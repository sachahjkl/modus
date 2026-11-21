// The pure parts of the streams of the console
// (src/md/features/module_outputs.md, "The console form"): the typed name
// of a record output, the find of a record output in a module file, the
// sentences of a joined record, a gap, an end and Escape, the bound of
// `first` and `table`, and the sum of two Tables with `+`.
//
// The package has no state, calls no allocator and makes no kernel call:
// each procedure reads memory of the caller and writes into memory of the
// caller, so host tests give each input.
package console_stream

import module "modus:contract/module"
import "modus:contract/output"
import "modus:console_condition"
import "modus:sentence"

// ---- The typed name.

// typed_name_split splits a typed name, "server.requests", into the name
// of its owner and the name of its record output. ok is false for a name
// with no dot, with more than one dot, or with an empty part: no record
// output has such a name, and the names of the processes have no dot.
typed_name_split :: proc "contextless" (name: string) -> (owner, stream: string, ok: bool) {
	dot := -1
	for index in 0 ..< len(name) {
		if name[index] != '.' {
			continue
		}
		if dot >= 0 {
			return "", "", false
		}
		dot = index
	}
	if dot <= 0 || dot == len(name) - 1 {
		return "", "", false
	}
	return name[:dot], name[dot + 1:], true
}

// record_output_count gives the rows of the table Record_Outputs of a
// module file: the table holds its row 0, which names nothing. A count past
// module.RECORD_STREAM_INDEX_MOST gives the bound: validate refuses such a
// file, and a reader of it reads no row past the bound.
record_output_count :: proc "contextless" (file: []u8) -> u32 {
	return min(max(module.count(file, .Record_Outputs), 1) - 1, module.RECORD_STREAM_INDEX_MOST)
}

// What the find of a record output gives besides its index.
Output_Find :: enum u8 {
	Found    = 0, // A record output of a record description.
	Absent   = 1, // The module declares no record output of the name.
	Generic  = 2, // A generic record output: its type comes with its wiring, and the console has no description to read it with.
	Damaged  = 3, // A row that module.record_output refuses: the file is no file that the loader takes.
}

// record_output_find gives the index from 1 of the record output of a name
// in a module file, and the index of the description of its record in the
// table Records. Each row goes through module.record_output, which checks
// it: a row that it refuses is Damaged, never a match.
record_output_find :: proc "contextless" (file: []u8, name: string) -> (index: u32, record: u32, found: Output_Find) {
	for row in 1 ..= record_output_count(file) {
		value, _, _, ok := module.record_output(file, row)
		if !ok {
			return 0, 0, .Damaged
		}
		if module.string_at(file, value.name_offset, value.name_count) != name {
			continue
		}
		if value.record == 0 {
			return row, 0, .Generic
		}
		return row, value.record, .Found
	}
	return 0, 0, .Absent
}

// record_input_count gives the rows of the table Record_Inputs of a module
// file, as record_output_count does.
record_input_count :: proc "contextless" (file: []u8) -> u32 {
	return min(max(module.count(file, .Record_Inputs), 1) - 1, module.RECORD_STREAM_INDEX_MOST)
}

// record_input_find gives the index from 1 of the record input of a name
// in a module file, and the index of the description of its record. A
// generic record input is Generic; a row that module.record_input refuses
// is Damaged, never a match.
record_input_find :: proc "contextless" (file: []u8, name: string) -> (index: u32, record: u32, found: Output_Find) {
	for row in 1 ..= record_input_count(file) {
		value, _, _, _, ok := module.record_input(file, row)
		if !ok {
			return 0, 0, .Damaged
		}
		if module.string_at(file, value.name_offset, value.name_count) != name {
			continue
		}
		if value.record == 0 {
			return row, 0, .Generic
		}
		return row, value.record, .Found
	}
	return 0, 0, .Absent
}

// record_output_names_write writes the names of the record outputs of a
// module file, separated by ", ": the sentence of a name that the module
// does not declare lists them.
record_output_names_write :: proc "contextless" (writer: ^sentence.Writer, file: []u8) {
	written := 0
	for row in 1 ..= record_output_count(file) {
		value, _, _, ok := module.record_output(file, row)
		if !ok {
			continue
		}
		sentence.write_part(writer, written > 0 ? ", " : "")
		sentence.write_part(writer, module.string_at(file, value.name_offset, value.name_count))
		written += 1
	}
}

// ---- The condition of a wiring.

// comparison_of gives the operator of a condition of a wiring for the
// operator of a condition of the console: the same six, with the values of
// the contract.
comparison_of :: proc "contextless" (comparison: console_condition.Comparison) -> output.Condition_Comparison {
	switch comparison {
	case .Equal:
		return .Equal
	case .Not_Equal:
		return .Not_Equal
	case .Less:
		return .Less
	case .Less_Or_Equal:
		return .Less_Or_Equal
	case .Greater:
		return .Greater
	case .Greater_Or_Equal:
		return .Greater_Or_Equal
	}
	return .None
}

// ---- The list of a start.

// Why the console refuses a row of the list of a start, before the root
// service reads it.
Start_Row_Refusal :: enum u8 {
	None             = 0,
	No_End_Of_Module = 1, // Neither end is the module that starts.
	Module_Twice     = 2, // Both ends are the module that starts: a wiring of a process to itself.
}

// start_row_ends says which ends of a row are the module that starts: they
// become the end Child, and the other end names a process that runs.
start_row_ends :: proc "contextless" (module_name, writer, reader: string) -> (writer_is_child, reader_is_child: bool, refusal: Start_Row_Refusal) {
	writer_is_child = writer == module_name
	reader_is_child = reader == module_name
	switch {
	case writer_is_child && reader_is_child:
		return false, false, .Module_Twice
	case !writer_is_child && !reader_is_child:
		return false, false, .No_End_Of_Module
	}
	return writer_is_child, reader_is_child, .None
}

// start_list_fits says if a list of rows, with its lent handles and the
// condition of each row, fits the bounds of the contract and the bytes of
// the list page. It gives the first byte of the conditions, after the lent
// handles.
start_list_fits :: proc "contextless" (rows, handles, conditions: int) -> (conditions_start: int, fits: bool) {
	if rows <= 0 || rows > output.WIRING_LIST_ROW_LIMIT || handles < 0 || handles > output.WIRING_LIST_HANDLE_LIMIT || conditions < 0 || conditions > rows {
		return 0, false
	}
	conditions_start = output.wiring_terms_start(rows, handles)
	return conditions_start, conditions_start + conditions * size_of(output.Condition_Terms) <= output.WIRING_LIST_BYTES_MOST
}

// ---- The notes of the draw.

// What a note of the draw of a Stream says: a row that is not a record.
Note_Kind :: enum u8 {
	Joined       = 0, // The reader joined after a count of records.
	Gap          = 1, // The ring refused a count of records for this reader.
	Clean_End    = 2, // An end record with no error, after a count of records.
	Error_End    = 3, // An end record with an error record, after a count of records.
	Ended_By     = 4, // An end word: the other side, the asker or a revocation ended the wiring.
	Escape       = 5, // Escape closed the reader end, after a count of rows.
}

// One note of the draw.
Note :: struct {
	kind:     Note_Kind,
	count:    u64, // Joined, Gap, Clean_End, Error_End: records. Escape: the rows drawn.
	end_word: output.End_Word, // Ended_By.
}

// note_write writes the sentence of a note. It gives false, and writes
// nothing, for a joined record of 0: the reader has the whole stream, and
// the draw says nothing of it.
note_write :: proc "contextless" (writer: ^sentence.Writer, note: Note) -> bool {
	part :: sentence.write_part
	switch note.kind {
	case .Joined:
		if note.count == 0 {
			return false
		}
		part(writer, "joined after ")
		part(writer, note.count)
		part(writer, note.count == 1 ? " record" : " records")
	case .Gap:
		part(writer, note.count)
		part(writer, note.count == 1 ? " record is missing here: the ring had no room for it" : " records are missing here: the ring had no room for them")
	case .Clean_End:
		part(writer, "the stream ended after ")
		part(writer, note.count)
		part(writer, note.count == 1 ? " record" : " records")
	case .Error_End:
		part(writer, "the stream ended with an error after ")
		part(writer, note.count)
		part(writer, note.count == 1 ? " record" : " records")
	case .Ended_By:
		part(writer, "the stream ended: ")
		switch note.end_word {
		case .None:
			// No end word is no end: the caller gives one that ended.
			part(writer, "no end word")
		case .Writer_Stopped:
			part(writer, "the writer stopped")
		case .Reader_Stopped:
			part(writer, "the reader stopped")
		case .Asker_Stopped:
			part(writer, "the asker stopped")
		case .Revoked:
			part(writer, "the wiring was revoked")
		case .Refused:
			part(writer, "a side refused its end")
		case .Side_Closed:
			part(writer, "the writer closed its end")
		}
	case .Escape:
		part(writer, "Escape closed the stream after ")
		part(writer, note.count)
		part(writer, note.count == 1 ? " row" : " rows")
	}
	return true
}

// ---- The sentences of the refusals.

// table_needed_write writes the sentence of a command that needs the whole
// of its rows, given a Stream: "sort takes a Table; a Stream has no end:
// first(s, n) or table(s) makes one".
table_needed_write :: proc "contextless" (writer: ^sentence.Writer, command: string) {
	sentence.write_part(writer, command)
	sentence.write_part(writer, " takes a Table; a Stream has no end: first(s, n) or table(s) makes one")
}

// VARIABLE_REFUSAL is the sentence of a Stream that a line keeps in a
// variable.
VARIABLE_REFUSAL :: "a variable keeps no Stream: a Stream is a wiring, and a variable outlives its line; first(s, n) or table(s) makes a Table"

// ---- The rows that first and table keep.

// What the read of a stream does with the next record that passes.
Collect_Step :: enum u8 {
	Keep      = 0, // It keeps the record as the next row.
	Done      = 1, // It has its count of rows: it ends the read.
	Too_Large = 2, // The memory holds no more row: table refuses the stream.
}

// TABLE_ROWS_WANTED_ALL is the count of table(s): every row until the end.
TABLE_ROWS_WANTED_ALL :: max(int)

// collect_step_of gives what the read does next, from the rows that it
// kept, the rows that it wants (TABLE_ROWS_WANTED_ALL for table), the size
// of a row and the bytes that hold the rows. A count of 0 or less, and a
// row size of 0 or less, give Done: no row is read.
collect_step_of :: proc "contextless" (kept, wanted, row_size, capacity: int) -> Collect_Step {
	if wanted <= 0 || row_size <= 0 || kept >= wanted {
		return .Done
	}
	if capacity < 0 || kept >= capacity / row_size {
		return .Too_Large
	}
	return .Keep
}

// table_too_large_write writes the sentence of table(s) whose rows pass the
// bytes that hold them.
table_too_large_write :: proc "contextless" (writer: ^sentence.Writer, rows: int, capacity: int) {
	sentence.write_part(writer, "table: the stream gave ")
	sentence.write_part(writer, u64(max(rows, 0)))
	sentence.write_part(writer, " rows and no end, and the line holds ")
	sentence.write_part(writer, u64(max(capacity, 0)))
	sentence.write_part(writer, " bytes of rows; first(s, n) keeps the first rows")
}

// ---- The sum of two Tables.

// Why a sum of two Tables is refused.
Sum_Refusal :: enum u8 {
	None              = 0,
	No_Description    = 1, // A side has no record description of a size that is not 0.
	Different_Records = 2, // The two descriptions are not equal (module.records_equal).
	Not_Whole_Rows    = 3, // A side has bytes that are not a whole count of rows.
	Too_Large         = 4, // The rows of both do not fit the memory of the result.
}

// table_sum writes the rows of the left table, then the rows of the right
// table, into into, and gives the bytes written. The two tables have equal
// record descriptions: a sum of two Tables of one description is the
// general operation that a wiring list uses
// (src/md/features/module_outputs.md, "The wiring list of a start"). On a
// refusal it writes nothing.
table_sum :: proc "contextless" (left_file: []u8, left_detail: u32, left_rows: []u8, right_file: []u8, right_detail: u32, right_rows: []u8, into: []u8) -> (written: int, refusal: Sum_Refusal) {
	left, left_ok := module.record_type(left_file, left_detail)
	right, right_ok := module.record_type(right_file, right_detail)
	if !left_ok || !right_ok || left.size == 0 || right.size == 0 {
		return 0, .No_Description
	}
	if !module.records_equal(left_file, left_detail, right_file, right_detail) {
		return 0, .Different_Records
	}
	size := int(left.size)
	if len(left_rows) % size != 0 || len(right_rows) % size != 0 {
		return 0, .Not_Whole_Rows
	}
	if len(left_rows) > len(into) || len(right_rows) > len(into) - len(left_rows) {
		return 0, .Too_Large
	}
	copy(into, left_rows)
	copy(into[len(left_rows):], right_rows)
	return len(left_rows) + len(right_rows), .None
}

// sum_refusal_write writes the sentence of a refused sum. left_name and
// right_name are the names of the two records.
sum_refusal_write :: proc "contextless" (writer: ^sentence.Writer, refusal: Sum_Refusal, left_name, right_name: string, capacity: int) {
	part :: sentence.write_part
	switch refusal {
	case .None:
	case .No_Description:
		part(writer, "\"+\": a table has no valid description")
	case .Different_Records:
		part(writer, "\"+\" joins two tables of one record: the left one has records ")
		part(writer, left_name)
		part(writer, ", the right one ")
		part(writer, right_name)
	case .Not_Whole_Rows:
		part(writer, "\"+\": a table holds bytes that are not a whole count of rows")
	case .Too_Large:
		part(writer, "\"+\": the rows of the two tables do not fit the ")
		part(writer, u64(max(capacity, 0)))
		part(writer, " bytes that the line has left")
	}
}
