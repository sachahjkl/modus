// The choice of the vector font (docs/FONTS.md, "The font file"): the same
// lines of the system in each candidate font and in Spleen 8x16, one word of
// each enlarged, and the measures of the text path.
//
// The module carries the subsets of the candidates of resources/fonts, and
// its process opens each one as the font of the cells of a font set of its
// own (text_rendering.font_file_open). It draws the lines of each
// candidate through the face of the cells of that set, with the rasterizer
// and the blend of the text of the system (graphics.character_of_set): a
// candidate is drawn as it would be drawn if it were the font of the
// system. The text of the window itself is the text of the system: the
// glyphs that the process draws from the font outlines into its private
// glyph cache, or Spleen, as the setting says.
//
// **What it is for.** It is the record of a choice: a reader sees the same
// lines in each candidate font at the sizes of the system, and the cost of
// each place where a glyph can come from, before a font becomes the font
// of the system.
//
// **Start**: `start("vector_glyphs")` in the console, or the bar of the
// desktop. Its row of `start_grant_sets` has no grant.
//
// **What a reader sees**: one block for each candidate and one for Spleen
// 8x16. The log has:
//
// - "vector_glyphs: one glyph from its outline, ...": the time of one glyph
//   at the scales 1, 2 and 3, from the private glyph cache of the process,
//   and from Spleen; each time is the least of 50 short batches, so that a
//   batch that the host stopped does not count;
// - one line for each candidate: the time to open its font file;
// - "vector_glyphs: ok, 6 candidates beside Spleen 8x16".
//
// **What it does not prove**: the times are measures of this host, not
// bounds.
package vector_glyphs

import "modus:contract/value_kinds"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:system"
import "modus:text_rendering"
import "modus:vector_font"

// Its own memory: 1023 pages, with no glyph of a candidate kept: each is
// drawn band by band at each draw. And the glyph memory of its two
// copies of the text rendering, its own, which draws the measure of one
// glyph of the system and the candidates, and the one of the drawing
// module, which draws its labels: each reserves its memory at its first
// glyph, 2 x 354 pages (display.TEXT_MEMORY_PAGES) = 708 pages.
// And the picture of its window, which it draws by hand at its logical
// size: 1008 x 704 pixels of 4 bytes, 693 pages
// (interface.hand_picture_pages). 1023 + 708 + 693 = 2424.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 2424, processes = 1, threads = 1, window_width = WIDTH, window_height = HEIGHT}

// The picture of the window, in its logical pixels (interface.Hand_Picture).
hand_picture: interface.Hand_Picture

WIDTH :: 1008
HEIGHT :: 704

Candidate :: struct {
	name:  string,
	bytes: []u8,
}

// The subsets that `modustool vector_fonts` writes, with their licenses
// beside them in resources/fonts.
candidates := [?]Candidate {
	{"Paper Mono (default)", #load("../../../../resources/fonts/paper_mono.ttf")},
	{"JetBrains Mono", #load("../../../../resources/fonts/jetbrains_mono.ttf")},
	{"DejaVu Sans Mono", #load("../../../../resources/fonts/dejavu_sans_mono.ttf")},
	{"IBM Mono (Plex)", #load("../../../../resources/fonts/ibm_mono.ttf")},
	{"Fira Mono", #load("../../../../resources/fonts/fira_mono.ttf")},
	{"Commit Mono", #load("../../../../resources/fonts/commit_mono.ttf")},
	{"Iosevka", #load("../../../../resources/fonts/iosevka.ttf")},
}

SAMPLE :: "compositor  12.4 ms  2 418 pages {fill} [rings] gi Rb 0O 1lI"
ENLARGED_WORD :: "Rag{0}%"
ENLARGED :: 4

render_memory: vector_font.Render_Memory
open_times: [len(candidates)]u64
// The font set of the candidate that draws now: the candidate as the font
// of the cells (with_font), and the memory of one outline for its open.
candidate_set: text_rendering.Font_Set
candidate_outline: text_rendering.Outline_Memory

window_memory: interface.Window_Memory(256, 8192)

// with_font opens the font file of one candidate as the font of the cells
// of candidate_set, which candidate_text draws from.
with_font :: proc "contextless" (index: int) -> (ok: bool) {
	outline := text_rendering.outline_of(&candidate_outline)
	start := system.nanoseconds()
	problem := text_rendering.font_file_open(&candidate_set, .Paper_Mono, candidates[index].bytes, &outline)
	if problem != .None {
		system.log_fact(.Info, Font_Refused{font = font_field(candidates[index].name), font_problem = value_kinds.text_field(vector_font.font_problem_names[problem], FONT_PROBLEM_FIELD_BYTES)})
		return false
	}
	open_times[index] = system.nanoseconds() - start
	return true
}

// candidate_text draws a text of ASCII in the face of the cells of the
// candidate, one cell of 8 x 16 pixels times the scale for each character,
// in the order of the stripes of the setting. A character that the
// candidate lacks draws the replacement glyph.
candidate_text :: proc "contextless" (canvas: graphics.Canvas, x, y: int, text: string, color: graphics.Color, scale: int) {
	size := text_rendering.size_of_scale(scale)
	for index in 0 ..< len(text) {
		at := x + index * graphics.CELL_WIDTH * scale
		if !graphics.character_of_set(&candidate_set, .Cells, canvas, at, y, rune(text[index]), color, size) {
			graphics.character_replacement(canvas, at, y, color, scale)
		}
	}
}

// enlarged draws a word at scale 1 into a small canvas, then each pixel as a
// square: the coverage of each stripe shows. candidate: in the face of the
// candidate; else Spleen.
enlarged :: proc "contextless" (canvas: graphics.Canvas, x, y: int, candidate: bool) {
	small: [8 * len(ENLARGED_WORD) * 16]graphics.Color
	view := graphics.Canvas{pixels = raw_data(small[:]), width = 8 * len(ENLARGED_WORD), height = 16, stride = 8 * len(ENLARGED_WORD)}
	graphics.clear(view, graphics.colors.card_bottom)
	if candidate {
		candidate_text(view, 0, 0, ENLARGED_WORD, graphics.colors.text, 1)
	} else {
		word := ENLARGED_WORD
		for index in 0 ..< len(word) {
			graphics.character_spleen(view, index * graphics.CELL_WIDTH, 0, rune(word[index]), graphics.colors.text)
		}
	}
	for row in 0 ..< 16 {
		for column in 0 ..< view.width {
			graphics.fill(canvas, x + column * ENLARGED, y + row * ENLARGED, ENLARGED, ENLARGED, small[row * view.width + column])
		}
	}
}

ROW_HEIGHT :: 40
LIST_TOP :: 48
ENLARGED_TOP :: LIST_TOP + (len(candidates) + 1) * ROW_HEIGHT + 16

// draw draws the whole window: the frame with the interface package, then
// the lines of each candidate over it.
draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_start(&window_memory)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	content := interface.card(&frame, {8, 8, WIDTH - 16, HEIGHT - 16}, "THE FONT OF THE SYSTEM", "resources/fonts: seven candidates, ASCII subsets, glyf outlines", graphics.colors.machine)
	interface.draw_text(frame.table, content.x, content.y, "the same line in each font, at scale 1 (8 x 16 pixels), then a word enlarged 4 times", graphics.colors.dim)
	for index in 0 ..= len(candidates) {
		y := content.y + LIST_TOP - 24 + index * ROW_HEIGHT
		name := index == 0 ? "Spleen 8x16 (bitmap)" : candidates[index - 1].name
		interface.draw_text(frame.table, content.x, y, name, graphics.colors.dim)
		if index > 0 {
			builder: interface.Text_Builder
			interface.text_put(&builder, "opened in ")
			interface.text_put_number(&builder, open_times[index - 1] / 1000)
			interface.text_put(&builder, " us")
			interface.draw_text_right(frame.table, content.x + content.width, y, interface.text_of(&builder), graphics.colors.dim)
		}
	}
	// The lines below are drawn by hand over the frame, in the same
	// picture of the surface, before the present.
	if !interface.window_frame_end_into_picture(&window_memory.drawing, &frame, window, &hand_picture) {
		return
	}

	canvas := hand_picture.canvas
	system_state := graphics.text_state
	for index in 0 ..= len(candidates) {
		y := content.y + LIST_TOP - 8 + index * ROW_HEIGHT
		x := content.x + 8
		place := content.x + (index % 4) * 240
		top := content.y + ENLARGED_TOP + (index / 4) * (16 * ENLARGED + 16)
		if index == 0 {
			// Spleen 8x16, whatever the setting of the font.
			graphics.text_choice_set(.Spleen, system_state.order)
			graphics.text(canvas, x, y, SAMPLE, graphics.colors.text)
			graphics.text_scaled(canvas, x + 560, y - 16, "12 345", graphics.colors.process, 2)
			graphics.text_state = system_state
			enlarged(canvas, place, top, false)
			continue
		}
		if !with_font(index - 1) {
			continue
		}
		candidate_text(canvas, x, y, SAMPLE, graphics.colors.text, 1)
		candidate_text(canvas, x + 560, y - 16, "12 345", graphics.colors.process, 2)
		enlarged(canvas, place, top, true)
	}
	interface.hand_picture_show(&hand_picture, window)
}

// The entry of vector_glyphs: it measures the three sources of a glyph,
// draws the candidates, writes the measures, then draws again after each
// event for ever.
//
// With no window it stops with `Failed`. The measures run before the
// first picture, on a scratch canvas that is not the window. The font
// files of the candidates are opened during the first `draw`.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "vector_glyphs")
	if !ok || interface.hand_picture_open(&hand_picture, &window) != .Ok {
		system.stop(.Failed)
	}

	// The measures, before the window: one glyph from its outline, in fixed
	// point, at each scale; one glyph of the system from the private glyph
	// cache of this process, whose glyph memory comes first, so that no
	// glyph of the measure is drawn band by band; one glyph of Spleen. The
	// scratch canvas is not the window.
	_ = display.text_memory_reserve()
	scratch: [48 * 48]graphics.Color
	scratch_canvas := graphics.Canvas{pixels = raw_data(scratch[:]), width = 48, height = 48, stride = 48}
	font, problem := vector_font.font_open(candidates[0].bytes)
	measures: vector_font.Font_Measures
	if problem == .None {
		measures, problem = vector_font.font_measures(&font, &render_memory)
	}
	// Each measure is the least time of BATCHES short batches: a batch that
	// the host stops in its middle does not count (a loaded host stops the
	// processors of the machine).
	BATCHES :: 50
	outline_times: [3]u64 = max(u64)
	pixels: [vector_font.CELL_WIDTH_LIMIT * vector_font.CELL_HEIGHT_LIMIT]u32
	if problem == .None {
		for scale in 1 ..= 3 {
			style := vector_font.glyph_style_of(measures, 8 * scale, 16 * scale, true)
			for _ in 0 ..< BATCHES / 5 {
				start := system.nanoseconds()
				for character in u8(33) ..= 126 {
					_ = vector_font.glyph_render(&font, measures, style, rune(character), &render_memory, pixels[:])
				}
				outline_times[scale - 1] = min(outline_times[scale - 1], (system.nanoseconds() - start) / 94)
			}
		}
	}
	BATCH :: 64
	sample := "Rag{0}%e"
	least_of_batches :: proc "contextless" (canvas: graphics.Canvas, sample: string) -> u64 {
		least := max(u64)
		for _ in 0 ..< BATCHES {
			start := system.nanoseconds()
			for index in 0 ..< BATCH {
				graphics.character(canvas, 0, 0, rune(sample[index % len(sample)]), graphics.colors.text)
			}
			least = min(least, (system.nanoseconds() - start) / BATCH)
		}
		return least
	}
	cache_time, spleen_time: u64
	if graphics.text_vector_drawn() {
		cache_time = least_of_batches(scratch_canvas, sample)
	}
	saved := graphics.text_state
	graphics.text_choice_set(.Spleen, saved.order)
	spleen_time = least_of_batches(scratch_canvas, sample)
	graphics.text_state = saved
	system.log_fact(.Info, Glyph_Measured{scale_one = outline_times[0], scale_two = outline_times[1], scale_three = outline_times[2], private_cache = cache_time, spleen = spleen_time})

	draw(&window)
	for open_time, index in open_times {
		system.log_fact(.Info, Font_Opened{open_time = value_kinds.Time_In_Microseconds(open_time / 1000), font = font_field(candidates[index].name)})
	}
	system.log_fact(.Info, Candidates_Ready{candidates = u64(len(candidates))})
	for {
		display.wait(&window)
		if interface.window_events(&window_memory.drawing, &window) {
			draw(&window)
		}
	}
}
