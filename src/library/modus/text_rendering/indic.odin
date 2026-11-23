package text_rendering

import "modus:contract/text_encoding"
import "modus:vector_font"

// The shaper of the scripts of India (src/md/features/written_shaping.md,
// "The scripts of India"): the OpenType specification of the Indic scripts,
// as HarfBuzz implements it, over the engine of the lookups
// (vector_font.engine_stage). A syllable is read from the text once; each
// character takes a position, the syllable is sorted by them, its glyphs
// go through the basic features, the final reordering and the
// presentation features, and come out as one Shaped: its first glyph as
// the base, the others after it.

// The most characters of one syllable, the dotted circle of a syllable
// with no base too: its glyphs fit the marks of a Shaped.
INDIC_SYLLABLE_LIMIT :: CLUSTER_MARK_LIMIT

@(private)
ZERO_WIDTH_NON_JOINER :: rune(0x200C)
@(private)
ZERO_WIDTH_JOINER :: rune(0x200D)

// The scripts of India that the shaper takes: one block of 128 characters
// each, from U+0900.
Indic_Script :: enum u8 {
	Devanagari,
	Bengali,
	Gurmukhi,
	Gujarati,
	Oriya,
	Tamil,
	Telugu,
	Kannada,
	Malayalam,
}

// Where the final reordering puts the reph.
@(private)
Reph_Position :: enum u8 {
	After_Main,
	Before_Sub,
	After_Sub,
	Before_Post,
	After_Post,
}

// How a reph forms.
@(private)
Reph_Mode :: enum u8 {
	Implicit, // Ra and a virama at the start of a syllable with a consonant after them.
	Explicit, // Ra, a virama and a zero width joiner.
	Logical, // A character of its own (U+0D4E, the dot reph of Malayalam).
}

// The row of a script: what the specification leaves to each script.
@(private)
Indic_Script_Row :: struct {
	tags:              [2]vector_font.Feature_Tag, // The tag of the second form of the specification, then of the first.
	virama, ra:        rune,
	reph_position:     Reph_Position,
	reph_mode:         Reph_Mode,
	below_before_base: bool, // blwf applies before the base too, not only after it.
}

@(rodata, private)
indic_script_rows := [Indic_Script]Indic_Script_Row {
	.Devanagari = {{{'d', 'e', 'v', '2'}, {'d', 'e', 'v', 'a'}}, 0x094D, 0x0930, .Before_Post, .Implicit, true},
	.Bengali    = {{{'b', 'n', 'g', '2'}, {'b', 'e', 'n', 'g'}}, 0x09CD, 0x09B0, .After_Sub, .Implicit, true},
	.Gurmukhi   = {{{'g', 'u', 'r', '2'}, {'g', 'u', 'r', 'u'}}, 0x0A4D, 0x0A30, .Before_Sub, .Implicit, true},
	.Gujarati   = {{{'g', 'j', 'r', '2'}, {'g', 'u', 'j', 'r'}}, 0x0ACD, 0x0AB0, .Before_Post, .Implicit, true},
	.Oriya      = {{{'o', 'r', 'y', '2'}, {'o', 'r', 'y', 'a'}}, 0x0B4D, 0x0B30, .After_Main, .Implicit, true},
	.Tamil      = {{{'t', 'm', 'l', '2'}, {'t', 'a', 'm', 'l'}}, 0x0BCD, 0x0BB0, .After_Post, .Implicit, true},
	.Telugu     = {{{'t', 'e', 'l', '2'}, {'t', 'e', 'l', 'u'}}, 0x0C4D, 0x0C30, .After_Post, .Explicit, false},
	.Kannada    = {{{'k', 'n', 'd', '2'}, {'k', 'n', 'd', 'a'}}, 0x0CCD, 0x0CB0, .After_Post, .Implicit, false},
	.Malayalam  = {{{'m', 'l', 'm', '2'}, {'m', 'l', 'y', 'm'}}, 0x0D4D, 0x0D30, .After_Main, .Logical, true},
}

// indic_script_of_character gives the script of a character of the blocks
// that the shaper takes.
@(private)
indic_script_of_character :: #force_inline proc "contextless" (character: rune) -> (script: Indic_Script, ok: bool) {
	if character < 0x0900 || character > 0x0D7F {
		return {}, false
	}
	return Indic_Script((character - 0x0900) >> 7), true
}

// is_indic_character says if the Indic shaper takes a character.
@(private)
is_indic_character :: #force_inline proc "contextless" (character: rune) -> bool {
	_, ok := indic_script_of_character(character)
	return ok
}

// The kind of a character in a syllable.
@(private)
Indic_Kind :: enum u8 {
	Other,
	Consonant, // A consonant, a placeholder, the dotted circle, an independent vowel: each can be the base.
	Repha, // The dot reph of Malayalam.
	Nukta,
	Virama,
	Matra, // A dependent vowel.
	Modifier, // A bindu, a visarga, a cantillation mark.
	Joiner,
	Non_Joiner,
}

@(private)
indic_kind_of :: proc "contextless" (character: rune) -> Indic_Kind {
	switch character {
	case DOTTED_CIRCLE:
		return .Consonant
	case ZERO_WIDTH_JOINER:
		return .Joiner
	case ZERO_WIDTH_NON_JOINER:
		return .Non_Joiner
	}
	#partial switch indic_category_of(character) {
	case .Consonant, .Consonant_Dead, .Consonant_Placeholder, .Consonant_With_Stacker, .Vowel_Independent:
		return .Consonant
	case .Consonant_Preceding_Repha:
		return .Repha
	case .Nukta:
		return .Nukta
	case .Virama, .Pure_Killer:
		return .Virama
	case .Vowel_Dependent:
		return .Matra
	case .Bindu, .Visarga, .Syllable_Modifier, .Cantillation_Mark, .Gemination_Mark, .Consonant_Medial:
		return .Modifier
	}
	return .Other
}

// The positions of the characters of a syllable, in the order in which
// the first reordering sorts them (the OpenType specification of the
// Indic scripts, and HarfBuzz).
@(private)
Indic_Place :: enum u8 {
	Start,
	Ra_To_Become_Reph,
	Pre_Matra,
	Pre_Consonant,
	Base_Consonant,
	After_Main,
	Above_Consonant,
	Before_Sub,
	Below_Consonant,
	After_Sub,
	Before_Post,
	Post_Consonant,
	After_Post,
	Modifier,
	End,
}

// matra_place gives the position of a dependent vowel by the side of the
// consonant where it draws, as each script orders it (HarfBuzz,
// matra_position_indic).
@(private)
matra_place :: proc "contextless" (script: Indic_Script, character: rune) -> Indic_Place {
	right :: proc "contextless" (script: Indic_Script, character: rune) -> Indic_Place {
		switch script {
		case .Devanagari:
			return .After_Sub
		case .Bengali, .Gurmukhi, .Gujarati, .Oriya, .Tamil, .Malayalam:
			return .After_Post
		case .Telugu:
			return character <= 0x0C42 ? .Before_Sub : .After_Sub
		case .Kannada:
			return character < 0x0CC3 || character > 0x0CD6 ? .Before_Sub : .After_Sub
		}
		return .After_Sub
	}
	top :: proc "contextless" (script: Indic_Script) -> Indic_Place {
		#partial switch script {
		case .Gurmukhi:
			return .After_Post
		case .Oriya:
			return .After_Main
		case .Telugu, .Kannada:
			return .Before_Sub
		}
		return .After_Sub
	}
	bottom :: proc "contextless" (script: Indic_Script) -> Indic_Place {
		#partial switch script {
		case .Gurmukhi, .Gujarati, .Tamil, .Malayalam:
			return .After_Post
		case .Telugu, .Kannada:
			return .Before_Sub
		}
		return .After_Sub
	}
	switch indic_position_of(character) {
	case .Left, .Left_And_Right, .Top_And_Left, .Top_And_Left_And_Right:
		return .Pre_Matra
	case .Right, .Top_And_Right:
		return right(script, character)
	case .Top:
		return top(script)
	case .Bottom, .Top_And_Bottom:
		return bottom(script)
	case .None:
	}
	return .End
}

// A syllable of a text: its characters, decomposed, and the first byte of
// the character of the text that each comes from.
@(private)
Indic_Syllable :: struct {
	characters: [INDIC_SYLLABLE_LIMIT]rune,
	places:     [INDIC_SYLLABLE_LIMIT]u32,
	count:      int,
	script:     Indic_Script,
	end:        int, // The byte after it.
}

// indic_decomposed gives the parts that the shaper splits a character
// into: a vowel sign of two parts (ো is ে and া), and a letter with a nukta
// that Unicode composes no more (क़). Each stays whole when HarfBuzz keeps
// it whole: a letter with a nukta that composes (ऩ), the rra of Devanagari
// and of Bengali, the au of Tamil, and the yya of Bengali, which HarfBuzz
// composes again.
@(private)
indic_decomposed :: proc "contextless" (character: rune, parts: ^[3]rune) -> (count: int) {
	switch character {
	case 0x0931, 0x09DC, 0x09DD, 0x09DF, 0x0B94:
		parts[0] = character
		return 1
	}
	first, second, found := indic_decomposition_of(character)
	if !found {
		parts[0] = character
		return 1
	}
	composed, composes := compose(first, second)
	if indic_category_of(character) != .Vowel_Dependent && composes && composed == character {
		parts[0] = character
		return 1
	}
	// A part that is itself of two parts (Kannada: ೋ is ೊ and ೕ).
	if inner_first, inner_second, inner := indic_decomposition_of(first); inner && indic_category_of(character) == .Vowel_Dependent {
		parts[0], parts[1], parts[2] = inner_first, inner_second, second
		return 3
	}
	parts[0], parts[1] = first, second
	return 2
}

// indic_syllable_read reads the syllable that starts at a byte of a text.
// Each byte is decoded once. ok is false at the end of the text and for a
// character that the Indic shaper does not take.
@(private)
indic_syllable_read :: proc "contextless" (text: []u8, place: int) -> (syllable: Indic_Syllable, ok: bool) {
	at := place
	Next :: struct {
		character: rune,
		length:    int, // 0: the end, an invalid sequence, or another script.
		kind:      Indic_Kind,
	}
	// peek decodes the character at a byte: a character of the script of
	// the syllable, or a joiner.
	peek :: proc "contextless" (text: []u8, at: int, script: Indic_Script) -> (next: Next) {
		decoded, length, valid := text_encoding.character_decode(text, at)
		if length == 0 || !valid {
			return {}
		}
		if decoded != ZERO_WIDTH_JOINER && decoded != ZERO_WIDTH_NON_JOINER {
			if character_script, of_india := indic_script_of_character(decoded); !of_india || character_script != script {
				return {}
			}
		}
		return {decoded, length, indic_kind_of(decoded)}
	}
	// take puts a character into the syllable, decomposed; false when it
	// does not fit, and then nothing of it is taken.
	take :: proc "contextless" (syllable: ^Indic_Syllable, character: rune, place: int) -> bool {
		parts: [3]rune
		count := indic_decomposed(character, &parts)
		if syllable.count + count > INDIC_SYLLABLE_LIMIT {
			return false
		}
		for part in parts[:count] {
			syllable.characters[syllable.count] = part
			syllable.places[syllable.count] = u32(place)
			syllable.count += 1
		}
		return true
	}
	first_character, first_length, first_valid := text_encoding.character_decode(text, at)
	if first_length == 0 || !first_valid {
		return {}, false
	}
	script, of_india := indic_script_of_character(first_character)
	if !of_india {
		return {}, false
	}
	syllable.script = script
	first := Next{first_character, first_length, indic_kind_of(first_character)}
	switch first.kind {
	case .Consonant, .Repha:
		take(&syllable, first.character, at) or_return
		at += first.length
	case .Nukta, .Virama, .Matra, .Modifier:
		// Marks with no base stand on the dotted circle.
		syllable.characters[0], syllable.places[0], syllable.count = DOTTED_CIRCLE, u32(at), 1
	case .Other, .Joiner, .Non_Joiner:
		take(&syllable, first.character, at) or_return
		syllable.end = at + first.length
		return syllable, true
	}
	next := peek(text, at, script)
	nuktas :: proc "contextless" (text: []u8, syllable: ^Indic_Syllable, at: ^int, next: ^Next) {
		for next.length > 0 && next.kind == .Nukta && take(syllable, next.character, at^) {
			at^ += next.length
			next^ = peek(text, at^, syllable.script)
		}
	}
	// The dot reph of Malayalam takes the consonant after it.
	if first.kind == .Repha && next.kind == .Consonant && take(&syllable, next.character, at) {
		at += next.length
		next = peek(text, at, script)
	}
	nuktas(text, &syllable, &at, &next)
	// The consonants that a virama joins, each with its nukta; a joiner
	// after a virama stays in the syllable, and ra, a virama and a joiner
	// are the explicit reph of Telugu.
	for next.length > 0 && next.kind == .Virama {
		after_at := at + next.length
		after := peek(text, after_at, script)
		joiner := after
		if after.kind == .Joiner || after.kind == .Non_Joiner {
			after_at += after.length
			after = peek(text, after_at, script)
		}
		if after.length == 0 || after.kind != .Consonant || syllable.count + 3 > INDIC_SYLLABLE_LIMIT {
			break
		}
		take(&syllable, next.character, at)
		at += next.length
		if joiner.kind == .Joiner || joiner.kind == .Non_Joiner {
			take(&syllable, joiner.character, at)
			at += joiner.length
		}
		take(&syllable, after.character, at)
		at = after_at + after.length
		next = peek(text, at, script)
		nuktas(text, &syllable, &at, &next)
	}
	// The dependent vowels, a final virama, a joiner after it, the
	// modifiers.
	for next.length > 0 && (next.kind == .Matra || next.kind == .Virama || next.kind == .Nukta || next.kind == .Modifier || next.kind == .Joiner || next.kind == .Non_Joiner) && take(&syllable, next.character, at) {
		at += next.length
		next = peek(text, at, script)
	}
	syllable.end = at
	return syllable, true
}

// The bits of the mask of a glyph: the features that apply to it. The
// features of the positions take the glyphs that their position chooses;
// the others take every glyph.
@(private)
INDIC_GLOBAL :: u32(1) << 0
@(private)
INDIC_REPH :: u32(1) << 1
@(private)
INDIC_HALF :: u32(1) << 2
@(private)
INDIC_BELOW :: u32(1) << 3
@(private)
INDIC_ABOVE :: u32(1) << 4
@(private)
INDIC_POST :: u32(1) << 5
@(private)
INDIC_PREF :: u32(1) << 6
@(private)
INDIC_INIT :: u32(1) << 7

// The basic features, one stage each, in the order of the specification.
@(rodata, private)
indic_basic_stages := [?]vector_font.Engine_Feature {
	{{'n', 'u', 'k', 't'}, INDIC_GLOBAL},
	{{'a', 'k', 'h', 'n'}, INDIC_GLOBAL},
	{{'r', 'p', 'h', 'f'}, INDIC_REPH},
	{{'r', 'k', 'r', 'f'}, INDIC_GLOBAL},
	{{'p', 'r', 'e', 'f'}, INDIC_PREF},
	{{'b', 'l', 'w', 'f'}, INDIC_BELOW},
	{{'a', 'b', 'v', 'f'}, INDIC_ABOVE},
	{{'h', 'a', 'l', 'f'}, INDIC_HALF},
	{{'p', 's', 't', 'f'}, INDIC_POST},
	{{'v', 'a', 't', 'u'}, INDIC_GLOBAL},
	{{'c', 'j', 'c', 't'}, INDIC_GLOBAL},
}

@(rodata, private)
indic_first_stage := [?]vector_font.Engine_Feature{{{'l', 'o', 'c', 'l'}, INDIC_GLOBAL}, {{'c', 'c', 'm', 'p'}, INDIC_GLOBAL}}

// The presentation features, with the common features of a horizontal
// text, in one stage.
@(rodata, private)
indic_presentation_stage := [?]vector_font.Engine_Feature {
	{{'i', 'n', 'i', 't'}, INDIC_INIT},
	{{'p', 'r', 'e', 's'}, INDIC_GLOBAL},
	{{'a', 'b', 'v', 's'}, INDIC_GLOBAL},
	{{'b', 'l', 'w', 's'}, INDIC_GLOBAL},
	{{'p', 's', 't', 's'}, INDIC_GLOBAL},
	{{'h', 'a', 'l', 'n'}, INDIC_GLOBAL},
	{{'r', 'l', 'i', 'g'}, INDIC_GLOBAL},
	{{'c', 'a', 'l', 't'}, INDIC_GLOBAL},
	{{'c', 'l', 'i', 'g'}, INDIC_GLOBAL},
	{{'l', 'i', 'g', 'a'}, INDIC_GLOBAL},
	{{'r', 'c', 'l', 't'}, INDIC_GLOBAL},
}

@(rodata, private)
indic_position_stage := [?]vector_font.Engine_Feature {
	{{'d', 'i', 's', 't'}, INDIC_GLOBAL},
	{{'k', 'e', 'r', 'n'}, INDIC_GLOBAL},
	{{'a', 'b', 'v', 'm'}, INDIC_GLOBAL},
	{{'b', 'l', 'w', 'm'}, INDIC_GLOBAL},
	{{'m', 'a', 'r', 'k'}, INDIC_GLOBAL},
	{{'m', 'k', 'm', 'k'}, INDIC_GLOBAL},
}

// The work of one syllable: its characters in the order of the first
// reordering, with the kind, the position and the glyph of each. A glyph
// of the buffer names its character by its place in this order.
@(private)
Indic_Work :: struct {
	file:       ^vector_font.Font_File,
	row:        ^Indic_Script_Row,
	script:     Indic_Script,
	tag:        vector_font.Feature_Tag,
	characters: [INDIC_SYLLABLE_LIMIT]rune,
	kinds:      [INDIC_SYLLABLE_LIMIT]Indic_Kind,
	places:     [INDIC_SYLLABLE_LIMIT]Indic_Place,
	glyphs:     [INDIC_SYLLABLE_LIMIT]int,
	sources:    [INDIC_SYLLABLE_LIMIT]u8, // The index of each in the syllable as read.
	masks:      [INDIC_SYLLABLE_LIMIT]u32,
	count:      int,
	reph:       bool,
}

@(private)
indic_kind_at :: #force_inline proc "contextless" (work: ^Indic_Work, glyph: vector_font.Engine_Glyph) -> Indic_Kind {
	return int(glyph.place) < work.count ? work.kinds[glyph.place] : .Other
}

@(private)
indic_place_at :: #force_inline proc "contextless" (work: ^Indic_Work, glyph: vector_font.Engine_Glyph) -> Indic_Place {
	return int(glyph.place) < work.count ? work.places[glyph.place] : .End
}

@(private)
is_indic_joiner :: #force_inline proc "contextless" (kind: Indic_Kind) -> bool {
	return kind == .Joiner || kind == .Non_Joiner
}

// would says if a feature of the script applies to exactly these glyphs.
@(private)
indic_would :: proc "contextless" (work: ^Indic_Work, tag: string, glyphs: []int) -> bool {
	return vector_font.layout_would_substitute(work.file, work.tag, {tag[0], tag[1], tag[2], tag[3]}, glyphs)
}

// consonant_place gives the position of a consonant after the base from
// the forms of the font: a below form with a virama before or after it, a
// post form, a pre-base form (HarfBuzz, consonant_position_from_face).
@(private)
consonant_place :: proc "contextless" (work: ^Indic_Work, glyph, virama: int) -> Indic_Place {
	before := [2]int{virama, glyph}
	after := [2]int{glyph, virama}
	if indic_would(work, "blwf", before[:]) || indic_would(work, "blwf", after[:]) || indic_would(work, "vatu", before[:]) || indic_would(work, "vatu", after[:]) {
		return .Below_Consonant
	}
	if indic_would(work, "pstf", before[:]) || indic_would(work, "pstf", after[:]) || indic_would(work, "pref", before[:]) || indic_would(work, "pref", after[:]) {
		return .Post_Consonant
	}
	return .Base_Consonant
}

// indic_first_reordering gives each character its position, finds the
// base and the reph, sorts the syllable by the positions and gives each
// character its mask (HarfBuzz, initial_reordering_consonant_syllable).
@(private)
indic_first_reordering :: proc "contextless" (work: ^Indic_Work, syllable: ^Indic_Syllable) {
	count := syllable.count
	row := work.row
	virama, _ := vector_font.glyph_of(work.file, row.virama)
	characters := syllable.characters[:count]
	kinds: [INDIC_SYLLABLE_LIMIT]Indic_Kind
	places: [INDIC_SYLLABLE_LIMIT]Indic_Place
	glyphs: [INDIC_SYLLABLE_LIMIT]int
	for character, index in characters {
		kinds[index] = indic_kind_of(character)
		glyph, problem := vector_font.glyph_of(work.file, character)
		glyphs[index] = problem == .None ? glyph : 0
		switch kinds[index] {
		case .Consonant:
			places[index] = consonant_place(work, glyphs[index], virama)
		case .Repha:
			places[index] = .Ra_To_Become_Reph
		case .Matra:
			places[index] = matra_place(work.script, character)
		case .Modifier:
			places[index] = .Modifier
		case .Other, .Nukta, .Virama, .Joiner, .Non_Joiner:
			places[index] = .End
		}
	}
	// The reph and the base.
	base := count
	limit := 0
	reph := false
	switch row.reph_mode {
	case .Implicit, .Explicit:
		if count >= 3 && characters[0] == row.ra && kinds[1] == .Virama {
			pair := [2]int{glyphs[0], glyphs[1]}
			triple := [3]int{glyphs[0], glyphs[1], glyphs[2]}
			explicit := row.reph_mode == .Explicit && kinds[2] == .Joiner
			implicit := row.reph_mode == .Implicit && !is_indic_joiner(kinds[2])
			if (explicit || implicit) && (indic_would(work, "rphf", pair[:]) || explicit && indic_would(work, "rphf", triple[:])) {
				limit = 2
				for limit < count && is_indic_joiner(kinds[limit]) {
					limit += 1
				}
				base, reph = 0, true
			}
		}
	case .Logical:
		if kinds[0] == .Repha {
			limit = 1
			for limit < count && is_indic_joiner(kinds[limit]) {
				limit += 1
			}
			base, reph = 0, true
		}
	}
	// From the end, the last consonant that takes no below form and no
	// post form (a post form after a below form ends the search), else the
	// first consonant after the reph.
	seen_below := false
	for index := count - 1; index >= limit; index -= 1 {
		if kinds[index] == .Consonant {
			if places[index] != .Below_Consonant && (places[index] != .Post_Consonant || seen_below) {
				base = index
				break
			}
			if places[index] == .Below_Consonant {
				seen_below = true
			}
			base = index
		} else if index > 0 && kinds[index] == .Joiner && kinds[index - 1] == .Virama {
			// A zero width joiner after a virama asks for the half form.
			break
		}
	}
	if reph && base == 0 && limit <= 2 {
		reph = false // No other consonant: ra is the base.
	}
	for index in 0 ..< min(base, count) {
		places[index] = min(Indic_Place.Pre_Consonant, places[index])
	}
	if base < count {
		places[base] = .Base_Consonant
	}
	if reph {
		places[0] = .Ra_To_Become_Reph
	}
	// The nukta, the virama and the joiners move with the character before
	// them; a virama after a pre-base matra stays with the consonant.
	last := Indic_Place.Start
	for index in 0 ..< count {
		#partial switch kinds[index] {
		case .Nukta, .Virama, .Joiner, .Non_Joiner:
			places[index] = last
			if kinds[index] == .Virama && last == .Pre_Matra {
				for back := index; back > 0; back -= 1 {
					if places[back - 1] != .Pre_Matra {
						places[index] = places[back - 1]
						break
					}
				}
			}
		case:
			if places[index] != .Modifier {
				last = places[index]
			}
		}
	}
	// A consonant after the base takes what stands before it since the
	// last consonant or matra.
	owner := base
	for index in base + 1 ..< count {
		if kinds[index] == .Consonant {
			for between in owner + 1 ..< index {
				if places[between] < .Modifier {
					places[between] = places[index]
				}
			}
			owner = index
		} else if kinds[index] == .Matra {
			owner = index
		}
	}
	// A stable sort by position.
	order: [INDIC_SYLLABLE_LIMIT]u8
	for index in 0 ..< count {
		order[index] = u8(index)
	}
	for index in 1 ..< count {
		for back := index; back > 0 && places[order[back]] < places[order[back - 1]]; back -= 1 {
			order[back], order[back - 1] = order[back - 1], order[back]
		}
	}
	work.count = count
	work.reph = reph
	for source, index in order[:count] {
		work.characters[index] = characters[source]
		work.kinds[index] = kinds[source]
		work.places[index] = places[source]
		work.glyphs[index] = glyphs[source]
		work.sources[index] = source
	}
	// The base again, and two pre-base matras keep their order.
	base = count
	first_matra, last_matra := count, count
	for index in 0 ..< count {
		if work.places[index] == .Base_Consonant {
			base = index
			break
		}
		if work.places[index] == .Pre_Matra {
			if first_matra == count {
				first_matra = index
			}
			last_matra = index
		}
	}
	if first_matra < last_matra {
		indic_work_reverse(work, first_matra, last_matra + 1)
		start := first_matra
		for index in first_matra ..= last_matra {
			if work.kinds[index] == .Matra {
				indic_work_reverse(work, start, index + 1)
				start = index + 1
			}
		}
	}
	// The masks.
	for index in 0 ..< count {
		mask := INDIC_GLOBAL
		if work.places[index] == .Ra_To_Become_Reph {
			mask |= INDIC_REPH
		}
		if index < base {
			mask |= INDIC_HALF
			if row.below_before_base {
				mask |= INDIC_BELOW
			}
		} else if index > base {
			mask |= INDIC_BELOW | INDIC_ABOVE | INDIC_POST
		}
		work.masks[index] = mask
	}
	// The pre-base form of ra, after the base (Malayalam, Telugu).
	if base + 2 < count {
		for index in base + 1 ..< count - 1 {
			pair := [2]int{work.glyphs[index], work.glyphs[index + 1]}
			if indic_would(work, "pref", pair[:]) {
				work.masks[index] |= INDIC_PREF
				work.masks[index + 1] |= INDIC_PREF
				break
			}
		}
	}
	// A non-joiner after the base keeps the half form away from what stands
	// before it, back to a consonant. Before the base, the joiners stay
	// glyphs that the lookups of the font see.
	for index in base + 1 ..< count {
		if work.kinds[index] != .Non_Joiner {
			continue
		}
		for back := index - 1; back > 0; back -= 1 {
			work.masks[back] &~= INDIC_HALF
			if work.kinds[back] == .Consonant {
				break
			}
		}
	}
}

@(private)
indic_work_reverse :: proc "contextless" (work: ^Indic_Work, from, to: int) {
	for low, high := from, to - 1; low < high; low, high = low + 1, high - 1 {
		work.characters[low], work.characters[high] = work.characters[high], work.characters[low]
		work.kinds[low], work.kinds[high] = work.kinds[high], work.kinds[low]
		work.places[low], work.places[high] = work.places[high], work.places[low]
		work.glyphs[low], work.glyphs[high] = work.glyphs[high], work.glyphs[low]
		work.sources[low], work.sources[high] = work.sources[high], work.sources[low]
	}
}

// indic_buffer_move moves the glyph at from to the place to, and the
// glyphs between them by one.
@(private)
indic_buffer_move :: proc "contextless" (buffer: ^vector_font.Engine_Buffer, from, to: int) {
	if from == to || from < 0 || to < 0 || from >= buffer.count || to >= buffer.count {
		return
	}
	moved := buffer.glyphs[from]
	if from < to {
		for index in from ..< to {
			buffer.glyphs[index] = buffer.glyphs[index + 1]
		}
	} else {
		for index := from; index > to; index -= 1 {
			buffer.glyphs[index] = buffer.glyphs[index - 1]
		}
	}
	buffer.glyphs[to] = moved
}

// ligated says if the glyph of a character took the character after it
// into a ligature: no glyph of the buffer comes from that character.
@(private)
ligated :: proc "contextless" (buffer: ^vector_font.Engine_Buffer, glyph: vector_font.Engine_Glyph) -> bool {
	for other in buffer.glyphs[:buffer.count] {
		if int(other.place) == int(glyph.place) + 1 {
			return false
		}
	}
	return true
}

// indic_final_reordering puts the pre-base matra, the reph and the pre-base
// form of ra in their places after the basic features (HarfBuzz,
// final_reordering_syllable_indic), and gives the pre-base matra at the
// start of a word the feature init.
@(private)
indic_final_reordering :: proc "contextless" (work: ^Indic_Work, buffer: ^vector_font.Engine_Buffer, word_start: bool) {
	end := buffer.count
	if end == 0 {
		return
	}
	glyphs := buffer.glyphs[:end]
	no_half_forms := work.script == .Malayalam || work.script == .Tamil
	// The base: the first glyph at the position of the base or after it.
	base := 0
	try_pref := true
	for base = 0; base < end; base += 1 {
		if indic_place_at(work, glyphs[base]) < .Base_Consonant {
			continue
		}
		if try_pref && base + 1 < end {
			for index in base + 1 ..< end {
				if glyphs[index].mask & INDIC_PREF == 0 {
					continue
				}
				if !ligated(buffer, glyphs[index]) {
					// A pre-base form that did not form: the base is near it.
					base = index
					for base < end && indic_kind_at(work, glyphs[base]) == .Virama {
						base += 1
					}
					if base < end {
						work.places[glyphs[base].place] = .Base_Consonant
					}
					try_pref = false
				}
				break
			}
			if base == end {
				break
			}
		}
		// Malayalam: a below form that did not form is the base.
		if work.script == .Malayalam {
			for index := base + 1; index < end; index += 1 {
				for index < end && is_indic_joiner(indic_kind_at(work, glyphs[index])) {
					index += 1
				}
				if index == end || indic_kind_at(work, glyphs[index]) != .Virama {
					break
				}
				index += 1
				for index < end && is_indic_joiner(indic_kind_at(work, glyphs[index])) {
					index += 1
				}
				if index < end && indic_kind_at(work, glyphs[index]) == .Consonant && indic_place_at(work, glyphs[index]) == .Below_Consonant {
					base = index
					work.places[glyphs[base].place] = .Base_Consonant
				}
			}
		}
		if 0 < base && indic_place_at(work, glyphs[base]) > .Base_Consonant {
			base -= 1
		}
		break
	}
	if base == end && 0 < base && indic_kind_at(work, glyphs[base - 1]) == .Joiner {
		base -= 1
	}
	if base < end {
		for 0 < base && (indic_kind_at(work, glyphs[base]) == .Nukta || indic_kind_at(work, glyphs[base]) == .Virama) {
			base -= 1
		}
	}
	// The pre-base matra: after the last virama that stayed a glyph before
	// the base, which no zero width joiner follows; with none, it stays.
	if 1 < end && 0 < base {
		new_place := base == end ? base - 2 : base - 1
		if !no_half_forms {
			for {
				for new_place > 0 && indic_kind_at(work, glyphs[new_place]) != .Matra && indic_kind_at(work, glyphs[new_place]) != .Virama {
					new_place -= 1
				}
				if indic_kind_at(work, glyphs[new_place]) == .Virama && indic_place_at(work, glyphs[new_place]) != .Pre_Matra {
					if new_place + 1 < end && indic_kind_at(work, glyphs[new_place + 1]) == .Joiner && new_place > 0 {
						new_place -= 1
						continue
					}
				} else {
					new_place = 0
				}
				break
			}
		}
		if 0 < new_place && new_place < end && indic_place_at(work, glyphs[new_place]) != .Pre_Matra {
			for index := new_place; index > 0; index -= 1 {
				if indic_place_at(work, glyphs[index - 1]) == .Pre_Matra {
					old_place := index - 1
					if old_place < base && base <= new_place {
						base -= 1
					}
					indic_buffer_move(buffer, old_place, new_place)
					new_place -= 1
				}
			}
		}
	}
	// The reph, when the virama went into it, or the dot reph.
	if 1 < end && indic_place_at(work, glyphs[0]) == .Ra_To_Become_Reph && ((indic_kind_at(work, glyphs[0]) == .Repha) != ligated(buffer, glyphs[0])) {
		new_place := -1
		explicit_virama :: proc "contextless" (work: ^Indic_Work, glyphs: []vector_font.Engine_Glyph, base: int) -> int {
			place := 1
			for place < base && indic_kind_at(work, glyphs[place]) != .Virama {
				place += 1
			}
			if place < base && indic_kind_at(work, glyphs[place]) == .Virama {
				if place + 1 < base && is_indic_joiner(indic_kind_at(work, glyphs[place + 1])) {
					place += 1
				}
				return place
			}
			return -1
		}
		position := work.row.reph_position
		if position != .After_Post {
			new_place = explicit_virama(work, glyphs, base)
		}
		if new_place < 0 && position == .After_Main {
			new_place = base
			for new_place + 1 < end && indic_place_at(work, glyphs[new_place + 1]) <= .After_Main {
				new_place += 1
			}
		}
		if new_place < 0 && position == .After_Sub {
			new_place = base
			for new_place + 1 < end {
				next := indic_place_at(work, glyphs[new_place + 1])
				if next == .Post_Consonant || next == .After_Post || next == .Modifier {
					break
				}
				new_place += 1
			}
		}
		if new_place < 0 {
			new_place = explicit_virama(work, glyphs, base)
		}
		if new_place < 0 {
			new_place = end - 1
			for new_place > 0 && indic_place_at(work, glyphs[new_place]) == .Modifier {
				new_place -= 1
			}
			// Before a virama after a matra, so that they meet.
			if indic_kind_at(work, glyphs[new_place]) == .Virama {
				for index in base + 1 ..< new_place {
					if indic_kind_at(work, glyphs[index]) == .Matra {
						new_place -= 1
					}
				}
			}
		}
		new_place = clamp(new_place, 0, end - 1)
		indic_buffer_move(buffer, 0, new_place)
		if 0 < base && base <= new_place {
			base -= 1
		}
	}
	// The pre-base form of ra: before the base, after a virama that stayed a
	// glyph.
	if try_pref && base + 1 < end {
		for index in base + 1 ..< end {
			if glyphs[index].mask & INDIC_PREF == 0 {
				continue
			}
			if ligated(buffer, glyphs[index]) {
				new_place := base
				if !no_half_forms {
					for new_place > 0 {
						kind := indic_kind_at(work, glyphs[new_place - 1])
						if kind == .Matra || kind == .Virama {
							break
						}
						new_place -= 1
					}
				}
				if new_place > 0 && indic_kind_at(work, glyphs[new_place - 1]) == .Virama && new_place < end && is_indic_joiner(indic_kind_at(work, glyphs[new_place])) {
					new_place += 1
				}
				indic_buffer_move(buffer, index, new_place)
			}
			break
		}
	}
	// init on a pre-base matra at the start of a word.
	if indic_place_at(work, glyphs[0]) == .Pre_Matra && word_start {
		glyphs[0].mask |= INDIC_INIT
	}
}

// indic_shape shapes a syllable with a font into a buffer, in the units
// of the font: the glyphs, their advances and their offsets
// (vector_font.engine_positions_finish). Each glyph names its character in
// the syllable as read (sources).
@(private)
indic_shape :: proc "contextless" (file: ^vector_font.Font_File, syllable: ^Indic_Syllable, buffer: ^vector_font.Engine_Buffer, word_start: bool, sources: ^[INDIC_SYLLABLE_LIMIT]u8) {
	work: Indic_Work
	work.file = file
	work.script = syllable.script
	work.row = &indic_script_rows[syllable.script]
	work.tag = vector_font.layout_has_script(file, file.gsub, work.row.tags[0]) ? work.row.tags[0] : work.row.tags[1]
	indic_first_reordering(&work, syllable)
	// The glyphs. A joiner is a glyph through the substitutions, as the
	// features of the specification see it (HarfBuzz: manual joiners), and
	// leaves before the positions, as it draws nothing.
	buffer.count = 0
	for index in 0 ..< work.count {
		buffer.glyphs[buffer.count] = {glyph = u16(work.glyphs[index]), place = u8(index), mask = work.masks[index]}
		buffer.count += 1
	}
	sources^ = work.sources
	vector_font.engine_buffer_prepare(file, buffer)
	_ = vector_font.engine_stage(file, .Substitution, work.tag, indic_first_stage[:], buffer)
	for stage in indic_basic_stages {
		single := [1]vector_font.Engine_Feature{stage}
		_ = vector_font.engine_stage(file, .Substitution, work.tag, single[:], buffer)
	}
	indic_final_reordering(&work, buffer, word_start)
	_ = vector_font.engine_stage(file, .Substitution, work.tag, indic_presentation_stage[:], buffer)
	kept := 0
	for glyph in buffer.glyphs[:buffer.count] {
		if !is_indic_joiner(indic_kind_at(&work, glyph)) {
			buffer.glyphs[kept] = glyph
			kept += 1
		}
	}
	buffer.count = kept
	vector_font.engine_buffer_prepare(file, buffer)
	_ = vector_font.engine_stage(file, .Positioning, work.tag, indic_position_stage[:], buffer)
	vector_font.engine_positions_finish(buffer)
}

// indic_shaped shapes the syllable at the byte of the shaper with the
// font that draws its first character, when it is a font of the script
// font set with a table GSUB; false leaves the shaper as it was.
@(private)
indic_shaped :: proc "contextless" (shaper: ^Shaper, shaped: ^Shaped) -> bool {
	spacing := shaper.spacing
	if spacing.cell_advance > 0 {
		return false
	}
	syllable, read := indic_syllable_read(shaper.text, shaper.place)
	if !read {
		return false
	}
	// The font of its first character of the script: the dotted circle of a
	// syllable with no base is a symbol of another chain.
	first := syllable.characters[syllable.characters[0] == DOTTED_CIRCLE && syllable.count > 1 ? 1 : 0]
	font, _ := font_glyph_in(shaper.set, spacing.face, first)
	if font not_in SCRIPT_FONTS {
		return false
	}
	file := &font_at(shaper.set, font).file
	if file.gsub.length == 0 {
		return false
	}
	buffer: vector_font.Engine_Buffer
	sources: [INDIC_SYLLABLE_LIMIT]u8
	indic_shape(file, &syllable, &buffer, !shaper.after_letter, &sources)
	if buffer.count == 0 {
		return false
	}
	row := &indic_script_rows[syllable.script]
	shaped^ = {start = shaper.place, end = syllable.end, script = vector_font.layout_has_script(file, file.gsub, row.tags[0]) ? row.tags[0] : row.tags[1], syllable = true}
	scale := measures_in_frame_of(shaper.set, spacing.face, font).advance
	limit := i64(spacing.size)
	// The clusters never go down along the glyphs, as in HarfBuzz: a glyph
	// that the reordering moved before the characters of the glyphs after
	// it takes their first byte.
	clusters: [vector_font.ENGINE_GLYPH_LIMIT]u32
	lowest := max(u32)
	for index := buffer.count - 1; index >= 0; index -= 1 {
		source := int(sources[min(int(buffer.glyphs[index].place), INDIC_SYLLABLE_LIMIT - 1)])
		lowest = min(lowest, syllable.places[min(source, syllable.count - 1)])
		clusters[index] = lowest
	}
	pen: i64
	for glyph, index in buffer.glyphs[:min(buffer.count, 1 + CLUSTER_MARK_LIMIT)] {
		resolved := resolve_index(spacing, font, int(glyph.glyph))
		resolved.advance = i32(clamp(units_at_size(int(glyph.x_advance), spacing.size, scale), 0, i64(advance_limit_of_size(spacing.size))))
		resolved.cluster = clusters[index]
		if index == 0 {
			shaped.base = resolved
		} else {
			if glyph.x_offset != 0 || glyph.y_offset != 0 || resolved.advance == 0 {
				resolved.placement = .Anchored
				resolved.offset_x = i32(clamp(pen + units_at_size(int(glyph.x_offset), spacing.size, scale), -limit, limit))
				resolved.offset_y = i32(clamp(units_at_size(int(glyph.y_offset), spacing.size, scale), -limit, limit))
			}
			shaped.marks[shaped.mark_count] = resolved
			shaped.mark_count += 1
		}
		pen += i64(resolved.advance)
	}
	shaper.place = syllable.end
	shaper.previous = .None
	shaper.sara_am_taken = -1
	shaper.after_letter = true
	return true
}
// The positions between two syllables: dist and kern of GPOS.
@(rodata, private)
indic_pair_stage := [?]vector_font.Engine_Feature{{{'d', 'i', 's', 't'}, INDIC_GLOBAL}, {{'k', 'e', 'r', 'n'}, INDIC_GLOBAL}}

// indic_pair_units gives the change of the advance of the last glyph of a
// syllable that the glyph after it, the first of the next syllable, makes
// (dist and kern of GPOS), in units of the font: a syllable is shaped
// alone, and HarfBuzz positions the pairs of a word across its syllables.
@(private)
indic_pair_units :: proc "contextless" (file: ^vector_font.Font_File, tag: vector_font.Feature_Tag, left, right: int) -> i32 {
	if file.gpos.length == 0 {
		return 0
	}
	buffer: vector_font.Engine_Buffer
	buffer.glyphs[0] = {glyph = u16(left), mask = INDIC_GLOBAL}
	buffer.glyphs[1] = {glyph = u16(right), place = 1, mask = INDIC_GLOBAL}
	buffer.count = 2
	vector_font.engine_buffer_prepare(file, &buffer)
	advance := buffer.glyphs[0].x_advance
	_ = vector_font.engine_stage(file, .Positioning, tag, indic_pair_stage[:], &buffer)
	return buffer.glyphs[0].x_advance - advance
}

// syllable_pair_of gives the pair of two shaped syllables of one font, in
// 1/64 of a pixel, within half a line: 0 when either is not a syllable.
@(private)
syllable_pair_of :: proc "contextless" (spacing: ^Spacing, set: ^Font_Set, current, next: ^Shaped) -> i32 {
	if !current.syllable || !next.syllable || spacing.cell_advance > 0 || spacing.without_pairs {
		return 0
	}
	last := current.mark_count > 0 ? current.marks[current.mark_count - 1] : current.base
	if last.font == .None || last.font != next.base.font {
		return 0
	}
	file := &font_at(set, last.font).file
	units := indic_pair_units(file, current.script, int(last.index), int(next.base.index))
	if units == 0 {
		return 0
	}
	limit := pair_limit_of_size(spacing.size)
	return i32(clamp(units_at_size(int(units), spacing.size, measures_in_frame_of(set, spacing.face, last.font).advance), -limit, limit))
}
