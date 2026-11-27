#+build !freestanding
#+build !modus
package interface

import "core:testing"
import "modus:display"

@(test)
command_palette_filters_navigates_and_triggers :: proc(t: ^testing.T) {
	items := [?]Command_Palette_Item{
		{id = 1, label = "Jump to bottom", category = "View"},
		{id = 2, label = "Scroll to top", category = "View"},
		{id = 3, label = "Clear history", category = "Edit", danger = true},
		{id = 4, label = "Disabled action", category = "View", disabled = true},
		{id = 5, label = "Inspect network", category = "System"},
	}
	p: Command_Palette_State

	// Closed and nil refusals.
	consumed, id := command_palette_handle_key(nil, display.KEY_ENTER, 0, true)
	testing.expect(t, !consumed && id == 0)
	consumed, id = command_palette_handle_key(&p, display.KEY_ENTER, 0, true)
	testing.expect(t, !consumed && id == 0)
	testing.expect(t, !command_palette_pointer(&p, 100, 100, true, 0, 800, 600).consumed)

	// Shortcut detection: Ctrl+K and Ctrl+Shift+P only; shift-only excludes Ctrl+K.
	testing.expect(t, is_command_palette_shortcut(0, 'k', display.MODIFIER_CONTROL))
	testing.expect(t, is_command_palette_shortcut(0, 'P', display.MODIFIER_CONTROL | display.MODIFIER_SHIFT))
	testing.expect(t, !is_command_palette_shortcut(0, 'k', 0))
	testing.expect(t, !is_command_palette_shortcut(0, 'k', display.MODIFIER_CONTROL | display.MODIFIER_ALT))
	testing.expect(t, !is_command_palette_shortcut(0, 'p', display.MODIFIER_CONTROL))
	testing.expect(t, is_command_palette_shift_shortcut(0, 'P', display.MODIFIER_CONTROL | display.MODIFIER_SHIFT))
	testing.expect(t, !is_command_palette_shift_shortcut(0, 'k', display.MODIFIER_CONTROL))

	// Open, verify key release (pressed=false) and Ctrl/Alt-modified keys do not type into filter.
	command_palette_open(&p, "Commands", items[:], 600)
	testing.expect(t, p.open && p.match_count == 5)
	consumed, _ = command_palette_handle_key(&p, 0, 'x', false)
	testing.expect(t, !consumed && p.filter_len == 0)
	_, _ = command_palette_handle_key(&p, 0, 'k', true, display.MODIFIER_CONTROL, 600)
	_, _ = command_palette_handle_key(&p, 0, 'P', true, display.MODIFIER_CONTROL | display.MODIFIER_SHIFT, 600)
	_, _ = command_palette_handle_key(&p, 0, 'a', true, display.MODIFIER_ALT, 600)
	// Control and non-ASCII runes do not enter the filter.
	_, _ = command_palette_handle_key(&p, 0, '\t', true, 0, 600)
	_, _ = command_palette_handle_key(&p, 0, 0x00E9, true, 0, 600)
	testing.expect_value(t, p.filter_len, 0)

	// Label match ranks ahead of category-only match ("sys" matches category "System" only;
	// add an item whose label contains "sys" to verify label > category ranking).
	rank_items := [?]Command_Palette_Item{
		{id = 10, label = "Alpha", category = "System"},
		{id = 11, label = "System info", category = "Tools"},
	}
	command_palette_open(&p, "Rank", rank_items[:], 600)
	_, _ = command_palette_handle_key(&p, 0, 's', true, 0, 600)
	_, _ = command_palette_handle_key(&p, 0, 'y', true, 0, 600)
	_, _ = command_palette_handle_key(&p, 0, 's', true, 0, 600)
	testing.expect_value(t, p.match_count, 2)
	testing.expect_value(t, p.items[p.matches[0].item_index].id, u32(11))
	testing.expect_value(t, p.items[p.matches[1].item_index].id, u32(10))

	// Fuzzy subsequence ("clr" -> Clear history) and Enter trigger.
	command_palette_open(&p, "Commands", items[:], 600)
	_, _ = command_palette_handle_key(&p, 0, 'c', true, 0, 600)
	_, _ = command_palette_handle_key(&p, 0, 'l', true, 0, 600)
	_, _ = command_palette_handle_key(&p, 0, 'r', true, 0, 600)
	testing.expect_value(t, p.match_count, 1)
	testing.expect_value(t, p.items[p.matches[0].item_index].id, u32(3))
	consumed, id = command_palette_handle_key(&p, display.KEY_ENTER, 0, true, 0, 600)
	testing.expect(t, consumed && id == 3 && !p.open)

	// Disabled item refuses Enter and pointer press; clicking outside closes.
	command_palette_open(&p, "Commands", items[:], 600)
	p.selected = 3
	consumed, id = command_palette_handle_key(&p, display.KEY_ENTER, 0, true, 0, 600)
	testing.expect(t, consumed && id == 0 && p.open)
	res := command_palette_pointer(&p, 2, 2, true, 0, 800, 600)
	testing.expect(t, res.consumed && res.changed && !res.triggered && !p.open)
}

@(test)
command_palette_bounds_short_window_and_overflow :: proc(t: ^testing.T) {
	many: [COMMAND_PALETTE_MAX_ITEMS + 4]Command_Palette_Item
	for i in 0 ..< len(many) {
		many[i] = {id = u32(i + 1), label = "Item"}
	}
	p: Command_Palette_State
	// Short window (win_h = 160 -> capacity 2 rows) caps item count at COMMAND_PALETTE_MAX_ITEMS.
	command_palette_open(&p, "Many", many[:], 160)
	testing.expect_value(t, p.item_count, COMMAND_PALETTE_MAX_ITEMS)
	testing.expect_value(t, p.visible_rows, 2)

	// Narrowing filter to 0 matches and backspacing must keep row capacity 2 intact.
	_, _ = command_palette_handle_key(&p, 0, 'z', true, 0, 160)
	testing.expect_value(t, p.match_count, 0)
	testing.expect_value(t, p.visible_rows, 2)
	_, _ = command_palette_handle_key(&p, display.KEY_BACKSPACE, 0, true, 0, 0)
	testing.expect_value(t, p.match_count, COMMAND_PALETTE_MAX_ITEMS)
	testing.expect_value(t, p.visible_rows, 2)

	// Pressing Down past visible_rows advances first_row so selected stays visible.
	for _ in 0 ..< 5 {
		_, _ = command_palette_handle_key(&p, display.KEY_DOWN, 0, true, 0, 160)
	}
	testing.expect(t, p.selected == 5)
	testing.expect(t, p.selected >= p.first_row && p.selected < p.first_row + p.visible_rows)

	// Filter stops cleanly at COMMAND_PALETTE_MAX_FILTER.
	for _ in 0 ..< COMMAND_PALETTE_MAX_FILTER + 8 {
		_, _ = command_palette_handle_key(&p, 0, 'i', true, 0, 160)
	}
	testing.expect_value(t, p.filter_len, COMMAND_PALETTE_MAX_FILTER)

	// Extreme wheel delta does not overflow int.
	command_palette_open(&p, "Many", many[:], 160)
	card := command_palette_card_rect(&p, 400, 160)
	_ = command_palette_pointer(&p, card.x + 20, card.y + 50, false, max(int), 400, 160)
	testing.expect(t, p.first_row >= 0 && p.first_row <= p.match_count - 1)
	_ = command_palette_pointer(&p, card.x + 20, card.y + 50, false, min(int) + 1, 400, 160)
	testing.expect_value(t, p.first_row, 0)

	// Narrow and degenerate windows (0, negative, 20 px) never emit negative-width draw records.
	records: [128]Draw_Record
	text_buf: [1024]u8
	table := Draw_Table{records = records[:], text = text_buf[:]}
	command_palette_draw(&table, &p, 0, 0)
	testing.expect_value(t, table.record_count, 0)
	command_palette_draw(&table, &p, -50, -50)
	testing.expect_value(t, table.record_count, 0)
	command_palette_draw(&table, &p, 24, 160)
	testing.expect_value(t, table.record_count, 0)
	command_palette_draw(&table, &p, 200, 160)
	testing.expect(t, table.record_count > 0)
	for rec in table.records[:table.record_count] {
		testing.expect(t, rec.right >= rec.left && rec.bottom >= rec.top)
	}
}

@(test)
compact_context_menu_and_right_click_input :: proc(t: ^testing.T) {
	// Row 0 separator_before is suppressed; row 1 separator_before adds spacing.
	cm: Context_Menu_State
	cm_items := [?]Context_Menu_Item{
		{id = 10, label = "Maximize", shortcut = "Ctrl+Shift+Up", separator_before = true},
		{id = 11, label = "Disabled", disabled = true},
		{id = 12, label = "Close", danger = true, separator_before = true},
	}
	context_menu_open_compact(&cm, 100, 100, 800, 600, cm_items[:])
	testing.expect(t, cm.open && cm.compact && cm.match_count == 3)
	testing.expect(t, context_menu_row_enabled(&cm, 0))
	testing.expect(t, !context_menu_row_enabled(&cm, 1))
	testing.expect(t, context_menu_row_enabled(&cm, 2))
	_, y0, _, h0, ok0 := context_menu_row_rect(&cm, 0)
	_, y1, _, h1, ok1 := context_menu_row_rect(&cm, 1)
	_, y2, _, _, ok2 := context_menu_row_rect(&cm, 2)
	testing.expect(t, ok0 && ok1 && ok2)
	testing.expect_value(t, y0, cm.y + CONTEXT_MENU_COMPACT_HEAD)
	testing.expect_value(t, y1, y0 + h0)
	testing.expect_value(t, y2, y1 + h1 + CONTEXT_MENU_SEPARATOR_HEIGHT)

	// Compact mode ignores printable keys and Ctrl-modified keys.
	_, _ = context_menu_handle_key(&cm, 0, 'z', true, 0)
	testing.expect_value(t, cm.match_count, 3)

	// Non-compact menu ignores Ctrl/Alt-modified keys so shortcuts never enter filter.
	full: Context_Menu_State
	context_menu_open(&full, 50, 50, 800, 600, cm_items[:])
	_, _ = context_menu_handle_key(&full, 0, 'c', true, display.MODIFIER_CONTROL)
	_, _ = context_menu_handle_key(&full, 0, 'x', true, display.MODIFIER_ALT)
	testing.expect_value(t, full.filter_len, 0)

	// Input tracks BUTTON_RIGHT edges and press coordinates, and clears edges on input_clear.
	inp: Input
	_ = input_add(&inp, {kind = .Pointer, x = 42, y = 77, buttons = display.BUTTON_RIGHT})
	testing.expect(t, inp.right_pressed && inp.right_held && !inp.right_released)
	testing.expect(t, inp.right_press_x == 42 && inp.right_press_y == 77)
	input_clear(&inp)
	testing.expect(t, !inp.right_pressed && inp.right_held && !inp.right_released)
	_ = input_add(&inp, {kind = .Pointer, x = 50, y = 80, buttons = 0})
	testing.expect(t, !inp.right_pressed && !inp.right_held && inp.right_released)
}
