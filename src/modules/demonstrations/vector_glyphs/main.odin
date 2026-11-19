// The choice of the vector font (docs/FONTS.md, "The font file"): the same
// lines of the system in each candidate font and in Spleen 8x16, one word of
// each enlarged, and the measures of the text path.
//
// The module carries the six subsets of resources/fonts (ASCII only), and
// its process builds a glyph cache of each one in its own memory: the time of that
// build is the measure of a cache made by each process at run time (the
// first of the three places of docs/FONTS.md, "Where it lives: three places
// weighed"). It draws the lines of each candidate from that cache.
// The text of the window itself is the text of the system: the glyphs that
// the process draws from the font outlines into its private glyph cache,
// or Spleen, as the setting says.
//
// **What it is for.** It is the record of a choice: a reader sees the same
// lines in each candidate font at the sizes of the system, and the cost of
// each place where a glyph can come from, before a font becomes the font
// of the system.
//
// **Start**: `start("vector_glyphs")` in the console, or the bar of the
// desktop. Its row of `process_roles` has no grant.
//
// **What a reader sees**: one block for each candidate and one for Spleen
// 8x16. The log has:
//
// - "vector_glyphs: one glyph from its outline, ...": the time of one glyph
//   at the scales 1, 2 and 3, from the private glyph cache of the process,
//   and from Spleen; each time is the least of 50 short batches, so that a
//   batch that the host stopped does not count;
// - one line for each candidate: the time to build its cache of 95
//   characters at 3 scales, and its bytes;
// - "vector_glyphs: ok, 6 candidates beside Spleen 8x16".
//
// **What it does not prove**: the times are measures of this host, not
// bounds.
package vector_glyphs

import "modus:contract/glyph_cache"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"
import "modus:support/vector_font"

// The glyph caches that it builds: 1362 pages. And the glyph memory of its
// two copies of the text rendering, its own, which draws the measure of
// one glyph of the system, and the one of the drawing module, which draws
// its labels: each reserves its memory at its first glyph, 2 x 354 pages
// (display.TEXT_MEMORY_PAGES) = 708 pages. 1362 + 708 = 2070.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 2070, processes = 1, threads = 1, window_width = WIDTH, window_height = HEIGHT}

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

// The glyph cache of one candidate, built here; 8-byte words.
cache_memory: [vector_font.GLYPH_CACHE_LIMIT / 8 + 1]u64
render_memory: vector_font.Render_Memory
build_times: [len(candidates)]u64
cache_sizes: [len(candidates)]int
// The cache of the candidate that draws now, validated (with_font).
candidate_cache: glyph_cache.Cache

window_memory: interface.Window_Memory(256, 8192)

// with_font builds the cache of one candidate and makes it the cache that
// candidate_text draws from.
with_font :: proc "contextless" (index: int) -> (ok: bool) {
	font, problem := vector_font.font_open(candidates[index].bytes)
	out := ([^]u8)(raw_data(cache_memory[:]))[:vector_font.GLYPH_CACHE_LIMIT]
	start := system.nanoseconds()
	size := 0
	if problem == .None {
		size, problem = vector_font.glyph_cache_build(&font, candidates[index].bytes, candidates[index].name, true, &render_memory, out)
	}
	if problem != .None {
		system.log(.Info, "vector_glyphs: the font ", candidates[index].name, " is refused: ", vector_font.font_problem_names[problem])
		return false
	}
	build_times[index] = system.nanoseconds() - start
	cache_sizes[index] = size
	refused: glyph_cache.Problem
	candidate_cache, refused = glyph_cache.validate(out[:size])
	if refused.kind != .None {
		system.log(.Info, "vector_glyphs: the cache of ", candidates[index].name, " is refused: ", glyph_cache.problem_sentences[refused.kind])
		return false
	}
	return true
}

// candidate_text draws a text of ASCII from the cache of the candidate, one
// cell of 8 x 16 pixels times the scale for each character, in the order
// of the stripes of the setting.
candidate_text :: proc "contextless" (canvas: graphics.Canvas, x, y: int, text: string, color: graphics.Color, scale: int) {
	state := &graphics.text_state
	for index in 0 ..< len(text) {
		graphics.character_vector_with(&candidate_cache, &state.square_root, &state.blend_tables, state.order, canvas, x + index * graphics.CELL_WIDTH * scale, y, rune(text[index]), color, scale)
	}
}

// enlarged draws a word at scale 1 into a small canvas, then each pixel as a
// square: the coverage of each stripe shows. candidate: from the cache of
// the candidate; else Spleen.
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
			interface.text_put(&builder, "cache built in ")
			interface.text_put_number(&builder, build_times[index - 1] / 1000)
			interface.text_put(&builder, " us, ")
			interface.text_put_number(&builder, u64(cache_sizes[index - 1]))
			interface.text_put(&builder, " bytes")
			interface.draw_text_right(frame.table, content.x + content.width, y, interface.text_of(&builder), graphics.colors.dim)
		}
	}
	// The lines below are drawn by hand over the frame, in the same
	// picture of the surface, before the present.
	if !interface.window_frame_end_without_present(&window_memory.drawing, &frame, window) {
		return
	}

	canvas := window.canvas
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
	display.present(window)
}

// The entry of vector_glyphs: it measures the three sources of a glyph,
// draws the candidates, writes the measures, then draws again after each
// event for ever.
//
// With no window it stops with the code 1. The measures run before the
// first picture, on a scratch canvas that is not the window. The caches of
// the candidates are built during the first `draw`.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "vector_glyphs")
	if !ok {
		system.stop(1)
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
	system.log(.Info, "vector_glyphs: one glyph from its outline, in fixed point, with the stripes (the least of batches): scale 1 ", outline_times[0], " ns, scale 2 ", outline_times[1], " ns, scale 3 ", outline_times[2], " ns; from the private glyph cache: ", cache_time, " ns; Spleen 8x16: ", spleen_time, " ns")

	draw(&window)
	for size, index in cache_sizes {
		system.log(.Info, "vector_glyphs: the cache of ", candidates[index].name, ": 95 characters at 3 scales built in ", build_times[index] / 1000, " us, ", u64(size), " bytes")
	}
	system.log(.Info, "vector_glyphs: ok, ", u64(len(candidates)), " candidates beside Spleen 8x16")
	for {
		display.wait(&window)
		if interface.window_events(&window_memory.drawing, &window) {
			draw(&window)
		}
	}
}
