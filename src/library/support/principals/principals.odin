// The formats of the principals (docs/PRINCIPALS.md): the name of a store
// of a principal, the name of a principal, the passphrase, and the file in
// which the program `unlock` keeps the record of a named principal, with its
// secret keys sealed under a key that Argon2id derives from the passphrase.
//
// No allocator and no kernel operation: the host tests run each procedure
// (principals_test.odin). The root service, `unlock` and the console use
// the same procedures.
//
// The parts:
//
// - `name_problem`, `passphrase_problem`: the rules of a name and of a
//   passphrase, with a sentence for each refusal.
// - `name_pack`, `name_unpack`: a name in three values of a ring record.
// - `store_name_write`, `store_name_principal`: the name of the store of a
//   program in the session of a principal.
// - `Principal_File`, `file_encode`, `file_decode`,
//   `file_additional_data`: the file of `unlock`.
// - `Machine_File`, `machine_file_encode`, `machine_file_decode`,
//   `machine_file_additional_data`: the record of the machine passphrase,
//   with the sealed machine key.
// - `Machine_Tpm_File`, `machine_tpm_file_encode`,
//   `machine_tpm_file_decode`: the record of a machine key sealed by the
//   TPM, with its copy under the recovery key and its key check.
// - `recovery_key_text`, `recovery_key_parse`, `recovery_seal_key`,
//   `machine_key_check`: the recovery key and the key check.
// - `Sealed_Object`, `sealed_object_encode`, `sealed_object_decode`: the
//   four parts of a sealed object, in the two records sealed by the TPM.
// - `Principal_Tpm_File`, `principal_tpm_file_encode`,
//   `principal_tpm_file_decode`, `principal_record_form`: the file of a
//   named principal whose keys the TPM seals with its passphrase, with the
//   copy under its recovery key.
// - `principal_authorization_value`, `principal_tpm_seal_key`,
//   `principal_recovery_seal_key`: the keys of that file.
//
// See [principal](term:principal), [named principal](term:named-principal),
// [passphrase](term:passphrase), [recovery key](term:recovery-key),
// [authorization value](term:authorization-value) and
// [TPM secret](term:tpm-secret).
package principals

import "modus:contract/text_encoding"
import blake2 "modus:support/cryptography/_blake2"
import "modus:support/tpm2"

// Principal 0 is the machine. Its record exists at each boot, and its
// session needs no unlock.
MACHINE :: 0
MACHINE_NAME :: "machine" // The name of principal 0.
// The records that the root service holds: principal 0 and one named
// principal. Several named principals on one machine are not built.
PRINCIPAL_CAPACITY :: 2

// The bytes of the name of a principal: three values of a ring record, with
// a zero byte after it.
NAME_LIMIT :: 23
PASSPHRASE_LEAST :: 8 // The fewest bytes of a passphrase.
PASSPHRASE_LIMIT :: 128 // The most bytes of a passphrase.

// The context values of the program `unlock`. 0 to 4 are the roles that the
// root service gives (the store: 3).
VALUE_MODE :: 5 // What this start of `unlock` does: the word of an Unlock_Mode.
VALUE_NAME :: 6 // 6, 7 and 8: the name, 24 bytes with zero bytes after it.
// 1: the firmware verified the boot program (Secure Boot was on), so
// `unlock` may seal the machine key by the TPM and seal it again after a
// recovery. 0: it may only unseal: a seal with Secure Boot off would trust
// a boot program that nothing verified.
VALUE_SEAL_ALLOWED :: 13

// What a start of `unlock` does. The root service writes its word in
// VALUE_MODE, so the values are those of the context and do not move.
Unlock_Mode :: enum u64 {
	// Ask for the machine passphrase if one is set, then unlock the
	// principal of the file.
	Unlock                  = 0,
	Create_Principal        = 1, // Create the principal named at VALUE_NAME.
	Set_Machine_Passphrase  = 2, // Set the machine passphrase.
	// Unlock the principal of the file: the root service holds the key of
	// the tag of the disk grant table of principal 0 already (after a
	// lock), so the machine passphrase is not asked again.
	Unlock_Machine_Key_Held = 3,
	// Make a machine key that the TPM service seals to the measure of the
	// system, and show its recovery key one time.
	Seal_Machine_Key        = 4,
	// Change the passphrase of the named principal whose session runs: the
	// current passphrase first, then the new one two times.
	Change_Passphrase       = 5,
	// Make a new recovery key for the named principal whose session runs,
	// after its current passphrase, and show it one time.
	New_Recovery_Key        = 6,
}

// unlock_mode_of_word reads the word of VALUE_MODE. A word that names no
// mode is refused: `unlock` does not guess what its starter asked for.
unlock_mode_of_word :: proc "contextless" (word: u64) -> (mode: Unlock_Mode, ok: bool) {
	for member in Unlock_Mode {
		if u64(member) == word {
			return member, true
		}
	}
	return {}, false
}

// mode_words names what a start of `unlock` runs for: the root service
// writes it on the line of a lock, which stops `unlock` whatever its mode
// (src/md/features/tpm_sealed_principal_keys.md).
mode_words :: proc "contextless" (mode: Unlock_Mode) -> string {
	switch mode {
	case .Unlock, .Unlock_Machine_Key_Held:
		return "an unlock"
	case .Create_Principal:
		return "the creation of a principal"
	case .Set_Machine_Passphrase:
		return "the machine passphrase that is set"
	case .Seal_Machine_Key:
		return "the machine key that the TPM seals"
	case .Change_Passphrase:
		return "a change of the passphrase"
	case .New_Recovery_Key:
		return "a new recovery key"
	}
	// Only a conversion that skips unlock_mode_of_word reaches this line:
	// it is said, not taken for an unlock.
	return "a mode that names no member"
}

// Change_Problem says why a file cannot take a change that a principal
// asks for, before the window asks for any passphrase. Its word crosses
// the root ring (Principal_Change_End), so each value is explicit.
Change_Problem :: enum u8 {
	None             = 0, // The change can be made.
	No_Recovery_Copy = 1, // A new recovery key for the form PRINCIPL: that form has no copy under a recovery key.
	No_Tpm_Service   = 2, // The form PRINCIPT with no TPM service: the current passphrase opens nothing without the TPM.
	Seal_Not_Allowed = 3, // A new passphrase for the form PRINCIPT with Secure Boot off: a new seal would trust a boot program that nothing verified.
	Unknown_Form     = 4, // The file has neither form.
	Unknown_Change   = 5, // A mode that is not a change.
}

@(rodata)
change_problem_sentences := [Change_Problem]string {
	.None             = "the change can be made",
	.No_Recovery_Copy = "the keys are sealed under the passphrase alone, and a recovery key for that form is not built",
	.No_Tpm_Service   = "the keys are sealed by the TPM, and no TPM service runs: the current passphrase opens nothing without it",
	.Seal_Not_Allowed = "the firmware did not verify the boot program (Secure Boot is off): a new seal by the TPM would trust a boot program that nothing verified",
	.Unknown_Form     = "the file of the principal has neither form",
	.Unknown_Change   = "the mode is not a change",
}

// How a change ended: `unlock` gives it to the root service
// (Principal_Change_End), which gives it to the console that asked. Each
// sentence fits on one line of the window of `unlock`: 63 cells. Its word
// crosses the root ring, so each value is explicit.
Change_End :: enum u8 {
	None                 = 0, // `unlock` stopped before the end of the change: a lock, a close, a fault.
	Passphrase_Changed   = 1, // The file has the new passphrase.
	Recovery_Key_Changed = 2, // The file has the copy under the new recovery key.
	Cancelled            = 3, // Enter with nothing: nothing changed.
	Refused              = 4, // The file cannot take this change: a Change_Problem says why.
	Seed_Too_Weak        = 5, // No key from the generator: nothing changed.
	Seal_Failed          = 6, // The TPM or the seal failed: nothing changed.
	Store_Failed         = 7, // The store did not keep the new file: nothing changed.
	Store_Unknown        = 8, // The store did not answer, and the file could not be read back: the old or the new secret opens it.
}

@(rodata)
change_end_sentences := [Change_End]string {
	.None                 = "unlock stopped before the end: the old or the new secret opens",
	.Passphrase_Changed   = "the passphrase is changed",
	.Recovery_Key_Changed = "the new recovery key is kept; the old one opens no new file",
	.Cancelled            = "the change is cancelled: nothing changed",
	.Refused              = "the file cannot take this change",
	.Seed_Too_Weak        = "nothing changed: the seed is too weak for a key",
	.Seal_Failed          = "nothing changed: the keys are not sealed again",
	.Store_Failed         = "nothing changed: the store did not keep the new file",
	.Store_Unknown        = "the store did not answer: the old or the new one opens",
}

// change_problem says if a file of the form `form` takes the change of the
// mode `mode` (.Change_Passphrase or .New_Recovery_Key), on a machine
// with or without the TPM service and the right to seal. A new recovery
// key seals no object by the TPM, so it needs no right to seal.
change_problem :: proc "contextless" (form: Principal_Record_Form, mode: Unlock_Mode, has_tpm: bool, seal_allowed: bool) -> Change_Problem {
	switch mode {
	case .Change_Passphrase, .New_Recovery_Key:
	case .Unlock, .Create_Principal, .Set_Machine_Passphrase, .Unlock_Machine_Key_Held, .Seal_Machine_Key:
		return .Unknown_Change
	}
	switch form {
	case .Unknown:
		return .Unknown_Form
	case .Passphrase:
		if mode == .New_Recovery_Key {
			return .No_Recovery_Copy
		}
	case .Sealed_By_The_Tpm:
		if !has_tpm {
			return .No_Tpm_Service
		}
		if mode == .Change_Passphrase && !seal_allowed {
			return .Seal_Not_Allowed
		}
	}
	return .None
}

// recovery_key_offered_at_unlock says if the passphrase prompt of an unlock
// offers the recovery key of a file of the form `form` at once (Ctrl+R in
// `unlock`). Only the form PRINCIPT has a copy under a recovery key, and
// only with the TPM service does its prompt ask for the passphrase: with no
// service it asks for the recovery key already. A principal who lost the
// passphrase then types no wrong try, which the TPM would count against the
// machine passphrase too.
recovery_key_offered_at_unlock :: proc "contextless" (form: Principal_Record_Form, has_tpm: bool) -> bool {
	return form == .Sealed_By_The_Tpm && has_tpm
}

// The key derivation: Argon2id (RFC 9106) with the first parameter set of
// the OWASP password storage cheat sheet: 19 MiB, 2 passes, 1 lane. A file
// with other parameters is refused: no file names its own cost.
DERIVATION_MEMORY_KIBIBYTES :: 19 * 1024
DERIVATION_PASSES :: 2
DERIVATION_MEMORY_PAGES :: DERIVATION_MEMORY_KIBIBYTES / 4 // The pages of 4096 bytes that the derivation needs.

SALT_SIZE :: 16 // The bytes of the salt of Argon2id.
NONCE_SIZE :: 12 // The bytes of the nonce of the seal (ChaCha20-Poly1305).
TAG_SIZE :: 16 // The bytes of the tag of the seal.
KEY_SIZE :: 32 // The bytes of the key that Argon2id derives.
PUBLIC_KEY_SIZE :: 32 // The bytes of an Ed25519 or X25519 public key.
// The two secret keys, sealed together: the Ed25519 seed (to sign grants)
// and the X25519 scalar (to unlock documents).
SECRET_KEYS_SIZE :: 64

// The file of a named principal: the object FILE_OBJECT in the store of
// `unlock`. The offsets, in bytes; each number is little-endian.
FILE_OBJECT :: "principal"
FILE_MAGIC :: "PRINCIPL" // The first 8 bytes of the file.
FILE_FORMAT :: u32(1) // The format number of the file. A file of another number is refused.
OFFSET_MAGIC :: 0 // 8 bytes.
OFFSET_FORMAT :: 8 // u32.
OFFSET_MEMORY :: 12 // u32: the KiB of Argon2id.
OFFSET_PASSES :: 16 // u32.
OFFSET_NAME_LENGTH :: 20 // u8.
OFFSET_NAME :: 21 // NAME_LIMIT bytes, zero bytes after the name.
OFFSET_SIGNING_PUBLIC_KEY :: OFFSET_NAME + NAME_LIMIT // 44: Ed25519.
OFFSET_UNLOCK_PUBLIC_KEY :: OFFSET_SIGNING_PUBLIC_KEY + PUBLIC_KEY_SIZE // 76: X25519.
OFFSET_SALT :: OFFSET_UNLOCK_PUBLIC_KEY + PUBLIC_KEY_SIZE // 108.
OFFSET_NONCE :: OFFSET_SALT + SALT_SIZE // 124.
// The sealed secret keys and their tag. The bytes before them are the
// additional data of the seal: a change of the name, of a public key, of the
// salt or of a parameter makes the open fail.
OFFSET_SEALED :: OFFSET_NONCE + NONCE_SIZE // 136.
SEALED_SIZE :: SECRET_KEYS_SIZE + TAG_SIZE // The sealed keys and their tag: 80 bytes.
FILE_SIZE :: OFFSET_SEALED + SEALED_SIZE // 216.
#assert(FILE_SIZE == 216)

// The file of a named principal, decoded: what `unlock` keeps in its store.
// `file_encode` writes it in 216 bytes; `file_decode` reads them as hostile
// input and refuses each other form.
Principal_File :: struct {
	name:               [NAME_LIMIT]u8, // The name of the principal.
	name_length:        int, // The bytes of the name.
	signing_public_key: [PUBLIC_KEY_SIZE]u8, // The Ed25519 public key that verifies its grants.
	unlock_public_key:  [PUBLIC_KEY_SIZE]u8, // The X25519 public key that seals its documents.
	salt:               [SALT_SIZE]u8, // The salt of Argon2id.
	nonce:              [NONCE_SIZE]u8, // The nonce of the seal.
	sealed:             [SEALED_SIZE]u8, // The two secret keys, sealed, and the tag.
}

// Why `file_decode` refused a file. The sentence of each one is in
// `file_problem_sentences`.
File_Problem :: enum u8 {
	None, // The file is valid.
	Wrong_Size, // Not 216 bytes.
	Wrong_Magic, // It does not start with FILE_MAGIC.
	Wrong_Format, // Another format number.
	Other_Parameters, // Other parameters of Argon2id than DERIVATION_MEMORY_KIBIBYTES and DERIVATION_PASSES.
	Bad_Name, // The name breaks `name_problem`.
	Bytes_After_Name, // A byte after the name is not zero.
	Bad_Area, // A record sealed by the TPM: an area is not a whole sized buffer within its limit, or a byte after it is not zero.
}

// The sentence of each problem of a file, for the window of `unlock` and the
// log.
@(rodata)
file_problem_sentences := [File_Problem]string {
	.None             = "",
	.Wrong_Size       = "the file does not have 216 bytes",
	.Wrong_Magic      = "the file does not start with PRINCIPL",
	.Wrong_Format     = "the file has another format number",
	.Other_Parameters = "the file names other parameters of Argon2id than 19456 KiB and 2 passes",
	.Bad_Name         = "the name in the file is not a name of a principal",
	.Bytes_After_Name = "the file has bytes that are not zero after the name",
	.Bad_Area         = "",
}

// Why a name of a principal is refused: the result of `name_problem`.
Name_Problem :: enum u8 {
	None, // The name is valid.
	Empty, // No byte.
	Too_Long, // More than NAME_LIMIT bytes.
	Bad_Byte, // A byte that is not a letter, a digit, '-', '_' or '.'.
}

// The sentence of each problem of a name.
@(rodata)
name_problem_sentences := [Name_Problem]string {
	.None     = "",
	.Empty    = "the name is empty",
	.Too_Long = "the name has more than 23 bytes",
	.Bad_Byte = "the name has a byte that is not a letter, a digit, '-', '_' or '.'",
}

// name_problem checks the name of a principal: 1 to 23 bytes of letters,
// digits, '-', '_' and '.'. The name is for display only: the number names
// the principal in the system.
name_problem :: proc "contextless" (name: string) -> Name_Problem {
	if len(name) == 0 {
		return .Empty
	}
	if len(name) > NAME_LIMIT {
		return .Too_Long
	}
	for index in 0 ..< len(name) {
		switch name[index] {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_', '.':
		case:
			return .Bad_Byte
		}
	}
	return .None
}

// Why a passphrase is refused: the result of `passphrase_problem`.
Passphrase_Problem :: enum u8 {
	None, // The passphrase is valid.
	Too_Short, // Fewer than PASSPHRASE_LEAST bytes.
	Too_Long, // More than PASSPHRASE_LIMIT bytes.
	Not_Text, // Not valid UTF-8, or a control character.
}

// The sentence of each problem of a passphrase.
@(rodata)
passphrase_problem_sentences := [Passphrase_Problem]string {
	.None      = "",
	.Too_Short = "the passphrase has fewer than 8 bytes",
	.Too_Long  = "the passphrase has more than 128 bytes",
	.Not_Text  = "the passphrase has a control character or a broken character",
}

// passphrase_problem checks a passphrase: 8 to 128 bytes of UTF-8 with no
// control character, the characters that the keys of a layout give. The
// bytes are not normalized: the keys give one form of each character, the
// precomposed one (src/md/data/text_encoding.md, "The chosen form").
passphrase_problem :: proc "contextless" (passphrase: []u8) -> Passphrase_Problem {
	if len(passphrase) < PASSPHRASE_LEAST {
		return .Too_Short
	}
	if len(passphrase) > PASSPHRASE_LIMIT {
		return .Too_Long
	}
	if !text_encoding.text_valid(passphrase) {
		return .Not_Text
	}
	return .None
}

// name_pack puts a name of a principal into three values of a ring record:
// 24 bytes, zero bytes after the name. A longer name is cut: check it first.
name_pack :: proc "contextless" (name: string) -> (values: [3]u64) {
	bytes: [24]u8
	copy(bytes[:NAME_LIMIT], name)
	return transmute([3]u64)bytes
}

// name_unpack gives the bytes of a name from three values, and its length:
// the bytes before the first zero byte, NAME_LIMIT at most.
name_unpack :: proc "contextless" (values: [3]u64) -> (name: [NAME_LIMIT]u8, length: int) {
	bytes := transmute([24]u8)values
	for length < NAME_LIMIT && bytes[length] != 0 {
		name[length] = bytes[length]
		length += 1
	}
	return
}

// store_name_write writes the name of the store that the root service gives
// to the connection of a program to the storage service: the name of the
// program for principal 0, so the stores of the system keep their names;
// "<program>.principal.<number>" for a named principal, so two principals
// that run one program have two stores. history adds ".history" after the
// name of the program (the store of the line history of the console). It
// gives false when the name and its zero byte do not fit in 32 bytes: the
// root service then refuses the connection, as a cut name could be the
// name of another store. This is the one place that builds the name: the
// identity of the package of the program (the key of the principal that
// signs it, and its name) enters here when storage attaches data to it
// (docs/PRINCIPALS.md, section 6).
store_name_write :: proc "contextless" (out: ^[32]u8, program: string, principal: u64, history: bool) -> bool {
	out^ = {}
	count := 0
	put :: proc "contextless" (into: ^[32]u8, written: ^int, text: string) -> bool {
		if written^ + len(text) > len(into^) - 1 {
			return false
		}
		copy(into^[written^:], text)
		written^ += len(text)
		return true
	}
	ok := put(out, &count, program)
	if ok && history {
		ok = put(out, &count, ".history")
	}
	if ok && principal != MACHINE {
		ok = put(out, &count, ".principal.")
		digits: [20]u8
		place := len(digits)
		value := principal
		for {
			place -= 1
			digits[place] = u8('0' + value % 10)
			value /= 10
			if value == 0 {
				break
			}
		}
		ok = ok && put(out, &count, string(digits[place:]))
	}
	if !ok {
		out^ = {}
	}
	return ok
}

// store_name_principal gives the principal of a store from its name: the
// inverse of store_name_write. A name with no ending ".principal.<number>"
// is a store of the machine. The storage service decides with it which
// stores a caller may name (docs/STORAGE.md, "No way up").
store_name_principal :: proc "contextless" (name: string) -> u64 {
	SUFFIX :: ".principal."
	digits_end := len(name)
	digits_start := digits_end
	for digits_start > 0 && name[digits_start - 1] >= '0' && name[digits_start - 1] <= '9' {
		digits_start -= 1
	}
	if digits_start == digits_end || digits_end - digits_start > 5 || digits_start < len(SUFFIX) || name[digits_start - len(SUFFIX):digits_start] != SUFFIX {
		return MACHINE
	}
	value: u64
	for index in digits_start ..< digits_end {
		value = value * 10 + u64(name[index] - '0')
	}
	return value
}

@(private)
u32_put :: proc "contextless" (bytes: []u8, value: u32) {
	bytes[0], bytes[1], bytes[2], bytes[3] = u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24)
}

@(private)
u32_get :: proc "contextless" (bytes: []u8) -> u32 {
	return u32(bytes[0]) | u32(bytes[1]) << 8 | u32(bytes[2]) << 16 | u32(bytes[3]) << 24
}

// file_encode writes the bytes of a file. The caller checked the name.
file_encode :: proc "contextless" (file: ^Principal_File, out: ^[FILE_SIZE]u8) {
	out^ = {}
	copy(out^[OFFSET_MAGIC:][:8], FILE_MAGIC)
	u32_put(out^[OFFSET_FORMAT:], FILE_FORMAT)
	u32_put(out^[OFFSET_MEMORY:], DERIVATION_MEMORY_KIBIBYTES)
	u32_put(out^[OFFSET_PASSES:], DERIVATION_PASSES)
	length := clamp(file.name_length, 0, NAME_LIMIT)
	out^[OFFSET_NAME_LENGTH] = u8(length)
	copy(out^[OFFSET_NAME:][:length], file.name[:length])
	copy(out^[OFFSET_SIGNING_PUBLIC_KEY:][:PUBLIC_KEY_SIZE], file.signing_public_key[:])
	copy(out^[OFFSET_UNLOCK_PUBLIC_KEY:][:PUBLIC_KEY_SIZE], file.unlock_public_key[:])
	copy(out^[OFFSET_SALT:][:SALT_SIZE], file.salt[:])
	copy(out^[OFFSET_NONCE:][:NONCE_SIZE], file.nonce[:])
	copy(out^[OFFSET_SEALED:][:SEALED_SIZE], file.sealed[:])
}

// file_decode reads a file that the store gave. It copies the bytes once
// and checks the copy: the store is data from the disk, which another
// machine or a fault can have changed. It does not check the seal: only
// the passphrase opens it.
file_decode :: proc "contextless" (bytes: []u8) -> (file: Principal_File, kept: [FILE_SIZE]u8, problem: File_Problem) {
	if len(bytes) != FILE_SIZE {
		return {}, {}, .Wrong_Size
	}
	copy(kept[:], bytes)
	if string(kept[OFFSET_MAGIC:][:8]) != FILE_MAGIC {
		return {}, {}, .Wrong_Magic
	}
	if u32_get(kept[OFFSET_FORMAT:]) != FILE_FORMAT {
		return {}, {}, .Wrong_Format
	}
	if u32_get(kept[OFFSET_MEMORY:]) != DERIVATION_MEMORY_KIBIBYTES || u32_get(kept[OFFSET_PASSES:]) != DERIVATION_PASSES {
		return {}, {}, .Other_Parameters
	}
	length := int(kept[OFFSET_NAME_LENGTH])
	if length > NAME_LIMIT || name_problem(string(kept[OFFSET_NAME:][:length])) != .None {
		return {}, {}, .Bad_Name
	}
	for after in kept[OFFSET_NAME + length:OFFSET_SIGNING_PUBLIC_KEY] {
		if after != 0 {
			return {}, {}, .Bytes_After_Name
		}
	}
	file.name_length = length
	copy(file.name[:], kept[OFFSET_NAME:][:length])
	copy(file.signing_public_key[:], kept[OFFSET_SIGNING_PUBLIC_KEY:][:PUBLIC_KEY_SIZE])
	copy(file.unlock_public_key[:], kept[OFFSET_UNLOCK_PUBLIC_KEY:][:PUBLIC_KEY_SIZE])
	copy(file.salt[:], kept[OFFSET_SALT:][:SALT_SIZE])
	copy(file.nonce[:], kept[OFFSET_NONCE:][:NONCE_SIZE])
	copy(file.sealed[:], kept[OFFSET_SEALED:][:SEALED_SIZE])
	return file, kept, .None
}

// file_additional_data gives the bytes of a file that the seal covers and
// that are not sealed: each byte before the sealed keys.
file_additional_data :: proc "contextless" (bytes: ^[FILE_SIZE]u8) -> []u8 {
	return bytes^[:OFFSET_SEALED]
}

// The record of the machine passphrase: the object MACHINE_OBJECT in the
// store of `unlock` (docs/PRINCIPALS.md, "Principal 0 and its machine
// passphrase"). It holds the machine key, 32 random bytes, sealed under
// the key that Argon2id derives from the machine passphrase. The machine key
// gives the key of the tag of the disk grant table of principal 0
// (modus:support/disk_program, table_key_of_machine_key). With no record,
// the machine has no passphrase.
MACHINE_OBJECT :: "machine"
MACHINE_MAGIC :: "MACHINEK" // The first 8 bytes of the record.
MACHINE_FORMAT :: u32(1) // A record of another format number is refused.
MACHINE_KEY_SIZE :: 32 // The bytes of the machine key.
MACHINE_OFFSET_MAGIC :: 0 // 8 bytes.
MACHINE_OFFSET_FORMAT :: 8 // u32.
MACHINE_OFFSET_MEMORY :: 12 // u32: the KiB of Argon2id.
MACHINE_OFFSET_PASSES :: 16 // u32.
MACHINE_OFFSET_SALT :: 20 // SALT_SIZE bytes.
MACHINE_OFFSET_NONCE :: MACHINE_OFFSET_SALT + SALT_SIZE // 36.
// The sealed machine key and its tag. The bytes before them are the
// additional data of the seal: a change of a parameter or of the salt makes
// the open fail.
MACHINE_OFFSET_SEALED :: MACHINE_OFFSET_NONCE + NONCE_SIZE // 48.
MACHINE_SEALED_SIZE :: MACHINE_KEY_SIZE + TAG_SIZE // 48.
MACHINE_FILE_SIZE :: MACHINE_OFFSET_SEALED + MACHINE_SEALED_SIZE // 96.
#assert(MACHINE_FILE_SIZE == 96)

// The record of the machine passphrase, decoded.
Machine_File :: struct {
	salt:   [SALT_SIZE]u8, // The salt of Argon2id.
	nonce:  [NONCE_SIZE]u8, // The nonce of the seal.
	sealed: [MACHINE_SEALED_SIZE]u8, // The machine key, sealed, and the tag.
}

// machine_file_encode writes the bytes of the record of the machine.
machine_file_encode :: proc "contextless" (file: ^Machine_File, out: ^[MACHINE_FILE_SIZE]u8) {
	out^ = {}
	copy(out^[MACHINE_OFFSET_MAGIC:][:8], MACHINE_MAGIC)
	u32_put(out^[MACHINE_OFFSET_FORMAT:], MACHINE_FORMAT)
	u32_put(out^[MACHINE_OFFSET_MEMORY:], DERIVATION_MEMORY_KIBIBYTES)
	u32_put(out^[MACHINE_OFFSET_PASSES:], DERIVATION_PASSES)
	copy(out^[MACHINE_OFFSET_SALT:][:SALT_SIZE], file.salt[:])
	copy(out^[MACHINE_OFFSET_NONCE:][:NONCE_SIZE], file.nonce[:])
	copy(out^[MACHINE_OFFSET_SEALED:][:MACHINE_SEALED_SIZE], file.sealed[:])
}

// machine_file_decode reads a record of the machine that the store gave.
// It copies the bytes once and checks the copy, as file_decode does. It
// does not check the seal: only the machine passphrase opens it. The
// problems are those of a file of a principal: Wrong_Size, Wrong_Magic,
// Wrong_Format and Other_Parameters.
machine_file_decode :: proc "contextless" (bytes: []u8) -> (file: Machine_File, kept: [MACHINE_FILE_SIZE]u8, problem: File_Problem) {
	if len(bytes) != MACHINE_FILE_SIZE {
		return {}, {}, .Wrong_Size
	}
	copy(kept[:], bytes)
	if string(kept[MACHINE_OFFSET_MAGIC:][:8]) != MACHINE_MAGIC {
		return {}, {}, .Wrong_Magic
	}
	if u32_get(kept[MACHINE_OFFSET_FORMAT:]) != MACHINE_FORMAT {
		return {}, {}, .Wrong_Format
	}
	if u32_get(kept[MACHINE_OFFSET_MEMORY:]) != DERIVATION_MEMORY_KIBIBYTES || u32_get(kept[MACHINE_OFFSET_PASSES:]) != DERIVATION_PASSES {
		return {}, {}, .Other_Parameters
	}
	copy(file.salt[:], kept[MACHINE_OFFSET_SALT:][:SALT_SIZE])
	copy(file.nonce[:], kept[MACHINE_OFFSET_NONCE:][:NONCE_SIZE])
	copy(file.sealed[:], kept[MACHINE_OFFSET_SEALED:][:MACHINE_SEALED_SIZE])
	return file, kept, .None
}

// machine_file_additional_data gives the bytes of a record of the machine
// that the seal covers and that are not sealed.
machine_file_additional_data :: proc "contextless" (bytes: ^[MACHINE_FILE_SIZE]u8) -> []u8 {
	return bytes^[:MACHINE_OFFSET_SEALED]
}

// machine_file_problem_sentences gives the sentence of each problem of a
// record of the machine, for the log of `unlock`.
@(rodata)
machine_file_problem_sentences := [File_Problem]string {
	.None             = "",
	.Wrong_Size       = "the record does not have 96 bytes",
	.Wrong_Magic      = "the record does not start with MACHINEK",
	.Wrong_Format     = "the record has another format number",
	.Other_Parameters = "the record names other parameters of Argon2id than 19456 KiB and 2 passes",
	.Bad_Name         = "",
	.Bytes_After_Name = "",
	.Bad_Area         = "",
}

// The record of a machine key sealed by the TPM: the object MACHINE_OBJECT
// in the store of `unlock`, as the record of the machine passphrase, with
// its own first 8 bytes
// (docs/PRINCIPALS.md, "The machine key sealed by the TPM").
// A machine has one machine key, so the object has one of the two forms.
// It holds:
//
// - the four parts of the sealed object that the TPM service gave: the two
//   areas, from which the TPM releases the machine key only while PCR 7
//   and PCR 11 hold the values of the seal; the creation data and the
//   creation ticket, with which the TPM proves at each unseal that it made
//   the object under the PCR values of its policy, so a record that another
//   system wrote is refused (tpm2.creation_data_pcr_digest);
// - the machine key sealed with ChaCha20-Poly1305 under the key of the
//   recovery key (recovery_seal_key), with the magic and the format as its
//   additional data: a new seal by the TPM changes the four parts and keeps
//   this copy, as the recovery key is not kept;
// - the key check (machine_key_check): the key that the TPM or the
//   recovery key gives must have it.
//
// The offsets, in bytes; each number is little-endian.
MACHINE_TPM_MAGIC :: "MACHINET" // The first 8 bytes of the record.
MACHINE_TPM_FORMAT :: u32(2) // A record of another format number is refused: format 1 had no proof of its creation.
MACHINE_TPM_PCRS :: tpm2.PCR_SET // The PCRs of the policy: PCR 7 and PCR 11, bit n for PCR n.
MACHINE_TPM_OFFSET_PCRS :: 12 // u32: the PCRs of the policy, bit n for PCR n.
MACHINE_TPM_OFFSET_SEALED_OBJECT :: 16 // The four parts of the sealed object: SEALED_OBJECT_SIZE bytes.
MACHINE_TPM_OFFSET_PUBLIC_BYTES :: MACHINE_TPM_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_PUBLIC_BYTES // 16: u16, the bytes of the public area.
MACHINE_TPM_OFFSET_PRIVATE_BYTES :: MACHINE_TPM_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_PRIVATE_BYTES // 18.
MACHINE_TPM_OFFSET_CREATION_BYTES :: MACHINE_TPM_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_CREATION_BYTES // 20.
MACHINE_TPM_OFFSET_TICKET_BYTES :: MACHINE_TPM_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_TICKET_BYTES // 22.
MACHINE_TPM_OFFSET_PUBLIC :: MACHINE_TPM_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_PUBLIC // 24.
MACHINE_TPM_PUBLIC_LIMIT :: tpm2.PUBLIC_AREA_LIMIT
MACHINE_TPM_OFFSET_PRIVATE :: MACHINE_TPM_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_PRIVATE // 152.
MACHINE_TPM_OFFSET_CREATION :: MACHINE_TPM_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_CREATION // 408.
MACHINE_TPM_OFFSET_TICKET :: MACHINE_TPM_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_TICKET // 664.
MACHINE_TPM_TICKET_LIMIT :: tpm2.CREATION_TICKET_LIMIT // 72: a digest of 64 bytes at most.
MACHINE_TPM_OFFSET_RECOVERY_NONCE :: MACHINE_TPM_OFFSET_SEALED_OBJECT + SEALED_OBJECT_SIZE // 736.
MACHINE_TPM_OFFSET_RECOVERY_SEALED :: MACHINE_TPM_OFFSET_RECOVERY_NONCE + NONCE_SIZE // 748: the machine key sealed under the recovery key, and the tag.
MACHINE_TPM_OFFSET_KEY_CHECK :: MACHINE_TPM_OFFSET_RECOVERY_SEALED + MACHINE_SEALED_SIZE // 796.
MACHINE_TPM_FILE_SIZE :: MACHINE_TPM_OFFSET_KEY_CHECK + KEY_SIZE // 828.
#assert(MACHINE_TPM_FILE_SIZE == 828)
// The additional data of the recovery seal: the magic and the format.
MACHINE_TPM_ADDITIONAL_SIZE :: MACHINE_TPM_OFFSET_PCRS

// The four parts of a sealed object that the TPM service gives, as a record
// keeps them: the two areas that TPM2_Load takes, and the creation data and
// the creation ticket that prove that the TPM made the object under the PCR
// values of its policy. The record of the machine key and the record of a
// named principal sealed by the TPM keep them in the same form.
Sealed_Object :: struct {
	public_bytes:    int,
	public_area:     [tpm2.PUBLIC_AREA_LIMIT]u8,
	private_bytes:   int,
	private_area:    [tpm2.PRIVATE_AREA_LIMIT]u8,
	creation_bytes:  int,
	creation_data:   [tpm2.CREATION_DATA_LIMIT]u8,
	ticket_bytes:    int,
	creation_ticket: [tpm2.CREATION_TICKET_LIMIT]u8,
}

// The places of the four parts in a record, from the start of the parts;
// each number is little-endian. Each part has its place at its limit, with
// zero bytes after it.
SEALED_OBJECT_OFFSET_PUBLIC_BYTES :: 0 // u16: the bytes of the public area.
SEALED_OBJECT_OFFSET_PRIVATE_BYTES :: 2 // u16: the bytes of the private area.
SEALED_OBJECT_OFFSET_CREATION_BYTES :: 4 // u16: the bytes of the creation data.
SEALED_OBJECT_OFFSET_TICKET_BYTES :: 6 // u16: the bytes of the creation ticket.
SEALED_OBJECT_OFFSET_PUBLIC :: 8 // The public area, with its size field.
SEALED_OBJECT_OFFSET_PRIVATE :: SEALED_OBJECT_OFFSET_PUBLIC + tpm2.PUBLIC_AREA_LIMIT // 136: the private area, with its size field.
SEALED_OBJECT_OFFSET_CREATION :: SEALED_OBJECT_OFFSET_PRIVATE + tpm2.PRIVATE_AREA_LIMIT // 392: the creation data, with its size field.
SEALED_OBJECT_OFFSET_TICKET :: SEALED_OBJECT_OFFSET_CREATION + tpm2.CREATION_DATA_LIMIT // 648: the creation ticket, whole.
SEALED_OBJECT_SIZE :: SEALED_OBJECT_OFFSET_TICKET + tpm2.CREATION_TICKET_LIMIT // 720.
#assert(SEALED_OBJECT_SIZE == 720)

// sealed_object_encode writes the four parts at their places. The caller
// took them from the TPM service, within their limits.
sealed_object_encode :: proc "contextless" (object: ^Sealed_Object, out: []u8) {
	public_bytes := clamp(object.public_bytes, 0, tpm2.PUBLIC_AREA_LIMIT)
	private_bytes := clamp(object.private_bytes, 0, tpm2.PRIVATE_AREA_LIMIT)
	creation_bytes := clamp(object.creation_bytes, 0, tpm2.CREATION_DATA_LIMIT)
	ticket_bytes := clamp(object.ticket_bytes, 0, tpm2.CREATION_TICKET_LIMIT)
	u16_put(out[SEALED_OBJECT_OFFSET_PUBLIC_BYTES:], u16(public_bytes))
	u16_put(out[SEALED_OBJECT_OFFSET_PRIVATE_BYTES:], u16(private_bytes))
	u16_put(out[SEALED_OBJECT_OFFSET_CREATION_BYTES:], u16(creation_bytes))
	u16_put(out[SEALED_OBJECT_OFFSET_TICKET_BYTES:], u16(ticket_bytes))
	copy(out[SEALED_OBJECT_OFFSET_PUBLIC:][:public_bytes], object.public_area[:public_bytes])
	copy(out[SEALED_OBJECT_OFFSET_PRIVATE:][:private_bytes], object.private_area[:private_bytes])
	copy(out[SEALED_OBJECT_OFFSET_CREATION:][:creation_bytes], object.creation_data[:creation_bytes])
	copy(out[SEALED_OBJECT_OFFSET_TICKET:][:ticket_bytes], object.creation_ticket[:ticket_bytes])
}

// sealed_object_decode reads the four parts of a copy of a record: each area
// must be a whole sized buffer of the TPM within its limit, the creation
// data must name PCR 7 and PCR 11 with a digest, the ticket must have its
// form, and each place has zero bytes after its part. It does not check the
// ticket: the TPM does.
sealed_object_decode :: proc "contextless" (parts: []u8) -> (object: Sealed_Object, ok: bool) {
	if len(parts) != SEALED_OBJECT_SIZE {
		return {}, false
	}
	public_bytes := int(u16_get(parts[SEALED_OBJECT_OFFSET_PUBLIC_BYTES:]))
	private_bytes := int(u16_get(parts[SEALED_OBJECT_OFFSET_PRIVATE_BYTES:]))
	creation_bytes := int(u16_get(parts[SEALED_OBJECT_OFFSET_CREATION_BYTES:]))
	ticket_bytes := int(u16_get(parts[SEALED_OBJECT_OFFSET_TICKET_BYTES:]))
	if public_bytes > tpm2.PUBLIC_AREA_LIMIT || private_bytes > tpm2.PRIVATE_AREA_LIMIT || creation_bytes > tpm2.CREATION_DATA_LIMIT || ticket_bytes > tpm2.CREATION_TICKET_LIMIT {
		return {}, false
	}
	public_place := parts[SEALED_OBJECT_OFFSET_PUBLIC:][:tpm2.PUBLIC_AREA_LIMIT]
	private_place := parts[SEALED_OBJECT_OFFSET_PRIVATE:][:tpm2.PRIVATE_AREA_LIMIT]
	creation_place := parts[SEALED_OBJECT_OFFSET_CREATION:][:tpm2.CREATION_DATA_LIMIT]
	ticket_place := parts[SEALED_OBJECT_OFFSET_TICKET:][:tpm2.CREATION_TICKET_LIMIT]
	if !tpm2.area_fits(public_place[:public_bytes], tpm2.PUBLIC_AREA_LIMIT) || !tpm2.area_fits(private_place[:private_bytes], tpm2.PRIVATE_AREA_LIMIT) || !tpm2.ticket_fits(ticket_place[:ticket_bytes]) {
		return {}, false
	}
	if _, named := tpm2.creation_data_pcr_digest(creation_place[:creation_bytes]); !named {
		return {}, false
	}
	if !zero_after(public_place, public_bytes) || !zero_after(private_place, private_bytes) || !zero_after(creation_place, creation_bytes) || !zero_after(ticket_place, ticket_bytes) {
		return {}, false
	}
	object.public_bytes, object.private_bytes = public_bytes, private_bytes
	object.creation_bytes, object.ticket_bytes = creation_bytes, ticket_bytes
	copy(object.public_area[:], public_place)
	copy(object.private_area[:], private_place)
	copy(object.creation_data[:], creation_place)
	copy(object.creation_ticket[:], ticket_place)
	return object, true
}

// The record of a machine key sealed by the TPM, decoded.
Machine_Tpm_File :: struct {
	pcrs:            u32, // The PCRs of the policy: tpm2.PCR_SET.
	using object:    Sealed_Object,
	recovery_nonce:  [NONCE_SIZE]u8, // The nonce of the recovery seal.
	recovery_sealed: [MACHINE_SEALED_SIZE]u8, // The machine key sealed under the key of the recovery key, and the tag.
	key_check:       [KEY_SIZE]u8, // machine_key_check of the machine key.
}

// zero_after says if each byte of a place after its part is zero.
@(private)
zero_after :: proc "contextless" (place: []u8, used: int) -> bool {
	for after in place[used:] {
		if after != 0 {
			return false
		}
	}
	return true
}

@(private)
u16_put :: proc "contextless" (bytes: []u8, value: u16) {
	bytes[0], bytes[1] = u8(value), u8(value >> 8)
}

@(private)
u16_get :: proc "contextless" (bytes: []u8) -> u16 {
	return u16(bytes[0]) | u16(bytes[1]) << 8
}

// machine_tpm_file_encode writes the bytes of the record. The caller took
// the four parts from the TPM service, within their limits.
machine_tpm_file_encode :: proc "contextless" (file: ^Machine_Tpm_File, out: ^[MACHINE_TPM_FILE_SIZE]u8) {
	out^ = {}
	copy(out^[MACHINE_OFFSET_MAGIC:][:8], MACHINE_TPM_MAGIC)
	u32_put(out^[MACHINE_OFFSET_FORMAT:], MACHINE_TPM_FORMAT)
	u32_put(out^[MACHINE_TPM_OFFSET_PCRS:], file.pcrs)
	sealed_object_encode(&file.object, out^[MACHINE_TPM_OFFSET_SEALED_OBJECT:][:SEALED_OBJECT_SIZE])
	copy(out^[MACHINE_TPM_OFFSET_RECOVERY_NONCE:][:NONCE_SIZE], file.recovery_nonce[:])
	copy(out^[MACHINE_TPM_OFFSET_RECOVERY_SEALED:][:MACHINE_SEALED_SIZE], file.recovery_sealed[:])
	copy(out^[MACHINE_TPM_OFFSET_KEY_CHECK:][:KEY_SIZE], file.key_check[:])
}

// machine_tpm_file_decode reads a record that the store gave. It copies the
// bytes once and checks the copy: the store is data from the disk. Each
// area must be a whole sized buffer of the TPM within its limit, the
// creation data must name PCR 7 and PCR 11 with a digest, the ticket must
// have its form, each part has zero bytes after it, and the PCRs must be
// PCR 7 and PCR 11: a record cannot name a weaker policy. It does not
// check the seals and the ticket: the TPM and the recovery key do.
machine_tpm_file_decode :: proc "contextless" (bytes: []u8) -> (file: Machine_Tpm_File, kept: [MACHINE_TPM_FILE_SIZE]u8, problem: File_Problem) {
	if len(bytes) != MACHINE_TPM_FILE_SIZE {
		return {}, {}, .Wrong_Size
	}
	copy(kept[:], bytes)
	if string(kept[MACHINE_OFFSET_MAGIC:][:8]) != MACHINE_TPM_MAGIC {
		return {}, {}, .Wrong_Magic
	}
	if u32_get(kept[MACHINE_OFFSET_FORMAT:]) != MACHINE_TPM_FORMAT {
		return {}, {}, .Wrong_Format
	}
	if u32_get(kept[MACHINE_TPM_OFFSET_PCRS:]) != tpm2.PCR_SET {
		return {}, {}, .Other_Parameters
	}
	object, object_ok := sealed_object_decode(kept[MACHINE_TPM_OFFSET_SEALED_OBJECT:][:SEALED_OBJECT_SIZE])
	if !object_ok {
		return {}, {}, .Bad_Area
	}
	file.pcrs = tpm2.PCR_SET
	file.object = object
	copy(file.recovery_nonce[:], kept[MACHINE_TPM_OFFSET_RECOVERY_NONCE:][:NONCE_SIZE])
	copy(file.recovery_sealed[:], kept[MACHINE_TPM_OFFSET_RECOVERY_SEALED:][:MACHINE_SEALED_SIZE])
	copy(file.key_check[:], kept[MACHINE_TPM_OFFSET_KEY_CHECK:][:KEY_SIZE])
	return file, kept, .None
}

// machine_tpm_file_additional_data gives the additional data of the
// recovery seal: the magic and the format only, so that a new seal by the
// TPM keeps the copy under the recovery key valid.
machine_tpm_file_additional_data :: proc "contextless" (bytes: ^[MACHINE_TPM_FILE_SIZE]u8) -> []u8 {
	return bytes^[:MACHINE_TPM_ADDITIONAL_SIZE]
}

// machine_tpm_file_problem_sentences gives the sentence of each problem of
// a record of a machine key sealed by the TPM, for the log of `unlock`.
@(rodata)
machine_tpm_file_problem_sentences := [File_Problem]string {
	.None             = "",
	.Wrong_Size       = "the record does not have 828 bytes",
	.Wrong_Magic      = "the record does not start with MACHINET",
	.Wrong_Format     = "the record has another format number",
	.Other_Parameters = "the record names other PCRs than PCR 7 and PCR 11",
	.Bad_Name         = "",
	.Bytes_After_Name = "",
	.Bad_Area         = "a part of the sealed object is not whole, or the creation data does not name PCR 7 and PCR 11, or a part has bytes that are not zero after it",
}

// The record of a machine key sealed by the TPM with the machine passphrase:
// the object MACHINE_OBJECT in the store of `unlock`, with its own first 8
// bytes (docs/PRINCIPALS.md, "The machine passphrase with the TPM";
// src/md/features/tpm_sealed_machine_passphrase.md). A machine with the TPM
// service and Secure Boot on gets this form when its machine passphrase is
// set. Its first 36 bytes have the form of the record under the machine
// passphrase alone, to the salt. Then it holds:
//
// - the four parts of a sealed object that the TPM service made with an
//   authorization value: the TPM secret, which the TPM releases only while
//   PCR 7 and PCR 11 hold the values of the seal, and only to the
//   authorization value that the machine passphrase gives
//   (machine_authorization_value); the TPM counts each wrong value;
// - the machine key sealed with ChaCha20-Poly1305 under the seal key, which
//   the TPM secret and the key of the passphrase give together
//   (machine_tpm_passphrase_seal_key); the additional data is each byte
//   before the PCRs;
// - the machine key sealed under the key of the recovery key
//   (recovery_seal_key); the additional data is each byte before the salt,
//   so a new passphrase after a recovery keeps this copy valid.
//
// It has no key check: each copy opens only under its authenticated seal.
// The offsets, in bytes; each number is little-endian.
MACHINE_TPM_PASSPHRASE_MAGIC :: "MACHINEP" // The first 8 bytes of the record.
MACHINE_TPM_PASSPHRASE_FORMAT :: u32(1) // A record of another format number is refused.
MACHINE_TPM_PASSPHRASE_PCRS :: tpm2.PCR_SET // The PCRs of the policy: PCR 7 and PCR 11, bit n for PCR n.
MACHINE_TPM_PASSPHRASE_OFFSET_PCRS :: MACHINE_OFFSET_NONCE // 36: u32, the PCRs of the policy, bit n for PCR n.
MACHINE_TPM_PASSPHRASE_OFFSET_SEALED_OBJECT :: MACHINE_TPM_PASSPHRASE_OFFSET_PCRS + 4 // 40: SEALED_OBJECT_SIZE bytes.
MACHINE_TPM_PASSPHRASE_OFFSET_NONCE :: MACHINE_TPM_PASSPHRASE_OFFSET_SEALED_OBJECT + SEALED_OBJECT_SIZE // 760: the nonce of the seal under the seal key.
MACHINE_TPM_PASSPHRASE_OFFSET_SEALED :: MACHINE_TPM_PASSPHRASE_OFFSET_NONCE + NONCE_SIZE // 772: the machine key under the seal key, and the tag.
MACHINE_TPM_PASSPHRASE_OFFSET_RECOVERY_NONCE :: MACHINE_TPM_PASSPHRASE_OFFSET_SEALED + MACHINE_SEALED_SIZE // 820.
MACHINE_TPM_PASSPHRASE_OFFSET_RECOVERY_SEALED :: MACHINE_TPM_PASSPHRASE_OFFSET_RECOVERY_NONCE + NONCE_SIZE // 832: the machine key under the recovery key, and the tag.
MACHINE_TPM_PASSPHRASE_FILE_SIZE :: MACHINE_TPM_PASSPHRASE_OFFSET_RECOVERY_SEALED + MACHINE_SEALED_SIZE // 880.
#assert(MACHINE_TPM_PASSPHRASE_FILE_SIZE == 880)
// The bytes that each seal covers and does not seal.
MACHINE_TPM_PASSPHRASE_ADDITIONAL_SIZE :: MACHINE_TPM_PASSPHRASE_OFFSET_PCRS // The seal under the seal key: to the salt.
MACHINE_TPM_PASSPHRASE_RECOVERY_ADDITIONAL_SIZE :: MACHINE_OFFSET_SALT // The recovery seal: the magic, the format and the parameters.
// The largest of the three forms of the record: the read of `unlock` takes
// each one.
MACHINE_RECORD_LIMIT :: max(MACHINE_FILE_SIZE, MACHINE_TPM_FILE_SIZE, MACHINE_TPM_PASSPHRASE_FILE_SIZE)

// The record of a machine key sealed by the TPM with the machine
// passphrase, decoded.
Machine_Tpm_Passphrase_File :: struct {
	salt:            [SALT_SIZE]u8, // The salt of Argon2id: the key of the passphrase.
	pcrs:            u32, // The PCRs of the policy: tpm2.PCR_SET.
	using object:    Sealed_Object, // Made with the authorization value of the machine passphrase.
	nonce:           [NONCE_SIZE]u8, // The nonce of the seal under the seal key.
	sealed:          [MACHINE_SEALED_SIZE]u8, // The machine key under the seal key, and the tag.
	recovery_nonce:  [NONCE_SIZE]u8,
	recovery_sealed: [MACHINE_SEALED_SIZE]u8, // The machine key under the key of the recovery key, and the tag.
}

// machine_tpm_passphrase_file_encode writes the bytes of the record. The
// caller took the four parts from the TPM service, within their limits.
machine_tpm_passphrase_file_encode :: proc "contextless" (file: ^Machine_Tpm_Passphrase_File, out: ^[MACHINE_TPM_PASSPHRASE_FILE_SIZE]u8) {
	out^ = {}
	copy(out^[MACHINE_OFFSET_MAGIC:][:8], MACHINE_TPM_PASSPHRASE_MAGIC)
	u32_put(out^[MACHINE_OFFSET_FORMAT:], MACHINE_TPM_PASSPHRASE_FORMAT)
	u32_put(out^[MACHINE_OFFSET_MEMORY:], DERIVATION_MEMORY_KIBIBYTES)
	u32_put(out^[MACHINE_OFFSET_PASSES:], DERIVATION_PASSES)
	copy(out^[MACHINE_OFFSET_SALT:][:SALT_SIZE], file.salt[:])
	u32_put(out^[MACHINE_TPM_PASSPHRASE_OFFSET_PCRS:], file.pcrs)
	sealed_object_encode(&file.object, out^[MACHINE_TPM_PASSPHRASE_OFFSET_SEALED_OBJECT:][:SEALED_OBJECT_SIZE])
	copy(out^[MACHINE_TPM_PASSPHRASE_OFFSET_NONCE:][:NONCE_SIZE], file.nonce[:])
	copy(out^[MACHINE_TPM_PASSPHRASE_OFFSET_SEALED:][:MACHINE_SEALED_SIZE], file.sealed[:])
	copy(out^[MACHINE_TPM_PASSPHRASE_OFFSET_RECOVERY_NONCE:][:NONCE_SIZE], file.recovery_nonce[:])
	copy(out^[MACHINE_TPM_PASSPHRASE_OFFSET_RECOVERY_SEALED:][:MACHINE_SEALED_SIZE], file.recovery_sealed[:])
}

// machine_tpm_passphrase_file_decode reads a record that the store gave. It
// copies the bytes once and checks the copy, as the other forms do: the
// parameters of Argon2id, the PCRs, which must be PCR 7 and PCR 11 so a
// record cannot name a weaker policy, and the four parts of the sealed
// object. It does not check the seals and the ticket: the TPM, the machine
// passphrase and the recovery key do.
machine_tpm_passphrase_file_decode :: proc "contextless" (bytes: []u8) -> (file: Machine_Tpm_Passphrase_File, kept: [MACHINE_TPM_PASSPHRASE_FILE_SIZE]u8, problem: File_Problem) {
	if len(bytes) != MACHINE_TPM_PASSPHRASE_FILE_SIZE {
		return {}, {}, .Wrong_Size
	}
	copy(kept[:], bytes)
	if string(kept[MACHINE_OFFSET_MAGIC:][:8]) != MACHINE_TPM_PASSPHRASE_MAGIC {
		return {}, {}, .Wrong_Magic
	}
	if u32_get(kept[MACHINE_OFFSET_FORMAT:]) != MACHINE_TPM_PASSPHRASE_FORMAT {
		return {}, {}, .Wrong_Format
	}
	if u32_get(kept[MACHINE_OFFSET_MEMORY:]) != DERIVATION_MEMORY_KIBIBYTES || u32_get(kept[MACHINE_OFFSET_PASSES:]) != DERIVATION_PASSES || u32_get(kept[MACHINE_TPM_PASSPHRASE_OFFSET_PCRS:]) != tpm2.PCR_SET {
		return {}, {}, .Other_Parameters
	}
	object, object_ok := sealed_object_decode(kept[MACHINE_TPM_PASSPHRASE_OFFSET_SEALED_OBJECT:][:SEALED_OBJECT_SIZE])
	if !object_ok {
		return {}, {}, .Bad_Area
	}
	copy(file.salt[:], kept[MACHINE_OFFSET_SALT:][:SALT_SIZE])
	file.pcrs = tpm2.PCR_SET
	file.object = object
	copy(file.nonce[:], kept[MACHINE_TPM_PASSPHRASE_OFFSET_NONCE:][:NONCE_SIZE])
	copy(file.sealed[:], kept[MACHINE_TPM_PASSPHRASE_OFFSET_SEALED:][:MACHINE_SEALED_SIZE])
	copy(file.recovery_nonce[:], kept[MACHINE_TPM_PASSPHRASE_OFFSET_RECOVERY_NONCE:][:NONCE_SIZE])
	copy(file.recovery_sealed[:], kept[MACHINE_TPM_PASSPHRASE_OFFSET_RECOVERY_SEALED:][:MACHINE_SEALED_SIZE])
	return file, kept, .None
}

// machine_tpm_passphrase_file_additional_data gives the additional data of
// the seal under the seal key: each byte before the PCRs.
machine_tpm_passphrase_file_additional_data :: proc "contextless" (bytes: ^[MACHINE_TPM_PASSPHRASE_FILE_SIZE]u8) -> []u8 {
	return bytes^[:MACHINE_TPM_PASSPHRASE_ADDITIONAL_SIZE]
}

// machine_tpm_passphrase_file_recovery_additional_data gives the additional
// data of the recovery seal: each byte before the salt, so that a new
// passphrase, which has a new salt, keeps the copy under the recovery key
// valid.
machine_tpm_passphrase_file_recovery_additional_data :: proc "contextless" (bytes: ^[MACHINE_TPM_PASSPHRASE_FILE_SIZE]u8) -> []u8 {
	return bytes^[:MACHINE_TPM_PASSPHRASE_RECOVERY_ADDITIONAL_SIZE]
}

// machine_tpm_passphrase_file_problem_sentences gives the sentence of each
// problem of a record sealed by the TPM with the machine passphrase, for the
// log of `unlock`.
@(rodata)
machine_tpm_passphrase_file_problem_sentences := [File_Problem]string {
	.None             = "",
	.Wrong_Size       = "the record does not have 880 bytes",
	.Wrong_Magic      = "the record does not start with MACHINEP",
	.Wrong_Format     = "the record has another format number",
	.Other_Parameters = "the record names other parameters of Argon2id than 19456 KiB and 2 passes, or other PCRs than PCR 7 and PCR 11",
	.Bad_Name         = "",
	.Bytes_After_Name = "",
	.Bad_Area         = "a part of the sealed object is not whole, or the creation data does not name PCR 7 and PCR 11, or a part has bytes that are not zero after it",
}

// The texts of the keyed hashes of the machine passphrase with the TPM:
// each differs from the text of a named principal, so a value or a seal key
// of the machine is never one of a principal, for the same passphrase too.
MACHINE_AUTHORIZATION_TEXT :: "modus authorization value of the machine key"
MACHINE_TPM_PASSPHRASE_SEAL_TEXT :: "modus seal by the TPM of the machine key under the machine passphrase"

// machine_authorization_value gives the authorization value of the sealed
// object of the record MACHINE_TPM_PASSPHRASE_MAGIC: keyed BLAKE2b of the
// key that Argon2id derives from the machine passphrase. It crosses the
// interface of the TPM in clear; a reader of it must still run Argon2id for
// each guess of the passphrase.
machine_authorization_value :: proc "contextless" (passphrase_key: ^[KEY_SIZE]u8) -> [tpm2.AUTHORIZATION_VALUE_SIZE]u8 {
	return keyed_hash(passphrase_key^[:], MACHINE_AUTHORIZATION_TEXT)
}

// machine_tpm_passphrase_seal_key gives the seal key of the machine key in
// the record MACHINE_TPM_PASSPHRASE_MAGIC: keyed BLAKE2b of the TPM secret
// over the key of the passphrase and a text. So the key needs the TPM and
// the passphrase together.
machine_tpm_passphrase_seal_key :: proc "contextless" (tpm_secret: ^[TPM_SECRET_SIZE]u8, passphrase_key: ^[KEY_SIZE]u8) -> [KEY_SIZE]u8 {
	return tpm_and_passphrase_key(tpm_secret, passphrase_key, MACHINE_TPM_PASSPHRASE_SEAL_TEXT)
}

// The three forms of the object MACHINE_OBJECT, by its first 8 bytes.
Machine_Record_Form :: enum u8 {
	Unknown, // No known magic: the record cannot be read.
	Passphrase, // MACHINE_MAGIC: the machine key under the machine passphrase alone.
	Sealed_By_The_Tpm, // MACHINE_TPM_MAGIC: the machine key sealed by the TPM, with its recovery key.
	Sealed_By_The_Tpm_With_Passphrase, // MACHINE_TPM_PASSPHRASE_MAGIC: the machine key sealed by the TPM with the machine passphrase, and its recovery key.
}

// machine_record_form gives the form of a record of the machine from its
// first 8 bytes.
machine_record_form :: proc "contextless" (bytes: []u8) -> Machine_Record_Form {
	if len(bytes) < 8 {
		return .Unknown
	}
	switch string(bytes[:8]) {
	case MACHINE_MAGIC:
		return .Passphrase
	case MACHINE_TPM_MAGIC:
		return .Sealed_By_The_Tpm
	case MACHINE_TPM_PASSPHRASE_MAGIC:
		return .Sealed_By_The_Tpm_With_Passphrase
	}
	return .Unknown
}

// The recovery key: 20 random bytes (160 bits), shown one time as 32
// characters of base32 (RFC 4648) in 8 groups of 4, separated by '-'. It
// opens the copy of the machine key when the TPM refuses: after an update
// of the system, on another machine, or with no TPM. 160 random bits need
// no slow derivation: a guess costs the attacker as much as a guess of the
// key itself.
RECOVERY_KEY_SIZE :: 20
RECOVERY_SYMBOLS :: 32 // The symbols of base32 of a recovery key.
RECOVERY_TEXT_SIZE :: RECOVERY_SYMBOLS + RECOVERY_SYMBOLS / 4 - 1 // 39: the symbols and 7 separators.
// The texts of the two keyed hashes: each use of a key has a text of its own.
RECOVERY_SEAL_TEXT :: "modus recovery key of the machine key"
MACHINE_KEY_CHECK_TEXT :: "modus check of the machine key"
BASE32_ALPHABET :: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

// Why a typed recovery key is refused: the result of recovery_key_parse.
Recovery_Problem :: enum u8 {
	None, // The text gives a key.
	Bad_Character, // A character that is not a letter, a digit 2 to 7, '-' or a space.
	Wrong_Length, // Not 32 symbols.
}

// The sentence of each problem of a typed recovery key, for the window of
// `unlock`.
@(rodata)
recovery_problem_sentences := [Recovery_Problem]string {
	.None          = "",
	.Bad_Character = "a recovery key has the letters A to Z and the digits 2 to 7 only",
	.Wrong_Length  = "a recovery key has 32 letters and digits",
}

// recovery_key_text writes the recovery key as its user reads it: 8 groups
// of 4 symbols of base32, separated by '-'.
recovery_key_text :: proc "contextless" (key: ^[RECOVERY_KEY_SIZE]u8) -> (text: [RECOVERY_TEXT_SIZE]u8) {
	alphabet: string = BASE32_ALPHABET
	symbol, place := 0, 0
	for group in 0 ..< RECOVERY_KEY_SIZE / 5 {
		// 5 bytes give 8 symbols of 5 bits.
		bits: u64
		for index in 0 ..< 5 {
			bits = bits << 8 | u64(key[group * 5 + index])
		}
		for shift := 35; shift >= 0; shift -= 5 {
			if symbol > 0 && symbol % 4 == 0 {
				text[place] = '-'
				place += 1
			}
			text[place] = alphabet[int((bits >> uint(shift)) & 31)]
			place += 1
			symbol += 1
		}
	}
	return text
}

// recovery_key_parse reads a typed recovery key: 32 symbols of base32, in
// upper or lower case, with any '-' and spaces between them.
recovery_key_parse :: proc "contextless" (typed: []u8) -> (key: [RECOVERY_KEY_SIZE]u8, problem: Recovery_Problem) {
	bits: u64
	bit_count: uint
	symbols, written := 0, 0
	for character in typed {
		value: u64
		switch character {
		case 'A' ..= 'Z':
			value = u64(character - 'A')
		case 'a' ..= 'z':
			value = u64(character - 'a')
		case '2' ..= '7':
			value = u64(character - '2') + 26
		case '-', ' ':
			continue
		case:
			return {}, .Bad_Character
		}
		if symbols == RECOVERY_SYMBOLS {
			return {}, .Wrong_Length
		}
		symbols += 1
		bits = bits << 5 | value
		bit_count += 5
		if bit_count >= 8 {
			bit_count -= 8
			key[written] = u8(bits >> bit_count)
			written += 1
			bits &= (u64(1) << bit_count) - 1
		}
	}
	if symbols != RECOVERY_SYMBOLS {
		return {}, .Wrong_Length
	}
	return key, .None
}

// keyed_hash gives keyed BLAKE2b of a key over a text: a pseudorandom
// function, so the result reveals nothing of the key.
@(private)
keyed_hash :: proc "contextless" (key: []u8, text: string) -> (result: [KEY_SIZE]u8) {
	context_of_the_hash: blake2.Blake2b_Context
	configuration := blake2.Blake2_Config {
		size = KEY_SIZE,
		key  = key,
	}
	blake2.init(&context_of_the_hash, &configuration)
	blake2.update(&context_of_the_hash, transmute([]u8)text)
	blake2.final(&context_of_the_hash, result[:])
	return result
}

// recovery_seal_key gives the key of the recovery seal: keyed BLAKE2b of
// the recovery key over RECOVERY_SEAL_TEXT.
recovery_seal_key :: proc "contextless" (recovery_key: ^[RECOVERY_KEY_SIZE]u8) -> [KEY_SIZE]u8 {
	return keyed_hash(recovery_key^[:], RECOVERY_SEAL_TEXT)
}

// machine_key_check gives the key check of a machine key: keyed BLAKE2b of
// the machine key over MACHINE_KEY_CHECK_TEXT. A key that the TPM service
// or the recovery key gives must have the check of the record: a record
// whose areas come from another record, or a service that gives another
// key, gives a key that does not pass.
machine_key_check :: proc "contextless" (machine_key: ^[MACHINE_KEY_SIZE]u8) -> [KEY_SIZE]u8 {
	return keyed_hash(machine_key^[:], MACHINE_KEY_CHECK_TEXT)
}

// The file of a named principal whose keys the TPM seals
// (docs/PRINCIPALS.md, "The keys sealed by the TPM";
// src/md/features/tpm_sealed_principal_keys.md): the object FILE_OBJECT
// of the store of `unlock`, as the file under the passphrase alone, with its
// own first 8 bytes. A machine has one named principal, so the object has
// one of the two forms. Its first 124 bytes have the form of the file under
// the passphrase alone, to the salt. Then it holds:
//
// - the four parts of a sealed object that the TPM service made with an
//   authorization value: the TPM secret, 32 random bytes, which the TPM
//   releases only while PCR 7 and PCR 11 hold the values of the seal, and
//   only to the authorization value that the passphrase gives; the TPM
//   counts each wrong value;
// - the two secret keys sealed with ChaCha20-Poly1305 under the seal key,
//   which the TPM secret and the key of the passphrase give together
//   (principal_tpm_seal_key); the additional data is each byte before the
//   PCRs: the name, the public keys, the parameters and the salt;
// - the two secret keys sealed under the key of the recovery key
//   (principal_recovery_seal_key); the additional data is each byte before
//   the salt, so a new passphrase after a recovery keeps this copy valid.
//
// The offsets, in bytes; each number is little-endian.
PRINCIPAL_TPM_MAGIC :: "PRINCIPT" // The first 8 bytes of the file.
PRINCIPAL_TPM_FORMAT :: u32(1) // A file of another format number is refused.
TPM_SECRET_SIZE :: 32 // The bytes of the TPM secret: the secret that the TPM service seals with an authorization value, here and in the form MACHINE_TPM_PASSPHRASE_MAGIC.
PRINCIPAL_TPM_PCRS :: tpm2.PCR_SET // The PCRs of the policy: PCR 7 and PCR 11, bit n for PCR n.
PRINCIPAL_TPM_OFFSET_PCRS :: OFFSET_NONCE // 124: u32, the PCRs of the policy, bit n for PCR n.
PRINCIPAL_TPM_OFFSET_SEALED_OBJECT :: PRINCIPAL_TPM_OFFSET_PCRS + 4 // 128: SEALED_OBJECT_SIZE bytes.
PRINCIPAL_TPM_OFFSET_NONCE :: PRINCIPAL_TPM_OFFSET_SEALED_OBJECT + SEALED_OBJECT_SIZE // 848: the nonce of the seal under the seal key.
PRINCIPAL_TPM_OFFSET_SEALED :: PRINCIPAL_TPM_OFFSET_NONCE + NONCE_SIZE // 860: the two secret keys and the tag.
PRINCIPAL_TPM_OFFSET_RECOVERY_NONCE :: PRINCIPAL_TPM_OFFSET_SEALED + SEALED_SIZE // 940.
PRINCIPAL_TPM_OFFSET_RECOVERY_SEALED :: PRINCIPAL_TPM_OFFSET_RECOVERY_NONCE + NONCE_SIZE // 952: the two secret keys under the recovery key, and the tag.
PRINCIPAL_TPM_FILE_SIZE :: PRINCIPAL_TPM_OFFSET_RECOVERY_SEALED + SEALED_SIZE // 1032.
#assert(PRINCIPAL_TPM_FILE_SIZE == 1032)
// The bytes that each seal covers and does not seal.
PRINCIPAL_TPM_ADDITIONAL_SIZE :: PRINCIPAL_TPM_OFFSET_PCRS // The seal under the seal key: to the salt.
PRINCIPAL_TPM_RECOVERY_ADDITIONAL_SIZE :: OFFSET_SALT // The recovery seal: to the public keys.
// The largest of the two forms of the file: the read of `unlock` takes
// either one.
PRINCIPAL_FILE_LIMIT :: max(FILE_SIZE, PRINCIPAL_TPM_FILE_SIZE)

// The file of a named principal sealed by the TPM, decoded.
Principal_Tpm_File :: struct {
	name:               [NAME_LIMIT]u8,
	name_length:        int,
	signing_public_key: [PUBLIC_KEY_SIZE]u8,
	unlock_public_key:  [PUBLIC_KEY_SIZE]u8,
	salt:               [SALT_SIZE]u8, // The salt of Argon2id: the key of the passphrase.
	pcrs:               u32, // The PCRs of the policy: tpm2.PCR_SET.
	using object:       Sealed_Object, // Made with the authorization value of the passphrase.
	nonce:              [NONCE_SIZE]u8, // The nonce of the seal under the seal key.
	sealed:             [SEALED_SIZE]u8, // The two secret keys under the seal key, and the tag.
	recovery_nonce:     [NONCE_SIZE]u8,
	recovery_sealed:    [SEALED_SIZE]u8, // The two secret keys under the key of the recovery key, and the tag.
}

// principal_tpm_file_encode writes the bytes of the file. The caller
// checked the name, and took the four parts from the TPM service.
principal_tpm_file_encode :: proc "contextless" (file: ^Principal_Tpm_File, out: ^[PRINCIPAL_TPM_FILE_SIZE]u8) {
	out^ = {}
	copy(out^[OFFSET_MAGIC:][:8], PRINCIPAL_TPM_MAGIC)
	u32_put(out^[OFFSET_FORMAT:], PRINCIPAL_TPM_FORMAT)
	u32_put(out^[OFFSET_MEMORY:], DERIVATION_MEMORY_KIBIBYTES)
	u32_put(out^[OFFSET_PASSES:], DERIVATION_PASSES)
	length := clamp(file.name_length, 0, NAME_LIMIT)
	out^[OFFSET_NAME_LENGTH] = u8(length)
	copy(out^[OFFSET_NAME:][:length], file.name[:length])
	copy(out^[OFFSET_SIGNING_PUBLIC_KEY:][:PUBLIC_KEY_SIZE], file.signing_public_key[:])
	copy(out^[OFFSET_UNLOCK_PUBLIC_KEY:][:PUBLIC_KEY_SIZE], file.unlock_public_key[:])
	copy(out^[OFFSET_SALT:][:SALT_SIZE], file.salt[:])
	u32_put(out^[PRINCIPAL_TPM_OFFSET_PCRS:], file.pcrs)
	sealed_object_encode(&file.object, out^[PRINCIPAL_TPM_OFFSET_SEALED_OBJECT:][:SEALED_OBJECT_SIZE])
	copy(out^[PRINCIPAL_TPM_OFFSET_NONCE:][:NONCE_SIZE], file.nonce[:])
	copy(out^[PRINCIPAL_TPM_OFFSET_SEALED:][:SEALED_SIZE], file.sealed[:])
	copy(out^[PRINCIPAL_TPM_OFFSET_RECOVERY_NONCE:][:NONCE_SIZE], file.recovery_nonce[:])
	copy(out^[PRINCIPAL_TPM_OFFSET_RECOVERY_SEALED:][:SEALED_SIZE], file.recovery_sealed[:])
}

// principal_tpm_file_decode reads a file that the store gave. It copies the
// bytes once and checks the copy, as file_decode does, and the four parts
// as the record of the machine key: the PCRs must be PCR 7 and PCR 11, so a
// file cannot name a weaker policy. It does not check the seals and the
// ticket: the TPM, the passphrase and the recovery key do.
principal_tpm_file_decode :: proc "contextless" (bytes: []u8) -> (file: Principal_Tpm_File, kept: [PRINCIPAL_TPM_FILE_SIZE]u8, problem: File_Problem) {
	if len(bytes) != PRINCIPAL_TPM_FILE_SIZE {
		return {}, {}, .Wrong_Size
	}
	copy(kept[:], bytes)
	if string(kept[OFFSET_MAGIC:][:8]) != PRINCIPAL_TPM_MAGIC {
		return {}, {}, .Wrong_Magic
	}
	if u32_get(kept[OFFSET_FORMAT:]) != PRINCIPAL_TPM_FORMAT {
		return {}, {}, .Wrong_Format
	}
	if u32_get(kept[OFFSET_MEMORY:]) != DERIVATION_MEMORY_KIBIBYTES || u32_get(kept[OFFSET_PASSES:]) != DERIVATION_PASSES || u32_get(kept[PRINCIPAL_TPM_OFFSET_PCRS:]) != tpm2.PCR_SET {
		return {}, {}, .Other_Parameters
	}
	length := int(kept[OFFSET_NAME_LENGTH])
	if length > NAME_LIMIT || name_problem(string(kept[OFFSET_NAME:][:length])) != .None {
		return {}, {}, .Bad_Name
	}
	if !zero_after(kept[OFFSET_NAME:OFFSET_SIGNING_PUBLIC_KEY], length) {
		return {}, {}, .Bytes_After_Name
	}
	object, object_ok := sealed_object_decode(kept[PRINCIPAL_TPM_OFFSET_SEALED_OBJECT:][:SEALED_OBJECT_SIZE])
	if !object_ok {
		return {}, {}, .Bad_Area
	}
	file.name_length = length
	copy(file.name[:], kept[OFFSET_NAME:][:length])
	copy(file.signing_public_key[:], kept[OFFSET_SIGNING_PUBLIC_KEY:][:PUBLIC_KEY_SIZE])
	copy(file.unlock_public_key[:], kept[OFFSET_UNLOCK_PUBLIC_KEY:][:PUBLIC_KEY_SIZE])
	copy(file.salt[:], kept[OFFSET_SALT:][:SALT_SIZE])
	file.pcrs = tpm2.PCR_SET
	file.object = object
	copy(file.nonce[:], kept[PRINCIPAL_TPM_OFFSET_NONCE:][:NONCE_SIZE])
	copy(file.sealed[:], kept[PRINCIPAL_TPM_OFFSET_SEALED:][:SEALED_SIZE])
	copy(file.recovery_nonce[:], kept[PRINCIPAL_TPM_OFFSET_RECOVERY_NONCE:][:NONCE_SIZE])
	copy(file.recovery_sealed[:], kept[PRINCIPAL_TPM_OFFSET_RECOVERY_SEALED:][:SEALED_SIZE])
	return file, kept, .None
}

// principal_tpm_file_additional_data gives the additional data of the seal
// under the seal key: each byte before the PCRs.
principal_tpm_file_additional_data :: proc "contextless" (bytes: ^[PRINCIPAL_TPM_FILE_SIZE]u8) -> []u8 {
	return bytes^[:PRINCIPAL_TPM_ADDITIONAL_SIZE]
}

// principal_tpm_file_recovery_additional_data gives the additional data of
// the recovery seal: each byte before the salt, so that a new passphrase,
// which has a new salt, keeps the copy under the recovery key valid.
principal_tpm_file_recovery_additional_data :: proc "contextless" (bytes: ^[PRINCIPAL_TPM_FILE_SIZE]u8) -> []u8 {
	return bytes^[:PRINCIPAL_TPM_RECOVERY_ADDITIONAL_SIZE]
}

// principal_tpm_file_problem_sentences gives the sentence of each problem
// of a file sealed by the TPM, for the log of `unlock`.
@(rodata)
principal_tpm_file_problem_sentences := [File_Problem]string {
	.None             = "",
	.Wrong_Size       = "the file does not have 1032 bytes",
	.Wrong_Magic      = "the file does not start with PRINCIPT",
	.Wrong_Format     = "the file has another format number",
	.Other_Parameters = "the file names other parameters of Argon2id than 19456 KiB and 2 passes, or other PCRs than PCR 7 and PCR 11",
	.Bad_Name         = "the name in the file is not a name of a principal",
	.Bytes_After_Name = "the file has bytes that are not zero after the name",
	.Bad_Area         = "a part of the sealed object is not whole, or the creation data does not name PCR 7 and PCR 11, or a part has bytes that are not zero after it",
}

// The two forms of the object FILE_OBJECT, by its first 8 bytes.
Principal_Record_Form :: enum u8 {
	Unknown, // Neither magic: the file cannot be read.
	Passphrase, // FILE_MAGIC: the keys under the passphrase alone.
	Sealed_By_The_Tpm, // PRINCIPAL_TPM_MAGIC: the keys sealed by the TPM with the passphrase, and the recovery key.
}

// principal_record_form gives the form of a file of a named principal from
// its first 8 bytes.
principal_record_form :: proc "contextless" (bytes: []u8) -> Principal_Record_Form {
	if len(bytes) < 8 {
		return .Unknown
	}
	switch string(bytes[:8]) {
	case FILE_MAGIC:
		return .Passphrase
	case PRINCIPAL_TPM_MAGIC:
		return .Sealed_By_The_Tpm
	}
	return .Unknown
}

// The texts of the keyed hashes of a named principal: each use of a key has
// a text of its own.
PRINCIPAL_AUTHORIZATION_TEXT :: "modus authorization value of a named principal"
PRINCIPAL_TPM_SEAL_TEXT :: "modus seal by the TPM of the keys of a named principal"
PRINCIPAL_RECOVERY_SEAL_TEXT :: "modus recovery key of a named principal"

// principal_authorization_value gives the authorization value of the
// sealed object: keyed BLAKE2b of the key that Argon2id derives from the
// passphrase. It crosses the interface of the TPM in clear; a reader of it
// must still run Argon2id for each guess of the passphrase.
principal_authorization_value :: proc "contextless" (passphrase_key: ^[KEY_SIZE]u8) -> [tpm2.AUTHORIZATION_VALUE_SIZE]u8 {
	return keyed_hash(passphrase_key^[:], PRINCIPAL_AUTHORIZATION_TEXT)
}

// principal_tpm_seal_key gives the seal key of the secret keys: keyed
// BLAKE2b of the TPM secret over the key of the passphrase and a text. So
// the keys need the TPM and the passphrase together: a reader of the TPM
// secret, on the bus of a hardware TPM, still runs Argon2id for each guess.
principal_tpm_seal_key :: proc "contextless" (tpm_secret: ^[TPM_SECRET_SIZE]u8, passphrase_key: ^[KEY_SIZE]u8) -> [KEY_SIZE]u8 {
	return tpm_and_passphrase_key(tpm_secret, passphrase_key, PRINCIPAL_TPM_SEAL_TEXT)
}

// tpm_and_passphrase_key gives keyed BLAKE2b of a TPM secret over the key of
// a passphrase and a text: the seal key of a record that needs the TPM and
// the passphrase together. Each use has its own text.
@(private)
tpm_and_passphrase_key :: proc "contextless" (tpm_secret: ^[TPM_SECRET_SIZE]u8, passphrase_key: ^[KEY_SIZE]u8, text: string) -> (result: [KEY_SIZE]u8) {
	context_of_the_hash: blake2.Blake2b_Context
	configuration := blake2.Blake2_Config {
		size = KEY_SIZE,
		key  = tpm_secret^[:],
	}
	blake2.init(&context_of_the_hash, &configuration)
	blake2.update(&context_of_the_hash, passphrase_key^[:])
	blake2.update(&context_of_the_hash, transmute([]u8)text)
	blake2.final(&context_of_the_hash, result[:])
	return result
}

// principal_recovery_seal_key gives the key of the recovery seal of a named
// principal: keyed BLAKE2b of the recovery key over
// PRINCIPAL_RECOVERY_SEAL_TEXT.
principal_recovery_seal_key :: proc "contextless" (recovery_key: ^[RECOVERY_KEY_SIZE]u8) -> [KEY_SIZE]u8 {
	return keyed_hash(recovery_key^[:], PRINCIPAL_RECOVERY_SEAL_TEXT)
}
