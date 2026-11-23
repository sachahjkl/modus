package remote_display_service

import "modus:contract/value_kinds"
import "modus:quic"
import "modus:quic_server"
import op "modus:contract/operation"
import "modus:contract/call_outcome"

// The log facts of the remote display (src/md/features/log_facts.md, "The
// facts of the device services and of the network"): the viewer keys that
// the handshake refuses or takes, the ends of a viewer, its refused
// records, and the refused words of the compositor, as records of fields.
// Each fact template is the sentence that the line wrote before it was a
// fact, so a wait of a machine test on that sentence reads it as before. A
// line whose sentence differs by its case is one fact type for each case:
// the template has no condition. No field has the name of a column of the
// head of facts(): number, time, process, level.
//
// A key, the address of a host and a cause are Text fields, and the last
// fields: the serial line of a fact stops at its last byte that is not
// zero. A Text field is [N]u8 with N written out, as the tool reads it.

// The bytes of the Text field of a whole viewer key: 64 hexadecimal digits
// and a zero byte, on 8 bytes.
KEY_FIELD_BYTES :: 72
// The bytes of the Text field of the head of a viewer key: its first 8
// bytes in 16 hexadecimal digits, and a zero byte, on 8 bytes.
KEY_HEAD_FIELD_BYTES :: 24
// The bytes of the Text field of the address of a host: the longest,
// "255.255.255.255 port 65535", has 26 bytes, and a zero byte.
PEER_FIELD_BYTES :: 32
// The bytes of the Text field of the cause of a refused record: the
// longest sentence of protocol.RECORD_PROBLEM_SENTENCES has 68 bytes.
RECORD_CAUSE_FIELD_BYTES :: 72
// The bytes of the Text field of the name of an error code of the
// protocol: the longest, "Input_Not_Allowed", has 17 bytes.
ERROR_CODE_FIELD_BYTES :: 24
// The bytes of the Text field of the step that a viewer did not do in its
// bound: the longest sentence of VIEWER_BOUND_SENTENCES has 59 bytes.
MISSED_STEP_FIELD_BYTES :: 64
// The bytes of the Text field of the cause of a refused size: the longest
// sentence of memory_screen.RESIZE_REFUSAL_SENTENCES has 79 bytes.
RESIZE_REFUSAL_FIELD_BYTES :: 88

// The handshake refused a viewer key.
@(log_fact = "remote_display: refused the viewer key {viewer_key}: no principal allowed it for the view, or the session of its principal is locked; the handshake ends before any viewer frame")
Viewer_Key_Refused :: struct {
	viewer_key: [72]u8,
}

// The end of a viewer dropped its keys and pointer records that waited for
// room in the window ring.
@(log_fact = "remote_display: the end of the viewer key {viewer_key_head} dropped {dropped} of its input records that waited for the compositor")
Viewer_Input_Records_Dropped :: struct {
	dropped:         u64,
	viewer_key_head: [24]u8,
}

// The grant of a viewer key ended between the check of the handshake and
// the binding of its connection.
@(log_fact = "remote_display: {peer}: the grant of the viewer key {viewer_key_head} ended during the handshake: the connection ends with the code Revoked")
Viewer_Key_Grant_Ended_In_Handshake :: struct {
	viewer_key_head: [24]u8,
	peer:            [32]u8,
}

// A host proved a viewer key whose principal allowed the view and the
// input: the viewer is taken.
@(log_fact = "remote_display: {peer} proved the viewer key {viewer_key_head}: it sees the screen for principal {principal}, and its keys and its pointer go to the desktop")
Viewer_Key_Proved_With_Input :: struct {
	principal:       u64,
	viewer_key_head: [24]u8,
	peer:            [32]u8,
}

// A host proved a viewer key whose principal allowed the view only: the
// viewer is taken, with no input.
@(log_fact = "remote_display: {peer} proved the viewer key {viewer_key_head}: it sees the screen for principal {principal}, with no input")
Viewer_Key_Proved_Without_Input :: struct {
	principal:       u64,
	viewer_key_head: [24]u8,
	peer:            [32]u8,
}

// The principal disconnected a viewer from the bar popover.
@(log_fact = "remote_display: the principal disconnected viewer key {viewer_key_head} of principal {principal} from the bar: the connection from {peer} ends with the code Revoked")
Viewer_Disconnected_From_Bar :: struct {
	principal:       u64,
	viewer_key_head: [24]u8,
	peer:            [32]u8,
}

// The grant of the key of a viewer ended: its connection ends.
@(log_fact = "remote_display: the grant of the viewer key {viewer_key_head} of principal {principal} ended (a revocation, a lock of its session, or another session in front): the connection from {peer} ends with the code Revoked")
Viewer_Key_Grant_Ended :: struct {
	principal:       u64,
	viewer_key_head: [24]u8,
	peer:            [32]u8,
}

// The border refused a record of a viewer: its connection ends with an
// error code. The cause and the code are Text fields: the cause comes
// from a closed set of sentences, and the name of a code of the protocol
// is no member of a contract enum that a field can name.
@(log_fact = "remote_display: refused a record of the viewer key {viewer_key_head}: {cause}: the connection ends with the code {error_code}")
Viewer_Record_Refused :: struct {
	viewer_key_head: [24]u8,
	cause:           [72]u8,
	error_code:      [24]u8,
}

// A viewer sent input that its principal allowed for the view only.
@(log_fact = "remote_display: the viewer key {viewer_key_head} sent input, and principal {principal} allowed it for the view only: nothing reaches the desktop, and the connection ends with the code Input_Not_Allowed")
Viewer_Input_Not_Allowed :: struct {
	principal:       u64,
	viewer_key_head: [24]u8,
}

// The damage set of a viewer was full: rectangles joined another.
@(log_fact = "remote_display: the damage of the viewer key {viewer_key_head} was full: {merges} rectangles joined another, and the viewer receives more pixels")
Viewer_Damage_Full :: struct {
	merges:          u64,
	viewer_key_head: [24]u8,
}

// A viewer did not keep a bound of time: its connection ends. The step
// that it did not do is a Text field: Viewer_Bound is an enum of this
// module, whose members a reader cannot name, and one fact type keeps the
// one event.
@(log_fact = "remote_display: the viewer key {viewer_key_head} {missed_step} in its bound of {bound}: the connection ends with the code Timeout")
Viewer_Bound_Passed :: struct {
	bound:           value_kinds.Time_In_Milliseconds,
	viewer_key_head: [24]u8,
	missed_step:     [64]u8,
}

// The compositor sent a word of the window ring that names no event. The
// next ones are counted, with no line.
@(log_fact = "remote_display: the compositor sent the word {word}, which names no event; the next ones are counted")
Compositor_Word_Refused :: struct {
	word: u64,
}

// The compositor named a picture of no capture face, or a second one.
@(log_fact = "remote_display: the compositor named the picture {picture} of no capture face, or a second one while this process holds one: the record is refused")
Capture_Picture_Refused :: struct {
	picture: u64,
}

// The bytes of the Text field of the failure that stops the service: the
// longest of the failures of the services of the devices and of the
// network has 91 bytes, and a zero byte.
FAILURE_FIELD_BYTES :: 96

// The service stops on a failure: the words of the failure come from a
// closed set of sentences of this module.
@(log_fact = "remote_display: {failure}")
Service_Failed :: struct {
	failure: [96]u8,
}

// A measure: the first viewer frame of the whole screen.
@(log_fact = "remote_display: a measure: the whole screen of {width}x{height} in one viewer frame: {screen_pieces} screen pieces, {piece_bytes} of screen pieces for {pixel_bytes} of pixels, coded in {coded_time}, taken by the viewer {taken_time} after its start")
Whole_Screen_Measured :: struct {
	width:         u64,
	height:        u64,
	screen_pieces: u64,
	piece_bytes:   value_kinds.Size_In_Bytes,
	pixel_bytes:   value_kinds.Size_In_Bytes,
	coded_time:    value_kinds.Time_In_Microseconds,
	taken_time:    value_kinds.Time_In_Microseconds,
}

// A measure: the viewer frames of a small damage, their median and their
// least. The template has at most 256 bytes, so its names are short.
@(log_fact = "remote_display: a measure: viewer frames of a small damage (at most {pixels} pixels), the median of {frames}: {median_size} of screen pieces, {median_time} from Viewer_Frame_Start in the stream to Viewer_Frame_Taken; the least {least_size} and {least_time}")
Small_Damage_Measured :: struct {
	pixels:      u64,
	frames:      u64,
	median_size: value_kinds.Size_In_Bytes,
	median_time: value_kinds.Time_In_Microseconds,
	least_size:  value_kinds.Size_In_Bytes,
	least_time:  value_kinds.Time_In_Microseconds,
}

// The screen of the compositor is past the largest screen of the
// protocol.
@(log_fact = "remote_display: the screen of {width}x{height} is past the largest screen of the protocol, 7680x4320: no capture face")
Screen_Past_Largest :: struct {
	width:  u64,
	height: u64,
}

// The budget of this process does not pay the two pictures of the capture
// face and the copy of the screen, at the size of the screen in force.
@(log_fact = "remote_display: no capture face for the screen of {width}x{height}: its two pictures and its copy need {pages}, which the budget of this process does not give")
Capture_Memory_Refused :: struct {
	width:  u64,
	height: u64,
	pages:  value_kinds.Size_In_Pages,
}

// The capture face was refused: each viewer that waited for it ends with
// the code Screen_Not_Held, so it does not wait with no screen.
@(log_fact = "remote_display: ended {viewers} viewers with the code Screen_Not_Held: the capture face of the screen in force was refused")
Viewers_Ended_With_No_Screen :: struct {
	viewers: u64,
}

// The size that a viewer asked was refused: by the budget of this process,
// or by the compositor. The viewer gets the record Screen_Size_Refused and
// keeps its session.
@(log_fact = "remote_display: refused the screen of {width} x {height} that the viewer {viewer_key_head} asked: {resize_refusal}")
Screen_Size_Ask_Refused :: struct {
	width:           u64,
	height:          u64,
	viewer_key_head: [24]u8,
	resize_refusal:  [88]u8,
}

// The compositor gave a refusal of a size that no ask in flight named, or
// a cause that names no member: the event changes nothing.
@(log_fact = "remote_display: refused an answer of the compositor: a refusal of {width} x {height} with the word {refusal_word}, which no ask in flight names or which names no cause")
Capture_Size_Refusal_Refused :: struct {
	width:        u64,
	height:       u64,
	refusal_word: u64,
}

// The root service refused a Screen_Budget that no viewer waits for, or a
// Release: the extra budget ends at the stop of this process.
@(log_fact = "remote_display: the root service refused a command of the budgets of the screen of memory: {outcome}")
Screen_Budget_Answer_Refused :: struct {
	outcome: call_outcome.Call_Outcome_Word,
}

// The root service gave an extra budget with no number, or a third one: it
// is closed with no use.
@(log_fact = "remote_display: closed an extra budget for {width} x {height} with no use: it has no number, or two are held already")
Screen_Budget_Not_Taken :: struct {
	width:  u64,
	height: u64,
}

// The root ring had no room for the release of the extra budget.
@(log_fact = "remote_display: the root ring has no room for the release of the extra budget of the screen of memory: its pages return at the stop of this process")
Screen_Budget_Release_Not_Sent :: struct {}

// The copies of a new size of the screen were refused: the compositor is
// asked for the size before, and no viewer ends.
@(log_fact = "remote_display: no copies of the screen of {width} x {height}: the screen goes back to {back_width} x {back_height}")
Screen_Change_Reverted :: struct {
	width:       u64,
	height:      u64,
	back_width:  u64,
	back_height: u64,
}

// The screen of memory changed size: each viewer receives the new size
// and the whole screen.
@(log_fact = "remote_display: the screen is now {width} x {height}: {viewers} viewers receive its size and the whole screen")
Screen_Changed :: struct {
	width:   u64,
	height:  u64,
	viewers: u64,
}

// The memory of the capture face does not map, or the compositor does not
// take it.
@(log_fact = "remote_display: the memory of the capture face does not map, or the compositor does not take it")
Capture_Memory_Not_Given :: struct {}

// The capture face is open: a copy of the screen.
@(log_fact = "remote_display: the capture face is open: a copy of {width}x{height}")
Capture_Face_Opened :: struct {
	width:  u64,
	height: u64,
}

// The last viewer left: the capture face is closed.
@(log_fact = "remote_display: no viewer: the capture face is closed, after {pictures} pictures of the compositor")
Capture_Face_Closed :: struct {
	pictures: u64,
}

// The public key of the service, which a viewer checks.
@(log_fact = "remote_display: the public key of this service: {public_key}")
Public_Key_Made :: struct {
	public_key: [72]u8,
}

// The service listens for viewers.
@(log_fact = "remote_display: listening on the UDP port {listen_port}, for the host 10.0.2.2 only, and for the viewer keys that a principal allowed: {viewer_capacity} viewers at one time")
Listening :: struct {
	listen_port:     u64,
	viewer_capacity: u64,
}

// The tool reads the length of a Text field as a literal: the constants
// name the same bytes.
#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)
#assert(size_of(Public_Key_Made) == KEY_FIELD_BYTES)
#assert(size_of(Viewer_Key_Refused) == KEY_FIELD_BYTES)
#assert(size_of(Viewer_Key_Grant_Ended_In_Handshake) == KEY_HEAD_FIELD_BYTES + PEER_FIELD_BYTES)
#assert(size_of(Viewer_Record_Refused) == KEY_HEAD_FIELD_BYTES + RECORD_CAUSE_FIELD_BYTES + ERROR_CODE_FIELD_BYTES)
#assert(size_of(Viewer_Bound_Passed) == 8 + KEY_HEAD_FIELD_BYTES + MISSED_STEP_FIELD_BYTES)

// key_field gives the Text field of a whole viewer key, in the digits of
// the line before the fact.
key_field :: proc "contextless" (key: [32]u8) -> [KEY_FIELD_BYTES]u8 {
	bytes := key
	text: [64]u8
	return value_kinds.text_field(quic_server.hex_text(text[:], bytes[:]), KEY_FIELD_BYTES)
}

// key_head_field gives the Text field of the head of a viewer key: its
// first 8 bytes.
key_head_field :: proc "contextless" (key: [32]u8) -> [KEY_HEAD_FIELD_BYTES]u8 {
	bytes := key
	text: [16]u8
	return value_kinds.text_field(quic_server.hex_text(text[:], bytes[:8]), KEY_HEAD_FIELD_BYTES)
}

// peer_field gives the Text field of the address and the port of a host.
peer_field :: proc "contextless" (peer: quic.Remote) -> [PEER_FIELD_BYTES]u8 {
	text: [40]u8
	return value_kinds.text_field(quic_server.address_text(text[:], peer), PEER_FIELD_BYTES)
}
