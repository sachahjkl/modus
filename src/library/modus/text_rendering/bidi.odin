package text_rendering

import "modus:contract/font_characters"
import "modus:contract/text_encoding"

// The direction of a line (UAX #9, the Unicode Bidirectional Algorithm;
// src/md/features/written_shaping.md, "The direction of a line"). The
// shaper places the glyphs of a text in the order of the text; this pass
// gives each glyph its place on the screen. The order of the placed glyphs
// stays the order of the text, so a fit and a break still count bytes.
//
// The isolates (LRI, RLI, FSI, PDI) open and close their levels (X1 to
// X10). The embeddings and the overrides are boundary neutrals: a text of
// the system holds none (src/md/data/text_encoding.md).

// The placed glyphs of a line that the pass reorders: the levels of a
// line live on the stack, which a call of the library module keeps under
// 16 KiB. A longer text keeps the order of the text. A draw record holds
// 256 bytes: at most 512 glyphs, each character a mark on a dotted circle.
BIDI_GLYPH_LIMIT :: 512

// placed_character gives the character at the first byte of a placed
// glyph, and if the placed glyph is a mark: a glyph that the shaper placed
// on a base (Anchored or Centred), the dots that a font made of a letter
// too, whose byte is the byte of the letter.
@(private)
placed_character :: proc "contextless" (text: []u8, glyph: Placed_Glyph) -> (character: rune, valid, mark: bool) {
	length: int
	character, length, valid = text_encoding.character_decode(text, int(glyph.cluster))
	if length == 0 {
		return 0, false, false
	}
	return character, valid, glyph.placement != .Base
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

// The deepest isolate (UAX #9, BD2: max_depth): an isolate past it is a
// neutral of the level around it.
BIDI_DEPTH_LIMIT :: 125

// The isolate characters of a line, which link two level runs into one
// isolating run sequence (BD13).
@(private)
ISOLATE_INITIATOR_VALID :: u8(1) // An LRI, RLI or FSI that opened an isolate.
@(private)
ISOLATE_END_MATCHED :: u8(2) // A PDI that closed one.

// is_isolate_initiator says if a class opens an isolate.
@(private)
is_isolate_initiator :: #force_inline proc "contextless" (class: Bidi_Class) -> bool {
	return class == .LRI || class == .RLI || class == .FSI
}

// matching_isolate_end gives the PDI that closes the isolate that the
// initiator at start opens (BD9), or count when none does.
@(private)
matching_isolate_end :: proc "contextless" (classes: []Bidi_Class, start: int) -> int {
	depth := 0
	for index in start + 1 ..< len(classes) {
		switch {
		case is_isolate_initiator(classes[index]):
			depth += 1
		case classes[index] == .PDI:
			if depth == 0 {
				return index
			}
			depth -= 1
		}
	}
	return len(classes)
}

// first_strong_level gives the level of the first strong character from
// start to end, the text inside an isolate left out (P2, P3): 1 for R or
// AL, 0 for L or none.
@(private)
first_strong_level :: proc "contextless" (classes: []Bidi_Class, start, end: int) -> u8 {
	for index := start; index < end; index += 1 {
		switch {
		case classes[index] == .L:
			return 0
		case classes[index] == .R || classes[index] == .AL:
			return 1
		case is_isolate_initiator(classes[index]):
			index = matching_isolate_end(classes, index)
		}
	}
	return 0
}

// bidi_levels gives the embedding level of each glyph of a line, and the
// level of the paragraph: P2 and P3, the explicit levels of the isolates
// (X1 to X10 for LRI, RLI, FSI and PDI), then W1 to W7, N1 and N2 on each
// isolating run sequence, I1 and I2, and L1 for the white space at the end
// of the line. scratch holds the glyphs of one isolating run sequence at a
// time. rtl is false when the line has no character of right to left and
// no isolate of right to left: its levels are then all 0. The embeddings
// and the overrides (LRE, RLE, LRO, RLO, PDF) are boundary neutrals: a text
// of the system holds none (src/md/data/text_encoding.md).
bidi_levels :: proc "contextless" (text: []u8, placed: []Placed_Glyph, levels: []u8, scratch: []u16) -> (paragraph: u8, rtl: bool) {
	count := min(len(placed), len(levels), len(scratch), BIDI_GLYPH_LIMIT)
	classes: [BIDI_GLYPH_LIMIT]Bidi_Class
	links: [BIDI_GLYPH_LIMIT]u8
	for index in 0 ..< count {
		character, valid, mark := placed_character(text, placed[index])
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
		case .LRE, .LRO, .RLE, .RLO, .PDF:
			class = .BN
		case .L, .R, .AL, .EN, .ES, .ET, .AN, .CS, .NSM, .BN, .B, .S, .WS, .ON, .LRI, .RLI, .FSI, .PDI:
		}
		classes[index] = class
		rtl ||= class == .R || class == .AL || class == .AN || class == .RLI || class == .FSI
	}
	if !rtl {
		for index in 0 ..< count {
			levels[index] = 0
		}
		return 0, false
	}
	line := classes[:count]
	paragraph = first_strong_level(line, 0, count)
	// X1 to X10, the isolates alone: each initiator takes the level around
	// it and opens the next odd or even level; its PDI closes it.
	stack: [BIDI_DEPTH_LIMIT + 2]u8
	depth := 0
	stack[0] = paragraph
	overflow_isolates, valid_isolates := 0, 0
	for index in 0 ..< count {
		current := stack[depth]
		levels[index] = current
		links[index] = 0
		class := classes[index]
		switch {
		case is_isolate_initiator(class):
			right_to_left := class == .RLI || class == .FSI && first_strong_level(line, index + 1, matching_isolate_end(line, index)) == 1
			next := right_to_left ? (current + 1) | 1 : (current + 2) & ~u8(1)
			if int(next) <= BIDI_DEPTH_LIMIT && overflow_isolates == 0 && depth + 1 < len(stack) {
				depth += 1
				stack[depth] = next
				valid_isolates += 1
				links[index] = ISOLATE_INITIATOR_VALID
			} else {
				overflow_isolates += 1
			}
		case class == .PDI:
			if overflow_isolates > 0 {
				overflow_isolates -= 1
			} else if valid_isolates > 0 {
				depth -= 1
				valid_isolates -= 1
				levels[index] = stack[depth]
				links[index] = ISOLATE_END_MATCHED
			}
		}
	}
	// Each isolating run sequence: from a glyph that no glyph of its level
	// comes before, over each isolate to its matched PDI.
	for start in 0 ..< count {
		if links[start] == ISOLATE_END_MATCHED || start > 0 && levels[start - 1] == levels[start] {
			continue
		}
		length := 0
		for index := start; index < count && length < len(scratch); {
			scratch[length] = u16(index)
			length += 1
			if links[index] == ISOLATE_INITIATOR_VALID {
				index = matching_isolate_end(line, index)
				continue
			}
			index += 1
			if index < count && levels[index] != levels[start] {
				break
			}
		}
		sequence_resolve(line, levels[:count], links[:count], scratch[:length], paragraph, text, placed[:count])
	}
	// I1 and I2.
	for index in 0 ..< count {
		level := levels[index]
		switch classes[index] {
		case .R:
			level += level % 2 == 0 ? 1 : 0
		case .AN, .EN:
			level += level % 2 == 0 ? 2 : 1
		case .L:
			level += level % 2 == 1 ? 1 : 0
		case .AL, .ES, .ET, .CS, .NSM, .BN, .B, .S, .WS, .ON, .LRE, .LRO, .RLE, .RLO, .PDF, .LRI, .RLI, .FSI, .PDI:
		}
		levels[index] = level
	}
	// L1: a segment separator and a paragraph separator take the level of
	// the paragraph, and so does the white space, with the isolate
	// characters, before each of them and at the end of the line. A text
	// holds no control character, so the one separator is U+2029
	// (src/md/data/text_encoding.md).
	trailing := true
	for index := count - 1; index >= 0; index -= 1 {
		character, valid, mark := placed_character(text, placed[index])
		class := valid && !mark ? bidi_class_of(character) : Bidi_Class.ON
		switch class {
		case .S, .B:
			levels[index] = paragraph
			trailing = true
		case .WS, .BN, .LRI, .RLI, .FSI, .PDI, .LRE, .LRO, .RLE, .RLO, .PDF:
			if trailing {
				levels[index] = paragraph
			}
		case .L, .R, .AL, .EN, .ES, .ET, .AN, .CS, .NSM, .ON:
			trailing = false
		}
	}
	return paragraph, true
}

// sequence_resolve resolves the weak and the neutral types of one
// isolating run sequence (W1 to W7, N1, N2), in the order of its glyphs:
// the glyphs inside an isolate are not in it, and its initiator and its
// matched PDI are neutrals next to each other.
@(private)
sequence_resolve :: proc "contextless" (classes: []Bidi_Class, levels: []u8, links: []u8, sequence: []u16, paragraph: u8, text: []u8, placed: []Placed_Glyph) {
	if len(sequence) == 0 {
		return
	}
	first, last := int(sequence[0]), int(sequence[len(sequence) - 1])
	level := levels[first]
	// sos and eos: the higher of the level of the sequence and of the level
	// next to it, the paragraph at an edge of the line or after an isolate
	// that no PDI closes.
	before := first > 0 ? levels[first - 1] : paragraph
	after := paragraph
	if last + 1 < len(levels) && links[last] != ISOLATE_INITIATOR_VALID {
		after = levels[last + 1]
	}
	sos := max(level, before) % 2 == 1 ? Bidi_Class.R : Bidi_Class.L
	eos := max(level, after) % 2 == 1 ? Bidi_Class.R : Bidi_Class.L
	// W1: a mark takes the class of the glyph before it; after an isolate
	// initiator or a PDI, it is a neutral.
	previous := sos
	for place in sequence {
		index := int(place)
		if classes[index] == .NSM {
			classes[index] = is_isolate_initiator(previous) || previous == .PDI ? .ON : previous
		}
		previous = classes[index]
	}
	// W2 and W3.
	last_strong := sos
	for place in sequence {
		index := int(place)
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
	for place in sequence {
		if classes[place] == .AL {
			classes[place] = .R
		}
	}
	// W4: one separator between two numbers of one kind.
	for position in 1 ..< max(len(sequence) - 1, 1) {
		index := int(sequence[position])
		before_class, after_class := classes[sequence[position - 1]], classes[sequence[position + 1]]
		switch {
		case classes[index] == .ES && before_class == .EN && after_class == .EN:
			classes[index] = .EN
		case classes[index] == .CS && before_class == after_class && (before_class == .EN || before_class == .AN):
			classes[index] = before_class
		}
	}
	// W5: a run of terminators beside a European number.
	for position := 0; position < len(sequence); {
		if classes[sequence[position]] != .ET {
			position += 1
			continue
		}
		end := position
		for end < len(sequence) && classes[sequence[end]] == .ET {
			end += 1
		}
		if position > 0 && classes[sequence[position - 1]] == .EN || end < len(sequence) && classes[sequence[end]] == .EN {
			for each in position ..< end {
				classes[sequence[each]] = .EN
			}
		}
		position = end
	}
	// W6 and W7.
	last_strong = sos
	for place in sequence {
		index := int(place)
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
	embedding := level % 2 == 1 ? Bidi_Class.R : Bidi_Class.L
	brackets_resolve(classes, sequence, sos, embedding, text, placed)
	// N1 and N2: a run of neutrals, the isolate characters too, takes the
	// direction around it when both sides agree, else the direction of the
	// embedding level.
	for position := 0; position < len(sequence); {
		if direction_of(classes[sequence[position]]) != .ON {
			position += 1
			continue
		}
		end := position
		for end < len(sequence) && direction_of(classes[sequence[end]]) == .ON {
			end += 1
		}
		side_before := position > 0 ? direction_of(classes[sequence[position - 1]]) : sos
		side_after := end < len(sequence) ? direction_of(classes[sequence[end]]) : eos
		resolved := side_before == side_after ? side_before : embedding
		for each in position ..< end {
			classes[sequence[each]] = resolved
		}
		position = end
	}
}

// The openings that the search of the bracket pairs holds (UAX #9, BD16):
// past them, the search stops, and the pairs found so far stay.
BIDI_BRACKET_STACK_LIMIT :: 63

// The records that the deepest path of shape holds on its stack: the
// cluster that shape holds and the one after it, the cluster that
// shaper_next reads, the levels and the order of bidi_line_reorder, the
// classes and the links of bidi_levels, and the openings and the pairs of
// brackets_resolve. A call of the library module text_rendering adds its
// fonts, and asserts the sum against its stack bound: the freestanding
// build runs on no host, so its frames are bounded by these sizes, and the
// host test measures the whole call.
SHAPE_STACK_RECORDS_BYTES :: 2 * size_of(Shaped) + size_of(Cluster) + BIDI_GLYPH_LIMIT * (size_of(u8) + size_of(u16)) + BIDI_GLYPH_LIMIT * (size_of(Bidi_Class) + size_of(u8)) + BIDI_BRACKET_STACK_LIMIT * (size_of(rune) + size_of(u16) + 2 * size_of(u16))

// brackets_resolve applies N0 to one isolating run sequence: each pair of
// brackets (BD16) takes the embedding direction when a strong type inside
// it has that direction; else the other direction, when a strong type
// inside it and the strong type before it both have it; else it stays
// neutral. The numbers count as R. A mark after a bracket that changed
// takes its direction. Each bracket is a neutral whose character
// BidiBrackets.txt pairs; a mark is never a bracket.
@(private)
brackets_resolve :: proc "contextless" (classes: []Bidi_Class, sequence: []u16, sos, embedding: Bidi_Class, text: []u8, placed: []Placed_Glyph) {
	Opening :: struct {
		pair:     rune, // The closing bracket that pairs with it.
		position: u16, // In the sequence.
	}
	openings: [BIDI_BRACKET_STACK_LIMIT]Opening
	pairs: [BIDI_BRACKET_STACK_LIMIT][2]u16
	depth, pair_count := 0, 0
	search: for position in 0 ..< len(sequence) {
		index := int(sequence[position])
		if classes[index] != .ON {
			continue
		}
		character, valid, mark := placed_character(text, placed[index])
		if !valid || mark {
			continue
		}
		pair, opening, found := bracket_of(character)
		if !found {
			continue
		}
		if opening {
			if depth == BIDI_BRACKET_STACK_LIMIT {
				break search
			}
			openings[depth] = {pair == 0x232A ? 0x3009 : pair, u16(position)}
			depth += 1
			continue
		}
		closing := character == 0x232A ? 0x3009 : character
		for back := depth - 1; back >= 0; back -= 1 {
			if openings[back].pair == closing {
				if pair_count < len(pairs) {
					pairs[pair_count] = {openings[back].position, u16(position)}
					pair_count += 1
				}
				depth = back
				break
			}
		}
	}
	// In the order of their openings.
	for index in 1 ..< pair_count {
		for back := index; back > 0 && pairs[back][0] < pairs[back - 1][0]; back -= 1 {
			pairs[back], pairs[back - 1] = pairs[back - 1], pairs[back]
		}
	}
	for pair in pairs[:pair_count] {
		has_embedding, has_opposite := false, false
		for position in int(pair[0]) + 1 ..< int(pair[1]) {
			direction := direction_of(classes[sequence[position]])
			if direction == embedding {
				has_embedding = true
				break
			}
			has_opposite ||= direction != .ON
		}
		resolved := Bidi_Class.ON
		if has_embedding {
			resolved = embedding
		} else if has_opposite {
			before := sos
			for position := int(pair[0]) - 1; position >= 0; position -= 1 {
				if direction := direction_of(classes[sequence[position]]); direction != .ON {
					before = direction
					break
				}
			}
			resolved = before != embedding ? before : embedding
		}
		if resolved == .ON {
			continue
		}
		for side in pair {
			classes[sequence[side]] = resolved
			for position := int(side) + 1; position < len(sequence) && placed[sequence[position]].placement != .Base; position += 1 {
				classes[sequence[position]] = resolved
			}
		}
	}
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
	// One array: the glyphs of a run sequence for bidi_levels, then the
	// order of the screen.
	order: [BIDI_GLYPH_LIMIT]u16
	_, rtl := bidi_levels(text, placed, levels[:count], order[:count])
	if !rtl {
		return
	}
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
	// A mark keeps its place from its base: the x of each mark becomes its
	// offset from the base before it, before the bases move.
	base := -1
	for index in 0 ..< count {
		if !(placed[index].placement != .Base) {
			base = index
		} else if base >= 0 {
			placed[index].x -= placed[base].x
		}
	}
	// The places, in the order of the screen; a mark has none of its own.
	pen: i64
	for visual in 0 ..< count {
		index := int(order[visual])
		if (placed[index].placement != .Base) {
			continue
		}
		placed[index].x = i32(pen)
		pen += i64(placed[index].advance)
	}
	base = -1
	set := spacing.fonts != nil ? spacing.fonts : &state.font_set
	for index in 0 ..< count {
		if (placed[index].placement != .Base) {
			if base >= 0 {
				placed[index].x += placed[base].x
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