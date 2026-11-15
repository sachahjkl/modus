#+build !freestanding
package principals

import "core:testing"
import "modus:support/tpm2"

// The store of a program has the name of the program for the machine, so
// the stores of the system keep their names; a named principal has a store
// of its own for each program.
@(test)
store_names_carry_the_principal :: proc(t: ^testing.T) {
	out: [32]u8
	cases := [?]struct {
		program:   string,
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
		testing.expect(t, store_name_write(&out, item.program, item.principal, item.history))
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
	// Two principals that run one program: two stores.
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
	testing.expect_value(t, passphrase_problem(transmute([]u8)string("tab\tinside it")), Passphrase_Problem.Bad_Byte)
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
