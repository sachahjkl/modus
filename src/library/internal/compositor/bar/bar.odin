// The bar of the desktop: the names of the modules, and the place of each
// button of the bar and of each line of its two menus, the start menu and
// the menu of the windows. The compositor draws them; the
// modus tool clicks them in the machine test. The two read this one table.
// The palette (src/library/internal/compositor/palette) lists the same names.
package bar

import process_page "modus:contract/disk_process_page"
import "modus:mark"
import "modus:text_rendering"

// The modules that the start menu offers, in its order.
@(rodata)
names := [?]string{"boot", "pages", "log", "console", "monitor", "plasma", "life", "paint", "fault", "hall_of_fame", "heron", "rings", "threads", "workers", "rights", "origin", "budget", "limits", "processors", "flow", "crowd", "clock", "randomness", "flood", "tally", "manual", "frames", "disk", "notes", "imports", "net", "remote", "server", "inspect", "debugger_window", "locks", "errors", "scheduler", "interface_elements", "vector_glyphs", "interface_font", "pointers", "settings", "tables", "interface_through_module", "address_space", "cryptography_vectors", "quic_echo", "extended_state", "return_fault", "fault_ring", "kernel_events"}

LABEL :: "start" // The text of the button that opens the start menu.
CHARACTER_WIDTH :: 8 // The font of the cells.
START :: 80 // After the mark of the system.
PADDING :: 8 // Pixels on each side of the text of a button.
HEIGHT :: 32 // The height of the bar.
BUTTON_Y :: 4 // The top of a button in the bar.
BUTTON_HEIGHT :: 24 // The height of a button.
LINE_HEIGHT :: 24 // One line of a menu.
BORDER :: 1 // The border of a menu, in pixels.
TITLE :: 40 // The title of a menu, as the title of a card.
COLUMNS :: 2 // The start menu has two columns of names.
COLUMN_LEAST :: 120 // The title of the menu fits.

// Layout: the widths of the texts of the bar, measured in the font that
// draws them: the names of the bar are in the interface font; with no
// interface font, in the font of the cells (docs/DESIGN.md, section 5). The
// place of each button and of each line of a menu comes from it, so a
// press lands on the entry that the eye sees. The compositor measures it
// once, and again when the font changes; it writes in its log which font
// it is, and the modus tool measures the same layout from the same font
// file.
//
// The layout also holds the edge of the screen that the bar is on, and the
// logical height of the screen: every place below comes from them, so a
// reader of the places never adds an offset of its own
// (src/md/features/bar_edge.md). The zero value is a bar at the top.
Layout :: struct {
	label_width:         int, // LABEL.
	windows_label_width: int, // WINDOWS_LABEL.
	longest_name_width:  int, // The widest of the names and of LABEL.
	edge:                Edge, // The edge of the screen that holds the bar.
	screen_height:       int, // The logical height of the screen: the place of a bar at the bottom.
}

// The edge of the screen that holds the bar. A menu of the bar opens away
// from it.
Edge :: enum u8 {
	Top, // The menus open down from the bar.
	Bottom, // The menus open up from the bar.
}

// placed gives a layout with the same widths on an edge of a screen.
placed :: proc "contextless" (layout: Layout, edge: Edge, screen_height: int) -> Layout {
	result := layout
	result.edge = edge
	result.screen_height = max(screen_height, 0)
	return result
}

// top gives the logical y of the first row of the bar. A screen lower than
// the bar keeps the bar at 0, so no row of it is above the screen.
top :: proc "contextless" (layout: Layout) -> int {
	switch layout.edge {
	case .Top:
		return 0
	case .Bottom:
		return max(0, layout.screen_height - HEIGHT)
	}
	return 0
}

// menu_top gives the y of a menu or a popover of the bar of a height:
// under a bar at the top, over a bar at the bottom, never above the screen.
menu_top :: proc "contextless" (layout: Layout, height: int) -> int {
	switch layout.edge {
	case .Top:
		return top(layout) + HEIGHT
	case .Bottom:
		return max(0, top(layout) - height)
	}
	return top(layout) + HEIGHT
}

// inside_bar reports whether a point is on a row of the bar.
inside_bar :: proc "contextless" (layout: Layout, point_y: int) -> bool {
	bar_top := top(layout)
	return point_y >= bar_top && point_y < bar_top + HEIGHT
}

// text_width_in gives the width of a text in pixels in a face at the text
// size of scale 1, rounded up: the measure of src/library/modus/interface
// (text_measured_width), from the font file that the copy of the text
// rendering of the caller opened. None, or a face that the caller has not
// opened: the font of the cells.
text_width_in :: proc "contextless" (face: text_rendering.Face, text: string) -> int {
	if spacing, ok := text_rendering.spacing_of(face, text_rendering.TEXT_SIZE_OF_SCALE_ONE); ok {
		width, _ := text_rendering.text_width(&spacing, transmute([]u8)text)
		return int((width + 63) / 64)
	}
	return len(text) * CHARACTER_WIDTH
}

// layout_of measures the texts of the bar in a face: the regular weight of
// the interface font, or None for the font of the cells.
layout_of :: proc "contextless" (face: text_rendering.Face) -> (layout: Layout) {
	layout.label_width = text_width_in(face, LABEL)
	layout.windows_label_width = text_width_in(face, WINDOWS_LABEL)
	layout.longest_name_width = layout.label_width
	for name in names {
		layout.longest_name_width = max(layout.longest_name_width, text_width_in(face, name))
	}
	return layout
}

// The mark of the system at the left of the bar, where the name of the
// system was: the heron at a cell size of 1, 24 by 24 pixels, at the height
// of the buttons. It ends before START.
MARK_X :: 16
MARK_Y :: BUTTON_Y // The top of the mark.
MARK_CELL_SIZE :: 1 // One pixel for each cell of the heron.
MARK_SIZE :: mark.HERON_GRID_SIZE * MARK_CELL_SIZE // The side of the mark: 24 pixels.
#assert(MARK_X + MARK_SIZE <= START && MARK_Y + MARK_SIZE <= HEIGHT)

// mark_y gives the y of the mark on the screen.
mark_y :: proc "contextless" (layout: Layout) -> int {
	return top(layout) + MARK_Y
}

// rows gives the lines of one column of the start menu.
rows :: proc "contextless" () -> int {
	return (len(names) + COLUMNS - 1) / COLUMNS
}

// button gives the place of the button of the bar that opens the start
// menu: its label and a padding on each side.
button :: proc "contextless" (layout: Layout) -> (x, y, width, height: int) {
	return START, top(layout) + BUTTON_Y, layout.label_width + 2 * PADDING, BUTTON_HEIGHT
}

// column_width gives the width of one column of the start menu:
// the widest name and a padding on each side, and COLUMN_LEAST at least.
column_width :: proc "contextless" (layout: Layout) -> int {
	longest := max(layout.longest_name_width, layout.label_width)
	return max(longest + 2 * PADDING, COLUMN_LEAST)
}

// menu gives the place of the start menu, next to its button, away from
// the edge of the bar.
menu :: proc "contextless" (layout: Layout) -> (x, y, width, height: int) {
	height = TITLE + rows() * LINE_HEIGHT + 2 * BORDER
	return START, menu_top(layout, height), COLUMNS * column_width(layout) + 2 * BORDER, height
}

// line gives the place of the line of names[index] in the menu.
line :: proc "contextless" (layout: Layout, index: int) -> (x, y, width, height: int) {
	left, top, _, _ := menu(layout)
	return left + BORDER + index / rows() * column_width(layout), top + BORDER + TITLE + index % rows() * LINE_HEIGHT, column_width(layout), LINE_HEIGHT
}

// line_at gives the index of the line of the menu at a point, or -1.
line_at :: proc "contextless" (layout: Layout, point_x, point_y: int) -> int {
	for _, index in names {
		x, y, width, height := line(layout, index)
		if point_x >= x && point_x < x + width && point_y >= y && point_y < y + height {
			return index
		}
	}
	return -1
}

// button_center gives the middle of the button that opens the menu.
button_center :: proc "contextless" (layout: Layout) -> (center_x, center_y: int) {
	x, y, width, height := button(layout)
	return x + width / 2, y + height / 2
}

// center gives the middle of the line of a module in the menu. ok is
// false if the menu does not have the module.
center :: proc "contextless" (layout: Layout, module: string) -> (center_x, center_y: int, ok: bool) {
	for name, index in names {
		if name == module {
			x, y, width, height := line(layout, index)
			return x + width / 2, y + height / 2, true
		}
	}
	return 0, 0, false
}

// The menu of the windows: one line for each window, with its title. A press
// on a line brings the window to the front.
WINDOWS_LABEL :: "windows"
WINDOWS_GAP :: 8 // Between the two buttons.
// The line of a disk process in the menu of the windows: its nickname, this
// gap, then its hash prefix in the font of the cells, faded
// (modus:contract/disk_process_page).
WINDOWS_HASH_GAP :: 8
WINDOWS_HASH_WIDTH :: process_page.HASH_PREFIX_DIGITS * CHARACTER_WIDTH
// The room of a title in the menu of the windows, in pixels: a title is
// cut to it in the font that draws it. It is the room of the larger of two
// lines in the font of the cells: the 32 cells of the longest title of a
// window (system.Name), and the longest nickname with its hash prefix. So
// the menu has one width in both fonts.
WINDOWS_TITLE_ROOM :: max(32 * CHARACTER_WIDTH, process_page.NICKNAME_LIMIT * CHARACTER_WIDTH + WINDOWS_HASH_GAP + WINDOWS_HASH_WIDTH)
// The place of a title in its line: after the square that marks the window
// with the focus.
WINDOWS_TITLE_X :: 24

// windows_button gives the place of the button that opens the menu of the windows.
windows_button :: proc "contextless" (layout: Layout) -> (x, y, width, height: int) {
	left, top, button_width, button_height := button(layout)
	return left + button_width + WINDOWS_GAP, top, layout.windows_label_width + 2 * PADDING, button_height
}

// windows_menu gives the place of the menu of count windows, next to its
// button, away from the edge of the bar.
windows_menu :: proc "contextless" (layout: Layout, count: int) -> (x, y, width, height: int) {
	left, _, _, _ := windows_button(layout)
	height = TITLE + count * LINE_HEIGHT + 2 * BORDER
	return left, menu_top(layout, height), WINDOWS_TITLE_ROOM + 2 * PADDING + 2 * BORDER, height
}

// windows_line gives the place of a line of the menu of the windows. Over a
// bar at the bottom the first line is next to the bar and the next ones go
// up: the place of a line then needs no count of the windows, as under a
// bar at the top.
windows_line :: proc "contextless" (layout: Layout, index: int) -> (x, y, width, height: int) {
	left, menu_y, menu_width, _ := windows_menu(layout, 0)
	switch layout.edge {
	case .Top:
		return left + BORDER, menu_y + BORDER + TITLE + index * LINE_HEIGHT, menu_width - 2 * BORDER, LINE_HEIGHT
	case .Bottom:
		return left + BORDER, top(layout) - BORDER - (index + 1) * LINE_HEIGHT, menu_width - 2 * BORDER, LINE_HEIGHT
	}
	return left + BORDER, menu_y + BORDER + TITLE + index * LINE_HEIGHT, menu_width - 2 * BORDER, LINE_HEIGHT
}

// windows_line_at gives the index of the line of the menu of count windows
// at a point, or -1.
windows_line_at :: proc "contextless" (layout: Layout, count, point_x, point_y: int) -> int {
	for index in 0 ..< count {
		x, y, width, height := windows_line(layout, index)
		if point_x >= x && point_x < x + width && point_y >= y && point_y < y + height {
			return index
		}
	}
	return -1
}

// windows_button_center gives the middle of the button of the menu of the windows.
windows_button_center :: proc "contextless" (layout: Layout) -> (center_x, center_y: int) {
	x, y, width, height := windows_button(layout)
	return x + width / 2, y + height / 2
}

// windows_line_center gives the middle of a line of the menu of the windows.
windows_line_center :: proc "contextless" (layout: Layout, index: int) -> (center_x, center_y: int) {
	x, y, width, height := windows_line(layout, index)
	return x + width / 2, y + height / 2
}

// A button of the bar.
Bar_Button :: enum u8 {
	None, // No button: the pointer is elsewhere.
	Start, // The button that opens the start menu.
	Windows, // The button that opens the menu of the windows.
}

// button_at gives the button of the bar at a point.
button_at :: proc "contextless" (layout: Layout, point_x, point_y: int) -> Bar_Button {
	inside :: proc "contextless" (point_x, point_y, x, y, width, height: int) -> bool {
		return point_x >= x && point_x < x + width && point_y >= y && point_y < y + height
	}
	if x, y, width, height := button(layout); inside(point_x, point_y, x, y, width, height) {
		return .Start
	}
	if x, y, width, height := windows_button(layout); inside(point_x, point_y, x, y, width, height) {
		return .Windows
	}
	return .None
}
