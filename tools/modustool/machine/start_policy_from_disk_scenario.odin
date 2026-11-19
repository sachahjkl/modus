package machine

import "core:fmt"
import "core:strings"
import "modus:contract/blake3"
import "modus:contract/system_description"
import "modus:support/disk_process"
import "modus:support/tpm2"
import "modustool:build"
import "modustool:foundation"

// The machines of a start policy from the disk
// (src/md/features/start_policy.md, "A start policy from the disk"), part
// of `modustool test start_policy`: three machines on one data disk and one
// state of a software TPM, with Secure Boot on, on the signed main system.
// The tool writes the disk: the store module_files of principal 0 holds the
// module disk_start_policy under the nickname tiny, and the module
// start_policy of the boot image under the nickname broken.
//
//   1. A choice is refused on a machine with no machine key. machine_seal()
//      makes one; then a nickname that names no module, a hash that does
//      not match the row, and a grant store for the chosen start policy
//      are refused; tiny is chosen, and the table is written.
//   2. Step 4 of the root service reads the choice: the TPM releases the
//      machine key with no window, the root service reads the table, loads
//      tiny from the store, measures it into PCR 12 and starts it with the
//      grant Start_Policy only. tiny starts the console in its own order and
//      makes the machine usable. The tool computes PCR 12 from the hash of
//      tiny and compares it with the value of the line. broken is chosen.
//   3. broken runs with no list, so it stops before Machine_Usable: the root
//      service starts the rescue start policy, measured too. The tool
//      computes PCR 12 after the two extends. The choice ends.

TEST_DISK_START_POLICY_DISK :: foundation.BUILD_FOLDER + "/test_start_policy_disk.img"
TEST_OUTPUT_START_POLICY_FROM_DISK :: foundation.BUILD_FOLDER + "/test_output_start_policy_from_disk_%d.txt"
START_POLICY_TPM_STATE_FOLDER :: foundation.BUILD_FOLDER + "/test_start_policy_tpm_state"
// The nicknames of the two module files of the store.
CHOSEN_NICKNAME :: "tiny"
BROKEN_NICKNAME :: "broken"

// The words that the line of a measure gives after the hash of the start
// policy, and before the 64 digits of PCR 12.
MEASURED_WORDS :: " is measured into PCR 12: PCR 12 = "

// Start_Policy_Machine holds the steps of one machine and the texts that
// they name, outside the temporary memory: the tool frees that memory after
// each step.
@(private = "file")
Start_Policy_Machine :: struct {
	steps: [dynamic]Step,
	texts: [dynamic]string,
}

@(private = "file")
machine_wait :: proc(machine: ^Start_Policy_Machine, text: string, any_order := false, fails_on := "") {
	append(&machine.texts, text)
	append(&machine.steps, Step{kind = .Wait, text = text, any_order = any_order, fails_on = fails_on, seconds = TPM_MACHINE_STEP_SECONDS})
}

@(private = "file")
machine_type :: proc(machine: ^Start_Policy_Machine, text: string) {
	append(&machine.texts, text)
	append(&machine.steps, Step{kind = .Front, text = "console"})
	append(&machine.steps, Step{kind = .Type, text = text})
}

@(private = "file")
machine_forget :: proc(machine: ^Start_Policy_Machine) {
	for text in machine.texts {
		delete(text)
	}
	clear(&machine.texts)
	clear(&machine.steps)
}

// machine_start_steps adds the start of a machine of the TPM, to the
// measure of the system.
@(private = "file")
machine_start_steps :: proc(machine: ^Start_Policy_Machine) {
	append(&machine.steps, Step{kind = .Wait, text = "boot program: started", seconds = TPM_MACHINE_FIRST_WAIT_SECONDS})
	append(&machine.steps, Step{kind = .Wait, text = SECURE_BOOT_VERIFIED_LINE, seconds = TPM_MACHINE_STEP_SECONDS})
	append(&machine.steps, Step{kind = .Wait, text = MEASURE_LINE, fails_on = MEASURE_REFUSED_LINE, seconds = TPM_MACHINE_STEP_SECONDS})
	append(&machine.steps, Step{kind = .Wait, text = "root: started tpm for the TPM at ", any_order = true, seconds = TPM_MACHINE_STEP_SECONDS})
}

// machine_end_steps adds the end: shutdown() in the console.
@(private = "file")
machine_end_steps :: proc(machine: ^Start_Policy_Machine) {
	append(&machine.steps, Step{kind = .Front, text = "console"})
	append(&machine.steps, Step{kind = .Type, text = "shutdown()"})
	append(&machine.steps, Step{kind = .Wait, text = "kernel: the machine stops with code 0", seconds = TPM_MACHINE_STEP_SECONDS})
}

@(private = "file")
start_policy_machine_run :: proc(part: ^Test_Part_Run, machine: ^Start_Policy_Machine, number: int) -> bool {
	output := self_test_file(TEST_OUTPUT_START_POLICY_FROM_DISK, number)
	passed := machine_test(part, machine.steps[:], {volume = build.BOOT_VOLUME_SECURE_BOOT, output = output, exit_status = build.MACHINE_STOP_OK, data_disk = TEST_DISK_START_POLICY_DISK, firmware = .With_Secure_Boot, tpm_state = START_POLICY_TPM_STATE_FOLDER, tpm_device = true})
	tpm_traffic_report(output)
	return passed
}

// pcr_12_check reads the value of PCR 12 that the line of the measure of a
// start policy gives, and compares it with the value that the tool
// computes. what names the start policy after its hash, as the root service
// writes it. The last such line counts.
@(private = "file")
pcr_12_check :: proc(output: string, what: string, expected: [32]u8) -> bool {
	text, readable := foundation.read_text_file(output)
	if !readable {
		fmt.eprintfln("modustool: test failed: cannot read %s", output)
		return false
	}
	marker := strings.concatenate({what, MEASURED_WORDS}, context.temp_allocator)
	at := strings.last_index(text, marker)
	if at < 0 || len(text) < at + len(marker) + 64 {
		fmt.eprintfln("modustool: test failed: %s has no line \"...%s\" with 64 digits", output, marker)
		return false
	}
	found := text[at + len(marker):][:64]
	digits := system_description.hexadecimal(expected)
	if found != string(digits[:]) {
		fmt.eprintfln("modustool: test failed: PCR 12 is %s after the start policy %s; the hashes of the start policies give %s", found, what, string(digits[:]))
		return false
	}
	foundation.test_passed_print("PCR 12 is %s after the start policy %s, the value that the tool computes from the hashes of the start policies", found, what)
	return true
}

// start_policy_from_disk_tests_run runs the three machines on a new disk
// and a new state of the software TPM.
start_policy_from_disk_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	chosen_file := foundation.read_file(foundation.module_path(foundation.DISK_START_POLICY_MODULE)) or_return
	broken_file := foundation.read_file(foundation.module_path(foundation.START_POLICY_MODULE)) or_return
	files := [?]build.Module_File{{CHOSEN_NICKNAME, chosen_file}, {BROKEN_NICKNAME, broken_file}}
	build.module_disk_write(TEST_DISK_START_POLICY_DISK, files[:]) or_return
	foundation.reset_folder(START_POLICY_TPM_STATE_FOLDER) or_return
	chosen_hash := blake3.hash(chosen_file)
	broken_hash := blake3.hash(broken_file)
	chosen_digits, broken_digits: [disk_process.HASH_DIGITS]u8
	disk_process.hash_write(&chosen_digits, chosen_hash)
	disk_process.hash_write(&broken_digits, broken_hash)
	machine: Start_Policy_Machine
	machine.steps = make([dynamic]Step)
	machine.texts = make([dynamic]string)
	defer {
		machine_forget(&machine)
		delete(machine.steps)
		delete(machine.texts)
	}

	// 1. No machine key: the choice is refused. Then the seal, the
	// refusals of the borders, and the choice.
	machine_start_steps(&machine)
	machine_wait(&machine, fmt.aprintf("unlock: no record of the machine key: the disk grants of principal 0 last until the machine stops, and the start policy of the boot image runs"), any_order = true)
	// The default start policy is measured too.
	machine_wait(&machine, fmt.aprintf(" of the list start_list%s", MEASURED_WORDS), any_order = true)
	machine_wait(&machine, fmt.aprintf("compositor: surface console"), any_order = true)
	machine_type(&machine, fmt.aprintf("start_policy_choose(\"%s\", \"%s\")", CHOSEN_NICKNAME, string(chosen_digits[:])))
	machine_wait(&machine, fmt.aprintf("root: refused a choice of a start policy: the machine has no machine key, so the disk grant table of principal 0 lasts until the machine stops, and no choice reaches the next start; machine_seal() makes a machine key"))
	machine_type(&machine, fmt.aprintf("machine_seal()"))
	machine_wait(&machine, fmt.aprintf("root: the machine key is sealed by the TPM in the window of unlock"))
	machine_wait(&machine, fmt.aprintf("unlock: the machine key is sealed by the TPM to PCR 7 and PCR 11, with a copy under a recovery key; the window shows the recovery key one time, and the record is written when it is written down"), any_order = true)
	machine_wait(&machine, fmt.aprintf("compositor: surface unlock"))
	append(&machine.steps, Step{kind = .Front, text = "unlock"})
	append(&machine.steps, Step{kind = .Key, text = "ret"})
	machine_wait(&machine, fmt.aprintf("%s", RECOVERY_KEY_ENTER_LINE))
	machine_wait(&machine, fmt.aprintf("root: the disk grant table of principal 0 is written in the store module_files: 0 rows, with the tag of the machine key"), any_order = true)
	machine_wait(&machine, fmt.aprintf("root: unlock stopped: itself, done"))
	// A nickname that names no module.
	machine_type(&machine, fmt.aprintf("start_policy_choose(\"nobody\", \"\")"))
	machine_wait(&machine, fmt.aprintf("root: refused the start policy nobody: the nickname names no module, as it has no row in the disk grant table of principal 0; name the hash of its file"))
	machine_type(&machine, fmt.aprintf("start_policy_choose(\"%s\", \"%s\")", CHOSEN_NICKNAME, string(chosen_digits[:])))
	machine_wait(&machine, fmt.aprintf("root: principal 0 chose the start policy %s, the file %s: it runs at the next start of the machine, with the grant Start_Policy only; the machine key keeps the choice on the disk", CHOSEN_NICKNAME, string(chosen_digits[:])))
	machine_wait(&machine, fmt.aprintf("root: the disk grant table of principal 0 is written in the store module_files: 1 rows, with the tag of the machine key"))
	// A reserved nickname: the name of a module of the boot image, under
	// which the start policy would run.
	machine_type(&machine, fmt.aprintf("start_policy_choose(\"console\", \"%s\")", string(chosen_digits[:])))
	machine_wait(&machine, fmt.aprintf("root: refused the start policy console: the root service gives this name a grant, or a module of the boot image has it, and the start policy runs under its nickname"), fails_on = "root: principal 0 chose the start policy console")
	// A hash that does not match the row.
	machine_type(&machine, fmt.aprintf("start_policy_choose(\"%s\", \"%s\")", CHOSEN_NICKNAME, string(broken_digits[:])))
	machine_wait(&machine, fmt.aprintf("root: refused the start policy %s: the nickname names the file %s, and the command names the file %s", CHOSEN_NICKNAME, string(chosen_digits[:]), string(broken_digits[:])))
	// The chosen start policy asks for another grant: refused.
	machine_type(&machine, fmt.aprintf("allow(\"%s\", \"store\")", CHOSEN_NICKNAME))
	machine_wait(&machine, fmt.aprintf("root: refused the grant store to the nickname %s: it names the chosen start policy, which holds the grant Start_Policy and nothing else", CHOSEN_NICKNAME))
	machine_end_steps(&machine)
	start_policy_machine_run(part, &machine, 1) or_return
	machine_forget(&machine)
	foundation.test_passed_print("%s", "principal 0 chose a start policy from the disk once its machine key opened with no passphrase; a nickname that names no module, a reserved nickname, a hash that does not match and a grant store for it were refused")

	// 2. The chosen start policy runs, measured into PCR 12.
	machine_start_steps(&machine)
	machine_wait(&machine, fmt.aprintf("root: unlock reads the machine key with no window, before the start policy: the choice of principal 0 is in its disk grant table"), any_order = true)
	machine_wait(&machine, fmt.aprintf("tpm: unsealed 32 bytes: PCR 7 and PCR 11 hold the values of the seal"), any_order = true)
	// The run of unlock before the start policy stops with its own line,
	// before the measure, whose wait below is ordered.
	machine_wait(&machine, fmt.aprintf("root: unlock read the machine key with no window and stopped: itself, done"), any_order = true)
	machine_wait(&machine, fmt.aprintf("root: read the disk grant table of principal 0 from the store module_files: 1 rows, with the tag of the machine key"), any_order = true)
	machine_wait(&machine, fmt.aprintf("root: reads the chosen start policy \"%s\", the file %s, from the store module_files of principal 0", CHOSEN_NICKNAME, string(chosen_digits[:])), any_order = true)
	chosen_words := fmt.aprintf("(nickname \"%s\")", CHOSEN_NICKNAME)
	defer delete(chosen_words)
	machine_wait(&machine, fmt.aprintf("%s%s", chosen_words, MEASURED_WORDS))
	machine_wait(&machine, fmt.aprintf("root: started the chosen start policy \"%s\" from the disk, hash %s, with the grant Start_Policy only", CHOSEN_NICKNAME, string(chosen_digits[:])), any_order = true)
	machine_wait(&machine, fmt.aprintf("disk_start_policy: the context holds the log, the budget and the root ring, no other handle and no start list: as it must"), any_order = true)
	machine_wait(&machine, fmt.aprintf("disk_start_policy: a start of the start policy of the boot image is refused with the status "), any_order = true)
	machine_wait(&machine, fmt.aprintf("disk_start_policy: Start_Policy_Choice, Start_From_Disk, Disk_Grant and Connect are refused with No_Right: as it must"), any_order = true, fails_on = "disk_start_policy: the command ")
	machine_wait(&machine, fmt.aprintf("disk_start_policy: the console runs: the machine is usable"), any_order = true, fails_on = "the rescue start policy starts")
	machine_wait(&machine, fmt.aprintf("root: the machine is usable, by the start policy "), any_order = true)
	machine_wait(&machine, fmt.aprintf(" chosen by principal 0, from the disk: the budget of this service holds "))
	// The chosen row keeps its file and its persistence.
	machine_type(&machine, fmt.aprintf("nickname_move(\"%s\", \"%s\")", CHOSEN_NICKNAME, string(broken_digits[:])))
	machine_wait(&machine, fmt.aprintf("root: refused the move of the nickname %s: it names the chosen start policy; start_policy_choose names another file", CHOSEN_NICKNAME), fails_on = " will get the data of ")
	machine_type(&machine, fmt.aprintf("disk_persistence(\"%s\", \"forget\")", CHOSEN_NICKNAME))
	machine_wait(&machine, fmt.aprintf("root: refused the setting of persistence of the nickname %s: it names the chosen start policy, which persists until start_policy_default ends the choice", CHOSEN_NICKNAME))
	machine_type(&machine, fmt.aprintf("start_policy_choose(\"%s\", \"%s\")", BROKEN_NICKNAME, string(broken_digits[:])))
	machine_wait(&machine, fmt.aprintf("root: principal 0 chose the start policy %s, the file %s: it runs at the next start of the machine", BROKEN_NICKNAME, string(broken_digits[:])))
	machine_wait(&machine, fmt.aprintf("root: the disk grant table of principal 0 is written in the store module_files: 2 rows, with the tag of the machine key"))
	machine_end_steps(&machine)
	start_policy_machine_run(part, &machine, 2) or_return
	machine_forget(&machine)
	zero: [32]u8
	chosen_digest := tpm2.start_policy_event_digest(&chosen_hash, &zero)
	after_chosen := tpm2.pcr_extended(&zero, &chosen_digest)
	pcr_12_check(self_test_file(TEST_OUTPUT_START_POLICY_FROM_DISK, 2), chosen_words, after_chosen) or_return

	// 3. The chosen start policy fails: the rescue runs, measured too.
	machine_start_steps(&machine)
	broken_words := fmt.aprintf("(nickname \"%s\")", BROKEN_NICKNAME)
	defer delete(broken_words)
	machine_wait(&machine, fmt.aprintf("root: unlock read the machine key with no window and stopped: itself, done"), any_order = true)
	machine_wait(&machine, fmt.aprintf("root: reads the chosen start policy \"%s\", the file %s, from the store module_files of principal 0", BROKEN_NICKNAME, string(broken_digits[:])), any_order = true)
	machine_wait(&machine, fmt.aprintf("%s%s", broken_words, MEASURED_WORDS))
	machine_wait(&machine, fmt.aprintf("start_policy: the context names no start list: no row starts"), any_order = true)
	machine_wait(&machine, fmt.aprintf(" stopped before the machine was usable: itself, refused; the rescue start policy starts"))
	machine_wait(&machine, fmt.aprintf(" of the list rescue_list%s", MEASURED_WORDS))
	machine_wait(&machine, fmt.aprintf("start_policy: the start list has 4 rows: each starts in its order"))
	machine_wait(&machine, fmt.aprintf("root: the machine is usable, by the start policy "), any_order = true)
	machine_wait(&machine, fmt.aprintf("%s", RESCUE_USABLE_TEXT))
	machine_type(&machine, fmt.aprintf("start_policy_default()"))
	machine_wait(&machine, fmt.aprintf("root: principal 0 ended its choice of a start policy: the default start policy runs at the next start of the machine"))
	machine_end_steps(&machine)
	start_policy_machine_run(part, &machine, 3) or_return
	machine_forget(&machine)
	broken_digest := tpm2.start_policy_event_digest(&broken_hash, &zero)
	after_broken := tpm2.pcr_extended(&zero, &broken_digest)
	pcr_12_check(self_test_file(TEST_OUTPUT_START_POLICY_FROM_DISK, 3), broken_words, after_broken) or_return
	// The rescue is the module start_policy of the boot image, the same
	// bytes as broken, with the rescue list.
	rescue_list, problem := build.start_list_bytes(build.DEFAULT_RESCUE_LIST[:])
	if problem != "" {
		fmt.eprintfln("modustool: test failed: the rescue list has no bytes: %s", problem)
		return false
	}
	rescue_list_hash := blake3.hash(rescue_list)
	rescue_digest := tpm2.start_policy_event_digest(&broken_hash, &rescue_list_hash)
	after_rescue := tpm2.pcr_extended(&after_broken, &rescue_digest)
	pcr_12_check(self_test_file(TEST_OUTPUT_START_POLICY_FROM_DISK, 3), " of the list rescue_list", after_rescue) or_return
	fmt.println("modustool: a start policy from the disk: 3 machines passed")
	return true
}
