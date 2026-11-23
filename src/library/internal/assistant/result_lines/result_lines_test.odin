#+build !freestanding
package result_lines

import "core:fmt"
import "core:strings"
import "core:testing"
import "internal:assistant/conversation"
import assistant_contract "modus:contract/assistant"
import "modus:console_results"
import "modus:contract/cut_mark"

@(private = "file")
table_make :: proc(shape: assistant_contract.Act_Table_Shape, name: string, columns: []string, rows: [][]string, total: int) -> ^conversation.Act_Table {
	table := new(conversation.Act_Table, context.temp_allocator)
	table.present, table.shape, table.total_rows = true, shape, total
	copy(table.name[:], name)
	table.column_count, table.row_count = len(columns), len(rows)
	for column, index in columns {
		copy(table.columns[index].name[:], column)
	}
	for row, row_index in rows {
		for cell, column_index in row {
			copy(table.cells[row_index * len(columns) + column_index].text[:], cell)
		}
	}
	return table
}

// The table of the processes: 16 columns, a hash of 64 digits, 8 rows of
// 18.
@(private = "file")
processes_table :: proc() -> ^conversation.Act_Table {
	columns := []string{"slot", "name", "state", "cause", "outcome", "resident", "mapped", "handles", "handles_peak", "mappings", "mappings_peak", "threads", "time", "entries", "started", "hash"}
	rows := make([][]string, 8, context.temp_allocator)
	for index in 0 ..< 8 {
		rows[index] = []string{fmt.tprintf("%d", index + 1), "principals", "waiting", "", "", "6762", "6828", "5", "5", "11", "11", "1", "2", "15", "1931705", strings.repeat("ab", 32, context.temp_allocator)}
	}
	return table_make(.Table, "Process", columns, rows, 18)
}

@(private = "file")
all_lines :: proc(lines: ^Lines) -> []string {
	texts := make([]string, lines.line_count, context.temp_allocator)
	for line in 0 ..< lines.line_count {
		buffer := make([]u8, 1024, context.temp_allocator)
		texts[line] = line_text(lines, line, buffer)
	}
	return texts
}

// The table of the processes in the window, 89 cells wide and 24 lines
// high: no line passes the width, the head names the first column, the
// rows that fit are drawn whole, and the notes of the drawer count the
// others against the 18 rows of the result.
@(test)
the_table_of_the_processes_fits_the_window_with_its_counts :: proc(t: ^testing.T) {
	lines := new(Lines, context.temp_allocator)
	testing.expect(t, fit(lines, processes_table(), 89, 24))
	texts := all_lines(lines)
	testing.expect(t, len(texts) >= 4 && len(texts) <= 24)
	for text in texts {
		testing.expectf(t, console_results.text_columns(text) <= 89, "%q passes 89 cells", text)
	}
	testing.expect(t, strings.has_prefix(texts[0], "slot"))
	testing.expectf(t, strings.contains(texts[len(texts) - 2], " rows more are not shown"), "%q", texts[len(texts) - 2])
	testing.expect_value(t, texts[len(texts) - 1], "18 rows of Process")
	// The hash is whole: 64 digits fit a row of 256 bytes.
	joined := strings.join(texts, "", context.temp_allocator)
	testing.expect(t, !strings.contains(joined, cut_mark.MARK_START))
}

// A room too small for the head: the first lines, then one line that
// counts the others. A room of 0 lines draws nothing.
@(test)
a_room_too_small_shows_the_first_lines_and_counts_the_others :: proc(t: ^testing.T) {
	lines := new(Lines, context.temp_allocator)
	testing.expect(t, !fit(lines, processes_table(), 89, 0))
	testing.expect(t, fit(lines, processes_table(), 20, 3))
	texts := all_lines(lines)
	testing.expect_value(t, len(texts), 3)
	testing.expectf(t, strings.has_suffix(texts[2], " lines more are not shown: the window is too small"), "%q", texts[2])
}

// A row past 256 bytes: the widest columns take a common bound, and a cut
// cell ends with the whole cut mark; when even the least bound passes,
// the last columns are dropped, with a note.
@(test)
a_row_past_the_bound_of_a_record_is_cut_with_its_mark_or_drops_columns :: proc(t: ^testing.T) {
	wide := strings.repeat("w", assistant_contract.ACT_TABLE_CELL_BYTES, context.temp_allocator)
	columns := []string{"a", "b", "c", "d", "e"}
	table := table_make(.Table, "Wide", columns, [][]string{{wide, wide, wide, wide, wide}}, 1)
	widths: [assistant_contract.ACT_TABLE_COLUMN_CAPACITY]u32
	kept := column_widths(table, widths[:])
	testing.expect_value(t, kept, 5)
	sum: u32
	for width in widths[:kept] {
		sum += width
		testing.expect(t, width >= CELL_LEAST)
	}
	testing.expect(t, sum <= 256)
	lines := new(Lines, context.temp_allocator)
	testing.expect(t, fit(lines, table, 400, 30))
	joined := strings.join(all_lines(lines), "\n", context.temp_allocator)
	testing.expectf(t, strings.contains(joined, cut_mark.MARK_END), "%q", joined)
	// 24 columns of 64 bytes: 11 keep the least bound, 13 are dropped.
	many := make([]string, assistant_contract.ACT_TABLE_COLUMN_CAPACITY, context.temp_allocator)
	row := make([]string, assistant_contract.ACT_TABLE_COLUMN_CAPACITY, context.temp_allocator)
	for index in 0 ..< len(many) {
		many[index] = fmt.tprintf("c%d", index)
		row[index] = wide
	}
	table = table_make(.Table, "Wide", many, [][]string{row}, 1)
	kept = column_widths(table, widths[:])
	testing.expect_value(t, kept, 256 / CELL_LEAST)
	testing.expect(t, fit(lines, table, 400, 60))
	texts := all_lines(lines)
	testing.expectf(t, strings.has_prefix(texts[len(texts) - 1], "13 columns more are not shown"), "%q", texts[len(texts) - 1])
}

// Past the lines that one result keeps, the last line says that the
// result is cut.
@(test)
a_result_past_the_capacity_says_that_it_is_cut :: proc(t: ^testing.T) {
	// 16 columns of 14 bytes in 20 cells: a cell takes a line, a row 16.
	columns := make([]string, 16, context.temp_allocator)
	row := make([]string, 16, context.temp_allocator)
	for index in 0 ..< 16 {
		columns[index] = fmt.tprintf("c%d", index)
		row[index] = "word word word"
	}
	rows := make([][]string, 8, context.temp_allocator)
	for index in 0 ..< 8 {
		rows[index] = row
	}
	table := table_make(.Table, "Words", columns, rows, 8)
	lines := new(Lines, context.temp_allocator)
	testing.expect(t, draw(lines, table, 20, 8))
	testing.expectf(t, lines.full, "%d lines", lines.line_count)
	texts := all_lines(lines)
	testing.expect(t, len(texts) <= LINE_CAPACITY)
	testing.expect_value(t, texts[len(texts) - 1], "the result is cut: it passes the lines that the window keeps")
}

// A record: its name, then one line for each field with its value.
@(test)
a_record_is_one_line_for_each_field :: proc(t: ^testing.T) {
	table := table_make(.Record, "Counts", []string{"processes", "threads"}, [][]string{{"12", "40"}}, 1)
	lines := new(Lines, context.temp_allocator)
	testing.expect(t, fit(lines, table, 89, 10))
	texts := all_lines(lines)
	testing.expect_value(t, len(texts), 3)
	testing.expect_value(t, texts[0], "Counts")
	testing.expect(t, strings.contains(texts[1], "processes") && strings.has_suffix(texts[1], "12"))
	testing.expect(t, strings.contains(texts[2], "threads") && strings.has_suffix(texts[2], "40"))
}
