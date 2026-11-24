#+build !freestanding
package conversation

import "core:testing"
import assistant_contract "modus:contract/assistant"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/call_outcome"
import "modus:contract/errors"

@(private = "file")
build_sample_conversation :: proc(conv: ^Conversation) {
	req1 := request_keep(conv, "list all processes")
	assert(req1 != nil)
	err: errors.Error_Record
	buf: [64]u8
	_, _, _ = request_text(conv, true, 1, buf[:], &err)
	_, _, _ = reply(conv, true, 1, "Checking processes now.", 2, &err)
	_, act1, _ := act(conv, true, 1, i64(assistant_contract.Act_Kind.Eval_Lex), "monitor.processes()", "monitor", "processes", &err)
	_, act2, _ := act(conv, true, 1, i64(assistant_contract.Act_Kind.Eval_Lex), "settings.set(.french)", "settings", "set", &err)
	_, _, _ = act_result(conv, true, act1, i64(assistant_contract.Act_State.Done), "Process: 12 rows", &err)
	_, _, _ = act_result(conv, true, act2, i64(assistant_contract.Act_State.Awaiting_Principal), "stopped for principal", &err)
	// Attach a live dialog serial to verify persist_decode clears stale dialog serials.
	act2_entry := act_of(conv, act2)
	act2_entry.dialog = 77
	_, _, _ = reply(conv, true, 1, "Done listing 12 processes.", 0, &err)

	req2 := request_keep(conv, "bad reply request")
	assert(req2 != nil)
	_, _, _ = request_text(conv, true, 2, buf[:], &err)
	_, _, _ = reply_refused(conv, true, 2, i64(errors.Kind.Bad_Value), i64(errors.Unit.Bytes), 1, 99, 10, &err)

	req3 := request_keep(conv, "stopped request")
	assert(req3 != nil)
	_, _, _ = request_text(conv, true, 3, buf[:], &err)
	_ = principal_stop(conv)
	_, _, _ = loop_end(conv, true, 3, i64(assistant_contract.Agent_Loop_End.Stopped_By_Principal), &err)
}

@(test)
persist_roundtrip_empty_and_populated_conversation :: proc(t: ^testing.T) {
	src := new(Conversation)
	defer free(src)
	dst := new(Conversation)
	defer free(dst)

	// Empty conversation roundtrip.
	empty_size := persist_encoded_size(src)
	testing.expect_value(t, empty_size, PERSIST_HEADER_BYTES)
	empty_buf := make([]u8, empty_size)
	defer delete(empty_buf)
	written, enc_refusal := persist_encode(src, empty_buf)
	testing.expect_value(t, enc_refusal, Persist_Refusal.None)
	testing.expect_value(t, written, empty_size)
	testing.expect_value(t, persist_decode(dst, empty_buf[:written]), Persist_Refusal.None)
	testing.expect_value(t, dst.entry_count, 0)
	testing.expect_value(t, dst.last_serial, u64(0))

	// Populated mixed conversation roundtrip.
	build_sample_conversation(src)
	size := persist_encoded_size(src)
	testing.expect(t, size > PERSIST_HEADER_BYTES)
	buf := make([]u8, size)
	defer delete(buf)

	// Buffer one byte too small must be refused.
	_, small_refusal := persist_encode(src, buf[:size - 1])
	testing.expect_value(t, small_refusal, Persist_Refusal.Buffer_Too_Small)

	written, enc_refusal = persist_encode(src, buf)
	testing.expect_value(t, enc_refusal, Persist_Refusal.None)
	testing.expect_value(t, written, size)

	dec_refusal := persist_decode(dst, buf[:written])
	testing.expect_value(t, dec_refusal, Persist_Refusal.None)
	testing.expect_value(t, dst.entry_count, src.entry_count)
	testing.expect_value(t, dst.last_serial, src.last_serial)
	testing.expect_value(t, dst.last_act, src.last_act)
	testing.expect_value(t, dst.last_entry, src.last_entry)

	for i in 0 ..< src.entry_count {
		a := entry_at(src, i)
		b := entry_at(dst, i)
		testing.expect_value(t, b.kind, a.kind)
		testing.expect_value(t, b.number, a.number)
		testing.expect_value(t, b.serial, a.serial)
		testing.expect_value(t, b.act, a.act)
		testing.expect_value(t, b.act_kind, a.act_kind)
		testing.expect_value(t, b.state, a.state)
		testing.expect_value(t, b.turn, a.turn)
		testing.expect_value(t, b.step, a.step)
		testing.expect_value(t, b.taken, a.taken)
		testing.expect_value(t, b.stop_requested, a.stop_requested)
		testing.expect_value(t, b.end_cause, a.end_cause)
		testing.expect_value(t, string(b.text[:b.text_count]), string(a.text[:a.text_count]))
		testing.expect_value(t, string(b.line[:b.line_count]), string(a.line[:a.line_count]))
		testing.expect_value(t, string(b.service[:b.service_count]), string(a.service[:a.service_count]))
		testing.expect_value(t, string(b.export[:b.export_count]), string(a.export[:a.export_count]))
		// Stale dialog serials must be cleared on reload.
		testing.expect_value(t, b.dialog, u64(0))
	}
}

@(test)
persist_roundtrip_wrapped_full_ring :: proc(t: ^testing.T) {
	src := new(Conversation)
	defer free(src)
	dst := new(Conversation)
	defer free(dst)

	// Push more than CONVERSATION_ENTRY_CAPACITY requests so entry_first wraps.
	for i in 0 ..< assistant_contract.CONVERSATION_ENTRY_CAPACITY + 17 {
		_ = request_keep(src, "ring wrap request")
		_ = i
	}
	testing.expect_value(t, src.entry_count, assistant_contract.CONVERSATION_ENTRY_CAPACITY)
	testing.expect(t, src.entry_first > 0)

	size := persist_encoded_size(src)
	buf := make([]u8, size)
	defer delete(buf)
	written, enc_refusal := persist_encode(src, buf)
	testing.expect_value(t, enc_refusal, Persist_Refusal.None)
	testing.expect_value(t, persist_decode(dst, buf[:written]), Persist_Refusal.None)
	testing.expect_value(t, dst.entry_count, assistant_contract.CONVERSATION_ENTRY_CAPACITY)
	testing.expect_value(t, entry_at(dst, 0).number, entry_at(src, 0).number)
	testing.expect_value(t, entry_at(dst, dst.entry_count - 1).number, entry_at(src, src.entry_count - 1).number)
}

@(private = "file")
resign_persisted :: proc(buf: []u8) {
	digest := blake3.derive_key(PERSIST_HASH_DOMAIN, buf[PERSIST_SIGNED_OFFSET:])
	copy(buf[PERSIST_HASH_OFFSET:PERSIST_HASH_OFFSET + blake3.HASH_SIZE], digest[:])
}

@(test)
persist_decode_refuses_corrupt_data_without_mutating_destination :: proc(t: ^testing.T) {
	src := new(Conversation)
	defer free(src)
	build_sample_conversation(src)
	size := persist_encoded_size(src)
	good := make([]u8, size)
	defer delete(good)
	written, enc_refusal := persist_encode(src, good)
	testing.expect_value(t, enc_refusal, Persist_Refusal.None)

	// Seed destination with an existing request to verify refusal mutates nothing.
	dst := new(Conversation)
	defer free(dst)
	_ = request_keep(dst, "keep me intact")
	sentinel_serial := dst.last_serial
	sentinel_count := dst.entry_count

	// 1. Truncated header (0 bytes, 1 byte, 79 bytes).
	testing.expect_value(t, persist_decode(dst, nil), Persist_Refusal.Truncated)
	testing.expect_value(t, persist_decode(dst, good[:1]), Persist_Refusal.Truncated)
	testing.expect_value(t, persist_decode(dst, good[:PERSIST_HEADER_BYTES - 1]), Persist_Refusal.Truncated)

	// 2. Truncated payload.
	testing.expect_value(t, persist_decode(dst, good[:written - 1]), Persist_Refusal.Truncated)

	// 3. Trailing byte past payload.
	trailing := make([]u8, written + 1)
	defer delete(trailing)
	copy(trailing, good[:written])
	testing.expect_value(t, persist_decode(dst, trailing), Persist_Refusal.Trailing_Bytes)

	// 4. Bad magic.
	corrupt := make([]u8, written)
	defer delete(corrupt)
	copy(corrupt, good[:written])
	corrupt[0] = 'X'
	testing.expect_value(t, persist_decode(dst, corrupt), Persist_Refusal.Bad_Magic)

	// 5. Unsupported version.
	copy(corrupt, good[:written])
	byte_order.write_u32_little_endian(corrupt, 40, PERSIST_VERSION + 1)
	resign_persisted(corrupt)
	testing.expect_value(t, persist_decode(dst, corrupt), Persist_Refusal.Unsupported_Version)

	// 6. Flipped digest bit -> Hash_Mismatch.
	copy(corrupt, good[:written])
	corrupt[PERSIST_HASH_OFFSET] ~= 0x01
	testing.expect_value(t, persist_decode(dst, corrupt), Persist_Refusal.Hash_Mismatch)

	// 7. Flipped payload byte without re-signing -> Hash_Mismatch.
	copy(corrupt, good[:written])
	corrupt[written - 1] ~= 0x01
	testing.expect_value(t, persist_decode(dst, corrupt), Persist_Refusal.Hash_Mismatch)

	// 8. Reserved header bits set (even if re-signed) -> Bad_Flags.
	copy(corrupt, good[:written])
	byte_order.write_u32_little_endian(corrupt, 76, 1)
	resign_persisted(corrupt)
	testing.expect_value(t, persist_decode(dst, corrupt), Persist_Refusal.Bad_Flags)

	// 9. Entry count past ring capacity -> Bad_Count.
	copy(corrupt, good[:written])
	byte_order.write_u32_little_endian(corrupt, 44, u32(assistant_contract.CONVERSATION_ENTRY_CAPACITY + 1))
	resign_persisted(corrupt)
	testing.expect_value(t, persist_decode(dst, corrupt), Persist_Refusal.Bad_Count)

	// 10. Invalid Entry_Kind enum word (even when re-signed) -> Bad_Enum.
	copy(corrupt, good[:written])
	corrupt[PERSIST_HEADER_BYTES + 0] = 99
	resign_persisted(corrupt)
	testing.expect_value(t, persist_decode(dst, corrupt), Persist_Refusal.Bad_Enum)

	// 11. Unknown flag bit set in entry (even when re-signed) -> Bad_Flags.
	copy(corrupt, good[:written])
	corrupt[PERSIST_HEADER_BYTES + 9] = 0x80
	resign_persisted(corrupt)
	testing.expect_value(t, persist_decode(dst, corrupt), Persist_Refusal.Bad_Flags)

	// 12. Control byte injected into first request text (even when re-signed) -> Bad_Text.
	copy(corrupt, good[:written])
	corrupt[PERSIST_HEADER_BYTES + PERSIST_ENTRY_HEADER_BYTES] = '\n'
	resign_persisted(corrupt)
	testing.expect_value(t, persist_decode(dst, corrupt), Persist_Refusal.Bad_Text)

	// 13. Entry number past last_entry (even when re-signed) -> Bad_Counters.
	copy(corrupt, good[:written])
	byte_order.write_u64_little_endian(corrupt, PERSIST_HEADER_BYTES + 16, src.last_entry + 1)
	resign_persisted(corrupt)
	testing.expect_value(t, persist_decode(dst, corrupt), Persist_Refusal.Bad_Counters)

	// Destination must remain completely intact after all 13 refusals.
	testing.expect_value(t, dst.last_serial, sentinel_serial)
	testing.expect_value(t, dst.entry_count, sentinel_count)
	testing.expect_value(t, string(entry_at(dst, 0).text[:entry_at(dst, 0).text_count]), "keep me intact")
}

// A persisted Allowed_By_Principal act must downgrade to Refused on reload so
// approvals cannot outlive a wide grant or replay across a window restart.
@(test)
persist_decode_downgrades_allowed_by_principal_across_restart :: proc(t: ^testing.T) {
	src := new(Conversation)
	defer free(src)
	dst := new(Conversation)
	defer free(dst)

	_ = request_keep(src, "change setting")
	err: errors.Error_Record
	req_buf: [64]u8
	_, _, _ = request_text(src, true, 1, req_buf[:], &err)
	_, _, _ = reply(src, true, 1, "proposing setting change", 1, &err)
	_, act_num, _ := act(src, true, 1, i64(assistant_contract.Act_Kind.Eval_Lex), "settings.set(.french)", "settings", "set", &err)
	_, _, _ = act_result(src, true, act_num, i64(assistant_contract.Act_State.Awaiting_Principal), "waiting", &err)
	act_of(src, act_num).state = .Allowed_By_Principal

	size := persist_encoded_size(src)
	buf := make([]u8, size)
	defer delete(buf)
	written, enc_refusal := persist_encode(src, buf)
	testing.expect_value(t, enc_refusal, Persist_Refusal.None)
	testing.expect_value(t, persist_decode(dst, buf[:written]), Persist_Refusal.None)

	reloaded := act_of(dst, act_num)
	testing.expect(t, reloaded != nil)
	testing.expect_value(t, reloaded.state, assistant_contract.Act_State.Refused)

	// Verify act_line returns the authoritative line and refuses small buffers.
	line_buf: [64]u8
	line_out, line_len := act_line(dst, true, act_num, line_buf[:], &err)
	testing.expect_value(t, line_out, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, string(line_buf[:line_len]), "settings.set(.french)")
	small_out, _ := act_line(dst, true, act_num, line_buf[:4], &err)
	testing.expect_value(t, small_out, call_outcome.Call_Outcome.Argument_Refused)
	no_grant_out, _ := act_line(dst, false, act_num, line_buf[:], &err)
	testing.expect_value(t, no_grant_out, call_outcome.Call_Outcome.Grant_Or_Right_Missing)
}
