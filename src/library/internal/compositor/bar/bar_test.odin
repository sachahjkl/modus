#+build !freestanding
package bar

import "base:runtime"
import "core:sync"
import "core:testing"
import "modus:contract/font_outlines"
import "modus:text_rendering"

// The font outlines of B612, opened once for the tests of this package in
// the state of the text rendering: the measure of the names of the bar. The
// memory of the resource stays for the run.
@(private = "file")
outlines_opened: bool
@(private = "file")
outlines_lock: sync.Mutex
@(private = "file")
outlines_words: []u64

@(private = "file")
b612_open :: proc(t: ^testing.T) {
	sync.mutex_lock(&outlines_lock)
	defer sync.mutex_unlock(&outlines_lock)
	if outlines_opened {
		return
	}
	fonts := [1]font_outlines.Font_Input{{"b612", #load("../../../../../resources/fonts/b612.ttf")}}
	size := font_outlines.resource_size(fonts[:])
	// The heap of the process, not the allocator of the test: the runner
	// frees all that a test allocated at its end, and the open fonts of the
	// state read these words in each later test.
	outlines_words = make([]u64, (size + 7) / 8, runtime.heap_allocator())
	bytes := ([^]u8)(raw_data(outlines_words))[:size]
	_, written := font_outlines.resource_write(fonts[:], bytes)
	testing.expect(t, written)
	outlines, problem := font_outlines.validate(bytes)
	testing.expect_value(t, problem.kind, font_outlines.Problem_Kind.None)
	_ = text_rendering.open(&outlines)
	outlines_opened = true
}

// Each entry of the bar and of its menus, in one layout: the middle of each
// maps back to it, and the points just outside each button map to no
// button. The layouts: the font of the cells, two made-up proportional
// layouts (narrower and wider than the cells), and B612.
@(private = "file")
entries_round_trip :: proc(t: ^testing.T, layout: Layout, name: string) {
	start_x, start_y := button_center(layout)
	testing.expectf(t, button_at(layout, start_x, start_y) == .Start, "%s: the middle of the button start", name)
	windows_x, windows_y := windows_button_center(layout)
	testing.expectf(t, button_at(layout, windows_x, windows_y) == .Windows, "%s: the middle of the button windows", name)
	x, y, width, height := button(layout)
	testing.expectf(t, button_at(layout, x - 1, y) == .None && button_at(layout, x + width - 1, y + height - 1) == .Start, "%s: the edges of the button start", name)
	// The gap between the two buttons is no button.
	testing.expectf(t, button_at(layout, x + width, y) == .None && button_at(layout, x + width + WINDOWS_GAP - 1, y) == .None, "%s: the gap between the buttons", name)
	windows_left, windows_top, windows_width, windows_height := windows_button(layout)
	testing.expectf(t, windows_left == x + width + WINDOWS_GAP, "%s: the button windows follows the button start", name)
	testing.expectf(t, button_at(layout, windows_left + windows_width, windows_top) == .None && button_at(layout, windows_left, windows_top + windows_height) == .None, "%s: past the button windows", name)
	for process, index in names {
		center_x, center_y, found := center(layout, process)
		testing.expectf(t, found && line_at(layout, center_x, center_y) == index, "%s: the middle of the line of %s", name, process)
		line_x, line_y, line_width, line_height := line(layout, index)
		testing.expectf(t, line_at(layout, line_x, line_y) == index && line_at(layout, line_x + line_width - 1, line_y + line_height - 1) == index, "%s: the corners of the line of %s", name, process)
	}
	menu_x, menu_y, menu_width, menu_height := menu(layout)
	testing.expectf(t, line_at(layout, menu_x + menu_width + 1, menu_y + TITLE + 4) == -1 && line_at(layout, menu_x + 4, menu_y + 4) == -1, "%s: past the menu and in its title", name)
	testing.expect(t, menu_height > 0)
	for index in 0 ..< 5 {
		line_x, line_y := windows_line_center(layout, index)
		testing.expectf(t, windows_line_at(layout, 5, line_x, line_y) == index, "%s: the middle of the line %v of the windows", name, index)
		testing.expectf(t, windows_line_at(layout, index, line_x, line_y) == -1, "%s: a line past the count of windows", name)
	}
}

@(test)
each_entry_maps_back_to_itself :: proc(t: ^testing.T) {
	entries_round_trip(t, layout_of(.None), "the font of the cells")
	entries_round_trip(t, {label_width = 37, windows_label_width = 41, longest_name_width = 150}, "narrower")
	entries_round_trip(t, {label_width = 91, windows_label_width = 77, longest_name_width = 260}, "wider")
	b612_open(t)
	entries_round_trip(t, layout_of(.Interface), "B612")
}

// The places follow the widths: a wider label moves the button windows to
// the right by the same pixels, and a wider name widens each column by the
// same pixels, past COLUMN_LEAST. In B612 each name fits its line with its padding, and the
// names of the bar are not the widths of the cells.
@(test)
places_follow_the_measured_widths :: proc(t: ^testing.T) {
	narrow := Layout{label_width = 40, windows_label_width = 40, longest_name_width = 100}
	wide := Layout{label_width = 52, windows_label_width = 40, longest_name_width = 101}
	narrow_x, _, _, _ := windows_button(narrow)
	wide_x, _, _, _ := windows_button(wide)
	testing.expect_value(t, wide_x - narrow_x, 12)
	testing.expect_value(t, column_width(narrow), COLUMN_LEAST) // 100 + 16 is 116: under COLUMN_LEAST.
	testing.expect_value(t, column_width({longest_name_width = COLUMN_LEAST - 2 * PADDING}), COLUMN_LEAST)
	testing.expect_value(t, column_width({longest_name_width = COLUMN_LEAST - 2 * PADDING + 1}), COLUMN_LEAST + 1) // One pixel past the least: one pixel wider, no round up.
	testing.expect_value(t, column_width({label_width = 40, windows_label_width = 40, longest_name_width = 113}), 113 + 2 * PADDING)
	testing.expect_value(t, column_width({}), COLUMN_LEAST) // No name: the least width.
	b612_open(t)
	layout := layout_of(.Interface)
	cells := layout_of(.None)
	testing.expect(t, layout.label_width > 0 && layout.windows_label_width > 0)
	testing.expect(t, layout != cells, "B612 measures the names of the bar in its own widths")
	for process, index in names {
		_, _, line_width, _ := line(layout, index)
		testing.expectf(t, text_width_in(.Interface, process) + 2 * PADDING <= line_width, "%s fits its line", process)
	}
	_, _, button_width, _ := button(layout)
	testing.expect_value(t, button_width, text_width_in(.Interface, LABEL) + 2 * PADDING)
	// A face that the outlines lack measures in the font of the cells.
	testing.expect_value(t, layout_of(.Cells), cells)
}
