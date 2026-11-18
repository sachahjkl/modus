#+build !freestanding
package graphics

import "core:mem"
import "core:sync"
import "core:testing"
import "modus:contract/demand_cache"
import "modus:contract/font_outlines"
import "modus:contract/glyph_cache"
import "modus:support/text_rendering"
import "modus:support/vector_font"

// The tests of this package that open the fallback state run one at a
// time: the state is one for the package, and the runner runs tests on
// several threads. Each one sets the state back to zero at its end.
fallback_test_lock: sync.Mutex

// fallback_open_for_test opens the four font files of the resource of the
// boot image, and the demand cache at demand_base (0: none), in a fallback
// state of all zero. The caller frees the words.
@(private = "file")
test_glyph_memory: ^text_rendering.Glyph_Memory

fallback_open_for_test :: proc(t: ^testing.T, demand_base: uintptr) -> (words: []u64) {
	fonts := [4]font_outlines.Font_Input {
		{"b612", #load("../../../../resources/fonts/b612.ttf")},
		{"b612_bold", #load("../../../../resources/fonts/b612_bold.ttf")},
		{"paper_mono", #load("../../../../resources/fonts/paper_mono.ttf")},
		{"paper_mono_semibold", #load("../../../../resources/fonts/paper_mono_semibold.ttf")},
	}
	size := font_outlines.resource_size(fonts[:])
	words = make([]u64, (size + 7) / 8)
	bytes := ([^]u8)(raw_data(words))[:size]
	_, written := font_outlines.resource_write(fonts[:], bytes)
	testing.expect(t, written)
	outlines, problem := font_outlines.validate(bytes)
	testing.expect_value(t, problem.kind, font_outlines.Problem_Kind.None)
	text_rendering.state = {}
	// The glyph memory that a process reserves at its first glyph past the
	// glyph caches: memory of the test here, all zero at each open.
	if test_glyph_memory == nil {
		test_glyph_memory = new(text_rendering.Glyph_Memory)
	}
	mem.zero(test_glyph_memory, size_of(text_rendering.Glyph_Memory))
	text_rendering.cache_state = {}
	text_rendering.memory_give(test_glyph_memory)
	missing := text_rendering.open(&outlines, demand_base)
	testing.expect_value(t, missing, text_rendering.Outline_Fonts{})
	return words
}

// A cell past the glyph cache draws its glyph from the fallback chain of
// the cells, with the blend of each cell. First what draws the replacement
// glyph: no outlines open, a character that no font has, and the setting
// Spleen. Then the glyph of 'A' that the font service drew and published
// as U+2500 gives the pixels of 'A' from the glyph cache of cells of the
// same font file, at each scale, from the demand cache; the same character
// drawn in the private glyph cache gives the pixels of the demand cache;
// and a Greek letter of B612, the second font of the chain, stays in its
// cell.
@(test)
a_cell_on_demand_draws_the_pixels_of_the_glyph_cache :: proc(t: ^testing.T) {
	sync.mutex_lock(&fallback_test_lock)
	defer sync.mutex_unlock(&fallback_test_lock)
	defer text_rendering.state = {}
	font_bytes := #load("../../../../resources/fonts/paper_mono.ttf")
	render := new(vector_font.Render_Memory)
	defer free(render)
	font, problem := vector_font.font_open(font_bytes)
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	memory := make([]u64, vector_font.GLYPH_CACHE_LIMIT / 8)
	defer delete(memory)
	file := ([^]u8)(raw_data(memory))[:vector_font.GLYPH_CACHE_LIMIT]
	size: int
	size, problem = vector_font.glyph_cache_build(&font, font_bytes, "paper_mono", true, render, file)
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	cache, refused := glyph_cache.validate(file[:size])
	testing.expect_value(t, refused.kind, glyph_cache.Problem_Kind.None)

	saved := text_state
	defer text_state = saved
	testing.expect_value(t, text_cache_use(cache).kind, glyph_cache.Problem_Kind.None)
	WIDTH :: 3 * CELL_WIDTH * 3
	HEIGHT :: CELL_HEIGHT * 3
	built_pixels, fallback_pixels: [WIDTH * HEIGHT]Color
	built := Canvas{pixels = raw_data(built_pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
	drawn := Canvas{pixels = raw_data(fallback_pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
	BOX :: rune(0x2500)

	// The replacement glyph: no outlines, no font for Ж, and Spleen.
	Case :: enum {
		No_Outlines,
		No_Font,
		Spleen,
	}
	for each in Case {
		text_choice_set(.Vector, .Red_Green_Blue)
		text := "─"
		words: []u64
		switch each {
		case .No_Outlines:
			text_rendering.state = {}
		case .No_Font:
			words = fallback_open_for_test(t, 0)
			text = "Ж"
		case .Spleen:
			words = fallback_open_for_test(t, 0)
			text_choice_set(.Spleen, .Red_Green_Blue)
		}
		clear(built, DARK_CARD_BOTTOM)
		clear(drawn, DARK_CARD_BOTTOM)
		character_replacement(built, CELL_WIDTH, 0, DARK_TEXT, 1)
		text_scaled(drawn, CELL_WIDTH, 0, text, DARK_TEXT, 1)
		testing.expectf(t, built_pixels == fallback_pixels, "%v: the replacement glyph", each)
		delete(words)
	}
	text_choice_set(.Vector, .Red_Green_Blue)

	// The demand cache: 'A' published as U+2500.
	demand_font: vector_font.Demand_Font
	demand_font, problem = vector_font.demand_font_open(font_bytes, .Cells, render)
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	bytes, allocation := mem.alloc_bytes(demand_cache.SIZE, demand_cache.PAGE_SIZE)
	testing.expect(t, allocation == nil)
	defer mem.free_bytes(bytes)
	base := uintptr(raw_data(bytes))
	faces: [demand_cache.Face]demand_cache.Face_Header
	faces[.Cells] = {font_hash = cache.header.font_hash, flags = demand_font.flags}
	writer := demand_cache.writer_open(base, vector_font.RENDERER_VERSION, faces)
	entry, result := vector_font.demand_glyph_draw(&demand_font, &writer, 'A', render)
	testing.expect_value(t, result, vector_font.Demand_Result.Drawn)
	place, _ := demand_cache.place_find(&writer, .Cells, BOX)
	demand_cache.publish(&writer, place, .Cells, BOX, entry)
	words := fallback_open_for_test(t, base)
	defer delete(words)
	text_rendering.frame_begin()
	testing.expect_value(t, cell_face(), text_rendering.Face.Cells)
	for scale in 1 ..= 3 {
		clear(built, DARK_CARD_BOTTOM)
		clear(drawn, DARK_CARD_BOTTOM)
		text_scaled(built, CELL_WIDTH * scale, 0, "A", DARK_TEXT, scale)
		text_scaled(drawn, CELL_WIDTH * scale, 0, "─", DARK_TEXT, scale)
		testing.expectf(t, built_pixels == fallback_pixels, "scale %v: the cell from the demand cache has the pixels of the glyph cache", scale)
	}
	// One character at scale 1, as `character` draws it.
	clear(built, DARK_CARD_BOTTOM)
	clear(drawn, DARK_CARD_BOTTOM)
	character(built, CELL_WIDTH, 0, 'A', DARK_TEXT)
	character(drawn, CELL_WIDTH, 0, BOX, DARK_TEXT)
	testing.expect(t, built_pixels == fallback_pixels)

	// The private glyph cache: ═ drawn by the font service and by this
	// process give the same pixels; and α of B612 stays in its cell.
	DOUBLE :: rune(0x2550)
	double_entry: demand_cache.Entry
	double_entry, result = vector_font.demand_glyph_draw(&demand_font, &writer, DOUBLE, render)
	testing.expect_value(t, result, vector_font.Demand_Result.Drawn)
	place, _ = demand_cache.place_find(&writer, .Cells, DOUBLE)
	demand_cache.publish(&writer, place, .Cells, DOUBLE, double_entry)
	for scale in 1 ..= 3 {
		text_rendering.frame_begin()
		clear(built, DARK_CARD_BOTTOM)
		text_scaled(built, CELL_WIDTH * scale, 0, "═", DARK_TEXT, scale)
		_, _, from_demand := text_rendering.glyph(.Cells, DOUBLE, text_rendering.size_of_scale(scale), 0)
		testing.expect_value(t, from_demand, text_rendering.Glyph_Source.Demand_Cache)
		delete(words)
		words = fallback_open_for_test(t, 0)
		clear(drawn, DARK_CARD_BOTTOM)
		text_scaled(drawn, CELL_WIDTH * scale, 0, "═", DARK_TEXT, scale)
		_, _, from_private := text_rendering.glyph(.Cells, DOUBLE, text_rendering.size_of_scale(scale), 0)
		testing.expect_value(t, from_private, text_rendering.Glyph_Source.Private_Cache)
		testing.expectf(t, built_pixels == fallback_pixels, "scale %v: the private cell has the pixels of the demand cache", scale)
		clear(drawn, DARK_CARD_BOTTOM)
		text_scaled(drawn, CELL_WIDTH * scale, 0, "α", DARK_TEXT, scale)
		ink, outside := 0, 0
		for row in 0 ..< HEIGHT {
			for column in 0 ..< WIDTH {
				if fallback_pixels[row * WIDTH + column] == DARK_CARD_BOTTOM {
					continue
				}
				inside := column >= CELL_WIDTH * scale && column < 2 * CELL_WIDTH * scale && row < CELL_HEIGHT * scale
				if inside {
					ink += 1
				} else {
					outside += 1
				}
			}
		}
		testing.expectf(t, ink > 0 && outside == 0, "scale %v: α has %v pixels of ink in its cell and %v outside", scale, ink, outside)
		// A change of the order of the stripes in the same frame: the
		// words do not depend on it, so the glyph is not drawn again.
		drawn_before := text_rendering.counts().drawn
		text_choice_set(.Vector, .Blue_Green_Red)
		clear(drawn, DARK_CARD_BOTTOM)
		text_scaled(drawn, CELL_WIDTH * scale, 0, "α", DARK_TEXT, scale)
		text_choice_set(.Vector, .Red_Green_Blue)
		testing.expectf(t, text_rendering.counts().drawn == drawn_before, "scale %v: a change of the order of the stripes draws no glyph again", scale)
		delete(words)
		words = fallback_open_for_test(t, base)
	}
}
