#+build !freestanding
package interface

import "core:testing"
import "modus:display"

@(test)
context_menu_fuzzy_filters_highlights_and_triggers :: proc(t: ^testing.T) {
	items := [4]Context_Menu_Item{
		{id = 1, label = "New Console"},
		{id = 2, label = "Open Monitor"},
		{id = 3, label = "Toggle Magnifier"},
		{id = 4, label = "Move Bar Bottom"},
	}
	menu: Context_Menu_State
	context_menu_open(&menu, 1800, 1000, 1920, 1080, items[:])
	testing.expect(t, menu.open)
	// Clamped inside screen bounds.
	testing.expect(t, menu.x + CONTEXT_MENU_WIDTH <= 1920)
	testing.expect_value(t, menu.match_count, 4)

	// Type "mag" -> narrows directly to "Toggle Magnifier" with exact match bitmask!
	_, _ = context_menu_handle_key(&menu, 0, 'm', true)
	_, _ = context_menu_handle_key(&menu, 0, 'a', true)
	_, _ = context_menu_handle_key(&menu, 0, 'g', true)
	testing.expect_value(t, menu.match_count, 1)
	testing.expect_value(t, menu.items[menu.matches[0].item_index].id, u32(3))
	// "Toggle Magnifier": 'M'=7, 'a'=8, 'g'=9 -> bits 7,8,9 set in match_mask!
	expected_mask := (u64(1) << 7) | (u64(1) << 8) | (u64(1) << 9)
	testing.expect_value(t, menu.matches[0].match_mask, expected_mask)

	// Enter triggers ID 3 and closes menu.
	consumed, triggered := context_menu_handle_key(&menu, display.KEY_ENTER, 0, true)
	testing.expect(t, consumed && triggered == 3 && !menu.open)
}
