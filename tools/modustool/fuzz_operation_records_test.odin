package modustool

import "core:fmt"
import "core:slice"
import "core:testing"
import "modus:contract/operation"
import "modus:contract/operation_sequence"

// The seed of the tests of the records, and the most sequences in which
// each record type must appear. With this seed each type appears in a few
// thousand sequences; the bound ends the search, so a generator that never
// writes a type fails the test.
FUZZ_RECORDS_TEST_SEED :: u64(0x7265_636F_7264_7331)
FUZZ_RECORDS_SEQUENCES_MOST :: 50_000

// The two machines of the edges of the extended state: the least that a
// processor with xsave takes (x87 and SSE, and no denormals-are-zero in
// MXCSR) and the most (every component but bit 63, which XCR0 reserves,
// and each bit of MXCSR that a processor can take). A valid area passes
// the first; an area with a word that names nothing fails the second.
FUZZ_TEST_MXCSR_MASK_LEAST :: u32(0xFFBF)
FUZZ_TEST_MXCSR_MASK_MOST :: u32(0xFFFF)
FUZZ_TEST_COMPONENTS_MOST :: max(u64) >> 1

// fuzz_page_ranges_follow_the_rules says if a table of ranges follows the
// rules of Memory_Commit: each range has a page, is inside the object, and
// starts after the range before it ends.
fuzz_page_ranges_follow_the_rules :: proc(ranges: []operation.Page_Range, object_pages: u64) -> bool {
	end: u64
	for item, index in ranges {
		if item.page_count < 1 || item.first >= object_pages || item.page_count > object_pages - item.first {
			return false
		}
		if index > 0 && item.first < end {
			return false
		}
		end = item.first + item.page_count
	}
	return true
}

// fuzz_record_form_problem decodes the bytes of one record as its type and
// says what its form breaks: a valid record that its contract refuses, or
// a record with a word that names nothing that its contract takes. ""
// when the record is what its form says. An edge can be valid or not.
fuzz_record_form_problem :: proc(type: Fuzz_Record_Type, form: Fuzz_Record_Form, bytes: []u8, object_pages: u64) -> string {
	refused: bool
	switch type {
	case .Page_Range_Table:
		if len(bytes) % size_of(operation.Page_Range) != 0 || len(bytes) > operation.RANGE_TABLE_CAPACITY * size_of(operation.Page_Range) {
			return fmt.tprintf("a table of ranges of %d bytes", len(bytes))
		}
		ranges: [operation.RANGE_TABLE_CAPACITY]operation.Page_Range
		count := len(bytes) / size_of(operation.Page_Range)
		copy(([^]u8)(&ranges[0])[:len(bytes)], bytes)
		refused = !fuzz_page_ranges_follow_the_rules(ranges[:count], object_pages)
	case .Register_Image:
		if len(bytes) != size_of(operation.Thread_Registers) {
			return fmt.tprintf("a register image of %d bytes", len(bytes))
		}
		registers: operation.Thread_Registers
		copy(([^]u8)(&registers)[:size_of(registers)], bytes)
		refusal, _ := operation.thread_registers_refusal(&registers)
		refused = refusal != .None
	case .Breakpoint_Image:
		if len(bytes) != size_of(operation.Thread_Breakpoints) {
			return fmt.tprintf("a breakpoint image of %d bytes", len(bytes))
		}
		image: operation.Thread_Breakpoints
		copy(([^]u8)(&image)[:size_of(image)], bytes)
		refusal, _ := operation.thread_breakpoints_refusal(&image)
		refused = refusal != .None
	case .Extended_State_Area:
		if len(bytes) != FUZZ_EXTENDED_STATE_BYTES {
			return fmt.tprintf("an extended state area of %d bytes", len(bytes))
		}
		switch form {
		case .Valid:
			refusal, value := operation.extended_state_refusal(bytes, FUZZ_EXTENDED_STATE_COMPONENTS_LEAST, FUZZ_TEST_MXCSR_MASK_LEAST, true)
			if refusal != .None {
				return fmt.tprintf("a valid extended state area is refused with %v (value %x)", refusal, value)
			}
		case .Names_Nothing:
			refusal, _ := operation.extended_state_refusal(bytes, FUZZ_TEST_COMPONENTS_MOST, FUZZ_TEST_MXCSR_MASK_MOST, true)
			if refusal == .None {
				return "an extended state area with a word that names nothing is taken"
			}
		case .Edge:
		}
		return ""
	}
	switch form {
	case .Valid:
		if refused {
			return fmt.tprintf("a valid %v is refused", type)
		}
	case .Names_Nothing:
		if !refused {
			return fmt.tprintf("a %v with a word that names nothing is taken", type)
		}
	case .Edge:
	}
	return ""
}

// For each choice input and each form, each writer gives a record that
// decodes as its type: a valid record that its contract takes, and a
// record with a word that names nothing that its contract refuses. A table
// of ranges is valid exactly when the object has a page for each range.
// The zero choices give a valid record.
@(test)
each_record_of_the_writers_is_what_its_form_says :: proc(t: ^testing.T) {
	empty: Fuzz_Choices
	testing.expect_value(t, fuzz_record_form_choose(&empty), Fuzz_Record_Form.Valid)
	random := Fuzz_Random{state = FUZZ_RECORDS_TEST_SEED}
	input := make([]u8, 1024, context.temp_allocator)
	object_pages_cases := [?]u64{1, 2, operation_sequence.AREA_PAGES_MOST, operation.MEMORY_PAGE_LIMIT}
	counts := [?]int{1, 2, operation_sequence.AREA_PAGES_MOST + 1, operation.RANGE_TABLE_CAPACITY}
	for round in 0 ..< 1_000 {
		length := 0
		if round > 0 {
			length = fuzz_random_below(&random, len(input) + 1)
		}
		for &item in input[:length] {
			item = u8(fuzz_random_next(&random))
		}
		for form in Fuzz_Record_Form {
			choices := fuzz_choices_of(input[:length])
			registers := fuzz_register_image_write(&choices, form)
			problem := fuzz_record_form_problem(.Register_Image, form, ([^]u8)(&registers)[:size_of(registers)], 0)
			testing.expectf(t, problem == "", "round %d, %v: %s", round, form, problem)

			choices = fuzz_choices_of(input[:length])
			image := fuzz_breakpoint_image_write(&choices, form)
			problem = fuzz_record_form_problem(.Breakpoint_Image, form, ([^]u8)(&image)[:size_of(image)], 0)
			testing.expectf(t, problem == "", "round %d, %v: %s", round, form, problem)

			choices = fuzz_choices_of(input[:length])
			area := fuzz_extended_state_write(&choices, form)
			problem = fuzz_record_form_problem(.Extended_State_Area, form, area[:], 0)
			testing.expectf(t, problem == "", "round %d, %v: %s", round, form, problem)

			for object_pages in object_pages_cases {
				for count in counts {
					choices = fuzz_choices_of(input[:length])
					ranges: [operation.RANGE_TABLE_CAPACITY]operation.Page_Range
					actual := fuzz_page_ranges_write(&choices, form, object_pages, ranges[:count])
					fits := u64(count) <= object_pages
					switch form {
					case .Valid:
						testing.expectf(t, (actual == .Valid) == fits, "round %d: %d ranges of an object of %d pages give the form %v", round, count, object_pages, actual)
						testing.expectf(t, fuzz_page_ranges_follow_the_rules(ranges[:count], object_pages) == fits, "round %d: %d ranges of an object of %d pages break the rules: %v", round, count, object_pages, fits)
					case .Edge, .Names_Nothing:
						testing.expect_value(t, actual, form)
					}
					problem = fuzz_record_form_problem(.Page_Range_Table, actual, ([^]u8)(&ranges[0])[:count * size_of(operation.Page_Range)], object_pages)
					testing.expectf(t, problem == "", "round %d, %v, %d ranges of %d pages: %s", round, form, count, object_pages, problem)
				}
			}
		}
	}
}

// fuzz_record_overlapped says if a later record of the same sequence
// wrote over a part of this one.
fuzz_record_overlapped :: proc(record: Fuzz_Record_Written, later: []Fuzz_Record_Written) -> bool {
	for other in later {
		if other.area == record.area && other.offset < record.offset + record.bytes && record.offset < other.offset + other.bytes {
			return true
		}
	}
	return false
}

// Each sequence of a fixed seed passes check, and each record that the
// generator wrote in it is in the content of its area and decodes as its
// type; each record type appears whole and valid within
// FUZZ_RECORDS_SEQUENCES_MOST sequences.
@(test)
each_record_of_a_generated_sequence_decodes_as_its_type :: proc(t: ^testing.T) {
	if !testing.expect(t, fuzz_operation_sequence_start(), "the grammar of the generator does not start") {
		return
	}
	sequence := new(operation_sequence.Sequence)
	defer free(sequence)
	written := make([dynamic]Fuzz_Record_Written)
	defer delete(written)
	random := Fuzz_Random{state = FUZZ_RECORDS_TEST_SEED}
	seen: [Fuzz_Record_Type]int
	all_seen :: proc(seen: [Fuzz_Record_Type]int) -> bool {
		for count in seen {
			if count == 0 {
				return false
			}
		}
		return true
	}
	sequences := 0
	for sequences < FUZZ_RECORDS_SEQUENCES_MOST && !all_seen(seen) {
		clear(&written)
		operation_sequence_generate_random_written(&random, sequence, &written)
		sequences += 1
		bytes, accepted := operation_sequence_encode(sequence)
		testing.expectf(t, accepted, "check refuses the sequence %d of the generator", sequences)
		delete(bytes)
		for record, place in written {
			content := operation_sequence.area_content(sequence, record.area)
			if !testing.expectf(t, record.bytes >= 1 && record.bytes <= record.record_bytes && record.offset >= 0 && record.offset + record.bytes <= len(content), "the sequence %d: a %v of %d bytes at %d is not in the %d bytes of the content of its area", sequences, record.type, record.bytes, record.offset, len(content)) {
				continue
			}
			if record.step < 0 || record.step >= sequence.step_count || fuzz_record_overlapped(record, written[place + 1:]) || record.bytes < record.record_bytes {
				continue
			}
			problem := fuzz_record_form_problem(record.type, record.form, content[record.offset:][:record.bytes], record.object_pages)
			testing.expectf(t, problem == "", "the sequence %d, step %d: %s", sequences, record.step, problem)
			if record.form == .Valid {
				seen[record.type] += 1
			}
		}
	}
	for type in Fuzz_Record_Type {
		testing.expectf(t, seen[type] > 0, "no whole valid %v within %d sequences of the seed %x", type, sequences, FUZZ_RECORDS_TEST_SEED)
	}
}

// One seed gives the same bytes and the same records twice, and the
// records are written: the sequences hold some.
@(test)
the_records_of_a_seed_are_the_same_at_each_run :: proc(t: ^testing.T) {
	if !testing.expect(t, fuzz_operation_sequence_start(), "the grammar of the generator does not start") {
		return
	}
	first_sequence := new(operation_sequence.Sequence)
	defer free(first_sequence)
	second_sequence := new(operation_sequence.Sequence)
	defer free(second_sequence)
	first_written := make([dynamic]Fuzz_Record_Written)
	defer delete(first_written)
	second_written := make([dynamic]Fuzz_Record_Written)
	defer delete(second_written)
	first_random := Fuzz_Random{state = FUZZ_RECORDS_TEST_SEED}
	second_random := Fuzz_Random{state = FUZZ_RECORDS_TEST_SEED}
	records := 0
	RECORDS_WANTED :: 16
	for sequences := 0; sequences < FUZZ_RECORDS_SEQUENCES_MOST && records < RECORDS_WANTED; sequences += 1 {
		clear(&first_written)
		clear(&second_written)
		operation_sequence_generate_random_written(&first_random, first_sequence, &first_written)
		operation_sequence_generate_random_written(&second_random, second_sequence, &second_written)
		first_bytes, first_accepted := operation_sequence_encode(first_sequence)
		second_bytes, second_accepted := operation_sequence_encode(second_sequence)
		testing.expect(t, first_accepted && second_accepted, "check refuses a sequence of the generator")
		testing.expectf(t, slice.equal(first_bytes, second_bytes), "the sequence %d of one seed has two forms", sequences)
		testing.expectf(t, slice.equal(first_written[:], second_written[:]), "the sequence %d of one seed has two lists of records", sequences)
		delete(first_bytes)
		delete(second_bytes)
		records += len(first_written)
	}
	testing.expectf(t, records >= RECORDS_WANTED, "the seed wrote %d records", records)
}

// The room for a record: an area that the sequence does not have, an
// offset before or past the area, and a length of 0 give no bytes; a
// record past the content grows it with zeros and moves the content of the
// later areas; a record cuts at the end of the area and at the end of the
// room of the content; and the sequence still passes check.
@(test)
the_room_of_a_record_stops_at_its_area_and_at_the_content :: proc(t: ^testing.T) {
	sequence := new(operation_sequence.Sequence)
	defer free(sequence)
	sequence.area_count = 2
	sequence.areas[0] = {pages = 1, content_bytes = 4}
	sequence.areas[1] = {pages = 1, content_bytes = 3}
	copy(sequence.content[:], "abcdxyz")
	area_bytes := operation.PAGE_SIZE
	testing.expect_value(t, len(fuzz_area_content_reserve(sequence, 2, 0, 8)), 0)
	testing.expect_value(t, len(fuzz_area_content_reserve(sequence, -1, 0, 8)), 0)
	testing.expect_value(t, len(fuzz_area_content_reserve(sequence, 0, -1, 8)), 0)
	testing.expect_value(t, len(fuzz_area_content_reserve(sequence, 0, area_bytes, 8)), 0)
	testing.expect_value(t, len(fuzz_area_content_reserve(sequence, 0, 0, 0)), 0)
	testing.expect_value(t, sequence.areas[0].content_bytes, 4)
	testing.expect_value(t, string(operation_sequence.area_content(sequence, 1)), "xyz")

	// Inside the content: no growth.
	inside := fuzz_area_content_reserve(sequence, 0, 1, 2)
	testing.expect_value(t, string(inside), "bc")
	testing.expect_value(t, sequence.areas[0].content_bytes, 4)

	// Past the content: zeros, and the later area keeps its bytes.
	grown := fuzz_area_content_reserve(sequence, 0, 8, 4)
	testing.expect_value(t, len(grown), 4)
	testing.expect_value(t, sequence.areas[0].content_bytes, 12)
	testing.expect(t, slice.equal(operation_sequence.area_content(sequence, 0)[:4], transmute([]u8)string("abcd")))
	for value in operation_sequence.area_content(sequence, 0)[4:] {
		testing.expect_value(t, value, 0)
	}
	testing.expect_value(t, string(operation_sequence.area_content(sequence, 1)), "xyz")

	// The last byte of area 1 is past the room: the 12 and 3 bytes of the
	// two areas leave CONTENT_BYTES_MOST - 15, so the content of area 1
	// cannot reach it. No byte, and nothing changes.
	past_room := fuzz_area_content_reserve(sequence, 1, area_bytes - 1, 16)
	testing.expect_value(t, len(past_room), 0)
	testing.expect_value(t, sequence.areas[0].content_bytes, 12)
	testing.expect_value(t, string(operation_sequence.area_content(sequence, 1)), "xyz")
	bytes, accepted := operation_sequence_encode(sequence)
	testing.expect(t, accepted, "check refuses a sequence whose content grew")
	delete(bytes)

	// Cut at the end of the area, where the room allows it: the last byte
	// only.
	alone := new(operation_sequence.Sequence)
	defer free(alone)
	alone.area_count = 1
	alone.areas[0] = {pages = 1}
	last := fuzz_area_content_reserve(alone, 0, area_bytes - 1, 16)
	testing.expect_value(t, len(last), 1)
	testing.expect_value(t, alone.areas[0].content_bytes, area_bytes)
	alone_bytes, alone_accepted := operation_sequence_encode(alone)
	testing.expect(t, alone_accepted, "check refuses an area whose content fills it")
	delete(alone_bytes)

	// Cut at the end of the room of the content.
	full := new(operation_sequence.Sequence)
	defer free(full)
	full.area_count = 1
	full.areas[0] = {pages = 2, content_bytes = operation_sequence.CONTENT_BYTES_MOST}
	testing.expect_value(t, len(fuzz_area_content_reserve(full, 0, operation_sequence.CONTENT_BYTES_MOST, 16)), 0)
	testing.expect_value(t, len(fuzz_area_content_reserve(full, 0, operation_sequence.CONTENT_BYTES_MOST - 6, 16)), 6)
	testing.expect_value(t, full.areas[0].content_bytes, operation_sequence.CONTENT_BYTES_MOST)
}

// A step gets no record where its writer cannot write one: a count of 0
// or past the capacity, a count that is not a plain value, an address in
// no area or in the page after its area, a command that reads no record
// and a word that names no command. Then a table of one range of an area
// and a register image.
@(test)
a_step_gets_a_record_only_where_its_writer_can_write_one :: proc(t: ^testing.T) {
	if !testing.expect(t, fuzz_operation_sequence_start(), "the grammar of the generator does not start") {
		return
	}
	sequence := new(operation_sequence.Sequence)
	defer free(sequence)
	written := make([dynamic]Fuzz_Record_Written, context.temp_allocator)
	sequence.area_count = 1
	sequence.areas[0] = {pages = 2}
	ranges_place := operation_parameter_place(.Memory_Commit, "ranges")
	count_place := operation_parameter_place(.Memory_Commit, "count")
	memory_place := operation_parameter_place(.Memory_Commit, "memory")
	commit := operation_sequence.Sequence_Step{operation = u32(operation.Operation.Memory_Commit)}
	commit.arguments[memory_place] = {source = .Area_Handle, area = 0}
	commit.arguments[ranges_place] = {source = .Area_Address, area = 0}
	write_one :: proc(sequence: ^operation_sequence.Sequence, chosen: operation.Operation, item: operation_sequence.Sequence_Step, written: ^[dynamic]Fuzz_Record_Written) {
		item := item
		choices: Fuzz_Choices
		fuzz_step_records_write(&choices, sequence, chosen, &item, 0, written)
	}
	refused_counts := [?]operation_sequence.Argument{{source = .Value, value = 0}, {source = .Value, value = operation.RANGE_TABLE_CAPACITY + 1}, {source = .Value, value = max(u64)}, {source = .Budget}}
	for count in refused_counts {
		item := commit
		item.arguments[count_place] = count
		write_one(sequence, .Memory_Commit, item, &written)
	}
	item := commit
	item.arguments[count_place] = {source = .Value, value = 1}
	item.arguments[ranges_place] = {source = .Value}
	write_one(sequence, .Memory_Commit, item, &written)
	item.arguments[ranges_place] = {source = .Area_Address, area = 0, offset = u64(2 * operation.PAGE_SIZE)}
	write_one(sequence, .Memory_Commit, item, &written)
	testing.expect_value(t, len(written), 0)
	testing.expect_value(t, sequence.areas[0].content_bytes, 0)

	command_place := operation_parameter_place(.Thread_Control, "command")
	address_place := operation_parameter_place(.Thread_Control, "address")
	control := operation_sequence.Sequence_Step{operation = u32(operation.Operation.Thread_Control)}
	control.arguments[address_place] = {source = .Area_Address, area = 0}
	no_record := [?]u64{u64(operation.Thread_Control_Command.Read_Registers), u64(max(operation.Thread_Control_Command)) + 1, max(u64)}
	for command in no_record {
		control.arguments[command_place] = {source = .Value, value = command}
		write_one(sequence, .Thread_Control, control, &written)
	}
	testing.expect_value(t, len(written), 0)
	testing.expect_value(t, sequence.areas[0].content_bytes, 0)

	item.arguments[ranges_place] = {source = .Area_Address, area = 0}
	write_one(sequence, .Memory_Commit, item, &written)
	control.arguments[command_place] = {source = .Value, value = u64(operation.Thread_Control_Command.Write_Registers)}
	write_one(sequence, .Thread_Control, control, &written)
	if testing.expect_value(t, len(written), 2) {
		testing.expect_value(t, written[0].type, Fuzz_Record_Type.Page_Range_Table)
		testing.expect_value(t, written[0].object_pages, 2)
		testing.expect_value(t, written[0].bytes, size_of(operation.Page_Range))
		testing.expect_value(t, written[1].type, Fuzz_Record_Type.Register_Image)
		testing.expect_value(t, written[1].bytes, size_of(operation.Thread_Registers))
		problem := fuzz_record_form_problem(.Register_Image, written[1].form, operation_sequence.area_content(sequence, 0)[:size_of(operation.Thread_Registers)], 0)
		testing.expect_value(t, problem, "")
	}
}

// The table refuses a table of ranges whose next parameter is not a count,
// and the records of the commands of Thread_Control on another operation.
@(test)
the_table_of_the_address_parameters_refuses_a_record_in_the_wrong_place :: proc(t: ^testing.T) {
	no_count := fuzz_address_parameters
	moved := fuzz_address_parameters
	for &row in no_count {
		if row.operation == .Program_State {
			row.record = .Page_Range_Table
		}
	}
	for &row in moved {
		if row.operation == .Memory_Commit {
			row.record = .Thread_Control_Command
		}
	}
	testing.expect(t, fuzz_address_parameters_problem(no_count[:]) != "", "a table of ranges with no count is taken")
	testing.expect(t, fuzz_address_parameters_problem(moved[:]) != "", "the records of Thread_Control on Memory_Commit are taken")
	testing.expect_value(t, fuzz_address_parameters_problem(fuzz_address_parameters[:]), "")
}
