package console

import module "modus:contract/module"
import "modus:contract/value_kinds"
import "modus:console_condition"
import "internal:console/console_results"
import "internal:console/console_stream"
import "modus:lex_evaluator"
import "modus:lex_parser"
import "modus:sentence"

// Tables: a value that holds records of one record description, one after
// the other (module.Type.Table). A Table result of an export gives one, and
// a few generic commands combine them. They know no table: each one reads
// the description of the records, as the module contract writes it.
//
//   where(table, field = value)  the rows whose field passes a condition
//   sort(table, field)           the rows in the order of a field
//   join(left, right, field)     each pair of rows with the same value of a field
//   columns(table, a, b, c)      the rows with some fields only
//   first(table, count)          the first rows
//   skip(table, count)           the rows after the first rows
//   rows(table)                  the count of rows
//   row(table, number)           one row, as a Record, from 1
//
// join and columns make records with a new description. The console writes
// that description in the format of the module contract: a header, a table
// directory, and the tables Records, Fields and Strings (description_make).
// The description has no second format.

TABLE_ARENA :: 256 * 1024 // The memory of the tables of one line.
TABLE_KEPT :: 32 * 1024 // The bytes of the rows that a variable keeps.
DESCRIPTION_SIZE :: 2048 // The bytes of a description that join or columns makes.
COLUMN_CAPACITY :: console_results.COLUMN_LIMIT

table_memory: [TABLE_ARENA]u8
table_used: int

// table_bytes gives zero bytes from the memory of the tables of the line,
// at a multiple of 8. nil: the line has no room.
table_bytes :: proc "contextless" (size: int) -> []u8 {
	start := (table_used + 7) &~ 7
	if size < 0 || size > len(table_memory) - start {
		return nil
	}
	table_used = start + size
	bytes := table_memory[start:table_used]
	for &b in bytes {
		b = 0
	}
	return bytes
}

// in_table_memory says if bytes are in the memory of the tables of the line:
// a variable that keeps them needs a copy.
in_table_memory :: proc "contextless" (bytes: []u8) -> bool {
	start, end := uintptr(&table_memory[0]), uintptr(&table_memory[0]) + TABLE_ARENA
	return len(bytes) > 0 && uintptr(raw_data(bytes)) >= start && uintptr(raw_data(bytes)) < end
}

// A Table value, read with its description.
Table :: struct {
	file:   []u8,
	record: module.Record,
	size:   int,
	rows:   int,
}

table_of :: proc "contextless" (value: Value) -> (table: Table, ok: bool) {
	if value.kind != .Table {
		return {}, false
	}
	table.record = module.record_type(value.file, value.detail) or_return
	table.file, table.size = value.file, int(table.record.size)
	if table.size == 0 {
		return {}, false
	}
	table.rows = len(value.record) / table.size
	return table, true
}

table_row :: proc "contextless" (table: Table, value: Value, index: int) -> []u8 {
	return value.record[index * table.size:][:table.size]
}

table_field :: proc "contextless" (table: Table, name: string) -> (item: module.Field, ok: bool) {
	for number in 0 ..< table.record.field_count {
		item = module.field(table.file, table.record, number) or_return
		if module.string_at(table.file, item.name_offset, item.name_count) == name {
			return item, true
		}
	}
	return {}, false
}

// field_names writes the names of the fields of a table, for an error.
field_names :: proc "contextless" (table: Table) -> string {
	start := scratch_count
	for number in 0 ..< table.record.field_count {
		item, _ := module.field(table.file, table.record, number)
		scratch_text(number > 0 ? ", " : "", module.string_at(table.file, item.name_offset, item.name_count))
	}
	return string(scratch[start:scratch_count])
}

// row_field gives one field of a row as the value that where, sort and
// join compare (console_condition.values_compare): an Integer with its
// sign, a handle, or a Text. A field with no such value gives a zero
// value: table_argument refused a Bytes field before.
row_field :: proc "contextless" (row: []u8, item: module.Field) -> console_condition.Field_Value {
	value, _ := console_condition.field_value_of(row, item)
	return value
}

// table_argument reads the table argument of a command, and one of its
// fields by name.
table_argument :: proc "contextless" (command: string, value: Value, name: string) -> (table: Table, item: module.Field, ok: bool) {
	table, ok = table_of(value)
	if !ok {
		fail(command, ": the table has no valid description")
		return
	}
	if item, ok = table_field(table, name); !ok {
		fail(command, ": the records ", type_text(table.file, .Record, value.detail), " have no field ", name, "; their fields are ", field_names(table))
		return
	}
	// A hash is neither an Integer nor a Text: the console has no value of
	// it to compare.
	if item.type == u8(module.Type.Bytes) {
		fail(command, ": the field ", name, " is ", type_text_of_field(table.file, item), "; ", command, " compares an Integer or a Text")
		return table, item, false
	}
	return
}

// tables_start adds the commands of tables. Each one takes a table of any
// record and reads only its description, so one command serves each table
// of each service. A command that gives a table gives a new table in the
// memory of the line: the table of its argument does not change.
//
// The tables of one line share 256 KiB; a variable keeps at most 32 KiB of
// rows. The console draws a table as a line of the names of its fields, a
// line for each row, and the count: "2 rows of Import"
// (docs/CONSOLE.md, "Results and their drawers").
tables_start :: proc "contextless" () {
	// Gives the rows of a table whose field passes a condition, in their
	// order.
	//
	// - `table`: a table of any record.
	// - `condition`: a field of its record, an operator and a value, as
	//   `block = 12`. The field is a name of the record, never a variable.
	//   The operators are `=`, `!=`, `<`, `<=`, `>` and `>=`. An Integer or
	//   a handle field takes an Integer and each operator. A Text field
	//   takes a Text, and a status field the name of a member of its enum
	//   (`level = Warning`), with `=` and `!=` only: the order of the
	//   members is no order of weight.
	//
	// The result has the record of the table.
	//
	// ```
	// > columns(where(manual.running(), module = "calendar_fixed"), process, slot, module, replaces)
	// > log.records(0) |> where(level = Warning) |> where(process = "storage")
	// ```
	//
	// Errors, before any row is read: the records have no such field (the
	// error lists their fields); the kind of the value is not the kind of
	// the field: "error: where: the field code is Integer, the value is
	// Text"; a name that names no member of the enum of a status (the error
	// lists the members); an order on a Text or a status; a hash.
	//
	// A Stream takes a condition too, and gives the same Stream: the
	// console checks the condition on each record as it reads it, so the
	// line reads no record that it does not keep (docs/CONSOLE.md,
	// "Streams").
	//
	// ```
	// > output_counter.counts |> where(status = 404) |> first(3)
	// ```
	command("where", {.Table, .None}, .Table, "the rows of a table or a stream whose field passes a condition: where(t, block = 12)", table_where, forms = {.Expression, .Condition})
	command_takes_stream()
	// Gives the rows of a table in the increasing order of a field.
	//
	// - `table`: a table of any record.
	// - `field`: the name of the field: integers by value, texts byte by
	//   byte.
	//
	// Rows with one value keep their order, so two sorts give an order by
	// two fields. The result has the record of the table.
	//
	// ```
	// > sort(columns(manual.handles("Write"), module, name, rights), "name")
	// ```
	command("sort", {.Table, .Text}, .Table, "the rows of a table in the order of a field", table_sort)
	// Gives one row for each pair of a row of the left table and a row of
	// the right table that have one value of a field.
	//
	// - `left`, `right`: two tables of any records.
	// - `field`: a field that both records have, of one kind.
	//
	// The new record has each field of the left record, then each field of
	// the right record whose name the left record does not have, at most 40
	// fields. Its name is `<left>_<right>`. The console writes its
	// description in the format of the module contract.
	//
	// ```
	// > join(columns(manual.running(), process, hash), columns(manual.modules(), hash, name, code, exports), "hash")
	// ```
	//
	// Errors: the field is a text on one side and an integer on the other;
	// the new record is larger than a record can be: choose fewer fields
	// with `columns` first.
	command("join", {.Table, .Table, .Text}, .Table, "each pair of rows of two tables with one value of a field", table_join)
	// Gives the rows with only the fields that the names choose, in their
	// order.
	//
	// - `table`: a table of any record, or a Stream.
	// - `fields`: one name of a field of its record or more, separated by
	//   commas. A name is a field, never a variable or a text.
	//
	// The new record keeps the name of the record. A table that `columns`
	// made is not the table that an export takes: an export checks the
	// whole record. On a Stream, it gives a Stream whose rows hold those
	// fields; its conditions still read the whole record.
	//
	// ```
	// > columns(manual.importers("calendar_fixed"), module, name, replacement, import_slots)
	// > output_counter.counts |> columns(status) |> first(2)
	// ```
	//
	// Errors: a name names no field (the error lists the fields), before
	// the line runs when the console knows the record on the left of `|>`.
	command("columns", {.Table, .None}, .Table, "the rows with the fields that the names choose: columns(t, a, b)", table_columns, forms = {.Expression, .Field_Names})
	command_takes_stream()
	// Gives the first rows of a table, at most a count: a count larger than
	// the table gives the whole table, and 0 or less gives no row.
	//
	// On a Stream, it reads records until it has the count of rows that
	// pass the conditions of the Stream, or until the stream ends, then
	// closes the stream: the writer reads the end word `Side_Closed`. The
	// Table has the rows only; the draw of a Stream shows its joined
	// record and its gaps. Escape stops the read, and the line fails with
	// the count of the rows that came.
	command("first", {.Table, .Integer}, .Table, "the first rows of a table or of a stream", table_first)
	command_takes_stream()
	// Gives the rows of a table after its first rows: a count larger than
	// the table gives no row, and 0 or less gives the whole table.
	//
	// The console draws the first 20 rows of a table. `skip(table, 20)`
	// gives the rows after them, and `first(skip(table, 20), 20)` the next
	// 20.
	command("skip", {.Table, .Integer}, .Table, "the rows of a table after its first rows", table_skip)
	// Gives the count of rows of a table, as an `Integer`.
	//
	// Its name is not `count`: the module `probe` exports `count`, and a
	// command of a module hides a command of the console with its name.
	command("rows", {.Table}, .Integer, "the count of rows of a table", table_count)
	// Gives one row of a table as a `Record`, from 1. After `r = row(t, 1)`,
	// `r.value` reads one field of the first row.
	//
	// Error: "row: the table has N rows, not a row M".
	command("row", {.Table, .Integer}, .Record, "one row of a table, from 1", table_one)
	// Gives the rows of a Stream until its end, as a Table.
	//
	// - `stream`: a Stream, with its conditions. A Table gives itself.
	//
	// The line waits for the end record of the writer, or for an end word:
	// its stop, a revocation. Escape stops the wait, and the line fails
	// with the count of the rows that came.
	//
	// ```
	// > table(output_counter.counts |> where(status = 404))
	// ```
	//
	// Error: the rows pass the 32 KiB that a Table of a line keeps before
	// the end of the stream: `first(s, n)` keeps the first rows.
	command("table", {.Table}, .Table, "the rows of a stream until its end", stream_table)
	command_takes_stream()
	// Gives one row for each record output that a module declares: its
	// name, its record, and its line of help. The name is the second part
	// of the typed name of the record output: `output_counter.counts`.
	//
	// - `module`: the name of a module of the boot image.
	//
	// ```
	// > record_outputs("output_counter")
	// output  record   about
	// counts  Counted  One record each time the writer counts, while a reader is wired.
	// 1 row of Record_Output
	// ```
	//
	// Errors: no module of the boot image has the name.
	command("record_outputs", {.Text}, .Table, "the record outputs of a module: record_outputs(\"server\")", record_outputs)
	// Gives the counts of the writer of a record output: the records
	// written, discarded with no reader (or that the condition of each
	// reader left out), and refused as `Full`. They are the claim of the
	// writer, as it published them at its last write before the console
	// read them: at least as new as the joined record.
	//
	// - `stream`: a Stream, by its typed name.
	//
	// The console wires the record output, waits for its first
	// compartment, the joined record, which the writer writes at its next
	// write, also when the condition of the Stream leaves that record out;
	// then it reads the counts and closes the record stream. Escape stops
	// the wait.
	//
	// ```
	// > stream_counts(output_counter.counts)
	// Writer_Counts
	//   written    12
	//   discarded  0
	//   refused    0
	//   held       0
	//   rings_past_gap  0
	// ```
	command("stream_counts", {.Stream}, .Record, "the counts of the writer of a record output: stream_counts(server.requests)", stream_counts)
	// Gives the Table of one row of a wiring list: the record output
	// `from` to the record input `to`, each by its typed name.
	//
	// - `from`: a Stream. Its first condition goes with the row, so the
	//   writer writes only the records that pass it.
	// - `to`: a record input, by its typed name.
	//
	// The row names its ends by their names; `start(module, list)` applies
	// it, and `+` joins two lists. The record `Wiring` holds `writer`,
	// `output`, `reader`, `input`, the text of the `condition`, and its
	// terms (`field`, `comparison`, `value_kind`, `integer`, `text`).
	//
	// ```
	// > wire(where(output_counter.counts, status = 404), output_count_reader.counts)
	// ```
	//
	// Errors: the two records differ; one process at both ends; a Stream
	// with more than one condition, or that `columns` cut.
	command("wire", {.Stream, .Record_Input}, .Table, "one row of a wiring list, from a record output to a record input", wire)
}

// command_takes_stream marks the command added last as a command whose
// first parameter, a Table, takes a Stream too.
command_takes_stream :: proc "contextless" () {
	commands[command_count - 1].takes_stream = true
}

// table_sum_value gives the Table of the rows of two Tables of one record
// description, in the memory of the tables of the line: "+" on two Tables.
table_sum_value :: proc "contextless" (left, right: Value) -> Value {
	start := (table_used + 7) &~ 7
	if start > len(table_memory) {
		start = len(table_memory)
	}
	into := table_memory[start:]
	written, refusal := console_stream.table_sum(left.file, left.detail, left.record, right.file, right.detail, right.record, into)
	if refusal != .None {
		left_record, _ := module.record_type(left.file, left.detail)
		right_record, _ := module.record_type(right.file, right.detail)
		writer := sentence.Writer {
			buffer = scratch[scratch_count:],
		}
		console_stream.sum_refusal_write(&writer, refusal, module.string_at(left.file, left_record.name_offset, left_record.name_count), module.string_at(right.file, right_record.name_offset, right_record.name_count), len(into))
		text := sentence.written(&writer)
		scratch_count += len(text)
		return fail(text)
	}
	table_used = start + written
	return {kind = .Table, record = table_memory[start:table_used], file = left.file, detail = left.detail}
}

// table_where gives the rows of a table whose field passes the condition
// that the parser read and condition_evaluate checked.
table_where :: proc "contextless" (arguments: []Value) -> Value {
	// The evaluation of a Condition node gives one; a value of another
	// source has none.
	if arguments[1].condition == nil {
		return fail("where takes a condition: a field, an operator and a value, as where(t, block = 12)")
	}
	if arguments[0].kind == .Stream {
		return stream_where(arguments[0], arguments[1].condition)
	}
	condition := arguments[1].condition^
	table, item, ok := table_argument("where", arguments[0], condition.field)
	if !ok {
		return {}
	}
	count := 0
	if item.kind == u8(value_kinds.Field_Kind.Text_View) {
		// A text view is decided from its 16 bytes: its length, its
		// prefix, and a short text whole. A table carries no out-of-line
		// area, so a long text with the length and the prefix of the
		// condition cannot be decided, and the line fails: a row is never
		// kept or left by a guess.
		for index in 0 ..< table.rows {
			_, _, decided := console_condition.text_view_condition_holds(table_row(table, arguments[0], index), item, nil, condition)
			if !decided {
				return fail("where: a row holds in ", condition.field, " a text of more than ", i64(value_kinds.TEXT_VIEW_INLINE_BYTES_MOST), " bytes with the length and the start of \"", condition.text, "\", whose next bytes the table does not carry")
			}
		}
	}
	for index in 0 ..< table.rows {
		count += int(table_row_holds(table_row(table, arguments[0], index), item, condition))
	}
	bytes := table_bytes(count * table.size)
	if bytes == nil && count > 0 {
		return fail("where: the line has no room for ", i64(count), " rows")
	}
	place := 0
	for index in 0 ..< table.rows {
		row := table_row(table, arguments[0], index)
		if table_row_holds(row, item, condition) {
			copy(bytes[place:], row)
			place += table.size
		}
	}
	return {kind = .Table, record = bytes, file = arguments[0].file, detail = arguments[0].detail}
}

// table_row_holds says if the field of a row passes a condition: a text
// view by its 16 bytes (table_where checked that each one is decided),
// each other field by its value.
table_row_holds :: proc "contextless" (row: []u8, item: module.Field, condition: Condition) -> bool {
	if item.kind == u8(value_kinds.Field_Kind.Text_View) {
		holds, _, _ := console_condition.text_view_condition_holds(row, item, nil, condition)
		return holds
	}
	return console_condition.condition_holds(row_field(row, item), condition)
}

// condition_fail fails the line with the sentence of a refusal of a
// condition, which console_condition writes.
condition_fail :: proc "contextless" (refusal: console_condition.Refusal, details: console_condition.Refusal_Details) -> Value {
	writer := sentence.Writer {
		buffer = scratch[scratch_count:],
	}
	console_condition.refusal_write(&writer, refusal, details)
	text := sentence.written(&writer)
	scratch_count += len(text)
	return fail(text)
}

// condition_evaluate evaluates a Condition node, the argument of a
// parameter of the form Condition: a field of the table of the first
// argument, an operator, and a value (console_condition). A status field
// takes the name of a member, which becomes its word there, at one place;
// another field takes an expression of its kind, in the range of the field.
// Each fault fails the line before the command runs.
condition_evaluate :: proc "contextless" (command_name: string, before: []Value, condition_node: lex_parser.Node_Index) -> Value {
	if len(before) == 0 {
		return fail(command_name, ": a condition comes after a table: ", command_name, "(t, block = 12)")
	}
	if before[0].kind != .Table && before[0].kind != .Stream {
		return fail(command_name, ": argument 1 is ", kind_names[before[0].kind], ", not a Table or a Stream: a condition names a field of the record of a table")
	}
	// A Table and a Stream both name the description of their records.
	described, described_ok := module.record_type(before[0].file, before[0].detail)
	if !described_ok || described.size == 0 {
		return fail(command_name, ": the table has no valid description")
	}
	table := Table {
		file   = before[0].file,
		record = described,
	}
	details := console_condition.Refusal_Details {
		command = command_name,
		file    = table.file,
		record  = table.record,
	}
	node := lex_parser.node_at(&line_tree, condition_node)
	head, refusal := node.condition_head, node.condition_refusal
	details.field, details.comparison = head.field, head.comparison
	if refusal != .None {
		return condition_fail(refusal, details)
	}
	found: bool
	if details.item, found = console_condition.field_find(table.file, table.record, head.field); !found {
		return condition_fail(.Unknown_Field, details)
	}
	if refusal = console_condition.field_check(details.item, head.comparison); refusal != .None {
		return condition_fail(refusal, details)
	}
	condition := Condition{field = head.field, comparison = head.comparison}
	which, status := console_condition.field_is_status(details.item)
	if status {
		word: u64
		word, details.member, _, refusal = console_condition.member_read(line_tree.text, head.value_start, which)
		if refusal != .None {
			return condition_fail(refusal, details)
		}
		condition.compared = i64(word)
	} else {
		// The value is a thunk of the evaluation: its refusal stops the
		// evaluation, which writes the sentence.
		value, forced := lex_evaluator.force(&line_evaluation, node.first_child)
		if !forced || failed {
			return {}
		}
		details.value_type = type_of_kind(value.kind)
		if refusal = console_condition.value_check(details.item, details.value_type, value.integer); refusal != .None {
			return condition_fail(refusal, details)
		}
		condition.compared, condition.text = value.integer, value.text
	}
	kept: ^Condition
	if kept, refusal = console_condition.condition_keep(&line_conditions, condition); refusal != .None {
		return condition_fail(refusal, details)
	}
	// After the name of a member, the argument ends: a status reads one
	// name, never an expression.
	if status && !node.member_alone {
		return fail("\",\" or \")\" is missing")
	}
	return {condition = kept}
}

// table_sort gives the rows of a table in the increasing order of a field.
// Rows with the same value keep their order.
table_sort :: proc "contextless" (arguments: []Value) -> Value {
	table, item, ok := table_argument("sort", arguments[0], arguments[1].text)
	if !ok {
		return {}
	}
	bytes := table_bytes(len(arguments[0].record))
	if bytes == nil && table.rows > 0 {
		return fail("sort: the line has no room for ", i64(table.rows), " rows")
	}
	copy(bytes, arguments[0].record)
	sorted := Value{kind = .Table, record = bytes, file = arguments[0].file, detail = arguments[0].detail}
	held: [module.RECORD_SIZE_LIMIT]u8
	for index in 1 ..< table.rows {
		copy(held[:], table_row(table, sorted, index))
		key := row_field(held[:table.size], item)
		place := index
		for place > 0 && console_condition.values_compare(row_field(table_row(table, sorted, place - 1), item), key) > 0 {
			copy(table_row(table, sorted, place), table_row(table, sorted, place - 1))
			place -= 1
		}
		copy(table_row(table, sorted, place), held[:table.size])
	}
	return sorted
}

// description_make writes the description of one record in the format of
// the module contract, in the memory of the tables of the line, and gives
// the offset of each column and the size of the record
// (console_results.description_write).
description_make :: proc "contextless" (name: string, columns: []Column) -> (file: []u8, size: u32, ok: bool) {
	buffer := table_bytes(DESCRIPTION_SIZE)
	if buffer == nil {
		return nil, 0, false
	}
	return console_results.description_write(buffer, name, columns)
}

// columns_of adds the fields of a table to a list of columns. With skip,
// it leaves out each field whose name the list has.
columns_of :: proc "contextless" (table: Table, side: int, list: ^[COLUMN_CAPACITY]Column, count: ^int, skip: bool) -> bool {
	each: for number in 0 ..< table.record.field_count {
		item, _ := module.field(table.file, table.record, number)
		name := module.string_at(table.file, item.name_offset, item.name_count)
		if skip {
			for column in list[:count^] {
				if column.name == name {
					continue each
				}
			}
		}
		// table_of checked each field: a byte that names no type or no
		// kind gives no column, and the new record is refused. The column
		// keeps the unit and the kind of the field.
		column, column_ok := console_results.column_of_field(name, item)
		if count^ == COLUMN_CAPACITY || !column_ok {
			return false
		}
		column.side = side
		list[count^] = column
		count^ += 1
	}
	return true
}

// table_join gives a row for each pair of a row of the left table and a row
// of the right table that have the same value of a field. The new record
// has each field of the left record, then each field of the right record
// whose name the left record does not have.
table_join :: proc "contextless" (arguments: []Value) -> Value {
	name := arguments[2].text
	left, left_item, left_ok := table_argument("join", arguments[0], name)
	if !left_ok {
		return {}
	}
	right, right_item, right_ok := table_argument("join", arguments[1], name)
	if !right_ok {
		return {}
	}
	if (left_item.type == u8(module.Type.Text)) != (right_item.type == u8(module.Type.Text)) {
		return fail("join: the field ", name, " is ", type_text_of_word(left.file, left_item.type, left_item.detail), " on the left and ", type_text_of_word(right.file, right_item.type, right_item.detail), " on the right")
	}
	columns: [COLUMN_CAPACITY]Column
	count := 0
	if !columns_of(left, 0, &columns, &count, false) || !columns_of(right, 1, &columns, &count, true) {
		return fail("join: the new record has more than ", i64(COLUMN_CAPACITY), " fields")
	}
	left_name := module.string_at(left.file, left.record.name_offset, left.record.name_count)
	right_name := module.string_at(right.file, right.record.name_offset, right.record.name_count)
	file, size, made := description_make(scratch_text(left_name, "_", right_name), columns[:count])
	if !made {
		return fail("join: the new record has ", u64(size), " bytes, the limit is ", u64(module.RECORD_SIZE_LIMIT), "; choose fewer fields with columns()")
	}
	rows := 0
	for a in 0 ..< left.rows {
		key := row_field(table_row(left, arguments[0], a), left_item)
		for b in 0 ..< right.rows {
			rows += int(console_condition.values_compare(key, row_field(table_row(right, arguments[1], b), right_item)) == 0)
		}
	}
	bytes := table_bytes(rows * int(size))
	if bytes == nil && rows > 0 {
		return fail("join: the line has no room for ", i64(rows), " rows")
	}
	place := 0
	for a in 0 ..< left.rows {
		row_left := table_row(left, arguments[0], a)
		key := row_field(row_left, left_item)
		for b in 0 ..< right.rows {
			row_right := table_row(right, arguments[1], b)
			if console_condition.values_compare(key, row_field(row_right, right_item)) != 0 {
				continue
			}
			for column in columns[:count] {
				source := column.side == 0 ? row_left : row_right
				width := module.field_size(console_results.column_field(column))
				copy(bytes[place + int(column.offset):][:width], source[column.from:][:width])
			}
			place += int(size)
		}
	}
	return {kind = .Table, record = bytes, file = file, detail = 1}
}

// table_columns gives the rows with the fields that a text names, in that
// order. The names are separated by spaces or commas.
table_columns :: proc "contextless" (arguments: []Value) -> Value {
	// The parser gives each argument of the form Field_Names a Text of the
	// names; a value of another source is no list of names.
	if arguments[1].kind != .Text || arguments[1].text == "" {
		return fail("columns takes the names of fields: columns(t, slot, name)")
	}
	if arguments[0].kind == .Stream {
		return stream_columns(arguments[0], arguments[1].text)
	}
	table, ok := table_of(arguments[0])
	if !ok {
		return fail("columns: the table has no valid description")
	}
	columns: [COLUMN_CAPACITY]Column
	count := 0
	rest := arguments[1].text
	for len(rest) > 0 {
		end := 0
		for end < len(rest) && rest[end] != ' ' && rest[end] != ',' {
			end += 1
		}
		name := rest[:end]
		rest = rest[min(end + 1, len(rest)):]
		if name == "" {
			continue
		}
		item, found := table_field(table, name)
		if !found {
			return fail("columns: the records ", type_text(table.file, .Record, arguments[0].detail), " have no field ", name, "; their fields are ", field_names(table))
		}
		if count == COLUMN_CAPACITY {
			return fail("columns: more than ", i64(COLUMN_CAPACITY), " fields")
		}
		column, column_ok := console_results.column_of_field(name, item)
		if !column_ok {
			return fail("columns: the field ", name, " has a type or a kind that names nothing")
		}
		columns[count] = column
		count += 1
	}
	if count == 0 {
		return fail("columns: no field is named; the fields are ", field_names(table))
	}
	file, size, made := description_make(module.string_at(table.file, table.record.name_offset, table.record.name_count), columns[:count])
	if !made {
		return fail("columns: no room for the description")
	}
	bytes := table_bytes(table.rows * int(size))
	if bytes == nil && table.rows > 0 {
		return fail("columns: the line has no room for ", i64(table.rows), " rows")
	}
	for index in 0 ..< table.rows {
		row := table_row(table, arguments[0], index)
		for column in columns[:count] {
			width := module.field_size(console_results.column_field(column))
			copy(bytes[index * int(size) + int(column.offset):][:width], row[column.from:][:width])
		}
	}
	return {kind = .Table, record = bytes, file = file, detail = 1}
}

table_first :: proc "contextless" (arguments: []Value) -> Value {
	if arguments[0].kind == .Stream {
		return stream_collect("first", arguments[0], int(clamp(arguments[1].integer, 0, i64(max(int)))))
	}
	table, ok := table_of(arguments[0])
	if !ok {
		return fail("first: the table has no valid description")
	}
	kept := clamp(int(arguments[1].integer), 0, table.rows)
	result := arguments[0]
	result.record = result.record[:kept * table.size]
	return result
}

table_skip :: proc "contextless" (arguments: []Value) -> Value {
	table, ok := table_of(arguments[0])
	if !ok {
		return fail("skip: the table has no valid description")
	}
	skipped := arguments[1].integer <= 0 ? 0 : arguments[1].integer >= i64(table.rows) ? table.rows : int(arguments[1].integer)
	result := arguments[0]
	result.record = result.record[skipped * table.size:]
	return result
}

table_count :: proc "contextless" (arguments: []Value) -> Value {
	table, ok := table_of(arguments[0])
	if !ok {
		return fail("rows: the table has no valid description")
	}
	return {kind = .Integer, integer = i64(table.rows)}
}

table_one :: proc "contextless" (arguments: []Value) -> Value {
	table, ok := table_of(arguments[0])
	if !ok {
		return fail("row: the table has no valid description")
	}
	number := arguments[1].integer
	if number < 1 || number > i64(table.rows) {
		return fail("row: the table has ", i64(table.rows), " rows, not a row ", number)
	}
	bytes := scratch_bytes(table.size)
	if bytes == nil {
		return fail("the line has too many records")
	}
	copy(bytes, table_row(table, arguments[0], int(number - 1)))
	return {kind = .Record, record = bytes, file = arguments[0].file, detail = arguments[0].detail}
}

// The buffer of a Table result of a direct call: the free part of the
// memory of the tables of the line.
Table_Buffer :: struct {
	slice: struct {
		address:  uintptr,
		capacity: u64, // In records.
	},
	size:  int,
}

table_buffer :: proc "contextless" (file: []u8, detail: u32) -> (buffer: Table_Buffer) {
	described, _ := module.record_type(file, detail)
	buffer.size = int(described.size)
	start := (table_used + 7) &~ 7
	if buffer.size == 0 || start > len(table_memory) {
		return buffer
	}
	buffer.slice = {uintptr(&table_memory[0]) + uintptr(start), u64((len(table_memory) - start) / buffer.size)}
	return buffer
}

// table_take gives the Table value of a direct call: the export wrote the
// records in the buffer, and gave the count of records of the full table.
table_take :: proc "contextless" (item: ^Command, buffer: ^Table_Buffer, count: u64) -> Value {
	if i64(count) < 0 {
		return table_error(item, i64(count))
	}
	if count > buffer.slice.capacity {
		return fail("the result of ", item.name, " has ", count, " records; ", buffer.slice.capacity, " fit in the memory of the line")
	}
	// The records stay where the export wrote them: the line keeps them.
	start := (table_used + 7) &~ 7
	table_used = start + int(count) * buffer.size
	bytes := table_memory[start:table_used]
	return {kind = .Table, record = bytes, file = item.file, detail = item.function.result_detail}
}

// table_error reports the negative count of a Table result: the export had
// no table to give. Its documentation says what each number means.
table_error :: proc "contextless" (item: ^Command, number: i64) -> Value {
	return fail(item.name, " gave no table but the error ", number, ": the documentation of the export says what it means")
}
