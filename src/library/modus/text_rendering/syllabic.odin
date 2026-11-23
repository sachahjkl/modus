package text_rendering

import "modus:contract/text_encoding"
import "modus:vector_font"

// The shapers of Khmer, Myanmar and the Universal Shaping Engine
// (src/md/features/written_shaping.md, "Khmer, Myanmar and the Universal
// Shaping Engine"): what they share. A syllable is read from a window of
// the text, decomposed and put in canonical order as HarfBuzz normalizes,
// matched by the grammar of its model (syllable_machine.odin), shaped by
// the engine of the lookups with its font, and written as one Shaped, as a
// syllable of a script of India.

// The most characters of the window of a syllable: with the dotted circle
// of a broken syllable, its glyphs fit the base and the marks of a Shaped,
// as a syllable of a script of India does (INDIC_SYLLABLE_LIMIT). Computed
// from CLUSTER_MARK_LIMIT. A longer syllable is cut there, and its rest
// starts the next one: each of its characters still draws.
SYLLABIC_WINDOW_LIMIT :: INDIC_SYLLABLE_LIMIT - 1

// The OpenType model of a script: its grammar, its features and its
// reordering.
Syllabic_Model :: enum u8 {
	Khmer,
	Myanmar,
	Universal, // The Universal Shaping Engine.
}

// The scripts that these shapers take, as HarfBuzz chooses their model
// (hb_ot_shaper_categorize).
Syllabic_Script :: enum u8 {
	Khmer,
	Myanmar,
	Tibetan,
	Balinese,
	Javanese,
	Sundanese,
}

@(private)
SYLLABIC_RANGE_LIMIT :: 3 // The runs of characters of one script.

// The row of a script: its characters, its model, its tag in the tables of
// its font, its font, and the chain of each face. The rows are data of the
// written part only: the fast part never places a character of these
// scripts (src/md/features/written_shaping.md, "The chains").
@(private)
Syllabic_Script_Row :: struct {
	ranges:      [SYLLABIC_RANGE_LIMIT]Character_Range,
	range_count: int,
	model:       Syllabic_Model,
	tag:         vector_font.Feature_Tag,
	font:        Outline_Font,
	chains:      [Chain_Kind]Chain,
}

@(rodata, private)
syllabic_script_rows := [Syllabic_Script]Syllabic_Script_Row {
	.Khmer = {ranges = {0 = {0x1780, 0x17FF}, 1 = {0x19E0, 0x19FF}}, range_count = 2, model = .Khmer, tag = {'k', 'h', 'm', 'r'}, font = .Noto_Sans_Khmer, chains = {.Interface = {.Noto_Sans_Khmer, .B612, .Noto_Sans, .Paper_Mono, .None}, .Interface_Bold = {.Noto_Sans_Khmer, .B612_Bold, .Noto_Sans, .Paper_Mono_Semibold, .None}, .Cells = {.Paper_Mono, .B612, .Noto_Sans, .Noto_Sans_Khmer, .None}, .Cells_Bold = {.Paper_Mono_Semibold, .B612, .Noto_Sans, .Noto_Sans_Khmer, .None}}},
	// The tag of the specification of Myanmar: HarfBuzz shapes a font of
	// the older tag mymr by the default model.
	.Myanmar = {ranges = {0 = {0x1000, 0x109F}, 1 = {0xA9E0, 0xA9FF}, 2 = {0xAA60, 0xAA7F}}, range_count = 3, model = .Myanmar, tag = {'m', 'y', 'm', '2'}, font = .Noto_Sans_Myanmar, chains = {.Interface = {.Noto_Sans_Myanmar, .B612, .Noto_Sans, .Paper_Mono, .None}, .Interface_Bold = {.Noto_Sans_Myanmar, .B612_Bold, .Noto_Sans, .Paper_Mono_Semibold, .None}, .Cells = {.Paper_Mono, .B612, .Noto_Sans, .Noto_Sans_Myanmar, .None}, .Cells_Bold = {.Paper_Mono_Semibold, .B612, .Noto_Sans, .Noto_Sans_Myanmar, .None}}},
	.Tibetan = {ranges = {0 = {0x0F00, 0x0FFF}}, range_count = 1, model = .Universal, tag = {'t', 'i', 'b', 't'}, font = .Noto_Serif_Tibetan, chains = {.Interface = {.Noto_Serif_Tibetan, .B612, .Noto_Sans, .Paper_Mono, .None}, .Interface_Bold = {.Noto_Serif_Tibetan, .B612_Bold, .Noto_Sans, .Paper_Mono_Semibold, .None}, .Cells = {.Paper_Mono, .B612, .Noto_Sans, .Noto_Serif_Tibetan, .None}, .Cells_Bold = {.Paper_Mono_Semibold, .B612, .Noto_Sans, .Noto_Serif_Tibetan, .None}}},
	.Balinese = {ranges = {0 = {0x1B00, 0x1B7F}}, range_count = 1, model = .Universal, tag = {'b', 'a', 'l', 'i'}, font = .Noto_Sans_Balinese, chains = {.Interface = {.Noto_Sans_Balinese, .B612, .Noto_Sans, .Paper_Mono, .None}, .Interface_Bold = {.Noto_Sans_Balinese, .B612_Bold, .Noto_Sans, .Paper_Mono_Semibold, .None}, .Cells = {.Paper_Mono, .B612, .Noto_Sans, .Noto_Sans_Balinese, .None}, .Cells_Bold = {.Paper_Mono_Semibold, .B612, .Noto_Sans, .Noto_Sans_Balinese, .None}}},
	.Javanese = {ranges = {0 = {0xA980, 0xA9DF}}, range_count = 1, model = .Universal, tag = {'j', 'a', 'v', 'a'}, font = .Noto_Sans_Javanese, chains = {.Interface = {.Noto_Sans_Javanese, .B612, .Noto_Sans, .Paper_Mono, .None}, .Interface_Bold = {.Noto_Sans_Javanese, .B612_Bold, .Noto_Sans, .Paper_Mono_Semibold, .None}, .Cells = {.Paper_Mono, .B612, .Noto_Sans, .Noto_Sans_Javanese, .None}, .Cells_Bold = {.Paper_Mono_Semibold, .B612, .Noto_Sans, .Noto_Sans_Javanese, .None}}},
	.Sundanese = {ranges = {0 = {0x1B80, 0x1BBF}, 1 = {0x1CC0, 0x1CCF}}, range_count = 2, model = .Universal, tag = {'s', 'u', 'n', 'd'}, font = .Noto_Sans_Sundanese, chains = {.Interface = {.Noto_Sans_Sundanese, .B612, .Noto_Sans, .Paper_Mono, .None}, .Interface_Bold = {.Noto_Sans_Sundanese, .B612_Bold, .Noto_Sans, .Paper_Mono_Semibold, .None}, .Cells = {.Paper_Mono, .B612, .Noto_Sans, .Noto_Sans_Sundanese, .None}, .Cells_Bold = {.Paper_Mono_Semibold, .B612, .Noto_Sans, .Noto_Sans_Sundanese, .None}}},
}

// The fonts of the rows: each face names them (fonts_of_face), as each of
// their chains holds its font. A constant, so the fast part holds no row.
SYLLABIC_SCRIPT_FONTS :: Outline_Fonts{.Noto_Sans_Khmer, .Noto_Sans_Myanmar, .Noto_Serif_Tibetan, .Noto_Sans_Balinese, .Noto_Sans_Javanese, .Noto_Sans_Sundanese}

// syllabic_script_of gives the script of the rows that holds a character.
@(private)
syllabic_script_of :: proc "contextless" (character: rune) -> (script: Syllabic_Script, found: bool) {
	if character < 0x0F00 || character > 0xAA7F {
		return {}, false
	}
	for &row, each in syllabic_script_rows {
		for range in row.ranges[:min(row.range_count, SYLLABIC_RANGE_LIMIT)] {
			if character >= range.first && character <= range.last {
				return each, true
			}
		}
	}
	return {}, false
}

// syllabic_chain_of gives the chain of a face for a character of the rows.
@(private)
syllabic_chain_of :: proc "contextless" (kind: Chain_Kind, character: rune) -> (chain: Chain, found: bool) {
	script := syllabic_script_of(character) or_return
	return syllabic_script_rows[script].chains[kind], true
}

// is_syllabic_shared says if a character of no script stays in the window
// of a syllable: the joiners, the dotted circle, the grapheme joiner and the
// variation selectors, which HarfBuzz keeps in the run of the script.
@(private)
is_syllabic_shared :: #force_inline proc "contextless" (character: rune) -> bool {
	return character == ZERO_WIDTH_NON_JOINER || character == ZERO_WIDTH_JOINER || character == DOTTED_CIRCLE || character == 0x034F || character >= 0xFE00 && character <= 0xFE0F
}

// is_syllabic_hidden says if a character draws nothing in a syllable: a
// default ignorable character, which HarfBuzz hides after its
// substitutions.
@(private)
is_syllabic_hidden :: #force_inline proc "contextless" (character: rune) -> bool {
	return character == ZERO_WIDTH_NON_JOINER || character == ZERO_WIDTH_JOINER || character == 0x034F || character >= 0xFE00 && character <= 0xFE0F
}

// The window of a syllable: its characters after the normalization, and
// the bytes of the characters of the text that each comes from. The room
// past SYLLABIC_WINDOW_LIMIT holds the dotted circle of a broken syllable.
@(private)
Syllabic_Text :: struct {
	characters: [INDIC_SYLLABLE_LIMIT]rune,
	starts:     [INDIC_SYLLABLE_LIMIT]u32, // The first byte of the characters of the text that it comes from.
	ends:       [INDIC_SYLLABLE_LIMIT]u32, // The byte after them.
	count:      int,
	script:     Syllabic_Script,
	model:      Syllabic_Model,
	end:        int, // The byte after the syllable, once it is cut.
}

// modified_combining_class gives the combining class by which HarfBuzz puts
// marks in order (_hb_modified_combining_class): Unicode, with the changes
// for Tibetan, so that the sign u comes before the sign i, tsa-phru before
// them, and padma after each vowel sign.
@(private)
modified_combining_class :: proc "contextless" (character: rune) -> u8 {
	switch character {
	case 0x0FC6:
		return 254
	case 0x0F39:
		return 127
	}
	class := combining_class_of(character)
	switch class {
	case 130:
		return 132
	case 132:
		return 131
	}
	return class
}

// syllabic_decomposed gives the parts of a character, as HarfBuzz
// decomposes it before it shapes (decompose of hb-ot-shape-normalize.cc):
// the canonical decomposition, and for Khmer its vowels of two parts, when
// the font draws the second part, and the first part or its own parts.
// With none, the character stays whole.
@(private)
syllabic_decomposed :: proc "contextless" (file: ^vector_font.Font_File, model: Syllabic_Model, character: rune, parts: ^[4]rune) -> (count: int) {
	has :: proc "contextless" (file: ^vector_font.Font_File, character: rune) -> bool {
		glyph, problem := vector_font.glyph_of(file, character)
		return problem == .None && glyph > 0
	}
	decomposition :: proc "contextless" (model: Syllabic_Model, character: rune) -> (first, second: rune, found: bool) {
		if model == .Khmer {
			switch character {
			case 0x17BE, 0x17BF, 0x17C0, 0x17C4, 0x17C5:
				// The vowel sign e before the consonant, and the whole sign
				// after it.
				return 0x17C1, character, true
			}
		}
		return syllabic_decomposition_of(character)
	}
	// The first and the second part of each level, from the outside in: a
	// level counts when the font draws its second part.
	firsts, seconds: [3]rune
	levels := 0
	current := character
	for levels < len(seconds) {
		first, second, found := decomposition(model, current)
		if !found || !has(file, second) {
			break
		}
		firsts[levels], seconds[levels] = first, second
		levels += 1
		current = first
	}
	// The deepest level whose first part the font draws, as the recursion
	// of HarfBuzz prefers the deepest that succeeds.
	for levels > 0 && !has(file, firsts[levels - 1]) {
		levels -= 1
	}
	if levels == 0 {
		parts[0] = character
		return 1
	}
	parts[0] = firsts[levels - 1]
	for level in 0 ..< levels {
		parts[1 + level] = seconds[levels - 1 - level]
	}
	return 1 + levels
}

// syllabic_window_read reads the window of a syllable at a byte of a text:
// the characters of the script of its first character and the shared
// characters after it that the font draws, each decomposed, at most
// SYLLABIC_WINDOW_LIMIT, then
// the marks in canonical order and the compositions again. Each byte is
// decoded once. ok is false when the first character is not of a script of
// the rows.
@(private)
syllabic_window_read :: proc "contextless" (text: []u8, place: int, file: ^vector_font.Font_File) -> (window: Syllabic_Text, ok: bool) {
	first, first_length, first_valid := text_encoding.character_decode(text, place)
	if first_length == 0 || !first_valid {
		return {}, false
	}
	window.script = syllabic_script_of(first) or_return
	row := &syllabic_script_rows[window.script]
	window.model = row.model
	at := place
	// HarfBuzz composes again only when its text holds a mark: a window
	// with none keeps each character as decomposed.
	holds_mark := false
	for window.count < SYLLABIC_WINDOW_LIMIT {
		character, length, valid := text_encoding.character_decode(text, at)
		if length == 0 || !valid {
			break
		}
		if script, of_rows := syllabic_script_of(character); of_rows ? script != window.script : !is_syllabic_shared(character) {
			break
		}
		parts: [4]rune
		count := syllabic_decomposed(file, window.model, character, &parts)
		if window.count + count > SYLLABIC_WINDOW_LIMIT {
			break
		}
		// A character that the font does not draw, whole or in parts, ends
		// the window: its fallback chain draws it, not the glyph 0 of the
		// font of the syllable. A character that draws nothing stays.
		if count == 1 && !is_syllabic_hidden(character) {
			if glyph, problem := vector_font.glyph_of(file, character); problem != .None || glyph == 0 {
				break
			}
		}
		holds_mark ||= is_unicode_mark(character)
		for part in parts[:count] {
			window.characters[window.count] = part
			window.starts[window.count] = u32(at)
			window.ends[window.count] = u32(at + length)
			window.count += 1
		}
		at += length
	}
	// The marks of each run of a combining class above 0, in order of
	// their class: a stable sort, as HarfBuzz sorts them.
	for index in 1 ..< window.count {
		class := modified_combining_class(window.characters[index])
		if class == 0 {
			continue
		}
		for back := index; back > 0; back -= 1 {
			before := modified_combining_class(window.characters[back - 1])
			if before == 0 || before <= class {
				break
			}
			syllabic_swap(&window, back - 1, back)
		}
	}
	// A starter and a mark after it compose again when Unicode names the
	// composition, the font draws it, and no mark between them has a
	// class as high (hb-ot-shape-normalize.cc, the third round). The
	// models of Khmer and USE never compose a mark with what follows it.
	kept := 0
	starter := -1
	for index in 0 ..< window.count {
		character := window.characters[index]
		if holds_mark && starter >= 0 && is_unicode_mark(character) && (starter == kept - 1 || modified_combining_class(window.characters[kept - 1]) < modified_combining_class(character)) {
			starter_character := window.characters[starter]
			if window.model == .Myanmar || !is_unicode_mark(starter_character) {
				if composed, found := compose(starter_character, character); found {
					if glyph, problem := vector_font.glyph_of(file, composed); problem == .None && glyph > 0 {
						window.characters[starter] = composed
						window.starts[starter] = min(window.starts[starter], window.starts[index])
						window.ends[starter] = max(window.ends[starter], window.ends[index])
						continue
					}
				}
			}
		}
		window.characters[kept] = character
		window.starts[kept] = window.starts[index]
		window.ends[kept] = window.ends[index]
		if modified_combining_class(character) == 0 {
			starter = kept
		}
		if kept == 0 && starter < 0 {
			starter = 0
		}
		kept += 1
	}
	window.count = kept
	window.end = window.count > 0 ? int(window.ends[window.count - 1]) : place
	return window, window.count > 0
}

// is_unicode_mark says if a character is a mark (Mn, Mc, Me), as the
// normalization of HarfBuzz reads a mark: the table of the marks holds Mn
// and Me, and the spacing marks of the syllabic scripts past India have
// their own table.
@(private)
is_unicode_mark :: proc "contextless" (character: rune) -> bool {
	return is_mark(character) || range_index(character, syllabic_spacing_mark_ranges[:]) >= 0
}

@(private)
syllabic_swap :: proc "contextless" (window: ^Syllabic_Text, first, second: int) {
	window.characters[first], window.characters[second] = window.characters[second], window.characters[first]
	window.starts[first], window.starts[second] = window.starts[second], window.starts[first]
	window.ends[first], window.ends[second] = window.ends[second], window.ends[first]
}

// syllabic_cut keeps the first characters of a window that a match took,
// and ends the syllable at a whole character of the text: a cut inside the
// parts of a character, or between the characters that a composition or
// the order of the marks mixed, moves to the nearest cut before it that
// keeps at least one character, else to the nearest after it.
@(private)
syllabic_cut :: proc "contextless" (window: ^Syllabic_Text, length: int) {
	valid :: proc "contextless" (window: ^Syllabic_Text, cut: int) -> bool {
		if cut <= 0 || cut > window.count {
			return false
		}
		end: u32
		for index in 0 ..< cut {
			end = max(end, window.ends[index])
		}
		for index in cut ..< window.count {
			if window.starts[index] < end {
				return false
			}
		}
		return true
	}
	cut := clamp(length, 1, window.count)
	for cut > 1 && !valid(window, cut) {
		cut -= 1
	}
	for cut < window.count && !valid(window, cut) {
		cut += 1
	}
	window.count = cut
	end: u32
	for index in 0 ..< cut {
		end = max(end, window.ends[index])
	}
	window.end = int(end)
}

// syllabic_insert puts a character at a place of the window, with the
// bytes of the character that it stands before: the dotted circle of a
// broken syllable. false when the window is full.
@(private)
syllabic_insert :: proc "contextless" (window: ^Syllabic_Text, at: int, character: rune) -> bool {
	if window.count >= INDIC_SYLLABLE_LIMIT || at < 0 || at > window.count {
		return false
	}
	for index := window.count; index > at; index -= 1 {
		window.characters[index] = window.characters[index - 1]
		window.starts[index] = window.starts[index - 1]
		window.ends[index] = window.ends[index - 1]
	}
	neighbour := min(at, window.count - 1)
	window.characters[at] = character
	window.starts[at] = window.starts[neighbour]
	window.ends[at] = window.ends[neighbour]
	window.count += 1
	return true
}

// The bits of the mask of a glyph of these shapers: the features that
// apply to it.
@(private)
SYLLABIC_GLOBAL :: u32(1) << 0
@(private)
SYLLABIC_REPH :: u32(1) << 1
@(private)
SYLLABIC_PREF :: u32(1) << 2
@(private)
SYLLABIC_BELOW :: u32(1) << 3
@(private)
SYLLABIC_ABOVE :: u32(1) << 4
@(private)
SYLLABIC_POST :: u32(1) << 5
@(private)
SYLLABIC_CFAR :: u32(1) << 6

// The features of the positions, in one stage. The cursive attachment of
// GPOS is not read yet; no font of the rows asks for it.
@(rodata, private)
syllabic_position_stage := [?]vector_font.Engine_Feature {
	{{'k', 'e', 'r', 'n'}, SYLLABIC_GLOBAL},
	{{'d', 'i', 's', 't'}, SYLLABIC_GLOBAL},
	{{'a', 'b', 'v', 'm'}, SYLLABIC_GLOBAL},
	{{'b', 'l', 'w', 'm'}, SYLLABIC_GLOBAL},
	{{'m', 'a', 'r', 'k'}, SYLLABIC_GLOBAL},
	{{'m', 'k', 'm', 'k'}, SYLLABIC_GLOBAL},
}

// syllabic_buffer_fill puts the glyph of each character of a window into a
// buffer, with its mask: glyph 0 for a character that the font lacks, as
// HarfBuzz shapes it.
@(private)
syllabic_buffer_fill :: proc "contextless" (file: ^vector_font.Font_File, window: ^Syllabic_Text, masks: []u32, buffer: ^vector_font.Engine_Buffer) {
	buffer.count = 0
	for index in 0 ..< min(window.count, len(masks), vector_font.ENGINE_GLYPH_LIMIT) {
		glyph, problem := vector_font.glyph_of(file, window.characters[index])
		buffer.glyphs[buffer.count] = {glyph = u16(problem == .None ? glyph : 0), place = u8(index), mask = masks[index]}
		buffer.count += 1
	}
	vector_font.engine_buffer_prepare(file, buffer)
}

// syllabic_positions takes out the glyphs of the characters that draw
// nothing, and applies the positions: with zero_marks, a mark of GDEF has
// no advance first (the models of Myanmar and USE: HarfBuzz zeroes the
// marks by GDEF early).
@(private)
syllabic_positions :: proc "contextless" (file: ^vector_font.Font_File, tag: vector_font.Feature_Tag, window: ^Syllabic_Text, buffer: ^vector_font.Engine_Buffer, zero_marks: bool, budget: ^vector_font.Layout_Budget) {
	kept := 0
	for glyph in buffer.glyphs[:buffer.count] {
		if int(glyph.place) < window.count && is_syllabic_hidden(window.characters[glyph.place]) && .Ligated not_in glyph.flags {
			continue
		}
		buffer.glyphs[kept] = glyph
		kept += 1
	}
	buffer.count = kept
	vector_font.engine_buffer_prepare(file, buffer)
	if zero_marks {
		for &glyph in buffer.glyphs[:buffer.count] {
			if glyph.class == .Mark {
				glyph.x_advance = 0
			}
		}
	}
	_ = vector_font.engine_stage(file, .Positioning, tag, syllabic_position_stage[:], buffer, budget)
	vector_font.engine_positions_finish(buffer)
}

// syllabic_shape shapes the window of a syllable with its font into a
// buffer, by the model of its script.
@(private)
syllabic_shape :: proc "contextless" (file: ^vector_font.Font_File, window: ^Syllabic_Text, buffer: ^vector_font.Engine_Buffer, budget: ^vector_font.Layout_Budget) {
	tag := syllabic_script_rows[window.script].tag
	switch window.model {
	case .Khmer:
		khmer_shape(file, tag, window, buffer, budget)
	case .Myanmar:
		myanmar_shape(file, tag, window, buffer, budget)
	case .Universal:
		universal_shape(file, tag, window, buffer, budget)
	}
}

// syllabic_shaped shapes the syllable at the byte of the shaper with the
// font of its script, when that font draws its first character and its
// tables name the script; false leaves the shaper as it was.
@(private)
syllabic_shaped :: #force_no_inline proc "contextless" (shaper: ^Shaper, shaped: ^Shaped) -> bool {
	spacing := shaper.spacing
	if spacing.cell_advance > 0 || vector_font.layout_budget_spent(&shaper.budget) {
		return false
	}
	first, length, valid := text_encoding.character_decode(shaper.text, shaper.place)
	if length == 0 || !valid {
		return false
	}
	script, of_rows := syllabic_script_of(first)
	if !of_rows {
		return false
	}
	row := &syllabic_script_rows[script]
	font, _ := font_glyph_in(shaper.set, spacing.face, first)
	if font != row.font {
		return false
	}
	file := &font_at(shaper.set, font).file
	if !vector_font.layout_has_script(file, file.gsub, row.tag) {
		return false
	}
	window, read := syllabic_window_read(shaper.text, shaper.place, file)
	if !read {
		return false
	}
	buffer: vector_font.Engine_Buffer
	syllabic_shape(file, &window, &buffer, &shaper.budget)
	if buffer.count == 0 || vector_font.layout_budget_spent(&shaper.budget) {
		return false
	}
	glyph_starts: [vector_font.ENGINE_GLYPH_LIMIT]u32
	for glyph, index in buffer.glyphs[:buffer.count] {
		glyph_starts[index] = window.starts[min(int(glyph.place), window.count - 1)]
	}
	shaped_of_syllable(shaper, shaped, font, &buffer, &glyph_starts, window.end, row.tag)
	return true
}

// shaped_of_syllable writes the glyphs of a shaped syllable, in units of
// its font, as one Shaped: the first glyph is its base, each glyph after it
// with an advance and no offset a base at the pen, each other anchored at
// its pen plus its offset. The cluster of each glyph is the first byte of
// its characters, made never to go down along the glyphs, as HarfBuzz
// merges them. The shaper then stands at the byte after the syllable.
@(private)
shaped_of_syllable :: proc "contextless" (shaper: ^Shaper, shaped: ^Shaped, font: Outline_Font, buffer: ^vector_font.Engine_Buffer, glyph_starts: ^[vector_font.ENGINE_GLYPH_LIMIT]u32, end: int, tag: vector_font.Feature_Tag) {
	spacing := shaper.spacing
	shaped^ = {start = shaper.place, end = end, script = tag, syllable = true}
	scale := measures_in_frame_of(shaper.set, spacing.face, font).advance
	limit := i64(spacing.size)
	count := clamp(buffer.count, 0, vector_font.ENGINE_GLYPH_LIMIT)
	lowest := max(u32)
	for index := count - 1; index >= 0; index -= 1 {
		lowest = min(lowest, glyph_starts[index])
		glyph_starts[index] = lowest
	}
	pen: i64
	for glyph, index in buffer.glyphs[:min(count, 1 + CLUSTER_MARK_LIMIT)] {
		resolved := resolve_index(spacing, font, int(glyph.glyph))
		resolved.advance = i32(clamp(units_at_size(int(glyph.x_advance), spacing.size, scale), 0, i64(advance_limit_of_size(spacing.size))))
		resolved.cluster = glyph_starts[index]
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
	shaper.place = end
	shaper.previous = .None
	shaper.sara_am_taken = -1
	shaper.after_letter = true
}