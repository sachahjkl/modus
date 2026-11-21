// A QUIC echo server (docs/QUIC.md, section 6): QUIC in the process
// (src/library/modus/quic), over a datagram endpoint with a listen grant of UDP. A
// client opens up to STREAMS_PER_CONNECTION streams at one time; on each
// one the server writes back each byte that it reads, then ends the stream
// after the client ended it, or resets it after the client reset it.
//
// What it can reach comes from its grants only:
//   a datagram endpoint with a listen grant: the UDP port 4433, and the
//       remotes that send a datagram of 1200 bytes to it;
//   the module cryptography, through its import slots.
//
// The key of the server: an Ed25519 key that this process makes at its
// start from its own generator (fill_for_a_key, the strength "processor" at
// least). Its public key goes on the log and in the window: a client pins
// it. The private key stays in the memory of this process; a new start
// makes a new key. A seed weaker than "processor" makes no key: the
// process says so in its window, and listens on nothing.
//
// **What it is for.** It is the test bench of the QUIC library on a real
// network path: the handshake of TLS 1.3, streams in both directions, Retry,
// the budgets of work against a hostile client, and the idle end. Its echo
// has no other use: the peer of the modus tool writes a pattern on each
// stream and checks each byte that comes back. The service `remote` uses
// the same library and the same limits.
//
// **Start**: `start("quic_echo")` in the console, or the bar of the
// desktop. A client needs the public key from the log or the window.
//
// **Grants**, as the root service gives them:
//
// - **Network**: a listen grant of UDP on port 4433. The network service
//   admits a new remote only on a datagram of 1200 bytes or more, and holds
//   the limit of three times the bytes that came from it.
//
// It needs no other grant: the cryptography is the module `cryptography`,
// which the loader gives through the imports of this process.
//
// **What a reader sees**: a window with the key and the counts of the
// server. The log has "quic_echo: the public key of this server: ...",
// "quic_echo: listening on the UDP port 4433, ...", one line for each
// connection that starts and ends, a line on each idle end that says if it
// held its bound, and the counters of the server when they change: the
// connections accepted and ended, the Retries, the Initials refused by each
// limit, the datagrams over the budget.
//
// **What it does not prove**: the client is the peer of the modus tool,
// not a QUIC stack of another project. 0-RTT and the migration of a
// connection are not built (docs/QUIC.md, section 10).
//
// main.odin: the endpoint, the server and the loop. draw.odin: the window.
package quic_echo

import "modus:contract/errors"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:quic"
import "modus:quic_server"
import "modus:random"
import "modus:system"

// 16 QUIC connections of about 85 KiB each, 4 streams of about 130 KiB for
// each, and an echo buffer of 16 KiB for each stream: about 2770 pages, in
// one mapping of the process (docs/QUIC.md, section 6): 3667 pages. And
// the glyph memory of the copy of the text rendering of the drawing
// module, which draws its text: 354 pages (display.TEXT_MEMORY_PAGES).
// 3667 + 354 = 4021.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 4021, processes = 1, threads = 1, window_width = WIDTH, window_height = HEIGHT}

foreign _ {
	seal_with_chacha20_poly1305 :: proc "c" (key, nonce, additional, text: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	open_with_chacha20_poly1305 :: proc "c" (key, nonce, additional, sealed: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	seal_with_aes_128_gcm :: proc "c" (key, nonce, additional, text: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	open_with_aes_128_gcm :: proc "c" (key, nonce, additional, sealed: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	sha256 :: proc "c" (text: ^string, result: ^[]u8) -> i64 ---
	hmac_sha256 :: proc "c" (key, text: ^string, result: ^[]u8) -> i64 ---
	hkdf_sha256_extract :: proc "c" (salt, input: ^string, result: ^[]u8) -> i64 ---
	hkdf_sha256_expand :: proc "c" (key, info: ^string, length: value_kinds.Size_In_Bytes, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	x25519 :: proc "c" (scalar, point: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	ed25519_public_key :: proc "c" (secret: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	ed25519_sign :: proc "c" (secret, message: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	ed25519_verify :: proc "c" (public, message, signature: ^string, error: ^errors.Error_Record) -> i64 ---
	header_protection_mask_with_aes_128 :: proc "c" (key, sample: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	header_protection_mask_with_chacha20 :: proc "c" (key, sample: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
}

CAPACITY :: 16 // Connections at one time.
STREAMS_PER_CONNECTION :: 4 // The streams that one client may open at one time.
// The bytes that one stream read and did not write back yet: the echo
// writes them back before it reads more.
ECHO_BUFFER_SIZE :: 16384
// The memory of the connections, of their streams and of their echo: one
// mapping of this process, never a stack.
CONNECTION_BYTES :: CAPACITY * size_of(quic.Connection)
STREAM_BYTES :: CAPACITY * STREAMS_PER_CONNECTION * size_of(quic.Stream)
ECHO_BYTES :: CAPACITY * STREAMS_PER_CONNECTION * ECHO_BUFFER_SIZE
TABLE_PAGES :: (CONNECTION_BYTES + STREAM_BYTES + ECHO_BYTES + system.PAGE_SIZE - 1) / system.PAGE_SIZE
APPLICATION_PROTOCOL :: "kernel-remote"
IDLE_TIMEOUT_MILLISECONDS :: 30_000

RECEIVE_PLACES :: 96 // Places 0 to 95: datagrams that arrive. The others: datagrams to send.
#assert(CAPACITY <= quic_server.MAX_CAPACITY)

LOG_LIMIT :: 50 // Lines of connections in one second at most: a client that opens many must not fill the log limit of the process.

cryptography := quic.Cryptography {
	seal_with_aes_128_gcm                = seal_with_aes_128_gcm,
	open_with_aes_128_gcm                = open_with_aes_128_gcm,
	seal_with_chacha20_poly1305          = seal_with_chacha20_poly1305,
	open_with_chacha20_poly1305          = open_with_chacha20_poly1305,
	hkdf_sha256_extract                  = hkdf_sha256_extract,
	hkdf_sha256_expand                   = hkdf_sha256_expand,
	header_protection_mask_with_aes_128  = header_protection_mask_with_aes_128,
	header_protection_mask_with_chacha20 = header_protection_mask_with_chacha20,
	sha256                               = sha256,
	hmac_sha256                          = hmac_sha256,
	x25519                               = x25519,
	ed25519_public_key                   = ed25519_public_key,
	ed25519_sign                         = ed25519_sign,
	ed25519_verify                       = ed25519_verify,
}

process_generator: random.Generator
server: quic.Server
records: [CAPACITY]quic.Server_Record
connections: []quic.Connection
streams: []quic.Stream
echo_buffers: [][ECHO_BUFFER_SIZE]u8
public_key: [32]u8
weak_seed: bool // The seed is weaker than "processor": no key, no endpoint.
listen_port: u16

// The echo of one stream: the bytes read and not yet written back.
Stream_Echo :: struct {
	active:         bool,
	identifier:     u64, // The stream of this echo: the stream record of the same place of the connection.
	start, end:     int,
	finished:       bool,
	finish_written: bool,
}

// The echo of each record.
Echo :: struct {
	generation: u64, // The generation of the record that this echo belongs to.
	logged:     bool,
	streams:    [STREAMS_PER_CONNECTION]Stream_Echo,
}
echoes: [CAPACITY]Echo

quic_endpoint: quic_server.Endpoint
log_budget := quic_server.Log_Budget{limit = LOG_LIMIT}
counters_logged: quic.Server_Counters
sends_refused_logged: u64
counters_second: u64

fail :: proc "contextless" (text: string) -> ! {
	system.log_fact(.Info, Start_Failed{cause = value_kinds.text_field(text, CAUSE_FIELD_BYTES)})
	system.stop(.Failed)
}

held_overflow_fail :: proc "contextless" () {
	fail("the held commands passed their bound")
}

now_microseconds :: proc "contextless" () -> u64 {
	return system.nanoseconds() / 1000
}

// log_allowed says if one more line of a connection goes on the log in this
// second.
log_allowed :: proc "contextless" () -> bool {
	return quic_server.log_allowed(&log_budget, system.time())
}

end_reason :: proc "contextless" (connection: ^quic.Connection) -> string {
	switch {
	case connection.closed_by_handshake_timeout:
		return "the handshake deadline"
	case connection.closed_by_idle_timeout:
		return "the idle timeout"
	case connection.closed_by_peer:
		return "closed by the client"
	}
	return "closed by this server"
}

// idle_end_log writes how long a connection that ended by its idle timeout
// received nothing, in time of the machine, against its bound: at least
// its idle timeout. The line also gives its bound (the larger of the idle
// timeout and three probe timeouts with no backoff) and how late after it
// the end came: the process learns that the deadline passed when its wait
// ends, and how late a busy or slow machine wakes it depends on the host,
// so no verdict checks that side. A test reads the verdict; the numbers
// are on the line.
idle_end_log :: proc "contextless" (connection: ^quic.Connection, remote: quic.Remote) {
	silence := (connection.ended_at - min(connection.last_activity, connection.ended_at)) / 1000
	idle_timeout := connection.idle_timeout / 1000
	bound := quic.connection_idle_bound(connection) / 1000
	held := silence >= idle_timeout
	after_bound := silence - min(silence, bound)
	if held {
		system.log_fact(.Info, Idle_End_Held{silence = value_kinds.Time_In_Milliseconds(silence), idle_timeout = value_kinds.Time_In_Milliseconds(idle_timeout), bound = value_kinds.Time_In_Milliseconds(bound), after_bound = value_kinds.Time_In_Milliseconds(after_bound), peer = peer_field(remote)})
	} else {
		system.log_fact(.Info, Idle_End_Not_Held{silence = value_kinds.Time_In_Milliseconds(silence), idle_timeout = value_kinds.Time_In_Milliseconds(idle_timeout), bound = value_kinds.Time_In_Milliseconds(bound), after_bound = value_kinds.Time_In_Milliseconds(after_bound), peer = peer_field(remote)})
	}
}

// printable_text copies the bytes of a text of the network into place,
// each byte that is not printable ASCII as '?': a log line stays one line.
printable_text :: proc "contextless" (place: []u8, bytes: []u8) -> string {
	count := min(len(place), len(bytes))
	for index in 0 ..< count {
		character := bytes[index]
		place[index] = character >= 0x20 && character < 0x7F ? character : '?'
	}
	return string(place[:count])
}

// echo_work writes back what each connection read, and logs each new
// connection and each end.
echo_work :: proc "contextless" () {
	for record, place in records {
		if !record.in_use {
			continue
		}
		echo := &echoes[place]
		if echo.generation != record.generation {
			echo^ = {generation = record.generation}
			if log_allowed() {
				system.log_fact(.Info, Connection_Arrived{peer = peer_field(record.remote)})
			}
		}
		connection := &connections[place]
		// Each stream is read to its end, or to the reset of the client: a
		// stream record is freed only when the application read that end
		// (stream_read), so a stream left unread would keep its record, and
		// the client would get no stream in its place.
		for &stream, slot in connection.streams {
			stream_echo := &echo.streams[slot]
			if !stream.in_use {
				stream_echo.active = false
				continue
			}
			if !stream_echo.active || stream_echo.identifier != stream.identifier {
				stream_echo^ = {active = true, identifier = stream.identifier}
			}
			stream_echo_work(connection, stream_echo, echo_buffers[place * STREAMS_PER_CONNECTION + slot][:])
		}
		if connection.state == .Closed && !echo.logged {
			echo.logged = true
			if log_allowed() {
				text: [40]u8
				// The code, the frame type and the reason of the close tell
				// why a client of another stack failed: the code of a TLS
				// alert is 0x100 plus the alert.
				reason: [quic.CLOSE_REASON_KEPT]u8
				reason_text := printable_text(reason[:], connection.close_reason_of_peer[:connection.close_reason_of_peer_length])
				peer := value_kinds.text_field(quic_server.address_text(text[:], record.remote), 27)
				cause := value_kinds.text_field(end_reason(connection), 23)
				client_reason := value_kinds.text_field(reason_text, 54)
				code := value_kinds.Hexadecimal_Sixteen_Digits(connection.close_error_code)
				frame_type := value_kinds.Hexadecimal_Sixteen_Digits(connection.close_frame_type)
				bytes_in := value_kinds.Size_In_Bytes(connection.data_consumed_total)
				bytes_out := value_kinds.Size_In_Bytes(connection.data_sent_total)
				round_trip := value_kinds.Time_In_Microseconds(connection.smoothed_round_trip)
				if connection.close_is_application {
					system.log_fact(.Info, Connection_Ended_By_Application{code = code, frame_type = frame_type, bytes_in = bytes_in, bytes_out = bytes_out, round_trip = round_trip, peer = peer, end_cause = cause, client_reason = client_reason})
				} else {
					system.log_fact(.Info, Connection_Ended{code = code, frame_type = frame_type, bytes_in = bytes_in, bytes_out = bytes_out, round_trip = round_trip, peer = peer, end_cause = cause, client_reason = client_reason})
				}
				if connection.closed_by_idle_timeout {
					idle_end_log(connection, record.remote)
				}
			}
		}
	}
}

// stream_echo_work writes back what one stream read, then its end; a
// stream that the client reset is reset with the same code.
stream_echo_work :: proc "contextless" (connection: ^quic.Connection, stream_echo: ^Stream_Echo, pending: []u8) {
	for {
		if stream_echo.start < stream_echo.end {
			stream_echo.start += quic.stream_write(connection, stream_echo.identifier, pending[stream_echo.start:stream_echo.end], false)
			if stream_echo.start < stream_echo.end {
				return
			}
		}
		stream_echo.start, stream_echo.end = 0, 0
		// The code of a reset of the client, before the read that can end
		// the stream.
		code: u64
		if stream := quic.stream_of(connection, stream_echo.identifier); stream != nil {
			code = stream.peer_reset_code
		}
		count, finished, reset := quic.stream_read(connection, stream_echo.identifier, pending)
		if reset {
			quic.stream_reset(connection, stream_echo.identifier, code)
			return
		}
		stream_echo.end = count
		stream_echo.finished = stream_echo.finished || finished
		if count == 0 {
			break
		}
	}
	if stream_echo.finished && stream_echo.start == stream_echo.end && !stream_echo.finish_written {
		quic.stream_write(connection, stream_echo.identifier, nil, true)
		stream_echo.finish_written = true
	}
}

// counters_log writes the counts of the server when they changed, once in
// a second at most: a flood is visible on the log in a few lines.
counters_log :: proc "contextless" () {
	second := system.time() / 1000
	if second == counters_second {
		return
	}
	counters := server.counters
	// The counts of each datagram change at each pass: they are in the
	// window, not on the log.
	counters.datagrams = counters_logged.datagrams
	counters.authenticity_checks = counters_logged.authenticity_checks
	if counters == counters_logged && quic_endpoint.sends_refused == sends_refused_logged {
		return
	}
	counters_second = second
	counters_logged = server.counters
	sends_refused_logged = quic_endpoint.sends_refused
	system.log_fact(.Info, Server_Counts{accepted = counters.accepted, ended = counters.ended, retries = counters.retries, tokens_refused = counters.tokens_refused + counters.tokens_expired, not_authentic = counters.not_authentic, too_small = counters.too_small, refused_by_limit = counters.refused_remote_limit + counters.refused_handshake_limit, refused_full = counters.refused_full})
	system.log_fact(.Info, Server_Budget_Counts{over_budget = counters.over_budget, over_address_budget = counters.over_address_budget, address_table_full = counters.address_table_full, tokens_used_again = counters.tokens_used_again, version_negotiations = counters.version_negotiations, sends_refused = quic_endpoint.sends_refused, last_send_status = u64(quic_endpoint.send_refusal_last)})
}

// key_make makes the Ed25519 key of this server from the generator of the
// process, with the strength "processor" at least. false: the seed is
// weaker; nothing is made.
key_make :: proc "contextless" (configuration: ^quic.Connection_Configuration) -> bool {
	error: errors.Error_Record
	if !random.fill_for_a_key(&process_generator, configuration.tls.server_private_key[:], .Processor, &error) {
		return false
	}
	secret := string(configuration.tls.server_private_key[:])
	result := public_key[:]
	if ed25519_public_key(&secret, &result, &error) != 32 {
		fail("the module cryptography refused to make the public key")
	}
	return true
}

// The entry of quic_echo: it makes its key, checks its grant, then runs the
// QUIC server until the machine stops.
//
// The entry, in order:
//
// 1. takes its random generator (with no seed it stops: `fail`) and opens
//    its window;
// 2. makes its Ed25519 key. With a seed under the strength "processor" it
//    writes "quic_echo: the random seed of this process is weak: ..." and
//    then only draws its window;
// 3. writes the public key on the log;
// 4. opens its endpoint and its datagram region, and asks the network
//    service for its grant; a grant that is not a listen grant of UDP stops
//    it;
// 5. maps the table of the connections and their streams, and starts the
//    QUIC server;
// 6. writes "quic_echo: listening on the UDP port 4433, ...".
//
// Then one loop runs for ever. Each pass gives the datagrams that arrived
// to the server, which echoes the bytes of each stream, and draws the
// window at most ten times in one second. It waits for a datagram, an event
// of the window, the next deadline of QUIC, or one second.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	if !random.generator_from_context(&process_generator, ctx) {
		fail("no random seed in the context")
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "quic_echo")
	if !ok {
		system.stop(.Failed)
	}
	configuration := quic.Connection_Configuration{idle_timeout_milliseconds = IDLE_TIMEOUT_MILLISECONDS}
	configuration.tls = {role = .Server, least_seed_strength = .Processor}
	configuration.tls.application_protocol_length = copy(configuration.tls.application_protocol[:], APPLICATION_PROTOCOL)
	if !key_make(&configuration) {
		// The rule on a weak seed: the process chooses what it
		// accepts, and a seed under it is an error that it shows.
		weak_seed = true
		system.log_fact(.Info, Seed_Weak{})
		for {
			draw(&window)
			display.wait(&window, system.time() + 1000)
			for event in display.next_event(&window) {
				_ = event
			}
		}
	}
	text: [64]u8
	system.log_fact(.Info, Public_Key_Made{public_key = value_kinds.text_field(quic_server.hex_text(text[:], public_key[:]), PUBLIC_KEY_FIELD_BYTES)})
	switch quic_server.endpoint_open(&quic_endpoint, ctx, RECEIVE_PLACES, CAPACITY) {
	case .None:
	case .No_Ring:
		fail("no endpoint: the process has no grant of the network")
	case .No_Region:
		fail("no datagram region")
	case .Info_Timeout, .Bad_Grant, .Bad_Config:
		fail("the grant is not a listen grant of UDP")
	}
	quic_endpoint.on_held_overflow = held_overflow_fail
	listen_port = quic_endpoint.listen_port
	// The connections and their echo: one mapping of this process.
	memory, memory_status := system.memory_create(TABLE_PAGES)
	table, table_status := system.memory_map(memory, {.Write})
	if memory_status != .Ok || table_status != .Ok {
		fail("no memory for the table of connections")
	}
	connections = ([^]quic.Connection)(table)[:CAPACITY]
	streams = ([^]quic.Stream)(rawptr(uintptr(table) + CONNECTION_BYTES))[:CAPACITY * STREAMS_PER_CONNECTION]
	echo_buffers = ([^][ECHO_BUFFER_SIZE]u8)(rawptr(uintptr(table) + CONNECTION_BYTES + STREAM_BYTES))[:CAPACITY * STREAMS_PER_CONNECTION]
	error: errors.Error_Record
	if !quic.server_init(&server, connections, records[:], streams, &configuration, &cryptography, &process_generator, quic.SERVER_LIMITS_DEFAULT, &error) {
		fail("the server refused its configuration")
	}
	// The server keeps its own copy of the key. A plain store of zeros to a
	// record that is not read again can be removed by the compiler.
	quic.secret_erase(&configuration.tls.server_private_key, size_of(configuration.tls.server_private_key))
	quic_server.endpoint_post_receives(&quic_endpoint)
	quic_server.endpoint_wake(&quic_endpoint)
	system.log_fact(.Info, Listening{listen_port = u64(listen_port), capacity = u64(CAPACITY), connection_size = value_kinds.Size_In_Kibibytes(size_of(quic.Connection) / 1024), streams = u64(STREAMS_PER_CONNECTION), stream_size = value_kinds.Size_In_Kibibytes(size_of(quic.Stream) / 1024)})

	arrived: [RECEIVE_PLACES]ring.Record
	last_draw: u64
	changed := true
	for {
		wait := system.wait_begin()
		count := quic_server.completions_drain(&quic_endpoint, &server, records[:], arrived[:])
		deadline := quic_server.exchange(&quic_endpoint, &server, records[:], arrived[:count], now_microseconds(), echo_work)
		counters_log()
		quic_server.endpoint_wake(&quic_endpoint)
		if count > 0 {
			changed = true
		}
		for event in display.next_event(&window) {
			_ = event
		}
		now := system.time()
		// This service never waits for the compositor: while the
		// compositor did not take the last picture, the picture waits,
		// and the wait below ends when the compositor has read.
		picture_waits := false
		if changed && now - last_draw >= 100 {
			if display.canvas_free(&window) {
				draw(&window)
				last_draw = now
				changed = false
			} else {
				picture_waits = true
			}
		}
		if !ring.empty(&quic_endpoint.datagrams.completions) {
			continue
		}
		system.wait_records(&wait, &quic_endpoint.datagrams.completions)
		display.wait_events(&wait, &window)
		limit := changed && !picture_waits ? last_draw + 100 : now + 1000
		if deadline != max(u64) {
			limit = min(limit, deadline / 1000 + 1)
		}
		system.wait_end(&wait, limit)
	}
}
