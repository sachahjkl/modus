package interface

import "modus:support/display"
import "modus:support/graphics"

// The action bar (docs/INTERFACE.md, "4.4 The action bar"): the band at
// the bottom of a window that names its keys. Each item is the keycaps of
// one key combination, then the name of its action. A press on an item
// gives the program the key of the item, so a press and the key run one
// piece of code. The items that do not fit go into a list behind a button
// "more". Its look is in the design rules (docs/DESIGN.md, "The action
// bar").
//
// The order in a frame: action_bar_input_take right after the frame
// begins, so that no element under the bar or under its list takes the
// press or the keys of the list; action_bar last, so that the list is
// drawn over the content.

ACTION_BAR_KEY_CAPACITY :: 3 // The keycaps of one combination.
ACTION_BAR_ITEM_CAPACITY :: 24 // The items of one bar.
ACTION_BAR_ROW_HEIGHT :: TABLE_LINE // One row of the bar, and one row of its list.
ACTION_BAR_WRAP_ROWS :: 2 // The rows of a bar that wraps.
ACTION_BAR_ITEM_MARGIN :: 8 // The room inside the box of an item, at its left and at its right.
ACTION_BAR_DIVIDER_WIDTH :: 1 // The line between two items.
ACTION_BAR_DIVIDER_HEIGHT :: 12
ACTION_BAR_KEYCAP_HEIGHT :: 20
ACTION_BAR_KEYCAP_LEAST_WIDTH :: 20 // A keycap of one character is a square.
ACTION_BAR_KEYCAP_PADDING :: 6 // From each side of a keycap to its label.
ACTION_BAR_NAME_GAP :: 6 // From the last keycap to the name of the action.
ACTION_BAR_JOIN_GAP :: 3 // On each side of the "+" between two keycaps of a combination.
ACTION_BAR_JOIN_TEXT :: "+"
ACTION_BAR_ARROW_ROWS :: 4 // The rows of a triangle: 1, 3, 5 and 7 pixels, as the arrow of the scroll bar.
ACTION_BAR_ARROW_WIDTH :: 2 * ACTION_BAR_ARROW_ROWS - 1
ACTION_BAR_ARROW_GAP :: 4 // From the word of a face to its triangle: "Page" and the triangle.
ACTION_BAR_POINT_SIZE :: 2 // The three points of the button "more".
ACTION_BAR_POINT_GAP :: 2
ACTION_BAR_LIST_BORDER :: 1
ACTION_BAR_MORE_NAME :: "more" // The element name of the button, and the word after its count.

#assert(ACTION_BAR_KEYCAP_HEIGHT + 4 == ACTION_BAR_ROW_HEIGHT)

// One item of an action bar. The texts stay in the memory of the caller.
Action_Bar_Item :: struct {
	// The faces of the keycaps of one combination, in their order:
	// {"Shift", "Tab"}. The first empty face ends them. The bar derives
	// the key of a press from them (action_bar_key_of).
	faces:    [ACTION_BAR_KEY_CAPACITY]string,
	name:     string, // The name of the action, in words: "back". It is the element name of the item too.
	priority: int, // An item of a lower priority leaves the row first.
}

// action_bar_item makes an item from the name of its action, its priority
// and the faces of its keycaps, in their order. Odin takes no literal of a
// fixed array with fewer values than the array, and a slice of faces
// would point into the memory of the caller: so the faces are copied into
// the array of the item. A face past ACTION_BAR_KEY_CAPACITY is dropped:
// the item then names a shorter combination, and its key is not that of
// the faces given (action_bar_key_of), so a host test sees it.
action_bar_item :: proc "contextless" (name: string, priority: int, faces: ..string) -> (item: Action_Bar_Item) {
	item.name = name
	item.priority = priority
	for index in 0 ..< min(len(faces), ACTION_BAR_KEY_CAPACITY) {
		item.faces[index] = faces[index]
	}
	return
}

// What a bar does with the items that do not fit in one row.
Action_Bar_Overflow :: enum u8 {
	More, // One row; the items that do not fit go into the list of the button "more".
	Wrap, // Two rows, in the order of the items; the items that two rows do not hold go into the list.
}

// Action_Bar_Options: how a bar places its items.
Action_Bar_Options :: struct {
	overflow:  Action_Bar_Overflow,
	alignment: Alignment, // Left: the items start at the left of the bar. Right: they end at its right edge.
	top:       int, // The highest place of the list: it never goes above it. 0: the top of the window.
}

// The places of the items of a bar for one width (action_bar_layout).
Action_Bar_Layout :: struct {
	boxes:        [ACTION_BAR_ITEM_CAPACITY]Area, // The box of each item in the row. A width of 0: the item is in the list.
	in_row:       [ACTION_BAR_ITEM_CAPACITY]bool,
	listed:       [ACTION_BAR_ITEM_CAPACITY]int, // The items of the list, as indexes of the items, in their order.
	listed_count: int,
	more_box:     Area, // The button "more". A width of 0: no button.
	rows:         int, // The rows that the items take.
}

// The part of a bar that the pointer is on, or that holds a press.
Action_Bar_Part_Kind :: enum u8 {
	None,
	Item, // An item of the row; index: the item.
	More, // The button "more".
	Row, // A row of the open list; index: the row.
}

Action_Bar_Part :: struct {
	kind:  Action_Bar_Part_Kind,
	index: int,
}

// The pointer of a frame, as action_bar_input_take found it.
Action_Bar_Pointer :: struct {
	x, y:                       int,
	known:                      bool,
	pressed, released:          bool,
	press_x, press_y:           int,
}

// What a bar keeps between frames, in the memory of the program: one for
// each bar.
Action_Bar_State :: struct {
	open:         bool, // The list of the button "more" is open.
	has_chosen:   bool, // The keys chose a row of the list.
	chosen:       int, // That row.
	// The keys of the rows that the list showed in the last frame: the
	// keys of the list reach the bar before it draws.
	listed_keys:  [ACTION_BAR_ITEM_CAPACITY]Key_Press,
	listed_runs:  [ACTION_BAR_ITEM_CAPACITY]bool, // The row has a key: its faces name one.
	listed_count: int,
	area:         Area, // The bar in the last frame.
	list_area:    Area, // The open list in the last frame. Empty when it was closed.
	held:         Action_Bar_Part, // The part where the button went down, until it goes up.
	lit:          bool, // The last frame drew a part under the pointer.
	pointer:      Action_Bar_Pointer, // The pointer of this frame.
	// The key of a row that Enter ran from the list, for the result of the
	// frame (action_bar).
	pending:      Key_Press,
	has_pending:  bool,
}

// What the input did to a bar in one frame.
Action_Bar_Result :: struct {
	run:                 Key_Press, // The key of the action that a press or the list ran.
	ran:                 bool, // `run` holds a key.
	list_rows_not_shown: int, // The rows of the open list that the room above the bar does not hold.
}

// What one key did to a bar (action_bar_key).
Action_Bar_Key_Outcome :: struct {
	taken: bool, // The key belongs to the open list: the program does not act on it.
	run:   Key_Press, // Enter on a chosen row: the key of its action.
	ran:   bool,
}

// The arrow that a face draws.
@(private = "file")
Action_Bar_Arrow :: enum u8 {
	None,
	Up,
	Down,
	Left,
	Right,
}

// action_bar_face_parts gives what a face draws: a word and an arrow. The
// fonts have no arrow character: an arrow is a triangle of rectangles.
@(private = "file")
action_bar_face_parts :: proc "contextless" (face: string) -> (label: string, arrow: Action_Bar_Arrow) {
	switch face {
	case "Up":
		return "", .Up
	case "Down":
		return "", .Down
	case "Left":
		return "", .Left
	case "Right":
		return "", .Right
	case "Page Up":
		return "Page", .Up
	case "Page Down":
		return "Page", .Down
	}
	return face, .None
}

// action_bar_face_count gives the faces of an item: up to the first empty one.
action_bar_face_count :: proc "contextless" (item: ^Action_Bar_Item) -> int {
	for face, index in item.faces {
		if face == "" {
			return index
		}
	}
	return ACTION_BAR_KEY_CAPACITY
}

// The code of the key Space, as the input service gives it.
@(private = "file")
KEY_SPACE :: 0x39

// action_bar_key_of gives the key that a press on an item gives its
// program, from its faces: a modifier ("Shift", "Ctrl"), then one key: a
// name of a key ("Enter", "Tab", "Esc", "Backspace", "Delete", "Space",
// "Home", "End", "Up", "Down", "Left", "Right", "Page Up", "Page Down"), or
// one printable ASCII character, which gives the character with the code
// 0: the code of a letter depends on the layout of the keyboard, so a
// program compares the character. ok is false for an item whose faces
// name no key: it takes no press.
action_bar_key_of :: proc "contextless" (item: ^Action_Bar_Item) -> (press: Key_Press, ok: bool) {
	count := action_bar_face_count(item)
	if count == 0 {
		return {}, false
	}
	for face in item.faces[:count - 1] {
		switch face {
		case "Shift":
			press.modifiers |= display.MODIFIER_SHIFT
		case "Ctrl":
			press.modifiers |= display.MODIFIER_CONTROL
		case:
			return {}, false
		}
	}
	last := item.faces[count - 1]
	// A key that gives a character has it too, as the keyboard layout
	// gives it: a program that reads the character of Enter sees '\n'.
	switch last {
	case "Enter":
		press.code, press.character = display.KEY_ENTER, '\n'
	case "Tab":
		press.code, press.character = KEY_TAB, '\t'
	case "Esc":
		press.code = display.KEY_ESCAPE
	case "Backspace":
		press.code, press.character = display.KEY_BACKSPACE, 8
	case "Delete":
		press.code = display.KEY_DELETE
	case "Space":
		press.code, press.character = KEY_SPACE, ' '
	case "Home":
		press.code = display.KEY_HOME
	case "End":
		press.code = display.KEY_END
	case "Up":
		press.code = display.KEY_UP
	case "Down":
		press.code = display.KEY_DOWN
	case "Left":
		press.code = display.KEY_LEFT
	case "Right":
		press.code = display.KEY_RIGHT
	case "Page Up":
		press.code = display.KEY_PAGE_UP
	case "Page Down":
		press.code = display.KEY_PAGE_DOWN
	case:
		if len(last) != 1 || last[0] < '!' || last[0] > '~' {
			return {}, false
		}
		press.character = rune(last[0])
	}
	return press, true
}

// action_bar_keycap_width gives the width of the keycap of one face.
action_bar_keycap_width :: proc "contextless" (table: ^Draw_Table, face: string) -> int {
	label, arrow := action_bar_face_parts(face)
	inner := 0
	if label != "" {
		inner += text_measured_width(table, FONT_INTERFACE, label)
	}
	if arrow != .None {
		if label != "" {
			inner += ACTION_BAR_ARROW_GAP
		}
		inner += ACTION_BAR_ARROW_WIDTH
	}
	return max(inner + 2 * ACTION_BAR_KEYCAP_PADDING, ACTION_BAR_KEYCAP_LEAST_WIDTH)
}

// action_bar_keys_width gives the width of the keycaps of an item, with
// the "+" between two of them.
action_bar_keys_width :: proc "contextless" (table: ^Draw_Table, item: ^Action_Bar_Item) -> int {
	count := action_bar_face_count(item)
	width := 0
	for face, index in item.faces[:count] {
		if index > 0 {
			width += 2 * ACTION_BAR_JOIN_GAP + text_measured_width(table, FONT_INTERFACE, ACTION_BAR_JOIN_TEXT)
		}
		width += action_bar_keycap_width(table, face)
	}
	return width
}

// action_bar_item_width gives the width of the box of an item: its
// margins, its keycaps, the gap and its name. An item is never narrower:
// a bar shows it whole, or puts it in the list.
action_bar_item_width :: proc "contextless" (table: ^Draw_Table, item: ^Action_Bar_Item) -> int {
	return 2 * ACTION_BAR_ITEM_MARGIN + action_bar_keys_width(table, item) + ACTION_BAR_NAME_GAP + text_measured_width(table, FONT_INTERFACE, item.name)
}

// action_bar_more_text writes the text of the button "more": the count of
// the items in its list, then the word.
@(private = "file")
action_bar_more_text :: proc "contextless" (builder: ^Text_Builder, count: int) -> string {
	builder.count = 0
	text_put_number(builder, u64(max(count, 0)))
	text_put(builder, " ")
	text_put(builder, ACTION_BAR_MORE_NAME)
	return text_of(builder)
}

// action_bar_more_width gives the width of the box of the button "more"
// with a count.
action_bar_more_width :: proc "contextless" (table: ^Draw_Table, count: int) -> int {
	builder: Text_Builder
	return 2 * ACTION_BAR_ITEM_MARGIN + ACTION_BAR_KEYCAP_LEAST_WIDTH + ACTION_BAR_NAME_GAP + text_measured_width(table, FONT_INTERFACE, action_bar_more_text(&builder, count))
}

// action_bar_flow places the items of in_row, in their order, over rows of
// a width: an item that does not fit after the one before starts the next
// row. A button of more_width (0: none) ends the last row. It gives false
// when they need more than rows_limit rows, or one of them is wider than
// a row. With boxes, it writes the box of each item and of the button,
// from the left of each row at x.
@(private = "file")
action_bar_flow :: proc "contextless" (widths: []int, in_row: []bool, x, y, room, rows_limit, more_width: int, boxes: []Area = nil, more_box: ^Area = nil) -> (fits: bool, rows: int) {
	// place gives the left of a box of a width in the current row, or
	// starts the next row for it.
	place :: proc "contextless" (current_row, row_used: ^int, box_width, row_room, row_limit: int) -> (left: int, ok: bool) {
		if box_width > row_room {
			return 0, false
		}
		need := box_width + (row_used^ > 0 ? ACTION_BAR_DIVIDER_WIDTH : 0)
		if row_used^ + need > row_room {
			current_row^ += 1
			row_used^ = 0
			need = box_width
			if current_row^ >= row_limit {
				return 0, false
			}
		}
		left = row_used^ + need - box_width
		row_used^ += need
		return left, true
	}
	row, used := 0, 0
	placed_one := false
	for width, index in widths {
		if !in_row[index] {
			continue
		}
		left, ok := place(&row, &used, width, room, rows_limit)
		if !ok {
			return false, row + 1
		}
		placed_one = true
		if boxes != nil {
			boxes[index] = {x + left, y + row * ACTION_BAR_ROW_HEIGHT, width, ACTION_BAR_ROW_HEIGHT}
		}
	}
	if more_width > 0 {
		left, ok := place(&row, &used, more_width, room, rows_limit)
		if !ok {
			return false, row + 1
		}
		placed_one = true
		if more_box != nil {
			more_box^ = {x + left, y + row * ACTION_BAR_ROW_HEIGHT, more_width, ACTION_BAR_ROW_HEIGHT}
		}
	}
	return true, placed_one ? row + 1 : 0
}

// action_bar_layout places the items of a bar in its area. All the items
// stay in the row when they fit. Else the button "more" ends the row, and
// items leave the row, the lowest priority first and, of two with one
// priority, the later one first, until the rest fit beside the button.
// The items in the row and in the list keep the order of the caller. It
// draws nothing: a host test runs it with no frame.
action_bar_layout :: proc "contextless" (table: ^Draw_Table, area: Area, items: []Action_Bar_Item, options: Action_Bar_Options = {}) -> (layout: Action_Bar_Layout) {
	count := min(len(items), ACTION_BAR_ITEM_CAPACITY)
	widths: [ACTION_BAR_ITEM_CAPACITY]int
	for index in 0 ..< count {
		widths[index] = action_bar_item_width(table, &items[index])
		layout.in_row[index] = true
	}
	rows_limit := options.overflow == .Wrap ? ACTION_BAR_WRAP_ROWS : 1
	room := max(area.width, 0)
	hidden := 0
	more_width := 0
	if fits, _ := action_bar_flow(widths[:count], layout.in_row[:count], 0, 0, room, rows_limit, 0); !fits {
		for {
			lowest := -1
			for index in 0 ..< count {
				if layout.in_row[index] && (lowest < 0 || items[index].priority <= items[lowest].priority) {
					lowest = index
				}
			}
			if lowest < 0 {
				break
			}
			layout.in_row[lowest] = false
			hidden += 1
			more_width = action_bar_more_width(table, hidden)
			if fits_now, _ := action_bar_flow(widths[:count], layout.in_row[:count], 0, 0, room, rows_limit, more_width); fits_now {
				break
			}
		}
		// A bar narrower than the button alone shows nothing: the keys
		// still run each action.
		if more_width > room {
			more_width = 0
		}
	}
	_, layout.rows = action_bar_flow(widths[:count], layout.in_row[:count], area.x, area.y, room, rows_limit, more_width, layout.boxes[:count], &layout.more_box)
	for index in 0 ..< count {
		if !layout.in_row[index] {
			layout.boxes[index] = {}
			layout.listed[layout.listed_count] = index
			layout.listed_count += 1
		}
	}
	if options.alignment == .Right {
		// Each row ends at the right edge of the area.
		for row in 0 ..< layout.rows {
			row_y := area.y + row * ACTION_BAR_ROW_HEIGHT
			right := area.x
			for index in 0 ..< count {
				if layout.in_row[index] && layout.boxes[index].y == row_y {
					right = max(right, layout.boxes[index].x + layout.boxes[index].width)
				}
			}
			if layout.more_box.width > 0 && layout.more_box.y == row_y {
				right = max(right, layout.more_box.x + layout.more_box.width)
			}
			shift := area.x + room - right
			for index in 0 ..< count {
				if layout.in_row[index] && layout.boxes[index].y == row_y {
					layout.boxes[index].x += shift
				}
			}
			if layout.more_box.width > 0 && layout.more_box.y == row_y {
				layout.more_box.x += shift
			}
		}
	}
	return
}

// action_bar_list_place gives the place of the list of a layout: as wide
// as its widest row, at most as wide as the bar, its right edge on the
// right edge of the bar, its bottom on the top of the bar. It holds the
// rows that the room from top to the bar takes; shown is their count.
action_bar_list_place :: proc "contextless" (table: ^Draw_Table, area: Area, items: []Action_Bar_Item, layout: ^Action_Bar_Layout, top: int) -> (list: Area, shown: int) {
	if layout.listed_count == 0 {
		return {}, 0
	}
	widest := 0
	for index in layout.listed[:layout.listed_count] {
		widest = max(widest, action_bar_item_width(table, &items[index]))
	}
	width := min(widest + 2 * ACTION_BAR_LIST_BORDER, max(area.width, 0))
	height_of :: proc "contextless" (rows: int) -> int {
		return 2 * ACTION_BAR_LIST_BORDER + rows * ACTION_BAR_ROW_HEIGHT + max(rows - 1, 0) * ACTION_BAR_DIVIDER_WIDTH
	}
	room := area.y - top
	shown = layout.listed_count
	for shown > 0 && height_of(shown) > room {
		shown -= 1
	}
	if shown == 0 {
		return {}, 0
	}
	height := height_of(shown)
	return {area.x + area.width - width, area.y - height, width, height}, shown
}

// action_bar_list_row gives the box of a row of the list.
action_bar_list_row :: proc "contextless" (list: Area, row: int) -> Area {
	return {list.x + ACTION_BAR_LIST_BORDER, list.y + ACTION_BAR_LIST_BORDER + row * (ACTION_BAR_ROW_HEIGHT + ACTION_BAR_DIVIDER_WIDTH), list.width - 2 * ACTION_BAR_LIST_BORDER, ACTION_BAR_ROW_HEIGHT}
}

// action_bar_close closes the list of a bar.
action_bar_close :: proc "contextless" (bar: ^Action_Bar_State) {
	bar.open = false
	bar.has_chosen = false
}

// action_bar_key gives one key to a bar. With the list closed it takes no
// key. With the list open, Up and Down choose a row (Up from no row
// chooses the last row, the one next to the bar; Down the first; a move
// stops at an end), Enter runs the chosen row and closes the list, and
// Escape closes it; each of these is taken. Another key closes the list
// and stays for the program. A program that reads its keys calls it for
// each key before it acts on the key.
action_bar_key :: proc "contextless" (bar: ^Action_Bar_State, press: Key_Press) -> (outcome: Action_Bar_Key_Outcome) {
	if !bar.open {
		return
	}
	count := clamp(bar.listed_count, 0, ACTION_BAR_ITEM_CAPACITY)
	switch press.code {
	case display.KEY_UP:
		outcome.taken = true
		if count > 0 {
			bar.chosen = bar.has_chosen ? max(bar.chosen - 1, 0) : count - 1
			bar.has_chosen = true
		}
	case display.KEY_DOWN:
		outcome.taken = true
		if count > 0 {
			bar.chosen = bar.has_chosen ? min(bar.chosen + 1, count - 1) : 0
			bar.has_chosen = true
		}
	case display.KEY_ENTER:
		outcome.taken = true
		if bar.has_chosen && bar.chosen >= 0 && bar.chosen < count && bar.listed_runs[bar.chosen] {
			outcome.run = bar.listed_keys[bar.chosen]
			outcome.ran = true
		}
		action_bar_close(bar)
	case display.KEY_ESCAPE:
		outcome.taken = true
		action_bar_close(bar)
	case:
		action_bar_close(bar)
	}
	return
}

// action_bar_input_take takes from the input of a frame what belongs to a
// bar, before any element of the frame reads it: the keys of the open
// list, and the press and the pointer while the list is open, while the
// pointer is over the bar or the list, or while the bar holds the press.
// The elements of the frame then see no press, and no pointer over the
// bar or the list. Call it right after the frame begins, for each frame
// that draws the bar. A row that Enter runs gives its key in the result
// of action_bar.
action_bar_input_take :: proc "contextless" (frame: ^Frame, bar: ^Action_Bar_State) {
	input := frame.input
	bar.pointer = {
		x        = input.pointer_x,
		y        = input.pointer_y,
		known    = input.pointer_known,
		pressed  = input.pressed,
		released = input.released,
		press_x  = input.press_x,
		press_y  = input.press_y,
	}
	over := input.pointer_known && (area_contains(bar.area, input.pointer_x, input.pointer_y) || bar.open && area_contains(bar.list_area, input.pointer_x, input.pointer_y))
	press_on_bar := input.pressed && (area_contains(bar.area, input.press_x, input.press_y) || bar.open && area_contains(bar.list_area, input.press_x, input.press_y))
	if bar.open || press_on_bar {
		input.pressed = false
	}
	// Only the release of a press that the bar holds: the release of a
	// thumb of a scroll bar dragged over the bar stays for the scroll bar.
	if bar.held.kind != .None {
		input.released = false
	}
	if over {
		input.pointer_known = false
		input.wheel = 0
	}
	for &key in input.keys[:input.key_count] {
		if key.taken {
			continue
		}
		outcome := action_bar_key(bar, key)
		if outcome.taken {
			key.taken = true
		}
		if outcome.ran {
			bar.pending = outcome.run
			bar.has_pending = true
		}
	}
}

// action_bar_part_at gives the part of a bar at a place, from the places
// of this frame.
@(private = "file")
action_bar_part_at :: proc "contextless" (layout: ^Action_Bar_Layout, count: int, list: Area, list_rows: int, open: bool, x, y: int) -> Action_Bar_Part {
	if open {
		for row in 0 ..< list_rows {
			if area_contains(action_bar_list_row(list, row), x, y) {
				return {.Row, row}
			}
		}
		if area_contains(list, x, y) {
			return {}
		}
	}
	if layout.more_box.width > 0 && area_contains(layout.more_box, x, y) {
		return {.More, 0}
	}
	for index in 0 ..< count {
		if layout.in_row[index] && area_contains(layout.boxes[index], x, y) {
			return {.Item, index}
		}
	}
	return {}
}

// action_bar draws a bar in its area, and gives the key of the action that
// a press, or Enter in the list, ran. The area is one row high
// (ACTION_BAR_ROW_HEIGHT), or two for Wrap. A press and a release on an
// item give its key. A press and a release on the button "more" open or
// close its list. A press and a release on a row of the list give its key
// and close the list. A press outside the open list closes it and gives
// nothing. Each item, each row of the open list and the button have an
// element name: the name of the item, and "more".
action_bar :: proc "contextless" (frame: ^Frame, area: Area, items: []Action_Bar_Item, bar: ^Action_Bar_State, options: Action_Bar_Options = {}) -> (result: Action_Bar_Result) {
	table := frame.table
	count := min(len(items), ACTION_BAR_ITEM_CAPACITY)
	layout := action_bar_layout(table, area, items[:count], options)
	if layout.listed_count == 0 {
		action_bar_close(bar)
	}
	list, list_rows := action_bar_list_place(table, area, items[:count], &layout, options.top)
	pointer := bar.pointer

	// The press, at the place where the button went down.
	if pointer.pressed && pointer.known {
		press_part := action_bar_part_at(&layout, count, list, list_rows, bar.open, pointer.press_x, pointer.press_y)
		if bar.open && press_part.kind != .Row && press_part.kind != .More {
			action_bar_close(bar)
			bar.held = {}
		} else {
			bar.held = press_part
		}
	}
	under := Action_Bar_Part{}
	if pointer.known {
		under = action_bar_part_at(&layout, count, list, list_rows, bar.open, pointer.x, pointer.y)
	}
	if pointer.released {
		held := bar.held
		bar.held = {}
		if held.kind != .None && held == under {
			switch held.kind {
			case .None:
			case .Item:
				if press, ok := action_bar_key_of(&items[held.index]); ok {
					result.run, result.ran = press, true
				}
			case .More:
				if bar.open {
					action_bar_close(bar)
				} else {
					bar.open = true
					bar.has_chosen = false
				}
			case .Row:
				if held.index < list_rows {
					if press, ok := action_bar_key_of(&items[layout.listed[held.index]]); ok {
						result.run, result.ran = press, true
					}
				}
				action_bar_close(bar)
			}
		}
	}
	if bar.has_pending {
		result.run, result.ran = bar.pending, true
		bar.has_pending = false
	}
	if bar.open {
		result.list_rows_not_shown = layout.listed_count - list_rows
	}

	// The band and its line at the top.
	draw_rectangle(table, area.x, area.y, area.width, area.height, graphics.colors.card_bottom)
	draw_rectangle(table, area.x, area.y, area.width, 1, graphics.colors.track)
	lit := false
	previous_right, previous_y := -1, -1
	for index in 0 ..< count {
		if !layout.in_row[index] {
			continue
		}
		box := layout.boxes[index]
		if previous_y == box.y && previous_right >= 0 {
			action_bar_divider_draw(table, box.x - ACTION_BAR_DIVIDER_WIDTH, box.y)
		}
		previous_right, previous_y = box.x + box.width, box.y
		hot := under.kind == .Item && under.index == index && (bar.held.kind == .None || bar.held == under)
		pressed := hot && bar.held.kind == .Item && bar.held.index == index
		_, takes_press := action_bar_key_of(&items[index])
		hot &&= takes_press
		pressed &&= takes_press
		lit ||= hot
		action_bar_item_draw(table, box, &items[index], hot, pressed)
		element_name(frame, box, items[index].name)
	}
	if layout.more_box.width > 0 {
		box := layout.more_box
		if previous_y == box.y && previous_right >= 0 {
			action_bar_divider_draw(table, box.x - ACTION_BAR_DIVIDER_WIDTH, box.y)
		}
		hot := under.kind == .More && (bar.held.kind == .None || bar.held == under)
		pressed := hot && bar.held.kind == .More
		lit ||= hot
		action_bar_more_draw(table, box, layout.listed_count, hot, pressed || bar.open)
		element_name(frame, box, ACTION_BAR_MORE_NAME)
	}

	// The list, over the content: the caller draws the bar last.
	bar.list_area = {}
	bar.listed_count = 0
	if bar.open && list_rows > 0 {
		bar.list_area = list
		draw_rectangle(table, list.x, list.y, list.width, list.height, graphics.colors.not_usable)
		draw_rectangle(table, list.x + ACTION_BAR_LIST_BORDER, list.y + ACTION_BAR_LIST_BORDER, list.width - 2 * ACTION_BAR_LIST_BORDER, list.height - 2 * ACTION_BAR_LIST_BORDER, graphics.colors.card_top)
		for row in 0 ..< list_rows {
			index := layout.listed[row]
			box := action_bar_list_row(list, row)
			if row > 0 {
				// The line between two rows, inside the margins of a row.
				draw_rectangle(table, box.x + ACTION_BAR_ITEM_MARGIN, box.y - ACTION_BAR_DIVIDER_WIDTH, box.width - 2 * ACTION_BAR_ITEM_MARGIN, ACTION_BAR_DIVIDER_WIDTH, graphics.colors.track)
			}
			press, takes_press := action_bar_key_of(&items[index])
			bar.listed_keys[row] = press
			bar.listed_runs[row] = takes_press
			chosen := bar.has_chosen && bar.chosen == row
			hot := takes_press && under.kind == .Row && under.index == row && (bar.held.kind == .None || bar.held == under)
			pressed := hot && bar.held.kind == .Row
			lit ||= hot
			action_bar_item_draw(table, box, &items[index], hot, pressed || chosen)
			element_name(frame, box, items[index].name)
		}
		bar.listed_count = list_rows
	} else if bar.open {
		action_bar_close(bar)
	}
	bar.area = area
	bar.lit = lit
	bar.pointer = {}
	return
}

// action_bar_wants_frame says if a program that draws only after a change
// must build a frame for the pointer: the list is open, the bar holds the
// press, the last frame drew a part under the pointer, or the pointer is
// over the bar or went down on it.
action_bar_wants_frame :: proc "contextless" (bar: ^Action_Bar_State, input: ^Input) -> bool {
	if bar.open || bar.held.kind != .None || bar.lit {
		return true
	}
	if !input.pointer_known {
		return false
	}
	return area_contains(bar.area, input.pointer_x, input.pointer_y) || input.pressed && area_contains(bar.area, input.press_x, input.press_y)
}

// action_bar_takes_pointer says if a press at a place belongs to the bar:
// the list is open (a press anywhere closes it), the bar holds the press,
// or the place is on the bar. A program that acts on a press itself does
// not act on such a press.
action_bar_takes_pointer :: proc "contextless" (bar: ^Action_Bar_State, x, y: int) -> bool {
	return bar.open || bar.held.kind != .None || area_contains(bar.area, x, y)
}

// input_key_add adds a key to the input of the next frame, as if it was
// typed: the key of an item that a press ran goes the way of a typed key.
// It gives false when the input has KEY_CAPACITY keys.
input_key_add :: proc "contextless" (input: ^Input, press: Key_Press) -> bool {
	if !input_has_room(input) {
		return false
	}
	input.keys[input.key_count] = {code = press.code, character = press.character, modifiers = press.modifiers}
	input.key_count += 1
	return true
}

// action_bar_divider_draw draws the line between two items of a row.
@(private = "file")
action_bar_divider_draw :: proc "contextless" (table: ^Draw_Table, x, row_y: int) {
	draw_rectangle(table, x, row_y + (ACTION_BAR_ROW_HEIGHT - ACTION_BAR_DIVIDER_HEIGHT) / 2, ACTION_BAR_DIVIDER_WIDTH, ACTION_BAR_DIVIDER_HEIGHT, graphics.colors.track)
}

// action_bar_box_fill fills the box of an item under the pointer, or held.
@(private = "file")
action_bar_box_fill :: proc "contextless" (table: ^Draw_Table, box: Area, hot, pressed: bool) -> (name_color: graphics.Color) {
	switch {
	case pressed:
		draw_rectangle(table, box.x, box.y, box.width, box.height, graphics.colors.chosen)
		return graphics.COLOR_WHITE
	case hot:
		draw_rectangle(table, box.x, box.y, box.width, box.height, graphics.colors.track)
	}
	return graphics.colors.text
}

// action_bar_keycap_surface draws the border and the surface of a keycap.
// Its surface goes from lighter at the top to darker at the bottom: the
// one sign of depth of the design rules (docs/DESIGN.md, "3. Surfaces").
@(private = "file")
action_bar_keycap_surface :: proc "contextless" (table: ^Draw_Table, x, y, width: int) {
	draw_rectangle(table, x, y, width, ACTION_BAR_KEYCAP_HEIGHT, graphics.colors.not_usable)
	draw_vertical_gradient(table, x + 1, y + 1, width - 2, ACTION_BAR_KEYCAP_HEIGHT - 2, graphics.colors.card_top, graphics.colors.card_bottom)
}

// action_bar_keycap_draw draws one keycap: its surface, and its word and
// its arrow in the middle.
@(private = "file")
action_bar_keycap_draw :: proc "contextless" (table: ^Draw_Table, x, y, width: int, face: string) {
	action_bar_keycap_surface(table, x, y, width)
	label, arrow := action_bar_face_parts(face)
	inner := 0
	label_width := 0
	if label != "" {
		label_width = text_measured_width(table, FONT_INTERFACE, label)
		inner += label_width
	}
	if arrow != .None {
		if label != "" {
			inner += ACTION_BAR_ARROW_GAP
		}
		inner += ACTION_BAR_ARROW_WIDTH
	}
	left := x + (width - inner) / 2
	if label != "" {
		draw_text(table, left, y + 2, label, graphics.colors.text, FONT_INTERFACE)
		left += label_width + ACTION_BAR_ARROW_GAP
	}
	if arrow != .None {
		action_bar_arrow_draw(table, left, y + (ACTION_BAR_KEYCAP_HEIGHT - ACTION_BAR_ARROW_WIDTH) / 2, arrow)
	}
}

// action_bar_arrow_draw draws a solid triangle in a square of
// ACTION_BAR_ARROW_WIDTH pixels: rows of 1, 3, 5 and 7 pixels, its point
// toward its direction.
@(private = "file")
action_bar_arrow_draw :: proc "contextless" (table: ^Draw_Table, x, y: int, arrow: Action_Bar_Arrow) {
	middle := ACTION_BAR_ARROW_WIDTH / 2
	first := (ACTION_BAR_ARROW_WIDTH - ACTION_BAR_ARROW_ROWS) / 2
	for step in 0 ..< ACTION_BAR_ARROW_ROWS {
		#partial switch arrow {
		case .Up:
			draw_rectangle(table, x + middle - step, y + first + step, 2 * step + 1, 1, graphics.colors.text)
		case .Down:
			draw_rectangle(table, x + middle - step, y + first + ACTION_BAR_ARROW_ROWS - 1 - step, 2 * step + 1, 1, graphics.colors.text)
		case .Left:
			draw_rectangle(table, x + first + step, y + middle - step, 1, 2 * step + 1, graphics.colors.text)
		case .Right:
			draw_rectangle(table, x + first + ACTION_BAR_ARROW_ROWS - 1 - step, y + middle - step, 1, 2 * step + 1, graphics.colors.text)
		}
	}
}

// action_bar_item_draw draws an item in its box: the fill of its state,
// its keycaps with the "+" between them, and its name. A name is whole or
// absent: in a list narrower than the item (a bar narrower than one item)
// the row shows its keycaps only.
@(private = "file")
action_bar_item_draw :: proc "contextless" (table: ^Draw_Table, box: Area, item: ^Action_Bar_Item, hot, pressed: bool) {
	name_color := action_bar_box_fill(table, box, hot, pressed)
	join_color := pressed ? graphics.Color(graphics.COLOR_WHITE) : graphics.colors.dim
	keycap_y := box.y + (ACTION_BAR_ROW_HEIGHT - ACTION_BAR_KEYCAP_HEIGHT) / 2
	text_y := box.y + (ACTION_BAR_ROW_HEIGHT - LINE) / 2
	x := box.x + ACTION_BAR_ITEM_MARGIN
	count := action_bar_face_count(item)
	for face, index in item.faces[:count] {
		if index > 0 {
			x += ACTION_BAR_JOIN_GAP
			x = draw_text(table, x, text_y, ACTION_BAR_JOIN_TEXT, join_color, FONT_INTERFACE)
			x += ACTION_BAR_JOIN_GAP
		}
		width := action_bar_keycap_width(table, face)
		action_bar_keycap_draw(table, x, keycap_y, width, face)
		x += width
	}
	x += ACTION_BAR_NAME_GAP
	if text_measured_width(table, FONT_INTERFACE, item.name) <= box.x + box.width - ACTION_BAR_ITEM_MARGIN - x {
		draw_text(table, x, text_y, item.name, name_color, FONT_INTERFACE)
	}
}

// action_bar_more_draw draws the button "more": a keycap with three
// points, then the count of the items of its list and the word.
@(private = "file")
action_bar_more_draw :: proc "contextless" (table: ^Draw_Table, box: Area, count: int, hot, open: bool) {
	name_color := action_bar_box_fill(table, box, hot, open)
	keycap_x := box.x + ACTION_BAR_ITEM_MARGIN
	keycap_y := box.y + (ACTION_BAR_ROW_HEIGHT - ACTION_BAR_KEYCAP_HEIGHT) / 2
	action_bar_keycap_surface(table, keycap_x, keycap_y, ACTION_BAR_KEYCAP_LEAST_WIDTH)
	points_width := 3 * ACTION_BAR_POINT_SIZE + 2 * ACTION_BAR_POINT_GAP
	point_x := keycap_x + (ACTION_BAR_KEYCAP_LEAST_WIDTH - points_width) / 2
	point_y := keycap_y + (ACTION_BAR_KEYCAP_HEIGHT - ACTION_BAR_POINT_SIZE) / 2
	for point in 0 ..< 3 {
		draw_rectangle(table, point_x + point * (ACTION_BAR_POINT_SIZE + ACTION_BAR_POINT_GAP), point_y, ACTION_BAR_POINT_SIZE, ACTION_BAR_POINT_SIZE, graphics.colors.text)
	}
	builder: Text_Builder
	draw_text(table, keycap_x + ACTION_BAR_KEYCAP_LEAST_WIDTH + ACTION_BAR_NAME_GAP, box.y + (ACTION_BAR_ROW_HEIGHT - LINE) / 2, action_bar_more_text(&builder, count), name_color, FONT_INTERFACE)
}
