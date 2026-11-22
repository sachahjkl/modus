package compositor

import "internal:compositor/bar"
import "modus:graphics"
import "modus:interface"
import "modus:system"

// The window switcher of the desktop (src/md/features/window_switcher.md):
// Alt+Tab and Alt+Shift+Tab. The rules are pure in
// src/library/internal/compositor/bar (window_switcher.odin); this file
// holds their state and their effects. The order of the windows from the
// front is the order of use: each window that comes to the front goes to
// the end of order.

window_switcher: bar.Window_Switcher

// window_switcher_key takes a key for the switcher. It gives true when the
// key goes to no window. The palette and the modes of the keys of the
// desktop hold the keys while they are open, so the switcher does not open
// over them.
window_switcher_key :: proc "contextless" (code: u32, pressed: bool, modifiers: u32) -> bool {
	if !window_switcher.open && (palette_is_open() || keyboard_window_mode != .None || bar_focus.kind != .None) {
		return false
	}
	opened := window_switcher.open
	outcome := bar.switcher_key(&window_switcher, code, pressed, modifiers, order_count)
	if outcome.changed {
		window_switcher_damage()
	}
	if !opened && window_switcher.open {
		system.log_fact(.Info, Window_Switcher_Opened{windows = u64(order_count)})
	}
	if outcome.finish && outcome.chosen >= 0 && outcome.chosen < order_count {
		position := order_count - 1 - outcome.chosen
		client := &clients[order[position]]
		if client.minimized {
			client.minimized = false
			damage_whole_screen()
		}
		raise(position)
		system.log_fact(.Info, Window_Switched{window = window_field(client.title[:])})
	}
	return outcome.taken
}

// window_switcher_cancel closes the card with no change, at a press of the
// pointer.
window_switcher_cancel :: proc "contextless" () {
	if bar.switcher_cancel(&window_switcher) {
		window_switcher_damage()
	}
}

// window_switcher_damage records the room of the card for the most lines
// it can have.
window_switcher_damage :: proc "contextless" () {
	x, y, width, height := bar.switcher_card(bar.SWITCHER_LINES_SHOWN, desktop_width, desktop_height)
	damage_add(x, y, width, height)
}

// window_switcher_records draws the card: one line for each window from
// the front, with its icon and its title, the chosen one on the chosen
// color. A minimized window has its title dim.
window_switcher_records :: proc "contextless" (table: ^interface.Draw_Table) {
	if !window_switcher.open || order_count == 0 {
		return
	}
	chosen := clamp(window_switcher.chosen, 0, order_count - 1)
	x, y, width, height := bar.switcher_card(order_count, desktop_width, desktop_height)
	interface.draw_vertical_gradient(table, x, y, width, height, graphics.colors.card_top, graphics.colors.card_bottom)
	interface.draw_outline(table, x, y, width, height, bar.BORDER, graphics.colors.title)
	first := bar.switcher_first_line(chosen, order_count)
	line_y := y + bar.BORDER + bar.SWITCHER_PADDING
	for place in first ..< min(order_count, first + bar.SWITCHER_LINES_SHOWN) {
		client := &clients[order[order_count - 1 - place]]
		is_chosen := place == chosen
		if is_chosen {
			interface.draw_rectangle(table, x + bar.BORDER, line_y, width - 2 * bar.BORDER, bar.SWITCHER_LINE_HEIGHT, graphics.colors.title)
		}
		color := is_chosen ? graphics.COLOR_WHITE : (client.minimized ? graphics.colors.dim : graphics.colors.text)
		icon_x := x + bar.BORDER + bar.SWITCHER_PADDING
		bar.icon_records(table, icon_x, line_y + (bar.SWITCHER_LINE_HEIGHT - bar.ICON_SIZE) / 2, client.icon, color, is_chosen ? graphics.COLOR_WHITE : graphics.colors.title)
		text_x := icon_x + bar.ICON_SIZE + bar.ICON_GAP
		title := interface.text_fit(table, interface.FONT_INTERFACE, system.name_of(client.title[:]), x + width - bar.BORDER - bar.SWITCHER_PADDING - text_x)
		interface.draw_text(table, text_x, line_y + (bar.SWITCHER_LINE_HEIGHT - graphics.CELL_HEIGHT) / 2, title, color, interface.FONT_INTERFACE)
		line_y += bar.SWITCHER_LINE_HEIGHT
	}
}
