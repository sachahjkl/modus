// The unlock of a named principal (docs/PRINCIPALS.md): the process that
// keeps the record of a named principal in its private store, and asks for
// its passphrase in its window.
//
// A principal is a key pair: an Ed25519 key, to sign grants, and an X25519
// key, to unlock documents. Its record is the file "principal" of the store
// of this process: its name, its two public keys, and its two secret keys
// sealed with ChaCha20-Poly1305 under a key that Argon2id derives from the
// passphrase and a salt (src/library/support/principals). A wrong passphrase gives
// another key, and the seal does not open: no passphrase and no hash of it
// is kept or compared.
//
// The root service starts this process at boot. With no file it stops at
// once: the machine runs as principal 0 only, with no unlock. With a file
// it gives the public part of the record to the root service and asks for
// the passphrase; when the seal opens, it tells the root service, which
// starts the session of the principal, and it stops. With that command it
// gives the root service one key: the key of the tag of the disk grant
// table of the principal, which keyed BLAKE2b gives from the secret unlock
// key. The secret keys are then erased. The root service
// starts it again after a lock. To create a principal, the root service
// starts it with a name: the passphrase is typed two times, the keys are
// made from the generator of the process, and the session starts.
//
// The passphrase shows as dots. On a machine with the TPM service and
// Secure Boot on, the file of a new principal has the form sealed by the TPM
// (docs/PRINCIPALS.md, "The keys sealed by the TPM"): the TPM releases a
// secret only to the system of the seal and to the authorization value that
// the passphrase gives, and counts each wrong passphrase; the secret and the
// passphrase together open the keys. A recovery key, shown one time at the
// creation, opens a copy of the keys when the TPM refuses or when the
// passphrase is lost; a new passphrase then seals them again. With no TPM
// service, or with Secure Boot off, the keys are sealed under the passphrase
// alone: the strength of that file is the strength of the passphrase
// against Argon2id with 19 MiB and 2 passes, on a copy of the disk.
//
// It also keeps the record of the machine key, the object "machine" of its
// store, in one of three forms
// (docs/PRINCIPALS.md, "Principal 0 and its machine passphrase";
// docs/PRINCIPALS.md, "The machine passphrase with the TPM";
// docs/PRINCIPALS.md, "The machine key sealed by the TPM"):
//
// - the machine key, 32 random bytes, sealed under the machine passphrase.
//   With the TPM service and Secure Boot on, the TPM seals it with the
//   passphrase, as the keys of a named principal: the TPM counts each wrong
//   machine passphrase, another system opens nothing with the right one,
//   and a recovery key, shown one time, opens a copy. Else the passphrase
//   alone seals it. With either record, and when the root service does not
//   hold the key yet, it asks for the machine passphrase first. The root
//   service starts it with the mode Unlock_Mode.Set_Machine_Passphrase after
//   `machine_passphrase()`;
// - the machine key sealed by the TPM service to PCR 7 and PCR 11, with a
//   copy under a recovery key. At each start the TPM releases the key with
//   no typing; when it refuses (another system, another machine, no TPM),
//   the window asks for the recovery key, and the key is sealed again to
//   the system that runs. The root service starts it with the mode
//   Unlock_Mode.Seal_Machine_Key after `machine_seal()`: the window shows the
//   recovery key one time.
//
// When a record gives the machine key, it gives the root service the key of
// the tag of the disk grant table of principal 0, which the machine key
// gives, and erases the other keys: the root service then needs no key
// that opens a seal.
//
// **What it is for.** It separates who holds the machine (principal 0) from
// a named principal whose processes run in a session of their own, with
// stores of their own. It is the only process that the root service
// believes when it says that a passphrase opened a seal.
//
// **Start**: the root service starts it; no line of the console does.
//
// - At boot, and again after `lock()` in the console.
// - With a name, after `principal_create("alice")` in the console: the
//   window asks for the passphrase two times.
// - During a session, after `passphrase_change()` or
//   `recovery_key_change()` in a console of the session: the window asks
//   for the current passphrase, then for the new one, or shows the new
//   recovery key (docs/PRINCIPALS.md, "A change of the passphrase").
//
// A lock stops it, whatever its mode: no window that a session asked for
// outlives the session (docs/PRINCIPALS.md, "4. The unlock and the lock").
//
// **Grants**, as the root service gives them:
//
// - **Store**: its private store, which holds the file "principal".
// - **Principals**: a ring to the root service for `Principal_Record`,
//   `Principal_Unlock`, `Machine_Key` and `Principal_Change_End` only. No other process can send
//   these commands, so no other process can start a session or give the
//   key of a disk grant table.
// - **Tpm**: the ring and the region of the TPM service, when the system is
//   measured into a TPM: Seal and Unseal only (modus:contract/tpm_service).
// - **Versions_Erase**: the storage service lets it end the versions of
//   the objects of its own store, with zeros over their blocks
//   ([erase_versions](storage.erase_versions)). No other process has it.
//
// **What a reader sees**: a window with the name of the principal and the
// passphrase as dots; Enter tries it, Backspace removes one byte, Escape
// clears it. The log has, for example:
//
// - `unlock: principal 1 "alice" is locked: its passphrase opens its session`;
// - `unlock: the passphrase of principal 1 "alice" opens its seal; ...`;
// - `unlock: the passphrase of principal 1 "alice" is wrong: ...`;
// - `unlock: the machine passphrase opens the machine key; ...`;
// - `unlock: the TPM releases the machine key: the system is the system of
//   the seal; ...`.
//
// **What it does not prove**: the secret keys sign and decrypt nothing yet;
// the unlock key only gives the key of the tag of the disk grant table.
// With the file under the passphrase alone, a wrong passphrase costs one
// derivation of Argon2id, and nothing counts or slows the tries.
//
// The design: (docs/PRINCIPALS.md, "4. The unlock and the lock").
package unlock

import "base:intrinsics"
import "modus:contract/errors"
import "modus:contract/ring"
import "modus:contract/text_encoding"
import "modus:contract/tpm_service"
import "modus:support/disk_process"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/principals"
import "modus:support/random"
import "modus:support/storage"
import "modus:contract/root_ring"
import "modus:support/system"
import "modus:support/tpm2"

// The blocks of Argon2id, 19 MiB (4864 pages)
// (src/library/support/principals, DERIVATION_MEMORY_PAGES).
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 5765, processes = 1, threads = 1, window_width = WIDTH, window_height = HEIGHT}

// The cost record of the export argon2id of the module cryptography: the
// same fields, in the same order (src/modules/libraries/cryptography).
Argon2id_Cost :: struct {
	memory_kibibytes: i64,
	passes:           i64,
	lanes:            i64,
	tag_bytes:        i64,
}

foreign _ {
	argon2id :: proc "c" (password, salt: ^string, cost: ^Argon2id_Cost, work: ^system.Bytes_To_Change, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	seal_with_chacha20_poly1305 :: proc "c" (key, nonce, additional, text: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	open_with_chacha20_poly1305 :: proc "c" (key, nonce, additional, sealed: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	x25519 :: proc "c" (scalar, point: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	ed25519_public_key :: proc "c" (secret: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
}

WIDTH :: 520
HEIGHT :: 180
// The bound of an answer of the root service: it answers each command at
// once, so this bound only ends a wait for a service that stopped.
ROOT_ANSWER_LIMIT :: 10_000

records_now, records_before: [320]interface.Draw_Record
text_now, text_before: [4096]u8
drawing: interface.Window_Drawing

Mode :: enum {
	Unlock, // The passphrase of the principal of the file.
	Create_First, // The passphrase of a new principal.
	Create_Again, // The same passphrase again.
	Machine_Unlock, // The machine passphrase, before the passphrase of a named principal.
	Machine_Create_First, // A new machine passphrase.
	Machine_Create_Again, // The same machine passphrase again.
	Machine_Recovery, // The TPM did not release the machine key: the recovery key, before the passphrase of a named principal.
	Machine_Reseal_First, // The recovery key opened a machine key sealed with the machine passphrase: a new machine passphrase that seals it again.
	Machine_Reseal_Again, // The same machine passphrase again.
	Machine_Reseal_Result, // The new seal after a recovery failed: its sentence, shown until Enter, before the named principal.
	Recovery_Shown, // The recovery key of a new machine key sealed by the TPM, shown one time.
	Principal_Recovery, // The TPM did not release the keys of the named principal: its recovery key.
	Principal_Recovery_Shown, // A new recovery key of a named principal sealed by the TPM, shown one time.
	New_Passphrase_First, // The recovery key or the current passphrase opened the keys: a new passphrase that seals them again.
	New_Passphrase_Again, // The same passphrase again.
	Change_Current, // A change that the principal asked for: its current passphrase, which proves it.
	Change_Result, // The end of a change, shown until Enter: what changed, or why nothing changed.
	Write_Result, // The store did not keep the record or the file whose recovery key was shown: the sentence until Enter.
	Write_Unknown, // The store did not answer the write, and the read back failed: the record or the file may be on the disk, so its recovery key stays shown until Enter.
	Done,
}

// The write that waits for Enter while the window shows a new recovery
// key: nothing is written before its principal wrote the key down, so a
// stop (a lock, a close, a fault) loses no key that nobody saw. A new
// recovery key of a change has its own file (renewed_recovery_file).
Pending_Write :: enum u8 {
	None,
	Principal_Created, // The file of a new principal sealed by the TPM, then its record and its session.
	Machine_Passphrase_Set, // The record of a machine passphrase sealed by the TPM, then the key of the table.
	Machine_Key_Sealed, // The record of a machine key sealed by the TPM alone, then the key of the table.
}
pending_write: Pending_Write

mode: Mode
// The change that the root service started this process for:
// .Change_Passphrase or .New_Recovery_Key. Any other mode, as the zero
// value .Unlock, is no change.
change_mode: principals.Unlock_Mode
principal_found: bool // The store holds the file of a named principal: its unlock comes after the machine key.

// The record of the machine key, as the store gave it, in its form.
machine_form: principals.Machine_Record_Form
machine_file: principals.Machine_File
machine_file_bytes: [principals.MACHINE_FILE_SIZE]u8
machine_tpm_file: principals.Machine_Tpm_File
machine_tpm_file_bytes: [principals.MACHINE_TPM_FILE_SIZE]u8
machine_tpm_passphrase_file: principals.Machine_Tpm_Passphrase_File
machine_tpm_passphrase_file_bytes: [principals.MACHINE_TPM_PASSPHRASE_FILE_SIZE]u8
machine_refusals: u64 // The wrong machine passphrases and recovery keys since the start.
// The machine key that a recovery key opened, until a new machine
// passphrase seals it again by the TPM; erased then, or at Enter with
// nothing. Also a new machine key, while the window shows its recovery
// key, until the write of its record after Enter.
opened_machine_key: [principals.MACHINE_KEY_SIZE]u8

// The TPM service: its ring and its region, when the root service gave
// them. The first tag is random: a completion that an earlier run of this
// process left in the ring never has the tag of a command of this run.
has_tpm: bool
tpm_requests: ring.Ring
tpm_region: []u8
tpm_tag: u32
tpm_process: system.Handle // The TPM service, with the right Read: its state says at once when it stopped.
seal_allowed: bool // The firmware verified the boot program: a seal and a new seal are allowed (principals.VALUE_SEAL_ALLOWED).
// The bound of an answer of the TPM service. It only ends a wait for a TPM
// that does not answer; the service ends each request at its own bound,
// which is below this one, and a stop of the service ends the wait at once.
TPM_ANSWER_LIMIT :: 600_000

// The recovery key of a new seal, as its user reads it, while the window
// shows it; erased when the window ends it.
recovery_text: [principals.RECOVERY_TEXT_SIZE]u8
// The most characters of a typed recovery key: its 39 characters and some
// spaces. The typed text is drawn: a recovery key is copied from paper.
RECOVERY_TYPED_LIMIT :: principals.RECOVERY_TEXT_SIZE + 8
requests: ring.Ring
request_tag: u32
generator: random.Generator
client: storage.Client

name: [principals.NAME_LIMIT]u8
name_length: int
number: u64 // The number of the principal in the root service.
// The file of the named principal, in its form: under the passphrase alone
// (file), or sealed by the TPM with the passphrase (principal_tpm_file).
principal_form: principals.Principal_Record_Form
file: principals.Principal_File
file_bytes: [principals.FILE_SIZE]u8
principal_tpm_file: principals.Principal_Tpm_File
principal_tpm_file_bytes: [principals.PRINCIPAL_TPM_FILE_SIZE]u8
// The public keys of the named principal, from its file in either form.
signing_public_key: [principals.PUBLIC_KEY_SIZE]u8
unlock_public_key: [principals.PUBLIC_KEY_SIZE]u8
// The secret keys that a recovery key, or the current passphrase of a
// change, opened, until a new passphrase seals them again; erased then.
// Also the keys of a new principal, while the window shows its recovery
// key, until the write of its file and the start of its session after
// Enter.
opened_secrets: [principals.SECRET_KEYS_SIZE]u8
// The file with the copy under a new recovery key, while the window shows
// that key: it is written only after Enter, so a key that nobody saw never
// becomes the key of the file.
renewed_recovery_file: principals.Principal_Tpm_File
renewed_recovery_bytes: [principals.PRINCIPAL_TPM_FILE_SIZE]u8

typed: [principals.PASSPHRASE_LIMIT]u8
typed_count: int
first: [principals.PASSPHRASE_LIMIT]u8 // The first passphrase of a creation, until the second one.
first_count: int
message: string = ""
message_failed: bool
refusals: u64 // The wrong passphrases since the start.

// The blocks of Argon2id: 19 MiB, one memory object of this process.
work: system.Bytes_To_Change

// erase writes 0 over a secret with volatile stores, which the compiler
// cannot remove.
erase :: proc "contextless" (bytes: []u8) {
	for &item in bytes {
		intrinsics.volatile_store(&item, 0)
	}
}

the_name :: proc "contextless" () -> string {
	return string(name[:name_length])
}

// object_versions_erase ends the versions of an object of the store of
// unlock, and the store writes zeros over their blocks. A version of the
// file of a principal opens with the passphrase or the recovery key from
// before a change, and a version of the record of the machine key with the
// seal from before a recovery (src/md/features/version_erase.md). Only
// unlock holds the grant Versions_Erase for it. An object with no version
// changes nothing, so each unlock asks again once the current file or
// record opened: a stop between a write and its erase is repaired then.
object_versions_erase :: proc "contextless" (object: string) {
	error: errors.Error_Record
	measure, status := storage.erase_versions(&client, storage.ROOT, object, &error)
	switch {
	case status != .Ok:
		text: [240]u8
		writer := system.Writer{buffer = text[:]}
		if status == .Failed {
			storage.error_text(&writer, &client, &error)
		}
		system.log("unlock: the store did not erase the versions of the object \"", object, "\": status ", u64(status), " ", system.written(&writer), "; the next unlock tries again")
	case measure.versions != 0 || measure.damaged != 0:
		system.log("unlock: the versions of the object \"", object, "\" are erased: ", u64(measure.versions), " ended, ", u64(measure.zeroed), " blocks written with zeros, ", u64(measure.kept), " blocks kept that another state names, ", u64(measure.damaged), " damaged parts with no zeros")
	}
}

// root_command sends a command of the principals to the root service and
// waits for its completion.
root_command :: proc "contextless" (kind: root_ring.Root_Command, values: [7]u64) -> (completion: ring.Record, answered: bool) {
	request_tag += 1
	if !system.send(&requests.commands, ring.Record{kind = u32(kind), tag = request_tag, values = values}) {
		return {}, false
	}
	limit := system.time() + ROOT_ANSWER_LIMIT
	for {
		for record in system.receive(&requests.completions) {
			if record.tag == request_tag {
				return record, true
			}
		}
		wait: system.Wait
		system.wait_records(&wait, &requests.completions)
		if system.wait_end(&wait, limit) >= limit {
			return {}, false
		}
	}
}

// record_give gives the public part of the record to the root service, and
// keeps the number that it answers.
record_give :: proc "contextless" () -> bool {
	key := transmute([4]u64)signing_public_key
	packed := principals.name_pack(the_name())
	completion, answered := root_command(.Principal_Record, {key[0], key[1], key[2], key[3], packed[0], packed[1], packed[2]})
	if !answered || system.Status(completion.kind) != .Ok {
		system.log("unlock: the root service did not take the record of the principal \"", the_name(), "\": status ", u64(completion.kind))
		return false
	}
	number = completion.values[0]
	return true
}

// derive gives the key of a seal from a passphrase and the salt of its
// record.
derive :: proc "contextless" (passphrase: []u8, salt_bytes: []u8, key: ^[principals.KEY_SIZE]u8) -> bool {
	password := string(passphrase)
	salt := string(salt_bytes)
	result := key^[:]
	error: errors.Error_Record
	cost := Argon2id_Cost {
		memory_kibibytes = principals.DERIVATION_MEMORY_KIBIBYTES,
		passes           = principals.DERIVATION_PASSES,
		lanes            = 1,
		tag_bytes        = principals.KEY_SIZE,
	}
	count := argon2id(&password, &salt, &cost, &work, &result, &error)
	if count != principals.KEY_SIZE {
		system.log("unlock: Argon2id refused the derivation: kind ", error.kind, ", argument ", error.argument)
		return false
	}
	return true
}

// public_keys_of gives the two public keys of the two secret keys.
public_keys_of :: proc "contextless" (secrets: ^[principals.SECRET_KEYS_SIZE]u8) -> (signing, unlocking: [principals.PUBLIC_KEY_SIZE]u8, ok: bool) {
	error: errors.Error_Record
	seed := string(secrets^[:32])
	signing_result := signing[:]
	if ed25519_public_key(&seed, &signing_result, &error) != 32 {
		return {}, {}, false
	}
	base_point: [32]u8
	base_point[0] = 9 // The base point of X25519 (RFC 7748, section 4.1).
	scalar := string(secrets^[32:])
	point := string(base_point[:])
	unlocking_result := unlocking[:]
	if x25519(&scalar, &point, &unlocking_result, &error) != 32 {
		return {}, {}, false
	}
	return signing, unlocking, true
}

// create makes a new principal: its keys, its file, its record in the root
// service, and its session. With the TPM service and Secure Boot on, the
// TPM seals the keys with the passphrase; else the passphrase alone does.
create :: proc "contextless" () {
	if has_tpm && seal_allowed {
		create_sealed_by_the_tpm()
		return
	}
	if has_tpm {
		system.log("unlock: the firmware did not verify the boot program (Secure Boot is off): the keys of the new principal are sealed under its passphrase alone, as a seal by the TPM would trust a boot program that nothing verified")
	} else {
		system.log("unlock: no TPM service: the keys of the new principal are sealed under its passphrase alone, with no recovery key")
	}
	secrets: [principals.SECRET_KEYS_SIZE]u8
	defer erase(secrets[:])
	error: errors.Error_Record
	// The keys come from the generator of this process, seeded by the root
	// service from the sources of the processor; a weak seed is refused.
	if !random.fill_for_a_key(&generator, secrets[:], .Processor, &error) {
		system.log("unlock: the seed of this process is too weak for a key: no principal is created")
		message, message_failed = "the seed of the machine is too weak for a key", true
		return
	}
	ok: bool
	file.signing_public_key, file.unlock_public_key, ok = public_keys_of(&secrets)
	if !ok {
		message, message_failed = "the module cryptography refused the keys", true
		return
	}
	file.name, file.name_length = name, name_length
	signing_public_key, unlock_public_key = file.signing_public_key, file.unlock_public_key
	principal_form = .Passphrase
	derived, sealed := passphrase_file_seal(&secrets, &file, &file_bytes)
	if !sealed {
		return
	}
	if _, status := storage.write(&client, storage.ROOT, principals.FILE_OBJECT, file_bytes[:]); status != .Ok {
		system.log("unlock: the store did not keep the file of the principal: status ", u64(status))
		message, message_failed = "the store did not keep the principal", true
		return
	}
	if !record_give() {
		message, message_failed = "the root service did not take the record", true
		return
	}
	system.log("unlock: principal ", number, " \"", the_name(), "\" is created: its keys are sealed in the store of unlock under a key of Argon2id, 19456 KiB and 2 passes, derived in ", derived, " ms")
	session_start(&secrets, root_ring.Principal_Key_Origin.New)
}

// passphrase_file_seal seals the secret keys in a file of the form under the
// passphrase alone: a new salt and a new nonce, the key of the passphrase
// typed, and the seal. The name and the public keys are in the file
// already. It gives the milliseconds of the derivation. On a failure the
// file can be half written: the caller writes it to the store only on
// success.
passphrase_file_seal :: proc "contextless" (secrets: ^[principals.SECRET_KEYS_SIZE]u8, sealed_file: ^principals.Principal_File, sealed_bytes: ^[principals.FILE_SIZE]u8) -> (derived: u64, ok: bool) {
	key: [principals.KEY_SIZE]u8
	defer erase(key[:])
	error: errors.Error_Record
	// A new salt and a new nonce at each seal: a nonce is never used again
	// under one key.
	if !random.fill_for_a_key(&generator, sealed_file.salt[:], .Processor, &error) || !random.fill_for_a_key(&generator, sealed_file.nonce[:], .Processor, &error) {
		system.log("unlock: the seed of this process is too weak for a key: the keys are not sealed")
		message, message_failed = "the seed of the machine is too weak for a key", true
		return 0, false
	}
	started := system.time()
	if !derive(typed[:typed_count], sealed_file.salt[:], &key) {
		message, message_failed = "the derivation of the key failed", true
		return 0, false
	}
	derived = system.time() - started
	principals.file_encode(sealed_file, sealed_bytes)
	key_text := string(key[:])
	nonce_text := string(sealed_file.nonce[:])
	additional := string(principals.file_additional_data(sealed_bytes))
	text := string(secrets^[:])
	sealed := sealed_file.sealed[:]
	if seal_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &text, &sealed, &error) != principals.SEALED_SIZE {
		message, message_failed = "the seal of the keys failed", true
		return 0, false
	}
	principals.file_encode(sealed_file, sealed_bytes)
	return derived, true
}

// public_keys_match says if two secret keys give the public keys of the
// file: a file whose public part does not match its seal is refused.
public_keys_match :: proc "contextless" (secrets: ^[principals.SECRET_KEYS_SIZE]u8) -> bool {
	signing, unlocking, ok := public_keys_of(secrets)
	return ok && signing == signing_public_key && unlocking == unlock_public_key
}

// What the passphrase typed gave when it opened the keys of the file.
Open_Outcome :: enum u8 {
	Opened, // The keys opened, and they give the public keys of the file.
	Derivation_Failed, // Argon2id gave no key.
	Wrong, // A wrong passphrase: the seal does not open, or the TPM refused its value and counted it.
	Locked_Out, // The TPM counted too many wrong passphrases, and refuses each try for now.
	Tpm_Refused, // The TPM did not release the TPM secret: another system, no answer, a record that it did not make.
	Not_Consistent, // The seal opened, and its keys are not the keys of the public part of the file.
}

// principal_keys_open opens the keys of the file of the named principal
// with the passphrase typed, in the form of the file. A wrong passphrase
// gives another key: the open fails. In the form sealed by the TPM, the
// TPM counts it.
principal_keys_open :: proc "contextless" (secrets: ^[principals.SECRET_KEYS_SIZE]u8) -> Open_Outcome {
	if principal_form == .Sealed_By_The_Tpm {
		return principal_tpm_open(secrets)
	}
	key: [principals.KEY_SIZE]u8
	defer erase(key[:])
	if !derive(typed[:typed_count], file.salt[:], &key) {
		return .Derivation_Failed
	}
	error: errors.Error_Record
	key_text := string(key[:])
	nonce_text := string(file.nonce[:])
	additional := string(principals.file_additional_data(&file_bytes))
	sealed := string(file.sealed[:])
	result := secrets^[:]
	if open_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &sealed, &result, &error) != principals.SECRET_KEYS_SIZE {
		return .Wrong
	}
	// The secret keys must be the keys of the record: a file whose public
	// part does not match its seal is refused.
	if !public_keys_match(secrets) {
		return .Not_Consistent
	}
	return .Opened
}

// passphrase_try opens the keys with the passphrase typed, and starts the
// session. A wrong passphrase opens nothing; when the TPM refuses, the
// window asks for the recovery key.
passphrase_try :: proc "contextless" () {
	secrets: [principals.SECRET_KEYS_SIZE]u8
	defer erase(secrets[:])
	sealed_by_the_tpm := principal_form == .Sealed_By_The_Tpm
	switch principal_keys_open(&secrets) {
	case .Derivation_Failed:
		message, message_failed = "the derivation of the key failed", true
	case .Wrong:
		refusals += 1
		if sealed_by_the_tpm {
			system.log("unlock: the passphrase of principal ", number, " \"", the_name(), "\" is wrong: the TPM refuses it and counts it, nothing is unlocked (", refusals, " in all)")
			message, message_failed = "the passphrase is wrong: the TPM counts each wrong try", true
		} else {
			system.log("unlock: the passphrase of principal ", number, " \"", the_name(), "\" is wrong: the seal does not open, nothing is unlocked (", refusals, " in all)")
			message, message_failed = "the passphrase is wrong: nothing is unlocked", true
		}
	case .Locked_Out:
		system.log("unlock: the TPM refuses each try of the passphrase of principal ", number, " \"", the_name(), "\" for now: it counted too many wrong passphrases; the recovery key opens the keys")
		principal_recovery_ask("the TPM refuses tries for now: type the recovery key")
	case .Tpm_Refused:
		principal_recovery_ask("the TPM refuses: type the recovery key of the principal")
	case .Not_Consistent:
		if sealed_by_the_tpm {
			system.log("unlock: the keys of principal ", number, " do not open under the secret that the TPM released: the file is not consistent, and the recovery key opens them")
			principal_recovery_ask("the file is not consistent: type the recovery key")
		} else {
			system.log("unlock: the sealed keys of principal ", number, " do not match its public keys: nothing is unlocked")
			message, message_failed = "the record is not consistent: nothing is unlocked", true
		}
	case .Opened:
		if sealed_by_the_tpm {
			system.log("unlock: the TPM releases the keys of principal ", number, " \"", the_name(), "\" to its passphrase: the system is the system of the seal; the root service receives the key of its disk grant table only, and the secret keys are erased")
		} else {
			system.log("unlock: the passphrase of principal ", number, " \"", the_name(), "\" opens its seal; the root service receives the key of its disk grant table only, and the secret keys are erased")
		}
		session_start(&secrets, root_ring.Principal_Key_Origin.Opened)
	}
}

// machine_key_give gives the root service the key of the tag of the disk
// grant table of principal 0, which the machine key gives, and nothing
// else: the root service needs no key that opens the record. origin is
// .Opened or .New: the root service writes over a table that does not
// verify only under a key of a new passphrase.
machine_key_give :: proc "contextless" (machine_key: ^[principals.MACHINE_KEY_SIZE]u8, origin: root_ring.Machine_Key_State) -> bool {
	// The current record gave the machine key: an erase that a stop missed
	// is done now, as for the file of a principal. A new key opened no
	// record.
	if origin == .Opened {
		object_versions_erase(principals.MACHINE_OBJECT)
	}
	table_key := disk_process.table_key_of_machine_key(machine_key)
	values := transmute([4]u64)table_key
	defer erase(table_key[:])
	defer erase(([^]u8)(rawptr(&values))[:size_of(values)])
	completion, answered := root_command(.Machine_Key, {values[0], values[1], values[2], values[3], u64(origin), 0, 0})
	if !answered || system.Status(completion.kind) != .Ok {
		system.log("unlock: the root service did not take the key of the disk grant table of principal 0: status ", u64(completion.kind))
		return false
	}
	return true
}

// after_machine goes on after the machine passphrase: to the passphrase of
// the named principal of the file, or to the end.
after_machine :: proc "contextless" () {
	erase(typed[:])
	typed_count = 0
	if !principal_found {
		mode = .Done
		return
	}
	principal_ask()
}

// principal_ask asks for the passphrase of the named principal of the file,
// or for its recovery key when its keys are sealed by the TPM and no TPM
// service runs.
principal_ask :: proc "contextless" () {
	if principal_form == .Sealed_By_The_Tpm && !has_tpm {
		system.log("unlock: the keys of principal ", number, " \"", the_name(), "\" are sealed by the TPM, and no TPM service runs: the recovery key opens them")
		principal_recovery_ask("no TPM: type the recovery key of the principal")
		return
	}
	mode = .Unlock
	message, message_failed = "", false
	system.log("unlock: principal ", number, " \"", the_name(), "\" is locked: its passphrase opens its session")
}

// no_screen_stop ends a run that needs typing on a machine with no screen,
// with one line that names what cannot be typed and what stays absent. The
// root service starts no `unlock` again on such a machine.
no_screen_stop :: proc "contextless" () -> ! {
	if mode == .Machine_Unlock || mode == .Machine_Recovery {
		system.log("unlock: no screen: the machine passphrase and the recovery key of the machine key cannot be typed: the disk grants of principal 0 and its client keys of remote stay absent")
	} else if mode == .Unlock || mode == .Principal_Recovery {
		system.log("unlock: no screen: the passphrase of principal ", number, " \"", the_name(), "\" cannot be typed: its session stays locked")
	} else {
		system.log("unlock: no screen: the window of unlock cannot be shown: nothing is typed, and nothing changes")
	}
	system.stop(0)
}

// principal_recovery_ask asks for the recovery key of the named principal.
principal_recovery_ask :: proc "contextless" (sentence: string) {
	mode = .Principal_Recovery
	message, message_failed = sentence, true
	system.log("unlock: the keys of principal ", number, " \"", the_name(), "\" wait for their recovery key: the TPM does not release them")
}

// machine_try opens the record of the machine with the machine passphrase
// typed, in the form of the record.
machine_try :: proc "contextless" () {
	if machine_form == .Sealed_By_The_Tpm_With_Passphrase {
		machine_tpm_passphrase_try()
		return
	}
	machine_passphrase_alone_try()
}

// machine_passphrase_alone_try opens the record under the machine
// passphrase alone. A wrong passphrase gives another key: the open fails,
// and the root service receives nothing.
machine_passphrase_alone_try :: proc "contextless" () {
	machine_key: [principals.MACHINE_KEY_SIZE]u8
	key: [principals.KEY_SIZE]u8
	defer erase(machine_key[:])
	defer erase(key[:])
	if !derive(typed[:typed_count], machine_file.salt[:], &key) {
		message, message_failed = "the derivation of the key failed", true
		return
	}
	error: errors.Error_Record
	key_text := string(key[:])
	nonce_text := string(machine_file.nonce[:])
	additional := string(principals.machine_file_additional_data(&machine_file_bytes))
	sealed := string(machine_file.sealed[:])
	result := machine_key[:]
	if open_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &sealed, &result, &error) != principals.MACHINE_KEY_SIZE {
		machine_refusals += 1
		system.log("unlock: the machine passphrase is wrong: the seal does not open, the disk grants of principal 0 stay absent (", machine_refusals, " in all)")
		message, message_failed = "the passphrase is wrong: nothing is opened", true
		return
	}
	if !machine_key_give(&machine_key, root_ring.Machine_Key_State.Opened) {
		message, message_failed = "the root service did not take the key", true
		return
	}
	system.log("unlock: the machine passphrase opens the machine key; the root service receives the key of the disk grant table only")
	after_machine()
}

// machine_create sets the machine passphrase. With the TPM service and
// Secure Boot on, the TPM seals the machine key with the passphrase; else
// the passphrase alone does.
machine_create :: proc "contextless" () {
	if has_tpm && seal_allowed {
		machine_tpm_passphrase_create()
		return
	}
	if has_tpm {
		system.log("unlock: the firmware did not verify the boot program (Secure Boot is off): the machine key is sealed under the machine passphrase alone, as a seal by the TPM would trust a boot program that nothing verified")
	} else {
		system.log("unlock: no TPM service: the machine key is sealed under the machine passphrase alone, with no recovery key")
	}
	machine_passphrase_alone_create()
}

// machine_passphrase_alone_create sets the machine passphrase alone: a new
// machine key, sealed in the record "machine" of the store of this process,
// and the key of the tag to the root service. It writes at most one record
// in a run: after the write it ends with the mode Done, or stops the
// process.
machine_passphrase_alone_create :: proc "contextless" () {
	machine_key: [principals.MACHINE_KEY_SIZE]u8
	key: [principals.KEY_SIZE]u8
	defer erase(machine_key[:])
	defer erase(key[:])
	error: errors.Error_Record
	// The key comes from the generator of this process, seeded by the root
	// service from the sources of the processor; a weak seed is refused.
	if !random.fill_for_a_key(&generator, machine_key[:], .Processor, &error) || !random.fill_for_a_key(&generator, machine_file.salt[:], .Processor, &error) || !random.fill_for_a_key(&generator, machine_file.nonce[:], .Processor, &error) {
		system.log("unlock: the seed of this process is too weak for a key: no machine passphrase is set")
		message, message_failed = "the seed of the machine is too weak for a key", true
		return
	}
	started := system.time()
	if !derive(typed[:typed_count], machine_file.salt[:], &key) {
		message, message_failed = "the derivation of the key failed", true
		return
	}
	derived := system.time() - started
	principals.machine_file_encode(&machine_file, &machine_file_bytes)
	key_text := string(key[:])
	nonce_text := string(machine_file.nonce[:])
	additional := string(principals.machine_file_additional_data(&machine_file_bytes))
	text := string(machine_key[:])
	sealed := machine_file.sealed[:]
	if seal_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &text, &sealed, &error) != principals.MACHINE_SEALED_SIZE {
		message, message_failed = "the seal of the key failed", true
		return
	}
	principals.machine_file_encode(&machine_file, &machine_file_bytes)
	if _, status := storage.write(&client, storage.ROOT, principals.MACHINE_OBJECT, machine_file_bytes[:]); status != .Ok {
		system.log("unlock: the store did not keep the record of the machine passphrase: status ", u64(status))
		message, message_failed = "the store did not keep the record", true
		return
	}
	system.log("unlock: the machine passphrase is set: the machine key is sealed in the store of unlock under a key of Argon2id, 19456 KiB and 2 passes, derived in ", derived, " ms")
	// The record is on the disk now: this run never writes a second one.
	// A root service that answers late can still take this key, and a new
	// record would then hold another key than the root service.
	if !machine_key_give(&machine_key, root_ring.Machine_Key_State.New) {
		system.log("unlock: the root service did not take the key of the new machine passphrase; the record stays, and its passphrase opens it at the next start")
		erase(machine_key[:])
		erase(key[:])
		erase(typed[:])
		erase(first[:])
		system.stop(1)
	}
	mode = .Done
}

// tpm_open maps the ring and the region of the TPM service, when the root
// service gave them, and drops each completion that an earlier run of this
// process left in the ring.
tpm_open :: proc "contextless" (ctx: ^system.Context) {
	seal_allowed = ctx.values[principals.VALUE_SEAL_ALLOWED] == 1
	if ctx.handles[tpm_service.GRANT_RING] == 0 || ctx.handles[tpm_service.GRANT_REGION] == 0 || ctx.handles[tpm_service.GRANT_SERVICE] == 0 {
		return
	}
	tpm_process = ctx.handles[tpm_service.GRANT_SERVICE]
	if !tpm_service_runs() {
		system.log("unlock: the TPM service stopped: the machine key sealed by the TPM opens with its recovery key only")
		return
	}
	status: system.Status
	if tpm_requests, status = system.ring_open(ctx.handles[tpm_service.GRANT_RING]); status != .Ok {
		system.log("unlock: the ring of the TPM service does not open: status ", u64(status))
		return
	}
	address, map_status := system.memory_map(ctx.handles[tpm_service.GRANT_REGION], {.Write})
	if map_status != .Ok {
		system.ring_close(&tpm_requests)
		system.log("unlock: the region of the TPM service does not map: status ", u64(map_status))
		return
	}
	tpm_region = ([^]u8)(address)[:tpm_service.REGION_SIZE]
	// A run that stopped during a request (a lock stops a change) can have
	// left an authorization value or a secret in the region.
	erase(tpm_region[tpm_service.REGION_AUTHORIZATION:][:tpm_service.AUTHORIZATION_SIZE])
	erase(tpm_region[tpm_service.REGION_SECRET:][:tpm_service.SECRET_SIZE])
	for {
		_, has_record := system.receive(&tpm_requests.completions)
		if !has_record {
			break
		}
	}
	tag_bytes: [4]u8
	random.fill(&generator, tag_bytes[:])
	tpm_tag = transmute(u32)tag_bytes
	has_tpm = true
}

// tpm_service_runs says if the TPM service has not stopped.
tpm_service_runs :: proc "contextless" () -> bool {
	state, _ := system.process_state(tpm_process)
	return state != .Stopped && state != .None
}

// tpm_request sends one command to the TPM service and waits for its
// completion. The stop of the service is an event of this thread, as it
// holds the handle of the service: the wait ends at once, and no TPM is
// asked again in this run. status is the member of the status of the
// completion, read only when answered.
tpm_request :: proc "contextless" (command: tpm_service.Command, values: [7]u64) -> (completion: ring.Record, status: tpm_service.Status, answered: bool) {
	tpm_tag += 1
	if !system.send(&tpm_requests.commands, ring.Record{kind = u32(command), tag = tpm_tag, values = values}) {
		return {}, {}, false
	}
	limit := system.time() + TPM_ANSWER_LIMIT
	for {
		wait := system.wait_begin()
		for record in system.receive(&tpm_requests.completions) {
			if record.tag != tpm_tag {
				continue
			}
			// The one border of the status: a word that names no status is
			// no answer that this process can read. It is said here, and the
			// caller takes it as no answer.
			read, read_ok := tpm_service.status_of_word(record.kind)
			if !read_ok {
				system.log("unlock: the TPM service gave the status ", u64(record.kind), " to the command ", u64(command), ", which names no status")
				return record, {}, false
			}
			return record, read, true
		}
		if !tpm_service_runs() {
			system.log("unlock: the TPM service stopped during a request")
			has_tpm = false
			return {}, {}, false
		}
		system.wait_records(&wait, &tpm_requests.completions)
		if system.wait_end(&wait, limit) >= limit {
			return {}, {}, false
		}
	}
}

// tpm_refusal_log writes why the TPM service did not do a request. status
// is read only when answered.
tpm_refusal_log :: proc "contextless" (what: string, completion: ring.Record, status: tpm_service.Status, answered: bool) {
	if !answered {
		system.log("unlock: the TPM service gave no answer to the ", what)
		return
	}
	switch status {
	case .Ok:
		// No refusal: nothing to write.
	case .Policy_Fails:
		system.log("unlock: the TPM refuses the ", what, ": PCR 7 and PCR 11 do not hold the values of the seal: another system, another state of Secure Boot, or another machine")
	case .Refused:
		system.log("unlock: the TPM refuses the ", what, ": response code ", system.Hex(completion.values[0]), " to the command ", system.Hex(completion.values[1]))
	case .Device_Error:
		// .None is no failed step: a Device_Error with it names no step.
		if step, step_ok := tpm_service.device_step_of_word(completion.values[0]); step_ok && step != .None {
			system.log("unlock: the interface of the TPM failed at the ", what, ": ", tpm_service.device_step_words[step])
		} else {
			system.log("unlock: the interface of the TPM failed at the ", what, ": the step ", completion.values[0], " names no step")
		}
	case .Not_Authentic:
		system.log("unlock: the TPM service refuses the ", what, ": this TPM did not make the sealed object of the record under the PCR values of its policy; the record was written by another system, and only its recovery key opens it")
	case .Authorization_Fails, .Locked_Out:
		// The caller says it, with the name of the principal.
	case .Bad_Command:
		system.log("unlock: the TPM service refuses the ", what, ": the command or a value is out of its range")
	}
}

// authorization_put puts an authorization value in the region of the TPM
// service, and gives the authorization of the request: .None with no
// value.
authorization_put :: proc "contextless" (authorization: []u8) -> tpm_service.Authorization {
	if len(authorization) != tpm_service.AUTHORIZATION_SIZE {
		return .None
	}
	copy(tpm_region[tpm_service.REGION_AUTHORIZATION:][:tpm_service.AUTHORIZATION_SIZE], authorization)
	return .Value
}

// tpm_seal asks the TPM service to seal a secret to PCR 7 and PCR 11, with
// an authorization value when one is given (32 bytes; nil for none), and
// puts the four parts of the sealed object in object. On a failure object
// keeps its parts.
tpm_seal :: proc "contextless" (secret: ^[tpm_service.SECRET_SIZE]u8, authorization: []u8, object: ^principals.Sealed_Object) -> bool {
	copy(tpm_region[tpm_service.REGION_SECRET:][:tpm_service.SECRET_SIZE], secret^[:])
	completion, status, answered := tpm_request(.Seal, {0 = u64(authorization_put(authorization))})
	// The service erases the secret and the value when it takes the
	// request; a service that did not answer can leave them in the region.
	erase(tpm_region[tpm_service.REGION_AUTHORIZATION:][:tpm_service.AUTHORIZATION_SIZE])
	if !answered || status != .Ok {
		erase(tpm_region[tpm_service.REGION_SECRET:][:tpm_service.SECRET_SIZE])
		tpm_refusal_log("seal", completion, status, answered)
		return false
	}
	// The counts come from the service: they are checked before a copy.
	if completion.values[0] > tpm2.PUBLIC_AREA_LIMIT || completion.values[1] > tpm2.PRIVATE_AREA_LIMIT || completion.values[2] != u64(tpm2.PCR_SET) || completion.values[3] > tpm2.CREATION_DATA_LIMIT || completion.values[4] > tpm2.CREATION_TICKET_LIMIT {
		system.log("unlock: the TPM service gave parts or PCRs that a record sealed by the TPM does not take")
		return false
	}
	public_bytes, private_bytes := int(completion.values[0]), int(completion.values[1])
	creation_bytes, ticket_bytes := int(completion.values[3]), int(completion.values[4])
	object^ = {}
	copy(object.public_area[:public_bytes], tpm_region[tpm_service.REGION_PUBLIC_AREA:][:public_bytes])
	copy(object.private_area[:private_bytes], tpm_region[tpm_service.REGION_PRIVATE_AREA:][:private_bytes])
	copy(object.creation_data[:creation_bytes], tpm_region[tpm_service.REGION_CREATION_DATA:][:creation_bytes])
	copy(object.creation_ticket[:ticket_bytes], tpm_region[tpm_service.REGION_CREATION_TICKET:][:ticket_bytes])
	object.public_bytes, object.private_bytes = public_bytes, private_bytes
	object.creation_bytes, object.ticket_bytes = creation_bytes, ticket_bytes
	return true
}

// tpm_unseal asks the TPM service for the secret of a sealed object, with
// an authorization value when one is given. The TPM gives it only while
// PCR 7 and PCR 11 hold the values of the seal, and only to the right
// value. It gives the status of the service: Ok with the secret.
tpm_unseal :: proc "contextless" (object: ^principals.Sealed_Object, authorization: []u8, secret: ^[tpm_service.SECRET_SIZE]u8) -> (status: tpm_service.Status, answered: bool) {
	public_bytes, private_bytes := object.public_bytes, object.private_bytes
	creation_bytes, ticket_bytes := object.creation_bytes, object.ticket_bytes
	copy(tpm_region[tpm_service.REGION_PUBLIC_AREA:][:public_bytes], object.public_area[:public_bytes])
	copy(tpm_region[tpm_service.REGION_PRIVATE_AREA:][:private_bytes], object.private_area[:private_bytes])
	copy(tpm_region[tpm_service.REGION_CREATION_DATA:][:creation_bytes], object.creation_data[:creation_bytes])
	copy(tpm_region[tpm_service.REGION_CREATION_TICKET:][:ticket_bytes], object.creation_ticket[:ticket_bytes])
	kind := authorization_put(authorization)
	completion: ring.Record
	completion, status, answered = tpm_request(.Unseal, {0 = u64(public_bytes), 1 = u64(private_bytes), 2 = u64(creation_bytes), 3 = u64(ticket_bytes), 4 = u64(kind)})
	defer erase(tpm_region[tpm_service.REGION_SECRET:][:tpm_service.SECRET_SIZE])
	erase(tpm_region[tpm_service.REGION_AUTHORIZATION:][:tpm_service.AUTHORIZATION_SIZE])
	if !answered {
		tpm_refusal_log("unseal", completion, status, answered)
		return .Device_Error, false
	}
	if status != .Ok {
		tpm_refusal_log("unseal", completion, status, answered)
		return status, true
	}
	if completion.values[0] != tpm_service.SECRET_SIZE {
		system.log("unlock: the TPM service gave a secret of ", completion.values[0], " bytes")
		return .Bad_Command, true
	}
	copy(secret^[:], tpm_region[tpm_service.REGION_SECRET:][:tpm_service.SECRET_SIZE])
	return .Ok, true
}

// machine_key_passes says if a machine key has the key check of the record:
// a key that the TPM or the recovery key gives must have it.
machine_key_passes :: proc "contextless" (machine_key: ^[principals.MACHINE_KEY_SIZE]u8) -> bool {
	check := principals.machine_key_check(machine_key)
	return check == machine_tpm_file.key_check
}

// machine_seal_create makes a machine key sealed by the TPM: the key and a
// recovery key from the generator of this process, the seal by the TPM
// service, the copy under the recovery key, and the record in memory. It
// keeps the text of the recovery key for the window, which shows it one
// time; the record is written after Enter (machine_key_sealed_commit).
machine_seal_create :: proc "contextless" () -> bool {
	machine_key: [principals.MACHINE_KEY_SIZE]u8
	recovery_key: [principals.RECOVERY_KEY_SIZE]u8
	seal_key: [principals.KEY_SIZE]u8
	defer erase(machine_key[:])
	defer erase(recovery_key[:])
	defer erase(seal_key[:])
	error: errors.Error_Record
	machine_tpm_file = {}
	// The keys come from the generator of this process, seeded by the root
	// service from the sources of the processor; a weak seed is refused.
	if !random.fill_for_a_key(&generator, machine_key[:], .Processor, &error) || !random.fill_for_a_key(&generator, recovery_key[:], .Processor, &error) || !random.fill_for_a_key(&generator, machine_tpm_file.recovery_nonce[:], .Processor, &error) {
		system.log("unlock: the seed of this process is too weak for a key: no machine key is sealed by the TPM")
		return false
	}
	if !tpm_seal(&machine_key, nil, &machine_tpm_file.object) {
		system.log("unlock: no machine key is sealed by the TPM: the TPM service did not seal it")
		return false
	}
	machine_tpm_file.pcrs = principals.MACHINE_TPM_PCRS
	machine_tpm_file.key_check = principals.machine_key_check(&machine_key)
	seal_key = principals.recovery_seal_key(&recovery_key)
	principals.machine_tpm_file_encode(&machine_tpm_file, &machine_tpm_file_bytes)
	key_text := string(seal_key[:])
	nonce_text := string(machine_tpm_file.recovery_nonce[:])
	additional := string(principals.machine_tpm_file_additional_data(&machine_tpm_file_bytes))
	text := string(machine_key[:])
	sealed := machine_tpm_file.recovery_sealed[:]
	if seal_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &text, &sealed, &error) != principals.MACHINE_SEALED_SIZE {
		system.log("unlock: the seal of the copy under the recovery key failed: no machine key is sealed by the TPM")
		return false
	}
	principals.machine_tpm_file_encode(&machine_tpm_file, &machine_tpm_file_bytes)
	// The record goes to the disk only when it decodes: the next start reads
	// it with the same checks.
	if _, _, problem := principals.machine_tpm_file_decode(machine_tpm_file_bytes[:]); problem != .None {
		system.log("unlock: the record of the machine key sealed by the TPM does not decode: ", principals.machine_tpm_file_problem_sentences[problem])
		return false
	}
	// The record waits in memory until Enter: a stop before it (a lock, a
	// close) leaves no record whose only recovery key nobody wrote down.
	recovery_text = principals.recovery_key_text(&recovery_key)
	opened_machine_key = machine_key
	pending_write = .Machine_Key_Sealed
	system.log("unlock: the machine key is sealed by the TPM to PCR 7 and PCR 11, with a copy under a recovery key; the window shows the recovery key one time, and the record is written when it is written down")
	return true
}

// machine_key_sealed_commit writes the record of the machine key sealed by
// the TPM after Enter, when the recovery key is written down, and gives the
// root service the key of the table. It writes at most one record in a run:
// the window ends after it, whatever the result.
machine_key_sealed_commit :: proc "contextless" () {
	defer erase(opened_machine_key[:])
	switch object_write(principals.MACHINE_OBJECT, machine_tpm_file_bytes[:]) {
	case .Kept:
		erase(recovery_text[:])
	case .Not_Kept:
		system.log("unlock: the store did not keep the record of the machine key; no machine key is sealed by the TPM")
		write_failed()
		return
	case .Unknown:
		write_unknown("unlock: the store gave no answer on the record of the machine key sealed by the TPM, and its read back failed: the record may be on the disk; the window shows the recovery key until Enter again, and the root service receives no key")
		return
	}
	system.log("unlock: the record of the machine key sealed by the TPM is in the store of unlock: its recovery key is written down")
	// The record holds the copy under the recovery key: a root service that
	// does not take the key changes nothing of it.
	if !machine_key_give(&opened_machine_key, root_ring.Machine_Key_State.New) {
		system.log("unlock: the root service did not take the key of the new machine key; the record stays, and the TPM opens it at the next start")
	}
	mode = .Done
}

// write_failed shows, until Enter, that the store did not keep a record or
// a file whose recovery key the window showed: that key opens nothing, and
// nothing is set.
write_failed :: proc "contextless" () {
	erase(recovery_text[:])
	mode = .Write_Result
	message, message_failed = "the store did not keep it: nothing is set; ask again", true
}

// write_unknown shows, until Enter again, that the store gave no answer on
// a record or a file whose recovery key the window showed, and that its
// read back failed: it may be on the disk, so its recovery key stays on the
// screen, and the window never says that nothing is set. The root service
// receives nothing in this run; the next start of unlock reads what the
// disk holds.
write_unknown :: proc "contextless" (line: string) {
	system.log(line)
	mode = .Write_Unknown
	message, message_failed = "the record may be on the disk: keep this recovery key", true
	if pending_write == .Principal_Created {
		message = "the file may be on the disk: keep this recovery key"
	}
}

// What the unseal at the start gave.
Unseal_Outcome :: enum u8 {
	Opened, // The root service has the key of the table.
	Refused, // The TPM did not release a key that passes its check: the window asks for the recovery key.
	Not_Taken, // The key passed, and the root service did not take it: a recovery key would not help, so the window does not ask for it.
}

// machine_tpm_unseal asks the TPM service for the machine key at the start,
// and gives the root service the key of the table when the key passes its
// check.
machine_tpm_unseal :: proc "contextless" () -> Unseal_Outcome {
	if !has_tpm {
		system.log("unlock: the machine key is sealed by the TPM, and no TPM service runs: the recovery key opens it")
		return .Refused
	}
	machine_key: [principals.MACHINE_KEY_SIZE]u8
	defer erase(machine_key[:])
	if status, answered := tpm_unseal(&machine_tpm_file.object, nil, &machine_key); !answered || status != .Ok {
		return .Refused
	}
	if !machine_key_passes(&machine_key) {
		system.log("unlock: the key that the TPM released does not have the key check of the record: it is erased, and the recovery key opens the record")
		return .Refused
	}
	if !machine_key_give(&machine_key, root_ring.Machine_Key_State.Opened) {
		system.log("unlock: the TPM released the machine key, and the root service did not take the key of its table: the disk grants of principal 0 stay absent until the next start")
		return .Not_Taken
	}
	system.log("unlock: the TPM releases the machine key: the system is the system of the seal; the root service receives the key of the disk grant table only")
	return .Opened
}

// machine_reseal seals the machine key again after a recovery, to PCR 7 and
// PCR 11 of the system that runs now: its next start then needs no
// recovery key. The copy under the recovery key and the key check stay:
// the machine key did not change, and the disk grant table keeps its tag.
// With Secure Boot off it does not: an attacker who turns Secure Boot off
// makes the TPM refuse as an update does, and a new seal after the
// recovery would then trust any boot program.
machine_reseal :: proc "contextless" (machine_key: ^[principals.MACHINE_KEY_SIZE]u8) {
	if !has_tpm {
		system.log("unlock: no TPM service: the machine key is not sealed again, and the recovery key opens it at the next start too")
		return
	}
	if !seal_allowed {
		system.log("unlock: the firmware did not verify the boot program (Secure Boot is off): the machine key is not sealed again, as its seal would trust a boot program that nothing verified; the recovery key opens it at the next start too")
		return
	}
	// A failed seal leaves the parts of the record as they were.
	renewed := machine_tpm_file.object
	if !tpm_seal(machine_key, nil, &renewed) {
		system.log("unlock: the machine key is not sealed again: the recovery key opens it at the next start too")
		return
	}
	machine_tpm_file.object = renewed
	principals.machine_tpm_file_encode(&machine_tpm_file, &machine_tpm_file_bytes)
	if _, status := storage.write(&client, storage.ROOT, principals.MACHINE_OBJECT, machine_tpm_file_bytes[:]); status != .Ok {
		system.log("unlock: the store did not keep the new seal of the machine key: status ", u64(status), "; the recovery key opens it at the next start too")
		return
	}
	system.log("unlock: the machine key is sealed again to PCR 7 and PCR 11 of the system that runs: its next start needs no recovery key")
	// The record of before holds a seal to the system that the TPM refused:
	// with it, a start of that older system would open the machine key.
	object_versions_erase(principals.MACHINE_OBJECT)
}

// recovery_try opens the copy of the machine key with the recovery key
// typed. A wrong recovery key does not open the seal, and the root service
// receives nothing.
recovery_try :: proc "contextless" () {
	recovery_key, problem := principals.recovery_key_parse(typed[:typed_count])
	defer erase(recovery_key[:])
	if problem != .None {
		message, message_failed = principals.recovery_problem_sentences[problem], true
		return
	}
	seal_key := principals.recovery_seal_key(&recovery_key)
	defer erase(seal_key[:])
	machine_key: [principals.MACHINE_KEY_SIZE]u8
	defer erase(machine_key[:])
	error: errors.Error_Record
	// The copy under the recovery key, in the form of the record. The form
	// sealed by the TPM alone has a key check, as its key from the TPM has
	// no seal of its own; the form with the passphrase has none.
	with_passphrase := machine_form == .Sealed_By_The_Tpm_With_Passphrase
	key_text := string(seal_key[:])
	nonce_text := string(machine_tpm_file.recovery_nonce[:])
	additional := string(principals.machine_tpm_file_additional_data(&machine_tpm_file_bytes))
	sealed := string(machine_tpm_file.recovery_sealed[:])
	if with_passphrase {
		nonce_text = string(machine_tpm_passphrase_file.recovery_nonce[:])
		additional = string(principals.machine_tpm_passphrase_file_recovery_additional_data(&machine_tpm_passphrase_file_bytes))
		sealed = string(machine_tpm_passphrase_file.recovery_sealed[:])
	}
	result := machine_key[:]
	opened := open_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &sealed, &result, &error) == principals.MACHINE_KEY_SIZE
	if opened && !with_passphrase {
		opened = machine_key_passes(&machine_key)
	}
	if !opened {
		machine_refusals += 1
		system.log("unlock: the recovery key is wrong: the copy of the machine key does not open, the disk grants of principal 0 stay absent (", machine_refusals, " in all)")
		message, message_failed = "the recovery key is wrong: nothing is opened", true
		return
	}
	if !machine_key_give(&machine_key, root_ring.Machine_Key_State.Opened) {
		message, message_failed = "the root service did not take the key", true
		return
	}
	system.log("unlock: the recovery key opens the machine key; the root service receives the key of the disk grant table only")
	if with_passphrase {
		machine_passphrase_reseal_ask(&machine_key)
		return
	}
	machine_reseal(&machine_key)
	after_machine()
}

// machine_recovery_ask asks for the recovery key of the machine key: the
// TPM did not release it.
machine_recovery_ask :: proc "contextless" (sentence: string) {
	mode = .Machine_Recovery
	message, message_failed = sentence, true
	system.log("unlock: the machine key waits for its recovery key: the disk grants of principal 0 come when it is typed")
}

// The owner of the secret that a seal by the TPM with a passphrase guards.
// The two seals derive another authorization value and another seal key,
// so that a value of one never opens the other, and their lines name the
// owner.
Secret_Owner :: enum u8 {
	Machine, // The machine key, under the machine passphrase.
	Named_Principal, // The secret keys of a named principal, under its passphrase.
}

// tpm_passphrase_seal_begin is the start that the two seals share: a new
// TPM secret, salt and nonce, the key of the passphrase typed, the seal of
// the TPM secret by the TPM service with the authorization value of that
// key, and the seal key from the two. salt and nonce are the fields of the
// file of the seal. A failure sets the message of the window and gives
// false; the TPM secret and the key of the passphrase never leave it.
tpm_passphrase_seal_begin :: proc "contextless" (owner: Secret_Owner, salt, nonce: []u8, object: ^principals.Sealed_Object) -> (seal_key: [principals.KEY_SIZE]u8, derived: u64, ok: bool) {
	passphrase_key: [principals.KEY_SIZE]u8
	tpm_secret: [principals.TPM_SECRET_SIZE]u8
	defer erase(passphrase_key[:])
	defer erase(tpm_secret[:])
	error: errors.Error_Record
	// The secret, the salt and the nonce come from the generator of this
	// process, seeded by the root service from the sources of the
	// processor; a weak seed is refused.
	if !random.fill_for_a_key(&generator, tpm_secret[:], .Processor, &error) || !random.fill_for_a_key(&generator, salt, .Processor, &error) || !random.fill_for_a_key(&generator, nonce, .Processor, &error) {
		switch owner {
		case .Machine:
			system.log("unlock: the seed of this process is too weak for a key: the machine key is not sealed by the TPM")
		case .Named_Principal:
			system.log("unlock: the seed of this process is too weak for a key: the keys are not sealed by the TPM")
		}
		message, message_failed = "the seed of the machine is too weak for a key", true
		return {}, 0, false
	}
	started := system.time()
	if !derive(typed[:typed_count], salt, &passphrase_key) {
		message, message_failed = "the derivation of the key failed", true
		return {}, 0, false
	}
	derived = system.time() - started
	authorization: [tpm2.AUTHORIZATION_VALUE_SIZE]u8
	switch owner {
	case .Machine:
		authorization = principals.machine_authorization_value(&passphrase_key)
	case .Named_Principal:
		authorization = principals.principal_authorization_value(&passphrase_key)
	}
	defer erase(authorization[:])
	if !tpm_seal(&tpm_secret, authorization[:], object) {
		switch owner {
		case .Machine:
			system.log("unlock: the TPM service did not seal the machine key with the machine passphrase")
			message, message_failed = "the TPM service did not seal the key", true
		case .Named_Principal:
			system.log("unlock: the TPM service did not seal the keys of principal \"", the_name(), "\"")
			message, message_failed = "the TPM service did not seal the keys", true
		}
		return {}, 0, false
	}
	switch owner {
	case .Machine:
		seal_key = principals.machine_tpm_passphrase_seal_key(&tpm_secret, &passphrase_key)
	case .Named_Principal:
		seal_key = principals.principal_tpm_seal_key(&tpm_secret, &passphrase_key)
	}
	return seal_key, derived, true
}

// machine_tpm_passphrase_seal seals the machine key in a record of the form
// sealed by the TPM with the machine passphrase: a new salt and a new TPM
// secret, the key of the passphrase typed, the seal by the TPM service with
// its authorization value, and the machine key under the seal key. The copy
// under the recovery key is in the record already. On a failure the record
// can be half written: the caller writes it to the store only on success.
machine_tpm_passphrase_seal :: proc "contextless" (machine_key: ^[principals.MACHINE_KEY_SIZE]u8, sealed_file: ^principals.Machine_Tpm_Passphrase_File, sealed_bytes: ^[principals.MACHINE_TPM_PASSPHRASE_FILE_SIZE]u8) -> bool {
	seal_key, derived, began := tpm_passphrase_seal_begin(.Machine, sealed_file.salt[:], sealed_file.nonce[:], &sealed_file.object)
	defer erase(seal_key[:])
	if !began {
		return false
	}
	error: errors.Error_Record
	sealed_file.pcrs = principals.MACHINE_TPM_PASSPHRASE_PCRS
	principals.machine_tpm_passphrase_file_encode(sealed_file, sealed_bytes)
	key_text := string(seal_key[:])
	nonce_text := string(sealed_file.nonce[:])
	additional := string(principals.machine_tpm_passphrase_file_additional_data(sealed_bytes))
	text := string(machine_key^[:])
	sealed := sealed_file.sealed[:]
	if seal_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &text, &sealed, &error) != principals.MACHINE_SEALED_SIZE {
		message, message_failed = "the seal of the key failed", true
		return false
	}
	principals.machine_tpm_passphrase_file_encode(sealed_file, sealed_bytes)
	// The record goes to the disk only when it decodes: the next start reads
	// it with the same checks.
	if _, _, problem := principals.machine_tpm_passphrase_file_decode(sealed_bytes^[:]); problem != .None {
		system.log("unlock: the record of the machine key sealed by the TPM with the machine passphrase does not decode: ", principals.machine_tpm_passphrase_file_problem_sentences[problem])
		message, message_failed = "the record does not decode", true
		return false
	}
	system.log("unlock: the machine key is sealed by the TPM to PCR 7 and PCR 11 and to the machine passphrase, under a key of Argon2id, 19456 KiB and 2 passes, derived in ", derived, " ms")
	return true
}

// machine_tpm_passphrase_create sets a machine passphrase that the TPM
// seals the machine key with: the key and a recovery key from the generator
// of this process, the copy under the recovery key, the seal, and the
// record in memory. The window then shows the recovery key one time; the
// record is written after Enter (machine_passphrase_commit).
machine_tpm_passphrase_create :: proc "contextless" () {
	machine_key: [principals.MACHINE_KEY_SIZE]u8
	recovery_key: [principals.RECOVERY_KEY_SIZE]u8
	defer erase(machine_key[:])
	defer erase(recovery_key[:])
	error: errors.Error_Record
	machine_tpm_passphrase_file = {}
	if !random.fill_for_a_key(&generator, machine_key[:], .Processor, &error) || !random.fill_for_a_key(&generator, recovery_key[:], .Processor, &error) || !random.fill_for_a_key(&generator, machine_tpm_passphrase_file.recovery_nonce[:], .Processor, &error) {
		system.log("unlock: the seed of this process is too weak for a key: no machine passphrase is set")
		message, message_failed = "the seed of the machine is too weak for a key", true
		return
	}
	// The copy under the recovery key: its additional data stops before the
	// salt, so it is sealed before the seal by the TPM chooses the salt.
	principals.machine_tpm_passphrase_file_encode(&machine_tpm_passphrase_file, &machine_tpm_passphrase_file_bytes)
	recovery_seal_key := principals.recovery_seal_key(&recovery_key)
	defer erase(recovery_seal_key[:])
	key_text := string(recovery_seal_key[:])
	nonce_text := string(machine_tpm_passphrase_file.recovery_nonce[:])
	additional := string(principals.machine_tpm_passphrase_file_recovery_additional_data(&machine_tpm_passphrase_file_bytes))
	text := string(machine_key[:])
	recovery_sealed := machine_tpm_passphrase_file.recovery_sealed[:]
	if seal_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &text, &recovery_sealed, &error) != principals.MACHINE_SEALED_SIZE {
		message, message_failed = "the seal of the recovery copy failed", true
		return
	}
	if !machine_tpm_passphrase_seal(&machine_key, &machine_tpm_passphrase_file, &machine_tpm_passphrase_file_bytes) {
		return
	}
	// The record waits in memory until Enter: a stop before it (a lock of
	// the session whose console asked, a close) leaves no record whose only
	// recovery key nobody wrote down, and sets no machine passphrase.
	recovery_text = principals.recovery_key_text(&recovery_key)
	opened_machine_key = machine_key
	pending_write = .Machine_Passphrase_Set
	system.log("unlock: the window shows the recovery key of the new machine passphrase one time; the record is written when it is written down")
	mode = .Recovery_Shown
	message, message_failed = "write it down, then Enter: the passphrase is set then", false
}

// machine_passphrase_commit writes the record of the machine passphrase
// sealed by the TPM after Enter, when the recovery key is written down, and
// gives the root service the key of the table. It writes at most one record
// in a run: the window ends after it, whatever the result.
machine_passphrase_commit :: proc "contextless" () {
	defer erase(opened_machine_key[:])
	switch object_write(principals.MACHINE_OBJECT, machine_tpm_passphrase_file_bytes[:]) {
	case .Kept:
		erase(recovery_text[:])
	case .Not_Kept:
		system.log("unlock: the store did not keep the record of the machine passphrase; no machine passphrase is set")
		write_failed()
		return
	case .Unknown:
		write_unknown("unlock: the store gave no answer on the record of the machine passphrase, and its read back failed: the record may be on the disk; the window shows the recovery key until Enter again, and the root service receives no key")
		return
	}
	machine_form = .Sealed_By_The_Tpm_With_Passphrase
	system.log("unlock: the machine passphrase is set: the TPM seals the machine key with it, with a copy under a recovery key, in the store of unlock")
	// The record holds the copy under the recovery key: a root service that
	// does not take the key changes nothing of it.
	if !machine_key_give(&opened_machine_key, root_ring.Machine_Key_State.New) {
		system.log("unlock: the root service did not take the key of the new machine passphrase; the record stays, and its passphrase opens it at the next start")
	}
	mode = .Done
}

// machine_tpm_passphrase_try opens a machine key that the TPM seals with
// the machine passphrase: the key of the passphrase gives the authorization
// value, the TPM releases the TPM secret only to it and to the system of the
// seal, and the two together give the seal key. The TPM counts each wrong
// passphrase. When the TPM refuses for another cause, the window asks for
// the recovery key.
machine_tpm_passphrase_try :: proc "contextless" () {
	passphrase_key: [principals.KEY_SIZE]u8
	tpm_secret: [principals.TPM_SECRET_SIZE]u8
	machine_key: [principals.MACHINE_KEY_SIZE]u8
	defer erase(passphrase_key[:])
	defer erase(tpm_secret[:])
	defer erase(machine_key[:])
	if !derive(typed[:typed_count], machine_tpm_passphrase_file.salt[:], &passphrase_key) {
		message, message_failed = "the derivation of the key failed", true
		return
	}
	authorization := principals.machine_authorization_value(&passphrase_key)
	defer erase(authorization[:])
	status, answered := tpm_unseal(&machine_tpm_passphrase_file.object, authorization[:], &tpm_secret)
	switch {
	case answered && status == .Ok:
	case answered && status == .Authorization_Fails:
		machine_refusals += 1
		system.log("unlock: the machine passphrase is wrong: the TPM refuses it and counts it, the disk grants of principal 0 stay absent (", machine_refusals, " in all)")
		message, message_failed = "the passphrase is wrong: the TPM counts each wrong try", true
		return
	case answered && status == .Locked_Out:
		system.log("unlock: the TPM refuses each try of the machine passphrase for now: it counted too many wrong passphrases; the recovery key opens the machine key")
		machine_recovery_ask("the TPM refuses tries for now: type the recovery key")
		return
	case:
		machine_recovery_ask("the TPM refuses: type the recovery key of the machine")
		return
	}
	seal_key := principals.machine_tpm_passphrase_seal_key(&tpm_secret, &passphrase_key)
	defer erase(seal_key[:])
	error: errors.Error_Record
	key_text := string(seal_key[:])
	nonce_text := string(machine_tpm_passphrase_file.nonce[:])
	additional := string(principals.machine_tpm_passphrase_file_additional_data(&machine_tpm_passphrase_file_bytes))
	sealed := string(machine_tpm_passphrase_file.sealed[:])
	result := machine_key[:]
	if open_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &sealed, &result, &error) != principals.MACHINE_KEY_SIZE {
		system.log("unlock: the machine key does not open under the secret that the TPM released: the record is not consistent, and the recovery key opens it")
		machine_recovery_ask("the record is not consistent: type the recovery key")
		return
	}
	if !machine_key_give(&machine_key, root_ring.Machine_Key_State.Opened) {
		message, message_failed = "the root service did not take the key", true
		return
	}
	system.log("unlock: the TPM releases the machine key to the machine passphrase: the system is the system of the seal; the root service receives the key of the disk grant table only")
	after_machine()
}

// machine_passphrase_reseal_ask goes on after the recovery key opened a
// machine key sealed with the machine passphrase: with the TPM service and
// Secure Boot on, the window asks for a new machine passphrase, which the
// TPM seals the key again with, to the system that runs. So the recovery
// also replaces a lost machine passphrase. Else nothing is sealed again.
machine_passphrase_reseal_ask :: proc "contextless" (machine_key: ^[principals.MACHINE_KEY_SIZE]u8) {
	switch {
	case !has_tpm:
		system.log("unlock: no TPM service: the machine key is not sealed again, and the recovery key opens it at the next start too")
	case !seal_allowed:
		system.log("unlock: the firmware did not verify the boot program (Secure Boot is off): the machine key is not sealed again, as its seal would trust a boot program that nothing verified; the recovery key opens it at the next start too")
	case:
		opened_machine_key = machine_key^
		mode = .Machine_Reseal_First
		message, message_failed = "type a machine passphrase: the TPM seals the key to it", false
		system.log("unlock: the machine key waits for a new machine passphrase: the TPM seals it again to it and to the system that runs")
		return
	}
	after_machine()
}

// machine_passphrase_reseal seals the machine key that the recovery key
// opened again by the TPM, to the new machine passphrase typed and to the
// system that runs, and writes the record. The copy under the recovery key
// stays. A seal that fails keeps the record as it was: the recovery key
// opens it at the next start too, and the window says it until Enter, so
// nobody believes that the new passphrase opens the key. The opened key is
// erased in each case: the window cannot ask again for a passphrase that it
// has no key to seal.
machine_passphrase_reseal :: proc "contextless" () {
	defer erase(opened_machine_key[:])
	renewed := machine_tpm_passphrase_file
	renewed_bytes: [principals.MACHINE_TPM_PASSPHRASE_FILE_SIZE]u8
	if !machine_tpm_passphrase_seal(&opened_machine_key, &renewed, &renewed_bytes) {
		system.log("unlock: the machine key is not sealed again: the recovery key opens it at the next start too")
		mode = .Machine_Reseal_Result
		message, message_failed = "not sealed again: the recovery key opens it at next start", true
		return
	}
	if _, status := storage.write(&client, storage.ROOT, principals.MACHINE_OBJECT, renewed_bytes[:]); status != .Ok {
		system.log("unlock: the store did not keep the new seal of the machine key: status ", u64(status), "; the recovery key opens it at the next start too")
		mode = .Machine_Reseal_Result
		message, message_failed = "the store did not keep the seal: the recovery key opens it", true
		return
	}
	machine_tpm_passphrase_file, machine_tpm_passphrase_file_bytes = renewed, renewed_bytes
	system.log("unlock: the machine key is sealed again to PCR 7 and PCR 11 of the system that runs and to the new machine passphrase: its next start needs no recovery key")
	// The record of before holds a seal that the old passphrase opens on
	// the system of that seal. No trial open comes first: the new record
	// keeps the copy under the recovery key byte for byte, and that copy
	// opened in this run, so a fault of the new seal costs one recovery and
	// not the key; a trial unseal would cost a use that the TPM counts.
	object_versions_erase(principals.MACHINE_OBJECT)
	after_machine()
}

// principal_tpm_seal seals the secret keys in a file of the form sealed by
// the TPM: a new salt and a new TPM secret, the key of the passphrase typed,
// the seal by the TPM service with its authorization value, and the keys
// under the seal key. The name, the public keys and the copy under the
// recovery key are in the file already. On a failure the file can be half
// written: the caller writes it to the store only on success.
principal_tpm_seal :: proc "contextless" (secrets: ^[principals.SECRET_KEYS_SIZE]u8, sealed_file: ^principals.Principal_Tpm_File, sealed_bytes: ^[principals.PRINCIPAL_TPM_FILE_SIZE]u8) -> bool {
	seal_key, derived, began := tpm_passphrase_seal_begin(.Named_Principal, sealed_file.salt[:], sealed_file.nonce[:], &sealed_file.object)
	defer erase(seal_key[:])
	if !began {
		return false
	}
	error: errors.Error_Record
	sealed_file.pcrs = principals.PRINCIPAL_TPM_PCRS
	principals.principal_tpm_file_encode(sealed_file, sealed_bytes)
	key_text := string(seal_key[:])
	nonce_text := string(sealed_file.nonce[:])
	additional := string(principals.principal_tpm_file_additional_data(sealed_bytes))
	text := string(secrets^[:])
	sealed := sealed_file.sealed[:]
	if seal_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &text, &sealed, &error) != principals.SEALED_SIZE {
		message, message_failed = "the seal of the keys failed", true
		return false
	}
	principals.principal_tpm_file_encode(sealed_file, sealed_bytes)
	// The file goes to the disk only when it decodes: the next start reads
	// it with the same checks.
	if _, _, problem := principals.principal_tpm_file_decode(sealed_bytes^[:]); problem != .None {
		system.log("unlock: the file of the principal sealed by the TPM does not decode: ", principals.principal_tpm_file_problem_sentences[problem])
		message, message_failed = "the file of the principal does not decode", true
		return false
	}
	system.log("unlock: the keys of principal \"", the_name(), "\" are sealed by the TPM to PCR 7 and PCR 11 and to its passphrase, under a key of Argon2id, 19456 KiB and 2 passes, derived in ", derived, " ms")
	return true
}

// create_sealed_by_the_tpm makes a new principal whose keys the TPM seals
// with its passphrase: the keys and a recovery key from the generator of
// this process, the copy under the recovery key, the seal, and the file in
// memory. The window then shows the recovery key one time; the file, the
// record in the root service and the session come after Enter
// (principal_created_commit).
create_sealed_by_the_tpm :: proc "contextless" () {
	secrets: [principals.SECRET_KEYS_SIZE]u8
	recovery_key: [principals.RECOVERY_KEY_SIZE]u8
	defer erase(secrets[:])
	defer erase(recovery_key[:])
	error: errors.Error_Record
	principal_tpm_file = {}
	if !random.fill_for_a_key(&generator, secrets[:], .Processor, &error) || !random.fill_for_a_key(&generator, recovery_key[:], .Processor, &error) || !random.fill_for_a_key(&generator, principal_tpm_file.recovery_nonce[:], .Processor, &error) {
		system.log("unlock: the seed of this process is too weak for a key: no principal is created")
		message, message_failed = "the seed of the machine is too weak for a key", true
		return
	}
	ok: bool
	principal_tpm_file.signing_public_key, principal_tpm_file.unlock_public_key, ok = public_keys_of(&secrets)
	if !ok {
		message, message_failed = "the module cryptography refused the keys", true
		return
	}
	principal_tpm_file.name, principal_tpm_file.name_length = name, name_length
	signing_public_key, unlock_public_key = principal_tpm_file.signing_public_key, principal_tpm_file.unlock_public_key
	principal_form = .Sealed_By_The_Tpm
	// The copy under the recovery key: its additional data stops before the
	// salt, so it is sealed before the seal by the TPM chooses the salt.
	principals.principal_tpm_file_encode(&principal_tpm_file, &principal_tpm_file_bytes)
	recovery_seal_key := principals.principal_recovery_seal_key(&recovery_key)
	defer erase(recovery_seal_key[:])
	key_text := string(recovery_seal_key[:])
	nonce_text := string(principal_tpm_file.recovery_nonce[:])
	additional := string(principals.principal_tpm_file_recovery_additional_data(&principal_tpm_file_bytes))
	text := string(secrets[:])
	recovery_sealed := principal_tpm_file.recovery_sealed[:]
	if seal_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &text, &recovery_sealed, &error) != principals.SEALED_SIZE {
		message, message_failed = "the seal of the recovery copy failed", true
		return
	}
	if !principal_tpm_seal(&secrets, &principal_tpm_file, &principal_tpm_file_bytes) {
		return
	}
	// The file waits in memory until Enter, and the keys with it, as the
	// session needs the key of its disk grant table: a stop before Enter
	// leaves no principal whose only recovery key nobody wrote down.
	recovery_text = principals.recovery_key_text(&recovery_key)
	opened_secrets = secrets
	pending_write = .Principal_Created
	system.log("unlock: the keys of the new principal \"", the_name(), "\" are sealed by the TPM with its passphrase, with a copy under a recovery key; the window shows the recovery key one time, and the principal is created when it is written down")
	mode = .Principal_Recovery_Shown
	message, message_failed = "write it down, then Enter: the principal is created then", false
}

// principal_created_commit writes the file of a new principal sealed by
// the TPM after Enter, when its recovery key is written down, then gives
// the record to the root service and starts the session. It writes at most
// one file in a run: the window ends after it, whatever the result, and
// the keys are erased.
principal_created_commit :: proc "contextless" () {
	defer erase(opened_secrets[:])
	switch principal_file_write(principal_tpm_file_bytes[:]) {
	case .Kept:
		erase(recovery_text[:])
	case .Not_Kept:
		system.log("unlock: the store did not keep the file of the principal; no principal is created")
		write_failed()
		return
	case .Unknown:
		write_unknown("unlock: the store gave no answer on the file of the new principal, and its read back failed: the file may be on the disk; the window shows the recovery key until Enter again, and the root service receives no record")
		return
	}
	// The file holds the copy under the recovery key: a root service that
	// does not take the record changes nothing of it.
	if !record_give() {
		system.log("unlock: the root service did not take the record of the new principal; its file stays, and its passphrase opens it at the next start")
		mode = .Done
		return
	}
	system.log("unlock: principal ", number, " \"", the_name(), "\" is created: its keys are sealed by the TPM with its passphrase, with a copy under a recovery key")
	session_start(&opened_secrets, root_ring.Principal_Key_Origin.New)
	// The keys are erased now: a session that did not start starts at the
	// next start of unlock, which reads the file.
	if mode != .Done {
		system.log("unlock: the session of principal ", number, " did not start after its creation; the next start of unlock asks for its passphrase")
		mode = .Done
	}
}

// principal_tpm_open opens the keys of a principal whose file the TPM
// seals: the key of the passphrase gives the authorization value, the TPM
// releases the TPM secret only to it and to the system of the seal, and the
// two together give the seal key. The TPM counts each wrong passphrase.
principal_tpm_open :: proc "contextless" (secrets: ^[principals.SECRET_KEYS_SIZE]u8) -> Open_Outcome {
	passphrase_key: [principals.KEY_SIZE]u8
	tpm_secret: [principals.TPM_SECRET_SIZE]u8
	defer erase(passphrase_key[:])
	defer erase(tpm_secret[:])
	if !derive(typed[:typed_count], principal_tpm_file.salt[:], &passphrase_key) {
		return .Derivation_Failed
	}
	authorization := principals.principal_authorization_value(&passphrase_key)
	defer erase(authorization[:])
	status, answered := tpm_unseal(&principal_tpm_file.object, authorization[:], &tpm_secret)
	switch {
	case answered && status == .Ok:
	case answered && status == .Authorization_Fails:
		return .Wrong
	case answered && status == .Locked_Out:
		return .Locked_Out
	case:
		return .Tpm_Refused
	}
	seal_key := principals.principal_tpm_seal_key(&tpm_secret, &passphrase_key)
	defer erase(seal_key[:])
	error: errors.Error_Record
	key_text := string(seal_key[:])
	nonce_text := string(principal_tpm_file.nonce[:])
	additional := string(principals.principal_tpm_file_additional_data(&principal_tpm_file_bytes))
	sealed := string(principal_tpm_file.sealed[:])
	result := secrets^[:]
	if open_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &sealed, &result, &error) != principals.SECRET_KEYS_SIZE || !public_keys_match(secrets) {
		return .Not_Consistent
	}
	return .Opened
}

// change_proof_try opens the keys with the current passphrase typed, the
// proof of a change. In the form sealed by the TPM, the TPM counts a wrong
// one, as at an unlock. When the keys open, the change goes on: a new
// passphrase, or a new recovery key. A refusal changes nothing, and the
// window asks again.
change_proof_try :: proc "contextless" () {
	secrets: [principals.SECRET_KEYS_SIZE]u8
	defer erase(secrets[:])
	sealed_by_the_tpm := principal_form == .Sealed_By_The_Tpm
	switch principal_keys_open(&secrets) {
	case .Derivation_Failed:
		message, message_failed = "the derivation of the key failed", true
	case .Wrong:
		refusals += 1
		if sealed_by_the_tpm {
			system.log("unlock: the current passphrase of principal ", number, " \"", the_name(), "\" is wrong: the TPM refuses it and counts it, nothing changes (", refusals, " in all)")
			message, message_failed = "the passphrase is wrong: the TPM counts each wrong try", true
		} else {
			system.log("unlock: the current passphrase of principal ", number, " \"", the_name(), "\" is wrong: the seal does not open, nothing changes (", refusals, " in all)")
			message, message_failed = "the passphrase is wrong: nothing changes", true
		}
	case .Locked_Out:
		system.log("unlock: the TPM refuses each try of the passphrase of principal ", number, " \"", the_name(), "\" for now: it counted too many wrong passphrases; nothing changes")
		message, message_failed = "the TPM refuses tries for now: nothing changes", true
	case .Tpm_Refused:
		system.log("unlock: the TPM does not release the keys of principal ", number, " \"", the_name(), "\" to its current passphrase: nothing changes")
		message, message_failed = "the TPM refuses: nothing changes", true
	case .Not_Consistent:
		system.log("unlock: the keys of principal ", number, " do not open under its current passphrase: the file is not consistent, nothing changes")
		message, message_failed = "the file is not consistent: nothing changes", true
	case .Opened:
		system.log("unlock: the current passphrase of principal ", number, " \"", the_name(), "\" opens its keys")
		if change_mode == .New_Recovery_Key {
			recovery_key_prepare(&secrets)
			return
		}
		opened_secrets = secrets
		mode = .New_Passphrase_First
		message, message_failed = "type the new passphrase", false
	}
}

// recovery_key_prepare makes a new recovery key after the proof of a
// change: a new key and a new nonce from the generator of this process, and
// the copy of the keys under it, in a file that waits in memory. The
// passphrase and the seal by the TPM stay: the additional data of the copy
// stops before the salt, and the seal under the seal key stops before the
// copy. The window shows the new key first; the file is written only after
// Enter (recovery_key_commit), so a key that the principal never saw never
// becomes the key of the file. A failure here keeps the file as it was.
recovery_key_prepare :: proc "contextless" (secrets: ^[principals.SECRET_KEYS_SIZE]u8) {
	recovery_key: [principals.RECOVERY_KEY_SIZE]u8
	defer erase(recovery_key[:])
	renewed_recovery_file = principal_tpm_file
	error: errors.Error_Record
	if !random.fill_for_a_key(&generator, recovery_key[:], .Processor, &error) || !random.fill_for_a_key(&generator, renewed_recovery_file.recovery_nonce[:], .Processor, &error) {
		system.log("unlock: the seed of this process is too weak for a key: principal ", number, " keeps its recovery key")
		change_end(.Seed_Too_Weak)
		return
	}
	recovery_seal_key := principals.principal_recovery_seal_key(&recovery_key)
	defer erase(recovery_seal_key[:])
	principals.principal_tpm_file_encode(&renewed_recovery_file, &renewed_recovery_bytes)
	key_text := string(recovery_seal_key[:])
	nonce_text := string(renewed_recovery_file.recovery_nonce[:])
	additional := string(principals.principal_tpm_file_recovery_additional_data(&renewed_recovery_bytes))
	text := string(secrets^[:])
	recovery_sealed := renewed_recovery_file.recovery_sealed[:]
	if seal_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &text, &recovery_sealed, &error) != principals.SEALED_SIZE {
		system.log("unlock: the seal of the copy under the new recovery key failed: principal ", number, " keeps its recovery key")
		change_end(.Seal_Failed)
		return
	}
	principals.principal_tpm_file_encode(&renewed_recovery_file, &renewed_recovery_bytes)
	// The file goes to the disk only when it decodes: the next start reads
	// it with the same checks.
	if _, _, problem := principals.principal_tpm_file_decode(renewed_recovery_bytes[:]); problem != .None {
		system.log("unlock: the file of the principal with a new recovery key does not decode: ", principals.principal_tpm_file_problem_sentences[problem])
		change_end(.Seal_Failed)
		return
	}
	recovery_text = principals.recovery_key_text(&recovery_key)
	system.log("unlock: principal ", number, " \"", the_name(), "\" has a new recovery key, and the window shows it one time; the file is written when it is written down")
	mode = .Principal_Recovery_Shown
	message, message_failed = "write it down, then Enter: the file is written then", false
}

// recovery_key_commit writes the file with the copy under the new recovery
// key, after Enter: its principal wrote the key down. If the store does
// not keep the file, the recovery key before it stays the key of the file.
recovery_key_commit :: proc "contextless" () {
	erase(recovery_text[:])
	switch principal_file_write(renewed_recovery_bytes[:]) {
	case .Kept:
		principal_tpm_file, principal_tpm_file_bytes = renewed_recovery_file, renewed_recovery_bytes
		system.log("unlock: the new recovery key of principal ", number, " \"", the_name(), "\" is kept: a file written from now opens with it only")
		object_versions_erase(principals.FILE_OBJECT)
		change_end(.Recovery_Key_Changed)
	case .Not_Kept:
		system.log("unlock: the store did not keep the new recovery key of principal ", number, ": the recovery key before it stays the key of the file")
		change_end(.Store_Failed)
	case .Unknown:
		system.log("unlock: the store gave no answer on the new recovery key of principal ", number, ": the old or the new recovery key opens the keys")
		change_end(.Store_Unknown)
	}
}

// passphrase_change_seal seals the keys that the current passphrase opened
// under the new passphrase typed, in the form of the file, and writes the
// file. The session goes on: the keys and the tag of the disk grant table
// do not change. A failure keeps the file as it was. In each case the keys
// are erased, and the window shows the end until Enter.
passphrase_change_seal :: proc "contextless" () {
	defer erase(opened_secrets[:])
	switch principal_form {
	case .Sealed_By_The_Tpm:
		renewed := principal_tpm_file
		renewed_bytes: [principals.PRINCIPAL_TPM_FILE_SIZE]u8
		if !principal_tpm_seal(&opened_secrets, &renewed, &renewed_bytes) {
			system.log("unlock: the passphrase of principal ", number, " does not change: the TPM did not seal the keys again, and the file stays as it was")
			change_end(.Seal_Failed)
			return
		}
		outcome := principal_file_write(renewed_bytes[:])
		if outcome == .Kept {
			principal_tpm_file, principal_tpm_file_bytes = renewed, renewed_bytes
		}
		// The new file keeps the copy under the recovery key: a fault of the
		// new seal leaves that way back, so the versions can go.
		passphrase_change_report(outcome, "the TPM seals its keys to PCR 7 and PCR 11 and to the new passphrase", true)
	case .Passphrase:
		renewed := file
		renewed_bytes: [principals.FILE_SIZE]u8
		if _, sealed := passphrase_file_seal(&opened_secrets, &renewed, &renewed_bytes); !sealed {
			system.log("unlock: the passphrase of principal ", number, " does not change: the keys are not sealed again, and the file stays as it was")
			change_end(.Seal_Failed)
			return
		}
		// The file goes to the disk only when it decodes: the next start
		// reads it with the same checks.
		if _, _, problem := principals.file_decode(renewed_bytes[:]); problem != .None {
			system.log("unlock: the file of the principal under the new passphrase does not decode: ", principals.file_problem_sentences[problem])
			change_end(.Seal_Failed)
			return
		}
		outcome := principal_file_write(renewed_bytes[:])
		opens := false
		if outcome == .Kept {
			file, file_bytes = renewed, renewed_bytes
			// This form has no copy under a recovery key: the version before
			// is the one way back to the keys if the new file does not open.
			// So the new file is opened with the new passphrase, still typed,
			// before its versions go: one more derivation.
			reopened: [principals.SECRET_KEYS_SIZE]u8
			opens = principal_keys_open(&reopened) == .Opened && reopened == opened_secrets
			erase(reopened[:])
			if !opens {
				system.log("unlock: the new file of principal ", number, " does not open with the new passphrase: its versions are kept, and the old passphrase opens the version before it")
			}
		}
		passphrase_change_report(outcome, "its keys are sealed under the new passphrase alone", opens)
	case .Unknown:
		change_end(.Seal_Failed)
	}
}

// passphrase_change_report writes the end of a change of the passphrase on
// the log, and shows it in the window. how says how the keys are sealed.
// erases: the new file has a way back to the keys besides its versions, or
// it opened with the new passphrase, so its versions can go.
passphrase_change_report :: proc "contextless" (outcome: Write_Outcome, how: string, erases: bool) {
	switch outcome {
	case .Kept:
		system.log("unlock: the passphrase of principal ", number, " \"", the_name(), "\" is changed: ", how)
		if erases {
			object_versions_erase(principals.FILE_OBJECT)
		}
		change_end(.Passphrase_Changed)
	case .Not_Kept:
		system.log("unlock: the passphrase of principal ", number, " does not change: the store did not keep the new file")
		change_end(.Store_Failed)
	case .Unknown:
		system.log("unlock: the store gave no answer on the new file of principal ", number, ": the old or the new passphrase opens the keys")
		change_end(.Store_Unknown)
	}
}

// change_end gives the end of a change to the root service, which gives it
// to the console that asked, and shows it in the window until Enter: a
// change never ends with a silent close.
change_end :: proc "contextless" (end: principals.Change_End, problem: principals.Change_Problem = .None) {
	completion, answered := root_command(.Principal_Change_End, {4 = u64(end), 5 = u64(problem)})
	if !answered || system.Status(completion.kind) != .Ok {
		system.log("unlock: the root service did not take the end of the change: status ", u64(completion.kind))
	}
	mode = .Change_Result
	message = principals.change_end_sentences[end]
	message_failed = end != .Passphrase_Changed && end != .Recovery_Key_Changed
}

// What a write of the file of the principal, or of the record of the
// machine key, gave.
Write_Outcome :: enum u8 {
	Kept, // The store holds the new object.
	Not_Kept, // The store holds the object from before, or none.
	Unknown, // The store did not answer, and the object could not be read back.
}

// principal_file_write writes a new file of the principal (object_write).
principal_file_write :: proc "contextless" (bytes: []u8) -> Write_Outcome {
	return object_write(principals.FILE_OBJECT, bytes)
}

// object_write writes an object of the store of unlock: the file of the
// principal or the record of the machine key. A write whose answer failed
// can still be on the disk (a storage service that stops after its commit
// and before its answer): the object is read back and compared, so the
// window never says that a secret is not kept when the disk holds it.
object_write :: proc "contextless" (object: string, bytes: []u8) -> Write_Outcome {
	_, status := storage.write(&client, storage.ROOT, object, bytes)
	if status == .Ok {
		return .Kept
	}
	system.log("unlock: the store did not answer the write of the object \"", object, "\": status ", u64(status), "; the object is read back")
	buffer: [max(principals.PRINCIPAL_FILE_LIMIT, principals.MACHINE_RECORD_LIMIT) + 1]u8
	read, found, read_status := storage.read(&client, storage.ROOT, object, buffer[:])
	if read_status != .Ok {
		return .Unknown
	}
	if found && string(read) == string(bytes) {
		return .Kept
	}
	return .Not_Kept
}

// principal_recovery_try opens the copy of the keys of the named principal
// with the recovery key typed. With the TPM service and Secure Boot on, the
// window then asks for a passphrase, and the TPM seals the keys again to it
// and to the system that runs; else the session starts at once.
principal_recovery_try :: proc "contextless" () {
	recovery_key, problem := principals.recovery_key_parse(typed[:typed_count])
	defer erase(recovery_key[:])
	if problem != .None {
		message, message_failed = principals.recovery_problem_sentences[problem], true
		return
	}
	seal_key := principals.principal_recovery_seal_key(&recovery_key)
	defer erase(seal_key[:])
	secrets: [principals.SECRET_KEYS_SIZE]u8
	defer erase(secrets[:])
	error: errors.Error_Record
	key_text := string(seal_key[:])
	nonce_text := string(principal_tpm_file.recovery_nonce[:])
	additional := string(principals.principal_tpm_file_recovery_additional_data(&principal_tpm_file_bytes))
	sealed := string(principal_tpm_file.recovery_sealed[:])
	result := secrets[:]
	if open_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &sealed, &result, &error) != principals.SECRET_KEYS_SIZE || !public_keys_match(&secrets) {
		refusals += 1
		system.log("unlock: the recovery key of principal ", number, " \"", the_name(), "\" is wrong: the copy of its keys does not open, nothing is unlocked (", refusals, " in all)")
		message, message_failed = "the recovery key is wrong: nothing is unlocked", true
		return
	}
	system.log("unlock: the recovery key of principal ", number, " \"", the_name(), "\" opens its keys")
	switch {
	case !has_tpm:
		system.log("unlock: no TPM service: the keys of principal ", number, " are not sealed again, and the recovery key opens them at the next start too")
	case !seal_allowed:
		system.log("unlock: the firmware did not verify the boot program (Secure Boot is off): the keys of principal ", number, " are not sealed again, as their seal would trust a boot program that nothing verified; the recovery key opens them at the next start too")
	case:
		opened_secrets = secrets
		mode = .New_Passphrase_First
		message, message_failed = "type a passphrase: the TPM seals the keys to it again", false
		system.log("unlock: principal ", number, " \"", the_name(), "\" types a passphrase: the TPM seals its keys again to it and to the system that runs")
		return
	}
	session_start(&secrets, root_ring.Principal_Key_Origin.Opened)
}

// principal_reseal seals the keys that the recovery key opened again by the
// TPM, to the passphrase typed and to the system that runs, writes the
// file, and starts the session. The copy under the recovery key stays. A
// seal that fails keeps the file as it was, and the session starts anyway:
// the recovery key opens the keys at the next start too.
principal_reseal :: proc "contextless" () {
	defer erase(opened_secrets[:])
	renewed := principal_tpm_file
	renewed_bytes: [principals.PRINCIPAL_TPM_FILE_SIZE]u8
	defer erase(renewed_bytes[:])
	switch {
	case !principal_tpm_seal(&opened_secrets, &renewed, &renewed_bytes):
		system.log("unlock: the keys of principal ", number, " are not sealed again: the recovery key opens them at the next start too")
	case:
		if _, status := storage.write(&client, storage.ROOT, principals.FILE_OBJECT, renewed_bytes[:]); status != .Ok {
			system.log("unlock: the store did not keep the new seal of the keys of principal ", number, ": status ", u64(status), "; the recovery key opens them at the next start too")
		} else {
			principal_tpm_file, principal_tpm_file_bytes = renewed, renewed_bytes
			system.log("unlock: the keys of principal ", number, " \"", the_name(), "\" are sealed again to PCR 7 and PCR 11 of the system that runs and to the new passphrase: its next unlock needs no recovery key")
			object_versions_erase(principals.FILE_OBJECT)
		}
	}
	session_start(&opened_secrets, root_ring.Principal_Key_Origin.Opened)
	// The keys are erased now: the window cannot ask for a passphrase to
	// seal them again, so it ends even when the session did not start.
	if mode != .Done {
		system.log("unlock: the session of principal ", number, " did not start after its recovery; the next start of unlock asks again")
		mode = .Done
	}
}

// What the store holds for the record of the machine key.
Record_State :: enum u8 {
	Absent, // No record: the machine has no passphrase, and one can be set.
	Present, // A record that decodes: its passphrase opens it.
	Unreadable, // The store failed to give it, or it does not decode: it can hold a good key, so no new record is written over it.
}

// machine_record_read reads the record of the machine key from the store,
// in its form: under the machine passphrase alone, sealed by the TPM with
// the machine passphrase, or sealed by the TPM with no passphrase. Only a
// store that answers "no object" gives Absent: a read error or a changed
// byte must never let a new key replace a good key.
machine_record_read :: proc "contextless" () -> Record_State {
	buffer: [principals.MACHINE_RECORD_LIMIT + 1]u8
	bytes, found, read_status := storage.read(&client, storage.ROOT, principals.MACHINE_OBJECT, buffer[:])
	if read_status != .Ok {
		system.log("unlock: the store did not give the record of the machine passphrase: status ", u64(read_status))
		return .Unreadable
	}
	if !found {
		return .Absent
	}
	machine_form = principals.machine_record_form(bytes)
	problem: principals.File_Problem
	switch machine_form {
	case .Passphrase:
		machine_file, machine_file_bytes, problem = principals.machine_file_decode(bytes)
		if problem != .None {
			system.log("unlock: the record of the machine passphrase is refused: ", principals.machine_file_problem_sentences[problem])
			return .Unreadable
		}
	case .Sealed_By_The_Tpm:
		machine_tpm_file, machine_tpm_file_bytes, problem = principals.machine_tpm_file_decode(bytes)
		if problem != .None {
			system.log("unlock: the record of the machine key sealed by the TPM is refused: ", principals.machine_tpm_file_problem_sentences[problem])
			return .Unreadable
		}
	case .Sealed_By_The_Tpm_With_Passphrase:
		machine_tpm_passphrase_file, machine_tpm_passphrase_file_bytes, problem = principals.machine_tpm_passphrase_file_decode(bytes)
		if problem != .None {
			system.log("unlock: the record of the machine key sealed by the TPM with the machine passphrase is refused: ", principals.machine_tpm_passphrase_file_problem_sentences[problem])
			return .Unreadable
		}
	case .Unknown:
		system.log("unlock: the record of the machine key is refused: it starts with none of MACHINEK, MACHINET and MACHINEP")
		return .Unreadable
	}
	return .Present
}

// session_start asks the root service to start the session of the
// principal, and gives it the key of the tag of the disk grant table of the
// principal, which the secret unlock key gives, and nothing else: the root
// service needs no key that opens the file or signs a grant. origin
// .New lets the root service write over a table that does not verify:
// only the key of a new principal does.
session_start :: proc "contextless" (secrets: ^[principals.SECRET_KEYS_SIZE]u8, origin: root_ring.Principal_Key_Origin) {
	// The current file opened the keys: a version of it is no longer the
	// only way back to keys that open, so an erase that a stop missed is
	// done now (src/md/features/version_erase.md). A new principal opened
	// nothing: its write can replace a file that never decoded, whose
	// version is then the one way back to its keys.
	if origin == .Opened {
		object_versions_erase(principals.FILE_OBJECT)
	}
	unlock_key: [disk_process.KEY_SIZE]u8
	copy(unlock_key[:], secrets^[principals.SECRET_KEYS_SIZE - disk_process.KEY_SIZE:])
	table_key := disk_process.table_key_of_principal_key(&unlock_key)
	values := transmute([4]u64)table_key
	defer erase(unlock_key[:])
	defer erase(table_key[:])
	defer erase(([^]u8)(rawptr(&values))[:size_of(values)])
	completion, answered := root_command(.Principal_Unlock, {values[0], values[1], values[2], values[3], number, u64(origin), 0})
	if !answered || system.Status(completion.kind) != .Ok {
		system.log("unlock: the root service did not start the session of principal ", number, ": status ", u64(completion.kind))
		message, message_failed = "the root service did not start the session", true
		return
	}
	mode = .Done
}

// machine_seal_sentence says how the machine key is sealed, for the line of
// the window under a mode of the machine: in the form of its record, or in
// the form that a new machine passphrase will give it. The longest one has
// 63 cells of 8 pixels after a margin of 12: 516 pixels, in a window of 520.
machine_seal_sentence :: proc "contextless" () -> string {
	form := machine_form
	if mode == .Machine_Create_First || mode == .Machine_Create_Again {
		form = .Passphrase
		if has_tpm && seal_allowed {
			form = .Sealed_By_The_Tpm_With_Passphrase
		}
	}
	// A new record waits for Enter: the store holds no record yet, and the
	// window says the form of the one that it shows the recovery key of.
	switch pending_write {
	case .None, .Principal_Created:
		// No record of the machine waits: the form is the one of the store.
	case .Machine_Passphrase_Set:
		form = .Sealed_By_The_Tpm_With_Passphrase
	case .Machine_Key_Sealed:
		form = .Sealed_By_The_Tpm
	}
	switch form {
	case .Sealed_By_The_Tpm:
		return "sealed by the TPM to PCR 7 and 11, with a copy for recovery"
	case .Sealed_By_The_Tpm_With_Passphrase:
		return "sealed by the TPM with the passphrase, with a copy for recovery"
	case .Passphrase, .Unknown:
	}
	return "no TPM seal: the passphrase alone protects the key"
}

// machine_recovery_offered says if the window offers the recovery key of
// the machine key with Ctrl+R: the machine passphrase is asked, and the TPM
// seals the key with it.
machine_recovery_offered :: proc "contextless" () -> bool {
	return mode == .Machine_Unlock && machine_form == .Sealed_By_The_Tpm_With_Passphrase && has_tpm
}

// principal_recovery_offered says if the window offers the recovery key of
// the named principal with Ctrl+R: its passphrase is asked for an unlock,
// and the TPM seals the keys with it. A change does not offer it: the
// recovery key is no proof of a change.
principal_recovery_offered :: proc "contextless" () -> bool {
	return mode == .Unlock && principals.recovery_key_offered_at_unlock(principal_form, has_tpm)
}

// machine_passphrase_back says if Enter with nothing at the recovery key of
// the machine key goes back to the machine passphrase, as for a named
// principal: the TPM seals the key with the passphrase and runs, so after a
// lockout the owner can wait for the TPM.
machine_passphrase_back :: proc "contextless" () -> bool {
	return machine_form == .Sealed_By_The_Tpm_With_Passphrase && has_tpm
}

draw :: proc "contextless" (window: ^display.Window) -> interface.Action_Bar_Result {
	if drawing.now.records == nil {
		drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	}
	frame := interface.window_frame_begin(&drawing, window)
	interface.action_bar_input_take(&frame, &bar)
	table := frame.table
	interface.draw_rectangle(table, 0, 0, WIDTH, HEIGHT, graphics.colors.background)
	// What the window asks for: the passphrase of a named principal, the
	// machine passphrase or the recovery key of principal 0, or what it
	// shows: a new recovery key. The widest line, the message after a new
	// seal, has 60 cells of 8 pixels after a margin of 12 pixels: it fits in
	// the window of 520 pixels.
	label := "principal  "
	subject := the_name()
	prompt := "passphrase  "
	// The keys of the mode, in the action bar (docs/INTERFACE.md, "4.4 The
	// action bar"): Enter, and Escape that clears what is typed. A mode
	// whose Enter does another thing with nothing typed says it in the
	// name of the item.
	enter_name := "unlock"
	clears := true
	note := "" // A fact at the left of the bar.
	switch mode {
	case .Unlock, .Done:
	case .Create_First:
		label = "new principal  "
	case .Create_Again:
		label = "new principal  "
		prompt = "again  "
	case .Machine_Unlock:
		label, subject = "machine passphrase  ", "principal 0"
		enter_name = "unlock; empty: skip"
	case .Machine_Create_First:
		label, subject = "new machine passphrase  ", "principal 0"
		enter_name = "set"
	case .Machine_Create_Again:
		label, subject = "new machine passphrase  ", "principal 0"
		prompt = "again  "
		enter_name = "set"
	case .Machine_Recovery:
		label, subject = "machine key  ", "principal 0"
		prompt = "recovery key  "
		enter_name = "open; empty: skip"
		if machine_passphrase_back() {
			enter_name, clears = "open; empty: the passphrase", false
		}
	case .Machine_Reseal_Result:
		label, subject = "machine key  ", "principal 0"
		prompt = "new seal  "
		enter_name, clears = "done", false
	case .Machine_Reseal_First:
		label, subject = "new machine passphrase  ", "principal 0"
		enter_name = "seal; empty: skip"
	case .Machine_Reseal_Again:
		label, subject = "new machine passphrase  ", "principal 0"
		prompt = "again  "
		enter_name = "seal"
	case .Recovery_Shown:
		label, subject = "machine key sealed by the TPM  ", "principal 0"
		prompt = "recovery key  "
		enter_name, clears, note = "done", false, "it is shown one time"
	case .Principal_Recovery:
		prompt = "recovery key  "
		enter_name = "open"
		if has_tpm {
			enter_name, clears = "open; empty: the passphrase", false
		}
	case .Principal_Recovery_Shown:
		label = "keys sealed by the TPM  "
		prompt = "recovery key  "
		enter_name, clears, note = "done", false, "it is shown one time"
	case .New_Passphrase_First:
		prompt = "new passphrase  "
		enter_name = change_mode == .Change_Passphrase ? "seal; empty: cancel" : "seal"
	case .New_Passphrase_Again:
		prompt = "again  "
		enter_name = "seal"
	case .Change_Current:
		// 54 cells of 8 pixels after a margin of 12: it fits in 520 pixels.
		prompt = "current passphrase  "
		enter_name = "check; empty: cancel"
	case .Change_Result:
		prompt = "change  "
		enter_name, clears = "done", false
	case .Write_Result:
		if pending_write != .Principal_Created {
			label, subject = "machine key  ", "principal 0"
		}
		prompt = "write  "
		enter_name, clears = "done", false
	case .Write_Unknown:
		label = "keys sealed by the TPM  "
		if pending_write != .Principal_Created {
			label, subject = "machine key  ", "principal 0"
		}
		prompt = "recovery key  "
		enter_name, clears = "done", false
	}
	x := interface.draw_text(table, 12, 12, label, graphics.colors.dim)
	interface.draw_text(table, x, 12, subject, graphics.colors.text)
	x = interface.draw_text(table, 12, 48, prompt, graphics.colors.dim)
	of_the_machine: bool
	switch mode {
	case .Machine_Unlock, .Machine_Create_First, .Machine_Create_Again, .Machine_Recovery, .Recovery_Shown, .Machine_Reseal_First, .Machine_Reseal_Again, .Machine_Reseal_Result:
		of_the_machine = true
	case .Unlock, .Create_First, .Create_Again, .Principal_Recovery, .Principal_Recovery_Shown, .New_Passphrase_First, .New_Passphrase_Again, .Change_Current, .Change_Result, .Write_Result, .Write_Unknown, .Done:
		// A mode of a named principal.
	}
	// The keys of the named principal are sealed by the TPM when its file
	// has that form, or when a creation will give it that form.
	creating := mode == .Create_First || mode == .Create_Again
	of_the_principal_tpm := principal_form == .Sealed_By_The_Tpm
	if creating {
		of_the_principal_tpm = has_tpm && seal_allowed
	}
	switch mode {
	case .Recovery_Shown, .Principal_Recovery_Shown, .Write_Unknown:
		// The recovery key, in the font of the cells: 39 cells of 8 pixels
		// after a prompt of 14 cells fit in the window. Its element name
		// gives a machine test its place.
		shown := string(recovery_text[:])
		interface.draw_text(table, x, 48, shown, graphics.colors.text)
		interface.element_name(&frame, {x, 48, len(shown) * graphics.CELL_WIDTH, graphics.CELL_HEIGHT}, "recovery_key")
	case .Change_Result, .Machine_Reseal_Result, .Write_Result:
		// Nothing is typed: the sentence of the end is the message below.
	case .Machine_Recovery, .Principal_Recovery:
		// The recovery key typed is drawn: it is copied from paper, and its
		// user checks it. At most RECOVERY_TYPED_LIMIT cells: it fits.
		end := interface.draw_text(table, x, 48, string(typed[:typed_count]), graphics.colors.text)
		interface.draw_rectangle(table, end + 2, 48, 2, 16, graphics.colors.text)
	case .Unlock, .Create_First, .Create_Again, .Machine_Unlock, .Machine_Create_First, .Machine_Create_Again, .Machine_Reseal_First, .Machine_Reseal_Again, .New_Passphrase_First, .New_Passphrase_Again, .Change_Current, .Done:
		// One dot for each character typed: the passphrase itself is never
		// drawn.
		dots := text_encoding.character_count(typed[:typed_count])
		for index in 0 ..< dots {
			interface.draw_rectangle(table, x + 2 + index * 10, 54, 6, 6, graphics.colors.text)
		}
		interface.draw_rectangle(table, x + 2 + dots * 10, 48, 2, 16, graphics.colors.text)
	}
	if message != "" {
		interface.draw_text(table, 12, 84, message, message_failed ? graphics.colors.failed : graphics.colors.process)
	}
	switch {
	case mode == .Write_Result || mode == .Write_Unknown:
		// The store holds no seal, or one that is not known: a sentence on
		// a seal would say what the disk may not hold.
	case of_the_machine:
		interface.draw_text(table, 12, 116, machine_seal_sentence(), graphics.colors.dim)
	case of_the_principal_tpm:
		// 62 cells of 8 pixels after a margin of 12: it fits in 520 pixels.
		interface.draw_text(table, 12, 116, "sealed by the TPM with the passphrase, with a copy for recovery", graphics.colors.dim)
	case:
		interface.draw_text(table, 12, 116, "no TPM seal: the passphrase alone protects the keys", graphics.colors.dim)
	}
	bar_y := HEIGHT - interface.ACTION_BAR_ROW_HEIGHT
	interface.draw_rectangle(table, 0, bar_y, WIDTH, interface.ACTION_BAR_ROW_HEIGHT, graphics.colors.card_bottom)
	interface.draw_rectangle(table, 0, bar_y, WIDTH, 1, graphics.colors.track)
	bar_left := 0
	if note != "" {
		bar_left = interface.draw_text(table, 12, bar_y + (interface.ACTION_BAR_ROW_HEIGHT - graphics.CELL_HEIGHT) / 2, note, graphics.colors.dim) + 16
	}
	items: [3]interface.Action_Bar_Item
	item_count := 0
	items[item_count] = interface.action_bar_item(enter_name, 2, "Enter")
	item_count += 1
	// A lost passphrase reaches its recovery key with no wrong try: each
	// wrong try counts in the TPM, against the machine passphrase and each
	// named principal together.
	if machine_recovery_offered() || principal_recovery_offered() {
		items[item_count] = interface.action_bar_item("recovery key", 1, "Ctrl", "r")
		item_count += 1
	}
	if clears {
		items[item_count] = interface.action_bar_item("clear", 1, "Esc")
		item_count += 1
	}
	// The items stand from the right edge: the fact at the left changes
	// with the mode, and the items keep their places.
	bar_result := interface.action_bar(&frame, {bar_left, bar_y, WIDTH - bar_left, interface.ACTION_BAR_ROW_HEIGHT}, items[:item_count], &bar, {alignment = .Right})
	interface.window_frame_end(&drawing, &frame, window)
	return bar_result
}

// enter acts on the passphrase typed.
enter :: proc "contextless" (window: ^display.Window) {
	switch mode {
	case .Unlock:
		message, message_failed = "deriving the key", false
		draw(window)
		passphrase_try()
	case .Machine_Unlock:
		// Enter with nothing skips the machine passphrase: the machine runs,
		// and the disk grants of principal 0 stay absent.
		if typed_count == 0 {
			system.log("unlock: the machine passphrase is not typed: the disk grants of principal 0 stay absent until unlock asks again")
			after_machine()
			return
		}
		message, message_failed = "deriving the key", false
		draw(window)
		machine_try()
	case .Machine_Recovery:
		// Enter with nothing skips the recovery key, as the machine
		// passphrase: the machine runs, and the disk grants of principal 0
		// stay absent.
		if typed_count == 0 {
			if machine_passphrase_back() {
				system.log("unlock: the recovery key of the machine key is not typed: the window asks for the machine passphrase again")
				mode = .Machine_Unlock
				message, message_failed = "the disk grants of the machine wait for it", false
				return
			}
			system.log("unlock: the recovery key is not typed: the disk grants of principal 0 stay absent until unlock asks again")
			after_machine()
			return
		}
		message, message_failed = "opening the copy of the machine key", false
		draw(window)
		recovery_try()
	case .Principal_Recovery:
		// Enter with nothing goes back to the passphrase while the TPM
		// service runs: after a lockout, the principal can wait for the TPM.
		if typed_count == 0 {
			if has_tpm {
				system.log("unlock: the recovery key of principal ", number, " is not typed: the window asks for its passphrase again")
				mode = .Unlock
				message, message_failed = "", false
			}
			return
		}
		message, message_failed = "opening the copy of the keys", false
		draw(window)
		principal_recovery_try()
	case .Recovery_Shown, .Principal_Recovery_Shown:
		// Its user wrote the recovery key down. The file or the record that
		// holds the copy under it is written only now. The key is erased
		// unless the write is not known: then it stays on the screen.
		message, message_failed = "writing", false
		draw(window)
		if mode == .Principal_Recovery_Shown && change_mode == .New_Recovery_Key {
			erase(recovery_text[:])
			recovery_key_commit()
		} else {
			// The line that a machine test waits for in order: nothing is
			// written, and nothing reaches the root service, before it.
			if pending_write != .None {
				system.log("unlock: Enter on the recovery key: it is written down, and the record or the file that holds its copy is written now")
			}
			// pending_write stays: the screen of a failed write names what
			// was not written.
			switch pending_write {
			case .Principal_Created:
				principal_created_commit()
			case .Machine_Passphrase_Set:
				machine_passphrase_commit()
			case .Machine_Key_Sealed:
				machine_key_sealed_commit()
			case .None:
				erase(recovery_text[:])
				mode = .Done
			}
		}
	case .Change_Result, .Write_Result:
		mode = .Done
	case .Write_Unknown:
		// The owner read that the record may be on the disk, and kept the
		// recovery key: it is erased now, and the next start of unlock
		// reads what the disk holds.
		erase(recovery_text[:])
		mode = .Done
	case .Machine_Reseal_Result:
		// The owner read why the key is not sealed again: the window goes
		// on to the named principal, or ends.
		after_machine()
	case .Change_Current:
		// Enter with nothing ends the change: nothing changes, and the
		// session goes on.
		if typed_count == 0 {
			system.log("unlock: the current passphrase of principal ", number, " is not typed: nothing changes")
			change_end(.Cancelled)
			mode = .Done
			return
		}
		message, message_failed = "deriving the key", false
		draw(window)
		change_proof_try()
	case .Create_First, .Machine_Create_First, .New_Passphrase_First, .Machine_Reseal_First:
		// In a change, Enter with nothing ends it: the keys that the proof
		// opened must not wait for anyone at the keyboard.
		if mode == .New_Passphrase_First && typed_count == 0 && change_mode == .Change_Passphrase {
			erase(opened_secrets[:])
			system.log("unlock: the new passphrase of principal ", number, " is not typed: nothing changes")
			change_end(.Cancelled)
			mode = .Done
			return
		}
		// After a recovery of the machine key, Enter with nothing skips the
		// new seal: the root service has the key of the table already.
		if mode == .Machine_Reseal_First && typed_count == 0 {
			erase(opened_machine_key[:])
			system.log("unlock: no new machine passphrase is typed: the machine key is not sealed again, and the recovery key opens it at the next start too")
			after_machine()
			return
		}
		if problem := principals.passphrase_problem(typed[:typed_count]); problem != .None {
			message, message_failed = principals.passphrase_problem_sentences[problem], true
		} else {
			first_count = copy(first[:], typed[:typed_count])
			switch mode {
			case .Create_First:
				mode = .Create_Again
			case .Machine_Create_First:
				mode = .Machine_Create_Again
			case .Machine_Reseal_First:
				mode = .Machine_Reseal_Again
			case .Unlock, .Create_Again, .Machine_Unlock, .Machine_Create_Again, .Machine_Recovery, .Machine_Reseal_Again, .Machine_Reseal_Result, .Recovery_Shown, .Principal_Recovery, .Principal_Recovery_Shown, .New_Passphrase_First, .New_Passphrase_Again, .Change_Current, .Change_Result, .Write_Result, .Write_Unknown, .Done:
				// A new passphrase after a recovery or in a change: the
				// other first modes are above.
				mode = .New_Passphrase_Again
			}
			message, message_failed = "type it again", false
		}
	case .Create_Again, .Machine_Create_Again, .New_Passphrase_Again, .Machine_Reseal_Again:
		// The mode of the first passphrase, for a second one that differs
		// and for a creation that failed before it wrote a file.
		first_mode := Mode.Create_First
		switch mode {
		case .Machine_Create_Again:
			first_mode = .Machine_Create_First
		case .New_Passphrase_Again:
			first_mode = .New_Passphrase_First
		case .Machine_Reseal_Again:
			first_mode = .Machine_Reseal_First
		case .Unlock, .Create_First, .Create_Again, .Machine_Unlock, .Machine_Create_First, .Machine_Recovery, .Machine_Reseal_First, .Machine_Reseal_Result, .Recovery_Shown, .Principal_Recovery, .Principal_Recovery_Shown, .New_Passphrase_First, .Change_Current, .Change_Result, .Write_Result, .Write_Unknown, .Done:
			// The creation of a named principal starts again at its first mode.
		}
		if string(first[:first_count]) != string(typed[:typed_count]) {
			message, message_failed = "the two passphrases differ: type a new one", true
			mode = first_mode
		} else {
			again_mode := mode
			message, message_failed = "deriving the key", false
			draw(window)
			switch again_mode {
			case .Machine_Create_Again:
				machine_create()
			case .Machine_Reseal_Again:
				// The key is erased at the end of the seal, whatever its
				// result: the window goes on to the named principal.
				machine_passphrase_reseal()
			case .New_Passphrase_Again:
				// The same two modes after a recovery and in a change: a
				// recovery starts the session, a change keeps it.
				if change_mode == .Change_Passphrase {
					passphrase_change_seal()
				} else {
					principal_reseal()
				}
			case .Unlock, .Create_First, .Create_Again, .Machine_Unlock, .Machine_Create_First, .Machine_Recovery, .Machine_Reseal_First, .Machine_Reseal_Result, .Recovery_Shown, .Principal_Recovery, .Principal_Recovery_Shown, .New_Passphrase_First, .Change_Current, .Change_Result, .Write_Result, .Write_Unknown, .Done:
				// The second passphrase of the creation of a named principal.
				create()
			}
			// A procedure that wrote a record or started a session changed
			// the mode; one that failed before left it.
			if mode == again_mode {
				mode = first_mode
			}
		}
		erase(first[:])
		first_count = 0
	case .Done:
	}
	erase(typed[:])
	typed_count = 0
}

// principal_file_read reads the file of the named principal from the store,
// in its form, and gives its public part to the root service. It gives
// false when the store holds no file. A file that does not decode, or a
// record that the root service refuses, stops the process with the code 1.
principal_file_read :: proc "contextless" () -> (found: bool) {
	buffer: [principals.PRINCIPAL_FILE_LIMIT + 1]u8
	bytes, present, read_status := storage.read(&client, storage.ROOT, principals.FILE_OBJECT, buffer[:])
	if read_status != .Ok {
		system.log("unlock: the store did not give the file of the principal: status ", u64(read_status))
		system.stop(1)
	}
	if !present {
		return false
	}
	problem: principals.File_Problem
	principal_form = principals.principal_record_form(bytes)
	switch principal_form {
	case .Passphrase:
		file, file_bytes, problem = principals.file_decode(bytes)
		if problem != .None {
			system.log("unlock: the file of the principal is refused: ", principals.file_problem_sentences[problem])
			system.stop(1)
		}
		name, name_length = file.name, file.name_length
		signing_public_key, unlock_public_key = file.signing_public_key, file.unlock_public_key
	case .Sealed_By_The_Tpm:
		principal_tpm_file, principal_tpm_file_bytes, problem = principals.principal_tpm_file_decode(bytes)
		if problem != .None {
			system.log("unlock: the file of the principal sealed by the TPM is refused: ", principals.principal_tpm_file_problem_sentences[problem])
			system.stop(1)
		}
		name, name_length = principal_tpm_file.name, principal_tpm_file.name_length
		signing_public_key, unlock_public_key = principal_tpm_file.signing_public_key, principal_tpm_file.unlock_public_key
	case .Unknown:
		system.log("unlock: the file of the principal is refused: it starts with neither PRINCIPL nor PRINCIPT")
		system.stop(1)
	}
	if !record_give() {
		system.stop(1)
	}
	return true
}

// The entry of unlock: it reads or creates the record of a named principal,
// asks for the passphrase, and stops when the session starts.
//
// The entry takes its random generator, opens the ring to the root service
// and its private store; with no ring or no store it stops with the code 1.
// Then:
//
// - **Create** (the context value `VALUE_MODE` is `Unlock_Mode.Create_Principal`):
//   it checks the name of the new principal and asks for a passphrase of 8
//   bytes at least.
// - **Set the machine passphrase** (`Unlock_Mode.Set_Machine_Passphrase`): with
//   no record "machine", it asks for a passphrase two times, makes the
//   machine key, seals it, and gives the root service the key of the tag.
//   With the TPM service and Secure Boot on, the TPM seals the key with the
//   passphrase, and the window shows a recovery key until Enter, before the
//   record is written.
// - **Seal the machine key** (`Unlock_Mode.Seal_Machine_Key`): with the TPM
//   service and no record "machine", it makes the machine key and a
//   recovery key, has the TPM service seal the key, and shows the recovery
//   key until Enter; then it writes the record and gives the root service
//   the key of the tag. Each window that shows a new recovery key writes
//   its record or its file only after Enter: a stop before it (a lock, a
//   close) leaves the disk as it was.
// - **Change the passphrase** (`Unlock_Mode.Change_Passphrase`) or **make a new
//   recovery key** (`Unlock_Mode.New_Recovery_Key`) of the principal whose
//   session runs: it reads the file, asks for the current passphrase,
//   which opens the keys as an unlock does, then for the new passphrase two
//   times, or shows the new recovery key until Enter. Enter with nothing
//   ends the change. A file that cannot take the change (a new recovery key
//   for the form under the passphrase alone, no TPM service for the form
//   sealed by the TPM, a new seal with Secure Boot off) stops it with the
//   code 1 before its window opens.
// - **Unlock**: it reads the file "principal", and the record "machine"
//   unless the mode is `Unlock_Mode.Unlock_Machine_Key_Held`. With a record under
//   a machine passphrase it asks for the machine passphrase first; when
//   the TPM seals the key with it and refuses for another cause than a
//   wrong passphrase, it asks for the recovery key, then for a new machine
//   passphrase that the TPM seals the key again with. With a
//   record sealed by the TPM it asks the TPM service for the key, and asks
//   for the recovery key only when the TPM refuses; after a recovery it
//   seals the key again to the system that runs. When the file or the
//   record opened, and after each write of a new secret, it asks the
//   store to erase their versions, so an old secret opens no version of
//   them (src/md/features/version_erase.md). Enter with nothing skips
//   either. With no record to ask for and no file it writes "unlock: no
//   named principal: the machine runs as principal 0, with no unlock" and
//   stops with the code 0.
//   A file that does not decode, or a record that the root service
//   refuses, stops it with the code 1.
//
// It reserves the memory of Argon2id (about 19 MiB), opens its window, and
// reads keys until the passphrase opens the seal and the root service
// starts the session. It then stops with the code 0. A wrong passphrase
// keeps the window open.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	// With no seed, each key is refused (create).
	if !random.generator_from_context(&generator, ctx) {
		system.log("unlock: the root service gave no random seed")
	}
	status: system.Status
	if requests, status = system.ring_open(ctx.handles[system.GRANT_ROOT]); status != .Ok {
		system.log("unlock: no ring to the root service")
		system.stop(1)
	}
	ok: bool
	if client, ok = storage.open(ctx); !ok {
		system.log("unlock: no store: no named principal can be kept")
		system.stop(1)
	}
	// The TPM service, when the system is measured into a TPM.
	tpm_open(ctx)
	// A word that names no mode is refused: an unlock in its place would do
	// what the starter did not ask for.
	start_mode, start_mode_ok := principals.unlock_mode_of_word(ctx.values[principals.VALUE_MODE])
	if !start_mode_ok {
		system.log("unlock: the root service gave the mode ", ctx.values[principals.VALUE_MODE], ", which names no mode of unlock: nothing is done")
		system.stop(1)
	}
	switch start_mode {
	case .Seal_Machine_Key:
		// The root service refuses this mode with no TPM service, or with a
		// record of the machine key; the store is read again here, as the
		// store is the truth.
		if !has_tpm {
			system.log("unlock: no TPM service: no machine key is sealed by the TPM")
			system.stop(1)
		}
		if !seal_allowed {
			system.log("unlock: the firmware did not verify the boot program (Secure Boot is off): no machine key is sealed by the TPM")
			system.stop(1)
		}
		switch machine_record_read() {
		case .Absent:
		case .Present:
			system.log("unlock: the machine has a record of its machine key already: a change is not built")
			system.stop(1)
		case .Unreadable:
			system.log("unlock: the record of the machine key cannot be read: no new machine key replaces it")
			system.stop(1)
		}
		if !machine_seal_create() {
			system.stop(1)
		}
		mode = .Recovery_Shown
		message = "write it down, then Enter: the record is written then"
	case .Create_Principal:
		name, name_length = principals.name_unpack({ctx.values[principals.VALUE_NAME], ctx.values[principals.VALUE_NAME + 1], ctx.values[principals.VALUE_NAME + 2]})
		if principals.name_problem(the_name()) != .None {
			system.log("unlock: the name of the new principal is refused")
			system.stop(1)
		}
		mode = .Create_First
		message = "type a passphrase of 8 bytes at least"
	case .Set_Machine_Passphrase:
		// The root service refuses a second machine passphrase; the record
		// is read again here, as the store is the truth. Only a store that
		// holds no record lets a new one be written.
		switch machine_record_read() {
		case .Absent:
		case .Present:
			system.log("unlock: the machine has a passphrase already: a change is not built")
			system.stop(1)
		case .Unreadable:
			system.log("unlock: the record of the machine passphrase cannot be read: no new passphrase replaces it")
			system.stop(1)
		}
		mode = .Machine_Create_First
		message = "type a passphrase of 8 bytes at least"
	case .Change_Passphrase, .New_Recovery_Key:
		// The root service starts these modes only for a principal whose
		// session runs; the file is read again here, as the store is the
		// truth, and its record must be the record of that session.
		change_mode = start_mode
		if !principal_file_read() {
			system.log("unlock: no named principal: there is no passphrase to change")
			change_end(.Refused, .Unknown_Form)
			system.stop(1)
		}
		if problem := principals.change_problem(principal_form, change_mode, has_tpm, seal_allowed); problem != .None {
			system.log("unlock: principal ", number, " \"", the_name(), "\" is not changed: ", principals.change_problem_sentences[problem])
			// The console that asked gives the cause: the sentence does not
			// fit on one line of the window.
			change_end(.Refused, problem)
			system.stop(1)
		}
		mode = .Change_Current
		if principal_form == .Sealed_By_The_Tpm {
			message = "type the current passphrase: the TPM counts each wrong try"
		} else {
			message = "type the current passphrase of the principal"
		}
		system.log("unlock: principal ", number, " \"", the_name(), "\" asks for a change: its current passphrase comes first")
	case .Unlock, .Unlock_Machine_Key_Held:
		principal_found = principal_file_read()
		// After a lock the root service holds the key of the table of
		// principal 0 already: the machine passphrase is not asked again.
		record_state := Record_State.Absent
		if start_mode != .Unlock_Machine_Key_Held {
			record_state = machine_record_read()
		}
		machine_asked := false
		machine_recovery := false // The TPM did not release the machine key: the window asks for the recovery key.
		switch record_state {
		case .Absent:
		case .Present:
			sealed_by_the_tpm := machine_form == .Sealed_By_The_Tpm
			key_form := sealed_by_the_tpm ? root_ring.Machine_Key_Form.Sealed_By_The_Tpm : root_ring.Machine_Key_Form.Passphrase
			completion, answered := root_command(.Machine_Key, {4 = u64(root_ring.Machine_Key_State.Awaited), 5 = u64(key_form)})
			switch {
			case !answered || system.Status(completion.kind) != .Ok:
				system.log("unlock: the root service did not take the state of the machine passphrase: status ", u64(completion.kind))
			case machine_form == .Sealed_By_The_Tpm_With_Passphrase && !has_tpm:
				// The passphrase opens nothing without the TPM.
				system.log("unlock: the machine key is sealed by the TPM with the machine passphrase, and no TPM service runs: the recovery key opens it")
				machine_asked, machine_recovery = true, true
			case !sealed_by_the_tpm:
				machine_asked = true
			case machine_tpm_unseal() == .Refused:
				// No typing when the TPM releases the key: the window asks
				// only when it does not.
				machine_asked, machine_recovery = true, true
			}
		case .Unreadable:
			// No key comes from a record that cannot be read. The root
			// service refuses each change of the table of principal 0, and
			// a new machine passphrase, so nothing is written over a table
			// or a record that can be good.
			completion, answered := root_command(.Machine_Key, {4 = u64(root_ring.Machine_Key_State.Unreadable)})
			if !answered || system.Status(completion.kind) != .Ok {
				system.log("unlock: the root service did not take the state of the machine passphrase: status ", u64(completion.kind))
			}
			system.log("unlock: the record of the machine passphrase cannot be read: the disk grants of principal 0 stay absent, and nothing replaces the record")
		}
		switch {
		case machine_recovery:
			mode = .Machine_Recovery
			message = "the TPM refuses: type the recovery key of the machine"
			system.log("unlock: the machine key waits for its recovery key: the disk grants of principal 0 come when it is typed")
		case machine_asked:
			mode = .Machine_Unlock
			message = "the disk grants of the machine wait for it"
			system.log("unlock: the machine has a passphrase: the disk grants of principal 0 come when it is typed")
		case principal_found:
			principal_ask()
		case:
			system.log("unlock: no named principal: the machine runs as principal 0, with no unlock")
			system.stop(0)
		}
	}
	// From here a key must be typed. On a machine with no screen the root
	// service gives no window: one line names what cannot be typed, and the
	// process stops before it pays the blocks of Argon2id.
	if ctx.handles[system.GRANT_DISPLAY] == 0 {
		no_screen_stop()
	}
	// The blocks of Argon2id.
	memory, memory_status := system.memory_create(principals.DERIVATION_MEMORY_PAGES)
	address: rawptr
	if memory_status == .Ok {
		address, memory_status = system.memory_map(memory)
	}
	if memory_status != .Ok {
		system.log("unlock: no memory for the derivation of the key: status ", u64(memory_status))
		system.stop(1)
	}
	work = {bytes = ([^]u8)(address), count = 0, capacity = principals.DERIVATION_MEMORY_KIBIBYTES * 1024}
	window, opened := display.open(ctx, WIDTH, HEIGHT, "unlock")
	if !opened {
		system.stop(1)
	}
	for mode != .Done {
		// A press on an item of the action bar runs its key, as the key
		// does; the next turn draws what it changed.
		if bar_result := draw(&window); bar_result.ran {
			key_run(&window, bar_result.run)
			continue
		}
		wait: system.Wait
		display.wait_events(&wait, &window)
		system.wait_end(&wait)
		for event in display.next_event(&window) {
			switch event.kind {
			case .Pointer:
				// The pointer reaches the action bar only: the next turn
				// draws a frame with it.
				interface.input_add(&drawing.input, event)
			case .Key:
				if !event.pressed {
					continue
				}
				// The open list of the action bar takes its keys first.
				press := interface.Key_Press{code = event.code, character = event.character, modifiers = event.modifiers}
				outcome := interface.action_bar_key(&bar, press)
				if outcome.ran {
					key_run(&window, outcome.run)
				}
				if !outcome.taken {
					key_run(&window, press)
				}
			case .None, .Settings_Changed, .Go_To, .Resized, .Copy_Asked, .Pasted:
				// next_event never gives None, and this window does nothing for the other events.
			}
			if mode == .Done {
				break
			}
		}
	}
	system.stop(0)
}

// key_run runs one key: a typed key, or the key of an item of the action
// bar that a press ran.
key_run :: proc "contextless" (window: ^display.Window, press: interface.Key_Press) {
	switch {
	case press.code == display.KEY_ESCAPE:
		erase(typed[:])
		typed_count = 0
	case press.character == '\n':
		enter(window)
	case press.character == 8:
		// The passphrase is UTF-8: Backspace removes its last
		// whole character, and erases its bytes.
		if typed_count > 0 {
			kept := text_encoding.complete_characters(typed[:typed_count - 1])
			erase(typed[kept:typed_count])
			typed_count = kept
		}
	case (press.modifiers & display.MODIFIER_CONTROL) != 0 && (press.character == 'r' || press.character == 'R'):
		// Ctrl+R asks for a recovery key with no try of the passphrase,
		// which the TPM would count. It types nothing in any mode.
		switch {
		case machine_recovery_offered():
			erase(typed[:])
			typed_count = 0
			system.log("unlock: the recovery key of the machine key is asked in the window: the TPM counts no try of the machine passphrase")
			machine_recovery_ask("type the recovery key of the machine")
		case principal_recovery_offered():
			erase(typed[:])
			typed_count = 0
			// Not principal_recovery_ask: its line says that the TPM refused,
			// and here the TPM was not asked.
			mode = .Principal_Recovery
			message, message_failed = "type the recovery key of the principal", false
			system.log("unlock: the recovery key of principal ", number, " \"", the_name(), "\" is asked in the window: the TPM counts no try of its passphrase")
		}
	case text_encoding.character_in_text(press.character):
		// A character whose bytes do not fit is not typed.
		recovery := mode == .Machine_Recovery || mode == .Principal_Recovery
		limit := recovery ? RECOVERY_TYPED_LIMIT : len(typed)
		if typed_count < limit {
			typed_count += text_encoding.character_encode(press.character, typed[typed_count:limit])
		}
	}
}

// The state of the action bar of the window.
bar: interface.Action_Bar_State
