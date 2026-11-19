package machine

import "core:encoding/hex"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "modus:contract/errors"
import protocol "modus:contract/remote_display"
import "modus:support/display"
import "modus:support/quic"
import "modus:support/random"
import "modustool:foundation"
import "modustool:fuzz"

// The peer as the first viewer of `remote_display`
// (src/md/features/remote_display.md; docs/QUIC.md, "8. The remote
// display"). The thread of the peer holds one QUIC connection to the
// service with the key of the viewer, opens its one stream, writes
// Session_Start, then reads the records of the screen through the border
// of the contract, rebuilds the screen from the tiles, and takes each
// frame. A record that the border refuses ends the connection with the
// code Bad_Record, as a viewer must.
//
// The cases of the machine test (remote_display_case_run) start a session,
// wait for its frames, compare the screen that the viewer rebuilt with a
// picture of QEMU of the same moment, and send what a viewer must not send:
// each refusal is checked by the code of the end of the connection.

PEER_DISPLAY_PORT_FIRST :: 44000 // The local UDP port of the first connection; one more for each next one.
// The first byte of the fixed private key of the viewer of a machine test;
// each next byte is one more. The key protects nothing but the test.
PEER_DISPLAY_VIEWER_KEY_FIRST :: 0x61
// The first byte of a private key that no principal allows.
PEER_DISPLAY_STRANGER_KEY_FIRST :: 0x7a
// The mark of a step that the tool replaces with the public key of the
// viewer of the peer: remote_display_allow("{viewer key}", "view").
VIEWER_KEY_MARK :: "{viewer key}"
// The frames of a small damage that the measure line takes, at most.
PEER_DISPLAY_SMALL_FRAMES :: 5
// A frame of a small damage: at most this many pixels.
PEER_DISPLAY_SMALL_PIXELS :: 64 * 64

Peer_Remote_Display :: struct {
	lock:              sync.Mutex, // Each field below: the thread of the peer and the thread of the scenario read them.
	cryptography:      quic.Cryptography,
	generator:         random.Generator,
	configuration:     quic.Connection_Configuration,
	pinned:            bool,
	client_public_key: [32]u8,
	client:            quic.Connection,
	streams:           []quic.Stream,
	wanted:            bool, // A case asked for a session: the next tick starts its connection.
	active:            bool, // The client holds a connection that did not end.
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
	refusal:           string, // Why this viewer refused a record of the service: a constant text.
	// The records that the viewer writes, as the stream takes them.
	outgoing:          [256]u8,
	outgoing_length:   int,
	outgoing_written:  int,
	session_started:   bool,
	// The record of the service that is being read: copied once, then its
	// border reads the copy.
	incoming:          []u8,
	incoming_count:    int,
	tile_pixels:       []u32,
	// The screen that the viewer rebuilds, and the screen of its last
	// whole frame.
	screen:            protocol.Screen,
	pixels:            []u32,
	shown:             []u32,
	shown_pointer:     protocol.Pointer_Place_Body,
	pointer:           protocol.Pointer_Place_Body,
	in_frame:          bool,
	frame_serial:      u64,
	tiles_left:        u32,
	frames_taken:      u64,
	hold_frames:       bool, // A case keeps the frame in flight: no Frame_Taken goes.
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
}

peer_display_make :: proc() -> ^Peer_Remote_Display {
	state := new(Peer_Remote_Display)
	state.streams = make([]quic.Stream, 1)
	state.incoming = make([]u8, protocol.RECORD_HEADER_SIZE + protocol.TILE_BODY_LIMIT)
	state.tile_pixels = make([]u32, protocol.TILE_PIXEL_LIMIT)
	state.pixels = make([]u32, protocol.SCREEN_WIDTH_LIMIT * protocol.SCREEN_HEIGHT_LIMIT)
	state.shown = make([]u32, protocol.SCREEN_WIDTH_LIMIT * protocol.SCREEN_HEIGHT_LIMIT)
	state.cryptography = fuzz.quic_cryptography_of_the_host()
	seed: [random.SEED_SIZE]u8
	for index in 0 ..< random.SEED_SIZE {
		seed[index] = u8(0x31 + index)
	}
	random.generator_seed(&state.generator, &seed, .Processor)
	state.configuration = {idle_timeout_milliseconds = 30_000}
	state.configuration.tls = {role = .Client, least_seed_strength = .Processor}
	state.configuration.tls.application_protocol_length = copy(state.configuration.tls.application_protocol[:], protocol.APPLICATION_PROTOCOL)
	private_key: [32]u8
	for index in 0 ..< len(private_key) {
		private_key[index] = u8(PEER_DISPLAY_VIEWER_KEY_FIRST + index)
	}
	peer_display_key_set(state, private_key)
	state.next_port = PEER_DISPLAY_PORT_FIRST
	state.start = time.tick_now()
	return state
}

peer_display_free :: proc(state: ^Peer_Remote_Display) {
	if state == nil {
		return
	}
	delete(state.streams)
	delete(state.incoming)
	delete(state.tile_pixels)
	delete(state.pixels)
	delete(state.shown)
	free(state)
}

peer_display_now :: proc(state: ^Peer_Remote_Display) -> u64 {
	return u64(time.tick_since(state.start) / time.Microsecond) + 1
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

// peer_display_datagram takes a datagram of the service to the peer.
peer_display_datagram :: proc(peer: ^Peer, destination: [4]u8, port: u16, data: []u8) {
	state := peer.display_viewer
	if state == nil || destination != PEER_ADDRESS {
		return
	}
	sync.mutex_lock(&state.lock)
	defer sync.mutex_unlock(&state.lock)
	if !state.active || port != state.port {
		return
	}
	error: errors.Error_Record
	quic.connection_datagram_receive(&state.client, data, peer_display_now(state), &error)
}

// peer_display_queue adds a record to the bytes that the viewer writes.
// false: the bytes are full. The lock is held.
peer_display_queue :: proc(state: ^Peer_Remote_Display, kind: protocol.Record_Kind, body: $T) -> bool {
	bytes, ok := protocol.record_write(state.outgoing[state.outgoing_length:], kind, body)
	if !ok {
		return false
	}
	state.outgoing_length += len(bytes)
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
	case .None, .Frame_Taken, .Tile_Request, .Key, .Pointer, .Session_Start:
		peer_display_refuse(state, "a record of the other direction")
	case .Screen_Size:
		state.screen = {record.screen_size.width, record.screen_size.height}
	case .Pointer_Place:
		state.pointer = record.pointer_place
	case .Frame_Start:
		if state.in_frame || state.screen.width == 0 {
			peer_display_refuse(state, "a Frame_Start in a frame, or before Screen_Size")
			return
		}
		state.in_frame = true
		state.frame_serial = record.frame_start.serial
		state.tiles_left = record.frame_start.tile_count
		state.frame_started = time.tick_now()
		state.frame_bytes, state.frame_pixels = 0, 0
	case .Tile:
		tile := record.tile
		if !state.in_frame || state.tiles_left == 0 {
			peer_display_refuse(state, "a tile past the count of its frame")
			return
		}
		count := int(tile.width * tile.height)
		// The tile goes into memory of its own: a damaged tile changes
		// nothing of the screen.
		if problem := protocol.tile_decode(record.coded, state.tile_pixels[:count]); problem != .None {
			peer_display_refuse(state, protocol.TILE_PROBLEM_SENTENCES[problem])
			return
		}
		width, tile_width := int(state.screen.width), int(tile.width)
		for row in 0 ..< int(tile.height) {
			copy(state.pixels[(int(tile.y) + row) * width + int(tile.x):][:tile_width], state.tile_pixels[row * tile_width:][:tile_width])
		}
		state.tiles_left -= 1
		state.frame_bytes += u64(length)
		state.frame_pixels += u64(count)
	case .Frame_End:
		if !state.in_frame || record.frame_end.serial != state.frame_serial || state.tiles_left != 0 {
			peer_display_refuse(state, "a Frame_End of another frame, or before the last tile")
			return
		}
		state.in_frame = false
		spent := time.tick_since(state.frame_started)
		pixel_count := int(state.screen.width) * int(state.screen.height)
		copy(state.shown[:pixel_count], state.pixels[:pixel_count])
		state.shown_pointer = state.pointer
		state.frames_taken += 1
		if !state.whole_measured && state.frame_pixels == u64(pixel_count) {
			state.whole_measured = true
			state.whole_bytes, state.whole_time = state.frame_bytes, spent
		} else if state.frame_pixels > 0 && state.frame_pixels <= PEER_DISPLAY_SMALL_PIXELS && state.small_count < PEER_DISPLAY_SMALL_FRAMES {
			state.small_bytes[state.small_count] = state.frame_bytes
			state.small_times[state.small_count] = spent
			state.small_count += 1
		}
		if !state.hold_frames {
			peer_display_queue(state, .Frame_Taken, protocol.Frame_Taken_Body{serial = state.frame_serial})
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

// peer_display_tick runs the session of the viewer: its connection, its
// stream, its records, the timers. The thread of the peer calls it.
peer_display_tick :: proc(peer: ^Peer) {
	state := peer.display_viewer
	if state == nil {
		return
	}
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
		state.client_refused = client.closed_by_peer && !client.close_is_application && client.close_error_code == quic.CRYPTO_ERROR_BASE + u64(quic.Alert.Access_Denied)
	}
	if state.wanted && !state.active && state.pinned {
		state.wanted = false
		state.ended, state.close_code, state.close_is_application, state.closed_by_peer, state.client_refused = false, 0, false, false, false
		state.refusal = ""
		state.has_stream, state.session_started = false, false
		state.outgoing_length, state.outgoing_written, state.incoming_count = 0, 0, 0
		state.screen = {}
		state.in_frame, state.frames_taken = false, 0
		state.port = state.next_port
		state.next_port += 1
		error: errors.Error_Record
		if quic.connection_start_client(client, state.streams, &state.configuration, &state.cryptography, &state.generator, now, &error) {
			state.active = true
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
			state.session_started = peer_display_queue(state, .Session_Start, protocol.Session_Start_Body{version = protocol.PROTOCOL_VERSION})
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
	Frames, // The viewer took a count of frames, or the session ended.
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

// peer_display_session asks for a new session with a private key, and
// waits for its first whole frame, or its end.
@(private = "file")
peer_display_session :: proc(state: ^Peer_Remote_Display, private_key: [32]u8) -> bool {
	peer_display_key_set(state, private_key)
	sync.mutex_lock(&state.lock)
	if state.active {
		quic.connection_close(&state.client, u64(protocol.Display_Error.None), peer_display_now(state))
	}
	sync.mutex_unlock(&state.lock)
	if !peer_display_wait(state, .End) {
		return false
	}
	sync.mutex_lock(&state.lock)
	state.wanted = true
	state.hold_frames = false
	sync.mutex_unlock(&state.lock)
	return peer_display_wait(state, .Frames, 1)
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

// peer_display_viewer_key gives the private key of the viewer of a machine
// test.
@(private = "file")
peer_display_viewer_key :: proc(first: u8) -> (key: [32]u8) {
	for index in 0 ..< len(key) {
		key[index] = first + u8(index)
	}
	return key
}

// peer_display_record_bytes gives the bytes of one record, in the temporary
// memory.
@(private = "file")
peer_display_record_bytes :: proc(kind: protocol.Record_Kind, body: $T) -> []u8 {
	out := make([]u8, protocol.RECORD_HEADER_SIZE + size_of(T), context.temp_allocator)
	bytes, _ := protocol.record_write(out, kind, body)
	return bytes
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

// remote_display_case_run runs one case of the viewer of `remote_display`
// and says if it passed.
remote_display_case_run :: proc(machine: ^Machine, name: string) -> (passed: bool, result: string) {
	state := machine.peer.display_viewer
	viewer_key := peer_display_viewer_key(PEER_DISPLAY_VIEWER_KEY_FIRST)
	switch name {
	case "unknown key":
		// A key that no principal allowed: the handshake ends with
		// access_denied, before any frame.
		stranger := peer_display_viewer_key(PEER_DISPLAY_STRANGER_KEY_FIRST)
		peer_display_session(state, stranger)
		peer_display_key_set(state, viewer_key)
		sync.mutex_lock(&state.lock)
		refused, frames := state.client_refused, state.frames_taken
		sync.mutex_unlock(&state.lock)
		if !refused || frames != 0 {
			return false, fmt.tprintf("a key that no principal allowed: %s, and %d frames", peer_display_end_text(state), frames)
		}
		return true, "a viewer key that no principal allowed: the handshake ended with access_denied, and no frame came"
	case "view":
		if !peer_display_session(state, viewer_key) {
			return false, fmt.tprintf("no whole frame came: %s", peer_display_end_text(state))
		}
		sync.mutex_lock(&state.lock)
		screen, bytes, spent, whole := state.screen, state.whole_bytes, state.whole_time, state.whole_measured
		sync.mutex_unlock(&state.lock)
		if !whole {
			return false, "the first frame was not the whole screen"
		}
		fmt.printfln("modustool: measure: the remote display: a whole screen of %dx%d in one frame: %d bytes of tiles for %d bytes of pixels (%.1f %%), %.1f ms from its Frame_Start to its Frame_End at the viewer", screen.width, screen.height, bytes, u64(screen.width) * u64(screen.height) * 4, f64(bytes) * 100 / f64(u64(screen.width) * u64(screen.height) * 4), f64(spent) / f64(time.Millisecond))
		return true, fmt.tprintf("the viewer took the whole screen of %dx%d in its first frame", screen.width, screen.height)
	case "compare":
		// The screen of the viewer after a whole frame, and a picture of
		// QEMU: the clock of the bar changes each second, so the case takes
		// both again until one pair is of the same moment.
		start := time.tick_now()
		attempts := 0
		// One copy for each try, in one buffer: a try costs the pixels of a
		// screen.
		shown := make([]u32, protocol.SCREEN_WIDTH_LIMIT * protocol.SCREEN_HEIGHT_LIMIT)
		defer delete(shown)
		for time.tick_since(start) < foundation.HANG_BOUND {
			attempts += 1
			sync.mutex_lock(&state.lock)
			screen, pointer := state.screen, state.shown_pointer
			copy(shown, state.shown[:int(screen.width) * int(screen.height)])
			active := state.active
			sync.mutex_unlock(&state.lock)
			if !active {
				return false, fmt.tprintf("the session ended: %s", peer_display_end_text(state))
			}
			dump, dumped := screen_dump_read(machine)
			if !dumped {
				return false, "QEMU gave no picture of the screen"
			}
			different, compared := peer_display_compare(shown, screen, pointer, dump)
			dump_width, dump_height := dump.width, dump.height
			delete(dump.file)
			if different == -1 {
				return false, fmt.tprintf("the picture of QEMU is %dx%d, and the viewer has %dx%d", dump_width, dump_height, screen.width, screen.height)
			}
			if different == 0 {
				return true, fmt.tprintf("the screen that the viewer rebuilt is the picture of QEMU, %d pixels outside the pointer, after %d tries", compared, attempts)
			}
			time.sleep(10 * CONDITION_POLL_PERIOD)
		}
		return false, fmt.tprintf("in %d tries, the screen of the viewer was never the picture of QEMU of the same moment", attempts)
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
			time.sleep(10 * CONDITION_POLL_PERIOD)
		}
		sync.mutex_lock(&state.lock)
		count := state.small_count
		bytes := state.small_bytes
		times := state.small_times
		sync.mutex_unlock(&state.lock)
		if count < PEER_DISPLAY_SMALL_FRAMES {
			return false, fmt.tprintf("%d frames of a small damage came, not %d", count, PEER_DISPLAY_SMALL_FRAMES)
		}
		slice.sort(bytes[:])
		slice.sort(times[:])
		fmt.printfln("modustool: measure: the remote display: a frame of a small damage (the median of %d): %d bytes of tiles, %.1f us from its Frame_Start to its Frame_End at the viewer", count, bytes[count / 2], f64(times[count / 2]) / f64(time.Microsecond))
		return true, fmt.tprintf("%d frames of a small damage, of %d to %d bytes", count, bytes[0], bytes[count - 1])
	case "input from a key of the view":
		key := protocol.Key_Body{code = display.KEY_SUPER, pressed = 1}
		if !peer_display_send_and_end(state, peer_display_record_bytes(.Key, key)) || !peer_display_ended_with(state, .Input_Not_Allowed) {
			return false, fmt.tprintf("a key from a key of the view alone: %s", peer_display_end_text(state))
		}
		return true, "a key from a viewer key of the view alone: the service ended the connection with the code Input_Not_Allowed"
	case "damaged request":
		if !peer_display_session(state, viewer_key) {
			return false, fmt.tprintf("no session: %s", peer_display_end_text(state))
		}
		sync.mutex_lock(&state.lock)
		screen := state.screen
		sync.mutex_unlock(&state.lock)
		request := protocol.Tile_Request_Body{x = screen.width - 1, y = 0, width = 2, height = 1}
		if !peer_display_send_and_end(state, peer_display_record_bytes(.Tile_Request, request)) || !peer_display_ended_with(state, .Bad_Record) {
			return false, fmt.tprintf("a tile request one pixel past the screen: %s", peer_display_end_text(state))
		}
		return true, "a tile request one pixel past the screen: the service ended the connection with the code Bad_Record"
	case "past bound":
		if !peer_display_session(state, viewer_key) {
			return false, fmt.tprintf("no session: %s", peer_display_end_text(state))
		}
		header := protocol.Record_Header{kind = .Key, length = protocol.VIEWER_BODY_LIMIT + 1}
		bytes := transmute([protocol.RECORD_HEADER_SIZE]u8)header
		if !peer_display_send_and_end(state, bytes[:]) || !peer_display_ended_with(state, .Too_Large) {
			return false, fmt.tprintf("a key of %d bytes: %s", protocol.VIEWER_BODY_LIMIT + 1, peer_display_end_text(state))
		}
		return true, fmt.tprintf("the header of a key of %d bytes, one past the bound: the service ended the connection with the code Too_Large before any byte of its body", protocol.VIEWER_BODY_LIMIT + 1)
	case "super", "escape":
		if name == "super" && !peer_display_session(state, viewer_key) {
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
	case "revoked":
		// The scenario revoked the key while the session was open.
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
		return true, "the service ended the open session of the revoked key with the code Revoked, and refused the key in the next handshake"
	}
	return false, fmt.tprintf("no case \"%s\" of remote_display", name)
}
