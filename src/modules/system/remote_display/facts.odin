package remote_display_service

import "modus:contract/value_kinds"
import "modus:support/quic"

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

// The handshake refused a viewer key.
@(log_fact = "remote_display: refused the viewer key {viewer_key}: no principal allowed it for the view, or the session of its principal is locked; the handshake ends before any viewer frame")
Viewer_Key_Refused :: struct {
	viewer_key: [72]u8,
}

// The end of a viewer dropped its keys and pointer records that waited for
// room in the window ring.
@(log_fact = "remote_display: the end of the viewer key {viewer_key} dropped {dropped} of its input records that waited for the compositor")
Viewer_Input_Records_Dropped :: struct {
	dropped:    u64,
	viewer_key: [24]u8,
}

// The grant of a viewer key ended between the check of the handshake and
// the binding of its connection.
@(log_fact = "remote_display: {peer}: the grant of the viewer key {viewer_key} ended during the handshake: the connection ends with the code Revoked")
Viewer_Key_Grant_Ended_In_Handshake :: struct {
	viewer_key: [24]u8,
	peer:       [32]u8,
}

// A host proved a viewer key whose principal allowed the view and the
// input: the viewer is taken.
@(log_fact = "remote_display: {peer} proved the viewer key {viewer_key}: it sees the screen for principal {principal}, and its keys and its pointer go to the desktop")
Viewer_Key_Proved_With_Input :: struct {
	principal:  u64,
	viewer_key: [24]u8,
	peer:       [32]u8,
}

// A host proved a viewer key whose principal allowed the view only: the
// viewer is taken, with no input.
@(log_fact = "remote_display: {peer} proved the viewer key {viewer_key}: it sees the screen for principal {principal}, with no input")
Viewer_Key_Proved_Without_Input :: struct {
	principal:  u64,
	viewer_key: [24]u8,
	peer:       [32]u8,
}

// The grant of the key of a viewer ended: its connection ends.
@(log_fact = "remote_display: the grant of the viewer key {viewer_key} of principal {principal} ended (a revocation, a lock of its session, or another session in front): the connection from {peer} ends with the code Revoked")
Viewer_Key_Grant_Ended :: struct {
	principal:  u64,
	viewer_key: [24]u8,
	peer:       [32]u8,
}

// The border refused a record of a viewer: its connection ends with an
// error code. The cause and the code are Text fields: the cause comes
// from a closed set of sentences, and the name of a code of the protocol
// is no member of a contract enum that a field can name.
@(log_fact = "remote_display: refused a record of the viewer key {viewer_key}: {cause}: the connection ends with the code {code}")
Viewer_Record_Refused :: struct {
	viewer_key: [24]u8,
	cause:      [72]u8,
	code:       [24]u8,
}

// A viewer sent input that its principal allowed for the view only.
@(log_fact = "remote_display: the viewer key {viewer_key} sent input, and principal {principal} allowed it for the view only: nothing reaches the desktop, and the connection ends with the code Input_Not_Allowed")
Viewer_Input_Not_Allowed :: struct {
	principal:  u64,
	viewer_key: [24]u8,
}

// The damage set of a viewer was full: rectangles joined another.
@(log_fact = "remote_display: the damage of the viewer key {viewer_key} was full: {merges} rectangles joined another, and the viewer receives more pixels")
Viewer_Damage_Full :: struct {
	merges:     u64,
	viewer_key: [24]u8,
}

// A viewer did not keep a bound of time: its connection ends. The step
// that it did not do is a Text field: Viewer_Bound is an enum of this
// module, whose members a reader cannot name, and one fact type keeps the
// one event.
@(log_fact = "remote_display: the viewer key {viewer_key} {missed_step} in its bound of {limit}: the connection ends with the code Timeout")
Viewer_Bound_Passed :: struct {
	limit:       value_kinds.Time_In_Milliseconds,
	viewer_key:  [24]u8,
	missed_step: [64]u8,
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

// The tool reads the length of a Text field as a literal: the constants
// name the same bytes.
#assert(size_of(Viewer_Key_Refused) == KEY_FIELD_BYTES)
#assert(size_of(Viewer_Key_Grant_Ended_In_Handshake) == KEY_HEAD_FIELD_BYTES + PEER_FIELD_BYTES)
#assert(size_of(Viewer_Record_Refused) == KEY_HEAD_FIELD_BYTES + RECORD_CAUSE_FIELD_BYTES + ERROR_CODE_FIELD_BYTES)
#assert(size_of(Viewer_Bound_Passed) == 8 + KEY_HEAD_FIELD_BYTES + MISSED_STEP_FIELD_BYTES)

// key_field gives the Text field of a whole viewer key, in the digits of
// the line before the fact.
key_field :: proc "contextless" (key: [32]u8) -> [KEY_FIELD_BYTES]u8 {
	bytes := key
	text: [64]u8
	return value_kinds.text_field(hex_text(text[:], bytes[:]), KEY_FIELD_BYTES)
}

// key_head_field gives the Text field of the head of a viewer key: its
// first 8 bytes.
key_head_field :: proc "contextless" (key: [32]u8) -> [KEY_HEAD_FIELD_BYTES]u8 {
	bytes := key
	text: [16]u8
	return value_kinds.text_field(hex_text(text[:], bytes[:8]), KEY_HEAD_FIELD_BYTES)
}

// peer_field gives the Text field of the address and the port of a host.
peer_field :: proc "contextless" (peer: quic.Remote) -> [PEER_FIELD_BYTES]u8 {
	text: [40]u8
	return value_kinds.text_field(address_text(text[:], peer), PEER_FIELD_BYTES)
}
