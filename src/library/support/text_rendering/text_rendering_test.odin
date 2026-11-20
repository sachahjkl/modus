#+build !freestanding
package text_rendering

import "core:fmt"
import "base:runtime"
import "core:mem"
import "core:sync"
import "core:testing"
import "core:time"
import "modus:contract/blake3"
import "modus:contract/font_outlines"
import "modus:contract/font_characters"
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
// its end. The tests of shaping_test.odin and raster_test.odin take it too.
//
// The words of the outlines that a test opens come from the allocator of
// the test, which the runner frees at its end: the state would then point
// at freed bytes. So the end of the lock clears the state, in each test of
// the package, before the next test can take it.
test_state_lock: sync.Mutex

// The measures of time of this package run only with -define:MEASURE=true:
// a test that measures time is opt-in, and a normal run prints no time.
MEASURE :: #config(MEASURE, false)

@(deferred_none = test_state_give)
test_state_take :: proc() {
	sync.mutex_lock(&test_state_lock)
}

test_state_give :: proc() {
	state = {}
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
outlines_open :: proc(t: ^testing.T, fonts: []font_outlines.Font_Input) -> (missing: Outline_Fonts, words: []u64) {
	outlines: font_outlines.Outlines
	outlines, words = resource_of(t, fonts)
	state = {}
	memory_reset_for_test()
	return open(&outlines), words
}

// The glyph memory of the tests: one for the package, as in a process,
// all zero at each open, and given as a process gives it at its first
// glyph past the glyph caches.
test_glyph_memory: ^Glyph_Memory

// memory_reset_for_test empties the cache and gives the package its glyph
// memory again, all zero. The memory comes from the heap of the process,
// not from the allocator of the test: the runner frees all that a test
// allocated at its end, and the next test would get the same bytes while
// the package still draws into them.
memory_reset_for_test :: proc() {
	if test_glyph_memory == nil {
		test_glyph_memory = new(Glyph_Memory, runtime.heap_allocator())
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

// The baseline of a face: no baseline before the open, for the face None,
// and for each size that the measure refuses. At each size that it gives,
// it is inside the line, it does not go up when the size grows (a caption
// and a title on one baseline need that order), and it is the row of the
// baseline of a glyph that the rasterizer places, last.
@(test)
the_baseline_of_a_face :: proc(t: ^testing.T) {
	test_state_take()
	for face in Face {
		_, found := baseline_row(face, TEXT_SIZE_OF_SCALE_ONE)
		testing.expectf(t, !found, "%v before the open: no baseline", face)
	}
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	_, none_found := baseline_row(.None, TEXT_SIZE_OF_SCALE_ONE)
	testing.expect(t, !none_found, "the face None: no baseline")
	for size in ([?]int{0, 1, TEXT_SIZE_MINIMUM - 1, -1, min(int), TEXT_SIZE_LIMIT + 1, max(int)}) {
		for face in Face {
			_, found := baseline_row(face, size)
			testing.expectf(t, !found, "%v at the size %v: no baseline", face, size)
		}
	}
	for face in Face {
		if face == .None {
			continue
		}
		previous := 0
		for size := TEXT_SIZE_MINIMUM; size <= TEXT_SIZE_LIMIT; size += SUBPIXEL {
			row, found := baseline_row(face, size)
			testing.expectf(t, found, "%v at the size %v: a baseline", face, size)
			testing.expectf(t, row >= 1 && row <= line_rows(size), "%v at the size %v: the row %v is inside the line of %v rows", face, size, row, line_rows(size))
			testing.expectf(t, row >= previous, "%v at the size %v: the row %v is above the row %v of a smaller size", face, size, row, previous)
			previous = row
		}
		primary := face_forms[face].primary
		for line in ([?]int{14, 16, 24, 32, 48}) {
			size := line * SUBPIXEL
			row, _ := baseline_row(face, size)
			job, problem := raster_begin(face, primary, glyph_index_of(primary, 'x'), size, 0)
			testing.expectf(t, problem == .None, "%v at a line of %v: the glyph x is placed", face, line)
			testing.expectf(t, row == job.baseline, "%v at a line of %v: the row %v is the baseline %v of the rasterizer", face, line, row, job.baseline)
		}
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
	testing.expect_value(t, open(&outlines), Outline_Fonts{})
	testing.expect_value(t, font_of(.Interface, 0x2500), Outline_Font.None)
}

// The fonts that the chains of a face can name: none before open and for
// the face None; only the fonts that the outlines hold; each font of each
// chain of the face with the four fonts, last.
@(test)
the_fonts_of_the_chains_of_a_face :: proc(t: ^testing.T) {
	test_state_take()
	state = {}
	memory_reset_for_test()
	testing.expect_value(t, chain_fonts(.Cells), Outline_Fonts{})
	only := [1]font_outlines.Font_Input{{"b612", b612_file}}
	_, words := outlines_open(t, only[:])
	defer delete(words)
	testing.expect_value(t, chain_fonts(.None), Outline_Fonts{})
	testing.expect_value(t, chain_fonts(.Interface), Outline_Fonts{.B612})
	testing.expect_value(t, chain_fonts(.Cells), Outline_Fonts{.B612})
	fonts := repository_fonts()
	_, all_words := outlines_open(t, fonts[:])
	defer delete(all_words)
	testing.expect_value(t, chain_fonts(.None), Outline_Fonts{})
	testing.expect_value(t, chain_fonts(.Interface), Outline_Fonts{.B612, .Paper_Mono})
	testing.expect_value(t, chain_fonts(.Cells), Outline_Fonts{.Paper_Mono, .B612})
	testing.expect_value(t, chain_fonts(.Cells_Without_Grid_Fit), Outline_Fonts{.Paper_Mono, .B612})
	testing.expect_value(t, chain_fonts(.Interface_Bold), Outline_Fonts{.B612_Bold, .B612, .Paper_Mono_Semibold})
	testing.expect_value(t, chain_fonts(.Cells_Bold), Outline_Fonts{.Paper_Mono_Semibold, .B612_Bold, .B612})
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
		case .Missing, .Banded:
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
		testing.expect_value(t, source, Glyph_Source.Private_Cache)
		testing.expectf(t, alpha.left == 0 && int(alpha.width) == cell_columns(size) && int(alpha.first_row) + int(alpha.row_count) <= line_rows(size), "size %v: α stays in its cell", size)
		lambda, _, _ := glyph(.Cells, 0x03BB, size, 0) // λ of Paper Mono, no descender.
		alpha_bottom := int(alpha.first_row) + int(alpha.row_count)
		lambda_bottom := int(lambda.first_row) + int(lambda.row_count)
		testing.expectf(t, abs(alpha_bottom - lambda_bottom) <= 1, "size %v: α ends at row %v, λ at row %v", size, alpha_bottom, lambda_bottom)
		advance_value, found := advance(.Cells, 0x03B1, size)
		testing.expectf(t, found && advance_value == i32(vector_font.divide_rounded(i64(size), 2)), "size %v: the advance of a cell", size)
	}
}

// The sizes and the positions of the golden hashes of each face: the
// scales that the glyph caches of the boot image held when the hashes were
// taken, and, for the characters past the 192, the positions at each scale
// that the demand cache held. The 192 characters are hashed at each
// position of the face (positions_of).
@(private = "file")
Golden_Form :: struct {
	scale_count:    int, // The scales 1 ..= scale_count.
	past_positions: [3]int, // The positions of the characters past the 192 at each scale; 0 past scale_count.
}

@(private = "file")
golden_forms := [Face]Golden_Form {
	.None                   = {},
	.Interface              = {3, {3, 1, 1}},
	.Interface_Bold         = {1, {3, 0, 0}},
	.Cells                  = {3, {1, 1, 1}},
	.Cells_Without_Grid_Fit = {3, {1, 1, 1}},
	.Cells_Bold             = {1, {1, 0, 0}},
}

// Why golden_bytes_of gives no bytes.
Golden_Problem :: enum {
	None,
	Unknown_Face, // A face that names no member, and the face None.
	Size_Refused, // A size that size_check refuses.
	No_Golden_Row, // A valid size that golden_forms does not hash for the face: no stored hash names it.
}

// golden_bytes_of gives the bytes of the golden hash of the 192
// characters of a face at a text size (golden_bytes_append), at each
// position of the face, in bytes, which it empties first. The outlines are
// open in the state of the package. It refuses a face that names no
// member, a size that size_check refuses, and a size that has no golden
// hash for the face, and then leaves bytes empty.
golden_bytes_of :: proc(t: ^testing.T, face: Face, size: int, bytes: ^[dynamic]u8) -> Golden_Problem {
	clear(bytes)
	if _, known := face_of_word(i64(face)); !known {
		return .Unknown_Face
	}
	if size_check(size) != .None {
		return .Size_Refused
	}
	hashed := false
	for scale in 1 ..= golden_forms[face].scale_count {
		if size_of_scale(scale) == size {
			hashed = true
		}
	}
	if !hashed {
		return .No_Golden_Row
	}
	form := face_forms[face]
	for position in 0 ..< positions_of(face) {
		for index in 0 ..< font_characters.CHARACTER_COUNT {
			character, _ := font_characters.character_of_index(index)
			glyph_index, glyph_problem := vector_font.glyph_of(&state.fonts[form.primary].file, character)
			testing.expectf(t, glyph_problem == .None, "%v U+%04X: a glyph of its font", face, int(character))
			box, raster_problem := glyph_raster(face, form.primary, glyph_index, size, position)
			testing.expectf(t, raster_problem == .None, "%v U+%04X at size %v: %v", face, int(character), size, raster_problem)
			golden_bytes_append(bytes, box)
		}
	}
	return .None
}

// The 192 characters keep their pixels: for each face, each scale of its
// golden hashes and each position, the glyphs that this package draws at
// the text size of the scale give the stored golden hash. A changed pixel,
// box or word fails with the face, the size and the hash found. The hashes
// come from a build whose test compared each of these words with the
// glyph caches that the boot image held then, so the pixels of the desktop
// stay those of the caches that left.
@(test)
the_192_characters_keep_their_golden_hashes :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	golden_bytes := make([dynamic]u8)
	defer delete(golden_bytes)
	for face in Face {
		if face == .None {
			continue
		}
		for scale in 1 ..= golden_forms[face].scale_count {
			text_size := size_of_scale(scale)
			testing.expect_value(t, golden_bytes_of(t, face, text_size, &golden_bytes), Golden_Problem.None)
			found := golden_hash_text(blake3.hash(golden_bytes[:]))
			fmt.printfln("text_rendering: the golden hash of %v at the size %v: %s", face, text_size, found)
			golden_hash_check(t, face, text_size, .The_192_Characters, found)
		}
	}
}

// The golden hash refuses what it does not name, and sees one pixel. A
// face that names no member and the face None, the sizes that size_check
// refuses (0, one under TEXT_SIZE_MINIMUM, one past TEXT_SIZE_LIMIT, a
// negative size, the largest int) and a valid size that no row names (a
// line of 20 pixels for the cells, the scale 2 of the bold weight) give no
// bytes. Then one bit of the last word of the 192 characters of the face
// Cells at the size 1 024 changed: the hash is no longer the stored hash;
// changed back, it is again.
@(test)
a_golden_hash_refuses_and_sees_one_pixel :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	bytes := make([dynamic]u8)
	defer delete(bytes)
	unknown_word := u8(max(Face)) + 1
	for face in ([2]Face{.None, Face(unknown_word)}) {
		append(&bytes, 1)
		testing.expect_value(t, golden_bytes_of(t, face, TEXT_SIZE_OF_SCALE_ONE, &bytes), Golden_Problem.Unknown_Face)
		testing.expect_value(t, len(bytes), 0)
	}
	for size in ([5]int{0, TEXT_SIZE_MINIMUM - 1, TEXT_SIZE_LIMIT + 1, -TEXT_SIZE_OF_SCALE_ONE, max(int)}) {
		testing.expectf(t, golden_bytes_of(t, .Cells, size, &bytes) == .Size_Refused, "the size %v is refused", size)
		testing.expect_value(t, len(bytes), 0)
	}
	testing.expect_value(t, golden_bytes_of(t, .Cells, 20 * SUBPIXEL, &bytes), Golden_Problem.No_Golden_Row)
	testing.expect_value(t, golden_bytes_of(t, .Interface_Bold, size_of_scale(2), &bytes), Golden_Problem.No_Golden_Row)
	testing.expect_value(t, len(bytes), 0)

	testing.expect_value(t, golden_bytes_of(t, .Cells, TEXT_SIZE_OF_SCALE_ONE, &bytes), Golden_Problem.None)
	stored, stored_found := golden_hash_stored(.Cells, TEXT_SIZE_OF_SCALE_ONE, .The_192_Characters)
	testing.expect(t, stored_found && stored != GOLDEN_HASH_NOT_STORED)
	testing.expect_value(t, golden_hash_text(blake3.hash(bytes[:])), stored)
	// The last byte: the coverage of the whole pixel of the last word of
	// the euro sign, the last of the 192 characters.
	bytes[len(bytes) - 1] ~= 1
	testing.expect(t, golden_hash_text(blake3.hash(bytes[:])) != stored, "a pixel changed, and the golden hash did not")
	bytes[len(bytes) - 1] ~= 1
	testing.expect_value(t, golden_hash_text(blake3.hash(bytes[:])), stored)
}

// golden_bytes_append adds a glyph that glyph_raster drew, as the golden
// hash reads it: its box as four numbers of 32 bits in little endian
// (first_row, row_count, left, width), then its words, row after row, each
// in little endian. The hash of these bytes over the 192 characters, by
// their character index, at each position of a face at one size, is the
// golden hash of that face and size (src/md/features/text_rendering.md,
// "The rasterizer").
golden_bytes_append :: proc(bytes: ^[dynamic]u8, box: Raster_Box) {
	word_append :: proc(bytes: ^[dynamic]u8, word: u32) {
		append(bytes, u8(word), u8(word >> 8), u8(word >> 16), u8(word >> 24))
	}
	word_append(bytes, u32(i32(box.first_row)))
	word_append(bytes, u32(i32(box.row_count)))
	word_append(bytes, u32(i32(box.left)))
	word_append(bytes, u32(i32(box.width)))
	for row in 0 ..< box.row_count {
		for word in test_words()[box.first_word + row * box.stride:][:box.width] {
			word_append(bytes, word)
		}
	}
}

// The characters of a golden hash.
Golden_Characters :: enum {
	// The 192 characters, by their character index, at each position of
	// the face (positions_of).
	The_192_Characters,
	// The characters past the 192 that the subset of the first font of the
	// face holds (font_outlines.interface_past_cache_ranges,
	// cell_past_cache_ranges), in the order of the code points, at the
	// positions of golden_forms: the glyphs that the demand cache held.
	Past_The_192_Characters,
}

// One stored golden hash.
Golden_Hash :: struct {
	face:       Face,
	size:       int,
	characters: Golden_Characters,
	hash:       string, // 64 hexadecimal digits in lower case; GOLDEN_HASH_NOT_STORED until a run gives it.
}

// The mark of a row whose hash a run has not given yet: the test fails on
// it, and its message gives the hash to store.
GOLDEN_HASH_NOT_STORED :: ""

// The golden hashes: the one proof that the pixels of the text did not
// change (src/md/features/text_rendering.md, "The rasterizer"). Those of
// the 192 characters come from the last build that had the glyph caches
// of the boot image, whose test compared each word with the code that
// built them. Those past the 192 come from the first build without the
// demand cache, whose rasterizer a test of the build before compared with
// it, word for word. A row marked GOLDEN_HASH_NOT_STORED fails and gives
// its hash in the message.
golden_hashes := [?]Golden_Hash {
	{.Interface, 1024, .The_192_Characters, "ffb96a288dce3f7055db33d5272e600f090e3b1ab7e26c7fd4b179f1a01b50a5"},
	{.Interface, 2048, .The_192_Characters, "8e71073bbc65aaf60657a7cd959cf516ea6c549c45c131bc3d9864bc5377d2b2"},
	{.Interface, 3072, .The_192_Characters, "995580da0f7a1aa66933df5674d52efaec10e81e9a496bb70857a654adcde1d1"},
	{.Interface_Bold, 1024, .The_192_Characters, "2505e899bfa2a602c1a89a902a373a9ad64212cad0f78ba9f3ee494aa6931e03"},
	{.Cells, 1024, .The_192_Characters, "c2d2aac39d9d1cdbda5d92de2aa436684f7a1a6b808bd3b3af04e72bb5e5139e"},
	{.Cells, 2048, .The_192_Characters, "8a30c44752198c04d24b1898e3629724dfba988c4fcfcd9ace46ba4f2c653def"},
	{.Cells, 3072, .The_192_Characters, "abc3a2ef28a929950daa36bedfa024485058ffdcabcee989af1adae7dd20624f"},
	{.Cells_Without_Grid_Fit, 1024, .The_192_Characters, "5d4508c60ca205998c4ec54e18a858391df734056e4a86cd379198aea0342445"},
	{.Cells_Without_Grid_Fit, 2048, .The_192_Characters, "3e3e8731e5c67b4a1c8309082687b0c962117a765e362e62c5d638625f7b6231"},
	{.Cells_Without_Grid_Fit, 3072, .The_192_Characters, "4ddef9cb9498ffbaeaf50813e022ca8e2eec629d7c581c2712108a546035b590"},
	{.Cells_Bold, 1024, .The_192_Characters, "df9bce041d1ec8ff9cd23d435f56c832e136df6752734fd5b304ba0d7b15cf3e"},
	{.Interface, 1024, .Past_The_192_Characters, "680eceaeda3786a5d8fd27c6cee901e024fe3a6d0c5e9dffa2dce52ac62a8409"},
	{.Interface, 2048, .Past_The_192_Characters, "f7222768c7bb9b8485b0f6b344acf824a71d4e8b3e9d6d38f9ee445dda78990d"},
	{.Interface, 3072, .Past_The_192_Characters, "0b025715646303be9254c0c0bd29b62d34cbe5fd1e8bfba723c49793c7f8776a"},
	{.Cells, 1024, .Past_The_192_Characters, "2d9a41d2f68b57b9266fee9abe77c7bd09cd7686b3ac6588527637d6d87230ab"},
	{.Cells, 2048, .Past_The_192_Characters, "1b2ce70a0959e56828c4a59187bd4394dc3d008c075d122803dc19364d93b9a7"},
	{.Cells, 3072, .Past_The_192_Characters, "2fd2b92c3b7c983ea156b28edefc8598ec77c8a30709fa4a639a755ea1faafad"},
	{.Cells_Without_Grid_Fit, 1024, .Past_The_192_Characters, "f2734820b63d4324d11e58c5a3aceceeae2813b1f66bf188a37159bb40780b57"},
	{.Cells_Without_Grid_Fit, 2048, .Past_The_192_Characters, "d870f102e96b46650f7c97510531f0dc6e195b9f5118a6dc8eda61f1681d995d"},
	{.Cells_Without_Grid_Fit, 3072, .Past_The_192_Characters, "3432d2fc22b9b94b7e8e93cbe72b0c07b5854e7f609e9f2d56743de9d87c8bf4"},
	{.Cells_Bold, 1024, .Past_The_192_Characters, "5e23b4844eb65bc1ec1ad3fa347e328586685bf5a55858a84a944f700cd2c5fa"},
}

// golden_hash_check compares a hash that a test found with the stored
// golden hash of its face, size and characters. A row with no stored hash
// fails, and gives the hash to store.
golden_hash_check :: proc(t: ^testing.T, face: Face, size: int, characters: Golden_Characters, found: string) {
	stored, has_row := golden_hash_stored(face, size, characters)
	switch {
	case !has_row:
		testing.expectf(t, false, "%v at the size %v, %v: golden_hashes has no row, and the hash is %s", face, size, characters, found)
	case stored == GOLDEN_HASH_NOT_STORED:
		testing.expectf(t, false, "%v at the size %v, %v: no golden hash is stored; store %s in golden_hashes", face, size, characters, found)
	case:
		testing.expectf(t, stored == found, "%v at the size %v, %v: the golden hash is %s, and the stored one %s", face, size, characters, found, stored)
	}
}

// golden_hash_stored gives the stored golden hash of a face, a size and a
// set of characters; has_row is false when golden_hashes has no row for
// them.
golden_hash_stored :: proc(face: Face, size: int, characters: Golden_Characters) -> (hash: string, has_row: bool) {
	for row in golden_hashes {
		if row.face == face && row.size == size && row.characters == characters {
			return row.hash, true
		}
	}
	return "", false
}

// The table of the golden hashes: one row for each face, size and set of
// characters, and each stored hash is 64 digits in lower case.
@(test)
the_table_of_the_golden_hashes :: proc(t: ^testing.T) {
	for row, index in golden_hashes {
		for other in golden_hashes[index + 1:] {
			testing.expectf(t, other.face != row.face || other.size != row.size || other.characters != row.characters, "%v at the size %v, %v: two rows", row.face, row.size, row.characters)
		}
		if row.hash == GOLDEN_HASH_NOT_STORED {
			continue
		}
		testing.expectf(t, len(row.hash) == 2 * blake3.HASH_SIZE, "%v at the size %v: a hash of %v digits", row.face, row.size, len(row.hash))
		for digit in row.hash {
			testing.expectf(t, digit >= '0' && digit <= '9' || digit >= 'a' && digit <= 'f', "%v at the size %v: the digit %v", row.face, row.size, digit)
		}
	}
}

// The glyphs past the 192 characters keep their pixels: for each face
// that the demand cache held, at each size and position that it held, the
// characters past the 192 of the subset of its first font, each from that
// font, give the stored golden hash. These are the glyphs that a process
// drew from the demand cache before it left.
@(test)
the_glyphs_past_the_192_characters_keep_their_golden_hashes :: proc(t: ^testing.T) {
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	Case :: struct {
		face:   Face,
		ranges: []font_outlines.Character_Range,
		count:  int,
	}
	cases := [?]Case {
		{.Interface, font_outlines.interface_past_cache_ranges[:], font_outlines.INTERFACE_PAST_CACHE_COUNT},
		{.Cells, font_outlines.cell_past_cache_ranges[:], font_outlines.CELL_PAST_CACHE_COUNT},
		{.Cells_Without_Grid_Fit, font_outlines.cell_past_cache_ranges[:], font_outlines.CELL_PAST_CACHE_COUNT},
		{.Cells_Bold, font_outlines.cell_past_cache_ranges[:], font_outlines.CELL_PAST_CACHE_COUNT},
	}
	for each in cases {
		form := face_forms[each.face]
		golden := golden_forms[each.face]
		for scale in 1 ..= golden.scale_count {
			text_size := size_of_scale(scale)
			golden_bytes := make([dynamic]u8)
			defer delete(golden_bytes)
			drawn := 0
			for position in 0 ..< golden.past_positions[scale - 1] {
				for range in each.ranges {
					for character in range.first ..= range.last {
						font, glyph_index := font_glyph_of(each.face, character)
						testing.expectf(t, font == form.primary, "%v U+%04X: from %v, not from the first font of its face", each.face, int(character), font)
						if font == .None {
							continue
						}
						box, problem := glyph_raster(each.face, font, glyph_index, text_size, position)
						testing.expectf(t, problem == .None, "%v U+%04X at the size %v: %v", each.face, int(character), text_size, problem)
						golden_bytes_append(&golden_bytes, box)
						drawn += 1
					}
				}
			}
			testing.expect_value(t, drawn, each.count * golden.past_positions[scale - 1])
			found := golden_hash_text(blake3.hash(golden_bytes[:]))
			fmt.printfln("text_rendering: the golden hash of %v at the size %v, past the 192 characters: %s", each.face, text_size, found)
			golden_hash_check(t, each.face, text_size, .Past_The_192_Characters, found)
		}
	}
}

// golden_hash_text gives a hash as 64 hexadecimal digits, in lower case.
golden_hash_text :: proc(hash: blake3.Hash) -> string {
	digits := "0123456789abcdef"
	text := make([]u8, 2 * blake3.HASH_SIZE, context.temp_allocator)
	for byte_value, index in hash {
		text[2 * index] = digits[byte_value >> 4]
		text[2 * index + 1] = digits[byte_value & 0xF]
	}
	return string(text)
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
	if !MEASURE {
		return
	}
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

// The time of the measure of 100 lines of the interface font at a line of
// 16 pixels from the font file (measure_ranges, as each process measures).
// The least of 200 rounds; each width is the width of its line alone. A
// measure, never a test of a speed.
@(test)
the_measure_time_of_a_hundred_lines :: proc(t: ^testing.T) {
	if !MEASURE {
		return
	}
	test_state_take()
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	LINES :: 100
	sample := [?]string{"Settings", "To AVATAR", "The interface takes it for titles, labels and buttons", "LT Wave", "processor_frame", "42 windows"}
	bytes := make([dynamic]u8)
	defer delete(bytes)
	ranges := make([]Text_Range, LINES)
	defer delete(ranges)
	for index in 0 ..< LINES {
		line := sample[index % len(sample)]
		ranges[index] = {start = u32(len(bytes)), count = u32(len(line))}
		append(&bytes, ..transmute([]u8)line)
	}
	spacing, ok := spacing_of(.Interface, TEXT_SIZE_OF_SCALE_ONE)
	testing.expect(t, ok)
	least_file := max(i64)
	for _ in 0 ..< 200 {
		start := time.tick_now()
		_, _, _ = measure_ranges(&spacing, bytes[:], ranges)
		least_file = min(least_file, i64(time.tick_since(start)))
	}
	for range in ranges {
		alone, alone_ok := text_width(&spacing, bytes[range.start:][:range.count])
		testing.expect(t, alone_ok && range.width == alone)
	}
	fmt.printfln("text_rendering: the measure of %v lines of B612 at a line of 16 pixels, the least of 200: %v ns from the font file", LINES, least_file)
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

// A face draws only when the outlines hold its first font: the face None
// never, no face before open, and with outlines of B612 alone only the
// face Interface; with the four fonts each face, last.
@(test)
a_face_is_opened_with_its_first_font :: proc(t: ^testing.T) {
	test_state_take()
	state = {}
	for face in Face {
		testing.expectf(t, !face_opened(face), "%v is opened before open", face)
	}
	only := [1]font_outlines.Font_Input{{"b612", b612_file}}
	_, only_words := outlines_open(t, only[:])
	defer delete(only_words)
	for face in Face {
		testing.expectf(t, face_opened(face) == (face == .Interface), "outlines of B612 alone: %v opened %v", face, face_opened(face))
	}
	fonts := repository_fonts()
	_, words := outlines_open(t, fonts[:])
	defer delete(words)
	for face in Face {
		testing.expectf(t, face_opened(face) == (face != .None), "the four fonts: %v opened %v", face, face_opened(face))
	}
}
