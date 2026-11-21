// The minimal WebGPU subset contract for 2D draw-table acceleration and 3D
// rendering (src/md/features/gpu_access.md): closed enumerations, precompiled
// SPIR-V binary border validation, fixed-size binary command stream encoding,
// and strict render-pass and resource-bounds validation.
//
// Shaders arrive exclusively as precompiled SPIR-V words; this system holds no
// runtime WGSL compiler. All wire integers are little-endian. This package
// allocates no memory and calls no kernel operation.
package webgpu_subset

import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Fixed size of one encoded GPU command record, in bytes.
COMMAND_RECORD_SIZE :: 48
MAX_COMMAND_STREAM_COMMANDS :: 4096
MAX_COMMAND_STREAM_BYTES :: MAX_COMMAND_STREAM_COMMANDS * COMMAND_RECORD_SIZE

// Fixed slot limits matching the minimal WebGPU subset.
MAX_VERTEX_BUFFER_SLOTS :: 8
MAX_BIND_GROUPS :: 4
MAX_TEXTURE_DIMENSION :: 16384

// SPIR-V binary header constants (SPIR-V 1.x specification, section 2.3).
SPIRV_MAGIC :: u32(0x0723_0203)
SPIRV_HEADER_WORDS :: 5
SPIRV_HEADER_BYTES :: SPIRV_HEADER_WORDS * 4
SPIRV_MAX_MINOR_VERSION :: u32(6)

// Allowed usages of a GPU buffer.
Buffer_Usage_Flag :: enum u32 {
	Vertex   = 0,
	Index    = 1,
	Uniform  = 2,
	Storage  = 3,
	Copy_Src = 4,
	Copy_Dst = 5,
}

Buffer_Usage :: bit_set[Buffer_Usage_Flag; u32]

// Closed set of pixel and depth formats in the WebGPU subset.
Texture_Format :: enum u32 {
	None             = 0,
	BGRA8_Unorm      = 1,
	RGBA8_Unorm      = 2,
	RGBA8_Unorm_Srgb = 3,
	R8_Unorm         = 4,
	Depth24_Plus     = 5,
}

// Allowed usages of a GPU texture.
Texture_Usage_Flag :: enum u32 {
	Copy_Src          = 0,
	Copy_Dst          = 1,
	Texture_Binding   = 2,
	Storage_Binding   = 3,
	Render_Attachment = 4,
}

Texture_Usage :: bit_set[Texture_Usage_Flag; u32]

// Closed set of primitive topologies.
Primitive_Topology :: enum u32 {
	None           = 0,
	Triangle_List  = 1,
	Triangle_Strip = 2,
	Line_List      = 3,
}

// Closed set of blend factors.
Blend_Factor :: enum u32 {
	Zero                = 0,
	One                 = 1,
	Src_Alpha           = 2,
	One_Minus_Src_Alpha = 3,
	Dst_Alpha           = 4,
	One_Minus_Dst_Alpha = 5,
}

// Closed set of render pass attachment load operations.
Load_Op :: enum u32 {
	None  = 0,
	Load  = 1,
	Clear = 2,
}

// Closed set of render pass attachment store operations.
Store_Op :: enum u32 {
	None    = 0,
	Store   = 1,
	Discard = 2,
}

// Index buffer element size.
Index_Format :: enum u32 {
	None   = 0,
	Uint16 = 1,
	Uint32 = 2,
}

// Closed set of GPU command kinds in a Gpu_Command_Stream.
Gpu_Command_Kind :: enum u32 {
	None                   = 0,
	Begin_Render_Pass      = 1,
	Set_Pipeline           = 2,
	Set_Vertex_Buffer      = 3,
	Set_Index_Buffer       = 4,
	Set_Bind_Group         = 5,
	Set_Scissor_Rect       = 6,
	Draw                   = 7,
	Draw_Indexed           = 8,
	End_Render_Pass        = 9,
	Copy_Buffer_To_Buffer  = 10,
	Copy_Buffer_To_Texture = 11,
}

// Why shader validation, encoding, or command stream validation refused an input.
Gpu_Refusal :: enum u8 {
	None = 0,
	Stream_Truncated,
	Stream_Too_Large,
	Encoder_Buffer_Full,
	Unknown_Command_Kind,
	Non_Zero_Reserved,
	Unknown_Enum_Word,
	Unknown_Usage_Bits,
	Render_Pass_Already_Active,
	Render_Pass_Not_Active,
	Unbalanced_Render_Pass,
	Copy_Inside_Render_Pass,
	Missing_Pipeline,
	Missing_Vertex_Buffer,
	Missing_Index_Buffer,
	Zero_Object_Id,
	Object_Id_Out_Of_Range,
	Missing_Usage_Flag,
	Format_Mismatch,
	Invalid_Slot,
	Zero_Draw_Count,
	Vertex_Range_Out_Of_Bounds,
	Index_Range_Out_Of_Bounds,
	Scissor_Rect_Out_Of_Bounds,
	Copy_Range_Out_Of_Bounds,
	Copy_Alignment_Invalid,
	Zero_Extent,
	Dimension_Too_Large,
	Spirv_Too_Short,
	Spirv_Bad_Magic,
	Spirv_Bad_Version,
	Spirv_Zero_Bound,
	Spirv_Non_Zero_Schema,
	Spirv_No_Instructions,
	Spirv_Bad_Instruction_Word_Count,
	Spirv_Truncated_Instruction,
	Spirv_Unaligned_Byte_Length,
}

// Validated metadata extracted from a precompiled SPIR-V binary module.
Spirv_Header_Info :: struct {
	version_major:     u32,
	version_minor:     u32,
	generator:         u32,
	id_bound:          u32,
	instruction_count: u32,
}

// Descriptor of a declared GPU buffer (object IDs start at 1).
Buffer_Desc :: struct {
	size:  u64,
	usage: Buffer_Usage,
}

// Descriptor of a declared GPU texture (object IDs start at 1).
Texture_Desc :: struct {
	width:  u32,
	height: u32,
	format: Texture_Format,
	usage:  Texture_Usage,
}

// Descriptor of a declared render pipeline (object IDs start at 1).
Pipeline_Desc :: struct {
	topology:      Primitive_Topology,
	color_format:  Texture_Format,
	src_blend:     Blend_Factor,
	dst_blend:     Blend_Factor,
	vertex_stride: u32,
}

// Caller-supplied tables of declared resources against which a stream is validated.
// Object identifier N (1-based) addresses entry N - 1 of the matching table.
Resource_Registry :: struct {
	buffers:          []Buffer_Desc,
	textures:         []Texture_Desc,
	pipelines:        []Pipeline_Desc,
	bind_group_count: u32,
}

// Encoded command stream slice ready for validation or submission.
Gpu_Command_Stream :: struct {
	bytes: []u8,
}

// Zero-allocation encoder that appends 48-byte command records into caller memory.
Gpu_Command_Encoder :: struct {
	storage:       []u8,
	used_bytes:    int,
	command_count: u32,
}

// Summary counts produced by a passing stream_validate run.
Stream_Summary :: struct {
	command_count:     u32,
	render_pass_count: u32,
	draw_call_count:   u32,
	copy_count:        u32,
}

// Clear color stored as 4 IEEE-754 float32 bit patterns.
Clear_Color :: struct {
	r_bits: u32,
	g_bits: u32,
	b_bits: u32,
	a_bits: u32,
}

// Border conversions from wire words to closed enumerations.

buffer_usage_of_word :: proc "contextless" (word: u32) -> (usage: Buffer_Usage, ok: bool) {
	known := transmute(u32)(Buffer_Usage{.Vertex, .Index, .Uniform, .Storage, .Copy_Src, .Copy_Dst})
	if word & ~known != 0 {
		return {}, false
	}
	return transmute(Buffer_Usage)word, true
}

texture_usage_of_word :: proc "contextless" (word: u32) -> (usage: Texture_Usage, ok: bool) {
	known := transmute(u32)(Texture_Usage{.Copy_Src, .Copy_Dst, .Texture_Binding, .Storage_Binding, .Render_Attachment})
	if word & ~known != 0 {
		return {}, false
	}
	return transmute(Texture_Usage)word, true
}

texture_format_of_word :: proc "contextless" (word: u32) -> (format: Texture_Format, ok: bool) {
	decoded, found := enum_word.member_of_word(Texture_Format, u64(word))
	if !found || decoded == .None {
		return .None, false
	}
	return decoded, true
}

primitive_topology_of_word :: proc "contextless" (word: u32) -> (topology: Primitive_Topology, ok: bool) {
	decoded, found := enum_word.member_of_word(Primitive_Topology, u64(word))
	if !found || decoded == .None {
		return .None, false
	}
	return decoded, true
}

blend_factor_of_word :: proc "contextless" (word: u32) -> (factor: Blend_Factor, ok: bool) {
	return enum_word.member_of_word(Blend_Factor, u64(word))
}

load_op_of_word :: proc "contextless" (word: u32) -> (op: Load_Op, ok: bool) {
	decoded, found := enum_word.member_of_word(Load_Op, u64(word))
	if !found || decoded == .None {
		return .None, false
	}
	return decoded, true
}

store_op_of_word :: proc "contextless" (word: u32) -> (op: Store_Op, ok: bool) {
	decoded, found := enum_word.member_of_word(Store_Op, u64(word))
	if !found || decoded == .None {
		return .None, false
	}
	return decoded, true
}

index_format_of_word :: proc "contextless" (word: u32) -> (format: Index_Format, ok: bool) {
	decoded, found := enum_word.member_of_word(Index_Format, u64(word))
	if !found || decoded == .None {
		return .None, false
	}
	return decoded, true
}

gpu_command_kind_of_word :: proc "contextless" (word: u32) -> (kind: Gpu_Command_Kind, ok: bool) {
	decoded, found := enum_word.member_of_word(Gpu_Command_Kind, u64(word))
	if !found || decoded == .None {
		return .None, false
	}
	return decoded, true
}

// texture_format_bytes_per_pixel returns the texel byte width for color formats,
// or 0 for None / Depth24_Plus (which cannot be directly buffer-copied).
texture_format_bytes_per_pixel :: proc "contextless" (format: Texture_Format) -> u32 {
	switch format {
	case .None, .Depth24_Plus:
		return 0
	case .R8_Unorm:
		return 1
	case .BGRA8_Unorm, .RGBA8_Unorm, .RGBA8_Unorm_Srgb:
		return 4
	}
	return 0
}

// index_format_byte_stride returns the byte width of one index element.
index_format_byte_stride :: proc "contextless" (format: Index_Format) -> u64 {
	switch format {
	case .None:
		return 0
	case .Uint16:
		return 2
	case .Uint32:
		return 4
	}
	return 0
}

// spirv_header_validate checks a precompiled SPIR-V binary word slice: exact
// magic number, SPIR-V 1.0..1.6 version word, non-zero ID bound, zero reserved
// schema, and valid instruction word counts spanning the entire module.
spirv_header_validate :: proc "contextless" (words: []u32) -> (info: Spirv_Header_Info, refusal: Gpu_Refusal) {
	if len(words) < SPIRV_HEADER_WORDS {
		return {}, .Spirv_Too_Short
	}
	if words[0] != SPIRV_MAGIC {
		return {}, .Spirv_Bad_Magic
	}
	version_word := words[1]
	if version_word & 0xFF00_00FF != 0 {
		return {}, .Spirv_Bad_Version
	}
	major := (version_word >> 16) & 0xFF
	minor := (version_word >> 8) & 0xFF
	if major != 1 || minor > SPIRV_MAX_MINOR_VERSION {
		return {}, .Spirv_Bad_Version
	}
	id_bound := words[3]
	if id_bound == 0 {
		return {}, .Spirv_Zero_Bound
	}
	if words[4] != 0 {
		return {}, .Spirv_Non_Zero_Schema
	}
	if len(words) == SPIRV_HEADER_WORDS {
		return {}, .Spirv_No_Instructions
	}

	instruction_count: u32 = 0
	cursor := SPIRV_HEADER_WORDS
	for cursor < len(words) {
		instruction_word := words[cursor]
		word_count := int(instruction_word >> 16)
		if word_count == 0 {
			return {}, .Spirv_Bad_Instruction_Word_Count
		}
		if word_count > len(words) - cursor {
			return {}, .Spirv_Truncated_Instruction
		}
		cursor += word_count
		instruction_count += 1
	}

	return Spirv_Header_Info{
		version_major     = major,
		version_minor     = minor,
		generator         = words[2],
		id_bound          = id_bound,
		instruction_count = instruction_count,
	}, .None
}

// spirv_bytes_validate validates a little-endian SPIR-V byte slice without allocating.
spirv_bytes_validate :: proc "contextless" (bytes: []u8) -> (info: Spirv_Header_Info, refusal: Gpu_Refusal) {
	if len(bytes) % 4 != 0 {
		return {}, .Spirv_Unaligned_Byte_Length
	}
	word_len := len(bytes) / 4
	if word_len < SPIRV_HEADER_WORDS {
		return {}, .Spirv_Too_Short
	}
	magic := byte_order.read_u32_little_endian(bytes, 0)
	if magic != SPIRV_MAGIC {
		return {}, .Spirv_Bad_Magic
	}
	version_word := byte_order.read_u32_little_endian(bytes, 4)
	if version_word & 0xFF00_00FF != 0 {
		return {}, .Spirv_Bad_Version
	}
	major := (version_word >> 16) & 0xFF
	minor := (version_word >> 8) & 0xFF
	if major != 1 || minor > SPIRV_MAX_MINOR_VERSION {
		return {}, .Spirv_Bad_Version
	}
	generator := byte_order.read_u32_little_endian(bytes, 8)
	id_bound := byte_order.read_u32_little_endian(bytes, 12)
	if id_bound == 0 {
		return {}, .Spirv_Zero_Bound
	}
	if byte_order.read_u32_little_endian(bytes, 16) != 0 {
		return {}, .Spirv_Non_Zero_Schema
	}
	if word_len == SPIRV_HEADER_WORDS {
		return {}, .Spirv_No_Instructions
	}

	instruction_count: u32 = 0
	cursor := SPIRV_HEADER_WORDS
	for cursor < word_len {
		instruction_word := byte_order.read_u32_little_endian(bytes, cursor * 4)
		word_count := int(instruction_word >> 16)
		if word_count == 0 {
			return {}, .Spirv_Bad_Instruction_Word_Count
		}
		if word_count > word_len - cursor {
			return {}, .Spirv_Truncated_Instruction
		}
		cursor += word_count
		instruction_count += 1
	}

	return Spirv_Header_Info{
		version_major     = major,
		version_minor     = minor,
		generator         = generator,
		id_bound          = id_bound,
		instruction_count = instruction_count,
	}, .None
}

// Command stream encoder helpers.

encoder_init :: proc "contextless" (storage: []u8) -> Gpu_Command_Encoder {
	return Gpu_Command_Encoder{storage = storage}
}

encoder_finish :: proc "contextless" (encoder: ^Gpu_Command_Encoder) -> Gpu_Command_Stream {
	return Gpu_Command_Stream{bytes = encoder.storage[:encoder.used_bytes]}
}

@(private = "file")
encoder_reserve_record :: proc "contextless" (encoder: ^Gpu_Command_Encoder, kind: Gpu_Command_Kind) -> (slot: []u8, refusal: Gpu_Refusal) {
	if encoder.used_bytes < 0 || len(encoder.storage) - encoder.used_bytes < COMMAND_RECORD_SIZE {
		return nil, .Encoder_Buffer_Full
	}
	if encoder.command_count >= MAX_COMMAND_STREAM_COMMANDS {
		return nil, .Stream_Too_Large
	}
	slot = encoder.storage[encoder.used_bytes : encoder.used_bytes + COMMAND_RECORD_SIZE]
	for index in 0 ..< COMMAND_RECORD_SIZE {
		slot[index] = 0
	}
	byte_order.write_u32_little_endian(slot, 0, u32(kind))
	byte_order.write_u32_little_endian(slot, 4, 0)
	encoder.used_bytes += COMMAND_RECORD_SIZE
	encoder.command_count += 1
	return slot, .None
}

encode_begin_render_pass :: proc "contextless" (encoder: ^Gpu_Command_Encoder, color_texture_id, depth_texture_id: u32, load_op: Load_Op, store_op: Store_Op, clear: Clear_Color = {}) -> Gpu_Refusal {
	slot, refusal := encoder_reserve_record(encoder, .Begin_Render_Pass)
	if refusal != .None {
		return refusal
	}
	byte_order.write_u32_little_endian(slot, 8, color_texture_id)
	byte_order.write_u32_little_endian(slot, 12, depth_texture_id)
	byte_order.write_u32_little_endian(slot, 16, u32(load_op))
	byte_order.write_u32_little_endian(slot, 20, u32(store_op))
	byte_order.write_u32_little_endian(slot, 24, clear.r_bits)
	byte_order.write_u32_little_endian(slot, 28, clear.g_bits)
	byte_order.write_u32_little_endian(slot, 32, clear.b_bits)
	byte_order.write_u32_little_endian(slot, 36, clear.a_bits)
	return .None
}

encode_set_pipeline :: proc "contextless" (encoder: ^Gpu_Command_Encoder, pipeline_id: u32) -> Gpu_Refusal {
	slot, refusal := encoder_reserve_record(encoder, .Set_Pipeline)
	if refusal != .None {
		return refusal
	}
	byte_order.write_u32_little_endian(slot, 8, pipeline_id)
	return .None
}

encode_set_vertex_buffer :: proc "contextless" (encoder: ^Gpu_Command_Encoder, slot_index: u32, buffer_id: u32, offset, size: u64) -> Gpu_Refusal {
	slot, refusal := encoder_reserve_record(encoder, .Set_Vertex_Buffer)
	if refusal != .None {
		return refusal
	}
	byte_order.write_u32_little_endian(slot, 8, slot_index)
	byte_order.write_u32_little_endian(slot, 12, buffer_id)
	byte_order.write_u64_little_endian(slot, 16, offset)
	byte_order.write_u64_little_endian(slot, 24, size)
	return .None
}

encode_set_index_buffer :: proc "contextless" (encoder: ^Gpu_Command_Encoder, buffer_id: u32, index_format: Index_Format, offset, size: u64) -> Gpu_Refusal {
	slot, refusal := encoder_reserve_record(encoder, .Set_Index_Buffer)
	if refusal != .None {
		return refusal
	}
	byte_order.write_u32_little_endian(slot, 8, buffer_id)
	byte_order.write_u32_little_endian(slot, 12, u32(index_format))
	byte_order.write_u64_little_endian(slot, 16, offset)
	byte_order.write_u64_little_endian(slot, 24, size)
	return .None
}

encode_set_bind_group :: proc "contextless" (encoder: ^Gpu_Command_Encoder, slot_index: u32, bind_group_id: u32) -> Gpu_Refusal {
	slot, refusal := encoder_reserve_record(encoder, .Set_Bind_Group)
	if refusal != .None {
		return refusal
	}
	byte_order.write_u32_little_endian(slot, 8, slot_index)
	byte_order.write_u32_little_endian(slot, 12, bind_group_id)
	return .None
}

encode_set_scissor_rect :: proc "contextless" (encoder: ^Gpu_Command_Encoder, x, y, width, height: u32) -> Gpu_Refusal {
	slot, refusal := encoder_reserve_record(encoder, .Set_Scissor_Rect)
	if refusal != .None {
		return refusal
	}
	byte_order.write_u32_little_endian(slot, 8, x)
	byte_order.write_u32_little_endian(slot, 12, y)
	byte_order.write_u32_little_endian(slot, 16, width)
	byte_order.write_u32_little_endian(slot, 20, height)
	return .None
}

encode_draw :: proc "contextless" (encoder: ^Gpu_Command_Encoder, vertex_count, instance_count, first_vertex, first_instance: u32) -> Gpu_Refusal {
	slot, refusal := encoder_reserve_record(encoder, .Draw)
	if refusal != .None {
		return refusal
	}
	byte_order.write_u32_little_endian(slot, 8, vertex_count)
	byte_order.write_u32_little_endian(slot, 12, instance_count)
	byte_order.write_u32_little_endian(slot, 16, first_vertex)
	byte_order.write_u32_little_endian(slot, 20, first_instance)
	return .None
}

encode_draw_indexed :: proc "contextless" (encoder: ^Gpu_Command_Encoder, index_count, instance_count, first_index: u32, base_vertex: i32, first_instance: u32) -> Gpu_Refusal {
	slot, refusal := encoder_reserve_record(encoder, .Draw_Indexed)
	if refusal != .None {
		return refusal
	}
	byte_order.write_u32_little_endian(slot, 8, index_count)
	byte_order.write_u32_little_endian(slot, 12, instance_count)
	byte_order.write_u32_little_endian(slot, 16, first_index)
	byte_order.write_u32_little_endian(slot, 20, u32(base_vertex))
	byte_order.write_u32_little_endian(slot, 24, first_instance)
	return .None
}

encode_end_render_pass :: proc "contextless" (encoder: ^Gpu_Command_Encoder) -> Gpu_Refusal {
	_, refusal := encoder_reserve_record(encoder, .End_Render_Pass)
	return refusal
}

encode_copy_buffer_to_buffer :: proc "contextless" (encoder: ^Gpu_Command_Encoder, src_buffer_id, dst_buffer_id: u32, src_offset, dst_offset, size: u64) -> Gpu_Refusal {
	slot, refusal := encoder_reserve_record(encoder, .Copy_Buffer_To_Buffer)
	if refusal != .None {
		return refusal
	}
	byte_order.write_u32_little_endian(slot, 8, src_buffer_id)
	byte_order.write_u32_little_endian(slot, 12, dst_buffer_id)
	byte_order.write_u64_little_endian(slot, 16, src_offset)
	byte_order.write_u64_little_endian(slot, 24, dst_offset)
	byte_order.write_u64_little_endian(slot, 32, size)
	return .None
}

encode_copy_buffer_to_texture :: proc "contextless" (encoder: ^Gpu_Command_Encoder, src_buffer_id, dst_texture_id: u32, src_offset: u64, bytes_per_row, dst_x, dst_y, width, height: u32) -> Gpu_Refusal {
	slot, refusal := encoder_reserve_record(encoder, .Copy_Buffer_To_Texture)
	if refusal != .None {
		return refusal
	}
	byte_order.write_u32_little_endian(slot, 8, src_buffer_id)
	byte_order.write_u32_little_endian(slot, 12, dst_texture_id)
	byte_order.write_u64_little_endian(slot, 16, src_offset)
	byte_order.write_u32_little_endian(slot, 24, bytes_per_row)
	byte_order.write_u32_little_endian(slot, 28, dst_x)
	byte_order.write_u32_little_endian(slot, 32, dst_y)
	byte_order.write_u32_little_endian(slot, 36, width)
	byte_order.write_u32_little_endian(slot, 40, height)
	return .None
}

@(private = "file")
range_fits_u64 :: proc "contextless" (offset, size, total: u64) -> bool {
	return offset <= total && size <= total - offset
}

@(private = "file")
buffer_lookup :: proc "contextless" (resources: Resource_Registry, buffer_id: u32) -> (desc: Buffer_Desc, refusal: Gpu_Refusal) {
	if buffer_id == 0 {
		return {}, .Zero_Object_Id
	}
	if int(buffer_id) > len(resources.buffers) {
		return {}, .Object_Id_Out_Of_Range
	}
	return resources.buffers[buffer_id - 1], .None
}

@(private = "file")
texture_lookup :: proc "contextless" (resources: Resource_Registry, texture_id: u32) -> (desc: Texture_Desc, refusal: Gpu_Refusal) {
	if texture_id == 0 {
		return {}, .Zero_Object_Id
	}
	if int(texture_id) > len(resources.textures) {
		return {}, .Object_Id_Out_Of_Range
	}
	desc = resources.textures[texture_id - 1]
	if desc.width == 0 || desc.height == 0 {
		return {}, .Zero_Extent
	}
	if desc.width > MAX_TEXTURE_DIMENSION || desc.height > MAX_TEXTURE_DIMENSION {
		return {}, .Dimension_Too_Large
	}
	if _, format_ok := texture_format_of_word(u32(desc.format)); !format_ok {
		return {}, .Unknown_Enum_Word
	}
	return desc, .None
}

@(private = "file")
pipeline_lookup :: proc "contextless" (resources: Resource_Registry, pipeline_id: u32) -> (desc: Pipeline_Desc, refusal: Gpu_Refusal) {
	if pipeline_id == 0 {
		return {}, .Zero_Object_Id
	}
	if int(pipeline_id) > len(resources.pipelines) {
		return {}, .Object_Id_Out_Of_Range
	}
	desc = resources.pipelines[pipeline_id - 1]
	if _, topo_ok := primitive_topology_of_word(u32(desc.topology)); !topo_ok {
		return {}, .Unknown_Enum_Word
	}
	if _, fmt_ok := texture_format_of_word(u32(desc.color_format)); !fmt_ok {
		return {}, .Unknown_Enum_Word
	}
	if _, src_ok := blend_factor_of_word(u32(desc.src_blend)); !src_ok {
		return {}, .Unknown_Enum_Word
	}
	if _, dst_ok := blend_factor_of_word(u32(desc.dst_blend)); !dst_ok {
		return {}, .Unknown_Enum_Word
	}
	return desc, .None
}

// stream_validate verifies an encoded Gpu_Command_Stream end-to-end against
// declared resources: closed command words, balanced render passes, draw and
// copy placement, bound pipelines and buffers, scissor rectangles, and byte ranges.
stream_validate :: proc "contextless" (stream: Gpu_Command_Stream, resources: Resource_Registry) -> (summary: Stream_Summary, refusal: Gpu_Refusal) {
	if len(stream.bytes) % COMMAND_RECORD_SIZE != 0 {
		return {}, .Stream_Truncated
	}
	if len(stream.bytes) > MAX_COMMAND_STREAM_BYTES {
		return {}, .Stream_Too_Large
	}

	in_render_pass := false
	pass_width: u32 = 0
	pass_height: u32 = 0
	pass_color_format: Texture_Format = .None

	has_pipeline := false
	active_pipeline: Pipeline_Desc

	vertex_bound: [MAX_VERTEX_BUFFER_SLOTS]bool
	vertex_sizes: [MAX_VERTEX_BUFFER_SLOTS]u64

	has_index_buffer := false
	index_stride: u64 = 0
	index_buffer_size: u64 = 0

	record_count := len(stream.bytes) / COMMAND_RECORD_SIZE
	for index in 0 ..< record_count {
		record := stream.bytes[index * COMMAND_RECORD_SIZE : (index + 1) * COMMAND_RECORD_SIZE]
		kind_word := byte_order.read_u32_little_endian(record, 0)
		reserved := byte_order.read_u32_little_endian(record, 4)
		if reserved != 0 {
			return {}, .Non_Zero_Reserved
		}
		kind, kind_ok := gpu_command_kind_of_word(kind_word)
		if !kind_ok {
			return {}, .Unknown_Command_Kind
		}

		switch kind {
		case .None:
			return {}, .Unknown_Command_Kind

		case .Begin_Render_Pass:
			if in_render_pass {
				return {}, .Render_Pass_Already_Active
			}
			color_texture_id := byte_order.read_u32_little_endian(record, 8)
			depth_texture_id := byte_order.read_u32_little_endian(record, 12)
			load_word := byte_order.read_u32_little_endian(record, 16)
			store_word := byte_order.read_u32_little_endian(record, 20)
			if _, load_ok := load_op_of_word(load_word); !load_ok {
				return {}, .Unknown_Enum_Word
			}
			if _, store_ok := store_op_of_word(store_word); !store_ok {
				return {}, .Unknown_Enum_Word
			}
			color_desc, color_refusal := texture_lookup(resources, color_texture_id)
			if color_refusal != .None {
				return {}, color_refusal
			}
			if .Render_Attachment not_in color_desc.usage {
				return {}, .Missing_Usage_Flag
			}
			if color_desc.format == .Depth24_Plus {
				return {}, .Format_Mismatch
			}
			if depth_texture_id != 0 {
				depth_desc, depth_refusal := texture_lookup(resources, depth_texture_id)
				if depth_refusal != .None {
					return {}, depth_refusal
				}
				if .Render_Attachment not_in depth_desc.usage {
					return {}, .Missing_Usage_Flag
				}
				if depth_desc.format != .Depth24_Plus || depth_desc.width != color_desc.width || depth_desc.height != color_desc.height {
					return {}, .Format_Mismatch
				}
			}
			in_render_pass = true
			pass_width = color_desc.width
			pass_height = color_desc.height
			pass_color_format = color_desc.format
			has_pipeline = false
			active_pipeline = {}
			vertex_bound = {}
			vertex_sizes = {}
			has_index_buffer = false
			index_stride = 0
			index_buffer_size = 0
			summary.render_pass_count += 1

		case .Set_Pipeline:
			if !in_render_pass {
				return {}, .Render_Pass_Not_Active
			}
			pipeline_id := byte_order.read_u32_little_endian(record, 8)
			pipeline_desc, pipe_refusal := pipeline_lookup(resources, pipeline_id)
			if pipe_refusal != .None {
				return {}, pipe_refusal
			}
			if pipeline_desc.color_format != pass_color_format {
				return {}, .Format_Mismatch
			}
			has_pipeline = true
			active_pipeline = pipeline_desc

		case .Set_Vertex_Buffer:
			if !in_render_pass {
				return {}, .Render_Pass_Not_Active
			}
			slot_index := byte_order.read_u32_little_endian(record, 8)
			buffer_id := byte_order.read_u32_little_endian(record, 12)
			offset := byte_order.read_u64_little_endian(record, 16)
			size := byte_order.read_u64_little_endian(record, 24)
			if slot_index >= MAX_VERTEX_BUFFER_SLOTS {
				return {}, .Invalid_Slot
			}
			buf_desc, buf_refusal := buffer_lookup(resources, buffer_id)
			if buf_refusal != .None {
				return {}, buf_refusal
			}
			if .Vertex not_in buf_desc.usage {
				return {}, .Missing_Usage_Flag
			}
			if size == 0 || !range_fits_u64(offset, size, buf_desc.size) {
				return {}, .Vertex_Range_Out_Of_Bounds
			}
			vertex_bound[slot_index] = true
			vertex_sizes[slot_index] = size

		case .Set_Index_Buffer:
			if !in_render_pass {
				return {}, .Render_Pass_Not_Active
			}
			buffer_id := byte_order.read_u32_little_endian(record, 8)
			format_word := byte_order.read_u32_little_endian(record, 12)
			offset := byte_order.read_u64_little_endian(record, 16)
			size := byte_order.read_u64_little_endian(record, 24)
			idx_format, fmt_ok := index_format_of_word(format_word)
			if !fmt_ok {
				return {}, .Unknown_Enum_Word
			}
			buf_desc, buf_refusal := buffer_lookup(resources, buffer_id)
			if buf_refusal != .None {
				return {}, buf_refusal
			}
			if .Index not_in buf_desc.usage {
				return {}, .Missing_Usage_Flag
			}
			stride := index_format_byte_stride(idx_format)
			if size == 0 || offset % stride != 0 || size % stride != 0 || !range_fits_u64(offset, size, buf_desc.size) {
				return {}, .Index_Range_Out_Of_Bounds
			}
			has_index_buffer = true
			index_stride = stride
			index_buffer_size = size

		case .Set_Bind_Group:
			if !in_render_pass {
				return {}, .Render_Pass_Not_Active
			}
			slot_index := byte_order.read_u32_little_endian(record, 8)
			bind_group_id := byte_order.read_u32_little_endian(record, 12)
			if slot_index >= MAX_BIND_GROUPS {
				return {}, .Invalid_Slot
			}
			if bind_group_id == 0 {
				return {}, .Zero_Object_Id
			}
			if bind_group_id > resources.bind_group_count {
				return {}, .Object_Id_Out_Of_Range
			}

		case .Set_Scissor_Rect:
			if !in_render_pass {
				return {}, .Render_Pass_Not_Active
			}
			x := byte_order.read_u32_little_endian(record, 8)
			y := byte_order.read_u32_little_endian(record, 12)
			width := byte_order.read_u32_little_endian(record, 16)
			height := byte_order.read_u32_little_endian(record, 20)
			if width == 0 || height == 0 {
				return {}, .Zero_Extent
			}
			if u64(x) + u64(width) > u64(pass_width) || u64(y) + u64(height) > u64(pass_height) {
				return {}, .Scissor_Rect_Out_Of_Bounds
			}

		case .Draw:
			if !in_render_pass {
				return {}, .Render_Pass_Not_Active
			}
			if !has_pipeline {
				return {}, .Missing_Pipeline
			}
			vertex_count := byte_order.read_u32_little_endian(record, 8)
			instance_count := byte_order.read_u32_little_endian(record, 12)
			first_vertex := byte_order.read_u32_little_endian(record, 16)
			if vertex_count == 0 || instance_count == 0 {
				return {}, .Zero_Draw_Count
			}
			end_vertex := u64(first_vertex) + u64(vertex_count)
			if end_vertex > u64(max(u32)) {
				return {}, .Vertex_Range_Out_Of_Bounds
			}
			if active_pipeline.vertex_stride > 0 {
				if !vertex_bound[0] {
					return {}, .Missing_Vertex_Buffer
				}
				stride := u64(active_pipeline.vertex_stride)
				if end_vertex > max(u64) / stride || end_vertex * stride > vertex_sizes[0] {
					return {}, .Vertex_Range_Out_Of_Bounds
				}
			}
			summary.draw_call_count += 1

		case .Draw_Indexed:
			if !in_render_pass {
				return {}, .Render_Pass_Not_Active
			}
			if !has_pipeline {
				return {}, .Missing_Pipeline
			}
			if !has_index_buffer {
				return {}, .Missing_Index_Buffer
			}
			index_count := byte_order.read_u32_little_endian(record, 8)
			instance_count := byte_order.read_u32_little_endian(record, 12)
			first_index := byte_order.read_u32_little_endian(record, 16)
			if index_count == 0 || instance_count == 0 {
				return {}, .Zero_Draw_Count
			}
			end_index := u64(first_index) + u64(index_count)
			if end_index > max(u64) / index_stride || end_index * index_stride > index_buffer_size {
				return {}, .Index_Range_Out_Of_Bounds
			}
			if active_pipeline.vertex_stride > 0 && !vertex_bound[0] {
				return {}, .Missing_Vertex_Buffer
			}
			summary.draw_call_count += 1

		case .End_Render_Pass:
			if !in_render_pass {
				return {}, .Render_Pass_Not_Active
			}
			in_render_pass = false
			pass_width = 0
			pass_height = 0
			pass_color_format = .None
			has_pipeline = false
			active_pipeline = {}
			vertex_bound = {}
			vertex_sizes = {}
			has_index_buffer = false
			index_stride = 0
			index_buffer_size = 0

		case .Copy_Buffer_To_Buffer:
			if in_render_pass {
				return {}, .Copy_Inside_Render_Pass
			}
			src_buffer_id := byte_order.read_u32_little_endian(record, 8)
			dst_buffer_id := byte_order.read_u32_little_endian(record, 12)
			src_offset := byte_order.read_u64_little_endian(record, 16)
			dst_offset := byte_order.read_u64_little_endian(record, 24)
			size := byte_order.read_u64_little_endian(record, 32)
			src_desc, src_refusal := buffer_lookup(resources, src_buffer_id)
			if src_refusal != .None {
				return {}, src_refusal
			}
			dst_desc, dst_refusal := buffer_lookup(resources, dst_buffer_id)
			if dst_refusal != .None {
				return {}, dst_refusal
			}
			if .Copy_Src not_in src_desc.usage || .Copy_Dst not_in dst_desc.usage {
				return {}, .Missing_Usage_Flag
			}
			if size == 0 {
				return {}, .Zero_Extent
			}
			if src_offset % 4 != 0 || dst_offset % 4 != 0 || size % 4 != 0 {
				return {}, .Copy_Alignment_Invalid
			}
			if !range_fits_u64(src_offset, size, src_desc.size) || !range_fits_u64(dst_offset, size, dst_desc.size) {
				return {}, .Copy_Range_Out_Of_Bounds
			}
			summary.copy_count += 1

		case .Copy_Buffer_To_Texture:
			if in_render_pass {
				return {}, .Copy_Inside_Render_Pass
			}
			src_buffer_id := byte_order.read_u32_little_endian(record, 8)
			dst_texture_id := byte_order.read_u32_little_endian(record, 12)
			src_offset := byte_order.read_u64_little_endian(record, 16)
			bytes_per_row := byte_order.read_u32_little_endian(record, 24)
			dst_x := byte_order.read_u32_little_endian(record, 28)
			dst_y := byte_order.read_u32_little_endian(record, 32)
			width := byte_order.read_u32_little_endian(record, 36)
			height := byte_order.read_u32_little_endian(record, 40)
			src_desc, src_refusal := buffer_lookup(resources, src_buffer_id)
			if src_refusal != .None {
				return {}, src_refusal
			}
			dst_desc, dst_refusal := texture_lookup(resources, dst_texture_id)
			if dst_refusal != .None {
				return {}, dst_refusal
			}
			if .Copy_Src not_in src_desc.usage || .Copy_Dst not_in dst_desc.usage {
				return {}, .Missing_Usage_Flag
			}
			if width == 0 || height == 0 {
				return {}, .Zero_Extent
			}
			bpp := texture_format_bytes_per_pixel(dst_desc.format)
			if bpp == 0 {
				return {}, .Format_Mismatch
			}
			if u64(dst_x) + u64(width) > u64(dst_desc.width) || u64(dst_y) + u64(height) > u64(dst_desc.height) {
				return {}, .Copy_Range_Out_Of_Bounds
			}
			row_bytes := u64(width) * u64(bpp)
			if u64(bytes_per_row) < row_bytes {
				return {}, .Copy_Range_Out_Of_Bounds
			}
			// Source span covers (height - 1) full strides plus the final row width.
			needed_bytes := u64(height - 1) * u64(bytes_per_row) + row_bytes
			if !range_fits_u64(src_offset, needed_bytes, src_desc.size) {
				return {}, .Copy_Range_Out_Of_Bounds
			}
			summary.copy_count += 1
		}

		summary.command_count += 1
	}

	if in_render_pass {
		return {}, .Unbalanced_Render_Pass
	}
	return summary, .None
}
