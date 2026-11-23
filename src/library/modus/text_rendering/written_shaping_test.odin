#+build !freestanding
package text_rendering

import "core:os"
import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/font_characters"
import "modus:contract/font_outlines"
import "modus:vector_font"

// The tests of the written shaper (src/md/features/written_shaping.md) and
// of the script fonts (src/md/features/script_fonts.md). The script fonts
// come from SCRIPT_FONT_SOURCES: the development shell and the check of
// the flake set it.

@(private)
script_font_names := [?]string{"noto_sans_hebrew", "noto_sans_arabic", "noto_sans_symbols_2", "noto_emoji", "noto_sans_cjk", "noto_sans_thai", "noto_sans_devanagari", "noto_sans_bengali", "noto_sans_gurmukhi", "noto_sans_gujarati", "noto_sans_oriya", "noto_sans_tamil", "noto_sans_telugu", "noto_sans_kannada", "noto_sans_malayalam", "noto_sans_khmer", "noto_sans_myanmar", "noto_serif_tibetan", "noto_sans_balinese", "noto_sans_javanese", "noto_sans_sundanese"}

// script_fonts_read reads the script fonts that names lists.
@(private)
script_fonts_read :: proc(t: ^testing.T, names: []string) -> (fonts: [dynamic]font_outlines.Font_Input) {
	sources := os.get_env("SCRIPT_FONT_SOURCES", context.temp_allocator)
	testing.expect(t, sources != "", "SCRIPT_FONT_SOURCES is set: run the tests in the development shell or in the check of the flake")
	for name in names {
		rest := sources
		prefix := strings.concatenate({name, "="}, context.temp_allocator)
		for item in strings.split_iterator(&rest, ";") {
			if strings.has_prefix(item, prefix) {
				bytes, error := os.read_entire_file(item[len(prefix):], context.allocator)
				if testing.expectf(t, error == nil, "%s can be read", item[len(prefix):]) {
					append(&fonts, font_outlines.Font_Input{name, bytes})
				}
			}
		}
	}
	return fonts
}

// script_set_open opens the fonts of the repository, then a script font set
// of the fonts that names lists. The caller frees the words.
@(private)
script_set_open :: proc(t: ^testing.T, names: []string) -> (words, script_words: []u64, missing: Outline_Fonts) {
	fonts := repository_fonts()
	_, words = outlines_open(t, fonts[:])
	scripts := script_fonts_read(t, names)
	defer {
		for font in scripts {
			delete(font.bytes)
		}
		delete(scripts)
	}
	set: font_outlines.Outlines
	set, script_words = resource_of(t, scripts[:])
	missing = script_fonts_open(&set)
	return words, script_words, missing
}

@(private)
shape_text :: proc(t: ^testing.T, face: Face, text: string, placed: []Placed_Glyph) -> (count: int, width: i64) {
	spacing, ok := spacing_of(face, TEXT_SIZE_OF_SCALE_ONE)
	testing.expect(t, ok)
	shaped: bool
	count, width, shaped = shape(&spacing, transmute([]u8)text, placed)
	testing.expect(t, shaped)
	return count, width
}

@(private = "file")
fallback_glyph :: proc(character: rune) -> u32 {
	if index, found := font_characters.character_index(character); found {
		return u32(index)
	}
	return FALLBACK_GLYPH_FIRST + u32(character)
}

// A letter and its marks draw the composed glyph when a font has it: e
// and U+0301 is é, the glyph and the advance of é; e with U+0323 and
// U+0302, in either order, is ệ (U+1EC7). A mark that does not compose
// (q and U+0301) is a glyph of its own with the advance 0, at the byte of
// the mark. A mark with no base (at the start, after a space) stands on a
// dotted circle. 20 marks on one letter: the 16 of a cluster, then a
// cluster of its own on a dotted circle. An invalid sequence before a mark
// leaves the mark with no base. A fit never splits a letter from its mark.
@(test)
a_mark_composes_with_its_letter :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	placed: [64]Placed_Glyph
	for face in ([?]Face{.Interface, .Cells}) {
		count, width := shape_text(t, face, "e\u0301", placed[:])
		composed, composed_width := shape_text(t, face, "é", placed[32:])
		testing.expectf(t, count == 1 && composed == 1 && placed[0] == placed[32] && width == composed_width, "%v: e and U+0301 is é", face)
		for text in ([?]string{"e\u0302\u0323", "e\u0323\u0302", "ệ"}) {
			count, _ = shape_text(t, face, text, placed[:])
			testing.expectf(t, count == 1 && placed[0].glyph == fallback_glyph(0x1EC7), "%v: %q is ệ: %v glyphs, the glyph %x", face, text, count, placed[0].glyph)
		}
		// A mark of class 0 that stays apart blocks the composition of a
		// mark after it (UAX #15, D115): e, U+034F (a mark of class 0
		// that composes with nothing), U+0323 and U+0301 is e with
		// three marks apart; with no U+034F, e and U+0323 compose to ẹ.
		count, _ = shape_text(t, face, "e\u034F\u0323\u0301", placed[:])
		testing.expectf(t, placed[0].glyph == fallback_glyph('e'), "%v: a mark of class 0 blocks the composition: %v", face, placed[:count])
		count, _ = shape_text(t, face, "e\u0323", placed[:])
		testing.expectf(t, count == 1 && placed[0].glyph == fallback_glyph(0x1EB9), "%v: e and U+0323 is ẹ: %v", face, placed[:count])
		count, width = shape_text(t, face, "q\u0301", placed[:])
		testing.expectf(t, count == 2 && placed[1].glyph == fallback_glyph(0x0301) && placed[1].advance == 0 && placed[1].cluster == 1, "%v: q and a mark apart: %v", face, placed[:count])
		q_width, _ := text_width(&Spacing{face = face, size = TEXT_SIZE_OF_SCALE_ONE}, transmute([]u8)string("q"))
		testing.expect_value(t, width, q_width)
		for text in ([?]string{"\u0301", " \u0301"}) {
			count, _ = shape_text(t, face, text, placed[:])
			last := count - 1
			testing.expectf(t, count >= 2 && placed[last - 1].glyph == fallback_glyph(DOTTED_CIRCLE) && placed[last - 1].advance > 0 && placed[last].glyph == fallback_glyph(0x0301), "%v: %q: a mark on a dotted circle: %v", face, text, placed[:count])
		}
		many := strings.concatenate({"e", strings.repeat("\u0301", 20, context.temp_allocator)}, context.temp_allocator)
		count, _ = shape_text(t, face, many, placed[:])
		testing.expect_value(t, count, 1 + 15 + 1 + 4)
		testing.expect_value(t, placed[0].glyph, fallback_glyph('é'))
		testing.expect_value(t, placed[16].glyph, fallback_glyph(DOTTED_CIRCLE))
		count, _ = shape_text(t, face, "e\xff\u0301", placed[:])
		testing.expectf(t, count == 4 && placed[1].glyph == REPLACEMENT_GLYPH && placed[2].glyph == fallback_glyph(DOTTED_CIRCLE), "%v: an invalid sequence before a mark: %v", face, placed[:count])
		spacing, _ := spacing_of(face, TEXT_SIZE_OF_SCALE_ONE)
		q_room, _ := text_width(&spacing, transmute([]u8)string("q\u0301"))
		testing.expect_value(t, text_fit(&spacing, transmute([]u8)string("q\u0301x"), q_room), 3)
		testing.expect_value(t, text_fit(&spacing, transmute([]u8)string("q\u0301x"), q_room - 1), 0)
	}
	// A grid of cells: a mark takes no cell, a mark with no base one.
	cells := cell_spacing(8)
	width, _ := text_width(&cells, transmute([]u8)string("e\u0301e\u0323\u0302"))
	testing.expect_value(t, width, i64(2 * 8 * SUBPIXEL))
	testing.expect_value(t, cell_count(transmute([]u8)string("e\u0301e\u0323\u0302")), 2)
	testing.expect_value(t, cell_count(transmute([]u8)string("\u0301a")), 2)
}

// The letters of Arabic join with the forms of their font
// (src/md/features/written_shaping.md, "The joining of Arabic"). Noto Sans
// Arabic makes beh, yeh and teh a dotless body and their dots (ccmp), then
// the form of the body (init, medi, fina): in بيت each letter is the form
// of its body, a glyph of the font that differs from its isolated body,
// and one mark of dots, anchored (GPOS) on that body, with the advance 0
// and the byte of its letter. A fatha after beh is anchored too, at its
// own byte. In سلام the lam and the alef are one glyph, the ligature U+FEFC,
// and the meem, for which the font has no isolated form, takes its
// presentation form U+FEE1. Each base of an Arabic word is at the right of
// the base after it in the text; each mark draws from a glyph with ink.
// With no script font, each letter is the replacement glyph, first.
@(test)
arabic_letters_join :: proc(t: ^testing.T) {
	test_budget := vector_font.Layout_Budget{limit = vector_font.LAYOUT_WORK_CAP}
	test_state_take()
	placed: [16]Placed_Glyph
	{
		fonts := repository_fonts()
		_, words := outlines_open(t, fonts[:])
		defer delete(words)
		count, _ := shape_text(t, .Interface, "بيت", placed[:])
		testing.expect(t, count == 3 && placed[0].glyph == REPLACEMENT_GLYPH && placed[2].glyph == REPLACEMENT_GLYPH)
	}
	names := [1]string{"noto_sans_arabic"}
	words, script_words, missing := script_set_open(t, names[:])
	defer delete(words)
	defer delete(script_words)
	testing.expect(t, .Noto_Sans_Arabic not_in missing)
	file := &font_at(&state.font_set, .Noto_Sans_Arabic).file
	frame_begin()
	// The bases and the marks of a word, by their placement.
	Word :: struct {
		bases, anchored: int,
	}
	word_of :: proc(t: ^testing.T, text: string, placed: []Placed_Glyph) -> (word: Word) {
		sum: i64
		last_base_x := i32(max(i32))
		for item in placed {
			sum += i64(item.advance)
			switch item.placement {
			case .Base:
				word.bases += 1
				testing.expectf(t, item.x < last_base_x, "%q: each base is at the left of the base before it: %v", text, placed)
				last_base_x = item.x
			case .Anchored:
				word.anchored += 1
				testing.expect_value(t, item.advance, i32(0))
				font, index, direct := direct_glyph_parts(item.glyph)
				entry: Glyph_Entry
				source: Glyph_Source
				if direct {
					entry, _, source = glyph_by_index(.Interface, font, index, TEXT_SIZE_OF_SCALE_ONE, 0)
				} else {
					entry, _, source = glyph(.Interface, rune(item.glyph - FALLBACK_GLYPH_FIRST), TEXT_SIZE_OF_SCALE_ONE, 0)
				}
				testing.expectf(t, source == .Private_Cache && entry.row_count > 0, "%q: an anchored mark has ink: %v, %v", text, item, source)
			case .Centred:
				testing.expectf(t, false, "%q: a mark that the font places is centred: %v", text, item)
			}
		}
		return word
	}
	count, width := shape_text(t, .Interface, "بيت", placed[:])
	word := word_of(t, "بيت", placed[:count])
	testing.expectf(t, word.bases == 3 && word.anchored == 3, "بيت: %v bases and %v dots: %v", word.bases, word.anchored, placed[:count])
	sum: i64
	for glyph in placed[:count] {
		sum += i64(glyph.advance)
	}
	testing.expect_value(t, width, sum)
	// Each base is the form of its font, not its isolated body; each dot
	// has the byte of its letter.
	Letter :: struct {
		character: rune,
		cluster:   u32,
	}
	letters := [3]Letter{{0x0628, 0}, {0x064A, 2}, {0x062A, 4}}
	place := 0
	for letter in letters {
		plain, _ := vector_font.glyph_of(file, letter.character)
		parts: [vector_font.SEQUENCE_LIMIT]int
		part_count, _ := vector_font.script_substitution(file, ARAB, {'c', 'c', 'm', 'p'}, plain, parts[:], &test_budget)
		testing.expectf(t, part_count == 2, "U+%04X is a body and its dots in its font", int(letter.character))
		for place < count && placed[place].placement != .Base {
			place += 1
		}
		font, index, direct := direct_glyph_parts(placed[place].glyph)
		testing.expectf(t, direct && font == .Noto_Sans_Arabic && index != parts[0] && placed[place].cluster == letter.cluster, "U+%04X: the base %v is a form of its body %v", int(letter.character), placed[place], parts[0])
		testing.expectf(t, place + 1 < count && placed[place + 1].placement == .Anchored && placed[place + 1].cluster == letter.cluster, "U+%04X: its dots follow it", int(letter.character))
		place += 1
	}
	// A format character of no width is Transparent for the joining: an
	// LRM, a zero width space or a word joiner between beh and yeh keeps
	// the forms of the word; a space breaks them.
	bases_of :: proc(placed: []Placed_Glyph) -> (bases: [8]u32, count: int) {
		for glyph in placed {
			if glyph.placement == .Base && glyph.glyph != INVISIBLE_GLYPH && count < len(bases) {
				bases[count] = glyph.glyph
				count += 1
			}
		}
		return
	}
	joined, joined_count := bases_of(placed[:count])
	for format in ([?]string{"\u200E", "\u200B", "\u2060", "\u200E\u200E"}) {
		text := strings.concatenate({"ب", format, "يت"}, context.temp_allocator)
		through, _ := shape_text(t, .Interface, text, placed[:])
		bases, bases_count := bases_of(placed[:through])
		testing.expectf(t, bases_count == joined_count && bases == joined, "%q: the forms through a format character: %v, joined: %v", text, bases[:bases_count], joined[:joined_count])
	}
	apart, _ := shape_text(t, .Interface, "ب يت", placed[:])
	bases, _ := bases_of(placed[:apart])
	testing.expect(t, bases[0] != joined[0], "a space breaks the join")
	testing.expect_value(t, joining_type_of(0x200E), Joining_Type.Transparent)
	testing.expect_value(t, joining_type_of(0x200D), Joining_Type.Join_Causing)
	testing.expect_value(t, joining_type_of(0x200C), Joining_Type.None)
	// A fatha on beh: anchored, at its own byte.
	count, _ = shape_text(t, .Interface, "بَيت", placed[:])
	word = word_of(t, "بَيت", placed[:count])
	testing.expectf(t, word.bases == 3 && word.anchored == 4, "بَيت: %v bases and %v marks: %v", word.bases, word.anchored, placed[:count])
	fatha_found := false
	for glyph in placed[:count] {
		fatha_found ||= glyph.glyph == fallback_glyph(0x064E) && glyph.cluster == 2 && glyph.placement == .Anchored
	}
	testing.expect(t, fatha_found, "the fatha is anchored at its byte")
	// Lam and alef: one glyph; the meem: its presentation form.
	count, _ = shape_text(t, .Interface, "سلام", placed[:])
	word = word_of(t, "سلام", placed[:count])
	testing.expectf(t, word.bases == 3 && placed[count - 2].glyph == fallback_glyph(0xFEFC) && placed[count - 1].glyph == fallback_glyph(0xFEE1), "سلام: %v", placed[:count])
	_, seen_index, seen_direct := direct_glyph_parts(placed[0].glyph)
	seen, _ := vector_font.glyph_of(file, 0x0633)
	testing.expectf(t, seen_direct && seen_index != seen, "the seen is the initial form of its font: %v", placed[0])
	// A letter between two spaces: its isolated body and its dot.
	count, _ = shape_text(t, .Interface, " ب ", placed[:])
	testing.expectf(t, count == 4 && placed[1].placement == .Base && placed[2].placement == .Anchored, "an isolated beh: %v", placed[:count])
}

// A line of mixed direction (UAX #9). In "abc אבג 123", a line of left to
// right, the Hebrew word is reversed and the number keeps its order after
// it: on the screen, a b c, the space, 1 2 3, the space, ג ב א. In
// "שלום (abc)", a line of right to left, the Hebrew word is at the right,
// abc keeps its order, and each parenthesis draws its mirrored form. The
// width is the sum of the advances in each case. A line of more than
// BIDI_GLYPH_LIMIT glyphs keeps the order of the text. A line of left to
// right alone keeps its places, last.
@(test)
a_line_of_mixed_direction :: proc(t: ^testing.T) {
	test_state_take()
	names := [1]string{"noto_sans_hebrew"}
	words, script_words, _ := script_set_open(t, names[:])
	defer delete(words)
	defer delete(script_words)
	placed: [32]Placed_Glyph
	count, width := shape_text(t, .Interface, "abc אבג 123", placed[:])
	testing.expect_value(t, count, 11)
	// The order on the screen, by the index of each glyph in the text.
	screen := [11]int{0, 1, 2, 3, 8, 9, 10, 7, 6, 5, 4}
	for index in 1 ..< len(screen) {
		left, right := placed[screen[index - 1]], placed[screen[index]]
		testing.expectf(t, left.x + left.advance == right.x, "the glyph %v is right after the glyph %v on the screen: %v and %v", screen[index], screen[index - 1], left, right)
	}
	sum: i64
	for glyph_placed in placed[:count] {
		sum += i64(glyph_placed.advance)
	}
	testing.expect_value(t, width, sum)
	count, _ = shape_text(t, .Interface, "שלום (abc)", placed[:])
	testing.expect_value(t, count, 10)
	testing.expect(t, placed[0].x > placed[3].x, "the Hebrew word is right to left")
	testing.expect(t, placed[6].x < placed[7].x && placed[7].x < placed[8].x, "abc keeps its order")
	testing.expect(t, placed[0].x > placed[9].x, "the line starts at the right")
	testing.expectf(t, placed[5].glyph == fallback_glyph(')') && placed[9].glyph == fallback_glyph('('), "each parenthesis is mirrored: %v %v", placed[5], placed[9])
	// Past the bound: the order of the text.
	long := strings.repeat("א", BIDI_GLYPH_LIMIT + 1, context.temp_allocator)
	many := make([]Placed_Glyph, BIDI_GLYPH_LIMIT + 1)
	defer delete(many)
	count, _ = shape_text(t, .Interface, long, many)
	testing.expect_value(t, count, BIDI_GLYPH_LIMIT + 1)
	for index in 1 ..< count {
		testing.expect(t, many[index].x > many[index - 1].x)
	}
	count, _ = shape_text(t, .Interface, "abc def", placed[:])
	for index in 1 ..< count {
		testing.expect_value(t, placed[index].x, placed[index - 1].x + placed[index - 1].advance)
	}
}

// The scripts of the script fonts: with no script font set, Hebrew,
// Arabic, an ideograph, an emoji and the black square have no font and are
// the replacement glyph: the box until the set arrives, no fault. After
// the open of the set, each has a font of the chain of its script and a
// glyph with ink; an ideograph in a face of cells takes two cells. A set
// that lacks the CJK font draws the others and keeps the box for the
// ideograph. The chains of the counted scripts draw their characters.
@(test)
the_scripts_of_the_script_fonts :: proc(t: ^testing.T) {
	test_state_take()
	Case :: struct {
		character: rune,
		font:      Outline_Font,
	}
	cases := [?]Case{{0x05D0, .Noto_Sans_Hebrew}, {0x0628, .Noto_Sans_Arabic}, {0x4E00, .Noto_Sans_CJK}, {0x3042, .Noto_Sans_CJK}, {0xAC00, .Noto_Sans_CJK}, {0x1F600, .Noto_Emoji}, {0x25A0, .Noto_Sans_Symbols_2}, {0x0915, .Noto_Sans_Devanagari}}
	{
		fonts := repository_fonts()
		_, words := outlines_open(t, fonts[:])
		defer delete(words)
		frame_begin()
		for each in cases {
			for face in ([?]Face{.Interface, .Cells}) {
				_, _, source := glyph(face, each.character, TEXT_SIZE_OF_SCALE_ONE, 0)
				testing.expectf(t, font_of(face, each.character) == .None && source == .Missing, "%v: U+%04X with no set: the box", face, int(each.character))
			}
		}
		// A set that lacks the CJK font.
		names := [2]string{"noto_sans_hebrew", "noto_emoji"}
		scripts := script_fonts_read(t, names[:])
		defer {
			for font in scripts {
				delete(font.bytes)
			}
			delete(scripts)
		}
		set, set_words := resource_of(t, scripts[:])
		defer delete(set_words)
		missing := script_fonts_open(&set)
		testing.expect_value(t, missing, Outline_Fonts{.Noto_Sans_Arabic, .Noto_Sans_Symbols_2, .Noto_Sans_CJK, .Noto_Sans_Thai, .Noto_Sans_Devanagari, .Noto_Sans_Bengali, .Noto_Sans_Gurmukhi, .Noto_Sans_Gujarati, .Noto_Sans_Oriya, .Noto_Sans_Tamil, .Noto_Sans_Telugu, .Noto_Sans_Kannada, .Noto_Sans_Malayalam, .Noto_Sans_Khmer, .Noto_Sans_Myanmar, .Noto_Serif_Tibetan, .Noto_Sans_Balinese, .Noto_Sans_Javanese, .Noto_Sans_Sundanese})
		testing.expect_value(t, font_of(.Interface, 0x05D0), Outline_Font.Noto_Sans_Hebrew)
		testing.expect_value(t, font_of(.Interface, 0x4E00), Outline_Font.None)
	}
	words, script_words, missing := script_set_open(t, script_font_names[:])
	defer delete(words)
	defer delete(script_words)
	testing.expect_value(t, missing, Outline_Fonts{})
	frame_begin()
	for each in cases {
		for face in ([?]Face{.Interface, .Interface_Bold, .Cells, .Cells_Bold}) {
			testing.expectf(t, font_of(face, each.character) == each.font, "%v: U+%04X from %v, expected %v", face, int(each.character), font_of(face, each.character), each.font)
			entry, _, source := glyph(face, each.character, TEXT_SIZE_OF_SCALE_ONE, 0)
			testing.expectf(t, source == .Private_Cache && entry.row_count > 0, "%v: U+%04X: %v, %v rows", face, int(each.character), source, entry.row_count)
			value, found := advance(face, each.character, TEXT_SIZE_OF_SCALE_ONE)
			testing.expectf(t, found && value > 0, "%v: U+%04X: the advance %v", face, int(each.character), value)
		}
	}
	wide, _, _ := glyph(.Cells, 0x4E00, TEXT_SIZE_OF_SCALE_ONE, 0)
	testing.expect_value(t, int(wide.width), 2 * cell_columns(TEXT_SIZE_OF_SCALE_ONE))
	narrow, _, _ := glyph(.Cells, 'A', TEXT_SIZE_OF_SCALE_ONE, 0)
	testing.expect_value(t, int(narrow.width), cell_columns(TEXT_SIZE_OF_SCALE_ONE))
	for script in ([?]Script{.Hebrew, .Arabic}) {
		drawn, total := coverage(.Interface, script)
		testing.expectf(t, drawn > total / 2, "%v: %v of %v", script, drawn, total)
	}
	// The cells of a line of ideographs: two for each.
	cells := cell_spacing(8)
	width, _ := text_width(&cells, transmute([]u8)string("一二a"))
	testing.expect_value(t, width, i64(5 * 8 * SUBPIXEL))
}

// The check of a script font set where it enters a machine: the set whose
// bytes give the named hash passes; one changed byte of a font, a named
// hash of another object, and a record whose hash is not the hash of its
// font are each refused whole, with Hash_Mismatch.
@(test)
a_script_font_set_that_does_not_verify :: proc(t: ^testing.T) {
	names := [1]string{"noto_sans_hebrew"}
	scripts := script_fonts_read(t, names[:])
	defer {
		for font in scripts {
			delete(font.bytes)
		}
		delete(scripts)
	}
	size := font_outlines.resource_size(scripts[:])
	words := make([]u64, (size + 7) / 8)
	defer delete(words)
	bytes := ([^]u8)(raw_data(words))[:size]
	_, written := font_outlines.resource_write(scripts[:], bytes)
	testing.expect(t, written)
	named := blake3.hash(bytes)
	_, problem := font_outlines.script_fonts_check(bytes, named, new(font_outlines.Record_Room, context.temp_allocator)[:])
	testing.expect_value(t, problem.kind, font_outlines.Problem_Kind.None)
	other := named
	other[0] ~= 1
	_, problem = font_outlines.script_fonts_check(bytes, other, new(font_outlines.Record_Room, context.temp_allocator)[:])
	testing.expect_value(t, problem.kind, font_outlines.Problem_Kind.Hash_Mismatch)
	bytes[size - 1] ~= 1
	_, problem = font_outlines.script_fonts_check(bytes, named, new(font_outlines.Record_Room, context.temp_allocator)[:])
	testing.expect_value(t, problem.kind, font_outlines.Problem_Kind.Hash_Mismatch)
	// The object as named, and a font that is not the font of its record.
	renamed := blake3.hash(bytes)
	_, problem = font_outlines.script_fonts_check(bytes, renamed, new(font_outlines.Record_Room, context.temp_allocator)[:])
	testing.expect_value(t, problem.kind, font_outlines.Problem_Kind.Hash_Mismatch)
	testing.expect_value(t, problem.index, u32(0))
}
// A font of the boot image is TrueType: a font with CFF outlines in the
// place of a font of the boot image is refused, and its slot stays closed
// and all zero. The same file opens as a script font.
@(test)
a_cff_font_in_the_place_of_a_boot_font_is_refused :: proc(t: ^testing.T) {
	names := [1]string{"noto_sans_symbols_2"}
	scripts := script_fonts_read(t, names[:])
	defer {
		for font in scripts {
			delete(font.bytes)
		}
		delete(scripts)
	}
	if len(scripts) != 1 {
		return
	}
	set := new(Font_Set)
	defer free(set)
	room := new(Font_Room)
	defer free(room)
	set.room = room[:]
	memory := new(Measure_Memory)
	defer free(memory)
	outline := measure_outline_of(memory)
	for font in BOOT_FONTS {
		testing.expect_value(t, font_file_open(set, font, scripts[0].bytes, &outline), vector_font.Font_Problem.Unknown_Format)
		testing.expectf(t, !font_at(set, font).opened && font_at(set, font).file.bytes == nil && font_at(set, font).own == {}, "%v stays closed", font)
	}
	testing.expect_value(t, font_file_open(set, .Noto_Sans_Symbols_2, scripts[0].bytes, &outline), vector_font.Font_Problem.None)
	testing.expect(t, font_at(set, .Noto_Sans_Symbols_2).opened)
}
// screen_order gives the glyphs of a line that have a width, by their place
// on the screen from the left: their indices in the order of the text.
@(private = "file")
screen_order :: proc(placed: []Placed_Glyph) -> [dynamic]int {
	order := make([dynamic]int, context.temp_allocator)
	for glyph, index in placed {
		if glyph.advance > 0 {
			append(&order, index)
		}
	}
	for low in 1 ..< len(order) {
		for back := low; back > 0 && placed[order[back]].x < placed[order[back - 1]].x; back -= 1 {
			order[back], order[back - 1] = order[back - 1], order[back]
		}
	}
	return order
}

// The isolates of UAX #9 (LRI, RLI, FSI, PDI): an isolate is one unit of
// the line around it, its own direction inside; each isolate character
// draws nothing and has no advance. RLI with Hebrew in a line of Latin:
// the Hebrew reversed in its place; a text that starts with an isolate of
// Latin and then Hebrew: a paragraph of right to left, as its first strong
// character outside the isolate says; FSI takes the direction of its first
// strong character; a PDI that closes nothing, and an RLI that no PDI
// closes, change no place before them; 130 RLIs deep pass the depth of the
// algorithm and fault nothing.
@(test)
the_isolates_of_a_line :: proc(t: ^testing.T) {
	test_state_take()
	names := [1]string{"noto_sans_hebrew"}
	words, script_words, _ := script_set_open(t, names[:])
	defer delete(words)
	defer delete(script_words)
	placed: [256]Placed_Glyph
	// a b RLI א ב PDI c: a, b, then ב, א, then c.
	count, _ := shape_text(t, .Interface, "ab\u2067אב\u2069c", placed[:])
	testing.expect_value(t, count, 7)
	for index in ([?]int{2, 5}) {
		testing.expectf(t, placed[index].glyph == INVISIBLE_GLYPH && placed[index].advance == 0, "the isolate character %d draws nothing: %v", index, placed[index])
	}
	order := screen_order(placed[:count])
	testing.expectf(t, slice_equal(order[:], {0, 1, 4, 3, 6}), "an RLI in Latin: %v", order[:])
	// LRI a b PDI א: the paragraph is right to left; the isolate keeps a b
	// in order, at the right of the Hebrew letter... at its left: the
	// isolate is the first unit of a line of right to left.
	count, _ = shape_text(t, .Interface, "\u2066ab\u2069 א", placed[:])
	order = screen_order(placed[:count])
	testing.expectf(t, slice_equal(order[:], {5, 4, 1, 2}), "an LRI first, then Hebrew: %v", order[:])
	// FSI with Hebrew inside: right to left inside.
	count, _ = shape_text(t, .Interface, "x\u2068אב\u2069y", placed[:])
	order = screen_order(placed[:count])
	testing.expectf(t, slice_equal(order[:], {0, 3, 2, 5}), "an FSI of Hebrew: %v", order[:])
	// FSI with Latin inside, in a line of right to left: left to right inside.
	count, _ = shape_text(t, .Interface, "א\u2068xy\u2069ב", placed[:])
	order = screen_order(placed[:count])
	testing.expectf(t, slice_equal(order[:], {5, 2, 3, 0}), "an FSI of Latin in Hebrew: %v", order[:])
	// A PDI that closes nothing, and an RLI that no PDI closes.
	count, _ = shape_text(t, .Interface, "ab\u2069c", placed[:])
	order = screen_order(placed[:count])
	testing.expectf(t, slice_equal(order[:], {0, 1, 3}), "a PDI alone: %v", order[:])
	count, _ = shape_text(t, .Interface, "ab\u2067אב", placed[:])
	order = screen_order(placed[:count])
	testing.expectf(t, slice_equal(order[:], {0, 1, 4, 3}), "an RLI with no PDI: %v", order[:])
	// Past the depth: each glyph keeps a place, and the width is the sum of
	// the advances.
	deep := strings.concatenate({strings.repeat("\u2067", 130, context.temp_allocator), "אab", strings.repeat("\u2069", 130, context.temp_allocator)}, context.temp_allocator)
	deep_placed := make([]Placed_Glyph, 300)
	defer delete(deep_placed)
	width: i64
	count, width = shape_text(t, .Interface, deep, deep_placed)
	testing.expect_value(t, count, 263)
	sum: i64
	for glyph in deep_placed[:count] {
		sum += i64(glyph.advance)
	}
	testing.expect_value(t, width, sum)
	// Inside the deepest isolate, of right to left: a b, then א at their
	// right.
	order = screen_order(deep_placed[:count])
	testing.expectf(t, slice_equal(order[:], {131, 132, 130}), "past the depth: %v", order[:])
	// The depth at its edge: RLI and LRI in turn each open one level, so
	// the isolates 1 to 125 reach the levels 1 to 125 (BIDI_DEPTH_LIMIT);
	// a 126th overflows. The Hebrew letter inside stays at the odd level
	// 125 in both: at a level of 126 it would take 127 (I1).
	for isolates in ([2]int{BIDI_DEPTH_LIMIT, BIDI_DEPTH_LIMIT + 1}) {
		opening := make([dynamic]u8, context.temp_allocator)
		for index in 0 ..< isolates {
			append(&opening, ..transmute([]u8)string(index % 2 == 0 ? "\u2067" : "\u2066"))
		}
		text := strings.concatenate({string(opening[:]), "א", strings.repeat("\u2069", isolates, context.temp_allocator)}, context.temp_allocator)
		edge_count, _ := shape_text(t, .Interface, text, deep_placed)
		levels: [BIDI_GLYPH_LIMIT]u8
		scratch: [BIDI_GLYPH_LIMIT]u16
		bidi_levels(transmute([]u8)text, deep_placed[:edge_count], levels[:edge_count], scratch[:edge_count])
		testing.expectf(t, edge_count == 2 * isolates + 1 && levels[isolates] == BIDI_DEPTH_LIMIT, "%d isolates: the letter inside at the level %d", isolates, levels[isolates])
	}
}

@(private = "file")
slice_equal :: proc(a: []int, b: []int) -> bool {
	if len(a) != len(b) {
		return false
	}
	for value, index in a {
		if b[index] != value {
			return false
		}
	}
	return true
}
// Thai: a consonant and its marks, which the anchors of Noto Sans Thai
// place; SARA AM is two parts, NIKHAHIT on the consonant before it, before
// its tone mark, which then stacks on it, and SARA AA as a vowel of its own
// at the byte of SARA AM. SARA AM at the start of the text, and after a
// space, stays one glyph. With no script font, a letter of Thai is the
// replacement glyph.
@(test)
thai_marks_and_sara_am :: proc(t: ^testing.T) {
	test_state_take()
	placed: [16]Placed_Glyph
	{
		fonts := repository_fonts()
		_, words := outlines_open(t, fonts[:])
		defer delete(words)
		count, _ := shape_text(t, .Interface, "ก", placed[:])
		testing.expect(t, count == 1 && placed[0].glyph == REPLACEMENT_GLYPH)
	}
	names := [1]string{"noto_sans_thai"}
	words, script_words, missing := script_set_open(t, names[:])
	defer delete(words)
	defer delete(script_words)
	testing.expect(t, .Noto_Sans_Thai not_in missing)
	testing.expect_value(t, font_of(.Interface, 0x0E01), Outline_Font.Noto_Sans_Thai)
	// A consonant and a tone mark.
	count, width := shape_text(t, .Interface, "ก่", placed[:])
	testing.expectf(t, count == 2 && placed[0].placement == .Base && placed[1].placement == .Anchored && placed[1].glyph == fallback_glyph(0x0E48), "ko and mai ek: %v", placed[:count])
	testing.expect_value(t, width, i64(placed[0].advance))
	// SARA AM after a consonant.
	count, _ = shape_text(t, .Interface, "กำ", placed[:])
	testing.expectf(t, count == 3, "ko and SARA AM: %v", placed[:count])
	if count == 3 {
		testing.expect(t, placed[1].glyph == fallback_glyph(0x0E4D) && placed[1].placement == .Anchored && placed[1].cluster == 3, "NIKHAHIT on ko, at the byte of SARA AM")
		testing.expect(t, placed[2].glyph == fallback_glyph(0x0E32) && placed[2].placement == .Base && placed[2].cluster == 3, "SARA AA, at the byte of SARA AM")
		testing.expect(t, placed[2].x == placed[0].x + placed[0].advance)
	}
	// SARA AM after a tone mark: NIKHAHIT before it, the tone mark on it.
	count, _ = shape_text(t, .Interface, "ก่ำ", placed[:])
	testing.expectf(t, count == 4, "ko, mai ek and SARA AM: %v", placed[:count])
	if count == 4 {
		testing.expect(t, placed[1].glyph == fallback_glyph(0x0E4D) && placed[2].glyph == fallback_glyph(0x0E48) && placed[3].glyph == fallback_glyph(0x0E32))
		testing.expectf(t, placed[2].placement == .Anchored && placed[2].y > placed[1].y, "mai ek stacks on NIKHAHIT: %v %v", placed[1], placed[2])
	}
	// SARA AM with nothing to take its NIKHAHIT: one glyph.
	for text in ([?]string{"ำ", " ำ"}) {
		count, _ = shape_text(t, .Interface, text, placed[:])
		last := placed[count - 1]
		testing.expectf(t, last.glyph == fallback_glyph(0x0E33) && last.placement == .Base, "%q: SARA AM stays whole: %v", text, placed[:count])
	}
	// A fit never splits ko from its NIKHAHIT, nor SARA AA from its byte.
	spacing, _ := spacing_of(.Interface, TEXT_SIZE_OF_SCALE_ONE)
	ko_width, _ := text_width(&spacing, transmute([]u8)string("ก"))
	testing.expect_value(t, text_fit(&spacing, transmute([]u8)string("กำ"), ko_width), 3)
	// The cells of a line of Thai: a mark none, SARA AM one.
	testing.expect_value(t, cell_count(transmute([]u8)string("ก่ำ")), 2)
	// A consonant with its marks at the limit of a cluster: SARA AM after
	// it stays whole, and nothing is written past the marks; one mark
	// fewer, and it splits. Each cluster decodes the text once: a cluster
	// read again alone at the byte of SARA AM keeps it whole.
	many: [64]Placed_Glyph
	for marks in ([2]int{CLUSTER_MARK_LIMIT, CLUSTER_MARK_LIMIT - 1}) {
		text := strings.concatenate({"ก", strings.repeat("\u0E48", marks, context.temp_allocator), "ำ"}, context.temp_allocator)
		count, _ = shape_text(t, .Interface, text, many[:])
		last := many[count - 1]
		if marks == CLUSTER_MARK_LIMIT {
			testing.expectf(t, count == 1 + marks + 1 && last.glyph == fallback_glyph(0x0E33), "%d marks: SARA AM stays whole: %v", marks, many[:count])
		} else {
			testing.expectf(t, count == 1 + marks + 2 && last.glyph == fallback_glyph(0x0E32) && many[1].glyph == fallback_glyph(0x0E4D), "%d marks: SARA AM splits: %v", marks, many[:count])
		}
	}
	alone, _ := cluster_read(&state.font_set, .Interface, transmute([]u8)string("กำ"), 3)
	testing.expect_value(t, alone.base, rune(0x0E33))
}

// Lam and alef make one glyph, and the cluster of the alef can take the
// NIKHAHIT of a SARA AM after it: the cluster after the ligature then is
// SARA AA, at the byte of SARA AM, and NIKHAHIT draws once.
@(test)
lam_alef_keeps_the_sara_am_that_it_took :: proc(t: ^testing.T) {
	test_state_take()
	names := [2]string{"noto_sans_arabic", "noto_sans_thai"}
	words, script_words, _ := script_set_open(t, names[:])
	defer delete(words)
	defer delete(script_words)
	placed: [16]Placed_Glyph
	text := "لاำ"
	count, _ := shape_text(t, .Interface, text, placed[:])
	nikhahit := 0
	for glyph in placed[:count] {
		nikhahit += int(glyph.glyph == fallback_glyph(0x0E4D))
	}
	last := placed[count - 1]
	testing.expectf(t, nikhahit == 1 && last.glyph == fallback_glyph(0x0E32) && last.cluster == 4, "lam-alef and SARA AM: %v", placed[:count])
}
