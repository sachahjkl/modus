#+build !freestanding
package result_lines

import "core:fmt"
import "core:strings"
import "core:testing"
import "internal:assistant/conversation"
import bridge_contract "modus:contract/agent_bridge"
import assistant_contract "modus:contract/assistant"
import "modus:console_results"
import "modus:contract/cut_mark"
import "modus:contract/value_kinds"

@(private = "file")
Column :: struct {
	name: string,
	kind: bridge_contract.Lex_Column_Kind,
	unit: i64,
}

// A cell: a text in a text column, a number in a number column.
@(private = "file")
Cell :: union {
	string,
	i64,
}

@(private = "file")
table_make :: proc(shape: assistant_contract.Act_Table_Shape, name: string, columns: []Column, rows: [][]Cell, total: int) -> ^conversation.Act_Table {
	table := new(conversation.Act_Table, context.temp_allocator)
	table.present, table.shape, table.total_rows = true, shape, total
	copy(table.name[:], name)
	table.column_count, table.row_count = len(columns), len(rows)
	for column, index in columns {
		copy(table.columns[index].name[:], column.name)
		table.columns[index].kind, table.columns[index].unit = i64(column.kind), column.unit
	}
	for row, row_index in rows {
		for cell, column_index in row {
			place := &table.cells[row_index * len(columns) + column_index]
			switch value in cell {
			case string:
				copy(place.text[:], value)
			case i64:
				place.integer = value
			}
		}
	}
	return table
}

@(private = "file")
text_columns_of :: proc(names: ..string) -> []Column {
	columns := make([]Column, len(names), context.temp_allocator)
	for name, index in names {
		columns[index] = {name = name, kind = .Text}
	}
	return columns
}

// The table of the processes: 16 columns, numbers, sizes in pages, a time
// in milliseconds, empty texts, a hash of 64 digits; 8 rows of 18.
@(private = "file")
processes_table :: proc() -> ^conversation.Act_Table {
	pages := i64(value_kinds.Size_Unit.Pages)
	columns := []Column{{"slot", .Integer, 0}, {"name", .Text, 0}, {"state", .Text, 0}, {"cause", .Text, 0}, {"outcome", .Text, 0}, {"resident", .Size, pages}, {"mapped", .Size, pages}, {"handles", .Integer, 0}, {"handles_peak", .Integer, 0}, {"mappings", .Integer, 0}, {"mappings_peak", .Integer, 0}, {"threads", .Integer, 0}, {"time", .Time, i64(value_kinds.Duration_Unit.Milliseconds)}, {"entries", .Integer, 0}, {"started", .Integer, 0}, {"hash", .Text, 0}}
	rows := make([][]Cell, 8, context.temp_allocator)
	for index in 0 ..< 8 {
		// Each row has memory of its own: a slice literal in a loop is one
		// place.
		row := []Cell{i64(index + 1), index == 0 ? "root" : "principals", "waiting", "", "", i64(9052 - index * 1000), i64(89), i64(4), i64(105), i64(11), i64(11), i64(1), i64(2), i64(15), i64(1931705), ""}
		rows[index] = make([]Cell, len(row), context.temp_allocator)
		copy(rows[index], row)
	}
	return table_make(.Table, "Process", columns, rows, 18)
}

@(private = "file")
all_lines :: proc(lines: ^Lines) -> []string {
	texts := make([]string, lines.line_count, context.temp_allocator)
	for line in 0 ..< lines.line_count {
		buffer := make([]u8, 4096, context.temp_allocator)
		texts[line] = line_text(lines, line, buffer)
	}
	return texts
}

// The table of the processes in a window of 89 cells and 24 lines: a row
// is one line within the width; the columns that fit show in their order,
// and one note names the others; a number is at the right of its column,
// with the unit of a size in its head; an empty cell keeps its column.
@(test)
the_table_of_the_processes_shows_the_columns_that_fit_one_line_a_row :: proc(t: ^testing.T) {
	lines := new(Lines, context.temp_allocator)
	scratch := new(Scratch, context.temp_allocator)
	testing.expect(t, fit(lines, scratch, processes_table(), 89, 24))
	texts := all_lines(lines)
	// The head, 8 rows, the two notes of the drawer and the note of the
	// columns.
	testing.expect_value(t, len(texts), 12)
	for text in texts {
		testing.expectf(t, console_results.text_columns(text) <= 89, "%q passes 89 cells", text)
	}
	head := texts[0]
	testing.expect(t, strings.has_prefix(head, "slot"))
	testing.expectf(t, strings.contains(head, "resident (pages)"), "%q", head)
	testing.expect(t, !strings.contains(head, "hash"))
	// The value of a size ends where its head ends.
	resident_end := strings.index(head, "resident (pages)") + len("resident (pages)")
	testing.expectf(t, strings.index(texts[1], "9052") + len("9052") == resident_end, "%q under %q", texts[1], head)
	testing.expectf(t, strings.index(texts[2], "8052") + len("8052") == resident_end, "%q under %q", texts[2], head)
	// The empty cause and outcome keep the columns after them.
	testing.expect_value(t, strings.index(texts[1], "waiting"), strings.index(head, "state"))
	testing.expect_value(t, strings.index(texts[8], "waiting"), strings.index(head, "state"))
	testing.expect_value(t, texts[9], "10 rows more are not shown")
	testing.expect_value(t, texts[10], "18 rows of Process")
	testing.expectf(t, strings.has_prefix(texts[11], "8 columns more: handles_peak, mappings"), "%q", texts[11])
}

// The note of the columns lists their names in their order while the width
// holds them, then "...".
@(test)
the_note_of_the_columns_fits_the_width :: proc(t: ^testing.T) {
	lines := new(Lines, context.temp_allocator)
	scratch := new(Scratch, context.temp_allocator)
	testing.expect(t, fit(lines, scratch, processes_table(), 40, 24))
	texts := all_lines(lines)
	note := texts[len(texts) - 1]
	testing.expectf(t, strings.has_suffix(note, ", ...") && console_results.text_columns(note) <= 40, "%q", note)
	testing.expect(t, strings.contains(note, " columns more: "))
}

// A room too small for the rows: the first lines, then one line that
// counts the others. A room of 0 lines draws nothing.
@(test)
a_room_too_small_shows_the_first_lines_and_counts_the_others :: proc(t: ^testing.T) {
	lines := new(Lines, context.temp_allocator)
	scratch := new(Scratch, context.temp_allocator)
	testing.expect(t, !fit(lines, scratch, processes_table(), 89, 0))
	testing.expect(t, fit(lines, scratch, processes_table(), 89, 3))
	texts := all_lines(lines)
	testing.expect_value(t, len(texts), 3)
	testing.expectf(t, strings.has_suffix(texts[2], " lines more are not shown: the window is too small"), "%q", texts[2])
}

// A row past 256 bytes: the widest text columns take a common bound, and a
// cut cell ends with the whole cut mark; when even the least bound passes,
// the last columns are dropped, and the note names them.
@(test)
a_row_past_the_bound_of_a_record_is_cut_with_its_mark_or_drops_columns :: proc(t: ^testing.T) {
	wide := strings.repeat("w", assistant_contract.ACT_TABLE_CELL_BYTES, context.temp_allocator)
	table := table_make(.Table, "Wide", text_columns_of("a", "b", "c", "d", "e"), [][]Cell{{wide, wide, wide, wide, wide}}, 1)
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
	scratch := new(Scratch, context.temp_allocator)
	testing.expect(t, fit(lines, scratch, table, 400, 30))
	joined := strings.join(all_lines(lines), "\n", context.temp_allocator)
	testing.expectf(t, strings.contains(joined, cut_mark.MARK_END), "%q", joined)
	// 24 columns of 64 bytes: 11 keep the least bound, 13 are dropped.
	names := make([]string, assistant_contract.ACT_TABLE_COLUMN_CAPACITY, context.temp_allocator)
	row := make([]Cell, assistant_contract.ACT_TABLE_COLUMN_CAPACITY, context.temp_allocator)
	for index in 0 ..< len(names) {
		names[index] = fmt.tprintf("c%d", index)
		row[index] = wide
	}
	table = table_make(.Table, "Wide", text_columns_of(..names), [][]Cell{row}, 1)
	kept = column_widths(table, widths[:])
	testing.expect_value(t, kept, 256 / CELL_LEAST)
	testing.expect(t, fit(lines, scratch, table, 4000, 30))
	texts := all_lines(lines)
	testing.expectf(t, strings.has_prefix(texts[len(texts) - 1], "13 columns more: c11, c12"), "%q", texts[len(texts) - 1])
}

// A note after a line that a capacity stopped half way is a line of its
// own.
@(test)
a_note_after_a_line_stopped_half_way_is_a_line_of_its_own :: proc(t: ^testing.T) {
	lines := new(Lines, context.temp_allocator)
	lines_reset(lines)
	lines.sink.write(&lines.sink, "slot", .Label)
	lines.sink.write(&lines.sink, "  name", .Label)
	testing.expect(t, lines.column > 0)
	lines.full = true
	note_write(lines, "the result is cut: it passes the lines that the window keeps")
	texts := all_lines(lines)
	testing.expect_value(t, len(texts), 2)
	testing.expect_value(t, texts[0], "slot  name")
	testing.expect_value(t, texts[1], "the result is cut: it passes the lines that the window keeps")
}

// A record: its name, then one line for each field with its value; a
// number at the right of its value column.
@(test)
a_record_is_one_line_for_each_field :: proc(t: ^testing.T) {
	columns := []Column{{"processes", .Integer, 0}, {"threads", .Integer, 0}, {"owner", .Text, 0}}
	table := table_make(.Record, "Counts", columns, [][]Cell{{i64(12), i64(40), "root"}}, 1)
	lines := new(Lines, context.temp_allocator)
	scratch := new(Scratch, context.temp_allocator)
	testing.expect(t, fit(lines, scratch, table, 89, 10))
	texts := all_lines(lines)
	testing.expect_value(t, len(texts), 4)
	testing.expect_value(t, texts[0], "Counts")
	testing.expect(t, strings.contains(texts[1], "processes") && strings.has_suffix(texts[1], "12"))
	testing.expect(t, strings.contains(texts[3], "owner") && strings.has_suffix(texts[3], "root"))
}
