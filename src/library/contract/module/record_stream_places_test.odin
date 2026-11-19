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

@(private = "file")
places_file :: proc(output_places: [2]u64, input_place: u64) -> []u8 {
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
	segments := [3]Segment{{}, {memory_offset = 0, memory_size = PAGE_SIZE, flags = {.Read, .Execute}}, {memory_offset = PAGE_SIZE, memory_size = PAGE_SIZE, flags = {.Read, .Write}}}
	outputs := [3]Record_Output{{}, {place = output_places[0]}, {place = output_places[1]}}
	inputs := [2]Record_Input{{}, {place = input_place}}
	add(&file, &directory, .Segments, bytes_of(segments[:]), len(segments), size_of(Segment))
	add(&file, &directory, .Record_Outputs, bytes_of(outputs[:]), len(outputs), size_of(Record_Output))
	add(&file, &directory, .Record_Inputs, bytes_of(inputs[:]), len(inputs), size_of(Record_Input))
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
