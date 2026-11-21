// The remote display: the screen of the machine for a viewer on another
// machine, and the keys and the pointer of that viewer
// (src/md/features/remote_display.md; docs/QUIC.md, "8. The remote
// display").
//
// QUIC in the process (src/library/modus/quic), over a datagram endpoint
// with a listen grant of UDP on the port remote_display.LISTEN_PORT that
// admits the address of the host only, as `remote` has. The viewer proves
// its own Ed25519 key in the handshake (mutual TLS 1.3 with raw public
// keys), and this process takes it only when the client table that the
// root service writes has a row for it whose uses hold View. Each
// connection is bound to its row: when the grant of the row ends, or when
// the row loses View, the connection ends with the code Revoked.
//
// The viewer opens one bidirectional stream. This process writes the
// screen in its direction: Screen_Size, then viewer frames of screen pieces from its copy
// of the screen, one viewer frame in flight. The viewer writes Viewer_Frame_Taken, a
// Screen_Piece_Request, and, for a row that holds Input, its keys and its pointer,
// which go to the compositor on the ring of the window of this process
// (modus:contract/remote_display). A record that its border refuses ends the
// connection with Bad_Record, a record past its bound with Too_Large, and a
// key of a row of the view alone with Input_Not_Allowed.
//
// The capture face of the compositor: while a viewer is connected, this
// process gives the compositor the memory of two pictures and a header
// (display.Capture_Open), copies the rectangles of each Capture_Frame into
// its own copy of the screen, and gives the picture back. It copies only
// while no viewer is in the middle of a viewer frame, so that each viewer frame shows one
// moment: a slow viewer delays the copy, never the compositor, which merges
// the damage while the picture is held. With no viewer, it closes the face,
// and the mark of a viewer leaves the bar.
//
// **Start**: `start("remote_display")` in the console. Read the public key
// on the log. Then allow the key of the viewer from a console that acts for
// the principal: `remote_display_allow("<key>", "view")`, or
// `"view_and_input"`.
//
// **Grants**, as the root service gives them:
//
// - **Network**: a listen grant of UDP on port 7101 for the address
//   10.0.2.2 only. The process refuses any other grant.
// - **Remote_Clients**: the client table, read-only.
// - **Screen_Capture**: the capture face and the input face of the
//   compositor, on the ring of its window. It opens no surface.
//
// **What it proves**: the screen reaches another machine only for a key
// that a principal allowed for the view, the keys of that machine reach
// the desktop only for a key allowed for the input, and the bar shows each
// session.
package remote_display_service

import "base:intrinsics"
import "modus:contract/datagram"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/pointer_pictures"
import "modus:contract/remote"
import protocol "modus:contract/remote_display"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:interface"
import "modus:network"
import "modus:quic"
import "modus:random"
import "modus:system"

// The copy of the screen of the largest screen, the two pictures and the
// header of the capture face, the QUIC connections and their streams, and
// the page tables of these mappings:
// 2025 + 4051 + about 300 + 24 = 6400.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 6400, processes = 1, threads = 1}

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

CAPACITY :: protocol.CONNECTION_CAPACITY
// One stream for each viewer: the server gives the client one stream.
STREAMS_PER_CONNECTION :: 1
CONNECTION_BYTES :: CAPACITY * size_of(quic.Connection)
STREAM_BYTES :: CAPACITY * STREAMS_PER_CONNECTION * size_of(quic.Stream)
TABLE_PAGES :: (CONNECTION_BYTES + STREAM_BYTES + system.PAGE_SIZE - 1) / system.PAGE_SIZE
IDLE_TIMEOUT_MILLISECONDS :: 30_000

// The bounds of a viewer frame, in milliseconds of the machine: its records must go
// into the stream, and the viewer must take it, this long after the phase
// started; else the connection ends with the code Timeout.
VIEWER_FRAME_WRITE_LIMIT :: 10_000
VIEWER_FRAME_TAKEN_LIMIT :: 10_000
// The write bound while another viewer waits: the copy of the screen waits
// for the viewer frame that is written, so one viewer holds the other back for
// this long at most.
VIEWER_FRAME_WRITE_LIMIT_SHARED :: 2_000
// A record of the viewer that came in part must be whole this long after
// its first byte: a viewer that stops in the middle of a record ends here,
// not at the idle timeout of QUIC.
RECORD_READ_LIMIT :: 10_000

// The datagram region: 256 places of 2048 bytes, as `remote`.
PLACE_SIZE :: 2048
PLACE_COUNT :: datagram.REGION_PAGES * system.PAGE_SIZE / PLACE_SIZE
RECEIVE_PLACES :: 64
SEND_TAG :: 1000
CALL_TAG :: 100_000
VALIDATE_TAG :: u32(1) << 31
VALIDATE_PLACE_BITS :: 4
VALIDATE_GENERATION_MASK :: (u64(1) << (31 - VALIDATE_PLACE_BITS)) - 1
#assert(CAPACITY <= 1 << VALIDATE_PLACE_BITS)
HELD_CAPACITY :: PLACE_COUNT + 2 * RECEIVE_PLACES + CAPACITY

// The records to the compositor that its ring did not take: the commands of
// the capture face, and the keys and the pointer of the viewers. While it is
// full, this process reads no record of a viewer: a full ring stops the
// writer, and no key is dropped.
COMPOSITOR_HOLD_CAPACITY :: 64
LOG_LIMIT :: 50 // Lines of connections and of refusals in one second at most.
// The viewer frames of a small damage that one measure line takes: the median of
// 21, as the other measures of the system.
SMALL_VIEWER_FRAME_SAMPLES :: 21
// A viewer frame of a small damage: at most this many pixels.
SMALL_VIEWER_FRAME_PIXELS :: 64 * 64

process_generator: random.Generator
server: quic.Server
records: [CAPACITY]quic.Server_Record
quic_connections: []quic.Connection
streams: []quic.Stream
public_key: [32]u8
listen_port: u16
local_address: u32

endpoint: ring.Ring
region: []u8
free_places: [PLACE_COUNT - RECEIVE_PLACES]u32
free_count: int
held_commands: [HELD_CAPACITY]ring.Record
held_command_count: int
log_second: u64
log_count: u64

// The ring of the window of this process: the capture face and the input
// face of the compositor ride it.
window_memory: system.Handle
window: ring.Ring
Compositor_Held :: struct {
	record:            ring.Record,
	viewer_place:      int, // The viewer of a key or a pointer record; -1: a command of the face.
	viewer_generation: u64,
}
compositor_held: [COMPOSITOR_HOLD_CAPACITY]Compositor_Held
compositor_held_count: int

// The client table that the root service writes, and the copy of its rows
// of this pass.
client_table: ^remote.Client_Table
client_rows: [remote.CLIENT_CAPACITY]remote.Client
client_table_version_seen: u32

// The capture face.
Capture_State :: enum u8 {
	Closed, // No viewer: no face.
	Asking, // Capture_Size_Ask went; the size did not come.
	Open, // The memory went with Capture_Open.
}
capture_state: Capture_State
screen: protocol.Screen
capture_memory: system.Handle
capture_mapped: rawptr
capture_header: ^display.Capture_Header
capture_pictures: [display.PICTURE_COUNT][^]u32
// The picture of the last Capture_Frame, which this process holds until it
// copied it: -1, none.
held_picture := -1
// The copy of the screen: each viewer codes its screen pieces from it.
mirror: [^]u32
mirror_memory: system.Handle
mirror_pixels: int
mirror_valid: bool // The first record of the face, the whole screen, is in the copy.
pointer_place: protocol.Pointer_Place_Body
pointer_shape: protocol.Pointer_Shape_Body
pointer_shape_valid: bool
captures: u64 // The records of the compositor that went into the copy.

// What one viewer is at in its viewer frame.
Viewer_Frame_Step :: enum u8 {
	None, // No viewer frame: the viewer waits for damage, or took the last viewer frame.
	Pointer_Shape, // The shape of the pointer goes first when it changed.
	Pointer_Warp, // A machine-initiated cursor move goes before the frame.
	Pointer_Place, // The place of the pointer goes before the frame, when it moved.
	Viewer_Frame_Start,
	Screen_Pieces,
	Viewer_Frame_End,
	In_Flight, // Viewer_Frame_End went: the viewer takes the viewer frame.
}

Viewer :: struct {
	place:      int, // The place of its record in the server, and of this viewer.
	generation: u64, // The generation of the record of the binding.
	bound:      bool,
	ended:      bool, // The connection was closed by this process: nothing binds it again.
	row:        int,
	serial:     u64,
	principal:  u64,
	key:        [32]u8,
	input:      bool, // The row held Input at the last pass.
	stream:     u64,
	has_stream: bool,
	// The record of the viewer that is being read: its header, then its
	// body. The bytes are copied once, and the border reads the copy.
	incoming:       [protocol.RECORD_HEADER_SIZE + protocol.VIEWER_BODY_LIMIT]u8,
	incoming_count: int,
	// The record of this process that is being written to the stream.
	outgoing:         [protocol.RECORD_HEADER_SIZE + protocol.SCREEN_PIECE_BODY_LIMIT]u8,
	outgoing_length:  int,
	outgoing_written: int,
	session_started:  bool, // Session_Start came: the first record of the viewer.
	size_sent:        bool,
	damage:           interface.Damage, // The rectangles that the viewer does not have.
	merges:           u64, // Rectangles that joined another because the damage set was full.
	viewer_frame:            interface.Damage, // The rectangles of the viewer frame that goes.
	viewer_frame_step:       Viewer_Frame_Step,
	viewer_frame_serial:     u64,
	viewer_frame_rectangle:  int,
	viewer_frame_piece:       u32,
	viewer_frame_pieces:      u32,
	viewer_frame_pixels:     u64,
	viewer_frame_bytes:      u64,
	viewer_frame_coded_time: u64, // Nanoseconds of the screen piece coder in this viewer frame.
	step_started_at:  u64, // Milliseconds of the machine: the start of the write bound or of the take bound.
	read_started_at:  u64, // Milliseconds of the machine: the first byte of the record that is read.
	viewer_frame_started_at: u64, // Nanoseconds: Viewer_Frame_Start went into the stream.
	pointer_sent:           protocol.Pointer_Place_Body,
	pointer_shape_sent:     protocol.Pointer_Shape_Body,
	pointer_shape_has_sent: bool,
	pointer_warp_pending:   bool,
	input_received_count:   u64,
	input_echo_count:       u64,
	frames:                 u64,
	whole_logged:           bool,
}
viewers: [CAPACITY]Viewer

// The measure of the viewer frames of a small damage, in the machine.
small_viewer_frame_bytes: [SMALL_VIEWER_FRAME_SAMPLES]u64
small_viewer_frame_times: [SMALL_VIEWER_FRAME_SAMPLES]u64
small_viewer_frame_count: int
small_viewer_frames_logged: bool

fail :: proc "contextless" (text: string) -> ! {
	system.log_fact(.Error, Service_Failed{failure = value_kinds.text_field(text, FAILURE_FIELD_BYTES)})
	system.stop(.Failed)
}

now_microseconds :: proc "contextless" () -> u64 {
	return system.nanoseconds() / 1000
}

place_bytes :: proc "contextless" (place: u32) -> []u8 {
	return region[int(place) * PLACE_SIZE:][:PLACE_SIZE]
}

command_push_or_hold :: proc "contextless" (record: ring.Record) {
	if held_command_count == 0 && ring.push(&endpoint.commands, record) {
		return
	}
	if held_command_count == HELD_CAPACITY {
		fail("the held commands passed their bound")
	}
	held_commands[held_command_count] = record
	held_command_count += 1
}

held_commands_push :: proc "contextless" () {
	done := 0
	for done < held_command_count && ring.push(&endpoint.commands, held_commands[done]) {
		done += 1
	}
	copy(held_commands[:], held_commands[done:held_command_count])
	held_command_count -= done
}

post :: proc "contextless" (place: u32) {
	command_push_or_hold(ring.Record{kind = u32(datagram.Command.Receive), tag = place, values = {0 = u64(place) * PLACE_SIZE, 1 = PLACE_SIZE}})
}

data_bytes :: proc "contextless" (place: u32) -> []u8 {
	return place_bytes(place)[network.UDP_HEADER:]
}

send :: proc "contextless" (place: u32, length: int, peer: quic.Remote) {
	whole := network.udp_header_write(place_bytes(place), local_address, peer.address, listen_port, peer.port, length)
	command_push_or_hold(ring.Record{kind = u32(datagram.Command.Send), tag = SEND_TAG + place, values = {0 = u64(place) * PLACE_SIZE, 1 = u64(whole), 2 = u64(peer.address)}})
}

validate :: proc "contextless" (peer: quic.Remote, place: int) {
	tag := VALIDATE_TAG | u32(records[place].generation & VALIDATE_GENERATION_MASK) << VALIDATE_PLACE_BITS | u32(place)
	command_push_or_hold(ring.Record{kind = u32(datagram.Command.Validate), tag = tag, values = {0 = u64(peer.address), 1 = u64(peer.port)}})
}

validation_completed :: proc "contextless" (completion: ring.Record) {
	place := int(completion.tag & ((1 << VALIDATE_PLACE_BITS) - 1))
	generation_bits := u64(completion.tag & ~VALIDATE_TAG) >> VALIDATE_PLACE_BITS
	if place >= CAPACITY || !records[place].in_use || records[place].generation & VALIDATE_GENERATION_MASK != generation_bits {
		return
	}
	quic.server_validation_confirmed(&server, place, records[place].generation, datagram.Status(completion.kind) == .Ok && completion.values[0] == 1)
}

release :: proc "contextless" (peer: quic.Remote) {
	command_push_or_hold(ring.Record{kind = u32(datagram.Command.Release), tag = CALL_TAG, values = {0 = u64(peer.address), 1 = u64(peer.port)}})
}

place_take :: proc "contextless" () -> (place: u32, ok: bool) {
	if free_count == 0 {
		return 0, false
	}
	free_count -= 1
	return free_places[free_count], true
}

hex_text :: proc "contextless" (buffer: []u8, bytes: []u8) -> string {
	digits := "0123456789abcdef"
	count := 0
	for byte in bytes {
		if count + 2 > len(buffer) {
			break
		}
		buffer[count], buffer[count + 1] = digits[byte >> 4], digits[byte & 0x0F]
		count += 2
	}
	return string(buffer[:count])
}

address_text :: proc "contextless" (buffer: []u8, peer: quic.Remote) -> string {
	writer := system.Writer{buffer = buffer}
	network.address_write(&writer, peer.address)
	system.write_bytes(&writer, transmute([]u8)string(" port "))
	system.write_unsigned(&writer, u64(peer.port))
	return system.written(&writer)
}

log_allowed :: proc "contextless" () -> bool {
	second := system.time() / 1000
	if second != log_second {
		log_second, log_count = second, 0
	}
	log_count += 1
	return log_count <= LOG_LIMIT
}

// compositor_send gives a record to the compositor, after the records that
// its ring did not take, in their order.
// A key or a pointer of a viewer carries the place and the generation of
// that viewer; a command of the capture face carries none (place -1).
compositor_send :: proc "contextless" (record: ring.Record, viewer_place: int = -1, viewer_generation: u64 = 0) {
	if compositor_held_count == 0 && system.send(&window.commands, record) {
		return
	}
	if compositor_held_count == COMPOSITOR_HOLD_CAPACITY {
		// The readers of the viewers stop while the hold is full, and the
		// commands of the face are a few: this does not happen.
		fail("the records to the compositor passed their bound")
	}
	compositor_held[compositor_held_count] = {record = record, viewer_place = viewer_place, viewer_generation = viewer_generation}
	compositor_held_count += 1
}

compositor_held_push :: proc "contextless" () {
	done := 0
	for done < compositor_held_count && system.send(&window.commands, compositor_held[done].record) {
		done += 1
	}
	copy(compositor_held[:], compositor_held[done:compositor_held_count])
	compositor_held_count -= done
}

// compositor_held_drop takes out the keys and the pointer records of one
// viewer that wait for room in the window ring: the end of a viewer ends
// its input at once. The commands of the face stay, in their order.
compositor_held_drop :: proc "contextless" (viewer_place: int, viewer_generation: u64) -> (dropped: int) {
	kept := 0
	for held in compositor_held[:compositor_held_count] {
		if held.viewer_place == viewer_place && held.viewer_generation == viewer_generation {
			dropped += 1
			continue
		}
		compositor_held[kept] = held
		kept += 1
	}
	compositor_held_count = kept
	return dropped
}

// client_key_allowed is the check of the handshake: the client proved this
// key, and a principal allowed it for the view, in a row whose grant holds.
client_key_allowed :: proc "contextless" (key: ^[32]u8) -> bool {
	rows: [remote.CLIENT_CAPACITY]remote.Client
	remote.client_table_read(client_table, &rows)
	proven := key^
	row := remote.client_find(&rows, proven)
	if row >= 0 && remote.client_grant_holds(&rows, row, rows[row].serial, .View) {
		return true
	}
	if log_allowed() {
		system.log_fact(.Info, Viewer_Key_Refused{viewer_key = key_field(proven)})
	}
	return false
}

// viewer_close ends the session of a viewer: its connection, and its keys
// and pointer records that wait for room in the window ring. A record that
// is in the ring already cannot be taken back.
viewer_close :: proc "contextless" (connection: ^quic.Connection, viewer: ^Viewer, code: protocol.Display_Error) {
	viewer.ended = true
	viewer.bound = false
	quic.connection_close(connection, u64(code), now_microseconds())
	if dropped := compositor_held_drop(viewer.place, viewer.generation); dropped > 0 && log_allowed() {
		system.log_fact(.Info, Viewer_Input_Records_Dropped{dropped = u64(dropped), viewer_key_head = key_head_field(viewer.key)})
	}
}

// viewer_bind binds a record whose handshake ended to the row of its key.
viewer_bind :: proc "contextless" (connection: ^quic.Connection, viewer: ^Viewer, peer: quic.Remote) {
	key := connection.tls.client_public_key
	row := remote.client_find(&client_rows, key)
	if row < 0 || !remote.client_grant_holds(&client_rows, row, client_rows[row].serial, .View) {
		viewer_close(connection, viewer, .Revoked)
		if log_allowed() {
			system.log_fact(.Info, Viewer_Key_Grant_Ended_In_Handshake{viewer_key_head = key_head_field(key), peer = peer_field(peer)})
		}
		return
	}
	viewer.bound, viewer.row, viewer.serial, viewer.principal, viewer.key = true, row, client_rows[row].serial, client_rows[row].principal, key
	viewer.input = remote.client_grant_holds(&client_rows, row, viewer.serial, .Input)
	// The first viewer frame is the whole screen.
	viewer.damage = {}
	interface.damage_add(&viewer.damage, {0, 0, int(protocol.SCREEN_WIDTH_LIMIT), int(protocol.SCREEN_HEIGHT_LIMIT)})
	if viewer.input {
		system.log_fact(.Info, Viewer_Key_Proved_With_Input{principal = viewer.principal, viewer_key_head = key_head_field(key), peer = peer_field(peer)})
	} else {
		system.log_fact(.Info, Viewer_Key_Proved_Without_Input{principal = viewer.principal, viewer_key_head = key_head_field(key), peer = peer_field(peer)})
	}
	viewers_tell()
}

// viewers_tell gives the compositor the viewers that the mark of the bar
// names: the first bytes of each key, and which ones have the input.
viewers_tell :: proc "contextless" () {
	if capture_state != .Open {
		return
	}
	record := ring.Record{kind = u32(display.Command.Capture_Viewers)}
	count := 0
	for viewer in viewers {
		if !viewer.bound || count == display.CAPTURE_VIEWER_CAPACITY {
			continue
		}
		head := viewer.key
		record.values[2 + count] = transmute(u64)[8]u8{head[0], head[1], head[2], head[3], head[4], head[5], head[6], head[7]}
		if viewer.input {
			record.values[1] |= 1 << u64(count)
		}
		count += 1
	}
	record.values[0] = u64(count)
	compositor_send(record)
}

// viewer_grant_check ends the connection of a viewer whose grant ended, in
// the middle of a viewer frame too, and follows a change of its input.
viewer_grant_check :: proc "contextless" (connection: ^quic.Connection, viewer: ^Viewer, peer: quic.Remote) {
	if !remote.client_grant_holds(&client_rows, viewer.row, viewer.serial, .View) {
		viewer_close(connection, viewer, .Revoked)
		if log_allowed() {
			system.log_fact(.Info, Viewer_Key_Grant_Ended{principal = viewer.principal, viewer_key_head = key_head_field(viewer.key), peer = peer_field(peer)})
		}
		viewers_tell()
		return
	}
	input := remote.client_grant_holds(&client_rows, viewer.row, viewer.serial, .Input)
	if input != viewer.input {
		viewer.input = input
		viewers_tell()
	}
}

// viewer_refuse ends the connection of a viewer that sent a record that its
// border refused, with one line.
viewer_refuse :: proc "contextless" (connection: ^quic.Connection, viewer: ^Viewer, code: protocol.Display_Error, why: string) {
	viewer_close(connection, viewer, code)
	if log_allowed() {
		system.log_fact(.Info, Viewer_Record_Refused{viewer_key_head = key_head_field(viewer.key), cause = value_kinds.text_field(why, RECORD_CAUSE_FIELD_BYTES), error_code = value_kinds.text_field(protocol.DISPLAY_ERROR_NAMES[code], ERROR_CODE_FIELD_BYTES)})
	}
	viewers_tell()
}

// viewer_read reads the records of a viewer, one whole record at a time:
// the header first, which its border checks before any byte of the body is
// read, then the body. It stops while the records to the compositor wait.
viewer_read :: proc "contextless" (connection: ^quic.Connection, viewer: ^Viewer) {
	for viewer.bound && compositor_held_count < COMPOSITOR_HOLD_CAPACITY / 2 {
		want := protocol.RECORD_HEADER_SIZE
		header: protocol.Record_Header
		if viewer.incoming_count >= protocol.RECORD_HEADER_SIZE {
			header, _ = protocol.header_read(viewer.incoming[:])
			want = protocol.RECORD_HEADER_SIZE + int(header.length)
		}
		count, finished, reset := quic.stream_read(connection, viewer.stream, viewer.incoming[viewer.incoming_count:want])
		if reset {
			viewer_close(connection, viewer, .None)
			viewers_tell()
			return
		}
		if viewer.incoming_count == 0 && count > 0 {
			viewer.read_started_at = system.time()
		}
		viewer.incoming_count += count
		// The header is checked once, by the read that completes it.
		if count > 0 && viewer.incoming_count == protocol.RECORD_HEADER_SIZE {
			header, _ = protocol.header_read(viewer.incoming[:])
			switch problem := protocol.record_length_problem(header, .To_Service); problem {
			case .None:
			case .Past_Bound:
				viewer_refuse(connection, viewer, .Too_Large, protocol.RECORD_PROBLEM_SENTENCES[problem])
				return
			case .Unknown_Kind, .Wrong_Direction, .Wrong_Length, .Outside_Screen, .Empty_Rectangle, .Bad_Field:
				viewer_refuse(connection, viewer, .Bad_Record, protocol.RECORD_PROBLEM_SENTENCES[problem])
				return
			}
			continue
		}
		if viewer.incoming_count > protocol.RECORD_HEADER_SIZE && viewer.incoming_count == protocol.RECORD_HEADER_SIZE + int(header.length) {
			record, problem := protocol.viewer_record_check(header, viewer.incoming[protocol.RECORD_HEADER_SIZE:viewer.incoming_count], screen)
			viewer.incoming_count = 0
			if problem != .None {
				viewer_refuse(connection, viewer, .Bad_Record, protocol.RECORD_PROBLEM_SENTENCES[problem])
				return
			}
			viewer_record_take(connection, viewer, record)
			continue
		}
		if finished && viewer.incoming_count == 0 {
			// The viewer ended its direction: the end of its session.
			viewer_close(connection, viewer, .None)
			viewers_tell()
			return
		}
		if count == 0 {
			return
		}
	}
}

// viewer_record_take does what a record of a viewer that its border took
// asks.
viewer_record_take :: proc "contextless" (connection: ^quic.Connection, viewer: ^Viewer, record: protocol.Viewer_Record) {
	if (record.kind == .Session_Start) == viewer.session_started {
		viewer_refuse(connection, viewer, .Bad_Record, viewer.session_started ? "a second Session_Start" : "a record before Session_Start")
		return
	}
	switch record.kind {
	case .None, .Screen_Size, .Viewer_Frame_Start, .Screen_Piece, .Viewer_Frame_End, .Pointer_Place, .Pointer_Shape, .Pointer_Picture, .Pointer_Warp:
		// The border took a record of the viewer only.
		viewer_refuse(connection, viewer, .Bad_Record, protocol.RECORD_PROBLEM_SENTENCES[.Wrong_Direction])
	case .Session_Start:
		viewer.session_started = true
	case .Viewer_Frame_Taken:
		if viewer.viewer_frame_step != .In_Flight || record.viewer_frame_taken.serial != viewer.viewer_frame_serial {
			viewer_refuse(connection, viewer, .Out_Of_Order, "a Viewer_Frame_Taken of no viewer frame in flight")
			return
		}
		viewer_frame_taken(viewer)
	case .Screen_Piece_Request:
		request := record.screen_piece_request
		viewer_damage_add(viewer, {int(request.x), int(request.y), int(request.x + request.width), int(request.y + request.height)})
	case .Key, .Pointer:
		if !remote.client_grant_holds(&client_rows, viewer.row, viewer.serial, .Input) {
			viewer_close(connection, viewer, .Input_Not_Allowed)
			if log_allowed() {
				system.log_fact(.Info, Viewer_Input_Not_Allowed{principal = viewer.principal, viewer_key_head = key_head_field(viewer.key)})
			}
			viewers_tell()
			return
		}
		viewer.input_received_count += 1
		if record.kind == .Key {
			key := record.key
			compositor_send({kind = u32(display.Command.Remote_Key), values = {0 = u64(key.code), 1 = u64(key.character), 2 = u64(key.pressed), 3 = u64(key.modifiers), 4 = u64(viewer.place), 5 = viewer.input_received_count, 6 = viewer.generation}}, viewer.place, viewer.generation)
		} else {
			pointer := record.pointer
			compositor_send({kind = u32(display.Command.Remote_Pointer), values = {0 = u64(pointer.x), 1 = u64(pointer.y), 2 = u64(pointer.buttons), 3 = u64(i64(pointer.wheel)), 4 = u64(viewer.place), 5 = viewer.input_received_count, 6 = viewer.generation}}, viewer.place, viewer.generation)
		}
	}
}

// viewer_damage_add adds a rectangle that the viewer does not have. A full
// set merges, and the merges are counted: the viewer receives more pixels,
// never fewer.
viewer_damage_add :: proc "contextless" (viewer: ^Viewer, rectangle: interface.Rectangle) {
	if viewer.damage.count == interface.DAMAGE_CAPACITY {
		viewer.merges += 1
	}
	interface.damage_add(&viewer.damage, rectangle)
}

// viewer_frame_taken ends a viewer frame that the viewer took, and takes its
// measures.
viewer_frame_taken :: proc "contextless" (viewer: ^Viewer) {
	viewer.viewer_frame_step = .None
	viewer.frames += 1
	taken_at := system.nanoseconds()
	spent := taken_at - min(viewer.viewer_frame_started_at, taken_at)
	if !viewer.whole_logged && viewer.viewer_frame_pixels == u64(screen.width) * u64(screen.height) {
		viewer.whole_logged = true
		system.log_fact(.Info, Whole_Screen_Measured{width = u64(screen.width), height = u64(screen.height), screen_pieces = u64(viewer.viewer_frame_pieces), piece_bytes = value_kinds.Size_In_Bytes(viewer.viewer_frame_bytes), pixel_bytes = value_kinds.Size_In_Bytes(viewer.viewer_frame_pixels * 4), coded_time = value_kinds.Time_In_Microseconds(viewer.viewer_frame_coded_time / 1000), taken_time = value_kinds.Time_In_Microseconds(spent / 1000)})
	}
	if viewer.viewer_frame_pixels > 0 && viewer.viewer_frame_pixels <= SMALL_VIEWER_FRAME_PIXELS && small_viewer_frame_count < SMALL_VIEWER_FRAME_SAMPLES {
		small_viewer_frame_bytes[small_viewer_frame_count] = viewer.viewer_frame_bytes
		small_viewer_frame_times[small_viewer_frame_count] = spent
		small_viewer_frame_count += 1
	}
	if small_viewer_frame_count == SMALL_VIEWER_FRAME_SAMPLES && !small_viewer_frames_logged {
		small_viewer_frames_logged = true
		median_sort(small_viewer_frame_bytes[:])
		median_sort(small_viewer_frame_times[:])
		system.log_fact(.Info, Small_Damage_Measured{pixels = u64(SMALL_VIEWER_FRAME_PIXELS), frames = u64(SMALL_VIEWER_FRAME_SAMPLES), median_size = value_kinds.Size_In_Bytes(small_viewer_frame_bytes[SMALL_VIEWER_FRAME_SAMPLES / 2]), median_time = value_kinds.Time_In_Microseconds(small_viewer_frame_times[SMALL_VIEWER_FRAME_SAMPLES / 2] / 1000), least_size = value_kinds.Size_In_Bytes(small_viewer_frame_bytes[0]), least_time = value_kinds.Time_In_Microseconds(small_viewer_frame_times[0] / 1000)})
	}
}

// median_sort sorts a few values in place: an insertion sort of 21.
median_sort :: proc "contextless" (values: []u64) {
	for index in 1 ..< len(values) {
		value := values[index]
		place := index
		for place > 0 && values[place - 1] > value {
			values[place] = values[place - 1]
			place -= 1
		}
		values[place] = value
	}
}

// viewer_next_record writes the next record of a viewer into its outgoing
// bytes. false: nothing to write now.
viewer_next_record :: proc "contextless" (viewer: ^Viewer) -> bool {
	viewer.outgoing_written = 0
	viewer.outgoing_length = 0
	if !viewer.size_sent {
		if !viewer.session_started || capture_state != .Open || screen.width == 0 {
			return false
		}
		bytes, _ := protocol.record_write(viewer.outgoing[:], .Screen_Size, protocol.Screen_Size_Body{screen.width, screen.height})
		viewer.outgoing_length = len(bytes)
		viewer.size_sent = true
		// The write bound starts with the first record of the service.
		viewer.step_started_at = system.time()
		return true
	}
	now := system.time()
	switch viewer.viewer_frame_step {
	case .In_Flight:
		return false
	case .None:
		if !mirror_valid || held_picture >= 0 || viewer.damage.count == 0 {
			// A picture that waits for its copy goes into the viewer frame first:
			// a viewer frame shows the newest moment.
			return false
		}
		// The viewer frame takes the damage of the viewer, cut to the screen.
		viewer.viewer_frame = {}
		viewer.viewer_frame_pieces, viewer.viewer_frame_pixels, viewer.viewer_frame_bytes, viewer.viewer_frame_coded_time = 0, 0, 0, 0
		for rectangle in viewer.damage.rectangles[:viewer.damage.count] {
			cut := interface.Rectangle{max(rectangle.left, 0), max(rectangle.top, 0), min(rectangle.right, int(screen.width)), min(rectangle.bottom, int(screen.height))}
			if cut.right <= cut.left || cut.bottom <= cut.top {
				continue
			}
			viewer.viewer_frame.rectangles[viewer.viewer_frame.count] = cut
			viewer.viewer_frame.count += 1
			viewer.viewer_frame_pieces += protocol.screen_piece_count(u32(cut.right - cut.left), u32(cut.bottom - cut.top))
			viewer.viewer_frame_pixels += u64(cut.right - cut.left) * u64(cut.bottom - cut.top)
		}
		viewer.damage = {}
		if viewer.merges > 0 && log_allowed() {
			system.log_fact(.Info, Viewer_Damage_Full{merges = viewer.merges, viewer_key_head = key_head_field(viewer.key)})
			viewer.merges = 0
		}
		if viewer.viewer_frame.count == 0 {
			return false
		}
		viewer.viewer_frame_serial += 1
		viewer.viewer_frame_rectangle, viewer.viewer_frame_piece = 0, 0
		viewer.viewer_frame_step = .Pointer_Shape
		viewer.step_started_at = now
		return viewer_next_record(viewer)
	case .Pointer_Shape:
		viewer.viewer_frame_step = .Pointer_Warp
		if pointer_shape_valid && (!viewer.pointer_shape_has_sent || viewer.pointer_shape_sent != pointer_shape) {
			bytes, _ := protocol.record_write(viewer.outgoing[:], .Pointer_Shape, pointer_shape)
			viewer.outgoing_length = len(bytes)
			viewer.pointer_shape_sent = pointer_shape
			viewer.pointer_shape_has_sent = true
			return true
		}
		return viewer_next_record(viewer)
	case .Pointer_Warp:
		viewer.viewer_frame_step = .Pointer_Place
		if viewer.pointer_warp_pending && pointer_place.x < screen.width && pointer_place.y < screen.height {
			viewer.pointer_warp_pending = false
			warp := protocol.Pointer_Warp_Body{x = pointer_place.x, y = pointer_place.y, input_echo_count = viewer.input_echo_count}
			bytes, _ := protocol.record_write(viewer.outgoing[:], .Pointer_Warp, warp)
			viewer.outgoing_length = len(bytes)
			return true
		}
		return viewer_next_record(viewer)
	case .Pointer_Place:
		viewer.viewer_frame_step = .Viewer_Frame_Start
		if viewer.pointer_sent != pointer_place {
			bytes, _ := protocol.record_write(viewer.outgoing[:], .Pointer_Place, pointer_place)
			viewer.outgoing_length = len(bytes)
			viewer.pointer_sent = pointer_place
			return true
		}
		return viewer_next_record(viewer)
	case .Viewer_Frame_Start:
		start := protocol.Viewer_Frame_Start_Body{
			serial             = viewer.viewer_frame_serial,
			screen_piece_count = viewer.viewer_frame_pieces,
			bytes              = 0,
			input_echo_count   = viewer.input_echo_count,
		}
		// The bytes of the screen pieces are known when they are coded: the
		// header gives the bound of the viewer frame, its screen pieces at their worst.
		start.bytes = u64(viewer.viewer_frame_pieces) * (protocol.RECORD_HEADER_SIZE + size_of(protocol.Screen_Piece_Header)) + viewer.viewer_frame_pixels * protocol.CODED_PIXEL_LIMIT
		bytes, _ := protocol.record_write(viewer.outgoing[:], .Viewer_Frame_Start, start)
		viewer.outgoing_length = len(bytes)
		viewer.viewer_frame_step = .Screen_Pieces
		viewer.viewer_frame_started_at = system.nanoseconds()
		return true
	case .Screen_Pieces:
		if viewer.viewer_frame_rectangle >= viewer.viewer_frame.count {
			viewer.viewer_frame_step = .Viewer_Frame_End
			return viewer_next_record(viewer)
		}
		rectangle := viewer.viewer_frame.rectangles[viewer.viewer_frame_rectangle]
		width, height := u32(rectangle.right - rectangle.left), u32(rectangle.bottom - rectangle.top)
		x, y, piece_width, piece_height := protocol.screen_piece_at(u32(rectangle.left), u32(rectangle.top), width, height, viewer.viewer_frame_piece)
		coded_start := system.nanoseconds()
		bytes, written := protocol.screen_piece_record_write(viewer.outgoing[:], mirror[:mirror_pixels], int(screen.width), x, y, piece_width, piece_height)
		viewer.viewer_frame_coded_time += system.nanoseconds() - coded_start
		if !written {
			// The bytes hold the worst code of a whole screen piece: this does not
			// happen.
			fail("a screen piece did not fit its record")
		}
		viewer.outgoing_length = len(bytes)
		viewer.viewer_frame_bytes += u64(len(bytes))
		viewer.viewer_frame_piece += 1
		if viewer.viewer_frame_piece == protocol.screen_piece_count(width, height) {
			viewer.viewer_frame_rectangle += 1
			viewer.viewer_frame_piece = 0
		}
		return true
	case .Viewer_Frame_End:
		bytes, _ := protocol.record_write(viewer.outgoing[:], .Viewer_Frame_End, protocol.Viewer_Frame_End_Body{serial = viewer.viewer_frame_serial})
		viewer.outgoing_length = len(bytes)
		viewer.viewer_frame_step = .In_Flight
		viewer.step_started_at = now
		return true
	}
	return false
}

// viewer_write writes the records of a viewer into its stream, as the
// stream takes them.
viewer_write :: proc "contextless" (connection: ^quic.Connection, viewer: ^Viewer) {
	for viewer.bound {
		if viewer.outgoing_written < viewer.outgoing_length {
			viewer.outgoing_written += quic.stream_write(connection, viewer.stream, viewer.outgoing[viewer.outgoing_written:viewer.outgoing_length], false)
			if viewer.outgoing_written < viewer.outgoing_length {
				return
			}
		}
		if !viewer_next_record(viewer) {
			return
		}
	}
}

// viewer_writing says if a viewer is in the middle of a viewer frame: its screen pieces
// come from the copy of the screen, which must not change under them.
viewer_writing :: proc "contextless" (viewer: ^Viewer) -> bool {
	switch viewer.viewer_frame_step {
	case .Pointer_Shape, .Pointer_Warp, .Pointer_Place, .Viewer_Frame_Start, .Screen_Pieces, .Viewer_Frame_End:
		return true
	case .None, .In_Flight:
		return viewer.outgoing_written < viewer.outgoing_length
	}
	return false
}

// viewers_work moves each viewer: its binding, its grant, its stream, its
// records, and the bounds of its viewer frame.
viewers_work :: proc "contextless" () {
	client_table_version_seen = intrinsics.atomic_load_explicit(&client_table.version, .Acquire)
	remote.client_table_read(client_table, &client_rows)
	now := system.time()
	for record, place in records {
		viewer := &viewers[place]
		if !record.in_use || viewer.generation != record.generation {
			// The client of the place ended, or another one took it: the
			// input of the one before goes nowhere.
			compositor_held_drop(place, viewer.generation)
			was_bound := viewer.bound
			viewer^ = {place = place, generation = record.in_use ? record.generation : 0}
			if was_bound {
				viewers_tell()
			}
			if !record.in_use {
				continue
			}
		}
		connection := &quic_connections[place]
		if connection.state == .Closed && viewer.bound {
			viewer.bound = false
			compositor_held_drop(place, viewer.generation)
			viewers_tell()
		}
		if connection.state != .Connected {
			continue
		}
		switch {
		case !viewer.bound && !viewer.ended:
			viewer_bind(connection, viewer, record.remote)
		case viewer.bound:
			viewer_grant_check(connection, viewer, record.remote)
		}
		if !viewer.bound {
			continue
		}
		if !viewer.has_stream {
			for &stream in connection.streams {
				if stream.in_use {
					viewer.stream, viewer.has_stream = stream.identifier, true
				}
			}
			if !viewer.has_stream {
				continue
			}
		}
		viewer_read(connection, viewer)
		viewer_write(connection, viewer)
		if !viewer.bound {
			continue
		}
		bound, limit := viewer_bound_of(viewer)
		if bound == .None || now - min(viewer_bound_start(viewer, bound), now) < limit {
			continue
		}
		viewer_close(connection, viewer, .Timeout)
		if log_allowed() {
			system.log_fact(.Info, Viewer_Bound_Passed{bound = value_kinds.Time_In_Milliseconds(limit), viewer_key_head = key_head_field(viewer.key), missed_step = value_kinds.text_field(VIEWER_BOUND_SENTENCES[bound], MISSED_STEP_FIELD_BYTES)})
		}
		viewers_tell()
	}
}

// The bound of time that a viewer is under, each with its own start and
// its own line.
Viewer_Bound :: enum u8 {
	None, // The viewer waits for damage: no bound.
	Write, // A record of the service goes into the stream: Screen_Size, or a viewer frame up to Viewer_Frame_End.
	Take, // Viewer_Frame_End went: the viewer must send Viewer_Frame_Taken.
	Read, // A record of the viewer came in part: the rest must come.
}

@(rodata)
VIEWER_BOUND_SENTENCES := [Viewer_Bound]string {
	.None  = "has no bound",
	.Write = "did not let the stream take the records of its viewer frame",
	.Take  = "did not take its viewer frame",
	.Read  = "did not send the rest of its record",
}

// viewer_bound_of gives the bound that a viewer is under now, and its
// length in milliseconds. The write bound is shorter while another viewer
// waits for the copy of the screen, which a viewer frame that is written holds
// back.
viewer_bound_of :: proc "contextless" (viewer: ^Viewer) -> (bound: Viewer_Bound, limit: u64) {
	switch {
	case viewer.incoming_count > 0:
		return .Read, RECORD_READ_LIMIT
	case viewer.viewer_frame_step == .In_Flight && viewer.outgoing_written == viewer.outgoing_length:
		return .Take, VIEWER_FRAME_TAKEN_LIMIT
	case viewer_writing(viewer):
		for &other in viewers {
			if &other != viewer && other.bound && other.viewer_frame_step == .None && other.damage.count > 0 {
				return .Write, VIEWER_FRAME_WRITE_LIMIT_SHARED
			}
		}
		return .Write, VIEWER_FRAME_WRITE_LIMIT
	}
	return .None, 0
}

// viewer_bound_start gives the start of a bound, in milliseconds of the
// machine.
viewer_bound_start :: proc "contextless" (viewer: ^Viewer, bound: Viewer_Bound) -> u64 {
	switch bound {
	case .Read:
		return viewer.read_started_at
	case .Write, .Take:
		return viewer.step_started_at
	case .None:
	}
	return max(u64)
}

// viewers_deadline gives the nearest bound of a viewer, in milliseconds of
// the machine, or max(u64).
viewers_deadline :: proc "contextless" () -> u64 {
	deadline := max(u64)
	for &viewer in viewers {
		if !viewer.bound {
			continue
		}
		bound, limit := viewer_bound_of(&viewer)
		if bound != .None {
			deadline = min(deadline, viewer_bound_start(&viewer, bound) + limit)
		}
	}
	return deadline
}

viewers_bound :: proc "contextless" () -> int {
	count := 0
	for viewer in viewers {
		if viewer.bound {
			count += 1
		}
	}
	return count
}

// capture_events reads the records of the compositor on the ring of the
// window: the size of the screen and the pictures of the capture face. A
// word that names no event is counted, and its first one writes a line.
capture_events :: proc "contextless" () {
	@(static) words_refused: u64
	for {
		record, has := system.receive(&window.completions)
		if !has {
			break
		}
		kind, known := enum_word.member_of_word(display.Event_Kind, u64(record.kind))
		if !known {
			if words_refused == 0 {
				system.log_fact(.Info, Compositor_Word_Refused{word = u64(record.kind)})
			}
			words_refused += 1
			continue
		}
		switch kind {
		case .None, .Key, .Pointer, .Settings_Changed, .Go_To, .Resized, .Copy_Asked, .Pasted, .Surface_Answer:
			// The events of a window: this process has no surface.
		case .Capture_Size:
			capture_size_take(record.values[0], record.values[1])
		case .Capture_Frame:
			if capture_state != .Open || record.values[0] >= display.PICTURE_COUNT || held_picture >= 0 {
				system.log_fact(.Info, Capture_Picture_Refused{picture = record.values[0]})
				continue
			}
			held_picture = int(record.values[0])
		}
	}
	system.wake_writer(&window.completions)
}

// capture_size_take makes the memory of the capture face for the size of
// the screen, gives it to the compositor, and makes the copy of the screen.
capture_size_take :: proc "contextless" (width, height: u64) {
	if capture_state != .Asking {
		return
	}
	if width == 0 || height == 0 || width > protocol.SCREEN_WIDTH_LIMIT || height > protocol.SCREEN_HEIGHT_LIMIT {
		system.log_fact(.Info, Screen_Past_Reference{width = width, height = height})
		capture_state = .Closed
		return
	}
	screen = {u32(width), u32(height)}
	pages := display.capture_pages(int(width), int(height))
	status: system.Status
	if capture_memory, status = system.memory_create(pages); status != .Ok {
		system.log_fact(.Info, Capture_Memory_Refused{pages = value_kinds.Size_In_Pages(pages)})
		capture_state = .Closed
		return
	}
	address, map_status := system.memory_map(capture_memory, {})
	given, give_status := system.give(window_memory, capture_memory, {.Read, .Write})
	if map_status != .Ok || give_status != .Ok {
		system.log_fact(.Info, Capture_Memory_Not_Given{})
		system.close(capture_memory)
		capture_memory = 0
		capture_state = .Closed
		return
	}
	capture_mapped = address
	capture_header = (^display.Capture_Header)(address)
	pixels := ([^]u32)(rawptr(uintptr(address) + display.CAPTURE_HEADER_PAGES * system.PAGE_SIZE))
	for &picture, place in capture_pictures {
		picture = pixels[place * int(width) * int(height):]
	}
	if mirror == nil {
		mirror_pages := (u64(protocol.SCREEN_WIDTH_LIMIT * protocol.SCREEN_HEIGHT_LIMIT * 4) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
		mirror_address: rawptr
		mirror_status: system.Status
		mirror_memory, mirror_status = system.memory_create(mirror_pages)
		if mirror_status == .Ok {
			mirror_address, mirror_status = system.memory_map(mirror_memory, {.Write})
		}
		if mirror_status != .Ok {
			fail("no memory for the copy of the screen")
		}
		mirror = ([^]u32)(mirror_address)
	}
	mirror_pixels = int(width) * int(height)
	mirror_valid = false
	compositor_send({kind = u32(display.Command.Capture_Open), values = {0 = u64(given), 1 = width, 2 = height}})
	capture_state = .Open
	system.log_fact(.Info, Capture_Face_Opened{width = width, height = height})
	viewers_tell()
}

// capture_apply copies the picture that the compositor wrote into the copy
// of the screen, while no viewer is in the middle of a viewer frame, then gives it
// back. The header is copied, then checked: the compositor wrote it.
capture_apply :: proc "contextless" () {
	if held_picture < 0 || capture_state != .Open {
		return
	}
	for &viewer in viewers {
		if viewer.bound && viewer_writing(&viewer) {
			return
		}
	}
	picture := held_picture
	header := capture_header.pictures[picture]
	count := int(min(header.count, display.CAPTURE_RECTANGLE_CAPACITY))
	width, height := int(screen.width), int(screen.height)
	for place in 0 ..< count {
		rectangle := header.rectangles[place]
		left, top := int(min(rectangle[0], screen.width)), int(min(rectangle[1], screen.height))
		right, bottom := int(min(rectangle[2], screen.width)), int(min(rectangle[3], screen.height))
		if right <= left || bottom <= top {
			continue
		}
		source := capture_pictures[picture]
		for row in top ..< bottom {
			intrinsics.mem_copy_non_overlapping(&mirror[row * width + left], &source[row * width + left], (right - left) * 4)
		}
		for &viewer in viewers {
			if viewer.bound {
				viewer_damage_add(&viewer, {left, top, right, bottom})
			}
		}
		// The first record of the face is the whole screen.
		if left == 0 && top == 0 && right == width && bottom == height {
			mirror_valid = true
		}
	}
	place := protocol.Pointer_Place_Body{x = header.pointer_x, y = header.pointer_y, left = header.pointer_left, top = header.pointer_top, right = header.pointer_right, bottom = header.pointer_bottom}
	if place.x < screen.width && place.y < screen.height && place.right <= screen.width && place.bottom <= screen.height {
		pointer_place = place
	}
	if _, shape_ok := enum_word.member_of_word(pointer_pictures.Pointer_Shape, u64(header.pointer_shape)); shape_ok {
		if _, form_ok := enum_word.member_of_word(pointer_pictures.Pointer_Form, u64(header.pointer_form)); form_ok {
			if header.pointer_size >= protocol.POINTER_SIZE_MINIMUM && header.pointer_size <= protocol.POINTER_SIZE_MAXIMUM && header.pointer_hot_spot_x < header.pointer_size && header.pointer_hot_spot_y < header.pointer_size {
				pointer_shape = {
					shape      = header.pointer_shape,
					form       = header.pointer_form,
					size       = header.pointer_size,
					hot_spot_x = header.pointer_hot_spot_x,
					hot_spot_y = header.pointer_hot_spot_y,
				}
				pointer_shape_valid = true
			}
		}
	}
	for &viewer in viewers {
		if !viewer.bound || viewer.place < 0 || viewer.place >= display.CAPTURE_VIEWER_CAPACITY {
			continue
		}
		if header.viewer_input_generation[viewer.place] == viewer.generation {
			echo := min(header.viewer_input_echo[viewer.place], viewer.input_received_count)
			viewer.input_echo_count = max(viewer.input_echo_count, echo)
		}
		if header.pointer_warped_mask & (u32(1) << u32(viewer.place)) != 0 {
			viewer.pointer_warp_pending = true
		}
	}
	captures += 1
	held_picture = -1
	compositor_send({kind = u32(display.Command.Capture_Taken), values = {0 = u64(picture)}})
}

// capture_follow opens the capture face when a viewer is bound, and closes
// it when none is.
capture_follow :: proc "contextless" () {
	bound := viewers_bound()
	switch capture_state {
	case .Closed:
		if bound > 0 {
			capture_state = .Asking
			compositor_send({kind = u32(display.Command.Capture_Size_Ask)})
		}
	case .Asking:
	case .Open:
		if bound == 0 {
			compositor_send({kind = u32(display.Command.Capture_Close)})
			system.memory_unmap(capture_mapped)
			system.close(capture_memory)
			capture_memory, capture_mapped, capture_header = 0, nil, nil
			held_picture = -1
			mirror_valid = false
			capture_state = .Closed
			system.log_fact(.Info, Capture_Face_Closed{pictures = captures})
		}
	}
}

// exchange gives the server the datagrams that arrived, runs its timers,
// moves the viewers, and sends what the connections have.
exchange :: proc "contextless" (arrived: []ring.Record) -> (deadline: u64) {
	now := now_microseconds()
	batch: [RECEIVE_PLACES]quic.Server_Datagram
	batch_count := 0
	for record in arrived {
		data, whole := network.udp_data_read(place_bytes(record.tag)[:min(record.values[1], PLACE_SIZE)], u32(record.values[2]), local_address, .Do_Not_Verify)
		if !whole {
			continue
		}
		batch[batch_count] = {data, quic.Remote{u32(record.values[2]), u16(record.values[3])}}
		batch_count += 1
	}
	order: [RECEIVE_PLACES]int
	count := quic.server_batch_order(&server, batch[:batch_count], order[:])
	for index in order[:count] {
		bytes, peer := batch[index].bytes, batch[index].remote
		answer_place, has_place := place_take()
		answer: []u8
		if has_place {
			answer = data_bytes(answer_place)
		}
		outcome := quic.server_datagram_receive(&server, bytes, peer, answer, now)
		if outcome.answer_length > 0 {
			send(answer_place, outcome.answer_length, peer)
		} else if has_place {
			free_places[free_count] = answer_place
			free_count += 1
		}
		if outcome.validate_remote && outcome.record >= 0 {
			validate(peer, outcome.record)
		}
		if outcome.release_remote {
			release(peer)
		}
	}
	quic.server_time_passes(&server, now)
	for _ in 0 ..< 4 {
		viewers_work()
		sent := 0
		for free_count > 0 {
			place, _ := place_take()
			length, peer := quic.server_datagram_send(&server, data_bytes(place), now)
			if length == 0 {
				free_places[free_count] = place
				free_count += 1
				break
			}
			send(place, length, peer)
			sent += 1
		}
		if sent == 0 {
			break
		}
	}
	ended: [CAPACITY]quic.Remote
	ended_count := quic.server_sweep(&server, ended[:])
	for peer in ended[:ended_count] {
		release(peer)
	}
	return quic.server_deadline(&server)
}

// The entry of the remote display: it makes its key, checks its grants,
// then runs QUIC, the viewers and the capture face until the machine stops.
//
// The entry, in order:
//
// 1. takes the random generator of its context and makes its Ed25519 key;
//    with a seed under the strength "processor" it writes "remote_display:
//    the random seed of this process is weak" and stops;
// 2. writes "remote_display: the public key of this service: " and 64
//    hexadecimal digits;
// 3. opens its datagram endpoint and the ring of its window, maps the client
//    table read-only, and asks the network service for its grant; a grant
//    that is not a listen grant of UDP for the host only stops it;
// 4. writes "remote_display: listening on the UDP port 7101, for the host
//    10.0.2.2 only, and for the viewer keys that a principal allowed".
//
// Then one loop runs for ever. Each pass gives the arrived datagrams to the
// server, moves the viewers, takes the records of the compositor, copies a
// picture that waits, and opens or closes the capture face. The loop waits
// for a datagram, a record of the compositor, a change of the client table,
// the next deadline of QUIC, or the bound of a viewer frame.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	if !random.generator_from_context(&process_generator, ctx) {
		fail("no random seed in the context")
	}
	configuration := quic.Connection_Configuration{idle_timeout_milliseconds = IDLE_TIMEOUT_MILLISECONDS}
	configuration.tls = {role = .Server, least_seed_strength = .Processor}
	configuration.tls.application_protocol_length = copy(configuration.tls.application_protocol[:], protocol.APPLICATION_PROTOCOL)
	error: errors.Error_Record
	if !random.fill_for_a_key(&process_generator, configuration.tls.server_private_key[:], .Processor, &error) {
		fail("the random seed of this process is weak: it makes no key, and listens on nothing")
	}
	secret := string(configuration.tls.server_private_key[:])
	result := public_key[:]
	if ed25519_public_key(&secret, &result, &error) != 32 {
		fail("the module cryptography refused to make the public key")
	}
	key_text: [64]u8
	system.log_fact(.Info, Public_Key_Made{public_key = value_kinds.text_field(hex_text(key_text[:], public_key[:]), KEY_FIELD_BYTES)})
	status: system.Status
	if endpoint, status = system.ring_open(ctx.handles[datagram.GRANT_RING]); status != .Ok {
		fail("no endpoint: the process has no grant of the network")
	}
	address, map_status := system.memory_map(ctx.handles[datagram.GRANT_REGION], {.Write})
	region_pages, size_status := system.memory_size(ctx.handles[datagram.GRANT_REGION])
	if map_status != .Ok || size_status != .Ok || region_pages < datagram.REGION_PAGES {
		fail("no datagram region")
	}
	region = ([^]u8)(address)[:datagram.REGION_PAGES * system.PAGE_SIZE]
	window_memory = ctx.handles[system.GRANT_DISPLAY]
	if window, status = system.ring_open(window_memory); status != .Ok {
		fail("no ring of a window: the capture face rides it")
	}
	client_table_address, client_table_status := system.memory_map(ctx.handles[remote.GRANT_CLIENT_TABLE], {})
	if client_table_status != .Ok {
		fail("no client table: the process has no grant Remote_Clients")
	}
	client_table = (^remote.Client_Table)(client_table_address)
	configuration.tls.client_key_check = client_key_allowed
	system.send(&endpoint.commands, ring.Record{kind = u32(datagram.Command.Info), tag = CALL_TAG})
	info: ring.Record
	for {
		record, has := system.receive(&endpoint.completions)
		if has {
			info = record
			break
		}
		wait: system.Wait
		system.wait_records(&wait, &endpoint.completions)
		system.wait_end(&wait, system.time() + 2000)
	}
	grant, grant_known := datagram.grant_unpack(info.values[6])
	if !grant_known || grant.tcp || !grant.listen || grant.address != remote.HOST_ADDRESS {
		fail("the grant is not a listen grant of UDP for the address of the host only")
	}
	listen_port = grant.port
	local_address = u32(info.values[0])
	memory, memory_status := system.memory_create(TABLE_PAGES)
	table, table_status := system.memory_map(memory, {.Write})
	if memory_status != .Ok || table_status != .Ok {
		fail("no memory for the table of connections")
	}
	quic_connections = ([^]quic.Connection)(table)[:CAPACITY]
	streams = ([^]quic.Stream)(rawptr(uintptr(table) + CONNECTION_BYTES))[:CAPACITY * STREAMS_PER_CONNECTION]
	limits := quic.SERVER_LIMITS_DEFAULT
	limits.connections_per_remote_address = CAPACITY
	limits.handshakes_per_remote_address = CAPACITY
	limits.handshakes_at_once = CAPACITY
	if !quic.server_init(&server, quic_connections, records[:], streams, &configuration, &cryptography, &process_generator, limits, &error) {
		fail("the server refused its configuration")
	}
	quic.secret_erase(&configuration.tls.server_private_key, size_of(configuration.tls.server_private_key))
	for place in 0 ..< RECEIVE_PLACES {
		post(u32(place))
	}
	for place in RECEIVE_PLACES ..< PLACE_COUNT {
		free_places[free_count] = u32(place)
		free_count += 1
	}
	system.wake_reader(&endpoint.commands)
	system.log_fact(.Info, Listening{listen_port = u64(listen_port), viewer_capacity = u64(CAPACITY)})

	arrived: [RECEIVE_PLACES]ring.Record
	for {
		wait := system.wait_begin()
		held_commands_push()
		compositor_held_push()
		count := 0
		for record in system.receive(&endpoint.completions) {
			switch {
			case record.tag < RECEIVE_PLACES:
				if datagram.Status(record.kind) == .Ok {
					arrived[count] = record
					count += 1
				} else {
					post(record.tag)
				}
			case record.tag & VALIDATE_TAG != 0:
				validation_completed(record)
			case record.tag >= SEND_TAG && record.tag < SEND_TAG + PLACE_COUNT:
				free_places[free_count] = record.tag - SEND_TAG
				free_count += 1
			}
		}
		capture_events()
		capture_apply()
		deadline := exchange(arrived[:count])
		for record in arrived[:count] {
			post(record.tag)
		}
		capture_follow()
		// A picture that the viewers no longer hold back goes into the copy
		// in this pass, and the viewer frames that it damaged go at once.
		capture_apply()
		system.wake_reader(&endpoint.commands)
		if !ring.empty(&endpoint.completions) || !ring.empty(&window.completions) {
			continue
		}
		system.wait_records(&wait, &endpoint.completions)
		system.wait_records(&wait, &window.completions)
		if compositor_held_count > 0 {
			system.wait_room(&wait, &window.commands)
		}
		system.wait_word(&wait, &client_table.version, client_table_version_seen)
		if system.wait_spin(&wait) {
			continue
		}
		limit: u64 = system.WAIT_FOREVER
		if deadline != max(u64) {
			limit = min(limit, deadline / 1000 + 1)
		}
		limit = min(limit, viewers_deadline())
		system.wait_end(&wait, limit)
	}
}
