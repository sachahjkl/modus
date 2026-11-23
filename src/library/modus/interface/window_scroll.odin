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

// window_scroll_begin moves the input of the frame into the coordinates of
// the layout of a window that scrolls. focus_before is the focus before Tab
// moved it in this frame: a moved focus comes into the view.
@(private)
window_scroll_begin :: proc "contextless" (drawing: ^Window_Drawing, window: ^display.Window, focus_before: Element_Identity) {
	drawing.focus_before = focus_before
	drawing.bar_first, drawing.bar_end = 0, 0
	view_width, view_height := display.view_size(window)
	view := window_scroll_view_of(window.width, window.height, view_width, view_height)
	drawing.scroll_x = window_scroll_clamp(drawing.scroll_x, view.most_x)
	drawing.scroll_y = window_scroll_clamp(drawing.scroll_y, view.most_y)
	drawing.input_shift_x, drawing.input_shift_y = drawing.scroll_x, drawing.scroll_y
	input := &drawing.input
	input.pointer_x += drawing.input_shift_x
	input.pointer_y += drawing.input_shift_y
	input.press_x += drawing.input_shift_x
	input.press_y += drawing.input_shift_y
}

// window_input_unshift gives the input back its place in the view: an
// event between two frames comes in the coordinates of the surface.
@(private)
window_input_unshift :: proc "contextless" (drawing: ^Window_Drawing) {
	input := &drawing.input
	input.pointer_x -= drawing.input_shift_x
	input.pointer_y -= drawing.input_shift_y
	input.press_x -= drawing.input_shift_x
	input.press_y -= drawing.input_shift_y
	drawing.input_shift_x, drawing.input_shift_y = 0, 0
}

// window_scroll_input ends the scroll of a frame of a window that scrolls:
// PageUp and PageDown that no element took move the view by a page; a focus
// that moved in this frame comes into the view; then the scroll bar of each
// axis that does not fit, at the edge of the view where the input of the
// frame was (input_shift), takes the press and the wheel that no view of
// the window took. drawing.scroll is then the scroll of the layout in this
// frame. The records of the bars are bar_first ..< bar_end.
@(private)
window_scroll_input :: proc "contextless" (drawing: ^Window_Drawing, frame: ^Frame, window: ^display.Window) {
	drawing.bar_first, drawing.bar_end = 0, 0
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
		drawing.scroll_y = window_scroll_page(drawing.scroll_y, view.inner_height, LINE, key.code == display.KEY_PAGE_DOWN)
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
	drawing.scroll_x = window_scroll_clamp(drawing.scroll_x, view.most_x)
	drawing.scroll_y = window_scroll_clamp(drawing.scroll_y, view.most_y)
	// The bars lie at the edge of the view that the input of the frame
	// saw, so a press lands on the part of the bar under the pointer.
	left, top := drawing.input_shift_x, drawing.input_shift_y
	inner := Area{left, top, view.inner_width, view.inner_height}
	drawing.bar_first = frame.table.record_count
	if view.scrolls_y {
		bar := scroll_bar(frame, {left + view.inner_width, top, SCROLL_BAR_THICKNESS, view.inner_height}, identity("interface: the vertical scroll bar of the window"), .Vertical, {total = window.height, visible = view.inner_height, first = drawing.scroll_y}, {line = LINE}, "the window", inner)
		drawing.scroll_y = window_scroll_clamp(bar.first, view.most_y)
	}
	if view.scrolls_x {
		bar := scroll_bar(frame, {left, top + view.inner_height, view.inner_width, SCROLL_BAR_THICKNESS}, identity("interface: the horizontal scroll bar of the window"), .Horizontal, {total = window.width, visible = view.inner_width, first = drawing.scroll_x}, {line = LINE}, "the window", inner)
		drawing.scroll_x = window_scroll_clamp(bar.first, view.most_x)
	}
	if view.scrolls_x && view.scrolls_y {
		draw_rectangle(frame.table, left + view.inner_width, top + view.inner_height, SCROLL_BAR_THICKNESS, SCROLL_BAR_THICKNESS, graphics.colors.background)
	}
	drawing.bar_end = frame.table.record_count
}

// The gap that the focus into view leaves past the element.
WINDOW_SCROLL_GAP :: 8

// window_scroll_move moves each record of the frame into the view: the
// records of the bars by the scroll that placed them, each other one by the
// scroll of the layout, and the points of each path with its record. A
// window that fits its view moves nothing.
@(private)
window_scroll_move :: proc "contextless" (drawing: ^Window_Drawing) {
	table := &drawing.now
	if drawing.scroll_x == 0 && drawing.scroll_y == 0 && drawing.input_shift_x == 0 && drawing.input_shift_y == 0 {
		return
	}
	for &record, index in table.records[:table.record_count] {
		step_x, step_y := drawing.scroll_x, drawing.scroll_y
		if index >= drawing.bar_first && index < drawing.bar_end {
			step_x, step_y = drawing.input_shift_x, drawing.input_shift_y
		}
		units_x, units_y := -draw_record.units_of_pixels(step_x), -draw_record.units_of_pixels(step_y)
		moved, ok := draw_record.record_moved(record, units_x, units_y)
		if !ok {
			continue
		}
		if primitive, problem := draw_record.read(record); problem == .None {
			if path, is_path := primitive.(draw_record.Draw_Path); is_path && !path_points_of_table_move(table, path, units_x, units_y) {
				continue
			}
		}
		record = moved
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
