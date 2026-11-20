#+build !freestanding
package console_stream

import module "modus:contract/module"
import "modus:contract/output"
import "modus:support/sentence"
import "core:testing"

// A module file of these tests: two records and two record outputs.
//
// The records: 1 "Counted", two unsigned Integers of 8 bytes; 2 "Other",
// one unsigned Integer of 8 bytes. The record outputs, sorted by name:
// 1 "counts" of Counted; 2 "mixed", generic.
@(private = "file")
Test_File :: struct {
	records: [dynamic]module.Record,
	fields:  [dynamic]module.Field,
	strings: [dynamic]u8,
	outputs: [dynamic]module.Record_Output,
}

@(private = "file")
COUNTED :: 1
@(private = "file")
OTHER :: 2

@(private = "file")
string_add :: proc(table: ^[dynamic]u8, text: string) -> (offset, count: u32) {
	offset = u32(len(table))
	append(table, text)
	return offset, u32(len(text))
}

@(private = "file")
test_file_parts :: proc() -> (parts: Test_File) {
	parts.records = make([dynamic]module.Record, context.temp_allocator)
	parts.fields = make([dynamic]module.Field, context.temp_allocator)
	parts.strings = make([dynamic]u8, context.temp_allocator)
	parts.outputs = make([dynamic]module.Record_Output, context.temp_allocator)
	append(&parts.strings, 0)
	append(&parts.records, module.Record{})
	append(&parts.fields, module.Field{})
	field_add :: proc(parts: ^Test_File, name: string, offset: u32) {
		name_offset, name_count := string_add(&parts.strings, name)
		append(&parts.fields, module.Field{name_offset = name_offset, name_count = name_count, offset = offset, type = u8(module.Type.Integer), unsigned = true})
	}
	record_add :: proc(parts: ^Test_File, name: string, size, field_count: u32) {
		name_offset, name_count := string_add(&parts.strings, name)
		append(&parts.records, module.Record{name_offset = name_offset, name_count = name_count, size = size, first_field = u32(len(parts.fields)), field_count = field_count})
	}
	record_add(&parts, "Counted", 16, 2)
	field_add(&parts, "serial", 0)
	field_add(&parts, "status", 8)
	record_add(&parts, "Other", 8, 1)
	field_add(&parts, "serial", 0)
	about_offset, about_count := string_add(&parts.strings, "One line of help.")
	output_add :: proc(parts: ^Test_File, name: string, record: u32, pairing: module.Record_Output_Pairing, about_offset, about_count: u32) {
		name_offset, name_count := string_add(&parts.strings, name)
		append(&parts.outputs, module.Record_Output{name_offset = name_offset, name_count = name_count, about_offset = about_offset, about_count = about_count, text_offset = about_offset, text_count = about_count, record = record, pairing = u8(pairing)})
	}
	append(&parts.outputs, module.Record_Output{})
	output_add(&parts, "counts", COUNTED, .Unpaired, about_offset, about_count)
	output_add(&parts, "mixed", 0, .Unpaired, about_offset, about_count)
	return parts
}

@(private = "file")
bytes_of :: proc(items: []$T) -> []u8 {
	return ([^]u8)(raw_data(items))[:len(items) * size_of(T)]
}

// test_file writes a module file of the parts: the header, the directory
// and each table, with no segment.
@(private = "file")
test_file :: proc(parts: Test_File) -> []u8 {
	file := make([dynamic]u8, size_of(module.Header) + module.TABLE_COUNT * size_of(module.Table_Entry), context.temp_allocator)
	directory: [module.TABLE_COUNT]module.Table_Entry
	add :: proc(file: ^[dynamic]u8, directory: ^[module.TABLE_COUNT]module.Table_Entry, kind: module.Table_Kind, bytes: []u8, count, record_size: u32) {
		for len(file) % 8 != 0 {
			append(file, 0)
		}
		directory[kind] = {offset = u64(len(file)), count = count, record_size = record_size}
		append(file, ..bytes)
	}
	add(&file, &directory, .Records, bytes_of(parts.records[:]), u32(len(parts.records)), size_of(module.Record))
	add(&file, &directory, .Fields, bytes_of(parts.fields[:]), u32(len(parts.fields)), size_of(module.Field))
	add(&file, &directory, .Strings, parts.strings[:], u32(len(parts.strings)), 1)
	add(&file, &directory, .Record_Outputs, bytes_of(parts.outputs[:]), u32(len(parts.outputs)), size_of(module.Record_Output))
	(^module.Header)(&file[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^[module.TABLE_COUNT]module.Table_Entry)(&file[size_of(module.Header)])^ = directory
	return file[:]
}

// A typed name has one dot, with a part on each side: a name with no dot,
// a dot first or last, two dots and an empty name are refused.
@(test)
a_typed_name_with_no_owner_or_no_stream_is_refused :: proc(t: ^testing.T) {
	for name in ([?]string{"", ".", "server", ".requests", "server.", "a.b.c", "server..requests"}) {
		_, _, ok := typed_name_split(name)
		testing.expectf(t, !ok, "the name %q is split", name)
	}
	owner, stream, ok := typed_name_split("s.r")
	testing.expect(t, ok && owner == "s" && stream == "r")
	owner, stream, ok = typed_name_split("server.requests")
	testing.expect(t, ok && owner == "server" && stream == "requests")
}

// A name that the module does not declare is Absent, a generic record
// output is Generic and gives no description, and a damaged row is
// Damaged, never a match. The record output of a description comes last.
@(test)
a_record_output_is_found_only_by_its_whole_name :: proc(t: ^testing.T) {
	file := test_file(test_file_parts())
	for name in ([?]string{"", "count", "countss", "Counts", "counts ", "requests"}) {
		_, _, found := record_output_find(file, name)
		testing.expectf(t, found == .Absent, "the name %q gave %v", name, found)
	}
	index, record, found := record_output_find(file, "mixed")
	testing.expect(t, found == .Generic && index == 2 && record == 0)

	damaged := test_file_parts()
	damaged.outputs[1].reserved[0] = 1
	_, _, found = record_output_find(test_file(damaged), "counts")
	testing.expect_value(t, found, Output_Find.Damaged)

	// A table that names no row and a file of no table.
	_, _, found = record_output_find(nil, "counts")
	testing.expect_value(t, found, Output_Find.Absent)

	index, record, found = record_output_find(file, "counts")
	testing.expect(t, found == .Found && index == 1 && record == COUNTED)
}

// The names of the record outputs, for a sentence: each row that the
// contract takes, in its order.
@(test)
the_names_of_the_record_outputs_are_listed :: proc(t: ^testing.T) {
	buffer: [128]u8
	writer := sentence.Writer{buffer = buffer[:]}
	record_output_names_write(&writer, nil)
	testing.expect_value(t, sentence.written(&writer), "")
	writer = {buffer = buffer[:]}
	record_output_names_write(&writer, test_file(test_file_parts()))
	testing.expect_value(t, sentence.written(&writer), "counts, mixed")
}

@(private = "file")
note_text :: proc(note: Note) -> (text: string, written: bool) {
	buffer := make([]u8, 256, context.temp_allocator)
	writer := sentence.Writer{buffer = buffer}
	written = note_write(&writer, note)
	return sentence.written(&writer), written
}

// A joined record of 0 writes nothing; of 1 and of the largest count, its
// count. Each end word has its own sentence, and None says that it is none.
@(test)
each_note_has_its_sentence :: proc(t: ^testing.T) {
	text, written := note_text({kind = .Joined, count = 0})
	testing.expect(t, !written && text == "")
	text, written = note_text({kind = .Joined, count = 1})
	testing.expect(t, written && text == "joined after 1 record")
	text, _ = note_text({kind = .Joined, count = max(u64)})
	testing.expect_value(t, text, "joined after 18446744073709551615 records")
	text, _ = note_text({kind = .Gap, count = 1})
	testing.expect_value(t, text, "1 record is missing here: the ring had no room for it")
	text, _ = note_text({kind = .Gap, count = 3})
	testing.expect_value(t, text, "3 records are missing here: the ring had no room for them")
	text, _ = note_text({kind = .Clean_End, count = 0})
	testing.expect_value(t, text, "the stream ended after 0 records")
	text, _ = note_text({kind = .Error_End, count = 1})
	testing.expect_value(t, text, "the stream ended with an error after 1 record")
	text, _ = note_text({kind = .Escape, count = 0})
	testing.expect_value(t, text, "Escape closed the stream after 0 rows")
	wanted := [output.End_Word]string {
		.None           = "the stream ended: no end word",
		.Writer_Stopped = "the stream ended: the writer stopped",
		.Reader_Stopped = "the stream ended: the reader stopped",
		.Asker_Stopped  = "the stream ended: the asker stopped",
		.Revoked        = "the stream ended: the wiring was revoked",
		.Refused        = "the stream ended: a side refused its end",
		.Side_Closed    = "the stream ended: the writer closed its end",
	}
	for sentence_wanted, word in wanted {
		text, written = note_text({kind = .Ended_By, end_word = word})
		testing.expectf(t, written && text == sentence_wanted, "the end word %v gave %q", word, text)
	}
}

// The edges of the count first: 0, a negative count, a row size of 0 or
// negative, a capacity of no row and a negative capacity; then the last
// row that fits, the one past it, and a count that is reached.
@(test)
the_read_of_first_and_table_stops_at_its_bound :: proc(t: ^testing.T) {
	testing.expect_value(t, collect_step_of(0, 0, 16, 1024), Collect_Step.Done)
	testing.expect_value(t, collect_step_of(0, -1, 16, 1024), Collect_Step.Done)
	testing.expect_value(t, collect_step_of(0, min(int), 16, 1024), Collect_Step.Done)
	testing.expect_value(t, collect_step_of(0, 3, 0, 1024), Collect_Step.Done)
	testing.expect_value(t, collect_step_of(0, 3, -16, 1024), Collect_Step.Done)
	testing.expect_value(t, collect_step_of(0, 3, 16, 15), Collect_Step.Too_Large)
	testing.expect_value(t, collect_step_of(0, 3, 16, -1), Collect_Step.Too_Large)
	testing.expect_value(t, collect_step_of(0, TABLE_ROWS_WANTED_ALL, 16, 0), Collect_Step.Too_Large)
	testing.expect_value(t, collect_step_of(63, TABLE_ROWS_WANTED_ALL, 16, 1024), Collect_Step.Keep)
	testing.expect_value(t, collect_step_of(64, TABLE_ROWS_WANTED_ALL, 16, 1024), Collect_Step.Too_Large)
	testing.expect_value(t, collect_step_of(64, 64, 16, 1024), Collect_Step.Done)
	testing.expect_value(t, collect_step_of(3, 3, 16, 1024), Collect_Step.Done)
	testing.expect_value(t, collect_step_of(4, 3, 16, 1024), Collect_Step.Done)
	testing.expect_value(t, collect_step_of(2, 3, 16, 1024), Collect_Step.Keep)
	testing.expect_value(t, collect_step_of(0, 1, 16, 16), Collect_Step.Keep)
}

// A sum is refused, with nothing written, for a side with no description,
// two different records, a side that is not whole rows, and rows past the
// memory, at one byte past it. Then the sums: an empty side, and two
// tables whose rows fill the memory exactly.
@(test)
a_sum_of_two_tables_is_whole_or_refused :: proc(t: ^testing.T) {
	file := test_file(test_file_parts())
	one := [16]u8{1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0}
	two := [32]u8{}
	for &value, index in two {
		value = u8(100 + index)
	}
	into: [48]u8
	untouched :: proc(t: ^testing.T, into: []u8) {
		for value in into {
			if value != 0 {
				testing.expect(t, false, "a refused sum wrote a byte")
				return
			}
		}
	}
	written, refusal := table_sum(file, 0, one[:], file, COUNTED, two[:], into[:])
	testing.expect(t, written == 0 && refusal == .No_Description)
	written, refusal = table_sum(file, COUNTED, one[:], file, 3, two[:], into[:])
	testing.expect(t, written == 0 && refusal == .No_Description)
	written, refusal = table_sum(nil, COUNTED, one[:], file, COUNTED, two[:], into[:])
	testing.expect(t, written == 0 && refusal == .No_Description)
	written, refusal = table_sum(file, COUNTED, one[:], file, OTHER, two[:], into[:])
	testing.expect(t, written == 0 && refusal == .Different_Records)
	written, refusal = table_sum(file, COUNTED, one[:15], file, COUNTED, two[:], into[:])
	testing.expect(t, written == 0 && refusal == .Not_Whole_Rows)
	written, refusal = table_sum(file, COUNTED, one[:], file, COUNTED, two[:17], into[:])
	testing.expect(t, written == 0 && refusal == .Not_Whole_Rows)
	written, refusal = table_sum(file, COUNTED, one[:], file, COUNTED, two[:], into[:47])
	testing.expect(t, written == 0 && refusal == .Too_Large)
	untouched(t, into[:])

	written, refusal = table_sum(file, COUNTED, nil, file, COUNTED, nil, into[:0])
	testing.expect(t, written == 0 && refusal == .None)
	written, refusal = table_sum(file, COUNTED, one[:], file, COUNTED, two[:], into[:])
	testing.expect(t, written == 48 && refusal == .None)
	testing.expect(t, into[0] == 1 && into[8] == 2 && into[16] == 100 && into[47] == 131)
}

// Each refusal of a sum has its sentence, and the sentence of a command
// that needs a Table names the two ways to make one.
@(test)
the_refusals_have_their_sentences :: proc(t: ^testing.T) {
	buffer: [256]u8
	writer := sentence.Writer{buffer = buffer[:]}
	sum_refusal_write(&writer, .Different_Records, "Counted", "Other", 0)
	testing.expect_value(t, sentence.written(&writer), "\"+\" joins two tables of one record: the left one has records Counted, the right one Other")
	writer = {buffer = buffer[:]}
	sum_refusal_write(&writer, .Too_Large, "", "", 4096)
	testing.expect_value(t, sentence.written(&writer), "\"+\": the rows of the two tables do not fit the 4096 bytes that the line has left")
	writer = {buffer = buffer[:]}
	sum_refusal_write(&writer, .None, "", "", 0)
	testing.expect_value(t, sentence.written(&writer), "")
	writer = {buffer = buffer[:]}
	table_needed_write(&writer, "sort")
	testing.expect_value(t, sentence.written(&writer), "sort takes a Table; a Stream has no end: first(s, n) or table(s) makes one")
	writer = {buffer = buffer[:]}
	table_too_large_write(&writer, 2048, 32768)
	testing.expect_value(t, sentence.written(&writer), "table: the stream gave 2048 rows and no end, and the line holds 32768 bytes of rows; first(s, n) keeps the first rows")
}
