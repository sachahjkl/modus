// The contents of two TPM indices that pin state which the disk alone
// cannot be trusted to keep: the form and the digest of the record of the
// machine key, and the digest of the current file of each named principal
// (src/md/features/tpm_sealed_machine_key.md, "The pin of the record";
// src/md/features/tpm_sealed_principal_keys.md, "The pin of the file").
//
// A copy of the disk can bring back an older record or an older file. A
// value in the TPM that only this system writes says which one is current,
// and a number in it that only rises makes an older value refused too.
//
// A pin also holds the digest of the record or the file that is about to
// be written, the announced digest. A stop of the machine between the write
// of the disk and the write of the TPM then leaves a record that the pin
// still names, so a cut of the power never locks a principal out.
//
// Each payload has a fixed size, big-endian numbers, a magic, a format and
// a checksum under a text of its own. The checksum finds a damaged or
// partly written index; it proves no origin: the policy of the index
// decides who writes it.
package tpm_attestation

import "modus:contract/byte_order"
import "modus:contract/enum_word"

// The format of both payloads. A new layout is a new format, refused by a
// reader of this one. Format 1 had no record digest in the pin of the
// machine key, and no announced digest.
PIN_RECORD_FORMAT :: u16(2)
// The format of the payload of a principal file pin. Format 3 added the
// principal identifier (src/md/features/several_principals.md, "The
// identity: three names"); a payload of format 2 is refused as of an
// unknown format, and the file of its principal is of the older format too.
PRINCIPAL_FILE_PIN_FORMAT :: u16(3)

// The magics of the two payloads, and the texts of their checksums. Two
// texts keep a payload of one kind from passing the checksum of the other.
MACHINE_KEY_PIN_MAGIC :: "MODUSMKP"
MACHINE_KEY_PIN_DOMAIN :: "MODUS_MACHINE_KEY_PIN_V2"
PRINCIPAL_FILE_PIN_MAGIC :: "MODUSPFP"
PRINCIPAL_FILE_PIN_DOMAIN :: "MODUS_PRINCIPAL_FILE_PIN_V3"

// The bytes of the first word of a record of the machine key: its magic,
// which names its form.
MACHINE_KEY_RECORD_MAGIC_SIZE :: 8

// The layout of the payload of the machine key pin.
MACHINE_KEY_PIN_OFFSET_MAGIC :: 0
MACHINE_KEY_PIN_OFFSET_FORMAT :: 8
MACHINE_KEY_PIN_OFFSET_FORM :: 10
MACHINE_KEY_PIN_OFFSET_RESERVED :: 11
MACHINE_KEY_PIN_OFFSET_EPOCH :: 12
MACHINE_KEY_PIN_OFFSET_RECORD_DIGEST :: 20
MACHINE_KEY_PIN_OFFSET_NEXT_DIGEST :: MACHINE_KEY_PIN_OFFSET_RECORD_DIGEST + SHA256_SIZE
MACHINE_KEY_PIN_OFFSET_CHECKSUM :: MACHINE_KEY_PIN_OFFSET_NEXT_DIGEST + SHA256_SIZE
MACHINE_KEY_PIN_RECORD_SIZE :: MACHINE_KEY_PIN_OFFSET_CHECKSUM + SHA256_SIZE

// The layout of the payload of a principal file pin.
PRINCIPAL_FILE_PIN_OFFSET_MAGIC :: 0
PRINCIPAL_FILE_PIN_OFFSET_FORMAT :: 8
PRINCIPAL_FILE_PIN_OFFSET_RESERVED :: 10
PRINCIPAL_FILE_PIN_OFFSET_PRINCIPAL :: 12
PRINCIPAL_FILE_PIN_OFFSET_GENERATION :: 16
PRINCIPAL_FILE_PIN_OFFSET_IDENTIFIER :: 24
PRINCIPAL_FILE_PIN_OFFSET_DIGEST :: PRINCIPAL_FILE_PIN_OFFSET_IDENTIFIER + IDENTIFIER_SIZE
PRINCIPAL_FILE_PIN_OFFSET_NEXT_DIGEST :: PRINCIPAL_FILE_PIN_OFFSET_DIGEST + SHA256_SIZE
PRINCIPAL_FILE_PIN_OFFSET_CHECKSUM :: PRINCIPAL_FILE_PIN_OFFSET_NEXT_DIGEST + SHA256_SIZE
PRINCIPAL_FILE_PIN_RECORD_SIZE :: PRINCIPAL_FILE_PIN_OFFSET_CHECKSUM + SHA256_SIZE

// The bytes of a principal identifier: 32 random bytes that name a named
// principal on the disk (modus:principals, Principal_Identifier).
IDENTIFIER_SIZE :: 32
Identifier :: [IDENTIFIER_SIZE]u8

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
	None                 = 0,
	Buffer_Too_Small     = 1,
	Truncated            = 2,
	Trailing_Bytes       = 3,
	Bad_Magic            = 4,
	Unknown_Format       = 5,
	Bad_Checksum         = 6,
	Reserved_Not_Zero    = 7,
	Unknown_Form         = 8,
	Form_Downgrade       = 9,
	Form_Change          = 10,
	Form_Mismatch        = 11,
	Not_Pinned           = 12,
	Epoch_Zero           = 13,
	Epoch_Replay         = 14,
	Epoch_Rollback       = 15,
	Principal_Zero       = 16,
	Principal_Mismatch   = 17,
	Generation_Zero      = 18,
	Generation_Replay    = 19,
	Generation_Rollback  = 20,
	Zero_Digest          = 21,
	Digest_Mismatch      = 22,
	Epoch_Exhausted      = 23, // The epoch is the largest of its type: no pin can follow it.
	Generation_Exhausted = 24, // The generation is the largest of its type.
	Record_Absent        = 25, // The pin names a record or a file that the disk does not hold.
	Announce_Pending     = 26, // The pin announces a record already: it is settled first.
	Identifier_Zero      = 27, // The principal identifier is all zero: no creation draws it.
	Identifier_Mismatch  = 28, // The file names another principal identifier than the pin.
}

// The words of each refusal, for a line of the log.
@(rodata)
pin_refusal_words := [Pin_Refusal]string {
	.None                 = "no refusal",
	.Buffer_Too_Small     = "the buffer is too small",
	.Truncated            = "the bytes are truncated",
	.Trailing_Bytes       = "bytes follow the payload",
	.Bad_Magic            = "the magic is wrong",
	.Unknown_Format       = "the format is not known",
	.Bad_Checksum         = "the checksum is wrong",
	.Reserved_Not_Zero    = "a reserved byte is not zero",
	.Unknown_Form         = "the form is not known",
	.Form_Downgrade       = "a form with the TPM becomes the passphrase alone",
	.Form_Change          = "the form changes",
	.Form_Mismatch        = "the form is not the pinned form",
	.Not_Pinned           = "no pin",
	.Epoch_Zero           = "the epoch is zero",
	.Epoch_Replay         = "the epoch is the pinned epoch",
	.Epoch_Rollback       = "the epoch is below the pinned epoch",
	.Principal_Zero       = "the principal is zero",
	.Principal_Mismatch   = "the principal is not the pinned principal",
	.Generation_Zero      = "the generation is zero",
	.Generation_Replay    = "the generation is the pinned generation",
	.Generation_Rollback  = "the generation is below the pinned generation",
	.Zero_Digest          = "the digest is zero",
	.Digest_Mismatch      = "the digest is not the pinned digest",
	.Epoch_Exhausted      = "the epoch is exhausted",
	.Generation_Exhausted = "the generation is exhausted",
	.Record_Absent        = "the pinned record is absent",
	.Announce_Pending     = "the pin announces a record already",
	.Identifier_Zero      = "the principal identifier is zero",
	.Identifier_Mismatch  = "the principal identifier is not the pinned identifier",
}

// pin_refusal_of_word is the border of the word of a refusal that crosses
// the ring of the TPM service.
pin_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Pin_Refusal, ok: bool) {
	return enum_word.member_of_word(Pin_Refusal, word)
}

// Which digest of a pin a record or a file has.
Pin_Match :: enum u8 {
	Current, // The digest of the current record.
	Next, // The announced digest: the write of the disk ended, the write of the pin did not.
}

// The pinned record of the machine key: its form, the epoch that rises at
// each write of the pin, the digest of the record, and the digest of the
// record whose write is announced (zero when none is).
Machine_Key_Pin :: struct {
	form:          Machine_Key_Form,
	epoch:         u64,
	record_digest: Digest,
	next_digest:   Digest,
}

// The pinned file of a named principal. A generation of 0 is the zero value
// of a pin that does not exist yet: no stored payload holds it.
Principal_File_Pin :: struct {
	principal:   u32, // The slot of the pin index.
	identifier:  Identifier, // The principal identifier of the pinned file.
	generation:  u64,
	file_digest: Digest,
	next_digest: Digest,
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
pin_payload_frame_check :: proc "contextless" (bytes: []u8, size: int, magic: string, domain: string, checksum_offset: int, format: u16 = PIN_RECORD_FORMAT) -> Pin_Refusal {
	if len(bytes) < size {
		return .Truncated
	}
	if len(bytes) > size {
		return .Trailing_Bytes
	}
	if string(bytes[:len(magic)]) != magic {
		return .Bad_Magic
	}
	if byte_order.read_u16_big_endian(bytes, len(magic)) != format {
		return .Unknown_Format
	}
	expected := pin_checksum(domain, bytes[:checksum_offset])
	if !constant_time_equal(expected[:], bytes[checksum_offset:][:SHA256_SIZE]) {
		return .Bad_Checksum
	}
	return .None
}

// machine_key_record_digest is the digest that a machine key pin holds:
// SHA-256 of the whole record as the store keeps it.
machine_key_record_digest :: proc "contextless" (record: []u8) -> Digest {
	return sha256_sum(record)
}

// The fields of a machine key pin that each stored payload must have.
@(private = "file")
machine_key_pin_fields_check :: proc "contextless" (pin: Machine_Key_Pin) -> Pin_Refusal {
	if pin.form == .None {
		return .Unknown_Form
	}
	if pin.epoch == 0 {
		return .Epoch_Zero
	}
	digest := pin.record_digest
	if is_all_zero(digest[:]) {
		return .Zero_Digest
	}
	return .None
}

// machine_key_pin_encode writes the payload of a pin. It refuses a pin that
// a decode would refuse, and writes nothing then.
machine_key_pin_encode :: proc "contextless" (pin: Machine_Key_Pin, out: []u8) -> (count: int, refusal: Pin_Refusal) {
	if len(out) < MACHINE_KEY_PIN_RECORD_SIZE {
		return 0, .Buffer_Too_Small
	}
	refusal = machine_key_pin_fields_check(pin)
	if refusal != .None {
		return 0, refusal
	}
	payload := out[:MACHINE_KEY_PIN_RECORD_SIZE]
	record_digest, next_digest := pin.record_digest, pin.next_digest
	copy(payload[MACHINE_KEY_PIN_OFFSET_MAGIC:], MACHINE_KEY_PIN_MAGIC)
	byte_order.write_u16_big_endian(payload, MACHINE_KEY_PIN_OFFSET_FORMAT, PIN_RECORD_FORMAT)
	payload[MACHINE_KEY_PIN_OFFSET_FORM] = u8(pin.form)
	payload[MACHINE_KEY_PIN_OFFSET_RESERVED] = 0
	byte_order.write_u64_big_endian(payload, MACHINE_KEY_PIN_OFFSET_EPOCH, pin.epoch)
	copy(payload[MACHINE_KEY_PIN_OFFSET_RECORD_DIGEST:], record_digest[:])
	copy(payload[MACHINE_KEY_PIN_OFFSET_NEXT_DIGEST:], next_digest[:])
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
	decoded := Machine_Key_Pin {
		form  = form,
		epoch = byte_order.read_u64_big_endian(bytes, MACHINE_KEY_PIN_OFFSET_EPOCH),
	}
	copy(decoded.record_digest[:], bytes[MACHINE_KEY_PIN_OFFSET_RECORD_DIGEST:][:SHA256_SIZE])
	copy(decoded.next_digest[:], bytes[MACHINE_KEY_PIN_OFFSET_NEXT_DIGEST:][:SHA256_SIZE])
	refusal = machine_key_pin_fields_check(decoded)
	if refusal != .None {
		return {}, refusal
	}
	return decoded, .None
}

// machine_key_pin_advance decides if the pin current may become proposed.
// A record keeps its form for its life (src/md/features/tpm_sealed_machine_passphrase.md,
// "Refused forms"), so only a machine with no pin chooses a form; after that
// only the epoch rises. A form that needs the TPM never becomes MACHINEK:
// that is the swap of a sealed record for one under a passphrase that an
// attacker chose.
machine_key_pin_advance :: proc "contextless" (current: Machine_Key_Pin, proposed: Machine_Key_Pin) -> Pin_Refusal {
	refusal := machine_key_pin_fields_check(proposed)
	if refusal != .None {
		return refusal
	}
	if current.form == .None {
		return .None
	}
	if pin_announce_pending(current.next_digest, proposed.next_digest) {
		return .Announce_Pending
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

// machine_key_record_matches_pin checks a record of the machine key that
// the disk gave against the pin: its form, then its digest, which is the
// current digest or the announced one. Not_Pinned leaves the decision to
// the caller: a machine before its first pin.
machine_key_record_matches_pin :: proc "contextless" (pin: Machine_Key_Pin, record: []u8) -> (match: Pin_Match, refusal: Pin_Refusal) {
	if len(record) < MACHINE_KEY_RECORD_MAGIC_SIZE {
		return .Current, .Truncated
	}
	form, form_ok := machine_key_form_of_record_magic(record)
	if !form_ok {
		return .Current, .Unknown_Form
	}
	if pin.form == .None {
		return .Current, .Not_Pinned
	}
	if form != pin.form {
		return .Current, .Form_Mismatch
	}
	return digest_match(machine_key_record_digest(record), pin.record_digest, pin.next_digest)
}

// pin_announce_pending says if a change announces a record over a pin that
// announces one already. Such a pin names two records, A current and B
// announced; a new announce of C would drop B, and a stop before the write
// of C would leave B on the disk, refused. So a pin is settled before it
// announces again.
@(private = "file")
pin_announce_pending :: proc "contextless" (current_next: Digest, proposed_next: Digest) -> bool {
	current_next, proposed_next := current_next, proposed_next
	return !is_all_zero(current_next[:]) && !is_all_zero(proposed_next[:])
}

// digest_match says which digest of a pin a digest of the disk is.
@(private = "file")
digest_match :: proc "contextless" (digest: Digest, current: Digest, next: Digest) -> (match: Pin_Match, refusal: Pin_Refusal) {
	digest, current, next := digest, current, next
	if constant_time_equal(digest[:], current[:]) {
		return .Current, .None
	}
	if !is_all_zero(next[:]) && constant_time_equal(digest[:], next[:]) {
		return .Next, .None
	}
	return .Current, .Digest_Mismatch
}

// machine_key_pin_announce gives the pin to write before the write of a new
// record: the current record stays current, and the new one is announced.
// A machine with no pin announces nothing: its first pin comes after the
// write (machine_key_pin_settle).
machine_key_pin_announce :: proc "contextless" (current: Machine_Key_Pin, new_record: []u8) -> (proposed: Machine_Key_Pin, refusal: Pin_Refusal) {
	if current.form == .None {
		return {}, .Not_Pinned
	}
	form, form_ok := machine_key_form_of_record_magic(new_record)
	if !form_ok {
		return {}, .Unknown_Form
	}
	if current.epoch == max(u64) {
		return {}, .Epoch_Exhausted
	}
	proposed = current
	proposed.epoch = current.epoch + 1
	proposed.next_digest = machine_key_record_digest(new_record)
	proposed.form = form
	refusal = machine_key_pin_advance(current, proposed)
	if refusal != .None {
		return {}, refusal
	}
	return proposed, .None
}

// machine_key_pin_settle gives the pin to write after a write: kept is the
// record that the store holds now (the new one when the store kept it, the
// old one when it did not). Nothing is announced after it.
machine_key_pin_settle :: proc "contextless" (current: Machine_Key_Pin, kept: []u8) -> (proposed: Machine_Key_Pin, refusal: Pin_Refusal) {
	form, form_ok := machine_key_form_of_record_magic(kept)
	if !form_ok {
		return {}, .Unknown_Form
	}
	if current.epoch == max(u64) {
		return {}, .Epoch_Exhausted
	}
	proposed = {form = form, epoch = current.epoch + 1, record_digest = machine_key_record_digest(kept)}
	refusal = machine_key_pin_advance(current, proposed)
	if refusal != .None {
		return {}, refusal
	}
	return proposed, .None
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
	digest, next_digest := pin.file_digest, pin.next_digest
	copy(payload[PRINCIPAL_FILE_PIN_OFFSET_MAGIC:], PRINCIPAL_FILE_PIN_MAGIC)
	byte_order.write_u16_big_endian(payload, PRINCIPAL_FILE_PIN_OFFSET_FORMAT, PRINCIPAL_FILE_PIN_FORMAT)
	byte_order.write_u16_big_endian(payload, PRINCIPAL_FILE_PIN_OFFSET_RESERVED, 0)
	byte_order.write_u32_big_endian(payload, PRINCIPAL_FILE_PIN_OFFSET_PRINCIPAL, pin.principal)
	byte_order.write_u64_big_endian(payload, PRINCIPAL_FILE_PIN_OFFSET_GENERATION, pin.generation)
	identifier := pin.identifier
	copy(payload[PRINCIPAL_FILE_PIN_OFFSET_IDENTIFIER:], identifier[:])
	copy(payload[PRINCIPAL_FILE_PIN_OFFSET_DIGEST:], digest[:])
	copy(payload[PRINCIPAL_FILE_PIN_OFFSET_NEXT_DIGEST:], next_digest[:])
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
	identifier := pin.identifier
	if is_all_zero(identifier[:]) {
		return .Identifier_Zero
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
	refusal = pin_payload_frame_check(bytes, PRINCIPAL_FILE_PIN_RECORD_SIZE, PRINCIPAL_FILE_PIN_MAGIC, PRINCIPAL_FILE_PIN_DOMAIN, PRINCIPAL_FILE_PIN_OFFSET_CHECKSUM, PRINCIPAL_FILE_PIN_FORMAT)
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
	copy(decoded.identifier[:], bytes[PRINCIPAL_FILE_PIN_OFFSET_IDENTIFIER:][:IDENTIFIER_SIZE])
	copy(decoded.file_digest[:], bytes[PRINCIPAL_FILE_PIN_OFFSET_DIGEST:][:SHA256_SIZE])
	copy(decoded.next_digest[:], bytes[PRINCIPAL_FILE_PIN_OFFSET_NEXT_DIGEST:][:SHA256_SIZE])
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
	if pin_announce_pending(current.next_digest, proposed.next_digest) {
		return .Announce_Pending
	}
	if proposed.principal != current.principal {
		return .Principal_Mismatch
	}
	if proposed.identifier != current.identifier {
		return .Identifier_Mismatch
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
// against its pin: the current digest, or the announced one.
principal_file_pin_check :: proc "contextless" (pin: Principal_File_Pin, principal: u32, identifier: Identifier, file: []u8) -> (match: Pin_Match, refusal: Pin_Refusal) {
	if pin.generation == 0 {
		return .Current, .Not_Pinned
	}
	if principal != pin.principal {
		return .Current, .Principal_Mismatch
	}
	// The pin of a slot names the identifier: a file of another principal
	// in the slot is refused, whatever its digest.
	if identifier != pin.identifier {
		return .Current, .Identifier_Mismatch
	}
	return digest_match(principal_file_digest(file), pin.file_digest, pin.next_digest)
}

// principal_file_pin_announce gives the pin to write before the write of a
// new file of a pinned principal: the current file stays current, and the
// new one is announced. A principal with no pin announces nothing.
principal_file_pin_announce :: proc "contextless" (current: Principal_File_Pin, new_file: []u8) -> (proposed: Principal_File_Pin, refusal: Pin_Refusal) {
	if current.generation == 0 {
		return {}, .Not_Pinned
	}
	if current.generation == max(u64) {
		return {}, .Generation_Exhausted
	}
	proposed = current
	proposed.generation = current.generation + 1
	proposed.next_digest = principal_file_digest(new_file)
	refusal = principal_file_pin_advance(current, proposed)
	if refusal != .None {
		return {}, refusal
	}
	return proposed, .None
}

// principal_file_pin_settle gives the pin to write after a write: kept is
// the file that the store holds now. A principal with no pin gets its first
// pin here, at the generation 1.
principal_file_pin_settle :: proc "contextless" (current: Principal_File_Pin, principal: u32, identifier: Identifier, kept: []u8) -> (proposed: Principal_File_Pin, refusal: Pin_Refusal) {
	if current.generation == max(u64) {
		return {}, .Generation_Exhausted
	}
	proposed = {principal = principal, identifier = identifier, generation = current.generation + 1, file_digest = principal_file_digest(kept)}
	refusal = principal_file_pin_advance(current, proposed)
	if refusal != .None {
		return {}, refusal
	}
	return proposed, .None
}
