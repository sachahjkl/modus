package venus_vulkan

// The recording encoders of the 2D draw that venus_commands.odin does not
// hold: the layout transitions of an image (vkCmdPipelineBarrier), the copy
// of an image into a buffer for the readback, the upload of the vertices
// and the indices inside the stream (vkCmdUpdateBuffer), the push constants
// and the dynamic viewport. Each one asks no reply: the renderer runs them
// in order.

// VkImageMemoryBarrier with no transfer of queue ownership.
Image_Memory_Barrier :: struct {
	source_access:      Access_Flags,
	destination_access: Access_Flags,
	old_layout:         Image_Layout,
	new_layout:         Image_Layout,
	image:              Object_Id,
	range:              Image_Subresource_Range,
}

// VkMemoryBarrier: it makes the writes of the source stages visible to the
// reads of the destination stages, for each buffer at once.
Memory_Barrier :: struct {
	source_access:      Access_Flags,
	destination_access: Access_Flags,
}

// VkViewport.
Viewport :: struct {
	x:         f32,
	y:         f32,
	width:     f32,
	height:    f32,
	min_depth: f32,
	max_depth: f32,
}

@(private)
stages_check :: proc "contextless" (stages: Pipeline_Stages) -> Venus_Problem {
	word := transmute(u32)stages
	if word == 0 {
		return .Missing_Flag_Bits
	}
	if word & ~PIPELINE_STAGE_KNOWN_BITS != 0 {
		return .Unknown_Flag_Bits
	}
	return .None
}

@(private)
image_barrier_check :: proc "contextless" (barrier: Image_Memory_Barrier) -> Venus_Problem {
	if barrier.image == 0 {
		return .Zero_Object_Id
	}
	if transmute(u32)barrier.source_access & ~ACCESS_KNOWN_BITS != 0 || transmute(u32)barrier.destination_access & ~ACCESS_KNOWN_BITS != 0 {
		return .Unknown_Flag_Bits
	}
	if _, old_ok := image_layout_of_word(i32(barrier.old_layout)); !old_ok {
		return .Unknown_Enum_Word
	}
	if _, new_ok := image_layout_of_word(i32(barrier.new_layout)); !new_ok {
		return .Unknown_Enum_Word
	}
	// Vulkan forbids a transition to UNDEFINED: it would drop the contents
	// with no meaning.
	if barrier.new_layout == .Undefined {
		return .Layout_Transition_Invalid
	}
	return range_check(barrier.range)
}

// encode_cmd_pipeline_barrier writes vkCmdPipelineBarrier with global
// memory barriers and image memory barriers, at least one of them: no buffer
// memory barrier and no dependency flag.
encode_cmd_pipeline_barrier :: proc "contextless" (
	encoder: ^Encoder,
	command_buffer: Object_Id,
	source_stages, destination_stages: Pipeline_Stages,
	memory_barriers: []Memory_Barrier,
	barriers: []Image_Memory_Barrier,
	flags := Command_Flags{},
) -> Venus_Problem {
	if command_buffer == 0 {
		return .Zero_Object_Id
	}
	stages_check(source_stages) or_return
	stages_check(destination_stages) or_return
	if len(memory_barriers) + len(barriers) == 0 || len(memory_barriers) > MAX_ARRAY_ELEMENTS || len(barriers) > MAX_ARRAY_ELEMENTS {
		return .Count_Out_Of_Range
	}
	for barrier in memory_barriers {
		if transmute(u32)barrier.source_access & ~ACCESS_KNOWN_BITS != 0 || transmute(u32)barrier.destination_access & ~ACCESS_KNOWN_BITS != 0 {
			return .Unknown_Flag_Bits
		}
	}
	for barrier in barriers {
		image_barrier_check(barrier) or_return
	}
	mark := command_begin(encoder, .Cmd_Pipeline_Barrier, flags) or_return
	put_object(encoder, command_buffer)
	put_u32(encoder, transmute(u32)source_stages)
	put_u32(encoder, transmute(u32)destination_stages)
	put_u32(encoder, 0) // dependencyFlags
	put_u32(encoder, u32(len(memory_barriers)))
	put_array_size(encoder, u64(len(memory_barriers)))
	for barrier in memory_barriers {
		put_structure(encoder, .Memory_Barrier)
		put_u32(encoder, transmute(u32)barrier.source_access)
		put_u32(encoder, transmute(u32)barrier.destination_access)
	}
	put_u32(encoder, 0) // bufferMemoryBarrierCount
	put_array_size(encoder, 0)
	put_u32(encoder, u32(len(barriers)))
	put_array_size(encoder, u64(len(barriers)))
	for barrier in barriers {
		put_structure(encoder, .Image_Memory_Barrier)
		put_u32(encoder, transmute(u32)barrier.source_access)
		put_u32(encoder, transmute(u32)barrier.destination_access)
		put_i32(encoder, i32(barrier.old_layout))
		put_i32(encoder, i32(barrier.new_layout))
		put_u32(encoder, QUEUE_FAMILY_IGNORED)
		put_u32(encoder, QUEUE_FAMILY_IGNORED)
		put_object(encoder, barrier.image)
		put_subresource_range(encoder, barrier.range)
	}
	return command_end(encoder, mark)
}

// encode_cmd_copy_image_to_buffer writes vkCmdCopyImageToBuffer. Vulkan
// reads the image only in the layout TRANSFER_SRC_OPTIMAL or GENERAL.
encode_cmd_copy_image_to_buffer :: proc "contextless" (encoder: ^Encoder, command_buffer, source: Object_Id, layout: Image_Layout, destination: Object_Id, region: Buffer_Image_Copy, flags := Command_Flags{}) -> Venus_Problem {
	if command_buffer == 0 || source == 0 || destination == 0 {
		return .Zero_Object_Id
	}
	if _, layout_ok := image_layout_of_word(i32(layout)); !layout_ok {
		return .Unknown_Enum_Word
	}
	if layout != .Transfer_Source_Optimal && layout != .General {
		return .Layout_Transition_Invalid
	}
	aspect_word := transmute(u32)region.aspects
	if aspect_word == 0 || aspect_word & ~IMAGE_ASPECT_KNOWN_BITS != 0 {
		return .Unknown_Flag_Bits
	}
	if region.width == 0 || region.height == 0 || region.depth == 0 || region.layer_count == 0 {
		return .Zero_Extent
	}
	mark := command_begin(encoder, .Cmd_Copy_Image_To_Buffer, flags) or_return
	put_object(encoder, command_buffer)
	put_object(encoder, source)
	put_i32(encoder, i32(layout))
	put_object(encoder, destination)
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

// encode_cmd_update_buffer writes vkCmdUpdateBuffer: the bytes travel inside
// the stream, so a buffer gets its contents with no mapped memory.
encode_cmd_update_buffer :: proc "contextless" (encoder: ^Encoder, command_buffer, buffer: Object_Id, offset: u64, data: []u8, flags := Command_Flags{}) -> Venus_Problem {
	if command_buffer == 0 || buffer == 0 {
		return .Zero_Object_Id
	}
	if len(data) == 0 {
		return .Zero_Extent
	}
	if len(data) > MAX_UPDATE_BUFFER_BYTES {
		return .Count_Out_Of_Range
	}
	if offset % 4 != 0 || len(data) % 4 != 0 {
		return .Misaligned_Length
	}
	mark := command_begin(encoder, .Cmd_Update_Buffer, flags) or_return
	put_object(encoder, command_buffer)
	put_object(encoder, buffer)
	put_u64(encoder, offset)
	put_u64(encoder, u64(len(data))) // dataSize
	put_array_size(encoder, u64(len(data)))
	put_bytes(encoder, data)
	return command_end(encoder, mark)
}

// encode_cmd_push_constants writes vkCmdPushConstants.
encode_cmd_push_constants :: proc "contextless" (encoder: ^Encoder, command_buffer, layout: Object_Id, stages: Shader_Stages, offset: u32, data: []u8, flags := Command_Flags{}) -> Venus_Problem {
	if command_buffer == 0 || layout == 0 {
		return .Zero_Object_Id
	}
	if len(data) > MAX_PUSH_CONSTANT_BYTES {
		return .Count_Out_Of_Range
	}
	push_constant_range_check(stages, offset, u32(len(data))) or_return
	mark := command_begin(encoder, .Cmd_Push_Constants, flags) or_return
	put_object(encoder, command_buffer)
	put_object(encoder, layout)
	put_u32(encoder, transmute(u32)stages)
	put_u32(encoder, offset)
	put_u32(encoder, u32(len(data)))
	put_array_size(encoder, u64(len(data)))
	put_bytes(encoder, data)
	return command_end(encoder, mark)
}

@(private)
viewport_check :: proc "contextless" (viewport: Viewport) -> Venus_Problem {
	// A comparison with a NaN is false, so each test is written to refuse it.
	if !(viewport.width > 0) || !(viewport.height > 0) {
		return .Zero_Extent
	}
	if !(viewport.width <= MAX_IMAGE_DIMENSION) || !(viewport.height <= MAX_IMAGE_DIMENSION) {
		return .Dimension_Too_Large
	}
	if !(viewport.x >= -MAX_IMAGE_DIMENSION && viewport.x <= MAX_IMAGE_DIMENSION) || !(viewport.y >= -MAX_IMAGE_DIMENSION && viewport.y <= MAX_IMAGE_DIMENSION) {
		return .Dimension_Too_Large
	}
	if !(viewport.min_depth >= 0 && viewport.min_depth <= 1) || !(viewport.max_depth >= 0 && viewport.max_depth <= 1) {
		return .Count_Out_Of_Range
	}
	return .None
}

// encode_cmd_set_viewport writes vkCmdSetViewport for viewport 0.
encode_cmd_set_viewport :: proc "contextless" (encoder: ^Encoder, command_buffer: Object_Id, viewport: Viewport, flags := Command_Flags{}) -> Venus_Problem {
	if command_buffer == 0 {
		return .Zero_Object_Id
	}
	viewport_check(viewport) or_return
	mark := command_begin(encoder, .Cmd_Set_Viewport, flags) or_return
	put_object(encoder, command_buffer)
	put_u32(encoder, 0) // firstViewport
	put_u32(encoder, 1) // viewportCount
	put_array_size(encoder, 1)
	put_f32(encoder, viewport.x)
	put_f32(encoder, viewport.y)
	put_f32(encoder, viewport.width)
	put_f32(encoder, viewport.height)
	put_f32(encoder, viewport.min_depth)
	put_f32(encoder, viewport.max_depth)
	return command_end(encoder, mark)
}
