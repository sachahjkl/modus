#+build !freestanding
package guest_builder_module

import "core:testing"
import "modus:contract/blake3"
import contract "modus:contract/guest_builder"
import "modus:contract/guest_os"
import "modus:guest_regions"
import op "modus:contract/operation"

// test_runner prepares a running build on an output disk of 4 KiB, with no
// input disk.
test_runner :: proc(runner: ^contract.Guest_Sandbox_Runner, output: []u8, max_exits: u64 = 0) {
	spec: contract.Guest_Build_Spec
	spec.kernel_hash = blake3.hash([]u8{1})
	spec.root_image_hash = blake3.hash([]u8{2})
	spec.memory_pages = 16_384
	spec.output_size_bound = u64(len(output))
	spec.max_guest_exits = max_exits
	contract.build_spec_set_command(&spec, "true")
	refusal := contract.runner_prepare(runner, &spec, nil, nil, output)
	assert(refusal == .None)
	assert(contract.runner_start(runner) == .None)
}

// The default budget pays the default guest memory and disks, while the
// contract bounds allow multi-GiB guests when a starter grants a larger budget.
@(test)
budget_holds_the_guest_and_the_disks :: proc(t: ^testing.T) {
	testing.expect(t, MODULE_BUDGET.working_memory_pages >= DEFAULT_GUEST_MEMORY_PAGES + DEFAULT_INPUT_DISK_PAGES + DEFAULT_OUTPUT_DISK_PAGES)
	testing.expect(t, GUEST_MEMORY_PAGES_MOST >= 4_194_304)
	testing.expect(t, INPUT_DISK_BYTES_MOST >= 1024 * 1024 * 1024)
	testing.expect(t, OUTPUT_DISK_BYTES_MOST >= 1024 * 1024 * 1024)
}

// The loop of a build: the machine answers its devices, the runner answers
// the ports of the build, a write to the read-only disk refuses the build,
// a stopped guest fails it, and the bound of the exits ends it.
@(test)
build_exit_dispatch :: proc(t: ^testing.T) {
	runner := new(contract.Guest_Sandbox_Runner)
	defer free(runner)
	linux := new(guest_os.Linux_Machine)
	defer free(linux)
	output: [4096]u8
	input: [1024]u8
	reported := u64(0)
	registers := op.Guest_Registers{rip = 0x1000}

	// The serial port goes to the machine; the frozen clock to the runner.
	test_runner(runner, output[:])
	guest_os.linux_machine_start(linux, {}, input[:], output[:])
	action := guest_regions.build_exit_handle(runner, linux, &registers, {kind = .Port_Write, a = 0x3F8, b = 1, c = 'x', next = 0x1001}, &reported)
	testing.expect_value(t, action, guest_regions.Build_Exit_Action.Run_Again)
	testing.expect_value(t, linux.serial.captured, u32(1))
	action = guest_regions.build_exit_handle(runner, linux, &registers, {kind = .Port_Read, a = u64(contract.Guest_Io_Port.Frozen_Clock_Low), b = 4, next = 0x1002}, &reported)
	testing.expect_value(t, action, guest_regions.Build_Exit_Action.Run_Again)
	testing.expect_value(t, registers.rip, u64(0x1002))
	testing.expect_value(t, runner.guest_exits_handled, u64(2))
	// With no memory, the address 0x10 is past the memory: a device access
	// whose instruction is on no page. The machine stops the guest.
	action = guest_regions.build_exit_handle(runner, linux, &registers, {kind = .Memory, a = 0x10, b = guest_os.FAULT_ACCESS_WRITE}, &reported)
	testing.expect_value(t, action, guest_regions.Build_Exit_Action.End)
	testing.expect_value(t, runner.state, contract.Guest_Build_State.Failed)

	// A write to the read-only disk ends the build with a violation.
	test_runner(runner, output[:])
	guest_os.linux_machine_start(linux, {}, input[:], output[:])
	linux.devices[.Input_Disk].writes_refused = 1
	action = guest_regions.build_exit_handle(runner, linux, &registers, {kind = .Interrupted}, &reported)
	testing.expect_value(t, action, guest_regions.Build_Exit_Action.End)
	testing.expect_value(t, runner.state, contract.Guest_Build_State.Refused)
	testing.expect_value(t, runner.sandbox_violations, u64(1))
	testing.expect_value(t, runner.refusal, contract.Guest_Builder_Refusal.Writable_Input_Forbidden)
	tree: [64]u8
	_, written, refusal := contract.runner_finish(runner, &unpack_workspace, tree[:])
	testing.expect(t, written == 0 && refusal == .Writable_Input_Forbidden)

	// A write past the bound of the output disk ends the build: the output
	// is too large.
	test_runner(runner, output[:])
	guest_os.linux_machine_start(linux, {}, input[:], output[:])
	reported = 0
	linux.devices[.Output_Disk].writes_past_bound = 1
	action = guest_regions.build_exit_handle(runner, linux, &registers, {kind = .Interrupted}, &reported)
	testing.expect_value(t, action, guest_regions.Build_Exit_Action.End)
	testing.expect_value(t, runner.state, contract.Guest_Build_State.Refused)
	testing.expect_value(t, runner.sandbox_violations, u64(1))

	// The trap of a network device refuses the build.
	test_runner(runner, output[:])
	guest_os.linux_machine_start(linux, {}, input[:], output[:])
	reported = 0
	action = guest_regions.build_exit_handle(runner, linux, &registers, {kind = .Port_Write, a = u64(contract.Guest_Io_Port.Network_Device_Trap), b = 4, next = 0x1004}, &reported)
	testing.expect_value(t, action, guest_regions.Build_Exit_Action.End)
	testing.expect_value(t, runner.state, contract.Guest_Build_State.Refused)

	// A guest that stops with no exit status fails the build.
	test_runner(runner, output[:])
	guest_os.linux_machine_start(linux, {}, input[:], output[:])
	registers.rflags = 0x2
	action = guest_regions.build_exit_handle(runner, linux, &registers, {kind = .Halt, next = 0x1005}, &reported)
	testing.expect_value(t, action, guest_regions.Build_Exit_Action.End)
	testing.expect_value(t, runner.state, contract.Guest_Build_State.Failed)

	// The bound of the exits counts the exits of the guest: cpuid here.
	test_runner(runner, output[:], 2)
	guest_os.linux_machine_start(linux, {}, input[:], output[:])
	testing.expect_value(t, guest_regions.build_exit_handle(runner, linux, &registers, {kind = .Cpuid, next = 0x1006}, &reported), guest_regions.Build_Exit_Action.Run_Again)
	testing.expect_value(t, guest_regions.build_exit_handle(runner, linux, &registers, {kind = .Cpuid, next = 0x1007}, &reported), guest_regions.Build_Exit_Action.Run_Again)
	testing.expect_value(t, guest_regions.build_exit_handle(runner, linux, &registers, {kind = .Cpuid, next = 0x1008}, &reported), guest_regions.Build_Exit_Action.End)
	testing.expect_value(t, runner.state, contract.Guest_Build_State.Timed_Out)
	testing.expect_value(t, runner.guest_exits_handled, u64(2))

	// The successful case last: the exit status 0 ends the run cleanly.
	test_runner(runner, output[:])
	guest_os.linux_machine_start(linux, {}, input[:], output[:])
	action = guest_regions.build_exit_handle(runner, linux, &registers, {kind = .Port_Write, a = u64(contract.Guest_Io_Port.Build_Exit_Status), b = 4, c = 0, next = 0x1008}, &reported)
	testing.expect_value(t, action, guest_regions.Build_Exit_Action.End)
	testing.expect(t, runner.guest_exited && runner.guest_exit_code == 0 && runner.state == .Running)
}

// The exits Interrupted come from the timer of the host: many of them, more
// than any bound of the spec, neither end the build nor change its count of
// exits. Two runs with a different count of host interrupts report the same
// count of exits.
@(test)
build_exit_host_interrupts_not_counted :: proc(t: ^testing.T) {
	runner := new(contract.Guest_Sandbox_Runner)
	defer free(runner)
	linux := new(guest_os.Linux_Machine)
	defer free(linux)
	output: [4096]u8
	input: [1024]u8

	exits_of_run :: proc(t: ^testing.T, runner: ^contract.Guest_Sandbox_Runner, linux: ^guest_os.Linux_Machine, input, output: []u8, interrupts: int) -> u64 {
		reported := u64(0)
		registers := op.Guest_Registers{rip = 0x1000}
		test_runner(runner, output, 4)
		guest_os.linux_machine_start(linux, {}, input, output)
		testing.expect_value(t, guest_regions.build_exit_handle(runner, linux, &registers, {kind = .Cpuid, next = 0x1002}, &reported), guest_regions.Build_Exit_Action.Run_Again)
		for _ in 0 ..< interrupts {
			if guest_regions.build_exit_handle(runner, linux, &registers, {kind = .Interrupted}, &reported) != .Run_Again {
				testing.fail_now(t, "an exit Interrupted ended the build")
			}
		}
		action := guest_regions.build_exit_handle(runner, linux, &registers, {kind = .Port_Write, a = u64(contract.Guest_Io_Port.Build_Exit_Status), b = 4, c = 0, next = 0x1004}, &reported)
		testing.expect_value(t, action, guest_regions.Build_Exit_Action.End)
		testing.expect(t, runner.guest_exited && runner.guest_exit_code == 0 && runner.state == .Running)
		return runner.guest_exits_handled
	}

	quiet := exits_of_run(t, runner, linux, input[:], output[:], 0)
	busy := exits_of_run(t, runner, linux, input[:], output[:], 1001)
	busier := exits_of_run(t, runner, linux, input[:], output[:], 5000)
	testing.expect_value(t, quiet, u64(2))
	testing.expect_value(t, busy, quiet)
	testing.expect_value(t, busier, quiet)
	tree: [64]u8
	_, _, refusal := contract.runner_finish(runner, &unpack_workspace, tree[:])
	testing.expect(t, refusal != .Nonzero_Guest_Exit)
}

// A guest that never exits by itself, as cli then jmp to itself, gives only
// exits Interrupted: the time of the system ends the build at the deadline
// of its spec with Timed_Out, which the bound of the exits never would.
@(test)
build_of_interrupts_only_ends_at_its_deadline :: proc(t: ^testing.T) {
	runner := new(contract.Guest_Sandbox_Runner)
	defer free(runner)
	linux := new(guest_os.Linux_Machine)
	defer free(linux)
	output: [4096]u8
	input: [1024]u8
	reported := u64(0)
	registers := op.Guest_Registers{rip = 0x1000}
	test_runner(runner, output[:], 4)
	guest_os.linux_machine_start(linux, {}, input[:], output[:])
	START :: u64(1_000_000_000)
	contract.runner_deadline_from(runner, START)
	bound := contract.build_time_bound_nanoseconds(&runner.spec)
	// Many interrupts, each a little later, all before the deadline.
	for step in u64(0) ..< 10_000 {
		contract.runner_clock_advance(runner, START + step * (bound / 10_001))
		if guest_regions.build_exit_handle(runner, linux, &registers, {kind = .Interrupted}, &reported) != .Run_Again {
			testing.fail_now(t, "an exit before the deadline ended the build")
		}
	}
	contract.runner_clock_advance(runner, START + bound)
	testing.expect_value(t, guest_regions.build_exit_handle(runner, linux, &registers, {kind = .Interrupted}, &reported), guest_regions.Build_Exit_Action.End)
	testing.expect_value(t, runner.state, contract.Guest_Build_State.Timed_Out)
	testing.expect_value(t, runner.guest_exits_handled, u64(0))
	testing.expect_value(t, runner.guest_runs, u64(10_001))
}

// Inside the memory of the guest, a fault reaches the process only when the
// kernel refused it (the kernel switches each page itself): the build fails.
@(test)
build_exit_memory_refused :: proc(t: ^testing.T) {
	runner := new(contract.Guest_Sandbox_Runner)
	defer free(runner)
	linux := new(guest_os.Linux_Machine)
	defer free(linux)
	ram := make([]u8, 1024 * 1024)
	defer delete(ram)
	output: [4096]u8
	reported := u64(0)
	registers := op.Guest_Registers{}
	test_runner(runner, output[:])
	guest_os.linux_machine_start(linux, {ram}, nil, output[:])
	testing.expect_value(t, guest_regions.build_exit_handle(runner, linux, &registers, {kind = .Memory, a = 0x8_0000, b = guest_os.FAULT_ACCESS_WRITE | 1}, &reported), guest_regions.Build_Exit_Action.End)
	testing.expect_value(t, linux.failure, guest_os.Machine_Failure.Memory_Refused)
	testing.expect_value(t, runner.state, contract.Guest_Build_State.Failed)
}
