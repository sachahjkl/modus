#+build !freestanding
#+build !modus
package venus_vulkan

import "core:testing"
import "modus:contract/byte_order"

// The command words of xmls/VK_EXT_command_serialization.xml and the
// structure types of vulkan_core.h: the renderer dispatches on these numbers.
#assert(u32(Command_Type.Create_Instance) == 0)
#assert(u32(Command_Type.Enumerate_Physical_Devices) == 2)
#assert(u32(Command_Type.Get_Physical_Device_Properties) == 6)
#assert(u32(Command_Type.Create_Device) == 11)
#assert(u32(Command_Type.Queue_Submit) == 18)
#assert(u32(Command_Type.Queue_Wait_Idle) == 19)
#assert(u32(Command_Type.Allocate_Memory) == 21)
#assert(u32(Command_Type.Bind_Buffer_Memory) == 28)
#assert(u32(Command_Type.Create_Buffer) == 50)
#assert(u32(Command_Type.Create_Command_Pool) == 85)
#assert(u32(Command_Type.Allocate_Command_Buffers) == 88)
#assert(u32(Command_Type.Begin_Command_Buffer) == 90)
#assert(u32(Command_Type.End_Command_Buffer) == 91)
#assert(u32(Command_Type.Cmd_Copy_Buffer) == 112)
#assert(u32(Command_Type.Cmd_Clear_Color_Image) == 119)
#assert(u32(Command_Type.Cmd_Begin_Render_Pass) == 133)
#assert(u32(Command_Type.Cmd_End_Render_Pass) == 135)
#assert(u32(Command_Type.Get_Device_Queue_2) == 155)
#assert(u32(Command_Type.Set_Reply_Command_Stream) == 178)
#assert(u32(Command_Type.Create_Ring) == 188)
#assert(u32(Command_Type.Notify_Ring) == 190)
#assert(i32(Structure_Type.Ring_Create_Info) == 1000384000)
#assert(i32(Structure_Type.Device_Queue_Info_2) == 1000145003)

// One expected word of the wire: 4 or 8 bytes.
Wire_Word :: struct {
	width: int,
	value: u64,
}

@(private = "file")
w32 :: proc(value: u64) -> Wire_Word {
	return {4, value}
}

@(private = "file")
w64 :: proc(value: u64) -> Wire_Word {
	return {8, value}
}

@(private = "file")
expect_words :: proc(t: ^testing.T, bytes: []u8, expected: []Wire_Word, loc := #caller_location) {
	offset := 0
	for word, index in expected {
		if offset + word.width > len(bytes) {
			testing.expectf(t, false, "the wire ends before word %d", index, loc = loc)
			return
		}
		got := word.width == 4 ? u64(byte_order.read_u32_little_endian(bytes, offset)) : byte_order.read_u64_little_endian(bytes, offset)
		testing.expectf(t, got == word.value, "word %d at byte %d: got 0x%x, want 0x%x", index, offset, got, word.value, loc = loc)
		offset += word.width
	}
	testing.expectf(t, offset == len(bytes), "the wire has %d bytes, the words %d", len(bytes), offset, loc = loc)
}

@(test)
create_instance_has_the_wire_layout_of_mesa :: proc(t: ^testing.T) {
	storage: [512]u8
	encoder := encoder_init(storage[:])
	application := Application_Info{application_name = "modus", application_version = 1, api_version = API_VERSION_1_1}
	testing.expect_value(t, encode_create_instance(&encoder, 7, application), Venus_Problem.None)
	bytes := encoder_bytes(&encoder)
	expect_words(t, bytes, {
		w32(0), w32(1), // vkCreateInstance, VK_COMMAND_GENERATE_REPLY_BIT_EXT
		w64(1), // pCreateInfo
		w32(1), w64(0), w32(0), // sType, pNext, flags
		w64(1), // pApplicationInfo
		w32(0), w64(0), // sType, pNext
		w64(6), w64(0x0000_7375_646F_6D), // "modus" and its null byte, padded to 8 bytes
		w32(1), // applicationVersion
		w64(0), // pEngineName
		w32(0), w32(u64(API_VERSION_1_1)),
		w32(0), w64(0), // no layer
		w32(0), w64(0), // no extension
		w64(0), // pAllocator
		w64(1), w64(7), // pInstance and its id
	})
	testing.expect_value(t, len(bytes), 136)
}

@(test)
command_encodings_have_the_wire_layout_of_mesa :: proc(t: ^testing.T) {
	storage: [1024]u8

	encoder := encoder_init(storage[:])
	testing.expect_value(t, encode_create_buffer(&encoder, 3, 9, 4096, {.Vertex_Buffer, .Transfer_Destination}), Venus_Problem.None)
	expect_words(t, encoder_bytes(&encoder), {
		w32(50), w32(1), w64(3), w64(1),
		w32(12), w64(0), w32(0), w64(4096), w32(0x82), w32(0), w32(0), w64(0),
		w64(0), w64(1), w64(9),
	})

	encoder = encoder_init(storage[:])
	testing.expect_value(t, encode_get_device_queue_2(&encoder, 3, 0, 0, 12), Venus_Problem.None)
	expect_words(t, encoder_bytes(&encoder), {
		w32(155), w32(0), w64(3), w64(1),
		w32(1000145003), w64(0), w32(0), w32(0), w32(0),
		w64(1), w64(12),
	})

	encoder = encoder_init(storage[:])
	testing.expect_value(t, encode_get_physical_device_properties(&encoder, 2), Venus_Problem.None)
	expect_words(t, encoder_bytes(&encoder), {
		w32(6), w32(1), w64(2), w64(1),
		w64(256), w64(16), // deviceName, pipelineCacheUUID
		w64(3), w64(3), w64(2), w64(2), w64(2), w64(2), // the fixed arrays of the limits
	})

	encoder = encoder_init(storage[:])
	range := Image_Subresource_Range{aspects = {.Color}, level_count = 1, layer_count = 1}
	testing.expect_value(t, encode_cmd_clear_color_image(&encoder, 20, 21, .Transfer_Destination_Optimal, {0x3F80_0000, 0, 0, 0x3F80_0000}, range), Venus_Problem.None)
	expect_words(t, encoder_bytes(&encoder), {
		w32(119), w32(0), w64(20), w64(21), w32(7),
		w64(1), w32(2), w64(4), w32(0x3F80_0000), w32(0), w32(0), w32(0x3F80_0000),
		w32(1), w64(1), w32(1), w32(0), w32(1), w32(0), w32(1),
	})

	encoder = encoder_init(storage[:])
	clear := [2]Clear_Value{[4]u32{1, 2, 3, 4}, Clear_Depth_Stencil{depth = 1}}
	testing.expect_value(t, encode_cmd_begin_render_pass(&encoder, 20, 30, 31, {width = 64, height = 32}, clear[:]), Venus_Problem.None)
	expect_words(t, encoder_bytes(&encoder), {
		w32(133), w32(0), w64(20), w64(1),
		w32(43), w64(0), w64(30), w64(31), w32(0), w32(0), w32(64), w32(32),
		w32(2), w64(2),
		w32(0), w32(2), w64(4), w32(1), w32(2), w32(3), w32(4),
		w32(1), w32(0x3F80_0000), w32(0),
		w32(0), // VK_SUBPASS_CONTENTS_INLINE
	})

	encoder = encoder_init(storage[:])
	command_buffers := [1]Object_Id{20}
	testing.expect_value(t, encode_queue_submit(&encoder, 12, command_buffers[:], 0), Venus_Problem.None)
	expect_words(t, encoder_bytes(&encoder), {
		w32(18), w32(0), w64(12), w32(1), w64(1),
		w32(4), w64(0), w32(0), w64(0), w64(0), w32(1), w64(1), w64(20), w32(0), w64(0),
		w64(0), // VK_NULL_HANDLE fence
	})

	encoder = encoder_init(storage[:])
	testing.expect_value(t, encode_notify_ring(&encoder, 5, 640), Venus_Problem.None)
	expect_words(t, encoder_bytes(&encoder), {w32(190), w32(0), w64(5), w32(640), w32(0)})
}

// encode_every_command writes one of each command and returns how many.
@(private = "file")
encode_every_command :: proc(encoder: ^Encoder) -> (count: int, problem: Venus_Problem) {
	physical := [1]Object_Id{2}
	command_buffers := [2]Object_Id{20, 21}
	regions := [1]Buffer_Copy{{source_offset = 0, destination_offset = 256, size = 128}}
	range := Image_Subresource_Range{aspects = {.Color}, level_count = 1, layer_count = 1}
	clear := [1]Clear_Value{[4]u32{9, 8, 7, 6}}
	ring_info := Ring_Create_Info{
		resource_id = 40, size = 192 + 4096, head_offset = RING_HEAD_OFFSET, tail_offset = RING_TAIL_OFFSET,
		status_offset = RING_STATUS_OFFSET, buffer_offset = RING_BUFFER_OFFSET, buffer_size = 4096, extra_offset = 192 + 4096,
	}
	copy_region := Buffer_Image_Copy{buffer_row_length = 64, aspects = {.Color}, layer_count = 1, width = 64, height = 4, depth = 1}
	encode_set_reply_command_stream(encoder, 41, 0, 4096) or_return
	encode_create_ring(encoder, 50, ring_info) or_return
	encode_create_instance(encoder, 1, {application_name = "modus", api_version = API_VERSION_1_1}) or_return
	encode_enumerate_physical_devices(encoder, 1, nil) or_return
	encode_enumerate_physical_devices(encoder, 1, physical[:]) or_return
	encode_get_physical_device_properties(encoder, 2) or_return
	encode_create_device(encoder, 2, 3, 0, 1) or_return
	encode_get_device_queue_2(encoder, 3, 0, 0, 12) or_return
	encode_create_buffer(encoder, 3, 9, 4096, {.Vertex_Buffer}) or_return
	encode_allocate_memory(encoder, 3, 10, 65536, 1) or_return
	encode_bind_buffer_memory(encoder, 3, 9, 10, 0) or_return
	encode_create_command_pool(encoder, 3, 11, 0, {.Reset_Command_Buffer}) or_return
	encode_allocate_command_buffers(encoder, 3, 11, .Primary, command_buffers[:]) or_return
	encode_begin_command_buffer(encoder, 20, {.One_Time_Submit}) or_return
	encode_cmd_copy_buffer(encoder, 20, 9, 9, regions[:]) or_return
	encode_cmd_clear_color_image(encoder, 20, 13, .General, {1, 2, 3, 4}, range) or_return
	encode_cmd_copy_buffer_to_image(encoder, 20, 9, 13, .Transfer_Destination_Optimal, copy_region) or_return
	encode_cmd_begin_render_pass(encoder, 20, 14, 15, {width = 64, height = 64}, clear[:]) or_return
	encode_cmd_bind_pipeline(encoder, 20, .Graphics, 16) or_return
	encode_cmd_set_scissor(encoder, 20, {x = 1, y = 2, width = 3, height = 4}) or_return
	encode_cmd_bind_vertex_buffers(encoder, 20, 0, 9, 64) or_return
	encode_cmd_bind_index_buffer(encoder, 20, 9, 128, .Uint16) or_return
	encode_cmd_bind_descriptor_sets(encoder, 20, .Graphics, 17, 0, 18) or_return
	encode_cmd_draw(encoder, 20, 3, 1, 0, 0) or_return
	encode_cmd_draw_indexed(encoder, 20, 6, 1, 0, -2, 0) or_return
	encode_cmd_end_render_pass(encoder, 20) or_return
	encode_end_command_buffer(encoder, 20) or_return
	encode_queue_submit(encoder, 12, command_buffers[:1], 19) or_return
	encode_queue_wait_idle(encoder, 12) or_return
	encode_seek_reply_command_stream(encoder, 64) or_return
	encode_notify_ring(encoder, 50, 4) or_return
	encode_destroy_ring(encoder, 50) or_return
	return 32, .None
}

@(test)
every_command_decodes_to_its_type_objects_and_values :: proc(t: ^testing.T) {
	storage: [8192]u8
	encoder := encoder_init(storage[:])
	count, problem := encode_every_command(&encoder)
	testing.expect_value(t, problem, Venus_Problem.None)
	testing.expect_value(t, int(encoder.command_count), count)

	// Measuring gives the same size and writes nothing.
	measure := encoder_measure()
	_, measure_problem := encode_every_command(&measure)
	testing.expect_value(t, measure_problem, Venus_Problem.None)
	testing.expect_value(t, measure.used_bytes, encoder.used_bytes)

	bytes := encoder_bytes(&encoder)
	validated, validate_problem := stream_validate(bytes)
	testing.expect_value(t, validate_problem, Venus_Problem.None)
	testing.expect_value(t, validated, count)

	expected_types := [?]Command_Type{
		.Set_Reply_Command_Stream, .Create_Ring, .Create_Instance, .Enumerate_Physical_Devices, .Enumerate_Physical_Devices,
		.Get_Physical_Device_Properties, .Create_Device, .Get_Device_Queue_2, .Create_Buffer, .Allocate_Memory,
		.Bind_Buffer_Memory, .Create_Command_Pool, .Allocate_Command_Buffers, .Begin_Command_Buffer, .Cmd_Copy_Buffer,
		.Cmd_Clear_Color_Image, .Cmd_Copy_Buffer_To_Image, .Cmd_Begin_Render_Pass, .Cmd_Bind_Pipeline, .Cmd_Set_Scissor,
		.Cmd_Bind_Vertex_Buffers, .Cmd_Bind_Index_Buffer, .Cmd_Bind_Descriptor_Sets, .Cmd_Draw, .Cmd_Draw_Indexed,
		.Cmd_End_Render_Pass, .End_Command_Buffer, .Queue_Submit, .Queue_Wait_Idle, .Seek_Reply_Command_Stream,
		.Notify_Ring, .Destroy_Ring,
	}
	decoder := decoder_init(bytes)
	commands: [len(expected_types)]Decoded_Command
	for expected, index in expected_types {
		command, decode_problem := command_decode_next(&decoder)
		testing.expect_value(t, decode_problem, Venus_Problem.None)
		testing.expect_value(t, command.command_type, expected)
		commands[index] = command
	}
	testing.expect(t, decoder_done(&decoder), "the decoder must end at the end of the stream")

	// The replies asked: the commands that return a VkResult or an object.
	testing.expect_value(t, commands[2].flags, Command_Flags{.Generate_Reply})
	testing.expect_value(t, commands[13].flags, Command_Flags{})

	// vkEnumeratePhysicalDevices: the count query, then the bound id.
	testing.expect_value(t, commands[3].object_count, 1)
	testing.expect_value(t, commands[4].objects[1], Object_Id(2))
	// vkCreateDevice: physical device, device; family 0, one queue, priority 1.0.
	testing.expect_value(t, commands[6].objects[0], Object_Id(2))
	testing.expect_value(t, commands[6].objects[1], Object_Id(3))
	testing.expect_value(t, commands[6].values[2], u64(0x3F80_0000))
	// vkAllocateCommandBuffers: device, pool, two command buffers.
	testing.expect_value(t, commands[12].object_count, 4)
	testing.expect_value(t, commands[12].objects[3], Object_Id(21))
	// vkCmdClearColorImage: layout, then the four words of the color.
	testing.expect_value(t, commands[15].values[0], u64(Image_Layout.General))
	testing.expect_value(t, commands[15].values[1], u64(1))
	testing.expect_value(t, commands[15].values[4], u64(4))
	// vkCmdDrawIndexed: the negative vertex offset keeps its sign.
	testing.expect_value(t, i64(commands[24].values[3]), i64(-2))
	// vkQueueSubmit: queue, command buffer, fence.
	testing.expect_value(t, commands[27].objects[0], Object_Id(12))
	testing.expect_value(t, commands[27].objects[1], Object_Id(20))
	testing.expect_value(t, commands[27].objects[2], Object_Id(19))
}

@(test)
encoders_refuse_wrong_inputs_and_leave_no_bytes :: proc(t: ^testing.T) {
	storage: [256]u8
	encoder := encoder_init(storage[:])
	one := [1]Object_Id{1}
	zero := [1]Object_Id{0}
	too_many: [MAX_ARRAY_ELEMENTS + 1]Object_Id
	for &id, index in too_many {
		id = Object_Id(index + 1)
	}
	range := Image_Subresource_Range{aspects = {.Color}, level_count = 1, layer_count = 1}

	testing.expect_value(t, encode_create_instance(&encoder, 0, {}), Venus_Problem.Zero_Object_Id)
	long_name: [MAX_STRING_BYTES]u8
	for &character in long_name {
		character = 'a'
	}
	testing.expect_value(t, encode_create_instance(&encoder, 1, {application_name = string(long_name[:])}), Venus_Problem.String_Too_Long)
	testing.expect_value(t, encode_create_instance(&encoder, 1, {engine_name = "a\x00b"}), Venus_Problem.String_Unterminated)
	testing.expect_value(t, encode_create_instance(&encoder, 1, {}, transmute(Command_Flags)u32(2)), Venus_Problem.Unknown_Command_Flags)
	testing.expect_value(t, encode_enumerate_physical_devices(&encoder, 1, zero[:]), Venus_Problem.Zero_Object_Id)
	testing.expect_value(t, encode_enumerate_physical_devices(&encoder, 1, too_many[:]), Venus_Problem.Count_Out_Of_Range)
	testing.expect_value(t, encode_create_device(&encoder, 1, 2, 0, 1.5), Venus_Problem.Count_Out_Of_Range)
	testing.expect_value(t, encode_create_device(&encoder, 1, 2, 0, -0.5), Venus_Problem.Count_Out_Of_Range)
	testing.expect_value(t, encode_create_buffer(&encoder, 1, 2, 0, {.Vertex_Buffer}), Venus_Problem.Zero_Extent)
	testing.expect_value(t, encode_create_buffer(&encoder, 1, 2, 16, {}), Venus_Problem.Unknown_Flag_Bits)
	testing.expect_value(t, encode_create_buffer(&encoder, 1, 2, 16, transmute(Buffer_Usage)u32(0x200)), Venus_Problem.Unknown_Flag_Bits)
	testing.expect_value(t, encode_allocate_memory(&encoder, 1, 2, 0, 0), Venus_Problem.Zero_Extent)
	testing.expect_value(t, encode_bind_buffer_memory(&encoder, 1, 0, 3, 0), Venus_Problem.Zero_Object_Id)
	testing.expect_value(t, encode_create_command_pool(&encoder, 1, 2, 0, transmute(Command_Pool_Flags)u32(4)), Venus_Problem.Unknown_Flag_Bits)
	testing.expect_value(t, encode_allocate_command_buffers(&encoder, 1, 2, .Primary, nil), Venus_Problem.Count_Out_Of_Range)
	testing.expect_value(t, encode_allocate_command_buffers(&encoder, 1, 2, Command_Buffer_Level(2), one[:]), Venus_Problem.Unknown_Enum_Word)
	testing.expect_value(t, encode_begin_command_buffer(&encoder, 1, transmute(Command_Buffer_Usage)u32(8)), Venus_Problem.Unknown_Flag_Bits)
	testing.expect_value(t, encode_cmd_copy_buffer(&encoder, 1, 2, 3, nil), Venus_Problem.Count_Out_Of_Range)
	testing.expect_value(t, encode_cmd_copy_buffer(&encoder, 1, 2, 3, []Buffer_Copy{{size = 0}}), Venus_Problem.Zero_Extent)
	testing.expect_value(t, encode_cmd_clear_color_image(&encoder, 1, 2, Image_Layout(3), {}, range), Venus_Problem.Unknown_Enum_Word)
	testing.expect_value(t, encode_cmd_clear_color_image(&encoder, 1, 2, .General, {}, {level_count = 1, layer_count = 1}), Venus_Problem.Unknown_Flag_Bits)
	testing.expect_value(t, encode_cmd_clear_color_image(&encoder, 1, 2, .General, {}, {aspects = {.Color}, layer_count = 1}), Venus_Problem.Zero_Extent)
	testing.expect_value(t, encode_cmd_begin_render_pass(&encoder, 1, 2, 3, {width = 0, height = 1}, nil), Venus_Problem.Zero_Extent)
	testing.expect_value(t, encode_cmd_begin_render_pass(&encoder, 1, 2, 3, {width = 1, height = 1}, []Clear_Value{nil}), Venus_Problem.Unknown_Union_Tag)
	testing.expect_value(t, encode_cmd_bind_pipeline(&encoder, 1, Pipeline_Bind_Point(7), 2), Venus_Problem.Unknown_Enum_Word)
	testing.expect_value(t, encode_cmd_set_scissor(&encoder, 1, {x = -1, width = 1, height = 1}), Venus_Problem.Dimension_Too_Large)
	testing.expect_value(t, encode_cmd_bind_index_buffer(&encoder, 1, 2, 1, .Uint16), Venus_Problem.Misaligned_Length)
	testing.expect_value(t, encode_cmd_bind_index_buffer(&encoder, 1, 2, 2, .Uint32), Venus_Problem.Misaligned_Length)
	testing.expect_value(t, encode_cmd_bind_index_buffer(&encoder, 1, 2, 0, Index_Type(2)), Venus_Problem.Unknown_Enum_Word)
	testing.expect_value(t, encode_cmd_draw(&encoder, 1, 0, 1, 0, 0), Venus_Problem.Zero_Extent)
	testing.expect_value(t, encode_cmd_draw_indexed(&encoder, 1, 1, 0, 0, 0, 0), Venus_Problem.Zero_Extent)
	testing.expect_value(t, encode_cmd_copy_buffer_to_image(&encoder, 1, 2, 3, .General, {aspects = {.Color}, width = 1, height = 1, depth = 0, layer_count = 1}), Venus_Problem.Zero_Extent)
	testing.expect_value(t, encode_queue_submit(&encoder, 0, one[:], 0), Venus_Problem.Zero_Object_Id)
	testing.expect_value(t, encode_queue_submit(&encoder, 1, nil, 0), Venus_Problem.Count_Out_Of_Range)
	testing.expect_value(t, encode_set_reply_command_stream(&encoder, 0, 0, 64), Venus_Problem.Zero_Object_Id)
	testing.expect_value(t, encode_set_reply_command_stream(&encoder, 1, 2, 64), Venus_Problem.Misaligned_Length)
	testing.expect_value(t, encode_seek_reply_command_stream(&encoder, 6), Venus_Problem.Misaligned_Length)
	testing.expect_value(t, encode_create_ring(&encoder, 1, {resource_id = 1, buffer_size = 4096}), Venus_Problem.Ring_Memory_Misaligned)
	testing.expect_value(t, encode_notify_ring(&encoder, 0, 0), Venus_Problem.Zero_Object_Id)
	testing.expect_value(t, encoder.used_bytes, 0)
	testing.expect_value(t, encoder.command_count, u32(0))

	// A command that does not fit leaves the earlier commands whole.
	small: [40]u8
	encoder = encoder_init(small[:])
	testing.expect_value(t, encode_cmd_draw(&encoder, 1, 3, 1, 0, 0), Venus_Problem.None)
	used := encoder.used_bytes
	testing.expect_value(t, used, 32)
	testing.expect_value(t, encode_cmd_draw(&encoder, 1, 3, 1, 0, 0), Venus_Problem.Buffer_Too_Short)
	testing.expect_value(t, encoder.used_bytes, used)
	testing.expect_value(t, encoder.problem, Venus_Problem.None)
	testing.expect_value(t, encode_end_command_buffer(&encoder, 1), Venus_Problem.Buffer_Too_Short)
	testing.expect_value(t, encoder.used_bytes, used)
}

@(private = "file")
put_word :: proc(bytes: []u8, offset: int, value: u32) {
	byte_order.write_u32_little_endian(bytes, offset, value)
}

@(private = "file")
decode_one :: proc(bytes: []u8) -> Venus_Problem {
	decoder := decoder_init(bytes)
	_, problem := command_decode_next(&decoder)
	if problem == .None && !decoder_done(&decoder) {
		return .Stream_Too_Large
	}
	return problem
}

@(test)
decoder_refuses_malformed_commands :: proc(t: ^testing.T) {
	storage: [8192]u8
	encoder := encoder_init(storage[:])
	_, problem := encode_every_command(&encoder)
	testing.expect_value(t, problem, Venus_Problem.None)
	stream := encoder_bytes(&encoder)

	// Every cut of the stream inside a command is refused, never read past.
	for cut := 4; cut < len(stream); cut += 4 {
		_, cut_problem := stream_validate(stream[:cut])
		decoder := decoder_init(stream)
		whole := 0
		for decoder.cursor < cut {
			if _, next_problem := command_decode_next(&decoder); next_problem != .None {
				break
			}
			whole = decoder.cursor
		}
		if whole == cut {
			testing.expect_value(t, cut_problem, Venus_Problem.None)
		} else {
			testing.expectf(t, cut_problem == .Stream_Truncated, "a cut at %d must be refused as truncated, got %v", cut, cut_problem)
		}
	}
	_, empty := stream_validate(nil)
	testing.expect_value(t, empty, Venus_Problem.Stream_Empty)
	_, odd := stream_validate(stream[:6])
	testing.expect_value(t, odd, Venus_Problem.Misaligned_Length)

	// Every single-bit flip of the stream decodes or is refused, never more.
	flipped: [8192]u8
	for bit in 0 ..< len(stream) * 8 {
		copy(flipped[:len(stream)], stream)
		flipped[bit / 8] ~= u8(1) << u8(bit % 8)
		_, _ = stream_validate(flipped[:len(stream)])
	}

	draw: [32]u8
	encoder = encoder_init(draw[:])
	_ = encode_cmd_draw(&encoder, 1, 3, 1, 0, 0)
	testing.expect_value(t, decode_one(draw[:]), Venus_Problem.None)
	put_word(draw[:], 0, 107 + 1000)
	testing.expect_value(t, decode_one(draw[:]), Venus_Problem.Unknown_Command_Type)
	put_word(draw[:], 0, 1) // vkDestroyInstance: not a command of this package
	testing.expect_value(t, decode_one(draw[:]), Venus_Problem.Unknown_Command_Type)
	put_word(draw[:], 0, 106)
	put_word(draw[:], 4, 2)
	testing.expect_value(t, decode_one(draw[:]), Venus_Problem.Unknown_Command_Flags)
	put_word(draw[:], 4, 0)
	byte_order.write_u64_little_endian(draw[:], 8, 0)
	testing.expect_value(t, decode_one(draw[:]), Venus_Problem.Zero_Object_Id)

	buffer: [128]u8
	encoder = encoder_init(buffer[:])
	_ = encode_create_buffer(&encoder, 3, 9, 4096, {.Vertex_Buffer})
	length := encoder.used_bytes
	// The words of vkCreateBuffer: 0 type, 4 flags, 8 device, 16 pointer,
	// 24 sType, 28 pNext, 36 flags, 40 size, 48 usage, 52 sharing mode,
	// 56 family count, 60 families, 68 pAllocator, 76 pBuffer, 84 id.
	cases := [?]struct {
		offset: int,
		value:  u32,
		want:   Venus_Problem,
	}{
		{16, 2, .Pointer_Invalid},
		{16, 0, .Pointer_Invalid},
		{24, 13, .Structure_Type_Mismatch},
		{24, 0xFFFF_FFFF, .Structure_Type_Mismatch},
		{28, 1, .Next_Chain_Refused},
		{36, 1, .Unknown_Flag_Bits},
		{48, 0x200, .Unknown_Flag_Bits},
		{52, 2, .Unknown_Enum_Word},
		{56, MAX_ARRAY_ELEMENTS + 1, .Count_Out_Of_Range},
		// The count of families is 0: an array of another size is refused.
		{60, 3, .Array_Size_Mismatch},
		{68, 1, .Pointer_Invalid},
		{76, 0, .Pointer_Invalid},
	}
	for entry in cases {
		corrupt: [128]u8
		copy(corrupt[:], buffer[:length])
		put_word(corrupt[:], entry.offset, entry.value)
		testing.expectf(t, decode_one(corrupt[:length]) == entry.want, "word at %d = 0x%x: want %v, got %v", entry.offset, entry.value, entry.want, decode_one(corrupt[:length]))
	}
	{
		corrupt: [128]u8
		copy(corrupt[:], buffer[:length])
		byte_order.write_u64_little_endian(corrupt[:], 40, 0)
		testing.expect_value(t, decode_one(corrupt[:length]), Venus_Problem.Zero_Extent)
		copy(corrupt[:], buffer[:length])
		byte_order.write_u64_little_endian(corrupt[:], 80, 0)
		testing.expect_value(t, decode_one(corrupt[:length]), Venus_Problem.Zero_Object_Id)
	}

	// An unknown union tag of a clear value, and of a clear color.
	pass: [256]u8
	encoder = encoder_init(pass[:])
	clear := [1]Clear_Value{[4]u32{1, 2, 3, 4}}
	_ = encode_cmd_begin_render_pass(&encoder, 1, 2, 3, {width = 1, height = 1}, clear[:])
	pass_length := encoder.used_bytes
	// 0 type, 4 flags, 8 cb, 16 pointer, 24 sType, 28 pNext, 36 pass, 44 fb,
	// 52 area, 68 count, 72 size, 80 tag, 84 color tag, 88 size, 96 words, 112 contents.
	put_word(pass[:], 80, 2)
	testing.expect_value(t, decode_one(pass[:pass_length]), Venus_Problem.Unknown_Union_Tag)
	put_word(pass[:], 80, 0)
	put_word(pass[:], 84, 3)
	testing.expect_value(t, decode_one(pass[:pass_length]), Venus_Problem.Unknown_Union_Tag)
	put_word(pass[:], 84, 2)
	put_word(pass[:], 112, 1)
	testing.expect_value(t, decode_one(pass[:pass_length]), Venus_Problem.Unknown_Enum_Word)
	put_word(pass[:], 112, 0)
	testing.expect_value(t, decode_one(pass[:pass_length]), Venus_Problem.None)

	// A string with no null byte, and a string longer than the bound.
	instance: [256]u8
	encoder = encoder_init(instance[:])
	_ = encode_create_instance(&encoder, 1, {application_name = "abc"})
	instance_length := encoder.used_bytes
	// The name: size at 52, bytes at 60.
	instance[63] = 'd'
	testing.expect_value(t, decode_one(instance[:instance_length]), Venus_Problem.String_Unterminated)
	instance[63] = 0
	byte_order.write_u64_little_endian(instance[:], 52, MAX_STRING_BYTES + 1)
	testing.expect_value(t, decode_one(instance[:instance_length]), Venus_Problem.String_Too_Long)

	// A ring whose layout is not the layout of this package.
	ring: [256]u8
	encoder = encoder_init(ring[:])
	info := Ring_Create_Info{
		resource_id = 1, size = 192 + 4096, head_offset = RING_HEAD_OFFSET, tail_offset = RING_TAIL_OFFSET,
		status_offset = RING_STATUS_OFFSET, buffer_offset = RING_BUFFER_OFFSET, buffer_size = 4096, extra_offset = 192 + 4096,
	}
	testing.expect_value(t, encode_create_ring(&encoder, 7, info), Venus_Problem.None)
	ring_length := encoder.used_bytes
	// 0 type, 4 flags, 8 ring, 16 pointer, 24 sType, 28 pNext, 36 flags,
	// 40 resource, 44 offset, 52 size, 60 idle, 68 head, 76 tail, 84 status,
	// 92 buffer offset, 100 buffer size, 108 extra offset, 116 extra size.
	byte_order.write_u64_little_endian(ring[:], 100, 4097)
	testing.expect_value(t, decode_one(ring[:ring_length]), Venus_Problem.Ring_Buffer_Size_Invalid)
	byte_order.write_u64_little_endian(ring[:], 100, 4096)
	byte_order.write_u64_little_endian(ring[:], 52, 100)
	testing.expect_value(t, decode_one(ring[:ring_length]), Venus_Problem.Ring_Memory_Too_Small)
	byte_order.write_u64_little_endian(ring[:], 52, 192 + 4096)
	put_word(ring[:], 40, 0)
	testing.expect_value(t, decode_one(ring[:ring_length]), Venus_Problem.Zero_Object_Id)
}


// The border of a client stream: each command of the ring and of the reply
// stream, and each command that asks for a reply, refuses the whole stream,
// even after a valid command. The decoder alone accepts each of them.
@(test)
client_stream_refuses_ring_and_reply_commands :: proc(t: ^testing.T) {
	ring_info := Ring_Create_Info{
		resource_id = 40, size = 192 + 4096, head_offset = RING_HEAD_OFFSET, tail_offset = RING_TAIL_OFFSET,
		status_offset = RING_STATUS_OFFSET, buffer_offset = RING_BUFFER_OFFSET, buffer_size = 4096, extra_offset = 192 + 4096,
	}
	Case :: enum {
		Create_Ring,
		Destroy_Ring,
		Notify_Ring,
		Set_Reply_Command_Stream,
		Seek_Reply_Command_Stream,
		Generate_Reply,
	}
	for case_kind in Case {
		storage: [1024]u8
		encoder := encoder_init(storage[:])
		testing.expect_value(t, encode_queue_wait_idle(&encoder, 12, {}), Venus_Problem.None)
		expected := Venus_Problem.Client_Command_Refused
		problem: Venus_Problem
		switch case_kind {
		case .Create_Ring:
			problem = encode_create_ring(&encoder, 50, ring_info)
		case .Destroy_Ring:
			problem = encode_destroy_ring(&encoder, 50)
		case .Notify_Ring:
			problem = encode_notify_ring(&encoder, 50, 4)
		case .Set_Reply_Command_Stream:
			problem = encode_set_reply_command_stream(&encoder, 41, 0, 4096)
		case .Seek_Reply_Command_Stream:
			problem = encode_seek_reply_command_stream(&encoder, 64)
		case .Generate_Reply:
			problem = encode_queue_wait_idle(&encoder, 12, REPLY)
			expected = .Client_Reply_Refused
		}
		testing.expect_value(t, problem, Venus_Problem.None)
		bytes := encoder_bytes(&encoder)
		whole, whole_problem := stream_validate(bytes)
		testing.expectf(t, whole_problem == .None && whole == 2, "%v decodes", case_kind)
		count, client_problem := stream_validate_client(bytes)
		testing.expectf(t, client_problem == expected, "%v is refused with %v, got %v", case_kind, expected, client_problem)
		testing.expectf(t, count == 1, "%v is refused after the one valid command", case_kind)
	}

	// Each type outside the commands of the ring and of the reply stream is
	// allowed; the five inside are not.
	refused := 0
	for command_type in Command_Type {
		if !command_type_client_allowed(command_type) {
			refused += 1
		}
	}
	testing.expect_value(t, refused, 5)

	// The faults of the decoder come first, as in stream_validate.
	_, empty := stream_validate_client(nil)
	testing.expect_value(t, empty, Venus_Problem.Stream_Empty)
	odd: [6]u8
	_, misaligned := stream_validate_client(odd[:])
	testing.expect_value(t, misaligned, Venus_Problem.Misaligned_Length)

	// The successful case last: rendering commands with no reply pass.
	storage: [1024]u8
	encoder := encoder_init(storage[:])
	testing.expect_value(t, encode_begin_command_buffer(&encoder, 20, {.One_Time_Submit}), Venus_Problem.None)
	testing.expect_value(t, encode_cmd_draw(&encoder, 20, 3, 1, 0, 0), Venus_Problem.None)
	testing.expect_value(t, encode_end_command_buffer(&encoder, 20), Venus_Problem.None)
	command_buffers := [1]Object_Id{20}
	testing.expect_value(t, encode_queue_submit(&encoder, 12, command_buffers[:], 19), Venus_Problem.None)
	count, problem := stream_validate_client(encoder_bytes(&encoder))
	testing.expect_value(t, problem, Venus_Problem.None)
	testing.expect_value(t, count, 4)
}
