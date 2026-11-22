package venus_vulkan

import "modus:contract/byte_order"
import "modus:contract/virtio_gpu"
import "modus:contract/webgpu_subset"

// The GPU back end of the WebGPU subset: a validated webgpu_subset command
// stream becomes the Venus commands that record and submit one command
// buffer (src/md/features/gpu_access.md, "The WebGPU of the system"). The
// objects of the stream (buffers, textures, pipelines, bind groups) are
// numbered from 1; each becomes the object id of its base plus its number.

// The object ids that a translation uses. The command buffer and the queue
// exist already; a base is the id of object 0 of its kind.
Translation_Objects :: struct {
	command_buffer:      Object_Id,
	queue:               Object_Id,
	fence:               Object_Id, // 0: no fence
	pipeline_layout:     Object_Id,
	render_pass_base:    Object_Id,
	framebuffer_base:    Object_Id,
	buffer_base:         Object_Id,
	image_base:          Object_Id,
	pipeline_base:       Object_Id,
	descriptor_set_base: Object_Id,
}

// The depth that a render pass with a depth texture clears to.
CLEAR_DEPTH :: f32(1)

@(private)
object_of :: proc "contextless" (base: Object_Id, number: u32) -> (id: Object_Id, problem: Venus_Problem) {
	if number == 0 {
		return 0, .Zero_Object_Id
	}
	if u64(base) > max(u64) - u64(number) {
		return 0, .Object_Id_Overflow
	}
	return base + Object_Id(number), .None
}

// buffer_usage_of_webgpu gives the Vulkan usage of a WebGPU buffer usage.
buffer_usage_of_webgpu :: proc "contextless" (usage: webgpu_subset.Buffer_Usage) -> Buffer_Usage {
	result: Buffer_Usage
	for flag in usage {
		switch flag {
		case .Vertex:
			result += {.Vertex_Buffer}
		case .Index:
			result += {.Index_Buffer}
		case .Uniform:
			result += {.Uniform_Buffer}
		case .Storage:
			result += {.Storage_Buffer}
		case .Copy_Src:
			result += {.Transfer_Source}
		case .Copy_Dst:
			result += {.Transfer_Destination}
		}
	}
	return result
}

// encode_webgpu_buffers writes vkCreateBuffer for each buffer of resources.
// Buffer n gets the id buffer_base + n.
encode_webgpu_buffers :: proc "contextless" (encoder: ^Encoder, resources: webgpu_subset.Resource_Registry, device, buffer_base: Object_Id) -> Venus_Problem {
	if device == 0 {
		return .Zero_Object_Id
	}
	mark := encoder.used_bytes
	count := encoder.command_count
	for buffer, index in resources.buffers {
		id, id_problem := object_of(buffer_base, u32(index + 1))
		problem := id_problem
		if problem == .None {
			problem = encode_create_buffer(encoder, device, id, buffer.size, buffer_usage_of_webgpu(buffer.usage))
		}
		if problem != .None {
			encoder.used_bytes = mark
			encoder.command_count = count
			return problem
		}
	}
	return .None
}

@(private = "file")
translate :: proc "contextless" (encoder: ^Encoder, stream: webgpu_subset.Gpu_Command_Stream, resources: webgpu_subset.Resource_Registry, objects: Translation_Objects) -> Venus_Problem {
	command_buffer := objects.command_buffer
	encode_begin_command_buffer(encoder, command_buffer, {.One_Time_Submit}) or_return
	record_webgpu_commands(encoder, stream, resources, objects) or_return
	encode_end_command_buffer(encoder, command_buffer) or_return
	submitted := [1]Object_Id{command_buffer}
	return encode_queue_submit(encoder, objects.queue, submitted[:], objects.fence)
}

// record_webgpu_commands writes one Venus command for each record of a
// validated stream, into the command buffer of objects.
@(private)
record_webgpu_commands :: proc "contextless" (encoder: ^Encoder, stream: webgpu_subset.Gpu_Command_Stream, resources: webgpu_subset.Resource_Registry, objects: Translation_Objects) -> Venus_Problem {
	command_buffer := objects.command_buffer
	record_count := len(stream.bytes) / webgpu_subset.COMMAND_RECORD_SIZE
	for index in 0 ..< record_count {
		record := stream.bytes[index * webgpu_subset.COMMAND_RECORD_SIZE:][:webgpu_subset.COMMAND_RECORD_SIZE]
		kind, kind_ok := webgpu_subset.gpu_command_kind_of_word(byte_order.read_u32_little_endian(record, 0))
		if !kind_ok {
			return .Webgpu_Stream_Invalid
		}
		switch kind {
		case .None:
			return .Webgpu_Stream_Invalid

		case .Begin_Render_Pass:
			color_texture := byte_order.read_u32_little_endian(record, 8)
			depth_texture := byte_order.read_u32_little_endian(record, 12)
			if color_texture == 0 || int(color_texture) > len(resources.textures) {
				return .Webgpu_Stream_Invalid
			}
			extent := resources.textures[color_texture - 1]
			render_pass := object_of(objects.render_pass_base, color_texture) or_return
			framebuffer := object_of(objects.framebuffer_base, color_texture) or_return
			clear_values: [2]Clear_Value
			clear_values[0] = [4]u32{
				byte_order.read_u32_little_endian(record, 24),
				byte_order.read_u32_little_endian(record, 28),
				byte_order.read_u32_little_endian(record, 32),
				byte_order.read_u32_little_endian(record, 36),
			}
			clear_count := 1
			if depth_texture != 0 {
				clear_values[1] = Clear_Depth_Stencil{depth = CLEAR_DEPTH}
				clear_count = 2
			}
			area := Rect_2D{width = extent.width, height = extent.height}
			encode_cmd_begin_render_pass(encoder, command_buffer, render_pass, framebuffer, area, clear_values[:clear_count]) or_return

		case .Set_Pipeline:
			pipeline := object_of(objects.pipeline_base, byte_order.read_u32_little_endian(record, 8)) or_return
			encode_cmd_bind_pipeline(encoder, command_buffer, .Graphics, pipeline) or_return

		case .Set_Vertex_Buffer:
			buffer := object_of(objects.buffer_base, byte_order.read_u32_little_endian(record, 12)) or_return
			encode_cmd_bind_vertex_buffers(encoder, command_buffer, byte_order.read_u32_little_endian(record, 8), buffer, byte_order.read_u64_little_endian(record, 16)) or_return

		case .Set_Index_Buffer:
			buffer := object_of(objects.buffer_base, byte_order.read_u32_little_endian(record, 8)) or_return
			format, format_ok := webgpu_subset.index_format_of_word(byte_order.read_u32_little_endian(record, 12))
			if !format_ok {
				return .Webgpu_Stream_Invalid
			}
			index_type: Index_Type
			switch format {
			case .None:
				return .Webgpu_Stream_Invalid
			case .Uint16:
				index_type = .Uint16
			case .Uint32:
				index_type = .Uint32
			}
			encode_cmd_bind_index_buffer(encoder, command_buffer, buffer, byte_order.read_u64_little_endian(record, 16), index_type) or_return

		case .Set_Bind_Group:
			descriptor_set := object_of(objects.descriptor_set_base, byte_order.read_u32_little_endian(record, 12)) or_return
			encode_cmd_bind_descriptor_sets(encoder, command_buffer, .Graphics, objects.pipeline_layout, byte_order.read_u32_little_endian(record, 8), descriptor_set) or_return

		case .Set_Scissor_Rect:
			x := byte_order.read_u32_little_endian(record, 8)
			y := byte_order.read_u32_little_endian(record, 12)
			if x > u32(max(i32)) || y > u32(max(i32)) {
				return .Dimension_Too_Large
			}
			scissor := Rect_2D{x = i32(x), y = i32(y), width = byte_order.read_u32_little_endian(record, 16), height = byte_order.read_u32_little_endian(record, 20)}
			encode_cmd_set_scissor(encoder, command_buffer, scissor) or_return

		case .Draw:
			encode_cmd_draw(
				encoder,
				command_buffer,
				byte_order.read_u32_little_endian(record, 8),
				byte_order.read_u32_little_endian(record, 12),
				byte_order.read_u32_little_endian(record, 16),
				byte_order.read_u32_little_endian(record, 20),
			) or_return

		case .Draw_Indexed:
			encode_cmd_draw_indexed(
				encoder,
				command_buffer,
				byte_order.read_u32_little_endian(record, 8),
				byte_order.read_u32_little_endian(record, 12),
				byte_order.read_u32_little_endian(record, 16),
				i32(byte_order.read_u32_little_endian(record, 20)),
				byte_order.read_u32_little_endian(record, 24),
			) or_return

		case .End_Render_Pass:
			encode_cmd_end_render_pass(encoder, command_buffer) or_return

		case .Copy_Buffer_To_Buffer:
			source := object_of(objects.buffer_base, byte_order.read_u32_little_endian(record, 8)) or_return
			destination := object_of(objects.buffer_base, byte_order.read_u32_little_endian(record, 12)) or_return
			region := [1]Buffer_Copy{{
				source_offset      = byte_order.read_u64_little_endian(record, 16),
				destination_offset = byte_order.read_u64_little_endian(record, 24),
				size               = byte_order.read_u64_little_endian(record, 32),
			}}
			encode_cmd_copy_buffer(encoder, command_buffer, source, destination, region[:]) or_return

		case .Copy_Buffer_To_Texture:
			texture := byte_order.read_u32_little_endian(record, 12)
			if texture == 0 || int(texture) > len(resources.textures) {
				return .Webgpu_Stream_Invalid
			}
			source := object_of(objects.buffer_base, byte_order.read_u32_little_endian(record, 8)) or_return
			destination := object_of(objects.image_base, texture) or_return
			// Vulkan counts a row in texels, WebGPU in bytes.
			bytes_per_texel := webgpu_subset.texture_format_bytes_per_pixel(resources.textures[texture - 1].format)
			bytes_per_row := byte_order.read_u32_little_endian(record, 24)
			if bytes_per_texel == 0 || bytes_per_row % bytes_per_texel != 0 {
				return .Webgpu_Stream_Invalid
			}
			dst_x := byte_order.read_u32_little_endian(record, 28)
			dst_y := byte_order.read_u32_little_endian(record, 32)
			if dst_x > u32(max(i32)) || dst_y > u32(max(i32)) {
				return .Dimension_Too_Large
			}
			region := Buffer_Image_Copy{
				buffer_offset     = byte_order.read_u64_little_endian(record, 16),
				buffer_row_length = bytes_per_row / bytes_per_texel,
				aspects           = {.Color},
				layer_count       = 1,
				image_x           = i32(dst_x),
				image_y           = i32(dst_y),
				width             = byte_order.read_u32_little_endian(record, 36),
				height            = byte_order.read_u32_little_endian(record, 40),
				depth             = 1,
			}
			encode_cmd_copy_buffer_to_image(encoder, command_buffer, source, destination, .Transfer_Destination_Optimal, region) or_return
		}
	}
	return .None
}

// webgpu_stream_to_venus validates stream against resources, then writes
// vkBeginCommandBuffer, one Venus command for each record,
// vkEndCommandBuffer and vkQueueSubmit. It measures first, so destination is
// untouched when the stream is refused or does not fit.
webgpu_stream_to_venus :: proc "contextless" (
	stream: webgpu_subset.Gpu_Command_Stream,
	resources: webgpu_subset.Resource_Registry,
	objects: Translation_Objects,
	destination: []u8,
) -> (written: int, problem: Venus_Problem) {
	if objects.command_buffer == 0 || objects.queue == 0 {
		return 0, .Zero_Object_Id
	}
	if _, refusal := webgpu_subset.stream_validate(stream, resources); refusal != .None {
		return 0, .Webgpu_Stream_Invalid
	}
	measure := encoder_measure()
	translate(&measure, stream, resources, objects) or_return
	if measure.used_bytes > virtio_gpu.MAX_SUBMIT_3D_BYTES {
		return 0, .Stream_Too_Large
	}
	if len(destination) < measure.used_bytes {
		return 0, .Buffer_Too_Short
	}
	encoder := encoder_init(destination[:measure.used_bytes])
	translate(&encoder, stream, resources, objects) or_return
	return encoder.used_bytes, .None
}

// webgpu_stream_to_submit_3d translates stream in place after a Submit_3D
// header, and returns the whole control queue packet.
webgpu_stream_to_submit_3d :: proc "contextless" (
	ctx_id: u32,
	stream: webgpu_subset.Gpu_Command_Stream,
	resources: webgpu_subset.Resource_Registry,
	objects: Translation_Objects,
	destination: []u8,
	virtio_fence_id: u64 = 0,
) -> (written: int, problem: Venus_Problem) {
	if ctx_id == 0 {
		return 0, .Zero_Object_Id
	}
	if len(destination) < virtio_gpu.SUBMIT_3D_HEADER_SIZE {
		return 0, .Buffer_Too_Short
	}
	venus_bytes := webgpu_stream_to_venus(stream, resources, objects, destination[virtio_gpu.SUBMIT_3D_HEADER_SIZE:]) or_return
	if _, frame_problem := virtio_gpu.submit_3d_header_encode(ctx_id, venus_bytes, destination, virtio_fence_id); frame_problem != .None {
		return 0, .Virtio_Frame_Invalid
	}
	return virtio_gpu.SUBMIT_3D_HEADER_SIZE + venus_bytes, .None
}
