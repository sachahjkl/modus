package text_rendering

import "modus:contract/font_characters"
import "modus:contract/text_encoding"

// The direction of a line (UAX #9, the Unicode Bidirectional Algorithm;
// src/md/features/written_shaping.md, "The direction of a line"). The
// shaper places the glyphs of a text in the order of the text; this pass
// gives each glyph its place on the screen. The order of the placed glyphs
// stays the order of the text, so a fit and a break still count bytes.
//
// The embeddings, the overrides and the isolates have no strength here:
// a text of the system holds none (src/md/data/text_encoding.md).

// The placed glyphs of a line that the pass reorders: the levels of a
// line live on the stack. A longer text keeps the order of the text: a
// draw record holds 256 bytes.
BIDI_GLYPH_LIMIT :: 1024

// placed_character gives the character at the first byte of a placed
// glyph, and if the placed glyph is a mark: a mark has the advance 0.
@(private)
placed_character :: proc "contextless" (text: []u8, glyph: Placed_Glyph) -> (character: rune, valid, mark: bool) {
	length: int
	character, length, valid = text_encoding.character_decode(text, int(glyph.cluster))
	if length == 0 {
		return 0, false, false
	}
	mark = valid && glyph.advance == 0 && is_mark(character) && glyph.glyph != FALLBACK_GLYPH_FIRST + u32(DOTTED_CIRCLE)
	return character, valid, mark
}

// is_strong_right says if a class counts as right to left for the
// neutrals (N1): R, and the numbers.
@(private)
direction_of :: #force_inline proc "contextless" (class: Bidi_Class) -> Bidi_Class {
	switch class {
	case .R, .AL, .EN, .AN:
		return .R
	case .L:
		return .L
	case .ES, .ET, .CS, .NSM, .BN, .B, .S, .WS, .ON, .LRE, .LRO, .RLE, .RLO, .PDF, .LRI, .RLI, .FSI, .PDI:
		return .ON
	}
	return .ON
}

// bidi_levels gives the embedding level of each glyph of a line (rules P2
// and P3, W1 to W7, N1 and N2, I1 and I2, and L1 for the white space at
// its end), and the level of the paragraph. rtl is false when the line has
// no character of right to left: its levels are then all 0.
bidi_levels :: proc "contextless" (text: []u8, placed: []Placed_Glyph, levels: []u8, marks: []bool) -> (paragraph: u8, rtl: bool) {
	count := min(len(placed), len(levels), len(marks), BIDI_GLYPH_LIMIT)
	classes: [BIDI_GLYPH_LIMIT]Bidi_Class
	for index in 0 ..< count {
		character, valid, mark := placed_character(text, placed[index])
		marks[index] = mark
		class := Bidi_Class.ON
		switch {
		case mark:
			class = .NSM
		case !valid || placed[index].glyph == FALLBACK_GLYPH_FIRST + u32(DOTTED_CIRCLE) && is_mark(character):
			class = .ON
		case:
			class = bidi_class_of(character)
		}
		switch class {
		case .LRE, .LRO, .RLE, .RLO, .PDF, .LRI, .RLI, .FSI, .PDI:
			class = .BN
		case .L, .R, .AL, .EN, .ES, .ET, .AN, .CS, .NSM, .BN, .B, .S, .WS, .ON:
		}
		classes[index] = class
		rtl ||= class == .R || class == .AL || class == .AN
	}
	if !rtl {
		for index in 0 ..< count {
			levels[index] = 0
		}
		return 0, false
	}
	// P2 and P3: the first strong character.
	for index in 0 ..< count {
		if classes[index] == .L {
			break
		}
		if classes[index] == .R || classes[index] == .AL {
			paragraph = 1
			break
		}
	}
	sos := paragraph == 1 ? Bidi_Class.R : Bidi_Class.L
	// W1: a mark takes the class of the character before it.
	for index in 0 ..< count {
		if classes[index] == .NSM {
			classes[index] = index == 0 ? sos : classes[index - 1]
		}
	}
	// W2 and W3: a European number after an Arabic letter is an Arabic
	// number; an Arabic letter is R.
	last_strong := sos
	for index in 0 ..< count {
		switch classes[index] {
		case .L, .R, .AL:
			last_strong = classes[index]
		case .EN:
			if last_strong == .AL {
				classes[index] = .AN
			}
		case .ES, .ET, .AN, .CS, .NSM, .BN, .B, .S, .WS, .ON, .LRE, .LRO, .RLE, .RLO, .PDF, .LRI, .RLI, .FSI, .PDI:
		}
	}
	for index in 0 ..< count {
		if classes[index] == .AL {
			classes[index] = .R
		}
	}
	// W4: one separator between two numbers of one kind.
	for index in 1 ..< max(count - 1, 1) {
		before, after := classes[index - 1], classes[index + 1]
		switch {
		case classes[index] == .ES && before == .EN && after == .EN:
			classes[index] = .EN
		case classes[index] == .CS && before == after && (before == .EN || before == .AN):
			classes[index] = before
		}
	}
	// W5: a run of terminators beside a European number.
	for index := 0; index < count; {
		if classes[index] != .ET {
			index += 1
			continue
		}
		end := index
		for end < count && classes[end] == .ET {
			end += 1
		}
		if index > 0 && classes[index - 1] == .EN || end < count && classes[end] == .EN {
			for each in index ..< end {
				classes[each] = .EN
			}
		}
		index = end
	}
	// W6 and W7.
	last_strong = sos
	for index in 0 ..< count {
		switch classes[index] {
		case .ES, .ET, .CS:
			classes[index] = .ON
		case .L, .R:
			last_strong = classes[index]
		case .EN:
			if last_strong == .L {
				classes[index] = .L
			}
		case .AL, .AN, .NSM, .BN, .B, .S, .WS, .ON, .LRE, .LRO, .RLE, .RLO, .PDF, .LRI, .RLI, .FSI, .PDI:
		}
	}
	// N1 and N2: a run of neutrals takes the direction around it when both
	// sides agree, else the direction of the paragraph.
	for index := 0; index < count; {
		if direction_of(classes[index]) != .ON {
			index += 1
			continue
		}
		end := index
		for end < count && direction_of(classes[end]) == .ON {
			end += 1
		}
		before := index > 0 ? direction_of(classes[index - 1]) : sos
		after := end < count ? direction_of(classes[end]) : sos
		resolved := before == after ? before : sos
		for each in index ..< end {
			classes[each] = resolved
		}
		index = end
	}
	// I1 and I2.
	for index in 0 ..< count {
		level := paragraph
		switch classes[index] {
		case .R:
			level += paragraph % 2 == 0 ? 1 : 0
		case .AN, .EN:
			level += paragraph % 2 == 0 ? 2 : 1
		case .L:
			level += paragraph % 2 == 1 ? 1 : 0
		case .AL, .ES, .ET, .CS, .NSM, .BN, .B, .S, .WS, .ON, .LRE, .LRO, .RLE, .RLO, .PDF, .LRI, .RLI, .FSI, .PDI:
		}
		levels[index] = level
	}
	// L1: the white space at the end of the line takes the level of the
	// paragraph.
	for index := count - 1; index >= 0; index -= 1 {
		character, valid, _ := placed_character(text, placed[index])
		class := valid ? bidi_class_of(character) : Bidi_Class.ON
		if class != .WS && class != .S && class != .BN {
			break
		}
		levels[index] = paragraph
	}
	return paragraph, true
}

// bidi_line_reorder gives the placed glyphs of a line their places on the
// screen (rule L2): each run of a level at least each odd level, from the
// highest, is reversed; a glyph of an odd level with a mirrored form
// (BidiMirroring.txt) draws that form; a mark keeps the place of its base.
bidi_line_reorder :: proc "contextless" (spacing: ^Spacing, text: []u8, placed: []Placed_Glyph) {
	count := len(placed)
	if count == 0 || count > BIDI_GLYPH_LIMIT {
		return
	}
	levels: [BIDI_GLYPH_LIMIT]u8
	marks: [BIDI_GLYPH_LIMIT]bool
	_, rtl := bidi_levels(text, placed, levels[:count], marks[:count])
	if !rtl {
		return
	}
	order: [BIDI_GLYPH_LIMIT]u16
	highest, lowest_odd := u8(0), u8(255)
	for index in 0 ..< count {
		order[index] = u16(index)
		highest = max(highest, levels[index])
		if levels[index] % 2 == 1 {
			lowest_odd = min(lowest_odd, levels[index])
		}
	}
	for level := highest; level >= lowest_odd && level > 0; level -= 1 {
		for start := 0; start < count; {
			if levels[order[start]] < level {
				start += 1
				continue
			}
			end := start
			for end < count && levels[order[end]] >= level {
				end += 1
			}
			for low, high := start, end - 1; low < high; low, high = low + 1, high - 1 {
				order[low], order[high] = order[high], order[low]
			}
			start = end
		}
	}
	// The places, in the order of the screen; a mark has none of its own.
	pen: i64
	for visual in 0 ..< count {
		index := int(order[visual])
		if marks[index] {
			continue
		}
		placed[index].x = i32(pen)
		pen += i64(placed[index].advance)
	}
	base := -1
	set := spacing.fonts != nil ? spacing.fonts : &state.font_set
	for index in 0 ..< count {
		if marks[index] {
			if base >= 0 {
				placed[index].x = placed[base].x
			}
			continue
		}
		base = index
		if levels[index] % 2 == 0 || placed[index].glyph >= DIRECT_GLYPH_FIRST {
			continue
		}
		character, valid, _ := placed_character(text, placed[index])
		mirror := mirror_of(character)
		if !valid || mirror == character {
			continue
		}
		if font, _ := font_glyph_in(set, spacing.face, mirror); font != .None {
			if character_index, in_cache := font_characters.character_index(mirror); in_cache {
				placed[index].glyph = u32(character_index)
			} else {
				placed[index].glyph = FALLBACK_GLYPH_FIRST + u32(mirror)
			}
		}
	}
}
