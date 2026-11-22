// Live desktop shell features integrated into the compositor:
// workspaces, edge-snapping, urgency-badged notifications with balanced
// spacing, viewport magnifier, positionable bar/tray state, and a live
// right-click filterable context menu.
package compositor

import "modus:contract/desktop_layout"
import "modus:contract/enum_word"
import "modus:contract/desktop_shell"
import "modus:contract/notifications"
import "modus:contract/ring"
import "modus:contract/screen_reader"
import "modus:system"
import "modus:display"
import "modus:graphics"
import "modus:interface"

NOTIFICATION_BANNER_WIDTH :: 312
NOTIFICATION_BANNER_HEIGHT :: 62
NOTIFICATION_BANNER_MARGIN :: 12
NOTIFICATION_BANNER_GAP :: 8
NOTIFICATION_RAIL_WIDTH :: 3
NOTIFICATION_MAX_VISIBLE :: 4

// Closed set of actions offered by the desktop right-click context menu.
Desktop_Context_Action :: enum u32 {
	None        = 0,
	New_Console = 1,
	Open_Monitor = 2,
	Open_Clock  = 3,
	Toggle_Mag  = 4,
	Restore_All = 5,
	Bar_Top     = 6,
	Bar_Bottom  = 7,
}

desktop_workspaces: desktop_layout.Workspace_Manager
desktop_work_area: desktop_layout.Work_Area
desktop_notifications: notifications.Notification_Queue
desktop_magnifier: screen_reader.Magnifier_State
desktop_bar_position: desktop_shell.Bar_Position = .Top
desktop_tray: desktop_shell.Tray_State
desktop_context_menu: interface.Context_Menu_State
desktop_features_ready: bool

// desktop_bar_y returns the top pixel Y coordinate of the horizontal bar
// (0 for Top, desktop_height - BAR_HEIGHT for Bottom).
desktop_bar_y :: proc "contextless" () -> int {
	if desktop_bar_position == .Bottom && desktop_height > BAR_HEIGHT {
		return desktop_height - BAR_HEIGHT
	}
	return 0
}

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
	damage_add(0, desktop_bar_y(), desktop_width, BAR_HEIGHT)
}

desktop_window_closed :: proc "contextless" (index: int) {
	if !desktop_features_ready || index < 0 {
		return
	}
	_ = desktop_layout.workspace_remove_window(&desktop_workspaces, u64(index + 1))
	damage_add(0, desktop_bar_y(), desktop_width, BAR_HEIGHT)
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
		rail_color := graphics.colors.title
		switch item.urgency {
		case .Low:
			rail_color = graphics.colors.dim
		case .Normal:
			rail_color = graphics.colors.title
		case .Critical:
			rail_color = graphics.colors.stop_process
		}
		// Kernel-theme card plate: subtle vertical gradient, 1px specular top edge, clean dark border.
		interface.draw_vertical_gradient(table, x, y, NOTIFICATION_BANNER_WIDTH, NOTIFICATION_BANNER_HEIGHT, graphics.colors.card_top, graphics.colors.card_bottom)
		interface.draw_outline(table, x, y, NOTIFICATION_BANNER_WIDTH, NOTIFICATION_BANNER_HEIGHT, 1, graphics.colors.track)
		interface.draw_rectangle(table, x + 1, y + 1, NOTIFICATION_BANNER_WIDTH - 2, 1, graphics.shade(graphics.colors.card_top, 125))
		// Crisp 3px urgency accent rail (matching Kernel theme Control Panel / Notifications).
		interface.draw_rectangle(table, x + 11, y + 12, NOTIFICATION_RAIL_WIDTH, NOTIFICATION_BANNER_HEIGHT - 24, rail_color)

		text_x := x + 24
		text_room := NOTIFICATION_BANNER_WIDTH - 36
		title_str := string(item.title[:item.title_len])
		title_fit := interface.text_fit(table, interface.FONT_INTERFACE, title_str, text_room)
		if item.body_len > 0 {
			interface.draw_text(table, text_x, y + 12, title_fit, graphics.COLOR_WHITE, interface.FONT_INTERFACE)
			body_str := string(item.body[:item.body_len])
			body_fit := interface.text_fit(table, interface.FONT_INTERFACE, body_str, text_room)
			interface.draw_text(table, text_x, y + 34, body_fit, graphics.colors.dim, interface.FONT_INTERFACE)
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
		{id = u32(Desktop_Context_Action.New_Console), label = "New Console"},
		{id = u32(Desktop_Context_Action.Open_Monitor), label = "Open Monitor"},
		{id = u32(Desktop_Context_Action.Open_Clock), label = "Open Clock"},
		{id = u32(Desktop_Context_Action.Toggle_Mag), label = "Toggle Magnifier"},
		{id = u32(Desktop_Context_Action.Restore_All), label = "Restore Minimized"},
		{id = u32(Desktop_Context_Action.Bar_Top), label = "Bar Position Top"},
		{id = u32(Desktop_Context_Action.Bar_Bottom), label = "Bar Position Bottom"},
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
	if action, ok := enum_word.member_of_word(Desktop_Context_Action, u64(act_id)); ok {
		switch action {
		case .None:
		case .New_Console:
			packed := system.name_pack("console")
			system.send(&control.completions, ring.Record{kind = u32(display.Control.Start), values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}})
		case .Open_Monitor:
			packed := system.name_pack("monitor")
			system.send(&control.completions, ring.Record{kind = u32(display.Control.Start), values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}})
		case .Open_Clock:
			packed := system.name_pack("clock")
			system.send(&control.completions, ring.Record{kind = u32(display.Control.Start), values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}})
		case .Toggle_Mag:
			desktop_magnifier_toggle(i32(pointer_x), i32(pointer_y))
		case .Restore_All:
			for &c in clients {
				if c.created && c.minimized {
					c.minimized = false
				}
			}
		case .Bar_Top:
			desktop_bar_position = .Top
		case .Bar_Bottom:
			desktop_bar_position = .Bottom
		}
	}
	damage_whole_screen()
	return true
}

TASKBAR_PILL_START_X :: 224
TASKBAR_PILL_WIDTH :: 136
TASKBAR_PILL_GAP :: 4
TRAY_BADGE_WIDTH :: 34
TRAY_BADGE_GAP :: 4

// desktop_taskbar_and_tray_records draws live taskbar window pills (highlighting
// focused windows, dimming minimized ones, showing module window counts when
// grouped) and system tray badges directly inside the top bar.
desktop_taskbar_and_tray_records :: proc "contextless" (table: ^interface.Draw_Table) {
	if !desktop_features_ready {
		return
	}
	// 1. Kernel-theme taskbar window plates after a crisp vertical hairline divider.
	bar_top := desktop_bar_y()
	interface.draw_rectangle(table, TASKBAR_PILL_START_X - 10, bar_top + 6, 1, BAR_HEIGHT - 12, graphics.colors.track)
	max_right := max(TASKBAR_PILL_START_X, desktop_width - CLOCK_WIDTH - 240)
	px := TASKBAR_PILL_START_X
	for position in 0 ..< order_count {
		if px + TASKBAR_PILL_WIDTH > max_right {
			break
		}
		idx := order[position]
		client := &clients[idx]
		if !client.created {
			continue
		}
		name := system.name_of(client.title[:])
		// Deduplicate by title so multiple windows of the same module group cleanly into one pill.
		already := false
		same_count := 0
		any_focus := false
		all_minimized := true
		for p2 in 0 ..< order_count {
			c2 := &clients[order[p2]]
			if !c2.created || system.name_of(c2.title[:]) != name {
				continue
			}
			if p2 < position {
				already = true
				break
			}
			same_count += 1
			if p2 == order_count - 1 && !c2.minimized {
				any_focus = true
			}
			if !c2.minimized {
				all_minimized = false
			}
		}
		if already {
			continue
		}
		by := desktop_bar_y()
		hovered := inside(pointer_x, pointer_y, px, by, TASKBAR_PILL_WIDTH, BAR_HEIGHT) && menu_open == .None
		pill_fg := any_focus ? graphics.COLOR_WHITE : (all_minimized ? graphics.colors.dim : graphics.colors.text)
		if any_focus {
			// Focused window plate: beveled steel gradient, 1px specular top highlight, crisp 2px bottom accent line.
			interface.draw_vertical_gradient(table, px, by + 2, TASKBAR_PILL_WIDTH, BAR_HEIGHT - 4, graphics.shade(graphics.colors.card_top, 135), graphics.shade(graphics.colors.card_bottom, 120))
			interface.draw_outline(table, px, by + 2, TASKBAR_PILL_WIDTH, BAR_HEIGHT - 4, 1, graphics.shade(graphics.colors.track, 130))
			interface.draw_rectangle(table, px + 1, by + 3, TASKBAR_PILL_WIDTH - 2, 1, graphics.shade(graphics.colors.card_top, 155))
			interface.draw_rectangle(table, px + 1, by + BAR_HEIGHT - 4, TASKBAR_PILL_WIDTH - 2, 2, graphics.colors.title)
		} else if !all_minimized || hovered {
			// Open/hovered inactive plate: quiet recessed steel plate with hairline border.
			top_c := hovered ? graphics.shade(graphics.colors.card_top, 120) : graphics.colors.card_top
			bot_c := hovered ? graphics.shade(graphics.colors.card_bottom, 110) : graphics.colors.card_bottom
			interface.draw_vertical_gradient(table, px, by + 2, TASKBAR_PILL_WIDTH, BAR_HEIGHT - 4, top_c, bot_c)
			interface.draw_outline(table, px, by + 2, TASKBAR_PILL_WIDTH, BAR_HEIGHT - 4, 1, graphics.colors.track)
		} else {
			// Minimized window: quiet flat slot with subtle bottom tick.
			interface.draw_rectangle(table, px + 10, by + BAR_HEIGHT - 4, TASKBAR_PILL_WIDTH - 20, 1, graphics.colors.dim)
		}
		label_room := same_count > 1 ? TASKBAR_PILL_WIDTH - 28 : TASKBAR_PILL_WIDTH - 16
		fit := interface.text_fit(table, interface.FONT_INTERFACE, name, label_room)
		interface.draw_text(table, px + 10, by + 8, fit, pill_fg, interface.FONT_INTERFACE)
		if same_count > 1 {
			// Stacked-window visual edge on right side + quiet numeric count.
			interface.draw_rectangle(table, px + TASKBAR_PILL_WIDTH - 3, by + 5, 1, BAR_HEIGHT - 10, graphics.colors.dim)
			digit := u8('0' + min(same_count, 9))
			interface.draw_character(table, px + TASKBAR_PILL_WIDTH - 14, by + 8, digit, graphics.colors.dim)
		}
		// Hover preview popover when pointer hovers over a taskbar pill.
		if inside(pointer_x, pointer_y, px, 0, TASKBAR_PILL_WIDTH, BAR_HEIGHT) && menu_open == .None {
			pop_h := 22 + same_count * 20 + 6
			interface.draw_rectangle(table, px, BAR_HEIGHT + 2, 180, pop_h, graphics.colors.card_bottom)
			interface.draw_outline(table, px, BAR_HEIGHT + 2, 180, pop_h, 1, graphics.colors.title)
			interface.draw_text(table, px + 8, BAR_HEIGHT + 6, fit, graphics.COLOR_WHITE, interface.FONT_INTERFACE)
			row := 0
			for p2 in 0 ..< order_count {
				c2 := &clients[order[p2]]
				if !c2.created || system.name_of(c2.title[:]) != name {
					continue
				}
				status_txt := c2.minimized ? "minimized" : (p2 == order_count - 1 ? "active" : "open")
				interface.draw_text(table, px + 8, BAR_HEIGHT + 24 + row * 20, status_txt, c2.minimized ? graphics.colors.dim : graphics.colors.text, interface.FONT_INTERFACE)
				row += 1
			}
		}
		px += TASKBAR_PILL_WIDTH + TASKBAR_PILL_GAP
	}

	// 2. System tray icon pills (to the left of the palette hint).
	tray_x := desktop_width - CLOCK_WIDTH - 230
	for &e in desktop_tray.entries {
		if !e.active || tray_x < px + 12 {
			continue
		}
		tray_x -= TRAY_BADGE_WIDTH + TRAY_BADGE_GAP
		bg := e.alert ? graphics.colors.stop_process : graphics.colors.track
		fg := e.alert ? graphics.COLOR_WHITE : graphics.colors.text
		by := desktop_bar_y()
		if e.alert {
			interface.draw_vertical_gradient(table, tray_x, by + 4, TRAY_BADGE_WIDTH, BAR_HEIGHT - 8, graphics.shade(bg, 115), graphics.shade(bg, 85))
		} else {
			interface.draw_outline(table, tray_x, by + 4, TRAY_BADGE_WIDTH, BAR_HEIGHT - 8, 1, graphics.colors.track)
		}
		interface.draw_text(table, tray_x + 8, by + 8, string(e.label[:e.len]), fg, interface.FONT_INTERFACE)
	}
}

// desktop_taskbar_press restores or raises a window group when clicking its pill in the bar.
desktop_taskbar_press :: proc "contextless" (click_x, click_y: int) -> bool {
	if !desktop_features_ready || click_y >= BAR_HEIGHT || click_x < TASKBAR_PILL_START_X {
		return false
	}
	max_right := max(TASKBAR_PILL_START_X, desktop_width - CLOCK_WIDTH - 240)
	px := TASKBAR_PILL_START_X
	for position in 0 ..< order_count {
		if px + TASKBAR_PILL_WIDTH > max_right {
			break
		}
		idx := order[position]
		client := &clients[idx]
		if !client.created {
			continue
		}
		name := system.name_of(client.title[:])
		already := false
		for p2 in 0 ..< position {
			if clients[order[p2]].created && system.name_of(clients[order[p2]].title[:]) == name {
				already = true
				break
			}
		}
		if already {
			continue
		}
		if click_x >= px && click_x < px + TASKBAR_PILL_WIDTH {
			// Restore any minimized window of this group or raise it to the front.
			if client.minimized {
				client.minimized = false
			}
			raise(position)
			damage_whole_screen()
			return true
		}
		px += TASKBAR_PILL_WIDTH + TASKBAR_PILL_GAP
	}
	return false
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
