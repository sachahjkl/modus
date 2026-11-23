package text_rendering

import "modus:vector_font"

// The Universal Shaping Engine (src/md/features/written_shaping.md, "The
// models"), as HarfBuzz implements it (hb-ot-shaper-use.cc): the grammar of
// a cluster, the basic features with the repha and the pre-base forms that
// they record, the dotted circle of a broken cluster, the reordering, then
// the presentation. The topographical features (isol, init, medi, fina) are
// not applied: no font of the rows has them, which a host test checks.

Universal_Categories :: bit_set[Universal_Category;u64]

@(private)
universal_set :: #force_inline proc "contextless" (categories: Universal_Categories) -> u64 {
	return transmute(u64)categories
}

// The syllable types of hb-ot-shaper-use-machine.rl, in the order of its
// patterns.
@(private)
Universal_Pattern :: enum u8 {
	Virama_Terminated,
	Sakot_Terminated,
	Standard,
	Number_Joiner_Terminated,
	Numeral,
	Symbol,
	Hieroglyph,
	Final_Modifier, // A final modifier after the base, alone: no cluster.
	Broken,
	Other, // No cluster.
}

// consonant_modifiers = CMAbv* CMBlw* ((h B | SUB) CMAbv* CMBlw*)*
@(private)
universal_reach_consonant_modifiers :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
	modifiers :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
		return reach_repeated(reach_repeated(reach, categories, universal_set({.Consonant_Modifier_Above})), categories, universal_set({.Consonant_Modifier_Below}))
	}
	result := modifiers(reach, categories)
	for {
		halant := reach_step(reach_step(result, categories, universal_set({.Halant, .Halant_Or_Vowel_Modifier, .Invisible_Stacker, .Sakot})), categories, universal_set({.Base}))
		grown := result | modifiers(halant | reach_step(result, categories, universal_set({.Consonant_Subjoined})), categories)
		if grown == result {
			return result
		}
		result = grown
	}
}

// complex_syllable_middle = consonant_modifiers medial_consonants
// dependent_vowels vowel_modifiers (Sk B)*
@(private)
universal_reach_middle :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
	result := universal_reach_consonant_modifiers(reach, categories)
	// medial_consonants = MPre? MAbv? MBlw? MPst?
	result = reach_optional(result, categories, universal_set({.Medial_Pre}))
	result = reach_optional(result, categories, universal_set({.Medial_Above}))
	result = reach_optional(result, categories, universal_set({.Medial_Below}))
	result = reach_optional(result, categories, universal_set({.Medial_Post}))
	// dependent_vowels = VPre* VAbv* VBlw* VPst* | H
	vowels := reach_repeated(result, categories, universal_set({.Vowel_Pre}))
	vowels = reach_repeated(vowels, categories, universal_set({.Vowel_Above}))
	vowels = reach_repeated(vowels, categories, universal_set({.Vowel_Below}))
	vowels = reach_repeated(vowels, categories, universal_set({.Vowel_Post}))
	result = vowels | reach_step(result, categories, universal_set({.Halant}))
	// vowel_modifiers = HVM? VMPre* VMAbv* VMBlw* VMPst*
	result = reach_optional(result, categories, universal_set({.Halant_Or_Vowel_Modifier}))
	result = reach_repeated(result, categories, universal_set({.Vowel_Modifier_Pre}))
	result = reach_repeated(result, categories, universal_set({.Vowel_Modifier_Above}))
	result = reach_repeated(result, categories, universal_set({.Vowel_Modifier_Below}))
	result = reach_repeated(result, categories, universal_set({.Vowel_Modifier_Post}))
	for {
		grown := result | reach_step(reach_step(result, categories, universal_set({.Sakot})), categories, universal_set({.Base}))
		if grown == result {
			return result
		}
		result = grown
	}
}

// complex_syllable_tail = complex_syllable_middle final_consonants
// final_modifiers
@(private)
universal_reach_complex_tail :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
	result := universal_reach_middle(reach, categories)
	// final_consonants = FAbv* FBlw* FPst*
	result = reach_repeated(result, categories, universal_set({.Final_Above}))
	result = reach_repeated(result, categories, universal_set({.Final_Below}))
	result = reach_repeated(result, categories, universal_set({.Final_Post}))
	// final_modifiers = FMAbv* FMBlw* | FMPst?
	modifiers := reach_repeated(reach_repeated(result, categories, universal_set({.Final_Modifier_Above})), categories, universal_set({.Final_Modifier_Below}))
	return modifiers | reach_optional(result, categories, universal_set({.Final_Modifier_Post}))
}

// number_joiner_terminated_cluster_tail = (HN N)* HN
@(private)
universal_reach_number_joiner_tail :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
	result := reach
	for {
		grown := result | reach_step(reach_step(result, categories, universal_set({.Halant_Number})), categories, universal_set({.Number}))
		if grown == result {
			break
		}
		result = grown
	}
	return reach_step(result, categories, universal_set({.Halant_Number}))
}

// numeral_cluster_tail = (HN N)+
@(private)
universal_reach_numeral_tail :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
	pair :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
		return reach_step(reach_step(reach, categories, universal_set({.Halant_Number})), categories, universal_set({.Number}))
	}
	result := pair(reach, categories)
	for {
		grown := result | pair(result, categories)
		if grown == result {
			return result
		}
		result = grown
	}
}

// tail = complex_syllable_tail | sakot_terminated_cluster_tail |
// symbol_cluster_tail | virama_terminated_cluster_tail
@(private)
universal_reach_tail :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
	complex := universal_reach_complex_tail(reach, categories)
	sakot := reach_step(universal_reach_middle(reach, categories), categories, universal_set({.Sakot}))
	// symbol_cluster_tail = SMAbv+ SMBlw* | SMBlw+
	above := reach_step(reach, categories, universal_set({.Symbol_Modifier_Above}))
	above = reach_repeated(reach_repeated(above, categories, universal_set({.Symbol_Modifier_Above})), categories, universal_set({.Symbol_Modifier_Below}))
	below := reach_repeated(reach_step(reach, categories, universal_set({.Symbol_Modifier_Below})), categories, universal_set({.Symbol_Modifier_Below}))
	// virama_terminated_cluster_tail = consonant_modifiers (IS | RK)
	virama := reach_step(universal_reach_consonant_modifiers(reach, categories), categories, universal_set({.Invisible_Stacker, .Reordering_Killer}))
	return complex | sakot | above | below | virama
}

// universal_syllable_match gives the pattern and the length of the cluster
// at the start of the categories of a window, the characters that the
// match leaves out taken away.
@(private)
universal_syllable_match :: proc "contextless" (categories: ^Syllable_Categories) -> (pattern: Universal_Pattern, length: int) {
	non_joiner :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
		return reach_optional(reach, categories, universal_set({.Non_Joiner}))
	}
	start := Reach(1)
	best := Syllable_Match{int(Universal_Pattern.Other), 0}
	// complex_syllable_start = (R | CS)? (B | GB)
	head := reach_step(reach_optional(start, categories, universal_set({.Repha, .Consonant_With_Stacker})), categories, universal_set({.Base, .Base_Other}))
	virama := reach_step(universal_reach_consonant_modifiers(head, categories), categories, universal_set({.Invisible_Stacker, .Reordering_Killer}))
	match_choose(&best, int(Universal_Pattern.Virama_Terminated), non_joiner(virama, categories))
	sakot := reach_step(universal_reach_middle(head, categories), categories, universal_set({.Sakot}))
	match_choose(&best, int(Universal_Pattern.Sakot_Terminated), non_joiner(sakot, categories))
	match_choose(&best, int(Universal_Pattern.Standard), non_joiner(universal_reach_complex_tail(head, categories), categories))
	number := reach_step(start, categories, universal_set({.Number}))
	match_choose(&best, int(Universal_Pattern.Number_Joiner_Terminated), non_joiner(universal_reach_number_joiner_tail(number, categories), categories))
	match_choose(&best, int(Universal_Pattern.Numeral), non_joiner(number | universal_reach_numeral_tail(number, categories), categories))
	symbol := reach_step(start, categories, universal_set({.Other, .Base_Other, .Hieroglyph_Segment_Begin}))
	match_choose(&best, int(Universal_Pattern.Symbol), non_joiner(symbol | universal_reach_tail(symbol, categories), categories))
	// hieroglyph_cluster = SB* G HR? HM? SE* (J SB* (G HR? HM? SE*)?)*
	glyph_part :: proc "contextless" (reach: Reach, categories: ^Syllable_Categories) -> Reach {
		result := reach_step(reach, categories, universal_set({.Hieroglyph}))
		result = reach_optional(result, categories, universal_set({.Hieroglyph_Mirror}))
		result = reach_optional(result, categories, universal_set({.Hieroglyph_Modifier}))
		return reach_repeated(result, categories, universal_set({.Hieroglyph_Segment_End}))
	}
	hieroglyph := glyph_part(reach_repeated(start, categories, universal_set({.Hieroglyph_Segment_Begin})), categories)
	for {
		joined := reach_repeated(reach_step(hieroglyph, categories, universal_set({.Hieroglyph_Joiner})), categories, universal_set({.Hieroglyph_Segment_Begin}))
		grown := hieroglyph | joined | glyph_part(joined, categories)
		if grown == hieroglyph {
			break
		}
		hieroglyph = grown
	}
	match_choose(&best, int(Universal_Pattern.Hieroglyph), non_joiner(hieroglyph, categories))
	match_choose(&best, int(Universal_Pattern.Final_Modifier), reach_step(start, categories, universal_set({.Final_Modifier_Post})))
	// broken_cluster = R? (tail | number_joiner_terminated_cluster_tail |
	// numeral_cluster_tail)
	broken := reach_optional(start, categories, universal_set({.Repha}))
	broken = universal_reach_tail(broken, categories) | universal_reach_number_joiner_tail(broken, categories) | universal_reach_numeral_tail(broken, categories)
	match_choose(&best, int(Universal_Pattern.Broken), non_joiner(broken, categories))
	if best.length == 0 {
		return .Other, 1
	}
	return Universal_Pattern(best.pattern), best.length
}

@(rodata, private)
universal_first_stage := [?]vector_font.Engine_Feature {
	{{'l', 'o', 'c', 'l'}, SYLLABIC_GLOBAL},
	{{'c', 'c', 'm', 'p'}, SYLLABIC_GLOBAL},
	{{'n', 'u', 'k', 't'}, SYLLABIC_GLOBAL},
	{{'a', 'k', 'h', 'n'}, SYLLABIC_GLOBAL},
}

@(rodata, private)
universal_repha_stage := [?]vector_font.Engine_Feature{{{'r', 'p', 'h', 'f'}, SYLLABIC_REPH}}

@(rodata, private)
universal_pre_base_stage := [?]vector_font.Engine_Feature{{{'p', 'r', 'e', 'f'}, SYLLABIC_GLOBAL}}

// The orthographic unit shaping group, in one stage.
@(rodata, private)
universal_basic_stage := [?]vector_font.Engine_Feature {
	{{'r', 'k', 'r', 'f'}, SYLLABIC_GLOBAL},
	{{'a', 'b', 'v', 'f'}, SYLLABIC_GLOBAL},
	{{'b', 'l', 'w', 'f'}, SYLLABIC_GLOBAL},
	{{'h', 'a', 'l', 'f'}, SYLLABIC_GLOBAL},
	{{'p', 's', 't', 'f'}, SYLLABIC_GLOBAL},
	{{'v', 'a', 't', 'u'}, SYLLABIC_GLOBAL},
	{{'c', 'j', 'c', 't'}, SYLLABIC_GLOBAL},
}

// The standard typographic presentation, with the common features of a
// horizontal text.
@(rodata, private)
universal_presentation_stage := [?]vector_font.Engine_Feature {
	{{'a', 'b', 'v', 's'}, SYLLABIC_GLOBAL},
	{{'b', 'l', 'w', 's'}, SYLLABIC_GLOBAL},
	{{'h', 'a', 'l', 'n'}, SYLLABIC_GLOBAL},
	{{'p', 'r', 'e', 's'}, SYLLABIC_GLOBAL},
	{{'p', 's', 't', 's'}, SYLLABIC_GLOBAL},
	{{'r', 'l', 'i', 'g'}, SYLLABIC_GLOBAL},
	{{'c', 'a', 'l', 't'}, SYLLABIC_GLOBAL},
	{{'c', 'l', 'i', 'g'}, SYLLABIC_GLOBAL},
	{{'l', 'i', 'g', 'a'}, SYLLABIC_GLOBAL},
	{{'r', 'c', 'l', 't'}, SYLLABIC_GLOBAL},
}

// The categories of the glyphs after the base, before which a repha
// stops (POST_BASE_FLAGS64 of HarfBuzz).
@(private)
UNIVERSAL_AFTER_BASE :: Universal_Categories{.Final_Above, .Final_Below, .Final_Post, .Final_Modifier_Above, .Final_Modifier_Below, .Final_Modifier_Post, .Medial_Above, .Medial_Below, .Medial_Post, .Medial_Pre, .Vowel_Above, .Vowel_Below, .Vowel_Post, .Vowel_Pre, .Vowel_Modifier_Above, .Vowel_Modifier_Below, .Vowel_Modifier_Post, .Vowel_Modifier_Pre}

// The work of a cluster: the category of each character of the window,
// which the record of rphf and of pref changes, and the dotted circle too.
@(private)
Universal_Work :: struct {
	categories: [INDIC_SYLLABLE_LIMIT]Universal_Category,
}

@(private)
universal_category_at :: #force_inline proc "contextless" (work: ^Universal_Work, window: ^Syllabic_Text, glyph: vector_font.Engine_Glyph) -> Universal_Category {
	return int(glyph.place) < window.count ? work.categories[glyph.place] : .Other
}

// is_universal_halant says if a glyph is a halant that stayed apart.
@(private)
is_universal_halant :: #force_inline proc "contextless" (work: ^Universal_Work, window: ^Syllabic_Text, glyph: vector_font.Engine_Glyph) -> bool {
	return universal_category_at(work, window, glyph) in Universal_Categories{.Halant, .Halant_Or_Vowel_Modifier, .Invisible_Stacker} && .Ligated not_in glyph.flags
}

// universal_reorder moves the repha before the first glyph after the base,
// and each vowel sign of the left to the start or after the last halant
// (reorder_syllable_use of HarfBuzz).
@(private)
universal_reorder :: proc "contextless" (work: ^Universal_Work, window: ^Syllabic_Text, buffer: ^vector_font.Engine_Buffer) {
	end := buffer.count
	if end > 1 && universal_category_at(work, window, buffer.glyphs[0]) == .Repha {
		for index in 1 ..< end {
			glyph := buffer.glyphs[index]
			after_base := universal_category_at(work, window, glyph) in UNIVERSAL_AFTER_BASE || is_universal_halant(work, window, glyph)
			if after_base || index == end - 1 {
				indic_buffer_move(buffer, 0, after_base ? index - 1 : index)
				break
			}
		}
	}
	target := 0
	for index in 0 ..< end {
		glyph := buffer.glyphs[index]
		if is_universal_halant(work, window, glyph) {
			target = index + 1
		} else if (universal_category_at(work, window, glyph) in Universal_Categories{.Vowel_Pre, .Vowel_Modifier_Pre}) && vector_font.engine_glyph_part(glyph) == 0 && target < index {
			indic_buffer_move(buffer, index, target)
		}
	}
}

// universal_shape shapes the window of a cluster of a script of USE into
// a buffer.
@(private)
universal_shape :: proc "contextless" (file: ^vector_font.Font_File, tag: vector_font.Feature_Tag, window: ^Syllabic_Text, buffer: ^vector_font.Engine_Buffer, budget: ^vector_font.Layout_Budget) {
	work: Universal_Work
	marks: [INDIC_SYLLABLE_LIMIT]bool
	for index in 0 ..< window.count {
		work.categories[index], marks[index] = universal_category_of(window.characters[index])
	}
	// The match leaves out a grapheme joiner, and a non-joiner before a
	// mark (find_syllables_use); a character left out stays in the cluster
	// of the characters before it.
	matched: Syllable_Categories
	kept: [SYLLABIC_WINDOW_LIMIT]u8
	for index in 0 ..< window.count {
		category := work.categories[index]
		if category == .Grapheme_Joiner {
			continue
		}
		if category == .Non_Joiner {
			before_mark := false
			for after in index + 1 ..< window.count {
				if work.categories[after] != .Grapheme_Joiner {
					before_mark = marks[after]
					break
				}
			}
			if before_mark {
				continue
			}
		}
		kept[matched.count] = u8(index)
		matched.values[matched.count] = u8(category)
		matched.count += 1
	}
	pattern := Universal_Pattern.Other
	length := window.count
	if matched.count > 0 {
		filtered: int
		pattern, filtered = universal_syllable_match(&matched)
		filtered = min(filtered, matched.count)
		length = filtered < matched.count ? int(kept[filtered]) : window.count
	}
	syllabic_cut(window, length)
	// rphf on a repha, else on the first three characters.
	masks: [INDIC_SYLLABLE_LIMIT]u32
	repha_count := work.categories[0] == .Repha ? 1 : min(3, window.count)
	for index in 0 ..< window.count {
		masks[index] = SYLLABIC_GLOBAL
		if index < repha_count {
			masks[index] |= SYLLABIC_REPH
		}
	}
	syllabic_buffer_fill(file, window, masks[:window.count], buffer)
	_ = vector_font.engine_stage(file, .Substitution, tag, universal_first_stage[:], buffer, budget)
	// A glyph that rphf changed is a repha; one that pref changed is a
	// vowel sign of the left.
	vector_font.engine_substitutions_forget(buffer)
	_ = vector_font.engine_stage(file, .Substitution, tag, universal_repha_stage[:], buffer, budget)
	for glyph in buffer.glyphs[:buffer.count] {
		if glyph.mask & SYLLABIC_REPH == 0 {
			break
		}
		if .Substituted in glyph.flags && int(glyph.place) < window.count {
			work.categories[glyph.place] = .Repha
			break
		}
	}
	vector_font.engine_substitutions_forget(buffer)
	_ = vector_font.engine_stage(file, .Substitution, tag, universal_pre_base_stage[:], buffer, budget)
	for glyph in buffer.glyphs[:buffer.count] {
		if .Substituted in glyph.flags && int(glyph.place) < window.count {
			work.categories[glyph.place] = .Vowel_Pre
			break
		}
	}
	_ = vector_font.engine_stage(file, .Substitution, tag, universal_basic_stage[:], buffer, budget)
	// The dotted circle of a broken cluster, after its repha.
	if pattern == .Broken {
		if glyph, problem := vector_font.glyph_of(file, DOTTED_CIRCLE); problem == .None && glyph > 0 {
			at := 0
			for at < buffer.count && universal_category_at(&work, window, buffer.glyphs[at]) == .Repha {
				at += 1
			}
			if syllabic_glyph_insert(file, window, buffer, at, DOTTED_CIRCLE, glyph) {
				work.categories[window.count - 1] = .Base
			}
		}
	}
	switch pattern {
	case .Virama_Terminated, .Sakot_Terminated, .Standard, .Symbol, .Broken:
		universal_reorder(&work, window, buffer)
	case .Number_Joiner_Terminated, .Numeral, .Hieroglyph, .Final_Modifier, .Other:
	}
	_ = vector_font.engine_stage(file, .Substitution, tag, universal_presentation_stage[:], buffer, budget)
	syllabic_positions(file, tag, window, buffer, true, budget)
}
