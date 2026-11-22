// The contents of two TPM indices that pin state which the disk alone
// cannot be trusted to keep: the form of the record of the machine key, and
// the digest of the current file of each named principal
// (src/md/features/tpm_sealed_machine_key.md, "The form of the record is not pinned";
// src/md/features/tpm_sealed_principal_keys.md, "The pin of the file").
//
// A copy of the disk can bring back an older record or an older file. A
// value in the TPM that only this system writes says which one is current,
// and a number in it that only rises makes an older value refused too.
//
// Each payload has a fixed size, big-endian numbers, a magic, a format and
// a checksum under a text of its own. The checksum finds a damaged or
// partly written index; it proves no origin: the policy of the index
// decides who writes it.
package tpm_attestation

import "modus:contract/byte_order"
import "modus:contract/enum_word"

// The format of both payloads. A new layout is a new format, refused by a
// reader of this one.
PIN_RECORD_FORMAT :: u16(1)

// The magics of the two payloads, and the texts of their checksums. Two
// texts keep a payload of one kind from passing the checksum of the other.
MACHINE_KEY_PIN_MAGIC :: "MODUSMKP"
MACHINE_KEY_PIN_DOMAIN :: "MODUS_MACHINE_KEY_PIN_V1"
PRINCIPAL_FILE_PIN_MAGIC :: "MODUSPFP"
PRINCIPAL_FILE_PIN_DOMAIN :: "MODUS_PRINCIPAL_FILE_PIN_V1"

// The bytes of the first word of a record of the machine key: its magic,
// which names its form.
MACHINE_KEY_RECORD_MAGIC_SIZE :: 8

// The layout of the payload of the machine key pin.
MACHINE_KEY_PIN_OFFSET_MAGIC :: 0
MACHINE_KEY_PIN_OFFSET_FORMAT :: 8
MACHINE_KEY_PIN_OFFSET_FORM :: 10
MACHINE_KEY_PIN_OFFSET_RESERVED :: 11
MACHINE_KEY_PIN_OFFSET_EPOCH :: 12
MACHINE_KEY_PIN_OFFSET_CHECKSUM :: 20
MACHINE_KEY_PIN_RECORD_SIZE :: MACHINE_KEY_PIN_OFFSET_CHECKSUM + SHA256_SIZE

// The layout of the payload of a principal file pin.
PRINCIPAL_FILE_PIN_OFFSET_MAGIC :: 0
PRINCIPAL_FILE_PIN_OFFSET_FORMAT :: 8
PRINCIPAL_FILE_PIN_OFFSET_RESERVED :: 10
PRINCIPAL_FILE_PIN_OFFSET_PRINCIPAL :: 12
PRINCIPAL_FILE_PIN_OFFSET_GENERATION :: 16
PRINCIPAL_FILE_PIN_OFFSET_DIGEST :: 24
PRINCIPAL_FILE_PIN_OFFSET_CHECKSUM :: PRINCIPAL_FILE_PIN_OFFSET_DIGEST + SHA256_SIZE
PRINCIPAL_FILE_PIN_RECORD_SIZE :: PRINCIPAL_FILE_PIN_OFFSET_CHECKSUM + SHA256_SIZE

// The form of the record of the machine key. None is the zero value of a
// pin that does not exist yet: no stored payload holds it.
Machine_Key_Form :: enum u8 {
	None     = 0,
	MachineT = 1, // MACHINET: sealed by the TPM.
	MachineP = 2, // MACHINEP: sealed by the TPM with the machine passphrase.
	MachineK = 3, // MACHINEK: the machine passphrase alone.
}

// The refusals of a pin payload and of a change of a pin.
Pin_Refusal :: enum u8 {
	None                = 0,
	Buffer_Too_Small    = 1,
	Truncated           = 2,
	Trailing_Bytes      = 3,
	Bad_Magic           = 4,
	Unknown_Format      = 5,
	Bad_Checksum        = 6,
	Reserved_Not_Zero   = 7,
	Unknown_Form        = 8,
	Form_Downgrade      = 9,
	Form_Change         = 10,
	Form_Mismatch       = 11,
	Not_Pinned          = 12,
	Epoch_Zero          = 13,
	Epoch_Replay        = 14,
	Epoch_Rollback      = 15,
	Principal_Zero      = 16,
	Principal_Mismatch  = 17,
	Generation_Zero     = 18,
	Generation_Replay   = 19,
	Generation_Rollback = 20,
	Zero_Digest         = 21,
	Digest_Mismatch     = 22,
}

// The pinned form of the record of the machine key, and the epoch that
// rises at each new record (a new seal after a recovery, a new passphrase).
Machine_Key_Pin :: struct {
	form:  Machine_Key_Form,
	epoch: u64,
}

// The pinned file of a named principal. A generation of 0 is the zero value
// of a pin that does not exist yet: no stored payload holds it.
Principal_File_Pin :: struct {
	principal:   u32,
	generation:  u64,
	file_digest: Digest,
}

// machine_key_form_of_word is the border of a form word of a pin payload.
// None names no record, so a stored payload never holds it.
machine_key_form_of_word :: proc "contextless" (word: u64) -> (form: Machine_Key_Form, ok: bool) {
	form, ok = enum_word.member_of_word(Machine_Key_Form, word)
	if !ok || form == .None {
		return .None, false
	}
	return form, true
}

// machine_key_form_of_record_magic reads the first 8 bytes of a record of
// the machine key as its form.
machine_key_form_of_record_magic :: proc "contextless" (record: []u8) -> (form: Machine_Key_Form, ok: bool) {
	if len(record) < MACHINE_KEY_RECORD_MAGIC_SIZE {
		return .None, false
	}
	switch string(record[:MACHINE_KEY_RECORD_MAGIC_SIZE]) {
	case "MACHINET":
		return .MachineT, true
	case "MACHINEP":
		return .MachineP, true
	case "MACHINEK":
		return .MachineK, true
	}
	return .None, false
}

// machine_key_form_uses_tpm says if a form needs the TPM to open.
machine_key_form_uses_tpm :: proc "contextless" (form: Machine_Key_Form) -> bool {
	switch form {
	case .MachineT, .MachineP:
		return true
	case .MachineK, .None:
		return false
	}
	return false
}

@(private = "file")
pin_checksum :: proc "contextless" (domain: string, covered: []u8) -> Digest {
	domain := domain
	ctx: Sha256_State
	sha256_init(&ctx)
	sha256_update(&ctx, transmute([]u8)domain)
	sha256_update(&ctx, covered)
	return sha256_final(&ctx)
}

@(private = "file")
pin_payload_frame_check :: proc "contextless" (bytes: []u8, size: int, magic: string, domain: string, checksum_offset: int) -> Pin_Refusal {
	if len(bytes) < size {
		return .Truncated
	}
	if len(bytes) > size {
		return .Trailing_Bytes
	}
	if string(bytes[:len(magic)]) != magic {
		return .Bad_Magic
	}
	if byte_order.read_u16_big_endian(bytes, len(magic)) != PIN_RECORD_FORMAT {
		return .Unknown_Format
	}
	expected := pin_checksum(domain, bytes[:checksum_offset])
	if !constant_time_equal(expected[:], bytes[checksum_offset:][:SHA256_SIZE]) {
		return .Bad_Checksum
	}
	return .None
}

// machine_key_pin_encode writes the payload of a pin. It refuses a pin that
// a decode would refuse, and writes nothing then.
machine_key_pin_encode :: proc "contextless" (pin: Machine_Key_Pin, out: []u8) -> (count: int, refusal: Pin_Refusal) {
	if len(out) < MACHINE_KEY_PIN_RECORD_SIZE {
		return 0, .Buffer_Too_Small
	}
	if pin.form == .None {
		return 0, .Unknown_Form
	}
	if pin.epoch == 0 {
		return 0, .Epoch_Zero
	}
	payload := out[:MACHINE_KEY_PIN_RECORD_SIZE]
	copy(payload[MACHINE_KEY_PIN_OFFSET_MAGIC:], MACHINE_KEY_PIN_MAGIC)
	byte_order.write_u16_big_endian(payload, MACHINE_KEY_PIN_OFFSET_FORMAT, PIN_RECORD_FORMAT)
	payload[MACHINE_KEY_PIN_OFFSET_FORM] = u8(pin.form)
	payload[MACHINE_KEY_PIN_OFFSET_RESERVED] = 0
	byte_order.write_u64_big_endian(payload, MACHINE_KEY_PIN_OFFSET_EPOCH, pin.epoch)
	checksum := pin_checksum(MACHINE_KEY_PIN_DOMAIN, payload[:MACHINE_KEY_PIN_OFFSET_CHECKSUM])
	copy(payload[MACHINE_KEY_PIN_OFFSET_CHECKSUM:], checksum[:])
	return MACHINE_KEY_PIN_RECORD_SIZE, .None
}

// machine_key_pin_decode reads the payload of a pin, as the TPM index gave
// it. The bytes come from a device that another system can write.
machine_key_pin_decode :: proc "contextless" (bytes: []u8) -> (pin: Machine_Key_Pin, refusal: Pin_Refusal) {
	refusal = pin_payload_frame_check(bytes, MACHINE_KEY_PIN_RECORD_SIZE, MACHINE_KEY_PIN_MAGIC, MACHINE_KEY_PIN_DOMAIN, MACHINE_KEY_PIN_OFFSET_CHECKSUM)
	if refusal != .None {
		return {}, refusal
	}
	if bytes[MACHINE_KEY_PIN_OFFSET_RESERVED] != 0 {
		return {}, .Reserved_Not_Zero
	}
	form, form_ok := machine_key_form_of_word(u64(bytes[MACHINE_KEY_PIN_OFFSET_FORM]))
	if !form_ok {
		return {}, .Unknown_Form
	}
	epoch := byte_order.read_u64_big_endian(bytes, MACHINE_KEY_PIN_OFFSET_EPOCH)
	if epoch == 0 {
		return {}, .Epoch_Zero
	}
	return {form = form, epoch = epoch}, .None
}

// machine_key_pin_advance decides if the pin current may become proposed.
// A record keeps its form for its life (src/md/features/tpm_sealed_machine_passphrase.md,
// "Refused forms"), so only a machine with no pin chooses a form; after that
// only the epoch rises. A form that needs the TPM never becomes MACHINEK:
// that is the swap of a sealed record for one under a passphrase that an
// attacker chose.
machine_key_pin_advance :: proc "contextless" (current: Machine_Key_Pin, proposed: Machine_Key_Pin) -> Pin_Refusal {
	if proposed.form == .None {
		return .Unknown_Form
	}
	if proposed.epoch == 0 {
		return .Epoch_Zero
	}
	if current.form == .None {
		return .None
	}
	if proposed.form != current.form {
		if machine_key_form_uses_tpm(current.form) && !machine_key_form_uses_tpm(proposed.form) {
			return .Form_Downgrade
		}
		return .Form_Change
	}
	if proposed.epoch == current.epoch {
		return .Epoch_Replay
	}
	if proposed.epoch < current.epoch {
		return .Epoch_Rollback
	}
	return .None
}

// machine_key_record_matches_pin checks the form of a record of the machine
// key that the disk gave against the pin. Not_Pinned leaves the decision to
// the caller: a machine before its first pin.
machine_key_record_matches_pin :: proc "contextless" (pin: Machine_Key_Pin, record: []u8) -> Pin_Refusal {
	if len(record) < MACHINE_KEY_RECORD_MAGIC_SIZE {
		return .Truncated
	}
	form, form_ok := machine_key_form_of_record_magic(record)
	if !form_ok {
		return .Unknown_Form
	}
	if pin.form == .None {
		return .Not_Pinned
	}
	if form != pin.form {
		return .Form_Mismatch
	}
	return .None
}

// principal_file_digest is the digest that a principal file pin holds:
// SHA-256 of the whole file as the store keeps it.
principal_file_digest :: proc "contextless" (file: []u8) -> Digest {
	return sha256_sum(file)
}

// principal_file_pin_encode writes the payload of a pin. It refuses a pin
// that a decode would refuse, and writes nothing then.
principal_file_pin_encode :: proc "contextless" (pin: Principal_File_Pin, out: []u8) -> (count: int, refusal: Pin_Refusal) {
	if len(out) < PRINCIPAL_FILE_PIN_RECORD_SIZE {
		return 0, .Buffer_Too_Small
	}
	refusal = principal_file_pin_fields_check(pin)
	if refusal != .None {
		return 0, refusal
	}
	payload := out[:PRINCIPAL_FILE_PIN_RECORD_SIZE]
	digest := pin.file_digest
	copy(payload[PRINCIPAL_FILE_PIN_OFFSET_MAGIC:], PRINCIPAL_FILE_PIN_MAGIC)
	byte_order.write_u16_big_endian(payload, PRINCIPAL_FILE_PIN_OFFSET_FORMAT, PIN_RECORD_FORMAT)
	byte_order.write_u16_big_endian(payload, PRINCIPAL_FILE_PIN_OFFSET_RESERVED, 0)
	byte_order.write_u32_big_endian(payload, PRINCIPAL_FILE_PIN_OFFSET_PRINCIPAL, pin.principal)
	byte_order.write_u64_big_endian(payload, PRINCIPAL_FILE_PIN_OFFSET_GENERATION, pin.generation)
	copy(payload[PRINCIPAL_FILE_PIN_OFFSET_DIGEST:], digest[:])
	checksum := pin_checksum(PRINCIPAL_FILE_PIN_DOMAIN, payload[:PRINCIPAL_FILE_PIN_OFFSET_CHECKSUM])
	copy(payload[PRINCIPAL_FILE_PIN_OFFSET_CHECKSUM:], checksum[:])
	return PRINCIPAL_FILE_PIN_RECORD_SIZE, .None
}

// Principal 0 is the machine: its record is pinned by its form, and it has
// no principal file.
@(private = "file")
principal_file_pin_fields_check :: proc "contextless" (pin: Principal_File_Pin) -> Pin_Refusal {
	if pin.principal == 0 {
		return .Principal_Zero
	}
	if pin.generation == 0 {
		return .Generation_Zero
	}
	digest := pin.file_digest
	if is_all_zero(digest[:]) {
		return .Zero_Digest
	}
	return .None
}

// principal_file_pin_decode reads the payload of a pin, as the TPM index
// gave it.
principal_file_pin_decode :: proc "contextless" (bytes: []u8) -> (pin: Principal_File_Pin, refusal: Pin_Refusal) {
	refusal = pin_payload_frame_check(bytes, PRINCIPAL_FILE_PIN_RECORD_SIZE, PRINCIPAL_FILE_PIN_MAGIC, PRINCIPAL_FILE_PIN_DOMAIN, PRINCIPAL_FILE_PIN_OFFSET_CHECKSUM)
	if refusal != .None {
		return {}, refusal
	}
	if byte_order.read_u16_big_endian(bytes, PRINCIPAL_FILE_PIN_OFFSET_RESERVED) != 0 {
		return {}, .Reserved_Not_Zero
	}
	decoded := Principal_File_Pin {
		principal  = byte_order.read_u32_big_endian(bytes, PRINCIPAL_FILE_PIN_OFFSET_PRINCIPAL),
		generation = byte_order.read_u64_big_endian(bytes, PRINCIPAL_FILE_PIN_OFFSET_GENERATION),
	}
	copy(decoded.file_digest[:], bytes[PRINCIPAL_FILE_PIN_OFFSET_DIGEST:][:SHA256_SIZE])
	refusal = principal_file_pin_fields_check(decoded)
	if refusal != .None {
		return {}, refusal
	}
	return decoded, .None
}

// principal_file_pin_advance decides if the pin current may become
// proposed: the same principal, a higher generation. A kept older file
// then has a generation that the pin refuses, with its old passphrase.
principal_file_pin_advance :: proc "contextless" (current: Principal_File_Pin, proposed: Principal_File_Pin) -> Pin_Refusal {
	refusal := principal_file_pin_fields_check(proposed)
	if refusal != .None {
		return refusal
	}
	if current.generation == 0 {
		return .None
	}
	if proposed.principal != current.principal {
		return .Principal_Mismatch
	}
	if proposed.generation == current.generation {
		return .Generation_Replay
	}
	if proposed.generation < current.generation {
		return .Generation_Rollback
	}
	return .None
}

// principal_file_pin_check checks a principal file that the disk gave
// against its pin.
principal_file_pin_check :: proc "contextless" (pin: Principal_File_Pin, principal: u32, file: []u8) -> Pin_Refusal {
	if pin.generation == 0 {
		return .Not_Pinned
	}
	if principal != pin.principal {
		return .Principal_Mismatch
	}
	digest := principal_file_digest(file)
	expected := pin.file_digest
	if !constant_time_equal(digest[:], expected[:]) {
		return .Digest_Mismatch
	}
	return .None
}
