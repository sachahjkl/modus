package venus_vulkan

// The replies. The driver side decodes a reply with the decode_*_reply
// procedures: each checks the command type, refuses an unknown VkResult, and
// checks that the renderer echoes the object ids that the command bound. The
// renderer side writes a reply with the encode_*_reply procedures; the tests
// use them to stand for the host.

// The kind of one field of VkPhysicalDeviceLimits on the wire.
Limit_Kind :: enum u8 {
	Unsigned_32, // uint32_t, VkBool32, VkSampleCountFlags
	Signed_32,
	Float_32,
	Unsigned_64, // VkDeviceSize, size_t
}

// One field of VkPhysicalDeviceLimits: a scalar (count 1) or a fixed array.
Limit_Field :: struct {
	kind:  Limit_Kind,
	count: u8,
}

LIMIT_FIELD_COUNT :: 106
// The fields as values, each element of a fixed array counted: the length
// of Physical_Device_Properties.limits.
LIMIT_VALUE_COUNT :: 114

// The index in Physical_Device_Properties.limits of the limits that the
// system reads.
LIMIT_VALUE_MAX_IMAGE_DIMENSION_2D :: 1
LIMIT_VALUE_MAX_MEMORY_ALLOCATION_COUNT :: 9
LIMIT_VALUE_MAX_COLOR_ATTACHMENTS :: 90
LIMIT_VALUE_NON_COHERENT_ATOM_SIZE :: 113

// The fields of VkPhysicalDeviceLimits in the order of vulkan_core.h.
@(rodata)
LIMIT_FIELDS := [LIMIT_FIELD_COUNT]Limit_Field {
	// maxImageDimension1D .. maxSamplerAllocationCount
	{.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1},
	{.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1},
	// bufferImageGranularity, sparseAddressSpaceSize
	{.Unsigned_64, 1}, {.Unsigned_64, 1},
	// maxBoundDescriptorSets .. maxVertexOutputComponents (21 fields)
	{.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1},
	{.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1},
	{.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1},
	// maxTessellationGenerationLevel .. maxComputeSharedMemorySize (18 fields)
	{.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1},
	{.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1},
	{.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1},
	// maxComputeWorkGroupCount[3], maxComputeWorkGroupInvocations, maxComputeWorkGroupSize[3]
	{.Unsigned_32, 3}, {.Unsigned_32, 1}, {.Unsigned_32, 3},
	// subPixelPrecisionBits, subTexelPrecisionBits, mipmapPrecisionBits, maxDrawIndexedIndexValue, maxDrawIndirectCount
	{.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1},
	// maxSamplerLodBias, maxSamplerAnisotropy, maxViewports, maxViewportDimensions[2], viewportBoundsRange[2], viewportSubPixelBits
	{.Float_32, 1}, {.Float_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 2}, {.Float_32, 2}, {.Unsigned_32, 1},
	// minMemoryMapAlignment, minTexelBufferOffsetAlignment, minUniformBufferOffsetAlignment, minStorageBufferOffsetAlignment
	{.Unsigned_64, 1}, {.Unsigned_64, 1}, {.Unsigned_64, 1}, {.Unsigned_64, 1},
	// minTexelOffset, maxTexelOffset, minTexelGatherOffset, maxTexelGatherOffset
	{.Signed_32, 1}, {.Unsigned_32, 1}, {.Signed_32, 1}, {.Unsigned_32, 1},
	// minInterpolationOffset, maxInterpolationOffset, subPixelInterpolationOffsetBits
	{.Float_32, 1}, {.Float_32, 1}, {.Unsigned_32, 1},
	// maxFramebufferWidth .. maxSampleMaskWords (14 fields)
	{.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1},
	{.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1},
	// timestampComputeAndGraphics, timestampPeriod
	{.Unsigned_32, 1}, {.Float_32, 1},
	// maxClipDistances, maxCullDistances, maxCombinedClipAndCullDistances, discreteQueuePriorities
	{.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1}, {.Unsigned_32, 1},
	// pointSizeRange[2], lineWidthRange[2], pointSizeGranularity, lineWidthGranularity
	{.Float_32, 2}, {.Float_32, 2}, {.Float_32, 1}, {.Float_32, 1},
	// strictLines, standardSampleLocations
	{.Unsigned_32, 1}, {.Unsigned_32, 1},
	// optimalBufferCopyOffsetAlignment, optimalBufferCopyRowPitchAlignment, nonCoherentAtomSize
	{.Unsigned_64, 1}, {.Unsigned_64, 1}, {.Unsigned_64, 1},
}

SPARSE_PROPERTY_COUNT :: 5

// VkPhysicalDeviceProperties. Each limit is a value of
// LIMIT_FIELDS in order, widened to 64 bits; a float limit is its bits.
Physical_Device_Properties :: struct {
	api_version:         u32,
	driver_version:      u32,
	vendor_id:           u32,
	device_id:           u32,
	device_type:         Physical_Device_Type,
	device_name:         [PHYSICAL_DEVICE_NAME_BYTES]u8,
	pipeline_cache_uuid: [UUID_BYTES]u8,
	limits:              [LIMIT_VALUE_COUNT]u64,
	sparse_properties:   [SPARSE_PROPERTY_COUNT]u32,
}

// device_name_text returns the name up to its null byte.
device_name_text :: proc "contextless" (properties: ^Physical_Device_Properties) -> string {
	for index in 0 ..< PHYSICAL_DEVICE_NAME_BYTES {
		if properties.device_name[index] == 0 {
			return string(properties.device_name[:index])
		}
	}
	return string(properties.device_name[:])
}

// Driver side: reply decoders.

@(private = "file")
reply_end :: proc "contextless" (decoder: ^Decoder, start: int) -> Venus_Problem {
	if decoder.problem != .None {
		problem := decoder.problem
		decoder.problem = .None
		decoder.cursor = start
		return problem
	}
	return .None
}

@(private = "file")
echoed_object :: proc "contextless" (decoder: ^Decoder, expected: Object_Id) {
	if !get_pointer(decoder) {
		fail(decoder, .Pointer_Invalid)
		return
	}
	if got := get_object(decoder); decoder.problem == .None && got != expected {
		fail(decoder, .Object_Id_Mismatch)
	}
}

// decode_result_reply reads the reply of a command whose only output is its
// VkResult: vkBindBufferMemory, vkBeginCommandBuffer, vkEndCommandBuffer,
// vkQueueSubmit, vkQueueWaitIdle.
decode_result_reply :: proc "contextless" (decoder: ^Decoder, command_type: Command_Type) -> (result: Vulkan_Result, problem: Venus_Problem) {
	start := decoder.cursor
	switch command_type {
	case .Bind_Buffer_Memory, .Begin_Command_Buffer, .End_Command_Buffer, .Queue_Submit, .Queue_Wait_Idle:
	case .Create_Instance, .Enumerate_Physical_Devices, .Get_Physical_Device_Properties, .Create_Device, .Allocate_Memory,
	     .Create_Buffer, .Create_Command_Pool, .Allocate_Command_Buffers, .Cmd_Bind_Pipeline, .Cmd_Set_Scissor,
	     .Cmd_Bind_Descriptor_Sets, .Cmd_Bind_Index_Buffer, .Cmd_Bind_Vertex_Buffers, .Cmd_Draw, .Cmd_Draw_Indexed,
	     .Cmd_Copy_Buffer, .Cmd_Copy_Buffer_To_Image, .Cmd_Clear_Color_Image, .Cmd_Begin_Render_Pass, .Cmd_End_Render_Pass,
	     .Get_Device_Queue_2, .Set_Reply_Command_Stream, .Seek_Reply_Command_Stream, .Create_Ring, .Destroy_Ring, .Notify_Ring:
		return .Error_Unknown, .Unexpected_Command_Type
	}
	expect_command_type(decoder, command_type)
	result = get_result(decoder)
	return result, reply_end(decoder, start)
}

// decode_create_object_reply reads the reply of a command that creates one
// object: vkCreateInstance, vkCreateDevice, vkAllocateMemory, vkCreateBuffer,
// vkCreateCommandPool. The renderer echoes the id when the result is a success.
decode_create_object_reply :: proc "contextless" (decoder: ^Decoder, command_type: Command_Type, object: Object_Id) -> (result: Vulkan_Result, problem: Venus_Problem) {
	start := decoder.cursor
	switch command_type {
	case .Create_Instance, .Create_Device, .Allocate_Memory, .Create_Buffer, .Create_Command_Pool:
	case .Enumerate_Physical_Devices, .Get_Physical_Device_Properties, .Bind_Buffer_Memory, .Begin_Command_Buffer,
	     .End_Command_Buffer, .Queue_Submit, .Queue_Wait_Idle, .Allocate_Command_Buffers, .Cmd_Bind_Pipeline,
	     .Cmd_Set_Scissor, .Cmd_Bind_Descriptor_Sets, .Cmd_Bind_Index_Buffer, .Cmd_Bind_Vertex_Buffers, .Cmd_Draw,
	     .Cmd_Draw_Indexed, .Cmd_Copy_Buffer, .Cmd_Copy_Buffer_To_Image, .Cmd_Clear_Color_Image, .Cmd_Begin_Render_Pass,
	     .Cmd_End_Render_Pass, .Get_Device_Queue_2, .Set_Reply_Command_Stream, .Seek_Reply_Command_Stream, .Create_Ring,
	     .Destroy_Ring, .Notify_Ring:
		return .Error_Unknown, .Unexpected_Command_Type
	}
	if object == 0 {
		return .Error_Unknown, .Zero_Object_Id
	}
	expect_command_type(decoder, command_type)
	result = get_result(decoder)
	echoed_object(decoder, object)
	return result, reply_end(decoder, start)
}

// decode_enumerate_physical_devices_reply reads the count of physical devices,
// and checks the echoed ids when the command bound ids. The count of a
// renderer can be less than the count of ids, with VK_INCOMPLETE.
decode_enumerate_physical_devices_reply :: proc "contextless" (decoder: ^Decoder, physical_devices: []Object_Id) -> (result: Vulkan_Result, device_count: u32, problem: Venus_Problem) {
	start := decoder.cursor
	expect_command_type(decoder, .Enumerate_Physical_Devices)
	result = get_result(decoder)
	if get_pointer(decoder) {
		device_count = get_u32(decoder)
	} else {
		fail(decoder, .Pointer_Invalid)
	}
	if decoder.problem == .None && device_count > MAX_ARRAY_ELEMENTS {
		fail(decoder, .Count_Out_Of_Range)
	}
	size := get_u64(decoder)
	if decoder.problem == .None {
		switch {
		case len(physical_devices) == 0:
			if size != 0 {
				fail(decoder, .Array_Size_Mismatch)
			}
		case size != u64(device_count) || device_count > u32(len(physical_devices)):
			fail(decoder, .Array_Size_Mismatch)
		case:
			for index in 0 ..< device_count {
				if get_object(decoder) != physical_devices[index] && decoder.problem == .None {
					fail(decoder, .Object_Id_Mismatch)
				}
			}
		}
	}
	if problem = reply_end(decoder, start); problem != .None {
		return .Error_Unknown, 0, problem
	}
	return result, device_count, .None
}

// decode_get_physical_device_properties_reply reads VkPhysicalDeviceProperties.
decode_get_physical_device_properties_reply :: proc "contextless" (decoder: ^Decoder, properties: ^Physical_Device_Properties) -> Venus_Problem {
	start := decoder.cursor
	expect_command_type(decoder, .Get_Physical_Device_Properties)
	expect_pointer(decoder, true)
	properties.api_version = get_u32(decoder)
	properties.driver_version = get_u32(decoder)
	properties.vendor_id = get_u32(decoder)
	properties.device_id = get_u32(decoder)
	type_word := get_i32(decoder)
	if decoder.problem == .None {
		device_type, type_ok := physical_device_type_of_word(type_word)
		if !type_ok {
			fail(decoder, .Unknown_Enum_Word)
		}
		properties.device_type = device_type
	}
	expect_array_size(decoder, PHYSICAL_DEVICE_NAME_BYTES)
	if offset, ok := decoder_take(decoder, PHYSICAL_DEVICE_NAME_BYTES); ok {
		copy(properties.device_name[:], decoder.source[offset:offset + PHYSICAL_DEVICE_NAME_BYTES])
		if properties.device_name[PHYSICAL_DEVICE_NAME_BYTES - 1] != 0 {
			fail(decoder, .String_Unterminated)
		}
	}
	expect_array_size(decoder, UUID_BYTES)
	if offset, ok := decoder_take(decoder, UUID_BYTES); ok {
		copy(properties.pipeline_cache_uuid[:], decoder.source[offset:offset + UUID_BYTES])
	}
	value_index := 0
	for field in LIMIT_FIELDS {
		if field.count > 1 {
			expect_array_size(decoder, u64(field.count))
		}
		for _ in 0 ..< field.count {
			switch field.kind {
			case .Unsigned_32, .Float_32:
				properties.limits[value_index] = u64(get_u32(decoder))
			case .Signed_32:
				properties.limits[value_index] = u64(i64(get_i32(decoder)))
			case .Unsigned_64:
				properties.limits[value_index] = get_u64(decoder)
			}
			value_index += 1
		}
	}
	for index in 0 ..< SPARSE_PROPERTY_COUNT {
		properties.sparse_properties[index] = get_u32(decoder)
	}
	return reply_end(decoder, start)
}

// decode_allocate_command_buffers_reply reads the result and checks the
// echoed ids of the command buffers.
decode_allocate_command_buffers_reply :: proc "contextless" (decoder: ^Decoder, command_buffers: []Object_Id) -> (result: Vulkan_Result, problem: Venus_Problem) {
	start := decoder.cursor
	if len(command_buffers) == 0 || len(command_buffers) > MAX_ARRAY_ELEMENTS {
		return .Error_Unknown, .Count_Out_Of_Range
	}
	expect_command_type(decoder, .Allocate_Command_Buffers)
	result = get_result(decoder)
	expect_array_size(decoder, u64(len(command_buffers)))
	for id in command_buffers {
		if get_object(decoder) != id && decoder.problem == .None {
			fail(decoder, .Object_Id_Mismatch)
		}
	}
	return result, reply_end(decoder, start)
}

// decode_get_device_queue_2_reply checks the echoed id of the queue.
decode_get_device_queue_2_reply :: proc "contextless" (decoder: ^Decoder, queue: Object_Id) -> Venus_Problem {
	start := decoder.cursor
	if queue == 0 {
		return .Zero_Object_Id
	}
	expect_command_type(decoder, .Get_Device_Queue_2)
	echoed_object(decoder, queue)
	return reply_end(decoder, start)
}

// Renderer side: reply encoders.

encode_result_reply :: proc "contextless" (encoder: ^Encoder, command_type: Command_Type, result: Vulkan_Result) -> Venus_Problem {
	if encoder.problem != .None {
		return encoder.problem
	}
	mark := encoder.used_bytes
	put_u32(encoder, u32(command_type))
	put_i32(encoder, i32(result))
	return command_end(encoder, mark)
}

encode_create_object_reply :: proc "contextless" (encoder: ^Encoder, command_type: Command_Type, result: Vulkan_Result, object: Object_Id) -> Venus_Problem {
	if encoder.problem != .None {
		return encoder.problem
	}
	mark := encoder.used_bytes
	put_u32(encoder, u32(command_type))
	put_i32(encoder, i32(result))
	put_pointer(encoder, true)
	put_object(encoder, object)
	return command_end(encoder, mark)
}

encode_enumerate_physical_devices_reply :: proc "contextless" (encoder: ^Encoder, result: Vulkan_Result, device_count: u32, physical_devices: []Object_Id) -> Venus_Problem {
	if encoder.problem != .None {
		return encoder.problem
	}
	mark := encoder.used_bytes
	put_u32(encoder, u32(Command_Type.Enumerate_Physical_Devices))
	put_i32(encoder, i32(result))
	put_pointer(encoder, true)
	put_u32(encoder, device_count)
	put_array_size(encoder, u64(len(physical_devices)))
	for id in physical_devices {
		put_object(encoder, id)
	}
	return command_end(encoder, mark)
}

encode_get_physical_device_properties_reply :: proc "contextless" (encoder: ^Encoder, properties: ^Physical_Device_Properties) -> Venus_Problem {
	if encoder.problem != .None {
		return encoder.problem
	}
	mark := encoder.used_bytes
	put_u32(encoder, u32(Command_Type.Get_Physical_Device_Properties))
	put_pointer(encoder, true)
	put_u32(encoder, properties.api_version)
	put_u32(encoder, properties.driver_version)
	put_u32(encoder, properties.vendor_id)
	put_u32(encoder, properties.device_id)
	put_i32(encoder, i32(properties.device_type))
	put_array_size(encoder, PHYSICAL_DEVICE_NAME_BYTES)
	if offset, write := encoder_room(encoder, PHYSICAL_DEVICE_NAME_BYTES); write {
		copy(encoder.storage[offset:offset + PHYSICAL_DEVICE_NAME_BYTES], properties.device_name[:])
	}
	put_array_size(encoder, UUID_BYTES)
	if offset, write := encoder_room(encoder, UUID_BYTES); write {
		copy(encoder.storage[offset:offset + UUID_BYTES], properties.pipeline_cache_uuid[:])
	}
	value_index := 0
	for field in LIMIT_FIELDS {
		if field.count > 1 {
			put_array_size(encoder, u64(field.count))
		}
		for _ in 0 ..< field.count {
			switch field.kind {
			case .Unsigned_32, .Float_32, .Signed_32:
				put_u32(encoder, u32(properties.limits[value_index]))
			case .Unsigned_64:
				put_u64(encoder, properties.limits[value_index])
			}
			value_index += 1
		}
	}
	for word in properties.sparse_properties {
		put_u32(encoder, word)
	}
	return command_end(encoder, mark)
}

encode_allocate_command_buffers_reply :: proc "contextless" (encoder: ^Encoder, result: Vulkan_Result, command_buffers: []Object_Id) -> Venus_Problem {
	if encoder.problem != .None {
		return encoder.problem
	}
	mark := encoder.used_bytes
	put_u32(encoder, u32(Command_Type.Allocate_Command_Buffers))
	put_i32(encoder, i32(result))
	put_array_size(encoder, u64(len(command_buffers)))
	for id in command_buffers {
		put_object(encoder, id)
	}
	return command_end(encoder, mark)
}

encode_get_device_queue_2_reply :: proc "contextless" (encoder: ^Encoder, queue: Object_Id) -> Venus_Problem {
	if encoder.problem != .None {
		return encoder.problem
	}
	mark := encoder.used_bytes
	put_u32(encoder, u32(Command_Type.Get_Device_Queue_2))
	put_pointer(encoder, true)
	put_object(encoder, queue)
	return command_end(encoder, mark)
}
