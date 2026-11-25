#+build !freestanding
package draw_record

import "core:testing"

@(test)
grid_rows_emit_draw_table_coalesces_spans_and_passes_record_border :: proc(t: ^testing.T) {
	cfg := Grid_Emit_Config {
		origin_x    = 16,
		origin_y    = 32,
		columns     = 6,
		rows        = 2,
		cell_width  = GRID_CELL_WIDTH_DEFAULT,
		cell_height = GRID_CELL_HEIGHT_DEFAULT,
		element     = 7,
	}
	bg_dark := opaque(0x101820)
	bg_hi := opaque(0x203040)
	fg_white := opaque(0xFFFFFF)
	fg_cyan := opaque(0x44CCFF)

	// Row 0: "hi" (cyan, bg_dark) + "  " (bg_dark) + "ok" (white bold, bg_hi) ->
	//   2 background spans (4 cells bg_dark, 2 cells bg_hi) + 2 text runs ("hi", "ok").
	// Row 1: transparent background, "é" (2-byte UTF-8) + 5 spaces -> 0 bg spans + 1 text run.
	cells := [12]Grid_Cell{
		// Row 0
		{codepoint = 'h', foreground = fg_cyan, background = bg_dark, weight = .Regular},
		{codepoint = 'i', foreground = fg_cyan, background = bg_dark, weight = .Regular},
		{codepoint = ' ', foreground = fg_cyan, background = bg_dark, weight = .Regular},
		{codepoint = ' ', foreground = fg_cyan, background = bg_dark, weight = .Regular},
		{codepoint = 'o', foreground = fg_white, background = bg_hi, weight = .Bold},
		{codepoint = 'k', foreground = fg_white, background = bg_hi, weight = .Bold},
		// Row 1
		{codepoint = 'é', foreground = fg_white, background = 0, weight = .Regular},
		{codepoint = ' ', foreground = fg_white, background = 0, weight = .Regular},
		{codepoint = ' ', foreground = fg_white, background = 0, weight = .Regular},
		{codepoint = ' ', foreground = fg_white, background = 0, weight = .Regular},
		{codepoint = ' ', foreground = fg_white, background = 0, weight = .Regular},
		{codepoint = ' ', foreground = fg_white, background = 0, weight = .Regular},
	}

	records: [16]Draw_Record
	text_buf: [64]u8

	res, r := grid_rows_emit_draw_table(cfg, cells[:], records[:], text_buf[:])
	testing.expect_value(t, r, Grid_Emit_Refusal.None)
	testing.expect_value(t, res.background_runs, 2)
	testing.expect_value(t, res.text_runs, 3)
	testing.expect_value(t, res.records_written, 5)
	testing.expect_value(t, string(text_buf[:res.text_bytes_written]), "hioké")

	// Every emitted Draw_Record must pass draw_record.read with Problem.None!
	for index in 0 ..< res.records_written {
		_, prob := read(records[index])
		testing.expect_value(t, prob, Problem.None)
		testing.expect_value(t, records[index].element, u32(7))
	}

	// Verify first background span covers columns 0..4 (4 * 8 = 32 px wide).
	testing.expect_value(t, records[0].left, units_of_pixels(16))
	testing.expect_value(t, records[0].right, units_of_pixels(16 + 32))
	testing.expect_value(t, records[0].top, units_of_pixels(32))
	testing.expect_value(t, records[0].bottom, units_of_pixels(48))
}

@(test)
grid_rows_emit_draw_table_refuses_bad_inputs_without_writing :: proc(t: ^testing.T) {
	cfg := Grid_Emit_Config {
		origin_x    = 0,
		origin_y    = 0,
		columns     = 2,
		rows        = 1,
		cell_width  = 8,
		cell_height = 16,
	}
	cells := [2]Grid_Cell{
		{codepoint = 'A', foreground = opaque(0xFFFFFF), background = opaque(0x111111)},
		{codepoint = 'B', foreground = opaque(0xFFFFFF), background = opaque(0x111111)},
	}
	records: [4]Draw_Record
	text_buf: [8]u8

	// Invalid grid size & cell size.
	bad_cfg := cfg
	bad_cfg.columns = 0
	_, r := grid_rows_emit_draw_table(bad_cfg, cells[:], records[:], text_buf[:])
	testing.expect_value(t, r, Grid_Emit_Refusal.Invalid_Grid_Size)
	bad_cfg = cfg
	bad_cfg.cell_height = GRID_CELL_HEIGHT_MIN - 1
	_, r = grid_rows_emit_draw_table(bad_cfg, cells[:], records[:], text_buf[:])
	testing.expect_value(t, r, Grid_Emit_Refusal.Invalid_Cell_Size)

	// Cells length mismatch.
	_, r = grid_rows_emit_draw_table(cfg, cells[:1], records[:], text_buf[:])
	testing.expect_value(t, r, Grid_Emit_Refusal.Cells_Length_Mismatch)

	// Non-canonical transparent color (alpha 0 with non-zero RGB).
	bad_cells := cells
	bad_cells[0].foreground = Draw_Color(0x00123456)
	_, r = grid_rows_emit_draw_table(cfg, bad_cells[:], records[:], text_buf[:])
	testing.expect_value(t, r, Grid_Emit_Refusal.Invalid_Color)

	// Unknown weight enum word.
	bad_cells = cells
	bad_cells[0].weight = Font_Weight(9)
	_, r = grid_rows_emit_draw_table(cfg, bad_cells[:], records[:], text_buf[:])
	testing.expect_value(t, r, Grid_Emit_Refusal.Invalid_Weight)

	// Control character and surrogate codepoints refused.
	bad_cells = cells
	bad_cells[0].codepoint = 0x1B
	_, r = grid_rows_emit_draw_table(cfg, bad_cells[:], records[:], text_buf[:])
	testing.expect_value(t, r, Grid_Emit_Refusal.Invalid_Codepoint)
	bad_cells[0].codepoint = 0xD800
	_, r = grid_rows_emit_draw_table(cfg, bad_cells[:], records[:], text_buf[:])
	testing.expect_value(t, r, Grid_Emit_Refusal.Invalid_Codepoint)

	// Short record buffer and short text buffer leave buffers untouched.
	text_buf[0] = 0xCC
	_, r = grid_rows_emit_draw_table(cfg, cells[:], records[:1], text_buf[:])
	testing.expect_value(t, r, Grid_Emit_Refusal.Record_Buffer_Too_Small)
	testing.expect_value(t, text_buf[0], u8(0xCC))
	_, r = grid_rows_emit_draw_table(cfg, cells[:], records[:], text_buf[:1])
	testing.expect_value(t, r, Grid_Emit_Refusal.Text_Buffer_Too_Small)
	testing.expect_value(t, text_buf[0], u8(0xCC))
}
