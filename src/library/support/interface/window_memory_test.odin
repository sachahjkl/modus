#+build !freestanding
package interface

import "modus:support/graphics"
import "core:testing"

// The smallest window memory: one record and four bytes of text in each
// table. The records and the bytes past them must be refused, and the
// table must say that it is full, so the next frame is drawn whole.
@(test)
a_window_memory_refuses_a_record_and_a_text_past_its_capacity :: proc(t: ^testing.T) {
	memory: Window_Memory(1, 4)
	drawing := window_memory_drawing(&memory)
	testing.expect_value(t, len(drawing.now.records), 1)
	testing.expect_value(t, len(drawing.now.text), 4)

	// Nothing yet: the edge of 0.
	testing.expect_value(t, drawing.now.record_count, 0)
	testing.expect(t, !drawing.now.full)

	// The bound: one record fits.
	draw_rectangle(&drawing.now, 0, 0, 8, 8, 0x102030)
	testing.expect_value(t, drawing.now.record_count, 1)
	testing.expect(t, !drawing.now.full)

	// One past the bound: refused, and nothing changed in the table.
	kept := memory.records_now[0]
	draw_rectangle(&drawing.now, 4, 4, 8, 8, 0x405060)
	testing.expect_value(t, drawing.now.record_count, 1)
	testing.expect(t, drawing.now.full)
	testing.expect(t, memory.records_now[0] == kept)

	// A text one byte longer than the text table: refused, no byte written.
	draw_table_clear(&drawing.now)
	draw_text(&drawing.now, 0, 0, "12345", 0x708090)
	testing.expect_value(t, drawing.now.text_count, 0)
	testing.expect_value(t, drawing.now.record_count, 0)
	testing.expect(t, drawing.now.full)
	testing.expect(t, memory.text_now == [4]u8{})
	testing.expect(t, memory.text_before == [4]u8{})
	testing.expect(t, memory.records_before == [1]Draw_Record{})
}

// The tables of the drawing are the memory of the record, the table now and
// the table before apart, and each text table starts at an address that is
// a multiple of 4, as a grid needs.
@(test)
a_window_memory_gives_its_own_tables :: proc(t: ^testing.T) {
	memory: Window_Memory(3, 12)
	drawing := window_memory_drawing(&memory)
	testing.expect(t, drawing == &memory.drawing)
	testing.expect(t, rawptr(raw_data(drawing.now.records)) == rawptr(&memory.records_now[0]))
	testing.expect(t, rawptr(raw_data(drawing.before.records)) == rawptr(&memory.records_before[0]))
	testing.expect(t, rawptr(raw_data(drawing.now.text)) == rawptr(&memory.text_now[0]))
	testing.expect(t, rawptr(raw_data(drawing.before.text)) == rawptr(&memory.text_before[0]))
	testing.expect_value(t, len(drawing.before.records), 3)
	testing.expect_value(t, len(drawing.before.text), 12)
	testing.expect_value(t, uintptr(&memory.text_now[0]) % 4, 0)
	testing.expect_value(t, uintptr(&memory.text_before[0]) % 4, 0)

	// A frame in the table now reaches the table before only by the copy
	// of a frame that the window presented.
	draw_rectangle(&drawing.now, 0, 0, 8, 8, 0x102030)
	testing.expect_value(t, drawing.before.record_count, 0)
	testing.expect(t, memory.records_before == [3]Draw_Record{})
	testing.expect(t, draw_table_copy(&drawing.before, &drawing.now))
	testing.expect(t, memory.records_before[0] == memory.records_now[0])
}

// The drawing is given at each frame: the second call must change nothing
// but the slices, which are the same. A call that cleared the input, the
// state, the picture memories or the frame before would lose a key, the
// focus, the pictures, or the difference with the last frame.
@(test)
a_window_memory_keeps_its_drawing_from_call_to_call :: proc(t: ^testing.T) {
	memory: Window_Memory(4, 16)
	// Before the first frame: an event can come before the tables are
	// given.
	memory.drawing.input.key_count = 1
	memory.drawing.input.keys[0].code = KEY_TAB
	drawing := window_memory_drawing(&memory)
	testing.expect_value(t, drawing.input.key_count, 1)

	pixels: [4]graphics.Color
	picture_memories := [1][]graphics.Color{pixels[:]}
	drawing.now.picture_memories = picture_memories[:]
	drawing.state.focus = identity("a field")
	drawing.drawn = true
	draw_rectangle(&drawing.now, 0, 0, 8, 8, 0x102030)
	draw_table_copy(&drawing.before, &drawing.now)
	before := memory.drawing

	again := window_memory_drawing(&memory)
	testing.expect(t, again == drawing)
	testing.expect_value(t, again.input.key_count, 1)
	testing.expect_value(t, again.state.focus, identity("a field"))
	testing.expect(t, again.drawn)
	testing.expect_value(t, again.now.record_count, 1)
	testing.expect_value(t, again.before.record_count, 1)
	testing.expect_value(t, len(again.now.picture_memories), 1)
	testing.expect(t, rawptr(raw_data(again.now.records)) == rawptr(raw_data(before.now.records)))
	testing.expect(t, rawptr(raw_data(again.before.text)) == rawptr(raw_data(before.before.text)))
}
