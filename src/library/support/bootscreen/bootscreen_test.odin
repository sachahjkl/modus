#+build !freestanding
package bootscreen

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"
import info "modus:contract/boot_info"
import "modus:contract/glyph_cache"
import "modus:support/graphics"
import "modus:support/vector_font"

// The scale of the boot display (src/md/features/boot_display_scale.md):
// the pure procedure of the place, its refusals and its edges first; the
// font of the cells and its refusals; then the display drawn at each scale,
// whose boxes must stay in the panel and whose texts must not overlap.

@(private = "file")
cells_font_file := #load("../../../../resources/fonts/paper_mono.ttf")
@(private = "file")
proportional_font_file := #load("../../../../resources/fonts/b612.ttf")

// The draw, the record of the boxes and the font of the cells are state of
// the package: the tests that use them take this lock, as the runner runs
// tests at the same time.
@(private = "file")
package_state_lock: sync.Mutex

@(test)
a_screen_of_no_pixels_is_refused :: proc(t: ^testing.T) {
	sizes := [?][2]int{{0, 1080}, {1920, 0}, {0, 0}, {-1, 1080}, {1920, -1}, {min(int), min(int)}}
	for size in sizes {
		place, ok := display_place(size[0], size[1])
		testing.expectf(t, !ok, "a screen of %v x %v is refused", size[0], size[1])
		testing.expect_value(t, place, Display_Place{})
	}
}

@(test)
a_screen_below_the_base_size_keeps_scale_one_at_the_top_left :: proc(t: ^testing.T) {
	sizes := [?][2]int{{1, 1}, {WIDTH - 1, HEIGHT}, {WIDTH, HEIGHT - 1}, {800, 600}}
	for size in sizes {
		place, ok := display_place(size[0], size[1])
		testing.expect(t, ok)
		testing.expect_value(t, place.eighths, SCALE_ONE)
		testing.expect_value(t, place.width, WIDTH)
		testing.expect_value(t, place.height, HEIGHT)
		testing.expect_value(t, place.x, max((size[0] - WIDTH) / 2, 0))
		testing.expect_value(t, place.y, max((size[1] - HEIGHT) / 2, 0))
	}
	// One side below the base size: that side starts at 0, the other is
	// in the middle.
	place, _ := display_place(WIDTH + 100, HEIGHT - 1)
	testing.expect_value(t, place.x, 50)
	testing.expect_value(t, place.y, 0)
}

@(test)
the_base_size_is_scale_one_with_no_margin :: proc(t: ^testing.T) {
	place, ok := display_place(WIDTH, HEIGHT)
	testing.expect(t, ok)
	testing.expect_value(t, place, Display_Place{eighths = SCALE_ONE, x = 0, y = 0, width = WIDTH, height = HEIGHT})
}

@(test)
the_least_scale_starts_at_its_size_with_its_margins :: proc(t: ^testing.T) {
	width := scaled(WIDTH, SCALE_LEAST) + 2 * SCREEN_MARGIN
	height := scaled(HEIGHT, SCALE_LEAST) + 2 * SCREEN_MARGIN
	place, ok := display_place(width, height)
	testing.expect(t, ok)
	testing.expect_value(t, place, Display_Place{eighths = SCALE_LEAST, x = SCREEN_MARGIN, y = SCREEN_MARGIN, width = scaled(WIDTH, SCALE_LEAST), height = scaled(HEIGHT, SCALE_LEAST)})
	// One pixel less on either side: the margin does not fit, so scale 1
	// in the middle, never 9 eighths.
	narrow, _ := display_place(width - 1, height)
	testing.expect_value(t, narrow.eighths, SCALE_ONE)
	low, _ := display_place(width, height - 1)
	testing.expect_value(t, low.eighths, SCALE_ONE)
	testing.expect_value(t, low.x, (width - WIDTH) / 2)
}

@(test)
the_reference_screen_takes_one_and_a_half :: proc(t: ^testing.T) {
	place, ok := display_place(1920, 1080)
	testing.expect(t, ok)
	// The height decides: 708 at 13 eighths is 1151 pixels, past 1080.
	REFERENCE_EIGHTHS :: 12
	testing.expect(t, scaled(HEIGHT, REFERENCE_EIGHTHS + 1) + 2 * SCREEN_MARGIN > 1080)
	testing.expect_value(t, place.eighths, REFERENCE_EIGHTHS)
	testing.expect_value(t, place.width, scaled(WIDTH, REFERENCE_EIGHTHS))
	testing.expect_value(t, place.height, scaled(HEIGHT, REFERENCE_EIGHTHS))
	testing.expect_value(t, place.x, (1920 - place.width) / 2)
	testing.expect_value(t, place.y, (1080 - place.height) / 2)
	testing.expect(t, place.y >= SCREEN_MARGIN)
}

@(test)
a_large_screen_takes_the_largest_scale :: proc(t: ^testing.T) {
	place, ok := display_place(3840, 2160)
	testing.expect(t, ok)
	testing.expect_value(t, place.eighths, SCALE_MOST)
	testing.expect_value(t, place.x, (3840 - scaled(WIDTH, SCALE_MOST)) / 2)
	// The largest values of the type: no sum wraps, the scale stays the
	// top of the range, and the panel is in the middle.
	largest, largest_ok := display_place(max(int), max(int))
	testing.expect(t, largest_ok)
	testing.expect_value(t, largest.eighths, SCALE_MOST)
	testing.expect_value(t, largest.x, (max(int) - scaled(WIDTH, SCALE_MOST)) / 2)
	testing.expect_value(t, largest.y, (max(int) - scaled(HEIGHT, SCALE_MOST)) / 2)
}

@(test)
a_wide_screen_that_is_not_tall_keeps_the_proportions :: proc(t: ^testing.T) {
	// The width holds scale 2; the height does not hold 1.25: the scale is
	// 1 on both axes, never a stretch across.
	place, ok := display_place(3840, 800)
	testing.expect(t, ok)
	testing.expect_value(t, place.eighths, SCALE_ONE)
	testing.expect_value(t, place.x, (3840 - WIDTH) / 2)
	testing.expect_value(t, place.y, (800 - HEIGHT) / 2)
	widest, _ := display_place(max(int), HEIGHT)
	testing.expect_value(t, widest.eighths, SCALE_ONE)
	testing.expect_value(t, widest.y, 0)
	flat, _ := display_place(max(int), 1)
	testing.expect_value(t, flat.eighths, SCALE_ONE)
	testing.expect_value(t, flat.y, 0)
}

@(test)
each_edge_rounds_half_up_and_neighbours_share_it :: proc(t: ^testing.T) {
	testing.expect_value(t, scaled(0, SCALE_LEAST), 0)
	testing.expect_value(t, scaled(1, 12), 2) // 1.5: a half rounds up.
	testing.expect_value(t, scaled(-1, 12), -1) // -1.5: up, toward plus infinity.
	testing.expect_value(t, scaled(3, SCALE_LEAST), 4) // 3.75.
	testing.expect_value(t, scaled(1, SCALE_LEAST), 1) // 1.25.
	testing.expect_value(t, scaled(WIDTH, SCALE_ONE), WIDTH)
	for eighths in ([?]int{SCALE_ONE, SCALE_LEAST, 11, 12, 13, 14, 15, SCALE_MOST}) {
		for logical in -1 ..< WIDTH {
			// A rectangle of one logical pixel keeps at least one screen pixel,
			// and two at most at scale 2.
			size := scaled(logical + 1, eighths) - scaled(logical, eighths)
			testing.expectf(t, size >= 1 && size <= 2, "at %v eighths, the pixel %v has %v screen pixels", eighths, logical, size)
		}
		// A cell of the text is whole pixels at each place.
		for place := 0; place < WIDTH; place += CELL {
			testing.expect_value(t, scaled(place + CELL, eighths) - scaled(place, eighths), eighths)
		}
	}
}

@(test)
a_font_of_the_cells_that_is_refused_leaves_no_font :: proc(t: ^testing.T) {
	sync.mutex_lock(&package_state_lock)
	defer sync.mutex_unlock(&package_state_lock)
	memory := new(Scaled_Glyph_Memory)
	defer free(memory)
	testing.expect_value(t, cell_font_use(cells_font_file, nil), vector_font.Font_Problem.Too_Many_Points)
	testing.expect(t, cell_font.memory == nil)
	testing.expect(t, cell_font_use(nil, memory) != .None)
	testing.expect(t, cell_font.memory == nil)
	testing.expect(t, cell_font_use(cells_font_file[:100], memory) != .None)
	testing.expect(t, cell_font.memory == nil)
	// A proportional font has no one advance for a cell.
	testing.expect_value(t, cell_font_use(proportional_font_file, memory), vector_font.Font_Problem.Unknown_Format)
	testing.expect(t, cell_font.memory == nil)
	// With no font, no glyph is drawn: the cell takes the whole scale below.
	_, drawn := scaled_glyph_of(33, 'A', 12)
	testing.expect(t, !drawn)
	testing.expect_value(t, memory.word_count, 0)
}

@(test)
a_glyph_past_the_cells_of_the_renderer_is_refused :: proc(t: ^testing.T) {
	sync.mutex_lock(&package_state_lock)
	defer sync.mutex_unlock(&package_state_lock)
	memory := new(Scaled_Glyph_Memory)
	defer free(memory)
	defer cell_font_use(nil, nil)
	testing.expect_value(t, cell_font_use(cells_font_file, memory), vector_font.Font_Problem.None)
	index, _ := glyph_cache.character_index('A')
	refused := [?][2]int{{index, 0}, {index, -1}, {index, vector_font.CELL_WIDTH_LIMIT + 1}, {index, max(int)}, {-1, 12}, {glyph_cache.CHARACTER_COUNT, 12}, {max(int), 12}}
	for refused_case in refused {
		_, refused_ok := scaled_glyph_of(refused_case[0], 'A', refused_case[1])
		testing.expectf(t, !refused_ok, "the index %v at a cell of %v is refused", refused_case[0], refused_case[1])
		testing.expect_value(t, memory.word_count, 0)
		testing.expect_value(t, memory.cell_widths, [SCALED_CELL_TABLES]int{})
		testing.expect_value(t, memory.drawn_count, 0)
	}
	// The largest cell of the renderer is drawn.
	largest, largest_ok := scaled_glyph_of(index, 'A', vector_font.CELL_WIDTH_LIMIT)
	testing.expect(t, largest_ok)
	testing.expect(t, largest.row_count > 0)
	// A glyph is drawn once, then kept.
	glyph, ok := scaled_glyph_of(index, 'A', 12)
	testing.expect(t, ok)
	testing.expect(t, glyph.row_count > 0 && int(glyph.first_row) + int(glyph.row_count) <= 24)
	words, drawn := memory.word_count, memory.drawn_count
	again, _ := scaled_glyph_of(index, 'A', 12)
	testing.expect_value(t, again, glyph)
	testing.expect_value(t, memory.word_count, words)
	testing.expect_value(t, memory.drawn_count, drawn)
	// A space has no ink and no words.
	space_index, _ := glyph_cache.character_index(' ')
	space, space_ok := scaled_glyph_of(space_index, ' ', 12)
	testing.expect(t, space_ok)
	testing.expect_value(t, space.row_count, 0)
	testing.expect_value(t, memory.word_count, words)
	// A third cell: the scale changed, and the glyphs of the old one go.
	_, _ = scaled_glyph_of(index, 'A', 10)
	testing.expect_value(t, memory.cell_widths, [SCALED_CELL_TABLES]int{10, 0})
	// A full memory empties and starts again: the glyph that did not fit
	// is drawn, and the words never pass the capacity.
	for character in rune(33) ..= 126 {
		character_index, _ := glyph_cache.character_index(character)
		kept, kept_ok := scaled_glyph_of(character_index, character, vector_font.CELL_WIDTH_LIMIT)
		testing.expect(t, kept_ok)
		testing.expect(t, int(kept.word_offset) + int(kept.row_count) * vector_font.CELL_WIDTH_LIMIT <= memory.word_count)
		testing.expect(t, memory.word_count <= SCALED_GLYPH_WORD_CAPACITY)
	}
}

// The data of a machine that started: each card has its facts, with the
// longest texts of a real start.
@(private = "file")
started_machine :: proc(data: ^Data) {
	name_put :: proc(bytes: []u8, name: string) {
		copy(bytes, name)
	}
	boot := &data.boot
	boot.time = 1_234_567
	stages := [?]struct {
		name:            string,
		start, duration: u64,
	}{{"firmware", 0, 900_000}, {"boot program", 900_000, 40_000}, {"kernel memory", 940_000, 12_000}, {"kernel processors", 952_000, 8_000}, {"kernel root", 960_000, 3_000}}
	for stage, index in stages {
		name_put(boot.stages[index].name[:], stage.name)
		boot.stages[index].start = stage.start
		boot.stages[index].duration = stage.duration
	}
	boot.stage_count = len(stages)
	boot.ranges[0] = {start = 0, page_count = 160, kind = u64(info.Memory_Kind.Free)}
	boot.ranges[1] = {start = 1 << 20, page_count = 3200, kind = u64(info.Memory_Kind.Boot)}
	boot.ranges[2] = {start = 64 << 20, page_count = 230_000, kind = u64(info.Memory_Kind.Free)}
	boot.range_count = 3
	boot.firmware_ranges = 104
	boot.direct_map_size = 1 << 30
	name_put(boot.firmware_vendor[:], "EDK II")
	boot.firmware_revision = 0x10000
	boot.framebuffer_width = 1920
	boot.framebuffer_height = 1080
	boot.framebuffer_format = u64(info.Pixel_Format.Blue_Green_Red_X)
	boot.kernel_size = 1_400_000
	boot.kernel_file_size = 1_300_000
	boot.cycle_frequency = 2_995_000_000
	boot.timer_frequency = 1_000_000_000
	boot.trust = {verifier = .Boot_Program, key_kind = .Test, entry_count = 90, measure = .Measured, measure_register = 11}
	data.machine = {page_count = 262_144, free_pages = 200_000, region_count = 300, budget_pages = 50_000, processors = 4}
	for index in 0 ..< 4 {
		data.processors[index].apic_id = u64(index)
	}
	names := [?]string{"root", "input", "compositor", "desktop_files"}
	for name, index in names {
		process := &data.processes[index]
		process.slot = u64(index + 1)
		name_put(process.report.name[:], name)
		process.report.state = .Ready
		process.report.thread_count = 3
		process.report.mapped_pages = u64(1000 * (index + 1))
		process.report.start_time = 961_000 + 9_000 * u64(index)
	}
	data.process_count = len(names)
	data.process_total = 31
	name_put(data.processor_name[:], "QEMU Virtual CPU version 2.5+")
	data.message = "the root service starts the desktop"
	data.state = .Running
	data.step = .Desktop
}

// boxes_check checks the boxes of one draw: each box in the panel, each
// text in its area, and no two texts on each other.
@(private = "file")
boxes_check :: proc(t: ^testing.T, record: ^Drawn_Boxes, place: Display_Place, name: string) {
	testing.expectf(t, record.lost == 0, "%s: %v boxes past the record", name, record.lost)
	testing.expectf(t, record.count > 0, "%s: the draw recorded no box", name)
	texts := 0
	for &box in record.boxes[:record.count] {
		inside := box.left >= 0 && box.top >= 0 && box.right <= place.width && box.bottom <= place.height && box.left <= box.right && box.top <= box.bottom
		testing.expectf(t, inside, "%s: a box %v leaves the panel of %v x %v", name, box, place.width, place.height)
		if box.kind != .Text {
			continue
		}
		texts += 1
		in_area := box.left >= box.area_left && box.top >= box.area_top && box.right <= box.area_right && box.bottom <= box.area_bottom
		testing.expectf(t, in_area, "%s: a text %v leaves its area", name, box)
	}
	testing.expectf(t, texts > 40, "%s: %v texts drawn", name, texts)
	for &first, index in record.boxes[:record.count] {
		if first.kind != .Text {
			continue
		}
		for &second in record.boxes[index + 1:record.count] {
			if second.kind != .Text {
				continue
			}
			overlap := first.left < second.right && second.left < first.right && first.top < second.bottom && second.top < first.bottom
			testing.expectf(t, !overlap, "%s: the texts %v and %v overlap", name, first, second)
		}
	}
}

@(test)
the_boot_display_at_each_scale_keeps_its_boxes :: proc(t: ^testing.T) {
	sync.mutex_lock(&package_state_lock)
	defer sync.mutex_unlock(&package_state_lock)
	data := new(Data)
	defer free(data)
	started_machine(data)
	record := new(Drawn_Boxes)
	defer free(record)
	memory := new(Scaled_Glyph_Memory)
	defer free(memory)
	drawn_boxes = record
	defer drawn_boxes = nil
	defer cell_font_use(nil, nil)
	// The screens of the scales 1, 10/8, 12/8 and 16/8.
	screens := [?]struct {
		width, height, eighths: int,
	}{{1024, 768, SCALE_ONE}, {1280, 960, SCALE_LEAST}, {1920, 1080, 12}, {3840, 2160, SCALE_MOST}}
	for screen in screens {
		place, ok := display_place(screen.width, screen.height)
		testing.expect(t, ok)
		testing.expect_value(t, place.eighths, screen.eighths)
		pixels := make([]graphics.Color, screen.width * screen.height)
		defer delete(pixels)
		canvas := graphics.Canvas{pixels = raw_data(pixels), width = screen.width, height = screen.height, stride = screen.width}
		// The boot program draws with no font of the cells; the root
		// service with one. The boxes are the same.
		for with_font in ([2]bool{false, true}) {
			if with_font {
				testing.expect_value(t, cell_font_use(cells_font_file, memory), vector_font.Font_Problem.None)
			} else {
				cell_font_use(nil, nil)
			}
			for &pixel in pixels {
				pixel = 0xFF00FF
			}
			record.count, record.lost = 0, 0
			memory.drawn_count = 0
			draw_screen(canvas, data)
			name := fmt.tprintf("%v x %v, %v eighths, font of the cells %v", screen.width, screen.height, place.eighths, with_font)
			boxes_check(t, record, place, name)
			// Each pixel outside the panel is the background, and the
			// panel covers each of its own pixels.
			testing.expect_value(t, pixels[0], graphics.Color(graphics.DARK_BACKGROUND))
			testing.expect_value(t, pixels[len(pixels) - 1], graphics.Color(graphics.DARK_BACKGROUND))
			missed := 0
			for row in place.y ..< place.y + place.height {
				for column in place.x ..< place.x + place.width {
					if pixels[row * screen.width + column] == 0xFF00FF {
						missed += 1
					}
				}
			}
			testing.expectf(t, missed == 0, "%s: %v pixels of the panel are not drawn", name, missed)
			// A cell of a whole scale draws from the caches; another from the
			// outlines when the font is given.
			cell_from_outlines := place.eighths % SCALE_ONE != 0
			testing.expectf(t, (memory.drawn_count > 0) == (with_font && cell_from_outlines), "%s: %v glyphs drawn from the outlines", name, memory.drawn_count)
		}
	}
}

// The cost of the glyphs of the root service at each scale: the first
// draw of the display after the font is given draws each glyph from its
// outline; the next draw finds them kept. It prints measures and asserts
// nothing. It measures only when the environment sets
// MODUS_MEASURE_BOOT_DISPLAY:
//
//   MODUS_MEASURE_BOOT_DISPLAY=1 odin test src/library/support/bootscreen -o:speed -collection:modus=src/library -define:ODIN_TEST_NAMES=bootscreen.scaled_glyph_measure
//
// Each time is the least of MEASURE_BATCHES draws, so that an interruption
// of the host does not count.
@(test)
scaled_glyph_measure :: proc(t: ^testing.T) {
	if os.get_env("MODUS_MEASURE_BOOT_DISPLAY", context.temp_allocator) == "" {
		return
	}
	MEASURE_BATCHES :: 20
	sync.mutex_lock(&package_state_lock)
	defer sync.mutex_unlock(&package_state_lock)
	data := new(Data)
	defer free(data)
	started_machine(data)
	memory := new(Scaled_Glyph_Memory)
	defer free(memory)
	defer cell_font_use(nil, nil)
	screens := [?][2]int{{1280, 960}, {1920, 1080}, {3840, 2160}}
	for screen in screens {
		pixels := make([]graphics.Color, screen[0] * screen[1])
		defer delete(pixels)
		canvas := graphics.Canvas{pixels = raw_data(pixels), width = screen[0], height = screen[1], stride = screen[0]}
		place, _ := display_place(screen[0], screen[1])
		first_least, kept_least := max(i64), max(i64)
		for _ in 0 ..< MEASURE_BATCHES {
			cell_font_use(cells_font_file, memory)
			start := time.tick_now()
			draw_screen(canvas, data)
			first_least = min(first_least, i64(time.duration_microseconds(time.tick_since(start))))
			start = time.tick_now()
			draw_screen(canvas, data)
			kept_least = min(kept_least, i64(time.duration_microseconds(time.tick_since(start))))
		}
		fmt.printfln("bootscreen: the display at %v eighths on %v x %v: %v us for the first draw with %v glyphs from the outlines, %v us for a draw with the glyphs kept (%v words kept, the least of %v draws)", place.eighths, screen[0], screen[1], first_least, memory.drawn_count, kept_least, memory.word_count, MEASURE_BATCHES)
	}
}
