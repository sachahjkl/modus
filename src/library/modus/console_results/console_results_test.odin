#+build !freestanding
package console_results

import "modus:contract/errors"
import module "modus:contract/module"
import "modus:contract/module_file_writer"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:graphics"
import "core:strings"
import "core:testing"

// What the drawers of a test wrote: the text, with a line feed at each end
// of a line, and the parts of each kind.
Drawn :: struct {
	text:         [8192]u8,
	count:        int,
	parts:        [Part]int, // The bytes of each kind of part.
	continuation: [64]int, // The continuation of each line, when it ended.
	lines:        int,
	runs:         [256]Drawn_Run, // Each part that is not spaces, in order.
	run_count:    int,
}

// One part that a drawer wrote, with what it is.
Drawn_Run :: struct {
	start:  int, // In Drawn.text.
	length: int,
	part:   Part,
}

drawn_write :: proc "contextless" (sink: ^Sink, text: string, part: Part) {
	drawn := (^Drawn)(sink.data)
	start := drawn.count
	drawn.count += copy(drawn.text[drawn.count:], text)
	drawn.parts[part] += len(text)
	blank := true
	for character in transmute([]u8)text {
		blank = blank && character == ' '
	}
	if !blank && drawn.run_count < len(drawn.runs) {
		drawn.runs[drawn.run_count] = {start = start, length = drawn.count - start, part = part}
		drawn.run_count += 1
	}
}

// drawn_part_of gives the part of the first run whose text is exactly
// text, after the run number `after`, and the number of that run. found is
// false when no run has the text.
drawn_part_of :: proc(drawn: ^Drawn, text: string, after: int = -1) -> (part: Part, number: int, found: bool) {
	for run, index in drawn.runs[:drawn.run_count] {
		if index > after && string(drawn.text[run.start:][:run.length]) == text {
			return run.part, index, true
		}
	}
	return .Plain, -1, false
}

drawn_end_line :: proc "contextless" (sink: ^Sink) {
	drawn := (^Drawn)(sink.data)
	drawn.count += copy(drawn.text[drawn.count:], "\n")
	if drawn.lines < len(drawn.continuation) {
		drawn.continuation[drawn.lines] = sink.continuation
	}
	drawn.lines += 1
}

drawn_sink :: proc(drawn: ^Drawn) -> Sink {
	return {data = drawn, write = drawn_write, end_line = drawn_end_line}
}

drawn_text :: proc(drawn: ^Drawn) -> string {
	return string(drawn.text[:drawn.count])
}

// The record of the tests: a number, a name of 12 bytes, a count.
Test_Table :: struct {
	description: [1024]u8,
	file:        []u8,
	columns:     [3]Column,
	size:        int,
	rows:        [16 * 32]u8,
	row_count:   int,
}

test_table_make :: proc(t: ^testing.T, table: ^Test_Table) {
	table.columns = {integer_column("slot"), text_column("name", 12), integer_column("pages")}
	size: u32
	ok: bool
	table.file, size, ok = description_write(table.description[:], "Process", table.columns[:])
	testing.expect(t, ok, "the description is written")
	testing.expect_value(t, size, 32)
	table.size = int(size)
}

test_table_add :: proc(table: ^Test_Table, slot: i64, name: string, pages: i64) {
	row := table.rows[table.row_count * table.size:][:table.size]
	row_integer_set(row, table.columns[0], slot)
	row_text_set(row, table.columns[1], name)
	row_integer_set(row, table.columns[2], pages)
	table.row_count += 1
}

test_table_bytes :: proc(table: ^Test_Table) -> []u8 {
	return table.rows[:table.row_count * table.size]
}

// A description that the console writes is a description of the module
// contract: the readers of the contract read its record and its fields.
@(test)
description_is_read_by_the_contract :: proc(t: ^testing.T) {
	table := new(Test_Table, context.temp_allocator)
	test_table_make(t, table)
	described, ok := module.record_type(table.file, 1)
	testing.expect(t, ok, "the record is found")
	testing.expect_value(t, described.field_count, 3)
	testing.expect_value(t, module.string_at(table.file, described.name_offset, described.name_count), "Process")
	item, found := module.field(table.file, described, 1)
	testing.expect(t, found && item.type == u8(module.Type.Text) && item.detail == 12 && item.offset == 8)
	testing.expect_value(t, module.string_at(table.file, item.name_offset, item.name_count), "name")
	// No column, a record that is too large, and a buffer that is too small.
	_, _, ok = description_write(table.description[:], "Empty", nil)
	testing.expect(t, !ok)
	wide := [2]Column{text_column("a", 200), text_column("b", 200)}
	size: u32
	_, size, ok = description_write(table.description[:], "Wide", wide[:])
	testing.expect(t, !ok && size == 400)
	one := [1]Column{integer_column("a")}
	_, _, ok = description_write(table.description[:64], "Small", one[:])
	testing.expect(t, !ok)
}

// A text longer than its column ends with the cut mark: it is not cut in
// silence.
@(test)
long_text_has_the_cut_mark :: proc(t: ^testing.T) {
	table := new(Test_Table, context.temp_allocator)
	test_table_make(t, table)
	table.columns[1] = text_column("name", 24)
	table.file, _, _ = description_write(table.description[:], "Process", table.columns[:])
	row: [64]u8
	row_text_set(row[:], table.columns[1], "a name that is longer than twenty-four bytes")
	text := module.field_text(row[:], column_field(table.columns[1]))
	testing.expectf(t, strings.contains(text, "... and ") && strings.has_suffix(text, " bytes more"), "the text is %q", text)
}

// A value that names no member, and an enum that the file does not
// describe, are drawn as a number, never as another member; a member is
// drawn as a line names it.
@(test)
a_member_is_drawn_by_its_name_and_a_value_of_no_member_by_its_number :: proc(t: ^testing.T) {
	memory: [4096]u8
	members := [2]module_file_writer.Member_Description{{"united_states", 0}, {"french", 1}}
	enums := [1]module_file_writer.Enum_Description{{"Keyboard_Layout", 4, true, members[:]}}
	size, refusal := module_file_writer.write({enums = enums[:]}, memory[:])
	testing.expect_value(t, refusal.refusal, module_file_writer.Refusal.None)
	file := memory[:size]
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	for value in ([3]i64{2, -1, max(i64)}) {
		drawn^ = {}
		draw_member(&sink, file, 1, value)
		testing.expectf(t, drawn.parts[Part.Status] == 0 && drawn.parts[Part.Number] > 0, "the value %d is drawn as a member", value)
	}
	drawn^ = {}
	draw_member(&sink, file, 2, 1)
	testing.expect_value(t, drawn_text(drawn), "1\n")
	drawn^ = {}
	draw_member(&sink, file, 1, 1)
	testing.expect_value(t, drawn_text(drawn), ".french\n")
	testing.expect_value(t, drawn.parts[Part.Status], 7)
}

@(test)
integer_and_text :: proc(t: ^testing.T) {
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	draw_integer(&sink, -42)
	testing.expect_value(t, drawn_text(drawn), "-42\n")
	testing.expect_value(t, drawn.parts[Part.Number], 3)
	drawn^ = {}
	draw_text(&sink, "one\ntwo\n")
	testing.expect_value(t, drawn_text(drawn), "one\ntwo\n")
	drawn^ = {}
	draw_text(&sink, "")
	testing.expect_value(t, drawn_text(drawn), "\n")
	drawn^ = {}
	draw_text(&sink, "a\n\nb")
	testing.expect_value(t, drawn_text(drawn), "a\n\nb\n")
}

// Each column has the least width of its head and its values; a number is
// at the right of its column, a text at the left; the last column has no
// spaces after it.
@(test)
table_columns :: proc(t: ^testing.T) {
	table := new(Test_Table, context.temp_allocator)
	test_table_make(t, table)
	test_table_add(table, 3, "console", 120)
	test_table_add(table, 12, "log", 7)
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	draw_table(&sink, table.file, 1, test_table_bytes(table), 20)
	expected := "slot  name     pages\n" + "   3  console    120\n" + "  12  log          7\n" + "2 rows of Process\n"
	testing.expect_value(t, drawn_text(drawn), expected)
	// A row that is too long goes on under the last column.
	testing.expect_value(t, drawn.continuation[1], 15)
	testing.expect(t, drawn.parts[Part.Label] == len("slot") + len("name") + len("pages"))
}

// A table with more rows than the limit: the first rows, then how many are
// not shown. The widths are those of the rows that are shown.
@(test)
table_cut_at_the_row_limit :: proc(t: ^testing.T) {
	table := new(Test_Table, context.temp_allocator)
	test_table_make(t, table)
	for index in 0 ..< 5 {
		test_table_add(table, i64(index + 1), index == 4 ? "a_long_name" : "x", 1)
	}
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	draw_table(&sink, table.file, 1, test_table_bytes(table), 2, ": skip(table, 2) gives them")
	expected := "slot  name  pages\n" + "   1  x         1\n" + "   2  x         1\n" + "3 rows more are not shown: skip(table, 2) gives them\n" + "5 rows of Process\n"
	testing.expect_value(t, drawn_text(drawn), expected)
	// One row, and no row.
	drawn^ = {}
	draw_table(&sink, table.file, 1, test_table_bytes(table)[:table.size], 20)
	testing.expect(t, strings.has_suffix(drawn_text(drawn), "1 row of Process\n"))
	drawn^ = {}
	draw_table(&sink, table.file, 1, nil, 20)
	testing.expect_value(t, drawn_text(drawn), "slot  name  pages\n0 rows of Process\n")
	// A description that is not one.
	drawn^ = {}
	draw_table(&sink, table.file, 9, test_table_bytes(table), 20)
	testing.expect_value(t, drawn_text(drawn), "a table with no valid description\n")
}

// A table that holds only its first rows, as a result that crossed a bound
// of rows: the count of all rows comes from total_rows. A total under the
// rows of the bytes, 0 and a negative total count the rows of the bytes.
@(test)
table_with_a_total_past_its_rows :: proc(t: ^testing.T) {
	table := new(Test_Table, context.temp_allocator)
	test_table_make(t, table)
	test_table_add(table, 1, "x", 1)
	test_table_add(table, 2, "y", 1)
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	draw_table(&sink, table.file, 1, test_table_bytes(table), 20, "", 18)
	expected := "slot  name  pages\n" + "   1  x         1\n" + "   2  y         1\n" + "16 rows more are not shown\n" + "18 rows of Process\n"
	testing.expect_value(t, drawn_text(drawn), expected)
	for total in ([?]int{0, 1, -5}) {
		drawn^ = {}
		draw_table(&sink, table.file, 1, test_table_bytes(table), 20, "", total)
		testing.expectf(t, strings.has_suffix(drawn_text(drawn), "   2  y         1\n2 rows of Process\n"), "total %d: %q", total, drawn_text(drawn))
	}
}

@(test)
record_fields :: proc(t: ^testing.T) {
	table := new(Test_Table, context.temp_allocator)
	test_table_make(t, table)
	test_table_add(table, 3, "console", 120)
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	draw_record(&sink, table.file, 1, test_table_bytes(table))
	expected := "Process\n" + "  slot   3\n" + "  name   console\n" + "  pages  120\n"
	testing.expect_value(t, drawn_text(drawn), expected)
	testing.expect_value(t, drawn.parts[Part.Type], len("Process"))
	testing.expect_value(t, drawn.continuation[1], 9)
	// Bytes that are fewer than the record.
	drawn^ = {}
	draw_record(&sink, table.file, 1, test_table_bytes(table)[:8])
	testing.expect_value(t, drawn_text(drawn), "a record with no valid description\n")
}

// The record of the tests of the value kinds: a text, a plain number, a
// size in pages and a time in milliseconds.
Usage_Table :: struct {
	description: [1024]u8,
	file:        []u8,
	columns:     [4]Column,
	size:        int,
	rows:        [4 * 40]u8,
	row_count:   int,
}

usage_table_make :: proc(t: ^testing.T, table: ^Usage_Table) {
	table.columns = {text_column("name", 12), integer_column("count"), size_column("used", .Pages), time_column("wait", .Milliseconds)}
	size: u32
	ok: bool
	table.file, size, ok = description_write(table.description[:], "Usage", table.columns[:])
	testing.expect(t, ok, "the description is written")
	testing.expect_value(t, size, 40)
	table.size = int(size)
}

usage_table_add :: proc(table: ^Usage_Table, name: string, count, used, wait: i64) {
	row := table.rows[table.row_count * table.size:][:table.size]
	row_text_set(row, table.columns[0], name)
	row_integer_set(row, table.columns[1], count)
	row_integer_set(row, table.columns[2], used)
	row_integer_set(row, table.columns[3], wait)
	table.row_count += 1
}

// The integer unit of a column is in the description that the console
// writes, and the reader of the contract gives it back. A unit out of the
// contract, and a unit on a Text, make a description that the contract
// refuses, and the drawer then draws no field of it.
@(test)
a_field_states_its_integer_unit :: proc(t: ^testing.T) {
	table := new(Usage_Table, context.temp_allocator)
	usage_table_make(t, table)
	described, ok := module.record_type(table.file, 1)
	testing.expect(t, ok, "the record is found")
	expected := [4]value_kinds.Integer_Unit{{}, {}, value_kinds.size_in(.Pages), value_kinds.time_in(.Milliseconds)}
	for unit, number in expected {
		item, found := module.field(table.file, described, u32(number))
		testing.expect(t, found)
		testing.expect_value(t, item.integer_unit, unit)
		testing.expect(t, module.field_integer_unit_valid(item))
	}
	refused := [?]Column {
		{name = "used", type = .Integer, detail = 8, integer_unit = {kind = .Size, unit = u8(max(value_kinds.Size_Unit)) + 1}},
		{name = "used", type = .Integer, detail = 8, integer_unit = {kind = .Module, unit = 0}},
		{name = "name", type = .Text, detail = 8, integer_unit = value_kinds.size_in(.Bytes)},
	}
	for column in refused {
		one := [1]Column{column}
		buffer: [1024]u8
		file, _, written := description_write(buffer[:], "Refused", one[:])
		testing.expect(t, written)
		_, valid := module.record_type(file, 1)
		testing.expectf(t, !valid, "the unit %v on a field %v is refused", column.integer_unit, column.type)
		drawn := new(Drawn, context.temp_allocator)
		sink := drawn_sink(drawn)
		draw_table(&sink, file, 1, nil, 20)
		testing.expect_value(t, drawn_text(drawn), "a table with no valid description\n")
	}
}

// Each cell of a table has the part of the value kind of its field, so the
// console gives it the color of that kind from the one table of colors: a
// text is plain, a number and a size have the color of memory, a time the
// color of the boot program. The unit of a size or a time is in the head
// of its column, one time: the cells hold the number only.
@(test)
table_cells_have_the_color_of_their_value_kind :: proc(t: ^testing.T) {
	table := new(Usage_Table, context.temp_allocator)
	usage_table_make(t, table)
	usage_table_add(table, "console", 3, 120, 45)
	usage_table_add(table, "log", 12, 7, 1500)
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	draw_table(&sink, table.file, 1, table.rows[:table.row_count * table.size], 20)
	expected := "name     count  used (pages)  wait (ms)\n" + "console      3           120         45\n" + "log         12             7       1500\n" + "2 rows of Usage\n"
	testing.expect_value(t, drawn_text(drawn), expected)
	Cell_Kind :: struct {
		text: string,
		kind: value_kinds.Value_Kind,
	}
	// In the order of the rows; each text is found after the one before it.
	cells := [?]Cell_Kind {
		{"console", .None},
		{"3", .Number},
		{"120", .Size},
		{"45", .Time},
		{"log", .None},
		{"12", .Number},
		{"7", .Size},
		{"1500", .Time},
	}
	after := -1
	for cell in cells {
		part, number, found := drawn_part_of(drawn, cell.text, after)
		if !testing.expectf(t, found, "the cell %s is drawn", cell.text) {
			continue
		}
		after = number
		kind := part_value_kind(part)
		testing.expectf(t, kind == cell.kind, "the cell %s has the kind %v, not %v", cell.text, kind, cell.kind)
		testing.expectf(t, graphics.value_kind_color(kind, graphics.appearance) == graphics.value_kind_color(cell.kind, graphics.appearance), "the cell %s has the color of %v", cell.text, cell.kind)
	}
	// A time is not in the color of a number: a reader tells them apart by
	// the color and by the unit of the head.
	testing.expect(t, graphics.value_kind_color(.Time, graphics.appearance) != graphics.value_kind_color(.Number, graphics.appearance))
	// The heads and their units are dim labels, and the unit is never in a
	// cell.
	testing.expect_value(t, drawn.parts[Part.Label], len("name") + len("count") + len("used (pages)") + len("wait (ms)"))
	testing.expect_value(t, drawn.parts[Part.Size], len("120") + len("7"))
	testing.expect_value(t, drawn.parts[Part.Time], len("45") + len("1500"))
}

// The record of the tests of the field kinds: a status of a log level, a
// hexadecimal Integer of 4 bytes, a module name, and a hash of 4 bytes.
Kinds_Table :: struct {
	description: [1024]u8,
	file:        []u8,
	columns:     [4]Column,
	size:        int,
	rows:        [4 * 44]u8,
	row_count:   int,
}

kinds_table_make :: proc(t: ^testing.T, table: ^Kinds_Table) {
	table.columns = {
		{name = "level", type = .Integer, detail = 1, unsigned = true, kind = .Status, contract_enum = .Log_Level},
		{name = "check", type = .Integer, detail = 4, unsigned = true, kind = .Hexadecimal},
		{name = "writer", type = .Text, detail = value_kinds.MODULE_NAME_FIELD_BYTES, kind = .Module_Name},
		{name = "module", type = .Bytes, detail = 4, kind = .Hash},
	}
	size: u32
	ok: bool
	table.file, size, ok = description_write(table.description[:], "Fact_Sample", table.columns[:])
	testing.expect(t, ok, "the description is written")
	testing.expect_value(t, size, 44)
	table.size = int(size)
}

kinds_table_add :: proc(table: ^Kinds_Table, level: i64, check: i64, writer: string, hash: [4]u8) {
	row := table.rows[table.row_count * table.size:][:table.size]
	row_integer_set(row, table.columns[0], level)
	row_integer_set(row, table.columns[1], check)
	row_text_set(row, table.columns[2], writer)
	hash_bytes := hash
	copy(row[table.columns[3].offset:][:4], hash_bytes[:])
	table.row_count += 1
}

// Each field kind survives the description that the console writes, and
// the contract reads it back: the kind and the enum of each field, and
// the column that columns and join make from that field.
@(test)
a_field_states_its_kind :: proc(t: ^testing.T) {
	table := new(Kinds_Table, context.temp_allocator)
	kinds_table_make(t, table)
	described, ok := module.record_type(table.file, 1)
	if !testing.expect(t, ok, "the record is found") {
		return
	}
	for column, number in table.columns {
		item, found := module.field(table.file, described, u32(number))
		testing.expect(t, found)
		testing.expect_value(t, item.kind, u8(column.kind))
		testing.expect_value(t, item.contract_enum, u8(column.contract_enum))
		back, back_ok := column_of_field(column.name, item)
		testing.expect(t, back_ok)
		testing.expect_value(t, back.kind, column.kind)
		testing.expect_value(t, back.contract_enum, column.contract_enum)
		testing.expect_value(t, back.type, column.type)
	}
	// A field whose kind byte names no kind gives no column.
	broken, _ := module.field(table.file, described, 0)
	broken.kind = u8(max(value_kinds.Field_Kind)) + 1
	_, broken_ok := column_of_field("level", broken)
	testing.expect(t, !broken_ok)
	// A kind on a field that it does not fit makes a description that the
	// contract refuses, and the drawer then draws no field of it.
	refused := [?]Column {
		{name = "check", type = .Integer, detail = 4, kind = .Hash},
		{name = "level", type = .Integer, detail = 1, unsigned = true, kind = .Status},
		{name = "level", type = .Integer, detail = 1, kind = .Status, contract_enum = .Log_Level},
		{name = "writer", type = .Text, detail = 8, kind = .Hexadecimal},
		{name = "module", type = .Bytes, detail = 4},
		{name = "module", type = .Bytes, detail = value_kinds.HASH_FIELD_BYTES + 1, kind = .Hash},
	}
	for column in refused {
		one := [1]Column{column}
		buffer: [1024]u8
		file, _, written := description_write(buffer[:], "Refused", one[:])
		testing.expect(t, written)
		_, valid := module.record_type(file, 1)
		testing.expectf(t, !valid, "the kind %v on a field %v is refused", column.kind, column.type)
		drawn := new(Drawn, context.temp_allocator)
		sink := drawn_sink(drawn)
		draw_table(&sink, file, 1, nil, 20)
		testing.expect_value(t, drawn_text(drawn), "a table with no valid description\n")
	}
}

// Each cell has the part of its field kind: a status its name, in the
// part Status, and a word that names no member its number as a Number,
// never a name; a hexadecimal Integer "0x" and two digits for each byte,
// at the right; a module name the part Module; a hash its bytes in
// hexadecimal, its zero bytes too, the part Version. A status, a module
// name and a hash are at the left of their column, with their head.
@(test)
table_cells_have_the_part_of_their_field_kind :: proc(t: ^testing.T) {
	table := new(Kinds_Table, context.temp_allocator)
	kinds_table_make(t, table)
	kinds_table_add(table, i64(op.Log_Level.Warning), 0x1a2b, "storage", {0x0a, 0x00, 0xff, 0x01})
	// One past the last level: a word that names no member.
	kinds_table_add(table, i64(max(op.Log_Level)) + 1, 0xffff_ffff, "log", {})
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	draw_table(&sink, table.file, 1, table.rows[:table.row_count * table.size], 20)
	expected := "level         check  writer   module\n" + "Warning  0x00001a2b  storage  0a00ff01\n" + "4        0xffffffff  log      00000000\n" + "2 rows of Fact_Sample\n"
	testing.expect_value(t, drawn_text(drawn), expected)
	Cell_Part :: struct {
		text: string,
		part: Part,
		kind: value_kinds.Value_Kind,
	}
	// In the order of the rows; each text is found after the one before it.
	cells := [?]Cell_Part {
		{"Warning", .Status, .Status},
		{"0x00001a2b", .Number, .Number},
		{"storage", .Module, .Module},
		{"0a00ff01", .Version, .Version},
		{"4", .Number, .Number},
		{"0xffffffff", .Number, .Number},
		{"log", .Module, .Module},
		{"00000000", .Version, .Version},
	}
	after := -1
	for cell in cells {
		part, number, found := drawn_part_of(drawn, cell.text, after)
		if !testing.expectf(t, found, "the cell %s is drawn", cell.text) {
			continue
		}
		after = number
		testing.expectf(t, part == cell.part, "the cell %s has the part %v, not %v", cell.text, part, cell.part)
		testing.expect_value(t, part_value_kind(part), cell.kind)
	}
	// No head has a unit: the kinds have none.
	testing.expect_value(t, drawn.parts[Part.Label], len("level") + len("check") + len("writer") + len("module"))
}

// A cell of the values of a log fact is its raw form: two digits for each
// byte up to the last byte that is not zero, the part Number, at the left.
// Values of zeros only are an empty cell; values with no zero byte are the
// whole 288 digits, never cut. A field of fact values of another size is
// refused, as the contract refuses it.
@(test)
a_cell_of_fact_values_is_its_raw_form :: proc(t: ^testing.T) {
	columns := [2]Column{{name = "number", type = .Integer, detail = 8}, {name = "values", type = .Bytes, detail = value_kinds.FACT_VALUES_FIELD_BYTES, kind = .Fact_Values}}
	buffer: [1024]u8
	file, size, written := description_write(buffer[:], "Fact_Row", columns[:])
	if !testing.expect(t, written, "the description is written") {
		return
	}
	described, valid := module.record_type(file, 1)
	if !testing.expect(t, valid, "the contract takes a field of fact values") {
		return
	}
	item, _ := module.field(file, described, 1)
	rows: [3 * 152]u8
	row_size := int(size)
	testing.expect_value(t, row_size, 152)
	// Row 1: 0c 00 23 then zeros; row 2: zeros only; row 3: no zero byte.
	rows[columns[1].offset] = 0x0c
	rows[columns[1].offset + 2] = 0x23
	for index in 0 ..< value_kinds.FACT_VALUES_FIELD_BYTES {
		rows[2 * row_size + int(columns[1].offset) + index] = 0xab
	}
	cell_buffer: [CELL_TEXT_CAPACITY]u8
	first := cell_of(rows[:row_size], item, cell_buffer[:])
	testing.expect(t, first.text == "0c0023" && first.part == .Number && !first.number)
	second := cell_of(rows[row_size:][:row_size], item, cell_buffer[:])
	testing.expect(t, second.text == "" && second.part == .Number)
	third := cell_of(rows[2 * row_size:][:row_size], item, cell_buffer[:])
	testing.expect_value(t, len(third.text), 2 * value_kinds.FACT_VALUES_FIELD_BYTES)
	refused := [?]Column {
		{name = "values", type = .Bytes, detail = value_kinds.FACT_VALUES_FIELD_BYTES - 1, kind = .Fact_Values},
		{name = "values", type = .Bytes, detail = 1, kind = .Fact_Values},
		{name = "values", type = .Integer, detail = 8, kind = .Fact_Values},
	}
	for column in refused {
		one := [1]Column{column}
		refused_buffer: [1024]u8
		refused_file, _, refused_written := description_write(refused_buffer[:], "Refused", one[:])
		testing.expect(t, refused_written)
		_, refused_valid := module.record_type(refused_file, 1)
		testing.expectf(t, !refused_valid, "fact values of %d bytes of the type %v are taken", column.detail, column.type)
	}
}

// A record writes each field by its kind, in the part of the kind.
@(test)
record_fields_are_written_by_their_kind :: proc(t: ^testing.T) {
	table := new(Kinds_Table, context.temp_allocator)
	kinds_table_make(t, table)
	kinds_table_add(table, i64(op.Log_Level.Warning), 0x1a2b, "storage", {0x0a, 0x00, 0xff, 0x01})
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	draw_record(&sink, table.file, 1, table.rows[:table.size])
	expected := "Fact_Sample\n" + "  level   Warning\n" + "  check   0x00001a2b\n" + "  writer  storage\n" + "  module  0a00ff01\n"
	testing.expect_value(t, drawn_text(drawn), expected)
	testing.expect_value(t, drawn.parts[Part.Status], len("Warning"))
	testing.expect_value(t, drawn.parts[Part.Module], len("storage"))
	testing.expect_value(t, drawn.parts[Part.Version], len("0a00ff01"))
}

// A hash that the buffer cannot hold whole gives no text: a hash is never
// cut. The edges: a buffer of one byte less, and of the exact size.
@(test)
a_hash_is_whole_or_nothing :: proc(t: ^testing.T) {
	bytes := [3]u8{0x00, 0x10, 0xff}
	short: [5]u8
	testing.expect_value(t, hash_text(short[:], bytes[:]), "")
	exact: [6]u8
	testing.expect_value(t, hash_text(exact[:], bytes[:]), "0010ff")
	none: [0]u8
	testing.expect_value(t, hash_text(none[:], nil), "")
}

// A record writes the unit after the value of a size or a time, in the
// part of the value, as a value run of the log covers the number and its
// unit.
@(test)
record_fields_have_their_unit_after_the_value :: proc(t: ^testing.T) {
	table := new(Usage_Table, context.temp_allocator)
	usage_table_make(t, table)
	usage_table_add(table, "console", 3, 120, 45)
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	draw_record(&sink, table.file, 1, table.rows[:table.size])
	expected := "Usage\n" + "  name   console\n" + "  count  3\n" + "  used   120 pages\n" + "  wait   45 ms\n"
	testing.expect_value(t, drawn_text(drawn), expected)
	unit, _, found := drawn_part_of(drawn, " pages")
	testing.expect(t, found && unit == .Size, "the unit of a size has the part of a size")
	unit, _, found = drawn_part_of(drawn, " ms")
	testing.expect(t, found && unit == .Time, "the unit of a time has the part of a time")
	testing.expect_value(t, drawn.parts[Part.Number], len("3"))
}

@(test)
handle_kind_and_rights :: proc(t: ^testing.T) {
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	draw_handle(&sink, 65541, .Memory, {.Give, .Read, .Write})
	testing.expect_value(t, drawn_text(drawn), "Handle 65541: Memory (Give, Read, Write)\n")
	drawn^ = {}
	draw_handle(&sink, 7, .None, {})
	testing.expect_value(t, drawn_text(drawn), "Handle 7: no object\n")
}

@(test)
bytes_view :: proc(t: ^testing.T) {
	bytes: [20]u8
	for &value, index in bytes {
		value = u8('A' + index)
	}
	bytes[1] = 0
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	draw_bytes(&sink, bytes[:], 256)
	expected := "00000000  41 00 43 44 45 46 47 48 49 4a 4b 4c 4d 4e 4f 50  A.CDEFGHIJKLMNOP\n" + "00000010  51 52 53 54                                      QRST\n" + "20 bytes\n"
	testing.expect_value(t, drawn_text(drawn), expected)
	// The bound: whole bytes only, then how many are not shown.
	drawn^ = {}
	draw_bytes(&sink, bytes[:], 2, 0x1000)
	testing.expect_value(t, drawn_text(drawn), "00001000  41 00                                            A.\n18 bytes more are not shown\n20 bytes\n")
	drawn^ = {}
	draw_bytes(&sink, nil, 256)
	testing.expect_value(t, drawn_text(drawn), "0 bytes\n")
}

// The digits of an Integer of each size, at its edges: the largest value
// and, with a sign, the least one.
@(test)
the_digits_of_an_integer_hold_its_largest_text :: proc(t: ^testing.T) {
	testing.expect_value(t, integer_digits(1, true), len("255"))
	testing.expect_value(t, integer_digits(1, false), len("-128"))
	testing.expect_value(t, integer_digits(2, true), len("65535"))
	testing.expect_value(t, integer_digits(2, false), len("-32768"))
	testing.expect_value(t, integer_digits(4, true), len("4294967295"))
	testing.expect_value(t, integer_digits(4, false), len("-2147483648"))
	testing.expect_value(t, integer_digits(8, true), len("18446744073709551615"))
	testing.expect_value(t, integer_digits(8, false), len("-9223372036854775808"))
}

// A Stream has no columns for a description that the contract does not
// read, and a row of another size draws nothing. Then the head and the
// rows: each line has the same width, the row of the least Integer too, so
// a row never moves the rows above it.
@(test)
a_stream_draws_each_row_in_the_widths_of_its_description :: proc(t: ^testing.T) {
	table := new(Test_Table, context.temp_allocator)
	test_table_make(t, table)
	_, ok := stream_columns_of(nil, 1)
	testing.expect(t, !ok, "a stream of no file has columns")
	_, ok = stream_columns_of(table.file, 0)
	testing.expect(t, !ok, "a stream of the record 0 has columns")
	_, ok = stream_columns_of(table.file, 2)
	testing.expect(t, !ok, "a stream of a record past the table has columns")

	columns: Stream_Columns
	columns, ok = stream_columns_of(table.file, 1)
	testing.expect(t, ok && columns.count == 3 && columns.size == table.size)
	testing.expect_value(t, columns.widths[0], 20)
	testing.expect_value(t, columns.widths[1], 12)
	testing.expect_value(t, columns.widths[2], 20)

	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	short: [8]u8
	draw_stream_row(&sink, &columns, short[:])
	testing.expect_value(t, drawn.lines, 0)

	draw_stream_head(&sink, &columns, table.file)
	test_table_add(table, 3, "alpha", 7)
	test_table_add(table, min(i64), "twelve", max(i64))
	rows := test_table_bytes(table)
	draw_stream_row(&sink, &columns, rows[:table.size])
	draw_stream_row(&sink, &columns, rows[table.size:])
	draw_note(&sink, "joined after 5 records")
	testing.expect_value(t, drawn.lines, 4)
	text := drawn_text(drawn)
	lines := strings.split_lines(text, context.temp_allocator)
	width := 20 + COLUMN_GAP + 12 + COLUMN_GAP + 20
	for line in lines[:3] {
		testing.expectf(t, len(line) == width, "the line %q has %d bytes, not %d", line, len(line), width)
	}
	testing.expect(t, strings.has_suffix(lines[0], "pages") && strings.contains(lines[0], "slot  name"), lines[0])
	testing.expect(t, strings.has_prefix(lines[2], "-9223372036854775808  twelve "), lines[2])
	testing.expect_value(t, lines[3], "joined after 5 records")
	testing.expect_value(t, drawn.parts[Part.Note], len("joined after 5 records"))
}

// An error of the console itself is its sentence. An error record adds its
// values; its details follow when there is more than one.
@(test)
failure_lines :: proc(t: ^testing.T) {
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	draw_failure(&sink, {sentence = "no variable has the name x"})
	testing.expect_value(t, drawn_text(drawn), "error: no variable has the name x\n")

	drawn^ = {}
	record := errors.error_make(.Too_Long, .Bytes, 2, 40, 36)
	names := [2]string{"amount", "note"}
	draw_failure(&sink, {sentence = "add: the argument note has 40 bytes; it can have at most 36 bytes (-1)", record = &record, operation = "add", argument_names = names[:]})
	expected := "error: add: the argument note has 40 bytes; it can have at most 36 bytes (-1)\n" + "  kind       Too_Long\n" + "  operation  add\n" + "  argument   2 note\n" + "  values     value 40, limit 36, found 0, unit bytes\n"
	testing.expect_value(t, drawn_text(drawn), expected)
	testing.expect_value(t, drawn.parts[Part.Status], len("Too_Long"))

	// A kind that the contract does not have, from another process.
	drawn^ = {}
	record = {kind = 9999}
	draw_failure(&sink, {sentence = "x", record = &record})
	testing.expect(t, strings.contains(drawn_text(drawn), "  kind       an unknown kind, 9999\n"), drawn_text(drawn))

	// Three details, two in the table of the caller.
	drawn^ = {}
	record = errors.error_make(.Absent, .None, 1, 0, 0, 1)
	details := [2]errors.Error_Record{record, errors.error_make(.Absent, .None, 1, 0, 0, 3)}
	one_name := [1]string{"names"}
	draw_failure(&sink, {sentence = "s", record = &record, operation = "monitor.counts_named", argument_names = one_name[:], details = details[:], detail_count = 3})
	text := drawn_text(drawn)
	testing.expect(t, strings.contains(text, "error: detail 1 of 3: monitor.counts_named: "), text)
	testing.expect(t, strings.contains(text, "error: detail 2 of 3: monitor.counts_named: "), text)
	testing.expect(t, strings.contains(text, "error: 1 more error detail did not fit in the table of error details\n"), text)
}
// The break of a text in a column: the edges of the width first, then a
// word longer than the column, then the break between words.
@(test)
a_text_breaks_between_words_and_cuts_only_a_word_longer_than_its_column :: proc(t: ^testing.T) {
	line, rest := wrap_segment("", 8)
	testing.expect(t, line == "" && rest == "", "an empty text gives a part")
	line, rest = wrap_segment("abc def", 0)
	testing.expect(t, line == "abc def" && rest == "", "a column of no width cuts a text")
	line, rest = wrap_segment("abc def", -1)
	testing.expect(t, line == "abc def" && rest == "", "a column of a negative width cuts a text")
	// Exact fit, and one past it.
	line, rest = wrap_segment("abcd efgh", 9)
	testing.expect(t, line == "abcd efgh" && rest == "", "a text that fits is broken")
	line, rest = wrap_segment("abcd efghi", 9)
	testing.expect_value(t, line, "abcd")
	testing.expect_value(t, rest, "efghi")
	// The space just past the column is a break: the line fills the column.
	line, rest = wrap_segment("abcd efgh ij", 9)
	testing.expect_value(t, line, "abcd efgh")
	testing.expect_value(t, rest, "ij")
	// A word longer than the column alone is cut at the column.
	line, rest = wrap_segment("abcdefghijkl mn", 5)
	testing.expect_value(t, line, "abcde")
	testing.expect_value(t, rest, "fghijkl mn")
	// A width of one character.
	line, rest = wrap_segment("ab", 1)
	testing.expect(t, line == "a" && rest == "b")
	// The spaces at a break go, at the end of the line and at the start of
	// the rest.
	line, rest = wrap_segment("ab   cd", 4)
	testing.expect_value(t, line, "ab")
	testing.expect_value(t, rest, "cd")
	// A line feed ends the line, even when the text fits.
	line, rest = wrap_segment("ab\ncd", 10)
	testing.expect(t, line == "ab" && rest == "cd")
	// The width is in columns, not bytes: "é" is two bytes and one column,
	// so "aé" fits two columns whole, and "éa" in one column cuts after é.
	line, rest = wrap_segment("aé", 2)
	testing.expect(t, line == "aé" && rest == "")
	line, rest = wrap_segment("éa", 1)
	testing.expect_value(t, line, "é")
	testing.expect_value(t, rest, "a")
	// A wide character takes two columns: "日本" in three columns cuts after
	// 日, and a wide character in a column of one goes whole.
	line, rest = wrap_segment("日本", 3)
	testing.expect(t, line == "日" && rest == "本")
	line, rest = wrap_segment("日a", 1)
	testing.expect(t, line == "日" && rest == "a")
	// Spaces at the start: they stay before a word that fits after them,
	// and go when they alone would fill the line.
	line, rest = wrap_segment("  ab cd", 4)
	testing.expect(t, line == "  ab" && rest == "cd")
	line, rest = wrap_segment("     abcdef", 3)
	testing.expect(t, line == "abc" && rest == "def")
	// Spaces only, and a line feed only: one empty line, and no rest.
	line, rest = wrap_segment("       ", 3)
	testing.expect(t, line == "" && rest == "")
	line, rest = wrap_segment("\n", 3)
	testing.expect(t, line == "" && rest == "")
}

// The record of the tests of the break: a name, a long text, a count.
Note_Table :: struct {
	description: [1024]u8,
	file:        []u8,
	columns:     [3]Column,
	size:        int,
	rows:        [4 * 128]u8,
	row_count:   int,
}

note_table_make :: proc(t: ^testing.T, table: ^Note_Table) {
	table.columns = {text_column("name", 16), text_column("note", 80), integer_column("count")}
	size: u32
	ok: bool
	table.file, size, ok = description_write(table.description[:], "Command", table.columns[:])
	testing.expect(t, ok, "the description is written")
	table.size = int(size)
}

note_table_add :: proc(table: ^Note_Table, name: string, note: string, count: i64) {
	row := table.rows[table.row_count * table.size:][:table.size]
	row_text_set(row, table.columns[0], name)
	row_text_set(row, table.columns[1], note)
	row_integer_set(row, table.columns[2], count)
	table.row_count += 1
}

// A table wider than the window of its sink: the column of text narrows,
// each of its texts goes on in its own column, between two words, and no
// line is wider than the window. A window of no bound and a window that
// no column of text can fit keep the old lines.
@(test)
a_table_wider_than_its_window_breaks_its_texts_in_their_own_column :: proc(t: ^testing.T) {
	table := new(Note_Table, context.temp_allocator)
	note_table_make(t, table)
	note_table_add(table, "isolate_memory", "isolate the module file of a memory object", 3)
	note_table_add(table, "help", "", 1)
	note_table_add(table, "start", "start a process, by module name, with a wiring list or none", 17)
	bytes := table.rows[:table.row_count * table.size]
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	sink.width = 40
	draw_table(&sink, table.file, 1, bytes, 20)
	expected :=
		"name            note               count\n" +
		"isolate_memory  isolate the            3\n" +
		"                module file of a\n" +
		"                memory object\n" +
		"help                                   1\n" +
		"start           start a process,      17\n" +
		"                by module name,\n" +
		"                with a wiring\n" +
		"                list or none\n" +
		"3 rows of Command\n"
	testing.expect_value(t, drawn_text(drawn), expected)
	for line in strings.split_lines(drawn_text(drawn), context.temp_allocator) {
		testing.expectf(t, len(line) <= 40, "the line %q is wider than the window", line)
		testing.expectf(t, !strings.has_suffix(line, " "), "the line %q ends with a space", line)
	}

	// Exact fit: a window as wide as the line breaks nothing; one column
	// less breaks the note.
	// The column of the names is as wide as "isolate_memory".
	full := 14 + COLUMN_GAP + len("start a process, by module name, with a wiring list or none") + COLUMN_GAP + 5
	drawn^ = {}
	sink.width = full
	draw_table(&sink, table.file, 1, bytes, 20)
	testing.expect_value(t, drawn.lines, 1 + 3 + 1)
	drawn^ = {}
	sink.width = full - 1
	draw_table(&sink, table.file, 1, bytes, 20)
	testing.expect_value(t, drawn.lines, 1 + 4 + 1)

	// No bound: one line for each row, as before.
	drawn^ = {}
	sink.width = 0
	draw_table(&sink, table.file, 1, bytes, 20)
	testing.expect_value(t, drawn.lines, 1 + 3 + 1)

	// A window too narrow for the least columns: the lines stay whole, and
	// the continuation of the caller takes their rest. The names are a
	// column of text too, and narrow to the least width as the notes do.
	drawn^ = {}
	sink.width = WRAP_COLUMN_LEAST + COLUMN_GAP + WRAP_COLUMN_LEAST + COLUMN_GAP + 5 - 1
	draw_table(&sink, table.file, 1, bytes, 20)
	testing.expect_value(t, drawn.lines, 1 + 3 + 1)
	// The least columns fit exactly.
	drawn^ = {}
	sink.width = WRAP_COLUMN_LEAST + COLUMN_GAP + WRAP_COLUMN_LEAST + COLUMN_GAP + 5
	draw_table(&sink, table.file, 1, bytes, 20)
	for line in strings.split_lines(drawn_text(drawn), context.temp_allocator) {
		testing.expectf(t, len(line) <= sink.width, "the line %q is wider than the window", line)
	}
	testing.expect(t, drawn.lines > 1 + 3 + 1, "the least columns break no text")
}

// A stream narrows its columns of text at its head, and its rows go on in
// them.
@(test)
a_stream_breaks_its_texts_in_the_columns_of_its_head :: proc(t: ^testing.T) {
	table := new(Note_Table, context.temp_allocator)
	note_table_make(t, table)
	note_table_add(table, "isolate_memory", "isolate the module file of a memory object", 3)
	columns, ok := stream_columns_of(table.file, 1)
	testing.expect(t, ok)
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	sink.width = 60
	draw_stream_head(&sink, &columns, table.file)
	testing.expect(t, columns.wrapped, "the columns are not narrowed")
	draw_stream_row(&sink, &columns, table.rows[:table.size])
	for line in strings.split_lines(drawn_text(drawn), context.temp_allocator) {
		testing.expectf(t, len(line) <= 60, "the line %q is wider than the window", line)
	}
	testing.expect(t, drawn.lines >= 3, "the note is not broken")
}

// A long text of a record goes on under the start of its value.
@(test)
a_record_breaks_a_long_text_under_its_value :: proc(t: ^testing.T) {
	table := new(Note_Table, context.temp_allocator)
	note_table_make(t, table)
	note_table_add(table, "start", "start a process, by module name, with a wiring list or none", 17)
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	sink.width = 30
	draw_record(&sink, table.file, 1, table.rows[:table.size])
	expected :=
		"Command\n" +
		"  name   start\n" +
		"  note   start a process, by\n" +
		"         module name, with a\n" +
		"         wiring list or none\n" +
		"  count  17\n"
	testing.expect_value(t, drawn_text(drawn), expected)
}
// A table whose texts hold a character of two bytes and wide characters:
// the columns are counted in the columns of the terminal, so each row
// ends at the column of the head, and each line of a broken text keeps the
// part of its cell.
@(test)
a_table_counts_columns_not_bytes :: proc(t: ^testing.T) {
	table := new(Note_Table, context.temp_allocator)
	note_table_make(t, table)
	note_table_add(table, "café", "é é é é é é é é é é é é", 1)
	note_table_add(table, "日本", "日本語 日本語 日本語 日本語", 22)
	bytes := table.rows[:table.row_count * table.size]
	drawn := new(Drawn, context.temp_allocator)
	sink := drawn_sink(drawn)
	draw_table(&sink, table.file, 1, bytes, 20)
	lines := strings.split_lines(drawn_text(drawn), context.temp_allocator)
	head := text_columns(lines[0])
	testing.expect_value(t, text_columns(lines[1]), head)
	testing.expect_value(t, text_columns(lines[2]), head)
	// Narrow: each line fits, and a line that goes on is in the part of its
	// cell, Plain, as its first line.
	drawn^ = {}
	sink.width = 30
	draw_table(&sink, table.file, 1, bytes, 20)
	for line in strings.split_lines(drawn_text(drawn), context.temp_allocator) {
		testing.expectf(t, text_columns(line) <= 30, "the line %q is wider than the window", line)
	}
	testing.expect(t, drawn.lines > 1 + 2 + 1, "no text is broken")
	for run in drawn.runs[:drawn.run_count] {
		text := string(drawn.text[run.start:][:run.length])
		if strings.contains(text, "日本語") || strings.contains(text, "é é") {
			testing.expectf(t, run.part == .Plain, "the part of %q is %v", text, run.part)
		}
	}
}
