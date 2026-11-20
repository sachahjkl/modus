#+build !freestanding
package vector_font

import "core:testing"
import "modus:contract/font_characters"

// The subsets of B612 that "modustool vector_fonts" writes. The values
// below were read by hand in the files of B612 1.008 (the commit of
// flake.nix), with a reader that is not this one.
@(private = "file")
b612_regular := #load("../../../../resources/fonts/b612.ttf")
@(private = "file")
b612_bold := #load("../../../../resources/fonts/b612_bold.ttf")
@(private = "file")
monospace_font := #load("../../../../resources/fonts/jetbrains_mono.ttf")

@(private = "file")
Known_Advance :: struct {
	character: rune,
	advance:   int,
}

@(private = "file")
Known_Pair :: struct {
	left, right: rune,
	adjustment:  int,
}

// Both weights of B612 have the same advances.
@(private = "file")
b612_advances := [?]Known_Advance{{'A', 1300}, {'V', 1300}, {'T', 1200}, {'o', 1200}, {'L', 1100}, {'y', 1100}, {'W', 1900}, {' ', 700}, {'M', 1800}, {'i', 600}, {'1', 1300}, {'.', 600}}

@(test)
the_advances_and_the_pairs_of_b612 :: proc(t: ^testing.T) {
	// "AV" and "VA" have no pair in B612: their adjustment is 0. "Wa" has
	// one in the bold weight only.
	regular_pairs := [?]Known_Pair{{'A', 'V', 0}, {'V', 'A', 0}, {'T', 'o', -100}, {'L', 'T', -100}, {'T', 'y', -100}, {'L', 'V', -150}, {'W', 'a', 0}}
	bold_pairs := [?]Known_Pair{{'A', 'V', 0}, {'T', 'o', -100}, {'L', 'T', -100}, {'L', 'V', -150}, {'W', 'a', -100}}
	Weight :: struct {
		bytes:      []u8,
		pairs:      []Known_Pair,
		pair_count: int,
	}
	weights := [2]Weight{{b612_regular, regular_pairs[:], 232}, {b612_bold, bold_pairs[:], 239}}
	for weight in weights {
		font, problem := font_open(weight.bytes)
		testing.expect_value(t, problem, Font_Problem.None)
		testing.expect_value(t, font.units_per_em, 2000)
		for known in b612_advances {
			testing.expectf(t, character_advance(&font, known.character) == known.advance, "the advance of %c: %v, expected %v", known.character, character_advance(&font, known.character), known.advance)
		}
		table, pair_problem := pair_table_open(&font)
		testing.expect_value(t, pair_problem, Font_Problem.None)
		// The pairs between two characters of ASCII: the glyphs 1 to
		// ASCII_COUNT of a subset (the glyph 0 is .notdef). The pairs of
		// the Latin-1 Supplement come after them in the subset.
		ascii_pairs := 0
		for index in 0 ..< table.count {
			left := read_u16(table.pairs, index * KERN_PAIR_SIZE + KERN_PAIR_LEFT_PLACE) or_else -1
			right := read_u16(table.pairs, index * KERN_PAIR_SIZE + KERN_PAIR_RIGHT_PLACE) or_else -1
			if left >= 1 && left <= font_characters.ASCII_COUNT && right >= 1 && right <= font_characters.ASCII_COUNT {
				ascii_pairs += 1
			}
		}
		testing.expect_value(t, ascii_pairs, weight.pair_count)
		for known in weight.pairs {
			adjustment := character_pair_adjustment(&font, &table, known.left, known.right)
			testing.expectf(t, adjustment == known.adjustment, "the pair %c%c: %v, expected %v", known.left, known.right, adjustment, known.adjustment)
		}
		// Each pair that the table has is found by the search.
		for index in 0 ..< table.count {
			left := read_u16(table.pairs, index * KERN_PAIR_SIZE + KERN_PAIR_LEFT_PLACE) or_else -1
			right := read_u16(table.pairs, index * KERN_PAIR_SIZE + KERN_PAIR_RIGHT_PLACE) or_else -1
			value := read_i16(table.pairs, index * KERN_PAIR_SIZE + KERN_PAIR_ADJUSTMENT_PLACE) or_else 0
			testing.expect(t, value != 0 && pair_adjustment(&table, left, right) == value)
		}
	}
}

// A font with no kern table has no pair: each adjustment is 0.
@(test)
a_font_with_no_pair :: proc(t: ^testing.T) {
	font, problem := font_open(monospace_font)
	testing.expect_value(t, problem, Font_Problem.None)
	table, pair_problem := pair_table_open(&font)
	testing.expect_value(t, pair_problem, Font_Problem.None)
	testing.expect_value(t, table.count, 0)
	testing.expect_value(t, character_pair_adjustment(&font, &table, 'T', 'o'), 0)
}

// A damaged kern table is refused with its problem, and no damage makes a
// fault: the version, the count of subtables, the format, the coverage, a
// count of pairs past the table, a pair twice, a glyph past the glyphs of
// the font, and the table cut at each length.
@(test)
a_damaged_pair_table :: proc(t: ^testing.T) {
	good, problem := font_open(b612_regular)
	testing.expect_value(t, problem, Font_Problem.None)
	testing.expect(t, good.kern.length > KERN_HEADER_SIZE + KERN_SUBTABLE_HEADER_SIZE + 2 * KERN_PAIR_SIZE)
	file := make([]u8, len(b612_regular))
	defer delete(file)
	// Each place comes from the layout of the table, by the names of the
	// reader, and each damaged value from the file itself: the damages hit
	// the same fields whatever glyphs and pairs the subset holds.
	at := good.kern.offset
	subtable := at + KERN_HEADER_SIZE
	first_pair := subtable + KERN_SUBTABLE_HEADER_SIZE
	pair_count := int(read_u16(b612_regular, subtable + KERN_SUBTABLE_PAIR_COUNT_PLACE) or_else 0)
	testing.expect(t, pair_count >= 2 && good.glyph_count <= 0xFFFF)
	// The glyph after the last glyph of the font: the first number that is
	// no glyph.
	past_the_glyphs := [2]u8{u8(good.glyph_count >> 8), u8(good.glyph_count)}
	// More pairs than the table holds: the count that ends one pair past it.
	too_many := (good.kern.length - KERN_HEADER_SIZE - KERN_SUBTABLE_HEADER_SIZE) / KERN_PAIR_SIZE + 1
	testing.expect(t, too_many > pair_count && too_many <= 0xFFFF)
	too_many_pairs := [2]u8{u8(too_many >> 8), u8(too_many)}
	Damage :: struct {
		offset: int,
		bytes:  [2]u8,
		kind:   Font_Problem,
	}
	damages := [?]Damage {
		{at + KERN_VERSION_PLACE, {0x00, 0x01}, .Unknown_Format}, // The version 1 of the kern table of Apple.
		{at + KERN_SUBTABLE_COUNT_PLACE, {0x00, 0x00}, .Unknown_Format}, // No subtable.
		{subtable + KERN_SUBTABLE_VERSION_PLACE, {0x00, 0x01}, .Unknown_Format}, // The version of the subtable.
		{subtable + KERN_SUBTABLE_COVERAGE_PLACE, {0x02, 0x01}, .Unknown_Format}, // Format 2.
		{subtable + KERN_SUBTABLE_COVERAGE_PLACE, {0x00, 0x03}, .Unknown_Format}, // Minimum values.
		{subtable + KERN_SUBTABLE_COVERAGE_PLACE, {0x00, 0x05}, .Unknown_Format}, // Cross-stream.
		{subtable + KERN_SUBTABLE_COVERAGE_PLACE, {0x00, 0x00}, .Unknown_Format}, // Vertical.
		{subtable + KERN_SUBTABLE_PAIR_COUNT_PLACE, too_many_pairs, .Too_Short}, // More pairs than the table holds.
		{first_pair + KERN_PAIR_RIGHT_PLACE, past_the_glyphs, .Unknown_Format}, // A right glyph past the glyphs of the font.
		{first_pair + KERN_PAIR_LEFT_PLACE, {0xFF, 0xFF}, .Unknown_Format}, // A left glyph of 65535: past the glyphs, and it breaks the order.
	}
	for damage in damages {
		copy(file, b612_regular)
		file[damage.offset] = damage.bytes[0]
		file[damage.offset + 1] = damage.bytes[1]
		font, opened := font_open(file)
		testing.expect_value(t, opened, Font_Problem.None)
		_, refused := pair_table_open(&font)
		testing.expectf(t, refused == damage.kind, "a damage at %v of the table: %v, expected %v", damage.offset - at, refused, damage.kind)
	}
	// A pair twice: the second pair copied over the first breaks the order.
	copy(file, b612_regular)
	copy(file[first_pair:][:KERN_PAIR_SIZE], b612_regular[first_pair + KERN_PAIR_SIZE:][:KERN_PAIR_SIZE])
	twice, _ := font_open(file)
	_, refused := pair_table_open(&twice)
	testing.expect_value(t, refused, Font_Problem.Unknown_Format)
	// The table cut at each length: refused, or no table at 0.
	for length in 0 ..< good.kern.length {
		cut := good
		cut.kern.length = length
		table, cut_problem := pair_table_open(&cut)
		if length == 0 {
			testing.expect(t, cut_problem == .None && table.count == 0)
		} else {
			testing.expectf(t, cut_problem == .Too_Short, "the table cut at %v: %v", length, cut_problem)
		}
	}
	// A table that the directory places past the end of the file.
	outside := good
	outside.kern.offset = len(b612_regular) - 2
	_, outside_problem := pair_table_open(&outside)
	testing.expect_value(t, outside_problem, Font_Problem.Too_Short)
}
