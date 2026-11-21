package text_model

// The layout of a text in the window: its display rows. The editor
// computes it once after each change of the text, never in a frame; a
// frame reads only the rows that it shows. A line longer than the window
// goes on more rows, so no text is cut at the edge (docs/DESIGN.md, "5.
// Text").
//
// The font of the cells gives each character one cell, and a tab the
// cells to the next stop. The text is valid UTF-8, so the lead byte of a
// character says that a character starts: the layout decodes nothing.

COLUMNS :: 80 // The cells of one display row.
TAB_WIDTH :: 4 // A tab goes to the next column that is a multiple of it.
#assert(COLUMNS % TAB_WIDTH == 0) // A tab then never passes the end of a row: only a full row wraps.

// Each row but the last of a line holds COLUMNS cells, and a byte takes at
// most TAB_WIDTH cells: such a row holds at least COLUMNS / TAB_WIDTH
// bytes. Each other row starts after a line end, which is a byte too. So a
// text of TEXT_CAPACITY bytes has at most TEXT_CAPACITY + 1 rows.
ROW_CAPACITY :: TEXT_CAPACITY + 1

// One display row: where it starts in the text, and the line that it
// shows a part of. The first row of a line has the line number in the
// gutter.
Row :: struct {
	start: i32,
	line:  i32, // From 0.
}

Layout :: struct {
	rows:       [ROW_CAPACITY]Row,
	row_count:  int, // At least 1: an empty text has one empty row.
	line_count: int,
}

// cell_width gives the cells of a character whose lead byte is value, at
// a column of its row. A continuation byte takes none.
@(private)
cell_width :: proc "contextless" (value: u8, column: int) -> int {
	switch {
	case value & 0xC0 == 0x80:
		return 0
	case value == TAB:
		return TAB_WIDTH - column % TAB_WIDTH
	}
	return 1
}

// layout_compute makes the rows of the whole text.
layout_compute :: proc "contextless" (layout: ^Layout, text: ^Text) {
	layout.rows[0] = {start = 0, line = 0}
	layout.row_count = 1
	column, line := 0, 0
	length := text_length(text)
	for place in 0 ..< length {
		value := byte_at(text, place)
		// The bound of ROW_CAPACITY above holds for each valid text; the
		// test keeps a wrong text from a write past the array.
		if layout.row_count >= ROW_CAPACITY {
			break
		}
		if value == LINE_END {
			line += 1
			layout.rows[layout.row_count] = {start = i32(place + 1), line = i32(line)}
			layout.row_count += 1
			column = 0
			continue
		}
		width := cell_width(value, column)
		if width > 0 && column + width > COLUMNS {
			layout.rows[layout.row_count] = {start = i32(place), line = i32(line)}
			layout.row_count += 1
			column = 0
			width = cell_width(value, 0)
		}
		column += width
	}
	layout.line_count = line + 1
}

// row_of gives the row that shows a place of the text. A place at the
// start of a row that continues a line is on that row, not at the end of
// the row before.
row_of :: proc "contextless" (layout: ^Layout, place: int) -> int {
	low, high := 0, layout.row_count - 1
	for low < high {
		middle := (low + high + 1) / 2
		if int(layout.rows[middle].start) <= place {
			low = middle
		} else {
			high = middle - 1
		}
	}
	return low
}

// row_first_of_line says if a row is the first row of its line: the
// gutter shows the line number only there.
row_first_of_line :: proc "contextless" (layout: ^Layout, row: int) -> bool {
	return row == 0 || layout.rows[row - 1].line != layout.rows[row].line
}

// row_end gives the last place that the caret can take on a row: the line
// end of the last row of a line, the end of the text, or, for a row that
// continues on the next row, the start of its last character (the place
// after it is the first place of the next row).
row_end :: proc "contextless" (layout: ^Layout, text: ^Text, row: int) -> int {
	if row + 1 >= layout.row_count {
		return text_length(text)
	}
	next := layout.rows[row + 1]
	if next.line != layout.rows[row].line {
		return int(next.start) - 1 // The line end.
	}
	return previous_character_start(text, int(next.start))
}

// row_bytes_end gives the place after the last byte that a row shows: its
// line end and the next row are not shown on it.
row_bytes_end :: proc "contextless" (layout: ^Layout, text: ^Text, row: int) -> int {
	if row + 1 >= layout.row_count {
		return text_length(text)
	}
	next := layout.rows[row + 1]
	if next.line != layout.rows[row].line {
		return int(next.start) - 1
	}
	return int(next.start)
}

// column_of gives the cell column of a place on its row.
column_of :: proc "contextless" (layout: ^Layout, text: ^Text, row: int, place: int) -> int {
	column := 0
	for at in int(layout.rows[row].start) ..< place {
		column += cell_width(byte_at(text, at), column)
	}
	return column
}

// place_at_column gives the place of a row nearest to a cell column: the
// start of the first character whose middle is past the column. A column
// before the row gives its start; past it, row_end.
place_at_column :: proc "contextless" (layout: ^Layout, text: ^Text, row: int, column: int) -> int {
	end := row_end(layout, text, row)
	place := int(layout.rows[row].start)
	at_column := 0
	for place < end {
		width := cell_width(byte_at(text, place), at_column)
		if 2 * column < 2 * at_column + width {
			return place
		}
		at_column += width
		place += character_length(text, place)
	}
	return end
}

// The moves of the caret.
Motion :: enum u8 {
	Left       = 0, // The character before.
	Right      = 1, // The character after.
	Up         = 2, // The row before, at the goal column.
	Down       = 3, // The row after, at the goal column.
	Line_Start = 4, // The start of the line (Home).
	Line_End   = 5, // The end of the line (End).
	Page_Up    = 6, // The rows of one page before.
	Page_Down  = 7, // The rows of one page after.
	Text_Start = 8, // Control with Home.
	Text_End   = 9, // Control with End.
}

// caret_move moves the caret. With extend (Shift), the anchor stays and
// the selection grows or shrinks; with no extend, nothing is selected
// after it, and Left or Right with a selection goes to its first or its
// last place. page_rows is the rows of one page. The layout is the layout
// of the text now.
caret_move :: proc "contextless" (text: ^Text, layout: ^Layout, motion: Motion, extend: bool, page_rows: int) {
	length := text_length(text)
	keeps_goal := false
	switch motion {
	case .Left:
		if !extend && selection_count(text) > 0 {
			text.caret, _ = selection(text)
		} else if text.caret > 0 {
			text.caret = previous_character_start(text, text.caret)
		}
	case .Right:
		if !extend && selection_count(text) > 0 {
			_, text.caret = selection(text)
		} else if text.caret < length {
			text.caret += character_length(text, text.caret)
		}
	case .Up, .Down, .Page_Up, .Page_Down:
		row := row_of(layout, text.caret)
		if !text.has_goal {
			text.goal_column = column_of(layout, text, row, text.caret)
			text.has_goal = true
		}
		step := 1
		if motion == .Page_Up || motion == .Page_Down {
			step = max(page_rows, 1)
		}
		target := motion == .Up || motion == .Page_Up ? row - step : row + step
		switch {
		case target < 0:
			text.caret = 0
		case target >= layout.row_count:
			text.caret = length
		case:
			text.caret = place_at_column(layout, text, target, text.goal_column)
		}
		keeps_goal = true
	case .Line_Start:
		row := row_of(layout, text.caret)
		for row > 0 && !row_first_of_line(layout, row) {
			row -= 1
		}
		text.caret = int(layout.rows[row].start)
	case .Line_End:
		row := row_of(layout, text.caret)
		for row + 1 < layout.row_count && layout.rows[row + 1].line == layout.rows[row].line {
			row += 1
		}
		text.caret = row_end(layout, text, row)
	case .Text_Start:
		text.caret = 0
	case .Text_End:
		text.caret = length
	}
	if !keeps_goal {
		text.has_goal = false
	}
	if !extend {
		text.anchor = text.caret
	}
}
