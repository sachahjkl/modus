#+build !freestanding
#+build !modus
package venus_vulkan

import "core:testing"
import "modus:contract/virtio_gpu"
import "modus:contract/webgpu_subset"

@(private = "file")
Fixture :: struct {
	buffers:   [3]webgpu_subset.Buffer_Desc,
	textures:  [2]webgpu_subset.Texture_Desc,
	pipelines: [1]webgpu_subset.Pipeline_Desc,
	records:   [webgpu_subset.COMMAND_RECORD_SIZE * 16]u8,
}

@(private = "file")
fixture_make :: proc(fixture: ^Fixture) -> (stream: webgpu_subset.Gpu_Command_Stream, resources: webgpu_subset.Resource_Registry) {
	fixture.buffers = {
		{size = 1024, usage = {.Vertex, .Copy_Dst}},
		{size = 256, usage = {.Index, .Copy_Dst}},
		{size = 4096, usage = {.Copy_Src}},
	}
	fixture.textures = {
		{width = 640, height = 480, format = .RGBA8_Unorm, usage = {.Render_Attachment, .Copy_Dst}},
		{width = 640, height = 480, format = .Depth24_Plus, usage = {.Render_Attachment}},
	}
	fixture.pipelines = {
		{topology = .Triangle_List, color_format = .RGBA8_Unorm, src_blend = .Src_Alpha, dst_blend = .One_Minus_Src_Alpha, vertex_stride = 32},
	}
	resources = webgpu_subset.Resource_Registry{
		buffers          = fixture.buffers[:],
		textures         = fixture.textures[:],
		pipelines        = fixture.pipelines[:],
		bind_group_count = 1,
	}
	encoder := webgpu_subset.encoder_init(fixture.records[:])
	_ = webgpu_subset.encode_copy_buffer_to_buffer(&encoder, 3, 1, 0, 0, 512)
	_ = webgpu_subset.encode_copy_buffer_to_texture(&encoder, 3, 1, 0, 256, 0, 0, 64, 4)
	_ = webgpu_subset.encode_begin_render_pass(&encoder, 1, 2, .Clear, .Store, webgpu_subset.Clear_Color{r_bits = 0x3F00_0000, a_bits = 0x3F80_0000})
	_ = webgpu_subset.encode_set_pipeline(&encoder, 1)
	_ = webgpu_subset.encode_set_vertex_buffer(&encoder, 0, 1, 64, 512)
	_ = webgpu_subset.encode_set_index_buffer(&encoder, 2, .Uint32, 0, 128)
	_ = webgpu_subset.encode_set_bind_group(&encoder, 0, 1)
	_ = webgpu_subset.encode_set_scissor_rect(&encoder, 16, 16, 320, 240)
	_ = webgpu_subset.encode_draw(&encoder, 6, 1, 0, 0)
	_ = webgpu_subset.encode_draw_indexed(&encoder, 12, 1, 0, -3, 0)
	_ = webgpu_subset.encode_end_render_pass(&encoder)
	return webgpu_subset.encoder_finish(&encoder), resources
}

@(private = "file")
OBJECTS :: Translation_Objects{
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
}

@(test)
webgpu_stream_becomes_the_exact_venus_sequence :: proc(t: ^testing.T) {
	fixture: Fixture
	stream, resources := fixture_make(&fixture)
	testing.expect_value(t, len(stream.bytes), 11 * webgpu_subset.COMMAND_RECORD_SIZE)
	_, webgpu_refusal := webgpu_subset.stream_validate(stream, resources)
	testing.expect_value(t, webgpu_refusal, webgpu_subset.Gpu_Refusal.None)

	destination: [4096]u8
	written, problem := webgpu_stream_to_venus(stream, resources, OBJECTS, destination[:])
	testing.expect_value(t, problem, Venus_Problem.None)

	expected := [?]Command_Type{
		.Begin_Command_Buffer, .Cmd_Copy_Buffer, .Cmd_Copy_Buffer_To_Image, .Cmd_Begin_Render_Pass, .Cmd_Bind_Pipeline,
		.Cmd_Bind_Vertex_Buffers, .Cmd_Bind_Index_Buffer, .Cmd_Bind_Descriptor_Sets, .Cmd_Set_Scissor, .Cmd_Draw,
		.Cmd_Draw_Indexed, .Cmd_End_Render_Pass, .End_Command_Buffer, .Queue_Submit,
	}
	decoder := decoder_init(destination[:written])
	commands: [len(expected)]Decoded_Command
	for want, index in expected {
		command, decode_problem := command_decode_next(&decoder)
		testing.expect_value(t, decode_problem, Venus_Problem.None)
		testing.expect_value(t, command.command_type, want)
		// Recording commands ask no reply; the renderer runs them in order.
		testing.expect_value(t, command.flags, Command_Flags{})
		testing.expect_value(t, command.objects[0], index == len(expected) - 1 ? Object_Id(200) : Object_Id(100))
		commands[index] = command
	}
	testing.expect(t, decoder_done(&decoder), "the translation must hold only the expected commands")

	// vkCmdCopyBuffer: buffer 3 to buffer 1, 512 bytes.
	testing.expect_value(t, commands[1].objects[1], Object_Id(3003))
	testing.expect_value(t, commands[1].objects[2], Object_Id(3001))
	testing.expect_value(t, commands[1].values[2], u64(512))
	// vkCmdCopyBufferToImage: 256 bytes a row of RGBA8 is 64 texels.
	testing.expect_value(t, commands[2].objects[2], Object_Id(4001))
	testing.expect_value(t, commands[2].values[0], u64(Image_Layout.Transfer_Destination_Optimal))
	testing.expect_value(t, commands[2].values[2], u64(64))
	testing.expect_value(t, commands[2].values[11], u64(64))
	testing.expect_value(t, commands[2].values[12], u64(4))
	// vkCmdBeginRenderPass: the pass and the framebuffer of texture 1, the
	// whole texture, the clear color bits, then the depth clear.
	testing.expect_value(t, commands[3].objects[1], Object_Id(1001))
	testing.expect_value(t, commands[3].objects[2], Object_Id(2001))
	testing.expect_value(t, commands[3].values[2], u64(640))
	testing.expect_value(t, commands[3].values[3], u64(480))
	testing.expect_value(t, commands[3].values[4], u64(Clear_Value_Tag.Color))
	testing.expect_value(t, commands[3].values[5], u64(0x3F00_0000))
	testing.expect_value(t, commands[3].values[8], u64(0x3F80_0000))
	testing.expect_value(t, commands[3].values[9], u64(Clear_Value_Tag.Depth_Stencil))
	testing.expect_value(t, commands[3].values[10], u64(0x3F80_0000))
	// The pipeline, the vertex buffer at 64, the index type, the bind group.
	testing.expect_value(t, commands[4].objects[1], Object_Id(5001))
	testing.expect_value(t, commands[5].objects[1], Object_Id(3001))
	testing.expect_value(t, commands[5].values[1], u64(64))
	testing.expect_value(t, commands[6].objects[1], Object_Id(3002))
	testing.expect_value(t, commands[6].values[1], u64(Index_Type.Uint32))
	testing.expect_value(t, commands[7].objects[1], Object_Id(400))
	testing.expect_value(t, commands[7].objects[2], Object_Id(6001))
	// The scissor, the draws with the negative base vertex.
	testing.expect_value(t, commands[8].values[1], u64(16))
	testing.expect_value(t, commands[8].values[3], u64(320))
	testing.expect_value(t, commands[9].values[0], u64(6))
	testing.expect_value(t, i64(commands[10].values[3]), i64(-3))
	// vkQueueSubmit: queue, the command buffer, the fence.
	testing.expect_value(t, commands[13].objects[1], Object_Id(100))
	testing.expect_value(t, commands[13].objects[2], Object_Id(300))

	// The Submit_3D packet frames the same bytes after its 32-byte header.
	packet: [4096]u8
	packet_bytes, packet_problem := webgpu_stream_to_submit_3d(7, stream, resources, OBJECTS, packet[:], 99)
	testing.expect_value(t, packet_problem, Venus_Problem.None)
	testing.expect_value(t, packet_bytes, virtio_gpu.SUBMIT_3D_HEADER_SIZE + written)
	frame, frame_problem := virtio_gpu.submit_3d_decode(packet[:packet_bytes])
	testing.expect_value(t, frame_problem, virtio_gpu.Validation_Problem.None)
	testing.expect_value(t, frame.header.ctx_id, u32(7))
	testing.expect_value(t, frame.header.fence_id, u64(99))
	testing.expect(t, string(frame.payload) == string(destination[:written]), "the packet must carry the translated stream")
}

@(test)
webgpu_translation_refusals_leave_the_destination_untouched :: proc(t: ^testing.T) {
	fixture: Fixture
	stream, resources := fixture_make(&fixture)
	destination: [4096]u8
	for &byte_value in destination {
		byte_value = 0xAA
	}
	untouched :: proc(t: ^testing.T, destination: []u8, loc := #caller_location) {
		for byte_value in destination {
			if byte_value != 0xAA {
				testing.expect(t, false, "a refused translation must not write", loc = loc)
				return
			}
		}
	}

	objects := OBJECTS
	objects.command_buffer = 0
	written, problem := webgpu_stream_to_venus(stream, resources, objects, destination[:])
	testing.expect_value(t, problem, Venus_Problem.Zero_Object_Id)
	testing.expect_value(t, written, 0)
	objects = OBJECTS
	objects.queue = 0
	_, problem = webgpu_stream_to_venus(stream, resources, objects, destination[:])
	testing.expect_value(t, problem, Venus_Problem.Zero_Object_Id)

	// A base so high that the id of object 1 overflows.
	objects = OBJECTS
	objects.pipeline_base = Object_Id(max(u64))
	_, problem = webgpu_stream_to_venus(stream, resources, objects, destination[:])
	testing.expect_value(t, problem, Venus_Problem.Object_Id_Overflow)
	// A bind group with no pipeline layout.
	objects = OBJECTS
	objects.pipeline_layout = 0
	_, problem = webgpu_stream_to_venus(stream, resources, objects, destination[:])
	testing.expect_value(t, problem, Venus_Problem.Zero_Object_Id)

	cut := webgpu_subset.Gpu_Command_Stream{bytes = stream.bytes[:len(stream.bytes) - 1]}
	_, problem = webgpu_stream_to_venus(cut, resources, OBJECTS, destination[:])
	testing.expect_value(t, problem, Venus_Problem.Webgpu_Stream_Invalid)
	unbalanced := webgpu_subset.Gpu_Command_Stream{bytes = stream.bytes[:len(stream.bytes) - webgpu_subset.COMMAND_RECORD_SIZE]}
	_, problem = webgpu_stream_to_venus(unbalanced, resources, OBJECTS, destination[:])
	testing.expect_value(t, problem, Venus_Problem.Webgpu_Stream_Invalid)

	needed, _ := webgpu_stream_to_venus(stream, resources, OBJECTS, destination[:])
	for &byte_value in destination {
		byte_value = 0xAA
	}
	_, problem = webgpu_stream_to_venus(stream, resources, OBJECTS, destination[:needed - 4])
	testing.expect_value(t, problem, Venus_Problem.Buffer_Too_Short)
	untouched(t, destination[:])

	_, problem = webgpu_stream_to_submit_3d(0, stream, resources, OBJECTS, destination[:])
	testing.expect_value(t, problem, Venus_Problem.Zero_Object_Id)
	_, problem = webgpu_stream_to_submit_3d(7, stream, resources, OBJECTS, destination[:virtio_gpu.SUBMIT_3D_HEADER_SIZE - 1])
	testing.expect_value(t, problem, Venus_Problem.Buffer_Too_Short)
	_, problem = webgpu_stream_to_submit_3d(7, stream, resources, OBJECTS, destination[:virtio_gpu.SUBMIT_3D_HEADER_SIZE + needed - 4])
	testing.expect_value(t, problem, Venus_Problem.Buffer_Too_Short)
	untouched(t, destination[:])

	// An empty stream records an empty command buffer: begin, end, submit.
	written, problem = webgpu_stream_to_venus({}, resources, OBJECTS, destination[:])
	testing.expect_value(t, problem, Venus_Problem.None)
	count, validate_problem := stream_validate(destination[:written])
	testing.expect_value(t, validate_problem, Venus_Problem.None)
	testing.expect_value(t, count, 3)
}

@(test)
webgpu_buffers_become_vulkan_buffers :: proc(t: ^testing.T) {
	testing.expect_value(t, buffer_usage_of_webgpu({.Vertex, .Copy_Dst}), Buffer_Usage{.Vertex_Buffer, .Transfer_Destination})
	testing.expect_value(t, buffer_usage_of_webgpu({.Index, .Uniform, .Storage, .Copy_Src}), Buffer_Usage{.Index_Buffer, .Uniform_Buffer, .Storage_Buffer, .Transfer_Source})
	testing.expect_value(t, buffer_usage_of_webgpu({}), Buffer_Usage{})

	fixture: Fixture
	_, resources := fixture_make(&fixture)
	storage: [1024]u8
	encoder := encoder_init(storage[:])
	testing.expect_value(t, encode_webgpu_buffers(&encoder, resources, 3, 3000), Venus_Problem.None)
	testing.expect_value(t, encoder.command_count, u32(3))
	decoder := decoder_init(encoder_bytes(&encoder))
	for index in 0 ..< 3 {
		command, problem := command_decode_next(&decoder)
		testing.expect_value(t, problem, Venus_Problem.None)
		testing.expect_value(t, command.command_type, Command_Type.Create_Buffer)
		testing.expect_value(t, command.objects[1], Object_Id(3001 + index))
		testing.expect_value(t, command.values[0], fixture.buffers[index].size)
	}

	// A buffer with no usage is refused, and the earlier buffers are removed.
	fixture.buffers[2].usage = {}
	encoder = encoder_init(storage[:])
	testing.expect_value(t, encode_webgpu_buffers(&encoder, resources, 3, 3000), Venus_Problem.Unknown_Flag_Bits)
	testing.expect_value(t, encoder.used_bytes, 0)
	testing.expect_value(t, encoder.command_count, u32(0))
	testing.expect_value(t, encode_webgpu_buffers(&encoder, resources, 0, 3000), Venus_Problem.Zero_Object_Id)
	fixture.buffers[2].usage = {.Copy_Src}
	testing.expect_value(t, encode_webgpu_buffers(&encoder, resources, 3, Object_Id(max(u64) - 1)), Venus_Problem.Object_Id_Overflow)
}
