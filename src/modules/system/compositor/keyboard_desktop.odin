package compositor

import "internal:compositor/bar"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:system"

// The acts of the desktop by keys alone (src/md/features/accessibility.md,
// "3. Keyboard access to everything"): the move and the resize of the
// window in front, and the focus of the keys on the bar and its menus. The
// pure rules are in src/library/internal/compositor/bar (keyboard.odin);
// this file holds their state and their effects.
//
// The keys of the compositor are Control and Shift with a function key,
// beside its other keys with Control and Shift (desktop_features.odin) and
// Alt+Tab (window_switcher.odin): the input service gives no Super as a
// modifier, and the key super alone opens the palette.
//   - Control+Shift+F7: the window in front moves by keys.
//   - Control+Shift+F8: the window in front resizes by keys.
//   - Control+Shift+F10: the bar takes the focus of the keys.
// The palette offers the first two as "move window" and "resize window".
//
// Each of the three is modal, as the palette is: while it holds the keys,
// no key reaches a process, so a key that a principal gives to the desktop
// never types into a window.

// The mode of the arrows on the window in front, and that window: a client
// index, or -1.
keyboard_window_mode: bar.Keyboard_Window_Mode
keyboard_window := -1
// The place and the size of the window when the mode started: Escape gives
// them back.
keyboard_window_start: struct {
	x, y, width, height: int,
}
// The size that the outline of the mode Resize shows: the size that Enter
// asks for. The window keeps its surface until its process answers.
keyboard_resize_width, keyboard_resize_height: int
// The item of the bar that has the focus of the keys. None: the bar has
// not the focus.
bar_focus: bar.Bar_Item
// The key whose press ended a mode or the focus of the bar: its release
// goes to no process, as it went to none with its press.
keyboard_kept_key: u32

// The words of the mark of a mode, over the window.
KEYBOARD_MOVE_WORDS :: "move: arrows, shift, enter, escape"
KEYBOARD_RESIZE_WORDS :: ": arrows, shift, enter, escape"
KEYBOARD_MARK_INSET :: 8 // From the corner of the surface to the mark.

// keyboard_desktop_key takes a key for the modes of the window in front
// and for the bar. It gives true when the key is taken: it then goes to no
// process. The palette, when it is open, has each key first.
keyboard_desktop_key :: proc "contextless" (code: u32, character: rune, pressed: bool, modifiers: u32) -> bool {
	if !pressed {
		if keyboard_kept_key != 0 && code == keyboard_kept_key {
			keyboard_kept_key = 0
			return true
		}
		return keyboard_window_mode != .None || bar_focus.kind != .None
	}
	if palette_is_open() {
		return false
	}
	shift := modifiers & display.MODIFIER_SHIFT != 0
	control_shift := u32(display.MODIFIER_CONTROL | display.MODIFIER_SHIFT)
	if keyboard_window_mode != .None {
		keyboard_window_key(code, shift)
		return true
	}
	if modifiers & control_shift == control_shift {
		switch code {
		case display.KEY_F7:
			keyboard_window_begin(.Move)
			return true
		case display.KEY_F8:
			keyboard_window_begin(.Resize)
			return true
		case display.KEY_F10:
			bar_focus_take({kind = .Start})
			return true
		}
	}
	if bar_focus.kind == .None && menu_open != .None {
		// A menu that the pointer opened takes the keys too: the focus
		// goes to its button.
		bar_focus_take(menu_open == .Start ? bar.Bar_Item{kind = .Start} : bar.Bar_Item{kind = .Windows})
	}
	if bar_focus.kind == .None && tray_state.open != .None {
		// A card of the tray that the pointer opened takes the keys too.
		bar_focus_take({kind = bar.bar_item_of_tray_widget(tray_state.open)})
	}
	if bar_focus.kind == .None {
		return false
	}
	return bar_key(code, character, shift)
}

// keyboard_pointer_pressed ends the modes of the keys at a press of the
// pointer: the pointer takes the desktop again. A move or a resize by keys
// keeps what the keys did, as Enter does.
keyboard_pointer_pressed :: proc "contextless" () {
	window_switcher_cancel() // window_switcher.odin
	if keyboard_window_mode != .None {
		keyboard_window_end(true)
	}
	if bar_focus.kind != .None {
		bar_focus = {}
		damage_bar()
		damage_menu()
	}
}

// keyboard_window_begin starts a mode of the arrows on the window in
// front. A window that a drag holds, a minimized window and, for Resize, a
// fixed window or one whose resize waits for its process do not start it.
keyboard_window_begin :: proc "contextless" (mode: bar.Keyboard_Window_Mode) {
	if mode == .None || order_count == 0 || dragging >= 0 || resizing >= 0 {
		return
	}
	index := order[order_count - 1]
	client := &clients[index]
	if !client.created || client.minimized {
		return
	}
	if mode == .Resize && (!client.resizable || client.resize_asked || client.resize_pictures != nil || client.released) {
		system.log_fact(.Info, Keyboard_Resize_Refused{window = window_field(client.title[:])})
		return
	}
	if bar_focus.kind != .None {
		bar_focus_leave()
	}
	keyboard_window_mode, keyboard_window = mode, index
	keyboard_window_start = {client.x, client.y, client.width, client.height}
	keyboard_resize_width, keyboard_resize_height = client.width, client.height
	keyboard_window_damage()
	switch mode {
	case .None:
	case .Move:
		system.log_fact(.Info, Keyboard_Move_Started{window = window_field(client.title[:])})
	case .Resize:
		system.log_fact(.Info, Keyboard_Resize_Started{window = window_field(client.title[:])})
	}
}

// keyboard_window_key takes a key while a mode of the arrows holds the
// window: an arrow steps, Enter keeps, Escape gives back. Each other key
// does nothing: the mode holds the keys until Enter or Escape.
keyboard_window_key :: proc "contextless" (code: u32, shift: bool) {
	arrow: bar.Arrow
	switch code {
	case display.KEY_LEFT:
		arrow = .Left
	case display.KEY_RIGHT:
		arrow = .Right
	case display.KEY_UP:
		arrow = .Up
	case display.KEY_DOWN:
		arrow = .Down
	case display.KEY_ENTER:
		keyboard_kept_key = code
		keyboard_window_end(true)
		return
	case display.KEY_ESCAPE:
		keyboard_kept_key = code
		keyboard_window_end(false)
		return
	case:
		return
	}
	client := &clients[keyboard_window]
	keyboard_window_damage()
	switch keyboard_window_mode {
	case .None:
	case .Move:
		damage_window(client)
		client.x, client.y = bar.keyboard_move_place(client.x, client.y, arrow, shift, window_frame_of(client), desktop_width, desktop_height)
		damage_window(client)
	case .Resize:
		keyboard_resize_width, keyboard_resize_height = bar.keyboard_resize_size(client.x, client.y, keyboard_resize_width, keyboard_resize_height, arrow, shift, size_range_of(client), 2 * BORDER, TITLE_HEIGHT + BORDER, desktop_width, desktop_height)
	}
	keyboard_window_damage()
}

// keyboard_window_end ends the mode of the arrows. keep: the window keeps
// its new place, or asks its process for the new size with the one event
// Resized, as at the release of a drag. Else the window is back at its
// place, and a resize asks nothing: the size never changed.
keyboard_window_end :: proc "contextless" (keep: bool) {
	if keyboard_window_mode == .None {
		return
	}
	client := &clients[keyboard_window]
	keyboard_window_damage()
	mode := keyboard_window_mode
	keyboard_window_mode, keyboard_window = .None, -1
	if !keep {
		damage_window(client)
		client.x, client.y = keyboard_window_start.x, keyboard_window_start.y
		damage_window(client)
		system.log_fact(.Info, Keyboard_Window_Kept{window = window_field(client.title[:])})
		return
	}
	switch mode {
	case .None:
	case .Move:
		system.log_fact(.Info, Window_Moved{x = u64(max(client.x, 0)), y = u64(client.y), window = window_field(client.title[:])})
	case .Resize:
		// One request at a time, superseding any queued post-drag live target.
		bar.live_resize_cancel(&client.live_resize)
		if window_size_ask(client, keyboard_resize_width, keyboard_resize_height, {.Right, .Bottom}) { // window_resize.odin
			window_unmaximize_on_resize(client)
		}
	}
}

// keyboard_window_gone ends a mode whose window left, or released its
// surface: no place is given back and no size is asked.
keyboard_window_gone :: proc "contextless" (index: int) {
	if keyboard_window_mode == .None || keyboard_window != index {
		return
	}
	keyboard_window_damage()
	keyboard_window_mode, keyboard_window = .None, -1
}

// keyboard_window_frame gives the frame that the mark of the mode
// outlines: the window where it is in the mode Move, the frame of the size
// that Enter asks in the mode Resize.
keyboard_window_frame :: proc "contextless" () -> Rectangle {
	client := &clients[keyboard_window]
	width, height := client.width, client.height
	if keyboard_window_mode == .Resize {
		width, height = keyboard_resize_width, keyboard_resize_height
	}
	return {client.x, client.y, client.x + width + 2 * BORDER, client.y + height + TITLE_HEIGHT + BORDER}
}

// keyboard_mark_words writes the words of the mark of the mode: the mode,
// the size that Enter asks, and the keys.
keyboard_mark_words :: proc "contextless" (builder: ^interface.Text_Builder) -> string {
	builder.count = 0
	switch keyboard_window_mode {
	case .None:
	case .Move:
		interface.text_put(builder, KEYBOARD_MOVE_WORDS)
	case .Resize:
		interface.text_put(builder, "resize ")
		interface.text_put_number(builder, u64(keyboard_resize_width))
		interface.text_put(builder, " x ")
		interface.text_put_number(builder, u64(keyboard_resize_height))
		interface.text_put(builder, KEYBOARD_RESIZE_WORDS)
	}
	return interface.text_of(builder)
}

// keyboard_mark_box gives the box of the mark of the mode: under the
// title bar of the frame, at its left. Its width comes from its words in
// the interface font, so it is measured with the table of the frame.
keyboard_mark_box :: proc "contextless" (table: ^interface.Draw_Table, words: string) -> interface.Area {
	frame := keyboard_window_frame()
	width := interface.text_measured_width(table, interface.FONT_INTERFACE, words) + 2 * bar.PADDING
	return {frame.left + BORDER + KEYBOARD_MARK_INSET, frame.top + TITLE_HEIGHT + KEYBOARD_MARK_INSET, width, bar.TRAY_HEIGHT}
}

// The box of the mark in the last frame: a step damages the old box, and
// the next frame draws the new one.
keyboard_mark_box_drawn: interface.Area

// keyboard_window_damage records the outline of the mode and its mark.
keyboard_window_damage :: proc "contextless" () {
	if keyboard_window_mode == .None {
		return
	}
	frame := keyboard_window_frame()
	ring := interface.focus_ring_area({frame.left, frame.top, frame.right - frame.left, frame.bottom - frame.top})
	damage_add(ring.x, ring.y, ring.width, ring.height)
	mark := keyboard_mark_box_drawn
	if mark.width > 0 {
		damage_add(mark.x, mark.y, mark.width, mark.height)
	}
	// The words of the next mark can be wider: its room to the right edge
	// of the screen is damaged with it.
	damage_add(frame.left, frame.top + TITLE_HEIGHT, desktop_width - frame.left, bar.TRAY_HEIGHT + 2 * KEYBOARD_MARK_INSET)
}

// keyboard_window_records appends the mark of a mode over the windows: an
// outline of 2 pixels in the strong text outside the frame, and a plate
// with the words of the mode. The window keeps its picture while it
// resizes: the outline shows the size that Enter asks. It gives the box of
// the records in pixels of the screen; drawn: false when no mode holds a
// window, and nothing was appended.
keyboard_window_records :: proc "contextless" (table: ^interface.Draw_Table) -> (box: Rectangle, drawn: bool) {
	keyboard_mark_box_drawn = {}
	if keyboard_window_mode == .None {
		return {}, false
	}
	frame := keyboard_window_frame()
	frame_area := interface.Area{frame.left, frame.top, frame.right - frame.left, frame.bottom - frame.top}
	interface.draw_focus_ring(table, frame_area)
	ring := interface.focus_ring_area(frame_area)
	x, y, width, height := ring.x, ring.y, ring.width, ring.height
	words_builder: interface.Text_Builder
	words := keyboard_mark_words(&words_builder)
	mark := keyboard_mark_box(table, words)
	keyboard_mark_box_drawn = mark
	interface.draw_rectangle(table, mark.x, mark.y, mark.width, mark.height, graphics.colors.recess)
	interface.draw_outline(table, mark.x, mark.y, mark.width, mark.height, 1, graphics.colors.text_strong)
	interface.draw_text(table, mark.x + bar.PADDING, mark.y + (mark.height - graphics.CELL_HEIGHT) / 2, words, graphics.colors.text_strong, interface.FONT_INTERFACE)
	left, top := min(x, mark.x), min(y, mark.y)
	right, bottom := max(x + width, mark.x + mark.width), max(y + height, mark.y + mark.height)
	return screen_rectangle_of(left, top, right - left, bottom - top), true
}

// bar_viewer_mark_shown says if the viewer mark is an item of the bar: it
// is drawn and has a viewer to list.
bar_viewer_mark_shown :: proc "contextless" () -> bool {
	return capture_is_open() && capture_mark_drawn && bar.viewer_popover_has_viewers(&capture_viewer_popover)
}

// bar_focus_take gives the focus of the keys to an item of the bar.
bar_focus_take :: proc "contextless" (item: bar.Bar_Item) {
	if bar_focus.kind == .None {
		system.log_fact(.Info, Bar_Focus_Taken{})
	}
	bar_focus = item
	damage_bar()
	damage_menu()
}

// bar_focus_leave closes the menu of the bar and gives the focus of the
// keys back to the window in front.
bar_focus_leave :: proc "contextless" () {
	menu_close()
	tray_widget_close() // tray_widgets.odin
	bar_focus = {}
	damage_bar()
	damage_menu()
	system.log_fact(.Info, Bar_Focus_Left{})
}

// bar_key takes a key while the bar has the focus. Left and Right (and Tab,
// Shift+Tab) move along the items and close a menu; Down and Up open the
// menu of a button and move its choice; Enter and Space act; Escape gives
// the focus back. The key super gives the focus back and opens the palette.
// Each other key does nothing: the bar holds the keys.
bar_key :: proc "contextless" (code: u32, character: rune, shift: bool) -> bool {
	switch {
	case code == display.KEY_SUPER:
		bar_focus_leave()
		return false
	case code == display.KEY_ESCAPE:
		keyboard_kept_key = code
		bar_focus_leave()
	case code == display.KEY_LEFT || code == display.KEY_RIGHT || code == display.KEY_TAB:
		forward := code == display.KEY_RIGHT || code == display.KEY_TAB && !shift
		menu_close()
		tray_widget_close()
		bar_focus_take(bar.bar_item_step(bar_focus, taskbar_plate_count, bar_viewer_mark_shown(), forward))
	case code == display.KEY_DOWN || code == display.KEY_UP:
		bar_menu_step(code == display.KEY_DOWN)
	case code == display.KEY_ENTER || character == ' ':
		keyboard_kept_key = code
		bar_item_act(shift)
	}
	return true
}

// bar_menu_step moves the choice of the open menu, or opens the menu of
// the button that has the focus, with its first line (Down) or its last
// (Up) chosen.
bar_menu_step :: proc "contextless" (forward: bool) {
	if menu_open == .None {
		switch bar_focus.kind {
		case .Start:
			menu_show(.Start)
		case .Windows:
			menu_show(.Windows)
		case .Control_Center, .Notifications, .Clock:
			// The card of the item opens, then the keys walk its parts.
			widget := bar.bar_item_tray_widget(bar_focus.kind)
			if tray_state.open != widget {
				tray_widget_show(widget) // tray_widgets.odin
			}
			tray_state.chosen = bar.tray_part_step(widget, notification_history.count, tray_state.chosen, forward)
			tray_card_damage(widget)
			return
		case .None, .Plate, .Viewer_Mark:
			return
		}
	}
	switch menu_open {
	case .None:
	case .Start:
		menu_line, menu_action = bar.start_menu_step(bar_layout, menu_line, menu_action, forward)
	case .Windows:
		menu_line = bar.windows_menu_step(menu_line, windows_menu_row_count, forward)
		menu_on_revoke = false
	}
	damage_menu()
}

// bar_item_act does the act of the item that has the focus: with a menu
// open, the act of its chosen line; else the button opens its menu with
// its first line chosen, a plate brings its group to the front, the viewer
// mark opens the list of the viewers. An act that reaches a window gives
// it the focus of the keys.
bar_item_act :: proc "contextless" (unbounded := false) {
	if menu_open != .None {
		if menu_line < 0 && menu_action == .None {
			return
		}
		if menu_choice_do(true, unbounded) { // start_menu.odin
			return // A grant was revoked: the menu and the focus of the keys stay.
		}
		bar_focus = {}
		damage_bar()
		system.log_fact(.Info, Bar_Focus_Left{})
		return
	}
	switch bar_focus.kind {
	case .None:
	case .Start, .Windows:
		bar_menu_step(true)
	case .Control_Center, .Notifications, .Clock:
		// Enter opens the card; on the card, it does the chosen part.
		widget := bar.bar_item_tray_widget(bar_focus.kind)
		if tray_state.open != widget {
			tray_widget_show(widget) // tray_widgets.odin
			return
		}
		part := tray_state.chosen
		if part == .None {
			return
		}
		if bar.tray_part_closes_card(part) {
			tray_widget_close()
		}
		tray_part_do(part)
		if tray_state.open == .None {
			bar_focus_leave()
		}
	case .Plate:
		if desktop_taskbar_slot_activate(bar_focus.plate) {
			bar_focus_leave()
		}
	case .Viewer_Mark:
		if bar_viewer_mark_shown() && bar.viewer_popover_mark_click(&capture_viewer_popover).kind == .Opened {
			damage_capture_popover(capture_viewer_popover.count)
		}
	}
}

// bar_focus_records appends the outline of the focus of the keys around
// the item of the bar that has it, after each item of the bar, so no item
// covers it. An item that the bar no longer shows has no outline: the next
// arrow finds the items that are there.
bar_focus_records :: proc "contextless" (table: ^interface.Draw_Table) {
	x, y, width, height: int
	switch bar_focus.kind {
	case .None:
		return
	case .Start:
		x, y, width, height = bar.button(bar_layout)
	case .Windows:
		x, y, width, height = bar.windows_button(bar_layout)
	case .Plate:
		if bar_focus.plate < 0 || bar_focus.plate >= taskbar_plate_count {
			return
		}
		x, y, width, height = bar.plate(bar_layout, bar_focus.plate)
	case .Viewer_Mark:
		if !bar_viewer_mark_shown() {
			return
		}
		x, y, width, height = capture_mark_x, capture_mark_y, capture_mark_width, capture_mark_height
	case .Control_Center, .Notifications, .Clock:
		x, y, width, height = bar.tray_widget_button(bar_layout, desktop_width, bar.bar_item_tray_widget(bar_focus.kind))
	}
	interface.draw_focus_ring(table, {x, y, width, height})
}
