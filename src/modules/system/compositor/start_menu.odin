// The heron button, the button of the windows, and the two menus that they
// open: the start menu, in two panes, and the menu of the windows. The bar
// package gives each place (src/library/internal/compositor/bar); the
// design of the look is src/md/features/desktop_shell_look.md.
package compositor

import "internal:compositor/bar"
import "modus:contract/ring"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:system"

// The look of the heron button. Each look has its own picture of the heron
// on its plate (bar_mark_build in main.odin).
Start_Button_Look :: enum u8 {
	Rest,
	Hover, // The pointer is over the button.
	Open, // The start menu is open: the plate is pressed in.
}

// start_button_look gives the look of the heron button in this frame.
start_button_look :: proc "contextless" () -> Start_Button_Look {
	if menu_open == .Start {
		return .Open
	}
	if bar_button_hovered == .Start {
		return .Hover
	}
	return .Rest
}

// start_button_records appends the plate of the heron button with its
// corner at (x, y): a night-blue plate, so the blue body of the heron
// stands out in both appearances; a dark outline, a line of light under
// its top edge, and a pressed plate with an accent at its foot while the
// start menu is open.
start_button_records :: proc "contextless" (table: ^interface.Draw_Table, x, y: int, look: Start_Button_Look) {
	width, height := bar.START_BUTTON_WIDTH, bar.PLATE_HEIGHT
	title, title_end := graphics.colors.title, graphics.colors.title_end
	interface.draw_rectangle(table, x, y, width, height, graphics.shade(title_end, 55))
	switch look {
	case .Rest:
		interface.draw_vertical_gradient(table, x + 1, y + 1, width - 2, height - 2, graphics.mix(title, title_end, 150), graphics.shade(title_end, 85))
		interface.draw_rectangle(table, x + 1, y + 1, width - 2, 1, graphics.mix(title, title_end, 90))
	case .Hover:
		interface.draw_vertical_gradient(table, x + 1, y + 1, width - 2, height - 2, graphics.mix(title, title_end, 110), graphics.mix(title, title_end, 210))
		interface.draw_rectangle(table, x + 1, y + 1, width - 2, 1, graphics.shade(title, 125))
	case .Open:
		interface.draw_vertical_gradient(table, x + 1, y + 1, width - 2, height - 2, graphics.shade(title_end, 70), graphics.mix(title, title_end, 140))
		interface.draw_rectangle(table, x + 1, y + 1, width - 2, 1, graphics.shade(title_end, 50))
		interface.draw_rectangle(table, x + 1, y + height - 3, width - 2, 2, graphics.shade(title, 150))
	}
}

// windows_button_records appends the button of the windows: the icon of a
// list, flat on the bar at rest, on a quiet plate under the pointer, on the
// chosen blue while its menu is open.
windows_button_records :: proc "contextless" (table: ^interface.Draw_Table) {
	x, y, width, height := bar.windows_button(bar_layout)
	color, accent := graphics.colors.text, graphics.colors.title
	if menu_open == .Windows {
		interface.draw_vertical_gradient(table, x, y, width, height, graphics.shade(graphics.colors.chosen, 112), graphics.shade(graphics.colors.chosen, 88))
		interface.draw_rectangle(table, x, y, width, 1, graphics.shade(graphics.colors.chosen, 140))
		color, accent = graphics.COLOR_WHITE, graphics.COLOR_WHITE
	} else if bar_button_hovered == .Windows {
		interface.draw_vertical_gradient(table, x, y, width, height, graphics.shade(graphics.colors.card_top, 125), graphics.colors.card_bottom)
		interface.draw_outline(table, x, y, width, height, 1, graphics.colors.track)
	}
	bar.icon_records(table, x + (width - bar.ICON_SIZE) / 2, y + (height - bar.ICON_SIZE) / 2, .Windows_List, color, accent)
	// The divider between the buttons and the plates of the windows: a dark
	// line and a line of light, as a groove in the bar.
	bar_top := desktop_bar_y()
	interface.draw_rectangle(table, bar.DIVIDER_X, bar_top + 6, 1, BAR_HEIGHT - 12, graphics.colors.track)
	interface.draw_rectangle(table, bar.DIVIDER_X + 1, bar_top + 6, 1, BAR_HEIGHT - 12, graphics.shade(graphics.colors.card_top, 125))
}

// menu_card_records appends the card of a menu of the bar: a sharp shadow
// on its side away from the bar, a border of the edge, the gradient of the
// cards and a line of light under its top edge. The shadow never falls on
// the bar.
menu_card_records :: proc "contextless" (table: ^interface.Draw_Table, x, y, width, height: int) {
	SHADOW :: 3
	shadow := graphics.colors.shadow
	interface.draw_rectangle(table, x + width, y + SHADOW, SHADOW, height - SHADOW, shadow)
	switch bar_layout.edge {
	case .Top:
		interface.draw_rectangle(table, x + SHADOW, y + height, width, SHADOW, shadow)
	case .Bottom:
		// The menu ends on the bar: its shadow is on its right side only.
	}
	interface.draw_rectangle(table, x, y, width, height, graphics.colors.edge)
	interface.draw_vertical_gradient(table, x + bar.BORDER, y + bar.BORDER, width - 2 * bar.BORDER, height - 2 * bar.BORDER, graphics.colors.card_top, graphics.colors.card_bottom)
	interface.draw_rectangle(table, x + bar.BORDER, y + bar.BORDER, width - 2 * bar.BORDER, 1, graphics.shade(graphics.colors.card_top, 135))
}

// menu_line_records appends one line of a menu: the chosen blue under the
// pointer, the icon, then the name, both in the middle of the line.
menu_line_records :: proc "contextless" (table: ^interface.Draw_Table, x, y, width, height: int, icon: bar.Icon, name: string, chosen: bool) {
	color, accent := graphics.colors.text, graphics.colors.title
	if chosen {
		interface.draw_rectangle(table, x, y, width, height, graphics.colors.chosen)
		interface.draw_rectangle(table, x, y, width, 1, graphics.shade(graphics.colors.chosen, 130))
		color, accent = graphics.COLOR_WHITE, graphics.shade(graphics.colors.chosen, 175)
	}
	bar.icon_records(table, x + bar.PADDING, y + (height - bar.ICON_SIZE) / 2, icon, color, accent)
	text_x := x + bar.PADDING + bar.ICON_SIZE + bar.ICON_GAP
	shown := interface.text_fit(table, interface.FONT_INTERFACE, name, x + width - bar.PADDING - text_x)
	interface.draw_text(table, text_x, y + (height - graphics.CELL_HEIGHT) / 2, shown, chosen ? graphics.COLOR_WHITE : color, interface.FONT_INTERFACE)
}

// The labels of the quick actions of the start menu.
START_ACTION_BAR_TO_BOTTOM :: "bar to bottom"
START_ACTION_BAR_TO_TOP :: "bar to top"
START_ACTION_MAGNIFIER :: "magnifier"

// start_menu_records appends the start menu: the pinned modules and the
// quick actions in the left pane, all other modules under their heading
// in the darker right pane.
start_menu_records :: proc "contextless" (table: ^interface.Draw_Table) {
	x, y, width, height := bar.menu(bar_layout)
	interface.draw_element_push(table, {x, y, width, height}, u32(interface.identity("start menu")), .Menu, {name = "start menu"})
	defer interface.draw_element_pop(table)
	menu_card_records(table, x, y, width, height)
	pane_x, pane_y, pane_width, pane_height := bar.right_pane(bar_layout)
	interface.draw_rectangle(table, pane_x - 1, pane_y, 1, pane_height, graphics.colors.track)
	interface.draw_vertical_gradient(table, pane_x, pane_y, pane_width, pane_height, graphics.mix(graphics.colors.card_bottom, graphics.colors.background, 128), graphics.colors.background)
	heading_y := pane_y + bar.PANE_PADDING
	interface.draw_text(table, pane_x + bar.PANE_PADDING + bar.PADDING, heading_y + 4, "all modules", graphics.colors.dim, interface.FONT_CAPTION)
	interface.draw_rectangle(table, pane_x + bar.PANE_PADDING, heading_y + bar.HEADING_HEIGHT - 4, pane_width - 2 * bar.PANE_PADDING, 1, graphics.colors.track)
	for name, index in bar.names {
		line_x, line_y, line_width, line_height := bar.line(bar_layout, index)
		menu_line_records(table, line_x, line_y, line_width, line_height, bar.name_icons[index], name, index == menu_line)
	}
	// The quick actions, under a hairline at the foot of the left pane.
	first_x, first_y, first_width, _ := bar.action_line(bar_layout, .Bar_Edge)
	interface.draw_rectangle(table, first_x, first_y - bar.ACTIONS_GAP / 2, first_width, 1, graphics.colors.track)
	for action in bar.Start_Action {
		label: string
		icon: bar.Icon
		switch action {
		case .None:
			continue
		case .Bar_Edge:
			icon = .Bar_Edge
			switch bar_layout.edge {
			case .Top:
				label = START_ACTION_BAR_TO_BOTTOM
			case .Bottom:
				label = START_ACTION_BAR_TO_TOP
			}
		case .Magnifier:
			icon, label = .Magnifier, START_ACTION_MAGNIFIER
		}
		line_x, line_y, line_width, line_height := bar.action_line(bar_layout, action)
		menu_line_records(table, line_x, line_y, line_width, line_height, icon, label, action == menu_action)
	}
}

// menu_show opens a menu of the bar, with no line chosen.
menu_show :: proc "contextless" (menu: Menu) {
	menu_open, menu_line, menu_action = menu, -1, .None
	switch menu {
	case .None:
	case .Start:
		system.log_fact(.Info, Start_Menu_Open{})
	case .Windows:
		windows_log()
	}
	damage_menu()
}

// menu_close closes the menu of the bar that is open, and does nothing.
menu_close :: proc "contextless" () {
	if menu_open == .None {
		return
	}
	menu_open, menu_line, menu_action = .None, -1, .None
	damage_menu()
}

// menu_choice_do does the chosen line of the open menu, from a press of the
// pointer or from Enter, then closes the menu: a line of the start menu
// starts its module, a quick action acts, a line of the menu of the windows
// brings its window to the front. With no line chosen, the menu closes
// alone.
menu_choice_do :: proc "contextless" () {
	if menu_open == .Start && menu_line >= 0 && menu_line < len(bar.names) {
		packed := system.name_pack(bar.names[menu_line])
		system.send(&control.completions, ring.Record{kind = u32(display.Control.Start), values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}})
	}
	if index := window_of_line(menu_line); menu_open == .Windows && menu_line >= 0 && index >= 0 {
		if clients[index].minimized {
			clients[index].minimized = false
			damage_whole_screen()
		}
		for position in 0 ..< order_count {
			if order[position] == index {
				raise(position)
				break
			}
		}
		system.log_fact(.Info, Window_In_Front{window = window_field(clients[index].title[:])})
	}
	chosen_action := menu_open == .Start ? menu_action : bar.Start_Action.None
	menu_close()
	start_action_do(chosen_action)
}

// start_action_do does a quick action of the start menu.
start_action_do :: proc "contextless" (action: bar.Start_Action) {
	switch action {
	case .None:
	case .Bar_Edge:
		switch bar_layout.edge {
		case .Top:
			desktop_bar_position_set(.Bottom)
		case .Bottom:
			desktop_bar_position_set(.Top)
		}
	case .Magnifier:
		desktop_magnifier_toggle(i32(pointer_x), i32(pointer_y))
	}
}

// windows_menu_records appends the menu of the windows: a heading with the
// count of the windows, then one line for each window, with its icon and
// its title; the window in front has a bar of the title blue at the left
// of its line, and its title in white.
windows_menu_records :: proc "contextless" (table: ^interface.Draw_Table) {
	x, y, width, height := bar.windows_menu(bar_layout, order_count)
	interface.draw_element_push(table, {x, y, width, height}, u32(interface.identity("windows menu")), .Menu, {name = "windows"})
	defer interface.draw_element_pop(table)
	menu_card_records(table, x, y, width, height)
	heading_y := y + bar.BORDER + (bar.TITLE - graphics.CELL_HEIGHT) / 2
	interface.draw_text(table, x + bar.BORDER + bar.WINDOWS_ICON_X, heading_y, "windows", graphics.colors.dim, interface.FONT_CAPTION)
	count: interface.Text_Builder
	interface.draw_text_right(table, x + width - bar.BORDER - bar.PADDING, heading_y, interface.number_text(&count, u64(order_count)), graphics.colors.text)
	interface.draw_rectangle(table, x + bar.BORDER + bar.PADDING, y + bar.BORDER + bar.TITLE - 4, width - 2 * bar.BORDER - 2 * bar.PADDING, 1, graphics.colors.track)
	for line in 0 ..< order_count {
		index := window_of_line(line)
		if index < 0 {
			break
		}
		line_x, line_y, line_width, line_height := bar.windows_line(bar_layout, line)
		focus := index == order[order_count - 1]
		chosen := line == menu_line
		color, accent := graphics.colors.text, graphics.colors.title
		if chosen {
			interface.draw_rectangle(table, line_x, line_y, line_width, line_height, graphics.colors.chosen)
			color, accent = graphics.COLOR_WHITE, graphics.shade(graphics.colors.chosen, 175)
		}
		if focus {
			interface.draw_rectangle(table, line_x + 2, line_y + 4, 2, line_height - 8, chosen ? graphics.COLOR_WHITE : graphics.colors.title)
		}
		bar.icon_records(table, line_x + bar.WINDOWS_ICON_X, line_y + (line_height - bar.ICON_SIZE) / 2, clients[index].icon, color, accent)
		// A disk process keeps the room of its hash prefix at the end of
		// the line: the nickname ends before it.
		room := line_width - bar.WINDOWS_TITLE_X - bar.PADDING
		if clients[index].from_disk {
			room -= bar.WINDOWS_HASH_GAP + interface.text_measured_width(table, interface.FONT_CAPTION_CELLS, string(clients[index].hash_prefix[:]))
		}
		text_y := line_y + (line_height - graphics.CELL_HEIGHT) / 2
		title := interface.text_fit(table, interface.FONT_INTERFACE, system.name_of(clients[index].title[:]), room)
		// The window in front has more weight than the others: the strong
		// text on the card, white only on the chosen blue.
		title_color := color
		if focus {
			title_color = graphics.colors.text_strong
		}
		if chosen {
			title_color = graphics.COLOR_WHITE
		}
		title_end := interface.draw_text(table, line_x + bar.WINDOWS_TITLE_X, text_y, title, title_color, interface.FONT_INTERFACE)
		if clients[index].from_disk {
			// A value, in the font of the cells at the caption size,
			// faded, on the baseline of the nickname: the name is the
			// nickname, and the prefix only tells two files apart. On the
			// chosen row it is white, as each text of that row: the dim
			// color has no contrast on the chosen blue.
			prefix_top := interface.text_top_on_baseline(table, interface.FONT_INTERFACE, text_y, interface.FONT_CAPTION_CELLS)
			interface.draw_text(table, title_end + bar.WINDOWS_HASH_GAP, prefix_top, string(clients[index].hash_prefix[:]), chosen ? graphics.COLOR_WHITE : graphics.colors.dim, interface.FONT_CAPTION_CELLS)
		}
	}
}
