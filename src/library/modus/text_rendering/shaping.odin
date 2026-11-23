package text_rendering

import "base:intrinsics"
import "modus:contract/font_characters"
import "modus:contract/text_encoding"
import "modus:vector_font"

// Text shaping (docs/FONTS.md, "12.3 The text shaping module"): the characters of a
// text become placed glyphs, with the advance of each character and the
// pair adjustment of each pair of characters that follow each other. The
// text is UTF-8 (src/library/modus/contract/text_encoding). No ligature and no
// other script: one placed glyph for each character, and one for each
// invalid sequence.
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
// The glyph of a character with no character index that the fallback chain
// has is FALLBACK_GLYPH_FIRST plus its code point: past each character
// index, and below REPLACEMENT_GLYPH.
FALLBACK_GLYPH_FIRST :: u32(1) << 24
#assert(FALLBACK_GLYPH_FIRST > CHARACTER_COUNT && u64(FALLBACK_GLYPH_FIRST) + text_encoding.CODE_POINT_LAST < u64(REPLACEMENT_GLYPH))
// The glyph of a form or a ligature that a substitution gave, with no
// character: DIRECT_GLYPH_FIRST, the font in bits 16 to 19, the glyph
// index in bits 0 to 15 (direct_glyph).
DIRECT_GLYPH_FIRST :: u32(1) << 30
#assert(u64(FALLBACK_GLYPH_FIRST) + text_encoding.CODE_POINT_LAST < u64(DIRECT_GLYPH_FIRST) && u64(DIRECT_GLYPH_FIRST) + 1 << 20 < u64(REPLACEMENT_GLYPH))
#assert(int(max(Outline_Font)) < 1 << 4)

// direct_glyph gives the placed glyph of a glyph of a font by its index.
direct_glyph :: #force_inline proc "contextless" (font: Outline_Font, index: int) -> u32 {
	return DIRECT_GLYPH_FIRST | u32(font) << 16 | u32(index) & 0xFFFF
}

// direct_glyph_parts gives the font and the glyph index of a placed glyph
// of DIRECT_GLYPH_FIRST; ok is false for each other glyph, and for a font
// that names no member: a placed glyph from another party is checked.
direct_glyph_parts :: proc "contextless" (glyph: u32) -> (font: Outline_Font, index: int, ok: bool) {
	if glyph < DIRECT_GLYPH_FIRST || glyph >= DIRECT_GLYPH_FIRST + 1 << 20 {
		return .None, 0, false
	}
	number := (glyph >> 16) & 0xF
	if number == 0 || number > u32(max(Outline_Font)) {
		return .None, 0, false
	}
	return Outline_Font(number), int(glyph & 0xFFFF), true
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

// Placed_Glyph: one character of a text, placed. x is from the origin of
// the text; advance includes the pair adjustment with the next character;
// so the x of a glyph is the sum of the advances before it.
Placed_Glyph :: struct {
	glyph:   u32, // The character index of the character (font_characters.character_index); FALLBACK_GLYPH_FIRST plus the code point: a character past them that the fallback chain has; REPLACEMENT_GLYPH: a character that no font of the chain has.
	x:       i32, // In 1/64 of a pixel.
	advance: i32, // In 1/64 of a pixel.
	cluster: u32, // The first byte of the character in the text.
}
#assert(size_of(Placed_Glyph) == 16)

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
	if face == .None || size_check(size) != .None || !set.opened || !set.fonts[face_forms[face].primary].opened {
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
	glyph:   u32, // As Placed_Glyph.glyph.
	font:    Outline_Font, // None: a cell, or the replacement glyph; neither has a pair.
	index:   int, // The glyph index in that font.
	advance: i32, // From 0 to its bound.
	cluster: u32, // The first byte of its character in the text.
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
	if spacing.cell_advance > 0 {
		resolved.glyph = valid ? glyph_of(character) : REPLACEMENT_GLYPH
		resolved.advance = valid ? cell_advance_of(spacing, character) : clamp(spacing.cell_advance, 0, CELL_ADVANCE_LIMIT)
		return resolved
	}
	set := spacing.fonts != nil ? spacing.fonts : &state.font_set
	font: Outline_Font
	index: int
	if valid {
		font, index = font_glyph_in(set, spacing.face, character)
	}
	if font == .None {
		resolved.glyph = REPLACEMENT_GLYPH
		zero_font, zero_index := font_glyph_in(set, spacing.face, REPLACEMENT_ADVANCE_CHARACTER)
		resolved.advance, _ = glyph_advance_in(set, spacing.face, zero_font, zero_index, spacing.size)
		return resolved
	}
	if character_index, in_cache := font_characters.character_index(character); in_cache {
		resolved.glyph = u32(character_index)
	} else {
		resolved.glyph = FALLBACK_GLYPH_FIRST + u32(character)
	}
	resolved.font, resolved.index = font, index
	resolved.advance, _ = glyph_advance_in(set, spacing.face, font, index, spacing.size)
	return resolved
}

// resolve_index is resolve for a glyph of a font by its index: a form or a
// ligature that a substitution gave.
@(private)
resolve_index :: proc "contextless" (spacing: ^Spacing, font: Outline_Font, index: int) -> (resolved: Resolved) {
	set := spacing.fonts != nil ? spacing.fonts : &state.font_set
	resolved = {glyph = direct_glyph(font, index), font = font, index = index}
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
	return glyph_pair_in(set, spacing.face, left.font, left.index, right.index, spacing.size)
}

// ---- The clusters (src/md/features/written_shaping.md).

// Cluster: a base and the marks after it, read from a text, with the
// composition of UAX #15 done: base is the composed character when a font
// has it, and marks are those that stayed apart.
Cluster :: struct {
	base:         rune,
	base_valid:   bool, // false: an invalid sequence, the replacement glyph.
	dotted:       bool, // The marks had no base: base is the dotted circle.
	marks:        [CLUSTER_MARK_LIMIT]rune,
	mark_places:  [CLUSTER_MARK_LIMIT]u32, // The first byte of each mark.
	mark_count:   int,
	start, end:   int, // Its bytes.
}

// is_cluster_break says if a character takes no mark: a space, a separator
// or a control. A mark after it has no base.
@(private)
is_cluster_break :: proc "contextless" (character: rune) -> bool {
	class := bidi_class_of(character)
	return class == .WS || class == .S || class == .B
}

// cluster_read reads the cluster that starts at a byte of a text: a base
// and at most CLUSTER_MARK_LIMIT marks after it, in canonical order, then
// composes them. has says if the fonts of the caller draw a character: a
// composition that no font draws is not made.
cluster_read :: proc "contextless" (set: ^Font_Set, face: Face, text: []u8, place: int) -> (cluster: Cluster, ok: bool) {
	character, length, valid := text_encoding.character_decode(text, place)
	if length == 0 {
		return {}, false
	}
	cluster.start = place
	at := place
	if valid && is_mark(character) {
		cluster.base, cluster.base_valid, cluster.dotted = DOTTED_CIRCLE, true, true
	} else {
		cluster.base, cluster.base_valid = character, valid
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
	// stayed apart before it blocks it (its class is 0 or at least its own).
	kept := 0
	for index in 0 ..< cluster.mark_count {
		mark := cluster.marks[index]
		class := combining_class_of(mark)
		blocked := kept > 0 && (combining_class_of(cluster.marks[kept - 1]) == 0 || combining_class_of(cluster.marks[kept - 1]) >= class)
		if !blocked {
			if composed, found := compose(cluster.base, mark); found && character_drawn(set, face, composed) {
				cluster.base = composed
				continue
			}
		}
		cluster.marks[kept] = mark
		cluster.mark_places[kept] = cluster.mark_places[index]
		kept += 1
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
}

@(private)
shaper_of :: proc "contextless" (spacing: ^Spacing, text: []u8) -> Shaper {
	return {spacing = spacing, set = spacing.fonts != nil ? spacing.fonts : &state.font_set, text = text}
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

// form_of gives the glyph of the form of a letter in its font, or the
// glyph of the character when the font has no such form.
@(private)
form_of :: proc "contextless" (set: ^Font_Set, font: Outline_Font, index: int, before, after: bool) -> int {
	substitute, problem := vector_font.script_single_substitution(&set.fonts[font].file, ARAB, form_feature(before, after), index)
	if problem != .None {
		return index
	}
	return substitute
}

// shaper_next shapes the next cluster of the text; false at its end.
@(private)
shaper_next :: proc "contextless" (shaper: ^Shaper, shaped: ^Shaped) -> bool {
	cluster := cluster_read(shaper.set, shaper.spacing.face, shaper.text, shaper.place) or_return
	shaped^ = {start = cluster.start, end = cluster.end}
	spacing := shaper.spacing
	shaped.base = resolve(spacing, cluster.base, cluster.base_valid)
	shaped.base.cluster = u32(cluster.start)
	type := cluster.base_valid && !cluster.dotted ? joining_type_of(cluster.base) : .None
	ligature_cluster: Cluster
	ligature_made := false
	if type != .None && spacing.cell_advance == 0 && shaped.base.font != .None {
		next, next_length, next_valid := text_encoding.character_decode(shaper.text, cluster.end)
		next_type := next_length > 0 && next_valid ? joining_type_of(next) : .None
		before := joins_after(shaper.previous) && joins_before(type)
		after := joins_after(type) && joins_before(next_type)
		base_cluster := shaped.base.cluster
		// Lam and an alef after it: one glyph, the ligature of the
		// presentation forms, final when the lam joins the letter before.
		if cluster.base == LAM && next_length > 0 && next_valid && is_alef(next) {
			ligature := lam_alef_of(next, before)
			if ligature != 0 && character_drawn(shaper.set, spacing.face, ligature) {
				if after_cluster, read := cluster_read(shaper.set, spacing.face, shaper.text, cluster.end); read {
					ligature_cluster = after_cluster
					ligature_made = true
					shaped.base = resolve(spacing, ligature, true)
					shaped.base.cluster = base_cluster
					type = .Right // The ligature ends with the alef, which joins nothing after it.
				}
			}
		}
		if !ligature_made {
			// The presentation form that Unicode names, when the font has
			// it; else the form of the GSUB of the font.
			if form := arabic_form_of(cluster.base, before, after); form != 0 && character_drawn(shaper.set, spacing.face, form) {
				shaped.base = resolve(spacing, form, true)
			} else if font := shaped.base.font; shaper.set.fonts[font].file.gsub.length > 0 {
				if substitute := form_of(shaper.set, font, shaped.base.index, before, after); substitute != shaped.base.index {
					shaped.base = resolve_index(spacing, font, substitute)
				}
			}
			shaped.base.cluster = base_cluster
		}
	}
	shaper.previous = type
	shaper.place = cluster.end
	marks_add(spacing, shaper.set, shaped, &cluster)
	if ligature_made {
		shaped.end = ligature_cluster.end
		shaper.place = ligature_cluster.end
		marks_add(spacing, shaper.set, shaped, &ligature_cluster)
	}
	return true
}

// marks_add resolves the marks of a cluster that stayed apart: each with
// the advance 0, or the replacement glyph and its advance when no font has
// it, so that a reader sees it.
@(private)
marks_add :: proc "contextless" (spacing: ^Spacing, set: ^Font_Set, shaped: ^Shaped, cluster: ^Cluster) {
	for index in 0 ..< cluster.mark_count {
		if shaped.mark_count >= CLUSTER_MARK_LIMIT {
			return
		}
		mark := resolve(spacing, cluster.marks[index], true)
		if mark.glyph != REPLACEMENT_GLYPH || spacing.cell_advance > 0 {
			mark.advance = 0
		}
		mark.cluster = cluster.mark_places[index]
		shaped.marks[shaped.mark_count] = mark
		shaped.mark_count += 1
	}
}

// shape places the characters of a text: it writes the placed glyphs that
// fit from the start of placed, and gives the count of the full answer
// (one for each cluster of a base and its composed marks, one for each mark
// that stayed apart, one for each invalid sequence) and the width of the
// text, the sum of the advances. ok is false for a text of more than
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
	shaper := shaper_of(spacing, text)
	current, next: Shaped
	has_current := shaper_next(&shaper, &current)
	x: i64
	for has_current {
		has_next := shaper_next(&shaper, &next)
		glyph_advance := current.base.advance
		if has_next {
			glyph_advance += pair_of(spacing, current.base, next.base)
		}
		if count < len(placed) {
			placed[count] = {glyph = current.base.glyph, x = i32(x), advance = glyph_advance, cluster = current.base.cluster}
		}
		count += 1
		x += i64(glyph_advance)
		for &mark in current.marks[:current.mark_count] {
			if count < len(placed) {
				placed[count] = {glyph = mark.glyph, x = i32(x), advance = mark.advance, cluster = mark.cluster}
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
		if has_next {
			x += i64(pair_of(spacing, current.base, next.base))
		}
		current = next
		has_current = has_next
	}
	return len(text)
}