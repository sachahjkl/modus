package machine

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "modus:contract/reference_screen"
import "modus:private/compositor/bar"
import "modus:private/compositor/palette"
import "modustool:build"

// The places of the scenarios that name an edge of the screen are on the
// reference screen: the corner is inside it and under the bar, the place
// that shows the title bar only keeps its height under the rule of the
// compositor, and the point of the palette is inside the panel that
// palette.panel_place gives, in the part that each step of the palette
// names. The point x = 400 of a screen of 1024 x 768 is outside it.
@(test)
scenario_places_are_on_the_reference_screen :: proc(t: ^testing.T) {
	testing.expect(t, SCREEN_CORNER_X > 0 && SCREEN_CORNER_X < reference_screen.WIDTH && SCREEN_CORNER_Y > bar.HEIGHT && SCREEN_CORNER_Y < reference_screen.HEIGHT)

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
	testing.expect_value(t, palette.part_at(panel_x, panel_y, 400, 120), palette.Part.Outside)
}

// The line of the reference screen reads back as the size of the contract,
// and the check of the step Screen_Size takes it. A screen of another size
// is refused at once with the size that the firmware gave; a log with no
// line and a line with no height are refused too.
@(test)
reference_screen_line_names_the_reference_screen :: proc(t: ^testing.T) {
	width, height, ok := screen_size_of_log("[compositor] " + REFERENCE_SCREEN_LINE + "\n")
	testing.expect(t, ok)
	testing.expect_value(t, width, reference_screen.WIDTH)
	testing.expect_value(t, height, reference_screen.HEIGHT)
	_, _, none_ok := screen_size_of_log("[compositor] compositor: two screen pages\n")
	testing.expect(t, !none_ok)
	_, _, no_height_ok := screen_size_of_log("[compositor] " + SCREEN_SIZE_LINE + "1920x\n")
	testing.expect(t, !no_height_ok)

	testing.expect_value(t, reference_screen_problem("[compositor] " + SCREEN_SIZE_LINE + "1024x768\n"), "the firmware gave 1024x768, not the reference screen 1920x1080")
	testing.expect_value(t, reference_screen_problem("[compositor] " + SCREEN_SIZE_LINE + "1920x1079\n"), "the firmware gave 1920x1079, not the reference screen 1920x1080")
	testing.expect_value(t, reference_screen_problem("[compositor] " + SCREEN_SIZE_LINE + "1080x1920\n"), "the firmware gave 1080x1920, not the reference screen 1920x1080")
	testing.expect(t, reference_screen_problem("") != "", "an empty log names the reference screen")
	testing.expect(t, reference_screen_problem("[compositor] " + SCREEN_SIZE_LINE + "1920x\n") != "", "a line with no height names the reference screen")
	// The last start of the compositor decides.
	testing.expect(t, reference_screen_problem("[compositor] " + REFERENCE_SCREEN_LINE + "\n[compositor] " + SCREEN_SIZE_LINE + "1024x768\n") != "")
	testing.expect_value(t, reference_screen_problem("[compositor] " + REFERENCE_SCREEN_LINE + "\n"), "")
}

// What the compositor pays at the reference screen, outside its surfaces
// and its tables: the frame and the background, the page tables of both and
// of the two screen pages, a second page directory for each of the three
// spans at a 1 GiB edge, the page table and the page directory of the
// display registers, and the second mappings of the resizes.
@(private = "file")
compositor_screen_pages_needed :: proc() -> u64 {
	PAGE :: 4096
	TABLE_SPAN :: 2 << 20 // The memory that one page table maps.
	SCREEN_BYTES :: reference_screen.WIDTH * reference_screen.HEIGHT * 4
	SCREEN_CANVAS_PAGES :: (SCREEN_BYTES + PAGE - 1) / PAGE
	#assert(SCREEN_CANVAS_PAGES == 2025)
	// A span that does not start on the edge of a page table touches one
	// table more than its size.
	CANVAS_TABLES :: (SCREEN_BYTES + TABLE_SPAN - 1) / TABLE_SPAN + 1
	SCREEN_PAGE_TABLES :: (2 * SCREEN_BYTES + TABLE_SPAN - 1) / TABLE_SPAN + 1
	SPAN_DIRECTORIES :: 3
	REGISTER_TABLES :: 2
	// The second mapping of a resize for each of 32 clients, from the
	// comment of the budget of the compositor.
	RESIZE_MAPPINGS :: 32 * 19
	return 2 * SCREEN_CANVAS_PAGES + 2 * CANVAS_TABLES + SCREEN_PAGE_TABLES + SPAN_DIRECTORIES + REGISTER_TABLES + RESIZE_MAPPINGS
}

// compositor_budget_problem reads the stated budget of a source of the
// compositor and gives "" when its working memory holds the pages that the
// reference screen needs, else the sentence of the fault.
@(private = "file")
compositor_budget_problem :: proc(path, source: string) -> string {
	state: build.Describe_State
	file, parsed := build.parse_source(path, source, &state)
	if !parsed {
		return "the source does not parse"
	}
	budget: build.Budget_Description
	if !build.budget_request_read(file, &budget) || !budget.stated {
		return "the source states no budget"
	}
	needed := compositor_screen_pages_needed()
	if budget.parts.working_memory_pages < needed {
		return fmt.tprintf("the compositor states %d pages of working memory; the reference screen and the resizes need %d at least", budget.parts.working_memory_pages, needed)
	}
	return ""
}

// The stated budget of the compositor holds the reference screen. The same
// check refuses a source that states 4411 pages, the budget counted at a
// screen of 1024 x 768, and a source one page short; it takes the exact
// amount.
@(test)
compositor_budget_holds_the_reference_screen :: proc(t: ^testing.T) {
	path :: "src/modules/system/compositor/main.odin"
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if !testing.expectf(t, read_error == nil, "%s: %v", path, read_error) {
		return
	}
	testing.expect_value(t, compositor_budget_problem(path, string(data)), "")

	needed := compositor_screen_pages_needed()
	// The braces are not in a format: the formatter reads a brace as the
	// start of a value.
	source_of :: proc(pages: u64) -> string {
		return strings.concatenate({"package compositor\n\n// Its loop.\nMODULE_BUDGET :: system.Stated_Budget{working_memory_pages = ", fmt.tprintf("%d", pages), ", processes = 1, threads = 2}\n"}, context.temp_allocator)
	}
	for pages in ([]u64{0, 1, 4411, needed - 1}) {
		testing.expectf(t, compositor_budget_problem("budget.odin", source_of(pages)) != "", "a budget of %d pages holds the reference screen", pages)
	}
	testing.expect_value(t, compositor_budget_problem("budget.odin", source_of(needed)), "")
}
