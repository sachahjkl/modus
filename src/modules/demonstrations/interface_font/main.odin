// The interface font (docs/FONTS.md, section 12): B612 Regular and Bold,
// placed by src/library/support/text_rendering and drawn by graphics.text_proportional.
// It shows a paragraph, three pairs with and without their adjustment, one
// word at the three positions of a pixel, enlarged, the digits in columns,
// three lines of characters past the Latin-1 Supplement (Greek letters of
// B612, box-drawing characters of Paper Mono, the second font of the
// fallback chain: src/md/features/glyphs_on_demand.md), and the time of
// one line.
//
// The process draws each glyph from the font outlines, a resource of the
// boot image that the root service maps read-only at its fixed range, into
// its private glyph cache. The labels of the window are the text of the
// system.
//
// **What it is for.** It shows the [interface font](term:interface-font)
// as the system draws it: [text shaping](term:text-shaping) with the
// [pair adjustments](term:pair-adjustment) of the font, glyphs at a
// [subpixel position](term:subpixel-position), drawn by the process into
// its [private glyph cache](term:private-glyph-cache), and the
// [fallback chain](term:fallback-chain). A reader compares a pair with and
// without its adjustment, and one word at three positions of a pixel.
//
// **What a reader sees.** Start it from the start menu, or with
// `start("interface_font")` in the console. The log gets the time of
// shaping and of drawing one line, then `interface_font: ok, B612 Regular
// and Bold, <count> and <count> pairs, ...`. After its first frame it
// writes `interface_font: each Greek letter of B612 is drawn by this
// process: <n> letters: as it must`, n the count of the Greek letters of
// B612, or `not each Greek letter of B612 is drawn: ...`; then `interface_font: the
// box-drawing characters come from paper_mono, the second font of the
// chain of the interface: <n> characters: as it must`; then
// `interface_font: <n> characters that no font of the chain has draw the
// replacement glyph: as it must`. A line that names a fault starts with
// `interface_font: the fallback chain of the interface is wrong: `. With
// no font outlines that hold B612, it writes `interface_font: the boot
// image gives no font outlines with the interface font`.
//
// **Its grants**: none. The root service maps the font outlines into each
// process that it starts.
package interface_font

import "modus:contract/text_encoding"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"
import "modus:support/text_rendering"

WIDTH :: 800
HEIGHT :: 720

// The glyph memory of its two copies of the text rendering: its own, which
// draws the lines of B612 and the Greek letters by hand, and the one of
// the drawing module, which draws its labels. Each reserves its memory at
// its first glyph. 2 x 354 pages (display.TEXT_MEMORY_PAGES).
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 708, window_width = WIDTH, window_height = HEIGHT}

// The faces of the interface font that this process opened.
interface_faces: display.Interface_Font
// The spacing of the regular weight at scale 1 and at scale 3, the bold
// weight at scale 1, and the regular weight at scale 3 with no pair.
regular_spacing, regular_spacing_large, bold_spacing, no_pair_spacing_large: text_rendering.Spacing

// The most characters of one line of this window.
LINE_LIMIT :: 96

PARAGRAPH := [?]string {
	"B612 was drawn for the screens of a cockpit: small text, read at a glance.",
	"Each character has its own advance, and pairs such as To, LT and Ty come closer.",
	"The interface takes it for titles, labels, buttons, menus and the bar.",
}
BOLD_LINE :: "Settings   Palette   Notes   Console   Monitor"
PAIRS :: "To  LT  Ty"
ENLARGED_WORD :: "Rag To"
ENLARGED :: 4
ENLARGED_COLUMNS :: 48 // The columns of the small canvas that are enlarged: the word and its margins.
// The places of the enlarged word in a pixel, in 1/64: 0, a third, two thirds.
ENLARGED_FRACTIONS := [3]i64{0, 21, 43}
NUMBERS := [?]string{"7", "42", "1 024", "65 536", "4 294 967 296", "100 000"}
// Characters past the Latin-1 Supplement: the capitals and the small
// letters of the Greek script of the fallback chains that B612 has, each one, made
// from the font file at the start, then a line with some of them and
// box-drawing characters, which B612 lacks and Paper Mono, the second font
// of the chain of the interface, has. A letter that B612 lacks is in no
// line of letters.
GREEK_SMALL_FIRST :: 0x03B1 // The first small letter of the Greek alphabet.
// The Greek letters that the character map of B612 1.008 has: the 49 of
// the script, less the capital pi (U+03A0) and the small rho (U+03C1).
B612_GREEK_LETTER_COUNT :: 47
GREEK_SENTENCE :: "Δt = 16 ms   λ = 532 nm   θ = 45°   σ, μ, π = 3.14159   ┌─┬─┐ ▒▓█"
greek_capitals, greek_small: [LINE_LIMIT]u8
GREEK: [3]string
// The box-drawing characters of GREEK_SENTENCE: each one from Paper Mono.
BOX_CHARACTERS := [?]rune{0x250C, 0x2500, 0x252C, 0x2510, 0x2592, 0x2593, 0x2588}
// Characters that no font of the chain of the interface has: the capital
// pi and the small rho that B612 lacks, and a Cyrillic letter.
MISSING_CHARACTERS := [?]rune{0x03A0, 0x03C1, 0x0416}

fallback_told: bool // The lines of the characters of the fallback chain are on the log.

// One line of B612 drawn into a canvas of its own: the enlarged word, and
// the measure of the time of one line.
SMALL_WIDTH :: 96
small_pixels: [SMALL_WIDTH * 16]graphics.Color
MEASURE_WIDTH :: 720
measure_pixels: [MEASURE_WIDTH * 16]graphics.Color
shaping_time, drawing_time: u64

window_memory: interface.Window_Memory(128, 4096)

// line_draw places a text and draws it, its origin at the whole pixel x and
// the top of its line at y; it gives the width in 1/64 of a pixel.
line_draw :: proc "contextless" (canvas: graphics.Canvas, place: i64, y: int, text: string, spacing: ^text_rendering.Spacing, scale: int, color: graphics.Color) -> (width: i64) {
	placed: [LINE_LIMIT]text_rendering.Placed_Glyph
	count := min(len(text), LINE_LIMIT)
	_, width, _ = text_rendering.shape(spacing, transmute([]u8)(text[:count]), placed[:count])
	graphics.text_proportional(canvas, place, y, placed[:count], spacing.face, scale, color)
	return width
}

// greek_letter_of_b612 says if a character of the Greek script of the
// fallback chains is a letter that B612 draws.
greek_letter_of_b612 :: proc "contextless" (character: rune) -> bool {
	return text_rendering.font_of(.Interface, character) == .B612
}

// greek_lines_make writes the line of the capitals and the line of the
// small letters that B612 has, and fills GREEK. The outlines are open:
// display.open opened them.
greek_lines_make :: proc "contextless" () {
	capitals, small := 0, 0
	row := text_rendering.scripts[.Greek]
	for range in row.ranges[:min(row.range_count, text_rendering.RANGE_LIMIT)] {
		for character in range.first ..= range.last {
			if !greek_letter_of_b612(character) {
				continue
			}
			if character < GREEK_SMALL_FIRST {
				capitals += text_encoding.character_encode(character, greek_capitals[capitals:])
			} else {
				small += text_encoding.character_encode(character, greek_small[small:])
			}
		}
	}
	GREEK = {string(greek_capitals[:capitals]), string(greek_small[:small]), GREEK_SENTENCE}
}

// fallback_lines_tell writes, once, what the frame drew from the fallback
// chain of the interface past the Latin-1 Supplement: each Greek letter of
// the subset of B612, each box-drawing character from Paper Mono, and the
// replacement glyph for the characters that no font of the chain has. The
// process draws each glyph as its frame drew it, from its own private
// glyph cache.
fallback_lines_tell :: proc "contextless" () {
	FAULT :: "interface_font: the fallback chain of the interface is wrong: "
	if fallback_told {
		return
	}
	fallback_told = true
	face := interface_faces.regular
	// The glyphs below come from the private glyph cache of this process,
	// whose glyph memory the entry reserved.
	if !display.text_memory_reserve() {
		system.log(.Warning, FAULT, "this process has no glyph memory: each glyph is drawn band by band")
		return
	}
	drawn, missing: u64
	row := text_rendering.scripts[.Greek]
	for range in row.ranges[:min(row.range_count, text_rendering.RANGE_LIMIT)] {
		for character in range.first ..= range.last {
			if !greek_letter_of_b612(character) {
				continue
			}
			entry, _, source := text_rendering.glyph(face, character, text_rendering.size_of_scale(1), 0)
			switch source {
			case .Private_Cache, .Not_Kept:
				drawn += entry.row_count > 0 ? 1 : 0
			case .Missing, .Banded:
				// The memory is given above, and a Greek letter at a line
				// of 16 pixels is far below the largest block: Banded is a
				// glyph that this window does not draw from its cache.
				missing += 1
			}
		}
	}
	if drawn == B612_GREEK_LETTER_COUNT && missing == 0 {
		system.log(.Info, "interface_font: each Greek letter of B612 is drawn by this process: ", drawn, " letters: as it must")
	} else {
		system.log(.Warning, "interface_font: not each Greek letter of B612 is drawn: ", drawn, " of ", u64(B612_GREEK_LETTER_COUNT), ", ", missing, " with no glyph")
	}
	for character in BOX_CHARACTERS {
		entry, _, source := text_rendering.glyph(face, character, text_rendering.size_of_scale(1), 0)
		font := text_rendering.font_of(face, character)
		if font != .Paper_Mono || source != .Private_Cache || entry.row_count == 0 {
			system.log(.Warning, FAULT, "the character ", u64(character), " comes from the font ", text_rendering.outline_font_name(font), ", with ", u64(entry.row_count), " rows of ink")
			return
		}
	}
	system.log(.Info, "interface_font: the box-drawing characters come from paper_mono, the second font of the chain of the interface: ", u64(len(BOX_CHARACTERS)), " characters: as it must")
	for character in MISSING_CHARACTERS {
		_, _, source := text_rendering.glyph(face, character, text_rendering.size_of_scale(1), 0)
		if text_rendering.has(face, character) || source != .Missing {
			system.log(.Warning, FAULT, "the character ", u64(character), " has a glyph, and no font of the chain has it")
			return
		}
		// Its advance is the advance of the replacement glyph: the shaper
		// gives it no fallback glyph.
		if _, found := text_rendering.advance(face, character, text_rendering.size_of_scale(1)); found {
			system.log(.Warning, FAULT, "the character ", u64(character), " has an advance of a font")
			return
		}
	}
	system.log(.Info, "interface_font: ", u64(len(MISSING_CHARACTERS)), " characters that no font of the chain has draw the replacement glyph: as it must")
}

// line_width gives the width of a text in 1/64 of a pixel.
line_width :: proc "contextless" (text: string, spacing: ^text_rendering.Spacing) -> i64 {
	width, _ := text_rendering.text_width(spacing, transmute([]u8)(text[:min(len(text), LINE_LIMIT)]))
	return width
}

// The rows of the window, from the top of the content of its card.
PARAGRAPH_TOP :: 24
PAIRS_TOP :: 152
ENLARGED_TOP :: 256
DIGITS_TOP :: 392
GREEK_TOP :: 552
TIME_TOP :: 616

draw :: proc "contextless" (window: ^display.Window) {
	interface.draw_whole_window_next(&window_memory.drawing)
	frame := interface.window_frame_start(&window_memory)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	content := interface.card(&frame, {8, 8, WIDTH - 16, HEIGHT - 16}, "THE INTERFACE FONT", "B612 Regular and Bold: proportional, with its pairs, at three positions in a pixel", graphics.colors.machine)
	labels := [?]struct {
		top:  int,
		text: string,
	} {
		{0, "a paragraph in B612 Regular, a line in B612 Bold, at scale 1"},
		{PAIRS_TOP - 24, "three pairs at scale 3: with the adjustment of the font, then without"},
		{ENLARGED_TOP - 24, "one word at 0, 1/3 and 2/3 of a pixel, enlarged 4 times"},
		{DIGITS_TOP - 24, "digits in columns: each digit has the same advance, so a column aligns"},
		{GREEK_TOP - 24, "the fallback chain: Greek of B612, box drawing of Paper Mono, the next font of its chain"},
	}
	for label in labels {
		interface.draw_text(frame.table, content.x, content.y + label.top, label.text, graphics.colors.dim)
	}
	// The line of the measures is wider than the card: it has the lines
	// that it needs (docs/INTERFACE.md, "The text in a box"), and the card
	// has room for three under TIME_TOP.
	timing: [192]u8
	interface.draw_text_wrapped(frame.table, content.x, content.y + TIME_TOP, content.width, system.format(timing[:], "one line of ", u64(len(PARAGRAPH[1])), " characters: shaping ", shaping_time, " ns, drawing ", drawing_time, " ns, its glyphs in the private glyph cache of this process"), graphics.colors.dim)
	// The lines below are drawn by hand over the frame, in the same
	// picture of the surface, before the present.
	if !interface.window_frame_end_without_present(&window_memory.drawing, &frame, window) {
		return
	}

	canvas := window.canvas
	x := i64(content.x) * 64
	// The paragraph and the bold line.
	for line, index in PARAGRAPH {
		line_draw(canvas, x, content.y + PARAGRAPH_TOP + index * 20, line, &regular_spacing, 1, graphics.colors.text)
	}
	line_draw(canvas, x, content.y + PARAGRAPH_TOP + len(PARAGRAPH) * 20 + 8, BOLD_LINE, &bold_spacing, 1, graphics.colors.text)
	// The pairs at scale 3, with and without their adjustment.
	line_draw(canvas, x, content.y + PAIRS_TOP, PAIRS, &regular_spacing_large, 3, graphics.colors.text)
	line_draw(canvas, x + 360 * 64, content.y + PAIRS_TOP, PAIRS, &no_pair_spacing_large, 3, graphics.colors.dim)
	// One word at the three positions, each pixel enlarged.
	small := graphics.Canvas{pixels = raw_data(small_pixels[:]), width = SMALL_WIDTH, height = 16, stride = SMALL_WIDTH}
	for fraction, index in ENLARGED_FRACTIONS {
		graphics.clear(small, graphics.colors.card_bottom)
		line_draw(small, 2 * 64 + fraction, 0, ENLARGED_WORD, &regular_spacing, 1, graphics.colors.text)
		left := content.x + index * (ENLARGED_COLUMNS * ENLARGED + 24)
		for row in 0 ..< 16 {
			for column in 0 ..< ENLARGED_COLUMNS {
				graphics.fill(canvas, left + column * ENLARGED, content.y + ENLARGED_TOP + row * ENLARGED, ENLARGED, ENLARGED, small_pixels[row * SMALL_WIDTH + column])
			}
		}
	}
	// The digits: each number at the right of its column, in each weight.
	column_right := i64(content.x + 200) * 64
	bold_right := i64(content.x + 440) * 64
	for number, index in NUMBERS {
		y := content.y + DIGITS_TOP + index * 20
		line_draw(canvas, column_right - line_width(number, &regular_spacing), y, number, &regular_spacing, 1, graphics.colors.text)
		line_draw(canvas, bold_right - line_width(number, &bold_spacing), y, number, &bold_spacing, 1, graphics.colors.process)
	}
	// The characters of the fallback chain: each one from its font of the
	// fallback chain, or the replacement glyph; the frame never waits.
	for line, index in GREEK {
		line_draw(canvas, x, content.y + GREEK_TOP + index * 20, line, &regular_spacing, 1, graphics.colors.text)
	}
	display.present(window)
	fallback_lines_tell()
}

// measure gives the time of one line: the first draw, which draws each of
// its glyphs into the private glyph cache, and the least time in batches
// after it, so that a batch that the host stops in its middle does not
// count: the shaping, then the drawing, into a canvas that is not the
// window.
measure :: proc "contextless" () {
	BATCHES :: 50
	canvas := graphics.Canvas{pixels = raw_data(measure_pixels[:]), width = MEASURE_WIDTH, height = 16, stride = MEASURE_WIDTH}
	text := transmute([]u8)(PARAGRAPH[1])
	placed: [LINE_LIMIT]text_rendering.Placed_Glyph
	shaping_time, drawing_time = max(u64), max(u64)
	for batch in 0 ..< BATCHES {
		graphics.clear(canvas, graphics.colors.card_bottom)
		start := system.nanoseconds()
		count, _, _ := text_rendering.shape(&regular_spacing, text, placed[:])
		shaped := system.nanoseconds()
		graphics.text_proportional(canvas, 0, 0, placed[:count], interface_faces.regular, 1, graphics.colors.text)
		drawn := system.nanoseconds()
		shaping_time = min(shaping_time, shaped - start)
		if batch == 0 {
			first_drawing_time = drawn - shaped
		} else {
			drawing_time = min(drawing_time, drawn - shaped)
		}
	}
}

// The time of the first draw of the line of measure: each of its glyphs
// drawn from its outline.
first_drawing_time: u64

// entry opens the window, finds the faces of the interface font, reserves
// the glyph memory, measures one line, writes the lines on the log, then
// draws the window at each event until the process is stopped. With no
// window, it stops with the code 1.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "interface_font")
	if !ok {
		system.stop(1)
	}
	font_ok: bool
	interface_faces, font_ok = display.interface_font_open(ctx)
	if !font_ok {
		system.log(.Info, "interface_font: the boot image gives no font outlines with the interface font")
		system.stop(1)
	}
	// The glyphs of this copy come from its private glyph cache: its glyph
	// memory before the measure, so that the measure draws no glyph band
	// by band.
	if !display.text_memory_reserve() {
		system.log(.Warning, "interface_font: this process has no glyph memory: each glyph is drawn band by band")
	}
	// The places from the font files, at the text sizes of the scales 1
	// and 3; display.interface_font_open gave the faces only with both
	// open.
	spacing_ok: [3]bool
	regular_spacing, spacing_ok[0] = text_rendering.spacing_of(.Interface, text_rendering.size_of_scale(1))
	regular_spacing_large, spacing_ok[1] = text_rendering.spacing_of(.Interface, text_rendering.size_of_scale(3))
	bold_spacing, spacing_ok[2] = text_rendering.spacing_of(.Interface_Bold, text_rendering.size_of_scale(1))
	if !spacing_ok[0] || !spacing_ok[1] || !spacing_ok[2] {
		system.stop(1)
	}
	no_pair_spacing_large = regular_spacing_large
	no_pair_spacing_large.without_pairs = true
	greek_lines_make()
	measure()
	system.log(.Info, "interface_font: one line of ", u64(len(PARAGRAPH[1])), " characters in B612 at scale 1 (the least of 50 batches): shaping ", shaping_time, " ns, drawing ", drawing_time, " ns; its first draw, each glyph from its outline: ", first_drawing_time, " ns")
	draw(&window)
	system.log(.Info, "interface_font: ok, B612 Regular and Bold, ", u64(text_rendering.state.fonts[.B612].pairs.count), " and ", u64(text_rendering.state.fonts[.B612_Bold].pairs.count), " pairs")
	for {
		// The input of the window: each event gives a frame.
		list: system.Wait
		display.wait_events(&list, &window)
		system.wait_end(&list)
		changed := interface.window_events(&window_memory.drawing, &window)
		if changed {
			draw(&window)
		}
	}
}
