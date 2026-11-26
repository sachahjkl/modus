#+build !freestanding
#+build !modus
package interface

import "core:fmt"
import "core:testing"
import "core:time"
import "modus:contract/text_encoding"
import "modus:graphics"

// The text grid measured against text runs (src/md/api/draw_table.md,
// "The text grid: the measure that decides"): compares Text_Grid against
// equivalent Text and Rectangle runs on the 104 by 32 terminal frames and
// on a full 1920 by 1080 terminal grid (240 by 67 cells).
//
// Normal test runs verify pixel-for-pixel equality (whole canvas, four
// damage rectangles, and incremental single-cell damage) and exact record
// and byte-table counts. Passing -define:MEASURE=true prints the timed
// build, difference, and draw measures in microseconds without asserting
// any duration or rate.

@(private = "file")
TEXT_GRID_MEASURE_ENABLED :: #config(MEASURE, false)

@(private = "file")
TEXT_GRID_MEASURE_ROUNDS_SMALL :: 100

@(private = "file")
TEXT_GRID_MEASURE_ROUNDS_LARGE :: 40

@(private = "file")
FULL_HD_WIDTH :: 1920

@(private = "file")
FULL_HD_HEIGHT :: 1080

@(private = "file")
FULL_HD_COLUMNS :: FULL_HD_WIDTH / 8 // 240 cells at 8x16 body font.

@(private = "file")
FULL_HD_ROWS :: FULL_HD_HEIGHT / 16 // 67 rows (1072 pixels inside 1080).

@(private = "file")
TERMINAL_COLUMNS :: 104

@(private = "file")
TERMINAL_ROWS :: 32

@(private = "file")
GRID_WORKLOAD_RECORD_CAPACITY :: FULL_HD_COLUMNS * FULL_HD_ROWS * 2 + 64

@(private = "file")
GRID_WORKLOAD_TEXT_CAPACITY :: FULL_HD_COLUMNS * FULL_HD_ROWS * size_of(Text_Grid_Cell) + 4096

@(private = "file")
Grid_Workload :: enum {
	Plain_104x32,
	Colored_Code_104x32,
	Per_Cell_Color_104x32,
	Per_Cell_Filled_104x32,
	Full_1920x1080_Terminal,
}

@(private = "file")
Grid_Spec :: struct {
	name:    string,
	columns: int,
	rows:    int,
	width:   int,
	height:  int,
	rounds:  int,
}

@(private = "file")
workload_spec :: proc(kind: Grid_Workload) -> Grid_Spec {
	switch kind {
	case .Plain_104x32:
		return {"104x32 plain text", TERMINAL_COLUMNS, TERMINAL_ROWS, TERMINAL_COLUMNS * 8, TERMINAL_ROWS * 16, TEXT_GRID_MEASURE_ROUNDS_SMALL}
	case .Colored_Code_104x32:
		return {"104x32 colored code", TERMINAL_COLUMNS, TERMINAL_ROWS, TERMINAL_COLUMNS * 8, TERMINAL_ROWS * 16, TEXT_GRID_MEASURE_ROUNDS_SMALL}
	case .Per_Cell_Color_104x32:
		return {"104x32 one color per cell", TERMINAL_COLUMNS, TERMINAL_ROWS, TERMINAL_COLUMNS * 8, TERMINAL_ROWS * 16, TEXT_GRID_MEASURE_ROUNDS_SMALL}
	case .Per_Cell_Filled_104x32:
		return {"104x32 one color and fill per cell", TERMINAL_COLUMNS, TERMINAL_ROWS, TERMINAL_COLUMNS * 8, TERMINAL_ROWS * 16, TEXT_GRID_MEASURE_ROUNDS_SMALL}
	case .Full_1920x1080_Terminal:
		return {"1920x1080 full terminal (240x67)", FULL_HD_COLUMNS, FULL_HD_ROWS, FULL_HD_WIDTH, FULL_HD_HEIGHT, TEXT_GRID_MEASURE_ROUNDS_LARGE}
	}
	return {}
}

// grid_emit_as_runs emits the exact equivalent of draw_text_grid using
// Draw_Text and Draw_Rectangle records, grouping cells by the same run
// rules as text_grid_draw.
@(private = "file")
grid_emit_as_runs :: proc(table: ^Draw_Table, x, y: int, grid: Text_Grid) {
	font := grid_font(grid)
	if !grid_valid(grid) || !font_size_valid(font) {
		table.refused = true
		return
	}
	cell_width, cell_height := cell_width_of(font), line_height(font)
	RUN_CHARACTERS :: 256
	run: [RUN_CHARACTERS * text_encoding.CHARACTER_BYTES_LIMIT]u8
	for row in 0 ..< grid.rows {
		cells := grid.cells[row * grid.stride:][:grid.columns]
		top := y + row * cell_height
		column := 0
		for column < grid.columns {
			cell := cells[column]
			left := x + column * cell_width
			if cell.reverse {
				draw_rectangle(table, left, top, cell_width, cell_height, cell.color)
				bytes := cell_character_put(run[:], 0, max(cell.character, ' '))
				draw_text(table, left, top, string(run[:bytes]), graphics.colors.background, font)
				column += 1
				continue
			}
			if cell.filled {
				count, bytes := 0, 0
				for column + count < grid.columns && count < RUN_CHARACTERS {
					next := cells[column + count]
					if next.reverse || !next.filled || next.color != cell.color || next.background != cell.background {
						break
					}
					bytes = cell_character_put(run[:], bytes, max(next.character, ' '))
					count += 1
				}
				draw_rectangle(table, left, top, count * cell_width, cell_height, cell.background)
				draw_text(table, left, top, string(run[:bytes]), cell.color, font)
				column += count
				continue
			}
			if cell.character <= ' ' {
				column += 1
				continue
			}
			count, bytes := 0, 0
			for column + count < grid.columns && count < RUN_CHARACTERS {
				next := cells[column + count]
				if next.reverse || next.filled || next.character < ' ' || next.color != cell.color {
					break
				}
				bytes = cell_character_put(run[:], bytes, next.character)
				count += 1
			}
			draw_text(table, left, top, string(run[:bytes]), cell.color, font)
			column += count
		}
	}
}

@(private = "file")
row_put_span :: proc(cells: []Text_Grid_Cell, column: int, text: string, color: graphics.Color, filled := false, background: graphics.Color = 0, reverse := false) -> int {
	col := column
	for ch in text {
		if col >= len(cells) {
			break
		}
		cells[col] = {
			character  = ch,
			reverse    = reverse,
			filled     = filled,
			color      = color,
			background = background,
		}
		col += 1
	}
	return col
}

@(private = "file")
fill_syntax_row :: proc(cells: []Text_Grid_Cell, row: int, columns: int) {
	COLOR_DIM :: graphics.Color(0x008A92A0)
	COLOR_KEYWORD :: graphics.Color(0x00E07A5F)
	COLOR_TYPE :: graphics.Color(0x0066B3FF)
	COLOR_IDENT :: graphics.Color(0x00E8ECEF)
	COLOR_STRING :: graphics.Color(0x0088D498)
	COLOR_NUMBER :: graphics.Color(0x00F2C14E)
	COLOR_ACCENT :: graphics.Color(0x00C792EA)
	BG_HIGHLIGHT :: graphics.Color(0x00243040)
	BG_STATUS :: graphics.Color(0x001E2836)

	if row == 0 {
		// Filled header banner across the full row with mixed color runs.
		col := 0
		col = row_put_span(cells, col, " modus console ", COLOR_IDENT, filled = true, background = BG_STATUS)
		col = row_put_span(cells, col, "| ", COLOR_DIM, filled = true, background = BG_STATUS)
		col = row_put_span(cells, col, "principal:0 ", COLOR_TYPE, filled = true, background = BG_STATUS)
		col = row_put_span(cells, col, "| ", COLOR_DIM, filled = true, background = BG_STATUS)
		col = row_put_span(cells, col, "grants:ok ", COLOR_STRING, filled = true, background = BG_STATUS)
		for col < columns {
			cells[col] = {character = ' ', filled = true, color = COLOR_DIM, background = BG_STATUS}
			col += 1
		}
		return
	}
	if row == 1 {
		col := 0
		col = row_put_span(cells, col, "modus> ", COLOR_ACCENT)
		col = row_put_span(cells, col, "log.follow", COLOR_IDENT)
		col = row_put_span(cells, col, " |> ", COLOR_KEYWORD)
		col = row_put_span(cells, col, "where", COLOR_TYPE)
		col = row_put_span(cells, col, "(level = ", COLOR_IDENT)
		col = row_put_span(cells, col, "Warning", COLOR_NUMBER)
		col = row_put_span(cells, col, ") ", COLOR_IDENT)
		if col < columns {
			cells[col] = {character = ' ', reverse = true, color = COLOR_IDENT}
		}
		return
	}
	// Highlighted active selection row every 17th line.
	selected := row % 17 == 5
	col := 0
	for col + 24 < columns {
		switch (row + col / 24) % 5 {
		case 0:
			col = row_put_span(cells, col, "00:12:41 ", COLOR_DIM, filled = selected, background = BG_HIGHLIGHT)
			col = row_put_span(cells, col, "proc ", COLOR_KEYWORD, filled = selected, background = BG_HIGHLIGHT)
			col = row_put_span(cells, col, "wiring_stall", COLOR_IDENT, filled = selected, background = BG_HIGHLIGHT)
			col = row_put_span(cells, col, "(", COLOR_DIM, filled = selected, background = BG_HIGHLIGHT)
			col = row_put_span(cells, col, "State", COLOR_TYPE, filled = selected, background = BG_HIGHLIGHT)
			col = row_put_span(cells, col, ") ", COLOR_DIM, filled = selected, background = BG_HIGHLIGHT)
		case 1:
			col = row_put_span(cells, col, "if ", COLOR_KEYWORD, filled = selected, background = BG_HIGHLIGHT)
			col = row_put_span(cells, col, "elapsed", COLOR_IDENT, filled = selected, background = BG_HIGHLIGHT)
			col = row_put_span(cells, col, " >= ", COLOR_ACCENT, filled = selected, background = BG_HIGHLIGHT)
			col = row_put_span(cells, col, "60000 ", COLOR_NUMBER, filled = selected, background = BG_HIGHLIGHT)
			col = row_put_span(cells, col, "\"revoked\" ", COLOR_STRING, filled = selected, background = BG_HIGHLIGHT)
		case 2:
			col = row_put_span(cells, col, "info ", COLOR_STRING, filled = selected, background = BG_HIGHLIGHT)
			col = row_put_span(cells, col, "ring ", COLOR_TYPE, filled = selected, background = BG_HIGHLIGHT)
			col = row_put_span(cells, col, "slot=", COLOR_DIM, filled = selected, background = BG_HIGHLIGHT)
			col = row_put_span(cells, col, "14 ", COLOR_NUMBER, filled = selected, background = BG_HIGHLIGHT)
			col = row_put_span(cells, col, "read=1024 ", COLOR_IDENT, filled = selected, background = BG_HIGHLIGHT)
		case 3:
			col = row_put_span(cells, col, "for ", COLOR_KEYWORD, filled = selected, background = BG_HIGHLIGHT)
			col = row_put_span(cells, col, "idx ", COLOR_IDENT, filled = selected, background = BG_HIGHLIGHT)
			col = row_put_span(cells, col, "in ", COLOR_KEYWORD, filled = selected, background = BG_HIGHLIGHT)
			col = row_put_span(cells, col, "0..<24 ", COLOR_NUMBER, filled = selected, background = BG_HIGHLIGHT)
			col = row_put_span(cells, col, "check_ok ", COLOR_STRING, filled = selected, background = BG_HIGHLIGHT)
		case 4:
			col = row_put_span(cells, col, "warn ", COLOR_NUMBER, filled = selected, background = BG_HIGHLIGHT)
			col = row_put_span(cells, col, "surface=", COLOR_DIM, filled = selected, background = BG_HIGHLIGHT)
			col = row_put_span(cells, col, "1920x1080 ", COLOR_TYPE, filled = selected, background = BG_HIGHLIGHT)
			col = row_put_span(cells, col, "frames=4096 ", COLOR_IDENT, filled = selected, background = BG_HIGHLIGHT)
		}
	}
	if selected {
		for col < columns {
			cells[col] = {character = ' ', filled = true, color = COLOR_DIM, background = BG_HIGHLIGHT}
			col += 1
		}
	}
}

@(private = "file")
workload_build_cells :: proc(kind: Grid_Workload, cells: []Text_Grid_Cell, columns, rows: int) {
	for &cell in cells {
		cell = {}
	}
	PALETTE := [6]graphics.Color{0x00E8ECEF, 0x00E07A5F, 0x0066B3FF, 0x0088D498, 0x00F2C14E, 0x00C792EA}
	BGS := [4]graphics.Color{0x001B2430, 0x00262030, 0x001C2D28, 0x002E241C}
	switch kind {
	case .Plain_104x32:
		for row in 0 ..< rows {
			line := cells[row * columns:][:columns]
			for col in 0 ..< columns - 8 {
				ch := rune('a' + (row + col) % 26)
				if col % 9 == 8 {
					ch = ' '
				}
				line[col] = {character = ch, color = PALETTE[0]}
			}
		}
	case .Colored_Code_104x32, .Full_1920x1080_Terminal:
		for row in 0 ..< rows {
			fill_syntax_row(cells[row * columns:][:columns], row, columns)
		}
	case .Per_Cell_Color_104x32:
		for row in 0 ..< rows {
			line := cells[row * columns:][:columns]
			for col in 0 ..< columns {
				line[col] = {
					character = rune('!' + (row * 13 + col) % 90),
					color     = PALETTE[(row + col) % len(PALETTE)],
				}
			}
		}
	case .Per_Cell_Filled_104x32:
		for row in 0 ..< rows {
			line := cells[row * columns:][:columns]
			for col in 0 ..< columns {
				line[col] = {
					character  = rune('!' + (row * 13 + col) % 90),
					filled     = true,
					color      = PALETTE[(row + col) % len(PALETTE)],
					background = BGS[(row + col) % len(BGS)],
				}
			}
		}
	}
}

@(private = "file")
canvases_equal :: proc(a, b: []graphics.Color) -> (equal: bool, first_diff: int) {
	if len(a) != len(b) {
		return false, 0
	}
	for idx in 0 ..< len(a) {
		if a[idx] != b[idx] {
			return false, idx
		}
	}
	return true, -1
}

// Verify pixel-for-pixel equality between Text_Grid and Text+Rectangle runs
// across edge cases (0 rows, 1x1 reverse/filled/plain, stride > columns,
// invalid code points) and all terminal workloads including 1920x1080.
@(test)
text_grid_equals_text_runs_pixel_for_pixel :: proc(t: ^testing.T) {
	process_drawing_begin()
	_ = blend_table()

	// Edge cases first: 0 rows, 1x1 plain/filled/reverse, stride > columns, control rune.
	edge_records_a := make([]Draw_Record, 64)
	defer delete(edge_records_a)
	edge_records_b := make([]Draw_Record, 64)
	defer delete(edge_records_b)
	edge_text_a := make([]u8, 4096)
	defer delete(edge_text_a)
	edge_text_b := make([]u8, 4096)
	defer delete(edge_text_b)
	edge_px_a := make([]graphics.Color, 64 * 64)
	defer delete(edge_px_a)
	edge_px_b := make([]graphics.Color, 64 * 64)
	defer delete(edge_px_b)

	edge_cells: [12]Text_Grid_Cell
	edge_cells[0] = {character = 'A', color = 0x00FFFFFF}
	edge_cells[1] = {character = ' ', reverse = true, color = 0x0000FF88}
	edge_cells[2] = {character = rune(0x01), filled = true, color = 0x00FFAA00, background = 0x00102030}
	edge_cells[4] = {character = 'X', color = 0x0044AAFF}
	edge_cells[5] = {character = ' ', color = 0x0044AAFF}
	edge_cells[6] = {character = 'Z', color = 0x0044AAFF}

	edge_grids := [3]Text_Grid{
		{cells = nil, columns = 4, rows = 0, stride = 4},
		{cells = edge_cells[:1], columns = 1, rows = 1, stride = 1},
		{cells = edge_cells[:], columns = 3, rows = 2, stride = 4},
	}
	for grid, g_idx in edge_grids {
		ta := Draw_Table{records = edge_records_a, text = edge_text_a}
		tb := Draw_Table{records = edge_records_b, text = edge_text_b}
		draw_text_grid(&ta, 0, 0, grid)
		grid_emit_as_runs(&tb, 0, 0, grid)
		testing.expectf(t, !ta.refused && !ta.full, "edge grid %d text_grid written", g_idx)
		testing.expectf(t, !tb.refused && !tb.full, "edge grid %d text_runs written", g_idx)
		ca := graphics.Canvas{pixels = raw_data(edge_px_a), width = 64, height = 64, stride = 64}
		cb := graphics.Canvas{pixels = raw_data(edge_px_b), width = 64, height = 64, stride = 64}
		graphics.clear(ca, graphics.colors.background)
		graphics.clear(cb, graphics.colors.background)
		execute(&ta, ca)
		execute(&tb, cb)
		eq, diff := canvases_equal(edge_px_a, edge_px_b)
		testing.expectf(t, eq, "edge grid %d pixel mismatch at %d", g_idx, diff)
	}

	// All realistic and worst-case terminal workloads, including 1920x1080.
	records_grid := make([]Draw_Record, 16)
	defer delete(records_grid)
	text_grid_buf := make([]u8, GRID_WORKLOAD_TEXT_CAPACITY)
	defer delete(text_grid_buf)
	records_runs := make([]Draw_Record, GRID_WORKLOAD_RECORD_CAPACITY)
	defer delete(records_runs)
	text_runs_buf := make([]u8, GRID_WORKLOAD_TEXT_CAPACITY)
	defer delete(text_runs_buf)

	records_grid_next := make([]Draw_Record, 16)
	defer delete(records_grid_next)
	text_grid_next := make([]u8, GRID_WORKLOAD_TEXT_CAPACITY)
	defer delete(text_grid_next)
	records_runs_next := make([]Draw_Record, GRID_WORKLOAD_RECORD_CAPACITY)
	defer delete(records_runs_next)
	text_runs_next := make([]u8, GRID_WORKLOAD_TEXT_CAPACITY)
	defer delete(text_runs_next)

	cells := make([]Text_Grid_Cell, FULL_HD_COLUMNS * FULL_HD_ROWS)
	defer delete(cells)
	pixels_grid := make([]graphics.Color, FULL_HD_WIDTH * FULL_HD_HEIGHT)
	defer delete(pixels_grid)
	pixels_runs := make([]graphics.Color, FULL_HD_WIDTH * FULL_HD_HEIGHT)
	defer delete(pixels_runs)

	for kind in Grid_Workload {
		spec := workload_spec(kind)
		cell_slice := cells[:spec.columns * spec.rows]
		workload_build_cells(kind, cell_slice, spec.columns, spec.rows)
		grid := Text_Grid{cells = cell_slice, columns = spec.columns, rows = spec.rows, stride = spec.columns}

		table_grid := Draw_Table{records = records_grid, text = text_grid_buf}
		table_runs := Draw_Table{records = records_runs, text = text_runs_buf}
		draw_text_grid(&table_grid, 0, 0, grid)
		grid_emit_as_runs(&table_runs, 0, 0, grid)

		testing.expectf(t, !table_grid.full && !table_grid.refused, "%s: Text_Grid table valid", spec.name)
		testing.expectf(t, !table_runs.full && !table_runs.refused, "%s: Text_Run table valid", spec.name)
		testing.expect_value(t, table_grid.record_count, 1)
		testing.expectf(t, table_runs.record_count >= spec.rows, "%s: Text_Run emits at least one record per row", spec.name)

		if kind == .Per_Cell_Filled_104x32 {
			// Worst case in 104x32 exceeds the 4 096 record threshold from draw_table.md.
			testing.expect_value(t, table_runs.record_count, TERMINAL_COLUMNS * TERMINAL_ROWS * 2)
			testing.expect(t, table_runs.record_count > 4096, "104x32 filled worst case exceeds 4 096 records")
		}
		if kind == .Full_1920x1080_Terminal {
			testing.expect(t, table_runs.record_count > 512, "full 1920x1080 colored terminal exceeds a 512-record window table")
		}

		px_len := spec.width * spec.height
		canvas_grid := graphics.Canvas{pixels = raw_data(pixels_grid[:px_len]), width = spec.width, height = spec.height, stride = spec.width}
		canvas_runs := graphics.Canvas{pixels = raw_data(pixels_runs[:px_len]), width = spec.width, height = spec.height, stride = spec.width}
		graphics.clear(canvas_grid, graphics.colors.background)
		graphics.clear(canvas_runs, graphics.colors.background)

		execute(&table_grid, canvas_grid)
		execute(&table_runs, canvas_runs)
		eq, diff := canvases_equal(pixels_grid[:px_len], pixels_runs[:px_len])
		testing.expectf(t, eq, "%s whole render pixel mismatch at %d", spec.name, diff)

		// Four quadrant damage rectangles must also render pixel-for-pixel identically.
		half_w, half_h := spec.width / 2, spec.height / 2
		quadrants := [4]Rectangle{
			{0, 0, half_w, half_h},
			{half_w, 0, spec.width, half_h},
			{0, half_h, half_w, spec.height},
			{half_w, half_h, spec.width, spec.height},
		}
		graphics.clear(canvas_grid, graphics.colors.background)
		graphics.clear(canvas_runs, graphics.colors.background)
		execute_in_rectangles(&table_grid, canvas_grid, quadrants[:])
		execute_in_rectangles(&table_runs, canvas_runs, quadrants[:])
		eq_quad, diff_quad := canvases_equal(pixels_grid[:px_len], pixels_runs[:px_len])
		testing.expectf(t, eq_quad, "%s 4-quadrant render pixel mismatch at %d", spec.name, diff_quad)

		// Incremental update: mutate one cell in the middle row and verify damage redraw matches.
		mid_index := (spec.rows / 2) * spec.columns + spec.columns / 2
		saved_cell := cell_slice[mid_index]
		cell_slice[mid_index] = {character = '@', color = 0x00FF55AA, reverse = true}

		table_grid_next := Draw_Table{records = records_grid_next, text = text_grid_next}
		table_runs_next := Draw_Table{records = records_runs_next, text = text_runs_next}
		draw_text_grid(&table_grid_next, 0, 0, grid)
		grid_emit_as_runs(&table_runs_next, 0, 0, grid)

		damage_grid, damage_runs: Damage
		damage_by_difference(&table_grid, &table_grid_next, &damage_grid)
		damage_by_difference(&table_runs, &table_runs_next, &damage_runs)
		testing.expectf(t, damage_grid.count > 0, "%s: Text_Grid single-cell change produces damage", spec.name)
		testing.expectf(t, damage_runs.count > 0, "%s: Text_Run single-cell change produces damage", spec.name)

		draw_damage_on_surface(&table_grid_next, canvas_grid, damage_grid.rectangles[:damage_grid.count])
		draw_damage_on_surface(&table_runs_next, canvas_runs, damage_runs.rectangles[:damage_runs.count])
		eq_dmg, diff_dmg := canvases_equal(pixels_grid[:px_len], pixels_runs[:px_len])
		testing.expectf(t, eq_dmg, "%s incremental damage render pixel mismatch at %d", spec.name, diff_dmg)

		cell_slice[mid_index] = saved_cell

		if TEXT_GRID_MEASURE_ENABLED {
			text_grid_measure_print(spec, grid, &table_grid, &table_grid_next, &table_runs, &table_runs_next, canvas_grid, canvas_runs, quadrants[:])
		}
	}
}

@(private = "file")
text_grid_measure_print :: proc(
	spec: Grid_Spec,
	grid: Text_Grid,
	table_grid, table_grid_next: ^Draw_Table,
	table_runs, table_runs_next: ^Draw_Table,
	canvas_grid, canvas_runs: graphics.Canvas,
	quadrants: []Rectangle,
) {
	build_grid_ns, build_runs_ns := max(i64), max(i64)
	diff_grid_ns, diff_runs_ns := max(i64), max(i64)
	draw_grid_whole_ns, draw_runs_whole_ns := max(i64), max(i64)
	draw_grid_quads_ns, draw_runs_quads_ns := max(i64), max(i64)

	for _ in 0 ..< spec.rounds {
		draw_table_clear(table_grid)
		t0 := time.tick_now()
		draw_text_grid(table_grid, 0, 0, grid)
		build_grid_ns = min(build_grid_ns, time.duration_nanoseconds(time.tick_since(t0)))

		draw_table_clear(table_runs)
		t0 = time.tick_now()
		grid_emit_as_runs(table_runs, 0, 0, grid)
		build_runs_ns = min(build_runs_ns, time.duration_nanoseconds(time.tick_since(t0)))

		d_grid: Damage
		t0 = time.tick_now()
		damage_by_difference(table_grid, table_grid_next, &d_grid)
		diff_grid_ns = min(diff_grid_ns, time.duration_nanoseconds(time.tick_since(t0)))

		d_runs: Damage
		t0 = time.tick_now()
		damage_by_difference(table_runs, table_runs_next, &d_runs)
		diff_runs_ns = min(diff_runs_ns, time.duration_nanoseconds(time.tick_since(t0)))

		t0 = time.tick_now()
		execute(table_grid, canvas_grid)
		draw_grid_whole_ns = min(draw_grid_whole_ns, time.duration_nanoseconds(time.tick_since(t0)))

		t0 = time.tick_now()
		execute(table_runs, canvas_runs)
		draw_runs_whole_ns = min(draw_runs_whole_ns, time.duration_nanoseconds(time.tick_since(t0)))

		t0 = time.tick_now()
		execute_in_rectangles(table_grid, canvas_grid, quadrants)
		draw_grid_quads_ns = min(draw_grid_quads_ns, time.duration_nanoseconds(time.tick_since(t0)))

		t0 = time.tick_now()
		execute_in_rectangles(table_runs, canvas_runs, quadrants)
		draw_runs_quads_ns = min(draw_runs_quads_ns, time.duration_nanoseconds(time.tick_since(t0)))
	}

	grid_rec_bytes := table_grid.record_count * size_of(Draw_Record)
	runs_rec_bytes := table_runs.record_count * size_of(Draw_Record)
	fmt.printfln(
		"interface: text_grid_measure [%s] (least of %d rounds):\n  Text_Grid: %d records (%d B), %d B text table | build %.1f us | diff %.1f us | draw %.1f us whole, %.1f us 4-quad\n  Text_Run:  %d records (%d B), %d B text table | build %.1f us | diff %.1f us | draw %.1f us whole, %.1f us 4-quad",
		spec.name, spec.rounds,
		table_grid.record_count, grid_rec_bytes, table_grid.text_count,
		f64(build_grid_ns) / 1000, f64(diff_grid_ns) / 1000, f64(draw_grid_whole_ns) / 1000, f64(draw_grid_quads_ns) / 1000,
		table_runs.record_count, runs_rec_bytes, table_runs.text_count,
		f64(build_runs_ns) / 1000, f64(diff_runs_ns) / 1000, f64(draw_runs_whole_ns) / 1000, f64(draw_runs_quads_ns) / 1000,
	)
}
