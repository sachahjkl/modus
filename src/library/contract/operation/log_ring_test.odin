#+build !freestanding
package operation

import "core:testing"

// The record that the kernel writes over now is the record
// `written - LOG_RECORD_CAPACITY`: while the kernel writes record W,
// `written` is still W. Its copy is never kept, the record after it is.
@(test)
the_record_under_the_writer_is_never_kept :: proc(t: ^testing.T) {
	writing := u64(LOG_RECORD_CAPACITY + 40) // The kernel writes this record; `written` is still its number.
	written := writing
	under_the_writer := writing - LOG_RECORD_CAPACITY
	testing.expect(t, !log_copy_kept(under_the_writer, written))
	testing.expect(t, log_copy_kept(under_the_writer + 1, written))
	// When the kernel ends the record and starts the next one, the next
	// record under the writer is lost too.
	testing.expect(t, !log_copy_kept(under_the_writer + 1, written + 1))
	testing.expect(t, log_copy_kept(written - 1, written))
}

// log_first_kept starts at the first record that log_copy_kept can keep,
// and counts each record before it as lost.
@(test)
the_first_kept_record_agrees_with_the_copy_rule :: proc(t: ^testing.T) {
	written := u64(LOG_RECORD_CAPACITY + 10)
	next, lost := log_first_kept(0, written)
	testing.expect_value(t, next, 11)
	testing.expect_value(t, lost, 11)
	testing.expect(t, log_copy_kept(next, written))
	testing.expect(t, !log_copy_kept(next - 1, written))

	// A log with fewer records than the capacity: nothing is lost.
	short_next, short_lost := log_first_kept(0, LOG_RECORD_CAPACITY - 1)
	testing.expect_value(t, short_next, 0)
	testing.expect_value(t, short_lost, 0)
	// Exactly the capacity: the record 0 is under the writer of the next one.
	full_next, full_lost := log_first_kept(0, LOG_RECORD_CAPACITY)
	testing.expect_value(t, full_next, 1)
	testing.expect_value(t, full_lost, 1)
	// A number past the last record gives the end, with nothing lost.
	end_next, end_lost := log_first_kept(written + 5, written)
	testing.expect_value(t, end_next, written)
	testing.expect_value(t, end_lost, 0)
}

// An own log ring keeps the last OWN_LOG_RECORD_CAPACITY records of its
// process: a reader from the own number 0 loses the records before them,
// and a reader with fewer records than that loses none.
@(test)
an_own_log_ring_keeps_the_last_records :: proc(t: ^testing.T) {
	short_first, short_lost, short_total := own_log_window(5, 0)
	testing.expect_value(t, short_first, 0)
	testing.expect_value(t, short_lost, 0)
	testing.expect_value(t, short_total, 5)

	full_first, full_lost, full_total := own_log_window(OWN_LOG_RECORD_CAPACITY, 0)
	testing.expect_value(t, full_first, 0)
	testing.expect_value(t, full_lost, 0)
	testing.expect_value(t, full_total, OWN_LOG_RECORD_CAPACITY)

	written := u64(OWN_LOG_RECORD_CAPACITY + 10)
	first, lost, total := own_log_window(written, 0)
	testing.expect_value(t, first, 10)
	testing.expect_value(t, lost, 10)
	testing.expect_value(t, total, OWN_LOG_RECORD_CAPACITY)

	// From a record that the ring keeps: nothing lost, the rest of the ring.
	kept_first, kept_lost, kept_total := own_log_window(written, 20)
	testing.expect_value(t, kept_first, 20)
	testing.expect_value(t, kept_lost, 0)
	testing.expect_value(t, kept_total, written - 20)

	// At the count, and past it: no record, nothing lost.
	end_first, end_lost, end_total := own_log_window(written, u32(written))
	testing.expect_value(t, end_first, written)
	testing.expect_value(t, end_lost, 0)
	testing.expect_value(t, end_total, 0)
	ahead_first, ahead_lost, ahead_total := own_log_window(written, u32(written) + 3)
	testing.expect_value(t, ahead_first, written)
	testing.expect_value(t, ahead_lost, 0)
	testing.expect_value(t, ahead_total, 0)
}

// The own number has 32 bits and the count of the kernel 64: an `after`
// names the count below the count of the process with the same low bits,
// across the wrap at 2^32.
@(test)
an_own_number_names_its_record_across_the_wrap :: proc(t: ^testing.T) {
	written := u64(1) << 32 + 3 // The own numbers 0xFFFF_FFFF, 0, 1 and 2 are the last ones.
	first, lost, total := own_log_window(written, 0xFFFF_FFFF)
	testing.expect_value(t, first, written - 4)
	testing.expect_value(t, lost, 0)
	testing.expect_value(t, total, 4)
	testing.expect_value(t, u32(first), 0xFFFF_FFFF)

	// The own number 0 of the start of the process is far before the ring:
	// it reads as the count 2^32, and the ring keeps the records from there.
	start_first, start_lost, start_total := own_log_window(written, 0)
	testing.expect_value(t, start_first, written - 3)
	testing.expect_value(t, start_lost, 0)
	testing.expect_value(t, start_total, 3)

	// An own number more than 2^31 before the count reads as past it.
	far_first, _, far_total := own_log_window(written, u32(3 + OWN_NUMBER_HALF))
	testing.expect_value(t, far_first, written)
	testing.expect_value(t, far_total, 0)
}

// The place of each record: whole records in each page, the pages in turn,
// and the record after the last place back at the first one.
@(test)
the_places_of_an_own_log_ring :: proc(t: ^testing.T) {
	records_of_a_page := u64(4096 / size_of(Log_Record))
	page, offset := own_log_place(0)
	testing.expect_value(t, page, 0)
	testing.expect_value(t, offset, 0)
	last_page, last_offset := own_log_place(records_of_a_page - 1)
	testing.expect_value(t, last_page, 0)
	testing.expect_value(t, last_offset, 4096 - size_of(Log_Record))
	next_page, next_offset := own_log_place(records_of_a_page)
	testing.expect_value(t, next_page, 1)
	testing.expect_value(t, next_offset, 0)
	end_page, _ := own_log_place(OWN_LOG_RECORD_CAPACITY - 1)
	testing.expect_value(t, end_page, OWN_LOG_PAGES - 1)
	wrap_page, wrap_offset := own_log_place(OWN_LOG_RECORD_CAPACITY)
	testing.expect_value(t, wrap_page, 0)
	testing.expect_value(t, wrap_offset, 0)
}

// The head of a line of the serial port is the name of the process in
// brackets, and nothing more: the bytes after the name (the runs, the text)
// never enter it. The edges come first: the kernel and a record that
// continues a line have no head, an empty name, a name of one byte, and a
// name that fills its whole field with no zero after it.
@(test)
the_head_of_a_line_of_the_serial_port :: proc(t: ^testing.T) {
	head: [LOG_LINE_HEAD_CAPACITY]u8

	kernel := Log_Record{}
	copy(kernel.name[:], "kernel")
	testing.expect_value(t, log_line_head(&kernel, false, &head), 0)
	testing.expect_value(t, log_line_head(&kernel, true, &head), 0)

	record := Log_Record{process = 3}
	copy(record.text[:], "text")
	record.runs[0] = {start = 1, length = 2, kind = 3}
	testing.expect_value(t, log_line_head(&record, true, &head), 0)
	count := log_line_head(&record, false, &head)
	testing.expect_value(t, string(head[:count]), "[] ")

	record.name[0] = 'n'
	count = log_line_head(&record, false, &head)
	testing.expect_value(t, string(head[:count]), "[n] ")

	record.name = {}
	copy(record.name[:], "console")
	count = log_line_head(&record, false, &head)
	testing.expect_value(t, string(head[:count]), "[console] ")
	testing.expect_value(t, log_line_head(&record, true, &head), 0)

	for &byte_value in record.name {
		byte_value = 'n'
	}
	count = log_line_head(&record, false, &head)
	testing.expect_value(t, count, LOG_LINE_HEAD_CAPACITY)
	testing.expect_value(t, head[1 + LOG_NAME_BYTES - 1], u8('n'))
	testing.expect_value(t, head[1 + LOG_NAME_BYTES], u8(']'))
	testing.expect_value(t, head[LOG_LINE_HEAD_CAPACITY - 1], u8(' '))
}

// The form of a record is read through its border: a byte that names no
// form is refused, the edges first (one past the last member, the largest
// byte), then the two members. The fact of a record is its bytes after the
// name of the process, and fills the record.
@(test)
the_form_of_a_record_is_read_through_its_border :: proc(t: ^testing.T) {
	record: Log_Record
	for word in ([2]u8{u8(max(Log_Record_Form)) + 1, max(u8)}) {
		record.form = word
		_, ok := log_record_form(&record)
		testing.expectf(t, !ok, "the form byte %d is taken", word)
	}
	record.form = 0
	text_form, text_ok := log_record_form(&record)
	record.form = u8(Log_Record_Form.Fact)
	fact_form, fact_ok := log_record_form(&record)
	testing.expect(t, text_ok && text_form == .Text && fact_ok && fact_form == .Fact)
	testing.expect_value(t, uintptr(log_record_fact(&record)) - uintptr(&record), uintptr(offset_of(Log_Record, runs)))
	testing.expect_value(t, int(offset_of(Log_Record, runs)) + size_of(Log_Fact), size_of(Log_Record))
	// The longest line of a fact fits after the longest head.
	testing.expect(t, LOG_SERIAL_LINE_BYTES_MOST >= LOG_LINE_HEAD_CAPACITY + LOG_FACT_LINE_BYTES_MOST + 2)
}

// The line of a fact on the serial port: "#", the first 8 bytes of the
// module hash, ":", the fact key, then the value bytes up to their last
// byte that is not zero. The edges: no value byte and only zero values (no
// space), a count past the capacity and the largest count (the capacity),
// bytes past the count (not written), and every value byte not zero (the
// longest line).
@(test)
the_line_of_a_fact :: proc(t: ^testing.T) {
	line: [LOG_FACT_LINE_BYTES_MOST]u8
	fact := Log_Fact{key = 0xfa0a_df38_a559_f4d1}
	hash_start := [8]u8{0x1a, 0x2b, 0x3c, 0x4d, 0x5e, 0x6f, 0x70, 0x81}
	copy(fact.module_hash[:], hash_start[:])
	fact.module_hash[8] = 0xFF // Past the 8 bytes: not in the line.
	count := log_fact_line(&fact, &line)
	testing.expect_value(t, string(line[:count]), "#1a2b3c4d5e6f7081:fa0adf38a559f4d1")
	fact.value_count = 4
	count = log_fact_line(&fact, &line)
	testing.expect_value(t, string(line[:count]), "#1a2b3c4d5e6f7081:fa0adf38a559f4d1")

	fact.values[0], fact.values[2] = 0x0c, 0x23
	fact.values[5] = 0x99 // Past the count: not in the line.
	count = log_fact_line(&fact, &line)
	testing.expect_value(t, string(line[:count]), "#1a2b3c4d5e6f7081:fa0adf38a559f4d1 0c0023")

	for &value in fact.values {
		value = 0xAB
	}
	for value_count in ([3]u16{LOG_FACT_VALUE_CAPACITY, LOG_FACT_VALUE_CAPACITY + 1, max(u16)}) {
		fact.value_count = value_count
		count = log_fact_line(&fact, &line)
		testing.expectf(t, count == LOG_FACT_LINE_BYTES_MOST, "a count of %d gives a line of %d bytes", value_count, count)
	}
	testing.expect_value(t, line[LOG_FACT_LINE_BYTES_MOST - 1], u8('b'))
	zero := Log_Fact{value_count = LOG_FACT_VALUE_CAPACITY}
	count = log_fact_line(&zero, &line)
	testing.expect_value(t, string(line[:count]), "#0000000000000000:0000000000000000")
}
