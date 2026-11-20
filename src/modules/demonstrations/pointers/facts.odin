package pointers

import "modus:contract/pointer_pictures"
import "modus:contract/value_kinds"

// The log facts of pointers (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before. The Text
// fields are the last fields: the serial line of a fact stops at its last
// byte that is not zero.
//
// Lines stay text: the lines with no value, and a theme that is not valid,
// whose sentence of the problem of up to 256 bytes passes the values of one
// fact.

// The bytes of the Text field of the name of a resource of the boot image:
// a name of at most 31 bytes.
RESOURCE_FIELD_BYTES :: 32
// The bytes of the Text field of the name and of the license of a theme:
// at most pointer_pictures.NAME_CAPACITY and LICENSE_CAPACITY bytes, and a
// zero byte.
THEME_TEXT_FIELD_BYTES :: 40
// The bytes of the Text field of the name of a shape: the longest,
// "resize_left_right", has 17 bytes.
SHAPE_FIELD_BYTES :: 24

// A press of a button of a theme: the window shows that theme.
@(log_fact = "pointers: the theme {theme} is shown")
Theme_Shown :: struct {
	theme: [32]u8,
}

// The pointer is over the tile of a shape.
@(log_fact = "pointers: the pointer is over the tile {shape}")
Pointer_Over_Tile :: struct {
	shape: [24]u8,
}

// A pointer theme of the boot image is valid: its header, its bytes, and
// the time of its hash and of its validation.
@(log_fact = "pointers: {theme}: {theme_name}, {license}, {shapes} shapes, {pictures} pictures, {file_size}; the hash and the validation in {check}")
Theme_Valid :: struct {
	shapes:     u64,
	pictures:   u64,
	file_size:  value_kinds.Size_In_Bytes,
	check:      value_kinds.Time_In_Microseconds,
	theme:      [32]u8,
	theme_name: [40]u8,
	license:    [40]u8,
}

// The window of a theme drawn.
@(log_fact = "pointers: ok, {themes} themes; the window of {theme} drawn in {drawing}")
Window_Drawn :: struct {
	themes:  u64,
	drawing: value_kinds.Time_In_Microseconds,
	theme:   [32]u8,
}

#assert(THEME_TEXT_FIELD_BYTES > pointer_pictures.NAME_CAPACITY && THEME_TEXT_FIELD_BYTES > pointer_pictures.LICENSE_CAPACITY)
#assert(size_of(Theme_Valid) == 32 + RESOURCE_FIELD_BYTES + 2 * THEME_TEXT_FIELD_BYTES)

// resource_field gives the Text field of the name of a resource.
resource_field :: proc "contextless" (name: string) -> [RESOURCE_FIELD_BYTES]u8 {
	return value_kinds.text_field(name, RESOURCE_FIELD_BYTES)
}

// theme_text_field gives the Text field of the name or of the license of a
// theme.
theme_text_field :: proc "contextless" (text: string) -> [THEME_TEXT_FIELD_BYTES]u8 {
	return value_kinds.text_field(text, THEME_TEXT_FIELD_BYTES)
}
