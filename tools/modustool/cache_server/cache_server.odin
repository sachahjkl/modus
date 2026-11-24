// Host-side content-addressed object cache server (src/md/features/recipes.md,
// "The object cache and its protocol").
//
// On-disk layout inside root_directory:
//   objects/<64-lowercase-hex-blake3>        raw blob or canonical tree bytes
//   outboards/<64-lowercase-hex-blake3>      pre-order parent chaining values for multi-frame blobs
//   realisations/<64-lowercase-hex-recipe>   canonical 164-byte Realisation_Record
//   tmp/<hex>.<sequence>.tmp                 staging area for atomic rename
//   recipes/<64-lowercase-hex-recipe>        a recipe object, by its recipe hash
//   release_pointers/<64-lowercase-hex>      a release pointer, by the hash of its 208 bytes
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

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "modus:contract/blake3"
import "modus:contract/module"
import "modus:contract/object_cache"
import "modus:contract/plans_recipes"
import "modus:contract/tree_hash"
import crypto_compat "modus:cryptography/compatibility_crypto"
import "modus:cryptography/ed25519"
import "modus:quic"
import "modustool:foundation"

// Default TCP and QUIC UDP listen address for `modustool cache-serve`
// (Plan value: matches object_cache.DEFAULT_QUIC_PORT).
DEFAULT_LISTEN_ADDRESS :: "127.0.0.1:5010"

// Closed set of subdirectories managed inside a cache store root.
Store_Directory :: enum u8 {
	Objects          = 1,
	Realisations     = 2,
	Temp             = 3,
	// A copy of each recipe object under its recipe hash, so that a
	// realisation finds its recipe by the hash that it holds
	// (src/md/infrastructure/cache_browser.md, "A realisation and its recipe").
	Recipes          = 4,
	Release_Pointers = 5, // Each release pointer, by the hash of its record.
	Outboards        = 6,
	// An object whose bytes do not hash to its name leaves objects/ for
	// this folder at the first mismatch: Has stops answering present, and
	// the next get answers Not_Found with no read.
	Damaged          = 7,
}

// The frames of an outboard that one exchange builds at most: no exchange
// hashes more than these frames and the one frame that it answers, whatever
// the size of the object (src/md/features/recipes.md, "Objects of any size").
OUTBOARD_BUILD_FRAMES_PER_EXCHANGE :: u64(16)

// The outboards that the server builds at once; a new build past it ends the
// build that waited longest.
OUTBOARD_BUILDS_AT_ONCE :: 4

// The build of an outboard that a get found missing: it goes on at each get of
// the object, OUTBOARD_BUILD_FRAMES_PER_EXCHANGE frames at a time, and the
// get answers Busy until it ends.
Outboard_Build :: struct {
	active:      bool,
	object_hash: blake3.Hash,
	object_size: u64,
	temp_path:   string,
	temp_file:   ^os.File,
	builder:     object_cache.Frame_Tree_Builder,
	last_used:   u64,
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
	protocol_lock:      sync.Mutex,
	status:             Cache_Status,
	// Guarded by protocol_lock when TCP and QUIC listeners run together.
	outboard_builds:    [OUTBOARD_BUILDS_AT_ONCE]Outboard_Build,
	outboard_build_use: u64,
	// OUTBOARD_BUILD_FRAMES_PER_EXCHANGE; a host test sets 1, so a small
	// object takes several exchanges to build.
	outboard_build_frames_per_exchange: u64,
}

// Configuration passed to cache_server_serve.
Cache_Serve_Options :: struct {
	directory:              string,
	listen_address:         string,
	authorized_public_keys: [][object_cache.PUBLIC_KEY_SIZE]u8,
	// Optional Ed25519 private key for the QUIC UDP listener on listen_address.
	// When has_quic_private_key is false and disable_quic is false, the server
	// loads <directory>/quic_server.key or creates it on first run so the
	// pinned server public key stays stable across restarts.
	quic_private_key:       [quic.ED25519_KEY_SIZE]u8,
	has_quic_private_key:   bool,
	// Plan value: concurrent QUIC clients served (0 uses CACHE_QUIC_DEFAULT_CONNECTIONS).
	quic_connections:       int,
	disable_quic:           bool,
	// The listener of the page and of the status record; empty: none.
	status_listen_address:  string,
	page:                   Cache_Page_Settings,
}

@(private)
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
	case .Recipes:
		return "recipes"
	case .Release_Pointers:
		return "release_pointers"
	case .Outboards:
		return "outboards"
	case .Damaged:
		return "damaged"
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
	// The server is the one writer of its folder, so a file of tmp/ is a part
	// of an upload or of an outboard that ended with an earlier run.
	if !store_temp_folder_empty(strings.concatenate({trimmed, "/", store_directory_name(.Temp)}, context.temp_allocator)) {
		return {}, false
	}
	server.outboard_build_frames_per_exchange = OUTBOARD_BUILD_FRAMES_PER_EXCHANGE
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
	for &build in server.outboard_builds {
		outboard_build_abort(&build)
	}
	delete(server.root_directory, allocator)
	delete(server.authorized_signers)
	cache_status_destroy(&server.status)
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
	temp_file, create_error := os.create(temp_path)
	if create_error != nil {
		return false, false
	}
	if !file_write_all(temp_file, content) || !file_sync_and_close(temp_file) {
		_ = os.remove(temp_path)
		return false, false
	}
	if !file_rename_durable(temp_path, final_path) {
		_ = os.remove(temp_path)
		return false, false
	}
	return true, added
}

// file_sync_and_close writes the bytes of file to the disk, then closes it.
// The file is closed in both outcomes.
file_sync_and_close :: proc(file: ^os.File) -> bool {
	sync_error := os.sync(file)
	close_error := os.close(file)
	return sync_error == nil && close_error == nil
}

// file_rename_durable renames a file whose bytes are on the disk, then writes
// its folder to the disk, so that a crash after the call keeps the new name
// with whole bytes, never a name with bytes that did not reach the disk. It
// is false only when the rename did not happen: once the name exists, a
// write of the folder that fails cannot take the rename back, and the next
// write of the folder carries it.
file_rename_durable :: proc(from_path, to_path: string) -> bool {
	if os.rename(from_path, to_path) != nil {
		return false
	}
	slash := strings.last_index_byte(to_path, '/')
	folder_path := slash > 0 ? to_path[:slash] : "."
	if folder, open_error := os.open(folder_path); open_error == nil {
		_ = file_sync_and_close(folder)
	}
	return true
}

// store_temp_folder_empty removes each entry of tmp/, one entry of the listing
// at a time.
@(private = "file")
store_temp_folder_empty :: proc(temp_folder: string) -> bool {
	folder, open_error := os.open(temp_folder)
	if open_error != nil {
		return false
	}
	defer os.close(folder)
	iterator := os.read_directory_iterator_create(folder)
	defer os.read_directory_iterator_destroy(&iterator)
	for entry in os.read_directory_iterator(&iterator) {
		if entry.type != .Regular {
			continue
		}
		if os.remove(strings.concatenate({temp_folder, "/", entry.name}, context.temp_allocator)) != nil {
			return false
		}
	}
	_, iterator_error := os.read_directory_iterator_error(&iterator)
	return iterator_error == nil
}

// store_move_damaged moves an object whose bytes do not hash to its name out
// of objects/, and removes its outboard. Has then stops answering present, a
// get answers Not_Found with no read, and a put writes the object again.
store_move_damaged :: proc(server: ^Cache_Server, hex_name: string, object_size: u64) {
	object_path, object_ok := store_path_for_hex(server.root_directory, .Objects, hex_name, context.temp_allocator)
	damaged_path, damaged_ok := store_path_for_hex(server.root_directory, .Damaged, hex_name, context.temp_allocator)
	outboard_path, outboard_ok := store_path_for_hex(server.root_directory, .Outboards, hex_name, context.temp_allocator)
	if !object_ok || !damaged_ok || !outboard_ok {
		return
	}
	_ = os.remove(outboard_path)
	if os.rename(object_path, damaged_path) != nil {
		return
	}
	cache_status_record_damaged(&server.status, object_size, time.now())
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

// The outcome of one step of the outboard of a blob of several frames.
Outboard_Step :: enum u8 {
	Ready   = 1, // The outboard is in place, and its file is open.
	Busy    = 2, // The build goes on at the next get of the object.
	Damaged = 3, // The bytes of the object do not hash to its name.
	Refused = 4, // A file of the store was not read or written.
}

@(private = "file")
outboard_build_temp_path :: proc(server: ^Cache_Server, object_hash: blake3.Hash, sequence: u64) -> string {
	hex := hash_to_hex(object_hash)
	return fmt.tprintf("%s/%s/%s.%d.outboard.tmp", server.root_directory, store_directory_name(.Temp), string(hex[:]), sequence)
}

// outboard_build_abort ends a build and removes its temporary file.
outboard_build_abort :: proc(build: ^Outboard_Build) {
	if !build.active {
		return
	}
	if build.temp_file != nil {
		_ = os.close(build.temp_file)
	}
	_ = os.remove(build.temp_path)
	delete(build.temp_path, runtime.default_allocator())
	build^ = {}
}

// outboard_build_find gives the build of an object, or starts one in a free
// place, or in the place of the build that waited longest.
@(private = "file")
outboard_build_find :: proc(server: ^Cache_Server, object_hash: blake3.Hash, object_size: u64) -> ^Outboard_Build {
	for &build in server.outboard_builds {
		if build.active && build.object_hash == object_hash && build.object_size == object_size {
			return &build
		}
	}
	oldest: ^Outboard_Build
	for &build in server.outboard_builds {
		if !build.active {
			oldest = &build
			break
		}
		if oldest == nil || build.last_used < oldest.last_used {
			oldest = &build
		}
	}
	outboard_build_abort(oldest)
	builder, start_ok := object_cache.frame_tree_builder_start(object_size)
	if !start_ok {
		return nil
	}
	sequence := sync.atomic_add(&server.temp_sequence, 1)
	// The path is kept with the allocator of the build: the builds outlive
	// one connection and one request.
	temp_path := strings.clone(outboard_build_temp_path(server, object_hash, sequence), runtime.default_allocator())
	temp_file, create_error := os.create(temp_path)
	if create_error != nil {
		delete(temp_path, runtime.default_allocator())
		return nil
	}
	oldest^ = Outboard_Build {
		active      = true,
		object_hash = object_hash,
		object_size = object_size,
		temp_path   = temp_path,
		temp_file   = temp_file,
		builder     = builder,
	}
	return oldest
}

// outboard_open_or_build opens the outboard of a blob of several frames.
// When it is missing or has the wrong size, it builds it from the object, at
// most outboard_build_frames_per_exchange frames for each call, so no request
// hashes more than a bounded part of the object; the outboard is renamed into
// the store only when the root of the object matches its name. scratch holds
// one frame.
outboard_open_or_build :: proc(
	server: ^Cache_Server,
	object_file: ^os.File,
	hex_name: string,
	object_hash: blake3.Hash,
	object_size: u64,
	scratch: []u8,
) -> (outboard_file: ^os.File, step: Outboard_Step, frames_built: u64, frame_count: u64) {
	expected_bytes, size_ok := object_cache.object_outboard_bytes(object_size)
	outboard_path, path_ok := store_path_for_hex(server.root_directory, .Outboards, hex_name, context.temp_allocator)
	if !size_ok || expected_bytes == 0 || !path_ok {
		return nil, .Refused, 0, 0
	}
	if existing, open_error := os.open(outboard_path); open_error == nil {
		existing_size, size_error := os.file_size(existing)
		if size_error == nil && existing_size >= 0 && u64(existing_size) == expected_bytes {
			return existing, .Ready, 0, 0
		}
		_ = os.close(existing)
	}
	build := outboard_build_find(server, object_hash, object_size)
	if build == nil {
		return nil, .Refused, 0, 0
	}
	server.outboard_build_use += 1
	build.last_used = server.outboard_build_use
	frames_per_exchange := server.outboard_build_frames_per_exchange
	if frames_per_exchange == 0 {
		frames_per_exchange = OUTBOARD_BUILD_FRAMES_PER_EXCHANGE
	}
	for _ in 0 ..< frames_per_exchange {
		if build.builder.finished {
			break
		}
		frame_index := build.builder.next_frame
		frame_length, length_ok := object_cache.object_frame_length(object_size, frame_index)
		if !length_ok {
			outboard_build_abort(build)
			return nil, .Refused, 0, 0
		}
		frame := scratch[:int(frame_length)]
		if frame_length > 0 && !file_read_exact_at(object_file, frame, i64(frame_index * object_cache.FRAME_PAYLOAD_BYTES)) {
			outboard_build_abort(build)
			return nil, .Refused, 0, 0
		}
		parents: [object_cache.MAX_PROOF_DEPTH]object_cache.Frame_Parent
		parent_count, add_ok := object_cache.frame_tree_builder_add(&build.builder, frame, &parents)
		if !add_ok {
			outboard_build_abort(build)
			return nil, .Refused, 0, 0
		}
		for parent in parents[:parent_count] {
			entry := object_cache.frame_parent_entry(parent)
			if !file_write_all_at(build.temp_file, entry[:], i64(parent.index * object_cache.OUTBOARD_ENTRY_SIZE)) {
				outboard_build_abort(build)
				return nil, .Refused, 0, 0
			}
		}
	}
	if !build.builder.finished {
		return nil, .Busy, build.builder.next_frame, build.builder.frame_count
	}
	if !object_cache.hashes_equal_constant_time(build.builder.root, object_hash) {
		outboard_build_abort(build)
		return nil, .Damaged, 0, 0
	}
	temp_file := build.temp_file
	build.temp_file = nil
	if !file_sync_and_close(temp_file) || !file_rename_durable(build.temp_path, outboard_path) {
		outboard_build_abort(build)
		return nil, .Refused, 0, 0
	}
	delete(build.temp_path, runtime.default_allocator())
	build^ = {}
	reopened, reopen_error := os.open(outboard_path)
	if reopen_error != nil {
		return nil, .Refused, 0, 0
	}
	return reopened, .Ready, 0, 0
}

// stored_frame_verifies checks one frame of a stored blob of several frames
// with the proof that its outboard gives.
@(private = "file")
stored_frame_verifies :: proc(
	object_file: ^os.File,
	outboard_file: ^os.File,
	object_hash: blake3.Hash,
	object_size: u64,
	frame_count: u64,
	frame_index: u64,
	scratch: []u8,
) -> bool {
	frame_length, length_ok := object_cache.object_frame_length(object_size, frame_index)
	path, path_ok := object_cache.object_frame_path(frame_count, frame_index)
	if !length_ok || !path_ok {
		return false
	}
	proof_buffer: [object_cache.MAX_PROOF_DEPTH * object_cache.PROOF_ENTRY_SIZE]u8
	proof := proof_buffer[:path.depth * object_cache.PROOF_ENTRY_SIZE]
	if !read_proof_from_outboard(outboard_file, &path, proof) {
		return false
	}
	frame := scratch[:int(frame_length)]
	if frame_length > 0 && !file_read_exact_at(object_file, frame, i64(frame_index * object_cache.FRAME_PAYLOAD_BYTES)) {
		return false
	}
	return object_cache.object_frame_verify(.Blob, object_hash, object_size, frame_index, proof, frame) == .Trust_By_Hash
}

// object_already_present_verified says whether the store holds the object, at
// a bounded cost: the size, then the one frame of a small object, or the last
// frame of a blob of several frames with the proof of its outboard. The last
// frame proves the size. A damaged frame in the middle is found by the get of
// that frame, which moves the object to damaged/, so the next put writes it
// again. A blob with no outboard is not present: the put writes it again with
// its outboard, which costs no more than a build of the outboard.
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
	outboard_bytes, outboard_size_ok := object_cache.object_outboard_bytes(object_size)
	outboard_path, outboard_path_ok := store_path_for_hex(server.root_directory, .Outboards, hex_name, context.temp_allocator)
	if !outboard_size_ok || !outboard_path_ok {
		return false
	}
	outboard_file, outboard_error := os.open(outboard_path)
	if outboard_error != nil {
		return false
	}
	defer os.close(outboard_file)
	outboard_size, outboard_size_error := os.file_size(outboard_file)
	if outboard_size_error != nil || outboard_size < 0 || u64(outboard_size) != outboard_bytes {
		return false
	}
	return stored_frame_verifies(obj_file, outboard_file, expected_hash, object_size, frame_count, frame_count - 1, conn.response_buffer)
}

@(private = "file")
busy_response :: proc(buffer: []u8, frames_built, frame_count: u64) -> (frame: []u8, status: object_cache.Cache_Response_Status) {
	response := object_cache.Cache_Response {
		request_kind = .Get_Object,
		status       = .Busy,
		frames_built = frames_built,
		frame_count  = frame_count,
	}
	return encode_response_into(buffer, &response)
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

	// A blob past the bound of a tree is no tree: Not_Found, as for a small
	// blob asked as a tree.
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
		// The stored bytes are checked against the hash and the kind asked:
		// a blob asked as a tree is Not_Found, and a damaged object leaves
		// objects/.
		decision := object_cache.verify_object_content(request.object_kind, request.object_hash, payload_dst)
		if decision != .Trust_By_Hash {
			other := opposite_object_kind(request.object_kind)
			if object_cache.verify_object_content(other, request.object_hash, payload_dst) == .Trust_By_Hash {
				return status_response(conn.response_buffer, .Get_Object, .Not_Found)
			}
			store_move_damaged(server, hex_name, object_size)
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
	// object leaves objects/. The outboard is built in the answer buffer,
	// before the proof and the frame are read into it.
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
		outboard_file, step, frames_built, steps_frame_count := outboard_open_or_build(server, obj_file, hex_name, request.object_hash, object_size, conn.response_buffer)
		switch step {
		case .Ready:
		case .Busy:
			return busy_response(conn.response_buffer, frames_built, steps_frame_count)
		case .Damaged:
			store_move_damaged(server, hex_name, object_size)
			return status_response(conn.response_buffer, .Get_Object, .Bad_Hash)
		case .Refused:
			return status_response(conn.response_buffer, .Get_Object, .Refused)
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
	// An outboard built again from bytes whose root matched, and a frame that
	// still does not verify: the bytes changed during the get.
	store_move_damaged(server, hex_name, object_size)
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
		cache_status_record_object(&server.status, request.object_hash, request.object_size, false, time.now())
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
	// Each file reaches the disk before its rename, and each folder after it,
	// so a crash never leaves a name whose bytes did not reach the disk.
	data_synced := file_sync_and_close(session.data_file)
	session.data_file = nil
	if !data_synced {
		put_session_abort(session)
		return status_response(conn.response_buffer, .Put_Object_Frame, .Refused)
	}

	object_size := session.object_size
	object_hash := session.object_hash
	object_kind := session.object_kind
	added := !os.exists(final_obj_path)
	final_out_path := ""
	if session.outboard_file != nil {
		outboard_synced := file_sync_and_close(session.outboard_file)
		session.outboard_file = nil
		out_path_ok: bool
		final_out_path, out_path_ok = store_path_for_hex(server.root_directory, .Outboards, hex_name, context.temp_allocator)
		if !outboard_synced || !out_path_ok {
			put_session_abort(session)
			return status_response(conn.response_buffer, .Put_Object_Frame, .Refused)
		}
		// The outboard comes before the object: the rename of objects/<hex>
		// is the one moment when the object exists.
		if !file_rename_durable(session.outboard_temp_path, final_out_path) {
			put_session_abort(session)
			return status_response(conn.response_buffer, .Put_Object_Frame, .Refused)
		}
		delete(session.outboard_temp_path)
		session.outboard_temp_path = ""
	}

	if !file_rename_durable(session.data_temp_path, final_obj_path) {
		// An outboard with no object is removed; the outboard of an object
		// that the store held already is the outboard of the same bytes.
		if added && final_out_path != "" && !os.exists(final_obj_path) {
			_ = os.remove(final_out_path)
		}
		put_session_abort(session)
		return status_response(conn.response_buffer, .Put_Object_Frame, .Refused)
	}
	put_session_clear(session)
	cache_status_record_object(&server.status, object_hash, object_size, added, time.now())
	// A blob that is a recipe object is also kept under its recipe hash. A
	// copy that fails to write changes nothing that a client relies on: the
	// object is written, and the page says that the host does not hold the
	// recipe.
	if object_kind == .Blob && object_size <= u64(plans_recipes.MAX_RECIPE_OBJECT_BYTES) {
		if recipe_bytes, read_error := os.read_entire_file(final_obj_path, context.temp_allocator); read_error == nil {
			recipe_object_index(server, recipe_bytes)
		}
	}
	return status_response(conn.response_buffer, .Put_Object_Frame, .Ok)
}

// handle_get_references returns the non-zero BLAKE3 hashes referenced by an
// object (canonical tree entries or module import table) or a realisation
// (its output hash). A plain blob returns Ok with zero references.
@(private = "file")
handle_get_references :: proc(
	server: ^Cache_Server,
	conn: ^Cache_Connection,
	request: ^object_cache.Cache_Request,
) -> (response_frame: []u8, status: object_cache.Cache_Response_Status) {
	hex_bytes := hash_to_hex(request.object_hash)
	hex_name := string(hex_bytes[:])
	refs_start := object_cache.FRAME_HEADER_SIZE + object_cache.GET_REFERENCES_RESPONSE_HEADER_SIZE

	obj_path, obj_path_ok := store_path_for_hex(server.root_directory, .Objects, hex_name, context.temp_allocator)
	if !obj_path_ok {
		return status_response(conn.response_buffer, .Get_References, .Refused)
	}
	if os.exists(obj_path) {
		obj_file, open_err := os.open(obj_path)
		if open_err != nil {
			return status_response(conn.response_buffer, .Get_References, .Refused)
		}
		defer if obj_file != nil {
			os.close(obj_file)
		}

		raw_size, sz_err := os.file_size(obj_file)
		if sz_err != nil || raw_size < 0 {
			return status_response(conn.response_buffer, .Get_References, .Refused)
		}
		object_size := u64(raw_size)

		prefix_len := int(min(object_size, u64(size_of(module.Header))))
		prefix: [size_of(module.Header)]u8
		if prefix_len > 0 && !file_read_exact_at(obj_file, prefix[:prefix_len], 0) {
			return status_response(conn.response_buffer, .Get_References, .Refused)
		}

		// Case 1: canonical MODTREE2 tree node.
		tree_magic := tree_hash.HEADER_MAGIC
		if object_size >= u64(tree_hash.HEADER_SIZE) && object_size <= u64(object_cache.MAX_TREE_PAYLOAD_BYTES) &&
		   string(prefix[:len(tree_magic)]) == string(tree_magic[:]) {
			tree_bytes := conn.request_buffer[:int(object_size)]
			if !file_read_exact_at(obj_file, tree_bytes, 0) {
				return status_response(conn.response_buffer, .Get_References, .Refused)
			}
			computed_tree, tree_refusal := tree_hash.tree_hash(tree_bytes)
			if tree_refusal == .None && object_cache.hashes_equal_constant_time(computed_tree, request.object_hash) {
				entry_count := tree_hash.tree_entry_count(tree_bytes)
				if entry_count > object_cache.MAX_REFERENCES {
					return status_response(conn.response_buffer, .Get_References, .Too_Large)
				}
				written_refs := 0
				offset := tree_hash.HEADER_SIZE
				for _ in 0 ..< entry_count {
					entry, next_offset, entry_ok := tree_hash.tree_entry_next(tree_bytes, offset)
					if !entry_ok {
						return status_response(conn.response_buffer, .Get_References, .Refused)
					}
					offset = next_offset
					if !object_cache.hash_is_zero(entry.hash) {
						dst := conn.response_buffer[refs_start + written_refs * blake3.HASH_SIZE:]
						copy(dst[:blake3.HASH_SIZE], entry.hash[:])
						written_refs += 1
					}
				}
				response := object_cache.Cache_Response {
					request_kind = .Get_References,
					status       = .Ok,
					references   = conn.response_buffer[refs_start:refs_start + written_refs * blake3.HASH_SIZE],
				}
				return encode_response_into(conn.response_buffer, &response)
			}
			// If bytes starting with MODTREE2 hash neither as a tree nor as a
			// plain blob to request.object_hash, quarantine the damaged file.
			blob_hash := blake3.hash(tree_bytes)
			if !object_cache.hashes_equal_constant_time(blob_hash, request.object_hash) {
				os.close(obj_file)
				obj_file = nil
				store_move_damaged(server, hex_name, object_size)
				return status_response(conn.response_buffer, .Get_References, .Not_Found)
			}
		}

		// Case 2: modus module file — read its Imports table directly without
		// loading large segments into memory.
		if prefix_len == size_of(module.Header) {
			head, head_err := module.header(prefix[:])
			if head_err == .None && u32(module.Table_Kind.Imports) < head.table_count {
				entry_offset := u64(head.header_size) + u64(module.Table_Kind.Imports) * size_of(module.Table_Entry)
				if entry_offset + size_of(module.Table_Entry) <= object_size {
					entry_bytes: [size_of(module.Table_Entry)]u8
					if file_read_exact_at(obj_file, entry_bytes[:], i64(entry_offset)) {
						entry := (cast(^module.Table_Entry)&entry_bytes[0])^
						table_bytes := u64(entry.count) * u64(entry.record_size)
						if entry.count > 1 && entry.record_size >= size_of(module.Import) &&
						   entry.offset <= object_size && table_bytes <= object_size - entry.offset {
							written_refs := 0
							for import_index in u32(1) ..< entry.count {
								if written_refs >= object_cache.MAX_REFERENCES {
									return status_response(conn.response_buffer, .Get_References, .Too_Large)
								}
								rec_pos := entry.offset + u64(import_index) * u64(entry.record_size)
								imp_hash: blake3.Hash
								if !file_read_exact_at(obj_file, imp_hash[:], i64(rec_pos)) {
									return status_response(conn.response_buffer, .Get_References, .Refused)
								}
								if !object_cache.hash_is_zero(imp_hash) {
									dst := conn.response_buffer[refs_start + written_refs * blake3.HASH_SIZE:]
									copy(dst[:blake3.HASH_SIZE], imp_hash[:])
									written_refs += 1
								}
							}
							response := object_cache.Cache_Response {
								request_kind = .Get_References,
								status       = .Ok,
								references   = conn.response_buffer[refs_start:refs_start + written_refs * blake3.HASH_SIZE],
							}
							return encode_response_into(conn.response_buffer, &response)
						}
					}
				}
			}
		}

		// Case 3: plain blob with no outgoing references.
		response := object_cache.Cache_Response {
			request_kind = .Get_References,
			status       = .Ok,
		}
		return encode_response_into(conn.response_buffer, &response)
	}

	// Case 4: realisation mapping a recipe hash to its output hash.
	data, found, read_ok := store_read_by_hex(server, .Realisations, hex_name, context.temp_allocator)
	if !read_ok {
		return status_response(conn.response_buffer, .Get_References, .Refused)
	}
	if !found {
		return status_response(conn.response_buffer, .Get_References, .Not_Found)
	}
	record, rec_refusal := object_cache.decode_realisation_record(data)
	if rec_refusal != .None || !object_cache.hashes_equal_constant_time(record.recipe_hash, request.object_hash) {
		return status_response(conn.response_buffer, .Get_References, .Refused)
	}
	signing_bytes, sign_ok := object_cache.realisation_signing_bytes(&record)
	if !sign_ok || !cache_server_verify_ed25519(record.signer_public_key, signing_bytes[:], record.signature) {
		return status_response(conn.response_buffer, .Get_References, .Bad_Signature)
	}
	copy(conn.response_buffer[refs_start:refs_start + blake3.HASH_SIZE], record.output_hash[:])
	response := object_cache.Cache_Response {
		request_kind = .Get_References,
		status       = .Ok,
		references   = conn.response_buffer[refs_start:refs_start + blake3.HASH_SIZE],
	}
	return encode_response_into(conn.response_buffer, &response)
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
	if server != nil {
		sync.mutex_lock(&server.protocol_lock)
	}
	defer if server != nil {
		sync.mutex_unlock(&server.protocol_lock)
	}
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

	case .Put_Release_Pointer:
		pointer := request.release_pointer
		response := object_cache.Cache_Response{request_kind = .Put_Release_Pointer}
		if !object_cache.signer_is_trusted(server.authorized_signers[:], pointer.publisher_public_key) {
			response.status = .Unauthorized
			return encode_response_into(conn.response_buffer, &response)
		}
		signing_bytes, sign_ok := object_cache.release_pointer_signing_bytes(&pointer)
		if !sign_ok {
			response.status = .Refused
			return encode_response_into(conn.response_buffer, &response)
		}
		if !cache_server_verify_ed25519(pointer.publisher_public_key, signing_bytes[:], pointer.signature) {
			response.status = .Bad_Signature
			return encode_response_into(conn.response_buffer, &response)
		}
		encoded: [object_cache.RELEASE_POINTER_WIRE_SIZE]u8
		if _, encode_refusal := object_cache.encode_release_pointer(&pointer, encoded[:]); encode_refusal != .None {
			response.status = .Refused
			return encode_response_into(conn.response_buffer, &response)
		}
		switch cache_status_release_pointer_put(server, pointer, encoded[:], time.now()) {
		case .Added, .Held_Already:
			response.status = .Ok
		case .Number_Not_Higher, .Not_Written:
			response.status = .Refused
		}
		return encode_response_into(conn.response_buffer, &response)

	case .Get_Release_Pointer:
		response := object_cache.Cache_Response{request_kind = .Get_Release_Pointer, status = .Not_Found}
		asked := request.release_pointer
		if pointer, found := cache_status_release_pointer_highest(&server.status, asked.publisher_public_key, object_cache.release_pointer_name(&asked)); found {
			response.status = .Ok
			response.release_pointer = pointer
		}
		return encode_response_into(conn.response_buffer, &response)

	case .Get_References:
		return handle_get_references(server, conn, &request)
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

	quic_running: ^Cache_Quic_Running
	if !options.disable_quic {
		quic_key := options.quic_private_key
		if !options.has_quic_private_key {
			if !cache_quic_load_or_create_key(server.root_directory, &quic_key) {
				fmt.eprintln("modustool: cache-serve: cannot load or create QUIC server key")
				return false
			}
		}
		defer crypto_compat.zero_explicit(&quic_key, size_of(quic_key))
		quic_endpoint := bound_err == nil ? bound : endpoint
		quic_err_text: string
		quic_conns := options.quic_connections > 0 ? options.quic_connections : CACHE_QUIC_DEFAULT_CONNECTIONS
		quic_running, quic_err_text = cache_quic_start(&server, quic_endpoint, quic_key, quic_conns)
		if quic_running == nil {
			fmt.eprintfln("modustool: cache-serve: cannot start QUIC listener on %s: %s", net.endpoint_to_string(quic_endpoint, context.temp_allocator), quic_err_text)
			return false
		}
		pub_hex := hash_to_hex(quic_running.public_key)
		fmt.printfln(
			"modustool: cache-serve: QUIC on udp://%s (ALPN %s, public key %s)",
			net.endpoint_to_string(quic_running.bound_endpoint, context.temp_allocator),
			object_cache.APPLICATION_PROTOCOL,
			string(pub_hex[:]),
		)
	}
	defer if quic_running != nil {
		sync.atomic_store(&server.stop, true)
		cache_quic_stop(quic_running)
	}

	cache_server_serve_listener(&server, listener)
	return true
}

// recipe_object_index keeps a copy of a blob that is a recipe object under
// its recipe hash. A blob that does not start with the magic is not tried.
recipe_object_index :: proc(server: ^Cache_Server, payload: []u8) {
	magic := plans_recipes.RECIPE_OBJECT_MAGIC
	if len(payload) < len(magic) || len(payload) > plans_recipes.MAX_RECIPE_OBJECT_BYTES || string(payload[:len(magic)]) != string(magic[:]) {
		return
	}
	spec := new(plans_recipes.Recipe_Spec, context.temp_allocator)
	recipe_digest, refusal := plans_recipes.recipe_object_decode(payload, spec)
	if refusal != .None {
		return
	}
	recipe_hex := hash_to_hex(recipe_digest)
	_, _ = store_write_atomic(server, .Recipes, string(recipe_hex[:]), payload)
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

// read_private_key_file reads a 64-hex-digit Ed25519 private seed file and
// checks that it parses as a valid Ed25519 private key.
read_private_key_file :: proc(command, path: string) -> (seed: [quic.ED25519_KEY_SIZE]u8, ok: bool) {
	raw, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("modustool: %s: cannot read key %s: %v", command, path, read_err)
		return {}, false
	}
	defer crypto_compat.zero_explicit(raw_data(raw), len(raw))
	decoded, decode_ok := decode_hex_32(string(raw))
	if !decode_ok {
		fmt.eprintfln("modustool: %s: %s must hold 64 hexadecimal digits", command, path)
		return {}, false
	}
	private_key: ed25519.Private_Key
	defer ed25519.private_key_clear(&private_key)
	if !ed25519.private_key_set_bytes(&private_key, decoded[:]) {
		crypto_compat.zero_explicit(&decoded, size_of(decoded))
		fmt.eprintfln("modustool: %s: %s is not a valid Ed25519 key", command, path)
		return {}, false
	}
	return decoded, true
}

// run_cache_serve implements `modustool cache-serve --dir <path> [--listen <addr>] [--quic-key <path>] [--quic-connections <n>] [--signer-key <path>] [--authorized-key <path>]`.
run_cache_serve :: proc(args: []string) -> int {
	usage_text :: "modustool: cache-serve --dir <path> [--listen <host:port>] [--quic-key <path>] [--quic-connections <n>] [--signer-key <path>] [--authorized-key <path>] [--status-listen <host:port>] [--endpoint <host:port>] [--site <address>]"
	directory := ""
	listen_address := DEFAULT_LISTEN_ADDRESS
	status_listen_address := ""
	quic_private_key: [quic.ED25519_KEY_SIZE]u8
	has_quic_private_key := false
	quic_connections := CACHE_QUIC_DEFAULT_CONNECTIONS
	defer crypto_compat.zero_explicit(&quic_private_key, size_of(quic_private_key))
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
		case "--quic-key":
			if index + 1 >= len(args) {
				fmt.eprintln(usage_text)
				return foundation.EXIT_USAGE
			}
			index += 1
			key, ok := read_private_key_file("cache-serve", args[index])
			if !ok {
				return foundation.EXIT_FAILURE
			}
			quic_private_key = key
			has_quic_private_key = true
		case "--quic-connections":
			if index + 1 >= len(args) {
				fmt.eprintln(usage_text)
				return foundation.EXIT_USAGE
			}
			index += 1
			parsed_conns, parse_ok := strconv.parse_int(args[index])
			if !parse_ok || parsed_conns < 1 || parsed_conns > CACHE_QUIC_MAX_CONNECTIONS {
				fmt.eprintfln("modustool: cache-serve: --quic-connections must be 1 to %d", CACHE_QUIC_MAX_CONNECTIONS)
				return foundation.EXIT_USAGE
			}
			quic_connections = parsed_conns
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
		quic_private_key       = quic_private_key,
		has_quic_private_key   = has_quic_private_key,
		quic_connections       = quic_connections,
		status_listen_address  = status_listen_address,
		page                   = page,
	}
	return cache_server_serve(options) ? 0 : foundation.EXIT_FAILURE
}

// cache_server_seed_object uploads one signed Blob or canonical Tree object
// directly into an open Cache_Server through the full wire request handler so
// Ed25519 verification, Bao outboard generation, and atomic commits run identically
// to remote uploads.
cache_server_seed_object :: proc(
	server: ^Cache_Server,
	kind: object_cache.Cache_Object_Kind,
	data: []u8,
	signer_private_key: [object_cache.PUBLIC_KEY_SIZE]u8,
) -> (hash: blake3.Hash, ok: bool) {
	if server == nil || len(data) == 0 {
		return {}, false
	}
	if _, valid_kind := object_cache.cache_object_kind_of_word(u64(kind)); !valid_kind {
		return {}, false
	}
	switch kind {
	case .Blob:
		hash = blake3.hash(data)
	case .Tree:
		refusal: tree_hash.Tree_Refusal
		hash, refusal = tree_hash.tree_hash(data)
		if refusal != .None {
			return {}, false
		}
	}

	seed := signer_private_key
	parsed: ed25519.Private_Key
	defer {
		ed25519.private_key_clear(&parsed)
		crypto_compat.zero_explicit(&seed, size_of(seed))
	}
	if !ed25519.private_key_set_bytes(&parsed, seed[:]) {
		return {}, false
	}
	signer_pub: [object_cache.PUBLIC_KEY_SIZE]u8
	ed25519.private_key_public_bytes(&parsed, signer_pub[:])

	signing_bytes, sign_ok := object_cache.put_object_signing_bytes(kind, hash, u64(len(data)), signer_pub)
	if !sign_ok {
		return {}, false
	}
	signature: [object_cache.SIGNATURE_SIZE]u8
	ed25519.sign(&parsed, signing_bytes[:], signature[:])

	conn: Cache_Connection
	cache_connection_init(&conn)
	defer cache_connection_destroy(&conn)

	frame_count, count_ok := object_cache.object_frame_count(u64(len(data)))
	if !count_ok || frame_count == 0 {
		return {}, false
	}

	put_req := object_cache.Cache_Request {
		kind                = .Put_Object,
		object_kind         = kind,
		object_hash         = hash,
		object_size         = u64(len(data)),
		uploader_public_key = signer_pub,
		uploader_signature  = signature,
	}
	written, enc_ref := object_cache.encode_request(&put_req, conn.request_buffer)
	if enc_ref != .None {
		return {}, false
	}
	resp_frame, status := cache_server_handle_connection_frame(server, &conn, conn.request_buffer[:written])
	if status != .Ok {
		return {}, false
	}
	resp, dec_ref := object_cache.decode_response(resp_frame)
	if dec_ref != .None {
		return {}, false
	}
	if resp.put_state == .Already_Present {
		return hash, true
	}

	for frame_index in u64(0) ..< frame_count {
		offset := int(frame_index * object_cache.FRAME_PAYLOAD_BYTES)
		end := min(offset + int(object_cache.FRAME_PAYLOAD_BYTES), len(data))
		frame_req := object_cache.Cache_Request {
			kind        = .Put_Object_Frame,
			object_kind = kind,
			object_hash = hash,
			offset      = u64(offset),
			payload     = data[offset:end],
		}
		frame_written, frame_enc_ref := object_cache.encode_request(&frame_req, conn.request_buffer)
		if frame_enc_ref != .None {
			return {}, false
		}
		_, frame_status := cache_server_handle_connection_frame(server, &conn, conn.request_buffer[:frame_written])
		if frame_status != .Ok {
			return {}, false
		}
	}
	return hash, true
}

// cache_server_seed_realisation signs and stores a Realisation_Record mapping
// recipe_hash to output_hash through the full wire request handler.
cache_server_seed_realisation :: proc(
	server: ^Cache_Server,
	recipe_hash: blake3.Hash,
	output_hash: blake3.Hash,
	output_kind: object_cache.Cache_Object_Kind,
	signer_private_key: [object_cache.PUBLIC_KEY_SIZE]u8,
) -> (record: object_cache.Realisation_Record, ok: bool) {
	if server == nil {
		return {}, false
	}
	if _, valid_kind := object_cache.cache_object_kind_of_word(u64(output_kind)); !valid_kind {
		return {}, false
	}
	seed := signer_private_key
	parsed: ed25519.Private_Key
	defer {
		ed25519.private_key_clear(&parsed)
		crypto_compat.zero_explicit(&seed, size_of(seed))
	}
	if !ed25519.private_key_set_bytes(&parsed, seed[:]) {
		return {}, false
	}
	record = {
		recipe_hash = recipe_hash,
		output_hash = output_hash,
		output_kind = output_kind,
	}
	ed25519.private_key_public_bytes(&parsed, record.signer_public_key[:])
	signing_bytes, sign_ok := object_cache.realisation_signing_bytes(&record)
	if !sign_ok {
		return {}, false
	}
	ed25519.sign(&parsed, signing_bytes[:], record.signature[:])

	conn: Cache_Connection
	cache_connection_init(&conn)
	defer cache_connection_destroy(&conn)

	req := object_cache.Cache_Request {
		kind        = .Put_Realisation,
		realisation = record,
	}
	written, enc_ref := object_cache.encode_request(&req, conn.request_buffer)
	if enc_ref != .None {
		return {}, false
	}
	_, status := cache_server_handle_connection_frame(server, &conn, conn.request_buffer[:written])
	if status != .Ok {
		return {}, false
	}
	return record, true
}
