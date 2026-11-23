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
	// The menu of a plate of the bar: the acts on its window.
	Window_Front    = 11,
	Window_Minimize = 12,
	Window_Close    = 13,
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
	notifications.queue_init(&desktop_notifications)
	_ = screen_reader.magnifier_init(&desktop_magnifier, screen_w, screen_h, u16(display_choices_in_force.magnifier_eighths))
	desktop_magnifier.enabled = false
	desktop_bar_position = display_choices_in_force.bar_edge
	desktop_notifications.do_not_disturb = display_choices_in_force.do_not_disturb == .On
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
	// The card of the switcher lists the windows of its open: a new window
	// closes it (window_switcher.odin).
	window_switcher_cancel()
	if !desktop_features_ready || index < 0 {
		return
	}
	_ = desktop_layout.workspace_add_window(&desktop_workspaces, u64(index + 1), desktop_workspaces.active_index)
	damage_bar()
}

desktop_window_closed :: proc "contextless" (index: int) {
	window_switcher_cancel()
	// The menu of a plate names its window by its client index, which a
	// new window can take: the menu of a window that closed closes with it.
	if index >= 0 && taskbar_menu_window == index {
		taskbar_menu_window = -1
		if desktop_context_menu.open {
			desktop_context_menu_damage()
			desktop_context_menu.open = false
		}
	}
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
		// A card plate: the gradient of the cards, a line of light under its
		// top edge and a border of the track. The title is the strong text:
		// white on the dark card, black on the white one.
		interface.draw_vertical_gradient(table, x, y, NOTIFICATION_BANNER_WIDTH, NOTIFICATION_BANNER_HEIGHT, graphics.colors.card_top, graphics.colors.card_bottom)
		interface.draw_outline(table, x, y, NOTIFICATION_BANNER_WIDTH, NOTIFICATION_BANNER_HEIGHT, 1, graphics.colors.track)
		interface.draw_rectangle(table, x + 1, y + 1, NOTIFICATION_BANNER_WIDTH - 2, 1, graphics.shade(graphics.colors.card_top, 125))
		// Crisp 3px urgency accent rail (matching Kernel theme Control Panel / Notifications).
		interface.draw_rectangle(table, x + 11, y + 12, NOTIFICATION_RAIL_WIDTH, NOTIFICATION_BANNER_HEIGHT - 24, rail_color)

		text_x := x + 24
		text_room := NOTIFICATION_BANNER_WIDTH - 36
		// The label of a caller: its process name, in the dim color before
		// the title (src/md/features/tray_widgets.md, "The export notify").
		if item.label_len > 0 {
			label_str := string(item.label[:min(int(item.label_len), notifications.MAX_LABEL_BYTES)])
			label_fit := interface.text_fit(table, interface.FONT_INTERFACE, label_str, text_room / 2)
			label_y := item.body_len > 0 ? y + 12 : y + (NOTIFICATION_BANNER_HEIGHT - graphics.CELL_HEIGHT) / 2
			after := interface.draw_text(table, text_x, label_y, label_fit, graphics.colors.dim, interface.FONT_INTERFACE)
			text_room -= after + 8 - text_x
			text_x = after + 8
		}
		title_str := string(item.title[:item.title_len])
		title_fit := interface.text_fit(table, interface.FONT_INTERFACE, title_str, text_room)
		if item.body_len > 0 {
			interface.draw_text(table, text_x, y + 12, title_fit, graphics.colors.text_strong, interface.FONT_INTERFACE)
			body_str := string(item.body[:item.body_len])
			body_fit := interface.text_fit(table, interface.FONT_INTERFACE, body_str, text_room)
			interface.draw_text(table, text_x, y + 34, body_fit, graphics.colors.dim, interface.FONT_INTERFACE)
		} else {
			interface.draw_text(table, text_x, y + (NOTIFICATION_BANNER_HEIGHT - graphics.CELL_HEIGHT) / 2, title_fit, graphics.colors.text_strong, interface.FONT_INTERFACE)
		}
		shown += 1
	}
}

// desktop_context_menu_open opens the filterable fuzzy right-click menu at (x, y).
desktop_context_menu_open :: proc "contextless" (x, y: int) {
	window_switcher_cancel() // window_switcher.odin: a menu takes the keys.
	taskbar_menu_window = -1
	if !desktop_features_ready {
		return
	}
	tray_widget_close() // tray_widgets.odin: one card at a time.
	// A shortcut is shown only for an act that desktop_shortcut_key does
	// with the same keys. The edge that the bar holds now is disabled.
	at_bottom := bar_layout.edge == .Bottom
	// The entry of the toggle names what it does to the window in front.
	front_maximized := order_count > 0 && clients[order[order_count - 1]].maximized
	items := [10]interface.Context_Menu_Item{
		{id = u32(Desktop_Context_Action.New_Console), label = "New Console"},
		{id = u32(Desktop_Context_Action.Open_Monitor), label = "Open Monitor"},
		{id = u32(Desktop_Context_Action.Open_Clock), label = "Open Clock"},
		{id = u32(Desktop_Context_Action.Snap_Left), label = "Snap Window Left", shortcut = "Ctrl+Shift+Left"},
		{id = u32(Desktop_Context_Action.Snap_Right), label = "Snap Window Right", shortcut = "Ctrl+Shift+Right"},
		{id = u32(Desktop_Context_Action.Maximize), label = front_maximized ? "Restore Window" : "Maximize Window", shortcut = "Ctrl+Shift+Up"},
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
			display_bar_edge_choose(.Top)
		case .Bar_Bottom:
			display_bar_edge_choose(.Bottom)
		case .Snap_Left:
			_ = desktop_snap_front_window(.Left_Half)
		case .Snap_Right:
			_ = desktop_snap_front_window(.Right_Half)
		case .Maximize:
			_ = desktop_snap_front_window(.Maximized)
		case .Window_Front:
			if index, window_there := taskbar_menu_window_take(); window_there {
				clients[index].minimized = false
				for position in 0 ..< order_count {
					if order[position] == index {
						raise(position)
						break
					}
				}
			}
		case .Window_Minimize:
			if index, window_there := taskbar_menu_window_take(); window_there {
				window_minimize(index)
			}
		case .Window_Close:
			if index, window_there := taskbar_menu_window_take(); window_there {
				system.send(&control.completions, ring.Record{kind = u32(display.Control.Stop), values = {0 = u64(clients[index].ring_memory)}})
			}
		}
		damage_whole_screen()
	}
}

TRAY_BADGE_GAP :: 4
TASKBAR_PREVIEW_WIDTH :: 184
TASKBAR_PREVIEW_TITLE :: 26 // The name of the group and the line under it.
TASKBAR_PREVIEW_LINE :: 20 // One window of the group.
TASKBAR_PREVIEW_FOOT :: 6
TASKBAR_PREVIEW_GAP :: 2 // Between the bar and the card.
TASKBAR_TRAY_GAP :: 8 // Between the last plate and the tray.

// The plate under the pointer at the last move, and whether its preview
// shows (bar.Taskbar_Preview): a change draws the plates and the preview
// again.
taskbar_preview_state: bar.Taskbar_Preview
// The first column that no plate reaches, in the last frame: the left of
// the tray. A press and a move read the plates that the eye sees.
taskbar_plates_right: int
// The plates that the last frame drew: the keys walk the plates that the
// eye sees.
taskbar_plate_count: int
// The card of the preview in the last frame; a width of 0: none.
taskbar_preview_area: interface.Area
// The group of the plate under the pointer in this frame: the plates find
// it, and the preview is drawn over the menus after them. A count of 0: none.
taskbar_preview_group: struct {
	x:     int,
	title: string, // The name as the plate shows it: cut to its room.
	name:  string, // The name of the windows of the group.
	count: int,
}

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

// desktop_taskbar_preview_records draws the preview of the group of the
// plate under the pointer: a card in the gradient of the cards with a line
// of light under its top border, the icon and the name, a line under them,
// then one line for each window with its state. The window in front has
// the bar of the focus, as in the menu of the windows.
desktop_taskbar_preview_records :: proc "contextless" (table: ^interface.Draw_Table) {
	group := taskbar_preview_group
	if group.count == 0 {
		return
	}
	height := taskbar_preview_height(group.count)
	left := clamp(group.x, 0, max(0, desktop_width - TASKBAR_PREVIEW_WIDTH))
	y := taskbar_preview_top(height)
	taskbar_preview_area = {left, y, TASKBAR_PREVIEW_WIDTH, height}
	interface.draw_vertical_gradient(table, left, y, TASKBAR_PREVIEW_WIDTH, height, graphics.colors.card_top, graphics.colors.card_bottom)
	interface.draw_outline(table, left, y, TASKBAR_PREVIEW_WIDTH, height, 1, graphics.colors.title)
	interface.draw_rectangle(table, left + 1, y + 1, TASKBAR_PREVIEW_WIDTH - 2, 1, graphics.shade(graphics.colors.card_top, 135))
	bar.icon_records(table, left + 8, y + 5, bar.icon_of(group.name), graphics.colors.text, graphics.colors.title)
	interface.draw_text(table, left + 8 + bar.ICON_SIZE + 6, y + 5, group.title, graphics.colors.text_strong, interface.FONT_INTERFACE)
	interface.draw_rectangle(table, left + 1, y + TASKBAR_PREVIEW_TITLE - 1, TASKBAR_PREVIEW_WIDTH - 2, 1, graphics.colors.track)
	row := 0
	for position in 0 ..< opened_count {
		client := &clients[opened[position]]
		if !client.created || system.name_of(client.title[:]) != group.name {
			continue
		}
		line_y := y + TASKBAR_PREVIEW_TITLE + row * TASKBAR_PREVIEW_LINE
		in_front := window_in_front(opened[position])
		state := client.minimized ? "minimized" : (in_front ? (client.maximized ? "active, maximized" : "active") : (client.maximized ? "maximized" : "open"))
		color := client.minimized ? graphics.colors.dim : (in_front ? graphics.colors.text_strong : graphics.colors.text)
		if in_front {
			interface.draw_rectangle(table, left + 10, line_y + 3, 2, TASKBAR_PREVIEW_LINE - 6, graphics.colors.title)
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
	if desktop_features_ready && menu_open == .None && tray_state.open == .None {
		slot = bar.plate_at(bar_layout, taskbar_plates_right, x, y)
	}
	if !bar.taskbar_preview_pointer(&taskbar_preview_state, slot, taskbar_preview_reaches(x, y)) {
		return
	}
	taskbar_preview_damage()
	if slot >= 0 {
		height := taskbar_preview_height(order_count)
		plate_x, _, _, _ := bar.plate(bar_layout, slot)
		left := clamp(plate_x, 0, max(0, desktop_width - TASKBAR_PREVIEW_WIDTH))
		damage_add(left, taskbar_preview_top(height), TASKBAR_PREVIEW_WIDTH, height)
	}
}

// taskbar_preview_reaches says if a place is on the card of the preview of
// the last frame, or in the gap between the card and the bar: the pointer
// that goes from the plate to the card crosses that gap.
taskbar_preview_reaches :: proc "contextless" (x, y: int) -> bool {
	area := taskbar_preview_area
	if area.width == 0 {
		return false
	}
	top, height := area.y, area.height + TASKBAR_PREVIEW_GAP
	if bar_layout.edge == .Top {
		top -= TASKBAR_PREVIEW_GAP
	}
	return inside(x, y, area.x, top, area.width, height)
}

// taskbar_preview_damage draws the plates and the card of the last frame
// again.
taskbar_preview_damage :: proc "contextless" () {
	damage_bar()
	if taskbar_preview_area.width > 0 {
		damage_add(taskbar_preview_area.x, taskbar_preview_area.y, taskbar_preview_area.width, taskbar_preview_area.height)
	}
}

// taskbar_preview_dismiss closes the card of the preview that shows:
// Escape, a press outside the card, a change of the windows
// (src/md/features/desktop_shell_look.md, "The preview closes as a hover
// card does"). It says whether a card closed.
taskbar_preview_dismiss :: proc "contextless" () -> bool {
	if !bar.taskbar_preview_close(&taskbar_preview_state) {
		return false
	}
	taskbar_preview_damage()
	return true
}

// taskbar_preview_press gives a press of any button to the preview: a press
// outside the card closes it.
taskbar_preview_press :: proc "contextless" (x, y: int) {
	if bar.taskbar_preview_press(&taskbar_preview_state, taskbar_preview_reaches(x, y)) {
		taskbar_preview_damage()
	}
}

// taskbar_group_first reports whether the window at a position of the
// order of opening is the first of its name: the plate of a group stands
// for it, at the place of the first window of the group that opened.
taskbar_group_first :: proc "contextless" (position: int) -> bool {
	client := &clients[opened[position]]
	if !client.created {
		return false
	}
	name := system.name_of(client.title[:])
	for earlier in 0 ..< position {
		if clients[opened[earlier]].created && system.name_of(clients[opened[earlier]].title[:]) == name {
			return false
		}
	}
	return true
}

// taskbar_group_last_used gives the position in order of the window of a
// name used last: among the windows shown, or among the minimized ones;
// -1 when the group has none of them.
taskbar_group_last_used :: proc "contextless" (name: string, minimized: bool) -> int {
	for position := order_count - 1; position >= 0; position -= 1 {
		client := &clients[order[position]]
		if client.created && client.minimized == minimized && system.name_of(client.title[:]) == name {
			return position
		}
	}
	return -1
}

// window_in_front reports whether a client is the window in front and is
// shown: the one that receives the keys.
window_in_front :: proc "contextless" (index: int) -> bool {
	return order_count > 0 && order[order_count - 1] == index && !clients[index].minimized
}

// window_minimize minimizes a window and moves it to the back, so the
// keys go to the window that is in front after it.
window_minimize :: proc "contextless" (index: int) {
	clients[index].minimized = true
	for position in 0 ..< order_count {
		if order[position] == index {
			lower(position)
			break
		}
	}
	damage_whole_screen()
}

// The client of the window whose plate the right button pressed: the menu
// of the plate acts on it. -1: none.
taskbar_menu_window := -1

// desktop_taskbar_menu_open opens the menu of the window acts at a press of
// the right button on a plate: on the window of its group used last.
desktop_taskbar_menu_open :: proc "contextless" (x, y: int) -> bool {
	if !desktop_features_ready {
		return false
	}
	position := taskbar_slot_first_position(bar.plate_at(bar_layout, taskbar_plates_right, x, y))
	if position < 0 {
		return false
	}
	name := system.name_of(clients[opened[position]].title[:])
	last_used := taskbar_group_last_used(name, false)
	if last_used < 0 {
		last_used = taskbar_group_last_used(name, true)
	}
	if last_used < 0 {
		return false
	}
	window_switcher_cancel() // window_switcher.odin: a menu takes the keys.
	taskbar_menu_window = order[last_used]
	client := &clients[taskbar_menu_window]
	items := [3]interface.Context_Menu_Item {
		{id = u32(Desktop_Context_Action.Window_Front), label = client.minimized ? "Restore" : "Bring to Front", disabled = window_in_front(taskbar_menu_window)},
		{id = u32(Desktop_Context_Action.Window_Minimize), label = "Minimize", disabled = client.minimized},
		{id = u32(Desktop_Context_Action.Window_Close), label = "Close"},
	}
	interface.context_menu_open(&desktop_context_menu, x, y, desktop_width, desktop_work_bottom(), items[:])
	damage_whole_screen()
	return true
}

// taskbar_menu_window_take gives the window of the menu of a plate, if it
// is still there: a window can close while its menu is open.
taskbar_menu_window_take :: proc "contextless" () -> (index: int, ok: bool) {
	index = taskbar_menu_window
	taskbar_menu_window = -1
	return index, index >= 0 && index < len(clients) && clients[index].created
}

// tray_icon_of gives the icon of a pill of the tray. ok is false for a pill
// that shows its label only.
tray_icon_of :: proc "contextless" (kind: desktop_shell.Tray_Icon_Kind) -> (icon: bar.Icon, ok: bool) {
	switch kind {
	case .Network:
		return .Network, true
	case .Sound:
		return .Sound, true
	case .Capture:
		return .Capture, true
	case .Wide_Grant:
		return .Grant, true
	case .Locale:
		return .Window, false
	}
	return .Window, false
}

// desktop_taskbar_and_tray_records draws the pills of the tray from right
// to the left, then the plates of the groups of windows from the divider
// to the tray: one plate for each name, with its icon, its name, the count
// of its windows when there are several, and the accent of the group of the
// window in front.
desktop_taskbar_and_tray_records :: proc "contextless" (table: ^interface.Draw_Table, right: int) {
	taskbar_preview_area = {}
	taskbar_preview_group = {}
	if !desktop_features_ready {
		taskbar_plates_right, taskbar_plate_count = 0, 0
		return
	}
	bar_top := desktop_bar_y()
	// 1. The tray: a pill keeps the room of one plate at least.
	tray_x := right
	for &entry in desktop_tray.entries {
		if !entry.active {
			continue
		}
		label := string(entry.label[:entry.len])
		icon, has_icon := tray_icon_of(entry.kind)
		content := label != "" ? interface.text_measured_width(table, interface.FONT_INTERFACE, label) : 0
		if has_icon {
			content += bar.ICON_SIZE + (label != "" ? 4 : 0)
		}
		pill_width := content + 2 * bar.PADDING
		if tray_x - pill_width < bar.PLATES_X + bar.PLATE_WIDTH + TASKBAR_TRAY_GAP {
			break
		}
		tray_x -= pill_width
		pill_y := bar_top + bar.TRAY_Y
		foreground := graphics.colors.text
		if entry.alert {
			interface.draw_vertical_gradient(table, tray_x, pill_y, pill_width, bar.TRAY_HEIGHT, graphics.shade(graphics.colors.stop_process, 115), graphics.shade(graphics.colors.stop_process, 85))
			interface.draw_rectangle(table, tray_x, pill_y, pill_width, 1, graphics.shade(graphics.colors.stop_process, 140))
			foreground = graphics.COLOR_WHITE
		}
		content_x := tray_x + bar.PADDING
		if has_icon {
			bar.icon_records(table, content_x, pill_y + (bar.TRAY_HEIGHT - bar.ICON_SIZE) / 2, icon, foreground, entry.alert ? graphics.COLOR_WHITE : graphics.colors.title)
			content_x += bar.ICON_SIZE + 4
		}
		if label != "" {
			interface.draw_text(table, content_x, pill_y + (bar.TRAY_HEIGHT - graphics.CELL_HEIGHT) / 2, label, foreground, interface.FONT_INTERFACE)
		}
		tray_x -= TRAY_BADGE_GAP
	}
	taskbar_plates_right = tray_x - TASKBAR_TRAY_GAP
	// 2. The plates of the groups of windows, in the order in which their
	// first windows opened: the focus changes the look of a plate, never its
	// place.
	slot := 0
	for position in 0 ..< opened_count {
		if !taskbar_group_first(position) {
			continue
		}
		x, y, width, height := bar.plate(bar_layout, slot)
		if x + width > taskbar_plates_right {
			break
		}
		client := &clients[opened[position]]
		name := system.name_of(client.title[:])
		same_count := 0
		any_focus := false
		all_minimized := true
		for other in position ..< opened_count {
			other_client := &clients[opened[other]]
			if !other_client.created || system.name_of(other_client.title[:]) != name {
				continue
			}
			same_count += 1
			if window_in_front(opened[other]) {
				any_focus = true
			}
			if !other_client.minimized {
				all_minimized = false
			}
		}
		hovered := slot == bar.taskbar_preview_slot(&taskbar_preview_state) && menu_open == .None && tray_state.open == .None
		// The plate in front is a step lighter than the bar: white text
		// reads on the steel plate of the dark appearance and vanishes on
		// the white plate of the light one, so the text is the strong text.
		// The light blue of the accent vanishes there too.
		foreground := any_focus ? graphics.colors.text_strong : (all_minimized ? graphics.colors.dim : graphics.colors.text)
		focus_accent := graphics.appearance == .Dark ? graphics.shade(graphics.colors.title, 160) : graphics.colors.title
		if any_focus {
			// The group of the window in front: a raised steel plate, a line
			// of light under its top edge, and an accent of 2 pixels at its foot.
			interface.draw_vertical_gradient(table, x, y, width, height, graphics.shade(graphics.colors.card_top, 135), graphics.shade(graphics.colors.card_bottom, 120))
			interface.draw_outline(table, x, y, width, height, 1, graphics.shade(graphics.colors.track, 130))
			interface.draw_rectangle(table, x + 1, y + 1, width - 2, 1, graphics.shade(graphics.colors.card_top, 155))
			interface.draw_rectangle(table, x + 1, y + height - 3, width - 2, 2, graphics.colors.title)
		} else if !all_minimized || hovered {
			// An open group, or one under the pointer: a quiet plate.
			top_color := hovered ? graphics.shade(graphics.colors.card_top, 120) : graphics.colors.card_top
			bottom_color := hovered ? graphics.shade(graphics.colors.card_bottom, 110) : graphics.colors.card_bottom
			interface.draw_vertical_gradient(table, x, y, width, height, top_color, bottom_color)
			interface.draw_outline(table, x, y, width, height, 1, graphics.colors.track)
		} else {
			// A group of minimized windows: no plate, a quiet line at its foot.
			interface.draw_rectangle(table, x + 10, y + height - 2, width - 20, 1, graphics.colors.dim)
		}
		bar.icon_records(table, x + bar.PADDING, y + (height - bar.ICON_SIZE) / 2, client.icon, foreground, any_focus ? focus_accent : graphics.colors.title)
		text_x := x + bar.PADDING + bar.ICON_SIZE + 6
		count_room := same_count > 1 ? 16 : 0
		fit := interface.text_fit(table, interface.FONT_INTERFACE, name, x + width - bar.PADDING - count_room - text_x)
		interface.draw_text(table, text_x, y + (height - graphics.CELL_HEIGHT) / 2, fit, foreground, interface.FONT_INTERFACE)
		if same_count > 1 {
			// A stack of windows: an edge at the right of the plate, and the count.
			interface.draw_rectangle(table, x + width - 3, y + 4, 1, height - 8, graphics.colors.dim)
			digit := u8('0' + min(same_count, 9))
			interface.draw_character(table, x + width - 15, y + (height - graphics.CELL_HEIGHT) / 2, digit, graphics.colors.dim)
		}
		// The preview lists the windows of a group of several, under the
		// pointer: a plate of one window says all that the preview would.
		if hovered && taskbar_preview_state.shown && same_count > 1 && !desktop_context_menu.open {
			taskbar_preview_group = {x = x, title = fit, name = name, count = same_count}
		}
		slot += 1
	}
	taskbar_plate_count = slot
}

// desktop_taskbar_press acts on the group of a plate of the bar.
desktop_taskbar_press :: proc "contextless" (click_x, click_y: int) -> bool {
	if !desktop_features_ready {
		return false
	}
	return desktop_taskbar_slot_activate(bar.plate_at(bar_layout, taskbar_plates_right, click_x, click_y))
}

// taskbar_slot_first_position gives the position in the order of opening
// of the first window of the group of a plate slot, or -1.
taskbar_slot_first_position :: proc "contextless" (wanted: int) -> int {
	if wanted < 0 {
		return -1
	}
	slot := 0
	for position in 0 ..< opened_count {
		if !taskbar_group_first(position) {
			continue
		}
		if slot == wanted {
			return position
		}
		slot += 1
	}
	return -1
}

// desktop_taskbar_slot_activate does the act of a press on a plate slot
// (bar.plate_act): from the pointer, or from Enter on the plate that has
// the focus of the keys. false: no group has that slot.
desktop_taskbar_slot_activate :: proc "contextless" (wanted: int) -> bool {
	if !desktop_features_ready {
		return false
	}
	first := taskbar_slot_first_position(wanted)
	if first < 0 {
		return false
	}
	name := system.name_of(clients[opened[first]].title[:])
	windows: [CLIENT_CAPACITY]bar.Plate_Window
	for position in 0 ..< order_count {
		client := &clients[order[position]]
		windows[position] = {name = system.name_of(client.title[:]), minimized = client.minimized}
	}
	act, position, found := bar.plate_press(windows[:order_count], name)
	if !found {
		return false
	}
	index := order[position]
	switch act {
	case .Minimize:
		window_minimize(index)
		system.log_fact(.Info, Plate_Minimized{window = window_field(clients[index].title[:])})
	case .Raise:
		raise(position)
		system.log_fact(.Info, Plate_Raised{window = window_field(clients[index].title[:])})
	case .Restore:
		clients[index].minimized = false
		raise(position)
		system.log_fact(.Info, Plate_Restored{window = window_field(clients[index].title[:])})
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

// desktop_snap_front_window gives the window in front the frame of a zone
// of the work area. The zone Maximized toggles the maximized state, so the
// button of the title bar, the menu and Ctrl+Shift+Up take one path.
desktop_snap_front_window :: proc "contextless" (zone: desktop_layout.Snap_Zone) -> bool {
	if !desktop_features_ready || order_count == 0 {
		return false
	}
	client := &clients[order[order_count - 1]]
	if zone == .Maximized {
		return desktop_toggle_maximize(client)
	}
	// The same refusal as the maximize: the answer to a request would give
	// the window a size under the new one.
	if !client.created || window_held_by_input(client) || window_waits_for_answer(client) {
		return false
	}
	x, y, outer_width, outer_height, ok := desktop_zone_frame(zone)
	if !ok {
		return false
	}
	if client.maximized {
		client.maximized = false
		system.log_fact(.Info, Window_Restored{window = window_field(client.title[:])})
		palette_entries_refresh()
	}
	window_frame_take(client, x, y, outer_width, outer_height)
	return true
}

// desktop_zone_frame gives the frame of a zone of the work area: its place
// and its outer size, in logical pixels.
desktop_zone_frame :: proc "contextless" (zone: desktop_layout.Snap_Zone) -> (x, y, outer_width, outer_height: int, ok: bool) {
	rect, found := desktop_layout.snap_zone_rect(desktop_work_area, zone)
	if !found {
		return 0, 0, 0, 0, false
	}
	// The zones of the layout start under a bar at the top: over a bar at
	// the bottom they start at the first row of the screen.
	return int(rect.x), int(rect.y) - BAR_HEIGHT + desktop_work_top(), int(rect.width), int(rect.height), true
}

// desktop_toggle_maximize gives a window the whole work area, or gives a
// maximized window back the place and the size that it had before. The size
// is a request to the process of the window, as at the end of a drag of its
// edges, within the limits that the process declared: a window that is not
// resizable only moves. A window whose last request has no answer yet is
// not maximized: the answer would change its size under the new one. A
// maximized window in that state takes back its place at once, and asks
// for its saved size when the request ends (desktop_restore_size_after_answer):
// a process that never answers cannot keep its window over the whole screen. A drag of the edges of the window
// or a resize by keys holds it: the toggle waits for their end.
desktop_toggle_maximize :: proc "contextless" (client: ^Client) -> bool {
	if client == nil || !client.created || window_held_by_input(client) {
		return false
	}
	if !client.maximized {
		if window_waits_for_answer(client) {
			return false
		}
		x, y, outer_width, outer_height, ok := desktop_zone_frame(.Maximized)
		if !ok {
			return false
		}
		client.saved_x, client.saved_y = client.x, client.y
		client.saved_width, client.saved_height = client.width, client.height
		client.maximized = true
		client.restore_size_due = false
		system.log_fact(.Info, Window_Maximized{window = window_field(client.title[:])})
		window_frame_take(client, x, y, outer_width, outer_height)
	} else {
		client.maximized = false
		system.log_fact(.Info, Window_Restored{window = window_field(client.title[:])})
		// A request that waits cannot be crossed: the window takes its
		// place now, and asks for its size when the request ends.
		client.restore_size_due = window_waits_for_answer(client)
		window_place_and_size_take(client, client.saved_x, client.saved_y, client.saved_width, client.saved_height)
	}
	palette_entries_refresh() // The entry of the window in front names the maximize or the restore.
	damage_whole_screen()
	return true
}

// desktop_restore_size_after_answer asks for the saved size of a window
// whose restore came while a request waited, once that request ended: its
// answer, a decline or a refusal. The place stays where the restore put it.
desktop_restore_size_after_answer :: proc "contextless" (client: ^Client) {
	if !client.restore_size_due || client.maximized || window_waits_for_answer(client) {
		return
	}
	client.restore_size_due = false
	window_place_and_size_take(client, client.x, client.y, client.saved_width, client.saved_height)
}

// desktop_restore_under_pointer gives a maximized window that a drag of its
// title moves the place and the size of before its maximize. The pointer
// keeps the same part of the title, so the smaller window comes under the
// pointer and the drag goes on. While a request of the window waits for its
// answer, the window stays maximized and moves: the next move tries again.
desktop_restore_under_pointer :: proc "contextless" (client: ^Client) {
	if !client.maximized || window_waits_for_answer(client) {
		return
	}
	frame_width := client.decoration == .Client ? 0 : 2 * BORDER
	drag_x = bar.restored_hold_x(drag_x, client.width + frame_width, client.saved_width + frame_width)
	client.maximized = false
	system.log_fact(.Info, Window_Restored{window = window_field(client.title[:])})
	window_place_and_size_take(client, pointer_x - drag_x, pointer_y - drag_y, client.saved_width, client.saved_height)
	palette_entries_refresh()
	damage_whole_screen()
}

// window_waits_for_answer says whether the process of a window has a
// request of a size or a surface to answer: a new request would cross it.
window_waits_for_answer :: proc "contextless" (client: ^Client) -> bool {
	return client.resize_asked || client.resize_pictures != nil || client.released
}

// window_held_by_input says whether a drag of the edges or a mode of the
// arrow keys holds a window: their end asks for its size.
window_held_by_input :: proc "contextless" (client: ^Client) -> bool {
	return (resizing >= 0 && &clients[resizing] == client) || (keyboard_window_mode != .None && keyboard_window >= 0 && &clients[keyboard_window] == client)
}

desktop_toggle_minimize :: proc "contextless" (client: ^Client) {
	if client == nil {
		return
	}
	if !client.minimized {
		// A minimized window gives the keys to the window behind it.
		for index in 0 ..< len(clients) {
			if &clients[index] == client {
				window_minimize(index)
				return
			}
		}
	}
	client.minimized = !client.minimized
	damage_whole_screen()
}

desktop_magnifier_set :: proc "contextless" (zoom_eighths: u16, tx, ty: i32) -> bool {
	if !desktop_features_ready {
		return false
	}
	// The principal took the magnifier over: the last assistive holder that
	// detaches must not end a magnification that it did not ask for.
	assistive_magnifying = false
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
	assistive_magnifying = false
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

desktop_notification_post :: proc "contextless" (source_id: u64, urgency: notifications.Urgency, now_ms: u64, title, body: []u8, label: []u8 = nil, cards_limit := 0) -> (id: u64, refusal: notifications.Notification_Refusal) {
	if !desktop_features_ready {
		return 0, .Nil_Queue
	}
	id, refusal = notifications.queue_post(&desktop_notifications, source_id, urgency, now_ms, display_choices_in_force.notification_show_milliseconds, title, body, label, cards_limit)
	if refusal != .None {
		return 0, refusal
	}
	desktop_damage_notifications()
	// The history shows the label too: "clock: the timer ended". The
	// label comes from the connection, so a card of the history names its
	// process as the banner does.
	// A labelled source keeps at most bar.NOTIFICATION_RECORDS_PER_SOURCE_LIMIT
	// records in the history: it cannot push the cards of the principal out.
	if len(label) == 0 {
		tray_notification_keep(title, body, source_id) // tray_widgets.odin
	} else {
		labelled: [notifications.MAX_LABEL_BYTES + 2 + notifications.MAX_TITLE_BYTES]u8
		count := copy(labelled[:], label)
		count += copy(labelled[count:], ": ")
		count += copy(labelled[count:], title)
		tray_notification_keep(labelled[:count], body, source_id, bar.NOTIFICATION_RECORDS_PER_SOURCE_LIMIT)
	}
	return id, .None
}
