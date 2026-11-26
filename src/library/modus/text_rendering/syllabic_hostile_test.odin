#+build !freestanding
#+build !modus
package text_rendering

import "core:strings"
import "core:testing"
import "modus:contract/text_encoding"
import "modus:vector_font"

// The shapers of Khmer, Myanmar and USE against hostile text: the syllable
// machine chooses the longest match and the first pattern on a tie, the
// window meets its bounds, every category in every order shapes, each
// character draws, the work stays inside the budget of the call, and the
// count of glyphs inside its bound.

@(private = "file")
categories_of :: proc(values: []u8) -> (categories: Syllable_Categories) {
	for value in values {
		categories.values[categories.count] = value
		categories.count += 1
	}
	return categories
}

// The longest match wins; on a tie the first pattern of the grammar wins,
// as in a Ragel scanner; a character that no pattern takes is Other, of
// length 1; a part that matches nothing reaches no place.
@(test)
the_syllable_machine_takes_the_longest_match_then_the_first_pattern :: proc(t: ^testing.T) {
	// Khmer: a consonant, a coeng, a consonant and a vowel sign above make
	// one syllable of 4; a vowel sign alone is broken; a joiner alone and
	// Other are no syllable.
	khmer := categories_of({u8(Khmer_Category.Consonant), u8(Khmer_Category.Coeng), u8(Khmer_Category.Consonant), u8(Khmer_Category.Vowel_Above)})
	pattern, length := khmer_syllable_match(&khmer)
	testing.expect(t, pattern == .Consonant_Syllable && length == 4)
	alone := categories_of({u8(Khmer_Category.Vowel_Above), u8(Khmer_Category.Consonant)})
	pattern, length = khmer_syllable_match(&alone)
	testing.expect(t, pattern == .Broken_Cluster && length == 1)
	for value in ([2]Khmer_Category{.Joiner, .Other}) {
		lone := categories_of({u8(value)})
		pattern, length = khmer_syllable_match(&lone)
		testing.expectf(t, pattern == .Other && length == 1, "%v alone: %v of %d", value, pattern, length)
	}
	// Myanmar: a joiner alone matches the non-Myanmar cluster and the
	// broken cluster, both of length 1: the first pattern wins.
	joiner := categories_of({u8(Myanmar_Category.Joiner)})
	myanmar_pattern, myanmar_length := myanmar_syllable_match(&joiner)
	testing.expect(t, myanmar_pattern == .Non_Myanmar_Cluster && myanmar_length == 1)
	// The kinzi: ra, asat, virama, then a consonant.
	kinzi := categories_of({u8(Myanmar_Category.Ra), u8(Myanmar_Category.Asat), u8(Myanmar_Category.Virama), u8(Myanmar_Category.Consonant), u8(Myanmar_Category.Vowel_Pre)})
	myanmar_pattern, myanmar_length = myanmar_syllable_match(&kinzi)
	testing.expect(t, myanmar_pattern == .Consonant_Syllable && myanmar_length == 5)
	// USE: a base of other matches the standard cluster and the symbol
	// cluster, both of length 1: the standard cluster wins. A final
	// modifier after the base alone is its own cluster.
	base_other := categories_of({u8(Universal_Category.Base_Other)})
	universal_pattern, universal_length := universal_syllable_match(&base_other)
	testing.expect(t, universal_pattern == .Standard && universal_length == 1)
	final_modifier := categories_of({u8(Universal_Category.Final_Modifier_Post), u8(Universal_Category.Base)})
	universal_pattern, universal_length = universal_syllable_match(&final_modifier)
	testing.expect(t, universal_pattern == .Final_Modifier && universal_length == 1)
	// A greedy reader would take the optional halant of the consonant
	// modifiers and miss the base: the longest match is the whole.
	stacked := categories_of({u8(Universal_Category.Base), u8(Universal_Category.Halant), u8(Universal_Category.Base), u8(Universal_Category.Vowel_Above), u8(Universal_Category.Final_Above)})
	universal_pattern, universal_length = universal_syllable_match(&stacked)
	testing.expect(t, universal_pattern == .Standard && universal_length == 5)
	vowel := categories_of({u8(Universal_Category.Vowel_Below)})
	universal_pattern, universal_length = universal_syllable_match(&vowel)
	testing.expect(t, universal_pattern == .Broken && universal_length == 1)
	// The places: a step over nothing reaches nothing; the longest of an
	// empty reach and of the start alone is 0.
	empty: Syllable_Categories
	testing.expect_value(t, reach_step(Reach(1), &empty, max(u64)), Reach(0))
	testing.expect_value(t, reach_longest(0), 0)
	testing.expect_value(t, reach_longest(1), 0)
	testing.expect_value(t, reach_longest(Reach(1) << SYLLABIC_WINDOW_LIMIT), SYLLABIC_WINDOW_LIMIT)
}

// The window: 15 characters, the 16th starts the next; the dotted circle
// fits a full window, and nothing more does; a cut between the parts of one
// character of the text moves before that character.
@(test)
a_window_meets_its_bounds :: proc(t: ^testing.T) {
	test_state_take()
	names := [2]string{"noto_sans_khmer", "noto_serif_tibetan"}
	words, script_words, missing := script_set_open(t, names[:])
	defer delete(words)
	defer delete(script_words)
	testing.expect(t, .Noto_Sans_Khmer not_in missing && .Noto_Serif_Tibetan not_in missing)
	khmer := &font_at(&state.font_set, .Noto_Sans_Khmer).file
	tibetan := &font_at(&state.font_set, .Noto_Serif_Tibetan).file
	long := strings.repeat("ក", SYLLABIC_WINDOW_LIMIT + 1, context.temp_allocator)
	window, read := syllabic_window_read(transmute([]u8)long, 0, khmer)
	testing.expect(t, read && window.count == SYLLABIC_WINDOW_LIMIT && window.end == SYLLABIC_WINDOW_LIMIT * 3)
	testing.expect(t, syllabic_insert(&window, 0, DOTTED_CIRCLE) && window.count == INDIC_SYLLABLE_LIMIT && window.characters[0] == DOTTED_CIRCLE)
	before := window
	testing.expect(t, !syllabic_insert(&window, 0, DOTTED_CIRCLE))
	testing.expect(t, !syllabic_insert(&window, -1, DOTTED_CIRCLE))
	testing.expect(t, window == before)
	// A character of another script, a broken byte and the end of the text
	// end the window; a text that starts with one of them has no window.
	for text in ([?]string{"", "a", "\xFF", "‍", "◌", "क"}) {
		_, starts := syllabic_window_read(transmute([]u8)text, 0, khmer)
		testing.expectf(t, !starts, "%q starts no window", text)
	}
	mixed := "កकក"
	window, read = syllabic_window_read(transmute([]u8)mixed, 0, khmer)
	testing.expect(t, read && window.count == 1 && window.end == 3)
	// ཀཱུ: U+0F75 is U+0F71 and U+0F74. A cut between its parts moves
	// before it.
	parts := "ཀཱུ"
	window, read = syllabic_window_read(transmute([]u8)parts, 0, tibetan)
	testing.expectf(t, read && window.count == 3 && window.characters[1] == 0x0F71 && window.characters[2] == 0x0F74 && window.starts[1] == window.starts[2], "ཀཱུ: %v", window.characters[:window.count])
	syllabic_cut(&window, 2)
	testing.expect(t, window.count == 1 && window.end == 3)
	// A cut at 0 or past the window keeps one character, or all.
	window, _ = syllabic_window_read(transmute([]u8)parts, 0, tibetan)
	syllabic_cut(&window, 0)
	testing.expect(t, window.count == 1)
	window, _ = syllabic_window_read(transmute([]u8)parts, 0, tibetan)
	syllabic_cut(&window, 99)
	testing.expect(t, window.count == 3 && window.end == len(parts))
	// The marks of Tibetan in the order of HarfBuzz: the sign u before the
	// sign i, whatever their order in the text.
	window, _ = syllabic_window_read(transmute([]u8)string("ཀིུ"), 0, tibetan)
	testing.expectf(t, window.count == 3 && window.characters[1] == 0x0F74 && window.characters[2] == 0x0F72, "ཀིུ: %v", window.characters[:window.count])
}

// representatives gives one character of each category of a model among
// the characters of a script and the characters that its syllables share.
@(private = "file")
representatives :: proc(script: Syllabic_Script) -> [dynamic]rune {
	row := syllabic_script_rows[script]
	seen: [64]bool
	found := make([dynamic]rune, context.temp_allocator)
	take :: proc(model: Syllabic_Model, character: rune, seen: ^[64]bool, found: ^[dynamic]rune) {
		value: u8
		switch model {
		case .Khmer:
			value = u8(khmer_category_of(character))
		case .Myanmar:
			value = u8(myanmar_category_of(character))
		case .Universal:
			category, _ := universal_category_of(character)
			value = u8(category)
		}
		if !seen[value] {
			seen[value] = true
			append(found, character)
		}
	}
	for range in row.ranges[:row.range_count] {
		for character in range.first ..= range.last {
			take(row.model, character, &seen, &found)
		}
	}
	for character in ([?]rune{0x200C, 0x200D, 0x25CC, 0x034F, 0xFE00}) {
		take(row.model, character, &seen, &found)
	}
	return found
}

@(private = "file")
text_append :: proc(text: ^[dynamic]u8, characters: ..rune) {
	for character in characters {
		bytes: [4]u8
		length := text_encoding.character_encode(character, bytes[:])
		append(text, ..bytes[:length])
	}
}

// For each script: every category after every two categories, long runs of
// one mark, of joiners before marks and of grapheme joiners, and a full
// window of bases with its marks. Each shapes whole: each glyph at the byte
// of a character, the width of shape and of text_width the same, the count
// of glyphs at most the glyphs of a Shaped for each character, and the work
// inside the budget of the call.
@(test)
hostile_text_of_the_syllabic_scripts :: proc(t: ^testing.T) {
	test_state_take()
	names := [6]string{"noto_sans_khmer", "noto_sans_myanmar", "noto_serif_tibetan", "noto_sans_balinese", "noto_sans_javanese", "noto_sans_sundanese"}
	words, script_words, missing := script_set_open(t, names[:])
	defer delete(words)
	defer delete(script_words)
	testing.expect_value(t, missing & SYLLABIC_SCRIPT_FONTS, Outline_Fonts{})
	// One mark of each script that stacks without an end.
	marks := [Syllabic_Script]rune {
		.Khmer     = 0x17D2,
		.Myanmar   = 0x103A,
		.Tibetan   = 0x0F71,
		.Balinese  = 0x1B44,
		.Javanese  = 0xA9C0,
		.Sundanese = 0x1BAA,
	}
	placed := make([]Placed_Glyph, 1 << 18, context.temp_allocator)
	spacing, _ := spacing_of(.Interface, TEXT_SIZE_OF_SCALE_ONE)
	for script in Syllabic_Script {
		row := syllabic_script_rows[script]
		base := row.ranges[0].first + (script == .Tibetan ? 0x40 : script == .Javanese ? 0x0F : script == .Sundanese ? 0x0A : 0x13)
		if script == .Khmer || script == .Myanmar {
			base = row.ranges[0].first
		}
		each := representatives(script)
		// The triples that fit one text: three characters take at most 12
		// bytes.
		triples := make([dynamic]u8, context.temp_allocator)
		triples_loop: for first in each {
			for second in each {
				for third in each {
					if len(triples) + 12 > TEXT_LIMIT {
						break triples_loop
					}
					text_append(&triples, first, second, third)
				}
			}
		}
		marks_run := make([dynamic]u8, context.temp_allocator)
		text_append(&marks_run, base)
		for _ in 0 ..< 10_000 {
			text_append(&marks_run, marks[script])
		}
		joiners := make([dynamic]u8, context.temp_allocator)
		text_append(&joiners, base)
		for _ in 0 ..< 5_000 {
			text_append(&joiners, 0x200C, marks[script])
		}
		grapheme := make([dynamic]u8, context.temp_allocator)
		text_append(&grapheme, base)
		for _ in 0 ..< 10_000 {
			text_append(&grapheme, 0x034F)
		}
		full := make([dynamic]u8, context.temp_allocator)
		for _ in 0 ..< SYLLABIC_WINDOW_LIMIT {
			text_append(&full, base)
		}
		for _ in 0 ..< SYLLABIC_WINDOW_LIMIT {
			text_append(&full, marks[script])
		}
		for text in ([?][]u8{triples[:], marks_run[:], joiners[:], grapheme[:], full[:]}) {
			characters := text_encoding.character_count(text)
			count, width, ok := shape(&spacing, text, placed)
			testing.expectf(t, ok && count >= 1 && count <= (1 + CLUSTER_MARK_LIMIT) * characters && count <= len(placed), "%v, %d bytes: %d glyphs for %d characters", script, len(text), count, characters)
			starts := make([]bool, len(text) + 1, context.temp_allocator)
			for place := 0; place < len(text); {
				_, length, _ := text_encoding.character_decode(text, place)
				starts[place] = true
				place += max(length, 1)
			}
			sum: i64
			wrong := 0
			for glyph in placed[:min(count, len(placed))] {
				if int(glyph.cluster) >= len(text) || !starts[glyph.cluster] {
					wrong += 1
				}
				sum += i64(glyph.advance)
			}
			testing.expectf(t, wrong == 0 && sum == width, "%v, %d bytes: %d glyphs at no character, the sum %d of the width %d", script, len(text), wrong, sum, width)
			measured, _ := text_width(&spacing, text)
			testing.expect_value(t, measured, width)
			shaper := shaper_of(&spacing, text)
			shaped: Shaped
			for shaper_next(&shaper, &shaped) {
			}
			testing.expectf(t, !vector_font.layout_budget_spent(&shaper.budget), "%v, %d bytes: the budget of %d is spent", script, len(text), shaper.budget.limit)
		}
	}
}

// A budget that a call spends: the syllables after it draw as the plain
// glyphs of their characters, each character a glyph, and nothing faults.
@(test)
a_spent_budget_draws_the_plain_glyphs_of_a_syllabic_script :: proc(t: ^testing.T) {
	test_state_take()
	names := [1]string{"noto_sans_khmer"}
	words, script_words, _ := script_set_open(t, names[:])
	defer delete(words)
	defer delete(script_words)
	spacing, _ := spacing_of(.Interface, TEXT_SIZE_OF_SCALE_ONE)
	text := transmute([]u8)string("ក្រុ")
	shaper := shaper_of(&spacing, text)
	shaped: Shaped
	testing.expect(t, shaper_next(&shaper, &shaped) && shaped.syllable)
	shaper = shaper_of(&spacing, text)
	shaper.budget.work = shaper.budget.limit
	count := 0
	for shaper_next(&shaper, &shaped) {
		testing.expect(t, !shaped.syllable)
		count += 1 + shaped.mark_count
	}
	testing.expect_value(t, count, 4)
}

// No font of the rows of USE has the topographical features: the shaper
// applies none (src/md/features/written_shaping.md, "The topographical
// features of USE"). A font of the set that has them fails here.
@(test)
no_font_of_universal_has_the_topographical_features :: proc(t: ^testing.T) {
	test_state_take()
	names := [4]string{"noto_serif_tibetan", "noto_sans_balinese", "noto_sans_javanese", "noto_sans_sundanese"}
	words, script_words, _ := script_set_open(t, names[:])
	defer delete(words)
	defer delete(script_words)
	for row in syllabic_script_rows {
		if row.model != .Universal {
			continue
		}
		file := &font_at(&state.font_set, row.font).file
		testing.expectf(t, vector_font.layout_has_script(file, file.gsub, row.tag), "%v names its script", row.font)
		for feature in ([4]vector_font.Feature_Tag{{'i', 's', 'o', 'l'}, {'i', 'n', 'i', 't'}, {'m', 'e', 'd', 'i'}, {'f', 'i', 'n', 'a'}}) {
			room: [vector_font.ENGINE_STAGE_WALK_LIMIT]u16
			indices, _, problem := vector_font.layout_feature_indices(file, file.gsub, row.tag, {'D', 'F', 'L', 'T'}, feature, room[:])
			testing.expectf(t, problem == .No_Feature || len(indices) == 0, "%v has %v", row.font, feature)
		}
	}
}

// The categories: a character out of the tables is Other, and no mark.
@(test)
a_character_out_of_the_tables_is_other :: proc(t: ^testing.T) {
	for character in ([?]rune{0, 'a', 0x0915, 0x10FFFF, 0x19E0}) {
		testing.expect_value(t, khmer_category_of(character), Khmer_Category.Other)
		testing.expect_value(t, myanmar_category_of(character), Myanmar_Category.Other)
		category, mark := universal_category_of(character)
		testing.expect(t, category == .Other && !mark)
	}
	testing.expect_value(t, khmer_category_of(0x17D2), Khmer_Category.Coeng)
	testing.expect_value(t, myanmar_category_of(0x103C), Myanmar_Category.Medial_Ra)
	category, mark := universal_category_of(0x0F72)
	testing.expect(t, category == .Vowel_Below && mark)
	_, script_found := syllabic_script_of(0x0915)
	testing.expect(t, !script_found)
}

// A broken Myanmar cluster starting with kinzi (Ra, Asat, Virama) followed by
// a pre-base vowel with no consonant and no dotted circle: Vowel_Pre must
// reorder before the kinzi instead of being marked as Base_Consonant.
@(test)
myanmar_broken_kinzi_without_consonant_reorders_pre_vowel :: proc(t: ^testing.T) {
	window: Syllabic_Text
	window.characters = {0 = 0x1004, 1 = 0x103A, 2 = 0x1039, 3 = 0x1031}
	window.count = 4
	buffer: vector_font.Engine_Buffer
	buffer.count = 4
	for index in 0 ..< 4 {
		buffer.glyphs[index] = {glyph = u16(index + 10), place = u8(index)}
	}
	myanmar_first_reordering(&window, &buffer)
	// Vowel_Pre (place 3, glyph 13) gets Pre_Matra and moves before kinzi (After_Main).
	testing.expect_value(t, buffer.glyphs[0].place, u8(3))
	testing.expect_value(t, buffer.glyphs[1].place, u8(0))
	testing.expect_value(t, buffer.glyphs[2].place, u8(1))
	testing.expect_value(t, buffer.glyphs[3].place, u8(2))
}

// outline_font_of_word refuses None (0) and any word past max(Outline_Font).
@(test)
outline_font_of_word_refuses_none_and_unknown :: proc(t: ^testing.T) {
	for word in ([?]u64{0, u64(max(Outline_Font)) + 1, u64(max(u32)), max(u64)}) {
		font, ok := outline_font_of_word(word)
		testing.expectf(t, !ok && font == .None, "word %d must be refused", word)
	}
	for member in Outline_Font {
		if member == .None {
			continue
		}
		font, ok := outline_font_of_word(u64(member))
		testing.expect(t, ok && font == member)
	}
}
