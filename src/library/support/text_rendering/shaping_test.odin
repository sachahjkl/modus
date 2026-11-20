#+build !freestanding
package text_rendering

import "core:testing"
import "modus:contract/font_characters"
import "modus:contract/text_encoding"
import "modus:support/vector_font"

@(private = "file")
b612_regular := #load("../../../../resources/fonts/b612.ttf")

// test_spacing opens the four fonts of the repository in the state of the
// package and gives the spacing of the interface face at the size of a
// line of 16 pixels. The caller frees the words of the resource, which the
// open fonts read.
@(private = "file")
test_spacing :: proc(t: ^testing.T) -> (spacing: Spacing, memory: []u64) {
	fonts := repository_fonts()
	missing: Outline_Fonts
	missing, memory = outlines_open(t, fonts[:])
	testing.expect_value(t, missing, Outline_Fonts{})
	ok: bool
	spacing, ok = spacing_of(.Interface, TEXT_SIZE_OF_SCALE_ONE)
	testing.expect(t, ok)
	return spacing, memory
}

// advance_at gives the advance of a character of the interface face at
// the size of the spacing of the tests.
@(private = "file")
advance_at :: proc(character: rune) -> i32 {
	value, _ := advance(.Interface, character, TEXT_SIZE_OF_SCALE_ONE)
	return value
}

// The width of a text is the sum of the advances of its placed glyphs, and
// the x of each glyph is the sum of the advances before it.
@(test)
the_width_is_the_sum_of_the_placed_glyphs :: proc(t: ^testing.T) {
	test_state_take()
	state = {}
	spacing, memory := test_spacing(t)
	defer delete(memory)
	testing.expect_value(t, spacing.size, TEXT_SIZE_OF_SCALE_ONE)
	text := "To Live: AVATAR, Wave 1234 - the quick brown fox jumps over the lazy dog."
	placed: [128]Placed_Glyph
	count, width, ok := shape(&spacing, transmute([]u8)text, placed[:])
	testing.expect(t, ok)
	testing.expect_value(t, count, len(text))
	sum: i64
	for glyph_placed, index in placed[:count] {
		testing.expect_value(t, i64(glyph_placed.x), sum)
		testing.expect_value(t, glyph_placed.cluster, u32(index)) // One byte for each character of ASCII.
		sum += i64(glyph_placed.advance)
	}
	testing.expect_value(t, width, sum)
	measured, measured_ok := text_width(&spacing, transmute([]u8)text)
	testing.expect(t, measured_ok && measured == sum)
}

// The pair adjustment is that of the font file: "To" is -100 units, -43 in
// 1/64 of a pixel at scale 1 (one unit is 1/150 of a pixel); "AV" has no
// pair in B612, so its advance is the advance of "A" alone (555). The rule
// of the sum: the advance and the adjustment are rounded each on its own,
// and the shaper adds the two integers: "T" before "o" is 512 - 43 = 469.
// A spacing with no pair places "T" at its advance alone.
@(test)
a_pair_changes_the_advance_by_the_value_of_the_file :: proc(t: ^testing.T) {
	test_state_take()
	state = {}
	spacing, memory := test_spacing(t)
	defer delete(memory)
	placed: [2]Placed_Glyph
	shape(&spacing, transmute([]u8)string("To"), placed[:])
	testing.expect_value(t, placed[0].advance, advance_at('T') - 43)
	testing.expect_value(t, advance_at('T'), 512) // 1200 units.
	testing.expect_value(t, placed[0].advance, 469)
	testing.expect_value(t, placed[1].x, placed[0].advance)
	shape(&spacing, transmute([]u8)string("AV"), placed[:])
	testing.expect_value(t, placed[0].advance, advance_at('A'))
	testing.expect_value(t, placed[0].advance, 555) // 1300 units.
	// The last glyph of a text has no pair after it.
	shape(&spacing, transmute([]u8)string("T"), placed[:1])
	testing.expect_value(t, placed[0].advance, 512)
	without := spacing
	without.without_pairs = true
	shape(&without, transmute([]u8)string("To"), placed[:])
	testing.expect_value(t, placed[0].advance, 512)
}

// grid_length gives a length of the font in 1/64 of a pixel at a scale of
// the grid, by the arithmetic of the grid and not by that of a text size:
// units * 8 * scale * 64 / units_per_cell, rounded to the nearest integer,
// a half toward plus infinity. It is the arithmetic that drew the advances
// and the pairs of the glyph caches that left the system.
@(private = "file")
grid_length :: proc(units, scale, units_per_cell: int) -> i32 {
	return i32(vector_font.divide_rounded(i64(units) * i64(8 * scale * SUBPIXEL), i64(units_per_cell)))
}

// The measure from the font files is the measure of the grid of the
// scales: at the sizes of the scales 1, 2 and 3, each advance of the 192
// characters and each pair of two of them, in B612 and B612 Bold, is the
// length that the arithmetic of the grid gives from the units of the font
// file (grid_length), the numbers of the glyph caches that left the
// system. So no place of a text moves. A pair that the file lacks is 0.
@(test)
the_measure_of_the_font_file_is_the_measure_of_the_grid :: proc(t: ^testing.T) {
	test_state_take()
	state = {}
	_, memory := test_spacing(t)
	defer delete(memory)
	b612_bold := #load("../../../../resources/fonts/b612_bold.ttf")
	Weight :: struct {
		face:  Face,
		bytes: []u8,
		name:  string,
	}
	weights := [2]Weight{{.Interface, b612_regular, "b612"}, {.Interface_Bold, b612_bold, "b612_bold"}}
	render := new(vector_font.Render_Memory)
	defer free(render)
	for weight in weights {
		file, problem := vector_font.font_open(weight.bytes)
		testing.expect_value(t, problem, vector_font.Font_Problem.None)
		own, stated: vector_font.Font_Measures
		own, problem = vector_font.font_measures(&file, render)
		testing.expect_value(t, problem, vector_font.Font_Problem.None)
		stated, problem = vector_font.proportional_measures(&file, own)
		testing.expect_value(t, problem, vector_font.Font_Problem.None)
		testing.expect_value(t, stated.advance, 1200) // The units of one cell: docs/FONTS.md, section 12.2.
		table, table_problem := vector_font.pair_table_open(&file)
		testing.expect_value(t, table_problem, vector_font.Font_Problem.None)
		for scale in 1 ..= 3 {
			spacing, ok := spacing_of(weight.face, size_of_scale(scale))
			testing.expect(t, ok)
			advances: [CHARACTER_COUNT]i32
			for index in 0 ..< CHARACTER_COUNT {
				character, _ := font_characters.character_of_index(index)
				advances[index] = grid_length(vector_font.character_advance(&file, character), scale, stated.advance)
				value, found := advance(weight.face, character, size_of_scale(scale))
				testing.expectf(t, found && value == advances[index], "%s at scale %d: %c has the advance %d, the grid %d", weight.name, scale, character, value, advances[index])
			}
			pair_count := 0
			for left in 0 ..< CHARACTER_COUNT {
				for right in 0 ..< CHARACTER_COUNT {
					left_character, _ := font_characters.character_of_index(left)
					right_character, _ := font_characters.character_of_index(right)
					text: [2 * text_encoding.CHARACTER_BYTES_LIMIT]u8
					length := text_encoding.character_encode(left_character, text[:])
					length += text_encoding.character_encode(right_character, text[length:])
					placed: [2]Placed_Glyph
					shape(&spacing, text[:length], placed[:])
					adjustment := placed[0].advance - advances[left]
					units := vector_font.character_pair_adjustment(&file, &table, left_character, right_character)
					expected := grid_length(units, scale, stated.advance)
					pair_count += int(units != 0)
					testing.expectf(t, adjustment == expected, "%s at scale %d: the pair %d %d is %d, the grid %d", weight.name, scale, left, right, adjustment, expected)
				}
			}
			testing.expectf(t, pair_count > 0, "%s: the font file has pairs", weight.name)
		}
	}
}

// An empty text has no glyph and no width. A control, an invalid sequence
// and a character outside the cache are each one replacement glyph, with
// the advance of "0" and no pair.
@(test)
an_empty_text_and_a_character_outside_the_cache :: proc(t: ^testing.T) {
	test_state_take()
	state = {}
	spacing, memory := test_spacing(t)
	defer delete(memory)
	count, width, ok := shape(&spacing, nil, nil)
	testing.expect(t, ok && count == 0 && width == 0)
	outside := [3]u8{'\n', 200, 127}
	placed: [4]Placed_Glyph
	count, width, ok = shape(&spacing, outside[:], placed[:])
	testing.expect(t, ok && count == 3)
	zero := advance_at('0')
	for glyph_placed, index in placed[:3] {
		testing.expect_value(t, glyph_placed.glyph, REPLACEMENT_GLYPH)
		testing.expect_value(t, glyph_placed.advance, zero)
		testing.expect_value(t, glyph_placed.cluster, u32(index))
	}
	testing.expect_value(t, width, 3 * i64(zero))
	// The first character past the Latin-1 Supplement (Ā, U+0100) is
	// outside the cache: two bytes and one replacement glyph, so the glyph
	// after it starts at byte 3.
	OUTSIDE_THE_CACHE :: rune(font_characters.LATIN_LAST + 1)
	_, in_cache := font_characters.character_index(OUTSIDE_THE_CACHE)
	testing.expect(t, !in_cache)
	text: [2 + text_encoding.CHARACTER_BYTES_LIMIT]u8
	text[0] = 'T'
	length := text_encoding.character_encode(OUTSIDE_THE_CACHE, text[1:])
	text[1 + length] = 'T'
	count, width, ok = shape(&spacing, text[:2 + length], placed[:])
	testing.expect(t, ok && count == 3)
	testing.expect_value(t, placed[1].glyph, REPLACEMENT_GLYPH)
	testing.expect_value(t, placed[2].glyph, u32('T' - font_characters.ASCII_FIRST))
	testing.expect_value(t, placed[2].cluster, u32(1 + length))
	testing.expect_value(t, placed[0].advance, advance_at('T')) // No pair with the replacement glyph.
	testing.expect_value(t, width, 2 * i64(advance_at('T')) + i64(zero))
	// "é" is in the cache: two bytes and its own glyph.
	e_acute, _ := font_characters.character_index('é')
	count, _, ok = shape(&spacing, transmute([]u8)string("TéT"), placed[:])
	testing.expect(t, ok && count == 3)
	testing.expect_value(t, placed[1].glyph, u32(e_acute))
	testing.expect_value(t, placed[1].cluster, u32(1))
	testing.expect_value(t, placed[2].cluster, u32(3))
	// "€", an added character, is in the cache: three bytes.
	count, _, ok = shape(&spacing, transmute([]u8)string("5 €"), placed[:])
	testing.expect(t, ok && count == 3)
	testing.expect_value(t, placed[2].glyph, u32(font_characters.ADDED_FIRST_INDEX))
	testing.expect_value(t, placed[2].cluster, u32(2))
	testing.expect_value(t, placed[2].advance, advance_at(font_characters.EURO_SIGN))
	// A text over the limit writes nothing.
	long := make([]u8, TEXT_LIMIT + 1)
	defer delete(long)
	placed[0] = {}
	_, _, ok = shape(&spacing, long, placed[:])
	testing.expect(t, !ok)
	testing.expect_value(t, placed[0], Placed_Glyph{})
}

// With a face, a character past the glyph cache that a font of the chain
// has is a fallback glyph with the advance of its font file at the size of
// the spacing and no pair; the advance is the same at each measure,
// whatever the private glyph cache holds. A character that no font has
// (ā, Ж), an invalid sequence, and a code point past Unicode are the
// replacement glyph, with the advance of "0". A spacing with no face
// places the replacement glyph with no advance, last.
@(test)
a_fallback_glyph_has_the_advance_of_its_font :: proc(t: ^testing.T) {
	test_state_take()
	defer state = {}
	spacing, memory := test_spacing(t)
	defer delete(memory)
	testing.expect_value(t, spacing.face, Face.Interface)
	OMEGA :: rune(0x03A9)
	text := "AΩB\xffāЖ─"
	zero := advance_at('0')
	placed: [8]Placed_Glyph
	count, width, shaped := shape(&spacing, transmute([]u8)text, placed[:])
	testing.expect(t, shaped && count == 7)
	for index in ([?]int{3, 4, 5}) {
		testing.expectf(t, placed[index].glyph == REPLACEMENT_GLYPH && placed[index].advance == zero, "glyph %v: the replacement glyph with the advance of 0", index)
	}
	omega_advance, found := advance(.Interface, OMEGA, TEXT_SIZE_OF_SCALE_ONE)
	testing.expect(t, found && omega_advance > 0)
	testing.expect_value(t, placed[1].glyph, FALLBACK_GLYPH_FIRST + u32(OMEGA))
	testing.expect_value(t, placed[1].advance, omega_advance) // No pair with a fallback glyph.
	testing.expect_value(t, placed[2].x, placed[1].x + omega_advance)
	testing.expect_value(t, placed[0].advance, advance_at('A'))
	testing.expect_value(t, placed[6].glyph, FALLBACK_GLYPH_FIRST + 0x2500) // From Paper Mono, the second font.
	// Draws in the private glyph cache change no advance.
	for character in ([?]rune{OMEGA, 0x2500}) {
		_, _, _ = glyph(.Interface, character, TEXT_SIZE_OF_SCALE_ONE, 0)
	}
	_, again, _ := shape(&spacing, transmute([]u8)text, placed[:])
	testing.expect_value(t, again, width)
	// A code point past Unicode, encoded in four bytes, is an invalid
	// sequence.
	past := [4]u8{0xF4, 0x90, 0x80, 0x80}
	_, _, _ = shape(&spacing, past[:], placed[:1])
	testing.expect_value(t, placed[0].glyph, REPLACEMENT_GLYPH)
	// At the size of scale 3, the advance of that size.
	spacing.size = size_of_scale(3)
	_, _, _ = shape(&spacing, transmute([]u8)string("Ω"), placed[:1])
	large, _ := advance(.Interface, OMEGA, size_of_scale(3))
	testing.expect_value(t, placed[0].advance, large)
	// A spacing with no face: the replacement glyph, with no advance.
	spacing.face = .None
	_, _, _ = shape(&spacing, transmute([]u8)string("Ω"), placed[:1])
	testing.expect_value(t, placed[0].glyph, REPLACEMENT_GLYPH)
	testing.expect_value(t, placed[0].advance, i32(0))
}

// A spacing of a face is refused for the face None, for a size at each
// edge out of its range (0, 1, one under the least, one past the largest,
// the largest int, a negative size), and before the fonts are open; the
// least and the largest size pass, last. A grid of cells keeps its width
// in its bound: 0 and a negative width are one pixel, a width past the
// bound is the bound.
@(test)
a_spacing_is_refused_out_of_its_range :: proc(t: ^testing.T) {
	test_state_take()
	defer state = {}
	state = {}
	_, closed := spacing_of(.Interface, TEXT_SIZE_OF_SCALE_ONE)
	testing.expect(t, !closed)
	_, memory := test_spacing(t)
	defer delete(memory)
	_, none := spacing_of(.None, TEXT_SIZE_OF_SCALE_ONE)
	testing.expect(t, !none)
	for size in ([?]int{0, 1, TEXT_SIZE_MINIMUM - 1, TEXT_SIZE_LIMIT + 1, max(int), -1, min(int)}) {
		_, ok := spacing_of(.Interface, size)
		testing.expectf(t, !ok, "the size %v is refused", size)
	}
	for size in ([?]int{TEXT_SIZE_MINIMUM, TEXT_SIZE_LIMIT}) {
		_, ok := spacing_of(.Interface, size)
		testing.expectf(t, ok, "the size %v passes", size)
	}
	for width in ([?]int{0, -1, min(int)}) {
		testing.expect_value(t, cell_spacing(width).cell_advance, i32(SUBPIXEL))
	}
	testing.expect_value(t, cell_spacing(max(int)).cell_advance, i32(CELL_ADVANCE_LIMIT))
	testing.expect_value(t, cell_spacing(CELL_ADVANCE_LIMIT / SUBPIXEL + 1).cell_advance, i32(CELL_ADVANCE_LIMIT))
	testing.expect_value(t, cell_spacing(8).cell_advance, i32(8 * SUBPIXEL))
}

// The bounds at any size: at the least and at the largest size, each
// advance of the 192 characters is from 0 to one line, each pair within
// half a line, and the longest text of the widest pair of letters keeps
// each x the sum of the advances before it, in an i32.
@(test)
the_bounds_of_the_shaper_at_each_size :: proc(t: ^testing.T) {
	test_state_take()
	defer state = {}
	_, memory := test_spacing(t)
	defer delete(memory)
	long := make([]u8, TEXT_LIMIT)
	defer delete(long)
	for &value, index in long {
		value = index % 2 == 0 ? 'W' : 'T'
	}
	placed := make([]Placed_Glyph, TEXT_LIMIT)
	defer delete(placed)
	for size in ([?]int{TEXT_SIZE_MINIMUM, TEXT_SIZE_OF_SCALE_ONE, TEXT_SIZE_LIMIT}) {
		for face in ([?]Face{.Interface, .Interface_Bold, .Cells, .Cells_Bold}) {
			spacing, ok := spacing_of(face, size)
			testing.expect(t, ok)
			for index in 0 ..< CHARACTER_COUNT {
				character, _ := font_characters.character_of_index(index)
				value, _ := advance(face, character, size)
				testing.expectf(t, value >= 0 && i64(value) <= advance_limit_of_size(size), "%v at %v: %c has %v", face, size, character, value)
			}
			count, width, shaped := shape(&spacing, long, placed)
			testing.expect(t, shaped && count == TEXT_LIMIT)
			sum: i64
			for glyph_placed in placed {
				testing.expect_value(t, i64(glyph_placed.x), sum)
				testing.expect(t, i64(glyph_placed.advance) >= -pair_limit_of_size(size) && i64(glyph_placed.advance) <= advance_limit_of_size(size) + pair_limit_of_size(size))
				sum += i64(glyph_placed.advance)
			}
			testing.expect(t, width == sum && sum < 1 << 31)
		}
	}
}

// 10 000 texts in one call give the widths of 10 000 calls of one text.
@(test)
ten_thousand_texts_in_one_call :: proc(t: ^testing.T) {
	test_state_take()
	state = {}
	spacing, memory := test_spacing(t)
	defer delete(memory)
	COUNT :: 10_000
	words := [?]string{"File", "Edit", "View", "To", "AVATAR", "Wave", "Settings", "", "Lily", "0123456789", "Ty", "LT"}
	bytes := make([dynamic]u8)
	defer delete(bytes)
	ranges := make([]Text_Range, COUNT)
	defer delete(ranges)
	for index in 0 ..< COUNT {
		word := words[index % len(words)]
		ranges[index] = {start = u32(len(bytes)), count = u32(len(word) + index % 3)}
		append(&bytes, ..transmute([]u8)word)
		for _ in 0 ..< index % 3 {
			append(&bytes, 'a' + u8(index % 26))
		}
	}
	problem, measured, _ := measure_ranges(&spacing, bytes[:], ranges)
	testing.expect_value(t, problem, Range_Problem.None)
	testing.expect_value(t, measured, COUNT)
	for range in ranges {
		width, _ := text_width(&spacing, bytes[range.start:][:range.count])
		testing.expect_value(t, range.width, width)
	}
	// A range past the text stops the measure at its index.
	ranges[7] = {start = u32(len(bytes)) - 1, count = 2}
	stopped, index, end := measure_ranges(&spacing, bytes[:], ranges)
	testing.expect(t, stopped == .Past_The_Text && index == 7 && end == u64(len(bytes)) + 1)
}

// A range of one byte past the limit of a text, inside its bytes, stops the
// measure as too long and keeps its width; a range at the limit is
// measured.
@(test)
a_range_past_the_limit_of_a_text :: proc(t: ^testing.T) {
	test_state_take()
	state = {}
	spacing, memory := test_spacing(t)
	defer delete(memory)
	bytes := make([]u8, TEXT_LIMIT + 1)
	defer delete(bytes)
	for &value in bytes {
		value = 'a'
	}
	ranges := [3]Text_Range{{start = 0, count = 1}, {start = 0, count = TEXT_LIMIT + 1, width = 7}, {start = 0, count = 1, width = 7}}
	stopped, index, end := measure_ranges(&spacing, bytes, ranges[:])
	testing.expect(t, stopped == .Too_Long && index == 1 && end == TEXT_LIMIT + 1)
	testing.expect(t, ranges[0].width > 0 && ranges[1].width == 7 && ranges[2].width == 7)
	at_limit := [1]Text_Range{{start = 1, count = TEXT_LIMIT}}
	problem, measured, _ := measure_ranges(&spacing, bytes, at_limit[:])
	width, _ := text_width(&spacing, bytes[1:])
	testing.expect(t, problem == .None && measured == 1 && at_limit[0].width == width)
}

// The fit of a text: a room below 0, of 0, and below the first advance
// gives no byte; a text past TEXT_LIMIT gives no byte; a room of the width
// of a start gives that start, and a fit never ends inside a character of
// several bytes. A room of the whole width gives the whole text, last.
@(test)
the_fit_of_a_text_is_whole_characters :: proc(t: ^testing.T) {
	test_state_take()
	state = {}
	spacing := cell_spacing(8)
	text := transmute([]u8)string("aé€b")
	cell := i64(8 * SUBPIXEL)
	for room in ([?]i64{min(i64), -1, 0, cell - 1}) {
		testing.expectf(t, text_fit(&spacing, text, room) == 0, "room %v: no byte", room)
	}
	long := make([]u8, TEXT_LIMIT + 1)
	defer delete(long)
	testing.expect_value(t, text_fit(&spacing, long, max(i64)), 0)
	Fit :: struct {
		room:  i64,
		bytes: int,
	}
	for fit in ([?]Fit{{cell, 1}, {2 * cell - 1, 1}, {2 * cell, 3}, {3 * cell - 1, 3}, {3 * cell, 6}, {4 * cell, len(text)}, {max(i64), len(text)}}) {
		testing.expectf(t, text_fit(&spacing, text, fit.room) == fit.bytes, "room %v: %v bytes, expected %v", fit.room, text_fit(&spacing, text, fit.room), fit.bytes)
	}
}

// The breaks of the lines: an empty text has one empty line; a box
// narrower than a character still gives a line of one whole character, of
// several bytes too; a line ends at the last space that fits, with no
// space at its end and none at the start of the rest; a word wider than
// the box breaks after its last `/`; with no separator, at its last
// character that fits. The lines, joined, are the text with no space at a
// break, last.
@(test)
the_breaks_of_the_lines :: proc(t: ^testing.T) {
	test_state_take()
	state = {}
	spacing := cell_spacing(8)
	cell := i64(8 * SUBPIXEL)
	end, rest := line_break(&spacing, nil, cell)
	testing.expect(t, end == 0 && rest == 0)
	euro := transmute([]u8)string("€€")
	end, rest = line_break(&spacing, euro, 0)
	testing.expect(t, end == 3 && rest == 3) // One whole character of three bytes.
	end, rest = line_break(&spacing, euro, -1)
	testing.expect(t, end == 3 && rest == 3)
	Case :: struct {
		text:          string,
		room:          i64,
		line, after:   string,
	}
	cases := [?]Case {
		{"one two three", 9 * cell, "one two", "three"},
		{"one two three", 8 * cell, "one two", "three"},
		{"one two three", 3 * cell, "one", "two three"},
		{"one   two", 5 * cell, "one", "two"},
		{"see src/library/support", 12 * cell, "see src/", "library/support"},
		{"abcdefgh", 3 * cell, "abc", "defgh"},
		{"one two", 100 * cell, "one two", ""},
	}
	for each in cases {
		text := transmute([]u8)each.text
		end, rest = line_break(&spacing, text, each.room)
		testing.expectf(t, string(text[:end]) == each.line && string(text[rest:]) == each.after, "%q in %v cells: %q and %q, expected %q and %q", each.text, each.room / cell, string(text[:end]), string(text[rest:]), each.line, each.after)
	}
}
