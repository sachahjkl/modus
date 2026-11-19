#+build !freestanding
package value_kinds

import "core:testing"

// A record of 168 bytes, as a log record holds (operation.LOG_TEXT_CAPACITY):
// this package does not import the operation contract, so the tests name
// the number. Each test derives its places from it.
TEST_RECORD_TEXT :: 168
TEST_RECORD_RUNS :: 8

// The field of a name keeps a zero byte at its end, whatever the length of
// the name: a name of the field size less one is whole, a name of the
// field size and one longer are cut before the last byte, and an empty
// name is a field of zeros. The bytes past the name are zero.
@(test)
a_field_of_a_name_keeps_its_last_byte_zero :: proc(t: ^testing.T) {
	Case :: struct {
		name: string,
		kept: int, // The bytes of the name in the field.
	}
	letters := "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"
	module_cases := [?]Case {
		{"", 0},
		{letters[:1], 1},
		{letters[:MODULE_NAME_FIELD_BYTES - 1], MODULE_NAME_FIELD_BYTES - 1},
		{letters[:MODULE_NAME_FIELD_BYTES], MODULE_NAME_FIELD_BYTES - 1},
		{letters[:MODULE_NAME_FIELD_BYTES + 1], MODULE_NAME_FIELD_BYTES - 1},
	}
	for item in module_cases {
		field := module_name_field(item.name)
		testing.expectf(t, string(field[:item.kept]) == item.name[:item.kept], "the name of %d bytes keeps %q", len(item.name), string(field[:item.kept]))
		for value, index in field[item.kept:] {
			testing.expectf(t, value == 0, "the name of %d bytes leaves the byte %d at %d", len(item.name), item.kept + index, value)
		}
	}
	TEXT_BYTES :: 24
	text_cases := [?]Case {
		{"", 0},
		{letters[:TEXT_BYTES - 1], TEXT_BYTES - 1},
		{letters[:TEXT_BYTES], TEXT_BYTES - 1},
		{letters[:TEXT_BYTES + 1], TEXT_BYTES - 1},
	}
	for item in text_cases {
		field := text_field(item.name, TEXT_BYTES)
		testing.expectf(t, string(field[:item.kept]) == item.name[:item.kept], "the text of %d bytes keeps %q", len(item.name), string(field[:item.kept]))
		for value, index in field[item.kept:] {
			testing.expectf(t, value == 0, "the text of %d bytes leaves the byte %d at %d", len(item.name), item.kept + index, value)
		}
	}
	// The least field: one byte, always zero.
	least := text_field("a", 1)
	testing.expect_value(t, least[0], u8(0))
}

// A text with no value: no run in its record.
@(test)
a_record_with_no_run :: proc(t: ^testing.T) {
	runs: [4]Value_Run_In_Call
	count := 0
	value_run_add(runs[:], &count, 0, 12, .None)
	value_run_add(runs[:], &count, 5, 5, .Number)
	testing.expect_value(t, count, 0)
	into: [TEST_RECORD_RUNS]Value_Run
	testing.expect_value(t, value_runs_of_record(runs[:count], 0, TEST_RECORD_TEXT, into[:]), 0)
}

// "kernel: free memory 2013 MiB": one run of the kind Size over "2013 MiB".
@(test)
a_record_with_one_run :: proc(t: ^testing.T) {
	text := "kernel: free memory 2013 MiB"
	runs: [4]Value_Run_In_Call
	count := 0
	value_run_add(runs[:], &count, 20, len(text), .Size)
	testing.expect(t, value_runs_check(runs[:count], len(text)))
	into: [TEST_RECORD_RUNS]Value_Run
	kept := value_runs_of_record(runs[:count], 0, len(text), into[:])
	testing.expect_value(t, kept, 1)
	start, end, kind, ok := value_run_in_text(into[0], len(text))
	testing.expect(t, ok)
	testing.expect_value(t, text[start:end], "2013 MiB")
	testing.expect_value(t, kind, Value_Kind.Size)
}

// A record keeps at most its capacity of runs: the first ones, in order;
// the text after them is plain.
@(test)
a_record_with_the_most_runs_and_more_parts :: proc(t: ^testing.T) {
	runs: [32]Value_Run_In_Call
	count := 0
	for index in 0 ..< 12 {
		value_run_add(runs[:], &count, index * 10, index * 10 + 3, .Number)
	}
	testing.expect_value(t, count, 12)
	testing.expect(t, value_runs_check(runs[:count], 120))
	into: [TEST_RECORD_RUNS]Value_Run
	kept := value_runs_of_record(runs[:count], 0, 120, into[:])
	testing.expect_value(t, kept, TEST_RECORD_RUNS)
	for index in 0 ..< kept {
		testing.expect_value(t, int(into[index].start), index * 10)
		testing.expect_value(t, int(into[index].length), 3)
	}
	// A writer whose table of runs is full adds none: those parts are plain.
	small: [2]Value_Run_In_Call
	small_count := 0
	for index in 0 ..< 5 {
		value_run_add(small[:], &small_count, index * 4, index * 4 + 2, .Time)
	}
	testing.expect_value(t, small_count, 2)
}

// A run that crosses the bound of two records is one run in each, from the
// start of each record.
@(test)
a_run_across_two_records :: proc(t: ^testing.T) {
	// 12 bytes of the first run in the first record, 8 in the second.
	BEFORE_THE_BOUND :: 12
	AFTER_THE_BOUND :: 8
	SECOND_RUN_START :: 48
	runs := [?]Value_Run_In_Call{{start = TEST_RECORD_TEXT - BEFORE_THE_BOUND, length = BEFORE_THE_BOUND + AFTER_THE_BOUND, kind = u8(Value_Kind.Version)}, {start = TEST_RECORD_TEXT + SECOND_RUN_START, length = 4, kind = u8(Value_Kind.Number)}}
	testing.expect(t, value_runs_check(runs[:], 2 * TEST_RECORD_TEXT))
	first: [TEST_RECORD_RUNS]Value_Run
	testing.expect_value(t, value_runs_of_record(runs[:], 0, TEST_RECORD_TEXT, first[:]), 1)
	testing.expect_value(t, first[0], Value_Run{start = TEST_RECORD_TEXT - BEFORE_THE_BOUND, length = BEFORE_THE_BOUND, kind = u8(Value_Kind.Version)})
	second: [TEST_RECORD_RUNS]Value_Run
	testing.expect_value(t, value_runs_of_record(runs[:], TEST_RECORD_TEXT, TEST_RECORD_TEXT, second[:]), 2)
	testing.expect_value(t, second[0], Value_Run{start = 0, length = AFTER_THE_BOUND, kind = u8(Value_Kind.Version)})
	testing.expect_value(t, second[1], Value_Run{start = SECOND_RUN_START, length = 4, kind = u8(Value_Kind.Number)})
}

// The cut mark ends a text: no run colors the mark. The rest of a text that
// a writer sends as a second line keeps its runs, from its own start.
@(test)
runs_cut_and_after :: proc(t: ^testing.T) {
	runs := [?]Value_Run_In_Call{{start = 2, length = 4, kind = u8(Value_Kind.Number)}, {start = 10, length = 10, kind = u8(Value_Kind.Size)}, {start = 30, length = 2, kind = u8(Value_Kind.Time)}}
	cut := runs
	testing.expect_value(t, value_runs_cut(cut[:], 3, 15), 2)
	testing.expect_value(t, cut[1], Value_Run_In_Call{start = 10, length = 5, kind = u8(Value_Kind.Size)})
	after := runs
	testing.expect_value(t, value_runs_after(after[:], 3, 15), 2)
	testing.expect_value(t, after[0], Value_Run_In_Call{start = 0, length = 5, kind = u8(Value_Kind.Size)})
	testing.expect_value(t, after[1], Value_Run_In_Call{start = 15, length = 2, kind = u8(Value_Kind.Time)})
}

// The runs come from another process: each wrong table is refused whole.
@(test)
hostile_runs_are_refused :: proc(t: ^testing.T) {
	past_the_text := [?]Value_Run_In_Call{{start = 8, length = 4, kind = u8(Value_Kind.Number)}}
	testing.expect(t, !value_runs_check(past_the_text[:], 10))
	empty := [?]Value_Run_In_Call{{start = 0, length = 0, kind = u8(Value_Kind.Number)}}
	testing.expect(t, !value_runs_check(empty[:], 10))
	out_of_order := [?]Value_Run_In_Call{{start = 5, length = 2, kind = u8(Value_Kind.Number)}, {start = 1, length = 2, kind = u8(Value_Kind.Number)}}
	testing.expect(t, !value_runs_check(out_of_order[:], 10))
	overlap := [?]Value_Run_In_Call{{start = 1, length = 4, kind = u8(Value_Kind.Number)}, {start = 3, length = 2, kind = u8(Value_Kind.Number)}}
	testing.expect(t, !value_runs_check(overlap[:], 10))
	no_kind := [?]Value_Run_In_Call{{start = 1, length = 2, kind = u8(Value_Kind.None)}}
	testing.expect(t, !value_runs_check(no_kind[:], 10))
	kinds_refused := [?]u8{u8(max(Value_Kind)) + 1, max(u8)}
	for kind in kinds_refused {
		past_the_kinds := [?]Value_Run_In_Call{{start = 1, length = 2, kind = kind}}
		testing.expectf(t, !value_runs_check(past_the_kinds[:], 10), "the kind byte %d names no kind, and the runs are taken", kind)
	}
	testing.expect(t, value_runs_check(nil, 0))
	// A reader of a record checks a run before it indexes the text.
	_, _, _, ok := value_run_in_text({start = TEST_RECORD_TEXT - 2, length = 10, kind = u8(Value_Kind.Size)}, TEST_RECORD_TEXT)
	testing.expect(t, !ok)
}

// The kind of a run of a record is a byte that the kernel wrote: a reader
// takes it through value_run_in_text, which refuses None, a byte past the
// last kind and the largest byte, and gives no kind for them.
@(test)
value_run_in_text_refuses_a_byte_that_names_no_kind :: proc(t: ^testing.T) {
	refused := [?]u8{u8(Value_Kind.None), u8(max(Value_Kind)) + 1, max(u8)}
	for kind_byte in refused {
		start, end, kind, ok := value_run_in_text({start = 1, length = 2, kind = kind_byte}, TEST_RECORD_TEXT)
		testing.expectf(t, !ok, "the kind byte %d names no kind, and the run is taken", kind_byte)
		testing.expect_value(t, kind, Value_Kind.None)
		testing.expect_value(t, start, 0)
		testing.expect_value(t, end, 0)
	}
	start, end, kind, ok := value_run_in_text({start = 1, length = 2, kind = u8(Value_Kind.Time)}, TEST_RECORD_TEXT)
	testing.expect(t, ok)
	testing.expect_value(t, start, 1)
	testing.expect_value(t, end, 3)
	testing.expect_value(t, kind, Value_Kind.Time)
}

// A byte that names no kind is refused: one past the last kind, and the
// largest byte. Each kind comes back from its own byte.
@(test)
value_kind_of_refuses_a_byte_that_names_no_kind :: proc(t: ^testing.T) {
	refused_bytes := [?]u8{u8(max(Value_Kind)) + 1, 200, max(u8)}
	for value in refused_bytes {
		kind, ok := value_kind_of(value)
		testing.expectf(t, !ok, "the byte %d names no kind, and it is taken", value)
		testing.expect_value(t, kind, Value_Kind.None)
	}
	for member in Value_Kind {
		kind, ok := value_kind_of(u8(member))
		testing.expect(t, ok)
		testing.expect_value(t, kind, member)
	}
}

// Each kind has a name, and no two kinds have one name.
@(test)
each_kind_has_one_name :: proc(t: ^testing.T) {
	for kind in Value_Kind {
		if kind == .None {
			continue
		}
		testing.expectf(t, VALUE_KIND_NAMES[kind] != "", "the kind %v has no name", kind)
		for other in Value_Kind {
			testing.expectf(t, other == kind || VALUE_KIND_NAMES[other] != VALUE_KIND_NAMES[kind], "the kinds %v and %v have one name", kind, other)
		}
	}
}

// The detail of an Integer parameter gives back the unit that made it, for
// each unit of the contract, and a plain number is the detail 0.
@(test)
each_integer_unit_survives_its_detail :: proc(t: ^testing.T) {
	units := make([dynamic]Integer_Unit, context.temp_allocator)
	append(&units, Integer_Unit{})
	for unit in Size_Unit {
		append(&units, size_in(unit))
	}
	for unit in Duration_Unit {
		append(&units, time_in(unit))
	}
	for integer_unit in units {
		detail := integer_unit_detail(integer_unit)
		testing.expectf(t, detail & 0xFF == 0, "the detail of %v uses byte 0", integer_unit)
		back, ok := integer_unit_of_detail(detail)
		testing.expectf(t, ok && back == integer_unit, "the detail %x of %v gives %v", detail, integer_unit, back)
	}
	testing.expect_value(t, integer_unit_detail({}), 0)
}

// A detail that is not one of the contract is refused: the size of an
// Integer field in byte 0, a byte 3, a unit past its enumeration, a unit
// of no kind, a kind that has no unit, a kind past the enumeration.
@(test)
a_detail_out_of_the_contract_is_no_unit :: proc(t: ^testing.T) {
	refused := [?]u32 {
		2, // The size of a field of 2 bytes, which the console keeps in the same word.
		4,
		0x0100_0000,
		u32(Value_Kind.Size) << 8 | (u32(max(Size_Unit)) + 1) << 16,
		u32(Value_Kind.Time) << 8 | (u32(max(Duration_Unit)) + 1) << 16,
		1 << 16,
		u32(Value_Kind.Handle) << 8,
		(u32(max(Value_Kind)) + 1) << 8,
	}
	for detail in refused {
		_, ok := integer_unit_of_detail(detail)
		testing.expectf(t, !ok, "the detail %x is taken as a unit", detail)
	}
}

// The table of the types names each unit of the contract once, with
// different names: a unit with no type cannot be stated by an export.
@(test)
each_integer_unit_has_one_type :: proc(t: ^testing.T) {
	testing.expect_value(t, len(INTEGER_UNIT_TYPES), len(Size_Unit) + len(Duration_Unit))
	for item, index in INTEGER_UNIT_TYPES {
		testing.expectf(t, integer_unit_valid(item.integer_unit) && item.integer_unit.kind != .None, "the type %s has no unit", item.name)
		found, ok := integer_unit_of_type_name(item.name)
		testing.expectf(t, ok && found == item.integer_unit, "the name %s gives %v", item.name, found)
		for other in INTEGER_UNIT_TYPES[:index] {
			testing.expectf(t, other.name != item.name && other.integer_unit != item.integer_unit, "the types %s and %s collide", other.name, item.name)
		}
	}
	_, found := integer_unit_of_type_name("i64")
	testing.expect(t, !found)
	testing.expect_value(t, size_of(Size_In_Pages), size_of(i64))
}

// A byte of a field kind or of a contract enum that names no member is
// refused by its border: one past the last member, a byte in the middle
// of the rest, and the largest byte. Each member then reads back from its
// own byte.
@(test)
a_byte_that_names_no_field_kind_is_refused :: proc(t: ^testing.T) {
	refused_kinds := [?]u8{u8(max(Field_Kind)) + 1, 128, max(u8)}
	for word in refused_kinds {
		_, ok := field_kind_of_word(word)
		testing.expectf(t, !ok, "the byte %d names no field kind, and it is taken", word)
	}
	refused_enums := [?]u8{u8(max(Contract_Enum)) + 1, 128, max(u8)}
	for word in refused_enums {
		_, ok := contract_enum_of_word(word)
		testing.expectf(t, !ok, "the byte %d names no contract enum, and it is taken", word)
	}
	for kind in Field_Kind {
		read, ok := field_kind_of_word(u8(kind))
		testing.expect(t, ok)
		testing.expect_value(t, read, kind)
	}
	for which in Contract_Enum {
		read, ok := contract_enum_of_word(u8(which))
		testing.expect(t, ok)
		testing.expect_value(t, read, which)
	}
}

// Plain has no value kind of its own, and each other field kind has the
// value kind that its color shows. Hexadecimal and the values of a fact
// share Number: a reader that does not see colors tells them apart by the
// "0x" that only a hexadecimal Integer has.
@(test)
each_field_kind_has_its_value_kind :: proc(t: ^testing.T) {
	testing.expect_value(t, field_kind_value_kind(.Plain), Value_Kind.None)
	testing.expect_value(t, field_kind_value_kind(.Hexadecimal), Value_Kind.Number)
	testing.expect_value(t, field_kind_value_kind(.Status), Value_Kind.Status)
	testing.expect_value(t, field_kind_value_kind(.Module_Name), Value_Kind.Module)
	testing.expect_value(t, field_kind_value_kind(.Hash), Value_Kind.Version)
	testing.expect_value(t, field_kind_value_kind(.Fact_Values), Value_Kind.Number)
}

// The table of the types of a field kind gives each name once, with the
// size of its type, and names no type for Plain or for Status: a status
// takes the type of its enum. A name of another type is no kind.
@(test)
each_field_kind_type_has_its_size :: proc(t: ^testing.T) {
	Named_Size :: struct {
		name: string,
		size: u32,
	}
	sizes := [?]Named_Size {
		{"Hexadecimal_8", size_of(Hexadecimal_8)},
		{"Hexadecimal_16", size_of(Hexadecimal_16)},
		{"Hexadecimal_32", size_of(Hexadecimal_32)},
		{"Hexadecimal_64", size_of(Hexadecimal_64)},
		{"Module_Name_Field", size_of(Module_Name_Field)},
		{"Hash_Field", size_of(Hash_Field)},
		{"Fact_Values_Field", size_of(Fact_Values_Field)},
	}
	testing.expect_value(t, len(FIELD_KIND_TYPES), len(sizes))
	for item, index in FIELD_KIND_TYPES {
		size, named := u32(0), false
		for row in sizes {
			if row.name == item.name {
				size, named = row.size, true
			}
		}
		testing.expectf(t, named && size == item.size, "the type %s has %d bytes in the table", item.name, item.size)
		testing.expectf(t, item.kind != .Plain && item.kind != .Status, "the type %s has the kind %v", item.name, item.kind)
		found, ok := field_kind_of_type_name(item.name)
		testing.expectf(t, ok && found == item, "the name %s gives %v", item.name, found)
		for other in FIELD_KIND_TYPES[:index] {
			testing.expectf(t, other.name != item.name, "the type %s is in the table two times", item.name)
		}
	}
	refused_names := [?]string{"", "u32", "Hexadecimal", "Hexadecimal_128", "hash_field", "Status"}
	for name in refused_names {
		_, found := field_kind_of_type_name(name)
		testing.expectf(t, !found, "the name %q is taken as a type of a field kind", name)
	}
	// A hash field holds at most the hash of a module, so a reader writes
	// it in a fixed buffer of two digits for each byte.
	testing.expect_value(t, size_of(Hash_Field), HASH_FIELD_BYTES)
	testing.expect_value(t, size_of(Fact_Values_Field), FACT_VALUES_FIELD_BYTES)
}

// Each contract enum but None names a type of the contract, and no two
// name the same type.
@(test)
each_contract_enum_names_one_type :: proc(t: ^testing.T) {
	testing.expect_value(t, CONTRACT_ENUM_TYPES[.None], Contract_Enum_Type{})
	for which in Contract_Enum {
		if which == .None {
			continue
		}
		row := CONTRACT_ENUM_TYPES[which]
		testing.expectf(t, row.package_name != "" && row.name != "", "the enum %v names no type", which)
		for other in Contract_Enum {
			testing.expectf(t, other == which || CONTRACT_ENUM_TYPES[other] != row, "the enums %v and %v name one type", which, other)
		}
	}
}
