#+build !freestanding
package object_cache

import "core:testing"
import "modus:contract/blake3"

@(private = "file")
build_test_outboard_with :: proc(
	t: ^testing.T,
	data: []u8,
	frame_bytes: u64,
) -> (root: blake3.Hash, outboard: [][OUTBOARD_ENTRY_SIZE]u8) {
	builder := frame_tree_builder_start_with(u64(len(data)), frame_bytes)
	parent_total := builder.frame_count > 0 ? int(builder.frame_count - 1) : 0
	outboard = make([][OUTBOARD_ENTRY_SIZE]u8, parent_total, context.temp_allocator)
	for idx in u64(0) ..< builder.frame_count {
		flen, ok := frame_length_with(u64(len(data)), idx, frame_bytes)
		testing.expect(t, ok)
		start := int(idx * frame_bytes)
		parents: [MAX_PROOF_DEPTH]Frame_Parent
		pcount, add_ok := frame_tree_builder_add(&builder, data[start:start + int(flen)], &parents)
		testing.expect(t, add_ok)
		for p in parents[:pcount] {
			outboard[int(p.index)] = frame_parent_entry(p)
		}
	}
	testing.expect(t, builder.finished)
	testing.expect_value(t, builder.root, blake3.hash(data))
	return builder.root, outboard
}

@(private = "file")
proof_for_frame :: proc(
	t: ^testing.T,
	frame_count: u64,
	frame_index: u64,
	outboard: [][OUTBOARD_ENTRY_SIZE]u8,
	dst: []u8,
) -> []u8 {
	path, ok := object_frame_path(frame_count, frame_index)
	testing.expect(t, ok)
	for level in 0 ..< path.depth {
		sibling := frame_proof_entry(outboard[int(path.parent_index[level])], path.in_left[level])
		copy(dst[level * PROOF_ENTRY_SIZE:(level + 1) * PROOF_ENTRY_SIZE], sibling[:])
	}
	return dst[:path.depth * PROOF_ENTRY_SIZE]
}

@(test)
resumable_put_refusal_border_refuses_unknown_words :: proc(t: ^testing.T) {
	for member in Resumable_Put_Refusal {
		got, ok := resumable_put_refusal_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, got, member)
	}
	for bad in ([?]u64{11, 255, max(u64)}) {
		_, ok := resumable_put_refusal_of_word(bad)
		testing.expectf(t, !ok, "word %d must not map to Resumable_Put_Refusal", bad)
	}
}

@(test)
resumable_put_init_and_frame_edges_refuse_without_mutation :: proc(t: ^testing.T) {
	session: Resumable_Put_Session
	valid_hash := blake3.hash(transmute([]u8)string("seed"))

	testing.expect_value(t, resumable_put_init(nil, .Blob, valid_hash, 10), Resumable_Put_Refusal.Bad_Session)
	testing.expect_value(t, resumable_put_init(&session, Cache_Object_Kind(99), valid_hash, 10), Resumable_Put_Refusal.Bad_Object_Kind)
	testing.expect_value(t, resumable_put_init(&session, .Blob, {}, 10), Resumable_Put_Refusal.Zero_Hash)
	testing.expect_value(t, resumable_put_init(&session, .Blob, valid_hash, MAX_OBJECT_BYTES + 1), Resumable_Put_Refusal.Too_Large)
	testing.expect_value(t, resumable_put_init(&session, .Tree, valid_hash, u64(MAX_TREE_PAYLOAD_BYTES) + 1), Resumable_Put_Refusal.Too_Large)
	testing.expect(t, !session.initialized)

	_, off_ok := resumable_put_resume_offset(&session)
	testing.expect(t, !off_ok)
	testing.expect(t, !resumable_put_is_complete(&session))
	testing.expect_value(t, resumable_put_accept_frame(&session, 0, nil, nil), Resumable_Put_Refusal.Bad_Session)

	// Empty 0-byte blob completes in 1 frame with empty proof.
	empty_hash := blake3.hash(nil)
	testing.expect_value(t, resumable_put_init(&session, .Blob, empty_hash, 0), Resumable_Put_Refusal.None)
	testing.expect_value(t, resumable_put_accept_frame(&session, 0, nil, nil), Resumable_Put_Refusal.None)
	testing.expect(t, resumable_put_is_complete(&session))
	off, ok := resumable_put_resume_offset(&session)
	testing.expect(t, ok && off == 0)
	testing.expect_value(t, resumable_put_accept_frame(&session, 0, nil, nil), Resumable_Put_Refusal.Already_Complete)
}

@(test)
resumable_put_multiframe_out_of_order_resume_and_refusals :: proc(t: ^testing.T) {
	FRAME_BYTES :: u64(blake3.CHUNK_SIZE)
	// 5 frames: 4 full 1 KiB frames + 321-byte tail.
	total_size := int(4 * FRAME_BYTES + 321)
	blob := make([]u8, total_size, context.temp_allocator)
	for i in 0 ..< total_size {
		blob[i] = u8((i * 97 + 13) & 0xFF)
	}
	root, outboard := build_test_outboard_with(t, blob, FRAME_BYTES)

	session: Resumable_Put_Session
	testing.expect_value(t, resumable_put_init_with(&session, .Blob, root, u64(total_size), FRAME_BYTES), Resumable_Put_Refusal.None)
	testing.expect_value(t, session.frame_count, u64(5))

	proof_buf: [MAX_PROOF_DEPTH * PROOF_ENTRY_SIZE]u8

	// Frame index out of range (5 and max(u64)) refused without mutation.
	before := session
	testing.expect_value(t, resumable_put_accept_frame(&session, 5, nil, blob[:10]), Resumable_Put_Refusal.Frame_Out_Of_Range)
	testing.expect_value(t, resumable_put_accept_frame(&session, max(u64), nil, blob[:10]), Resumable_Put_Refusal.Frame_Out_Of_Range)
	testing.expect_value(t, session, before)

	// Truncated/oversized frame refused without mutation.
	p0 := proof_for_frame(t, 5, 0, outboard, proof_buf[:])
	testing.expect_value(t, resumable_put_accept_frame(&session, 0, p0, blob[:FRAME_BYTES - 1]), Resumable_Put_Refusal.Bad_Frame_Length)
	testing.expect_value(t, session, before)

	// Truncated proof refused without mutation.
	testing.expect_value(t, resumable_put_accept_frame(&session, 0, p0[:len(p0) - 1], blob[:FRAME_BYTES]), Resumable_Put_Refusal.Bad_Proof)
	testing.expect_value(t, session, before)

	// Corrupted proof byte refused with Hash_Mismatch without mutation.
	bad_proof := make([]u8, len(p0), context.temp_allocator)
	copy(bad_proof, p0)
	bad_proof[0] ~= 0x01
	testing.expect_value(t, resumable_put_accept_frame(&session, 0, bad_proof, blob[:FRAME_BYTES]), Resumable_Put_Refusal.Hash_Mismatch)
	testing.expect_value(t, session, before)

	// Tampered frame byte refused with Hash_Mismatch without mutation.
	bad_frame := make([]u8, int(FRAME_BYTES), context.temp_allocator)
	copy(bad_frame, blob[:FRAME_BYTES])
	bad_frame[17] ~= 0x80
	testing.expect_value(t, resumable_put_accept_frame(&session, 0, p0, bad_frame), Resumable_Put_Refusal.Hash_Mismatch)
	testing.expect_value(t, session, before)

	// Accept frame 0 -> resume offset advances to 1024.
	testing.expect_value(t, resumable_put_accept_frame(&session, 0, p0, blob[:FRAME_BYTES]), Resumable_Put_Refusal.None)
	off, ok := resumable_put_resume_offset(&session)
	testing.expect(t, ok && off == FRAME_BYTES)

	// Duplicate frame 0 -> Frame_Conflict without mutating session.
	snap_after_0 := session
	testing.expect_value(t, resumable_put_accept_frame(&session, 0, p0, blob[:FRAME_BYTES]), Resumable_Put_Refusal.Frame_Conflict)
	testing.expect_value(t, session, snap_after_0)

	// Accept frame 2 out of order -> resume offset stays at 1024 (frame 1 missing).
	p2 := proof_for_frame(t, 5, 2, outboard, proof_buf[:])
	testing.expect_value(t, resumable_put_accept_frame(&session, 2, p2, blob[2 * FRAME_BYTES:3 * FRAME_BYTES]), Resumable_Put_Refusal.None)
	off, ok = resumable_put_resume_offset(&session)
	testing.expect(t, ok && off == FRAME_BYTES)
	// Duplicate out-of-order frame 2 -> Frame_Conflict.
	testing.expect_value(t, resumable_put_accept_frame(&session, 2, p2, blob[2 * FRAME_BYTES:3 * FRAME_BYTES]), Resumable_Put_Refusal.Frame_Conflict)

	// Accept frame 1 -> contiguous frontier jumps past both 1 and 2 to 3 * FRAME_BYTES!
	p1 := proof_for_frame(t, 5, 1, outboard, proof_buf[:])
	testing.expect_value(t, resumable_put_accept_frame(&session, 1, p1, blob[FRAME_BYTES:2 * FRAME_BYTES]), Resumable_Put_Refusal.None)
	off, ok = resumable_put_resume_offset(&session)
	testing.expect(t, ok && off == 3 * FRAME_BYTES)

	// Accept frame 3 and final short frame 4 -> session completes!
	p3 := proof_for_frame(t, 5, 3, outboard, proof_buf[:])
	p4 := proof_for_frame(t, 5, 4, outboard, proof_buf[:])
	testing.expect_value(t, resumable_put_accept_frame(&session, 3, p3, blob[3 * FRAME_BYTES:4 * FRAME_BYTES]), Resumable_Put_Refusal.None)
	testing.expect(t, !resumable_put_is_complete(&session))
	testing.expect_value(t, resumable_put_accept_frame(&session, 4, p4, blob[4 * FRAME_BYTES:]), Resumable_Put_Refusal.None)
	testing.expect(t, resumable_put_is_complete(&session))
	off, ok = resumable_put_resume_offset(&session)
	testing.expect(t, ok && off == u64(total_size))
}
