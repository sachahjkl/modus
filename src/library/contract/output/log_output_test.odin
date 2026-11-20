#+build !freestanding
package output

import "core:testing"
import "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The fields of Log_Output_Record as the tool writes them for a module that
// declares the record: each one after the one before, from the first byte.
@(private = "file")
log_output_test_fields :: proc() -> [7]Test_Field {
	return {
		{name = "time", type = .Integer, unsigned = true},
		{name = "text_count", type = .Integer, unsigned = true, detail = 4},
		{name = "level", type = .Integer, unsigned = true, detail = 1, kind = .Status, contract_enum = .Log_Level},
		{name = "form", type = .Integer, unsigned = true, detail = 1, kind = .Status, contract_enum = .Log_Record_Form},
		{name = "more", type = .Integer, unsigned = true, detail = 1},
		{name = "run_count", type = .Integer, unsigned = true, detail = 1},
		{name = "body", type = .Bytes, detail = value_kinds.LOG_BODY_FIELD_BYTES, kind = .Log_Body},
	}
}

// The description file of the record output log does not fit one byte
// short, nor in no byte; it fits whole.
@(test)
a_log_output_description_that_does_not_fit_is_refused :: proc(t: ^testing.T) {
	into := make([]u8, DESCRIPTION_FILE_BYTES_MOST, context.temp_allocator)
	size, ok := log_output_file_write(into)
	testing.expect(t, ok && size > 0 && size <= DESCRIPTION_FILE_BYTES_MOST)
	_, short_ok := log_output_file_write(into[:size - 1])
	testing.expect(t, !short_ok)
	_, empty_ok := log_output_file_write(nil)
	testing.expect(t, !empty_ok)
}

// The description file of the contract is the record of a module that
// declares Log_Output_Record: the type check finds them equal, a
// description file written again from it is the same bytes, and a
// record of one field changed differs.
@(test)
the_log_output_description_is_the_record_of_the_contract :: proc(t: ^testing.T) {
	into := make([]u8, DESCRIPTION_FILE_BYTES_MOST, context.temp_allocator)
	size, ok := log_output_file_write(into)
	testing.expect(t, ok)
	if !ok {
		return
	}
	file := into[:size]
	described, taken := module.record_stream_type(file, DESCRIPTION_RECORD_INDEX)
	testing.expect(t, taken)
	testing.expect_value(t, described.size, u32(size_of(Log_Output_Record)))
	testing.expect_value(t, described.field_count, u32(7))
	fields := log_output_test_fields()
	declared := typed_file(LOG_OUTPUT_RECORD_NAME, fields[:])
	difference, part := record_descriptions_compare(file, DESCRIPTION_RECORD_INDEX, declared, 1)
	testing.expectf(t, difference == .Equal, "the description of the contract differs from the declared record: %v at %d", difference, part)
	again := make([]u8, DESCRIPTION_FILE_BYTES_MOST, context.temp_allocator)
	again_size, again_ok := description_file_write(again, file, DESCRIPTION_RECORD_INDEX)
	testing.expect(t, again_ok && again_size == size && string(again[:again_size]) == string(file))
	// The form as a plain integer: the type check refuses it.
	changed := fields
	changed[3].kind, changed[3].contract_enum = .Plain, .None
	other := typed_file(LOG_OUTPUT_RECORD_NAME, changed[:])
	other_difference, _ := record_descriptions_compare(file, DESCRIPTION_RECORD_INDEX, other, 1)
	testing.expect(t, other_difference != .Equal)
}

// The border of a text record of log refuses another form, a count past
// the text of a log record, and a byte past the count that is not 0; it
// takes a count of 0 and the largest count.
@(test)
the_text_of_a_log_record_passes_its_border :: proc(t: ^testing.T) {
	record: Log_Output_Record
	record.form = .Fact
	_, fact_ok := log_output_text(&record)
	testing.expect(t, !fact_ok)
	record.form = .Text
	record.text_count = op.LOG_TEXT_CAPACITY + 1
	_, past_ok := log_output_text(&record)
	testing.expect(t, !past_ok)
	record.text_count = max(u32)
	_, largest_ok := log_output_text(&record)
	testing.expect(t, !largest_ok)
	record.text_count = 2
	record.body[LOG_OUTPUT_TEXT_OFFSET + 2] = 'x'
	_, trailing_ok := log_output_text(&record)
	testing.expect(t, !trailing_ok)
	record.body[LOG_OUTPUT_TEXT_OFFSET + 2] = 0
	record.body[LOG_OUTPUT_TEXT_OFFSET + 0] = 'o'
	record.body[LOG_OUTPUT_TEXT_OFFSET + 1] = 'k'
	text, ok := log_output_text(&record)
	testing.expect(t, ok && text == "ok")
	record.text_count = 0
	record.body = {}
	empty, empty_ok := log_output_text(&record)
	testing.expect(t, empty_ok && empty == "")
	record.text_count = op.LOG_TEXT_CAPACITY
	for &value in record.body[LOG_OUTPUT_TEXT_OFFSET:] {
		value = 'a'
	}
	whole, whole_ok := log_output_text(&record)
	testing.expect(t, whole_ok && len(whole) == op.LOG_TEXT_CAPACITY)
}

// The border of a fact record of log refuses another form, a text count or
// runs beside a fact, a count of values past a part, no part, a count of
// parts past the most, and a part past its count.
@(test)
the_fact_of_a_log_record_passes_its_border :: proc(t: ^testing.T) {
	body := make([]u8, op.LOG_FACT_HEAD_BYTES + 8, context.temp_allocator)
	body[32] = 7 // The first byte of the key.
	good, made := log_output_fact_part(body, 0, .Info, 1)
	testing.expect(t, made)
	_, good_ok := log_output_fact(&good)
	testing.expect(t, good_ok)
	broken := [?]proc(record: ^Log_Output_Record) {
		proc(record: ^Log_Output_Record) {record.form = .Text},
		proc(record: ^Log_Output_Record) {record.text_count = 1},
		proc(record: ^Log_Output_Record) {record.run_count = 1},
		proc(record: ^Log_Output_Record) {(^op.Log_Fact)(&record.body[0]).value_count = op.LOG_FACT_VALUE_CAPACITY + 1},
		proc(record: ^Log_Output_Record) {(^op.Log_Fact)(&record.body[0]).part_count = 0},
		proc(record: ^Log_Output_Record) {(^op.Log_Fact)(&record.body[0]).part_count = u8(op.LOG_FACT_RECORDS_MOST + 1)},
		proc(record: ^Log_Output_Record) {(^op.Log_Fact)(&record.body[0]).part = 1},
	}
	for change, number in broken {
		record := good
		change(&record)
		_, ok := log_output_fact(&record)
		testing.expectf(t, !ok, "the change %d of a fact passes the border", number)
	}
}

// A text is cut as the kernel cuts it: at most LOG_TEXT_CAPACITY bytes, a
// part ends after a whole character, more joins the parts. A start
// outside the text gives an empty record.
@(test)
a_text_of_log_is_cut_as_the_kernel_cuts_it :: proc(t: ^testing.T) {
	// A start before the text and one past it.
	text := make([]u8, op.LOG_TEXT_CAPACITY + 1, context.temp_allocator)
	for &value in text {
		value = 'a'
	}
	for start in ([?]int{-1, len(text) + 1}) {
		record, next := log_output_text_part(text, nil, start, .Info, 0)
		testing.expectf(t, next == len(text) && record.text_count == 0, "the start %d gives a part", start)
	}
	// The empty text: one record of no byte.
	empty_record, empty_next := log_output_text_part(nil, nil, 0, .Info, 0)
	testing.expect(t, empty_next == 0 && empty_record.text_count == 0 && empty_record.more == 0 && empty_record.form == .Text)
	// The capacity whole: one record.
	whole, whole_next := log_output_text_part(text[:op.LOG_TEXT_CAPACITY], nil, 0, .Warning, 5)
	testing.expect(t, whole_next == op.LOG_TEXT_CAPACITY && whole.text_count == op.LOG_TEXT_CAPACITY && whole.more == 0 && whole.level == .Warning && whole.time == 5)
	// One byte past it: two records, joined by more.
	first, first_next := log_output_text_part(text, nil, 0, .Info, 0)
	testing.expect(t, first_next == op.LOG_TEXT_CAPACITY && first.more == 1)
	second, second_next := log_output_text_part(text, nil, first_next, .Info, 0)
	testing.expect(t, second_next == len(text) && second.text_count == 1 && second.more == 0)
	// A character of two bytes over the cut goes whole to the next part.
	split := make([]u8, op.LOG_TEXT_CAPACITY + 1, context.temp_allocator)
	for &value in split[:op.LOG_TEXT_CAPACITY - 1] {
		value = 'a'
	}
	split[op.LOG_TEXT_CAPACITY - 1], split[op.LOG_TEXT_CAPACITY] = 0xC3, 0xA9
	cut, cut_next := log_output_text_part(split, nil, 0, .Info, 0)
	testing.expect(t, cut_next == op.LOG_TEXT_CAPACITY - 1 && cut.more == 1)
	rest, rest_next := log_output_text_part(split, nil, cut_next, .Info, 0)
	rest_text, rest_ok := log_output_text(&rest)
	testing.expect(t, rest_next == len(split) && rest_ok && rest_text == "é")
	// A value run in the first part only.
	runs := [1]value_kinds.Value_Run_In_Call{{start = 10, length = 3, kind = u8(value_kinds.Value_Kind.Number)}}
	with_run, run_next := log_output_text_part(text, runs[:], 0, .Info, 0)
	testing.expect(t, with_run.run_count == 1)
	after_run, _ := log_output_text_part(text, runs[:], run_next, .Info, 0)
	testing.expect(t, after_run.run_count == 0)
}

// A fact is cut in parts of LOG_FACT_VALUE_CAPACITY values: a body shorter
// than the head, one past the most bytes of a call, and a part outside the
// parts are refused; a fact of exactly one part and one of one value more
// give one and two parts, with the head of the writer in each.
@(test)
a_fact_of_log_is_cut_as_the_kernel_cuts_it :: proc(t: ^testing.T) {
	short := make([]u8, op.LOG_FACT_HEAD_BYTES - 1, context.temp_allocator)
	_, short_ok := log_output_fact_part(short, 0, .Info, 0)
	testing.expect(t, !short_ok)
	long := make([]u8, op.LOG_FACT_CALL_BYTES_MOST + 1, context.temp_allocator)
	_, long_ok := log_output_fact_part(long, 0, .Info, 0)
	testing.expect(t, !long_ok)
	one := make([]u8, op.LOG_FACT_HEAD_BYTES + op.LOG_FACT_VALUE_CAPACITY, context.temp_allocator)
	one[0], one[32] = 0xAB, 9 // The first byte of the module hash and of the key.
	for part in ([?]int{-1, 1}) {
		_, part_ok := log_output_fact_part(one, part, .Info, 0)
		testing.expectf(t, !part_ok, "the part %d of a fact of one part is given", part)
	}
	record, ok := log_output_fact_part(one, 0, .Error, 3)
	fact, fact_ok := log_output_fact(&record)
	testing.expect(t, ok && fact_ok && record.more == 0 && record.level == .Error && record.time == 3)
	testing.expect(t, fact.part == 0 && fact.part_count == 1 && fact.value_count == op.LOG_FACT_VALUE_CAPACITY && fact.module_hash[0] == 0xAB && fact.key == 9)
	two := make([]u8, len(one) + 1, context.temp_allocator)
	copy(two, one)
	two[len(two) - 1] = 0x5A
	first, first_ok := log_output_fact_part(two, 0, .Info, 0)
	second, second_ok := log_output_fact_part(two, 1, .Info, 0)
	first_fact, _ := log_output_fact(&first)
	second_fact, second_fact_ok := log_output_fact(&second)
	testing.expect(t, first_ok && second_ok && second_fact_ok && first.more == 1 && second.more == 0)
	testing.expect(t, first_fact.part_count == 2 && second_fact.part == 1 && second_fact.value_count == 1 && second_fact.values[0] == 0x5A && second_fact.key == 9)
}

// The gap of the records that the writer lost: a count of 0 changes
// nothing, a new gap starts at the first lost serial, a gap that waits
// grows, and a count that would pass the largest count of the ring leaves
// the gap and says so, with a condition and without, at the edges.
@(test)
a_gap_of_lost_records_counts_to_its_largest :: proc(t: ^testing.T) {
	waiting := Gap_State{count = 3, first = 40}
	unchanged, unchanged_step := gap_after_lost_records(waiting, 43, 0, false)
	testing.expect(t, unchanged == waiting && unchanged_step == .Counted)
	started, started_step := gap_after_lost_records({}, 50, 1, false)
	testing.expect(t, started == Gap_State{count = 1, first = 50} && started_step == .Counted)
	grown, grown_step := gap_after_lost_records(waiting, 43, 5, false)
	testing.expect(t, grown == Gap_State{count = 8, first = 40} && grown_step == .Counted)
	for filtered in ([?]bool{false, true}) {
		most := gap_count_most(filtered)
		full, full_step := gap_after_lost_records({}, 0, most, filtered)
		testing.expectf(t, full.count == most && full_step == .Counted, "the largest count from no gap, filtered %v", filtered)
		past, past_step := gap_after_lost_records({count = 1, first = 7}, 8, most, filtered)
		testing.expectf(t, past == Gap_State{count = 1, first = 7} && past_step == .Past_The_Count, "one past the largest count, filtered %v", filtered)
		// The serials after the gap wrap past the top of the 32 bits.
		last, last_step := gap_after_lost_records({count = most - 1, first = 7}, 7 + (most - 1), 1, filtered)
		testing.expectf(t, last.count == most && last_step == .Counted, "the last record of the largest count, filtered %v", filtered)
		over, over_step := gap_after_lost_records({count = most, first = 7}, 7 + most, 1, filtered)
		testing.expectf(t, over.count == most && over_step == .Past_The_Count, "a gap at its largest count, filtered %v", filtered)
	}
}

// Lost records that do not follow the gap that waits: refused on a ring
// with no condition, before and after the gap and at a distance of one,
// with the gap unchanged; counted on a ring with a condition, whose reader
// takes serials that move forward by any count.
@(test)
a_gap_of_lost_records_that_does_not_follow_its_gap :: proc(t: ^testing.T) {
	waiting := Gap_State{count = 3, first = 40}
	for first in ([?]u32{42, 44, 39, 0, max(u32)}) {
		after, step := gap_after_lost_records(waiting, first, 1, false)
		testing.expectf(t, after == waiting && step == .Not_Contiguous, "the lost records from %d after the gap of 40 to 42 gave %v", first, step)
	}
	skipped, skipped_step := gap_after_lost_records(waiting, 45, 2, true)
	testing.expect(t, skipped == Gap_State{count = 5, first = 40} && skipped_step == .Counted)
	// The gap at the top of the serials, and the lost records after the wrap.
	top := Gap_State{count = 2, first = max(u32) - 1}
	wrapped, wrapped_step := gap_after_lost_records(top, 0, 1, false)
	testing.expect(t, wrapped == Gap_State{count = 3, first = max(u32) - 1} && wrapped_step == .Counted)
}
