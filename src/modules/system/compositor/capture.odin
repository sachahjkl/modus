package compositor

// The capture face and the input face (src/md/features/remote_display.md,
// "The service"): a copy of the screen for the service of the remote
// display, and the keys and the pointer of its viewers.
//
// Both ride the ring of the window of that service: the root service says
// in its Client_Add that it holds the start grant Screen_Capture. A command
// of the two faces from another client is counted and dropped, and the
// first one writes a line. One client holds the capture face at a time.
//
// The copy never makes this loop wait: the service holds at most one of the
// two pictures, and while it holds it, the damage of each frame goes into
// the debt of each picture and into the rectangles of the next record. The
// copy runs before the pointer is drawn, so the pointer is not in the
// pixels; the header of each picture names its place.
//
// While the face is open, the bar shows the mark of a viewer, which this
// service draws from its own state: the service names its viewers, and
// cannot hide the mark.

import "modus:display"
import "modus:graphics"
import "modus:interface"
import "internal:compositor/bar"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:key_path"
import "modus:system"

// The largest code of a key of a viewer: a scan code of set 1, with the
// bit of its prefix.
REMOTE_KEY_CODE_LIMIT :: display.KEY_EXTENDED | 0xFF

// The header of a picture holds each rectangle of a damage set: a set
// never has more than the header can name.
#assert(interface.DAMAGE_CAPACITY <= display.CAPTURE_RECTANGLE_CAPACITY)
#assert(bar.VIEWER_CAPACITY == display.CAPTURE_VIEWER_CAPACITY)

Capture_Face :: struct {
	client:       int, // The client that holds the face, or -1.
	memory:       system.Handle,
	mapped:       rawptr,
	header:       ^display.Capture_Header,
	pictures:     [display.PICTURE_COUNT]graphics.Canvas,
	// Where each picture differs from the frame: the rectangles that its
	// next copy writes.
	debts:        [display.PICTURE_COUNT]interface.Damage,
	changed:      interface.Damage, // The rectangles that changed since the last record.
	held:         int, // The picture of the last record, until Capture_Taken; -1: none.
	last_written: int,
	serial:       u64,
	// The viewers that the service named, for the mark of the bar.
	viewer_count:            int,
	viewer_input:            u64, // Bit n: viewer n has the input.
	viewer_keys:             [display.CAPTURE_VIEWER_CAPACITY]u64,
	// Protocol v2 per-viewer warp notifications and input echo counts.
	pointer_warped_mask:     u32,
	viewer_input_generation: [display.CAPTURE_VIEWER_CAPACITY]u64,
	viewer_input_echo:       [display.CAPTURE_VIEWER_CAPACITY]u64,
	// The counts of the log.
	records:          u64, // The records Capture_Frame.
	refused:          u64, // Commands of the two faces that this service refused.
	remote_keys:      u64,
	remote_pointers:  u64,
}

capture := Capture_Face{client = -1, held = -1, last_written = 1}
capture_viewer_popover := bar.Viewer_Popover{hovered_index = -1}
// Rendered place of the viewer mark in the bar, updated when capture_mark_records draws it.
capture_mark_x, capture_mark_y, capture_mark_width, capture_mark_height: int
capture_mark_drawn: bool

// capture_is_open says if a client holds the capture face.
capture_is_open :: proc "contextless" () -> bool {
	return capture.client >= 0
}

// capture_note_machine_pointer_move marks that the machine moved the
// pointer without a Remote_Pointer record from any viewer, so connected
// viewers receive a Pointer_Warp record.
capture_note_machine_pointer_move :: proc "contextless" () {
	if capture.client >= 0 {
		capture.pointer_warped_mask |= (u32(1) << display.CAPTURE_VIEWER_CAPACITY) - 1
	}
}

// capture_record_viewer_input updates the monotonic echo counter of a
// viewer slot once its Remote_Key or Remote_Pointer record is applied.
@(private = "file")
capture_record_viewer_input :: proc "contextless" (record: ring.Record) -> (viewer_slot: u64) {
	viewer_slot = record.values[4]
	input_serial := record.values[5]
	generation := record.values[6]
	if viewer_slot < display.CAPTURE_VIEWER_CAPACITY && generation != 0 {
		if capture.viewer_input_generation[viewer_slot] != generation || input_serial >= capture.viewer_input_echo[viewer_slot] {
			capture.viewer_input_generation[viewer_slot] = generation
			capture.viewer_input_echo[viewer_slot] = input_serial
		}
	}
	return viewer_slot
}

// capture_refuse counts a refused command of the two faces; the first one
// writes a line, so a client cannot fill the log.
@(private = "file")
capture_refuse :: proc "contextless" (client: ^Client, why: string) {
	if capture.refused == 0 {
		system.log_fact(.Warning, Capture_Command_Refused{capture_refusal = value_kinds.text_field(why, CAPTURE_REFUSAL_FIELD_BYTES)})
	}
	capture.refused += 1
}

// capture_command takes one command of the capture face or of the input
// face from the ring of a client.
capture_command :: proc "contextless" (index: int, command: display.Command, record: ring.Record) {
	client := &clients[index]
	if !client.capture_allowed {
		if command == .Capture_Open {
			// A handle that the process gave through its ring is closed:
			// the compositor keeps nothing of a refused command.
			if _, _, through := system.handle_state(system.Handle(record.values[0]), client.ring_memory); through {
				system.close(system.Handle(record.values[0]))
			}
		}
		capture_refuse(client, "the process has no grant Screen_Capture")
		return
	}
	switch command {
	case .None, .Surface_Create, .Present, .Pointer_Shape, .Act_Names, .Picture_Due, .Resizable, .Surface_Resize, .Surface_Rescale, .Surface_Release, .Surface_Declined, .Resize_Declined, .Copy, .Copy_Declined, .Paste_Taken:
		// The loop gives this procedure the commands of the two faces only.
	case .Capture_Size_Ask:
		send(client, .Capture_Size, {0 = u64(screen.width), 1 = u64(screen.height)})
	case .Capture_Open:
		capture_open(index, record)
	case .Capture_Taken:
		if capture.client != index || capture.held < 0 || record.values[0] != u64(capture.held) {
			capture_refuse(client, "a Capture_Taken of a picture that the process does not hold")
			return
		}
		capture.held = -1
		if capture.changed.count > 0 {
			capture_frame_due()
		}
	case .Capture_Close:
		if capture.client == index {
			capture_end("the service closed it")
		}
	case .Capture_Viewers:
		if capture.client != index || record.values[0] > display.CAPTURE_VIEWER_CAPACITY {
			capture_refuse(client, "a list of viewers past its capacity, or with no capture face")
			return
		}
		capture.viewer_count = int(record.values[0])
		capture.viewer_input = record.values[1] & (1 << display.CAPTURE_VIEWER_CAPACITY - 1)
		for &key, place in capture.viewer_keys {
			key = place < capture.viewer_count ? record.values[2 + place] : 0
		}
		was_open := capture_viewer_popover.open
		old_count := capture_viewer_popover.count
		if bar.viewer_popover_sync(&capture_viewer_popover, true, capture.viewer_count, capture.viewer_keys[:], capture.viewer_input) && (was_open || capture_viewer_popover.open) {
			damage_capture_popover(max(old_count, capture_viewer_popover.count))
		}
		damage_bar()
	case .Remote_Key:
		code, character_word, pressed, modifiers := record.values[0], record.values[1], record.values[2], record.values[3]
		if capture.client != index || code == 0 || code > REMOTE_KEY_CODE_LIMIT || pressed > 1 || modifiers > u64(display.MODIFIER_SHIFT | display.MODIFIER_CONTROL) {
			capture_refuse(client, "a key out of its range, or with no capture face")
			return
		}
		capture.remote_keys += 1
		if capture.remote_keys == 1 {
			system.log_fact(.Info, First_Viewer_Key{})
		}
		_ = capture_record_viewer_input(record)
		character := display.key_character_of(character_word)
		// The path of a key of the input service: the palette, the
		// clipboard, then the window in front, never the bar.
		switch {
		case palette_key(u32(code), character, pressed != 0, u32(modifiers)):
		case clipboard_key(character, u32(modifiers), pressed != 0):
		case order_count > 0:
			in_front := order[order_count - 1]
			send(&clients[in_front], .Key, {0 = code, 1 = u64(character), 2 = pressed, 3 = modifiers})
		}
	case .Remote_Pointer:
		x, y, buttons := record.values[0], record.values[1], record.values[2]
		if capture.client != index || x >= u64(screen.width) || y >= u64(screen.height) || buttons & ~u64(display.BUTTON_LEFT | display.BUTTON_RIGHT) != 0 {
			capture_refuse(client, "a pointer outside the screen, or with no capture face")
			return
		}
		capture.remote_pointers += 1
		viewer_slot := capture_record_viewer_input(record)
		wheel := int(clamp(i64(record.values[3]), -key_path.WHEEL_NOTCHES_LIMIT, key_path.WHEEL_NOTCHES_LIMIT))
		before_x, before_y := pointer_x, pointer_y
		// A viewer sees the pixels of the screen: its place goes to the
		// logical pixel of the desktop that holds it.
		pointer_moved(logical_pixel_of(int(x)) - pointer_x, logical_pixel_of(int(y)) - pointer_y, u32(buttons), wheel)
		if pointer_x != before_x || pointer_y != before_y {
			// Other viewers saw a move they did not initiate; the sender
			// knows its own move.
			all_viewers := (u32(1) << display.CAPTURE_VIEWER_CAPACITY) - 1
			sender_bit := viewer_slot < display.CAPTURE_VIEWER_CAPACITY ? (u32(1) << u32(viewer_slot)) : 0
			capture.pointer_warped_mask |= all_viewers &~ sender_bit
		}
	}
}

// capture_open makes the memory of the copy of the screen with the budget
// that a client gave through its ring, for that memory alone: a header
// page, then two pictures of the size of the screen. The compositor
// writes into it at each frame, so it writes only into memory that it
// made: a client cannot revoke its mapping, nor leave a page with no
// frame. It gives the client a copy with Read, and answers each record
// with Capture_Opened: the copy, or 0 when it refused.
@(private = "file")
capture_open :: proc "contextless" (index: int, record: ring.Record) {
	client := &clients[index]
	budget := system.Handle(record.values[0])
	kind, rights, through := system.handle_state(budget, client.ring_memory)
	if !through {
		capture_refuse(client, "a handle that the process did not give")
		send(client, .Capture_Opened, {})
		return
	}
	defer system.close(budget)
	width, height := record.values[1], record.values[2]
	budget_pages: u64
	if kind == .Budget && rights & {.Spend, .Read} == {.Spend, .Read} {
		if amounts, status := system.budget_read(budget); status == .Ok {
			budget_pages = amounts.pages
		}
	}
	switch {
	case capture.client >= 0:
		capture_refuse(client, "a second capture face")
	case kind != .Budget || rights & {.Spend, .Read} != {.Spend, .Read}:
		capture_refuse(client, "the handle is not a budget with Spend and Read")
	case width != u64(screen.width) || height != u64(screen.height):
		capture_refuse(client, "the size is not the size of the screen")
	case budget_pages < display.capture_budget_pages(screen.width, screen.height):
		capture_refuse(client, "the budget does not pay the header and two pictures")
	case:
		memory, create_status := system.memory_create(display.capture_pages(screen.width, screen.height), budget)
		if create_status != .Ok {
			capture_refuse(client, "the budget pays no memory")
			break
		}
		address, map_status := system.memory_map(memory, {.Write})
		given: system.Handle
		give_status := map_status
		if map_status == .Ok {
			given, give_status = system.give(client.ring_memory, memory, {.Read})
		}
		if give_status != .Ok {
			if map_status == .Ok {
				system.memory_unmap(address)
			}
			system.close(memory)
			capture_refuse(client, "the memory does not map")
			break
		}
		capture = {client = index, memory = memory, mapped = address, held = -1, last_written = 1}
		capture.header = (^display.Capture_Header)(address)
		pixels := ([^]graphics.Color)(rawptr(uintptr(address) + display.CAPTURE_HEADER_PAGES * system.PAGE_SIZE))
		for &picture, place in capture.pictures {
			picture = {pixels = pixels[place * screen.width * screen.height:], width = screen.width, height = screen.height, stride = screen.width}
		}
		// Each pixel of each picture is owed, and the first record has the
		// whole screen.
		whole := interface.Rectangle{0, 0, screen.width, screen.height}
		for &debt in capture.debts {
			interface.damage_add(&debt, whole)
		}
		interface.damage_add(&capture.changed, whole)
		send(client, .Capture_Opened, {0 = u64(given)})
		// The mark of the bar, and a frame that writes the first picture.
		damage_bar()
		// The client of a capture face has no window, so it has no title:
		// the root service allows one process, and the line names none.
		system.log_fact(.Info, Capture_Face_Opened{width = u64(screen.width), height = u64(screen.height)})
		return
	}
	send(client, .Capture_Opened, {})
}

// capture_end closes the capture face: the memory is unmapped and closed,
// and the mark leaves the bar.
capture_end :: proc "contextless" (why: string) {
	if capture.client < 0 {
		return
	}
	if capture.mapped != nil {
		system.memory_unmap(capture.mapped)
	}
	if capture.memory != 0 {
		system.close(capture.memory)
	}
	system.log_fact(.Info, Capture_Face_Ended{pictures = capture.records, viewer_keys = capture.remote_keys, viewer_pointer_records = capture.remote_pointers, refused = capture.refused, capture_end = value_kinds.text_field(why, CAPTURE_END_FIELD_BYTES)})
	was_open := capture_viewer_popover.open
	old_count := capture_viewer_popover.count
	_ = bar.viewer_popover_sync(&capture_viewer_popover, false, 0, nil, 0)
	capture_mark_drawn = false
	capture = {client = -1, held = -1, last_written = 1}
	if was_open {
		damage_capture_popover(old_count)
	}
	damage_bar()
}

// capture_frame_due makes the next frame come, so that it writes the
// rectangles that changed while the service held its picture. The
// rectangle of the pointer is drawn again, which the copy needs anyway.
@(private = "file")
capture_frame_due :: proc "contextless" () {
	if pointer_drawn_valid {
		damage_rectangle_add(pointer_drawn.left, pointer_drawn.top, pointer_drawn.right - pointer_drawn.left, pointer_drawn.bottom - pointer_drawn.top)
	} else {
		damage_rectangle_add(0, 0, 1, 1)
	}
}

// capture_before_frame runs before a frame draws: a rectangle that the
// next picture owes from an earlier frame can hold the pointer of now in
// the frame, so the frame draws the rectangle of the pointer again, and
// the copy finds it with no pointer.
capture_before_frame :: proc "contextless" () {
	if capture.client < 0 || capture.held >= 0 || !pointer_drawn_valid {
		return
	}
	debt := &capture.debts[1 - capture.last_written]
	for rectangle in debt.rectangles[:debt.count] {
		if rectangle.left < pointer_drawn.right && pointer_drawn.left < rectangle.right && rectangle.top < pointer_drawn.bottom && pointer_drawn.top < rectangle.bottom {
			damage_rectangle_add(pointer_drawn.left, pointer_drawn.top, pointer_drawn.right - pointer_drawn.left, pointer_drawn.bottom - pointer_drawn.top)
			return
		}
	}
}

// capture_after_draw runs in each frame after the windows, the bar and
// the palette, before the pointer: the areas of the frame hold the pixels
// of the screen with no pointer. It owes them to both pictures, and writes
// the picture that the service does not hold.
capture_after_draw :: proc "contextless" (areas: []Rectangle) {
	if capture.client < 0 {
		return
	}
	for area in areas {
		rectangle := interface.Rectangle{area.left, area.top, area.right, area.bottom}
		interface.damage_add(&capture.changed, rectangle)
		for &debt in capture.debts {
			interface.damage_add(&debt, rectangle)
		}
	}
	if capture.held >= 0 || capture.changed.count == 0 {
		return
	}
	written := 1 - capture.last_written
	debt := &capture.debts[written]
	for rectangle in debt.rectangles[:debt.count] {
		left, top := max(rectangle.left, 0), max(rectangle.top, 0)
		right, bottom := min(rectangle.right, screen.width), min(rectangle.bottom, screen.height)
		if right <= left || bottom <= top {
			continue
		}
		target := graphics.view(capture.pictures[written], left, top, right - left, bottom - top)
		source := graphics.view(frame, left, top, right - left, bottom - top)
		graphics.copy(target, 0, 0, source)
	}
	debt^ = {}
	capture.serial += 1
	header := &capture.header.pictures[written]
	header.serial = capture.serial
	header.count = u64(capture.changed.count)
	for rectangle, place in capture.changed.rectangles[:capture.changed.count] {
		header.rectangles[place] = {u32(max(rectangle.left, 0)), u32(max(rectangle.top, 0)), u32(clamp(rectangle.right, 0, screen.width)), u32(clamp(rectangle.bottom, 0, screen.height))}
	}
	pointer_screen_x, pointer_screen_y := pointer_screen_place()
	header.pointer_x, header.pointer_y = u32(clamp(pointer_screen_x, 0, screen.width - 1)), u32(clamp(pointer_screen_y, 0, screen.height - 1))
	header.pointer_left, header.pointer_top, header.pointer_right, header.pointer_bottom = 0, 0, 0, 0
	if pointer_drawn_valid {
		left, top := clamp(pointer_drawn.left, 0, screen.width), clamp(pointer_drawn.top, 0, screen.height)
		right, bottom := clamp(pointer_drawn.right, 0, screen.width), clamp(pointer_drawn.bottom, 0, screen.height)
		if left < right && top < bottom {
			header.pointer_left, header.pointer_top, header.pointer_right, header.pointer_bottom = u32(left), u32(top), u32(right), u32(bottom)
		}
	}
	header.pointer_shape = u32(pointer_shape)
	header.pointer_form = u32(pointer_form)
	if pointer_theme != nil && pointer_chosen.picture.width >= 24 && pointer_chosen.picture.width <= 48 {
		header.pointer_size = pointer_chosen.picture.width
		header.pointer_hot_spot_x = min(pointer_chosen.picture.hot_spot_x, header.pointer_size - 1)
		header.pointer_hot_spot_y = min(pointer_chosen.picture.hot_spot_y, header.pointer_size - 1)
	} else {
		header.pointer_size = 24
		header.pointer_hot_spot_x = 0
		header.pointer_hot_spot_y = 0
	}
	header.pointer_warped_mask = capture.pointer_warped_mask
	capture.pointer_warped_mask = 0
	header.viewer_input_generation = capture.viewer_input_generation
	header.viewer_input_echo = capture.viewer_input_echo
	send(&clients[capture.client], .Capture_Frame, {0 = u64(written), 1 = header.count, 2 = header.serial})
	capture.changed = {}
	capture.held = written
	capture.last_written = written
	capture.records += 1
}

// capture_mark_records appends the mark of a viewer to the bar while the
// capture face is open, at the right of the tray, which ends 16 pixels
// before right. The text that fits in the room after the first plate of the
// windows goes: each key and its input, then the count of the viewers, then
// the mark alone; no text is cut.
capture_mark_records :: proc "contextless" (table: ^interface.Draw_Table, right: int) {
	if capture.client < 0 {
		capture_mark_drawn = false
		return
	}
	room := capture_mark_room(right)
	full: [96]u8
	full_writer := system.Writer{buffer = full[:]}
	system.write_part(&full_writer, capture.viewer_count > 1 ? "viewers: " : "viewer")
	for place in 0 ..< capture.viewer_count {
		system.write_part(&full_writer, place == 0 ? (capture.viewer_count > 1 ? "" : ": ") : ", ")
		head := transmute([8]u8)capture.viewer_keys[place]
		system.write_hex(&full_writer, u64(head[0]) << 24 | u64(head[1]) << 16 | u64(head[2]) << 8 | u64(head[3]), 8)
		if capture.viewer_input >> u64(place) & 1 != 0 {
			system.write_part(&full_writer, " input")
		}
	}
	count: [24]u8
	count_writer := system.Writer{buffer = count[:]}
	system.write_part(&count_writer, "viewers: ")
	system.write_unsigned(&count_writer, u64(capture.viewer_count))
	candidates := [2]string{system.written(&full_writer), system.written(&count_writer)}
	for text in candidates {
		width := interface.text_measured_width(table, interface.FONT_INTERFACE, text) + 2 * bar.PADDING
		if width > room {
			continue
		}
		x := right - 16 - width
		y := desktop_bar_y() + bar.TRAY_Y
		capture_mark_x, capture_mark_y, capture_mark_width, capture_mark_height = x, y, width, bar.TRAY_HEIGHT
		capture_mark_drawn = true
		if capture_viewer_popover.open {
			interface.draw_rectangle(table, x, y, width, bar.TRAY_HEIGHT, graphics.colors.chosen)
		}
		interface.draw_outline(table, x, y, width, bar.TRAY_HEIGHT, 2, graphics.colors.warning)
		interface.draw_text(table, x + bar.PADDING, y + (bar.TRAY_HEIGHT - graphics.CELL_HEIGHT) / 2, text, capture_viewer_popover.open ? graphics.COLOR_WHITE : graphics.colors.text, interface.FONT_INTERFACE)
		return
	}
	// The square alone: it needs no room of its own, so the mark is always
	// drawn.
	x := right - 16 - CAPTURE_MARK_SQUARE
	y := desktop_bar_y() + bar.TRAY_Y + (bar.TRAY_HEIGHT - CAPTURE_MARK_SQUARE) / 2
	capture_mark_x, capture_mark_y, capture_mark_width, capture_mark_height = x, y, CAPTURE_MARK_SQUARE, CAPTURE_MARK_SQUARE
	capture_mark_drawn = true
	interface.draw_rectangle(table, x, y, CAPTURE_MARK_SQUARE, CAPTURE_MARK_SQUARE, graphics.colors.warning)
}

// The mark of a viewer with no text.
CAPTURE_MARK_SQUARE :: 16

// capture_mark_room gives the room of the mark between the first plate of
// the windows and an element of the bar that starts at right: the plates
// give way to the mark.
capture_mark_room :: proc "contextless" (right: int) -> int {
	return right - 16 - (bar.PLATES_X + bar.PLATE_WIDTH + 16)
}

// capture_mark_contains reports whether (x, y) lies inside the visible viewer
// mark while at least one viewer is connected.
capture_mark_contains :: proc "contextless" (x, y: int) -> bool {
	if !capture_is_open() || !capture_mark_drawn || !bar.viewer_popover_has_viewers(&capture_viewer_popover) {
		return false
	}
	return x >= capture_mark_x && x < capture_mark_x + capture_mark_width && y >= capture_mark_y && y < capture_mark_y + capture_mark_height
}

// capture_popover_shift gives the vertical move from the place of the
// viewer card that the bar package gives, under a bar at the top, to its
// place on the screen: over the bar when the bar is at the bottom
// (src/md/features/bar_edge.md). It is 0 for a bar at the top.
capture_popover_shift :: proc "contextless" (count: int) -> int {
	_, y, _, height := bar.viewer_popover_rect(capture_mark_x, capture_mark_width, desktop_width, count)
	return bar.menu_top(bar_layout, height) - y
}

// damage_capture_popover marks the bar mark and viewer list popover card dirty.
damage_capture_popover :: proc "contextless" (count: int) {
	damage_bar()
	x, y, width, height := bar.viewer_popover_rect(capture_mark_x, capture_mark_width, desktop_width, max(count, 1))
	damage_add(x, y + capture_popover_shift(max(count, 1)), width, height)
}

// capture_popover_close closes the viewer popover if open and damages its area.
capture_popover_close :: proc "contextless" () {
	if !capture_viewer_popover.open {
		return
	}
	old_count := capture_viewer_popover.count
	_ = bar.viewer_popover_escape(&capture_viewer_popover)
	damage_capture_popover(old_count)
}

// capture_popover_escape closes the viewer popover on local Escape. Returns
// true when Escape was consumed by closing an open popover.
capture_popover_escape :: proc "contextless" () -> bool {
	if !capture_viewer_popover.open {
		return false
	}
	old_count := capture_viewer_popover.count
	if bar.viewer_popover_escape(&capture_viewer_popover).kind == .Closed {
		damage_capture_popover(old_count)
		return true
	}
	return false
}

// capture_popover_pointer_move updates hover state on the open viewer popover.
capture_popover_pointer_move :: proc "contextless" (x, y: int) {
	if bar.viewer_popover_pointer_move(&capture_viewer_popover, capture_mark_x, capture_mark_width, desktop_width, x, y - capture_popover_shift(capture_viewer_popover.count)) {
		damage_capture_popover(capture_viewer_popover.count)
	}
}

// capture_popover_press handles a left-button press for the bar viewer mark
// and the viewer list popover. Returns true when the press was consumed.
capture_popover_press :: proc "contextless" (x, y: int) -> bool {
	if capture_viewer_popover.open {
		old_count := capture_viewer_popover.count
		if capture_mark_contains(x, y) {
			_ = bar.viewer_popover_mark_click(&capture_viewer_popover)
			damage_capture_popover(old_count)
			return true
		}
		action := bar.viewer_popover_click(&capture_viewer_popover, capture_mark_x, capture_mark_width, desktop_width, x, y - capture_popover_shift(capture_viewer_popover.count))
		switch action.kind {
		case .None:
			return true
		case .Opened:
			damage_capture_popover(capture_viewer_popover.count)
			return true
		case .Closed:
			damage_capture_popover(old_count)
			return true
		case .Disconnect:
			damage_capture_popover(old_count)
			if capture.client >= 0 && action.key_head != 0 {
				send(&clients[capture.client], .Capture_Disconnect, {0 = action.key_head})
				head_text: [8]u8
				head_writer := system.Writer{buffer = head_text[:]}
				head := transmute([8]u8)action.key_head
				system.write_hex(&head_writer, u64(head[0]) << 24 | u64(head[1]) << 16 | u64(head[2]) << 8 | u64(head[3]), 8)
				system.log_fact(.Info, Viewer_Disconnect_Requested{viewer_key_head = value_kinds.text_field(system.written(&head_writer), 24)})
			}
			return true
		}
	}
	if capture_mark_contains(x, y) {
		tray_widget_close() // tray_widgets.odin: one card at a time.
		if menu_open != .None {
			menu_open = .None
			menu_line = -1
			menu_action = .None
			damage_menu()
		}
		if bar.viewer_popover_mark_click(&capture_viewer_popover).kind == .Opened {
			damage_capture_popover(capture_viewer_popover.count)
		}
		return true
	}
	return false
}

// capture_popover_records appends the viewer list card below the bar mark when
// the popover is open.
capture_popover_records :: proc "contextless" (frame: ^interface.Frame) {
	if !capture_viewer_popover.open || capture_viewer_popover.count <= 0 {
		return
	}
	table := frame.table
	shift := capture_popover_shift(capture_viewer_popover.count)
	pop_x, pop_y, pop_w, pop_h := bar.viewer_popover_rect(capture_mark_x, capture_mark_width, desktop_width, capture_viewer_popover.count)
	pop_y += shift
	count: interface.Text_Builder
	interface.card(frame, {pop_x, pop_y, pop_w, pop_h}, "VIEWERS", "remote display", graphics.colors.warning, interface.number_text(&count, u64(capture_viewer_popover.count)))
	for index in 0 ..< capture_viewer_popover.count {
		row_x, row_y, _, _, row_ok := bar.viewer_popover_row_rect(capture_mark_x, capture_mark_width, desktop_width, capture_viewer_popover.count, index)
		btn_x, btn_y, btn_w, btn_h, btn_ok := bar.viewer_popover_disconnect_rect(capture_mark_x, capture_mark_width, desktop_width, capture_viewer_popover.count, index)
		if !row_ok || !btn_ok {
			continue
		}
		row_y += shift
		btn_y += shift
		viewer := capture_viewer_popover.viewers[index]
		label_buf: [bar.VIEWER_LABEL_CAPACITY]u8
		label := bar.viewer_key_label(viewer.key_head, viewer.has_input, label_buf[:])
		interface.draw_text(table, row_x + bar.PADDING, row_y + 4, label, graphics.colors.text, interface.FONT_INTERFACE)
		hovered := capture_viewer_popover.hovered_index == index
		fill := hovered ? graphics.colors.stop_process_pointer_over : graphics.colors.stop_process
		interface.draw_rectangle(table, btn_x, btn_y, btn_w, btn_h, fill)
		btn_text_w := interface.text_measured_width(table, interface.FONT_INTERFACE, bar.VIEWER_DISCONNECT_LABEL)
		interface.draw_text(table, btn_x + max((btn_w - btn_text_w) / 2, 0), btn_y + (btn_h - graphics.CELL_HEIGHT) / 2, bar.VIEWER_DISCONNECT_LABEL, graphics.COLOR_WHITE, interface.FONT_INTERFACE)
	}
}
