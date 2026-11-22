package venus_vulkan

import "modus:contract/byte_order"
import "modus:contract/draw_record"
import "modus:contract/virtio_gpu"
import "modus:contract/webgpu_subset"

// The GPU back end of the draw table: a draw table becomes a stream of the
// WebGPU subset (webgpu_subset.draw_table_translate_to_webgpu), and that
// stream becomes the Venus commands that record, submit and read back one
// frame (src/md/features/gpu_access.md, "The draw table on the virtual
// GPU"). The vertices and the indices travel inside the Venus stream with
// vkCmdUpdateBuffer, because no process maps the host-visible memory of the
// device yet.
//
// The objects of a frame are numbered as the WebGPU back end numbers them:
// the object id of its base plus its number. encode_draw_table_venus_objects
// creates them once; draw_table_to_venus records each frame on them.

// The numbers of the objects of a draw table in the WebGPU subset.
DRAW_TABLE_COLOR_TEXTURE :: u32(1)
DRAW_TABLE_PIPELINE :: u32(1)
DRAW_TABLE_VERTEX_BUFFER :: u32(1)
DRAW_TABLE_INDEX_BUFFER :: u32(2)
DRAW_TABLE_READBACK_BUFFER :: u32(3)

// The push constants of the 2D vertex shader: the width and the height of
// the surface in pixels, two floats, so the shader turns a pixel place into
// a place of the viewport.
DRAW_TABLE_PUSH_CONSTANT_BYTES :: 8

// The entry point of the two shaders of the 2D pipeline.
DRAW_TABLE_SHADER_ENTRY_POINT :: "main"

// The vertex attributes of webgpu_subset.Vertex_2D: the place, the color,
// the texture coordinate.
@(rodata)
DRAW_TABLE_VERTEX_ATTRIBUTES := [3]Vertex_Attribute {
	{location = 0, format = .R32G32_Signed_Float, offset = 0},
	{location = 1, format = .R32G32B32A32_Signed_Float, offset = 8},
	{location = 2, format = .R32G32_Signed_Float, offset = 24},
}

// The blend of the 2D pipeline: straight alpha over the target, as the
// processor back end blends.
DRAW_TABLE_BLEND :: Color_Blend {
	enabled                  = true,
	source_color_factor      = .Source_Alpha,
	destination_color_factor = .One_Minus_Source_Alpha,
	color_operation          = .Add,
	source_alpha_factor      = .One,
	destination_alpha_factor = .One_Minus_Source_Alpha,
	alpha_operation          = .Add,
}

// The target of a draw table on the GPU: the objects, the surface, and what
// the render pass does with the contents of the last frame.
Draw_Table_Venus_Target :: struct {
	objects:             Translation_Objects,
	surface_width:       u32,
	surface_height:      u32,
	format:              Format,
	// The sizes of the vertex and the index buffers of the GPU.
	vertex_buffer_bytes: u64,
	index_buffer_bytes:  u64,
	// Clear: the frame starts from clear_color. Load: the frame starts from
	// the last frame, which the readback left in TRANSFER_SRC_OPTIMAL.
	load_op:             webgpu_subset.Load_Op,
	clear_color:         webgpu_subset.Clear_Color,
	has_damage_rect:     bool,
	damage_rect:         webgpu_subset.Pixel_Rect,
}

// The objects that encode_draw_table_venus_objects creates beside those of
// the target, and the SPIR-V of the two shaders that the build compiled.
Draw_Table_Venus_Setup :: struct {
	device:                   Object_Id,
	image_memory:             Object_Id,
	image_memory_bytes:       u64,
	image_view:               Object_Id,
	device_local_memory_type: u32,
	// The memory of the vertex, the index and the readback buffer.
	buffer_memories:          [3]Object_Id,
	host_visible_memory_type: u32,
	vertex_shader:            Object_Id,
	fragment_shader:          Object_Id,
	vertex_shader_code:       []u8,
	fragment_shader_code:     []u8,
}

Draw_Table_Venus_Result :: struct {
	written:             int,
	venus_command_count: u32,
	translation:         webgpu_subset.Draw_Table_Translate_Result,
}

@(private = "file")
Draw_Table_Objects :: struct {
	image:           Object_Id,
	render_pass:     Object_Id,
	framebuffer:     Object_Id,
	pipeline:        Object_Id,
	vertex_buffer:   Object_Id,
	index_buffer:    Object_Id,
	readback_buffer: Object_Id,
}

@(private = "file")
texture_format_of :: proc "contextless" (format: Format) -> (texture_format: webgpu_subset.Texture_Format, ok: bool) {
	switch format {
	case .R8G8B8A8_Unorm:
		return .RGBA8_Unorm, true
	case .R8G8B8A8_Srgb:
		return .RGBA8_Unorm_Srgb, true
	case .B8G8R8A8_Unorm:
		return .BGRA8_Unorm, true
	case .Undefined, .B8G8R8A8_Srgb, .R32G32_Signed_Float, .R32G32B32A32_Signed_Float:
		return .None, false
	}
	return .None, false
}

@(private = "file")
readback_bytes_of :: proc "contextless" (target: Draw_Table_Venus_Target) -> u64 {
	return u64(target.surface_width) * u64(target.surface_height) * 4
}

// target_check refuses a target whose objects, surface, format or load
// operation the frame cannot use, and gives the ids of its objects.
@(private = "file")
target_check :: proc "contextless" (target: Draw_Table_Venus_Target) -> (ids: Draw_Table_Objects, problem: Venus_Problem) {
	objects := target.objects
	if objects.command_buffer == 0 || objects.queue == 0 || objects.pipeline_layout == 0 {
		return {}, .Zero_Object_Id
	}
	extent_check(target.surface_width, target.surface_height) or_return
	enum_check(target.format) or_return
	if _, format_ok := texture_format_of(target.format); !format_ok {
		return {}, .Unknown_Enum_Word
	}
	load_op, load_ok := webgpu_subset.load_op_of_word(u32(target.load_op))
	if !load_ok {
		return {}, .Unknown_Enum_Word
	}
	switch load_op {
	case .Clear, .Load:
	case .None:
		return {}, .Unknown_Enum_Word
	}
	if target.vertex_buffer_bytes == 0 || target.index_buffer_bytes == 0 {
		return {}, .Zero_Extent
	}
	ids.image = object_of(objects.image_base, DRAW_TABLE_COLOR_TEXTURE) or_return
	ids.render_pass = object_of(objects.render_pass_base, DRAW_TABLE_COLOR_TEXTURE) or_return
	ids.framebuffer = object_of(objects.framebuffer_base, DRAW_TABLE_COLOR_TEXTURE) or_return
	ids.pipeline = object_of(objects.pipeline_base, DRAW_TABLE_PIPELINE) or_return
	ids.vertex_buffer = object_of(objects.buffer_base, DRAW_TABLE_VERTEX_BUFFER) or_return
	ids.index_buffer = object_of(objects.buffer_base, DRAW_TABLE_INDEX_BUFFER) or_return
	ids.readback_buffer = object_of(objects.buffer_base, DRAW_TABLE_READBACK_BUFFER) or_return
	return ids, .None
}

@(private = "file")
create_buffer_with_memory :: proc "contextless" (encoder: ^Encoder, device, buffer, memory: Object_Id, size: u64, usage: Buffer_Usage, memory_type: u32) -> Venus_Problem {
	encode_create_buffer(encoder, device, buffer, size, usage) or_return
	encode_allocate_memory(encoder, device, memory, size, memory_type) or_return
	return encode_bind_buffer_memory(encoder, device, buffer, memory, 0)
}

@(private = "file")
write_objects :: proc "contextless" (encoder: ^Encoder, target: Draw_Table_Venus_Target, setup: Draw_Table_Venus_Setup, ids: Draw_Table_Objects) -> Venus_Problem {
	device := setup.device
	width := target.surface_width
	height := target.surface_height
	color_range := Image_Subresource_Range{aspects = {.Color}, level_count = 1, layer_count = 1}
	encode_create_image(encoder, device, ids.image, {format = target.format, width = width, height = height, usage = {.Color_Attachment, .Transfer_Source}, tiling = .Optimal}) or_return
	encode_allocate_memory(encoder, device, setup.image_memory, setup.image_memory_bytes, setup.device_local_memory_type) or_return
	encode_bind_image_memory(encoder, device, ids.image, setup.image_memory, 0) or_return
	encode_create_image_view(encoder, device, ids.image, setup.image_view, target.format, color_range) or_return
	attachment := Color_Attachment_Description {
		format       = target.format,
		load_op      = .Clear,
		store_op     = .Store,
		final_layout = .Color_Attachment_Optimal,
	}
	if target.load_op == .Load {
		attachment.load_op = .Load
		attachment.initial_layout = .Color_Attachment_Optimal
	}
	encode_create_render_pass(encoder, device, ids.render_pass, attachment) or_return
	views := [1]Object_Id{setup.image_view}
	encode_create_framebuffer(encoder, device, ids.framebuffer, ids.render_pass, views[:], width, height) or_return
	encode_create_shader_module(encoder, device, setup.vertex_shader, setup.vertex_shader_code) or_return
	encode_create_shader_module(encoder, device, setup.fragment_shader, setup.fragment_shader_code) or_return
	push_ranges := [1]Push_Constant_Range{{stages = {.Vertex}, offset = 0, size = DRAW_TABLE_PUSH_CONSTANT_BYTES}}
	encode_create_pipeline_layout(encoder, device, target.objects.pipeline_layout, nil, push_ranges[:]) or_return
	attributes := DRAW_TABLE_VERTEX_ATTRIBUTES
	pipeline := Graphics_Pipeline_Description {
		vertex_shader     = setup.vertex_shader,
		fragment_shader   = setup.fragment_shader,
		entry_point       = DRAW_TABLE_SHADER_ENTRY_POINT,
		vertex_stride     = webgpu_subset.VERTEX_2D_STRIDE,
		vertex_attributes = attributes[:],
		topology          = .Triangle_List,
		blend             = DRAW_TABLE_BLEND,
		layout            = target.objects.pipeline_layout,
		render_pass       = ids.render_pass,
	}
	encode_create_graphics_pipelines(encoder, device, ids.pipeline, pipeline) or_return
	create_buffer_with_memory(encoder, device, ids.vertex_buffer, setup.buffer_memories[0], target.vertex_buffer_bytes, {.Vertex_Buffer, .Transfer_Destination}, setup.host_visible_memory_type) or_return
	create_buffer_with_memory(encoder, device, ids.index_buffer, setup.buffer_memories[1], target.index_buffer_bytes, {.Index_Buffer, .Transfer_Destination}, setup.host_visible_memory_type) or_return
	return create_buffer_with_memory(encoder, device, ids.readback_buffer, setup.buffer_memories[2], readback_bytes_of(target), {.Transfer_Destination}, setup.host_visible_memory_type)
}

// encode_draw_table_venus_objects writes the commands that create the
// objects of a draw table target: the color image, its memory and its view,
// the render pass, the framebuffer, the two shader modules, the pipeline
// layout with the push constants of the surface size, the 2D pipeline, and
// the vertex, the index and the readback buffers with their memory. A
// refused object leaves no byte of the earlier ones.
encode_draw_table_venus_objects :: proc "contextless" (encoder: ^Encoder, target: Draw_Table_Venus_Target, setup: Draw_Table_Venus_Setup) -> Venus_Problem {
	if setup.device == 0 {
		return .Zero_Object_Id
	}
	ids := target_check(target) or_return
	if setup.image_memory_bytes < readback_bytes_of(target) {
		return .Gpu_Buffer_Too_Small
	}
	mark := encoder.used_bytes
	count := encoder.command_count
	if problem := write_objects(encoder, target, setup, ids); problem != .None {
		encoder.used_bytes = mark
		encoder.command_count = count
		return problem
	}
	return .None
}

@(private = "file")
Frame :: struct {
	target:       Draw_Table_Venus_Target,
	ids:          Draw_Table_Objects,
	stream:       webgpu_subset.Gpu_Command_Stream,
	resources:    webgpu_subset.Resource_Registry,
	vertex_bytes: []u8,
	index_bytes:  []u8,
}

// upload writes the bytes into a buffer with one vkCmdUpdateBuffer for each
// 65536 bytes.
@(private = "file")
upload :: proc "contextless" (encoder: ^Encoder, command_buffer, buffer: Object_Id, bytes: []u8) -> Venus_Problem {
	for offset := 0; offset < len(bytes); offset += MAX_UPDATE_BUFFER_BYTES {
		chunk := bytes[offset:][:min(MAX_UPDATE_BUFFER_BYTES, len(bytes) - offset)]
		encode_cmd_update_buffer(encoder, command_buffer, buffer, u64(offset), chunk) or_return
	}
	return .None
}

@(private = "file")
record_frame :: proc "contextless" (encoder: ^Encoder, frame: ^Frame) -> Venus_Problem {
	target := frame.target
	objects := target.objects
	command_buffer := objects.command_buffer
	width := target.surface_width
	height := target.surface_height
	color_range := Image_Subresource_Range{aspects = {.Color}, level_count = 1, layer_count = 1}
	encode_begin_command_buffer(encoder, command_buffer, {.One_Time_Submit}) or_return
	upload(encoder, command_buffer, frame.ids.vertex_buffer, frame.vertex_bytes) or_return
	upload(encoder, command_buffer, frame.ids.index_buffer, frame.index_bytes) or_return

	// The image goes to COLOR_ATTACHMENT_OPTIMAL: from UNDEFINED when the
	// frame clears it, which drops the old contents with no copy; from the
	// layout of the last readback when the frame keeps them. The uploads
	// become visible to the vertex input in the same barrier.
	uploaded := len(frame.vertex_bytes) > 0
	keep := target.load_op == .Load
	to_attachment := [1]Image_Memory_Barrier{{
		destination_access = {.Color_Attachment_Write},
		old_layout         = .Undefined,
		new_layout         = .Color_Attachment_Optimal,
		image              = frame.ids.image,
		range              = color_range,
	}}
	source_stages := Pipeline_Stages{.Top_Of_Pipe}
	destination_stages := Pipeline_Stages{.Color_Attachment_Output}
	if keep {
		to_attachment[0].source_access = {.Transfer_Read}
		to_attachment[0].destination_access = {.Color_Attachment_Read, .Color_Attachment_Write}
		to_attachment[0].old_layout = .Transfer_Source_Optimal
		source_stages = {.Transfer}
	}
	uploads := [1]Memory_Barrier{{source_access = {.Transfer_Write}, destination_access = {.Vertex_Attribute_Read, .Index_Read}}}
	memory_barriers := uploads[:0]
	if uploaded {
		memory_barriers = uploads[:]
		source_stages = {.Transfer}
		destination_stages += {.Vertex_Input}
	}
	encode_cmd_pipeline_barrier(encoder, command_buffer, source_stages, destination_stages, memory_barriers, to_attachment[:]) or_return

	encode_cmd_set_viewport(encoder, command_buffer, {width = f32(width), height = f32(height), max_depth = 1}) or_return
	push: [DRAW_TABLE_PUSH_CONSTANT_BYTES]u8
	byte_order.write_u32_little_endian(push[:], 0, transmute(u32)f32(width))
	byte_order.write_u32_little_endian(push[:], 4, transmute(u32)f32(height))
	encode_cmd_push_constants(encoder, command_buffer, objects.pipeline_layout, {.Vertex}, 0, push[:]) or_return

	record_webgpu_commands(encoder, frame.stream, frame.resources, objects) or_return

	// The readback: the image becomes a source of transfer, its pixels go to
	// the readback buffer, and the host reads them after the fence.
	to_transfer := [1]Image_Memory_Barrier{{
		source_access      = {.Color_Attachment_Write},
		destination_access = {.Transfer_Read},
		old_layout         = .Color_Attachment_Optimal,
		new_layout         = .Transfer_Source_Optimal,
		image              = frame.ids.image,
		range              = color_range,
	}}
	encode_cmd_pipeline_barrier(encoder, command_buffer, {.Color_Attachment_Output}, {.Transfer}, nil, to_transfer[:]) or_return
	region := Buffer_Image_Copy {
		buffer_row_length = width,
		aspects           = {.Color},
		layer_count       = 1,
		width             = width,
		height            = height,
		depth             = 1,
	}
	encode_cmd_copy_image_to_buffer(encoder, command_buffer, frame.ids.image, .Transfer_Source_Optimal, frame.ids.readback_buffer, region) or_return
	to_host := [1]Memory_Barrier{{source_access = {.Transfer_Write}, destination_access = {.Host_Read}}}
	encode_cmd_pipeline_barrier(encoder, command_buffer, {.Transfer}, {.Host}, to_host[:], nil) or_return

	encode_end_command_buffer(encoder, command_buffer) or_return
	submitted := [1]Object_Id{command_buffer}
	return encode_queue_submit(encoder, objects.queue, submitted[:], objects.fence)
}

// draw_table_to_venus translates a draw table into the Venus stream of one
// frame on the GPU: vkBeginCommandBuffer, the upload of the vertices and the
// indices, the barrier to COLOR_ATTACHMENT_OPTIMAL, the viewport and the
// push constants, the render pass with its pipeline, scissors and draws, the
// barrier to TRANSFER_SRC_OPTIMAL, vkCmdCopyImageToBuffer into the readback
// buffer, the barrier to the host, vkEndCommandBuffer and vkQueueSubmit.
//
// scratch holds the WebGPU commands, the vertices and the indices of the
// translation. A refused table, target or size writes no byte of
// destination: the stream is measured before it is written. draw_problem
// says why the draw table was refused when problem is Draw_Table_Refused.
draw_table_to_venus :: proc "contextless" (
	records: []draw_record.Draw_Record,
	text_bytes: []u8,
	target: Draw_Table_Venus_Target,
	scratch: []u8,
	destination: []u8,
) -> (result: Draw_Table_Venus_Result, draw_problem: webgpu_subset.Draw_Table_Translation_Problem, problem: Venus_Problem) {
	ids, target_problem := target_check(target)
	if target_problem != .None {
		return {}, .None, target_problem
	}
	texture_format, _ := texture_format_of(target.format)

	// The scratch is cut in three: an eighth for the WebGPU commands, then
	// the vertices and the indices in the ratio of a quad (128 bytes of
	// vertices for 24 bytes of indices).
	command_bytes := len(scratch) / 8 / webgpu_subset.COMMAND_RECORD_SIZE * webgpu_subset.COMMAND_RECORD_SIZE
	rest := len(scratch) - command_bytes
	vertex_bytes := rest / 19 * 16 / int(webgpu_subset.VERTEX_2D_STRIDE) * int(webgpu_subset.VERTEX_2D_STRIDE)
	index_bytes := (rest - vertex_bytes) / 4 * 4
	command_storage := scratch[:command_bytes]
	vertex_storage := scratch[command_bytes:][:vertex_bytes]
	index_storage := scratch[command_bytes + vertex_bytes:][:index_bytes]

	config := webgpu_subset.Draw_Table_Translate_Config {
		surface_width    = target.surface_width,
		surface_height   = target.surface_height,
		color_texture_id = DRAW_TABLE_COLOR_TEXTURE,
		pipeline_id      = DRAW_TABLE_PIPELINE,
		vertex_buffer_id = DRAW_TABLE_VERTEX_BUFFER,
		index_buffer_id  = DRAW_TABLE_INDEX_BUFFER,
		load_op          = target.load_op,
		clear_color      = target.clear_color,
		has_damage_rect  = target.has_damage_rect,
		damage_rect      = target.damage_rect,
	}
	translation, translation_problem := webgpu_subset.draw_table_translate_to_webgpu(records, text_bytes, config, command_storage, vertex_storage, index_storage)
	if translation_problem != .None {
		return {}, translation_problem, .Draw_Table_Refused
	}
	if u64(translation.vertex_bytes_used) > target.vertex_buffer_bytes || u64(translation.index_bytes_used) > target.index_buffer_bytes {
		return {}, .None, .Gpu_Buffer_Too_Small
	}

	buffers := [3]webgpu_subset.Buffer_Desc {
		{size = target.vertex_buffer_bytes, usage = {.Vertex, .Copy_Dst}},
		{size = target.index_buffer_bytes, usage = {.Index, .Copy_Dst}},
		{size = readback_bytes_of(target), usage = {.Copy_Dst}},
	}
	textures := [1]webgpu_subset.Texture_Desc{{width = target.surface_width, height = target.surface_height, format = texture_format, usage = {.Render_Attachment, .Copy_Src}}}
	pipelines := [1]webgpu_subset.Pipeline_Desc {
		{topology = .Triangle_List, color_format = texture_format, src_blend = .Src_Alpha, dst_blend = .One_Minus_Src_Alpha, vertex_stride = webgpu_subset.VERTEX_2D_STRIDE},
	}
	frame := Frame {
		target       = target,
		ids          = ids,
		stream       = translation.stream,
		resources    = {buffers = buffers[:], textures = textures[:], pipelines = pipelines[:]},
		vertex_bytes = vertex_storage[:translation.vertex_bytes_used],
		index_bytes  = index_storage[:translation.index_bytes_used],
	}
	if _, refusal := webgpu_subset.stream_validate(frame.stream, frame.resources); refusal != .None {
		return {}, .None, .Webgpu_Stream_Invalid
	}

	measure := encoder_measure()
	if measure_problem := record_frame(&measure, &frame); measure_problem != .None {
		return {}, .None, measure_problem
	}
	if measure.used_bytes > virtio_gpu.MAX_SUBMIT_3D_BYTES {
		return {}, .None, .Stream_Too_Large
	}
	if len(destination) < measure.used_bytes {
		return {}, .None, .Buffer_Too_Short
	}
	encoder := encoder_init(destination[:measure.used_bytes])
	if write_problem := record_frame(&encoder, &frame); write_problem != .None {
		return {}, .None, write_problem
	}
	return Draw_Table_Venus_Result{written = encoder.used_bytes, venus_command_count = encoder.command_count, translation = translation}, .None, .None
}
