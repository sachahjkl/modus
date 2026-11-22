// Live desktop shell features integrated into the compositor:
// workspaces, edge-snapping, urgency-badged notifications with balanced
// spacing, viewport magnifier, positionable bar/tray state, and a live
// right-click filterable context menu.
package compositor

import "modus:contract/desktop_layout"
import "modus:contract/desktop_shell"
import "modus:contract/notifications"
import "modus:contract/ring"
import "modus:contract/screen_reader"
import "modus:system"
import "modus:display"
import "modus:graphics"
import "modus:interface"

NOTIFICATION_BANNER_WIDTH :: 296
NOTIFICATION_BANNER_HEIGHT :: 60
NOTIFICATION_BANNER_MARGIN :: 12
NOTIFICATION_BANNER_GAP :: 8
NOTIFICATION_ICON_SIZE :: 22
NOTIFICATION_MAX_VISIBLE :: 4

// Context menu action IDs for desktop right-click menu.
CTX_ACT_NEW_CONSOLE    :: u32(1)
CTX_ACT_OPEN_MONITOR   :: u32(2)
CTX_ACT_OPEN_CLOCK     :: u32(3)
CTX_ACT_TOGGLE_MAG     :: u32(4)
CTX_ACT_RESTORE_ALL    :: u32(5)
CTX_ACT_BAR_TOP        :: u32(6)
CTX_ACT_BAR_BOTTOM     :: u32(7)

desktop_workspaces: desktop_layout.Workspace_Manager
desktop_work_area: desktop_layout.Work_Area
desktop_notifications: notifications.Notification_Queue
desktop_magnifier: screen_reader.Magnifier_State
desktop_bar_position: desktop_shell.Bar_Position = .Top
desktop_tray: desktop_shell.Tray_State
desktop_context_menu: interface.Context_Menu_State
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
	desktop_bar_position = .Top
	desktop_tray = {}
	desktop_shell.tray_set(&desktop_tray, .Locale, true, false, "EN")
	desktop_context_menu = {}
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

// desktop_notifications_records draws urgency-badged rectangular notification
// cards with symmetric top/bottom padding in the top-right corner below the bar.
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
		border_color := graphics.colors.title
		badge_color := graphics.colors.title
		glyph := u8('i')
		switch item.urgency {
		case .Low:
			border_color = graphics.colors.track
			badge_color = graphics.colors.track
			glyph = '-'
		case .Normal:
			border_color = graphics.colors.title
			badge_color = graphics.colors.title
			glyph = 'i'
		case .Critical:
			border_color = graphics.colors.stop_process
			badge_color = graphics.colors.stop_process
			glyph = '!'
		}
		interface.draw_rectangle(table, x, y, NOTIFICATION_BANNER_WIDTH, NOTIFICATION_BANNER_HEIGHT, graphics.colors.card_bottom)
		interface.draw_outline(table, x, y, NOTIFICATION_BANNER_WIDTH, NOTIFICATION_BANNER_HEIGHT, 1, border_color)

		// Left urgency icon badge centered vertically inside the 60px card.
		icon_x := x + 10
		icon_y := y + (NOTIFICATION_BANNER_HEIGHT - NOTIFICATION_ICON_SIZE) / 2
		interface.draw_rectangle(table, icon_x, icon_y, NOTIFICATION_ICON_SIZE, NOTIFICATION_ICON_SIZE, badge_color)
		interface.draw_character(table, icon_x + (NOTIFICATION_ICON_SIZE - graphics.CELL_WIDTH) / 2, icon_y + (NOTIFICATION_ICON_SIZE - graphics.CELL_HEIGHT) / 2, glyph, graphics.COLOR_WHITE)

		// Balanced text block: 11px top margin, 6px gap between title and body, 11px bottom margin.
		text_x := icon_x + NOTIFICATION_ICON_SIZE + 10
		text_room := NOTIFICATION_BANNER_WIDTH - (text_x - x) - 10
		title_str := string(item.title[:item.title_len])
		title_fit := interface.text_fit(table, interface.FONT_INTERFACE, title_str, text_room)
		if item.body_len > 0 {
			interface.draw_text(table, text_x, y + 11, title_fit, graphics.COLOR_WHITE, interface.FONT_INTERFACE)
			body_str := string(item.body[:item.body_len])
			body_fit := interface.text_fit(table, interface.FONT_INTERFACE, body_str, text_room)
			interface.draw_text(table, text_x, y + 33, body_fit, graphics.colors.dim, interface.FONT_INTERFACE)
		} else {
			interface.draw_text(table, text_x, y + (NOTIFICATION_BANNER_HEIGHT - graphics.CELL_HEIGHT) / 2, title_fit, graphics.COLOR_WHITE, interface.FONT_INTERFACE)
		}
		shown += 1
	}
}

// desktop_context_menu_open opens the filterable fuzzy right-click menu at (x, y).
desktop_context_menu_open :: proc "contextless" (x, y: int) {
	if !desktop_features_ready {
		return
	}
	items := [7]interface.Context_Menu_Item{
		{id = CTX_ACT_NEW_CONSOLE, label = "New Console"},
		{id = CTX_ACT_OPEN_MONITOR, label = "Open Monitor"},
		{id = CTX_ACT_OPEN_CLOCK, label = "Open Clock"},
		{id = CTX_ACT_TOGGLE_MAG, label = "Toggle Magnifier"},
		{id = CTX_ACT_RESTORE_ALL, label = "Restore Minimized"},
		{id = CTX_ACT_BAR_TOP, label = "Bar Position Top"},
		{id = CTX_ACT_BAR_BOTTOM, label = "Bar Position Bottom"},
	}
	interface.context_menu_open(&desktop_context_menu, x, y, desktop_width, desktop_height, items[:])
	damage_whole_screen()
}

desktop_context_menu_key :: proc "contextless" (code: u32, character: rune, pressed: bool) -> bool {
	if !desktop_context_menu.open {
		return false
	}
	consumed, act_id := interface.context_menu_handle_key(&desktop_context_menu, code, character, pressed)
	if !consumed {
		return false
	}
	switch act_id {
	case CTX_ACT_NEW_CONSOLE:
		packed := system.name_pack("console")
		system.send(&control.completions, ring.Record{kind = u32(display.Control.Start), values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}})
	case CTX_ACT_OPEN_MONITOR:
		packed := system.name_pack("monitor")
		system.send(&control.completions, ring.Record{kind = u32(display.Control.Start), values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}})
	case CTX_ACT_OPEN_CLOCK:
		packed := system.name_pack("clock")
		system.send(&control.completions, ring.Record{kind = u32(display.Control.Start), values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}})
	case CTX_ACT_TOGGLE_MAG:
		desktop_magnifier_toggle(i32(pointer_x), i32(pointer_y))
	case CTX_ACT_RESTORE_ALL:
		for &c in clients {
			if c.created && c.minimized {
				c.minimized = false
			}
		}
	case CTX_ACT_BAR_TOP:
		desktop_bar_position = .Top
	case CTX_ACT_BAR_BOTTOM:
		desktop_bar_position = .Bottom
	}
	damage_whole_screen()
	return true
}

desktop_context_menu_records :: proc "contextless" (table: ^interface.Draw_Table) {
	if desktop_context_menu.open {
		interface.context_menu_draw(table, &desktop_context_menu)
	}
}

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

desktop_toggle_maximize :: proc "contextless" (client: ^Client) {
	if client == nil {
		return
	}
	damage_window(client)
	if !client.maximized {
		client.saved_x = client.x
		client.saved_y = client.y
		client.maximized = true
		client.x = 0
		client.y = BAR_HEIGHT
	} else {
		client.maximized = false
		client.x = client.saved_x
		client.y = client.saved_y
	}
	damage_whole_screen()
}

desktop_toggle_minimize :: proc "contextless" (client: ^Client) {
	if client == nil {
		return
	}
	client.minimized = !client.minimized
	damage_whole_screen()
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
