// The cost of a frame at 1920 x 1080 on the processor, with no GPU. The
// design:
// (src/md/features/desktop_to_browser.md, "The first measure: a frame at 1920 × 1080 on the processor").
//
// **What it is for.** It gives the numbers from which the thresholds of
// the processor profile of the [quality profile](term:quality-profile)
// come. The process draws into canvases of the reference screen in memory
// of its own budget, apart from the screen of the compositor, with the code that
// the compositor calls: `graphics.clear`, `graphics.copy` and the
// [drawing module](term:drawing-module). It measures three parts, each 21
// times after one frame that pays the pages on first use:
//
// 1. A clear of the frame, then its copy into a screen page: the bound of
//    the memory bandwidth.
// 2. A frame of the compositor with four windows, in its phases: the
//    background, one call of the drawing module for each window and one
//    for the bar, then the copy into a screen page. Once in full, once in
//    the damage of one Present and of the clock of the bar.
// 3. The execution of a draw table that fills the screen with the records
//    of a desktop: gradients, rectangles, texts in both fonts, opaque
//    pictures, pictures and rectangles with alpha.
//
// **What a reader sees.** No window. `modustool measure` starts it after
// the other measures of its measure run, with `start("processor_frame")`.
// The log gets one line for each part, `processor_frame: measure: <part>:
// least <time> us, median <time> us, <count> frames in one second at the
// median, over 21 frames`, then `processor_frame: ok, ...` or
// `processor_frame: wrong: ...`. A time is a measure: no test compares it
// to a bound.
//
// **Its grants**: none.
//
// **What it does not prove.** The records of each window are in the form
// of the compositor, not its code: the compositor keeps its procedures.
// The pointer, the rings and the page flip are not in the frame.
package processor_frame

import "modus:contract/draw_record"
import "modus:contract/errors"
import "modus:contract/reference_screen"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"

// The process draws through the drawing module only: the interface
// package declares its exports with this setting, which the row of the
// module in the module table gives (tools/modustool/foundation/module_table.odin).
#assert(interface.DRAWING_THROUGH_MODULE, "processor_frame is built with -define:DRAWING_THROUGH_MODULE=true")

// The reference screen:
// (src/md/features/desktop_to_browser.md, "The reference screen"). The
// lines of the log name its size in words: the sentence of a measure is its
// identity in the measure record, so a new size starts a new series.
SCREEN_WIDTH :: reference_screen.WIDTH
SCREEN_HEIGHT :: reference_screen.HEIGHT
#assert(SCREEN_WIDTH == 1920 && SCREEN_HEIGHT == 1080, "the lines of the measure name 1920x1080")

// The frames of each part that the line counts: an odd count, so the
// median is one frame.
ROUNDS :: 21
#assert(ROUNDS % 2 == 1)

PAGE_BYTES :: 4096
#assert(PAGE_BYTES == system.PAGE_SIZE)
PIXELS_IN_A_PAGE :: PAGE_BYTES / 4
#assert(PIXELS_IN_A_PAGE * size_of(graphics.Color) == PAGE_BYTES)

// A canvas of the screen: the frame, the screen page and the background.
SCREEN_PAGES :: SCREEN_WIDTH * SCREEN_HEIGHT / PIXELS_IN_A_PAGE
#assert(SCREEN_WIDTH * SCREEN_HEIGHT % PIXELS_IN_A_PAGE == 0)

// The surfaces of the four windows, from the back to the front: sizes of
// windows of a desktop at this screen, each a whole count of pages.
WINDOW_COUNT :: 4
BACK_WINDOW_WIDTH :: 1280
BACK_WINDOW_HEIGHT :: 800
SECOND_WINDOW_WIDTH :: 960
SECOND_WINDOW_HEIGHT :: 640
THIRD_WINDOW_WIDTH :: 800
THIRD_WINDOW_HEIGHT :: 640
FRONT_WINDOW_WIDTH :: 640
FRONT_WINDOW_HEIGHT :: 480
#assert(BACK_WINDOW_WIDTH * BACK_WINDOW_HEIGHT % PIXELS_IN_A_PAGE == 0)
#assert(SECOND_WINDOW_WIDTH * SECOND_WINDOW_HEIGHT % PIXELS_IN_A_PAGE == 0)
#assert(THIRD_WINDOW_WIDTH * THIRD_WINDOW_HEIGHT % PIXELS_IN_A_PAGE == 0)
#assert(FRONT_WINDOW_WIDTH * FRONT_WINDOW_HEIGHT % PIXELS_IN_A_PAGE == 0)
WINDOW_PAGES :: (BACK_WINDOW_WIDTH * BACK_WINDOW_HEIGHT + SECOND_WINDOW_WIDTH * SECOND_WINDOW_HEIGHT + THIRD_WINDOW_WIDTH * THIRD_WINDOW_HEIGHT + FRONT_WINDOW_WIDTH * FRONT_WINDOW_HEIGHT) / PIXELS_IN_A_PAGE

// The pictures of the draw table: one opaque picture, then one with alpha,
// in one picture memory.
PICTURE_SIDE :: 256
PICTURE_PIXELS :: PICTURE_SIDE * PICTURE_SIDE
PICTURE_PAGES :: 2 * PICTURE_PIXELS / PIXELS_IN_A_PAGE
#assert(2 * PICTURE_PIXELS % PIXELS_IN_A_PAGE == 0)

// The process itself, as the other small processes with no window.
PROCESS_PAGES :: 180
// The page tables of the mappings: about 33 MiB in 8 mappings, one table
// for each 2 MiB, one more for each mapping that does not start on a
// 2 MiB edge, and the page directories above them.
PAGE_TABLE_PAGES :: 32

// The three canvases of the screen, the four surfaces, the pictures, the
// process and its page tables. The tool reads a literal only, so the
// assert ties it to the parts.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 8815, processes = 1, threads = 1}
#assert(MODULE_BUDGET.working_memory_pages == 3 * SCREEN_PAGES + WINDOW_PAGES + PICTURE_PAGES + PROCESS_PAGES + PAGE_TABLE_PAGES)

// The frame of a window and the bar, in the form of the compositor
// (src/modules/system/compositor/main.odin, frame_records).
TITLE_HEIGHT :: 24
BORDER :: 2
CLOSE_SIZE :: 24
BAR_HEIGHT :: 32
CLOCK_WIDTH :: 19 * 8 // "2026-11-18 12:00:00" in the font of the cells.
BAR_BUTTON_PADDING :: 12
WINDOW_TITLE :: "a window"
BAR_CLOCK_TEXT :: "2026-11-18 12:00:00"

// The damage of a frame in its damage: a rectangle of the surface of the
// front window that one Present changed, and the clock of the bar.
PRESENT_WIDTH :: 400
PRESENT_HEIGHT :: 300
#assert(PRESENT_WIDTH <= FRONT_WINDOW_WIDTH && PRESENT_HEIGHT <= FRONT_WINDOW_HEIGHT)

// The cards of the draw table, which fill the screen.
CARD_COLUMNS :: 4
CARD_ROWS :: 3
CARD_GAP :: 16
CARD_WIDTH :: 456
CARD_HEIGHT :: 336
#assert(CARD_COLUMNS * CARD_WIDTH + (CARD_COLUMNS + 1) * CARD_GAP <= SCREEN_WIDTH)
#assert(CARD_ROWS * CARD_HEIGHT + (CARD_ROWS + 1) * CARD_GAP <= SCREEN_HEIGHT)
CARD_LINES :: 10
CARD_LINE_HEIGHT :: 24
CARD_LINES_TOP :: 56 // From the top of the card.
CARD_LABEL_X :: 224 // From the left of the card: right of the pictures.
CARD_VALUE_RIGHT :: 440
#assert(CARD_LINES_TOP + CARD_LINES * CARD_LINE_HEIGHT <= CARD_HEIGHT - 32)
PICTURE_SHOWN :: 128 // The side of the part of a picture that a card shows.
#assert(PICTURE_SHOWN * 2 <= PICTURE_SIDE)
CARD_TITLE :: "A CARD"
CARD_CAPTION :: "the records of a desktop"
CARD_LABEL :: "a label"
// The alpha of the translucent records: a panel over a card, and a shadow
// over the cards.
PANEL_ALPHA :: 96
SHADOW_ALPHA :: 160

// One window of the frame of the compositor: its place and its surface.
Measured_Window :: struct {
	x, y:    int,
	surface: graphics.Canvas,
}

windows: [WINDOW_COUNT]Measured_Window
frame, screen_page, background: graphics.Canvas
pictures: []graphics.Color // The opaque picture, then the picture with alpha.
opaque_picture, alpha_picture: graphics.Canvas

// The draw table of the screen of the compositor, in its parts: one for
// each window, with its surface as its picture memory, then one for the
// bar (src/md/api/picture.md).
screen_records: [512]interface.Draw_Record
screen_text: [4096]u8
screen_table: interface.Draw_Table
Screen_Part :: struct {
	first, count:   int,
	picture_memory: []graphics.Color,
	bounds:         interface.Rectangle, // The outer rectangle of a window.
	bounded:        bool, // The bar has no bound.
}
screen_parts: [WINDOW_COUNT + 1]Screen_Part
screen_part_count: int
screen_picture_memories: [1][]graphics.Color

// The draw table of the desktop, built once: the measure is its execution.
desktop_records: [1024]interface.Draw_Record
desktop_text: [8192]u8
desktop_table: interface.Draw_Table
desktop_picture_memories: [1][]graphics.Color

// The records of the desktop by kind, for its line. Each record is in one
// count.
Desktop_Counts :: struct {
	opaque_rectangles: u64, // Rectangles and gradients of one opaque color.
	cell_texts:        u64, // Texts in the font of the cells.
	interface_texts:   u64, // Texts in the interface font.
	opaque_pictures:   u64,
	with_alpha:        u64, // Rectangles and pictures with alpha.
}
desktop_counts: Desktop_Counts

full_screen_areas := [1]interface.Rectangle{{0, 0, SCREEN_WIDTH, SCREEN_HEIGHT}}
damage_areas: [2]interface.Rectangle
// The calls of the drawing module that it refused: each is a fault of this
// process, which the last line names.
refusals: u64

Frame_Times :: [ROUNDS]u64

// canvas_make makes a canvas of memory of the budget of this process.
canvas_make :: proc "contextless" (width, height: int) -> (canvas: graphics.Canvas, ok: bool) {
	pages := (u64(width * height) + PIXELS_IN_A_PAGE - 1) / PIXELS_IN_A_PAGE
	memory, status := system.memory_create(pages)
	if status != .Ok {
		return {}, false
	}
	address, map_status := system.memory_map(memory)
	if map_status != .Ok {
		return {}, false
	}
	return {pixels = ([^]graphics.Color)(address), width = width, height = height, stride = width}, true
}

// least_and_median gives the least time of a part and its median.
least_and_median :: proc "contextless" (times: Frame_Times) -> (least, median: u64) {
	sorted := times
	for index in 1 ..< ROUNDS {
		value := sorted[index]
		place := index
		for place > 0 && sorted[place - 1] > value {
			sorted[place] = sorted[place - 1]
			place -= 1
		}
		sorted[place] = value
	}
	return sorted[0], sorted[ROUNDS / 2]
}

// frames_measure draws one frame that is not counted, which pays the pages
// on first use, then ROUNDS frames, and gives the time of each.
frames_measure :: proc "contextless" (draw: proc "contextless" ()) -> (times: Frame_Times) {
	draw()
	for round in 0 ..< ROUNDS {
		start := system.nanoseconds()
		draw()
		times[round] = system.nanoseconds() - start
	}
	return times
}

// measure_log writes the line of one part. The tool reads its form
// (tools/modustool/checks/processor_frame_measure.odin): change both together.
measure_log :: proc "contextless" (part: string, times: Frame_Times) {
	least, median := least_and_median(times)
	frames := u64(1_000_000_000) / max(median, 1)
	system.log(.Info, "processor_frame: measure: ", part, ": least ", least / 1000, ".", least / 100 % 10, " us, median ", median / 1000, ".", median / 100 % 10, " us, ", frames, " frames in one second at the median, over ", u64(ROUNDS), " frames")
}

// clear_and_present clears the frame, then copies it into the screen
// page, as the compositor copies its frame.
clear_and_present :: proc "contextless" () {
	graphics.clear(frame, graphics.colors.background)
	graphics.copy(screen_page, 0, 0, frame)
}

// window_frame_records appends the frame of a window in the form of the
// compositor: the title bar with its gradient and its lighter top line, the
// borders, the title, the close button.
window_frame_records :: proc "contextless" (table: ^interface.Draw_Table, window: Measured_Window, focus: bool) {
	x, y := window.x, window.y
	outer_width := window.surface.width + 2 * BORDER
	outer_height := window.surface.height + TITLE_HEIGHT + BORDER
	start := graphics.Color(focus ? graphics.colors.title : graphics.colors.title_quiet)
	end := graphics.Color(focus ? graphics.colors.title_end : graphics.colors.title_quiet_end)
	interface.draw_horizontal_gradient(table, x, y, outer_width, 1, graphics.shade(start, 125), graphics.shade(end, 125))
	interface.draw_horizontal_gradient(table, x, y + 1, outer_width, TITLE_HEIGHT - 1, start, end)
	interface.draw_horizontal_gradient(table, x, y + outer_height - BORDER, outer_width, BORDER, start, end)
	interface.draw_rectangle(table, x, y + TITLE_HEIGHT, BORDER, outer_height - TITLE_HEIGHT - BORDER, start)
	interface.draw_rectangle(table, x + outer_width - BORDER, y + TITLE_HEIGHT, BORDER, outer_height - TITLE_HEIGHT - BORDER, end)
	interface.draw_text(table, x + 8, y + 4, WINDOW_TITLE, focus ? graphics.COLOR_WHITE : graphics.colors.dim, interface.FONT_INTERFACE)
	base := graphics.Color(focus ? graphics.colors.stop_process : graphics.colors.stop_process_quiet)
	close_x := x + outer_width - BORDER - CLOSE_SIZE
	interface.draw_vertical_gradient(table, close_x, y, CLOSE_SIZE, TITLE_HEIGHT, graphics.shade(base, 118), graphics.shade(base, 82))
	interface.draw_rectangle(table, close_x, y, CLOSE_SIZE, 1, graphics.shade(base, 150))
	interface.draw_character(table, close_x + (CLOSE_SIZE - graphics.CELL_WIDTH) / 2, y + (TITLE_HEIGHT - graphics.CELL_HEIGHT) / 2, 'x', focus ? graphics.COLOR_WHITE : graphics.colors.stop_process_quiet_mark)
}

// bar_button_records appends a button of the bar with its label in the
// interface font, and gives the x after it.
bar_button_records :: proc "contextless" (table: ^interface.Draw_Table, x: int, label: string) -> int {
	width := interface.text_measured_width(table, interface.FONT_INTERFACE, label) + 2 * BAR_BUTTON_PADDING
	interface.draw_rectangle(table, x, 4, width, BAR_HEIGHT - 8, graphics.colors.track)
	interface.draw_text(table, x + BAR_BUTTON_PADDING, 8, label, graphics.colors.text, interface.FONT_INTERFACE)
	return x + width
}

// screen_build builds the draw table of the screen, in its parts, as the
// compositor does at each frame.
screen_build :: proc "contextless" () {
	screen_table = {records = screen_records[:], text = screen_text[:], interface_font = display.interface_font_of()}
	screen_part_count = 0
	table := &screen_table
	for window, position in windows {
		first := table.record_count
		window_frame_records(table, window, position == WINDOW_COUNT - 1)
		memory := window.surface.pixels[:window.surface.stride * window.surface.height]
		screen_picture_memories[0] = memory
		table.picture_memories = screen_picture_memories[:]
		interface.draw_picture(table, window.x + BORDER, window.y + TITLE_HEIGHT, window.surface, 0)
		table.picture_memories = nil
		outer := interface.Rectangle{window.x, window.y, window.x + window.surface.width + 2 * BORDER, window.y + window.surface.height + TITLE_HEIGHT + BORDER}
		screen_parts[screen_part_count] = {first = first, count = table.record_count - first, picture_memory = memory, bounds = outer, bounded = true}
		screen_part_count += 1
	}
	first := table.record_count
	interface.draw_vertical_gradient(table, 0, 0, SCREEN_WIDTH, BAR_HEIGHT - 1, graphics.colors.card_top, graphics.colors.card_bottom)
	interface.draw_rectangle(table, 0, BAR_HEIGHT - 1, SCREEN_WIDTH, 1, graphics.colors.track)
	after_start := bar_button_records(table, 48, "start")
	bar_button_records(table, after_start + 8, "windows")
	interface.draw_text(table, SCREEN_WIDTH - CLOCK_WIDTH - 16, 8, BAR_CLOCK_TEXT, graphics.colors.text)
	screen_parts[screen_part_count] = {first = first, count = table.record_count - first}
	screen_part_count += 1
}

// compositor_frame draws the areas of the screen in the phases of the
// compositor (docs/SIMD.md, "4. The compositor"): the background, the
// parts that meet each area with one call of the drawing module for each
// part, then the copy of the areas into the screen page.
compositor_frame :: proc "contextless" (areas: []interface.Rectangle) {
	screen_build()
	for area in areas {
		canvas := graphics.view(frame, area.left, area.top, area.right - area.left, area.bottom - area.top)
		graphics.copy(canvas, -area.left, -area.top, background)
	}
	for part in screen_parts[:screen_part_count] {
		rectangles: [interface.DAMAGE_CAPACITY]interface.Rectangle
		count := 0
		for area in areas {
			if count == len(rectangles) {
				break
			}
			if part.bounded && (part.bounds.right <= area.left || area.right <= part.bounds.left || part.bounds.bottom <= area.top || area.bottom <= part.bounds.top) {
				continue
			}
			rectangles[count] = area
			count += 1
		}
		if count > 0 {
			refused: errors.Error_Record
			if !interface.draw_part_through_module(&screen_table, part.first, part.count, part.picture_memory, frame, rectangles[:count], false, 0, &refused) {
				refusals += 1
			}
		}
	}
	for area in areas {
		width, height := area.right - area.left, area.bottom - area.top
		graphics.copy(graphics.view(screen_page, area.left, area.top, width, height), 0, 0, graphics.view(frame, area.left, area.top, width, height))
	}
}

compositor_frame_full :: proc "contextless" () {
	compositor_frame(full_screen_areas[:])
}

compositor_frame_in_its_damage :: proc "contextless" () {
	compositor_frame(damage_areas[:])
}

// desktop_text_append appends a text and counts it in the font that draws
// it: a text in the interface font is in the font of the cells when the
// process has no interface font.
desktop_text_append :: proc "contextless" (x, y: int, text: string, color: graphics.Color, font: interface.Font, right_aligned := false) {
	if interface.font_in_use(&desktop_table, font, len(text)).kind == .Interface {
		desktop_counts.interface_texts += 1
	} else {
		desktop_counts.cell_texts += 1
	}
	if right_aligned {
		interface.draw_text_right(&desktop_table, x, y, text, color, font)
	} else {
		interface.draw_text(&desktop_table, x, y, text, color, font)
	}
}

// desktop_build builds the draw table of a desktop that fills the screen:
// the background with its grid of points, twelve cards, and a shadow over
// them.
desktop_build :: proc "contextless" () {
	desktop_table = {records = desktop_records[:], text = desktop_text[:], interface_font = display.interface_font_of()}
	desktop_picture_memories[0] = pictures
	desktop_table.picture_memories = desktop_picture_memories[:]
	table := &desktop_table
	interface.draw_rectangle(table, 0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, graphics.colors.background)
	interface.draw_point_grid(table, 0, 0, SCREEN_WIDTH, SCREEN_HEIGHT)
	desktop_counts.opaque_rectangles += 2
	builder: interface.Text_Builder
	for row in 0 ..< CARD_ROWS {
		for column in 0 ..< CARD_COLUMNS {
			index := row * CARD_COLUMNS + column
			x := CARD_GAP + column * (CARD_WIDTH + CARD_GAP)
			y := CARD_GAP + row * (CARD_HEIGHT + CARD_GAP)
			interface.draw_vertical_gradient(table, x, y, CARD_WIDTH, CARD_HEIGHT, graphics.colors.card_top, graphics.colors.card_bottom)
			desktop_counts.opaque_rectangles += 1
			desktop_text_append(x + 16, y + 12, CARD_TITLE, graphics.colors.text, interface.FONT_INTERFACE_BOLD)
			desktop_text_append(x + 16, y + 32, CARD_CAPTION, graphics.colors.dim, interface.FONT_INTERFACE)
			// An opaque picture, and a picture with alpha over a part of it.
			interface.draw_picture(table, x + 16, y + CARD_LINES_TOP, graphics.view(opaque_picture, index * 8, 0, PICTURE_SHOWN, PICTURE_SHOWN), 1)
			interface.draw_picture_with_alpha(table, x + 16 + PICTURE_SHOWN / 2, y + CARD_LINES_TOP + PICTURE_SHOWN / 2, graphics.view(alpha_picture, 0, index * 8, PICTURE_SHOWN, PICTURE_SHOWN), 1)
			desktop_counts.opaque_pictures += 1
			desktop_counts.with_alpha += 1
			// A panel with alpha under the pictures.
			interface.draw_rectangle_with_alpha(table, x + 16, y + CARD_LINES_TOP + PICTURE_SHOWN / 2 + PICTURE_SHOWN + 16, PICTURE_SHOWN + PICTURE_SHOWN / 2, 40, draw_record.with_alpha(graphics.colors.kernel, PANEL_ALPHA))
			desktop_counts.with_alpha += 1
			for line in 0 ..< CARD_LINES {
				line_y := y + CARD_LINES_TOP + line * CARD_LINE_HEIGHT + 4
				desktop_text_append(x + CARD_LABEL_X, line_y, CARD_LABEL, graphics.colors.dim, interface.FONT_INTERFACE)
				desktop_text_append(x + CARD_VALUE_RIGHT, line_y, interface.number_text(&builder, u64(index * 1000 + line * 37)), graphics.colors.text, {}, true)
			}
			// A bar: its track, then its value.
			interface.draw_rectangle(table, x + 16, y + CARD_HEIGHT - 24, CARD_WIDTH - 32, 8, graphics.colors.track)
			interface.draw_rectangle(table, x + 16, y + CARD_HEIGHT - 24, (index + 1) * 32, 8, graphics.colors.process)
			desktop_counts.opaque_rectangles += 2
		}
	}
	// The shadow of a menu over the cards.
	interface.draw_rectangle_with_alpha(table, SCREEN_WIDTH - 720, SCREEN_HEIGHT - 480, 600, 400, draw_record.with_alpha(graphics.colors.background, SHADOW_ALPHA))
	desktop_counts.with_alpha += 1
}

// desktop_draw executes the draw table of the desktop into the frame, with
// the fill of the background: one call of the drawing module.
desktop_draw :: proc "contextless" () {
	refused: errors.Error_Record
	if !interface.draw_part_through_module(&desktop_table, 0, desktop_table.record_count, pictures, frame, full_screen_areas[:], true, graphics.colors.background, &refused) {
		refusals += 1
	}
}

// pictures_fill writes the two pictures: an opaque picture of a gradient
// of two channels, and a picture whose alpha goes from 1 to 255 along a
// line.
pictures_fill :: proc "contextless" () {
	for y in 0 ..< PICTURE_SIDE {
		for x in 0 ..< PICTURE_SIDE {
			opaque_picture.pixels[y * PICTURE_SIDE + x] = graphics.rgb(u32(x), u32(y), 0x80)
			alpha := u32(x % 255 + 1)
			alpha_picture.pixels[y * PICTURE_SIDE + x] = alpha << 24 | graphics.rgb(0x40, u32(y), u32(x))
		}
	}
}

// entry makes the canvases, the surfaces and the pictures, measures each
// part, checks a pixel that each part writes, and stops. A refused memory
// stops it with the code 1 and a line.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	// The text of the drawing: the settings of the principal, the glyph
	// caches and the interface font, as the compositor loads them.
	display.text_settings_open(ctx)
	display.interface_font_load(ctx)

	sizes := [WINDOW_COUNT][2]int{{BACK_WINDOW_WIDTH, BACK_WINDOW_HEIGHT}, {SECOND_WINDOW_WIDTH, SECOND_WINDOW_HEIGHT}, {THIRD_WINDOW_WIDTH, THIRD_WINDOW_HEIGHT}, {FRONT_WINDOW_WIDTH, FRONT_WINDOW_HEIGHT}}
	// The places of the windows, from the back to the front: each one lower
	// and to the right, inside the screen with its frame.
	places := [WINDOW_COUNT][2]int{{96, 72}, {480, 200}, {880, 320}, {1160, 480}}
	surface_colors := [WINDOW_COUNT]graphics.Color{graphics.colors.kernel, graphics.colors.memory, graphics.colors.machine, graphics.colors.process}
	made := true
	ok: bool
	frame, ok = canvas_make(SCREEN_WIDTH, SCREEN_HEIGHT)
	made &&= ok
	screen_page, ok = canvas_make(SCREEN_WIDTH, SCREEN_HEIGHT)
	made &&= ok
	background, ok = canvas_make(SCREEN_WIDTH, SCREEN_HEIGHT)
	made &&= ok
	for index in 0 ..< WINDOW_COUNT {
		windows[index].x, windows[index].y = places[index][0], places[index][1]
		windows[index].surface, ok = canvas_make(sizes[index][0], sizes[index][1])
		made &&= ok
	}
	picture_canvas: graphics.Canvas
	picture_canvas, ok = canvas_make(PICTURE_SIDE, 2 * PICTURE_SIDE)
	made &&= ok
	if !made {
		system.log(.Info, "processor_frame: wrong: the budget of this process gave no memory for its canvases")
		system.stop(1)
	}
	pictures = picture_canvas.pixels[:2 * PICTURE_PIXELS]
	opaque_picture = {pixels = raw_data(pictures), width = PICTURE_SIDE, height = PICTURE_SIDE, stride = PICTURE_SIDE}
	alpha_picture = {pixels = raw_data(pictures[PICTURE_PIXELS:]), width = PICTURE_SIDE, height = PICTURE_SIDE, stride = PICTURE_SIDE}
	pictures_fill()

	// The background of the compositor: one color and the grid of points.
	graphics.clear(background, graphics.colors.background)
	for y := graphics.POINT_STEP / 2; y < SCREEN_HEIGHT; y += graphics.POINT_STEP {
		for x := graphics.POINT_STEP / 2; x < SCREEN_WIDTH; x += graphics.POINT_STEP {
			graphics.fill(background, x, y, graphics.POINT_SIZE, graphics.POINT_SIZE, graphics.colors.point)
		}
	}
	// Each surface: its color, and a band of the text color.
	for window, index in windows {
		graphics.clear(window.surface, surface_colors[index])
		graphics.fill(window.surface, 0, 0, window.surface.width, 24, graphics.colors.text)
	}
	front := windows[WINDOW_COUNT - 1]
	front_left, front_top := front.x + BORDER, front.y + TITLE_HEIGHT
	damage_areas[0] = {front_left, front_top, front_left + PRESENT_WIDTH, front_top + PRESENT_HEIGHT}
	damage_areas[1] = {SCREEN_WIDTH - CLOCK_WIDTH - 16, 8, SCREEN_WIDTH - 16, 8 + graphics.CELL_HEIGHT}
	damage_pixels := u64(PRESENT_WIDTH * PRESENT_HEIGHT + CLOCK_WIDTH * graphics.CELL_HEIGHT)

	// A pixel that each part writes holds another color before the part,
	// so a part that drew nothing leaves it wrong.
	pixels_right: [4]bool
	last_pixel := SCREEN_WIDTH * SCREEN_HEIGHT - 1
	screen_page.pixels[last_pixel] = graphics.colors.background ~ 0xFFFFFF

	// 1. The clear and the present.
	measure_log("a clear and a present of 1920x1080", frames_measure(clear_and_present))
	pixels_right[0] = screen_page.pixels[last_pixel] == graphics.colors.background

	// 2. The frame of the compositor, in full and in its damage. The pixel
	// is the middle of the surface of the front window, inside the damage.
	middle_x, middle_y := FRONT_WINDOW_WIDTH / 2, FRONT_WINDOW_HEIGHT / 2
	#assert(FRONT_WINDOW_WIDTH / 2 < PRESENT_WIDTH && FRONT_WINDOW_HEIGHT / 2 < PRESENT_HEIGHT)
	screen_pixel := (front_top + middle_y) * SCREEN_WIDTH + front_left + middle_x
	surface_pixel := front.surface.pixels[middle_y * front.surface.stride + middle_x]
	measure_log("a full frame of the compositor at 1920x1080 with 4 windows", frames_measure(compositor_frame_full))
	pixels_right[1] = screen_page.pixels[screen_pixel] == surface_pixel
	screen_page.pixels[screen_pixel] = surface_pixel ~ 0xFFFFFF
	damage_part: [160]u8
	measure_log(system.format(damage_part[:], "a frame of the compositor at 1920x1080 with 4 windows in its damage of 2 rectangles, ", damage_pixels, " pixels"), frames_measure(compositor_frame_in_its_damage))
	pixels_right[2] = screen_page.pixels[screen_pixel] == surface_pixel

	// 3. The draw table of a desktop. The pixel is the first one of the
	// opaque picture of the first card.
	desktop_build()
	picture_pixel := (CARD_GAP + CARD_LINES_TOP) * SCREEN_WIDTH + CARD_GAP + 16
	frame.pixels[picture_pixel] = opaque_picture.pixels[0] ~ 0xFFFFFF
	counts := desktop_counts
	record_count := counts.opaque_rectangles + counts.cell_texts + counts.interface_texts + counts.opaque_pictures + counts.with_alpha
	desktop_part: [256]u8
	measure_log(system.format(desktop_part[:], "the execution of a draw table of 1920x1080 with ", record_count, " records: ", counts.opaque_rectangles, " opaque rectangles and gradients, ", counts.cell_texts, " texts in the font of the cells, ", counts.interface_texts, " in the interface font, ", counts.opaque_pictures, " opaque pictures, ", counts.with_alpha, " rectangles and pictures with alpha"), frames_measure(desktop_draw))
	pixels_right[3] = frame.pixels[picture_pixel] == opaque_picture.pixels[0]

	tables_whole := !screen_table.full && !screen_table.refused && !desktop_table.full && !desktop_table.refused && u64(desktop_table.record_count) == record_count
	if refusals == 0 && tables_whole && pixels_right[0] && pixels_right[1] && pixels_right[2] && pixels_right[3] {
		system.log(.Info, "processor_frame: ok, each part drew its pixels, the drawing module refused no call, and each table holds each of its records")
		system.stop(0)
	}
	system.log(.Info, "processor_frame: wrong: the pixels of the clear and present, the full frame, the frame in its damage and the draw table are right: ", pixels_right[0] ? "yes" : "no", ", ", pixels_right[1] ? "yes" : "no", ", ", pixels_right[2] ? "yes" : "no", ", ", pixels_right[3] ? "yes" : "no", "; the drawing module refused ", refusals, " calls; each table holds each of its records: ", tables_whole ? "yes" : "no")
	system.stop(1)
}
