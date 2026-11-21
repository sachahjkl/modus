package machine

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "modus:contract/reference_screen"
import "modus:contract/scale_factor"
import "internal:compositor/bar"
import "internal:compositor/palette"
import "modustool:build"

// The places of the scenarios that name an edge of the screen are on the
// reference screen in logical pixels at the scale of the machine: the
// corner is inside it and under the bar, the place that shows the title
// bar only keeps its height under the rule of the compositor, and the
// point of the palette is inside the panel that palette.panel_place gives,
// in the part that each step of the palette names. The point x = 400 of a
// screen of 1024 x 768 is outside it.
@(test)
scenario_places_are_on_the_reference_screen :: proc(t: ^testing.T) {
	logical_width, logical_height := scale_factor.logical_screen(MACHINE_SCALE)
	testing.expect_value(t, i64(LOGICAL_SCREEN_WIDTH), logical_width)
	testing.expect_value(t, i64(LOGICAL_SCREEN_HEIGHT), logical_height)
	testing.expect(t, SCREEN_CORNER_X > 0 && SCREEN_CORNER_X < LOGICAL_SCREEN_WIDTH && SCREEN_CORNER_Y > bar.HEIGHT && SCREEN_CORNER_Y < LOGICAL_SCREEN_HEIGHT)

	frame := bar.Window_Frame{outer_width = 1004, border = WINDOW_BORDER, close_size = 24, title_height = WINDOW_TITLE_HEIGHT}
	_, kept_y := bar.window_place_kept(64, WINDOW_TITLE_ONLY_Y, frame, LOGICAL_SCREEN_WIDTH, LOGICAL_SCREEN_HEIGHT)
	testing.expect_value(t, kept_y, WINDOW_TITLE_ONLY_Y)
	testing.expect_value(t, WINDOW_TITLE_ONLY_Y + WINDOW_TITLE_HEIGHT, LOGICAL_SCREEN_HEIGHT)
	// The drag holds the title at WINDOW_GRAB_Y: the pointer of the move
	// stays on the screen, which the move of the tool requires.
	testing.expect(t, WINDOW_TITLE_ONLY_Y + WINDOW_GRAB_Y < LOGICAL_SCREEN_HEIGHT)

	panel_x, panel_y := palette.panel_place(LOGICAL_SCREEN_WIDTH)
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

// The helper from a logical place of a scenario to a pixel of the screen,
// at its edges: 0, 1, -1, the edges of the logical screen, which reach
// the edges of the reference screen, the limit on each side, and one past
// it, which is refused and never wraps. Each pixel of the screen goes back
// to the logical pixel that holds it.
@(test)
the_place_of_a_scenario_on_the_screen :: proc(t: ^testing.T) {
	for scale in scale_factor.Scale {
		zero, zero_ok := screen_place_of_logical(0, scale)
		testing.expect(t, zero_ok && zero == 0)
		one, _ := screen_place_of_logical(1, scale)
		testing.expectf(t, one >= 1 && one <= 2, "1 logical pixel at %d eighths is %d", u8(scale), one)
		minus_one, minus_ok := screen_place_of_logical(-1, scale)
		testing.expectf(t, minus_ok && minus_one <= -1 && minus_one >= -2, "-1 logical pixel at %d eighths is %d", u8(scale), minus_one)
		_, past_ok := screen_place_of_logical(LOGICAL_PLACE_LIMIT + 1, scale)
		testing.expect(t, !past_ok)
		_, before_ok := screen_place_of_logical(-LOGICAL_PLACE_LIMIT - 1, scale)
		testing.expect(t, !before_ok)
		_, largest_ok := screen_place_of_logical(max(int), scale)
		testing.expect(t, !largest_ok)
		_, smallest_ok := screen_place_of_logical(min(int), scale)
		testing.expect(t, !smallest_ok)
		limit, limit_ok := screen_place_of_logical(LOGICAL_PLACE_LIMIT, scale)
		testing.expect(t, limit_ok && limit > LOGICAL_PLACE_LIMIT)
		_, screen_past_ok := logical_place_of_screen(LOGICAL_PLACE_LIMIT + 1, scale)
		testing.expect(t, !screen_past_ok)
		for pixel in -40 ..= reference_screen.WIDTH + 40 {
			place, ok := logical_place_of_screen(pixel, scale)
			left, _ := screen_place_of_logical(place, scale)
			right, _ := screen_place_of_logical(place + 1, scale)
			testing.expectf(t, ok && left <= pixel && pixel < right, "the pixel %d at %d eighths", pixel, u8(scale))
		}
	}
	// The machine: the logical screen ends at the edges of the screen.
	right, _ := screen_place_of_logical(LOGICAL_SCREEN_WIDTH, MACHINE_SCALE)
	bottom, _ := screen_place_of_logical(LOGICAL_SCREEN_HEIGHT, MACHINE_SCALE)
	testing.expect(t, right <= reference_screen.WIDTH && bottom <= reference_screen.HEIGHT)
	past_right, _ := screen_place_of_logical(LOGICAL_SCREEN_WIDTH + 1, MACHINE_SCALE)
	testing.expect(t, past_right > reference_screen.WIDTH)
	// The cells of Spleen of the body: 10 by 20 at 1.25 with the glyph at
	// 1, 2; 11 by 22 at 1.375 with the glyph at 1, 3.
	testing.expect_value(t, spleen_cells_of(.Ten_Eighths), Spleen_Cells{step = 10, glyph_x = 1, glyph_y = 2})
	testing.expect_value(t, spleen_cells_of(.Eleven_Eighths), Spleen_Cells{step = 11, glyph_x = 1, glyph_y = 3})
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
