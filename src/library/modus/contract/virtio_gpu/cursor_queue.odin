// VirtIO-GPU 1.2 hardware cursor queue framing (VIRTIO 1.2, section 5.7.6.10;
// src/md/infrastructure/whole_frame.md).
//
// Encodes and decodes UPDATE_CURSOR (0x0300) and MOVE_CURSOR (0x0301) commands
// for the dedicated cursor virtqueue (CURSOR_QUEUE_INDEX == 1) so pointer
// movement updates hardware scanout overlays with zero compositor redraw frames.
// All procedures are contextless and write nothing on refusal.
package virtio_gpu

import "modus:contract/byte_order"

// Format property: VirtIO-GPU 1.2 hardware cursor resources are strictly 64x64
// 32-bit BGRA/ARGB pixels (16384 bytes) with hotspots in 0..=63.
CURSOR_DIMENSION :: u32(64)
CURSOR_PIXEL_BYTES :: u32(4)
CURSOR_IMAGE_BYTES :: u32(CURSOR_DIMENSION * CURSOR_DIMENSION * CURSOR_PIXEL_BYTES)
CURSOR_HOTSPOT_MAX :: u32(CURSOR_DIMENSION - 1)

// Format property: wire byte lengths of virtio_gpu_cursor_pos and
// virtio_gpu_update_cursor (shared by UPDATE_CURSOR and MOVE_CURSOR).
CURSOR_POS_SIZE :: 16
UPDATE_CURSOR_SIZE :: CTRL_HEADER_SIZE + CURSOR_POS_SIZE + 16
MOVE_CURSOR_SIZE :: UPDATE_CURSOR_SIZE

#assert(UPDATE_CURSOR_SIZE == 56)

// Closed refusal set returned by VirtIO-GPU cursor queue procedures.
Cursor_Problem :: enum u8 {
	None                  = 0,
	Buffer_Too_Short      = 1,
	Invalid_Header        = 2,
	Wrong_Command_Type    = 3,
	Scanout_Out_Of_Range  = 4,
	Hotspot_Out_Of_Range  = 5,
	Position_Out_Of_Range = 6,
	Non_Zero_Padding      = 7,
	Zero_Resource_Id      = 8,
	Invalid_Dimensions    = 9,
	Cursor_Not_Configured = 10,
}

// Wire coordinates of a cursor on one scanout (virtio_gpu_cursor_pos).
Cursor_Pos :: struct {
	scanout_id: u32,
	x:          u32,
	y:          u32,
}

// Decoded UPDATE_CURSOR command (virtio_gpu_update_cursor, type 0x0300).
Update_Cursor_Request :: struct {
	header:      Ctrl_Header,
	pos:         Cursor_Pos,
	resource_id: u32,
	hot_x:       u32,
	hot_y:       u32,
}

// Decoded MOVE_CURSOR command (virtio_gpu_update_cursor, type 0x0301).
Move_Cursor_Request :: struct {
	header:      Ctrl_Header,
	pos:         Cursor_Pos,
	resource_id: u32,
}

// Hardware cursor overlay state tracked by the GPU device service / compositor.
Cursor_State :: struct {
	scanout_id:           u32,
	resource_id:          u32,
	hot_x:                u32,
	hot_y:                u32,
	x:                    u32,
	y:                    u32,
	visible:              bool,
	moves_without_redraw: u64,
}

// cursor_clamp_position clamps signed pointer coordinates (x, y) into
// [0..scanout_width - 1] x [0..scanout_height - 1], refusing invalid scanouts.
cursor_clamp_position :: proc "contextless" (
	x: i32,
	y: i32,
	scanout_width: u32,
	scanout_height: u32,
) -> (
	clamped_x: u32,
	clamped_y: u32,
	problem: Cursor_Problem,
) {
	if dimensions_validate(scanout_width, scanout_height) != .None {
		return 0, 0, .Invalid_Dimensions
	}
	cx := x
	cy := y
	if cx < 0 {
		cx = 0
	}
	if cy < 0 {
		cy = 0
	}
	ux := u32(cx)
	uy := u32(cy)
	if ux >= scanout_width {
		ux = scanout_width - 1
	}
	if uy >= scanout_height {
		uy = scanout_height - 1
	}
	return ux, uy, .None
}

@(private = "file")
validate_cursor_pos :: proc "contextless" (pos: Cursor_Pos, scanout_width, scanout_height: u32) -> Cursor_Problem {
	if dimensions_validate(scanout_width, scanout_height) != .None {
		return .Invalid_Dimensions
	}
	if pos.scanout_id >= MAX_SCANOUTS {
		return .Scanout_Out_Of_Range
	}
	if pos.x >= scanout_width || pos.y >= scanout_height {
		return .Position_Out_Of_Range
	}
	return .None
}

@(private = "file")
write_cursor_body :: proc "contextless" (
	dst: []u8,
	pos: Cursor_Pos,
	resource_id: u32,
	hot_x: u32,
	hot_y: u32,
) {
	byte_order.write_u32_little_endian(dst, CTRL_HEADER_SIZE + 0, pos.scanout_id)
	byte_order.write_u32_little_endian(dst, CTRL_HEADER_SIZE + 4, pos.x)
	byte_order.write_u32_little_endian(dst, CTRL_HEADER_SIZE + 8, pos.y)
	byte_order.write_u32_little_endian(dst, CTRL_HEADER_SIZE + 12, 0) // pos.padding
	byte_order.write_u32_little_endian(dst, CTRL_HEADER_SIZE + 16, resource_id)
	byte_order.write_u32_little_endian(dst, CTRL_HEADER_SIZE + 20, hot_x)
	byte_order.write_u32_little_endian(dst, CTRL_HEADER_SIZE + 24, hot_y)
	byte_order.write_u32_little_endian(dst, CTRL_HEADER_SIZE + 28, 0) // trailing padding
}

// cursor_update_encode validates and encodes an UPDATE_CURSOR command for a
// visible 64x64 cursor resource. Writes nothing on refusal.
cursor_update_encode :: proc "contextless" (
	req: Update_Cursor_Request,
	scanout_width: u32,
	scanout_height: u32,
	dst: []u8,
) -> (
	written: int,
	problem: Cursor_Problem,
) {
	if len(dst) < UPDATE_CURSOR_SIZE {
		return 0, .Buffer_Too_Short
	}
	if req.resource_id == 0 {
		return 0, .Zero_Resource_Id
	}
	if req.hot_x > CURSOR_HOTSPOT_MAX || req.hot_y > CURSOR_HOTSPOT_MAX {
		return 0, .Hotspot_Out_Of_Range
	}
	if pos_p := validate_cursor_pos(req.pos, scanout_width, scanout_height); pos_p != .None {
		return 0, pos_p
	}
	hdr := req.header
	hdr.command_type = .Update_Cursor
	if _, hdr_p := ctrl_header_encode(hdr, dst); hdr_p != .None {
		return 0, .Invalid_Header
	}
	write_cursor_body(dst, req.pos, req.resource_id, req.hot_x, req.hot_y)
	return UPDATE_CURSOR_SIZE, .None
}

// cursor_hide_encode encodes an UPDATE_CURSOR command with resource_id = 0 and
// zero hotspot to disable the hardware cursor on scanout_id.
cursor_hide_encode :: proc "contextless" (
	scanout_id: u32,
	flags: Header_Flags,
	fence_id: u64,
	dst: []u8,
) -> (
	written: int,
	problem: Cursor_Problem,
) {
	if len(dst) < UPDATE_CURSOR_SIZE {
		return 0, .Buffer_Too_Short
	}
	if scanout_id >= MAX_SCANOUTS {
		return 0, .Scanout_Out_Of_Range
	}
	hdr := Ctrl_Header{command_type = .Update_Cursor, flags = flags, fence_id = fence_id}
	if _, hdr_p := ctrl_header_encode(hdr, dst); hdr_p != .None {
		return 0, .Invalid_Header
	}
	write_cursor_body(dst, Cursor_Pos{scanout_id = scanout_id}, 0, 0, 0)
	return UPDATE_CURSOR_SIZE, .None
}

// cursor_update_decode validates and decodes a 56-byte UPDATE_CURSOR command.
cursor_update_decode :: proc "contextless" (
	src: []u8,
	scanout_width: u32,
	scanout_height: u32,
) -> (
	req: Update_Cursor_Request,
	problem: Cursor_Problem,
) {
	if len(src) < UPDATE_CURSOR_SIZE {
		return {}, .Buffer_Too_Short
	}
	hdr, hdr_p := ctrl_header_decode(src)
	if hdr_p != .None {
		return {}, .Invalid_Header
	}
	if hdr.command_type != .Update_Cursor {
		return {}, .Wrong_Command_Type
	}
	pos_pad := byte_order.read_u32_little_endian(src, CTRL_HEADER_SIZE + 12)
	end_pad := byte_order.read_u32_little_endian(src, CTRL_HEADER_SIZE + 28)
	if pos_pad != 0 || end_pad != 0 {
		return {}, .Non_Zero_Padding
	}
	pos := Cursor_Pos {
		scanout_id = byte_order.read_u32_little_endian(src, CTRL_HEADER_SIZE + 0),
		x          = byte_order.read_u32_little_endian(src, CTRL_HEADER_SIZE + 4),
		y          = byte_order.read_u32_little_endian(src, CTRL_HEADER_SIZE + 8),
	}
	if pos_p := validate_cursor_pos(pos, scanout_width, scanout_height); pos_p != .None {
		return {}, pos_p
	}
	res_id := byte_order.read_u32_little_endian(src, CTRL_HEADER_SIZE + 16)
	hot_x := byte_order.read_u32_little_endian(src, CTRL_HEADER_SIZE + 20)
	hot_y := byte_order.read_u32_little_endian(src, CTRL_HEADER_SIZE + 24)
	if res_id == 0 {
		if hot_x != 0 || hot_y != 0 {
			return {}, .Hotspot_Out_Of_Range
		}
	} else if hot_x > CURSOR_HOTSPOT_MAX || hot_y > CURSOR_HOTSPOT_MAX {
		return {}, .Hotspot_Out_Of_Range
	}
	return Update_Cursor_Request{header = hdr, pos = pos, resource_id = res_id, hot_x = hot_x, hot_y = hot_y}, .None
}

// cursor_move_encode validates and encodes a MOVE_CURSOR command (0x0301) with
// zero hotspot fields so pointer moves bypass full compositor redraws.
cursor_move_encode :: proc "contextless" (
	req: Move_Cursor_Request,
	scanout_width: u32,
	scanout_height: u32,
	dst: []u8,
) -> (
	written: int,
	problem: Cursor_Problem,
) {
	if len(dst) < MOVE_CURSOR_SIZE {
		return 0, .Buffer_Too_Short
	}
	if req.resource_id == 0 {
		return 0, .Zero_Resource_Id
	}
	if pos_p := validate_cursor_pos(req.pos, scanout_width, scanout_height); pos_p != .None {
		return 0, pos_p
	}
	hdr := req.header
	hdr.command_type = .Move_Cursor
	if _, hdr_p := ctrl_header_encode(hdr, dst); hdr_p != .None {
		return 0, .Invalid_Header
	}
	write_cursor_body(dst, req.pos, req.resource_id, 0, 0)
	return MOVE_CURSOR_SIZE, .None
}

// cursor_move_decode validates and decodes a 56-byte MOVE_CURSOR command.
cursor_move_decode :: proc "contextless" (
	src: []u8,
	scanout_width: u32,
	scanout_height: u32,
) -> (
	req: Move_Cursor_Request,
	problem: Cursor_Problem,
) {
	if len(src) < MOVE_CURSOR_SIZE {
		return {}, .Buffer_Too_Short
	}
	hdr, hdr_p := ctrl_header_decode(src)
	if hdr_p != .None {
		return {}, .Invalid_Header
	}
	if hdr.command_type != .Move_Cursor {
		return {}, .Wrong_Command_Type
	}
	pos_pad := byte_order.read_u32_little_endian(src, CTRL_HEADER_SIZE + 12)
	hot_x := byte_order.read_u32_little_endian(src, CTRL_HEADER_SIZE + 20)
	hot_y := byte_order.read_u32_little_endian(src, CTRL_HEADER_SIZE + 24)
	end_pad := byte_order.read_u32_little_endian(src, CTRL_HEADER_SIZE + 28)
	if pos_pad != 0 || hot_x != 0 || hot_y != 0 || end_pad != 0 {
		return {}, .Non_Zero_Padding
	}
	pos := Cursor_Pos {
		scanout_id = byte_order.read_u32_little_endian(src, CTRL_HEADER_SIZE + 0),
		x          = byte_order.read_u32_little_endian(src, CTRL_HEADER_SIZE + 4),
		y          = byte_order.read_u32_little_endian(src, CTRL_HEADER_SIZE + 8),
	}
	if pos_p := validate_cursor_pos(pos, scanout_width, scanout_height); pos_p != .None {
		return {}, pos_p
	}
	res_id := byte_order.read_u32_little_endian(src, CTRL_HEADER_SIZE + 16)
	if res_id == 0 {
		return {}, .Zero_Resource_Id
	}
	return Move_Cursor_Request{header = hdr, pos = pos, resource_id = res_id}, .None
}

// cursor_state_apply_move clamps (raw_x, raw_y) to the scanout bounds, emits a
// MOVE_CURSOR command into out_cmd, and advances state without mutating on refusal.
cursor_state_apply_move :: proc "contextless" (
	state: ^Cursor_State,
	raw_x: i32,
	raw_y: i32,
	scanout_width: u32,
	scanout_height: u32,
	out_cmd: []u8,
) -> (
	written: int,
	problem: Cursor_Problem,
) {
	if state == nil || !state.visible || state.resource_id == 0 {
		return 0, .Cursor_Not_Configured
	}
	cx, cy, clamp_p := cursor_clamp_position(raw_x, raw_y, scanout_width, scanout_height)
	if clamp_p != .None {
		return 0, clamp_p
	}
	req := Move_Cursor_Request {
		pos         = {scanout_id = state.scanout_id, x = cx, y = cy},
		resource_id = state.resource_id,
	}
	w, enc_p := cursor_move_encode(req, scanout_width, scanout_height, out_cmd)
	if enc_p != .None {
		return 0, enc_p
	}
	state.x = cx
	state.y = cy
	state.moves_without_redraw += 1
	return w, .None
}
