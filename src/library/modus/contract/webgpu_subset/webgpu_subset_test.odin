#+build !freestanding
package webgpu_subset

import "core:testing"
import "modus:contract/byte_order"

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
