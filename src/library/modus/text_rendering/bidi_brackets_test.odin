#+build !freestanding
package text_rendering

import "core:strings"
import "core:testing"

// The levels of the glyphs of a line, by the byte of each.
@(private = "file")
levels_of :: proc(t: ^testing.T, text: string) -> (levels: map[u32]u8) {
	placed: [64]Placed_Glyph
	count, _ := shape_text(t, .Interface, text, placed[:])
	line_levels: [BIDI_GLYPH_LIMIT]u8
	scratch: [BIDI_GLYPH_LIMIT]u16
	bidi_levels(transmute([]u8)text, placed[:count], line_levels[:count], scratch[:count])
	levels = make(map[u32]u8, context.temp_allocator)
	for glyph, index in placed[:count] {
		levels[glyph.cluster] = line_levels[index]
	}
	return levels
}

// N0 (UAX #9): a pair of brackets with only right-to-left text inside, in
// a line of left to right, after a right-to-left letter, is right to left:
// the closing bracket too, where N1 alone makes it left to right. A
// bracket that pairs with nothing, or with a bracket of another kind,
// stays to N1. U+2329 pairs with U+3009, its canonical other form.
@(test)
a_pair_of_brackets_takes_the_direction_inside_it :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	// x space alef ( bet ) a: the bytes 0, 1, 2, 4, 5, 7, 8.
	levels := levels_of(t, "x א(ב)a")
	testing.expectf(t, levels[4] == 1 && levels[7] == 1, "the pair takes R: ( at %d, ) at %d", levels[4], levels[7])
	testing.expect_value(t, levels[8], u8(0))
	// A closing bracket of another kind: no pair, N1 decides.
	levels = levels_of(t, "x א(ב]a")
	testing.expectf(t, levels[4] == 1 && levels[7] == 0, "no pair: ( at %d, ] at %d", levels[4], levels[7])
	// A pair with left-to-right text inside, in the same line: L.
	levels = levels_of(t, "x א(b)a")
	testing.expectf(t, levels[4] == 0 && levels[6] == 0, "L inside: ( at %d, ) at %d", levels[4], levels[6])
	// U+2329 and U+3009 pair: 〈 is 3 bytes, ב 2.
	levels = levels_of(t, "x א\u2329ב\u3009a")
	testing.expectf(t, levels[4] == 1 && levels[9] == 1, "the canonical pair takes R: %d, %d", levels[4], levels[9])
	// A pair nested in a pair: the outer one first.
	levels = levels_of(t, "x א(ב[ג])a")
	testing.expectf(t, levels[4] == 1 && levels[7] == 1 && levels[10] == 1 && levels[11] == 1, "nested pairs: %v", levels)
}

// L1: a paragraph separator (U+2029) takes the level of the paragraph,
// and so does the white space before it, as at the end of the line; the
// white space between two letters of right to left before none keeps the
// level of N1. A text of the system holds no tab and no other control
// (src/md/data/text_encoding.md): a tab is an invalid sequence, so U+2029
// is the one separator of L1 that a text holds.
@(test)
a_separator_and_the_space_before_it_take_the_paragraph_level :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	// a space alef space U+2029 bet space c: bytes 0, 1, 2, 4, 5, 8, 10, 11.
	levels := levels_of(t, "a א \u2029ב c")
	testing.expectf(t, levels[4] == 0 && levels[5] == 0, "the space and the separator: %d, %d", levels[4], levels[5])
	testing.expect_value(t, levels[2], u8(1))
	testing.expect_value(t, levels[8], u8(1))
	// A tab is an invalid sequence: a neutral, which N1 resolves.
	levels = levels_of(t, "a א \tב c")
	testing.expect_value(t, levels[5], u8(1))
	levels = levels_of(t, "a א ב c")
	testing.expect_value(t, levels[4], u8(1))
	// White space at the end of the line.
	levels = levels_of(t, "א  ")
	testing.expectf(t, levels[2] == 1 && levels[3] == 1, "the end of a line of right to left: %v", levels)
}

// The bounds of N0: 63 openings nested in a line of left to right after a
// letter of right to left pair with their closings, so the closing of the
// outer pair takes R; 64 openings fill the stack, the search stops there as
// BD16 says, no pair is found, and N1 gives that closing L. Pairs one
// after the other keep the order of the line: 63, 64, and 169, the most
// that a line of BIDI_GLYPH_LIMIT glyphs holds with a letter in each. The
// table of the pairs holds each pair that a line can have: 255 and 256
// pairs, 256 the most in BIDI_GLYPH_LIMIT glyphs, are kept.
@(test)
the_bounds_of_the_bracket_pairs :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	placed := make([]Placed_Glyph, BIDI_GLYPH_LIMIT, context.temp_allocator)
	levels_at :: proc(t: ^testing.T, text: string, placed: []Placed_Glyph) -> (levels: [BIDI_GLYPH_LIMIT]u8, count: int, rtl: bool) {
		count, _ = shape_text(t, .Interface, text, placed)
		scratch: [BIDI_GLYPH_LIMIT]u16
		_, rtl = bidi_levels(transmute([]u8)text, placed[:count], levels[:count], scratch[:count])
		return
	}
	for depth in ([2]int{BIDI_BRACKET_STACK_LIMIT, BIDI_BRACKET_STACK_LIMIT + 1}) {
		text := strings.concatenate({"x א", strings.repeat("(", depth, context.temp_allocator), "ב", strings.repeat(")", depth, context.temp_allocator), "a"}, context.temp_allocator)
		levels, count, _ := levels_at(t, text, placed)
		// The last closing bracket is the glyph before a.
		closing := levels[count - 2]
		paired := depth <= BIDI_BRACKET_STACK_LIMIT
		testing.expectf(t, closing == (paired ? 1 : 0), "%d openings: the last closing at the level %d", depth, closing)
	}
	for pairs in ([3]int{63, 64, (BIDI_GLYPH_LIMIT - 4) / 3}) {
		text := strings.concatenate({"x א", strings.repeat("(ב)", pairs, context.temp_allocator), "a"}, context.temp_allocator)
		levels, count, rtl := levels_at(t, text, placed)
		testing.expectf(t, count <= BIDI_GLYPH_LIMIT && rtl && levels[count - 2] == 1, "%d pairs: the last closing at %d", pairs, levels[count - 2])
	}
	for pairs in ([2]int{BIDI_BRACKET_PAIR_LIMIT - 1, BIDI_BRACKET_PAIR_LIMIT}) {
		text := strings.repeat("()", pairs, context.temp_allocator)
		count := 2 * pairs
		classes := make([]Bidi_Class, count, context.temp_allocator)
		sequence := make([]u16, count, context.temp_allocator)
		brackets := make([]Placed_Glyph, count, context.temp_allocator)
		for index in 0 ..< count {
			classes[index] = .ON
			sequence[index] = u16(index)
			brackets[index] = {cluster = u32(index), placement = .Base}
		}
		testing.expectf(t, count <= BIDI_GLYPH_LIMIT && brackets_resolve(classes, sequence, .R, .R, transmute([]u8)text, brackets), "%d pairs are kept", pairs)
	}
}
