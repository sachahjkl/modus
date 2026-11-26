#+build !freestanding
package doom

import "core:testing"
import "modus:display"

@(test)
doom_key_mapping_covers_controls_and_refuses_unknown :: proc(t: ^testing.T) {
	testing.expect_value(t, doom_key_of_event(u32(Scan_Code.Up), 0), u8(Doom_Key.Up))
	testing.expect_value(t, doom_key_of_event(u32(Scan_Code.W), 'w'), u8(Doom_Key.Up))
	testing.expect_value(t, doom_key_of_event(u32(Scan_Code.Down), 0), u8(Doom_Key.Down))
	testing.expect_value(t, doom_key_of_event(u32(Scan_Code.S), 's'), u8(Doom_Key.Down))
	testing.expect_value(t, doom_key_of_event(u32(Scan_Code.Left), 0), u8(Doom_Key.Left))
	testing.expect_value(t, doom_key_of_event(u32(Scan_Code.Right), 0), u8(Doom_Key.Right))
	testing.expect_value(t, doom_key_of_event(u32(Scan_Code.A), 'a'), u8(Doom_Key.Strafe_L))
	testing.expect_value(t, doom_key_of_event(u32(Scan_Code.D), 'd'), u8(Doom_Key.Strafe_R))
	testing.expect_value(t, doom_key_of_event(u32(Scan_Code.Ctrl_Left), 0), u8(Doom_Key.Fire))
	testing.expect_value(t, doom_key_of_event(u32(Scan_Code.Ctrl_Right), 0), u8(Doom_Key.Fire))
	testing.expect_value(t, doom_key_of_event(u32(Scan_Code.Space), ' '), u8(Doom_Key.Use))
	testing.expect_value(t, doom_key_of_event(u32(Scan_Code.E), 'e'), u8(Doom_Key.Use))
	testing.expect_value(t, doom_key_of_event(u32(Scan_Code.Shift_Left), 0), u8(Doom_Key.Rshift))
	testing.expect_value(t, doom_key_of_event(u32(Scan_Code.Enter), '\n'), u8(Doom_Key.Enter))
	testing.expect_value(t, doom_key_of_event(u32(Scan_Code.Escape), 0), u8(Doom_Key.Escape))
	testing.expect_value(t, doom_key_of_event(u32(Scan_Code.Tab), '\t'), u8(Doom_Key.Tab))
	testing.expect_value(t, doom_key_of_event(u32(Scan_Code.Y), 'y'), u8(Doom_Key.Key_Y))
	testing.expect_value(t, doom_key_of_event(u32(Scan_Code.N), 'n'), u8(Doom_Key.Key_N))
	testing.expect_value(t, doom_key_of_event(u32(Scan_Code.Digit_1), '1'), u8(Doom_Key.Digit_1))
	testing.expect_value(t, doom_key_of_event(u32(Scan_Code.Digit_7), '7'), u8(Doom_Key.Digit_7))
	testing.expect_value(t, doom_key_of_event(0xFFFF, 0), u8(0))
	testing.expect_value(t, doom_key_of_event(0, 0x0100), u8(0))
}

@(test)
key_queue_wraps_and_counts_drops :: proc(t: ^testing.T) {
	q: Key_Queue
	_, ok := key_queue_pop(&q)
	testing.expect(t, !ok)

	// Zero key is ignored.
	key_queue_push(&q, true, 0)
	testing.expect_value(t, q.count, 0)

	for i in 0 ..< KEY_QUEUE_CAPACITY {
		key_queue_push(&q, i % 2 == 0, u8('a' + (i % 26)))
	}
	testing.expect_value(t, q.count, KEY_QUEUE_CAPACITY)
	testing.expect_value(t, q.dropped, u64(0))

	// One past capacity drops cleanly and counts it.
	key_queue_push(&q, true, u8(Doom_Key.Fire))
	testing.expect_value(t, q.dropped, u64(1))

	// Drain half and push again to test wrap-around.
	for i in 0 ..< 10 {
		item, popped := key_queue_pop(&q)
		testing.expect(t, popped)
		testing.expect_value(t, item.pressed, i % 2 == 0)
		testing.expect_value(t, item.key, u8('a' + (i % 26)))
	}
	key_queue_push(&q, true, u8(Doom_Key.Enter))
	testing.expect_value(t, q.count, KEY_QUEUE_CAPACITY - 9)
}

@(test)
mouse_input_accumulates_deltas_and_clears_on_unlock :: proc(t: ^testing.T) {
	m: Mouse_Input
	_, _, _, ok := mouse_input_take(&m)
	testing.expect(t, !ok)

	mouse_input_add(&m, 5, -3, display.BUTTON_LEFT | display.BUTTON_RIGHT)
	mouse_input_add(&m, -2, 4, display.BUTTON_RIGHT)
	buttons, dx, dy, taken := mouse_input_take(&m)
	testing.expect(t, taken)
	testing.expect_value(t, buttons, i32(2))
	testing.expect_value(t, dx, i32(12))
	testing.expect_value(t, dy, i32(4))

	// Unlock clears held buttons and queues a zero-button update.
	mouse_input_clear(&m)
	buttons2, dx2, dy2, taken2 := mouse_input_take(&m)
	testing.expect(t, taken2)
	testing.expect_value(t, buttons2, i32(0))
	testing.expect_value(t, dx2, i32(0))
	testing.expect_value(t, dy2, i32(0))
}
