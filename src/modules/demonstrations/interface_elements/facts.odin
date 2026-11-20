package interface_elements

import "modus:contract/value_kinds"

// The log facts of interface_elements (src/md/features/log_facts.md): each
// fact template is the line that the process wrote before it was a fact, so
// a wait of a machine test on that sentence reads it as before. The Text
// fields are the last fields: the serial line of a fact stops at its last
// byte that is not zero.

// The bytes of the Text field of a name of the list: the longest,
// "compositor", has 10 bytes.
LIST_NAME_FIELD_BYTES :: 16
// The bytes of the Text field of the text of the input: at most the 32
// bytes of `typed`, and a zero byte.
TYPED_TEXT_FIELD_BYTES :: 40
// The bytes of the Text field of the state of the damage overlay: "shown"
// or "hidden".
OVERLAY_FIELD_BYTES :: 8

// The bytes of the Text field of the name of a measure of the damage: the
// longest, "one number changed", has 18 bytes.
MEASURE_NAME_FIELD_BYTES :: 24

// A measure of the damage by difference: the records of the frame, its
// damage rectangles and their part of the window, and the time of one
// comparison.
@(log_fact = "interface_elements: {measure}: {records} records, {rectangles} damage rectangles, {window_percent} % of the window, the difference in {difference}")
Damage_Measured :: struct {
	records:        u64,
	rectangles:     u64,
	window_percent: u64,
	difference:     value_kinds.Nanoseconds_As_Microseconds,
	measure:        [24]u8,
}

// The button was pressed: the count of its presses since the start.
@(log_fact = "interface_elements: the button was pressed {presses} times")
Button_Pressed :: struct {
	presses: u64,
}

// The list has a new choice.
@(log_fact = "interface_elements: the list chooses {chosen_name}")
List_Chose :: struct {
	chosen_name: [16]u8,
}

// The text input changed: its whole text.
@(log_fact = "interface_elements: the text is \"{typed_text}\"")
Text_Typed :: struct {
	typed_text: [40]u8,
}

// The button of the damage shows or hides the damage rectangles.
@(log_fact = "interface_elements: the damage is {overlay}")
Damage_Overlay_Changed :: struct {
	overlay: [8]u8,
}

// One whole frame built and drawn in the font of the cells, on a machine
// whose boot image gives no interface font.
@(log_fact = "interface_elements: one whole frame, built and drawn (the least of 20): the font of the cells {cell_font}; no interface font")
Whole_Frame_Measured_Without_Interface_Font :: struct {
	cell_font: value_kinds.Time_In_Microseconds,
}

// One whole frame built and drawn in the font of the cells and in the
// interface font.
@(log_fact = "interface_elements: one whole frame, built and drawn (the least of 20): the font of the cells {cell_font}, the interface font {interface_font}")
Whole_Frame_Measured :: struct {
	cell_font:      value_kinds.Time_In_Microseconds,
	interface_font: value_kinds.Time_In_Microseconds,
}

// The window drew its whole frame, then a frame in its damage.
@(log_fact = "interface_elements: ok, the whole frame drawn in {whole_frame}; the next frame drawn in its {damage_rectangles} damage rectangles in {damage_frame}")
Frames_Drawn :: struct {
	whole_frame:       value_kinds.Time_In_Microseconds,
	damage_rectangles: u64,
	damage_frame:      value_kinds.Time_In_Microseconds,
}

#assert(size_of(List_Chose) == LIST_NAME_FIELD_BYTES)
#assert(size_of(Text_Typed) == TYPED_TEXT_FIELD_BYTES && TYPED_TEXT_FIELD_BYTES > len(typed))
#assert(size_of(Damage_Overlay_Changed) == OVERLAY_FIELD_BYTES)

// microseconds gives a time in nanoseconds as whole microseconds, as the
// line wrote it.
microseconds :: proc "contextless" (nanoseconds: u64) -> value_kinds.Time_In_Microseconds {
	return value_kinds.Time_In_Microseconds(nanoseconds / 1000)
}
