#+build !freestanding
package guest_builder_module

import "core:testing"
import "modus:contract/blake3"
import contract "modus:contract/guest_builder"
import "modus:contract/guest_os"
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

// The region of a mapping of the memory of the guest: 2 MiB, and more past
// GUEST_REGIONS_MOST regions, so that the mappings of a guest stay under the
// capacity of a process.
@(test)
guest_region_sizes :: proc(t: ^testing.T) {
	testing.expect_value(t, guest_region_bytes(0), GUEST_REGION_BYTES_LEAST)
	testing.expect_value(t, guest_region_bytes(64 * 1024 * 1024), GUEST_REGION_BYTES_LEAST)
	testing.expect_value(t, guest_region_bytes(GUEST_REGIONS_MOST * GUEST_REGION_BYTES_LEAST), GUEST_REGION_BYTES_LEAST)
	testing.expect_value(t, guest_region_bytes(GUEST_REGIONS_MOST * GUEST_REGION_BYTES_LEAST + 1), 2 * GUEST_REGION_BYTES_LEAST)
	for pages in ([?]u64{16, 16_384, 65_535, GUEST_MEMORY_PAGES_MOST}) {
		bytes := pages * 4096
		region := guest_region_bytes(bytes)
		testing.expect(t, region % GUEST_REGION_BYTES_LEAST == 0)
		testing.expectf(t, (bytes + region - 1) / region <= GUEST_REGIONS_MOST, "%v pages make at most %v regions", pages, GUEST_REGIONS_MOST)
	}
	testing.expect(t, MODULE_BUDGET.working_memory_pages >= GUEST_MEMORY_PAGES_MOST + INPUT_DISK_BYTES_MOST / 4096 + OUTPUT_DISK_BYTES_MOST / 4096)
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
	action := build_exit_handle(runner, linux, &registers, {kind = .Port_Write, a = 0x3F8, b = 1, c = 'x', next = 0x1001}, &reported)
	testing.expect_value(t, action, Build_Exit_Action.Run_Again)
	testing.expect_value(t, linux.serial.captured, u32(1))
	action = build_exit_handle(runner, linux, &registers, {kind = .Port_Read, a = u64(contract.Guest_Io_Port.Frozen_Clock_Low), b = 4, next = 0x1002}, &reported)
	testing.expect_value(t, action, Build_Exit_Action.Run_Again)
	testing.expect_value(t, registers.rip, u64(0x1002))
	testing.expect_value(t, runner.guest_exits_handled, u64(2))
	// With no memory, the address 0x10 is past the memory: a device access
	// whose instruction is on no page. The machine stops the guest.
	action = build_exit_handle(runner, linux, &registers, {kind = .Memory, a = 0x10, b = guest_os.FAULT_ACCESS_WRITE}, &reported)
	testing.expect_value(t, action, Build_Exit_Action.End)
	testing.expect_value(t, runner.state, contract.Guest_Build_State.Failed)

	// A write to the read-only disk ends the build with a violation.
	test_runner(runner, output[:])
	guest_os.linux_machine_start(linux, {}, input[:], output[:])
	linux.devices[.Input_Disk].writes_refused = 1
	action = build_exit_handle(runner, linux, &registers, {kind = .Interrupted}, &reported)
	testing.expect_value(t, action, Build_Exit_Action.End)
	testing.expect_value(t, runner.state, contract.Guest_Build_State.Refused)
	testing.expect_value(t, runner.sandbox_violations, u64(1))
	testing.expect_value(t, runner.refusal, contract.Guest_Builder_Refusal.Writable_Input_Forbidden)
	tree: [64]u8
	_, written, refusal := contract.runner_finish(runner, &unpack_workspace, tree[:])
	testing.expect(t, written == 0 && refusal == .Writable_Input_Forbidden)

	// The trap of a network device refuses the build.
	test_runner(runner, output[:])
	guest_os.linux_machine_start(linux, {}, input[:], output[:])
	reported = 0
	action = build_exit_handle(runner, linux, &registers, {kind = .Port_Write, a = u64(contract.Guest_Io_Port.Network_Device_Trap), b = 4, next = 0x1004}, &reported)
	testing.expect_value(t, action, Build_Exit_Action.End)
	testing.expect_value(t, runner.state, contract.Guest_Build_State.Refused)

	// A guest that stops with no exit status fails the build.
	test_runner(runner, output[:])
	guest_os.linux_machine_start(linux, {}, input[:], output[:])
	registers.rflags = 0x2
	action = build_exit_handle(runner, linux, &registers, {kind = .Halt, next = 0x1005}, &reported)
	testing.expect_value(t, action, Build_Exit_Action.End)
	testing.expect_value(t, runner.state, contract.Guest_Build_State.Failed)

	// The bound of the exits counts the exits of the guest: cpuid here.
	test_runner(runner, output[:], 2)
	guest_os.linux_machine_start(linux, {}, input[:], output[:])
	testing.expect_value(t, build_exit_handle(runner, linux, &registers, {kind = .Cpuid, next = 0x1006}, &reported), Build_Exit_Action.Run_Again)
	testing.expect_value(t, build_exit_handle(runner, linux, &registers, {kind = .Cpuid, next = 0x1007}, &reported), Build_Exit_Action.Run_Again)
	testing.expect_value(t, build_exit_handle(runner, linux, &registers, {kind = .Cpuid, next = 0x1008}, &reported), Build_Exit_Action.End)
	testing.expect_value(t, runner.state, contract.Guest_Build_State.Timed_Out)
	testing.expect_value(t, runner.guest_exits_handled, u64(2))

	// The successful case last: the exit status 0 ends the run cleanly.
	test_runner(runner, output[:])
	guest_os.linux_machine_start(linux, {}, input[:], output[:])
	action = build_exit_handle(runner, linux, &registers, {kind = .Port_Write, a = u64(contract.Guest_Io_Port.Build_Exit_Status), b = 4, c = 0, next = 0x1008}, &reported)
	testing.expect_value(t, action, Build_Exit_Action.End)
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
		testing.expect_value(t, build_exit_handle(runner, linux, &registers, {kind = .Cpuid, next = 0x1002}, &reported), Build_Exit_Action.Run_Again)
		for _ in 0 ..< interrupts {
			if build_exit_handle(runner, linux, &registers, {kind = .Interrupted}, &reported) != .Run_Again {
				testing.fail_now(t, "an exit Interrupted ended the build")
			}
		}
		action := build_exit_handle(runner, linux, &registers, {kind = .Port_Write, a = u64(contract.Guest_Io_Port.Build_Exit_Status), b = 4, c = 0, next = 0x1004}, &reported)
		testing.expect_value(t, action, Build_Exit_Action.End)
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

// A kernel count past the memory of the guest is refused before the
// rounding to a page, so no count wraps the size of the copy to 0.
@(test)
kernel_staging_refuses_counts_past_memory :: proc(t: ^testing.T) {
	memory := u64(64 * 1024 * 1024)
	for count in ([?]u64{0, max(u64), max(u64) - 10, max(u64) - 4095, memory, memory - 1, memory + 1}) {
		staging, fits := kernel_staging_bytes(count, memory)
		testing.expectf(t, !fits && staging == 0, "the count %v is refused", count)
	}
	_, empty_fits := kernel_staging_bytes(1, 0)
	testing.expect(t, !empty_fits)
	staging, fits := kernel_staging_bytes(1, memory)
	testing.expect(t, fits && staging == 4096)
	staging, fits = kernel_staging_bytes(memory - 4096, memory)
	testing.expect(t, fits && staging == memory - 4096)
}

// Inside the memory of the guest, a fault asks for a switch of its region:
// a write gives Write, an instruction fetch gives Execute.
@(test)
build_exit_region_switch :: proc(t: ^testing.T) {
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
	testing.expect_value(t, build_exit_handle(runner, linux, &registers, {kind = .Memory, a = 0x8_0000, b = guest_os.FAULT_ACCESS_WRITE | 1}, &reported), Build_Exit_Action.Switch_Write)
	testing.expect_value(t, linux.switch_address, u64(0x8_0000))
	testing.expect_value(t, build_exit_handle(runner, linux, &registers, {kind = .Memory, a = 0x9_0000, b = guest_os.FAULT_ACCESS_EXECUTE | 1}, &reported), Build_Exit_Action.Switch_Execute)
	testing.expect_value(t, linux.switch_address, u64(0x9_0000))
	testing.expect_value(t, runner.state, contract.Guest_Build_State.Running)
}
