#+build !freestanding
package fallback_glyphs

import "core:mem"
import "core:sync"
import "core:testing"
import "modus:contract/demand_cache"
import "modus:contract/font_outlines"
import "modus:contract/glyph_cache"
import "modus:support/vector_font"

@(private = "file")
b612_file := #load("../../../../resources/fonts/b612.ttf")
@(private = "file")
b612_bold_file := #load("../../../../resources/fonts/b612_bold.ttf")
@(private = "file")
paper_mono_file := #load("../../../../resources/fonts/paper_mono.ttf")
@(private = "file")
paper_mono_semibold_file := #load("../../../../resources/fonts/paper_mono_semibold.ttf")

// The state and the private cache of the package are one per program, as
// in the system, but the runner runs tests on several threads of one
// process: each test holds this lock from its first line to its end.
@(private = "file")
test_state_lock: sync.Mutex

@(private = "file", deferred_none = test_state_give)
test_state_take :: proc() {
	sync.mutex_lock(&test_state_lock)
}

@(private = "file")
test_state_give :: proc() {
	sync.mutex_unlock(&test_state_lock)
}

// The four font files of the resource of the boot image.
@(private = "file")
repository_fonts :: proc() -> [4]font_outlines.Font_Input {
	return {{"b612", b612_file}, {"b612_bold", b612_bold_file}, {"paper_mono", paper_mono_file}, {"paper_mono_semibold", paper_mono_semibold_file}}
}

// resource_of writes a resource of fonts and validates it. The caller
// frees the words.
@(private = "file")
resource_of :: proc(t: ^testing.T, fonts: []font_outlines.Font_Input) -> (outlines: font_outlines.Outlines, words: []u64) {
	size := font_outlines.resource_size(fonts)
	words = make([]u64, (size + 7) / 8)
	bytes := ([^]u8)(raw_data(words))[:size]
	written, ok := font_outlines.resource_write(fonts, bytes)
	testing.expect(t, ok && written == size)
	problem: font_outlines.Problem
	outlines, problem = font_outlines.validate(bytes)
	testing.expect_value(t, problem.kind, font_outlines.Problem_Kind.None)
	return outlines, words
}

// outlines_open opens a resource of fonts in a state of all zero: the
// state of a program at its start. The caller frees the words.
@(private = "file")
outlines_open :: proc(t: ^testing.T, fonts: []font_outlines.Font_Input, demand_base: uintptr = 0) -> (missing: Outline_Fonts, words: []u64) {
	outlines: font_outlines.Outlines
	outlines, words = resource_of(t, fonts)
	state = {}
	private_cache = {}
	return open(&outlines, demand_base), words
}

// A character that is no character of a text has no font, no advance and
// no glyph in any face: 0, a negative code point, a control character, a
// surrogate, one past the last code point and the largest value of the
// type.
@(test)
a_character_that_is_no_character_of_a_text_has_no_glyph :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	refused := [?]rune{0, -1, 0x1B, 0x7F, 0x9F, 0xD800, 0xDFFF, 0x0011_0000, max(rune)}
	for face in Face {
		for character in refused {
			testing.expectf(t, font_of(face, character) == .None && !has(face, character), "%v: U+%X has no font", face, int(character))
			_, found := advance(face, character, 1)
			testing.expectf(t, !found, "%v: U+%X has no advance", face, int(character))
			_, words_of_glyph, source := glyph(face, character, 1, 0)
			testing.expectf(t, source == .Missing && words_of_glyph == nil, "%v: U+%X has no glyph", face, int(character))
		}
	}
	testing.expect_value(t, counts(), Private_Counts{})
}

// A scale or a position that a face does not have gives no glyph and no
// advance: 0, a negative value, one past the bound, the largest value; a
// second position at scale 2; scale 2 of a face of scale 1 only; the face
// None. Nothing is drawn.
@(test)
a_scale_or_a_position_that_the_face_lacks_has_no_glyph :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	ALPHA :: rune(0x03B1)
	Wrong :: struct {
		face:            Face,
		scale, position: int,
	}
	wrongs := [?]Wrong {
		{.Interface, 0, 0},
		{.Interface, -1, 0},
		{.Interface, glyph_cache.SIZE_LIMIT + 1, 0},
		{.Interface, max(int), 0},
		{.Interface, 1, -1},
		{.Interface, 1, glyph_cache.POSITION_LIMIT},
		{.Interface, 2, 1},
		{.Interface, 1, max(int)},
		{.Interface_Bold, 2, 0},
		{.Cells, 1, 1},
		{.Cells_Bold, 2, 0},
		{.None, 1, 0},
	}
	for wrong in wrongs {
		_, _, source := glyph(wrong.face, ALPHA, wrong.scale, wrong.position)
		testing.expectf(t, source == .Missing, "%v at scale %v, position %v: no glyph", wrong.face, wrong.scale, wrong.position)
		if wrong.position == 0 {
			_, found := advance(wrong.face, ALPHA, wrong.scale)
			testing.expectf(t, !found, "%v at scale %v: no advance", wrong.face, wrong.scale)
		}
	}
	testing.expect_value(t, counts(), Private_Counts{})
}

// Before open, and with outlines that lack a font, a chain skips what it
// does not have: a state of all zero finds no face and no font; outlines
// with B612 alone name the three other fonts as missing, and the
// box-drawing characters, which only Paper Mono has, have no font.
@(test)
a_font_that_the_outlines_lack_is_skipped :: proc(t: ^testing.T) {
	test_state_take()
	state = {}
	private_cache = {}
	testing.expect_value(t, font_of(.Interface, 0x03B1), Outline_Font.None)
	testing.expect_value(t, face_of_cache(nil), Face.None)
	_, _, source := glyph(.Interface, 0x03B1, 1, 0)
	testing.expect_value(t, source, Glyph_Source.Missing)

	only := [1]font_outlines.Font_Input{{"b612", b612_file}}
	missing, words := outlines_open(t, only[:])
	defer delete(words)
	testing.expect_value(t, missing, Outline_Fonts{.B612_Bold, .Paper_Mono, .Paper_Mono_Semibold})
	testing.expect_value(t, font_of(.Interface, 0x2500), Outline_Font.None)
	testing.expect_value(t, font_of(.Cells, 0x03B1), Outline_Font.None) // The cells have no first font.
	testing.expect_value(t, font_of(.Interface, 0x03B1), Outline_Font.B612)
	// A second open changes nothing: the outlines never change.
	all := repository_fonts()
	outlines, more := resource_of(t, all[:])
	defer delete(more)
	testing.expect_value(t, open(&outlines, 0), Outline_Fonts{})
	testing.expect_value(t, font_of(.Interface, 0x2500), Outline_Font.None)
}

// A font whose outline is damaged: the glyph of that character is Missing,
// counted once as refused, and not drawn again at the next frames; the
// other glyphs of the font are drawn. Its advance stays the advance of its
// file, so a text keeps its place.
@(test)
a_damaged_outline_is_missing_and_drawn_once :: proc(t: ^testing.T) {
	test_state_take()
	ALPHA :: rune(0x03B1)
	damaged := make([]u8, len(b612_file))
	defer delete(damaged)
	copy(damaged, b612_file)
	font, problem := vector_font.font_open(damaged)
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	glyph_index: int
	glyph_index, problem = vector_font.glyph_of(&font, ALPHA)
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	data: []u8
	data, problem = vector_font.glyph_data(&font, glyph_index)
	testing.expect(t, problem == .None && len(data) >= 10)
	// The count of contours, the first i16 of the glyph: far more than the
	// memory of the renderer holds.
	data[0], data[1] = 0x7F, 0xFF
	fonts := repository_fonts()
	fonts[0].bytes = damaged
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	for frame in 0 ..< 3 {
		frame_begin()
		_, _, source := glyph(.Interface, ALPHA, 1, 0)
		testing.expectf(t, source == .Missing, "frame %v: the damaged α has no glyph", frame)
	}
	testing.expect_value(t, counts().refused, u64(1))
	_, found := advance(.Interface, ALPHA, 1)
	testing.expect(t, found)
	_, _, source := glyph(.Interface, 0x03B2, 1, 0)
	testing.expect_value(t, source, Glyph_Source.Private_Cache)
}

// A script that no font covers is named: the chains of the interface and
// of the cells draw no Cyrillic letter, and 47 of the 49 Greek letters (no
// font has Π, U+03A0, nor ρ, U+03C1); each box-drawing character comes
// from Paper Mono.
@(test)
a_script_that_no_font_covers_is_named :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	Expected :: struct {
		face:          Face,
		script:        Script,
		drawn, total:  int,
	}
	expected := [?]Expected {
		{.Interface, .Cyrillic, 0, 96},
		{.Cells, .Cyrillic, 0, 96},
		{.Interface_Bold, .Cyrillic, 0, 96},
		{.Interface, .Greek, 47, 49},
		{.Cells, .Greek, 47, 49},
		{.Cells_Bold, .Greek, 47, 49},
		{.Interface, .Box_Drawing, 160, 160},
		{.Cells, .Box_Drawing, 160, 160},
	}
	for each in expected {
		drawn, total := coverage(each.face, each.script)
		testing.expectf(t, drawn == each.drawn && total == each.total, "%v, %v: %v of %v; expected %v of %v", each.face, each.script, drawn, total, each.drawn, each.total)
	}
	for missing in ([?]rune{0x03A0, 0x03C1, 0x0416}) {
		for face in ([?]Face{.Interface, .Cells}) {
			testing.expectf(t, font_of(face, missing) == .None, "%v: U+%04X has no font", face, int(missing))
		}
	}
	testing.expect_value(t, font_of(.Interface, 0x2500), Outline_Font.Paper_Mono)
	testing.expect_value(t, font_of(.Cells, 0x03B1), Outline_Font.B612)
	testing.expect_value(t, font_of(.Cells, 0x03BB), Outline_Font.Paper_Mono)
	testing.expect_value(t, font_of(.Cells_Bold, 0x03B1), Outline_Font.B612)
}

// The runs of blocks: a count of 0, a negative count and a count past the
// words have no run; each run splits by halves and joins its free
// neighbour again, so the words are one run after each give.
@(test)
the_runs_of_blocks_split_and_join :: proc(t: ^testing.T) {
	test_state_take()
	for count in ([?]int{0, -1, WORD_CAPACITY + 1, max(int)}) {
		_, ok := order_of_words(count)
		testing.expectf(t, !ok, "%v words have no run", count)
	}
	Size :: struct {
		count, order: int,
	}
	for size in ([?]Size{{1, 0}, {BLOCK_WORDS, 0}, {BLOCK_WORDS + 1, 1}, {GLYPH_WORDS_LIMIT, 7}, {WORD_CAPACITY, ORDER_COUNT - 1}}) {
		order, ok := order_of_words(size.count)
		testing.expectf(t, ok && order == size.order, "%v words: order %v, expected %v", size.count, order, size.order)
	}
	cache := new(Private_Cache)
	defer free(cache)
	blocks: [BLOCK_COUNT]int
	for &block in blocks {
		taken: bool
		block, taken = run_take(cache, 0)
		testing.expect(t, taken)
	}
	_, taken := run_take(cache, 0)
	testing.expect(t, !taken)
	_, taken = run_take(cache, ORDER_COUNT - 1)
	testing.expect(t, !taken)
	for block in blocks {
		run_give(cache, block, 0)
	}
	testing.expect(t, cache.free_heads[ORDER_COUNT - 1] != 0)
	for order in 0 ..< ORDER_COUNT - 1 {
		testing.expectf(t, cache.free_heads[order] == 0, "order %v: no free run after the joins", order)
	}
	whole: int
	whole, taken = run_take(cache, ORDER_COUNT - 1)
	testing.expect(t, taken && whole == 0)
}

// A full cache evicts the oldest glyph and never refuses one: more glyphs
// than its entries are each drawn; the first glyph leaves first, and a
// glyph used in a newer frame stays. A frame that uses more glyphs than
// the cache holds still draws each one, and counts the evictions of
// glyphs of that frame.
@(test)
a_full_cache_evicts_the_oldest :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	Glyph_Key :: struct {
		face:            Face,
		character:       rune,
		scale, position: int,
	}
	keys := make([dynamic]Glyph_Key)
	defer delete(keys)
	for face in ([?]Face{.Cells, .Cells_Without_Grid_Fit, .Interface}) {
		form := face_forms[face]
		for character in rune(0x2500) ..= 0x259F {
			for scale in 1 ..= form.scale_count {
				for position in 0 ..< form.positions[scale - 1] {
					append(&keys, Glyph_Key{face, character, scale, position})
				}
			}
		}
	}
	testing.expect(t, len(keys) > ENTRY_CAPACITY)
	frame_begin()
	_, _, first_source := glyph(keys[0].face, keys[0].character, keys[0].scale, keys[0].position)
	testing.expect_value(t, first_source, Glyph_Source.Private_Cache)
	frame_begin()
	_, _, second_source := glyph(keys[1].face, keys[1].character, keys[1].scale, keys[1].position)
	testing.expect_value(t, second_source, Glyph_Source.Private_Cache)
	// The first glyph is used again in a newer frame: the second is now
	// the oldest.
	frame_begin()
	_, _, _ = glyph(keys[0].face, keys[0].character, keys[0].scale, keys[0].position)
	testing.expect_value(t, private_cache.oldest, u16(entry_find(&private_cache, key_of(keys[1].face, keys[1].character, keys[1].scale, keys[1].position)) + 1))
	frame_begin()
	for key in keys[2:] {
		_, _, source := glyph(key.face, key.character, key.scale, key.position)
		testing.expectf(t, source == .Private_Cache, "%v U+%04X at scale %v is drawn", key.face, int(key.character), key.scale)
	}
	testing.expect(t, counts().evicted > 0)
	testing.expect(t, counts().evicted_in_use > 0)
	testing.expect_value(t, entry_find(&private_cache, key_of(keys[1].face, keys[1].character, keys[1].scale, keys[1].position)), -1)
	last := keys[len(keys) - 1]
	testing.expect(t, entry_find(&private_cache, key_of(last.face, last.character, last.scale, last.position)) >= 0)
	// The order of use holds each entry of the table once.
	in_order := 0
	next := private_cache.newest
	for next != 0 && in_order <= ENTRY_CAPACITY {
		in_order += 1
		next = private_cache.entries[next - 1].older
	}
	testing.expect(t, in_order <= ENTRY_CAPACITY && in_order > 0)
}

// A change of a setting in the middle of a frame: the grid fit and the
// scale are in the key, so a glyph of the other grid fit or of another
// scale is another entry, and the words of the glyph drawn before stay as
// they were; the first setting again finds its glyph with no new draw.
@(test)
a_change_of_settings_in_the_middle_of_a_frame :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	ALPHA :: rune(0x03B1)
	frame_begin()
	with_fit, with_words, source := glyph(.Cells, ALPHA, 1, 0)
	testing.expect_value(t, source, Glyph_Source.Private_Cache)
	saved: [8 * 16]u32
	count := int(with_fit.row_count) * int(with_fit.width)
	testing.expect(t, count > 0 && count <= len(saved))
	copy(saved[:count], with_words[:count])
	_, _, source = glyph(.Cells_Without_Grid_Fit, ALPHA, 1, 0)
	testing.expect_value(t, source, Glyph_Source.Private_Cache)
	_, _, source = glyph(.Cells, ALPHA, 2, 0)
	testing.expect_value(t, source, Glyph_Source.Private_Cache)
	testing.expect_value(t, counts().drawn, u64(3))
	again, again_words, _ := glyph(.Cells, ALPHA, 1, 0)
	testing.expect_value(t, counts().drawn, u64(3))
	testing.expect(t, again == with_fit && again_words == with_words)
	testing.expect(t, mem.compare(mem.slice_to_bytes(saved[:count]), mem.slice_to_bytes(again_words[:count])) == 0)
}

// A glyph of a fallback font stands in the frame of the first font of its
// face: a Greek letter of B612 in a cell of Paper Mono stays in its cell,
// and its baseline is the baseline of Paper Mono: its last row of ink is
// the last row of a letter of Paper Mono with no descender.
@(test)
a_fallback_glyph_stands_in_the_frame_of_the_first_font :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	for scale in 1 ..= 3 {
		alpha, _, source := glyph(.Cells, 0x03B1, scale, 0) // α of B612, no descender.
		testing.expect_value(t, source, Glyph_Source.Private_Cache)
		testing.expectf(t, alpha.left == 0 && int(alpha.width) == 8 * scale && int(alpha.first_row) + int(alpha.row_count) <= 16 * scale, "scale %v: α stays in its cell", scale)
		lambda, _, _ := glyph(.Cells, 0x03BB, scale, 0) // λ of Paper Mono, no descender.
		alpha_bottom := int(alpha.first_row) + int(alpha.row_count)
		lambda_bottom := int(lambda.first_row) + int(lambda.row_count)
		testing.expectf(t, abs(alpha_bottom - lambda_bottom) <= 1, "scale %v: α ends at row %v, λ at row %v", scale, alpha_bottom, lambda_bottom)
		advance_value, found := advance(.Cells, 0x03B1, scale)
		testing.expectf(t, found && advance_value == i32(8 * scale * glyph_cache.SUBPIXEL), "scale %v: the advance of a cell", scale)
	}
	// A box-drawing character of Paper Mono in the interface: a glyph with
	// ink, with the advance of Paper Mono scaled to the cap height of B612.
	box, _, source := glyph(.Interface, 0x2500, 1, 0)
	testing.expect(t, source == .Private_Cache && box.row_count > 0)
	box_advance, found := advance(.Interface, 0x2500, 1)
	testing.expect(t, found && box_advance > 0 && box_advance <= glyph_cache.ADVANCE_LIMIT)
}

// The first font of a face draws the bytes of the demand cache: the glyph
// that this program draws in its private glyph cache is the glyph that the
// font service draws for the same face, at each scale and position. So a
// picture does not depend on which layer drew a glyph.
@(test)
a_private_glyph_of_the_first_font_is_the_glyph_of_the_demand_cache :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	render := new(vector_font.Render_Memory)
	defer free(render)
	cache_bytes, allocation := mem.alloc_bytes(demand_cache.SIZE, demand_cache.PAGE_SIZE)
	testing.expect(t, allocation == nil)
	defer mem.free_bytes(cache_bytes)
	no_faces: [demand_cache.Face]demand_cache.Face_Header
	writer := demand_cache.writer_open(uintptr(raw_data(cache_bytes)), vector_font.RENDERER_VERSION, no_faces)
	Case :: struct {
		demand:    demand_cache.Face,
		face:      Face,
		file:      []u8,
		character: rune,
	}
	cases := [?]Case{{.Interface, .Interface, b612_file, 0x03A9}, {.Cells, .Cells, paper_mono_file, 0x2554}, {.Cells_Without_Grid_Fit, .Cells_Without_Grid_Fit, paper_mono_file, 0x03BB}, {.Cells_Bold, .Cells_Bold, paper_mono_semibold_file, 0x2588}}
	for each in cases {
		demand_font, problem := vector_font.demand_font_open(each.file, each.demand, render)
		testing.expect_value(t, problem, vector_font.Font_Problem.None)
		entry, result := vector_font.demand_glyph_draw(&demand_font, &writer, each.character, render)
		testing.expect_value(t, result, vector_font.Demand_Result.Drawn)
		form := face_forms[each.face]
		for scale in 1 ..= form.scale_count {
			for position in 0 ..< form.positions[scale - 1] {
				built, _ := demand_cache.glyph_of_entry(each.demand, &entry, scale, position)
				private, private_words, source := glyph(each.face, each.character, scale, position)
				testing.expectf(t, source == .Private_Cache, "%v U+%04X: drawn privately", each.face, int(each.character))
				same_box := private.first_row == built.first_row && private.row_count == built.row_count && private.left == built.left && private.width == built.width
				testing.expectf(t, same_box, "%v U+%04X at scale %v, position %v: the box of the demand cache", each.face, int(each.character), scale, position)
				if !same_box {
					continue
				}
				count := int(built.row_count) * int(built.width)
				differ := 0
				for word in 0 ..< count {
					if private_words[word] != writer.words[int(built.word_offset) + word] {
						differ += 1
					}
				}
				testing.expectf(t, differ == 0, "%v U+%04X at scale %v, position %v: %v words differ", each.face, int(each.character), scale, position, differ)
			}
		}
	}
}

// The face of a glyph cache: a cache of another font file, a cache of the
// form of no face, and a cache of the right file and form, last.
@(test)
the_face_of_a_glyph_cache :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	render := new(vector_font.Render_Memory)
	defer free(render)
	out := make([]u64, vector_font.GLYPH_CACHE_LIMIT / 8)
	defer delete(out)
	file := ([^]u8)(raw_data(out))[:vector_font.GLYPH_CACHE_LIMIT]
	Case :: struct {
		grid_fit:    bool,
		scale_count: int,
		face:        Face,
	}
	cases := [?]Case{{true, 2, .None}, {true, 3, .Cells}, {false, 3, .Cells_Without_Grid_Fit}}
	for each in cases {
		font, problem := vector_font.font_open(paper_mono_file)
		testing.expect_value(t, problem, vector_font.Font_Problem.None)
		size: int
		size, problem = vector_font.glyph_cache_build(&font, paper_mono_file, "paper_mono", each.grid_fit, render, file, each.scale_count)
		testing.expect_value(t, problem, vector_font.Font_Problem.None)
		cache, refused := glyph_cache.validate(file[:size])
		testing.expect_value(t, refused.kind, glyph_cache.Problem_Kind.None)
		testing.expectf(t, face_of_cache(&cache) == each.face, "grid fit %v, %v scales: %v, expected %v", each.grid_fit, each.scale_count, face_of_cache(&cache), each.face)
		if each.face != .None {
			// Another font file: the hash differs.
			header := cache.header^
			header.font_hash[0] ~= 1
			other := cache
			other.header = &header
			testing.expect_value(t, face_of_cache(&other), Face.None)
		}
	}
}
