package processor_frame

import "modus:contract/value_kinds"
import "modus:system"

// The log facts of processor_frame (src/md/features/log_facts.md): each
// fact template is the line that the process wrote before it was a fact, so
// a wait of a machine test on that sentence reads it as before. The Text
// fields are the last fields: the serial line of a fact stops at its last
// byte that is not zero.
//
// The measure lines are read by the measure record and by
// processor_frame_lines_check, in their sentence: a time is a field of
// nanoseconds that the reader writes as microseconds with one decimal, as
// the line did. Each part has its fact type, since a part names its own
// counts.

// The budget of the process gave no memory for its canvases.
@(log_fact = "processor_frame: wrong: the budget of this process gave no memory for its canvases")
No_Canvas_Memory :: struct {}

// Each part drew its pixels, the drawing module refused no call, and each
// table holds its records.
@(log_fact = "processor_frame: ok, each part drew its pixels, the drawing module refused no call, and each table holds each of its records")
Parts_Drawn :: struct {}

// A clear and a present of a frame of the reference screen: the least and
// the median time of the frames.
@(log_fact = "processor_frame: measure: a clear and a present of 1920x1080: least {least}, median {median}, {frames} frames in one second at the median, over {rounds} frames")
Clear_And_Present_Measured :: struct {
	least:  value_kinds.Nanoseconds_As_Microseconds,
	median: value_kinds.Nanoseconds_As_Microseconds,
	frames: u64,
	rounds: u64,
}

// A full frame of the compositor with 4 windows.
@(log_fact = "processor_frame: measure: a full frame of the compositor at 1920x1080 with 4 windows: least {least}, median {median}, {frames} frames in one second at the median, over {rounds} frames")
Full_Frame_Measured :: struct {
	least:  value_kinds.Nanoseconds_As_Microseconds,
	median: value_kinds.Nanoseconds_As_Microseconds,
	frames: u64,
	rounds: u64,
}

// A frame of the compositor in its damage of 2 rectangles.
@(log_fact = "processor_frame: measure: a frame of the compositor at 1920x1080 with 4 windows in its damage of 2 rectangles, {pixels} pixels: least {least}, median {median}, {frames} frames in one second at the median, over {rounds} frames")
Damage_Frame_Measured :: struct {
	pixels: u64,
	least:  value_kinds.Nanoseconds_As_Microseconds,
	median: value_kinds.Nanoseconds_As_Microseconds,
	frames: u64,
	rounds: u64,
}

// The execution of the draw table of a desktop, with the count of each
// kind of record.
@(log_fact = "processor_frame: measure: the execution of a draw table of 1920x1080 with {records} records: {opaque_rectangles} opaque rectangles and gradients, {cell_texts} texts in the font of the cells, {interface_texts} in the interface font, {opaque_pictures} opaque pictures, {with_alpha} rectangles and pictures with alpha: least {least}, median {median}, {frames} frames in one second at the median, over {rounds} frames")
Draw_Table_Measured :: struct {
	records:           u64,
	opaque_rectangles: u64,
	cell_texts:        u64,
	interface_texts:   u64,
	opaque_pictures:   u64,
	with_alpha:        u64,
	least:             value_kinds.Nanoseconds_As_Microseconds,
	median:            value_kinds.Nanoseconds_As_Microseconds,
	frames:            u64,
	rounds:            u64,
}

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
