#+build !freestanding
#+build !modus
package operation_sequence

import "core:slice"
import "core:testing"
import "modus:contract/byte_order"
import "modus:contract/operation"

// The tests write a whole sequence with the writer, damage one word of its
// bytes, and check the refusal of the reader: its problem, its index, its
// argument, the bytes that it did not change, and the zero sequence that
// it leaves. The accepted cases come last.

// A sequence with two areas and five steps, each argument source once:
// the steps 1 and 2 are one kernel entry, and the step 3 names the
// results of the steps 0 and 2.
@(private = "file")
test_sequence :: proc() -> Sequence {
	sequence: Sequence
	sequence.area_count = 2
	sequence.areas[0] = {pages = 1, content_bytes = 3}
	sequence.areas[1] = {pages = AREA_PAGES_MOST, content_bytes = 0}
	sequence.content[0] = 'a'
	sequence.content[1] = 'b'
	sequence.content[2] = 'c'
	sequence.step_count = 5
	sequence.steps[0] = {operation = u32(operation.Operation.Memory_Create)}
	sequence.steps[0].arguments[0] = {source = .Budget}
	sequence.steps[0].arguments[1] = {source = .Value, value = 1}
	sequence.steps[1] = {operation = u32(operation.Operation.Log), flags = {.No_Error_Details}}
	sequence.steps[1].arguments[0] = {source = .Log}
	sequence.steps[1].arguments[1] = {source = .Area_Address, area = 0}
	sequence.steps[1].arguments[2] = {source = .Value, value = 3}
	sequence.steps[2] = {operation = u32(operation.Operation.Thread_Create), flags = {.Same_Entry}}
	sequence.steps[2].arguments[0] = {source = .Budget}
	sequence.steps[2].arguments[1] = {source = .Thread_Entry, entry = .Return}
	sequence.steps[2].arguments[2] = {source = .Area_Address, area = 1, offset = AREA_PAGES_MOST * operation.PAGE_SIZE - 8}
	sequence.steps[3] = {operation = u32(operation.Operation.Memory_Map)}
	sequence.steps[3].arguments[0] = {source = .Result, step = 0, place = 0}
	sequence.steps[3].arguments[1] = {source = .Result, step = 2, place = ARGUMENTS - 1, offset = RESULT_OFFSET_MOST}
	sequence.steps[3].arguments[2] = {source = .Area_Handle, area = 1}
	sequence.steps[4] = {operation = u32(operation.Operation.Inspect)}
	sequence.steps[4].arguments[0] = {source = .Machine}
	sequence.steps[4].arguments[1] = {source = .Value, value = max(u64)}
	return sequence
}

@(private = "file")
test_bytes :: proc(t: ^testing.T, sequence: ^Sequence) -> []u8 {
	out := make([]u8, SEQUENCE_BYTES_MOST, context.temp_allocator)
	written, ok := write(out, sequence)
	testing.expect(t, ok, "the writer refuses the sequence of the test")
	return written
}

// expect_refusal checks one refusal, and that the reader left the bytes as
// they were and the sequence zero.
@(private = "file")
expect_refusal :: proc(t: ^testing.T, bytes: []u8, problem: Problem, index, argument: int, loc := #caller_location) {
	before := slice.clone(bytes, context.temp_allocator)
	sequence := new(Sequence, context.temp_allocator)
	sequence.step_count = 1 // A value that the refusal must clear.
	refusal := check(bytes, sequence)
	testing.expect_value(t, refusal, Refusal{problem, index, argument}, loc = loc)
	testing.expect(t, slice.equal(before, bytes), "check changed the bytes", loc = loc)
	testing.expect(t, sequence^ == Sequence{}, "a refusal left a part of the sequence", loc = loc)
}

@(private = "file")
set_u64 :: proc(bytes: []u8, offset: int, value: u64) -> []u8 {
	changed := slice.clone(bytes, context.temp_allocator)
	byte_order.write_u64_little_endian(changed, offset, value)
	return changed
}

@(private = "file")
set_u32 :: proc(bytes: []u8, offset: int, value: u32) -> []u8 {
	changed := slice.clone(bytes, context.temp_allocator)
	byte_order.write_u32_little_endian(changed, offset, value)
	return changed
}

@(private = "file")
set_u16 :: proc(bytes: []u8, offset: int, value: u16) -> []u8 {
	changed := slice.clone(bytes, context.temp_allocator)
	byte_order.write_u16_little_endian(changed, offset, value)
	return changed
}

// The offset of one word of an argument record of the test sequence.
@(private = "file")
argument_word :: proc(step, argument: int, field: uintptr) -> int {
	return argument_offset(2, step, argument) + int(field)
}

@(test)
check_refuses_a_damaged_header :: proc(t: ^testing.T) {
	sequence := test_sequence()
	bytes := test_bytes(t, &sequence)
	expect_refusal(t, bytes[:0], .Too_Small, -1, -1)
	expect_refusal(t, bytes[:1], .Too_Small, -1, -1)
	expect_refusal(t, bytes[:HEADER_SIZE - 1], .Too_Small, -1, -1)
	magic := int(offset_of(Header_Record, magic))
	expect_refusal(t, set_u64(bytes, magic, MAGIC + 1), .Magic, -1, -1)
	expect_refusal(t, set_u64(bytes, magic, 0), .Magic, -1, -1)
	expect_refusal(t, set_u64(bytes, magic, max(u64)), .Magic, -1, -1)
	format := int(offset_of(Header_Record, format))
	expect_refusal(t, set_u32(bytes, format, 0), .Format, -1, -1)
	expect_refusal(t, set_u32(bytes, format, FORMAT + 1), .Format, -1, -1)
	expect_refusal(t, set_u32(bytes, format, max(u32)), .Format, -1, -1)
	steps := int(offset_of(Header_Record, step_count))
	expect_refusal(t, set_u16(bytes, steps, STEPS_MOST + 1), .Step_Count, -1, -1)
	expect_refusal(t, set_u16(bytes, steps, max(u16)), .Step_Count, -1, -1)
	areas := int(offset_of(Header_Record, area_count))
	expect_refusal(t, set_u16(bytes, areas, AREAS_MOST + 1), .Area_Count, -1, -1)
	expect_refusal(t, set_u16(bytes, areas, max(u16)), .Area_Count, -1, -1)
}

// A cut at each kind of record, and one byte too many.
@(test)
check_refuses_a_truncated_sequence :: proc(t: ^testing.T) {
	sequence := test_sequence()
	bytes := test_bytes(t, &sequence)
	content_offset := step_offset(2, 5)
	expect_refusal(t, bytes[:HEADER_SIZE], .Size, -1, -1)
	expect_refusal(t, bytes[:HEADER_SIZE + AREA_SIZE + 1], .Size, -1, -1)
	expect_refusal(t, bytes[:step_offset(2, 4) + 1], .Size, -1, -1)
	expect_refusal(t, bytes[:content_offset - 1], .Size, -1, -1)
	expect_refusal(t, bytes[:content_offset], .Size, -1, -1)
	expect_refusal(t, bytes[:len(bytes) - 1], .Size, -1, -1)
	longer := make([]u8, len(bytes) + 1, context.temp_allocator)
	copy(longer, bytes)
	expect_refusal(t, longer, .Size, -1, -1)
	// One step more in the header than the bytes hold.
	expect_refusal(t, set_u16(bytes, int(offset_of(Header_Record, step_count)), 6), .Size, -1, -1)
}

@(test)
check_refuses_a_damaged_area :: proc(t: ^testing.T) {
	sequence := test_sequence()
	bytes := test_bytes(t, &sequence)
	second_pages := HEADER_SIZE + AREA_SIZE + int(offset_of(Area_Record, pages))
	expect_refusal(t, set_u32(bytes, second_pages, 0), .Area_Pages, 1, -1)
	expect_refusal(t, set_u32(bytes, second_pages, AREA_PAGES_MOST + 1), .Area_Pages, 1, -1)
	expect_refusal(t, set_u32(bytes, second_pages, max(u32)), .Area_Pages, 1, -1)
	first_content := HEADER_SIZE + int(offset_of(Area_Record, content_bytes))
	expect_refusal(t, set_u32(bytes, first_content, operation.PAGE_SIZE + 1), .Area_Content, 0, -1)
	expect_refusal(t, set_u32(bytes, first_content, max(u32)), .Area_Content, 0, -1)
	// Each area holds its content, and both together pass the most.
	full := test_sequence()
	full.areas[0] = {pages = 1, content_bytes = CONTENT_BYTES_MOST}
	full.areas[1] = {pages = 1, content_bytes = 0}
	full_bytes := test_bytes(t, &full)
	second_content := HEADER_SIZE + AREA_SIZE + int(offset_of(Area_Record, content_bytes))
	expect_refusal(t, set_u32(full_bytes, second_content, 1), .Area_Content, 1, -1)
}

@(test)
check_refuses_a_damaged_step :: proc(t: ^testing.T) {
	sequence := test_sequence()
	bytes := test_bytes(t, &sequence)
	operation_word := step_offset(2, 4) + int(offset_of(Step_Record, operation))
	expect_refusal(t, set_u32(bytes, operation_word, u32(operation.Operation.Inspect) | operation.COMMAND_NAMES_ERROR_DETAILS), .Operation_Word, 4, -1)
	expect_refusal(t, set_u32(bytes, operation_word, max(u32)), .Operation_Word, 4, -1)
	flags := step_offset(2, 4) + int(offset_of(Step_Record, flags))
	unknown := u32(1) << (u32(max(Step_Flag)) + 1)
	expect_refusal(t, set_u32(bytes, flags, unknown), .Step_Flags, 4, -1)
	expect_refusal(t, set_u32(bytes, flags, STEP_FLAGS_KNOWN | unknown), .Step_Flags, 4, -1)
	expect_refusal(t, set_u32(bytes, flags, max(u32)), .Step_Flags, 4, -1)
	first_flags := step_offset(2, 0) + int(offset_of(Step_Record, flags))
	expect_refusal(t, set_u32(bytes, first_flags, u32(1) << u32(Step_Flag.Same_Entry)), .Entry_First, 0, -1)
}

// A kernel entry of the most steps passes; one step more is refused at
// that step.
@(test)
check_refuses_a_kernel_entry_past_its_most :: proc(t: ^testing.T) {
	sequence: Sequence
	sequence.step_count = ENTRY_STEPS_MOST + 1
	for step in 1 ..< sequence.step_count {
		sequence.steps[step].flags = {.Same_Entry}
	}
	bytes := test_bytes(t, &sequence)
	expect_refusal(t, bytes, .Entry_Steps, ENTRY_STEPS_MOST, -1)
	sequence.step_count = ENTRY_STEPS_MOST
	read: Sequence
	testing.expect_value(t, check(test_bytes(t, &sequence), &read), Refusal{.None, -1, -1})
}

@(test)
check_refuses_a_damaged_argument :: proc(t: ^testing.T) {
	sequence := test_sequence()
	bytes := test_bytes(t, &sequence)
	source := offset_of(Argument_Record, source)
	index := offset_of(Argument_Record, index)
	place := offset_of(Argument_Record, place)
	value := offset_of(Argument_Record, value)

	// A source word that names no member.
	expect_refusal(t, set_u64(bytes, argument_word(4, 2, source), u64(max(Argument_Source)) + 1), .Argument_Source, 4, 2)
	expect_refusal(t, set_u64(bytes, argument_word(4, 2, source), max(u64)), .Argument_Source, 4, 2)

	// A word that the source does not use.
	expect_refusal(t, set_u64(bytes, argument_word(4, 1, index), 1), .Unused_Field, 4, 1)
	expect_refusal(t, set_u64(bytes, argument_word(4, 1, place), max(u64)), .Unused_Field, 4, 1)
	expect_refusal(t, set_u64(bytes, argument_word(4, 0, value), 1), .Unused_Field, 4, 0)
	expect_refusal(t, set_u64(bytes, argument_word(4, 0, index), 1), .Unused_Field, 4, 0)
	expect_refusal(t, set_u64(bytes, argument_word(3, 2, value), 1), .Unused_Field, 3, 2)
	expect_refusal(t, set_u64(bytes, argument_word(1, 1, place), 1), .Unused_Field, 1, 1)
	expect_refusal(t, set_u64(bytes, argument_word(2, 1, value), 1), .Unused_Field, 2, 1)

	// An area that the sequence does not have.
	expect_refusal(t, set_u64(bytes, argument_word(3, 2, index), 2), .Area_Index, 3, 2)
	expect_refusal(t, set_u64(bytes, argument_word(3, 2, index), max(u64)), .Area_Index, 3, 2)
	expect_refusal(t, set_u64(bytes, argument_word(1, 1, index), 2), .Area_Index, 1, 1)
	expect_refusal(t, set_u64(bytes, argument_word(1, 1, index), max(u64)), .Area_Index, 1, 1)

	// An offset one past the area and its page with no access.
	first_end := u64(operation.PAGE_SIZE + operation.PAGE_SIZE)
	expect_refusal(t, set_u64(bytes, argument_word(1, 1, value), first_end), .Offset, 1, 1)
	expect_refusal(t, set_u64(bytes, argument_word(1, 1, value), max(u64)), .Offset, 1, 1)
	expect_refusal(t, set_u64(bytes, argument_word(3, 1, value), RESULT_OFFSET_MOST + 1), .Offset, 3, 1)
	expect_refusal(t, set_u64(bytes, argument_word(3, 1, value), max(u64)), .Offset, 3, 1)

	// An entry word that names no thread entry.
	expect_refusal(t, set_u64(bytes, argument_word(2, 1, index), u64(max(Thread_Entry)) + 1), .Thread_Entry, 2, 1)
	expect_refusal(t, set_u64(bytes, argument_word(2, 1, index), max(u64)), .Thread_Entry, 2, 1)

	// The result of this step, of a later step, of a step that the
	// sequence does not have, and of a step of the same kernel entry.
	expect_refusal(t, set_u64(bytes, argument_word(3, 0, index), 3), .Result_Later, 3, 0)
	expect_refusal(t, set_u64(bytes, argument_word(3, 0, index), 4), .Result_Later, 3, 0)
	expect_refusal(t, set_u64(bytes, argument_word(3, 0, index), 5), .Result_Later, 3, 0)
	expect_refusal(t, set_u64(bytes, argument_word(3, 0, index), max(u64)), .Result_Later, 3, 0)
	same_entry := set_u64(bytes, argument_word(2, 3, source), u64(Argument_Source.Result))
	expect_refusal(t, set_u64(same_entry, argument_word(2, 3, index), 1), .Result_Same_Entry, 2, 3)
	first_step := set_u64(bytes, argument_word(0, 3, source), u64(Argument_Source.Result))
	expect_refusal(t, first_step, .Result_Later, 0, 3)

	// A value of a completion past its values.
	expect_refusal(t, set_u64(bytes, argument_word(3, 0, place), ARGUMENTS), .Result_Place, 3, 0)
	expect_refusal(t, set_u64(bytes, argument_word(3, 0, place), max(u64)), .Result_Place, 3, 0)

	// At each bound, the sequence passes.
	at_bounds := set_u64(bytes, argument_word(1, 1, value), first_end - 1)
	read: Sequence
	testing.expect_value(t, check(at_bounds, &read), Refusal{.None, -1, -1})
	testing.expect_value(t, read.steps[1].arguments[1].offset, first_end - 1)
}

// The writer refuses a count past its array, and a buffer that is too
// short, and writes nothing then.
@(test)
write_refuses_a_count_past_its_most :: proc(t: ^testing.T) {
	out := make([]u8, SEQUENCE_BYTES_MOST, context.temp_allocator)
	Damage :: #type proc(sequence: ^Sequence)
	cases := [?]Damage {
		proc(sequence: ^Sequence) {sequence.step_count = -1},
		proc(sequence: ^Sequence) {sequence.step_count = STEPS_MOST + 1},
		proc(sequence: ^Sequence) {sequence.step_count = max(int)},
		proc(sequence: ^Sequence) {sequence.area_count = -1},
		proc(sequence: ^Sequence) {sequence.area_count = AREAS_MOST + 1},
		proc(sequence: ^Sequence) {sequence.areas[0].content_bytes = -1},
		proc(sequence: ^Sequence) {sequence.areas[0].content_bytes = CONTENT_BYTES_MOST + 1},
		proc(sequence: ^Sequence) {sequence.areas[0].content_bytes = max(int)},
		proc(sequence: ^Sequence) {sequence.areas[0].content_bytes = CONTENT_BYTES_MOST; sequence.areas[1].content_bytes = 1},
		proc(sequence: ^Sequence) {sequence.areas[0].pages = -1},
		proc(sequence: ^Sequence) {sequence.areas[0].pages = int(max(u32)) + 1},
	}
	for damage, index in cases {
		sequence := test_sequence()
		damage(&sequence)
		written, ok := write(out, &sequence)
		testing.expectf(t, !ok && written == nil, "case %d: the writer takes a count past its most", index)
		_, size_ok := size(&sequence)
		testing.expectf(t, !size_ok, "case %d: size takes a count past its most", index)
	}
	sequence := test_sequence()
	total, _ := size(&sequence)
	written, ok := write(out[:total - 1], &sequence)
	testing.expect(t, !ok && written == nil, "the writer writes into a buffer one byte too short")
	written, ok = write(out[:total], &sequence)
	testing.expect(t, ok && len(written) == total)
}

// What the writer writes the reader reads to the same sequence, and that
// sequence writes again to the same bytes: the empty sequence, the
// sequence of the test, and the largest sequence.
@(test)
a_sequence_reads_and_writes_again_to_itself :: proc(t: ^testing.T) {
	empty: Sequence
	largest: Sequence
	largest.step_count = STEPS_MOST
	largest.area_count = AREAS_MOST
	for area in 0 ..< AREAS_MOST {
		largest.areas[area] = {pages = AREA_PAGES_MOST, content_bytes = CONTENT_BYTES_MOST / AREAS_MOST}
	}
	for &item, index in largest.content {
		item = u8(index)
	}
	for step in 0 ..< STEPS_MOST {
		largest.steps[step].operation = max(u32) &~ operation.COMMAND_NAMES_ERROR_DETAILS
		largest.steps[step].flags = {.No_Error_Details}
		for argument in 0 ..< ARGUMENTS {
			largest.steps[step].arguments[argument] = {source = .Value, value = max(u64)}
		}
		if step > 0 {
			largest.steps[step].arguments[0] = {source = .Result, step = step - 1, place = ARGUMENTS - 1, offset = RESULT_OFFSET_MOST}
		}
		largest.steps[step].arguments[1] = {source = .Area_Address, area = AREAS_MOST - 1, offset = AREA_PAGES_MOST * operation.PAGE_SIZE + operation.PAGE_SIZE - 1}
		largest.steps[step].arguments[2] = {source = .Thread_Entry, entry = max(Thread_Entry)}
	}
	sequences := [?]Sequence{empty, test_sequence(), largest}
	for &sequence, index in sequences {
		bytes := test_bytes(t, &sequence)
		read := new(Sequence, context.temp_allocator)
		testing.expectf(t, check(bytes, read) == Refusal{.None, -1, -1}, "case %d: check refuses what the writer wrote", index)
		testing.expectf(t, read^ == sequence, "case %d: the sequence read is not the sequence written", index)
		again := test_bytes(t, read)
		testing.expectf(t, slice.equal(again, bytes), "case %d: the sequence read writes other bytes", index)
	}
	largest_bytes := test_bytes(t, &largest)
	testing.expect_value(t, len(largest_bytes), SEQUENCE_BYTES_MOST)
	read := new(Sequence, context.temp_allocator)
	_ = check(test_bytes(t, &sequences[1]), read)
	testing.expect(t, slice.equal(area_content(read, 0), []u8{'a', 'b', 'c'}))
	testing.expect_value(t, len(area_content(read, 1)), 0)
}
