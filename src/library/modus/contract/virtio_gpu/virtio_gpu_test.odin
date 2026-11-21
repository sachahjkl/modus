#+build !freestanding
package virtio_gpu

import "core:testing"
import "modus:contract/byte_order"

@(test)
border_enum_refusals :: proc(t: ^testing.T) {
	// Unknown command words: 0, 1, gaps, one past highest, max(u32).
	for word in ([]u32{0, 1, 0x00FF, 0x010A, 0x010D, 0x01FF, 0x0208, 0x10FF, 0x1104, 0x11FF, 0x1206, max(u32)}) {
		_, ok := command_type_of_word(word)
		testing.expectf(t, !ok, "unknown command word 0x%x must be refused", word)
	}
	// Every valid Command_Type round-trips through its wire word.
	for member in Command_Type {
		decoded, ok := command_type_of_word(u32(member))
		testing.expect(t, ok, "known Command_Type must decode")
		testing.expect_value(t, decoded, member)
	}

	// Unknown pixel format words: 0, 5, 66, 69, max(u32).
	for word in ([]u32{0, 5, 66, 69, max(u32)}) {
		_, ok := pixel_format_of_word(word)
		testing.expectf(t, !ok, "unknown pixel format %d must be refused", word)
	}
	for member in Pixel_Format {
		decoded, ok := pixel_format_of_word(u32(member))
		testing.expect(t, ok, "known Pixel_Format must decode")
		testing.expect_value(t, decoded, member)
	}

	// Unknown capset identifiers: 0, 6, max(u32).
	for word in ([]u32{0, 6, 0xFF, max(u32)}) {
		_, ok := capset_id_of_word(word)
		testing.expectf(t, !ok, "unknown capset id %d must be refused", word)
	}
	for member in Capset_Id {
		decoded, ok := capset_id_of_word(u32(member))
		testing.expect(t, ok, "known Capset_Id must decode")
		testing.expect_value(t, decoded, member)
	}

	// Unknown header flag bits and blob flag bits.
	for word in ([]u32{0x4, 0x8, 0x8000_0000, max(u32)}) {
		_, ok := header_flags_of_word(word)
		testing.expect(t, !ok, "unknown header flag bit must be refused")
	}
	for word in ([]u32{0x8, 0x10, 0x8000_0000, max(u32)}) {
		_, ok := blob_flags_of_word(word)
		testing.expect(t, !ok, "unknown blob flag bit must be refused")
	}

	// Service ring command border refuses 0 (None) and unknown words.
	for word in ([]u32{0, 5, 99, max(u32)}) {
		_, ok := service_command_of_ring_word(word)
		testing.expect(t, !ok, "invalid service command must be refused")
	}
	for member in Service_Command {
		if member == .None {
			continue
		}
		decoded, ok := service_command_of_ring_word(u32(member))
		testing.expect(t, ok, "known Service_Command must decode")
		testing.expect_value(t, decoded, member)
	}
}

@(test)
ctrl_header_edges_and_roundtrip :: proc(t: ^testing.T) {
	short: [CTRL_HEADER_SIZE - 1]u8
	_, enc_short := ctrl_header_encode(Ctrl_Header{command_type = .Get_Display_Info}, short[:])
	testing.expect_value(t, enc_short, Validation_Problem.Buffer_Too_Short)
	_, dec_short := ctrl_header_decode(short[:])
	testing.expect_value(t, dec_short, Validation_Problem.Buffer_Too_Short)
	_, dec_empty := ctrl_header_decode(nil)
	testing.expect_value(t, dec_empty, Validation_Problem.Buffer_Too_Short)

	wire: [CTRL_HEADER_SIZE]u8
	// Corrupt command type word.
	byte_order.write_u32_little_endian(wire[:], 0, 0xDEAD_BEEF)
	_, bad_type := ctrl_header_decode(wire[:])
	testing.expect_value(t, bad_type, Validation_Problem.Unknown_Command_Type)

	// Valid type, corrupt flags.
	byte_order.write_u32_little_endian(wire[:], 0, u32(Command_Type.Get_Display_Info))
	byte_order.write_u32_little_endian(wire[:], 4, 0xFFFF_FFFC)
	_, bad_flags := ctrl_header_decode(wire[:])
	testing.expect_value(t, bad_flags, Validation_Problem.Unknown_Header_Flags)

	// Valid type & flags, non-zero padding bytes.
	byte_order.write_u32_little_endian(wire[:], 4, 0)
	wire[21] = 1
	_, bad_pad := ctrl_header_decode(wire[:])
	testing.expect_value(t, bad_pad, Validation_Problem.Non_Zero_Padding)
	wire[21] = 0
	wire[23] = 0x80
	_, bad_pad2 := ctrl_header_decode(wire[:])
	testing.expect_value(t, bad_pad2, Validation_Problem.Non_Zero_Padding)

	// Valid roundtrip.
	expected := Ctrl_Header{
		command_type = .Submit_3D,
		flags        = {.Fence, .Info_Ring_Idx},
		fence_id     = 0x0123_4567_89AB_CDEF,
		ctx_id       = 7,
		ring_idx     = 3,
	}
	written, problem := ctrl_header_encode(expected, wire[:])
	testing.expect_value(t, problem, Validation_Problem.None)
	testing.expect_value(t, written, CTRL_HEADER_SIZE)
	decoded, dec_problem := ctrl_header_decode(wire[:])
	testing.expect_value(t, dec_problem, Validation_Problem.None)
	testing.expect_value(t, decoded, expected)
}

@(test)
display_info_and_nodata_responses :: proc(t: ^testing.T) {
	wire: [RESP_DISPLAY_INFO_SIZE]u8

	// Error response on nodata and display info.
	_, err_enc := ctrl_header_encode(Ctrl_Header{command_type = .Response_Err_Invalid_Resource_Id, fence_id = 42}, wire[:])
	testing.expect_value(t, err_enc, Validation_Problem.None)
	hdr, nodata_prob := nodata_response_decode(wire[:CTRL_HEADER_SIZE])
	testing.expect_value(t, nodata_prob, Validation_Problem.Device_Error_Response)
	testing.expect_value(t, hdr.command_type, Command_Type.Response_Err_Invalid_Resource_Id)

	resp_err, disp_err := display_info_response_decode(wire[:CTRL_HEADER_SIZE])
	testing.expect_value(t, disp_err, Validation_Problem.Device_Error_Response)
	testing.expect_value(t, resp_err.header.command_type, Command_Type.Response_Err_Invalid_Resource_Id)

	// Unexpected response type on nodata.
	_, _ = ctrl_header_encode(Ctrl_Header{command_type = .Response_Ok_Capset_Info}, wire[:])
	_, unexpected := nodata_response_decode(wire[:CTRL_HEADER_SIZE])
	testing.expect_value(t, unexpected, Validation_Problem.Unexpected_Response_Type)

	// Truncated display info with valid header.
	_, _ = ctrl_header_encode(Ctrl_Header{command_type = .Response_Ok_Display_Info}, wire[:])
	_, short_disp := display_info_response_decode(wire[:RESP_DISPLAY_INFO_SIZE - 1])
	testing.expect_value(t, short_disp, Validation_Problem.Buffer_Too_Short)

	// Valid Display_Info_Response roundtrip.
	sample := Display_Info_Response{
		header = Ctrl_Header{command_type = .Response_Ok_Display_Info, flags = {.Fence}, fence_id = 9},
	}
	sample.displays[0] = Display_One{rect = Rect{x = 0, y = 0, width = 1920, height = 1080}, enabled = 1, flags = 0}
	sample.displays[MAX_SCANOUTS - 1] = Display_One{rect = Rect{x = 1920, y = 0, width = 1280, height = 720}, enabled = 1, flags = 2}

	written, prob := display_info_response_encode(sample, wire[:])
	testing.expect_value(t, prob, Validation_Problem.None)
	testing.expect_value(t, written, RESP_DISPLAY_INFO_SIZE)

	decoded, dec_prob := display_info_response_decode(wire[:])
	testing.expect_value(t, dec_prob, Validation_Problem.None)
	testing.expect_value(t, decoded.displays[0], sample.displays[0])
	testing.expect_value(t, decoded.displays[MAX_SCANOUTS - 1], sample.displays[MAX_SCANOUTS - 1])
}

@(test)
resource_2d_lifecycle_refusals_and_roundtrip :: proc(t: ^testing.T) {
	wire: [4096]u8

	// Resource_Create_2D refusals: resource_id 0, zero width/height, over max dimension, short buffer.
	_, p0 := resource_create_2d_encode(0, .B8G8R8X8_Unorm, 1920, 1080, wire[:])
	testing.expect_value(t, p0, Validation_Problem.Zero_Resource_Id)
	_, p1 := resource_create_2d_encode(1, .B8G8R8X8_Unorm, 0, 1080, wire[:])
	testing.expect_value(t, p1, Validation_Problem.Zero_Dimensions)
	_, p2 := resource_create_2d_encode(1, .B8G8R8X8_Unorm, 1920, 0, wire[:])
	testing.expect_value(t, p2, Validation_Problem.Zero_Dimensions)
	_, p3 := resource_create_2d_encode(1, .B8G8R8X8_Unorm, MAX_RESOURCE_DIMENSION + 1, 1080, wire[:])
	testing.expect_value(t, p3, Validation_Problem.Dimension_Too_Large)
	_, p4 := resource_create_2d_encode(1, .B8G8R8X8_Unorm, 1, MAX_RESOURCE_DIMENSION + 1, wire[:])
	testing.expect_value(t, p4, Validation_Problem.Dimension_Too_Large)
	_, p5 := resource_create_2d_encode(1, .B8G8R8X8_Unorm, 1, 1, wire[:RESOURCE_CREATE_2D_SIZE - 1])
	testing.expect_value(t, p5, Validation_Problem.Buffer_Too_Short)

	// Valid Resource_Create_2D at exact upper bound & normal size.
	w_create, ok_create := resource_create_2d_encode(1, .B8G8R8X8_Unorm, 1920, 1080, wire[:], fence_id = 11)
	testing.expect_value(t, ok_create, Validation_Problem.None)
	testing.expect_value(t, w_create, RESOURCE_CREATE_2D_SIZE)
	dec_create, dec_create_prob := resource_create_2d_decode(wire[:w_create])
	testing.expect_value(t, dec_create_prob, Validation_Problem.None)
	testing.expect_value(t, dec_create.resource_id, u32(1))
	testing.expect_value(t, dec_create.format, Pixel_Format.B8G8R8X8_Unorm)
	testing.expect_value(t, dec_create.width, u32(1920))
	testing.expect_value(t, dec_create.height, u32(1080))
	testing.expect_value(t, dec_create.header.fence_id, u64(11))

	// Corrupt format on wire is refused by decoder.
	byte_order.write_u32_little_endian(wire[:], 28, 999)
	_, bad_fmt := resource_create_2d_decode(wire[:w_create])
	testing.expect_value(t, bad_fmt, Validation_Problem.Unknown_Pixel_Format)

	// Resource_Attach_Backing refusals: resource_id 0, empty entries, > MAX_BACKING_ENTRIES, zero length, address overflow.
	_, b0 := resource_attach_backing_encode(0, []Mem_Entry{{address = 0x1000, length = 4096}}, wire[:])
	testing.expect_value(t, b0, Validation_Problem.Zero_Resource_Id)
	_, b1 := resource_attach_backing_encode(1, nil, wire[:])
	testing.expect_value(t, b1, Validation_Problem.Empty_Backing_Entries)
	too_many: [MAX_BACKING_ENTRIES + 1]Mem_Entry
	for &e in too_many {
		e = {address = 0x1000, length = 4096}
	}
	_, b2 := resource_attach_backing_encode(1, too_many[:], wire[:])
	testing.expect_value(t, b2, Validation_Problem.Too_Many_Backing_Entries)
	_, b3 := resource_attach_backing_encode(1, []Mem_Entry{{address = 0x1000, length = 0}}, wire[:])
	testing.expect_value(t, b3, Validation_Problem.Zero_Backing_Length)
	_, b4 := resource_attach_backing_encode(1, []Mem_Entry{{address = max(u64) - 10, length = 11}}, wire[:])
	testing.expect_value(t, b4, Validation_Problem.Backing_Address_Overflow)

	// Valid Resource_Attach_Backing roundtrip.
	backing := [2]Mem_Entry{
		{address = 0x0010_0000, length = 4096 * 1024},
		{address = 0x0050_0000, length = 4096 * 1024},
	}
	w_attach, ok_attach := resource_attach_backing_encode(1, backing[:], wire[:])
	testing.expect_value(t, ok_attach, Validation_Problem.None)
	testing.expect_value(t, w_attach, RESOURCE_ATTACH_BACKING_HEADER_SIZE + 2 * MEM_ENTRY_SIZE)
	decoded_entries: [4]Mem_Entry
	_, dec_res_id, dec_count, dec_attach_prob := resource_attach_backing_decode(wire[:w_attach], decoded_entries[:])
	testing.expect_value(t, dec_attach_prob, Validation_Problem.None)
	testing.expect_value(t, dec_res_id, u32(1))
	testing.expect_value(t, dec_count, u32(2))
	testing.expect_value(t, decoded_entries[0], backing[0])
	testing.expect_value(t, decoded_entries[1], backing[1])

	// Set_Scanout refusals: scanout_id >= MAX_SCANOUTS, resource_id == 0, rect out of bounds, u32 wraparound.
	_, s0 := set_scanout_encode(MAX_SCANOUTS, 1, Rect{0, 0, 1920, 1080}, 1920, 1080, wire[:])
	testing.expect_value(t, s0, Validation_Problem.Scanout_Id_Out_Of_Range)
	_, s1 := set_scanout_encode(0, 0, Rect{0, 0, 1920, 1080}, 1920, 1080, wire[:])
	testing.expect_value(t, s1, Validation_Problem.Zero_Resource_Id)
	_, s2 := set_scanout_encode(0, 1, Rect{0, 0, 1921, 1080}, 1920, 1080, wire[:])
	testing.expect_value(t, s2, Validation_Problem.Rect_Out_Of_Bounds)
	_, s3 := set_scanout_encode(0, 1, Rect{max(u32), 0, 2, 1}, 1920, 1080, wire[:])
	testing.expect_value(t, s3, Validation_Problem.Rect_Out_Of_Bounds)
	_, s4 := set_scanout_encode(0, 1, Rect{0, 0, 0, 1080}, 1920, 1080, wire[:])
	testing.expect_value(t, s4, Validation_Problem.Zero_Dimensions)

	// Valid Set_Scanout roundtrip.
	w_scan, ok_scan := set_scanout_encode(0, 1, Rect{0, 0, 1920, 1080}, 1920, 1080, wire[:])
	testing.expect_value(t, ok_scan, Validation_Problem.None)
	testing.expect_value(t, w_scan, SET_SCANOUT_SIZE)
	dec_scan, dec_scan_prob := set_scanout_decode(wire[:w_scan], 1920, 1080)
	testing.expect_value(t, dec_scan_prob, Validation_Problem.None)
	testing.expect_value(t, dec_scan.scanout_id, u32(0))
	testing.expect_value(t, dec_scan.resource_id, u32(1))
	testing.expect_value(t, dec_scan.rect, Rect{0, 0, 1920, 1080})

	// Transfer_To_Host_2D & Resource_Flush refusals + roundtrips.
	_, t0 := transfer_to_host_2d_encode(0, Rect{10, 20, 100, 50}, 0, 1920, 1080, wire[:])
	testing.expect_value(t, t0, Validation_Problem.Zero_Resource_Id)
	_, t1 := transfer_to_host_2d_encode(1, Rect{1900, 0, 21, 10}, 0, 1920, 1080, wire[:])
	testing.expect_value(t, t1, Validation_Problem.Rect_Out_Of_Bounds)

	w_xfer, ok_xfer := transfer_to_host_2d_encode(1, Rect{10, 20, 100, 50}, (20 * 1920 + 10) * 4, 1920, 1080, wire[:])
	testing.expect_value(t, ok_xfer, Validation_Problem.None)
	testing.expect_value(t, w_xfer, TRANSFER_TO_HOST_2D_SIZE)
	dec_xfer, dec_xfer_prob := transfer_to_host_2d_decode(wire[:w_xfer], 1920, 1080)
	testing.expect_value(t, dec_xfer_prob, Validation_Problem.None)
	testing.expect_value(t, dec_xfer.offset, u64((20 * 1920 + 10) * 4))
	testing.expect_value(t, dec_xfer.rect, Rect{10, 20, 100, 50})

	_, f0 := resource_flush_encode(0, Rect{0, 0, 10, 10}, 1920, 1080, wire[:])
	testing.expect_value(t, f0, Validation_Problem.Zero_Resource_Id)
	_, f1 := resource_flush_encode(1, Rect{0, 1080, 10, 1}, 1920, 1080, wire[:])
	testing.expect_value(t, f1, Validation_Problem.Rect_Out_Of_Bounds)

	w_flush, ok_flush := resource_flush_encode(1, Rect{10, 20, 100, 50}, 1920, 1080, wire[:])
	testing.expect_value(t, ok_flush, Validation_Problem.None)
	testing.expect_value(t, w_flush, RESOURCE_FLUSH_SIZE)
	dec_flush, dec_flush_prob := resource_flush_decode(wire[:w_flush], 1920, 1080)
	testing.expect_value(t, dec_flush_prob, Validation_Problem.None)
	testing.expect_value(t, dec_flush.rect, Rect{10, 20, 100, 50})

	// Resource_Unref refusal + roundtrip.
	_, u0 := resource_unref_encode(0, wire[:])
	testing.expect_value(t, u0, Validation_Problem.Zero_Resource_Id)
	w_unref, ok_unref := resource_unref_encode(1, wire[:])
	testing.expect_value(t, ok_unref, Validation_Problem.None)
	dec_unref, dec_unref_prob := resource_unref_decode(wire[:w_unref])
	testing.expect_value(t, dec_unref_prob, Validation_Problem.None)
	testing.expect_value(t, dec_unref.resource_id, u32(1))
}

@(test)
venus_context_blob_and_submit_3d_framing :: proc(t: ^testing.T) {
	wire: [4096]u8

	// Get_Capset_Info request & Capset_Info_Response (Venus = 4).
	w_cap, ok_cap := get_capset_info_encode(0, wire[:])
	testing.expect_value(t, ok_cap, Validation_Problem.None)
	testing.expect_value(t, w_cap, GET_CAPSET_INFO_SIZE)
	dec_cap_req, dec_cap_req_prob := get_capset_info_decode(wire[:w_cap])
	testing.expect_value(t, dec_cap_req_prob, Validation_Problem.None)
	testing.expect_value(t, dec_cap_req.capset_index, u32(0))

	cap_resp := Capset_Info_Response{
		header             = Ctrl_Header{command_type = .Response_Ok_Capset_Info},
		capset_id          = .Venus,
		capset_max_version = 1,
		capset_max_size    = 4096,
	}
	w_cap_resp, ok_cap_resp := capset_info_response_encode(cap_resp, wire[:])
	testing.expect_value(t, ok_cap_resp, Validation_Problem.None)
	testing.expect_value(t, w_cap_resp, RESP_CAPSET_INFO_SIZE)
	dec_cap_resp, dec_cap_resp_prob := capset_info_response_decode(wire[:w_cap_resp])
	testing.expect_value(t, dec_cap_resp_prob, Validation_Problem.None)
	testing.expect_value(t, dec_cap_resp.capset_id, Capset_Id.Venus)
	testing.expect_value(t, dec_cap_resp.capset_max_version, u32(1))
	testing.expect_value(t, dec_cap_resp.capset_max_size, u32(4096))

	// Corrupt capset_id on wire is refused.
	byte_order.write_u32_little_endian(wire[:], 24, 99)
	_, bad_cap := capset_info_response_decode(wire[:w_cap_resp])
	testing.expect_value(t, bad_cap, Validation_Problem.Unknown_Capset_Id)

	// Ctx_Create refusals: ctx_id 0, name > 64 bytes, unknown upper context_init bits.
	_, c0 := ctx_create_encode(0, .Venus, "modus-venus", wire[:])
	testing.expect_value(t, c0, Validation_Problem.Zero_Context_Id)
	long_name: [CTX_CREATE_NAME_BYTES + 1]u8
	for &ch in long_name {
		ch = 'a'
	}
	_, c1 := ctx_create_encode(1, .Venus, string(long_name[:]), wire[:])
	testing.expect_value(t, c1, Validation_Problem.Name_Too_Long)

	w_ctx, ok_ctx := ctx_create_encode(3, .Venus, "modus-venus", wire[:], fence_id = 77)
	testing.expect_value(t, ok_ctx, Validation_Problem.None)
	testing.expect_value(t, w_ctx, CTX_CREATE_SIZE)
	dec_ctx, dec_ctx_prob := ctx_create_decode(wire[:w_ctx])
	testing.expect_value(t, dec_ctx_prob, Validation_Problem.None)
	testing.expect_value(t, dec_ctx.header.ctx_id, u32(3))
	testing.expect_value(t, dec_ctx.capset_id, Capset_Id.Venus)
	testing.expect_value(t, dec_ctx.name_length, u32(len("modus-venus")))
	testing.expect_value(t, string(dec_ctx.debug_name[:dec_ctx.name_length]), "modus-venus")

	// Upper bits set in context_init must be refused.
	byte_order.write_u32_little_endian(wire[:], 28, u32(Capset_Id.Venus) | 0x0001_0000)
	_, bad_ctx_init := ctx_create_decode(wire[:w_ctx])
	testing.expect_value(t, bad_ctx_init, Validation_Problem.Unknown_Capset_Id)

	// Ctx_Destroy refusal on 0 + valid encode.
	_, cd0 := ctx_destroy_encode(0, wire[:])
	testing.expect_value(t, cd0, Validation_Problem.Zero_Context_Id)
	w_cd, ok_cd := ctx_destroy_encode(3, wire[:])
	testing.expect_value(t, ok_cd, Validation_Problem.None)
	testing.expect_value(t, w_cd, CTX_DESTROY_SIZE)

	// Resource_Create_Blob refusals + roundtrip.
	_, bl0 := resource_create_blob_encode(3, 0, .Host3D, {.Use_Mappable}, 0, 1, 65536, wire[:])
	testing.expect_value(t, bl0, Validation_Problem.Zero_Resource_Id)
	_, bl1 := resource_create_blob_encode(3, 5, .Host3D, {.Use_Mappable}, 0, 1, 0, wire[:])
	testing.expect_value(t, bl1, Validation_Problem.Zero_Blob_Size)
	_, bl2 := resource_create_blob_encode(3, 5, .Host3D, {.Use_Mappable}, MAX_BACKING_ENTRIES + 1, 1, 4096, wire[:])
	testing.expect_value(t, bl2, Validation_Problem.Too_Many_Backing_Entries)

	w_blob, ok_blob := resource_create_blob_encode(3, 5, .Host3D_Guest, {.Use_Mappable, .Use_Shareable}, 1, 99, 65536, wire[:])
	testing.expect_value(t, ok_blob, Validation_Problem.None)
	testing.expect_value(t, w_blob, RESOURCE_CREATE_BLOB_SIZE)
	dec_blob, dec_blob_prob := resource_create_blob_decode(wire[:w_blob])
	testing.expect_value(t, dec_blob_prob, Validation_Problem.None)
	testing.expect_value(t, dec_blob.resource_id, u32(5))
	testing.expect_value(t, dec_blob.blob_memory, Blob_Memory.Host3D_Guest)
	testing.expect_value(t, dec_blob.blob_flags, Blob_Flags{.Use_Mappable, .Use_Shareable})
	testing.expect_value(t, dec_blob.blob_id, u64(99))
	testing.expect_value(t, dec_blob.size, u64(65536))

	// Submit_3D refusals: ctx_id 0, empty stream, unaligned byte length, truncated buffer.
	_, sub0 := submit_3d_encode(0, []u8{1, 2, 3, 4}, wire[:])
	testing.expect_value(t, sub0, Validation_Problem.Zero_Context_Id)
	_, sub1 := submit_3d_encode(3, nil, wire[:])
	testing.expect_value(t, sub1, Validation_Problem.Submit_Size_Invalid)
	_, sub2 := submit_3d_encode(3, []u8{1, 2, 3}, wire[:])
	testing.expect_value(t, sub2, Validation_Problem.Submit_Size_Invalid)
	_, sub3 := submit_3d_encode(3, []u8{1, 2, 3, 4}, wire[:SUBMIT_3D_HEADER_SIZE + 3])
	testing.expect_value(t, sub3, Validation_Problem.Buffer_Too_Short)

	venus_words := [12]u8{0x01, 0x00, 0x00, 0x00, 0x10, 0x20, 0x30, 0x40, 0xAA, 0xBB, 0xCC, 0xDD}
	w_sub, ok_sub := submit_3d_encode(3, venus_words[:], wire[:], fence_id = 88)
	testing.expect_value(t, ok_sub, Validation_Problem.None)
	testing.expect_value(t, w_sub, SUBMIT_3D_HEADER_SIZE + len(venus_words))
	dec_sub, dec_sub_prob := submit_3d_decode(wire[:w_sub])
	testing.expect_value(t, dec_sub_prob, Validation_Problem.None)
	testing.expect_value(t, dec_sub.header.ctx_id, u32(3))
	testing.expect_value(t, dec_sub.header.fence_id, u64(88))
	testing.expect_value(t, len(dec_sub.payload), len(venus_words))
	for index in 0 ..< len(venus_words) {
		testing.expect_value(t, dec_sub.payload[index], venus_words[index])
	}

	// Truncating 1 byte off Submit_3D wire fails decode.
	_, trunc_sub := submit_3d_decode(wire[:w_sub - 1])
	testing.expect_value(t, trunc_sub, Validation_Problem.Buffer_Too_Short)
}
