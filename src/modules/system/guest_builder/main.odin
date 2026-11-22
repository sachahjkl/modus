// Sandboxed freestanding guest builder module
// (src/md/features/recipes.md, "The three kinds of builder";
// src/md/features/guest.md, src/md/features/foreign_systems.md).
//
// Boots a Linux kernel of 64 bits in a guest of the kernel's Guest_Run, and
// answers its exits with the machine of modus:contract/guest_os. Runs inside
// a call host with zero network, zero real clock, and zero ambient grants:
//   - decodes and validates the canonical Guest_Build_Spec;
//   - copies the kernel image into the memory of the guest and verifies it
//     against spec.kernel_hash via BLAKE3 there, before any parse;
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
import "modus:contract/errors"
import contract "modus:contract/guest_builder"
import "modus:contract/guest_os"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:system"

// The memory of the guest, at most, and the disks. The budget pays all of
// them at once, with the nested page table of the guest and this process.
GUEST_MEMORY_PAGES_MOST :: u64(65_536) // 256 MiB.
INPUT_DISK_BYTES_MOST :: u64(16 * 1024 * 1024)
OUTPUT_DISK_BYTES_MOST :: contract.MAX_OUTPUT_DISK_BYTES
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 88064, processes = 2, threads = 1}
#assert(88064 == GUEST_MEMORY_PAGES_MOST + INPUT_DISK_BYTES_MOST / system.PAGE_SIZE + OUTPUT_DISK_BYTES_MOST / system.PAGE_SIZE + 2048)
TREE_OUTPUT_BYTES_MOST :: contract.UNPACK_NODE_BUFFER_BYTES

// Name of the child guest process in kernel reports.
GUEST_PROCESS_NAME :: "guest_builder guest"

// The memory of the guest is mapped in regions of at least 2 MiB, so that
// the process has at most GUEST_REGIONS_MOST mappings in the guest.
GUEST_REGION_BYTES_LEAST :: u64(2 * 1024 * 1024)
GUEST_REGIONS_MOST :: u64(120)

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

// One memory object of this process, mapped here.
Owned_Memory :: struct {
	handle: system.Handle,
	bytes:  []u8,
}

// owned_memory_make makes a memory object of at least byte_count bytes and
// maps it here for writing.
owned_memory_make :: proc "contextless" (byte_count: u64) -> (memory: Owned_Memory, status: system.Status) {
	pages := max((byte_count + system.PAGE_SIZE - 1) / system.PAGE_SIZE, 1)
	handle: system.Handle
	handle, status = system.memory_create(pages)
	if status != .Ok {
		return {}, status
	}
	address: rawptr
	address, status = system.memory_map(handle, {.Write})
	if status != .Ok {
		system.close(handle)
		return {}, status
	}
	return {handle = handle, bytes = ([^]u8)(address)[:pages * system.PAGE_SIZE]}, .Ok
}

owned_memory_end :: proc "contextless" (memory: ^Owned_Memory) {
	if memory.bytes != nil {
		system.memory_unmap(raw_data(memory.bytes))
	}
	if memory.handle != 0 {
		system.close(memory.handle)
	}
	memory^ = {}
}

// input_disk_copy copies the caller's input disk once into a memory object
// of this process: the caller shares its memory and can change it.
input_disk_copy :: proc "contextless" (input_disk: ^system.Bytes_To_Read, error: ^errors.Error_Record) -> (memory: Owned_Memory, disk: []u8, ok: bool) {
	if input_disk == nil {
		return {}, nil, true
	}
	count := intrinsics.volatile_load(&input_disk.count)
	if count > INPUT_DISK_BYTES_MOST {
		errors.fail(error, ERROR, .Too_Long, .Bytes, ARGUMENT_INPUT_DISK, i64(count), i64(INPUT_DISK_BYTES_MOST))
		return {}, nil, false
	}
	if count == 0 {
		return {}, nil, true
	}
	status: system.Status
	memory, status = owned_memory_make(count)
	if status != .Ok {
		errors.fail(error, ERROR, .Budget, .Pages, ARGUMENT_INPUT_DISK, i64(count / system.PAGE_SIZE + 1))
		return {}, nil, false
	}
	intrinsics.mem_copy_non_overlapping(raw_data(memory.bytes), input_disk.bytes, int(count))
	return memory, memory.bytes[:count], true
}

// What the loop of a build does after one exit.
Build_Exit_Action :: enum u8 {
	Run_Again      = 1,
	Switch_Write   = 2, // Give the region of machine.switch_address Write, then run again.
	Switch_Execute = 3, // Give it Execute, then run again.
	End            = 4, // The run ended: the state of the runner says how.
}

// build_exit_handle answers one exit of a build: the bound of the exits,
// the machine of the guest, then the ports of the runner (the frozen clock,
// the exit status, the trap of a network device), and the read-only disk,
// whose first refused write refuses the build.
build_exit_handle :: proc "contextless" (runner: ^contract.Guest_Sandbox_Runner, linux: ^guest_os.Linux_Machine, registers: ^op.Guest_Registers, exit: guest_os.Machine_Exit, input_writes_reported: ^u64) -> Build_Exit_Action {
	if !contract.runner_exit_counted(runner) {
		return .End
	}
	action := Build_Exit_Action.Run_Again
	switch guest_os.linux_machine_handle_exit(linux, registers, exit) {
	case .Continue:
	case .Not_Handled:
		if !contract.runner_answer_exit(runner, registers, exit.kind, exit.a, exit.b, exit.c, exit.next) {
			action = .End
		}
	case .Switch_Write:
		action = .Switch_Write
	case .Switch_Execute:
		action = .Switch_Execute
	case .Halted, .Failed:
		// The guest stopped with no exit status: the build failed.
		runner.state = .Failed
		if runner.refusal == .None {
			runner.refusal = .Nonzero_Guest_Exit
		}
		return .End
	}
	if refused := linux.devices[.Input_Disk].writes_refused; refused > input_writes_reported^ {
		input_writes_reported^ = refused
		contract.runner_report_violation(runner, .Read_Only_Disk_Write)
		return .End
	}
	return action
}

// guest_region_bytes gives the size of one mapping of the memory of the
// guest: 2 MiB, or more for a memory past GUEST_REGIONS_MOST regions of 2 MiB.
guest_region_bytes :: proc "contextless" (memory_bytes: u64) -> u64 {
	least := (memory_bytes + GUEST_REGIONS_MOST - 1) / GUEST_REGIONS_MOST
	return max(GUEST_REGION_BYTES_LEAST, (least + GUEST_REGION_BYTES_LEAST - 1) / GUEST_REGION_BYTES_LEAST * GUEST_REGION_BYTES_LEAST)
}

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

// The resources of one build, which build_end gives back in each case.
Build_Resources :: struct {
	guest:       system.Handle,
	guest_ram:   Owned_Memory,
	input_disk:  Owned_Memory,
	output_disk: Owned_Memory,
}

build_end :: proc "contextless" (resources: ^Build_Resources) {
	if resources.guest != 0 {
		_ = system.process_stop(resources.guest)
		system.close(resources.guest)
	}
	owned_memory_end(&resources.guest_ram)
	owned_memory_end(&resources.input_disk)
	owned_memory_end(&resources.output_disk)
	resources^ = {}
}

// refuse ends a build that the checks refused before its guest ran.
@(private = "file")
refuse :: proc "contextless" (report: ^Guest_Build_Report, error: ^errors.Error_Record, resources: ^Build_Resources, refusal: contract.Guest_Builder_Refusal, argument: i64) -> i64 {
	build_end(resources)
	sandbox_runner.state = .Refused
	write_report(report, .Refused, refusal)
	system.log_fact(.Info, Build_Refused{refusal_code = u64(refusal), exit_code = 0, violations = sandbox_runner.sandbox_violations})
	return errors.fail(error, ERROR, .Bad_Value, .None, argument, 0, 0, i64(refusal))
}

// guest_map maps the memory of the guest into the guest process in regions
// that may each be written or executed, never both, and gives each region
// Execute first: a kernel starts by running code.
@(private = "file")
guest_map :: proc "contextless" (guest: system.Handle, memory: system.Handle, memory_bytes: u64) -> (status: system.Status, step: string) {
	region := guest_region_bytes(memory_bytes)
	for address: u64 = 0; address < memory_bytes; address += region {
		pages := min(region, memory_bytes - address) / system.PAGE_SIZE
		flags := op.Map_Flags{.Write, .Execute, .No_Access}
		if address == 0 {
			flags += {.At_Address_Zero}
		}
		if _, status = system.memory_map(memory, flags, guest, address, address / system.PAGE_SIZE, pages); status != .Ok {
			return status, "Memory_Map of guest memory"
		}
		ranges := [1]op.Address_Range{{address = address, page_count = pages}}
		if _, status = system.memory_protect(ranges[:], {.Execute}, process = guest); status != .Ok {
			return status, "Memory_Protect of guest memory"
		}
	}
	return .Ok, ""
}

// guest_region_switch gives the region of a guest physical address the one
// access that the guest asked for.
@(private = "file")
guest_region_switch :: proc "contextless" (guest: system.Handle, memory_bytes: u64, address: u64, write: bool) -> system.Status {
	region := guest_region_bytes(memory_bytes)
	start := address / region * region
	pages := min(region, memory_bytes - start) / system.PAGE_SIZE
	ranges := [1]op.Address_Range{{address = start, page_count = pages}}
	_, status := system.memory_protect(ranges[:], write ? op.Map_Flags{.Write} : op.Map_Flags{.Execute}, process = guest)
	return status
}

// build boots the Linux kernel of the spec in a sandboxed guest and writes
// the canonical MODTREE1 output tree into output_tree on clean exit code 0,
// returning the canonical tree byte count written or -1 with an error
// record. The report holds the BLAKE3 hash of the whole output disk.
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
	machine = {}
	sandbox_runner = {}
	output_disk_hash = {}
	resources: Build_Resources

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
		return refuse(report, error, &resources, spec_refusal, ARGUMENT_SPEC)
	}
	if spec.memory_pages > GUEST_MEMORY_PAGES_MOST {
		return refuse(report, error, &resources, .Memory_Past_Bound, ARGUMENT_SPEC)
	}
	memory_bytes := spec.memory_pages * system.PAGE_SIZE

	if kernel_image == nil {
		return errors.fail(error, ERROR, .Bad_Address, .None, ARGUMENT_KERNEL)
	}
	kernel_count := intrinsics.volatile_load(&kernel_image.count)
	if kernel_count == 0 {
		return errors.fail(error, ERROR, .Empty, .Bytes, ARGUMENT_KERNEL, 0, i64(memory_bytes))
	}
	// The image waits at the top of the memory of the guest, page aligned,
	// while the kernel loads below it.
	staging_bytes := (kernel_count + system.PAGE_SIZE - 1) &~ (system.PAGE_SIZE - 1)
	if staging_bytes >= memory_bytes {
		return errors.fail(error, ERROR, .Too_Long, .Bytes, ARGUMENT_KERNEL, i64(kernel_count), i64(memory_bytes))
	}
	staging := memory_bytes - staging_bytes

	status: system.Status
	resources.guest_ram, status = owned_memory_make(memory_bytes)
	if status != .Ok {
		build_end(&resources)
		return errors.fail(error, ERROR, .Budget, .Pages, ARGUMENT_SPEC, i64(spec.memory_pages))
	}
	ram := resources.guest_ram.bytes[:memory_bytes]
	kernel_slice := ram[staging:][:kernel_count]
	intrinsics.mem_copy_non_overlapping(raw_data(kernel_slice), kernel_image.bytes, int(kernel_count))
	// The hash is of the copy, which the caller cannot change any more.
	if blake3.hash(kernel_slice) != spec.kernel_hash {
		return refuse(report, error, &resources, .Malformed_Disk_Image, ARGUMENT_KERNEL)
	}
	parsed, boot_refusal := guest_os.linux_image_parse(kernel_slice, memory_bytes)
	if boot_refusal == .None && parsed.load_end > staging {
		boot_refusal = .Memory_Too_Small
	}
	if boot_refusal != .None {
		system.log_fact(.Info, Kernel_Refused{refusal_code = u64(boot_refusal)})
		return refuse(report, error, &resources, boot_refusal == .Memory_Too_Small ? .Memory_Too_Small : .Malformed_Disk_Image, ARGUMENT_KERNEL)
	}

	input_bytes: []u8
	ok: bool
	resources.input_disk, input_bytes, ok = input_disk_copy(input_disk, error)
	if !ok {
		build_end(&resources)
		return ERROR
	}
	resources.output_disk, status = owned_memory_make(spec.output_size_bound)
	if status != .Ok {
		build_end(&resources)
		return errors.fail(error, ERROR, .Budget, .Pages, ARGUMENT_SPEC, i64(spec.output_size_bound / system.PAGE_SIZE + 1))
	}
	output_bytes := resources.output_disk.bytes[:spec.output_size_bound]

	// The kernel is no disk of the guest: the runner gets no root disk.
	prepare_refusal := contract.runner_prepare(&sandbox_runner, &spec, nil, input_bytes, output_bytes)
	if prepare_refusal != .None {
		return refuse(report, error, &resources, prepare_refusal, ARGUMENT_INPUT_DISK)
	}
	guest_memory := guest_os.Guest_Memory{ram}
	guest_os.linux_machine_start(&machine, guest_memory, input_bytes, output_bytes)
	places := guest_os.linux_machine_places()
	registers, start_refusal := guest_os.linux_boot_prepare(guest_memory, kernel_slice, parsed, places[:], spec.command[:spec.command_length])
	if start_refusal != .None {
		system.log_fact(.Info, Kernel_Refused{refusal_code = u64(start_refusal)})
		return refuse(report, error, &resources, .Invalid_Command_Text, ARGUMENT_SPEC)
	}
	// The image leaves the memory of the guest: a build sees the same bytes
	// whatever was staged there.
	intrinsics.mem_zero(raw_data(kernel_slice), int(staging_bytes))
	if refusal := contract.runner_start(&sandbox_runner); refusal != .None {
		build_end(&resources)
		write_report(report, sandbox_runner.state, refusal)
		return errors.fail(error, ERROR, .State, .None, 0, 0, 0, i64(refusal))
	}

	// The guest process: its nested page table holds the memory of the
	// guest only. Past it, each address is a device of the machine.
	guest_name := GUEST_PROCESS_NAME
	created, create_status := system.call(.Process_Create, u64(system.own_budget()), u64(uintptr(raw_data(guest_name))), u64(len(guest_name)))
	if create_status != .Ok {
		build_end(&resources)
		system.log_fact(.Error, Step_Failed{status_word = op.Status_Word(create_status), step = value_kinds.text_field("Process_Create of the guest", 40)})
		return errors.fail(error, ERROR, .Refused, .None, 0, i64(create_status))
	}
	resources.guest = system.Handle(created[0])
	if map_status, step := guest_map(resources.guest, resources.guest_ram.handle, memory_bytes); map_status != .Ok {
		build_end(&resources)
		system.log_fact(.Error, Step_Failed{status_word = op.Status_Word(map_status), step = value_kinds.text_field(step, 40)})
		return errors.fail(error, ERROR, .Refused, .None, 0, i64(map_status))
	}

	consecutive_interrupted := u64(0)
	input_writes_reported := u64(0)
	run_loop: for {
		run_error: errors.Error_Record
		exit, run_status := system.guest_run(resources.guest, &registers, &run_error)
		if run_status == .Bad_Operation && run_error.kind == i64(errors.Kind.Unsupported) {
			build_end(&resources)
			write_report(report, .Refused, .Nonzero_Guest_Exit)
			system.log_fact(.Info, Guests_Unsupported{})
			return errors.fail(error, ERROR, .Unsupported, .None)
		}
		if run_status != .Ok {
			build_end(&resources)
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
		machine_exit := guest_os.Machine_Exit{kind = exit.kind, a = exit.a, b = exit.b, c = exit.c, next = exit.next, code = exit.code, information = exit.information}
		action := build_exit_handle(&sandbox_runner, &machine, &registers, machine_exit, &input_writes_reported)
		switch action {
		case .Run_Again:
		case .Switch_Write, .Switch_Execute:
			write := action == .Switch_Write
			if switch_status := guest_region_switch(resources.guest, memory_bytes, machine.switch_address, write); switch_status != .Ok {
				sandbox_runner.state = .Failed
				system.log_fact(.Error, Step_Failed{status_word = op.Status_Word(switch_status), step = value_kinds.text_field("Memory_Protect of a guest region", 40)})
				break run_loop
			}
		case .End:
			break run_loop
		}
	}

	// Stop the guest before the output disk is read: no instruction of the
	// guest runs after process_stop returns.
	_ = system.process_stop(resources.guest)
	system.close(resources.guest)
	resources.guest = 0
	output_disk_hash = blake3.hash(output_bytes)

	output_hash, tree_written, finish_refusal := contract.runner_finish(&sandbox_runner, &unpack_workspace, tree_output_staging[:])
	if finish_refusal != .None || sandbox_runner.state != .Succeeded {
		build_end(&resources)
		write_report(report, sandbox_runner.state, finish_refusal)
		system.log_fact(.Info, Build_Refused{refusal_code = u64(finish_refusal), exit_code = u64(sandbox_runner.guest_exit_code), violations = sandbox_runner.sandbox_violations})
		return errors.fail(error, ERROR, .Refused, .None, 0, i64(sandbox_runner.guest_exit_code), 0, i64(finish_refusal))
	}
	build_end(&resources)

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
