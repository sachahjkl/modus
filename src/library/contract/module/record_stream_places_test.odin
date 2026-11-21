#+build !freestanding
package module

import "core:testing"

// The file of these tests: a code segment of one page, then a data
// segment of one page, two record outputs and one record input, each with
// a place in the data segment. validate reads the places only, so the rows
// hold no name.
@(private = "file")
FIRST_OUTPUT_PLACE :: u64(PAGE_SIZE + 8)
@(private = "file")
SECOND_OUTPUT_PLACE :: u64(PAGE_SIZE + 64)
@(private = "file")
INPUT_PLACE :: u64(PAGE_SIZE + 128)

// The other writes of a loader that a file of these tests holds: its
// rebase words, its import slots, its own-hash place, and the flags of its
// data segment.
@(private = "file")
Loader_Writes :: struct {
	rebases:    []u64,
	import_slots: []Import_Slot, // From index 1: the entry 0 is added.
	hash_place: u64, // 0: no table Own_Hash.
	data_flags: Segment_Flags, // {}: Read and Write.
	extra_rows: [2]int, // Rows added after the record outputs and after the record input, each with extra_place.
	extra_place: u64,
	// The added rows take distinct places in place of extra_place: from
	// EXTRA_PLACES_FIRST, one place after the other, the outputs first.
	extra_places_apart: bool,
}

// The first of the distinct places of the added rows, after the three
// places of the file.
@(private = "file")
EXTRA_PLACES_FIRST :: u64(PAGE_SIZE + 256)

@(private = "file")
places_file :: proc(output_places: [2]u64, input_place: u64, writes: Loader_Writes = {}) -> []u8 {
	bytes_of :: proc(items: []$T) -> []u8 {
		return ([^]u8)(raw_data(items))[:len(items) * size_of(T)]
	}
	file := make([dynamic]u8, size_of(Header) + TABLE_COUNT * size_of(Table_Entry), context.temp_allocator)
	directory: [TABLE_COUNT]Table_Entry
	add :: proc(file: ^[dynamic]u8, directory: ^[TABLE_COUNT]Table_Entry, kind: Table_Kind, bytes: []u8, count, record_size: u32) {
		for len(file) % 8 != 0 {
			append(file, 0)
		}
		directory[kind] = {offset = u64(len(file)), count = count, record_size = record_size}
		append(file, ..bytes)
	}
	data_flags := writes.data_flags == {} ? Segment_Flags{.Read, .Write} : writes.data_flags
	segments := [3]Segment{{}, {memory_offset = 0, memory_size = PAGE_SIZE, flags = {.Read, .Execute}}, {memory_offset = PAGE_SIZE, memory_size = PAGE_SIZE, flags = data_flags}}
	outputs := make([dynamic]Record_Output, context.temp_allocator)
	append(&outputs, Record_Output{}, Record_Output{place = output_places[0]}, Record_Output{place = output_places[1]})
	next_place := EXTRA_PLACES_FIRST
	extra_place_of :: proc(writes: Loader_Writes, next_place: ^u64) -> u64 {
		if !writes.extra_places_apart {
			return writes.extra_place
		}
		place := next_place^
		next_place^ += RECORD_STREAM_PLACE_SIZE
		return place
	}
	for _ in 0 ..< writes.extra_rows[0] {
		append(&outputs, Record_Output{place = extra_place_of(writes, &next_place)})
	}
	inputs := make([dynamic]Record_Input, context.temp_allocator)
	append(&inputs, Record_Input{}, Record_Input{place = input_place})
	for _ in 0 ..< writes.extra_rows[1] {
		append(&inputs, Record_Input{place = extra_place_of(writes, &next_place)})
	}
	add(&file, &directory, .Segments, bytes_of(segments[:]), len(segments), size_of(Segment))
	add(&file, &directory, .Record_Outputs, bytes_of(outputs[:]), u32(len(outputs)), size_of(Record_Output))
	add(&file, &directory, .Record_Inputs, bytes_of(inputs[:]), u32(len(inputs)), size_of(Record_Input))
	if len(writes.rebases) != 0 {
		add(&file, &directory, .Rebases, bytes_of(writes.rebases), u32(len(writes.rebases)), REBASE_WORD_SIZE)
	}
	if len(writes.import_slots) != 0 {
		import_slots := make([dynamic]Import_Slot, context.temp_allocator)
		append(&import_slots, Import_Slot{})
		append(&import_slots, ..writes.import_slots)
		add(&file, &directory, .Import_Slots, bytes_of(import_slots[:]), u32(len(import_slots)), size_of(Import_Slot))
	}
	if writes.hash_place != 0 {
		hash_places := [2]Own_Hash_Place{{}, {memory_offset = writes.hash_place}}
		add(&file, &directory, .Own_Hash, bytes_of(hash_places[:]), len(hash_places), size_of(Own_Hash_Place))
	}
	(^Header)(&file[0])^ = {magic = MAGIC, version = VERSION, header_size = size_of(Header), machine = .X86_64, table_count = TABLE_COUNT, memory_size = 2 * PAGE_SIZE}
	(^[TABLE_COUNT]Table_Entry)(&file[size_of(Header)])^ = directory
	return file[:]
}

@(private = "file")
memory_is_zero :: proc(memory: []u8) -> bool {
	for value in memory {
		if value != 0 {
			return false
		}
	}
	return true
}

// A place that is not 0 and not RECORD_STREAM_PLACE_SIZE aligned bytes in
// a segment that the loader can write is refused by validate, for a record
// output and for a record input: in the code, not aligned, across the end
// of the data, past the memory, at the largest offsets. The loader refuses
// it too, and writes nothing.
@(test)
a_record_stream_place_outside_writable_data_is_refused :: proc(t: ^testing.T) {
	refused := [?]u64{4, 64, PAGE_SIZE - RECORD_STREAM_PLACE_SIZE, PAGE_SIZE + 1, PAGE_SIZE + 2, 2 * PAGE_SIZE - 2, 2 * PAGE_SIZE, max(u64) - RECORD_STREAM_PLACE_SIZE + 1, max(u64)}
	for place in refused {
		as_output := places_file({FIRST_OUTPUT_PLACE, place}, INPUT_PLACE)
		testing.expectf(t, validate(as_output) == .Bad_Record_Stream_Place, "the place %x of a record output is taken", place)
		as_input := places_file({FIRST_OUTPUT_PLACE, SECOND_OUTPUT_PLACE}, place)
		testing.expectf(t, validate(as_input) == .Bad_Record_Stream_Place, "the place %x of a record input is taken", place)
		memory := make([]u8, 2 * PAGE_SIZE, context.temp_allocator)
		testing.expect(t, !record_stream_indexes_write(as_input, memory))
		// The rows before the refused one are written in the same walk:
		// the loader then does not run the module, whose memory it drops.
		testing.expect(t, memory_is_zero(memory[:PAGE_SIZE]))
	}
}

// A place that another write of a loader meets is refused: the own-hash
// place over a place, by its first byte and by its last; a rebase
// location, as an offset word and as a bit of a bitmap, by one byte at
// each side; an import slot; a data segment that loses Write after the
// load. The neighbours that touch a place and do not meet it come last.
@(test)
a_record_stream_place_that_another_write_meets_is_refused :: proc(t: ^testing.T) {
	places := [2]u64{FIRST_OUTPUT_PLACE, SECOND_OUTPUT_PLACE}
	refused := [?]Loader_Writes {
		{hash_place = SECOND_OUTPUT_PLACE + RECORD_STREAM_PLACE_SIZE - 1},
		{hash_place = SECOND_OUTPUT_PLACE - HASH_SIZE + 1},
		// A rebase word with its low bit set is a bitmap, so a location is
		// even: the nearest even locations that share a byte with the place.
		{rebases = {SECOND_OUTPUT_PLACE - REBASE_WORD_SIZE + 2}},
		{rebases = {SECOND_OUTPUT_PLACE + RECORD_STREAM_PLACE_SIZE - 2}},
		// The offset word puts the cursor 8 bytes after it; bit 4 names
		// the fourth word from the cursor: the place of the record input.
		{rebases = {INPUT_PLACE - 4 * REBASE_WORD_SIZE, 1 << 4 | 1}},
		// A second bitmap word moves the cursor by the 63 words of the
		// first: its bit 1 names the word at the cursor, the place of the
		// record input.
		{rebases = {INPUT_PLACE - REBASE_WORD_SIZE - REBASE_WORD_SIZE * REBASE_BITMAP_LOCATIONS, 1, 1 << 1 | 1}},
		// Bit 63, the last of a bitmap, names the 63rd word from the
		// cursor: the place of the second record output.
		{rebases = {SECOND_OUTPUT_PLACE - REBASE_WORD_SIZE - REBASE_WORD_SIZE * (REBASE_BITMAP_LOCATIONS - 1), 1 << 63 | 1}},
		{import_slots = {{memory_offset = FIRST_OUTPUT_PLACE - REBASE_WORD_SIZE + 1, import_index = 1, export_index = 1}}},
		{data_flags = {.Read, .Write, .Read_Only_After_Load}},
	}
	for writes in refused {
		file := places_file(places, INPUT_PLACE, writes)
		testing.expectf(t, validate(file) == .Bad_Record_Stream_Place, "the places beside %v are taken", writes)
	}
	taken := [?]Loader_Writes {
		{hash_place = SECOND_OUTPUT_PLACE + RECORD_STREAM_PLACE_SIZE},
		{hash_place = SECOND_OUTPUT_PLACE - HASH_SIZE},
		{rebases = {SECOND_OUTPUT_PLACE - REBASE_WORD_SIZE}},
		{rebases = {SECOND_OUTPUT_PLACE + RECORD_STREAM_PLACE_SIZE}},
		{rebases = {INPUT_PLACE - 4 * REBASE_WORD_SIZE, 1 << 3 | 1 << 5 | 1}},
		// The neighbours of the two walks above: the word before the place.
		{rebases = {INPUT_PLACE - 2 * REBASE_WORD_SIZE - REBASE_WORD_SIZE * REBASE_BITMAP_LOCATIONS, 1, 1 << 1 | 1}},
		{rebases = {SECOND_OUTPUT_PLACE - REBASE_WORD_SIZE - REBASE_WORD_SIZE * (REBASE_BITMAP_LOCATIONS - 1), 1 << 62 | 1}},
		{import_slots = {{memory_offset = FIRST_OUTPUT_PLACE + RECORD_STREAM_PLACE_SIZE, import_index = 1, export_index = 1}}},
	}
	for writes in taken {
		file := places_file(places, INPUT_PLACE, writes)
		testing.expectf(t, validate(file) == .None, "the places beside %v are refused: %v", writes, validate(file))
	}
}

// The rows of each table past RECORD_STREAM_INDEX_MOST are refused before
// any row is read: one past it, in each table, with rows whose place in
// the code would be refused if validate read them; the largest count that
// the directory holds. The bound itself, with valid rows, comes last.
@(test)
the_rows_of_a_record_stream_table_are_bounded_before_they_are_read :: proc(t: ^testing.T) {
	places := [2]u64{FIRST_OUTPUT_PLACE, SECOND_OUTPUT_PLACE}
	// The file has two record outputs and one record input of its own.
	past := [2][2]int{{RECORD_STREAM_INDEX_MOST - 1, 0}, {0, RECORD_STREAM_INDEX_MOST}}
	for extra in past {
		file := places_file(places, INPUT_PLACE, {extra_rows = extra, extra_place = 4})
		testing.expectf(t, validate(file) == .Too_Many_Record_Streams, "%v more rows are taken: %v", extra, validate(file))
	}
	// A count that the directory states and the file does not hold is a
	// table outside the file: refused before the bound.
	largest := places_file(places, INPUT_PLACE)
	directory := (^[TABLE_COUNT]Table_Entry)(&largest[size_of(Header)])
	directory[Table_Kind.Record_Outputs].count = max(u32)
	testing.expect_value(t, validate(largest), Error.Bad_Table)
	testing.expect(t, !record_stream_counts_valid(largest))

	at_bound := [2][2]int{{RECORD_STREAM_INDEX_MOST - 2, 0}, {0, RECORD_STREAM_INDEX_MOST - 1}}
	for extra in at_bound {
		file := places_file(places, INPUT_PLACE, {extra_rows = extra})
		testing.expectf(t, validate(file) == .None, "%v more rows are refused: %v", extra, validate(file))
	}
}

// The tables at their bound, each row with its own place: a rebase on the
// last place of the sorted run is refused, as one on the first; the same
// file with no rebase is taken last.
@(test)
the_places_of_full_tables_are_each_checked :: proc(t: ^testing.T) {
	places := [2]u64{FIRST_OUTPUT_PLACE, SECOND_OUTPUT_PLACE}
	// Two outputs and one input of the file, then their rows to the bound.
	extra := [2]int{RECORD_STREAM_INDEX_MOST - 2, RECORD_STREAM_INDEX_MOST - 1}
	last := EXTRA_PLACES_FIRST + RECORD_STREAM_PLACE_SIZE * u64(extra[0] + extra[1] - 1)
	for rebase in ([?]u64{last, FIRST_OUTPUT_PLACE}) {
		rebases := [1]u64{rebase}
		file := places_file(places, INPUT_PLACE, {extra_rows = extra, extra_places_apart = true, rebases = rebases[:]})
		testing.expectf(t, validate(file) == .Bad_Record_Stream_Place, "a rebase on the place %x of full tables is taken", rebase)
	}
	file := places_file(places, INPUT_PLACE, {extra_rows = extra, extra_places_apart = true})
	testing.expect_value(t, validate(file), Error.None)
}

// Two rows at one place are refused: two outputs, an output and an input,
// and two added rows far in the sorted run. Rows of the place 0 share it
// with no fault: the link dropped each variable.
@(test)
two_rows_at_one_place_are_refused :: proc(t: ^testing.T) {
	testing.expect_value(t, validate(places_file({FIRST_OUTPUT_PLACE, FIRST_OUTPUT_PLACE}, INPUT_PLACE)), Error.Bad_Record_Stream_Place)
	testing.expect_value(t, validate(places_file({FIRST_OUTPUT_PLACE, SECOND_OUTPUT_PLACE}, SECOND_OUTPUT_PLACE)), Error.Bad_Record_Stream_Place)
	testing.expect_value(t, validate(places_file({FIRST_OUTPUT_PLACE, SECOND_OUTPUT_PLACE}, INPUT_PLACE, {extra_rows = {2, 0}, extra_place = EXTRA_PLACES_FIRST})), Error.Bad_Record_Stream_Place)
	testing.expect_value(t, validate(places_file({0, 0}, 0, {extra_rows = {3, 3}})), Error.None)
}

// The places that validate takes, last: 0, which writes nothing, the first
// and the last aligned place of the data. The loader writes the index of
// each row at its place, only inside the range that it gives, and refuses
// memory that ends before a place.
@(test)
the_loader_writes_the_index_of_each_row_at_its_place :: proc(t: ^testing.T) {
	last := u64(2 * PAGE_SIZE - RECORD_STREAM_PLACE_SIZE)
	edges := places_file({0, PAGE_SIZE}, last)
	testing.expect_value(t, validate(edges), Error.None)
	memory := make([]u8, 2 * PAGE_SIZE, context.temp_allocator)
	testing.expect(t, record_stream_indexes_write(edges, memory))
	testing.expect_value(t, memory[PAGE_SIZE], 2)
	testing.expect_value(t, memory[last], 1)
	testing.expect(t, memory_is_zero(memory[:PAGE_SIZE]))

	file := places_file({FIRST_OUTPUT_PLACE, SECOND_OUTPUT_PLACE}, INPUT_PLACE)
	testing.expect_value(t, validate(file), Error.None)
	clean := make([]u8, 2 * PAGE_SIZE, context.temp_allocator)
	testing.expect(t, record_stream_indexes_write(file, clean, 0, PAGE_SIZE))
	testing.expect(t, memory_is_zero(clean))
	testing.expect(t, !record_stream_indexes_write(file, clean[:INPUT_PLACE + RECORD_STREAM_PLACE_SIZE - 1]))
	written := make([]u8, 2 * PAGE_SIZE, context.temp_allocator)
	testing.expect(t, record_stream_indexes_write(file, written, PAGE_SIZE, 2 * PAGE_SIZE))
	read :: proc(memory: []u8, place: u64) -> u32 {
		return u32(memory[place]) | u32(memory[place + 1]) << 8 | u32(memory[place + 2]) << 16 | u32(memory[place + 3]) << 24
	}
	testing.expect_value(t, read(written, FIRST_OUTPUT_PLACE), 1)
	testing.expect_value(t, read(written, SECOND_OUTPUT_PLACE), 2)
	testing.expect_value(t, read(written, INPUT_PLACE), 1)
}
