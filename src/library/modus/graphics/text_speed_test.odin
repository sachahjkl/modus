#+build !freestanding
#+build !modus
package graphics

import "core:fmt"
import "core:sync"
import "core:testing"
import "core:time"

// The cost of the text, part by part, on the host (docs/FONTS.md, section
// 5): run with `taskset -c N` and -o:speed. Each number is the least of
// many batches, so that an interruption of the host does not count. The
// glyphs are those of the face of the cells (face_glyphs_test.odin).

@(private = "file")
speed_sample := "compositor  12.4 ms  2 418 pages {fill} [rings] gi Rb 0O 1lI"
SPEED_BATCHES :: 3000
SPEED_GLYPHS :: 60

// speed_least runs one batch of the sample line many times and gives the
// least time of one glyph, in nanoseconds (one decimal).
@(private = "file")
speed_least :: proc(batch: proc(canvas: Canvas, data: rawptr), canvas: Canvas, data: rawptr, background := Speed_Background.Flat) -> f64 {
	least := max(i64)
	for _ in 0 ..< SPEED_BATCHES {
		background_fill(canvas, background) // Not in the time: each batch draws over the background.
		start := time.tick_now()
		batch(canvas, data)
		least = min(least, time.duration_nanoseconds(time.tick_since(start)))
	}
	return f64(least) / SPEED_GLYPHS
}

@(test)
text_speed_parts :: proc(t: ^testing.T) {
	sync.mutex_lock(&fallback_test_lock)
	defer sync.mutex_unlock(&fallback_test_lock)
	glyphs := test_glyphs_of(t, .Cells)
	defer test_glyphs_free(glyphs)
	// Where the words of a cell fall, at scale 1, over the sample line.
	zero, full, partial, outside: int
	for index in 0 ..< len(speed_sample) {
		entry, words, _ := test_glyph(glyphs, rune(speed_sample[index]), 1)
		outside += (CELL_HEIGHT - int(entry.row_count)) * int(entry.width)
		if entry.row_count == 0 {
			continue
		}
		for word in words[:int(entry.row_count) * int(entry.width)] {
			switch {
			case word == 0:
				zero += 1
			case word & 0x00FFFFFF == 0x00FFFFFF:
				full += 1
			case:
				partial += 1
			}
		}
	}
	cells := len(speed_sample)
	fmt.printfln("graphics: the words of one cell of 128 pixels, on the mean: %.1f rows with no ink, %.1f zero, %.1f full, %.1f partial", f64(outside) / f64(cells), f64(zero) / f64(cells), f64(full) / f64(cells), f64(partial) / f64(cells))

	data := new(Speed_Data)
	defer free(data)
	data.glyphs = glyphs
	square_root_table_fill(&data.table)
	pixels := make([]Color, 640 * 48)
	defer delete(pixels)
	canvas := Canvas{pixels = raw_data(pixels), width = 640, height = 48, stride = 640}
	walk := speed_least(proc(canvas: Canvas, raw: rawptr) {
		data := (^Speed_Data)(raw)
		sum: u32
		for index in 0 ..< SPEED_GLYPHS {
			entry, words, _ := test_glyph(data.glyphs, rune(speed_sample[index]), 1)
			if entry.row_count == 0 {
				continue
			}
			for word in words[:int(entry.row_count) * int(entry.width)] {
				sum += word
			}
		}
		canvas.pixels[0] = sum
	}, canvas, data)
	background_fill(canvas, .Flat)
	spleen := speed_least(proc(canvas: Canvas, raw: rawptr) {
		for index in 0 ..< SPEED_GLYPHS {
			character_spleen(canvas, 8 * index, 8, rune(speed_sample[index]), DARK_TEXT)
		}
	}, canvas, data)
	fmt.printfln("graphics: one glyph at scale 1 on the host: only a walk over its words %.1f ns; Spleen 8x16 %.1f ns", walk, spleen)
	for background in Speed_Background {
		background_fill(canvas, background)
		reference := speed_least(proc(canvas: Canvas, raw: rawptr) {
			data := (^Speed_Data)(raw)
			for index in 0 ..< SPEED_GLYPHS {
				test_glyph_reference_draw(data.glyphs, &data.table, .Red_Green_Blue, canvas, 8 * index, 8, rune(speed_sample[index]), DARK_TEXT, 1)
			}
		}, canvas, data, background)
		data.tables = {}
		fast := speed_least(proc(canvas: Canvas, raw: rawptr) {
			data := (^Speed_Data)(raw)
			for index in 0 ..< SPEED_GLYPHS {
				test_glyph_fast_draw(data.glyphs, &data.table, &data.tables, .Red_Green_Blue, canvas, 8 * index, 8, rune(speed_sample[index]), DARK_TEXT, 1)
			}
		}, canvas, data, background)
		fmt.printfln("graphics: one glyph at scale 1 over %v: the reference blend %.1f ns, the fast blend %.1f ns, %v tables made", background, reference, fast, data.tables.made)
	}
	// The scales 2 and 3 over a flat color.
	for scale in 2 ..= 3 {
		data.scale = scale
		reference := speed_least(proc(canvas: Canvas, raw: rawptr) {
			data := (^Speed_Data)(raw)
			for index in 0 ..< SPEED_GLYPHS / 3 {
				test_glyph_reference_draw(data.glyphs, &data.table, .Red_Green_Blue, canvas, 8 * data.scale * index, 0, rune(speed_sample[index]), DARK_TEXT, data.scale)
			}
		}, canvas, data)
		fast := speed_least(proc(canvas: Canvas, raw: rawptr) {
			data := (^Speed_Data)(raw)
			for index in 0 ..< SPEED_GLYPHS / 3 {
				test_glyph_fast_draw(data.glyphs, &data.table, &data.tables, .Red_Green_Blue, canvas, 8 * data.scale * index, 0, rune(speed_sample[index]), DARK_TEXT, data.scale)
			}
		}, canvas, data)
		enlarged := speed_least(proc(canvas: Canvas, raw: rawptr) {
			data := (^Speed_Data)(raw)
			for index in 0 ..< SPEED_GLYPHS / 3 {
				character_spleen_enlarged(canvas, 8 * data.scale * index, 0, rune(speed_sample[index]), DARK_TEXT, data.scale)
			}
		}, canvas, data)
		fmt.printfln("graphics: one glyph at scale %v over Flat: the reference blend %.1f ns, the fast blend %.1f ns, Spleen enlarged %.1f ns", scale, 3 * reference, 3 * fast, 3 * enlarged)
	}
}

Speed_Data :: struct {
	glyphs: ^Test_Glyphs,
	table:  [4096]u8,
	tables: Blend_Tables,
	scale:  int,
}

Speed_Background :: enum {
	Flat, // One color: the console, a flat card.
	Card, // The card of the rules: DARK_CARD_TOP to DARK_CARD_BOTTOM over 400 rows.
	Across, // The title bar: a gradient from the left to the right.
	Noise, // Each pixel of its own color: a picture.
}

// background_fill draws a background over the whole canvas. Each time the
// same: a batch draws over the same pixels as the batch before, so the
// pixels under the text are text (a batch of text over text: the blend of
// one glyph over itself, as a picture drawn again does).
background_fill :: proc(canvas: Canvas, background: Speed_Background) {
	state := u32(99)
	for y in 0 ..< canvas.height {
		for x in 0 ..< canvas.width {
			pixel := &canvas.pixels[y * canvas.stride + x]
			switch background {
			case .Flat:
				pixel^ = DARK_CARD_BOTTOM
			case .Card:
				pixel^ = mix(DARK_CARD_TOP, DARK_CARD_BOTTOM, u32((y + 200) * 255 / 400))
			case .Across:
				pixel^ = mix(DARK_TITLE, DARK_TITLE_END, u32(x * 255 / canvas.width))
			case .Noise:
				state = state * 1664525 + 1013904223
				pixel^ = state >> 8
			}
		}
	}
}
