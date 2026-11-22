// Live desktop workspace switching, edge-snapping, notification banner
// rendering, and viewport magnifier zoom integrated directly into the
// compositor event loop and frame draw pass.
package compositor

import "modus:contract/desktop_layout"
import "modus:contract/notifications"
import "modus:contract/screen_reader"
import "modus:display"
import "modus:graphics"
import "modus:interface"

NOTIFICATION_BANNER_WIDTH :: 280
NOTIFICATION_BANNER_HEIGHT :: 54
NOTIFICATION_BANNER_MARGIN :: 10
NOTIFICATION_BANNER_GAP :: 6
NOTIFICATION_MAX_VISIBLE :: 4

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
	if notifications.queue_expire(&desktop_notifications, now_ns / 1_000_000) > 0 {
		desktop_damage_notifications()
	}
}

desktop_damage_notifications :: proc "contextless" () {
	x := max(0, desktop_width - NOTIFICATION_BANNER_WIDTH - NOTIFICATION_BANNER_MARGIN - 2)
	h := NOTIFICATION_MAX_VISIBLE * (NOTIFICATION_BANNER_HEIGHT + NOTIFICATION_BANNER_GAP) + NOTIFICATION_BANNER_MARGIN * 2
	damage_add(x, BAR_HEIGHT, desktop_width - x, min(h, max(0, desktop_height - BAR_HEIGHT)))
}

// desktop_notifications_records appends non-focus-stealing rectangular banner
// cards for active notifications in the top-right corner below the bar.
desktop_notifications_records :: proc "contextless" (table: ^interface.Draw_Table) {
	if !desktop_features_ready {
		return
	}
	shown := 0
	x := max(0, desktop_width - NOTIFICATION_BANNER_WIDTH - NOTIFICATION_BANNER_MARGIN)
	for &item in desktop_notifications.items {
		if !item.active {
			continue
		}
		if shown >= NOTIFICATION_MAX_VISIBLE {
			break
		}
		y := BAR_HEIGHT + NOTIFICATION_BANNER_MARGIN + shown * (NOTIFICATION_BANNER_HEIGHT + NOTIFICATION_BANNER_GAP)
		border_color := item.urgency == .Critical ? graphics.colors.stop_process : graphics.colors.title
		interface.draw_rectangle(table, x, y, NOTIFICATION_BANNER_WIDTH, NOTIFICATION_BANNER_HEIGHT, graphics.colors.card_bottom)
		interface.draw_outline(table, x, y, NOTIFICATION_BANNER_WIDTH, NOTIFICATION_BANNER_HEIGHT, 1, border_color)
		title_str := string(item.title[:item.title_len])
		title_fit := interface.text_fit(table, interface.FONT_INTERFACE, title_str, NOTIFICATION_BANNER_WIDTH - 16)
		interface.draw_text(table, x + 8, y + 6, title_fit, graphics.COLOR_WHITE, interface.FONT_INTERFACE)
		if item.body_len > 0 {
			body_str := string(item.body[:item.body_len])
			body_fit := interface.text_fit(table, interface.FONT_INTERFACE, body_str, NOTIFICATION_BANNER_WIDTH - 16)
			interface.draw_text(table, x + 8, y + 26, body_fit, graphics.colors.dim, interface.FONT_INTERFACE)
		}
		shown += 1
	}
}

// desktop_magnifier_sample reads a magnified pixel from frame for screen
// destination coordinates (dst_x, dst_y), applying the active filter mode.
desktop_magnifier_sample :: proc "contextless" (dst_x, dst_y: int) -> graphics.Color {
	zoom := max(i32(12), i32(desktop_magnifier.zoom_eighths))
	src_x := clamp(int(desktop_magnifier.view_x) + (dst_x * 8) / int(zoom), 0, max(0, frame.width - 1))
	src_y := clamp(int(desktop_magnifier.view_y) + (dst_y * 8) / int(zoom), 0, max(0, frame.height - 1))
	color := frame.pixels[src_y * frame.stride + src_x]
	switch desktop_magnifier.filter {
	case .Normal:
		return color
	case .Inverted:
		return (^graphics.Color)(&color)^ ~ 0x00FF_FFFF
	case .High_Contrast:
		r := (color >> 16) & 0xFF
		g := (color >> 8) & 0xFF
		b := color & 0xFF
		luma := (r * 3 + g * 6 + b) / 10
		return luma >= 96 ? graphics.COLOR_WHITE : graphics.Color(0x0000_0000)
	}
	return color
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

desktop_magnifier_set :: proc "contextless" (zoom_eighths: u16, tx, ty: i32) -> bool {
	if !desktop_features_ready {
		return false
	}
	if zoom_eighths == 0 {
		desktop_magnifier.enabled = false
		damage_whole_screen()
		return true
	}
	if zoom_eighths < 12 || zoom_eighths > 64 {
		return false
	}
	desktop_magnifier.zoom_eighths = zoom_eighths
	desktop_magnifier.enabled = true
	screen_reader.magnifier_focus_on(&desktop_magnifier, tx, ty)
	damage_whole_screen()
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
	before_x, before_y := desktop_magnifier.view_x, desktop_magnifier.view_y
	screen_reader.magnifier_focus_on(&desktop_magnifier, tx, ty)
	if desktop_magnifier.view_x != before_x || desktop_magnifier.view_y != before_y {
		damage_whole_screen()
	}
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
	if refusal == .None {
		desktop_damage_notifications()
		return id
	}
	return 0
}
