// Host-side content-addressed object cache server (src/md/features/recipes.md,
// "The object cache and its protocol").
//
// On-disk layout inside root_directory:
//   objects/<64-lowercase-hex-blake3>        raw blob or canonical tree bytes
//   outboards/<64-lowercase-hex-blake3>      pre-order parent chaining values for multi-frame blobs
//   realisations/<64-lowercase-hex-recipe>   canonical 164-byte Realisation_Record
//   tmp/<hex>.<sequence>.tmp                 staging area for atomic rename
//
// Security invariants enforced on every request:
//   - Every Put_Object and Put_Realisation requires an authorized Ed25519
//     signer key and a valid Ed25519 signature over the domain-separated
//     canonical signing bytes.
//   - Every Put_Object streams frames into temporary files under tmp/,
//     verifies the computed BLAKE3 root (Blob) or canonical tree_hash (Tree)
//     when the final frame arrives, and renames atomically only on a match.
//     Any refusal or disconnect deletes the temporary files.
//   - Every file path is built exclusively from a validated 64-character
//     lowercase hexadecimal string inside a closed Store_Directory enum,
//     preventing path traversal.
//   - Every Get_Object frame is verified against the requested object hash
//     and kind (with its inclusion proof for multi-frame blobs) before
//     sending bytes to a client.
package cache_server

import "core:fmt"
import "core:io"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "modus:contract/blake3"
import "modus:contract/object_cache"
import crypto_compat "modus:cryptography/compatibility_crypto"
import "modus:cryptography/ed25519"
import "modustool:foundation"

// Default TCP listen address for `modustool cache-serve`.
DEFAULT_LISTEN_ADDRESS :: "127.0.0.1:7200"

// Closed set of subdirectories managed inside a cache store root.
Store_Directory :: enum u8 {
	Objects      = 1,
	Realisations = 2,
	Temp         = 3,
	Outboards    = 4,
}

// In-flight streaming upload state held per connection.
Put_Session :: struct {
	active:             bool,
	object_hash:        blake3.Hash,
	object_kind:        object_cache.Cache_Object_Kind,
	object_size:        u64,
	frame_count:        u64,
	next_frame:         u64,
	hex_name:           [64]u8,
	data_temp_path:     string,
	data_file:          ^os.File,
	outboard_temp_path: string,
	outboard_file:      ^os.File,
	builder:            object_cache.Frame_Tree_Builder,
}

// Per-connection reusable frame buffers and active streaming Put session.
// Holding one request buffer and one response buffer keeps server memory
// bounded (~2 MiB per connection) for any object size.
Cache_Connection :: struct {
	put:             Put_Session,
	request_buffer:  []u8,
	response_buffer: []u8,
}

// Running state of an on-disk object cache store.
Cache_Server :: struct {
	root_directory:     string,
	authorized_signers: [dynamic][object_cache.PUBLIC_KEY_SIZE]u8,
	temp_sequence:      u64,
	stop:               bool,
	status:             Cache_Status,
}

// Configuration passed to cache_server_serve.
Cache_Serve_Options :: struct {
	directory:              string,
	listen_address:         string,
	authorized_public_keys: [][object_cache.PUBLIC_KEY_SIZE]u8,
	// The listener of the page and of the status record; empty: none.
	status_listen_address:  string,
	page:                   Cache_Page_Settings,
}

@(private = "file")
HEX_DIGITS :: "0123456789abcdef"

// hash_to_hex formats a 32-byte hash as 64 lowercase ASCII hexadecimal bytes.
hash_to_hex :: proc(value: blake3.Hash) -> (out: [64]u8) {
	digits := HEX_DIGITS
	for byte_value, index in value {
		out[index * 2] = digits[byte_value >> 4]
		out[index * 2 + 1] = digits[byte_value & 0x0F]
	}
	return out
}

// hex_hash_valid returns true only when text is exactly 64 lowercase ASCII
// hexadecimal characters (no slashes, dots, whitespace, uppercase, or NULs).
hex_hash_valid :: proc(text: string) -> bool {
	if len(text) != 64 {
		return false
	}
	for index in 0 ..< len(text) {
		ch := text[index]
		is_digit := ch >= '0' && ch <= '9'
		is_lower_hex := ch >= 'a' && ch <= 'f'
		if !is_digit && !is_lower_hex {
			return false
		}
	}
	return true
}

@(private)
store_directory_name :: proc(directory: Store_Directory) -> string {
	switch directory {
	case .Objects:
		return "objects"
	case .Realisations:
		return "realisations"
	case .Temp:
		return "tmp"
	case .Outboards:
		return "outboards"
	}
	return ""
}

// store_path_for_hex constructs a validated path inside root_directory.
// Refuses any hex_name that fails hex_hash_valid, closing path traversal.
store_path_for_hex :: proc(
	root_directory: string,
	directory: Store_Directory,
	hex_name: string,
	allocator := context.temp_allocator,
) -> (path: string, ok: bool) {
	if root_directory == "" || !hex_hash_valid(hex_name) {
		return "", false
	}
	sub := store_directory_name(directory)
	if sub == "" {
		return "", false
	}
	return strings.concatenate({root_directory, "/", sub, "/", hex_name}, allocator), true
}

// cache_connection_init allocates the fixed request and response buffers for
// one connection.
cache_connection_init :: proc(conn: ^Cache_Connection, allocator := context.allocator) {
	conn^ = {}
	conn.request_buffer = make([]u8, object_cache.FRAME_HEADER_SIZE + object_cache.MAX_REQUEST_BODY_BYTES, allocator)
	conn.response_buffer = make([]u8, object_cache.FRAME_HEADER_SIZE + object_cache.MAX_RESPONSE_BODY_BYTES, allocator)
}

// cache_connection_destroy aborts any unfinished upload (removing its
// temporary files) and frees the connection buffers.
cache_connection_destroy :: proc(conn: ^Cache_Connection, allocator := context.allocator) {
	if conn == nil {
		return
	}
	put_session_abort(&conn.put)
	delete(conn.request_buffer, allocator)
	delete(conn.response_buffer, allocator)
	conn.request_buffer = nil
	conn.response_buffer = nil
}

// put_session_abort closes and deletes any temporary staging files of an
// unfinished upload, leaving no partial object in the store.
put_session_abort :: proc(session: ^Put_Session) {
	if session == nil {
		return
	}
	if session.data_file != nil {
		_ = os.close(session.data_file)
		session.data_file = nil
	}
	if session.data_temp_path != "" {
		_ = os.remove(session.data_temp_path)
		delete(session.data_temp_path)
		session.data_temp_path = ""
	}
	if session.outboard_file != nil {
		_ = os.close(session.outboard_file)
		session.outboard_file = nil
	}
	if session.outboard_temp_path != "" {
		_ = os.remove(session.outboard_temp_path)
		delete(session.outboard_temp_path)
		session.outboard_temp_path = ""
	}
	session^ = {}
}

// put_session_clear releases path memory after temporary files have been
// committed by atomic rename.
@(private = "file")
put_session_clear :: proc(session: ^Put_Session) {
	if session.data_file != nil {
		_ = os.close(session.data_file)
	}
	if session.outboard_file != nil {
		_ = os.close(session.outboard_file)
	}
	if session.data_temp_path != "" {
		delete(session.data_temp_path)
	}
	if session.outboard_temp_path != "" {
		delete(session.outboard_temp_path)
	}
	session^ = {}
}

// file_read_exact_at reads exactly len(buffer) bytes from file starting at offset.
@(private)
file_read_exact_at :: proc(file: ^os.File, buffer: []u8, offset: i64) -> bool {
	received := 0
	for received < len(buffer) {
		count, err := os.read_at(file, buffer[received:], offset + i64(received))
		if count > 0 {
			received += count
		}
		if received == len(buffer) {
			return err == nil || err == io.Error.EOF
		}
		if err != nil || count == 0 {
			return false
		}
	}
	return true
}

// file_write_all writes all bytes of data sequentially to file.
@(private)
file_write_all :: proc(file: ^os.File, data: []u8) -> bool {
	written := 0
	for written < len(data) {
		count, err := os.write(file, data[written:])
		if err != nil || count == 0 {
			return false
		}
		written += count
	}
	return true
}

// file_write_all_at writes all bytes of data to file starting at offset.
@(private)
file_write_all_at :: proc(file: ^os.File, data: []u8, offset: i64) -> bool {
	written := 0
	for written < len(data) {
		count, err := os.write_at(file, data[written:], offset + i64(written))
		if err != nil || count == 0 {
			return false
		}
		written += count
	}
	return true
}

// cache_server_open initializes the on-disk directory layout and copies
// authorized uploader/signer public keys.
cache_server_open :: proc(
	root_directory: string,
	authorized_signers: [][object_cache.PUBLIC_KEY_SIZE]u8,
	allocator := context.allocator,
) -> (server: Cache_Server, ok: bool) {
	if root_directory == "" {
		return {}, false
	}
	trimmed := strings.trim_right(root_directory, "/")
	if trimmed == "" {
		trimmed = "/"
	}
	for dir in Store_Directory {
		sub_path := strings.concatenate({trimmed, "/", store_directory_name(dir)}, context.temp_allocator)
		if !foundation.make_folder(sub_path) {
			return {}, false
		}
	}
	server.root_directory = strings.clone(trimmed, allocator)
	server.authorized_signers = make([dynamic][object_cache.PUBLIC_KEY_SIZE]u8, 0, len(authorized_signers), allocator)
	for key in authorized_signers {
		key_copy := key
		if !object_cache.bytes_all_zero(key_copy[:]) {
			append(&server.authorized_signers, key)
		}
	}
	server.status.started = time.now()
	server.status.started_tick = time.tick_now()
	if !cache_status_scan(&server) {
		cache_server_destroy(&server, allocator)
		return {}, false
	}
	return server, true
}

// cache_server_destroy frees memory owned by server. On-disk files are kept.
cache_server_destroy :: proc(server: ^Cache_Server, allocator := context.allocator) {
	if server == nil {
		return
	}
	delete(server.root_directory, allocator)
	delete(server.authorized_signers)
	server.root_directory = ""
	server.authorized_signers = nil
}

// store_read_by_hex reads a content-addressed file by validated hex name.
// Returns (nil, false, false) when hex_name is invalid (e.g. path traversal)
// or on I/O failure; returns (nil, false, true) when the entry is absent.
store_read_by_hex :: proc(
	server: ^Cache_Server,
	directory: Store_Directory,
	hex_name: string,
	allocator := context.allocator,
) -> (data: []u8, found: bool, ok: bool) {
	if server == nil {
		return nil, false, false
	}
	path, path_ok := store_path_for_hex(server.root_directory, directory, hex_name, context.temp_allocator)
	if !path_ok {
		return nil, false, false
	}
	if !os.exists(path) {
		return nil, false, true
	}
	bytes, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		return nil, false, false
	}
	return bytes, true, true
}

// store_write_atomic writes content to a unique temporary file under tmp/ and
// renames it into place atomically so no reader ever sees a partial file.
// added says that the store did not hold the name before: the counts of the
// page grow only then. The server is the one writer of its folder, so the
// test before the rename holds until the rename.
store_write_atomic :: proc(
	server: ^Cache_Server,
	directory: Store_Directory,
	hex_name: string,
	content: []u8,
) -> (written: bool, added: bool) {
	if server == nil {
		return false, false
	}
	final_path, final_ok := store_path_for_hex(server.root_directory, directory, hex_name, context.temp_allocator)
	if !final_ok {
		return false, false
	}
	added = !os.exists(final_path)
	sequence := sync.atomic_add(&server.temp_sequence, 1)
	temp_path := fmt.tprintf("%s/%s/%s.%d.tmp", server.root_directory, store_directory_name(.Temp), hex_name, sequence)
	if write_err := os.write_entire_file(temp_path, content); write_err != nil {
		_ = os.remove(temp_path)
		return false, false
	}
	if rename_err := os.rename(temp_path, final_path); rename_err != nil {
		_ = os.remove(temp_path)
		return false, false
	}
	return true, added
}

// cache_server_verify_ed25519 verifies an Ed25519 signature using the modus
// cryptography package.
cache_server_verify_ed25519 :: proc(
	public_key: [object_cache.PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [object_cache.SIGNATURE_SIZE]u8,
) -> bool {
	pub_copy := public_key
	sig_copy := signature
	parsed: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&parsed, pub_copy[:]) {
		return false
	}
	return ed25519.verify(&parsed, message, sig_copy[:])
}

// cache_server_has returns true when hash is stored as either a complete
// object or a realisation. In-flight uploads under tmp/ never appear here.
cache_server_has :: proc(server: ^Cache_Server, value: blake3.Hash) -> bool {
	if server == nil || object_cache.hash_is_zero(value) {
		return false
	}
	hex_bytes := hash_to_hex(value)
	hex_name := string(hex_bytes[:])
	if obj_path, ok := store_path_for_hex(server.root_directory, .Objects, hex_name, context.temp_allocator); ok && os.exists(obj_path) {
		return true
	}
	if real_path, ok := store_path_for_hex(server.root_directory, .Realisations, hex_name, context.temp_allocator); ok && os.exists(real_path) {
		return true
	}
	return false
}

@(private = "file")
encode_response_into :: proc(
	buffer: []u8,
	response: ^object_cache.Cache_Response,
) -> (frame: []u8, status: object_cache.Cache_Response_Status) {
	written, enc_refusal := object_cache.encode_response(response, buffer)
	if enc_refusal != .None {
		fallback := object_cache.Cache_Response {
			request_kind = .Has,
			status       = .Refused,
		}
		fallback_written, _ := object_cache.encode_response(&fallback, buffer)
		return buffer[:fallback_written], .Refused
	}
	return buffer[:written], response.status
}

@(private = "file")
status_response :: proc(
	buffer: []u8,
	kind: object_cache.Cache_Request_Kind,
	status: object_cache.Cache_Response_Status,
) -> (frame: []u8, out_status: object_cache.Cache_Response_Status) {
	response := object_cache.Cache_Response {
		request_kind = kind,
		status       = status,
	}
	return encode_response_into(buffer, &response)
}

@(private = "file")
opposite_object_kind :: proc(kind: object_cache.Cache_Object_Kind) -> object_cache.Cache_Object_Kind {
	switch kind {
	case .Blob:
		return .Tree
	case .Tree:
		return .Blob
	}
	return .Blob
}

// read_proof_from_outboard reads the sibling chaining values along path from
// outboard_file into proof_dst (length path.depth * PROOF_ENTRY_SIZE).
@(private = "file")
read_proof_from_outboard :: proc(
	outboard_file: ^os.File,
	path: ^object_cache.Frame_Path,
	proof_dst: []u8,
) -> bool {
	for level in 0 ..< path.depth {
		entry: [object_cache.OUTBOARD_ENTRY_SIZE]u8
		pos := i64(path.parent_index[level] * object_cache.OUTBOARD_ENTRY_SIZE)
		if !file_read_exact_at(outboard_file, entry[:], pos) {
			return false
		}
		sibling := object_cache.frame_proof_entry(entry, path.in_left[level])
		copy(proof_dst[level * object_cache.PROOF_ENTRY_SIZE:(level + 1) * object_cache.PROOF_ENTRY_SIZE], sibling[:])
	}
	return true
}

// ensure_outboard opens the pre-order outboard file for a multi-frame blob.
// If the outboard is missing or has the wrong size, it streams obj_file once
// using scratch_frame (at least FRAME_PAYLOAD_BYTES), verifies the BLAKE3
// root against expected_hash, and writes the outboard atomically.
@(private = "file")
ensure_outboard :: proc(
	server: ^Cache_Server,
	obj_file: ^os.File,
	hex_name: string,
	expected_hash: blake3.Hash,
	object_size: u64,
	scratch_frame: []u8,
) -> (outboard_file: ^os.File, status: object_cache.Cache_Response_Status) {
	expected_bytes, out_ok := object_cache.object_outboard_bytes(object_size)
	if !out_ok || expected_bytes == 0 {
		return nil, .Refused
	}
	outboard_path, path_ok := store_path_for_hex(server.root_directory, .Outboards, hex_name, context.temp_allocator)
	if !path_ok {
		return nil, .Refused
	}
	if os.exists(outboard_path) {
		existing, open_err := os.open(outboard_path)
		if open_err == nil {
			sz, sz_err := os.file_size(existing)
			if sz_err == nil && u64(sz) == expected_bytes {
				return existing, .Ok
			}
			_ = os.close(existing)
		}
	}

	// Build outboard by streaming obj_file in 1 MiB frames.
	builder, start_ok := object_cache.frame_tree_builder_start(object_size)
	if !start_ok {
		return nil, .Refused
	}
	sequence := sync.atomic_add(&server.temp_sequence, 1)
	temp_path := fmt.tprintf("%s/%s/%s.%d.outboard.tmp", server.root_directory, store_directory_name(.Temp), hex_name, sequence)
	temp_file, create_err := os.create(temp_path)
	if create_err != nil {
		return nil, .Refused
	}
	cleaned := false
	defer if !cleaned {
		_ = os.close(temp_file)
		_ = os.remove(temp_path)
	}

	for frame_index in u64(0) ..< builder.frame_count {
		frame_len, len_ok := object_cache.object_frame_length(object_size, frame_index)
		if !len_ok {
			return nil, .Refused
		}
		frame_slice := scratch_frame[:int(frame_len)]
		if frame_len > 0 && !file_read_exact_at(obj_file, frame_slice, i64(frame_index * object_cache.FRAME_PAYLOAD_BYTES)) {
			return nil, .Refused
		}
		parents: [object_cache.MAX_PROOF_DEPTH]object_cache.Frame_Parent
		parent_count, add_ok := object_cache.frame_tree_builder_add(&builder, frame_slice, &parents)
		if !add_ok {
			return nil, .Refused
		}
		for p in 0 ..< parent_count {
			entry := object_cache.frame_parent_entry(parents[p])
			pos := i64(parents[p].index * object_cache.OUTBOARD_ENTRY_SIZE)
			if !file_write_all_at(temp_file, entry[:], pos) {
				return nil, .Refused
			}
		}
	}
	if !builder.finished || !object_cache.hashes_equal_constant_time(builder.root, expected_hash) {
		return nil, .Bad_Hash
	}
	if close_err := os.close(temp_file); close_err != nil {
		_ = os.remove(temp_path)
		cleaned = true
		return nil, .Refused
	}
	if rename_err := os.rename(temp_path, outboard_path); rename_err != nil {
		_ = os.remove(temp_path)
		cleaned = true
		return nil, .Refused
	}
	cleaned = true

	reopened, reopen_err := os.open(outboard_path)
	if reopen_err != nil {
		return nil, .Refused
	}
	return reopened, .Ok
}

// object_already_present_verified checks whether the store already holds a
// verified object with the exact requested hash, kind, and size.
@(private = "file")
object_already_present_verified :: proc(
	server: ^Cache_Server,
	conn: ^Cache_Connection,
	hex_name: string,
	kind: object_cache.Cache_Object_Kind,
	expected_hash: blake3.Hash,
	object_size: u64,
	frame_count: u64,
) -> bool {
	obj_path, path_ok := store_path_for_hex(server.root_directory, .Objects, hex_name, context.temp_allocator)
	if !path_ok || !os.exists(obj_path) {
		return false
	}
	obj_file, open_err := os.open(obj_path)
	if open_err != nil {
		return false
	}
	defer os.close(obj_file)
	raw_size, sz_err := os.file_size(obj_file)
	if sz_err != nil || raw_size < 0 || u64(raw_size) != object_size {
		return false
	}
	if frame_count == 1 {
		slice := conn.response_buffer[:int(object_size)]
		if object_size > 0 && !file_read_exact_at(obj_file, slice, 0) {
			return false
		}
		return object_cache.verify_object_content(kind, expected_hash, slice) == .Trust_By_Hash
	}
	if kind != .Blob {
		return false
	}
	// The whole object is hashed again: a read of the disk costs less than
	// the upload that it saves, and a stored object with a damaged byte is
	// then written again instead of kept. The outboard is checked frame by
	// frame at each get, and built again when a frame does not verify.
	builder, start_ok := object_cache.frame_tree_builder_start(object_size)
	if !start_ok {
		return false
	}
	for frame_index in u64(0) ..< frame_count {
		frame_length, length_ok := object_cache.object_frame_length(object_size, frame_index)
		if !length_ok {
			return false
		}
		frame := conn.response_buffer[:int(frame_length)]
		if frame_length > 0 && !file_read_exact_at(obj_file, frame, i64(frame_index * object_cache.FRAME_PAYLOAD_BYTES)) {
			return false
		}
		parents: [object_cache.MAX_PROOF_DEPTH]object_cache.Frame_Parent
		if _, add_ok := object_cache.frame_tree_builder_add(&builder, frame, &parents); !add_ok {
			return false
		}
	}
	return builder.finished && object_cache.hashes_equal_constant_time(builder.root, expected_hash)
}

// handle_get_object serves one aligned frame of a stored object with its
// BLAKE3 inclusion proof, reading and verifying directly in conn.response_buffer.
@(private = "file")
handle_get_object :: proc(
	server: ^Cache_Server,
	conn: ^Cache_Connection,
	request: ^object_cache.Cache_Request,
) -> (response_frame: []u8, status: object_cache.Cache_Response_Status) {
	hex_bytes := hash_to_hex(request.object_hash)
	hex_name := string(hex_bytes[:])
	obj_path, path_ok := store_path_for_hex(server.root_directory, .Objects, hex_name, context.temp_allocator)
	if !path_ok {
		return status_response(conn.response_buffer, .Get_Object, .Refused)
	}
	if !os.exists(obj_path) {
		return status_response(conn.response_buffer, .Get_Object, .Not_Found)
	}
	obj_file, open_err := os.open(obj_path)
	if open_err != nil {
		return status_response(conn.response_buffer, .Get_Object, .Refused)
	}
	defer os.close(obj_file)

	raw_size, sz_err := os.file_size(obj_file)
	if sz_err != nil || raw_size < 0 {
		return status_response(conn.response_buffer, .Get_Object, .Refused)
	}
	object_size := u64(raw_size)

	// A multi-frame or oversized blob cannot be a canonical Tree: report Not_Found
	// so blob/tree confusion matches the single-frame behavior.
	if request.object_kind == .Tree && object_size > u64(object_cache.MAX_TREE_PAYLOAD_BYTES) {
		return status_response(conn.response_buffer, .Get_Object, .Not_Found)
	}

	frame_index, idx_ok := object_cache.object_offset_to_frame_index(request.offset)
	if !idx_ok {
		return status_response(conn.response_buffer, .Get_Object, .Refused)
	}
	frame_count, count_ok := object_cache.object_frame_count(object_size)
	if !count_ok {
		return status_response(conn.response_buffer, .Get_Object, .Bad_Hash)
	}
	if frame_index >= frame_count {
		return status_response(conn.response_buffer, .Get_Object, .Out_Of_Range)
	}
	frame_len, len_ok := object_cache.object_frame_length(object_size, frame_index)
	if !len_ok {
		return status_response(conn.response_buffer, .Get_Object, .Out_Of_Range)
	}
	proof_start := object_cache.FRAME_HEADER_SIZE + object_cache.GET_OBJECT_RESPONSE_HEADER_SIZE
	if frame_count == 1 {
		payload_dst := conn.response_buffer[proof_start:proof_start + int(frame_len)]
		if frame_len > 0 && !file_read_exact_at(obj_file, payload_dst, 0) {
			return status_response(conn.response_buffer, .Get_Object, .Refused)
		}
		// Re-verify stored bytes against requested hash and kind to prevent
		// blob/tree confusion and detect on-disk corruption.
		decision := object_cache.verify_object_content(request.object_kind, request.object_hash, payload_dst)
		if decision != .Trust_By_Hash {
			other := opposite_object_kind(request.object_kind)
			if object_cache.verify_object_content(other, request.object_hash, payload_dst) == .Trust_By_Hash {
				return status_response(conn.response_buffer, .Get_Object, .Not_Found)
			}
			return status_response(conn.response_buffer, .Get_Object, .Bad_Hash)
		}
		response := object_cache.Cache_Response {
			request_kind = .Get_Object,
			status       = .Ok,
			object_kind  = request.object_kind,
			object_size  = object_size,
			offset       = 0,
			proof        = nil,
			payload      = payload_dst,
		}
		return encode_response_into(conn.response_buffer, &response)
	}

	// A blob of several frames: the proof comes from its outboard. A frame
	// that does not verify is checked once more with an outboard built again
	// from the object, so a damaged outboard is repaired and a damaged
	// object is refused. The outboard is built in the answer buffer, before
	// the proof and the frame are read into it.
	path, path_ok2 := object_cache.object_frame_path(frame_count, frame_index)
	if !path_ok2 {
		return status_response(conn.response_buffer, .Get_Object, .Refused)
	}
	proof_len := path.depth * object_cache.PROOF_ENTRY_SIZE
	proof_dst := conn.response_buffer[proof_start:proof_start + proof_len]
	payload_start := proof_start + proof_len
	payload_dst := conn.response_buffer[payload_start:payload_start + int(frame_len)]
	for attempt in 0 ..< 2 {
		if attempt == 1 {
			outboard_path, outboard_path_ok := store_path_for_hex(server.root_directory, .Outboards, hex_name, context.temp_allocator)
			if !outboard_path_ok {
				return status_response(conn.response_buffer, .Get_Object, .Refused)
			}
			_ = os.remove(outboard_path)
		}
		outboard_file, out_status := ensure_outboard(server, obj_file, hex_name, request.object_hash, object_size, conn.response_buffer)
		if out_status != .Ok {
			return status_response(conn.response_buffer, .Get_Object, out_status)
		}
		proof_read := read_proof_from_outboard(outboard_file, &path, proof_dst)
		_ = os.close(outboard_file)
		if !proof_read {
			continue
		}
		if frame_len > 0 && !file_read_exact_at(obj_file, payload_dst, i64(request.offset)) {
			return status_response(conn.response_buffer, .Get_Object, .Refused)
		}
		if object_cache.object_frame_verify(.Blob, request.object_hash, object_size, frame_index, proof_dst, payload_dst) == .Trust_By_Hash {
			response := object_cache.Cache_Response {
				request_kind = .Get_Object,
				status       = .Ok,
				object_kind  = .Blob,
				object_size  = object_size,
				offset       = request.offset,
				proof        = proof_dst,
				payload      = payload_dst,
			}
			return encode_response_into(conn.response_buffer, &response)
		}
	}
	return status_response(conn.response_buffer, .Get_Object, .Bad_Hash)
}

// handle_put_object validates authorization, signature, size, and free disk
// space, then either answers Already_Present or opens temporary staging files
// and answers Accept_Frames at offset 0.
@(private = "file")
handle_put_object :: proc(
	server: ^Cache_Server,
	conn: ^Cache_Connection,
	request: ^object_cache.Cache_Request,
) -> (response_frame: []u8, status: object_cache.Cache_Response_Status) {
	// Starting a new Put_Object aborts any unfinished upload on this connection.
	put_session_abort(&conn.put)

	if !object_cache.signer_is_trusted(server.authorized_signers[:], request.uploader_public_key) {
		return status_response(conn.response_buffer, .Put_Object, .Unauthorized)
	}
	signing_bytes, sign_ok := object_cache.put_object_signing_bytes(
		request.object_kind,
		request.object_hash,
		request.object_size,
		request.uploader_public_key,
	)
	if !sign_ok {
		return status_response(conn.response_buffer, .Put_Object, .Refused)
	}
	if !cache_server_verify_ed25519(request.uploader_public_key, signing_bytes[:], request.uploader_signature) {
		return status_response(conn.response_buffer, .Put_Object, .Bad_Signature)
	}
	frame_count, count_ok := object_cache.object_frame_count(request.object_size)
	outboard_bytes, out_ok := object_cache.object_outboard_bytes(request.object_size)
	if !count_ok || !out_ok {
		return status_response(conn.response_buffer, .Put_Object, .Too_Large)
	}

	hex_bytes := hash_to_hex(request.object_hash)
	hex_name := string(hex_bytes[:])

	if object_already_present_verified(server, conn, hex_name, request.object_kind, request.object_hash, request.object_size, frame_count) {
		cache_status_record_object(&server.status, request.object_size, false, time.now())
		response := object_cache.Cache_Response {
			request_kind = .Put_Object,
			status       = .Ok,
			put_state    = .Already_Present,
			offset       = 0,
		}
		return encode_response_into(conn.response_buffer, &response)
	}

	// Bound accepted object size by available disk space for content plus outboard.
	if free_bytes, free_known := cache_disk_free_bytes(server.root_directory); free_known {
		if request.object_size + outboard_bytes > free_bytes {
			return status_response(conn.response_buffer, .Put_Object, .Too_Large)
		}
	}

	builder, builder_ok := object_cache.frame_tree_builder_start(request.object_size)
	if !builder_ok {
		return status_response(conn.response_buffer, .Put_Object, .Too_Large)
	}

	sequence := sync.atomic_add(&server.temp_sequence, 1)
	data_temp_path := fmt.aprintf("%s/%s/%s.%d.tmp", server.root_directory, store_directory_name(.Temp), hex_name, sequence)
	data_file, create_err := os.create(data_temp_path)
	if create_err != nil {
		delete(data_temp_path)
		return status_response(conn.response_buffer, .Put_Object, .Refused)
	}

	outboard_temp_path := ""
	outboard_file: ^os.File
	if frame_count > 1 {
		outboard_temp_path = fmt.aprintf("%s/%s/%s.%d.outboard.tmp", server.root_directory, store_directory_name(.Temp), hex_name, sequence)
		out_err: os.Error
		outboard_file, out_err = os.create(outboard_temp_path)
		if out_err != nil {
			_ = os.close(data_file)
			_ = os.remove(data_temp_path)
			delete(data_temp_path)
			delete(outboard_temp_path)
			return status_response(conn.response_buffer, .Put_Object, .Refused)
		}
	}

	conn.put = Put_Session {
		active             = true,
		object_hash        = request.object_hash,
		object_kind        = request.object_kind,
		object_size        = request.object_size,
		frame_count        = frame_count,
		next_frame         = 0,
		hex_name           = hex_bytes,
		data_temp_path     = data_temp_path,
		data_file          = data_file,
		outboard_temp_path = outboard_temp_path,
		outboard_file      = outboard_file,
		builder            = builder,
	}

	response := object_cache.Cache_Response {
		request_kind = .Put_Object,
		status       = .Ok,
		put_state    = .Accept_Frames,
		offset       = 0,
	}
	return encode_response_into(conn.response_buffer, &response)
}

// handle_put_object_frame accepts one aligned frame of the active Put_Session,
// writes it to the temporary staging file, updates the frame tree and outboard,
// and atomically renames into place only when the final root matches.
@(private = "file")
handle_put_object_frame :: proc(
	server: ^Cache_Server,
	conn: ^Cache_Connection,
	request: ^object_cache.Cache_Request,
) -> (response_frame: []u8, status: object_cache.Cache_Response_Status) {
	session := &conn.put
	if !session.active || !object_cache.hashes_equal_constant_time(request.object_hash, session.object_hash) {
		put_session_abort(session)
		return status_response(conn.response_buffer, .Put_Object_Frame, .Refused)
	}
	expected_offset := session.next_frame * object_cache.FRAME_PAYLOAD_BYTES
	if request.offset != expected_offset {
		put_session_abort(session)
		return status_response(conn.response_buffer, .Put_Object_Frame, .Refused)
	}
	expected_len, len_ok := object_cache.object_frame_length(session.object_size, session.next_frame)
	if !len_ok || u64(len(request.payload)) != expected_len {
		put_session_abort(session)
		return status_response(conn.response_buffer, .Put_Object_Frame, .Refused)
	}

	switch session.object_kind {
	case .Tree:
		// Canonical trees always fit in one frame and verify by domain-separated tree_hash.
		if object_cache.verify_object_content(.Tree, session.object_hash, request.payload) != .Trust_By_Hash {
			put_session_abort(session)
			return status_response(conn.response_buffer, .Put_Object_Frame, .Bad_Hash)
		}
		if len(request.payload) > 0 && !file_write_all(session.data_file, request.payload) {
			put_session_abort(session)
			return status_response(conn.response_buffer, .Put_Object_Frame, .Refused)
		}
		session.next_frame += 1

	case .Blob:
		if len(request.payload) > 0 && !file_write_all(session.data_file, request.payload) {
			put_session_abort(session)
			return status_response(conn.response_buffer, .Put_Object_Frame, .Refused)
		}
		parents: [object_cache.MAX_PROOF_DEPTH]object_cache.Frame_Parent
		parent_count, add_ok := object_cache.frame_tree_builder_add(&session.builder, request.payload, &parents)
		if !add_ok {
			put_session_abort(session)
			return status_response(conn.response_buffer, .Put_Object_Frame, .Refused)
		}
		for p in 0 ..< parent_count {
			entry := object_cache.frame_parent_entry(parents[p])
			pos := i64(parents[p].index * object_cache.OUTBOARD_ENTRY_SIZE)
			if !file_write_all_at(session.outboard_file, entry[:], pos) {
				put_session_abort(session)
				return status_response(conn.response_buffer, .Put_Object_Frame, .Refused)
			}
		}
		session.next_frame += 1
		if session.next_frame < session.frame_count {
			return status_response(conn.response_buffer, .Put_Object_Frame, .Ok)
		}
		if !session.builder.finished || !object_cache.hashes_equal_constant_time(session.builder.root, session.object_hash) {
			put_session_abort(session)
			return status_response(conn.response_buffer, .Put_Object_Frame, .Bad_Hash)
		}
	}

	// Final frame verified: close staging files and rename atomically into place.
	hex_name := string(session.hex_name[:])
	final_obj_path, obj_path_ok := store_path_for_hex(server.root_directory, .Objects, hex_name, context.temp_allocator)
	if !obj_path_ok {
		put_session_abort(session)
		return status_response(conn.response_buffer, .Put_Object_Frame, .Refused)
	}
	if close_err := os.close(session.data_file); close_err != nil {
		session.data_file = nil
		put_session_abort(session)
		return status_response(conn.response_buffer, .Put_Object_Frame, .Refused)
	}
	session.data_file = nil

	if session.outboard_file != nil {
		if out_close_err := os.close(session.outboard_file); out_close_err != nil {
			session.outboard_file = nil
			put_session_abort(session)
			return status_response(conn.response_buffer, .Put_Object_Frame, .Refused)
		}
		session.outboard_file = nil
		final_out_path, out_path_ok := store_path_for_hex(server.root_directory, .Outboards, hex_name, context.temp_allocator)
		if !out_path_ok {
			put_session_abort(session)
			return status_response(conn.response_buffer, .Put_Object_Frame, .Refused)
		}
		// Rename outboard before object so objects/<hex> is the single publication barrier.
		if out_rename_err := os.rename(session.outboard_temp_path, final_out_path); out_rename_err != nil {
			put_session_abort(session)
			return status_response(conn.response_buffer, .Put_Object_Frame, .Refused)
		}
		delete(session.outboard_temp_path)
		session.outboard_temp_path = ""
	}

	object_size := session.object_size
	added := !os.exists(final_obj_path)
	if rename_err := os.rename(session.data_temp_path, final_obj_path); rename_err != nil {
		put_session_abort(session)
		return status_response(conn.response_buffer, .Put_Object_Frame, .Refused)
	}
	put_session_clear(session)
	cache_status_record_object(&server.status, object_size, added, time.now())
	return status_response(conn.response_buffer, .Put_Object_Frame, .Ok)
}

// cache_server_handle_connection_frame decodes one binary request frame,
// validates authentication, signatures, ranges, and content hashes, serves or
// updates the store, and returns the encoded binary response frame inside
// conn.response_buffer (zero heap allocations per frame).
cache_server_handle_connection_frame :: proc(
	server: ^Cache_Server,
	conn: ^Cache_Connection,
	request_frame: []u8,
) -> (response_frame: []u8, status: object_cache.Cache_Response_Status) {
	request, refusal := object_cache.decode_request(request_frame)
	if refusal != .None {
		put_session_abort(&conn.put)
		err_status: object_cache.Cache_Response_Status = refusal == .Too_Large ? .Too_Large : .Refused
		echo_kind := object_cache.Cache_Request_Kind.Has
		if len(request_frame) >= 6 {
			if parsed_kind, ok := object_cache.cache_request_kind_of_word(u64(request_frame[5])); ok {
				echo_kind = parsed_kind
			}
		}
		return status_response(conn.response_buffer, echo_kind, err_status)
	}

	if server == nil {
		put_session_abort(&conn.put)
		return status_response(conn.response_buffer, request.kind, .Refused)
	}

	switch request.kind {
	case .Has:
		present: u64 = 0
		for index in 0 ..< int(request.hash_count) {
			if cache_server_has(server, request.hashes[index]) {
				present |= u64(1) << u64(index)
			}
		}
		response := object_cache.Cache_Response {
			request_kind   = .Has,
			status         = .Ok,
			present_bitset = present,
		}
		return encode_response_into(conn.response_buffer, &response)

	case .Get_Object:
		return handle_get_object(server, conn, &request)

	case .Get_Realisation:
		hex_bytes := hash_to_hex(request.recipe_hash)
		data, found, read_ok := store_read_by_hex(server, .Realisations, string(hex_bytes[:]), context.temp_allocator)
		if !read_ok {
			return status_response(conn.response_buffer, .Get_Realisation, .Refused)
		}
		if !found {
			return status_response(conn.response_buffer, .Get_Realisation, .Not_Found)
		}
		record, rec_refusal := object_cache.decode_realisation_record(data)
		if rec_refusal != .None || !object_cache.hashes_equal_constant_time(record.recipe_hash, request.recipe_hash) {
			return status_response(conn.response_buffer, .Get_Realisation, .Refused)
		}
		signing_bytes, sign_ok := object_cache.realisation_signing_bytes(&record)
		if !sign_ok || !cache_server_verify_ed25519(record.signer_public_key, signing_bytes[:], record.signature) {
			return status_response(conn.response_buffer, .Get_Realisation, .Bad_Signature)
		}
		response := object_cache.Cache_Response {
			request_kind = .Get_Realisation,
			status       = .Ok,
			realisation  = record,
		}
		return encode_response_into(conn.response_buffer, &response)

	case .Put_Object:
		return handle_put_object(server, conn, &request)

	case .Put_Object_Frame:
		return handle_put_object_frame(server, conn, &request)

	case .Put_Realisation:
		if !object_cache.signer_is_trusted(server.authorized_signers[:], request.realisation.signer_public_key) {
			return status_response(conn.response_buffer, .Put_Realisation, .Unauthorized)
		}
		signing_bytes, sign_ok := object_cache.realisation_signing_bytes(&request.realisation)
		if !sign_ok {
			return status_response(conn.response_buffer, .Put_Realisation, .Refused)
		}
		if !cache_server_verify_ed25519(request.realisation.signer_public_key, signing_bytes[:], request.realisation.signature) {
			return status_response(conn.response_buffer, .Put_Realisation, .Bad_Signature)
		}
		encoded_record: [object_cache.REALISATION_WIRE_SIZE]u8
		_, enc_refusal := object_cache.encode_realisation_record(&request.realisation, encoded_record[:])
		if enc_refusal != .None {
			return status_response(conn.response_buffer, .Put_Realisation, .Refused)
		}
		hex_bytes := hash_to_hex(request.realisation.recipe_hash)
		written, added := store_write_atomic(server, .Realisations, string(hex_bytes[:]), encoded_record[:])
		if !written {
			return status_response(conn.response_buffer, .Put_Realisation, .Refused)
		}
		cache_status_record_realisation(&server.status, request.realisation, added, time.now())
		return status_response(conn.response_buffer, .Put_Realisation, .Ok)
	}

	return status_response(conn.response_buffer, .Has, .Refused)
}

// cache_server_handle_frame serves a single stateless request frame, allocating
// the returned response slice with allocator. Multi-frame Put sequences use
// cache_server_handle_connection_frame with a persistent Cache_Connection.
cache_server_handle_frame :: proc(
	server: ^Cache_Server,
	request_frame: []u8,
	allocator := context.allocator,
) -> (response_frame: []u8, status: object_cache.Cache_Response_Status) {
	conn: Cache_Connection
	cache_connection_init(&conn, context.allocator)
	defer cache_connection_destroy(&conn, context.allocator)
	frame, out_status := cache_server_handle_connection_frame(server, &conn, request_frame)
	copied := make([]u8, len(frame), allocator)
	copy(copied, frame)
	return copied, out_status
}

// tcp_read_exact reads exactly len(buffer) bytes from socket.
// When allow_eof_at_start is true and 0 bytes are read at offset 0, sets eof.
@(private)
tcp_read_exact :: proc(socket: net.TCP_Socket, buffer: []u8, allow_eof_at_start: bool) -> (ok: bool, eof: bool) {
	received := 0
	for received < len(buffer) {
		count, err := net.recv_tcp(socket, buffer[received:])
		if err != nil {
			return false, false
		}
		if count == 0 {
			if allow_eof_at_start && received == 0 {
				return false, true
			}
			return false, false
		}
		received += count
	}
	return true, false
}

// tcp_write_all writes all bytes of data to socket.
tcp_write_all :: proc(socket: net.TCP_Socket, data: []u8) -> bool {
	sent := 0
	for sent < len(data) {
		count, err := net.send_tcp(socket, data[sent:])
		if err != nil || count == 0 {
			return false
		}
		sent += count
	}
	return true
}

// cache_server_serve_connection serves sequential object cache frames over one
// stream socket until clean EOF or a framing error. On disconnect, any
// unfinished Put_Object session is aborted and its temporary files removed.
cache_server_serve_connection :: proc(server: ^Cache_Server, socket: net.TCP_Socket) {
	_ = net.set_option(socket, .Receive_Timeout, foundation.HANG_BOUND)
	_ = net.set_option(socket, .Send_Timeout, foundation.HANG_BOUND)
	conn: Cache_Connection
	cache_connection_init(&conn)
	defer cache_connection_destroy(&conn)
	for !sync.atomic_load(&server.stop) {
		defer free_all(context.temp_allocator)
		header := conn.request_buffer[:object_cache.FRAME_HEADER_SIZE]
		header_ok, eof := tcp_read_exact(socket, header, true)
		if eof {
			return
		}
		if !header_ok {
			return
		}
		_, body_length, header_refusal := object_cache.inspect_request_header(header)
		if header_refusal != .None {
			err_frame, _ := cache_server_handle_connection_frame(server, &conn, header)
			_ = tcp_write_all(socket, err_frame)
			return
		}
		total := object_cache.FRAME_HEADER_SIZE + body_length
		if body_length > 0 {
			body_ok, _ := tcp_read_exact(socket, conn.request_buffer[object_cache.FRAME_HEADER_SIZE:total], false)
			if !body_ok {
				return
			}
		}
		response_frame, _ := cache_server_handle_connection_frame(server, &conn, conn.request_buffer[:total])
		if !tcp_write_all(socket, response_frame) {
			return
		}
	}
}

// cache_server_serve_listener accepts connections on listener until server.stop
// becomes true or listener is closed.
cache_server_serve_listener :: proc(server: ^Cache_Server, listener: net.TCP_Socket) {
	for !sync.atomic_load(&server.stop) {
		client, _, err := net.accept_tcp(listener)
		if err != nil {
			return
		}
		cache_server_serve_connection(server, client)
		net.close(client)
	}
}

// cache_server_serve opens the store, binds the TCP endpoint, and serves
// object cache requests until stopped.
cache_server_serve :: proc(options: Cache_Serve_Options) -> bool {
	listen_text := options.listen_address != "" ? options.listen_address : DEFAULT_LISTEN_ADDRESS
	endpoint, endpoint_ok := net.parse_endpoint(listen_text)
	if !endpoint_ok {
		fmt.eprintfln("modustool: cache-serve: invalid listen address %q (expected host:port)", listen_text)
		return false
	}
	server, open_ok := cache_server_open(options.directory, options.authorized_public_keys)
	if !open_ok {
		fmt.eprintfln("modustool: cache-serve: cannot open store directory %q", options.directory)
		return false
	}
	defer cache_server_destroy(&server)

	listener, listen_err := net.listen_tcp(endpoint)
	if listen_err != nil {
		fmt.eprintfln("modustool: cache-serve: cannot listen on %s: %v", listen_text, listen_err)
		return false
	}
	defer net.close(listener)

	bound, bound_err := net.bound_endpoint(listener)
	if bound_err == nil {
		fmt.printfln(
			"modustool: cache-serve: serving %s on %s (%d authorized signer keys)",
			server.root_directory,
			net.endpoint_to_string(bound, context.temp_allocator),
			len(server.authorized_signers),
		)
	}

	// The page and the status record, on their own thread, so a slow reader
	// of the page never holds the thread of the protocol.
	status_running: ^Cache_Status_Running
	if options.status_listen_address != "" {
		status_endpoint, status_endpoint_ok := net.parse_endpoint(options.status_listen_address)
		if !status_endpoint_ok {
			fmt.eprintfln("modustool: cache-serve: invalid status listen address %q (expected host:port)", options.status_listen_address)
			return false
		}
		page := options.page
		if page.endpoint == "" {
			page.endpoint = listen_text
		}
		if page.site_address == "" {
			page.site_address = DEFAULT_SITE_ADDRESS
		}
		status_socket, status_listen_err := net.listen_tcp(status_endpoint)
		if status_listen_err != nil {
			fmt.eprintfln("modustool: cache-serve: cannot listen on %s: %v", options.status_listen_address, status_listen_err)
			return false
		}
		status_bound, status_bound_err := net.bound_endpoint(status_socket)
		if status_bound_err == nil {
			fmt.printfln("modustool: cache-serve: the page and status.json on http://%s/", net.endpoint_to_string(status_bound, context.temp_allocator))
		}
		status_running = cache_status_start(&server, page, status_socket)
		if status_running == nil {
			fmt.eprintln("modustool: cache-serve: the system refused the thread of the page")
			net.close(status_socket)
			return false
		}
	}
	defer if status_running != nil {
		sync.atomic_store(&server.stop, true)
		cache_status_stop(status_running)
	}

	cache_server_serve_listener(&server, listener)
	return true
}

@(private)
decode_hex_32 :: proc(text: string) -> (bytes: [32]u8, ok: bool) {
	trimmed := strings.trim_space(text)
	if len(trimmed) != 64 {
		return {}, false
	}
	for index in 0 ..< 32 {
		high, high_ok := hex_nibble(trimmed[index * 2])
		low, low_ok := hex_nibble(trimmed[index * 2 + 1])
		if !high_ok || !low_ok {
			crypto_compat.zero_explicit(&bytes, size_of(bytes))
			return {}, false
		}
		bytes[index] = high << 4 | low
	}
	return bytes, true
}

@(private = "file")
hex_nibble :: proc(ch: u8) -> (value: u8, ok: bool) {
	switch ch {
	case '0' ..= '9':
		return ch - '0', true
	case 'a' ..= 'f':
		return ch - 'a' + 10, true
	case 'A' ..= 'F':
		return ch - 'A' + 10, true
	}
	return 0, false
}

// read_signer_public_key_from_private_key_file reads a 64-hex-digit Ed25519
// private seed file and derives its 32-byte public key, erasing the seed.
read_signer_public_key_from_private_key_file :: proc(path: string) -> (public_key: [object_cache.PUBLIC_KEY_SIZE]u8, ok: bool) {
	raw, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("modustool: cache-serve: cannot read signer key %s: %v", path, read_err)
		return {}, false
	}
	defer crypto_compat.zero_explicit(raw_data(raw), len(raw))
	seed, decode_ok := decode_hex_32(string(raw))
	defer crypto_compat.zero_explicit(&seed, size_of(seed))
	if !decode_ok {
		fmt.eprintfln("modustool: cache-serve: %s must hold 64 hexadecimal digits", path)
		return {}, false
	}
	private_key: ed25519.Private_Key
	defer ed25519.private_key_clear(&private_key)
	if !ed25519.private_key_set_bytes(&private_key, seed[:]) {
		fmt.eprintfln("modustool: cache-serve: %s is not a valid Ed25519 key", path)
		return {}, false
	}
	ed25519.private_key_public_bytes(&private_key, public_key[:])
	return public_key, true
}

// read_public_key_file reads a 64-hex-digit Ed25519 public key file. command
// names the command in each refusal.
read_public_key_file :: proc(command, path: string) -> (public_key: [object_cache.PUBLIC_KEY_SIZE]u8, ok: bool) {
	raw, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("modustool: %s: the public key %s was not read: %v", command, path, read_err)
		return {}, false
	}
	decoded, decode_ok := decode_hex_32(string(raw))
	if !decode_ok {
		fmt.eprintfln("modustool: %s: %s must hold 64 hexadecimal digits", command, path)
		return {}, false
	}
	parsed: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&parsed, decoded[:]) {
		fmt.eprintfln("modustool: %s: %s is not an Ed25519 public key", command, path)
		return {}, false
	}
	return decoded, true
}

// run_cache_serve implements `modustool cache-serve --dir <path> [--listen <addr>] [--signer-key <path>] [--authorized-key <path>]`.
run_cache_serve :: proc(args: []string) -> int {
	usage_text :: "modustool: cache-serve --dir <path> [--listen <host:port>] [--signer-key <path>] [--authorized-key <path>] [--status-listen <host:port>] [--endpoint <host:port>] [--site <address>]"
	directory := ""
	listen_address := DEFAULT_LISTEN_ADDRESS
	status_listen_address := ""
	page := Cache_Page_Settings {
		site_address = DEFAULT_SITE_ADDRESS,
	}
	authorized := make([dynamic][object_cache.PUBLIC_KEY_SIZE]u8)
	defer delete(authorized)

	for index := 0; index < len(args); index += 1 {
		flag := args[index]
		switch flag {
		case "--dir":
			if index + 1 >= len(args) {
				fmt.eprintln(usage_text)
				return foundation.EXIT_USAGE
			}
			index += 1
			directory = args[index]
		case "--listen":
			if index + 1 >= len(args) {
				fmt.eprintln(usage_text)
				return foundation.EXIT_USAGE
			}
			index += 1
			listen_address = args[index]
		case "--signer-key":
			if index + 1 >= len(args) {
				fmt.eprintln(usage_text)
				return foundation.EXIT_USAGE
			}
			index += 1
			pub, ok := read_signer_public_key_from_private_key_file(args[index])
			if !ok {
				return foundation.EXIT_FAILURE
			}
			append(&authorized, pub)
		case "--authorized-key":
			if index + 1 >= len(args) {
				fmt.eprintln(usage_text)
				return foundation.EXIT_USAGE
			}
			index += 1
			pub, ok := read_public_key_file("cache-serve", args[index])
			if !ok {
				return foundation.EXIT_FAILURE
			}
			append(&authorized, pub)
		case "--status-listen", "--endpoint", "--site":
			if index + 1 >= len(args) {
				fmt.eprintln(usage_text)
				return foundation.EXIT_USAGE
			}
			index += 1
			value := args[index]
			switch flag {
			case "--status-listen":
				status_listen_address = value
			case "--endpoint":
				if !cache_page_endpoint_valid(value) {
					fmt.eprintfln("modustool: cache-serve: --endpoint takes host:port, with letters, digits, '.', '-', ':', '[' and ']' only")
					return foundation.EXIT_USAGE
				}
				page.endpoint = value
			case "--site":
				if !cache_page_site_address_valid(value) {
					fmt.eprintfln("modustool: cache-serve: --site takes an address that starts with https:// or http://, with no space, quote, '<', '>', ';', '?' or '#'")
					return foundation.EXIT_USAGE
				}
				page.site_address = strings.trim_right(value, "/")
			}
		case:
			fmt.eprintfln("modustool: cache-serve: unknown option %s", flag)
			fmt.eprintln(usage_text)
			return foundation.EXIT_USAGE
		}
	}

	if directory == "" {
		fmt.eprintln("modustool: cache-serve: --dir <path> is required")
		fmt.eprintln(usage_text)
		return foundation.EXIT_USAGE
	}

	options := Cache_Serve_Options {
		directory              = directory,
		listen_address         = listen_address,
		authorized_public_keys = authorized[:],
		status_listen_address  = status_listen_address,
		page                   = page,
	}
	return cache_server_serve(options) ? 0 : foundation.EXIT_FAILURE
}
