package text_rendering

import "base:intrinsics"
import "modus:contract/font_characters"
import "modus:contract/text_encoding"
import "modus:vector_font"

// Text shaping (docs/FONTS.md, "12.3 The text shaping module"): the characters of a
// text become placed glyphs, with the advance of each character and the
// pair adjustment of each pair of characters that follow each other. The
// text is UTF-8 (src/library/modus/contract/text_encoding). A cluster is a
// base and its marks, composed or placed by the anchors of its font; a
// letter of Arabic takes the form of its font; a syllable of Devanagari
// goes through the engine of the lookups (indic.odin); each invalid
// sequence is one placed glyph (src/md/features/written_shaping.md).
//
// Each number comes from the font file of the face, at the text size of
// the spacing: the advance of the table hmtx, and the pair of the table
// kern when two glyphs of one font follow each other. Each is rounded once
// to 1/64 of a pixel, and the x of a glyph is the sum of the integers
// before it. No number depends on a cache, on the grid fit or on the order
// of the stripes, so the measure and the draw of a frame agree.
//
// A process measures over the fonts that it opened (spacing_of). The
// library module text_rendering opens a set of fonts from the bytes of its
// caller for one call (spacing_in): those bytes can be in a call region
// that another thread changes. The parser checks each read of a font file
// against its bytes, so a changed byte gives other numbers, never a read
// out of the file; each advance and each pair is kept in its bound at its
// read, so no sum wraps.

CHARACTER_COUNT :: font_characters.CHARACTER_COUNT // The characters with a character index: ASCII 32 to 126, the Latin-1 Supplement and the added characters.
// The glyph of a character that no font of the chain has, and of each
// invalid sequence of the text: the reader draws the replacement glyph in
// its place (graphics.character_replacement), so that a reader sees that a
// character is there that the font does not draw. It has the advance of
// REPLACEMENT_ADVANCE_CHARACTER, and no pair.
REPLACEMENT_GLYPH :: max(u32)
REPLACEMENT_ADVANCE_CHARACTER :: '0'
// The glyph of a format character that a reader never sees: a control of
// the direction of a line (the isolates of UAX #9, the marks LRM, RLM and
// ALM), a joiner or a non-joiner, a space or a joiner of no width, a soft
// hyphen. It has the advance 0, and the reader draws nothing.
INVISIBLE_GLYPH :: REPLACEMENT_GLYPH - 1

// is_invisible_format says if a character is one of those format
// characters (is_invisible_format: the default ignorable characters that a
// line holds, DerivedCoreProperties.txt).
is_invisible_format :: proc "contextless" (character: rune) -> bool {
	switch character {
	case 0x00AD, 0x061C, 0x180E, 0x200B ..= 0x200F, 0x202A ..= 0x202E, 0x2060 ..= 0x2064, 0x2066 ..= 0x2069, 0xFEFF:
		return true
	}
	return false
}
// The glyph of a character with no character index that the fallback chain
// has is FALLBACK_GLYPH_FIRST plus its code point: past each character
// index, and below REPLACEMENT_GLYPH.
FALLBACK_GLYPH_FIRST :: u32(1) << 24
#assert(FALLBACK_GLYPH_FIRST > CHARACTER_COUNT && u64(FALLBACK_GLYPH_FIRST) + text_encoding.CODE_POINT_LAST < u64(REPLACEMENT_GLYPH))
// The glyph of a form or a ligature that a substitution gave, with no
// character: DIRECT_GLYPH_FIRST, the font in the FONT_FIELD_BITS bits from
// bit 16, the glyph index in bits 0 to 15 (direct_glyph).
DIRECT_GLYPH_FIRST :: u32(1) << 30
DIRECT_GLYPH_SPAN :: u32(1) << (16 + FONT_FIELD_BITS)
#assert(u64(FALLBACK_GLYPH_FIRST) + text_encoding.CODE_POINT_LAST < u64(DIRECT_GLYPH_FIRST) && u64(DIRECT_GLYPH_FIRST) + u64(DIRECT_GLYPH_SPAN) < u64(REPLACEMENT_GLYPH) - 1)

// direct_glyph gives the placed glyph of a glyph of a font by its index.
direct_glyph :: #force_inline proc "contextless" (font: Outline_Font, index: int) -> u32 {
	return DIRECT_GLYPH_FIRST | u32(font) << 16 | u32(index) & 0xFFFF
}

// direct_glyph_parts gives the font and the glyph index of a placed glyph
// of DIRECT_GLYPH_FIRST; ok is false for each other glyph, and for a font
// that names no member: a placed glyph from another party is checked.
direct_glyph_parts :: proc "contextless" (glyph: u32) -> (font: Outline_Font, index: int, ok: bool) {
	if glyph < DIRECT_GLYPH_FIRST || glyph >= DIRECT_GLYPH_FIRST + DIRECT_GLYPH_SPAN {
		return .None, 0, false
	}
	number := (glyph >> 16) & (1 << FONT_FIELD_BITS - 1)
	font, ok = outline_font_of_word(u64(number))
	if !ok {
		return .None, 0, false
	}
	return font, int(glyph & 0xFFFF), true
}

// The base of a mark with no base (the Unicode Standard, "Display of
// combining marks with no base").
DOTTED_CIRCLE :: rune(0x25CC)
// The marks of one cluster; a mark past it starts a cluster of its own,
// on a dotted circle.
CLUSTER_MARK_LIMIT :: 16
// The most bytes of one text.
TEXT_LIMIT :: 1 << 16
// The widest cell of a grid of cells, in 1/64 of a pixel: the cell of the
// largest text size is half of it.
CELL_ADVANCE_LIMIT :: TEXT_SIZE_LIMIT
// An advance is at most one line and a pair at most half a line, at any
// size (advance_limit_of_size, pair_limit_of_size): the place of the last
// glyph of the longest text at the largest size stays in an i32 of 1/64 of
// a pixel.
#assert(TEXT_LIMIT * (TEXT_SIZE_LIMIT + TEXT_SIZE_LIMIT / 2) < 1 << 31)
#assert(TEXT_LIMIT * CELL_ADVANCE_LIMIT < 1 << 31)

// How the reader places a glyph (src/md/features/written_shaping.md, "The
// anchors of the marks").
Glyph_Placement :: enum u32 {
	Base     = 0, // A glyph with a place of its own: its origin at x, on the baseline.
	Anchored = 1, // A mark that the anchors of its font place: its origin at x, y above the baseline.
	Centred  = 2, // A mark that no anchor places: the reader centres it on the advance of the base before it.
}

// Placed_Glyph: one glyph of a text, placed. x is from the origin of the
// text; advance includes the pair adjustment with the next glyph; so the x
// of a base is the sum of the advances before it. A mark has the advance 0
// and the placement of its kind.
Placed_Glyph :: struct {
	glyph:     u32, // The character index of the character (font_characters.character_index); FALLBACK_GLYPH_FIRST plus the code point: a character past them that the fallback chain has; DIRECT_GLYPH_FIRST and a glyph of a font: a form that a substitution gave; REPLACEMENT_GLYPH: a character that no font of the chain has.
	x:         i32, // In 1/64 of a pixel.
	y:         i32, // In 1/64 of a pixel, up from the baseline: 0 but for an anchored mark.
	advance:   i32, // In 1/64 of a pixel.
	cluster:   u32, // The first byte of the character in the text.
	placement: Glyph_Placement,
}
#assert(size_of(Placed_Glyph) == 24)

// Text_Range: one text of a table of bytes, and its width, which the
// measure writes.
Text_Range :: struct {
	start: u32, // The first byte, in the table of bytes.
	count: u32, // Its bytes: at most TEXT_LIMIT.
	width: i64, // In 1/64 of a pixel.
}
#assert(size_of(Text_Range) == 16)

// Spacing: what places the characters of a text. A face at a text size,
// over a set of fonts; or one advance for every character: a grid of cells.
Spacing :: struct {
	// The fonts: nil is the set that this copy of the package opened (open).
	fonts:         ^Font_Set,
	face:          Face,
	size:          int, // The text size, in 1/64 of a pixel.
	cell_advance:  i32, // Above 0: each character, the replacement glyph too, has this advance and no pair: the cells of a grid.
	without_pairs: bool, // No pair adjustment: the text as its advances alone place it.
}

// spacing_of gives the spacing of a face at a text size over the fonts
// that this copy opened. ok is false for the face None, for a size that
// size_check refuses, and before open or when the outlines lack the first
// font of the face: then no character of the face has a measure.
spacing_of :: proc "contextless" (face: Face, size: int) -> (spacing: Spacing, ok: bool) {
	return spacing_in(&state.font_set, face, size)
}

// spacing_in is spacing_of over a set of fonts.
spacing_in :: proc "contextless" (set: ^Font_Set, face: Face, size: int) -> (spacing: Spacing, ok: bool) {
	if face == .None || size_check(size) != .None || !set.opened || !font_at(set, face_forms[face].primary).opened {
		return {}, false
	}
	return {fonts = set, face = face, size = size}, true
}

// cell_spacing gives the spacing of a grid of cells of a width in pixels:
// each character is one cell. The width is kept from 1 pixel to
// CELL_ADVANCE_LIMIT.
cell_spacing :: proc "contextless" (cell_width: int) -> Spacing {
	return {cell_advance = i32(clamp(cell_width, 1, CELL_ADVANCE_LIMIT / SUBPIXEL)) * SUBPIXEL}
}

// glyph_of gives the glyph of a character in a grid of cells: its
// character index, or REPLACEMENT_GLYPH.
glyph_of :: #force_inline proc "contextless" (character: rune) -> u32 {
	index, found := font_characters.character_index(character)
	if !found {
		return REPLACEMENT_GLYPH
	}
	return u32(index)
}

// Resolved: one glyph of a text, found once in the fonts: its placed
// glyph, the font and the glyph of that font that measure it, its advance
// with no pair, and the first byte of its character.
@(private)
Resolved :: struct {
	glyph:     u32, // As Placed_Glyph.glyph.
	font:      Outline_Font, // None: a cell, or the replacement glyph; neither has a pair.
	index:     i32, // The glyph index in that font: 16 bits.
	advance:   i32, // From 0 to its bound.
	cluster:   u32, // The first byte of its character in the text.
	// A mark: its place from the origin of its base, in 1/64 of a pixel,
	// and how the reader places it.
	offset_x:  i32,
	offset_y:  i32,
	placement: Glyph_Placement,
}

// The cells of a character in a grid of cells: a mark none, a wide
// character two, each other one.
@(private)
cell_advance_of :: proc "contextless" (spacing: ^Spacing, character: rune) -> i32 {
	cells: i32 = cell_width_of(character) == .Two ? 2 : 1
	return clamp(spacing.cell_advance * cells, 0, CELL_ADVANCE_LIMIT)
}

// resolve finds a decoded character in the spacing: an invalid sequence,
// and a character that no font of the chain has, is the replacement glyph
// with the advance of REPLACEMENT_ADVANCE_CHARACTER.
@(private)
resolve :: proc "contextless" (spacing: ^Spacing, character: rune, valid: bool) -> (resolved: Resolved) {
	resolved, _ = resolve_in_chain(spacing, character, valid, .Take)
	return resolved
}

// resolve_in_chain is resolve, with the rule of the walk of the chain for
// a font of the script font set. reached is true when the rule Stop met
// such a font before a font that has the character: the fast part does not
// place that character.
@(private)
resolve_in_chain :: proc "contextless" (spacing: ^Spacing, character: rune, valid: bool, rule: Script_Font_Rule) -> (resolved: Resolved, reached: bool) {
	if spacing.cell_advance > 0 {
		resolved.glyph = valid ? glyph_of(character) : REPLACEMENT_GLYPH
		resolved.advance = valid ? cell_advance_of(spacing, character) : clamp(spacing.cell_advance, 0, CELL_ADVANCE_LIMIT)
		return resolved, false
	}
	set := spacing.fonts != nil ? spacing.fonts : &state.font_set
	if valid && is_invisible_format(character) {
		resolved.glyph = INVISIBLE_GLYPH
		return resolved, false
	}
	font: Outline_Font
	index: int
	if valid {
		font, index, reached = chain_glyph(set, spacing.face, character, rule)
		if reached {
			return {}, true
		}
	}
	if font == .None {
		resolved.glyph = REPLACEMENT_GLYPH
		// The digit zero is in the first font of each face: no font of the
		// set is asked.
		zero_font, zero_index, _ := chain_glyph(set, spacing.face, REPLACEMENT_ADVANCE_CHARACTER, .Skip)
		resolved.advance, _ = glyph_advance_in(set, spacing.face, zero_font, zero_index, spacing.size)
		return resolved, false
	}
	if character_index, in_cache := font_characters.character_index(character); in_cache {
		resolved.glyph = u32(character_index)
	} else {
		resolved.glyph = FALLBACK_GLYPH_FIRST + u32(character)
	}
	resolved.font, resolved.index = font, i32(index)
	resolved.advance, _ = glyph_advance_in(set, spacing.face, font, index, spacing.size)
	return resolved, false
}

// resolve_index is resolve for a glyph of a font by its index: a form or a
// ligature that a substitution gave.
@(private)
resolve_index :: proc "contextless" (spacing: ^Spacing, font: Outline_Font, index: int) -> (resolved: Resolved) {
	set := spacing.fonts != nil ? spacing.fonts : &state.font_set
	resolved = {glyph = direct_glyph(font, index), font = font, index = i32(index & 0xFFFF)}
	resolved.advance, _ = glyph_advance_in(set, spacing.face, font, index, spacing.size)
	return resolved
}

// pair_of gives the adjustment of the pair of two resolved characters: the
// pair of their font when both come from one font, else 0.
@(private)
pair_of :: proc "contextless" (spacing: ^Spacing, left, right: Resolved) -> i32 {
	if spacing.cell_advance > 0 || spacing.without_pairs || left.font == .None || left.font != right.font {
		return 0
	}
	set := spacing.fonts != nil ? spacing.fonts : &state.font_set
	return glyph_pair_in(set, spacing.face, left.font, int(left.index), int(right.index), spacing.size)
}

// ---- The clusters (src/md/features/written_shaping.md).

// Cluster: a base and the marks after it, read from a text, with the
// composition of UAX #15 done: base is the composed character when a font
// has it, and marks are those that stayed apart.
Cluster :: struct {
	base:         rune,
	base_valid:   bool, // false: an invalid sequence, the replacement glyph.
	dotted:       bool, // The marks had no base: base is the dotted circle.
	marks:         [CLUSTER_MARK_LIMIT]rune,
	mark_places:   [CLUSTER_MARK_LIMIT]u32, // The first byte of each mark.
	mark_count:    int,
	start, end:    int, // Its bytes.
	sara_am_taken: int, // The byte of the SARA AM after it whose NIKHAHIT it took; -1: none.
}

// is_cluster_break says if a character takes no mark: a space, a separator
// or a control, the bidirectional classes WS, S and B. A mark after it has
// no base. The characters are written here, not read from the table of the
// classes: the fast part reads the cells of a grid with it, and that table
// is the written part (the_cluster_breaks_are_the_classes_of_unicode).
@(private)
is_cluster_break :: proc "contextless" (character: rune) -> bool {
	switch character {
	case 0x0009 ..= 0x000D, 0x001C ..= 0x0020, 0x0085, 0x1680, 0x2000 ..= 0x200A, 0x2028, 0x2029, 0x205F, 0x3000:
		return true
	}
	return false
}

// SARA AM of Thai (U+0E33) and of Lao (U+0EB3) is two parts: NIKHAHIT, a
// mark on the consonant before it, and SARA AA, a vowel of its own (the
// OpenType Thai shaper, which HarfBuzz follows). The mark goes before the
// tone marks and the vowels above that the consonant holds, so that they
// stack on it.
@(private)
SARA_AM_THAI :: rune(0x0E33)
@(private)
SARA_AM_LAO :: rune(0x0EB3)

// is_thai_above_mark says if a mark of Thai or Lao is one that NIKHAHIT
// goes before: a tone mark or a vowel above.
@(private)
is_thai_above_mark :: proc "contextless" (character: rune) -> bool {
	switch character & ~rune(0x0080) {
	case 0x0E31, 0x0E34 ..= 0x0E37, 0x0E3B, 0x0E47 ..= 0x0E4E:
		return true
	}
	return false
}

// is_sara_am says if a character is SARA AM of Thai or of Lao.
is_sara_am :: #force_inline proc "contextless" (character: rune) -> bool {
	return character == SARA_AM_THAI || character == SARA_AM_LAO
}

// cluster_read reads the cluster that starts at a byte of a text: a base
// and at most CLUSTER_MARK_LIMIT marks after it, in canonical order, then
// composes them. A composition that no font of the face draws is not made.
// sara_am_taken is the byte of the SARA AM whose NIKHAHIT the cluster
// before took (Cluster.sara_am_taken), -1 for none: the cluster that starts
// there is its SARA AA. Each byte of the text is decoded once for the
// cluster, so a text that another thread changes gives other glyphs, and
// never a read or a write past a table.
cluster_read :: proc "contextless" (set: ^Font_Set, face: Face, text: []u8, place: int, sara_am_taken := -1) -> (cluster: Cluster, ok: bool) {
	when WRITTEN_SHAPING_COMPILED_IN {
		return cluster_read_written(set, face, text, place, sara_am_taken)
	} else {
		// A simple character before a simple character, or the end, is a
		// cluster of one character: no mark follows it, and no SARA AM.
		character, length, valid := text_encoding.character_decode(text, place)
		if length == 0 {
			return {}, false
		}
		next, next_length, next_valid := text_encoding.character_decode(text, place + length)
		if (!valid || is_simple(character)) && (next_length == 0 || !next_valid || is_simple(next)) {
			return cluster_of_one(text, place)
		}
		if set == &state.font_set {
			if read, read_ok, called := held_cluster_read(face, text, place, sara_am_taken); called {
				return read, read_ok
			}
		}
		return cluster_of_one(text, place)
	}
}

// cluster_read_written is cluster_read in the written part.
@(private)
cluster_read_written :: proc "contextless" (set: ^Font_Set, face: Face, text: []u8, place: int, sara_am_taken := -1) -> (cluster: Cluster, ok: bool) {
	character, length, valid := text_encoding.character_decode(text, place)
	if length == 0 {
		return {}, false
	}
	cluster.start = place
	cluster.sara_am_taken = -1
	at := place
	if valid && is_mark(character) {
		cluster.base, cluster.base_valid, cluster.dotted = DOTTED_CIRCLE, true, true
	} else {
		cluster.base, cluster.base_valid = character, valid
		// The vowel of a SARA AM whose NIKHAHIT the cluster before took.
		if valid && is_sara_am(character) && place == sara_am_taken {
			cluster.base = character - 1
		}
		at += length
		if !valid || is_cluster_break(character) {
			cluster.end = at
			return cluster, true
		}
	}
	for cluster.mark_count < CLUSTER_MARK_LIMIT {
		mark, mark_length, mark_valid := text_encoding.character_decode(text, at)
		if mark_length == 0 || !mark_valid || !is_mark(mark) {
			break
		}
		cluster.marks[cluster.mark_count] = mark
		cluster.mark_places[cluster.mark_count] = u32(at)
		cluster.mark_count += 1
		at += mark_length
	}
	cluster.end = at
	// The NIKHAHIT of a SARA AM after the cluster, before its tone marks
	// and its vowels above: when the fonts draw both of its parts and the
	// cluster has room for one more mark. The cluster after it learns it
	// from sara_am_taken, not from a second read of the text.
	sara_am, sara_am_length, sara_am_valid := text_encoding.character_decode(text, at)
	if !cluster.dotted && sara_am_length > 0 && sara_am_valid && is_sara_am(sara_am) && cluster.mark_count < CLUSTER_MARK_LIMIT && character_drawn(set, face, sara_am + 0x1A) && character_drawn(set, face, sara_am - 1) {
		cluster.sara_am_taken = at
		position := cluster.mark_count
		for position > 0 && is_thai_above_mark(cluster.marks[position - 1]) {
			position -= 1
		}
		for index := cluster.mark_count; index > position; index -= 1 {
			cluster.marks[index] = cluster.marks[index - 1]
			cluster.mark_places[index] = cluster.mark_places[index - 1]
		}
		cluster.marks[position] = sara_am + 0x1A
		cluster.mark_places[position] = u32(at)
		cluster.mark_count += 1
	}
	if cluster.dotted || cluster.mark_count == 0 {
		return cluster, true
	}
	// The canonical order: a stable sort of the marks by their class.
	for index in 1 ..< cluster.mark_count {
		for back := index; back > 0 && combining_class_of(cluster.marks[back]) < combining_class_of(cluster.marks[back - 1]) && combining_class_of(cluster.marks[back]) != 0; back -= 1 {
			cluster.marks[back], cluster.marks[back - 1] = cluster.marks[back - 1], cluster.marks[back]
			cluster.mark_places[back], cluster.mark_places[back - 1] = cluster.mark_places[back - 1], cluster.mark_places[back]
		}
	}
	// The composition: each mark composes with the base unless a mark that
	// stayed apart before it blocks it (UAX #15, D115): a kept mark of the
	// class 0, anywhere before it, is a starter that blocks each mark
	// after it; else the last kept mark, the highest class in canonical
	// order, blocks a mark of its class or lower.
	kept := 0
	kept_starter := false
	for index in 0 ..< cluster.mark_count {
		mark := cluster.marks[index]
		class := combining_class_of(mark)
		blocked := kept_starter || (kept > 0 && combining_class_of(cluster.marks[kept - 1]) >= class)
		if !blocked {
			if composed, found := compose(cluster.base, mark); found && character_drawn(set, face, composed) {
				cluster.base = composed
				continue
			}
		}
		cluster.marks[kept] = mark
		cluster.mark_places[kept] = cluster.mark_places[index]
		kept += 1
		kept_starter ||= class == 0
	}
	cluster.mark_count = kept
	return cluster, true
}

// character_drawn says if the fonts of a face draw a character; with no
// face, if it has a character index (Spleen and a grid of cells).
@(private)
character_drawn :: proc "contextless" (set: ^Font_Set, face: Face, character: rune) -> bool {
	if face == .None || !set.opened {
		_, found := font_characters.character_index(character)
		return found
	}
	font, _ := font_glyph_in(set, face, character)
	return font != .None
}

// Shaped: one cluster, shaped: its base glyph and its marks.
@(private)
Shaped :: struct {
	base:       Resolved,
	marks:      [CLUSTER_MARK_LIMIT]Resolved,
	mark_count: int,
	start, end: int,
	script:     vector_font.Feature_Tag, // The script of its base in the tables of its font: the anchors of its marks.
	// A syllable that the engine of the lookups shaped (indic.odin): its
	// glyphs hold their pairs already, so no pair of the table kern joins
	// it to the cluster beside it.
	syllable:   bool,
}

// Shaper: the walk over the clusters of a text, with the joining type of
// the base of the cluster before (Arabic).
@(private)
Shaper :: struct {
	spacing:  ^Spacing,
	set:      ^Font_Set,
	text:     []u8,
	place:    int,
	previous: Joining_Type,
	// The byte of the SARA AM whose NIKHAHIT the last cluster took; -1:
	// none (Cluster.sara_am_taken).
	sara_am_taken: int,
	// The cluster before ended with a letter or a mark: the next syllable
	// of a script of India does not start a word (the feature init).
	after_letter:  bool,
	// The work of the engine of the lookups for the whole call, in
	// proportion to the bytes of the text (vector_font.layout_budget_of_text):
	// each syllable, each test of the font and each pair take from it.
	budget:        vector_font.Layout_Budget,
}

@(private)
shaper_of :: proc "contextless" (spacing: ^Spacing, text: []u8) -> Shaper {
	return {spacing = spacing, set = spacing.fonts != nil ? spacing.fonts : &state.font_set, text = text, sara_am_taken = -1, budget = vector_font.layout_budget_of_text(len(text))}
}

// The Arabic letters that make a ligature with a lam before them: the
// alefs.
@(private)
is_alef :: #force_inline proc "contextless" (character: rune) -> bool {
	return character == 0x0622 || character == 0x0623 || character == 0x0625 || character == 0x0627
}
@(private)
LAM :: rune(0x0644)

@(private)
joins_after :: #force_inline proc "contextless" (type: Joining_Type) -> bool {
	return type == .Dual || type == .Left || type == .Join_Causing
}
@(private)
joins_before :: #force_inline proc "contextless" (type: Joining_Type) -> bool {
	return type == .Dual || type == .Right || type == .Join_Causing
}

@(private)
ARAB :: vector_font.Feature_Tag{'a', 'r', 'a', 'b'}

// form_feature gives the feature of the form of a letter that joins the
// letter before it, the letter after it, both, or neither.
@(private)
form_feature :: proc "contextless" (before, after: bool) -> vector_font.Feature_Tag {
	switch {
	case before && after:
		return {'m', 'e', 'd', 'i'}
	case before:
		return {'f', 'i', 'n', 'a'}
	case after:
		return {'i', 'n', 'i', 't'}
	}
	return {'i', 's', 'o', 'l'}
}

// The most marks that the substitutions of a font make of one letter: the
// dots of a letter of Arabic.
FONT_MARK_LIMIT :: vector_font.SEQUENCE_LIMIT

// font_forms shapes a letter of Arabic with the substitutions of its font
// (src/md/features/written_shaping.md, "The joining of Arabic"): ccmp,
// which makes some letters a dotless body and its dots, then the feature of
// its form (init, medi, fina or isol) on the body. It gives the body and
// the glyphs of the marks that the font made; changed is false when the
// font changes nothing.
@(private)
font_forms :: proc "contextless" (set: ^Font_Set, font: Outline_Font, index: int, before, after: bool, marks: ^[FONT_MARK_LIMIT]int, budget: ^vector_font.Layout_Budget) -> (body, mark_count: int, changed: bool) {
	file := &font_at(set, font).file
	parts: [vector_font.SEQUENCE_LIMIT]int
	part_count, problem := vector_font.script_substitution(file, ARAB, {'c', 'c', 'm', 'p'}, index, parts[:], budget)
	if problem != .None {
		parts[0], part_count = index, 1
	}
	formed: [vector_font.SEQUENCE_LIMIT]int
	formed_count: int
	formed_count, problem = vector_font.script_substitution(file, ARAB, form_feature(before, after), parts[0], formed[:], budget)
	if problem != .None {
		formed[0], formed_count = parts[0], 1
	}
	body = formed[0]
	for glyph in formed[1:formed_count] {
		if mark_count < FONT_MARK_LIMIT {
			marks[mark_count] = glyph
			mark_count += 1
		}
	}
	for glyph in parts[1:part_count] {
		if mark_count < FONT_MARK_LIMIT {
			marks[mark_count] = glyph
			mark_count += 1
		}
	}
	return body, mark_count, body != index || mark_count > 0
}

// opentype_script_of gives the tag of the script of a character in the
// tables GSUB and GPOS; a font without it takes DFLT (vector_font.layout_lookups).
@(private)
opentype_script_of :: proc "contextless" (character: rune) -> vector_font.Feature_Tag {
	switch character {
	case 0x0590 ..= 0x05FF, 0xFB1D ..= 0xFB4F:
		return {'h', 'e', 'b', 'r'}
	case 0x0600 ..= 0x08FF, 0xFB50 ..= 0xFDFF, 0xFE70 ..= 0xFEFF:
		return ARAB
	case 0x0370 ..= 0x03FF, 0x1F00 ..= 0x1FFF:
		return {'g', 'r', 'e', 'k'}
	case 0x0400 ..= 0x052F:
		return {'c', 'y', 'r', 'l'}
	case 0x0E00 ..= 0x0E7F:
		return {'t', 'h', 'a', 'i'}
	case 0x0900 ..= 0x097F:
		return {'d', 'e', 'v', '2'}
	}
	return {'l', 'a', 't', 'n'}
}

// mark_place places a mark that stayed apart with the anchors of its font
// (vector_font.mark_anchor_offset): on the mark before it on the same base
// (mkmk), else on its base (mark). A mark of another font than its base, or
// with no anchor, stays Centred: the reader centres it.
@(private)
mark_place :: proc "contextless" (spacing: ^Spacing, set: ^Font_Set, shaped: ^Shaped, mark: ^Resolved, budget: ^vector_font.Layout_Budget) {
	font := mark.font
	if font == .None || font != shaped.base.font || spacing.cell_advance > 0 {
		return
	}
	file := &font_at(set, font).file
	if file.gpos.length == 0 {
		return
	}
	scale := measures_in_frame_of(set, spacing.face, font).advance
	limit := i64(spacing.size)
	if shaped.mark_count > 0 {
		before := &shaped.marks[shaped.mark_count - 1]
		if before.font == font && before.placement == .Anchored {
			if dx, dy, found, problem := vector_font.mark_anchor_offset(file, shaped.script, .Mark, int(before.index), int(mark.index), budget); problem == .None && found {
				mark.offset_x = i32(clamp(i64(before.offset_x) + units_at_size(dx, spacing.size, scale), -limit, limit))
				mark.offset_y = i32(clamp(i64(before.offset_y) + units_at_size(dy, spacing.size, scale), -limit, limit))
				mark.placement = .Anchored
				return
			}
		}
	}
	if dx, dy, found, problem := vector_font.mark_anchor_offset(file, shaped.script, .Base, int(shaped.base.index), int(mark.index), budget); problem == .None && found {
		mark.offset_x = i32(clamp(units_at_size(dx, spacing.size, scale), -limit, limit))
		mark.offset_y = i32(clamp(units_at_size(dy, spacing.size, scale), -limit, limit))
		mark.placement = .Anchored
	}
}

// shaper_next shapes the next cluster of the text; false at its end.
@(private)
shaper_next :: proc "contextless" (shaper: ^Shaper, shaped: ^Shaped) -> bool {
	if indic_shaped(shaper, shaped) || syllabic_shaped(shaper, shaped) {
		return true
	}
	cluster := cluster_read_written(shaper.set, shaper.spacing.face, shaper.text, shaper.place, shaper.sara_am_taken) or_return
	shaper.sara_am_taken = cluster.sara_am_taken
	shaped^ = {start = cluster.start, end = cluster.end}
	spacing := shaper.spacing
	shaped.base = resolve(spacing, cluster.base, cluster.base_valid)
	shaped.base.cluster = u32(cluster.start)
	shaped.script = opentype_script_of(cluster.base)
	type := cluster.base_valid && !cluster.dotted ? joining_type_of(cluster.base) : .None
	ligature_cluster: Cluster
	ligature_made := false
	if type != .None && type != .Transparent && spacing.cell_advance == 0 && shaped.base.font != .None {
		next, next_length, next_valid := text_encoding.character_decode(shaper.text, cluster.end)
		// The letter after it, through the format characters of no width
		// (Transparent): an LRM between two letters keeps their join. At
		// most CLUSTER_MARK_LIMIT of them are looked through.
		next_type := next_length > 0 && next_valid ? joining_type_of(next) : .None
		ahead := cluster.end + next_length
		for _ in 0 ..< CLUSTER_MARK_LIMIT {
			if next_type != .Transparent {
				break
			}
			after_next, after_length, after_valid := text_encoding.character_decode(shaper.text, ahead)
			next_type = after_length > 0 && after_valid ? joining_type_of(after_next) : .None
			ahead += after_length
		}
		if next_type == .Transparent {
			next_type = .None
		}
		before := joins_after(shaper.previous) && joins_before(type)
		after := joins_after(type) && joins_before(next_type)
		base_cluster := shaped.base.cluster
		// Lam and an alef after it: one glyph, the ligature of the
		// presentation forms, final when the lam joins the letter before.
		if cluster.base == LAM && next_length > 0 && next_valid && is_alef(next) {
			ligature := lam_alef_of(next, before)
			if ligature != 0 && character_drawn(shaper.set, spacing.face, ligature) {
				if after_cluster, read := cluster_read_written(shaper.set, spacing.face, shaper.text, cluster.end, cluster.sara_am_taken); read {
					ligature_cluster = after_cluster
					ligature_made = true
					shaped.base = resolve(spacing, ligature, true)
					shaped.base.cluster = base_cluster
					type = .Right // The ligature ends with the alef, which joins nothing after it.
				}
			}
		}
		if !ligature_made {
			// The forms of the font, with the dots that its anchors place,
			// when its GSUB makes them and its GPOS places them; else the
			// presentation form that Unicode names, when the font has it.
			font := shaped.base.font
			file := &font_at(shaper.set, font).file
			made := false
			if file.gsub.length > 0 && file.gpos.length > 0 {
				font_marks: [FONT_MARK_LIMIT]int
				body, font_mark_count, changed := font_forms(shaper.set, font, int(shaped.base.index), before, after, &font_marks, &shaper.budget)
				if changed {
					shaped.base = resolve_index(spacing, font, body)
					shaped.base.cluster = base_cluster
					for glyph in font_marks[:min(font_mark_count, CLUSTER_MARK_LIMIT)] {
						mark := resolve_index(spacing, font, glyph)
						mark.advance = 0
						mark.cluster = base_cluster
						mark.placement = .Centred
						mark_place(spacing, shaper.set, shaped, &mark, &shaper.budget)
						shaped.marks[shaped.mark_count] = mark
						shaped.mark_count += 1
					}
					made = true
				}
			}
			if !made {
				if form := arabic_form_of(cluster.base, before, after); form != 0 && character_drawn(shaper.set, spacing.face, form) {
					shaped.base = resolve(spacing, form, true)
				}
			}
			shaped.base.cluster = base_cluster
		}
	}
	// A format character of no width keeps the type of the letter before
	// it for the letter after it.
	if type != .Transparent {
		shaper.previous = type
	}
	#partial switch bidi_class_of(cluster.base) {
	case .L, .R, .AL:
		shaper.after_letter = cluster.base_valid && !is_cluster_break(cluster.base)
	case:
		shaper.after_letter = cluster.mark_count > 0
	}
	shaper.place = cluster.end
	marks_add(spacing, shaper.set, shaped, &cluster, &shaper.budget)
	if ligature_made {
		shaped.end = ligature_cluster.end
		shaper.place = ligature_cluster.end
		// The cluster after the ligature learns from the alef, the last
		// cluster read, whether its SARA AM lost its NIKHAHIT.
		shaper.sara_am_taken = ligature_cluster.sara_am_taken
		marks_add(spacing, shaper.set, shaped, &ligature_cluster, &shaper.budget)
	}
	return true
}

// marks_add resolves the marks of a cluster that stayed apart: each with
// the advance 0, or the replacement glyph and its advance when no font has
// it, so that a reader sees it.
@(private)
marks_add :: proc "contextless" (spacing: ^Spacing, set: ^Font_Set, shaped: ^Shaped, cluster: ^Cluster, budget: ^vector_font.Layout_Budget) {
	for index in 0 ..< cluster.mark_count {
		if shaped.mark_count >= CLUSTER_MARK_LIMIT {
			return
		}
		mark := resolve(spacing, cluster.marks[index], true)
		if mark.glyph != REPLACEMENT_GLYPH || spacing.cell_advance > 0 {
			mark.advance = 0
			mark.placement = .Centred
			mark_place(spacing, set, shaped, &mark, budget)
		}
		mark.cluster = cluster.mark_places[index]
		shaped.marks[shaped.mark_count] = mark
		shaped.mark_count += 1
	}
}

// The records on the stack of shape, by the depth at which they run
// together. shape holds two Shaped; under it run, one at a time, three
// branches:
//   - shaper_next, with the cluster that it reads, the cluster after a lam
//     (lam-alef), the marks of the forms of a letter of Arabic, then under
//     it mark_place and mark_anchor_offset with its pool of walked
//     indices, or the lookups of a walk before it (font_forms reads the
//     same, one at a time);
//   - indic_shaped, never inlined into shaper_next, with its syllable, its
//     buffer of the engine, its sources and the glyphs of its clusters;
//     under it indic_shape with its work (Indic_Work), then either the
//     tests of a feature on exact glyphs (layout_would_substitute) or a
//     stage of the engine with its nested levels
//     (vector_font.ENGINE_DEEPEST_RECORDS_BYTES): a call over the fonts of
//     the process runs them;
//   - syllabic_shaped, never inlined into shaper_next, with its window, its
//     buffer and the bytes of its glyphs; under it the shaper of its model
//     with its categories, its masks and the work of USE, or the
//     positions of the first reordering of Myanmar, then a stage of the
//     engine with its nested levels;
//   - bidi_line_reorder with its levels and its order, then bidi_levels
//     with its classes, its links and the stack of its isolates, then
//     brackets_resolve with its openings and its pairs.
// The library module text_rendering adds its fonts and asserts the sum
// against its stack bound: the freestanding build runs on no host, so its
// frames are bounded by these sizes; the host test measures a whole call.
@(private)
SHAPER_NEXT_RECORDS_BYTES :: 2 * size_of(Cluster) + FONT_MARK_LIMIT * size_of(int) + vector_font.SUBSTITUTION_LOOKUP_LIMIT * size_of(u16) + size_of(vector_font.Layout_Lookups)
@(private)
INDIC_SHAPED_RECORDS_BYTES :: size_of(Indic_Syllable) + size_of(vector_font.Engine_Buffer) + INDIC_SYLLABLE_LIMIT + vector_font.ENGINE_GLYPH_LIMIT * size_of(u32) + size_of(Indic_Work) + max(vector_font.ENGINE_DEEPEST_RECORDS_BYTES, vector_font.WOULD_SUBSTITUTE_RECORDS_BYTES)
@(private)
SYLLABIC_SHAPED_RECORDS_BYTES :: size_of(Syllabic_Text) + size_of(vector_font.Engine_Buffer) + vector_font.ENGINE_GLYPH_LIMIT * size_of(u32) + max(size_of(Universal_Work) + INDIC_SYLLABLE_LIMIT * (size_of(u32) + size_of(bool)) + size_of(Syllable_Categories) + SYLLABIC_WINDOW_LIMIT, vector_font.ENGINE_GLYPH_LIMIT * size_of(Indic_Place)) + vector_font.ENGINE_DEEPEST_RECORDS_BYTES
@(private)
BIDI_RECORDS_BYTES :: BIDI_GLYPH_LIMIT * (size_of(u8) + size_of(u16)) + BIDI_GLYPH_LIMIT * (size_of(Bidi_Class) + size_of(u8)) + (BIDI_DEPTH_LIMIT + 2) + BIDI_BRACKET_STACK_LIMIT * (size_of(rune) + size_of(u16)) + BIDI_BRACKET_PAIR_LIMIT * 2 * size_of(u16)
SHAPE_STACK_RECORDS_BYTES :: 2 * size_of(Shaped) + max(SHAPER_NEXT_RECORDS_BYTES, INDIC_SHAPED_RECORDS_BYTES, SYLLABIC_SHAPED_RECORDS_BYTES, BIDI_RECORDS_BYTES)

// shape places the characters of a text: it writes the placed glyphs that
// fit from the start of placed, and gives the count of the full answer
// (one for each cluster of a base and its composed marks, one for each mark
// that stayed apart or that the font of a letter of Arabic made, one for
// each glyph of a syllable of Devanagari, one for each invalid sequence)
// and the width of the text, the sum of the advances. ok is false for a text of more than
// TEXT_LIMIT bytes: nothing is written. Each character of the text is
// decoded once for its cluster: a text that another thread changes during
// the call gives other glyphs, and never a place past the text.
//
// When every placed glyph fits, the places are reordered for a line of
// mixed direction (UAX #9): the x of each glyph is then its place on the
// screen, and its order in placed stays the order of the text.
shape :: proc "contextless" (spacing: ^Spacing, text: []u8, placed: []Placed_Glyph) -> (count: int, width: i64, ok: bool) {
	if len(text) > TEXT_LIMIT {
		return 0, 0, false
	}
	simple: bool
	if count, width, simple = shape_simple(spacing, text, placed, false); simple {
		return count, width, true
	}
	when WRITTEN_SHAPING_COMPILED_IN {
		return shape_written(spacing, text, placed)
	} else {
		called: bool
		if count, width, called = written_line_shape(spacing, text, placed); called {
			return count, width, true
		}
		count, width, _ = shape_simple(spacing, text, placed, true)
		return count, width, true
	}
}

// shape_written is shape in the written part.
@(private)
shape_written :: proc "contextless" (spacing: ^Spacing, text: []u8, placed: []Placed_Glyph) -> (count: int, width: i64, ok: bool) {
	if len(text) > TEXT_LIMIT {
		return 0, 0, false
	}
	shaper := shaper_of(spacing, text)
	current, next: Shaped
	has_current := shaper_next(&shaper, &current)
	x: i64
	for has_current {
		has_next := shaper_next(&shaper, &next)
		glyph_advance := current.base.advance
		if has_next && !current.syllable && !next.syllable {
			glyph_advance += pair_of(spacing, current.base, next.base)
		}
		// Two syllables of a script of India: the pair of GPOS of the last
		// glyph of the first and the first glyph of the next.
		if has_next {
			if pair := syllable_pair_of(spacing, shaper.set, &current, &next, &shaper.budget); pair != 0 {
				if current.mark_count > 0 {
					current.marks[current.mark_count - 1].advance += pair
				} else {
					glyph_advance += pair
				}
			}
		}
		if count < len(placed) {
			placed[count] = {glyph = current.base.glyph, x = i32(x), advance = glyph_advance, cluster = current.base.cluster}
		}
		count += 1
		base_x := x
		x += i64(glyph_advance)
		for &mark in current.marks[:current.mark_count] {
			// An anchored mark from the origin of its base; a centred mark
			// at its base, which the reader centres on; the replacement
			// glyph of a mark that no font has, in its own place.
			mark_x := x
			switch mark.placement {
			case .Base:
			case .Anchored:
				mark_x = base_x + i64(mark.offset_x)
			case .Centred:
				mark_x = base_x
			}
			if count < len(placed) {
				placed[count] = {glyph = mark.glyph, x = i32(mark_x), y = mark.offset_y, advance = mark.advance, cluster = mark.cluster, placement = mark.placement}
			}
			count += 1
			x += i64(mark.advance)
		}
		current = next
		has_current = has_next
	}
	if count <= len(placed) && spacing.cell_advance == 0 {
		bidi_line_reorder(spacing, text, placed[:count])
	}
	return count, x, true
}

// text_width gives the width of a text in 1/64 of a pixel: the sum of the
// advances that shape gives, with no placed glyph written. ok is false for
// a text of more than TEXT_LIMIT bytes.
text_width :: proc "contextless" (spacing: ^Spacing, text: []u8) -> (width: i64, ok: bool) {
	_, width, ok = shape(spacing, text, nil)
	return
}

// Range_Problem: why measure_ranges stopped.
Range_Problem :: enum u8 {
	None, // Each range was measured.
	Past_The_Text, // A range names bytes after the end of the text.
	Too_Long, // A range has more than TEXT_LIMIT bytes.
}

// measure_ranges writes the width of each range of a table of bytes, in
// one call: a window measures all its labels at once. Each range record is
// read once. It stops at the first range that names bytes past the text,
// or has more than TEXT_LIMIT bytes, and gives its index and its end.
measure_ranges :: proc "contextless" (spacing: ^Spacing, text: []u8, ranges: []Text_Range) -> (problem: Range_Problem, index: int, end: u64) {
	for &range, number in ranges {
		copied := intrinsics.volatile_load(&range)
		end = u64(copied.start) + u64(copied.count)
		if end > u64(len(text)) {
			return .Past_The_Text, number, end
		}
		if copied.count > TEXT_LIMIT {
			return .Too_Long, number, u64(copied.count)
		}
		width, _ := text_width(spacing, text[copied.start:end])
		range.width = width
	}
	return .None, len(ranges), 0
}

// text_fit gives the bytes of the longest start of a text whose width is
// at most room, in 1/64 of a pixel: whole clusters, so a cut never splits
// a character or a letter from its marks. 0 for a room below the first
// advance.
text_fit :: proc "contextless" (spacing: ^Spacing, text: []u8, room: i64) -> (count: int) {
	if len(text) > TEXT_LIMIT {
		return 0
	}
	simple: bool
	if count, simple = text_fit_simple(spacing, text, room, false); simple {
		return count
	}
	when WRITTEN_SHAPING_COMPILED_IN {
		return text_fit_written(spacing, text, room)
	} else {
		called: bool
		if count, called = written_line_fit(spacing, text, room); called {
			return count
		}
		count, _ = text_fit_simple(spacing, text, room, true)
		return count
	}
}

// text_fit_written is text_fit in the written part.
@(private)
text_fit_written :: proc "contextless" (spacing: ^Spacing, text: []u8, room: i64) -> (count: int) {
	if len(text) > TEXT_LIMIT {
		return 0
	}
	shaper := shaper_of(spacing, text)
	current, next: Shaped
	has_current := shaper_next(&shaper, &current)
	x: i64
	for has_current {
		has_next := shaper_next(&shaper, &next)
		cluster_width := i64(current.base.advance)
		for mark in current.marks[:current.mark_count] {
			cluster_width += i64(mark.advance)
		}
		// The pair with the next cluster moves the next glyph, not the end
		// of this one: a start that ends here has no pair after it.
		if x + cluster_width > room {
			return current.start
		}
		x += cluster_width
		if has_next && !current.syllable && !next.syllable {
			x += i64(pair_of(spacing, current.base, next.base))
		}
		if has_next {
			x += i64(syllable_pair_of(spacing, shaper.set, &current, &next, &shaper.budget))
		}
		current = next
		has_current = has_next
	}
	return len(text)
}
// ---- The fast part (src/md/features/text_rendering.md, "Where the written
// shaping lives").

// How the walk of a chain treats a font of the script font set.
@(private)
Script_Font_Rule :: enum u8 {
	Take, // The font gives its glyph: through the library module when it holds the font.
	Stop, // The walk stops there: the fast part does not place the character.
	Skip, // The walk goes past it: the fast part places a text of a set of its caller, one character at a time.
}

// simple_read reads and resolves one character of a text for the fast
// part. simple is false for a character that is not simple, and for one
// whose chain reaches a font of the script font set before a font that has
// it; every_character takes each character, past the fonts of the set.
@(private)
simple_read :: proc "contextless" (spacing: ^Spacing, text: []u8, place: int, every_character: bool) -> (resolved: Resolved, end: int, read, simple: bool) {
	character, length, valid := text_encoding.character_decode(text, place)
	if length == 0 {
		return {}, place, false, true
	}
	if valid && !every_character && !is_simple(character) {
		return {}, place, false, false
	}
	reached: bool
	resolved, reached = resolve_in_chain(spacing, character, valid, every_character ? .Skip : .Stop)
	if reached {
		return {}, place, false, false
	}
	resolved.cluster = u32(place)
	return resolved, place + length, true, true
}

// shape_simple is shape in the fast part: each character is its own
// cluster, with the pair of the character after it. simple is false, and
// placed holds no answer, when the text is not simple; every_character
// places each text so, as a module without the written part places a text
// that the library module does not.
@(private)
shape_simple :: proc "contextless" (spacing: ^Spacing, text: []u8, placed: []Placed_Glyph, every_character: bool) -> (count: int, width: i64, simple: bool) {
	current, place, has_current, current_simple := simple_read(spacing, text, 0, every_character)
	if !current_simple {
		return 0, 0, false
	}
	x: i64
	for has_current {
		next, next_place, has_next, next_simple := simple_read(spacing, text, place, every_character)
		if !next_simple {
			return 0, 0, false
		}
		glyph_advance := current.advance
		if has_next {
			glyph_advance += pair_of(spacing, current, next)
		}
		if count < len(placed) {
			placed[count] = {glyph = current.glyph, x = i32(x), advance = glyph_advance, cluster = current.cluster}
		}
		count += 1
		x += i64(glyph_advance)
		current, place, has_current = next, next_place, has_next
	}
	return count, x, true
}

// text_fit_simple is text_fit in the fast part, as shape_simple is shape.
@(private)
text_fit_simple :: proc "contextless" (spacing: ^Spacing, text: []u8, room: i64, every_character: bool) -> (count: int, simple: bool) {
	current, place, has_current, current_simple := simple_read(spacing, text, 0, every_character)
	if !current_simple {
		return 0, false
	}
	x: i64
	fit := -1
	for has_current {
		next, next_place, has_next, next_simple := simple_read(spacing, text, place, every_character)
		if !next_simple {
			return 0, false
		}
		// The pair with the next character moves the next glyph, not the
		// end of this one: a start that ends here has no pair after it.
		if fit < 0 && x + i64(current.advance) > room {
			fit = int(current.cluster)
			if every_character {
				return fit, true
			}
		}
		x += i64(current.advance)
		if has_next {
			x += i64(pair_of(spacing, current, next))
		}
		current, place, has_current = next, next_place, has_next
	}
	if fit >= 0 {
		return fit, true
	}
	return len(text), true
}

// chain_glyph walks the chain of a face for a character: the first font
// that has it, and its glyph. rule says what a font of the script font set
// does; reached is true when the rule Stop met one first.
@(private)
chain_glyph :: proc "contextless" (set: ^Font_Set, face: Face, character: rune, rule: Script_Font_Rule) -> (font: Outline_Font, glyph_index: int, reached: bool) {
	if face == .None || !set.opened || !character_valid(character) || !font_at(set, face_forms[face].primary).opened {
		return .None, 0, false
	}
	for each in chain_of(face, character) {
		if each == .None {
			break
		}
		opened := font_at(set, each)
		if !opened.opened {
			continue
		}
		if each in SCRIPT_FONTS {
			switch rule {
			case .Stop:
				return .None, 0, true
			case .Skip:
				continue
			case .Take:
			}
			// The library module holds the font, and walks the whole chain
			// with the same fonts: its answer is the answer of this walk.
			if opened.held {
				when !WRITTEN_SHAPING_COMPILED_IN {
					if set == &state.font_set {
						font, glyph_index = held_glyph_find(face, character)
						return font, glyph_index, false
					}
				}
				continue
			}
		}
		if index, problem := vector_font.glyph_of(&opened.file, character); problem == .None {
			return each, index, false
		}
	}
	return .None, 0, false
}
