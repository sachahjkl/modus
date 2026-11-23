package resources

import "core:fmt"
import "core:strings"

// The categories of the shapers of Khmer, Myanmar and the Universal Shaping
// Engine (src/md/features/written_shaping.md, "Khmer, Myanmar and the
// Universal Shaping Engine"). Each model reads its own category of a
// character: the rules of the generators of HarfBuzz 12.3.0
// (gen-indic-table.py for Khmer and Myanmar, gen-use-table.py for USE) over
// the Unicode Character Database, with the changes that those generators
// make to it. The output of those generators, run on the same database,
// gives the same categories.

// A name and the name that it stands for.
@(private = "file")
Name_Pair :: struct {
	name, value: string,
}

@(private = "file")
name_of :: proc(pairs: []Name_Pair, name: string) -> (value: string, found: bool) {
	for pair in pairs {
		if pair.name == name {
			return pair.value, true
		}
	}
	return "", false
}

// A run of code points.
@(private = "file")
Code_Range :: struct {
	first, last: rune,
}

// The blocks of the Khmer model, and of the Myanmar model, as
// gen-indic-table.py allows them (ALLOWED_BLOCKS). Khmer Symbols is not
// one of them.
@(private = "file")
KHMER_BLOCKS := [?]Code_Range{{0x1780, 0x17FF}}
@(private = "file")
MYANMAR_BLOCKS := [?]Code_Range{{0x1000, 0x109F}, {0xA9E0, 0xA9FF}, {0xAA60, 0xAA7F}}
// The characters of other blocks that a syllable of Khmer or Myanmar holds:
// the joiners, the placeholders of the specification of Myanmar, the dotted
// circle and the variation selectors.
@(private = "file")
INDIC_SHARED := [?]Code_Range{{0x200C, 0x200D}, {0x2015, 0x2015}, {0x2022, 0x2022}, {0x25CC, 0x25CC}, {0x25FB, 0x25FE}, {0xFE00, 0xFE0F}}
// The blocks of the scripts that the system shapes by USE: Tibetan,
// Balinese, Sundanese and its supplement, Javanese; then the characters of
// other blocks that their syllables hold.
@(private = "file")
UNIVERSAL_BLOCKS := [?]Code_Range{{0x0F00, 0x0FFF}, {0x1B00, 0x1B7F}, {0x1B80, 0x1BBF}, {0x1CC0, 0x1CCF}, {0xA980, 0xA9DF}, {0x034F, 0x034F}, {0x200C, 0x200D}, {0x25CC, 0x25CC}, {0xFE00, 0xFE0F}}

// The category of HarfBuzz for each Indic syllabic category
// (gen-indic-table.py, category_map).
@(private = "file")
indic_category_names := [?]Name_Pair {
	{"Other", "X"},
	{"Avagraha", "Symbol"},
	{"Bindu", "SM"},
	{"Brahmi_Joining_Number", "PLACEHOLDER"},
	{"Cantillation_Mark", "A"},
	{"Consonant", "C"},
	{"Consonant_Dead", "C"},
	{"Consonant_Final", "CM"},
	{"Consonant_Head_Letter", "C"},
	{"Consonant_Initial_Postfixed", "C"},
	{"Consonant_Killer", "M"},
	{"Consonant_Medial", "CM"},
	{"Consonant_Placeholder", "PLACEHOLDER"},
	{"Consonant_Preceding_Repha", "Repha"},
	{"Consonant_Prefixed", "X"},
	{"Consonant_Subjoined", "CM"},
	{"Consonant_Succeeding_Repha", "CM"},
	{"Consonant_With_Stacker", "CS"},
	{"Gemination_Mark", "SM"},
	{"Invisible_Stacker", "H"},
	{"Joiner", "ZWJ"},
	{"Modifying_Letter", "X"},
	{"Non_Joiner", "ZWNJ"},
	{"Nukta", "N"},
	{"Number", "PLACEHOLDER"},
	{"Number_Joiner", "PLACEHOLDER"},
	{"Pure_Killer", "M"},
	{"Register_Shifter", "RS"},
	{"Syllable_Modifier", "SM"},
	{"Tone_Letter", "X"},
	{"Tone_Mark", "N"},
	{"Virama", "H"},
	{"Visarga", "SM"},
	{"Vowel", "V"},
	{"Vowel_Dependent", "M"},
	{"Vowel_Independent", "V"},
}

// The position of HarfBuzz for each Indic positional category
// (gen-indic-table.py, position_map).
@(private = "file")
indic_position_names := [?]Name_Pair {
	{"Not_Applicable", "END"},
	{"Left", "PRE_C"},
	{"Top", "ABOVE_C"},
	{"Bottom", "BELOW_C"},
	{"Right", "POST_C"},
	{"Bottom_And_Right", "POST_C"},
	{"Left_And_Right", "POST_C"},
	{"Top_And_Bottom", "BELOW_C"},
	{"Top_And_Bottom_And_Left", "BELOW_C"},
	{"Top_And_Bottom_And_Right", "POST_C"},
	{"Top_And_Left", "ABOVE_C"},
	{"Top_And_Left_And_Right", "POST_C"},
	{"Top_And_Right", "POST_C"},
	{"Overstruck", "AFTER_MAIN"},
}

// A change of a category for a run of characters.
@(private = "file")
Category_Change :: struct {
	first, last: rune,
	category:    string,
}

// The changes of gen-indic-table.py (category_overrides) to the categories
// of Khmer, Myanmar and the characters that their syllables share.
@(private = "file")
indic_category_changes := [?]Category_Change {
	{0xFE00, 0xFE0F, "VS"},
	{0x2015, 0x2015, "PLACEHOLDER"},
	{0x2022, 0x2022, "PLACEHOLDER"},
	{0x25FB, 0x25FE, "PLACEHOLDER"},
	{0x25CC, 0x25CC, "DOTTEDCIRCLE"},
	// Khmer.
	{0x179A, 0x179A, "Ra"},
	{0x17CC, 0x17CC, "Robatic"},
	{0x17C9, 0x17CA, "Robatic"},
	{0x17C6, 0x17C6, "Xgroup"},
	{0x17CB, 0x17CB, "Xgroup"},
	{0x17CD, 0x17D1, "Xgroup"},
	{0x17C7, 0x17C8, "Ygroup"},
	{0x17DD, 0x17DD, "Ygroup"},
	{0x17D3, 0x17D3, "Ygroup"},
	{0x17D9, 0x17D9, "PLACEHOLDER"},
	// Myanmar.
	{0x104E, 0x104E, "C"},
	{0x1004, 0x1004, "Ra"},
	{0x101B, 0x101B, "Ra"},
	{0x105A, 0x105A, "Ra"},
	{0x1032, 0x1032, "A"},
	{0x1036, 0x1036, "A"},
	{0x103A, 0x103A, "As"},
	{0x103E, 0x103E, "MH"},
	{0x1060, 0x1060, "ML"},
	{0x103C, 0x103C, "MR"},
	{0x103D, 0x103D, "MW"},
	{0x1082, 0x1082, "MW"},
	{0x103B, 0x103B, "MY"},
	{0x105E, 0x105F, "MY"},
	{0x1063, 0x1064, "PT"},
	{0x1069, 0x106D, "PT"},
	{0xAA7B, 0xAA7B, "PT"},
	{0x1038, 0x1038, "SM"},
	{0x1087, 0x108D, "SM"},
	{0x108F, 0x108F, "SM"},
	{0x109A, 0x109C, "SM"},
	{0x104A, 0x104A, "PLACEHOLDER"},
}

// The members of text_rendering.Khmer_Category for the categories of
// HarfBuzz that the grammar of Khmer names; each other is Other.
@(private = "file")
khmer_members := [?]Name_Pair {
	{"C", "Consonant"},
	{"V", "Vowel_Independent"},
	{"H", "Coeng"},
	{"ZWNJ", "Non_Joiner"},
	{"ZWJ", "Joiner"},
	{"PLACEHOLDER", "Placeholder"},
	{"DOTTEDCIRCLE", "Dotted_Circle"},
	{"Ra", "Ro"},
	{"VAbv", "Vowel_Above"},
	{"VBlw", "Vowel_Below"},
	{"VPre", "Vowel_Pre"},
	{"VPst", "Vowel_Post"},
	{"Robatic", "Robatic"},
	{"Xgroup", "Group_X"},
	{"Ygroup", "Group_Y"},
}

// The members of text_rendering.Myanmar_Category; each other is Other.
@(private = "file")
myanmar_members := [?]Name_Pair {
	{"C", "Consonant"},
	{"V", "Vowel_Independent"},
	{"N", "Dot_Below"},
	{"H", "Virama"},
	{"ZWNJ", "Non_Joiner"},
	{"ZWJ", "Joiner"},
	{"SM", "Syllable_Modifier"},
	{"PLACEHOLDER", "Placeholder"},
	{"DOTTEDCIRCLE", "Dotted_Circle"},
	{"A", "Anusvara"},
	{"Ra", "Ra"},
	{"CS", "Consonant_With_Stacker"},
	{"SMPst", "Syllable_Modifier_Post"},
	{"VAbv", "Vowel_Above"},
	{"VBlw", "Vowel_Below"},
	{"VPre", "Vowel_Pre"},
	{"VPst", "Vowel_Post"},
	{"As", "Asat"},
	{"MH", "Medial_Ha"},
	{"MR", "Medial_Ra"},
	{"MW", "Medial_Wa"},
	{"MY", "Medial_Ya"},
	{"PT", "Pwo_Tone"},
	{"VS", "Variation_Selector"},
	{"ML", "Medial_La"},
}

// The Indic categories of the files ms-use of HarfBuzz, which the USE
// generator takes after those of Unicode, for the blocks of USE that the
// system shapes (IndicSyllabicCategory-Additional.txt).
@(private = "file")
universal_syllabic_changes := [?]Category_Change {
	{0x25CC, 0x25CC, "Consonant"},
	{0x0F7F, 0x0F7F, "Consonant_Dead"},
	{0x0F71, 0x0F71, "Nukta"},
	{0x0F00, 0x0F01, "Consonant"},
	{0x0F04, 0x0F06, "Consonant"},
	{0x0F39, 0x0F39, "Nukta"},
	{0xFE00, 0xFE0F, "Modifying_Letter"},
	{0x0F86, 0x0F87, "Tone_Mark"},
	{0x1B6B, 0x1B73, "Symbol_Modifier"},
	// gen-use-table.py, map_to_use: these have no syllabic category in
	// Unicode, and a position.
	{0x0F18, 0x0F19, "Vowel_Dependent"},
	{0x0F3E, 0x0F3F, "Vowel_Dependent"},
}

// The positions of IndicPositionalCategory-Additional.txt for the blocks
// of USE that the system shapes.
@(private = "file")
universal_position_changes := [?]Category_Change {
	{0x0F72, 0x0F72, "Bottom"},
	{0x0F7A, 0x0F7D, "Bottom"},
	{0x0F80, 0x0F80, "Bottom"},
	{0xA9BF, 0xA9BF, "Bottom"},
	{0x0F74, 0x0F74, "Top"},
	{0xA9BE, 0xA9BE, "Right"},
	{0x1B6C, 0x1B6C, "Top"},
}

// The members of text_rendering.Universal_Category, by the name of the
// category in the specification of USE.
@(private = "file")
universal_members := [?]Name_Pair {
	{"O", "Other"},
	{"B", "Base"},
	{"N", "Number"},
	{"GB", "Base_Other"},
	{"CGJ", "Grapheme_Joiner"},
	{"SUB", "Consonant_Subjoined"},
	{"H", "Halant"},
	{"HN", "Halant_Number"},
	{"ZWNJ", "Non_Joiner"},
	{"WJ", "Word_Joiner"},
	{"R", "Repha"},
	{"CS", "Consonant_With_Stacker"},
	{"IS", "Invisible_Stacker"},
	{"Sk", "Sakot"},
	{"G", "Hieroglyph"},
	{"J", "Hieroglyph_Joiner"},
	{"SB", "Hieroglyph_Segment_Begin"},
	{"SE", "Hieroglyph_Segment_End"},
	{"HVM", "Halant_Or_Vowel_Modifier"},
	{"HM", "Hieroglyph_Modifier"},
	{"HR", "Hieroglyph_Mirror"},
	{"RK", "Reordering_Killer"},
	{"FAbv", "Final_Above"},
	{"FBlw", "Final_Below"},
	{"FPst", "Final_Post"},
	{"MAbv", "Medial_Above"},
	{"MBlw", "Medial_Below"},
	{"MPst", "Medial_Post"},
	{"MPre", "Medial_Pre"},
	{"CMAbv", "Consonant_Modifier_Above"},
	{"CMBlw", "Consonant_Modifier_Below"},
	{"VAbv", "Vowel_Above"},
	{"VBlw", "Vowel_Below"},
	{"VPst", "Vowel_Post"},
	{"VPre", "Vowel_Pre"},
	{"VMAbv", "Vowel_Modifier_Above"},
	{"VMBlw", "Vowel_Modifier_Below"},
	{"VMPst", "Vowel_Modifier_Post"},
	{"VMPre", "Vowel_Modifier_Pre"},
	{"SMAbv", "Symbol_Modifier_Above"},
	{"SMBlw", "Symbol_Modifier_Below"},
	{"FMAbv", "Final_Modifier_Above"},
	{"FMBlw", "Final_Modifier_Below"},
	{"FMPst", "Final_Modifier_Post"},
}

// The properties of the database that the categories read, by code point.
@(private = "file")
Syllabic_Sources :: struct {
	syllabic:   map[rune]string, // IndicSyllabicCategory.txt.
	positional: map[rune]string, // IndicPositionalCategory.txt.
	general:    map[rune]string, // DerivedGeneralCategory.txt.
	joining:    map[rune]string, // DerivedJoiningType.txt.
	ignorable:  map[rune]bool, // Default_Ignorable_Code_Point of DerivedCoreProperties.txt.
}

@(private = "file")
lines_in_ranges :: proc(lines: []Unicode_Line, ranges: []Code_Range, values: ^map[rune]string) {
	for line in lines {
		for range in ranges {
			for character in max(line.first, range.first) ..= min(line.last, range.last) {
				values[character] = line.fields[0]
			}
		}
	}
}

// indic_model_category gives the category of HarfBuzz of a character of
// Khmer or Myanmar (gen-indic-table.py): ok is false for a category that
// the generator does not know.
@(private = "file")
indic_model_category :: proc(sources: ^Syllabic_Sources, character: rune) -> (category: string, ok: bool) {
	category = name_of(indic_category_names[:], sources.syllabic[character] or_else "Other") or_return
	position_name := sources.positional[character] or_else "Not_Applicable"
	if category == "SM" && position_name == "Not_Applicable" {
		category = "SMPst"
	}
	position := name_of(indic_position_names[:], position_name) or_return
	for change in indic_category_changes {
		if character >= change.first && character <= change.last {
			category = change.category
		}
	}
	if category == "M" || category == "MPst" {
		switch position {
		case "PRE_C":
			return "VPre", true
		case "ABOVE_C":
			return "VAbv", true
		case "BELOW_C":
			return "VBlw", true
		case "POST_C":
			return "VPst", true
		}
		return "", false
	}
	return category, true
}

@(private = "file")
one_of :: proc(value: string, values: ..string) -> bool {
	for each in values {
		if value == each {
			return true
		}
	}
	return false
}

@(private = "file")
one_of_rune :: proc(character: rune, values: ..rune) -> bool {
	for each in values {
		if character == each {
			return true
		}
	}
	return false
}

@(private = "file")
Position_Group :: struct {
	suffix:    string,
	positions: []string,
}

// position_suffix gives the suffix of the one position group that holds a
// positional category; ok is false for none or more than one.
@(private = "file")
position_suffix :: proc(positional: string, groups: []Position_Group) -> (suffix: string, ok: bool) {
	count := 0
	for group in groups {
		for position in group.positions {
			if position == positional {
				suffix = group.suffix
				count += 1
			}
		}
	}
	return suffix, count == 1
}

// universal_model_category gives the category of USE of a character
// (gen-use-table.py, map_to_use): ok is false when the rules give no
// category, or more than one, as the generator stops then.
@(private = "file")
universal_model_category :: proc(sources: ^Syllabic_Sources, character: rune) -> (category: string, ok: bool) {
	_, has_syllabic := sources.syllabic[character]
	_, has_positional := sources.positional[character]
	_, has_joining := sources.joining[character]
	changed := false
	for change in universal_syllabic_changes {
		changed ||= character >= change.first && character <= change.last
	}
	for change in universal_position_changes {
		changed ||= character >= change.first && character <= change.last
	}
	if !has_syllabic && !has_positional && !has_joining && !sources.ignorable[character] && !changed {
		// The generator reads only the characters that these files name:
		// each other is O.
		return "O", true
	}
	syllabic := sources.syllabic[character] or_else "Other"
	positional := sources.positional[character] or_else "Not_Applicable"
	for change in universal_syllabic_changes {
		if character >= change.first && character <= change.last {
			syllabic = change.category
		}
	}
	for change in universal_position_changes {
		if character >= change.first && character <= change.last {
			positional = change.category
		}
	}
	general := sources.general[character] or_else "Cn"
	ignorable := sources.ignorable[character]
	joining := sources.joining[character] or_else "U"
	is_base := one_of(syllabic, "Number", "Consonant", "Consonant_Head_Letter", "Tone_Letter", "Vowel_Independent") || one_of(joining, "C", "D", "L", "R") && syllabic != "Joiner" || general == "Lo" && one_of(syllabic, "Avagraha", "Bindu", "Consonant_Final", "Consonant_Medial", "Consonant_Subjoined", "Vowel", "Vowel_Dependent")
	is_base_other := syllabic == "Consonant_Placeholder" || one_of_rune(character, 0x2015, 0x2022, 0x25FB, 0x25FC, 0x25FD, 0x25FE)
	is_joiner := syllabic == "Joiner" || ignorable && one_of(general, "Mc", "Me", "Mn")
	is_symbol_modifier := syllabic == "Symbol_Modifier"
	is_word_joiner := ignorable && !one_of_rune(character, 0x115F, 0x1160, 0x3164, 0xFFA0, 0x1BCA0, 0x1BCA1, 0x1BCA2, 0x1BCA3) && syllabic == "Other" && !is_joiner || general == "Cn"
	is_sakot := character == 0x1A60
	is_halant_or_vowel_modifier := character == 0x0DCA
	found := make([dynamic]string, context.temp_allocator)
	add :: proc(found: ^[dynamic]string, holds: bool, name: string) {
		if holds {
			append(found, name)
		}
	}
	add(&found, is_base, "B")
	add(&found, syllabic == "Brahmi_Joining_Number", "N")
	add(&found, is_base_other, "GB")
	add(&found, is_joiner, "CGJ")
	add(&found, syllabic == "Consonant_Final" && general != "Lo" || syllabic == "Consonant_Succeeding_Repha", "F")
	add(&found, syllabic == "Syllable_Modifier", "FM")
	add(&found, syllabic == "Consonant_Medial" && general != "Lo" || syllabic == "Consonant_Initial_Postfixed", "M")
	add(&found, one_of(syllabic, "Nukta", "Gemination_Mark", "Consonant_Killer"), "CM")
	add(&found, syllabic == "Consonant_Subjoined" && general != "Lo", "SUB")
	add(&found, syllabic == "Consonant_With_Stacker", "CS")
	add(&found, syllabic == "Virama" && !is_halant_or_vowel_modifier, "H")
	add(&found, is_halant_or_vowel_modifier, "HVM")
	add(&found, syllabic == "Number_Joiner", "HN")
	add(&found, syllabic == "Invisible_Stacker" && !is_sakot, "IS")
	add(&found, syllabic == "Hieroglyph", "G")
	add(&found, syllabic == "Hieroglyph_Modifier", "HM")
	add(&found, syllabic == "Hieroglyph_Mirror", "HR")
	add(&found, syllabic == "Hieroglyph_Joiner", "J")
	add(&found, one_of(syllabic, "Hieroglyph_Mark_Begin", "Hieroglyph_Segment_Begin"), "SB")
	add(&found, one_of(syllabic, "Hieroglyph_Mark_End", "Hieroglyph_Segment_End"), "SE")
	add(&found, syllabic == "Non_Joiner", "ZWNJ")
	add(&found, (general == "Po" || one_of(syllabic, "Consonant_Dead", "Joiner", "Modifying_Letter", "Other")) && !is_base && !is_base_other && !is_joiner && !is_symbol_modifier && !is_word_joiner, "O")
	add(&found, syllabic == "Reordering_Killer", "RK")
	add(&found, one_of(syllabic, "Consonant_Preceding_Repha", "Consonant_Prefixed"), "R")
	add(&found, is_sakot, "Sk")
	add(&found, is_symbol_modifier, "SM")
	add(&found, syllabic == "Pure_Killer" || general != "Lo" && one_of(syllabic, "Vowel", "Vowel_Dependent"), "V")
	add(&found, one_of(syllabic, "Tone_Mark", "Cantillation_Mark", "Register_Shifter", "Visarga") || general != "Lo" && syllabic == "Bindu", "VM")
	add(&found, is_word_joiner, "WJ")
	if len(found) != 1 {
		return "", false
	}
	category = found[0]
	// The position of the categories that have one (use_positions).
	suffix := ""
	switch category {
	case "F":
		suffix = position_suffix(positional, {{"Abv", {"Top"}}, {"Blw", {"Bottom"}}, {"Pst", {"Right"}}}) or_return
	case "M":
		suffix = position_suffix(positional, {{"Abv", {"Top"}}, {"Blw", {"Bottom", "Bottom_And_Left", "Bottom_And_Right"}}, {"Pst", {"Right"}}, {"Pre", {"Left", "Top_And_Bottom_And_Left"}}}) or_return
	case "CM":
		suffix = position_suffix(positional, {{"Abv", {"Top"}}, {"Blw", {"Bottom", "Overstruck"}}}) or_return
	case "V":
		suffix = position_suffix(positional, {{"Abv", {"Top", "Top_And_Bottom", "Top_And_Bottom_And_Right", "Top_And_Right"}}, {"Blw", {"Bottom", "Overstruck", "Bottom_And_Right"}}, {"Pst", {"Right"}}, {"Pre", {"Left", "Top_And_Left", "Top_And_Left_And_Right", "Left_And_Right"}}}) or_return
	case "VM":
		suffix = position_suffix(positional, {{"Abv", {"Top"}}, {"Blw", {"Bottom", "Overstruck"}}, {"Pst", {"Right"}}, {"Pre", {"Left"}}}) or_return
	case "SM":
		suffix = position_suffix(positional, {{"Abv", {"Top"}}, {"Blw", {"Bottom"}}}) or_return
	case "FM":
		suffix = position_suffix(positional, {{"Abv", {"Top"}}, {"Blw", {"Bottom"}}, {"Pst", {"Not_Applicable"}}}) or_return
	}
	return strings.concatenate({category, suffix}, context.temp_allocator), true
}

// syllabic_categories_write writes the tables of the categories of Khmer,
// Myanmar and USE. false when a file does not read or a character takes no
// category: the generators of HarfBuzz stop on such a character too.
@(private)
syllabic_categories_write :: proc(out: ^strings.Builder, folder: string, category_lines, joining_lines: []Unicode_Line) -> bool {
	syllabic_lines, _, syllabic_ok := unicode_lines_read(folder, "IndicSyllabicCategory.txt")
	positional_lines, _, positional_ok := unicode_lines_read(folder, "IndicPositionalCategory.txt")
	core_lines, _, core_ok := unicode_lines_read(folder, "DerivedCoreProperties.txt")
	if !syllabic_ok || !positional_ok || !core_ok {
		return false
	}
	all := make([dynamic]Code_Range, context.temp_allocator)
	append(&all, ..KHMER_BLOCKS[:])
	append(&all, ..MYANMAR_BLOCKS[:])
	append(&all, ..INDIC_SHARED[:])
	append(&all, ..UNIVERSAL_BLOCKS[:])
	sources := Syllabic_Sources {
		syllabic   = make(map[rune]string, 4096, context.temp_allocator),
		positional = make(map[rune]string, 4096, context.temp_allocator),
		general    = make(map[rune]string, 4096, context.temp_allocator),
		joining    = make(map[rune]string, 4096, context.temp_allocator),
		ignorable  = make(map[rune]bool, 256, context.temp_allocator),
	}
	lines_in_ranges(syllabic_lines[:], all[:], &sources.syllabic)
	lines_in_ranges(positional_lines[:], all[:], &sources.positional)
	lines_in_ranges(category_lines, all[:], &sources.general)
	lines_in_ranges(joining_lines, all[:], &sources.joining)
	for line in core_lines {
		if line.fields[0] != "Default_Ignorable_Code_Point" {
			continue
		}
		for range in all {
			for character in max(line.first, range.first) ..= min(line.last, range.last) {
				sources.ignorable[character] = true
			}
		}
	}
	// Khmer and Myanmar: the categories that their grammar names.
	Indic_Table :: struct {
		name, type, comment: string,
		blocks:              []Code_Range,
		members:             []Name_Pair,
	}
	indic_tables := [2]Indic_Table {
		{"khmer_category_ranges", "Khmer_Range", "The category of the model of Khmer of each character that a syllable of Khmer holds and that is not Other (gen-indic-table.py of HarfBuzz)", KHMER_BLOCKS[:], khmer_members[:]},
		{"myanmar_category_ranges", "Myanmar_Range", "The category of the model of Myanmar of each character that a syllable of Myanmar holds and that is not Other (gen-indic-table.py of HarfBuzz)", MYANMAR_BLOCKS[:], myanmar_members[:]},
	}
	for table in indic_tables {
		ranges := make([dynamic]Value_Range, context.temp_allocator)
		blocks := make([dynamic]Code_Range, context.temp_allocator)
		append(&blocks, ..table.blocks)
		append(&blocks, ..INDIC_SHARED[:])
		for block in blocks {
			for character in block.first ..= block.last {
				category, ok := indic_model_category(&sources, character)
				if !ok {
					fmt.eprintfln("modustool: U+%04X takes no category of HarfBuzz: %q, %q", int(character), sources.syllabic[character], sources.positional[character])
					return false
				}
				if member, named := name_of(table.members, category); named {
					append(&ranges, Value_Range{character, character, member})
				}
			}
		}
		ranges_write(out, table.comment, table.name, table.type, ranges_merge(ranges), ".")
	}
	// USE: each character of its blocks, and if it is a mark (Mn, Mc, Me):
	// a non-joiner before a mark is left out of the match
	// (hb-ot-shaper-use-machine.rl, find_syllables_use).
	universal := make([dynamic]Value_Range, context.temp_allocator)
	for block in UNIVERSAL_BLOCKS {
		for character in block.first ..= block.last {
			category, ok := universal_model_category(&sources, character)
			if !ok {
				fmt.eprintfln("modustool: U+%04X takes no category of USE, or more than one", int(character))
				return false
			}
			general := sources.general[character] or_else "Cn"
			mark := general == "Mn" || general == "Mc" || general == "Me"
			if category == "O" && !mark {
				continue
			}
			append(&universal, Value_Range{character, character, fmt.tprintf(".%s, %v", name_of(universal_members[:], category) or_else "", mark)})
		}
	}
	ranges_write(out, "The category of USE of each character of the blocks that the system shapes by USE, and if it is a mark (gen-use-table.py of HarfBuzz); each other character of those blocks is Other and no mark", "universal_category_ranges", "Universal_Range", ranges_merge(universal), "")
	// The spacing marks (Mc) of the blocks of these models: the
	// normalization of HarfBuzz reads Mn, Mc and Me as marks.
	spacing := make([dynamic]Value_Range, context.temp_allocator)
	for block in all {
		for character in block.first ..= block.last {
			if sources.general[character] == "Mc" {
				append(&spacing, Value_Range{character, character, "Mc"})
			}
		}
	}
	merged := ranges_merge(spacing)
	fmt.sbprintfln(out, "\n// The spacing marks (Mc) of the blocks of Khmer, Myanmar and USE (DerivedGeneralCategory.txt): %d ranges.", len(merged))
	fmt.sbprintln(out, "@(rodata)\nsyllabic_spacing_mark_ranges := [?]Character_Range {")
	for range in merged {
		fmt.sbprintfln(out, "\t{{0x%04X, 0x%04X}},", int(range.first), int(range.last))
	}
	fmt.sbprintln(out, "}")
	return true
}