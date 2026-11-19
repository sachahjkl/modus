package resources

import "core:fmt"
import "core:os"
import "modus:contract/glyph_cache"
import "modus:support/graphics"
import "modustool:foundation"

// The picture of the choice of the font (docs/FONTS.md, "The font file"):
// the same lines of the system in each candidate and in Spleen, at the
// scales 1, 2 and 3, then one word of each enlarged 5 times so that the
// pixels and the color stripes show. src/library/support/graphics draws it
// with the blend of the system, each candidate from a glyph cache that the
// renderer of the system draws from its font file.

CANDIDATE_LINES := [?]string {
	"> print(monitor.processes())   31 processes, 4 processors, 1 204 pages",
	"compositor     12.4 ms    2 418 pages   runs   0x4F3A..9C21",
	"KERNEL ENTRIES  Boot_Report.stages   ok: {fill} [rings] gi Rb 0O 1lI",
}

PICTURE_WIDTH :: 1296
BLOCK_WIDTH :: 640
BLOCK_HEIGHT :: 216
CROP_SCALE :: 5
CROP_TEXT :: "Rag{0}%"

Picture_Font :: struct {
	label:    string,
	cache:    []u8, // nil: Spleen.
	grid_fit: bool,
}

// The cache of the font that picture_text draws from, validated by
// picture_font_use; none: Spleen.
@(private = "file")
picture_cache: glyph_cache.Cache
@(private = "file")
picture_cache_valid: bool

// picture_text draws a text in cells of 8 x 16 pixels times the scale, in
// the font of picture_font_use: from its cache, with the fast blend of the
// system, or in Spleen.
@(private = "file")
picture_text :: proc(canvas: graphics.Canvas, x, y: int, text: string, color: graphics.Color, scale: int = 1) {
	if !picture_cache_valid {
		graphics.text_scaled(canvas, x, y, text, color, scale)
		return
	}
	state := &graphics.text_state
	cell := 0
	for character in text {
		graphics.character_vector_with(&picture_cache, &state.square_root, &state.blend_tables, state.order, canvas, x + cell * graphics.CELL_WIDTH * scale, y, character, color, scale)
		cell += 1
	}
}

candidates_picture_write :: proc() -> bool {
	fonts := make([dynamic]Picture_Font, context.temp_allocator)
	append(&fonts, Picture_Font{label = "Spleen 8x16 (bitmap, the fallback)"})
	for candidate in vector_font_candidates {
		path := foundation.join(VECTOR_FONT_FOLDER, "/", candidate.name, ".ttf")
		bytes := foundation.read_file(path) or_return
		cache := glyph_cache_of(bytes, candidate.name, true) or_return
		label := fmt.tprintf("%s%s", candidate.family, candidate.name == DEFAULT_VECTOR_FONT ? " (default)" : "")
		append(&fonts, Picture_Font{label = label, cache = cache, grid_fit = true})
		if candidate.name == DEFAULT_VECTOR_FONT {
			no_fit := glyph_cache_of(bytes, candidate.name, false) or_return
			append(&fonts, Picture_Font{label = fmt.tprintf("%s, no grid fit", candidate.family), cache = no_fit})
		}
	}
	rows := (len(fonts) + 1) / 2
	crop_rows := (len(fonts) + 3) / 4
	crop_height := 16 * CROP_SCALE + 24
	height := 8 + rows * BLOCK_HEIGHT + crop_rows * crop_height + 8
	pixels := make([]graphics.Color, PICTURE_WIDTH * height, context.temp_allocator)
	canvas := graphics.Canvas{pixels = raw_data(pixels), width = PICTURE_WIDTH, height = height, stride = PICTURE_WIDTH}
	graphics.clear(canvas, graphics.DARK_BACKGROUND)
	saved := graphics.text_state
	defer graphics.text_state = saved
	for font, index in fonts {
		picture_font_use(font)
		x := 8 + (index % 2) * (BLOCK_WIDTH + 8)
		y := 8 + (index / 2) * BLOCK_HEIGHT
		graphics.block(canvas, x, y, BLOCK_WIDTH, BLOCK_HEIGHT - 8, graphics.DARK_CARD_TOP, graphics.DARK_CARD_BOTTOM)
		graphics.fill(canvas, x + 16, y + 12, 4, 16, graphics.DARK_MACHINE)
		picture_text(canvas, x + 28, y + 12, font.label, graphics.DARK_MACHINE)
		line_y := y + 40
		for line, line_index in CANDIDATE_LINES {
			color := graphics.Color(line_index == 2 ? graphics.DARK_KERNEL : graphics.DARK_TEXT)
			picture_text(canvas, x + 16, line_y, line, color)
			line_y += 16
		}
		picture_text(canvas, x + 16, line_y + 8, "EEVDF fair 1.5x", graphics.DARK_PROCESS, 2)
		picture_text(canvas, x + 16, line_y + 48, "12 345", graphics.DARK_TEXT, 3)
		picture_text(canvas, x + 176, line_y + 72, "wakes in one second", graphics.DARK_DIM)
	}
	// The crops: one word at scale 1, each pixel as a square of CROP_SCALE.
	crop_top := 8 + rows * BLOCK_HEIGHT
	for font, index in fonts {
		picture_font_use(font)
		small: [8 * len(CROP_TEXT) * 16]graphics.Color
		small_canvas := graphics.Canvas{pixels = raw_data(small[:]), width = 8 * len(CROP_TEXT), height = 16, stride = 8 * len(CROP_TEXT)}
		graphics.clear(small_canvas, graphics.DARK_CARD_BOTTOM)
		picture_text(small_canvas, 0, 0, CROP_TEXT, graphics.DARK_TEXT)
		x := 8 + (index % 4) * 320
		y := crop_top + (index / 4) * crop_height
		picture_text(canvas, x, y, font.label[:min(len(font.label), 38)], graphics.DARK_DIM)
		for row in 0 ..< 16 {
			for column in 0 ..< small_canvas.width {
				graphics.fill(canvas, x + column * CROP_SCALE, y + 20 + row * CROP_SCALE, CROP_SCALE, CROP_SCALE, small[row * small_canvas.width + column])
			}
		}
	}
	picture_font_use({})
	rgb := make([]u8, 3 * len(pixels), context.temp_allocator)
	for color, index in pixels {
		rgb[3 * index] = u8(color >> 16)
		rgb[3 * index + 1] = u8(color >> 8)
		rgb[3 * index + 2] = u8(color)
	}
	file, encode_error := png_encode(PICTURE_WIDTH, height, 3, rgb)
	if encode_error != nil {
		fmt.eprintfln("modustool: cannot encode %s: %v", CANDIDATES_PICTURE, encode_error)
		return false
	}
	if write_error := os.write_entire_file(CANDIDATES_PICTURE, file); write_error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", CANDIDATES_PICTURE, write_error)
		return false
	}
	return true
}

@(private = "file")
picture_font_use :: proc(font: Picture_Font) {
	graphics.text_choice_set(.Spleen, .Red_Green_Blue)
	graphics.text_state_start()
	picture_cache_valid = false
	if font.cache == nil {
		return
	}
	problem: glyph_cache.Problem
	picture_cache, problem = glyph_cache.validate(font.cache)
	if problem.kind != .None {
		fmt.eprintfln("modustool: a glyph cache of the picture is refused: %v", problem)
		return
	}
	picture_cache_valid = true
}
