package modustool

import "modus:contract/pointer_pictures"
import "modus:support/graphics"
import "modus:support/mark"
import "core:fmt"
import "core:os"
import "core:time"

// The preview sheet of the theme of the system, for a reader who draws a
// shape: `modustool pointers preview <file.png>` reads the manifest of the
// system, draws each shape in each form at each size, and writes one PNG
// file with no machine. A row for each shape: its name and its hot spot,
// then for each form two blocks: on the surface of its appearance, and on
// a mid grey, where the edge shows as well as the fill (the surface of the
// appearance has the color of the edge). In each block each size is at 1:1
// and magnified with a grid of its pixels; a magnified square on the grey
// is a checkerboard of two greys, so that a pixel of the edge shows against
// both. A frame of amber marks the hot spot. An animated shape has a second
// row for its second frame.

POINTER_PREVIEW_MARGIN :: 16
POINTER_PREVIEW_GAP :: 8
POINTER_PREVIEW_LINE :: 20 // A line of the font of 8 by 16.
POINTER_PREVIEW_NAME_WIDTH :: 30 * 8 // 30 characters: the longest name has 28.
POINTER_PREVIEW_MAGNIFIED :: 192 // The side of a magnified picture: 24 at 8 times, 48 at 4 times.

// The surface under each form: the background of the desktop, and the
// light background of the site.
pointer_preview_surfaces := [pointer_pictures.Pointer_Form]graphics.Color {
	.Dark  = graphics.COLOR_BACKGROUND,
	.Light = graphics.Color(mark.BACKGROUND_LIGHT),
}
// The two greys of the block where the edge and the fill both show: the
// first at 1:1, both as a checkerboard when magnified.
POINTER_PREVIEW_GREY :: graphics.Color(0x808080)
POINTER_PREVIEW_GREY_SECOND :: graphics.Color(0x6C6C6C)

// pointer_preview_magnification gives how many times a size is magnified.
pointer_preview_magnification :: proc(size: u32) -> int {
	return max(POINTER_PREVIEW_MAGNIFIED / int(size), 1)
}

run_pointers_preview :: proc(output: string) -> int {
	start := time.tick_now()
	text, read_ok := read_file(SYSTEM_POINTER_MANIFEST)
	if !read_ok {
		return EXIT_FAILURE
	}
	manifest, problem := manifest_parse(SYSTEM_POINTER_MANIFEST, string(text))
	if problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		return EXIT_FAILURE
	}
	file, _, made_problem := pointer_theme_make(manifest, "")
	if made_problem != "" {
		fmt.eprintfln("modustool: %s: %s", SYSTEM_POINTER_MANIFEST, made_problem)
		return EXIT_FAILURE
	}
	sizes := manifest.sizes[:]
	form_width := POINTER_PREVIEW_GAP
	tallest := 0
	for size in sizes {
		magnified := int(size) * pointer_preview_magnification(size)
		form_width += int(size) + POINTER_PREVIEW_GAP + magnified + POINTER_PREVIEW_GAP
		tallest = max(tallest, magnified)
	}
	row_height := max(tallest + 2 * POINTER_PREVIEW_GAP, 3 * POINTER_PREVIEW_LINE) + POINTER_PREVIEW_GAP
	// Two blocks for each form: its surface, and the grey.
	width := 2 * POINTER_PREVIEW_MARGIN + POINTER_PREVIEW_NAME_WIDTH + 2 * len(pointer_pictures.Pointer_Form) * (form_width + POINTER_PREVIEW_GAP)
	row_count := 0
	for &item in manifest.shapes {
		row_count += len(item.frames) > 0 ? 2 : 1
	}
	height := 2 * POINTER_PREVIEW_MARGIN + POINTER_PREVIEW_LINE + row_count * row_height

	colors := make([]graphics.Color, width * height, context.temp_allocator)
	canvas := graphics.Canvas{pixels = raw_data(colors), width = width, height = height, stride = width}
	graphics.clear(canvas, graphics.COLOR_TRACK)
	saved := graphics.text_state
	defer graphics.text_state = saved
	graphics.text_choice_set(.Spleen, .Red_Green_Blue)

	y := POINTER_PREVIEW_MARGIN
	graphics.text(canvas, POINTER_PREVIEW_MARGIN, y, fmt.tprintf("%s: each shape, the dark form then the light form, each on its surface and on grey, each size at 1:1 and magnified; amber: the hot spot", SYSTEM_POINTER_MANIFEST), graphics.COLOR_TEXT)
	y += POINTER_PREVIEW_LINE
	for shape in pointer_pictures.Pointer_Shape {
		item: ^Manifest_Shape
		for &candidate in manifest.shapes {
			if candidate.shape == shape {
				item = &candidate
			}
		}
		if item == nil {
			continue
		}
		frame_count := len(item.frames)
		for frame in 0 ..< max(min(frame_count, 2), 1) {
			name := pointer_pictures.SHAPE_NAMES[shape]
			graphics.text(canvas, POINTER_PREVIEW_MARGIN, y + POINTER_PREVIEW_GAP, name, graphics.COLOR_TEXT)
			graphics.text(canvas, POINTER_PREVIEW_MARGIN, y + POINTER_PREVIEW_GAP + POINTER_PREVIEW_LINE, fmt.tprintf("hot %d,%d", item.hot_spot.x, item.hot_spot.y), graphics.COLOR_BOOT_PROGRAM)
			// The time of the frame: the first frame at 0, the second at the
			// delay of the first.
			time_milliseconds: u64 = 0
			if frame_count > 0 {
				graphics.text(canvas, POINTER_PREVIEW_MARGIN, y + POINTER_PREVIEW_GAP + 2 * POINTER_PREVIEW_LINE, fmt.tprintf("frame %d of %d", frame + 1, frame_count), graphics.COLOR_DIM)
				if frame > 0 {
					time_milliseconds = u64(item.frames[0].delay)
				}
			}
			x := POINTER_PREVIEW_MARGIN + POINTER_PREVIEW_NAME_WIDTH
			for form in pointer_pictures.Pointer_Form {
				// The surface of the appearance, plain; then the grey, as a
				// checkerboard when magnified.
				blocks := [2][2]graphics.Color{{pointer_preview_surfaces[form], pointer_preview_surfaces[form]}, {POINTER_PREVIEW_GREY, POINTER_PREVIEW_GREY_SECOND}}
				for block in blocks {
					graphics.fill(canvas, x, y, form_width, row_height - POINTER_PREVIEW_GAP, block[0])
					place := x + POINTER_PREVIEW_GAP
					for size in sizes {
						chosen := pointer_pictures.choose(file, form, shape, size, time_milliseconds)
						// The hot spot in the square of the size, and where
						// the box of the picture is in that square.
						hot_x, hot_y := int(item.hot_spot.x * size / sizes[0]), int(item.hot_spot.y * size / sizes[0])
						left, top := hot_x - int(chosen.picture.hot_spot_x), hot_y - int(chosen.picture.hot_spot_y)
						pointer_preview_draw(canvas, place, y + POINTER_PREVIEW_GAP, int(size), 1, chosen, left, top, hot_x, hot_y, block[0], block[0])
						place += int(size) + POINTER_PREVIEW_GAP
						magnification := pointer_preview_magnification(size)
						pointer_preview_draw(canvas, place, y + POINTER_PREVIEW_GAP, int(size), magnification, chosen, left, top, hot_x, hot_y, block[0], block[1])
						place += int(size) * magnification + POINTER_PREVIEW_GAP
					}
					x += form_width + POINTER_PREVIEW_GAP
				}
			}
			y += row_height
		}
	}

	rgb := make([]u8, 3 * len(colors), context.temp_allocator)
	for color, index in colors {
		rgb[3 * index] = u8(color >> 16)
		rgb[3 * index + 1] = u8(color >> 8)
		rgb[3 * index + 2] = u8(color)
	}
	data, encoded := mark_pixels_png_quick(output, width, height, 3, rgb)
	if !encoded {
		return EXIT_FAILURE
	}
	if err := os.write_entire_file(output, data); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", output, err)
		return EXIT_FAILURE
	}
	fmt.printfln("modustool: pointers: wrote %s (%d by %d pixels): %d shapes in %d forms at the sizes %v, in %.1f ms", output, width, height, len(manifest.shapes), len(pointer_pictures.Pointer_Form), sizes, time.duration_milliseconds(time.tick_since(start)))
	return 0
}

// pointer_preview_draw draws the square of one size at x, y, each pixel a
// block of magnification x magnification: the picture over the surface,
// with its box at left, top in the square. The surface is a checkerboard of
// its two colors (two equal colors: plain). A magnified square has a grid
// of its pixels and a frame on its hot spot; a square at 1:1 has a mark of
// 3 pixels above and at the left of its hot spot.
pointer_preview_draw :: proc(canvas: graphics.Canvas, x, y, side, magnification: int, chosen: pointer_pictures.Chosen, left, top, hot_x, hot_y: int, surface, surface_second: graphics.Color) {
	width, height := int(chosen.picture.width), int(chosen.picture.height)
	for row in 0 ..< side {
		for column in 0 ..< side {
			under := (row + column) % 2 == 0 ? surface : surface_second
			color := under
			inside_x, inside_y := column - left, row - top
			if inside_x >= 0 && inside_y >= 0 && inside_x < width && inside_y < height {
				pixel := chosen.pixels[inside_y * width + inside_x]
				// A premultiplied pixel over the surface.
				kept := 255 - (pixel >> 24)
				color = 0
				for shift in ([?]u32{0, 8, 16}) {
					channel := (pixel >> shift) & 0xFF + ((u32(under) >> shift) & 0xFF) * kept / 255
					color |= graphics.Color(min(channel, 255) << shift)
				}
			}
			graphics.fill(canvas, x + column * magnification, y + row * magnification, magnification, magnification, color)
		}
	}
	if magnification == 1 {
		graphics.fill(canvas, x + hot_x, y - 4, 1, 3, graphics.COLOR_BOOT_PROGRAM)
		graphics.fill(canvas, x - 4, y + hot_y, 3, 1, graphics.COLOR_BOOT_PROGRAM)
		return
	}
	grid := graphics.mix(surface, graphics.COLOR_DIM, 72)
	for line in 0 ..= side {
		graphics.fill(canvas, x + line * magnification, y, 1, side * magnification, grid)
		graphics.fill(canvas, x, y + line * magnification, side * magnification, 1, grid)
	}
	graphics.outline(canvas, x + hot_x * magnification, y + hot_y * magnification, magnification + 1, magnification + 1, 1, graphics.COLOR_BOOT_PROGRAM)
}
