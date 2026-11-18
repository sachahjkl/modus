#+build !freestanding
package acpi_processors

import "core:testing"

// A table APIC that a test builds, entry after entry.
@(private = "file")
Table_Builder :: struct {
	bytes:  [512]u8,
	length: int,
}

@(private = "file")
builder_start :: proc(builder: ^Table_Builder) {
	builder.length = ENTRIES_START
}

@(private = "file")
store_32 :: proc(bytes: []u8, offset: int, value: u32) {
	for index in 0 ..< 4 {
		bytes[offset + index] = u8(value >> (8 * uint(index)))
	}
}

// local_add writes an entry of an identifier of 8 bits.
@(private = "file")
local_add :: proc(builder: ^Table_Builder, identifier: u8, flags: u32, length := LOCAL_CONTROLLER_SIZE) {
	start := builder.length
	builder.bytes[start] = ENTRY_LOCAL_CONTROLLER
	builder.bytes[start + 1] = u8(length)
	builder.bytes[start + LOCAL_CONTROLLER_IDENTIFIER] = identifier
	if length >= LOCAL_CONTROLLER_SIZE {
		store_32(builder.bytes[:], start + LOCAL_CONTROLLER_FLAGS, flags)
	}
	builder.length += length
}

// extended_add writes an entry of an identifier of 32 bits.
@(private = "file")
extended_add :: proc(builder: ^Table_Builder, identifier: u32, flags: u32, length := LOCAL_CONTROLLER_EXTENDED_SIZE) {
	start := builder.length
	builder.bytes[start] = ENTRY_LOCAL_CONTROLLER_EXTENDED
	builder.bytes[start + 1] = u8(length)
	// The identifier and the flags fit an entry one byte short too: such an
	// entry is refused by its length alone.
	store_32(builder.bytes[:], start + LOCAL_CONTROLLER_EXTENDED_IDENTIFIER, identifier)
	store_32(builder.bytes[:], start + LOCAL_CONTROLLER_EXTENDED_FLAGS, flags)
	builder.length += length
}

@(test)
a_table_shorter_than_its_entries_names_no_processor :: proc(t: ^testing.T) {
	bytes: [ENTRIES_START + 1]u8
	identifiers := [4]u32{7, 7, 7, 7}
	for length in ([?]int{0, 1, ENTRIES_START - 1, ENTRIES_START, ENTRIES_START + 1}) {
		testing.expect_value(t, processors_read(bytes[:length], true, identifiers[:]), 0)
		testing.expect_value(t, identifiers, [4]u32{7, 7, 7, 7})
	}
}

@(test)
an_entry_out_of_the_table_ends_the_walk :: proc(t: ^testing.T) {
	builder: Table_Builder
	builder_start(&builder)
	local_add(&builder, 1, FLAG_ENABLED)
	start := builder.length
	local_add(&builder, 2, FLAG_ENABLED)
	identifiers: [4]u32
	// A length of 0, which would never advance the walk; a length below the
	// header; a length one past the table; and the table cut one byte
	// before the end of its last entry.
	builder.bytes[start + 1] = 0
	testing.expect_value(t, processors_read(builder.bytes[:builder.length], false, identifiers[:]), 1)
	builder.bytes[start + 1] = ENTRY_HEADER_SIZE - 1
	testing.expect_value(t, processors_read(builder.bytes[:builder.length], false, identifiers[:]), 1)
	builder.bytes[start + 1] = u8(builder.length - start + 1)
	testing.expect_value(t, processors_read(builder.bytes[:builder.length], false, identifiers[:]), 1)
	builder.bytes[start + 1] = LOCAL_CONTROLLER_SIZE
	testing.expect_value(t, processors_read(builder.bytes[:builder.length - 1], false, identifiers[:]), 1)
	testing.expect_value(t, identifiers[0], 1)
	// The last entry ends exactly at the end of the table: it counts.
	identifiers = {}
	testing.expect_value(t, processors_read(builder.bytes[:builder.length], false, identifiers[:]), 2)
	testing.expect_value(t, identifiers, [4]u32{1, 2, 0, 0})
}

@(test)
a_processor_needs_its_flag_its_length_and_its_mode :: proc(t: ^testing.T) {
	builder: Table_Builder
	builder_start(&builder)
	local_add(&builder, 1, 0) // Not enabled.
	local_add(&builder, 2, ~FLAG_ENABLED) // Each other flag, not enabled.
	local_add(&builder, 3, FLAG_ENABLED, LOCAL_CONTROLLER_SIZE - 1) // One byte short of its flags.
	extended_add(&builder, 4, FLAG_ENABLED, LOCAL_CONTROLLER_EXTENDED_SIZE - 1) // One byte short, in each mode.
	extended_add(&builder, max(u32), FLAG_ENABLED)
	// An entry of 10 bytes: the walk goes on after its 10 bytes, not
	// after 8, so the next entry is read whole.
	local_add(&builder, max(u8), FLAG_ENABLED, LOCAL_CONTROLLER_SIZE + 2)
	local_add(&builder, max(u8) - 1, FLAG_ENABLED)
	identifiers: [4]u32
	// The extended entry counts only in the mode of extended identifiers.
	testing.expect_value(t, processors_read(builder.bytes[:builder.length], false, identifiers[:]), 2)
	testing.expect_value(t, identifiers, [4]u32{u32(max(u8)), u32(max(u8) - 1), 0, 0})
	identifiers = {}
	testing.expect_value(t, processors_read(builder.bytes[:builder.length], true, identifiers[:]), 3)
	testing.expect_value(t, identifiers, [4]u32{max(u32), u32(max(u8)), u32(max(u8) - 1), 0})
}

@(test)
the_identifiers_stop_at_their_capacity :: proc(t: ^testing.T) {
	builder: Table_Builder
	builder_start(&builder)
	for identifier in u8(0) ..< 5 {
		local_add(&builder, identifier, FLAG_ENABLED)
	}
	identifiers: [3]u32
	testing.expect_value(t, processors_read(builder.bytes[:builder.length], false, identifiers[:0]), 0)
	testing.expect_value(t, processors_read(builder.bytes[:builder.length], false, identifiers[:]), 3)
	testing.expect_value(t, identifiers, [3]u32{0, 1, 2})
}

// The absence of a table comes first, then its length, then its count;
// one listed processor is a machine of one processor, not an absence.
@(test)
the_absence_of_the_processors_of_a_table :: proc(t: ^testing.T) {
	builder: Table_Builder
	builder_start(&builder)
	testing.expect_value(t, table_absence(false, nil, 0), Table_Absence.Absent)
	// A table that the kernel did not find, whatever its bytes and count.
	testing.expect_value(t, table_absence(false, builder.bytes[:builder.length], 3), Table_Absence.Absent)
	for length in ([?]int{0, 1, ENTRIES_START - 1}) {
		testing.expect_value(t, table_absence(true, builder.bytes[:length], 0), Table_Absence.Too_Short)
		testing.expect_value(t, table_absence(true, builder.bytes[:length], 1), Table_Absence.Too_Short)
	}
	// A table of its header only, and a table whose one entry cannot run.
	testing.expect_value(t, table_absence(true, builder.bytes[:ENTRIES_START], processors_read(builder.bytes[:ENTRIES_START], false, nil)), Table_Absence.No_Usable_Processor)
	local_add(&builder, 1, 0)
	identifiers: [4]u32
	count := processors_read(builder.bytes[:builder.length], false, identifiers[:])
	testing.expect_value(t, table_absence(true, builder.bytes[:builder.length], count), Table_Absence.No_Usable_Processor)
	testing.expect_value(t, table_absence(true, builder.bytes[:builder.length], -1), Table_Absence.No_Usable_Processor)
	// Each absence has a text for the line of the kernel; None alone has none.
	for absence in Table_Absence {
		testing.expectf(t, (TABLE_ABSENCE_TEXTS[absence] == "") == (absence == .None), "the text of %v", absence)
	}
	local_add(&builder, 2, FLAG_ENABLED)
	count = processors_read(builder.bytes[:builder.length], false, identifiers[:])
	testing.expect_value(t, count, 1)
	testing.expect_value(t, table_absence(true, builder.bytes[:builder.length], count), Table_Absence.None)
	testing.expect_value(t, table_absence(true, builder.bytes[:builder.length], max(int)), Table_Absence.None)
}
