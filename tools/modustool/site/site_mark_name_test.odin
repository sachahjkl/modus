package site

import "core:testing"
import "modus:support/mark"
import "modustool:resources"

// The sizes of the name of the mark on the site: a whole count of pixels
// for a cell of the font of the name, and the box of the name that
// name_size gives at that cell size.
@(test)
site_mark_name_sizes_are_whole_cells_of_the_font :: proc(t: ^testing.T) {
	for cell_size in ([]int{SITE_MARK_NAME_CELL_SIZE, SITE_MARK_NAME_HOME_CELL_SIZE}) {
		width, height := mark.name_size(cell_size)
		testing.expect_value(t, site_mark_name_font_size(cell_size) * resources.MARK_FONT_UNITS_OF_A_CELL, cell_size * resources.MARK_FONT_UNITS_OF_THE_EM)
		testing.expect_value(t, site_mark_name_font_size(cell_size) % resources.MARK_FONT_CELLS_OF_THE_EM, 0)
		testing.expect_value(t, width, mark.NAME_COLUMNS * cell_size)
		testing.expect_value(t, height, mark.NAME_ROWS * cell_size)
	}
}
