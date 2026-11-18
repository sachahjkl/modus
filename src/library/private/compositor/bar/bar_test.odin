#+build !freestanding
package bar

import "modus:contract/glyph_cache"
import "core:testing"
import "modus:support/vector_font"

// The regular cache of B612 at scale 1, in memory that the caller frees:
// the cache of the names of the bar.
@(private = "file")
b612_cache_of :: proc(t: ^testing.T) -> (cache: glyph_cache.Cache, memory: []u64) {
	bytes := #load("../../../../../resources/fonts/b612.ttf")
	font, problem := vector_font.font_open(bytes)
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	render := new(vector_font.Render_Memory)
	defer free(render)
	memory = make([]u64, vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT / 8)
	out := ([^]u8)(raw_data(memory))[:vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT]
	positions := [3]int{3, 1, 1}
	size: int
	size, problem = vector_font.glyph_cache_build_proportional(&font, bytes, "b612", true, render, out, positions[:])
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	refused: glyph_cache.Problem
	cache, refused = glyph_cache.validate(out[:size])
	testing.expect_value(t, refused.kind, glyph_cache.Problem_Kind.None)
	return cache, memory
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
	entries_round_trip(t, layout_of(nil), "the font of the cells")
	entries_round_trip(t, {label_width = 37, windows_label_width = 41, longest_name_width = 150}, "narrower")
	entries_round_trip(t, {label_width = 91, windows_label_width = 77, longest_name_width = 260}, "wider")
	cache, memory := b612_cache_of(t)
	defer delete(memory)
	entries_round_trip(t, layout_of(&cache), "B612")
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
	cache, memory := b612_cache_of(t)
	defer delete(memory)
	layout := layout_of(&cache)
	cells := layout_of(nil)
	testing.expect(t, layout.label_width > 0 && layout.windows_label_width > 0)
	testing.expect(t, layout != cells, "B612 measures the names of the bar in its own widths")
	for process, index in names {
		_, _, line_width, _ := line(layout, index)
		testing.expectf(t, text_width_in(&cache, process) + 2 * PADDING <= line_width, "%s fits its line", process)
	}
	_, _, button_width, _ := button(layout)
	testing.expect_value(t, button_width, text_width_in(&cache, LABEL) + 2 * PADDING)
}
