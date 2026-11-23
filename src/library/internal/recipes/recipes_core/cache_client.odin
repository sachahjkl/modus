// Freestanding QUIC client for the modus object cache v2 protocol
// (src/md/features/recipes.md, "The object cache and its protocol").
//
// Uses modus:quic over a caller-supplied UDP datagram transport callback
// (modus datagram ring in src/modules/system/recipes, or core:net UDP in host
// tests). Pins the server's raw Ed25519 public key, verifies Ed25519
// realisations against Substitution_Policy, verifies every 1 MiB Bao frame
// against the object root hash before writing to Recipes_State.store, and
// recursively fetches missing children of Tree outputs.
//
// Cache_Quic_Client holds ~2.3 MiB of fixed buffers and must live in static
// memory or a heap/page allocation, never on a stack.
package recipes_core

import "modus:contract/blake3"
import "modus:contract/errors"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"
import "modus:quic"
import "modus:random"

// Plan value: one bidirectional stream per sequential client RPC.
CACHE_CLIENT_STREAMS :: 1

// Plan value: QUIC idle timeout in milliseconds for the cache client.
CACHE_CLIENT_IDLE_TIMEOUT_MS :: 30_000

// Plan value: per-exchange timeout in microseconds (10 seconds).
CACHE_CLIENT_EXCHANGE_TIMEOUT_US :: u64(10_000_000)

// Plan value: maximum Busy retries while waiting for a server outboard build.
CACHE_CLIENT_BUSY_LIMIT :: 4096

// Plan value: maximum pending objects tracked while fetching a Tree closure.
CACHE_CLOSURE_QUEUE_CAPACITY :: 1024

// Closed set of transport and protocol outcomes from Cache_Quic_Client.
Cache_Client_Error :: enum u8 {
	None           = 0,
	Not_Configured = 1,
	Start_Failed   = 2,
	Bad_Server_Key = 3, // TLS handshake failed with bad_certificate (wrong pinned key).
	Handshake_Fail = 4,
	Timed_Out      = 5,
	Disconnected   = 6,
	Bad_Request    = 7,
	Bad_Response   = 8,
	Stream_Reset   = 9,
}

// UDP datagram seam provided by the host (modus datagram ring or host UDP socket).
Cache_Datagram_Transport :: struct {
	send:      proc "contextless" (bytes: []u8, user_data: rawptr) -> bool,
	recv:      proc "contextless" (buffer: []u8, deadline_us: u64, user_data: rawptr) -> (length: int, ok: bool),
	now_us:    proc "contextless" (user_data: rawptr) -> u64,
	user_data: rawptr,
}

// One object queued during iterative Tree closure fetching.
Cache_Closure_Item :: struct {
	hash: blake3.Hash,
	kind: object_cache.Cache_Object_Kind,
}

// Complete zero-allocation state of one QUIC object cache client.
Cache_Quic_Client :: struct {
	configured:            bool,
	connected:             bool,
	server_public_key:     [object_cache.PUBLIC_KEY_SIZE]u8,
	cryptography:          ^quic.Cryptography,
	generator:             ^random.Generator,
	transport:             Cache_Datagram_Transport,
	exchange_timeout_us:   u64,
	last_close_error_code: u64,
	connection:            quic.Connection,
	streams:               [CACHE_CLIENT_STREAMS]quic.Stream,
	request_buf:           [object_cache.FRAME_HEADER_SIZE + object_cache.MAX_REQUEST_BODY_BYTES]u8,
	response_buf:          [object_cache.FRAME_HEADER_SIZE + object_cache.MAX_RESPONSE_BODY_BYTES]u8,
	datagram_buf:          [quic.DATAGRAM_LIMIT]u8,
	closure_queue:         [CACHE_CLOSURE_QUEUE_CAPACITY]Cache_Closure_Item,
}

// cache_quic_client_init configures client with a pinned server Ed25519 public
// key, cryptography procedures, a seeded PRNG, and UDP datagram callbacks.
cache_quic_client_init :: proc "contextless" (
	client: ^Cache_Quic_Client,
	server_public_key: [object_cache.PUBLIC_KEY_SIZE]u8,
	cryptography: ^quic.Cryptography,
	generator: ^random.Generator,
	transport: Cache_Datagram_Transport,
	exchange_timeout_us: u64 = CACHE_CLIENT_EXCHANGE_TIMEOUT_US,
) -> bool {
	if client == nil || cryptography == nil || generator == nil ||
	   transport.send == nil || transport.recv == nil || transport.now_us == nil {
		return false
	}
	key_copy := server_public_key
	if object_cache.bytes_all_zero(key_copy[:]) {
		return false
	}
	client.configured = true
	client.connected = false
	client.server_public_key = server_public_key
	client.cryptography = cryptography
	client.generator = generator
	client.transport = transport
	client.exchange_timeout_us = exchange_timeout_us > 0 ? exchange_timeout_us : CACHE_CLIENT_EXCHANGE_TIMEOUT_US
	client.last_close_error_code = 0
	return true
}

@(private = "file")
client_drain_sends :: proc "contextless" (client: ^Cache_Quic_Client, now: u64) -> bool {
	for {
		length := quic.connection_datagram_send(&client.connection, client.datagram_buf[:quic.MAX_DATAGRAM_SIZE], now)
		if length == 0 {
			return true
		}
		if !client.transport.send(client.datagram_buf[:length], client.transport.user_data) {
			return false
		}
	}
}

@(private = "file")
client_step_io :: proc "contextless" (client: ^Cache_Quic_Client, deadline: u64) -> bool {
	now := client.transport.now_us(client.transport.user_data)
	if !client_drain_sends(client, now) {
		return false
	}
	if now >= deadline {
		return false
	}
	conn_deadline := quic.connection_deadline(&client.connection)
	wait_until := deadline
	if conn_deadline != quic.NO_DEADLINE && conn_deadline < wait_until {
		wait_until = conn_deadline
	}
	received, ok := client.transport.recv(client.datagram_buf[:], wait_until, client.transport.user_data)
	now = client.transport.now_us(client.transport.user_data)
	if ok && received > 0 {
		err: errors.Error_Record
		quic.connection_datagram_receive(&client.connection, client.datagram_buf[:received], now, &err)
	}
	quic.connection_time_passes(&client.connection, now)
	_ = client_drain_sends(client, now)
	return true
}

// cache_quic_client_connect completes the QUIC + TLS 1.3 handshake with ALPN
// object_cache.APPLICATION_PROTOCOL and pinned server_public_key.
cache_quic_client_connect :: proc "contextless" (client: ^Cache_Quic_Client) -> Cache_Client_Error {
	if client == nil || !client.configured {
		return .Not_Configured
	}
	if client.connected && client.connection.state == .Connected {
		return .None
	}
	client.connected = false
	client.last_close_error_code = 0

	cfg := quic.Connection_Configuration {
		idle_timeout_milliseconds = CACHE_CLIENT_IDLE_TIMEOUT_MS,
		tls = {
			role                = .Client,
			least_seed_strength = .Processor,
			server_public_key   = client.server_public_key,
		},
	}
	cfg.tls.application_protocol_length = copy(cfg.tls.application_protocol[:], object_cache.APPLICATION_PROTOCOL)

	now := client.transport.now_us(client.transport.user_data)
	start_err: errors.Error_Record
	if !quic.connection_start_client(
		&client.connection,
		client.streams[:],
		&cfg,
		client.cryptography,
		client.generator,
		now,
		&start_err,
	) {
		return .Start_Failed
	}

	deadline := now + client.exchange_timeout_us
	for {
		if client.connection.state == .Connected && client.connection.peer_parameters_applied {
			client.connected = true
			return .None
		}
		if client.connection.state == .Closing || client.connection.state == .Draining || client.connection.state == .Closed {
			client.last_close_error_code = client.connection.close_error_code
			// Pump once so our CONNECTION_CLOSE alert reaches the server cleanly.
			_ = client_drain_sends(client, client.transport.now_us(client.transport.user_data))
			if client.connection.close_error_code == u64(quic.CRYPTO_ERROR_BASE) + u64(quic.Alert.Bad_Certificate) ||
			   client.connection.tls.alert == .Bad_Certificate {
				return .Bad_Server_Key
			}
			return .Handshake_Fail
		}
		if client.transport.now_us(client.transport.user_data) >= deadline {
			return .Timed_Out
		}
		if !client_step_io(client, deadline) {
			if client.transport.now_us(client.transport.user_data) >= deadline {
				return .Timed_Out
			}
		}
	}
}

// cache_quic_client_close sends CONNECTION_CLOSE and resets local connection state.
cache_quic_client_close :: proc "contextless" (client: ^Cache_Quic_Client) {
	if client == nil {
		return
	}
	if client.connection.state != .Idle && client.connection.state != .Closed {
		now := client.transport.now_us(client.transport.user_data)
		quic.connection_close(&client.connection, 0, now)
		_ = client_drain_sends(client, now)
	}
	client.connected = false
}

// cache_quic_client_exchange sends one v2 request frame on a fresh QUIC stream,
// reads and decodes the response frame into client.response_buf, and drains the
// stream so the stream slot is returned. Response slices borrow from client.response_buf.
cache_quic_client_exchange :: proc "contextless" (
	client: ^Cache_Quic_Client,
	request: ^object_cache.Cache_Request,
) -> (response: object_cache.Cache_Response, err: Cache_Client_Error) {
	if client == nil || !client.configured {
		return {}, .Not_Configured
	}
	req_len, enc_refusal := object_cache.encode_request(request, client.request_buf[:])
	if enc_refusal != .None {
		return {}, .Bad_Request
	}
	if !client.connected || client.connection.state != .Connected {
		if conn_err := cache_quic_client_connect(client); conn_err != .None {
			return {}, conn_err
		}
	}

	now := client.transport.now_us(client.transport.user_data)
	deadline := now + client.exchange_timeout_us

	// Wait until a stream slot and peer MAX_STREAMS window are available.
	stream_id: u64
	opened := false
	for !opened {
		if client.connection.state != .Connected {
			client.connected = false
			return {}, .Disconnected
		}
		stream_id, opened = quic.stream_open(&client.connection)
		if opened {
			break
		}
		if client.transport.now_us(client.transport.user_data) >= deadline {
			cache_quic_client_close(client)
			return {}, .Timed_Out
		}
		_ = client_step_io(client, deadline)
	}

	// Stream the request bytes with FIN while simultaneously receiving response
	// bytes if the server answers early (e.g. header refusal).
	sent := 0
	recv_len := 0
	expected_len := object_cache.FRAME_HEADER_SIZE
	header_parsed := false
	peer_finished := false

	for {
		if client.connection.state != .Connected {
			client.connected = false
			return {}, .Disconnected
		}
		if sent < req_len {
			wrote := quic.stream_write(&client.connection, stream_id, client.request_buf[sent:req_len], true)
			sent += wrote
		}

		// Read any available response bytes into client.response_buf.
		for !peer_finished {
			if !header_parsed {
				need := object_cache.FRAME_HEADER_SIZE - recv_len
				n, fin, rst := quic.stream_read(&client.connection, stream_id, client.response_buf[recv_len:recv_len + need])
				if rst {
					return {}, .Stream_Reset
				}
				recv_len += n
				if fin {
					peer_finished = true
				}
				if recv_len == object_cache.FRAME_HEADER_SIZE {
					_, _, body_len, hdr_refusal := object_cache.inspect_response_header(client.response_buf[:object_cache.FRAME_HEADER_SIZE])
					if hdr_refusal != .None {
						quic.stream_reset(&client.connection, stream_id, 1)
						quic.stream_stop_sending(&client.connection, stream_id, 1)
						return {}, .Bad_Response
					}
					expected_len = object_cache.FRAME_HEADER_SIZE + body_len
					header_parsed = true
				}
				if n == 0 {
					break
				}
			} else if recv_len < expected_len {
				n, fin, rst := quic.stream_read(&client.connection, stream_id, client.response_buf[recv_len:expected_len])
				if rst {
					return {}, .Stream_Reset
				}
				recv_len += n
				if fin {
					peer_finished = true
				}
				if n == 0 {
					break
				}
			} else {
				// Frame complete; read 0-byte FIN if present so stream slot frees promptly.
				extra: [1]u8
				n, fin, rst := quic.stream_read(&client.connection, stream_id, extra[:])
				if rst {
					return {}, .Stream_Reset
				}
				if n > 0 {
					return {}, .Bad_Response
				}
				if fin {
					peer_finished = true
				}
				break
			}
		}

		if sent == req_len && header_parsed && recv_len == expected_len && peer_finished {
			break
		}
		if header_parsed && recv_len < expected_len && peer_finished {
			return {}, .Bad_Response
		}
		if !header_parsed && peer_finished {
			return {}, .Bad_Response
		}
		if client.transport.now_us(client.transport.user_data) >= deadline {
			cache_quic_client_close(client)
			return {}, .Timed_Out
		}
		_ = client_step_io(client, deadline)
	}

	// Flush final ACK for the stream FIN so server frees its slot immediately.
	_ = client_drain_sends(client, client.transport.now_us(client.transport.user_data))

	decoded, dec_refusal := object_cache.decode_response(client.response_buf[:expected_len])
	if dec_refusal != .None || decoded.request_kind != request.kind {
		return {}, .Bad_Response
	}
	return decoded, .None
}

// cache_quic_fetch_object_to_store fetches one content-addressed object over
// QUIC in aligned 1 MiB frames, verifies every frame with its Bao inclusion
// proof (or canonical tree_hash for Tree) BEFORE writing it to state.store,
// enforces the 75% retention guard, and writes under unified <64-hex> name.
cache_quic_fetch_object_to_store :: proc "contextless" (
	client: ^Cache_Quic_Client,
	state: ^Recipes_State,
	expected_hash: blake3.Hash,
	kind: object_cache.Cache_Object_Kind,
) -> (object_size: u64, refusal: pr.Recipe_Refusal) {
	if client == nil || state == nil {
		return 0, .Cache_Miss
	}
	obj_name := pr.blob_object_name(expected_hash)
	obj_name_text := pr.private_object_name_text(&obj_name)

	// Fetch frame 0 first (retrying monotonically on .Busy).
	resp0, busy_ok := fetch_frame_with_busy(client, expected_hash, kind, 0)
	if !busy_ok {
		return 0, .Cache_Miss
	}
	if resp0.status == .Not_Found {
		return 0, .Cache_Miss
	}
	if resp0.status != .Ok {
		return 0, .Malformed_Output
	}
	if resp0.object_kind != kind || resp0.offset != 0 {
		return 0, .Malformed_Output
	}
	object_size = resp0.object_size
	if object_size > OUTPUT_BYTES_MOST {
		return 0, .Malformed_Output
	}
	frame_count, count_ok := object_cache.object_frame_count(object_size)
	if !count_ok {
		return 0, .Malformed_Output
	}
	if object_cache.object_frame_verify(kind, expected_hash, object_size, 0, resp0.proof, resp0.payload) != .Trust_By_Hash {
		return 0, .Hash_Mismatch
	}
	if room_refusal := retention_make_room(state, object_size); room_refusal != .None {
		return 0, room_refusal
	}
	if frame_count == 1 {
		if pr.private_store_write(&state.store, obj_name_text, resp0.payload) != .Ok {
			return 0, .Store_Failed
		}
		return object_size, .None
	}
	if kind != .Blob {
		return 0, .Malformed_Output
	}

	// Multi-frame Blob: stream frame 0, then frames 1 ..< frame_count,
	// verifying each Bao frame before writing it. Remove partial object on any failure.
	if pr.private_store_write_range(&state.store, obj_name_text, 0, resp0.payload, object_size, false) != .Ok {
		_ = pr.private_store_remove(&state.store, obj_name_text)
		return 0, .Store_Failed
	}
	for frame_index in u64(1) ..< frame_count {
		offset := frame_index * object_cache.FRAME_PAYLOAD_BYTES
		resp, frame_ok := fetch_frame_with_busy(client, expected_hash, .Blob, offset)
		if !frame_ok || resp.status != .Ok || resp.object_kind != .Blob || resp.object_size != object_size || resp.offset != offset {
			_ = pr.private_store_remove(&state.store, obj_name_text)
			return 0, .Malformed_Output
		}
		if object_cache.object_frame_verify(.Blob, expected_hash, object_size, frame_index, resp.proof, resp.payload) != .Trust_By_Hash {
			_ = pr.private_store_remove(&state.store, obj_name_text)
			return 0, .Hash_Mismatch
		}
		is_final := frame_index == frame_count - 1
		if pr.private_store_write_range(&state.store, obj_name_text, offset, resp.payload, object_size, is_final) != .Ok {
			_ = pr.private_store_remove(&state.store, obj_name_text)
			return 0, .Store_Failed
		}
	}
	return object_size, .None
}

@(private = "file")
fetch_frame_with_busy :: proc "contextless" (
	client: ^Cache_Quic_Client,
	object_hash: blake3.Hash,
	kind: object_cache.Cache_Object_Kind,
	offset: u64,
) -> (response: object_cache.Cache_Response, ok: bool) {
	req := object_cache.Cache_Request {
		kind        = .Get_Object,
		object_hash = object_hash,
		object_kind = kind,
		offset      = offset,
	}
	last_built: u64 = 0
	expected_frames: u64 = 0
	for _ in 0 ..< CACHE_CLIENT_BUSY_LIMIT {
		resp, err := cache_quic_client_exchange(client, &req)
		if err != .None {
			return {}, false
		}
		if resp.status != .Busy {
			return resp, true
		}
		if expected_frames == 0 {
			expected_frames = resp.frame_count
		} else if resp.frame_count != expected_frames || resp.frames_built <= last_built {
			return {}, false
		}
		last_built = resp.frames_built
	}
	return {}, false
}

// cache_quic_fetch_closure_to_store fetches root_hash (and for Tree outputs,
// iteratively fetches every missing child Tree, Part, and Blob into state.store).
cache_quic_fetch_closure_to_store :: proc "contextless" (
	client: ^Cache_Quic_Client,
	state: ^Recipes_State,
	root_hash: blake3.Hash,
	root_kind: object_cache.Cache_Object_Kind,
) -> (root_size: u64, refusal: pr.Recipe_Refusal) {
	head := 0
	tail := 0
	client.closure_queue[tail] = {hash = root_hash, kind = root_kind}
	tail += 1

	for head < tail {
		item := client.closure_queue[head]
		head += 1

		// Check if already stored with matching hash (for non-root blobs).
		if head > 1 && item.kind == .Blob {
			existing_name := pr.blob_object_name(item.hash)
			if existing_size, sz_status := pr.private_store_size(&state.store, pr.private_object_name_text(&existing_name)); sz_status == .Ok {
				if stored_output_check(state, item.hash, .Blob, existing_size) == .Whole {
					continue
				}
			}
		}

		obj_size, fetch_refusal := cache_quic_fetch_object_to_store(client, state, item.hash, item.kind)
		if fetch_refusal != .None {
			return 0, fetch_refusal
		}
		if head == 1 {
			root_size = obj_size
		}
		if item.kind == .Tree {
			// The verified single-frame MODTREE2 bytes are still in client.response_buf
			// inside the last Get_Object response; decode directly from client.response_buf.
			decoded, dec_ref := object_cache.decode_response(client.response_buf[:object_cache.FRAME_HEADER_SIZE + object_cache.GET_OBJECT_RESPONSE_HEADER_SIZE + int(obj_size)])
			if dec_ref != .None {
				return 0, .Malformed_Output
			}
			entry_count := tree_hash.tree_entry_count(decoded.payload)
			offset := tree_hash.HEADER_SIZE
			for _ in 0 ..< entry_count {
				entry, next_offset, entry_ok := tree_hash.tree_entry_next(decoded.payload, offset)
				if !entry_ok {
					return 0, .Malformed_Output
				}
				offset = next_offset
				child_kind: object_cache.Cache_Object_Kind = .Blob
				switch entry.kind {
				case .Object:
					child_kind = .Blob
				case .Tree, .Part:
					child_kind = .Tree
				}
				// Skip duplicates already queued.
				seen := false
				for existing in client.closure_queue[:tail] {
					if existing.hash == entry.hash && existing.kind == child_kind {
						seen = true
						break
					}
				}
				if !seen {
					if tail >= len(client.closure_queue) {
						return 0, .Malformed_Output
					}
					client.closure_queue[tail] = {hash = entry.hash, kind = child_kind}
					tail += 1
				}
			}
		}
	}
	return root_size, .None
}

// cache_quic_fetch_realisation_callback is a Recipes_State.remote_cache_fetch
// implementation backed by Cache_Quic_Client + an Ed25519 Signature_Verify_Proc.
Cache_Quic_Fetch_Context :: struct {
	client:           ^Cache_Quic_Client,
	verify_signature: object_cache.Signature_Verify_Proc,
	verify_user:      rawptr,
}

cache_quic_fetch_realisation :: proc "contextless" (
	state: ^Recipes_State,
	spec: ^pr.Recipe_Spec,
	recipe_hash: blake3.Hash,
	policy: object_cache.Substitution_Policy,
	out_realisation: ^object_cache.Realisation_Record,
	out_length: ^u64,
	user_data: rawptr,
) -> (found: bool, refusal: pr.Recipe_Refusal) {
	ctx := (^Cache_Quic_Fetch_Context)(user_data)
	if ctx == nil || ctx.client == nil || !ctx.client.configured || spec == nil || out_realisation == nil || out_length == nil {
		return false, .None
	}

	req := object_cache.Cache_Request {
		kind        = .Get_Realisation,
		recipe_hash = recipe_hash,
	}
	resp, err := cache_quic_client_exchange(ctx.client, &req)
	if err != .None {
		// Network unreachable or handshake failure is treated as a cache miss
		// so Prefer_Cache can fall back to local build and Cache_Only refuses Cache_Miss.
		if err == .Bad_Server_Key {
			return false, .Untrusted_Realisation
		}
		return false, .None
	}
	if resp.status == .Not_Found {
		return false, .None
	}
	if resp.status != .Ok {
		return false, .Malformed_Output
	}

	realisation := resp.realisation
	if realisation.output_kind != spec.output_kind {
		return false, .Malformed_Output
	}
	decision := object_cache.substitution_check(
		policy,
		object_cache.Substitution_Realisation_Subject{
			expected_recipe_hash = recipe_hash,
			realisation          = realisation,
		},
		ctx.verify_signature,
		ctx.verify_user,
	)
	switch decision {
	case .Trust_By_Signer:
	case .Refuse_Untrusted_Signer:
		return false, .Untrusted_Realisation
	case .Refuse_Bad_Signature:
		return false, .Bad_Signature
	case .Refuse_Hash_Mismatch:
		return false, .Hash_Mismatch
	case .Trust_By_Hash, .Refuse_Malformed:
		return false, .Malformed_Output
	}

	root_size, closure_refusal := cache_quic_fetch_closure_to_store(ctx.client, state, realisation.output_hash, realisation.output_kind)
	if closure_refusal != .None {
		return false, closure_refusal
	}
	out_realisation^ = realisation
	out_length^ = root_size
	return true, .None
}

// cache_quic_put_object uploads data over QUIC using Put_Object + aligned 1 MiB
// Put_Object_Frame requests.
cache_quic_put_object :: proc "contextless" (
	client: ^Cache_Quic_Client,
	kind: object_cache.Cache_Object_Kind,
	object_hash: blake3.Hash,
	data: []u8,
	uploader_public_key: [object_cache.PUBLIC_KEY_SIZE]u8,
	uploader_signature: [object_cache.SIGNATURE_SIZE]u8,
) -> (status: object_cache.Cache_Response_Status, err: Cache_Client_Error) {
	head := object_cache.Cache_Request {
		kind                = .Put_Object,
		object_hash         = object_hash,
		object_kind         = kind,
		object_size         = u64(len(data)),
		uploader_public_key = uploader_public_key,
		uploader_signature  = uploader_signature,
	}
	head_resp, head_err := cache_quic_client_exchange(client, &head)
	if head_err != .None {
		return {}, head_err
	}
	if head_resp.status != .Ok {
		return head_resp.status, .None
	}
	if head_resp.put_state == .Already_Present {
		return .Ok, .None
	}
	frame_count, count_ok := object_cache.object_frame_count(u64(len(data)))
	if !count_ok {
		return .Refused, .Bad_Request
	}
	for frame_index in u64(0) ..< frame_count {
		offset := frame_index * object_cache.FRAME_PAYLOAD_BYTES
		frame_len, len_ok := object_cache.object_frame_length(u64(len(data)), frame_index)
		if !len_ok {
			return .Refused, .Bad_Request
		}
		frame_req := object_cache.Cache_Request {
			kind        = .Put_Object_Frame,
			object_hash = object_hash,
			offset      = offset,
			payload     = data[offset:offset + frame_len],
		}
		frame_resp, frame_err := cache_quic_client_exchange(client, &frame_req)
		if frame_err != .None {
			return {}, frame_err
		}
		if frame_resp.status != .Ok {
			return frame_resp.status, .None
		}
	}
	return .Ok, .None
}

// cache_quic_get_references queries Get_References over QUIC and copies up to
// len(out_hashes) returned hashes.
cache_quic_get_references :: proc "contextless" (
	client: ^Cache_Quic_Client,
	object_hash: blake3.Hash,
	out_hashes: []blake3.Hash,
) -> (count: int, status: object_cache.Cache_Response_Status, err: Cache_Client_Error) {
	req := object_cache.Cache_Request {
		kind        = .Get_References,
		object_hash = object_hash,
	}
	resp, exch_err := cache_quic_client_exchange(client, &req)
	if exch_err != .None {
		return 0, {}, exch_err
	}
	if resp.status != .Ok {
		return 0, resp.status, .None
	}
	total := object_cache.response_reference_count(&resp)
	limit := min(total, len(out_hashes))
	for index in 0 ..< limit {
		if h, ok := object_cache.response_reference_at(&resp, index); ok {
			out_hashes[index] = h
		}
	}
	return total, .Ok, .None
}

// cache_quic_get_release_pointer queries Get_Release_Pointer over QUIC.
cache_quic_get_release_pointer :: proc "contextless" (
	client: ^Cache_Quic_Client,
	publisher_public_key: [object_cache.PUBLIC_KEY_SIZE]u8,
	name: string,
) -> (pointer: object_cache.Release_Pointer, status: object_cache.Cache_Response_Status, err: Cache_Client_Error) {
	if len(name) == 0 || len(name) > object_cache.RELEASE_POINTER_NAME_CAPACITY {
		return {}, {}, .Bad_Request
	}
	req := object_cache.Cache_Request {
		kind = .Get_Release_Pointer,
		release_pointer = {
			publisher_public_key = publisher_public_key,
			name_length          = u8(len(name)),
		},
	}
	copy(req.release_pointer.name[:], name)
	resp, exch_err := cache_quic_client_exchange(client, &req)
	if exch_err != .None {
		return {}, {}, exch_err
	}
	return resp.release_pointer, resp.status, .None
}
