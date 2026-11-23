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

// The memory of the guest, at most, and the disks. The budget pays all of
// them at once, with the nested page table of the guest and this process.
GUEST_MEMORY_PAGES_MOST :: u64(65_536) // 256 MiB.
INPUT_DISK_BYTES_MOST :: u64(16 * 1024 * 1024)
OUTPUT_DISK_BYTES_MOST :: contract.MAX_OUTPUT_DISK_BYTES
// Working memory for up to 256 MiB guest RAM, 16 MiB input disk, 64 MiB
// output disk, nested page tables and working scratch; two child guest
// processes and one service thread.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 88064, processes = 2, threads = 1}
#assert(88064 == GUEST_MEMORY_PAGES_MOST + INPUT_DISK_BYTES_MOST / system.PAGE_SIZE + OUTPUT_DISK_BYTES_MOST / system.PAGE_SIZE + 2048)
TREE_OUTPUT_BYTES_MOST :: contract.UNPACK_NODE_BUFFER_BYTES

// Name of the child guest process in kernel reports.
GUEST_PROCESS_NAME :: "guest_builder guest"

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

// initial_archive_stage copies the initial archive of the caller to the
// place that the boot gives it in the memory of the guest, under ceiling,
// and checks its size and its hash there: the caller shares its memory and
// can change it, the copy it cannot. linux_boot_prepare then finds the
// bytes at their place already. A refused archive leaves no byte of it in
// the memory of the guest.
initial_archive_stage :: proc "contextless" (ram: []u8, parsed: guest_os.Linux_Image, ceiling: u64, spec: ^contract.Guest_Build_Spec, source: rawptr, count: u64) -> (archive: []u8, refusal: contract.Guest_Builder_Refusal) {
	if contract.hash_is_zero(spec.initial_archive_hash) {
		if count != 0 || spec.initial_archive_size != 0 {
			return nil, .Initial_Archive_Size_Invalid
		}
		return nil, .None
	}
	if count > contract.MAX_INITIAL_ARCHIVE_BYTES {
		return nil, .Initial_Archive_Too_Large
	}
	if count != spec.initial_archive_size || source == nil {
		return nil, .Initial_Archive_Size_Invalid
	}
	address, place_refusal := guest_os.linux_initial_archive_place(parsed, count, min(ceiling, u64(len(ram))))
	if place_refusal != .None {
		return nil, .Initial_Archive_Too_Large
	}
	archive = ram[address:][:count]
	intrinsics.mem_copy_non_overlapping(raw_data(archive), source, int(count))
	if refusal = contract.initial_archive_check(spec, archive); refusal != .None {
		intrinsics.mem_zero(raw_data(archive), int(count))
		return nil, refusal
	}
	return archive, .None
}

// What the loop of a build does after one exit.
Build_Exit_Action :: enum u8 {
	Run_Again      = 1,
	End            = 4, // The run ended: the state of the runner says how.
}

// build_exit_handle answers one exit of a build: the bound of the exits,
// the machine of the guest, then the ports of the runner (the frozen clock,
// the exit status, the trap of a network device), and the read-only disk,
// whose first refused write refuses the build.
build_exit_handle :: proc "contextless" (runner: ^contract.Guest_Sandbox_Runner, linux: ^guest_os.Linux_Machine, registers: ^op.Guest_Registers, exit: guest_os.Machine_Exit, input_writes_reported: ^u64) -> Build_Exit_Action {
	if !contract.runner_exit_counted(runner, exit.kind) {
		return .End
	}
	action := Build_Exit_Action.Run_Again
	switch guest_os.linux_machine_handle_exit(linux, registers, exit) {
	case .Continue:
	case .Not_Handled:
		if !contract.runner_answer_exit(runner, registers, exit.kind, exit.a, exit.b, exit.c, exit.next) {
			action = .End
		}
	case .Halted, .Failed, .Waiting:
		// The guest stopped with no exit status: the build failed. A build
		// never sets waits_for_input, so Waiting never comes.
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

// The resources of one build, which build_end gives back in each case.
Build_Resources :: struct {
	guest:       system.Handle,
	guest_ram:   guest_regions.Owned_Memory,
	input_disk:  guest_regions.Owned_Memory,
	output_disk: guest_regions.Owned_Memory,
}

build_end :: proc "contextless" (resources: ^Build_Resources) {
	if resources.guest != 0 {
		_ = system.process_stop(resources.guest)
		system.close(resources.guest)
	}
	guest_regions.owned_memory_end(&resources.guest_ram)
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

	// Copy every caller length and buffer once before validating: the caller
	// shares the call region and can modify memory concurrently.
	if spec_bytes == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, ARGUMENT_SPEC)
	}
	spec_count := intrinsics.volatile_load(&spec_bytes.count)
	if spec_count != contract.SPEC_WIRE_SIZE {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Bytes, ARGUMENT_SPEC, i64(min(spec_count, 1 << 62)), contract.SPEC_WIRE_SIZE)
	}
	if spec_bytes.bytes == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, ARGUMENT_SPEC)
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
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, ARGUMENT_KERNEL)
	}
	kernel_count := intrinsics.volatile_load(&kernel_image.count)
	if kernel_count == 0 {
		return call_outcome.fail(error, .Argument_Refused, .Empty, .Bytes, ARGUMENT_KERNEL, 0, i64(memory_bytes))
	}
	if kernel_image.bytes == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, ARGUMENT_KERNEL)
	}
	staging_bytes, staging_fits := guest_regions.kernel_staging_bytes(kernel_count, memory_bytes)
	if !staging_fits {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, ARGUMENT_KERNEL, i64(min(kernel_count, 1 << 62)), i64(memory_bytes))
	}
	staging := memory_bytes - staging_bytes

	status: system.Status
	resources.guest_ram, status = guest_regions.owned_memory_make(memory_bytes)
	if status != .Ok {
		build_end(&resources)
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Budget, .Pages, ARGUMENT_SPEC, i64(spec.memory_pages))
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

	// The initial archive goes to its place below the copy of the image,
	// and is checked there.
	archive_source: rawptr
	archive_count: u64
	if initial_archive != nil {
		archive_count = intrinsics.volatile_load(&initial_archive.count)
		archive_source = initial_archive.bytes
	}
	archive, archive_refusal := initial_archive_stage(ram, parsed, staging, &spec, archive_source, archive_count)
	if archive_refusal != .None {
		system.log_fact(.Info, Initial_Archive_Refused{refusal_code = u64(archive_refusal), archive_bytes = archive_count})
		return refuse(report, error, &resources, archive_refusal, ARGUMENT_INITIAL_ARCHIVE)
	}

	input_bytes: []u8
	copied: call_outcome.Call_Outcome
	resources.input_disk, input_bytes, copied = input_disk_copy(input_disk, error)
	if copied != .Succeeded {
		build_end(&resources)
		return copied, 0
	}
	resources.output_disk, status = guest_regions.owned_memory_make(spec.output_size_bound)
	if status != .Ok {
		build_end(&resources)
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Budget, .Pages, ARGUMENT_SPEC, i64(spec.output_size_bound / system.PAGE_SIZE + 1))
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
	// The ceiling is the one of initial_archive_stage: the boot finds the
	// archive at its place, below the copy of the image.
	registers, start_refusal := guest_os.linux_boot_prepare(guest_memory, kernel_slice, parsed, places[:], spec.command[:spec.command_length], archive, staging)
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
		return call_outcome.fail(error, .Wrong_State, .State, .None, 0, 0, 0, i64(refusal))
	}

	// The guest process: its nested page table holds the memory of the
	// guest only. Past it, each address is a device of the machine.
	guest_name := GUEST_PROCESS_NAME
	created, create_status := system.call(.Process_Create, u64(system.own_budget()), u64(uintptr(raw_data(guest_name))), u64(len(guest_name)))
	if create_status != .Ok {
		build_end(&resources)
		system.log_fact(.Error, Step_Failed{status_word = op.Status_Word(create_status), step = value_kinds.text_field("Process_Create of the guest", 40)})
		return call_outcome.fail(error, system.outcome_of_own_status(create_status), .Refused, .None, 0, i64(create_status))
	}
	resources.guest = system.Handle(created[0])
	if map_status, step := guest_regions.map_memory(resources.guest, resources.guest_ram.handle, memory_bytes); map_status != .Ok {
		build_end(&resources)
		system.log_fact(.Error, Step_Failed{status_word = op.Status_Word(map_status), step = value_kinds.text_field(step, 40)})
		return call_outcome.fail(error, system.outcome_of_own_status(map_status), .Refused, .None, 0, i64(map_status))
	}

	// No bound counts the exits Interrupted: they come from the timer of the
	// host, and a bound on them refuses on a slow machine a build that a fast
	// one accepts. The bound of the spec counts the exits of the guest; a
	// guest that runs with no exit of its own runs until its caller stops it.
	input_writes_reported := u64(0)
	run_loop: for {
		run_error: errors.Error_Record
		exit, run_status := system.guest_run(resources.guest, &registers, &run_error)
		if run_status == .Bad_Operation && run_error.kind == i64(errors.Kind.Unsupported) {
			build_end(&resources)
			write_report(report, .Refused, .Nonzero_Guest_Exit)
			system.log_fact(.Info, Guests_Unsupported{})
			return call_outcome.fail(error, .Operation_Unsupported, .Unsupported, .None)
		}
		if run_status != .Ok {
			build_end(&resources)
			write_report(report, .Failed, .Nonzero_Guest_Exit)
			system.log_fact(.Error, Step_Failed{status_word = op.Status_Word(run_status), step = value_kinds.text_field("Guest_Run", 40)})
			return call_outcome.fail(error, system.outcome_of_own_status(run_status), .Refused, .None, 0, i64(run_status))
		}
		machine_exit := guest_os.Machine_Exit{kind = exit.kind, a = exit.a, b = exit.b, c = exit.c, next = exit.next, code = exit.code, information = exit.information}
		action := build_exit_handle(&sandbox_runner, &machine, &registers, machine_exit, &input_writes_reported)
		switch action {
		case .Run_Again:
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
