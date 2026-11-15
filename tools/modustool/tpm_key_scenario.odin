package modustool

import "core:fmt"
import "core:os"
import format "modus:contract/store"
import "modus:support/principals"
import "modus:support/storage_mount"

// The machines of the machine key sealed by the TPM
// (docs/PRINCIPALS.md, "The machine key sealed by the TPM"),
// `modustool test principals tpm`:
// six machines with one software TPM, whose state they share as one TPM
// across restarts, on the firmware with the TPM driver and no Secure Boot
// (OVMF_TPM_CODE). The firmware with Secure Boot loses an answer of the
// software TPM at each start on the test host, with or without system
// management mode (docs/TRUSTED_BOOT.md, "The machines of the TPM"). So the
// first five start the volumes of the test of the seal, whose root service
// seals with no Secure Boot (SEAL_WITHOUT_SECURE_BOOT_FOR_A_TEST); the sixth
// starts the main volume, where the rule of Secure Boot holds.
//
//   1. The system of the test of the seal: `machine_seal()` makes the
//      machine key; the TPM service seals it to PCR 7 and PCR 11; the window
//      of `unlock` shows the recovery key, which the tool reads off the
//      screen.
//   2. The same system: the TPM proves the creation of the sealed object,
//      releases the key with no typing, and the disk grant table that
//      machine 1 wrote verifies under it.
//   3. The other system (one byte of the module lonely changed before its
//      description was made and signed: another PCR 11): the TPM refuses;
//      a wrong recovery key opens nothing; the recovery key of machine 1
//      opens the key, and `unlock` seals it again to this system.
//   4. The other system again: the TPM releases the key with no typing.
//   5. The other system on a disk of its own, whose record is the record of
//      machine 4 with one byte of its creation ticket changed: the TPM
//      refuses the ticket, and nothing is unsealed.
//   6. The main volume, whose root service has no setting of a test
//      (another PCR 11), on the disk of machines 1 to 4: the TPM refuses,
//      the recovery key opens the key, and `unlock` does not seal it again,
//      as Secure Boot is off: a seal would trust a boot program that
//      nothing verified. `machine_seal()` is refused for the same reason.
//
// Machines 7 to 10, after them, seal the keys of a named principal on a
// disk of their own (see scenario_tpm_principal_create below).
//
// The machines of the TPM are opt-in, as the machines of the measure of
// `test trusted_boot tpm` are: on some runs QEMU does not give the firmware
// the answer of one command of the software TPM
// (docs/TRUSTED_BOOT.md, "The machines of the TPM").

TEST_TPM_KEY_DISK :: BUILD_FOLDER + "/test_tpm_key_disk.img"
// The disk of machine 5: the store of `unlock` with the record of machine 4,
// one byte of its creation ticket changed.
TEST_TPM_KEY_CHANGED_TICKET_DISK :: BUILD_FOLDER + "/test_tpm_key_changed_ticket_disk.img"
// The boot line of the root service of the test of the seal: the text of
// TEST_BUILD_LINE_SEAL_WITHOUT_SECURE_BOOT in src/programs/root/tpm.odin.
// machine_test fails each machine of another volume that prints it.
TEST_ROOT_SEAL_WITHOUT_SECURE_BOOT_LINE :: "root: this system seals with no Secure Boot: a test system, never a release"
// The store of `unlock`: a store of principal 0 has the name of its program.
UNLOCK_STORE :: "unlock"
TEST_OUTPUT_TPM_KEY :: BUILD_FOLDER + "/test_output_tpm_key_%d.txt"
// The state of the software TPM that the six machines share.
TPM_KEY_STATE_FOLDER :: BUILD_FOLDER + "/test_tpm_key_state"

// A recovery key that is not the recovery key of the machine: 32 symbols of
// base32, each one A.
WRONG_RECOVERY_KEY :: "AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA"

// The steps of the start of a machine of the TPM, to the desktop: the
// boot program measures the system, and the root service starts the TPM
// service.
@(private = "file")
tpm_key_start := [?]Step {
	{kind = .Wait, text = "boot program: started", seconds = TPM_MACHINE_FIRST_WAIT_SECONDS},
	{kind = .Wait, text = MEASURE_LINE, fails_on = MEASURE_REFUSED_LINE, seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = "root: started tpm for the TPM at ", seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = "tpm: ok, the CRB interface at ", any_order = true, seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = "compositor: surface console", any_order = true, seconds = TPM_MACHINE_STEP_SECONDS},
}

// The end of each machine: the console comes to the front, so the line
// goes to the console and not to a window of unlock.
@(private = "file")
tpm_key_end := [?]Step {
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// A new disk with no record: unlock stops at once. The window of unlock then
// draws in Spleen 8x16, so the tool reads a recovery key off the screen,
// glyph by glyph.
@(private = "file")
tpm_key_new_disk_and_font := [?]Step {
	{kind = .Wait, text = "unlock: no named principal: the machine runs as principal 0, with no unlock", any_order = true},
	{kind = .Wait, text = "root: unlock stopped with code 0", any_order = true},
	{kind = .Launch, text = "settings"},
	{kind = .Wait, text = "compositor: surface settings", any_order = true},
	{kind = .Wait, text = "settings: ok, "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"settings\")"},
	{kind = .Wait, text = "[console]   call       service"},
	{kind = .Type, text = "settings.set(\"font\", \"spleen\")"},
	{kind = .Wait, text = "settings: font spleen, "},
}

@(private = "file")
scenario_tpm_key_seal := [?]Step {
	// The seal: the key, the record, and the key of the table to the root
	// service, which writes the table under it.
	{kind = .Type, text = "machine_seal()"},
	{kind = .Wait, text = "root: the machine key is sealed by the TPM in the window of unlock"},
	{kind = .Wait, text = "tpm: sealed 32 bytes to PCR 7 and PCR 11: a public area of ", any_order = true},
	{kind = .Wait, text = "unlock: the machine key is sealed by the TPM to PCR 7 and PCR 11, with a copy under a recovery key, in the store of unlock", any_order = true},
	{kind = .Wait, text = "root: the disk grant table of principal 0 is written in the store programs: 0 rows, with the tag of the machine key", any_order = true},
	// The recovery key, shown one time.
	{kind = .Wait, text = "compositor: surface unlock"},
	{kind = .Front, text = "unlock"},
	{kind = .Screen_Text, text = "unlock", element = "recovery_key"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "root: unlock stopped with code 0"},
	// A second key is refused: it would replace the key of the table.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "machine_seal()"},
	{kind = .Wait, text = "root: refused a machine key sealed by the TPM: the machine has a record of its machine key, and a change is not built"},
}

@(private = "file")
scenario_tpm_key_same_system := [?]Step {
	{kind = .Wait, text = "tpm: unsealed 32 bytes: PCR 7 and PCR 11 hold the values of the seal", any_order = true},
	{kind = .Wait, text = "unlock: the TPM releases the machine key: the system is the system of the seal; the root service receives the key of the disk grant table only", any_order = true},
	{kind = .Wait, text = "root: read the disk grant table of principal 0 from the store programs: 0 rows, with the tag of the machine key", any_order = true},
	{kind = .Wait, text = "unlock: no named principal: the machine runs as principal 0, with no unlock", any_order = true},
	{kind = .Wait, text = "root: unlock stopped with code 0", any_order = true},
}

// The TPM refuses, a wrong recovery key opens nothing, and the recovery key
// of machine 1 opens the machine key.
@(private = "file")
scenario_tpm_key_recovery := [?]Step {
	{kind = .Wait, text = "tpm: the TPM refuses the unseal: PCR 7 and PCR 11 do not hold the values of the seal", any_order = true},
	{kind = .Wait, text = "unlock: the TPM refuses the unseal: PCR 7 and PCR 11 do not hold the values of the seal", any_order = true},
	{kind = .Wait, text = "unlock: the machine key waits for its recovery key: the disk grants of principal 0 come when it is typed", any_order = true},
	{kind = .Wait, text = "compositor: surface unlock", any_order = true},
	{kind = .Front, text = "unlock"},
	{kind = .Type, text = WRONG_RECOVERY_KEY},
	{kind = .Wait, text = "unlock: the recovery key is wrong: the copy of the machine key does not open, the disk grants of principal 0 stay absent (1 in all)"},
	{kind = .Type, text = SCREEN_TEXT_MARK},
	{kind = .Wait, text = "unlock: the recovery key opens the machine key; the root service receives the key of the disk grant table only"},
	{kind = .Wait, text = "root: read the disk grant table of principal 0 from the store programs: 0 rows, with the tag of the machine key", any_order = true},
}

// The other system with Secure Boot on: after the recovery, the key is
// sealed again to this system.
@(private = "file")
scenario_tpm_key_reseal := [?]Step {
	{kind = .Wait, text = "tpm: sealed 32 bytes to PCR 7 and PCR 11: a public area of ", any_order = true},
	{kind = .Wait, text = "unlock: the machine key is sealed again to PCR 7 and PCR 11 of the system that runs: its next start needs no recovery key"},
	{kind = .Wait, text = "root: unlock stopped with code 0"},
}

// One byte of the creation ticket of the record changed: the TPM refuses
// the ticket, so the service unseals nothing, and the window asks for the
// recovery key. The TPM checks the ticket with the handle NULL as the
// signing key.
@(private = "file")
scenario_tpm_key_changed_ticket := [?]Step {
	{kind = .Wait, text = "tpm: refused the unseal: the TPM refuses the creation ticket of the object (response code ", any_order = true},
	{kind = .Wait, text = "unlock: the TPM service refuses the unseal: this TPM did not make the sealed object of the record under the PCR values of its policy", any_order = true},
	{kind = .Wait, text = "unlock: the machine key waits for its recovery key: the disk grants of principal 0 come when it is typed", any_order = true, fails_on = "tpm: unsealed 32 bytes"},
}

// Secure Boot off: no new seal after the recovery, and no seal by command.
@(private = "file")
scenario_tpm_key_secure_boot_off := [?]Step {
	{kind = .Wait, text = "unlock: the firmware did not verify the boot program (Secure Boot is off): the machine key is not sealed again, as its seal would trust a boot program that nothing verified; the recovery key opens it at the next start too", fails_on = "unlock: the machine key is sealed again"},
	{kind = .Wait, text = "root: unlock stopped with code 0"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "machine_seal()"},
	{kind = .Wait, text = "root: refused a machine key sealed by the TPM: the firmware did not verify the boot program (Secure Boot is off), so a seal would trust a boot program that nothing verified"},
}

// The machines of the keys of a named principal sealed by the TPM
// (docs/PRINCIPALS.md, "The keys sealed by the TPM"), on a disk of their
// own and the same software TPM, after the machines of the machine key:
//
//   7. The system of the test of the seal: `principal_create("alice")`; the
//      TPM seals the keys to PCR 7, PCR 11 and the passphrase; the window
//      shows the recovery key, which the tool reads off the screen.
//   8. The same system: a wrong passphrase, which the TPM refuses and
//      counts (TPM_RC_AUTH_FAIL), then the right one: the TPM releases the
//      keys, and the session starts.
//   9. The other system: the TPM refuses the passphrase, as PCR 11 differs;
//      a wrong recovery key opens nothing; the recovery key opens the keys,
//      and a new passphrase seals them again to this system.
//  10. The other system again: two wrong passphrases, each counted; with
//      the one of machine 8, the TPM has counted three, the most that
//      libtpms allows by default, and refuses the right one (TPM_RC_LOCKOUT);
//      the recovery key opens the keys. This machine is the last one that
//      uses the TPM: the lockout lasts 1000 seconds of the time of the TPM.
//
// The TPM service sends TPM2_Shutdown after each use of the passphrase that
// is not a counted failure. After a counted failure it sends none, so a stop
// then would count one more failure at the next start. Each machine here
// that types a wrong passphrase ends its tries in the same run with an
// answer that is not a counted failure: machine 8 with the right
// passphrase, machine 10 with the lockout. So no start counts a failure of
// its own, and the counts are those of before: one failure on machine 8,
// two on machine 10, and the lockout at the next try.

TEST_TPM_PRINCIPAL_DISK :: BUILD_FOLDER + "/test_tpm_principal_disk.img"
WRONG_PRINCIPAL_PASSPHRASE :: "not the passphrase of alice"
NEW_PRINCIPAL_PASSPHRASE :: "a new passphrase of alice"

// The line of the TPM service after each use of an authorization value.
@(private = "file")
TPM_SHUTDOWN_LINE :: "tpm: TPM2_Shutdown after the use of an authorization value: a stop of the machine now makes the TPM count no failure"

@(private = "file")
scenario_tpm_principal_create := [?]Step {
	{kind = .Front, text = "console"},
	{kind = .Type, text = "principal_create(\"alice\")"},
	{kind = .Wait, text = "root: started unlock"},
	{kind = .Wait, text = "compositor: surface unlock"},
	{kind = .Front, text = "unlock"},
	{kind = .Type, text = PRINCIPAL_PASSPHRASE},
	{kind = .Type, text = PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = "tpm: sealed 32 bytes to PCR 7 and PCR 11 and an authorization value, whose wrong tries the TPM counts: a public area of ", any_order = true},
	{kind = .Wait, text = "unlock: the keys of principal \"alice\" are sealed by the TPM to PCR 7 and PCR 11 and to its passphrase, under a key of Argon2id", any_order = true},
	{kind = .Wait, text = "unlock: principal 1 \"alice\" is created: its keys are sealed by the TPM with its passphrase, with a copy under a recovery key; the window shows the recovery key one time", any_order = true},
	{kind = .Wait, text = "root: the session of principal 1 \"alice\" starts: the desktop starts each program in it", any_order = true},
	// The recovery key, shown one time.
	{kind = .Front, text = "unlock"},
	{kind = .Screen_Text, text = "unlock", element = "recovery_key"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "root: unlock stopped with code 0"},
}

// The start of a machine with the file of alice: unlock asks for her
// passphrase.
@(private = "file")
tpm_principal_locked := [?]Step {
	{kind = .Wait, text = "root: principal 1 \"alice\" is recorded, its public key ", any_order = true},
	{kind = .Wait, text = "unlock: principal 1 \"alice\" is locked: its passphrase opens its session", any_order = true},
	{kind = .Wait, text = "compositor: surface unlock", any_order = true},
	{kind = .Front, text = "unlock"},
}

@(private = "file")
scenario_tpm_principal_same_system := [?]Step {
	{kind = .Type, text = WRONG_PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = "tpm: the TPM refuses the unseal: the authorization value is wrong, and the TPM counted the failure (response code ", any_order = true},
	// No TPM2_Shutdown after a counted failure: its line would come before
	// the line of unlock.
	{kind = .Wait, text = "unlock: the passphrase of principal 1 \"alice\" is wrong: the TPM refuses it and counts it, nothing is unlocked (1 in all)", fails_on = TPM_SHUTDOWN_LINE},
	{kind = .Type, text = PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = "tpm: unsealed 32 bytes: PCR 7 and PCR 11 hold the values of the seal, and the authorization value is right", any_order = true},
	// The right passphrase sends TPM2_Shutdown: the stop of this machine
	// counts no failure at the start of the next one.
	{kind = .Wait, text = TPM_SHUTDOWN_LINE, any_order = true},
	{kind = .Wait, text = "unlock: the TPM releases the keys of principal 1 \"alice\" to its passphrase: the system is the system of the seal", any_order = true},
	{kind = .Wait, text = "root: the session of principal 1 \"alice\" starts: the desktop starts each program in it", any_order = true},
	{kind = .Wait, text = "root: unlock stopped with code 0", any_order = true},
}

// The recovery key of machine 7 opens the keys, and a new passphrase seals
// them again to the system that runs.
@(private = "file")
tpm_principal_recovery_and_new_passphrase := [?]Step {
	{kind = .Type, text = WRONG_RECOVERY_KEY},
	{kind = .Wait, text = "unlock: the recovery key of principal 1 \"alice\" is wrong: the copy of its keys does not open, nothing is unlocked ("},
	{kind = .Type, text = SCREEN_TEXT_MARK},
	{kind = .Wait, text = "unlock: the recovery key of principal 1 \"alice\" opens its keys"},
	{kind = .Wait, text = "unlock: principal 1 \"alice\" types a passphrase: the TPM seals its keys again to it and to the system that runs"},
	{kind = .Type, text = NEW_PRINCIPAL_PASSPHRASE},
	{kind = .Type, text = NEW_PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = "tpm: sealed 32 bytes to PCR 7 and PCR 11 and an authorization value, whose wrong tries the TPM counts: a public area of ", any_order = true},
	{kind = .Wait, text = "unlock: the keys of principal 1 \"alice\" are sealed again to PCR 7 and PCR 11 of the system that runs and to the new passphrase: its next unlock needs no recovery key", any_order = true},
	{kind = .Wait, text = "root: the session of principal 1 \"alice\" starts: the desktop starts each program in it", any_order = true},
	{kind = .Wait, text = "root: unlock stopped with code 0", any_order = true},
}

@(private = "file")
scenario_tpm_principal_other_system := [?]Step {
	{kind = .Type, text = PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = "tpm: the TPM refuses the unseal: PCR 7 and PCR 11 do not hold the values of the seal", any_order = true},
	{kind = .Wait, text = "unlock: the keys of principal 1 \"alice\" wait for their recovery key: the TPM does not release them", fails_on = "unlock: the TPM releases the keys"},
}

@(private = "file")
scenario_tpm_principal_lockout := [?]Step {
	// The passphrase of before the recovery is wrong now: two failures,
	// which make three with the one of machine 8.
	{kind = .Type, text = PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = "unlock: the passphrase of principal 1 \"alice\" is wrong: the TPM refuses it and counts it, nothing is unlocked (1 in all)", fails_on = TPM_SHUTDOWN_LINE},
	{kind = .Type, text = WRONG_PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = "unlock: the passphrase of principal 1 \"alice\" is wrong: the TPM refuses it and counts it, nothing is unlocked (2 in all)", fails_on = TPM_SHUTDOWN_LINE},
	// The right passphrase: the TPM refuses each try now.
	{kind = .Type, text = NEW_PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = "tpm: the TPM refuses the unseal: it counted too many wrong authorization values, and refuses each try for now (response code ", any_order = true, fails_on = "tpm: unsealed 32 bytes"},
	// The lockout is not a counted failure: the service sends TPM2_Shutdown.
	{kind = .Wait, text = TPM_SHUTDOWN_LINE, any_order = true},
	{kind = .Wait, text = "unlock: the TPM refuses each try of the passphrase of principal 1 \"alice\" for now: it counted too many wrong passphrases; the recovery key opens the keys"},
	{kind = .Wait, text = "unlock: the keys of principal 1 \"alice\" wait for their recovery key: the TPM does not release them"},
}

// tpm_key_machine_run runs one machine of the part: the start, the steps,
// the end, with the shared state of the TPM, then prints what the log of
// its software TPM shows.
@(private = "file")
tpm_key_machine_run :: proc(parts: [][]Step, volume: string, firmware: Machine_Firmware, number: int, disk: string = TEST_TPM_KEY_DISK) -> bool {
	// Not in the temporary allocator: the tool frees it after each step.
	all := make([dynamic]Step)
	defer delete(all)
	append(&all, tpm_key_start[0])
	// The root service of a test volume says that it seals with no Secure
	// Boot before it starts the TPM service: the wait comes before the
	// waits of the TPM, so the place of the log has not passed it.
	if volume == BOOT_VOLUME_SEAL_TEST || volume == BOOT_VOLUME_SEAL_TEST_OTHER_SYSTEM {
		append(&all, Step{kind = .Wait, text = TEST_ROOT_SEAL_WITHOUT_SECURE_BOOT_LINE, any_order = true, seconds = TPM_MACHINE_STEP_SECONDS})
	}
	append(&all, ..tpm_key_start[1:])
	for part in parts {
		append(&all, ..part)
	}
	append(&all, ..tpm_key_end[:])
	output := self_test_file(TEST_OUTPUT_TPM_KEY, number)
	passed := machine_test(all[:], volume, output, MACHINE_STOP_OK, disk, firmware = firmware, tpm_state = TPM_KEY_STATE_FOLDER)
	tpm_traffic_report(output)
	return passed
}

// tpm_key_changed_ticket_disk_write reads the record of the machine key
// from the disk of the part, as the storage service opens it, changes one
// byte of the digest of its creation ticket, and writes a new disk whose
// store of `unlock` holds that record only. Every other part of the record
// stays: only the TPM can refuse it, at the check of the ticket.
@(private = "file")
tpm_key_changed_ticket_disk_write :: proc() -> bool {
	image, read_error := os.read_entire_file(TEST_TPM_KEY_DISK, context.allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: test failed: cannot read %s: %v", TEST_TPM_KEY_DISK, read_error)
		return false
	}
	defer delete(image)
	state := new(storage_mount.State)
	defer free(state)
	contents := disk_contents(image, state)
	record: []u8
	for &item in contents.objects {
		if item.store == UNLOCK_STORE && item.name == principals.MACHINE_OBJECT && !item.tree && !item.damaged {
			record = item.bytes
		}
	}
	if len(record) != principals.MACHINE_TPM_FILE_SIZE || string(record[:8]) != principals.MACHINE_TPM_MAGIC {
		fmt.eprintfln("modustool: test failed: %s holds no record of a machine key sealed by the TPM in the store %s (%d bytes)", TEST_TPM_KEY_DISK, UNLOCK_STORE, len(record))
		return false
	}
	changed := make([]u8, len(record), context.temp_allocator)
	copy(changed, record)
	// The first byte of the digest of the ticket: after its tag, its
	// hierarchy and the size of the digest.
	changed[principals.MACHINE_TPM_OFFSET_TICKET + 8] ~= 0x01
	disk := Program_Disk {
		image = make([]u8, DATA_DISK_SIZE),
		next  = 2,
	}
	defer delete(disk.image)
	root := new(format.Root, context.temp_allocator)
	root.magic = format.ROOT_MAGIC
	root.generation = PROGRAM_DISK_GENERATION
	root.disk_blocks = u64(DATA_DISK_SIZE) / format.BLOCK_SIZE
	files := [1]Program_File{{name = principals.MACHINE_OBJECT, bytes = changed}}
	root.stores[0] = program_store_put(&disk, UNLOCK_STORE, files[:], DATA_DISK_SIZE) or_return
	root.check = format.root_check(root)
	copy(disk.image[:format.BLOCK_SIZE], ([^]u8)(root)[:format.BLOCK_SIZE])
	if err := os.write_entire_file(TEST_TPM_KEY_CHANGED_TICKET_DISK, disk.image); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", TEST_TPM_KEY_CHANGED_TICKET_DISK, err)
		return false
	}
	fmt.printfln("modustool: %s: the record of the machine key with one byte of its creation ticket changed", TEST_TPM_KEY_CHANGED_TICKET_DISK)
	return true
}

// principals_tpm_tests_run runs the six machines, on a new disk and a new
// state of the software TPM.
principals_tpm_tests_run :: proc() -> bool {
	disk_prepare(TEST_TPM_KEY_DISK, DATA_DISK_SIZE, true) or_return
	reset_folder(TPM_KEY_STATE_FOLDER) or_return
	delete(screen_text_kept)
	screen_text_kept = ""
	tpm_key_machine_run([][]Step{tpm_key_new_disk_and_font[:], scenario_tpm_key_seal[:]}, BOOT_VOLUME_SEAL_TEST, .With_Tpm, 1) or_return
	test_passed_print("%s", "machine_seal() sealed the machine key by the TPM, and the window of unlock showed its recovery key")
	tpm_key_machine_run([][]Step{scenario_tpm_key_same_system[:]}, BOOT_VOLUME_SEAL_TEST, .With_Tpm, 2) or_return
	test_passed_print("%s", "the same system: the TPM proved the creation and released the machine key with no typing")
	tpm_key_machine_run([][]Step{scenario_tpm_key_recovery[:], scenario_tpm_key_reseal[:]}, BOOT_VOLUME_SEAL_TEST_OTHER_SYSTEM, .With_Tpm, 3) or_return
	test_passed_print("%s", "another system: the TPM refused, the recovery key opened the machine key, and it was sealed again")
	tpm_key_machine_run([][]Step{scenario_tpm_key_same_system[:]}, BOOT_VOLUME_SEAL_TEST_OTHER_SYSTEM, .With_Tpm, 4) or_return
	test_passed_print("%s", "the other system after the recovery: the TPM released the machine key with no typing")
	// The record that machine 4 opened, with one byte of its ticket changed,
	// on a disk of its own: the disk of the part stays as it is.
	tpm_key_changed_ticket_disk_write() or_return
	tpm_key_machine_run([][]Step{scenario_tpm_key_changed_ticket[:]}, BOOT_VOLUME_SEAL_TEST_OTHER_SYSTEM, .With_Tpm, 5, TEST_TPM_KEY_CHANGED_TICKET_DISK) or_return
	test_passed_print("%s", "one byte of the creation ticket changed: the TPM refused the ticket, and nothing was unsealed")
	tpm_key_machine_run([][]Step{scenario_tpm_key_recovery[:], scenario_tpm_key_secure_boot_off[:]}, BOOT_VOLUME, .With_Tpm, 6) or_return
	test_passed_print("%s", "the system of a release with Secure Boot off: the recovery key opened the machine key, and no seal trusts the boot program")
	fmt.println("modustool: the machine key sealed by the TPM: 6 machines passed")
	principals_tpm_principal_tests_run() or_return
	return true
}

// principals_tpm_principal_tests_run runs the four machines of the keys of a
// named principal, on a new disk and the state of the software TPM that the
// machines of the machine key left.
@(private = "file")
principals_tpm_principal_tests_run :: proc() -> bool {
	disk_prepare(TEST_TPM_PRINCIPAL_DISK, DATA_DISK_SIZE, true) or_return
	delete(screen_text_kept)
	screen_text_kept = ""
	tpm_key_machine_run([][]Step{tpm_key_new_disk_and_font[:], scenario_tpm_principal_create[:]}, BOOT_VOLUME_SEAL_TEST, .With_Tpm, 7, TEST_TPM_PRINCIPAL_DISK) or_return
	test_passed_print("%s", "principal_create() sealed the keys of alice by the TPM with her passphrase, and the window of unlock showed her recovery key")
	tpm_key_machine_run([][]Step{tpm_principal_locked[:], scenario_tpm_principal_same_system[:]}, BOOT_VOLUME_SEAL_TEST, .With_Tpm, 8, TEST_TPM_PRINCIPAL_DISK) or_return
	test_passed_print("%s", "the same system: the TPM counted a wrong passphrase, and released the keys to the right one")
	tpm_key_machine_run([][]Step{tpm_principal_locked[:], scenario_tpm_principal_other_system[:], tpm_principal_recovery_and_new_passphrase[:]}, BOOT_VOLUME_SEAL_TEST_OTHER_SYSTEM, .With_Tpm, 9, TEST_TPM_PRINCIPAL_DISK) or_return
	test_passed_print("%s", "another system: the TPM refused the passphrase, the recovery key opened the keys, and a new passphrase sealed them again")
	tpm_key_machine_run([][]Step{tpm_principal_locked[:], scenario_tpm_principal_lockout[:], tpm_principal_recovery_and_new_passphrase[:]}, BOOT_VOLUME_SEAL_TEST_OTHER_SYSTEM, .With_Tpm, 10, TEST_TPM_PRINCIPAL_DISK) or_return
	test_passed_print("%s", "the TPM counted each wrong passphrase, refused each try after three, and the recovery key opened the keys")
	fmt.println("modustool: the keys of a named principal sealed by the TPM: 4 machines passed")
	return true
}
