// The lines of the typed result of an act, as the console draws a result
// (src/md/features/assistant.md, "The result of an act"). The package
// writes the description of the record and its rows, lets the drawers of
// modus:console_results write the lines, and fits them to the room of the
// window: the columns that fit its width, in their order, and the rows that
// fit its height. A row never wraps, so the eye follows each column. The
// package has no state of its own, calls no allocator and makes no call of
// the system: a host test reads each line. The window paints the lines in
// the font of the cells.
package result_lines

import "internal:assistant/conversation"
import assistant_contract "modus:contract/assistant"
import "modus:contract/cut_mark"
import module "modus:contract/module"
import "modus:contract/value_kinds"
import "modus:console_results"
import "modus:sentence"

// The lines of one result. A row is one line, so a table takes a head,
// 8 rows and the two notes of the drawer, and a record a name and one line
// for each field; the notes of this package take two more. Past a
// capacity the lines stop, and the last line says that the result is cut:
// no line is dropped in silence.
LINE_CAPACITY :: max(assistant_contract.ACT_TABLE_ROW_CAPACITY, assistant_contract.ACT_TABLE_COLUMN_CAPACITY) + 8
#assert(LINE_CAPACITY >= 1 + assistant_contract.ACT_TABLE_ROW_CAPACITY + 2 + NOTE_LINES)
#assert(LINE_CAPACITY >= 1 + assistant_contract.ACT_TABLE_COLUMN_CAPACITY + NOTE_LINES)
TEXT_BYTES :: 32 * 1024
PART_CAPACITY :: 4096
#assert(TEXT_BYTES <= int(max(u16)))

// The notes of this package: the columns that are not shown, and the cut.
NOTE_LINES :: 2

// The least bytes of a text column when the row must be narrowed to the
// bound of a record: one character and the cut mark of the most bytes that
// a cell of 64 bytes can miss, so a cut cell still says what it misses.
CELL_LEAST :: 1 + len(cut_mark.MARK_START) + 2 + len(cut_mark.MARK_END)
#assert(assistant_contract.ACT_TABLE_CELL_BYTES < 100) // The 2 digits of CELL_LEAST.
#assert(CELL_LEAST <= assistant_contract.ACT_TABLE_CELL_BYTES)

Part :: struct {
	line:  u16,
	start: u16,
	count: u16,
	part:  console_results.Part,
}

// What the drawers wrote, line by line.
Lines :: struct {
	text:       [TEXT_BYTES]u8,
	text_count: int,
	parts:      [PART_CAPACITY]Part,
	part_count: int,
	line_count: int,
	shown_rows: int, // For a Table: the rows drawn on this page.
	column:     int, // The column of the line that is written: 0 at its start.
	full:       bool, // A capacity stopped the lines: the last line says so.
	sink:       console_results.Sink,
}

// The memory of one draw: the description of the record and its rows. The
// caller keeps one, for each draw in turn.
Scratch :: struct {
	description: [4096]u8,
	rows:        [assistant_contract.ACT_TABLE_ROW_CAPACITY * module.RECORD_SIZE_LIMIT]u8,
}

@(private)
part_add :: proc "contextless" (lines: ^Lines, text: string, part: console_results.Part, room_kept: int) -> bool {
	if lines.line_count >= LINE_CAPACITY - room_kept || lines.part_count >= PART_CAPACITY - room_kept || lines.text_count + len(text) > TEXT_BYTES - 96 * room_kept {
		return false
	}
	copy(lines.text[lines.text_count:], text)
	lines.parts[lines.part_count] = {line = u16(lines.line_count), start = u16(lines.text_count), count = u16(len(text)), part = part}
	lines.part_count += 1
	lines.text_count += len(text)
	lines.column += console_results.text_columns(text)
	return true
}

@(private = "file")
line_write :: proc "contextless" (sink: ^console_results.Sink, text: string, part: console_results.Part) {
	lines := (^Lines)(sink.data)
	if text == "" || lines.full {
		return
	}
	if !part_add(lines, text, part, NOTE_LINES) {
		lines.full = true
	}
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

// note_write writes one line of a note after the lines, in the room that
// the drawers leave free. A line that a capacity stopped half way ends
// first: the note is a line of its own.
@(private)
note_write :: proc "contextless" (lines: ^Lines, text: string) {
	if lines.column > 0 && lines.line_count < LINE_CAPACITY {
		lines.line_count += 1
		lines.column = 0
	}
	if part_add(lines, text, .Note, 0) {
		lines.line_count += 1
		lines.column = 0
	}
}

// The form of each column of a draw.
@(private = "file")
Draw_Columns :: struct {
	columns: [assistant_contract.ACT_TABLE_COLUMN_CAPACITY]console_results.Column,
	count:   int,
}

// column_of gives the column of the description for a column of a result:
// a text at the left, as wide as bytes; a number at the right, with its
// unit in the head, as the console writes it.
@(private = "file")
column_of :: proc "contextless" (table: ^conversation.Act_Table, column: int, bytes: u32) -> console_results.Column {
	name := conversation.act_table_column_name(table, column)
	switch form in conversation.act_table_column_form(table, column) {
	case conversation.Text_Form:
		return console_results.text_column(name, bytes)
	case conversation.Integer_Form:
		return console_results.integer_column(name)
	case value_kinds.Size_Unit:
		return console_results.size_column(name, form)
	case value_kinds.Duration_Unit:
		return console_results.time_column(name, form)
	case conversation.Hexadecimal_Form:
		return {name = name, type = .Integer, detail = u32(form.bytes), unsigned = true, kind = .Hexadecimal}
	}
	return console_results.text_column(name, bytes)
}

// row_size gives the bytes of a row of the first count columns, as
// description_write lays it out: a text column at any byte, a number
// column at a multiple of its size, and the row at a multiple of its
// widest number. A text column is at most bound bytes.
@(private = "file")
row_size :: proc "contextless" (widths: []u32, is_text: []bool, count: int, bound: u32) -> u32 {
	size, alignment: u32 = 0, 1
	for column in 0 ..< count {
		width := is_text[column] ? min(widths[column], bound) : widths[column]
		column_alignment := is_text[column] ? 1 : max(width, 1)
		size = (size + column_alignment - 1) / column_alignment * column_alignment + width
		alignment = max(alignment, column_alignment)
	}
	return (size + alignment - 1) / alignment * alignment
}

// column_widths gives the bytes of each column, and the count of columns
// that a row of RECORD_SIZE_LIMIT bytes keeps, with the padding that
// description_write gives a number column (row_size). A number column has
// the bytes of its number. A text column is as wide as its longest cell,
// and at most text_most bytes; when a row passes the bound, the widest
// text columns take a common bound, and a cell past its column ends with
// the cut mark. A bound under CELL_LEAST would leave no room for the mark:
// the last columns are then dropped.
column_widths :: proc "contextless" (table: ^conversation.Act_Table, widths: []u32, text_most: u32 = assistant_contract.ACT_TABLE_CELL_BYTES) -> (kept: int) {
	is_text: [assistant_contract.ACT_TABLE_COLUMN_CAPACITY]bool
	for column in 0 ..< table.column_count {
		switch form in conversation.act_table_column_form(table, column) {
		case conversation.Integer_Form, value_kinds.Size_Unit, value_kinds.Duration_Unit:
			widths[column] = 8
		case conversation.Hexadecimal_Form:
			widths[column] = u32(form.bytes)
		case conversation.Text_Form:
			is_text[column] = true
			widths[column] = 1
			for row in 0 ..< table.row_count {
				widths[column] = max(widths[column], u32(len(conversation.act_table_cell_text(table, row, column))))
			}
			widths[column] = min(widths[column], max(text_most, CELL_LEAST))
		}
	}
	kept = table.column_count
	for kept > 0 && row_size(widths, is_text[:], kept, CELL_LEAST) > module.RECORD_SIZE_LIMIT {
		kept -= 1
	}
	bound := u32(assistant_contract.ACT_TABLE_CELL_BYTES)
	for bound > CELL_LEAST && row_size(widths, is_text[:], kept, bound) > module.RECORD_SIZE_LIMIT {
		bound -= 1
	}
	for column in 0 ..< kept {
		if is_text[column] {
			widths[column] = min(widths[column], bound)
		}
	}
	return kept
}

// description_and_rows writes the description of the first count columns
// and the rows of the result in scratch.
@(private = "file")
description_and_rows :: proc "contextless" (scratch: ^Scratch, table: ^conversation.Act_Table, widths: []u32, count: int, row_offset := 0) -> (file: []u8, size: u32, rows: []u8, ok: bool) {
	columns: Draw_Columns
	for column in 0 ..< count {
		columns.columns[column] = column_of(table, column, widths[column])
	}
	scratch.description = {}
	written: bool
	file, size, written = console_results.description_write(scratch.description[:], conversation.act_table_name(table), columns.columns[:count])
	if !written || size == 0 {
		return nil, 0, nil, false
	}
	start := clamp(row_offset, 0, table.row_count)
	available := table.row_count - start
	// description_write wrote the offset of each column in columns.
	rows = scratch.rows[:int(size) * available]
	for &value in rows {
		value = 0
	}
	for index in 0 ..< available {
		source_row := start + index
		place := rows[index * int(size):][:size]
		for column in 0 ..< count {
			if conversation.form_is_text(conversation.act_table_column_form(table, column)) {
				console_results.row_text_set(place, columns.columns[column], conversation.act_table_cell_text(table, source_row, column))
			} else {
				console_results.row_integer_set(place, columns.columns[column], conversation.act_table_cell_integer(table, source_row, column))
			}
		}
	}
	return file, size, rows, true
}

// columns_in_width gives how many columns, from the first, a line of a
// width in cells shows: each column as wide as its head and the widest of
// the cells that the drawer writes, with the gap of the console between
// two. One column at least. A record shows one field on each line: each
// column.
@(private = "file")
columns_in_width :: proc "contextless" (table: ^conversation.Act_Table, file: []u8, rows: []u8, size: u32, kept: int, width_cells: int) -> int {
	if table.shape == .Record || width_cells <= 0 {
		return kept
	}
	described, ok := module.record_type(file, 1)
	if !ok {
		return kept
	}
	used := 0
	row_count := size > 0 ? len(rows) / int(size) : 0
	for column in 0 ..< kept {
		item, found := module.field(file, described, u32(column))
		if !found {
			return max(column, 1)
		}
		_, unit := console_results.integer_part(item)
		width := console_results.head_length(int(item.name_count), unit)
		for row in 0 ..< row_count {
			buffer: [console_results.CELL_TEXT_CAPACITY]u8
			cell := console_results.cell_of(rows[row * int(size):][:size], item, buffer[:])
			width = max(width, console_results.text_columns(cell.text))
		}
		next := used + (column > 0 ? console_results.COLUMN_GAP : 0) + width
		if next > width_cells {
			return max(column, 1)
		}
		used = next
	}
	return kept
}

// columns_note writes the note of the columns that are not shown: their
// count, then their names in their order, as many as the width holds, and
// "..." when some names do not fit.
@(private = "file")
columns_note :: proc "contextless" (lines: ^Lines, table: ^conversation.Act_Table, shown: int, width_cells: int) {
	hidden := table.column_count - shown
	if hidden <= 0 {
		return
	}
	buffer: [256]u8
	writer := sentence.Writer {
		buffer = buffer[:],
	}
	sentence.write_part(&writer, u64(hidden))
	sentence.write_part(&writer, hidden == 1 ? " column more: " : " columns more: ")
	room := width_cells > 0 ? min(width_cells, len(buffer)) : len(buffer)
	for column in shown ..< table.column_count {
		name := conversation.act_table_column_name(table, column)
		separator := column > shown ? ", " : ""
		last := column == table.column_count - 1
		// The room keeps place for ", ..." after a name that is not the last.
		after := last ? 0 : len(", ...")
		if writer.count + len(separator) + len(name) + after > room {
			sentence.write_part(&writer, column > shown ? ", ..." : "...")
			break
		}
		sentence.write_part(&writer, separator)
		sentence.write_part(&writer, name)
	}
	note_write(lines, sentence.written(&writer))
}

@(private)
lines_reset :: proc "contextless" (lines: ^Lines) {
	lines.text_count, lines.part_count, lines.line_count, lines.shown_rows, lines.column = 0, 0, 0, 0, 0
	lines.full = false
	// No width: the drawer never narrows a column and never breaks a row;
	// the columns that the width cannot hold are not described at all.
	lines.sink = {data = lines, write = line_write, end_line = line_end, width = 0}
}

// record_value_room gives the bytes of a text value of a record: the cells
// of a line after the name of the widest field and the gaps that
// draw_record writes before and after it, so a long value ends with the
// cut mark inside the width and never runs past the window. A character
// takes a cell or more and one byte or more, so a value of so many bytes
// takes no more cells. A table, or a line with no width, has the bound of
// a cell.
@(private = "file")
record_value_room :: proc "contextless" (table: ^conversation.Act_Table, width_cells: int) -> u32 {
	if table.shape != .Record || width_cells <= 0 {
		return assistant_contract.ACT_TABLE_CELL_BYTES
	}
	name_width := 0
	for column in 0 ..< table.column_count {
		name_width = max(name_width, console_results.text_columns(conversation.act_table_column_name(table, column)))
	}
	room := width_cells - 2 * console_results.COLUMN_GAP - name_width
	return u32(clamp(room, CELL_LEAST, assistant_contract.ACT_TABLE_CELL_BYTES))
}

// draw writes the lines of a result at a width in cells, with at most
// row_limit rows; the drawer counts the rest against total_rows. ok is
// false when the description cannot be written.
draw :: proc "contextless" (lines: ^Lines, scratch: ^Scratch, table: ^conversation.Act_Table, width_cells: int, row_limit: int, row_offset := 0) -> (ok: bool) {
	lines_reset(lines)
	widths: [assistant_contract.ACT_TABLE_COLUMN_CAPACITY]u32
	kept := column_widths(table, widths[:], record_value_room(table, width_cells))
	if kept == 0 {
		return false
	}
	start := clamp(row_offset, 0, table.row_count)
	available := table.row_count - start
	file, size, rows := description_and_rows(scratch, table, widths[:], kept, start) or_return
	shown := columns_in_width(table, file, rows, size, kept, width_cells)
	if shown < kept {
		file, size, rows = description_and_rows(scratch, table, widths[:], shown, start) or_return
	}
	switch table.shape {
	case .Table:
		page_rows := clamp(row_limit, 0, available)
		lines.shown_rows = page_rows
		console_results.draw_table(&lines.sink, file, 1, rows, page_rows, "", table.total_rows)
	case .Record:
		lines.shown_rows = 1
		console_results.draw_record(&lines.sink, file, 1, rows[:size])
	}
	columns_note(lines, table, shown, width_cells)
	if lines.full {
		note_write(lines, "the result is cut: it passes the lines that the window keeps")
	}
	return true
}

// fit writes the lines of a result within line_room lines starting at
// row_offset: the most rows whose lines fit, so the note of the drawer
// counts the others; when no row fits, the first lines and one line that
// counts the lines not shown. ok is false when the description cannot be
// written, or line_room is under 1.
fit :: proc "contextless" (lines: ^Lines, scratch: ^Scratch, table: ^conversation.Act_Table, width_cells: int, line_room: int, row_offset := 0) -> (ok: bool) {
	if line_room < 1 {
		return false
	}
	start := clamp(row_offset, 0, table.row_count)
	available := table.row_count - start
	initial_limit := table.shape == .Record ? available : min(available, max(line_room - 1, 0))
	for row_limit := initial_limit; row_limit >= 0; row_limit -= 1 {
		draw(lines, scratch, table, width_cells, row_limit, start) or_return
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
	buffer: [96]u8
	note_write(lines, sentence.format(buffer[:], hidden, hidden == 1 ? " line more is not shown: the window is too small" : " lines more are not shown: the window is too small"))
	return true
}

// lines_clip keeps the first count lines.
@(private = "file")
lines_clip :: proc "contextless" (lines: ^Lines, count: int) {
	parts := 0
	for parts < lines.part_count && int(lines.parts[parts].line) < count {
		parts += 1
	}
	lines.part_count = parts
	lines.text_count = parts > 0 ? int(lines.parts[parts - 1].start) + int(lines.parts[parts - 1].count) : 0
	lines.line_count = count
	lines.column = 0
}

// line_text writes the text of a line in buffer, for a test and a log.
line_text :: proc "contextless" (lines: ^Lines, line: int, buffer: []u8) -> string {
	count := 0
	for index in 0 ..< lines.part_count {
		part := lines.parts[index]
		if int(part.line) == line {
			count += copy(buffer[count:], lines.text[part.start:][:part.count])
		}
	}
	return string(buffer[:count])
}

