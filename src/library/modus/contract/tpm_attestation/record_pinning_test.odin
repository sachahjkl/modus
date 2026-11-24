#+build !freestanding
package tpm_attestation

// The host tests of the pin payloads, of their rules, and of the announce
// and the settle around a write of the disk
// (src/md/features/tpm_sealed_machine_key.md, "The pin of the record").

import "core:crypto/hash"
import "core:testing"
import "modus:contract/byte_order"

// The principal identifier of the pins of these tests.
TEST_IDENTIFIER :: Identifier{0 = 0xA1, 31 = 0x5C}

@(private = "file")
pin_test_digest :: proc(seed: u8) -> (out: Digest) {
	for i in 0 ..< SHA256_SIZE {
		out[i] = seed + u8(i * 5 + 1)
	}
	return out
}

// The checksum of a pin payload, computed with the SHA-256 of the core
// library, so that a test does not trust the code that it checks.
@(private = "file")
reference_pin_checksum :: proc(domain: string, covered: []u8) -> (out: Digest) {
	joined: [256]u8
	copy(joined[:], domain)
	copy(joined[len(domain):], covered)
	reference: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, joined[:len(domain) + len(covered)], reference[:])
	return Digest(reference)
}

// Writes a fresh checksum over a payload that a test changed, so that the
// field checks behind the checksum are reached.
@(private = "file")
reseal_machine_key_pin :: proc(payload: []u8) {
	checksum := reference_pin_checksum(MACHINE_KEY_PIN_DOMAIN, payload[:MACHINE_KEY_PIN_OFFSET_CHECKSUM])
	copy(payload[MACHINE_KEY_PIN_OFFSET_CHECKSUM:], checksum[:])
}

@(private = "file")
reseal_principal_file_pin :: proc(payload: []u8) {
	checksum := reference_pin_checksum(PRINCIPAL_FILE_PIN_DOMAIN, payload[:PRINCIPAL_FILE_PIN_OFFSET_CHECKSUM])
	copy(payload[PRINCIPAL_FILE_PIN_OFFSET_CHECKSUM:], checksum[:])
}

@(private = "file")
pin_bytes_all_are :: proc(bytes: []u8, value: u8) -> bool {
	for item in bytes {
		if item != value {
			return false
		}
	}
	return true
}

@(test)
machine_key_pin_payload_refuses_damage :: proc(t: ^testing.T) {
	record_digest := pin_test_digest(0x50)
	next_digest := pin_test_digest(0x60)
	// The encoder refuses what a decoder refuses, and writes nothing then.
	untouched: [MACHINE_KEY_PIN_RECORD_SIZE]u8
	for &item in untouched {
		item = 0xEE
	}
	count, refusal := machine_key_pin_encode({form = .None, epoch = 1, record_digest = record_digest}, untouched[:])
	testing.expect_value(t, refusal, Pin_Refusal.Unknown_Form)
	testing.expect_value(t, count, 0)
	count, refusal = machine_key_pin_encode({form = .MachineT, epoch = 0, record_digest = record_digest}, untouched[:])
	testing.expect_value(t, refusal, Pin_Refusal.Epoch_Zero)
	count, refusal = machine_key_pin_encode({form = .MachineT, epoch = 1}, untouched[:])
	testing.expect_value(t, refusal, Pin_Refusal.Zero_Digest)
	count, refusal = machine_key_pin_encode({form = .MachineT, epoch = 1, record_digest = record_digest}, untouched[:MACHINE_KEY_PIN_RECORD_SIZE - 1])
	testing.expect_value(t, refusal, Pin_Refusal.Buffer_Too_Small)
	testing.expect(t, pin_bytes_all_are(untouched[:], 0xEE))

	// The exact layout.
	pinned := Machine_Key_Pin{form = .MachineT, epoch = 0x0102_0304_0506_0708, record_digest = record_digest, next_digest = next_digest}
	payload: [MACHINE_KEY_PIN_RECORD_SIZE]u8
	count, refusal = machine_key_pin_encode(pinned, payload[:])
	testing.expect_value(t, refusal, Pin_Refusal.None)
	testing.expect_value(t, count, 116)
	expected_head := [20]u8{'M', 'O', 'D', 'U', 'S', 'M', 'K', 'P', 0x00, 0x02, 0x01, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08}
	testing.expect(t, string(payload[:20]) == string(expected_head[:]))
	testing.expect(t, string(payload[20:52]) == string(record_digest[:]))
	testing.expect(t, string(payload[52:84]) == string(next_digest[:]))
	checksum := reference_pin_checksum(MACHINE_KEY_PIN_DOMAIN, payload[:84])
	testing.expect(t, string(payload[84:]) == string(checksum[:]))
	pin, decode_refusal := machine_key_pin_decode(payload[:])
	testing.expect_value(t, decode_refusal, Pin_Refusal.None)
	testing.expect_value(t, pin, pinned)

	// Sizes: 0, one short, one long.
	_, decode_refusal = machine_key_pin_decode(nil)
	testing.expect_value(t, decode_refusal, Pin_Refusal.Truncated)
	_, decode_refusal = machine_key_pin_decode(payload[:MACHINE_KEY_PIN_RECORD_SIZE - 1])
	testing.expect_value(t, decode_refusal, Pin_Refusal.Truncated)
	longer: [MACHINE_KEY_PIN_RECORD_SIZE + 1]u8
	copy(longer[:], payload[:])
	_, decode_refusal = machine_key_pin_decode(longer[:])
	testing.expect_value(t, decode_refusal, Pin_Refusal.Trailing_Bytes)

	// Each single flipped bit is refused.
	for index in 0 ..< MACHINE_KEY_PIN_RECORD_SIZE {
		damaged := payload
		damaged[index] ~= 0x01
		_, flipped := machine_key_pin_decode(damaged[:])
		testing.expectf(t, flipped != .None, "a flipped bit at byte %d was taken", index)
	}

	// The magic and the format come before the checksum. Format 1, the
	// payload with no record digest, is refused.
	damaged := payload
	damaged[0] = 'X'
	_, decode_refusal = machine_key_pin_decode(damaged[:])
	testing.expect_value(t, decode_refusal, Pin_Refusal.Bad_Magic)
	for format in ([?]u8{0, 1, 3}) {
		damaged = payload
		damaged[MACHINE_KEY_PIN_OFFSET_FORMAT + 1] = format
		reseal_machine_key_pin(damaged[:])
		_, decode_refusal = machine_key_pin_decode(damaged[:])
		testing.expect_value(t, decode_refusal, Pin_Refusal.Unknown_Format)
	}
	damaged = payload
	damaged[MACHINE_KEY_PIN_OFFSET_EPOCH + 7] ~= 0xFF
	_, decode_refusal = machine_key_pin_decode(damaged[:])
	testing.expect_value(t, decode_refusal, Pin_Refusal.Bad_Checksum)

	// Behind a correct checksum, each field is still checked.
	for word in ([?]u8{0, 4, 255}) {
		damaged = payload
		damaged[MACHINE_KEY_PIN_OFFSET_FORM] = word
		reseal_machine_key_pin(damaged[:])
		_, decode_refusal = machine_key_pin_decode(damaged[:])
		testing.expect_value(t, decode_refusal, Pin_Refusal.Unknown_Form)
	}
	damaged = payload
	damaged[MACHINE_KEY_PIN_OFFSET_RESERVED] = 1
	reseal_machine_key_pin(damaged[:])
	_, decode_refusal = machine_key_pin_decode(damaged[:])
	testing.expect_value(t, decode_refusal, Pin_Refusal.Reserved_Not_Zero)
	damaged = payload
	for index in 0 ..< 8 {
		damaged[MACHINE_KEY_PIN_OFFSET_EPOCH + index] = 0
	}
	reseal_machine_key_pin(damaged[:])
	_, decode_refusal = machine_key_pin_decode(damaged[:])
	testing.expect_value(t, decode_refusal, Pin_Refusal.Epoch_Zero)
	damaged = payload
	for index in 0 ..< SHA256_SIZE {
		damaged[MACHINE_KEY_PIN_OFFSET_RECORD_DIGEST + index] = 0
	}
	reseal_machine_key_pin(damaged[:])
	_, decode_refusal = machine_key_pin_decode(damaged[:])
	testing.expect_value(t, decode_refusal, Pin_Refusal.Zero_Digest)

	// A payload under the text of the other kind fails its checksum.
	damaged = payload
	other := reference_pin_checksum(PRINCIPAL_FILE_PIN_DOMAIN, damaged[:MACHINE_KEY_PIN_OFFSET_CHECKSUM])
	copy(damaged[MACHINE_KEY_PIN_OFFSET_CHECKSUM:], other[:])
	_, decode_refusal = machine_key_pin_decode(damaged[:])
	testing.expect_value(t, decode_refusal, Pin_Refusal.Bad_Checksum)

	// With no announced record, the next digest is zero and decodes.
	alone := pinned
	alone.next_digest = {}
	count, refusal = machine_key_pin_encode(alone, payload[:])
	testing.expect_value(t, refusal, Pin_Refusal.None)
	pin, decode_refusal = machine_key_pin_decode(payload[:])
	testing.expect_value(t, decode_refusal, Pin_Refusal.None)
	testing.expect_value(t, pin, alone)
}

@(test)
machine_key_pin_refuses_downgrade_and_rollback :: proc(t: ^testing.T) {
	digest := pin_test_digest(0x51)
	sealed_five := Machine_Key_Pin{form = .MachineT, epoch = 5, record_digest = digest}
	testing.expect_value(t, machine_key_pin_advance(sealed_five, {form = .MachineK, epoch = 6, record_digest = digest}), Pin_Refusal.Form_Downgrade)
	testing.expect_value(t, machine_key_pin_advance({form = .MachineP, epoch = 5, record_digest = digest}, {form = .MachineK, epoch = 900, record_digest = digest}), Pin_Refusal.Form_Downgrade)
	testing.expect_value(t, machine_key_pin_advance(sealed_five, {form = .MachineK, epoch = 1, record_digest = digest}), Pin_Refusal.Form_Downgrade)
	testing.expect_value(t, machine_key_pin_advance({form = .MachineK, epoch = 5, record_digest = digest}, {form = .MachineT, epoch = 6, record_digest = digest}), Pin_Refusal.Form_Change)
	testing.expect_value(t, machine_key_pin_advance(sealed_five, {form = .MachineP, epoch = 6, record_digest = digest}), Pin_Refusal.Form_Change)
	testing.expect_value(t, machine_key_pin_advance(sealed_five, {form = .MachineT, epoch = 5, record_digest = digest}), Pin_Refusal.Epoch_Replay)
	testing.expect_value(t, machine_key_pin_advance(sealed_five, {form = .MachineT, epoch = 4, record_digest = digest}), Pin_Refusal.Epoch_Rollback)
	testing.expect_value(t, machine_key_pin_advance(sealed_five, {form = .MachineT, epoch = 0, record_digest = digest}), Pin_Refusal.Epoch_Zero)
	testing.expect_value(t, machine_key_pin_advance(sealed_five, {form = .MachineT, epoch = 6}), Pin_Refusal.Zero_Digest)
	testing.expect_value(t, machine_key_pin_advance(sealed_five, {form = .None, epoch = 6, record_digest = digest}), Pin_Refusal.Unknown_Form)
	testing.expect_value(t, machine_key_pin_advance({}, {form = .None, epoch = 1, record_digest = digest}), Pin_Refusal.Unknown_Form)
	testing.expect_value(t, machine_key_pin_advance({}, {form = .MachineK, epoch = 0, record_digest = digest}), Pin_Refusal.Epoch_Zero)
	testing.expect_value(t, machine_key_pin_advance({form = .MachineT, epoch = max(u64), record_digest = digest}, {form = .MachineT, epoch = max(u64), record_digest = digest}), Pin_Refusal.Epoch_Replay)

	// The accepted cases come last.
	testing.expect_value(t, machine_key_pin_advance({}, {form = .MachineT, epoch = 1, record_digest = digest}), Pin_Refusal.None)
	testing.expect_value(t, machine_key_pin_advance(sealed_five, {form = .MachineT, epoch = 6, record_digest = digest}), Pin_Refusal.None)
	testing.expect_value(t, machine_key_pin_advance({form = .MachineT, epoch = max(u64) - 1, record_digest = digest}, {form = .MachineT, epoch = max(u64), record_digest = digest}), Pin_Refusal.None)
}

// A disk writer swaps, downgrades, rolls back or changes the record of the
// machine key: the pin refuses each, and takes only the record that it
// names or the one that it announced.
@(test)
machine_key_pin_refuses_swap_and_rollback_of_the_record :: proc(t: ^testing.T) {
	sealed_record := transmute([]u8)string("MACHINET the sealed record of epoch one")
	resealed_record := transmute([]u8)string("MACHINET the record after a new seal")
	older_sealed_record := transmute([]u8)string("MACHINET an older sealed record")
	passphrase_record := transmute([]u8)string("MACHINEK a record under the passphrase of an attacker")

	first, refusal := machine_key_pin_settle({}, sealed_record)
	testing.expect_value(t, refusal, Pin_Refusal.None)
	testing.expect_value(t, first.form, Machine_Key_Form.MachineT)
	testing.expect_value(t, first.epoch, u64(1))

	// The swap for a record under a passphrase, an older sealed record, a
	// changed byte, a cut record, another kind of record.
	match: Pin_Match
	match, refusal = machine_key_record_matches_pin(first, passphrase_record)
	testing.expect_value(t, refusal, Pin_Refusal.Form_Mismatch)
	match, refusal = machine_key_record_matches_pin(first, older_sealed_record)
	testing.expect_value(t, refusal, Pin_Refusal.Digest_Mismatch)
	changed: [64]u8
	copy(changed[:], sealed_record)
	changed[len(sealed_record) - 1] ~= 0x01
	match, refusal = machine_key_record_matches_pin(first, changed[:len(sealed_record)])
	testing.expect_value(t, refusal, Pin_Refusal.Digest_Mismatch)
	match, refusal = machine_key_record_matches_pin(first, sealed_record[:7])
	testing.expect_value(t, refusal, Pin_Refusal.Truncated)
	match, refusal = machine_key_record_matches_pin(first, transmute([]u8)string("PRINCIPT"))
	testing.expect_value(t, refusal, Pin_Refusal.Unknown_Form)
	match, refusal = machine_key_record_matches_pin({}, sealed_record)
	testing.expect_value(t, refusal, Pin_Refusal.Not_Pinned)

	// No pin moves to a record under a passphrase after a sealed one.
	_, refusal = machine_key_pin_announce(first, passphrase_record)
	testing.expect_value(t, refusal, Pin_Refusal.Form_Downgrade)
	_, refusal = machine_key_pin_settle(first, passphrase_record)
	testing.expect_value(t, refusal, Pin_Refusal.Form_Downgrade)
	_, refusal = machine_key_pin_announce({}, resealed_record)
	testing.expect_value(t, refusal, Pin_Refusal.Not_Pinned)
	_, refusal = machine_key_pin_announce(first, transmute([]u8)string("MACHINE"))
	testing.expect_value(t, refusal, Pin_Refusal.Unknown_Form)
	_, refusal = machine_key_pin_settle({}, transmute([]u8)string("MACHINE"))
	testing.expect_value(t, refusal, Pin_Refusal.Unknown_Form)
	exhausted := first
	exhausted.epoch = max(u64)
	_, refusal = machine_key_pin_announce(exhausted, resealed_record)
	testing.expect_value(t, refusal, Pin_Refusal.Epoch_Exhausted)
	_, refusal = machine_key_pin_settle(exhausted, resealed_record)
	testing.expect_value(t, refusal, Pin_Refusal.Epoch_Exhausted)

	// A new seal: announce, write, settle. A stop between the write of the
	// disk and the settle leaves the old or the new record, each taken.
	announced: Machine_Key_Pin
	announced, refusal = machine_key_pin_announce(first, resealed_record)
	testing.expect_value(t, refusal, Pin_Refusal.None)
	testing.expect_value(t, announced.epoch, u64(2))
	match, refusal = machine_key_record_matches_pin(announced, older_sealed_record)
	testing.expect_value(t, refusal, Pin_Refusal.Digest_Mismatch)
	match, refusal = machine_key_record_matches_pin(announced, sealed_record)
	testing.expect_value(t, refusal, Pin_Refusal.None)
	testing.expect_value(t, match, Pin_Match.Current)
	match, refusal = machine_key_record_matches_pin(announced, resealed_record)
	testing.expect_value(t, refusal, Pin_Refusal.None)
	testing.expect_value(t, match, Pin_Match.Next)
	settled: Machine_Key_Pin
	settled, refusal = machine_key_pin_settle(announced, resealed_record)
	testing.expect_value(t, refusal, Pin_Refusal.None)
	testing.expect_value(t, settled.epoch, u64(3))
	testing.expect(t, settled.next_digest == Digest{})

	// After the settle, the record of before is a rollback.
	match, refusal = machine_key_record_matches_pin(settled, sealed_record)
	testing.expect_value(t, refusal, Pin_Refusal.Digest_Mismatch)
	testing.expect_value(t, machine_key_pin_advance(settled, first), Pin_Refusal.Epoch_Rollback)
	match, refusal = machine_key_record_matches_pin(settled, resealed_record)
	testing.expect_value(t, refusal, Pin_Refusal.None)
	testing.expect_value(t, match, Pin_Match.Current)
}

@(test)
principal_file_pin_payload_refuses_damage :: proc(t: ^testing.T) {
	digest := pin_test_digest(0x40)
	next_digest := pin_test_digest(0x41)
	pin := Principal_File_Pin{identifier = TEST_IDENTIFIER, principal = 0x0A0B_0C0D, generation = 0x1122_3344_5566_7788, file_digest = digest, next_digest = next_digest}

	untouched: [PRINCIPAL_FILE_PIN_RECORD_SIZE]u8
	for &item in untouched {
		item = 0xEE
	}
	_, refusal := principal_file_pin_encode({principal = 0, generation = 1, file_digest = digest}, untouched[:])
	testing.expect_value(t, refusal, Pin_Refusal.Principal_Zero)
	_, refusal = principal_file_pin_encode({principal = 1, generation = 1, file_digest = digest}, untouched[:])
	testing.expect_value(t, refusal, Pin_Refusal.Identifier_Zero)
	_, refusal = principal_file_pin_encode({identifier = TEST_IDENTIFIER, principal = 1, generation = 0, file_digest = digest}, untouched[:])
	testing.expect_value(t, refusal, Pin_Refusal.Generation_Zero)
	_, refusal = principal_file_pin_encode({identifier = TEST_IDENTIFIER, principal = 1, generation = 1}, untouched[:])
	testing.expect_value(t, refusal, Pin_Refusal.Zero_Digest)
	_, refusal = principal_file_pin_encode(pin, untouched[:PRINCIPAL_FILE_PIN_RECORD_SIZE - 1])
	testing.expect_value(t, refusal, Pin_Refusal.Buffer_Too_Small)
	testing.expect(t, pin_bytes_all_are(untouched[:], 0xEE))

	payload: [PRINCIPAL_FILE_PIN_RECORD_SIZE]u8
	count: int
	count, refusal = principal_file_pin_encode(pin, payload[:])
	testing.expect_value(t, refusal, Pin_Refusal.None)
	testing.expect_value(t, count, 152)
	expected_head := [24]u8{'M', 'O', 'D', 'U', 'S', 'P', 'F', 'P', 0x00, 0x04, 0x00, 0x00, 0x0A, 0x0B, 0x0C, 0x0D, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88}
	testing.expect(t, string(payload[:24]) == string(expected_head[:]))
	identifier := TEST_IDENTIFIER
	testing.expect(t, string(payload[24:56]) == string(identifier[:]))
	testing.expect(t, string(payload[56:88]) == string(digest[:]))
	testing.expect(t, string(payload[88:120]) == string(next_digest[:]))
	checksum := reference_pin_checksum(PRINCIPAL_FILE_PIN_DOMAIN, payload[:120])
	testing.expect(t, string(payload[120:]) == string(checksum[:]))
	// Payloads of older formats 2 and 3 are of no known format.
	for older in ([?]u8{0x02, 0x03}) {
		older_format := payload
		older_format[9] = older
		_, older_refusal := principal_file_pin_decode(older_format[:])
		testing.expect_value(t, older_refusal, Pin_Refusal.Unknown_Format)
	}
	decoded, decode_refusal := principal_file_pin_decode(payload[:])
	testing.expect_value(t, decode_refusal, Pin_Refusal.None)
	testing.expect_value(t, decoded, pin)

	_, decode_refusal = principal_file_pin_decode(payload[:PRINCIPAL_FILE_PIN_RECORD_SIZE - 1])
	testing.expect_value(t, decode_refusal, Pin_Refusal.Truncated)
	for index in 0 ..< PRINCIPAL_FILE_PIN_RECORD_SIZE {
		damaged := payload
		damaged[index] ~= 0x80
		_, flipped := principal_file_pin_decode(damaged[:])
		testing.expectf(t, flipped != .None, "a flipped bit at byte %d was taken", index)
	}

	// A machine key pin is not a principal file pin.
	machine_payload: [MACHINE_KEY_PIN_RECORD_SIZE]u8
	_, _ = machine_key_pin_encode({form = .MachineT, epoch = 1, record_digest = digest}, machine_payload[:])
	_, decode_refusal = principal_file_pin_decode(machine_payload[:])
	testing.expect_value(t, decode_refusal, Pin_Refusal.Truncated)
	damaged := payload
	copy(damaged[:8], MACHINE_KEY_PIN_MAGIC)
	reseal_principal_file_pin(damaged[:])
	_, decode_refusal = principal_file_pin_decode(damaged[:])
	testing.expect_value(t, decode_refusal, Pin_Refusal.Bad_Magic)
	damaged = payload
	damaged[PRINCIPAL_FILE_PIN_OFFSET_FORMAT + 1] = 1
	reseal_principal_file_pin(damaged[:])
	_, decode_refusal = principal_file_pin_decode(damaged[:])
	testing.expect_value(t, decode_refusal, Pin_Refusal.Unknown_Format)

	// Behind a correct checksum, each field is still checked.
	damaged = payload
	damaged[PRINCIPAL_FILE_PIN_OFFSET_STATE + 1] = 2 // unknown Principal_Pin_State
	reseal_principal_file_pin(damaged[:])
	_, decode_refusal = principal_file_pin_decode(damaged[:])
	testing.expect_value(t, decode_refusal, Pin_Refusal.Unknown_State)
	// Free state with non-zero identifier/digest is refused.
	damaged = payload
	damaged[PRINCIPAL_FILE_PIN_OFFSET_STATE + 1] = u8(Principal_Pin_State.Free)
	reseal_principal_file_pin(damaged[:])
	_, decode_refusal = principal_file_pin_decode(damaged[:])
	testing.expect_value(t, decode_refusal, Pin_Refusal.Free_Pin_Not_Zero)
	damaged = payload
	byte_order.write_u32_big_endian(damaged[:], PRINCIPAL_FILE_PIN_OFFSET_PRINCIPAL, 0)
	reseal_principal_file_pin(damaged[:])
	_, decode_refusal = principal_file_pin_decode(damaged[:])
	testing.expect_value(t, decode_refusal, Pin_Refusal.Principal_Zero)
	damaged = payload
	byte_order.write_u64_big_endian(damaged[:], PRINCIPAL_FILE_PIN_OFFSET_GENERATION, 0)
	reseal_principal_file_pin(damaged[:])
	_, decode_refusal = principal_file_pin_decode(damaged[:])
	testing.expect_value(t, decode_refusal, Pin_Refusal.Generation_Zero)
	damaged = payload
	for index in 0 ..< SHA256_SIZE {
		damaged[PRINCIPAL_FILE_PIN_OFFSET_DIGEST + index] = 0
	}
	reseal_principal_file_pin(damaged[:])
	_, decode_refusal = principal_file_pin_decode(damaged[:])
	testing.expect_value(t, decode_refusal, Pin_Refusal.Zero_Digest)
}

// A disk writer keeps an older file of a principal, with its older
// passphrase, and puts it back after a change: the pin refuses it.
@(test)
principal_file_pin_refuses_rollback_and_mismatch :: proc(t: ^testing.T) {
	file_three := transmute([]u8)string("PRINCIPT the file of generation three")
	file_two := transmute([]u8)string("PRINCIPT the file of generation two")
	reference: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, file_three, reference[:])
	testing.expect_value(t, principal_file_digest(file_three), Digest(reference))

	current := Principal_File_Pin{identifier = TEST_IDENTIFIER, principal = 7, generation = 3, file_digest = principal_file_digest(file_three)}
	older := Principal_File_Pin{identifier = TEST_IDENTIFIER, principal = 7, generation = 2, file_digest = principal_file_digest(file_two)}
	testing.expect_value(t, principal_file_pin_advance(current, older), Pin_Refusal.Generation_Rollback)
	testing.expect_value(t, principal_file_pin_advance(current, current), Pin_Refusal.Generation_Replay)
	same_generation_other_file := Principal_File_Pin{identifier = TEST_IDENTIFIER, principal = 7, generation = 3, file_digest = principal_file_digest(file_two)}
	testing.expect_value(t, principal_file_pin_advance(current, same_generation_other_file), Pin_Refusal.Generation_Replay)
	testing.expect_value(t, principal_file_pin_advance(current, {identifier = TEST_IDENTIFIER, principal = 8, generation = 4, file_digest = current.file_digest}), Pin_Refusal.Principal_Mismatch)
	testing.expect_value(t, principal_file_pin_advance(current, {identifier = TEST_IDENTIFIER, principal = 7, generation = 4}), Pin_Refusal.Zero_Digest)
	testing.expect_value(t, principal_file_pin_advance(current, {identifier = TEST_IDENTIFIER, principal = 7, generation = 0, file_digest = current.file_digest}), Pin_Refusal.Generation_Zero)
	testing.expect_value(t, principal_file_pin_advance(current, {principal = 0, generation = 4, file_digest = current.file_digest}), Pin_Refusal.Principal_Zero)
	testing.expect_value(t, principal_file_pin_advance({}, {identifier = TEST_IDENTIFIER, principal = 7, generation = 1}), Pin_Refusal.Zero_Digest)
	// The identifier: none, and another principal in the same slot.
	testing.expect_value(t, principal_file_pin_advance(current, {principal = 7, generation = 4, file_digest = current.file_digest}), Pin_Refusal.Identifier_Zero)
	other_identifier := TEST_IDENTIFIER
	other_identifier[31] ~= 1
	testing.expect_value(t, principal_file_pin_advance(current, {identifier = other_identifier, principal = 7, generation = 4, file_digest = current.file_digest}), Pin_Refusal.Identifier_Mismatch)
	_, other_refusal := principal_file_pin_check(current, 7, other_identifier, file_three)
	testing.expect_value(t, other_refusal, Pin_Refusal.Identifier_Mismatch)
	_, other_refusal = principal_file_pin_check(current, 7, {}, file_three)
	testing.expect_value(t, other_refusal, Pin_Refusal.Identifier_Mismatch)

	// The file that the disk gives against the pin.
	_, refusal := principal_file_pin_check(current, 7, TEST_IDENTIFIER, file_two)
	testing.expect_value(t, refusal, Pin_Refusal.Digest_Mismatch)
	_, refusal = principal_file_pin_check(current, 7, TEST_IDENTIFIER, nil)
	testing.expect_value(t, refusal, Pin_Refusal.Digest_Mismatch)
	_, refusal = principal_file_pin_check(current, 7, TEST_IDENTIFIER, file_three[:len(file_three) - 1])
	testing.expect_value(t, refusal, Pin_Refusal.Digest_Mismatch)
	changed: [64]u8
	copy(changed[:], file_three)
	changed[len(file_three) - 1] ~= 0x01
	_, refusal = principal_file_pin_check(current, 7, TEST_IDENTIFIER, changed[:len(file_three)])
	testing.expect_value(t, refusal, Pin_Refusal.Digest_Mismatch)
	_, refusal = principal_file_pin_check(current, 8, TEST_IDENTIFIER, file_three)
	testing.expect_value(t, refusal, Pin_Refusal.Principal_Mismatch)
	_, refusal = principal_file_pin_check({}, 7, TEST_IDENTIFIER, file_three)
	testing.expect_value(t, refusal, Pin_Refusal.Not_Pinned)

	// A change of the passphrase: announce, write, settle. The older file
	// is refused at each step, and after the settle the file of before too.
	file_four := transmute([]u8)string("PRINCIPT the file of generation four")
	_, refusal = principal_file_pin_announce({}, file_four)
	testing.expect_value(t, refusal, Pin_Refusal.Not_Pinned)
	exhausted := current
	exhausted.generation = max(u64)
	_, refusal = principal_file_pin_announce(exhausted, file_four)
	testing.expect_value(t, refusal, Pin_Refusal.Generation_Exhausted)
	_, refusal = principal_file_pin_settle(exhausted, 7, TEST_IDENTIFIER, file_four)
	testing.expect_value(t, refusal, Pin_Refusal.Generation_Exhausted)
	_, refusal = principal_file_pin_settle(current, 8, TEST_IDENTIFIER, file_four)
	testing.expect_value(t, refusal, Pin_Refusal.Principal_Mismatch)
	_, refusal = principal_file_pin_settle(current, 0, TEST_IDENTIFIER, file_four)
	testing.expect_value(t, refusal, Pin_Refusal.Principal_Zero)
	announced: Principal_File_Pin
	announced, refusal = principal_file_pin_announce(current, file_four)
	testing.expect_value(t, refusal, Pin_Refusal.None)
	_, refusal = principal_file_pin_check(announced, 7, TEST_IDENTIFIER, file_two)
	testing.expect_value(t, refusal, Pin_Refusal.Digest_Mismatch)
	match: Pin_Match
	match, refusal = principal_file_pin_check(announced, 7, TEST_IDENTIFIER, file_three)
	testing.expect(t, refusal == .None && match == .Current)
	match, refusal = principal_file_pin_check(announced, 7, TEST_IDENTIFIER, file_four)
	testing.expect(t, refusal == .None && match == .Next)
	settled: Principal_File_Pin
	settled, refusal = principal_file_pin_settle(announced, 7, TEST_IDENTIFIER, file_four)
	testing.expect_value(t, refusal, Pin_Refusal.None)
	testing.expect_value(t, settled.generation, u64(5))
	_, refusal = principal_file_pin_check(settled, 7, TEST_IDENTIFIER, file_three)
	testing.expect_value(t, refusal, Pin_Refusal.Digest_Mismatch)
	_, refusal = principal_file_pin_check(settled, 7, TEST_IDENTIFIER, file_two)
	testing.expect_value(t, refusal, Pin_Refusal.Digest_Mismatch)

	// The accepted cases come last.
	testing.expect_value(t, principal_file_pin_advance({}, older), Pin_Refusal.None)
	forward := Principal_File_Pin{identifier = TEST_IDENTIFIER, principal = 7, generation = 4, file_digest = principal_file_digest(file_two)}
	testing.expect_value(t, principal_file_pin_advance(current, forward), Pin_Refusal.None)
	match, refusal = principal_file_pin_check(current, 7, TEST_IDENTIFIER, file_three)
	testing.expect(t, refusal == .None && match == .Current)
	first: Principal_File_Pin
	first, refusal = principal_file_pin_settle({}, 7, TEST_IDENTIFIER, file_three)
	testing.expect_value(t, refusal, Pin_Refusal.None)
	testing.expect_value(t, first.generation, u64(1))
	match, refusal = principal_file_pin_check(settled, 7, TEST_IDENTIFIER, file_four)
	testing.expect(t, refusal == .None && match == .Current)
}

// Free pin ("free, generation g") transitions and refusals:
// Absent -> Free refused; Active -> Free advances generation and zeroes
// identifier/digests; Free -> Free refused; Free refuses any file on disk;
// Free(g) -> Active(B, g+1) succeeds for a new principal identifier.
@(test)
principal_file_pin_free_and_recreate_transitions :: proc(t: ^testing.T) {
	file_a := transmute([]u8)string("PRINCIPT file A")
	file_b := transmute([]u8)string("PRINCIPT file B")
	id_b := TEST_IDENTIFIER
	id_b[0] ~= 0xFF

	// Absent -> Free is refused.
	_, ref := principal_file_pin_free({})
	testing.expect_value(t, ref, Pin_Refusal.Not_Pinned)
	testing.expect_value(t, principal_file_pin_advance({}, {state = .Free, principal = 1, generation = 1}), Pin_Refusal.Not_Pinned)

	// Active(A, 1) -> Free(2).
	pin_a, ref_a := principal_file_pin_settle({}, 1, TEST_IDENTIFIER, file_a)
	testing.expect_value(t, ref_a, Pin_Refusal.None)
	freed, ref_free := principal_file_pin_free(pin_a)
	testing.expect_value(t, ref_free, Pin_Refusal.None)
	testing.expect_value(t, freed.state, Principal_Pin_State.Free)
	testing.expect_value(t, freed.generation, u64(2))
	testing.expect_value(t, freed.identifier, Identifier{})
	testing.expect_value(t, freed.file_digest, Digest{})

	// Round-trip encode/decode of Free pin.
	payload: [PRINCIPAL_FILE_PIN_RECORD_SIZE]u8
	count, enc_ref := principal_file_pin_encode(freed, payload[:])
	testing.expect(t, enc_ref == .None && count == PRINCIPAL_FILE_PIN_RECORD_SIZE)
	decoded, dec_ref := principal_file_pin_decode(payload[:])
	testing.expect(t, dec_ref == .None && decoded == freed)

	// Free -> Free is refused, announce on Free is refused, file check on Free is refused.
	_, ref = principal_file_pin_free(freed)
	testing.expect_value(t, ref, Pin_Refusal.Slot_Free)
	testing.expect_value(t, principal_file_pin_advance(freed, {state = .Free, principal = 1, generation = 3}), Pin_Refusal.Slot_Free)
	_, ref = principal_file_pin_announce(freed, file_b)
	testing.expect_value(t, ref, Pin_Refusal.Slot_Free)
	_, ref = principal_file_pin_check(freed, 1, TEST_IDENTIFIER, file_a)
	testing.expect_value(t, ref, Pin_Refusal.Slot_Free)

	// Rollback from Free(2) to Active(A, 1) or Active(A, 2) is refused.
	testing.expect_value(t, principal_file_pin_advance(freed, pin_a), Pin_Refusal.Generation_Rollback)
	replay_active := pin_a
	replay_active.generation = 2
	testing.expect_value(t, principal_file_pin_advance(freed, replay_active), Pin_Refusal.Generation_Replay)

	// Free(2) -> Active(B, 3) succeeds with new principal identifier B.
	pin_b, ref_b := principal_file_pin_settle(freed, 1, id_b, file_b)
	testing.expect_value(t, ref_b, Pin_Refusal.None)
	testing.expect_value(t, pin_b.state, Principal_Pin_State.Active)
	testing.expect_value(t, pin_b.generation, u64(3))
	testing.expect_value(t, pin_b.identifier, id_b)
	match, check_ref := principal_file_pin_check(pin_b, 1, id_b, file_b)
	testing.expect(t, check_ref == .None && match == .Current)
}

@(test)
pin_refusal_words_name_each_refusal :: proc(t: ^testing.T) {
	for refusal in Pin_Refusal {
		testing.expectf(t, len(pin_refusal_words[refusal]) > 0, "the refusal %v has no words", refusal)
	}
}

// The signed policy of the publisher does not name PCR 7: a change of PCR 7
// (an update of dbx) gives another approved policy, and the authorized
// digest stays. A newer version passes; an older version, a revoked key and
// a forged signature are refused, and change no floor.
@(test)
signed_policy_survives_a_pcr_7_change_and_refuses_older_or_forged :: proc(t: ^testing.T) {
	publisher_secret := pin_test_digest(0x70)
	publisher_key_digest := pin_test_digest(0x71)
	reference := pin_test_digest(0x72)
	state: Rollback_Floor_State
	testing.expect_value(t, rollback_floor_init(&state, publisher_key_digest, 1, 2, 4), Rollback_Refusal.None)

	approved_before_dbx := Approved_Policy_Statement{key_number = 2, policy_version = 5, approved_policy = pin_test_digest(0x80), policy_ref = reference}
	approved_after_dbx := Approved_Policy_Statement{key_number = 2, policy_version = 6, approved_policy = pin_test_digest(0x81), policy_ref = reference}

	// A forged signature: the right statement under another key.
	forged_key := pin_test_digest(0x73)
	forged_hash := compute_policy_approval_hash(approved_after_dbx)
	forged := hmac_sha256(forged_key[:], forged_hash[:])
	_, refusal := rollback_floor_verify_policy_authorize(&state, approved_after_dbx, forged[:], signed_policy_test_verify, &publisher_secret)
	testing.expect_value(t, refusal, Rollback_Refusal.Signature_Invalid)
	testing.expect_value(t, state.version_floor, u32(4))
	// A signature of another statement.
	older_version := Approved_Policy_Statement{key_number = 2, policy_version = 3, approved_policy = pin_test_digest(0x82), policy_ref = reference}
	older_hash := compute_policy_approval_hash(older_version)
	older_signature := hmac_sha256(publisher_secret[:], older_hash[:])
	_, refusal = rollback_floor_verify_policy_authorize(&state, approved_after_dbx, older_signature[:], signed_policy_test_verify, &publisher_secret)
	testing.expect_value(t, refusal, Rollback_Refusal.Signature_Invalid)
	// A version below the floor, signed by the publisher.
	_, refusal = rollback_floor_verify_policy_authorize(&state, older_version, older_signature[:], signed_policy_test_verify, &publisher_secret)
	testing.expect_value(t, refusal, Rollback_Refusal.Policy_Version_Below_Floor)
	testing.expect_value(t, state.version_floor, u32(4))
	// A revoked key number, signed by the publisher.
	revoked := Approved_Policy_Statement{key_number = 1, policy_version = 64, approved_policy = pin_test_digest(0x83), policy_ref = reference}
	revoked_hash := compute_policy_approval_hash(revoked)
	revoked_signature := hmac_sha256(publisher_secret[:], revoked_hash[:])
	_, refusal = rollback_floor_verify_policy_authorize(&state, revoked, revoked_signature[:], signed_policy_test_verify, &publisher_secret)
	testing.expect_value(t, refusal, Rollback_Refusal.Key_Number_Below_Floor)
	testing.expect_value(t, state.key_floor, u32(2))

	// The accepted cases come last: the update, then the change of PCR 7.
	before_hash := compute_policy_approval_hash(approved_before_dbx)
	before_signature := hmac_sha256(publisher_secret[:], before_hash[:])
	authorized_before: Digest
	authorized_before, refusal = rollback_floor_verify_policy_authorize(&state, approved_before_dbx, before_signature[:], signed_policy_test_verify, &publisher_secret)
	testing.expect_value(t, refusal, Rollback_Refusal.None)
	testing.expect_value(t, state.version_floor, u32(5))
	after_hash := compute_policy_approval_hash(approved_after_dbx)
	after_signature := hmac_sha256(publisher_secret[:], after_hash[:])
	authorized_after: Digest
	authorized_after, refusal = rollback_floor_verify_policy_authorize(&state, approved_after_dbx, after_signature[:], signed_policy_test_verify, &publisher_secret)
	testing.expect_value(t, refusal, Rollback_Refusal.None)
	testing.expect_value(t, state.version_floor, u32(6))
	testing.expect(t, authorized_before == authorized_after)
	testing.expect(t, authorized_after == compute_policy_authorize_digest(publisher_key_digest, reference))
	// The statement of before the update is now below the floor.
	_, refusal = rollback_floor_verify_policy_authorize(&state, approved_before_dbx, before_signature[:], signed_policy_test_verify, &publisher_secret)
	testing.expect_value(t, refusal, Rollback_Refusal.Policy_Version_Below_Floor)
}

// The verifier of the test: an HMAC under the secret of the publisher
// stands for its signature.
@(private = "file")
signed_policy_test_verify :: proc "contextless" (publisher_key_digest: Digest, approval_digest: Digest, signature: []u8, user_data: rawptr) -> bool {
	secret := (^Digest)(user_data)
	approval := approval_digest
	expected := hmac_sha256(secret[:], approval[:])
	return len(signature) == SHA256_SIZE && constant_time_equal(expected[:], signature)
}
