// The bar of the desktop: the names of the modules, and the place of each
// part of the bar and of its two menus: the heron button and the start
// menu, the button and the menu of the windows, the plates of the windows.
// The compositor draws them; the modus tool clicks them in the machine
// test. The two read this one table. The palette
// (src/library/internal/compositor/palette) lists the same names.
// src/md/features/desktop_shell_look.md holds the design of the look.
package bar

import process_page "modus:contract/disk_process_page"
import "modus:mark"
import "modus:text_rendering"

// The sections of the start menu, in its order: by the module category of
// each module (src/md/features/desktop_shell_look.md, "The start menu").
// A service, a library and a test module are in no section.
Menu_Section :: enum u8 {
	Applications, // The programs of the principal: the top of the left pane.
	Tools, // The system tools and the developer tools: under the applications.
	Demonstrations, // The demonstrations: the right pane, closed until the principal opens it.
}

// The modules that the start menu offers (names), the icon of each
// (name_icons), APPLICATION_COUNT and TOOL_COUNT are in
// start_menu_names.odin, which the build of the tool writes from the table
// of the modules: each module of the boot image with an entry whose
// category is an application, a system tool, a developer tool or a
// demonstration, by section, each section in the order of the alphabet. A
// new module of such a category gets its line with no list to change.
LEFT_COUNT :: APPLICATION_COUNT + TOOL_COUNT // The names of the left pane.
DEMONSTRATION_COUNT :: len(names) - LEFT_COUNT // The names of the right pane.
#assert(LEFT_COUNT < len(names))

// section_of gives the section of the line of names[index].
section_of :: proc "contextless" (index: int) -> Menu_Section {
	switch {
	case index < APPLICATION_COUNT:
		return .Applications
	case index < LEFT_COUNT:
		return .Tools
	}
	return .Demonstrations
}

// section_line_count gives the lines of a section.
section_line_count :: proc "contextless" (section: Menu_Section) -> int {
	switch section {
	case .Applications:
		return APPLICATION_COUNT
	case .Tools:
		return TOOL_COUNT
	case .Demonstrations:
		return DEMONSTRATION_COUNT
	}
	return 0
}

// The headings of the sections, as the menu shows them.
@(rodata)
section_headings := [Menu_Section]string {
	.Applications   = "Applications",
	.Tools          = "Tools",
	.Demonstrations = "Demonstrations",
}

// The bytes of the label of a name: a name of the menu is shorter.
LABEL_BYTES :: 32

// label_of gives the label of a module name for a reader: each "_" a
// space. The name is an identifier, which the palette and the console
// take; the menu is read. A name longer than LABEL_BYTES is given as it is.
label_of :: proc "contextless" (name: string, buffer: ^[LABEL_BYTES]u8) -> string {
	if len(name) > LABEL_BYTES {
		return name
	}
	for index in 0 ..< len(name) {
		buffer[index] = name[index] == '_' ? ' ' : name[index]
	}
	return string(buffer[:len(name)])
}

// shown_count gives the names whose lines the menu shows: the left pane,
// and the demonstrations when they are open. The names of the right pane
// are the last, so the lines shown are names[:shown_count].
shown_count :: proc "contextless" (layout: Layout) -> int {
	return layout.demonstrations_open ? len(names) : LEFT_COUNT
}

CHARACTER_WIDTH :: 8 // The font of the cells.
PADDING :: 8 // Pixels on each side of the text of a line or a pill.
HEIGHT :: 32 // The height of the bar.

// A plate of the bar: the heron button, the button of the windows, the
// plate of a group of windows. Each has the same top and height, so the
// row of plates reads as one band.
PLATE_Y :: 2 // The top of a plate in the bar.
PLATE_HEIGHT :: 28

// A pill of the tray at the right of the bar: a quieter, lower plate.
TRAY_Y :: 4
TRAY_HEIGHT :: 24

// The heron button, at the left of the bar: it opens the start menu.
START_BUTTON_X :: 4
START_BUTTON_WIDTH :: 44

// The button of the windows, next to the heron button: it opens the menu
// of the windows, one line for each window.
BUTTON_GAP :: 4
WINDOWS_BUTTON_X :: START_BUTTON_X + START_BUTTON_WIDTH + BUTTON_GAP
WINDOWS_BUTTON_WIDTH :: 28

// The line of one pixel between the buttons and the plates of the windows.
DIVIDER_GAP :: 6
DIVIDER_X :: WINDOWS_BUTTON_X + WINDOWS_BUTTON_WIDTH + DIVIDER_GAP

// The plates of the windows, one for each name: they start after the divider.
PLATES_X :: DIVIDER_X + 1 + DIVIDER_GAP
PLATE_WIDTH :: 160
PLATE_GAP :: 2

// An icon of the system: a square of ICON_SIZE pixels (icons.odin), and
// the gap between it and the text after it.
ICON_SIZE :: 16
ICON_GAP :: 8

// The mark of the system: the heron at a cell size of 1, 24 by 24 pixels,
// in the middle of the heron button.
MARK_CELL_SIZE :: 1 // One pixel for each cell of the heron.
MARK_SIZE :: mark.HERON_GRID_SIZE * MARK_CELL_SIZE // The side of the mark: 24 pixels.
MARK_X :: START_BUTTON_X + (START_BUTTON_WIDTH - MARK_SIZE) / 2
MARK_Y :: PLATE_Y + (PLATE_HEIGHT - MARK_SIZE) / 2 // The top of the mark in the bar.
#assert(MARK_X >= START_BUTTON_X && MARK_X + MARK_SIZE <= START_BUTTON_X + START_BUTTON_WIDTH)
#assert(MARK_Y >= PLATE_Y && MARK_Y + MARK_SIZE <= PLATE_Y + PLATE_HEIGHT && PLATE_Y + PLATE_HEIGHT <= HEIGHT)

// The start menu: a card in two panes. The left pane has the pinned
// modules, in lines of PINNED_LINE_HEIGHT, and the quick actions at its
// foot; the right pane has a heading and the other modules in COLUMNS
// columns of lines of LINE_HEIGHT.
BORDER :: 1 // The border of a menu, in pixels.
PANE_PADDING :: 8 // Inside each pane, on each side.
PINNED_LINE_HEIGHT :: 28
LINE_HEIGHT :: 24 // One line of a menu.
HEADING_HEIGHT :: 24 // The heading of the right pane.
ACTION_LINE_HEIGHT :: 28
ACTIONS_GAP :: 16 // Between the last pinned line and the quick actions, at least.
COLUMNS :: 3 // The right pane has three columns of names: the demonstrations fit a screen of 720 pixels.
COLUMN_LEAST :: 160 // The width of a column, at least: the quick actions fit.
TITLE :: 40 // The title of the menu of the windows, as the title of a card.

// A quick action of the start menu, at the foot of its left pane.
Start_Action :: enum u8 {
	None, // No action: the pointer is elsewhere.
	Demonstrations, // Opens or closes the right pane of the demonstrations; the menu stays open.
	Bar_Edge, // Moves the bar to the other edge of the screen.
	Magnifier, // Turns the magnifier on or off.
}
ACTION_COUNT :: len(Start_Action) - 1

// Layout: the width of the widest name of the start menu, measured in the
// font that draws it: the names of the bar are in the interface font; with
// no interface font, in the font of the cells (docs/DESIGN.md, section 5).
// The place of each line of a menu comes from it, so a press lands on the
// entry that the eye sees. The compositor measures it once, and again when
// the font changes; it writes in its log which font it is, and the modus
// tool measures the same layout from the same font file.
//
// The layout also holds the edge of the screen that the bar is on, and the
// logical height of the screen: every place below comes from them, so a
// reader of the places never adds an offset of its own
// (src/md/features/bar_edge.md). The zero value is a bar at the top.
Layout :: struct {
	longest_name_width:  int, // The widest of the labels of the names.
	edge:                Edge, // The edge of the screen that holds the bar.
	screen_height:       int, // The logical height of the screen: the place of a bar at the bottom.
	demonstrations_open: bool, // The start menu shows its right pane, the demonstrations.
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

// with_demonstrations gives a layout with the same widths and edge whose
// start menu shows the demonstrations, or hides them.
with_demonstrations :: proc "contextless" (layout: Layout, open: bool) -> Layout {
	result := layout
	result.demonstrations_open = open
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

// layout_of measures the names of the start menu in a face: the regular
// weight of the interface font, or None for the font of the cells.
layout_of :: proc "contextless" (face: text_rendering.Face) -> (layout: Layout) {
	for name in names {
		buffer: [LABEL_BYTES]u8
		layout.longest_name_width = max(layout.longest_name_width, text_width_in(face, label_of(name, &buffer)))
	}
	return layout
}

// mark_y gives the y of the mark on the screen.
mark_y :: proc "contextless" (layout: Layout) -> int {
	return top(layout) + MARK_Y
}

// inside reports whether a point is inside a rectangle.
@(private)
inside :: proc "contextless" (point_x, point_y, x, y, width, height: int) -> bool {
	return point_x >= x && point_x < x + width && point_y >= y && point_y < y + height
}

// button gives the place of the heron button, which opens the start menu.
button :: proc "contextless" (layout: Layout) -> (x, y, width, height: int) {
	return START_BUTTON_X, top(layout) + PLATE_Y, START_BUTTON_WIDTH, PLATE_HEIGHT
}

// button_center gives the middle of the heron button.
button_center :: proc "contextless" (layout: Layout) -> (center_x, center_y: int) {
	x, y, width, height := button(layout)
	return x + width / 2, y + height / 2
}

// column_width gives the width of one line of the start menu: its icon,
// the widest name and a padding on each side, and COLUMN_LEAST at least.
column_width :: proc "contextless" (layout: Layout) -> int {
	return max(layout.longest_name_width + ICON_SIZE + ICON_GAP + 2 * PADDING, COLUMN_LEAST)
}

// rows gives the lines of one column of the right pane of the start menu.
rows :: proc "contextless" () -> int {
	return (DEMONSTRATION_COUNT + COLUMNS - 1) / COLUMNS
}

// left_lines_height gives the height of the sections of the left pane: a
// heading and the lines of each section that has a line.
left_lines_height :: proc "contextless" () -> int {
	height := 0
	for section in ([2]Menu_Section{.Applications, .Tools}) {
		if count := section_line_count(section); count > 0 {
			height += HEADING_HEIGHT + count * PINNED_LINE_HEIGHT
		}
	}
	return height
}

// heading_place gives the y of the heading of a section of the left pane,
// or of the right pane for the demonstrations. ok is false for a section
// with no line, which has no heading.
heading_place :: proc "contextless" (layout: Layout, section: Menu_Section) -> (x, y, width: int, ok: bool) {
	if section_line_count(section) == 0 {
		return 0, 0, 0, false
	}
	left, menu_y, _, _ := menu(layout)
	switch section {
	case .Applications:
		return left + BORDER + PANE_PADDING, menu_y + BORDER + PANE_PADDING, column_width(layout), true
	case .Tools:
		y = menu_y + BORDER + PANE_PADDING
		if APPLICATION_COUNT > 0 {
			y += HEADING_HEIGHT + APPLICATION_COUNT * PINNED_LINE_HEIGHT
		}
		return left + BORDER + PANE_PADDING, y, column_width(layout), true
	case .Demonstrations:
		pane_x, pane_y, pane_width, _ := right_pane(layout)
		return pane_x + PANE_PADDING, pane_y + PANE_PADDING, pane_width - 2 * PANE_PADDING, layout.demonstrations_open
	}
	return 0, 0, 0, false
}

// pane_width gives the width of the left pane of the start menu.
pane_width :: proc "contextless" (layout: Layout) -> int {
	return column_width(layout) + 2 * PANE_PADDING
}

// menu gives the place of the start menu, at the heron button, away from
// the edge of the bar. With the demonstrations open, the taller of the two
// panes gives its height; closed, the menu is the left pane alone.
menu :: proc "contextless" (layout: Layout) -> (x, y, width, height: int) {
	left_height := left_lines_height() + ACTIONS_GAP + ACTION_COUNT * ACTION_LINE_HEIGHT
	right_height := HEADING_HEIGHT + rows() * LINE_HEIGHT
	height = 2 * BORDER + 2 * PANE_PADDING + left_height
	width = 2 * BORDER + pane_width(layout)
	if layout.demonstrations_open {
		height = 2 * BORDER + 2 * PANE_PADDING + max(left_height, right_height)
		width += 1 + 2 * PANE_PADDING + COLUMNS * column_width(layout)
	}
	return START_BUTTON_X, menu_top(layout, height), width, height
}

// right_pane gives the place of the right pane of the start menu: after the
// left pane and the line of one pixel between them, inside the border. A
// menu with the demonstrations closed has no right pane: its width is 0.
right_pane :: proc "contextless" (layout: Layout) -> (x, y, width, height: int) {
	left, menu_y, menu_width, menu_height := menu(layout)
	x = left + BORDER + pane_width(layout) + 1
	if !layout.demonstrations_open {
		return x, menu_y + BORDER, 0, menu_height - 2 * BORDER
	}
	return x, menu_y + BORDER, left + menu_width - BORDER - x, menu_height - 2 * BORDER
}

// line gives the place of the line of names[index] in the start menu: a
// line of a section of the left pane, under its heading, or a line of a
// column of the right pane, under the heading of the demonstrations.
line :: proc "contextless" (layout: Layout, index: int) -> (x, y, width, height: int) {
	if index < LEFT_COUNT {
		section := section_of(index)
		heading_x, heading_y, _, _ := heading_place(layout, section)
		first := section == .Tools ? APPLICATION_COUNT : 0
		return heading_x, heading_y + HEADING_HEIGHT + (index - first) * PINNED_LINE_HEIGHT, column_width(layout), PINNED_LINE_HEIGHT
	}
	pane_x, pane_y, _, _ := right_pane(layout)
	place := index - LEFT_COUNT
	return pane_x + PANE_PADDING + place / rows() * column_width(layout), pane_y + PANE_PADDING + HEADING_HEIGHT + place % rows() * LINE_HEIGHT, column_width(layout), LINE_HEIGHT
}

// line_at gives the index of the line of the start menu at a point, or -1.
// A line of a closed section is never at a point.
line_at :: proc "contextless" (layout: Layout, point_x, point_y: int) -> int {
	for index in 0 ..< shown_count(layout) {
		if x, y, width, height := line(layout, index); inside(point_x, point_y, x, y, width, height) {
			return index
		}
	}
	return -1
}

// center gives the middle of the line of a module in the menu. ok is
// false if the menu does not have the module, or if its line is in the
// closed demonstrations: a press there would land on nothing.
center :: proc "contextless" (layout: Layout, module: string) -> (center_x, center_y: int, ok: bool) {
	for index in 0 ..< shown_count(layout) {
		if names[index] == module {
			x, y, width, height := line(layout, index)
			return x + width / 2, y + height / 2, true
		}
	}
	return 0, 0, false
}

// section_of_name gives the section of a module of the menu. ok is false
// for a name that the menu does not have.
section_of_name :: proc "contextless" (module: string) -> (section: Menu_Section, ok: bool) {
	for name, index in names {
		if name == module {
			return section_of(index), true
		}
	}
	return .Applications, false
}

// action_line gives the place of a quick action in the left pane of the
// start menu, after the lines of its sections and their gap: the last
// action ends the closed card. The actions keep their places from the top
// of the card when the demonstrations open, so the action that opens them
// stays under the pointer in a menu under the bar. None has no place: its
// width is 0.
action_line :: proc "contextless" (layout: Layout, action: Start_Action) -> (x, y, width, height: int) {
	if action == .None {
		return 0, 0, 0, 0
	}
	left, menu_y, _, _ := menu(layout)
	above := int(action) - 1 // The actions before this one.
	return left + BORDER + PANE_PADDING, menu_y + BORDER + PANE_PADDING + left_lines_height() + ACTIONS_GAP + above * ACTION_LINE_HEIGHT, column_width(layout), ACTION_LINE_HEIGHT
}

// action_at gives the quick action at a point, or None.
action_at :: proc "contextless" (layout: Layout, point_x, point_y: int) -> Start_Action {
	for action in Start_Action {
		if x, y, width, height := action_line(layout, action); width > 0 && inside(point_x, point_y, x, y, width, height) {
			return action
		}
	}
	return .None
}

// The menu of the windows: one line for each window, with its icon and its
// title. A press on a line brings the window to the front.
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
// The place of the icon and of the title in a line of the menu of the
// windows: the icon after the bar of two pixels that marks the window with
// the focus.
WINDOWS_ICON_X :: 8
WINDOWS_TITLE_X :: WINDOWS_ICON_X + ICON_SIZE + ICON_GAP

// windows_button gives the place of the button that opens the menu of the windows.
windows_button :: proc "contextless" (layout: Layout) -> (x, y, width, height: int) {
	return WINDOWS_BUTTON_X, top(layout) + PLATE_Y, WINDOWS_BUTTON_WIDTH, PLATE_HEIGHT
}

// windows_menu gives the place of the menu of count windows, at its
// button, away from the edge of the bar.
windows_menu :: proc "contextless" (layout: Layout, count: int) -> (x, y, width, height: int) {
	height = TITLE + count * LINE_HEIGHT + 2 * BORDER
	return WINDOWS_BUTTON_X, menu_top(layout, height), WINDOWS_TITLE_X + WINDOWS_TITLE_ROOM + PADDING + 2 * BORDER, height
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
		if x, y, width, height := windows_line(layout, index); inside(point_x, point_y, x, y, width, height) {
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

// plate gives the place of the plate of a slot of the bar: the plates of
// the groups of windows, from the left, after the divider.
plate :: proc "contextless" (layout: Layout, slot: int) -> (x, y, width, height: int) {
	return PLATES_X + slot * (PLATE_WIDTH + PLATE_GAP), top(layout) + PLATE_Y, PLATE_WIDTH, PLATE_HEIGHT
}

// plate_at gives the slot of the plate at a point, or -1: a point in the
// gap between two plates, above or under the plates, or before the first,
// is on no plate. right is the first column that no plate reaches: a slot
// whose plate does not end before it is not drawn.
plate_at :: proc "contextless" (layout: Layout, right, point_x, point_y: int) -> int {
	_, y, _, height := plate(layout, 0)
	if point_x < PLATES_X || point_y < y || point_y >= y + height {
		return -1
	}
	offset := point_x - PLATES_X
	slot := offset / (PLATE_WIDTH + PLATE_GAP)
	if offset % (PLATE_WIDTH + PLATE_GAP) >= PLATE_WIDTH {
		return -1
	}
	if PLATES_X + (slot + 1) * (PLATE_WIDTH + PLATE_GAP) - PLATE_GAP > right {
		return -1
	}
	return slot
}

// A button of the bar.
Bar_Button :: enum u8 {
	None, // No button: the pointer is elsewhere.
	Start, // The heron button, which opens the start menu.
	Windows, // The button that opens the menu of the windows.
}

// button_at gives the button of the bar at a point.
button_at :: proc "contextless" (layout: Layout, point_x, point_y: int) -> Bar_Button {
	if x, y, width, height := button(layout); inside(point_x, point_y, x, y, width, height) {
		return .Start
	}
	if x, y, width, height := windows_button(layout); inside(point_x, point_y, x, y, width, height) {
		return .Windows
	}
	return .None
}
