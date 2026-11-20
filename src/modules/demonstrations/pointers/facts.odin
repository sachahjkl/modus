package pointers

import "modus:contract/pointer_pictures"
import "modus:contract/value_kinds"
import "modus:support/system"

// The log facts of pointers (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before. The Text
// fields are the last fields: the serial line of a fact stops at its last
// byte that is not zero.

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

// A theme that is not valid writes the parts of its problem
// (pointer_pictures.sentence): the part of the file, the entry or the
// pixel, the field, the words of the rule, the value and the limit. The
// three texts and the three numbers fill the 144 bytes of one fact, so the
// name of the theme is in the template: one fact type for each theme of
// RESOURCE_PREFERENCE and each form of the part.

// The bytes of the Text fields of a problem of a theme: a part has at most
// 17 bytes, a field 27 and the words of a rule 60.
PART_FIELD_BYTES :: 24
FIELD_NAME_FIELD_BYTES :: 32
RULE_FIELD_BYTES :: 64

// The boot image gives no image to read.
@(log_fact = "pointers: no boot image")
No_Boot_Image :: struct {}

// The boot image has no pointer theme: the process stops.
@(log_fact = "pointers: the boot image has no pointer theme")
No_Pointer_Theme :: struct {}

// The theme of the owner does not have the hash of its entry.
@(log_fact = "pointers: pointers_posy is not valid: the bytes do not have the hash of the entry of the resource")
Owner_Theme_Hash_Differs :: struct {}

// The theme of the system does not have the hash of its entry.
@(log_fact = "pointers: pointers_system is not valid: the bytes do not have the hash of the entry of the resource")
System_Theme_Hash_Differs :: struct {}

// The theme of the owner breaks a rule in a part of no entry.
@(log_fact = "pointers: pointers_posy is not valid: {part}: {field} {rule} (value {value}, limit {limit})")
Owner_Theme_Not_Valid :: struct {
	value: u64,
	limit: u64,
	part:  [24]u8,
	field: [32]u8,
	rule:  [64]u8,
}

// The theme of the owner breaks a rule in an entry of a table.
@(log_fact = "pointers: pointers_posy is not valid: {part}, entry {index}: {field} {rule} (value {value}, limit {limit})")
Owner_Theme_Entry_Not_Valid :: struct {
	index: u64,
	value: u64,
	limit: u64,
	part:  [24]u8,
	field: [32]u8,
	rule:  [64]u8,
}

// The theme of the owner breaks a rule in a pixel.
@(log_fact = "pointers: pointers_posy is not valid: {part}, pixel {index}: {field} {rule} (value {value}, limit {limit})")
Owner_Theme_Pixel_Not_Valid :: struct {
	index: u64,
	value: u64,
	limit: u64,
	part:  [24]u8,
	field: [32]u8,
	rule:  [64]u8,
}

// The theme of the system breaks a rule in a part of no entry.
@(log_fact = "pointers: pointers_system is not valid: {part}: {field} {rule} (value {value}, limit {limit})")
System_Theme_Not_Valid :: struct {
	value: u64,
	limit: u64,
	part:  [24]u8,
	field: [32]u8,
	rule:  [64]u8,
}

// The theme of the system breaks a rule in an entry of a table.
@(log_fact = "pointers: pointers_system is not valid: {part}, entry {index}: {field} {rule} (value {value}, limit {limit})")
System_Theme_Entry_Not_Valid :: struct {
	index: u64,
	value: u64,
	limit: u64,
	part:  [24]u8,
	field: [32]u8,
	rule:  [64]u8,
}

// The theme of the system breaks a rule in a pixel.
@(log_fact = "pointers: pointers_system is not valid: {part}, pixel {index}: {field} {rule} (value {value}, limit {limit})")
System_Theme_Pixel_Not_Valid :: struct {
	index: u64,
	value: u64,
	limit: u64,
	part:  [24]u8,
	field: [32]u8,
	rule:  [64]u8,
}

#assert(pointer_pictures.RESOURCE_OF_THE_OWNER == "pointers_posy" && pointer_pictures.RESOURCE_OF_THE_SYSTEM == "pointers_system" && len(pointer_pictures.RESOURCE_PREFERENCE) == 2)
#assert(size_of(System_Theme_Entry_Not_Valid) == 24 + PART_FIELD_BYTES + FIELD_NAME_FIELD_BYTES + RULE_FIELD_BYTES)

// theme_not_valid_log writes the fact of a theme that is not valid: by its
// hash, or by the problem that validate found.
theme_not_valid_log :: proc "contextless" (resource: string, hash_differs: bool, problem: pointer_pictures.Problem) {
	owner := resource == pointer_pictures.RESOURCE_OF_THE_OWNER
	if hash_differs {
		if owner {
			system.log_fact(.Info, Owner_Theme_Hash_Differs{})
		} else {
			system.log_fact(.Info, System_Theme_Hash_Differs{})
		}
		return
	}
	part := value_kinds.text_field(pointer_pictures.PART_NAMES[problem.part], PART_FIELD_BYTES)
	field := value_kinds.text_field(pointer_pictures.FIELD_NAMES[problem.field], FIELD_NAME_FIELD_BYTES)
	rule := value_kinds.text_field(pointer_pictures.KIND_SENTENCES[problem.kind], RULE_FIELD_BYTES)
	switch {
	case problem.part == .Pixels && owner:
		system.log_fact(.Info, Owner_Theme_Pixel_Not_Valid{index = problem.index, value = problem.value, limit = problem.limit, part = part, field = field, rule = rule})
	case problem.part == .Pixels:
		system.log_fact(.Info, System_Theme_Pixel_Not_Valid{index = problem.index, value = problem.value, limit = problem.limit, part = part, field = field, rule = rule})
	case (problem.part == .Shapes || problem.part == .Pictures) && owner:
		system.log_fact(.Info, Owner_Theme_Entry_Not_Valid{index = problem.index, value = problem.value, limit = problem.limit, part = part, field = field, rule = rule})
	case problem.part == .Shapes || problem.part == .Pictures:
		system.log_fact(.Info, System_Theme_Entry_Not_Valid{index = problem.index, value = problem.value, limit = problem.limit, part = part, field = field, rule = rule})
	case owner:
		system.log_fact(.Info, Owner_Theme_Not_Valid{value = problem.value, limit = problem.limit, part = part, field = field, rule = rule})
	case:
		system.log_fact(.Info, System_Theme_Not_Valid{value = problem.value, limit = problem.limit, part = part, field = field, rule = rule})
	}
}

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
