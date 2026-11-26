#+build !freestanding
#+build !modus
package interface

import "core:strings"
import "core:testing"
import "modus:display"

@(private = "file")
DESKTOP_ITEMS := [4]Context_Menu_Item{
	{id = 1, label = "New Console"},
	{id = 2, label = "Open Monitor"},
	{id = 3, label = "Toggle Magnifier", shortcut = "Ctrl+Shift+M"},
	{id = 4, label = "Move Bar Bottom"},
}

@(private = "file")
row_middle :: proc(m: ^Context_Menu_State, row: int) -> (x, y: int) {
	row_x, row_y, width, height, _ := context_menu_row_rect(m, row)
	return row_x + width / 2, row_y + height / 2
}

@(test)
context_menu_fuzzy_filters_highlights_and_triggers :: proc(t: ^testing.T) {
	menu: Context_Menu_State
	context_menu_open(&menu, 1800, 1000, 1920, 1080, DESKTOP_ITEMS[:])
	testing.expect(t, menu.open)
	// Clamped inside screen bounds.
	testing.expect(t, menu.x + CONTEXT_MENU_WIDTH <= 1920 - CONTEXT_MENU_SCREEN_MARGIN)
	testing.expect(t, menu.y + context_menu_height(&menu) <= 1080 - CONTEXT_MENU_SCREEN_MARGIN)
	testing.expect_value(t, menu.match_count, 4)
	testing.expect_value(t, menu.items[2].shortcut, "Ctrl+Shift+M")

	// Type "mag" -> narrows directly to "Toggle Magnifier" with exact match bitmask.
	_, _ = context_menu_handle_key(&menu, 0, 'm', true)
	_, _ = context_menu_handle_key(&menu, 0, 'a', true)
	_, _ = context_menu_handle_key(&menu, 0, 'g', true)
	testing.expect_value(t, menu.match_count, 1)
	testing.expect_value(t, menu.items[menu.matches[0].item_index].id, u32(3))
	// "Toggle Magnifier": 'M'=7, 'a'=8, 'g'=9 -> bits 7,8,9 set in match_mask.
	expected_mask := (u64(1) << 7) | (u64(1) << 8) | (u64(1) << 9)
	testing.expect_value(t, menu.matches[0].match_mask, expected_mask)

	// Enter triggers ID 3 and closes menu.
	consumed, triggered := context_menu_handle_key(&menu, display.KEY_ENTER, 0, true)
	testing.expect(t, consumed && triggered == 3 && !menu.open)
}

// A nil menu and a closed menu take nothing and change nothing.
@(test)
context_menu_refuses_nil_and_closed :: proc(t: ^testing.T) {
	context_menu_open(nil, 10, 10, 100, 100, DESKTOP_ITEMS[:])
	context_menu_close(nil)
	context_menu_refilter(nil)
	context_menu_draw(nil, nil)
	consumed, triggered := context_menu_handle_key(nil, display.KEY_ENTER, 0, true)
	testing.expect(t, !consumed && triggered == 0)
	testing.expect_value(t, context_menu_pointer(nil, 0, 0, true), Context_Menu_Pointer_Result{})
	testing.expect(t, !context_menu_contains(nil, 0, 0))
	testing.expect_value(t, context_menu_row_at(nil, 0, 0), -1)
	_, _, _, _, ok := context_menu_row_rect(nil, 0)
	testing.expect(t, !ok)

	menu: Context_Menu_State
	context_menu_open(&menu, 100, 100, 1920, 1080, DESKTOP_ITEMS[:])
	context_menu_close(&menu)
	before := menu
	middle_x, middle_y := row_middle(&menu, 0)
	testing.expect_value(t, context_menu_pointer(&menu, middle_x, middle_y, true), Context_Menu_Pointer_Result{})
	consumed, triggered = context_menu_handle_key(&menu, display.KEY_ENTER, 0, true)
	testing.expect(t, !consumed && triggered == 0)
	testing.expect_value(t, context_menu_row_at(&menu, middle_x, middle_y), -1)
	testing.expect(t, !context_menu_contains(&menu, middle_x, middle_y))
	testing.expect(t, menu == before, "a closed menu changes in no field")

	// A key that is released does nothing on an open menu.
	context_menu_open(&menu, 100, 100, 1920, 1080, DESKTOP_ITEMS[:])
	consumed, _ = context_menu_handle_key(&menu, 0, 'm', false)
	testing.expect(t, !consumed && menu.filter_len == 0)
}

// The pointer over a row chooses it, a press on it triggers its item, and
// a second move over the same row changes nothing.
@(test)
context_menu_pointer_chooses_and_triggers :: proc(t: ^testing.T) {
	menu: Context_Menu_State
	context_menu_open(&menu, 100, 100, 1920, 1080, DESKTOP_ITEMS[:])
	x, y := row_middle(&menu, 2)
	result := context_menu_pointer(&menu, x, y, false)
	testing.expect(t, result.consumed && result.changed && !result.triggered)
	testing.expect_value(t, menu.selected, 2)
	result = context_menu_pointer(&menu, x + 1, y, false)
	testing.expect(t, result.consumed && !result.changed, "the same row again changes nothing")
	x, y = row_middle(&menu, 1)
	result = context_menu_pointer(&menu, x, y, true)
	testing.expect(t, result.consumed && result.changed && result.triggered)
	testing.expect_value(t, result.triggered_id, u32(2))
	testing.expect(t, !menu.open && menu.has_chosen && menu.chosen_id == 2)
}

// A press outside closes the menu and goes on; a move outside changes
// nothing; a press on the filter field or on the foot triggers nothing.
@(test)
context_menu_pointer_outside_and_off_the_rows :: proc(t: ^testing.T) {
	menu: Context_Menu_State
	context_menu_open(&menu, 100, 100, 1920, 1080, DESKTOP_ITEMS[:])
	result := context_menu_pointer(&menu, 99, 100, false)
	testing.expect(t, !result.consumed && !result.changed && menu.open)
	// The filter field, the line under it, and the foot.
	for y in ([?]int{menu.y, menu.y + CONTEXT_MENU_FIELD_MARGIN, menu.y + CONTEXT_MENU_HEADER_HEIGHT - 1, menu.y + context_menu_height(&menu) - 1}) {
		result = context_menu_pointer(&menu, menu.x + 20, y, true)
		testing.expectf(t, result.consumed && !result.triggered && menu.open, "a press at y %v", y)
	}
	result = context_menu_pointer(&menu, menu.x + CONTEXT_MENU_WIDTH, menu.y + CONTEXT_MENU_HEADER_HEIGHT + 2, true)
	testing.expect(t, !result.consumed && result.changed && !result.triggered && !menu.open)
	testing.expect(t, !menu.has_chosen)
}

// The edges of a row: its first and its last pixel are on it, one pixel
// past each edge is on the next row, on the border or on the field.
@(test)
context_menu_row_edges :: proc(t: ^testing.T) {
	menu: Context_Menu_State
	context_menu_open(&menu, 200, 200, 1920, 1080, DESKTOP_ITEMS[:])
	x, y, width, height, ok := context_menu_row_rect(&menu, 0)
	testing.expect(t, ok)
	testing.expect_value(t, context_menu_row_at(&menu, x, y), 0)
	testing.expect_value(t, context_menu_row_at(&menu, x + width - 1, y + height - 1), 0)
	testing.expect_value(t, context_menu_row_at(&menu, x - 1, y), -1)
	testing.expect_value(t, context_menu_row_at(&menu, x + width, y), -1)
	testing.expect_value(t, context_menu_row_at(&menu, x, y - 1), -1)
	testing.expect_value(t, context_menu_row_at(&menu, x, y + height), 1)
	_, last_y, _, last_height, last_ok := context_menu_row_rect(&menu, 3)
	testing.expect(t, last_ok)
	testing.expect_value(t, context_menu_row_at(&menu, x, last_y + last_height), -1)
	for row in ([?]int{-1, 4, CONTEXT_MENU_MAX_ITEMS, max(int)}) {
		_, _, _, _, row_ok := context_menu_row_rect(&menu, row)
		testing.expectf(t, !row_ok, "the row %v is past the matches", row)
	}
}

// A disabled item triggers nothing, by Enter or by a press, and the menu
// stays open.
@(test)
context_menu_disabled_item_triggers_nothing :: proc(t: ^testing.T) {
	items := [2]Context_Menu_Item{{id = 7, label = "Shut Down", disabled = true}, {id = 8, label = "Sleep"}}
	menu: Context_Menu_State
	context_menu_open(&menu, 50, 50, 800, 600, items[:])
	consumed, triggered := context_menu_handle_key(&menu, display.KEY_ENTER, 0, true)
	testing.expect(t, consumed && triggered == 0 && menu.open && !menu.has_chosen)
	x, y := row_middle(&menu, 0)
	result := context_menu_pointer(&menu, x, y, true)
	testing.expect(t, result.consumed && !result.triggered && menu.open && !menu.has_chosen)
}

// The bounds of the filter and of the items: the filter keeps
// CONTEXT_MENU_MAX_FILTER characters and refuses the next one, a control
// character and DEL; the menu keeps CONTEXT_MENU_MAX_ITEMS items.
@(test)
context_menu_bounds :: proc(t: ^testing.T) {
	many: [CONTEXT_MENU_MAX_ITEMS + 1]Context_Menu_Item
	for &item, index in many {
		item = {id = u32(index + 1), label = "aaaa aaaa aaaa aaaa aaaa aaaa aaaa aaaa a"}
	}
	menu: Context_Menu_State
	context_menu_open(&menu, 0, 0, 1920, 1080, many[:])
	testing.expect_value(t, menu.item_count, CONTEXT_MENU_MAX_ITEMS)
	for _ in 0 ..< CONTEXT_MENU_MAX_FILTER {
		_, _ = context_menu_handle_key(&menu, 0, 'a', true)
	}
	testing.expect_value(t, menu.filter_len, CONTEXT_MENU_MAX_FILTER)
	consumed, _ := context_menu_handle_key(&menu, 0, 'a', true)
	testing.expect(t, consumed)
	testing.expect_value(t, menu.filter_len, CONTEXT_MENU_MAX_FILTER)
	context_menu_open(&menu, 0, 0, 1920, 1080, DESKTOP_ITEMS[:])
	for character in ([?]rune{0, 0x1F, 0x7F, 0xE9}) {
		_, _ = context_menu_handle_key(&menu, 0, character, true)
		testing.expectf(t, menu.filter_len == 0 && menu.match_count == 4, "the character %x is no filter", character)
	}
	// Backspace on an empty filter keeps it empty.
	_, _ = context_menu_handle_key(&menu, display.KEY_BACKSPACE, 0, true)
	testing.expect_value(t, menu.filter_len, 0)
}

// A filter that matches nothing: one row of height for the words "No
// match", no row to choose, and Enter, Up and Down trigger nothing.
@(test)
context_menu_no_match :: proc(t: ^testing.T) {
	menu: Context_Menu_State
	context_menu_open(&menu, 300, 300, 1920, 1080, DESKTOP_ITEMS[:])
	for character in "zzq" {
		_, _ = context_menu_handle_key(&menu, 0, character, true)
	}
	testing.expect_value(t, menu.match_count, 0)
	testing.expect_value(t, context_menu_height(&menu), CONTEXT_MENU_HEADER_HEIGHT + CONTEXT_MENU_ROW_HEIGHT + CONTEXT_MENU_FOOT)
	for code in ([?]u32{display.KEY_UP, display.KEY_DOWN, display.KEY_ENTER}) {
		consumed, triggered := context_menu_handle_key(&menu, code, 0, true)
		testing.expect(t, consumed && triggered == 0 && menu.open && menu.selected == 0)
	}
	testing.expect_value(t, context_menu_row_at(&menu, menu.x + 20, menu.y + CONTEXT_MENU_HEADER_HEIGHT + 4), -1)
	// Backspace brings the rows back.
	_, _ = context_menu_handle_key(&menu, display.KEY_BACKSPACE, 0, true)
	_, _ = context_menu_handle_key(&menu, display.KEY_BACKSPACE, 0, true)
	_, _ = context_menu_handle_key(&menu, display.KEY_BACKSPACE, 0, true)
	testing.expect_value(t, menu.match_count, 4)
}

// The place of the card: a point outside the screen, and a screen smaller
// than the card, keep the card at the margin of the screen.
@(test)
context_menu_stays_on_the_screen :: proc(t: ^testing.T) {
	menu: Context_Menu_State
	context_menu_open(&menu, -500, -500, 1920, 1080, DESKTOP_ITEMS[:])
	testing.expect(t, menu.x == CONTEXT_MENU_SCREEN_MARGIN && menu.y == CONTEXT_MENU_SCREEN_MARGIN)
	context_menu_open(&menu, 50, 50, 10, 10, DESKTOP_ITEMS[:])
	testing.expect(t, menu.x == CONTEXT_MENU_SCREEN_MARGIN && menu.y == CONTEXT_MENU_SCREEN_MARGIN)
	context_menu_open(&menu, max(int), max(int), 1920, 1080, DESKTOP_ITEMS[:])
	testing.expect_value(t, menu.x, 1920 - CONTEXT_MENU_WIDTH - CONTEXT_MENU_SCREEN_MARGIN)
	testing.expect_value(t, menu.y, 1080 - context_menu_height(&menu) - CONTEXT_MENU_SCREEN_MARGIN)
	// An empty list of items opens a menu with no row to choose.
	context_menu_open(&menu, 50, 50, 1920, 1080, nil)
	testing.expect(t, menu.open && menu.item_count == 0 && menu.match_count == 0)
	consumed, triggered := context_menu_handle_key(&menu, display.KEY_ENTER, 0, true)
	testing.expect(t, consumed && triggered == 0)
}

// The draw: a full table of records takes the card with its shortcut and
// sets no refusal; with a filter, the matched characters add their lines.
@(test)
context_menu_draws_its_shortcut :: proc(t: ^testing.T) {
	records: [256]Draw_Record
	text: [2048]u8
	table := Draw_Table{records = records[:], text = text[:]}
	menu: Context_Menu_State
	context_menu_open(&menu, 100, 100, 1920, 1080, DESKTOP_ITEMS[:])
	context_menu_draw(&table, &menu)
	testing.expect(t, !table.refused && !table.full)
	testing.expect(t, strings.contains(string(table.text[:table.text_count]), "Ctrl+Shift+M"))
	without_filter := table.record_count
	table = Draw_Table{records = records[:], text = text[:]}
	_, _ = context_menu_handle_key(&menu, 0, 'o', true)
	context_menu_draw(&table, &menu)
	testing.expect(t, !table.refused && !table.full && table.record_count > 0)
	testing.expect(t, table.record_count != without_filter)
	// A closed menu draws nothing.
	table = Draw_Table{records = records[:], text = text[:]}
	context_menu_close(&menu)
	context_menu_draw(&table, &menu)
	testing.expect_value(t, table.record_count, 0)
}
