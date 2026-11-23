package machine

import "core:encoding/endian"
import "core:encoding/hex"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "modus:contract/errors"
import "modus:contract/memory_screen"
import protocol "modus:contract/remote_display"
import "modus:display"
import "modus:quic"
import "modus:random"
import "modustool:foundation"
import "modustool:fuzz"

// The peer as the viewers of `remote_display`
// (src/md/features/remote_display.md; docs/QUIC.md, "8. The remote
// display"). The thread of the peer holds one QUIC connection for each
// viewer, with the key of the viewer, opens its one stream, writes
// Session_Start, then reads the records of the screen through the border
// of the contract, rebuilds the screen from the screen pieces, and takes
// each viewer frame. A record that the border refuses ends the connection
// with the code Bad_Record, as a viewer must.
//
// The cases of the machine test (remote_display_case_run) start a session,
// wait for its viewer frames, compare the screen that the viewer rebuilt
// with a picture of QEMU of the same moment, and send what a viewer must
// not send: each refusal is checked by the code of the end of the
// connection. Viewer 0 runs the cases; the next viewers fill the capacity
// of the service in the case "a viewer past the capacity", and the last one
// is the viewer past it.

PEER_DISPLAY_VIEWERS :: protocol.CONNECTION_CAPACITY + 1
PEER_DISPLAY_PORT_FIRST :: 44000 // The local UDP port of the first connection of viewer 0; one more for each next one.
PEER_DISPLAY_PORT_STEP :: 1000 // The ports of viewer n start at PEER_DISPLAY_PORT_FIRST + n * this.
// The first byte of the fixed private key of the viewer of a machine test;
// each next byte is one more. The key protects nothing but the test.
PEER_DISPLAY_VIEWER_KEY_FIRST :: 0x61
// The first byte of a private key that no principal allows.
PEER_DISPLAY_STRANGER_KEY_FIRST :: 0x7a
// The mark of a step that the tool replaces with the public key of the
// viewer of the peer: remote_display_allow("{viewer key}", "view").
VIEWER_KEY_MARK :: "{viewer key}"
// The viewer frames of a small damage that the measure line takes, at most.
PEER_DISPLAY_SMALL_FRAMES :: 5

// The largest rectangle of a pointer picture: the pointer theme of the
// system draws at the sizes 24 and 48. The comparison excludes no larger
// rectangle, so a wrong place of the pointer cannot hide a part of the
// screen.
PEER_DISPLAY_POINTER_LIMIT :: 48

Peer_Remote_Display :: struct {
	lock:              sync.Mutex, // Each field below: the thread of the peer and the thread of the scenario read them.
	number:            int, // The viewer: 0, 1 or 2.
	cryptography:      quic.Cryptography,
	generator:         random.Generator,
	configuration:     quic.Connection_Configuration,
	pinned:            bool,
	client_public_key: [32]u8,
	client:            quic.Connection,
	streams:           []quic.Stream,
	wanted:            bool, // A case asked for a session: the next tick starts its connection.
	active:            bool, // The client holds a connection that did not end.
	connections_made:  int,
	port:              u16,
	next_port:         u16,
	start:             time.Tick,
	stream:            u64,
	has_stream:        bool,
	// How the last connection ended.
	ended:             bool,
	close_code:        u64,
	close_is_application: bool,
	closed_by_peer:    bool,
	client_refused:    bool, // The service ended the handshake with access_denied.
	handshake_timeout: bool, // No handshake: the service had no record for the client.
	refusal:           string, // Why this viewer refused a record of the service: a constant text.
	// The records that the viewer writes, as the stream takes them. The
	// first bytes of a session can be bytes of a case in place of
	// Session_Start.
	outgoing:          [256]u8,
	outgoing_length:   int,
	outgoing_written:  int,
	session_started:   bool,
	start_bytes:       [64]u8,
	start_bytes_length: int,
	// The record of the service that is being read: copied once, then its
	// border reads the copy.
	incoming:          []u8,
	incoming_count:    int,
	piece_pixels:      []u32,
	// The screen that the viewer rebuilds, and the screen of its last
	// whole viewer frame.
	screen:            protocol.Screen,
	pixels:            []u32,
	shown:             []u32,
	shown_pointer:     protocol.Pointer_Place_Body,
	pointer:           protocol.Pointer_Place_Body,
	pointer_shape:     protocol.Pointer_Shape_Body,
	has_pointer_shape: bool,
	pointer_warp:      protocol.Pointer_Warp_Body,
	has_pointer_warp:  bool,
	inputs_sent:       u64,
	echo_tracker:      protocol.Input_Echo_Tracker,
	last_echo_count:   u64,
	in_frame:          bool,
	frame_serial:      u64,
	pieces_left:       u32,
	frames_taken:      u64, // The viewer frames that came whole, taken or held.
	hold_frames:       bool, // A case keeps each viewer frame in flight: no Viewer_Frame_Taken goes.
	// The measures of the viewer, on the clock of the host.
	frame_started:     time.Tick,
	frame_bytes:       u64,
	frame_pixels:      u64,
	whole_bytes:       u64,
	whole_time:        time.Duration,
	whole_measured:    bool,
	small_bytes:       [PEER_DISPLAY_SMALL_FRAMES]u64,
	small_times:       [PEER_DISPLAY_SMALL_FRAMES]time.Duration,
	small_count:       int,
	// The pixels of the last viewer frame and of the smallest one after the
	// whole screen: a failure of the small frames names what came.
	last_frame_pixels:     u64,
	smallest_frame_pixels: u64,
	// The size of the screen of memory (protocol version 3): the count of
	// the Screen_Size records of the session, the viewer frames since the
	// last one, whether the first of them was the whole screen, and the last
	// refusal of an ask.
	screen_sizes:      int,
	frames_at_size:    u64,
	first_frame_whole: bool,
	size_refusal:      protocol.Screen_Size_Refused_Body,
	size_refused:      bool,
}

peer_display_make :: proc(number: int) -> ^Peer_Remote_Display {
	state := new(Peer_Remote_Display)
	state.number = number
	state.streams = make([]quic.Stream, 1)
	state.incoming = make([]u8, protocol.RECORD_HEADER_SIZE + protocol.SCREEN_PIECE_BODY_LIMIT)
	state.piece_pixels = make([]u32, protocol.SCREEN_PIECE_PIXEL_LIMIT)
	state.cryptography = fuzz.quic_cryptography_of_the_host()
	// A seed of its own for each viewer: two viewers never draw the same
	// connection identifiers.
	seed: [random.SEED_SIZE]u8
	for index in 0 ..< random.SEED_SIZE {
		seed[index] = u8(0x31 + index + 0x40 * number)
	}
	random.generator_seed(&state.generator, &seed, .Processor)
	state.configuration = {idle_timeout_milliseconds = 30_000}
	state.configuration.tls = {role = .Client, least_seed_strength = .Processor}
	state.configuration.tls.application_protocol_length = copy(state.configuration.tls.application_protocol[:], protocol.APPLICATION_PROTOCOL)
	peer_display_key_set(state, peer_display_viewer_key(PEER_DISPLAY_VIEWER_KEY_FIRST))
	state.next_port = u16(PEER_DISPLAY_PORT_FIRST + number * PEER_DISPLAY_PORT_STEP)
	state.start = time.tick_now()
	return state
}

peer_display_free :: proc(state: ^Peer_Remote_Display) {
	if state == nil {
		return
	}
	delete(state.streams)
	delete(state.incoming)
	delete(state.piece_pixels)
	delete(state.pixels)
	delete(state.shown)
	free(state)
}

peer_display_now :: proc(state: ^Peer_Remote_Display) -> u64 {
	return u64(time.tick_since(state.start) / time.Microsecond) + 1
}

// peer_display_viewer_key gives the private key of a viewer of a machine
// test.
peer_display_viewer_key :: proc(first: u8) -> (key: [32]u8) {
	for index in 0 ..< len(key) {
		key[index] = first + u8(index)
	}
	return key
}

// peer_display_key_set gives the viewer a private key, and computes its
// public key. The lock is not held.
peer_display_key_set :: proc(state: ^Peer_Remote_Display, private_key: [32]u8) {
	sync.mutex_lock(&state.lock)
	defer sync.mutex_unlock(&state.lock)
	state.configuration.tls.client_private_key = private_key
	error: errors.Error_Record
	secret := string(state.configuration.tls.client_private_key[:])
	result := state.client_public_key[:]
	state.cryptography.ed25519_public_key(&secret, &result, &error)
}

// viewer_key_expand writes the public key of the viewer in place of each
// VIEWER_KEY_MARK of a text of a step.
viewer_key_expand :: proc(state: ^Peer_Remote_Display, text: string) -> string {
	sync.mutex_lock(&state.lock)
	key := state.client_public_key
	sync.mutex_unlock(&state.lock)
	expanded, _ := strings.replace_all(text, VIEWER_KEY_MARK, hex_of(key[:]), context.temp_allocator)
	return expanded
}

// peer_display_pin_text takes the public key of one start of the service.
peer_display_pin_text :: proc(state: ^Peer_Remote_Display, text: string) -> bool {
	bytes, ok := hex.decode(transmute([]u8)text, context.temp_allocator)
	if !ok || len(bytes) != 32 {
		return false
	}
	sync.mutex_lock(&state.lock)
	defer sync.mutex_unlock(&state.lock)
	copy(state.configuration.tls.server_public_key[:], bytes)
	state.pinned = true
	return true
}

// peer_display_datagram takes a datagram of the service to the peer, for
// the viewer whose connection has its port.
peer_display_datagram :: proc(peer: ^Peer, destination: [4]u8, port: u16, data: []u8) {
	if destination != PEER_ADDRESS {
		return
	}
	for state in peer.display_viewers {
		if state == nil {
			continue
		}
		sync.mutex_lock(&state.lock)
		if state.active && port == state.port {
			error: errors.Error_Record
			quic.connection_datagram_receive(&state.client, data, peer_display_now(state), &error)
			sync.mutex_unlock(&state.lock)
			return
		}
		sync.mutex_unlock(&state.lock)
	}
}

// peer_display_queue adds a record to the bytes that the viewer writes.
// false: the bytes are full. The lock is held.
peer_display_queue :: proc(state: ^Peer_Remote_Display, kind: protocol.Record_Kind, body: $T) -> bool {
	bytes, ok := protocol.record_write(state.outgoing[state.outgoing_length:], kind, body)
	if !ok {
		return false
	}
	state.outgoing_length += len(bytes)
	if kind == .Key || kind == .Pointer {
		state.inputs_sent += 1
	}
	return true
}

// peer_display_queue_bytes adds raw bytes, which the border of the service
// must refuse. The lock is held.
peer_display_queue_bytes :: proc(state: ^Peer_Remote_Display, bytes: []u8) -> bool {
	if len(state.outgoing) - state.outgoing_length < len(bytes) {
		return false
	}
	copy(state.outgoing[state.outgoing_length:], bytes)
	state.outgoing_length += len(bytes)
	return true
}

// peer_display_refuse ends the connection for a record of the service that
// the border of the viewer refused. The lock is held.
@(private = "file")
peer_display_refuse :: proc(state: ^Peer_Remote_Display, why: string) {
	state.refusal = why
	quic.connection_close(&state.client, u64(protocol.Display_Error.Bad_Record), peer_display_now(state))
}

// peer_display_record takes one whole record of the service that its border
// took. The lock is held.
@(private = "file")
peer_display_record :: proc(state: ^Peer_Remote_Display, record: protocol.Service_Record, length: int) {
	switch record.kind {
	case .None, .Viewer_Frame_Taken, .Screen_Piece_Request, .Key, .Pointer, .Session_Start, .Screen_Size_Ask:
		peer_display_refuse(state, "a record of the other direction")
	case .Screen_Size_Refused:
		state.size_refusal, state.size_refused = record.screen_size_refused, true
	case .Screen_Size:
		// A Screen_Size comes first, and again after a change of the size of
		// a screen of memory, between two viewer frames.
		if state.in_frame {
			peer_display_refuse(state, "a Screen_Size in the middle of a viewer frame")
			return
		}
		state.screen_sizes += 1
		state.frames_at_size, state.first_frame_whole = 0, false
		state.screen = {record.screen_size.width, record.screen_size.height}
		// The pixels of the viewer have the size of the screen of the
		// session: a screen of 8K is 132 MB, which a screen of 1080p does
		// not pay for.
		pixel_count := int(state.screen.width) * int(state.screen.height)
		if len(state.pixels) < pixel_count {
			delete(state.pixels)
			delete(state.shown)
			state.pixels = make([]u32, pixel_count)
			state.shown = make([]u32, pixel_count)
		}
	case .Pointer_Place:
		state.pointer = record.pointer_place
	case .Pointer_Shape:
		state.pointer_shape = record.pointer_shape
		state.has_pointer_shape = true
	case .Pointer_Picture:
		state.has_pointer_shape = true
	case .Pointer_Warp:
		if protocol.input_echo_check(&state.echo_tracker, record.pointer_warp.input_echo_count, state.inputs_sent) != .None {
			peer_display_refuse(state, "a Pointer_Warp with a bad input echo count")
			return
		}
		state.pointer_warp = record.pointer_warp
		state.has_pointer_warp = true
		state.last_echo_count = record.pointer_warp.input_echo_count
	case .Viewer_Frame_Start:
		if state.in_frame || state.screen.width == 0 {
			peer_display_refuse(state, "a Viewer_Frame_Start in a viewer frame, or before Screen_Size")
			return
		}
		if protocol.input_echo_check(&state.echo_tracker, record.viewer_frame_start.input_echo_count, state.inputs_sent) != .None {
			peer_display_refuse(state, "a Viewer_Frame_Start with a bad input echo count")
			return
		}
		state.last_echo_count = record.viewer_frame_start.input_echo_count
		state.in_frame = true
		state.frame_serial = record.viewer_frame_start.serial
		state.pieces_left = record.viewer_frame_start.screen_piece_count
		state.frame_started = time.tick_now()
		state.frame_bytes, state.frame_pixels = 0, 0
	case .Screen_Piece:
		piece := record.screen_piece
		if !state.in_frame || state.pieces_left == 0 {
			peer_display_refuse(state, "a screen piece past the count of its viewer frame")
			return
		}
		count := int(piece.width * piece.height)
		// The piece goes into memory of its own: a damaged piece changes
		// nothing of the screen.
		if problem := protocol.screen_piece_decode(record.coded, state.piece_pixels[:count]); problem != .None {
			peer_display_refuse(state, protocol.SCREEN_PIECE_PROBLEM_SENTENCES[problem])
			return
		}
		width, piece_width := int(state.screen.width), int(piece.width)
		for row in 0 ..< int(piece.height) {
			copy(state.pixels[(int(piece.y) + row) * width + int(piece.x):][:piece_width], state.piece_pixels[row * piece_width:][:piece_width])
		}
		state.pieces_left -= 1
		state.frame_bytes += u64(length)
		state.frame_pixels += u64(count)
	case .Viewer_Frame_End:
		if !state.in_frame || record.viewer_frame_end.serial != state.frame_serial || state.pieces_left != 0 {
			peer_display_refuse(state, "a Viewer_Frame_End of another viewer frame, or before the last screen piece")
			return
		}
		state.in_frame = false
		spent := time.tick_since(state.frame_started)
		pixel_count := int(state.screen.width) * int(state.screen.height)
		copy(state.shown[:pixel_count], state.pixels[:pixel_count])
		state.shown_pointer = state.pointer
		state.frames_taken += 1
		state.last_frame_pixels = state.frame_pixels
		if state.whole_measured && (state.smallest_frame_pixels == 0 || state.frame_pixels < state.smallest_frame_pixels) {
			state.smallest_frame_pixels = state.frame_pixels
		}
		if state.frames_at_size == 0 {
			state.first_frame_whole = state.frame_pixels == u64(pixel_count)
		}
		state.frames_at_size += 1
		if !state.whole_measured && state.frame_pixels == u64(pixel_count) {
			state.whole_measured = true
			state.whole_bytes, state.whole_time = state.frame_bytes, spent
		} else if state.frame_pixels > 0 && state.frame_pixels <= protocol.small_damage_pixels(state.screen.width, state.screen.height) && state.small_count < PEER_DISPLAY_SMALL_FRAMES {
			state.small_bytes[state.small_count] = state.frame_bytes
			state.small_times[state.small_count] = spent
			state.small_count += 1
		}
		if !state.hold_frames {
			peer_display_queue(state, .Viewer_Frame_Taken, protocol.Viewer_Frame_Taken_Body{serial = state.frame_serial})
		}
	}
}

// peer_display_read reads the records of the service, one whole record at
// a time: the header first, which its border checks before any byte of the
// body. The lock is held.
@(private = "file")
peer_display_read :: proc(state: ^Peer_Remote_Display) {
	client := &state.client
	for client.state == .Connected {
		want := protocol.RECORD_HEADER_SIZE
		header: protocol.Record_Header
		if state.incoming_count >= protocol.RECORD_HEADER_SIZE {
			header, _ = protocol.header_read(state.incoming)
			want = protocol.RECORD_HEADER_SIZE + int(header.length)
		}
		count, _, reset := quic.stream_read(client, state.stream, state.incoming[state.incoming_count:want])
		if reset {
			return
		}
		state.incoming_count += count
		if count > 0 && state.incoming_count == protocol.RECORD_HEADER_SIZE {
			header, _ = protocol.header_read(state.incoming)
			if problem := protocol.record_length_problem(header, .To_Viewer); problem != .None {
				peer_display_refuse(state, protocol.RECORD_PROBLEM_SENTENCES[problem])
				return
			}
			continue
		}
		if state.incoming_count > protocol.RECORD_HEADER_SIZE && state.incoming_count == protocol.RECORD_HEADER_SIZE + int(header.length) {
			record, problem := protocol.service_record_check(header, state.incoming[protocol.RECORD_HEADER_SIZE:state.incoming_count], state.screen)
			length := state.incoming_count
			state.incoming_count = 0
			if problem != .None {
				peer_display_refuse(state, protocol.RECORD_PROBLEM_SENTENCES[problem])
				return
			}
			peer_display_record(state, record, length)
			continue
		}
		if count == 0 {
			return
		}
	}
}

// peer_display_tick runs the sessions of the viewers: their connections,
// their streams, their records, the timers. The thread of the peer calls
// it.
peer_display_tick :: proc(peer: ^Peer) {
	for state in peer.display_viewers {
		if state != nil {
			peer_display_tick_one(peer, state)
		}
	}
}

@(private = "file")
peer_display_tick_one :: proc(peer: ^Peer, state: ^Peer_Remote_Display) {
	sync.mutex_lock(&state.lock)
	defer sync.mutex_unlock(&state.lock)
	now := peer_display_now(state)
	client := &state.client
	if state.active && client.state == .Closed {
		state.active = false
		state.ended = true
		state.close_code = client.close_error_code
		state.close_is_application = client.close_is_application
		state.closed_by_peer = client.closed_by_peer
		state.handshake_timeout = client.closed_by_handshake_timeout
		state.client_refused = client.closed_by_peer && !client.close_is_application && client.close_error_code == quic.CRYPTO_ERROR_BASE + u64(quic.Alert.Access_Denied)
	}
	if state.wanted && !state.active && state.pinned {
		state.wanted = false
		state.ended, state.close_code, state.close_is_application, state.closed_by_peer, state.client_refused, state.handshake_timeout = false, 0, false, false, false, false
		state.refusal = ""
		state.has_stream, state.session_started = false, false
		state.outgoing_length, state.outgoing_written, state.incoming_count = 0, 0, 0
		state.screen = {}
		state.pointer_shape, state.has_pointer_shape = {}, false
		state.pointer_warp, state.has_pointer_warp = {}, false
		state.inputs_sent, state.echo_tracker, state.last_echo_count = 0, {}, 0
		state.in_frame, state.frames_taken = false, 0
		state.screen_sizes, state.frames_at_size, state.first_frame_whole, state.size_refusal, state.size_refused = 0, 0, false, {}, false
		state.port = state.next_port
		state.next_port += 1
		error: errors.Error_Record
		if quic.connection_start_client(client, state.streams, &state.configuration, &state.cryptography, &state.generator, now, &error) {
			state.active = true
			state.connections_made += 1
		} else {
			state.ended = true
			state.refusal = "the QUIC client of the viewer did not start"
		}
	}
	if !state.active {
		return
	}
	if client.state == .Connected && !state.has_stream {
		if identifier, opened := quic.stream_open(client); opened {
			state.stream, state.has_stream = identifier, true
		}
	}
	if state.has_stream && client.state == .Connected {
		if !state.session_started {
			// The first bytes of the stream: Session_Start, or the bytes of
			// a case that must be refused before it.
			if state.start_bytes_length > 0 {
				state.session_started = peer_display_queue_bytes(state, state.start_bytes[:state.start_bytes_length])
				state.start_bytes_length = 0
			} else {
				state.session_started = peer_display_queue(state, .Session_Start, protocol.Session_Start_Body{version = protocol.PROTOCOL_VERSION})
			}
		}
		for state.outgoing_written < state.outgoing_length {
			taken := quic.stream_write(client, state.stream, state.outgoing[state.outgoing_written:state.outgoing_length], false)
			if taken == 0 {
				break
			}
			state.outgoing_written += taken
		}
		if state.outgoing_written == state.outgoing_length {
			state.outgoing_written, state.outgoing_length = 0, 0
		}
		peer_display_read(state)
	}
	buffer: [quic.MAX_DATAGRAM_SIZE]u8
	for _ in 0 ..< 64 {
		length := quic.connection_datagram_send(client, buffer[:], now)
		if length == 0 {
			break
		}
		peer_send(peer, peer_udp_to_machine(peer, PEER_ADDRESS, state.port, protocol.LISTEN_PORT, buffer[:length]))
	}
	if quic.connection_deadline(client) <= now {
		quic.connection_time_passes(client, now)
	}
}

// What a case waits for.
@(private = "file")
Display_Condition :: enum {
	Frames, // The viewer has a count of viewer frames, or the session ended.
	End, // The session ended.
}

// peer_display_wait waits for a condition of the session, with the hang
// bound, and says if it holds.
@(private = "file")
peer_display_wait :: proc(state: ^Peer_Remote_Display, condition: Display_Condition, frames: u64 = 0) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < foundation.HANG_BOUND {
		sync.mutex_lock(&state.lock)
		// No session: none runs, and none is asked for.
		no_session := !state.active && !state.wanted
		taken := state.frames_taken
		sync.mutex_unlock(&state.lock)
		switch condition {
		case .Frames:
			if taken >= frames || no_session {
				return taken >= frames
			}
		case .End:
			if no_session {
				return true
			}
		}
		time.sleep(CONDITION_POLL_PERIOD)
	}
	return false
}

// peer_display_close ends the session of a viewer, and waits for its end.
@(private = "file")
peer_display_close :: proc(state: ^Peer_Remote_Display) -> bool {
	sync.mutex_lock(&state.lock)
	if state.active {
		quic.connection_close(&state.client, u64(protocol.Display_Error.None), peer_display_now(state))
	}
	sync.mutex_unlock(&state.lock)
	return peer_display_wait(state, .End)
}

// peer_display_begin asks for a new session with a private key: its first
// bytes are Session_Start, or start_bytes when a case gives them. hold:
// the viewer takes no viewer frame.
@(private = "file")
peer_display_begin :: proc(state: ^Peer_Remote_Display, private_key: [32]u8, hold := false, start_bytes: []u8 = nil) -> bool {
	peer_display_key_set(state, private_key)
	if !peer_display_close(state) {
		return false
	}
	sync.mutex_lock(&state.lock)
	state.wanted = true
	// The thread of the peer clears the session when it starts the new
	// connection, later: until then a wait for frames must not count the
	// frames of the session before, or it ends before the new one exists.
	state.frames_taken = 0
	state.hold_frames = hold
	state.start_bytes_length = copy(state.start_bytes[:], start_bytes)
	sync.mutex_unlock(&state.lock)
	return true
}

// peer_display_session asks for a new session, and waits for its first
// whole viewer frame, or its end.
@(private = "file")
peer_display_session :: proc(state: ^Peer_Remote_Display, private_key: [32]u8, hold := false) -> bool {
	return peer_display_begin(state, private_key, hold) && peer_display_wait(state, .Frames, 1)
}

// peer_display_end_text says how the last session ended, in the temporary
// memory.
@(private = "file")
peer_display_end_text :: proc(state: ^Peer_Remote_Display) -> string {
	sync.mutex_lock(&state.lock)
	defer sync.mutex_unlock(&state.lock)
	if state.client_refused {
		return "the service refused the key in the handshake (access_denied)"
	}
	if state.handshake_timeout {
		return "the handshake did not end before its deadline: the service had no record for the client"
	}
	name := state.close_is_application ? protocol.display_error_name(state.close_code) : "a code of the transport"
	return fmt.tprintf("the connection ended (by the service: %v) with the code %d (%s)%s%s", state.closed_by_peer, state.close_code, name, state.refusal != "" ? "; the viewer refused: " : "", state.refusal)
}

// peer_display_ended_with says if the last session ended with a code of the
// service.
@(private = "file")
peer_display_ended_with :: proc(state: ^Peer_Remote_Display, code: protocol.Display_Error) -> bool {
	sync.mutex_lock(&state.lock)
	defer sync.mutex_unlock(&state.lock)
	return state.ended && state.closed_by_peer && state.close_is_application && state.close_code == u64(code)
}

// peer_display_send_and_end queues bytes on the open session, then waits
// for its end.
@(private = "file")
peer_display_send_and_end :: proc(state: ^Peer_Remote_Display, bytes: []u8) -> bool {
	sync.mutex_lock(&state.lock)
	queued := state.active && peer_display_queue_bytes(state, bytes)
	sync.mutex_unlock(&state.lock)
	return queued && peer_display_wait(state, .End)
}

// peer_display_record_bytes gives the bytes of one record, in the temporary
// memory.
@(private = "file")
peer_display_record_bytes :: proc(kind: protocol.Record_Kind, body: $T) -> []u8 {
	out := make([]u8, protocol.RECORD_HEADER_SIZE + size_of(T), context.temp_allocator)
	bytes, _ := protocol.record_write(out, kind, body)
	return bytes
}

// peer_display_header_bytes gives the bytes of a header alone, with any
// kind word and any length, in the temporary memory.
@(private = "file")
peer_display_header_bytes :: proc(kind_word: u32, length: u32) -> []u8 {
	// The words go into the bytes as a viewer sends them: a kind word that
	// names no member is the case that the service must refuse, so it never
	// becomes a Record_Kind here.
	#assert(protocol.RECORD_HEADER_SIZE == 8 && offset_of(protocol.Record_Header, kind) == 0 && offset_of(protocol.Record_Header, length) == 4)
	out := make([]u8, protocol.RECORD_HEADER_SIZE + int(min(length, 64)), context.temp_allocator)
	endian.unchecked_put_u32le(out[0:4], kind_word)
	endian.unchecked_put_u32le(out[4:8], length)
	return out
}

// peer_display_compare compares the screen that the viewer rebuilt with a
// picture of QEMU, outside the rectangle of the pointer, which the viewer
// draws itself. It gives the count of the pixels that differ, or -1 when
// the two do not have one size.
@(private = "file")
peer_display_compare :: proc(shown: []u32, screen: protocol.Screen, pointer: protocol.Pointer_Place_Body, dump: Screen_Dump) -> (different: int, compared: int) {
	if dump.width != int(screen.width) || dump.height != int(screen.height) {
		return -1, 0
	}
	for y in 0 ..< dump.height {
		for x in 0 ..< dump.width {
			if u32(x) >= pointer.left && u32(x) < pointer.right && u32(y) >= pointer.top && u32(y) < pointer.bottom {
				continue
			}
			color := shown[y * dump.width + x]
			place := (y * dump.width + x) * 3
			compared += 1
			if dump.pixels[place] != u8(color >> 16) || dump.pixels[place + 1] != u8(color >> 8) || dump.pixels[place + 2] != u8(color) {
				different += 1
			}
		}
	}
	return different, compared
}

// peer_display_compare_run compares the screen of a viewer with pictures
// of QEMU until one pair is of the same moment. The screen of the viewer
// must come from a viewer frame after the frame after_frames, so that the
// comparison reads pixels of the damage and not only of the first whole
// frame. The rectangle of the pointer that it excludes is at most the
// largest pointer picture.
@(private = "file")
peer_display_compare_run :: proc(machine: ^Machine, state: ^Peer_Remote_Display, after_frames: u64) -> (passed: bool, result: string) {
	start := time.tick_now()
	attempts := 0
	// One copy for each try, in one buffer: a try costs the pixels of a
	// screen.
	shown: [dynamic]u32
	defer delete(shown)
	for time.tick_since(start) < foundation.HANG_BOUND {
		sync.mutex_lock(&state.lock)
		screen, pointer, frames, active := state.screen, state.shown_pointer, state.frames_taken, state.active
		resize(&shown, int(screen.width) * int(screen.height))
		copy(shown[:], state.shown[:int(screen.width) * int(screen.height)])
		sync.mutex_unlock(&state.lock)
		if !active {
			return false, fmt.tprintf("the session ended: %s", peer_display_end_text(state))
		}
		if frames <= after_frames {
			time.sleep(CONDITION_POLL_PERIOD)
			continue
		}
		if pointer.right - pointer.left > PEER_DISPLAY_POINTER_LIMIT || pointer.bottom - pointer.top > PEER_DISPLAY_POINTER_LIMIT {
			return false, fmt.tprintf("the rectangle of the pointer %v is larger than a pointer picture of %d pixels", pointer, PEER_DISPLAY_POINTER_LIMIT)
		}
		attempts += 1
		dump, dumped := screen_dump_read(machine)
		if !dumped {
			return false, "QEMU gave no picture of the screen"
		}
		different, compared := peer_display_compare(shown[:], screen, pointer, dump)
		dump_width, dump_height := dump.width, dump.height
		delete(dump.file)
		if different == -1 {
			return false, fmt.tprintf("the picture of QEMU is %dx%d, and the viewer has %dx%d", dump_width, dump_height, screen.width, screen.height)
		}
		if different == 0 {
			return true, fmt.tprintf("the screen that the viewer rebuilt from %d viewer frames is the picture of QEMU, %d pixels outside the pointer at (%d, %d), after %d tries", frames, compared, pointer.x, pointer.y, attempts)
		}
		time.sleep(CONDITION_POLL_PERIOD)
	}
	return false, fmt.tprintf("in %d tries, the screen of the viewer was never the picture of QEMU of the same moment", attempts)
}

// peer_display_frames gives the count of the viewer frames of a viewer.
@(private = "file")
peer_display_frames :: proc(state: ^Peer_Remote_Display) -> u64 {
	sync.mutex_lock(&state.lock)
	defer sync.mutex_unlock(&state.lock)
	return state.frames_taken
}

// peer_display_refusal_case starts a session, sends bytes on it, and checks
// that the service ends it with a code.
@(private = "file")
peer_display_refusal_case :: proc(state: ^Peer_Remote_Display, key: [32]u8, what: string, bytes: []u8, code: protocol.Display_Error) -> (passed: bool, result: string) {
	if !peer_display_session(state, key) {
		return false, fmt.tprintf("no session: %s", peer_display_end_text(state))
	}
	if !peer_display_send_and_end(state, bytes) || !peer_display_ended_with(state, code) {
		return false, fmt.tprintf("%s: %s", what, peer_display_end_text(state))
	}
	return true, fmt.tprintf("%s: the service ended the connection with the code %s", what, protocol.DISPLAY_ERROR_NAMES[code])
}

// remote_display_case_run runs one case of the viewers of `remote_display`
// and says if it passed.
remote_display_case_run :: proc(machine: ^Machine, name: string) -> (passed: bool, result: string) {
	state := machine.peer.display_viewers[0]
	viewer_key := peer_display_viewer_key(PEER_DISPLAY_VIEWER_KEY_FIRST)
	if strings.has_prefix(name, "ask ") {
		return peer_display_ask_case(state, viewer_key, name[len("ask "):])
	}
	switch name {
	case "unknown key":
		// A key that no principal allowed: the handshake ends with
		// access_denied, before any viewer frame.
		peer_display_session(state, peer_display_viewer_key(PEER_DISPLAY_STRANGER_KEY_FIRST))
		peer_display_key_set(state, viewer_key)
		sync.mutex_lock(&state.lock)
		refused, frames := state.client_refused, state.frames_taken
		sync.mutex_unlock(&state.lock)
		if !refused || frames != 0 {
			return false, fmt.tprintf("a key that no principal allowed: %s, and %d viewer frames", peer_display_end_text(state), frames)
		}
		return true, "a viewer key that no principal allowed: the handshake ended with access_denied, and no viewer frame came"
	case "before session start":
		// A key in place of Session_Start: the service writes nothing
		// before Session_Start, so no viewer frame comes.
		if !peer_display_begin(state, viewer_key, false, peer_display_record_bytes(.Key, protocol.Key_Body{code = display.KEY_ESCAPE, pressed = 1})) || !peer_display_wait(state, .End) || !peer_display_ended_with(state, .Bad_Record) {
			return false, fmt.tprintf("a key before Session_Start: %s", peer_display_end_text(state))
		}
		return true, "a key before Session_Start: the service ended the connection with the code Bad_Record"
	case "second session start":
		return peer_display_refusal_case(state, viewer_key, "a second Session_Start", peer_display_record_bytes(.Session_Start, protocol.Session_Start_Body{version = protocol.PROTOCOL_VERSION}), .Bad_Record)
	case "taken out of order":
		return peer_display_refusal_case(state, viewer_key, "a Viewer_Frame_Taken of no viewer frame in flight", peer_display_record_bytes(.Viewer_Frame_Taken, protocol.Viewer_Frame_Taken_Body{serial = 1 << 40}), .Out_Of_Order)
	case "unknown kind":
		// The word between the two directions names no kind.
		return peer_display_refusal_case(state, viewer_key, "a record whose kind names no record", peer_display_header_bytes(u32(protocol.Record_Kind.Screen_Size_Refused) + 1, 8), .Bad_Record)
	case "other direction":
		return peer_display_refusal_case(state, viewer_key, "a Screen_Size from the viewer", peer_display_record_bytes(.Screen_Size, protocol.Screen_Size_Body{1, 1}), .Bad_Record)
	case "damaged request":
		if !peer_display_session(state, viewer_key) {
			return false, fmt.tprintf("no session: %s", peer_display_end_text(state))
		}
		sync.mutex_lock(&state.lock)
		screen := state.screen
		sync.mutex_unlock(&state.lock)
		request := protocol.Screen_Piece_Request_Body{x = screen.width - 1, y = 0, width = 2, height = 1}
		if !peer_display_send_and_end(state, peer_display_record_bytes(.Screen_Piece_Request, request)) || !peer_display_ended_with(state, .Bad_Record) {
			return false, fmt.tprintf("a screen piece request one pixel past the screen: %s", peer_display_end_text(state))
		}
		return true, "a screen piece request one pixel past the screen: the service ended the connection with the code Bad_Record"
	case "past bound":
		return peer_display_refusal_case(state, viewer_key, fmt.tprintf("the header of a key of %d bytes, one past the bound, before any byte of its body", protocol.VIEWER_BODY_LIMIT + 1), peer_display_header_bytes(u32(protocol.Record_Kind.Key), protocol.VIEWER_BODY_LIMIT + 1)[:protocol.RECORD_HEADER_SIZE], .Too_Large)
	case "input from a key of the view":
		return peer_display_refusal_case(state, viewer_key, "a key from a viewer key of the view alone", peer_display_record_bytes(.Key, protocol.Key_Body{code = display.KEY_SUPER, pressed = 1}), .Input_Not_Allowed)
	case "never takes its frame":
		// The viewer takes no viewer frame: the service ends the session at
		// the take bound.
		if !peer_display_session(state, viewer_key, true) || !peer_display_wait(state, .End) || !peer_display_ended_with(state, .Timeout) {
			return false, fmt.tprintf("a viewer that takes no viewer frame: %s", peer_display_end_text(state))
		}
		return true, "a viewer that took no viewer frame: the service ended the connection with the code Timeout"
	case "a viewer past the capacity":
		// The viewers of the capacity at one time; the one past it gets no
		// record of the server, and its handshake ends at its deadline.
		viewers := machine.peer.display_viewers[:protocol.CONNECTION_CAPACITY]
		past := machine.peer.display_viewers[protocol.CONNECTION_CAPACITY]
		for viewer, number in viewers {
			if !peer_display_session(viewer, viewer_key) {
				return false, fmt.tprintf("viewer %d of %d at one time: %s", number + 1, protocol.CONNECTION_CAPACITY, peer_display_end_text(viewer))
			}
		}
		if !peer_display_begin(past, viewer_key) || !peer_display_wait(past, .End) {
			return false, "the viewer past the capacity did not end"
		}
		sync.mutex_lock(&past.lock)
		timeout, frames := past.handshake_timeout, past.frames_taken
		sync.mutex_unlock(&past.lock)
		if !timeout || frames != 0 {
			return false, fmt.tprintf("the viewer past the capacity: %s, with %d viewer frames", peer_display_end_text(past), frames)
		}
		for viewer, number in viewers {
			if peer_display_frames(viewer) == 0 {
				return false, fmt.tprintf("viewer %d took no viewer frame", number + 1)
			}
		}
		#reverse for viewer in viewers {
			if !peer_display_close(viewer) {
				return false, "the viewers of the capacity did not end"
			}
		}
		return true, fmt.tprintf("%d viewers took viewer frames at one time; the one past them got no record of the server, and its handshake ended at its deadline", protocol.CONNECTION_CAPACITY)
	case "view":
		if !peer_display_session(state, viewer_key) {
			return false, fmt.tprintf("no whole viewer frame came: %s", peer_display_end_text(state))
		}
		sync.mutex_lock(&state.lock)
		screen, bytes, spent, whole := state.screen, state.whole_bytes, state.whole_time, state.whole_measured
		sync.mutex_unlock(&state.lock)
		if !whole {
			return false, "the first viewer frame was not the whole screen"
		}
		fmt.printfln("modustool: measure: the remote display: a whole screen of %dx%d in one viewer frame: %d bytes of screen pieces for %d bytes of pixels (%.1f %%), %.1f ms from its Viewer_Frame_Start to its Viewer_Frame_End at the viewer", screen.width, screen.height, bytes, u64(screen.width) * u64(screen.height) * 4, f64(bytes) * 100 / f64(u64(screen.width) * u64(screen.height) * 4), f64(spent) / f64(time.Millisecond))
		return true, fmt.tprintf("the viewer took the whole screen of %dx%d in its first viewer frame", screen.width, screen.height)
	case "compare":
		// After the first whole viewer frame: a viewer frame of the damage
		// must come before the comparison.
		return peer_display_compare_run(machine, state, 1)
	case "pointer over the clock":
		// The pointer of the viewer over the clock of the bar, which
		// changes each second: the pixels of the clock around the pointer
		// must be the pixels of the screen, with no pointer in them.
		sync.mutex_lock(&state.lock)
		screen := state.screen
		x, y := screen.width - 90, u32(12)
		queued := state.active && peer_display_queue(state, .Pointer, protocol.Pointer_Body{x = x, y = y})
		sync.mutex_unlock(&state.lock)
		if !queued {
			return false, fmt.tprintf("the pointer did not go: %s", peer_display_end_text(state))
		}
		// The compositor moves the pointer to the logical pixel that holds
		// the pixel of the viewer, and names the pixel of the screen of that
		// logical pixel: the place to wait for.
		logical_x, _ := logical_place_of_screen(int(x), MACHINE_SCALE)
		logical_y, _ := logical_place_of_screen(int(y), MACHINE_SCALE)
		shown_x, _ := screen_place_of_logical(logical_x, MACHINE_SCALE)
		shown_y, _ := screen_place_of_logical(logical_y, MACHINE_SCALE)
		start := time.tick_now()
		for time.tick_since(start) < foundation.HANG_BOUND {
			sync.mutex_lock(&state.lock)
			place, frames := state.shown_pointer, state.frames_taken
			sync.mutex_unlock(&state.lock)
			if int(place.x) == shown_x && int(place.y) == shown_y {
				return peer_display_compare_run(machine, state, frames)
			}
			time.sleep(CONDITION_POLL_PERIOD)
		}
		return false, "no viewer frame named the place of the pointer over the clock"
	case "small frames":
		// The clock of the bar damages a small rectangle each second.
		start := time.tick_now()
		for time.tick_since(start) < foundation.HANG_BOUND {
			sync.mutex_lock(&state.lock)
			count := state.small_count
			sync.mutex_unlock(&state.lock)
			if count == PEER_DISPLAY_SMALL_FRAMES {
				break
			}
			time.sleep(CONDITION_POLL_PERIOD)
		}
		sync.mutex_lock(&state.lock)
		count := state.small_count
		bytes := state.small_bytes
		times := state.small_times
		frames, last_pixels, smallest_pixels, screen := state.frames_taken, state.last_frame_pixels, state.smallest_frame_pixels, state.screen
		sync.mutex_unlock(&state.lock)
		if count < PEER_DISPLAY_SMALL_FRAMES {
			return false, fmt.tprintf("%d viewer frames of a small damage (at most %d pixels) came, not %d; the viewer took %d viewer frames in all, the smallest after the whole screen of %d pixels, the last of %d", count, protocol.small_damage_pixels(screen.width, screen.height), PEER_DISPLAY_SMALL_FRAMES, frames, smallest_pixels, last_pixels)
		}
		slice.sort(bytes[:])
		slice.sort(times[:])
		fmt.printfln("modustool: measure: the remote display: a viewer frame of a small damage (the median of %d): %d bytes of screen pieces, %.1f us from its Viewer_Frame_Start to its Viewer_Frame_End at the viewer", count, bytes[count / 2], f64(times[count / 2]) / f64(time.Microsecond))
		return true, fmt.tprintf("%d viewer frames of a small damage, of %d to %d bytes", count, bytes[0], bytes[count - 1])
	case "same session":
		// An allow that adds the input keeps the serial of the row: the
		// session goes on, on its connection, and takes viewer frames.
		sync.mutex_lock(&state.lock)
		active, made, frames := state.active, state.connections_made, state.frames_taken
		sync.mutex_unlock(&state.lock)
		if !active || !peer_display_wait(state, .Frames, frames + 1) {
			return false, fmt.tprintf("the session did not go on after the allow: %s", peer_display_end_text(state))
		}
		sync.mutex_lock(&state.lock)
		still_made := state.connections_made
		sync.mutex_unlock(&state.lock)
		if still_made != made {
			return false, "the allow made a new connection"
		}
		return true, "the allow of the input kept the session: the same connection took a new viewer frame"
	case "super", "escape":
		if !state.active && !peer_display_session(state, viewer_key) {
			return false, fmt.tprintf("no session: %s", peer_display_end_text(state))
		}
		code: u32 = name == "super" ? display.KEY_SUPER : display.KEY_ESCAPE
		sync.mutex_lock(&state.lock)
		queued := state.active && peer_display_queue(state, .Key, protocol.Key_Body{code = code, pressed = 1}) && peer_display_queue(state, .Key, protocol.Key_Body{code = code, pressed = 0})
		sync.mutex_unlock(&state.lock)
		if !queued {
			return false, fmt.tprintf("the key did not go: %s", peer_display_end_text(state))
		}
		return true, fmt.tprintf("the viewer sent the key %s, pressed and released", name)
	case "hold a frame":
		// A viewer frame in flight: the viewer holds the next one.
		sync.mutex_lock(&state.lock)
		state.hold_frames = true
		frames := state.frames_taken
		sync.mutex_unlock(&state.lock)
		if !peer_display_wait(state, .Frames, frames + 1) {
			return false, fmt.tprintf("no viewer frame came to hold: %s", peer_display_end_text(state))
		}
		return true, "a viewer frame is in flight: the viewer does not take it"
	case "revoked":
		// The scenario revoked the key, or put another session in front,
		// while the session was open.
		if !peer_display_wait(state, .End) || !peer_display_ended_with(state, .Revoked) {
			return false, fmt.tprintf("the session of the revoked key: %s", peer_display_end_text(state))
		}
		peer_display_session(state, viewer_key)
		sync.mutex_lock(&state.lock)
		refused := state.client_refused
		sync.mutex_unlock(&state.lock)
		if !refused {
			return false, fmt.tprintf("a new session with the revoked key: %s", peer_display_end_text(state))
		}
		return true, "the service ended the open session of the key with the code Revoked, and refused the key in the next handshake"
	}
	return false, fmt.tprintf("no case \"%s\" of remote_display", name)
}

// peer_display_ask_case runs a case of the size of a screen of memory
// (src/md/features/screen_of_memory.md), on the open session of viewer 0
// or a new one. The words after "ask ":
//   "<width>x<height>": the service sends Screen_Size of that size, then
//   the whole screen in the first viewer frame of the size;
//   "<width>x<height> refused <cause>": the service sends
//   Screen_Size_Refused with that size and that cause, and the session
//   goes on;
//   "<width>x<height> ends <code>": the connection ends with that code: a
//   size past the bounds ends with Bad_Record, an ask of a viewer with the
//   view alone with Input_Not_Allowed.
@(private = "file")
peer_display_ask_case :: proc(state: ^Peer_Remote_Display, viewer_key: [32]u8, words: string) -> (passed: bool, result: string) {
	fields := strings.fields(words, context.temp_allocator)
	size := len(fields) > 0 ? strings.split(fields[0], "x", context.temp_allocator) : nil
	if len(size) != 2 {
		return false, fmt.tprintf("the case \"ask %s\" names no size", words)
	}
	width, width_ok := strconv.parse_u64(size[0])
	height, height_ok := strconv.parse_u64(size[1])
	if !width_ok || !height_ok || width > u64(max(u32)) || height > u64(max(u32)) {
		return false, fmt.tprintf("the case \"ask %s\" names no size", words)
	}
	ask := protocol.Screen_Size_Body{u32(width), u32(height)}
	if !state.active && !peer_display_session(state, viewer_key) {
		return false, fmt.tprintf("no session: %s", peer_display_end_text(state))
	}
	if len(fields) == 3 && fields[1] == "ends" {
		code, named := protocol.Display_Error(0), false
		for member in protocol.Display_Error {
			if protocol.DISPLAY_ERROR_NAMES[member] == fields[2] {
				code, named = member, true
			}
		}
		if !named {
			return false, fmt.tprintf("the case \"ask %s\" names no code", words)
		}
		if !peer_display_send_and_end(state, peer_display_record_bytes(.Screen_Size_Ask, ask)) || !peer_display_ended_with(state, code) {
			return false, fmt.tprintf("an ask of %dx%d: %s", width, height, peer_display_end_text(state))
		}
		return true, fmt.tprintf("an ask of %dx%d: the service ended the connection with the code %s", width, height, fields[2])
	}
	sync.mutex_lock(&state.lock)
	state.size_refused = false
	sizes_before := state.screen_sizes
	queued := state.active && peer_display_queue(state, .Screen_Size_Ask, ask)
	sync.mutex_unlock(&state.lock)
	if !queued {
		return false, fmt.tprintf("the ask did not go: %s", peer_display_end_text(state))
	}
	refused := len(fields) == 3 && fields[1] == "refused"
	start := time.tick_now()
	for time.tick_since(start) < foundation.HANG_BOUND {
		sync.mutex_lock(&state.lock)
		active, screen, sizes, frames, whole := state.active, state.screen, state.screen_sizes, state.frames_at_size, state.first_frame_whole
		size_refused, refusal := state.size_refused, state.size_refusal
		sync.mutex_unlock(&state.lock)
		if !active {
			return false, fmt.tprintf("the session ended: %s", peer_display_end_text(state))
		}
		switch {
		case refused && size_refused:
			cause := fmt.tprintf("%v", memory_screen.Resize_Refusal(refusal.refusal))
			if refusal.width != ask.width || refusal.height != ask.height || cause != fields[2] {
				return false, fmt.tprintf("the ask of %dx%d was refused for %dx%d with the cause %s, not %s", width, height, refusal.width, refusal.height, cause, fields[2])
			}
			return true, fmt.tprintf("the ask of %dx%d got Screen_Size_Refused with the cause %s, and the session goes on", width, height, cause)
		case !refused && size_refused && memory_screen.Resize_Refusal(refusal.refusal) == .Too_Soon:
			// The least time between two changes: the viewer asks again until
			// the service takes the ask, within the bound of the case.
			sync.mutex_lock(&state.lock)
			state.size_refused = false
			asked_again := state.active && peer_display_queue(state, .Screen_Size_Ask, ask)
			sync.mutex_unlock(&state.lock)
			if !asked_again {
				return false, fmt.tprintf("the ask did not go again: %s", peer_display_end_text(state))
			}
		case !refused && size_refused:
			return false, fmt.tprintf("the ask of %dx%d was refused with the cause %v", width, height, memory_screen.Resize_Refusal(refusal.refusal))
		case !refused && sizes > sizes_before && screen == {ask.width, ask.height} && frames > 0:
			if !whole {
				return false, fmt.tprintf("the first viewer frame of %dx%d was not the whole screen", width, height)
			}
			return true, fmt.tprintf("the viewer asked %dx%d, received Screen_Size of that size, and the whole screen in the next viewer frame", width, height)
		}
		time.sleep(CONDITION_POLL_PERIOD)
	}
	return false, fmt.tprintf("no answer to the ask of %dx%d came in %v", width, height, foundation.HANG_BOUND)
}
