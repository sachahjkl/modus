#+build !freestanding
package text_shaping

import "modus:contract/demand_cache"
import "modus:contract/glyph_cache"
import "modus:contract/text_encoding"
import "core:mem"
import "core:testing"
import "modus:support/vector_font"

@(private = "file")
b612_regular := #load("../../../../resources/fonts/b612.ttf")

// test_spacing builds the glyph cache of B612 (three positions at scale 1,
// one at the scales 2 and 3) and gives the spacing of scale 1. The memory
// of the cache stays for the test: the spacing reads it in place.
@(private = "file")
test_spacing :: proc(t: ^testing.T) -> (spacing: Spacing, memory: []u64) {
	font, problem := vector_font.font_open(b612_regular)
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	render := new(vector_font.Render_Memory)
	defer free(render)
	memory = make([]u64, vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT / 8)
	out := ([^]u8)(raw_data(memory))[:vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT]
	positions := [3]int{3, 1, 1}
	size: int
	size, problem = vector_font.glyph_cache_build_proportional(&font, b612_regular, "b612", true, render, out, positions[:])
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	cache, refused := glyph_cache.validate(out[:size])
	testing.expect_value(t, refused.kind, glyph_cache.Problem_Kind.None)
	ok: bool
	spacing, ok = spacing_of(&cache, 1)
	testing.expect(t, ok)
	return spacing, memory
}

// The width of a text is the sum of the advances of its placed glyphs, and
// the x of each glyph is the sum of the advances before it.
@(test)
the_width_is_the_sum_of_the_placed_glyphs :: proc(t: ^testing.T) {
	spacing, memory := test_spacing(t)
	defer delete(memory)
	text := "To Live: AVATAR, Wave 1234 - the quick brown fox jumps over the lazy dog."
	placed: [128]Placed_Glyph
	count, width, ok := shape(&spacing, transmute([]u8)text, placed[:])
	testing.expect(t, ok)
	testing.expect_value(t, count, len(text))
	sum: i64
	for glyph, index in placed[:count] {
		testing.expect_value(t, i64(glyph.x), sum)
		testing.expect_value(t, glyph.cluster, u32(index)) // One byte for each character of ASCII.
		sum += i64(glyph.advance)
	}
	testing.expect_value(t, width, sum)
	measured, measured_ok := text_width(&spacing, transmute([]u8)text)
	testing.expect(t, measured_ok && measured == sum)
}

// The pair adjustment is that of the font file: "To" is -100 units, -43 in
// 1/64 of a pixel at scale 1 (one unit is 1/150 of a pixel); "AV" has no
// pair in B612, so its advance is the advance of "A" alone (555). The rule
// of the sum: the cache rounds the advance and the adjustment each on its
// own, and the shaper adds the two integers: "T" before "o" is 512 - 43 =
// 469. The rounding of the sum of the units (1100 units, 469.33) also
// gives 469 here; for other pairs the two rules differ by 1/64.
@(test)
a_pair_changes_the_advance_by_the_value_of_the_file :: proc(t: ^testing.T) {
	spacing, memory := test_spacing(t)
	defer delete(memory)
	placed: [2]Placed_Glyph
	shape(&spacing, transmute([]u8)string("To"), placed[:])
	testing.expect_value(t, placed[0].advance, spacing.advances['T' - glyph_cache.ASCII_FIRST] - 43)
	testing.expect_value(t, spacing.advances['T' - glyph_cache.ASCII_FIRST], 512) // 1200 units.
	testing.expect_value(t, placed[0].advance, 469)
	testing.expect_value(t, placed[1].x, placed[0].advance)
	shape(&spacing, transmute([]u8)string("AV"), placed[:])
	testing.expect_value(t, placed[0].advance, spacing.advances['A' - glyph_cache.ASCII_FIRST])
	testing.expect_value(t, placed[0].advance, 555) // 1300 units.
	// The last glyph of a text has no pair after it.
	shape(&spacing, transmute([]u8)string("T"), placed[:1])
	testing.expect_value(t, placed[0].advance, 512)
}

// An empty text has no glyph and no width. A control, an invalid sequence
// and a character outside the cache are each one replacement glyph, with
// the advance of "0" and no pair.
@(test)
an_empty_text_and_a_character_outside_the_cache :: proc(t: ^testing.T) {
	spacing, memory := test_spacing(t)
	defer delete(memory)
	count, width, ok := shape(&spacing, nil, nil)
	testing.expect(t, ok && count == 0 && width == 0)
	outside := [3]u8{'\n', 200, 127}
	placed: [4]Placed_Glyph
	count, width, ok = shape(&spacing, outside[:], placed[:])
	testing.expect(t, ok && count == 3)
	zero := spacing.advances['0' - glyph_cache.ASCII_FIRST]
	for glyph, index in placed[:3] {
		testing.expect_value(t, glyph.glyph, REPLACEMENT_GLYPH)
		testing.expect_value(t, glyph.advance, zero)
		testing.expect_value(t, glyph.cluster, u32(index))
	}
	testing.expect_value(t, width, 3 * i64(zero))
	// The first character past the Latin-1 Supplement (Ā, U+0100) is
	// outside the cache: two bytes and one replacement glyph, so the glyph
	// after it starts at byte 3.
	OUTSIDE_THE_CACHE :: rune(glyph_cache.LATIN_LAST + 1)
	_, in_cache := glyph_cache.character_index(OUTSIDE_THE_CACHE)
	testing.expect(t, !in_cache)
	text: [2 + text_encoding.CHARACTER_BYTES_LIMIT]u8
	text[0] = 'T'
	length := text_encoding.character_encode(OUTSIDE_THE_CACHE, text[1:])
	text[1 + length] = 'T'
	count, width, ok = shape(&spacing, text[:2 + length], placed[:])
	testing.expect(t, ok && count == 3)
	testing.expect_value(t, placed[1].glyph, REPLACEMENT_GLYPH)
	testing.expect_value(t, placed[2].glyph, u32('T' - glyph_cache.ASCII_FIRST))
	testing.expect_value(t, placed[2].cluster, u32(1 + length))
	testing.expect_value(t, placed[0].advance, spacing.advances['T' - glyph_cache.ASCII_FIRST]) // No pair with the replacement glyph.
	testing.expect_value(t, width, 2 * i64(spacing.advances['T' - glyph_cache.ASCII_FIRST]) + i64(zero))
	// "é" is in the cache: two bytes and its own glyph, by its character
	// index, and the glyph after it starts at byte 3.
	e_acute, _ := glyph_cache.character_index('é')
	count, _, ok = shape(&spacing, transmute([]u8)string("TéT"), placed[:])
	testing.expect(t, ok && count == 3)
	testing.expect_value(t, placed[1].glyph, u32(e_acute))
	testing.expect_value(t, placed[1].cluster, u32(1))
	testing.expect_value(t, placed[2].cluster, u32(3))
	// "€", an added character, is in the cache: three bytes and the glyph
	// of its character index, after the Latin-1 Supplement.
	count, _, ok = shape(&spacing, transmute([]u8)string("5 €"), placed[:])
	testing.expect(t, ok && count == 3)
	testing.expect_value(t, placed[2].glyph, u32(glyph_cache.ADDED_FIRST_INDEX))
	testing.expect_value(t, placed[2].cluster, u32(2))
	testing.expect_value(t, placed[2].advance, spacing.advances[glyph_cache.ADDED_FIRST_INDEX])
	// A text over the limit writes nothing.
	long := make([]u8, TEXT_LIMIT + 1)
	defer delete(long)
	placed[0] = {}
	_, _, ok = shape(&spacing, long, placed[:])
	testing.expect(t, !ok)
	testing.expect_value(t, placed[0], Placed_Glyph{})
}

// With a demand cache: a character past the glyph cache is the replacement
// glyph, with the advance of "0", and wanted, until the cache holds it at
// the generation of the frame; then it is a glyph of the demand cache with
// its own advance, and no pair. An absent character and an invalid
// sequence are never wanted.
@(test)
a_character_on_demand_is_placed_from_the_next_frame :: proc(t: ^testing.T) {
	spacing, memory := test_spacing(t)
	defer delete(memory)
	file := ([^]u8)(raw_data(memory))[:int((^glyph_cache.Header)(raw_data(memory)).file_size)]
	cache, _ := glyph_cache.validate(file)
	bytes, allocation := mem.alloc_bytes(demand_cache.SIZE, demand_cache.PAGE_SIZE)
	testing.expect(t, allocation == nil)
	defer mem.free_bytes(bytes)
	base := uintptr(raw_data(bytes))
	faces: [demand_cache.Face]demand_cache.Face_Header
	faces[.Interface] = {font_hash = cache.header.font_hash, flags = cache.header.flags}
	writer := demand_cache.writer_open(base, vector_font.RENDERER_VERSION, faces)
	reader, ok := demand_cache.reader_of(base, .Interface, &cache)
	testing.expect(t, ok)
	spacing.demand = &reader
	OMEGA :: rune(0x03A9)
	A_MACRON :: rune(0x0101)
	text := "AΩB\xffā"
	demand_cache.reader_frame_begin(&reader)
	placed: [8]Placed_Glyph
	count, width, shaped := shape(&spacing, transmute([]u8)text, placed[:])
	testing.expect(t, shaped && count == 5)
	zero := spacing.advances['0' - glyph_cache.ASCII_FIRST]
	testing.expect_value(t, placed[1].glyph, REPLACEMENT_GLYPH)
	testing.expect_value(t, placed[1].advance, zero)
	testing.expect_value(t, reader.wanted_count, 2) // Ω and ā; not the invalid byte.
	testing.expect_value(t, reader.wanted[0], OMEGA)
	testing.expect_value(t, reader.wanted[1], A_MACRON)
	// The font service publishes Ω, and ā as absent.
	entry := demand_cache.Entry{state = .Drawn, advances = {700, 1400, 2100}}
	place, _ := demand_cache.place_find(&writer, .Interface, OMEGA)
	demand_cache.publish(&writer, place, .Interface, OMEGA, entry)
	place, _ = demand_cache.place_find(&writer, .Interface, A_MACRON)
	demand_cache.publish(&writer, place, .Interface, A_MACRON, demand_cache.Entry{state = .Absent})
	// The same frame: the same placed glyphs.
	_, again, _ := shape(&spacing, transmute([]u8)text, placed[:])
	testing.expect_value(t, again, width)
	// The next frame.
	demand_cache.reader_frame_begin(&reader)
	count, width, shaped = shape(&spacing, transmute([]u8)text, placed[:])
	testing.expect(t, shaped && count == 5)
	testing.expect_value(t, placed[1].glyph, DEMAND_GLYPH_FIRST + u32(OMEGA))
	testing.expect_value(t, placed[1].advance, i32(700)) // No pair with a glyph on demand.
	testing.expect_value(t, placed[0].advance, spacing.advances['A' - glyph_cache.ASCII_FIRST])
	testing.expect_value(t, placed[2].x, placed[1].x + 700)
	testing.expect_value(t, placed[4].glyph, REPLACEMENT_GLYPH)
	testing.expect_value(t, reader.wanted_count, 0)
	// At scale 3 the advance of scale 3.
	spacing.scale = 3
	shape(&spacing, transmute([]u8)string("Ω"), placed[:1])
	testing.expect_value(t, placed[0].advance, i32(2100))
	// The module has no demand cache: the replacement glyph.
	spacing.demand = nil
	shape(&spacing, transmute([]u8)string("Ω"), placed[:1])
	testing.expect_value(t, placed[0].glyph, REPLACEMENT_GLYPH)
}

// 10 000 texts in one call give the widths of 10 000 calls of one text.
@(test)
ten_thousand_texts_in_one_call :: proc(t: ^testing.T) {
	spacing, memory := test_spacing(t)
	defer delete(memory)
	COUNT :: 10_000
	words := [?]string{"File", "Edit", "View", "To", "AVATAR", "Wave", "Settings", "", "Lily", "0123456789", "Ty", "LT"}
	bytes := make([dynamic]u8)
	defer delete(bytes)
	ranges := make([]Text_Range, COUNT)
	defer delete(ranges)
	for index in 0 ..< COUNT {
		word := words[index % len(words)]
		ranges[index] = {start = u32(len(bytes)), count = u32(len(word) + index % 3)}
		append(&bytes, ..transmute([]u8)word)
		for _ in 0 ..< index % 3 {
			append(&bytes, 'a' + u8(index % 26))
		}
	}
	problem, measured, _ := measure_ranges(&spacing, bytes[:], ranges)
	testing.expect_value(t, problem, Range_Problem.None)
	testing.expect_value(t, measured, COUNT)
	for range in ranges {
		width, _ := text_width(&spacing, bytes[range.start:][:range.count])
		testing.expect_value(t, range.width, width)
	}
	// A range past the text stops the measure at its index.
	ranges[7] = {start = u32(len(bytes)) - 1, count = 2}
	stopped, index, end := measure_ranges(&spacing, bytes[:], ranges)
	testing.expect(t, stopped == .Past_The_Text && index == 7 && end == u64(len(bytes)) + 1)
}
