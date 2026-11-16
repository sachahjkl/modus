package modustool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "modus:contract/release"
import "modus:contract/system_description"

// The machines of the trusted boot (docs/TRUSTED_BOOT.md), `modustool test
// trusted_boot`. With the usual firmware, the boot program must refuse:
//   1. one byte of the module console changed after the system description
//      was made;
//   2. one bit of the description signature changed;
//   3. one byte of the kernel module changed;
//   4. a boot image with no system description;
//   5. an entry of console that states another hash, with the right bytes.
// Each names the file and stops, and the kernel never starts.
// With the firmware with a TPM driver and no system management mode, and a
// software TPM (swtpm):
//   6. the boot program measures the description into PCR 11 and reads it
//      back; the tool computes the value from the description and compares;
//   7. another system, one byte of the module lonely changed before the
//      description was made and signed: it boots, and its measure is the
//      other value that the tool computes for it. Its boot program is
//      signed for Secure Boot too, for the machines of `test principals`;
//      this firmware does not check the signature.
// With Secure Boot on, the certificate of the test firmware signing key
// enrolled, and no TPM device (the measure is the work of machines 6 and 7;
// the machines of the TPM of `test principals` have Secure Boot and a TPM):
//   8. the signed boot program starts, and says that the firmware verified
//      it;
//   9. the signed boot program with one byte changed does not start;
//  10. the unsigned boot program does not start.
// Then, with the usual firmware:
//  11. the volume of machine 8, packaged as the files of a release with a
//      release signing key of the test, verifies, decompresses, and starts
//      from its GPT disk.

// The module that the volumes of machines 1 and 5 change: the root service
// starts it at each boot: with no check, the machine runs it.
CHANGED_MODULE :: "console"
// The module that the volume of machine 7 changes: no program of that
// machine loads it.
OTHER_SYSTEM_MODULE :: "lonely"

TEST_OUTPUT_CHANGED_MODULE :: BUILD_FOLDER + "/test_output_changed_module.txt"
TEST_OUTPUT_WRONG_SIGNATURE :: BUILD_FOLDER + "/test_output_wrong_signature.txt"
TEST_OUTPUT_CHANGED_KERNEL :: BUILD_FOLDER + "/test_output_changed_kernel.txt"
TEST_OUTPUT_WITHOUT_DESCRIPTION :: BUILD_FOLDER + "/test_output_without_description.txt"
TEST_OUTPUT_STATED_HASH :: BUILD_FOLDER + "/test_output_stated_hash.txt"
TEST_OUTPUT_MEASURED :: BUILD_FOLDER + "/test_output_measured.txt"
TEST_OUTPUT_OTHER_SYSTEM :: BUILD_FOLDER + "/test_output_other_system.txt"
TEST_OUTPUT_SECURE_BOOT :: BUILD_FOLDER + "/test_output_secure_boot.txt"
TEST_OUTPUT_SECURE_BOOT_CHANGED :: BUILD_FOLDER + "/test_output_secure_boot_changed.txt"
TEST_OUTPUT_SECURE_BOOT_UNSIGNED :: BUILD_FOLDER + "/test_output_secure_boot_unsigned.txt"

// The firmware of a test machine. The TPM device is another option of the
// machine (machine_test, tpm_device): a firmware with a TPM driver and no
// device runs as on a machine with no TPM.
Machine_Firmware :: enum {
	Usual, // OVMF_CODE and OVMF_VARS: no TPM driver, no Secure Boot.
	With_Tpm_Driver, // OVMF_TPM_CODE and OVMF_TPM_VARS: a TPM driver, no Secure Boot, no system management mode.
	With_Secure_Boot, // OVMF_FULL_CODE with SECURE_BOOT_VARIABLES: the certificate of the firmware signing key enrolled, Secure Boot on, system management mode, a TPM driver.
}

// The steps of a machine of the TPM or of Secure Boot after "boot program:
// started", until the desktop: the firmware with system management mode is
// slow on a loaded host, and a command of the TPM that the firmware
// abandons costs it about two minutes. 300 s is the bound of each step; a
// refused measure ends the wait at once, with the line of the refusal.
TPM_MACHINE_STEP_SECONDS :: 300
MEASURE_REFUSED_LINE :: "boot program: the TPM refused the measure"

// The control command of swtpm that QEMU sends when the firmware abandons a
// command of the TPM before its answer (CMD_CANCEL_TPM_CMD): the trace of a
// time-out of the interface driver of the firmware.
SWTPM_CANCEL_COMMAND :: "00 00 00 09"

// The first wait of a machine with that firmware: for "boot program:
// started", by name, with its own bound. A boot that is slow under the load
// of the host says nothing about the trusted boot; the tool prints the time
// that it took.
TPM_MACHINE_FIRST_WAIT_SECONDS :: 600

// The log that the firmware writes on its debug console port, beside the
// log of the machine. The firmware of Nixpkgs is a release build: it writes
// few lines there.
FIRMWARE_LOG_SUFFIX :: "_firmware.log"
// The trace of QEMU for the TPM device of a machine of the TPM, each line
// with its time (main.odin, machine_command).
QEMU_TRACE_SUFFIX :: "_qemu_tpm_trace.log"
FIRMWARE_LOG_LINES_SHOWN :: 40

// The line of the firmware when it cannot start a boot option, as its boot
// manager writes it on the console (UefiBootManagerLib of EDK II).
FIRMWARE_LOAD_FAILURE_LINE :: "BdsDxe: failed to load Boot"

// machine_file gives a file of one test machine beside its log.
machine_file :: proc(output, suffix: string) -> string {
	return strings.concatenate({strings.trim_suffix(output, ".txt"), suffix}, context.temp_allocator)
}

// The software TPM of one machine: a folder of its own for each machine,
// with a new state, so that each starts with a TPM with no history and no
// file of another machine.
TPM_START_TIMEOUT :: HANG_BOUND // It only ends a start of swtpm that hangs.

tpm_folder_of :: proc(output: string) -> string {
	return machine_file(output, "_tpm")
}

tpm_socket_of :: proc(output: string) -> string {
	return strings.concatenate({tpm_folder_of(output), "/swtpm.socket"}, context.temp_allocator)
}

Tpm_Process :: struct {
	process: os.Process,
	started: bool,
	folder:  string,
}

// tpm_start starts swtpm for the machine of this output, and waits until
// its control socket exists. --terminate ends it when QEMU closes the
// connection; tpm_stop ends it in each case. state is "" for a TPM with no
// history, in the folder of the machine; else the folder of a state that
// several machines of one test part share, as one TPM across restarts of
// one machine: the part makes it new once.
tpm_start :: proc(tpm: ^Tpm_Process, output: string, state: string = "") -> bool {
	folder := tpm_folder_of(output)
	socket := tpm_socket_of(output)
	reset_folder(folder) or_return
	state_folder := state != "" ? state : folder
	log := strings.concatenate({"file=", folder, "/swtpm.log,level=20"}, context.temp_allocator)
	process, err := os.process_start({command = {"swtpm", "socket", "--tpm2", "--tpmstate", strings.concatenate({"dir=", state_folder}, context.temp_allocator), "--ctrl", strings.concatenate({"type=unixio,path=", socket}, context.temp_allocator), "--log", log, "--terminate"}, stdout = os.stderr, stderr = os.stderr})
	if err != nil {
		fmt.eprintfln("modustool: cannot start swtpm: %v. Use the development shell: nix develop", err)
		return false
	}
	tpm^ = {process = process, started = true, folder = strings.clone(folder)}
	start := time.tick_now()
	for !os.exists(socket) {
		if time.tick_since(start) > TPM_START_TIMEOUT {
			fmt.eprintfln("modustool: swtpm made no socket %s in %v", socket, TPM_START_TIMEOUT)
			tpm_stop(tpm)
			return false
		}
		time.sleep(10 * time.Millisecond)
	}
	return true
}

// tpm_stop ends swtpm and waits for its end: the next machine never starts
// while it runs.
tpm_stop :: proc(tpm: ^Tpm_Process) {
	if !tpm.started {
		return
	}
	_ = os.process_kill(tpm.process)
	_, _ = os.process_wait(tpm.process)
	tpm.started = false
	delete(tpm.folder)
	tpm.folder = ""
}

// tpm_traffic_report prints what the swtpm log of a machine of the TPM
// shows (docs/TRUSTED_BOOT.md, "The machines of the TPM"):
// - the count of TPM2_Startup commands: one for each start of the
//   firmware; two or more mean that the firmware reset the machine;
// - the count of commands that the firmware abandoned (QEMU sends the
//   control command "cancel"): each one is a command whose answer the
//   firmware did not take, after which it marks its TPM as absent;
// - the name of the last command before the first cancel.
tpm_traffic_report :: proc(output: string) {
	path := strings.concatenate({tpm_folder_of(output), "/swtpm.log"}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	lines := strings.split_lines(string(data), context.temp_allocator)
	startups, cancels := 0, 0
	last_command, abandoned_command := "", ""
	for line, index in lines {
		trimmed := strings.trim_space(line)
		// "IsEnEnabled(0x17a = 'GetCapability'): 1": swtpm runs a command.
		if strings.has_prefix(trimmed, "IsEnEnabled(") {
			last_command = trimmed[len("IsEnEnabled("):]
			if end := strings.index_byte(last_command, ')'); end >= 0 {
				last_command = last_command[:end]
			}
			if strings.contains(last_command, "'Startup'") {
				startups += 1
			}
		}
		if strings.has_prefix(trimmed, "Ctrl Cmd:") && index + 1 < len(lines) && strings.trim_space(lines[index + 1]) == SWTPM_CANCEL_COMMAND {
			cancels += 1
			if abandoned_command == "" {
				abandoned_command = last_command
			}
		}
	}
	if cancels == 0 {
		fmt.printfln("modustool: the TPM of %s: %d Startup, 0 commands abandoned (%s)", output, startups, path)
	} else {
		fmt.printfln("modustool: the TPM of %s: %d Startup, %d commands abandoned; the first after the command %s (%s; the times are in %s)", output, startups, cancels, abandoned_command, path, machine_file(output, QEMU_TRACE_SUFFIX))
	}
}

// firmware_failure_report says what a machine with that firmware showed
// when a step failed, while QEMU still runs: a picture of its screen (a
// prompt or a menu of the firmware is there), then the end of the log of
// the firmware and of swtpm.
firmware_failure_report :: proc(machine: ^Machine, output: string) {
	name := machine_file(output, "_firmware_screen")
	name = name[strings.last_index_byte(name, '/') + 1:]
	_ = screen_save(machine, name)
	for path in ([]string{machine_file(output, FIRMWARE_LOG_SUFFIX), strings.concatenate({tpm_folder_of(output), "/swtpm.log"}, context.temp_allocator), machine_file(output, QEMU_TRACE_SUFFIX)}) {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			fmt.eprintfln("modustool: %s: none (%v)", path, err)
			continue
		}
		lines := strings.split_lines(string(data), context.temp_allocator)
		fmt.eprintfln("modustool: the end of %s (%d bytes):", path, len(data))
		for line in lines[max(len(lines) - FIRMWARE_LOG_LINES_SHOWN, 0):] {
			fmt.eprintln("   ", line)
		}
	}
}

scenario_changed_module := [?]Step {
	{kind = .Wait, text = "boot program: started"},
	{kind = .Wait, text = "boot program: " + CHANGED_MODULE + " does not have the hash of the system description: expected "},
	{kind = .Wait, text = "boot program: the boot display shows the failure"},
	{kind = .Shot, text = "boot_fails_changed_module"},
	{kind = .Quit},
}

scenario_wrong_signature := [?]Step {
	{kind = .Wait, text = "boot program: started"},
	{kind = .Wait, text = "boot program: the signature of the system description is wrong"},
	{kind = .Wait, text = "boot program: the boot display shows the failure"},
	{kind = .Shot, text = "boot_fails_wrong_signature"},
	{kind = .Quit},
}

scenario_changed_kernel := [?]Step {
	{kind = .Wait, text = "boot program: started"},
	{kind = .Wait, text = "boot program: " + system_description.KERNEL_ENTRY_NAME + " does not have the hash of the system description: expected "},
	{kind = .Wait, text = "boot program: the boot display shows the failure"},
	{kind = .Shot, text = "boot_fails_changed_kernel"},
	{kind = .Quit},
}

scenario_without_description := [?]Step {
	{kind = .Wait, text = "boot program: started"},
	{kind = .Wait, text = "boot program: the boot image has no system description and description signature as its two last resources"},
	{kind = .Wait, text = "boot program: the boot display shows the failure"},
	{kind = .Quit},
}

scenario_stated_hash := [?]Step {
	{kind = .Wait, text = "boot program: started"},
	{kind = .Wait, text = "boot program: " + CHANGED_MODULE + " states in the boot image another hash than the system description: expected "},
	{kind = .Wait, text = "boot program: the boot display shows the failure"},
	{kind = .Quit},
}

MEASURE_LINE :: "boot program: PCR 11 = "
// The line of the boot program that says who verified it: the firmware
// with Secure Boot, or the boot program alone.
SECURE_BOOT_VERIFIED_LINE :: "boot program: verified by the firmware (Secure Boot), then by the boot program"
BOOT_PROGRAM_ONLY_VERIFIED_LINE :: "boot program: verified by the boot program, which the firmware did not verify"

scenario_measured := [?]Step {
	{kind = .Wait, text = "boot program: started", seconds = TPM_MACHINE_FIRST_WAIT_SECONDS},
	{kind = .Wait, text = BOOT_PROGRAM_ONLY_VERIFIED_LINE, seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = "boot program: the kernel and each module and resource have the hash of the system description", seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = MEASURE_LINE, fails_on = MEASURE_REFUSED_LINE, seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = "root: the boot image agrees with the system description that the boot program verified: ", seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = "root: measured: PCR 11 = ", seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = "compositor: surface console", any_order = true, seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Launch, text = "boot"},
	{kind = .Wait, text = "boot: ok, 7 stages, "},
	{kind = .Shot, text = "boot_measured"},
	{kind = .Quit},
}

scenario_other_system := [?]Step {
	{kind = .Wait, text = "boot program: started", seconds = TPM_MACHINE_FIRST_WAIT_SECONDS},
	{kind = .Wait, text = MEASURE_LINE, fails_on = MEASURE_REFUSED_LINE, seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = "root: the boot image agrees with the system description that the boot program verified: ", seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Quit},
}

scenario_secure_boot := [?]Step {
	{kind = .Wait, text = "boot program: started", seconds = TPM_MACHINE_FIRST_WAIT_SECONDS},
	{kind = .Wait, text = SECURE_BOOT_VERIFIED_LINE, seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = "root: verified by the firmware (Secure Boot), then by the boot program", seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = "compositor: surface console", any_order = true, seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Launch, text = "boot"},
	{kind = .Wait, text = "boot: ok, 7 stages, "},
	{kind = .Shot, text = "boot_secure_boot"},
	{kind = .Quit},
}

// The firmware refuses the boot program: its boot manager writes that it
// cannot load the boot option of the boot volume. The machine then never
// prints "boot program: started" (refused_machine_run checks the whole log
// after the end of QEMU).
scenario_secure_boot_refused := [?]Step {
	{kind = .Wait, text = FIRMWARE_LOAD_FAILURE_LINE, seconds = TPM_MACHINE_FIRST_WAIT_SECONDS},
	{kind = .Quit},
}

// trusted_boot_tests_run runs the ten machines: the five refusals of the
// boot program, the two machines of the measure, and the three machines of
// Secure Boot.
trusted_boot_tests_run :: proc() -> bool {
	// The machines that reach the desktop write a store on the data disk of
	// the tests. The machines after these expect a new disk.
	defer disk_prepare(TEST_DATA_DISK, DATA_DISK_SIZE, true)
	refused_machine_run(scenario_changed_module[:], BOOT_VOLUME_CHANGED_MODULE, TEST_OUTPUT_CHANGED_MODULE) or_return
	refused_machine_run(scenario_wrong_signature[:], BOOT_VOLUME_WRONG_SIGNATURE, TEST_OUTPUT_WRONG_SIGNATURE) or_return
	refused_machine_run(scenario_changed_kernel[:], BOOT_VOLUME_CHANGED_KERNEL, TEST_OUTPUT_CHANGED_KERNEL) or_return
	refused_machine_run(scenario_without_description[:], BOOT_VOLUME_WITHOUT_DESCRIPTION, TEST_OUTPUT_WITHOUT_DESCRIPTION) or_return
	refused_machine_run(scenario_stated_hash[:], BOOT_VOLUME_STATED_HASH, TEST_OUTPUT_STATED_HASH) or_return
	measured := measure_machine_run(scenario_measured[:], BOOT_VOLUME, TEST_OUTPUT_MEASURED, .With_Tpm_Driver) or_return
	other := measure_machine_run(scenario_other_system[:], BOOT_VOLUME_OTHER_SYSTEM, TEST_OUTPUT_OTHER_SYSTEM, .With_Tpm_Driver) or_return
	if measured == other {
		fmt.eprintln("modustool: test failed: a system with one byte of one module changed has the same measure")
		return false
	}
	test_passed_print("%s", "a system with one byte of the module " + OTHER_SYSTEM_MODULE + " changed has another measure")
	// The tool ends QEMU: status 0.
	machine_test(scenario_secure_boot[:], BOOT_VOLUME_SECURE_BOOT, TEST_OUTPUT_SECURE_BOOT, 0, firmware = .With_Secure_Boot) or_return
	test_passed_print("the firmware with Secure Boot started the signed boot program of %s, which says so", BOOT_VOLUME_SECURE_BOOT)
	refused_machine_run(scenario_secure_boot_refused[:], BOOT_VOLUME_SECURE_BOOT_CHANGED, TEST_OUTPUT_SECURE_BOOT_CHANGED, .With_Secure_Boot) or_return
	refused_machine_run(scenario_secure_boot_refused[:], BOOT_VOLUME, TEST_OUTPUT_SECURE_BOOT_UNSIGNED, .With_Secure_Boot) or_return
	release_image_machine_run() or_return
	return true
}

// The machine of the release image: the files of a release, made from the
// volume of Secure Boot of the tests, verified, decompressed, and started.
RELEASE_TEST_FOLDER :: BUILD_FOLDER + "/release_test"
RELEASE_TEST_DISK :: RELEASE_TEST_FOLDER + "/decompressed.img"
TEST_OUTPUT_RELEASE_IMAGE :: BUILD_FOLDER + "/test_output_release_image.txt"
// The seed of the release signing key of this test only. It is published
// here, so its public key is never the key of the repository, and the
// release command refuses it.
RELEASE_TEST_SEED_TEXT :: "modus release image test seed 01"

scenario_release_image := [?]Step {
	{kind = .Wait, text = "boot program: started"},
	{kind = .Wait, text = "boot program: the kernel and each module and resource have the hash of the system description"},
	{kind = .Wait, text = "root: the boot image agrees with the system description that the boot program verified: "},
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Quit},
}

// release_image_machine_run packages the volume of Secure Boot, which the
// test keys signed, as the files of a release, with the one packaging that
// accepts the test keys. It verifies the files, decompresses the image with
// zstd, and starts a machine from the GPT disk with the usual firmware: the
// machines of Secure Boot already test the signature of the boot program.
release_image_machine_run :: proc() -> bool {
	seed_text: string = RELEASE_TEST_SEED_TEXT
	seed := transmute([]u8)seed_text
	files := release_files_write(BOOT_VOLUME_SECURE_BOOT, release.RELEASE_NUMBER, RELEASE_TEST_FOLDER, RELEASE_TEST_FOLDER + "/" + RELEASE_OUTPUT_FOLDER, seed, .Test_Keys_Allowed) or_return
	public_key := public_key_of_seed(seed) or_return
	digits, problem := release_files_verify(files.image_path, files.checksum_path, public_key)
	if problem != "" {
		fmt.eprintfln("modustool: test failed: the files of the release image do not verify: %s", problem)
		return false
	}
	test_passed_print("the release signature of %s verifies, and %s has its SHA-256 %s", files.checksum_path, files.image_path, digits)
	_ = os.remove(RELEASE_TEST_DISK)
	run([]string{"zstd", "-d", "-q", "-o", RELEASE_TEST_DISK, files.image_path}) or_return
	// The disk is the output of this build: the machine starts from it.
	boot_volume_ready_note(RELEASE_TEST_DISK)
	// The tool ends QEMU: status 0.
	machine_test(scenario_release_image[:], RELEASE_TEST_DISK, TEST_OUTPUT_RELEASE_IMAGE, 0) or_return
	test_passed_print("the decompressed release image %s, a GPT disk, starts the system", RELEASE_TEST_DISK)
	return true
}

// refused_machine_run runs a machine whose boot program, or whose firmware,
// must refuse its volume, then checks that the kernel wrote nothing: it
// never started. With Secure Boot the boot program itself must not start.
refused_machine_run :: proc(steps: []Step, volume, output: string, firmware: Machine_Firmware = .Usual) -> bool {
	// The tool ends QEMU: status 0.
	machine_test(steps, volume, output, 0, firmware = firmware) or_return
	log_bytes := read_file(output) or_return
	log := string(log_bytes)
	if strings.contains(log, "kernel: ") {
		fmt.eprintfln("modustool: test failed: the kernel of %s started after a refused check", volume)
		return false
	}
	if firmware == .With_Secure_Boot {
		if strings.contains(log, "boot program: started") {
			fmt.eprintfln("modustool: test failed: the firmware with Secure Boot started the boot program of %s", volume)
			return false
		}
		test_passed_print("the firmware with Secure Boot refused the boot program of %s, which never started", volume)
		return true
	}
	test_passed_print("the boot program refused %s, and the kernel did not start", volume)
	return true
}

// measure_machine_run runs a machine with a software TPM, then compares the
// value of the measure register that the boot program read back with the
// value that the tool computes from the system description of the volume.
measure_machine_run :: proc(steps: []Step, volume, output: string, firmware: Machine_Firmware) -> (value: [32]u8, ok: bool) {
	// The tool ends QEMU: status 0.
	passed := machine_test(steps, volume, output, 0, firmware = firmware, tpm_device = true)
	tpm_traffic_report(output)
	if !passed {
		return
	}
	description := image_description_read(volume) or_return
	expected := system_description.hexadecimal(measure_expected(description))
	log_bytes := read_file(output) or_return
	log := string(log_bytes)
	at := strings.index(log, MEASURE_LINE)
	if at < 0 || len(log) < at + len(MEASURE_LINE) + 64 {
		fmt.eprintfln("modustool: test failed: %s has no line \"%s\" with 64 digits", output, MEASURE_LINE)
		return
	}
	found := log[at + len(MEASURE_LINE):][:64]
	if found != string(expected[:]) {
		fmt.eprintfln("modustool: test failed: the TPM of %s holds %s in PCR 11; the system description gives %s", volume, found, string(expected[:]))
		return
	}
	test_passed_print("PCR 11 of %s is %s, the value that the tool computes from its system description", volume, found)
	return measure_expected(description), true
}
