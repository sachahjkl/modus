// Live desktop shell features integrated into the compositor:
// workspaces, edge-snapping, urgency-badged notifications with balanced
// spacing, viewport magnifier, positionable bar/tray state, and a live
// right-click filterable context menu.
package compositor

import "internal:compositor/bar"
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
	Snap_Left   = 8,
	Snap_Right  = 9,
	Maximize    = 10,
}

desktop_workspaces: desktop_layout.Workspace_Manager
desktop_work_area: desktop_layout.Work_Area
desktop_notifications: notifications.Notification_Queue
desktop_magnifier: screen_reader.Magnifier_State
desktop_bar_position: desktop_shell.Bar_Position = .Top
desktop_tray: desktop_shell.Tray_State
desktop_context_menu: interface.Context_Menu_State
desktop_features_ready: bool

// desktop_bar_y gives the logical y of the first row of the bar: the
// layout of the bar holds its edge (src/md/features/bar_edge.md).
desktop_bar_y :: proc "contextless" () -> int {
	return bar.top(bar_layout)
}

// desktop_work_top gives the first row of the desktop under a bar at the
// top, or the first row of the screen over a bar at the bottom: the place of
// a maximized window and of the first notification.
desktop_work_top :: proc "contextless" () -> int {
	switch bar_layout.edge {
	case .Top:
		return BAR_HEIGHT
	case .Bottom:
		return 0
	}
	return BAR_HEIGHT
}

// desktop_work_bottom gives the row after the last row of the desktop.
desktop_work_bottom :: proc "contextless" () -> int {
	switch bar_layout.edge {
	case .Top:
		return desktop_height
	case .Bottom:
		return desktop_bar_y()
	}
	return desktop_height
}

// bar_edge_of gives the edge that the compositor draws for a setting of the
// bar. A vertical bar is not drawn yet: the bar then stays at the top.
bar_edge_of :: proc "contextless" (position: desktop_shell.Bar_Position) -> bar.Edge {
	switch position {
	case .Top, .Left, .Right:
		return .Top
	case .Bottom:
		return .Bottom
	}
	return .Top
}

// desktop_bar_position_set takes a new setting of the bar and moves the bar,
// its menus and the windows maximized against it.
desktop_bar_position_set :: proc "contextless" (position: desktop_shell.Bar_Position) {
	before_top := desktop_work_top()
	desktop_bar_position = position
	bar_layout_update()
	if after_top := desktop_work_top(); after_top != before_top {
		for &client in clients {
			if client.created && client.maximized {
				client.y = after_top
			}
		}
	}
	damage_whole_screen()
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
	damage_bar()
}

desktop_window_closed :: proc "contextless" (index: int) {
	if !desktop_features_ready || index < 0 {
		return
	}
	_ = desktop_layout.workspace_remove_window(&desktop_workspaces, u64(index + 1))
	damage_bar()
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
	work_top := desktop_work_top()
	damage_add(x, work_top, desktop_width - x, min(h, max(0, desktop_work_bottom() - work_top)))
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
		y := desktop_work_top() + NOTIFICATION_BANNER_MARGIN + shown * (NOTIFICATION_BANNER_HEIGHT + NOTIFICATION_BANNER_GAP)
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
	// A shortcut is shown only for an act that desktop_shortcut_key does
	// with the same keys. The edge that the bar holds now is disabled.
	at_bottom := bar_layout.edge == .Bottom
	items := [10]interface.Context_Menu_Item{
		{id = u32(Desktop_Context_Action.New_Console), label = "New Console"},
		{id = u32(Desktop_Context_Action.Open_Monitor), label = "Open Monitor"},
		{id = u32(Desktop_Context_Action.Open_Clock), label = "Open Clock"},
		{id = u32(Desktop_Context_Action.Snap_Left), label = "Snap Window Left", shortcut = "Ctrl+Shift+Left"},
		{id = u32(Desktop_Context_Action.Snap_Right), label = "Snap Window Right", shortcut = "Ctrl+Shift+Right"},
		{id = u32(Desktop_Context_Action.Maximize), label = "Maximize Window", shortcut = "Ctrl+Shift+Up"},
		{id = u32(Desktop_Context_Action.Toggle_Mag), label = "Toggle Magnifier", shortcut = "Ctrl+Shift+M"},
		{id = u32(Desktop_Context_Action.Restore_All), label = "Restore Minimized"},
		{id = u32(Desktop_Context_Action.Bar_Top), label = "Bar Position Top", disabled = !at_bottom},
		{id = u32(Desktop_Context_Action.Bar_Bottom), label = "Bar Position Bottom", disabled = at_bottom},
	}
	// The menu stays on the desktop: it never covers the bar at the bottom.
	interface.context_menu_open(&desktop_context_menu, x, y, desktop_width, desktop_work_bottom(), items[:])
	damage_whole_screen()
}

// desktop_context_menu_damage records the card of the open context menu,
// with the room of every item, so a filter that shrinks it leaves no row.
desktop_context_menu_damage :: proc "contextless" () {
	height := interface.CONTEXT_MENU_HEADER_HEIGHT + max(1, desktop_context_menu.item_count) * interface.CONTEXT_MENU_ROW_HEIGHT + interface.CONTEXT_MENU_FOOT
	damage_add(desktop_context_menu.x, desktop_context_menu.y, interface.CONTEXT_MENU_WIDTH, height)
}

// desktop_context_menu_pointer gives the pointer to the open context menu.
// It gives true when the menu took the event: nothing under it receives it.
desktop_context_menu_pointer :: proc "contextless" (x, y: int, pressed: bool) -> bool {
	if !desktop_context_menu.open {
		return false
	}
	result := interface.context_menu_pointer(&desktop_context_menu, x, y, pressed)
	if result.changed {
		desktop_context_menu_damage()
	}
	if result.triggered {
		desktop_context_action(result.triggered_id)
	}
	return result.consumed
}

desktop_context_menu_key :: proc "contextless" (code: u32, character: rune, pressed: bool) -> bool {
	if !desktop_context_menu.open {
		return false
	}
	consumed, act_id := interface.context_menu_handle_key(&desktop_context_menu, code, character, pressed)
	if !consumed {
		return false
	}
	desktop_context_menu_damage()
	desktop_context_action(act_id)
	return true
}

// desktop_context_action does the act of an item of the context menu. The
// word of the menu becomes its enum here, and nowhere else.
desktop_context_action :: proc "contextless" (act_id: u32) {
	if action, ok := enum_word.member_of_word(Desktop_Context_Action, u64(act_id)); ok {
		switch action {
		case .None:
			// A key that filters or moves the choice: the menu damaged its card.
			return
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
			desktop_bar_position_set(.Top)
		case .Bar_Bottom:
			desktop_bar_position_set(.Bottom)
		case .Snap_Left:
			_ = desktop_snap_front_window(.Left_Half)
		case .Snap_Right:
			_ = desktop_snap_front_window(.Right_Half)
		case .Maximize:
			_ = desktop_snap_front_window(.Maximized)
		}
		damage_whole_screen()
	}
}

TASKBAR_PILL_START_X :: 224
TASKBAR_PILL_WIDTH :: 136
TASKBAR_PILL_GAP :: 4
TRAY_BADGE_WIDTH :: 34
TRAY_BADGE_GAP :: 4
TASKBAR_PREVIEW_WIDTH :: 184
TASKBAR_PREVIEW_TITLE :: 26 // The name of the group and the line under it.
TASKBAR_PREVIEW_LINE :: 20 // One window of the group.
TASKBAR_PREVIEW_FOOT :: 6
TASKBAR_PREVIEW_GAP :: 2 // Between the bar and the card.

// The slot of the plate under the pointer at the last move, or -1: a change
// draws the plates and the preview again.
taskbar_hover_slot := -1
// The card of the preview in the last frame; a width of 0: none.
taskbar_preview_area: interface.Area

// taskbar_preview_height gives the height of the preview of a group of
// count windows.
taskbar_preview_height :: proc "contextless" (count: int) -> int {
	return TASKBAR_PREVIEW_TITLE + max(count, 1) * TASKBAR_PREVIEW_LINE + TASKBAR_PREVIEW_FOOT
}

// taskbar_preview_top gives the y of a preview of a height: next to the
// bar, away from its edge, with a gap of its own.
taskbar_preview_top :: proc "contextless" (height: int) -> int {
	y := bar.menu_top(bar_layout, height + TASKBAR_PREVIEW_GAP)
	switch bar_layout.edge {
	case .Top:
		return y + TASKBAR_PREVIEW_GAP
	case .Bottom:
		return y
	}
	return y
}

// taskbar_preview_records draws the preview of a group of windows of one
// name: a card in the gradient of the cards with a line of light under its
// top border, the name, a line under it, then one line for each window with
// its state. The window in front has the square of the focus, as in the
// menu of the windows.
taskbar_preview_records :: proc "contextless" (table: ^interface.Draw_Table, x: int, title, name: string, count: int) {
	height := taskbar_preview_height(count)
	left := clamp(x, 0, max(0, desktop_width - TASKBAR_PREVIEW_WIDTH))
	y := taskbar_preview_top(height)
	taskbar_preview_area = {left, y, TASKBAR_PREVIEW_WIDTH, height}
	interface.draw_vertical_gradient(table, left, y, TASKBAR_PREVIEW_WIDTH, height, graphics.colors.card_top, graphics.colors.card_bottom)
	interface.draw_outline(table, left, y, TASKBAR_PREVIEW_WIDTH, height, 1, graphics.colors.title)
	interface.draw_rectangle(table, left + 1, y + 1, TASKBAR_PREVIEW_WIDTH - 2, 1, graphics.shade(graphics.colors.card_top, 135))
	interface.draw_text(table, left + 10, y + 5, title, graphics.COLOR_WHITE, interface.FONT_INTERFACE)
	interface.draw_rectangle(table, left + 1, y + TASKBAR_PREVIEW_TITLE - 1, TASKBAR_PREVIEW_WIDTH - 2, 1, graphics.colors.track)
	row := 0
	for position in 0 ..< order_count {
		client := &clients[order[position]]
		if !client.created || system.name_of(client.title[:]) != name {
			continue
		}
		line_y := y + TASKBAR_PREVIEW_TITLE + row * TASKBAR_PREVIEW_LINE
		in_front := position == order_count - 1 && !client.minimized
		state := client.minimized ? "minimized" : (in_front ? "active" : "open")
		color := client.minimized ? graphics.colors.dim : (in_front ? graphics.colors.text_strong : graphics.colors.text)
		if in_front {
			interface.draw_rectangle(table, left + 10, line_y + 7, 6, 6, graphics.colors.title)
		}
		interface.draw_text(table, left + 24, line_y + 2, state, color, interface.FONT_INTERFACE)
		row += 1
	}
}

// desktop_taskbar_pointer_move draws the plates and the preview again when
// the pointer reaches another plate slot or leaves the plates. The slots
// are at fixed places, so the test needs no pass over the windows; only a
// change damages the card of the preview, the old one and the room of the
// new one.
desktop_taskbar_pointer_move :: proc "contextless" (x, y: int) {
	slot := -1
	if desktop_features_ready && menu_open == .None && bar.inside_bar(bar_layout, y) && x >= TASKBAR_PILL_START_X {
		offset := x - TASKBAR_PILL_START_X
		if offset % (TASKBAR_PILL_WIDTH + TASKBAR_PILL_GAP) < TASKBAR_PILL_WIDTH {
			slot = offset / (TASKBAR_PILL_WIDTH + TASKBAR_PILL_GAP)
		}
	}
	if slot == taskbar_hover_slot {
		return
	}
	taskbar_hover_slot = slot
	damage_bar()
	if taskbar_preview_area.width > 0 {
		damage_add(taskbar_preview_area.x, taskbar_preview_area.y, taskbar_preview_area.width, taskbar_preview_area.height)
	}
	if slot >= 0 {
		height := taskbar_preview_height(order_count)
		left := clamp(TASKBAR_PILL_START_X + slot * (TASKBAR_PILL_WIDTH + TASKBAR_PILL_GAP), 0, max(0, desktop_width - TASKBAR_PREVIEW_WIDTH))
		damage_add(left, taskbar_preview_top(height), TASKBAR_PREVIEW_WIDTH, height)
	}
}

// desktop_taskbar_and_tray_records draws live taskbar window pills (highlighting
// focused windows, dimming minimized ones, showing module window counts when
// grouped) and system tray badges directly inside the top bar.
desktop_taskbar_and_tray_records :: proc "contextless" (table: ^interface.Draw_Table) {
	if !desktop_features_ready {
		return
	}
	// 1. Kernel-theme taskbar window plates after a crisp vertical hairline divider.
	taskbar_preview_area = {}
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
		if hovered {
			taskbar_preview_records(table, px, fit, name, same_count)
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
	if !desktop_features_ready || !bar.inside_bar(bar_layout, click_y) || click_x < TASKBAR_PILL_START_X {
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
	// The zones of the layout start under a bar at the top: over a bar at
	// the bottom they start at the first row of the screen.
	client.y = int(rect.y) - BAR_HEIGHT + desktop_work_top()
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
		client.y = desktop_work_top()
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
