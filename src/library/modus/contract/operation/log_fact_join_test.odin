#+build !freestanding
package operation

import "core:testing"

// The writer of the records of these tests, and another process.
@(private = "file")
JOIN_WRITER :: u64(3) << 32 | 7
@(private = "file")
JOIN_OTHER_WRITER :: u64(4) << 32 | 9
@(private = "file")
JOIN_KEY :: u64(0xfa0a_df38_a559_f4d1)

// The value bytes of a fact of `count` bytes: byte n is n + 1, cut to a
// byte, so a byte out of its place shows.
@(private = "file")
join_values :: proc(count: int) -> [LOG_FACT_VALUES_MOST]u8 {
	values: [LOG_FACT_VALUES_MOST]u8
	for index in 0 ..< count {
		values[index] = u8(index + 1)
	}
	return values
}

// join_part gives the record `part` of a fact of `count` value bytes, at a
// number, as the kernel cuts it.
@(private = "file")
join_part :: proc(values: ^[LOG_FACT_VALUES_MOST]u8, count, part: int, number: u64, writer := JOIN_WRITER, key := JOIN_KEY) -> Log_Fact_Part {
	start := part * LOG_FACT_VALUE_CAPACITY
	end := min(count, start + LOG_FACT_VALUE_CAPACITY)
	hash: [32]u8
	hash[0] = 0x1a
	return {number = number, writer = writer, module_hash = hash, key = key, part = part, part_count = log_fact_part_count(count), values = values[start:max(start, end)]}
}

// The count of the records of a fact: the edges of one record, of two, and
// of the bound.
@(test)
the_records_of_a_fact_are_counted :: proc(t: ^testing.T) {
	testing.expect_value(t, log_fact_part_count(0), 1)
	testing.expect_value(t, log_fact_part_count(1), 1)
	testing.expect_value(t, log_fact_part_count(LOG_FACT_VALUE_CAPACITY), 1)
	testing.expect_value(t, log_fact_part_count(LOG_FACT_VALUE_CAPACITY + 1), 2)
	testing.expect_value(t, log_fact_part_count(2 * LOG_FACT_VALUE_CAPACITY), 2)
	testing.expect_value(t, log_fact_part_count(LOG_FACT_VALUES_MOST), LOG_FACT_RECORDS_MOST)
	testing.expect_value(t, log_fact_part_count(LOG_FACT_RECORDS_MOST * LOG_FACT_VALUE_CAPACITY + 1), LOG_FACT_RECORDS_MOST + 1)
	testing.expect_value(t, LOG_FACT_CALL_BYTES_MOST, LOG_FACT_HEAD_BYTES + LOG_FACT_VALUES_MOST)
}

// Each record that a reader cannot join is refused, and gives no whole
// fact: a missing middle, a missing first, an interleaved record of
// another process, a record of another fact, a part with no first, a
// count of records of 0 and one past the bound, a part past its count, a
// record before the last that is not full, and a text record of the same
// process inside a fact. After each refusal, the join holds no open fact.
@(test)
a_fact_that_cannot_be_joined_is_refused :: proc(t: ^testing.T) {
	COUNT :: 3 * LOG_FACT_VALUE_CAPACITY + 10
	values := join_values(COUNT)

	// A missing middle: the parts 0 and 2, by numbers that follow each
	// other, and by numbers with a hole.
	{
		join: Log_Fact_Join
		whole, fault := log_fact_join_take(&join, join_part(&values, COUNT, 0, 10))
		testing.expect(t, !whole && fault == .None && join.open)
		whole, fault = log_fact_join_take(&join, join_part(&values, COUNT, 2, 11))
		testing.expect(t, !whole && fault == .Missing_Part && !join.open)
		join = {}
		_, _ = log_fact_join_take(&join, join_part(&values, COUNT, 0, 10))
		whole, fault = log_fact_join_take(&join, join_part(&values, COUNT, 1, 12))
		testing.expect(t, !whole && fault == .Missing_Part && !join.open)
	}
	// A missing first: a part after the first with no open fact.
	{
		join: Log_Fact_Join
		whole, fault := log_fact_join_take(&join, join_part(&values, COUNT, 1, 11))
		testing.expect(t, !whole && fault == .Part_Without_First && !join.open)
		whole, fault = log_fact_join_take(&join, join_part(&values, COUNT, 3, 13))
		testing.expect(t, !whole && fault == .Part_Without_First && !join.open)
	}
	// An interleaved record of another process, with the next number: a
	// part of its own fact, and a record that is no fact.
	{
		join: Log_Fact_Join
		_, _ = log_fact_join_take(&join, join_part(&values, COUNT, 0, 10))
		whole, fault := log_fact_join_take(&join, join_part(&values, COUNT, 1, 11, writer = JOIN_OTHER_WRITER))
		testing.expect(t, !whole && fault == .Other_Process && !join.open)
		join = {}
		_, _ = log_fact_join_take(&join, join_part(&values, COUNT, 0, 10))
		testing.expect_value(t, log_fact_join_other_record(&join, 11, JOIN_OTHER_WRITER), Log_Fact_Join_Fault.Other_Process)
		testing.expect(t, !join.open)
	}
	// A text record of the same process inside a fact, and a record of
	// another fact of the same process.
	{
		join: Log_Fact_Join
		_, _ = log_fact_join_take(&join, join_part(&values, COUNT, 0, 10))
		testing.expect_value(t, log_fact_join_other_record(&join, 11, JOIN_WRITER), Log_Fact_Join_Fault.Missing_Part)
		join = {}
		_, _ = log_fact_join_take(&join, join_part(&values, COUNT, 0, 10))
		whole, fault := log_fact_join_take(&join, join_part(&values, COUNT, 1, 11, key = JOIN_KEY + 1))
		testing.expect(t, !whole && fault == .Other_Fact && !join.open)
	}
	// A count of records of 0, one past the bound, the largest count, and a
	// part past its count.
	{
		join: Log_Fact_Join
		bad_counts := [?]int{0, LOG_FACT_RECORDS_MOST + 1, max(int)}
		for part_count in bad_counts {
			record := join_part(&values, COUNT, 0, 10)
			record.part_count = part_count
			whole, fault := log_fact_join_take(&join, record)
			testing.expectf(t, !whole && fault == .Part_Count && !join.open, "the count of records %d is taken", part_count)
		}
		record := join_part(&values, COUNT, 0, 10)
		record.part = record.part_count
		whole, fault := log_fact_join_take(&join, record)
		testing.expect(t, !whole && fault == .Part_Count)
		record.part = -1
		whole, fault = log_fact_join_take(&join, record)
		testing.expect(t, !whole && fault == .Part_Count)
	}
	// A first record that is not full, a middle record that is not full,
	// and a last record of more bytes than a record holds.
	{
		join: Log_Fact_Join
		short_first := join_part(&values, COUNT, 0, 10)
		short_first.values = short_first.values[:LOG_FACT_VALUE_CAPACITY - 1]
		whole, fault := log_fact_join_take(&join, short_first)
		testing.expect(t, !whole && fault == .Value_Count && !join.open)
		_, _ = log_fact_join_take(&join, join_part(&values, COUNT, 0, 10))
		short_middle := join_part(&values, COUNT, 1, 11)
		short_middle.values = short_middle.values[:1]
		whole, fault = log_fact_join_take(&join, short_middle)
		testing.expect(t, !whole && fault == .Value_Count && !join.open)
		large: [LOG_FACT_VALUE_CAPACITY + 1]u8
		single := join_part(&values, 1, 0, 20)
		single.values = large[:]
		whole, fault = log_fact_join_take(&join, single)
		testing.expect(t, !whole && fault == .Value_Count)
	}
}

// The bound of the values of a fact holds on the reader too: nine full
// records pass it, and the last of them is refused with no byte past the
// values; a last record of the rest of the bound is whole, and one byte
// more is refused. The largest number has no next one: a record at 0 after
// it is no part of its fact. A read that ends with a fact open, and did
// not stop at its page, lost its next record; one that stopped at its page
// keeps the fact open.
@(test)
the_bounds_of_a_join_hold :: proc(t: ^testing.T) {
	full: [LOG_FACT_VALUE_CAPACITY]u8
	for &value in full {
		value = 0xff
	}
	hash: [32]u8
	part_of :: proc(full: []u8, hash: [32]u8, number: u64, part, count: int, last_bytes: int) -> Log_Fact_Part {
		values := full
		if part == count - 1 {
			values = full[:last_bytes]
		}
		return {number = number, writer = JOIN_WRITER, module_hash = hash, key = JOIN_KEY, part = part, part_count = count, values = values}
	}
	rest := LOG_FACT_VALUES_MOST - (LOG_FACT_RECORDS_MOST - 1) * LOG_FACT_VALUE_CAPACITY
	Case :: struct {
		last_bytes: int,
		whole:      bool,
	}
	for item in ([3]Case{{LOG_FACT_VALUE_CAPACITY, false}, {rest + 1, false}, {rest, true}}) {
		join: Log_Fact_Join
		for part in 0 ..< LOG_FACT_RECORDS_MOST - 1 {
			whole, fault := log_fact_join_take(&join, part_of(full[:], hash, u64(10 + part), part, LOG_FACT_RECORDS_MOST, item.last_bytes))
			testing.expect(t, !whole && fault == .None)
		}
		whole, fault := log_fact_join_take(&join, part_of(full[:], hash, u64(10 + LOG_FACT_RECORDS_MOST - 1), LOG_FACT_RECORDS_MOST - 1, LOG_FACT_RECORDS_MOST, item.last_bytes))
		testing.expectf(t, whole == item.whole && (fault == .None) == item.whole && join.value_count <= LOG_FACT_VALUES_MOST, "a last record of %d bytes gave %v, whole %v", item.last_bytes, fault, whole)
		if item.whole {
			testing.expect_value(t, join.value_count, LOG_FACT_VALUES_MOST)
		} else {
			testing.expect(t, !join.open)
		}
	}
	// The largest number, then a record at 0.
	{
		join: Log_Fact_Join
		_, _ = log_fact_join_take(&join, part_of(full[:], hash, max(u64), 0, 2, 1))
		testing.expect(t, join.open)
		whole, fault := log_fact_join_take(&join, part_of(full[:], hash, 0, 1, 2, 1))
		testing.expect(t, !whole && fault == .Missing_Part && !join.open)
	}
	// The end of a read: an open fact, at the page and past it.
	{
		join: Log_Fact_Join
		_, _ = log_fact_join_take(&join, part_of(full[:], hash, 10, 0, 2, 1))
		testing.expect_value(t, log_fact_join_end(&join, true), Log_Fact_Join_Fault.None)
		testing.expect(t, join.open)
		testing.expect_value(t, log_fact_join_end(&join, false), Log_Fact_Join_Fault.Missing_Part)
		testing.expect(t, !join.open)
		testing.expect_value(t, log_fact_join_end(&join, false), Log_Fact_Join_Fault.None)
	}
}

// A fact of one record after a broken fact is whole, with the fault of
// the broken fact; a first record after a broken fact opens a new fact.
@(test)
a_fact_after_a_broken_fact_is_joined :: proc(t: ^testing.T) {
	COUNT :: 2 * LOG_FACT_VALUE_CAPACITY
	values := join_values(COUNT)
	join: Log_Fact_Join
	_, _ = log_fact_join_take(&join, join_part(&values, COUNT, 0, 10))
	small := join_values(5)
	whole, fault := log_fact_join_take(&join, join_part(&small, 5, 0, 11))
	testing.expect(t, whole && fault == .Missing_Part && join.value_count == 5 && join.values[4] == 5)
	_, _ = log_fact_join_take(&join, join_part(&values, COUNT, 0, 20))
	whole, fault = log_fact_join_take(&join, join_part(&values, COUNT, 0, 21))
	testing.expect(t, !whole && fault == .Missing_Part && join.open)
	whole, fault = log_fact_join_take(&join, join_part(&values, COUNT, 1, 22))
	testing.expect(t, whole && fault == .None && join.value_count == COUNT)
}

// The facts that are joined, the last case: one record of 0 bytes, of
// one byte and of a whole record; two records; and the bound of
// LOG_FACT_RECORDS_MOST records, whose values come back in their order.
@(test)
the_records_of_a_fact_are_joined_in_order :: proc(t: ^testing.T) {
	counts := [?]int{0, 1, LOG_FACT_VALUE_CAPACITY, LOG_FACT_VALUE_CAPACITY + 1, LOG_FACT_VALUES_MOST - 1, LOG_FACT_VALUES_MOST}
	for count in counts {
		values := join_values(count)
		join: Log_Fact_Join
		parts := log_fact_part_count(count)
		for part in 0 ..< parts {
			whole, fault := log_fact_join_take(&join, join_part(&values, count, part, u64(100 + part)))
			testing.expectf(t, fault == .None && whole == (part == parts - 1), "the part %d of a fact of %d bytes gave %v, whole %v", part, count, fault, whole)
		}
		testing.expectf(t, !join.open && join.value_count == count, "the fact of %d bytes joined %d bytes", count, join.value_count)
		testing.expect(t, join.values == values)
	}
}

// The line of a fact of several records: the first record writes the
// count of the records, each next record "/" and its values, a part that
// starts a line "/" with no count; a fact of one record writes no count.
@(test)
the_line_of_a_fact_of_several_records :: proc(t: ^testing.T) {
	fact: Log_Fact
	fact.module_hash[0], fact.module_hash[1], fact.module_hash[2], fact.module_hash[3] = 0x1a, 0x2b, 0x3c, 0x4d
	fact.key = JOIN_KEY
	fact.value_count = LOG_FACT_VALUE_CAPACITY
	fact.values[0] = 0x0c
	fact.part, fact.part_count = 0, 2
	line: [LOG_FACT_LINE_BYTES_MOST]u8
	count := log_fact_line(&fact, &line)
	testing.expect_value(t, string(line[:count]), "#1a2b3c4d:fa0adf*2 0c")
	second := fact
	second.part, second.value_count = 1, 1
	second.values = {}
	second.values[0] = 0x0d
	count = log_fact_line(&second, &line, continuation = true)
	testing.expect_value(t, string(line[:count]), "/0d")
	// A part that starts a line: its head, and no count.
	count = log_fact_line(&second, &line)
	testing.expect_value(t, string(line[:count]), "#1a2b3c4d:fa0adf/0d")
	// A part of zeros: the mark alone.
	empty := second
	empty.values = {}
	count = log_fact_line(&empty, &line, continuation = true)
	testing.expect_value(t, string(line[:count]), "/")
	// A first record of zeros: the count, and no space.
	zeros := fact
	zeros.values = {}
	count = log_fact_line(&zeros, &line)
	testing.expect_value(t, string(line[:count]), "#1a2b3c4d:fa0adf*2")
	// One record: no count, as before.
	single := fact
	single.part_count = 1
	count = log_fact_line(&single, &line)
	testing.expect_value(t, string(line[:count]), "#1a2b3c4d:fa0adf 0c")
	// The largest line of one record fits its bound.
	full := fact
	full.part_count = LOG_FACT_RECORDS_MOST
	for &value in full.values {
		value = 0xff
	}
	count = log_fact_line(&full, &line)
	testing.expect(t, count <= LOG_FACT_LINE_BYTES_MOST && count == 1 + 8 + 1 + 6 + 2 + 1 + 2 * LOG_FACT_VALUE_CAPACITY)
}
