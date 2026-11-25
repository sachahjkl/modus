// Host-side durable resumable upload support for object_cache
// (src/md/features/recipes.md, "Objects of any size").
//
// Persists verified 1 MiB frames in tmp/<hex>.part alongside a compact
// binary checkpoint tmp/<hex>.state so an interrupted upload resumes from
// resumable_put_resume_offset without re-uploading verified frames. Only once
// all frames verify and the full object (plus Bao outboard for multi-frame
// blobs) is reconstructed does it commit atomically into objects/<hex>.
package cache_server

import "core:fmt"
import "core:os"
import "core:strings"
import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/object_cache"

// Format property: magic and exact size of the durable resumable state file.
//   [0..8]   magic "MODRPUT1"
//   [8]      kind (Cache_Object_Kind)
//   [9..16]  reserved (0)
//   [16..48] object_hash
//   [48..56] object_size (u64 LE)
//   [56..64] contiguous_frames (u64 LE)
//   [64..72] received_count (u64 LE)
//   [72..584] received_bitmap ([64]u64 LE)
@(private = "file")
RESUMABLE_STATE_MAGIC :: [8]u8{'M', 'O', 'D', 'R', 'P', 'U', 'T', '1'}
@(private)
RESUMABLE_STATE_SIZE :: 72 + object_cache.RESUMABLE_PUT_BITMAP_WORDS * 8

#assert(RESUMABLE_STATE_SIZE == 584)

// Durable handle for one in-progress resumable upload inside Cache_Server.
Resumable_Upload_Handle :: struct {
	server:     ^Cache_Server,
	session:    object_cache.Resumable_Put_Session,
	hex_name:   [64]u8,
	part_path:  string,
	state_path: string,
}

@(private)
encode_resumable_state :: proc(session: ^object_cache.Resumable_Put_Session, out: ^[RESUMABLE_STATE_SIZE]u8) {
	magic := RESUMABLE_STATE_MAGIC
	copy(out[0:8], magic[:])
	out[8] = u8(session.object_kind)
	for i in 9 ..< 16 {
		out[i] = 0
	}
	copy(out[16:48], session.object_hash[:])
	byte_order.write_u64_little_endian(out[:], 48, session.object_size)
	byte_order.write_u64_little_endian(out[:], 56, session.contiguous_frames)
	byte_order.write_u64_little_endian(out[:], 64, session.received_count)
	for idx in 0 ..< object_cache.RESUMABLE_PUT_BITMAP_WORDS {
		byte_order.write_u64_little_endian(out[:], 72 + idx * 8, session.received_bitmap[idx])
	}
}

@(private)
decode_resumable_state :: proc(
	raw: []u8,
	expected_kind: object_cache.Cache_Object_Kind,
	expected_hash: blake3.Hash,
	expected_size: u64,
	session: ^object_cache.Resumable_Put_Session,
) -> bool {
	if len(raw) != RESUMABLE_STATE_SIZE {
		return false
	}
	magic := RESUMABLE_STATE_MAGIC
	for i in 0 ..< 8 {
		if raw[i] != magic[i] {
			return false
		}
	}
	kind, kind_ok := object_cache.cache_object_kind_of_word(u64(raw[8]))
	if !kind_ok || kind != expected_kind {
		return false
	}
	for i in 9 ..< 16 {
		if raw[i] != 0 {
			return false
		}
	}
	stored_hash: blake3.Hash
	copy(stored_hash[:], raw[16:48])
	if stored_hash != expected_hash {
		return false
	}
	stored_size := byte_order.read_u64_little_endian(raw, 48)
	if stored_size != expected_size {
		return false
	}
	if object_cache.resumable_put_init(session, expected_kind, expected_hash, expected_size) != .None {
		return false
	}
	contiguous := byte_order.read_u64_little_endian(raw, 56)
	received := byte_order.read_u64_little_endian(raw, 64)
	if contiguous > session.frame_count || received > session.frame_count || received < contiguous {
		session^ = {}
		return false
	}
	remaining := session.frame_count - contiguous
	bitmap_popcount: u64 = 0
	for idx in 0 ..< object_cache.RESUMABLE_PUT_BITMAP_WORDS {
		word := byte_order.read_u64_little_endian(raw, 72 + idx * 8)
		session.received_bitmap[idx] = word
		for bit in u64(0) ..< 64 {
			if (word & (u64(1) << bit)) == 0 {
				continue
			}
			rel := u64(idx) * 64 + bit
			// Bit 0 must be 0 whenever contiguous < frame_count (otherwise frontier
			// would have advanced), and no bit may lie at or past frame_count - contiguous.
			if (contiguous < session.frame_count && rel == 0) || rel >= remaining {
				session^ = {}
				return false
			}
			bitmap_popcount += 1
		}
	}
	if bitmap_popcount != received - contiguous {
		session^ = {}
		return false
	}
	session.contiguous_frames = contiguous
	session.received_count = received
	return true
}

@(private = "file")
save_resumable_state :: proc(state_path: string, session: ^object_cache.Resumable_Put_Session) -> bool {
	buf: [RESUMABLE_STATE_SIZE]u8
	encode_resumable_state(session, &buf)
	tmp_state := strings.concatenate({state_path, ".tmp"}, context.temp_allocator)
	file, err := os.create(tmp_state)
	if err != nil {
		return false
	}
	if !file_write_all(file, buf[:]) || !file_sync_and_close(file) {
		_ = os.remove(tmp_state)
		return false
	}
	if !file_rename_durable(tmp_state, state_path) {
		_ = os.remove(tmp_state)
		return false
	}
	return true
}

// resumable_upload_open starts a new resumable upload or resumes an existing
// partial upload in server's tmp/ folder when matching .part and .state exist.
resumable_upload_open :: proc(
	server: ^Cache_Server,
	kind: object_cache.Cache_Object_Kind,
	object_hash: blake3.Hash,
	object_size: u64,
	allocator := context.allocator,
) -> (handle: Resumable_Upload_Handle, refusal: object_cache.Resumable_Put_Refusal, ok: bool) {
	if server == nil {
		return {}, .Bad_Session, false
	}
	session: object_cache.Resumable_Put_Session
	if init_ref := object_cache.resumable_put_init(&session, kind, object_hash, object_size); init_ref != .None {
		return {}, init_ref, false
	}

	hex := hash_to_hex(object_hash)
	hex_text := string(hex[:])
	part_path := fmt.aprintf("%s/%s/%s.part", server.root_directory, store_directory_name(.Temp), hex_text, allocator = allocator)
	state_path := fmt.aprintf("%s/%s/%s.state", server.root_directory, store_directory_name(.Temp), hex_text, allocator = allocator)

	// Resume cleanly if a valid matching state + part file already exist on disk.
	resumed := false
	if os.exists(part_path) && os.exists(state_path) {
		if raw_state, read_err := os.read_entire_file(state_path, context.temp_allocator); read_err == nil {
			resumed_session: object_cache.Resumable_Put_Session
			if decode_resumable_state(raw_state, kind, object_hash, object_size, &resumed_session) {
				session = resumed_session
				resumed = true
			}
		}
	}

	handle = {
		server     = server,
		session    = session,
		hex_name   = hex,
		part_path  = part_path,
		state_path = state_path,
	}

	if !resumed {
		part_file, create_err := os.create(part_path)
		if create_err != nil {
			delete(part_path, allocator)
			delete(state_path, allocator)
			return {}, .Bad_Session, false
		}
		if !file_sync_and_close(part_file) || !save_resumable_state(handle.state_path, &handle.session) {
			_ = os.remove(part_path)
			_ = os.remove(state_path)
			delete(part_path, allocator)
			delete(state_path, allocator)
			return {}, .Bad_Session, false
		}
	}
	return handle, .None, true
}

// resumable_upload_close releases handle memory while preserving .part and
// .state files on disk so a later resumable_upload_open continues where it left off.
resumable_upload_close :: proc(handle: ^Resumable_Upload_Handle, allocator := context.allocator) {
	if handle == nil {
		return
	}
	if handle.part_path != "" {
		delete(handle.part_path, allocator)
	}
	if handle.state_path != "" {
		delete(handle.state_path, allocator)
	}
	handle^ = {}
}

// resumable_upload_abort deletes any staged .part and .state files and releases memory.
resumable_upload_abort :: proc(handle: ^Resumable_Upload_Handle, allocator := context.allocator) {
	if handle == nil {
		return
	}
	if handle.part_path != "" {
		_ = os.remove(handle.part_path)
	}
	if handle.state_path != "" {
		_ = os.remove(handle.state_path)
	}
	resumable_upload_close(handle, allocator)
}

// resumable_upload_write_frame verifies one Bao-proved frame, persists it into
// .part at its aligned offset, updates .state, and commits atomically into
// objects/<hex> (plus outboards/<hex> for multi-frame blobs) once complete.
resumable_upload_write_frame :: proc(
	handle: ^Resumable_Upload_Handle,
	frame_index: u64,
	proof: []u8,
	frame: []u8,
) -> (refusal: object_cache.Resumable_Put_Refusal, complete: bool) {
	if handle == nil || handle.server == nil || !handle.session.initialized {
		return .Bad_Session, false
	}
	// Verify frame against a copy of session first so disk failure never leaves
	// in-memory state ahead of durable storage.
	candidate := handle.session
	if acc_ref := object_cache.resumable_put_accept_frame(&candidate, frame_index, proof, frame); acc_ref != .None {
		return acc_ref, false
	}

	part_file, open_err := os.open(handle.part_path, {.Read, .Write})
	if open_err != nil {
		return .Bad_Session, false
	}
	offset := i64(frame_index * object_cache.FRAME_PAYLOAD_BYTES)
	write_ok := len(frame) == 0 || file_write_all_at(part_file, frame, offset)
	sync_ok := file_sync_and_close(part_file)
	if !write_ok || !sync_ok {
		return .Bad_Session, false
	}

	// Persist state from &candidate before updating handle.session so a state
	// save failure never leaves in-memory state ahead of durable storage.
	if !save_resumable_state(handle.state_path, &candidate) {
		return .Bad_Session, false
	}
	handle.session = candidate

	if !object_cache.resumable_put_is_complete(&handle.session) {
		return .None, false
	}

	// All frames verified: rebuild outboard (when multi-frame) and verify full root
	// over the durable part file before atomic rename into objects/<hex>.
	hex_text := string(handle.hex_name[:])
	final_obj_path, obj_ok := store_path_for_hex(handle.server.root_directory, .Objects, hex_text, context.temp_allocator)
	if !obj_ok {
		return .Bad_Session, false
	}

	if handle.session.frame_count > 1 {
		outboard_tmp := fmt.tprintf("%s/%s/%s.outboard.part", handle.server.root_directory, store_directory_name(.Temp), hex_text)
		outboard_final, ob_ok := store_path_for_hex(handle.server.root_directory, .Outboards, hex_text, context.temp_allocator)
		if !ob_ok {
			return .Bad_Session, false
		}
		verify_file, vopen_err := os.open(handle.part_path)
		if vopen_err != nil {
			return .Bad_Session, false
		}
		ob_file, ob_create_err := os.create(outboard_tmp)
		if ob_create_err != nil {
			_ = os.close(verify_file)
			return .Bad_Session, false
		}
		builder, b_ok := object_cache.frame_tree_builder_start(handle.session.object_size)
		if !b_ok {
			_ = os.close(verify_file)
			_ = os.close(ob_file)
			_ = os.remove(outboard_tmp)
			return .Bad_Session, false
		}
		scratch := make([]u8, int(object_cache.FRAME_PAYLOAD_BYTES), context.allocator)
		defer delete(scratch)
		for idx in u64(0) ..< handle.session.frame_count {
			flen, fl_ok := object_cache.object_frame_length(handle.session.object_size, idx)
			if !fl_ok || (flen > 0 && !file_read_exact_at(verify_file, scratch[:int(flen)], i64(idx * object_cache.FRAME_PAYLOAD_BYTES))) {
				_ = os.close(verify_file)
				_ = os.close(ob_file)
				_ = os.remove(outboard_tmp)
				return .Hash_Mismatch, false
			}
			parents: [object_cache.MAX_PROOF_DEPTH]object_cache.Frame_Parent
			pcount, add_ok := object_cache.frame_tree_builder_add(&builder, scratch[:int(flen)], &parents)
			if !add_ok {
				_ = os.close(verify_file)
				_ = os.close(ob_file)
				_ = os.remove(outboard_tmp)
				return .Hash_Mismatch, false
			}
			for p in parents[:pcount] {
				entry := object_cache.frame_parent_entry(p)
				if !file_write_all_at(ob_file, entry[:], i64(p.index * object_cache.OUTBOARD_ENTRY_SIZE)) {
					_ = os.close(verify_file)
					_ = os.close(ob_file)
					_ = os.remove(outboard_tmp)
					return .Bad_Session, false
				}
			}
		}
		_ = os.close(verify_file)
		if !builder.finished || builder.root != handle.session.object_hash {
			_ = os.close(ob_file)
			_ = os.remove(outboard_tmp)
			return .Hash_Mismatch, false
		}
		if !file_sync_and_close(ob_file) || !file_rename_durable(outboard_tmp, outboard_final) {
			_ = os.remove(outboard_tmp)
			return .Bad_Session, false
		}
	} else {
		// Single-frame object (including 0-byte blobs): re-verify exact on-disk
		// .part size and content hash before renaming into objects/.
		verify_file, vopen_err := os.open(handle.part_path)
		if vopen_err != nil {
			return .Bad_Session, false
		}
		actual_size, size_err := os.file_size(verify_file)
		if size_err != nil || actual_size != i64(handle.session.object_size) {
			_ = os.close(verify_file)
			return .Hash_Mismatch, false
		}
		raw := make([]u8, int(handle.session.object_size), context.allocator)
		defer delete(raw)
		read_ok := handle.session.object_size == 0 || file_read_exact_at(verify_file, raw, 0)
		_ = os.close(verify_file)
		if !read_ok {
			return .Hash_Mismatch, false
		}
		if object_cache.verify_object_content(handle.session.object_kind, handle.session.object_hash, raw) != .Trust_By_Hash {
			return .Hash_Mismatch, false
		}
	}

	if !file_rename_durable(handle.part_path, final_obj_path) {
		return .Bad_Session, false
	}
	_ = os.remove(handle.state_path)
	return .None, true
}
