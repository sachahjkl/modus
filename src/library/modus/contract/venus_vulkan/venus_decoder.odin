package venus_vulkan

import "modus:contract/webgpu_subset"

// The command decoder of the renderer side. It reads each command that this
// package encodes, with the rules of the generated vn_decode_vk* functions:
// every array size must equal its count, every structure must have its
// VkStructureType and a null pNext, every enum must name a member. The GPU
// device service runs it on a client stream before it sends the stream to
// the host, and the tests run it on the output of the encoders.

MAX_DECODED_OBJECTS :: 32
MAX_DECODED_VALUES :: 128

// One decoded command: its type, its flags, the object ids in the order of
// the wire, and the other values in the order of the wire. A float value is
// its bits, an int32 value is sign-extended.
Decoded_Command :: struct {
	command_type: Command_Type,
	flags:        Command_Flags,
	object_count: int,
	value_count:  int,
	objects:      [MAX_DECODED_OBJECTS]Object_Id,
	values:       [MAX_DECODED_VALUES]u64,
}

@(private = "file")
keep_object :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command, id: Object_Id) {
	if decoder.problem != .None {
		return
	}
	if command.object_count == MAX_DECODED_OBJECTS {
		fail(decoder, .Count_Out_Of_Range)
		return
	}
	command.objects[command.object_count] = id
	command.object_count += 1
}

@(private = "file")
keep_value :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command, value: u64) {
	if decoder.problem != .None {
		return
	}
	if command.value_count == MAX_DECODED_VALUES {
		fail(decoder, .Count_Out_Of_Range)
		return
	}
	command.values[command.value_count] = value
	command.value_count += 1
}

@(private = "file")
required_object :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command) {
	keep_object(decoder, command, get_required_object(decoder))
}

@(private = "file")
optional_object :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command) {
	keep_object(decoder, command, get_object(decoder))
}

@(private = "file")
value_u32 :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command) -> u32 {
	value := get_u32(decoder)
	keep_value(decoder, command, u64(value))
	return value
}

@(private = "file")
value_i32 :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command) -> i32 {
	value := get_i32(decoder)
	keep_value(decoder, command, u64(i64(value)))
	return value
}

@(private = "file")
value_u64 :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command) -> u64 {
	value := get_u64(decoder)
	keep_value(decoder, command, value)
	return value
}

@(private = "file")
value_flags :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command, known_bits: u32) {
	if value_u32(decoder, command) & ~known_bits != 0 {
		fail(decoder, .Unknown_Flag_Bits)
	}
}

@(private = "file")
zero_word :: proc "contextless" (decoder: ^Decoder) {
	if get_u32(decoder) != 0 {
		fail(decoder, .Unknown_Flag_Bits)
	}
}

// count reads a uint32 count of at most limit elements.
@(private = "file")
count :: proc "contextless" (decoder: ^Decoder, minimum, limit: u32) -> u32 {
	value := get_u32(decoder)
	if decoder.problem == .None && (value < minimum || value > limit) {
		fail(decoder, .Count_Out_Of_Range)
		return 0
	}
	return value
}

// array_present reads the size of an array that is either absent (0) or
// holds count elements.
@(private = "file")
array_present :: proc "contextless" (decoder: ^Decoder, element_count: u32) -> bool {
	size := get_u64(decoder)
	if size == 0 {
		return false
	}
	if size != u64(element_count) {
		fail(decoder, .Array_Size_Mismatch)
		return false
	}
	return true
}

@(private = "file")
empty_array :: proc "contextless" (decoder: ^Decoder) {
	expect_array_size(decoder, 0)
}

@(private = "file")
enum_value :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command, $Enum: typeid) {
	word := value_i32(decoder, command)
	if decoder.problem != .None {
		return
	}
	if _, ok := enum_word_of_i32(Enum, word); !ok {
		fail(decoder, .Unknown_Enum_Word)
	}
}

@(private = "file")
enum_word_of_i32 :: proc "contextless" ($Enum: typeid, word: i32) -> (member: Enum, ok: bool) {
	for candidate in Enum {
		if i64(candidate) == i64(word) {
			return candidate, true
		}
	}
	return {}, false
}

// clear_color reads a VkClearColorValue: its tag, then four 32-bit words.
@(private = "file")
clear_color :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command) {
	tag_word := get_u32(decoder)
	if decoder.problem != .None {
		return
	}
	// Each member of the union carries four words.
	if _, tag_ok := clear_color_tag_of_word(tag_word); !tag_ok {
		fail(decoder, .Unknown_Union_Tag)
		return
	}
	expect_array_size(decoder, 4)
	for _ in 0 ..< 4 {
		value_u32(decoder, command)
	}
}

@(private = "file")
allocator_absent :: proc "contextless" (decoder: ^Decoder) {
	expect_pointer(decoder, false)
}

@(private = "file")
output_object :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command) {
	expect_pointer(decoder, true)
	required_object(decoder, command)
}

// boolean reads a VkBool32: 0 or 1.
@(private = "file")
boolean :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command) -> bool {
	value := value_u32(decoder, command)
	if decoder.problem == .None && value > 1 {
		fail(decoder, .Unknown_Enum_Word)
	}
	return value == 1
}

// flags_required reads a flag word that must have at least one bit, and
// only known bits.
@(private = "file")
flags_required :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command, known_bits: u32) -> u32 {
	value := value_u32(decoder, command)
	if decoder.problem != .None {
		return 0
	}
	if value == 0 {
		fail(decoder, .Missing_Flag_Bits)
	} else if value & ~known_bits != 0 {
		fail(decoder, .Unknown_Flag_Bits)
	}
	return value
}

@(private = "file")
layout_value :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command) -> Image_Layout {
	word := value_i32(decoder, command)
	if decoder.problem != .None {
		return .Undefined
	}
	layout, ok := image_layout_of_word(word)
	if !ok {
		fail(decoder, .Unknown_Enum_Word)
	}
	return layout
}

@(private = "file")
color_format_value :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command) {
	word := value_i32(decoder, command)
	if decoder.problem != .None {
		return
	}
	format, ok := format_of_word(word)
	if !ok || color_format_check(format) != .None {
		fail(decoder, .Unknown_Enum_Word)
	}
}

@(private = "file")
sample_count_value :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command) {
	word := value_u32(decoder, command)
	if decoder.problem != .None {
		return
	}
	if _, ok := sample_count_of_word(word); !ok {
		fail(decoder, .Unknown_Enum_Word)
	}
}

@(private = "file")
subresource_range :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command) {
	flags_required(decoder, command, IMAGE_ASPECT_KNOWN_BITS)
	value_u32(decoder, command) // baseMipLevel
	level_count := value_u32(decoder, command)
	value_u32(decoder, command) // baseArrayLayer
	layer_count := value_u32(decoder, command)
	if decoder.problem == .None && (level_count == 0 || layer_count == 0) {
		fail(decoder, .Zero_Extent)
	}
}

// image_copy_regions reads the regions of vkCmdCopyBufferToImage and
// vkCmdCopyImageToBuffer: VkBufferImageCopy.
@(private = "file")
image_copy_regions :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command) {
	d := decoder
	c := command
	region_count := count(d, 1, MAX_ARRAY_ELEMENTS)
	expect_array_size(d, u64(region_count))
	for _ in 0 ..< region_count {
		value_u64(d, c)
		value_u32(d, c)
		value_u32(d, c)
		value_flags(d, c, IMAGE_ASPECT_KNOWN_BITS)
		value_u32(d, c)
		value_u32(d, c)
		value_u32(d, c)
		value_i32(d, c)
		value_i32(d, c)
		value_i32(d, c)
		value_u32(d, c)
		value_u32(d, c)
		value_u32(d, c)
	}
}

// required_string reads a C string that must be present.
@(private = "file")
required_string :: proc "contextless" (decoder: ^Decoder) {
	if peek_u64(decoder) == 0 && decoder.problem == .None {
		fail(decoder, .String_Unterminated)
		return
	}
	skip_string(decoder)
}

// blob reads the bytes of a blob array of size byte_count, padded to 32
// bits, and returns them.
@(private = "file")
blob :: proc "contextless" (decoder: ^Decoder, byte_count: u64) -> []u8 {
	expect_array_size(decoder, byte_count)
	if decoder.problem != .None {
		return nil
	}
	padded := (int(byte_count) + 3) & ~int(3)
	if offset, ok := decoder_take(decoder, padded); ok {
		return decoder.source[offset:][:int(byte_count)]
	}
	return nil
}

// attachment_reference reads a VkAttachmentReference whose attachment is
// below attachment_count or VK_ATTACHMENT_UNUSED.
@(private = "file")
attachment_reference :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command, attachment_count: u32) {
	attachment := value_u32(decoder, command)
	if decoder.problem == .None && attachment >= attachment_count && attachment != ATTACHMENT_UNUSED {
		fail(decoder, .Count_Out_Of_Range)
	}
	layout_value(decoder, command)
}

@(private = "file")
attachment_references :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command, attachment_count: u32) -> u32 {
	reference_count := count(decoder, 0, MAX_ARRAY_ELEMENTS)
	expect_array_size(decoder, u64(reference_count))
	for _ in 0 ..< reference_count {
		attachment_reference(decoder, command, attachment_count)
	}
	return reference_count
}

// The pipeline state structures of vkCreateGraphicsPipelines, each behind
// its pointer.

@(private = "file")
pipeline_shader_stages :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command) {
	d := decoder
	c := command
	stage_count := count(d, 1, MAX_ARRAY_ELEMENTS)
	expect_array_size(d, u64(stage_count))
	for _ in 0 ..< stage_count {
		expect_structure(d, .Pipeline_Shader_Stage_Create_Info)
		zero_word(d)
		stage := flags_required(d, c, SHADER_STAGE_KNOWN_BITS)
		// A stage create info names exactly one stage.
		if d.problem == .None && stage & (stage - 1) != 0 {
			fail(d, .Unknown_Flag_Bits)
		}
		required_object(d, c)
		required_string(d)
		expect_pointer(d, false) // pSpecializationInfo
	}
}

@(private = "file")
pipeline_vertex_input :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command) {
	d := decoder
	c := command
	expect_pointer(d, true)
	expect_structure(d, .Pipeline_Vertex_Input_State_Create_Info)
	zero_word(d)
	binding_count := count(d, 0, MAX_ARRAY_ELEMENTS)
	expect_array_size(d, u64(binding_count))
	for _ in 0 ..< binding_count {
		value_u32(d, c)
		value_u32(d, c)
		enum_value(d, c, Vertex_Input_Rate)
	}
	attribute_count := count(d, 0, MAX_ARRAY_ELEMENTS)
	expect_array_size(d, u64(attribute_count))
	for _ in 0 ..< attribute_count {
		value_u32(d, c)
		value_u32(d, c)
		word := value_i32(d, c)
		if d.problem == .None {
			format, format_ok := format_of_word(word)
			if !format_ok || vertex_format_bytes(format) == 0 {
				fail(d, .Unknown_Enum_Word)
			}
		}
		value_u32(d, c)
	}
}

@(private = "file")
pipeline_fixed_states :: proc "contextless" (decoder: ^Decoder, command: ^Decoded_Command) {
	d := decoder
	c := command
	expect_pointer(d, true) // pInputAssemblyState
	expect_structure(d, .Pipeline_Input_Assembly_State_Create_Info)
	zero_word(d)
	enum_value(d, c, Primitive_Topology)
	boolean(d, c)

	expect_pointer(d, false) // pTessellationState

	expect_pointer(d, true) // pViewportState
	expect_structure(d, .Pipeline_Viewport_State_Create_Info)
	zero_word(d)
	viewport_count := count(d, 1, MAX_ARRAY_ELEMENTS)
	if array_present(d, viewport_count) {
		for _ in 0 ..< viewport_count * 6 {
			value_u32(d, c)
		}
	}
	scissor_count := count(d, 1, MAX_ARRAY_ELEMENTS)
	if array_present(d, scissor_count) {
		for _ in 0 ..< scissor_count {
			value_i32(d, c)
			value_i32(d, c)
			value_u32(d, c)
			value_u32(d, c)
		}
	}

	expect_pointer(d, true) // pRasterizationState
	expect_structure(d, .Pipeline_Rasterization_State_Create_Info)
	zero_word(d)
	boolean(d, c) // depthClampEnable
	boolean(d, c) // rasterizerDiscardEnable
	enum_value(d, c, Polygon_Mode)
	value_flags(d, c, CULL_MODE_KNOWN_BITS)
	enum_value(d, c, Front_Face)
	boolean(d, c) // depthBiasEnable
	for _ in 0 ..< 4 {
		value_u32(d, c) // the three depth bias floats and the line width
	}

	expect_pointer(d, true) // pMultisampleState
	expect_structure(d, .Pipeline_Multisample_State_Create_Info)
	zero_word(d)
	sample_count_value(d, c)
	boolean(d, c) // sampleShadingEnable
	value_u32(d, c) // minSampleShading
	// One sample has a mask of one word.
	if array_present(d, 1) {
		value_u32(d, c)
	}
	boolean(d, c) // alphaToCoverageEnable
	boolean(d, c) // alphaToOneEnable

	expect_pointer(d, false) // pDepthStencilState

	expect_pointer(d, true) // pColorBlendState
	expect_structure(d, .Pipeline_Color_Blend_State_Create_Info)
	zero_word(d)
	// The system never enables a logic operation.
	if boolean(d, c) && d.problem == .None {
		fail(d, .Unknown_Enum_Word)
	}
	enum_value(d, c, Logic_Op)
	blend_count := count(d, 0, MAX_ARRAY_ELEMENTS)
	expect_array_size(d, u64(blend_count))
	for _ in 0 ..< blend_count {
		boolean(d, c)
		enum_value(d, c, Blend_Factor)
		enum_value(d, c, Blend_Factor)
		enum_value(d, c, Blend_Op)
		enum_value(d, c, Blend_Factor)
		enum_value(d, c, Blend_Factor)
		enum_value(d, c, Blend_Op)
		value_flags(d, c, COLOR_COMPONENT_KNOWN_BITS)
	}
	expect_array_size(d, 4) // blendConstants
	for _ in 0 ..< 4 {
		value_u32(d, c)
	}

	// pDynamicState
	if get_pointer(d) {
		expect_structure(d, .Pipeline_Dynamic_State_Create_Info)
		zero_word(d)
		dynamic_count := count(d, 0, MAX_ARRAY_ELEMENTS)
		expect_array_size(d, u64(dynamic_count))
		for _ in 0 ..< dynamic_count {
			enum_value(d, c, Dynamic_State)
		}
	}
}

@(private = "file")
no_names :: proc "contextless" (decoder: ^Decoder) {
	// enabledLayerCount and enabledExtensionCount: the system enables none.
	count(decoder, 0, 0)
	empty_array(decoder)
}

// command_decode_next decodes the command at the cursor of decoder.
command_decode_next :: proc "contextless" (decoder: ^Decoder) -> (command: Decoded_Command, problem: Venus_Problem) {
	if decoder.problem != .None {
		return {}, decoder.problem
	}
	start := decoder.cursor
	type_word := get_u32(decoder)
	flags_word := get_u32(decoder)
	if decoder.problem != .None {
		decoder.cursor = start
		return {}, decoder.problem
	}
	command_type, type_ok := command_type_of_word(type_word)
	if !type_ok {
		decoder.cursor = start
		return {}, .Unknown_Command_Type
	}
	flags, flags_ok := command_flags_of_word(flags_word)
	if !flags_ok {
		decoder.cursor = start
		return {}, .Unknown_Command_Flags
	}
	command.command_type = command_type
	command.flags = flags
	d := decoder
	c := &command

	switch command_type {
	case .Create_Instance:
		expect_pointer(d, true)
		expect_structure(d, .Instance_Create_Info)
		zero_word(d)
		if get_pointer(d) {
			expect_structure(d, .Application_Info)
			skip_string(d)
			value_u32(d, c)
			skip_string(d)
			value_u32(d, c)
			value_u32(d, c)
		}
		no_names(d)
		no_names(d)
		allocator_absent(d)
		output_object(d, c)

	case .Enumerate_Physical_Devices:
		required_object(d, c)
		expect_pointer(d, true)
		device_count := value_u32(d, c)
		if device_count > MAX_ARRAY_ELEMENTS {
			fail(d, .Count_Out_Of_Range)
		}
		if array_present(d, device_count) {
			for _ in 0 ..< device_count {
				required_object(d, c)
			}
		}

	case .Get_Physical_Device_Properties:
		required_object(d, c)
		expect_pointer(d, true)
		expect_array_size(d, PHYSICAL_DEVICE_NAME_BYTES)
		expect_array_size(d, UUID_BYTES)
		for field in LIMIT_FIELDS {
			if field.count > 1 {
				expect_array_size(d, u64(field.count))
			}
		}

	case .Create_Device:
		required_object(d, c)
		expect_pointer(d, true)
		expect_structure(d, .Device_Create_Info)
		zero_word(d)
		queue_info_count := count(d, 1, MAX_ARRAY_ELEMENTS)
		expect_array_size(d, u64(queue_info_count))
		for _ in 0 ..< queue_info_count {
			expect_structure(d, .Device_Queue_Create_Info)
			zero_word(d)
			value_u32(d, c)
			queue_count := count(d, 1, MAX_ARRAY_ELEMENTS)
			keep_value(d, c, u64(queue_count))
			expect_array_size(d, u64(queue_count))
			for _ in 0 ..< queue_count {
				value_u32(d, c)
			}
		}
		no_names(d)
		no_names(d)
		expect_pointer(d, false)
		allocator_absent(d)
		output_object(d, c)

	case .Get_Device_Queue_2:
		required_object(d, c)
		expect_pointer(d, true)
		expect_structure(d, .Device_Queue_Info_2)
		zero_word(d)
		value_u32(d, c)
		value_u32(d, c)
		output_object(d, c)

	case .Create_Buffer:
		required_object(d, c)
		expect_pointer(d, true)
		expect_structure(d, .Buffer_Create_Info)
		zero_word(d)
		if value_u64(d, c) == 0 && d.problem == .None {
			fail(d, .Zero_Extent)
		}
		value_flags(d, c, BUFFER_USAGE_KNOWN_BITS)
		sharing_mode := get_i32(d)
		if d.problem == .None && sharing_mode != 0 && sharing_mode != 1 {
			fail(d, .Unknown_Enum_Word)
		}
		family_count := count(d, 0, MAX_ARRAY_ELEMENTS)
		if array_present(d, family_count) {
			for _ in 0 ..< family_count {
				value_u32(d, c)
			}
		}
		allocator_absent(d)
		output_object(d, c)

	case .Allocate_Memory:
		required_object(d, c)
		expect_pointer(d, true)
		expect_structure(d, .Memory_Allocate_Info)
		if value_u64(d, c) == 0 && d.problem == .None {
			fail(d, .Zero_Extent)
		}
		value_u32(d, c)
		allocator_absent(d)
		output_object(d, c)

	case .Bind_Buffer_Memory, .Bind_Image_Memory:
		required_object(d, c)
		required_object(d, c)
		required_object(d, c)
		value_u64(d, c)

	case .Create_Command_Pool:
		required_object(d, c)
		expect_pointer(d, true)
		expect_structure(d, .Command_Pool_Create_Info)
		value_flags(d, c, COMMAND_POOL_KNOWN_BITS)
		value_u32(d, c)
		allocator_absent(d)
		output_object(d, c)

	case .Allocate_Command_Buffers:
		required_object(d, c)
		expect_pointer(d, true)
		expect_structure(d, .Command_Buffer_Allocate_Info)
		required_object(d, c)
		enum_value(d, c, Command_Buffer_Level)
		buffer_count := count(d, 1, MAX_ARRAY_ELEMENTS)
		expect_array_size(d, u64(buffer_count))
		for _ in 0 ..< buffer_count {
			required_object(d, c)
		}

	case .Begin_Command_Buffer:
		required_object(d, c)
		expect_pointer(d, true)
		expect_structure(d, .Command_Buffer_Begin_Info)
		value_flags(d, c, COMMAND_BUFFER_USAGE_KNOWN_BITS)
		expect_pointer(d, false)

	case .End_Command_Buffer, .Cmd_End_Render_Pass, .Queue_Wait_Idle:
		required_object(d, c)

	case .Cmd_Copy_Buffer:
		required_object(d, c)
		required_object(d, c)
		required_object(d, c)
		region_count := count(d, 1, MAX_ARRAY_ELEMENTS)
		expect_array_size(d, u64(region_count))
		for _ in 0 ..< region_count {
			value_u64(d, c)
			value_u64(d, c)
			if value_u64(d, c) == 0 && d.problem == .None {
				fail(d, .Zero_Extent)
			}
		}

	case .Cmd_Clear_Color_Image:
		required_object(d, c)
		required_object(d, c)
		enum_value(d, c, Image_Layout)
		expect_pointer(d, true)
		clear_color(d, c)
		range_count := count(d, 1, MAX_ARRAY_ELEMENTS)
		expect_array_size(d, u64(range_count))
		for _ in 0 ..< range_count {
			value_flags(d, c, IMAGE_ASPECT_KNOWN_BITS)
			for _ in 0 ..< 4 {
				value_u32(d, c)
			}
		}

	case .Cmd_Begin_Render_Pass:
		required_object(d, c)
		expect_pointer(d, true)
		expect_structure(d, .Render_Pass_Begin_Info)
		required_object(d, c)
		required_object(d, c)
		value_i32(d, c)
		value_i32(d, c)
		value_u32(d, c)
		value_u32(d, c)
		clear_count := count(d, 0, MAX_ARRAY_ELEMENTS)
		if array_present(d, clear_count) {
			for _ in 0 ..< clear_count {
				tag_word := value_u32(d, c)
				if d.problem != .None {
					break
				}
				tag, tag_ok := clear_value_tag_of_word(tag_word)
				if !tag_ok {
					fail(d, .Unknown_Union_Tag)
					break
				}
				switch tag {
				case .Color:
					clear_color(d, c)
				case .Depth_Stencil:
					value_u32(d, c)
					value_u32(d, c)
				}
			}
		}
		enum_value(d, c, Subpass_Contents)

	case .Cmd_Bind_Pipeline:
		required_object(d, c)
		enum_value(d, c, Pipeline_Bind_Point)
		required_object(d, c)

	case .Cmd_Set_Scissor:
		required_object(d, c)
		value_u32(d, c)
		scissor_count := count(d, 1, MAX_ARRAY_ELEMENTS)
		expect_array_size(d, u64(scissor_count))
		for _ in 0 ..< scissor_count {
			value_i32(d, c)
			value_i32(d, c)
			value_u32(d, c)
			value_u32(d, c)
		}

	case .Cmd_Bind_Vertex_Buffers:
		required_object(d, c)
		value_u32(d, c)
		binding_count := count(d, 1, MAX_ARRAY_ELEMENTS)
		expect_array_size(d, u64(binding_count))
		for _ in 0 ..< binding_count {
			required_object(d, c)
		}
		expect_array_size(d, u64(binding_count))
		for _ in 0 ..< binding_count {
			value_u64(d, c)
		}

	case .Cmd_Bind_Index_Buffer:
		required_object(d, c)
		required_object(d, c)
		value_u64(d, c)
		enum_value(d, c, Index_Type)

	case .Cmd_Bind_Descriptor_Sets:
		required_object(d, c)
		enum_value(d, c, Pipeline_Bind_Point)
		required_object(d, c)
		value_u32(d, c)
		set_count := count(d, 1, MAX_ARRAY_ELEMENTS)
		expect_array_size(d, u64(set_count))
		for _ in 0 ..< set_count {
			required_object(d, c)
		}
		offset_count := count(d, 0, MAX_ARRAY_ELEMENTS)
		if array_present(d, offset_count) {
			for _ in 0 ..< offset_count {
				value_u32(d, c)
			}
		}

	case .Cmd_Draw:
		required_object(d, c)
		for _ in 0 ..< 4 {
			value_u32(d, c)
		}

	case .Cmd_Draw_Indexed:
		required_object(d, c)
		value_u32(d, c)
		value_u32(d, c)
		value_u32(d, c)
		value_i32(d, c)
		value_u32(d, c)

	case .Cmd_Copy_Buffer_To_Image:
		required_object(d, c)
		required_object(d, c)
		required_object(d, c)
		enum_value(d, c, Image_Layout)
		image_copy_regions(d, c)

	case .Cmd_Copy_Image_To_Buffer:
		required_object(d, c)
		required_object(d, c)
		layout := layout_value(d, c)
		if d.problem == .None && layout != .Transfer_Source_Optimal && layout != .General {
			fail(d, .Layout_Transition_Invalid)
		}
		required_object(d, c)
		image_copy_regions(d, c)

	case .Create_Image:
		required_object(d, c)
		expect_pointer(d, true)
		expect_structure(d, .Image_Create_Info)
		zero_word(d)
		enum_value(d, c, Image_Type)
		color_format_value(d, c)
		width := value_u32(d, c)
		height := value_u32(d, c)
		depth := value_u32(d, c)
		if d.problem == .None {
			if check := extent_check(width, height); check != .None {
				fail(d, check)
			} else if depth != 1 {
				fail(d, depth == 0 ? .Zero_Extent : .Dimension_Too_Large)
			}
		}
		keep_value(d, c, u64(count(d, 1, MAX_ARRAY_ELEMENTS))) // mipLevels
		keep_value(d, c, u64(count(d, 1, MAX_ARRAY_ELEMENTS))) // arrayLayers
		sample_count_value(d, c)
		enum_value(d, c, Image_Tiling)
		flags_required(d, c, IMAGE_USAGE_KNOWN_BITS)
		enum_value(d, c, Sharing_Mode)
		family_count := count(d, 0, MAX_ARRAY_ELEMENTS)
		if array_present(d, family_count) {
			for _ in 0 ..< family_count {
				value_u32(d, c)
			}
		}
		// A new image has no contents: its layout is UNDEFINED until a barrier.
		if layout := layout_value(d, c); d.problem == .None && layout != .Undefined {
			fail(d, .Layout_Transition_Invalid)
		}
		allocator_absent(d)
		output_object(d, c)

	case .Create_Image_View:
		required_object(d, c)
		expect_pointer(d, true)
		expect_structure(d, .Image_View_Create_Info)
		zero_word(d)
		required_object(d, c)
		enum_value(d, c, Image_View_Type)
		color_format_value(d, c)
		for _ in 0 ..< 4 {
			enum_value(d, c, Component_Swizzle)
		}
		subresource_range(d, c)
		allocator_absent(d)
		output_object(d, c)

	case .Create_Shader_Module:
		required_object(d, c)
		expect_pointer(d, true)
		expect_structure(d, .Shader_Module_Create_Info)
		zero_word(d)
		code_size := value_u64(d, c)
		if d.problem == .None {
			switch {
			case code_size == 0:
				fail(d, .Zero_Extent)
			case code_size % 4 != 0:
				fail(d, .Misaligned_Length)
			case code_size > MAX_SHADER_CODE_WORDS * 4:
				fail(d, .Count_Out_Of_Range)
			}
		}
		// pCode: an array of codeSize / 4 words.
		expect_array_size(d, code_size / 4)
		if d.problem == .None {
			if offset, ok := decoder_take(d, int(code_size)); ok {
				if _, refusal := webgpu_subset.spirv_bytes_validate(d.source[offset:][:int(code_size)]); refusal != .None {
					fail(d, .Shader_Code_Invalid)
				}
			}
		}
		allocator_absent(d)
		output_object(d, c)

	case .Create_Pipeline_Layout:
		required_object(d, c)
		expect_pointer(d, true)
		expect_structure(d, .Pipeline_Layout_Create_Info)
		zero_word(d)
		set_count := count(d, 0, MAX_ARRAY_ELEMENTS)
		expect_array_size(d, u64(set_count))
		for _ in 0 ..< set_count {
			required_object(d, c)
		}
		range_count := count(d, 0, MAX_ARRAY_ELEMENTS)
		expect_array_size(d, u64(range_count))
		for _ in 0 ..< range_count {
			stages := value_u32(d, c)
			offset := value_u32(d, c)
			size := value_u32(d, c)
			if d.problem == .None {
				if check := push_constant_range_check(transmute(Shader_Stages)stages, offset, size); check != .None {
					fail(d, check)
				}
			}
		}
		allocator_absent(d)
		output_object(d, c)

	case .Create_Render_Pass:
		required_object(d, c)
		expect_pointer(d, true)
		expect_structure(d, .Render_Pass_Create_Info)
		zero_word(d)
		attachment_count := count(d, 1, MAX_ARRAY_ELEMENTS)
		expect_array_size(d, u64(attachment_count))
		for _ in 0 ..< attachment_count {
			zero_word(d)
			color_format_value(d, c)
			sample_count_value(d, c)
			enum_value(d, c, Attachment_Load_Op)
			enum_value(d, c, Attachment_Store_Op)
			enum_value(d, c, Attachment_Load_Op)
			enum_value(d, c, Attachment_Store_Op)
			layout_value(d, c)
			if layout_value(d, c) == .Undefined && d.problem == .None {
				fail(d, .Layout_Transition_Invalid)
			}
		}
		subpass_count := count(d, 1, MAX_ARRAY_ELEMENTS)
		expect_array_size(d, u64(subpass_count))
		for _ in 0 ..< subpass_count {
			zero_word(d)
			// A subpass of a render pass is a graphics subpass.
			if value_i32(d, c) != i32(Pipeline_Bind_Point.Graphics) && d.problem == .None {
				fail(d, .Unknown_Enum_Word)
			}
			attachment_references(d, c, attachment_count)
			color_count := attachment_references(d, c, attachment_count)
			if array_present(d, color_count) {
				for _ in 0 ..< color_count {
					attachment_reference(d, c, attachment_count)
				}
			}
			if get_pointer(d) {
				attachment_reference(d, c, attachment_count)
			}
			preserve_count := count(d, 0, MAX_ARRAY_ELEMENTS)
			expect_array_size(d, u64(preserve_count))
			for _ in 0 ..< preserve_count {
				if value_u32(d, c) >= attachment_count && d.problem == .None {
					fail(d, .Count_Out_Of_Range)
				}
			}
		}
		dependency_count := count(d, 0, MAX_ARRAY_ELEMENTS)
		expect_array_size(d, u64(dependency_count))
		for _ in 0 ..< dependency_count {
			value_u32(d, c)
			value_u32(d, c)
			flags_required(d, c, PIPELINE_STAGE_KNOWN_BITS)
			flags_required(d, c, PIPELINE_STAGE_KNOWN_BITS)
			value_flags(d, c, ACCESS_KNOWN_BITS)
			value_flags(d, c, ACCESS_KNOWN_BITS)
			value_flags(d, c, DEPENDENCY_KNOWN_BITS)
		}
		allocator_absent(d)
		output_object(d, c)

	case .Create_Framebuffer:
		required_object(d, c)
		expect_pointer(d, true)
		expect_structure(d, .Framebuffer_Create_Info)
		zero_word(d)
		required_object(d, c)
		attachment_count := count(d, 1, MAX_ARRAY_ELEMENTS)
		expect_array_size(d, u64(attachment_count))
		for _ in 0 ..< attachment_count {
			required_object(d, c)
		}
		width := value_u32(d, c)
		height := value_u32(d, c)
		if d.problem == .None {
			if check := extent_check(width, height); check != .None {
				fail(d, check)
			}
		}
		keep_value(d, c, u64(count(d, 1, MAX_ARRAY_ELEMENTS))) // layers
		allocator_absent(d)
		output_object(d, c)

	case .Create_Graphics_Pipelines:
		required_object(d, c)
		optional_object(d, c) // pipelineCache
		info_count := count(d, 1, MAX_ARRAY_ELEMENTS)
		expect_array_size(d, u64(info_count))
		for _ in 0 ..< info_count {
			expect_structure(d, .Graphics_Pipeline_Create_Info)
			zero_word(d)
			pipeline_shader_stages(d, c)
			pipeline_vertex_input(d, c)
			pipeline_fixed_states(d, c)
			required_object(d, c) // layout
			required_object(d, c) // renderPass
			value_u32(d, c) // subpass
			optional_object(d, c) // basePipelineHandle
			value_i32(d, c) // basePipelineIndex
		}
		allocator_absent(d)
		expect_array_size(d, u64(info_count))
		for _ in 0 ..< info_count {
			required_object(d, c)
		}

	case .Cmd_Pipeline_Barrier:
		required_object(d, c)
		flags_required(d, c, PIPELINE_STAGE_KNOWN_BITS)
		flags_required(d, c, PIPELINE_STAGE_KNOWN_BITS)
		zero_word(d) // dependencyFlags
		memory_count := count(d, 0, MAX_ARRAY_ELEMENTS)
		expect_array_size(d, u64(memory_count))
		for _ in 0 ..< memory_count {
			expect_structure(d, .Memory_Barrier)
			value_flags(d, c, ACCESS_KNOWN_BITS)
			value_flags(d, c, ACCESS_KNOWN_BITS)
		}
		// The system sends no buffer memory barrier.
		count(d, 0, 0)
		empty_array(d)
		barrier_count := count(d, 0, MAX_ARRAY_ELEMENTS)
		expect_array_size(d, u64(barrier_count))
		if d.problem == .None && memory_count + barrier_count == 0 {
			fail(d, .Count_Out_Of_Range)
		}
		for _ in 0 ..< barrier_count {
			expect_structure(d, .Image_Memory_Barrier)
			value_flags(d, c, ACCESS_KNOWN_BITS)
			value_flags(d, c, ACCESS_KNOWN_BITS)
			layout_value(d, c)
			if layout_value(d, c) == .Undefined && d.problem == .None {
				fail(d, .Layout_Transition_Invalid)
			}
			value_u32(d, c)
			value_u32(d, c)
			required_object(d, c)
			subresource_range(d, c)
		}

	case .Cmd_Update_Buffer:
		required_object(d, c)
		required_object(d, c)
		offset := value_u64(d, c)
		size := value_u64(d, c)
		if d.problem == .None {
			switch {
			case size == 0:
				fail(d, .Zero_Extent)
			case size > MAX_UPDATE_BUFFER_BYTES:
				fail(d, .Count_Out_Of_Range)
			case size % 4 != 0 || offset % 4 != 0:
				fail(d, .Misaligned_Length)
			}
		}
		blob(d, size)

	case .Cmd_Push_Constants:
		required_object(d, c)
		required_object(d, c)
		stages := value_u32(d, c)
		offset := value_u32(d, c)
		size := value_u32(d, c)
		if d.problem == .None {
			if check := push_constant_range_check(transmute(Shader_Stages)stages, offset, size); check != .None {
				fail(d, check)
			}
		}
		blob(d, u64(size))

	case .Cmd_Set_Viewport:
		required_object(d, c)
		value_u32(d, c)
		viewport_count := count(d, 1, MAX_ARRAY_ELEMENTS)
		expect_array_size(d, u64(viewport_count))
		for _ in 0 ..< viewport_count {
			viewport: Viewport
			viewport.x = transmute(f32)value_u32(d, c)
			viewport.y = transmute(f32)value_u32(d, c)
			viewport.width = transmute(f32)value_u32(d, c)
			viewport.height = transmute(f32)value_u32(d, c)
			viewport.min_depth = transmute(f32)value_u32(d, c)
			viewport.max_depth = transmute(f32)value_u32(d, c)
			if d.problem == .None {
				if check := viewport_check(viewport); check != .None {
					fail(d, check)
				}
			}
		}

	case .Queue_Submit:
		required_object(d, c)
		submit_count := count(d, 0, MAX_ARRAY_ELEMENTS)
		if array_present(d, submit_count) {
			for _ in 0 ..< submit_count {
				expect_structure(d, .Submit_Info)
				wait_count := count(d, 0, MAX_ARRAY_ELEMENTS)
				if array_present(d, wait_count) {
					for _ in 0 ..< wait_count {
						required_object(d, c)
					}
				}
				if array_present(d, wait_count) {
					for _ in 0 ..< wait_count {
						value_u32(d, c)
					}
				}
				buffer_count := count(d, 0, MAX_ARRAY_ELEMENTS)
				if array_present(d, buffer_count) {
					for _ in 0 ..< buffer_count {
						required_object(d, c)
					}
				}
				signal_count := count(d, 0, MAX_ARRAY_ELEMENTS)
				if array_present(d, signal_count) {
					for _ in 0 ..< signal_count {
						required_object(d, c)
					}
				}
			}
		}
		optional_object(d, c)

	case .Set_Reply_Command_Stream:
		expect_pointer(d, true)
		if value_u32(d, c) == 0 && d.problem == .None {
			fail(d, .Zero_Object_Id)
		}
		value_u64(d, c)
		value_u64(d, c)

	case .Seek_Reply_Command_Stream:
		value_u64(d, c)

	case .Create_Ring:
		ring := value_u64(d, c)
		if ring == 0 && d.problem == .None {
			fail(d, .Zero_Object_Id)
		}
		expect_pointer(d, true)
		expect_structure(d, .Ring_Create_Info)
		zero_word(d)
		info := Ring_Create_Info{resource_id = value_u32(d, c)}
		info.offset = value_u64(d, c)
		info.size = value_u64(d, c)
		info.idle_timeout = value_u64(d, c)
		info.head_offset = value_u64(d, c)
		info.tail_offset = value_u64(d, c)
		info.status_offset = value_u64(d, c)
		info.buffer_offset = value_u64(d, c)
		info.buffer_size = value_u64(d, c)
		info.extra_offset = value_u64(d, c)
		info.extra_size = value_u64(d, c)
		if d.problem == .None {
			if info.resource_id == 0 {
				fail(d, .Zero_Object_Id)
			} else if check := ring_create_info_check(info); check != .None {
				fail(d, check)
			}
		}

	case .Destroy_Ring:
		if value_u64(d, c) == 0 && d.problem == .None {
			fail(d, .Zero_Object_Id)
		}

	case .Notify_Ring:
		if value_u64(d, c) == 0 && d.problem == .None {
			fail(d, .Zero_Object_Id)
		}
		value_u32(d, c)
		zero_word(d)
	}

	if decoder.problem != .None {
		problem = decoder.problem
		decoder.problem = .None
		decoder.cursor = start
		return {}, problem
	}
	return command, .None
}

// stream_validate decodes every command of a stream and refuses a stream
// with a fault, a partial command, or bytes after the last command.
stream_validate :: proc "contextless" (source: []u8) -> (command_count: int, problem: Venus_Problem) {
	if len(source) == 0 {
		return 0, .Stream_Empty
	}
	if len(source) % 4 != 0 {
		return 0, .Misaligned_Length
	}
	decoder := decoder_init(source)
	for decoder.cursor < len(source) {
		if _, command_problem := command_decode_next(&decoder); command_problem != .None {
			return command_count, command_problem
		}
		command_count += 1
	}
	return command_count, .None
}

// command_type_client_allowed says if a client stream may hold a command of
// this type. The commands of the ring and of the reply stream name the
// shared memory of the context: a client that sends them can point the
// renderer at the ring or the replies of the service, so only the service
// sends them.
command_type_client_allowed :: proc "contextless" (command_type: Command_Type) -> bool {
	switch command_type {
	case .Create_Instance, .Enumerate_Physical_Devices, .Get_Physical_Device_Properties, .Create_Device,
	     .Queue_Submit, .Queue_Wait_Idle, .Allocate_Memory, .Bind_Buffer_Memory, .Bind_Image_Memory,
	     .Create_Buffer, .Create_Image, .Create_Image_View, .Create_Shader_Module, .Create_Graphics_Pipelines,
	     .Create_Pipeline_Layout, .Create_Framebuffer, .Create_Render_Pass, .Create_Command_Pool,
	     .Allocate_Command_Buffers, .Begin_Command_Buffer, .End_Command_Buffer, .Cmd_Bind_Pipeline,
	     .Cmd_Set_Viewport, .Cmd_Set_Scissor, .Cmd_Bind_Descriptor_Sets, .Cmd_Bind_Index_Buffer,
	     .Cmd_Bind_Vertex_Buffers, .Cmd_Draw, .Cmd_Draw_Indexed, .Cmd_Copy_Buffer, .Cmd_Copy_Buffer_To_Image,
	     .Cmd_Copy_Image_To_Buffer, .Cmd_Update_Buffer, .Cmd_Clear_Color_Image, .Cmd_Pipeline_Barrier,
	     .Cmd_Push_Constants, .Cmd_Begin_Render_Pass, .Cmd_End_Render_Pass, .Get_Device_Queue_2:
		return true
	case .Set_Reply_Command_Stream, .Seek_Reply_Command_Stream, .Create_Ring, .Destroy_Ring, .Notify_Ring:
		return false
	}
	return false
}

// stream_validate_client is stream_validate for a stream of a client, at
// the border of the GPU device service: it refuses too each command that
// only the service sends, and each command with the flag Generate_Reply,
// whose reply would land in the reply stream of the service.
stream_validate_client :: proc "contextless" (source: []u8) -> (command_count: int, problem: Venus_Problem) {
	if len(source) == 0 {
		return 0, .Stream_Empty
	}
	if len(source) % 4 != 0 {
		return 0, .Misaligned_Length
	}
	decoder := decoder_init(source)
	for decoder.cursor < len(source) {
		command, command_problem := command_decode_next(&decoder)
		if command_problem != .None {
			return command_count, command_problem
		}
		if !command_type_client_allowed(command.command_type) {
			return command_count, .Client_Command_Refused
		}
		if .Generate_Reply in command.flags {
			return command_count, .Client_Reply_Refused
		}
		command_count += 1
	}
	return command_count, .None
}
