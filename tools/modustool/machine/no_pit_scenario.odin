package machine

import "modustool:build"
import "modustool:foundation"

// The machine with no time base (src/md/features/missing_hardware.md): no
// 8254 (`-machine q35,pit=off`), and a processor whose highest leaf of
// CPUID is below leaf 0x15, so it states no frequency of its cycle counter
// on any host. The kernel finds both, writes its line and stops with the
// code Start_Failed, in place of a hang of the first processor. A
// processor that states its frequency would start the machine with the
// cycle counter as its time base; QEMU fills no leaf 0x15 on every host,
// so the host tests of src/kernel/time_base hold that path.

TEST_OUTPUT_NO_PIT :: foundation.BUILD_FOLDER + "/test_output_no_pit.txt"

// The status of QEMU when the kernel stops the machine with code 1,
// Start_Failed.
MACHINE_STOP_START_FAILED :: 1 << 1 | 1

@(rodata)
scenario_no_pit := [?]Step {
	// The last line of the kernel before the calibration: the kernel ran
	// up to the wait for the 8254.
	{kind = .Wait, text = "kernel: control registers: cr0 "},
	{kind = .Wait, text = "kernel: the 8254 does not count, and the processor states no frequency of its cycle counter (CPUID has no leaf 0x15): the kernel has no time base"},
}

no_pit_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	return machine_test(part, scenario_no_pit[:], {volume = build.BOOT_VOLUME, output = TEST_OUTPUT_NO_PIT, exit_status = MACHINE_STOP_START_FAILED, processor = .Without_Frequency_Leaves, without_pit = true})
}
