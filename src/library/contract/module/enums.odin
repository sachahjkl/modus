package module

// The enums of the exports (src/md/features/enum_parameters.md): a
// parameter or a result of the type Enum takes one member of a closed set.
// The module file names the members, so each front end reads one
// description: the completion of the console, the check of a line before
// its call, and the row of buttons of the palette.
//
// An enum is an Enum_Type record of the table Enums, with its members in
// the table Members, one after the other. A call carries the value of the
// member in a register: the callee reads the low bytes of the size of the
// enum, as the compiler of its source passes an enum of that size.
//
// An Enum parameter can name an export of its module that gives the value
// in use, its getter: the palette marks the button of that value. The
// pairing is written in the file; no reader finds a getter by its name.
//
// A file comes from its build or from a disk: each reader takes an enum
// through enum_type, which refuses a description that breaks a rule.

// The description of one enum.
//
// Example: `settings.Keyboard_Layout` is the enum "Keyboard_Layout" of 4
// unsigned bytes, with the members `united_states` = 0 and `french` = 1.
Enum_Type :: struct {
	name_offset:  u32, // In the string table: the name of the type in its source.
	name_count:   u32, // The bytes of the name.
	first_member: u32, // An index in the member table. The members of an enum follow each other.
	member_count: u32, // From 1 to ENUM_MEMBER_CAPACITY.
	size:         u8, // The bytes of a value: 1, 2, 4 or 8, the backing type of the source.
	unsigned:     bool, // The backing type has no sign.
	reserved:     [6]u8, // 0.
}
#assert(size_of(Enum_Type) == 24)

// One member of an enum: its name, as a line names it after a ".", and its
// value, the word that a call carries.
Member :: struct {
	name_offset: u32, // In the string table.
	name_count:  u32, // From 1 to ENUM_MEMBER_NAME_CAPACITY bytes: a lower case letter, then lower case letters, digits and "_".
	value:       i64, // Fits the size and the sign of its enum. An unsigned value of 8 bytes is its bits.
}
#assert(size_of(Member) == 16)

ENUM_MEMBER_CAPACITY :: 64 // The members of one enum at most: the palette shows each one as a button or a candidate.
ENUM_MEMBER_NAME_CAPACITY :: 31 // The bytes of the name of a member at most: a candidate of the palette holds it.
ENUM_DETAIL_INDEX_MOST :: 0xFFFF // The largest index of an enum, and of a getter, that the detail of a parameter holds.

// What enum_type and function_enums_check refuse.
Enum_Problem :: enum u8 {
	None             = 0, // The enums of the function keep each rule.
	No_Enum          = 1, // The detail names no enum of the table Enums, or an enum result has bits of a getter.
	Bad_Size         = 2, // The size is not 1, 2, 4 or 8, or a reserved byte is not 0.
	Bad_Member_Count = 3, // No member, more than ENUM_MEMBER_CAPACITY, or members outside the table Members.
	Bad_Member_Name  = 4, // A name that is empty, too long, not a name of Lex in lower case, outside the string table, or given twice.
	Bad_Member_Value = 5, // A value that the size and the sign do not hold, the absent word, or a value given twice.
	No_Getter        = 6, // The getter names no export of the module.
	Bad_Getter       = 7, // The getter takes a parameter, gives an error record, or gives no Enum.
	Getter_Type      = 8, // The getter gives another enum than its parameter takes.
	Bad_Optional     = 9, // An optional bit on a parameter that is no Enum, or past the parameters.
}

// enum_detail_of reads the detail of an Enum parameter: the index of its
// enum in the table Enums, and the index of its getter in the table
// Exports, 0 for none.
enum_detail_of :: proc "contextless" (detail: u32) -> (enum_index: u32, getter: u32) {
	return detail & 0xFFFF, detail >> 16
}

// enum_detail_make gives the detail of an Enum parameter. ok is false for
// an index of an enum or a getter past ENUM_DETAIL_INDEX_MOST.
enum_detail_make :: proc "contextless" (enum_index: u32, getter: u32) -> (detail: u32, ok: bool) {
	if enum_index > ENUM_DETAIL_INDEX_MOST || getter > ENUM_DETAIL_INDEX_MOST {
		return 0, false
	}
	return enum_index | getter << 16, true
}

// parameter_optional says if a call may leave out the parameter index of
// an export.
parameter_optional :: proc "contextless" (function: Function, index: int) -> bool {
	return index >= 0 && index < PARAMETER_CAPACITY && function.optional_parameters >> u16(index) & 1 != 0
}

// enum_value_fits says if a value is one that an enum of a size and a sign
// holds.
enum_value_fits :: proc "contextless" (size: u8, unsigned: bool, value: i64) -> bool {
	if size == 8 {
		return true
	}
	bits := 8 * u64(size)
	if unsigned {
		return value >= 0 && u64(value) < u64(1) << bits
	}
	return value >= -(i64(1) << (bits - 1)) && value < i64(1) << (bits - 1)
}

// enum_absent_word gives the word that a call gives for an optional Enum
// parameter that it leaves out: each bit of the size of the enum set. A
// callee that reads the low bytes of the register reads all ones; no member
// has that value (enum_type refuses it).
enum_absent_word :: proc "contextless" (of: Enum_Type) -> i64 {
	if of.size >= 8 || !of.unsigned {
		return -1
	}
	return i64(u64(1) << (8 * u64(of.size)) - 1)
}

// enum_value_of_register reads the integer result of an export that gives
// an Enum: the low bytes of the size of the enum, with its sign. The callee
// writes only those bytes, as its compiler gives an enum of that size.
enum_value_of_register :: proc "contextless" (of: Enum_Type, register: i64) -> i64 {
	if of.size >= 8 || of.size == 0 {
		return register
	}
	bits := 8 * u64(of.size)
	low := u64(register) & (u64(1) << bits - 1)
	if !of.unsigned && low >> (bits - 1) & 1 != 0 {
		low |= ~u64(0) << bits // The sign.
	}
	return i64(low)
}

// enum_member_name_valid says if a name is a name of a member: a lower case
// letter, then lower case letters, digits and "_", as Lex reads a name
// after a ".".
enum_member_name_valid :: proc "contextless" (name: string) -> bool {
	if len(name) == 0 || len(name) > ENUM_MEMBER_NAME_CAPACITY || name[0] < 'a' || name[0] > 'z' {
		return false
	}
	for index in 0 ..< len(name) {
		character := name[index]
		if !(character >= 'a' && character <= 'z' || character >= '0' && character <= '9' || character == '_') {
			return false
		}
	}
	return true
}

// enum_member gives the member number of an enum, from 0, without a check
// of its name or value: enum_type checked each one.
enum_member :: proc "contextless" (file: []u8, of: Enum_Type, number: u32) -> (value: Member, ok: bool) {
	if number >= of.member_count || of.first_member == 0 {
		return {}, false
	}
	return record(file, .Members, of.first_member + number, Member)
}

// enum_type gives the description of an enum, by its index in the table
// Enums, after it checked it: its size, its count of members, and each
// name and value. problem says why it refused.
enum_type :: proc "contextless" (file: []u8, index: u32) -> (value: Enum_Type, problem: Enum_Problem) {
	if index == 0 {
		return {}, .No_Enum
	}
	ok: bool
	value, ok = record(file, .Enums, index, Enum_Type)
	if !ok {
		return {}, .No_Enum
	}
	switch value.size {
	case 1, 2, 4, 8:
	case:
		return {}, .Bad_Size
	}
	if value.reserved != {} {
		return {}, .Bad_Size
	}
	members := count(file, .Members)
	if value.member_count == 0 || value.member_count > ENUM_MEMBER_CAPACITY || value.first_member == 0 || u64(value.first_member) + u64(value.member_count) > u64(members) {
		return {}, .Bad_Member_Count
	}
	if name := string_at(file, value.name_offset, value.name_count); len(name) == 0 {
		return {}, .Bad_Member_Name
	}
	absent := enum_absent_word(value)
	for number in 0 ..< value.member_count {
		item, item_ok := enum_member(file, value, number)
		if !item_ok {
			return {}, .Bad_Member_Count
		}
		name := string_at(file, item.name_offset, item.name_count)
		if u32(len(name)) != item.name_count || !enum_member_name_valid(name) {
			return {}, .Bad_Member_Name
		}
		if !enum_value_fits(value.size, value.unsigned, item.value) || item.value == absent {
			return {}, .Bad_Member_Value
		}
		for earlier in 0 ..< number {
			other, _ := enum_member(file, value, earlier)
			if string_at(file, other.name_offset, other.name_count) == name {
				return {}, .Bad_Member_Name
			}
			if other.value == item.value {
				return {}, .Bad_Member_Value
			}
		}
	}
	return value, .None
}

// enum_value_of_name gives the value of the member of an enum with a name.
// found is false for a name that no member has.
enum_value_of_name :: proc "contextless" (file: []u8, of: Enum_Type, name: string) -> (value: i64, found: bool) {
	for number in 0 ..< of.member_count {
		item := enum_member(file, of, number) or_continue
		if string_at(file, item.name_offset, item.name_count) == name {
			return item.value, true
		}
	}
	return 0, false
}

// enum_name_of_value gives the name of the member of an enum with a value.
// found is false for a value that no member has: a reader then writes the
// number, never the name of another member.
enum_name_of_value :: proc "contextless" (file: []u8, of: Enum_Type, value: i64) -> (name: string, found: bool) {
	for number in 0 ..< of.member_count {
		item := enum_member(file, of, number) or_continue
		if item.value == value {
			return string_at(file, item.name_offset, item.name_count), true
		}
	}
	return "", false
}

// enum_name gives the name of an enum: the name of its type in its source.
enum_name :: proc "contextless" (file: []u8, of: Enum_Type) -> string {
	return string_at(file, of.name_offset, of.name_count)
}

// enums_equal says if two descriptions of an enum are equal: the same
// name, size and sign, and the same members with the same values, in the
// same order. The two enums can be in two modules: an enum has no identity
// but its description.
enums_equal :: proc "contextless" (file: []u8, index: u32, other_file: []u8, other_index: u32) -> bool {
	first, first_problem := enum_type(file, index)
	second, second_problem := enum_type(other_file, other_index)
	if first_problem != .None || second_problem != .None {
		return false
	}
	if first.size != second.size || first.unsigned != second.unsigned || first.member_count != second.member_count || enum_name(file, first) != enum_name(other_file, second) {
		return false
	}
	for number in 0 ..< first.member_count {
		a := enum_member(file, first, number) or_return
		b := enum_member(other_file, second, number) or_return
		if a.value != b.value || string_at(file, a.name_offset, a.name_count) != string_at(other_file, b.name_offset, b.name_count) {
			return false
		}
	}
	return true
}

// function_enums_check checks the enums of the description of an export:
// each Enum parameter names a valid enum, and a getter that is an export
// with no parameter and no error record whose result is an equal enum;
// each optional bit is on an Enum parameter; an Enum result names a valid
// enum and no getter. parameter is the parameter of the problem, from 0,
// or -1 for the result and for the optional bits.
function_enums_check :: proc "contextless" (file: []u8, function: Function) -> (parameter: int, problem: Enum_Problem) {
	function := function
	count := min(int(function.parameter_count), PARAMETER_CAPACITY)
	for word, index in function.parameters[:count] {
		if word != u8(Type.Enum) {
			if parameter_optional(function, index) {
				return index, .Bad_Optional
			}
			continue
		}
		enum_index, getter := enum_detail_of(function.parameter_details[index])
		if _, found := enum_type(file, enum_index); found != .None {
			return index, found
		}
		if getter == 0 {
			continue
		}
		getter_function, getter_found := function_of_export(file, getter)
		if !getter_found {
			return index, .No_Getter
		}
		if getter_function.parameter_count != 0 || getter_function.error_record != 0 || getter_function.result != u8(Type.Enum) {
			return index, .Bad_Getter
		}
		if !enums_equal(file, enum_index, file, getter_function.result_detail) {
			return index, .Getter_Type
		}
	}
	if function.optional_parameters >> u16(count) != 0 {
		return -1, .Bad_Optional
	}
	if function.result == u8(Type.Enum) {
		enum_index, getter := enum_detail_of(function.result_detail)
		if getter != 0 {
			return -1, .No_Enum
		}
		if _, found := enum_type(file, enum_index); found != .None {
			return -1, found
		}
	}
	return -1, .None
}

// function_of_export gives the description of an export, by its index,
// for a check of a getter: the index 0, an index past the table and the
// entry export are none. The entry starts the process: no caller calls it.
@(private)
function_of_export :: proc "contextless" (file: []u8, export_index: u32) -> (value: Function, ok: bool) {
	if export_index == 0 || export_index >= count(file, .Exports) {
		return {}, false
	}
	if head, head_error := header(file); head_error != .None || export_index == head.entry_export {
		return {}, false
	}
	return function(file, export_index)
}
