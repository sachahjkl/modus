package processor_frame

import "modus:contract/value_kinds"
import "modus:support/system"

// The log facts of processor_frame (src/md/features/log_facts.md): each
// fact template is the line that the process wrote before it was a fact, so
// a wait of a machine test on that sentence reads it as before. The Text
// fields are the last fields: the serial line of a fact stops at its last
// byte that is not zero.
//
// The measure lines stay text: each writes a time in microseconds with one
// decimal, which no field kind writes. So do the lines with no value.

// The bytes of the Text field of the four answers of the pixels: the
// longest, "yes, yes, yes, yes", has 18 bytes.
PIXELS_RIGHT_FIELD_BYTES :: 24
// The bytes of the Text field of one answer, "yes" or "no".
ANSWER_FIELD_BYTES :: 8

// A part drew wrong pixels, the drawing module refused a call, or a table
// lost a record: the run fails. pixels_right holds the answer of each part
// in the order of the sentence.
@(log_fact = "processor_frame: wrong: the pixels of the clear and present, the full frame, the frame in its damage and the draw table are right: {pixels_right}; the drawing module refused {refused_calls} calls; each table holds each of its records: {tables_whole}")
Parts_Wrong :: struct {
	refused_calls: u64,
	pixels_right:  [24]u8,
	tables_whole:  [8]u8,
}

#assert(size_of(Parts_Wrong) == 8 + PIXELS_RIGHT_FIELD_BYTES + ANSWER_FIELD_BYTES)

// answer_text gives the answer of a check in the words of the line.
answer_text :: proc "contextless" (right: bool) -> string {
	return right ? "yes" : "no"
}

// answer_field gives the Text field of the answer of one check.
answer_field :: proc "contextless" (right: bool) -> [ANSWER_FIELD_BYTES]u8 {
	return value_kinds.text_field(answer_text(right), ANSWER_FIELD_BYTES)
}

// pixels_right_field gives the Text field of the answers of the four
// parts, separated as the line wrote them.
pixels_right_field :: proc "contextless" (pixels_right: [4]bool) -> [PIXELS_RIGHT_FIELD_BYTES]u8 {
	text: [PIXELS_RIGHT_FIELD_BYTES]u8
	writer := system.Writer{buffer = text[:]}
	for right, index in pixels_right {
		if index > 0 {
			system.write_part(&writer, ", ")
		}
		system.write_part(&writer, answer_text(right))
	}
	return value_kinds.text_field(system.written(&writer), PIXELS_RIGHT_FIELD_BYTES)
}
