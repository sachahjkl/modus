#+build !freestanding
package desktop_shell

import "core:testing"

@(test)
bar_positions_grouping_csd_and_system_tray :: proc(t: ^testing.T) {
	_, bad_p := bar_position_of_word(99)
	testing.expect(t, !bad_p)
	_, bad_d := window_decoration_of_word(99)
	testing.expect(t, !bad_d)
	_, bad_t := tray_icon_kind_of_word(99)
	testing.expect(t, !bad_t)

	// Bottom bar reserves bottom 32px; Left bar reserves left 48px.
	bb, bw, bok := bar_and_work_rects(1920, 1080, .Bottom)
	testing.expect(t, bok)
	testing.expect_value(t, bb, Shell_Rect{0, 1048, 1920, 32})
	testing.expect_value(t, bw, Shell_Rect{0, 0, 1920, 1048})

	lb, lw, lok := bar_and_work_rects(1920, 1080, .Left)
	testing.expect(t, lok)
	testing.expect_value(t, lb, Shell_Rect{0, 0, 48, 1080})
	testing.expect_value(t, lw, Shell_Rect{48, 0, 1872, 1080})

	// Two terminal windows (1 minimized, 1 focused) + 1 console -> 2 taskbar groups.
	wins := [3]Window_Entry{
		{window_id = 1, module_key = 0xAA, focused = false, minimized = true},
		{window_id = 2, module_key = 0xAA, focused = true, minimized = false},
		{window_id = 3, module_key = 0xBB, focused = false, minimized = false},
	}
	groups: [8]Taskbar_Group
	gn := taskbar_group_windows(wins[:], groups[:])
	testing.expect_value(t, gn, 2)
	testing.expect_value(t, groups[0].total_count, u16(2))
	testing.expect_value(t, groups[0].minimized_count, u16(1))
	testing.expect(t, groups[0].has_focus)

	// System tray updates and clears cleanly.
	tray: Tray_State
	tray_set(&tray, .Locale, true, false, "FR")
	tray_set(&tray, .Wide_Grant, true, true, "AGNT")
	testing.expect(t, tray.entries[0].active && string(tray.entries[0].label[:tray.entries[0].len]) == "FR")
	testing.expect(t, tray.entries[1].active && tray.entries[1].alert)
	tray_set(&tray, .Wide_Grant, false, false, "")
	testing.expect(t, !tray.entries[1].active)
}
