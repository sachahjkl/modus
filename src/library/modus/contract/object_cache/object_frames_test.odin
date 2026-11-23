#+build !freestanding
package object_cache

import "core:testing"
import "modus:contract/blake3"

// build_outboard_with runs Frame_Tree_Builder over data with frame_bytes and
// returns the computed root and pre-order outboard buffer.
@(private = "file")
build_outboard_with :: proc(t: ^testing.T, data: []u8, frame_bytes: u64) -> (root: blake3.Hash, outboard: []u8) {
	object_size := u64(len(data))
	count := frame_count_with(object_size, frame_bytes)
	outboard = make([]u8, int((count - 1) * OUTBOARD_ENTRY_SIZE))
	seen := make([]bool, int(count - 1))
	defer delete(seen)

	builder := frame_tree_builder_start_with(object_size, frame_bytes)
	for frame_index in u64(0) ..< count {
		start := int(frame_index * frame_bytes)
		length, len_ok := frame_length_with(object_size, frame_index, frame_bytes)
		testing.expect(t, len_ok)
		parents: [MAX_PROOF_DEPTH]Frame_Parent
		parent_count, add_ok := frame_tree_builder_add(&builder, data[start:start + int(length)], &parents)
		testing.expect(t, add_ok)
		for p in 0 ..< parent_count {
			parent := parents[p]
			testing.expect(t, parent.index < count - 1)
			testing.expect(t, !seen[parent.index])
			seen[parent.index] = true
			entry := frame_parent_entry(parent)
			pos := int(parent.index) * OUTBOARD_ENTRY_SIZE
			copy(outboard[pos:pos + OUTBOARD_ENTRY_SIZE], entry[:])
		}
	}
	testing.expect(t, builder.finished)
	for was_seen in seen {
		testing.expect(t, was_seen)
	}
	return builder.root, outboard
}

@(private = "file")
extract_proof :: proc(outboard: []u8, path: Frame_Path, dst: []u8) -> []u8 {
	for level in 0 ..< path.depth {
		pos := int(path.parent_index[level]) * OUTBOARD_ENTRY_SIZE
		entry: [OUTBOARD_ENTRY_SIZE]u8
		copy(entry[:], outboard[pos:pos + OUTBOARD_ENTRY_SIZE])
		sibling := frame_proof_entry(entry, path.in_left[level])
		copy(dst[level * PROOF_ENTRY_SIZE:(level + 1) * PROOF_ENTRY_SIZE], sibling[:])
	}
	return dst[:path.depth * PROOF_ENTRY_SIZE]
}

@(test)
frame_arithmetic_and_offset_alignment_edges :: proc(t: ^testing.T) {
	// Unaligned offsets refused.
	for bad in ([]u64{1, 63, 64, 1024, FRAME_PAYLOAD_BYTES - 1, FRAME_PAYLOAD_BYTES + 1, max(u64)}) {
		_, ok := object_offset_to_frame_index(bad)
		testing.expect(t, !ok)
	}
	// Offset at or past MAX_OBJECT_BYTES refused.
	for bad in ([]u64{MAX_OBJECT_BYTES, MAX_OBJECT_BYTES + FRAME_PAYLOAD_BYTES}) {
		_, ok := object_offset_to_frame_index(bad)
		testing.expect(t, !ok)
	}
	// Valid aligned edges: 0, 1 frame, last valid frame.
	idx0, ok0 := object_offset_to_frame_index(0)
	testing.expect(t, ok0 && idx0 == 0)
	idx1, ok1 := object_offset_to_frame_index(FRAME_PAYLOAD_BYTES)
	testing.expect(t, ok1 && idx1 == 1)
	idx_last, ok_last := object_offset_to_frame_index((MAX_FRAME_COUNT - 1) * FRAME_PAYLOAD_BYTES)
	testing.expect(t, ok_last && idx_last == MAX_FRAME_COUNT - 1)

	// Size past MAX_OBJECT_BYTES refused.
	_, c_over := object_frame_count(MAX_OBJECT_BYTES + 1)
	testing.expect(t, !c_over)
	_, l_over := object_frame_length(MAX_OBJECT_BYTES + 1, 0)
	testing.expect(t, !l_over)
	_, o_over := object_outboard_bytes(MAX_OBJECT_BYTES + 1)
	testing.expect(t, !o_over)
	_, b_over := frame_tree_builder_start(MAX_OBJECT_BYTES + 1)
	testing.expect(t, !b_over)

	// Edge sizes: 0, 1, exact 1 frame, 1 frame + 1, MAX_OBJECT_BYTES.
	c0, ok_c0 := object_frame_count(0)
	testing.expect(t, ok_c0 && c0 == 1)
	l0, ok_l0 := object_frame_length(0, 0)
	testing.expect(t, ok_l0 && l0 == 0)
	_, ok_l0_past := object_frame_length(0, 1)
	testing.expect(t, !ok_l0_past)

	c_exact, ok_ce := object_frame_count(FRAME_PAYLOAD_BYTES)
	testing.expect(t, ok_ce && c_exact == 1)
	l_exact, ok_le := object_frame_length(FRAME_PAYLOAD_BYTES, 0)
	testing.expect(t, ok_le && l_exact == FRAME_PAYLOAD_BYTES)
	_, ok_le_past := object_frame_length(FRAME_PAYLOAD_BYTES, 1)
	testing.expect(t, !ok_le_past)

	c_plus1, ok_cp1 := object_frame_count(FRAME_PAYLOAD_BYTES + 1)
	testing.expect(t, ok_cp1 && c_plus1 == 2)
	l_p1_0, ok_lp10 := object_frame_length(FRAME_PAYLOAD_BYTES + 1, 0)
	l_p1_1, ok_lp11 := object_frame_length(FRAME_PAYLOAD_BYTES + 1, 1)
	testing.expect(t, ok_lp10 && l_p1_0 == FRAME_PAYLOAD_BYTES)
	testing.expect(t, ok_lp11 && l_p1_1 == 1)
	_, ok_lp1_past := object_frame_length(FRAME_PAYLOAD_BYTES + 1, 2)
	testing.expect(t, !ok_lp1_past)

	c_max, ok_cmax := object_frame_count(MAX_OBJECT_BYTES)
	testing.expect(t, ok_cmax && c_max == MAX_FRAME_COUNT)
	l_max, ok_lmax := object_frame_length(MAX_OBJECT_BYTES, MAX_FRAME_COUNT - 1)
	testing.expect(t, ok_lmax && l_max == FRAME_PAYLOAD_BYTES)
	_, ok_lmax_past := object_frame_length(MAX_OBJECT_BYTES, MAX_FRAME_COUNT)
	testing.expect(t, !ok_lmax_past)

	// Path refusals: frame_count == 0, > MAX_FRAME_COUNT, frame_index >= frame_count.
	_, p0 := object_frame_path(0, 0)
	testing.expect(t, !p0)
	_, p_over := object_frame_path(MAX_FRAME_COUNT + 1, 0)
	testing.expect(t, !p_over)
	_, p_past := object_frame_path(4, 4)
	testing.expect(t, !p_past)
}

@(test)
frame_tree_builder_matches_blake3_for_every_size_and_shape :: proc(t: ^testing.T) {
	// Test all official-vector sizes up to 102400 with 1 KiB frames (up to 100 frames),
	// covering powers of two, non-powers of two, odd counts, and partial last frames.
	max_size :: 105 * blake3.CHUNK_SIZE + 37
	input := make([]u8, max_size)
	defer delete(input)
	for &b, i in input {
		b = u8(i % 251)
	}
	sizes := [?]int{
		0, 1, 2, 63, 64, 65, 1023, 1024, 1025,
		2048, 2049, 3072, 3073, 4096, 4097, 5120, 5121,
		6144, 6145, 7168, 7169, 8192, 8193, 16384, 31744,
		100 * 1024, 102400, max_size,
	}
	proof_buf: [MAX_PROOF_DEPTH * PROOF_ENTRY_SIZE]u8
	for size in sizes {
		slice := input[:size]
		expected_hash := blake3.hash(slice)
		root, outboard := build_outboard_with(t, slice, blake3.CHUNK_SIZE)
		defer delete(outboard)
		testing.expect_value(t, root, expected_hash)

		count := frame_count_with(u64(size), blake3.CHUNK_SIZE)
		for frame_index in u64(0) ..< count {
			start := int(frame_index * blake3.CHUNK_SIZE)
			length, _ := frame_length_with(u64(size), frame_index, blake3.CHUNK_SIZE)
			path, path_ok := object_frame_path(count, frame_index)
			testing.expect(t, path_ok)
			proof := extract_proof(outboard, path, proof_buf[:])
			decision := frame_verify_with(.Blob, expected_hash, u64(size), frame_index, proof, slice[start:start + int(length)], blake3.CHUNK_SIZE)
			testing.expect_value(t, decision, Substitution_Decision.Trust_By_Hash)
		}
	}
}

@(test)
frame_verification_refuses_tampering_short_proof_and_lying_size :: proc(t: ^testing.T) {
	// 7 frames of 1 KiB + 11 bytes = 7179 bytes (8 frames, non-power-of-two right edge).
	size :: 7 * blake3.CHUNK_SIZE + 11
	data := make([]u8, size)
	defer delete(data)
	for &b, i in data {
		b = u8((i * 13 + 7) % 251)
	}
	root, outboard := build_outboard_with(t, data, blake3.CHUNK_SIZE)
	defer delete(outboard)
	testing.expect_value(t, root, blake3.hash(data))

	count := frame_count_with(size, blake3.CHUNK_SIZE)
	proof_buf: [MAX_PROOF_DEPTH * PROOF_ENTRY_SIZE]u8

	// 1. Corrupting any bit of a frame payload is refused with Refuse_Hash_Mismatch.
	for frame_index in ([3]u64{0, 3, count - 1}) {
		start := int(frame_index * blake3.CHUNK_SIZE)
		length, _ := frame_length_with(size, frame_index, blake3.CHUNK_SIZE)
		path, _ := object_frame_path(count, frame_index)
		proof := extract_proof(outboard, path, proof_buf[:])

		corrupt := make([]u8, int(length), context.temp_allocator)
		copy(corrupt, data[start:start + int(length)])
		corrupt[0] ~= 0x01
		testing.expect_value(
			t,
			frame_verify_with(.Blob, root, size, frame_index, proof, corrupt, blake3.CHUNK_SIZE),
			Substitution_Decision.Refuse_Hash_Mismatch,
		)
		corrupt[0] ~= 0x01
		corrupt[len(corrupt) - 1] ~= 0x80
		testing.expect_value(
			t,
			frame_verify_with(.Blob, root, size, frame_index, proof, corrupt, blake3.CHUNK_SIZE),
			Substitution_Decision.Refuse_Hash_Mismatch,
		)
	}

	// 2. Corrupting any bit of any proof level is refused with Refuse_Hash_Mismatch.
	path3, _ := object_frame_path(count, 3)
	proof3 := extract_proof(outboard, path3, proof_buf[:])
	for level in 0 ..< path3.depth {
		proof3[level * PROOF_ENTRY_SIZE] ~= 0x01
		testing.expect_value(
			t,
			frame_verify_with(.Blob, root, size, 3, proof3, data[3 * blake3.CHUNK_SIZE:4 * blake3.CHUNK_SIZE], blake3.CHUNK_SIZE),
			Substitution_Decision.Refuse_Hash_Mismatch,
		)
		proof3[level * PROOF_ENTRY_SIZE] ~= 0x01
	}

	// 3. Proof cut short or extended is refused with Refuse_Malformed.
	testing.expect_value(
		t,
		frame_verify_with(.Blob, root, size, 3, proof3[:0], data[3 * blake3.CHUNK_SIZE:4 * blake3.CHUNK_SIZE], blake3.CHUNK_SIZE),
		Substitution_Decision.Refuse_Malformed,
	)
	testing.expect_value(
		t,
		frame_verify_with(.Blob, root, size, 3, proof3[:len(proof3) - 1], data[3 * blake3.CHUNK_SIZE:4 * blake3.CHUNK_SIZE], blake3.CHUNK_SIZE),
		Substitution_Decision.Refuse_Malformed,
	)
	testing.expect_value(
		t,
		frame_verify_with(.Blob, root, size, 3, proof3[:len(proof3) - PROOF_ENTRY_SIZE], data[3 * blake3.CHUNK_SIZE:4 * blake3.CHUNK_SIZE], blake3.CHUNK_SIZE),
		Substitution_Decision.Refuse_Malformed,
	)

	// 4. Lying about object_size:
	//    - Claiming single-frame size (1 KiB) for multi-frame root -> Refuse_Hash_Mismatch.
	testing.expect_value(
		t,
		frame_verify_with(.Blob, root, blake3.CHUNK_SIZE, 0, nil, data[:blake3.CHUNK_SIZE], blake3.CHUNK_SIZE),
		Substitution_Decision.Refuse_Hash_Mismatch,
	)
	//    - Claiming truncated size (6 * 1 KiB) for 8-frame root: last frame (frame 5) fails!
	fake_size :: u64(6 * blake3.CHUNK_SIZE)
	fake_path, _ := object_frame_path(6, 5)
	fake_proof := make([]u8, fake_path.depth * PROOF_ENTRY_SIZE, context.temp_allocator)
	// Even with real sibling CVs from the 8-frame outboard, frame 5 cannot verify as the last frame of a 6-frame tree.
	copy(fake_proof, proof3[:len(fake_proof)])
	testing.expect_value(
		t,
		frame_verify_with(.Blob, root, fake_size, 5, fake_proof, data[5 * blake3.CHUNK_SIZE:6 * blake3.CHUNK_SIZE], blake3.CHUNK_SIZE),
		Substitution_Decision.Refuse_Hash_Mismatch,
	)

	// 5. Multi-frame object claiming Cache_Object_Kind.Tree is refused as Refuse_Malformed.
	testing.expect_value(
		t,
		frame_verify_with(.Tree, root, size, 0, proof3, data[:blake3.CHUNK_SIZE], blake3.CHUNK_SIZE),
		Substitution_Decision.Refuse_Malformed,
	)

	// 6. Frame_Tree_Builder refuses wrong frame length and extra frame after finish.
	builder, b_ok := frame_tree_builder_start(FRAME_PAYLOAD_BYTES + 1)
	testing.expect(t, b_ok)
	parents: [MAX_PROOF_DEPTH]Frame_Parent
	short_frame: [16]u8
	_, bad_len_ok := frame_tree_builder_add(&builder, short_frame[:], &parents)
	testing.expect(t, !bad_len_ok)

	single_builder, sb_ok := frame_tree_builder_start(0)
	testing.expect(t, sb_ok)
	_, ok_empty := frame_tree_builder_add(&single_builder, nil, &parents)
	testing.expect(t, ok_empty && single_builder.finished)
	testing.expect_value(t, single_builder.root, blake3.hash(nil))
	_, extra_ok := frame_tree_builder_add(&single_builder, nil, &parents)
	testing.expect(t, !extra_ok)
}

@(test)
real_one_mib_frames_match_blake3_at_boundaries :: proc(t: ^testing.T) {
	// Test exact 1 MiB, 1 MiB + 1 byte, and 3 MiB + 7 bytes using real FRAME_PAYLOAD_BYTES.
	total :: 3 * FRAME_PAYLOAD_BYTES + 7
	data := make([]u8, total)
	defer delete(data)
	for &b, i in data {
		b = u8((i * 17 + 3) % 251)
	}
	proof_buf: [MAX_PROOF_DEPTH * PROOF_ENTRY_SIZE]u8
	for size in ([4]int{0, FRAME_PAYLOAD_BYTES, FRAME_PAYLOAD_BYTES + 1, total}) {
		slice := data[:size]
		expected := blake3.hash(slice)
		root, outboard := build_outboard_with(t, slice, FRAME_PAYLOAD_BYTES)
		defer delete(outboard)
		testing.expect_value(t, root, expected)

		count, c_ok := object_frame_count(u64(size))
		testing.expect(t, c_ok)
		for idx in u64(0) ..< count {
			start := int(idx * FRAME_PAYLOAD_BYTES)
			length, l_ok := object_frame_length(u64(size), idx)
			testing.expect(t, l_ok)
			path, p_ok := object_frame_path(count, idx)
			testing.expect(t, p_ok)
			proof := extract_proof(outboard, path, proof_buf[:])
			decision := object_frame_verify(.Blob, expected, u64(size), idx, proof, slice[start:start + int(length)])
			testing.expect_value(t, decision, Substitution_Decision.Trust_By_Hash)
		}
	}
}

@(test)
the_deepest_path_holds_in_one_answer :: proc(t: ^testing.T) {
	// The largest count of frames, and one less: each path stays within
	// MAX_PROOF_DEPTH levels and names parents of the tree only.
	for count in ([2]u64{MAX_FRAME_COUNT, MAX_FRAME_COUNT - 1}) {
		for index in ([4]u64{0, 1, count / 2, count - 1}) {
			path, path_ok := object_frame_path(count, index)
			testing.expect(t, path_ok)
			testing.expect(t, path.depth >= 1 && path.depth <= MAX_PROOF_DEPTH)
			testing.expect_value(t, path.parent_index[0], u64(0))
			for level in 0 ..< path.depth {
				testing.expect(t, path.parent_index[level] < count - 1)
			}
			if count == MAX_FRAME_COUNT {
				testing.expect_value(t, path.depth, MAX_PROOF_DEPTH)
			}
		}
	}
	// One past the largest count, and the frame past the end.
	_, past_count := object_frame_path(MAX_FRAME_COUNT + 1, 0)
	testing.expect(t, !past_count)
	_, past_frame := object_frame_path(MAX_FRAME_COUNT, MAX_FRAME_COUNT)
	testing.expect(t, !past_frame)

	// The last frame of the largest object, with its 32 levels: the answer
	// fits MAX_RESPONSE_BODY_BYTES, and a proof that the root does not
	// accept is a mismatch, not a fault of the reader.
	proof: [MAX_PROOF_DEPTH * PROOF_ENTRY_SIZE]u8
	for &b, i in proof {
		b = u8(i * 7 + 1)
	}
	frame := make([]u8, FRAME_PAYLOAD_BYTES)
	defer delete(frame)
	buffer := make([]u8, FRAME_HEADER_SIZE + MAX_RESPONSE_BODY_BYTES)
	defer delete(buffer)
	last_offset := (MAX_FRAME_COUNT - 1) * FRAME_PAYLOAD_BYTES
	answer := Cache_Response {
		request_kind = .Get_Object,
		status       = .Ok,
		object_kind  = .Blob,
		object_size  = MAX_OBJECT_BYTES,
		offset       = last_offset,
		proof        = proof[:],
		payload      = frame,
	}
	written, encode_refusal := encode_response(&answer, buffer)
	testing.expect_value(t, encode_refusal, Wire_Refusal.None)
	testing.expect_value(t, written, len(buffer))
	decoded, decode_refusal := decode_response(buffer[:written])
	testing.expect_value(t, decode_refusal, Wire_Refusal.None)
	testing.expect_value(t, len(decoded.proof), MAX_PROOF_DEPTH * PROOF_ENTRY_SIZE)
	some_hash := blake3.hash(proof[:])
	testing.expect_value(t, object_frame_verify(.Blob, some_hash, MAX_OBJECT_BYTES, MAX_FRAME_COUNT - 1, decoded.proof, decoded.payload), Substitution_Decision.Refuse_Hash_Mismatch)
	// One level short is refused before any hash.
	testing.expect_value(t, object_frame_verify(.Blob, some_hash, MAX_OBJECT_BYTES, MAX_FRAME_COUNT - 1, decoded.proof[PROOF_ENTRY_SIZE:], decoded.payload), Substitution_Decision.Refuse_Malformed)
}
