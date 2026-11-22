#+build !freestanding
package wide_cells

import "core:testing"

Test_Cell :: Cell(u8)

IDEOGRAPH :: '日'
SECOND_IDEOGRAPH :: '本'

// A wide character takes its column as the lead and the next as the trail.
@(test)
a_wide_character_takes_a_lead_and_a_trail :: proc(t: ^testing.T) {
	row: [6]Test_Cell
	next, result := row_put(row[:], 1, IDEOGRAPH, 7)
	testing.expect_value(t, result, Put_Result.Placed)
	testing.expect_value(t, next, 3)
	testing.expect_value(t, row[1].part, Cell_Part.Wide_Lead)
	testing.expect_value(t, row[2].part, Cell_Part.Wide_Trail)
	testing.expect_value(t, row[1].payload, 7)
	testing.expect_value(t, row[2].payload, 7)
	testing.expect(t, row_is_whole(row[:]))
	// A character of no width takes no cell.
	next, result = row_put(row[:], 3, 0x0301, 1)
	testing.expect_value(t, result, Put_Result.Zero_Width)
	testing.expect_value(t, next, 3)
	testing.expect_value(t, row[3].part, Cell_Part.Empty)
}

// The right edge: a wide character at the last column does not fit, and
// the row is the same; at the column before it, it fits.
@(test)
a_wide_character_at_the_last_column_does_not_fit :: proc(t: ^testing.T) {
	row: [4]Test_Cell
	_, result := row_put(row[:], 3, IDEOGRAPH, 0)
	testing.expect_value(t, result, Put_Result.No_Room)
	testing.expect_value(t, row[3].part, Cell_Part.Empty)
	next, placed := row_put(row[:], 2, IDEOGRAPH, 0)
	testing.expect_value(t, placed, Put_Result.Placed)
	testing.expect_value(t, next, 4)
	// Out of the row: refused, and nothing changes.
	for column in ([?]int{-1, 4, 5, max(int)}) {
		_, refused := row_put(row[:], column, 'a', 0)
		testing.expect_value(t, refused, Put_Result.No_Room)
	}
	testing.expect(t, row_is_whole(row[:]))
	// A grid of one column: the wide character takes its one cell.
	narrow: [1]Test_Cell
	_, alone := row_put(narrow[:], 0, IDEOGRAPH, 0)
	testing.expect_value(t, alone, Put_Result.Placed)
	testing.expect_value(t, narrow[0].part, Cell_Part.Single)
}

// A write over either half of a wide character clears the other half.
@(test)
a_write_over_one_half_clears_the_other :: proc(t: ^testing.T) {
	row: [6]Test_Cell
	row_put(row[:], 2, IDEOGRAPH, 0)
	row_put(row[:], 2, 'a', 0) // Over the lead.
	testing.expect_value(t, row[2].part, Cell_Part.Single)
	testing.expect_value(t, row[3].part, Cell_Part.Empty)
	testing.expect(t, row_is_whole(row[:]))

	row_put(row[:], 2, IDEOGRAPH, 0)
	row_put(row[:], 3, 'b', 0) // Over the trail.
	testing.expect_value(t, row[2].part, Cell_Part.Empty)
	testing.expect_value(t, row[3].character, 'b')
	testing.expect(t, row_is_whole(row[:]))

	// A wide character over the trail of one and the lead of another
	// clears both outer halves.
	row = {}
	row_put(row[:], 0, IDEOGRAPH, 0)
	row_put(row[:], 2, SECOND_IDEOGRAPH, 0)
	row_put(row[:], 1, 'x', 0)
	testing.expect_value(t, row[0].part, Cell_Part.Empty)
	testing.expect_value(t, row[2].part, Cell_Part.Wide_Lead)
	row_put(row[:], 1, IDEOGRAPH, 0)
	testing.expect_value(t, row[1].part, Cell_Part.Wide_Lead)
	testing.expect_value(t, row[2].part, Cell_Part.Wide_Trail)
	testing.expect_value(t, row[2].character, IDEOGRAPH)
	testing.expect_value(t, row[3].part, Cell_Part.Empty)
	testing.expect(t, row_is_whole(row[:]))
}

// Backspace and erase clear both halves, from either half.
@(test)
backspace_clears_a_wide_character_whole :: proc(t: ^testing.T) {
	row: [6]Test_Cell
	column := 0
	column, _ = row_put(row[:], column, 'a', 0)
	column, _ = row_put(row[:], column, IDEOGRAPH, 0)
	testing.expect_value(t, column, 3)
	column = row_backspace(row[:], column)
	testing.expect_value(t, column, 1)
	testing.expect_value(t, row[1].part, Cell_Part.Empty)
	testing.expect_value(t, row[2].part, Cell_Part.Empty)
	column = row_backspace(row[:], column)
	testing.expect_value(t, column, 0)
	testing.expect_value(t, row_backspace(row[:], 0), 0)
	testing.expect_value(t, row_backspace(row[:], -1), 0)
	testing.expect_value(t, row_backspace(row[:], 7), 6)
	// Erase from the lead and from the trail.
	row_put(row[:], 4, IDEOGRAPH, 0)
	testing.expect_value(t, row_erase(row[:], 5), 4)
	testing.expect_value(t, row[4].part, Cell_Part.Empty)
	row_put(row[:], 4, IDEOGRAPH, 0)
	testing.expect_value(t, row_erase(row[:], 4), 4)
	testing.expect_value(t, row[5].part, Cell_Part.Empty)
	testing.expect_value(t, row_erase(row[:], 6), 6)
	testing.expect(t, row_is_whole(row[:]))
}

// The flow wraps a wide character that finds one column left to the next
// row, and the last column of the row stays empty.
@(test)
the_flow_wraps_a_wide_character_at_the_right_edge :: proc(t: ^testing.T) {
	flow := Flow{columns = 5}
	places: [dynamic][2]int
	defer delete(places)
	for character in "abcd日e" {
		row, column, _ := flow_place(&flow, character)
		append(&places, [2]int{row, column})
	}
	testing.expect_value(t, places[3], [2]int{0, 3})
	testing.expect_value(t, places[4], [2]int{1, 0}, ) // The ideograph: one column was left.
	testing.expect_value(t, places[5], [2]int{1, 2})
	// Exactly at the edge: the ideograph fills the last two columns.
	flow = {columns = 5}
	for character in "abc日" {
		flow_place(&flow, character)
	}
	testing.expect_value(t, flow.row, 0)
	cursor_row, cursor_column := flow_cursor(flow)
	testing.expect_value(t, cursor_row, 1)
	testing.expect_value(t, cursor_column, 0)
	// A mark of no width stays at the place of the flow.
	_, _, width := flow_place(&flow, 0x0301)
	testing.expect_value(t, width, 0)
	testing.expect_value(t, flow.column, 5)
	// A flow of zero columns is a flow of one.
	empty := Flow{}
	row, column, one := flow_place(&empty, IDEOGRAPH)
	testing.expect_value(t, [3]int{row, column, one}, [3]int{0, 0, 1})
}

// The scrollback: lines that the terminal keeps are laid out in rows of
// the view again at each view, from any first line. A line of the text
// does not wrap: a wide character that does not fit ends the row with the
// continuation mark, which clears the half that it covers. Each row is
// whole, and a line gives the same cells wherever the view starts.
@(test)
kept_lines_give_whole_rows_from_any_first_line :: proc(t: ^testing.T) {
	COLUMNS :: 7
	lines := [?]string{"abc日本語", "日本語です", "a日b本c語", "abcdef日", "한국어 텍스트", "ｆｕｌｌ"}
	lay :: proc(text: string) -> (row: [COLUMNS]Test_Cell) {
		column := 0
		for character in text {
			next, result := row_put(row[:], column, character, 0)
			if result == .No_Room {
				row_put(row[:], COLUMNS - 1, '>', 1)
				break
			}
			column = next
		}
		return
	}
	first_view: [len(lines)][COLUMNS]Test_Cell
	for text, index in lines {
		first_view[index] = lay(text)
		testing.expectf(t, row_is_whole(first_view[index][:]), "line %d: a half of a wide character alone", index)
	}
	// "abcdef日": the ideograph finds one column: the mark ends the row.
	testing.expect_value(t, first_view[3][6].character, '>')
	// "abc日本語": the third ideograph starts at column 7, past the row;
	// the mark at the last column clears the trail of 本 and its lead.
	testing.expect_value(t, first_view[0][6].character, '>')
	testing.expect_value(t, first_view[0][5].part, Cell_Part.Empty)
	for top in 0 ..< len(lines) {
		for index in top ..< len(lines) {
			testing.expect_value(t, lay(lines[index]), first_view[index])
		}
	}
}
