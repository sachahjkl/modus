package text_rendering

import "modus:vector_font"

// The model of Khmer (src/md/features/written_shaping.md, "The models"), as
// HarfBuzz implements it (hb-ot-shaper-khmer.cc): the grammar of a
// syllable, the coeng and ro moved before the base with pref, the vowel
// sign of the left moved before the base, then the features in two stages.

Khmer_Categories :: bit_set[Khmer_Category;u64]

@(private)
khmer_set :: #force_inline proc "contextless" (categories: Khmer_Categories) -> u64 {
	return transmute(u64)categories
}

// The grammar of hb-ot-shaper-khmer-machine.rl, as reached places.
@(private)
Khmer_Pattern :: enum u8 {
	Consonant_Syllable,
	Broken_Cluster,
	Other,
}

@(private)
khmer_consonant :: #force_inline proc "contextless" () -> u64 {
	return khmer_set({.Consonant, .Ro, .Vowel_Independent})
}

@(private)
khmer_joiners :: #force_inline proc "contextless" () -> u64 {
	return khmer_set({.Joiner, .Non_Joiner})
}

// cn = c ((ZWJ|ZWNJ)? Robatic)?
@(private)
khmer_reach_cn :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
	consonant := reach_step(reach, categories, khmer_consonant())
	return consonant | reach_step(reach_optional(consonant, categories, khmer_joiners()), categories, khmer_set({.Robatic}))
}

// xgroup = (joiner* Xgroup)*
@(private)
khmer_reach_x_group :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
	result := reach
	for {
		grown := result | reach_step(reach_repeated(result, categories, khmer_joiners()), categories, khmer_set({.Group_X}))
		if grown == result {
			return result
		}
		result = grown
	}
}

// matra_group = VPre? xgroup VBlw? xgroup (joiner? VAbv)? xgroup VPst?
@(private)
khmer_reach_matra_group :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
	result := reach_optional(reach, categories, khmer_set({.Vowel_Pre}))
	result = khmer_reach_x_group(result, categories)
	result = reach_optional(result, categories, khmer_set({.Vowel_Below}))
	result = khmer_reach_x_group(result, categories)
	result |= reach_step(reach_optional(result, categories, khmer_joiners()), categories, khmer_set({.Vowel_Above}))
	result = khmer_reach_x_group(result, categories)
	return reach_optional(result, categories, khmer_set({.Vowel_Post}))
}

// syllable_tail = xgroup matra_group xgroup (H c)? ygroup
@(private)
khmer_reach_syllable_tail :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
	result := khmer_reach_x_group(reach, categories)
	result = khmer_reach_matra_group(result, categories)
	result = khmer_reach_x_group(result, categories)
	result |= reach_step(reach_step(result, categories, khmer_set({.Coeng})), categories, khmer_consonant())
	return reach_repeated(result, categories, khmer_set({.Group_Y}))
}

// broken_cluster = Robatic? (H cn)* (H | syllable_tail)
@(private)
khmer_reach_broken_cluster :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
	result := reach_optional(reach, categories, khmer_set({.Robatic}))
	for {
		grown := result | khmer_reach_cn(reach_step(result, categories, khmer_set({.Coeng})), categories)
		if grown == result {
			break
		}
		result = grown
	}
	return reach_step(result, categories, khmer_set({.Coeng})) | khmer_reach_syllable_tail(result, categories)
}

// khmer_syllable_match gives the pattern and the length of the syllable at
// the start of the categories of a window: the longest match, the first
// pattern on a tie, and Other for one character that no pattern takes.
@(private)
khmer_syllable_match :: proc "contextless" (categories: ^Syllable_Categories) -> (pattern: Khmer_Pattern, length: int) {
	start := Reach(1)
	best := Syllable_Match(Khmer_Pattern){.Other, 0}
	// consonant_syllable = (cn | PLACEHOLDER | DOTTEDCIRCLE) broken_cluster
	base := khmer_reach_cn(start, categories) | reach_step(start, categories, khmer_set({.Placeholder, .Dotted_Circle}))
	match_choose(&best, Khmer_Pattern.Consonant_Syllable, khmer_reach_broken_cluster(base, categories))
	match_choose(&best, Khmer_Pattern.Broken_Cluster, khmer_reach_broken_cluster(start, categories))
	if best.length == 0 {
		return .Other, 1
	}
	return best.pattern, best.length
}

// The features of the first stage, and of the stage after the syllables:
// the model of Khmer leaves out liga and asks for clig.
@(rodata, private)
khmer_basic_stage := [?]vector_font.Engine_Feature {
	{{'l', 'o', 'c', 'l'}, SYLLABIC_GLOBAL},
	{{'c', 'c', 'm', 'p'}, SYLLABIC_GLOBAL},
	{{'p', 'r', 'e', 'f'}, SYLLABIC_PREF},
	{{'b', 'l', 'w', 'f'}, SYLLABIC_BELOW},
	{{'a', 'b', 'v', 'f'}, SYLLABIC_ABOVE},
	{{'p', 's', 't', 'f'}, SYLLABIC_POST},
	{{'c', 'f', 'a', 'r'}, SYLLABIC_CFAR},
}

@(rodata, private)
khmer_presentation_stage := [?]vector_font.Engine_Feature {
	{{'p', 'r', 'e', 's'}, SYLLABIC_GLOBAL},
	{{'a', 'b', 'v', 's'}, SYLLABIC_GLOBAL},
	{{'b', 'l', 'w', 's'}, SYLLABIC_GLOBAL},
	{{'p', 's', 't', 's'}, SYLLABIC_GLOBAL},
	{{'r', 'l', 'i', 'g'}, SYLLABIC_GLOBAL},
	{{'c', 'a', 'l', 't'}, SYLLABIC_GLOBAL},
	{{'c', 'l', 'i', 'g'}, SYLLABIC_GLOBAL},
	{{'r', 'c', 'l', 't'}, SYLLABIC_GLOBAL},
}

// khmer_move moves the characters of a window from..from+count to the place
// to, before them, with their categories and their masks.
@(private)
khmer_move :: proc "contextless" (window: ^Syllabic_Text, categories: ^[INDIC_SYLLABLE_LIMIT]Khmer_Category, masks: ^[INDIC_SYLLABLE_LIMIT]u32, from, count, to: int) {
	for moved in 0 ..< count {
		for index := from + moved; index > to + moved; index -= 1 {
			syllabic_swap(window, index - 1, index)
			categories[index - 1], categories[index] = categories[index], categories[index - 1]
			masks[index - 1], masks[index] = masks[index], masks[index - 1]
		}
	}
}

// khmer_shape shapes the window of a syllable of Khmer into a buffer.
@(private)
khmer_shape :: proc "contextless" (file: ^vector_font.Font_File, tag: vector_font.Feature_Tag, window: ^Syllabic_Text, buffer: ^vector_font.Engine_Buffer, budget: ^vector_font.Layout_Budget) {
	matched: Syllable_Categories
	matched.count = window.count
	for index in 0 ..< window.count {
		matched.values[index] = u8(khmer_category_of(window.characters[index]))
	}
	pattern, length := khmer_syllable_match(&matched)
	syllabic_cut(window, length)
	if pattern == .Broken_Cluster {
		if glyph, problem := vector_font.glyph_of(file, DOTTED_CIRCLE); problem == .None && glyph > 0 {
			syllabic_insert(window, 0, DOTTED_CIRCLE)
		}
	}
	categories: [INDIC_SYLLABLE_LIMIT]Khmer_Category
	masks: [INDIC_SYLLABLE_LIMIT]u32
	for index in 0 ..< window.count {
		categories[index] = khmer_category_of(window.characters[index])
		masks[index] = SYLLABIC_GLOBAL
	}
	if pattern != .Other {
		// Each glyph after the first takes the forms below, above and after
		// the base (reorder_consonant_syllable of HarfBuzz).
		for index in 1 ..< window.count {
			masks[index] |= SYLLABIC_BELOW | SYLLABIC_ABOVE | SYLLABIC_POST
		}
		coengs := 0
		for index := 1; index < window.count; index += 1 {
			if categories[index] == .Coeng && coengs <= 2 && index + 1 < window.count {
				coengs += 1
				if categories[index + 1] == .Ro {
					// The coeng and the ro move to the start with pref; what
					// follows them takes cfar.
					masks[index] |= SYLLABIC_PREF
					masks[index + 1] |= SYLLABIC_PREF
					khmer_move(window, &categories, &masks, index, 2, 0)
					for after in index + 2 ..< window.count {
						masks[after] |= SYLLABIC_CFAR
					}
					coengs = 2
				}
			} else if categories[index] == .Vowel_Pre {
				khmer_move(window, &categories, &masks, index, 1, 0)
			}
		}
	}
	syllabic_buffer_fill(file, window, masks[:window.count], buffer)
	_ = vector_font.engine_stage(file, .Substitution, tag, khmer_basic_stage[:], buffer, budget)
	_ = vector_font.engine_stage(file, .Substitution, tag, khmer_presentation_stage[:], buffer, budget)
	syllabic_positions(file, tag, window, buffer, false, budget)
}
