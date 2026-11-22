package venus_vulkan

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

	case .Bind_Buffer_Memory:
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
