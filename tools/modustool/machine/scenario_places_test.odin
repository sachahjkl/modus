package machine

import "core:os"
import "core:testing"
import "modus:contract/reference_screen"
import "modus:private/compositor/bar"
import "modus:private/compositor/palette"
import "modustool:build"

// The places of the scenarios that name an edge of the screen are on the
// reference screen: the corner is inside it, the place that shows the title
// bar only keeps its height under the rule of the compositor, and the point
// of the palette is inside the panel that palette.panel_place gives, in the
// part that each step of the palette names. The places of the screen of
// 1024 x 768 of before are not these places.
@(test)
scenario_places_are_on_the_reference_screen :: proc(t: ^testing.T) {
	testing.expect(t, SCREEN_CORNER_X > 0 && SCREEN_CORNER_X < reference_screen.WIDTH && SCREEN_CORNER_Y > bar.HEIGHT && SCREEN_CORNER_Y < reference_screen.HEIGHT)
	testing.expect(t, SCREEN_CORNER_X != 1018 && SCREEN_CORNER_Y != 762, "the corner is the corner of the screen of before")

	frame := bar.Window_Frame{outer_width = 1004, border = WINDOW_BORDER, close_size = 24, title_height = WINDOW_TITLE_HEIGHT}
	_, kept_y := bar.window_place_kept(64, WINDOW_TITLE_ONLY_Y, frame, reference_screen.WIDTH, reference_screen.HEIGHT)
	testing.expect_value(t, kept_y, WINDOW_TITLE_ONLY_Y)
	testing.expect_value(t, WINDOW_TITLE_ONLY_Y + WINDOW_TITLE_HEIGHT, reference_screen.HEIGHT)
	// The drag holds the title at WINDOW_GRAB_Y: the pointer of the move
	// stays on the screen, which the move of the tool requires.
	testing.expect(t, WINDOW_TITLE_ONLY_Y + WINDOW_GRAB_Y < reference_screen.HEIGHT)

	panel_x, panel_y := palette.panel_place(reference_screen.WIDTH)
	testing.expect_value(t, PALETTE_LEFT, panel_x)
	parts := [?]struct {
		y:    int,
		part: palette.Part,
	}{{120, .Input_Band}, {180, .List}, {476, .Rest}}
	for item in parts {
		testing.expectf(t, palette.part_at(panel_x, panel_y, PALETTE_POINT_X, item.y) == item.part, "the point %d,%d of the scenario is not in the part %v of the palette", PALETTE_POINT_X, item.y, item.part)
	}
	// The point of the screen of before is outside the panel now.
	testing.expect_value(t, palette.part_at(panel_x, panel_y, 400, 120), palette.Part.Outside)
}

// The line that the main scenario waits for names the reference screen:
// its size reads back as the size of the contract. A log of the screen of
// before, a log with no line and a line with no height give no reference
// screen.
@(test)
reference_screen_line_names_the_reference_screen :: proc(t: ^testing.T) {
	width, height, ok := screen_size_of_log("[compositor] " + REFERENCE_SCREEN_LINE + "\n")
	testing.expect(t, ok)
	testing.expect_value(t, width, reference_screen.WIDTH)
	testing.expect_value(t, height, reference_screen.HEIGHT)
	old_width, old_height, old_ok := screen_size_of_log("[compositor] " + SCREEN_SIZE_LINE + "1024x768\n")
	testing.expect(t, old_ok && (old_width != reference_screen.WIDTH || old_height != reference_screen.HEIGHT))
	_, _, none_ok := screen_size_of_log("[compositor] compositor: two screen pages\n")
	testing.expect(t, !none_ok)
	_, _, no_height_ok := screen_size_of_log("[compositor] " + SCREEN_SIZE_LINE + "1920x\n")
	testing.expect(t, !no_height_ok)
}

// The working memory of the compositor holds what the reference screen
// costs it: the frame and the background at the size of the screen, the
// page tables of both and of the two screen pages, and the page table and
// the page directory of the display registers. The stated budget of the
// screen of 1024 x 768, 4411 pages, holds the parts of the screen and
// not the second mappings of the resizes: the check refuses it.
@(test)
compositor_budget_holds_the_reference_screen :: proc(t: ^testing.T) {
	PAGE :: 4096
	TABLE_SPAN :: 2 << 20 // The memory that one page table maps.
	SCREEN_BYTES :: reference_screen.WIDTH * reference_screen.HEIGHT * 4
	SCREEN_CANVAS_PAGES :: (SCREEN_BYTES + PAGE - 1) / PAGE
	// A span that does not start on the edge of a page table touches one
	// table more than its size.
	CANVAS_TABLES :: (SCREEN_BYTES + TABLE_SPAN - 1) / TABLE_SPAN + 1
	SCREEN_PAGE_TABLES :: (2 * SCREEN_BYTES + TABLE_SPAN - 1) / TABLE_SPAN + 1
	REGISTER_TABLES :: 2
	// The second mapping of a resize for each of 32 clients, from the
	// comment of the budget of the compositor.
	RESIZE_MAPPINGS :: 32 * 19
	NEEDED :: 2 * SCREEN_CANVAS_PAGES + 2 * CANVAS_TABLES + SCREEN_PAGE_TABLES + REGISTER_TABLES + RESIZE_MAPPINGS
	#assert(SCREEN_CANVAS_PAGES == 2025)

	path :: "src/modules/system/compositor/main.odin"
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if !testing.expectf(t, read_error == nil, "%s: %v", path, read_error) {
		return
	}
	state: build.Describe_State
	file, parsed := build.parse_source(path, string(data), &state)
	if !testing.expect(t, parsed) {
		return
	}
	budget: build.Budget_Description
	testing.expect(t, build.budget_request_read(file, &budget))
	testing.expect(t, budget.stated)
	testing.expectf(t, budget.parts.working_memory_pages >= NEEDED, "the compositor states %d pages of working memory; the reference screen and the resizes need %d at least", budget.parts.working_memory_pages, NEEDED)
	testing.expect(t, u64(4411) < NEEDED, "the budget of the screen of before passes the check")
}
