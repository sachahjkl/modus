#+build !freestanding
#+build !modus
package output

import "core:testing"
import "modus:contract/module"
import "modus:contract/value_kinds"

@(private = "file")
described_fields :: proc() -> [3]Test_Field {
	return {
		{name = "bytes", type = .Integer, unsigned = true, integer_unit = value_kinds.size_in(.Bytes)},
		{name = "level", type = .Integer, unsigned = true, detail = 1, kind = .Status, contract_enum = .Log_Level},
		{name = "name", type = .Text, detail = 7},
	}
}

// A record that no reader takes gives no description file: the index 0,
// an index past the table, a record with a Handle field. A file that does
// not fit the bytes gives none, one byte short and with no byte.
@(test)
a_description_file_of_no_record_or_too_large_is_refused :: proc(t: ^testing.T) {
	fields := described_fields()
	file := typed_file("Probe", fields[:])
	into := make([]u8, DESCRIPTION_FILE_BYTES_MOST, context.temp_allocator)
	for index in ([?]u32{0, 2, max(u32)}) {
		_, ok := description_file_write(into, file, index)
		testing.expectf(t, !ok, "the record %d gives a description file", index)
	}
	with_handle := typed_file("Probe", []Test_Field{{name = "handle", type = .Handle}, {name = "rest", type = .Integer, detail = 4}})
	_, handle_ok := description_file_write(into, with_handle, 1)
	testing.expect(t, !handle_ok)
	size, ok := description_file_write(into, file, 1)
	testing.expect(t, ok)
	_, short_ok := description_file_write(into[:size - 1], file, 1)
	testing.expect(t, !short_ok)
	_, empty_ok := description_file_write(nil, file, 1)
	testing.expect(t, !empty_ok)
}

// The description file holds the record as the module file describes it,
// last: the type check finds them equal, and the border of the reader
// takes a compartment against it.
@(test)
a_description_file_holds_the_record_of_the_writer :: proc(t: ^testing.T) {
	fields := described_fields()
	file := typed_file("Probe", fields[:])
	into := make([]u8, DESCRIPTION_FILE_BYTES_MOST, context.temp_allocator)
	size, ok := description_file_write(into, file, 1)
	testing.expect(t, ok && size <= DESCRIPTION_FILE_BYTES_MOST)
	described := into[:size]
	difference, part := record_descriptions_compare(described, DESCRIPTION_RECORD_INDEX, file, 1)
	testing.expectf(t, difference == .Equal, "the description file differs: %v at %d", difference, part)
	description, taken := module.record_stream_type(described, DESCRIPTION_RECORD_INDEX)
	testing.expect(t, taken)
	compartment := make([]u8, compartment_size(description.size), context.temp_allocator)
	state: Read_State
	testing.expect(t, joined_compartment(compartment, 0))
	_, fault, _ := record_of_compartment(&state, compartment, described, description)
	testing.expect_value(t, fault, Compartment_Fault.None)
	record := make([]u8, description.size, context.temp_allocator)
	copy(record[9:], "probe")
	testing.expect(t, record_compartment(compartment, 0, record))
	taken_compartment, record_fault, _ := record_of_compartment(&state, compartment, described, description)
	testing.expect_value(t, record_fault, Compartment_Fault.None)
	testing.expect_value(t, taken_compartment.kind, Compartment_Kind.Record)
}
