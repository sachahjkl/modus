#+build !freestanding
package tpm_service

import "core:testing"
import "modus:contract/tpm_attestation"

// The pins on the ring and in unlock: a writer of the disk swaps, removes
// or rolls back the record of the machine key or the file of a principal,
// and the decision of unlock refuses it before any key opens
// (src/md/features/tpm_sealed_machine_key.md, "The pin of the record").

@(private = "file")
SEALED_RECORD :: "MACHINET the sealed record that the TPM pins"
@(private = "file")
OLDER_SEALED_RECORD :: "MACHINET an older sealed record, of an older seal"
@(private = "file")
PASSPHRASE_RECORD :: "MACHINEK a record under a passphrase of the attacker"
@(private = "file")
NEW_SEALED_RECORD :: "MACHINET the record of the new seal after a recovery"

@(private = "file")
machine_payload_of :: proc(t: ^testing.T, pin: tpm_attestation.Machine_Key_Pin) -> (payload: [tpm_attestation.MACHINE_KEY_PIN_RECORD_SIZE]u8) {
	count, refusal := tpm_attestation.machine_key_pin_encode(pin, payload[:])
	testing.expect(t, refusal == .None && count == len(payload))
	return
}

@(private = "file")
principal_payload_of :: proc(t: ^testing.T, pin: tpm_attestation.Principal_File_Pin) -> (payload: [tpm_attestation.PRINCIPAL_FILE_PIN_RECORD_SIZE]u8) {
	count, refusal := tpm_attestation.principal_file_pin_encode(pin, payload[:])
	testing.expect(t, refusal == .None && count == len(payload))
	return
}

@(test)
the_border_of_the_pins_refuses_each_wrong_word :: proc(t: ^testing.T) {
	machine_size := u64(tpm_attestation.MACHINE_KEY_PIN_RECORD_SIZE)
	principal_size := u64(tpm_attestation.PRINCIPAL_FILE_PIN_RECORD_SIZE)
	for kind_word in ([?]u64{0, 3, 255, max(u64)}) {
		_, ok := pin_request_of_values(.Pin_Read, {0 = kind_word})
		testing.expectf(t, !ok, "the kind word %d was taken", kind_word)
	}
	refused := [?][7]u64 {
		{0 = u64(Pin_Kind.Machine_Key), 1 = 1}, // A principal on the machine key.
		{0 = u64(Pin_Kind.Principal_File), 1 = 0}, // Principal 0 has no file.
		{0 = u64(Pin_Kind.Principal_File), 1 = PIN_PRINCIPAL_LIMIT + 1},
		{0 = u64(Pin_Kind.Principal_File), 1 = max(u64)},
	}
	for values in refused {
		_, ok := pin_request_of_values(.Pin_Read, values)
		testing.expectf(t, !ok, "the request %v was taken", values)
		_, status := request_of_record(u32(Command.Pin_Read), values, .Client_Ring)
		testing.expect_value(t, status, Status.Bad_Command)
	}
	// A write of a payload of another size than its kind: 0, one short,
	// one long, the size of the other kind, the largest word.
	for size in ([?]u64{0, machine_size - 1, machine_size + 1, principal_size, max(u64)}) {
		_, ok := pin_request_of_values(.Pin_Write, {0 = u64(Pin_Kind.Machine_Key), 2 = size})
		testing.expectf(t, !ok, "a machine key pin of %d bytes was taken", size)
	}
	_, ok := pin_request_of_values(.Pin_Write, {0 = u64(Pin_Kind.Principal_File), 1 = 1, 2 = machine_size})
	testing.expect(t, !ok)
	// The other commands are no pin request, and the measure ring takes no pin.
	for command in ([?]Command{.None, .Seal, .Unseal, .Measure_Start_Policy}) {
		_, ok = pin_request_of_values(command, {0 = u64(Pin_Kind.Machine_Key)})
		testing.expect(t, !ok)
	}
	_, status := request_of_record(u32(Command.Pin_Read), {0 = u64(Pin_Kind.Machine_Key)}, .Measure_Ring)
	testing.expect_value(t, status, Status.Bad_Command)
	_, status = request_of_record(u32(Command.Pin_Write), {0 = u64(Pin_Kind.Machine_Key), 2 = machine_size}, .Measure_Ring)
	testing.expect_value(t, status, Status.Bad_Command)
	for state_word in ([?]u64{5, 255, max(u64)}) {
		_, state_ok := pin_state_of_word(state_word)
		testing.expect(t, !state_ok)
	}

	// The accepted cases come last.
	request: Pin_Request
	request, ok = pin_request_of_values(.Pin_Read, {0 = u64(Pin_Kind.Machine_Key)})
	testing.expect(t, ok && request.kind == .Machine_Key && request.principal == 0)
	request, ok = pin_request_of_values(.Pin_Write, {0 = u64(Pin_Kind.Principal_File), 1 = PIN_PRINCIPAL_LIMIT, 2 = principal_size})
	testing.expect(t, ok && request.principal == PIN_PRINCIPAL_LIMIT && request.bytes == int(principal_size))
	parsed: Request
	parsed, status = request_of_record(u32(Command.Pin_Write), {0 = u64(Pin_Kind.Machine_Key), 2 = machine_size}, .Client_Ring)
	testing.expect(t, status == .Ok && parsed.command == .Pin_Write && parsed.authorization == .None)
}

// A disk swap, a downgrade, a removal and a rollback of the record of the
// machine key are each refused with Record_Pin_Mismatch.
@(test)
a_swapped_or_removed_machine_record_is_refused :: proc(t: ^testing.T) {
	sealed := transmute([]u8)string(SEALED_RECORD)
	pin := tpm_attestation.Machine_Key_Pin{form = .MachineT, epoch = 4, record_digest = tpm_attestation.machine_key_record_digest(sealed)}
	payload := machine_payload_of(t, pin)

	Case :: struct {
		record:  string,
		present: bool,
		refusal: tpm_attestation.Pin_Refusal,
	}
	cases := [?]Case {
		{PASSPHRASE_RECORD, true, .Form_Mismatch}, // The swap for a passphrase that the attacker set.
		{OLDER_SEALED_RECORD, true, .Digest_Mismatch}, // The rollback to an older seal.
		{"", false, .Record_Absent}, // The removal.
		{"MACHINE", true, .Truncated},
		{"PRINCIPT not a record of the machine key", true, .Unknown_Form},
	}
	for item in cases {
		for state in ([?]Pin_State{.Held, .Held_Other_Policy}) {
			verdict, _, refusal := machine_record_pin_verdict(state, payload[:], transmute([]u8)item.record, item.present)
			testing.expectf(t, verdict == .Record_Pin_Mismatch && refusal == item.refusal, "the record %q in %v gave %v, %v", item.record, state, verdict, refusal)
		}
	}
	// A damaged payload of the index refuses each record, the pinned one too.
	for place in 0 ..< len(payload) {
		damaged := payload
		damaged[place] ~= 0x04
		verdict, _, refusal := machine_record_pin_verdict(.Held, damaged[:], sealed, true)
		testing.expectf(t, verdict == .Record_Pin_Mismatch && refusal != .None, "a pin damaged at byte %d took the record", place)
	}
	verdict, _, refusal := machine_record_pin_verdict(.Held, payload[:len(payload) - 1], sealed, true)
	testing.expect(t, verdict == .Record_Pin_Mismatch && refusal == .Truncated)
	verdict, _, refusal = machine_record_pin_verdict(.Held, nil, sealed, true)
	testing.expect(t, verdict == .Record_Pin_Mismatch && refusal == .Truncated)

	// No pin of this system: the record is taken, and unlock pins it.
	for state in ([?]Pin_State{.Absent, .Foreign, .Never_Written}) {
		verdict, _, refusal = machine_record_pin_verdict(state, payload[:], transmute([]u8)string(PASSPHRASE_RECORD), true)
		testing.expectf(t, verdict == .Not_Pinned && refusal == .Not_Pinned, "the state %v gave %v", state, verdict)
	}

	// The accepted cases come last: the pinned record, after an update of
	// the system too (a pin of another policy), and an announced record.
	got: tpm_attestation.Machine_Key_Pin
	verdict, got, refusal = machine_record_pin_verdict(.Held, payload[:], sealed, true)
	testing.expect(t, verdict == .Accepted && refusal == .None && got == pin)
	verdict, _, _ = machine_record_pin_verdict(.Held_Other_Policy, payload[:], sealed, true)
	testing.expect_value(t, verdict, Pin_Verdict.Accepted)
	announced, announce_refusal := tpm_attestation.machine_key_pin_announce(pin, transmute([]u8)string(NEW_SEALED_RECORD))
	testing.expect_value(t, announce_refusal, tpm_attestation.Pin_Refusal.None)
	announced_payload := machine_payload_of(t, announced)
	verdict, _, _ = machine_record_pin_verdict(.Held, announced_payload[:], transmute([]u8)string(NEW_SEALED_RECORD), true)
	testing.expect_value(t, verdict, Pin_Verdict.Accepted_Next)
	verdict, _, _ = machine_record_pin_verdict(.Held, announced_payload[:], sealed, true)
	testing.expect_value(t, verdict, Pin_Verdict.Accepted)
	verdict, _, refusal = machine_record_pin_verdict(.Held, announced_payload[:], transmute([]u8)string(OLDER_SEALED_RECORD), true)
	testing.expect(t, verdict == .Record_Pin_Mismatch && refusal == .Digest_Mismatch)
}

// A writer of the disk keeps the file of a principal, the passphrase
// changes, and the writer puts the old file back: refused, with the old
// passphrase.
@(test)
a_principal_file_rolled_back_to_an_older_passphrase_is_refused :: proc(t: ^testing.T) {
	old_file := transmute([]u8)string("PRINCIPT the file under the old passphrase")
	new_file := transmute([]u8)string("PRINCIPT the file under the new passphrase")
	first, refusal := tpm_attestation.principal_file_pin_settle({}, 1, old_file)
	testing.expect_value(t, refusal, tpm_attestation.Pin_Refusal.None)
	announced: tpm_attestation.Principal_File_Pin
	announced, refusal = tpm_attestation.principal_file_pin_announce(first, new_file)
	testing.expect_value(t, refusal, tpm_attestation.Pin_Refusal.None)
	settled: tpm_attestation.Principal_File_Pin
	settled, refusal = tpm_attestation.principal_file_pin_settle(announced, 1, new_file)
	testing.expect_value(t, refusal, tpm_attestation.Pin_Refusal.None)
	payload := principal_payload_of(t, settled)

	verdict: Pin_Verdict
	verdict, _, refusal = principal_file_pin_verdict(.Held, payload[:], 1, old_file, true)
	testing.expect(t, verdict == .Principal_File_Pin_Mismatch && refusal == .Digest_Mismatch)
	verdict, _, refusal = principal_file_pin_verdict(.Held_Other_Policy, payload[:], 1, old_file, true)
	testing.expect(t, verdict == .Principal_File_Pin_Mismatch && refusal == .Digest_Mismatch)
	verdict, _, refusal = principal_file_pin_verdict(.Held, payload[:], 1, nil, false)
	testing.expect(t, verdict == .Principal_File_Pin_Mismatch && refusal == .Record_Absent)
	// The pin of principal 1 against the number of another principal, 0,
	// and one past the limit.
	for principal in ([?]u64{2, 0, PIN_PRINCIPAL_LIMIT + 1, max(u64)}) {
		verdict, _, refusal = principal_file_pin_verdict(.Held, payload[:], principal, new_file, true)
		testing.expectf(t, verdict == .Principal_File_Pin_Mismatch && refusal == .Principal_Mismatch, "the principal %d gave %v, %v", principal, verdict, refusal)
	}
	// Each step of the change refuses the file of before the change, once
	// the settle names the new one.
	old_payload := principal_payload_of(t, first)
	announced_payload := principal_payload_of(t, announced)
	verdict, _, _ = principal_file_pin_verdict(.Held, old_payload[:], 1, new_file, true)
	testing.expect_value(t, verdict, Pin_Verdict.Principal_File_Pin_Mismatch)
	// The service refuses to put the old pin back over the new one.
	write_request := Pin_Request{kind = .Principal_File, principal = 1, bytes = len(old_payload)}
	testing.expect_value(t, pin_write_refusal(write_request, .Held, payload[:], old_payload[:]), tpm_attestation.Pin_Refusal.Generation_Rollback)

	// The accepted cases come last.
	verdict, _, refusal = principal_file_pin_verdict(.Held, payload[:], 1, new_file, true)
	testing.expect(t, verdict == .Accepted && refusal == .None)
	verdict, _, _ = principal_file_pin_verdict(.Held, announced_payload[:], 1, old_file, true)
	testing.expect_value(t, verdict, Pin_Verdict.Accepted)
	verdict, _, _ = principal_file_pin_verdict(.Held, announced_payload[:], 1, new_file, true)
	testing.expect_value(t, verdict, Pin_Verdict.Accepted_Next)
	verdict, _, _ = principal_file_pin_verdict(.Absent, nil, 1, old_file, true)
	testing.expect_value(t, verdict, Pin_Verdict.Not_Pinned)
}

// The service writes no pin that goes back, changes the form to the
// passphrase alone, names another principal, or replaces a damaged pin.
@(test)
the_service_refuses_each_pin_that_goes_back :: proc(t: ^testing.T) {
	sealed := transmute([]u8)string(SEALED_RECORD)
	current := tpm_attestation.Machine_Key_Pin{form = .MachineT, epoch = 7, record_digest = tpm_attestation.machine_key_record_digest(sealed)}
	stored := machine_payload_of(t, current)
	machine_request := Pin_Request{kind = .Machine_Key, bytes = len(stored)}

	downgrade := machine_payload_of(t, {form = .MachineK, epoch = 8, record_digest = current.record_digest})
	testing.expect_value(t, pin_write_refusal(machine_request, .Held, stored[:], downgrade[:]), tpm_attestation.Pin_Refusal.Form_Downgrade)
	older := machine_payload_of(t, {form = .MachineT, epoch = 6, record_digest = current.record_digest})
	testing.expect_value(t, pin_write_refusal(machine_request, .Held, stored[:], older[:]), tpm_attestation.Pin_Refusal.Epoch_Rollback)
	testing.expect_value(t, pin_write_refusal(machine_request, .Held_Other_Policy, stored[:], older[:]), tpm_attestation.Pin_Refusal.Epoch_Rollback)
	replay := stored
	testing.expect_value(t, pin_write_refusal(machine_request, .Held, stored[:], replay[:]), tpm_attestation.Pin_Refusal.Epoch_Replay)
	damaged_new := machine_payload_of(t, {form = .MachineT, epoch = 8, record_digest = current.record_digest})
	damaged_new[30] ~= 1
	testing.expect_value(t, pin_write_refusal(machine_request, .Held, stored[:], damaged_new[:]), tpm_attestation.Pin_Refusal.Bad_Checksum)
	damaged_stored := stored
	damaged_stored[30] ~= 1
	forward := machine_payload_of(t, {form = .MachineT, epoch = 8, record_digest = current.record_digest})
	testing.expect_value(t, pin_write_refusal(machine_request, .Held, damaged_stored[:], forward[:]), tpm_attestation.Pin_Refusal.Bad_Checksum)
	// A payload of the other kind.
	principal_payload := principal_payload_of(t, {principal = 1, generation = 1, file_digest = current.record_digest})
	testing.expect(t, pin_write_refusal(machine_request, .Absent, nil, principal_payload[:]) != .None)
	principal_request := Pin_Request{kind = .Principal_File, principal = 2, bytes = len(principal_payload)}
	testing.expect_value(t, pin_write_refusal(principal_request, .Absent, nil, principal_payload[:]), tpm_attestation.Pin_Refusal.Principal_Mismatch)

	// The accepted cases come last: a forward pin, and a first pin over no
	// index or over an index of another software, whose bytes are ignored.
	testing.expect_value(t, pin_write_refusal(machine_request, .Held, stored[:], forward[:]), tpm_attestation.Pin_Refusal.None)
	testing.expect_value(t, pin_write_refusal(machine_request, .Absent, nil, older[:]), tpm_attestation.Pin_Refusal.None)
	testing.expect_value(t, pin_write_refusal(machine_request, .Foreign, damaged_stored[:], older[:]), tpm_attestation.Pin_Refusal.None)
	principal_request.principal = 1
	testing.expect_value(t, pin_write_refusal(principal_request, .Never_Written, nil, principal_payload[:]), tpm_attestation.Pin_Refusal.None)
}
