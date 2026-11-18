#+build !freestanding
package text_rendering

import "core:fmt"
import "core:mem"
import "core:sync"
import "core:testing"
import "core:time"
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

// The state, the render memory and the private cache of the package are
// one per process, as in the system, but the runner runs tests on several
// threads of one process: each test holds this lock from its first line to
// its end. The tests of shaping_test.odin take it too.
test_state_lock: sync.Mutex

@(deferred_none = test_state_give)
test_state_take :: proc() {
	sync.mutex_lock(&test_state_lock)
}

test_state_give :: proc() {
	sync.mutex_unlock(&test_state_lock)
}

// The four font files of the resource of the boot image.
repository_fonts :: proc() -> [4]font_outlines.Font_Input {
	return {{"b612", b612_file}, {"b612_bold", b612_bold_file}, {"paper_mono", paper_mono_file}, {"paper_mono_semibold", paper_mono_semibold_file}}
}

// resource_of writes a resource of fonts and validates it. The caller
// frees the words.
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
// state of a process at its start. The caller frees the words.
outlines_open :: proc(t: ^testing.T, fonts: []font_outlines.Font_Input, demand_base: uintptr = 0) -> (missing: Outline_Fonts, words: []u64) {
	outlines: font_outlines.Outlines
	outlines, words = resource_of(t, fonts)
	state = {}
	memory_reset_for_test()
	return open(&outlines, demand_base), words
}

// The glyph memory of the tests: one for the package, as in a process,
// all zero at each open, and given as a process gives it at its first
// glyph past the glyph caches.
test_glyph_memory: ^Glyph_Memory

// memory_reset_for_test empties the cache and gives the package its glyph
// memory again, all zero.
memory_reset_for_test :: proc() {
	if test_glyph_memory == nil {
		test_glyph_memory = new(Glyph_Memory)
	}
	mem.zero(test_glyph_memory, size_of(Glyph_Memory))
	cache_state = {}
	memory_give(test_glyph_memory)
}

// test_cache gives the private glyph cache of the glyph memory of the tests.
test_cache :: proc() -> ^Private_Cache {
	return &cache_state.memory.cache
}

// test_words gives the words of the raster memory of the tests.
test_words :: proc() -> []u32 {
	return cache_state.memory.raster.words[:]
}

// The sizes at the edges of their range: 0, 1, one below the smallest
// size, one past the largest, the largest value of the type and a negative
// size are refused, and give no advance and no glyph; nothing is drawn.
// The smallest and the largest size are accepted, last.
@(test)
a_size_out_of_its_range_is_refused :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	Refused :: struct {
		size:    int,
		problem: Size_Problem,
	}
	refused := [?]Refused {
		{0, .Zero},
		{1, .Too_Small},
		{TEXT_SIZE_MINIMUM - 1, .Too_Small},
		{-1, .Too_Small},
		{min(int), .Too_Small},
		{TEXT_SIZE_LIMIT + 1, .Too_Large},
		{max(int), .Too_Large},
	}
	ALPHA :: rune(0x03B1)
	for each in refused {
		testing.expectf(t, size_check(each.size) == each.problem, "size %v: %v, expected %v", each.size, size_check(each.size), each.problem)
		for face in Face {
			_, found := advance(face, ALPHA, each.size)
			testing.expectf(t, !found, "%v at size %v: no advance", face, each.size)
			_, glyph_words, source := glyph(face, ALPHA, each.size, 0)
			testing.expectf(t, source == .Missing && glyph_words == nil, "%v at size %v: no glyph", face, each.size)
			_, started := glyph_bands(face, ALPHA, each.size, 0)
			testing.expectf(t, !started, "%v at size %v: no bands", face, each.size)
		}
	}
	testing.expect_value(t, counts(), Private_Counts{})
	for size in ([?]int{TEXT_SIZE_MINIMUM, TEXT_SIZE_LIMIT}) {
		testing.expect_value(t, size_check(size), Size_Problem.None)
		_, found := advance(.Cells, ALPHA, size)
		testing.expectf(t, found, "size %v: an advance", size)
	}
}

// A position that a face does not have gives no glyph: a negative
// position, one past the bound, the largest value; a second position for
// a face of cells; the face None. Nothing is drawn.
@(test)
a_position_that_the_face_lacks_has_no_glyph :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	ALPHA :: rune(0x03B1)
	Wrong :: struct {
		face:     Face,
		position: int,
	}
	wrongs := [?]Wrong{{.Interface, -1}, {.Interface, POSITION_LIMIT}, {.Interface, max(int)}, {.Interface_Bold, POSITION_LIMIT}, {.Cells, 1}, {.Cells_Bold, POSITION_LIMIT - 1}, {.None, 0}}
	for wrong in wrongs {
		_, _, source := glyph(wrong.face, ALPHA, TEXT_SIZE_OF_SCALE_ONE, wrong.position)
		testing.expectf(t, source == .Missing, "%v at position %v: no glyph", wrong.face, wrong.position)
	}
	testing.expect_value(t, counts(), Private_Counts{})
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
			_, found := advance(face, character, TEXT_SIZE_OF_SCALE_ONE)
			testing.expectf(t, !found, "%v: U+%X has no advance", face, int(character))
			_, words_of_glyph, source := glyph(face, character, TEXT_SIZE_OF_SCALE_ONE, 0)
			testing.expectf(t, source == .Missing && words_of_glyph == nil, "%v: U+%X has no glyph", face, int(character))
		}
	}
	testing.expect_value(t, counts(), Private_Counts{})
}

// A glyph index past the font, the index 0 below it, a negative index and
// the largest value of the type: the renderer refuses each one, and the
// render memory is not read past its outline.
@(test)
a_glyph_index_past_the_font_is_refused :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	for font in ([?]Outline_Font{.B612, .Paper_Mono}) {
		count := state.fonts[font].file.glyph_count
		face := font == .B612 ? Face.Interface : Face.Cells
		for index in ([?]int{count, count + 1, -1, max(int)}) {
			_, problem := glyph_raster(face, font, index, TEXT_SIZE_OF_SCALE_ONE, 0)
			testing.expectf(t, problem == .Refused, "%v glyph %v: %v, expected Refused", font, index, problem)
		}
		// The last glyph of the font is a glyph.
		_, problem := glyph_raster(face, font, count - 1, TEXT_SIZE_OF_SCALE_ONE, 0)
		testing.expectf(t, problem != .Refused, "%v glyph %v: drawn", font, count - 1)
	}
}

// A damaged outline table: the count of contours of a glyph far past the
// memory of the renderer, and a table loca whose last offset passes the
// table glyf. The glyph of each is Missing, counted once as refused, and
// not drawn again at the next frames; the other glyphs of the font are
// drawn. Its advance stays the advance of its file, so a text keeps its
// place.
@(test)
a_damaged_outline_table_is_refused_once :: proc(t: ^testing.T) {
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
	data[0], data[1] = 0x7F, 0xFF
	fonts := repository_fonts()
	fonts[0].bytes = damaged
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	for frame in 0 ..< 3 {
		frame_begin()
		for size in ([?]int{TEXT_SIZE_OF_SCALE_ONE, 1280, 3 * TEXT_SIZE_OF_SCALE_ONE}) {
			_, _, source := glyph(.Interface, ALPHA, size, 0)
			testing.expectf(t, source == .Missing, "frame %v, size %v: the damaged α has no glyph", frame, size)
		}
	}
	testing.expect_value(t, counts().refused, u64(3))
	_, found := advance(.Interface, ALPHA, TEXT_SIZE_OF_SCALE_ONE)
	testing.expect(t, found)
	_, _, source := glyph(.Interface, 0x03B2, TEXT_SIZE_OF_SCALE_ONE, 0)
	testing.expect_value(t, source, Glyph_Source.Private_Cache)

	// The table loca of Paper Mono puts the start of the glyph of ─ after
	// its end: the read of the outline stops, and the glyph is refused.
	cut := make([]u8, len(paper_mono_file))
	defer delete(cut)
	copy(cut, paper_mono_file)
	mono, mono_problem := vector_font.font_open(cut)
	testing.expect_value(t, mono_problem, vector_font.Font_Problem.None)
	box_index, _ := vector_font.glyph_of(&mono, 0x2500)
	loca := cut[mono.loca.offset:][:mono.loca.length]
	if mono.long_offsets {
		place := 4 * box_index
		loca[place], loca[place + 1], loca[place + 2], loca[place + 3] = 0x7F, 0xFF, 0xFF, 0xFF
	} else {
		place := 2 * box_index
		loca[place], loca[place + 1] = 0xFF, 0xFF
	}
	_, damaged_problem := vector_font.glyph_data(&mono, box_index)
	testing.expect_value(t, damaged_problem, vector_font.Font_Problem.Too_Short)
	fonts = repository_fonts()
	fonts[2].bytes = cut
	_, cut_words := outlines_open(t, fonts[:])
	defer delete(cut_words)
	frame_begin()
	_, _, cut_source := glyph(.Cells, 0x2500, TEXT_SIZE_OF_SCALE_ONE, 0)
	testing.expect_value(t, cut_source, Glyph_Source.Missing)
	testing.expect_value(t, counts().refused, u64(1))
	testing.expect_value(t, counts().drawn, u64(0))
}

// Before open, and with outlines that lack a font, a chain skips what it
// does not have: a state of all zero finds no face and no font; outlines
// with B612 alone name the three other fonts as missing, and the
// box-drawing characters, which only Paper Mono has, have no font.
@(test)
a_font_that_the_outlines_lack_is_skipped :: proc(t: ^testing.T) {
	test_state_take()
	state = {}
	memory_reset_for_test()
	testing.expect_value(t, font_of(.Interface, 0x03B1), Outline_Font.None)
	testing.expect_value(t, face_of_cache(nil), Face.None)
	_, _, source := glyph(.Interface, 0x03B1, TEXT_SIZE_OF_SCALE_ONE, 0)
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
		face:         Face,
		script:       Script,
		drawn, total: int,
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
	testing.expect_value(t, font_of(.Interface, 0x2500), Outline_Font.Paper_Mono)
	testing.expect_value(t, font_of(.Cells, 0x03B1), Outline_Font.B612)
	testing.expect_value(t, font_of(.Cells, 0x03BB), Outline_Font.Paper_Mono)
	testing.expect_value(t, font_of(.Cells_Bold, 0x03B1), Outline_Font.B612)
}

// The runs of blocks: a count of 0, a negative count, a count one past the
// largest block and the largest value have no run; each run splits by
// halves and joins its free neighbour again, up to the largest block, so
// the words are runs of the largest block after each give.
@(test)
the_runs_of_blocks_split_and_join :: proc(t: ^testing.T) {
	test_state_take()
	for count in ([?]int{0, -1, GLYPH_WORDS_LIMIT + 1, max(int)}) {
		_, ok := order_of_words(count)
		testing.expectf(t, !ok, "%v words have no run", count)
	}
	Size :: struct {
		count, order: int,
	}
	for size in ([?]Size{{1, 0}, {BLOCK_WORDS, 0}, {BLOCK_WORDS + 1, 1}, {GLYPH_WORDS_LIMIT, ORDER_COUNT - 1}}) {
		order, ok := order_of_words(size.count)
		testing.expectf(t, ok && order == size.order, "%v words: order %v, expected %v", size.count, order, size.order)
	}
	cache := new(Private_Cache)
	defer free(cache)
	blocks := make([]int, BLOCK_COUNT)
	defer delete(blocks)
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
	largest := 0
	for next := cache.free_heads[ORDER_COUNT - 1]; next != 0 && largest <= LARGEST_RUN_COUNT; next = cache.free_next[next - 1] {
		largest += 1
	}
	testing.expect_value(t, largest, LARGEST_RUN_COUNT)
	for order in 0 ..< ORDER_COUNT - 1 {
		testing.expectf(t, cache.free_heads[order] == 0, "order %v: no free run after the joins", order)
	}
	first: int
	first, taken = run_take(cache, ORDER_COUNT - 1)
	testing.expect(t, taken && first % (1 << uint(ORDER_COUNT - 1)) == 0)
}

// The cache at its bound of entries: in one frame, ENTRY_CAPACITY glyphs
// are kept, and the glyph one past the bound is drawn and not kept: its
// words are right, it has no entry, the entries that were there stay, and
// the report of the glyphs not kept comes once. In the next frame the same
// glyph is kept: it evicts the oldest glyph, of an older frame.
@(test)
the_cache_at_its_bound_of_entries :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	// Distinct keys of small glyphs, so that the entries fill before the
	// words: the full stop of the interface at each third of a pixel, and
	// of its bold weight, at the sizes of a line of 4 to 20 pixels. Each
	// takes one block.
	STOP :: '.'
	SIZE_COUNT :: ENTRY_CAPACITY / (POSITION_LIMIT + 1)
	#assert(SIZE_COUNT * (POSITION_LIMIT + 1) == ENTRY_CAPACITY)
	frame_begin()
	for index in 0 ..< SIZE_COUNT {
		size := TEXT_SIZE_MINIMUM + index
		for position in 0 ..< POSITION_LIMIT {
			_, _, source := glyph(.Interface, STOP, size, position)
			testing.expectf(t, source == .Private_Cache, "size %v, position %v: kept", size, position)
		}
		_, _, source := glyph(.Interface_Bold, STOP, size, 0)
		testing.expectf(t, source == .Private_Cache, "bold at size %v: kept", size)
	}
	testing.expect_value(t, counts().drawn, u64(ENTRY_CAPACITY))
	testing.expect_value(t, counts().evicted, u64(0))
	_, told := not_kept_report()
	testing.expect(t, !told)
	past_size := TEXT_SIZE_MINIMUM + SIZE_COUNT
	before := new([ENTRY_CAPACITY]Private_Entry)
	defer free(before)
	cache := test_cache()
	before^ = cache.entries
	past, _, past_source := glyph(.Interface, STOP, past_size, 0)
	testing.expect_value(t, past_source, Glyph_Source.Not_Kept)
	testing.expect_value(t, counts().not_kept, u64(1))
	testing.expect_value(t, counts().evicted, u64(0))
	testing.expect_value(t, entry_find(test_cache(), key_of(.Interface, .B612, glyph_index_of(.B612, STOP), past_size, 0)), -1)
	testing.expect(t, mem.compare(mem.ptr_to_bytes(before), mem.ptr_to_bytes(&cache.entries)) == 0)
	// Its box is the box of the glyph drawn whole.
	box, problem := glyph_raster(.Interface, .B612, glyph_index_of(.B612, STOP), past_size, 0)
	testing.expect_value(t, problem, Raster_Problem.None)
	testing.expect(t, int(past.row_count) == box.row_count && int(past.width) == box.width && int(past.first_row) == box.first_row && int(past.left) == box.left)
	count, report := not_kept_report()
	testing.expect(t, report && count == 1)
	_, report = not_kept_report()
	testing.expect(t, !report)
	// The next frame keeps it, in place of the oldest glyph.
	frame_begin()
	_, _, kept := glyph(.Interface, STOP, past_size, 0)
	testing.expect_value(t, kept, Glyph_Source.Private_Cache)
	testing.expect_value(t, counts().evicted, u64(1))
	testing.expect_value(t, entry_find(test_cache(), key_of(.Interface, .B612, glyph_index_of(.B612, STOP), TEXT_SIZE_MINIMUM, 0)), -1)
}

// glyph_index_of gives the glyph of a character in an opened font.
@(private = "file")
glyph_index_of :: proc(font: Outline_Font, character: rune) -> int {
	index, _ := vector_font.glyph_of(&state.fonts[font].file, character)
	return index
}

// A frame larger than the cache: the full block of the cells at a large
// size takes a block of the largest orders, so the words fill before the
// entries. In one frame, each glyph is drawn; the glyphs that find no room
// are drawn and not kept, no glyph of the frame is evicted, and the words
// of the kept glyphs do not change. A glyph larger than the largest block
// is never kept: it is drawn band by band, and its bands are the rows of
// the glyph drawn whole at the bound of the render memory.
@(test)
a_frame_larger_than_the_cache :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	FULL_BLOCK :: rune(0x2588)
	BASE :: 6 * TEXT_SIZE_OF_SCALE_ONE // A cell of 48 by 96 pixels: 4 608 words, a block of the largest order but one.
	frame_begin()
	first, first_words, first_source := glyph(.Cells, FULL_BLOCK, BASE, 0)
	testing.expect_value(t, first_source, Glyph_Source.Private_Cache)
	first_count := int(first.row_count) * int(first.width)
	saved := make([]u32, first_count)
	defer delete(saved)
	copy(saved, first_words[:first_count])
	kept, not_kept := 1, 0
	for index in 1 ..< 200 {
		_, _, source := glyph(.Cells, FULL_BLOCK, BASE + index, 0)
		switch source {
		case .Private_Cache:
			kept += 1
		case .Not_Kept:
			not_kept += 1
		case .Missing, .Demand_Cache, .Banded:
			testing.expectf(t, false, "size %v: %v", BASE + index, source)
		}
	}
	fmt.printfln("text_rendering: a frame of 200 full blocks of 48 by 96 pixels: %v kept, %v drawn and not kept", kept, not_kept)
	testing.expect(t, not_kept > 0 && kept + not_kept == 200)
	testing.expect_value(t, counts().evicted, u64(0))
	testing.expect_value(t, counts().not_kept, u64(not_kept))
	again, again_words, again_source := glyph(.Cells, FULL_BLOCK, BASE, 0)
	testing.expect(t, again_source == .Private_Cache && again == first)
	testing.expect(t, mem.compare(mem.slice_to_bytes(saved), mem.slice_to_bytes(again_words[:first_count])) == 0)

	// A glyph past the largest block: Banded, with no entry.
	LARGE :: TEXT_SIZE_LIMIT
	_, _, large_source := glyph(.Cells, FULL_BLOCK, LARGE, 0)
	testing.expect_value(t, large_source, Glyph_Source.Banded)
	testing.expect_value(t, counts().banded, u64(1))
	job, started := glyph_bands(.Cells, FULL_BLOCK, LARGE, 0)
	testing.expect(t, started)
	rows, ink := 0, 0
	for {
		band_first, band_rows, band_words := band_next(&job)
		if band_rows == 0 {
			break
		}
		testing.expect_value(t, band_first, job.row_first + rows)
		rows += band_rows
		for word in band_words[:band_rows * job.columns] {
			if word != 0 {
				ink += 1
			}
		}
	}
	testing.expect(t, rows > 0 && rows <= LINE_ROW_LIMIT && ink > 0)
}

// The bands of a glyph give the words of the glyph drawn whole: at a size
// whose glyph fits the render memory, the rows of the bands, one after the
// other, are the rows of glyph_raster.
@(test)
the_bands_are_the_glyph_drawn_whole :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	Case :: struct {
		face:      Face,
		character: rune,
		size:      int,
	}
	cases := [?]Case{{.Interface, 'g', 3 * TEXT_SIZE_OF_SCALE_ONE}, {.Interface, 'W', 1280}, {.Cells, '@', 2 * TEXT_SIZE_OF_SCALE_ONE}, {.Interface_Bold, 0x03A9, 1536}}
	for each in cases {
		font, index := font_glyph_of(each.face, each.character)
		box, problem := glyph_raster(each.face, font, index, each.size, 0)
		testing.expect_value(t, problem, Raster_Problem.None)
		// The bands write the band of the raster memory and read the outline again:
		// the words of the glyph drawn whole stay in the words of that memory.
		job, started := glyph_bands(each.face, each.character, each.size, 0)
		testing.expect(t, started && job.columns == box.stride)
		box_column := box.left + job.origin_column // The column of the box in the work row.
		differ := 0
		for {
			band_first, band_rows, band_words := band_next(&job)
			if band_rows == 0 {
				break
			}
			for row in 0 ..< band_rows {
				line := band_first + row
				for word, column in band_words[row * job.columns:][:job.columns] {
					inside := line >= box.first_row && line < box.first_row + box.row_count && column >= box_column && column < box_column + box.width
					expected: u32
					if inside {
						expected = test_words()[box.first_word + (line - box.first_row) * box.stride + column - box_column]
					}
					differ += word != expected ? 1 : 0
				}
			}
		}
		testing.expectf(t, differ == 0, "%v U+%04X at size %v: %v words of the bands differ", each.face, int(each.character), each.size, differ)
	}
}

// A glyph of a fallback font stands in the frame of the first font of its
// face, at each size: a Greek letter of B612 in a cell of Paper Mono stays
// in its cell, and its baseline is the baseline of Paper Mono: its last
// row of ink is the last row of a letter of Paper Mono with no descender.
@(test)
a_fallback_glyph_stands_in_the_frame_of_the_first_font :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	for size in ([?]int{TEXT_SIZE_OF_SCALE_ONE, 1280, 1536, 2 * TEXT_SIZE_OF_SCALE_ONE, 3 * TEXT_SIZE_OF_SCALE_ONE}) {
		frame_begin()
		alpha, _, source := glyph(.Cells, 0x03B1, size, 0) // α of B612, no descender.
		testing.expect(t, source == .Private_Cache || source == .Demand_Cache)
		testing.expectf(t, alpha.left == 0 && int(alpha.width) == cell_columns(size) && int(alpha.first_row) + int(alpha.row_count) <= line_rows(size), "size %v: α stays in its cell", size)
		lambda, _, _ := glyph(.Cells, 0x03BB, size, 0) // λ of Paper Mono, no descender.
		alpha_bottom := int(alpha.first_row) + int(alpha.row_count)
		lambda_bottom := int(lambda.first_row) + int(lambda.row_count)
		testing.expectf(t, abs(alpha_bottom - lambda_bottom) <= 1, "size %v: α ends at row %v, λ at row %v", size, alpha_bottom, lambda_bottom)
		advance_value, found := advance(.Cells, 0x03B1, size)
		testing.expectf(t, found && advance_value == i32(vector_font.divide_rounded(i64(size), 2)), "size %v: the advance of a cell", size)
	}
}

// The words of today: for each face, each of the 192 characters of a
// glyph cache, each scale and each position, the glyph that this package
// draws at the text size of the scale has the box and the words of the
// glyph that the build of the glyph caches draws (vector_font, the code
// of the tool that makes the caches of the boot image). The faces of the
// interface are built with three positions at each scale: the positions 1
// and 2 at the scales 2 and 3 are the new ones, and the position 0 is the
// glyph of today's cache with one position.
@(test)
the_words_are_the_words_of_the_glyph_caches :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	memory := new(vector_font.Render_Memory)
	defer free(memory)
	out := make([]u64, vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT / 8)
	defer delete(out)
	file := ([^]u8)(raw_data(out))[:vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT]
	Case :: struct {
		face:  Face,
		bytes: []u8,
		name:  string,
	}
	cases := [?]Case{{.Interface, b612_file, "b612"}, {.Interface_Bold, b612_bold_file, "b612_bold"}, {.Cells, paper_mono_file, "paper_mono"}, {.Cells_Without_Grid_Fit, paper_mono_file, "paper_mono"}, {.Cells_Bold, paper_mono_semibold_file, "paper_mono_semibold"}}
	for each in cases {
		form := face_forms[each.face]
		font, problem := vector_font.font_open(each.bytes)
		testing.expect_value(t, problem, vector_font.Font_Problem.None)
		// The scales of the glyph cache of the face in the boot image: the
		// bold weights have scale 1 only, and the build of today refuses
		// some of their glyphs at the larger scales, whose ink passes its
		// row of 64 pixels.
		size: int
		if form.proportional {
			positions := [glyph_cache.SIZE_LIMIT]int{POSITION_LIMIT, POSITION_LIMIT, POSITION_LIMIT}
			size, problem = vector_font.glyph_cache_build_proportional(&font, each.bytes, each.name, form.grid_fit, memory, file, positions[:form.scale_count])
		} else {
			size, problem = vector_font.glyph_cache_build(&font, each.bytes, each.name, form.grid_fit, memory, file, form.scale_count)
		}
		testing.expectf(t, problem == .None, "%v: the build of today: %v", each.face, problem)
		cache, refused := glyph_cache.validate(file[:size])
		testing.expectf(t, refused.kind == .None, "%v: the cache of today: %v", each.face, refused.kind)
		if problem != .None || refused.kind != .None {
			continue
		}
		compared, differ := 0, 0
		start := time.tick_now()
		for scale in 1 ..= form.scale_count {
			text_size := size_of_scale(scale)
			for position in 0 ..< positions_of(each.face) {
				for index in 0 ..< glyph_cache.CHARACTER_COUNT {
					character, _ := glyph_cache.character_of_index(index)
					_, built, found := glyph_cache.glyph_of_index(&cache, index, scale, position)
					testing.expect(t, found)
					glyph_index, glyph_problem := vector_font.glyph_of(&state.fonts[form.primary].file, character)
					testing.expectf(t, glyph_problem == .None, "%v U+%04X: a glyph of its font", each.face, int(character))
					box, raster_problem := glyph_raster(each.face, form.primary, glyph_index, text_size, position)
					testing.expectf(t, raster_problem == .None, "%v U+%04X at size %v: %v", each.face, int(character), text_size, raster_problem)
					compared += 1
					same_box := int(built.row_count) == box.row_count && (box.row_count == 0 || int(built.first_row) == box.first_row && int(built.left) == box.left && int(built.width) == box.width)
					if !same_box {
						differ += 1
						testing.expectf(t, false, "%v U+%04X at size %v, position %v: the box %v, expected %v", each.face, int(character), text_size, position, box, built)
						continue
					}
					for row in 0 ..< box.row_count {
						new_row := test_words()[box.first_word + row * box.stride:][:box.width]
						old_row := cache.words[int(built.word_offset) + row * box.width:][:box.width]
						if mem.compare(mem.slice_to_bytes(new_row), mem.slice_to_bytes(old_row)) != 0 {
							differ += 1
							testing.expectf(t, false, "%v U+%04X at size %v, position %v: the row %v differs", each.face, int(character), text_size, position, row)
							break
						}
					}
				}
			}
		}
		fmt.printfln("text_rendering: %v: %v glyphs equal to the glyph caches of today, %v differ, %v", each.face, compared - differ, differ, time.tick_since(start))
	}
}

// The measure is the draw: at each size, for each face, the width of a
// text is the sum of the advances of its characters from the font file,
// the x of each placed glyph is the sum of the advances before it, and the
// fit of the start of a text in a room is the start whose measure is the
// room: a box computed from the measure holds what the fit and the break
// put in it.
@(test)
the_measure_is_the_draw :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	// Characters past the glyph caches only: the spacing has no table of a
	// cache, so each advance comes from a font file.
	text := "αβγΩ─λμ▒ν"
	sizes := [?]int{TEXT_SIZE_MINIMUM, TEXT_SIZE_OF_SCALE_ONE, 1280, 1536, 2 * TEXT_SIZE_OF_SCALE_ONE, 3 * TEXT_SIZE_OF_SCALE_ONE}
	for face in Face {
		if face == .None {
			continue
		}
		for size in sizes {
			spacing := Spacing{face = face, size = size}
			placed: [32]Placed_Glyph
			count, width, ok := shape(&spacing, transmute([]u8)text, placed[:])
			testing.expect(t, ok)
			sum: i64
			for glyph_placed in placed[:count] {
				testing.expectf(t, i64(glyph_placed.x) == sum, "%v at size %v: the x of a glyph is the sum before it", face, size)
				if glyph_placed.glyph != REPLACEMENT_GLYPH {
					value, found := advance(face, rune(glyph_placed.glyph - FALLBACK_GLYPH_FIRST), size)
					testing.expectf(t, found && value == glyph_placed.advance, "%v at size %v: the advance of the font file", face, size)
				}
				sum += i64(glyph_placed.advance)
			}
			testing.expect_value(t, width, sum)
			for glyph_placed in placed[1:count] {
				// A glyph of no advance (the replacement glyph of a spacing
				// with no table) does not end a fit.
				if glyph_placed.advance == 0 {
					continue
				}
				start := int(glyph_placed.cluster)
				room, _ := text_width(&spacing, transmute([]u8)text[:start])
				testing.expectf(t, text_fit(&spacing, transmute([]u8)text, room) == start, "%v at size %v: the fit of a room of %v is the start of %v bytes", face, size, room, start)
				testing.expectf(t, text_fit(&spacing, transmute([]u8)text, room - 1) < start, "%v at size %v: one less does not fit it", face, size)
			}
		}
	}
}

// The raster time of one glyph of each face at the lines of 16, 20, 24 and
// 32 pixels: the least of 200 draws of a glyph of the interface and of a
// glyph of the cells, past the private cache. A measure, never a test.
@(test)
the_raster_time_of_one_glyph :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	Case :: struct {
		face:      Face,
		character: rune,
	}
	cases := [?]Case{{.Interface, 'g'}, {.Interface_Bold, 'W'}, {.Cells, 'g'}, {.Cells_Without_Grid_Fit, 'g'}, {.Cells_Bold, 'W'}}
	for each in cases {
		font, index := font_glyph_of(each.face, each.character)
		for pixels in ([?]int{16, 20, 24, 32}) {
			least := max(i64)
			for _ in 0 ..< 200 {
				start := time.tick_now()
				_, problem := glyph_raster(each.face, font, index, pixels * SUBPIXEL, positions_of(each.face) - 1)
				elapsed := i64(time.tick_since(start))
				testing.expect_value(t, problem, Raster_Problem.None)
				least = min(least, elapsed)
			}
			fmt.printfln("text_rendering: the raster of one glyph of %v at a line of %v pixels: %v ns, the least of 200", each.face, pixels, least)
		}
	}
}

// The first font of a face draws the bytes of the demand cache: the glyph
// that this process draws in its private glyph cache is the glyph that the
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
				private, private_words, source := glyph(each.face, each.character, size_of_scale(scale), position)
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

// A change of a setting in the middle of a frame: the grid fit and the
// size are in the key, so a glyph of the other grid fit or of another size
// is another entry, and the words of the glyph drawn before stay as they
// were; the first setting again finds its glyph with no new draw.
@(test)
a_change_of_settings_in_the_middle_of_a_frame :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	ALPHA :: rune(0x03B1)
	frame_begin()
	with_fit, with_words, source := glyph(.Cells, ALPHA, TEXT_SIZE_OF_SCALE_ONE, 0)
	testing.expect_value(t, source, Glyph_Source.Private_Cache)
	saved: [8 * 16]u32
	count := int(with_fit.row_count) * int(with_fit.width)
	testing.expect(t, count > 0 && count <= len(saved))
	copy(saved[:count], with_words[:count])
	_, _, source = glyph(.Cells_Without_Grid_Fit, ALPHA, TEXT_SIZE_OF_SCALE_ONE, 0)
	testing.expect_value(t, source, Glyph_Source.Private_Cache)
	_, _, source = glyph(.Cells, ALPHA, 1280, 0)
	testing.expect_value(t, source, Glyph_Source.Private_Cache)
	testing.expect_value(t, counts().drawn, u64(3))
	again, again_words, _ := glyph(.Cells, ALPHA, TEXT_SIZE_OF_SCALE_ONE, 0)
	testing.expect_value(t, counts().drawn, u64(3))
	testing.expect(t, again == with_fit && again_words == with_words)
	testing.expect(t, mem.compare(mem.slice_to_bytes(saved[:count]), mem.slice_to_bytes(again_words[:count])) == 0)
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
			header := cache.header^
			header.font_hash[0] ~= 1
			other := cache
			other.header = &header
			testing.expect_value(t, face_of_cache(&other), Face.None)
		}
	}
}
