// Live desktop workspace switching, edge-snapping, notification queue, and
// viewport magnifier state integrated directly into the compositor event loop.
package compositor

import "modus:contract/desktop_layout"
import "modus:contract/notifications"
import "modus:contract/screen_reader"
import "modus:display"

desktop_workspaces: desktop_layout.Workspace_Manager
desktop_work_area: desktop_layout.Work_Area
desktop_notifications: notifications.Notification_Queue
desktop_magnifier: screen_reader.Magnifier_State
desktop_features_ready: bool

desktop_features_init :: proc "contextless" (screen_w, screen_h, bar_h: i32) {
	desktop_work_area = desktop_layout.Work_Area{
		screen_width  = screen_w,
		screen_height = screen_h,
		bar_height    = bar_h,
	}
	_ = desktop_layout.workspace_manager_init(&desktop_workspaces)
	notifications.queue_init(&desktop_notifications, min_interval_ms = 500)
	_ = screen_reader.magnifier_init(&desktop_magnifier, screen_w, screen_h, 16)
	desktop_magnifier.enabled = false
	desktop_features_ready = true
}

desktop_features_resize :: proc "contextless" (screen_w, screen_h, bar_h: i32) {
	if !desktop_features_ready {
		desktop_features_init(screen_w, screen_h, bar_h)
		return
	}
	desktop_work_area = desktop_layout.Work_Area{
		screen_width  = screen_w,
		screen_height = screen_h,
		bar_height    = bar_h,
	}
	desktop_magnifier.screen_w = screen_w
	desktop_magnifier.screen_h = screen_h
}

desktop_window_opened :: proc "contextless" (index: int) {
	if !desktop_features_ready || index < 0 {
		return
	}
	_ = desktop_layout.workspace_add_window(&desktop_workspaces, u64(index + 1), desktop_workspaces.active_index)
}

desktop_window_closed :: proc "contextless" (index: int) {
	if !desktop_features_ready || index < 0 {
		return
	}
	_ = desktop_layout.workspace_remove_window(&desktop_workspaces, u64(index + 1))
}

desktop_features_tick :: proc "contextless" (now_ns: u64) {
	if !desktop_features_ready {
		return
	}
	_ = notifications.queue_expire(&desktop_notifications, now_ns / 1_000_000)
}

desktop_workspace_select :: proc "contextless" (index: u8) -> bool {
	if !desktop_features_ready {
		return false
	}
	focused_id, refusal := desktop_layout.workspace_switch(&desktop_workspaces, index)
	if refusal != .None {
		return false
	}
	if focused_id > 0 {
		target := int(focused_id - 1)
		for position in 0 ..< order_count {
			if order[position] == target {
				raise(position)
				break
			}
		}
	}
	damage_whole_screen()
	return true
}

desktop_snap_front_window :: proc "contextless" (zone: desktop_layout.Snap_Zone) -> bool {
	if !desktop_features_ready || order_count == 0 {
		return false
	}
	rect, ok := desktop_layout.snap_zone_rect(desktop_work_area, zone)
	if !ok {
		return false
	}
	idx := order[order_count - 1]
	client := &clients[idx]
	damage_window(client)
	client.x = int(rect.x)
	client.y = int(rect.y)
	damage_window(client)
	return true
}

desktop_magnifier_toggle :: proc "contextless" (tx, ty: i32) {
	if !desktop_features_ready {
		return
	}
	desktop_magnifier.enabled = !desktop_magnifier.enabled
	if desktop_magnifier.enabled {
		screen_reader.magnifier_focus_on(&desktop_magnifier, tx, ty)
	}
	damage_whole_screen()
}

desktop_magnifier_track :: proc "contextless" (tx, ty: i32) {
	if !desktop_features_ready || !desktop_magnifier.enabled {
		return
	}
	screen_reader.magnifier_focus_on(&desktop_magnifier, tx, ty)
}

// desktop_shortcut_key handles Ctrl+Shift desktop shell bindings (workspaces
// 1..4, edge snapping Left/Right/Up, and viewport magnifier toggle M).
desktop_shortcut_key :: proc "contextless" (code: u32, character: rune, pressed: bool, modifiers: u32) -> bool {
	if !desktop_features_ready || !pressed {
		return false
	}
	ctrl_shift := u32(display.MODIFIER_CONTROL | display.MODIFIER_SHIFT)
	if (modifiers & ctrl_shift) != ctrl_shift {
		return false
	}
	switch code {
	case display.KEY_LEFT:
		return desktop_snap_front_window(.Left_Half)
	case display.KEY_RIGHT:
		return desktop_snap_front_window(.Right_Half)
	case display.KEY_UP:
		return desktop_snap_front_window(.Maximized)
	}
	switch character {
	case '1', '!':
		return desktop_workspace_select(0)
	case '2', '@':
		return desktop_workspace_select(1)
	case '3', '#':
		return desktop_workspace_select(2)
	case '4', '$':
		return desktop_workspace_select(3)
	case 'm', 'M':
		desktop_magnifier_toggle(i32(pointer_x), i32(pointer_y))
		return true
	}
	return false
}

desktop_notification_post :: proc "contextless" (source_id: u64, urgency: notifications.Urgency, now_ms: u64, title, body: []u8) -> u64 {
	if !desktop_features_ready {
		return 0
	}
	id, refusal := notifications.queue_post(&desktop_notifications, source_id, urgency, now_ms, 8_000, title, body)
	return refusal == .None ? id : 0
}
