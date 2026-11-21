// Sandboxed freestanding guest builder module
// (src/md/features/recipes.md, "The three kinds of builder";
// src/md/features/guest.md).
//
// Wires the pure contract package modus:contract/guest_builder to the kernel's
// Guest_Run virtualization primitive. Runs inside a call host with zero
// network, zero real clock, and zero ambient grants:
//   - decodes and validates the canonical Guest_Build_Spec;
//   - verifies the guest kernel image against spec.kernel_hash via BLAKE3;
//   - creates a child guest process with no threads and maps verified kernel
//     code execute-only (never writable and executable);
//   - drives system.guest_run through Guest_Sandbox_Runner so read-only input
//     disks cannot be modified, network access is refused, and RTC/clock reads
//     are frozen to spec.frozen_epoch_seconds;
//   - extracts and hashes the writable output disk into canonical MODTREE1
//     bytes only on clean exit code 0 with zero sandbox violations.
package guest_builder_module

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/errors"
import contract "modus:contract/guest_builder"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:system"

// The builder process and its child guest process: working memory covers
// module mappings, BSS staging buffers, guest code pages, nested page tables,
// and the two kernel control pages of the guest processor.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 512, processes = 2, threads = 1}

// Name of the child guest process in kernel reports.
GUEST_PROCESS_NAME :: "guest_builder guest"

// Guest physical load address of the verified guest kernel entry code:
// Memory_Map refuses guest physical page 0.
GUEST_CODE_ADDRESS :: u64(0x1000)

// Maximum sizes for copy-then-check staging buffers in BSS.
KERNEL_IMAGE_BYTES_MOST :: 64 * 1024
INPUT_DISK_BYTES_MOST :: 64 * 1024
OUTPUT_DISK_BYTES_MOST :: 64 * 1024
TREE_OUTPUT_BYTES_MOST :: contract.UNPACK_NODE_BUFFER_BYTES

// Bound on consecutive Interrupted exits from machine timer ticks before
// aborting a stalled run.
INTERRUPTED_RUNS_LIMIT :: u64(1000)

// Failing return code of build(): the error record carries the exact cause.
ERROR :: i64(-1)

// Export parameter indices reported in errors.Error_Record.
ARGUMENT_SPEC :: 1
ARGUMENT_KERNEL :: 2
ARGUMENT_INPUT_DISK :: 3
ARGUMENT_OUTPUT_TREE :: 4
ARGUMENT_REPORT :: 5

// Parameter index of the memory handle in kernel Memory_Map error records.
MEMORY_MAP_ARGUMENT_MEMORY :: 1

// Flat fixed-layout build report returned to the caller of build().
Guest_Build_Report :: struct {
	state:              i64,
	refusal:            i64,
	guest_exit_code:    i64,
	guest_exits:        i64,
	sandbox_violations: i64,
	tree_bytes_written: i64,
	output_tree_hash:   value_kinds.Hash_Field,
}

// Package-level BSS staging buffers keep large arrays off the thread stack.
spec_wire_copy: [contract.SPEC_WIRE_SIZE]u8
kernel_image_copy: [KERNEL_IMAGE_BYTES_MOST]u8
input_disk_copy: [INPUT_DISK_BYTES_MOST]u8
output_disk_staging: [OUTPUT_DISK_BYTES_MOST]u8
tree_output_staging: [TREE_OUTPUT_BYTES_MOST]u8
unpack_workspace: contract.Disk_Unpack_Workspace
sandbox_runner: contract.Guest_Sandbox_Runner

// output_tree_map maps the caller's lent output memory object for writing.
@(private = "file")
output_tree_map :: proc "contextless" (memory: system.Handle, error: ^errors.Error_Record) -> (bytes: []u8, ok: bool) {
	refusal: errors.Error_Record
	address, status := system.memory_map(memory, {.Write}, error = &refusal)
	if status != .Ok {
		if error != nil {
			error^ = refusal
			error.operation = 0
			error.argument = refusal.argument == MEMORY_MAP_ARGUMENT_MEMORY ? i64(ARGUMENT_OUTPUT_TREE) : 0
			if refusal.kind == i64(errors.Kind.None) {
				error^ = errors.error_make(.Refused, argument = ARGUMENT_OUTPUT_TREE, found = i64(status))
			}
		}
		return nil, false
	}
	pages, _ := system.memory_size(memory)
	return ([^]u8)(address)[:pages * system.PAGE_SIZE], true
}

// write_report records the final state of sandbox_runner into report.
@(private = "file")
write_report :: proc "contextless" (report: ^Guest_Build_Report, state: contract.Guest_Build_State, refusal: contract.Guest_Builder_Refusal) {
	report^ = {
		state              = i64(state),
		refusal            = i64(refusal),
		guest_exit_code    = i64(sandbox_runner.guest_exit_code),
		guest_exits        = i64(sandbox_runner.guest_exits_handled),
		sandbox_violations = i64(sandbox_runner.sandbox_violations),
		tree_bytes_written = i64(sandbox_runner.output_tree_bytes_written),
		output_tree_hash   = value_kinds.Hash_Field(sandbox_runner.output_tree_hash),
	}
}

// build executes one deterministic sandboxed guest build and writes the
// canonical MODTREE1 output tree into output_tree on clean exit code 0,
// returning the canonical tree byte count written or -1 with an error record.
@(export, link_name = "build")
build :: proc "c" (
	spec_bytes: ^system.Bytes_To_Read,
	kernel_image: ^system.Bytes_To_Read,
	input_disk: ^system.Bytes_To_Read,
	output_tree: system.Lent({.Read, .Write}),
	report: ^Guest_Build_Report,
	error: ^errors.Error_Record,
) -> i64 {
	if report == nil {
		return errors.fail(error, ERROR, .Bad_Address, .None, ARGUMENT_REPORT)
	}
	report^ = {}

	// Copy every caller length and buffer once before validating: the caller
	// shares the call region and can modify memory concurrently.
	if spec_bytes == nil {
		return errors.fail(error, ERROR, .Bad_Address, .None, ARGUMENT_SPEC)
	}
	spec_count := intrinsics.volatile_load(&spec_bytes.count)
	if spec_count != contract.SPEC_WIRE_SIZE {
		return errors.fail(error, ERROR, .Bad_Value, .Bytes, ARGUMENT_SPEC, i64(spec_count), contract.SPEC_WIRE_SIZE)
	}
	intrinsics.mem_copy_non_overlapping(&spec_wire_copy[0], spec_bytes.bytes, contract.SPEC_WIRE_SIZE)

	spec, spec_refusal := contract.decode_build_spec(spec_wire_copy[:])
	if spec_refusal != .None {
		sandbox_runner = {}
		write_report(report, .Refused, spec_refusal)
		system.log_fact(.Info, Build_Refused{refusal_code = u64(spec_refusal), exit_code = 0, violations = 0})
		return errors.fail(error, ERROR, .Bad_Value, .None, ARGUMENT_SPEC, 0, 0, i64(spec_refusal))
	}
	if spec.output_size_bound > OUTPUT_DISK_BYTES_MOST {
		sandbox_runner = {}
		write_report(report, .Refused, .Output_Too_Large)
		system.log_fact(.Info, Build_Refused{refusal_code = u64(contract.Guest_Builder_Refusal.Output_Too_Large), exit_code = 0, violations = 0})
		return errors.fail(error, ERROR, .Over_Limit, .Bytes, ARGUMENT_SPEC, i64(spec.output_size_bound), OUTPUT_DISK_BYTES_MOST)
	}

	if kernel_image == nil {
		return errors.fail(error, ERROR, .Bad_Address, .None, ARGUMENT_KERNEL)
	}
	kernel_count := intrinsics.volatile_load(&kernel_image.count)
	if kernel_count == 0 {
		return errors.fail(error, ERROR, .Empty, .Bytes, ARGUMENT_KERNEL, 0, KERNEL_IMAGE_BYTES_MOST)
	}
	if kernel_count > KERNEL_IMAGE_BYTES_MOST {
		return errors.fail(error, ERROR, .Too_Long, .Bytes, ARGUMENT_KERNEL, i64(kernel_count), KERNEL_IMAGE_BYTES_MOST)
	}
	intrinsics.mem_copy_non_overlapping(&kernel_image_copy[0], kernel_image.bytes, int(kernel_count))
	kernel_slice := kernel_image_copy[:kernel_count]

	// Verify the guest kernel bytes match the content-addressed kernel_hash.
	if blake3.hash(kernel_slice) != spec.kernel_hash {
		sandbox_runner = {}
		write_report(report, .Refused, .Malformed_Disk_Image)
		system.log_fact(.Info, Build_Refused{refusal_code = u64(contract.Guest_Builder_Refusal.Malformed_Disk_Image), exit_code = 0, violations = 0})
		return errors.fail(error, ERROR, .Bad_Value, .None, ARGUMENT_KERNEL, 0, 0, i64(contract.Guest_Builder_Refusal.Malformed_Disk_Image))
	}

	input_slice: []u8
	if input_disk != nil {
		input_count := intrinsics.volatile_load(&input_disk.count)
		if input_count > INPUT_DISK_BYTES_MOST {
			return errors.fail(error, ERROR, .Too_Long, .Bytes, ARGUMENT_INPUT_DISK, i64(input_count), INPUT_DISK_BYTES_MOST)
		}
		if input_count > 0 {
			intrinsics.mem_copy_non_overlapping(&input_disk_copy[0], input_disk.bytes, int(input_count))
			input_slice = input_disk_copy[:input_count]
		}
	}

	prepare_refusal := contract.runner_prepare(&sandbox_runner, &spec, kernel_slice, input_slice, output_disk_staging[:spec.output_size_bound])
	if prepare_refusal != .None {
		write_report(report, sandbox_runner.state, prepare_refusal)
		system.log_fact(.Info, Build_Refused{refusal_code = u64(prepare_refusal), exit_code = 0, violations = sandbox_runner.sandbox_violations})
		return errors.fail(error, ERROR, .Bad_Value, .None, ARGUMENT_INPUT_DISK, 0, 0, i64(prepare_refusal))
	}
	if start_refusal := contract.runner_start(&sandbox_runner); start_refusal != .None {
		write_report(report, sandbox_runner.state, start_refusal)
		return errors.fail(error, ERROR, .State, .None, 0, 0, 0, i64(start_refusal))
	}

	// Create the isolated guest process whose nested page table holds only
	// the explicitly mapped execute-only guest kernel pages.
	guest_name := GUEST_PROCESS_NAME
	created, create_status := system.call(.Process_Create, u64(system.own_budget()), u64(uintptr(raw_data(guest_name))), u64(len(guest_name)))
	if create_status != .Ok {
		system.log_fact(.Error, Step_Failed{status_word = op.Status_Word(create_status), step = value_kinds.text_field("Process_Create of the guest", 40)})
		return errors.fail(error, ERROR, .Refused, .None, 0, i64(create_status))
	}
	guest := system.Handle(created[0])

	kernel_pages := (kernel_count + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	code_memory, memory_status := system.memory_create(kernel_pages)
	if memory_status != .Ok {
		_ = system.process_stop(guest)
		system.close(guest)
		system.log_fact(.Error, Step_Failed{status_word = op.Status_Word(memory_status), step = value_kinds.text_field("Memory_Create of guest code", 40)})
		return errors.fail(error, ERROR, .Budget, .Pages, 0, i64(kernel_pages))
	}

	code_mapping, map_status := system.memory_map(code_memory, {.Write})
	if map_status != .Ok {
		system.close(code_memory)
		_ = system.process_stop(guest)
		system.close(guest)
		system.log_fact(.Error, Step_Failed{status_word = op.Status_Word(map_status), step = value_kinds.text_field("Memory_Map of guest code", 40)})
		return errors.fail(error, ERROR, .Refused, .None, 0, i64(map_status))
	}
	intrinsics.mem_copy_non_overlapping(code_mapping, &kernel_image_copy[0], int(kernel_count))
	system.memory_unmap(code_mapping)

	// Map guest code execute-only so no page is both writable and executable.
	if _, guest_map_status := system.memory_map(code_memory, {.Execute}, guest, GUEST_CODE_ADDRESS); guest_map_status != .Ok {
		system.close(code_memory)
		_ = system.process_stop(guest)
		system.close(guest)
		system.log_fact(.Error, Step_Failed{status_word = op.Status_Word(guest_map_status), step = value_kinds.text_field("Memory_Map in guest", 40)})
		return errors.fail(error, ERROR, .Refused, .None, 0, i64(guest_map_status))
	}

	// Execute the guest processor under strict sandbox control.
	registers := op.Guest_Registers{rip = GUEST_CODE_ADDRESS}
	consecutive_interrupted := u64(0)
	for {
		run_error: errors.Error_Record
		exit, run_status := system.guest_run(guest, &registers, &run_error)
		if run_status == .Bad_Operation && run_error.kind == i64(errors.Kind.Unsupported) {
			system.close(code_memory)
			_ = system.process_stop(guest)
			system.close(guest)
			write_report(report, .Refused, .Nonzero_Guest_Exit)
			system.log_fact(.Info, Guests_Unsupported{})
			return errors.fail(error, ERROR, .Unsupported, .None)
		}
		if run_status != .Ok {
			system.close(code_memory)
			_ = system.process_stop(guest)
			system.close(guest)
			write_report(report, .Failed, .Nonzero_Guest_Exit)
			system.log_fact(.Error, Step_Failed{status_word = op.Status_Word(run_status), step = value_kinds.text_field("Guest_Run", 40)})
			return errors.fail(error, ERROR, .Refused, .None, 0, i64(run_status))
		}
		if exit.kind == .Interrupted {
			consecutive_interrupted += 1
			if consecutive_interrupted > INTERRUPTED_RUNS_LIMIT {
				sandbox_runner.state = .Timed_Out
				break
			}
		} else {
			consecutive_interrupted = 0
		}
		if !contract.runner_handle_exit(&sandbox_runner, &registers, exit.kind, exit.a, exit.b, exit.c, exit.next) {
			break
		}
	}

	// Stop and release the child guest process before extracting output.
	_ = system.process_stop(guest)
	system.close(guest)
	system.close(code_memory)

	// Extract and hash the writable output disk only on clean exit code 0.
	output_hash, tree_written, finish_refusal := contract.runner_finish(&sandbox_runner, &unpack_workspace, tree_output_staging[:])
	if finish_refusal != .None || sandbox_runner.state != .Succeeded {
		write_report(report, sandbox_runner.state, finish_refusal)
		system.log_fact(.Info, Build_Refused{refusal_code = u64(finish_refusal), exit_code = u64(sandbox_runner.guest_exit_code), violations = sandbox_runner.sandbox_violations})
		return errors.fail(error, ERROR, .Refused, .None, 0, i64(sandbox_runner.guest_exit_code), 0, i64(finish_refusal))
	}

	output_memory, mapped := output_tree_map(output_tree.handle, error)
	if !mapped {
		sandbox_runner.output_tree_hash = {}
		sandbox_runner.output_tree_bytes_written = 0
		write_report(report, .Failed, .Output_Extraction_Failed)
		return ERROR
	}
	if tree_written > len(output_memory) {
		system.memory_unmap(raw_data(output_memory))
		sandbox_runner.output_tree_hash = {}
		sandbox_runner.output_tree_bytes_written = 0
		write_report(report, .Failed, .Output_Extraction_Failed)
		return errors.fail(error, ERROR, .Too_Small, .Bytes, ARGUMENT_OUTPUT_TREE, i64(len(output_memory)), i64(tree_written))
	}
	intrinsics.mem_copy_non_overlapping(raw_data(output_memory), &tree_output_staging[0], tree_written)
	system.memory_unmap(raw_data(output_memory))

	write_report(report, .Succeeded, .None)
	system.log_fact(.Info, Build_Completed{guest_exits = sandbox_runner.guest_exits_handled, tree_bytes = u64(tree_written), output_hash = value_kinds.Hash_Field(output_hash)})
	return i64(tree_written)
}
