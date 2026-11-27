// Freestanding single-stream QUIC object-cache v2 frame fetcher for the
// delegated disk_processes service (src/md/features/script_fonts.md).
//
// Speaks QUIC over UDP (ALPN = "modus-object-cache", pinned 32-byte Ed25519
// server public key) through a caller-supplied UDP datagram transport callback.
// Fetches one 1 MiB Get_Object Blob frame at a time into its fixed response
// buffer, checks monotonic .Busy progress within a single per-frame deadline,
// and aborts immediately when the caller signals cancellation (e.g. a Cancel
// command from root).
//
// Allocates no memory and calls no kernel operation. Must live in static BSS
// or a mapped buffer, never on a stack.
package disk_processes_core

import "modus:contract/blake3"
import "modus:contract/errors"
import "modus:contract/font_outlines"
import "modus:contract/object_cache"
import "modus:quic"
import "modus:random"

// Plan value: QUIC idle timeout in milliseconds for object-cache fetches.
CACHE_FETCHER_IDLE_TIMEOUT_MS :: 30_000
// Plan value: overall per-frame fetch timeout in microseconds (15 seconds).
CACHE_FETCHER_EXCHANGE_TIMEOUT_US :: u64(15_000_000)
// Computed: maximum number of 1 MiB Bao frames in a valid script font set
// (SCRIPT_FONTS_BYTES_LIMIT = 64 MiB -> 64 frames).
CACHE_FETCHER_MAX_SCRIPT_FONTS_FRAMES :: (font_outlines.SCRIPT_FONTS_BYTES_LIMIT + object_cache.FRAME_PAYLOAD_BYTES - 1) / object_cache.FRAME_PAYLOAD_BYTES
// Plan value: maximum monotonic .Busy retries per frame while the cache builds
// an outboard (at most one retry per frame of a 64 MiB script font set).
CACHE_FETCHER_BUSY_LIMIT :: int(CACHE_FETCHER_MAX_SCRIPT_FONTS_FRAMES)

// UDP datagram and cancellation seam provided by the shell or host tests.
Cache_Quic_Transport :: struct {
	send:      proc "contextless" (bytes: []u8, user_data: rawptr) -> bool,
	recv:      proc "contextless" (buffer: []u8, deadline_us: u64, user_data: rawptr) -> (length: int, ok: bool),
	now_us:    proc "contextless" (user_data: rawptr) -> u64,
	cancelled: proc "contextless" (user_data: rawptr) -> bool,
	user_data: rawptr,
}

// Complete zero-allocation state of the single-stream QUIC object-cache fetcher.
Cache_Quic_Fetcher :: struct {
	configured:          bool,
	connected:           bool,
	server_public_key:   [object_cache.PUBLIC_KEY_SIZE]u8,
	cryptography:        ^quic.Cryptography,
	generator:           ^random.Generator,
	transport:           Cache_Quic_Transport,
	exchange_timeout_us: u64,
	connection:          quic.Connection,
	streams:             [1]quic.Stream,
	request_buf:         [object_cache.FRAME_HEADER_SIZE + object_cache.GET_OBJECT_BODY_SIZE]u8,
	response_buf:        [object_cache.FRAME_HEADER_SIZE + object_cache.MAX_RESPONSE_BODY_BYTES]u8,
	datagram_buf:        [quic.DATAGRAM_LIMIT]u8,
}

// saturating_add_u64 adds two microsecond timestamps without wrapping past max(u64).
saturating_add_u64 :: proc "contextless" (a, b: u64) -> u64 {
	if a > max(u64) - b {
		return max(u64)
	}
	return a + b
}

// fetcher_reset_connection drops the QUIC connection and stream slot cleanly so
// neither a .Closing state nor an open stream slot leaks into a later exchange.
@(private = "file")
fetcher_reset_connection :: proc "contextless" (fetcher: ^Cache_Quic_Fetcher) {
	fetcher.connection = {}
	fetcher.streams = {}
	fetcher.connected = false
}

// cache_quic_fetcher_init configures fetcher with a pinned Ed25519 server
// public key, QUIC cryptography table, PRNG, and UDP datagram callbacks.
cache_quic_fetcher_init :: proc "contextless" (
	fetcher: ^Cache_Quic_Fetcher,
	server_public_key: [object_cache.PUBLIC_KEY_SIZE]u8,
	cryptography: ^quic.Cryptography,
	generator: ^random.Generator,
	transport: Cache_Quic_Transport,
	exchange_timeout_us: u64 = CACHE_FETCHER_EXCHANGE_TIMEOUT_US,
) -> bool {
	if fetcher == nil || cryptography == nil || generator == nil ||
	   transport.send == nil || transport.recv == nil || transport.now_us == nil {
		return false
	}
	key_copy := server_public_key
	if object_cache.bytes_all_zero(key_copy[:]) {
		return false
	}
	fetcher_reset_connection(fetcher)
	fetcher.configured = true
	fetcher.server_public_key = server_public_key
	fetcher.cryptography = cryptography
	fetcher.generator = generator
	fetcher.transport = transport
	fetcher.exchange_timeout_us = exchange_timeout_us > 0 ? exchange_timeout_us : CACHE_FETCHER_EXCHANGE_TIMEOUT_US
	return true
}

// cache_quic_fetcher_close clears connection and configuration state. When
// send_close is false (the default for Cancel and load teardown), it never
// transmits on the transport so teardown cannot block on a stalled ring.
cache_quic_fetcher_close :: proc "contextless" (fetcher: ^Cache_Quic_Fetcher, send_close: bool = false) {
	if fetcher == nil {
		return
	}
	if send_close && !fetcher_cancelled(fetcher) &&
	   fetcher.connection.state == .Connected &&
	   fetcher.transport.now_us != nil && fetcher.transport.send != nil {
		now := fetcher.transport.now_us(fetcher.transport.user_data)
		quic.connection_close(&fetcher.connection, 0, now)
		_ = fetcher_drain_sends(fetcher, now)
	}
	fetcher_reset_connection(fetcher)
	fetcher.configured = false
}

@(private = "file")
fetcher_cancelled :: proc "contextless" (fetcher: ^Cache_Quic_Fetcher) -> bool {
	return fetcher.transport.cancelled != nil && fetcher.transport.cancelled(fetcher.transport.user_data)
}

@(private = "file")
fetcher_drain_sends :: proc "contextless" (fetcher: ^Cache_Quic_Fetcher, now: u64) -> bool {
	for {
		length := quic.connection_datagram_send(&fetcher.connection, fetcher.datagram_buf[:quic.MAX_DATAGRAM_SIZE], now)
		if length == 0 {
			return true
		}
		if !fetcher.transport.send(fetcher.datagram_buf[:length], fetcher.transport.user_data) {
			return false
		}
	}
}

@(private = "file")
fetcher_step_io :: proc "contextless" (fetcher: ^Cache_Quic_Fetcher, deadline: u64) -> bool {
	if fetcher_cancelled(fetcher) {
		return false
	}
	now := fetcher.transport.now_us(fetcher.transport.user_data)
	if !fetcher_drain_sends(fetcher, now) {
		return false
	}
	if now >= deadline {
		return false
	}
	conn_deadline := quic.connection_deadline(&fetcher.connection)
	wait_until := deadline
	if conn_deadline != quic.NO_DEADLINE && conn_deadline < wait_until {
		wait_until = conn_deadline
	}
	received, ok := fetcher.transport.recv(fetcher.datagram_buf[:], wait_until, fetcher.transport.user_data)
	if fetcher_cancelled(fetcher) {
		return false
	}
	now = fetcher.transport.now_us(fetcher.transport.user_data)
	if ok && received > 0 {
		if received > len(fetcher.datagram_buf) {
			return false
		}
		err: errors.Error_Record
		quic.connection_datagram_receive(&fetcher.connection, fetcher.datagram_buf[:received], now, &err)
	}
	quic.connection_time_passes(&fetcher.connection, now)
	if !fetcher_drain_sends(fetcher, now) {
		return false
	}
	return true
}

@(private = "file")
fetcher_connect :: proc "contextless" (fetcher: ^Cache_Quic_Fetcher, deadline: u64) -> Cache_Answer_Kind {
	if !fetcher.configured {
		return .Not_Configured
	}
	if fetcher.connected && fetcher.connection.state == .Connected {
		return .Ok
	}
	fetcher_reset_connection(fetcher)

	cfg := quic.Connection_Configuration {
		idle_timeout_milliseconds = CACHE_FETCHER_IDLE_TIMEOUT_MS,
		tls = {
			role                = .Client,
			least_seed_strength = .Processor,
			server_public_key   = fetcher.server_public_key,
		},
	}
	cfg.tls.application_protocol_length = copy(cfg.tls.application_protocol[:], object_cache.APPLICATION_PROTOCOL)

	now := fetcher.transport.now_us(fetcher.transport.user_data)
	start_err: errors.Error_Record
	if !quic.connection_start_client(
		&fetcher.connection,
		fetcher.streams[:],
		&cfg,
		fetcher.cryptography,
		fetcher.generator,
		now,
		&start_err,
	) {
		fetcher_reset_connection(fetcher)
		return .Network_Failed
	}

	for {
		if fetcher_cancelled(fetcher) {
			fetcher_reset_connection(fetcher)
			return .Network_Failed
		}
		if fetcher.connection.state == .Connected && fetcher.connection.peer_parameters_applied {
			fetcher.connected = true
			return .Ok
		}
		if fetcher.connection.state == .Closing || fetcher.connection.state == .Draining || fetcher.connection.state == .Closed {
			_ = fetcher_drain_sends(fetcher, fetcher.transport.now_us(fetcher.transport.user_data))
			bad_key := fetcher.connection.close_error_code == u64(quic.CRYPTO_ERROR_BASE) + u64(quic.Alert.Bad_Certificate) ||
			           fetcher.connection.tls.alert == .Bad_Certificate
			fetcher_reset_connection(fetcher)
			if bad_key {
				return .Bad_Server_Key
			}
			return .Network_Failed
		}
		if fetcher.transport.now_us(fetcher.transport.user_data) >= deadline {
			fetcher_reset_connection(fetcher)
			return .Network_Failed
		}
		if !fetcher_step_io(fetcher, deadline) {
			fetcher_reset_connection(fetcher)
			return .Network_Failed
		}
	}
}

@(private = "file")
fetcher_exchange_once :: proc "contextless" (
	fetcher: ^Cache_Quic_Fetcher,
	request: ^object_cache.Cache_Request,
	deadline: u64,
) -> (response: object_cache.Cache_Response, kind: Cache_Answer_Kind) {
	if !fetcher.configured {
		return {}, .Not_Configured
	}
	req_len, enc_refusal := object_cache.encode_request(request, fetcher.request_buf[:])
	if enc_refusal != .None {
		return {}, .Bad_Response
	}
	if !fetcher.connected || fetcher.connection.state != .Connected {
		if conn_kind := fetcher_connect(fetcher, deadline); conn_kind != .Ok {
			return {}, conn_kind
		}
	}

	stream_id: u64
	opened := false
	for !opened {
		if fetcher_cancelled(fetcher) {
			fetcher_reset_connection(fetcher)
			return {}, .Network_Failed
		}
		if fetcher.connection.state != .Connected {
			fetcher_reset_connection(fetcher)
			return {}, .Network_Failed
		}
		stream_id, opened = quic.stream_open(&fetcher.connection)
		if opened {
			break
		}
		if fetcher.transport.now_us(fetcher.transport.user_data) >= deadline {
			fetcher_reset_connection(fetcher)
			return {}, .Network_Failed
		}
		if !fetcher_step_io(fetcher, deadline) {
			fetcher_reset_connection(fetcher)
			return {}, .Network_Failed
		}
	}

	sent := 0
	recv_len := 0
	expected_len := object_cache.FRAME_HEADER_SIZE
	header_parsed := false
	peer_finished := false

	for {
		if fetcher_cancelled(fetcher) {
			fetcher_reset_connection(fetcher)
			return {}, .Network_Failed
		}
		if fetcher.connection.state != .Connected {
			fetcher_reset_connection(fetcher)
			return {}, .Network_Failed
		}
		if sent < req_len {
			wrote := quic.stream_write(&fetcher.connection, stream_id, fetcher.request_buf[sent:req_len], true)
			sent += wrote
		}

		for !peer_finished {
			if !header_parsed {
				need := object_cache.FRAME_HEADER_SIZE - recv_len
				n, fin, rst := quic.stream_read(&fetcher.connection, stream_id, fetcher.response_buf[recv_len:recv_len + need])
				if rst {
					fetcher_reset_connection(fetcher)
					return {}, .Bad_Response
				}
				recv_len += n
				if fin {
					peer_finished = true
				}
				if recv_len == object_cache.FRAME_HEADER_SIZE {
					_, _, body_len, hdr_refusal := object_cache.inspect_response_header(fetcher.response_buf[:object_cache.FRAME_HEADER_SIZE])
					if hdr_refusal != .None {
						quic.stream_reset(&fetcher.connection, stream_id, 1)
						quic.stream_stop_sending(&fetcher.connection, stream_id, 1)
						fetcher_reset_connection(fetcher)
						return {}, .Bad_Response
					}
					expected_len = object_cache.FRAME_HEADER_SIZE + body_len
					header_parsed = true
				}
				if n == 0 {
					break
				}
			} else if recv_len < expected_len {
				n, fin, rst := quic.stream_read(&fetcher.connection, stream_id, fetcher.response_buf[recv_len:expected_len])
				if rst {
					fetcher_reset_connection(fetcher)
					return {}, .Bad_Response
				}
				recv_len += n
				if fin {
					peer_finished = true
				}
				if n == 0 {
					break
				}
			} else {
				extra: [1]u8
				n, fin, rst := quic.stream_read(&fetcher.connection, stream_id, extra[:])
				if rst || n > 0 {
					fetcher_reset_connection(fetcher)
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
		if peer_finished {
			fetcher_reset_connection(fetcher)
			return {}, .Bad_Response
		}
		if fetcher.transport.now_us(fetcher.transport.user_data) >= deadline {
			fetcher_reset_connection(fetcher)
			return {}, .Network_Failed
		}
		if !fetcher_step_io(fetcher, deadline) {
			fetcher_reset_connection(fetcher)
			return {}, .Network_Failed
		}
	}

	if !fetcher_drain_sends(fetcher, fetcher.transport.now_us(fetcher.transport.user_data)) {
		fetcher_reset_connection(fetcher)
		return {}, .Network_Failed
	}

	decoded, dec_refusal := object_cache.decode_response(fetcher.response_buf[:expected_len])
	if dec_refusal != .None || decoded.request_kind != request.kind {
		fetcher_reset_connection(fetcher)
		return {}, .Bad_Response
	}
	return decoded, .Ok
}

// cache_quic_fetcher_get_frame fetches one 1 MiB Blob frame at offset for
// object_hash, retrying monotonic .Busy responses within a single overall
// per-frame deadline and script-font frame count bound, and returns a
// Cache_Frame_Answer whose proof and payload slices borrow from
// fetcher.response_buf until the next fetch call.
cache_quic_fetcher_get_frame :: proc "contextless" (
	fetcher: ^Cache_Quic_Fetcher,
	object_hash: blake3.Hash,
	offset: u64,
) -> (answer: Cache_Frame_Answer) {
	if fetcher == nil || !fetcher.configured {
		return {kind = .Not_Configured}
	}
	req := object_cache.Cache_Request {
		kind        = .Get_Object,
		object_hash = object_hash,
		object_kind = .Blob,
		offset      = offset,
	}
	frame_deadline := saturating_add_u64(fetcher.transport.now_us(fetcher.transport.user_data), fetcher.exchange_timeout_us)
	last_built: u64 = 0
	expected_frames: u64 = 0
	for _ in 0 ..< CACHE_FETCHER_BUSY_LIMIT {
		if fetcher_cancelled(fetcher) {
			fetcher_reset_connection(fetcher)
			return {kind = .Network_Failed}
		}
		if fetcher.transport.now_us(fetcher.transport.user_data) >= frame_deadline {
			fetcher_reset_connection(fetcher)
			return {kind = .Network_Failed}
		}
		resp, kind := fetcher_exchange_once(fetcher, &req, frame_deadline)
		if kind != .Ok {
			return {kind = kind}
		}
		if resp.status == .Busy {
			if resp.frame_count == 0 || resp.frame_count > CACHE_FETCHER_MAX_SCRIPT_FONTS_FRAMES || resp.frames_built >= resp.frame_count {
				fetcher_reset_connection(fetcher)
				return {kind = .Bad_Response}
			}
			if expected_frames == 0 {
				expected_frames = resp.frame_count
			} else if resp.frame_count != expected_frames || resp.frames_built <= last_built {
				fetcher_reset_connection(fetcher)
				return {kind = .Bad_Response}
			}
			last_built = resp.frames_built
			continue
		}
		if resp.status == .Not_Found {
			return {kind = .Not_Found}
		}
		if resp.status != .Ok {
			fetcher_reset_connection(fetcher)
			return {kind = .Bad_Response}
		}
		return {
			kind        = .Ok,
			object_kind = resp.object_kind,
			object_size = resp.object_size,
			offset      = resp.offset,
			proof       = resp.proof,
			payload     = resp.payload,
		}
	}
	fetcher_reset_connection(fetcher)
	return {kind = .Bad_Response}
}
