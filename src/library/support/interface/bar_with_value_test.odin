#+build !freestanding
package interface

import "modus:support/graphics"
import "core:testing"

@(private = "file")
Bar_Frame :: struct {
	records: [16]Draw_Record,
	text:    [256]u8,
	table:   Draw_Table,
	state:   Interface_State,
	input:   Input,
}

@(private = "file")
bar_frame_begin :: proc(memory: ^Bar_Frame) -> Frame {
	memory.table = {records = memory.records[:], text = memory.text[:]}
	return frame_begin(&memory.table, &memory.state, &memory.input)
}

// Each record of the table is inside the area: no bar and no text passes it.
@(private = "file")
records_inside :: proc(t: ^testing.T, table: ^Draw_Table, area: Area, name: string) {
	for record in table.records[:table.record_count] {
		view := record_view(record)
		inside := view.x >= area.x && view.y >= area.y && view.x + view.width <= area.x + area.width && view.y + view.height <= area.y + area.height
		testing.expectf(t, inside, "%s: a record at %d,%d of %d x %d passes the area", name, view.x, view.y, view.width, view.height)
	}
}

// The bar of the value against its maximum, at the edges: no room, a bar
// wider than the area, a value of 0, a value above the maximum, a maximum
// of 0, the largest value, and the least value against the largest
// maximum. Each must stay inside its area.
@(test)
bar_with_value_stays_inside_its_area_at_each_edge :: proc(t: ^testing.T) {
	Case :: struct {
		name:              string,
		area:              Area,
		bar_width:         int,
		value, maximum:    u64,
		full_width:        int, // The width of the full part; -1: no full part.
		value_drawn:       bool,
	}
	cases := [?]Case {
		{"an area of no width", {10, 10, 0, 24}, 200, 5, 10, -1, false},
		{"a bar of no width", {10, 10, 120, 24}, 0, 5, 10, -1, true},
		{"a bar wider than the area", {10, 10, 50, 24}, 200, 10, 10, 50, false},
		{"a negative bar width", {10, 10, 120, 24}, -8, 5, 10, -1, true},
		{"the value 0", {10, 10, 120, 24}, 40, 0, 10, -1, true},
		{"a value above the maximum", {10, 10, 120, 24}, 40, 30, 10, 40, true},
		{"a maximum of 0", {10, 10, 120, 24}, 40, 3, 0, 40, true},
		{"the largest value", {10, 10, 240, 24}, 40, max(u64), max(u64), 40, true},
		{"the least value against the largest maximum", {10, 10, 120, 24}, 40, 1, max(u64), 2, true},
		{"a bar of 1 pixel and a value", {10, 10, 120, 24}, 1, 1, 10, 1, true},
	}
	for test_case in cases {
		memory: Bar_Frame
		frame := bar_frame_begin(&memory)
		bar_with_value(&frame, test_case.area, test_case.bar_width, test_case.value, test_case.maximum, graphics.colors.process)
		records_inside(t, &memory.table, test_case.area, test_case.name)
		full := -1
		texts := 0
		for record in memory.table.records[:memory.table.record_count] {
			view := record_view(record)
			if view.kind == .Gradient && view.axis == .Down {
				full = view.width
			} else if view.kind == .Text {
				texts += 1
			}
		}
		testing.expectf(t, full == test_case.full_width, "%s: the full part is %d pixels wide, not %d", test_case.name, full, test_case.full_width)
		testing.expectf(t, (texts == 1) == test_case.value_drawn, "%s: %d texts", test_case.name, texts)
	}
}

// A usual row: the track in the middle of a line of a table, the value
// after the gap, at the top of its line of text.
@(test)
bar_with_value_places_the_bar_and_the_value :: proc(t: ^testing.T) {
	memory: Bar_Frame
	frame := bar_frame_begin(&memory)
	area := Area{284, 40, 300, TABLE_LINE}
	bar_with_value(&frame, area, 200, 50, 100, graphics.colors.process)
	testing.expect_value(t, memory.table.record_count, 3)
	track := record_view(memory.table.records[0])
	testing.expect(t, is_solid_rectangle(track), "the track is a solid rectangle")
	testing.expect_value(t, track.x, area.x)
	testing.expect_value(t, track.y, area.y + (TABLE_LINE - BAR_WITH_VALUE_THICKNESS) / 2)
	testing.expect_value(t, track.width, 200)
	testing.expect_value(t, track.height, BAR_WITH_VALUE_THICKNESS)
	full := record_view(memory.table.records[1])
	testing.expect_value(t, full.width, 100)
	value := record_view(memory.table.records[2])
	testing.expect_value(t, value.kind, Draw_Kind.Text)
	testing.expect_value(t, value.x, area.x + 200 + BAR_WITH_VALUE_GAP)
	testing.expect_value(t, value.y, area.y + (TABLE_LINE - line_height({})) / 2)
	testing.expect_value(t, string(memory.text[value.first:][:value.count]), "50")
}
