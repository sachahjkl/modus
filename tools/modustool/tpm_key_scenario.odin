package modustool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:time"
import format "modus:contract/store"
import "modus:support/principals"
import "modus:private/storage/storage_mount"
import "modus:support/tpm2"
import "modustool:foundation"

// The machines of the machine key sealed by the TPM
// (docs/PRINCIPALS.md, "The machine key sealed by the TPM"),
// part of `modustool test principals`:
// six machines with one software TPM, whose state they share as one TPM
// across restarts. The first five run the firmware with Secure Boot on and
// the enrolled variable store (OVMF_FULL_CODE), and start signed volumes
// whose root service is the root service of a release: the rule "a seal
// needs Secure Boot" holds in each of them. The sixth runs the firmware
// with the TPM driver and no Secure Boot (OVMF_TPM_CODE).
//
//   1. The signed main system (BOOT_VOLUME_SECURE_BOOT): `machine_seal()`
//      makes the machine key; the TPM service seals it to PCR 7 and PCR 11;
//      the window of `unlock` shows the recovery key, which the tool reads
//      off the screen.
//   2. The same system: the TPM proves the creation of the sealed object,
//      releases the key with no typing, and the disk grant table that
//      machine 1 wrote verifies under it.
//   3. The other system (BOOT_VOLUME_OTHER_SYSTEM: one byte of the module
//      lonely changed before its description was made and signed, so
//      another PCR 11, and its boot program signed for Secure Boot): the
//      TPM refuses; a wrong recovery key opens nothing; the recovery key of
//      machine 1 opens the key, and `unlock` seals it again to this system.
//   4. The other system again: the TPM releases the key with no typing.
//   5. The other system on a disk of its own, whose record is the record of
//      machine 4 with one byte of its creation ticket changed: the TPM
//      refuses the ticket, and nothing is unsealed.
//   6. The other system with Secure Boot off, on the disk of machines 1 to
//      4: PCR 11 is the PCR 11 of the seal of machine 3, and only PCR 7
//      differs, so the TPM refuses because of PCR 7 alone. The recovery
//      key opens the key, and `unlock` does not seal it again, as a seal
//      would trust a boot program that nothing verified. `machine_seal()`
//      is refused for the same reason.
//
// Machines 7 to 12, after them, seal the keys of a named principal on a
// disk of their own (see scenario_tpm_principal_create below). Machines 13
// to 16 seal the machine key with a machine passphrase, on a disk and a
// state of the software TPM of their own.

TEST_TPM_KEY_DISK :: foundation.BUILD_FOLDER + "/test_tpm_key_disk.img"
// The disk of machine 5: the store of `unlock` with the record of machine 4,
// one byte of its creation ticket changed.
TEST_TPM_KEY_CHANGED_TICKET_DISK :: foundation.BUILD_FOLDER + "/test_tpm_key_changed_ticket_disk.img"
// The store of `unlock`: a store of principal 0 has the name of its process.
UNLOCK_STORE :: "unlock"
TEST_OUTPUT_TPM_KEY :: foundation.BUILD_FOLDER + "/test_output_tpm_key_%d.txt"
// The state of the software TPM that the ten machines share.
TPM_KEY_STATE_FOLDER :: foundation.BUILD_FOLDER + "/test_tpm_key_state"

// The lines of the TPM service on its lockout hierarchy
// (src/md/features/tpm_sealed_principal_keys.md, "The lockout authorization
// value"): the first use of a passphrase on a new state of the TPM sets a
// value, and the first use in each later run finds it. The count limits of libtpms with no setup: three
// failures, then one forgiven each 1000 seconds.
TPM_LOCKOUT_SET_LINE :: "tpm: the lockout hierarchy had an empty authorization value: this service set a random one and kept no copy, so no system resets the count of the TPM or changes its limits"
TPM_LOCKOUT_FOUND_LINE :: "tpm: the lockout hierarchy has an authorization value: an earlier start of this system set it, or another system did; this service keeps no copy of it and leaves it"
TPM_COUNT_LIMITS_LINE :: "tpm: the count limits of the TPM: a lockout after 3 wrong authorization values, one forgiven each 1000 seconds; "
// A new state of the software TPM, whose lockout hierarchy has the empty
// value: the reset that the TPM of the part refuses is taken there.
TPM_LOCKOUT_EMPTY_STATE_FOLDER :: foundation.BUILD_FOLDER + "/test_tpm_lockout_empty_state"
TEST_OUTPUT_TPM_LOCKOUT :: foundation.BUILD_FOLDER + "/test_output_tpm_lockout_%d.txt"
// The largest answer to a command that the tool sends to the TPM.
TPM_TOOL_ANSWER_LIMIT :: 256

// The line of unlock at Enter on a new recovery key: no record, no file,
// no key of a table and no session comes before it
// (src/md/features/tpm_sealed_principal_keys.md).
RECOVERY_KEY_ENTER_LINE :: "unlock: Enter on the recovery key: it is written down, and the record or the file that holds its copy is written now"

// A recovery key that is not the recovery key of the machine: 32 symbols of
// base32, each one A.
WRONG_RECOVERY_KEY :: "AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA"

// The steps of the start of a machine of the TPM, to the desktop: the
// boot program measures the system, and the root service starts the TPM
// service. The root service starts the TPM service and the compositor
// shows the console in no fixed order, so the three waits after the
// measure each search from the measure line.
@(private = "file")
tpm_key_start := [?]Step {
	{kind = .Wait, text = "boot program: started", seconds = TPM_MACHINE_FIRST_WAIT_SECONDS},
	{kind = .Wait, text = MEASURE_LINE, fails_on = MEASURE_REFUSED_LINE, seconds = TPM_MACHINE_STEP_SECONDS},
	{kind = .Wait, text = "root: started tpm for the TPM at ", any_order = true, seconds = TPM_MACHINE_STEP_SECONDS},
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
	// The record waits for Enter: the root service writes no table before
	// it.
	{kind = .Wait, text = "unlock: the machine key is sealed by the TPM to PCR 7 and PCR 11, with a copy under a recovery key; the window shows the recovery key one time, and the record is written when it is written down", any_order = true, fails_on = "root: the disk grant table of principal 0 is written"},
	// The recovery key, shown one time.
	{kind = .Wait, text = "compositor: surface unlock"},
	{kind = .Front, text = "unlock"},
	{kind = .Screen_Text, text = "unlock", element = "recovery_key"},
	{kind = .Key, text = "ret"},
	// The line of Enter, in order: the table before it fails the step.
	{kind = .Wait, text = RECOVERY_KEY_ENTER_LINE, fails_on = "root: the disk grant table of principal 0 is written"},
	{kind = .Wait, text = "unlock: the record of the machine key sealed by the TPM is in the store of unlock: its recovery key is written down"},
	{kind = .Wait, text = "root: the disk grant table of principal 0 is written in the store module_files: 0 rows, with the tag of the machine key", any_order = true},
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
	{kind = .Wait, text = "root: read the disk grant table of principal 0 from the store module_files: 0 rows, with the tag of the machine key", any_order = true},
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
	{kind = .Wait, text = "root: read the disk grant table of principal 0 from the store module_files: 0 rows, with the tag of the machine key", any_order = true},
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
// own and the same software TPM, after the machines of the machine key,
// each with Secure Boot on:
//
//   7. The signed main system: `principal_create("alice")`; the
//      TPM seals the keys to PCR 7, PCR 11 and the passphrase; the window
//      shows the recovery key, which the tool reads off the screen.
//   8. The same system: a wrong passphrase, which the TPM refuses and
//      counts (TPM_RC_AUTH_FAIL), then the right one: the TPM releases the
//      keys, and the session starts.
//   9. The other system: the TPM refuses the passphrase, as PCR 11 differs;
//      a wrong recovery key opens nothing; the recovery key opens the keys,
//      and a new passphrase seals them again to this system.
//  10. The other system again: the passphrase opens the session; a console
//      of the session changes the passphrase (the current one first, which
//      the TPM checks), then makes a new recovery key, which the tool reads
//      off the screen. The console then asks for the machine passphrase,
//      and the lock comes while the window shows its recovery key: the
//      root service stops `unlock`, and no record of the machine is
//      written. After the lock the passphrase before the change is refused
//      and counted, and the changed one opens the keys. The tool serves
//      its disk, which drops the write of zeros of the erase over the file
//      of machine 9 (principal_change_with_a_dropped_zero_run).
//  11. The system of machines 7 and 8, where the TPM would refuse, as the
//      keys are sealed to the other system: Ctrl+R asks for the recovery
//      key with no try, and Enter with nothing goes back to the passphrase;
//      Ctrl+R again, the recovery key of machine 7 opens nothing, the new
//      one of machine 10 opens the keys, and the TPM seals them again to
//      this system.
//  12. The same system: one wrong passphrase, counted; with the one of
//      machine 8 and the one of machine 10, the TPM has counted three, the
//      most that libtpms allows by default, and refuses the right one
//      (TPM_RC_LOCKOUT); the recovery key opens the keys. This machine is
//      the last one that uses the TPM: the lockout lasts 1000 seconds of
//      the time of the TPM.
//
// Machines 1 to 6 use no passphrase, so the TPM service leaves the lockout
// hierarchy as it found it. Machine 7, the first seal with a passphrase,
// sets the lockout value; machines 8, 9, 10 and 12 find it at their first
// passphrase, and machine 11 at its new seal. After machine 12, the tool
// starts swtpm alone, as another system on the machine, and sends
// TPM2_DictionaryAttackLockReset with the empty value: a new TPM takes it,
// the TPM of the part refuses it (tpm_lockout_reset_tests_run).
//
// The TPM service sends TPM2_Shutdown after each use of the passphrase that
// is not a counted failure. After a counted failure it sends none, so a stop
// then would count one more failure at the next start. Each machine here
// that types a wrong passphrase ends its tries in the same run with an
// answer that is not a counted failure: machines 8 and 10 with the right
// passphrase, machine 12 with the lockout. A policy failure on another
// system counts nothing. So no start counts a failure of its own, and the
// counts are those of before: one failure on machine 8, one on machine 10,
// one on machine 12, and the lockout at the next try.

TEST_TPM_PRINCIPAL_DISK :: foundation.BUILD_FOLDER + "/test_tpm_principal_disk.img"
WRONG_PRINCIPAL_PASSPHRASE :: "not the passphrase of alice"
NEW_PRINCIPAL_PASSPHRASE :: "a new passphrase of alice"
// The passphrase that the change of machine 10 gives.
CHANGED_PRINCIPAL_PASSPHRASE :: "the changed passphrase of alice"

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
	// The first seal with a passphrase on this TPM: machines 1 to 6 used no
	// passphrase, so they left the lockout value empty.
	{kind = .Wait, text = TPM_LOCKOUT_SET_LINE, any_order = true, fails_on = TPM_LOCKOUT_FOUND_LINE},
	{kind = .Wait, text = "tpm: sealed 32 bytes to PCR 7 and PCR 11 and an authorization value, whose wrong tries the TPM counts: a public area of ", any_order = true},
	{kind = .Wait, text = "unlock: the keys of principal \"alice\" are sealed by the TPM to PCR 7 and PCR 11 and to its passphrase, under a key of Argon2id", any_order = true},
	// The file, the record and the session wait for Enter: a stop before
	// it leaves no principal whose recovery key nobody wrote down.
	{kind = .Wait, text = "unlock: the keys of the new principal \"alice\" are sealed by the TPM with its passphrase, with a copy under a recovery key; the window shows the recovery key one time, and the principal is created when it is written down", any_order = true, fails_on = "root: principal 1 \"alice\" is recorded"},
	// The recovery key, shown one time.
	{kind = .Front, text = "unlock"},
	{kind = .Screen_Text, text = "unlock", element = "recovery_key"},
	{kind = .Key, text = "ret"},
	// The line of Enter, in order: the record before it fails the step.
	{kind = .Wait, text = RECOVERY_KEY_ENTER_LINE, fails_on = "root: principal 1 \"alice\" is recorded"},
	{kind = .Wait, text = "root: principal 1 \"alice\" is recorded, its public key ", any_order = true},
	{kind = .Wait, text = "unlock: principal 1 \"alice\" is created: its keys are sealed by the TPM with its passphrase, with a copy under a recovery key", any_order = true},
	{kind = .Wait, text = "root: the session of principal 1 \"alice\" starts: the desktop starts each process in it", any_order = true},
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
	{kind = .Wait, text = TPM_LOCKOUT_FOUND_LINE, any_order = true, fails_on = TPM_LOCKOUT_SET_LINE},
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
	{kind = .Wait, text = "root: the session of principal 1 \"alice\" starts: the desktop starts each process in it", any_order = true},
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
	// The file of before the new seal is a version: unlock erases it.
	{kind = .Wait, text = PRINCIPAL_FILE_ERASED_LINE, any_order = true},
	{kind = .Wait, text = "root: the session of principal 1 \"alice\" starts: the desktop starts each process in it", any_order = true},
	{kind = .Wait, text = "root: unlock stopped with code 0", any_order = true},
}

// The line of unlock after the erase of the one version of the file of
// alice that a write made (src/md/features/version_erase.md).
@(private = "file")
PRINCIPAL_FILE_ERASED_LINE :: "unlock: the versions of the object \"principal\" are erased: 1 ended, "

// The line of the storage service when the read back of the zeros of an
// erase finds one block that the disk did not write, in two parts around
// the generation of the commit of the end (src/modules/system/storage/trees.odin).
@(private = "file")
ZEROS_DROPPED_LINE_START :: "storage: the versions of " + principals.FILE_OBJECT + " in the store " + UNLOCK_STORE + " are ended at the generation "
@(private = "file")
ZEROS_DROPPED_LINE_END :: ", and the read back of the zeros found 1 blocks with other bytes: the disk did not keep those writes, and their old bytes stay in free blocks until a commit takes them"
// The line of the storage service after the erase, before the count of
// the blocks that read back as zeros.
@(private = "file")
STORAGE_FILE_ERASED_LINE :: "storage: the versions of " + principals.FILE_OBJECT + " in the store " + UNLOCK_STORE + " are erased: 1 version ended, "

@(private = "file")
scenario_tpm_principal_other_system := [?]Step {
	{kind = .Type, text = PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = TPM_LOCKOUT_FOUND_LINE, any_order = true, fails_on = TPM_LOCKOUT_SET_LINE},
	{kind = .Wait, text = "tpm: the TPM refuses the unseal: PCR 7 and PCR 11 do not hold the values of the seal", any_order = true},
	{kind = .Wait, text = "unlock: the keys of principal 1 \"alice\" wait for their recovery key: the TPM does not release them", fails_on = "unlock: the TPM releases the keys"},
}

// Machine 10: the passphrase of machine 9 opens the session; a console of
// the session changes the passphrase, then makes a new recovery key, which
// the tool reads off the screen, then asks for the machine passphrase, and
// locks while the window shows its recovery key: no window of unlock
// outlives the lock. After the lock, the passphrase before the change is
// refused and counted, and the new one opens.
@(private = "file")
scenario_tpm_principal_change := [?]Step {
	{kind = .Type, text = NEW_PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = TPM_LOCKOUT_FOUND_LINE, any_order = true, fails_on = TPM_LOCKOUT_SET_LINE},
	{kind = .Wait, text = "unlock: the TPM releases the keys of principal 1 \"alice\" to its passphrase: the system is the system of the seal", any_order = true},
	{kind = .Wait, text = "root: the session of principal 1 \"alice\" starts: the desktop starts each process in it", any_order = true},
	{kind = .Wait, text = "root: unlock stopped with code 0", any_order = true},
	// A console of the session acts for alice: the console of the machine
	// cannot ask for a change.
	{kind = .Launch, text = "console"},
	{kind = .Wait, text = "root: started console, with a terminal, in the session of principal 1 \"alice\""},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Front, text = "console"},
	// The change of the passphrase: the current one proves it, then the new
	// one two times. The TPM seals the keys again.
	{kind = .Type, text = "passphrase_change()"},
	{kind = .Wait, text = "root: the passphrase of principal 1 \"alice\" changes in the window of unlock"},
	{kind = .Wait, text = "unlock: principal 1 \"alice\" asks for a change: its current passphrase comes first", any_order = true},
	{kind = .Wait, text = "compositor: surface unlock", any_order = true},
	{kind = .Front, text = "unlock"},
	// The recovery key is no proof of a change: Ctrl+R at the current
	// passphrase does nothing, and types nothing, so the passphrase that
	// follows opens the keys.
	{kind = .Key, text = "ctrl-r"},
	{kind = .Type, text = NEW_PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = "tpm: unsealed 32 bytes: PCR 7 and PCR 11 hold the values of the seal, and the authorization value is right", any_order = true},
	{kind = .Wait, text = "unlock: the current passphrase of principal 1 \"alice\" opens its keys", fails_on = "is asked in the window"},
	{kind = .Type, text = CHANGED_PRINCIPAL_PASSPHRASE},
	{kind = .Type, text = CHANGED_PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = "tpm: sealed 32 bytes to PCR 7 and PCR 11 and an authorization value, whose wrong tries the TPM counts: a public area of ", any_order = true},
	{kind = .Wait, text = "unlock: the passphrase of principal 1 \"alice\" is changed: the TPM seals its keys to PCR 7 and PCR 11 and to the new passphrase", any_order = true},
	// The disk does not keep the write of zeros over the block of the file
	// of machine 9: the read back of the zeros finds it.
	{kind = .Wait, text = ZEROS_DROPPED_LINE_END, any_order = true},
	{kind = .Wait, text = PRINCIPAL_FILE_ERASED_LINE, any_order = true},
	// The end goes to the console that asked, and the window shows it
	// until Enter.
	{kind = .Wait, text = "root: the change in the window of unlock ends: the passphrase is changed"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "root: unlock stopped with code 0"},
	// A new recovery key: the current passphrase, then the key, shown one
	// time. The tool keeps the key of machine 7 as the text before.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "recovery_key_change()"},
	{kind = .Wait, text = "root: a new recovery key of principal 1 \"alice\" is made in the window of unlock"},
	{kind = .Wait, text = "compositor: surface unlock", any_order = true},
	{kind = .Front, text = "unlock"},
	{kind = .Type, text = CHANGED_PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = "unlock: the current passphrase of principal 1 \"alice\" opens its keys"},
	{kind = .Wait, text = "unlock: principal 1 \"alice\" has a new recovery key, and the window shows it one time; the file is written when it is written down", any_order = true},
	{kind = .Screen_Text, text = "unlock", element = "recovery_key"},
	// Enter after the key is written down: the file is written only now.
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "unlock: the new recovery key of principal 1 \"alice\" is kept: a file written from now opens with it only"},
	{kind = .Wait, text = PRINCIPAL_FILE_ERASED_LINE, any_order = true},
	{kind = .Wait, text = "root: the change in the window of unlock ends: the new recovery key is kept; the old one opens no new file", any_order = true},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "root: unlock stopped with code 0"},
	// A console of the session asks for the machine passphrase: the TPM
	// seals the machine key with it, and the window shows the recovery key.
	// The lock comes before Enter.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "machine_passphrase()"},
	{kind = .Wait, text = "root: the machine passphrase is set in the window of unlock"},
	{kind = .Wait, text = "compositor: surface unlock", any_order = true},
	{kind = .Front, text = "unlock"},
	{kind = .Type, text = MACHINE_PASSPHRASE},
	{kind = .Type, text = MACHINE_PASSPHRASE},
	{kind = .Wait, text = "tpm: sealed 32 bytes to PCR 7 and PCR 11 and an authorization value, whose wrong tries the TPM counts: a public area of ", any_order = true},
	{kind = .Wait, text = "unlock: the window shows the recovery key of the new machine passphrase one time; the record is written when it is written down"},
	// The recovery key is on the screen at the lock. The read keeps no
	// text: machine 11 types the recovery key of machine 7 and the new one
	// of this machine, the two texts kept before.
	{kind = .Screen_Text, text = "unlock", element = "recovery_key", shown_only = true},
	// The lock from the console of the session, which stops with it. The
	// lock stops the window of unlock too: nobody at the locked machine
	// reads the recovery key or sets the machine passphrase. No record was
	// written before Enter, so the unlock of the lock asks for no machine
	// passphrase. The passphrase before the change is wrong now: the TPM
	// counts it.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "lock()"},
	{kind = .Wait, text = "root: the session of principal 1 \"alice\" ends: "},
	{kind = .Wait, text = "root: the lock stops the window of unlock, which ran for the machine passphrase that is set; unlock asks for the passphrase when it stopped", fails_on = "unlock: the machine passphrase is set"},
	{kind = .Wait, text = "root: unlock stopped with code "},
	{kind = .Wait, text = "unlock: principal 1 \"alice\" is locked: its passphrase opens its session", any_order = true, fails_on = "unlock: the machine has a passphrase"},
	{kind = .Wait, text = "compositor: surface unlock", any_order = true},
	{kind = .Front, text = "unlock"},
	{kind = .Type, text = NEW_PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = "unlock: the passphrase of principal 1 \"alice\" is wrong: the TPM refuses it and counts it, nothing is unlocked (1 in all)", fails_on = TPM_SHUTDOWN_LINE},
	{kind = .Type, text = CHANGED_PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = "unlock: the TPM releases the keys of principal 1 \"alice\" to its passphrase: the system is the system of the seal", any_order = true},
	{kind = .Wait, text = "root: the session of principal 1 \"alice\" starts: the desktop starts each process in it", any_order = true},
	{kind = .Wait, text = "root: unlock stopped with code 0", any_order = true},
}

// Machine 11, on the system of machines 7 and 8, whose keys the TPM sealed
// to the other system: Ctrl+R asks for the recovery key with no try that
// the TPM counts, Enter with nothing goes back to the passphrase, and
// Ctrl+R asks again. The proof that no request reaches the TPM before the
// recovery is the wait for the lockout line after the recovery, in
// scenario_tpm_principal_old_recovery_key: the TPM service writes it at the
// first request of the run with an authorization value.
@(private = "file")
scenario_tpm_principal_recovery_with_no_try := [?]Step {
	{kind = .Key, text = "ctrl-r"},
	{kind = .Wait, text = "unlock: the recovery key of principal 1 \"alice\" is asked in the window: the TPM counts no try of its passphrase"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "unlock: the recovery key of principal 1 is not typed: the window asks for its passphrase again"},
	{kind = .Key, text = "ctrl-r"},
	{kind = .Wait, text = "unlock: the recovery key of principal 1 \"alice\" is asked in the window: the TPM counts no try of its passphrase"},
}

// Machine 11, after Ctrl+R: the recovery key of machine 7, which the new
// one of machine 10 replaced, opens nothing; the new one opens the keys,
// and the TPM seals them again to this system and to the changed
// passphrase. The new seal is the first request of the run with an
// authorization value: the TPM service finds the lockout value there.
@(private = "file")
scenario_tpm_principal_old_recovery_key := [?]Step {
	{kind = .Type, text = SCREEN_TEXT_BEFORE_MARK},
	{kind = .Wait, text = "unlock: the recovery key of principal 1 \"alice\" is wrong: the copy of its keys does not open, nothing is unlocked (1 in all)"},
	{kind = .Type, text = SCREEN_TEXT_MARK},
	{kind = .Wait, text = "unlock: the recovery key of principal 1 \"alice\" opens its keys"},
	{kind = .Wait, text = "unlock: principal 1 \"alice\" types a passphrase: the TPM seals its keys again to it and to the system that runs"},
	{kind = .Type, text = CHANGED_PRINCIPAL_PASSPHRASE},
	{kind = .Type, text = CHANGED_PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = TPM_LOCKOUT_FOUND_LINE, any_order = true, fails_on = TPM_LOCKOUT_SET_LINE},
	{kind = .Wait, text = "tpm: sealed 32 bytes to PCR 7 and PCR 11 and an authorization value, whose wrong tries the TPM counts: a public area of ", any_order = true},
	{kind = .Wait, text = "unlock: the keys of principal 1 \"alice\" are sealed again to PCR 7 and PCR 11 of the system that runs and to the new passphrase: its next unlock needs no recovery key", any_order = true},
	{kind = .Wait, text = "root: the session of principal 1 \"alice\" starts: the desktop starts each process in it", any_order = true},
	{kind = .Wait, text = "root: unlock stopped with code 0", any_order = true},
}

@(private = "file")
scenario_tpm_principal_lockout := [?]Step {
	// One failure of machine 8 and one of machine 10, the passphrase before
	// the change: one more wrong passphrase makes three.
	{kind = .Type, text = WRONG_PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = TPM_LOCKOUT_FOUND_LINE, any_order = true, fails_on = TPM_LOCKOUT_SET_LINE},
	{kind = .Wait, text = "unlock: the passphrase of principal 1 \"alice\" is wrong: the TPM refuses it and counts it, nothing is unlocked (1 in all)", fails_on = TPM_SHUTDOWN_LINE},
	// The right passphrase: the TPM refuses each try now.
	{kind = .Type, text = CHANGED_PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = "tpm: the TPM refuses the unseal: it counted too many wrong authorization values, and refuses each try for now (response code ", any_order = true, fails_on = "tpm: unsealed 32 bytes"},
	// The lockout is not a counted failure: the service sends TPM2_Shutdown.
	{kind = .Wait, text = TPM_SHUTDOWN_LINE, any_order = true},
	{kind = .Wait, text = "unlock: the TPM refuses each try of the passphrase of principal 1 \"alice\" for now: it counted too many wrong passphrases; the recovery key opens the keys"},
	{kind = .Wait, text = "unlock: the keys of principal 1 \"alice\" wait for their recovery key: the TPM does not release them"},
}

// The machines of the machine passphrase with the TPM
// (docs/PRINCIPALS.md, "The machine passphrase with the TPM"), after the
// reset tests, on a disk of their own and a new state of the software TPM:
// the count of the TPM of machines 1 to 12 stays as their steps need it,
// and machine 12 left that TPM in its lockout. Each one has Secure Boot on:
//
//  13. The signed main system: `machine_passphrase()`; the TPM seals the
//      machine key to PCR 7, PCR 11 and the machine passphrase; the window
//      shows the recovery key, which the tool reads off the screen. The
//      first use of a passphrase on this TPM sets the lockout value.
//  14. The same system: a wrong machine passphrase, which the TPM refuses
//      and counts, then the right one: the TPM releases the key, and the
//      disk grant table of machine 13 verifies under it.
//  15. The other system: the right machine passphrase, and the TPM refuses
//      it, as PCR 11 differs; a wrong recovery key opens nothing; the
//      recovery key of machine 13 opens the key, and a new machine
//      passphrase seals it again to this system.
//  16. The other system again: Ctrl+R asks for the recovery key with no
//      try, and Enter with nothing goes back to the passphrase; the
//      passphrase of machine 13 is refused and counted, and the new one
//      opens the key with no recovery.
TEST_TPM_MACHINE_PASSPHRASE_DISK :: foundation.BUILD_FOLDER + "/test_tpm_machine_passphrase_disk.img"
TPM_MACHINE_PASSPHRASE_STATE_FOLDER :: foundation.BUILD_FOLDER + "/test_tpm_machine_passphrase_state"
WRONG_MACHINE_PASSPHRASE :: "not the machine passphrase"
NEW_MACHINE_PASSPHRASE :: "a new machine passphrase"

@(private = "file")
scenario_tpm_machine_passphrase_set := [?]Step {
	{kind = .Front, text = "console"},
	{kind = .Type, text = "machine_passphrase()"},
	{kind = .Wait, text = "root: the machine passphrase is set in the window of unlock"},
	{kind = .Wait, text = "compositor: surface unlock"},
	{kind = .Front, text = "unlock"},
	{kind = .Type, text = MACHINE_PASSPHRASE},
	{kind = .Type, text = MACHINE_PASSPHRASE},
	// The first use of a passphrase on this new state of the TPM.
	{kind = .Wait, text = TPM_LOCKOUT_SET_LINE, any_order = true, fails_on = TPM_LOCKOUT_FOUND_LINE},
	{kind = .Wait, text = "tpm: sealed 32 bytes to PCR 7 and PCR 11 and an authorization value, whose wrong tries the TPM counts: a public area of ", any_order = true},
	{kind = .Wait, text = "unlock: the machine key is sealed by the TPM to PCR 7 and PCR 11 and to the machine passphrase, under a key of Argon2id, 19456 KiB and 2 passes, derived in ", any_order = true},
	// The record waits for Enter: the root service writes no table before
	// it.
	{kind = .Wait, text = "unlock: the window shows the recovery key of the new machine passphrase one time; the record is written when it is written down", any_order = true, fails_on = "root: the disk grant table of principal 0 is written"},
	// The recovery key, shown one time.
	{kind = .Front, text = "unlock"},
	{kind = .Screen_Text, text = "unlock", element = "recovery_key"},
	{kind = .Key, text = "ret"},
	// The line of Enter, in order: the table before it fails the step.
	{kind = .Wait, text = RECOVERY_KEY_ENTER_LINE, fails_on = "root: the disk grant table of principal 0 is written"},
	{kind = .Wait, text = "unlock: the machine passphrase is set: the TPM seals the machine key with it, with a copy under a recovery key, in the store of unlock"},
	{kind = .Wait, text = "root: the disk grant table of principal 0 is written in the store module_files: 0 rows, with the tag of the machine key", any_order = true},
	{kind = .Wait, text = "root: unlock stopped with code 0"},
}

// The start of a machine with the record of the machine passphrase sealed
// by the TPM: unlock asks for the machine passphrase.
@(private = "file")
tpm_machine_passphrase_asked := [?]Step {
	{kind = .Wait, text = "root: the machine has a passphrase: the disk grants of principal 0 wait for it, and the machine runs", any_order = true},
	{kind = .Wait, text = "unlock: the machine has a passphrase: the disk grants of principal 0 come when it is typed", any_order = true},
	{kind = .Wait, text = "compositor: surface unlock", any_order = true},
	{kind = .Front, text = "unlock"},
}

@(private = "file")
scenario_tpm_machine_passphrase_same_system := [?]Step {
	{kind = .Type, text = WRONG_MACHINE_PASSPHRASE},
	{kind = .Wait, text = TPM_LOCKOUT_FOUND_LINE, any_order = true, fails_on = TPM_LOCKOUT_SET_LINE},
	{kind = .Wait, text = "tpm: the TPM refuses the unseal: the authorization value is wrong, and the TPM counted the failure (response code ", any_order = true},
	// No TPM2_Shutdown after a counted failure: its line would come before
	// the line of unlock.
	{kind = .Wait, text = "unlock: the machine passphrase is wrong: the TPM refuses it and counts it, the disk grants of principal 0 stay absent (1 in all)", fails_on = TPM_SHUTDOWN_LINE},
	{kind = .Type, text = MACHINE_PASSPHRASE},
	{kind = .Wait, text = "tpm: unsealed 32 bytes: PCR 7 and PCR 11 hold the values of the seal, and the authorization value is right", any_order = true},
	// The right passphrase sends TPM2_Shutdown: the stop of this machine
	// counts no failure at the start of the next one.
	{kind = .Wait, text = TPM_SHUTDOWN_LINE, any_order = true},
	{kind = .Wait, text = "unlock: the TPM releases the machine key to the machine passphrase: the system is the system of the seal; the root service receives the key of the disk grant table only", any_order = true},
	{kind = .Wait, text = "root: read the disk grant table of principal 0 from the store module_files: 0 rows, with the tag of the machine key", any_order = true},
	{kind = .Wait, text = "root: unlock stopped with code 0", any_order = true},
}

// Another system: the right machine passphrase opens nothing, and the
// recovery key opens the key; a new machine passphrase seals it again.
@(private = "file")
scenario_tpm_machine_passphrase_other_system := [?]Step {
	{kind = .Type, text = MACHINE_PASSPHRASE},
	{kind = .Wait, text = TPM_LOCKOUT_FOUND_LINE, any_order = true, fails_on = TPM_LOCKOUT_SET_LINE},
	{kind = .Wait, text = "tpm: the TPM refuses the unseal: PCR 7 and PCR 11 do not hold the values of the seal", any_order = true},
	{kind = .Wait, text = "unlock: the machine key waits for its recovery key: the disk grants of principal 0 come when it is typed", fails_on = "unlock: the TPM releases the machine key"},
	{kind = .Type, text = WRONG_RECOVERY_KEY},
	{kind = .Wait, text = "unlock: the recovery key is wrong: the copy of the machine key does not open, the disk grants of principal 0 stay absent (1 in all)"},
	{kind = .Type, text = SCREEN_TEXT_MARK},
	{kind = .Wait, text = "unlock: the recovery key opens the machine key; the root service receives the key of the disk grant table only"},
	{kind = .Wait, text = "root: read the disk grant table of principal 0 from the store module_files: 0 rows, with the tag of the machine key", any_order = true},
	{kind = .Wait, text = "unlock: the machine key waits for a new machine passphrase: the TPM seals it again to it and to the system that runs", any_order = true},
	{kind = .Type, text = NEW_MACHINE_PASSPHRASE},
	{kind = .Type, text = NEW_MACHINE_PASSPHRASE},
	{kind = .Wait, text = "tpm: sealed 32 bytes to PCR 7 and PCR 11 and an authorization value, whose wrong tries the TPM counts: a public area of ", any_order = true},
	{kind = .Wait, text = "unlock: the machine key is sealed again to PCR 7 and PCR 11 of the system that runs and to the new machine passphrase: its next start needs no recovery key", any_order = true},
	// The record of machine 13 is a version now: unlock erases it.
	{kind = .Wait, text = "unlock: the versions of the object \"machine\" are erased: 1 ended, ", any_order = true},
	{kind = .Wait, text = "root: unlock stopped with code 0", any_order = true},
}

// Machine 16, the other system after the new seal of machine 15: Ctrl+R
// asks for the recovery key with no try that the TPM counts, and Enter with
// nothing goes back to the passphrase. The passphrase of machine 13 is
// wrong now, as the new seal has the value of the new one: the TPM refuses
// it and counts it, the second failure on this TPM after the one of machine
// 14. The new passphrase opens the key with no recovery.
@(private = "file")
scenario_tpm_machine_passphrase_after_the_new_seal := [?]Step {
	{kind = .Key, text = "ctrl-r"},
	{kind = .Wait, text = "unlock: the recovery key of the machine key is asked in the window: the TPM counts no try of the machine passphrase", fails_on = "the TPM refuses it and counts it"},
	{kind = .Wait, text = "unlock: the machine key waits for its recovery key: the disk grants of principal 0 come when it is typed"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "unlock: the recovery key of the machine key is not typed: the window asks for the machine passphrase again", fails_on = "unlock: the recovery key is not typed"},
	{kind = .Type, text = MACHINE_PASSPHRASE},
	{kind = .Wait, text = TPM_LOCKOUT_FOUND_LINE, any_order = true, fails_on = TPM_LOCKOUT_SET_LINE},
	{kind = .Wait, text = "tpm: the TPM refuses the unseal: the authorization value is wrong, and the TPM counted the failure (response code ", any_order = true},
	{kind = .Wait, text = "unlock: the machine passphrase is wrong: the TPM refuses it and counts it, the disk grants of principal 0 stay absent (1 in all)", fails_on = TPM_SHUTDOWN_LINE},
	{kind = .Type, text = NEW_MACHINE_PASSPHRASE},
	{kind = .Wait, text = "tpm: unsealed 32 bytes: PCR 7 and PCR 11 hold the values of the seal, and the authorization value is right", any_order = true},
	{kind = .Wait, text = TPM_SHUTDOWN_LINE, any_order = true},
	{kind = .Wait, text = "unlock: the TPM releases the machine key to the machine passphrase: the system is the system of the seal; the root service receives the key of the disk grant table only", any_order = true},
	{kind = .Wait, text = "root: read the disk grant table of principal 0 from the store module_files: 0 rows, with the tag of the machine key", any_order = true},
	{kind = .Wait, text = "root: unlock stopped with code 0", any_order = true},
}

// tpm_key_machine_run runs one machine of the part: the start, the steps,
// the end, with the state of the TPM given, then prints what the log of
// its software TPM shows.
@(private = "file")
tpm_key_machine_run :: proc(part: ^Test_Part_Run, step_groups: [][]Step, volume: string, firmware: Machine_Firmware, number: int, disk: string = TEST_TPM_KEY_DISK, tpm_state: string = TPM_KEY_STATE_FOLDER, disk_server: ^Network_Block_Device = nil) -> bool {
	// Not in the temporary allocator: the tool frees it after each step.
	all := make([dynamic]Step)
	defer delete(all)
	append(&all, tpm_key_start[0])
	// The boot program says who verified it before it measures: the state
	// of Secure Boot that the rule of the seal reads is the one of the
	// machine, not a guess of the scenario.
	verifier_line := firmware == .With_Secure_Boot ? SECURE_BOOT_VERIFIED_LINE : BOOT_PROGRAM_ONLY_VERIFIED_LINE
	append(&all, Step{kind = .Wait, text = verifier_line, seconds = TPM_MACHINE_STEP_SECONDS})
	append(&all, ..tpm_key_start[1:])
	// The TPM service writes this line after its line "ok", before it serves
	// its ring. The lines of the lockout value come at the first use of a
	// passphrase, in the steps of machines 7 to 10.
	append(&all, Step{kind = .Wait, text = TPM_COUNT_LIMITS_LINE, any_order = true})
	for group in step_groups {
		append(&all, ..group)
	}
	append(&all, ..tpm_key_end[:])
	output := self_test_file(TEST_OUTPUT_TPM_KEY, number)
	passed := machine_test(part, all[:], {volume = volume, output = output, exit_status = MACHINE_STOP_OK, data_disk = disk, disk_server = disk_server, firmware = firmware, tpm_state = tpm_state, tpm_device = true})
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
	disk := Module_Disk {
		image = make([]u8, DATA_DISK_SIZE),
		next  = 2,
	}
	defer delete(disk.image)
	root := new(format.Root, context.temp_allocator)
	root.magic = format.ROOT_MAGIC
	root.generation = MODULE_DISK_GENERATION
	root.disk_blocks = u64(DATA_DISK_SIZE) / format.BLOCK_SIZE
	files := [1]Module_File{{name = principals.MACHINE_OBJECT, bytes = changed}}
	root.stores[0] = module_files_store_put(&disk, UNLOCK_STORE, files[:], DATA_DISK_SIZE) or_return
	root.check = format.root_check(root)
	copy(disk.image[:format.BLOCK_SIZE], ([^]u8)(root)[:format.BLOCK_SIZE])
	if err := os.write_entire_file(TEST_TPM_KEY_CHANGED_TICKET_DISK, disk.image); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", TEST_TPM_KEY_CHANGED_TICKET_DISK, err)
		return false
	}
	fmt.printfln("modustool: %s: the record of the machine key with one byte of its creation ticket changed", TEST_TPM_KEY_CHANGED_TICKET_DISK)
	return true
}

// The secret parts of a file of a named principal in the form PRINCIPT:
// the salt of its passphrase, its keys under the seal key, and its keys
// under its recovery key. Each one is random bytes, so a copy of it on the
// disk is a copy of that file.
@(private = "file")
Principal_File_Parts :: struct {
	salt:            [principals.SALT_SIZE]u8,
	sealed:          [principals.SEALED_SIZE]u8,
	recovery_sealed: [principals.SEALED_SIZE]u8,
}

// principal_file_parts_read reads the file of alice from the disk of the
// keys of a named principal, as the storage service opens it, and gives
// its secret parts.
@(private = "file")
principal_file_parts_read :: proc() -> (parts: Principal_File_Parts, ok: bool) {
	image, read_error := os.read_entire_file(TEST_TPM_PRINCIPAL_DISK, context.allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: test failed: cannot read %s: %v", TEST_TPM_PRINCIPAL_DISK, read_error)
		return {}, false
	}
	defer delete(image)
	state := new(storage_mount.State)
	defer free(state)
	contents := disk_contents(image, state)
	file: []u8
	for &item in contents.objects {
		if item.store == UNLOCK_STORE && item.name == principals.FILE_OBJECT && !item.tree && !item.damaged {
			file = item.bytes
		}
	}
	if len(file) != principals.PRINCIPAL_TPM_FILE_SIZE || string(file[:len(principals.PRINCIPAL_TPM_MAGIC)]) != principals.PRINCIPAL_TPM_MAGIC {
		fmt.eprintfln("modustool: test failed: %s holds no file of a named principal sealed by the TPM in the store %s (%d bytes)", TEST_TPM_PRINCIPAL_DISK, UNLOCK_STORE, len(file))
		return {}, false
	}
	copy(parts.salt[:], file[principals.OFFSET_SALT:][:principals.SALT_SIZE])
	copy(parts.sealed[:], file[principals.PRINCIPAL_TPM_OFFSET_SEALED:][:principals.SEALED_SIZE])
	copy(parts.recovery_sealed[:], file[principals.PRINCIPAL_TPM_OFFSET_RECOVERY_SEALED:][:principals.SEALED_SIZE])
	return parts, true
}

// principal_change_with_a_dropped_zero_run runs machine 10 on the disk that
// the tool serves, from the image that machine 9 left. The disk answers Ok
// to the first write of zeros over the block that holds the salt of the
// file of machine 9, and keeps its old bytes
// (src/md/features/version_erase.md). After
// the machine, the image goes back to the disk file of the part, and the
// count of the blocks written with zeros in the line of the storage service
// and in the row that unlock writes must be the count of the zeros that
// the disk kept. It gives the block that the disk did not write with zeros.
@(private = "file")
principal_change_with_a_dropped_zero_run :: proc(part: ^Test_Part_Run, parts: ^Principal_File_Parts) -> (dropped_block: u64, ok: bool) {
	image, read_error := os.read_entire_file(TEST_TPM_PRINCIPAL_DISK, context.allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: test failed: cannot read %s: %v", TEST_TPM_PRINCIPAL_DISK, read_error)
		return 0, false
	}
	server: Network_Block_Device
	started := disk_server_start(&server, image)
	delete(image)
	if !started {
		return 0, false
	}
	defer disk_server_free(&server)
	// The thread of the server reads the bytes at the first write; no
	// machine is connected yet.
	sync.mutex_lock(&server.lock)
	server.zero_drop_bytes = parts.salt[:]
	sync.mutex_unlock(&server.lock)
	// Not in the temporary allocator: the tool frees it after each step.
	address := fmt.aprintf("nbd://127.0.0.1:%d", server.port)
	defer delete(address)
	ran := tpm_key_machine_run(part, [][]Step{tpm_principal_locked[:], scenario_tpm_principal_change[:]}, BOOT_VOLUME_OTHER_SYSTEM, .With_Secure_Boot, 10, address, disk_server = &server)
	disk_server_stop(&server)
	if !ran {
		return 0, false
	}
	sync.mutex_lock(&server.lock)
	defer sync.mutex_unlock(&server.lock)
	if server.zero_drop_state != .Flushed {
		fmt.eprintfln("modustool: test failed: the disk did not drop a write of zeros over the block of the file of alice before the change, with a flush after it: the state %v", server.zero_drop_state)
		return 0, false
	}
	// The machine stopped: the current image is what a disk file holds.
	if err := os.write_entire_file(TEST_TPM_PRINCIPAL_DISK, server.current); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", TEST_TPM_PRINCIPAL_DISK, err)
		return 0, false
	}
	output := self_test_file(TEST_OUTPUT_TPM_KEY, 10)
	defer delete(output)
	log_bytes, log_error := os.read_entire_file(output, context.allocator)
	if log_error != nil {
		fmt.eprintfln("modustool: test failed: cannot read %s: %v", output, log_error)
		return 0, false
	}
	defer delete(log_bytes)
	text := string(log_bytes)
	// The line of the dropped zero names the object and the store of the
	// file; the scenario waited for its end.
	line_at := strings.index(text, ZEROS_DROPPED_LINE_START)
	line := line_at < 0 ? "" : text[line_at:]
	if end := strings.index_byte(line, '\n'); end >= 0 {
		line = line[:end]
	}
	if !strings.contains(line, ZEROS_DROPPED_LINE_END) {
		fmt.eprintfln("modustool: test failed: %s has no line \"%s...%s\"", output, ZEROS_DROPPED_LINE_START, ZEROS_DROPPED_LINE_END)
		return 0, false
	}
	kept := i64(server.zero_blocks_kept_with_drop)
	storage_zeroed, storage_found := number_after(text, STORAGE_FILE_ERASED_LINE)
	unlock_zeroed, unlock_found := number_after(text, PRINCIPAL_FILE_ERASED_LINE)
	if !storage_found || !unlock_found || storage_zeroed != kept || unlock_zeroed != kept {
		fmt.eprintfln("modustool: test failed: the disk kept %d blocks of zeros of the erase and dropped the write of block %d; the line of the storage service counts %d blocks written with zeros (found: %v), and the row that unlock writes %d (found: %v)", kept, server.zero_dropped_block, storage_zeroed, storage_found, unlock_zeroed, unlock_found)
		return 0, false
	}
	foundation.test_passed_print("the disk dropped the write of zeros over block %d, which held the file of alice before the change; the read back of the zeros found it, and the line of the storage service and the row of unlock count the %d blocks of zeros that the disk kept", server.zero_dropped_block, kept)
	return server.zero_dropped_block, true
}

// principal_file_parts_absent searches each byte of the disk of the keys
// of a named principal, named blocks and free blocks alike, for the secret
// parts of a file from before a change. The erase of the versions leaves
// them only in the block whose write of zeros the disk dropped, and there
// only while that block is free (src/md/features/version_erase.md).
@(private = "file")
principal_file_parts_absent :: proc(parts: ^Principal_File_Parts, dropped_block: u64) -> bool {
	image, read_error := os.read_entire_file(TEST_TPM_PRINCIPAL_DISK, context.allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: test failed: cannot read %s: %v", TEST_TPM_PRINCIPAL_DISK, read_error)
		return false
	}
	defer delete(image)
	Searched :: struct {
		what:  string,
		bytes: []u8,
	}
	searched := [3]Searched{{"its salt", parts.salt[:]}, {"its keys under the seal key", parts.sealed[:]}, {"its keys under the recovery key", parts.recovery_sealed[:]}}
	text := string(image)
	salt_in_dropped_block := false
	for item, item_index in searched {
		for from := 0; from < len(text); {
			found := strings.index(text[from:], string(item.bytes))
			if found < 0 {
				break
			}
			at := from + found
			first_block := u64(at / format.BLOCK_SIZE)
			last_block := u64((at + len(item.bytes) - 1) / format.BLOCK_SIZE)
			if first_block != dropped_block || last_block != dropped_block {
				fmt.eprintfln("modustool: test failed: the disk holds %s from the file of alice before the change, at the byte %d (the block %d), outside the block %d whose write of zeros the disk dropped", item.what, at, first_block, dropped_block)
				return false
			}
			if item_index == 0 {
				salt_in_dropped_block = true
			}
			from = at + 1
		}
	}
	// The disk that the engine left opens as the storage service opens it:
	// no root names a block of zeros, and the file has no version.
	state := new(storage_mount.State)
	defer free(state)
	contents := disk_contents(image, state)
	mounted := contents.mount
	if mounted.failed || mounted.wrong != 0 || mounted.damaged_objects != 0 || mounted.damaged_versions != 0 || storage_mount.hash_index_check(state) != 0 {
		fmt.eprintfln("modustool: test failed: the disk after the erase opens with %d wrong blocks, %d damaged objects, %d damaged versions, %d faults of the hash index (failed: %v)", mounted.wrong, mounted.damaged_objects, mounted.damaged_versions, storage_mount.hash_index_check(state), mounted.failed)
		return false
	}
	file := stored_object_of(&contents, UNLOCK_STORE, principals.FILE_OBJECT)
	if file == nil || file.damaged || file.versions_damaged || len(file.versions) != 0 {
		fmt.eprintfln("modustool: test failed: after the erase, the file of alice in the store %s is absent, damaged, or has versions (%d)", UNLOCK_STORE, file == nil ? 0 : len(file.versions))
		return false
	}
	// A free block keeps the bytes that the disk did not write over, as
	// the log said; a block that a later commit took holds that commit.
	dropped_block_free := dropped_block < u64(len(image)) / format.BLOCK_SIZE && state.references[dropped_block] == 0
	if dropped_block_free && !salt_in_dropped_block {
		fmt.eprintfln("modustool: test failed: the block %d is free, and does not hold the salt of the file of alice before the change: the disk wrote over it, or the test dropped the write of another block", dropped_block)
		return false
	}
	if dropped_block_free {
		foundation.test_passed_print("the disk of %d bytes holds the file of alice before the change only in the free block %d, whose write of zeros it dropped, as the log of the storage service says; the store erased its versions and wrote zeros over each other block", len(image), dropped_block)
	} else {
		foundation.test_passed_print("the disk of %d bytes holds none of the salt, the keys under the seal key and the keys under the recovery key of the file of alice before the change: a later commit took the block %d, whose write of zeros the disk dropped", len(image), dropped_block)
	}
	foundation.test_passed_print("the disk after the erase opens at the generation %d with no wrong block, and the file of alice has no version", mounted.generation)
	return true
}

// tpm_lockout_reset_try starts swtpm alone on a state of the software TPM,
// as another system on the machine finds the TPM, and sends it
// TPM2_DictionaryAttackLockReset with the empty value of the lockout
// hierarchy. It gives the response code of the TPM; ok is false when the
// tool could not ask, or the answer is not an answer of a TPM.
@(private = "file")
tpm_lockout_reset_try :: proc(state_folder: string, number: int) -> (code: u32, ok: bool) {
	alone := tpm_alone_start(state_folder, self_test_file(TEST_OUTPUT_TPM_LOCKOUT, number)) or_return
	defer tpm_alone_stop(&alone)
	command: [64]u8
	count := tpm2.dictionary_attack_lock_reset_command(command[:])
	answer: [TPM_TOOL_ANSWER_LIMIT]u8
	bytes := tpm_alone_transact(&alone, command[:count], answer[:], "TPM2_DictionaryAttackLockReset") or_return
	status_code, problem := tpm2.status_answer(bytes)
	if problem == .Malformed {
		fmt.eprintfln("modustool: test failed: the answer of swtpm to TPM2_DictionaryAttackLockReset does not have the form of an answer (%s)", alone.tpm.folder)
		return 0, false
	}
	return status_code, true
}

// A software TPM that runs alone, with no QEMU, on a state of the software
// TPM of a part: the tool sends it the commands that another system on the
// machine can send.
Tpm_Alone :: struct {
	tpm:        Tpm_Host_Process,
	connection: linux.Fd, // The Unix socket of the commands, in the folder of the output.
}

// The Unix sockets of swtpm alone, in the folder of its output: no port of
// the loopback, which a machine of another part that runs at the same time
// could hold.
TPM_ALONE_SERVER_SOCKET :: "/server.socket"
TPM_ALONE_CONTROL_SOCKET :: "/control.socket"

// tpm_alone_start starts swtpm alone on a state of the software TPM, in the
// folder of the output given, and connects to its socket of the commands.
tpm_alone_start :: proc(state_folder: string, output: string) -> (alone: Tpm_Alone, ok: bool) {
	folder := tpm_folder_of(output)
	foundation.reset_folder(folder) or_return
	log := strings.concatenate({"file=", folder, "/swtpm.log,level=20"}, context.temp_allocator)
	server_path := strings.concatenate({folder, TPM_ALONE_SERVER_SOCKET}, context.temp_allocator)
	server := strings.concatenate({"type=unixio,path=", server_path}, context.temp_allocator)
	control := strings.concatenate({"type=unixio,path=", folder, TPM_ALONE_CONTROL_SOCKET}, context.temp_allocator)
	// not-need-init and startup-clear: swtpm starts the TPM itself, as the
	// firmware of a machine does, with no QEMU.
	host_process, start_error := os.process_start({command = {"swtpm", "socket", "--tpm2", "--tpmstate", strings.concatenate({"dir=", state_folder}, context.temp_allocator), "--server", server, "--ctrl", control, "--flags", "not-need-init,startup-clear", "--log", log}, stdout = os.stderr, stderr = os.stderr})
	if start_error != nil {
		fmt.eprintfln("modustool: cannot start swtpm: %v. Use the development shell: nix develop", start_error)
		return {}, false
	}
	alone.tpm = Tpm_Host_Process{host_process = host_process, started = true, folder = strings.clone(folder)}

	// Wait until swtpm takes a connection.
	start := time.tick_now()
	for {
		connection, connected := call_socket_connect(server_path)
		if connected {
			alone.connection = connection
			break
		}
		if time.tick_since(start) > TPM_START_TIMEOUT {
			fmt.eprintfln("modustool: test failed: swtpm took no connection at %s in %v", server_path, TPM_START_TIMEOUT)
			tpm_stop(&alone.tpm)
			return {}, false
		}
		time.sleep(CONDITION_POLL_PERIOD)
	}
	return alone, true
}

// tpm_alone_stop closes the connection and ends swtpm, which writes its
// state.
tpm_alone_stop :: proc(alone: ^Tpm_Alone) {
	call_socket_close(alone.connection)
	tpm_stop(&alone.tpm)
}

// tpm_alone_transact sends one command and gives its whole answer, in the
// buffer given: the size of its header bounds it. what names the command in
// a line of a failure.
tpm_alone_transact :: proc(alone: ^Tpm_Alone, command: []u8, answer: []u8, what: string) -> (bytes: []u8, ok: bool) {
	if len(command) == 0 || !call_socket_send_all(alone.connection, command) {
		fmt.eprintfln("modustool: test failed: the command %s did not go to swtpm (%s)", what, alone.tpm.folder)
		return nil, false
	}
	// The header of an answer has its size in bytes 2 to 5, big-endian.
	HEADER_SIZE :: 10
	received := 0
	size := HEADER_SIZE
	// The receive of the socket ends after its own short time with no byte;
	// the bound only ends a wait for a TPM that does not answer.
	start := time.tick_now()
	for received < size {
		got, receive_error := linux.recv(alone.connection, answer[received:size], {})
		if (receive_error == .EAGAIN || receive_error == .EINTR) && time.tick_since(start) < foundation.HANG_BOUND {
			continue
		}
		if receive_error != .NONE || got <= 0 {
			fmt.eprintfln("modustool: test failed: swtpm gave %d bytes of an answer of %d to %s: %v (%s)", received, size, what, receive_error, alone.tpm.folder)
			return nil, false
		}
		received += got
		if received >= HEADER_SIZE && size == HEADER_SIZE {
			size = int(u32(answer[2]) << 24 | u32(answer[3]) << 16 | u32(answer[4]) << 8 | u32(answer[5]))
			if size < HEADER_SIZE || size > len(answer) {
				fmt.eprintfln("modustool: test failed: swtpm gave an answer of %d bytes to %s (%s)", size, what, alone.tpm.folder)
				return nil, false
			}
		}
	}
	return answer[:size], true
}

// tpm_lockout_reset_tests_run sends the reset of the count with the empty
// lockout value, as another system on the machine can, first to a new
// state of the TPM, which takes it, then to the TPM of the part after
// machine 12, which refuses it: the service set a value there at machine 7.
// The first one proves that the bytes of the command reset the count of a
// TPM with an empty value, so the refusal of the second one comes from its
// value. The TPM of the part answers TPM_RC_AUTH_FAIL: no machine of the
// TPM runs after it, and the lockout hierarchy then waits. The answer is
// TPM_RC_AUTH_FAIL only because machine 12 ends with TPM2_Shutdown: after a
// start that is not orderly, a TPM can close the lockout hierarchy and
// answer TPM_RC_LOCKOUT; read that cause first if the code is 0x921.
@(private = "file")
tpm_lockout_reset_tests_run :: proc() -> bool {
	foundation.reset_folder(TPM_LOCKOUT_EMPTY_STATE_FOLDER) or_return
	code := tpm_lockout_reset_try(TPM_LOCKOUT_EMPTY_STATE_FOLDER, 1) or_return
	if code != tpm2.RESPONSE_SUCCESS {
		fmt.eprintfln("modustool: test failed: a new TPM, whose lockout value is empty, refused TPM2_DictionaryAttackLockReset with the empty value (response code 0x%X)", code)
		return false
	}
	foundation.test_passed_print("%s", "a new TPM, whose lockout value is empty, took TPM2_DictionaryAttackLockReset from another system")
	code = tpm_lockout_reset_try(TPM_KEY_STATE_FOLDER, 2) or_return
	if !tpm2.authorization_fails(code) {
		fmt.eprintfln("modustool: test failed: the TPM whose lockout value the TPM service set answered 0x%X to TPM2_DictionaryAttackLockReset with the empty value, not TPM_RC_AUTH_FAIL", code)
		return false
	}
	foundation.test_passed_print("the TPM whose lockout value the TPM service set refused TPM2_DictionaryAttackLockReset from another system (response code 0x%X): the count of the wrong passphrases holds", code)
	return true
}

// principals_tpm_tests_run runs the six machines of the machine key, then
// the six of the keys of a named principal, on a new disk and a new state
// of the software TPM, then the four of the machine passphrase with the
// TPM, on a disk and a state of their own.
principals_tpm_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	disk_prepare(TEST_TPM_KEY_DISK, DATA_DISK_SIZE, true) or_return
	foundation.reset_folder(TPM_KEY_STATE_FOLDER) or_return
	screen_text_forget(part)
	tpm_key_machine_run(part, [][]Step{tpm_key_new_disk_and_font[:], scenario_tpm_key_seal[:]}, BOOT_VOLUME_SECURE_BOOT, .With_Secure_Boot, 1) or_return
	foundation.test_passed_print("%s", "machine_seal() sealed the machine key by the TPM, and the window of unlock showed its recovery key")
	tpm_key_machine_run(part, [][]Step{scenario_tpm_key_same_system[:]}, BOOT_VOLUME_SECURE_BOOT, .With_Secure_Boot, 2) or_return
	foundation.test_passed_print("%s", "the same system: the TPM proved the creation and released the machine key with no typing")
	tpm_key_machine_run(part, [][]Step{scenario_tpm_key_recovery[:], scenario_tpm_key_reseal[:]}, BOOT_VOLUME_OTHER_SYSTEM, .With_Secure_Boot, 3) or_return
	foundation.test_passed_print("%s", "another system: the TPM refused, the recovery key opened the machine key, and it was sealed again")
	tpm_key_machine_run(part, [][]Step{scenario_tpm_key_same_system[:]}, BOOT_VOLUME_OTHER_SYSTEM, .With_Secure_Boot, 4) or_return
	foundation.test_passed_print("%s", "the other system after the recovery: the TPM released the machine key with no typing")
	// The record that machine 4 opened, with one byte of its ticket changed,
	// on a disk of its own: the disk of the part stays as it is.
	tpm_key_changed_ticket_disk_write() or_return
	tpm_key_machine_run(part, [][]Step{scenario_tpm_key_changed_ticket[:]}, BOOT_VOLUME_OTHER_SYSTEM, .With_Secure_Boot, 5, TEST_TPM_KEY_CHANGED_TICKET_DISK) or_return
	foundation.test_passed_print("%s", "one byte of the creation ticket changed: the TPM refused the ticket, and nothing was unsealed")
	// The system of the seal of machine 3 with Secure Boot off: the firmware
	// with no Secure Boot starts the signed boot program too, so only PCR 7
	// differs.
	tpm_key_machine_run(part, [][]Step{scenario_tpm_key_recovery[:], scenario_tpm_key_secure_boot_off[:]}, BOOT_VOLUME_OTHER_SYSTEM, .With_Tpm_Driver, 6) or_return
	foundation.test_passed_print("%s", "the same system with Secure Boot off: the TPM refused for PCR 7 alone, the recovery key opened the machine key, and no seal trusts the boot program")
	fmt.println("modustool: the machine key sealed by the TPM: 6 machines passed")
	principals_tpm_principal_tests_run(part) or_return
	return true
}

// principals_tpm_principal_tests_run runs the six machines of the keys of a
// named principal, on a new disk and the state of the software TPM that the
// machines of the machine key left.
@(private = "file")
principals_tpm_principal_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	disk_prepare(TEST_TPM_PRINCIPAL_DISK, DATA_DISK_SIZE, true) or_return
	screen_text_forget(part)
	tpm_key_machine_run(part, [][]Step{tpm_key_new_disk_and_font[:], scenario_tpm_principal_create[:]}, BOOT_VOLUME_SECURE_BOOT, .With_Secure_Boot, 7, TEST_TPM_PRINCIPAL_DISK) or_return
	foundation.test_passed_print("%s", "principal_create() sealed the keys of alice by the TPM with her passphrase, and the window of unlock showed her recovery key")
	tpm_key_machine_run(part, [][]Step{tpm_principal_locked[:], scenario_tpm_principal_same_system[:]}, BOOT_VOLUME_SECURE_BOOT, .With_Secure_Boot, 8, TEST_TPM_PRINCIPAL_DISK) or_return
	foundation.test_passed_print("%s", "the same system: the TPM counted a wrong passphrase, and released the keys to the right one")
	tpm_key_machine_run(part, [][]Step{tpm_principal_locked[:], scenario_tpm_principal_other_system[:], tpm_principal_recovery_and_new_passphrase[:]}, BOOT_VOLUME_OTHER_SYSTEM, .With_Secure_Boot, 9, TEST_TPM_PRINCIPAL_DISK) or_return
	foundation.test_passed_print("%s", "another system: the TPM refused the passphrase, the recovery key opened the keys, and a new passphrase sealed them again")
	// The file of alice before the change, as the store holds it: its secret
	// parts must leave the disk with the change.
	old_parts := principal_file_parts_read() or_return
	dropped_block := principal_change_with_a_dropped_zero_run(part, &old_parts) or_return
	foundation.test_passed_print("%s", "a console of the session changed the passphrase and the recovery key; the lock stopped the window that showed the recovery key of a machine passphrase, which was not written; the old passphrase was refused and counted, and the new one opened the keys")
	principal_file_parts_absent(&old_parts, dropped_block) or_return
	tpm_key_machine_run(part, [][]Step{tpm_principal_locked[:], scenario_tpm_principal_recovery_with_no_try[:], scenario_tpm_principal_old_recovery_key[:]}, BOOT_VOLUME_SECURE_BOOT, .With_Secure_Boot, 11, TEST_TPM_PRINCIPAL_DISK) or_return
	foundation.test_passed_print("%s", "another system: Ctrl+R asked for the recovery key with no try, the recovery key before the change opened nothing, and the new one opened the keys")
	tpm_key_machine_run(part, [][]Step{tpm_principal_locked[:], scenario_tpm_principal_lockout[:], tpm_principal_recovery_and_new_passphrase[:]}, BOOT_VOLUME_SECURE_BOOT, .With_Secure_Boot, 12, TEST_TPM_PRINCIPAL_DISK) or_return
	foundation.test_passed_print("%s", "the TPM counted each wrong passphrase, refused each try after three, and the recovery key opened the keys")
	fmt.println("modustool: the keys of a named principal sealed by the TPM: 6 machines passed")
	// After the last machine of the TPM: the try of the reset closes the
	// lockout hierarchy of that TPM for its recovery time.
	tpm_lockout_reset_tests_run() or_return
	principals_tpm_machine_passphrase_tests_run(part) or_return
	return true
}

// principals_tpm_machine_passphrase_tests_run runs the four machines of the
// machine passphrase with the TPM, on a new disk and a new state of the
// software TPM.
@(private = "file")
principals_tpm_machine_passphrase_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	disk_prepare(TEST_TPM_MACHINE_PASSPHRASE_DISK, DATA_DISK_SIZE, true) or_return
	foundation.reset_folder(TPM_MACHINE_PASSPHRASE_STATE_FOLDER) or_return
	screen_text_forget(part)
	tpm_key_machine_run(part, [][]Step{tpm_key_new_disk_and_font[:], scenario_tpm_machine_passphrase_set[:]}, BOOT_VOLUME_SECURE_BOOT, .With_Secure_Boot, 13, TEST_TPM_MACHINE_PASSPHRASE_DISK, TPM_MACHINE_PASSPHRASE_STATE_FOLDER) or_return
	foundation.test_passed_print("%s", "machine_passphrase() on a machine with the TPM: the TPM sealed the machine key with the machine passphrase, and the window of unlock showed its recovery key")
	tpm_key_machine_run(part, [][]Step{tpm_machine_passphrase_asked[:], scenario_tpm_machine_passphrase_same_system[:]}, BOOT_VOLUME_SECURE_BOOT, .With_Secure_Boot, 14, TEST_TPM_MACHINE_PASSPHRASE_DISK, TPM_MACHINE_PASSPHRASE_STATE_FOLDER) or_return
	foundation.test_passed_print("%s", "the same system: the TPM counted a wrong machine passphrase, and released the machine key to the right one")
	tpm_key_machine_run(part, [][]Step{tpm_machine_passphrase_asked[:], scenario_tpm_machine_passphrase_other_system[:]}, BOOT_VOLUME_OTHER_SYSTEM, .With_Secure_Boot, 15, TEST_TPM_MACHINE_PASSPHRASE_DISK, TPM_MACHINE_PASSPHRASE_STATE_FOLDER) or_return
	foundation.test_passed_print("%s", "another system: the TPM refused the right machine passphrase, the recovery key opened the machine key, and a new machine passphrase sealed it again")
	tpm_key_machine_run(part, [][]Step{tpm_machine_passphrase_asked[:], scenario_tpm_machine_passphrase_after_the_new_seal[:]}, BOOT_VOLUME_OTHER_SYSTEM, .With_Secure_Boot, 16, TEST_TPM_MACHINE_PASSPHRASE_DISK, TPM_MACHINE_PASSPHRASE_STATE_FOLDER) or_return
	foundation.test_passed_print("%s", "the other system after the new seal: Ctrl+R asked for the recovery key with no try, the passphrase before the new seal was refused and counted, and the new one opened the machine key")
	fmt.println("modustool: the machine passphrase with the TPM: 4 machines passed")
	return true
}
