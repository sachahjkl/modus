package bootscreen

import "modus:contract/glyph_cache"
import "modus:contract/text_encoding"
import "modus:support/graphics"
import "modus:support/vector_font"

// The text of the boot display in cells that no glyph cache holds
// (src/md/features/boot_display_scale.md, "The text"): a scale of eighths
// makes cells of 10 x 20 to 15 x 30 pixels, and the glyph caches have 8,
// 16 and 24 pixels only. A drawer that holds the font outlines gives the
// font file of the cells and memory: each glyph is drawn from its outline
// at its first use, with the renderer that built the glyph caches, and the
// rows of its ink are kept until the scale changes. With no font, a cell
// draws the largest whole scale of the caches inside it, in its middle.

// The two cells of one scale: the text, and the large digits.
SCALED_CELL_TABLES :: 2
// The words of the glyphs that the memory keeps: 128 KiB. One display
// draws about 80 characters of the text and 15 of the large digits; a
// full memory empties and starts again.
SCALED_GLYPH_WORD_CAPACITY :: 1 << 15
#assert(SCALED_GLYPH_WORD_CAPACITY >= vector_font.CELL_WIDTH_LIMIT * vector_font.CELL_HEIGHT_LIMIT)

// The state of the glyph of one character in one cell.
Scaled_Glyph_State :: enum u8 {
	Not_Drawn, // Not used at this cell yet.
	Drawn, // Its rows of ink are in the words.
	Refused, // The renderer refused its outline: the cell draws the whole scale below.
}

// One glyph of the memory: the rows of its ink, as an entry of a glyph cache.
Scaled_Glyph :: struct {
	state:       Scaled_Glyph_State,
	first_row:   u16, // The first row with ink, from the top of the cell.
	row_count:   u16, // 0: no ink, a space.
	word_offset: u32, // The first word of row first_row, in the words.
}

// The memory of the glyphs, which the drawer that gives a font owns.
Scaled_Glyph_Memory :: struct {
	render:      vector_font.Render_Memory, // The work of the renderer on one glyph.
	cell:        [vector_font.CELL_WIDTH_LIMIT * vector_font.CELL_HEIGHT_LIMIT]u32, // One whole cell, before its rows of ink are kept.
	cell_widths: [SCALED_CELL_TABLES]int, // The cell width of each table of glyphs; 0: a free table.
	glyphs:      [SCALED_CELL_TABLES][glyph_cache.CHARACTER_COUNT]Scaled_Glyph, // By character index.
	words:       [SCALED_GLYPH_WORD_CAPACITY]u32,
	word_count:  int, // The words in use.
	drawn_count: u64, // The glyphs that the renderer drew since the font was given: the measure reads it.
}

// The font of the cells that the drawer gave, opened once.
@(private)
Cell_Font :: struct {
	memory:   ^Scaled_Glyph_Memory, // nil: no font.
	file:     vector_font.Font_File,
	measures: vector_font.Font_Measures,
}

@(private)
cell_font: Cell_Font

// cell_font_use gives the display the font file of the cells (the font
// whose hash the glyph cache of the cells names) and the memory of its
// glyphs. A font that the reader refuses, or that is not monospace, leaves
// the display with the whole scales; the problem is for the log of the
// caller. A nil memory refuses the font, with Too_Many_Points: no glyph has
// room.
cell_font_use :: proc "contextless" (font_bytes: []u8, memory: ^Scaled_Glyph_Memory) -> vector_font.Font_Problem {
	cell_font = {}
	if memory == nil {
		return .Too_Many_Points
	}
	file, problem := vector_font.font_open(font_bytes)
	if problem != .None {
		return problem
	}
	measures: vector_font.Font_Measures
	measures, problem = vector_font.font_measures(&file, &memory.render)
	if problem != .None {
		return problem
	}
	if !measures.monospace {
		// A cell holds one advance: a proportional font passes its cells.
		return .Unknown_Format
	}
	scaled_glyphs_empty(memory)
	memory.drawn_count = 0
	cell_font = {memory = memory, file = file, measures = measures}
	if graphics.text_state.square_root[len(graphics.text_state.square_root) - 1] == 0 {
		graphics.text_state_start()
	}
	return .None
}

// scaled_glyphs_empty forgets every glyph of the memory.
@(private)
scaled_glyphs_empty :: proc "contextless" (memory: ^Scaled_Glyph_Memory) {
	memory.cell_widths = {}
	memory.glyphs = {}
	memory.word_count = 0
}

// scaled_glyph_of gives the glyph of a character in a cell of cell_width
// x 2 cell_width pixels, and draws it at its first use. ok is false with
// no font, for a cell past the largest cell of the renderer, and for an
// outline that the renderer refused.
@(private)
scaled_glyph_of :: proc "contextless" (character_index: int, character: rune, cell_width: int) -> (glyph: Scaled_Glyph, ok: bool) {
	memory := cell_font.memory
	cell_height := 2 * cell_width
	if memory == nil || cell_width < 1 || cell_width > vector_font.CELL_WIDTH_LIMIT || cell_height > vector_font.CELL_HEIGHT_LIMIT || character_index < 0 || character_index >= glyph_cache.CHARACTER_COUNT {
		return {}, false
	}
	table := -1
	for width, index in memory.cell_widths {
		if width == cell_width {
			table = index
			break
		}
	}
	if table < 0 {
		for width, index in memory.cell_widths {
			if width == 0 {
				table = index
				break
			}
		}
		if table < 0 {
			// A third cell: the scale changed. The glyphs of the old scale go.
			scaled_glyphs_empty(memory)
			table = 0
		}
		memory.cell_widths[table] = cell_width
	}
	switch memory.glyphs[table][character_index].state {
	case .Drawn:
		return memory.glyphs[table][character_index], true
	case .Refused:
		return {}, false
	case .Not_Drawn:
	}
	style := vector_font.glyph_style_of(cell_font.measures, cell_width, cell_height, true)
	pixels := memory.cell[:cell_width * cell_height]
	memory.drawn_count += 1
	if vector_font.glyph_render(&cell_font.file, cell_font.measures, style, character, &memory.render, pixels) != .None {
		memory.glyphs[table][character_index].state = .Refused
		return {}, false
	}
	first, last := cell_height, -1
	for row in 0 ..< cell_height {
		for word in pixels[row * cell_width:][:cell_width] {
			if word != 0 {
				first = min(first, row)
				last = max(last, row)
				break
			}
		}
	}
	if last < first {
		memory.glyphs[table][character_index] = {state = .Drawn}
		return memory.glyphs[table][character_index], true
	}
	count := (last - first + 1) * cell_width
	if memory.word_count + count > SCALED_GLYPH_WORD_CAPACITY {
		scaled_glyphs_empty(memory)
		table = 0
		memory.cell_widths[table] = cell_width
	}
	copy(memory.words[memory.word_count:][:count], pixels[first * cell_width:][:count])
	memory.glyphs[table][character_index] = {state = .Drawn, first_row = u16(first), row_count = u16(last - first + 1), word_offset = u32(memory.word_count)}
	memory.word_count += count
	return memory.glyphs[table][character_index], true
}

// scaled_glyph_draw blends one glyph of the memory into the cell at (x, y)
// of a canvas, cut to the canvas, as a glyph of a glyph cache is blended,
// with the stripes in the order of the screen.
@(private)
scaled_glyph_draw :: proc "contextless" (canvas: graphics.Canvas, x, y: int, glyph: Scaled_Glyph, cell_width: int, color: graphics.Color, order: graphics.Subpixel_Order) {
	if glyph.row_count == 0 || cell_font.memory == nil {
		return
	}
	top := y + int(glyph.first_row)
	first_column := max(0, -x)
	last_column := min(cell_width, canvas.width - x)
	first_row := max(0, -top)
	last_row := min(int(glyph.row_count), canvas.height - top)
	if first_column >= last_column || first_row >= last_row {
		return
	}
	words := raw_data(cell_font.memory.words[glyph.word_offset:])
	graphics.blend_glyph_rows(canvas.pixels[top * canvas.stride + x:], canvas.stride, words, cell_width, first_row, last_row, first_column, last_column, color, order, &graphics.text_state.square_root, &graphics.text_state.blend_tables)
}

// The largest whole scale of the glyph caches and of Spleen.
@(private)
WHOLE_SCALE_MOST :: 3

// cells_draw draws characters in cells of cell_width x 2 cell_width screen
// pixels from (x, y). A cell of a whole scale of the caches draws from the
// glyph cache, or from Spleen, as each text of the system. Another cell
// draws from the outlines when the drawer gave the font, else the largest
// whole scale inside the cell, in its middle: the text is never larger
// than its cells. The color is in the order of the canvas.
@(private)
cells_draw :: proc "contextless" (canvas: graphics.Canvas, x, y: int, characters: string, color: graphics.Color, cell_width: int) {
	order := graphics.text_state.order
	screen_order := stripes_of_screen(order)
	graphics.text_state.order = screen_order
	defer graphics.text_state.order = order
	whole := cell_width / graphics.CELL_WIDTH
	if cell_width % graphics.CELL_WIDTH == 0 && whole >= 1 && whole <= WHOLE_SCALE_MOST {
		graphics.text_scaled(canvas, x, y, characters, color, whole)
		return
	}
	lower := clamp(whole, 1, WHOLE_SCALE_MOST)
	inset_x := max((cell_width - lower * graphics.CELL_WIDTH) / 2, 0)
	inset_y := max((2 * cell_width - lower * graphics.CELL_HEIGHT) / 2, 0)
	bytes := transmute([]u8)characters
	at, place := x, 0
	for place < len(bytes) {
		character, length, _ := text_encoding.character_decode(bytes, place)
		if at < canvas.width && at + cell_width > 0 {
			drawn := false
			if index, in_cells := glyph_cache.character_index(character); in_cells {
				if glyph, ok := scaled_glyph_of(index, character, cell_width); ok {
					scaled_glyph_draw(canvas, at, y, glyph, cell_width, color, screen_order)
					drawn = true
				}
			}
			if !drawn {
				graphics.text_scaled(canvas, at + inset_x, y + inset_y, characters[place:][:length], color, lower)
			}
		}
		place += length
		at += cell_width
	}
}
