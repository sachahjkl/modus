#+build !freestanding
package system

import "core:strings"
import "core:testing"
import "modus:contract/cut_mark"
import op "modus:contract/operation"
import "modus:contract/value_kinds"

// The write of the texts of the text views of a fact: a record of a u64
// then the views, as a fact type has them, and room for the out-of-line
// area. Each text reads back through value_kinds.text_view_read, which a
// reader calls.
@(private = "file")
views_write :: proc(texts: []string) -> (values: []u8, record_size: int, area_count: int) {
	record_size = 8 + len(texts) * value_kinds.TEXT_VIEW_BYTES
	values = make([]u8, record_size + op.LOG_FACT_TEXT_AREA_BYTES_MOST, context.temp_allocator)
	written: bool
	area_count, written = log_fact_text_views_write(values, record_size, texts)
	assert(written)
	return
}

@(private = "file")
view_text :: proc(values: []u8, record_size, area_count, index: int) -> (text: string, ok: bool) {
	views_start := record_size - (record_size - 8)
	view := values[views_start + index * value_kinds.TEXT_VIEW_BYTES:][:value_kinds.TEXT_VIEW_BYTES]
	read := value_kinds.text_view_read(view, values[record_size:][:area_count]) or_return
	return string(read), true
}

// The edges of the length of one text: 0, 1, 4, 12 in the view; 13, the
// first out of line; the room that the first record leaves after the
// record and one byte past it, which takes a second record; the bound of
// the area, and one byte past it, which is cut with its mark.
@(test)
the_edges_of_a_text_view_are_written :: proc(t: ^testing.T) {
	record_size := 8 + value_kinds.TEXT_VIEW_BYTES
	room_in_first := op.LOG_FACT_VALUE_CAPACITY - record_size
	Case :: struct {
		length:  int,
		area:    int, // The bytes of the area after the write.
		records: int, // The records of the fact.
	}
	cases := [?]Case {
		{0, 0, 1},
		{1, 0, 1},
		{4, 0, 1},
		{value_kinds.TEXT_VIEW_INLINE_BYTES_MOST, 0, 1},
		{value_kinds.TEXT_VIEW_INLINE_BYTES_MOST + 1, value_kinds.TEXT_VIEW_INLINE_BYTES_MOST + 1, 1},
		{room_in_first, room_in_first, 1},
		{room_in_first + 1, room_in_first + 1, 2},
		// A record of 24 bytes and the full area: 1048 bytes, 8 records.
		{op.LOG_FACT_TEXT_AREA_BYTES_MOST, op.LOG_FACT_TEXT_AREA_BYTES_MOST, op.LOG_FACT_RECORDS_MOST - 1},
	}
	for item in cases {
		text := strings.repeat("a", item.length, context.temp_allocator)
		values, size, area := views_write({text})
		read, ok := view_text(values, size, area, 0)
		testing.expectf(t, ok && read == text, "a text of %d bytes reads back %d bytes", item.length, len(read))
		testing.expectf(t, area == item.area, "a text of %d bytes takes %d bytes of the area, not %d", item.length, area, item.area)
		testing.expectf(t, op.log_fact_part_count(size + area) == item.records, "a text of %d bytes takes %d records", item.length, op.log_fact_part_count(size + area))
	}
	// One byte past the bound: the area holds the start and the mark,
	// never a text that looks whole.
	past := strings.repeat("b", op.LOG_FACT_TEXT_AREA_BYTES_MOST + 1, context.temp_allocator)
	values, size, area := views_write({past})
	read, ok := view_text(values, size, area, 0)
	testing.expect(t, ok && area == op.LOG_FACT_TEXT_AREA_BYTES_MOST && len(read) == op.LOG_FACT_TEXT_AREA_BYTES_MOST)
	testing.expect(t, strings.has_suffix(read, cut_mark.MARK_END) && strings.contains(read, cut_mark.MARK_START))
	testing.expect(t, op.log_fact_part_count(size + area) == op.LOG_FACT_RECORDS_MOST - 1)
	// The most records: a record of 136 bytes, a u64 and 8 views, past
	// the 128 bytes that leave the full area in 8 records, and the full
	// area: 1160 bytes, 9 records, within the bound of the values.
	most_texts: [8]string
	most_texts[7] = strings.repeat("c", op.LOG_FACT_TEXT_AREA_BYTES_MOST, context.temp_allocator)
	most_values, most_size, most_area := views_write(most_texts[:])
	most_read, most_ok := view_text(most_values, most_size, most_area, 7)
	testing.expect(t, most_ok && most_read == most_texts[7] && most_size == 136)
	testing.expect(t, op.log_fact_part_count(most_size + most_area) == op.LOG_FACT_RECORDS_MOST && most_size + most_area <= op.LOG_FACT_VALUES_MOST)
}

// Two and three views in one fact: each long text after the one before
// in the area, a short text in its view between them, and a text that
// the full area has no room for keeps its start and the mark in its view.
@(test)
several_text_views_share_the_area :: proc(t: ^testing.T) {
	first := strings.repeat("x", 100, context.temp_allocator)
	third := "/modules/a/path/of/twenty"
	values, size, area := views_write({first, "short", third})
	for text, index in ([3]string{first, "short", third}) {
		read, ok := view_text(values, size, area, index)
		testing.expectf(t, ok && read == text, "the view %d reads %q", index, read)
	}
	testing.expect_value(t, area, len(first) + len(third))
	two_values, two_size, two_area := views_write({"", first})
	read, ok := view_text(two_values, two_size, two_area, 1)
	testing.expect(t, ok && read == first && two_area == len(first))
	empty, empty_ok := view_text(two_values, two_size, two_area, 0)
	testing.expect(t, empty_ok && empty == "")
	// The area full after the first text: the second keeps its start and
	// as much of the mark as its view holds.
	full := strings.repeat("y", op.LOG_FACT_TEXT_AREA_BYTES_MOST, context.temp_allocator)
	full_values, full_size, full_area := views_write({full, third})
	second, second_ok := view_text(full_values, full_size, full_area, 1)
	testing.expect(t, second_ok && len(second) <= value_kinds.TEXT_VIEW_INLINE_BYTES_MOST && second != third[:len(second)] && full_area == op.LOG_FACT_TEXT_AREA_BYTES_MOST)
}

// More texts than the record has views is refused, and nothing is
// written: a record of fewer bytes than the views, one text more than the
// views with a fixed field that is not zero at its place, and the record
// of one view given three texts. The record and the area keep each byte.
@(test)
more_texts_than_views_are_refused :: proc(t: ^testing.T) {
	small := make([]u8, 8 + op.LOG_FACT_TEXT_AREA_BYTES_MOST, context.temp_allocator)
	area, written := log_fact_text_views_write(small, 8, {"a"})
	testing.expect(t, !written && area == 0)
	// Two u64 then one view: two texts would take the two u64 for a view,
	// and the second one is not zero.
	record_size := 16 + value_kinds.TEXT_VIEW_BYTES
	values := make([]u8, record_size + op.LOG_FACT_TEXT_AREA_BYTES_MOST, context.temp_allocator)
	values[8] = 7
	long := strings.repeat("x", 40, context.temp_allocator)
	before := make([]u8, len(values), context.temp_allocator)
	copy(before, values)
	area, written = log_fact_text_views_write(values, record_size, {long, "b"})
	testing.expect(t, !written && area == 0 && string(values) == string(before))
	area, written = log_fact_text_views_write(values, record_size, {"a", "b", "c"})
	testing.expect(t, !written && area == 0 && string(values) == string(before))
	// The count of the views, the last case: written.
	area, written = log_fact_text_views_write(values, record_size, {long})
	testing.expect(t, written && area == len(long) && values[8] == 7)
}
