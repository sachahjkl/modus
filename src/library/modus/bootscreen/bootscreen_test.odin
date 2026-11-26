#+build !freestanding
#+build !modus
package bootscreen

import "core:fmt"
import "core:sync"
import "core:testing"
import info "modus:contract/boot_info"
import "modus:contract/font_characters"
import "modus:graphics"

// The scale of the boot display (src/md/features/boot_display_scale.md):
// the pure procedure of the place, snapped to the sizes of Spleen, its
// refusals and its edges first; the form of Spleen of each cell and the
// pixels of each size; then the display drawn at each scale, whose boxes
// must stay in the panel and whose texts must not overlap.

// The draw and the record of the boxes are state of the package: the
// tests that use them take this lock, as the runner runs tests at the
// same time.
@(private = "file")
package_state_lock: sync.Mutex

// The scales of the display, from scale 1.
@(private = "file")
EVERY_SCALE :: [4]int{SCALE_ONE, SPLEEN_12X24_WIDTH, SPLEEN_16X32_WIDTH, SPLEEN_32X64_WIDTH}

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
each_scale_starts_at_its_size_with_its_margins :: proc(t: ^testing.T) {
	scales := DISPLAY_SCALES
	for eighths in scales {
		width := scaled(WIDTH, eighths) + 2 * SCREEN_MARGIN
		height := scaled(HEIGHT, eighths) + 2 * SCREEN_MARGIN
		place, ok := display_place(width, height)
		testing.expect(t, ok)
		testing.expect_value(t, place, Display_Place{eighths = eighths, x = SCREEN_MARGIN, y = SCREEN_MARGIN, width = scaled(WIDTH, eighths), height = scaled(HEIGHT, eighths)})
		// One pixel less on either side: the scale below in the list, never
		// a scale between two sizes of Spleen.
		for smaller in ([2][2]int{{width - 1, height}, {width, height - 1}}) {
			below, _ := display_place(smaller[0], smaller[1])
			testing.expectf(t, below.eighths < eighths, "%v x %v takes %v eighths", smaller[0], smaller[1], below.eighths)
			testing.expectf(t, below.eighths == SCALE_ONE || below.eighths == SPLEEN_12X24_WIDTH || below.eighths == SPLEEN_16X32_WIDTH, "%v x %v takes %v eighths, no size of Spleen", smaller[0], smaller[1], below.eighths)
		}
	}
	// The width of the base size, and one pixel less than the first scale.
	first, _ := display_place(scaled(WIDTH, SPLEEN_12X24_WIDTH) + 2 * SCREEN_MARGIN - 1, 1080)
	testing.expect_value(t, first.eighths, SCALE_ONE)
}

@(test)
the_common_screens_take_their_sizes_of_spleen :: proc(t: ^testing.T) {
	screens := [?]struct {
		width, height, eighths: int,
	}{
		{1920, 1080, SPLEEN_12X24_WIDTH}, // 1464 x 1062.
		{2560, 1440, SPLEEN_16X32_WIDTH}, // 1952 x 1416.
		{3840, 2160, SPLEEN_16X32_WIDTH}, // 32x64 needs 2832 lines.
		{5120, 2880, SPLEEN_32X64_WIDTH}, // 3904 x 2832.
		{7680, 4320, SPLEEN_32X64_WIDTH},
		{1366, 768, SCALE_ONE},
	}
	for screen in screens {
		place, ok := display_place(screen.width, screen.height)
		testing.expect(t, ok)
		testing.expectf(t, place.eighths == screen.eighths, "%v x %v takes %v eighths, not %v", screen.width, screen.height, place.eighths, screen.eighths)
		testing.expect_value(t, place.width, scaled(WIDTH, place.eighths))
		testing.expect_value(t, place.x, (screen.width - place.width) / 2)
		testing.expect_value(t, place.y, (screen.height - place.height) / 2)
	}
}

@(test)
a_wide_screen_that_is_not_tall_keeps_the_proportions :: proc(t: ^testing.T) {
	place, ok := display_place(7680, 1000)
	testing.expect(t, ok)
	testing.expect_value(t, place.eighths, SCALE_ONE)
	testing.expect_value(t, place.x, (7680 - WIDTH) / 2)
	widest, _ := display_place(max(int), HEIGHT)
	testing.expect_value(t, widest.eighths, SCALE_ONE)
	testing.expect_value(t, widest.y, 0)
	flat, _ := display_place(max(int), 1)
	testing.expect_value(t, flat.eighths, SCALE_ONE)
	testing.expect_value(t, flat.y, 0)
	// The largest values of the type: no sum wraps, and the largest size.
	largest, largest_ok := display_place(max(int), max(int))
	testing.expect(t, largest_ok)
	testing.expect_value(t, largest.eighths, SPLEEN_32X64_WIDTH)
	testing.expect_value(t, largest.x, (max(int) - scaled(WIDTH, SPLEEN_32X64_WIDTH)) / 2)
}

@(test)
each_edge_rounds_half_up_and_neighbours_share_it :: proc(t: ^testing.T) {
	testing.expect_value(t, scaled(0, SPLEEN_12X24_WIDTH), 0)
	testing.expect_value(t, scaled(1, SPLEEN_12X24_WIDTH), 2) // 1.5: a half rounds up.
	testing.expect_value(t, scaled(-1, SPLEEN_12X24_WIDTH), -1) // -1.5: up, toward plus infinity.
	testing.expect_value(t, scaled(WIDTH, SCALE_ONE), WIDTH)
	testing.expect_value(t, scaled(WIDTH, SPLEEN_32X64_WIDTH), 4 * WIDTH)
	scales := EVERY_SCALE
	for eighths in scales {
		for logical in -1 ..< WIDTH {
			size := scaled(logical + 1, eighths) - scaled(logical, eighths)
			testing.expectf(t, size >= eighths / SCALE_ONE && size <= (eighths + SCALE_ONE - 1) / SCALE_ONE, "at %v eighths, the pixel %v has %v screen pixels", eighths, logical, size)
		}
		// A cell of the text is whole pixels at each place.
		for place := 0; place < WIDTH; place += CELL {
			testing.expect_value(t, scaled(place + CELL, eighths) - scaled(place, eighths), eighths)
		}
	}
}

@(test)
a_cell_that_no_size_fills_is_refused :: proc(t: ^testing.T) {
	for cell in ([?]int{min(int), -1, 0, 1, graphics.CELL_WIDTH - 1, 10, 14, 20, 30, max(int)}) {
		form, ok := spleen_form_of(cell)
		testing.expectf(t, !ok, "a cell of %v is refused", cell)
		testing.expect_value(t, form, Spleen_Form{})
	}
}

@(test)
each_cell_of_each_scale_has_its_size_of_spleen :: proc(t: ^testing.T) {
	expected := [?]struct {
		cell: int,
		form: Spleen_Form,
	}{
		{graphics.CELL_WIDTH, {.Cells_8x16, 1}},
		{SPLEEN_12X24_WIDTH, {.Cells_12x24, 1}},
		{SPLEEN_16X32_WIDTH, {.Cells_16x32, 1}},
		{SPLEEN_32X64_WIDTH, {.Cells_32x64, 1}},
		// The large digits at 12 and 32 eighths: no size has their cell.
		{2 * SPLEEN_12X24_WIDTH, {.Cells_8x16, 3}},
		{2 * SPLEEN_32X64_WIDTH, {.Cells_8x16, 8}},
	}
	for row in expected {
		form, ok := spleen_form_of(row.cell)
		testing.expect(t, ok)
		testing.expectf(t, form == row.form, "a cell of %v is %v, not %v", row.cell, form, row.form)
	}
	// Each cell that the display draws, the text and the large digits, has
	// a form that fills it.
	scales := EVERY_SCALE
	for eighths in scales {
		for cell in ([2]int{CELL * eighths / SCALE_ONE, LARGE_CELL * eighths / SCALE_ONE}) {
			form, ok := spleen_form_of(cell)
			testing.expectf(t, ok, "at %v eighths the cell of %v has no form", eighths, cell)
			testing.expect_value(t, spleen_size_widths[form.size] * form.factor, cell)
		}
	}
}

// m_draw draws M in one cell into a canvas of that cell.
@(private = "file")
m_draw :: proc(pixels: []graphics.Color, cell_width: int) -> graphics.Canvas {
	for &pixel in pixels {
		pixel = 0
	}
	canvas := graphics.Canvas{pixels = raw_data(pixels), width = cell_width, height = 2 * cell_width, stride = cell_width}
	spleen_text_draw(canvas, 0, 0, "M", graphics.COLOR_WHITE, cell_width)
	return canvas
}

@(test)
m_has_the_pixels_of_each_size :: proc(t: ^testing.T) {
	largest_cell := 2 * SPLEEN_32X64_WIDTH
	pixels := make([]graphics.Color, largest_cell * 2 * largest_cell)
	defer delete(pixels)
	index, _ := font_characters.character_index('M')
	// ink gives the bit of the table of a size, at a pixel of its cell.
	ink :: proc(size: Spleen_Size, index, row, column: int) -> bool {
		switch size {
		case .Cells_8x16:
			return graphics.font[index][row] << uint(column) & 0x80 != 0
		case .Cells_12x24:
			return spleen_12x24[index][row] << uint(column) & 0x8000 != 0
		case .Cells_16x32:
			return spleen_16x32[index][row] << uint(column) & 0x8000 != 0
		case .Cells_32x64:
			return spleen_32x64[index][row] << uint(column) & 0x8000_0000 != 0
		}
		return false
	}
	cells := [?]int{graphics.CELL_WIDTH, SPLEEN_12X24_WIDTH, SPLEEN_16X32_WIDTH, SPLEEN_32X64_WIDTH, 2 * SPLEEN_12X24_WIDTH, 2 * SPLEEN_32X64_WIDTH}
	for cell in cells {
		form, _ := spleen_form_of(cell)
		canvas := m_draw(pixels, cell)
		wrong, drawn_count := 0, 0
		for row in 0 ..< 2 * cell {
			for column in 0 ..< cell {
				expected := ink(form.size, index, row / form.factor, column / form.factor)
				drawn := canvas.pixels[row * canvas.stride + column] != 0
				if drawn {
					drawn_count += 1
				}
				if expected != drawn {
					wrong += 1
				}
			}
		}
		testing.expectf(t, wrong == 0 && drawn_count > 0, "M in a cell of %v: %v pixels differ from Spleen %v at %v times, %v drawn", cell, wrong, form.size, form.factor, drawn_count)
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
	boot.trust = {verifier = u64(info.Verifier.Boot_Program), key_kind = u64(info.Signing_Key_Kind.Test), entry_count = 90, measure = u64(info.Measure_State.Measured), measure_register = 11}
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
	drawn_boxes = record
	defer drawn_boxes = nil
	// A screen of each scale: 1, 1.5, 2 and 4.
	screens := [?]struct {
		width, height, eighths: int,
	}{{1024, 768, SCALE_ONE}, {1920, 1080, SPLEEN_12X24_WIDTH}, {2560, 1440, SPLEEN_16X32_WIDTH}, {5120, 2880, SPLEEN_32X64_WIDTH}}
	for screen in screens {
		place, ok := display_place(screen.width, screen.height)
		testing.expect(t, ok)
		testing.expect_value(t, place.eighths, screen.eighths)
		pixels := make([]graphics.Color, screen.width * screen.height)
		defer delete(pixels)
		canvas := graphics.Canvas{pixels = raw_data(pixels), width = screen.width, height = screen.height, stride = screen.width}
		for &pixel in pixels {
			pixel = 0xFF00FF
		}
		record.count, record.lost = 0, 0
		draw_screen(canvas, data)
		name := fmt.tprintf("%v x %v, %v eighths", screen.width, screen.height, place.eighths)
		boxes_check(t, record, place, name)
		// Each pixel outside the panel is the background, and the panel
		// covers each of its own pixels.
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
	}
}
