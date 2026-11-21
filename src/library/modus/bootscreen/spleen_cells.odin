package bootscreen

import "modus:contract/font_characters"
import "modus:contract/text_encoding"
import "modus:graphics"

// The text of the boot display (src/md/features/boot_display_scale.md,
// "The text"): Spleen only, in each drawer, as the console of Linux takes a
// size of its font by the resolution. The scale of the display is the
// width of a size of Spleen (scale.odin), so a cell of the text is a cell
// of the font. A cell of the large digits, twice as wide, is a size of the
// font too, or 8x16 drawn at a whole factor. The tables of 12x24, 16x32
// and 32x64 are spleen_sizes.odin, which the command "font" of the tool
// writes from the files of the font; 8x16 is graphics.font.

// The sizes of Spleen that the boot display draws.
Spleen_Size :: enum u8 {
	Cells_8x16, // graphics.font.
	Cells_12x24, // spleen_12x24.
	Cells_16x32, // spleen_16x32.
	Cells_32x64, // spleen_32x64.
}

// The width of the cell of each size: the height is twice the width.
@(rodata)
spleen_size_widths := [Spleen_Size]int {
	.Cells_8x16  = graphics.CELL_WIDTH,
	.Cells_12x24 = SPLEEN_12X24_WIDTH,
	.Cells_16x32 = SPLEEN_16X32_WIDTH,
	.Cells_32x64 = SPLEEN_32X64_WIDTH,
}

// How one cell is drawn: a size, each of its pixels a square of factor
// screen pixels.
Spleen_Form :: struct {
	size:   Spleen_Size,
	factor: int,
}

// spleen_form_of gives the form of a cell of cell_width x 2 cell_width
// pixels: the size whose cell it is, else 8x16 at the whole factor that
// fills it. ok is false for a cell that neither fills exactly: the scales
// of the display give none, and a draw of such a cell draws nothing.
spleen_form_of :: proc "contextless" (cell_width: int) -> (form: Spleen_Form, ok: bool) {
	for width, size in spleen_size_widths {
		if width == cell_width {
			return {size = size, factor = 1}, true
		}
	}
	if cell_width > graphics.CELL_WIDTH && cell_width % graphics.CELL_WIDTH == 0 {
		return {size = .Cells_8x16, factor = cell_width / graphics.CELL_WIDTH}, true
	}
	return {}, false
}

// spleen_text_draw draws characters in cells of cell_width x 2 cell_width
// screen pixels from (x, y), cut to the canvas, in a color in the order of
// the canvas. A character that the font lacks, and an invalid sequence,
// draw the replacement glyph that fills the cell.
@(private)
spleen_text_draw :: proc "contextless" (canvas: graphics.Canvas, x, y: int, characters: string, color: graphics.Color, cell_width: int) {
	form, ok := spleen_form_of(cell_width)
	if !ok {
		return
	}
	bytes := transmute([]u8)characters
	at, place := x, 0
	for place < len(bytes) {
		character, length, _ := text_encoding.character_decode(bytes, place)
		if at < canvas.width && at + cell_width > 0 {
			spleen_character_draw(canvas, at, y, character, color, form)
		}
		place += length
		at += cell_width
	}
}

// spleen_character_draw draws one character in the cell at (x, y).
@(private)
spleen_character_draw :: proc "contextless" (canvas: graphics.Canvas, x, y: int, character: rune, color: graphics.Color, form: Spleen_Form) {
	index, found := font_characters.character_index(character)
	if !found {
		// The box of the replacement glyph is drawn on the grid of 8x16.
		graphics.character_replacement(canvas, x, y, color, spleen_size_widths[form.size] / graphics.CELL_WIDTH * form.factor)
		return
	}
	switch form.size {
	case .Cells_8x16:
		if form.factor == 1 {
			graphics.character_spleen(canvas, x, y, character, color)
		} else {
			graphics.character_spleen_enlarged(canvas, x, y, character, color, form.factor)
		}
	case .Cells_12x24:
		spleen_rows_draw(canvas, x, y, spleen_12x24[index][:], SPLEEN_12X24_WIDTH, color)
	case .Cells_16x32:
		spleen_rows_draw(canvas, x, y, spleen_16x32[index][:], SPLEEN_16X32_WIDTH, color)
	case .Cells_32x64:
		spleen_wide_rows_draw(canvas, x, y, spleen_32x64[index][:], SPLEEN_32X64_WIDTH, color)
	}
}

// spleen_rows_draw paints the pixels of the rows of one glyph of 16 bits:
// bit 15 of a row is its left pixel.
@(private)
spleen_rows_draw :: proc "contextless" (canvas: graphics.Canvas, x, y: int, rows: []u16, width: int, color: graphics.Color) {
	for bits, row in rows {
		line := y + row
		if line < 0 || line >= canvas.height || bits == 0 {
			continue
		}
		for column in 0 ..< width {
			pixel_x := x + column
			if bits << uint(column) & 0x8000 != 0 && pixel_x >= 0 && pixel_x < canvas.width {
				canvas.pixels[line * canvas.stride + pixel_x] = color
			}
		}
	}
}

// spleen_wide_rows_draw paints the pixels of the rows of one glyph of 32
// bits: bit 31 of a row is its left pixel.
@(private)
spleen_wide_rows_draw :: proc "contextless" (canvas: graphics.Canvas, x, y: int, rows: []u32, width: int, color: graphics.Color) {
	for bits, row in rows {
		line := y + row
		if line < 0 || line >= canvas.height || bits == 0 {
			continue
		}
		for column in 0 ..< width {
			pixel_x := x + column
			if bits << uint(column) & 0x8000_0000 != 0 && pixel_x >= 0 && pixel_x < canvas.width {
				canvas.pixels[line * canvas.stride + pixel_x] = color
			}
		}
	}
}
