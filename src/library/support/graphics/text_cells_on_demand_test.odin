#+build !freestanding
package graphics

import "core:mem"
import "core:testing"
import "modus:contract/demand_cache"
import "modus:contract/glyph_cache"
import "modus:support/vector_font"

// A cell past the glyph cache draws its glyph from the face of the demand
// cache, with the blend of each cell: the glyph of 'A' that the font
// service drew and published as U+2500 gives the pixels of 'A' from the
// glyph cache of cells of the same font file, at each scale, and stays in
// its cell. A frame that does not see the entry, a program with no face,
// and the setting Spleen draw the replacement glyph.
@(test)
a_cell_on_demand_draws_the_pixels_of_the_glyph_cache :: proc(t: ^testing.T) {
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
	reader, matches := demand_cache.reader_of(base, .Cells, &cache)
	testing.expect(t, matches)
	BOX :: rune(0x2500)
	entry, result := vector_font.demand_glyph_draw(&demand_font, &writer, 'A', render)
	testing.expect_value(t, result, vector_font.Demand_Result.Drawn)
	place, _ := demand_cache.place_find(&writer, .Cells, BOX)
	demand_cache.publish(&writer, place, .Cells, BOX, entry)
	demand_cache.reader_frame_begin(&reader)

	saved := text_state
	defer text_state = saved
	testing.expect_value(t, text_cache_use(cache).kind, glyph_cache.Problem_Kind.None)
	text_choice_set(.Vector, .Red_Green_Blue)
	text_demand_use(&reader, nil)

	WIDTH :: 3 * CELL_WIDTH * 3
	HEIGHT :: CELL_HEIGHT * 3
	built_pixels, demand_pixels: [WIDTH * HEIGHT]Color
	built := Canvas{pixels = raw_data(built_pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
	drawn := Canvas{pixels = raw_data(demand_pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
	for scale in 1 ..= 3 {
		clear(built, DARK_CARD_BOTTOM)
		clear(drawn, DARK_CARD_BOTTOM)
		text_scaled(built, CELL_WIDTH * scale, 0, "A", DARK_TEXT, scale)
		text_scaled(drawn, CELL_WIDTH * scale, 0, "─", DARK_TEXT, scale)
		testing.expectf(t, built_pixels == demand_pixels, "scale %v: the cell on demand has the pixels of the glyph cache", scale)
		// The ink of the cell stays in its cell: the two cells beside it
		// keep the background.
		outside := 0
		for row in 0 ..< CELL_HEIGHT * scale {
			for column in 0 ..< WIDTH {
				inside := column >= CELL_WIDTH * scale && column < 2 * CELL_WIDTH * scale
				if !inside && demand_pixels[row * WIDTH + column] != DARK_CARD_BOTTOM {
					outside += 1
				}
			}
		}
		testing.expectf(t, outside == 0, "scale %v: %v pixels of ink are outside the cell", scale, outside)
	}
	// One character at scale 1, as `character` draws it.
	clear(built, DARK_CARD_BOTTOM)
	clear(drawn, DARK_CARD_BOTTOM)
	character(built, CELL_WIDTH, 0, 'A', DARK_TEXT)
	character(drawn, CELL_WIDTH, 0, BOX, DARK_TEXT)
	testing.expect(t, built_pixels == demand_pixels)

	// The replacement glyph: a frame before the publication, no face, and
	// the setting Spleen.
	Case :: enum {
		Frame_Before_The_Publication,
		No_Face,
		Spleen,
	}
	for each in Case {
		text_choice_set(.Vector, .Red_Green_Blue)
		text_demand_use(&reader, nil)
		demand_cache.reader_frame_begin(&reader)
		switch each {
		case .Frame_Before_The_Publication:
			reader.generation_limit = 0
		case .No_Face:
			text_demand_use(nil, nil)
		case .Spleen:
			text_choice_set(.Spleen, .Red_Green_Blue)
		}
		clear(built, DARK_CARD_BOTTOM)
		clear(drawn, DARK_CARD_BOTTOM)
		character_replacement(built, CELL_WIDTH, 0, DARK_TEXT, 1)
		text_scaled(drawn, CELL_WIDTH, 0, "─", DARK_TEXT, 1)
		testing.expectf(t, built_pixels == demand_pixels, "%v: the replacement glyph", each)
	}
}
