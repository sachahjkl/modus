package text_rendering

import "modus:contract/text_encoding"
import "modus:vector_font"

// The shaper of Devanagari (src/md/features/written_shaping.md,
// "Devanagari"): the OpenType specification of the Indic scripts over the
// engine of the lookups (vector_font.engine_stage). A syllable is read from
// the text once, its glyphs go through the basic features, the final
// reordering and the presentation features, and come out as one Shaped:
// its first glyph as the base, the others after it.

// The most characters of one syllable, the dotted circle of a syllable
// with no base too: its glyphs fit the marks of a Shaped.
INDIC_SYLLABLE_LIMIT :: CLUSTER_MARK_LIMIT

@(private)
VIRAMA_DEVANAGARI :: rune(0x094D)
@(private)
RA_DEVANAGARI :: rune(0x0930)
@(private)
ZERO_WIDTH_NON_JOINER :: rune(0x200C)
@(private)
ZERO_WIDTH_JOINER :: rune(0x200D)

// The kind of a syllable.
@(private)
Indic_Syllable_Kind :: enum u8 {
	Consonant, // A consonant, with the consonants that a virama joins to it.
	Vowel, // An independent vowel.
	Standalone, // Marks with no base: the dotted circle is their base.
	Other, // A digit, a danda, an avagraha: one character, no mark.
}

// A syllable of a text: its characters and the first byte of each.
@(private)
Indic_Syllable :: struct {
	characters: [INDIC_SYLLABLE_LIMIT]rune,
	places:     [INDIC_SYLLABLE_LIMIT]u32,
	count:      int,
	kind:       Indic_Syllable_Kind,
	end:        int, // The byte after it.
}

// is_indic_character says if the Indic shaper takes a character: the
// Devanagari block.
@(private)
is_indic_character :: #force_inline proc "contextless" (character: rune) -> bool {
	return character >= 0x0900 && character <= 0x097F
}

@(private)
is_indic_consonant :: proc "contextless" (character: rune) -> bool {
	if character == DOTTED_CIRCLE {
		return true
	}
	#partial switch indic_category_of(character) {
	case .Consonant, .Consonant_Dead, .Consonant_Placeholder, .Consonant_With_Stacker, .Consonant_Preceding_Repha:
		return true
	}
	return false
}

// is_indic_modifier says if a character is a sign that ends a syllable
// after its vowels: a bindu, a visarga, a cantillation mark.
@(private)
is_indic_modifier :: proc "contextless" (character: rune) -> bool {
	#partial switch indic_category_of(character) {
	case .Bindu, .Visarga, .Syllable_Modifier, .Cantillation_Mark, .Gemination_Mark:
		return true
	}
	return false
}

// is_indic_dependent says if a character belongs to the syllable before
// it: a nukta, a virama, a dependent vowel, a modifier.
@(private)
is_indic_dependent :: proc "contextless" (character: rune) -> bool {
	#partial switch indic_category_of(character) {
	case .Nukta, .Virama, .Pure_Killer, .Vowel_Dependent:
		return true
	}
	return is_indic_modifier(character)
}

// indic_syllable_read reads the syllable that starts at a byte of a text.
// Each byte is decoded once. ok is false at the end of the text and for a
// character that the Indic shaper does not take.
@(private)
indic_syllable_read :: proc "contextless" (text: []u8, place: int) -> (syllable: Indic_Syllable, ok: bool) {
	at := place
	// peek decodes the character at the byte at, a valid one of the
	// syllable only: 0 for the end and for an invalid sequence.
	peek :: proc "contextless" (text: []u8, at: int) -> (character: rune, length: int) {
		decoded, decoded_length, valid := text_encoding.character_decode(text, at)
		if decoded_length == 0 || !valid {
			return 0, 0
		}
		return decoded, decoded_length
	}
	take :: proc "contextless" (syllable: ^Indic_Syllable, character: rune, place: int) -> bool {
		if syllable.count == INDIC_SYLLABLE_LIMIT {
			return false
		}
		syllable.characters[syllable.count] = character
		syllable.places[syllable.count] = u32(place)
		syllable.count += 1
		return true
	}
	first, first_length := peek(text, at)
	if first_length == 0 || !is_indic_character(first) {
		return {}, false
	}
	switch {
	case is_indic_consonant(first):
		syllable.kind = .Consonant
	case indic_category_of(first) == .Vowel_Independent:
		syllable.kind = .Vowel
	case is_indic_dependent(first):
		syllable.kind = .Standalone
	case:
		syllable.kind = .Other
	}
	if syllable.kind == .Standalone {
		take(&syllable, DOTTED_CIRCLE, at)
	} else {
		take(&syllable, first, at)
		at += first_length
	}
	if syllable.kind == .Other {
		syllable.end = at
		return syllable, true
	}
	character, length := peek(text, at)
	nuktas :: proc "contextless" (text: []u8, syllable: ^Indic_Syllable, at: ^int, character: ^rune, length: ^int) {
		for length^ > 0 && indic_category_of(character^) == .Nukta && take(syllable, character^, at^) {
			at^ += length^
			character^, length^ = peek(text, at^)
		}
	}
	nuktas(text, &syllable, &at, &character, &length)
	// The consonants that a virama joins, each with its nukta; a joiner
	// after a virama stays in the syllable.
	if syllable.kind == .Consonant {
		for length > 0 && character == VIRAMA_DEVANAGARI {
			after_at := at + length
			after, after_length := peek(text, after_at)
			if after == ZERO_WIDTH_JOINER || after == ZERO_WIDTH_NON_JOINER {
				after_at += after_length
				after, after_length = peek(text, after_at)
			}
			if after_length == 0 || !is_indic_character(after) || !is_indic_consonant(after) || syllable.count + 3 > INDIC_SYLLABLE_LIMIT {
				break
			}
			take(&syllable, character, at)
			at += length
			character, length = peek(text, at)
			if character == ZERO_WIDTH_JOINER || character == ZERO_WIDTH_NON_JOINER {
				take(&syllable, character, at)
				at += length
				character, length = peek(text, at)
			}
			take(&syllable, character, at)
			at += length
			character, length = peek(text, at)
			nuktas(text, &syllable, &at, &character, &length)
		}
	}
	// The dependent vowels, a final virama, the modifiers.
	for length > 0 && is_indic_character(character) && is_indic_dependent(character) && take(&syllable, character, at) {
		at += length
		character, length = peek(text, at)
	}
	syllable.end = at
	return syllable, true
}

// The features of the Indic shaper, and the bit of the mask of each that
// the positions of a syllable choose. The other features take every glyph.
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
indic_tag :: #force_inline proc "contextless" (tag: string) -> vector_font.Feature_Tag {
	return {tag[0], tag[1], tag[2], tag[3]}
}

// The basic features, one stage each, in the order of the specification.
@(rodata, private)
indic_basic_stages := [?]vector_font.Engine_Feature {
	{{'n', 'u', 'k', 't'}, INDIC_GLOBAL},
	{{'a', 'k', 'h', 'n'}, INDIC_GLOBAL},
	{{'r', 'p', 'h', 'f'}, INDIC_REPH},
	{{'r', 'k', 'r', 'f'}, INDIC_GLOBAL},
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

// indic_category_at gives the category of the character of a glyph of the
// buffer: a ligature has the category of its first character.
@(private)
indic_category_at :: #force_inline proc "contextless" (syllable: ^Indic_Syllable, glyph: vector_font.Engine_Glyph) -> Indic_Category {
	if int(glyph.place) >= syllable.count {
		return .Other
	}
	character := syllable.characters[glyph.place]
	if character == DOTTED_CIRCLE {
		return .Consonant_Placeholder
	}
	return indic_category_of(character)
}

@(private)
is_pre_base_matra :: #force_inline proc "contextless" (character: rune) -> bool {
	return indic_category_of(character) == .Vowel_Dependent && indic_position_of(character) == .Left
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

// indic_shape shapes a syllable with a font into a buffer, in the units
// of the font: the glyphs, their advances and their offsets
// (vector_font.engine_positions_finish).
@(private)
indic_shape :: proc "contextless" (file: ^vector_font.Font_File, syllable: ^Indic_Syllable, buffer: ^vector_font.Engine_Buffer) {
	script := indic_script_of(file)
	// The reph: ra and a virama at the start of a syllable with a
	// consonant after them.
	count := syllable.count
	chars := syllable.characters[:count]
	reph := syllable.kind == .Consonant && count >= 3 && chars[0] == RA_DEVANAGARI && chars[1] == VIRAMA_DEVANAGARI && is_indic_consonant(chars[2])
	// The base: the last consonant, less a ra after a virama, which takes
	// its below form, and never the ra of the reph.
	first_possible := reph ? 2 : 0
	base := 0
	if syllable.kind == .Consonant {
		base = first_possible
		for index := count - 1; index >= first_possible; index -= 1 {
			if !is_indic_consonant(chars[index]) {
				continue
			}
			if chars[index] == RA_DEVANAGARI && index >= 1 && chars[index - 1] == VIRAMA_DEVANAGARI && index - 2 > first_possible {
				continue
			}
			base = index
			break
		}
	}
	// The glyphs, with the mask of the place of each; a joiner is no
	// glyph: a non-joiner after a virama keeps the half form away.
	buffer.count = 0
	for character, index in chars {
		if character == ZERO_WIDTH_JOINER || character == ZERO_WIDTH_NON_JOINER {
			if character == ZERO_WIDTH_NON_JOINER {
				for back := buffer.count - 1; back >= 0 && back >= buffer.count - 2; back -= 1 {
					buffer.glyphs[back].mask &~= INDIC_HALF
				}
			}
			continue
		}
		mask := INDIC_GLOBAL
		switch {
		case reph && index < 2:
			mask |= INDIC_REPH | INDIC_HALF | INDIC_BELOW
		case index < base:
			mask |= INDIC_HALF | INDIC_BELOW
		case index > base:
			mask |= INDIC_BELOW | INDIC_ABOVE | INDIC_POST
		}
		glyph, problem := vector_font.glyph_of(file, character)
		if problem != .None {
			glyph = 0
		}
		buffer.glyphs[buffer.count] = {glyph = u16(glyph), place = u8(index), mask = mask}
		buffer.count += 1
	}
	// The first reordering: a pre-base matra goes to the start, after the
	// reph.
	start := reph ? 2 : 0
	for index in 0 ..< buffer.count {
		if is_pre_base_matra(chars[buffer.glyphs[index].place]) && index > start {
			indic_buffer_move(buffer, index, start)
			start += 1
		}
	}
	vector_font.engine_buffer_prepare(file, buffer)
	_ = vector_font.engine_stage(file, .Substitution, script, indic_first_stage[:], buffer)
	for stage in indic_basic_stages {
		single := [1]vector_font.Engine_Feature{stage}
		_ = vector_font.engine_stage(file, .Substitution, script, single[:], buffer)
	}
	indic_final_reorder(syllable, buffer, reph, base)
	_ = vector_font.engine_stage(file, .Substitution, script, indic_presentation_stage[:], buffer)
	vector_font.engine_buffer_prepare(file, buffer)
	_ = vector_font.engine_stage(file, .Positioning, script, indic_position_stage[:], buffer)
	vector_font.engine_positions_finish(buffer)
}

// indic_script_of gives the script tag of the font: dev2, the tag of the
// second form of the specification, when the font has it, else deva.
@(private)
indic_script_of :: proc "contextless" (file: ^vector_font.Font_File) -> vector_font.Feature_Tag {
	if vector_font.layout_has_script(file, file.gsub, {'d', 'e', 'v', '2'}) {
		return {'d', 'e', 'v', '2'}
	}
	return {'d', 'e', 'v', 'a'}
}

// indic_final_reordering: the pre-base matra goes after the last virama
// that stayed a glyph before the base, and the reph after the base, its
// below forms and its vowels, before the modifiers.
@(private)
indic_final_reorder :: proc "contextless" (syllable: ^Indic_Syllable, buffer: ^vector_font.Engine_Buffer, reph: bool, base_character: int) {
	if buffer.count == 0 {
		return
	}
	// The base glyph: the last glyph of a character up to the base.
	base := 0
	for index in 0 ..< buffer.count {
		place := int(buffer.glyphs[index].place)
		if place <= base_character && !is_pre_base_matra(syllable.characters[place]) {
			base = index
		}
	}
	// The pre-base matra.
	for index in 0 ..< base {
		if !is_pre_base_matra(syllable.characters[buffer.glyphs[index].place]) {
			continue
		}
		target := base - 1
		for target > index && indic_category_at(syllable, buffer.glyphs[target]) != .Virama && indic_category_at(syllable, buffer.glyphs[target]) != .Vowel_Dependent {
			target -= 1
		}
		if target > index && indic_category_at(syllable, buffer.glyphs[target]) == .Virama {
			indic_buffer_move(buffer, index, target)
		}
		break
	}
	// The reph: made when the virama after the ra is gone into it.
	if !reph || buffer.glyphs[0].place != 0 || (buffer.count > 1 && buffer.glyphs[1].place == 1) {
		return
	}
	target := -1
	for index in 1 ..< base {
		if indic_category_at(syllable, buffer.glyphs[index]) == .Virama {
			target = index
			break
		}
	}
	if target < 0 {
		target = buffer.count - 1
		for index in base + 1 ..< buffer.count {
			if is_indic_modifier(syllable.characters[buffer.glyphs[index].place]) {
				target = index - 1
				break
			}
		}
	}
	indic_buffer_move(buffer, 0, max(target, 0))
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
	first := syllable.characters[syllable.kind == .Standalone && syllable.count > 1 ? 1 : 0]
	font, _ := font_glyph_in(shaper.set, spacing.face, first)
	if font not_in SCRIPT_FONTS {
		return false
	}
	file := &font_at(shaper.set, font).file
	if file.gsub.length == 0 {
		return false
	}
	buffer: vector_font.Engine_Buffer
	indic_shape(file, &syllable, &buffer)
	ENGINE_GLYPH_LIMIT :: vector_font.ENGINE_GLYPH_LIMIT
	if buffer.count == 0 {
		return false
	}
	shaped^ = {start = shaper.place, end = syllable.end, script = indic_script_of(file), syllable = true}
	scale := measures_in_frame_of(shaper.set, spacing.face, font).advance
	limit := i64(spacing.size)
	// The clusters never go down along the glyphs, as in HarfBuzz: a glyph
	// that the reordering moved before the characters of the glyphs after
	// it takes their first byte.
	clusters: [ENGINE_GLYPH_LIMIT]u32
	lowest := max(u32)
	for index := buffer.count - 1; index >= 0; index -= 1 {
		lowest = min(lowest, syllable.places[min(int(buffer.glyphs[index].place), syllable.count - 1)])
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
	return true
}
