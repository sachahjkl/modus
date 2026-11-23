package text_rendering

import "modus:vector_font"

// The model of Myanmar (src/md/features/written_shaping.md, "The models"),
// as HarfBuzz implements it (hb-ot-shaper-myanmar.cc): the grammar of a
// syllable, locl and ccmp, the first reordering on the glyphs, then rphf,
// pref, blwf and pstf one stage each, then the presentation.

Myanmar_Categories :: bit_set[Myanmar_Category;u64]

@(private)
myanmar_set :: #force_inline proc "contextless" (categories: Myanmar_Categories) -> u64 {
	return transmute(u64)categories
}

@(private)
Myanmar_Pattern :: enum u8 {
	Consonant_Syllable,
	Non_Myanmar_Cluster,
	Broken_Cluster,
	Other,
}

// k = Ra As H: the kinzi.
@(private)
myanmar_reach_kinzi :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
	return reach_step(reach_step(reach_step(reach, categories, myanmar_set({.Ra})), categories, myanmar_set({.Asat})), categories, myanmar_set({.Virama}))
}

// (DB As?)?
@(private)
myanmar_reach_dot_below :: #force_inline proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
	return reach | reach_optional(reach_step(reach, categories, myanmar_set({.Dot_Below})), categories, myanmar_set({.Asat}))
}

// medial_group = MY? As? MR? ((MW MH? ML? | MH ML? | ML) As?)?
@(private)
myanmar_reach_medial_group :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
	result := reach_optional(reach, categories, myanmar_set({.Medial_Ya}))
	result = reach_optional(result, categories, myanmar_set({.Asat}))
	result = reach_optional(result, categories, myanmar_set({.Medial_Ra}))
	wa := reach_optional(reach_optional(reach_step(result, categories, myanmar_set({.Medial_Wa})), categories, myanmar_set({.Medial_Ha})), categories, myanmar_set({.Medial_La}))
	ha := reach_optional(reach_step(result, categories, myanmar_set({.Medial_Ha})), categories, myanmar_set({.Medial_La}))
	la := reach_step(result, categories, myanmar_set({.Medial_La}))
	return result | reach_optional(wa | ha | la, categories, myanmar_set({.Asat}))
}

// main_vowel_group = (VPre VS?)* VAbv* VBlw* A* (DB As?)?
@(private)
myanmar_reach_main_vowel_group :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
	result := reach
	for {
		grown := result | reach_optional(reach_step(result, categories, myanmar_set({.Vowel_Pre})), categories, myanmar_set({.Variation_Selector}))
		if grown == result {
			break
		}
		result = grown
	}
	result = reach_repeated(result, categories, myanmar_set({.Vowel_Above}))
	result = reach_repeated(result, categories, myanmar_set({.Vowel_Below}))
	result = reach_repeated(result, categories, myanmar_set({.Anusvara}))
	return myanmar_reach_dot_below(result, categories)
}

// post_vowel_group = VPst MH? ML? As* VAbv* A* (DB As?)?
@(private)
myanmar_reach_post_vowel_group :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
	result := reach_step(reach, categories, myanmar_set({.Vowel_Post}))
	result = reach_optional(result, categories, myanmar_set({.Medial_Ha}))
	result = reach_optional(result, categories, myanmar_set({.Medial_La}))
	result = reach_repeated(result, categories, myanmar_set({.Asat}))
	result = reach_repeated(result, categories, myanmar_set({.Vowel_Above}))
	result = reach_repeated(result, categories, myanmar_set({.Anusvara}))
	return myanmar_reach_dot_below(result, categories)
}

// tone_group = sm | PT A* DB? As?
@(private)
myanmar_reach_tone_group :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
	modifier := reach_step(reach, categories, myanmar_set({.Syllable_Modifier, .Syllable_Modifier_Post}))
	tone := reach_repeated(reach_step(reach, categories, myanmar_set({.Pwo_Tone})), categories, myanmar_set({.Anusvara}))
	tone = reach_optional(reach_optional(tone, categories, myanmar_set({.Dot_Below})), categories, myanmar_set({.Asat}))
	return modifier | tone
}

// complex_syllable_tail = As* medial_group main_vowel_group
// post_vowel_group* tone_group* j?
@(private)
myanmar_reach_complex_tail :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
	result := reach_repeated(reach, categories, myanmar_set({.Asat}))
	result = myanmar_reach_medial_group(result, categories)
	result = myanmar_reach_main_vowel_group(result, categories)
	for {
		grown := result | myanmar_reach_post_vowel_group(result, categories)
		if grown == result {
			break
		}
		result = grown
	}
	for {
		grown := result | myanmar_reach_tone_group(result, categories)
		if grown == result {
			break
		}
		result = grown
	}
	return reach_optional(result, categories, myanmar_set({.Joiner, .Non_Joiner}))
}

// syllable_tail = (H (c|IV) VS?)* (H | complex_syllable_tail)
@(private)
myanmar_reach_syllable_tail :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
	result := reach
	for {
		consonant := reach_step(reach_step(result, categories, myanmar_set({.Virama})), categories, myanmar_set({.Consonant, .Ra, .Vowel_Independent}))
		grown := result | reach_optional(consonant, categories, myanmar_set({.Variation_Selector}))
		if grown == result {
			break
		}
		result = grown
	}
	return reach_step(result, categories, myanmar_set({.Virama})) | myanmar_reach_complex_tail(result, categories)
}

// myanmar_syllable_match gives the pattern and the length of the syllable
// at the start of the categories of a window.
@(private)
myanmar_syllable_match :: proc "contextless" (categories: ^Syllable_Categories) -> (pattern: Myanmar_Pattern, length: int) {
	start := Reach(1)
	best := Syllable_Match{int(Myanmar_Pattern.Other), 0}
	// consonant_syllable = (k|CS)? (c|IV|GB|DOTTEDCIRCLE) VS? syllable_tail
	head := start | myanmar_reach_kinzi(start, categories) | reach_step(start, categories, myanmar_set({.Consonant_With_Stacker}))
	base := reach_step(head, categories, myanmar_set({.Consonant, .Ra, .Vowel_Independent, .Placeholder, .Dotted_Circle}))
	match_choose(&best, int(Myanmar_Pattern.Consonant_Syllable), myanmar_reach_syllable_tail(reach_optional(base, categories, myanmar_set({.Variation_Selector})), categories))
	// j | SMPst
	match_choose(&best, int(Myanmar_Pattern.Non_Myanmar_Cluster), reach_step(start, categories, myanmar_set({.Joiner, .Non_Joiner, .Syllable_Modifier_Post})))
	// broken_cluster = k? VS? syllable_tail
	broken := reach_optional(start | myanmar_reach_kinzi(start, categories), categories, myanmar_set({.Variation_Selector}))
	match_choose(&best, int(Myanmar_Pattern.Broken_Cluster), myanmar_reach_syllable_tail(broken, categories))
	if best.length == 0 {
		return .Other, 1
	}
	return Myanmar_Pattern(best.pattern), best.length
}

@(rodata, private)
myanmar_first_stage := [?]vector_font.Engine_Feature{{{'l', 'o', 'c', 'l'}, SYLLABIC_GLOBAL}, {{'c', 'c', 'm', 'p'}, SYLLABIC_GLOBAL}}

// The basic features, one stage each, after the reordering.
@(rodata, private)
myanmar_basic_stages := [?]vector_font.Engine_Feature {
	{{'r', 'p', 'h', 'f'}, SYLLABIC_GLOBAL},
	{{'p', 'r', 'e', 'f'}, SYLLABIC_GLOBAL},
	{{'b', 'l', 'w', 'f'}, SYLLABIC_GLOBAL},
	{{'p', 's', 't', 'f'}, SYLLABIC_GLOBAL},
}

// The presentation features, with the common features of a horizontal
// text.
@(rodata, private)
myanmar_presentation_stage := [?]vector_font.Engine_Feature {
	{{'p', 'r', 'e', 's'}, SYLLABIC_GLOBAL},
	{{'a', 'b', 'v', 's'}, SYLLABIC_GLOBAL},
	{{'b', 'l', 'w', 's'}, SYLLABIC_GLOBAL},
	{{'p', 's', 't', 's'}, SYLLABIC_GLOBAL},
	{{'r', 'l', 'i', 'g'}, SYLLABIC_GLOBAL},
	{{'c', 'a', 'l', 't'}, SYLLABIC_GLOBAL},
	{{'c', 'l', 'i', 'g'}, SYLLABIC_GLOBAL},
	{{'l', 'i', 'g', 'a'}, SYLLABIC_GLOBAL},
	{{'r', 'c', 'l', 't'}, SYLLABIC_GLOBAL},
}

@(private)
myanmar_category_at :: #force_inline proc "contextless" (window: ^Syllabic_Text, glyph: vector_font.Engine_Glyph) -> Myanmar_Category {
	return int(glyph.place) < window.count ? myanmar_category_of(window.characters[glyph.place]) : .Other
}

// syllabic_glyph_insert puts the glyph of a character appended to the
// window at a place of the buffer: the dotted circle of a broken syllable,
// with the bytes of the character of the glyph that it stands before.
// false when the window or the buffer is full.
@(private)
syllabic_glyph_insert :: proc "contextless" (file: ^vector_font.Font_File, window: ^Syllabic_Text, buffer: ^vector_font.Engine_Buffer, at: int, character: rune, glyph: int) -> bool {
	if window.count >= INDIC_SYLLABLE_LIMIT || buffer.count >= vector_font.ENGINE_GLYPH_LIMIT || at < 0 || at > buffer.count || window.count == 0 {
		return false
	}
	neighbour := at < buffer.count ? int(buffer.glyphs[at].place) : int(buffer.glyphs[max(at - 1, 0)].place)
	neighbour = clamp(neighbour, 0, window.count - 1)
	index := window.count
	window.characters[index] = character
	window.starts[index] = window.starts[neighbour]
	window.ends[index] = window.ends[neighbour]
	window.count += 1
	for move := buffer.count; move > at; move -= 1 {
		buffer.glyphs[move] = buffer.glyphs[move - 1]
	}
	mask := buffer.count > 0 ? buffer.glyphs[min(at, buffer.count - 1)].mask : SYLLABIC_GLOBAL
	buffer.glyphs[at] = {glyph = u16(glyph), place = u8(index), mask = mask}
	buffer.count += 1
	vector_font.engine_buffer_prepare(file, buffer)
	return true
}

// myanmar_first_reordering gives each glyph its position and sorts the
// syllable by them (initial_reordering_consonant_syllable of HarfBuzz).
@(private)
myanmar_first_reordering :: proc "contextless" (window: ^Syllabic_Text, buffer: ^vector_font.Engine_Buffer) {
	end := buffer.count
	glyphs := buffer.glyphs[:end]
	is_consonant :: proc "contextless" (window: ^Syllabic_Text, glyph: vector_font.Engine_Glyph) -> bool {
		if .Ligated in glyph.flags {
			return false
		}
		return myanmar_category_at(window, glyph) in Myanmar_Categories{.Consonant, .Consonant_With_Stacker, .Ra, .Vowel_Independent, .Placeholder, .Dotted_Circle}
	}
	base := end
	reph := false
	limit := 0
	if end >= 3 && myanmar_category_at(window, glyphs[0]) == .Ra && myanmar_category_at(window, glyphs[1]) == .Asat && myanmar_category_at(window, glyphs[2]) == .Virama {
		limit, base, reph = 3, 0, true
	}
	if !reph {
		base = limit
	}
	for index in limit ..< end {
		if is_consonant(window, glyphs[index]) {
			base = index
			break
		}
	}
	positions: [vector_font.ENGINE_GLYPH_LIMIT]Indic_Place
	walk := 0
	for ; walk < (reph ? 3 : 0); walk += 1 {
		positions[walk] = .After_Main
	}
	for ; walk < base; walk += 1 {
		positions[walk] = .Pre_Consonant
	}
	if walk < end {
		positions[walk] = .Base_Consonant
		walk += 1
	}
	place := Indic_Place.After_Main
	for ; walk < end; walk += 1 {
		category := myanmar_category_at(window, glyphs[walk])
		switch {
		case category == .Medial_Ra:
			positions[walk] = .Pre_Consonant
		case category == .Vowel_Pre:
			positions[walk] = .Pre_Matra
		case category == .Variation_Selector:
			positions[walk] = positions[walk - 1]
		case place == .After_Main && category == .Vowel_Below:
			place = .Below_Consonant
			positions[walk] = place
		case place == .Below_Consonant && category == .Anusvara:
			positions[walk] = .Before_Sub
		case place == .Below_Consonant && category == .Vowel_Below:
			positions[walk] = place
		case place == .Below_Consonant:
			place = .After_Sub
			positions[walk] = place
		case:
			positions[walk] = place
		}
	}
	// A stable sort by position.
	for index in 1 ..< end {
		for back := index; back > 0 && positions[back] < positions[back - 1]; back -= 1 {
			positions[back], positions[back - 1] = positions[back - 1], positions[back]
			glyphs[back], glyphs[back - 1] = glyphs[back - 1], glyphs[back]
		}
	}
	// Two vowel signs of the left keep their order, with what goes with
	// each.
	first_left, last_left := end, end
	for index in 0 ..< end {
		if positions[index] == .Pre_Matra {
			if first_left == end {
				first_left = index
			}
			last_left = index
		}
	}
	reverse :: proc "contextless" (glyphs: []vector_font.Engine_Glyph, from, to: int) {
		for low, high := from, to - 1; low < high; low, high = low + 1, high - 1 {
			glyphs[low], glyphs[high] = glyphs[high], glyphs[low]
		}
	}
	if first_left < last_left {
		reverse(glyphs, first_left, last_left + 1)
		start := first_left
		for index in first_left ..= last_left {
			if myanmar_category_at(window, glyphs[index]) == .Vowel_Pre {
				reverse(glyphs, start, index + 1)
				start = index + 1
			}
		}
	}
}

// myanmar_shape shapes the window of a syllable of Myanmar into a buffer.
@(private)
myanmar_shape :: proc "contextless" (file: ^vector_font.Font_File, tag: vector_font.Feature_Tag, window: ^Syllabic_Text, buffer: ^vector_font.Engine_Buffer, budget: ^vector_font.Layout_Budget) {
	matched: Syllable_Categories
	matched.count = window.count
	for index in 0 ..< window.count {
		matched.values[index] = u8(myanmar_category_of(window.characters[index]))
	}
	pattern, length := myanmar_syllable_match(&matched)
	syllabic_cut(window, length)
	masks: [INDIC_SYLLABLE_LIMIT]u32
	for index in 0 ..< window.count {
		masks[index] = SYLLABIC_GLOBAL
	}
	syllabic_buffer_fill(file, window, masks[:window.count], buffer)
	_ = vector_font.engine_stage(file, .Substitution, tag, myanmar_first_stage[:], buffer, budget)
	if pattern == .Broken_Cluster {
		if glyph, problem := vector_font.glyph_of(file, DOTTED_CIRCLE); problem == .None && glyph > 0 {
			syllabic_glyph_insert(file, window, buffer, 0, DOTTED_CIRCLE, glyph)
		}
	}
	if pattern == .Consonant_Syllable || pattern == .Broken_Cluster {
		myanmar_first_reordering(window, buffer)
	}
	for stage in myanmar_basic_stages {
		single := [1]vector_font.Engine_Feature{stage}
		_ = vector_font.engine_stage(file, .Substitution, tag, single[:], buffer, budget)
	}
	_ = vector_font.engine_stage(file, .Substitution, tag, myanmar_presentation_stage[:], buffer, budget)
	syllabic_positions(file, tag, window, buffer, true, budget)
}
