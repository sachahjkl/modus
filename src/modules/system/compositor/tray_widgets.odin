// The tray widgets of the bar (src/md/features/tray_widgets.md): the
// button of the control center, the button of the notifications, the clock,
// and the card that each opens. The places and the rules are in
// src/library/internal/compositor/bar (tray_widgets.odin); this file draws
// the buttons and the cards, and does the act of each part.
package compositor

import "internal:compositor/bar"
import "modus:contract/accessibility"
import "modus:contract/date"
import "modus:contract/ring"
import "modus:contract/settings"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:system"

// The state of the buttons and of the open card.
tray_state: bar.Tray_State
// The notifications that the desktop showed, the newest first: the dot of
// the bell and the notification center read it.
notification_history: bar.Notification_History

// The shadow of a card of the bar, as menu_card_records draws it.
TRAY_CARD_SHADOW :: 3

// tray_widget_name gives the name of a widget as the export pointer says
// it in its field menu: empty for None.
tray_widget_name :: proc "contextless" (widget: bar.Tray_Widget) -> string {
	switch widget {
	case .None:
		return ""
	case .Control_Center:
		return "control_center"
	case .Notifications:
		return "notifications"
	case .Calendar:
		return "calendar"
	}
	return ""
}

// tray_local_seconds gives the local time in seconds since 1970 at the
// time now of the system, as the clock of the bar shows it; with no date,
// the seconds since the boot, and dated is false.
tray_local_seconds :: proc "contextless" (now: u64) -> (seconds: i64, dated: bool) {
	if milliseconds, known := date.milliseconds_now(date_page, now); known {
		return milliseconds / 1000 + date.zone_offset_seconds_read(date_page), true
	}
	return i64(now / 1000), false
}

// tray_card_damage records the room of the card of a widget with its
// shadow: the card of the notifications at its largest, so a history that
// shrinks leaves no row behind at either bar edge.
tray_card_damage :: proc "contextless" (widget: bar.Tray_Widget) {
	x, y, width, height := bar.tray_card(bar_layout, desktop_width, widget, bar.NOTIFICATION_HISTORY_CAPACITY)
	if width > 0 {
		damage_add(x, y - TRAY_CARD_SHADOW, width + TRAY_CARD_SHADOW, height + 2 * TRAY_CARD_SHADOW)
	}
}

// tray_others_close closes each other card of the desktop: one card shows
// at a time.
tray_others_close :: proc "contextless" () {
	menu_close() // start_menu.odin
	capture_popover_close() // capture.odin
	if desktop_context_menu.open {
		desktop_context_menu_damage() // desktop_features.odin
		desktop_context_menu.open = false
	}
}

// tray_widget_show opens the card of a widget and closes each other card,
// or closes the open card with None.
tray_widget_show :: proc "contextless" (widget: bar.Tray_Widget) {
	if widget == .None {
		tray_widget_close()
		return
	}
	before := tray_state.open
	tray_others_close()
	if bar.tray_open(&tray_state, widget) {
		tray_card_damage(before)
		tray_card_damage(widget)
		damage_bar()
	}
}

// tray_widget_close closes the open card, if one is open.
tray_widget_close :: proc "contextless" () {
	before := tray_state.open
	if bar.tray_open(&tray_state, .None) {
		tray_card_damage(before)
		damage_bar()
	}
}

// tray_widget_escape closes the open card on Escape. It reports whether a
// card was open: then the key goes to no window.
tray_widget_escape :: proc "contextless" () -> bool {
	if tray_state.open == .None {
		return false
	}
	tray_widget_close()
	return true
}

// tray_widgets_pointer_move lights the button and the part under the pointer.
tray_widgets_pointer_move :: proc "contextless" (x, y: int) {
	button_changed, part_changed := bar.tray_pointer_move(&tray_state, bar_layout, desktop_width, notification_history.count, x, y)
	if button_changed {
		damage_bar()
	}
	if part_changed {
		tray_card_damage(tray_state.open)
	}
}

// tray_widgets_press takes a press of the left button. It reports whether
// the tray widgets took it: then nothing under it receives it.
tray_widgets_press :: proc "contextless" (x, y: int) -> bool {
	before := tray_state.open
	press := bar.tray_press(&tray_state, bar_layout, desktop_width, notification_history.count, x, y)
	switch press.kind {
	case .Not_Taken:
		return false
	case .Opened:
		tray_others_close()
		tray_card_damage(before)
		tray_card_damage(press.widget)
		damage_bar()
	case .Closed:
		tray_card_damage(press.widget)
		damage_bar()
	case .Kept_Open:
	case .Part_Pressed:
		tray_card_damage(press.widget)
		if tray_state.open != before {
			damage_bar()
		}
		tray_part_do(press.part)
	}
	return true
}

// tray_part_do does the act of a part of a card, from a press or from Enter.
tray_part_do :: proc "contextless" (part: bar.Tray_Part) {
	switch part {
	case .None, .Display_Tile:
		// These parts say a state: they take no press.
	case .Appearance_Tile:
		appearance_next_ask()
	case .Bar_Edge_Tile:
		switch bar_layout.edge {
		case .Top:
			display_bar_edge_choose(.Bottom)
		case .Bottom:
			display_bar_edge_choose(.Top)
		}
	case .Magnifier_Tile:
		desktop_magnifier_toggle(i32(pointer_x), i32(pointer_y))
		tray_card_damage(.Control_Center)
	case .Launch_Settings, .Launch_Monitor, .Launch_Browser, .Launch_Edit:
		module, _ := bar.tray_part_module(part)
		packed := system.name_pack(module)
		system.send(&control.completions, ring.Record{kind = u32(display.Control.Start), values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}})
	case .Clear_All:
		if bar.notification_history_clear(&notification_history) {
			tray_state.chosen = .None
			damage_bar()
			tray_card_damage(.Notifications)
		}
	}
}

// tray_notification_keep copies a notification that the desktop showed
// into the history: the dot of the bell and an open notification center
// show it.
tray_notification_keep :: proc "contextless" (title, body: []u8, source: u64, source_limit := 0) {
	seconds, dated := tray_local_seconds(system.time())
	if bar.notification_history_add(&notification_history, string(title), string(body), seconds, dated, source, source_limit) {
		damage_bar()
		if tray_state.open == .Notifications {
			tray_card_damage(.Notifications)
		}
	}
}

// tray_widgets_second draws the calendar again at each second of the
// clock: its foot shows the time since the boot.
tray_widgets_second :: proc "contextless" () {
	if tray_state.open == .Calendar {
		tray_card_damage(.Calendar)
	}
}

// tray_button_plate_records appends the plate of a tray button or of the
// clock: flat on the bar at rest, a quiet plate under the pointer, the
// chosen blue while its card is open. It gives the colors of the content.
tray_button_plate_records :: proc "contextless" (table: ^interface.Draw_Table, widget: bar.Tray_Widget) -> (color, accent: graphics.Color) {
	x, y, width, height := bar.tray_widget_button(bar_layout, desktop_width, widget)
	if tray_state.open == widget {
		interface.draw_vertical_gradient(table, x, y, width, height, graphics.shade(graphics.colors.chosen, 112), graphics.shade(graphics.colors.chosen, 88))
		interface.draw_rectangle(table, x, y, width, 1, graphics.shade(graphics.colors.chosen, 140))
		return graphics.COLOR_WHITE, graphics.COLOR_WHITE
	}
	if tray_state.hovered == widget {
		interface.draw_vertical_gradient(table, x, y, width, height, graphics.shade(graphics.colors.card_top, 125), graphics.colors.card_bottom)
		interface.draw_outline(table, x, y, width, height, 1, graphics.colors.track)
		interface.draw_rectangle(table, x + 1, y + 1, width - 2, 1, graphics.shade(graphics.colors.card_top, 140))
	}
	return graphics.colors.text, graphics.colors.title
}

// tray_clock_plate_records appends the plate of the clock, under its text,
// and gives the colors of the text and of its separators.
tray_clock_plate_records :: proc "contextless" (table: ^interface.Draw_Table) -> (text, separator: graphics.Color) {
	color, _ := tray_button_plate_records(table, .Calendar)
	if tray_state.open == .Calendar {
		return color, color
	}
	return graphics.colors.text, graphics.colors.dim
}

// tray_buttons_records appends the button of the control center and the
// button of the notifications. The bell has a square of the coral of a
// failure at its top right while the history holds a notification.
tray_buttons_records :: proc "contextless" (table: ^interface.Draw_Table) {
	icons := [2]struct {
		widget: bar.Tray_Widget,
		icon:   bar.Icon,
		name:   string,
	}{{.Control_Center, .Switches, "control center"}, {.Notifications, .Bell, "notifications"}}
	for item in icons {
		x, y, width, height := bar.tray_widget_button(bar_layout, desktop_width, item.widget)
		interface.draw_element_push(table, {x, y, width, height}, u32(interface.identity(item.name)), .Button, {name = item.name, expanded = tray_state.open == item.widget ? .Expanded : .Collapsed})
		color, accent := tray_button_plate_records(table, item.widget)
		icon_x, icon_y := x + (width - bar.ICON_SIZE) / 2, y + (height - bar.ICON_SIZE) / 2
		bar.icon_records(table, icon_x, icon_y, item.icon, color, accent)
		if item.widget == .Notifications && notification_history.count > 0 {
			interface.draw_rectangle(table, icon_x + bar.ICON_SIZE - 4, icon_y, 4, 4, graphics.colors.failed)
		}
		interface.draw_element_pop(table)
	}
}

// tray_card_records appends the open card over the desktop.
tray_card_records :: proc "contextless" (table: ^interface.Draw_Table) {
	widget := tray_state.open
	if widget == .None {
		return
	}
	x, y, width, height := bar.tray_card(bar_layout, desktop_width, widget, notification_history.count)
	name := tray_widget_name(widget)
	interface.draw_element_push(table, {x, y, width, height}, u32(interface.identity(name)), .Dialog, {name = name})
	defer interface.draw_element_pop(table)
	menu_card_records(table, x, y, width, height) // start_menu.odin
	switch widget {
	case .None:
	case .Control_Center:
		control_center_records(table, x, y, width)
	case .Notifications:
		notification_center_records(table, x, y, width)
	case .Calendar:
		calendar_records(table, x, y, width, height)
	}
}

// control_center_tile_records appends one tile: a plate of the chosen blue
// while its switch is on, else a plate sunk in the card; a border of the
// title blue under the pointer for a tile that a press changes. Its icon,
// its name, and under the name its value.
control_center_tile_records :: proc "contextless" (table: ^interface.Draw_Table, part: bar.Tray_Part, icon: bar.Icon, name, value: string, on: bool) {
	x, y, width, height, ok := bar.tray_part_place(bar_layout, desktop_width, part, notification_history.count)
	if !ok {
		return
	}
	pressable := bar.tray_part_takes_press(part)
	hovered := pressable && tray_state.chosen == part
	role := pressable ? accessibility.Element_Role.Switch : accessibility.Element_Role.Group
	interface.draw_element_push(table, {x, y, width, height}, u32(interface.identity(name)), role, {name = name, value_text = value, toggle = pressable ? (on ? .True : .False) : .None})
	defer interface.draw_element_pop(table)
	color, accent, value_color := graphics.colors.text_strong, graphics.colors.title, graphics.colors.dim
	if on {
		chosen := graphics.colors.chosen
		interface.draw_vertical_gradient(table, x, y, width, height, graphics.shade(chosen, hovered ? 128 : 114), graphics.shade(chosen, hovered ? 100 : 88))
		interface.draw_outline(table, x, y, width, height, 1, hovered ? graphics.COLOR_WHITE : graphics.shade(chosen, 70))
		interface.draw_rectangle(table, x + 1, y + 1, width - 2, 1, graphics.shade(chosen, 150))
		color, accent, value_color = graphics.COLOR_WHITE, graphics.COLOR_WHITE, graphics.COLOR_WHITE
	} else {
		interface.draw_rectangle(table, x, y, width, height, graphics.colors.recess)
		interface.draw_outline(table, x, y, width, height, 1, hovered ? graphics.colors.title : graphics.colors.track)
		interface.draw_rectangle(table, x + 1, y + 1, width - 2, 1, graphics.colors.shadow)
	}
	TILE_INSET :: 10
	bar.icon_records(table, x + TILE_INSET, y + TILE_INSET, icon, color, accent)
	text_x := x + TILE_INSET + bar.ICON_SIZE + bar.ICON_GAP
	room := x + width - TILE_INSET - text_x
	interface.draw_text(table, text_x, y + 9, interface.text_fit(table, interface.FONT_INTERFACE, name, room), color, interface.FONT_INTERFACE)
	interface.draw_text(table, text_x, y + 31, interface.text_fit(table, interface.FONT_CAPTION, value, room), value_color, interface.FONT_CAPTION)
}

// control_center_records appends the four tiles, the groove under them and
// the four launch buttons.
control_center_records :: proc "contextless" (table: ^interface.Draw_Table, x, y, width: int) {
	appearance := graphics.appearance == .Dark ? "Dark" : "Light"
	control_center_tile_records(table, .Appearance_Tile, .Contrast, "Appearance", appearance, false)
	edge := "Top"
	switch bar_layout.edge {
	case .Top:
	case .Bottom:
		edge = "Bottom"
	}
	control_center_tile_records(table, .Bar_Edge_Tile, .Bar_Edge, "Bar", edge, false)
	magnified := desktop_magnifier.enabled
	control_center_tile_records(table, .Magnifier_Tile, .Magnifier, "Magnifier", magnified ? "On" : "Off", magnified)
	size: [32]u8
	size_writer := system.Writer{buffer = size[:]}
	system.write_unsigned(&size_writer, u64(screen.width))
	system.write_part(&size_writer, "×")
	system.write_unsigned(&size_writer, u64(screen.height))
	control_center_tile_records(table, .Display_Tile, .Window, gpu_present ? "VirtIO-GPU 1.2" : "Processor", system.written(&size_writer), gpu_attached)
	// A groove: a dark line and a line of light.
	groove_y := bar.control_center_hairline_y(y)
	groove_x, groove_width := x + bar.BORDER + bar.CONTROL_PADDING, width - 2 * bar.BORDER - 2 * bar.CONTROL_PADDING
	interface.draw_rectangle(table, groove_x, groove_y, groove_width, 1, graphics.colors.track)
	interface.draw_rectangle(table, groove_x, groove_y + 1, groove_width, 1, graphics.shade(graphics.colors.card_top, 125))
	launches := [4]struct {
		part: bar.Tray_Part,
		icon: bar.Icon,
	}{{.Launch_Settings, .Settings}, {.Launch_Monitor, .Monitor}, {.Launch_Browser, .Globe}, {.Launch_Edit, .Document}}
	for launch in launches {
		launch_x, launch_y, launch_width, launch_height, ok := bar.tray_part_place(bar_layout, desktop_width, launch.part, notification_history.count)
		if !ok {
			continue
		}
		_, label := bar.tray_part_module(launch.part)
		interface.draw_element_push(table, {launch_x, launch_y, launch_width, launch_height}, u32(interface.identity(label)), .Button, {name = label})
		color, accent := graphics.colors.text, graphics.colors.title
		if tray_state.chosen == launch.part {
			interface.draw_vertical_gradient(table, launch_x, launch_y, launch_width, launch_height, graphics.shade(graphics.colors.chosen, 112), graphics.shade(graphics.colors.chosen, 88))
			interface.draw_rectangle(table, launch_x, launch_y, launch_width, 1, graphics.shade(graphics.colors.chosen, 140))
			color, accent = graphics.COLOR_WHITE, graphics.COLOR_WHITE
		} else {
			interface.draw_vertical_gradient(table, launch_x, launch_y, launch_width, launch_height, graphics.shade(graphics.colors.card_top, 118), graphics.colors.card_bottom)
			interface.draw_outline(table, launch_x, launch_y, launch_width, launch_height, 1, graphics.colors.track)
			interface.draw_rectangle(table, launch_x + 1, launch_y + 1, launch_width - 2, 1, graphics.shade(graphics.colors.card_top, 140))
		}
		bar.icon_records(table, launch_x + (launch_width - bar.ICON_SIZE) / 2, launch_y + 7, launch.icon, color, accent)
		shown := interface.text_fit(table, interface.FONT_CAPTION, label, launch_width - 8)
		label_width := interface.text_measured_width(table, interface.FONT_CAPTION, shown)
		interface.draw_text(table, launch_x + (launch_width - label_width) / 2, launch_y + 27, shown, color, interface.FONT_CAPTION)
		interface.draw_element_pop(table)
	}
}

// notification_center_records appends the history: a head with its
// caption and the button Clear all, then one row for each notification
// with its title, its time and its body; one line with no notification.
notification_center_records :: proc "contextless" (table: ^interface.Draw_Table, x, y, width: int) {
	count := notification_history.count
	if count == 0 {
		interface.draw_text(table, x + bar.BORDER + 2 * bar.PADDING, y + bar.BORDER + (bar.NOTIFICATION_EMPTY_HEIGHT - graphics.CELL_HEIGHT) / 2, "No notifications", graphics.colors.dim, interface.FONT_INTERFACE)
		return
	}
	head_y := y + bar.BORDER + (bar.NOTIFICATION_HEAD_HEIGHT - graphics.CELL_HEIGHT) / 2
	interface.draw_text(table, x + bar.BORDER + bar.PADDING, head_y, "notifications", graphics.colors.dim, interface.FONT_CAPTION)
	interface.draw_rectangle(table, x + bar.BORDER + bar.PADDING, y + bar.BORDER + bar.NOTIFICATION_HEAD_HEIGHT - 4, width - 2 * bar.BORDER - 2 * bar.PADDING, 1, graphics.colors.track)
	if button_x, button_y, button_width, button_height, ok := bar.tray_part_place(bar_layout, desktop_width, .Clear_All, count); ok {
		// The plate of a button of a card, as the button that revokes a grant.
		interface.draw_element_push(table, {button_x, button_y, button_width, button_height}, u32(interface.identity(bar.CLEAR_ALL_LABEL)), .Button, {name = bar.CLEAR_ALL_LABEL})
		track := graphics.colors.track
		if tray_state.chosen == .Clear_All {
			track = graphics.shade(track, 130)
		}
		interface.draw_vertical_gradient(table, button_x, button_y, button_width, button_height, track, graphics.shade(track, 88))
		interface.draw_outline(table, button_x, button_y, button_width, button_height, 1, tray_state.chosen == .Clear_All ? graphics.colors.title : graphics.shade(graphics.colors.track, 150))
		label_width := interface.text_measured_width(table, interface.FONT_INTERFACE, bar.CLEAR_ALL_LABEL)
		interface.draw_text(table, button_x + (button_width - label_width) / 2, button_y + (button_height - graphics.CELL_HEIGHT) / 2, bar.CLEAR_ALL_LABEL, graphics.colors.text_strong, interface.FONT_INTERFACE)
		interface.draw_element_pop(table)
	}
	for index in 0 ..< count {
		row_x, row_y, row_width, row_height, ok := bar.notification_row(bar_layout, desktop_width, count, index)
		if !ok {
			continue
		}
		record := &notification_history.records[index]
		time_buffer: [8]u8
		time := bar.notification_time_text(record, &time_buffer)
		time_width := interface.text_measured_width(table, interface.FONT_CAPTION_CELLS, time)
		text_x := row_x + bar.PADDING
		right := row_x + row_width - bar.PADDING
		title := interface.text_fit(table, interface.FONT_INTERFACE, bar.notification_title(record), right - time_width - bar.PADDING - text_x)
		interface.draw_text(table, text_x, row_y + 8, title, graphics.colors.text_strong, interface.FONT_INTERFACE)
		interface.draw_text_right(table, right, interface.text_top_on_baseline(table, interface.FONT_INTERFACE, row_y + 8, interface.FONT_CAPTION_CELLS), time, graphics.colors.dim, interface.FONT_CAPTION_CELLS)
		if body := bar.notification_body(record); body != "" {
			interface.draw_text(table, text_x, row_y + 28, interface.text_fit(table, interface.FONT_INTERFACE, body, right - text_x), graphics.colors.dim, interface.FONT_INTERFACE)
		}
		if index + 1 < count {
			interface.draw_rectangle(table, text_x, row_y + row_height - 1, right - text_x, 1, graphics.colors.track)
		}
	}
}

// calendar_records appends the month of today: its name and its year, the
// days of the week, the grid on a recessed plate with today on the chosen
// blue, then a foot with the time zone and the time since the boot. With
// no date, the card says so, and its foot gives the time since the boot.
calendar_records :: proc "contextless" (table: ^interface.Draw_Table, x, y, width, height: int) {
	now := system.time()
	local, dated := tray_local_seconds(now)
	grid_x, grid_y, grid_width, grid_height := bar.calendar_grid(bar_layout, desktop_width)
	head_x := grid_x + bar.CALENDAR_GRID_INSET + 4
	head_y := y + bar.BORDER + bar.CALENDAR_PADDING
	if !dated {
		interface.draw_text(table, head_x, head_y, "No date", graphics.colors.dim, interface.FONT_INTERFACE)
	} else {
		month := bar.calendar_month_of(local)
		title_buffer: [32]u8
		interface.draw_text(table, head_x, head_y, bar.calendar_title(month, &title_buffer), graphics.colors.text_strong, interface.FONT_INTERFACE_BOLD)
		for name, column in bar.CALENDAR_WEEKDAYS {
			cell_x, _, cell_width, _, _ := bar.calendar_cell_place(bar_layout, desktop_width, 0, column)
			name_width := interface.text_measured_width(table, interface.FONT_CAPTION, name)
			interface.draw_text(table, cell_x + (cell_width - name_width) / 2, grid_y - bar.CALENDAR_WEEKDAY_HEIGHT + 2, name, graphics.colors.dim, interface.FONT_CAPTION)
		}
		interface.draw_rectangle(table, grid_x, grid_y, grid_width, grid_height, graphics.colors.recess)
		interface.draw_outline(table, grid_x, grid_y, grid_width, grid_height, 1, graphics.colors.track)
		interface.draw_rectangle(table, grid_x + 1, grid_y + 1, grid_width - 2, 1, graphics.colors.shadow)
		today_row, today_column := bar.calendar_today_cell(month)
		for row in 0 ..< bar.CALENDAR_ROWS {
			for column in 0 ..< bar.CALENDAR_COLUMNS {
				cell_x, cell_y, cell_width, cell_height, _ := bar.calendar_cell_place(bar_layout, desktop_width, row, column)
				day, in_month := bar.calendar_cell(month, row, column)
				color := in_month ? graphics.colors.text : graphics.colors.dim
				if row == today_row && column == today_column {
					chosen := graphics.colors.chosen
					interface.draw_vertical_gradient(table, cell_x + 2, cell_y + 1, cell_width - 4, cell_height - 2, graphics.shade(chosen, 112), graphics.shade(chosen, 88))
					interface.draw_rectangle(table, cell_x + 2, cell_y + 1, cell_width - 4, 1, graphics.shade(chosen, 145))
					color = graphics.COLOR_WHITE
				}
				digits: interface.Text_Builder
				text := interface.number_text(&digits, u64(day))
				text_width := interface.text_measured_width(table, {}, text)
				interface.draw_text(table, cell_x + (cell_width - text_width) / 2, cell_y + (cell_height - graphics.CELL_HEIGHT) / 2, text, color)
			}
		}
	}
	// The foot: the zone at the left, the time since the boot at the right.
	foot_y := grid_y + grid_height + (bar.CALENDAR_FOOT_HEIGHT - graphics.CELL_HEIGHT) / 2
	if dated {
		zone_buffer: [settings.ZONE_TEXT_SIZE]u8
		zone: [16]u8
		zone_writer := system.Writer{buffer = zone[:]}
		system.write_part(&zone_writer, "UTC")
		system.write_part(&zone_writer, settings.zone_text(zone_buffer[:], i32(date.zone_offset_seconds_read(date_page) / 60)))
		interface.draw_text(table, grid_x + bar.CALENDAR_GRID_INSET, foot_y, system.written(&zone_writer), graphics.colors.dim)
	}
	seconds := now / 1000
	uptime: [32]u8
	uptime_writer := system.Writer{buffer = uptime[:]}
	system.write_part(&uptime_writer, "up ")
	two_digits :: proc "contextless" (writer: ^system.Writer, value: u64) {
		if value < 10 {
			system.write_part(writer, "0")
		}
		system.write_unsigned(writer, value)
	}
	two_digits(&uptime_writer, seconds / 3600)
	system.write_part(&uptime_writer, ":")
	two_digits(&uptime_writer, seconds / 60 % 60)
	system.write_part(&uptime_writer, ":")
	two_digits(&uptime_writer, seconds % 60)
	interface.draw_text_right(table, grid_x + grid_width - bar.CALENDAR_GRID_INSET, foot_y, system.written(&uptime_writer), graphics.colors.dim)
	_ = height
}
// The act name of the button of the appearance in force in the window of
// settings (src/modules/system/settings, value_button).
APPEARANCE_ACT_NAME :: "settings.set:appearance"

// appearance_next_ask takes a press on the tile Appearance: the next
// appearance, auto, dark, light. The page has one writer, the process
// settings, and only the root service knows which process that is: an act
// name is a claim that any window can make. So the compositor always asks
// the root service, which starts settings for the pass of the next
// appearance, or answers Settings_Raise for the window of settings that
// runs. The tile shows the new appearance when the page changes.
appearance_next_ask :: proc "contextless" () {
	if !system.send(&control.completions, ring.Record{kind = u32(display.Control.Appearance_Next)}) {
		system.log_fact(.Warning, Appearance_Tile_Ring_Full{})
		return
	}
	system.log_fact(.Info, Appearance_Tile_Asks_Next{})
}

// settings_raise takes Settings_Raise of the root service: it raises the
// window of settings that the root service started, in place of a second
// process settings. For the tile Appearance it puts the focus on the
// appearance in force, where Enter on another value sets it. A focus word
// that names no member, or a handle that names no window (the window
// closed since the answer), is refused.
settings_raise :: proc "contextless" (word: u64, focus_word: u64) {
	focus, focus_ok := display.settings_raise_focus_of_word(focus_word)
	if !focus_ok {
		system.log_fact(.Info, Settings_Raise_Focus_Refused{word = focus_word})
		return
	}
	ring_memories: [CLIENT_CAPACITY]u32
	for position in 0 ..< order_count {
		ring_memories[position] = u32(clients[order[position]].ring_memory)
	}
	position, found := bar.settings_raise_target(ring_memories[:order_count], word)
	if !found {
		system.log_fact(.Info, Settings_Raise_Without_Window{})
		return
	}
	index := order[position]
	raise(position)
	switch focus {
	case .Keep:
		system.log_fact(.Info, Settings_Window_Raised{})
	case .Appearance:
		send(&clients[index], .Go_To, {0 = u64(display.act_name_hash(APPEARANCE_ACT_NAME))})
		system.log_fact(.Info, Appearance_Tile_Goes_To_Settings{})
	}
}
