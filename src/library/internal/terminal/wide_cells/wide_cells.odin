// The cells of a row of the terminal for characters of two columns
// (src/md/features/glyphs_on_demand.md, "Characters of two columns").
//
// A wide character (text_rendering.cell_width_of gives Two) takes two
// cells: the cell of its column holds it as the lead, and the next cell is
// its trail, which draws no glyph of its own. Each operation keeps a row
// whole: a lead is always followed by its trail, and a trail always
// follows its lead. A write over one half of a wide character clears the
// other half, so no half of a glyph stays alone. A wide character that
// finds one column left at the end of a row goes to the next row in a flow
// (the edit line), or does not fit in a row that does not wrap (a line of
// the text, which the terminal ends with its continuation mark).
//
// The cells carry a payload of the caller (the style of the cell): this
// package decides where a character goes, never how it is drawn.
package wide_cells

import "modus:text_rendering"

// What a cell holds.
Cell_Part :: enum u8 {
	Empty      = 0, // No character.
	Single     = 1, // A character of one column.
	Wide_Lead  = 2, // The first column of a wide character: the cell holds it.
	Wide_Trail = 3, // The second column of a wide character: the character is in the cell before.
}

// One cell: the character, its part, and the payload of the caller.
Cell :: struct($Payload: typeid) {
	character: rune,
	part:      Cell_Part,
	payload:   Payload,
}

// What a write in a row did.
Put_Result :: enum u8 {
	Placed     = 0, // The character is in the row.
	Zero_Width = 1, // A character of no width: it takes no cell, and the row is the same.
	No_Room    = 2, // The character does not fit before the end of the row: the row is the same.
}

// width_of gives the columns of a character in a grid of columns columns:
// a wide character in a grid of one column takes its one cell.
width_of :: proc "contextless" (character: rune, columns: int) -> int {
	width := int(text_rendering.cell_width_of(character))
	return columns < 2 ? min(width, 1) : width
}

// halves_clear clears, around the cells from first to first + count - 1,
// each half of a wide character whose other half is in those cells: the
// cells are about to be written.
@(private)
halves_clear :: proc "contextless" (row: []Cell($Payload), first: int, count: int) {
	last := first + count - 1
	if first > 0 && row[first].part == .Wide_Trail {
		row[first - 1] = {}
	}
	if last + 1 < len(row) && row[last].part == .Wide_Lead {
		row[last + 1] = {}
	}
}

// row_put writes a character at a column of a row, over what the cells
// held. next is the column after the character. A column out of the row is
// No_Room.
row_put :: proc "contextless" (row: []Cell($Payload), column: int, character: rune, payload: Payload) -> (next: int, result: Put_Result) {
	width := width_of(character, len(row))
	if width == 0 {
		return column, .Zero_Width
	}
	// Compared without a sum: a column near the largest int must not wrap.
	if column < 0 || column > len(row) - width {
		return column, .No_Room
	}
	halves_clear(row, column, width)
	if width == 1 {
		row[column] = {character = character, part = .Single, payload = payload}
		return column + 1, .Placed
	}
	row[column] = {character = character, part = .Wide_Lead, payload = payload}
	row[column + 1] = {character = character, part = .Wide_Trail, payload = payload}
	return column + 2, .Placed
}

// row_erase clears the character that holds a column, both halves of a
// wide character. start is the first column of that character: the column
// of a lead for a trail. A column out of the row changes nothing.
row_erase :: proc "contextless" (row: []Cell($Payload), column: int) -> (start: int) {
	if column < 0 || column >= len(row) {
		return column
	}
	start = column
	if row[column].part == .Wide_Trail && column > 0 {
		start = column - 1
	}
	if row[start].part == .Wide_Lead && start + 1 < len(row) {
		row[start + 1] = {}
	}
	row[start] = {}
	return start
}

// row_backspace clears the character before a column, both halves of a
// wide character, and gives the column where it started: the column of
// the cursor after a Backspace. At column 0 nothing changes.
row_backspace :: proc "contextless" (row: []Cell($Payload), column: int) -> (cursor: int) {
	if column <= 0 || column > len(row) {
		return max(min(column, len(row)), 0)
	}
	return row_erase(row, column - 1)
}

// row_is_whole says if each lead of a row is followed by its trail and each
// trail follows its lead, with the same character.
row_is_whole :: proc "contextless" (row: []Cell($Payload)) -> bool {
	for cell, column in row {
		switch cell.part {
		case .Empty, .Single:
		case .Wide_Lead:
			if column + 1 >= len(row) || row[column + 1].part != .Wide_Trail || row[column + 1].character != cell.character {
				return false
			}
		case .Wide_Trail:
			if column == 0 || row[column - 1].part != .Wide_Lead || row[column - 1].character != cell.character {
				return false
			}
		}
	}
	return true
}

// A flow of characters over rows of columns cells, as the edit line goes
// on in the rows under it: the place of the next character.
Flow :: struct {
	columns: int,
	row:     int,
	column:  int,
}

// flow_place gives the row and the column of the next character, and moves
// the flow after it. A wide character that finds one column left goes to
// the start of the next row, and the last column of the row stays empty. A
// character of no width takes no column: width is 0, and the flow stays.
flow_place :: proc "contextless" (flow: ^Flow, character: rune) -> (row: int, column: int, width: int) {
	columns := max(flow.columns, 1)
	width = width_of(character, columns)
	if width == 0 {
		return flow.row, flow.column, 0
	}
	if flow.column + width > columns {
		flow.row += 1
		flow.column = 0
	}
	row, column = flow.row, flow.column
	flow.column += width
	return
}

// flow_cursor gives the place of a cursor at the end of a flow: after the
// last character, or at the start of the next row when the row is full.
flow_cursor :: proc "contextless" (flow: Flow) -> (row: int, column: int) {
	if flow.column >= max(flow.columns, 1) {
		return flow.row + 1, 0
	}
	return flow.row, flow.column
}
