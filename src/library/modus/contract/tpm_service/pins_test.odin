#+build !freestanding
package tpm_service

import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/tpm_attestation"

// The principal identifier of the pins of these tests.
TEST_IDENTIFIER :: tpm_attestation.Identifier{0 = 0xA1, 31 = 0x5C}

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
		_, status, _ := request_of_record(u32(Command.Pin_Read), values, .Client_Ring)
		testing.expect_value(t, status, call_outcome.Call_Outcome.Argument_Refused)
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
	_, status, _ := request_of_record(u32(Command.Pin_Read), {0 = u64(Pin_Kind.Machine_Key)}, .Measure_Ring)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Grant_Or_Right_Missing)
	_, status, _ = request_of_record(u32(Command.Pin_Write), {0 = u64(Pin_Kind.Machine_Key), 2 = machine_size}, .Measure_Ring)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Grant_Or_Right_Missing)
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
	parsed, status, _ = request_of_record(u32(Command.Pin_Write), {0 = u64(Pin_Kind.Machine_Key), 2 = machine_size}, .Client_Ring)
	testing.expect(t, status == .Succeeded && parsed.command == .Pin_Write && parsed.authorization == .None)
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
	first, refusal := tpm_attestation.principal_file_pin_settle({}, 1, TEST_IDENTIFIER, old_file)
	testing.expect_value(t, refusal, tpm_attestation.Pin_Refusal.None)
	announced: tpm_attestation.Principal_File_Pin
	announced, refusal = tpm_attestation.principal_file_pin_announce(first, new_file)
	testing.expect_value(t, refusal, tpm_attestation.Pin_Refusal.None)
	settled: tpm_attestation.Principal_File_Pin
	settled, refusal = tpm_attestation.principal_file_pin_settle(announced, 1, TEST_IDENTIFIER, new_file)
	testing.expect_value(t, refusal, tpm_attestation.Pin_Refusal.None)
	payload := principal_payload_of(t, settled)

	verdict: Pin_Verdict
	verdict, _, refusal = principal_file_pin_verdict(.Held, payload[:], 1, TEST_IDENTIFIER, old_file, true)
	testing.expect(t, verdict == .Principal_File_Pin_Mismatch && refusal == .Digest_Mismatch)
	verdict, _, refusal = principal_file_pin_verdict(.Held_Other_Policy, payload[:], 1, TEST_IDENTIFIER, old_file, true)
	testing.expect(t, verdict == .Principal_File_Pin_Mismatch && refusal == .Digest_Mismatch)
	verdict, _, refusal = principal_file_pin_verdict(.Held, payload[:], 1, TEST_IDENTIFIER, nil, false)
	testing.expect(t, verdict == .Principal_File_Pin_Mismatch && refusal == .Record_Absent)
	// The pin of principal 1 against the number of another principal, 0,
	// and one past the limit.
	for principal in ([?]u64{2, 0, PIN_PRINCIPAL_LIMIT + 1, max(u64)}) {
		verdict, _, refusal = principal_file_pin_verdict(.Held, payload[:], principal, TEST_IDENTIFIER, new_file, true)
		testing.expectf(t, verdict == .Principal_File_Pin_Mismatch && refusal == .Principal_Mismatch, "the principal %d gave %v, %v", principal, verdict, refusal)
	}
	// Each step of the change refuses the file of before the change, once
	// the settle names the new one.
	old_payload := principal_payload_of(t, first)
	announced_payload := principal_payload_of(t, announced)
	verdict, _, _ = principal_file_pin_verdict(.Held, old_payload[:], 1, TEST_IDENTIFIER, new_file, true)
	testing.expect_value(t, verdict, Pin_Verdict.Principal_File_Pin_Mismatch)
	// The service refuses to put the old pin back over the new one.
	write_request := Pin_Request{kind = .Principal_File, principal = 1, bytes = len(old_payload)}
	testing.expect_value(t, pin_write_refusal(write_request, .Held, payload[:], old_payload[:]), tpm_attestation.Pin_Refusal.Generation_Rollback)

	// The accepted cases come last.
	verdict, _, refusal = principal_file_pin_verdict(.Held, payload[:], 1, TEST_IDENTIFIER, new_file, true)
	testing.expect(t, verdict == .Accepted && refusal == .None)
	verdict, _, _ = principal_file_pin_verdict(.Held, announced_payload[:], 1, TEST_IDENTIFIER, old_file, true)
	testing.expect_value(t, verdict, Pin_Verdict.Accepted)
	verdict, _, _ = principal_file_pin_verdict(.Held, announced_payload[:], 1, TEST_IDENTIFIER, new_file, true)
	testing.expect_value(t, verdict, Pin_Verdict.Accepted_Next)
	verdict, _, _ = principal_file_pin_verdict(.Absent, nil, 1, TEST_IDENTIFIER, old_file, true)
	testing.expect_value(t, verdict, Pin_Verdict.Not_Pinned)
}

// A Free pin ("free, generation g") accepts an absent file as Free_Slot,
// refuses a rolled-back file on disk with Slot_Free, and lets the TPM service
// advance Free(g) -> Active(B, g+1) while refusing Free -> Free and rollback.
@(test)
free_pin_verdict_and_recreation_cycle :: proc(t: ^testing.T) {
	file_a := transmute([]u8)string("PRINCIPT file A")
	file_b := transmute([]u8)string("PRINCIPT file B")
	id_b := TEST_IDENTIFIER
	id_b[0] ~= 0x55

	pin_a, ref := tpm_attestation.principal_file_pin_settle({}, 1, TEST_IDENTIFIER, file_a)
	testing.expect_value(t, ref, tpm_attestation.Pin_Refusal.None)
	payload_a := principal_payload_of(t, pin_a)

	freed, free_ref := tpm_attestation.principal_file_pin_free(pin_a)
	testing.expect_value(t, free_ref, tpm_attestation.Pin_Refusal.None)
	payload_free := principal_payload_of(t, freed)

	req := Pin_Request{kind = .Principal_File, principal = 1, bytes = len(payload_free)}
	// Active -> Free accepted by service; Absent -> Free refused; Free -> Free refused.
	testing.expect_value(t, pin_write_refusal(req, .Held, payload_a[:], payload_free[:]), tpm_attestation.Pin_Refusal.None)
	testing.expect_value(t, pin_write_refusal(req, .Absent, nil, payload_free[:]), tpm_attestation.Pin_Refusal.Not_Pinned)
	freed_again := freed
	freed_again.generation = 3
	payload_free3 := principal_payload_of(t, freed_again)
	testing.expect_value(t, pin_write_refusal(req, .Held, payload_free[:], payload_free3[:]), tpm_attestation.Pin_Refusal.Slot_Free)

	// Verdict on Free pin: absent -> Free_Slot; planted file -> Mismatch(Slot_Free).
	v, decoded, vref := principal_file_pin_verdict(.Held, payload_free[:], 1, {}, nil, false)
	testing.expect(t, v == .Free_Slot && vref == .None && decoded == freed)
	v, _, vref = principal_file_pin_verdict(.Held, payload_free[:], 1, TEST_IDENTIFIER, file_a, true)
	testing.expect(t, v == .Principal_File_Pin_Mismatch && vref == .Slot_Free)

	// Recreate in freed slot: Free(2) -> Active(B, 3) accepted by service.
	pin_b, b_ref := tpm_attestation.principal_file_pin_settle(freed, 1, id_b, file_b)
	testing.expect_value(t, b_ref, tpm_attestation.Pin_Refusal.None)
	payload_b := principal_payload_of(t, pin_b)
	testing.expect_value(t, pin_write_refusal(req, .Held, payload_free[:], payload_b[:]), tpm_attestation.Pin_Refusal.None)
	testing.expect_value(t, pin_write_refusal(req, .Held, payload_b[:], payload_a[:]), tpm_attestation.Pin_Refusal.Generation_Rollback)
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
	principal_payload := principal_payload_of(t, {identifier = TEST_IDENTIFIER, principal = 1, generation = 1, file_digest = current.record_digest})
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

// A stop between the write of the store and the settle: the next start
// finds the new record as the announced one and settles the pin. From then
// on the record of before is refused, and the service never writes a pin
// that names it again.
@(test)
a_crash_before_the_settle_retires_the_old_record_at_the_next_start :: proc(t: ^testing.T) {
	old_record := transmute([]u8)string(SEALED_RECORD)
	new_record := transmute([]u8)string(NEW_SEALED_RECORD)
	first, refusal := tpm_attestation.machine_key_pin_settle({}, old_record)
	testing.expect_value(t, refusal, tpm_attestation.Pin_Refusal.None)
	// The announce is written, the store keeps the new record, the machine stops.
	announced: tpm_attestation.Machine_Key_Pin
	announced, refusal = tpm_attestation.machine_key_pin_announce(first, new_record)
	testing.expect_value(t, refusal, tpm_attestation.Pin_Refusal.None)
	announced_payload := machine_payload_of(t, announced)

	// The start after the stop: the new record is the announced one, and
	// unlock settles on it, which the service takes.
	verdict, pin, _ := machine_record_pin_verdict(.Held, announced_payload[:], new_record, true)
	testing.expect_value(t, verdict, Pin_Verdict.Accepted_Next)
	settled: tpm_attestation.Machine_Key_Pin
	settled, refusal = tpm_attestation.machine_key_pin_settle(pin, new_record)
	testing.expect_value(t, refusal, tpm_attestation.Pin_Refusal.None)
	settled_payload := machine_payload_of(t, settled)
	machine_request := Pin_Request{kind = .Machine_Key, bytes = len(settled_payload)}
	testing.expect_value(t, pin_write_refusal(machine_request, .Held, announced_payload[:], settled_payload[:]), tpm_attestation.Pin_Refusal.None)

	// A writer of the disk then puts the old record back: refused at each
	// later start.
	verdict, _, refusal = machine_record_pin_verdict(.Held, settled_payload[:], old_record, true)
	testing.expect(t, verdict == .Record_Pin_Mismatch && refusal == .Digest_Mismatch)
	verdict, _, refusal = machine_record_pin_verdict(.Held_Other_Policy, settled_payload[:], old_record, true)
	testing.expect(t, verdict == .Record_Pin_Mismatch && refusal == .Digest_Mismatch)
	// And no pin that names the old record again is written: neither the
	// first pin, nor the announce, nor a settle on the old record.
	first_payload := machine_payload_of(t, first)
	testing.expect_value(t, pin_write_refusal(machine_request, .Held, settled_payload[:], first_payload[:]), tpm_attestation.Pin_Refusal.Epoch_Rollback)
	testing.expect_value(t, pin_write_refusal(machine_request, .Held, settled_payload[:], announced_payload[:]), tpm_attestation.Pin_Refusal.Epoch_Rollback)
	back_to_old := tpm_attestation.Machine_Key_Pin{form = .MachineT, epoch = settled.epoch, record_digest = first.record_digest}
	back_payload := machine_payload_of(t, back_to_old)
	testing.expect_value(t, pin_write_refusal(machine_request, .Held, settled_payload[:], back_payload[:]), tpm_attestation.Pin_Refusal.Epoch_Replay)

	// The same for the file of a principal.
	old_file := transmute([]u8)string("PRINCIPT the file before the change")
	new_file := transmute([]u8)string("PRINCIPT the file after the change")
	principal_first, _ := tpm_attestation.principal_file_pin_settle({}, 1, TEST_IDENTIFIER, old_file)
	principal_announced, _ := tpm_attestation.principal_file_pin_announce(principal_first, new_file)
	principal_announced_payload := principal_payload_of(t, principal_announced)
	principal_pin: tpm_attestation.Principal_File_Pin
	verdict, principal_pin, _ = principal_file_pin_verdict(.Held, principal_announced_payload[:], 1, TEST_IDENTIFIER, new_file, true)
	testing.expect_value(t, verdict, Pin_Verdict.Accepted_Next)
	principal_settled, settle_refusal := tpm_attestation.principal_file_pin_settle(principal_pin, 1, TEST_IDENTIFIER, new_file)
	testing.expect_value(t, settle_refusal, tpm_attestation.Pin_Refusal.None)
	principal_settled_payload := principal_payload_of(t, principal_settled)
	verdict, _, refusal = principal_file_pin_verdict(.Held, principal_settled_payload[:], 1, TEST_IDENTIFIER, old_file, true)
	testing.expect(t, verdict == .Principal_File_Pin_Mismatch && refusal == .Digest_Mismatch)
	// The accepted case comes last.
	verdict, _, _ = principal_file_pin_verdict(.Held, principal_settled_payload[:], 1, TEST_IDENTIFIER, new_file, true)
	testing.expect_value(t, verdict, Pin_Verdict.Accepted)
}

// A writer of the disk removes the file of a pinned principal: the pin
// refuses the absence, and the service writes no pin that starts the slot
// again at generation 1 or below the pinned generation.
@(test)
a_removed_principal_file_is_never_a_new_principal :: proc(t: ^testing.T) {
	file := transmute([]u8)string("PRINCIPT the file of alice")
	other_file := transmute([]u8)string("PRINCIPT the file of a new principal")
	pinned := tpm_attestation.Principal_File_Pin{identifier = TEST_IDENTIFIER, principal = 1, generation = 5, file_digest = tpm_attestation.principal_file_digest(file)}
	payload := principal_payload_of(t, pinned)
	for state in ([?]Pin_State{.Held, .Held_Other_Policy}) {
		verdict, _, refusal := principal_file_pin_verdict(state, payload[:], 1, TEST_IDENTIFIER, nil, false)
		testing.expectf(t, verdict == .Principal_File_Pin_Mismatch && refusal == .Record_Absent, "a removed file in %v gave %v", state, verdict)
	}
	request := Pin_Request{kind = .Principal_File, principal = 1, bytes = len(payload)}
	for generation in ([?]u64{1, 4, 5}) {
		reset := principal_payload_of(t, {identifier = TEST_IDENTIFIER, principal = 1, generation = generation, file_digest = tpm_attestation.principal_file_digest(other_file)})
		refusal := pin_write_refusal(request, .Held, payload[:], reset[:])
		testing.expectf(t, refusal == .Generation_Rollback || refusal == .Generation_Replay, "a pin of generation %d over generation 5 gave %v", generation, refusal)
		refusal = pin_write_refusal(request, .Held_Other_Policy, payload[:], reset[:])
		testing.expectf(t, refusal == .Generation_Rollback || refusal == .Generation_Replay, "a pin of generation %d over an older policy gave %v", generation, refusal)
	}
	// The pin of the machine key refuses the removal of its record too.
	sealed := transmute([]u8)string(SEALED_RECORD)
	machine := machine_payload_of(t, {form = .MachineT, epoch = 3, record_digest = tpm_attestation.machine_key_record_digest(sealed)})
	verdict, _, refusal := machine_record_pin_verdict(.Held, machine[:], nil, false)
	testing.expect(t, verdict == .Record_Pin_Mismatch && refusal == .Record_Absent)
	machine_request := Pin_Request{kind = .Machine_Key, bytes = len(machine)}
	restart := machine_payload_of(t, {form = .MachineK, epoch = 1, record_digest = tpm_attestation.machine_key_record_digest(sealed)})
	testing.expect_value(t, pin_write_refusal(machine_request, .Held, machine[:], restart[:]), tpm_attestation.Pin_Refusal.Form_Downgrade)
	restart_same_form := machine_payload_of(t, {form = .MachineT, epoch = 1, record_digest = tpm_attestation.machine_key_record_digest(sealed)})
	testing.expect_value(t, pin_write_refusal(machine_request, .Held, machine[:], restart_same_form[:]), tpm_attestation.Pin_Refusal.Epoch_Rollback)
}

// A pin that names two records, A current and B announced, whose settle
// failed: a new announce of C is refused, by the rules of unlock and by the
// service, so a stop before the write of C never leaves B on the disk and
// refused. After the settle on B, the announce of C goes.
@(test)
an_unsettled_pin_refuses_a_new_announce :: proc(t: ^testing.T) {
	record_a := transmute([]u8)string(SEALED_RECORD)
	record_b := transmute([]u8)string(NEW_SEALED_RECORD)
	record_c := transmute([]u8)string("MACHINET the record of a third seal")
	first, _ := tpm_attestation.machine_key_pin_settle({}, record_a)
	announced, _ := tpm_attestation.machine_key_pin_announce(first, record_b)
	announced_payload := machine_payload_of(t, announced)
	verdict, pin, _ := machine_record_pin_verdict(.Held, announced_payload[:], record_b, true)
	testing.expect_value(t, verdict, Pin_Verdict.Accepted_Next)

	// The settle on B failed: the pin still names A and B.
	_, refusal := tpm_attestation.machine_key_pin_announce(pin, record_c)
	testing.expect_value(t, refusal, tpm_attestation.Pin_Refusal.Announce_Pending)
	over := tpm_attestation.Machine_Key_Pin{form = .MachineT, epoch = announced.epoch + 1, record_digest = announced.record_digest, next_digest = tpm_attestation.machine_key_record_digest(record_c)}
	over_payload := machine_payload_of(t, over)
	request := Pin_Request{kind = .Machine_Key, bytes = len(over_payload)}
	testing.expect_value(t, pin_write_refusal(request, .Held, announced_payload[:], over_payload[:]), tpm_attestation.Pin_Refusal.Announce_Pending)
	testing.expect_value(t, pin_write_refusal(request, .Held_Other_Policy, announced_payload[:], over_payload[:]), tpm_attestation.Pin_Refusal.Announce_Pending)

	// The same for the file of a principal.
	file_a := transmute([]u8)string("PRINCIPT file A")
	file_b := transmute([]u8)string("PRINCIPT file B")
	file_c := transmute([]u8)string("PRINCIPT file C")
	principal_first, _ := tpm_attestation.principal_file_pin_settle({}, 1, TEST_IDENTIFIER, file_a)
	principal_announced, _ := tpm_attestation.principal_file_pin_announce(principal_first, file_b)
	_, refusal = tpm_attestation.principal_file_pin_announce(principal_announced, file_c)
	testing.expect_value(t, refusal, tpm_attestation.Pin_Refusal.Announce_Pending)
	principal_announced_payload := principal_payload_of(t, principal_announced)
	principal_over := principal_announced
	principal_over.generation += 1
	principal_over.next_digest = tpm_attestation.principal_file_digest(file_c)
	principal_over_payload := principal_payload_of(t, principal_over)
	principal_request := Pin_Request{kind = .Principal_File, principal = 1, bytes = len(principal_over_payload)}
	testing.expect_value(t, pin_write_refusal(principal_request, .Held, principal_announced_payload[:], principal_over_payload[:]), tpm_attestation.Pin_Refusal.Announce_Pending)

	// The accepted cases come last: the settle on B, then the announce of C.
	settled, settle_refusal := tpm_attestation.machine_key_pin_settle(pin, record_b)
	testing.expect_value(t, settle_refusal, tpm_attestation.Pin_Refusal.None)
	next: tpm_attestation.Machine_Key_Pin
	next, refusal = tpm_attestation.machine_key_pin_announce(settled, record_c)
	testing.expect_value(t, refusal, tpm_attestation.Pin_Refusal.None)
	settled_payload := machine_payload_of(t, settled)
	next_payload := machine_payload_of(t, next)
	testing.expect_value(t, pin_write_refusal(request, .Held, settled_payload[:], next_payload[:]), tpm_attestation.Pin_Refusal.None)
	principal_settled, _ := tpm_attestation.principal_file_pin_settle(principal_announced, 1, TEST_IDENTIFIER, file_b)
	_, refusal = tpm_attestation.principal_file_pin_announce(principal_settled, file_c)
	testing.expect_value(t, refusal, tpm_attestation.Pin_Refusal.None)
}

@(test)
the_word_of_a_pin_refusal_crosses_its_border :: proc(t: ^testing.T) {
	for word in ([?]u64{u64(max(tpm_attestation.Pin_Refusal)) + 1, 255, 256, max(u64)}) {
		_, ok := tpm_attestation.pin_refusal_of_word(word)
		testing.expectf(t, !ok, "the word %d named a refusal", word)
	}
	for refusal in tpm_attestation.Pin_Refusal {
		read, ok := tpm_attestation.pin_refusal_of_word(u64(refusal))
		testing.expect(t, ok && read == refusal)
	}
}
