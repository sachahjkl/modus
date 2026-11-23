#+build !freestanding
package principals

import "core:testing"
import "modus:contract/byte_order"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:cryptography_primitives"
import "modus:tpm2"

// The pair of a procedure of the call form, as one value that a check
// compares.
@(private = "file")
Answer :: struct {
	outcome: call_outcome.Call_Outcome,
	value:   i64,
}

@(private = "file")
answer_of :: proc(outcome: call_outcome.Call_Outcome, value: i64) -> Answer {
	return {outcome, value}
}

// refused says if a call refused an argument: the outcome Argument_Refused
// and the value 0.
@(private = "file")
refused :: proc(outcome: call_outcome.Call_Outcome, value: i64) -> bool {
	return outcome == .Argument_Refused && value == 0
}

// The store of a module has the name of the module for the machine, so
// the stores of the system keep their names; a named principal has a store
// of its own for each module.
@(test)
store_names_carry_the_principal :: proc(t: ^testing.T) {
	out: [32]u8
	cases := [?]struct {
		process:   string,
		principal: u64,
		history:   bool,
		name:      string,
	} {
		{"notes", MACHINE, false, "notes"},
		{"console", MACHINE, true, "console.history"},
		{"notes", 1, false, "notes.principal.1"},
		{"console", 1, true, "console.history.principal.1"},
		{"notes", 32767, false, "notes.principal.32767"},
	}
	for item in cases {
		testing.expect(t, store_name_write(&out, item.process, item.principal, item.history))
		length := 0
		for length < len(out) && out[length] != 0 {
			length += 1
		}
		testing.expect_value(t, string(out[:length]), item.name)
		// The inverse gives the principal back from the name.
		testing.expect_value(t, store_name_principal(item.name), item.principal)
	}
	testing.expect_value(t, store_name_principal("principal.1"), u64(MACHINE))
	testing.expect_value(t, store_name_principal("notes.principal."), u64(MACHINE))
	// Two principals that run one module: two stores.
	first, second: [32]u8
	testing.expect(t, store_name_write(&first, "notes", MACHINE, false))
	testing.expect(t, store_name_write(&second, "notes", 1, false))
	testing.expect(t, first != second)
}

// A name that does not fit with its zero byte is refused, never cut: a cut
// name can be the name of another store.
@(test)
a_store_name_that_does_not_fit_is_refused :: proc(t: ^testing.T) {
	out: [32]u8
	testing.expect(t, store_name_write(&out, "interface_through_module", MACHINE, false))
	testing.expect(t, !store_name_write(&out, "interface_through_module", 1, false))
	testing.expect_value(t, out, [32]u8{})
	// 31 bytes fit; 32 do not.
	testing.expect(t, store_name_write(&out, "abcdefghijklmnopqrstuvwxyz01234", MACHINE, false))
	testing.expect(t, !store_name_write(&out, "abcdefghijklmnopqrstuvwxyz012345", MACHINE, false))
}

@(test)
names_and_passphrases :: proc(t: ^testing.T) {
	testing.expect_value(t, name_problem("alice"), Name_Problem.None)
	testing.expect_value(t, name_problem("a.b-c_9"), Name_Problem.None)
	testing.expect_value(t, name_problem(""), Name_Problem.Empty)
	testing.expect_value(t, name_problem("abcdefghijklmnopqrstuvwx"), Name_Problem.Too_Long)
	testing.expect_value(t, name_problem("two words"), Name_Problem.Bad_Byte)
	testing.expect_value(t, name_problem("quote\""), Name_Problem.Bad_Byte)
	testing.expect_value(t, passphrase_problem(transmute([]u8)string("correct horse")), Passphrase_Problem.None)
	testing.expect_value(t, passphrase_problem(transmute([]u8)string("short")), Passphrase_Problem.Too_Short)
	testing.expect_value(t, passphrase_problem(transmute([]u8)string("tab\tinside it")), Passphrase_Problem.Not_Text)
	// A passphrase of the layout of France: UTF-8, and its bytes count.
	testing.expect_value(t, passphrase_problem(transmute([]u8)string("été à Noël")), Passphrase_Problem.None)
	testing.expect_value(t, passphrase_problem(transmute([]u8)string("éééé")), Passphrase_Problem.None) // 8 bytes.
	testing.expect_value(t, passphrase_problem(transmute([]u8)string("ééé")), Passphrase_Problem.Too_Short)
	testing.expect_value(t, passphrase_problem(transmute([]u8)string("a sequence \xC3 cut short")), Passphrase_Problem.Not_Text)
	long: [PASSPHRASE_LIMIT + 1]u8
	for &character in long {
		character = 'a'
	}
	testing.expect_value(t, passphrase_problem(long[:]), Passphrase_Problem.Too_Long)
	testing.expect_value(t, passphrase_problem(long[:PASSPHRASE_LIMIT]), Passphrase_Problem.None)
	values := name_pack("alice")
	name, length := name_unpack(values)
	testing.expect_value(t, string(name[:length]), "alice")
	full := name_pack("abcdefghijklmnopqrstuvw")
	name, length = name_unpack(full)
	testing.expect_value(t, length, NAME_LIMIT)
}

test_file :: proc() -> Principal_File {
	file := Principal_File{name_length = 5}
	for index in 0 ..< PRINCIPAL_IDENTIFIER_SIZE {
		file.identifier[index] = u8(200 + index)
	}
	copy(file.name[:], "alice")
	for index in 0 ..< PUBLIC_KEY_SIZE {
		file.signing_public_key[index] = u8(index)
		file.unlock_public_key[index] = u8(100 + index)
	}
	for index in 0 ..< SALT_SIZE {
		file.salt[index] = u8(200 + index)
	}
	for index in 0 ..< NONCE_SIZE {
		file.nonce[index] = u8(50 + index)
	}
	for index in 0 ..< SEALED_SIZE {
		file.sealed[index] = u8(index * 3)
	}
	return file
}

@(test)
a_file_round_trip :: proc(t: ^testing.T) {
	file := test_file()
	bytes: [FILE_SIZE]u8
	file_encode(&file, &bytes)
	decoded, kept, problem := file_decode(bytes[:])
	testing.expect_value(t, problem, File_Problem.None)
	testing.expect(t, decoded == file)
	testing.expect(t, kept == bytes)
	testing.expect_value(t, len(file_additional_data(&kept)), OFFSET_SEALED)
	testing.expect_value(t, string(bytes[:8]), "PRINCIPL")
}

// A file is data from the disk: each field that the code trusts is checked.
@(test)
hostile_files_are_refused :: proc(t: ^testing.T) {
	file := test_file()
	good: [FILE_SIZE]u8
	file_encode(&file, &good)
	expect :: proc(test: ^testing.T, bytes: []u8, wanted: File_Problem) {
		_, _, problem := file_decode(bytes)
		testing.expect_value(test, problem, wanted)
	}
	expect(t, good[:FILE_SIZE - 1], .Wrong_Size)
	expect(t, nil, .Wrong_Size)
	changed := good
	changed[0] = 'X'
	expect(t, changed[:], .Wrong_Magic)
	changed = good
	changed[OFFSET_FORMAT] = u8(FILE_FORMAT + 1) // A format that this system does not know.
	expect(t, changed[:], .Wrong_Format)
	// The format of the release before: refused with the sentence that
	// says what to do; the formats 0 and the largest name no release.
	changed = good
	changed[OFFSET_FORMAT] = u8(OLDER_FILE_FORMAT)
	expect(t, changed[:], .Older_Format)
	changed = good
	changed[OFFSET_FORMAT] = 0
	expect(t, changed[:], .Wrong_Format)
	changed = good
	changed[OFFSET_FORMAT], changed[OFFSET_FORMAT + 1], changed[OFFSET_FORMAT + 2], changed[OFFSET_FORMAT + 3] = 0xff, 0xff, 0xff, 0xff
	expect(t, changed[:], .Wrong_Format)
	// A file of no identifier; one byte of the identifier suffices.
	changed = good
	for index in 0 ..< PRINCIPAL_IDENTIFIER_SIZE {
		changed[OFFSET_IDENTIFIER + index] = 0
	}
	expect(t, changed[:], .Zero_Identifier)
	changed[OFFSET_IDENTIFIER + PRINCIPAL_IDENTIFIER_SIZE - 1] = 1
	expect(t, changed[:], .None)
	testing.expect(t, len(file_problem_sentences[.Older_Format]) > 0 && len(principal_tpm_file_problem_sentences[.Older_Format]) > 0)
	// A file cannot ask for a cheaper derivation, or for more memory.
	changed = good
	changed[OFFSET_MEMORY] = 8
	expect(t, changed[:], .Other_Parameters)
	changed = good
	changed[OFFSET_PASSES] = 1
	expect(t, changed[:], .Other_Parameters)
	changed = good
	changed[OFFSET_NAME_LENGTH] = NAME_LIMIT + 1
	expect(t, changed[:], .Bad_Name)
	changed = good
	changed[OFFSET_NAME_LENGTH] = 0
	expect(t, changed[:], .Bad_Name)
	changed = good
	changed[OFFSET_NAME + 1] = ' '
	expect(t, changed[:], .Bad_Name)
	changed = good
	changed[OFFSET_NAME + 10] = 'x'
	expect(t, changed[:], .Bytes_After_Name)
}

test_machine_file :: proc() -> (file: Machine_File) {
	for index in 0 ..< SALT_SIZE {
		file.salt[index] = u8(7 + index)
	}
	for index in 0 ..< NONCE_SIZE {
		file.nonce[index] = u8(90 + index)
	}
	for index in 0 ..< MACHINE_SEALED_SIZE {
		file.sealed[index] = u8(index * 5 + 1)
	}
	return file
}

@(test)
a_machine_record_round_trip :: proc(t: ^testing.T) {
	file := test_machine_file()
	bytes: [MACHINE_FILE_SIZE]u8
	machine_file_encode(&file, &bytes)
	decoded, kept, problem := machine_file_decode(bytes[:])
	testing.expect_value(t, problem, File_Problem.None)
	testing.expect(t, decoded == file)
	testing.expect(t, kept == bytes)
	testing.expect_value(t, len(machine_file_additional_data(&kept)), MACHINE_OFFSET_SEALED)
	testing.expect_value(t, string(bytes[:8]), "MACHINEK")
	// The salt, the nonce and the seal are at their offsets of the guide.
	testing.expect_value(t, bytes[20], u8(7))
	testing.expect_value(t, bytes[36], u8(90))
	testing.expect_value(t, bytes[48], u8(1))
}

// The record of the machine is data from the disk, as the file of a
// principal is: a record cannot ask for a cheaper derivation.
@(test)
hostile_machine_records_are_refused :: proc(t: ^testing.T) {
	file := test_machine_file()
	good: [MACHINE_FILE_SIZE]u8
	machine_file_encode(&file, &good)
	expect :: proc(test: ^testing.T, bytes: []u8, wanted: File_Problem) {
		_, _, problem := machine_file_decode(bytes)
		testing.expect_value(test, problem, wanted)
	}
	expect(t, good[:MACHINE_FILE_SIZE - 1], .Wrong_Size)
	expect(t, nil, .Wrong_Size)
	// A file of a named principal is no record of the machine.
	principal_bytes: [FILE_SIZE]u8
	principal_file := test_file()
	file_encode(&principal_file, &principal_bytes)
	expect(t, principal_bytes[:], .Wrong_Size)
	changed := good
	changed[1] = 'X'
	expect(t, changed[:], .Wrong_Magic)
	changed = good
	changed[MACHINE_OFFSET_FORMAT] = u8(MACHINE_FORMAT + 1) // A format that this system does not know.
	expect(t, changed[:], .Wrong_Format)
	changed = good
	changed[MACHINE_OFFSET_MEMORY] = 8
	expect(t, changed[:], .Other_Parameters)
	changed = good
	changed[MACHINE_OFFSET_PASSES] = 1
	expect(t, changed[:], .Other_Parameters)
}

// The parts of a creation ticket: its tag, its hierarchy and the size of its
// digest, then the digest.
TICKET_HEAD_SIZE :: 2 + 4 + 2
TICKET_DIGEST_SIZE_PLACE :: TICKET_HEAD_SIZE - 1 // The low byte of the size of the digest.
DIGEST_OF_SHA256 :: 32

test_machine_tpm_file :: proc() -> (file: Machine_Tpm_File) {
	file.pcrs = tpm2.PCR_SET
	// Two areas as the TPM gives them: a size field, then its bytes.
	file.public_bytes = 82
	file.public_area[0], file.public_area[1] = 0x00, 80
	for index in 2 ..< 82 {
		file.public_area[index] = u8(index)
	}
	file.private_bytes = 130
	file.private_area[0], file.private_area[1] = 0x00, 128
	for index in 2 ..< 130 {
		file.private_area[index] = u8(200 - index)
	}
	// The creation data as the TPM gives it: the selection of PCR 7 and PCR
	// 11 of SHA-256, a digest, the locality, the name of the parent and its
	// qualified name, no outside information: 123 bytes with its size field.
	creation := [?]u8{0x00, 0x79, 0x00, 0x00, 0x00, 0x01, 0x00, 0x0B, 0x03, 0x80, 0x08, 0x00, 0x00, 0x20}
	place := copy(file.creation_data[:], creation[:])
	for index in 0 ..< 32 {
		file.creation_data[place + index] = u8(0x30 + index)
	}
	place += 32
	file.creation_data[place + 1], file.creation_data[place + 2] = 0x00, 0x0B // The locality 0, then the hash of the parent name.
	place += 3
	for _ in 0 ..< 2 {
		file.creation_data[place], file.creation_data[place + 1] = 0x00, 34 // A name: the hash, then the digest.
		file.creation_data[place + 3] = 0x0B
		place += 2 + 34
	}
	place += 2 // No outside information.
	file.creation_bytes = place
	// The creation ticket as swtpm gives it: its tag, the owner hierarchy,
	// and a digest of SHA-512, the largest that the record takes.
	ticket := [TICKET_HEAD_SIZE]u8{0x80, 0x21, 0x40, 0x00, 0x00, 0x01, 0x00, u8(tpm2.TICKET_DIGEST_LIMIT)}
	head := copy(file.creation_ticket[:], ticket[:])
	file.ticket_bytes = head + tpm2.TICKET_DIGEST_LIMIT
	for index in head ..< file.ticket_bytes {
		file.creation_ticket[index] = 0x5A
	}
	for index in 0 ..< NONCE_SIZE {
		file.recovery_nonce[index] = u8(30 + index)
	}
	for index in 0 ..< MACHINE_SEALED_SIZE {
		file.recovery_sealed[index] = u8(index * 3 + 2)
	}
	for index in 0 ..< KEY_SIZE {
		file.key_check[index] = u8(index + 100)
	}
	return file
}

@(test)
a_record_sealed_by_the_tpm_round_trip :: proc(t: ^testing.T) {
	file := test_machine_tpm_file()
	bytes: [MACHINE_TPM_FILE_SIZE]u8
	machine_tpm_file_encode(&file, &bytes)
	decoded, kept, problem := machine_tpm_file_decode(bytes[:])
	testing.expect_value(t, problem, File_Problem.None)
	testing.expect(t, decoded == file)
	testing.expect(t, kept == bytes)
	testing.expect_value(t, string(bytes[:8]), "MACHINET")
	testing.expect_value(t, file.creation_bytes, 123)
	testing.expect_value(t, file.ticket_bytes, MACHINE_TPM_TICKET_LIMIT)
	// The offsets of the table of the guide (docs/PRINCIPALS.md).
	guide_offsets := [?][2]int {
		{MACHINE_TPM_OFFSET_PUBLIC, 24},
		{MACHINE_TPM_OFFSET_PRIVATE, 152},
		{MACHINE_TPM_OFFSET_CREATION, 408},
		{MACHINE_TPM_OFFSET_TICKET, 664},
		{MACHINE_TPM_TICKET_LIMIT, 72},
		{MACHINE_TPM_OFFSET_RECOVERY_NONCE, 736},
		{MACHINE_TPM_OFFSET_RECOVERY_SEALED, 748},
		{MACHINE_TPM_OFFSET_KEY_CHECK, 796},
		{MACHINE_TPM_FILE_SIZE, 828},
	}
	for pair in guide_offsets {
		testing.expect_value(t, pair[0], pair[1])
	}
	// Each field at its offset.
	testing.expect_value(t, bytes[MACHINE_OFFSET_FORMAT], u8(MACHINE_TPM_FORMAT))
	testing.expect_value(t, bytes[MACHINE_TPM_OFFSET_PCRS], u8(0x80)) // PCR 7 and PCR 11: 0x880, little-endian.
	testing.expect_value(t, bytes[MACHINE_TPM_OFFSET_PCRS + 1], u8(0x08))
	testing.expect_value(t, int(bytes[MACHINE_TPM_OFFSET_PUBLIC_BYTES]), file.public_bytes)
	testing.expect_value(t, int(bytes[MACHINE_TPM_OFFSET_PRIVATE_BYTES]), file.private_bytes)
	testing.expect_value(t, int(bytes[MACHINE_TPM_OFFSET_CREATION_BYTES]), file.creation_bytes)
	testing.expect_value(t, int(bytes[MACHINE_TPM_OFFSET_TICKET_BYTES]), file.ticket_bytes)
	testing.expect_value(t, bytes[MACHINE_TPM_OFFSET_PUBLIC + 2], file.public_area[2])
	testing.expect_value(t, bytes[MACHINE_TPM_OFFSET_PRIVATE + 2], file.private_area[2])
	testing.expect_value(t, bytes[MACHINE_TPM_OFFSET_CREATION + 1], file.creation_data[1])
	testing.expect_value(t, bytes[MACHINE_TPM_OFFSET_TICKET], u8(tpm2.TAG_CREATION >> 8))
	testing.expect_value(t, bytes[MACHINE_TPM_OFFSET_TICKET + file.ticket_bytes - 1], file.creation_ticket[file.ticket_bytes - 1])
	testing.expect_value(t, bytes[MACHINE_TPM_OFFSET_RECOVERY_NONCE], file.recovery_nonce[0])
	testing.expect_value(t, bytes[MACHINE_TPM_OFFSET_RECOVERY_SEALED], file.recovery_sealed[0])
	testing.expect_value(t, bytes[MACHINE_TPM_OFFSET_KEY_CHECK], file.key_check[0])
	// The recovery seal covers the magic and the format only: a new seal by
	// the TPM changes the areas and keeps the copy under the recovery key.
	testing.expect_value(t, len(machine_tpm_file_additional_data(&kept)), 12)
	// The form of the object, by its first 8 bytes.
	testing.expect_value(t, machine_record_form(bytes[:]), Machine_Record_Form.Sealed_By_The_Tpm)
	passphrase_file := test_machine_file()
	passphrase_bytes: [MACHINE_FILE_SIZE]u8
	machine_file_encode(&passphrase_file, &passphrase_bytes)
	testing.expect_value(t, machine_record_form(passphrase_bytes[:]), Machine_Record_Form.Passphrase)
	testing.expect_value(t, machine_record_form(bytes[:7]), Machine_Record_Form.Unknown)
	testing.expect_value(t, machine_record_form(nil), Machine_Record_Form.Unknown)
}

// The record is data from the disk: an area that is not whole would go to
// the TPM as a wrong command, and a record cannot name a weaker policy.
@(test)
hostile_records_sealed_by_the_tpm_are_refused :: proc(t: ^testing.T) {
	file := test_machine_tpm_file()
	good: [MACHINE_TPM_FILE_SIZE]u8
	machine_tpm_file_encode(&file, &good)
	expect :: proc(test: ^testing.T, bytes: []u8, wanted: File_Problem) {
		_, _, problem := machine_tpm_file_decode(bytes)
		testing.expect_value(test, problem, wanted)
	}
	expect(t, good[:MACHINE_TPM_FILE_SIZE - 1], .Wrong_Size)
	expect(t, nil, .Wrong_Size)
	changed := good
	changed[7] = 'K'
	expect(t, changed[:], .Wrong_Magic)
	changed = good
	changed[MACHINE_OFFSET_FORMAT] = u8(MACHINE_TPM_FORMAT + 1) // A format that this system does not know.
	expect(t, changed[:], .Wrong_Format)
	changed = good
	changed[MACHINE_TPM_OFFSET_PCRS] = 0x00 // PCR 11 only: no PCR 7.
	expect(t, changed[:], .Other_Parameters)
	changed = good
	changed[MACHINE_TPM_OFFSET_PUBLIC_BYTES] = u8(MACHINE_TPM_PUBLIC_LIMIT + 1) // Past the limit of the public area.
	expect(t, changed[:], .Bad_Area)
	changed = good
	changed[MACHINE_TPM_OFFSET_PUBLIC_BYTES] = u8(file.public_bytes - 1) // The size field counts one byte more than the record keeps.
	expect(t, changed[:], .Bad_Area)
	changed = good
	changed[MACHINE_TPM_OFFSET_PRIVATE + 1] += 1 // The size field counts one byte more than the record.
	expect(t, changed[:], .Bad_Area)
	changed = good
	changed[MACHINE_TPM_OFFSET_PUBLIC + file.public_bytes] = 1 // A byte after the public area.
	expect(t, changed[:], .Bad_Area)
	changed = good
	changed[MACHINE_TPM_OFFSET_PRIVATE + file.private_bytes] = 1 // A byte after the private area.
	expect(t, changed[:], .Bad_Area)
	changed = good
	// The first byte of the selection: after the size field, the count of
	// the selections, the hash and the size of the selection.
	changed[MACHINE_TPM_OFFSET_CREATION + 2 + 4 + 2 + 1] = 0x00 // A creation data with no PCR 7.
	expect(t, changed[:], .Bad_Area)
	changed = good
	changed[MACHINE_TPM_OFFSET_CREATION + file.creation_bytes] = 1 // A byte after the creation data.
	expect(t, changed[:], .Bad_Area)
	changed = good
	changed[MACHINE_TPM_OFFSET_TICKET + 1] ~= 0x01 // A ticket with another tag.
	expect(t, changed[:], .Bad_Area)
	changed = good
	changed[MACHINE_TPM_OFFSET_TICKET_BYTES] = u8(file.ticket_bytes - 1) // A ticket cut by one byte.
	expect(t, changed[:], .Bad_Area)
	changed = good
	changed[MACHINE_TPM_OFFSET_TICKET_BYTES] = u8(MACHINE_TPM_TICKET_LIMIT + 1) // Past the limit of the ticket.
	expect(t, changed[:], .Bad_Area)
	// A ticket with a digest of SHA-256: shorter, and of the same form.
	short := file
	short.creation_ticket[TICKET_DIGEST_SIZE_PLACE] = DIGEST_OF_SHA256
	short.ticket_bytes = TICKET_HEAD_SIZE + DIGEST_OF_SHA256
	for index in short.ticket_bytes ..< MACHINE_TPM_TICKET_LIMIT {
		short.creation_ticket[index] = 0
	}
	short_bytes: [MACHINE_TPM_FILE_SIZE]u8
	machine_tpm_file_encode(&short, &short_bytes)
	expect(t, short_bytes[:], .None)
	// The same with a byte after the ticket.
	short_bytes[MACHINE_TPM_OFFSET_TICKET + short.ticket_bytes] = 1
	expect(t, short_bytes[:], .Bad_Area)
	changed = good
	changed[MACHINE_OFFSET_FORMAT] = u8(MACHINE_TPM_FORMAT - 1) // The format before had no proof of the creation.
	expect(t, changed[:], .Wrong_Format)
	// A record of the machine passphrase is no record sealed by the TPM.
	passphrase_file := test_machine_file()
	passphrase_bytes: [MACHINE_FILE_SIZE]u8
	machine_file_encode(&passphrase_file, &passphrase_bytes)
	expect(t, passphrase_bytes[:], .Wrong_Size)
}

// The recovery key as its user reads it: base32 of RFC 4648 in groups of 4.
// "fooba" is "MZXW6YTB" in section 10 of the RFC.
@(test)
the_recovery_key_is_base32_in_groups :: proc(t: ^testing.T) {
	key: [RECOVERY_KEY_SIZE]u8
	copy(key[:], "foobafoobafoobafooba")
	text := recovery_key_text(&key)
	testing.expect_value(t, string(text[:]), "MZXW-6YTB-MZXW-6YTB-MZXW-6YTB-MZXW-6YTB")
	zero: [RECOVERY_KEY_SIZE]u8
	zero_text := recovery_key_text(&zero)
	testing.expect_value(t, string(zero_text[:]), "AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA-AAAA")
	full: [RECOVERY_KEY_SIZE]u8
	for &item in full {
		item = 0xFF
	}
	full_text := recovery_key_text(&full)
	testing.expect_value(t, string(full_text[:]), "7777-7777-7777-7777-7777-7777-7777-7777")

	// The parse takes the text back, in either case, with or without the
	// separators.
	parsed, problem := recovery_key_parse(text[:])
	testing.expect_value(t, problem, Recovery_Problem.None)
	testing.expect(t, parsed == key)
	lower := "mzxw6ytb mzxw6ytb mzxw6ytbmzxw6ytb"
	parsed, problem = recovery_key_parse(transmute([]u8)lower)
	testing.expect_value(t, problem, Recovery_Problem.None)
	testing.expect(t, parsed == key)
	// Each byte of the key changes the text.
	for index in 0 ..< RECOVERY_KEY_SIZE {
		other := key
		other[index] ~= 1
		other_text := recovery_key_text(&other)
		back, other_problem := recovery_key_parse(other_text[:])
		testing.expect_value(t, other_problem, Recovery_Problem.None)
		testing.expect(t, back == other)
		testing.expect(t, other_text != text)
	}
	// The refusals.
	one := "MZXW-6YTB-MZXW-6YTB-MZXW-6YTB-MZXW-6YT1"
	_, problem = recovery_key_parse(transmute([]u8)one)
	testing.expect_value(t, problem, Recovery_Problem.Bad_Character)
	short := "MZXW-6YTB-MZXW-6YTB-MZXW-6YTB-MZXW-6YT"
	_, problem = recovery_key_parse(transmute([]u8)short)
	testing.expect_value(t, problem, Recovery_Problem.Wrong_Length)
	long := "MZXW-6YTB-MZXW-6YTB-MZXW-6YTB-MZXW-6YTBA"
	_, problem = recovery_key_parse(transmute([]u8)long)
	testing.expect_value(t, problem, Recovery_Problem.Wrong_Length)
	_, problem = recovery_key_parse(nil)
	testing.expect_value(t, problem, Recovery_Problem.Wrong_Length)
}

// The key of the recovery seal and the key check: each use of a key has its
// own text, so the two results differ for the same bytes, and each one
// depends on the key.
@(test)
the_recovery_seal_key_and_the_key_check_differ :: proc(t: ^testing.T) {
	recovery: [RECOVERY_KEY_SIZE]u8
	machine_key: [MACHINE_KEY_SIZE]u8
	for index in 0 ..< RECOVERY_KEY_SIZE {
		recovery[index] = u8(index + 1)
		machine_key[index] = u8(index + 1)
	}
	seal_key := recovery_seal_key(&recovery)
	testing.expect(t, seal_key == recovery_seal_key(&recovery))
	check := machine_key_check(&machine_key)
	testing.expect(t, check == machine_key_check(&machine_key))
	testing.expect(t, seal_key != check)
	other_key := machine_key
	other_key[31] = 1
	testing.expect(t, machine_key_check(&other_key) != check)
	other_recovery := recovery
	other_recovery[0] = 0
	testing.expect(t, recovery_seal_key(&other_recovery) != seal_key)
	zero: [KEY_SIZE]u8
	testing.expect(t, check != zero)
}

test_principal_tpm_file :: proc() -> (file: Principal_Tpm_File) {
	principal := test_file()
	file.name, file.name_length = principal.name, principal.name_length
	file.identifier = principal.identifier
	file.signing_public_key, file.unlock_public_key = principal.signing_public_key, principal.unlock_public_key
	file.salt = principal.salt
	file.pcrs = tpm2.PCR_SET
	// The four parts of the record of the machine key: the same form.
	file.object = test_machine_tpm_file().object
	for index in 0 ..< NONCE_SIZE {
		file.nonce[index] = u8(60 + index)
		file.recovery_nonce[index] = u8(70 + index)
	}
	for index in 0 ..< SEALED_SIZE {
		file.sealed[index] = u8(index * 7 + 3)
		file.recovery_sealed[index] = u8(index * 11 + 5)
	}
	return file
}

@(test)
a_principal_file_sealed_by_the_tpm_round_trip :: proc(t: ^testing.T) {
	file := test_principal_tpm_file()
	bytes: [PRINCIPAL_TPM_FILE_SIZE]u8
	principal_tpm_file_encode(&file, &bytes)
	decoded, kept, problem := principal_tpm_file_decode(bytes[:])
	testing.expect_value(t, problem, File_Problem.None)
	testing.expect(t, decoded == file)
	testing.expect(t, kept == bytes)
	testing.expect_value(t, string(bytes[:8]), PRINCIPAL_TPM_MAGIC)
	// The offsets of the table of the guide (docs/PRINCIPALS.md).
	guide_offsets := [?][2]int {
		{OFFSET_IDENTIFIER, 44},
		{PRINCIPAL_TPM_OFFSET_PCRS, 156},
		{PRINCIPAL_TPM_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_PUBLIC, 168},
		{PRINCIPAL_TPM_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_PRIVATE, 296},
		{PRINCIPAL_TPM_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_CREATION, 552},
		{PRINCIPAL_TPM_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_TICKET, 808},
		{PRINCIPAL_TPM_OFFSET_NONCE, 880},
		{PRINCIPAL_TPM_OFFSET_SEALED, 892},
		{PRINCIPAL_TPM_OFFSET_RECOVERY_NONCE, 972},
		{PRINCIPAL_TPM_OFFSET_RECOVERY_SEALED, 984},
		{PRINCIPAL_TPM_FILE_SIZE, 1064},
	}
	for pair in guide_offsets {
		testing.expect_value(t, pair[0], pair[1])
	}
	// The first part has the form of the file under the passphrase alone.
	testing.expect_value(t, bytes[OFFSET_NAME_LENGTH], u8(file.name_length))
	testing.expect_value(t, bytes[OFFSET_SIGNING_PUBLIC_KEY], file.signing_public_key[0])
	testing.expect_value(t, bytes[OFFSET_SALT], file.salt[0])
	testing.expect_value(t, bytes[PRINCIPAL_TPM_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_PUBLIC + 2], file.public_area[2])
	testing.expect_value(t, bytes[PRINCIPAL_TPM_OFFSET_NONCE], file.nonce[0])
	testing.expect_value(t, bytes[PRINCIPAL_TPM_OFFSET_RECOVERY_SEALED + SEALED_SIZE - 1], file.recovery_sealed[SEALED_SIZE - 1])
	// The two seals cover their parts: the recovery seal stops before the
	// salt, so a new passphrase keeps it valid.
	testing.expect_value(t, len(principal_tpm_file_additional_data(&kept)), PRINCIPAL_TPM_OFFSET_PCRS)
	testing.expect_value(t, len(principal_tpm_file_recovery_additional_data(&kept)), OFFSET_SALT)
	// The form, by the first 8 bytes.
	testing.expect_value(t, principal_record_form(bytes[:]), Principal_Record_Form.Sealed_By_The_Tpm)
	principal := test_file()
	principal_bytes: [FILE_SIZE]u8
	file_encode(&principal, &principal_bytes)
	testing.expect_value(t, principal_record_form(principal_bytes[:]), Principal_Record_Form.Passphrase)
	testing.expect_value(t, principal_record_form(bytes[:7]), Principal_Record_Form.Unknown)
	testing.expect_value(t, principal_record_form(nil), Principal_Record_Form.Unknown)
	testing.expect(t, PRINCIPAL_FILE_LIMIT >= FILE_SIZE && PRINCIPAL_FILE_LIMIT >= PRINCIPAL_TPM_FILE_SIZE)
}

// The file is data from the disk: each field that the code trusts is
// checked, as in the two other forms.
@(test)
hostile_principal_files_sealed_by_the_tpm_are_refused :: proc(t: ^testing.T) {
	file := test_principal_tpm_file()
	good: [PRINCIPAL_TPM_FILE_SIZE]u8
	principal_tpm_file_encode(&file, &good)
	expect :: proc(test: ^testing.T, bytes: []u8, wanted: File_Problem) {
		_, _, problem := principal_tpm_file_decode(bytes)
		testing.expect_value(test, problem, wanted)
	}
	expect(t, good[:PRINCIPAL_TPM_FILE_SIZE - 1], .Wrong_Size)
	expect(t, nil, .Wrong_Size)
	changed := good
	changed[7] = 'L'
	expect(t, changed[:], .Wrong_Magic)
	changed = good
	changed[OFFSET_FORMAT] = u8(PRINCIPAL_TPM_FORMAT + 1) // A format that this system does not know.
	expect(t, changed[:], .Wrong_Format)
	changed = good
	changed[OFFSET_FORMAT] = u8(OLDER_PRINCIPAL_TPM_FORMAT)
	expect(t, changed[:], .Older_Format)
	changed = good
	for index in 0 ..< PRINCIPAL_IDENTIFIER_SIZE {
		changed[OFFSET_IDENTIFIER + index] = 0
	}
	expect(t, changed[:], .Zero_Identifier)
	changed = good
	changed[OFFSET_PASSES] = u8(DERIVATION_PASSES - 1) // A cheaper derivation.
	expect(t, changed[:], .Other_Parameters)
	changed = good
	changed[PRINCIPAL_TPM_OFFSET_PCRS] = 0x00 // PCR 11 only: no PCR 7.
	expect(t, changed[:], .Other_Parameters)
	changed = good
	changed[OFFSET_NAME_LENGTH] = NAME_LIMIT + 1
	expect(t, changed[:], .Bad_Name)
	changed = good
	changed[OFFSET_NAME + NAME_LIMIT - 1] = 'x'
	expect(t, changed[:], .Bytes_After_Name)
	changed = good
	changed[PRINCIPAL_TPM_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_PUBLIC_BYTES] = u8(tpm2.PUBLIC_AREA_LIMIT + 1) // Past the limit of the public area.
	expect(t, changed[:], .Bad_Area)
	changed = good
	changed[PRINCIPAL_TPM_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_PRIVATE + file.private_bytes] = 1 // A byte after the private area.
	expect(t, changed[:], .Bad_Area)
	changed = good
	changed[PRINCIPAL_TPM_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_TICKET + 1] ~= 0x01 // A ticket with another tag.
	expect(t, changed[:], .Bad_Area)
	// The other forms are no file sealed by the TPM.
	principal := test_file()
	principal_bytes: [FILE_SIZE]u8
	file_encode(&principal, &principal_bytes)
	expect(t, principal_bytes[:], .Wrong_Size)
	machine := test_machine_tpm_file()
	machine_bytes: [MACHINE_TPM_FILE_SIZE]u8
	machine_tpm_file_encode(&machine, &machine_bytes)
	expect(t, machine_bytes[:], .Wrong_Size)
}

// The keys of a named principal: each use has its own text, the seal key
// needs the TPM secret and the key of the passphrase together, and the
// recovery seal of a principal is not the recovery seal of the machine key.
@(test)
the_keys_of_a_principal_sealed_by_the_tpm_differ :: proc(t: ^testing.T) {
	passphrase_key: [KEY_SIZE]u8
	tpm_secret: [TPM_SECRET_SIZE]u8
	recovery: [RECOVERY_KEY_SIZE]u8
	for index in 0 ..< KEY_SIZE {
		passphrase_key[index] = u8(index + 1)
		tpm_secret[index] = u8(index + 1)
	}
	for index in 0 ..< RECOVERY_KEY_SIZE {
		recovery[index] = u8(index + 1)
	}
	authorization := principal_authorization_value(&passphrase_key)
	seal_key := principal_tpm_seal_key(&tpm_secret, &passphrase_key)
	testing.expect(t, seal_key == principal_tpm_seal_key(&tpm_secret, &passphrase_key))
	testing.expect(t, authorization != seal_key)
	other_secret := tpm_secret
	other_secret[0] ~= 1
	testing.expect(t, principal_tpm_seal_key(&other_secret, &passphrase_key) != seal_key)
	other_passphrase_key := passphrase_key
	other_passphrase_key[KEY_SIZE - 1] ~= 1
	testing.expect(t, principal_tpm_seal_key(&tpm_secret, &other_passphrase_key) != seal_key)
	testing.expect(t, principal_authorization_value(&other_passphrase_key) != authorization)
	testing.expect(t, principal_recovery_seal_key(&recovery) != recovery_seal_key(&recovery))
	testing.expect_value(t, len(authorization), tpm2.AUTHORIZATION_VALUE_SIZE)
}

// Which change a file takes: a new recovery key needs a copy under a
// recovery key, the form PRINCIPT needs the TPM for the proof, and only a
// new seal by the TPM needs the right to seal.
@(test)
the_changes_that_a_file_takes :: proc(t: ^testing.T) {
	cases := [?]struct {
		form:         Principal_Record_Form,
		mode:         Unlock_Mode,
		has_tpm:      bool,
		seal_allowed: bool,
		problem:      Change_Problem,
	} {
		// The modes of unlock that are no change come first: each is refused.
		{.Sealed_By_The_Tpm, .Unlock, true, true, .Unknown_Change},
		{.Sealed_By_The_Tpm, .Unlock_Machine_Key_Held, true, true, .Unknown_Change},
		{.Sealed_By_The_Tpm, .Create_Principal, true, true, .Unknown_Change},
		{.Passphrase, .Set_Machine_Passphrase, true, true, .Unknown_Change},
		{.Passphrase, .Seal_Machine_Key, true, true, .Unknown_Change},
		{.Sealed_By_The_Tpm, .Machine_Key_Without_Window, true, true, .Unknown_Change},
		{.Unknown, .Change_Passphrase, true, true, .Unknown_Form},
		{.Unknown, .New_Recovery_Key, false, false, .Unknown_Form},
		{.Sealed_By_The_Tpm, .Change_Passphrase, true, false, .Seal_Not_Allowed},
		{.Sealed_By_The_Tpm, .Change_Passphrase, false, true, .No_Tpm_Service},
		{.Sealed_By_The_Tpm, .New_Recovery_Key, false, true, .No_Tpm_Service},
		{.Passphrase, .New_Recovery_Key, true, true, .None},
		{.Passphrase, .New_Recovery_Key, false, false, .None},
		{.Sealed_By_The_Tpm, .Change_Passphrase, true, true, .None},
		{.Sealed_By_The_Tpm, .New_Recovery_Key, true, true, .None},
		// A new recovery key seals nothing by the TPM.
		{.Sealed_By_The_Tpm, .New_Recovery_Key, true, false, .None},
		// The form under the passphrase alone needs no TPM.
		{.Passphrase, .Change_Passphrase, false, false, .None},
		{.Passphrase, .Change_Passphrase, true, true, .None},
	}
	for item in cases {
		testing.expect_value(t, change_problem(item.form, item.mode, item.has_tpm, item.seal_allowed), item.problem)
	}
	for problem in Change_Problem {
		testing.expect(t, len(change_problem_sentences[problem]) > 0)
	}
	// The window of unlock shows the sentence of an end on one line of
	// 63 cells after its margin: no sentence is cut.
	WINDOW_LINE_CELLS :: 63
	for end in Change_End {
		testing.expect(t, len(change_end_sentences[end]) > 0)
		testing.expect(t, len(change_end_sentences[end]) <= WINDOW_LINE_CELLS)
	}
}

// The word of VALUE_MODE crosses the border of the context: each word that
// names no mode is refused, then each mode comes back from its own word.
@(test)
the_word_of_the_mode_of_unlock :: proc(t: ^testing.T) {
	refused := [?]u64{u64(max(Unlock_Mode)) + 1, u64(max(Unlock_Mode)) + 2, 1 << 32, max(u64)}
	for word in refused {
		_, ok := unlock_mode_of_word(word)
		testing.expectf(t, !ok, "the word %d names no mode, and it is taken", word)
	}
	for mode in Unlock_Mode {
		read, ok := unlock_mode_of_word(u64(mode))
		testing.expect(t, ok)
		testing.expect_value(t, read, mode)
	}
}

// The prompt of an unlock offers the recovery key at once only for a file
// that has a copy under one, and only when it asks for the passphrase.
@(test)
the_prompts_that_offer_the_recovery_key :: proc(t: ^testing.T) {
	cases := [?]struct {
		form:    Principal_Record_Form,
		has_tpm: bool,
		offered: bool,
	} {
		{.Sealed_By_The_Tpm, true, true},
		// With no TPM service the prompt asks for the recovery key already.
		{.Sealed_By_The_Tpm, false, false},
		// The form under the passphrase alone has no recovery key.
		{.Passphrase, true, false},
		{.Passphrase, false, false},
		{.Unknown, true, false},
	}
	for item in cases {
		testing.expect_value(t, recovery_key_offered_at_unlock(item.form, item.has_tpm), item.offered)
	}
}

// Principal-number guard on passphrase/recovery changes: principal 0 and any
// number at or past PRINCIPAL_CAPACITY are refused, and a loaded file of
// another principal never matches.
@(test)
change_principal_guard_refuses_invalid_and_mismatched_principals :: proc(t: ^testing.T) {
	invalid_numbers := [?]u64{MACHINE, PRINCIPAL_CAPACITY, PRINCIPAL_CAPACITY + 1, 1 << 32, max(u64)}
	for bad in invalid_numbers {
		testing.expect(t, !change_principal_valid(bad))
		testing.expect(t, !change_principal_matches(bad, bad))
		testing.expect(t, !change_principal_matches(bad, 1))
		testing.expect(t, !change_principal_matches(1, bad))
	}
	testing.expect(t, change_principal_valid(1))
	testing.expect(t, change_principal_matches(1, 1))
}

// Helper: builds a genuine sealed PRINCIPL record with derived Ed25519 and
// X25519 public keys and ChaCha20-Poly1305 ciphertext under passphrase_key.
test_sealed_principl_record :: proc(
	name: string,
	secrets: ^[SECRET_KEYS_SIZE]u8,
	passphrase_key: ^[KEY_SIZE]u8,
) -> (bytes: [FILE_SIZE]u8) {
	file: Principal_File
	file.name_length = copy(file.name[:], name)
	file.identifier = test_file().identifier
	signing, unlocking, ok := secret_keys_public_keys(secrets)
	assert(ok)
	file.signing_public_key = signing
	file.unlock_public_key = unlocking
	for index in 0 ..< SALT_SIZE {
		file.salt[index] = u8(0x21 + index)
	}
	for index in 0 ..< NONCE_SIZE {
		file.nonce[index] = u8(0x41 + index)
	}
	file_encode(&file, &bytes)
	key_text := string(passphrase_key^[:])
	nonce_text := string(file.nonce[:])
	additional := string(file_additional_data(&bytes))
	plain_text := string(secrets^[:])
	sealed_slice := file.sealed[:]
	error: errors.Error_Record
	_, count := cryptography_primitives.seal_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &plain_text, &sealed_slice, &error)
	assert(count == SEALED_SIZE)
	file_encode(&file, &bytes)
	return bytes
}

// Adversarial tests for record_open_verify: corrupted, truncated, wrong-key,
// mismatched-secret, and mismatched-public-key PRINCIPL records are refused,
// while a genuine round-trip record passes.
@(test)
record_open_verify_refuses_corrupted_and_mismatched_records :: proc(t: ^testing.T) {
	secrets: [SECRET_KEYS_SIZE]u8
	passphrase_key: [KEY_SIZE]u8
	for index in 0 ..< SECRET_KEYS_SIZE {
		secrets[index] = u8(0x11 + index * 3)
	}
	for index in 0 ..< KEY_SIZE {
		passphrase_key[index] = u8(0x71 + index * 5)
	}
	good := test_sealed_principl_record("alice", &secrets, &passphrase_key)

	// Nil pointers and all-zero expected secrets are refused.
	zero_secrets: [SECRET_KEYS_SIZE]u8
	testing.expect_value(t, record_open_verify(good[:], nil, &secrets), Record_Verify_Problem.Bad_Arguments)
	testing.expect_value(t, record_open_verify(good[:], &passphrase_key, nil), Record_Verify_Problem.Bad_Arguments)
	testing.expect_value(t, record_open_verify(good[:], &passphrase_key, &zero_secrets), Record_Verify_Problem.Bad_Arguments)

	// Wrong sizes (0, 1, FILE_SIZE - 1, FILE_SIZE + 1) are refused.
	oversized: [FILE_SIZE + 1]u8
	copy(oversized[:], good[:])
	testing.expect_value(t, record_open_verify(nil, &passphrase_key, &secrets), Record_Verify_Problem.Decode_Failed)
	testing.expect_value(t, record_open_verify(good[:1], &passphrase_key, &secrets), Record_Verify_Problem.Decode_Failed)
	testing.expect_value(t, record_open_verify(good[:FILE_SIZE - 1], &passphrase_key, &secrets), Record_Verify_Problem.Decode_Failed)
	testing.expect_value(t, record_open_verify(oversized[:], &passphrase_key, &secrets), Record_Verify_Problem.Decode_Failed)

	// Wrong passphrase key fails decryption.
	wrong_key := passphrase_key
	wrong_key[0] ~= 0x01
	testing.expect_value(t, record_open_verify(good[:], &wrong_key, &secrets), Record_Verify_Problem.Open_Failed)

	// Flipping any single bit across the entire 216-byte record fails verification.
	for byte_index in 0 ..< FILE_SIZE {
		tampered := good
		tampered[byte_index] ~= 0x80
		problem := record_open_verify(tampered[:], &passphrase_key, &secrets)
		testing.expectf(t, problem != .None, "bit flip at byte %d unexpectedly passed record_open_verify", byte_index)
	}

	// A validly encrypted record holding different secrets is refused with Secrets_Mismatch.
	other_secrets := secrets
	other_secrets[0] ~= 0x01
	other_record := test_sealed_principl_record("alice", &other_secrets, &passphrase_key)
	testing.expect_value(t, record_open_verify(other_record[:], &passphrase_key, &secrets), Record_Verify_Problem.Secrets_Mismatch)

	// A validly encrypted record whose header public keys do not match its secrets is refused.
	wrong_pub_file, _, decode_prob := file_decode(good[:])
	testing.expect_value(t, decode_prob, File_Problem.None)
	wrong_pub_file.signing_public_key[0] ~= 0x01
	wrong_pub_bytes: [FILE_SIZE]u8
	file_encode(&wrong_pub_file, &wrong_pub_bytes)
	key_text := string(passphrase_key[:])
	nonce_text := string(wrong_pub_file.nonce[:])
	additional := string(file_additional_data(&wrong_pub_bytes))
	plain_text := string(secrets[:])
	sealed_slice := wrong_pub_file.sealed[:]
	error: errors.Error_Record
	_, count := cryptography_primitives.seal_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &plain_text, &sealed_slice, &error)
	testing.expect_value(t, count, i64(SEALED_SIZE))
	file_encode(&wrong_pub_file, &wrong_pub_bytes)
	testing.expect_value(t, record_open_verify(wrong_pub_bytes[:], &passphrase_key, &secrets), Record_Verify_Problem.Public_Key_Wrong)

	// The genuine sealed record passes verification.
	testing.expect_value(t, record_open_verify(good[:], &passphrase_key, &secrets), Record_Verify_Problem.None)
}

// Exhaustive adversarial tests for non-TPM principal recovery key seal/open:
// round-trip, wrong recovery key, empty/zero recovery key, wrong principal
// number, bit-flip tamper across all 200 bytes, size edges, and forged
// mismatched public keys.
@(test)
non_tpm_recovery_seal_and_open_enforces_strict_borders :: proc(t: ^testing.T) {
	secrets: [SECRET_KEYS_SIZE]u8
	recovery_key: [RECOVERY_KEY_SIZE]u8
	nonce: [NONCE_SIZE]u8
	for index in 0 ..< SECRET_KEYS_SIZE {
		secrets[index] = u8(0x33 + index * 7)
	}
	for index in 0 ..< RECOVERY_KEY_SIZE {
		recovery_key[index] = u8(0xA1 + index * 3)
	}
	for index in 0 ..< NONCE_SIZE {
		nonce[index] = u8(0x55 + index)
	}

	zero_recovery: [RECOVERY_KEY_SIZE]u8
	zero_nonce: [NONCE_SIZE]u8
	zero_secrets: [SECRET_KEYS_SIZE]u8
	record_bytes: [NON_TPM_RECOVERY_SIZE]u8

	// Seal border refusals first.
	testing.expect_value(t, non_tpm_recovery_seal(1, "alice", nil, &recovery_key, &nonce, &record_bytes), Non_Tpm_Recovery_Problem.Bad_Arguments)
	testing.expect_value(t, non_tpm_recovery_seal(1, "alice", &secrets, nil, &nonce, &record_bytes), Non_Tpm_Recovery_Problem.Bad_Arguments)
	testing.expect_value(t, non_tpm_recovery_seal(1, "alice", &secrets, &recovery_key, nil, &record_bytes), Non_Tpm_Recovery_Problem.Bad_Arguments)
	testing.expect_value(t, non_tpm_recovery_seal(1, "alice", &secrets, &recovery_key, &nonce, nil), Non_Tpm_Recovery_Problem.Bad_Arguments)
	testing.expect_value(t, non_tpm_recovery_seal(MACHINE, "alice", &secrets, &recovery_key, &nonce, &record_bytes), Non_Tpm_Recovery_Problem.Bad_Principal)
	testing.expect_value(t, non_tpm_recovery_seal(1, "", &secrets, &recovery_key, &nonce, &record_bytes), Non_Tpm_Recovery_Problem.Bad_Name)
	testing.expect_value(t, non_tpm_recovery_seal(1, "bad name!", &secrets, &recovery_key, &nonce, &record_bytes), Non_Tpm_Recovery_Problem.Bad_Name)
	testing.expect_value(t, non_tpm_recovery_seal(1, "alice", &secrets, &zero_recovery, &nonce, &record_bytes), Non_Tpm_Recovery_Problem.Empty_Recovery_Key)
	testing.expect_value(t, non_tpm_recovery_seal(1, "alice", &secrets, &recovery_key, &zero_nonce, &record_bytes), Non_Tpm_Recovery_Problem.Bad_Nonce)
	testing.expect_value(t, non_tpm_recovery_seal(1, "alice", &zero_secrets, &recovery_key, &nonce, &record_bytes), Non_Tpm_Recovery_Problem.Bad_Keys)

	// Genuine seal for principal 1.
	testing.expect_value(t, non_tpm_recovery_seal(1, "alice", &secrets, &recovery_key, &nonce, &record_bytes), Non_Tpm_Recovery_Problem.None)

	// Open border refusals: nil pointers, principal 0, empty/zero recovery key,
	// wrong principal number, wrong recovery key, size edges.
	opened_secrets: [SECRET_KEYS_SIZE]u8
	opened_secrets[0] = 0xFF
	_, prob := non_tpm_recovery_open(record_bytes[:], nil, 1, &opened_secrets)
	testing.expect_value(t, prob, Non_Tpm_Recovery_Problem.Bad_Arguments)
	testing.expect(t, opened_secrets == zero_secrets)

	_, prob = non_tpm_recovery_open(record_bytes[:], &recovery_key, 1, nil)
	testing.expect_value(t, prob, Non_Tpm_Recovery_Problem.Bad_Arguments)

	opened_secrets[0] = 0xFF
	_, prob = non_tpm_recovery_open(record_bytes[:], &recovery_key, MACHINE, &opened_secrets)
	testing.expect_value(t, prob, Non_Tpm_Recovery_Problem.Bad_Principal)
	testing.expect(t, opened_secrets == zero_secrets)

	opened_secrets[0] = 0xFF
	_, prob = non_tpm_recovery_open(record_bytes[:], &zero_recovery, 1, &opened_secrets)
	testing.expect_value(t, prob, Non_Tpm_Recovery_Problem.Empty_Recovery_Key)
	testing.expect(t, opened_secrets == zero_secrets)

	// Wrong expected principal number refused.
	opened_secrets[0] = 0xFF
	_, prob = non_tpm_recovery_open(record_bytes[:], &recovery_key, 2, &opened_secrets)
	testing.expect_value(t, prob, Non_Tpm_Recovery_Problem.Wrong_Principal)
	testing.expect(t, opened_secrets == zero_secrets)

	// Rewriting principal_number in the header to 2 and requesting 2 fails AEAD + KDF binding.
	rewritten_principal := record_bytes
	byte_order.write_u64_little_endian(rewritten_principal[NON_TPM_RECOVERY_OFFSET_PRINCIPAL:], 0, 2)
	opened_secrets[0] = 0xFF
	_, prob = non_tpm_recovery_open(rewritten_principal[:], &recovery_key, 2, &opened_secrets)
	testing.expect_value(t, prob, Non_Tpm_Recovery_Problem.Not_Authentic)
	testing.expect(t, opened_secrets == zero_secrets)

	// Wrong recovery key (1-bit flip) refused and leaves out_secrets zeroed.
	wrong_recovery := recovery_key
	wrong_recovery[RECOVERY_KEY_SIZE - 1] ~= 0x01
	opened_secrets[0] = 0xFF
	_, prob = non_tpm_recovery_open(record_bytes[:], &wrong_recovery, 1, &opened_secrets)
	testing.expect_value(t, prob, Non_Tpm_Recovery_Problem.Not_Authentic)
	testing.expect(t, opened_secrets == zero_secrets)

	// Size edges: 0, 1, NON_TPM_RECOVERY_SIZE - 1, NON_TPM_RECOVERY_SIZE + 1.
	oversized: [NON_TPM_RECOVERY_SIZE + 1]u8
	copy(oversized[:], record_bytes[:])
	_, prob = non_tpm_recovery_open(nil, &recovery_key, 1, &opened_secrets)
	testing.expect_value(t, prob, Non_Tpm_Recovery_Problem.Wrong_Size)
	_, prob = non_tpm_recovery_open(record_bytes[:1], &recovery_key, 1, &opened_secrets)
	testing.expect_value(t, prob, Non_Tpm_Recovery_Problem.Wrong_Size)
	_, prob = non_tpm_recovery_open(record_bytes[:NON_TPM_RECOVERY_SIZE - 1], &recovery_key, 1, &opened_secrets)
	testing.expect_value(t, prob, Non_Tpm_Recovery_Problem.Wrong_Size)
	_, prob = non_tpm_recovery_open(oversized[:], &recovery_key, 1, &opened_secrets)
	testing.expect_value(t, prob, Non_Tpm_Recovery_Problem.Wrong_Size)

	// Bit-flip tamper sweep across EVERY SINGLE byte of the 200-byte record.
	for byte_index in 0 ..< NON_TPM_RECOVERY_SIZE {
		tampered := record_bytes
		tampered[byte_index] ~= 0x01
		opened_secrets[0] = 0xFF
		_, tamper_prob := non_tpm_recovery_open(tampered[:], &recovery_key, 1, &opened_secrets)
		testing.expectf(t, tamper_prob != .None, "tamper at byte %d unexpectedly opened", byte_index)
		testing.expect(t, opened_secrets == zero_secrets)
	}

	// Forged valid AEAD ciphertext whose decrypted secrets do not derive the
	// header's public keys must be refused with Keys_Mismatch.
	forged := record_bytes
	forged[NON_TPM_RECOVERY_OFFSET_SIGNING_PUBLIC_KEY] ~= 0x01
	aead_key: [KEY_SIZE]u8
	testing.expect(t, non_tpm_recovery_derive_key(&recovery_key, 1, &aead_key))
	key_text := string(aead_key[:])
	nonce_text := string(nonce[:])
	additional := string(forged[:NON_TPM_RECOVERY_OFFSET_SEALED])
	plain_text := string(secrets[:])
	sealed_slice := forged[NON_TPM_RECOVERY_OFFSET_SEALED:][:SEALED_SIZE]
	error: errors.Error_Record
	_, count := cryptography_primitives.seal_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &plain_text, &sealed_slice, &error)
	testing.expect_value(t, count, i64(SEALED_SIZE))
	opened_secrets[0] = 0xFF
	_, prob = non_tpm_recovery_open(forged[:], &recovery_key, 1, &opened_secrets)
	testing.expect_value(t, prob, Non_Tpm_Recovery_Problem.Keys_Mismatch)
	testing.expect(t, opened_secrets == zero_secrets)

	// Genuine round-trip open succeeds and recovers the exact secret keys and metadata.
	decoded, ok_prob := non_tpm_recovery_open(record_bytes[:], &recovery_key, 1, &opened_secrets)
	testing.expect_value(t, ok_prob, Non_Tpm_Recovery_Problem.None)
	testing.expect(t, opened_secrets == secrets)
	testing.expect_value(t, decoded.principal_number, u64(1))
	testing.expect_value(t, string(decoded.name[:decoded.name_length]), "alice")
	expected_signing, expected_unlock, derived_ok := secret_keys_public_keys(&secrets)
	testing.expect(t, derived_ok)
	testing.expect(t, decoded.signing_public_key == expected_signing)
	testing.expect(t, decoded.unlock_public_key == expected_unlock)

	// Round-trip at edge principal number max(u64) also works cleanly.
	max_record: [NON_TPM_RECOVERY_SIZE]u8
	testing.expect_value(t, non_tpm_recovery_seal(max(u64), "bob", &secrets, &recovery_key, &nonce, &max_record), Non_Tpm_Recovery_Problem.None)
	max_opened: [SECRET_KEYS_SIZE]u8
	max_decoded, max_prob := non_tpm_recovery_open(max_record[:], &recovery_key, max(u64), &max_opened)
	testing.expect_value(t, max_prob, Non_Tpm_Recovery_Problem.None)
	testing.expect(t, max_opened == secrets)
	testing.expect_value(t, max_decoded.principal_number, max(u64))
	testing.expect_value(t, string(max_decoded.name[:max_decoded.name_length]), "bob")
}

// The line of a lock names what the `unlock` that it stops ran for: each
// mode that a session can ask for has words of its own, and a mode that
// only unlocks says so. A word that names no mode never reaches the words:
// the border refuses it (the_word_of_the_mode_of_unlock).
@(test)
the_words_of_each_mode_of_unlock :: proc(t: ^testing.T) {
	asked := [?]Unlock_Mode{.Create_Principal, .Set_Machine_Passphrase, .Seal_Machine_Key, .Change_Passphrase, .New_Recovery_Key, .Machine_Key_Without_Window}
	for mode, index in asked {
		testing.expect(t, mode_words(mode) != mode_words(.Unlock))
		for other in asked[index + 1:] {
			testing.expect(t, mode_words(mode) != mode_words(other))
		}
	}
	testing.expect_value(t, mode_words(.Unlock_Machine_Key_Held), mode_words(.Unlock))
}

// A new recovery key changes only the copy under the recovery key: the two
// additional data stay, so the seal under the seal key still opens, and a
// new passphrase keeps the copy under the recovery key.
@(test)
a_new_recovery_key_keeps_the_seal_of_the_passphrase :: proc(t: ^testing.T) {
	file := test_principal_tpm_file()
	before: [PRINCIPAL_TPM_FILE_SIZE]u8
	principal_tpm_file_encode(&file, &before)
	renewed := file
	for index in 0 ..< NONCE_SIZE {
		renewed.recovery_nonce[index] ~= 0xff
	}
	for index in 0 ..< SEALED_SIZE {
		renewed.recovery_sealed[index] ~= 0xff
	}
	after: [PRINCIPAL_TPM_FILE_SIZE]u8
	principal_tpm_file_encode(&renewed, &after)
	testing.expect(t, string(principal_tpm_file_additional_data(&before)) == string(principal_tpm_file_additional_data(&after)))
	testing.expect(t, string(principal_tpm_file_recovery_additional_data(&before)) == string(principal_tpm_file_recovery_additional_data(&after)))
	// Each byte before the copy under the recovery key stays.
	testing.expect(t, string(before[:PRINCIPAL_TPM_OFFSET_RECOVERY_NONCE]) == string(after[:PRINCIPAL_TPM_OFFSET_RECOVERY_NONCE]))
	testing.expect(t, string(before[PRINCIPAL_TPM_OFFSET_RECOVERY_NONCE:]) != string(after[PRINCIPAL_TPM_OFFSET_RECOVERY_NONCE:]))
	_, _, problem := principal_tpm_file_decode(after[:])
	testing.expect_value(t, problem, File_Problem.None)
	// A new salt changes the additional data of the seal under the seal
	// key, and not the one of the copy under the recovery key.
	salted := file
	salted.salt[0] ~= 1
	salted_bytes: [PRINCIPAL_TPM_FILE_SIZE]u8
	principal_tpm_file_encode(&salted, &salted_bytes)
	testing.expect(t, string(principal_tpm_file_additional_data(&before)) != string(principal_tpm_file_additional_data(&salted_bytes)))
	testing.expect(t, string(principal_tpm_file_recovery_additional_data(&before)) == string(principal_tpm_file_recovery_additional_data(&salted_bytes)))
}

test_machine_tpm_passphrase_file :: proc() -> (file: Machine_Tpm_Passphrase_File) {
	file.salt = test_machine_file().salt
	file.pcrs = tpm2.PCR_SET
	// The four parts of the record of the machine key: the same form.
	file.object = test_machine_tpm_file().object
	for index in 0 ..< NONCE_SIZE {
		file.nonce[index] = u8(110 + index)
		file.recovery_nonce[index] = u8(130 + index)
	}
	for index in 0 ..< MACHINE_SEALED_SIZE {
		file.sealed[index] = u8(index * 13 + 7)
		file.recovery_sealed[index] = u8(index * 17 + 9)
	}
	return file
}

@(test)
a_record_sealed_by_the_tpm_with_the_machine_passphrase_round_trip :: proc(t: ^testing.T) {
	file := test_machine_tpm_passphrase_file()
	bytes: [MACHINE_TPM_PASSPHRASE_FILE_SIZE]u8
	machine_tpm_passphrase_file_encode(&file, &bytes)
	decoded, kept, problem := machine_tpm_passphrase_file_decode(bytes[:])
	testing.expect_value(t, problem, File_Problem.None)
	testing.expect(t, decoded == file)
	testing.expect(t, kept == bytes)
	testing.expect_value(t, string(bytes[:8]), MACHINE_TPM_PASSPHRASE_MAGIC)
	// The offsets of the table of the guide (docs/PRINCIPALS.md).
	guide_offsets := [?][2]int {
		{MACHINE_OFFSET_SALT, 20},
		{MACHINE_TPM_PASSPHRASE_OFFSET_PCRS, 36},
		{MACHINE_TPM_PASSPHRASE_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_PUBLIC_BYTES, 40},
		{MACHINE_TPM_PASSPHRASE_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_PUBLIC, 48},
		{MACHINE_TPM_PASSPHRASE_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_PRIVATE, 176},
		{MACHINE_TPM_PASSPHRASE_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_CREATION, 432},
		{MACHINE_TPM_PASSPHRASE_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_TICKET, 688},
		{MACHINE_TPM_PASSPHRASE_OFFSET_NONCE, 760},
		{MACHINE_TPM_PASSPHRASE_OFFSET_SEALED, 772},
		{MACHINE_TPM_PASSPHRASE_OFFSET_RECOVERY_NONCE, 820},
		{MACHINE_TPM_PASSPHRASE_OFFSET_RECOVERY_SEALED, 832},
		{MACHINE_TPM_PASSPHRASE_FILE_SIZE, 880},
	}
	for pair in guide_offsets {
		testing.expect_value(t, pair[0], pair[1])
	}
	// Each field at its offset.
	testing.expect_value(t, bytes[MACHINE_OFFSET_FORMAT], u8(MACHINE_TPM_PASSPHRASE_FORMAT))
	testing.expect_value(t, bytes[MACHINE_OFFSET_SALT], file.salt[0])
	testing.expect_value(t, bytes[MACHINE_TPM_PASSPHRASE_OFFSET_PCRS], u8(0x80)) // PCR 7 and PCR 11: 0x880, little-endian.
	testing.expect_value(t, bytes[MACHINE_TPM_PASSPHRASE_OFFSET_PCRS + 1], u8(0x08))
	testing.expect_value(t, bytes[MACHINE_TPM_PASSPHRASE_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_PUBLIC + 2], file.public_area[2])
	testing.expect_value(t, bytes[MACHINE_TPM_PASSPHRASE_OFFSET_NONCE], file.nonce[0])
	testing.expect_value(t, bytes[MACHINE_TPM_PASSPHRASE_OFFSET_SEALED], file.sealed[0])
	testing.expect_value(t, bytes[MACHINE_TPM_PASSPHRASE_OFFSET_RECOVERY_NONCE], file.recovery_nonce[0])
	testing.expect_value(t, bytes[MACHINE_TPM_PASSPHRASE_OFFSET_RECOVERY_SEALED + MACHINE_SEALED_SIZE - 1], file.recovery_sealed[MACHINE_SEALED_SIZE - 1])
	// The first bytes have the form of the record under the passphrase
	// alone, to the salt.
	alone := test_machine_file()
	alone_bytes: [MACHINE_FILE_SIZE]u8
	machine_file_encode(&alone, &alone_bytes)
	testing.expect(t, string(bytes[MACHINE_OFFSET_MEMORY:MACHINE_OFFSET_NONCE]) == string(alone_bytes[MACHINE_OFFSET_MEMORY:MACHINE_OFFSET_NONCE]))
	// The two seals cover their parts: the recovery seal stops before the
	// salt, so a new passphrase keeps it valid.
	testing.expect_value(t, len(machine_tpm_passphrase_file_additional_data(&kept)), MACHINE_TPM_PASSPHRASE_OFFSET_PCRS)
	testing.expect_value(t, len(machine_tpm_passphrase_file_recovery_additional_data(&kept)), MACHINE_OFFSET_SALT)
	// The form, by the first 8 bytes, and the read of each form fits.
	testing.expect_value(t, machine_record_form(bytes[:]), Machine_Record_Form.Sealed_By_The_Tpm_With_Passphrase)
	testing.expect(t, MACHINE_RECORD_LIMIT >= MACHINE_FILE_SIZE && MACHINE_RECORD_LIMIT >= MACHINE_TPM_FILE_SIZE && MACHINE_RECORD_LIMIT >= MACHINE_TPM_PASSPHRASE_FILE_SIZE)
}

// The record is data from the disk: each field that the code trusts is
// checked, as in the two other forms.
@(test)
hostile_records_sealed_by_the_tpm_with_the_machine_passphrase_are_refused :: proc(t: ^testing.T) {
	file := test_machine_tpm_passphrase_file()
	good: [MACHINE_TPM_PASSPHRASE_FILE_SIZE]u8
	machine_tpm_passphrase_file_encode(&file, &good)
	expect :: proc(test: ^testing.T, bytes: []u8, wanted: File_Problem) {
		_, _, problem := machine_tpm_passphrase_file_decode(bytes)
		testing.expect_value(test, problem, wanted)
	}
	expect(t, good[:MACHINE_TPM_PASSPHRASE_FILE_SIZE - 1], .Wrong_Size)
	expect(t, nil, .Wrong_Size)
	changed := good
	changed[7] = 'T'
	expect(t, changed[:], .Wrong_Magic)
	changed = good
	changed[MACHINE_OFFSET_FORMAT] = u8(MACHINE_TPM_PASSPHRASE_FORMAT + 1) // A format that this system does not know.
	expect(t, changed[:], .Wrong_Format)
	changed = good
	changed[MACHINE_OFFSET_PASSES] = u8(DERIVATION_PASSES - 1) // A cheaper derivation.
	expect(t, changed[:], .Other_Parameters)
	changed = good
	changed[MACHINE_OFFSET_MEMORY] = 8 // Less memory for the derivation.
	expect(t, changed[:], .Other_Parameters)
	changed = good
	changed[MACHINE_TPM_PASSPHRASE_OFFSET_PCRS] = 0x00 // PCR 11 only: no PCR 7.
	expect(t, changed[:], .Other_Parameters)
	changed = good
	changed[MACHINE_TPM_PASSPHRASE_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_PUBLIC_BYTES] = u8(tpm2.PUBLIC_AREA_LIMIT + 1) // Past the limit of the public area.
	expect(t, changed[:], .Bad_Area)
	changed = good
	changed[MACHINE_TPM_PASSPHRASE_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_PRIVATE + file.private_bytes] = 1 // A byte after the private area.
	expect(t, changed[:], .Bad_Area)
	changed = good
	changed[MACHINE_TPM_PASSPHRASE_OFFSET_SEALED_OBJECT + SEALED_OBJECT_OFFSET_TICKET + 1] ~= 0x01 // A ticket with another tag.
	expect(t, changed[:], .Bad_Area)
	// The other forms are no record of this form.
	alone := test_machine_file()
	alone_bytes: [MACHINE_FILE_SIZE]u8
	machine_file_encode(&alone, &alone_bytes)
	expect(t, alone_bytes[:], .Wrong_Size)
	tpm_alone := test_machine_tpm_file()
	tpm_alone_bytes: [MACHINE_TPM_FILE_SIZE]u8
	machine_tpm_file_encode(&tpm_alone, &tpm_alone_bytes)
	expect(t, tpm_alone_bytes[:], .Wrong_Size)
	// And this form is no record of the two others.
	_, _, alone_problem := machine_file_decode(good[:])
	testing.expect_value(t, alone_problem, File_Problem.Wrong_Size)
	_, _, tpm_alone_problem := machine_tpm_file_decode(good[:])
	testing.expect_value(t, tpm_alone_problem, File_Problem.Wrong_Size)
}

// The keys of the machine passphrase with the TPM: each use has its own
// text, the seal key needs the TPM secret and the key of the passphrase
// together, and neither is a key of a named principal for the same
// passphrase and secret.
@(test)
the_keys_of_the_machine_passphrase_with_the_tpm_differ :: proc(t: ^testing.T) {
	passphrase_key: [KEY_SIZE]u8
	tpm_secret: [TPM_SECRET_SIZE]u8
	for index in 0 ..< KEY_SIZE {
		passphrase_key[index] = u8(index + 1)
		tpm_secret[index] = u8(index + 1)
	}
	authorization := machine_authorization_value(&passphrase_key)
	seal_key := machine_tpm_passphrase_seal_key(&tpm_secret, &passphrase_key)
	testing.expect(t, seal_key == machine_tpm_passphrase_seal_key(&tpm_secret, &passphrase_key))
	testing.expect(t, authorization != seal_key)
	other_secret := tpm_secret
	other_secret[0] ~= 1
	testing.expect(t, machine_tpm_passphrase_seal_key(&other_secret, &passphrase_key) != seal_key)
	other_passphrase_key := passphrase_key
	other_passphrase_key[KEY_SIZE - 1] ~= 1
	testing.expect(t, machine_tpm_passphrase_seal_key(&tpm_secret, &other_passphrase_key) != seal_key)
	testing.expect(t, machine_authorization_value(&other_passphrase_key) != authorization)
	// Not the keys of a named principal.
	testing.expect(t, principal_authorization_value(&passphrase_key) != authorization)
	testing.expect(t, principal_tpm_seal_key(&tpm_secret, &passphrase_key) != seal_key)
	testing.expect_value(t, len(authorization), tpm2.AUTHORIZATION_VALUE_SIZE)
}

// A new passphrase after a recovery changes the salt, the parts and the
// seal under the seal key: the additional data of the copy under the
// recovery key stays, so that copy still opens.
// The proof of a wide grant: a principal past the table, no record, a
// file of another principal, a machine key that the TPM alone seals, and a
// record of the TPM with no TPM service each refuse the proof; principal 0
// with a machine passphrase, alone or with the TPM, and a named principal
// whose file is its own are asked.
@(test)
the_proof_of_a_wide_grant_needs_a_passphrase_here :: proc(t: ^testing.T) {
	testing.expect_value(t, proof_problem(PRINCIPAL_CAPACITY, true, .Passphrase, true, PRINCIPAL_CAPACITY), Proof_Problem.Bad_Principal)
	testing.expect_value(t, proof_problem(max(u64), true, .Passphrase, true, 0), Proof_Problem.Bad_Principal)
	testing.expect_value(t, proof_problem(MACHINE, false, .Passphrase, true, 0), Proof_Problem.No_Record)
	testing.expect_value(t, proof_problem(MACHINE, true, .Unknown, true, 0), Proof_Problem.No_Record)
	testing.expect_value(t, proof_problem(MACHINE, true, .Sealed_By_The_Tpm, true, 0), Proof_Problem.No_Passphrase)
	testing.expect_value(t, proof_problem(MACHINE, true, .Sealed_By_The_Tpm_With_Passphrase, false, 0), Proof_Problem.No_Tpm)
	if PRINCIPAL_CAPACITY > 1 {
		named := u64(1)
		testing.expect_value(t, proof_problem(named, false, .Unknown, true, named), Proof_Problem.No_Record)
		testing.expect_value(t, proof_problem(named, true, .Unknown, true, MACHINE), Proof_Problem.Other_Principal)
		testing.expect_value(t, proof_problem(named, true, .Unknown, false, named), Proof_Problem.None)
	}
	testing.expect_value(t, proof_problem(MACHINE, true, .Passphrase, false, 0), Proof_Problem.None)
	testing.expect_value(t, proof_problem(MACHINE, true, .Sealed_By_The_Tpm_With_Passphrase, true, 0), Proof_Problem.None)
}

@(test)
a_new_machine_passphrase_keeps_the_copy_under_the_recovery_key :: proc(t: ^testing.T) {
	file := test_machine_tpm_passphrase_file()
	before: [MACHINE_TPM_PASSPHRASE_FILE_SIZE]u8
	machine_tpm_passphrase_file_encode(&file, &before)
	renewed := file
	renewed.salt[0] ~= 1
	renewed.nonce[0] ~= 1
	renewed.sealed[0] ~= 1
	renewed.private_area[2] ~= 1
	after: [MACHINE_TPM_PASSPHRASE_FILE_SIZE]u8
	machine_tpm_passphrase_file_encode(&renewed, &after)
	testing.expect(t, string(machine_tpm_passphrase_file_recovery_additional_data(&before)) == string(machine_tpm_passphrase_file_recovery_additional_data(&after)))
	testing.expect(t, string(machine_tpm_passphrase_file_additional_data(&before)) != string(machine_tpm_passphrase_file_additional_data(&after)))
	testing.expect(t, string(before[MACHINE_TPM_PASSPHRASE_OFFSET_RECOVERY_NONCE:]) == string(after[MACHINE_TPM_PASSPHRASE_OFFSET_RECOVERY_NONCE:]))
	_, _, problem := machine_tpm_passphrase_file_decode(after[:])
	testing.expect_value(t, problem, File_Problem.None)
}

// The storage key of a principal is a key of its own: not the unlock key,
// not the key of another text over the same secret, and another secret
// gives another key.
@(test)
the_storage_key_is_a_use_of_its_own_of_the_unlock_key :: proc(t: ^testing.T) {
	secret: [KEY_SIZE]u8
	for index in 0 ..< KEY_SIZE {
		secret[index] = u8(index + 1)
	}
	storage := principal_storage_key(&secret)
	testing.expect(t, storage != secret)
	testing.expect(t, storage != keyed_hash(secret[:], RECOVERY_SEAL_TEXT))
	testing.expect(t, storage != keyed_hash(secret[:], PRINCIPAL_AUTHORIZATION_TEXT))
	other := secret
	other[0] ~= 1
	testing.expect(t, principal_storage_key(&other) != storage)
	testing.expect(t, principal_storage_key(&secret) == storage)
}
