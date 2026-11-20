package machine

import "core:strings"
import "core:testing"
import op "modus:contract/operation"
import "modustool:build"

// fact_record_rows give the rows of a fact of two records at the numbers
// first and first + 1, the second left out when only_first.
@(private = "file")
fact_record_rows :: proc(first: i64, only_first: bool) -> []Fact_Record_Row {
	values := make([]u8, op.LOG_FACT_VALUE_CAPACITY, context.temp_allocator)
	for &value in values {
		value = 0x11
	}
	rows := make([dynamic]Fact_Record_Row, context.temp_allocator)
	append(&rows, Fact_Record_Row{number = first, key = 0xfa0a_df38_a559_f4d1, part = 0, part_count = 2, values = values})
	if !only_first {
		append(&rows, Fact_Record_Row{number = first + 1, key = 0xfa0a_df38_a559_f4d1, part = 1, part_count = 2, values = values[:1]})
	}
	return rows[:]
}

// The step Record with a fact whose last record is missing: when the read
// did not stop at its page, the first record shows its raw part after the
// mark, never an empty text; when it stopped at its page, the fact waits
// for the next read, which starts at its first record, and has no entry. A whole
// fact whose module the catalog does not hold has no sentence, and its
// first record no text.
@(test)
a_fact_whose_last_record_is_missing_shows_the_mark :: proc(t: ^testing.T) {
	empty := build.Fact_Catalog{allocator = context.temp_allocator}
	lost := make(map[i64]string, context.temp_allocator)
	_, lost_open := fact_record_rows_sentences(&empty, fact_record_rows(10, true), false, &lost)
	testing.expectf(t, !lost_open && strings.has_prefix(lost[10], op.LOG_FACT_JOIN_BROKEN_MARK), "the first record of a fact with no last record reads %q", lost[10])
	at_page := make(map[i64]string, context.temp_allocator)
	open_first, open := fact_record_rows_sentences(&empty, fact_record_rows(10, true), true, &at_page)
	_, has_text := at_page[10]
	testing.expect(t, open && open_first == 10 && !has_text)
	// A record with a hole in the numbers: both records are raw.
	rows := fact_record_rows(20, false)
	rows[1].number = 22
	hole := make(map[i64]string, context.temp_allocator)
	_, _ = fact_record_rows_sentences(&empty, rows, false, &hole)
	testing.expect(t, strings.has_prefix(hole[20], op.LOG_FACT_JOIN_BROKEN_MARK) && strings.has_prefix(hole[22], op.LOG_FACT_JOIN_BROKEN_MARK))
	// Whole, with no module: the first record "", the last no sentence.
	whole := make(map[i64]string, context.temp_allocator)
	_, _ = fact_record_rows_sentences(&empty, fact_record_rows(30, false), false, &whole)
	first_text, first_has := whole[30]
	_, last_has := whole[31]
	testing.expect(t, first_has && first_text == "" && !last_has)
}
