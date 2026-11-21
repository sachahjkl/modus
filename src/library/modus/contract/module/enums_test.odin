#+build !freestanding
package module

import "core:fmt"
import "core:testing"

// One enum of a test file: its name, its size and sign, and its members.
@(private = "file")
Test_Enum :: struct {
	name:     string,
	size:     u8,
	unsigned: bool,
	members:  []Test_Member,
	reserved: [6]u8,
}

@(private = "file")
Test_Member :: struct {
	name:  string,
	value: i64,
}

// The enums of most tests: a layout of the keyboard, and a font.
@(private = "file", rodata)
LAYOUT_MEMBERS := [2]Test_Member{{"united_states", 0}, {"french", 1}}
@(private = "file", rodata)
FONT_MEMBERS := [2]Test_Member{{"vector", 0}, {"spleen", 1}}

// file_of writes a module file with the exports of functions, export n + 1
// with the description functions[n], and the enums, enum n + 1 with
// enums[n]. The strings are each name, after the byte 0.
@(private = "file")
file_of :: proc(functions: []Function, enums: []Test_Enum) -> []u8 {
	strings := make([dynamic]u8, context.temp_allocator)
	append(&strings, 0)
	add :: proc(strings: ^[dynamic]u8, text: string) -> (offset: u32, count: u32) {
		offset = u32(len(strings))
		append(strings, ..transmute([]u8)text)
		return offset, u32(len(text))
	}
	enum_records := make([dynamic]Enum_Type, context.temp_allocator)
	member_records := make([dynamic]Member, context.temp_allocator)
	append(&enum_records, Enum_Type{})
	append(&member_records, Member{})
	for item in enums {
		described := Enum_Type{first_member = u32(len(member_records)), member_count = u32(len(item.members)), size = item.size, unsigned = item.unsigned, reserved = item.reserved}
		described.name_offset, described.name_count = add(&strings, item.name)
		append(&enum_records, described)
		for member in item.members {
			record_of_member := Member{value = member.value}
			record_of_member.name_offset, record_of_member.name_count = add(&strings, member.name)
			append(&member_records, record_of_member)
		}
	}
	function_records := make([dynamic]Function, context.temp_allocator)
	export_records := make([dynamic]Export, context.temp_allocator)
	append(&function_records, Function{})
	append(&export_records, Export{})
	for item, index in functions {
		append(&function_records, item)
		append(&export_records, Export{function = u32(index + 1)})
	}
	directory := size_of(Header)
	offset := directory + TABLE_COUNT * size_of(Table_Entry)
	file := make([dynamic]u8, offset, context.temp_allocator)
	(^Header)(&file[0])^ = {magic = MAGIC, version = VERSION, header_size = size_of(Header), machine = .X86_64, table_count = TABLE_COUNT}
	place :: proc(file: ^[dynamic]u8, kind: Table_Kind, bytes: []u8, count: int, record_size: int) {
		entry := Table_Entry{offset = u64(len(file)), count = u32(count), record_size = u32(record_size)}
		append(file, ..bytes)
		(^Table_Entry)(&file[size_of(Header) + int(kind) * size_of(Table_Entry)])^ = entry
	}
	place(&file, .Exports, ([^]u8)(raw_data(export_records))[:len(export_records) * size_of(Export)], len(export_records), size_of(Export))
	place(&file, .Functions, ([^]u8)(raw_data(function_records))[:len(function_records) * size_of(Function)], len(function_records), size_of(Function))
	place(&file, .Enums, ([^]u8)(raw_data(enum_records))[:len(enum_records) * size_of(Enum_Type)], len(enum_records), size_of(Enum_Type))
	place(&file, .Members, ([^]u8)(raw_data(member_records))[:len(member_records) * size_of(Member)], len(member_records), size_of(Member))
	place(&file, .Strings, strings[:], len(strings), 1)
	return file[:]
}

// enum_record_in gives the record of the enum index in the bytes of a file
// of file_of, for a test that breaks it.
@(private = "file")
enum_record_in :: proc(file: []u8, index: u32) -> ^Enum_Type {
	entry := (^Table_Entry)(&file[size_of(Header) + int(Table_Kind.Enums) * size_of(Table_Entry)])^
	return (^Enum_Type)(&file[entry.offset + u64(index) * u64(entry.record_size)])
}

// setter_of gives the description of an export with one Enum parameter of
// the enum enum_index, its getter the export getter, optional or not.
@(private = "file")
setter_of :: proc(enum_index, getter: u32, optional: bool) -> (function: Function) {
	function.parameter_count = 1
	function.parameters[0] = u8(Type.Enum)
	function.parameter_details[0], _ = enum_detail_make(enum_index, getter)
	function.result = u8(Type.Integer)
	function.optional_parameters = optional ? 1 : 0
	return function
}

// getter_of gives the description of an export with no parameter that
// gives the enum enum_index.
@(private = "file")
getter_of :: proc(enum_index: u32) -> Function {
	return {result = u8(Type.Enum), result_detail = enum_index}
}

// A byte of a type past Enum names no type: the first one past the last
// member, and the largest byte.
@(test)
a_type_byte_past_enum_is_refused :: proc(t: ^testing.T) {
	for word in ([2]u8{u8(max(Type)) + 1, max(u8)}) {
		_, ok := type_of_word(word)
		testing.expectf(t, !ok, "the type byte %d is taken", word)
	}
	type, ok := type_of_word(u8(Type.Enum))
	testing.expect(t, ok && type == .Enum)
}

// Each rule of an enum refuses its edges: the size, the reserved bytes,
// the count of members, each name and each value.
@(test)
an_enum_that_breaks_a_rule_is_refused :: proc(t: ^testing.T) {
	Case :: struct {
		item:    Test_Enum,
		problem: Enum_Problem,
	}
	too_many := make([]Test_Member, ENUM_MEMBER_CAPACITY + 1, context.temp_allocator)
	for &member, index in too_many {
		member = {name = fmt.tprintf("member_%d", index), value = i64(index)}
	}
	cases := [?]Case {
		{{"Font", 0, true, FONT_MEMBERS[:], {}}, .Bad_Size},
		{{"Font", 3, true, FONT_MEMBERS[:], {}}, .Bad_Size},
		{{"Font", 16, true, FONT_MEMBERS[:], {}}, .Bad_Size},
		{{"Font", max(u8), true, FONT_MEMBERS[:], {}}, .Bad_Size},
		{{"Font", 4, true, FONT_MEMBERS[:], {1, 0, 0, 0, 0, 0}}, .Bad_Size},
		{{"Font", 4, true, FONT_MEMBERS[:], {0, 0, 0, 0, 0, max(u8)}}, .Bad_Size},
		{{"Font", 4, true, nil, {}}, .Bad_Member_Count},
		{{"Font", 4, true, too_many, {}}, .Bad_Member_Count},
		{{"", 4, true, FONT_MEMBERS[:], {}}, .Bad_Member_Name},
		{{"Font", 4, true, {{"", 0}}, {}}, .Bad_Member_Name},
		{{"Font", 4, true, {{"Vector", 0}}, {}}, .Bad_Member_Name},
		{{"Font", 4, true, {{"1st", 0}}, {}}, .Bad_Member_Name},
		{{"Font", 4, true, {{"_vector", 0}}, {}}, .Bad_Member_Name},
		{{"Font", 4, true, {{"vec tor", 0}}, {}}, .Bad_Member_Name},
		{{"Font", 4, true, {{"vector.", 0}}, {}}, .Bad_Member_Name},
		{{"Font", 4, true, {{"abcdefghijklmnopqrstuvwxyzabcdef", 0}}, {}}, .Bad_Member_Name},
		{{"Font", 4, true, {{"vector", 0}, {"vector", 1}}, {}}, .Bad_Member_Name},
		{{"Font", 1, true, {{"vector", 256}}, {}}, .Bad_Member_Value},
		{{"Font", 1, true, {{"vector", -1}}, {}}, .Bad_Member_Value},
		{{"Font", 1, true, {{"vector", 255}}, {}}, .Bad_Member_Value},
		{{"Font", 1, false, {{"vector", 128}}, {}}, .Bad_Member_Value},
		{{"Font", 1, false, {{"vector", -129}}, {}}, .Bad_Member_Value},
		{{"Font", 1, false, {{"vector", -1}}, {}}, .Bad_Member_Value},
		{{"Font", 4, true, {{"vector", 0xFFFF_FFFF}}, {}}, .Bad_Member_Value},
		{{"Font", 4, true, {{"vector", 1 << 32}}, {}}, .Bad_Member_Value},
		{{"Font", 8, true, {{"vector", -1}}, {}}, .Bad_Member_Value},
		{{"Font", 8, false, {{"vector", -1}}, {}}, .Bad_Member_Value},
		{{"Font", 4, true, {{"vector", 1}, {"spleen", 1}}, {}}, .Bad_Member_Value},
	}
	for item in cases {
		file := file_of(nil, {item.item})
		_, problem := enum_type(file, 1)
		testing.expectf(t, problem == item.problem, "the enum %v gives %v, not %v", item.item, problem, item.problem)
	}
	// An index of no enum: 0, one past the table, and the largest index.
	file := file_of(nil, {{"Font", 4, true, FONT_MEMBERS[:], {}}})
	for index in ([3]u32{0, 2, max(u32)}) {
		_, problem := enum_type(file, index)
		testing.expect_value(t, problem, Enum_Problem.No_Enum)
	}
	// Members outside the table Members: the range ends one past the
	// table, starts past it, starts at its largest index, or starts at 0,
	// the record of no member, with members. The file has 2 members, at 1
	// and 2.
	Range :: struct {
		first, count: u32,
	}
	for item in ([?]Range{{2, 2}, {3, 1}, {max(u32), 1}, {max(u32), max(u32)}, {0, 1}, {0, 2}}) {
		ranged := file_of(nil, {{"Font", 4, true, FONT_MEMBERS[:], {}}})
		described := enum_record_in(ranged, 1)
		described.first_member, described.member_count = item.first, item.count
		_, problem := enum_type(ranged, 1)
		testing.expectf(t, problem == .Bad_Member_Count, "the members %v give %v", item, problem)
	}
	// The edges that are taken: a value at the top of each size and sign,
	// the last value under the absent word, a name of the largest length.
	taken := [?]Test_Enum {
		{"Font", 1, true, {{"a", 0}, {"b", 254}}, {}},
		{"Font", 1, false, {{"a", -128}, {"b", 127}}, {}},
		{"Font", 8, true, {{"a", 0}, {"b", max(i64)}, {"c", min(i64)}}, {}},
		{"Font", 4, true, {{"abcdefghijklmnopqrstuvwxyzabcde", 0}}, {}},
		{"Font", 4, true, too_many[:ENUM_MEMBER_CAPACITY], {}},
	}
	for item in taken {
		taken_file := file_of(nil, {item})
		_, problem := enum_type(taken_file, 1)
		testing.expectf(t, problem == .None, "the enum %v is refused: %v", item, problem)
	}
}

// The getter of a parameter is refused when it names no export, takes a
// parameter, gives an error record or no Enum, or gives another enum; an
// optional bit is refused on a parameter that is no Enum and past the
// parameters; an Enum result with the bits of a getter is refused.
@(test)
a_getter_or_an_optional_bit_that_breaks_a_rule_is_refused :: proc(t: ^testing.T) {
	enums := []Test_Enum{{"Keyboard_Layout", 4, true, LAYOUT_MEMBERS[:], {}}, {"Font", 4, true, FONT_MEMBERS[:], {}}}
	with_parameter := getter_of(1)
	with_parameter.parameter_count, with_parameter.parameters[0] = 1, u8(Type.Integer)
	with_error := getter_of(1)
	with_error.error_record = 1
	integer_result := Function{result = u8(Type.Integer)}
	Case :: struct {
		functions: []Function,
		problem:   Enum_Problem,
		parameter: int,
	}
	optional_integer := Function{parameter_count = 1, optional_parameters = 1}
	optional_integer.parameters[0] = u8(Type.Integer)
	optional_past := setter_of(1, 0, true)
	optional_past.optional_parameters = 0b10
	optional_largest := setter_of(1, 0, true)
	optional_largest.optional_parameters = max(u16)
	getter_bits_on_result := getter_of(1)
	getter_bits_on_result.result_detail, _ = enum_detail_make(1, 1)
	cases := [?]Case {
		{{setter_of(1, 2, false)}, .No_Getter, 0},
		{{setter_of(1, ENUM_DETAIL_INDEX_MOST, false)}, .No_Getter, 0},
		{{setter_of(1, 2, false), with_parameter}, .Bad_Getter, 0},
		{{setter_of(1, 2, false), with_error}, .Bad_Getter, 0},
		{{setter_of(1, 2, false), integer_result}, .Bad_Getter, 0},
		{{setter_of(1, 2, false), getter_of(2)}, .Getter_Type, 0},
		{{setter_of(1, 2, false), getter_of(3)}, .Getter_Type, 0},
		{{setter_of(0, 0, false)}, .No_Enum, 0},
		{{setter_of(3, 0, false)}, .No_Enum, 0},
		{{optional_integer}, .Bad_Optional, 0},
		{{optional_past}, .Bad_Optional, -1},
		{{optional_largest}, .Bad_Optional, -1},
		{{getter_bits_on_result}, .No_Enum, -1},
		{{getter_of(0)}, .No_Enum, -1},
	}
	for item in cases {
		file := file_of(item.functions, enums)
		described, _ := function(file, 1)
		parameter, problem := function_enums_check(file, described)
		testing.expectf(t, problem == item.problem && parameter == item.parameter, "%v gives %v at %d, not %v at %d", item.functions, problem, parameter, item.problem, item.parameter)
	}
	// The entry export is no getter, even with the form of one: it starts
	// the process, and no caller calls it.
	entry_file := file_of({setter_of(1, 2, false), getter_of(1)}, enums)
	(^Header)(&entry_file[0]).entry_export = 2
	entry_setter, _ := function(entry_file, 1)
	_, entry_problem := function_enums_check(entry_file, entry_setter)
	testing.expect_value(t, entry_problem, Enum_Problem.No_Getter)
	// The detail holds an index up to its largest, and refuses one past it.
	_, past_enum := enum_detail_make(ENUM_DETAIL_INDEX_MOST + 1, 0)
	_, past_getter := enum_detail_make(1, ENUM_DETAIL_INDEX_MOST + 1)
	_, largest := enum_detail_make(max(u32), max(u32))
	testing.expect(t, !past_enum && !past_getter && !largest)
	detail, made := enum_detail_make(ENUM_DETAIL_INDEX_MOST, ENUM_DETAIL_INDEX_MOST)
	enum_index, getter := enum_detail_of(detail)
	testing.expect(t, made && enum_index == ENUM_DETAIL_INDEX_MOST && getter == ENUM_DETAIL_INDEX_MOST)
	// The success comes last: a setter whose getter gives its enum, and a
	// setter with no getter.
	file := file_of({setter_of(1, 2, true), getter_of(1), setter_of(2, 0, false)}, enums)
	for export in ([3]u32{1, 2, 3}) {
		described, _ := function(file, export)
		_, problem := function_enums_check(file, described)
		testing.expectf(t, problem == .None, "the export %d is refused: %v", export, problem)
	}
}

// A name that no member has gives no value, and a member of another enum
// is no member: the console refuses both before the call.
@(test)
a_name_of_no_member_or_of_another_enum_gives_no_value :: proc(t: ^testing.T) {
	file := file_of(nil, {{"Keyboard_Layout", 4, true, LAYOUT_MEMBERS[:], {}}, {"Font", 4, true, FONT_MEMBERS[:], {}}})
	layout, layout_problem := enum_type(file, 1)
	font, font_problem := enum_type(file, 2)
	testing.expect(t, layout_problem == .None && font_problem == .None)
	for name in ([?]string{"", "germany", "French", "spleen", ".french", "french "}) {
		_, found := enum_value_of_name(file, layout, name)
		testing.expectf(t, !found, "the name %q is a member of Keyboard_Layout", name)
	}
	for value in ([?]i64{-1, 2, max(i64), min(i64)}) {
		_, found := enum_name_of_value(file, layout, value)
		testing.expectf(t, !found, "the value %d is a member of Keyboard_Layout", value)
	}
	testing.expect(t, !enums_equal(file, 1, file, 2))
	testing.expect(t, !enums_equal(file, 1, file, 0) && !enums_equal(file, 3, file, 3))
	value, found := enum_value_of_name(file, layout, "french")
	testing.expect(t, found && value == 1)
	name, named := enum_name_of_value(file, font, 1)
	testing.expect(t, named && name == "spleen")
	testing.expect(t, enums_equal(file, 1, file, 1))
}

// The integer result of a getter holds the enum in its low bytes only:
// the reader keeps those bytes and their sign, and the absent word is all
// ones of the size.
@(test)
the_result_of_a_getter_is_read_at_the_size_of_its_enum :: proc(t: ^testing.T) {
	unsigned_byte := Enum_Type{size = 1, unsigned = true}
	signed_byte := Enum_Type{size = 1, unsigned = false}
	unsigned_word := Enum_Type{size = 4, unsigned = true}
	whole := Enum_Type{size = 8, unsigned = true}
	testing.expect_value(t, enum_value_of_register(unsigned_byte, 0x7FFF_FF01), 1)
	testing.expect_value(t, enum_value_of_register(unsigned_byte, -1), 255)
	testing.expect_value(t, enum_value_of_register(signed_byte, 0xFF), -1)
	testing.expect_value(t, enum_value_of_register(signed_byte, 0x17F), 127)
	testing.expect_value(t, enum_value_of_register(unsigned_word, -1), 0xFFFF_FFFF)
	testing.expect_value(t, enum_value_of_register(whole, min(i64)), min(i64))
	testing.expect_value(t, enum_absent_word(unsigned_byte), 255)
	testing.expect_value(t, enum_absent_word(signed_byte), -1)
	testing.expect_value(t, enum_absent_word(unsigned_word), 0xFFFF_FFFF)
	testing.expect_value(t, enum_absent_word(whole), -1)
	// The absent word that a caller gives, -1 in the register, is the
	// absent word of each size once read at that size.
	for described in ([4]Enum_Type{unsigned_byte, signed_byte, unsigned_word, whole}) {
		testing.expect_value(t, enum_value_of_register(described, -1), enum_absent_word(described))
	}
}

// The check of a replacement refuses an Enum parameter of another enum,
// and one that a side may leave out and the other needs; the getter is
// not compared.
@(test)
a_replacement_with_another_enum_or_another_optional_bit_is_refused :: proc(t: ^testing.T) {
	enums := []Test_Enum{{"Keyboard_Layout", 4, true, LAYOUT_MEMBERS[:], {}}, {"Font", 4, true, FONT_MEMBERS[:], {}}}
	file := file_of({setter_of(1, 0, true), setter_of(2, 0, true), setter_of(1, 0, false), setter_of(1, 4, true), getter_of(1)}, enums)
	difference, parameter, _, _ := functions_compare(file, 1, file, 2)
	testing.expect(t, difference == .Parameter_Detail && parameter == 1)
	difference, parameter, _, _ = functions_compare(file, 1, file, 3)
	testing.expect(t, difference == .Parameter_Detail && parameter == 1)
	difference, _, _, _ = functions_compare(file, 1, file, 4)
	testing.expect_value(t, difference, Difference.None)
}
