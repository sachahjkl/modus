package module

import "base:intrinsics"
import "modus:contract/enum_word"

// The optional parameters and the settings of a parameter
// (src/md/features/module_settings.md, "The description of a parameter").
//
// An optional parameter crosses as a pair: a Presence word, then its value.
// Absent is 0, so a caller that passes zeros passes absence, and zero stays
// a real value when the word before it is Given. The pair is two words of
// the call form, not one struct of 16 bytes: the C convention passes such a
// struct on the stack when one register is left, and a later word then
// takes that register, so the words would no longer follow the parameters.

// The word before the value of an optional parameter. The border of an
// export refuses any other word (presence_of_word).
Presence :: enum u64 {
	Absent = 0, // The call leaves the parameter out: the value word is 0, and the export reads nothing in it.
	Given  = 1, // The value word holds the value, zero included.
}

// presence_of_word is the border of the word of a Presence: false for a
// word that names no member.
presence_of_word :: proc "contextless" (word: Presence) -> (presence: Presence, ok: bool) {
	return enum_word.member_of_word(Presence, u64(word))
}

// optional_member_of_arguments is the border of an optional Enum parameter
// of an export: its Presence word, then its value. given is false for
// Absent; ok is false for a Presence word that names no member, and for a
// Given value that names no member. The export answers ok false with an
// error record.
//
// Example: `optional_member_of_arguments(.Absent, Font(0))` is `{}, false,
// true`; `optional_member_of_arguments(.Given, Font(1))` is `.Spleen, true,
// true`; `optional_member_of_arguments(Presence(2), Font(0))` is `{},
// false, false`.
optional_member_of_arguments :: proc "contextless" (presence: Presence, argument: $Enum) -> (member: Enum, given: bool, ok: bool) where intrinsics.type_is_enum(Enum) {
	switch read, read_ok := presence_of_word(presence); {
	case !read_ok:
		return {}, false, false
	case read == .Absent:
		return {}, false, true
	}
	member, ok = enum_word.member_of_argument(argument)
	return member, true, ok
}

// optional_integer_of_arguments is the border of an optional Integer
// parameter: its Presence word, then its value. given is false for Absent,
// and ok is false for a Presence word that names no member. The range of
// the value is the check of the export.
optional_integer_of_arguments :: proc "contextless" (presence: Presence, value: i64) -> (integer: i64, given: bool, ok: bool) {
	switch read, read_ok := presence_of_word(presence); {
	case !read_ok:
		return 0, false, false
	case read == .Absent:
		return 0, false, true
	}
	return value, true, true
}

// Whether a call must give a parameter: one byte for each parameter of a
// Function (Function.parameter_needs).
Parameter_Need :: enum u8 {
	Required = 0, // One word of the call form: the value.
	Optional = 1, // Two words of the call form: a Presence word, then the value.
}

// parameter_need_of_word is the border of the byte of a Parameter_Need.
parameter_need_of_word :: proc "contextless" (word: u8) -> (need: Parameter_Need, ok: bool) {
	return enum_word.member_of_word(Parameter_Need, u64(word))
}

// parameter_optional says if a call may leave out the parameter index of
// an export: its need is Optional. A byte that names no need is not.
parameter_optional :: proc "contextless" (function: Function, index: int) -> bool {
	if index < 0 || index >= PARAMETER_CAPACITY {
		return false
	}
	need, ok := parameter_need_of_word(function.parameter_needs[index])
	return ok && need == .Optional
}

// optional_type_allowed says if a parameter of a type can be optional: a
// type that one word carries. A Text, a Record, a Table or Bytes is an
// address, and has no value to leave out.
optional_type_allowed :: proc "contextless" (type: Type) -> bool {
	#partial switch type {
	case .Integer, .Handle, .Enum:
		return true
	}
	return false
}

// function_needs_check checks the need of each parameter of an export:
// each byte names a Parameter_Need, Optional is on a type that one word
// carries (optional_type_allowed), each byte past the parameters is 0, and
// the reserved field is 0. parameter is the first parameter that breaks a
// rule, from 0, or -1 for the reserved field; valid is true for none.
function_needs_check :: proc "contextless" (function: Function) -> (parameter: int, valid: bool) {
	count := min(int(function.parameter_count), PARAMETER_CAPACITY)
	for word, index in function.parameter_needs {
		need, ok := parameter_need_of_word(word)
		if !ok || index >= count && need != .Required {
			return index, false
		}
		if need == .Optional {
			if type, type_ok := function_parameter_type(function, index); !type_ok || !optional_type_allowed(type) {
				return index, false
			}
		}
	}
	if function.reserved != 0 {
		return -1, false
	}
	return -1, true
}

// parameter_word_count gives the words of the call form that the
// parameters of an export take: one for each, two for each optional one.
parameter_word_count :: proc "contextless" (function: Function) -> int {
	count := min(int(function.parameter_count), PARAMETER_CAPACITY)
	words := 0
	for index in 0 ..< count {
		words += parameter_optional(function, index) ? 2 : 1
	}
	return words
}

// parameter_word_index gives the word of the call form that holds the
// value of the parameter index. The Presence word of an optional parameter
// is the word before it.
//
// Example: for (count: i64, font_presence: Presence, font: Font), the
// parameter 1, font, has its value in the word 2.
parameter_word_index :: proc "contextless" (function: Function, index: int) -> int {
	words := 0
	for before in 0 ..< min(index, PARAMETER_CAPACITY) {
		words += parameter_optional(function, before) ? 2 : 1
	}
	return words + (parameter_optional(function, index) ? 1 : 0)
}

// The settings of one parameter: its range, the export that gives its
// choices, and the export that gives its instances. The table
// Parameter_Settings holds one row for each parameter that has one, in the
// order of the export and of the parameter.
//
// Example: the parameter notification_show_milliseconds of the export set
// of the compositor has the range 1000 to 60000.
Parameter_Setting :: struct {
	export_index:     u32, // The export whose parameter this is: an index in the table Exports, from 1.
	parameter:        u8, // The parameter, from 0.
	has_range:        bool, // least and most hold the range of an Integer.
	reserved:         u16, // 0.
	least:            i64, // The least value that the export takes.
	most:             i64, // The largest value that the export takes.
	choices_export:   u32, // The export that gives the choices of an open set, 0 for none: no parameter, a Table result.
	instances_export: u32, // The export that gives the instances that the first parameter names, 0 for none: no parameter, a Table result.
}
#assert(size_of(Parameter_Setting) == 32)

// What parameter_settings_check refuses in a row.
Parameter_Setting_Problem :: enum u8 {
	None          = 0, // The row keeps each rule.
	No_Export     = 1, // The export index names no export, or names the entry.
	No_Parameter  = 2, // The parameter is past the parameters of its export.
	Bad_Range     = 3, // A range on a parameter that is no Integer, or least above most.
	Bad_Choices   = 4, // A choices export on a parameter that is no Integer, or an export that does not exist, takes a parameter or gives no Table.
	Bad_Instances = 5, // An instances export on a parameter other than the first, of no Integer, or an export that does not exist, takes a parameter or gives no Table.
	Nothing       = 6, // A row with no range, no choices and no instances, or a reserved field that is not 0.
	Out_Of_Order  = 7, // The row does not come after the row before it, in the order of the export and of the parameter: two rows of one parameter included.
}

// parameter_setting_row checks one row alone: its function, its parameter,
// its range and its two exports.
parameter_setting_row :: proc "contextless" (file: []u8, row: Parameter_Setting) -> Parameter_Setting_Problem {
	function, found := function_of_export(file, row.export_index)
	if !found {
		return .No_Export
	}
	if int(row.parameter) >= min(int(function.parameter_count), PARAMETER_CAPACITY) {
		return .No_Parameter
	}
	if row.reserved != 0 || !row.has_range && row.choices_export == 0 && row.instances_export == 0 {
		return .Nothing
	}
	type, type_ok := function_parameter_type(function, int(row.parameter))
	integer := type_ok && type == .Integer
	if row.has_range && (!integer || row.least > row.most) || !row.has_range && (row.least != 0 || row.most != 0) {
		return .Bad_Range
	}
	if row.choices_export != 0 && (!integer || !table_export(file, row.choices_export)) {
		return .Bad_Choices
	}
	if row.instances_export != 0 && (row.parameter != 0 || !integer || !table_export(file, row.instances_export)) {
		return .Bad_Instances
	}
	return .None
}

// table_export says if an export gives a table and takes no parameter: the
// form of a choices export and of an instances export.
@(private = "file")
table_export :: proc "contextless" (file: []u8, export_index: u32) -> bool {
	function, found := function_of_export(file, export_index)
	return found && function.parameter_count == 0 && function.result == u8(Type.Table)
}

// parameter_settings_check checks each row of the table
// Parameter_Settings, and that each row comes after the row before it. It
// gives the first row that breaks a rule, from 1, and why; 0 and None for a
// file whose rows keep each rule, or that has no row.
parameter_settings_check :: proc "contextless" (file: []u8) -> (row_index: u32, problem: Parameter_Setting_Problem) {
	before: Parameter_Setting
	for index in u32(1) ..< count(file, .Parameter_Settings) {
		row, _ := record(file, .Parameter_Settings, index, Parameter_Setting)
		if row_problem := parameter_setting_row(file, row); row_problem != .None {
			return index, row_problem
		}
		if index > 1 && u64(row.export_index) << 8 | u64(row.parameter) <= u64(before.export_index) << 8 | u64(before.parameter) {
			return index, .Out_Of_Order
		}
		before = row
	}
	return 0, .None
}

// parameter_setting gives the settings of the parameter index of the
// export export_index: found is false when the file has no row for it.
parameter_setting :: proc "contextless" (file: []u8, export_index: u32, index: int) -> (row: Parameter_Setting, found: bool) {
	if index < 0 || index >= PARAMETER_CAPACITY {
		return {}, false
	}
	key := u64(export_index) << 8 | u64(index)
	low, high := u32(1), count(file, .Parameter_Settings)
	for low < high {
		middle := low + (high - low) / 2
		candidate, candidate_found := record(file, .Parameter_Settings, middle, Parameter_Setting)
		if !candidate_found {
			return {}, false
		}
		candidate_key := u64(candidate.export_index) << 8 | u64(candidate.parameter)
		switch {
		case candidate_key == key:
			return candidate, true
		case candidate_key < key:
			low = middle + 1
		case:
			high = middle
		}
	}
	return {}, false
}
