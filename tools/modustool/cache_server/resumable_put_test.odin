package cache_server

import "core:os"
import "core:slice"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/object_cache"

@(private = "file")
build_host_outboard :: proc(t: ^testing.T, data: []u8) -> (root: blake3.Hash, outboard: [][object_cache.OUTBOARD_ENTRY_SIZE]u8) {
	builder, ok := object_cache.frame_tree_builder_start(u64(len(data)))
	testing.expect(t, ok)
	outboard = make([][object_cache.OUTBOARD_ENTRY_SIZE]u8, int(builder.frame_count - 1), context.temp_allocator)
	for idx in u64(0) ..< builder.frame_count {
		flen, len_ok := object_cache.object_frame_length(u64(len(data)), idx)
		testing.expect(t, len_ok)
		start := int(idx * object_cache.FRAME_PAYLOAD_BYTES)
		parents: [object_cache.MAX_PROOF_DEPTH]object_cache.Frame_Parent
		pcount, add_ok := object_cache.frame_tree_builder_add(&builder, data[start:start + int(flen)], &parents)
		testing.expect(t, add_ok)
		for p in parents[:pcount] {
			outboard[int(p.index)] = object_cache.frame_parent_entry(p)
		}
	}
	testing.expect(t, builder.finished)
	return builder.root, outboard
}

@(private = "file")
host_frame_proof :: proc(
	t: ^testing.T,
	frame_count: u64,
	frame_index: u64,
	outboard: [][object_cache.OUTBOARD_ENTRY_SIZE]u8,
	dst: []u8,
) -> []u8 {
	path, ok := object_cache.object_frame_path(frame_count, frame_index)
	testing.expect(t, ok)
	for level in 0 ..< path.depth {
		sibling := object_cache.frame_proof_entry(outboard[int(path.parent_index[level])], path.in_left[level])
		copy(dst[level * object_cache.PROOF_ENTRY_SIZE:(level + 1) * object_cache.PROOF_ENTRY_SIZE], sibling[:])
	}
	return dst[:path.depth * object_cache.PROOF_ENTRY_SIZE]
}

@(test)
resumable_upload_interrupt_resume_refusal_and_commit :: proc(t: ^testing.T) {
	dir := make_temp_store_dir(t)
	defer {
		os.remove_all(dir)
		delete(dir)
	}

	server, opened := cache_server_open(dir, nil)
	testing.expect(t, opened)
	defer cache_server_destroy(&server)

	// 3 frames: 2 full 1 MiB frames + 19_001-byte tail.
	total_size := int(2 * object_cache.FRAME_PAYLOAD_BYTES + 19_001)
	blob := make([]u8, total_size)
	defer delete(blob)
	for i in 0 ..< total_size {
		blob[i] = u8((i * 113 + 7) & 0xFF)
	}
	root, outboard := build_host_outboard(t, blob)
	proof_buf: [object_cache.MAX_PROOF_DEPTH * object_cache.PROOF_ENTRY_SIZE]u8

	// Phase 1: open upload, send frame 0 and frame 1, then simulate disconnect by closing handle.
	h1, open_ref1, ok1 := resumable_upload_open(&server, .Blob, root, u64(total_size))
	testing.expect(t, ok1)
	testing.expect_value(t, open_ref1, object_cache.Resumable_Put_Refusal.None)

	p0 := host_frame_proof(t, 3, 0, outboard, proof_buf[:])
	ref0, done0 := resumable_upload_write_frame(&h1, 0, p0, blob[:object_cache.FRAME_PAYLOAD_BYTES])
	testing.expect_value(t, ref0, object_cache.Resumable_Put_Refusal.None)
	testing.expect(t, !done0)

	p1 := host_frame_proof(t, 3, 1, outboard, proof_buf[:])
	ref1, done1 := resumable_upload_write_frame(&h1, 1, p1, blob[object_cache.FRAME_PAYLOAD_BYTES:2 * object_cache.FRAME_PAYLOAD_BYTES])
	testing.expect_value(t, ref1, object_cache.Resumable_Put_Refusal.None)
	testing.expect(t, !done1)
	testing.expect(t, !cache_server_has(&server, root), "incomplete resumable upload must not appear in objects/")
	resumable_upload_close(&h1)

	// Phase 2: resume from durable .part + .state -> resume offset must be exactly 2 MiB.
	h2, open_ref2, ok2 := resumable_upload_open(&server, .Blob, root, u64(total_size))
	testing.expect(t, ok2)
	testing.expect_value(t, open_ref2, object_cache.Resumable_Put_Refusal.None)
	defer resumable_upload_close(&h2)

	resume_off, off_ok := object_cache.resumable_put_resume_offset(&h2.session)
	testing.expect(t, off_ok)
	testing.expect_value(t, resume_off, u64(2 * object_cache.FRAME_PAYLOAD_BYTES))

	// Re-sending already-verified frame 0 is refused with Frame_Conflict.
	dup_ref, dup_done := resumable_upload_write_frame(&h2, 0, p0, blob[:object_cache.FRAME_PAYLOAD_BYTES])
	testing.expect_value(t, dup_ref, object_cache.Resumable_Put_Refusal.Frame_Conflict)
	testing.expect(t, !dup_done)

	// Sending a tampered final frame 2 is refused with Hash_Mismatch and commits nothing.
	p2 := host_frame_proof(t, 3, 2, outboard, proof_buf[:])
	bad_tail := make([]u8, 19_001)
	defer delete(bad_tail)
	copy(bad_tail, blob[2 * object_cache.FRAME_PAYLOAD_BYTES:])
	bad_tail[42] ~= 0xFF
	bad_ref, bad_done := resumable_upload_write_frame(&h2, 2, p2, bad_tail)
	testing.expect_value(t, bad_ref, object_cache.Resumable_Put_Refusal.Hash_Mismatch)
	testing.expect(t, !bad_done)
	testing.expect(t, !cache_server_has(&server, root))

	// Sending valid final frame 2 completes upload and commits objects/<hex> + outboards/<hex>.
	ref2, done2 := resumable_upload_write_frame(&h2, 2, p2, blob[2 * object_cache.FRAME_PAYLOAD_BYTES:])
	testing.expect_value(t, ref2, object_cache.Resumable_Put_Refusal.None)
	testing.expect(t, done2)
	testing.expect(t, cache_server_has(&server, root))

	hex := hash_to_hex(root)
	stored, found, read_ok := store_read_by_hex(&server, .Objects, string(hex[:]), context.allocator)
	defer delete(stored)
	testing.expect(t, read_ok && found)
	testing.expect(t, slice.equal(stored, blob))

	ob_path, ob_ok := store_path_for_hex(server.root_directory, .Outboards, string(hex[:]), context.temp_allocator)
	testing.expect(t, ob_ok && os.exists(ob_path))
}
