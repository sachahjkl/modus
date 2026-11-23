#+build !freestanding
package interface

import "modus:graphics"
import "core:testing"

// The outline of the focus (src/md/features/accessibility.md, "3. Keyboard
// access to everything"): 2 pixels in the strong text, outside the area of
// the element with the focus, after its fill and outside its clips.

@(private = "file")
Focus_Tables :: struct {
	records: [256]Draw_Record,
	text:    [4096]u8,
}

// ring_rectangles gives the places in the table of the rectangles of the
// strong text that lie outside an area: the records of an outline of the
// focus around it. A text of the strong color is no rectangle.
@(private = "file")
ring_rectangles :: proc(table: ^Draw_Table, area: Area) -> (places: [8]int, count: int) {
	for record, index in table.records[:table.record_count] {
		view := record_view(record)
		if !view.read || view.kind != .Rectangle || view.color != graphics.colors.text_strong {
			continue
		}
		inside := view.x < area.x + area.width && area.x < view.x + view.width && view.y < area.y + area.height && area.y < view.y + view.height
		if inside {
			continue
		}
		if count < len(places) {
			places[count] = index
		}
		count += 1
	}
	return
}

// The box of the outline: each edge of the size first.
@(test)
the_box_of_the_outline_of_the_focus :: proc(t: ^testing.T) {
	testing.expect_value(t, FOCUS_RING_WIDTH, 2)
	testing.expect_value(t, focus_ring_area({10, 20, 30, 40}), Area{8, 18, 34, 44})
	testing.expect_value(t, focus_ring_area({0, 0, 0, 0}), Area{-2, -2, 4, 4})
	testing.expect_value(t, focus_ring_area({5, 5, -7, -1}), Area{3, 3, 4, 4})
	testing.expect_value(t, focus_ring_area({0, 0, 1, 1}), Area{-2, -2, 5, 5})
}

// A button with no focus has no outline; with the focus, the four sides of
// the outline lie outside it, after its fill, and its pixels are the
// strong text around a fill that the outline never covers.
@(test)
the_outline_of_a_button_with_the_focus :: proc(t: ^testing.T) {
	AREA :: Area{4, 4, 40, 20}
	WIDTH :: 48
	HEIGHT :: 28
	for focused in ([2]bool{false, true}) {
		memory: Focus_Tables
		table := Draw_Table{records = memory.records[:], text = memory.text[:]}
		state: Interface_State
		input: Input
		if focused {
			state.focus = identity("press")
		}
		frame := frame_begin(&table, &state, &input)
		result := button(&frame, AREA, identity("press"), "press")
		frame_end(&frame)
		testing.expect_value(t, result.focused, focused)
		places, count := ring_rectangles(&table, AREA)
		if !focused {
			testing.expect_value(t, count, 0)
			continue
		}
		testing.expect_value(t, count, 4)
		// The fill comes first, so it never covers the outline.
		fill_place := -1
		for record, index in table.records[:table.record_count] {
			view := record_view(record)
			if view.read && view.kind == .Rectangle && view.x == AREA.x && view.y == AREA.y && view.width == AREA.width && view.height == AREA.height {
				fill_place = index
				break
			}
		}
		testing.expect(t, fill_place >= 0)
		for place in places[:count] {
			testing.expect(t, place > fill_place)
		}
		pixels: [WIDTH * HEIGHT]graphics.Color
		canvas := graphics.Canvas{pixels = raw_data(pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
		execute(&table, canvas)
		at :: proc(pixels: []graphics.Color, x, y: int) -> graphics.Color {
			return pixels[y * WIDTH + x]
		}
		ring := focus_ring_area(AREA)
		// Each pixel of the band of 2 around the area is the strong text.
		for y in ring.y ..< ring.y + ring.height {
			for x in ring.x ..< ring.x + ring.width {
				in_area := x >= AREA.x && x < AREA.x + AREA.width && y >= AREA.y && y < AREA.y + AREA.height
				if !in_area {
					testing.expectf(t, at(pixels[:], x, y) == graphics.colors.text_strong, "the pixel %d,%d of the outline is %06x", x, y, u32(at(pixels[:], x, y)))
				}
			}
		}
		// Outside the outline, nothing; inside the area, the fill at its corners.
		testing.expect_value(t, at(pixels[:], ring.x - 1, ring.y - 1), graphics.Color(0))
		testing.expect_value(t, at(pixels[:], ring.x + ring.width, ring.y + ring.height), graphics.Color(0))
		testing.expect(t, at(pixels[:], AREA.x, AREA.y) != graphics.colors.text_strong)
		testing.expect(t, at(pixels[:], AREA.x + AREA.width - 1, AREA.y + AREA.height - 1) != graphics.colors.text_strong)
	}
}

// A list cuts its lines to its area with a clip: its outline comes after
// the clip closes, or the clip would cut it whole.
@(test)
the_outline_of_a_list_is_outside_its_clip :: proc(t: ^testing.T) {
	AREA :: Area{10, 10, 120, 3 * TABLE_LINE}
	memory: Focus_Tables
	table := Draw_Table{records = memory.records[:], text = memory.text[:]}
	state: Interface_State
	input: Input
	state.focus = identity("list")
	names := [?]string{"one", "two", "three", "four"}
	choice := 0
	frame := frame_begin(&table, &state, &input)
	result := list_with_choice(&frame, AREA, identity("list"), names[:], &choice)
	frame_end(&frame)
	testing.expect(t, result.focused)
	places, count := ring_rectangles(&table, AREA)
	testing.expect_value(t, count, 4)
	last_clip_pop := -1
	for record, index in table.records[:table.record_count] {
		if record_view(record).kind == .Clip_Pop {
			last_clip_pop = index
		}
	}
	testing.expect(t, last_clip_pop >= 0)
	for place in places[:count] {
		testing.expectf(t, place > last_clip_pop, "the outline record %d is inside the clip that ends at %d", place, last_clip_pop)
	}
}

// A field with the focus has the outline; the same field without it has
// none, though its text is in the strong color.
@(test)
the_outline_of_a_text_input_with_the_focus :: proc(t: ^testing.T) {
	process_drawing_begin()
	AREA :: Area{6, 6, 160, 28}
	for focused in ([2]bool{false, true}) {
		memory: Focus_Tables
		table := Draw_Table{records = memory.records[:], text = memory.text[:]}
		state: Interface_State
		input: Input
		if focused {
			state.focus = identity("field")
		}
		typed: [32]u8
		count := copy(typed[:], "text")
		frame := frame_begin(&table, &state, &input)
		text_input(&frame, AREA, identity("field"), typed[:], &count)
		frame_end(&frame)
		_, rings := ring_rectangles(&table, AREA)
		testing.expect_value(t, rings, focused ? 4 : 0)
	}
}
