package machine

import "core:fmt"
import "modus:private/root/entropy_read_deadline"
import "modustool:build"
import "modustool:foundation"

// The machines that lack a part (src/md/features/missing_hardware.md):
// each one removes the part from QEMU, waits for the line that names it,
// and checks a later step that still works.
//
//   1. With a screen, Secure Boot and a software TPM, on a new disk:
//      `machine_seal()` seals the machine key by the TPM, and the console
//      allows the client key of the peer, which the disk grant table of
//      principal 0 keeps.
//   2. The same disk and the same TPM with no display device (`-vga none`):
//      the root service starts no console, writes its line and starts
//      `remote`; the TPM releases the machine key with no typing, the table
//      gives back the client key; a call to the compositor, which never
//      started, is refused, and a call that starts the storage service
//      runs. No step of this machine reads the screen.
//   3. No PS/2 controller (`-machine q35,i8042=off`): the input service
//      writes its line and stops, and the desktop comes up with the console.
//   4. An entropy device whose source never answers: the reads of the start
//      pass their deadline, count as refused, and the entropy service stops;
//      a process started after it shows the two refused reads.

TEST_MISSING_DEVICES_DISK :: foundation.BUILD_FOLDER + "/test_missing_devices_disk.img"
TEST_OUTPUT_MISSING_DEVICES :: foundation.BUILD_FOLDER + "/test_output_missing_devices_%d.txt"
// The state of the software TPM that machines 1 and 2 share.
MISSING_DEVICES_TPM_STATE_FOLDER :: foundation.BUILD_FOLDER + "/test_missing_devices_tpm_state"

// The line of the root service on a machine with no screen.
NO_SCREEN_LINE :: "root: no screen: no console; remote calls still reach the system"
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

// The start of a machine of the TPM with Secure Boot, to the line of the
// limits of the TPM: the boot program measures the system, and the root
// service starts the TPM service.
@(private = "file")
missing_devices_tpm_start := [?]Step {
	{kind = .Wait, text = "boot program: started", seconds = TPM_MACHINE_FIRST_WAIT_SECONDS},
	{kind = .Wait, text = SECURE_BOOT_VERIFIED_LINE, seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = MEASURE_LINE, fails_on = MEASURE_REFUSED_LINE, seconds = TPM_MACHINE_STEP_SECONDS},
}

// Machine 1: the seal, the recovery key written down with Enter, then the
// client key of the peer, allowed by principal 0, whose disk grant table
// the machine key now keeps on the disk.
@(private = "file")
scenario_missing_devices_seal_and_allow := [?]Step {
	{kind = .Wait, text = "root: started tpm for the TPM at ", any_order = true, seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = "tpm: ok, the CRB interface at ", any_order = true, seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = TPM_COUNT_LIMITS_LINE, any_order = true},
	{kind = .Wait, text = "compositor: surface console", any_order = true, seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = "unlock: no named principal: the machine runs as principal 0, with no unlock", any_order = true},
	{kind = .Wait, text = "root: unlock stopped with code 0", any_order = true},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "machine_seal()"},
	{kind = .Wait, text = "root: the machine key is sealed by the TPM in the window of unlock"},
	{kind = .Wait, text = "compositor: surface unlock", any_order = true},
	{kind = .Front, text = "unlock"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = RECOVERY_KEY_ENTER_LINE, fails_on = "root: the disk grant table of principal 0 is written"},
	{kind = .Wait, text = "root: the disk grant table of principal 0 is written in the store module_files: 0 rows, with the tag of the machine key; 0 client keys of remote", any_order = true},
	{kind = .Wait, text = "root: unlock stopped with code 0"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "remote_allow(\"{client key}\")"},
	{kind = .Wait, text = "root: principal 0 allowed the client key "},
	{kind = .Wait, text = "root: the disk grant table of principal 0 is written in the store module_files: 0 rows, with the tag of the machine key; 1 client keys of remote"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// Machine 2: no screen. The line comes before any process starts, and no
// compositor starts after it. `remote` starts with no window; the TPM
// releases the machine key, the table gives back the client key, and a
// call that starts the storage service on demand runs through `remote`.
// The tool ends QEMU: no console can stop the machine.
@(private = "file")
scenario_missing_devices_no_screen := [?]Step {
	{kind = .Wait, text = NO_SCREEN_LINE, fails_on = "compositor: ok "},
	{kind = .Wait, text = "root: started tpm for the TPM at ", any_order = true, seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = "tpm: ok, the CRB interface at ", any_order = true, seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = "root: started remote", any_order = true},
	{kind = .Remote_Key, text = "remote: the public key of this service: "},
	{kind = .Wait, text = "remote: listening on the UDP port 7100, for the host 10.0.2.2 only, and for the client keys that a principal allowed", any_order = true},
	{kind = .Wait, text = "tpm: unsealed 32 bytes: PCR 7 and PCR 11 hold the values of the seal", any_order = true},
	{kind = .Wait, text = "unlock: the TPM releases the machine key: the system is the system of the seal; the root service receives the key of the disk grant table only", any_order = true},
	{kind = .Wait, text = "root: read the disk grant table of principal 0 from the store module_files: 0 rows, with the tag of the machine key; 1 client keys of remote", fails_on = "compositor: ok "},
	// No service of the screen: the compositor never started, and is not a
	// service that starts on demand, so the root service refuses the
	// connection, and `remote` refuses the call with the field of the
	// service. No export that `remote` reaches asks for a start, so this is
	// the refusal of the screen that a call can reach.
	{kind = .Call, text = "compositor.windows()", outcome = .Refused, expected = "error: remote: the argument service"},
	// The root service still serves: a connection that starts the storage
	// service on demand.
	{kind = .Call, text = "storage.stores()", expected = " blocks in use"},
	{kind = .Wait, text = "root: connected remote to the service storage, acting for principal 0, for the client key ", any_order = true, fails_on = "compositor: ok "},
	{kind = .Quit},
}

// Machine 3: no PS/2 controller. The input service finds a status port of
// all ones, writes its line and stops; the desktop comes up with the
// console, with no keyboard and no mouse. The tool ends QEMU: no key can
// reach the console.
@(private = "file")
scenario_missing_devices_no_ps2_controller := [?]Step {
	{kind = .Wait, text = NO_PS2_CONTROLLER_LINE, fails_on = "input: ok, "},
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "root: the start is done: ", any_order = true},
	{kind = .Quit},
}

// Machine 4: an entropy device that takes each read and never ends it. The
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

// missing_devices_silent_entropy_run runs machine 4, with the line of the
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
	return machine_test(part, all[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_MISSING_DEVICES, 4), exit_status = build.MACHINE_STOP_OK, entropy_device_silent = true})
}

// missing_devices_tpm_machine_run runs machine 1 or 2 on the disk and the
// state of the TPM of the part.
@(private = "file")
missing_devices_tpm_machine_run :: proc(part: ^Test_Part_Run, steps: []Step, number: int, exit_status: int, without_screen: bool) -> bool {
	// Not in the temporary allocator: the tool frees it after each step.
	all := make([dynamic]Step)
	defer delete(all)
	append(&all, ..missing_devices_tpm_start[:])
	append(&all, ..steps)
	output := self_test_file(TEST_OUTPUT_MISSING_DEVICES, number)
	passed := machine_test(part, all[:], {volume = build.BOOT_VOLUME_SECURE_BOOT, output = output, exit_status = exit_status, data_disk = TEST_MISSING_DEVICES_DISK, firmware = .With_Secure_Boot, tpm_state = MISSING_DEVICES_TPM_STATE_FOLDER, tpm_device = true, without_screen = without_screen})
	tpm_traffic_report(output)
	return passed
}

missing_devices_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	disk_prepare(TEST_MISSING_DEVICES_DISK, build.DATA_DISK_SIZE, true) or_return
	foundation.reset_folder(MISSING_DEVICES_TPM_STATE_FOLDER) or_return
	missing_devices_tpm_machine_run(part, scenario_missing_devices_seal_and_allow[:], 1, build.MACHINE_STOP_OK, false) or_return
	foundation.test_passed_print("%s", "the TPM sealed the machine key, and the disk grant table of principal 0 keeps the client key of the peer")
	// The tool ends QEMU: status 0.
	missing_devices_tpm_machine_run(part, scenario_missing_devices_no_screen[:], 2, 0, true) or_return
	foundation.test_passed_print("%s", "no screen: the root service started no console and started remote, and a call of the peer through remote ran")
	machine_test(part, scenario_missing_devices_no_ps2_controller[:], {volume = build.BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_MISSING_DEVICES, 3), exit_status = 0, without_ps2_controller = true}) or_return
	foundation.test_passed_print("%s", "no PS/2 controller: the input service stopped with its line, and the desktop came up")
	missing_devices_silent_entropy_run(part) or_return
	foundation.test_passed_print("%s", "an entropy device that never answers: its reads passed their deadline and counted as refused, and a process started after it")
	return true
}
