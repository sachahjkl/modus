#+build !freestanding
package interface

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "modus:contract/draw_record"
import "modus:graphics"

// The cost of the clip stack (src/md/api/draw_table.md, "What costs more
// than version 10"): 256 rectangles under CLIP_DEPTH_LIMIT nested clips
// against the same rectangles with no clip, drawn whole and in four damage
// rectangles, and the border of the order of the clips over 4 096 records.
// It prints measures and asserts nothing. It measures only when the
// environment sets MODUS_MEASURE_CLIPS:
//
//   MODUS_MEASURE_CLIPS=1 taskset -c 5 odin test src/library/modus/interface -o:speed -collection:modus=src/library/modus -define:ODIN_TEST_NAMES=interface.clip_measure
//
// Each time is the least of many rounds, so that an interruption of the
// host does not count.

@(private = "file")
CLIP_MEASURE_ROUNDS :: 200
@(private = "file")
CLIP_MEASURE_RECTANGLES :: 256
@(private = "file")
CLIP_MEASURE_ORDER_RECORDS :: 4096
@(private = "file")
CLIP_MEASURE_WIDTH :: 512
@(private = "file")
CLIP_MEASURE_HEIGHT :: 512

@(private = "file")
Clip_Measure_Tables :: struct {
	records: [CLIP_MEASURE_RECTANGLES + 2 * draw_record.CLIP_DEPTH_LIMIT]Draw_Record,
	order:   [CLIP_MEASURE_ORDER_RECORDS]Draw_Record,
	pixels:  [CLIP_MEASURE_WIDTH * CLIP_MEASURE_HEIGHT]graphics.Color,
}

// clip_measure_draw gives the least time of one draw of a table, whole and
// in four parts of equal size.
@(private = "file")
clip_measure_draw :: proc(table: ^Draw_Table, pixels: []graphics.Color) -> (whole_nanoseconds, parts_nanoseconds: i64) {
	canvas := graphics.Canvas{pixels = raw_data(pixels), width = CLIP_MEASURE_WIDTH, height = CLIP_MEASURE_HEIGHT, stride = CLIP_MEASURE_WIDTH}
	HALF_WIDTH :: CLIP_MEASURE_WIDTH / 2
	HALF_HEIGHT :: CLIP_MEASURE_HEIGHT / 2
	parts := [4]Rectangle{{0, 0, HALF_WIDTH, HALF_HEIGHT}, {HALF_WIDTH, 0, CLIP_MEASURE_WIDTH, HALF_HEIGHT}, {0, HALF_HEIGHT, HALF_WIDTH, CLIP_MEASURE_HEIGHT}, {HALF_WIDTH, HALF_HEIGHT, CLIP_MEASURE_WIDTH, CLIP_MEASURE_HEIGHT}}
	whole_nanoseconds, parts_nanoseconds = max(i64), max(i64)
	for _ in 0 ..< CLIP_MEASURE_ROUNDS {
		start := time.tick_now()
		execute(table, canvas)
		whole_nanoseconds = min(whole_nanoseconds, time.duration_nanoseconds(time.tick_since(start)))
		start = time.tick_now()
		execute_in_rectangles(table, canvas, parts[:])
		parts_nanoseconds = min(parts_nanoseconds, time.duration_nanoseconds(time.tick_since(start)))
	}
	return
}

// clip_measure_build writes the rectangles of the measure, a grid of 16 by
// 16 squares of 24 pixels, under a depth of nested clips that each leave a
// margin of one pixel.
@(private = "file")
clip_measure_build :: proc(table: ^Draw_Table, depth: int) {
	draw_table_clear(table)
	for level in 0 ..< depth {
		draw_clip_push(table, level, level, CLIP_MEASURE_WIDTH - 2 * level, CLIP_MEASURE_HEIGHT - 2 * level)
	}
	for index in 0 ..< CLIP_MEASURE_RECTANGLES {
		draw_rectangle(table, (index % 16) * 32 + 4, (index / 16) * 32 + 4, 24, 24, graphics.Color(0x00102030 + u32(index)))
	}
	for _ in 0 ..< depth {
		draw_clip_pop(table)
	}
}

@(test)
clip_measure :: proc(t: ^testing.T) {
	if os.get_env("MODUS_MEASURE_CLIPS", context.temp_allocator) == "" {
		return
	}
	_ = blend_table()
	memory := new(Clip_Measure_Tables)
	defer free(memory)
	table := Draw_Table{records = memory.records[:]}
	depths := [2]int{0, draw_record.CLIP_DEPTH_LIMIT}
	for depth in depths {
		clip_measure_build(&table, depth)
		whole, parts := clip_measure_draw(&table, memory.pixels[:])
		fmt.printfln("interface: clip stack, %v rectangles under %v nested clips, in %v by %v pixels: %.1f us whole, %.1f us in 4 damage rectangles (the least of %v rounds)", CLIP_MEASURE_RECTANGLES, depth, CLIP_MEASURE_WIDTH, CLIP_MEASURE_HEIGHT, f64(whole) / 1000, f64(parts) / 1000, CLIP_MEASURE_ROUNDS)
	}
	// The border of the order: a rectangle, then a push and its pop, over
	// 4 096 records; the last record is a rectangle, so the order is whole.
	for &record, index in memory.order {
		switch index % 3 {
		case 1:
			record = draw_record.record_of(draw_record.Draw_Clip_Push{}, 0, 0, 0, draw_record.units_of_pixels(8), draw_record.units_of_pixels(8))
		case 2:
			record = draw_record.record_of(draw_record.Draw_Clip_Pop{}, 0, 0, 0, 0, 0)
		case:
			record = draw_record.record_of(draw_record.Draw_Rectangle{color = draw_record.opaque(0x00102030)}, 0, 0, 0, draw_record.units_of_pixels(8), draw_record.units_of_pixels(8))
		}
	}
	#assert(CLIP_MEASURE_ORDER_RECORDS % 3 == 1)
	least := max(i64)
	problem: draw_record.Clip_Order_Problem
	for _ in 0 ..< CLIP_MEASURE_ROUNDS {
		start := time.tick_now()
		problem, _ = draw_record.clip_order_check(memory.order[:])
		least = min(least, time.duration_nanoseconds(time.tick_since(start)))
	}
	fmt.printfln("interface: clip stack, the border of the order over %v records: %.1f us (the least of %v rounds, the verdict %v)", CLIP_MEASURE_ORDER_RECORDS, f64(least) / 1000, CLIP_MEASURE_ROUNDS, problem)
	testing.expect(t, !table.refused && !table.full, "a table of the measure is not written")
}
