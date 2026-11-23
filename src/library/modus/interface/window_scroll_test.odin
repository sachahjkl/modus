#+build !freestanding
package interface

import "core:testing"
import "modus:contract/draw_record"
import "modus:contract/ring"
import "modus:contract/scale_factor"
import "modus:display"
import "modus:graphics"

// The view of a layout: a layout that fits on both axes scrolls on none;
// one unit past the view on one axis scrolls on it, and its bar can make
// the other axis pass too. The settings window at 2, 560 x 688 in a view
// of 560 x 482, scrolls down only when its width fits beside the bar.
@(test)
the_view_of_a_layout_scrolls_on_each_axis_that_passes :: proc(t: ^testing.T) {
	T :: SCROLL_BAR_THICKNESS
	fits := window_scroll_view_of(560, 482, 560, 482)
	testing.expect(t, !fits.scrolls_x && !fits.scrolls_y && fits.most_x == 0 && fits.most_y == 0 && fits.inner_width == 560 && fits.inner_height == 482)
	down := window_scroll_view_of(500, 688, 560, 482)
	testing.expect(t, !down.scrolls_x && down.scrolls_y && down.inner_width == 560 - T && down.most_y == 688 - 482)
	// One unit past the height: the bar takes 17 columns, and a layout of
	// the whole width then passes the view less the bar.
	both := window_scroll_view_of(560, 483, 560, 482)
	testing.expect(t, both.scrolls_x && both.scrolls_y && both.inner_width == 560 - T && both.inner_height == 482 - T)
	testing.expect(t, both.most_x == T && both.most_y == 483 - (482 - T))
	// A view smaller than the bars: no room, and the whole layout to scroll.
	tiny := window_scroll_view_of(100, 100, 5, 5)
	testing.expect(t, tiny.inner_width == 0 && tiny.inner_height == 0 && tiny.most_x == 100 && tiny.most_y == 100)
	// A layout of 0: nothing scrolls.
	empty := window_scroll_view_of(0, 0, 560, 482)
	testing.expect(t, !empty.scrolls_x && !empty.scrolls_y)
}

// The clamp keeps a scroll inside 0 to most, the edges and past them, and
// a most below 0 keeps 0.
@(test)
a_scroll_stays_inside_its_layout :: proc(t: ^testing.T) {
	testing.expect_value(t, window_scroll_clamp(-1, 100), 0)
	testing.expect_value(t, window_scroll_clamp(min(int), 100), 0)
	testing.expect_value(t, window_scroll_clamp(0, 100), 0)
	testing.expect_value(t, window_scroll_clamp(100, 100), 100)
	testing.expect_value(t, window_scroll_clamp(101, 100), 100)
	testing.expect_value(t, window_scroll_clamp(max(int), 100), 100)
	testing.expect_value(t, window_scroll_clamp(5, -3), 0)
}

// The focus into view: a part in the view keeps the scroll, at each edge
// exactly; one unit past an edge moves the view by the part and the gap; a
// part longer than the view shows its start; a negative gap is no gap.
@(test)
a_part_comes_into_the_view_with_its_gap :: proc(t: ^testing.T) {
	testing.expect_value(t, window_scroll_to_show(100, 400, 100, 24, 8), 100)
	testing.expect_value(t, window_scroll_to_show(100, 400, 476, 24, 8), 100)
	testing.expect_value(t, window_scroll_to_show(100, 400, 477, 24, 8), 109)
	testing.expect_value(t, window_scroll_to_show(100, 400, 99, 24, 8), 91)
	testing.expect_value(t, window_scroll_to_show(100, 400, 0, 500, 8), -8)
	testing.expect_value(t, window_scroll_to_show(100, 400, 99, 24, -5), 99)
	// A gap larger than a quarter of the view is cut to it.
	testing.expect_value(t, window_scroll_to_show(0, 40, 50, 10, 100), 30)
}

// A page is the view less one line, at least one line, in each direction.
@(test)
a_page_keeps_one_line_in_sight :: proc(t: ^testing.T) {
	testing.expect_value(t, window_scroll_page(0, 482, 16, true), 466)
	testing.expect_value(t, window_scroll_page(466, 482, 16, false), 0)
	testing.expect_value(t, window_scroll_page(0, 10, 16, true), 16)
	testing.expect_value(t, window_scroll_page(0, 0, 0, true), 1)
}

// A window in plain memory whose layout of 200 x 300 scrolls in a view of
// 200 x 100: both axes scroll, the inner view is 183 x 83.
@(private = "file")
LAYOUT_WIDTH :: 200
@(private = "file")
LAYOUT_HEIGHT :: 300
@(private = "file")
VIEW_WIDTH :: 200
@(private = "file")
VIEW_HEIGHT :: 100
@(private = "file")
SURFACE_LIMIT :: (VIEW_WIDTH * 16 + scale_factor.EIGHTHS_OF_ONE - 1) / scale_factor.EIGHTHS_OF_ONE

@(private = "file")
Scroll_Test_Window :: struct {
	counters: ring.Counters,
	records:  [8]ring.Record,
	window:   display.Window,
	memory:   Window_Memory(64, 256),
}

@(private = "file")
scroll_test_window :: proc(test: ^Scroll_Test_Window, pixels: []graphics.Color, scale: scale_factor.Scale) -> (drawing: ^Window_Drawing, canvas: graphics.Canvas) {
	width := int(scale_factor.screen_pixel_of_logical_pixel(VIEW_WIDTH, scale))
	height := int(scale_factor.screen_pixel_of_logical_pixel(VIEW_HEIGHT, scale))
	canvas = {pixels = raw_data(pixels), width = width, height = height, stride = width}
	window := &test.window
	window.ring.commands = {counters = &test.counters, records = raw_data(test.records[:]), mask = 7}
	window.pictures = {canvas, canvas}
	window.canvas = canvas
	window.width, window.height = LAYOUT_WIDTH, LAYOUT_HEIGHT
	window.view_width, window.view_height = VIEW_WIDTH, VIEW_HEIGHT
	window.rescale = {phase = .Steady, scale = scale, wanted = scale, serial = 1}
	return window_memory_drawing(&test.memory), canvas
}

// A press lands on the element of the layout that the view shows under it,
// at 1.25 and at 2: the input of the frame is in the coordinates of the
// layout, the records move by the scroll, and the pixel under the press
// has the color of the element. After the frame the input is back in the
// view. The same element drawn with no move is elsewhere: the check can
// fail.
@(test)
a_press_reaches_the_element_that_a_scrolled_view_shows :: proc(t: ^testing.T) {
	process_drawing_begin()
	ELEMENT :: Area{10, 70, 40, 20}
	PRESS_X :: 20
	PRESS_Y :: 30
	SCROLL_Y :: 50
	ELEMENT_COLOR :: graphics.Color(0x30A050)
	BACKGROUND :: graphics.Color(0x101010)
	pixels := make([]graphics.Color, SURFACE_LIMIT * SURFACE_LIMIT)
	defer delete(pixels)
	for scale in ([?]scale_factor.Scale{.Ten_Eighths, .Sixteen_Eighths}) {
		test := new(Scroll_Test_Window)
		defer free(test)
		drawing, canvas := scroll_test_window(test, pixels, scale)
		drawing.scroll_y = SCROLL_Y
		testing.expect(t, input_add(&drawing.input, {kind = .Pointer, x = PRESS_X, y = PRESS_Y, buttons = display.BUTTON_LEFT}))
		frame := window_frame_begin_at(drawing, &test.window, nil, 0)
		testing.expectf(t, drawing.input.pointer_y == PRESS_Y + SCROLL_Y && drawing.input.press_y == PRESS_Y + SCROLL_Y, "at %v the input is at %d", scale, drawing.input.pointer_y)
		result := element_interact(&frame, identity("element"), ELEMENT, .Button)
		testing.expectf(t, result.under_pointer, "at %v the press is not on the element", scale)
		draw_rectangle(frame.table, ELEMENT.x, ELEMENT.y, ELEMENT.width, ELEMENT.height, ELEMENT_COLOR)
		window_scroll_end(drawing, &frame, &test.window, true)
		frame_end(&frame)
		window_scroll_move(drawing)
		window_input_unshift(drawing)
		testing.expectf(t, drawing.input.pointer_x == PRESS_X && drawing.input.pointer_y == PRESS_Y && drawing.input.press_y == PRESS_Y, "at %v the input is not back in the view", scale)
		testing.expectf(t, drawing.bar_first == 1 && frame.table.record_count > 1, "at %v the bars are not after the frame", scale)
		graphics.clear(canvas, BACKGROUND)
		execute(frame.table, canvas)
		pressed_x := int(scale_factor.screen_pixel_of_logical_pixel(PRESS_X, scale))
		pressed_y := int(scale_factor.screen_pixel_of_logical_pixel(PRESS_Y, scale))
		testing.expectf(t, pixels[pressed_y * canvas.stride + pressed_x] == ELEMENT_COLOR, "at %v the pixel under the press is %x", scale, pixels[pressed_y * canvas.stride + pressed_x])
		// The record with no move: the element is 50 lines lower.
		unmoved := frame.table.records[0]
		moved_back, back_ok := draw_record.record_moved(unmoved, 0, draw_record.units_of_pixels(SCROLL_Y))
		testing.expect(t, back_ok)
		frame.table.records[0] = moved_back
		graphics.clear(canvas, BACKGROUND)
		execute(frame.table, canvas)
		testing.expectf(t, pixels[pressed_y * canvas.stride + pressed_x] != ELEMENT_COLOR, "at %v the unmoved element covers the press: the check cannot fail", scale)
	}
}

// The pointer over a bar strip: no element of the frame sees it, also one
// that covers the whole layout, and the bar of the window takes the press.
// One unit inside the inner view, the element sees it.
@(test)
the_pointer_over_a_bar_strip_belongs_to_the_bar :: proc(t: ^testing.T) {
	process_drawing_begin()
	pixels := make([]graphics.Color, SURFACE_LIMIT * SURFACE_LIMIT)
	defer delete(pixels)
	view := window_scroll_view_of(LAYOUT_WIDTH, LAYOUT_HEIGHT, VIEW_WIDTH, VIEW_HEIGHT)
	for x in ([?]int{view.inner_width, VIEW_WIDTH - 1, view.inner_width - 1}) {
		test := new(Scroll_Test_Window)
		defer free(test)
		drawing, _ := scroll_test_window(test, pixels, .Sixteen_Eighths)
		testing.expect(t, input_add(&drawing.input, {kind = .Pointer, x = x, y = 30, buttons = display.BUTTON_LEFT}))
		frame := window_frame_begin_at(drawing, &test.window, nil, 0)
		result := element_interact(&frame, identity("the whole layout"), {0, 0, LAYOUT_WIDTH, LAYOUT_HEIGHT}, .Button)
		window_scroll_end(drawing, &frame, &test.window, true)
		frame_end(&frame)
		window_scroll_move(drawing)
		window_input_unshift(drawing)
		over_bar := x >= view.inner_width
		testing.expectf(t, result.under_pointer == !over_bar, "at x %d the element sees the pointer: %v", x, result.under_pointer)
		bar_holds := drawing.state.pressed == identity("interface: the vertical scroll bar of the window")
		testing.expectf(t, bar_holds == over_bar, "at x %d the bar holds the press: %v", x, bar_holds)
	}
}

// PageDown moves the view by a page and stops at the end; PageUp comes
// back; a key that an element took moves nothing. A window that fits
// takes no page key, and its scroll is 0.
@(test)
the_page_keys_move_the_view_of_a_window_that_scrolls :: proc(t: ^testing.T) {
	process_drawing_begin()
	pixels := make([]graphics.Color, SURFACE_LIMIT * SURFACE_LIMIT)
	defer delete(pixels)
	view := window_scroll_view_of(LAYOUT_WIDTH, LAYOUT_HEIGHT, VIEW_WIDTH, VIEW_HEIGHT)
	test := new(Scroll_Test_Window)
	defer free(test)
	drawing, _ := scroll_test_window(test, pixels, .Ten_Eighths)
	press_keys :: proc(drawing: ^Window_Drawing, window: ^display.Window, code: u32, count: int, taken: bool) {
		for _ in 0 ..< count {
			_ = input_add(&drawing.input, {kind = .Key, code = code, pressed = true})
		}
		frame := window_frame_begin_at(drawing, window, nil, 0)
		if taken {
			for &key in frame.input.keys[:frame.input.key_count] {
				key.taken = true
			}
		}
		window_scroll_end(drawing, &frame, window, true)
		frame_end(&frame)
		window_scroll_move(drawing)
		window_input_unshift(drawing)
		input_clear(&drawing.input)
	}
	press_keys(drawing, &test.window, display.KEY_PAGE_DOWN, 1, false)
	testing.expect_value(t, drawing.scroll_y, window_scroll_page(0, view.inner_height, LINE, true))
	press_keys(drawing, &test.window, display.KEY_PAGE_DOWN, 5, false)
	testing.expect_value(t, drawing.scroll_y, view.most_y)
	press_keys(drawing, &test.window, display.KEY_PAGE_UP, 1, true)
	testing.expect_value(t, drawing.scroll_y, view.most_y)
	press_keys(drawing, &test.window, display.KEY_PAGE_UP, 5, false)
	testing.expect_value(t, drawing.scroll_y, 0)
	test.window.width, test.window.height = VIEW_WIDTH, VIEW_HEIGHT
	drawing.scroll_y = 40
	press_keys(drawing, &test.window, display.KEY_PAGE_DOWN, 1, false)
	testing.expect_value(t, drawing.scroll_y, 0)
}

// Shift+Tab moves the focus to an element below the view: the view moves to
// show it with its gap.
@(test)
a_focus_below_the_view_comes_into_it :: proc(t: ^testing.T) {
	process_drawing_begin()
	pixels := make([]graphics.Color, SURFACE_LIMIT * SURFACE_LIMIT)
	defer delete(pixels)
	view := window_scroll_view_of(LAYOUT_WIDTH, LAYOUT_HEIGHT, VIEW_WIDTH, VIEW_HEIGHT)
	test := new(Scroll_Test_Window)
	defer free(test)
	drawing, _ := scroll_test_window(test, pixels, .Sixteen_Eighths)
	LOW :: Area{10, 250, 40, 20}
	build :: proc(drawing: ^Window_Drawing, window: ^display.Window) {
		frame := window_frame_begin_at(drawing, window, nil, 0)
		_ = element_interact(&frame, identity("high"), {10, 10, 40, 20}, .Button)
		_ = element_interact(&frame, identity("low"), LOW, .Button)
		window_scroll_end(drawing, &frame, window, true)
		frame_end(&frame)
		window_scroll_move(drawing)
		window_input_unshift(drawing)
		input_clear(&drawing.input)
	}
	build(drawing, &test.window)
	testing.expect_value(t, drawing.scroll_y, 0)
	_ = input_add(&drawing.input, {kind = .Key, code = KEY_TAB, modifiers = display.MODIFIER_SHIFT, pressed = true})
	build(drawing, &test.window)
	testing.expect(t, drawing.state.focus == identity("low"))
	testing.expect_value(t, drawing.scroll_y, window_scroll_clamp(window_scroll_to_show(0, view.inner_height, LOW.y, LOW.height, WINDOW_SCROLL_GAP), view.most_y))
}

// A frame that begins twice with no end moves the input once: the second
// begin gives the input its places in the view back first.
@(test)
a_second_begin_moves_the_input_once :: proc(t: ^testing.T) {
	process_drawing_begin()
	pixels := make([]graphics.Color, SURFACE_LIMIT * SURFACE_LIMIT)
	defer delete(pixels)
	test := new(Scroll_Test_Window)
	defer free(test)
	drawing, _ := scroll_test_window(test, pixels, .Ten_Eighths)
	drawing.scroll_y = 50
	_ = input_add(&drawing.input, {kind = .Pointer, x = 20, y = 30})
	_ = window_frame_begin_at(drawing, &test.window, nil, 0)
	_ = window_frame_begin_at(drawing, &test.window, nil, 0)
	testing.expect_value(t, drawing.input.pointer_y, 80)
	window_input_unshift(drawing)
	testing.expect_value(t, drawing.input.pointer_y, 30)
	window_input_unshift(drawing)
	testing.expect_value(t, drawing.input.pointer_y, 30)
}

// A raw event of a process: a place in the inner view maps to the layout
// by the scroll; a place over a bar strip is the bar's, away from each
// element; a place past the view, as a drag held past its edge, maps as a
// place inside it. A window that fits gives the place as it is. The page
// keys go to the input only when the layout scrolls.
@(test)
a_raw_event_maps_to_the_layout :: proc(t: ^testing.T) {
	process_drawing_begin()
	pixels := make([]graphics.Color, SURFACE_LIMIT * SURFACE_LIMIT)
	defer delete(pixels)
	view := window_scroll_view_of(LAYOUT_WIDTH, LAYOUT_HEIGHT, VIEW_WIDTH, VIEW_HEIGHT)
	test := new(Scroll_Test_Window)
	defer free(test)
	drawing, _ := scroll_test_window(test, pixels, .Ten_Eighths)
	drawing.scroll_x, drawing.scroll_y = 5, 50
	x, y, inside := window_layout_point(drawing, &test.window, 20, 30)
	testing.expect(t, inside && x == 25 && y == 80)
	x, y, inside = window_layout_point(drawing, &test.window, view.inner_width, 30)
	testing.expect(t, !inside && x == WINDOW_POINTER_AWAY && y == WINDOW_POINTER_AWAY)
	x, y, inside = window_layout_point(drawing, &test.window, 20, view.inner_height)
	testing.expect(t, !inside)
	x, y, inside = window_layout_point(drawing, &test.window, VIEW_WIDTH + 10, -4)
	testing.expect(t, inside && x == VIEW_WIDTH + 15 && y == 46)
	// A scroll past the end is clamped before the map.
	drawing.scroll_y = 10_000
	_, y, _ = window_layout_point(drawing, &test.window, 0, 0)
	testing.expect_value(t, y, view.most_y)
	drawing.scroll_y = 50
	event, in_layout, due := window_scroll_event(drawing, &test.window, {kind = .Pointer, x = 20, y = 30})
	testing.expect(t, in_layout && event.x == 25 && event.y == 80 && !due && drawing.input.pointer_y == 30)
	event, in_layout, due = window_scroll_event(drawing, &test.window, {kind = .Pointer, x = VIEW_WIDTH - 1, y = 30})
	testing.expect(t, !in_layout && due)
	event, in_layout, due = window_scroll_event(drawing, &test.window, {kind = .Pointer, x = 20, y = 30, wheel = 1})
	testing.expect(t, in_layout && due && drawing.input.wheel == 1)
	_, _, due = window_scroll_event(drawing, &test.window, {kind = .Key, code = display.KEY_PAGE_DOWN, pressed = true})
	testing.expect(t, due && drawing.input.key_count == 1)
	_, _, due = window_scroll_event(drawing, &test.window, {kind = .Key, code = display.KEY_PAGE_DOWN})
	testing.expect(t, !due && drawing.input.key_count == 1)
	_, _, due = window_scroll_event(drawing, &test.window, {kind = .Key, code = 'a', character = 'a', pressed = true})
	testing.expect(t, !due && drawing.input.key_count == 1)
	test.window.width, test.window.height = VIEW_WIDTH, VIEW_HEIGHT
	x, y, inside = window_layout_point(drawing, &test.window, VIEW_WIDTH - 1, 30)
	testing.expect(t, inside && x == VIEW_WIDTH - 1 && y == 30)
	_, _, due = window_scroll_event(drawing, &test.window, {kind = .Key, code = display.KEY_PAGE_DOWN, pressed = true})
	testing.expect(t, !due && drawing.input.key_count == 1)
}

// The points of a path in the text table of a frame: a range outside the
// text, not on a point, or of a part of a point moves nothing; a point that
// would pass the limit moves no point; no point is a move; a whole range
// moves each point.
@(test)
the_points_of_a_path_move_in_the_text_table :: proc(t: ^testing.T) {
	words: [12]u32
	records: [4]Draw_Record
	table := Draw_Table{records = records[:], text = ([^]u8)(raw_data(words[:]))[:len(words) * 4]}
	points := ([^]draw_record.Path_Point_Record)(raw_data(words[:]))[:3]
	points[0] = {command = 0, x = 64, y = 640}
	points[1] = {command = 1, x = 128, y = 1280}
	points[2] = {command = 1, x = 192, y = 640}
	table.text_count = 3 * draw_record.PATH_POINT_SIZE
	before := points[0]
	testing.expect(t, !path_points_of_table_move(&table, {first = 0, count = 4 * draw_record.PATH_POINT_SIZE}, 0, -64))
	testing.expect(t, !path_points_of_table_move(&table, {first = 2, count = draw_record.PATH_POINT_SIZE}, 0, -64))
	testing.expect(t, !path_points_of_table_move(&table, {first = 0, count = draw_record.PATH_POINT_SIZE - 1}, 0, -64))
	testing.expect(t, !path_points_of_table_move(&table, {first = 0, count = draw_record.PATH_POINT_SIZE}, 0, max(i32)))
	testing.expect(t, points[0] == before)
	testing.expect(t, path_points_of_table_move(&table, {first = 0, count = 0}, 0, max(i32)))
	testing.expect(t, path_points_of_table_move(&table, {first = 0, count = 3 * draw_record.PATH_POINT_SIZE}, 64, -640))
	testing.expect(t, points[0].x == 128 && points[0].y == 0 && points[1].y == 640 && points[2].x == 256)
}

// The move of a frame: each record before the bars moves by the scroll,
// the bars stay; a record that the move takes past the limit draws nothing,
// a push past it keeps its kind with an empty box, and a path whose points
// would pass the limit draws nothing.
@(test)
the_move_of_a_frame_hides_each_record_past_the_limit :: proc(t: ^testing.T) {
	process_drawing_begin()
	pixels := make([]graphics.Color, SURFACE_LIMIT * SURFACE_LIMIT)
	defer delete(pixels)
	test := new(Scroll_Test_Window)
	defer free(test)
	drawing, _ := scroll_test_window(test, pixels, .Ten_Eighths)
	table := &drawing.now
	draw_table_clear(table)
	LIMIT :: draw_record.COORDINATE_UNIT_LIMIT
	records := [?]Draw_Record{
		draw_record.record_of(draw_record.Draw_Rectangle{color = 0xFF102030}, 0, 0, 6400, 640, 7040),
		draw_record.record_of(draw_record.Draw_Clip_Push{}, 0, 0, -LIMIT + 64, 640, 640),
		draw_record.record_of(draw_record.Draw_Rectangle{color = 0xFF102030}, 0, 0, -LIMIT + 64, 640, 640),
		draw_record.record_of(draw_record.Draw_Clip_Pop{}, 0, 0, 0, 0, 0),
		draw_record.record_of(draw_record.Draw_Path{first = 0, count = 2 * draw_record.PATH_POINT_SIZE, fill_color = 0xFF102030}, 0, 0, 0, 640, 640),
		draw_record.record_of(draw_record.Draw_Rectangle{color = 0xFF405060}, 0, 0, 0, 640, 640),
	}
	copy(table.records, records[:])
	table.record_count = len(records)
	points := [2]draw_record.Path_Point_Record{{command = 0, x = 0, y = 640}, {command = 1, x = 640, y = -LIMIT + 64}}
	copy(table.text, ([^]u8)(&points)[:size_of(points)])
	table.text_count = size_of(points)
	drawing.scroll_y = 2
	drawing.bar_first = len(records) - 1
	window_scroll_move(drawing)
	testing.expect_value(t, table.records[0].top, 6400 - 128)
	testing.expect(t, table.records[1] == draw_record.record_of(draw_record.Draw_Clip_Push{}, 0, 0, 0, 0, 0))
	testing.expect(t, table.records[2] == draw_record.record_of(draw_record.Draw_Nothing{}, 0, 0, 0, 0, 0))
	testing.expect(t, table.records[3] == records[3])
	testing.expect(t, table.records[4] == draw_record.record_of(draw_record.Draw_Nothing{}, 0, 0, 0, 0, 0))
	// No point of the path moved.
	moved_points := ([^]draw_record.Path_Point_Record)(raw_data(table.text))[:2]
	testing.expect(t, moved_points[0] == points[0] && moved_points[1] == points[1])
	testing.expect(t, table.records[5] == records[5])
	problem, _ := draw_record.clip_order_check(table.records[:table.record_count])
	testing.expect_value(t, problem, draw_record.Clip_Order_Problem.None)
}

// A new surface draws whole: a frame that begins with another surface
// serial than the frame before has no picture known.
@(test)
a_new_surface_serial_draws_the_next_frame_whole :: proc(t: ^testing.T) {
	process_drawing_begin()
	pixels := make([]graphics.Color, SURFACE_LIMIT * SURFACE_LIMIT)
	defer delete(pixels)
	test := new(Scroll_Test_Window)
	defer free(test)
	drawing, _ := scroll_test_window(test, pixels, .Ten_Eighths)
	_ = window_frame_begin_at(drawing, &test.window, nil, 0)
	drawing.debts.known[0], drawing.debts.known[1] = true, true
	_ = window_frame_begin_at(drawing, &test.window, nil, 0)
	testing.expect(t, drawing.debts.known[0] && drawing.debts.known[1])
	test.window.rescale.serial += 1
	_ = window_frame_begin_at(drawing, &test.window, nil, 0)
	testing.expect(t, !drawing.debts.known[0] && !drawing.debts.known[1])
}

// A drag of any button that a press in the layout started stays in the
// layout over a bar, its release included, so a stroke or a selection ends
// where the pointer left it; the next event over the bar is the bar's. A
// press on a bar is the bar's, and so is its release over the bar. The
// scroll asks a frame once for each event that needs one.
@(test)
a_drag_from_the_layout_ends_in_the_layout_over_a_bar :: proc(t: ^testing.T) {
	process_drawing_begin()
	pixels := make([]graphics.Color, SURFACE_LIMIT * SURFACE_LIMIT)
	defer delete(pixels)
	view := window_scroll_view_of(LAYOUT_WIDTH, LAYOUT_HEIGHT, VIEW_WIDTH, VIEW_HEIGHT)
	BAR_X :: VIEW_WIDTH - 5
	for button in ([?]u32{display.BUTTON_RIGHT, display.BUTTON_LEFT}) {
		test := new(Scroll_Test_Window)
		defer free(test)
		drawing, _ := scroll_test_window(test, pixels, .Ten_Eighths)
		drawing.scroll_x, drawing.scroll_y = 5, 50
		event, in_layout, _ := window_scroll_event(drawing, &test.window, {kind = .Pointer, x = 20, y = 30, buttons = button})
		testing.expect(t, in_layout && event.x == 25 && event.y == 80)
		event, in_layout, _ = window_scroll_event(drawing, &test.window, {kind = .Pointer, x = BAR_X, y = 30, buttons = button})
		testing.expectf(t, in_layout && event.x == BAR_X + 5 && event.y == 80, "button %d: the drag over the bar is at %d,%d", button, event.x, event.y)
		event, in_layout, _ = window_scroll_event(drawing, &test.window, {kind = .Pointer, x = BAR_X, y = 30})
		testing.expectf(t, in_layout && event.x == BAR_X + 5 && event.y == 80, "button %d: the release over the bar is at %d,%d", button, event.x, event.y)
		event, in_layout, _ = window_scroll_event(drawing, &test.window, {kind = .Pointer, x = BAR_X, y = 31})
		testing.expect(t, !in_layout && event.x == WINDOW_POINTER_AWAY && event.y == WINDOW_POINTER_AWAY)
		// A press on the bar: its drag into the layout is in the layout,
		// and its release back over the bar is the bar's.
		event, in_layout, _ = window_scroll_event(drawing, &test.window, {kind = .Pointer, x = BAR_X, y = 30, buttons = button})
		testing.expect(t, !in_layout)
		event, in_layout, _ = window_scroll_event(drawing, &test.window, {kind = .Pointer, x = 20, y = 30, buttons = button})
		testing.expect(t, in_layout && event.x == 25)
		event, in_layout, _ = window_scroll_event(drawing, &test.window, {kind = .Pointer, x = view.inner_width, y = 30})
		testing.expect(t, !in_layout)
	}
	test := new(Scroll_Test_Window)
	defer free(test)
	drawing, _ := scroll_test_window(test, pixels, .Ten_Eighths)
	testing.expect(t, !window_scroll_frame_take(drawing))
	_, _, due := window_scroll_event(drawing, &test.window, {kind = .Pointer, x = 20, y = 30, wheel = 1})
	testing.expect(t, due && window_scroll_frame_take(drawing) && !window_scroll_frame_take(drawing))
}
