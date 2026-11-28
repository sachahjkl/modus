package interface

import "modus:contract/draw_record"
import "modus:display"
import "modus:graphics"
import "modus:system"

// The scroll of a window whose layout is larger than its view, the logical
// size of its surface (src/md/features/window_scroll.md). The compositor
// gives each window at most the work area; the frame is built in the
// coordinates of the layout, the input of the frame is moved into them, and
// at the end of the frame each record moves by the scroll, so the drawing
// module draws the part of the layout that the view shows. A window whose
// layout fits its view pays nothing.

// The view of a window: which axes do not fit, the part of the view that
// shows the layout once the scroll bars take their edges, and the largest
// scroll on each axis.
Window_Scroll_View :: struct {
	scrolls_x, scrolls_y:      bool,
	inner_width, inner_height: int,
	most_x, most_y:            int,
}

// window_scroll_view_of gives the view of a layout in a view. A bar takes
// an edge of the view, so a layout that fits on one axis alone can pass the
// view less the bar of the other axis: that axis scrolls too.
window_scroll_view_of :: proc "contextless" (layout_width, layout_height, view_width, view_height: int) -> (view: Window_Scroll_View) {
	view.scrolls_x = layout_width > view_width
	view.scrolls_y = layout_height > view_height
	// Two passes: a bar only adds a bar, on the other axis.
	for _ in 0 ..< 2 {
		view.scrolls_x = layout_width > view_width - (view.scrolls_y ? SCROLL_BAR_THICKNESS : 0)
		view.scrolls_y = layout_height > view_height - (view.scrolls_x ? SCROLL_BAR_THICKNESS : 0)
	}
	view.inner_width = max(view_width - (view.scrolls_y ? SCROLL_BAR_THICKNESS : 0), 0)
	view.inner_height = max(view_height - (view.scrolls_x ? SCROLL_BAR_THICKNESS : 0), 0)
	view.most_x = view.scrolls_x ? max(layout_width - view.inner_width, 0) : 0
	view.most_y = view.scrolls_y ? max(layout_height - view.inner_height, 0) : 0
	return
}

// window_scroll_clamp gives a scroll inside 0 to most: a larger view, or a
// smaller layout, never shows a part past the end.
window_scroll_clamp :: proc "contextless" (scroll, most: int) -> int {
	return clamp(scroll, 0, max(most, 0))
}

// window_scroll_to_show gives the scroll that shows the part from first to
// first + length of the layout in a view of inner units, with a gap past
// it: the same scroll when the part is in the view already. A part longer
// than the view shows its start.
window_scroll_to_show :: proc "contextless" (scroll, inner, first, length, gap: int) -> int {
	kept_gap := clamp(gap, 0, max(inner / 4, 0))
	switch {
	case first < scroll || length > inner:
		return first - kept_gap
	case first + length > scroll + inner:
		return first + length - inner + kept_gap
	}
	return scroll
}

// window_scroll_page gives the scroll after PageDown (down) or PageUp: the
// view less one line, so the line at its edge stays in sight, and at least
// one line.
window_scroll_page :: proc "contextless" (scroll, inner, line: int, down: bool) -> int {
	step := max(inner - line, line, 1)
	return down ? scroll + step : scroll - step
}

// The place of the pointer while it is over a bar strip of a window that
// scrolls, for the elements of the frame: no element of a layout reaches
// it, so an element under the bar takes no press, no wheel and no hover.
WINDOW_POINTER_AWAY :: -(1 << 24)

// The gap that the focus into view leaves past the element.
WINDOW_SCROLL_GAP :: 8

// layout_point_of_view gives the place in the layout of a place of the
// view, for a view of a layout and its scroll. in_layout is false over a
// bar strip: the place is then WINDOW_POINTER_AWAY on each axis. A place
// past the view, as a drag held past the edge, maps as a place inside it.
@(private)
layout_point_of_view :: proc "contextless" (view: Window_Scroll_View, scroll_x, scroll_y, view_width, view_height, x, y: int) -> (layout_x, layout_y: int, in_layout: bool) {
	over_vertical := view.scrolls_y && x >= view.inner_width && x < view_width && y >= 0 && y < view_height
	over_horizontal := view.scrolls_x && y >= view.inner_height && y < view_height && x >= 0 && x < view_width
	if over_vertical || over_horizontal {
		return WINDOW_POINTER_AWAY, WINDOW_POINTER_AWAY, false
	}
	return x + scroll_x, y + scroll_y, true
}

// window_layout_point gives the place in the layout of a window of a place
// of its view: the place of a pointer event. A process that tests the
// places of its raw events against its layout calls it for each event
// (src/md/features/window_scroll.md, "A process that reads its events").
// in_layout is false over a scroll bar of the window: the event belongs to
// the bar, and the place is WINDOW_POINTER_AWAY. A window that fits its
// view gives the place as it is. It reads no button: a drag that a press
// in the layout started stays in the layout over a bar in
// window_scroll_event.
window_layout_point :: proc "contextless" (drawing: ^Window_Drawing, window: ^display.Window, view_x, view_y: int) -> (x, y: int, in_layout: bool) {
	view_width, view_height := display.view_size(window)
	view := window_scroll_view_of(window.width, window.height, view_width, view_height)
	scroll_x := window_scroll_clamp(drawing.scroll_x, view.most_x)
	scroll_y := window_scroll_clamp(drawing.scroll_y, view.most_y)
	return layout_point_of_view(view, scroll_x, scroll_y, view_width, view_height, view_x, view_y)
}

// window_scroll_event takes an event that a process read itself with
// display.next_event, for a window that draws through a Window_Drawing
// with no window_events: a hand picture, or a frame that the process
// builds from its own loop. A process reads its events with
// window_next_event, which calls it for each one; a process that needs
// in_layout calls it itself. The pointer, and PageUp and PageDown when the
// layout scrolls, go to the input of the next frame, where the bars and the
// keys of the window take them. It gives the event with its place in the
// coordinates of the layout, which the process tests its elements against;
// in_layout false over a bar, except for a drag of any button that a press
// in the layout started, its release included, which stays in the layout;
// and show_due when the scroll needs a frame: a wheel, a press, a release,
// a pointer over a bar or a lit or held bar, or a page key. A caller skips
// an event with in_layout false: no drag of its own is active then.
window_scroll_event :: proc "contextless" (drawing: ^Window_Drawing, window: ^display.Window, event: display.Event, pointer_input := Pointer_Input.Scroll_Only) -> (layout_event: display.Event, in_layout: bool, show_due: bool) {
	layout_event, in_layout = event, true
	view_width, view_height := display.view_size(window)
	view := window_scroll_view_of(window.width, window.height, view_width, view_height)
	scrolls := view.scrolls_x || view.scrolls_y
	switch event.kind {
	case .Pointer:
		scroll_x := window_scroll_clamp(drawing.scroll_x, view.most_x)
		scroll_y := window_scroll_clamp(drawing.scroll_y, view.most_y)
		held_before := drawing.input.button_held
		// A window whose frames take no pointer gets none while it fits: no
		// hover and no press that it never took.
		switch pointer_input {
		case .Every_Event:
			_ = input_add(&drawing.input, event)
		case .Scroll_Only:
			if scrolls {
				_ = input_add(&drawing.input, event)
			}
		}
		held := event.buttons & display.BUTTON_LEFT != 0
		layout_event.x, layout_event.y, in_layout = layout_point_of_view(view, scroll_x, scroll_y, view_width, view_height, event.x, event.y)
		// The drag of any button: a press from no button starts it where it
		// lands; it lasts to the event that releases the last button.
		buttons_before := drawing.event_buttons
		if event.buttons != 0 && buttons_before == 0 {
			drawing.drag_from_layout = in_layout
		}
		// A drag that a press in the layout started stays in the layout
		// over a bar, to its release: a selection or a stroke follows the
		// pointer to the edge, and the release ends it in the layout.
		if !in_layout && buttons_before != 0 && drawing.drag_from_layout {
			layout_event.x, layout_event.y, in_layout = event.x + scroll_x, event.y + scroll_y, true
		}
		drawing.event_buttons = event.buttons
		if event.buttons == 0 {
			drawing.drag_from_layout = false
		}
		show_due = scrolls && (event.wheel != 0 || !in_layout || held != held_before || drawing.state.scroll_bar_lit != 0 || drawing.state.scroll_bar_part != .None)
	case .Key:
		if scrolls && event.pressed && (event.code == display.KEY_PAGE_UP || event.code == display.KEY_PAGE_DOWN) {
			show_due = input_add(&drawing.input, event)
		}
	case .None, .Presentation, .Go_To, .Resized, .Copy_Asked, .Pasted, .Capture_Size, .Capture_Frame, .Capture_Disconnect, .Capture_Opened, .Surface_Answer, .Work_Area, .Pointer_Delta, .Pointer_Lock_Changed:
		// The window layer reads no other event here: a new surface is
		// drawn whole by its serial (window_frame_begin_at).
	}
	drawing.scroll_frame_due ||= show_due
	return
}

// Which pointer events a process gives to the input of its frames.
Pointer_Input :: enum u8 {
	Scroll_Only, // The elements of the frames take no pointer: the pointer goes to the input only while the layout scrolls, for the bars.
	Every_Event, // The frames take the pointer: each pointer event goes to the input, in place of the input_add of the process.
}

// window_next_event reads the next event of a window, for a process that
// reads its events itself, in place of display.next_event; pointer_input
// says if its frames take the pointer: each event goes
// to the scroll of the window first (window_scroll_event), so the bars, the
// wheel and the page keys of a window that does not fit the work area work
// in each such loop. A pointer event comes in the coordinates of the
// layout; over a bar, with no drag of the process, its place is
// WINDOW_POINTER_AWAY, which no element reaches. A process that draws only
// when its own state changes also draws when window_scroll_frame_take says
// so.
window_next_event :: proc "contextless" (drawing: ^Window_Drawing, window: ^display.Window, pointer_input := Pointer_Input.Scroll_Only) -> (event: display.Event, ok: bool) {
	read := display.next_event(window) or_return
	event, _, _ = window_scroll_event(drawing, window, read, pointer_input)
	return event, true
}

// window_scroll_frame_take says if the scroll of the window needs a frame
// since the last call: an event changed the bars or the scroll. It gives
// it once.
window_scroll_frame_take :: proc "contextless" (drawing: ^Window_Drawing) -> (due: bool) {
	due = drawing.scroll_frame_due
	drawing.scroll_frame_due = false
	return
}

// window_scroll_begin moves the input of the frame into the coordinates of
// the layout of a window that scrolls, and hides the pointer from the
// elements of the frame while it is over a bar strip: the bars take it at
// the end of the frame (window_scroll_end). focus_before is the focus
// before Tab moved it in this frame: a moved focus comes into the view. An
// input that a frame left moved, with no end, comes back first.
@(private)
window_scroll_begin :: proc "contextless" (drawing: ^Window_Drawing, window: ^display.Window, focus_before: Element_Identity) {
	window_input_unshift(drawing)
	drawing.focus_before = focus_before
	drawing.bar_first = -1
	view_width, view_height := display.view_size(window)
	view := window_scroll_view_of(window.width, window.height, view_width, view_height)
	drawing.scroll_x = window_scroll_clamp(drawing.scroll_x, view.most_x)
	drawing.scroll_y = window_scroll_clamp(drawing.scroll_y, view.most_y)
	if !view.scrolls_x && !view.scrolls_y {
		return
	}
	input := &drawing.input
	drawing.view_pointer_x, drawing.view_pointer_y = input.pointer_x, input.pointer_y
	drawing.view_press_x, drawing.view_press_y = input.press_x, input.press_y
	drawing.view_right_press_x, drawing.view_right_press_y = input.right_press_x, input.right_press_y
	drawing.input_moved = true
	press_in_layout, pointer_in_layout: bool
	input.press_x, input.press_y, press_in_layout = layout_point_of_view(view, drawing.scroll_x, drawing.scroll_y, view_width, view_height, input.press_x, input.press_y)
	input.right_press_x, input.right_press_y, _ = layout_point_of_view(view, drawing.scroll_x, drawing.scroll_y, view_width, view_height, input.right_press_x, input.right_press_y)
	input.pointer_x, input.pointer_y, pointer_in_layout = layout_point_of_view(view, drawing.scroll_x, drawing.scroll_y, view_width, view_height, input.pointer_x, input.pointer_y)
	// A drag that a press in the layout started stays in the layout over a
	// bar: the element that holds it follows the pointer.
	if !pointer_in_layout && input.button_held && press_in_layout {
		input.pointer_x, input.pointer_y = drawing.view_pointer_x + drawing.scroll_x, drawing.view_pointer_y + drawing.scroll_y
	}
}

// window_input_unshift gives the input back its places in the view: the
// bars of the window take it so, and an event between two frames comes in
// the coordinates of the surface.
@(private)
window_input_unshift :: proc "contextless" (drawing: ^Window_Drawing) {
	if !drawing.input_moved {
		return
	}
	input := &drawing.input
	input.pointer_x, input.pointer_y = drawing.view_pointer_x, drawing.view_pointer_y
	input.press_x, input.press_y = drawing.view_press_x, drawing.view_press_y
	input.right_press_x, input.right_press_y = drawing.view_right_press_x, drawing.view_right_press_y
	drawing.input_moved = false
}

// window_scroll_end ends the scroll of a frame of a window that scrolls:
// PageUp and PageDown that no element took move the view by a page; a focus
// that moved in this frame comes into the view. With bars, it then closes
// the clips that the frame left open, gives the input back its places in
// the view, and draws the scroll bar of each axis that does not fit, in the
// coordinates of the view, after each record of the frame: each takes the
// press and the wheel that no view of the window took. drawing.scroll is
// then the scroll of the layout in this frame, and the records before
// drawing.bar_first move by it (window_scroll_move). A frame that draws
// into a hand picture has no bars: the frame that shows the picture draws
// them (hand_picture_show).
@(private)
window_scroll_end :: proc "contextless" (drawing: ^Window_Drawing, frame: ^Frame, window: ^display.Window, bars: bool) {
	drawing.bar_first = -1
	view_width, view_height := display.view_size(window)
	view := window_scroll_view_of(window.width, window.height, view_width, view_height)
	if !view.scrolls_x && !view.scrolls_y {
		drawing.scroll_x, drawing.scroll_y = 0, 0
		drawing.scroll_logged = false
		return
	}
	title := string(window.title[:window.title_count])
	if !drawing.scroll_logged {
		drawing.scroll_logged = true
		system.log(.Info, "interface: ", title, ": the layout of ", u64(window.width), "x", u64(window.height), " scrolls in a view of ", u64(view_width), "x", u64(view_height))
	}
	for &key in frame.input.keys[:frame.input.key_count] {
		if key.taken || !view.scrolls_y || key.code != display.KEY_PAGE_UP && key.code != display.KEY_PAGE_DOWN {
			continue
		}
		key.taken = true
		drawing.scroll_y = window_scroll_clamp(window_scroll_page(drawing.scroll_y, view.inner_height, LINE, key.code == display.KEY_PAGE_DOWN), view.most_y)
		system.log(.Info, "interface: ", title, ": the keys move the view to ", u64(drawing.scroll_x), ",", u64(drawing.scroll_y))
	}
	if frame.state.focus != drawing.focus_before && frame.focus_area_known {
		area := frame.focus_area
		before_x, before_y := drawing.scroll_x, drawing.scroll_y
		if view.scrolls_x {
			drawing.scroll_x = window_scroll_to_show(drawing.scroll_x, view.inner_width, area.x, area.width, WINDOW_SCROLL_GAP)
		}
		if view.scrolls_y {
			drawing.scroll_y = window_scroll_to_show(drawing.scroll_y, view.inner_height, area.y, area.height, WINDOW_SCROLL_GAP)
		}
		drawing.scroll_x = window_scroll_clamp(drawing.scroll_x, view.most_x)
		drawing.scroll_y = window_scroll_clamp(drawing.scroll_y, view.most_y)
		if drawing.scroll_x != before_x || drawing.scroll_y != before_y {
			system.log(.Info, "interface: ", title, ": the focus moves the view to ", u64(drawing.scroll_x), ",", u64(drawing.scroll_y))
		}
	}
	start_x, start_y := drawing.scroll_x, drawing.scroll_y
	drawing.scroll_x = window_scroll_clamp(drawing.scroll_x, view.most_x)
	drawing.scroll_y = window_scroll_clamp(drawing.scroll_y, view.most_y)
	if !bars {
		if drawing.scroll_x != start_x || drawing.scroll_y != start_y {
			frame.scroll_moved = true
		}
		return
	}
	// A bar inside a clip of the frame would be cut by it.
	draw_clips_close(frame.table)
	window_input_unshift(drawing)
	inner := Area{0, 0, view.inner_width, view.inner_height}
	drawing.bar_first = frame.table.record_count
	if view.scrolls_y {
		bar := scroll_bar(frame, {view.inner_width, 0, SCROLL_BAR_THICKNESS, view.inner_height}, identity("interface: the vertical scroll bar of the window"), .Vertical, {total = window.height, visible = view.inner_height, first = drawing.scroll_y}, {line = LINE}, "the window", inner)
		drawing.scroll_y = window_scroll_clamp(bar.first, view.most_y)
	}
	if view.scrolls_x {
		bar := scroll_bar(frame, {0, view.inner_height, view.inner_width, SCROLL_BAR_THICKNESS}, identity("interface: the horizontal scroll bar of the window"), .Horizontal, {total = window.width, visible = view.inner_width, first = drawing.scroll_x}, {line = LINE}, "the window", inner)
		drawing.scroll_x = window_scroll_clamp(bar.first, view.most_x)
	}
	if drawing.scroll_x != start_x || drawing.scroll_y != start_y {
		frame.scroll_moved = true
	}
	if view.scrolls_x && view.scrolls_y {
		draw_rectangle(frame.table, view.inner_width, view.inner_height, SCROLL_BAR_THICKNESS, SCROLL_BAR_THICKNESS, graphics.colors.background)
	}
}

// window_scroll_move moves each record of the frame before its bars into
// the view by the scroll of the layout, and the points of each path with
// its record. A record that the move would take past the coordinate limit,
// and a path whose points would, draws nothing in its place
// (draw_record.record_hidden): a record half moved would draw at a place
// of the layout that the view does not show. A window that fits its view
// moves nothing.
@(private)
window_scroll_move :: proc "contextless" (drawing: ^Window_Drawing) {
	table := &drawing.now
	if drawing.scroll_x == 0 && drawing.scroll_y == 0 {
		return
	}
	end := drawing.bar_first >= 0 ? min(drawing.bar_first, table.record_count) : table.record_count
	units_x, units_y := -draw_record.units_of_pixels(drawing.scroll_x), -draw_record.units_of_pixels(drawing.scroll_y)
	for &record in table.records[:end] {
		moved, ok := draw_record.record_moved(record, units_x, units_y)
		if ok {
			if primitive, problem := draw_record.read(record); problem == .None {
				if path, is_path := primitive.(draw_record.Draw_Path); is_path {
					ok = path_points_of_table_move(table, path, units_x, units_y)
				}
			}
		}
		record = ok ? moved : draw_record.record_hidden(record)
	}
}

// path_points_of_table_move moves the points of a path in the text table of
// a frame. false: the range is outside the text, or a point would pass the
// limit; nothing moves.
@(private)
path_points_of_table_move :: proc "contextless" (table: ^Draw_Table, path: draw_record.Draw_Path, step_x, step_y: i32) -> bool {
	first, count := int(path.first), int(path.count)
	if count == 0 {
		return true
	}
	if first < 0 || count < 0 || first + count > table.text_count || first % align_of(draw_record.Path_Point_Record) != 0 || count % draw_record.PATH_POINT_SIZE != 0 {
		return false
	}
	points := ([^]draw_record.Path_Point_Record)(&table.text[first])[:count / draw_record.PATH_POINT_SIZE]
	return draw_record.path_points_move(points, step_x, step_y)
}
