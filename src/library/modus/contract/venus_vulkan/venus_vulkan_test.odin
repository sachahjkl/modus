#+build !freestanding
package venus_vulkan

import "core:testing"
import "modus:contract/byte_order"
import "modus:contract/virtio_gpu"
import "modus:contract/webgpu_subset"

@(private = "file")
minimal_valid_spirv_bytes :: proc() -> [40]u8 {
	words := [10]u32{
		webgpu_subset.SPIRV_MAGIC,
		0x0001_0600,
		0x000D_0001,
		8,
		0,
		(2 << 16) | 17, 1,
		(3 << 16) | 14, 0, 1,
	}
	bytes: [40]u8
	for word, idx in words {
		byte_order.write_u32_little_endian(bytes[:], idx * 4, word)
	}
	return bytes
}

@(test)
enum_and_flag_borders :: proc(t: ^testing.T) {
	// Zero, one past the last member, and max(u32) must be refused.
	for word in ([]u32{0, 31, 999, max(u32)}) {
		_, ok := command_type_of_word(word)
		testing.expect(t, !ok, "unknown Venus command type must be refused")
	}
	for word in ([]u32{2, 1 << 31, max(u32)}) {
		_, ok := command_flags_of_word(word)
		testing.expect(t, !ok, "unknown Venus command flags must be refused")
	}
	for word in ([]u32{3, 100, max(u32)}) {
		_, ok := ring_status_of_word(word)
		testing.expect(t, !ok, "unknown Venus ring status must be refused")
	}

	// Every valid enum member decodes cleanly.
	for member in Venus_Command_Type {
		decoded, ok := command_type_of_word(u32(member))
		testing.expect(t, ok, "known Venus command type must decode")
		testing.expect_value(t, decoded, member)
	}
	for status in Venus_Ring_Status {
		decoded, ok := ring_status_of_word(u32(status))
		testing.expect(t, ok, "known Venus ring status must decode")
		testing.expect_value(t, decoded, status)
	}
}

@(test)
ring_header_border_refusals_and_roundtrip :: proc(t: ^testing.T) {
	base := Venus_Ring_Header{
		magic         = VENUS_RING_MAGIC,
		version       = VENUS_RING_VERSION,
		head          = 64,
		tail          = 128,
		status        = .Active,
		buffer_size   = 4096,
		buffer_offset = 64,
		extra_offset  = 64 + 4096,
		extra_size    = 1024,
		ring_id       = 7,
	}
	total_blob := u64(64 + 4096 + 1024)
	wire: [VENUS_RING_HEADER_SIZE]u8

	// Buffer too short.
	_, short_prob := ring_header_encode(base, total_blob, wire[:VENUS_RING_HEADER_SIZE - 1])
	testing.expect_value(t, short_prob, Venus_Problem.Buffer_Too_Short)

	// Bad magic & bad version.
	bad := base
	bad.magic = 0
	testing.expect_value(t, ring_header_validate(bad, total_blob), Venus_Problem.Ring_Bad_Magic)

	bad = base
	bad.version = 2
	testing.expect_value(t, ring_header_validate(bad, total_blob), Venus_Problem.Ring_Bad_Version)

	// Invalid buffer sizes: 0, below min, non-power-of-two, above max.
	for size in ([]u32{0, 128, 300, 4097, MAX_RING_BUFFER_SIZE * 2}) {
		bad = base
		bad.buffer_size = size
		testing.expect_value(t, ring_header_validate(bad, u64(MAX_RING_BUFFER_SIZE) * 4), Venus_Problem.Ring_Invalid_Buffer_Size)
	}

	// Head out of bounds or misaligned.
	for bad_head in ([]u32{1, 3, 4096, max(u32)}) {
		bad = base
		bad.head = bad_head
		testing.expect_value(t, ring_header_validate(bad, total_blob), Venus_Problem.Ring_Head_Out_Of_Bounds)
	}

	// Tail out of bounds or misaligned.
	for bad_tail in ([]u32{2, 4096, max(u32)}) {
		bad = base
		bad.tail = bad_tail
		testing.expect_value(t, ring_header_validate(bad, total_blob), Venus_Problem.Ring_Tail_Out_Of_Bounds)
	}

	// Buffer offset misaligned, overlapping header, or overflowing blob size.
	bad = base
	bad.buffer_offset = 32
	testing.expect_value(t, ring_header_validate(bad, total_blob), Venus_Problem.Ring_Offset_Out_Of_Bounds)

	bad = base
	bad.buffer_offset = 68
	testing.expect_value(t, ring_header_validate(bad, total_blob), Venus_Problem.Ring_Offset_Out_Of_Bounds)

	testing.expect_value(t, ring_header_validate(base, total_blob - 1), Venus_Problem.Ring_Offset_Out_Of_Bounds)

	// Extra region overlapping ring buffer or non-zero extra_offset with zero extra_size.
	bad = base
	bad.extra_offset = 64 + 4092
	testing.expect_value(t, ring_header_validate(bad, total_blob), Venus_Problem.Ring_Offset_Out_Of_Bounds)

	bad = base
	bad.extra_size = 0
	testing.expect_value(t, ring_header_validate(bad, total_blob), Venus_Problem.Ring_Offset_Out_Of_Bounds)

	// Zero ring ID refused.
	bad = base
	bad.ring_id = 0
	testing.expect_value(t, ring_header_validate(bad, total_blob), Venus_Problem.Zero_Handle_Id)

	// Valid encode & decode round-trip.
	written, enc_prob := ring_header_encode(base, total_blob, wire[:])
	testing.expect_value(t, enc_prob, Venus_Problem.None)
	testing.expect_value(t, written, VENUS_RING_HEADER_SIZE)

	decoded, dec_prob := ring_header_decode(wire[:], total_blob)
	testing.expect_value(t, dec_prob, Venus_Problem.None)
	testing.expect_value(t, decoded, base)

	// Corrupt reserved bytes on wire must be refused.
	corrupted := wire
	corrupted[36] = 1
	_, res_prob1 := ring_header_decode(corrupted[:], total_blob)
	testing.expect_value(t, res_prob1, Venus_Problem.Ring_Non_Zero_Reserved)

	corrupted = wire
	corrupted[63] = 0xFF
	_, res_prob2 := ring_header_decode(corrupted[:], total_blob)
	testing.expect_value(t, res_prob2, Venus_Problem.Ring_Non_Zero_Reserved)

	// Wrap-around available/free byte accounting.
	testing.expect_value(t, ring_available_bytes(64, 128, 4096), u32(64))
	testing.expect_value(t, ring_available_bytes(4000, 32, 4096), u32(128))
	testing.expect_value(t, ring_free_bytes(0, 0, 4096), u32(4092))
	testing.expect_value(t, ring_free_bytes(0, 4092, 4096), u32(0))
}

@(test)
wire_border_and_spirv_refusals :: proc(t: ^testing.T) {
	// Empty and misaligned streams.
	_, p_empty := stream_validate(nil)
	testing.expect_value(t, p_empty, Venus_Problem.Stream_Empty)

	misaligned: [18]u8
	_, p_mis := stream_validate(misaligned[:])
	testing.expect_value(t, p_mis, Venus_Problem.Misaligned_Length)

	// Raw wire packet with unknown command type, bad flags, non-zero reserved, misaligned payload.
	pkt: [32]u8
	byte_order.write_u32_little_endian(pkt[:], 0, 0)
	_, _, p_zero_cmd := stream_decode_next(pkt[:], 0)
	testing.expect_value(t, p_zero_cmd, Venus_Problem.Unknown_Command_Type)

	byte_order.write_u32_little_endian(pkt[:], 0, u32(Venus_Command_Type.Create_Instance))
	byte_order.write_u32_little_endian(pkt[:], 4, 2)
	_, _, p_flags := stream_decode_next(pkt[:], 0)
	testing.expect_value(t, p_flags, Venus_Problem.Unknown_Command_Flags)

	byte_order.write_u32_little_endian(pkt[:], 4, 0)
	byte_order.write_u32_little_endian(pkt[:], 8, PAYLOAD_SIZE_CREATE_INSTANCE)
	byte_order.write_u32_little_endian(pkt[:], 12, 1)
	_, _, p_res := stream_decode_next(pkt[:], 0)
	testing.expect_value(t, p_res, Venus_Problem.Non_Zero_Reserved)

	byte_order.write_u32_little_endian(pkt[:], 12, 0)
	byte_order.write_u32_little_endian(pkt[:], 8, 14) // misaligned payload
	_, _, p_pay_mis := stream_decode_next(pkt[:], 0)
	testing.expect_value(t, p_pay_mis, Venus_Problem.Misaligned_Length)

	byte_order.write_u32_little_endian(pkt[:], 8, 8) // wrong size for Create_Instance (expects 16)
	_, _, p_pay_size := stream_decode_next(pkt[:], 0)
	testing.expect_value(t, p_pay_size, Venus_Problem.Payload_Size_Mismatch)

	// Zero handle IDs refused across encoder commands.
	buf: [1024]u8
	enc := encoder_init(buf[:])
	testing.expect_value(t, encode_create_instance(&enc, Create_Instance_Payload{instance_id = 0, api_version = 1}), Venus_Problem.Zero_Handle_Id)
	testing.expect_value(t, encode_create_device(&enc, Create_Device_Payload{physical_device_id = 0, device_id = 2, queue_family_index = 0, queue_count = 1}), Venus_Problem.Zero_Handle_Id)
	testing.expect_value(t, encode_create_device(&enc, Create_Device_Payload{physical_device_id = 1, device_id = 0, queue_family_index = 0, queue_count = 1}), Venus_Problem.Zero_Handle_Id)
	testing.expect_value(t, encode_allocate_memory(&enc, Allocate_Memory_Payload{device_id = 1, memory_id = 0, allocation_size = 4096}), Venus_Problem.Zero_Handle_Id)
	testing.expect_value(t, encode_create_buffer(&enc, Create_Buffer_Payload{device_id = 1, buffer_id = 2, size = 0, usage = {.Vertex}}), Venus_Problem.Zero_Extent)
	testing.expect_value(t, encode_create_image(&enc, Create_Image_Payload{device_id = 1, image_id = 2, width = MAX_IMAGE_DIMENSION + 1, height = 64, format = .RGBA8_Unorm, usage = {.Render_Attachment}}), Venus_Problem.Dimension_Too_Large)
	testing.expect_value(t, encode_cmd_draw(&enc, Cmd_Draw_Payload{command_buffer_id = 1, vertex_count = 0, instance_count = 1}), Venus_Problem.Zero_Draw_Count)
	testing.expect_value(t, encode_cmd_bind_vertex_buffers(&enc, Cmd_Bind_Vertex_Buffers_Payload{command_buffer_id = 1, first_binding = MAX_VERTEX_BUFFER_SLOTS, buffer_id = 2}), Venus_Problem.Invalid_Slot)
	testing.expect_value(t, encode_queue_submit(&enc, Queue_Submit_Payload{queue_id = 0, command_buffer_id = 1}), Venus_Problem.Zero_Handle_Id)
	testing.expect_value(t, encode_ring_notify(&enc, Ring_Notify_Payload{ring_id = 0, seqno = 1}), Venus_Problem.Zero_Handle_Id)
	testing.expect_value(t, enc.used_bytes, 0)

	// SPIR-V refusals: invalid bytes, unaligned bytes, oversized word count.
	bad_spirv: [24]u8
	testing.expect_value(t, encode_create_shader_module(&enc, 1, 10, bad_spirv[:]), Venus_Problem.Invalid_Spirv)
	testing.expect_value(t, encode_create_shader_module(&enc, 1, 10, bad_spirv[:21]), Venus_Problem.Misaligned_Length)

	oversized_spirv := make([]u8, MAX_SPIRV_BYTES + 4)
	defer delete(oversized_spirv)
	testing.expect_value(t, encode_create_shader_module(&enc, 1, 10, oversized_spirv), Venus_Problem.Spirv_Too_Large)

	// Raw wire Create_Shader_Module claiming word_count == MAX_SPIRV_WORDS + 1 must be refused.
	wire_shader: [COMMAND_HEADER_SIZE + PAYLOAD_SIZE_CREATE_SHADER_MODULE_HEADER]u8
	byte_order.write_u32_little_endian(wire_shader[:], 0, u32(Venus_Command_Type.Create_Shader_Module))
	byte_order.write_u32_little_endian(wire_shader[:], 8, PAYLOAD_SIZE_CREATE_SHADER_MODULE_HEADER)
	byte_order.write_u64_little_endian(wire_shader[:], COMMAND_HEADER_SIZE + 0, 1)
	byte_order.write_u64_little_endian(wire_shader[:], COMMAND_HEADER_SIZE + 8, 2)
	byte_order.write_u32_little_endian(wire_shader[:], COMMAND_HEADER_SIZE + 16, MAX_SPIRV_WORDS + 1)
	_, _, p_spirv_wire := stream_decode_next(wire_shader[:], 0)
	testing.expect_value(t, p_spirv_wire, Venus_Problem.Spirv_Too_Large)
}

@(test)
stream_state_machine_and_all_commands_roundtrip :: proc(t: ^testing.T) {
	buf: [4096]u8

	// Unbalanced Begin_Command_Buffer refused.
	enc := encoder_init(buf[:])
	testing.expect_value(t, encode_begin_command_buffer(&enc, Begin_Command_Buffer_Payload{command_buffer_id = 50}), Venus_Problem.None)
	_, p_unbal_cb := stream_validate(encoder_bytes(&enc))
	testing.expect_value(t, p_unbal_cb, Venus_Problem.Unbalanced_Command_Buffer)

	// Cmd_Draw outside render pass refused.
	enc = encoder_init(buf[:])
	testing.expect_value(t, encode_begin_command_buffer(&enc, Begin_Command_Buffer_Payload{command_buffer_id = 50}), Venus_Problem.None)
	testing.expect_value(t, encode_cmd_draw(&enc, Cmd_Draw_Payload{command_buffer_id = 50, vertex_count = 3, instance_count = 1}), Venus_Problem.None)
	testing.expect_value(t, encode_end_command_buffer(&enc, End_Command_Buffer_Payload{command_buffer_id = 50}), Venus_Problem.None)
	_, p_draw_out := stream_validate(encoder_bytes(&enc))
	testing.expect_value(t, p_draw_out, Venus_Problem.Render_Pass_Not_Active)

	// Cmd_Copy_Buffer inside render pass refused.
	enc = encoder_init(buf[:])
	testing.expect_value(t, encode_begin_command_buffer(&enc, Begin_Command_Buffer_Payload{command_buffer_id = 50}), Venus_Problem.None)
	testing.expect_value(t, encode_cmd_begin_render_pass(&enc, Cmd_Begin_Render_Pass_Payload{command_buffer_id = 50, render_pass_id = 10, framebuffer_id = 11, render_width = 64, render_height = 64}), Venus_Problem.None)
	testing.expect_value(t, encode_cmd_copy_buffer(&enc, Cmd_Copy_Buffer_Payload{command_buffer_id = 50, src_buffer_id = 1, dst_buffer_id = 2, size = 16}), Venus_Problem.None)
	testing.expect_value(t, encode_cmd_end_render_pass(&enc, Cmd_End_Render_Pass_Payload{command_buffer_id = 50}), Venus_Problem.None)
	testing.expect_value(t, encode_end_command_buffer(&enc, End_Command_Buffer_Payload{command_buffer_id = 50}), Venus_Problem.None)
	_, p_copy_in := stream_validate(encoder_bytes(&enc))
	testing.expect_value(t, p_copy_in, Venus_Problem.Copy_Inside_Render_Pass)

	// Mismatched command buffer handle inside recording refused.
	enc = encoder_init(buf[:])
	testing.expect_value(t, encode_begin_command_buffer(&enc, Begin_Command_Buffer_Payload{command_buffer_id = 50}), Venus_Problem.None)
	testing.expect_value(t, encode_end_command_buffer(&enc, End_Command_Buffer_Payload{command_buffer_id = 51}), Venus_Problem.None)
	_, p_cb_mis := stream_validate(encoder_bytes(&enc))
	testing.expect_value(t, p_cb_mis, Venus_Problem.Command_Buffer_Mismatch)

	// Full valid Venus lifecycle exercising every command type.
	spirv := minimal_valid_spirv_bytes()
	enc = encoder_init(buf[:])
	testing.expect_value(t, encode_set_reply_command_stream(&enc, Set_Reply_Command_Stream_Payload{stream_resource_id = 1, offset = 0, size = 4096}), Venus_Problem.None)
	testing.expect_value(t, encode_create_instance(&enc, Create_Instance_Payload{instance_id = 1, api_version = 0x0040_3000}), Venus_Problem.None)
	testing.expect_value(t, encode_enumerate_physical_devices(&enc, Enumerate_Physical_Devices_Payload{instance_id = 1, max_device_count = 4}), Venus_Problem.None)
	testing.expect_value(t, encode_create_device(&enc, Create_Device_Payload{physical_device_id = 2, device_id = 3, queue_family_index = 0, queue_count = 1}), Venus_Problem.None)
	testing.expect_value(t, encode_allocate_memory(&enc, Allocate_Memory_Payload{device_id = 3, memory_id = 4, allocation_size = 65536, memory_type_index = 0}), Venus_Problem.None)
	testing.expect_value(t, encode_create_buffer(&enc, Create_Buffer_Payload{device_id = 3, buffer_id = 5, size = 1024, usage = {.Vertex, .Copy_Dst}}), Venus_Problem.None)
	testing.expect_value(t, encode_create_image(&enc, Create_Image_Payload{device_id = 3, image_id = 6, width = 800, height = 600, format = .RGBA8_Unorm, usage = {.Render_Attachment}}), Venus_Problem.None)
	testing.expect_value(t, encode_create_shader_module(&enc, 3, 7, spirv[:]), Venus_Problem.None)
	testing.expect_value(t, encode_create_render_pass(&enc, Create_Render_Pass_Payload{device_id = 3, render_pass_id = 8, color_format = .RGBA8_Unorm, has_depth = true, load_op = .Clear, store_op = .Store}), Venus_Problem.None)
	testing.expect_value(t, encode_create_graphics_pipelines(&enc, Create_Graphics_Pipelines_Payload{device_id = 3, pipeline_id = 9, render_pass_id = 8, vertex_shader_id = 7, fragment_shader_id = 7, topology = .Triangle_List, src_blend = .Src_Alpha, dst_blend = .One_Minus_Src_Alpha, vertex_stride = 32}), Venus_Problem.None)
	testing.expect_value(t, encode_allocate_command_buffers(&enc, Allocate_Command_Buffers_Payload{device_id = 3, command_pool_id = 10, command_buffer_id = 11}), Venus_Problem.None)
	testing.expect_value(t, encode_begin_command_buffer(&enc, Begin_Command_Buffer_Payload{command_buffer_id = 11}), Venus_Problem.None)
	testing.expect_value(t, encode_cmd_copy_buffer(&enc, Cmd_Copy_Buffer_Payload{command_buffer_id = 11, src_buffer_id = 5, dst_buffer_id = 5, src_offset = 0, dst_offset = 512, size = 128}), Venus_Problem.None)
	testing.expect_value(t, encode_cmd_copy_buffer_to_image(&enc, Cmd_Copy_Buffer_To_Image_Payload{command_buffer_id = 11, src_buffer_id = 5, dst_image_id = 6, src_offset = 0, bytes_per_row = 64, dst_x = 0, dst_y = 0, width = 16, height = 16}), Venus_Problem.None)
	testing.expect_value(t, encode_cmd_begin_render_pass(&enc, Cmd_Begin_Render_Pass_Payload{command_buffer_id = 11, render_pass_id = 8, framebuffer_id = 12, render_width = 800, render_height = 600}), Venus_Problem.None)
	testing.expect_value(t, encode_cmd_bind_pipeline(&enc, Cmd_Bind_Pipeline_Payload{command_buffer_id = 11, pipeline_id = 9}), Venus_Problem.None)
	testing.expect_value(t, encode_cmd_set_scissor(&enc, Cmd_Set_Scissor_Payload{command_buffer_id = 11, x = 10, y = 20, width = 100, height = 80}), Venus_Problem.None)
	testing.expect_value(t, encode_cmd_bind_vertex_buffers(&enc, Cmd_Bind_Vertex_Buffers_Payload{command_buffer_id = 11, first_binding = 0, buffer_id = 5, offset = 0}), Venus_Problem.None)
	testing.expect_value(t, encode_cmd_bind_index_buffer(&enc, Cmd_Bind_Index_Buffer_Payload{command_buffer_id = 11, buffer_id = 5, offset = 0, index_format = .Uint32}), Venus_Problem.None)
	testing.expect_value(t, encode_cmd_bind_descriptor_sets(&enc, Cmd_Bind_Descriptor_Sets_Payload{command_buffer_id = 11, set_index = 0, descriptor_set_id = 13}), Venus_Problem.None)
	testing.expect_value(t, encode_cmd_draw(&enc, Cmd_Draw_Payload{command_buffer_id = 11, vertex_count = 3, instance_count = 1}), Venus_Problem.None)
	testing.expect_value(t, encode_cmd_draw_indexed(&enc, Cmd_Draw_Indexed_Payload{command_buffer_id = 11, index_count = 6, instance_count = 1, first_index = 0, vertex_offset = -1, first_instance = 0}), Venus_Problem.None)
	testing.expect_value(t, encode_cmd_end_render_pass(&enc, Cmd_End_Render_Pass_Payload{command_buffer_id = 11}), Venus_Problem.None)
	testing.expect_value(t, encode_end_command_buffer(&enc, End_Command_Buffer_Payload{command_buffer_id = 11}), Venus_Problem.None)
	testing.expect_value(t, encode_queue_submit(&enc, Queue_Submit_Payload{queue_id = 14, command_buffer_id = 11, fence_id = 15}), Venus_Problem.None)
	testing.expect_value(t, encode_queue_wait_idle(&enc, Queue_Wait_Idle_Payload{queue_id = 14}), Venus_Problem.None)
	testing.expect_value(t, encode_ring_notify(&enc, Ring_Notify_Payload{ring_id = 16, seqno = 42}), Venus_Problem.None)
	testing.expect_value(t, encode_free_memory(&enc, Free_Memory_Payload{device_id = 3, memory_id = 4}), Venus_Problem.None)
	testing.expect_value(t, encode_destroy_device(&enc, Destroy_Device_Payload{device_id = 3}), Venus_Problem.None)
	testing.expect_value(t, encode_destroy_instance(&enc, Destroy_Instance_Payload{instance_id = 1}), Venus_Problem.None)

	summary, val_prob := stream_validate(encoder_bytes(&enc))
	testing.expect_value(t, val_prob, Venus_Problem.None)
	testing.expect_value(t, summary.command_count, u32(30))
	testing.expect_value(t, summary.shader_count, u32(1))
	testing.expect_value(t, summary.render_pass_count, u32(1))
	testing.expect_value(t, summary.draw_call_count, u32(2))
	testing.expect_value(t, summary.copy_count, u32(2))
	testing.expect_value(t, summary.submit_count, u32(1))
}

@(test)
webgpu_stream_to_venus_and_submit_3d :: proc(t: ^testing.T) {
	buffers := [?]webgpu_subset.Buffer_Desc{
		{size = 1024, usage = {.Vertex, .Copy_Dst}},
		{size = 256, usage = {.Index, .Copy_Dst}},
		{size = 4096, usage = {.Copy_Src}},
	}
	textures := [?]webgpu_subset.Texture_Desc{
		{width = 640, height = 480, format = .RGBA8_Unorm, usage = {.Render_Attachment, .Copy_Dst}},
		{width = 640, height = 480, format = .Depth24_Plus, usage = {.Render_Attachment}},
	}
	pipelines := [?]webgpu_subset.Pipeline_Desc{
		{topology = .Triangle_List, color_format = .RGBA8_Unorm, src_blend = .Src_Alpha, dst_blend = .One_Minus_Src_Alpha, vertex_stride = 32},
	}
	reg := webgpu_subset.Resource_Registry{
		buffers          = buffers[:],
		textures         = textures[:],
		pipelines        = pipelines[:],
		bind_group_count = 1,
	}

	ws_buf: [webgpu_subset.COMMAND_RECORD_SIZE * 16]u8
	ws_enc := webgpu_subset.encoder_init(ws_buf[:])
	_ = webgpu_subset.encode_copy_buffer_to_buffer(&ws_enc, 3, 1, 0, 0, 512)
	_ = webgpu_subset.encode_begin_render_pass(&ws_enc, 1, 2, .Clear, .Store, webgpu_subset.Clear_Color{a_bits = 0x3F80_0000})
	_ = webgpu_subset.encode_set_pipeline(&ws_enc, 1)
	_ = webgpu_subset.encode_set_vertex_buffer(&ws_enc, 0, 1, 0, 512)
	_ = webgpu_subset.encode_set_index_buffer(&ws_enc, 2, .Uint32, 0, 128)
	_ = webgpu_subset.encode_set_bind_group(&ws_enc, 0, 1)
	_ = webgpu_subset.encode_set_scissor_rect(&ws_enc, 16, 16, 320, 240)
	_ = webgpu_subset.encode_draw(&ws_enc, 6, 1, 0, 0)
	_ = webgpu_subset.encode_draw_indexed(&ws_enc, 12, 1, 0, 0, 0)
	_ = webgpu_subset.encode_end_render_pass(&ws_enc)
	ws_stream := webgpu_subset.encoder_finish(&ws_enc)

	handles := Venus_Translation_Handles{
		command_buffer_id   = 100,
		queue_id            = 200,
		fence_id            = 300,
		render_pass_id_base = 1000,
		framebuffer_id_base = 2000,
		buffer_id_base      = 3000,
		image_id_base       = 4000,
		pipeline_id_base    = 5000,
		descriptor_set_base = 6000,
	}

	venus_buf: [4096]u8
	for i in 0 ..< len(venus_buf) {
		venus_buf[i] = 0xAA
	}

	// Zero command_buffer_id or queue_id refused without touching destination.
	bad_handles := handles
	bad_handles.command_buffer_id = 0
	w0, p0 := webgpu_stream_to_venus(ws_stream, reg, bad_handles, venus_buf[:])
	testing.expect_value(t, p0, Venus_Problem.Zero_Handle_Id)
	testing.expect_value(t, w0, 0)
	testing.expect_value(t, venus_buf[0], u8(0xAA))

	// Invalid WebGPU stream refused without touching destination.
	bad_ws := webgpu_subset.Gpu_Command_Stream{bytes = ws_stream.bytes[:len(ws_stream.bytes) - 1]}
	w1, p1 := webgpu_stream_to_venus(bad_ws, reg, handles, venus_buf[:])
	testing.expect_value(t, p1, Venus_Problem.Webgpu_Stream_Invalid)
	testing.expect_value(t, w1, 0)
	testing.expect_value(t, venus_buf[0], u8(0xAA))

	// Valid translation.
	written, trans_prob := webgpu_stream_to_venus(ws_stream, reg, handles, venus_buf[:])
	testing.expect_value(t, trans_prob, Venus_Problem.None)
	testing.expect(t, written > 0 && written % 4 == 0, "translated Venus stream must be non-empty and 4-byte aligned")

	// Destination 1 byte too short must refuse with zero bytes written.
	short_dst: [4096]u8
	for i in 0 ..< len(short_dst) {
		short_dst[i] = 0xCC
	}
	w_short, p_short := webgpu_stream_to_venus(ws_stream, reg, handles, short_dst[:written - 1])
	testing.expect_value(t, p_short, Venus_Problem.Buffer_Too_Short)
	testing.expect_value(t, w_short, 0)
	testing.expect_value(t, short_dst[0], u8(0xCC))

	// Translated stream passes Venus validation with exact counts.
	summary, val_prob := stream_validate(venus_buf[:written])
	testing.expect_value(t, val_prob, Venus_Problem.None)
	testing.expect_value(t, summary.command_count, u32(13)) // Begin_CB + 10 translated + End_CB + Queue_Submit
	testing.expect_value(t, summary.render_pass_count, u32(1))
	testing.expect_value(t, summary.draw_call_count, u32(2))
	testing.expect_value(t, summary.copy_count, u32(1))
	testing.expect_value(t, summary.submit_count, u32(1))

	// Wrap directly into VirtIO-GPU Submit_3D and verify round-trip decode.
	submit_buf: [4096]u8
	submit_written, submit_prob := webgpu_stream_to_submit_3d(7, ws_stream, reg, handles, submit_buf[:], 99)
	testing.expect_value(t, submit_prob, Venus_Problem.None)
	testing.expect_value(t, submit_written, virtio_gpu.SUBMIT_3D_HEADER_SIZE + written)

	frame, frame_prob := virtio_gpu.submit_3d_decode(submit_buf[:submit_written])
	testing.expect_value(t, frame_prob, virtio_gpu.Validation_Problem.None)
	testing.expect_value(t, frame.header.ctx_id, u32(7))
	testing.expect_value(t, frame.header.fence_id, u64(99))
	testing.expect_value(t, len(frame.payload), written)

	payload_summary, payload_prob := stream_validate(frame.payload)
	testing.expect_value(t, payload_prob, Venus_Problem.None)
	testing.expect_value(t, payload_summary, summary)
}
