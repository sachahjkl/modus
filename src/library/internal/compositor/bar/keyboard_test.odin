#+build !freestanding
package bar

import "core:testing"
import "modus:interface"

// The frame of the compositor: borders of 2, a title of 24, on a screen of
// 1280 x 768.
@(private = "file")
FRAME_OF_TEST :: Window_Frame{outer_width = 400 + 4, border = 2, close_size = 24, title_height = 24}
@(private = "file")
FRAME_WIDTH_OF_TEST :: 4
@(private = "file")
FRAME_HEIGHT_OF_TEST :: 24 + 2
@(private = "file")
SCREEN_WIDTH_OF_TEST :: 1280
@(private = "file")
SCREEN_HEIGHT_OF_TEST :: 768
@(private = "file")
SIZES_OF_TEST :: Size_Range{least_width = 160, least_height = 64, largest_width = 900, largest_height = 600}

// The steps of the arrows: a spacing token, and one pixel with Shift.
@(test)
the_arrows_step_by_the_token_and_by_one_pixel :: proc(t: ^testing.T) {
	cases := [?]struct {
		arrow:  Arrow,
		fine:   bool,
		x, y:   int,
	}{
		{.Left, false, -KEYBOARD_STEP, 0},
		{.Right, false, KEYBOARD_STEP, 0},
		{.Up, false, 0, -KEYBOARD_STEP},
		{.Down, false, 0, KEYBOARD_STEP},
		{.Left, true, -1, 0},
		{.Right, true, 1, 0},
		{.Up, true, 0, -1},
		{.Down, true, 0, 1},
	}
	for item in cases {
		x, y := arrow_step(item.arrow, item.fine)
		testing.expectf(t, x == item.x && y == item.y, "%v fine %v steps %d,%d", item.arrow, item.fine, x, y)
	}
	testing.expect_value(t, KEYBOARD_STEP, 16)
}

// A move by keys never takes the title off the screen or under the bar:
// each edge first, from a place already at the bound.
@(test)
a_move_by_keys_keeps_the_title_on_the_screen :: proc(t: ^testing.T) {
	// Up from under the bar stays under the bar.
	x, y := keyboard_move_place(100, HEIGHT, .Up, false, FRAME_OF_TEST, SCREEN_WIDTH_OF_TEST, SCREEN_HEIGHT_OF_TEST)
	testing.expect_value(t, y, HEIGHT)
	testing.expect_value(t, x, 100)
	// Right past the edge keeps TITLE_KEPT pixels of the title.
	x, _ = keyboard_move_place(SCREEN_WIDTH_OF_TEST - TITLE_KEPT, 200, .Right, false, FRAME_OF_TEST, SCREEN_WIDTH_OF_TEST, SCREEN_HEIGHT_OF_TEST)
	testing.expect_value(t, x, SCREEN_WIDTH_OF_TEST - TITLE_KEPT)
	// Down past the bottom keeps TITLE_KEPT lines.
	_, y = keyboard_move_place(100, SCREEN_HEIGHT_OF_TEST - TITLE_KEPT, .Down, true, FRAME_OF_TEST, SCREEN_WIDTH_OF_TEST, SCREEN_HEIGHT_OF_TEST)
	testing.expect_value(t, y, SCREEN_HEIGHT_OF_TEST - TITLE_KEPT)
	// Left past the edge keeps the end of the title and the close button.
	title_width := FRAME_OF_TEST.outer_width - FRAME_OF_TEST.border - FRAME_OF_TEST.close_size
	left_bound := TITLE_KEPT - title_width
	x, _ = keyboard_move_place(left_bound, 200, .Left, false, FRAME_OF_TEST, SCREEN_WIDTH_OF_TEST, SCREEN_HEIGHT_OF_TEST)
	testing.expect_value(t, x, left_bound)
	// A place far outside comes back to the bound in one step.
	x, y = keyboard_move_place(max(int) / 2, max(int) / 2, .Down, false, FRAME_OF_TEST, SCREEN_WIDTH_OF_TEST, SCREEN_HEIGHT_OF_TEST)
	testing.expect_value(t, x, SCREEN_WIDTH_OF_TEST - TITLE_KEPT)
	testing.expect_value(t, y, SCREEN_HEIGHT_OF_TEST - TITLE_KEPT)
	// Inside the bounds: one token, or one pixel with Shift.
	x, y = keyboard_move_place(300, 200, .Left, false, FRAME_OF_TEST, SCREEN_WIDTH_OF_TEST, SCREEN_HEIGHT_OF_TEST)
	testing.expect(t, x == 300 - KEYBOARD_STEP && y == 200)
	x, y = keyboard_move_place(300, 200, .Down, true, FRAME_OF_TEST, SCREEN_WIDTH_OF_TEST, SCREEN_HEIGHT_OF_TEST)
	testing.expect(t, x == 300 && y == 201)
}

// A resize by keys stays inside the limits of the window and on the
// screen: the bounds first, then a step inside them.
@(test)
a_resize_by_keys_keeps_the_limits_and_the_screen :: proc(t: ^testing.T) {
	resize :: proc(x, y, width, height: int, arrow: Arrow, fine: bool) -> (int, int) {
		return keyboard_resize_size(x, y, width, height, arrow, fine, SIZES_OF_TEST, FRAME_WIDTH_OF_TEST, FRAME_HEIGHT_OF_TEST, SCREEN_WIDTH_OF_TEST, SCREEN_HEIGHT_OF_TEST)
	}
	// At the least size, Left and Up shrink nothing.
	width, height := resize(100, 100, SIZES_OF_TEST.least_width, SIZES_OF_TEST.least_height, .Left, false)
	testing.expect_value(t, width, SIZES_OF_TEST.least_width)
	width, height = resize(100, 100, SIZES_OF_TEST.least_width, SIZES_OF_TEST.least_height, .Up, false)
	testing.expect_value(t, height, SIZES_OF_TEST.least_height)
	// One pixel over the least size, a step of the token stops at it.
	width, _ = resize(100, 100, SIZES_OF_TEST.least_width + 1, 200, .Left, false)
	testing.expect_value(t, width, SIZES_OF_TEST.least_width)
	// At the largest size, Right and Down grow nothing.
	width, _ = resize(100, 100, SIZES_OF_TEST.largest_width, 200, .Right, false)
	testing.expect_value(t, width, SIZES_OF_TEST.largest_width)
	_, height = resize(100, 100, 300, SIZES_OF_TEST.largest_height, .Down, false)
	testing.expect_value(t, height, SIZES_OF_TEST.largest_height)
	// The right edge of the screen stops the width before the limit.
	x := SCREEN_WIDTH_OF_TEST - FRAME_WIDTH_OF_TEST - 300
	width, _ = resize(x, 100, 300, 200, .Right, false)
	testing.expect_value(t, width, 300)
	width, _ = resize(x - 5, 100, 300, 200, .Right, false)
	testing.expect_value(t, width, 305)
	// The bottom of the screen stops the height.
	y := SCREEN_HEIGHT_OF_TEST - FRAME_HEIGHT_OF_TEST - 200
	_, height = resize(100, y, 300, 200, .Down, false)
	testing.expect_value(t, height, 200)
	// Inside the bounds: one token, or one pixel with Shift.
	width, height = resize(100, 100, 300, 200, .Right, false)
	testing.expect(t, width == 300 + KEYBOARD_STEP && height == 200)
	width, height = resize(100, 100, 300, 200, .Up, true)
	testing.expect(t, width == 300 && height == 199)
}

// The walk over the bar: no focus starts at the heron button; each end
// goes around; an item that left steps from the end; Left and Right undo
// each other.
@(test)
the_keys_walk_the_items_of_the_bar :: proc(t: ^testing.T) {
	// The edges: no plate and no mark, one plate, the largest counts.
	testing.expect_value(t, bar_item_count(0, false), 2)
	testing.expect_value(t, bar_item_count(-5, false), 2)
	testing.expect_value(t, bar_item_count(3, true), 6)
	testing.expect_value(t, bar_item_step({}, 0, false, true), Bar_Item{kind = .Start})
	testing.expect_value(t, bar_item_step({}, 0, false, false), Bar_Item{kind = .Start})
	// Around the ends.
	testing.expect_value(t, bar_item_step({kind = .Start}, 0, false, false), Bar_Item{kind = .Windows})
	testing.expect_value(t, bar_item_step({kind = .Windows}, 0, false, true), Bar_Item{kind = .Start})
	testing.expect_value(t, bar_item_step({kind = .Windows}, 2, false, true), Bar_Item{kind = .Plate, plate = 0})
	testing.expect_value(t, bar_item_step({kind = .Plate, plate = 1}, 2, true, true), Bar_Item{kind = .Viewer_Mark})
	testing.expect_value(t, bar_item_step({kind = .Viewer_Mark}, 2, true, true), Bar_Item{kind = .Start})
	testing.expect_value(t, bar_item_step({kind = .Start}, 2, true, false), Bar_Item{kind = .Viewer_Mark})
	// An item that left the bar: a plate past the count, a negative plate,
	// a mark that went.
	testing.expect_value(t, bar_item_place({kind = .Plate, plate = 2}, 2, false), -1)
	testing.expect_value(t, bar_item_place({kind = .Plate, plate = -1}, 2, false), -1)
	testing.expect_value(t, bar_item_place({kind = .Viewer_Mark}, 2, false), -1)
	testing.expect_value(t, bar_item_place({}, 2, true), -1)
	testing.expect_value(t, bar_item_step({kind = .Plate, plate = 7}, 2, false, false), Bar_Item{kind = .Plate, plate = 1})
	testing.expect_value(t, bar_item_step({kind = .Plate, plate = 7}, 2, false, true), Bar_Item{kind = .Start})
	testing.expect_value(t, bar_item_step({kind = .Viewer_Mark}, 0, false, false), Bar_Item{kind = .Windows})
	// A place outside the order is no item.
	testing.expect_value(t, bar_item_at(-1, 2, true), Bar_Item{})
	testing.expect_value(t, bar_item_at(5, 2, true), Bar_Item{})
	testing.expect_value(t, bar_item_at(max(int), 2, true), Bar_Item{})
	// Right then Left gives each item back.
	for place in 0 ..< bar_item_count(4, true) {
		item := bar_item_at(place, 4, true)
		testing.expect_value(t, bar_item_place(item, 4, true), place)
		testing.expect_value(t, bar_item_step(bar_item_step(item, 4, true, true), 4, true, false), item)
	}
}

// The keys walk the lines of the start menu, then its quick actions, and
// go around; the menu of the windows goes around its count.
@(test)
the_keys_walk_the_lines_of_the_menus :: proc(t: ^testing.T) {
	line, action := start_menu_step(-1, .None, true)
	testing.expect(t, line == 0 && action == .None)
	line, action = start_menu_step(-1, .None, false)
	testing.expect(t, line == -1 && action == .Magnifier)
	line, action = start_menu_step(len(names) - 1, .None, true)
	testing.expect(t, line == -1 && action == .Bar_Edge)
	line, action = start_menu_step(-1, .Bar_Edge, false)
	testing.expect(t, line == len(names) - 1 && action == .None)
	line, action = start_menu_step(-1, .Magnifier, true)
	testing.expect(t, line == 0 && action == .None)
	line, action = start_menu_step(0, .None, false)
	testing.expect(t, line == -1 && action == .Magnifier)
	// The order of the quick actions is the order of their lines.
	for ordered, index in start_actions_in_order {
		_, y, _, _ := action_line({}, ordered)
		if index > 0 {
			_, before_y, _, _ := action_line({}, start_actions_in_order[index - 1])
			testing.expect(t, before_y < y)
		}
	}
	testing.expect_value(t, len(start_actions_in_order), len(Start_Action) - 1)
	// A line past the names is no line: Down starts at the first one.
	line, action = start_menu_step(len(names), .None, true)
	testing.expect(t, line == 0 && action == .None)
	// Each place of the order is reached once in a whole round.
	seen: [START_MENU_KEY_LINES]bool
	line, action = -1, .None
	for _ in 0 ..< START_MENU_KEY_LINES {
		line, action = start_menu_step(line, action, true)
		place := line
		for ordered, index in start_actions_in_order {
			if action != .None && ordered == action {
				place = len(names) + index
			}
		}
		testing.expect(t, place >= 0 && place < START_MENU_KEY_LINES && !seen[place])
		seen[place] = true
	}
	// The menu of the windows: no window, one, the ends, a line past the count.
	testing.expect_value(t, windows_menu_step(-1, 0, true), -1)
	testing.expect_value(t, windows_menu_step(3, -1, false), -1)
	testing.expect_value(t, windows_menu_step(0, 1, true), 0)
	testing.expect_value(t, windows_menu_step(-1, 3, true), 0)
	testing.expect_value(t, windows_menu_step(-1, 3, false), 2)
	testing.expect_value(t, windows_menu_step(2, 3, true), 0)
	testing.expect_value(t, windows_menu_step(0, 3, false), 2)
	testing.expect_value(t, windows_menu_step(9, 3, false), 2)
}

// The outline of the focus around each item of the bar stays in the bar,
// at each edge of the screen, and in the gap between two plates: no item
// drawn after it covers it, and the damage of the bar holds it.
@(test)
the_outline_of_the_focus_fits_around_each_item_of_the_bar :: proc(t: ^testing.T) {
	testing.expect(t, PLATE_GAP >= interface.FOCUS_RING_WIDTH)
	testing.expect(t, BUTTON_GAP >= interface.FOCUS_RING_WIDTH)
	for edge in Edge {
		layout := placed({}, edge, SCREEN_HEIGHT_OF_TEST)
		bar_top := top(layout)
		items: [4]interface.Area
		items[0].x, items[0].y, items[0].width, items[0].height = button(layout)
		items[1].x, items[1].y, items[1].width, items[1].height = windows_button(layout)
		items[2].x, items[2].y, items[2].width, items[2].height = plate(layout, 0)
		items[3].x, items[3].y, items[3].width, items[3].height = plate(layout, 1)
		for item, index in items {
			ring := interface.focus_ring_area(item)
			testing.expectf(t, ring.x >= 0 && ring.y >= bar_top && ring.y + ring.height <= bar_top + HEIGHT, "%v edge: the outline of item %d is %v", edge, index, ring)
			if index + 1 < len(items) {
				// The outline of an item ends where the outline of the next
				// one starts, at most: two outlines never cover an item.
				testing.expectf(t, ring.x + ring.width <= items[index + 1].x, "%v edge: the outline of item %d covers the next", edge, index)
			}
		}
	}
}
