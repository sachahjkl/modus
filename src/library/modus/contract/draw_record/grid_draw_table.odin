// Terminal grid to draw-record converter (src/md/features/console_renderers.md).
//
// Emits canonical Draw_Record background fill spans (coalescing adjacent cells
// sharing the same non-transparent background color) and Draw_Text glyph runs
// (coalescing adjacent visible glyphs sharing foreground color and weight in
// Font_Kind.Cells_8x16) into caller-owned record and UTF-8 text slices.
// Validates every cell and measures capacity before writing so a refusal
// leaves caller buffers untouched.
package draw_record

// Format property: default Spleen 8x16 monospace cell size in logical pixels.
GRID_CELL_WIDTH_DEFAULT :: i32(8)
GRID_CELL_HEIGHT_DEFAULT :: i32(16)

// Plan value: bounds terminal grid dimensions well inside COORDINATE_LIMIT
// (512 * 128 = 65536 << 8388608).
GRID_MAX_COLUMNS :: 512
GRID_MAX_ROWS :: 256

// Format property: cell height bounds matching TEXT_SIZE_MINIMUM..TEXT_SIZE_LIMIT.
GRID_CELL_HEIGHT_MIN :: i32(TEXT_SIZE_MINIMUM / UNITS_PER_PIXEL)
GRID_CELL_HEIGHT_MAX :: i32(TEXT_SIZE_LIMIT / UNITS_PER_PIXEL)

// Closed refusal set returned by grid_rows_emit_draw_table.
Grid_Emit_Refusal :: enum u8 {
	None                    = 0,
	Invalid_Grid_Size       = 1,
	Invalid_Cell_Size       = 2,
	Origin_Out_Of_Bounds    = 3,
	Cells_Length_Mismatch   = 4,
	Invalid_Color           = 5,
	Invalid_Weight          = 6,
	Invalid_Codepoint       = 7,
	Record_Buffer_Too_Small = 8,
	Text_Buffer_Too_Small   = 9,
}

// One terminal cell in row-major order. codepoint == 0 or ' ' emits no glyph.
Grid_Cell :: struct {
	codepoint:  rune,
	foreground: Draw_Color,
	background: Draw_Color,
	weight:     Font_Weight,
}

// Layout parameters for converting a terminal grid into Draw_Records.
Grid_Emit_Config :: struct {
	origin_x:    i32, // Top-left logical pixel X.
	origin_y:    i32, // Top-left logical pixel Y.
	columns:     int,
	rows:        int,
	cell_width:  i32,
	cell_height: i32,
	element:     u32,
}

// Counts of emitted draw records and UTF-8 bytes written.
Grid_Emit_Result :: struct {
	records_written:    int,
	text_bytes_written: int,
	background_runs:    int,
	text_runs:          int,
}

@(private = "file")
grid_codepoint_valid :: #force_inline proc "contextless" (cp: rune) -> bool {
	if cp == 0 {
		return true
	}
	if cp < 0x20 || cp == 0x7F || cp > 0x10FFFF {
		return false
	}
	if cp >= 0xD800 && cp <= 0xDFFF {
		return false
	}
	return true
}

@(private = "file")
grid_utf8_len :: #force_inline proc "contextless" (cp: rune) -> int {
	if cp < 0x80 {
		return 1
	}
	if cp < 0x800 {
		return 2
	}
	if cp < 0x10000 {
		return 3
	}
	return 4
}

@(private = "file")
grid_utf8_write :: proc "contextless" (dst: []u8, offset: int, cp: rune) -> int {
	v := u32(cp)
	if v < 0x80 {
		dst[offset] = u8(v)
		return 1
	}
	if v < 0x800 {
		dst[offset + 0] = u8(0xC0 | (v >> 6))
		dst[offset + 1] = u8(0x80 | (v & 0x3F))
		return 2
	}
	if v < 0x10000 {
		dst[offset + 0] = u8(0xE0 | (v >> 12))
		dst[offset + 1] = u8(0x80 | ((v >> 6) & 0x3F))
		dst[offset + 2] = u8(0x80 | (v & 0x3F))
		return 3
	}
	dst[offset + 0] = u8(0xF0 | (v >> 18))
	dst[offset + 1] = u8(0x80 | ((v >> 12) & 0x3F))
	dst[offset + 2] = u8(0x80 | ((v >> 6) & 0x3F))
	dst[offset + 3] = u8(0x80 | (v & 0x3F))
	return 4
}

@(private = "file")
grid_cell_has_glyph :: #force_inline proc "contextless" (cell: Grid_Cell) -> bool {
	return cell.codepoint != 0 && cell.codepoint != ' ' && cell.foreground != 0
}

// validate_and_measure_grid validates all inputs and counts the exact number
// of draw records and UTF-8 text bytes required before any write happens.
@(private = "file")
validate_and_measure_grid :: proc "contextless" (
	config: Grid_Emit_Config,
	cells: []Grid_Cell,
) -> (
	needed_records: int,
	needed_text: int,
	refusal: Grid_Emit_Refusal,
) {
	if config.columns <= 0 || config.columns > GRID_MAX_COLUMNS || config.rows <= 0 || config.rows > GRID_MAX_ROWS {
		return 0, 0, .Invalid_Grid_Size
	}
	if config.cell_width <= 0 || config.cell_width > GRID_CELL_HEIGHT_MAX || config.cell_height < GRID_CELL_HEIGHT_MIN || config.cell_height > GRID_CELL_HEIGHT_MAX {
		return 0, 0, .Invalid_Cell_Size
	}
	right_px := i64(config.origin_x) + i64(config.columns) * i64(config.cell_width)
	bottom_px := i64(config.origin_y) + i64(config.rows) * i64(config.cell_height)
	if i64(config.origin_x) < -i64(COORDINATE_LIMIT) || i64(config.origin_y) < -i64(COORDINATE_LIMIT) ||
		right_px > i64(COORDINATE_LIMIT) || bottom_px > i64(COORDINATE_LIMIT) {
		return 0, 0, .Origin_Out_Of_Bounds
	}
	expected_cells := config.columns * config.rows
	if len(cells) != expected_cells {
		return 0, 0, .Cells_Length_Mismatch
	}
	for cell in cells {
		if !color_canonical(cell.foreground) || !color_canonical(cell.background) {
			return 0, 0, .Invalid_Color
		}
		if _, ok := font_weight_of_word(u8(cell.weight)); !ok {
			return 0, 0, .Invalid_Weight
		}
		if !grid_codepoint_valid(cell.codepoint) {
			return 0, 0, .Invalid_Codepoint
		}
	}
	for row in 0 ..< config.rows {
		row_base := row * config.columns
		// Measure coalesced background runs.
		col := 0
		for col < config.columns {
			bg := cells[row_base + col].background
			if bg == 0 {
				col += 1
				continue
			}
			for col < config.columns && cells[row_base + col].background == bg {
				col += 1
			}
			needed_records += 1
		}
		// Measure coalesced visible glyph runs sharing (foreground, weight).
		col = 0
		for col < config.columns {
			c := cells[row_base + col]
			if !grid_cell_has_glyph(c) {
				col += 1
				continue
			}
			fg := c.foreground
			wt := c.weight
			for col < config.columns {
				next := cells[row_base + col]
				if !grid_cell_has_glyph(next) || next.foreground != fg || next.weight != wt {
					break
				}
				needed_text += grid_utf8_len(next.codepoint)
				col += 1
			}
			needed_records += 1
		}
	}
	return needed_records, needed_text, .None
}

// grid_rows_emit_draw_table emits canonical Draw_Rectangle background spans
// (coalescing adjacent matching backgrounds) followed by Draw_Text glyph runs
// (Font_Kind.Cells_8x16) for every row. On refusal, records_out and text_out
// are untouched.
grid_rows_emit_draw_table :: proc "contextless" (
	config: Grid_Emit_Config,
	cells: []Grid_Cell,
	records_out: []Draw_Record,
	text_out: []u8,
) -> (
	result: Grid_Emit_Result,
	refusal: Grid_Emit_Refusal,
) {
	needed_records, needed_text, val_r := validate_and_measure_grid(config, cells)
	if val_r != .None {
		return {}, val_r
	}
	if len(records_out) < needed_records {
		return {}, .Record_Buffer_Too_Small
	}
	if len(text_out) < needed_text {
		return {}, .Text_Buffer_Too_Small
	}

	text_size := u16(config.cell_height * UNITS_PER_PIXEL)
	rec_idx := 0
	text_idx := 0

	for row in 0 ..< config.rows {
		row_base := row * config.columns
		top_px := int(config.origin_y) + row * int(config.cell_height)
		bottom_px := top_px + int(config.cell_height)
		top_u := units_of_pixels(top_px)
		bottom_u := units_of_pixels(bottom_px)

		// Pass 1: coalesced non-transparent background rectangles.
		col := 0
		for col < config.columns {
			bg := cells[row_base + col].background
			if bg == 0 {
				col += 1
				continue
			}
			start_col := col
			for col < config.columns && cells[row_base + col].background == bg {
				col += 1
			}
			left_u := units_of_pixels(int(config.origin_x) + start_col * int(config.cell_width))
			right_u := units_of_pixels(int(config.origin_x) + col * int(config.cell_width))
			records_out[rec_idx] = record_of(Draw_Rectangle{color = bg}, config.element, left_u, top_u, right_u, bottom_u)
			rec_idx += 1
			result.background_runs += 1
		}

		// Pass 2: coalesced visible glyph runs sharing (foreground, weight).
		col = 0
		for col < config.columns {
			first_cell := cells[row_base + col]
			if !grid_cell_has_glyph(first_cell) {
				col += 1
				continue
			}
			start_col := col
			fg := first_cell.foreground
			wt := first_cell.weight
			text_start := text_idx
			for col < config.columns {
				c := cells[row_base + col]
				if !grid_cell_has_glyph(c) || c.foreground != fg || c.weight != wt {
					break
				}
				text_idx += grid_utf8_write(text_out, text_idx, c.codepoint)
				col += 1
			}
			left_u := units_of_pixels(int(config.origin_x) + start_col * int(config.cell_width))
			right_u := units_of_pixels(int(config.origin_x) + col * int(config.cell_width))
			prim := Draw_Text {
				first    = u32(text_start),
				count    = u32(text_idx - text_start),
				color    = fg,
				origin_x = left_u,
				font     = .Cells_8x16,
				weight   = wt,
				size     = text_size,
			}
			records_out[rec_idx] = record_of(prim, config.element, left_u, top_u, right_u, bottom_u)
			rec_idx += 1
			result.text_runs += 1
		}
	}

	result.records_written = rec_idx
	result.text_bytes_written = text_idx
	return result, .None
}
