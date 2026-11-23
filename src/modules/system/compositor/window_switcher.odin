package compositor

import "internal:compositor/bar"
import "modus:display"
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
#assert(CLIENT_CAPACITY <= bar.SWITCHER_WINDOW_CAPACITY)

// window_switcher_key takes a key for the switcher. It gives true when the
// key goes to no window. While its card is open the switcher has each key
// first; it does not open over the palette, a mode of the keys of the
// desktop, a dialog of the trusted display or a menu.
window_switcher_key :: proc "contextless" (code: u32, pressed: bool, modifiers: u32) -> bool {
	// Control+Shift+Escape revokes a wide grant: the card never holds it. It
	// closes, and the key goes on to the revocation.
	control_shift := u32(display.MODIFIER_CONTROL | display.MODIFIER_SHIFT)
	if pressed && code == display.KEY_ESCAPE && modifiers & control_shift == control_shift {
		window_switcher_cancel()
		return false
	}
	if !window_switcher.open && (palette_is_open() || keyboard_window_mode != .None || bar_focus.kind != .None || trusted_dialog_open() || desktop_context_menu.open) {
		return false
	}
	front_to_back: [CLIENT_CAPACITY]int
	for position in 0 ..< order_count {
		front_to_back[position] = order[order_count - 1 - position]
	}
	opened := window_switcher.open
	outcome := bar.switcher_key(&window_switcher, code, pressed, modifiers, front_to_back[:order_count])
	if outcome.changed {
		window_switcher_damage()
	}
	if !opened && window_switcher.open {
		system.log_fact(.Info, Window_Switcher_Opened{windows = u64(window_switcher.window_count)})
	}
	if outcome.finish {
		window_bring_to_front(outcome.window)
	}
	return outcome.taken
}

// window_bring_to_front restores a window if it is minimized and raises
// it, if the client still has a window.
window_bring_to_front :: proc "contextless" (index: int) {
	if index < 0 || index >= CLIENT_CAPACITY || !clients[index].created {
		return
	}
	for position in 0 ..< order_count {
		if order[position] != index {
			continue
		}
		client := &clients[index]
		if client.minimized {
			client.minimized = false
			damage_whole_screen()
		}
		raise(position)
		system.log_fact(.Info, Window_Switched{window = window_field(client.title[:])})
		return
	}
}

// window_switcher_cancel closes the card with no change: at a press of the
// pointer, when a window opens or closes, when a dialog or a menu opens.
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

// window_switcher_records draws the card: one line for each window of its
// open, from the front, with its icon and its title, the chosen one on the
// chosen color. A minimized window has its title dim.
window_switcher_records :: proc "contextless" (table: ^interface.Draw_Table) {
	count := window_switcher.window_count
	if !window_switcher.open || count <= 0 || count > bar.SWITCHER_WINDOW_CAPACITY {
		return
	}
	chosen := clamp(window_switcher.chosen, 0, count - 1)
	x, y, width, height := bar.switcher_card(count, desktop_width, desktop_height)
	interface.draw_vertical_gradient(table, x, y, width, height, graphics.colors.card_top, graphics.colors.card_bottom)
	interface.draw_outline(table, x, y, width, height, bar.BORDER, graphics.colors.title)
	first := bar.switcher_first_line(chosen, count)
	line_y := y + bar.BORDER + bar.SWITCHER_PADDING
	for line in first ..< min(count, first + bar.SWITCHER_LINES_SHOWN) {
		index := window_switcher.windows[line]
		if index < 0 || index >= CLIENT_CAPACITY {
			continue
		}
		client := &clients[index]
		is_chosen := line == chosen
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
