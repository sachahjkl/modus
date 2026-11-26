#+build !freestanding
#+build !modus
package text_rendering

import "core:testing"

// The fast part and the written part (src/md/features/text_rendering.md,
// "Where the written shaping lives"): on a simple text, both give each
// placed glyph the same glyph, place, advance and cluster, and the same
// fit; a text that is not simple is refused by the fast part.

@(private = "file")
FAST_TEXTS := [?]string {
	"",
	"a",
	"Settings",
	"The quick brown fox jumps over the lazy dog. 0123456789",
	"AV To Wa Yo LT ff fi -- ... (a) [b] {c} <d>",
	"été naïve ß ñ ü Å ÆØ œ",
	"Καλημέρα Ωμέγα",
	"Привет мир Жж",
	"→ ≤ ∞ © € – — … “ ”",
	"─│┌┐█░",
	"tab\there",
	"invalid \xFF\xFE bytes \xC3",
	"ệ ạ ǫ",
}

@(private = "file")
NOT_SIMPLE_TEXTS := [?]string {
	"é",
	"שלום",
	"بيت",
	"हिन्दी",
	"กำ",
	"a‍b",
	"a‏b",
	"abc ١٢",
	"中文",
}

// The faces of the tests, each with its own chain.
@(private = "file")
FAST_FACES := [?]Face{.Interface, .Interface_Bold, .Cells, .Cells_Bold}

@(private = "file")
fast_and_written_compare :: proc(t: ^testing.T) -> (simple_count: int) {
	for face in FAST_FACES {
		spacing, ok := spacing_of(face, TEXT_SIZE_OF_SCALE_ONE)
		testing.expect(t, ok)
		for text in FAST_TEXTS {
			bytes := transmute([]u8)text
			fast: [128]Placed_Glyph
			written: [128]Placed_Glyph
			fast_count, fast_width, simple := shape_simple(&spacing, bytes, fast[:], false)
			if !simple {
				continue
			}
			simple_count += 1
			written_count, written_width, _ := shape_written(&spacing, bytes, written[:])
			testing.expectf(t, fast_count == written_count && fast_width == written_width, "%v %q: %d glyphs of width %d by the fast part, %d of width %d by the written part", face, text, fast_count, fast_width, written_count, written_width)
			for index in 0 ..< min(fast_count, written_count, len(fast)) {
				testing.expectf(t, fast[index] == written[index], "%v %q, glyph %d: %v by the fast part, %v by the written part", face, text, index, fast[index], written[index])
			}
			for room in ([6]i64{-1, 0, 1, 64 * 8, 64 * 40, 1 << 30}) {
				fast_fit, _ := text_fit_simple(&spacing, bytes, room, false)
				written_fit := text_fit_written(&spacing, bytes, room)
				testing.expectf(t, fast_fit == written_fit, "%v %q in %d: a fit of %d bytes by the fast part, %d by the written part", face, text, room, fast_fit, written_fit)
			}
		}
		for text in NOT_SIMPLE_TEXTS {
			_, _, simple := shape_simple(&spacing, transmute([]u8)text, nil, false)
			testing.expectf(t, !simple, "%v %q is not simple", face, text)
			_, fit_simple := text_fit_simple(&spacing, transmute([]u8)text, 1 << 30, false)
			testing.expectf(t, !fit_simple, "%v %q is not simple for the fit", face, text)
		}
	}
	return simple_count
}

@(test)
the_fast_part_places_a_simple_text_as_the_written_part :: proc(t: ^testing.T) {
	test_state_take()
	defer test_state_give()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	// The texts of Latin, Greek, Cyrillic, the punctuation, the symbols of
	// Noto Sans and the box are simple in each face: 12 texts in 4 faces.
	testing.expect_value(t, fast_and_written_compare(t), 4 * (len(FAST_TEXTS) - 1) + 4)
}

// With the script font set open, a character whose chain reaches a font of
// the set before a font that has it is not placed by the fast part.
@(test)
the_fast_part_stops_at_a_font_of_the_set :: proc(t: ^testing.T) {
	test_state_take()
	defer test_state_give()
	names := [?]string{"noto_sans_symbols_2", "noto_sans_cjk", "noto_sans_hebrew"}
	words, script_words, _ := script_set_open(t, names[:])
	defer delete(words)
	defer delete(script_words)
	if !font_at(&state.font_set, .Noto_Sans_Symbols_2).opened {
		return
	}
	fast_and_written_compare(t)
	spacing, _ := spacing_of(.Interface, TEXT_SIZE_OF_SCALE_ONE)
	// U+2B1B, a large square, is drawn by Noto Sans Symbols 2 only: its
	// chain reaches that font first.
	_, _, simple := shape_simple(&spacing, transmute([]u8)string("⬛"), nil, false)
	testing.expect(t, !simple, "a character of a font of the set goes to the written part")
	// Each character still draws in the module with no written part: past
	// the font of the set, the box.
	count, _, every := shape_simple(&spacing, transmute([]u8)string("a⬛b"), nil, true)
	testing.expect(t, every && count == 3, "one character at a time places each character")
}

// The characters that take no mark are the classes WS, S and B of the
// table of Unicode, at each code point.
@(test)
the_cluster_breaks_are_the_classes_of_unicode :: proc(t: ^testing.T) {
	for character in rune(0) ..= 0x10FFFF {
		class := bidi_class_of(character)
		breaks := class == .WS || class == .S || class == .B
		if is_cluster_break(character) != breaks {
			testing.expectf(t, false, "U+%04X of the class %v: is_cluster_break gives %v", character, class, !breaks)
		}
	}
	testing.expect(t, !is_cluster_break(-1) && !is_cluster_break(0x110000))
}

// The table of the simple characters holds no character that the written
// part treats apart: no mark, no class of right to left or of an explicit
// direction, no combining class, no joining, no character past U+10FFFF.
@(test)
the_simple_characters_need_no_shaping :: proc(t: ^testing.T) {
	previous_last := rune(-1)
	for range in simple_ranges {
		testing.expectf(t, range.first > previous_last && range.first <= range.last && range.last <= 0x10FFFF, "the range %X to %X is in order", range.first, range.last)
		previous_last = range.last
		for character in range.first ..= range.last {
			class := bidi_class_of(character)
			switch class {
			case .L, .EN, .ES, .ET, .CS, .WS, .ON:
			case .R, .AL, .AN, .NSM, .BN, .B, .S, .LRE, .LRO, .RLE, .RLO, .PDF, .LRI, .RLI, .FSI, .PDI:
				testing.expectf(t, false, "U+%04X is simple, and of the class %v", character, class)
			}
			if is_mark(character) || combining_class_of(character) != 0 || joining_type_of(character) != .None || is_invisible_format(character) {
				testing.expectf(t, false, "U+%04X is simple, and a mark, a combining class, a joining type or a format character", character)
			}
		}
	}
	// The edges: the first and the last character of a range, and the
	// characters around them.
	testing.expect(t, is_simple('a') && is_simple(' ') && !is_simple(0x0301) && !is_simple(0x05D0) && !is_simple(0x200D) && !is_simple(-1) && !is_simple(0x110000))
	for range in simple_ranges {
		testing.expect(t, is_simple(range.first) && is_simple(range.last))
		testing.expectf(t, !is_simple(range.last + 1) || range.last + 1 > 0x10FFFF, "U+%04X past a range", range.last + 1)
	}
}
