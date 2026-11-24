// QUIC UDP listener for the host-side object cache server
// (src/md/features/recipes.md, "The object cache and its protocol").
//
// Runs on its own thread alongside the TCP listener in cache_server.odin,
// serving the exact same v2 MOCQ/MOCR binary framing over QUIC streams
// (ALPN = "modus-object-cache", raw Ed25519 server public key).
package cache_server

import "core:crypto"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "modus:contract/errors"
import "modus:contract/object_cache"
import crypto_compat "modus:cryptography/compatibility_crypto"
import "modus:cryptography/ed25519"
import "modus:cryptography_primitives"
import "modus:quic"
import "modus:random"

// Plan value: default concurrent QUIC clients served by one cache-serve instance
// (overridable with --quic-connections up to CACHE_QUIC_MAX_CONNECTIONS).
CACHE_QUIC_DEFAULT_CONNECTIONS :: 32

// Plan value: upper bound on concurrent QUIC clients accepted by --quic-connections.
CACHE_QUIC_MAX_CONNECTIONS :: 256

// Plan value: concurrent bidirectional streams allowed per QUIC client.
CACHE_QUIC_STREAMS_PER_CONNECTION :: 4

// Plan value: QUIC idle timeout in milliseconds, matching the system QUIC services.
CACHE_QUIC_IDLE_TIMEOUT_MS :: 30_000

// Plan value: upper bound on one UDP receive wait so stop flags and QUIC timers wake promptly.
CACHE_QUIC_POLL_INTERVAL :: 5 * time.Millisecond

// Stream framing phase for the active stream of one QUIC client slot.
Cache_Quic_Stream_Phase :: enum u8 {
	Reading_Header   = 0,
	Reading_Body     = 1,
	Writing_Response = 2,
}

// Per-stream framing state for one concurrent bidirectional QUIC stream.
Cache_Quic_Stream_State :: struct {
	in_use:           bool,
	stream_id:        u64,
	phase:            Cache_Quic_Stream_Phase,
	recv_len:         int,
	expected_len:     int,
	send_len:         int,
	send_offset:      int,
	peer_finished:    bool,
	close_after_send: bool,
	request_buf:      [dynamic]u8,
	response_buf:     [dynamic]u8,
}

// Per-connection application state paired with one quic.Server record slot.
Cache_Quic_Client_Slot :: struct {
	generation:    u64,
	conn:          Cache_Connection,
	stream_states: [CACHE_QUIC_STREAMS_PER_CONNECTION]Cache_Quic_Stream_State,
}

// Running QUIC listener state and its worker thread.
Cache_Quic_Running :: struct {
	server:          ^Cache_Server,
	socket:          net.UDP_Socket,
	bound_endpoint:  net.Endpoint,
	public_key:      [quic.ED25519_KEY_SIZE]u8,
	max_connections: int,
	stop:            bool,
	worker:          ^thread.Thread,
	cryptography:    quic.Cryptography,
	generator:       random.Generator,
	quic_server:     quic.Server,
	connections:     []quic.Connection,
	records:         []quic.Server_Record,
	streams:         []quic.Stream,
	slots:           []Cache_Quic_Client_Slot,
	start_tick:      time.Tick,
}

// cache_quic_cryptography builds a quic.Cryptography table backed by the modus
// cryptography primitives compiled for the host.
cache_quic_cryptography :: proc() -> quic.Cryptography {
	return {
		seal_with_aes_128_gcm                = cryptography_primitives.seal_with_aes_128_gcm,
		open_with_aes_128_gcm                = cryptography_primitives.open_with_aes_128_gcm,
		seal_with_chacha20_poly1305          = cryptography_primitives.seal_with_chacha20_poly1305,
		open_with_chacha20_poly1305          = cryptography_primitives.open_with_chacha20_poly1305,
		hkdf_sha256_extract                  = cryptography_primitives.hkdf_sha256_extract,
		hkdf_sha256_expand                   = cryptography_primitives.hkdf_sha256_expand,
		header_protection_mask_with_aes_128  = cryptography_primitives.header_protection_mask_with_aes_128,
		header_protection_mask_with_chacha20 = cryptography_primitives.header_protection_mask_with_chacha20,
		sha256                               = cryptography_primitives.sha256,
		hmac_sha256                          = cryptography_primitives.hmac_sha256,
		x25519                               = cryptography_primitives.x25519,
		ed25519_public_key                   = cryptography_primitives.ed25519_public_key,
		ed25519_sign                         = cryptography_primitives.ed25519_sign,
		ed25519_verify                       = cryptography_primitives.ed25519_verify,
	}
}

// cache_quic_random_private_key fills out with 32 random bytes from the host
// cryptographic random source and checks that it forms an Ed25519 key.
cache_quic_random_private_key :: proc(out: ^[quic.ED25519_KEY_SIZE]u8) -> bool {
	crypto.rand_bytes(out[:])
	parsed: ed25519.Private_Key
	defer ed25519.private_key_clear(&parsed)
	return ed25519.private_key_set_bytes(&parsed, out[:])
}

// cache_quic_load_or_create_key loads <root_directory>/quic_server.key if it
// exists, or generates a fresh Ed25519 seed and persists it as 64 hex digits
// so the pinned server public key stays stable across restarts.
cache_quic_load_or_create_key :: proc(root_directory: string, out: ^[quic.ED25519_KEY_SIZE]u8) -> bool {
	key_path := strings.concatenate({root_directory, "/quic_server.key"}, context.temp_allocator)
	if os.exists(key_path) {
		loaded, ok := read_private_key_file("cache-serve", key_path)
		if !ok {
			return false
		}
		out^ = loaded
		crypto_compat.zero_explicit(&loaded, size_of(loaded))
		return true
	}
	if !cache_quic_random_private_key(out) {
		return false
	}
	hex_bytes := hash_to_hex(out^)
	defer crypto_compat.zero_explicit(&hex_bytes, size_of(hex_bytes))
	// Create directly with 0o600 so the private key is never world-readable.
	key_file, open_err := os.open(key_path, {.Write, .Create, .Trunc}, os.perm(0o600))
	if open_err != nil {
		crypto_compat.zero_explicit(out, size_of(out^))
		return false
	}
	written_ok := file_write_all(key_file, hex_bytes[:])
	synced_ok := file_sync_and_close(key_file)
	if !written_ok || !synced_ok {
		_ = os.remove(key_path)
		crypto_compat.zero_explicit(out, size_of(out^))
		return false
	}
	return true
}

// cache_quic_public_key_of_private derives the 32-byte Ed25519 public key for
// private_key.
cache_quic_public_key_of_private :: proc(private_key: [quic.ED25519_KEY_SIZE]u8) -> (public_key: [quic.ED25519_KEY_SIZE]u8, ok: bool) {
	seed := private_key
	parsed: ed25519.Private_Key
	defer ed25519.private_key_clear(&parsed)
	if !ed25519.private_key_set_bytes(&parsed, seed[:]) {
		return {}, false
	}
	ed25519.private_key_public_bytes(&parsed, public_key[:])
	return public_key, true
}

@(private)
endpoint_to_quic_remote :: proc(ep: net.Endpoint) -> (remote: quic.Remote, ok: bool) {
	ip4, is_ip4 := ep.address.(net.IP4_Address)
	if !is_ip4 || ep.port <= 0 || ep.port > int(max(u16)) {
		return {}, false
	}
	address := u32(ip4[0]) << 24 | u32(ip4[1]) << 16 | u32(ip4[2]) << 8 | u32(ip4[3])
	return quic.Remote{address = address, port = u16(ep.port)}, true
}

@(private)
quic_remote_to_endpoint :: proc(remote: quic.Remote) -> net.Endpoint {
	ip4 := net.IP4_Address{
		u8(remote.address >> 24),
		u8(remote.address >> 16),
		u8(remote.address >> 8),
		u8(remote.address),
	}
	return net.Endpoint{address = ip4, port = int(remote.port)}
}

@(private = "file")
cache_quic_now_us :: proc(running: ^Cache_Quic_Running) -> u64 {
	return u64(time.tick_since(running.start_tick) / time.Microsecond) + 1
}

@(private = "file")
stream_state_clear :: proc(st: ^Cache_Quic_Stream_State) {
	st.in_use = false
	st.stream_id = 0
	st.phase = .Reading_Header
	st.recv_len = 0
	st.expected_len = object_cache.FRAME_HEADER_SIZE
	st.send_len = 0
	st.send_offset = 0
	st.peer_finished = false
	st.close_after_send = false
	clear(&st.request_buf)
	clear(&st.response_buf)
}

@(private = "file")
slot_reset_for_new_connection :: proc(slot: ^Cache_Quic_Client_Slot, generation: u64) {
	put_session_abort(&slot.conn.put)
	slot.generation = generation
	for &st in slot.stream_states {
		delete(st.request_buf)
		delete(st.response_buf)
		st = {}
	}
}

@(private = "file")
slot_find_stream_state :: proc(slot: ^Cache_Quic_Client_Slot, stream_id: u64) -> ^Cache_Quic_Stream_State {
	for &st in slot.stream_states {
		if st.in_use && st.stream_id == stream_id {
			return &st
		}
	}
	return nil
}

@(private = "file")
slot_attach_new_streams :: proc(slot: ^Cache_Quic_Client_Slot, connection: ^quic.Connection) {
	for &stream in connection.streams {
		if !stream.in_use {
			continue
		}
		if stream.send_finish || stream.reset_sent || stream.stop_sending_sent {
			continue
		}
		if slot_find_stream_state(slot, stream.identifier) != nil {
			continue
		}
		for &st in slot.stream_states {
			if !st.in_use {
				stream_state_clear(&st)
				st.in_use = true
				st.stream_id = stream.identifier
				st.phase = .Reading_Header
				st.expected_len = object_cache.FRAME_HEADER_SIZE
				break
			}
		}
	}
}

@(private = "file")
stream_queue_response :: proc(st: ^Cache_Quic_Stream_State, resp: []u8, close_after: bool) {
	resize(&st.response_buf, len(resp))
	copy(st.response_buf[:len(resp)], resp)
	st.send_len = len(resp)
	st.send_offset = 0
	st.close_after_send = close_after
	st.phase = .Writing_Response
}

@(private = "file")
slot_step_one_stream :: proc(running: ^Cache_Quic_Running, slot: ^Cache_Quic_Client_Slot, connection: ^quic.Connection, st: ^Cache_Quic_Stream_State) -> (progressed: bool) {
	stream := quic.stream_of(connection, st.stream_id)
	if stream == nil {
		stream_state_clear(st)
		return true
	}

	switch st.phase {
	case .Reading_Header:
		if len(st.request_buf) < object_cache.FRAME_HEADER_SIZE {
			resize(&st.request_buf, object_cache.FRAME_HEADER_SIZE)
		}
		need := object_cache.FRAME_HEADER_SIZE - st.recv_len
		n, finished, reset := quic.stream_read(connection, st.stream_id, st.request_buf[st.recv_len:st.recv_len + need])
		if reset {
			put_session_abort(&slot.conn.put)
			quic.stream_reset(connection, st.stream_id, 0)
			stream_state_clear(st)
			return true
		}
		st.recv_len += n
		if finished {
			st.peer_finished = true
		}
		if st.recv_len == 0 && st.peer_finished {
			_ = quic.stream_write(connection, st.stream_id, nil, true)
			stream_state_clear(st)
			return true
		}
		if st.recv_len < object_cache.FRAME_HEADER_SIZE {
			if st.peer_finished {
				resp, _ := cache_server_handle_connection_frame(running.server, &slot.conn, st.request_buf[:st.recv_len])
				stream_queue_response(st, resp, true)
				return true
			}
			return n > 0
		}
		_, body_length, header_refusal := object_cache.inspect_request_header(st.request_buf[:object_cache.FRAME_HEADER_SIZE])
		if header_refusal != .None {
			resp, _ := cache_server_handle_connection_frame(running.server, &slot.conn, st.request_buf[:object_cache.FRAME_HEADER_SIZE])
			stream_queue_response(st, resp, true)
			quic.stream_stop_sending(connection, st.stream_id, 1)
			return true
		}
		st.expected_len = object_cache.FRAME_HEADER_SIZE + body_length
		if len(st.request_buf) < st.expected_len {
			resize(&st.request_buf, st.expected_len)
		}
		st.phase = .Reading_Body
		return true

	case .Reading_Body:
		before := st.recv_len
		for st.recv_len < st.expected_len {
			n, finished, reset := quic.stream_read(connection, st.stream_id, st.request_buf[st.recv_len:st.expected_len])
			if reset {
				put_session_abort(&slot.conn.put)
				quic.stream_reset(connection, st.stream_id, 0)
				stream_state_clear(st)
				return true
			}
			st.recv_len += n
			if finished {
				st.peer_finished = true
			}
			if n == 0 {
				break
			}
		}
		if st.recv_len < st.expected_len {
			if st.peer_finished {
				resp, _ := cache_server_handle_connection_frame(running.server, &slot.conn, st.request_buf[:st.recv_len])
				stream_queue_response(st, resp, true)
				return true
			}
			return st.recv_len > before
		}
		resp, _ := cache_server_handle_connection_frame(running.server, &slot.conn, st.request_buf[:st.expected_len])
		stream_queue_response(st, resp, false)
		return true

	case .Writing_Response:
		want_fin := st.peer_finished || st.close_after_send
		remaining := st.response_buf[st.send_offset:st.send_len]
		wrote := quic.stream_write(connection, st.stream_id, remaining, want_fin)
		st.send_offset += wrote
		if st.send_offset < st.send_len {
			return wrote > 0
		}
		if want_fin {
			if st.close_after_send {
				quic.stream_stop_sending(connection, st.stream_id, 1)
			}
			stream_state_clear(st)
			return true
		}
		st.recv_len = 0
		st.expected_len = object_cache.FRAME_HEADER_SIZE
		st.phase = .Reading_Header
		return true
	}
	return false
}

// slot_service_streams advances all concurrent active bidirectional streams on
// connection index in round-robin so pipelined multi-frame Get_Object requests
// interleave without head-of-line blocking.
@(private = "file")
slot_service_streams :: proc(running: ^Cache_Quic_Running, index: int) {
	record := &running.records[index]
	slot := &running.slots[index]
	if !record.in_use {
		if slot.generation != 0 {
			slot_reset_for_new_connection(slot, 0)
		}
		return
	}
	if slot.generation != record.generation {
		slot_reset_for_new_connection(slot, record.generation)
	}
	connection := &running.connections[index]
	if connection.state != .Connected {
		return
	}

	// Bounded round-robin passes per tick so all active streams read requests
	// and refill their QUIC send windows together without starving siblings.
	for _ in 0 ..< 16 {
		slot_attach_new_streams(slot, connection)
		any_progress := false
		for &st in slot.stream_states {
			if !st.in_use {
				continue
			}
			if slot_step_one_stream(running, slot, connection, &st) {
				any_progress = true
			}
		}
		if !any_progress {
			return
		}
	}
}

@(private = "file")
cache_quic_drain_sends :: proc(running: ^Cache_Quic_Running, now: u64) {
	datagram: [quic.MAX_DATAGRAM_SIZE]u8
	for {
		length, remote := quic.server_datagram_send(&running.quic_server, datagram[:], now)
		if length == 0 {
			return
		}
		_, _ = net.send_udp(running.socket, datagram[:length], quic_remote_to_endpoint(remote))
	}
}

@(private = "file")
cache_quic_worker :: proc(t: ^thread.Thread) {
	running := cast(^Cache_Quic_Running)t.data
	receive_buffer: [quic.DATAGRAM_LIMIT]u8
	answer_buffer: [quic.MAX_DATAGRAM_SIZE]u8
	released := make([]quic.Remote, running.max_connections)
	defer delete(released)

	for !sync.atomic_load(&running.stop) && !sync.atomic_load(&running.server.stop) {
		defer free_all(context.temp_allocator)
		now := cache_quic_now_us(running)
		deadline := quic.server_deadline(&running.quic_server)
		wait_duration := CACHE_QUIC_POLL_INTERVAL
		if deadline != quic.NO_DEADLINE {
			if deadline <= now {
				wait_duration = time.Millisecond
			} else {
				until := time.Duration(deadline - now) * time.Microsecond
				if until < wait_duration {
					wait_duration = max(until, time.Millisecond)
				}
			}
		}
		_ = net.set_option(running.socket, .Receive_Timeout, wait_duration)

		// Drain any incoming UDP datagrams (first one blocks up to wait_duration,
		// subsequent ones are polled non-blocking until EAGAIN/timeout).
		bytes_read, sender, recv_err := net.recv_udp(running.socket, receive_buffer[:])
		if recv_err == nil && bytes_read > 0 {
			now = cache_quic_now_us(running)
			if remote, remote_ok := endpoint_to_quic_remote(sender); remote_ok {
				outcome := quic.server_datagram_receive(&running.quic_server, receive_buffer[:bytes_read], remote, answer_buffer[:], now)
				if outcome.answer_length > 0 {
					_, _ = net.send_udp(running.socket, answer_buffer[:outcome.answer_length], sender)
				}
				if outcome.validate_remote && outcome.record >= 0 {
					quic.server_validation_confirmed(&running.quic_server, outcome.record, running.records[outcome.record].generation, true)
				}
			}
			// Drain additional queued datagrams immediately before sleeping again.
			_ = net.set_blocking(running.socket, false)
			for _ in 0 ..< 64 {
				more_read, more_sender, more_err := net.recv_udp(running.socket, receive_buffer[:])
				if more_err != nil || more_read <= 0 {
					break
				}
				now = cache_quic_now_us(running)
				if remote, remote_ok := endpoint_to_quic_remote(more_sender); remote_ok {
					outcome := quic.server_datagram_receive(&running.quic_server, receive_buffer[:more_read], remote, answer_buffer[:], now)
					if outcome.answer_length > 0 {
						_, _ = net.send_udp(running.socket, answer_buffer[:outcome.answer_length], more_sender)
					}
					if outcome.validate_remote && outcome.record >= 0 {
						quic.server_validation_confirmed(&running.quic_server, outcome.record, running.records[outcome.record].generation, true)
					}
				}
			}
			_ = net.set_blocking(running.socket, true)
		}

		now = cache_quic_now_us(running)
		for index in 0 ..< running.max_connections {
			slot_service_streams(running, index)
		}
		quic.server_time_passes(&running.quic_server, now)
		cache_quic_drain_sends(running, now)
		_ = quic.server_sweep(&running.quic_server, released)
		for index in 0 ..< running.max_connections {
			if !running.records[index].in_use && running.slots[index].generation != 0 {
				slot_reset_for_new_connection(&running.slots[index], 0)
			}
		}
	}
}

// cache_quic_start binds a UDP socket on endpoint and starts a background
// thread serving the object_cache v2 protocol over QUIC with ALPN
// object_cache.APPLICATION_PROTOCOL.
cache_quic_start :: proc(
	server: ^Cache_Server,
	endpoint: net.Endpoint,
	private_key: [quic.ED25519_KEY_SIZE]u8,
	max_connections: int = CACHE_QUIC_DEFAULT_CONNECTIONS,
) -> (running: ^Cache_Quic_Running, err_text: string) {
	if server == nil {
		return nil, "cache server is nil"
	}
	if max_connections < 1 || max_connections > CACHE_QUIC_MAX_CONNECTIONS {
		return nil, "QUIC connection capacity is out of range"
	}
	public_key, pub_ok := cache_quic_public_key_of_private(private_key)
	if !pub_ok {
		return nil, "Ed25519 private key is not accepted"
	}
	socket, bind_err := net.make_bound_udp_socket(endpoint.address, endpoint.port)
	if bind_err != nil {
		return nil, "cannot bind UDP socket"
	}
	bound, bound_err := net.bound_endpoint(socket)
	if bound_err != nil {
		net.close(socket)
		return nil, "cannot inspect bound UDP endpoint"
	}

	running = new(Cache_Quic_Running)
	running.server = server
	running.socket = socket
	running.bound_endpoint = bound
	running.public_key = public_key
	running.max_connections = max_connections
	running.cryptography = cache_quic_cryptography()
	running.start_tick = time.tick_now()

	seed: [random.SEED_SIZE]u8
	crypto.rand_bytes(seed[:])
	random.generator_seed(&running.generator, &seed, .Processor)

	running.connections = make([]quic.Connection, max_connections)
	running.records = make([]quic.Server_Record, max_connections)
	running.streams = make([]quic.Stream, max_connections * CACHE_QUIC_STREAMS_PER_CONNECTION)
	running.slots = make([]Cache_Quic_Client_Slot, max_connections)
	for &slot in running.slots {
		cache_connection_init(&slot.conn)
	}

	cfg := quic.Connection_Configuration {
		idle_timeout_milliseconds = CACHE_QUIC_IDLE_TIMEOUT_MS,
		tls = {
			role                = .Server,
			least_seed_strength = .Processor,
			server_private_key  = private_key,
		},
	}
	defer crypto_compat.zero_explicit(&cfg.tls.server_private_key, size_of(cfg.tls.server_private_key))
	cfg.tls.application_protocol_length = copy(cfg.tls.application_protocol[:], object_cache.APPLICATION_PROTOCOL)

	limits := quic.server_limits_of_one_address(max_connections)
	init_error: errors.Error_Record
	if !quic.server_init(
		&running.quic_server,
		running.connections,
		running.records,
		running.streams,
		&cfg,
		&running.cryptography,
		&running.generator,
		limits,
		&init_error,
	) {
		cache_quic_free_resources(running)
		return nil, "quic.server_init failed"
	}

	running.worker = thread.create(cache_quic_worker)
	if running.worker == nil {
		cache_quic_free_resources(running)
		return nil, "cannot create QUIC worker thread"
	}
	running.worker.data = running
	thread.start(running.worker)
	return running, ""
}

@(private = "file")
cache_quic_free_resources :: proc(running: ^Cache_Quic_Running) {
	if running == nil {
		return
	}
	net.close(running.socket)
	for &slot in running.slots {
		for &st in slot.stream_states {
			delete(st.request_buf)
			delete(st.response_buf)
		}
		cache_connection_destroy(&slot.conn)
	}
	crypto_compat.zero_explicit(&running.quic_server, size_of(running.quic_server))
	delete(running.slots)
	delete(running.streams)
	delete(running.records)
	delete(running.connections)
	free(running)
}

// cache_quic_stop stops the QUIC listener thread, aborts any unfinished
// uploads, closes the UDP socket, and frees memory.
cache_quic_stop :: proc(running: ^Cache_Quic_Running) {
	if running == nil {
		return
	}
	sync.atomic_store(&running.stop, true)
	if running.worker != nil {
		thread.join(running.worker)
		thread.destroy(running.worker)
		running.worker = nil
	}
	cache_quic_free_resources(running)
}
