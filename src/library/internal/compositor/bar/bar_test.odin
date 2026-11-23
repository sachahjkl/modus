#+build !freestanding
package bar

import "base:runtime"
import "core:sync"
import "core:testing"
import "modus:contract/font_outlines"
import "modus:text_rendering"

// The font outlines of B612, opened once for the tests of this package in
// the state of the text rendering: the measure of the names of the bar. The
// memory of the resource stays for the run.
@(private = "file")
outlines_opened: bool
@(private = "file")
outlines_lock: sync.Mutex
@(private = "file")
outlines_words: []u64

@(private = "file")
b612_open :: proc(t: ^testing.T) {
	sync.mutex_lock(&outlines_lock)
	defer sync.mutex_unlock(&outlines_lock)
	if outlines_opened {
		return
	}
	fonts := [1]font_outlines.Font_Input{{"b612", #load("../../../../../resources/fonts/b612.ttf")}}
	size := font_outlines.resource_size(fonts[:])
	// The heap of the process, not the allocator of the test: the runner
	// frees all that a test allocated at its end, and the open fonts of the
	// state read these words in each later test.
	outlines_words = make([]u64, (size + 7) / 8, runtime.heap_allocator())
	bytes := ([^]u8)(raw_data(outlines_words))[:size]
	_, written := font_outlines.resource_write(fonts[:], bytes)
	testing.expect(t, written)
	room := new(font_outlines.Record_Room, context.temp_allocator)
	outlines, problem := font_outlines.validate(bytes, room[:])
	testing.expect_value(t, problem.kind, font_outlines.Problem_Kind.None)
	_ = text_rendering.open(&outlines)
	outlines_opened = true
}


// Each entry of the bar and of its menus, in one layout: the middle of each
// maps back to it, and the points just outside each button map to no
// button. The layouts: the font of the cells, two made-up proportional
// layouts (narrower and wider than the cells), and B612.
@(private = "file")
entries_round_trip :: proc(t: ^testing.T, layout: Layout, name: string) {
	start_x, start_y := button_center(layout)
	testing.expectf(t, button_at(layout, start_x, start_y) == .Start, "%s: the middle of the heron button", name)
	windows_x, windows_y := windows_button_center(layout)
	testing.expectf(t, button_at(layout, windows_x, windows_y) == .Windows, "%s: the middle of the button of the windows", name)
	x, y, width, height := button(layout)
	testing.expectf(t, button_at(layout, x - 1, y) == .None && button_at(layout, x, y - 1) == .None && button_at(layout, x + width - 1, y + height - 1) == .Start, "%s: the edges of the heron button", name)
	// The gap between the two buttons is no button.
	testing.expectf(t, button_at(layout, x + width, y) == .None && button_at(layout, x + width + BUTTON_GAP - 1, y) == .None, "%s: the gap between the buttons", name)
	windows_left, windows_top, windows_width, windows_height := windows_button(layout)
	testing.expectf(t, windows_left == x + width + BUTTON_GAP, "%s: the button of the windows follows the heron button", name)
	testing.expectf(t, button_at(layout, windows_left + windows_width, windows_top) == .None && button_at(layout, windows_left, windows_top + windows_height) == .None, "%s: past the button of the windows", name)
	for process, index in names {
		center_x, center_y, found := center(layout, process)
		if index >= shown_count(layout) {
			// A closed demonstration has no place to press.
			testing.expectf(t, !found, "%s: the closed demonstration %s has a place", name, process)
			continue
		}
		testing.expectf(t, found && line_at(layout, center_x, center_y) == index, "%s: the middle of the line of %s", name, process)
		line_x, line_y, line_width, line_height := line(layout, index)
		testing.expectf(t, line_at(layout, line_x, line_y) == index && line_at(layout, line_x + line_width - 1, line_y + line_height - 1) == index, "%s: the corners of the line of %s", name, process)
		testing.expectf(t, action_at(layout, center_x, center_y) == .None, "%s: the line of %s is no action", name, process)
	}
	for action in Start_Action {
		action_x, action_y, action_width, action_height := action_line(layout, action)
		if action == .None {
			testing.expectf(t, action_width == 0 && action_height == 0, "%s: None has no line", name)
			continue
		}
		testing.expectf(t, action_at(layout, action_x + action_width / 2, action_y + action_height / 2) == action, "%s: the middle of the action %v", name, action)
		testing.expectf(t, action_at(layout, action_x, action_y) == action && action_at(layout, action_x + action_width - 1, action_y + action_height - 1) == action, "%s: the corners of the action %v", name, action)
		testing.expectf(t, line_at(layout, action_x + 1, action_y + 1) == -1, "%s: the action %v is no line of a module", name, action)
	}
	menu_x, menu_y, menu_width, menu_height := menu(layout)
	testing.expectf(t, line_at(layout, menu_x + menu_width + 1, menu_y + menu_height / 2) == -1 && line_at(layout, menu_x, menu_y) == -1, "%s: past the menu and on its border", name)
	// The heading of each section is no line.
	for section in Menu_Section {
		if heading_x, heading_y, _, has_heading := heading_place(layout, section); has_heading {
			testing.expectf(t, line_at(layout, heading_x + 1, heading_y + 1) == -1, "%s: the heading of %v", name, section)
		}
	}
	testing.expect(t, menu_height > 0)
	for index in 0 ..< 5 {
		line_x, line_y := windows_line_center(layout, index)
		testing.expectf(t, windows_line_at(layout, 5, line_x, line_y) == index, "%s: the middle of the line %v of the windows", name, index)
		testing.expectf(t, windows_line_at(layout, index, line_x, line_y) == -1, "%s: a line past the count of windows", name)
	}
}

@(test)
each_entry_maps_back_to_itself :: proc(t: ^testing.T) {
	for open in ([2]bool{false, true}) {
		entries_round_trip(t, with_demonstrations(layout_of(.None), open), "the font of the cells")
		entries_round_trip(t, with_demonstrations({longest_name_width = 150}, open), "narrower")
		entries_round_trip(t, with_demonstrations({longest_name_width = 260}, open), "wider")
		entries_round_trip(t, with_demonstrations({}, open), "no name")
		b612_open(t)
		entries_round_trip(t, with_demonstrations(layout_of(.Interface), open), "B612")
		entries_round_trip(t, with_demonstrations(placed(layout_of(.None), .Bottom, 1080), open), "the font of the cells, at the bottom")
		entries_round_trip(t, with_demonstrations(placed({longest_name_width = 260}, .Bottom, 1200), open), "wider, at the bottom")
	}
}

// The sections of the start menu: the applications and the tools in the
// left pane, each under its heading, the demonstrations in the right pane
// under theirs, and each action in the left pane; no two lines share a
// pixel; the actions are under the last line of the tools with their gap,
// and the last action ends at the padding of the card. With the
// demonstrations closed, the card is the left pane alone, with the same
// places of its lines and actions as the open card at the top.
@(test)
the_start_menu_has_its_sections :: proc(t: ^testing.T) {
	for widths in ([?]Layout{layout_of(.None), {longest_name_width = 260}, placed(layout_of(.None), .Bottom, 1080)}) {
		open := with_demonstrations(widths, true)
		menu_x, menu_y, menu_width, menu_height := menu(open)
		pane_x, pane_y, pane_width_right, pane_height := right_pane(open)
		testing.expect_value(t, pane_x, menu_x + BORDER + pane_width(open) + 1)
		testing.expect_value(t, pane_x + pane_width_right, menu_x + menu_width - BORDER)
		testing.expect_value(t, pane_y + pane_height, menu_y + menu_height - BORDER)
		for index in 0 ..< len(names) {
			x, y, width, height := line(open, index)
			testing.expectf(t, y >= menu_y + BORDER + PANE_PADDING && y + height <= menu_y + menu_height - BORDER - PANE_PADDING, "the line of %s is inside the card", names[index])
			section := section_of(index)
			_, heading_y, _, has_heading := heading_place(open, section)
			testing.expectf(t, has_heading && y >= heading_y + HEADING_HEIGHT, "the line of %s is under the heading of %v", names[index], section)
			if section != .Demonstrations {
				testing.expectf(t, x >= menu_x + BORDER && x + width <= pane_x - 1, "the line of %s is in the left pane", names[index])
			} else {
				testing.expectf(t, x >= pane_x + PANE_PADDING && x + width <= pane_x + pane_width_right - PANE_PADDING, "the line of %s is in the right pane", names[index])
			}
			for other in index + 1 ..< len(names) {
				other_x, other_y, other_width, other_height := line(open, other)
				apart := x + width <= other_x || other_x + other_width <= x || y + height <= other_y || other_y + other_height <= y
				testing.expectf(t, apart, "the lines of %s and %s share no pixel", names[index], names[other])
			}
		}
		_, last_tool_y, _, last_tool_height := line(open, LEFT_COUNT - 1)
		_, first_action_y, _, _ := action_line(open, start_actions_in_order[0])
		testing.expect(t, first_action_y >= last_tool_y + last_tool_height + ACTIONS_GAP)
		action_x, last_action_y, action_width, last_action_height := action_line(open, .Magnifier)
		testing.expect(t, last_action_y + last_action_height <= menu_y + menu_height - BORDER - PANE_PADDING)
		testing.expect(t, action_x + action_width <= pane_x - 1)

		closed := with_demonstrations(widths, false)
		closed_x, closed_y, closed_width, closed_height := menu(closed)
		testing.expect_value(t, closed_width, 2 * BORDER + pane_width(closed))
		testing.expect(t, closed_height <= menu_height)
		_, _, closed_pane_width, _ := right_pane(closed)
		testing.expect_value(t, closed_pane_width, 0)
		_, _, _, demonstrations_heading := heading_place(closed, .Demonstrations)
		testing.expect(t, !demonstrations_heading, "the closed demonstrations have a heading")
		for index in 0 ..< LEFT_COUNT {
			x, y, width, height := line(closed, index)
			testing.expectf(t, x >= closed_x + BORDER && x + width <= closed_x + closed_width - BORDER && y >= closed_y && y + height <= closed_y + closed_height, "the line of %s is in the closed card", names[index])
		}
		// The last action ends the closed card at its padding.
		_, closed_last_y, _, closed_last_height := action_line(closed, .Magnifier)
		testing.expect_value(t, closed_last_y + closed_last_height, closed_y + closed_height - BORDER - PANE_PADDING)
		// Under a bar at the top, the action that opens the demonstrations
		// keeps its place when they open.
		if widths.edge == .Top {
			_, closed_toggle_y, _, _ := action_line(closed, .Demonstrations)
			_, open_toggle_y, _, _ := action_line(open, .Demonstrations)
			testing.expect_value(t, open_toggle_y, closed_toggle_y)
		}
	}
	// No section of the left pane is empty but the applications, which
	// wait for their first; each name has one section.
	testing.expect(t, TOOL_COUNT > 0 && DEMONSTRATION_COUNT > 0)
	_, _, _, applications_heading := heading_place({}, .Applications)
	testing.expect_value(t, applications_heading, APPLICATION_COUNT > 0)
}

// The label of a name: each "_" a space, the other bytes as they are; an
// empty name, a name of one byte, a name at the bound, and a name past it.
@(test)
a_label_reads_as_words :: proc(t: ^testing.T) {
	buffer: [LABEL_BYTES]u8
	testing.expect_value(t, label_of("", &buffer), "")
	testing.expect_value(t, label_of("_", &buffer), " ")
	testing.expect_value(t, label_of("hall_of_fame", &buffer), "hall of fame")
	at_bound: [LABEL_BYTES]u8
	for &value in at_bound {
		value = '_'
	}
	testing.expect_value(t, len(label_of(string(at_bound[:]), &buffer)), LABEL_BYTES)
	past: [LABEL_BYTES + 1]u8
	for &value in past {
		value = '_'
	}
	testing.expect_value(t, label_of(string(past[:]), &buffer), string(past[:]))
	for name in names {
		testing.expectf(t, len(name) <= LABEL_BYTES, "the name %s is longer than a label", name)
	}
}

// The zero value of the layout is a bar at the top, at the places that the
// machine test clicks: an edge in the layout moves no place of a bar at the
// top, whatever the height of the screen.
@(test)
a_bar_at_the_top_keeps_its_places :: proc(t: ^testing.T) {
	widths := layout_of(.None)
	for height in ([?]int{0, 1, HEIGHT, 720, 1080, max(int)}) {
		layout := placed(widths, .Top, height)
		testing.expect_value(t, top(layout), 0)
		_, button_y, _, _ := button(layout)
		testing.expect_value(t, button_y, PLATE_Y)
		_, menu_y, _, _ := menu(layout)
		testing.expect_value(t, menu_y, HEIGHT)
		_, windows_y, _, _ := windows_menu(layout, 3)
		testing.expect_value(t, windows_y, HEIGHT)
		_, line_y, _, _ := windows_line(layout, 2)
		testing.expect_value(t, line_y, HEIGHT + BORDER + TITLE + 2 * LINE_HEIGHT)
		testing.expect_value(t, mark_y(layout), MARK_Y)
		_, plate_y, _, _ := plate(layout, 4)
		testing.expect_value(t, plate_y, PLATE_Y)
		testing.expect(t, button_center_matches(widths, layout))
	}
}

@(private = "file")
button_center_matches :: proc(widths, layout: Layout) -> bool {
	x0, y0 := button_center(widths)
	x1, y1 := button_center(layout)
	x2, y2 := windows_button_center(widths)
	x3, y3 := windows_button_center(layout)
	return x0 == x1 && y0 == y1 && x2 == x3 && y2 == y3
}

// A bar at the bottom: its last row is the last row of the screen, and each
// menu ends on the first row of the bar.
@(test)
a_bar_at_the_bottom_opens_its_menus_up :: proc(t: ^testing.T) {
	layout := placed(layout_of(.None), .Bottom, 1080)
	testing.expect_value(t, top(layout), 1080 - HEIGHT)
	_, button_y, _, button_height := button(layout)
	testing.expect_value(t, button_y, 1080 - HEIGHT + PLATE_Y)
	testing.expect(t, button_y + button_height <= 1080)
	testing.expect_value(t, mark_y(layout), 1080 - HEIGHT + MARK_Y)
	_, menu_y, _, menu_height := menu(layout)
	testing.expect_value(t, menu_y + menu_height, top(layout))
	for count in ([?]int{0, 1, 5, 24}) {
		_, windows_y, _, windows_height := windows_menu(layout, count)
		testing.expect_value(t, windows_y + windows_height, top(layout))
		for index in 0 ..< count {
			// Each line is inside the card, under its title.
			_, line_y, _, line_height := windows_line(layout, index)
			testing.expectf(t, line_y >= windows_y + BORDER + TITLE && line_y + line_height <= windows_y + windows_height - BORDER, "the line %v of %v windows is in the card", index, count)
		}
	}
	// The first line is next to the bar.
	_, first_y, _, first_height := windows_line(layout, 0)
	testing.expect_value(t, first_y + first_height, top(layout) - BORDER)
	// A press on the bar is on the bar, one row past it on either side is not.
	testing.expect(t, inside_bar(layout, top(layout)) && inside_bar(layout, 1079))
	testing.expect(t, !inside_bar(layout, top(layout) - 1) && !inside_bar(layout, 1080) && !inside_bar(layout, 0))
	// A button of a bar at the bottom is not at the place of the button of
	// a bar at the top.
	testing.expect_value(t, button_at(layout, START_BUTTON_X + 1, PLATE_Y + 1), Bar_Button.None)
	testing.expect_value(t, plate_at(layout, 4000, PLATES_X + 1, PLATE_Y + 1), -1)
	testing.expect_value(t, plate_at(layout, 4000, PLATES_X + 1, top(layout) + PLATE_Y + 1), 0)
}

// The edges of the height of the screen: a screen no higher than the bar
// keeps the bar at 0, a negative height is 0, and a menu taller than the
// room over the bar starts at the first row of the screen, never above it.
@(test)
a_bar_at_the_bottom_stays_on_a_small_screen :: proc(t: ^testing.T) {
	widths := layout_of(.None)
	testing.expect_value(t, top(placed(widths, .Bottom, 0)), 0)
	testing.expect_value(t, top(placed(widths, .Bottom, HEIGHT - 1)), 0)
	testing.expect_value(t, top(placed(widths, .Bottom, HEIGHT)), 0)
	testing.expect_value(t, top(placed(widths, .Bottom, HEIGHT + 1)), 1)
	testing.expect_value(t, placed(widths, .Bottom, -5).screen_height, 0)
	testing.expect_value(t, top(placed(widths, .Bottom, -5)), 0)
	small := placed(widths, .Bottom, 200)
	_, menu_y, _, menu_height := menu(small)
	testing.expect(t, menu_height > 200 - HEIGHT)
	testing.expect_value(t, menu_y, 0)
	testing.expect_value(t, menu_top(small, 0), 200 - HEIGHT)
	testing.expect_value(t, menu_top(small, 200 - HEIGHT), 0)
	testing.expect_value(t, menu_top(small, 200 - HEIGHT + 1), 0)
	testing.expect_value(t, menu_top(small, max(int)), 0)
}

// The plates of the windows: they start after the divider, which follows
// the button of the windows; the middle and the corners of each plate map
// back to its slot; the gap between two plates, the rows above and under
// them, the room before the first and a plate that does not end before the
// right end of the plates are no plate.
@(test)
the_plates_map_back_to_their_slots :: proc(t: ^testing.T) {
	layout := layout_of(.None)
	windows_x, _, windows_width, _ := windows_button(layout)
	testing.expect(t, DIVIDER_X >= windows_x + windows_width && PLATES_X > DIVIDER_X)
	right := PLATES_X + 3 * (PLATE_WIDTH + PLATE_GAP) - PLATE_GAP // Room for three plates exactly.
	for slot in 0 ..< 3 {
		x, y, width, height := plate(layout, slot)
		testing.expect_value(t, plate_at(layout, right, x + width / 2, y + height / 2), slot)
		testing.expect_value(t, plate_at(layout, right, x, y), slot)
		testing.expect_value(t, plate_at(layout, right, x + width - 1, y + height - 1), slot)
		testing.expect_value(t, plate_at(layout, right, x, y - 1), -1)
		testing.expect_value(t, plate_at(layout, right, x, y + height), -1)
		if slot < 2 {
			testing.expect_value(t, plate_at(layout, right, x + width, y), -1)
			testing.expect_value(t, plate_at(layout, right, x + width + PLATE_GAP - 1, y), -1)
		}
	}
	_, plate_y, _, _ := plate(layout, 0)
	testing.expect_value(t, plate_at(layout, right, PLATES_X - 1, plate_y), -1)
	testing.expect_value(t, plate_at(layout, right, DIVIDER_X, plate_y), -1)
	fourth_x, _, _, _ := plate(layout, 3)
	testing.expect_value(t, plate_at(layout, right, fourth_x + 1, plate_y), -1)
	testing.expect_value(t, plate_at(layout, right + 1, fourth_x + 1, plate_y), -1)
	testing.expect_value(t, plate_at(layout, right + PLATE_WIDTH + PLATE_GAP, fourth_x + 1, plate_y), 3)
	testing.expect_value(t, plate_at(layout, 0, PLATES_X + 1, plate_y), -1)
	testing.expect_value(t, plate_at(layout, max(int) / 2, max(int) / 4, plate_y) >= 0, true)
}

// The places follow the widths: a wider name widens each column by the
// same pixels, past COLUMN_LEAST. In B612 each name fits its line with its
// icon and its padding, and the names of the bar are not the widths of the
// cells.
@(test)
places_follow_the_measured_widths :: proc(t: ^testing.T) {
	LEAST_NAME :: COLUMN_LEAST - ICON_SIZE - ICON_GAP - 2 * PADDING
	testing.expect_value(t, column_width({longest_name_width = 100}), COLUMN_LEAST) // 100 + 40 is 140: under COLUMN_LEAST.
	testing.expect_value(t, column_width({longest_name_width = LEAST_NAME}), COLUMN_LEAST)
	testing.expect_value(t, column_width({longest_name_width = LEAST_NAME + 1}), COLUMN_LEAST + 1) // One pixel past the least: one pixel wider, no round up.
	testing.expect_value(t, column_width({longest_name_width = 200}), 200 + ICON_SIZE + ICON_GAP + 2 * PADDING)
	testing.expect_value(t, column_width({}), COLUMN_LEAST) // No name: the least width.
	_, _, narrow_width, _ := menu({longest_name_width = 200, demonstrations_open = true})
	_, _, wide_width, _ := menu({longest_name_width = 210, demonstrations_open = true})
	testing.expect_value(t, wide_width - narrow_width, 10 * (COLUMNS + 1)) // The left pane and each column.
	_, _, narrow_closed, _ := menu({longest_name_width = 200})
	_, _, wide_closed, _ := menu({longest_name_width = 210})
	testing.expect_value(t, wide_closed - narrow_closed, 10) // The left pane alone.
	b612_open(t)
	layout := layout_of(.Interface)
	cells := layout_of(.None)
	testing.expect(t, layout.longest_name_width > 0)
	testing.expect(t, layout != cells, "B612 measures the names of the bar in its own widths")
	for process, index in names {
		_, _, line_width, _ := line(layout, index)
		buffer: [LABEL_BYTES]u8
		testing.expectf(t, text_width_in(.Interface, label_of(process, &buffer)) + ICON_SIZE + ICON_GAP + 2 * PADDING <= line_width, "%s fits its line", process)
	}
	// The labels of the quick actions fit the least column in both fonts.
	for label in ([?]string{"demonstrations", "bar to bottom", "bar to top", "magnifier"}) {
		testing.expectf(t, text_width_in(.Interface, label) + ICON_SIZE + ICON_GAP + 2 * PADDING <= COLUMN_LEAST, "%s fits an action line", label)
		testing.expectf(t, text_width_in(.None, label) + ICON_SIZE + ICON_GAP + 2 * PADDING <= COLUMN_LEAST, "%s fits an action line in the cells", label)
	}
	// The start menu of B612 fits the reference screen of 1280 pixels, with
	// its demonstrations open.
	_, _, menu_width, menu_height := menu(with_demonstrations(layout, true))
	testing.expect(t, menu_width <= 1280 && menu_height <= 720 - HEIGHT)
	// A face that the outlines lack measures in the font of the cells.
	testing.expect_value(t, layout_of(.Cells), cells)
}
