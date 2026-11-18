#+build !freestanding
package interface

import "modus:support/display"
import "core:testing"

// The tests of the action bar: the fit of the items, the overflow at
// several widths, the order of priority, the place of the list, the keys of
// the list, and the press that gives the key of an item. A table with no
// interface font measures in the font of the cells: 8 pixels for each
// character, so each width below follows from the texts.

@(private = "file")
Bar_Memory :: struct {
	records: [1024]Draw_Record,
	text:    [8192]u8,
}

@(private = "file")
bar_table_of :: proc(memory: ^Bar_Memory) -> Draw_Table {
	return {records = memory.records[:], text = memory.text[:]}
}

// The items of the tests: their priorities are not in their order.
@(private = "file")
test_items :: proc() -> [5]Action_Bar_Item {
	return {
		action_bar_item("module before", 5, "Up"),
		action_bar_item("next link", 1, "Tab"),
		action_bar_item("open", 3, "Enter"),
		action_bar_item("back", 1, "Backspace"),
		action_bar_item("link before", 4, "Shift", "Tab"),
	}
}

// The width of the box of an item, from the rule of the bar: its margins,
// each keycap (its label and its padding, or the least width), the "+"
// with its gaps, the gap and the name, each character 8 pixels.
@(private = "file")
expected_width :: proc(item: Action_Bar_Item) -> int {
	CHARACTER :: 8
	width := 2 * ACTION_BAR_ITEM_MARGIN + ACTION_BAR_NAME_GAP + len(item.name) * CHARACTER
	for face, index in item.faces {
		if face == "" {
			break
		}
		if index > 0 {
			width += 2 * ACTION_BAR_JOIN_GAP + len(ACTION_BAR_JOIN_TEXT) * CHARACTER
		}
		inner := 0
		switch face {
		case "Up", "Down", "Left", "Right":
			inner = ACTION_BAR_ARROW_WIDTH
		case "Page Up", "Page Down":
			inner = len("Page") * CHARACTER + ACTION_BAR_ARROW_GAP + ACTION_BAR_ARROW_WIDTH
		case:
			inner = len(face) * CHARACTER
		}
		width += max(inner + 2 * ACTION_BAR_KEYCAP_PADDING, ACTION_BAR_KEYCAP_LEAST_WIDTH)
	}
	return width
}

@(private = "file")
expected_more_width :: proc(count_text: string) -> int {
	return 2 * ACTION_BAR_ITEM_MARGIN + ACTION_BAR_KEYCAP_LEAST_WIDTH + ACTION_BAR_NAME_GAP + (len(count_text) + 1 + len(ACTION_BAR_MORE_NAME)) * 8
}

@(test)
action_bar_measures_each_item :: proc(t: ^testing.T) {
	memory: Bar_Memory
	table := bar_table_of(&memory)
	items := test_items()
	for &item in items {
		testing.expect_value(t, action_bar_item_width(&table, &item), expected_width(item))
	}
	page := action_bar_item("up", 0, "Page Up")
	testing.expect_value(t, action_bar_item_width(&table, &page), expected_width(page))
	testing.expect_value(t, action_bar_more_width(&table, 3), expected_more_width("3"))
}

@(test)
action_bar_items_that_fit_stay_in_one_row :: proc(t: ^testing.T) {
	memory: Bar_Memory
	table := bar_table_of(&memory)
	items := test_items()
	area := Area{10, 200, 1000, ACTION_BAR_ROW_HEIGHT}
	layout := action_bar_layout(&table, area, items[:])
	testing.expect_value(t, layout.listed_count, 0)
	testing.expect_value(t, layout.more_box.width, 0)
	testing.expect_value(t, layout.rows, 1)
	x := area.x
	for item, index in items {
		testing.expect(t, layout.in_row[index])
		testing.expect_value(t, layout.boxes[index], Area{x, area.y, expected_width(item), ACTION_BAR_ROW_HEIGHT})
		x += expected_width(item) + ACTION_BAR_DIVIDER_WIDTH
	}
}

// The sum of the boxes of the items in a row, with the dividers, and the
// button: the room that they take.
@(private = "file")
row_room :: proc(items: []Action_Bar_Item, layout: ^Action_Bar_Layout, more_width: int) -> int {
	used := 0
	shown := 0
	for item, index in items {
		if layout.in_row[index] {
			used += expected_width(item)
			shown += 1
		}
	}
	if more_width > 0 {
		used += more_width
		shown += 1
	}
	return used + max(shown - 1, 0) * ACTION_BAR_DIVIDER_WIDTH
}

// The room of all the items in one row, with no button.
@(private = "file")
whole_row_room :: proc(items: []Action_Bar_Item) -> int {
	whole: Action_Bar_Layout
	for index in 0 ..< len(items) {
		whole.in_row[index] = true
	}
	return row_room(items, &whole, 0)
}

@(test)
action_bar_overflow_at_several_widths :: proc(t: ^testing.T) {
	memory: Bar_Memory
	table := bar_table_of(&memory)
	items := test_items()
	all := whole_row_room(items[:])
	// From the width that holds all of them down to a bar with room for
	// the button alone: at each width the row and the button fit in the
	// bar, and the list holds the rest in the order of the caller.
	for width := all; width >= 160; width -= 37 {
		layout := action_bar_layout(&table, {0, 0, width, ACTION_BAR_ROW_HEIGHT}, items[:])
		if width == all {
			testing.expect_value(t, layout.listed_count, 0)
			continue
		}
		testing.expectf(t, layout.listed_count > 0, "at %d pixels the items do not fit", width)
		count_text: [4]u8
		count_text[0] = u8('0' + layout.listed_count)
		more := expected_more_width(string(count_text[:1]))
		testing.expect_value(t, layout.more_box.width, more)
		testing.expectf(t, row_room(items[:], &layout, more) <= width, "at %d pixels the row passes the bar", width)
		testing.expect_value(t, layout.more_box.x + layout.more_box.width, row_room(items[:], &layout, more))
		// The listed items, in the order of the caller, are the ones out
		// of the row.
		listed := 0
		for index in 0 ..< len(items) {
			if !layout.in_row[index] {
				testing.expect_value(t, layout.listed[listed], index)
				listed += 1
			}
		}
		testing.expect_value(t, listed, layout.listed_count)
	}
}

@(test)
action_bar_takes_out_the_lowest_priority_first :: proc(t: ^testing.T) {
	memory: Bar_Memory
	table := bar_table_of(&memory)
	items := test_items()
	// The priorities: 5, 1, 3, 1, 4. Of the two items of priority 1 the
	// later one leaves first (index 3), then index 1, then index 2 (3),
	// then index 4 (4).
	order := [4]int{3, 1, 2, 4}
	all := whole_row_room(items[:])
	before := 0
	for width := all - 1; width >= 0; width -= 1 {
		layout := action_bar_layout(&table, {0, 0, width, ACTION_BAR_ROW_HEIGHT}, items[:])
		if layout.listed_count == before {
			continue
		}
		testing.expectf(t, layout.listed_count > before, "a narrower bar lists fewer items at %d pixels", width)
		for out in order[:min(layout.listed_count, len(order))] {
			testing.expectf(t, !layout.in_row[out], "at %d pixels the item %d is in the row", width, out)
		}
		before = layout.listed_count
	}
	testing.expect_value(t, before, len(items))
}

@(test)
action_bar_right_alignment_ends_at_the_edge :: proc(t: ^testing.T) {
	memory: Bar_Memory
	table := bar_table_of(&memory)
	items := test_items()
	area := Area{40, 0, 1000, ACTION_BAR_ROW_HEIGHT}
	layout := action_bar_layout(&table, area, items[:], {alignment = .Right})
	last := layout.boxes[len(items) - 1]
	testing.expect_value(t, last.x + last.width, area.x + area.width)
	testing.expect_value(t, layout.boxes[0].x, area.x + area.width - row_room(items[:], &layout, 0))
}

@(test)
action_bar_wrap_takes_two_rows_in_order :: proc(t: ^testing.T) {
	memory: Bar_Memory
	table := bar_table_of(&memory)
	items := test_items()
	all := whole_row_room(items[:])
	width := all * 2 / 3
	layout := action_bar_layout(&table, {0, 100, width, 2 * ACTION_BAR_ROW_HEIGHT}, items[:], {overflow = .Wrap})
	testing.expect_value(t, layout.listed_count, 0)
	testing.expect_value(t, layout.rows, 2)
	// The order: the items of the second row come after those of the first.
	for index in 1 ..< len(items) {
		before, now := layout.boxes[index - 1], layout.boxes[index]
		testing.expect(t, now.y > before.y || now.y == before.y && now.x > before.x)
	}
	testing.expect_value(t, layout.boxes[len(items) - 1].y, 100 + ACTION_BAR_ROW_HEIGHT)
}

@(test)
action_bar_list_opens_upward_at_the_right_edge :: proc(t: ^testing.T) {
	memory: Bar_Memory
	table := bar_table_of(&memory)
	items := test_items()
	area := Area{0, 400, 300, ACTION_BAR_ROW_HEIGHT}
	layout := action_bar_layout(&table, area, items[:])
	testing.expect(t, layout.listed_count >= 2)
	list, shown := action_bar_list_place(&table, area, items[:], &layout, 0)
	testing.expect_value(t, shown, layout.listed_count)
	testing.expect_value(t, list.x + list.width, area.x + area.width)
	testing.expect_value(t, list.y + list.height, area.y)
	widest := 0
	for index in layout.listed[:layout.listed_count] {
		widest = max(widest, expected_width(items[index]))
	}
	testing.expect_value(t, list.width, widest + 2 * ACTION_BAR_LIST_BORDER)
	testing.expect_value(t, list.height, 2 * ACTION_BAR_LIST_BORDER + shown * ACTION_BAR_ROW_HEIGHT + (shown - 1) * ACTION_BAR_DIVIDER_WIDTH)
	// The last row touches the border over the bar.
	last := action_bar_list_row(list, shown - 1)
	testing.expect_value(t, last.y + last.height + ACTION_BAR_LIST_BORDER, area.y)
	// A room of two rows above the bar holds two rows; the rest are not shown.
	two := 2 * ACTION_BAR_LIST_BORDER + 2 * ACTION_BAR_ROW_HEIGHT + ACTION_BAR_DIVIDER_WIDTH
	list, shown = action_bar_list_place(&table, area, items[:], &layout, area.y - two)
	testing.expect_value(t, shown, 2)
	testing.expect_value(t, list.y, area.y - two)
}

@(test)
action_bar_key_of_reads_the_faces :: proc(t: ^testing.T) {
	cases := [?]struct {
		item:  Action_Bar_Item,
		press: Key_Press,
		ok:    bool,
	} {
		{action_bar_item("enter", 0, "Enter"), {code = display.KEY_ENTER, character = '\n'}, true},
		{action_bar_item("backspace", 0, "Backspace"), {code = display.KEY_BACKSPACE, character = 8}, true},
		{action_bar_item("shift tab", 0, "Shift", "Tab"), {code = KEY_TAB, character = '\t', modifiers = display.MODIFIER_SHIFT}, true},
		{action_bar_item("ctrl k", 0, "Ctrl", "k"), {character = 'k', modifiers = display.MODIFIER_CONTROL}, true},
		{action_bar_item("page down", 0, "Page Down"), {code = display.KEY_PAGE_DOWN}, true},
		{action_bar_item("h", 0, "h"), {character = 'h'}, true},
		{action_bar_item("range", 0, "0-3"), {}, false},
		{action_bar_item("two keys", 0, "Tab", "Enter"), {}, false},
		// A face past the capacity is dropped: Shift, Ctrl and Tab stay,
		// and the Enter after them is not the key.
		{action_bar_item("four faces", 0, "Shift", "Ctrl", "Tab", "Enter"), {code = KEY_TAB, character = '\t', modifiers = display.MODIFIER_SHIFT | display.MODIFIER_CONTROL}, true},
		{{}, {}, false},
	}
	for &each in cases {
		press, ok := action_bar_key_of(&each.item)
		testing.expect_value(t, ok, each.ok)
		testing.expect_value(t, press, each.press)
	}
}

// One frame of a bar of 300 pixels at the bottom of a window of 300 by
// 400, whose input gets one pointer event and the keys given.
@(private = "file")
BAR_AREA :: Area{0, 376, 300, ACTION_BAR_ROW_HEIGHT}

@(private = "file")
bar_frame :: proc(table: ^Draw_Table, state: ^Interface_State, input: ^Input, bar: ^Action_Bar_State, items: []Action_Bar_Item) -> Action_Bar_Result {
	frame := frame_begin(table, state, input)
	action_bar_input_take(&frame, bar)
	result := action_bar(&frame, BAR_AREA, items, bar)
	frame_end(&frame)
	input_clear(input)
	return result
}

@(private = "file")
pointer_to :: proc(input: ^Input, area: Area, held: bool) {
	input_add(input, {kind = .Pointer, x = area.x + area.width / 2, y = area.y + area.height / 2, buttons = held ? display.BUTTON_LEFT : 0})
}

@(test)
action_bar_press_on_an_item_gives_its_key :: proc(t: ^testing.T) {
	memory: Bar_Memory
	table := bar_table_of(&memory)
	state: Interface_State
	input: Input
	bar: Action_Bar_State
	items := test_items()
	bar_frame(&table, &state, &input, &bar, items[:])
	layout := action_bar_layout(&table, BAR_AREA, items[:])
	testing.expect(t, layout.in_row[0])
	pointer_to(&input, layout.boxes[0], true)
	result := bar_frame(&table, &state, &input, &bar, items[:])
	testing.expect(t, !result.ran, "a press runs nothing before its release")
	pointer_to(&input, layout.boxes[0], false)
	result = bar_frame(&table, &state, &input, &bar, items[:])
	testing.expect(t, result.ran)
	testing.expect_value(t, result.run, Key_Press{code = display.KEY_UP})
}

@(test)
action_bar_list_by_pointer_and_by_keys :: proc(t: ^testing.T) {
	memory: Bar_Memory
	table := bar_table_of(&memory)
	state: Interface_State
	input: Input
	bar: Action_Bar_State
	items := test_items()
	bar_frame(&table, &state, &input, &bar, items[:])
	layout := action_bar_layout(&table, BAR_AREA, items[:])
	testing.expect(t, layout.listed_count >= 2)
	testing.expect(t, layout.more_box.width > 0)

	// A press and a release on the button open the list.
	pointer_to(&input, layout.more_box, true)
	bar_frame(&table, &state, &input, &bar, items[:])
	pointer_to(&input, layout.more_box, false)
	bar_frame(&table, &state, &input, &bar, items[:])
	testing.expect(t, bar.open)
	testing.expect_value(t, bar.listed_count, layout.listed_count)
	list, _ := action_bar_list_place(&table, BAR_AREA, items[:], &layout, 0)
	testing.expect_value(t, bar.list_area, list)

	// Up from no row chooses the last row, next to the bar; Down then
	// stops at it; Up moves to the row before.
	key_add :: proc(input: ^Input, code: u32, character: rune = 0) {
		input_add(input, {kind = .Key, code = code, character = character, pressed = true})
	}
	key_add(&input, display.KEY_UP)
	bar_frame(&table, &state, &input, &bar, items[:])
	testing.expect(t, bar.has_chosen && bar.chosen == layout.listed_count - 1)
	key_add(&input, display.KEY_DOWN)
	bar_frame(&table, &state, &input, &bar, items[:])
	testing.expect_value(t, bar.chosen, layout.listed_count - 1)
	key_add(&input, display.KEY_UP)
	bar_frame(&table, &state, &input, &bar, items[:])
	testing.expect_value(t, bar.chosen, layout.listed_count - 2)

	// Enter runs the chosen row and closes the list.
	key_add(&input, display.KEY_ENTER)
	result := bar_frame(&table, &state, &input, &bar, items[:])
	expected, _ := action_bar_key_of(&items[layout.listed[layout.listed_count - 2]])
	testing.expect(t, result.ran)
	testing.expect_value(t, result.run, expected)
	testing.expect(t, !bar.open)

	// Escape closes it, and is taken.
	bar.open = true
	bar_frame(&table, &state, &input, &bar, items[:])
	outcome := action_bar_key(&bar, {code = display.KEY_ESCAPE})
	testing.expect(t, outcome.taken && !outcome.ran && !bar.open)
	// Another key closes it and stays for the process.
	bar.open = true
	outcome = action_bar_key(&bar, {character = 'x'})
	testing.expect(t, !outcome.taken && !bar.open)
	// With the list closed, no key is taken.
	outcome = action_bar_key(&bar, {code = display.KEY_UP})
	testing.expect(t, !outcome.taken)

	// A press on a row runs it.
	bar.open = true
	bar_frame(&table, &state, &input, &bar, items[:])
	row := action_bar_list_row(bar.list_area, 0)
	pointer_to(&input, row, true)
	bar_frame(&table, &state, &input, &bar, items[:])
	pointer_to(&input, row, false)
	result = bar_frame(&table, &state, &input, &bar, items[:])
	expected, _ = action_bar_key_of(&items[layout.listed[0]])
	testing.expect(t, result.ran)
	testing.expect_value(t, result.run, expected)
	testing.expect(t, !bar.open)

	// A press outside the open list closes it and runs nothing; no
	// element under it sees the press.
	bar.open = true
	bar_frame(&table, &state, &input, &bar, items[:])
	input_add(&input, {kind = .Pointer, x = 10, y = 10, buttons = display.BUTTON_LEFT})
	frame := frame_begin(&table, &state, &input)
	action_bar_input_take(&frame, &bar)
	under := button(&frame, {0, 0, 80, 24}, identity("under"), "under")
	result = action_bar(&frame, BAR_AREA, items[:], &bar)
	frame_end(&frame)
	input_clear(&input)
	testing.expect(t, !bar.open && !result.ran)
	testing.expect(t, state.pressed != identity("under") && !under.activated, "the button under the press does not take it")
}

@(test)
action_bar_names_its_items :: proc(t: ^testing.T) {
	memory: Bar_Memory
	table := bar_table_of(&memory)
	state: Interface_State
	input: Input
	bar: Action_Bar_State
	items := test_items()
	frame := frame_begin(&table, &state, &input)
	action_bar_input_take(&frame, &bar)
	action_bar(&frame, BAR_AREA, items[:], &bar)
	layout := action_bar_layout(&table, BAR_AREA, items[:])
	for item, index in items {
		place := element_places_find(&frame.element_places, item.name)
		testing.expect_value(t, place != nil, layout.in_row[index])
		if place != nil {
			testing.expect_value(t, place.area, layout.boxes[index])
		}
	}
	more := element_places_find(&frame.element_places, ACTION_BAR_MORE_NAME)
	testing.expect(t, more != nil && more.area == layout.more_box)
	frame_end(&frame)
}
