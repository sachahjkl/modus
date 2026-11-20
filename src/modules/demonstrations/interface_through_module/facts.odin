package interface_through_module

import "modus:contract/value_kinds"

// The log facts of interface_through_module
// (src/md/features/log_facts.md): each fact template is the line that the
// process wrote before it was a fact, so a wait of a machine test on that
// sentence reads it as before. The Text fields are the last fields: the
// serial line of a fact stops at its last byte that is not zero.

// The draw table of the package and the draw table of the module are the
// same bytes.
@(log_fact = "interface_through_module: ok, the two draw tables are equal")
Draw_Tables_Equal :: struct {}

// The two draw tables differ.
@(log_fact = "interface_through_module: wrong: the two draw tables differ")
Draw_Tables_Differ :: struct {}

// The bytes of the Text field that says whether the count of a frame that
// did not fit is the count of the full frame: the longest, "not the count
// of the full frame", has 31 bytes.
FULL_COUNT_FIELD_BYTES :: 32

// One frame built through the module and with the package compiled in.
@(log_fact = "interface_through_module: one frame of {records} draw records and {text_bytes} text bytes in {calls} element calls: {through_module} through the module, {compiled_in} with the package compiled in, the least of {builds}")
Frame_Built :: struct {
	records:        u64,
	text_bytes:     u64,
	calls:          u64,
	through_module: value_kinds.Time_In_Nanoseconds,
	compiled_in:    value_kinds.Time_In_Nanoseconds,
	builds:         u64,
}

// The damage and the drawing of one frame through the module, and the code
// of the module.
@(log_fact = "interface_through_module: the damage and the drawing through the module: {drawing}; interface_module has {module_code} of code")
Frame_Drawn :: struct {
	drawing:     value_kinds.Time_In_Nanoseconds,
	module_code: value_kinds.Size_In_Bytes,
}

// A frame that does not fit a draw table of 16 places: the records that
// the module asked for, and those that the process drew.
@(log_fact = "interface_through_module: a draw table of 16 places: the frame did not fit, {asked} records asked, {drawn} drawn, {full_count}")
Frame_Did_Not_Fit :: struct {
	asked:      u64,
	drawn:      u64,
	full_count: [32]u8,
}

// The drawing module refused the frame of the comparison of the pixels.
@(log_fact = "interface_through_module: the drawing module refused the frame, with the error kind {error_kind} of the argument {argument}: WRONG")
Drawing_Module_Refused :: struct {
	error_kind: u64,
	argument:   u64,
}

// The package and the drawing module drew the same pixels.
@(log_fact = "interface_through_module: one frame drawn by the package compiled in and by the drawing module: {pixels} pixels, {text_records} text records, the same bytes: as it must")
Same_Pixels :: struct {
	pixels:       u64,
	text_records: u64,
}

// The package and the drawing module drew pixels that differ.
@(log_fact = "interface_through_module: one frame drawn by the package compiled in and by the drawing module: {different} of {pixels} pixels differ, {text_records} text records: WRONG")
Pixels_Differ :: struct {
	different:    u64,
	pixels:       u64,
	text_records: u64,
}

#assert(size_of(Frame_Did_Not_Fit) == 16 + FULL_COUNT_FIELD_BYTES)

// full_count_field gives the Text field that says whether a count is the
// count of the full frame.
full_count_field :: proc "contextless" (full: bool) -> [FULL_COUNT_FIELD_BYTES]u8 {
	return value_kinds.text_field(full ? "the count of the full frame" : "not the count of the full frame", FULL_COUNT_FIELD_BYTES)
}
