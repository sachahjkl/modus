#+build !freestanding
#+build !modus
package webgpu_subset

import "core:testing"
import "modus:contract/byte_order"
import "modus:contract/draw_record"

@(test)
enum_and_usage_borders :: proc(t: ^testing.T) {
	// Unknown usage bits refused.
	for word in ([]u32{1 << 6, 1 << 31, max(u32)}) {
		_, ok := buffer_usage_of_word(word)
		testing.expect(t, !ok, "unknown buffer usage bit must be refused")
	}
	for word in ([]u32{1 << 5, 1 << 31, max(u32)}) {
		_, ok := texture_usage_of_word(word)
		testing.expect(t, !ok, "unknown texture usage bit must be refused")
	}

	// Zero (None) and out-of-range words refused for non-zero enums.
	for word in ([]u32{0, 6, max(u32)}) {
		_, ok := texture_format_of_word(word)
		testing.expect(t, !ok, "invalid texture format must be refused")
	}
	for word in ([]u32{0, 4, max(u32)}) {
		_, ok := primitive_topology_of_word(word)
		testing.expect(t, !ok, "invalid primitive topology must be refused")
	}
	for word in ([]u32{6, 100, max(u32)}) {
		_, ok := blend_factor_of_word(word)
		testing.expect(t, !ok, "invalid blend factor must be refused")
	}
	for word in ([]u32{0, 3, max(u32)}) {
		_, ok := load_op_of_word(word)
		testing.expect(t, !ok, "invalid load op must be refused")
	}
	for word in ([]u32{0, 3, max(u32)}) {
		_, ok := store_op_of_word(word)
		testing.expect(t, !ok, "invalid store op must be refused")
	}
	for word in ([]u32{0, 3, max(u32)}) {
		_, ok := index_format_of_word(word)
		testing.expect(t, !ok, "invalid index format must be refused")
	}
	for word in ([]u32{0, 12, max(u32)}) {
		_, ok := gpu_command_kind_of_word(word)
		testing.expect(t, !ok, "invalid command kind must be refused")
	}

	// All valid members decode cleanly.
	for member in Gpu_Command_Kind {
		if member == .None {
			continue
		}
		decoded, ok := gpu_command_kind_of_word(u32(member))
		testing.expect(t, ok, "known command kind must decode")
		testing.expect_value(t, decoded, member)
	}
}

@(test)
spirv_binary_border_refusals_and_valid :: proc(t: ^testing.T) {
	// Too short: 0, 1, 4 words.
	_, r0 := spirv_header_validate(nil)
	testing.expect_value(t, r0, Gpu_Refusal.Spirv_Too_Short)
	_, r1 := spirv_header_validate([]u32{SPIRV_MAGIC})
	testing.expect_value(t, r1, Gpu_Refusal.Spirv_Too_Short)
	_, r4 := spirv_header_validate([]u32{SPIRV_MAGIC, 0x0001_0000, 0, 1})
	testing.expect_value(t, r4, Gpu_Refusal.Spirv_Too_Short)

	// Header only with zero instructions.
	_, r_no_inst := spirv_header_validate([]u32{SPIRV_MAGIC, 0x0001_0000, 0, 4, 0})
	testing.expect_value(t, r_no_inst, Gpu_Refusal.Spirv_No_Instructions)

	// Wrong magic (0 and byte-swapped).
	_, r_magic0 := spirv_header_validate([]u32{0, 0x0001_0000, 0, 4, 0, (1 << 16) | 17})
	testing.expect_value(t, r_magic0, Gpu_Refusal.Spirv_Bad_Magic)
	_, r_magic_swap := spirv_header_validate([]u32{0x0302_2307, 0x0001_0000, 0, 4, 0, (1 << 16) | 17})
	testing.expect_value(t, r_magic_swap, Gpu_Refusal.Spirv_Bad_Magic)

	// Invalid version words: major 0, major 2, minor 7, high/low reserved bytes non-zero.
	for bad_ver in ([]u32{0x0000_0000, 0x0002_0000, 0x0001_0700, 0x0101_0000, 0x0001_0001}) {
		_, r_ver := spirv_header_validate([]u32{SPIRV_MAGIC, bad_ver, 0, 4, 0, (1 << 16) | 17})
		testing.expect_value(t, r_ver, Gpu_Refusal.Spirv_Bad_Version)
	}

	// Zero ID bound.
	_, r_bound := spirv_header_validate([]u32{SPIRV_MAGIC, 0x0001_0300, 0, 0, 0, (1 << 16) | 17})
	testing.expect_value(t, r_bound, Gpu_Refusal.Spirv_Zero_Bound)

	// Non-zero reserved instruction schema.
	_, r_schema := spirv_header_validate([]u32{SPIRV_MAGIC, 0x0001_0300, 0, 4, 1, (1 << 16) | 17})
	testing.expect_value(t, r_schema, Gpu_Refusal.Spirv_Non_Zero_Schema)

	// Zero word count in instruction header (must not infinite-loop).
	_, r_zero_wc := spirv_header_validate([]u32{SPIRV_MAGIC, 0x0001_0300, 0, 4, 0, 0x0000_0011})
	testing.expect_value(t, r_zero_wc, Gpu_Refusal.Spirv_Bad_Instruction_Word_Count)

	// Truncated instruction: claims 3 words, only 2 remain.
	_, r_trunc := spirv_header_validate([]u32{SPIRV_MAGIC, 0x0001_0300, 0, 4, 0, (3 << 16) | 14, 0})
	testing.expect_value(t, r_trunc, Gpu_Refusal.Spirv_Truncated_Instruction)

	// Truncated instruction with max word count (0xFFFF).
	_, r_max_wc := spirv_header_validate([]u32{SPIRV_MAGIC, 0x0001_0300, 0, 4, 0, (0xFFFF << 16) | 14})
	testing.expect_value(t, r_max_wc, Gpu_Refusal.Spirv_Truncated_Instruction)

	// Unaligned byte length.
	bad_bytes: [21]u8
	_, r_unaligned := spirv_bytes_validate(bad_bytes[:])
	testing.expect_value(t, r_unaligned, Gpu_Refusal.Spirv_Unaligned_Byte_Length)

	// Valid minimal SPIR-V 1.6 module (OpCapability Shader + OpMemoryModel Logical GLSL450).
	valid_words := [?]u32{
		SPIRV_MAGIC,
		0x0001_0600, // SPIR-V 1.6
		0x000D_0001, // generator
		12,          // ID bound
		0,           // schema
		(2 << 16) | 17, 1, // OpCapability Shader
		(3 << 16) | 14, 0, 1, // OpMemoryModel Logical GLSL450
	}
	info, ok_refusal := spirv_header_validate(valid_words[:])
	testing.expect_value(t, ok_refusal, Gpu_Refusal.None)
	testing.expect_value(t, info.version_major, u32(1))
	testing.expect_value(t, info.version_minor, u32(6))
	testing.expect_value(t, info.generator, u32(0x000D_0001))
	testing.expect_value(t, info.id_bound, u32(12))
	testing.expect_value(t, info.instruction_count, u32(2))

	// Same module encoded as little-endian bytes.
	valid_bytes: [len(valid_words) * 4]u8
	for word, idx in valid_words {
		byte_order.write_u32_little_endian(valid_bytes[:], idx * 4, word)
	}
	byte_info, byte_refusal := spirv_bytes_validate(valid_bytes[:])
	testing.expect_value(t, byte_refusal, Gpu_Refusal.None)
	testing.expect_value(t, byte_info, info)
}

@(private = "file")
test_resources :: proc() -> (buffers: [4]Buffer_Desc, textures: [3]Texture_Desc, pipelines: [2]Pipeline_Desc) {
	buffers = {
		0 = {size = 1024, usage = {.Vertex, .Copy_Dst}},
		1 = {size = 256, usage = {.Index, .Copy_Dst}},
		2 = {size = 4096, usage = {.Copy_Src}},
		3 = {size = 512, usage = {.Uniform}},
	}
	textures = {
		0 = {width = 1920, height = 1080, format = .BGRA8_Unorm, usage = {.Render_Attachment, .Copy_Dst}},
		1 = {width = 1920, height = 1080, format = .Depth24_Plus, usage = {.Render_Attachment}},
		2 = {width = 64, height = 64, format = .RGBA8_Unorm, usage = {.Texture_Binding, .Copy_Dst}},
	}
	pipelines = {
		0 = {topology = .Triangle_List, color_format = .BGRA8_Unorm, src_blend = .Src_Alpha, dst_blend = .One_Minus_Src_Alpha, vertex_stride = 32},
		1 = {topology = .Triangle_Strip, color_format = .RGBA8_Unorm, src_blend = .One, dst_blend = .Zero, vertex_stride = 0},
	}
	return buffers, textures, pipelines
}

@(test)
command_stream_render_pass_and_copy_rules :: proc(t: ^testing.T) {
	buffers, textures, pipelines := test_resources()
	reg := Resource_Registry{buffers = buffers[:], textures = textures[:], pipelines = pipelines[:], bind_group_count = 2}

	// Truncated stream (not a multiple of COMMAND_RECORD_SIZE).
	short_bytes: [COMMAND_RECORD_SIZE - 1]u8
	_, r_trunc := stream_validate(Gpu_Command_Stream{bytes = short_bytes[:]}, reg)
	testing.expect_value(t, r_trunc, Gpu_Refusal.Stream_Truncated)

	// Unknown command kind & non-zero reserved header word.
	raw_one: [COMMAND_RECORD_SIZE]u8
	byte_order.write_u32_little_endian(raw_one[:], 0, 999)
	_, r_unk := stream_validate(Gpu_Command_Stream{bytes = raw_one[:]}, reg)
	testing.expect_value(t, r_unk, Gpu_Refusal.Unknown_Command_Kind)

	byte_order.write_u32_little_endian(raw_one[:], 0, u32(Gpu_Command_Kind.End_Render_Pass))
	byte_order.write_u32_little_endian(raw_one[:], 4, 1)
	_, r_res := stream_validate(Gpu_Command_Stream{bytes = raw_one[:]}, reg)
	testing.expect_value(t, r_res, Gpu_Refusal.Non_Zero_Reserved)

	// Unbalanced Begin_Render_Pass without End_Render_Pass.
	buf: [COMMAND_RECORD_SIZE * 16]u8
	enc := encoder_init(buf[:])
	testing.expect_value(t, encode_begin_render_pass(&enc, 1, 0, .Clear, .Store), Gpu_Refusal.None)
	_, r_unbal := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, r_unbal, Gpu_Refusal.Unbalanced_Render_Pass)

	// Nested Begin_Render_Pass refused.
	testing.expect_value(t, encode_begin_render_pass(&enc, 1, 0, .Clear, .Store), Gpu_Refusal.None)
	_, r_nest := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, r_nest, Gpu_Refusal.Render_Pass_Already_Active)

	// End_Render_Pass outside render pass refused.
	enc = encoder_init(buf[:])
	testing.expect_value(t, encode_end_render_pass(&enc), Gpu_Refusal.None)
	_, r_end_out := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, r_end_out, Gpu_Refusal.Render_Pass_Not_Active)

	// Draw outside render pass refused.
	enc = encoder_init(buf[:])
	testing.expect_value(t, encode_draw(&enc, 3, 1, 0, 0), Gpu_Refusal.None)
	_, r_draw_out := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, r_draw_out, Gpu_Refusal.Render_Pass_Not_Active)

	// Copy_Buffer_To_Buffer inside render pass refused.
	enc = encoder_init(buf[:])
	testing.expect_value(t, encode_begin_render_pass(&enc, 1, 0, .Clear, .Store), Gpu_Refusal.None)
	testing.expect_value(t, encode_copy_buffer_to_buffer(&enc, 3, 1, 0, 0, 64), Gpu_Refusal.None)
	testing.expect_value(t, encode_end_render_pass(&enc), Gpu_Refusal.None)
	_, r_copy_in := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, r_copy_in, Gpu_Refusal.Copy_Inside_Render_Pass)

	// Copy_Buffer_To_Texture inside render pass refused.
	enc = encoder_init(buf[:])
	testing.expect_value(t, encode_begin_render_pass(&enc, 1, 0, .Clear, .Store), Gpu_Refusal.None)
	testing.expect_value(t, encode_copy_buffer_to_texture(&enc, 3, 3, 0, 64 * 4, 0, 0, 16, 16), Gpu_Refusal.None)
	testing.expect_value(t, encode_end_render_pass(&enc), Gpu_Refusal.None)
	_, r_tex_in := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, r_tex_in, Gpu_Refusal.Copy_Inside_Render_Pass)
}

@(test)
command_stream_bounds_and_usage_refusals :: proc(t: ^testing.T) {
	buffers, textures, pipelines := test_resources()
	reg := Resource_Registry{buffers = buffers[:], textures = textures[:], pipelines = pipelines[:], bind_group_count = 2}
	buf: [COMMAND_RECORD_SIZE * 16]u8

	// Draw without pipeline.
	enc := encoder_init(buf[:])
	_ = encode_begin_render_pass(&enc, 1, 0, .Clear, .Store)
	_ = encode_draw(&enc, 3, 1, 0, 0)
	_ = encode_end_render_pass(&enc)
	_, r_no_pipe := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, r_no_pipe, Gpu_Refusal.Missing_Pipeline)

	// Pipeline color format mismatch (pipeline 2 is RGBA8, render target 1 is BGRA8).
	enc = encoder_init(buf[:])
	_ = encode_begin_render_pass(&enc, 1, 0, .Clear, .Store)
	_ = encode_set_pipeline(&enc, 2)
	_ = encode_end_render_pass(&enc)
	_, r_fmt := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, r_fmt, Gpu_Refusal.Format_Mismatch)

	// Draw with vertex stride > 0 but no vertex buffer bound.
	enc = encoder_init(buf[:])
	_ = encode_begin_render_pass(&enc, 1, 0, .Clear, .Store)
	_ = encode_set_pipeline(&enc, 1)
	_ = encode_draw(&enc, 3, 1, 0, 0)
	_ = encode_end_render_pass(&enc)
	_, r_no_vb := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, r_no_vb, Gpu_Refusal.Missing_Vertex_Buffer)

	// Draw exceeding bound vertex buffer (1024 bytes / 32 stride = 32 vertices; 33 must fail).
	enc = encoder_init(buf[:])
	_ = encode_begin_render_pass(&enc, 1, 0, .Clear, .Store)
	_ = encode_set_pipeline(&enc, 1)
	_ = encode_set_vertex_buffer(&enc, 0, 1, 0, 1024)
	_ = encode_draw(&enc, 33, 1, 0, 0)
	_ = encode_end_render_pass(&enc)
	_, r_vb_oob := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, r_vb_oob, Gpu_Refusal.Vertex_Range_Out_Of_Bounds)

	// Draw_Indexed without index buffer.
	enc = encoder_init(buf[:])
	_ = encode_begin_render_pass(&enc, 1, 0, .Clear, .Store)
	_ = encode_set_pipeline(&enc, 1)
	_ = encode_set_vertex_buffer(&enc, 0, 1, 0, 1024)
	_ = encode_draw_indexed(&enc, 6, 1, 0, 0, 0)
	_ = encode_end_render_pass(&enc)
	_, r_no_ib := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, r_no_ib, Gpu_Refusal.Missing_Index_Buffer)

	// Draw_Indexed exceeding bound index buffer (256 bytes / 4 bytes = 64 Uint32 indices; 65 must fail).
	enc = encoder_init(buf[:])
	_ = encode_begin_render_pass(&enc, 1, 0, .Clear, .Store)
	_ = encode_set_pipeline(&enc, 1)
	_ = encode_set_vertex_buffer(&enc, 0, 1, 0, 1024)
	_ = encode_set_index_buffer(&enc, 2, .Uint32, 0, 256)
	_ = encode_draw_indexed(&enc, 65, 1, 0, 0, 0)
	_ = encode_end_render_pass(&enc)
	_, r_ib_oob := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, r_ib_oob, Gpu_Refusal.Index_Range_Out_Of_Bounds)

	// Scissor rect out of bounds (normal + u32 wraparound).
	enc = encoder_init(buf[:])
	_ = encode_begin_render_pass(&enc, 1, 0, .Clear, .Store)
	_ = encode_set_scissor_rect(&enc, 1900, 0, 21, 100)
	_ = encode_end_render_pass(&enc)
	_, r_sc1 := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, r_sc1, Gpu_Refusal.Scissor_Rect_Out_Of_Bounds)

	enc = encoder_init(buf[:])
	_ = encode_begin_render_pass(&enc, 1, 0, .Clear, .Store)
	_ = encode_set_scissor_rect(&enc, max(u32), 0, 2, 1)
	_ = encode_end_render_pass(&enc)
	_, r_sc2 := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, r_sc2, Gpu_Refusal.Scissor_Rect_Out_Of_Bounds)

	// Bind group out of range and invalid slot.
	enc = encoder_init(buf[:])
	_ = encode_begin_render_pass(&enc, 1, 0, .Clear, .Store)
	_ = encode_set_bind_group(&enc, MAX_BIND_GROUPS, 1)
	_ = encode_end_render_pass(&enc)
	_, r_bg_slot := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, r_bg_slot, Gpu_Refusal.Invalid_Slot)

	enc = encoder_init(buf[:])
	_ = encode_begin_render_pass(&enc, 1, 0, .Clear, .Store)
	_ = encode_set_bind_group(&enc, 0, 3) // bind_group_count == 2
	_ = encode_end_render_pass(&enc)
	_, r_bg_id := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, r_bg_id, Gpu_Refusal.Object_Id_Out_Of_Range)

	// Copy_Buffer_To_Buffer wrong usage, unaligned size, out of bounds.
	enc = encoder_init(buf[:])
	_ = encode_copy_buffer_to_buffer(&enc, 4, 1, 0, 0, 64) // buffer 4 lacks Copy_Src
	_, r_cp_use := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, r_cp_use, Gpu_Refusal.Missing_Usage_Flag)

	enc = encoder_init(buf[:])
	_ = encode_copy_buffer_to_buffer(&enc, 3, 1, 0, 0, 6) // not 4-byte aligned
	_, r_cp_align := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, r_cp_align, Gpu_Refusal.Copy_Alignment_Invalid)

	enc = encoder_init(buf[:])
	_ = encode_copy_buffer_to_buffer(&enc, 3, 1, 0, 1020, 8) // dst size 1024
	_, r_cp_oob := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, r_cp_oob, Gpu_Refusal.Copy_Range_Out_Of_Bounds)

	// Copy_Buffer_To_Texture into Depth24_Plus refused.
	enc = encoder_init(buf[:])
	_ = encode_copy_buffer_to_texture(&enc, 3, 2, 0, 256, 0, 0, 16, 16)
	_, r_depth_cp := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, r_depth_cp, Gpu_Refusal.Missing_Usage_Flag)

	// Encoder buffer full.
	tiny: [COMMAND_RECORD_SIZE - 1]u8
	tiny_enc := encoder_init(tiny[:])
	testing.expect_value(t, encode_end_render_pass(&tiny_enc), Gpu_Refusal.Encoder_Buffer_Full)
}

@(test)
command_stream_valid_full_frame :: proc(t: ^testing.T) {
	buffers, textures, pipelines := test_resources()
	reg := Resource_Registry{buffers = buffers[:], textures = textures[:], pipelines = pipelines[:], bind_group_count = 2}
	buf: [COMMAND_RECORD_SIZE * 16]u8
	enc := encoder_init(buf[:])

	// Upload vertex data, index data, and a 16x16 RGBA8 glyph atlas tile before the render pass.
	testing.expect_value(t, encode_copy_buffer_to_buffer(&enc, 3, 1, 0, 0, 1024), Gpu_Refusal.None)
	testing.expect_value(t, encode_copy_buffer_to_buffer(&enc, 3, 2, 1024, 0, 256), Gpu_Refusal.None)
	testing.expect_value(t, encode_copy_buffer_to_texture(&enc, 3, 3, 0, 16 * 4, 0, 0, 16, 16), Gpu_Refusal.None)

	// Render pass with color + depth attachment, scissor, bind group, Draw + Draw_Indexed.
	testing.expect_value(t, encode_begin_render_pass(&enc, 1, 2, .Clear, .Store, Clear_Color{a_bits = 0x3F80_0000}), Gpu_Refusal.None)
	testing.expect_value(t, encode_set_pipeline(&enc, 1), Gpu_Refusal.None)
	testing.expect_value(t, encode_set_vertex_buffer(&enc, 0, 1, 0, 1024), Gpu_Refusal.None)
	testing.expect_value(t, encode_set_index_buffer(&enc, 2, .Uint32, 0, 256), Gpu_Refusal.None)
	testing.expect_value(t, encode_set_bind_group(&enc, 0, 1), Gpu_Refusal.None)
	testing.expect_value(t, encode_set_scissor_rect(&enc, 0, 0, 1920, 1080), Gpu_Refusal.None)
	testing.expect_value(t, encode_draw(&enc, 32, 1, 0, 0), Gpu_Refusal.None)
	testing.expect_value(t, encode_draw_indexed(&enc, 64, 1, 0, 0, 0), Gpu_Refusal.None)
	testing.expect_value(t, encode_end_render_pass(&enc), Gpu_Refusal.None)

	summary, refusal := stream_validate(encoder_finish(&enc), reg)
	testing.expect_value(t, refusal, Gpu_Refusal.None)
	testing.expect_value(t, summary.command_count, u32(12))
	testing.expect_value(t, summary.render_pass_count, u32(1))
	testing.expect_value(t, summary.draw_call_count, u32(2))
	testing.expect_value(t, summary.copy_count, u32(3))
}

@(private = "file")
px_u :: proc(pixels: int) -> i32 {
	return draw_record.units_of_pixels(pixels)
}

@(private = "file")
append_path_point :: proc(buf: []u8, offset: int, cmd: draw_record.Path_Command, x_px, y_px: int) -> int {
	byte_order.write_u32_little_endian(buf, offset + 0, u32(cmd))
	byte_order.write_u32_little_endian(buf, offset + 4, u32(px_u(x_px)))
	byte_order.write_u32_little_endian(buf, offset + 8, u32(px_u(y_px)))
	return offset + draw_record.PATH_POINT_SIZE
}

@(private = "file")
expect_all_bytes_equal :: proc(t: ^testing.T, data: []u8, expected: u8, msg: string) {
	for b in data {
		if b != expected {
			testing.expect_value(t, b, expected)
			testing.expect(t, false, msg)
			return
		}
	}
}

@(test)
draw_table_translate_refusals_and_non_corruption :: proc(t: ^testing.T) {
	base_cfg := Draw_Table_Translate_Config{
		surface_width    = 64,
		surface_height   = 64,
		color_texture_id = 1,
		pipeline_id      = 1,
		vertex_buffer_id = 1,
		index_buffer_id  = 2,
		load_op          = .Clear,
	}

	cmd_buf: [COMMAND_RECORD_SIZE * 16]u8
	vtx_buf: [size_of(Vertex_2D) * 16]u8
	idx_buf: [size_of(u32) * 32]u8
	for i in 0 ..< len(cmd_buf) { cmd_buf[i] = 0xA5 }
	for i in 0 ..< len(vtx_buf) { vtx_buf[i] = 0xA5 }
	for i in 0 ..< len(idx_buf) { idx_buf[i] = 0xA5 }

	valid_rect := draw_record.record_of(draw_record.Draw_Rectangle{color = draw_record.opaque(0xFF0000)}, 0, px_u(0), px_u(0), px_u(32), px_u(32))
	one_rect := [1]draw_record.Draw_Record{valid_rect}

	// Config border refusals.
	bad_cfg := base_cfg
	bad_cfg.surface_width = 0
	_, p := draw_table_translate_to_webgpu(one_rect[:], nil, bad_cfg, cmd_buf[:], vtx_buf[:], idx_buf[:])
	testing.expect_value(t, p, Draw_Table_Translation_Problem.Zero_Surface_Dimensions)

	bad_cfg = base_cfg
	bad_cfg.surface_height = MAX_TEXTURE_DIMENSION + 1
	_, p = draw_table_translate_to_webgpu(one_rect[:], nil, bad_cfg, cmd_buf[:], vtx_buf[:], idx_buf[:])
	testing.expect_value(t, p, Draw_Table_Translation_Problem.Surface_Dimension_Too_Large)

	bad_cfg = base_cfg
	bad_cfg.pipeline_id = 0
	_, p = draw_table_translate_to_webgpu(one_rect[:], nil, bad_cfg, cmd_buf[:], vtx_buf[:], idx_buf[:])
	testing.expect_value(t, p, Draw_Table_Translation_Problem.Zero_Object_Id)

	bad_cfg = base_cfg
	bad_cfg.has_damage_rect = true
	bad_cfg.damage_rect = Pixel_Rect{x = 60, y = 0, width = 5, height = 10}
	_, p = draw_table_translate_to_webgpu(one_rect[:], nil, bad_cfg, cmd_buf[:], vtx_buf[:], idx_buf[:])
	testing.expect_value(t, p, Draw_Table_Translation_Problem.Damage_Rect_Out_Of_Bounds)

	bad_cfg.damage_rect = Pixel_Rect{x = max(u32), y = 0, width = 2, height = 1}
	_, p = draw_table_translate_to_webgpu(one_rect[:], nil, bad_cfg, cmd_buf[:], vtx_buf[:], idx_buf[:])
	testing.expect_value(t, p, Draw_Table_Translation_Problem.Damage_Rect_Out_Of_Bounds)

	// Unbalanced Clip_Push without Clip_Pop refused.
	unbal_push := [2]draw_record.Draw_Record{
		draw_record.record_of(draw_record.Draw_Clip_Push{}, 0, px_u(0), px_u(0), px_u(32), px_u(32)),
		valid_rect,
	}
	_, p = draw_table_translate_to_webgpu(unbal_push[:], nil, base_cfg, cmd_buf[:], vtx_buf[:], idx_buf[:])
	testing.expect_value(t, p, Draw_Table_Translation_Problem.Unbalanced_Clips_Or_Elements)

	// Unbalanced Clip_Pop without Clip_Push refused.
	unbal_pop := [1]draw_record.Draw_Record{
		draw_record.record_of(draw_record.Draw_Clip_Pop{}, 0, 0, 0, 0, 0),
	}
	_, p = draw_table_translate_to_webgpu(unbal_pop[:], nil, base_cfg, cmd_buf[:], vtx_buf[:], idx_buf[:])
	testing.expect_value(t, p, Draw_Table_Translation_Problem.Unbalanced_Clips_Or_Elements)

	// Out-of-bounds draw record (inverted box and past coordinate limit).
	bad_rec := valid_rect
	bad_rec.left = px_u(40)
	bad_rec.right = px_u(10)
	bad_table := [2]draw_record.Draw_Record{valid_rect, bad_rec}
	_, p = draw_table_translate_to_webgpu(bad_table[:], nil, base_cfg, cmd_buf[:], vtx_buf[:], idx_buf[:])
	testing.expect_value(t, p, Draw_Table_Translation_Problem.Invalid_Draw_Record)

	// Text record pointing past text_bytes refused.
	bad_text := [1]draw_record.Draw_Record{
		draw_record.record_of(draw_record.Draw_Text{
			first    = 10,
			count    = 5,
			color    = draw_record.opaque(0xFFFFFF),
			origin_x = px_u(0),
			font     = .Cells_8x16,
			weight   = .Regular,
			size     = u16(px_u(16)),
		}, 0, px_u(0), px_u(0), px_u(40), px_u(16)),
	}
	short_text: [12]u8
	_, p = draw_table_translate_to_webgpu(bad_text[:], short_text[:], base_cfg, cmd_buf[:], vtx_buf[:], idx_buf[:])
	testing.expect_value(t, p, Draw_Table_Translation_Problem.Byte_Table_Out_Of_Bounds)

	// Buffer overflow refusals: vertex, index, and command buffers too small.
	_, p = draw_table_translate_to_webgpu(one_rect[:], nil, base_cfg, cmd_buf[:], vtx_buf[:size_of(Vertex_2D) * 3], idx_buf[:])
	testing.expect_value(t, p, Draw_Table_Translation_Problem.Vertex_Buffer_Overflow)

	_, p = draw_table_translate_to_webgpu(one_rect[:], nil, base_cfg, cmd_buf[:], vtx_buf[:], idx_buf[:size_of(u32) * 5])
	testing.expect_value(t, p, Draw_Table_Translation_Problem.Index_Buffer_Overflow)

	_, p = draw_table_translate_to_webgpu(one_rect[:], nil, base_cfg, cmd_buf[:COMMAND_RECORD_SIZE * 6], vtx_buf[:], idx_buf[:])
	testing.expect_value(t, p, Draw_Table_Translation_Problem.Command_Buffer_Overflow)

	// Zero partial corruption: every sentinel byte across all three output buffers stays intact.
	expect_all_bytes_equal(t, cmd_buf[:], 0xA5, "command buffer must remain untouched after refusals")
	expect_all_bytes_equal(t, vtx_buf[:], 0xA5, "vertex buffer must remain untouched after refusals")
	expect_all_bytes_equal(t, idx_buf[:], 0xA5, "index buffer must remain untouched after refusals")
}

@(test)
draw_table_translate_features_and_culling :: proc(t: ^testing.T) {
	text_table: [256]u8
	// Put a UTF-8 label at offset 0..5, and a 3-point triangle path at offset 16.
	copy(text_table[0:5], "modus")
	path_off := 16
	off := path_off
	off = append_path_point(text_table[:], off, .Move, 4, 4)
	off = append_path_point(text_table[:], off, .Line, 20, 4)
	off = append_path_point(text_table[:], off, .Line, 12, 20)
	off = append_path_point(text_table[:], off, .Close, 0, 0)
	path_bytes := u32(off - path_off)

	records := [?]draw_record.Draw_Record{
		// Semantic element push/pop must be skipped with zero geometry.
		draw_record.record_of(draw_record.Draw_Element_Push{role = .Button}, 42, px_u(0), px_u(0), px_u(64), px_u(64)),
		// Visible rectangle inside damage rect [0..32) x [0..32).
		draw_record.record_of(draw_record.Draw_Rectangle{color = draw_record.opaque(0xFF0000)}, 42, px_u(0), px_u(0), px_u(24), px_u(24)),
		// Culled rectangle outside damage rect [0..32) x [0..32).
		draw_record.record_of(draw_record.Draw_Rectangle{color = draw_record.opaque(0x00FF00)}, 42, px_u(40), px_u(40), px_u(60), px_u(60)),
		// Nested clip push intersecting damage rect -> [8..28) x [8..28).
		draw_record.record_of(draw_record.Draw_Clip_Push{}, 42, px_u(8), px_u(8), px_u(28), px_u(28)),
		draw_record.record_of(draw_record.Draw_Gradient{
			start_x = px_u(8), start_y = px_u(8), end_x = px_u(28), end_y = px_u(8),
			start_color = draw_record.opaque(0xFF0000), end_color = draw_record.opaque(0x0000FF),
		}, 42, px_u(8), px_u(8), px_u(28), px_u(28)),
		// Disjoint inner clip -> empty intersection, enclosed record culled without zero-extent scissor.
		draw_record.record_of(draw_record.Draw_Clip_Push{}, 42, px_u(30), px_u(30), px_u(50), px_u(50)),
		draw_record.record_of(draw_record.Draw_Picture{memory = 0, format = .Opaque, first = 0, stride = 16, generation = 1}, 42, px_u(30), px_u(30), px_u(46), px_u(46)),
		draw_record.record_of(draw_record.Draw_Clip_Pop{}, 42, 0, 0, 0, 0),
		draw_record.record_of(draw_record.Draw_Clip_Pop{}, 42, 0, 0, 0, 0),
		// Visible text + visible path.
		draw_record.record_of(draw_record.Draw_Text{
			first = 0, count = 5, color = draw_record.opaque(0xFFFFFF),
			origin_x = px_u(2), font = .Cells_8x16, weight = .Regular, size = u16(px_u(16)),
		}, 42, px_u(2), px_u(2), px_u(42), px_u(18)),
		draw_record.record_of(draw_record.Draw_Path{
			first = u32(path_off), count = path_bytes,
			fill_color = draw_record.opaque(0x00FF00), stroke_color = draw_record.opaque(0xFFFFFF), stroke_width = u32(px_u(2)),
		}, 42, px_u(0), px_u(0), px_u(24), px_u(24)),
		draw_record.record_of(draw_record.Draw_Element_Pop{}, 42, 0, 0, 0, 0),
	}

	cfg := Draw_Table_Translate_Config{
		surface_width    = 64,
		surface_height   = 64,
		color_texture_id = 1,
		pipeline_id      = 1,
		vertex_buffer_id = 1,
		index_buffer_id  = 2,
		load_op          = .Clear,
		has_damage_rect  = true,
		damage_rect      = Pixel_Rect{x = 0, y = 0, width = 32, height = 32},
	}

	cmd_buf: [COMMAND_RECORD_SIZE * 64]u8
	vtx_buf: [size_of(Vertex_2D) * 256]u8
	idx_buf: [size_of(u32) * 512]u8

	res, prob := draw_table_translate_to_webgpu(records[:], text_table[:], cfg, cmd_buf[:], vtx_buf[:], idx_buf[:])
	testing.expect_value(t, prob, Draw_Table_Translation_Problem.None)
	testing.expect_value(t, res.skipped_records, u32(2)) // Element_Push + Element_Pop
	testing.expect_value(t, res.culled_records, u32(2))  // out-of-damage rect + disjoint-clip picture
	testing.expect_value(t, res.scissor_change_count, u32(3)) // root -> nested -> root
	testing.expect(t, res.vertex_count > 0 && res.index_count > 0, "visible geometry must be emitted")

	// Emitted command stream must pass strict webgpu_subset.stream_validate.
	buffers := [?]Buffer_Desc{
		{size = u64(len(vtx_buf)), usage = {.Vertex}},
		{size = u64(len(idx_buf)), usage = {.Index}},
	}
	textures := [?]Texture_Desc{
		{width = 64, height = 64, format = .RGBA8_Unorm, usage = {.Render_Attachment}},
	}
	pipelines := [?]Pipeline_Desc{
		{topology = .Triangle_List, color_format = .RGBA8_Unorm, src_blend = .Src_Alpha, dst_blend = .One_Minus_Src_Alpha, vertex_stride = VERTEX_2D_STRIDE},
	}
	reg := Resource_Registry{buffers = buffers[:], textures = textures[:], pipelines = pipelines[:]}
	summary, ws_ref := stream_validate(res.stream, reg)
	testing.expect_value(t, ws_ref, Gpu_Refusal.None)
	testing.expect_value(t, summary.render_pass_count, u32(1))
	testing.expect_value(t, summary.draw_call_count, u32(3))
}

@(test)
software_3d_depth_occlusion_scissor_degenerate_and_refusals :: proc(t: ^testing.T) {
	W :: 32
	H :: 32

	// Perspective MVP looking down -Z (near = 1.0, far = 10.0) with identity model transform.
	mvp := matrix_4x4_perspective_zero_to_one(1.0, 1.0, 1.0, 10.0)
	uniform_bytes: [MATRIX_4X4_BYTES]u8
	testing.expect(t, matrix_4x4_encode(mvp, uniform_bytes[:], 0), "MVP encode must succeed")

	// Two overlapping 3D triangles covering center pixel (16, 16):
	// Triangle A (RED): z = -4.0 (farther), spans x in [-2, 2], y in [-2, 2]
	// Triangle B (GREEN): z = -2.0 (nearer), spans x in [-0.6, 0.6], y in [-0.6, 0.6]
	// Triangle C (degenerate collinear): must be safely skipped.
	far_tri := [3]Vertex_3D{
		{x = -2.0, y = -2.0, z = -4.0, r = 1.0, g = 0.0, b = 0.0, a = 1.0},
		{x =  2.0, y = -2.0, z = -4.0, r = 1.0, g = 0.0, b = 0.0, a = 1.0},
		{x =  0.0, y =  2.0, z = -4.0, r = 1.0, g = 0.0, b = 0.0, a = 1.0},
	}
	near_tri := [3]Vertex_3D{
		{x = -0.8, y = -0.8, z = -2.0, r = 0.0, g = 1.0, b = 0.0, a = 1.0},
		{x =  0.8, y = -0.8, z = -2.0, r = 0.0, g = 1.0, b = 0.0, a = 1.0},
		{x =  0.0, y =  0.8, z = -2.0, r = 0.0, g = 1.0, b = 0.0, a = 1.0},
	}
	degen_tri := [3]Vertex_3D{
		{x = 0.0, y = 0.0, z = -2.0, r = 0.0, g = 0.0, b = 1.0, a = 1.0},
		{x = 0.5, y = 0.5, z = -2.0, r = 0.0, g = 0.0, b = 1.0, a = 1.0},
		{x = 1.0, y = 1.0, z = -2.0, r = 0.0, g = 0.0, b = 1.0, a = 1.0},
	}

	// Render in BOTH draw orders: (far then near) and (near then far).
	color_order_a: [W * H * 4]u8
	depth_order_a: [W * H]u32
	color_order_b: [W * H * 4]u8
	depth_order_b: [W * H]u32

	for pass_idx in 0 ..< 2 {
		vb_bytes: [size_of(Vertex_3D) * 9]u8
		if pass_idx == 0 {
			for v, i in far_tri { _ = vertex_3d_encode(v, vb_bytes[:], i * size_of(Vertex_3D)) }
			for v, i in near_tri { _ = vertex_3d_encode(v, vb_bytes[:], (3 + i) * size_of(Vertex_3D)) }
		} else {
			for v, i in near_tri { _ = vertex_3d_encode(v, vb_bytes[:], i * size_of(Vertex_3D)) }
			for v, i in far_tri { _ = vertex_3d_encode(v, vb_bytes[:], (3 + i) * size_of(Vertex_3D)) }
		}
		for v, i in degen_tri { _ = vertex_3d_encode(v, vb_bytes[:], (6 + i) * size_of(Vertex_3D)) }

		buffers_desc := [?]Buffer_Desc{
			{size = u64(len(vb_bytes)), usage = {.Vertex}},
			{size = u64(len(uniform_bytes)), usage = {.Uniform}},
		}
		textures_desc := [?]Texture_Desc{
			{width = W, height = H, format = .RGBA8_Unorm, usage = {.Render_Attachment}},
			{width = W, height = H, format = .Depth24_Plus, usage = {.Render_Attachment}},
		}
		pipelines_desc := [?]Pipeline_Desc{
			{topology = .Triangle_List, color_format = .RGBA8_Unorm, src_blend = .One, dst_blend = .Zero, vertex_stride = VERTEX_3D_STRIDE},
		}
		reg := Resource_Registry{buffers = buffers_desc[:], textures = textures_desc[:], pipelines = pipelines_desc[:], bind_group_count = 1}

		cmd_storage: [COMMAND_RECORD_SIZE * 16]u8
		enc := encoder_init(cmd_storage[:])
		_ = encode_begin_render_pass(&enc, 1, 2, .Clear, .Store, Clear_Color{a_bits = transmute(u32)f32(1.0)})
		_ = encode_set_pipeline(&enc, 1)
		_ = encode_set_vertex_buffer(&enc, 0, 1, 0, u64(len(vb_bytes)))
		_ = encode_set_bind_group(&enc, 0, 1)
		// Scissor clips to [4..28) x [4..28) to verify edge clipping simultaneously.
		_ = encode_set_scissor_rect(&enc, 4, 4, 24, 24)
		_ = encode_draw(&enc, 9, 1, 0, 0)
		_ = encode_end_render_pass(&enc)

		target_color := pass_idx == 0 ? color_order_a[:] : color_order_b[:]
		target_depth := pass_idx == 0 ? depth_order_a[:] : depth_order_b[:]

		backing_bufs := [?][]u8{vb_bytes[:], uniform_bytes[:]}
		backing_tex := [?]Software_Texture_Memory{
			{color_bytes = target_color},
			{depth_values = target_depth},
		}
		shaders := [?]Software_Shader_Mode{.Vertex_Color_3D}
		bg_uniforms := [?]u32{2}

		dev := Software_Device{
			resources           = reg,
			buffers             = backing_bufs[:],
			textures            = backing_tex[:],
			pipeline_shaders    = shaders[:],
			bind_group_uniforms = bg_uniforms[:],
		}
		exec_sum, exec_ref := software_3d_execute(encoder_finish(&enc), dev)
		testing.expect_value(t, exec_ref, Gpu_Refusal.None)
		// Degenerate triangle is skipped -> exactly 2 triangles rasterized.
		testing.expect_value(t, exec_sum.triangles_rasterized, u64(2))
		testing.expect(t, exec_sum.pixels_shaded > 0, "triangles must shade pixels")
	}

	// Both draw orders must produce bit-identical color and depth buffers!
	for i in 0 ..< len(color_order_a) {
		testing.expect_value(t, color_order_a[i], color_order_b[i])
	}
	for i in 0 ..< len(depth_order_a) {
		testing.expect_value(t, depth_order_a[i], depth_order_b[i])
	}

	// Center pixel (16, 16) is covered by both triangles: nearer GREEN triangle wins!
	center_px := (16 * W + 16) * 4
	testing.expect_value(t, color_order_a[center_px + 0], u8(0))
	testing.expect_value(t, color_order_a[center_px + 1], u8(255))
	testing.expect_value(t, color_order_a[center_px + 2], u8(0))
	testing.expect_value(t, color_order_a[center_px + 3], u8(255))
	testing.expect(t, depth_order_a[16 * W + 16] < DEPTH24_MAX, "depth buffer must record near triangle depth")

	// Pixel (16, 22) is inside FAR red triangle and outside NEAR green triangle -> RED!
	red_px := (22 * W + 16) * 4
	testing.expect_value(t, color_order_a[red_px + 0], u8(255))
	testing.expect_value(t, color_order_a[red_px + 1], u8(0))
	testing.expect_value(t, color_order_a[red_px + 2], u8(0))

	// Scissor boundary check: pixel (3, 16) and (28, 16) outside [4..28) must stay clear black (0,0,0,255).
	for sx in ([]int{3, 28}) {
		off := (16 * W + sx) * 4
		testing.expect_value(t, color_order_a[off + 0], u8(0))
		testing.expect_value(t, color_order_a[off + 1], u8(0))
		testing.expect_value(t, color_order_a[off + 2], u8(0))
		testing.expect_value(t, color_order_a[off + 3], u8(255))
	}

	// Refusal with ZERO pixels touched: undersized backing buffer, undersized texture,
	// invalid shader mode, and out-of-bounds index value in Draw_Indexed.
	sentinel_color: [W * H * 4]u8
	sentinel_depth: [W * H]u32
	for i in 0 ..< len(sentinel_color) { sentinel_color[i] = 0x5A }
	for i in 0 ..< len(sentinel_depth) { sentinel_depth[i] = 0x0012_3456 }

	vb_small: [size_of(Vertex_3D) * 3]u8
	ib_bad: [12]u8
	byte_order.write_u32_little_endian(ib_bad[:], 0, 0)
	byte_order.write_u32_little_endian(ib_bad[:], 4, 1)
	byte_order.write_u32_little_endian(ib_bad[:], 8, 99) // Out of bounds of 3-vertex VB!

	b_desc := [?]Buffer_Desc{
		{size = u64(len(vb_small)), usage = {.Vertex}},
		{size = u64(len(ib_bad)), usage = {.Index}},
	}
	t_desc := [?]Texture_Desc{
		{width = W, height = H, format = .RGBA8_Unorm, usage = {.Render_Attachment}},
		{width = W, height = H, format = .Depth24_Plus, usage = {.Render_Attachment}},
	}
	p_desc := [?]Pipeline_Desc{
		{topology = .Triangle_List, color_format = .RGBA8_Unorm, src_blend = .One, dst_blend = .Zero, vertex_stride = VERTEX_3D_STRIDE},
	}
	reg_bad := Resource_Registry{buffers = b_desc[:], textures = t_desc[:], pipelines = p_desc[:]}

	cmd_bad: [COMMAND_RECORD_SIZE * 8]u8
	enc_bad := encoder_init(cmd_bad[:])
	_ = encode_begin_render_pass(&enc_bad, 1, 2, .Clear, .Store)
	_ = encode_set_pipeline(&enc_bad, 1)
	_ = encode_set_vertex_buffer(&enc_bad, 0, 1, 0, u64(len(vb_small)))
	_ = encode_set_index_buffer(&enc_bad, 2, .Uint32, 0, u64(len(ib_bad)))
	_ = encode_draw_indexed(&enc_bad, 3, 1, 0, 0, 0)
	_ = encode_end_render_pass(&enc_bad)

	backing_bufs_bad := [?][]u8{vb_small[:], ib_bad[:]}
	backing_tex_ok := [?]Software_Texture_Memory{{color_bytes = sentinel_color[:]}, {depth_values = sentinel_depth[:]}}
	shaders_ok := [?]Software_Shader_Mode{.Vertex_Color_3D}

	// Out-of-bounds index value inside index buffer refused before clearing!
	_, ref_idx := software_3d_execute(encoder_finish(&enc_bad), Software_Device{
		resources = reg_bad, buffers = backing_bufs_bad[:], textures = backing_tex_ok[:], pipeline_shaders = shaders_ok[:],
	})
	testing.expect_value(t, ref_idx, Gpu_Refusal.Index_Value_Out_Of_Bounds)

	// Undersized backing buffer refused.
	backing_bufs_short := [?][]u8{vb_small[:len(vb_small) - 1], ib_bad[:]}
	_, ref_buf := software_3d_execute(encoder_finish(&enc_bad), Software_Device{
		resources = reg_bad, buffers = backing_bufs_short[:], textures = backing_tex_ok[:], pipeline_shaders = shaders_ok[:],
	})
	testing.expect_value(t, ref_buf, Gpu_Refusal.Backing_Buffer_Too_Small)

	// Undersized backing color texture refused.
	backing_tex_short := [?]Software_Texture_Memory{{color_bytes = sentinel_color[:len(sentinel_color) - 4]}, {depth_values = sentinel_depth[:]}}
	_, ref_tex := software_3d_execute(encoder_finish(&enc_bad), Software_Device{
		resources = reg_bad, buffers = backing_bufs_bad[:], textures = backing_tex_short[:], pipeline_shaders = shaders_ok[:],
	})
	testing.expect_value(t, ref_tex, Gpu_Refusal.Backing_Texture_Too_Small)

	// Invalid shader mode (.None) refused.
	shaders_bad := [?]Software_Shader_Mode{.None}
	_, ref_sh := software_3d_execute(encoder_finish(&enc_bad), Software_Device{
		resources = reg_bad, buffers = backing_bufs_bad[:], textures = backing_tex_ok[:], pipeline_shaders = shaders_bad[:],
	})
	testing.expect_value(t, ref_sh, Gpu_Refusal.Shader_Mode_Invalid)

	// Verify ZERO pixels touched across all four refusals!
	expect_all_bytes_equal(t, sentinel_color[:], 0x5A, "color framebuffer must be untouched after refusal")
	for d in sentinel_depth {
		testing.expect_value(t, d, u32(0x0012_3456))
	}
}

@(test)
draw_table_to_software_3d_end_to_end :: proc(t: ^testing.T) {
	W :: 32
	H :: 32

	// Build a draw_record v20 frame:
	// 1. Opaque red background rect [0..32) x [0..32)
	// 2. Clip_Push [8..20) x [8..20)
	//    - Full-screen green rect [0..32) x [0..32) -> must clip strictly to [8..20) x [8..20)
	// 3. Clip_Pop
	// 4. Translucent blue rect (alpha 128) at [0..8) x [0..8) over red -> linear-light gamma-2 blend!
	// 5. Element_Push / Element_Pop wrapping a filled white path triangle at [22..30) x [22..30).
	text_table: [128]u8
	off := 0
	off = append_path_point(text_table[:], off, .Move, 22, 22)
	off = append_path_point(text_table[:], off, .Line, 30, 22)
	off = append_path_point(text_table[:], off, .Line, 26, 30)
	off = append_path_point(text_table[:], off, .Close, 0, 0)

	records := [?]draw_record.Draw_Record{
		draw_record.record_of(draw_record.Draw_Rectangle{color = draw_record.opaque(0xFF0000)}, 0, px_u(0), px_u(0), px_u(W), px_u(H)),
		draw_record.record_of(draw_record.Draw_Clip_Push{}, 0, px_u(8), px_u(8), px_u(20), px_u(20)),
		draw_record.record_of(draw_record.Draw_Rectangle{color = draw_record.opaque(0x00FF00)}, 0, px_u(0), px_u(0), px_u(W), px_u(H)),
		draw_record.record_of(draw_record.Draw_Clip_Pop{}, 0, 0, 0, 0, 0),
		draw_record.record_of(draw_record.Draw_Rectangle{color = draw_record.with_alpha(0x0000FF, 128)}, 0, px_u(0), px_u(0), px_u(8), px_u(8)),
		draw_record.record_of(draw_record.Draw_Element_Push{role = .Figure}, 7, px_u(22), px_u(22), px_u(30), px_u(30)),
		draw_record.record_of(draw_record.Draw_Path{first = 0, count = u32(off), fill_color = draw_record.opaque(0xFFFFFF)}, 7, px_u(22), px_u(22), px_u(30), px_u(30)),
		draw_record.record_of(draw_record.Draw_Element_Pop{}, 7, 0, 0, 0, 0),
	}

	cmd_buf: [COMMAND_RECORD_SIZE * 64]u8
	vtx_buf: [size_of(Vertex_2D) * 128]u8
	idx_buf: [size_of(u32) * 256]u8

	cfg := Draw_Table_Translate_Config{
		surface_width    = W,
		surface_height   = H,
		color_texture_id = 1,
		pipeline_id      = 1,
		vertex_buffer_id = 1,
		index_buffer_id  = 2,
		load_op          = .Clear,
		clear_color      = Clear_Color{a_bits = transmute(u32)f32(1.0)},
	}

	tr, tr_prob := draw_table_translate_to_webgpu(records[:], text_table[:], cfg, cmd_buf[:], vtx_buf[:], idx_buf[:])
	testing.expect_value(t, tr_prob, Draw_Table_Translation_Problem.None)
	testing.expect_value(t, tr.skipped_records, u32(2))

	framebuffer: [W * H * 4]u8
	b_desc := [?]Buffer_Desc{
		{size = u64(tr.vertex_bytes_used), usage = {.Vertex}},
		{size = u64(tr.index_bytes_used), usage = {.Index}},
	}
	t_desc := [?]Texture_Desc{
		{width = W, height = H, format = .RGBA8_Unorm, usage = {.Render_Attachment}},
	}
	p_desc := [?]Pipeline_Desc{
		{topology = .Triangle_List, color_format = .RGBA8_Unorm, src_blend = .Src_Alpha, dst_blend = .One_Minus_Src_Alpha, vertex_stride = VERTEX_2D_STRIDE},
	}
	reg := Resource_Registry{buffers = b_desc[:], textures = t_desc[:], pipelines = p_desc[:]}
	backing_bufs := [?][]u8{vtx_buf[:tr.vertex_bytes_used], idx_buf[:tr.index_bytes_used]}
	backing_tex := [?]Software_Texture_Memory{{color_bytes = framebuffer[:]}}
	shaders := [?]Software_Shader_Mode{.Solid_Color_2D}

	exec_sum, exec_ref := software_3d_execute(tr.stream, Software_Device{
		resources        = reg,
		buffers          = backing_bufs[:],
		textures         = backing_tex[:],
		pipeline_shaders = shaders[:],
	})
	testing.expect_value(t, exec_ref, Gpu_Refusal.None)
	testing.expect(t, exec_sum.triangles_rasterized >= 7, "all rects and path triangle must rasterize")

	// Inside clipped green rect [8..20) x [8..20): pixel (12, 12) must be pure GREEN.
	p_green := (12 * W + 12) * 4
	testing.expect_value(t, framebuffer[p_green + 0], u8(0))
	testing.expect_value(t, framebuffer[p_green + 1], u8(255))
	testing.expect_value(t, framebuffer[p_green + 2], u8(0))

	// Immediately outside clip at (7, 12) and (20, 12): must be RED background!
	for x in ([]int{7, 20}) {
		p_red := (12 * W + x) * 4
		testing.expect_value(t, framebuffer[p_red + 0], u8(255))
		testing.expect_value(t, framebuffer[p_red + 1], u8(0))
		testing.expect_value(t, framebuffer[p_red + 2], u8(0))
	}

	// Translucent blue (alpha 128/255 ≈ 0.502) over opaque red in linear light (gamma 2):
	// R = sqrt(1.0 * (1 - 128/255)) * 255 ≈ 180, B = sqrt(1.0 * (128/255)) * 255 ≈ 181.
	p_blend := (4 * W + 4) * 4
	testing.expect(t, framebuffer[p_blend + 0] >= 178 && framebuffer[p_blend + 0] <= 182, "linear-light red blend must be ~180")
	testing.expect_value(t, framebuffer[p_blend + 1], u8(0))
	testing.expect(t, framebuffer[p_blend + 2] >= 179 && framebuffer[p_blend + 2] <= 183, "linear-light blue blend must be ~181")

	// Inside filled white path triangle at (26, 25): must be pure WHITE!
	p_path := (25 * W + 26) * 4
	testing.expect_value(t, framebuffer[p_path + 0], u8(255))
	testing.expect_value(t, framebuffer[p_path + 1], u8(255))
	testing.expect_value(t, framebuffer[p_path + 2], u8(255))
}

