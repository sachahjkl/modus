// One build in a Linux guest, from a checked spec to the end of its run
// (src/md/features/recipes.md, "The guest builder"): the memory of the
// guest, the kernel and the initial archive copied there and checked by
// their hashes, the boot, the guest process, and the loop that answers each
// exit with the machine of modus:contract/guest_os and the runner of
// modus:contract/guest_builder. The module guest_builder and the service
// recipes run their builds with it, so the two never answer an exit in two
// ways.
package guest_regions

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/errors"
import gb "modus:contract/guest_builder"
import "modus:contract/guest_os"
import op "modus:contract/operation"
import "modus:system"

// The name of the guest process of a build in the reports of the kernel.
GUEST_BUILD_PROCESS_NAME :: "guest build"

// What the loop of a build does after one exit.
Build_Exit_Action :: enum u8 {
	Run_Again = 1,
	End       = 4, // The run ended: the state of the runner says how.
}

// build_exit_handle answers one exit of a build: the bound of the exits,
// the machine of the guest, then the ports of the runner (the frozen clock,
// the exit status, the trap of a network device), the read-only disk, whose
// first refused write refuses the build, and the bound of the output disk,
// whose first write past it refuses the build.
build_exit_handle :: proc "contextless" (runner: ^gb.Guest_Sandbox_Runner, linux: ^guest_os.Linux_Machine, registers: ^op.Guest_Registers, exit: guest_os.Machine_Exit, input_writes_reported: ^u64) -> Build_Exit_Action {
	if !gb.runner_exit_counted(runner, exit.kind) {
		return .End
	}
	action := Build_Exit_Action.Run_Again
	switch guest_os.linux_machine_handle_exit(linux, registers, exit) {
	case .Continue:
	case .Not_Handled:
		if !gb.runner_answer_exit(runner, registers, exit.kind, exit.a, exit.b, exit.c, exit.next) {
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
		gb.runner_report_violation(runner, .Read_Only_Disk_Write)
		return .End
	}
	if linux.devices[.Output_Disk].writes_past_bound > 0 {
		gb.runner_report_violation(runner, .Output_Size_Exceeded)
		return .End
	}
	return action
}

// initial_archive_stage copies the initial archive to the place that the
// boot gives it in the memory of the guest, under ceiling, and checks its
// size and its hash there: a caller that shares its memory can change the
// source, not the copy. A refused archive leaves no byte of it in the memory
// of the guest.
initial_archive_stage :: proc "contextless" (ram: []u8, parsed: guest_os.Linux_Image, ceiling: u64, spec: ^gb.Guest_Build_Spec, source: rawptr, count: u64) -> (archive: []u8, refusal: gb.Guest_Builder_Refusal) {
	if gb.hash_is_zero(spec.initial_archive_hash) {
		if count != 0 || spec.initial_archive_size != 0 {
			return nil, .Initial_Archive_Size_Invalid
		}
		return nil, .None
	}
	if count > gb.MAX_INITIAL_ARCHIVE_BYTES {
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
	if refusal = gb.initial_archive_check(spec, archive); refusal != .None {
		intrinsics.mem_zero(raw_data(archive), int(count))
		return nil, refusal
	}
	return archive, .None
}

// How a guest build ended, past what the runner says.
Guest_Build_End :: enum u8 {
	Ran           = 0, // The guest ran: the state of the runner says how it ended.
	Refused       = 1, // A check before the run refused the build: the refusal of the runner says which.
	Unsupported   = 2, // The processors of the machine have no guest support that the kernel uses.
	Kernel_Failed = 3, // A kernel operation failed: the status and the step say which.
}

// The part of the build that a refusal before the run names.
Guest_Build_Part :: enum u8 {
	None            = 0,
	Spec            = 1,
	Kernel          = 2,
	Initial_Archive = 3,
}

// The end of one guest build, for the log and the error record of its
// caller.
Guest_Build_Outcome :: struct {
	end:              Guest_Build_End,
	refused_part:     Guest_Build_Part,
	boot_refusal:     guest_os.Linux_Boot_Refusal,
	status:           system.Status,
	step:             string,
	output_disk_hash: blake3.Hash, // The BLAKE3 hash of the whole output disk after the run.
}

// guest_build_run boots the kernel of spec in a new guest and runs it until
// the runner ends. The runner is prepared on input_disk and output_disk and
// started; kernel and initial_archive are the bytes that the spec names by
// their hashes, which the run checks on its own copies. The memory of the
// guest is spec.memory_pages pages from the budget of the caller, given back
// before the return. A refusal before the run leaves the runner Refused with
// its refusal. The guest stops before the return, so the caller reads the
// output disk with no instruction of the guest running.
guest_build_run :: proc "contextless" (runner: ^gb.Guest_Sandbox_Runner, machine: ^guest_os.Linux_Machine, spec: ^gb.Guest_Build_Spec, kernel: []u8, initial_archive: []u8, input_disk: []u8, output_disk: []u8) -> (outcome: Guest_Build_Outcome) {
	refuse :: proc "contextless" (runner: ^gb.Guest_Sandbox_Runner, outcome: ^Guest_Build_Outcome, refusal: gb.Guest_Builder_Refusal, part: Guest_Build_Part) -> Guest_Build_Outcome {
		runner.state = .Refused
		if runner.refusal == .None {
			runner.refusal = refusal
		}
		outcome.end = .Refused
		outcome.refused_part = part
		return outcome^
	}
	kernel_failed :: proc "contextless" (runner: ^gb.Guest_Sandbox_Runner, outcome: ^Guest_Build_Outcome, status: system.Status, step: string) -> Guest_Build_Outcome {
		runner.state = .Failed
		if runner.refusal == .None {
			runner.refusal = .Nonzero_Guest_Exit
		}
		outcome.end = .Kernel_Failed
		outcome.status = status
		outcome.step = step
		return outcome^
	}
	memory_bytes := spec.memory_pages * system.PAGE_SIZE
	staging_bytes, staging_fits := kernel_staging_bytes(u64(len(kernel)), memory_bytes)
	if !staging_fits {
		return refuse(runner, &outcome, .Memory_Too_Small, .Kernel)
	}
	staging := memory_bytes - staging_bytes
	ram, status := owned_memory_make(memory_bytes)
	if status != .Ok {
		return kernel_failed(runner, &outcome, status, "Memory_Create of the guest memory")
	}
	defer owned_memory_end(&ram)
	guest_ram := ram.bytes[:memory_bytes]
	kernel_copy := guest_ram[staging:][:len(kernel)]
	copy(kernel_copy, kernel)
	// The hash is of the copy, which no other process can change.
	if blake3.hash(kernel_copy) != spec.kernel_hash {
		return refuse(runner, &outcome, .Malformed_Disk_Image, .Kernel)
	}
	parsed, boot_refusal := guest_os.linux_image_parse(kernel_copy, memory_bytes)
	if boot_refusal == .None && parsed.load_end > staging {
		boot_refusal = .Memory_Too_Small
	}
	if boot_refusal != .None {
		outcome.boot_refusal = boot_refusal
		return refuse(runner, &outcome, boot_refusal == .Memory_Too_Small ? .Memory_Too_Small : .Malformed_Disk_Image, .Kernel)
	}
	// The initial archive goes below the copy of the image, checked there.
	archive, archive_refusal := initial_archive_stage(guest_ram, parsed, staging, spec, raw_data(initial_archive), u64(len(initial_archive)))
	if archive_refusal != .None {
		return refuse(runner, &outcome, archive_refusal, .Initial_Archive)
	}
	guest_memory := guest_os.Guest_Memory{guest_ram}
	guest_os.linux_machine_start(machine, guest_memory, input_disk, output_disk)
	places := guest_os.linux_machine_places()
	registers, start_refusal := guest_os.linux_boot_prepare(guest_memory, kernel_copy, parsed, places[:], spec.command[:spec.command_length], archive, staging)
	if start_refusal != .None {
		outcome.boot_refusal = start_refusal
		return refuse(runner, &outcome, .Invalid_Command_Text, .Spec)
	}
	// The image leaves the memory of the guest: a build sees the same bytes
	// whatever was staged there.
	intrinsics.mem_zero(raw_data(kernel_copy), int(staging_bytes))

	// The guest process: its nested page table holds the memory of the
	// guest only. Past it, each address is a device of the machine.
	name := GUEST_BUILD_PROCESS_NAME
	created, create_status := system.call(.Process_Create, u64(system.own_budget()), u64(uintptr(raw_data(name))), u64(len(name)))
	if create_status != .Ok {
		return kernel_failed(runner, &outcome, create_status, "Process_Create of the guest")
	}
	guest := system.Handle(created[0])
	defer system.close(guest)
	if map_status, step := map_memory(guest, ram.handle, memory_bytes); map_status != .Ok {
		_ = system.process_stop(guest)
		return kernel_failed(runner, &outcome, map_status, step)
	}

	// No bound counts the exits Interrupted: they come from the timer of the
	// host, and a bound on them refuses on a slow machine a build that a fast
	// one accepts. The bound of the spec counts the exits of the guest, and
	// it is the hang bound of a build: the runner ends Timed_Out past it.
	input_writes_reported := u64(0)
	run_loop: for {
		run_error: errors.Error_Record
		exit, run_status := system.guest_run(guest, &registers, &run_error)
		if run_status == .Bad_Operation && run_error.kind == i64(errors.Kind.Unsupported) {
			_ = system.process_stop(guest)
			runner.state = .Refused
			if runner.refusal == .None {
				runner.refusal = .Nonzero_Guest_Exit
			}
			outcome.end = .Unsupported
			return outcome
		}
		if run_status != .Ok {
			_ = system.process_stop(guest)
			return kernel_failed(runner, &outcome, run_status, "Guest_Run")
		}
		machine_exit := guest_os.Machine_Exit{kind = exit.kind, a = exit.a, b = exit.b, c = exit.c, next = exit.next, code = exit.code, information = exit.information}
		switch build_exit_handle(runner, machine, &registers, machine_exit, &input_writes_reported) {
		case .Run_Again:
		case .End:
			break run_loop
		}
	}
	// Stop the guest before the output disk is read: no instruction of the
	// guest runs after process_stop returns.
	_ = system.process_stop(guest)
	outcome.output_disk_hash = blake3.hash(output_disk)
	outcome.end = .Ran
	return outcome
}
