// The unlock of a named principal (docs/PRINCIPALS.md): the program that
// keeps the record of a named principal in its private store, and asks for
// its passphrase in its window.
//
// A principal is a key pair: an Ed25519 key, to sign grants, and an X25519
// key, to unlock documents. Its record is the file "principal" of the store
// of this program: its name, its two public keys, and its two secret keys
// sealed with ChaCha20-Poly1305 under a key that Argon2id derives from the
// passphrase and a salt (src/library/support/principals). A wrong passphrase gives
// another key, and the seal does not open: no passphrase and no hash of it
// is kept or compared.
//
// The root service starts this program at boot. With no file it stops at
// once: the machine runs as principal 0 only, with no unlock. With a file
// it gives the public part of the record to the root service and asks for
// the passphrase; when the seal opens, it tells the root service, which
// starts the session of the principal, and it stops. The secret keys are
// erased at once: no part of the system uses them yet. The root service
// starts it again after a lock. To create a principal, the root service
// starts it with a name: the passphrase is typed two times, the keys are
// made from the generator of the program, and the session starts.
//
// The passphrase shows as dots. The seal by the TPM is not built: the
// strength of the record is the strength of the passphrase against
// Argon2id with 19 MiB and 2 passes, on a copy of the disk.
//
// It also keeps the record of the machine passphrase, the object "machine"
// of its store: the machine key, 32 random bytes, sealed in the same way
// (docs/PRINCIPALS.md, "Principal 0 and its machine passphrase"). With
// that record, and when the root service does not hold the key yet, it
// asks for the machine passphrase first. When the seal opens, it gives the
// root service the key of the tag of the disk grant table of principal 0,
// which the machine key gives, and erases the other keys: the root service
// then needs no key that opens the seal. The root service starts it with
// the mode MODE_SET_MACHINE_PASSPHRASE after `machine_passphrase()`.
//
// **What it is for.** It separates who holds the machine (principal 0) from
// a named principal whose programs run in a session of their own, with
// stores of their own. It is the only program that the root service
// believes when it says that a passphrase opened a seal.
//
// **Start**: the root service starts it; no line of the console does.
//
// - At boot, and again after `lock()` in the console.
// - With a name, after `principal_create("alice")` in the console: the
//   window asks for the passphrase two times.
//
// **Grants**, as the root service gives them:
//
// - **Store**: its private store, which holds the file "principal".
// - **Principals**: a ring to the root service for `Principal_Record`,
//   `Principal_Unlock` and `Machine_Key` only. No other program can send
//   these commands, so no other program can start a session or give the
//   key of the disk grant table of principal 0.
//
// **What a reader sees**: a window with the name of the principal and the
// passphrase as dots; Enter tries it, Backspace removes one byte, Escape
// clears it. The log has, for example:
//
// - `unlock: principal 1 "alice" is locked: its passphrase opens its session`;
// - `unlock: the passphrase of principal 1 "alice" opens its seal; ...`;
// - `unlock: the passphrase of principal 1 "alice" is wrong: ...`;
// - `unlock: the machine passphrase opens the machine key; ...`.
//
// **What it does not prove**: the secret keys sign and decrypt nothing yet.
// A wrong passphrase costs one derivation of Argon2id; nothing counts or
// slows the tries.
//
// The design: (docs/PRINCIPALS.md, "4. The unlock and the lock").
package unlock

import "base:intrinsics"
import "modus:contract/errors"
import "modus:contract/ring"
import "modus:support/disk_program"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/principals"
import "modus:support/random"
import "modus:support/storage"
import "modus:support/system"

// The blocks of Argon2id, 19 MiB (4864 pages)
// (src/library/support/principals, DERIVATION_MEMORY_PAGES).
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 5765, programs = 1, threads = 1, window_width = WIDTH, window_height = HEIGHT}

// The cost record of the export argon2id of the module cryptography: the
// same fields, in the same order (src/modules/cryptography).
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

records_now, records_before: [256]interface.Draw_Record
text_now, text_before: [4096]u8
drawing: interface.Window_Drawing

Mode :: enum {
	Unlock, // The passphrase of the principal of the file.
	Create_First, // The passphrase of a new principal.
	Create_Again, // The same passphrase again.
	Machine_Unlock, // The machine passphrase, before the passphrase of a named principal.
	Machine_Create_First, // A new machine passphrase.
	Machine_Create_Again, // The same machine passphrase again.
	Done,
}

mode: Mode
principal_found: bool // The store holds the file of a named principal: its unlock comes after the machine passphrase.

// The record of the machine passphrase, as the store gave it.
machine_file: principals.Machine_File
machine_file_bytes: [principals.MACHINE_FILE_SIZE]u8
machine_refusals: u64 // The wrong machine passphrases since the start.
requests: ring.Ring
request_tag: u32
generator: random.Generator
client: storage.Client

name: [principals.NAME_LIMIT]u8
name_length: int
number: u64 // The number of the principal in the root service.
file: principals.Principal_File
file_bytes: [principals.FILE_SIZE]u8

typed: [principals.PASSPHRASE_LIMIT]u8
typed_count: int
first: [principals.PASSPHRASE_LIMIT]u8 // The first passphrase of a creation, until the second one.
first_count: int
message: string = ""
message_failed: bool
refusals: u64 // The wrong passphrases since the start.

// The blocks of Argon2id: 19 MiB, one memory object of this program.
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

// root_command sends a command of the principals to the root service and
// waits for its completion.
root_command :: proc "contextless" (kind: system.Root_Command, values: [7]u64) -> (completion: ring.Record, answered: bool) {
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
	key := transmute([4]u64)file.signing_public_key
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
// service, and its session.
create :: proc "contextless" () {
	secrets: [principals.SECRET_KEYS_SIZE]u8
	key: [principals.KEY_SIZE]u8
	defer erase(secrets[:])
	defer erase(key[:])
	error: errors.Error_Record
	// The keys come from the generator of this program, seeded by the root
	// service from the sources of the processor; a weak seed is refused.
	if !random.fill_for_a_key(&generator, secrets[:], .Processor, &error) || !random.fill_for_a_key(&generator, file.salt[:], .Processor, &error) || !random.fill_for_a_key(&generator, file.nonce[:], .Processor, &error) {
		system.log("unlock: the seed of this program is too weak for a key: no principal is created")
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
	started := system.time()
	if !derive(typed[:typed_count], file.salt[:], &key) {
		message, message_failed = "the derivation of the key failed", true
		return
	}
	derived := system.time() - started
	principals.file_encode(&file, &file_bytes)
	key_text := string(key[:])
	nonce_text := string(file.nonce[:])
	additional := string(principals.file_additional_data(&file_bytes))
	text := string(secrets[:])
	sealed := file.sealed[:]
	if seal_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &text, &sealed, &error) != principals.SEALED_SIZE {
		message, message_failed = "the seal of the keys failed", true
		return
	}
	principals.file_encode(&file, &file_bytes)
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
	session_start()
}

// passphrase_try opens the seal with the passphrase typed. A wrong passphrase gives
// another key: the open fails, and nothing is unlocked.
passphrase_try :: proc "contextless" () {
	secrets: [principals.SECRET_KEYS_SIZE]u8
	key: [principals.KEY_SIZE]u8
	defer erase(secrets[:])
	defer erase(key[:])
	if !derive(typed[:typed_count], file.salt[:], &key) {
		message, message_failed = "the derivation of the key failed", true
		return
	}
	error: errors.Error_Record
	key_text := string(key[:])
	nonce_text := string(file.nonce[:])
	additional := string(principals.file_additional_data(&file_bytes))
	sealed := string(file.sealed[:])
	result := secrets[:]
	if open_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &sealed, &result, &error) != principals.SECRET_KEYS_SIZE {
		refusals += 1
		system.log("unlock: the passphrase of principal ", number, " \"", the_name(), "\" is wrong: the seal does not open, nothing is unlocked (", refusals, " in all)")
		message, message_failed = "the passphrase is wrong: nothing is unlocked", true
		return
	}
	// The secret keys must be the keys of the record: a file whose public
	// part does not match its seal is refused.
	signing, unlocking, ok := public_keys_of(&secrets)
	if !ok || signing != file.signing_public_key || unlocking != file.unlock_public_key {
		system.log("unlock: the sealed keys of principal ", number, " do not match its public keys: nothing is unlocked")
		message, message_failed = "the record is not consistent: nothing is unlocked", true
		return
	}
	system.log("unlock: the passphrase of principal ", number, " \"", the_name(), "\" opens its seal; the secret keys are erased: nothing uses them yet")
	session_start()
}

// machine_key_give gives the root service the key of the tag of the disk
// grant table of principal 0, which the machine key gives, and nothing
// else: the root service needs no key that opens the record. origin is
// MACHINE_KEY_OPENED or MACHINE_KEY_NEW: the root service writes over a
// table that does not verify only under a key of a new passphrase.
machine_key_give :: proc "contextless" (machine_key: ^[principals.MACHINE_KEY_SIZE]u8, origin: u64) -> bool {
	table_key := disk_program.table_key_of_machine_key(machine_key)
	values := transmute([4]u64)table_key
	defer erase(table_key[:])
	defer erase(([^]u8)(rawptr(&values))[:size_of(values)])
	completion, answered := root_command(.Machine_Key, {values[0], values[1], values[2], values[3], origin, 0, 0})
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
	mode = .Unlock
	message, message_failed = "", false
	system.log("unlock: principal ", number, " \"", the_name(), "\" is locked: its passphrase opens its session")
}

// machine_try opens the record of the machine with the passphrase typed. A
// wrong passphrase gives another key: the open fails, and the root service
// receives nothing.
machine_try :: proc "contextless" () {
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
	if !machine_key_give(&machine_key, system.MACHINE_KEY_OPENED) {
		message, message_failed = "the root service did not take the key", true
		return
	}
	system.log("unlock: the machine passphrase opens the machine key; the root service receives the key of the disk grant table only")
	after_machine()
}

// machine_create sets the machine passphrase: a new machine key, sealed in
// the record "machine" of the store of this program, and the key of the tag
// to the root service. It writes at most one record in a run: after the
// write it ends with the mode Done, or stops the program.
machine_create :: proc "contextless" () {
	machine_key: [principals.MACHINE_KEY_SIZE]u8
	key: [principals.KEY_SIZE]u8
	defer erase(machine_key[:])
	defer erase(key[:])
	error: errors.Error_Record
	// The key comes from the generator of this program, seeded by the root
	// service from the sources of the processor; a weak seed is refused.
	if !random.fill_for_a_key(&generator, machine_key[:], .Processor, &error) || !random.fill_for_a_key(&generator, machine_file.salt[:], .Processor, &error) || !random.fill_for_a_key(&generator, machine_file.nonce[:], .Processor, &error) {
		system.log("unlock: the seed of this program is too weak for a key: no machine passphrase is set")
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
	if !machine_key_give(&machine_key, system.MACHINE_KEY_NEW) {
		system.log("unlock: the root service did not take the key of the new machine passphrase; the record stays, and its passphrase opens it at the next start")
		erase(machine_key[:])
		erase(key[:])
		erase(typed[:])
		erase(first[:])
		system.stop(1)
	}
	mode = .Done
}

// What the store holds for the record of the machine passphrase.
Record_State :: enum u8 {
	Absent, // No record: the machine has no passphrase, and one can be set.
	Present, // A record that decodes: its passphrase opens it.
	Unreadable, // The store failed to give it, or it does not decode: it can hold a good key, so no new record is written over it.
}

// machine_record_read reads the record of the machine passphrase from the
// store. Only a store that answers "no object" gives Absent: a read error
// or a changed byte must never let a new passphrase replace a good key.
machine_record_read :: proc "contextless" () -> Record_State {
	buffer: [principals.MACHINE_FILE_SIZE + 1]u8
	bytes, found, read_status := storage.read(&client, storage.ROOT, principals.MACHINE_OBJECT, buffer[:])
	if read_status != .Ok {
		system.log("unlock: the store did not give the record of the machine passphrase: status ", u64(read_status))
		return .Unreadable
	}
	if !found {
		return .Absent
	}
	problem: principals.File_Problem
	machine_file, machine_file_bytes, problem = principals.machine_file_decode(bytes)
	if problem != .None {
		system.log("unlock: the record of the machine passphrase is refused: ", principals.machine_file_problem_sentences[problem])
		return .Unreadable
	}
	return .Present
}

session_start :: proc "contextless" () {
	completion, answered := root_command(.Principal_Unlock, {4 = number})
	if !answered || system.Status(completion.kind) != .Ok {
		system.log("unlock: the root service did not start the session of principal ", number, ": status ", u64(completion.kind))
		message, message_failed = "the root service did not start the session", true
		return
	}
	mode = .Done
}

draw :: proc "contextless" (window: ^display.Window) {
	if drawing.now.records == nil {
		drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	}
	frame := interface.window_frame_begin(&drawing, window)
	table := frame.table
	interface.draw_rectangle(table, 0, 0, WIDTH, HEIGHT, graphics.COLOR_BACKGROUND)
	// What the window asks for: the passphrase of a named principal, or
	// the machine passphrase of principal 0. The widest line, the hint of
	// Machine_Unlock, has 54 cells of 8 pixels: it fits in the window.
	label := "principal  "
	subject := the_name()
	prompt := "passphrase  "
	hint := "enter: unlock; escape: clear"
	switch mode {
	case .Unlock, .Done:
	case .Create_First:
		label = "new principal  "
	case .Create_Again:
		label = "new principal  "
		prompt = "again  "
	case .Machine_Unlock:
		label, subject = "machine passphrase  ", "principal 0"
		hint = "enter: unlock; enter with nothing: skip; escape: clear"
	case .Machine_Create_First:
		label, subject = "new machine passphrase  ", "principal 0"
		hint = "enter: set; escape: clear"
	case .Machine_Create_Again:
		label, subject = "new machine passphrase  ", "principal 0"
		prompt = "again  "
		hint = "enter: set; escape: clear"
	}
	x := interface.draw_text(table, 12, 12, label, graphics.COLOR_DIM)
	interface.draw_text(table, x, 12, subject, graphics.COLOR_TEXT)
	x = interface.draw_text(table, 12, 48, prompt, graphics.COLOR_DIM)
	// One dot for each byte typed: the passphrase itself is never drawn.
	for index in 0 ..< typed_count {
		interface.draw_rectangle(table, x + 2 + index * 10, 54, 6, 6, graphics.COLOR_TEXT)
	}
	interface.draw_rectangle(table, x + 2 + typed_count * 10, 48, 2, 16, graphics.COLOR_TEXT)
	if message != "" {
		interface.draw_text(table, 12, 84, message, message_failed ? graphics.COLOR_FAILED : graphics.COLOR_PROGRAM)
	}
	interface.draw_text(table, 12, 116, "no TPM seal: the passphrase alone protects the keys", graphics.COLOR_DIM)
	interface.draw_text(table, 12, HEIGHT - 26, hint, graphics.COLOR_DIM)
	interface.window_frame_end(&drawing, &frame, window)
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
	case .Create_First, .Machine_Create_First:
		if problem := principals.passphrase_problem(typed[:typed_count]); problem != .None {
			message, message_failed = principals.passphrase_problem_sentences[problem], true
		} else {
			first_count = copy(first[:], typed[:typed_count])
			mode = mode == .Create_First ? Mode.Create_Again : Mode.Machine_Create_Again
			message, message_failed = "type it again", false
		}
	case .Create_Again, .Machine_Create_Again:
		of_the_machine := mode == .Machine_Create_Again
		if string(first[:first_count]) != string(typed[:typed_count]) {
			message, message_failed = "the two passphrases differ: type a new one", true
			mode = of_the_machine ? Mode.Machine_Create_First : Mode.Create_First
		} else {
			message, message_failed = "deriving the key", false
			draw(window)
			if of_the_machine {
				machine_create()
			} else {
				create()
			}
			if mode != .Done {
				mode = of_the_machine ? Mode.Machine_Create_First : Mode.Create_First
			}
		}
		erase(first[:])
		first_count = 0
	case .Done:
	}
	erase(typed[:])
	typed_count = 0
}

// The entry of unlock: it reads or creates the record of a named principal,
// asks for the passphrase, and stops when the session starts.
//
// The entry takes its random generator, opens the ring to the root service
// and its private store; with no ring or no store it stops with the code 1.
// Then:
//
// - **Create** (the context value `VALUE_MODE` is `MODE_CREATE_PRINCIPAL`):
//   it checks the name of the new principal and asks for a passphrase of 8
//   bytes at least.
// - **Set the machine passphrase** (`MODE_SET_MACHINE_PASSPHRASE`): with
//   no record "machine", it asks for a passphrase two times, makes the
//   machine key, seals it, and gives the root service the key of the tag.
// - **Unlock**: it reads the file "principal", and the record "machine"
//   unless the mode is `MODE_UNLOCK_MACHINE_KEY_HELD`. With a record of the
//   machine it asks for the machine passphrase first; Enter with nothing
//   skips it. With neither it writes "unlock: no named principal: the
//   machine runs as principal 0, with no unlock" and stops with the code 0.
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
	switch ctx.values[principals.VALUE_MODE] {
	case principals.MODE_CREATE_PRINCIPAL:
		name, name_length = principals.name_unpack({ctx.values[principals.VALUE_NAME], ctx.values[principals.VALUE_NAME + 1], ctx.values[principals.VALUE_NAME + 2]})
		if principals.name_problem(the_name()) != .None {
			system.log("unlock: the name of the new principal is refused")
			system.stop(1)
		}
		mode = .Create_First
		message = "type a passphrase of 8 bytes at least"
	case principals.MODE_SET_MACHINE_PASSPHRASE:
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
	case:
		buffer: [principals.FILE_SIZE + 1]u8
		bytes, found, read_status := storage.read(&client, storage.ROOT, principals.FILE_OBJECT, buffer[:])
		if read_status != .Ok {
			system.log("unlock: the store did not give the file of the principal: status ", u64(read_status))
			system.stop(1)
		}
		if found {
			problem: principals.File_Problem
			file, file_bytes, problem = principals.file_decode(bytes)
			if problem != .None {
				system.log("unlock: the file of the principal is refused: ", principals.file_problem_sentences[problem])
				system.stop(1)
			}
			name, name_length = file.name, file.name_length
			if !record_give() {
				system.stop(1)
			}
			principal_found = true
		}
		// After a lock the root service holds the key of the table of
		// principal 0 already: the machine passphrase is not asked again.
		record_state := Record_State.Absent
		if ctx.values[principals.VALUE_MODE] != principals.MODE_UNLOCK_MACHINE_KEY_HELD {
			record_state = machine_record_read()
		}
		machine_asked := false
		switch record_state {
		case .Absent:
		case .Present:
			machine_asked = true
			completion, answered := root_command(.Machine_Key, {4 = system.MACHINE_KEY_AWAITED})
			if !answered || system.Status(completion.kind) != .Ok {
				system.log("unlock: the root service did not take the state of the machine passphrase: status ", u64(completion.kind))
				machine_asked = false
			}
		case .Unreadable:
			// No key comes from a record that cannot be read. The root
			// service refuses each change of the table of principal 0, and
			// a new machine passphrase, so nothing is written over a table
			// or a record that can be good.
			completion, answered := root_command(.Machine_Key, {4 = system.MACHINE_KEY_UNREADABLE})
			if !answered || system.Status(completion.kind) != .Ok {
				system.log("unlock: the root service did not take the state of the machine passphrase: status ", u64(completion.kind))
			}
			system.log("unlock: the record of the machine passphrase cannot be read: the disk grants of principal 0 stay absent, and nothing replaces the record")
		}
		switch {
		case machine_asked:
			mode = .Machine_Unlock
			message = "the disk grants of the machine wait for it"
			system.log("unlock: the machine has a passphrase: the disk grants of principal 0 come when it is typed")
		case principal_found:
			mode = .Unlock
			system.log("unlock: principal ", number, " \"", the_name(), "\" is locked: its passphrase opens its session")
		case:
			system.log("unlock: no named principal: the machine runs as principal 0, with no unlock")
			system.stop(0)
		}
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
		draw(&window)
		wait: system.Wait
		display.wait_events(&wait, &window)
		system.wait_end(&wait)
		for event in display.next_event(&window) {
			if event.kind != .Key || !event.pressed {
				continue
			}
			switch {
			case event.code == display.KEY_ESCAPE:
				erase(typed[:])
				typed_count = 0
			case event.character == '\n':
				enter(&window)
			case event.character == 8:
				if typed_count > 0 {
					typed_count -= 1
					typed[typed_count] = 0
				}
			case event.character >= ' ' && event.character <= '~':
				if typed_count < len(typed) {
					typed[typed_count] = event.character
					typed_count += 1
				}
			}
			if mode == .Done {
				break
			}
		}
	}
	system.stop(0)
}
