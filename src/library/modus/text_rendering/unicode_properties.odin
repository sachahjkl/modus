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
