// The lines of the typed result of an act, as the console draws a result
// (src/md/features/assistant.md, "The result of an act"). The package
// writes the description of the record and its rows, lets the drawers of
// modus:console_results write the lines at a width in cells, and fits
// them to the room of the window. It has no state of its own, calls no
// allocator and makes no call of the system: a host test reads each line.
// The window paints the lines in the font of the cells.
package result_lines

import "internal:assistant/conversation"
import assistant_contract "modus:contract/assistant"
import "modus:contract/cut_mark"
import module "modus:contract/module"
import "modus:console_results"
import "modus:sentence"

// The lines of one result: a head, 8 rows that each take some lines of a
// column of words, and the notes. Past a capacity the lines stop, and the
// last line says that the result is cut: no line is dropped in silence.
LINE_CAPACITY :: 64
TEXT_BYTES :: 16 * 1024
PART_CAPACITY :: 1024

// The least bytes of a column when the row must be narrowed to the bound
// of a record: one character and the cut mark of the most bytes that a
// cell of 64 bytes can miss, so a cut cell still says what it misses.
CELL_LEAST :: 1 + len(cut_mark.MARK_START) + 2 + len(cut_mark.MARK_END)
#assert(assistant_contract.ACT_TABLE_CELL_BYTES < 100) // The 2 digits of CELL_LEAST.
#assert(CELL_LEAST <= assistant_contract.ACT_TABLE_CELL_BYTES)

Part :: struct {
	line:  int,
	start: int,
	count: int,
	part:  console_results.Part,
}

// What the drawers wrote, line by line. A line that passes the width goes
// on in a new line under the continuation that the drawer set.
Lines :: struct {
	text:        [TEXT_BYTES]u8,
	text_count:  int,
	parts:       [PART_CAPACITY]Part,
	part_count:  int,
	line_count:  int,
	column:      int, // The column of the line that is written.
	full:        bool, // A capacity stopped the lines: the last line says so.
	sink:        console_results.Sink,
	description: [4096]u8,
	rows:        [assistant_contract.ACT_TABLE_ROW_CAPACITY * module.RECORD_SIZE_LIMIT]u8,
}

// The lines that the last line of a full result keeps for its note.
// Two notes at most: the dropped columns, and the cut.
@(private = "file")
NOTE_LINES :: 2

@(private = "file")
is_blank :: proc "contextless" (text: string) -> bool {
	for character in transmute([]u8)text {
		if character != ' ' {
			return false
		}
	}
	return true
}

@(private = "file")
part_add :: proc "contextless" (lines: ^Lines, text: string, part: console_results.Part) {
	if lines.line_count >= LINE_CAPACITY - NOTE_LINES || lines.part_count >= PART_CAPACITY - 2 || lines.text_count + len(text) > TEXT_BYTES - 64 {
		lines.full = true
		return
	}
	copy(lines.text[lines.text_count:], text)
	lines.parts[lines.part_count] = {line = lines.line_count, start = lines.text_count, count = len(text), part = part}
	lines.part_count += 1
	lines.text_count += len(text)
	lines.column += console_results.text_columns(text)
}

@(private = "file")
line_write :: proc "contextless" (sink: ^console_results.Sink, text: string, part: console_results.Part) {
	lines := (^Lines)(sink.data)
	if text == "" || lines.full {
		return
	}
	columns := console_results.text_columns(text)
	if sink.width > 0 && lines.column > 0 && lines.column + columns > sink.width {
		// Blanks at the end of a line are dropped.
		if part == .Plain && is_blank(text) {
			return
		}
		line_end(sink)
		if sink.continuation > 0 && sink.continuation < sink.width {
			blank := console_results.BLANKS
			part_add(lines, blank[:min(sink.continuation, len(blank))], .Plain)
		}
	}
	part_add(lines, text, part)
}

@(private = "file")
line_end :: proc "contextless" (sink: ^console_results.Sink) {
	lines := (^Lines)(sink.data)
	if lines.full {
		return
	}
	if lines.line_count >= LINE_CAPACITY - NOTE_LINES {
		lines.full = true
		return
	}
	lines.line_count += 1
	lines.column = 0
}

// note_write writes one line of a note at the end of the lines; it takes
// the place that part_add keeps free.
@(private = "file")
note_write :: proc "contextless" (lines: ^Lines, parts: ..sentence.Part) {
	buffer: [96]u8
	text := sentence.format(buffer[:], ..parts)
	if lines.part_count >= PART_CAPACITY || lines.text_count + len(text) > TEXT_BYTES || lines.line_count >= LINE_CAPACITY {
		return
	}
	copy(lines.text[lines.text_count:], text)
	lines.parts[lines.part_count] = {line = lines.line_count, start = lines.text_count, count = len(text), part = .Note}
	lines.part_count += 1
	lines.text_count += len(text)
	lines.line_count += 1
	lines.column = 0
}

// column_widths gives the bytes of each Text column, its longest cell, at
// least 1, and the count of columns that the row keeps. A record of the
// contract holds RECORD_SIZE_LIMIT bytes: when a row passes it, the widest
// columns take a common bound, and a cell past its column ends with the
// cut mark. A bound under CELL_LEAST would leave no room for the mark: the
// last columns are then dropped, and a note says how many.
column_widths :: proc "contextless" (table: ^conversation.Act_Table, widths: []u32) -> (kept: int) {
	for column in 0 ..< table.column_count {
		widths[column] = 1
		for row in 0 ..< table.row_count {
			widths[column] = max(widths[column], u32(len(conversation.act_table_cell_text(table, row, column))))
		}
	}
	kept = table.column_count
	for kept > 0 {
		least_sum: u32
		for column in 0 ..< kept {
			least_sum += min(widths[column], CELL_LEAST)
		}
		if least_sum <= module.RECORD_SIZE_LIMIT {
			break
		}
		kept -= 1
	}
	bound := u32(assistant_contract.ACT_TABLE_CELL_BYTES)
	for bound > CELL_LEAST {
		sum: u32
		for column in 0 ..< kept {
			sum += min(widths[column], bound)
		}
		if sum <= module.RECORD_SIZE_LIMIT {
			break
		}
		bound -= 1
	}
	for column in 0 ..< kept {
		widths[column] = min(widths[column], bound)
	}
	return kept
}

@(private = "file")
lines_reset :: proc "contextless" (lines: ^Lines, width_cells: int) {
	lines.text_count, lines.part_count, lines.line_count, lines.column = 0, 0, 0, 0
	lines.full = false
	lines.sink = {data = lines, write = line_write, end_line = line_end, width = max(width_cells, 0)}
}

// draw writes the lines of a result at a width in cells, with at most
// row_limit rows; the drawer counts the rest against total_rows. ok is
// false when the description cannot be written.
draw :: proc "contextless" (lines: ^Lines, table: ^conversation.Act_Table, width_cells: int, row_limit: int) -> (ok: bool) {
	lines_reset(lines, width_cells)
	widths: [assistant_contract.ACT_TABLE_COLUMN_CAPACITY]u32
	kept := column_widths(table, widths[:])
	if kept == 0 {
		return false
	}
	columns: [assistant_contract.ACT_TABLE_COLUMN_CAPACITY]console_results.Column
	for column in 0 ..< kept {
		columns[column] = console_results.text_column(conversation.act_table_column_name(table, column), widths[column])
	}
	lines.description = {}
	file, size, written := console_results.description_write(lines.description[:], conversation.act_table_name(table), columns[:kept])
	if !written || size == 0 {
		return false
	}
	// description_write wrote the offset of each column in columns.
	rows := lines.rows[:int(size) * table.row_count]
	for &value in rows {
		value = 0
	}
	for row in 0 ..< table.row_count {
		for column in 0 ..< kept {
			console_results.row_text_set(rows[row * int(size):][:size], columns[column], conversation.act_table_cell_text(table, row, column))
		}
	}
	switch table.shape {
	case .Table:
		console_results.draw_table(&lines.sink, file, 1, rows, clamp(row_limit, 0, table.row_count), "", table.total_rows)
	case .Record:
		console_results.draw_record(&lines.sink, file, 1, rows[:size])
	}
	if kept < table.column_count {
		dropped := u64(table.column_count - kept)
		note_write(lines, dropped, dropped == 1 ? " column more is not shown: a row holds 256 bytes" : " columns more are not shown: a row holds 256 bytes")
	}
	if lines.full {
		note_write(lines, "the result is cut: it passes the lines that the window keeps")
	}
	return true
}

// fit writes the lines of a result within line_room lines: the most rows
// whose lines fit, so the note of the drawer counts the others; when no
// row fits, the first lines and one line that counts the lines not shown.
// ok is false when the description cannot be written, or line_room is
// under 1.
fit :: proc "contextless" (lines: ^Lines, table: ^conversation.Act_Table, width_cells: int, line_room: int) -> (ok: bool) {
	if line_room < 1 {
		return false
	}
	for row_limit := table.row_count; row_limit >= 0; row_limit -= 1 {
		draw(lines, table, width_cells, row_limit) or_return
		if lines.line_count <= line_room || table.shape == .Record {
			break
		}
	}
	if lines.line_count <= line_room {
		return true
	}
	// Not even the head fits: the first lines, then the count of the
	// others.
	hidden := u64(lines.line_count - (line_room - 1))
	lines_clip(lines, line_room - 1)
	note_write(lines, hidden, hidden == 1 ? " line more is not shown: the window is too small" : " lines more are not shown: the window is too small")
	return true
}

// lines_clip keeps the first count lines.
@(private = "file")
lines_clip :: proc "contextless" (lines: ^Lines, count: int) {
	parts := 0
	for parts < lines.part_count && lines.parts[parts].line < count {
		parts += 1
	}
	lines.part_count = parts
	lines.text_count = parts > 0 ? lines.parts[parts - 1].start + lines.parts[parts - 1].count : 0
	lines.line_count = count
	lines.column = 0
}

// line_text writes the text of a line in buffer, for a test and a log.
line_text :: proc "contextless" (lines: ^Lines, line: int, buffer: []u8) -> string {
	count := 0
	for index in 0 ..< lines.part_count {
		part := lines.parts[index]
		if part.line == line {
			count += copy(buffer[count:], lines.text[part.start:][:part.count])
		}
	}
	return string(buffer[:count])
}
