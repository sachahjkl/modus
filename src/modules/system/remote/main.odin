// The remote service: the calls of the host (docs/MODULE_CONTRACT.md,
// section 4, "A call from the host"; docs/QUIC.md, section 7).
//
// QUIC in the process (src/library/modus/quic), over a datagram endpoint with a
// listen grant of UDP on the port remote.LISTEN_PORT that admits the
// address of the host only (remote.HOST_ADDRESS): the network service drops
// a datagram of another address before this process sees it. Each call is
// one bidirectional stream: the request (a remote.Request header and the
// bytes of the call region), then the end of the stream; the answer (a
// remote.Answer header and the bytes of the result), then the end of the
// stream. A call that fails before its answer is reset with a code of
// remote.Stream_Error.
//
// The key of the service: an Ed25519 key that this process makes at its
// start from its own generator (fill_for_a_key, the strength "processor" at
// least). Its public key goes on the log and in the window: the host pins
// it. A new start makes a new key. A seed weaker than "processor" makes no
// key: the process says so, and listens on nothing. The public key is also
// the machine identity of this start toward paired machines (mesh.odin).
//
// The key of the client: the handshake asks each client for its own
// Ed25519 key, as a raw public key with its signature (mutual TLS 1.3), and
// takes it only when the client table that the root service writes has a
// row for it (remote.Client_Table, read-only). A key with no row is refused
// in the handshake (access_denied), with one line of the log, before any
// stream. Each connection is bound to its row; when the grant of the row
// ends (a revocation, a lock of the session of its principal), the open
// connection ends with the code Revoked.
//
// It holds a ring to the root service that serves Connect and Disconnect
// only, to the services that the root service names for it, each for one
// row of the client table: the root service gives that connection the
// principal of the row. It copies the bytes of a whole request in the call
// region of its connection to the service, makes the isolated call, and
// writes the call answer. It does not read the descriptions: the host
// encoded the call with them, and the service checks the call region. It
// trusts nothing in a request (remote.request_check).
//
// The window shows the public key, the counts of the calls and of the
// resets, the connections to services with their principals, and the last
// calls.
//
// **What it is for.** A process on the host calls an export of a service of
// the machine as the console calls it: the same descriptions, the same
// isolated call, the same error records. The tool of the project uses it
// to test and to measure a running machine from outside, with no screen:
//
// ```
// modustool call <the public key, 64 hexadecimal digits> "monitor.processes()"
// ```
//
// **Start**: `start("remote")` in the console, or the bar of the desktop.
// Read the public key in its window or on the log. Then allow the key of
// the client from a console that acts for the principal:
// `remote_allow("<the key of the client, 64 hexadecimal digits>")`.
//
// **Grants**, as the root service gives them:
//
// - **Network**: a listen grant of UDP on port 7100 for the address
//   10.0.2.2 only. The process refuses any other grant.
// - **Remote_Clients**: the client table, read-only: the key of each
//   client that a principal allowed, and that principal.
// - **Connect**: a ring to the root service for `Connect` and `Disconnect`,
//   to the services of its start grant set (`start_grant_sets`): compositor, date, debugger, inspect,
//   log, manual, monitor, settings and storage, each for one row of the
//   client table. A call to another service fails with the refusal of the
//   root service.
// - **Acts_For_Principal**: a service gives the caller what it holds for
//   all callers of the principal of the row, as it does for a console of
//   that principal.
//
// **What it proves**: a call from outside the machine passes the same
// checks as a call from inside, a lost datagram never runs a call two
// times, and a call acts only for a principal that allowed the key of its
// client.
package remote_service

import "base:intrinsics"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/remote"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:interface"
import "modus:quic"
import "modus:quic_server"
import "modus:random"
import "modus:contract/root_ring"
import "modus:system"

// 2 QUIC connections of about 85 KiB each, 8 streams of about 130 KiB for
// each, and a buffer of a request or an answer of about 64 KiB for each
// stream: about 820 pages, in one mapping of the process (docs/QUIC.md,
// section 7), and the call regions of its connections to services: 3067
// pages. And the glyph memory of the copy of the text rendering of the
// drawing module, which draws its text: 354 pages
// (display.TEXT_MEMORY_PAGES). 3067 + 354 = 3421.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 3421, processes = 1, threads = 1, window_width = WIDTH, window_height = HEIGHT}

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

// The QUIC connections and their calls: remote.CONNECTION_CAPACITY records,
// each with remote.CALLS_AT_ONCE stream records, and one buffer for each
// stream, which holds its request, then its answer.
CAPACITY :: remote.CONNECTION_CAPACITY
STREAMS_PER_CONNECTION :: remote.CALLS_AT_ONCE
CALL_COUNT :: CAPACITY * STREAMS_PER_CONNECTION
CALL_BUFFER_SIZE :: remote.ANSWER_LIMIT
#assert(remote.REQUEST_LIMIT <= CALL_BUFFER_SIZE)
// The memory of the connections, of their streams and of their buffers: one
// mapping of this process, never a stack.
CONNECTION_BYTES :: CAPACITY * size_of(quic.Connection)
STREAM_BYTES :: CALL_COUNT * size_of(quic.Stream)
BUFFER_BYTES :: CALL_COUNT * CALL_BUFFER_SIZE
TABLE_PAGES :: (CONNECTION_BYTES + STREAM_BYTES + BUFFER_BYTES + system.PAGE_SIZE - 1) / system.PAGE_SIZE
IDLE_TIMEOUT_MILLISECONDS :: 30_000

// The bounds of a call stream, in milliseconds of the machine. Each one
// starts again at each phase of the call (Call.phase_started_at), and the
// wait of the loop ends at the nearest one (calls_deadline).
// A request must be whole (its last byte and the end of its stream) this
// long after its stream came; else the stream is reset with Timeout.
REQUEST_TIME_LIMIT :: 10_000
// The host must take the whole answer (each byte and the end acknowledged)
// this long after the call ended; else the stream is reset with Timeout.
ANSWER_TIME_LIMIT :: 10_000
// After this side reset a stream, the host must end its own direction this
// long after; else the connection ends (CONNECTION_CLOSE, Timeout): a
// stream record that the host never ends would hold one call of the 8.
RELEASE_TIME_LIMIT :: 10_000
// An isolated call blocks the QUIC of this process. After a call that took
// SLOW_CALL_MILLISECONDS or more, the next call waits
// EXCHANGE_AFTER_SLOW_CALL_MILLISECONDS, in which the loop only moves
// datagrams: a handshake of a second connection, or the next flight of a
// stream, goes as far as the round trips of that time allow. On the test
// network a round trip is under 1 ms. A call of 5 s then waits 1 % more at
// most; a fast call adds no wait.
SLOW_CALL_MILLISECONDS :: 100
EXCHANGE_AFTER_SLOW_CALL_MILLISECONDS :: 50

RECEIVE_PLACES :: 64 // Places 0 to 63: datagrams that arrive. The others: datagrams to send.
#assert(CAPACITY <= quic_server.MAX_CAPACITY)

CALL_LIMIT :: 5000 // Milliseconds: an isolated call that takes longer ends the connection to its service.
CONNECT_LIMIT :: 10_000 // Milliseconds for the root service to make a connection: it can start the service first.
LOG_REFUSALS :: 16 // The refusals that this process writes on the log; it counts the others.
LOG_LIMIT :: 50 // Lines of connections and of streams in one second at most: a host that opens many must not fill the log limit of the process.

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
quic_connections: []quic.Connection
streams: []quic.Stream
call_buffers: [][CALL_BUFFER_SIZE]u8
public_key: [32]u8
weak_seed: bool // The seed is weaker than "processor": no key, no endpoint.
listen_port: u16

// The phases of one call stream. A record of a stream frees when the host
// read the end of this side and this side read the end of the host
// (src/library/modus/quic, stream_read); the call place is then empty again.
Call_Phase :: enum u8 {
	None, // No stream in this place.
	Reading, // The request comes. Bound: REQUEST_TIME_LIMIT.
	Waiting, // The request is whole: it waits for its turn. One isolated call runs at a time, in the order in which the requests became whole.
	Answering, // The answer goes, as the stream buffer takes it, then the end of the stream. Bound: ANSWER_TIME_LIMIT.
	Discarding, // This side reset the stream: it drops what comes, until the end of the host. Bound: RELEASE_TIME_LIMIT.
}

Call :: struct {
	phase:            Call_Phase,
	identifier:       u64, // The stream.
	generation:       u64, // The generation of the record: a stream of an earlier client of the place is another call.
	received:         int, // The bytes of the request in the buffer.
	answer_length:    int,
	answer_written:   int, // The bytes of the answer that the stream took.
	phase_started_at: u64, // Milliseconds of the machine: the start of the bound of the phase.
	order:            u64, // The turn of a whole request.
}
calls: [CALL_COUNT]Call
next_order: u64

// What this process logged of each record.
Record_Log :: struct {
	generation: u64,
	end_logged: bool,
}
record_logs: [CAPACITY]Record_Log

// The client table that the root service writes (remote.Client_Table), and
// the copy of its rows that this process read at the start of the pass.
client_table: ^remote.Client_Table
client_rows: [remote.CLIENT_CAPACITY]remote.Client
client_table_version_seen: u32 // The version of the table before the copy of the last pass.

// The row of the client table that a record is bound to: its client proved
// the key of that row in the handshake. A call of the record acts for the
// principal of the row, while the row keeps the serial of the binding.
Record_Client :: struct {
	generation: u64, // The generation of the record of the binding.
	bound:      bool, // The record has a row, whose grant held at the last pass.
	ended:      bool, // The grant of the row ended, or the key had no row: the connection was closed, and nothing binds it again.
	row:        int, // The place of the row in the table.
	serial:     u64, // The serial of the row when the record was bound: the grant.
	principal:  u64, // The principal that allowed the key.
	key:        [32]u8, // The key that the client proved.
}
record_clients: [CAPACITY]Record_Client

// A connection to one service: the root service made it, for one row of
// the client table.
Service_Connection :: struct {
	name:          [32]u8, // Empty: the place is free.
	row:           int, // The row of the client table that the connection is for.
	serial:        u64, // The serial of that row: the grant that the connection carries.
	principal:     u64, // The principal of that row: the root service gave it to the connection.
	process:       system.Handle, // The service, with the right Read: its state.
	ring_memory:   system.Handle,
	region_memory: system.Handle,
	calls:         ring.Ring,
	region:        []u8,
	hash:          [32]u8, // The hash of the module file of the service.
	tag:           u32,
	count:         u64, // The calls through this connection.
}

// The 9 services of the row of "remote" in start_grant_sets in the root service, for each of
// the CAPACITY connections, each of which can have a key of another row.
SERVICE_CONNECTION_CAPACITY :: 24

service_connections: [SERVICE_CONNECTION_CAPACITY]Service_Connection

// The counts that the window shows.
Counts :: struct {
	requests:    u64, // The whole requests.
	calls:       u64, // The isolated calls that ran.
	failed:      u64, // The calls whose export gave a negative result with an error record.
	refused:     u64, // The requests that this process refused with its error record.
	too_large:   u64, // Streams reset with Too_Large.
	timeouts:    u64, // Streams reset with Timeout.
	cancelled:   u64, // Calls that the host gave up before their turn.
	closed_held: u64, // Connections that this process closed for a stream that the host did not end.
	bytes_in:    u64, // The bytes of whole requests.
	bytes_out:   u64, // The bytes of answers.
	sends_refused: u64, // Sends that the network service refused.
	keys_refused: u64, // Client keys that the handshake refused: no row, or a session that is locked.
	revoked:     u64, // Connections that this process ended because the grant of their key ended.
}
counts: Counts

// The last calls, for the window.
Recent :: struct {
	service:      [32]u8,
	export:       u32,
	status:       remote.Status,
	call_status:  u32,
	text:         [96]u8, // A refusal: the sentence of its error record.
	text_count:   int,
	value:        i64,
	error:        i64, // The kind of the error record, or 0.
	bytes:        u64,
	microseconds: u64,
}
RECENT_CAPACITY :: 8
recent: [RECENT_CAPACITY]Recent
recent_count: u64

quic_endpoint: quic_server.Endpoint
requests: ring.Ring // To the root service.
request_tag: u32
draw_logged: bool
log_budget := quic_server.Log_Budget{limit = LOG_LIMIT}

fail :: proc "contextless" (text: string) -> ! {
	system.log_fact(.Info, Service_Failed{failure = value_kinds.text_field(text, FAILURE_FIELD_BYTES)})
	system.stop(.Failed)
}

held_overflow_fail :: proc "contextless" () {
	fail("the held commands passed their bound")
}

now_microseconds :: proc "contextless" () -> u64 {
	return system.nanoseconds() / 1000
}

// log_allowed says if one more line of a connection or of a stream goes on
// the log in this second.
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
		return "closed by the host"
	}
	return "closed by this service"
}

// idle_end_log writes how long a connection that ended by its idle timeout
// received nothing, in time of the machine, against its bound: at least
// its idle timeout. How late after its bound the end came depends on the
// load of the host: the line gives it, and the verdict does not check it.
// A test reads the verdict; the numbers are on the line.
idle_end_log :: proc "contextless" (connection: ^quic.Connection, peer: quic.Remote) {
	silence := (connection.ended_at - min(connection.last_activity, connection.ended_at)) / 1000
	idle_timeout := connection.idle_timeout / 1000
	bound := quic.connection_idle_bound(connection) / 1000
	after_bound := silence - min(silence, bound)
	if silence >= idle_timeout {
		system.log_fact(.Info, Idle_End_Held{silence = milliseconds_field(silence), idle_timeout = milliseconds_field(idle_timeout), bound = milliseconds_field(bound), after_bound = milliseconds_field(after_bound), peer = peer_field(peer)})
	} else {
		system.log_fact(.Info, Idle_End_Not_Held{silence = milliseconds_field(silence), idle_timeout = milliseconds_field(idle_timeout), bound = milliseconds_field(bound), after_bound = milliseconds_field(after_bound), peer = peer_field(peer)})
	}
}

// stream_refuse ends a call stream with a code: STOP_SENDING (the host stops
// its request, when it did not end it) and RESET_STREAM. The place then
// drops what still comes, until the end of the host.
stream_refuse :: proc "contextless" (connection: ^quic.Connection, call: ^Call, code: remote.Stream_Error, now: u64) {
	quic.stream_stop_sending(connection, call.identifier, u64(code))
	quic.stream_reset(connection, call.identifier, u64(code))
	call.phase = .Discarding
	call.phase_started_at = now
}

// call_work moves one call stream: it reads the request, writes the answer,
// and applies the bound of the phase.
call_work :: proc "contextless" (connection: ^quic.Connection, peer: quic.Remote, call: ^Call, buffer: []u8, now: u64) {
	elapsed := now - min(call.phase_started_at, now)
	switch call.phase {
	case .None, .Waiting:
	case .Reading:
		for {
			// The buffer holds REQUEST_LIMIT bytes; one byte more is read into
			// a place of its own, and makes the request Too_Large.
			count: int
			finished, reset: bool
			if call.received < remote.REQUEST_LIMIT {
				count, finished, reset = quic.stream_read(connection, call.identifier, buffer[call.received:remote.REQUEST_LIMIT])
			} else {
				one_more: [1]u8
				count, finished, reset = quic.stream_read(connection, call.identifier, one_more[:])
			}
			if reset {
				// The host gave up its request: no call. This side ends its
				// own direction, and the record frees.
				quic.stream_reset(connection, call.identifier, u64(remote.Stream_Error.Cancelled))
				call.phase = .Discarding
				call.phase_started_at = now
				counts.cancelled += 1
				return
			}
			call.received += count
			switch remote.stream_progress(u64(call.received), finished, remote.REQUEST_LIMIT) {
			case .Too_Large:
				stream_refuse(connection, call, .Too_Large, now)
				counts.too_large += 1
				if log_allowed() {
					system.log_fact(.Info, Request_Too_Large{stream_identifier = call.identifier, request_limit = bytes_field(u64(remote.REQUEST_LIMIT)), peer = peer_field(peer)})
				}
				return
			case .Complete:
				call.phase = .Waiting
				call.order = next_order
				next_order += 1
				return
			case .Waiting:
			}
			if count == 0 {
				break
			}
		}
		if elapsed >= REQUEST_TIME_LIMIT {
			stream_refuse(connection, call, .Timeout, now)
			counts.timeouts += 1
			if log_allowed() {
				system.log_fact(.Info, Request_Timeout{stream_identifier = call.identifier, bound = milliseconds_field(REQUEST_TIME_LIMIT), bytes_received = bytes_field(u64(call.received)), elapsed = milliseconds_field(elapsed), peer = peer_field(peer)})
			}
		}
	case .Answering:
		if stream := quic.stream_of(connection, call.identifier); stream != nil && stream.reset_sent {
			// A STOP_SENDING of the host made the library reset this
			// direction: the answer will never go, and its bound need not run.
			call.phase = .Discarding
			call.phase_started_at = now
			counts.cancelled += 1
			return
		}
		if call.answer_written < call.answer_length {
			call.answer_written += quic.stream_write(connection, call.identifier, buffer[call.answer_written:call.answer_length], true)
		}
		if elapsed >= ANSWER_TIME_LIMIT {
			stream_refuse(connection, call, .Timeout, now)
			counts.timeouts += 1
			if log_allowed() {
				system.log_fact(.Info, Answer_Timeout{stream_identifier = call.identifier, bound = milliseconds_field(ANSWER_TIME_LIMIT), bytes_written = u64(call.answer_written), answer_length = bytes_field(u64(call.answer_length)), elapsed = milliseconds_field(elapsed), peer = peer_field(peer)})
			}
		}
	case .Discarding:
		for {
			dropped: [4096]u8
			count, _, _ := quic.stream_read(connection, call.identifier, dropped[:])
			if count == 0 {
				break
			}
		}
		if elapsed >= RELEASE_TIME_LIMIT {
			if connection.state == .Connected {
				quic.connection_close(connection, u64(remote.Stream_Error.Timeout), now_microseconds())
				counts.closed_held += 1
				if log_allowed() {
					system.log_fact(.Info, Stream_Not_Ended_After_Reset{stream_identifier = call.identifier, bound = milliseconds_field(RELEASE_TIME_LIMIT), elapsed = milliseconds_field(elapsed), peer = peer_field(peer)})
				}
			}
			// The connection ends by its closing state; the next bound is
			// later, so that the wait of the loop does not end at once until
			// the record is free.
			call.phase_started_at = now
		}
	}
}

// client_key_allowed is the check of the handshake (quic.Client_Key_Check):
// the client proved this key, and it is allowed while the client table has
// a row for it whose grant holds. The table is read again here: a key that
// a principal allowed a moment ago is taken. A refusal writes one line.
client_key_allowed :: proc "contextless" (key: ^[32]u8) -> bool {
	rows: [remote.CLIENT_CAPACITY]remote.Client
	remote.client_table_read(client_table, &rows)
	proven := key^
	row := remote.client_find(&rows, proven)
	if row >= 0 && remote.client_grant_holds(&rows, row, rows[row].serial, .Calls) {
		return true
	}
	counts.keys_refused += 1
	if log_allowed() {
		client_key := key_field(proven)
		if row >= 0 && rows[row].contested != 0 {
			system.log_fact(.Info, Client_Key_Refused_Contested{principal = rows[row].principal, other_principal = rows[row].contested - 1, client_key = client_key})
		} else if row >= 0 && rows[row].session_locked == 0 {
			system.log_fact(.Info, Client_Key_Refused_For_Display_Only{principal = rows[row].principal, client_key = client_key})
		} else if row >= 0 {
			system.log_fact(.Info, Client_Key_Refused_Session_Locked{principal = rows[row].principal, client_key = client_key})
		} else {
			system.log_fact(.Info, Client_Key_Refused{client_key = client_key})
		}
	}
	return false
}

// client_bind binds a record whose handshake ended to the row of the key
// that its client proved, or ends it when no row holds that key now: the
// row can end between the check of the handshake and this pass.
client_bind :: proc "contextless" (connection: ^quic.Connection, client: ^Record_Client, peer: quic.Remote) {
	key := connection.tls.client_public_key
	row := remote.client_find(&client_rows, key)
	if row < 0 || !remote.client_grant_holds(&client_rows, row, client_rows[row].serial, .Calls) {
		client.ended = true
		quic.connection_close(connection, u64(remote.Stream_Error.Revoked), now_microseconds())
		counts.revoked += 1
		if log_allowed() {
			system.log_fact(.Info, Client_Key_Grant_Ended_In_Handshake{client_key_head = key_head_field(key), peer = peer_field(peer)})
		}
		return
	}
	client.bound, client.row, client.serial, client.principal, client.key = true, row, client_rows[row].serial, client_rows[row].principal, key
	if log_allowed() {
		system.log_fact(.Info, Client_Key_Proved{principal = client.principal, client_key_head = key_head_field(key), peer = peer_field(peer)})
	}
}

// client_grant_check ends the connection of a bound record whose grant
// ended: the principal revoked the key, or locked its session. Its
// connections to services end in service_connections_of_ended_grants.
client_grant_check :: proc "contextless" (connection: ^quic.Connection, client: ^Record_Client, peer: quic.Remote) {
	if remote.client_grant_holds(&client_rows, client.row, client.serial, .Calls) {
		return
	}
	client.bound = false
	client.ended = true
	quic.connection_close(connection, u64(remote.Stream_Error.Revoked), now_microseconds())
	counts.revoked += 1
	if log_allowed() {
		place := client.row
		if place >= 0 && place < remote.CLIENT_CAPACITY && client_rows[place].key == client.key && client_rows[place].contested != 0 {
			system.log_fact(.Info, Client_Key_Contested{principal = client.principal, other_principal = client_rows[place].contested - 1, client_key_head = key_head_field(client.key), peer = peer_field(peer)})
		} else {
			system.log_fact(.Info, Client_Key_Grant_Ended{principal = client.principal, client_key_head = key_head_field(client.key), peer = peer_field(peer)})
		}
	}
}

// service_connections_of_ended_grants ends each connection to a service
// whose row no longer holds its serial: a revocation, a lock or an unlock
// ended its grant. The root service ended its side already, so this
// process tells it nothing. It runs whatever the state of the QUIC
// connections: a grant can end while no client of its row is connected,
// and its slot must not stay taken, or the table of connections fills.
service_connections_of_ended_grants :: proc "contextless" () {
	ended := 0
	in_use := 0
	for &item in service_connections {
		if item.name[0] == 0 {
			continue
		}
		if remote.client_grant_holds(&client_rows, item.row, item.serial, .Calls) {
			in_use += 1
			continue
		}
		connection_end(&item, false)
		ended += 1
	}
	if ended > 0 && log_allowed() {
		system.log_fact(.Info, Service_Connections_Ended{ended = u64(ended), in_use = u64(in_use), capacity = SERVICE_CONNECTION_CAPACITY})
	}
}

// calls_work moves each call stream of each record, and logs each new
// connection and each end.
calls_work :: proc "contextless" () {
	now := system.time()
	// One state of the client table for the whole pass. The version is read
	// first: the wait of the loop ends at once when the table changed after
	// it.
	client_table_version_seen = intrinsics.atomic_load_explicit(&client_table.version, .Acquire)
	remote.client_table_read(client_table, &client_rows)
	service_connections_of_ended_grants()
	for record, place in records {
		place_calls := calls[place * STREAMS_PER_CONNECTION:][:STREAMS_PER_CONNECTION]
		if !record.in_use {
			for &call in place_calls {
				call = {}
			}
			continue
		}
		record_log := &record_logs[place]
		if record_log.generation != record.generation {
			record_log^ = {generation = record.generation}
			if log_allowed() {
				system.log_fact(.Info, Connection_Arrived{peer = peer_field(record.remote)})
			}
		}
		connection := &quic_connections[place]
		client := &record_clients[place]
		if client.generation != record.generation {
			client^ = {generation = record.generation}
		}
		if connection.state == .Connected {
			switch {
			case !client.bound && !client.ended:
				client_bind(connection, client, record.remote)
			case client.bound:
				client_grant_check(connection, client, record.remote)
			}
		}
		// Each stream is read to its end, or to the reset of the host: a
		// stream record is freed only when this process read that end
		// (quic.stream_read), so a stream left unread would keep its record,
		// and the host would get no stream in its place.
		for &stream, slot in connection.streams {
			call := &place_calls[slot]
			if !stream.in_use {
				call^ = {}
				continue
			}
			if call.phase == .None || call.identifier != stream.identifier || call.generation != record.generation {
				call^ = {phase = .Reading, identifier = stream.identifier, generation = record.generation, phase_started_at = now}
			}
			call_work(connection, record.remote, call, call_buffers[place * STREAMS_PER_CONNECTION + slot][:], now)
		}
		if connection.state == .Closed && !record_log.end_logged {
			record_log.end_logged = true
			if log_allowed() {
				// A code of the application and a transport code are two
				// sentences: each one is a fact type.
				close_code := value_kinds.Hexadecimal_Sixteen_Digits(connection.close_error_code)
				bytes_in, bytes_out := value_kinds.Size_In_Bytes(connection.data_consumed_total), value_kinds.Size_In_Bytes(connection.data_sent_total)
				reason := value_kinds.text_field(end_reason(connection), END_REASON_FIELD_BYTES)
				if connection.close_is_application {
					system.log_fact(.Info, Connection_Ended_By_Application{close_code = close_code, bytes_in = bytes_in, bytes_out = bytes_out, peer = peer_field(record.remote), end_reason = reason})
				} else {
					system.log_fact(.Info, Connection_Ended{close_code = close_code, bytes_in = bytes_in, bytes_out = bytes_out, peer = peer_field(record.remote), end_reason = reason})
				}
				if connection.closed_by_idle_timeout {
					idle_end_log(connection, record.remote)
				}
			}
		}
	}
}

// calls_deadline gives the nearest bound of a call, in milliseconds of the
// machine, or max(u64).
calls_deadline :: proc "contextless" () -> u64 {
	deadline := max(u64)
	for &call in calls {
		bound: u64
		switch call.phase {
		case .None, .Waiting:
			continue
		case .Reading:
			bound = REQUEST_TIME_LIMIT
		case .Answering:
			bound = ANSWER_TIME_LIMIT
		case .Discarding:
			bound = RELEASE_TIME_LIMIT
		}
		deadline = min(deadline, call.phase_started_at + bound)
	}
	return deadline
}



// call_bounds_pause moves the start of the bound of each call whose stream
// moves (reading, answering, discarding) later by the time of an isolated
// call: during it this process runs no QUIC, so the host could not move the
// stream, and a bound counts only the time in which the stream could move.
call_bounds_pause :: proc "contextless" (place_calls: []Call, paused: u64) {
	for &call in place_calls {
		switch call.phase {
		case .Reading, .Answering, .Discarding:
			call.phase_started_at += paused
		case .None, .Waiting:
		}
	}
}

// serve_next makes the isolated call of the request that became whole
// first, and puts its answer in the buffer of its stream. served is false
// when no request waits; duration is the time of the isolated call, in
// milliseconds of the machine.
serve_next :: proc "contextless" () -> (served: bool, duration: u64) {
	chosen := -1
	for &call, index in calls {
		if call.phase == .Waiting && (chosen < 0 || call.order < calls[chosen].order) {
			chosen = index
		}
	}
	if chosen < 0 {
		return false, 0
	}
	call := &calls[chosen]
	place := chosen / STREAMS_PER_CONNECTION
	connection := &quic_connections[place]
	stream := quic.stream_of(connection, call.identifier)
	if stream == nil || !records[place].in_use || records[place].generation != call.generation {
		call^ = {}
		return true, 0
	}
	if stream.reset_received || stream.reset_sent {
		// The host gave up the call before its turn (a reset, or a
		// STOP_SENDING): no call.
		quic.stream_reset(connection, call.identifier, u64(remote.Stream_Error.Cancelled))
		call.phase = .Discarding
		call.phase_started_at = system.time()
		counts.cancelled += 1
		return true, 0
	}
	client := &record_clients[place]
	if !client.bound || client.generation != records[place].generation {
		// The grant of the key of the client ended, and the connection
		// ends: no call acts for a principal that no longer allows it.
		quic.stream_reset(connection, call.identifier, u64(remote.Stream_Error.Revoked))
		call.phase = .Discarding
		call.phase_started_at = system.time()
		return true, 0
	}
	call_started_at := system.time()
	call.answer_length = serve(call_buffers[chosen][:], call.received, client)
	call_ended_at := system.time()
	duration = call_ended_at - min(call_started_at, call_ended_at)
	// The other calls: their streams did not move during the isolated call.
	// This call is still waiting here, so it is not moved.
	call_bounds_pause(calls[:], duration)
	call.answer_written = 0
	call.phase = .Answering
	// The bound of the answer starts when the answer exists: the time of
	// the isolated call is bounded by CALL_LIMIT.
	call.phase_started_at = call_ended_at
	return true, duration
}

// answer_put writes an answer in the buffer of a stream, and gives its
// length.
answer_put :: proc "contextless" (buffer: []u8, header: remote.Answer, result: []u8) -> int {
	bytes, written := remote.answer_write(buffer, header, result)
	if !written {
		// A result is cut to the call region, and the buffer holds an answer
		// of a whole call region: this does not happen.
		bytes, _ = remote.answer_write(buffer, header, nil)
	}
	counts.bytes_out += u64(len(bytes))
	return len(bytes)
}

// refuse answers a request that this process refused, and writes the
// sentence of its error record on the log while the log has room for it.
refuse :: proc "contextless" (buffer: []u8, error: errors.Error_Record, service: string = "", hash: [32]u8 = {}) -> int {
	counts.refused += 1
	error := error
	// One sentence, for the log and for the window.
	sentence: [256]u8
	writer := system.Writer{buffer = sentence[:]}
	field := ""
	if error.argument >= 1 && error.argument <= len(remote.REQUEST_FIELD_NAMES) {
		field = remote.REQUEST_FIELD_NAMES[error.argument - 1]
	}
	system.error_text(&writer, &error, "remote", field)
	if counts.refused <= LOG_REFUSALS {
		if counts.refused == LOG_REFUSALS {
			system.log_fact(.Info, Request_Refused_Last_Logged(errors.error_record_fact_fields(error)))
		} else {
			system.log_fact(.Info, Request_Refused(errors.error_record_fact_fields(error)))
		}
	}
	answer := remote.Answer{status = .Refused, error = error, hash = hash}
	item := recent_add(service, 0, answer, 0, 0)
	item.text_count = copy(item.text[:], system.written(&writer))
	return answer_put(buffer, answer, nil)
}

recent_add :: proc "contextless" (service: string, export: u32, answer: remote.Answer, bytes: u64, microseconds: u64) -> ^Recent {
	item := &recent[recent_count % RECENT_CAPACITY]
	item^ = {export = export, status = answer.status, call_status = answer.call_status, value = answer.value, error = answer.error.kind, bytes = bytes, microseconds = microseconds}
	copy(item.service[:len(item.service) - 1], service)
	recent_count += 1
	return item
}

// connection_find gives the connection to a service for the row of the
// client of a call, and asks the root service for one when this process
// has none: the root service gives it the principal of the row. On a
// failure it gives the error record of the answer.
connection_find :: proc "contextless" (name: string, client: ^Record_Client) -> (connection: ^Service_Connection, error: errors.Error_Record) {
	free: ^Service_Connection
	for &item in service_connections {
		if item.name[0] == 0 {
			free = &item
		} else if remote.name_text(&item.name) == name && item.row == client.row && item.serial == client.serial {
			return &item, {}
		}
	}
	if free == nil {
		return nil, errors.error_make(.Full, .None, remote.FIELD_SERVICE, 0, SERVICE_CONNECTION_CAPACITY)
	}
	packed := system.name_pack(name)
	request_tag += 1
	// values[4] names the row from 1, as the root service takes it.
	if !system.send(&requests.commands, ring.Record{kind = u32(root_ring.Root_Command.Connect), tag = request_tag, values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3], 4 = u64(client.row + 1), 5 = client.serial}}) {
		return nil, errors.error_make(.Refused, .None, remote.FIELD_SERVICE, 0, 0, i64(system.Status.No_Slot))
	}
	limit := system.time() + CONNECT_LIMIT
	for {
		for record in system.receive(&requests.completions) {
			if record.tag != request_tag {
				continue
			}
			// The root service writes the word: a word that names no status
			// is the refusal of status_of_word, and its record.
			status, status_refusal := system.status_of_word(record.kind)
			if status_refusal.kind != 0 {
				status_refusal.argument = remote.FIELD_SERVICE
				return nil, status_refusal
			}
			switch status {
			case .Ok:
			case .Bad_Handle:
				// No service runs with this name.
				return nil, errors.error_make(.Absent, .None, remote.FIELD_SERVICE)
			case .No_Right:
				return nil, errors.error_make(.No_Grant, .Connection, remote.FIELD_SERVICE)
			case .Bad_State:
				// The root service wrote why: the grant of the row ended, or
				// the session of its principal is locked. The field at fault
				// is the service that the call names.
				refused := errors.completion_record(record.values)
				refused.argument = remote.FIELD_SERVICE
				return nil, refused
			case .Bad_Operation, .Bad_Address, .No_Memory, .No_Slot, .No_Budget:
				return nil, errors.error_make(.Refused, .None, remote.FIELD_SERVICE, 0, 0, i64(status))
			}
			connection = free
			connection^ = {
				row           = client.row,
				serial        = client.serial,
				principal     = client.principal,
				process       = system.Handle(record.values[0]),
				ring_memory   = system.Handle(record.values[1]),
				region_memory = system.Handle(record.values[2]),
				hash          = transmute([32]u8)[4]u64{record.values[3], record.values[4], record.values[5], record.values[6]},
			}
			copy(connection.name[:len(connection.name) - 1], name)
			ring_status: system.Status
			connection.calls, ring_status = system.ring_open(connection.ring_memory, receive_handles = true)
			address, map_status := system.memory_map(connection.region_memory)
			region_pages, size_status := system.memory_size(connection.region_memory)
			if ring_status != .Ok || map_status != .Ok || size_status != .Ok {
				connection_end(connection, false)
				refused := ring_status != .Ok ? ring_status : map_status != .Ok ? map_status : size_status
				return nil, errors.error_make(.Refused, .None, remote.FIELD_SERVICE, 0, 0, i64(refused))
			}
			connection.region = ([^]u8)(address)[:region_pages * system.PAGE_SIZE]
			system.log_fact(.Info, Service_Connected{principal = client.principal, service = value_kinds.module_name_field(name)})
			return connection, {}
		}
		wait: system.Wait
		system.wait_records(&wait, &requests.completions)
		if system.wait_end(&wait, limit) >= limit {
			return nil, errors.error_make(.Over_Limit, .Milliseconds, remote.FIELD_SERVICE, CONNECT_LIMIT, CONNECT_LIMIT)
		}
	}
}

// connection_end closes what this process holds of a connection to a
// service. tell: ask the root service to end it too (the service still
// runs).
connection_end :: proc "contextless" (connection: ^Service_Connection, tell: bool) {
	if tell {
		packed := system.name_pack(remote.name_text(&connection.name))
		request_tag += 1
		system.send(&requests.commands, ring.Record{kind = u32(root_ring.Root_Command.Disconnect), tag = request_tag, values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3], 4 = u64(connection.row + 1)}})
	}
	if connection.calls.head != nil {
		system.ring_close(&connection.calls)
	}
	if connection.region != nil {
		system.memory_unmap(raw_data(connection.region))
	}
	for handle in ([3]system.Handle{connection.process, connection.ring_memory, connection.region_memory}) {
		if handle != 0 {
			system.close(handle)
		}
	}
	connection^ = {}
}

// isolated_call_make makes the isolated call of a request through a
// connection, and gives the completion. On a failure of the connection it gives an error record.
// While it waits, this process runs no QUIC: an isolated call is bounded by
// CALL_LIMIT, and a peer of QUIC sends again what it does not see
// acknowledged.
isolated_call_make :: proc "contextless" (connection: ^Service_Connection, request: remote.Request, arguments: []u8) -> (completion: ring.Record, error: errors.Error_Record, ok: bool) {
	// The bytes after the arguments are zero: a request that names a place
	// of the result reads no byte of a call before it.
	copied := copy(connection.region, arguments)
	if copied < len(connection.region) {
		intrinsics.mem_zero(raw_data(connection.region[copied:]), len(connection.region) - copied)
	}
	connection.tag += 1
	if !system.send(&connection.calls.commands, ring.Record{kind = request.export, tag = connection.tag, values = {0 = 0, 1 = u64(request.record_size)}}) {
		return {}, errors.error_make(.Full, .Records, 0, 0, i64(ring.capacity(&connection.calls.commands))), false
	}
	start := system.time()
	limit := start + CALL_LIMIT
	for {
		// The stop of the service is an event of this thread.
		wait := system.wait_begin()
		for _ in 0 ..< ring.CAPACITY {
			record, has := system.receive(&connection.calls.completions)
			if !has {
				break
			}
			if record.tag == connection.tag {
				return record, {}, true
			}
		}
		if state, _, _ := system.process_state(connection.process); state == .Stopped || state == .None {
			system.log_fact(.Info, Service_Stopped_During_Call{service = value_kinds.module_name_field(remote.name_text(&connection.name))})
			connection_end(connection, false)
			return {}, errors.error_make(.State, .None, remote.FIELD_SERVICE, 0, 0, i64(state)), false
		}
		system.wait_records(&wait, &connection.calls.completions)
		if system.wait_spin(&wait) {
			continue
		}
		if now := system.wait_end(&wait, limit); now >= limit {
			system.log_fact(.Info, Service_Silent{bound = milliseconds_field(CALL_LIMIT), service = value_kinds.module_name_field(remote.name_text(&connection.name))})
			connection_end(connection, true)
			return {}, errors.error_make(.Over_Limit, .Milliseconds, remote.FIELD_EXPORT, i64(now - start), CALL_LIMIT), false
		}
	}
}

// serve reads one whole request in the buffer of its stream, makes the
// call for the principal of the row of its client, and writes the answer in
// the same buffer: the request is copied into the call region before the
// answer is written. It gives the length of the answer.
serve :: proc "contextless" (buffer: []u8, received: int, client: ^Record_Client) -> int {
	counts.requests += 1
	counts.bytes_in += u64(received)
	start := system.nanoseconds()
	request, arguments, error, ok := remote.request_check(buffer[:received], remote.REGION_SIZE)
	if !ok {
		return refuse(buffer, error)
	}
	service := remote.name_text(&request.service)
	connection, connection_error := connection_find(service, client)
	if connection == nil {
		return refuse(buffer, connection_error, service)
	}
	if connection.hash != request.hash {
		return refuse(buffer, errors.error_make(.Bad_Value, .None, remote.FIELD_HASH), service, connection.hash)
	}
	if u64(len(connection.region)) < remote.REGION_SIZE {
		return refuse(buffer, errors.error_make(.Too_Small, .Bytes, remote.FIELD_SERVICE, i64(len(connection.region)), remote.REGION_SIZE), service, connection.hash)
	}
	completion, call_error, called := isolated_call_make(connection, request, arguments)
	if !called {
		return refuse(buffer, call_error, service, connection.hash)
	}
	connection.count += 1
	counts.calls += 1
	answer := remote.Answer {
		status      = .Ok,
		call_status = completion.kind,
		value       = i64(completion.values[0]),
		hash        = connection.hash,
	}
	result: []u8
	if isolated.Status(completion.kind) == .Ok {
		if request.error_start != 0 && answer.value < 0 {
			// The service wrote it: values only, copied as values.
			answer.error = (^errors.Error_Record)(raw_data(connection.region[request.error_start:]))^
			counts.failed += 1
			// The bytes of a failed call are its error details.
			details, details_count := remote.details_bytes(request, connection.region[:remote.REGION_SIZE])
			answer.details = u32(min(details_count, u64(max(u32))))
			result = details
		} else {
			result = connection.region[request.result_start:][:remote.result_bytes(request, answer.value)]
		}
	}
	length := answer_put(buffer, answer, result)
	recent_add(service, request.export, answer, u64(len(result)), (system.nanoseconds() - start) / 1000)
	return length
}

// key_make makes the Ed25519 key of this service from the generator of the
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

// The entry of the remote service: it makes its key, checks its grant, then
// runs QUIC and the calls of the host until the machine stops.
//
// The entry, in order:
//
// 1. takes the random generator of its context, and opens its window (it
//    runs with no window too);
// 2. makes its Ed25519 key. With a seed under the strength "processor" it
//    writes "remote: the random seed of this process is weak" and then only
//    draws its window: it listens on nothing;
// 3. writes "remote: the public key of this service: " and 64 hexadecimal
//    digits;
// 4. opens its datagram endpoint and the ring to the root service, maps the
//    client table read-only, and asks the network service for its grant. A
//    grant that is not a listen grant of UDP for the host only stops it
//    (`fail`), and so does a missing client table;
// 5. maps the table of the connections, the streams and their buffers,
//    starts the QUIC server, which asks each client for its key, and erases
//    its own copy of the private key;
// 6. writes "remote: listening on the UDP port 7100, for the host 10.0.2.2
//    only, and for the client keys that a principal allowed: ...".
//
// Then one loop runs for ever. Each pass gives the arrived datagrams to the
// server, makes at most one isolated call, and draws the window at most ten
// times in one second. After a call of 100 ms or more, the passes of the
// next 50 ms only move datagrams, so that the handshake of another
// connection goes on. The loop waits for a datagram, an event of the
// window, the next deadline of QUIC, or the bound of a call.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	if !random.generator_from_context(&process_generator, ctx) {
		fail("no random seed in the context")
	}
	window, has_window := display.open(ctx, WIDTH, HEIGHT, "remote")
	configuration := quic.Connection_Configuration{idle_timeout_milliseconds = IDLE_TIMEOUT_MILLISECONDS}
	configuration.tls = {role = .Server, least_seed_strength = .Processor}
	configuration.tls.application_protocol_length = copy(configuration.tls.application_protocol[:], remote.APPLICATION_PROTOCOL)
	if !key_make(&configuration) {
		// A seed under the least strength is an error that the process
		// shows: no key, and no endpoint.
		weak_seed = true
		system.log_fact(.Info, Seed_Weak{})
		for {
			if has_window {
				draw(&window)
				display.wait(&window, system.time() + 1000)
				for event in display.next_event(&window) {
					_ = event
				}
			} else {
				wait: system.Wait
				system.wait_end(&wait, system.time() + 1000)
			}
		}
	}
	// The key of the service is the identity of this machine to its paired
	// machines (mesh.odin).
	mesh_error: errors.Error_Record
	if mesh_identity_set(public_key, &mesh_error) != 0 {
		fail("the public key of the service is not a machine identity")
	}
	key_text: [64]u8
	system.log_fact(.Info, Public_Key_Made{public_key = value_kinds.text_field(quic_server.hex_text(key_text[:], public_key[:]), KEY_FIELD_BYTES)})
	switch quic_server.endpoint_open(&quic_endpoint, ctx, RECEIVE_PLACES, CAPACITY, remote.HOST_ADDRESS, true) {
	case .None:
	case .No_Ring:
		fail("no endpoint: the process has no grant of the network")
	case .No_Region:
		fail("no datagram region")
	case .Info_Timeout, .Bad_Grant, .Bad_Config:
		fail("the grant is not a listen grant of UDP for the address of the host only")
	}
	quic_endpoint.on_held_overflow = held_overflow_fail
	listen_port = quic_endpoint.listen_port
	status: system.Status
	if requests, status = system.ring_open(ctx.handles[system.GRANT_ROOT], receive_handles = true); status != .Ok {
		fail("no ring to the root service")
	}
	// The client table, read-only: the root service writes it, and this
	// process cannot give a key a row.
	client_table_address, client_table_status := system.memory_map(ctx.handles[remote.GRANT_CLIENT_TABLE], {})
	if client_table_status != .Ok {
		fail("no client table: the process has no grant Remote_Clients")
	}
	client_table = (^remote.Client_Table)(client_table_address)
	// The handshake asks each client for its key, and takes it only when
	// the table allows it.
	configuration.tls.client_key_check = client_key_allowed
	// The connections, their streams and their buffers: one mapping.
	memory, memory_status := system.memory_create(TABLE_PAGES)
	table, table_status := system.memory_map(memory, {.Write})
	if memory_status != .Ok || table_status != .Ok {
		fail("no memory for the table of connections")
	}
	quic_connections = ([^]quic.Connection)(table)[:CAPACITY]
	streams = ([^]quic.Stream)(rawptr(uintptr(table) + CONNECTION_BYTES))[:CALL_COUNT]
	call_buffers = ([^][CALL_BUFFER_SIZE]u8)(rawptr(uintptr(table) + CONNECTION_BYTES + STREAM_BYTES))[:CALL_COUNT]
	// The limits of quic_echo, for a table of 2 records: one address (the
	// host) may hold both, in the handshake too.
	limits := quic.SERVER_LIMITS_DEFAULT
	limits.connections_per_remote_address = CAPACITY
	limits.handshakes_per_remote_address = CAPACITY
	limits.handshakes_at_once = CAPACITY
	error: errors.Error_Record
	if !quic.server_init(&server, quic_connections, records[:], streams, &configuration, &cryptography, &process_generator, limits, &error) {
		fail("the server refused its configuration")
	}
	// The server keeps its own copy of the key. A plain store of zeros to a
	// record that is not read again can be removed by the compiler.
	quic.secret_erase(&configuration.tls.server_private_key, size_of(configuration.tls.server_private_key))
	quic_server.endpoint_post_receives(&quic_endpoint)
	quic_server.endpoint_wake(&quic_endpoint)
	system.log_fact(.Info, Listening{listen_port = u64(listen_port), connection_capacity = u64(CAPACITY), calls_per_connection = u64(STREAMS_PER_CONNECTION)})

	arrived: [RECEIVE_PLACES]ring.Record
	drawn: u64
	dirty := true
	picture_waits := false // A picture waits until the compositor took the picture before it.
	// After a slow isolated call: no call before this time, only datagrams.
	exchange_until: u64
	for {
		wait := system.wait_begin()
		count := quic_server.completions_drain(&quic_endpoint, &server, records[:], arrived[:])
		counts.sends_refused = quic_endpoint.sends_refused
		deadline := quic_server.exchange(&quic_endpoint, &server, records[:], arrived[:count], now_microseconds(), calls_work)
		quic_server.endpoint_wake(&quic_endpoint)
		if count > 0 {
			dirty = true
		}
		// One isolated call in each pass: the datagrams of the connections
		// move between two calls, for a while after a slow one.
		served := false
		if system.time() >= exchange_until {
			duration: u64
			served, duration = serve_next()
			if served {
				dirty = true
			}
			if duration >= SLOW_CALL_MILLISECONDS {
				exchange_until = system.time() + EXCHANGE_AFTER_SLOW_CALL_MILLISECONDS
			}
		}
		now := system.time()
		if has_window {
			interface.window_events(&window_memory.drawing, &window)
			// A new surface, of a change of the scale or of a resize, waits
			// for its first picture: the compositor shows the frame of the
			// window with the background until then. The calls are not the
			// only change of this window.
			if display.picture_owed(&window) {
				dirty = true
			}
			// The window changes at most ten times in one second: a burst of
			// calls does not wait for the drawing. This service never
			// waits for the compositor: while the compositor did not take
			// the last picture, the picture waits, and the wait below ends
			// when the compositor has read.
			picture_waits = dirty && now - drawn >= 100 && !display.canvas_free(&window)
			if dirty && now - drawn >= 100 && !picture_waits {
				start := system.nanoseconds()
				draw(&window)
				drawn, dirty = now, false
				// The time of one picture, one time, when the window has calls
				// to show (docs/DESIGN.md, section 7).
				if !draw_logged && counts.calls >= 1000 {
					draw_logged = true
					system.log_fact(.Info, Window_Drawn{picture_time = value_kinds.Time_In_Microseconds((system.nanoseconds() - start) / 1000)})
					system.log_fact(.Info, Interface_Measured{records = u64(window_memory.drawing.now.record_count), damage_rectangles = u64(window_memory.drawing.damage.count), build_time = value_kinds.Time_In_Microseconds(window_memory.drawing.build_time / 1000), difference_time = value_kinds.Time_In_Microseconds(window_memory.drawing.difference_time / 1000), draw_time = value_kinds.Time_In_Microseconds(window_memory.drawing.draw_time / 1000)})
				}
			}
		}
		if served || !ring.empty(&quic_endpoint.datagrams.completions) {
			// The answer goes at once: the next pass writes it in its stream.
			continue
		}
		system.wait_records(&wait, &quic_endpoint.datagrams.completions)
		if has_window {
			display.wait_events(&wait, &window)
		}
		// A change of the client table: the root service wakes this word,
		// so a revoked key ends its connection at once, and not at the next
		// deadline of QUIC.
		system.wait_word(&wait, &client_table.version, client_table_version_seen)
		if system.wait_spin(&wait) {
			continue
		}
		limit := dirty && has_window && !picture_waits ? drawn + 100 : system.WAIT_FOREVER
		if deadline != max(u64) {
			limit = min(limit, deadline / 1000 + 1)
		}
		limit = min(limit, calls_deadline())
		if exchange_until > system.time() {
			limit = min(limit, exchange_until)
		}
		system.wait_end(&wait, limit)
	}
}
