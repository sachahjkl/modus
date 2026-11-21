#+build !freestanding
package interface

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "modus:contract/draw_record"
import "modus:graphics"

// The cost of a path (src/md/api/draw_table.md, "What costs more than
// version 10"): the time of the fill and of the stroke of an icon, of a
// chart, of a line and of the largest path, drawn whole and in four damage
// rectangles. It prints measures and asserts nothing. It measures only when
// the environment sets MODUS_MEASURE_PATHS:
//
//   MODUS_MEASURE_PATHS=1 taskset -c 5 odin test src/library/modus/interface -o:speed -collection:modus=src/library/modus -define:ODIN_TEST_NAMES=interface.path_measure
//
// Each time is the least of many rounds, so that an interruption of the
// host does not count.

@(private = "file")
MEASURE_ROUNDS :: 200

@(private = "file")
Measure_Tables :: struct {
	records: [4]Draw_Record,
	text:    [(draw_record.PATH_POINT_LIMIT + 4) * draw_record.PATH_POINT_SIZE]u8,
}

// measure_path gives the least time of one draw of a table, whole and in
// four parts of equal size, in a canvas of a size.
@(private = "file")
measure_path :: proc(table: ^Draw_Table, width, height: int) -> (whole_nanoseconds, parts_nanoseconds: i64) {
	pixels := make([]graphics.Color, width * height)
	defer delete(pixels)
	canvas := graphics.Canvas{pixels = raw_data(pixels), width = width, height = height, stride = width}
	parts := [4]Rectangle{{0, 0, width / 2, height / 2}, {width / 2, 0, width, height / 2}, {0, height / 2, width / 2, height}, {width / 2, height / 2, width, height}}
	whole_nanoseconds, parts_nanoseconds = max(i64), max(i64)
	for _ in 0 ..< MEASURE_ROUNDS {
		start := time.tick_now()
		execute(table, canvas)
		whole_nanoseconds = min(whole_nanoseconds, time.duration_nanoseconds(time.tick_since(start)))
		start = time.tick_now()
		execute_in_rectangles(table, canvas, parts[:])
		parts_nanoseconds = min(parts_nanoseconds, time.duration_nanoseconds(time.tick_since(start)))
	}
	return
}

@(private = "file")
measure_print :: proc(name: string, table: ^Draw_Table, width, height: int) {
	whole, parts := measure_path(table, width, height)
	fmt.printfln("interface: path, %s, in %v by %v pixels: %.1f us whole, %.1f us in 4 damage rectangles (the least of %v rounds)", name, width, height, f64(whole) / 1000, f64(parts) / 1000, MEASURE_ROUNDS)
}

@(test)
path_measure :: proc(t: ^testing.T) {
	if os.get_env("MODUS_MEASURE_PATHS", context.temp_allocator) == "" {
		return
	}
	_ = blend_table()
	memory := new(Measure_Tables)
	defer free(memory)
	table := Draw_Table{records = memory.records[:], text = memory.text[:]}
	UNITS :: draw_record.UNITS_PER_PIXEL
	// An icon of 64 by 64: a circle of eight curves, a fill, then a stroke.
	circle: [18]Path_Point
	ON :: [8][2]i32{{30, 0}, {21, 21}, {0, 30}, {-21, 21}, {-30, 0}, {-21, -21}, {0, -30}, {21, -21}}
	CONTROL :: [8][2]i32{{30, 12}, {12, 30}, {-12, 30}, {-30, 12}, {-30, -12}, {-12, -30}, {12, -30}, {30, -12}}
	on, control := ON, CONTROL
	circle[0] = {command = .Move, x = (32 + on[0][0]) * UNITS, y = (32 + on[0][1]) * UNITS}
	for eighth in 0 ..< 8 {
		next := on[(eighth + 1) % 8]
		circle[1 + eighth * 2] = {command = .Curve_Control, x = (32 + control[eighth][0]) * UNITS, y = (32 + control[eighth][1]) * UNITS}
		circle[2 + eighth * 2] = {command = .Line, x = (32 + next[0]) * UNITS, y = (32 + next[1]) * UNITS}
	}
	circle[17] = {command = .Close}
	draw_path(&table, circle[:], draw_record.opaque(0x004080C0), 0, 0)
	measure_print("an icon of 8 curves, filled", &table, 64, 64)
	draw_table_clear(&table)
	draw_path(&table, circle[:], 0, draw_record.opaque(0x00F0F0F0), 2 * UNITS)
	measure_print("an icon of 8 curves, stroked 2 pixels wide", &table, 64, 64)
	// A chart: a line of 512 points across 1 024 by 200 pixels, stroked.
	chart: [512]Path_Point
	seed: u32 = 7
	for &place, index in chart {
		seed = seed * 1103515245 + 12345
		place = {command = index == 0 ? draw_record.Path_Command.Move : draw_record.Path_Command.Line, x = i32(index * 2) * UNITS + 32, y = i32(20 + (seed >> 16) % 160) * UNITS}
	}
	draw_table_clear(&table)
	draw_path(&table, chart[:], 0, draw_record.opaque(0x00F0A040), 2 * UNITS)
	measure_print("a chart of 512 points, stroked 2 pixels wide", &table, 1024, 200)
	// A line of 1 pixel across 512 by 512 pixels.
	draw_table_clear(&table)
	draw_line(&table, 0, 0, 511, 300, 1, 0x00FFFFFF)
	measure_print("a line of 1 pixel at an angle", &table, 512, 512)
	// The largest path: PATH_POINT_LIMIT points in a zigzag over 512 by
	// 512 pixels, filled, then stroked.
	largest: [draw_record.PATH_POINT_LIMIT]Path_Point
	for &place, index in largest {
		place = {command = index == 0 ? draw_record.Path_Command.Move : draw_record.Path_Command.Line, x = i32(index * 512 / len(largest)) * UNITS, y = i32(index % 2 == 0 ? 4 : 508) * UNITS}
	}
	draw_table_clear(&table)
	draw_path(&table, largest[:], draw_record.with_alpha(0x00FFFFFF, 128), 0, 0)
	measure_print("the largest path, 1 024 points, filled", &table, 512, 512)
	draw_table_clear(&table)
	draw_path(&table, largest[:], 0, draw_record.opaque(0x00FFFFFF), 2 * UNITS)
	measure_print("the largest path, 1 024 points, stroked 2 pixels wide", &table, 512, 512)
	testing.expect(t, !table.refused && !table.full, "a path of the measure is not written")
}
