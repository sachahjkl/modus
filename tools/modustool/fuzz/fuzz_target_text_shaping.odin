package fuzz

import "core:mem"
import "core:slice"
import "modus:contract/glyph_cache"
import "modus:contract/text_encoding"
import "modus:support/text_shaping"

// The fuzz target of the shaping tables of the fonts
// (src/md/infrastructure/fuzzing.md, "The targets, in order of value"): the
// module text_shaping places the characters of a text over the advances
// and the pairs of its caller, in the call region, which another thread
// can change. Each advance and each pair is kept in its limits when it is
// read, and each place stays in the text.
//
// The fallback face is None: a fallback face reads the font files that a
// process opened, a state outside the input, and the module has none.

// The head of an input: the counts of the parts that follow it, in this
// order: the advances (CHARACTER_COUNT of them), the pairs, the text, the
// ranges. A part cut by the end of the input is shorter.
Fuzz_Shaping_Head :: struct {
	pair_count:  u16,
	text_count:  u16,
	range_count: u8,
	reserved:    [3]u8,
}
#assert(size_of(Fuzz_Shaping_Head) == 8)

@(private = "file")
FUZZ_SHAPING_PAIR_LIMIT :: 1024
@(private = "file")
FUZZ_SHAPING_RANGE_LIMIT :: 32
FUZZ_SHAPING_INPUT_LIMIT :: 16 << 10

// A text one byte past the limit of a text, for the refusal: the same for
// each execution.
@(private = "file")
fuzz_shaping_long_text: []u8

fuzz_text_shaping_start :: proc() -> bool {
	fuzz_shaping_long_text = make([]u8, text_shaping.TEXT_LIMIT + 1)
	return fuzz_shaping_long_text != nil
}

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

// The model of the pairs: the adjustment of each pair of glyphs, from the
// first pair of the table that names it. It is filled by one walk of the
// pairs, with no search, so the binary search of the reader must agree.
@(private = "file")
Fuzz_Pair_Model :: [text_shaping.CHARACTER_COUNT][text_shaping.CHARACTER_COUNT]i32

@(private = "file")
fuzz_pair_model_of :: proc(pairs: []glyph_cache.Pair_Entry) -> ^Fuzz_Pair_Model {
	model := new(Fuzz_Pair_Model, context.temp_allocator)
	named := new([text_shaping.CHARACTER_COUNT][text_shaping.CHARACTER_COUNT]bool, context.temp_allocator)
	for pair in pairs {
		if int(pair.left) >= text_shaping.CHARACTER_COUNT || int(pair.right) >= text_shaping.CHARACTER_COUNT || named[pair.left][pair.right] {
			continue
		}
		named[pair.left][pair.right] = true
		model[pair.left][pair.right] = clamp(pair.adjustment, -glyph_cache.ADVANCE_LIMIT, glyph_cache.ADVANCE_LIMIT)
	}
	return model
}

// fuzz_pair_model gives the adjustment of two glyphs: 0 for the
// replacement glyph, which has no pair.
@(private = "file")
fuzz_pair_model :: proc(model: ^Fuzz_Pair_Model, left, right: u32) -> i32 {
	if left >= text_shaping.CHARACTER_COUNT || right >= text_shaping.CHARACTER_COUNT {
		return 0
	}
	return model[left][right]
}

// fuzz_text_shaping_execute: a text gives one placed glyph for each
// character and each invalid sequence, as the text encoding counts them,
// at the place of its first byte; each glyph is a glyph of the cache or
// the replacement glyph; each x is the sum of the advances before it, and
// the width their sum. Over pairs in order, each advance is the advance of
// the model with its pair. A shorter table of placed glyphs gives the same
// answer and writes its first glyphs only. A text past the limit, and a
// range past the text or the limit, are refused and change nothing. The
// tables are read only.
fuzz_text_shaping_execute :: proc(input: []u8) -> Fuzz_Verdict {
	head: Fuzz_Shaping_Head
	copy(mem.ptr_to_bytes(&head), input)
	rest := input[min(len(input), size_of(head)):]
	advances := fuzz_shaping_part(i32, &rest, text_shaping.CHARACTER_COUNT)
	if len(advances) < text_shaping.CHARACTER_COUNT {
		// The spacing of a cache has an advance for each character.
		whole := make([]i32, text_shaping.CHARACTER_COUNT, context.temp_allocator)
		copy(whole, advances)
		advances = whole
	}
	pairs := fuzz_shaping_part(glyph_cache.Pair_Entry, &rest, min(int(head.pair_count), FUZZ_SHAPING_PAIR_LIMIT))
	text_count := min(int(head.text_count), len(rest))
	text := slice.clone(rest[:text_count], context.temp_allocator)
	rest = rest[text_count:]
	ranges := fuzz_shaping_part(text_shaping.Text_Range, &rest, min(int(head.range_count), FUZZ_SHAPING_RANGE_LIMIT))
	advances_before := slice.clone(advances, context.temp_allocator)
	pairs_before := slice.clone(pairs, context.temp_allocator)
	text_before := slice.clone(text, context.temp_allocator)
	spacing := text_shaping.Spacing{advances = advances, pairs = pairs, fallback = .None, scale = 1}
	pair_model := fuzz_pair_model_of(pairs)

	placed := make([]text_shaping.Placed_Glyph, len(text) + 1, context.temp_allocator)
	count, width, ok := text_shaping.shape(&spacing, text, placed)
	if !ok || count != text_encoding.character_count(text) {
		return fuzz_broken(.Two_Readers, "shape gives %d glyphs, %v; the text has %d characters", count, ok, text_encoding.character_count(text))
	}
	sorted := true
	for index in 1 ..< len(pairs) {
		if u32(pairs[index - 1].left) << 8 | u32(pairs[index - 1].right) >= u32(pairs[index].left) << 8 | u32(pairs[index].right) {
			sorted = false
			break
		}
	}
	x: i64
	place := 0
	for item, index in placed[:count] {
		character, length, valid := text_encoding.character_decode(text, place)
		glyph := text_shaping.glyph_of(character)
		if item.cluster != u32(place) || item.glyph != glyph || glyph != text_shaping.REPLACEMENT_GLYPH && glyph >= text_shaping.CHARACTER_COUNT {
			return fuzz_broken(.Contract, "the glyph %d is %d at %d; the text has %d at %d (valid %v)", index, item.glyph, item.cluster, glyph, place, valid)
		}
		if i64(item.x) != x || item.advance < -glyph_cache.ADVANCE_LIMIT || item.advance > 2 * glyph_cache.ADVANCE_LIMIT {
			return fuzz_broken(.Contract, "the glyph %d is at %d, after %d, with the advance %d", index, item.x, x, item.advance)
		}
		if sorted {
			advance_glyph := glyph >= text_shaping.CHARACTER_COUNT ? text_shaping.glyph_of(text_shaping.REPLACEMENT_ADVANCE_CHARACTER) : glyph
			expected := clamp(advances[advance_glyph], 0, glyph_cache.ADVANCE_LIMIT)
			if index + 1 < count {
				expected += fuzz_pair_model(pair_model, glyph, placed[index + 1].glyph)
			}
			if item.advance != expected {
				return fuzz_broken(.Model, "the glyph %d has the advance %d; its advance and its pair give %d", index, item.advance, expected)
			}
		}
		x += i64(item.advance)
		place += length
	}
	if x != width {
		return fuzz_broken(.Contract, "shape gives the width %d; its advances give %d", width, x)
	}
	if text_width, width_ok := text_shaping.text_width(&spacing, text); !width_ok || text_width != width {
		return fuzz_broken(.Two_Readers, "text_width gives %d, %v; shape gives %d", text_width, width_ok, width)
	}
	// A shorter table of placed glyphs.
	shorter := make([]text_shaping.Placed_Glyph, count / 2 + 1, context.temp_allocator)
	sentinel := text_shaping.Placed_Glyph{glyph = 7, x = 7, advance = 7, cluster = 7}
	for &item in shorter {
		item = sentinel
	}
	short_table := shorter[:count / 2]
	short_count, short_width, short_ok := text_shaping.shape(&spacing, text, short_table)
	if !short_ok || short_count != count || short_width != width || !slice.equal(short_table, placed[:len(short_table)]) || shorter[len(shorter) - 1] != sentinel {
		return fuzz_broken(.Contract, "shape with %d places gives %d glyphs, or writes past its table", len(short_table), short_count)
	}
	// A text past the limit.
	untouched := make([]text_shaping.Placed_Glyph, 1, context.temp_allocator)
	untouched[0] = sentinel
	if long_count, long_width, long_ok := text_shaping.shape(&spacing, fuzz_shaping_long_text, untouched); long_ok || long_count != 0 || long_width != 0 || untouched[0] != sentinel {
		return fuzz_broken(.Contract, "shape takes a text of %d bytes", len(fuzz_shaping_long_text))
	}
	if verdict := fuzz_measure_ranges_check(&spacing, text, ranges); verdict.oracle != .None {
		return verdict
	}
	if !slice.equal(advances, advances_before) || !slice.equal(pairs, pairs_before) || !slice.equal(text, text_before) {
		return fuzz_broken(.Contract, "the shaping changed its tables or its text")
	}
	return FUZZ_PASSED
}

// fuzz_measure_ranges_check: each range before the one that stops the
// measure has the width of its text; the range that stops it names bytes
// past the text or more than the limit; it and each range after it keep
// their width.
@(private = "file")
fuzz_measure_ranges_check :: proc(spacing: ^text_shaping.Spacing, text: []u8, ranges: []text_shaping.Text_Range) -> Fuzz_Verdict {
	before := slice.clone(ranges, context.temp_allocator)
	problem, index, end := text_shaping.measure_ranges(spacing, text, ranges)
	if problem > max(text_shaping.Range_Problem) || index < 0 || index > len(ranges) || (problem == .None) != (index == len(ranges)) {
		return fuzz_broken(.Contract, "measure_ranges gives %v at the range %d of %d", problem, index, len(ranges))
	}
	for range, number in ranges[:index] {
		width, _ := text_shaping.text_width(spacing, text[range.start:][:range.count])
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
		if stopped.count <= text_shaping.TEXT_LIMIT || stopped_end > u64(len(text)) || end != u64(stopped.count) {
			return fuzz_broken(.Contract, "measure_ranges stops as too long at a range of %d bytes", stopped.count)
		}
	case .None:
	}
	return FUZZ_PASSED
}

fuzz_text_shaping_seeds :: proc(seeds: ^[dynamic][]u8) {
	advances: [text_shaping.CHARACTER_COUNT]i32
	for &advance, index in advances {
		advance = i32(index * 37 % (glyph_cache.ADVANCE_LIMIT + 2)) - 1
	}
	advances[0] = max(i32)
	advances[1] = min(i32)
	a, _ := glyph_cache.character_index('A')
	v, _ := glyph_cache.character_index('V')
	pairs := [?]glyph_cache.Pair_Entry {
		{left = 0, right = 0, adjustment = min(i32)},
		{left = u8(a), right = u8(v), adjustment = -80},
		{left = u8(v), right = u8(a), adjustment = max(i32)},
	}
	text := "AVA \xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80 \xFF\xC3 AV"
	ranges := [?]text_shaping.Text_Range {
		{start = 0, count = 3},
		{start = 4, count = u32(len(text) - 4)},
		{start = 0, count = 0},
		{start = u32(len(text)), count = 1},
		{start = 0, count = text_shaping.TEXT_LIMIT + 1},
	}
	for unsorted in ([2]bool{false, true}) {
		head := Fuzz_Shaping_Head{pair_count = len(pairs), text_count = u16(len(text)), range_count = len(ranges)}
		seed_pairs := pairs
		if unsorted {
			seed_pairs[0], seed_pairs[2] = seed_pairs[2], seed_pairs[0]
		}
		seed := make([dynamic]u8)
		append(&seed, ..mem.ptr_to_bytes(&head))
		append(&seed, ..slice.to_bytes(advances[:]))
		append(&seed, ..slice.to_bytes(seed_pairs[:]))
		append(&seed, ..transmute([]u8)text)
		append(&seed, ..slice.to_bytes(ranges[:]))
		append(seeds, seed[:])
	}
}

fuzz_text_shaping_regions :: proc(input: []u8, regions: ^[dynamic]Fuzz_Region) {
	if len(input) < size_of(Fuzz_Shaping_Head) {
		return
	}
	append(regions, Fuzz_Region{offset = 0, type = Fuzz_Shaping_Head, count = 1})
	head: Fuzz_Shaping_Head
	mem.copy(&head, raw_data(input), size_of(head))
	pairs_offset := size_of(head) + text_shaping.CHARACTER_COUNT * size_of(i32)
	count := min(int(head.pair_count), FUZZ_SHAPING_PAIR_LIMIT, max(len(input) - pairs_offset, 0) / size_of(glyph_cache.Pair_Entry))
	if count > 0 {
		append(regions, Fuzz_Region{offset = pairs_offset, type = glyph_cache.Pair_Entry, count = count})
	}
}
