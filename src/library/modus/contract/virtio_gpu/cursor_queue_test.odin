#+build !freestanding
package virtio_gpu

import "core:testing"
import "modus:contract/byte_order"

@(test)
cursor_update_and_move_encode_decode_refuse_every_fault :: proc(t: ^testing.T) {
	buf: [UPDATE_CURSOR_SIZE]u8
	w_screen := u32(1920)
	h_screen := u32(1080)

	// Short buffer refused without writing.
	short_buf: [UPDATE_CURSOR_SIZE - 1]u8
	req := Update_Cursor_Request {
		pos         = {scanout_id = 0, x = 100, y = 200},
		resource_id = 7,
		hot_x       = 12,
		hot_y       = 63,
	}
	written, p := cursor_update_encode(req, w_screen, h_screen, short_buf[:])
	testing.expect_value(t, p, Cursor_Problem.Buffer_Too_Short)
	testing.expect_value(t, written, 0)

	// Zero resource ID refused on update & move.
	bad_req := req
	bad_req.resource_id = 0
	_, p = cursor_update_encode(bad_req, w_screen, h_screen, buf[:])
	testing.expect_value(t, p, Cursor_Problem.Zero_Resource_Id)

	// Hotspot out of 0..=63 refused.
	bad_req = req
	bad_req.hot_x = CURSOR_HOTSPOT_MAX + 1
	_, p = cursor_update_encode(bad_req, w_screen, h_screen, buf[:])
	testing.expect_value(t, p, Cursor_Problem.Hotspot_Out_Of_Range)
	bad_req = req
	bad_req.hot_y = CURSOR_HOTSPOT_MAX + 1
	_, p = cursor_update_encode(bad_req, w_screen, h_screen, buf[:])
	testing.expect_value(t, p, Cursor_Problem.Hotspot_Out_Of_Range)

	// Scanout out of range and position past scanout refused.
	bad_req = req
	bad_req.pos.scanout_id = MAX_SCANOUTS
	_, p = cursor_update_encode(bad_req, w_screen, h_screen, buf[:])
	testing.expect_value(t, p, Cursor_Problem.Scanout_Out_Of_Range)
	bad_req = req
	bad_req.pos.x = w_screen
	_, p = cursor_update_encode(bad_req, w_screen, h_screen, buf[:])
	testing.expect_value(t, p, Cursor_Problem.Position_Out_Of_Range)
	bad_req = req
	bad_req.pos.y = h_screen
	_, p = cursor_update_encode(bad_req, w_screen, h_screen, buf[:])
	testing.expect_value(t, p, Cursor_Problem.Position_Out_Of_Range)

	// Valid UPDATE_CURSOR round-trip.
	written, p = cursor_update_encode(req, w_screen, h_screen, buf[:])
	testing.expect_value(t, p, Cursor_Problem.None)
	testing.expect_value(t, written, UPDATE_CURSOR_SIZE)
	decoded, dp := cursor_update_decode(buf[:], w_screen, h_screen)
	testing.expect_value(t, dp, Cursor_Problem.None)
	testing.expect_value(t, decoded.header.command_type, Command_Type.Update_Cursor)
	testing.expect_value(t, decoded.resource_id, u32(7))
	testing.expect_value(t, decoded.hot_x, u32(12))
	testing.expect_value(t, decoded.hot_y, u32(63))
	testing.expect_value(t, decoded.pos.x, u32(100))
	testing.expect_value(t, decoded.pos.y, u32(200))

	// Wrong command type refused when decoded as MOVE_CURSOR.
	_, mp := cursor_move_decode(buf[:], w_screen, h_screen)
	testing.expect_value(t, mp, Cursor_Problem.Wrong_Command_Type)

	// Non-zero padding refused on decode.
	corrupt := buf
	byte_order.write_u32_little_endian(corrupt[:], CTRL_HEADER_SIZE + 12, 1)
	_, dp = cursor_update_decode(corrupt[:], w_screen, h_screen)
	testing.expect_value(t, dp, Cursor_Problem.Non_Zero_Padding)
	corrupt = buf
	byte_order.write_u32_little_endian(corrupt[:], CTRL_HEADER_SIZE + 28, 1)
	_, dp = cursor_update_decode(corrupt[:], w_screen, h_screen)
	testing.expect_value(t, dp, Cursor_Problem.Non_Zero_Padding)

	// Explicit hide encodes resource_id = 0 cleanly and decodes back.
	hw, hp := cursor_hide_encode(0, {}, 0, buf[:])
	testing.expect(t, hp == .None && hw == UPDATE_CURSOR_SIZE)
	hidden, hdp := cursor_update_decode(buf[:], w_screen, h_screen)
	testing.expect(t, hdp == .None && hidden.resource_id == 0 && hidden.hot_x == 0 && hidden.hot_y == 0)
}

@(test)
cursor_state_clamps_moves_and_avoids_redraw :: proc(t: ^testing.T) {
	cmd: [MOVE_CURSOR_SIZE]u8
	state: Cursor_State

	// Unconfigured cursor refuses move without mutating state.
	_, p := cursor_state_apply_move(&state, 10, 10, 1920, 1080, cmd[:])
	testing.expect_value(t, p, Cursor_Problem.Cursor_Not_Configured)
	testing.expect_value(t, state.moves_without_redraw, u64(0))

	state = Cursor_State{scanout_id = 0, resource_id = 42, hot_x = 4, hot_y = 4, visible = true}
	// Negative and past-edge coordinates clamp cleanly into [0..w-1] x [0..h-1].
	w, p2 := cursor_state_apply_move(&state, -50, 9999, 1920, 1080, cmd[:])
	testing.expect(t, p2 == .None && w == MOVE_CURSOR_SIZE)
	testing.expect_value(t, state.x, u32(0))
	testing.expect_value(t, state.y, u32(1079))
	testing.expect_value(t, state.moves_without_redraw, u64(1))

	moved, dp := cursor_move_decode(cmd[:], 1920, 1080)
	testing.expect_value(t, dp, Cursor_Problem.None)
	testing.expect_value(t, moved.header.command_type, Command_Type.Move_Cursor)
	testing.expect_value(t, moved.resource_id, u32(42))
	testing.expect_value(t, moved.pos.x, u32(0))
	testing.expect_value(t, moved.pos.y, u32(1079))
}
