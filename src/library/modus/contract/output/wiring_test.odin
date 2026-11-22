#+build !freestanding
package output

import "core:testing"
import "modus:contract/errors"
import "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/value_kinds"

// A command of the wiring ring that the border takes: a writer end of the
// record output 1, the pace Writer_Chooses.
@(private = "file")
writer_command :: proc() -> ring.Record {
	return given_end_record({command = .Writer_End, tag = 7, ring = 21, index = 1, pace = .Writer_Chooses, end_words = 24})
}

// A reader end of the record input 1, with no terms.
@(private = "file")
reader_command :: proc() -> ring.Record {
	return given_end_record({command = .Reader_End, tag = 8, ring = 22, index = 1, description = 23, end_words = 25})
}

// The end of the asker: an index, terms or a pace beside it are refused,
// as the asker declares no record input; the end that the border takes
// comes back as it was, last.
@(test)
an_asker_end_names_no_record_input :: proc(t: ^testing.T) {
	asker := given_end_record({command = .Asker_End, tag = 9, ring = 26, description = 27, end_words = 28})
	for word in ([?]u64{1, module.RECORD_STREAM_INDEX_MOST, max(u64)}) {
		record := asker
		record.values[WIRING_VALUE_INDEX] = word
		expect_end_refused(t, record, WIRING_VALUE_INDEX + 1, i64(min(word, 1 << 62)), 0)
	}
	terms := asker
	terms.values[WIRING_VALUE_TERMS] = 1
	expect_end_refused(t, terms, WIRING_VALUE_TERMS + 1, 1, 0)
	pace := asker
	pace.values[WIRING_VALUE_PACE] = 1
	expect_end_refused(t, pace, WIRING_VALUE_PACE + 1, 1, 0)
	taken, _, ok := given_end_of_record(asker)
	testing.expect(t, ok)
	testing.expect_value(t, taken, Given_End{command = .Asker_End, tag = 9, ring = 26, description = 27, end_words = 28})
}

// The end page: each end with none, or with a word past 32 bits, is
// refused, as it would never read the end of its wiring.
@(test)
an_end_with_no_end_page_is_refused :: proc(t: ^testing.T) {
	for command in ([?]ring.Record{writer_command(), reader_command()}) {
		for word in ([?]u64{0, u64(max(u32)) + 1, max(u64)}) {
			record := command
			record.values[WIRING_VALUE_END_WORDS] = word
			expect_end_refused(t, record, WIRING_VALUE_END_WORDS + 1, i64(min(word, 1 << 62)), i64(max(u32)))
		}
	}
}

// expect_end_refused gives a command to the border, and checks that it is
// refused with Bad_Value, the argument and the value that the record
// names, and that it gives no end.
@(private = "file")
expect_end_refused :: proc(t: ^testing.T, record: ring.Record, argument: i64, value: i64, limit: i64, loc := #caller_location) {
	end, refusal, ok := given_end_of_record(record)
	testing.expectf(t, !ok, "the command %v is taken", record, loc = loc)
	testing.expectf(t, end == Given_End{}, "a refused command gives the end %v", end, loc = loc)
	expected := errors.error_make(.Bad_Value, .None, argument, value, limit)
	testing.expectf(t, refusal == expected, "the refusal is %v, not %v", refusal, expected, loc = loc)
}

// The kind of a command: 0 names no command, one past the last member and
// the largest word name none.
@(test)
a_command_whose_kind_names_no_member_is_refused :: proc(t: ^testing.T) {
	largest := i64(max(Wiring_Command))
	words := [?]u32{u32(Wiring_Command.None), u32(max(Wiring_Command)) + 1, max(u32)}
	for word in words {
		record := writer_command()
		record.kind = word
		expect_end_refused(t, record, 0, i64(word), largest)
	}
}

// The handle of the output ring: 0 names no handle, and a word past 32 bits
// is no handle, for each kind of end.
@(test)
a_ring_handle_of_zero_or_past_32_bits_is_refused :: proc(t: ^testing.T) {
	words := [?]u64{0, u64(max(u32)) + 1, max(u64)}
	for command in ([?]ring.Record{writer_command(), reader_command()}) {
		for word in words {
			record := command
			record.values[WIRING_VALUE_RING] = word
			expect_end_refused(t, record, WIRING_VALUE_RING + 1, i64(min(word, 1 << 62)), i64(max(u32)))
		}
	}
}

// The index of the record output or the record input: 0 names no row, and
// a row past the 16 bits of a wiring names none.
@(test)
an_index_of_zero_or_past_the_most_is_refused :: proc(t: ^testing.T) {
	words := [?]u64{0, module.RECORD_STREAM_INDEX_MOST + 1, max(u64)}
	for command in ([?]ring.Record{writer_command(), reader_command()}) {
		for word in words {
			record := command
			record.values[WIRING_VALUE_INDEX] = word
			expect_end_refused(t, record, WIRING_VALUE_INDEX + 1, i64(min(word, 1 << 62)), module.RECORD_STREAM_INDEX_MOST)
		}
	}
}

// The pace of a writer end: one past the last member and the largest word
// name none. Its condition page is a handle: past 32 bits it is refused,
// and a page of a handle is taken. The last word of a writer end is its
// pair, a number of a wiring of 32 bits: past 32 bits it is refused, and
// 1 and the largest word of 32 bits come back as they went.
@(test)
a_writer_end_with_an_unknown_pace_or_a_wrong_condition_is_refused :: proc(t: ^testing.T) {
	paces := [?]u64{u64(max(Wiring_Pace)) + 1, max(u64)}
	for word in paces {
		record := writer_command()
		record.values[WIRING_VALUE_PACE] = word
		expect_end_refused(t, record, WIRING_VALUE_PACE + 1, i64(min(word, 1 << 62)), i64(max(Wiring_Pace)))
	}
	for word in ([?]u64{u64(max(u32)) + 1, max(u64)}) {
		record := writer_command()
		record.values[WIRING_VALUE_TERMS] = word
		expect_end_refused(t, record, WIRING_VALUE_TERMS + 1, i64(min(word, 1 << 62)), i64(max(u32)))
	}
	for word in ([?]u64{u64(max(u32)) + 1, max(u64)}) {
		record := writer_command()
		record.values[WIRING_VALUE_PAIR] = word
		expect_end_refused(t, record, WIRING_VALUE_PAIR + 1, i64(min(word, 1 << 62)), i64(max(u32)))
	}
	for word in ([?]u64{1, u64(max(u32))}) {
		record := writer_command()
		record.values[WIRING_VALUE_PAIR] = word
		taken, _, ok := given_end_of_record(record)
		testing.expect(t, ok && taken.pair == u32(word) && taken.filter == .None)
		testing.expect_value(t, given_end_record(taken), record)
	}
	with_condition := writer_command()
	with_condition.values[WIRING_VALUE_TERMS] = u64(max(u32))
	taken, _, ok := given_end_of_record(with_condition)
	testing.expect(t, ok && taken.condition == op.Handle(max(u32)) && taken.filter == .None)
}

// A reader end has no pace: the word is 0, so a pace word of a member is
// refused too. Its terms handle is a handle: past 32 bits it is refused.
@(test)
a_reader_end_with_a_pace_or_terms_past_32_bits_is_refused :: proc(t: ^testing.T) {
	paces := [?]u64{u64(Wiring_Pace.Never_Holds_Writer), u64(max(Wiring_Pace)), max(u64)}
	for word in paces {
		record := reader_command()
		record.values[WIRING_VALUE_PACE] = word
		expect_end_refused(t, record, WIRING_VALUE_PACE + 1, i64(min(word, 1 << 62)), 0)
	}
	terms := [?]u64{u64(max(u32)) + 1, max(u64)}
	for word in terms {
		record := reader_command()
		record.values[WIRING_VALUE_TERMS] = word
		expect_end_refused(t, record, WIRING_VALUE_TERMS + 1, i64(min(word, 1 << 62)), i64(max(u32)))
	}
}

// The description file: a reader end with none, or with a word past 32
// bits, is refused, as it cannot check a record; a writer end with one is
// refused, as it reads no record.
@(test)
a_description_file_belongs_to_a_reader_end_only :: proc(t: ^testing.T) {
	for word in ([?]u64{0, u64(max(u32)) + 1, max(u64)}) {
		record := reader_command()
		record.values[WIRING_VALUE_DESCRIPTION] = word
		expect_end_refused(t, record, WIRING_VALUE_DESCRIPTION + 1, i64(min(word, 1 << 62)), i64(max(u32)))
	}
	for word in ([?]u64{1, max(u64)}) {
		record := writer_command()
		record.values[WIRING_VALUE_DESCRIPTION] = word
		expect_end_refused(t, record, WIRING_VALUE_DESCRIPTION + 1, i64(min(word, 1 << 62)), 0)
	}
}

// The filter word of a reader end and of an asker end: one past the last
// member and the largest word name none. Then By_Writer, which the border
// gives back.
@(test)
a_filter_word_that_names_no_member_is_refused :: proc(t: ^testing.T) {
	asker := given_end_record({command = .Asker_End, tag = 9, ring = 26, description = 27, end_words = 28})
	for command in ([?]ring.Record{reader_command(), asker}) {
		for word in ([?]u64{u64(max(Reader_Filter)) + 1, max(u64)}) {
			record := command
			record.values[WIRING_VALUE_FILTER] = word
			expect_end_refused(t, record, WIRING_VALUE_FILTER + 1, i64(min(word, 1 << 62)), i64(max(Reader_Filter)))
		}
		filtered := command
		filtered.values[WIRING_VALUE_FILTER] = u64(Reader_Filter.By_Writer)
		taken, _, ok := given_end_of_record(filtered)
		testing.expect(t, ok && taken.filter == .By_Writer)
		testing.expect_value(t, given_end_record(taken), filtered)
	}
}

// The ends that the border takes, last: the edges of the handle and of
// the index, each pace, and a reader end with and with no terms. Each one
// comes back from given_end_record as it was.
@(test)
the_border_takes_each_valid_end_back_as_it_was :: proc(t: ^testing.T) {
	ends := make([dynamic]Given_End, context.temp_allocator)
	for pace in Wiring_Pace {
		append(&ends, Given_End{command = .Writer_End, tag = 1, ring = 1, index = 1, pace = pace, end_words = 1})
	}
	append(&ends, Given_End{command = .Writer_End, tag = max(u32), ring = op.Handle(max(u32)), index = module.RECORD_STREAM_INDEX_MOST, pace = .Always_Holds_Writer, end_words = op.Handle(max(u32))})
	append(&ends, Given_End{command = .Reader_End, tag = 0, ring = 1, index = 1, description = 1, end_words = 1})
	append(&ends, Given_End{command = .Reader_End, tag = 3, ring = op.Handle(max(u32)), index = module.RECORD_STREAM_INDEX_MOST, terms = op.Handle(max(u32)), description = op.Handle(max(u32)), end_words = op.Handle(max(u32))})
	append(&ends, Given_End{command = .Reader_End, tag = 4, ring = 9, index = 2, terms = 1, description = 2, end_words = 3})
	for end in ends {
		record := given_end_record(end)
		taken, refusal, ok := given_end_of_record(record)
		testing.expectf(t, ok, "the end %v is refused: %v", end, refusal)
		testing.expect_value(t, taken, end)
		testing.expect_value(t, refusal, errors.Error_Record{})
	}
}

// The completion of the wiring ring: a status word that names no member is
// refused; an Ok whose answer word names no Wiring_Answer (one past the
// last, the largest word); an Ok with any other value that is not 0, the
// answer Closed among them.
@(test)
a_completion_with_an_unknown_status_or_an_ok_with_values_is_refused :: proc(t: ^testing.T) {
	words := [?]u32{u32(max(op.Status)) + 1, max(u32)}
	for word in words {
		_, _, _, _, ok := wiring_completion_of_record({kind = word, tag = 1})
		testing.expectf(t, !ok, "the status word %d is taken", word)
	}
	for answer in ([?]u64{u64(max(Wiring_Answer)) + 1, max(u64)}) {
		record := wiring_completion(5, .Ok)
		record.values[WIRING_ANSWER_VALUE] = answer
		_, _, _, _, ok := wiring_completion_of_record(record)
		testing.expectf(t, !ok, "the answer word %d is taken", answer)
	}
	for base in ([?]ring.Record{wiring_completion(5, .Ok), wiring_closed_completion(5)}) {
		for index in WIRING_ANSWER_VALUE + 1 ..< 7 {
			record := base
			record.values[index] = 1
			_, _, _, _, ok := wiring_completion_of_record(record)
			testing.expectf(t, !ok, "an Ok with the value %d is taken", index)
		}
	}
}

// The completions that the border takes, last: Ok with the answer Taken,
// the word Closed, and a refusal with its error record and the tag of its
// command.
@(test)
a_completion_comes_back_with_its_status_its_tag_and_its_record :: proc(t: ^testing.T) {
	status, tag, answer, refusal, ok := wiring_completion_of_record(wiring_completion(max(u32), .Ok))
	testing.expect(t, ok)
	testing.expect_value(t, status, op.Status.Ok)
	testing.expect_value(t, tag, max(u32))
	testing.expect_value(t, answer, Wiring_Answer.Taken)
	testing.expect_value(t, refusal, errors.Error_Record{})

	status, tag, answer, refusal, ok = wiring_completion_of_record(wiring_closed_completion(7))
	testing.expect(t, ok)
	testing.expect_value(t, status, op.Status.Ok)
	testing.expect_value(t, tag, 7)
	testing.expect_value(t, answer, Wiring_Answer.Closed)
	testing.expect_value(t, refusal, errors.Error_Record{})

	refused := errors.error_make(.Bad_Value, .None, WIRING_VALUE_INDEX + 1, 9, 2)
	status, tag, answer, refusal, ok = wiring_completion_of_record(wiring_completion(6, .Bad_Operation, refused))
	testing.expect(t, ok)
	testing.expect_value(t, status, op.Status.Bad_Operation)
	testing.expect_value(t, tag, 6)
	testing.expect_value(t, refusal, refused)
}

// The capacity of a wiring ring: one past the largest ring and the largest
// count are refused; 0, 1 and the smallest capacity give the smallest ring,
// one more the next power of two, and the largest ring holds its capacity.
@(test)
the_capacity_of_a_wiring_ring_holds_the_ends_of_a_start :: proc(t: ^testing.T) {
	for count in ([?]u64{ring.CAPACITY_LIMIT + 1, max(u64)}) {
		_, ok := wiring_ring_capacity(count)
		testing.expectf(t, !ok, "a wiring ring holds %d ends", count)
	}
	Case :: struct {
		ends:     u64,
		capacity: u32,
	}
	cases := [?]Case {
		{0, WIRING_RING_CAPACITY},
		{1, WIRING_RING_CAPACITY},
		{WIRING_RING_CAPACITY, WIRING_RING_CAPACITY},
		{WIRING_RING_CAPACITY + 1, 2 * WIRING_RING_CAPACITY},
		{ring.CAPACITY_LIMIT, ring.CAPACITY_LIMIT},
	}
	for item in cases {
		capacity, ok := wiring_ring_capacity(item.ends)
		testing.expectf(t, ok && capacity == item.capacity, "%d ends give %d, not %d", item.ends, capacity, item.capacity)
	}
	testing.expect_value(t, ring.pages(WIRING_RING_CAPACITY), u64(WIRING_RING_PAGES))
}

// One field of a record of the type check, with its bytes in order: the
// builder places each field after the one before it. The tests of the
// description file use it too.
Test_Field :: struct {
	name:          string,
	type:          module.Type,
	unsigned:      bool,
	detail:        u32,
	integer_unit:  value_kinds.Integer_Unit,
	kind:          value_kinds.Field_Kind,
	contract_enum: value_kinds.Contract_Enum,
}

// typed_file gives a module file with one record, at the index 1, whose
// fields follow each other from its first byte.
typed_file :: proc(name: string, fields: []Test_Field) -> []u8 {
	strings_bytes := make([dynamic]u8, context.temp_allocator)
	append(&strings_bytes, 0)
	name_add :: proc(table: ^[dynamic]u8, text: string) -> (offset, count: u32) {
		offset = u32(len(table))
		append(table, text)
		return offset, u32(len(text))
	}
	records: [2]module.Record
	records[1].name_offset, records[1].name_count = name_add(&strings_bytes, name)
	described := make([]module.Field, len(fields) + 1, context.temp_allocator)
	offset: u32 = 0
	for item, number in fields {
		field := module.Field{offset = offset, type = u8(item.type), unsigned = item.unsigned, detail = item.detail, integer_unit = item.integer_unit, kind = u8(item.kind), contract_enum = u8(item.contract_enum)}
		field.name_offset, field.name_count = name_add(&strings_bytes, item.name)
		described[number + 1] = field
		offset += module.field_size(field)
	}
	records[1].size, records[1].first_field, records[1].field_count = offset, 1, u32(len(fields))

	bytes := make([dynamic]u8, size_of(module.Header) + module.TABLE_COUNT * size_of(module.Table_Entry), context.temp_allocator)
	directory: [module.TABLE_COUNT]module.Table_Entry
	add :: proc(file: ^[dynamic]u8, directory: ^[module.TABLE_COUNT]module.Table_Entry, kind: module.Table_Kind, data: []u8, count, record_size: u32) {
		for len(file) % 8 != 0 {
			append(file, 0)
		}
		directory[kind] = {offset = u64(len(file)), count = count, record_size = record_size}
		append(file, ..data)
	}
	add(&bytes, &directory, .Records, ([^]u8)(&records)[:size_of(records)], len(records), size_of(module.Record))
	add(&bytes, &directory, .Fields, ([^]u8)(raw_data(described))[:len(described) * size_of(module.Field)], u32(len(described)), size_of(module.Field))
	add(&bytes, &directory, .Strings, strings_bytes[:], u32(len(strings_bytes)), 1)
	(^module.Header)(&bytes[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^[module.TABLE_COUNT]module.Table_Entry)(&bytes[size_of(module.Header)])^ = directory
	return bytes[:]
}

// The fields of the record of the type check: a count of bytes, a level of
// the log, and a name. Each test changes one property of one field.
@(private = "file")
probe_fields :: proc() -> [3]Test_Field {
	return {
		{name = "bytes", type = .Integer, unsigned = true, integer_unit = value_kinds.size_in(.Bytes)},
		{name = "level", type = .Integer, unsigned = true, detail = 1, kind = .Status, contract_enum = .Log_Level},
		{name = "name", type = .Text, detail = 7},
	}
}

@(private = "file")
probe_file :: proc(fields: [3]Test_Field, name: string = "Probe") -> []u8 {
	copied := fields
	return typed_file(name, copied[:])
}

@(private = "file")
expect_difference :: proc(t: ^testing.T, file: []u8, index: u32, other_file: []u8, other_index: u32, difference: Description_Difference, part: u32, loc := #caller_location) {
	given, given_part := record_descriptions_compare(file, index, other_file, other_index)
	testing.expectf(t, given == difference && given_part == part, "the difference is %v at %d, not %v at %d", given, given_part, difference, part, loc = loc)
	// The check reads in both directions alike.
	back, back_part := record_descriptions_compare(other_file, other_index, file, index)
	testing.expectf(t, back == difference && back_part == part, "the difference back is %v at %d, not %v at %d", back, back_part, difference, part, loc = loc)
}

// The access record of `server`, as its writer and the readers of its
// test declare it: status, answer_size, answer_time, method, target, peer.
@(private = "file")
access_fields :: proc() -> [6]Test_Field {
	return {
		{name = "status", type = .Integer, unsigned = true},
		{name = "answer_size", type = .Integer, integer_unit = value_kinds.size_in(.Bytes)},
		{name = "answer_time", type = .Integer, integer_unit = value_kinds.time_in(.Microseconds)},
		{name = "method", type = .Text, detail = 8},
		{name = "target", type = .Text, detail = 56},
		{name = "peer", type = .Text, detail = 32},
	}
}

// A reader whose copy of the access record of `server` changed one field
// is refused at the wiring, with the unit Record_Types and the number of
// that field: a unit of time in place of a unit of size, a field renamed,
// a signed status, and a target cut by 8 bytes with a peer longer by 8,
// which keep the size. The copy as the writer declares it is equal.
@(test)
a_copy_of_the_access_record_with_one_field_changed_is_refused :: proc(t: ^testing.T) {
	writer := access_fields()
	writer_file := typed_file("Access_Record", writer[:])

	timed_size := access_fields()
	timed_size[1].integer_unit = value_kinds.time_in(.Microseconds)
	expect_difference(t, writer_file, 1, typed_file("Access_Record", timed_size[:]), 1, .Field, 2)

	renamed := access_fields()
	renamed[4].name = "path"
	expect_difference(t, writer_file, 1, typed_file("Access_Record", renamed[:]), 1, .Field, 5)

	signed := access_fields()
	signed[0].unsigned = false
	expect_difference(t, writer_file, 1, typed_file("Access_Record", signed[:]), 1, .Field, 1)

	moved := access_fields()
	moved[4].detail -= 8
	moved[5].detail += 8
	expect_difference(t, writer_file, 1, typed_file("Access_Record", moved[:]), 1, .Field, 5)

	same := access_fields()
	expect_difference(t, writer_file, 1, typed_file("Access_Record", same[:]), 1, .Equal, 0)
}

// A description that a reader cannot take is never compared: the index 0
// (a generic end whose type no wiring fixed), an index past the table, and
// a record with a Handle field, even beside itself.
@(test)
a_description_that_no_reader_takes_is_not_compared :: proc(t: ^testing.T) {
	probe := probe_file(probe_fields())
	expect_difference(t, probe, 0, probe, 1, .Not_Described, 0)
	expect_difference(t, probe, 2, probe, 1, .Not_Described, 0)
	expect_difference(t, probe, max(u32), probe, 1, .Not_Described, 0)
	with_handle := typed_file("Probe", []Test_Field{{name = "handle", type = .Handle}, {name = "rest", type = .Integer, detail = 4}})
	expect_difference(t, with_handle, 1, with_handle, 1, .Not_Described, 0)
	expect_difference(t, with_handle, 1, probe, 1, .Not_Described, 0)
}

// The record as a whole: another name, another size, another count of
// fields with the same size.
@(test)
a_record_with_another_name_size_or_count_differs_as_a_whole :: proc(t: ^testing.T) {
	probe := probe_file(probe_fields())
	expect_difference(t, probe, 1, probe_file(probe_fields(), "Probe_Two"), 1, .Name, 0)
	// A name of 8 bytes more keeps the size a multiple of the alignment.
	longer := probe_fields()
	longer[2].detail += 8
	expect_difference(t, probe, 1, probe_file(longer), 1, .Size, 0)
	// Two fields of 4 bytes in place of the first field of 8: the same size.
	base := probe_fields()
	split := typed_file("Probe", []Test_Field{{name = "bytes", type = .Integer, unsigned = true, detail = 4}, {name = "more", type = .Integer, unsigned = true, detail = 4}, base[1], base[2]})
	expect_difference(t, probe, 1, split, 1, .Field_Count, 0)
}

// Each property of a field, changed alone, gives the number of that field.
@(test)
each_property_of_a_field_is_part_of_the_type :: proc(t: ^testing.T) {
	probe := probe_file(probe_fields())

	renamed := probe_fields()
	renamed[1].name = "levels"
	expect_difference(t, probe, 1, probe_file(renamed), 1, .Field, 2)

	signed := probe_fields()
	signed[0].unsigned = false
	expect_difference(t, probe, 1, probe_file(signed), 1, .Field, 1)

	timed := probe_fields()
	timed[0].integer_unit = value_kinds.time_in(.Milliseconds)
	expect_difference(t, probe, 1, probe_file(timed), 1, .Field, 1)

	plain := probe_fields()
	plain[1].kind, plain[1].contract_enum = .Plain, .None
	expect_difference(t, probe, 1, probe_file(plain), 1, .Field, 2)

	hexadecimal := probe_fields()
	hexadecimal[0].integer_unit, hexadecimal[0].kind = {}, .Hexadecimal
	expect_difference(t, probe, 1, probe_file(hexadecimal), 1, .Field, 1)

	// Another enum of the contract: the reader would check its members.
	other_enum := probe_fields()
	other_enum[1].contract_enum = .Status
	expect_difference(t, probe, 1, probe_file(other_enum), 1, .Field, 2)

	// Bytes of 7 in place of a Text of 7: the same size, another type.
	hashed := probe_fields()
	hashed[2].type, hashed[2].kind = .Bytes, .Hash
	expect_difference(t, probe, 1, probe_file(hashed), 1, .Field, 3)

	// The same sizes in another order: the first field that differs is 1.
	reordered := typed_file("Probe", []Test_Field{{name = "first", type = .Integer, unsigned = true, detail = 4}, {name = "second", type = .Integer, unsigned = true, detail = 2}, {name = "third", type = .Integer, unsigned = true, detail = 2}})
	in_order := typed_file("Probe", []Test_Field{{name = "first", type = .Integer, unsigned = true, detail = 2}, {name = "second", type = .Integer, unsigned = true, detail = 2}, {name = "third", type = .Integer, unsigned = true, detail = 4}})
	expect_difference(t, reordered, 1, in_order, 1, .Field, 1)
}

// Equal descriptions, last: a record beside itself, and the same record
// described in two files.
@(test)
equal_descriptions_pass_the_type_check :: proc(t: ^testing.T) {
	probe := probe_file(probe_fields())
	expect_difference(t, probe, 1, probe, 1, .Equal, 0)
	expect_difference(t, probe, 1, probe_file(probe_fields()), 1, .Equal, 0)
}
