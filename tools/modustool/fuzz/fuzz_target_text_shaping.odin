package fuzz

import "core:mem"
import "core:slice"
import "modus:contract/font_outlines"
import "modus:contract/text_encoding"
import "modus:text_rendering"

// The fuzz target of the text shaping (src/md/infrastructure/fuzzing.md,
// "The targets, in order of value"): the package text_rendering places the
// characters of a text in a face at a text size, from the font files of
// the system, as the library module text_rendering does over the bytes of
// its caller. The input chooses the face, the size, the pairs, the text and
// its ranges; the fonts are the four of the boot image, opened once.

// The head of an input: the face, the text size, whether the pairs are
// off, then the counts of the parts that follow it, in this order: the
// text, the ranges. A part cut by the end of the input is shorter. With
// font_from_input, the bytes after the ranges are the font file of B612,
// which the input gives whole: a hostile font through the open of a set of
// fonts and the shaper, as a caller of the library module gives it.
Fuzz_Shaping_Head :: struct {
	face:            u8, // A text_rendering.Face; a word that names no member, or None, measures nothing.
	without_pairs:   u8, // Not 0: the spacing has no pair.
	size:            u16, // The text size in 1/64 of a pixel, any value: a size out of its range is refused.
	text_count:      u16,
	range_count:     u8,
	font_from_input: u8, // Not 0: the rest of the input is the font file of B612.
}
#assert(size_of(Fuzz_Shaping_Head) == 8)

@(private = "file")
FUZZ_SHAPING_RANGE_LIMIT :: 32
// Room for the subset of B612 (55 676 bytes), a text and its ranges.
FUZZ_SHAPING_INPUT_LIMIT :: 96 << 10

@(private = "file")
fuzz_paper_mono := #load("../../../resources/fonts/paper_mono.ttf")
@(private = "file")
fuzz_b612 := #load("../../../resources/fonts/b612.ttf")

// fuzz_shaping_font_from_input: a font file of the input, opened as the
// B612 of a set beside the true Paper Mono, through fonts_open and shape.
// Its numbers are not modelled; each one stays in its bound
// (fuzz_shaping_invariants). A font
// that the open refuses gives no spacing of the face Interface.
@(private = "file")
fuzz_shaping_font_from_input :: proc(face: text_rendering.Face, size: int, without_pairs: bool, text: []u8, font_bytes: []u8) -> Fuzz_Verdict {
	if len(font_bytes) == 0 {
		return FUZZ_PASSED
	}
	fonts := [2]font_outlines.Font_Input{{"b612", font_bytes}, {"paper_mono", fuzz_paper_mono}}
	resource_size := font_outlines.resource_size(fonts[:])
	words := make([]u64, (resource_size + 7) / 8, context.temp_allocator)
	bytes := ([^]u8)(raw_data(words))[:resource_size]
	if _, written := font_outlines.resource_write(fonts[:], bytes); !written {
		return fuzz_broken(.Contract, "the resource of a font of %d bytes is not written", len(font_bytes))
	}
	outlines, problem := font_outlines.validate(bytes)
	if problem.kind != .None {
		return fuzz_broken(.Round_Trip, "the resource that resource_write wrote is refused: %v", problem.kind)
	}
	set := new(text_rendering.Font_Set, context.temp_allocator)
	set.room = new(text_rendering.Font_Room, context.temp_allocator)[:]
	outline_memory := new(text_rendering.Outline_Memory, context.temp_allocator)
	outline := text_rendering.outline_of(outline_memory)
	_ = text_rendering.fonts_open(set, &outlines, &outline)
	spacing, spacing_ok := text_rendering.spacing_in(set, face, size)
	if !spacing_ok {
		return FUZZ_PASSED
	}
	spacing.without_pairs = without_pairs
	placed := make([]text_rendering.Placed_Glyph, FUZZ_GLYPHS_OF_A_CHARACTER * len(text) + 1, context.temp_allocator)
	count, width, ok := text_rendering.shape(&spacing, text, placed)
	if !ok || count > len(placed) {
		return fuzz_broken(.Contract, "shape over a font of the input gives %d glyphs, %v, for %d bytes", count, ok, len(text))
	}
	if verdict := fuzz_shaping_invariants(&spacing, text, placed[:count], width, size); verdict.oracle != .None {
		return verdict
	}
	return FUZZ_PASSED
}

// fuzz_shaping_plain says if a text keeps one placed glyph for each
// character, in the order of the text: no mark (which composes, or stays
// apart with the advance 0, or stands on a dotted circle), no character of
// a right-to-left class (which reorders the line), no letter that joins
// (Arabic and its kin), and no format character that draws nothing (an
// isolate of UAX #9, a joiner). The model of each character holds for such
// a text only.
@(private = "file")
fuzz_shaping_plain :: proc(text: []u8) -> bool {
	for place := 0; place < len(text); {
		character, length, valid := text_encoding.character_decode(text, place)
		place += max(length, 1)
		if !valid {
			continue
		}
		if text_rendering.is_mark(character) || text_rendering.joining_type_of(character) != .None || text_rendering.is_invisible_format(character) {
			return false
		}
		// The scripts of India: the engine of the lookups shapes a
		// syllable into other glyphs than its characters.
		if character >= 0x0900 && character <= 0x0D7F {
			return false
		}
		#partial switch text_rendering.bidi_class_of(character) {
		case .R, .AL, .AN:
			return false
		}
	}
	return true
}

// The most placed glyphs of one character: a letter of Arabic is a body
// and the marks that the font makes of it, and a syllable of Devanagari of
// one character is at most its base and CLUSTER_MARK_LIMIT glyphs after it.
@(private = "file")
FUZZ_GLYPHS_OF_A_CHARACTER :: 1 + text_rendering.CLUSTER_MARK_LIMIT

// fuzz_shaping_invariants: the bounds that each text keeps, plain or not.
// At most FUZZ_GLYPHS_OF_A_CHARACTER placed glyphs for each character; each cluster is the first byte of a character of the
// text; each advance from minus half a line to one line and a half; the
// width the sum of the advances, in an i32, and text_width the same width.
// The places, in any order, are one chain from 0 to the width: the
// multiset of the starts with the width is the multiset of the ends with 0,
// whether the line keeps the order of the text or a reorder of UAX #9
// moved its runs.
@(private = "file")
fuzz_shaping_invariants :: proc(spacing: ^text_rendering.Spacing, text: []u8, placed: []text_rendering.Placed_Glyph, width: i64, size: int) -> Fuzz_Verdict {
	characters := text_encoding.character_count(text)
	if len(placed) > FUZZ_GLYPHS_OF_A_CHARACTER * characters || (characters > 0 && len(placed) == 0) {
		return fuzz_broken(.Contract, "shape gives %d glyphs for %d characters", len(placed), characters)
	}
	starts := make([]bool, len(text) + 1, context.temp_allocator)
	for place := 0; place < len(text); {
		_, length, _ := text_encoding.character_decode(text, place)
		starts[place] = true
		place += max(length, 1)
	}
	lefts := make([]i64, len(placed) + 1, context.temp_allocator)
	rights := make([]i64, len(placed) + 1, context.temp_allocator)
	sum: i64
	for item, index in placed {
		if int(item.cluster) >= len(text) || !starts[item.cluster] {
			return fuzz_broken(.Contract, "the glyph %d names the byte %d, which starts no character of %d bytes", index, item.cluster, len(text))
		}
		if i64(item.advance) < -i64(size) / 2 || i64(item.advance) > i64(size) + i64(size) / 2 {
			return fuzz_broken(.Contract, "the glyph %d at %d has the advance %d, past its bound at the size %d", index, item.cluster, item.advance, size)
		}
		lefts[index], rights[index] = i64(item.x), i64(item.x) + i64(item.advance)
		sum += i64(item.advance)
	}
	if sum != width || width >= 1 << 31 || width <= -(1 << 31) {
		return fuzz_broken(.Contract, "shape gives the width %d; its advances give %d", width, sum)
	}
	lefts[len(placed)], rights[len(placed)] = width, 0
	slice.sort(lefts)
	slice.sort(rights)
	if !slice.equal(lefts, rights) {
		return fuzz_broken(.Contract, "the places of %d glyphs are not one line from 0 to the width %d", len(placed), width)
	}
	if text_width, width_ok := text_rendering.text_width(spacing, text); !width_ok || text_width != width {
		return fuzz_broken(.Two_Readers, "text_width gives %d, %v; shape gives %d", text_width, width_ok, width)
	}
	return FUZZ_PASSED
}

// The fonts of the target, opened at the start and only read after it: the
// executions on several threads share them.
@(private = "file")
fuzz_shaping_fonts: ^text_rendering.Font_Set
@(private = "file")
fuzz_shaping_outlines_words: []u64

// A text one byte past the limit of a text, for the refusal: the same for
// each execution.
@(private = "file")
fuzz_shaping_long_text: []u8

fuzz_text_shaping_start :: proc() -> bool {
	fuzz_shaping_long_text = make([]u8, text_rendering.TEXT_LIMIT + 1)
	fonts := [5]font_outlines.Font_Input {
		{"b612", fuzz_b612},
		{"b612_bold", #load("../../../resources/fonts/b612_bold.ttf")},
		{"paper_mono", fuzz_paper_mono},
		{"paper_mono_semibold", #load("../../../resources/fonts/paper_mono_semibold.ttf")},
		{"noto_sans", #load("../../../resources/fonts/noto_sans.ttf")},
	}
	size := font_outlines.resource_size(fonts[:])
	fuzz_shaping_outlines_words = make([]u64, (size + 7) / 8)
	bytes := ([^]u8)(raw_data(fuzz_shaping_outlines_words))[:size]
	if _, written := font_outlines.resource_write(fonts[:], bytes); !written {
		return false
	}
	outlines, problem := font_outlines.validate(bytes)
	if problem.kind != .None {
		return false
	}
	fuzz_shaping_fonts = new(text_rendering.Font_Set)
	fuzz_shaping_fonts.room = new(text_rendering.Font_Room)[:]
	outline_memory := new(text_rendering.Outline_Memory)
	defer free(outline_memory)
	outline := text_rendering.outline_of(outline_memory)
	missing := text_rendering.fonts_open(fuzz_shaping_fonts, &outlines, &outline)
	// The script fonts of Arabic, Devanagari, Telugu and Malayalam (an
	// explicit reph, a dot reph, pre-base forms), when the shell names them:
	// the forms of Arabic, lam-alef and the engine of the lookups are then
	// inside the target.
	script_inputs := make([dynamic]font_outlines.Font_Input)
	for name in ([4]string{"noto_sans_arabic", "noto_sans_devanagari", "noto_sans_telugu", "noto_sans_malayalam"}) {
		if script_bytes, found := fuzz_script_font_file(name); found {
			append(&script_inputs, font_outlines.Font_Input{name, script_bytes})
		}
	}
	if len(script_inputs) > 0 {
		script_size := font_outlines.resource_size(script_inputs[:])
		fuzz_shaping_script_words = make([]u64, (script_size + 7) / 8)
		script_bytes := ([^]u8)(raw_data(fuzz_shaping_script_words))[:script_size]
		if _, written := font_outlines.resource_write(script_inputs[:], script_bytes); !written {
			return false
		}
		script_outlines, script_problem := font_outlines.validate(script_bytes)
		if script_problem.kind != .None {
			return false
		}
		_ = text_rendering.script_fonts_open_in(fuzz_shaping_fonts, &script_outlines, &outline)
	}
	return fuzz_shaping_long_text != nil && missing == {}
}

// The resource of the script fonts of the target, when the shell names them.
@(private = "file")
fuzz_shaping_script_words: []u64

// fuzz_shaping_part copies the next part of an input into memory of its
// records, aligned.
@(private = "file")
fuzz_shaping_part :: proc($T: typeid, rest: ^[]u8, count: int) -> []T {
	available := min(count, len(rest^) / size_of(T))
	records := make([]T, available, context.temp_allocator)
	copy(slice.to_bytes(records), rest^)
	rest^ = rest^[available * size_of(T):]
	return records
}

// The model of one character: its font, its glyph in that font and its
// advance, from the parts of the package that the shaper composes. A
// character that no font has is the replacement glyph, with the advance of
// "0".
@(private = "file")
Fuzz_Character :: struct {
	font:    text_rendering.Outline_Font,
	index:   int,
	advance: i32,
	glyph:   u32,
}

@(private = "file")
fuzz_character_model :: proc(face: text_rendering.Face, size: int, character: rune, valid: bool) -> (model: Fuzz_Character) {
	if valid {
		model.font, model.index = text_rendering.font_glyph_in(fuzz_shaping_fonts, face, character)
	}
	if model.font == .None {
		zero_font, zero_index := text_rendering.font_glyph_in(fuzz_shaping_fonts, face, text_rendering.REPLACEMENT_ADVANCE_CHARACTER)
		model.advance, _ = text_rendering.glyph_advance_in(fuzz_shaping_fonts, face, zero_font, zero_index, size)
		model.glyph = text_rendering.REPLACEMENT_GLYPH
		return model
	}
	model.advance, _ = text_rendering.glyph_advance_in(fuzz_shaping_fonts, face, model.font, model.index, size)
	model.glyph = text_rendering.glyph_of(character)
	if model.glyph == text_rendering.REPLACEMENT_GLYPH {
		model.glyph = text_rendering.FALLBACK_GLYPH_FIRST + u32(character)
	}
	return model
}

// fuzz_text_shaping_execute: a spacing is refused for a face that is not a
// member or None and for a size out of its range, and given for each other.
// Each text keeps fuzz_shaping_invariants. A plain text (fuzz_shaping_
// plain) gives one placed glyph for each character and each invalid
// sequence, as the text encoding counts them, at the place of its first
// byte; each advance is the advance of its character in the model, from 0
// to one line, with the pair of its font and the next when both come from
// one font, within half a line; each x is the sum of the advances before
// it. A shorter table of placed glyphs
// gives the same answer and writes its first glyphs only. A text past the
// limit, and a range past the text or the limit, are refused and change
// nothing. The text is read only.
fuzz_text_shaping_execute :: proc(input: []u8) -> Fuzz_Verdict {
	head: Fuzz_Shaping_Head
	copy(mem.ptr_to_bytes(&head), input)
	rest := input[min(len(input), size_of(head)):]
	text_count := min(int(head.text_count), len(rest))
	text := slice.clone(rest[:text_count], context.temp_allocator)
	rest = rest[text_count:]
	ranges := fuzz_shaping_part(text_rendering.Text_Range, &rest, min(int(head.range_count), FUZZ_SHAPING_RANGE_LIMIT))
	text_before := slice.clone(text, context.temp_allocator)
	size := int(head.size)

	// The border of the face, as the library module has it: a byte that
	// names no member never becomes a face.
	face, face_ok := text_rendering.face_of_word(i64(head.face))
	if !face_ok {
		return FUZZ_PASSED
	}
	if head.font_from_input != 0 {
		return fuzz_shaping_font_from_input(face, size, head.without_pairs != 0, text, rest)
	}
	spacing, spacing_ok := text_rendering.spacing_in(fuzz_shaping_fonts, face, size)
	if spacing_ok != (text_rendering.size_check(size) == .None) {
		return fuzz_broken(.Contract, "a spacing of the face %v at the size %d is %v", face, size, spacing_ok)
	}
	if !spacing_ok {
		return FUZZ_PASSED
	}
	spacing.without_pairs = head.without_pairs != 0

	placed := make([]text_rendering.Placed_Glyph, FUZZ_GLYPHS_OF_A_CHARACTER * len(text) + 1, context.temp_allocator)
	count, width, ok := text_rendering.shape(&spacing, text, placed)
	if !ok || count > len(placed) {
		return fuzz_broken(.Contract, "shape gives %d glyphs, %v, for %d bytes", count, ok, len(text))
	}
	if verdict := fuzz_shaping_invariants(&spacing, text, placed[:count], width, size); verdict.oracle != .None {
		return verdict
	}
	plain := fuzz_shaping_plain(text)
	if plain && count != text_encoding.character_count(text) {
		return fuzz_broken(.Two_Readers, "shape gives %d glyphs; the plain text has %d characters", count, text_encoding.character_count(text))
	}
	advance_limit := i64(size)
	pair_limit := i64(size) / 2
	x: i64
	place := 0
	for item, index in placed[:count] {
		if !plain {
			break
		}
		character, length, valid := text_encoding.character_decode(text, place)
		model := fuzz_character_model(face, size, character, valid)
		if item.cluster != u32(place) || item.glyph != model.glyph {
			return fuzz_broken(.Model, "the glyph %d is %d at %d; the model has %d at %d (valid %v)", index, item.glyph, item.cluster, model.glyph, place, valid)
		}
		if i64(model.advance) < 0 || i64(model.advance) > advance_limit {
			return fuzz_broken(.Contract, "the character at %d has the advance %d, past one line of %d", place, model.advance, size)
		}
		expected := model.advance
		if index + 1 < count {
			next_character, _, next_valid := text_encoding.character_decode(text, place + length)
			next := fuzz_character_model(face, size, next_character, next_valid)
			if !spacing.without_pairs && model.font != .None && model.font == next.font {
				pair := text_rendering.glyph_pair_in(fuzz_shaping_fonts, face, model.font, model.index, next.index, size)
				if i64(pair) < -pair_limit || i64(pair) > pair_limit {
					return fuzz_broken(.Contract, "the pair at %d is %d, past half a line of %d", place, pair, size)
				}
				expected += pair
			}
		}
		if item.advance != expected {
			return fuzz_broken(.Model, "the glyph %d has the advance %d; its advance and its pair give %d", index, item.advance, expected)
		}
		if i64(item.x) != x {
			return fuzz_broken(.Contract, "the glyph %d is at %d, after %d", index, item.x, x)
		}
		x += i64(item.advance)
		place += length
	}
	// A shorter table of placed glyphs.
	shorter := make([]text_rendering.Placed_Glyph, count / 2 + 1, context.temp_allocator)
	sentinel := text_rendering.Placed_Glyph{glyph = 7, x = 7, advance = 7, cluster = 7}
	for &item in shorter {
		item = sentinel
	}
	short_table := shorter[:count / 2]
	short_count, short_width, short_ok := text_rendering.shape(&spacing, text, short_table)
	// A table too short for the whole answer gets no reorder of UAX #9:
	// its places are those of the order of the text, and a bracket keeps
	// its own glyph where the whole answer may draw its mirror.
	same := true
	for item, index in short_table {
		whole := placed[index]
		glyph_same := item.glyph == whole.glyph
		if !glyph_same && !plain {
			character, _, _ := text_encoding.character_decode(text, int(item.cluster))
			if mirror := text_rendering.mirror_of(character); mirror != 0 {
				mirrored := text_rendering.glyph_of(mirror)
				if mirrored == text_rendering.REPLACEMENT_GLYPH {
					mirrored = text_rendering.FALLBACK_GLYPH_FIRST + u32(mirror)
				}
				glyph_same = whole.glyph == mirrored
			}
		}
		same &&= glyph_same && item.advance == whole.advance && item.cluster == whole.cluster && (!plain || item.x == whole.x)
	}
	if !short_ok || short_count != count || short_width != width || !same || shorter[len(shorter) - 1] != sentinel {
		return fuzz_broken(.Contract, "shape with %d places gives %d glyphs, or writes past its table", len(short_table), short_count)
	}
	// A text past the limit.
	untouched := make([]text_rendering.Placed_Glyph, 1, context.temp_allocator)
	untouched[0] = sentinel
	if long_count, long_width, long_ok := text_rendering.shape(&spacing, fuzz_shaping_long_text, untouched); long_ok || long_count != 0 || long_width != 0 || untouched[0] != sentinel {
		return fuzz_broken(.Contract, "shape takes a text of %d bytes", len(fuzz_shaping_long_text))
	}
	if verdict := fuzz_measure_ranges_check(&spacing, text, ranges); verdict.oracle != .None {
		return verdict
	}
	if !slice.equal(text, text_before) {
		return fuzz_broken(.Contract, "the shaping changed its text")
	}
	return FUZZ_PASSED
}

// fuzz_measure_ranges_check: each range before the one that stops the
// measure has the width of its text; the range that stops it names bytes
// past the text or more than the limit; it and each range after it keep
// their width.
@(private = "file")
fuzz_measure_ranges_check :: proc(spacing: ^text_rendering.Spacing, text: []u8, ranges: []text_rendering.Text_Range) -> Fuzz_Verdict {
	before := slice.clone(ranges, context.temp_allocator)
	problem, index, end := text_rendering.measure_ranges(spacing, text, ranges)
	if problem > max(text_rendering.Range_Problem) || index < 0 || index > len(ranges) || (problem == .None) != (index == len(ranges)) {
		return fuzz_broken(.Contract, "measure_ranges gives %v at the range %d of %d", problem, index, len(ranges))
	}
	for range, number in ranges[:index] {
		width, _ := text_rendering.text_width(spacing, text[range.start:][:range.count])
		if range.width != width || range.start != before[number].start || range.count != before[number].count {
			return fuzz_broken(.Contract, "the range %d has the width %d; its text has %d", number, range.width, width)
		}
	}
	if !slice.equal(ranges[index:], before[index:]) {
		return fuzz_broken(.Contract, "measure_ranges changed a range at or after the one that stopped it")
	}
	if problem == .None {
		return FUZZ_PASSED
	}
	stopped := before[index]
	stopped_end := u64(stopped.start) + u64(stopped.count)
	switch problem {
	case .Past_The_Text:
		if stopped_end <= u64(len(text)) || end != stopped_end {
			return fuzz_broken(.Contract, "measure_ranges stops past the text at a range that ends at %d of %d", stopped_end, len(text))
		}
	case .Too_Long:
		if stopped.count <= text_rendering.TEXT_LIMIT || stopped_end > u64(len(text)) || end != u64(stopped.count) {
			return fuzz_broken(.Contract, "measure_ranges stops as too long at a range of %d bytes", stopped.count)
		}
	case .None:
	}
	return FUZZ_PASSED
}

// The seeds: each face at the sizes of the edges (0, one under the least,
// the least, the size of a line of 16 pixels, the largest, one past it, the
// largest u16), with and without pairs, over a text of pairs, of
// characters past the glyph caches, of characters that no font has, and of
// invalid sequences; and a face that names no member.
fuzz_text_shaping_seeds :: proc(seeds: ^[dynamic][]u8) {
	text := "To AVATAR LT Wave \xC3\xA9\xE2\x82\xAC \xCE\x94t \xE2\x94\x8C\xE2\x94\x80 \xD0\x96 \xF0\x9F\x98\x80 \xFF\xC3 AV e\u0301 q\u0323\u0302 \u0301 \u05D0\u05D1 (12) \u0628\u064A\u062A \u0644\u0627"
	ranges := [?]text_rendering.Text_Range {
		{start = 0, count = 3},
		{start = 4, count = u32(len(text) - 4)},
		{start = 0, count = 0},
		{start = u32(len(text)), count = 1},
		{start = 0, count = text_rendering.TEXT_LIMIT + 1},
	}
	sizes := [?]u16{0, text_rendering.TEXT_SIZE_MINIMUM - 1, text_rendering.TEXT_SIZE_MINIMUM, text_rendering.TEXT_SIZE_OF_SCALE_ONE, text_rendering.TEXT_SIZE_LIMIT, text_rendering.TEXT_SIZE_LIMIT + 1, max(u16)}
	faces := [?]u8{u8(text_rendering.Face.None), u8(text_rendering.Face.Interface), u8(text_rendering.Face.Interface_Bold), u8(text_rendering.Face.Cells), u8(text_rendering.Face.Cells_Bold), u8(max(text_rendering.Face)) + 1}
	for face in faces {
		for size in sizes {
			for without_pairs in ([2]u8{0, 1}) {
				head := Fuzz_Shaping_Head{face = face, without_pairs = without_pairs, size = size, text_count = u16(len(text)), range_count = len(ranges)}
				seed := make([dynamic]u8)
				append(&seed, ..mem.ptr_to_bytes(&head))
				append(&seed, ..transmute([]u8)text)
				append(&seed, ..slice.to_bytes(ranges[:]))
				append(seeds, seed[:])
			}
		}
	}
	// The font from the input: the true B612, at a size of the glyph
	// caches and at the largest size, with and without pairs.
	for size in ([2]u16{text_rendering.TEXT_SIZE_OF_SCALE_ONE, text_rendering.TEXT_SIZE_LIMIT}) {
		for without_pairs in ([2]u8{0, 1}) {
			head := Fuzz_Shaping_Head{face = u8(text_rendering.Face.Interface), without_pairs = without_pairs, size = size, text_count = u16(len(text)), range_count = 0, font_from_input = 1}
			seed := make([dynamic]u8)
			append(&seed, ..mem.ptr_to_bytes(&head))
			append(&seed, ..transmute([]u8)text)
			append(&seed, ..fuzz_b612)
			append(seeds, seed[:])
		}
	}
}

fuzz_text_shaping_regions :: proc(input: []u8, regions: ^[dynamic]Fuzz_Region) {
	if len(input) < size_of(Fuzz_Shaping_Head) {
		return
	}
	append(regions, Fuzz_Region{offset = 0, type = Fuzz_Shaping_Head, count = 1})
	head: Fuzz_Shaping_Head
	mem.copy(&head, raw_data(input), size_of(head))
	ranges_offset := size_of(head) + int(head.text_count)
	count := min(int(head.range_count), FUZZ_SHAPING_RANGE_LIMIT, max(len(input) - ranges_offset, 0) / size_of(text_rendering.Text_Range))
	if count > 0 {
		append(regions, Fuzz_Region{offset = ranges_offset, type = text_rendering.Text_Range, count = count})
	}
}