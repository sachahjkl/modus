#+build !freestanding
package bar

import "core:testing"

@(private = "file")
make_key_head :: proc(b0, b1, b2, b3: u8) -> u64 {
	raw := [8]u8{b0, b1, b2, b3, 0x11, 0x22, 0x33, 0x44}
	return transmute(u64)raw
}

@(test)
viewer_popover_zero_viewers_hidden_and_noop :: proc(t: ^testing.T) {
	popover: Viewer_Popover
	viewer_popover_init(&popover)

	// 0 viewers: mark click is a no-op, Escape is a no-op, click is a no-op.
	testing.expect(t, !viewer_popover_has_viewers(&popover))
	testing.expect_value(t, viewer_popover_mark_click(&popover).kind, Viewer_Popover_Action_Kind.None)
	testing.expect(t, !popover.open)
	testing.expect_value(t, viewer_popover_escape(&popover).kind, Viewer_Popover_Action_Kind.None)
	testing.expect_value(t, viewer_popover_click(&popover, 900, 120, 1280, 910, 80).kind, Viewer_Popover_Action_Kind.None)
	testing.expect_value(t, viewer_popover_disconnect_index(&popover, 0).kind, Viewer_Popover_Action_Kind.None)
	testing.expect(t, !viewer_popover_point_inside(900, 120, 1280, 0, 910, 40))
	testing.expect_value(t, viewer_popover_disconnect_at(900, 120, 1280, 0, 910, 40), -1)

	// Sync with capture open but 0 viewers stays closed.
	keys := [1]u64{make_key_head(0xAA, 0xBB, 0xCC, 0xDD)}
	testing.expect(t, !viewer_popover_sync(&popover, true, 0, keys[:], 0))
	testing.expect(t, !popover.open)
	testing.expect(t, !viewer_popover_has_viewers(&popover))
}

@(test)
viewer_popover_single_viewer_open_label_and_disconnect :: proc(t: ^testing.T) {
	popover: Viewer_Popover
	viewer_popover_init(&popover)

	k0 := make_key_head(0xAB, 0xCD, 0x01, 0x23)
	keys := [1]u64{k0}
	testing.expect(t, viewer_popover_sync(&popover, true, 1, keys[:], 1))
	testing.expect(t, viewer_popover_has_viewers(&popover))

	// Key label formatting (both input and view-only, plus too-small buffer refusal).
	label_buf: [VIEWER_LABEL_CAPACITY]u8
	testing.expect_value(t, viewer_key_label(k0, true, label_buf[:]), "abcd0123 (input)")
	testing.expect_value(t, viewer_key_label(k0, false, label_buf[:]), "abcd0123 (view)")
	tiny: [4]u8
	testing.expect_value(t, viewer_key_label(k0, true, tiny[:]), "")

	// Clicking the bar mark opens the popover.
	open_act := viewer_popover_mark_click(&popover)
	testing.expect_value(t, open_act.kind, Viewer_Popover_Action_Kind.Opened)
	testing.expect(t, popover.open)

	// Clicking inside the popover body away from the disconnect button keeps it open.
	px, py, pw, _, row_ok := viewer_popover_row_rect(900, 120, 1280, 1, 0)
	testing.expect(t, row_ok && pw > VIEWER_DISCONNECT_WIDTH)
	body_act := viewer_popover_click(&popover, 900, 120, 1280, px + 8, py + 8)
	testing.expect_value(t, body_act.kind, Viewer_Popover_Action_Kind.None)
	testing.expect(t, popover.open)

	// Moving over the disconnect button sets hovered_index = 0.
	bx, by, bw, bh, btn_ok := viewer_popover_disconnect_rect(900, 120, 1280, 1, 0)
	testing.expect(t, btn_ok)
	testing.expect(t, viewer_popover_pointer_move(&popover, 900, 120, 1280, bx + bw / 2, by + bh / 2))
	testing.expect_value(t, popover.hovered_index, 0)

	// Clicking the disconnect button emits Disconnect with exact index and key_head and closes.
	disc_act := viewer_popover_click(&popover, 900, 120, 1280, bx + bw / 2, by + bh / 2)
	testing.expect_value(t, disc_act.kind, Viewer_Popover_Action_Kind.Disconnect)
	testing.expect_value(t, disc_act.viewer_index, 0)
	testing.expect_value(t, disc_act.key_head, k0)
	testing.expect(t, !popover.open)
	testing.expect_value(t, popover.hovered_index, -1)
}

@(test)
viewer_popover_multiple_viewers_and_invalid_indexes :: proc(t: ^testing.T) {
	popover: Viewer_Popover
	viewer_popover_init(&popover)

	k0 := make_key_head(0x10, 0x20, 0x30, 0x40)
	k1 := make_key_head(0x50, 0x60, 0x70, 0x80)
	k2 := make_key_head(0x90, 0xA0, 0xB0, 0xC0)
	keys := [3]u64{k0, k1, k2}
	// Viewer 0 and 2 have input, viewer 1 is view-only.
	testing.expect(t, viewer_popover_sync(&popover, true, 3, keys[:], 0b101))
	testing.expect_value(t, popover.count, 3)
	testing.expect(t, popover.viewers[0].has_input && !popover.viewers[1].has_input && popover.viewers[2].has_input)

	// Disconnect refused while popover is closed.
	testing.expect_value(t, viewer_popover_disconnect_index(&popover, 1).kind, Viewer_Popover_Action_Kind.None)

	// Open popover.
	testing.expect_value(t, viewer_popover_mark_click(&popover).kind, Viewer_Popover_Action_Kind.Opened)

	// Out-of-range and negative viewer indexes refused cleanly with popover still open.
	for bad in ([5]int{-1, -100, 3, VIEWER_CAPACITY, max(int)}) {
		testing.expect_value(t, viewer_popover_disconnect_index(&popover, bad).kind, Viewer_Popover_Action_Kind.None)
		testing.expect(t, popover.open, "refused index must not alter popover state")
		_, _, _, _, ok := viewer_popover_row_rect(900, 120, 1280, 3, bad)
		testing.expect(t, !ok)
		_, _, _, _, btn_ok := viewer_popover_disconnect_rect(900, 120, 1280, 3, bad)
		testing.expect(t, !btn_ok)
	}

	// Zero key_head refused cleanly even for an in-range index.
	popover.viewers[1].key_head = 0
	testing.expect_value(t, viewer_popover_disconnect_index(&popover, 1).kind, Viewer_Popover_Action_Kind.None)
	testing.expect(t, popover.open)
	popover.viewers[1].key_head = k1

	// Click disconnect on viewer index 2 (last row) -> emits exact index 2 and key_head k2.
	bx, by, bw, bh, ok := viewer_popover_disconnect_rect(900, 120, 1280, 3, 2)
	testing.expect(t, ok)
	act := viewer_popover_click(&popover, 900, 120, 1280, bx + bw / 2, by + bh / 2)
	testing.expect_value(t, act.kind, Viewer_Popover_Action_Kind.Disconnect)
	testing.expect_value(t, act.viewer_index, 2)
	testing.expect_value(t, act.key_head, k2)
	testing.expect(t, !popover.open)

	// Over-capacity sync clamps cleanly to VIEWER_CAPACITY.
	many := [VIEWER_CAPACITY + 2]u64{k0, k1, k2, make_key_head(0xDE, 0xAD, 0xBE, 0xEF), 1, 2}
	testing.expect(t, viewer_popover_sync(&popover, true, VIEWER_CAPACITY + 2, many[:], 0xFF))
	testing.expect_value(t, popover.count, VIEWER_CAPACITY)
}

@(test)
viewer_popover_close_on_escape_outside_click_mark_reclick_and_capture_end :: proc(t: ^testing.T) {
	popover: Viewer_Popover
	viewer_popover_init(&popover)
	keys := [2]u64{make_key_head(0x01, 0x02, 0x03, 0x04), make_key_head(0x05, 0x06, 0x07, 0x08)}
	_ = viewer_popover_sync(&popover, true, 2, keys[:], 0b01)

	// 1. Escape closes an open popover.
	testing.expect_value(t, viewer_popover_mark_click(&popover).kind, Viewer_Popover_Action_Kind.Opened)
	testing.expect_value(t, viewer_popover_escape(&popover).kind, Viewer_Popover_Action_Kind.Closed)
	testing.expect(t, !popover.open)
	// Repeated Escape is a no-op.
	testing.expect_value(t, viewer_popover_escape(&popover).kind, Viewer_Popover_Action_Kind.None)

	// 2. Outside click closes an open popover.
	testing.expect_value(t, viewer_popover_mark_click(&popover).kind, Viewer_Popover_Action_Kind.Opened)
	cx, cy, cw, ch := viewer_popover_rect(900, 120, 1280, 2)
	testing.expect(t, cw == VIEWER_POPOVER_WIDTH && ch > TITLE)
	out_act := viewer_popover_click(&popover, 900, 120, 1280, cx - 1, cy + 10)
	testing.expect_value(t, out_act.kind, Viewer_Popover_Action_Kind.Closed)
	testing.expect(t, !popover.open)

	// 3. Clicking the mark a second time toggles closed.
	testing.expect_value(t, viewer_popover_mark_click(&popover).kind, Viewer_Popover_Action_Kind.Opened)
	testing.expect_value(t, viewer_popover_mark_click(&popover).kind, Viewer_Popover_Action_Kind.Closed)
	testing.expect(t, !popover.open)

	// 4. Syncing with capture_open = false automatically closes an open popover.
	testing.expect_value(t, viewer_popover_mark_click(&popover).kind, Viewer_Popover_Action_Kind.Opened)
	testing.expect(t, viewer_popover_sync(&popover, false, 2, keys[:], 0b01))
	testing.expect(t, !popover.open)
	testing.expect_value(t, popover.count, 0)

	// 5. Narrow screen clamps popover horizontally inside [PADDING, screen_width - width - PADDING].
	nx, ny, nw, _ := viewer_popover_rect(10, 20, 640, 1)
	testing.expect(t, nx >= PADDING && nx + nw <= 640 - PADDING && ny == HEIGHT)
}
