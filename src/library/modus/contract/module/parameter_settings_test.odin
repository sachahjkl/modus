#+build !freestanding
package module

import "core:testing"

// settings_file_of writes a module file with the exports of functions,
// export n + 1 with the description functions[n], and the rows of the
// table Parameter_Settings.
@(private = "file")
settings_file_of :: proc(functions: []Function, rows: []Parameter_Setting) -> []u8 {
	function_records := make([dynamic]Function, context.temp_allocator)
	export_records := make([dynamic]Export, context.temp_allocator)
	setting_records := make([dynamic]Parameter_Setting, context.temp_allocator)
	append(&function_records, Function{})
	append(&export_records, Export{})
	append(&setting_records, Parameter_Setting{})
	for item, index in functions {
		append(&function_records, item)
		append(&export_records, Export{function = u32(index + 1)})
	}
	append(&setting_records, ..rows)
	offset := size_of(Header) + TABLE_COUNT * size_of(Table_Entry)
	file := make([dynamic]u8, offset, context.temp_allocator)
	(^Header)(&file[0])^ = {magic = MAGIC, version = VERSION, header_size = size_of(Header), machine = .X86_64, table_count = TABLE_COUNT}
	place :: proc(file: ^[dynamic]u8, kind: Table_Kind, bytes: []u8, count: int, record_size: int) {
		entry := Table_Entry{offset = u64(len(file)), count = u32(count), record_size = u32(record_size)}
		append(file, ..bytes)
		(^Table_Entry)(&file[size_of(Header) + int(kind) * size_of(Table_Entry)])^ = entry
	}
	place(&file, .Exports, ([^]u8)(raw_data(export_records))[:len(export_records) * size_of(Export)], len(export_records), size_of(Export))
	place(&file, .Functions, ([^]u8)(raw_data(function_records))[:len(function_records) * size_of(Function)], len(function_records), size_of(Function))
	place(&file, .Parameter_Settings, ([^]u8)(raw_data(setting_records))[:len(setting_records) * size_of(Parameter_Setting)], len(setting_records), size_of(Parameter_Setting))
	return file[:]
}

// setter_with gives an export with an Integer parameter and an optional
// Enum parameter.
@(private = "file")
setter_with :: proc() -> (function: Function) {
	function.parameter_count = 2
	function.parameters[0] = u8(Type.Integer)
	function.parameters[1] = u8(Type.Enum)
	function.parameter_needs[1] = u8(Parameter_Need.Optional)
	function.result = u8(Type.Integer)
	return function
}

// The word of a Presence is refused past Given: 2, the largest word.
// Absent is 0, so a caller that gives zeros gives absence.
@(test)
a_presence_word_past_given_is_refused :: proc(t: ^testing.T) {
	for word in ([?]u64{2, 3, 0x100, max(u64)}) {
		_, ok := presence_of_word(Presence(word))
		testing.expectf(t, !ok, "the presence word %d is taken", word)
	}
	absent, absent_ok := presence_of_word(Presence(0))
	testing.expect(t, absent_ok && absent == .Absent)
	given, given_ok := presence_of_word(Presence(1))
	testing.expect(t, given_ok && given == .Given)
}

// The border of an optional parameter: a Presence word past Given refuses
// the pair whatever the value; Absent is not given, whatever the value;
// Given with a value that names no member is refused; Given with 0 is the
// value 0, never absence.
@(test)
an_optional_pair_is_read_at_its_border :: proc(t: ^testing.T) {
	Font :: enum u32 {
		Vector = 0,
		Spleen = 1,
	}
	for word in ([?]u64{2, max(u64)}) {
		_, given, ok := optional_member_of_arguments(Presence(word), Font.Spleen)
		testing.expectf(t, !given && !ok, "the presence %d is taken", word)
		_, integer_given, integer_ok := optional_integer_of_arguments(Presence(word), 5)
		testing.expectf(t, !integer_given && !integer_ok, "the presence %d of an Integer is taken", word)
	}
	_, given, ok := optional_member_of_arguments(.Given, Font(2))
	testing.expect(t, given && !ok)
	_, given, ok = optional_member_of_arguments(.Absent, Font(0xFFFF_FFFF))
	testing.expect(t, !given && ok)
	member: Font
	member, given, ok = optional_member_of_arguments(.Given, Font.Vector)
	testing.expect(t, given && ok && member == .Vector)
	integer, integer_given, integer_ok := optional_integer_of_arguments(.Given, 0)
	testing.expect(t, integer_given && integer_ok && integer == 0)
	integer, integer_given, integer_ok = optional_integer_of_arguments(.Absent, max(i64))
	testing.expect(t, !integer_given && integer_ok && integer == 0)
}

// The need of a parameter: a byte past Optional, Optional on a type that
// one word does not carry, a need past the parameters and a reserved field
// that is not 0 are refused, each at its parameter.
@(test)
a_need_that_breaks_a_rule_is_refused :: proc(t: ^testing.T) {
	Case :: struct {
		function:  Function,
		parameter: int,
	}
	past_member := setter_with()
	past_member.parameter_needs[0] = 2
	largest := setter_with()
	largest.parameter_needs[1] = max(u8)
	past_count := setter_with()
	past_count.parameter_needs[2] = u8(Parameter_Need.Optional)
	last := setter_with()
	last.parameter_needs[PARAMETER_CAPACITY - 1] = u8(Parameter_Need.Optional)
	reserved := setter_with()
	reserved.reserved = 1
	cases := [?]Case{{past_member, 0}, {largest, 1}, {past_count, 2}, {last, PARAMETER_CAPACITY - 1}, {reserved, -1}}
	for type in ([?]Type{.Text, .Record, .Table, .Bytes, .None}) {
		wrong := setter_with()
		wrong.parameters[1] = u8(type)
		parameter, valid := function_needs_check(wrong)
		testing.expectf(t, !valid && parameter == 1, "an optional %v gives %d, %v", type, parameter, valid)
	}
	for item in cases {
		parameter, valid := function_needs_check(item.function)
		testing.expectf(t, !valid && parameter == item.parameter, "%v gives %d, %v, not %d", item.function.parameter_needs, parameter, valid, item.parameter)
	}
	for type in ([?]Type{.Integer, .Handle, .Enum}) {
		taken := setter_with()
		taken.parameters[1] = u8(type)
		_, valid := function_needs_check(taken)
		testing.expectf(t, valid, "an optional %v is refused", type)
	}
}

// The words of the call form: an optional parameter takes two, its
// Presence word then its value. Twelve optional parameters take 24 words,
// past the capacity of a call.
@(test)
an_optional_parameter_takes_two_words :: proc(t: ^testing.T) {
	function := setter_with()
	testing.expect_value(t, parameter_word_count(function), 3)
	testing.expect_value(t, parameter_word_index(function, 0), 0)
	testing.expect_value(t, parameter_word_index(function, 1), 2)
	testing.expect_value(t, call_argument_count(parameter_word_count(function), u8(Type.Integer), true), 4)
	all: Function
	all.parameter_count = PARAMETER_CAPACITY
	for index in 0 ..< PARAMETER_CAPACITY {
		all.parameters[index] = u8(Type.Integer)
		all.parameter_needs[index] = u8(Parameter_Need.Optional)
	}
	testing.expect_value(t, parameter_word_count(all), 2 * PARAMETER_CAPACITY)
	testing.expect(t, call_argument_count(parameter_word_count(all), u8(Type.None), false) > CALL_WORD_CAPACITY)
	// A count past the capacity reads only the capacity.
	all.parameter_count = max(u8)
	testing.expect_value(t, parameter_word_count(all), 2 * PARAMETER_CAPACITY)
	testing.expect(t, !parameter_optional(all, -1) && !parameter_optional(all, PARAMETER_CAPACITY))
}

// A row of the table Parameter_Settings that breaks a rule is refused, at
// its row: no function, the entry, a parameter past the count, a range on
// an Enum, least above most, bytes of a range with no range, a choices or
// instances export that does not exist or has the wrong form, instances on
// a parameter other than the first, a row of nothing, a reserved field, two
// rows of one parameter and rows out of order.
@(test)
a_parameter_setting_that_breaks_a_rule_is_refused :: proc(t: ^testing.T) {
	choices := Function{result = u8(Type.Table)}
	with_parameter := choices
	with_parameter.parameter_count, with_parameter.parameters[0] = 1, u8(Type.Integer)
	integer_result := Function{result = u8(Type.Integer)}
	functions := []Function{setter_with(), choices, with_parameter, integer_result}
	Case :: struct {
		rows:    []Parameter_Setting,
		problem: Parameter_Setting_Problem,
		row:     u32,
	}
	ranged := Parameter_Setting{export_index = 1, parameter = 0, has_range = true, least = 1000, most = 60000}
	cases := [?]Case {
		{{{export_index = 0, parameter = 0, has_range = true}}, .No_Export, 1},
		{{{export_index = 5, parameter = 0, has_range = true}}, .No_Export, 1},
		{{{export_index = max(u32), parameter = 0, has_range = true}}, .No_Export, 1},
		{{{export_index = 1, parameter = 2, has_range = true}}, .No_Parameter, 1},
		{{{export_index = 1, parameter = max(u8), has_range = true}}, .No_Parameter, 1},
		{{{export_index = 1, parameter = 1, has_range = true}}, .Bad_Range, 1},
		{{{export_index = 1, parameter = 0, has_range = true, least = 2, most = 1}}, .Bad_Range, 1},
		{{{export_index = 1, parameter = 0, has_range = true, least = max(i64), most = min(i64)}}, .Bad_Range, 1},
		{{{export_index = 1, parameter = 0, choices_export = 2, most = 1}}, .Bad_Range, 1},
		{{{export_index = 1, parameter = 0, choices_export = 3}}, .Bad_Choices, 1},
		{{{export_index = 1, parameter = 0, choices_export = 4}}, .Bad_Choices, 1},
		{{{export_index = 1, parameter = 0, choices_export = 5}}, .Bad_Choices, 1},
		{{{export_index = 1, parameter = 1, choices_export = 2}}, .Bad_Choices, 1},
		{{{export_index = 1, parameter = 0, instances_export = 4}}, .Bad_Instances, 1},
		{{{export_index = 1, parameter = 0, instances_export = max(u32)}}, .Bad_Instances, 1},
		{{{export_index = 1, parameter = 1, instances_export = 2}}, .Bad_Instances, 1},
		{{{export_index = 1, parameter = 0}}, .Nothing, 1},
		{{{export_index = 1, parameter = 0, has_range = true, reserved = 1}}, .Nothing, 1},
		{{ranged, ranged}, .Out_Of_Order, 2},
		{{{export_index = 2, parameter = 0, has_range = true}, ranged}, .No_Parameter, 1},
	}
	for item in cases {
		file := settings_file_of(functions, item.rows)
		row, problem := parameter_settings_check(file)
		testing.expectf(t, problem == item.problem && row == item.row, "%v gives %v at %d, not %v at %d", item.rows, problem, row, item.problem, item.row)
	}
	// Two valid rows out of order.
	second := Parameter_Setting{export_index = 1, parameter = 0, choices_export = 2, instances_export = 2}
	other := settings_file_of({setter_with(), choices, setter_with()}, {{export_index = 3, parameter = 0, has_range = true}, second})
	row, problem := parameter_settings_check(other)
	testing.expect(t, problem == .Out_Of_Order && row == 2)
	// The rows that are taken, and the lookup of each.
	file := settings_file_of({setter_with(), choices, setter_with()}, {{export_index = 1, parameter = 0, has_range = true, least = min(i64), most = max(i64)}, {export_index = 3, parameter = 0, has_range = true, least = 5, most = 5, choices_export = 2, instances_export = 2}})
	row, problem = parameter_settings_check(file)
	testing.expect(t, problem == .None && row == 0)
	found_row, found := parameter_setting(file, 3, 0)
	testing.expect(t, found && found_row.least == 5 && found_row.choices_export == 2)
	_, absent := parameter_setting(file, 3, 1)
	_, past := parameter_setting(file, 1, PARAMETER_CAPACITY)
	_, negative := parameter_setting(file, 1, -1)
	testing.expect(t, !absent && !past && !negative)
}
