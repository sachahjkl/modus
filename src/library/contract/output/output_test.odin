#+build !freestanding
package output

import "core:testing"
import "modus:contract/errors"
import "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/value_kinds"

// The record of these tests, 64 bytes, each byte of one field: `value`, an
// unsigned Integer of 8 bytes; `level`, an unsigned Integer of 1 byte of
// the kind Status of the contract enum Log_Level; `name`, a Text of 55
// bytes. Its place has 128 bytes, so each kind has bytes past what it
// names.
@(private = "file")
RECORD_SIZE :: 64
@(private = "file")
NAME_OFFSET :: 9
@(private = "file")
NAME_SIZE :: RECORD_SIZE - NAME_OFFSET
@(private = "file")
LEVEL_OFFSET :: 8
@(private = "file")
FIELD_COUNT :: 3
@(private = "file")
TEST_PLACE_SIZE :: 128

// test_file gives a module file with the record of these tests at the
// index 1, and its description.
@(private = "file")
test_file :: proc() -> (file: []u8, description: module.Record) {
	strings_bytes := make([dynamic]u8, context.temp_allocator)
	append(&strings_bytes, 0)
	name_add :: proc(table: ^[dynamic]u8, text: string) -> (offset, count: u32) {
		offset = u32(len(table))
		append(table, text)
		return offset, u32(len(text))
	}
	records: [2]module.Record
	records[1].name_offset, records[1].name_count = name_add(&strings_bytes, "Probe")
	records[1].size, records[1].first_field, records[1].field_count = RECORD_SIZE, 1, FIELD_COUNT
	fields: [FIELD_COUNT + 1]module.Field
	fields[1] = {offset = 0, type = u8(module.Type.Integer), unsigned = true}
	fields[1].name_offset, fields[1].name_count = name_add(&strings_bytes, "value")
	fields[2] = {offset = LEVEL_OFFSET, type = u8(module.Type.Integer), unsigned = true, detail = 1, kind = u8(value_kinds.Field_Kind.Status), contract_enum = u8(value_kinds.Contract_Enum.Log_Level)}
	fields[2].name_offset, fields[2].name_count = name_add(&strings_bytes, "level")
	fields[3] = {offset = NAME_OFFSET, type = u8(module.Type.Text), detail = NAME_SIZE}
	fields[3].name_offset, fields[3].name_count = name_add(&strings_bytes, "name")

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
	add(&bytes, &directory, .Fields, ([^]u8)(&fields)[:size_of(fields)], len(fields), size_of(module.Field))
	add(&bytes, &directory, .Strings, strings_bytes[:], u32(len(strings_bytes)), 1)
	(^module.Header)(&bytes[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^[module.TABLE_COUNT]module.Table_Entry)(&bytes[size_of(module.Header)])^ = directory
	file = bytes[:]
	ok: bool
	description, ok = module.record_stream_type(file, 1)
	assert(ok, "the record of the tests is a record of a record stream")
	return file, description
}

@(private = "file")
new_place :: proc() -> []u8 {
	return make([]u8, TEST_PLACE_SIZE, context.temp_allocator)
}

// A record place of these tests: value, the level Info, and a name.
@(private = "file")
probe_place :: proc(serial: u32, name: string = "probe") -> []u8 {
	record: [RECORD_SIZE]u8
	record[0] = u8(serial)
	copy(record[NAME_OFFSET:], name)
	place := new_place()
	assert(record_place(place, serial, record[:]))
	return place
}

@(private = "file")
joined_at :: proc(serial: u32) -> []u8 {
	place := new_place()
	assert(joined_place(place, serial))
	return place
}

// expect_refused gives a place to the border, and checks its fault, the
// value and the part of its error record, and that the state did not
// change.
@(private = "file")
expect_refused :: proc(t: ^testing.T, state: ^Read_State, place: []u8, file: []u8, description: module.Record, fault: Place_Fault, value: i64, found: i64, loc := #caller_location) {
	before := state^
	_, given, refusal := record_of_place(state, place, file, description)
	testing.expectf(t, given == fault, "the fault is %v, not %v", given, fault, loc = loc)
	testing.expectf(t, refusal.value == value && refusal.found == found && refusal.kind != 0, "the refusal is %v, not the value %d and the part %d", refusal, value, found, loc = loc)
	testing.expectf(t, state^ == before, "the state changed: %v, before %v", state^, before, loc = loc)
}

// The sizes of a place: the place word and the record, rounded up to 64,
// and none past the largest record.
@(test)
the_size_of_a_place_is_the_word_and_the_record_rounded_up :: proc(t: ^testing.T) {
	testing.expect_value(t, place_size(0), 64)
	testing.expect_value(t, place_size(56), 64)
	testing.expect_value(t, place_size(57), 128)
	testing.expect_value(t, place_size(72), 128)
	testing.expect_value(t, place_size(module.RECORD_SIZE_LIMIT), 320)
	testing.expect_value(t, place_size(module.RECORD_SIZE_LIMIT + 1), 0)
	testing.expect_value(t, place_size(max(u32)), 0)
	testing.expect(t, ring.place_size_valid(place_size(module.RECORD_SIZE_LIMIT)))
}

// The first place of a ring: a place of another size, a kind that names no
// member, and each place that is not a joined record are refused, with
// nothing changed; a joined record with a byte past its word too.
@(test)
the_first_place_must_be_a_joined_record :: proc(t: ^testing.T) {
	file, description := test_file()
	state: Read_State
	for size in ([?]int{0, 1, TEST_PLACE_SIZE - 1, TEST_PLACE_SIZE + 1}) {
		expect_refused(t, &state, make([]u8, size, context.temp_allocator), file, description, .Wrong_Size, i64(size), 0)
	}
	unknown := joined_at(0)
	unknown[0] = u8(max(Place_Kind)) + 1
	expect_refused(t, &state, unknown, file, description, .Unknown_Kind, i64(max(Place_Kind)) + 1, 0)
	largest := joined_at(0)
	largest[0], largest[1], largest[2], largest[3] = 0xFF, 0xFF, 0xFF, 0xFF
	expect_refused(t, &state, largest, file, description, .Unknown_Kind, i64(max(u32)), 0)
	// A record, a gap and an end first. The zero place is a record of serial 0.
	expect_refused(t, &state, new_place(), file, description, .Not_Joined_First, i64(Place_Kind.Record), 0)
	gap := new_place()
	gap_place(gap, 0, 1)
	expect_refused(t, &state, gap, file, description, .Not_Joined_First, i64(Place_Kind.Gap), 0)
	end := new_place()
	end_place(end, 0, {})
	expect_refused(t, &state, end, file, description, .Not_Joined_First, i64(Place_Kind.End), 0)
	// A joined record with a byte past its word: the first, and the last.
	for at in ([?]int{PLACE_WORD_SIZE, TEST_PLACE_SIZE - 1}) {
		dirty := joined_at(0)
		dirty[at] = 1
		expect_refused(t, &state, dirty, file, description, .Unnamed_Byte, i64(at), 0)
	}
	// The joined record of 0, then of N past any capacity of a ring.
	taken, fault, _ := record_of_place(&state, joined_at(0), file, description)
	testing.expect(t, fault == .None && taken.kind == .Joined && taken.serial == 0 && state.joined && state.next_serial == 0)
	later: Read_State
	_, later_fault, _ := record_of_place(&later, joined_at(5000), file, description)
	testing.expect(t, later_fault == .None && later.next_serial == 5000)
	first, first_fault, _ := record_of_place(&later, probe_place(5000), file, description)
	testing.expect(t, first_fault == .None && first.serial == 5000 && later.next_serial == 5001)
}

// After the joined record: a second joined record, a serial before, after
// and far from the next one, a gap of no record, bytes past what each kind
// names, a bad Text and a bad Status are refused with nothing changed; any
// place after the end record is refused.
@(test)
a_damaged_place_is_refused_and_changes_nothing :: proc(t: ^testing.T) {
	file, description := test_file()
	state: Read_State
	_, joined_fault, _ := record_of_place(&state, joined_at(5), file, description)
	testing.expect_value(t, joined_fault, Place_Fault.None)
	expect_refused(t, &state, joined_at(5), file, description, .Joined_Again, i64(Place_Kind.Joined), 0)
	for serial in ([?]u32{0, 4, 6, max(u32)}) {
		expect_refused(t, &state, probe_place(serial), file, description, .Wrong_Serial, i64(serial), 0)
	}
	empty_gap := new_place()
	testing.expect(t, !gap_place(empty_gap, 5, 0))
	empty_gap[0] = u8(Place_Kind.Gap)
	empty_gap[4] = 5
	expect_refused(t, &state, empty_gap, file, description, .Empty_Gap, 0, 0)
	dirty_gap := new_place()
	gap_place(dirty_gap, 5, 2)
	dirty_gap[GAP_COUNT_OFFSET + 4] = 1
	expect_refused(t, &state, dirty_gap, file, description, .Unnamed_Byte, GAP_COUNT_OFFSET + 4, 0)
	dirty_end := new_place()
	end_place(dirty_end, 5, {})
	dirty_end[TEST_PLACE_SIZE - 1] = 1
	expect_refused(t, &state, dirty_end, file, description, .Unnamed_Byte, TEST_PLACE_SIZE - 1, 0)
	// A record with a byte past the record, in its place.
	for at in ([?]int{PLACE_WORD_SIZE + RECORD_SIZE, TEST_PLACE_SIZE - 1}) {
		dirty := probe_place(5)
		dirty[at] = 1
		expect_refused(t, &state, dirty, file, description, .Unnamed_Byte, i64(at), FIELD_COUNT + 1)
	}
	// The Text field: a control character, a byte that starts no
	// character, a cut character at its end, and a byte after its first
	// zero byte, at the start and at the end of the field.
	name_part := i64(3)
	expect_refused(t, &state, probe_place(5, "a\nb"), file, description, .Bad_Text, 1, name_part)
	expect_refused(t, &state, probe_place(5, "\xff"), file, description, .Bad_Text, 0, name_part)
	expect_refused(t, &state, probe_place(5, "ab\xc3"), file, description, .Bad_Text, 2, name_part)
	after_zero := probe_place(5, "ab")
	after_zero[PLACE_WORD_SIZE + NAME_OFFSET + 3] = 'c'
	expect_refused(t, &state, after_zero, file, description, .Bad_Text, 3, name_part)
	last_byte := probe_place(5, "")
	last_byte[PLACE_WORD_SIZE + RECORD_SIZE - 1] = 'z'
	expect_refused(t, &state, last_byte, file, description, .Bad_Text, NAME_SIZE - 1, name_part)
	// The Status field: one past the last level, and the largest byte.
	for word in ([?]u8{u8(max(op.Log_Level)) + 1, max(u8)}) {
		bad_level := probe_place(5)
		bad_level[PLACE_WORD_SIZE + LEVEL_OFFSET] = word
		expect_refused(t, &state, bad_level, file, description, .Bad_Status, i64(word), 2)
	}
	// The end, then a place after it.
	end := new_place()
	end_place(end, 5, errors.error_make(.Refused))
	taken, end_fault, _ := record_of_place(&state, end, file, description)
	testing.expect(t, end_fault == .None && taken.kind == .End && taken.error.kind == i64(errors.Kind.Refused) && state.ended)
	expect_refused(t, &state, probe_place(5), file, description, .After_End, i64(Place_Kind.Record), 0)
	expect_refused(t, &state, joined_at(5), file, description, .After_End, i64(Place_Kind.Joined), 0)
}

// A stream as a writer writes it, last: the joined record of 0, two
// records, a gap of three, a record, a record whose name fills its field,
// the last level, the end. Then the serials across the top of their type.
@(test)
a_stream_is_taken_in_order :: proc(t: ^testing.T) {
	file, description := test_file()
	state: Read_State
	full_name: [NAME_SIZE]u8
	for &value in full_name {
		value = 'n'
	}
	error_level := probe_place(6, "error")
	error_level[PLACE_WORD_SIZE + LEVEL_OFFSET] = u8(op.Log_Level.Error)
	gap := new_place()
	testing.expect(t, gap_place(gap, 2, 3))
	end := new_place()
	testing.expect(t, end_place(end, 8, {}))
	places := [?][]u8{joined_at(0), probe_place(0), probe_place(1), gap, probe_place(5), error_level, probe_place(7, string(full_name[:])), end}
	kinds := [?]Place_Kind{.Joined, .Record, .Record, .Gap, .Record, .Record, .Record, .End}
	serials := [?]u32{0, 0, 1, 2, 5, 6, 7, 8}
	for place, index in places {
		taken, fault, refusal := record_of_place(&state, place, file, description)
		testing.expectf(t, fault == .None && taken.kind == kinds[index] && taken.serial == serials[index], "the place %d gave %v and %v: %v", index, fault, taken.kind, refusal)
		if taken.kind == .Record {
			testing.expect_value(t, len(taken.record), RECORD_SIZE)
		}
		if taken.kind == .Gap {
			testing.expect_value(t, taken.gap_count, 3)
		}
	}
	testing.expect(t, state.ended && state.next_serial == 8)
	// The serial after max(u32) is 0, and a gap across the top too.
	top: Read_State
	_, top_joined, _ := record_of_place(&top, joined_at(max(u32)), file, description)
	_, top_record, _ := record_of_place(&top, probe_place(max(u32)), file, description)
	wrap_gap := new_place()
	gap_place(wrap_gap, 0, 2)
	_, top_gap, _ := record_of_place(&top, wrap_gap, file, description)
	_, top_next, _ := record_of_place(&top, probe_place(2), file, description)
	testing.expect(t, top_joined == .None && top_record == .None && top_gap == .None && top_next == .None && top.next_serial == 3)
}

// The places that a writer writes refuse a place too small for their kind
// and a record that does not fit; each writes zero past what it names.
@(test)
the_writer_of_a_place_refuses_what_does_not_fit :: proc(t: ^testing.T) {
	small := make([]u8, PLACE_WORD_SIZE - 1, context.temp_allocator)
	testing.expect(t, !joined_place(small, 0))
	testing.expect(t, !gap_place(make([]u8, GAP_COUNT_OFFSET + 3, context.temp_allocator), 0, 1))
	testing.expect(t, !end_place(make([]u8, PLACE_ALIGNMENT - 1, context.temp_allocator), 0, {}))
	record: [RECORD_SIZE + 1]u8
	place := make([]u8, PLACE_WORD_SIZE + RECORD_SIZE, context.temp_allocator)
	testing.expect(t, !record_place(place, 0, record[:]))
	// A place written over a dirty one is zero past its word.
	for &value in place {
		value = 0xA5
	}
	testing.expect(t, joined_place(place, 9))
	for value in place[PLACE_WORD_SIZE:] {
		testing.expect_value(t, value, 0)
	}
}

// The end words: a word that names no end, one past the last and the
// largest, a stop word beside another end than Writer_Stopped, and a
// reserved word are refused. The write changes no counter of the head and
// no byte outside the end words.
@(test)
the_end_words_are_read_through_their_border :: proc(t: ^testing.T) {
	refused := [?]End_Words {
		{end = u32(max(End_Word)) + 1},
		{end = max(u32)},
		{end = u32(End_Word.Reader_Stopped), stop_cause = 1},
		{end = u32(End_Word.Revoked), stop_outcome = 1},
		{end = u32(End_Word.None), stop_cause = 1},
		{end = u32(End_Word.Asker_Stopped), reserved = {12 = 1}},
	}
	for words in refused {
		_, _, _, ok := end_of_words(words)
		testing.expectf(t, !ok, "the end words %v are taken", words)
	}
	head := new(ring.Head, context.temp_allocator)
	head.commands.write, head.commands.read, head.completions.write, head.completions.read = 3, 2, 1, 1
	end_words_write(head, .Writer_Stopped, 4, 2)
	bytes := ([^]u8)(head)[:size_of(ring.Head)]
	for value, index in bytes {
		if index >= END_WORDS_OFFSET && index < END_WORDS_OFFSET + 3 * size_of(u32) {
			continue
		}
		if index < size_of(ring.Counters) || (index >= int(offset_of(ring.Head, completions)) && index < int(offset_of(ring.Head, completions)) + size_of(ring.Counters)) {
			continue
		}
		testing.expectf(t, value == 0, "the byte %d of the head is %d", index, value)
	}
	testing.expect(t, head.commands.write == 3 && head.commands.read == 2 && head.completions.write == 1 && head.completions.read == 1)
	end, cause, outcome, ok := end_of_words(end_words_read(head))
	testing.expect(t, ok && end == .Writer_Stopped && cause == 4 && outcome == 2)
	none, _, _, none_ok := end_of_words(end_words_read(new(ring.Head, context.temp_allocator)))
	testing.expect(t, none_ok && none == .None)
}

// A completion: a kind that names no member and an End_Taken with values
// are refused; a refusal carries its serial and its error record.
@(test)
a_completion_is_read_through_its_border :: proc(t: ^testing.T) {
	for record in ([?]ring.Record{{kind = u32(max(Completion_Kind)) + 1}, {kind = max(u32)}, {kind = u32(Completion_Kind.End_Taken), values = {6 = 1}}}) {
		_, _, _, ok := completion_of_record(record)
		testing.expectf(t, !ok, "the completion %v is taken", record)
	}
	refusal := errors.error_make(.Bad_Value, .None, 0, 4, 3, 2)
	kind, serial, error, ok := completion_of_record(refusal_completion(17, refusal))
	testing.expect(t, ok && kind == .Bad_Record && serial == 17 && error == refusal)
	end_kind, end_serial, _, end_ok := completion_of_record(end_completion(9))
	testing.expect(t, end_ok && end_kind == .End_Taken && end_serial == 9)
}

// The places go through a ring of places: the writer pushes its copy, the
// reader pops its own copy and takes it through the border.
@(test)
places_go_through_a_ring_of_places :: proc(t: ^testing.T) {
	file, description := test_file()
	size := place_size(description.size)
	page_count := ring.place_pages(ring.CAPACITY, size)
	memory := make([]u8, page_count * ring.PAGE_SIZE, context.temp_allocator)
	stream, opened := ring.place_open(raw_data(memory), page_count, size)
	testing.expect(t, opened && size == TEST_PLACE_SIZE)
	if !opened {
		return
	}
	testing.expect(t, ring.place_push(&stream.commands, joined_at(0)))
	testing.expect(t, ring.place_push(&stream.commands, probe_place(0, "through the ring")))
	state: Read_State
	copy_of_place := make([]u8, size, context.temp_allocator)
	for kind in ([?]Place_Kind{.Joined, .Record}) {
		testing.expect(t, ring.place_pop(&stream.commands, copy_of_place))
		taken, fault, _ := record_of_place(&state, copy_of_place, file, description)
		testing.expect(t, fault == .None && taken.kind == kind)
		if kind == .Record {
			testing.expect_value(t, module.field_text(taken.record, module.Field{offset = NAME_OFFSET, type = u8(module.Type.Text), detail = NAME_SIZE}), "through the ring")
		}
	}
}
