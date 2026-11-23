package text_rendering

// The properties of a character that the written shaper reads
// (src/md/features/written_shaping.md): each a search by halves in a table
// of unicode_tables.odin, which "modustool unicode_tables" writes from the
// Unicode Character Database.

// The bidirectional class of a character (UAX #9, table 4).
Bidi_Class :: enum u8 {
	L, // Left to right.
	R, // Right to left.
	AL, // Arabic letter.
	EN, // European number.
	ES, // European separator.
	ET, // European terminator.
	AN, // Arabic number.
	CS, // Common separator.
	NSM, // Nonspacing mark.
	BN, // Boundary neutral.
	B, // Paragraph separator.
	S, // Segment separator.
	WS, // White space.
	ON, // Other neutral.
	LRE,
	LRO,
	RLE,
	RLO,
	PDF,
	LRI,
	RLI,
	FSI,
	PDI,
}

Bidi_Range :: struct {
	first, last: rune,
	class:       Bidi_Class,
}

Class_Range :: struct {
	first, last: rune,
	class:       u8,
}

// The joining type of a character (ArabicShaping.txt). A mark is
// transparent by its category; each other character joins nothing.
Joining_Type :: enum u8 {
	None,
	Right, // Joins the character before it only (alef, dal, reh, waw).
	Dual, // Joins on both sides.
	Left, // Joins the character after it only.
	Join_Causing, // The tatweel and the zero width joiner: joins on both sides, has no form.
	Transparent, // A mark and a format character of no width: the letters around it join through it.
}

Joining_Range :: struct {
	first, last: rune,
	type:        Joining_Type,
}

// A primary composition: first and second compose to composed.
Composition :: struct {
	first, second, composed: rune,
}

// The presentation forms of a letter of Arabic: isolated, final, initial
// and medial; 0 for a form that Unicode does not name.
Arabic_Forms :: struct {
	character: rune,
	forms:     [4]rune,
}

// The ligature of lam with an alef: its isolated and its final form.
Lam_Alef :: struct {
	alef:            rune,
	isolated, final: rune,
}

// arabic_form_of gives the presentation form of a letter that joins the
// letter before it, the letter after it, both or neither; 0 when Unicode
// names no such form.
arabic_form_of :: proc "contextless" (character: rune, before, after: bool) -> rune {
	low, high := 0, len(arabic_forms)
	for low < high {
		middle := low + (high - low) / 2
		switch {
		case character < arabic_forms[middle].character:
			high = middle
		case character > arabic_forms[middle].character:
			low = middle + 1
		case:
			form := 0
			switch {
			case before && after:
				form = 3
			case after:
				form = 2
			case before:
				form = 1
			}
			return arabic_forms[middle].forms[form]
		}
	}
	return 0
}

// lam_alef_of gives the ligature of lam with an alef, final when the lam
// joins the letter before it; 0 for a letter that is no such alef.
lam_alef_of :: proc "contextless" (alef: rune, before: bool) -> rune {
	for entry in lam_alef_forms {
		if entry.alef == alef {
			return before ? entry.final : entry.isolated
		}
	}
	return 0
}

// The syllabic category of a character of the scripts of India
// (IndicSyllabicCategory.txt): Other for a character out of the table.
Indic_Category :: enum u8 {
	Other,
	Avagraha,
	Bindu,
	Cantillation_Mark,
	Consonant,
	Consonant_Dead,
	Consonant_Medial,
	Consonant_Placeholder,
	Consonant_Preceding_Repha,
	Consonant_With_Stacker,
	Gemination_Mark,
	Joiner,
	Modifying_Letter,
	Non_Joiner,
	Nukta,
	Number,
	Pure_Killer,
	Syllable_Modifier,
	Virama,
	Visarga,
	Vowel_Dependent,
	Vowel_Independent,
}

// The position of a mark of the scripts of India
// (IndicPositionalCategory.txt): None for a character out of the table.
Indic_Position :: enum u8 {
	None,
	Top,
	Right,
	Bottom,
	Left,
	Left_And_Right,
	Top_And_Right,
	Top_And_Left,
	Top_And_Left_And_Right,
	Top_And_Bottom,
}

Indic_Syllabic_Range :: struct {
	first, last: rune,
	category:    Indic_Category,
}

Indic_Position_Range :: struct {
	first, last: rune,
	position:    Indic_Position,
}

// A paired bracket (BidiBrackets.txt): the bracket, the bracket that pairs
// with it, and if it opens.
Bracket_Pair :: struct {
	character, pair: rune,
	opening:         bool,
}

// bracket_of gives the bracket that pairs with a character, and if the
// character opens; found is false for a character that is no paired
// bracket. U+2329 and U+232A are canonically U+3008 and U+3009: each takes
// the pair of the other form, so that either form closes the other
// (UAX #9, BD16).
bracket_of :: proc "contextless" (character: rune) -> (pair: rune, opening, found: bool) {
	wanted := character
	switch character {
	case 0x2329:
		wanted = 0x3008
	case 0x232A:
		wanted = 0x3009
	}
	low, high := 0, len(bracket_pairs)
	for low < high {
		middle := low + (high - low) / 2
		switch {
		case wanted < bracket_pairs[middle].character:
			high = middle
		case wanted > bracket_pairs[middle].character:
			low = middle + 1
		case:
			return bracket_pairs[middle].pair, bracket_pairs[middle].opening, true
		}
	}
	return 0, false, false
}

// A canonical decomposition of two characters of a syllabic script.
Syllabic_Decomposition :: struct {
	character, first, second: rune,
}

// syllabic_decomposition_of gives the canonical decomposition of a
// character of a syllabic script (the scripts of India, Khmer, Myanmar and
// the scripts of USE) into two characters, when it has one.
syllabic_decomposition_of :: proc "contextless" (character: rune) -> (first, second: rune, found: bool) {
	low, high := 0, len(syllabic_decompositions)
	for low < high {
		middle := low + (high - low) / 2
		switch {
		case character < syllabic_decompositions[middle].character:
			high = middle
		case character > syllabic_decompositions[middle].character:
			low = middle + 1
		case:
			return syllabic_decompositions[middle].first, syllabic_decompositions[middle].second, true
		}
	}
	return 0, 0, false
}

// The category of a character in the model of Khmer (the categories of
// hb-ot-shaper-khmer-machine.rl of HarfBuzz). Its values stay under 64: a
// set of them is one word of the syllable machine.
Khmer_Category :: enum u8 {
	Other,
	Consonant,
	Vowel_Independent,
	Coeng, // The subscript sign U+17D2: a virama that makes the next consonant a subscript.
	Non_Joiner,
	Joiner,
	Placeholder,
	Dotted_Circle,
	Ro, // U+179A, which forms the pre-base subscript with a coeng.
	Vowel_Above,
	Vowel_Below,
	Vowel_Pre,
	Vowel_Post,
	Robatic, // The signs above that change the register of a consonant.
	Group_X, // The signs above and the virama marks after the vowels.
	Group_Y, // The signs after the syllable: the visarga, the yuukaleapintu.
}

Khmer_Range :: struct {
	first, last: rune,
	category:    Khmer_Category,
}

// The category of a character in the model of Myanmar
// (hb-ot-shaper-myanmar-machine.rl).
Myanmar_Category :: enum u8 {
	Other,
	Consonant,
	Vowel_Independent,
	Dot_Below,
	Virama,
	Non_Joiner,
	Joiner,
	Syllable_Modifier, // The visarga and the tones of Shan.
	Placeholder,
	Dotted_Circle,
	Anusvara, // The signs above that come after the vowels: the anusvara and the vowel sign ai.
	Ra, // The ra of a kinzi.
	Consonant_With_Stacker,
	Syllable_Modifier_Post,
	Vowel_Above,
	Vowel_Below,
	Vowel_Pre,
	Vowel_Post,
	Asat,
	Medial_Ha,
	Medial_Ra,
	Medial_Wa,
	Medial_Ya,
	Pwo_Tone,
	Variation_Selector,
	Medial_La,
}

Myanmar_Range :: struct {
	first, last: rune,
	category:    Myanmar_Category,
}

// The category of a character in the Universal Shaping Engine (the
// categories of the specification of USE, hb-ot-shaper-use-machine.rl).
Universal_Category :: enum u8 {
	Other,
	Base,
	Number,
	Base_Other,
	Grapheme_Joiner, // A joiner and a mark of no width that the match leaves out.
	Consonant_Subjoined,
	Halant,
	Halant_Number,
	Non_Joiner,
	Word_Joiner,
	Repha,
	Consonant_With_Stacker,
	Invisible_Stacker,
	Sakot,
	Hieroglyph,
	Hieroglyph_Joiner,
	Hieroglyph_Segment_Begin,
	Hieroglyph_Segment_End,
	Halant_Or_Vowel_Modifier,
	Hieroglyph_Modifier,
	Hieroglyph_Mirror,
	Reordering_Killer,
	Final_Above,
	Final_Below,
	Final_Post,
	Medial_Above,
	Medial_Below,
	Medial_Post,
	Medial_Pre,
	Consonant_Modifier_Above,
	Consonant_Modifier_Below,
	Vowel_Above,
	Vowel_Below,
	Vowel_Post,
	Vowel_Pre,
	Vowel_Modifier_Above,
	Vowel_Modifier_Below,
	Vowel_Modifier_Post,
	Vowel_Modifier_Pre,
	Symbol_Modifier_Above,
	Symbol_Modifier_Below,
	Final_Modifier_Above,
	Final_Modifier_Below,
	Final_Modifier_Post,
}

Universal_Range :: struct {
	first, last: rune,
	category:    Universal_Category,
	mark:        bool, // Its general category is Mn, Mc or Me.
}

// A set of categories is one word of the syllable machine (syllable_machine.odin).
#assert(len(Khmer_Category) <= 64 && len(Myanmar_Category) <= 64 && len(Universal_Category) <= 64)

khmer_category_of :: proc "contextless" (character: rune) -> Khmer_Category {
	if index := range_index(character, khmer_category_ranges[:]); index >= 0 {
		return khmer_category_ranges[index].category
	}
	return .Other
}

myanmar_category_of :: proc "contextless" (character: rune) -> Myanmar_Category {
	if index := range_index(character, myanmar_category_ranges[:]); index >= 0 {
		return myanmar_category_ranges[index].category
	}
	return .Other
}

// universal_category_of gives the category of USE of a character of the
// blocks that the system shapes by USE, and if it is a mark.
universal_category_of :: proc "contextless" (character: rune) -> (category: Universal_Category, mark: bool) {
	if index := range_index(character, universal_category_ranges[:]); index >= 0 {
		return universal_category_ranges[index].category, universal_category_ranges[index].mark
	}
	return .Other, false
}

indic_category_of :: proc "contextless" (character: rune) -> Indic_Category {
	if index := range_index(character, indic_syllabic_ranges[:]); index >= 0 {
		return indic_syllabic_ranges[index].category
	}
	return .Other
}

indic_position_of :: proc "contextless" (character: rune) -> Indic_Position {
	if index := range_index(character, indic_position_ranges[:]); index >= 0 {
		return indic_position_ranges[index].position
	}
	return .None
}

// range_index gives the index of the range that holds a character in a
// table of ranges in order, or -1.
@(private)
range_index :: #force_inline proc "contextless" (character: rune, ranges: []$T) -> int {
	low, high := 0, len(ranges)
	for low < high {
		middle := low + (high - low) / 2
		switch {
		case character < ranges[middle].first:
			high = middle
		case character > ranges[middle].last:
			low = middle + 1
		case:
			return middle
		}
	}
	return -1
}

// bidi_class_of gives the bidirectional class of a character.
bidi_class_of :: proc "contextless" (character: rune) -> Bidi_Class {
	if index := range_index(character, bidi_class_ranges[:]); index >= 0 {
		return bidi_class_ranges[index].class
	}
	return .L
}

// is_simple says if a character is simple: the fast part places it alone,
// as the written part would (src/md/features/text_rendering.md, "Where the
// written shaping lives").
is_simple :: proc "contextless" (character: rune) -> bool {
	return range_index(character, simple_ranges[:]) >= 0
}

// is_mark says if a character is a mark (Mn or Me): it belongs to the
// character before it.
is_mark :: proc "contextless" (character: rune) -> bool {
	return range_index(character, mark_ranges[:]) >= 0
}

// combining_class_of gives the canonical combining class of a character.
combining_class_of :: proc "contextless" (character: rune) -> u8 {
	if index := range_index(character, combining_class_ranges[:]); index >= 0 {
		return combining_class_ranges[index].class
	}
	return 0
}

// joining_type_of gives the joining type of a character.
joining_type_of :: proc "contextless" (character: rune) -> Joining_Type {
	if index := range_index(character, joining_ranges[:]); index >= 0 {
		return joining_ranges[index].type
	}
	return .None
}

// mirror_of gives the mirrored form of a character, or the character.
mirror_of :: proc "contextless" (character: rune) -> rune {
	low, high := 0, len(mirror_pairs)
	for low < high {
		middle := low + (high - low) / 2
		switch {
		case character < mirror_pairs[middle][0]:
			high = middle
		case character > mirror_pairs[middle][0]:
			low = middle + 1
		case:
			return mirror_pairs[middle][1]
		}
	}
	return character
}

// compose gives the primary composition of two characters; found is false
// when Unicode names none.
compose :: proc "contextless" (first, second: rune) -> (composed: rune, found: bool) {
	low, high := 0, len(compositions)
	for low < high {
		middle := low + (high - low) / 2
		entry := compositions[middle]
		switch {
		case first < entry.first || first == entry.first && second < entry.second:
			high = middle
		case first > entry.first || second > entry.second:
			low = middle + 1
		case:
			return entry.composed, true
		}
	}
	return 0, false
}
