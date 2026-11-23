// Sandboxed freestanding guest builder module
// (src/md/features/recipes.md, "The three kinds of builder";
// src/md/features/foreign_systems.md, "The machine of a Linux guest").
//
// Boots a Linux kernel of 64 bits in a guest of the kernel's Guest_Run, and
// answers its exits with the machine of modus:contract/guest_os. Runs inside
// a call host with zero network, zero real clock, and zero ambient grants:
//   - decodes and validates the canonical Guest_Build_Spec;
//   - copies the kernel image into the memory of the guest and verifies it
//     against spec.kernel_hash via BLAKE3 there, before any parse;
//   - copies the initial archive that the spec names to its place in the
//     memory of the guest and verifies it against spec.initial_archive_hash
//     there, before the boot gives it to Linux;
//   - loads it by the 64-bit boot protocol of Linux (zero page, page table,
//     descriptors, command line with the command of the build);
//   - maps the memory of the guest in regions that switch between Write and
//     Execute, never both;
//   - gives the guest a serial console, a virtio console, a read-only
//     virtio disk of inputs and a writable virtio disk of outputs, and no
//     network device;
//   - extracts the output disk into canonical MODTREE1 bytes only on clean
//     exit code 0 with zero sandbox violations, and reports the BLAKE3 hash
//     of the whole output disk.
package guest_builder_module

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import contract "modus:contract/guest_builder"
import "modus:contract/guest_os"
import "modus:guest_regions"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:system"

// Contract bounds on guest RAM and disks (up to 16 GiB RAM and 1 GiB disks).
// At runtime the process budget granted by the starter bounds the actual
// allocation cleanly with a Budget error record.
GUEST_MEMORY_PAGES_MOST :: contract.MAX_GUEST_MEMORY_PAGES
INPUT_DISK_BYTES_MOST :: contract.MAX_INPUT_DISK_BYTES
OUTPUT_DISK_BYTES_MOST :: contract.MAX_OUTPUT_DISK_BYTES
// Default budget request for a standalone guest build (256 MiB guest RAM,
// 16 MiB input disk, 64 MiB output disk, nested page tables and scratch);
// a starter can grant a larger budget for multi-GiB builds.
DEFAULT_GUEST_MEMORY_PAGES :: u64(65_536)
DEFAULT_INPUT_DISK_PAGES :: u64(4_096)
DEFAULT_OUTPUT_DISK_PAGES :: u64(16_384)
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 88064, processes = 2, threads = 1}
#assert(88064 == DEFAULT_GUEST_MEMORY_PAGES + DEFAULT_INPUT_DISK_PAGES + DEFAULT_OUTPUT_DISK_PAGES + 2048)
TREE_OUTPUT_BYTES_MOST :: contract.UNPACK_NODE_BUFFER_BYTES


// Export parameter indices reported in errors.Error_Record.
ARGUMENT_SPEC :: 1
ARGUMENT_KERNEL :: 2
ARGUMENT_INITIAL_ARCHIVE :: 3
ARGUMENT_INPUT_DISK :: 4
ARGUMENT_OUTPUT_TREE :: 5
ARGUMENT_REPORT :: 6

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
	machine_failure:    i64, // The word of a guest_os.Machine_Failure: why the machine stopped the guest.
	console_bytes:      i64, // The bytes that the guest wrote on its serial and virtio consoles.
	output_tree_hash:   value_kinds.Hash_Field,
	output_disk_hash:   value_kinds.Hash_Field, // The BLAKE3 hash of the whole output disk after the run.
}

// Package-level state keeps large records off the thread stack.
spec_wire_copy: [contract.SPEC_WIRE_SIZE]u8
tree_output_staging: [TREE_OUTPUT_BYTES_MOST]u8
unpack_workspace: contract.Disk_Unpack_Workspace
sandbox_runner: contract.Guest_Sandbox_Runner
machine: guest_os.Linux_Machine
output_disk_hash: blake3.Hash

// input_disk_copy copies the caller's input disk once into a memory object
// of this process: the caller shares its memory and can change it.
input_disk_copy :: proc "contextless" (input_disk: ^system.Bytes_To_Read, error: ^errors.Error_Record) -> (memory: guest_regions.Owned_Memory, disk: []u8, outcome: call_outcome.Call_Outcome) {
	if input_disk == nil {
		return {}, nil, .Succeeded
	}
	count := intrinsics.volatile_load(&input_disk.count)
	if count > INPUT_DISK_BYTES_MOST {
		outcome, _ = call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, ARGUMENT_INPUT_DISK, i64(count), i64(INPUT_DISK_BYTES_MOST))
		return {}, nil, outcome
	}
	if count == 0 {
		return {}, nil, .Succeeded
	}
	status: system.Status
	memory, status = guest_regions.owned_memory_make(count)
	if status != .Ok {
		outcome, _ = call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Budget, .Pages, ARGUMENT_INPUT_DISK, i64(count / system.PAGE_SIZE + 1))
		return {}, nil, outcome
	}
	intrinsics.mem_copy_non_overlapping(raw_data(memory.bytes), input_disk.bytes, int(count))
	return memory, memory.bytes[:count], .Succeeded
}

// output_tree_map maps the caller's lent output memory object for writing.
@(private = "file")
output_tree_map :: proc "contextless" (memory: system.Handle, error: ^errors.Error_Record) -> (bytes: []u8, outcome: call_outcome.Call_Outcome) {
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
		return nil, system.outcome_of_status(status)
	}
	pages, _ := system.memory_size(memory)
	return ([^]u8)(address)[:pages * system.PAGE_SIZE], .Succeeded
}

// write_report records the final state of sandbox_runner into report, and
// counts the build in the counts that status gives.
@(private = "file")
write_report :: proc "contextless" (report: ^Guest_Build_Report, state: contract.Guest_Build_State, refusal: contract.Guest_Builder_Refusal) {
	builds_count(state, refusal)
	report^ = {
		state              = i64(state),
		refusal            = i64(refusal),
		guest_exit_code    = i64(sandbox_runner.guest_exit_code),
		guest_exits        = i64(sandbox_runner.guest_exits_handled),
		sandbox_violations = i64(sandbox_runner.sandbox_violations),
		tree_bytes_written = i64(sandbox_runner.output_tree_bytes_written),
		machine_failure    = i64(machine.failure),
		console_bytes      = i64(machine.serial.captured) + i64(machine.devices[.Console].console_length),
		output_tree_hash   = value_kinds.Hash_Field(sandbox_runner.output_tree_hash),
		output_disk_hash   = value_kinds.Hash_Field(output_disk_hash),
	}
}

// The disks of one build, which build_end gives back in each case.
Build_Resources :: struct {
	input_disk:  guest_regions.Owned_Memory,
	output_disk: guest_regions.Owned_Memory,
}

build_end :: proc "contextless" (resources: ^Build_Resources) {
	guest_regions.owned_memory_end(&resources.input_disk)
	guest_regions.owned_memory_end(&resources.output_disk)
	resources^ = {}
}

// refuse ends a build that the checks refused before its guest ran: the
// argument breaks a rule of the build.
@(private = "file")
refuse :: proc "contextless" (report: ^Guest_Build_Report, error: ^errors.Error_Record, resources: ^Build_Resources, refusal: contract.Guest_Builder_Refusal, argument: i64) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	build_end(resources)
	sandbox_runner.state = .Refused
	write_report(report, .Refused, refusal)
	system.log_fact(.Info, Build_Refused{refusal_code = u64(refusal), exit_code = 0, violations = sandbox_runner.sandbox_violations})
	return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, argument, 0, 0, i64(refusal))
}

// argument_of_part gives the argument of build that a refusal before the
// run of the guest names.
@(private = "file")
argument_of_part :: proc "contextless" (part: guest_regions.Guest_Build_Part) -> i64 {
	switch part {
	case .None, .Spec:
		return ARGUMENT_SPEC
	case .Kernel:
		return ARGUMENT_KERNEL
	case .Initial_Archive:
		return ARGUMENT_INITIAL_ARCHIVE
	}
	return ARGUMENT_SPEC
}

// build boots the Linux kernel of the spec in a sandboxed guest and writes
// the canonical MODTREE1 output tree into output_tree on clean exit code 0,
// returning the canonical tree byte count written, or an outcome with an
// error record. The report holds the BLAKE3 hash of the whole output disk,
// and the state of a build that ran its guest.
@(export, link_name = "build")
build :: proc "c" (
	spec_bytes: ^system.Bytes_To_Read,
	kernel_image: ^system.Bytes_To_Read,
	initial_archive: ^system.Bytes_To_Read,
	input_disk: ^system.Bytes_To_Read,
	output_tree: system.Lent({.Read, .Write}),
	report: ^Guest_Build_Report,
	error: ^errors.Error_Record,
) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if report == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, ARGUMENT_REPORT)
	}
	report^ = {}
	machine = {}
	sandbox_runner = {}
	output_disk_hash = {}
	resources: Build_Resources

	// Copy every caller length once before validating: the caller shares the
	// call region and can modify memory concurrently.
	if spec_bytes == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, ARGUMENT_SPEC)
	}
	spec_count := intrinsics.volatile_load(&spec_bytes.count)
	if spec_count < contract.SPEC_WIRE_MIN_SIZE || spec_count > contract.SPEC_WIRE_SIZE {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Bytes, ARGUMENT_SPEC, i64(min(spec_count, 1 << 62)), contract.SPEC_WIRE_SIZE)
	}
	if spec_bytes.bytes == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, ARGUMENT_SPEC)
	}
	intrinsics.mem_copy_non_overlapping(&spec_wire_copy[0], spec_bytes.bytes, int(spec_count))
	spec, spec_refusal := contract.decode_build_spec(spec_wire_copy[:spec_count])
	if spec_refusal != .None {
		return refuse(report, error, &resources, spec_refusal, ARGUMENT_SPEC)
	}
	memory_bytes := spec.memory_pages * system.PAGE_SIZE

	if kernel_image == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, ARGUMENT_KERNEL)
	}
	kernel_count := intrinsics.volatile_load(&kernel_image.count)
	if kernel_count == 0 {
		return call_outcome.fail(error, .Argument_Refused, .Empty, .Bytes, ARGUMENT_KERNEL, 0, i64(memory_bytes))
	}
	if kernel_image.bytes == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, ARGUMENT_KERNEL)
	}
	if _, staging_fits := guest_regions.kernel_staging_bytes(kernel_count, memory_bytes); !staging_fits {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, ARGUMENT_KERNEL, i64(min(kernel_count, 1 << 62)), i64(memory_bytes))
	}
	archive_bytes: []u8
	if initial_archive != nil {
		archive_count := intrinsics.volatile_load(&initial_archive.count)
		if archive_count > contract.MAX_INITIAL_ARCHIVE_BYTES {
			system.log_fact(.Info, Initial_Archive_Refused{refusal_code = u64(contract.Guest_Builder_Refusal.Initial_Archive_Too_Large), archive_bytes = archive_count})
			return refuse(report, error, &resources, .Initial_Archive_Too_Large, ARGUMENT_INITIAL_ARCHIVE)
		}
		if archive_count > 0 && initial_archive.bytes != nil {
			archive_bytes = ([^]u8)(initial_archive.bytes)[:archive_count]
		}
	}

	input_bytes: []u8
	copied: call_outcome.Call_Outcome
	resources.input_disk, input_bytes, copied = input_disk_copy(input_disk, error)
	if copied != .Succeeded {
		build_end(&resources)
		return copied, 0
	}
	status: system.Status
	resources.output_disk, status = guest_regions.owned_memory_make(spec.output_size_bound)
	if status != .Ok {
		build_end(&resources)
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Budget, .Pages, ARGUMENT_SPEC, i64(spec.output_size_bound / system.PAGE_SIZE + 1))
	}
	output_bytes := resources.output_disk.bytes[:spec.output_size_bound]

	// The kernel is no disk of the guest: the runner gets no root disk.
	if prepare_refusal := contract.runner_prepare(&sandbox_runner, &spec, nil, input_bytes, output_bytes); prepare_refusal != .None {
		return refuse(report, error, &resources, prepare_refusal, ARGUMENT_INPUT_DISK)
	}
	if start_refusal := contract.runner_start(&sandbox_runner); start_refusal != .None {
		build_end(&resources)
		write_report(report, sandbox_runner.state, start_refusal)
		return call_outcome.fail(error, .Wrong_State, .State, .None, 0, 0, 0, i64(start_refusal))
	}

	// The run copies the kernel and the archive out of the memory of the
	// caller, and checks the copies against the hashes of the spec.
	kernel_bytes := ([^]u8)(kernel_image.bytes)[:kernel_count]
	run := guest_regions.guest_build_run(&sandbox_runner, &machine, &spec, kernel_bytes, archive_bytes, input_bytes, output_bytes)
	output_disk_hash = run.output_disk_hash
	switch run.end {
	case .Ran:
	case .Refused:
		switch run.refused_part {
		case .Kernel, .Spec:
			if run.boot_refusal != .None {
				system.log_fact(.Info, Kernel_Refused{refusal_code = u64(run.boot_refusal)})
			}
		case .Initial_Archive:
			system.log_fact(.Info, Initial_Archive_Refused{refusal_code = u64(sandbox_runner.refusal), archive_bytes = u64(len(archive_bytes))})
		case .None:
		}
		return refuse(report, error, &resources, sandbox_runner.refusal, argument_of_part(run.refused_part))
	case .Unsupported:
		build_end(&resources)
		write_report(report, .Refused, .Nonzero_Guest_Exit)
		system.log_fact(.Info, Guests_Unsupported{})
		return call_outcome.fail(error, .Operation_Unsupported, .Unsupported, .None)
	case .Kernel_Failed:
		build_end(&resources)
		write_report(report, .Failed, .Nonzero_Guest_Exit)
		system.log_fact(.Error, Step_Failed{status_word = op.Status_Word(run.status), step = value_kinds.text_field(run.step, 40)})
		return call_outcome.fail(error, system.outcome_of_own_status(run.status), .Refused, .None, 0, i64(run.status))
	}

	output_hash, tree_written, finish_refusal := contract.runner_finish(&sandbox_runner, &unpack_workspace, tree_output_staging[:])
	if finish_refusal != .None || sandbox_runner.state != .Succeeded {
		build_end(&resources)
		write_report(report, sandbox_runner.state, finish_refusal)
		system.log_fact(.Info, Build_Refused{refusal_code = u64(finish_refusal), exit_code = u64(sandbox_runner.guest_exit_code), violations = sandbox_runner.sandbox_violations})
		// The guest ran and gave no output tree: the report holds its state
		// and its exit, and the output tree of the caller is as it was.
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .None, 0, i64(sandbox_runner.guest_exit_code), 0, i64(finish_refusal))
	}
	build_end(&resources)

	output_memory, mapped := output_tree_map(output_tree.handle, error)
	if mapped != .Succeeded {
		sandbox_runner.output_tree_hash = {}
		sandbox_runner.output_tree_bytes_written = 0
		write_report(report, .Failed, .Output_Extraction_Failed)
		return mapped, 0
	}
	if tree_written > len(output_memory) {
		system.memory_unmap(raw_data(output_memory))
		sandbox_runner.output_tree_hash = {}
		sandbox_runner.output_tree_bytes_written = 0
		write_report(report, .Failed, .Output_Extraction_Failed)
		return call_outcome.fail(error, .Argument_Refused, .Too_Small, .Bytes, ARGUMENT_OUTPUT_TREE, i64(len(output_memory)), i64(tree_written))
	}
	intrinsics.mem_copy_non_overlapping(raw_data(output_memory), &tree_output_staging[0], tree_written)
	system.memory_unmap(raw_data(output_memory))

	write_report(report, .Succeeded, .None)
	system.log_fact(.Info, Build_Completed{guest_exits = sandbox_runner.guest_exits_handled, tree_bytes = u64(tree_written), output_hash = value_kinds.Hash_Field(output_hash)})
	return .Succeeded, i64(tree_written)
}
