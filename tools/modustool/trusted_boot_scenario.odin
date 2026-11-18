package modustool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import info "modus:contract/boot_info"
import "modus:contract/release"
import "modus:contract/system_description"
import "modus:support/tpm2"

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
// Then the TPM floors (src/md/features/rollback_floors.md), with one
// software TPM whose state the six machines share, as one TPM across
// restarts, and Secure Boot on but in machine 17:
//  12. a newer system (the security version one above the repository)
//      starts on a TPM with no floor; its boot program defines the key
//      floor and the version floor of its key number, and raises them to
//      its numbers, before its measure;
//  then swtpm alone, as another system on the machine, replaces the
//      version floor with an index planted with an authorization value and
//      never written, and the key floor with a foreign index;
//  13. the same system takes both as 0, removes them, and puts its own
//      floors back;
//  14. the system of the repository is then refused: its security version
//      is below the version floor, and the kernel never starts;
//  15. a newer system whose boot program has a newer key (the key number
//      one above) starts, raises the key floor, and starts the version
//      floor of its key number;
//  16. the boot program of machine 12, with the older key number, is then
//      refused: its signing key is revoked;
//  17. with Secure Boot off, so another PCR 7, each floor is foreign: the
//      system of machine 14 starts, and its boot program changes no floor.

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

Tpm_Host_Process :: struct {
	host_process: os.Process,
	started: bool,
	folder:  string,
}

// tpm_start starts swtpm for the machine of this output, and waits until
// its control socket exists. --terminate ends it when QEMU closes the
// connection; tpm_stop ends it in each case. state is "" for a TPM with no
// history, in the folder of the machine; else the folder of a state that
// several machines of one test part share, as one TPM across restarts of
// one machine: the part makes it new once.
tpm_start :: proc(tpm: ^Tpm_Host_Process, output: string, state: string = "") -> bool {
	folder := tpm_folder_of(output)
	socket := tpm_socket_of(output)
	reset_folder(folder) or_return
	state_folder := state != "" ? state : folder
	log := strings.concatenate({"file=", folder, "/swtpm.log,level=20"}, context.temp_allocator)
	host_process, err := os.process_start({command = {"swtpm", "socket", "--tpm2", "--tpmstate", strings.concatenate({"dir=", state_folder}, context.temp_allocator), "--ctrl", strings.concatenate({"type=unixio,path=", socket}, context.temp_allocator), "--log", log, "--terminate"}, stdout = os.stderr, stderr = os.stderr})
	if err != nil {
		fmt.eprintfln("modustool: cannot start swtpm: %v. Use the development shell: nix develop", err)
		return false
	}
	tpm^ = {host_process = host_process, started = true, folder = strings.clone(folder)}
	start := time.tick_now()
	for !os.exists(socket) {
		if time.tick_since(start) > TPM_START_TIMEOUT {
			fmt.eprintfln("modustool: swtpm made no socket %s in %v", socket, TPM_START_TIMEOUT)
			tpm_stop(tpm)
			return false
		}
		time.sleep(CONDITION_POLL_PERIOD)
	}
	return true
}

// tpm_stop ends swtpm and waits for its end: the next machine never starts
// while it runs.
tpm_stop :: proc(tpm: ^Tpm_Host_Process) {
	if !tpm.started {
		return
	}
	_ = os.process_kill(tpm.host_process)
	_, _ = os.process_wait(tpm.host_process)
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
trusted_boot_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	refused_machine_run(part, scenario_changed_module[:], BOOT_VOLUME_CHANGED_MODULE, TEST_OUTPUT_CHANGED_MODULE) or_return
	refused_machine_run(part, scenario_wrong_signature[:], BOOT_VOLUME_WRONG_SIGNATURE, TEST_OUTPUT_WRONG_SIGNATURE) or_return
	refused_machine_run(part, scenario_changed_kernel[:], BOOT_VOLUME_CHANGED_KERNEL, TEST_OUTPUT_CHANGED_KERNEL) or_return
	refused_machine_run(part, scenario_without_description[:], BOOT_VOLUME_WITHOUT_DESCRIPTION, TEST_OUTPUT_WITHOUT_DESCRIPTION) or_return
	refused_machine_run(part, scenario_stated_hash[:], BOOT_VOLUME_STATED_HASH, TEST_OUTPUT_STATED_HASH) or_return
	measured := measure_machine_run(part, scenario_measured[:], BOOT_VOLUME, TEST_OUTPUT_MEASURED, .With_Tpm_Driver) or_return
	other := measure_machine_run(part, scenario_other_system[:], BOOT_VOLUME_OTHER_SYSTEM, TEST_OUTPUT_OTHER_SYSTEM, .With_Tpm_Driver) or_return
	if measured == other {
		fmt.eprintln("modustool: test failed: a system with one byte of one module changed has the same measure")
		return false
	}
	test_passed_print("%s", "a system with one byte of the module " + OTHER_SYSTEM_MODULE + " changed has another measure")
	// The tool ends QEMU: status 0.
	machine_test(part, scenario_secure_boot[:], {volume = BOOT_VOLUME_SECURE_BOOT, output = TEST_OUTPUT_SECURE_BOOT, exit_status = 0, firmware = .With_Secure_Boot}) or_return
	test_passed_print("the firmware with Secure Boot started the signed boot program of %s, which says so", BOOT_VOLUME_SECURE_BOOT)
	refused_machine_run(part, scenario_secure_boot_refused[:], BOOT_VOLUME_SECURE_BOOT_CHANGED, TEST_OUTPUT_SECURE_BOOT_CHANGED, .With_Secure_Boot) or_return
	refused_machine_run(part, scenario_secure_boot_refused[:], BOOT_VOLUME, TEST_OUTPUT_SECURE_BOOT_UNSIGNED, .With_Secure_Boot) or_return
	release_image_machine_run(part) or_return
	floor_tests_run(part) or_return
	return true
}

// The state of the software TPM that the six machines of the floors share.
FLOOR_TPM_STATE_FOLDER :: BUILD_FOLDER + "/test_tpm_floor_state"
TEST_OUTPUT_FLOOR :: BUILD_FOLDER + "/test_output_floor_%d.txt"
// The number of the output of the plant, which runs swtpm alone between
// machines 12 and 13.
FLOOR_PLANT_NUMBER :: 0
// The authorization value of the planted index: another system knows it,
// and this system does not.
FLOOR_PLANTED_VALUE :: "planted by another system"
#assert(len(FLOOR_PLANTED_VALUE) <= tpm2.AUTHORIZATION_VALUE_SIZE)
// The lines of the boot program on the floors (src/boot/trust.odin).
FLOOR_LINE :: "boot program: the TPM floors: the key floor %d%s, the version floor of the key number %d %d%s"
FLOOR_RAISED_LINE :: "boot program: %s rose from %d to %d"
FLOOR_DEFINED_LINE :: "boot program: %s: defined its index"
FLOOR_ABSENT_WORDS :: " (no index: no system defined it)"
FLOOR_HELD_WORDS :: " (held)"
FLOOR_FOREIGN_WORDS :: " (a foreign index, taken as 0: another system defined it, or PCR 7 changed)"
FLOOR_NEVER_WRITTEN_WORDS :: " (an index never written, taken as 0)"
FLOOR_STAY_LINE :: "boot program: the TPM floors stay as they are: the firmware did not verify this boot program"

// The numbers of the build, for the lines that the machines of the floors
// print: the key number that the build gave its key, and the security
// version of the repository. Each test volume raises one of them by 1.
Floor_Numbers :: struct {
	key_number:       u64,
	security_version: u64,
}

// floor_numbers_read reads the key number of the build from the key file
// that every boot program holds (system_key_write).
floor_numbers_read :: proc() -> (numbers: Floor_Numbers, ok: bool) {
	bytes := read_file(SYSTEM_KEY_FILE) or_return
	if len(bytes) != system_description.PUBLIC_KEY_SIZE + 8 {
		fmt.eprintfln("modustool: test failed: %s has %d bytes, not a public key and a key number", SYSTEM_KEY_FILE, len(bytes))
		return {}, false
	}
	for index in 0 ..< 8 {
		numbers.key_number |= u64(bytes[system_description.PUBLIC_KEY_SIZE + index]) << (8 * u64(index))
	}
	numbers.security_version = system_description.SECURITY_VERSION
	return numbers, true
}

// Floor_Machine holds the steps of one machine of the floors and the texts
// that they name, outside the temporary memory: the tool frees that memory
// after each step.
Floor_Machine :: struct {
	steps: [dynamic]Step,
	texts: [dynamic]string,
}

// floor_wait adds a wait for a text that the machine writes. The text comes
// from fmt.aprintf: the machine owns it, and frees it after its run.
floor_wait :: proc(machine: ^Floor_Machine, text: string, any_order := false, fails_on := "") {
	append(&machine.texts, text)
	append(&machine.steps, Step{kind = .Wait, text = text, any_order = any_order, fails_on = fails_on, seconds = TPM_MACHINE_STEP_SECONDS})
}

// floor_start_steps adds the steps of the start of a machine of the floors
// up to its check: the boot program started, who verified it, the floors
// that it read, and its two numbers.
floor_start_steps :: proc(machine: ^Floor_Machine, firmware: Machine_Firmware, floors_line: string, key_number, security_version: u64) {
	append(&machine.steps, Step{kind = .Wait, text = "boot program: started", seconds = TPM_MACHINE_FIRST_WAIT_SECONDS})
	append(&machine.steps, Step{kind = .Wait, text = firmware == .With_Secure_Boot ? SECURE_BOOT_VERIFIED_LINE : BOOT_PROGRAM_ONLY_VERIFIED_LINE, seconds = TPM_MACHINE_STEP_SECONDS})
	floor_wait(machine, floors_line)
	floor_wait(machine, fmt.aprintf("boot program: this boot program has the key number %d, and the system description the security version %d", key_number, security_version))
}

// floor_started_steps adds the steps after the raises of a machine that
// starts: the measure, after which no program raises a floor, the root
// service, and the desktop; then the end.
floor_started_steps :: proc(machine: ^Floor_Machine) {
	append(&machine.steps, Step{kind = .Wait, text = MEASURE_LINE, fails_on = MEASURE_REFUSED_LINE, seconds = TPM_MACHINE_STEP_SECONDS})
	append(&machine.steps, Step{kind = .Wait, text = "root: the TPM floors before this start: ", seconds = TPM_MACHINE_STEP_SECONDS})
	append(&machine.steps, Step{kind = .Wait, text = "compositor: surface console", any_order = true, seconds = TPM_MACHINE_STEP_SECONDS})
	append(&machine.steps, Step{kind = .Quit})
}

// floor_refused_steps adds the steps of a refusal: its line, before any
// measure, and the boot display; then the end.
floor_refused_steps :: proc(machine: ^Floor_Machine, refusal: string) {
	floor_wait(machine, refusal, fails_on = MEASURE_LINE)
	append(&machine.steps, Step{kind = .Wait, text = "boot program: the boot display shows the failure", seconds = TPM_MACHINE_STEP_SECONDS})
	append(&machine.steps, Step{kind = .Quit})
}

// floor_machine_forget frees the texts of a machine and empties it for the
// next one.
floor_machine_forget :: proc(machine: ^Floor_Machine) {
	for text in machine.texts {
		delete(text)
	}
	clear(&machine.texts)
	clear(&machine.steps)
}

// floor_machine_run runs one machine of the floors on the shared state of
// the software TPM, then empties it. A machine that starts reaches the
// desktop, and the tool ends QEMU; a refused machine shows its failure, and
// the tool checks that its kernel never started.
floor_machine_run :: proc(part: ^Test_Part_Run, machine: ^Floor_Machine, volume: string, number: int, refused: bool, firmware: Machine_Firmware = .With_Secure_Boot) -> bool {
	defer floor_machine_forget(machine)
	output := self_test_file(TEST_OUTPUT_FLOOR, number)
	// The tool ends QEMU: status 0.
	passed := machine_test(part, machine.steps[:], {volume = volume, output = output, exit_status = 0, firmware = firmware, tpm_state = FLOOR_TPM_STATE_FOLDER, tpm_device = true})
	tpm_traffic_report(output)
	if !passed {
		return false
	}
	if refused {
		log_bytes := read_file(output) or_return
		if strings.contains(string(log_bytes), "kernel: ") {
			fmt.eprintfln("modustool: test failed: the kernel of %s started after the boot program refused it for a TPM floor", volume)
			return false
		}
	}
	return true
}

// floor_plant does to the state of the software TPM of the floors what
// another system on the machine can do with the empty value of the owner
// hierarchy, with swtpm alone and no QEMU: it replaces the version floor of
// the key number given with an index that has the area of a floor (its
// attributes, the policy of this system) and an authorization value, never
// written; and it replaces the key floor with a foreign index, whose policy
// is not the policy of this system. The policy comes from the area of the
// key floor that machine 12 defined.
floor_plant :: proc(key_number: u64) -> bool {
	alone := tpm_alone_start(FLOOR_TPM_STATE_FOLDER, self_test_file(TEST_OUTPUT_FLOOR, FLOOR_PLANT_NUMBER)) or_return
	defer tpm_alone_stop(&alone)
	command: [128]u8
	answer: [TPM_TOOL_ANSWER_LIMIT]u8
	count := tpm2.nv_read_public_command(command[:], info.KEY_FLOOR_INDEX)
	bytes := tpm_alone_transact(&alone, command[:count], answer[:], "TPM2_NV_ReadPublic") or_return
	public, code, problem := tpm2.nv_public_answer(bytes)
	if problem != .None || public.policy_size != tpm2.DIGEST_SIZE || public.attributes & tpm2.NV_WRITTEN == 0 {
		fmt.eprintfln("modustool: test failed: the key floor of machine 12 is not a written floor (response code 0x%X)", code)
		return false
	}
	policy: [tpm2.DIGEST_SIZE]u8
	copy(policy[:], public.policy[:tpm2.DIGEST_SIZE])
	other_policy := policy
	other_policy[0] ~= 1
	planted_value: string = FLOOR_PLANTED_VALUE
	version_index := info.version_floor_index(key_number)
	Plant_Step :: struct {
		count: int,
		what:  string,
	}
	plant_steps := [4]Plant_Step {
		{0, "TPM2_NV_UndefineSpace of the version floor"},
		{0, "TPM2_NV_DefineSpace of a planted index with an authorization value"},
		{0, "TPM2_NV_UndefineSpace of the key floor"},
		{0, "TPM2_NV_DefineSpace of a foreign index"},
	}
	for &step, place in plant_steps {
		// One command buffer: each command is built just before it goes.
		switch place {
		case 0:
			step.count = tpm2.nv_undefine_command(command[:], version_index)
		case 1:
			step.count = tpm2.floor_area_define_command(command[:], version_index, &policy, transmute([]u8)planted_value)
		case 2:
			step.count = tpm2.nv_undefine_command(command[:], info.KEY_FLOOR_INDEX)
		case 3:
			step.count = tpm2.floor_area_define_command(command[:], info.KEY_FLOOR_INDEX, &other_policy, nil)
		}
		bytes = tpm_alone_transact(&alone, command[:step.count], answer[:], step.what) or_return
		code, problem = tpm2.status_answer(bytes)
		if problem != .None {
			fmt.eprintfln("modustool: test failed: swtpm refused %s (response code 0x%X)", step.what, code)
			return false
		}
	}
	fmt.printfln("modustool: %s: as another system can, the version floor of the key number %d is now an index with the area of a floor and an authorization value, never written, and the key floor a foreign index", FLOOR_TPM_STATE_FOLDER, key_number)
	return true
}

// floor_tests_run runs the six machines of the TPM floors on a new state
// of the software TPM, with a plant of another system between machines 12
// and 13.
floor_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	numbers := floor_numbers_read() or_return
	reset_folder(FLOOR_TPM_STATE_FOLDER) or_return
	machine: Floor_Machine
	machine.steps = make([dynamic]Step)
	machine.texts = make([dynamic]string)
	defer {
		floor_machine_forget(&machine)
		delete(machine.steps)
		delete(machine.texts)
	}
	newer_version := numbers.security_version + 1
	newer_key := numbers.key_number + 1
	key_name := "the key floor"
	// Not in the temporary memory: they serve several machines.
	version_name := fmt.aprintf("the version floor of the key number %d", numbers.key_number)
	defer delete(version_name)
	newer_version_name := fmt.aprintf("the version floor of the key number %d", newer_key)
	defer delete(newer_version_name)

	// 12. A newer system on a TPM with no floor defines and raises both, in
	// its boot program, before its measure.
	floor_start_steps(&machine, .With_Secure_Boot, fmt.aprintf(FLOOR_LINE, 0, FLOOR_ABSENT_WORDS, numbers.key_number, 0, FLOOR_ABSENT_WORDS), numbers.key_number, newer_version)
	floor_wait(&machine, fmt.aprintf(FLOOR_DEFINED_LINE, key_name))
	floor_wait(&machine, fmt.aprintf(FLOOR_RAISED_LINE, key_name, 0, numbers.key_number))
	floor_wait(&machine, fmt.aprintf(FLOOR_DEFINED_LINE, version_name))
	floor_wait(&machine, fmt.aprintf(FLOOR_RAISED_LINE, version_name, 0, newer_version))
	floor_started_steps(&machine)
	floor_machine_run(part, &machine, BOOT_VOLUME_NEWER_SYSTEM, 12, false) or_return
	test_passed_print("a newer system defined the TPM floors and raised them before its measure: the key floor to %d, the version floor of its key to %d", numbers.key_number, newer_version)

	// Another system plants an index with an authorization value, and a
	// foreign one.
	floor_plant(numbers.key_number) or_return

	// 13. The same newer system finds both, takes each as 0, removes them,
	// and puts its own floors back.
	floor_start_steps(&machine, .With_Secure_Boot, fmt.aprintf(FLOOR_LINE, 0, FLOOR_FOREIGN_WORDS, numbers.key_number, 0, FLOOR_NEVER_WRITTEN_WORDS), numbers.key_number, newer_version)
	floor_wait(&machine, fmt.aprintf("boot program: %s: removed a foreign index: another system defined it, or PCR 7 changed", key_name))
	floor_wait(&machine, fmt.aprintf(FLOOR_RAISED_LINE, key_name, 0, numbers.key_number))
	floor_wait(&machine, fmt.aprintf("boot program: %s: removed an index that was never written: another system planted it", version_name))
	floor_wait(&machine, fmt.aprintf(FLOOR_RAISED_LINE, version_name, 0, newer_version))
	floor_started_steps(&machine)
	floor_machine_run(part, &machine, BOOT_VOLUME_NEWER_SYSTEM, 13, false) or_return
	test_passed_print("%s", "the boot program removed a planted index with an authorization value and a foreign index, and put the floors of this system back")

	// 14. The system of the repository: below the version floor that
	// machine 13 put back.
	held := fmt.aprintf(FLOOR_LINE, numbers.key_number, FLOOR_HELD_WORDS, numbers.key_number, newer_version, FLOOR_HELD_WORDS)
	floor_start_steps(&machine, .With_Secure_Boot, held, numbers.key_number, numbers.security_version)
	floor_refused_steps(&machine, fmt.aprintf("boot program: the security version %d of the system description is below the version floor %d of the TPM: an older system", numbers.security_version, newer_version))
	floor_machine_run(part, &machine, BOOT_VOLUME_SECURE_BOOT, 14, true) or_return
	test_passed_print("the boot program refused the system of %s after a newer one started: its security version %d is below the version floor %d", BOOT_VOLUME_SECURE_BOOT, numbers.security_version, newer_version)

	// 15. A newer key raises the key floor, and starts the version floor of
	// its own key number.
	floor_start_steps(&machine, .With_Secure_Boot, fmt.aprintf(FLOOR_LINE, numbers.key_number, FLOOR_HELD_WORDS, newer_key, 0, FLOOR_ABSENT_WORDS), newer_key, newer_version)
	floor_wait(&machine, fmt.aprintf(FLOOR_RAISED_LINE, key_name, numbers.key_number, newer_key))
	floor_wait(&machine, fmt.aprintf(FLOOR_DEFINED_LINE, newer_version_name))
	floor_wait(&machine, fmt.aprintf(FLOOR_RAISED_LINE, newer_version_name, 0, newer_version))
	floor_started_steps(&machine)
	floor_machine_run(part, &machine, BOOT_VOLUME_NEWER_KEY, 15, false) or_return
	test_passed_print("a boot program with the key number %d raised the key floor from %d to %d", newer_key, numbers.key_number, newer_key)

	// 16. The boot program of machine 12: its key is revoked.
	floor_start_steps(&machine, .With_Secure_Boot, fmt.aprintf(FLOOR_LINE, newer_key, FLOOR_HELD_WORDS, numbers.key_number, newer_version, FLOOR_HELD_WORDS), numbers.key_number, newer_version)
	floor_refused_steps(&machine, fmt.aprintf("boot program: the key number %d of this boot program is below the key floor %d of the TPM: its key is revoked", numbers.key_number, newer_key))
	floor_machine_run(part, &machine, BOOT_VOLUME_NEWER_SYSTEM, 16, true) or_return
	test_passed_print("the boot program with the key number %d refused to start after a boot program with the key number %d raised the key floor: its signing key is revoked", numbers.key_number, newer_key)

	// 17. Another PCR 7: the system of the repository, whose boot program
	// machine 14 refused, on the firmware with Secure Boot off. Each floor
	// is foreign there, so the older system starts; with Secure Boot off,
	// its boot program changes no floor.
	floor_start_steps(&machine, .With_Tpm_Driver, fmt.aprintf(FLOOR_LINE, 0, FLOOR_FOREIGN_WORDS, numbers.key_number, 0, FLOOR_FOREIGN_WORDS), numbers.key_number, numbers.security_version)
	append(&machine.steps, Step{kind = .Wait, text = FLOOR_STAY_LINE, seconds = TPM_MACHINE_STEP_SECONDS})
	floor_started_steps(&machine)
	floor_machine_run(part, &machine, BOOT_VOLUME_SECURE_BOOT, 17, false, .With_Tpm_Driver) or_return
	test_passed_print("%s", "with another PCR 7 (Secure Boot off), each floor is foreign: the older system started, and its boot program changed no floor")
	fmt.println("modustool: the TPM floors: 6 machines passed")
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
release_image_machine_run :: proc(part: ^Test_Part_Run) -> bool {
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
	machine_test(part, scenario_release_image[:], {volume = RELEASE_TEST_DISK, output = TEST_OUTPUT_RELEASE_IMAGE, exit_status = 0}) or_return
	test_passed_print("the decompressed release image %s, a GPT disk, starts the system", RELEASE_TEST_DISK)
	return true
}

// refused_machine_run runs a machine whose boot program, or whose firmware,
// must refuse its volume, then checks that the kernel wrote nothing: it
// never started. With Secure Boot the boot program itself must not start.
refused_machine_run :: proc(part: ^Test_Part_Run, steps: []Step, volume, output: string, firmware: Machine_Firmware = .Usual) -> bool {
	// The tool ends QEMU: status 0.
	machine_test(part, steps, {volume = volume, output = output, exit_status = 0, firmware = firmware}) or_return
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
measure_machine_run :: proc(part: ^Test_Part_Run, steps: []Step, volume, output: string, firmware: Machine_Firmware) -> (value: [32]u8, ok: bool) {
	// The tool ends QEMU: status 0.
	passed := machine_test(part, steps, {volume = volume, output = output, exit_status = 0, firmware = firmware, tpm_device = true})
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
