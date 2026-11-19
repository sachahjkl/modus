package machine

import "core:fmt"
import "modus:private/root/entropy_read_deadline"
import "modustool:build"
import "modustool:foundation"

// The machines that lack a part (src/md/features/missing_hardware.md):
// each one removes the part from QEMU, waits for the line that names it,
// and checks a later step that still works.
//
//   1. No display device (`-vga none`): the root service writes its line
//      and starts no input service, no compositor and no console; the boot
//      pass of `settings`, which needs the block service and the storage
//      service of the data disk, and `unlock` then run, and the start ends.
//      No step of this machine reads the screen.
//   2. No PS/2 controller (`-machine q35,i8042=off`): the input service
//      writes its line and stops, and the desktop comes up with the console.
//   3. An entropy device whose source never answers: the reads of the start
//      pass their deadline, count as refused, and the entropy service stops;
//      a process started after it shows the two refused reads.

TEST_OUTPUT_MISSING_DEVICES :: foundation.BUILD_FOLDER + "/test_output_missing_devices_%d.txt"

// The line of the root service on a machine with no screen.
NO_SCREEN_LINE :: "root: no screen: no console, no window; the other services start"
// The line of the input service on a machine with no PS/2 controller.
NO_PS2_CONTROLLER_LINE :: "input: no PS/2 controller: no keyboard and no mouse"
// The line of the root service when the two reads of the start of the
// entropy device pass their deadline (entropy_read_late_line).
ENTROPY_READ_LATE_LINE_FORMAT :: "root: the entropy device did not answer a read in %d seconds: 2 reads count as refused, and the entropy service stops: no more bytes of the device"
// The step that waits for that line: the deadline of the read from the
// start of the entropy service, then the start of the desktop on a loaded
// host, which runs the machine more slowly. It is larger than the deadline
// (a host test of the tool checks it).
ENTROPY_READ_LATE_STEP_SECONDS :: 300

// entropy_read_late_line gives the line of the deadline, with the deadline
// of the system: a change of the deadline changes the line that the test
// waits for. Not in the temporary allocator: the tool frees it after each
// step.
entropy_read_late_line :: proc() -> string {
	return fmt.aprintf(ENTROPY_READ_LATE_LINE_FORMAT, entropy_read_deadline.READ_DEADLINE_MILLISECONDS / 1000)
}

// Machine 1: no screen. The line comes before any process starts, and no
// compositor and no console start after it. The sign that the system runs
// comes from the steps that the root service takes after the place of the
// console: the boot pass of `settings` on a new data disk, through the
// block service and the storage service, then `unlock`, then the line of
// the end of the start. The tool ends QEMU: no console can stop the machine.
@(private = "file")
scenario_missing_devices_no_screen := [?]Step {
	{kind = .Wait, text = NO_SCREEN_LINE, fails_on = "compositor: ok "},
	{kind = .Wait, text = "settings: the boot pass: no settings kept: the defaults", any_order = true},
	{kind = .Wait, text = "root: settings stopped: itself, done", any_order = true},
	{kind = .Wait, text = "unlock: no named principal: the machine runs as principal 0, with no unlock", any_order = true},
	{kind = .Wait, text = "root: the machine is usable, by the start policy ", fails_on = "root: started console"},
	{kind = .Quit},
}

// Machine 2: no PS/2 controller. The input service finds a status port of
// all ones, writes its line and stops; the desktop comes up with the
// console, with no keyboard and no mouse. The tool ends QEMU: no key can
// reach the console.
@(private = "file")
scenario_missing_devices_no_ps2_controller := [?]Step {
	{kind = .Wait, text = NO_PS2_CONTROLLER_LINE, fails_on = "input: ok, "},
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "root: the machine is usable, by the start policy ", any_order = true},
	{kind = .Quit},
}

// Machine 3: an entropy device that takes each read and never ends it. The
// desktop comes up before the deadline; then the line of the deadline
// (missing_devices_silent_entropy_run puts its step between these two);
// after it, a process starts and shows the reads of the start as refused,
// with no byte of the device.
@(private = "file")
scenario_missing_devices_silent_entropy_start := [?]Step {
	{kind = .Wait, text = "root: started entropy for the device at the place 19 of the bus", any_order = true},
	{kind = .Wait, text = "entropy: ok, a queue of ", any_order = true},
	{kind = .Wait, text = "compositor: surface console", any_order = true},
}

@(private = "file")
scenario_missing_devices_silent_entropy_after := [?]Step {
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"randomness\")"},
	{kind = .Wait, text = "randomness: the entropy device: 0 bytes mixed after the gathering; refused reads: 2"},
	{kind = .Wait, text = "randomness: the generator: 4 MiB in "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// missing_devices_silent_entropy_run runs machine 3, with the line of the
// deadline built from the deadline of the system.
@(private = "file")
missing_devices_silent_entropy_run :: proc(part: ^Test_Part_Run) -> bool {
	// Not in the temporary allocator: the tool frees it after each step.
	all := make([dynamic]Step)
	defer delete(all)
	late_line := entropy_read_late_line()
	defer delete(late_line)
	append(&all, ..scenario_missing_devices_silent_entropy_start[:])
	append(&all, Step{kind = .Wait, text = late_line, seconds = ENTROPY_READ_LATE_STEP_SECONDS, fails_on = "root: the entropy device gave "})
	append(&all, ..scenario_missing_devices_silent_entropy_after[:])
	return machine_test(part, all[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_MISSING_DEVICES, 3), exit_status = build.MACHINE_STOP_OK, entropy_device_silent = true})
}

missing_devices_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	// The tool ends QEMU of machines 1 and 2: status 0.
	machine_test(part, scenario_missing_devices_no_screen[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_MISSING_DEVICES, 1), exit_status = 0, without_screen = true}) or_return
	foundation.test_passed_print("%s", "no screen: the root service started no compositor and no console, and the settings, the storage and unlock ran")
	machine_test(part, scenario_missing_devices_no_ps2_controller[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_MISSING_DEVICES, 2), exit_status = 0, without_ps2_controller = true}) or_return
	foundation.test_passed_print("%s", "no PS/2 controller: the input service stopped with its line, and the desktop came up")
	missing_devices_silent_entropy_run(part) or_return
	foundation.test_passed_print("%s", "an entropy device that never answers: its reads passed their deadline and counted as refused, and a process started after it")
	return true
}
