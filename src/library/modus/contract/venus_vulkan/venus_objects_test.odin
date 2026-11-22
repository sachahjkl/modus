#+build !freestanding
package venus_vulkan

import "core:testing"
import "modus:contract/byte_order"

// The round trip of each object and recording command of the 2D draw: the
// encoder writes it, the decoder of the renderer side reads it back whole,
// and each malformed word of the wire is refused with its problem, with the
// cursor of the decoder back at the start of the command.

@(private = "file")
SHADER_WORDS :: [6]u32{SPIRV_MAGIC, 0x0001_0300, 0, 4, 0, (1 << 16) | 17}

@(private = "file")
shader_bytes :: proc() -> (bytes: [24]u8) {
	for word, index in SHADER_WORDS {
		byte_order.write_u32_little_endian(bytes[:], index * 4, word)
	}
	return
}

@(private = "file")
COLOR_RANGE :: Image_Subresource_Range{aspects = {.Color}, level_count = 1, layer_count = 1}

@(private = "file")
decode_single :: proc(t: ^testing.T, bytes: []u8, want: Command_Type, loc := #caller_location) -> Decoded_Command {
	decoder := decoder_init(bytes)
	command, problem := command_decode_next(&decoder)
	testing.expect_value(t, problem, Venus_Problem.None, loc = loc)
	testing.expect_value(t, command.command_type, want, loc = loc)
	testing.expect(t, decoder_done(&decoder), "the decoder must read the whole command", loc = loc)
	count, validate_problem := stream_validate(bytes)
	testing.expect_value(t, validate_problem, Venus_Problem.None, loc = loc)
	testing.expect_value(t, count, 1, loc = loc)
	return command
}

// expect_word_refused writes word at offset in a copy of bytes, and checks
// that the decoder refuses the command with want and leaves its cursor at
// the start.
@(private = "file")
expect_word_refused :: proc(t: ^testing.T, bytes: []u8, offset: int, word: u32, want: Venus_Problem, loc := #caller_location) {
	copied: [1024]u8
	testing.expect(t, len(bytes) <= len(copied) && offset + 4 <= len(bytes), "the test command is too long", loc = loc)
	copy(copied[:], bytes)
	byte_order.write_u32_little_endian(copied[:], offset, word)
	decoder := decoder_init(copied[:len(bytes)])
	_, problem := command_decode_next(&decoder)
	testing.expect_value(t, problem, want, loc = loc)
	testing.expect_value(t, decoder.cursor, 0, loc = loc)
	_, validate_problem := stream_validate(copied[:len(bytes)])
	testing.expect_value(t, validate_problem, want, loc = loc)
}

// expect_each_prefix_refused checks that each cut of the command, at each
// word, is refused: no prefix of a command is a command.
@(private = "file")
expect_each_prefix_refused :: proc(t: ^testing.T, bytes: []u8, loc := #caller_location) {
	for cut := 0; cut < len(bytes); cut += 4 {
		decoder := decoder_init(bytes[:cut])
		_, problem := command_decode_next(&decoder)
		if problem == .None {
			testing.expectf(t, false, "the prefix of %d bytes was accepted", cut, loc = loc)
			return
		}
		testing.expect_value(t, decoder.cursor, 0, loc = loc)
	}
}

// expect_refused_untouched checks that an encoder refusal wrote nothing.
@(private = "file")
expect_refused_untouched :: proc(t: ^testing.T, encoder: ^Encoder, got, want: Venus_Problem, loc := #caller_location) {
	testing.expect_value(t, got, want, loc = loc)
	testing.expect_value(t, encoder.used_bytes, 0, loc = loc)
	testing.expect_value(t, encoder.command_count, u32(0), loc = loc)
	testing.expect_value(t, encoder.problem, Venus_Problem.None, loc = loc)
}

@(private = "file")
IMAGE_DESCRIPTION :: Image_Description{format = .R8G8B8A8_Unorm, width = 640, height = 480, usage = {.Color_Attachment, .Transfer_Source}, tiling = .Optimal}

@(test)
create_image_round_trip_and_refusals :: proc(t: ^testing.T) {
	storage: [256]u8
	encoder := encoder_init(storage[:])
	testing.expect_value(t, encode_create_image(&encoder, 3, 70, IMAGE_DESCRIPTION), Venus_Problem.None)
	bytes := encoder_bytes(&encoder)
	testing.expect_value(t, len(bytes), 124)
	command := decode_single(t, bytes, .Create_Image)
	testing.expect_value(t, command.flags, Command_Flags{.Generate_Reply})
	testing.expect_value(t, command.objects[0], Object_Id(3))
	testing.expect_value(t, command.objects[1], Object_Id(70))
	testing.expect_value(t, command.values[0], u64(Image_Type.Two_Dimensions))
	testing.expect_value(t, command.values[1], u64(Format.R8G8B8A8_Unorm))
	testing.expect_value(t, command.values[2], u64(640))
	testing.expect_value(t, command.values[3], u64(480))
	testing.expect_value(t, command.values[9], u64(transmute(u32)Image_Usage{.Color_Attachment, .Transfer_Source}))

	expect_word_refused(t, bytes, 0, 9999, .Unknown_Command_Type)
	expect_word_refused(t, bytes, 4, 2, .Unknown_Command_Flags)
	expect_word_refused(t, bytes, 8, 0, .Zero_Object_Id)
	expect_word_refused(t, bytes, 16, 2, .Pointer_Invalid)
	expect_word_refused(t, bytes, 24, i32_word(i32(Structure_Type.Image_View_Create_Info)), .Structure_Type_Mismatch)
	expect_word_refused(t, bytes, 28, 1, .Next_Chain_Refused)
	expect_word_refused(t, bytes, 36, 1, .Unknown_Flag_Bits)
	expect_word_refused(t, bytes, 40, 3, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 44, 99, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 44, 0, .Unknown_Enum_Word) // UNDEFINED is no format of an image
	expect_word_refused(t, bytes, 44, u32(Format.R32G32_Signed_Float), .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 48, 0, .Zero_Extent)
	expect_word_refused(t, bytes, 52, MAX_IMAGE_DIMENSION + 1, .Dimension_Too_Large)
	expect_word_refused(t, bytes, 56, 2, .Dimension_Too_Large)
	expect_word_refused(t, bytes, 56, 0, .Zero_Extent)
	expect_word_refused(t, bytes, 60, 0, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 64, MAX_ARRAY_ELEMENTS + 1, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 68, 4, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 72, 2, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 76, 0, .Missing_Flag_Bits)
	expect_word_refused(t, bytes, 76, 0x100, .Unknown_Flag_Bits)
	expect_word_refused(t, bytes, 80, 2, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 84, MAX_ARRAY_ELEMENTS + 1, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 88, 3, .Array_Size_Mismatch)
	expect_word_refused(t, bytes, 96, u32(Image_Layout.Color_Attachment_Optimal), .Layout_Transition_Invalid)
	expect_word_refused(t, bytes, 96, 3, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 100, 1, .Pointer_Invalid)
	expect_word_refused(t, bytes, 108, 0, .Pointer_Invalid)
	expect_word_refused(t, bytes, 116, 0, .Zero_Object_Id)
	expect_each_prefix_refused(t, bytes)

	// The encoder refuses each input that the decoder refuses, and writes nothing.
	encoder = encoder_init(storage[:])
	description := IMAGE_DESCRIPTION
	expect_refused_untouched(t, &encoder, encode_create_image(&encoder, 0, 70, description), .Zero_Object_Id)
	expect_refused_untouched(t, &encoder, encode_create_image(&encoder, 3, 0, description), .Zero_Object_Id)
	description.format = .Undefined
	expect_refused_untouched(t, &encoder, encode_create_image(&encoder, 3, 70, description), .Unknown_Enum_Word)
	description.format = Format(12345)
	expect_refused_untouched(t, &encoder, encode_create_image(&encoder, 3, 70, description), .Unknown_Enum_Word)
	description = IMAGE_DESCRIPTION
	description.width = 0
	expect_refused_untouched(t, &encoder, encode_create_image(&encoder, 3, 70, description), .Zero_Extent)
	description.width = MAX_IMAGE_DIMENSION + 1
	expect_refused_untouched(t, &encoder, encode_create_image(&encoder, 3, 70, description), .Dimension_Too_Large)
	description.width = MAX_IMAGE_DIMENSION
	description.usage = {}
	expect_refused_untouched(t, &encoder, encode_create_image(&encoder, 3, 70, description), .Missing_Flag_Bits)
	description.usage = transmute(Image_Usage)u32(0x8000_0010)
	expect_refused_untouched(t, &encoder, encode_create_image(&encoder, 3, 70, description), .Unknown_Flag_Bits)
	description.usage = {.Color_Attachment}
	description.tiling = Image_Tiling(7)
	expect_refused_untouched(t, &encoder, encode_create_image(&encoder, 3, 70, description), .Unknown_Enum_Word)
	// The largest image is accepted.
	description.tiling = .Linear
	description.height = MAX_IMAGE_DIMENSION
	testing.expect_value(t, encode_create_image(&encoder, 3, 70, description), Venus_Problem.None)
	// A storage one byte short keeps nothing of the command.
	short := encoder_init(storage[:123])
	expect_refused_untouched(t, &short, encode_create_image(&short, 3, 70, IMAGE_DESCRIPTION), .Buffer_Too_Short)
}

@(private = "file")
i32_word :: proc(value: i32) -> u32 {
	return u32(value)
}

@(test)
image_memory_and_view_round_trip_and_refusals :: proc(t: ^testing.T) {
	storage: [256]u8
	encoder := encoder_init(storage[:])
	testing.expect_value(t, encode_bind_image_memory(&encoder, 3, 70, 80, 4096), Venus_Problem.None)
	bytes := encoder_bytes(&encoder)
	testing.expect_value(t, len(bytes), 40)
	command := decode_single(t, bytes, .Bind_Image_Memory)
	testing.expect_value(t, command.objects[1], Object_Id(70))
	testing.expect_value(t, command.objects[2], Object_Id(80))
	testing.expect_value(t, command.values[0], u64(4096))
	expect_word_refused(t, bytes, 16, 0, .Zero_Object_Id)
	expect_word_refused(t, bytes, 24, 0, .Zero_Object_Id)
	expect_each_prefix_refused(t, bytes)
	encoder = encoder_init(storage[:])
	expect_refused_untouched(t, &encoder, encode_bind_image_memory(&encoder, 3, 0, 80, 0), .Zero_Object_Id)
	expect_refused_untouched(t, &encoder, encode_bind_image_memory(&encoder, 3, 70, 0, 0), .Zero_Object_Id)

	encoder = encoder_init(storage[:])
	testing.expect_value(t, encode_create_image_view(&encoder, 3, 70, 71, .B8G8R8A8_Unorm, COLOR_RANGE), Venus_Problem.None)
	bytes = encoder_bytes(&encoder)
	testing.expect_value(t, len(bytes), 116)
	command = decode_single(t, bytes, .Create_Image_View)
	testing.expect_value(t, command.objects[1], Object_Id(70))
	testing.expect_value(t, command.objects[2], Object_Id(71))
	testing.expect_value(t, command.values[1], u64(Format.B8G8R8A8_Unorm))
	expect_word_refused(t, bytes, 28, 1, .Next_Chain_Refused)
	expect_word_refused(t, bytes, 40, 0, .Zero_Object_Id)
	expect_word_refused(t, bytes, 48, 3, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 52, 0, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 56, 7, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 68, 0xFFFF_FFFF, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 72, 0, .Missing_Flag_Bits)
	expect_word_refused(t, bytes, 72, 8, .Unknown_Flag_Bits)
	expect_word_refused(t, bytes, 80, 0, .Zero_Extent)
	expect_word_refused(t, bytes, 88, 0, .Zero_Extent)
	expect_word_refused(t, bytes, 108, 0, .Zero_Object_Id)
	expect_each_prefix_refused(t, bytes)
	encoder = encoder_init(storage[:])
	expect_refused_untouched(t, &encoder, encode_create_image_view(&encoder, 3, 0, 71, .B8G8R8A8_Unorm, COLOR_RANGE), .Zero_Object_Id)
	expect_refused_untouched(t, &encoder, encode_create_image_view(&encoder, 3, 70, 71, .R32G32_Signed_Float, COLOR_RANGE), .Unknown_Enum_Word)
	expect_refused_untouched(t, &encoder, encode_create_image_view(&encoder, 3, 70, 71, .B8G8R8A8_Unorm, {aspects = {.Color}, level_count = 0, layer_count = 1}), .Zero_Extent)
	expect_refused_untouched(t, &encoder, encode_create_image_view(&encoder, 3, 70, 71, .B8G8R8A8_Unorm, {level_count = 1, layer_count = 1}), .Unknown_Flag_Bits)
}

@(test)
create_shader_module_round_trip_and_refusals :: proc(t: ^testing.T) {
	code := shader_bytes()
	storage: [256]u8
	encoder := encoder_init(storage[:])
	testing.expect_value(t, encode_create_shader_module(&encoder, 3, 90, code[:]), Venus_Problem.None)
	bytes := encoder_bytes(&encoder)
	testing.expect_value(t, len(bytes), 104)
	command := decode_single(t, bytes, .Create_Shader_Module)
	testing.expect_value(t, command.values[0], u64(24))
	testing.expect_value(t, command.objects[1], Object_Id(90))
	testing.expect(t, string(bytes[56:80]) == string(code[:]), "the code must travel unchanged")

	expect_word_refused(t, bytes, 24, 14, .Structure_Type_Mismatch)
	expect_word_refused(t, bytes, 40, 0, .Zero_Extent)
	expect_word_refused(t, bytes, 40, 22, .Misaligned_Length)
	expect_word_refused(t, bytes, 40, MAX_SHADER_CODE_WORDS * 4 + 4, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 48, 5, .Array_Size_Mismatch)
	expect_word_refused(t, bytes, 56, 0, .Shader_Code_Invalid)
	expect_word_refused(t, bytes, 72, 1, .Shader_Code_Invalid) // the schema word
	expect_word_refused(t, bytes, 76, (9 << 16) | 17, .Shader_Code_Invalid) // an instruction past the end
	expect_word_refused(t, bytes, 96, 0, .Zero_Object_Id)
	expect_each_prefix_refused(t, bytes)

	encoder = encoder_init(storage[:])
	expect_refused_untouched(t, &encoder, encode_create_shader_module(&encoder, 3, 90, nil), .Shader_Code_Invalid)
	expect_refused_untouched(t, &encoder, encode_create_shader_module(&encoder, 3, 90, code[:22]), .Shader_Code_Invalid)
	expect_refused_untouched(t, &encoder, encode_create_shader_module(&encoder, 3, 90, code[:20]), .Shader_Code_Invalid)
	bad := code
	bad[0] = 0
	expect_refused_untouched(t, &encoder, encode_create_shader_module(&encoder, 3, 90, bad[:]), .Shader_Code_Invalid)
	expect_refused_untouched(t, &encoder, encode_create_shader_module(&encoder, 0, 90, code[:]), .Zero_Object_Id)
	huge: [MAX_SHADER_CODE_WORDS * 4 + 4]u8
	expect_refused_untouched(t, &encoder, encode_create_shader_module(&encoder, 3, 90, huge[:]), .Count_Out_Of_Range)
}

@(test)
create_pipeline_layout_round_trip_and_refusals :: proc(t: ^testing.T) {
	storage: [256]u8
	encoder := encoder_init(storage[:])
	ranges := [1]Push_Constant_Range{{stages = {.Vertex}, offset = 0, size = 8}}
	testing.expect_value(t, encode_create_pipeline_layout(&encoder, 3, 400, nil, ranges[:]), Venus_Problem.None)
	bytes := encoder_bytes(&encoder)
	testing.expect_value(t, len(bytes), 100)
	command := decode_single(t, bytes, .Create_Pipeline_Layout)
	testing.expect_value(t, command.values[0], u64(transmute(u32)Shader_Stages{.Vertex}))
	testing.expect_value(t, command.values[2], u64(8))
	testing.expect_value(t, command.objects[1], Object_Id(400))
	expect_word_refused(t, bytes, 40, MAX_ARRAY_ELEMENTS + 1, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 44, 1, .Array_Size_Mismatch)
	expect_word_refused(t, bytes, 52, MAX_ARRAY_ELEMENTS + 1, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 64, 0, .Missing_Flag_Bits)
	expect_word_refused(t, bytes, 64, 0x40, .Unknown_Flag_Bits)
	expect_word_refused(t, bytes, 68, 2, .Misaligned_Length)
	expect_word_refused(t, bytes, 72, 0, .Zero_Extent)
	expect_word_refused(t, bytes, 72, MAX_PUSH_CONSTANT_BYTES + 4, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 68, MAX_PUSH_CONSTANT_BYTES - 4, .Count_Out_Of_Range)
	expect_each_prefix_refused(t, bytes)

	// Set layouts travel as ids.
	encoder = encoder_init(storage[:])
	sets := [2]Object_Id{7, 8}
	testing.expect_value(t, encode_create_pipeline_layout(&encoder, 3, 400, sets[:], nil), Venus_Problem.None)
	command = decode_single(t, encoder_bytes(&encoder), .Create_Pipeline_Layout)
	testing.expect_value(t, command.objects[1], Object_Id(7))
	testing.expect_value(t, command.objects[2], Object_Id(8))
	testing.expect_value(t, command.objects[3], Object_Id(400))

	encoder = encoder_init(storage[:])
	zero_set := [1]Object_Id{0}
	expect_refused_untouched(t, &encoder, encode_create_pipeline_layout(&encoder, 3, 400, zero_set[:], nil), .Zero_Object_Id)
	too_many: [MAX_ARRAY_ELEMENTS + 1]Push_Constant_Range
	expect_refused_untouched(t, &encoder, encode_create_pipeline_layout(&encoder, 3, 400, nil, too_many[:]), .Count_Out_Of_Range)
	bad := [1]Push_Constant_Range{{stages = {.Vertex}, offset = 124, size = 8}}
	expect_refused_untouched(t, &encoder, encode_create_pipeline_layout(&encoder, 3, 400, nil, bad[:]), .Count_Out_Of_Range)
	bad[0] = {stages = {}, offset = 0, size = 8}
	expect_refused_untouched(t, &encoder, encode_create_pipeline_layout(&encoder, 3, 400, nil, bad[:]), .Missing_Flag_Bits)
	bad[0] = {stages = {.Fragment}, offset = 0, size = 6}
	expect_refused_untouched(t, &encoder, encode_create_pipeline_layout(&encoder, 3, 400, nil, bad[:]), .Misaligned_Length)
	// The whole push constant range is accepted.
	bad[0] = {stages = {.Fragment}, offset = 0, size = MAX_PUSH_CONSTANT_BYTES}
	testing.expect_value(t, encode_create_pipeline_layout(&encoder, 3, 400, nil, bad[:]), Venus_Problem.None)
}

@(private = "file")
ATTACHMENT :: Color_Attachment_Description{format = .R8G8B8A8_Unorm, load_op = .Clear, store_op = .Store, initial_layout = .Undefined, final_layout = .Color_Attachment_Optimal}

@(test)
create_render_pass_round_trip_and_refusals :: proc(t: ^testing.T) {
	storage: [256]u8
	encoder := encoder_init(storage[:])
	testing.expect_value(t, encode_create_render_pass(&encoder, 3, 1001, ATTACHMENT), Venus_Problem.None)
	bytes := encoder_bytes(&encoder)
	testing.expect_value(t, len(bytes), 204)
	command := decode_single(t, bytes, .Create_Render_Pass)
	testing.expect_value(t, command.values[0], u64(Format.R8G8B8A8_Unorm))
	testing.expect_value(t, command.values[2], u64(Attachment_Load_Op.Clear))
	testing.expect_value(t, command.values[6], u64(Image_Layout.Undefined))
	testing.expect_value(t, command.values[7], u64(Image_Layout.Color_Attachment_Optimal))
	testing.expect_value(t, command.objects[1], Object_Id(1001))

	expect_word_refused(t, bytes, 40, 0, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 44, 2, .Array_Size_Mismatch)
	expect_word_refused(t, bytes, 52, 1, .Unknown_Flag_Bits)
	expect_word_refused(t, bytes, 64, 3, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 68, 2, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 80, 4, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 84, 0, .Layout_Transition_Invalid)
	expect_word_refused(t, bytes, 88, 0, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 104, 1, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 108, MAX_ARRAY_ELEMENTS + 1, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 132, 1, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 136, 3, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 140, 2, .Array_Size_Mismatch)
	expect_word_refused(t, bytes, 148, 2, .Pointer_Invalid)
	expect_word_refused(t, bytes, 156, MAX_ARRAY_ELEMENTS + 1, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 168, MAX_ARRAY_ELEMENTS + 1, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 196, 0, .Zero_Object_Id)
	expect_each_prefix_refused(t, bytes)

	// VK_ATTACHMENT_UNUSED is a reference that names no attachment.
	unused: [256]u8
	copy(unused[:], bytes)
	byte_order.write_u32_little_endian(unused[:], 132, ATTACHMENT_UNUSED)
	decode_single(t, unused[:len(bytes)], .Create_Render_Pass)

	// A pass that keeps the contents and ends in the layout of a present.
	encoder = encoder_init(storage[:])
	kept := ATTACHMENT
	kept.load_op = .Load
	kept.initial_layout = .Color_Attachment_Optimal
	kept.final_layout = .Present_Source
	testing.expect_value(t, encode_create_render_pass(&encoder, 3, 1001, kept), Venus_Problem.None)
	command = decode_single(t, encoder_bytes(&encoder), .Create_Render_Pass)
	testing.expect_value(t, command.values[7], u64(Image_Layout.Present_Source))

	encoder = encoder_init(storage[:])
	refused := ATTACHMENT
	refused.final_layout = .Undefined
	expect_refused_untouched(t, &encoder, encode_create_render_pass(&encoder, 3, 1001, refused), .Layout_Transition_Invalid)
	refused = ATTACHMENT
	refused.load_op = Attachment_Load_Op(3)
	expect_refused_untouched(t, &encoder, encode_create_render_pass(&encoder, 3, 1001, refused), .Unknown_Enum_Word)
	refused = ATTACHMENT
	refused.initial_layout = Image_Layout(3)
	expect_refused_untouched(t, &encoder, encode_create_render_pass(&encoder, 3, 1001, refused), .Unknown_Enum_Word)
	refused = ATTACHMENT
	refused.format = .R32G32B32A32_Signed_Float
	expect_refused_untouched(t, &encoder, encode_create_render_pass(&encoder, 3, 1001, refused), .Unknown_Enum_Word)
	expect_refused_untouched(t, &encoder, encode_create_render_pass(&encoder, 3, 0, ATTACHMENT), .Zero_Object_Id)
}

@(test)
create_framebuffer_round_trip_and_refusals :: proc(t: ^testing.T) {
	storage: [256]u8
	encoder := encoder_init(storage[:])
	views := [1]Object_Id{71}
	testing.expect_value(t, encode_create_framebuffer(&encoder, 3, 2001, 1001, views[:], 640, 480), Venus_Problem.None)
	bytes := encoder_bytes(&encoder)
	testing.expect_value(t, len(bytes), 104)
	command := decode_single(t, bytes, .Create_Framebuffer)
	testing.expect_value(t, command.objects[1], Object_Id(1001))
	testing.expect_value(t, command.objects[2], Object_Id(71))
	testing.expect_value(t, command.objects[3], Object_Id(2001))
	testing.expect_value(t, command.values[0], u64(640))
	testing.expect_value(t, command.values[1], u64(480))
	expect_word_refused(t, bytes, 40, 0, .Zero_Object_Id)
	expect_word_refused(t, bytes, 48, 0, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 48, MAX_ARRAY_ELEMENTS + 1, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 52, 2, .Array_Size_Mismatch)
	expect_word_refused(t, bytes, 60, 0, .Zero_Object_Id)
	expect_word_refused(t, bytes, 68, 0, .Zero_Extent)
	expect_word_refused(t, bytes, 72, MAX_IMAGE_DIMENSION + 1, .Dimension_Too_Large)
	expect_word_refused(t, bytes, 76, 0, .Count_Out_Of_Range)
	expect_each_prefix_refused(t, bytes)

	encoder = encoder_init(storage[:])
	expect_refused_untouched(t, &encoder, encode_create_framebuffer(&encoder, 3, 2001, 1001, nil, 640, 480), .Count_Out_Of_Range)
	zero_view := [1]Object_Id{0}
	expect_refused_untouched(t, &encoder, encode_create_framebuffer(&encoder, 3, 2001, 1001, zero_view[:], 640, 480), .Zero_Object_Id)
	expect_refused_untouched(t, &encoder, encode_create_framebuffer(&encoder, 3, 2001, 0, views[:], 640, 480), .Zero_Object_Id)
	expect_refused_untouched(t, &encoder, encode_create_framebuffer(&encoder, 3, 2001, 1001, views[:], 640, 0), .Zero_Extent)
	expect_refused_untouched(t, &encoder, encode_create_framebuffer(&encoder, 3, 2001, 1001, views[:], MAX_IMAGE_DIMENSION + 1, 480), .Dimension_Too_Large)
}

@(private = "file")
pipeline_description :: proc(attributes: []Vertex_Attribute) -> Graphics_Pipeline_Description {
	return {
		vertex_shader     = 90,
		fragment_shader   = 91,
		entry_point       = "main",
		vertex_stride     = 32,
		vertex_attributes = attributes,
		topology          = .Triangle_List,
		blend             = DRAW_TABLE_BLEND,
		layout            = 400,
		render_pass       = 1001,
	}
}

@(test)
create_graphics_pipelines_round_trip_and_refusals :: proc(t: ^testing.T) {
	attributes := DRAW_TABLE_VERTEX_ATTRIBUTES
	storage: [1024]u8
	encoder := encoder_init(storage[:])
	testing.expect_value(t, encode_create_graphics_pipelines(&encoder, 3, 5001, pipeline_description(attributes[:])), Venus_Problem.None)
	bytes := encoder_bytes(&encoder)
	testing.expect_value(t, len(bytes), 688)
	command := decode_single(t, bytes, .Create_Graphics_Pipelines)
	testing.expect_value(t, command.objects[1], Object_Id(0)) // no pipeline cache
	testing.expect_value(t, command.objects[2], Object_Id(90))
	testing.expect_value(t, command.objects[3], Object_Id(91))
	testing.expect_value(t, command.objects[4], Object_Id(400))
	testing.expect_value(t, command.objects[5], Object_Id(1001))
	testing.expect_value(t, command.objects[7], Object_Id(5001))
	testing.expect_value(t, command.values[0], u64(transmute(u32)Shader_Stages{.Vertex}))
	testing.expect_value(t, command.values[1], u64(transmute(u32)Shader_Stages{.Fragment}))
	testing.expect_value(t, command.values[3], u64(32)) // the stride

	expect_word_refused(t, bytes, 24, 0, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 28, 2, .Array_Size_Mismatch)
	expect_word_refused(t, bytes, 36, 30, .Structure_Type_Mismatch)
	expect_word_refused(t, bytes, 40, 1, .Next_Chain_Refused)
	expect_word_refused(t, bytes, 80, 0, .Missing_Flag_Bits)
	expect_word_refused(t, bytes, 80, 0x11, .Unknown_Flag_Bits) // two stages in one stage
	expect_word_refused(t, bytes, 80, 0x40, .Unknown_Flag_Bits)
	expect_word_refused(t, bytes, 84, 0, .Zero_Object_Id)
	expect_word_refused(t, bytes, 92, 0, .String_Unterminated)
	expect_word_refused(t, bytes, 104, 0x7878_7878, .String_Unterminated) // the null byte of the name
	expect_word_refused(t, bytes, 92, MAX_STRING_BYTES + 1, .String_Too_Long)
	expect_word_refused(t, bytes, 108, 1, .Pointer_Invalid)
	expect_word_refused(t, bytes, 132, 3, .Unknown_Flag_Bits)
	expect_word_refused(t, bytes, 168, 0, .Pointer_Invalid)
	expect_word_refused(t, bytes, 212, 2, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 216, MAX_ARRAY_ELEMENTS + 1, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 236, u32(Format.B8G8R8A8_Unorm), .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 236, 0, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 300, 6, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 304, 2, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 308, 1, .Pointer_Invalid)
	expect_word_refused(t, bytes, 340, 0, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 344, 2, .Array_Size_Mismatch)
	expect_word_refused(t, bytes, 396, 3, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 400, 4, .Unknown_Flag_Bits)
	expect_word_refused(t, bytes, 404, 2, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 452, 2, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 464, 2, .Array_Size_Mismatch)
	expect_word_refused(t, bytes, 480, 1, .Pointer_Invalid)
	expect_word_refused(t, bytes, 512, 1, .Unknown_Enum_Word) // a logic operation
	expect_word_refused(t, bytes, 516, 3, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 532, 2, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 536, 10, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 544, 5, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 560, 0x10, .Unknown_Flag_Bits)
	expect_word_refused(t, bytes, 564, 3, .Array_Size_Mismatch)
	expect_word_refused(t, bytes, 588, 2, .Pointer_Invalid)
	expect_word_refused(t, bytes, 624, 2, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 632, 0, .Zero_Object_Id)
	expect_word_refused(t, bytes, 640, 0, .Zero_Object_Id)
	expect_word_refused(t, bytes, 664, 1, .Pointer_Invalid)
	expect_word_refused(t, bytes, 672, 2, .Array_Size_Mismatch)
	expect_word_refused(t, bytes, 680, 0, .Zero_Object_Id)
	expect_each_prefix_refused(t, bytes)

	encoder = encoder_init(storage[:])
	description := pipeline_description(attributes[:])
	description.layout = 0
	expect_refused_untouched(t, &encoder, encode_create_graphics_pipelines(&encoder, 3, 5001, description), .Zero_Object_Id)
	expect_refused_untouched(t, &encoder, encode_create_graphics_pipelines(&encoder, 3, 0, pipeline_description(attributes[:])), .Zero_Object_Id)
	description = pipeline_description(attributes[:])
	description.entry_point = ""
	expect_refused_untouched(t, &encoder, encode_create_graphics_pipelines(&encoder, 3, 5001, description), .String_Unterminated)
	description.entry_point = "ma\x00in"
	expect_refused_untouched(t, &encoder, encode_create_graphics_pipelines(&encoder, 3, 5001, description), .String_Unterminated)
	description = pipeline_description(nil)
	expect_refused_untouched(t, &encoder, encode_create_graphics_pipelines(&encoder, 3, 5001, description), .Count_Out_Of_Range)
	many: [MAX_VERTEX_ATTRIBUTES + 1]Vertex_Attribute
	description = pipeline_description(many[:])
	expect_refused_untouched(t, &encoder, encode_create_graphics_pipelines(&encoder, 3, 5001, description), .Count_Out_Of_Range)
	// An attribute past the stride, a color format as an attribute, two
	// attributes at one location.
	past := [1]Vertex_Attribute{{location = 0, format = .R32G32B32A32_Signed_Float, offset = 24}}
	expect_refused_untouched(t, &encoder, encode_create_graphics_pipelines(&encoder, 3, 5001, pipeline_description(past[:])), .Dimension_Too_Large)
	color := [1]Vertex_Attribute{{location = 0, format = .B8G8R8A8_Unorm, offset = 0}}
	expect_refused_untouched(t, &encoder, encode_create_graphics_pipelines(&encoder, 3, 5001, pipeline_description(color[:])), .Unknown_Enum_Word)
	twice := [2]Vertex_Attribute{{location = 1, format = .R32G32_Signed_Float, offset = 0}, {location = 1, format = .R32G32_Signed_Float, offset = 8}}
	expect_refused_untouched(t, &encoder, encode_create_graphics_pipelines(&encoder, 3, 5001, pipeline_description(twice[:])), .Count_Out_Of_Range)
	description = pipeline_description(attributes[:])
	description.topology = Primitive_Topology(6)
	expect_refused_untouched(t, &encoder, encode_create_graphics_pipelines(&encoder, 3, 5001, description), .Unknown_Enum_Word)
	description = pipeline_description(attributes[:])
	description.blend.alpha_operation = Blend_Op(5)
	expect_refused_untouched(t, &encoder, encode_create_graphics_pipelines(&encoder, 3, 5001, description), .Unknown_Enum_Word)
	description = pipeline_description(attributes[:])
	description.vertex_stride = 0
	expect_refused_untouched(t, &encoder, encode_create_graphics_pipelines(&encoder, 3, 5001, description), .Zero_Extent)
}

@(private = "file")
TO_PRESENT :: Image_Memory_Barrier{
	source_access      = {.Transfer_Read},
	destination_access = {},
	old_layout         = .Transfer_Source_Optimal,
	new_layout         = .Present_Source,
	image              = 70,
	range              = COLOR_RANGE,
}

@(test)
pipeline_barrier_round_trip_and_refusals :: proc(t: ^testing.T) {
	storage: [256]u8
	encoder := encoder_init(storage[:])
	memory := [1]Memory_Barrier{{source_access = {.Transfer_Write}, destination_access = {.Vertex_Attribute_Read}}}
	to_attachment := [1]Image_Memory_Barrier{{
		destination_access = {.Color_Attachment_Write},
		old_layout         = .Undefined,
		new_layout         = .Color_Attachment_Optimal,
		image              = 70,
		range              = COLOR_RANGE,
	}}
	testing.expect_value(t, encode_cmd_pipeline_barrier(&encoder, 100, {.Transfer}, {.Vertex_Input, .Color_Attachment_Output}, memory[:], to_attachment[:]), Venus_Problem.None)
	bytes := encoder_bytes(&encoder)
	testing.expect_value(t, len(bytes), 148)
	command := decode_single(t, bytes, .Cmd_Pipeline_Barrier)
	testing.expect_value(t, command.flags, Command_Flags{})
	testing.expect_value(t, command.values[0], u64(transmute(u32)Pipeline_Stages{.Transfer}))
	testing.expect_value(t, command.values[6], u64(Image_Layout.Undefined))
	testing.expect_value(t, command.values[7], u64(Image_Layout.Color_Attachment_Optimal))
	testing.expect_value(t, command.values[8], u64(QUEUE_FAMILY_IGNORED))
	testing.expect_value(t, command.objects[1], Object_Id(70))

	expect_word_refused(t, bytes, 8, 0, .Zero_Object_Id)
	expect_word_refused(t, bytes, 16, 0, .Missing_Flag_Bits)
	expect_word_refused(t, bytes, 20, 0x2_0000, .Unknown_Flag_Bits)
	expect_word_refused(t, bytes, 24, 1, .Unknown_Flag_Bits)
	expect_word_refused(t, bytes, 28, MAX_ARRAY_ELEMENTS + 1, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 32, 2, .Array_Size_Mismatch)
	expect_word_refused(t, bytes, 40, u32(Structure_Type.Image_Memory_Barrier), .Structure_Type_Mismatch)
	expect_word_refused(t, bytes, 44, 1, .Next_Chain_Refused)
	expect_word_refused(t, bytes, 52, 0x2_0000, .Unknown_Flag_Bits)
	expect_word_refused(t, bytes, 60, 1, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 72, MAX_ARRAY_ELEMENTS + 1, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 84, u32(Structure_Type.Memory_Barrier), .Structure_Type_Mismatch)
	expect_word_refused(t, bytes, 88, 1, .Next_Chain_Refused)
	expect_word_refused(t, bytes, 100, 0x8000_0000, .Unknown_Flag_Bits)
	expect_word_refused(t, bytes, 104, 3, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 108, u32(Image_Layout.Undefined), .Layout_Transition_Invalid)
	expect_word_refused(t, bytes, 108, 1000001001, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 120, 0, .Zero_Object_Id)
	expect_word_refused(t, bytes, 128, 0, .Missing_Flag_Bits)
	expect_word_refused(t, bytes, 136, 0, .Zero_Extent)
	expect_word_refused(t, bytes, 144, 0, .Zero_Extent)
	expect_each_prefix_refused(t, bytes)
	// A barrier command with no barrier at all.
	empty: [256]u8
	copy(empty[:], bytes)
	for &byte_value in empty[28:64] {
		byte_value = 0
	}
	decoder := decoder_init(empty[:64])
	_, problem := command_decode_next(&decoder)
	testing.expect_value(t, problem, Venus_Problem.Count_Out_Of_Range)

	// The layout of a present: TRANSFER_SRC_OPTIMAL to PRESENT_SRC_KHR.
	encoder = encoder_init(storage[:])
	present := [1]Image_Memory_Barrier{TO_PRESENT}
	testing.expect_value(t, encode_cmd_pipeline_barrier(&encoder, 100, {.Transfer}, {.Bottom_Of_Pipe}, nil, present[:]), Venus_Problem.None)
	command = decode_single(t, encoder_bytes(&encoder), .Cmd_Pipeline_Barrier)
	testing.expect_value(t, command.values[4], u64(Image_Layout.Transfer_Source_Optimal))
	testing.expect_value(t, command.values[5], u64(Image_Layout.Present_Source))

	encoder = encoder_init(storage[:])
	expect_refused_untouched(t, &encoder, encode_cmd_pipeline_barrier(&encoder, 100, {.Transfer}, {.Bottom_Of_Pipe}, nil, nil), .Count_Out_Of_Range)
	expect_refused_untouched(t, &encoder, encode_cmd_pipeline_barrier(&encoder, 0, {.Transfer}, {.Bottom_Of_Pipe}, nil, present[:]), .Zero_Object_Id)
	expect_refused_untouched(t, &encoder, encode_cmd_pipeline_barrier(&encoder, 100, {}, {.Bottom_Of_Pipe}, nil, present[:]), .Missing_Flag_Bits)
	expect_refused_untouched(t, &encoder, encode_cmd_pipeline_barrier(&encoder, 100, transmute(Pipeline_Stages)u32(0x10_0000), {.Bottom_Of_Pipe}, nil, present[:]), .Unknown_Flag_Bits)
	too_many: [MAX_ARRAY_ELEMENTS + 1]Image_Memory_Barrier
	for &barrier in too_many {
		barrier = TO_PRESENT
	}
	expect_refused_untouched(t, &encoder, encode_cmd_pipeline_barrier(&encoder, 100, {.Transfer}, {.Bottom_Of_Pipe}, nil, too_many[:]), .Count_Out_Of_Range)
	refused := [1]Image_Memory_Barrier{TO_PRESENT}
	refused[0].new_layout = .Undefined
	expect_refused_untouched(t, &encoder, encode_cmd_pipeline_barrier(&encoder, 100, {.Transfer}, {.Bottom_Of_Pipe}, nil, refused[:]), .Layout_Transition_Invalid)
	refused[0] = TO_PRESENT
	refused[0].old_layout = Image_Layout(3)
	expect_refused_untouched(t, &encoder, encode_cmd_pipeline_barrier(&encoder, 100, {.Transfer}, {.Bottom_Of_Pipe}, nil, refused[:]), .Unknown_Enum_Word)
	refused[0] = TO_PRESENT
	refused[0].image = 0
	expect_refused_untouched(t, &encoder, encode_cmd_pipeline_barrier(&encoder, 100, {.Transfer}, {.Bottom_Of_Pipe}, nil, refused[:]), .Zero_Object_Id)
	refused[0] = TO_PRESENT
	refused[0].range.layer_count = 0
	expect_refused_untouched(t, &encoder, encode_cmd_pipeline_barrier(&encoder, 100, {.Transfer}, {.Bottom_Of_Pipe}, nil, refused[:]), .Zero_Extent)
	refused[0] = TO_PRESENT
	refused[0].destination_access = transmute(Access_Flags)u32(0x8000_0000)
	expect_refused_untouched(t, &encoder, encode_cmd_pipeline_barrier(&encoder, 100, {.Transfer}, {.Bottom_Of_Pipe}, nil, refused[:]), .Unknown_Flag_Bits)
	bad_memory := [1]Memory_Barrier{{source_access = transmute(Access_Flags)u32(0x4_0000)}}
	expect_refused_untouched(t, &encoder, encode_cmd_pipeline_barrier(&encoder, 100, {.Transfer}, {.Host}, bad_memory[:], nil), .Unknown_Flag_Bits)
}

@(private = "file")
READBACK_REGION :: Buffer_Image_Copy{buffer_row_length = 640, aspects = {.Color}, layer_count = 1, width = 640, height = 480, depth = 1}

@(test)
copy_image_to_buffer_round_trip_and_refusals :: proc(t: ^testing.T) {
	storage: [256]u8
	encoder := encoder_init(storage[:])
	testing.expect_value(t, encode_cmd_copy_image_to_buffer(&encoder, 100, 70, .Transfer_Source_Optimal, 3003, READBACK_REGION), Venus_Problem.None)
	bytes := encoder_bytes(&encoder)
	command := decode_single(t, bytes, .Cmd_Copy_Image_To_Buffer)
	testing.expect_value(t, command.objects[1], Object_Id(70))
	testing.expect_value(t, command.objects[2], Object_Id(3003))
	testing.expect_value(t, command.values[0], u64(Image_Layout.Transfer_Source_Optimal))
	testing.expect_value(t, command.values[2], u64(640))
	expect_word_refused(t, bytes, 16, 0, .Zero_Object_Id)
	expect_word_refused(t, bytes, 24, u32(Image_Layout.Transfer_Destination_Optimal), .Layout_Transition_Invalid)
	expect_word_refused(t, bytes, 24, u32(Image_Layout.Color_Attachment_Optimal), .Layout_Transition_Invalid)
	expect_word_refused(t, bytes, 24, 99, .Unknown_Enum_Word)
	expect_word_refused(t, bytes, 28, 0, .Zero_Object_Id)
	expect_word_refused(t, bytes, 36, 0, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 40, 2, .Array_Size_Mismatch)
	expect_word_refused(t, bytes, 64, 8, .Unknown_Flag_Bits)
	expect_each_prefix_refused(t, bytes)
	// GENERAL is the other layout that a copy reads.
	encoder = encoder_init(storage[:])
	testing.expect_value(t, encode_cmd_copy_image_to_buffer(&encoder, 100, 70, .General, 3003, READBACK_REGION), Venus_Problem.None)
	decode_single(t, encoder_bytes(&encoder), .Cmd_Copy_Image_To_Buffer)

	encoder = encoder_init(storage[:])
	expect_refused_untouched(t, &encoder, encode_cmd_copy_image_to_buffer(&encoder, 100, 70, .Present_Source, 3003, READBACK_REGION), .Layout_Transition_Invalid)
	expect_refused_untouched(t, &encoder, encode_cmd_copy_image_to_buffer(&encoder, 100, 70, Image_Layout(4), 3003, READBACK_REGION), .Unknown_Enum_Word)
	expect_refused_untouched(t, &encoder, encode_cmd_copy_image_to_buffer(&encoder, 100, 0, .Transfer_Source_Optimal, 3003, READBACK_REGION), .Zero_Object_Id)
	region := READBACK_REGION
	region.height = 0
	expect_refused_untouched(t, &encoder, encode_cmd_copy_image_to_buffer(&encoder, 100, 70, .Transfer_Source_Optimal, 3003, region), .Zero_Extent)
	region = READBACK_REGION
	region.aspects = {}
	expect_refused_untouched(t, &encoder, encode_cmd_copy_image_to_buffer(&encoder, 100, 70, .Transfer_Source_Optimal, 3003, region), .Unknown_Flag_Bits)
}

@(test)
update_buffer_and_push_constants_round_trip_and_refusals :: proc(t: ^testing.T) {
	data := [8]u8{1, 2, 3, 4, 5, 6, 7, 8}
	storage: [256]u8
	encoder := encoder_init(storage[:])
	testing.expect_value(t, encode_cmd_update_buffer(&encoder, 100, 3001, 64, data[:]), Venus_Problem.None)
	bytes := encoder_bytes(&encoder)
	testing.expect_value(t, len(bytes), 56)
	command := decode_single(t, bytes, .Cmd_Update_Buffer)
	testing.expect_value(t, command.objects[1], Object_Id(3001))
	testing.expect_value(t, command.values[0], u64(64))
	testing.expect_value(t, command.values[1], u64(8))
	testing.expect(t, string(bytes[48:56]) == string(data[:]), "the data must travel unchanged")
	expect_word_refused(t, bytes, 16, 0, .Zero_Object_Id)
	expect_word_refused(t, bytes, 24, 2, .Misaligned_Length)
	expect_word_refused(t, bytes, 32, 0, .Zero_Extent)
	expect_word_refused(t, bytes, 32, 6, .Misaligned_Length)
	expect_word_refused(t, bytes, 32, MAX_UPDATE_BUFFER_BYTES + 4, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 40, 4, .Array_Size_Mismatch)
	expect_each_prefix_refused(t, bytes)

	encoder = encoder_init(storage[:])
	expect_refused_untouched(t, &encoder, encode_cmd_update_buffer(&encoder, 100, 3001, 0, nil), .Zero_Extent)
	expect_refused_untouched(t, &encoder, encode_cmd_update_buffer(&encoder, 100, 3001, 0, data[:6]), .Misaligned_Length)
	expect_refused_untouched(t, &encoder, encode_cmd_update_buffer(&encoder, 100, 3001, 2, data[:]), .Misaligned_Length)
	expect_refused_untouched(t, &encoder, encode_cmd_update_buffer(&encoder, 100, 0, 0, data[:]), .Zero_Object_Id)
	large: [MAX_UPDATE_BUFFER_BYTES + 4]u8
	expect_refused_untouched(t, &encoder, encode_cmd_update_buffer(&encoder, 100, 3001, 0, large[:]), .Count_Out_Of_Range)
	// The bound itself is accepted.
	measure := encoder_measure()
	testing.expect_value(t, encode_cmd_update_buffer(&measure, 100, 3001, 0, large[:MAX_UPDATE_BUFFER_BYTES]), Venus_Problem.None)

	encoder = encoder_init(storage[:])
	testing.expect_value(t, encode_cmd_push_constants(&encoder, 100, 400, {.Vertex}, 0, data[:]), Venus_Problem.None)
	bytes = encoder_bytes(&encoder)
	testing.expect_value(t, len(bytes), 52)
	command = decode_single(t, bytes, .Cmd_Push_Constants)
	testing.expect_value(t, command.objects[1], Object_Id(400))
	testing.expect_value(t, command.values[2], u64(8))
	expect_word_refused(t, bytes, 16, 0, .Zero_Object_Id)
	expect_word_refused(t, bytes, 24, 0, .Missing_Flag_Bits)
	expect_word_refused(t, bytes, 28, MAX_PUSH_CONSTANT_BYTES - 4, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 32, 12, .Array_Size_Mismatch)
	expect_each_prefix_refused(t, bytes)
	encoder = encoder_init(storage[:])
	expect_refused_untouched(t, &encoder, encode_cmd_push_constants(&encoder, 100, 0, {.Vertex}, 0, data[:]), .Zero_Object_Id)
	expect_refused_untouched(t, &encoder, encode_cmd_push_constants(&encoder, 100, 400, {}, 0, data[:]), .Missing_Flag_Bits)
	expect_refused_untouched(t, &encoder, encode_cmd_push_constants(&encoder, 100, 400, {.Vertex}, 124, data[:]), .Count_Out_Of_Range)
	expect_refused_untouched(t, &encoder, encode_cmd_push_constants(&encoder, 100, 400, {.Vertex}, 0, nil), .Zero_Extent)
}

@(test)
set_viewport_round_trip_and_refusals :: proc(t: ^testing.T) {
	storage: [128]u8
	encoder := encoder_init(storage[:])
	testing.expect_value(t, encode_cmd_set_viewport(&encoder, 100, {width = 640, height = 480, max_depth = 1}), Venus_Problem.None)
	bytes := encoder_bytes(&encoder)
	testing.expect_value(t, len(bytes), 56)
	command := decode_single(t, bytes, .Cmd_Set_Viewport)
	testing.expect_value(t, command.values[3], u64(transmute(u32)f32(640)))
	testing.expect_value(t, command.values[6], u64(transmute(u32)f32(1)))
	expect_word_refused(t, bytes, 20, 0, .Count_Out_Of_Range)
	expect_word_refused(t, bytes, 24, 2, .Array_Size_Mismatch)
	expect_word_refused(t, bytes, 40, 0, .Zero_Extent)
	expect_word_refused(t, bytes, 40, 0x7FC0_0000, .Zero_Extent) // NaN
	expect_word_refused(t, bytes, 44, transmute(u32)f32(-1), .Zero_Extent)
	expect_word_refused(t, bytes, 40, transmute(u32)f32(MAX_IMAGE_DIMENSION + 1), .Dimension_Too_Large)
	expect_word_refused(t, bytes, 52, transmute(u32)f32(2), .Count_Out_Of_Range)
	expect_each_prefix_refused(t, bytes)
	encoder = encoder_init(storage[:])
	expect_refused_untouched(t, &encoder, encode_cmd_set_viewport(&encoder, 0, {width = 1, height = 1}), .Zero_Object_Id)
	expect_refused_untouched(t, &encoder, encode_cmd_set_viewport(&encoder, 100, {width = 0, height = 1}), .Zero_Extent)
	expect_refused_untouched(t, &encoder, encode_cmd_set_viewport(&encoder, 100, {width = 1, height = 1, min_depth = -0.5}), .Count_Out_Of_Range)
	nan := transmute(f32)u32(0x7FC0_0000)
	expect_refused_untouched(t, &encoder, encode_cmd_set_viewport(&encoder, 100, {x = nan, width = 1, height = 1}), .Dimension_Too_Large)
}

@(test)
replies_of_the_object_commands :: proc(t: ^testing.T) {
	storage: [128]u8
	creating := [?]Command_Type{.Create_Image, .Create_Image_View, .Create_Shader_Module, .Create_Pipeline_Layout, .Create_Render_Pass, .Create_Framebuffer}
	for command_type in creating {
		encoder := encoder_init(storage[:])
		testing.expect_value(t, encode_create_object_reply(&encoder, command_type, .Success, 70), Venus_Problem.None)
		decoder := decoder_init(encoder_bytes(&encoder))
		result, problem := decode_create_object_reply(&decoder, command_type, 70)
		testing.expect_value(t, problem, Venus_Problem.None)
		testing.expect_value(t, result, Vulkan_Result.Success)
		decoder = decoder_init(encoder_bytes(&encoder))
		_, problem = decode_create_object_reply(&decoder, command_type, 71)
		testing.expect_value(t, problem, Venus_Problem.Object_Id_Mismatch)
		testing.expect_value(t, decoder.cursor, 0)
		decoder = decoder_init(encoder_bytes(&encoder))
		_, problem = decode_result_reply(&decoder, command_type)
		testing.expect_value(t, problem, Venus_Problem.Unexpected_Command_Type)
	}
	encoder := encoder_init(storage[:])
	testing.expect_value(t, encode_result_reply(&encoder, .Bind_Image_Memory, .Error_Out_Of_Device_Memory), Venus_Problem.None)
	decoder := decoder_init(encoder_bytes(&encoder))
	result, problem := decode_result_reply(&decoder, .Bind_Image_Memory)
	testing.expect_value(t, problem, Venus_Problem.None)
	testing.expect_value(t, result, Vulkan_Result.Error_Out_Of_Device_Memory)
	decoder = decoder_init(encoder_bytes(&encoder))
	_, problem = decode_create_object_reply(&decoder, .Bind_Image_Memory, 70)
	testing.expect_value(t, problem, Venus_Problem.Unexpected_Command_Type)

	pipelines := [2]Object_Id{5001, 5002}
	encoder = encoder_init(storage[:])
	testing.expect_value(t, encode_create_graphics_pipelines_reply(&encoder, .Success, pipelines[:]), Venus_Problem.None)
	decoder = decoder_init(encoder_bytes(&encoder))
	result, problem = decode_create_graphics_pipelines_reply(&decoder, pipelines[:])
	testing.expect_value(t, problem, Venus_Problem.None)
	testing.expect_value(t, result, Vulkan_Result.Success)
	testing.expect(t, decoder_done(&decoder))
	other := [2]Object_Id{5001, 5003}
	decoder = decoder_init(encoder_bytes(&encoder))
	_, problem = decode_create_graphics_pipelines_reply(&decoder, other[:])
	testing.expect_value(t, problem, Venus_Problem.Object_Id_Mismatch)
	decoder = decoder_init(encoder_bytes(&encoder))
	_, problem = decode_create_graphics_pipelines_reply(&decoder, pipelines[:1])
	testing.expect_value(t, problem, Venus_Problem.Array_Size_Mismatch)
	decoder = decoder_init(encoder_bytes(&encoder))
	_, problem = decode_create_graphics_pipelines_reply(&decoder, nil)
	testing.expect_value(t, problem, Venus_Problem.Count_Out_Of_Range)
	// A failed pipeline comes back as VK_NULL_HANDLE; a success never does.
	failed := [2]Object_Id{5001, 0}
	encoder = encoder_init(storage[:])
	_ = encode_create_graphics_pipelines_reply(&encoder, .Error_Out_Of_Device_Memory, failed[:])
	decoder = decoder_init(encoder_bytes(&encoder))
	result, problem = decode_create_graphics_pipelines_reply(&decoder, pipelines[:])
	testing.expect_value(t, problem, Venus_Problem.None)
	testing.expect_value(t, result, Vulkan_Result.Error_Out_Of_Device_Memory)
	encoder = encoder_init(storage[:])
	_ = encode_create_graphics_pipelines_reply(&encoder, .Success, failed[:])
	decoder = decoder_init(encoder_bytes(&encoder))
	_, problem = decode_create_graphics_pipelines_reply(&decoder, pipelines[:])
	testing.expect_value(t, problem, Venus_Problem.Object_Id_Mismatch)
	// An unknown VkResult is refused.
	encoder = encoder_init(storage[:])
	_ = encode_create_graphics_pipelines_reply(&encoder, Vulkan_Result(77), pipelines[:])
	decoder = decoder_init(encoder_bytes(&encoder))
	_, problem = decode_create_graphics_pipelines_reply(&decoder, pipelines[:])
	testing.expect_value(t, problem, Venus_Problem.Unknown_Result)
}
