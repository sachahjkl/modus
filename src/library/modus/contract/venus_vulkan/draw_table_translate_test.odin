#+build !freestanding
#+build !modus
package venus_vulkan

import "core:testing"
import "modus:contract/byte_order"
import "modus:contract/draw_record"
import "modus:contract/webgpu_subset"

@(private = "file")
TARGET :: Draw_Table_Venus_Target {
	objects             = {
		command_buffer      = 100,
		queue               = 200,
		fence               = 300,
		pipeline_layout     = 400,
		render_pass_base    = 1000,
		framebuffer_base    = 2000,
		buffer_base         = 3000,
		image_base          = 4000,
		pipeline_base       = 5000,
		descriptor_set_base = 6000,
	},
	surface_width       = 64,
	surface_height      = 48,
	format              = .R8G8B8A8_Unorm,
	vertex_buffer_bytes = 32768,
	index_buffer_bytes  = 8192,
	load_op             = .Clear,
	clear_color         = {r_bits = 0x3F00_0000, a_bits = 0x3F80_0000},
}

@(private = "file")
pixels :: proc(value: int) -> i32 {
	return draw_record.units_of_pixels(value)
}

@(private = "file")
rectangle :: proc(color: u32, left, top, right, bottom: int) -> draw_record.Draw_Record {
	return draw_record.record_of(draw_record.Draw_Rectangle{color = draw_record.Draw_Color(color)}, 0, pixels(left), pixels(top), pixels(right), pixels(bottom))
}

@(private = "file")
put_point :: proc(text: []u8, offset: int, command: draw_record.Path_Command, x, y: int) -> int {
	byte_order.write_u32_little_endian(text, offset, u32(command))
	byte_order.write_u32_little_endian(text, offset + 4, u32(pixels(x)))
	byte_order.write_u32_little_endian(text, offset + 8, u32(pixels(y)))
	return offset + draw_record.PATH_POINT_SIZE
}

@(private = "file")
decode_all :: proc(t: ^testing.T, bytes: []u8, commands: []Decoded_Command, loc := #caller_location) -> int {
	decoder := decoder_init(bytes)
	count := 0
	for decoder.cursor < len(bytes) {
		command, problem := command_decode_next(&decoder)
		testing.expect_value(t, problem, Venus_Problem.None, loc = loc)
		if problem != .None || count == len(commands) {
			testing.expect(t, problem != .None, "more commands than the test holds", loc = loc)
			return count
		}
		commands[count] = command
		count += 1
	}
	return count
}

@(private = "file")
expect_types :: proc(t: ^testing.T, commands: []Decoded_Command, want: []Command_Type, loc := #caller_location) {
	testing.expect_value(t, len(commands), len(want), loc = loc)
	for index in 0 ..< min(len(commands), len(want)) {
		testing.expect_value(t, commands[index].command_type, want[index], loc = loc)
	}
}

@(private = "file")
fill :: proc(bytes: []u8, value: u8) {
	for &byte_value in bytes {
		byte_value = value
	}
}

@(private = "file")
expect_untouched :: proc(t: ^testing.T, bytes: []u8, loc := #caller_location) {
	for byte_value in bytes {
		if byte_value != 0xAA {
			testing.expect(t, false, "a refused translation must not write its destination", loc = loc)
			return
		}
	}
}

// The frame of an empty table clears the image: no upload, no draw, then
// the readback.
@(test)
empty_draw_table_becomes_a_clear_and_a_readback :: proc(t: ^testing.T) {
	scratch: [16384]u8
	destination: [4096]u8
	result, draw_problem, problem := draw_table_to_venus(nil, nil, TARGET, scratch[:], destination[:])
	testing.expect_value(t, problem, Venus_Problem.None)
	testing.expect_value(t, draw_problem, webgpu_subset.Draw_Table_Translation_Problem.None)
	testing.expect_value(t, result.translation.vertex_count, u32(0))
	commands: [32]Decoded_Command
	count := decode_all(t, destination[:result.written], commands[:])
	testing.expect_value(t, u32(count), result.venus_command_count)
	expect_types(t, commands[:count], {
		.Begin_Command_Buffer, .Cmd_Pipeline_Barrier, .Cmd_Set_Viewport, .Cmd_Push_Constants, .Cmd_Begin_Render_Pass,
		.Cmd_End_Render_Pass, .Cmd_Pipeline_Barrier, .Cmd_Copy_Image_To_Buffer, .Cmd_Pipeline_Barrier,
		.End_Command_Buffer, .Queue_Submit,
	})
	// The clear drops the old contents: UNDEFINED to COLOR_ATTACHMENT_OPTIMAL,
	// with no memory barrier, from the top of the pipe.
	first := commands[1]
	testing.expect_value(t, first.values[0], u64(transmute(u32)Pipeline_Stages{.Top_Of_Pipe}))
	testing.expect_value(t, first.values[4], u64(Image_Layout.Undefined))
	testing.expect_value(t, first.values[5], u64(Image_Layout.Color_Attachment_Optimal))
	testing.expect_value(t, first.objects[1], Object_Id(4001))
	// The render pass and the framebuffer of the color texture, and the clear color.
	testing.expect_value(t, commands[4].objects[1], Object_Id(1001))
	testing.expect_value(t, commands[4].objects[2], Object_Id(2001))
	testing.expect_value(t, commands[4].values[2], u64(64))
	testing.expect_value(t, commands[4].values[3], u64(48))
	testing.expect_value(t, commands[4].values[5], u64(0x3F00_0000))
	// The push constants are the size of the surface.
	testing.expect_value(t, commands[3].objects[1], Object_Id(400))
	// The readback: COLOR_ATTACHMENT_OPTIMAL to TRANSFER_SRC_OPTIMAL, the copy
	// of the whole image into buffer 3, then the host barrier.
	testing.expect_value(t, commands[6].values[4], u64(Image_Layout.Color_Attachment_Optimal))
	testing.expect_value(t, commands[6].values[5], u64(Image_Layout.Transfer_Source_Optimal))
	testing.expect_value(t, commands[7].objects[1], Object_Id(4001))
	testing.expect_value(t, commands[7].objects[2], Object_Id(3003))
	testing.expect_value(t, commands[7].values[2], u64(64))
	testing.expect_value(t, commands[7].values[11], u64(64))
	testing.expect_value(t, commands[7].values[12], u64(48))
	testing.expect_value(t, commands[8].values[1], u64(transmute(u32)Pipeline_Stages{.Host}))
	testing.expect_value(t, commands[8].values[3], u64(transmute(u32)Access_Flags{.Host_Read}))
	testing.expect_value(t, commands[10].objects[0], Object_Id(200))
	testing.expect_value(t, commands[10].objects[2], Object_Id(300))
}

// Rectangles, an alpha rectangle, a gradient, nested clips, a text quad, a
// picture quad and an outline: the vertices travel in the stream, and each
// clip becomes a scissor.
@(test)
draw_table_becomes_the_exact_venus_frame :: proc(t: ^testing.T) {
	text: [128]u8
	copy(text[:], "modus")
	path_first := 16
	offset := put_point(text[:], path_first, .Move, 4, 4)
	offset = put_point(text[:], offset, .Line, 20, 4)
	offset = put_point(text[:], offset, .Line, 12, 20)
	offset = put_point(text[:], offset, .Close, 0, 0)
	records := [?]draw_record.Draw_Record {
		rectangle(0xFF20_4080, 0, 0, 64, 48),
		rectangle(0x8000_FF00, 4, 4, 30, 30),
		draw_record.record_of(draw_record.Draw_Clip_Push{}, 0, pixels(8), pixels(8), pixels(40), pixels(40)),
		draw_record.record_of(draw_record.Draw_Gradient {
			start_x = pixels(8), start_y = pixels(8), end_x = pixels(8), end_y = pixels(40),
			start_color = draw_record.opaque(0xFF0000), end_color = draw_record.opaque(0x0000FF),
		}, 0, pixels(8), pixels(8), pixels(40), pixels(40)),
		draw_record.record_of(draw_record.Draw_Clip_Push{}, 0, pixels(16), pixels(16), pixels(24), pixels(24)),
		rectangle(0xFFFF_FFFF, 0, 0, 64, 48),
		draw_record.record_of(draw_record.Draw_Clip_Pop{}, 0, 0, 0, 0, 0),
		draw_record.record_of(draw_record.Draw_Clip_Pop{}, 0, 0, 0, 0, 0),
		draw_record.record_of(draw_record.Draw_Text {
			first = 0, count = 5, color = draw_record.opaque(0xFFFFFF),
			origin_x = pixels(2), font = .Cells_8x16, weight = .Regular, size = u16(pixels(16)),
		}, 0, pixels(2), pixels(30), pixels(42), pixels(46)),
		draw_record.record_of(draw_record.Draw_Picture{memory = 0, format = .Opaque, first = 0, stride = 16, generation = 1}, 0, pixels(44), pixels(4), pixels(60), pixels(20)),
		draw_record.record_of(draw_record.Draw_Path {
			first = u32(path_first), count = u32(offset - path_first),
			stroke_color = draw_record.opaque(0xFFFFFF), stroke_width = u32(pixels(2)),
		}, 0, pixels(0), pixels(0), pixels(24), pixels(24)),
	}
	scratch: [65536]u8
	destination: [32768]u8
	result, draw_problem, problem := draw_table_to_venus(records[:], text[:], TARGET, scratch[:], destination[:])
	testing.expect_value(t, problem, Venus_Problem.None)
	testing.expect_value(t, draw_problem, webgpu_subset.Draw_Table_Translation_Problem.None)
	translation := result.translation
	// 2 rectangles, 1 gradient, 1 clipped rectangle, 1 text, 1 picture, and
	// the three segments of the outline: 9 quads.
	testing.expect_value(t, translation.quad_count, u32(9))
	testing.expect_value(t, translation.vertex_bytes_used, 9 * 4 * 32)
	testing.expect_value(t, translation.index_bytes_used, 9 * 6 * 4)

	commands: [64]Decoded_Command
	count := decode_all(t, destination[:result.written], commands[:])
	testing.expect_value(t, u32(count), result.venus_command_count)
	prologue := [?]Command_Type {
		.Begin_Command_Buffer, .Cmd_Update_Buffer, .Cmd_Update_Buffer, .Cmd_Pipeline_Barrier, .Cmd_Set_Viewport,
		.Cmd_Push_Constants, .Cmd_Begin_Render_Pass, .Cmd_Bind_Pipeline, .Cmd_Bind_Vertex_Buffers, .Cmd_Bind_Index_Buffer,
	}
	epilogue := [?]Command_Type {
		.Cmd_End_Render_Pass, .Cmd_Pipeline_Barrier, .Cmd_Copy_Image_To_Buffer, .Cmd_Pipeline_Barrier, .End_Command_Buffer, .Queue_Submit,
	}
	testing.expect(t, count > len(prologue) + len(epilogue))
	expect_types(t, commands[:len(prologue)], prologue[:])
	expect_types(t, commands[count - len(epilogue):count], epilogue[:])

	// The middle is scissors and draws only; each clip is one scissor.
	scissors := 0
	drawn_indices: u64 = 0
	inner_scissor_seen := false
	for command in commands[len(prologue):count - len(epilogue)] {
		#partial switch command.command_type {
		case .Cmd_Set_Scissor:
			scissors += 1
			if command.values[1] == 16 && command.values[2] == 16 && command.values[3] == 8 && command.values[4] == 8 {
				inner_scissor_seen = true
			}
		case .Cmd_Draw_Indexed:
			drawn_indices += command.values[0]
		case:
			testing.expectf(t, false, "a %v inside the render pass", command.command_type)
		}
	}
	testing.expect_value(t, u32(scissors), translation.scissor_change_count)
	testing.expect(t, scissors >= 3, "the surface, the outer clip and the inner clip each have a scissor")
	testing.expect(t, inner_scissor_seen, "the inner clip intersects the outer clip: 16, 16, 8, 8")
	testing.expect_value(t, drawn_indices, u64(translation.index_count))

	// The vertices and the indices arrive whole, in the stream.
	testing.expect_value(t, commands[1].objects[1], Object_Id(3001))
	testing.expect_value(t, commands[1].values[1], u64(translation.vertex_bytes_used))
	testing.expect_value(t, commands[2].objects[1], Object_Id(3002))
	testing.expect_value(t, commands[2].values[1], u64(translation.index_bytes_used))
	// vkBeginCommandBuffer is 48 bytes; the data of vkCmdUpdateBuffer starts
	// 48 bytes after its own start.
	vertex_data := destination[48 + 48:][:translation.vertex_bytes_used]
	first_x := transmute(f32)byte_order.read_u32_little_endian(vertex_data, 0)
	first_alpha := transmute(f32)byte_order.read_u32_little_endian(vertex_data, 20)
	testing.expect_value(t, first_x, f32(0))
	testing.expect_value(t, first_alpha, f32(1))
	second_alpha := transmute(f32)byte_order.read_u32_little_endian(vertex_data, 4 * 32 + 20)
	testing.expect(t, second_alpha > 0.5 && second_alpha < 0.51, "the alpha rectangle keeps its alpha")
	// The uploads are visible to the vertex input in the first barrier.
	barrier := commands[3]
	testing.expect_value(t, barrier.values[0], u64(transmute(u32)Pipeline_Stages{.Transfer}))
	testing.expect_value(t, barrier.values[1], u64(transmute(u32)Pipeline_Stages{.Vertex_Input, .Color_Attachment_Output}))
	testing.expect_value(t, barrier.values[2], u64(transmute(u32)Access_Flags{.Transfer_Write}))
	testing.expect_value(t, barrier.values[6], u64(Image_Layout.Undefined))
	testing.expect_value(t, barrier.values[7], u64(Image_Layout.Color_Attachment_Optimal))
	testing.expect_value(t, commands[7].objects[1], Object_Id(5001))

	// A frame that keeps the last contents leaves TRANSFER_SRC_OPTIMAL.
	kept := TARGET
	kept.load_op = .Load
	result, draw_problem, problem = draw_table_to_venus(records[:], text[:], kept, scratch[:], destination[:])
	testing.expect_value(t, problem, Venus_Problem.None)
	count = decode_all(t, destination[:result.written], commands[:])
	testing.expect_value(t, commands[3].values[6], u64(Image_Layout.Transfer_Source_Optimal))
	testing.expect_value(t, commands[3].values[4], u64(transmute(u32)Access_Flags{.Transfer_Read}))
}

@(test)
draw_table_translation_refusals_leave_the_destination_untouched :: proc(t: ^testing.T) {
	records := [1]draw_record.Draw_Record{rectangle(0xFFFF_0000, 0, 0, 32, 32)}
	scratch: [16384]u8
	destination: [8192]u8
	fill(destination[:], 0xAA)

	refuse :: proc(t: ^testing.T, records: []draw_record.Draw_Record, target: Draw_Table_Venus_Target, scratch, destination: []u8, want: Venus_Problem, want_draw := webgpu_subset.Draw_Table_Translation_Problem.None, loc := #caller_location) {
		result, draw_problem, problem := draw_table_to_venus(records, nil, target, scratch, destination)
		testing.expect_value(t, problem, want, loc = loc)
		testing.expect_value(t, draw_problem, want_draw, loc = loc)
		testing.expect_value(t, result.written, 0, loc = loc)
		expect_untouched(t, destination, loc = loc)
	}

	target := TARGET
	target.objects.command_buffer = 0
	refuse(t, records[:], target, scratch[:], destination[:], .Zero_Object_Id)
	target = TARGET
	target.objects.queue = 0
	refuse(t, records[:], target, scratch[:], destination[:], .Zero_Object_Id)
	target = TARGET
	target.objects.pipeline_layout = 0
	refuse(t, records[:], target, scratch[:], destination[:], .Zero_Object_Id)
	target = TARGET
	target.surface_width = 0
	refuse(t, records[:], target, scratch[:], destination[:], .Zero_Extent)
	target = TARGET
	target.surface_height = MAX_IMAGE_DIMENSION + 1
	refuse(t, records[:], target, scratch[:], destination[:], .Dimension_Too_Large)
	target = TARGET
	target.format = .Undefined
	refuse(t, records[:], target, scratch[:], destination[:], .Unknown_Enum_Word)
	target.format = .B8G8R8A8_Srgb
	refuse(t, records[:], target, scratch[:], destination[:], .Unknown_Enum_Word)
	target.format = Format(999)
	refuse(t, records[:], target, scratch[:], destination[:], .Unknown_Enum_Word)
	target = TARGET
	target.load_op = .None
	refuse(t, records[:], target, scratch[:], destination[:], .Unknown_Enum_Word)
	target.load_op = webgpu_subset.Load_Op(77)
	refuse(t, records[:], target, scratch[:], destination[:], .Unknown_Enum_Word)
	target = TARGET
	target.vertex_buffer_bytes = 0
	refuse(t, records[:], target, scratch[:], destination[:], .Zero_Extent)
	target = TARGET
	target.objects.image_base = Object_Id(max(u64))
	refuse(t, records[:], target, scratch[:], destination[:], .Object_Id_Overflow)
	target = TARGET
	target.objects.buffer_base = Object_Id(max(u64) - 2)
	refuse(t, records[:], target, scratch[:], destination[:], .Object_Id_Overflow)

	// A table that the border of the draw table refuses.
	unbalanced := [1]draw_record.Draw_Record{draw_record.record_of(draw_record.Draw_Clip_Push{}, 0, 0, 0, pixels(8), pixels(8))}
	refuse(t, unbalanced[:], TARGET, scratch[:], destination[:], .Draw_Table_Refused, .Unbalanced_Clips_Or_Elements)
	damaged := records
	damaged[0].kind = 200
	refuse(t, damaged[:], TARGET, scratch[:], destination[:], .Draw_Table_Refused, .Invalid_Draw_Record)
	target = TARGET
	target.has_damage_rect = true
	target.damage_rect = {x = 60, y = 0, width = 8, height = 8}
	refuse(t, records[:], target, scratch[:], destination[:], .Draw_Table_Refused, .Damage_Rect_Out_Of_Bounds)
	// A scratch too small for the vertices, or for the commands, of the table.
	refuse(t, records[:], TARGET, nil, destination[:], .Draw_Table_Refused, .Vertex_Buffer_Overflow)
	refuse(t, records[:], TARGET, scratch[:256], destination[:], .Draw_Table_Refused, .Command_Buffer_Overflow)
	// GPU buffers smaller than the vertices or the indices of the frame.
	target = TARGET
	target.vertex_buffer_bytes = 4 * 32 - 4
	refuse(t, records[:], target, scratch[:], destination[:], .Gpu_Buffer_Too_Small)
	target = TARGET
	target.index_buffer_bytes = 6 * 4 - 4
	refuse(t, records[:], target, scratch[:], destination[:], .Gpu_Buffer_Too_Small)

	// A destination one word short is refused whole.
	needed, _, needed_problem := draw_table_to_venus(records[:], nil, TARGET, scratch[:], destination[:])
	testing.expect_value(t, needed_problem, Venus_Problem.None)
	fill(destination[:], 0xAA)
	refuse(t, records[:], TARGET, scratch[:], destination[:needed.written - 4], .Buffer_Too_Short)
	refuse(t, records[:], TARGET, scratch[:], nil, .Buffer_Too_Short)
	// The exact size is enough.
	exact, _, exact_problem := draw_table_to_venus(records[:], nil, TARGET, scratch[:], destination[:needed.written])
	testing.expect_value(t, exact_problem, Venus_Problem.None)
	testing.expect_value(t, exact.written, needed.written)
	count, validate_problem := stream_validate(destination[:exact.written])
	testing.expect_value(t, validate_problem, Venus_Problem.None)
	testing.expect_value(t, u32(count), exact.venus_command_count)
}

// A table whose vertices do not fit in one Submit_3D packet is refused whole.
@(test)
oversized_draw_table_is_refused :: proc(t: ^testing.T) {
	RECTANGLES :: 600
	records: [RECTANGLES]draw_record.Draw_Record
	for &record, index in records {
		record = rectangle(0xFF00_0000 | u32(index), index % 60, index / 60, index % 60 + 2, index / 60 + 2)
	}
	target := TARGET
	target.vertex_buffer_bytes = 1 << 20
	target.index_buffer_bytes = 1 << 20
	scratch := make([]u8, 1 << 18)
	defer delete(scratch)
	destination := make([]u8, 1 << 18)
	defer delete(destination)
	fill(destination, 0xAA)
	result, draw_problem, problem := draw_table_to_venus(records[:], nil, target, scratch, destination)
	testing.expect_value(t, draw_problem, webgpu_subset.Draw_Table_Translation_Problem.None)
	testing.expect_value(t, problem, Venus_Problem.Stream_Too_Large)
	testing.expect_value(t, result.written, 0)
	expect_untouched(t, destination)
	// The same table cut to what one packet carries passes.
	result, draw_problem, problem = draw_table_to_venus(records[:300], nil, target, scratch, destination)
	testing.expect_value(t, problem, Venus_Problem.None)
	_, validate_problem := stream_validate(destination[:result.written])
	testing.expect_value(t, validate_problem, Venus_Problem.None)
}

@(test)
draw_table_objects_are_created_in_order :: proc(t: ^testing.T) {
	words := [6]u32{SPIRV_MAGIC, 0x0001_0300, 0, 4, 0, (1 << 16) | 17}
	code: [24]u8
	for word, index in words {
		byte_order.write_u32_little_endian(code[:], index * 4, word)
	}
	setup := Draw_Table_Venus_Setup {
		device                   = 3,
		image_memory             = 7001,
		image_memory_bytes       = 64 * 48 * 4,
		image_view               = 7002,
		device_local_memory_type = 1,
		buffer_memories          = {7003, 7004, 7005},
		host_visible_memory_type = 2,
		vertex_shader            = 90,
		fragment_shader          = 91,
		vertex_shader_code       = code[:],
		fragment_shader_code     = code[:],
	}
	storage: [4096]u8
	encoder := encoder_init(storage[:])
	testing.expect_value(t, encode_draw_table_venus_objects(&encoder, TARGET, setup), Venus_Problem.None)
	commands: [32]Decoded_Command
	count := decode_all(t, encoder_bytes(&encoder), commands[:])
	expect_types(t, commands[:count], {
		.Create_Image, .Allocate_Memory, .Bind_Image_Memory, .Create_Image_View, .Create_Render_Pass, .Create_Framebuffer,
		.Create_Shader_Module, .Create_Shader_Module, .Create_Pipeline_Layout, .Create_Graphics_Pipelines,
		.Create_Buffer, .Allocate_Memory, .Bind_Buffer_Memory, .Create_Buffer, .Allocate_Memory, .Bind_Buffer_Memory,
		.Create_Buffer, .Allocate_Memory, .Bind_Buffer_Memory,
	})
	// Each object has the id that the frame names.
	testing.expect_value(t, commands[0].objects[1], Object_Id(4001))
	testing.expect_value(t, commands[4].objects[1], Object_Id(1001))
	testing.expect_value(t, commands[5].objects[3], Object_Id(2001))
	testing.expect_value(t, commands[8].objects[1], Object_Id(400))
	testing.expect_value(t, commands[9].objects[7], Object_Id(5001))
	testing.expect_value(t, commands[10].objects[1], Object_Id(3001))
	testing.expect_value(t, commands[13].objects[1], Object_Id(3002))
	testing.expect_value(t, commands[16].objects[1], Object_Id(3003))
	testing.expect_value(t, commands[16].values[0], u64(64 * 48 * 4))
	// A clear pass starts from UNDEFINED; a pass that keeps the contents
	// starts from COLOR_ATTACHMENT_OPTIMAL and loads.
	testing.expect_value(t, commands[4].values[2], u64(Attachment_Load_Op.Clear))
	testing.expect_value(t, commands[4].values[6], u64(Image_Layout.Undefined))
	kept := TARGET
	kept.load_op = .Load
	encoder = encoder_init(storage[:])
	testing.expect_value(t, encode_draw_table_venus_objects(&encoder, kept, setup), Venus_Problem.None)
	count = decode_all(t, encoder_bytes(&encoder), commands[:])
	testing.expect_value(t, commands[4].values[2], u64(Attachment_Load_Op.Load))
	testing.expect_value(t, commands[4].values[6], u64(Image_Layout.Color_Attachment_Optimal))

	// A refusal of a late object keeps no byte of the earlier ones.
	encoder = encoder_init(storage[:])
	bad := setup
	bad_code := code
	bad_code[0] = 0
	bad.fragment_shader_code = bad_code[:]
	testing.expect_value(t, encode_draw_table_venus_objects(&encoder, TARGET, bad), Venus_Problem.Shader_Code_Invalid)
	testing.expect_value(t, encoder.used_bytes, 0)
	testing.expect_value(t, encoder.command_count, u32(0))
	bad = setup
	bad.buffer_memories[2] = 0
	testing.expect_value(t, encode_draw_table_venus_objects(&encoder, TARGET, bad), Venus_Problem.Zero_Object_Id)
	testing.expect_value(t, encoder.used_bytes, 0)
	bad = setup
	bad.image_memory_bytes = 64 * 48 * 4 - 1
	testing.expect_value(t, encode_draw_table_venus_objects(&encoder, TARGET, bad), Venus_Problem.Gpu_Buffer_Too_Small)
	bad = setup
	bad.device = 0
	testing.expect_value(t, encode_draw_table_venus_objects(&encoder, TARGET, bad), Venus_Problem.Zero_Object_Id)
	short := encoder_init(storage[:512])
	testing.expect_value(t, encode_draw_table_venus_objects(&short, TARGET, setup), Venus_Problem.Buffer_Too_Short)
	testing.expect_value(t, short.used_bytes, 0)
	testing.expect_value(t, short.problem, Venus_Problem.None)
}
