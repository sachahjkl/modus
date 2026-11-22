package venus_vulkan

// The command encoders of the driver side. Each one validates its inputs,
// then writes the command in the order of the Vulkan parameters, as the
// generated vn_encode_vk* functions of Mesa do. The default flags ask a reply
// for a command that returns a VkResult or an object, and no reply for a
// command that only records work.

Application_Info :: struct {
	application_name:    string,
	application_version: u32,
	engine_name:         string,
	engine_version:      u32,
	api_version:         u32,
}

Rect_2D :: struct {
	x:      i32,
	y:      i32,
	width:  u32,
	height: u32,
}

Buffer_Copy :: struct {
	source_offset:      u64,
	destination_offset: u64,
	size:               u64,
}

Image_Subresource_Range :: struct {
	aspects:          Image_Aspects,
	base_mip_level:   u32,
	level_count:      u32,
	base_array_layer: u32,
	layer_count:      u32,
}

Buffer_Image_Copy :: struct {
	buffer_offset:       u64,
	buffer_row_length:   u32,
	buffer_image_height: u32,
	aspects:             Image_Aspects,
	mip_level:           u32,
	base_array_layer:    u32,
	layer_count:         u32,
	image_x:             i32,
	image_y:             i32,
	image_z:             i32,
	width:               u32,
	height:              u32,
	depth:               u32,
}

// One clear value of a render pass: a color as four 32-bit words (the bits of
// the floats), or a depth and a stencil value.
Clear_Value :: union {
	[4]u32,
	Clear_Depth_Stencil,
}

Clear_Depth_Stencil :: struct {
	depth:   f32,
	stencil: u32,
}

// VkRingCreateInfoMESA: where the ring lives in a blob resource.
Ring_Create_Info :: struct {
	resource_id:   u32,
	offset:        u64,
	size:          u64,
	idle_timeout:  u64,
	head_offset:   u64,
	tail_offset:   u64,
	status_offset: u64,
	buffer_offset: u64,
	buffer_size:   u64,
	extra_offset:  u64,
	extra_size:    u64,
}

@(private = "file")
REPLY :: Command_Flags{.Generate_Reply}

@(private = "file")
string_check :: proc "contextless" (text: string) -> Venus_Problem {
	if len(text) + 1 > MAX_STRING_BYTES {
		return .String_Too_Long
	}
	for index in 0 ..< len(text) {
		if text[index] == 0 {
			return .String_Unterminated
		}
	}
	return .None
}

@(private = "file")
objects_check :: proc "contextless" (ids: []Object_Id) -> Venus_Problem {
	if len(ids) == 0 || len(ids) > MAX_ARRAY_ELEMENTS {
		return .Count_Out_Of_Range
	}
	for id in ids {
		if id == 0 {
			return .Zero_Object_Id
		}
	}
	return .None
}

// encode_create_instance writes vkCreateInstance with no layer and no
// extension: the renderer refuses both.
encode_create_instance :: proc "contextless" (encoder: ^Encoder, instance: Object_Id, application: Application_Info, flags := REPLY) -> Venus_Problem {
	if instance == 0 {
		return .Zero_Object_Id
	}
	if problem := string_check(application.application_name); problem != .None {
		return problem
	}
	if problem := string_check(application.engine_name); problem != .None {
		return problem
	}
	mark := command_begin(encoder, .Create_Instance, flags) or_return
	put_pointer(encoder, true)
	put_structure(encoder, .Instance_Create_Info)
	put_u32(encoder, 0) // flags
	put_pointer(encoder, true)
	put_structure(encoder, .Application_Info)
	put_string(encoder, application.application_name)
	put_u32(encoder, application.application_version)
	put_string(encoder, application.engine_name)
	put_u32(encoder, application.engine_version)
	put_u32(encoder, application.api_version)
	put_u32(encoder, 0) // enabledLayerCount
	put_array_size(encoder, 0)
	put_u32(encoder, 0) // enabledExtensionCount
	put_array_size(encoder, 0)
	put_pointer(encoder, false) // pAllocator
	put_pointer(encoder, true)
	put_object(encoder, instance)
	return command_end(encoder, mark)
}

// encode_enumerate_physical_devices writes vkEnumeratePhysicalDevices. With
// no ids it asks the count; with ids it binds them to the physical devices.
encode_enumerate_physical_devices :: proc "contextless" (encoder: ^Encoder, instance: Object_Id, physical_devices: []Object_Id, flags := REPLY) -> Venus_Problem {
	if instance == 0 {
		return .Zero_Object_Id
	}
	if len(physical_devices) > 0 {
		if problem := objects_check(physical_devices); problem != .None {
			return problem
		}
	}
	mark := command_begin(encoder, .Enumerate_Physical_Devices, flags) or_return
	put_object(encoder, instance)
	put_pointer(encoder, true)
	put_u32(encoder, u32(len(physical_devices)))
	put_array_size(encoder, u64(len(physical_devices)))
	for id in physical_devices {
		put_object(encoder, id)
	}
	return command_end(encoder, mark)
}

// encode_get_physical_device_properties writes vkGetPhysicalDeviceProperties.
// The output struct is partial: only the sizes of its fixed arrays travel.
encode_get_physical_device_properties :: proc "contextless" (encoder: ^Encoder, physical_device: Object_Id, flags := REPLY) -> Venus_Problem {
	if physical_device == 0 {
		return .Zero_Object_Id
	}
	mark := command_begin(encoder, .Get_Physical_Device_Properties, flags) or_return
	put_object(encoder, physical_device)
	put_pointer(encoder, true)
	put_array_size(encoder, PHYSICAL_DEVICE_NAME_BYTES)
	put_array_size(encoder, UUID_BYTES)
	for field in LIMIT_FIELDS {
		if field.count > 1 {
			put_array_size(encoder, u64(field.count))
		}
	}
	return command_end(encoder, mark)
}

// encode_create_device writes vkCreateDevice with one queue of one family.
encode_create_device :: proc "contextless" (encoder: ^Encoder, physical_device, device: Object_Id, queue_family_index: u32, queue_priority: f32, flags := REPLY) -> Venus_Problem {
	if physical_device == 0 || device == 0 {
		return .Zero_Object_Id
	}
	if !(queue_priority >= 0 && queue_priority <= 1) {
		return .Count_Out_Of_Range
	}
	mark := command_begin(encoder, .Create_Device, flags) or_return
	put_object(encoder, physical_device)
	put_pointer(encoder, true)
	put_structure(encoder, .Device_Create_Info)
	put_u32(encoder, 0) // flags
	put_u32(encoder, 1) // queueCreateInfoCount
	put_array_size(encoder, 1)
	put_structure(encoder, .Device_Queue_Create_Info)
	put_u32(encoder, 0) // flags
	put_u32(encoder, queue_family_index)
	put_u32(encoder, 1) // queueCount
	put_array_size(encoder, 1)
	put_f32(encoder, queue_priority)
	put_u32(encoder, 0) // enabledLayerCount
	put_array_size(encoder, 0)
	put_u32(encoder, 0) // enabledExtensionCount
	put_array_size(encoder, 0)
	put_pointer(encoder, false) // pEnabledFeatures
	put_pointer(encoder, false) // pAllocator
	put_pointer(encoder, true)
	put_object(encoder, device)
	return command_end(encoder, mark)
}

// encode_get_device_queue_2 writes vkGetDeviceQueue2 and binds the id of the
// queue. The renderer refuses vkGetDeviceQueue and a second call for a queue.
encode_get_device_queue_2 :: proc "contextless" (encoder: ^Encoder, device: Object_Id, queue_family_index, queue_index: u32, queue: Object_Id, flags := Command_Flags{}) -> Venus_Problem {
	if device == 0 || queue == 0 {
		return .Zero_Object_Id
	}
	mark := command_begin(encoder, .Get_Device_Queue_2, flags) or_return
	put_object(encoder, device)
	put_pointer(encoder, true)
	put_structure(encoder, .Device_Queue_Info_2)
	put_u32(encoder, 0) // flags
	put_u32(encoder, queue_family_index)
	put_u32(encoder, queue_index)
	put_pointer(encoder, true)
	put_object(encoder, queue)
	return command_end(encoder, mark)
}

// encode_create_buffer writes vkCreateBuffer for an exclusive buffer.
encode_create_buffer :: proc "contextless" (encoder: ^Encoder, device, buffer: Object_Id, size: u64, usage: Buffer_Usage, flags := REPLY) -> Venus_Problem {
	if device == 0 || buffer == 0 {
		return .Zero_Object_Id
	}
	if size == 0 {
		return .Zero_Extent
	}
	usage_word := transmute(u32)usage
	if usage_word == 0 || usage_word & ~BUFFER_USAGE_KNOWN_BITS != 0 {
		return .Unknown_Flag_Bits
	}
	mark := command_begin(encoder, .Create_Buffer, flags) or_return
	put_object(encoder, device)
	put_pointer(encoder, true)
	put_structure(encoder, .Buffer_Create_Info)
	put_u32(encoder, 0) // flags
	put_u64(encoder, size)
	put_u32(encoder, usage_word)
	put_i32(encoder, 0) // VK_SHARING_MODE_EXCLUSIVE
	put_u32(encoder, 0) // queueFamilyIndexCount
	put_array_size(encoder, 0)
	put_pointer(encoder, false) // pAllocator
	put_pointer(encoder, true)
	put_object(encoder, buffer)
	return command_end(encoder, mark)
}

// encode_allocate_memory writes vkAllocateMemory.
encode_allocate_memory :: proc "contextless" (encoder: ^Encoder, device, memory: Object_Id, allocation_size: u64, memory_type_index: u32, flags := REPLY) -> Venus_Problem {
	if device == 0 || memory == 0 {
		return .Zero_Object_Id
	}
	if allocation_size == 0 {
		return .Zero_Extent
	}
	mark := command_begin(encoder, .Allocate_Memory, flags) or_return
	put_object(encoder, device)
	put_pointer(encoder, true)
	put_structure(encoder, .Memory_Allocate_Info)
	put_u64(encoder, allocation_size)
	put_u32(encoder, memory_type_index)
	put_pointer(encoder, false) // pAllocator
	put_pointer(encoder, true)
	put_object(encoder, memory)
	return command_end(encoder, mark)
}

// encode_bind_buffer_memory writes vkBindBufferMemory.
encode_bind_buffer_memory :: proc "contextless" (encoder: ^Encoder, device, buffer, memory: Object_Id, memory_offset: u64, flags := REPLY) -> Venus_Problem {
	if device == 0 || buffer == 0 || memory == 0 {
		return .Zero_Object_Id
	}
	mark := command_begin(encoder, .Bind_Buffer_Memory, flags) or_return
	put_object(encoder, device)
	put_object(encoder, buffer)
	put_object(encoder, memory)
	put_u64(encoder, memory_offset)
	return command_end(encoder, mark)
}

// encode_create_command_pool writes vkCreateCommandPool.
encode_create_command_pool :: proc "contextless" (encoder: ^Encoder, device, command_pool: Object_Id, queue_family_index: u32, pool_flags: Command_Pool_Flags, flags := REPLY) -> Venus_Problem {
	if device == 0 || command_pool == 0 {
		return .Zero_Object_Id
	}
	if transmute(u32)pool_flags & ~COMMAND_POOL_KNOWN_BITS != 0 {
		return .Unknown_Flag_Bits
	}
	mark := command_begin(encoder, .Create_Command_Pool, flags) or_return
	put_object(encoder, device)
	put_pointer(encoder, true)
	put_structure(encoder, .Command_Pool_Create_Info)
	put_u32(encoder, transmute(u32)pool_flags)
	put_u32(encoder, queue_family_index)
	put_pointer(encoder, false) // pAllocator
	put_pointer(encoder, true)
	put_object(encoder, command_pool)
	return command_end(encoder, mark)
}

// encode_allocate_command_buffers writes vkAllocateCommandBuffers and binds
// one id for each command buffer.
encode_allocate_command_buffers :: proc "contextless" (encoder: ^Encoder, device, command_pool: Object_Id, level: Command_Buffer_Level, command_buffers: []Object_Id, flags := REPLY) -> Venus_Problem {
	if device == 0 || command_pool == 0 {
		return .Zero_Object_Id
	}
	if problem := objects_check(command_buffers); problem != .None {
		return problem
	}
	if _, level_ok := command_buffer_level_of_word(i32(level)); !level_ok {
		return .Unknown_Enum_Word
	}
	mark := command_begin(encoder, .Allocate_Command_Buffers, flags) or_return
	put_object(encoder, device)
	put_pointer(encoder, true)
	put_structure(encoder, .Command_Buffer_Allocate_Info)
	put_object(encoder, command_pool)
	put_i32(encoder, i32(level))
	put_u32(encoder, u32(len(command_buffers)))
	put_array_size(encoder, u64(len(command_buffers)))
	for id in command_buffers {
		put_object(encoder, id)
	}
	return command_end(encoder, mark)
}

// encode_begin_command_buffer writes vkBeginCommandBuffer for a primary
// command buffer: no inheritance info.
encode_begin_command_buffer :: proc "contextless" (encoder: ^Encoder, command_buffer: Object_Id, usage: Command_Buffer_Usage, flags := Command_Flags{}) -> Venus_Problem {
	if command_buffer == 0 {
		return .Zero_Object_Id
	}
	if transmute(u32)usage & ~COMMAND_BUFFER_USAGE_KNOWN_BITS != 0 {
		return .Unknown_Flag_Bits
	}
	mark := command_begin(encoder, .Begin_Command_Buffer, flags) or_return
	put_object(encoder, command_buffer)
	put_pointer(encoder, true)
	put_structure(encoder, .Command_Buffer_Begin_Info)
	put_u32(encoder, transmute(u32)usage)
	put_pointer(encoder, false) // pInheritanceInfo
	return command_end(encoder, mark)
}

// encode_end_command_buffer writes vkEndCommandBuffer.
encode_end_command_buffer :: proc "contextless" (encoder: ^Encoder, command_buffer: Object_Id, flags := Command_Flags{}) -> Venus_Problem {
	if command_buffer == 0 {
		return .Zero_Object_Id
	}
	mark := command_begin(encoder, .End_Command_Buffer, flags) or_return
	put_object(encoder, command_buffer)
	return command_end(encoder, mark)
}

// encode_cmd_copy_buffer writes vkCmdCopyBuffer.
encode_cmd_copy_buffer :: proc "contextless" (encoder: ^Encoder, command_buffer, source, destination: Object_Id, regions: []Buffer_Copy, flags := Command_Flags{}) -> Venus_Problem {
	if command_buffer == 0 || source == 0 || destination == 0 {
		return .Zero_Object_Id
	}
	if len(regions) == 0 || len(regions) > MAX_ARRAY_ELEMENTS {
		return .Count_Out_Of_Range
	}
	for region in regions {
		if region.size == 0 {
			return .Zero_Extent
		}
	}
	mark := command_begin(encoder, .Cmd_Copy_Buffer, flags) or_return
	put_object(encoder, command_buffer)
	put_object(encoder, source)
	put_object(encoder, destination)
	put_u32(encoder, u32(len(regions)))
	put_array_size(encoder, u64(len(regions)))
	for region in regions {
		put_u64(encoder, region.source_offset)
		put_u64(encoder, region.destination_offset)
		put_u64(encoder, region.size)
	}
	return command_end(encoder, mark)
}

@(private = "file")
range_check :: proc "contextless" (range: Image_Subresource_Range) -> Venus_Problem {
	aspect_word := transmute(u32)range.aspects
	if aspect_word == 0 || aspect_word & ~IMAGE_ASPECT_KNOWN_BITS != 0 {
		return .Unknown_Flag_Bits
	}
	if range.level_count == 0 || range.layer_count == 0 {
		return .Zero_Extent
	}
	return .None
}

// encode_cmd_clear_color_image writes vkCmdClearColorImage. The color travels
// as the uint32 member of VkClearColorValue, its default union tag, so the
// bits of each float arrive unchanged.
encode_cmd_clear_color_image :: proc "contextless" (encoder: ^Encoder, command_buffer, image: Object_Id, layout: Image_Layout, color: [4]u32, range: Image_Subresource_Range, flags := Command_Flags{}) -> Venus_Problem {
	if command_buffer == 0 || image == 0 {
		return .Zero_Object_Id
	}
	if _, layout_ok := image_layout_of_word(i32(layout)); !layout_ok {
		return .Unknown_Enum_Word
	}
	if problem := range_check(range); problem != .None {
		return problem
	}
	mark := command_begin(encoder, .Cmd_Clear_Color_Image, flags) or_return
	put_object(encoder, command_buffer)
	put_object(encoder, image)
	put_i32(encoder, i32(layout))
	put_pointer(encoder, true)
	put_clear_color(encoder, color)
	put_u32(encoder, 1) // rangeCount
	put_array_size(encoder, 1)
	put_u32(encoder, transmute(u32)range.aspects)
	put_u32(encoder, range.base_mip_level)
	put_u32(encoder, range.level_count)
	put_u32(encoder, range.base_array_layer)
	put_u32(encoder, range.layer_count)
	return command_end(encoder, mark)
}

@(private = "file")
put_clear_color :: proc "contextless" (encoder: ^Encoder, color: [4]u32) {
	put_u32(encoder, u32(Clear_Color_Tag.Unsigned_32))
	put_array_size(encoder, 4)
	for word in color {
		put_u32(encoder, word)
	}
}

// encode_cmd_begin_render_pass writes vkCmdBeginRenderPass with inline
// subpass contents.
encode_cmd_begin_render_pass :: proc "contextless" (encoder: ^Encoder, command_buffer, render_pass, framebuffer: Object_Id, render_area: Rect_2D, clear_values: []Clear_Value, flags := Command_Flags{}) -> Venus_Problem {
	if command_buffer == 0 || render_pass == 0 || framebuffer == 0 {
		return .Zero_Object_Id
	}
	if render_area.width == 0 || render_area.height == 0 {
		return .Zero_Extent
	}
	if len(clear_values) > MAX_ARRAY_ELEMENTS {
		return .Count_Out_Of_Range
	}
	for value in clear_values {
		if value == nil {
			return .Unknown_Union_Tag
		}
	}
	mark := command_begin(encoder, .Cmd_Begin_Render_Pass, flags) or_return
	put_object(encoder, command_buffer)
	put_pointer(encoder, true)
	put_structure(encoder, .Render_Pass_Begin_Info)
	put_object(encoder, render_pass)
	put_object(encoder, framebuffer)
	put_i32(encoder, render_area.x)
	put_i32(encoder, render_area.y)
	put_u32(encoder, render_area.width)
	put_u32(encoder, render_area.height)
	put_u32(encoder, u32(len(clear_values)))
	put_array_size(encoder, u64(len(clear_values)))
	for value in clear_values {
		switch clear in value {
		case [4]u32:
			put_u32(encoder, u32(Clear_Value_Tag.Color))
			put_clear_color(encoder, clear)
		case Clear_Depth_Stencil:
			put_u32(encoder, u32(Clear_Value_Tag.Depth_Stencil))
			put_f32(encoder, clear.depth)
			put_u32(encoder, clear.stencil)
		}
	}
	put_i32(encoder, i32(Subpass_Contents.Inline))
	return command_end(encoder, mark)
}

encode_cmd_end_render_pass :: proc "contextless" (encoder: ^Encoder, command_buffer: Object_Id, flags := Command_Flags{}) -> Venus_Problem {
	if command_buffer == 0 {
		return .Zero_Object_Id
	}
	mark := command_begin(encoder, .Cmd_End_Render_Pass, flags) or_return
	put_object(encoder, command_buffer)
	return command_end(encoder, mark)
}

encode_cmd_bind_pipeline :: proc "contextless" (encoder: ^Encoder, command_buffer: Object_Id, bind_point: Pipeline_Bind_Point, pipeline: Object_Id, flags := Command_Flags{}) -> Venus_Problem {
	if command_buffer == 0 || pipeline == 0 {
		return .Zero_Object_Id
	}
	if _, point_ok := pipeline_bind_point_of_word(i32(bind_point)); !point_ok {
		return .Unknown_Enum_Word
	}
	mark := command_begin(encoder, .Cmd_Bind_Pipeline, flags) or_return
	put_object(encoder, command_buffer)
	put_i32(encoder, i32(bind_point))
	put_object(encoder, pipeline)
	return command_end(encoder, mark)
}

encode_cmd_set_scissor :: proc "contextless" (encoder: ^Encoder, command_buffer: Object_Id, scissor: Rect_2D, flags := Command_Flags{}) -> Venus_Problem {
	if command_buffer == 0 {
		return .Zero_Object_Id
	}
	if scissor.width == 0 || scissor.height == 0 {
		return .Zero_Extent
	}
	if scissor.x < 0 || scissor.y < 0 {
		return .Dimension_Too_Large
	}
	mark := command_begin(encoder, .Cmd_Set_Scissor, flags) or_return
	put_object(encoder, command_buffer)
	put_u32(encoder, 0) // firstScissor
	put_u32(encoder, 1) // scissorCount
	put_array_size(encoder, 1)
	put_i32(encoder, scissor.x)
	put_i32(encoder, scissor.y)
	put_u32(encoder, scissor.width)
	put_u32(encoder, scissor.height)
	return command_end(encoder, mark)
}

encode_cmd_bind_vertex_buffers :: proc "contextless" (encoder: ^Encoder, command_buffer: Object_Id, first_binding: u32, buffer: Object_Id, offset: u64, flags := Command_Flags{}) -> Venus_Problem {
	if command_buffer == 0 || buffer == 0 {
		return .Zero_Object_Id
	}
	mark := command_begin(encoder, .Cmd_Bind_Vertex_Buffers, flags) or_return
	put_object(encoder, command_buffer)
	put_u32(encoder, first_binding)
	put_u32(encoder, 1) // bindingCount
	put_array_size(encoder, 1)
	put_object(encoder, buffer)
	put_array_size(encoder, 1)
	put_u64(encoder, offset)
	return command_end(encoder, mark)
}

encode_cmd_bind_index_buffer :: proc "contextless" (encoder: ^Encoder, command_buffer, buffer: Object_Id, offset: u64, index_type: Index_Type, flags := Command_Flags{}) -> Venus_Problem {
	if command_buffer == 0 || buffer == 0 {
		return .Zero_Object_Id
	}
	if _, type_ok := index_type_of_word(i32(index_type)); !type_ok {
		return .Unknown_Enum_Word
	}
	stride := u64(index_type == .Uint16 ? 2 : 4)
	if offset % stride != 0 {
		return .Misaligned_Length
	}
	mark := command_begin(encoder, .Cmd_Bind_Index_Buffer, flags) or_return
	put_object(encoder, command_buffer)
	put_object(encoder, buffer)
	put_u64(encoder, offset)
	put_i32(encoder, i32(index_type))
	return command_end(encoder, mark)
}

encode_cmd_bind_descriptor_sets :: proc "contextless" (encoder: ^Encoder, command_buffer: Object_Id, bind_point: Pipeline_Bind_Point, layout: Object_Id, first_set: u32, descriptor_set: Object_Id, flags := Command_Flags{}) -> Venus_Problem {
	if command_buffer == 0 || layout == 0 || descriptor_set == 0 {
		return .Zero_Object_Id
	}
	if _, point_ok := pipeline_bind_point_of_word(i32(bind_point)); !point_ok {
		return .Unknown_Enum_Word
	}
	mark := command_begin(encoder, .Cmd_Bind_Descriptor_Sets, flags) or_return
	put_object(encoder, command_buffer)
	put_i32(encoder, i32(bind_point))
	put_object(encoder, layout)
	put_u32(encoder, first_set)
	put_u32(encoder, 1) // descriptorSetCount
	put_array_size(encoder, 1)
	put_object(encoder, descriptor_set)
	put_u32(encoder, 0) // dynamicOffsetCount
	put_array_size(encoder, 0)
	return command_end(encoder, mark)
}

encode_cmd_draw :: proc "contextless" (encoder: ^Encoder, command_buffer: Object_Id, vertex_count, instance_count, first_vertex, first_instance: u32, flags := Command_Flags{}) -> Venus_Problem {
	if command_buffer == 0 {
		return .Zero_Object_Id
	}
	if vertex_count == 0 || instance_count == 0 {
		return .Zero_Extent
	}
	mark := command_begin(encoder, .Cmd_Draw, flags) or_return
	put_object(encoder, command_buffer)
	put_u32(encoder, vertex_count)
	put_u32(encoder, instance_count)
	put_u32(encoder, first_vertex)
	put_u32(encoder, first_instance)
	return command_end(encoder, mark)
}

encode_cmd_draw_indexed :: proc "contextless" (encoder: ^Encoder, command_buffer: Object_Id, index_count, instance_count, first_index: u32, vertex_offset: i32, first_instance: u32, flags := Command_Flags{}) -> Venus_Problem {
	if command_buffer == 0 {
		return .Zero_Object_Id
	}
	if index_count == 0 || instance_count == 0 {
		return .Zero_Extent
	}
	mark := command_begin(encoder, .Cmd_Draw_Indexed, flags) or_return
	put_object(encoder, command_buffer)
	put_u32(encoder, index_count)
	put_u32(encoder, instance_count)
	put_u32(encoder, first_index)
	put_i32(encoder, vertex_offset)
	put_u32(encoder, first_instance)
	return command_end(encoder, mark)
}

encode_cmd_copy_buffer_to_image :: proc "contextless" (encoder: ^Encoder, command_buffer, source: Object_Id, destination: Object_Id, layout: Image_Layout, region: Buffer_Image_Copy, flags := Command_Flags{}) -> Venus_Problem {
	if command_buffer == 0 || source == 0 || destination == 0 {
		return .Zero_Object_Id
	}
	if _, layout_ok := image_layout_of_word(i32(layout)); !layout_ok {
		return .Unknown_Enum_Word
	}
	aspect_word := transmute(u32)region.aspects
	if aspect_word == 0 || aspect_word & ~IMAGE_ASPECT_KNOWN_BITS != 0 {
		return .Unknown_Flag_Bits
	}
	if region.width == 0 || region.height == 0 || region.depth == 0 || region.layer_count == 0 {
		return .Zero_Extent
	}
	mark := command_begin(encoder, .Cmd_Copy_Buffer_To_Image, flags) or_return
	put_object(encoder, command_buffer)
	put_object(encoder, source)
	put_object(encoder, destination)
	put_i32(encoder, i32(layout))
	put_u32(encoder, 1) // regionCount
	put_array_size(encoder, 1)
	put_u64(encoder, region.buffer_offset)
	put_u32(encoder, region.buffer_row_length)
	put_u32(encoder, region.buffer_image_height)
	put_u32(encoder, aspect_word)
	put_u32(encoder, region.mip_level)
	put_u32(encoder, region.base_array_layer)
	put_u32(encoder, region.layer_count)
	put_i32(encoder, region.image_x)
	put_i32(encoder, region.image_y)
	put_i32(encoder, region.image_z)
	put_u32(encoder, region.width)
	put_u32(encoder, region.height)
	put_u32(encoder, region.depth)
	return command_end(encoder, mark)
}

// encode_queue_submit writes vkQueueSubmit with one VkSubmitInfo and no
// semaphore. The fence can be 0.
encode_queue_submit :: proc "contextless" (encoder: ^Encoder, queue: Object_Id, command_buffers: []Object_Id, fence: Object_Id, flags := Command_Flags{}) -> Venus_Problem {
	if queue == 0 {
		return .Zero_Object_Id
	}
	if problem := objects_check(command_buffers); problem != .None {
		return problem
	}
	mark := command_begin(encoder, .Queue_Submit, flags) or_return
	put_object(encoder, queue)
	put_u32(encoder, 1) // submitCount
	put_array_size(encoder, 1)
	put_structure(encoder, .Submit_Info)
	put_u32(encoder, 0) // waitSemaphoreCount
	put_array_size(encoder, 0)
	put_array_size(encoder, 0) // pWaitDstStageMask
	put_u32(encoder, u32(len(command_buffers)))
	put_array_size(encoder, u64(len(command_buffers)))
	for id in command_buffers {
		put_object(encoder, id)
	}
	put_u32(encoder, 0) // signalSemaphoreCount
	put_array_size(encoder, 0)
	put_object(encoder, fence)
	return command_end(encoder, mark)
}

encode_queue_wait_idle :: proc "contextless" (encoder: ^Encoder, queue: Object_Id, flags := REPLY) -> Venus_Problem {
	if queue == 0 {
		return .Zero_Object_Id
	}
	mark := command_begin(encoder, .Queue_Wait_Idle, flags) or_return
	put_object(encoder, queue)
	return command_end(encoder, mark)
}

// encode_set_reply_command_stream writes vkSetReplyCommandStreamMESA: the
// renderer writes the next replies into this range of a blob resource.
encode_set_reply_command_stream :: proc "contextless" (encoder: ^Encoder, resource_id: u32, offset, size: u64, flags := Command_Flags{}) -> Venus_Problem {
	if resource_id == 0 {
		return .Zero_Object_Id
	}
	if size == 0 {
		return .Zero_Extent
	}
	if offset % 4 != 0 || size % 4 != 0 {
		return .Misaligned_Length
	}
	mark := command_begin(encoder, .Set_Reply_Command_Stream, flags) or_return
	put_pointer(encoder, true)
	put_u32(encoder, resource_id)
	put_u64(encoder, offset)
	put_u64(encoder, size)
	return command_end(encoder, mark)
}

// encode_seek_reply_command_stream writes vkSeekReplyCommandStreamMESA.
encode_seek_reply_command_stream :: proc "contextless" (encoder: ^Encoder, position: u64, flags := Command_Flags{}) -> Venus_Problem {
	if position % 4 != 0 {
		return .Misaligned_Length
	}
	mark := command_begin(encoder, .Seek_Reply_Command_Stream, flags) or_return
	put_u64(encoder, position)
	return command_end(encoder, mark)
}

// encode_create_ring writes vkCreateRingMESA.
encode_create_ring :: proc "contextless" (encoder: ^Encoder, ring: u64, info: Ring_Create_Info, flags := Command_Flags{}) -> Venus_Problem {
	if ring == 0 || info.resource_id == 0 {
		return .Zero_Object_Id
	}
	if problem := ring_create_info_check(info); problem != .None {
		return problem
	}
	mark := command_begin(encoder, .Create_Ring, flags) or_return
	put_u64(encoder, ring)
	put_pointer(encoder, true)
	put_structure(encoder, .Ring_Create_Info)
	put_u32(encoder, 0) // flags
	put_u32(encoder, info.resource_id)
	put_u64(encoder, info.offset)
	put_u64(encoder, info.size)
	put_u64(encoder, info.idle_timeout)
	put_u64(encoder, info.head_offset)
	put_u64(encoder, info.tail_offset)
	put_u64(encoder, info.status_offset)
	put_u64(encoder, info.buffer_offset)
	put_u64(encoder, info.buffer_size)
	put_u64(encoder, info.extra_offset)
	put_u64(encoder, info.extra_size)
	return command_end(encoder, mark)
}

encode_destroy_ring :: proc "contextless" (encoder: ^Encoder, ring: u64, flags := Command_Flags{}) -> Venus_Problem {
	if ring == 0 {
		return .Zero_Object_Id
	}
	mark := command_begin(encoder, .Destroy_Ring, flags) or_return
	put_u64(encoder, ring)
	return command_end(encoder, mark)
}

// encode_notify_ring writes vkNotifyRingMESA: it wakes a renderer that set
// the idle bit of the ring status.
encode_notify_ring :: proc "contextless" (encoder: ^Encoder, ring: u64, seqno: u32, flags := Command_Flags{}) -> Venus_Problem {
	if ring == 0 {
		return .Zero_Object_Id
	}
	mark := command_begin(encoder, .Notify_Ring, flags) or_return
	put_u64(encoder, ring)
	put_u32(encoder, seqno)
	put_u32(encoder, 0) // flags
	return command_end(encoder, mark)
}
