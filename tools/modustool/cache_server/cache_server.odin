// Host-side content-addressed object cache server (src/md/features/recipes.md,
// "The object cache and its protocol").
//
// On-disk layout inside root_directory:
//   objects/<64-lowercase-hex-blake3>        raw blob or canonical tree bytes
//   realisations/<64-lowercase-hex-recipe>   canonical 164-byte Realisation_Record
//   tmp/<hex>.<sequence>.tmp                 staging area for atomic rename
//
// Security invariants enforced on every request:
//   - Every Put_Object and Put_Realisation requires an authorized Ed25519
//     signer key and a valid Ed25519 signature over the domain-separated
//     canonical signing bytes.
//   - Every Put_Object recomputes its BLAKE3 hash (Blob) or canonical
//     tree_hash (Tree) BEFORE writing atomically via temp file + rename.
//   - Every file path is built exclusively from a validated 64-character
//     lowercase hexadecimal string inside a closed Store_Directory enum,
//     preventing path traversal.
//   - Every Get_Object re-verifies the object's content hash and kind against
//     the requested hash and kind before returning bytes to a client.
package cache_server

import "core:fmt"
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

// cache_server_has returns true when hash is stored as either an object or a
// realisation.
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
encode_response_alloc :: proc(
	response: ^object_cache.Cache_Response,
	allocator := context.allocator,
) -> (frame: []u8, status: object_cache.Cache_Response_Status) {
	size, size_refusal := object_cache.encoded_response_size(response)
	if size_refusal != .None {
		fallback := object_cache.Cache_Response {
			request_kind = .Has,
			status       = .Refused,
		}
		fallback_frame := make([]u8, object_cache.FRAME_HEADER_SIZE, allocator)
		_, _ = object_cache.encode_response(&fallback, fallback_frame)
		return fallback_frame, .Refused
	}
	frame = make([]u8, size, allocator)
	_, enc_refusal := object_cache.encode_response(response, frame)
	if enc_refusal != .None {
		delete(frame, allocator)
		fallback := object_cache.Cache_Response {
			request_kind = .Has,
			status       = .Refused,
		}
		fallback_frame := make([]u8, object_cache.FRAME_HEADER_SIZE, allocator)
		_, _ = object_cache.encode_response(&fallback, fallback_frame)
		return fallback_frame, .Refused
	}
	return frame, response.status
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

// cache_server_handle_frame decodes one binary request frame, validates
// authentication, signatures, and content hashes, serves or updates the store,
// and returns the encoded binary response frame (allocated with allocator).
cache_server_handle_frame :: proc(
	server: ^Cache_Server,
	request_frame: []u8,
	allocator := context.allocator,
) -> (response_frame: []u8, status: object_cache.Cache_Response_Status) {
	request, refusal := object_cache.decode_request(request_frame)
	if refusal != .None {
		err_status: object_cache.Cache_Response_Status = refusal == .Too_Large ? .Too_Large : .Refused
		echo_kind := object_cache.Cache_Request_Kind.Has
		if len(request_frame) >= 6 {
			if parsed_kind, ok := object_cache.cache_request_kind_of_word(u64(request_frame[5])); ok {
				echo_kind = parsed_kind
			}
		}
		err_response := object_cache.Cache_Response {
			request_kind = echo_kind,
			status       = err_status,
		}
		return encode_response_alloc(&err_response, allocator)
	}

	if server == nil {
		err_response := object_cache.Cache_Response {
			request_kind = request.kind,
			status       = .Refused,
		}
		return encode_response_alloc(&err_response, allocator)
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
		return encode_response_alloc(&response, allocator)

	case .Get_Object:
		hex_bytes := hash_to_hex(request.object_hash)
		data, found, read_ok := store_read_by_hex(server, .Objects, string(hex_bytes[:]), context.temp_allocator)
		if !read_ok {
			response := object_cache.Cache_Response {
				request_kind = .Get_Object,
				status       = .Refused,
			}
			return encode_response_alloc(&response, allocator)
		}
		if !found {
			response := object_cache.Cache_Response {
				request_kind = .Get_Object,
				status       = .Not_Found,
			}
			return encode_response_alloc(&response, allocator)
		}
		// Re-verify stored bytes against requested hash and kind to prevent
		// blob/tree confusion and detect on-disk corruption.
		decision := object_cache.verify_object_content(request.object_kind, request.object_hash, data)
		if decision != .Trust_By_Hash {
			other := opposite_object_kind(request.object_kind)
			if object_cache.verify_object_content(other, request.object_hash, data) == .Trust_By_Hash {
				response := object_cache.Cache_Response {
					request_kind = .Get_Object,
					status       = .Not_Found,
				}
				return encode_response_alloc(&response, allocator)
			}
			response := object_cache.Cache_Response {
				request_kind = .Get_Object,
				status       = .Bad_Hash,
			}
			return encode_response_alloc(&response, allocator)
		}
		response := object_cache.Cache_Response {
			request_kind = .Get_Object,
			status       = .Ok,
			object_kind  = request.object_kind,
			payload      = data,
		}
		return encode_response_alloc(&response, allocator)

	case .Get_Realisation:
		hex_bytes := hash_to_hex(request.recipe_hash)
		data, found, read_ok := store_read_by_hex(server, .Realisations, string(hex_bytes[:]), context.temp_allocator)
		if !read_ok {
			response := object_cache.Cache_Response {
				request_kind = .Get_Realisation,
				status       = .Refused,
			}
			return encode_response_alloc(&response, allocator)
		}
		if !found {
			response := object_cache.Cache_Response {
				request_kind = .Get_Realisation,
				status       = .Not_Found,
			}
			return encode_response_alloc(&response, allocator)
		}
		record, rec_refusal := object_cache.decode_realisation_record(data)
		if rec_refusal != .None || !object_cache.hashes_equal_constant_time(record.recipe_hash, request.recipe_hash) {
			response := object_cache.Cache_Response {
				request_kind = .Get_Realisation,
				status       = .Refused,
			}
			return encode_response_alloc(&response, allocator)
		}
		signing_bytes, sign_ok := object_cache.realisation_signing_bytes(&record)
		if !sign_ok || !cache_server_verify_ed25519(record.signer_public_key, signing_bytes[:], record.signature) {
			response := object_cache.Cache_Response {
				request_kind = .Get_Realisation,
				status       = .Bad_Signature,
			}
			return encode_response_alloc(&response, allocator)
		}
		response := object_cache.Cache_Response {
			request_kind = .Get_Realisation,
			status       = .Ok,
			realisation  = record,
		}
		return encode_response_alloc(&response, allocator)

	case .Put_Object:
		if !object_cache.signer_is_trusted(server.authorized_signers[:], request.uploader_public_key) {
			response := object_cache.Cache_Response {
				request_kind = .Put_Object,
				status       = .Unauthorized,
			}
			return encode_response_alloc(&response, allocator)
		}
		signing_bytes, sign_ok := object_cache.put_object_signing_bytes(
			request.object_kind,
			request.object_hash,
			u64(len(request.payload)),
			request.uploader_public_key,
		)
		if !sign_ok {
			response := object_cache.Cache_Response {
				request_kind = .Put_Object,
				status       = .Refused,
			}
			return encode_response_alloc(&response, allocator)
		}
		if !cache_server_verify_ed25519(request.uploader_public_key, signing_bytes[:], request.uploader_signature) {
			response := object_cache.Cache_Response {
				request_kind = .Put_Object,
				status       = .Bad_Signature,
			}
			return encode_response_alloc(&response, allocator)
		}
		if object_cache.verify_object_content(request.object_kind, request.object_hash, request.payload) != .Trust_By_Hash {
			response := object_cache.Cache_Response {
				request_kind = .Put_Object,
				status       = .Bad_Hash,
			}
			return encode_response_alloc(&response, allocator)
		}
		hex_bytes := hash_to_hex(request.object_hash)
		written, added := store_write_atomic(server, .Objects, string(hex_bytes[:]), request.payload)
		if !written {
			response := object_cache.Cache_Response {
				request_kind = .Put_Object,
				status       = .Refused,
			}
			return encode_response_alloc(&response, allocator)
		}
		cache_status_record_object(&server.status, u64(len(request.payload)), added, time.now())
		response := object_cache.Cache_Response {
			request_kind = .Put_Object,
			status       = .Ok,
		}
		return encode_response_alloc(&response, allocator)

	case .Put_Realisation:
		if !object_cache.signer_is_trusted(server.authorized_signers[:], request.realisation.signer_public_key) {
			response := object_cache.Cache_Response {
				request_kind = .Put_Realisation,
				status       = .Unauthorized,
			}
			return encode_response_alloc(&response, allocator)
		}
		signing_bytes, sign_ok := object_cache.realisation_signing_bytes(&request.realisation)
		if !sign_ok {
			response := object_cache.Cache_Response {
				request_kind = .Put_Realisation,
				status       = .Refused,
			}
			return encode_response_alloc(&response, allocator)
		}
		if !cache_server_verify_ed25519(request.realisation.signer_public_key, signing_bytes[:], request.realisation.signature) {
			response := object_cache.Cache_Response {
				request_kind = .Put_Realisation,
				status       = .Bad_Signature,
			}
			return encode_response_alloc(&response, allocator)
		}
		encoded_record: [object_cache.REALISATION_WIRE_SIZE]u8
		_, enc_refusal := object_cache.encode_realisation_record(&request.realisation, encoded_record[:])
		if enc_refusal != .None {
			response := object_cache.Cache_Response {
				request_kind = .Put_Realisation,
				status       = .Refused,
			}
			return encode_response_alloc(&response, allocator)
		}
		hex_bytes := hash_to_hex(request.realisation.recipe_hash)
		written, added := store_write_atomic(server, .Realisations, string(hex_bytes[:]), encoded_record[:])
		if !written {
			response := object_cache.Cache_Response {
				request_kind = .Put_Realisation,
				status       = .Refused,
			}
			return encode_response_alloc(&response, allocator)
		}
		cache_status_record_realisation(&server.status, request.realisation, added, time.now())
		response := object_cache.Cache_Response {
			request_kind = .Put_Realisation,
			status       = .Ok,
		}
		return encode_response_alloc(&response, allocator)
	}

	err_response := object_cache.Cache_Response {
		request_kind = .Has,
		status       = .Refused,
	}
	return encode_response_alloc(&err_response, allocator)
}

// tcp_read_exact reads exactly len(buffer) bytes from socket.
// When allow_eof_at_start is true and 0 bytes are read at offset 0, sets eof.
@(private = "file")
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

// cache_server_read_response_frame reads one framed response from socket
// (usable by host clients and integration tests).
cache_server_read_response_frame :: proc(
	socket: net.TCP_Socket,
	allocator := context.allocator,
) -> (frame: []u8, ok: bool) {
	header: [object_cache.FRAME_HEADER_SIZE]u8
	read_ok, _ := tcp_read_exact(socket, header[:], false)
	if !read_ok {
		return nil, false
	}
	_, _, body_length, header_refusal := object_cache.inspect_response_header(header[:])
	if header_refusal != .None {
		return nil, false
	}
	frame = make([]u8, object_cache.FRAME_HEADER_SIZE + body_length, allocator)
	copy(frame[:object_cache.FRAME_HEADER_SIZE], header[:])
	if body_length > 0 {
		body_ok, _ := tcp_read_exact(socket, frame[object_cache.FRAME_HEADER_SIZE:], false)
		if !body_ok {
			delete(frame, allocator)
			return nil, false
		}
	}
	return frame, true
}

// cache_server_serve_connection serves sequential object cache frames over one
// stream socket until clean EOF or a framing error.
cache_server_serve_connection :: proc(server: ^Cache_Server, socket: net.TCP_Socket) {
	_ = net.set_option(socket, .Receive_Timeout, foundation.HANG_BOUND)
	_ = net.set_option(socket, .Send_Timeout, foundation.HANG_BOUND)
	for !sync.atomic_load(&server.stop) {
		defer free_all(context.temp_allocator)
		header: [object_cache.FRAME_HEADER_SIZE]u8
		header_ok, eof := tcp_read_exact(socket, header[:], true)
		if eof {
			return
		}
		if !header_ok {
			return
		}
		_, body_length, header_refusal := object_cache.inspect_request_header(header[:])
		if header_refusal != .None {
			err_frame, _ := cache_server_handle_frame(server, header[:], context.temp_allocator)
			_ = tcp_write_all(socket, err_frame)
			return
		}
		request_frame := make([]u8, object_cache.FRAME_HEADER_SIZE + body_length)
		defer delete(request_frame)
		copy(request_frame[:object_cache.FRAME_HEADER_SIZE], header[:])
		if body_length > 0 {
			body_ok, _ := tcp_read_exact(socket, request_frame[object_cache.FRAME_HEADER_SIZE:], false)
			if !body_ok {
				return
			}
		}
		response_frame, _ := cache_server_handle_frame(server, request_frame)
		defer delete(response_frame)
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
	}
	defer if status_running != nil {
		sync.atomic_store(&server.stop, true)
		cache_status_stop(status_running)
	}

	cache_server_serve_listener(&server, listener)
	return true
}

@(private = "file")
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

// read_public_key_file reads a 64-hex-digit Ed25519 public key file.
read_public_key_file :: proc(path: string) -> (public_key: [object_cache.PUBLIC_KEY_SIZE]u8, ok: bool) {
	raw, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln("modustool: cache-serve: cannot read public key %s: %v", path, read_err)
		return {}, false
	}
	decoded, decode_ok := decode_hex_32(string(raw))
	if !decode_ok {
		fmt.eprintfln("modustool: cache-serve: %s must hold 64 hexadecimal digits", path)
		return {}, false
	}
	parsed: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&parsed, decoded[:]) {
		fmt.eprintfln("modustool: cache-serve: %s is not a valid Ed25519 public key", path)
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
			pub, ok := read_public_key_file(args[index])
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
