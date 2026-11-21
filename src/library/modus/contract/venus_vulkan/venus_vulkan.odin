// The Venus Vulkan wire protocol contract for GPU command serialization over
// VirtIO-GPU Submit_3D and shared-memory blob rings (src/md/features/gpu_access.md).
//
// Every command packet is 4-byte aligned, little-endian, and starts with a
// 16-byte header (command_type, flags, payload_bytes, reserved == 0) followed
// by aligned 64-bit Vulkan object handle identifiers and fixed or bounded
// payloads. All wire words cross one border into closed enumerations.
//
// This package allocates no memory and calls no kernel operation.
package venus_vulkan

import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/virtio_gpu"
import "modus:contract/webgpu_subset"

// Wire framing sizes and strict protocol bounds.
COMMAND_HEADER_SIZE :: 16
MAX_STREAM_BYTES :: virtio_gpu.MAX_SUBMIT_3D_BYTES
MAX_COMMAND_PAYLOAD_BYTES :: MAX_STREAM_BYTES - COMMAND_HEADER_SIZE
MAX_SPIRV_WORDS :: 16000
MAX_SPIRV_BYTES :: MAX_SPIRV_WORDS * 4
MAX_PHYSICAL_DEVICES :: 16
MAX_QUEUE_FAMILIES :: 16
MAX_IMAGE_DIMENSION :: webgpu_subset.MAX_TEXTURE_DIMENSION
MAX_VERTEX_BUFFER_SLOTS :: webgpu_subset.MAX_VERTEX_BUFFER_SLOTS
MAX_BIND_GROUPS :: webgpu_subset.MAX_BIND_GROUPS

// Shared-memory blob ring framing constants.
VENUS_RING_MAGIC :: u32(0x564E_5553) // "VNUS"
VENUS_RING_VERSION :: u32(1)
VENUS_RING_HEADER_SIZE :: 64
MIN_RING_BUFFER_SIZE :: u32(256)
MAX_RING_BUFFER_SIZE :: u32(4 * 1024 * 1024)

// Closed set of Venus Vulkan command type words. Word 0 names no command.
Venus_Command_Type :: enum u32 {
	Set_Reply_Command_Stream   = 1,
	Create_Instance            = 2,
	Destroy_Instance           = 3,
	Enumerate_Physical_Devices = 4,
	Create_Device              = 5,
	Destroy_Device             = 6,
	Allocate_Memory            = 7,
	Free_Memory                = 8,
	Create_Buffer              = 9,
	Create_Image               = 10,
	Create_Shader_Module       = 11,
	Create_Render_Pass         = 12,
	Create_Graphics_Pipelines  = 13,
	Allocate_Command_Buffers   = 14,
	Begin_Command_Buffer       = 15,
	Cmd_Begin_Render_Pass      = 16,
	Cmd_Bind_Pipeline          = 17,
	Cmd_Set_Scissor            = 18,
	Cmd_Bind_Vertex_Buffers    = 19,
	Cmd_Bind_Index_Buffer      = 20,
	Cmd_Bind_Descriptor_Sets   = 21,
	Cmd_Draw                   = 22,
	Cmd_Draw_Indexed           = 23,
	Cmd_End_Render_Pass        = 24,
	End_Command_Buffer         = 25,
	Cmd_Copy_Buffer            = 26,
	Cmd_Copy_Buffer_To_Image   = 27,
	Queue_Submit               = 28,
	Queue_Wait_Idle            = 29,
	Ring_Notify                = 30,
}

// Per-command Venus wire header flags.
Venus_Command_Flag :: enum u32 {
	Generate_Reply = 0,
}

Venus_Command_Flags :: bit_set[Venus_Command_Flag; u32]

// Closed set of shared-memory Venus ring status words.
Venus_Ring_Status :: enum u32 {
	Idle   = 0,
	Active = 1,
	Fatal  = 2,
}

// Why a Venus encoder, decoder, ring validator, or translator refused an input.
Venus_Problem :: enum u8 {
	None = 0,
	Buffer_Too_Short,
	Stream_Empty,
	Stream_Too_Large,
	Misaligned_Length,
	Unknown_Command_Type,
	Unknown_Command_Flags,
	Non_Zero_Reserved,
	Payload_Size_Mismatch,
	Zero_Handle_Id,
	Zero_Extent,
	Dimension_Too_Large,
	Zero_Draw_Count,
	Invalid_Slot,
	Count_Out_Of_Range,
	Unknown_Enum_Word,
	Unknown_Usage_Bits,
	Spirv_Too_Large,
	Invalid_Spirv,
	Command_Buffer_Already_Active,
	Command_Buffer_Not_Active,
	Command_Buffer_Mismatch,
	Unbalanced_Command_Buffer,
	Render_Pass_Already_Active,
	Render_Pass_Not_Active,
	Unbalanced_Render_Pass,
	Copy_Inside_Render_Pass,
	Ring_Bad_Magic,
	Ring_Bad_Version,
	Ring_Invalid_Status,
	Ring_Invalid_Buffer_Size,
	Ring_Head_Out_Of_Bounds,
	Ring_Tail_Out_Of_Bounds,
	Ring_Offset_Out_Of_Bounds,
	Ring_Non_Zero_Reserved,
	Webgpu_Stream_Invalid,
	Virtio_Frame_Invalid,
}

// Shared-memory ring header laid out in the first 64 bytes of a Venus blob resource.
Venus_Ring_Header :: struct {
	magic:         u32,
	version:       u32,
	head:          u32,
	tail:          u32,
	status:        Venus_Ring_Status,
	buffer_size:   u32,
	buffer_offset: u32,
	extra_offset:  u32,
	extra_size:    u32,
	ring_id:       u64,
}

// Decoded 16-byte Venus wire command header.
Venus_Command_Header :: struct {
	command_type:  Venus_Command_Type,
	flags:         Venus_Command_Flags,
	payload_bytes: u32,
}

// Fixed-size typed command payloads (all Vulkan object IDs are non-zero u64 handles).

Set_Reply_Command_Stream_Payload :: struct {
	stream_resource_id: u32,
	offset:             u32,
	size:               u32,
}

Create_Instance_Payload :: struct {
	instance_id: u64,
	api_version: u32,
}

Destroy_Instance_Payload :: struct {
	instance_id: u64,
}

Enumerate_Physical_Devices_Payload :: struct {
	instance_id:      u64,
	max_device_count: u32,
}

Create_Device_Payload :: struct {
	physical_device_id: u64,
	device_id:          u64,
	queue_family_index: u32,
	queue_count:        u32,
}

Destroy_Device_Payload :: struct {
	device_id: u64,
}

Allocate_Memory_Payload :: struct {
	device_id:         u64,
	memory_id:         u64,
	allocation_size:   u64,
	memory_type_index: u32,
}

Free_Memory_Payload :: struct {
	device_id: u64,
	memory_id: u64,
}

Create_Buffer_Payload :: struct {
	device_id: u64,
	buffer_id: u64,
	size:      u64,
	usage:     webgpu_subset.Buffer_Usage,
}

Create_Image_Payload :: struct {
	device_id: u64,
	image_id:  u64,
	width:     u32,
	height:    u32,
	format:    webgpu_subset.Texture_Format,
	usage:     webgpu_subset.Texture_Usage,
}

Create_Shader_Module_Payload :: struct {
	device_id:        u64,
	shader_module_id: u64,
	spirv_bytes:      []u8,
	spirv_info:       webgpu_subset.Spirv_Header_Info,
}

Create_Render_Pass_Payload :: struct {
	device_id:       u64,
	render_pass_id:  u64,
	color_format:    webgpu_subset.Texture_Format,
	has_depth:       bool,
	load_op:         webgpu_subset.Load_Op,
	store_op:        webgpu_subset.Store_Op,
}

Create_Graphics_Pipelines_Payload :: struct {
	device_id:          u64,
	pipeline_id:        u64,
	render_pass_id:     u64,
	vertex_shader_id:   u64,
	fragment_shader_id: u64,
	topology:           webgpu_subset.Primitive_Topology,
	src_blend:          webgpu_subset.Blend_Factor,
	dst_blend:          webgpu_subset.Blend_Factor,
	vertex_stride:      u32,
}

Allocate_Command_Buffers_Payload :: struct {
	device_id:         u64,
	command_pool_id:   u64,
	command_buffer_id: u64,
}

Begin_Command_Buffer_Payload :: struct {
	command_buffer_id: u64,
}

Cmd_Begin_Render_Pass_Payload :: struct {
	command_buffer_id: u64,
	render_pass_id:    u64,
	framebuffer_id:    u64,
	render_x:          u32,
	render_y:          u32,
	render_width:      u32,
	render_height:     u32,
	clear_color:       webgpu_subset.Clear_Color,
}

Cmd_Bind_Pipeline_Payload :: struct {
	command_buffer_id: u64,
	pipeline_id:       u64,
}

Cmd_Set_Scissor_Payload :: struct {
	command_buffer_id: u64,
	x:                 u32,
	y:                 u32,
	width:             u32,
	height:            u32,
}

Cmd_Bind_Vertex_Buffers_Payload :: struct {
	command_buffer_id: u64,
	first_binding:     u32,
	buffer_id:         u64,
	offset:            u64,
}

Cmd_Bind_Index_Buffer_Payload :: struct {
	command_buffer_id: u64,
	buffer_id:         u64,
	offset:            u64,
	index_format:      webgpu_subset.Index_Format,
}

Cmd_Bind_Descriptor_Sets_Payload :: struct {
	command_buffer_id: u64,
	set_index:         u32,
	descriptor_set_id: u64,
}

Cmd_Draw_Payload :: struct {
	command_buffer_id: u64,
	vertex_count:      u32,
	instance_count:    u32,
	first_vertex:      u32,
	first_instance:    u32,
}

Cmd_Draw_Indexed_Payload :: struct {
	command_buffer_id: u64,
	index_count:       u32,
	instance_count:    u32,
	first_index:       u32,
	vertex_offset:     i32,
	first_instance:    u32,
}

Cmd_End_Render_Pass_Payload :: struct {
	command_buffer_id: u64,
}

End_Command_Buffer_Payload :: struct {
	command_buffer_id: u64,
}

Cmd_Copy_Buffer_Payload :: struct {
	command_buffer_id: u64,
	src_buffer_id:     u64,
	dst_buffer_id:     u64,
	src_offset:        u64,
	dst_offset:        u64,
	size:              u64,
}

Cmd_Copy_Buffer_To_Image_Payload :: struct {
	command_buffer_id: u64,
	src_buffer_id:     u64,
	dst_image_id:      u64,
	src_offset:        u64,
	bytes_per_row:     u32,
	dst_x:             u32,
	dst_y:             u32,
	width:             u32,
	height:            u32,
}

Queue_Submit_Payload :: struct {
	queue_id:          u64,
	command_buffer_id: u64,
	fence_id:          u64,
}

Queue_Wait_Idle_Payload :: struct {
	queue_id: u64,
}

Ring_Notify_Payload :: struct {
	ring_id: u64,
	seqno:   u32,
}

// Union of all decoded Venus command payloads past the border.
Venus_Payload :: union {
	Set_Reply_Command_Stream_Payload,
	Create_Instance_Payload,
	Destroy_Instance_Payload,
	Enumerate_Physical_Devices_Payload,
	Create_Device_Payload,
	Destroy_Device_Payload,
	Allocate_Memory_Payload,
	Free_Memory_Payload,
	Create_Buffer_Payload,
	Create_Image_Payload,
	Create_Shader_Module_Payload,
	Create_Render_Pass_Payload,
	Create_Graphics_Pipelines_Payload,
	Allocate_Command_Buffers_Payload,
	Begin_Command_Buffer_Payload,
	Cmd_Begin_Render_Pass_Payload,
	Cmd_Bind_Pipeline_Payload,
	Cmd_Set_Scissor_Payload,
	Cmd_Bind_Vertex_Buffers_Payload,
	Cmd_Bind_Index_Buffer_Payload,
	Cmd_Bind_Descriptor_Sets_Payload,
	Cmd_Draw_Payload,
	Cmd_Draw_Indexed_Payload,
	Cmd_End_Render_Pass_Payload,
	End_Command_Buffer_Payload,
	Cmd_Copy_Buffer_Payload,
	Cmd_Copy_Buffer_To_Image_Payload,
	Queue_Submit_Payload,
	Queue_Wait_Idle_Payload,
	Ring_Notify_Payload,
}

// One validated and decoded Venus command packet.
Venus_Decoded_Command :: struct {
	header:  Venus_Command_Header,
	payload: Venus_Payload,
}

// Zero-allocation encoder that appends Venus commands into caller-owned storage.
Venus_Stream_Encoder :: struct {
	storage:       []u8,
	used_bytes:    int,
	command_count: u32,
}

// Summary counts produced by stream_validate.
Venus_Stream_Summary :: struct {
	command_count:     u32,
	render_pass_count: u32,
	draw_call_count:   u32,
	copy_count:        u32,
	submit_count:      u32,
	shader_count:      u32,
}

// Vulkan handle base IDs used when translating a webgpu_subset command stream.
Venus_Translation_Handles :: struct {
	command_buffer_id:    u64,
	queue_id:             u64,
	fence_id:             u64,
	render_pass_id_base:  u64,
	framebuffer_id_base:  u64,
	buffer_id_base:       u64,
	image_id_base:        u64,
	pipeline_id_base:     u64,
	descriptor_set_base:  u64,
}

// Fixed wire payload sizes for each command (0 means variable-size payload).
PAYLOAD_SIZE_SET_REPLY_COMMAND_STREAM :: 16
PAYLOAD_SIZE_CREATE_INSTANCE :: 16
PAYLOAD_SIZE_DESTROY_INSTANCE :: 8
PAYLOAD_SIZE_ENUMERATE_PHYSICAL_DEVICES :: 16
PAYLOAD_SIZE_CREATE_DEVICE :: 24
PAYLOAD_SIZE_DESTROY_DEVICE :: 8
PAYLOAD_SIZE_ALLOCATE_MEMORY :: 32
PAYLOAD_SIZE_FREE_MEMORY :: 16
PAYLOAD_SIZE_CREATE_BUFFER :: 32
PAYLOAD_SIZE_CREATE_IMAGE :: 32
PAYLOAD_SIZE_CREATE_SHADER_MODULE_HEADER :: 24
PAYLOAD_SIZE_CREATE_RENDER_PASS :: 32
PAYLOAD_SIZE_CREATE_GRAPHICS_PIPELINES :: 56
PAYLOAD_SIZE_ALLOCATE_COMMAND_BUFFERS :: 24
PAYLOAD_SIZE_BEGIN_COMMAND_BUFFER :: 8
PAYLOAD_SIZE_CMD_BEGIN_RENDER_PASS :: 56
PAYLOAD_SIZE_CMD_BIND_PIPELINE :: 16
PAYLOAD_SIZE_CMD_SET_SCISSOR :: 24
PAYLOAD_SIZE_CMD_BIND_VERTEX_BUFFERS :: 32
PAYLOAD_SIZE_CMD_BIND_INDEX_BUFFER :: 32
PAYLOAD_SIZE_CMD_BIND_DESCRIPTOR_SETS :: 24
PAYLOAD_SIZE_CMD_DRAW :: 24
PAYLOAD_SIZE_CMD_DRAW_INDEXED :: 32
PAYLOAD_SIZE_CMD_END_RENDER_PASS :: 8
PAYLOAD_SIZE_END_COMMAND_BUFFER :: 8
PAYLOAD_SIZE_CMD_COPY_BUFFER :: 48
PAYLOAD_SIZE_CMD_COPY_BUFFER_TO_IMAGE :: 56
PAYLOAD_SIZE_QUEUE_SUBMIT :: 24
PAYLOAD_SIZE_QUEUE_WAIT_IDLE :: 8
PAYLOAD_SIZE_RING_NOTIFY :: 16

// Border conversions from wire words to closed enumerations.

command_type_of_word :: proc "contextless" (word: u32) -> (command_type: Venus_Command_Type, ok: bool) {
	return enum_word.member_of_word(Venus_Command_Type, u64(word))
}

command_flags_of_word :: proc "contextless" (word: u32) -> (flags: Venus_Command_Flags, ok: bool) {
	known := transmute(u32)(Venus_Command_Flags{.Generate_Reply})
	if word & ~known != 0 {
		return {}, false
	}
	return transmute(Venus_Command_Flags)word, true
}

ring_status_of_word :: proc "contextless" (word: u32) -> (status: Venus_Ring_Status, ok: bool) {
	return enum_word.member_of_word(Venus_Ring_Status, u64(word))
}

@(private = "file")
is_power_of_two_u32 :: proc "contextless" (value: u32) -> bool {
	return value != 0 && (value & (value - 1)) == 0
}

// Ring header border validation, encoding, and decoding.

// ring_header_validate verifies a Venus_Ring_Header against the total blob byte size.
ring_header_validate :: proc "contextless" (header: Venus_Ring_Header, total_blob_size: u64) -> Venus_Problem {
	if header.magic != VENUS_RING_MAGIC {
		return .Ring_Bad_Magic
	}
	if header.version != VENUS_RING_VERSION {
		return .Ring_Bad_Version
	}
	if _, status_ok := ring_status_of_word(u32(header.status)); !status_ok {
		return .Ring_Invalid_Status
	}
	if header.buffer_size < MIN_RING_BUFFER_SIZE || header.buffer_size > MAX_RING_BUFFER_SIZE || !is_power_of_two_u32(header.buffer_size) {
		return .Ring_Invalid_Buffer_Size
	}
	if header.head % 4 != 0 || header.head >= header.buffer_size {
		return .Ring_Head_Out_Of_Bounds
	}
	if header.tail % 4 != 0 || header.tail >= header.buffer_size {
		return .Ring_Tail_Out_Of_Bounds
	}
	if header.buffer_offset < VENUS_RING_HEADER_SIZE || header.buffer_offset % 64 != 0 {
		return .Ring_Offset_Out_Of_Bounds
	}
	buffer_end := u64(header.buffer_offset) + u64(header.buffer_size)
	if buffer_end > total_blob_size {
		return .Ring_Offset_Out_Of_Bounds
	}
	if header.extra_size == 0 {
		if header.extra_offset != 0 {
			return .Ring_Offset_Out_Of_Bounds
		}
	} else {
		if header.extra_offset % 4 != 0 || u64(header.extra_offset) < buffer_end {
			return .Ring_Offset_Out_Of_Bounds
		}
		if u64(header.extra_offset) + u64(header.extra_size) > total_blob_size {
			return .Ring_Offset_Out_Of_Bounds
		}
	}
	if header.ring_id == 0 {
		return .Zero_Handle_Id
	}
	return .None
}

// ring_header_encode validates and writes a 64-byte Venus_Ring_Header.
ring_header_encode :: proc "contextless" (header: Venus_Ring_Header, total_blob_size: u64, destination: []u8) -> (written: int, problem: Venus_Problem) {
	if len(destination) < VENUS_RING_HEADER_SIZE {
		return 0, .Buffer_Too_Short
	}
	if check := ring_header_validate(header, total_blob_size); check != .None {
		return 0, check
	}
	for index in 0 ..< VENUS_RING_HEADER_SIZE {
		destination[index] = 0
	}
	byte_order.write_u32_little_endian(destination, 0, header.magic)
	byte_order.write_u32_little_endian(destination, 4, header.version)
	byte_order.write_u32_little_endian(destination, 8, header.head)
	byte_order.write_u32_little_endian(destination, 12, header.tail)
	byte_order.write_u32_little_endian(destination, 16, u32(header.status))
	byte_order.write_u32_little_endian(destination, 20, header.buffer_size)
	byte_order.write_u32_little_endian(destination, 24, header.buffer_offset)
	byte_order.write_u32_little_endian(destination, 28, header.extra_offset)
	byte_order.write_u32_little_endian(destination, 32, header.extra_size)
	byte_order.write_u32_little_endian(destination, 36, 0)
	byte_order.write_u64_little_endian(destination, 40, header.ring_id)
	return VENUS_RING_HEADER_SIZE, .None
}

// ring_header_decode validates and reads a 64-byte Venus_Ring_Header from wire bytes.
ring_header_decode :: proc "contextless" (source: []u8, total_blob_size: u64) -> (header: Venus_Ring_Header, problem: Venus_Problem) {
	if len(source) < VENUS_RING_HEADER_SIZE {
		return {}, .Buffer_Too_Short
	}
	if byte_order.read_u32_little_endian(source, 36) != 0 {
		return {}, .Ring_Non_Zero_Reserved
	}
	for index in 48 ..< VENUS_RING_HEADER_SIZE {
		if source[index] != 0 {
			return {}, .Ring_Non_Zero_Reserved
		}
	}
	status, status_ok := ring_status_of_word(byte_order.read_u32_little_endian(source, 16))
	if !status_ok {
		return {}, .Ring_Invalid_Status
	}
	decoded := Venus_Ring_Header{
		magic         = byte_order.read_u32_little_endian(source, 0),
		version       = byte_order.read_u32_little_endian(source, 4),
		head          = byte_order.read_u32_little_endian(source, 8),
		tail          = byte_order.read_u32_little_endian(source, 12),
		status        = status,
		buffer_size   = byte_order.read_u32_little_endian(source, 20),
		buffer_offset = byte_order.read_u32_little_endian(source, 24),
		extra_offset  = byte_order.read_u32_little_endian(source, 28),
		extra_size    = byte_order.read_u32_little_endian(source, 32),
		ring_id       = byte_order.read_u64_little_endian(source, 40),
	}
	if check := ring_header_validate(decoded, total_blob_size); check != .None {
		return {}, check
	}
	return decoded, .None
}

// ring_available_bytes returns how many unread bytes sit between head and tail
// in a validated power-of-two ring buffer.
ring_available_bytes :: proc "contextless" (head, tail, buffer_size: u32) -> u32 {
	if buffer_size == 0 || !is_power_of_two_u32(buffer_size) {
		return 0
	}
	return (tail - head) & (buffer_size - 1)
}

// ring_free_bytes returns how many writable bytes remain without colliding with head.
// One 4-byte word is reserved to distinguish full from empty.
ring_free_bytes :: proc "contextless" (head, tail, buffer_size: u32) -> u32 {
	if buffer_size < 4 || !is_power_of_two_u32(buffer_size) {
		return 0
	}
	used := ring_available_bytes(head, tail, buffer_size)
	if used >= buffer_size - 4 {
		return 0
	}
	return (buffer_size - 4) - used
}

// Stream encoder helpers.

encoder_init :: proc "contextless" (storage: []u8) -> Venus_Stream_Encoder {
	return Venus_Stream_Encoder{storage = storage}
}

encoder_bytes :: proc "contextless" (encoder: ^Venus_Stream_Encoder) -> []u8 {
	return encoder.storage[:encoder.used_bytes]
}

@(private = "file")
encoder_reserve :: proc "contextless" (
	encoder: ^Venus_Stream_Encoder,
	command_type: Venus_Command_Type,
	flags: Venus_Command_Flags,
	payload_bytes: int,
) -> (payload: []u8, problem: Venus_Problem) {
	if _, type_ok := command_type_of_word(u32(command_type)); !type_ok {
		return nil, .Unknown_Command_Type
	}
	flags_word := transmute(u32)flags
	if _, flags_ok := command_flags_of_word(flags_word); !flags_ok {
		return nil, .Unknown_Command_Flags
	}
	if payload_bytes < 0 || payload_bytes % 4 != 0 {
		return nil, .Misaligned_Length
	}
	if payload_bytes > MAX_COMMAND_PAYLOAD_BYTES {
		return nil, .Stream_Too_Large
	}
	total_packet := COMMAND_HEADER_SIZE + payload_bytes
	if encoder.used_bytes < 0 || encoder.used_bytes > MAX_STREAM_BYTES - total_packet {
		return nil, .Stream_Too_Large
	}
	if len(encoder.storage) - encoder.used_bytes < total_packet {
		return nil, .Buffer_Too_Short
	}
	packet := encoder.storage[encoder.used_bytes : encoder.used_bytes + total_packet]
	for index in 0 ..< total_packet {
		packet[index] = 0
	}
	byte_order.write_u32_little_endian(packet, 0, u32(command_type))
	byte_order.write_u32_little_endian(packet, 4, flags_word)
	byte_order.write_u32_little_endian(packet, 8, u32(payload_bytes))
	byte_order.write_u32_little_endian(packet, 12, 0)
	encoder.used_bytes += total_packet
	encoder.command_count += 1
	return packet[COMMAND_HEADER_SIZE:], .None
}

// Per-command encoders (all validate inputs before reserving/writing bytes).

encode_set_reply_command_stream :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Set_Reply_Command_Stream_Payload, flags: Venus_Command_Flags = {}) -> Venus_Problem {
	if p.stream_resource_id == 0 {
		return .Zero_Handle_Id
	}
	if p.size == 0 {
		return .Zero_Extent
	}
	if p.offset % 4 != 0 || p.size % 4 != 0 {
		return .Misaligned_Length
	}
	slot, problem := encoder_reserve(encoder, .Set_Reply_Command_Stream, flags, PAYLOAD_SIZE_SET_REPLY_COMMAND_STREAM)
	if problem != .None {
		return problem
	}
	byte_order.write_u32_little_endian(slot, 0, p.stream_resource_id)
	byte_order.write_u32_little_endian(slot, 4, p.offset)
	byte_order.write_u32_little_endian(slot, 8, p.size)
	byte_order.write_u32_little_endian(slot, 12, 0)
	return .None
}

encode_create_instance :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Create_Instance_Payload, flags: Venus_Command_Flags = {.Generate_Reply}) -> Venus_Problem {
	if p.instance_id == 0 {
		return .Zero_Handle_Id
	}
	slot, problem := encoder_reserve(encoder, .Create_Instance, flags, PAYLOAD_SIZE_CREATE_INSTANCE)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.instance_id)
	byte_order.write_u32_little_endian(slot, 8, p.api_version)
	byte_order.write_u32_little_endian(slot, 12, 0)
	return .None
}

encode_destroy_instance :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Destroy_Instance_Payload, flags: Venus_Command_Flags = {}) -> Venus_Problem {
	if p.instance_id == 0 {
		return .Zero_Handle_Id
	}
	slot, problem := encoder_reserve(encoder, .Destroy_Instance, flags, PAYLOAD_SIZE_DESTROY_INSTANCE)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.instance_id)
	return .None
}

encode_enumerate_physical_devices :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Enumerate_Physical_Devices_Payload, flags: Venus_Command_Flags = {.Generate_Reply}) -> Venus_Problem {
	if p.instance_id == 0 {
		return .Zero_Handle_Id
	}
	if p.max_device_count == 0 || p.max_device_count > MAX_PHYSICAL_DEVICES {
		return .Count_Out_Of_Range
	}
	slot, problem := encoder_reserve(encoder, .Enumerate_Physical_Devices, flags, PAYLOAD_SIZE_ENUMERATE_PHYSICAL_DEVICES)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.instance_id)
	byte_order.write_u32_little_endian(slot, 8, p.max_device_count)
	byte_order.write_u32_little_endian(slot, 12, 0)
	return .None
}

encode_create_device :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Create_Device_Payload, flags: Venus_Command_Flags = {.Generate_Reply}) -> Venus_Problem {
	if p.physical_device_id == 0 || p.device_id == 0 {
		return .Zero_Handle_Id
	}
	if p.queue_family_index >= MAX_QUEUE_FAMILIES || p.queue_count == 0 || p.queue_count > MAX_QUEUE_FAMILIES {
		return .Count_Out_Of_Range
	}
	slot, problem := encoder_reserve(encoder, .Create_Device, flags, PAYLOAD_SIZE_CREATE_DEVICE)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.physical_device_id)
	byte_order.write_u64_little_endian(slot, 8, p.device_id)
	byte_order.write_u32_little_endian(slot, 16, p.queue_family_index)
	byte_order.write_u32_little_endian(slot, 20, p.queue_count)
	return .None
}

encode_destroy_device :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Destroy_Device_Payload, flags: Venus_Command_Flags = {}) -> Venus_Problem {
	if p.device_id == 0 {
		return .Zero_Handle_Id
	}
	slot, problem := encoder_reserve(encoder, .Destroy_Device, flags, PAYLOAD_SIZE_DESTROY_DEVICE)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.device_id)
	return .None
}

encode_allocate_memory :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Allocate_Memory_Payload, flags: Venus_Command_Flags = {.Generate_Reply}) -> Venus_Problem {
	if p.device_id == 0 || p.memory_id == 0 {
		return .Zero_Handle_Id
	}
	if p.allocation_size == 0 {
		return .Zero_Extent
	}
	slot, problem := encoder_reserve(encoder, .Allocate_Memory, flags, PAYLOAD_SIZE_ALLOCATE_MEMORY)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.device_id)
	byte_order.write_u64_little_endian(slot, 8, p.memory_id)
	byte_order.write_u64_little_endian(slot, 16, p.allocation_size)
	byte_order.write_u32_little_endian(slot, 24, p.memory_type_index)
	byte_order.write_u32_little_endian(slot, 28, 0)
	return .None
}

encode_free_memory :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Free_Memory_Payload, flags: Venus_Command_Flags = {}) -> Venus_Problem {
	if p.device_id == 0 || p.memory_id == 0 {
		return .Zero_Handle_Id
	}
	slot, problem := encoder_reserve(encoder, .Free_Memory, flags, PAYLOAD_SIZE_FREE_MEMORY)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.device_id)
	byte_order.write_u64_little_endian(slot, 8, p.memory_id)
	return .None
}

encode_create_buffer :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Create_Buffer_Payload, flags: Venus_Command_Flags = {.Generate_Reply}) -> Venus_Problem {
	if p.device_id == 0 || p.buffer_id == 0 {
		return .Zero_Handle_Id
	}
	if p.size == 0 {
		return .Zero_Extent
	}
	usage_word := transmute(u32)p.usage
	if _, usage_ok := webgpu_subset.buffer_usage_of_word(usage_word); !usage_ok {
		return .Unknown_Usage_Bits
	}
	slot, problem := encoder_reserve(encoder, .Create_Buffer, flags, PAYLOAD_SIZE_CREATE_BUFFER)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.device_id)
	byte_order.write_u64_little_endian(slot, 8, p.buffer_id)
	byte_order.write_u64_little_endian(slot, 16, p.size)
	byte_order.write_u32_little_endian(slot, 24, usage_word)
	byte_order.write_u32_little_endian(slot, 28, 0)
	return .None
}

encode_create_image :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Create_Image_Payload, flags: Venus_Command_Flags = {.Generate_Reply}) -> Venus_Problem {
	if p.device_id == 0 || p.image_id == 0 {
		return .Zero_Handle_Id
	}
	if p.width == 0 || p.height == 0 {
		return .Zero_Extent
	}
	if p.width > MAX_IMAGE_DIMENSION || p.height > MAX_IMAGE_DIMENSION {
		return .Dimension_Too_Large
	}
	if _, fmt_ok := webgpu_subset.texture_format_of_word(u32(p.format)); !fmt_ok {
		return .Unknown_Enum_Word
	}
	usage_word := transmute(u32)p.usage
	if _, usage_ok := webgpu_subset.texture_usage_of_word(usage_word); !usage_ok {
		return .Unknown_Usage_Bits
	}
	slot, problem := encoder_reserve(encoder, .Create_Image, flags, PAYLOAD_SIZE_CREATE_IMAGE)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.device_id)
	byte_order.write_u64_little_endian(slot, 8, p.image_id)
	byte_order.write_u32_little_endian(slot, 16, p.width)
	byte_order.write_u32_little_endian(slot, 20, p.height)
	byte_order.write_u32_little_endian(slot, 24, u32(p.format))
	byte_order.write_u32_little_endian(slot, 28, usage_word)
	return .None
}

encode_create_shader_module :: proc "contextless" (
	encoder: ^Venus_Stream_Encoder,
	device_id: u64,
	shader_module_id: u64,
	spirv_bytes: []u8,
	flags: Venus_Command_Flags = {.Generate_Reply},
) -> Venus_Problem {
	if device_id == 0 || shader_module_id == 0 {
		return .Zero_Handle_Id
	}
	if len(spirv_bytes) % 4 != 0 {
		return .Misaligned_Length
	}
	if len(spirv_bytes) > MAX_SPIRV_BYTES {
		return .Spirv_Too_Large
	}
	if _, spirv_refusal := webgpu_subset.spirv_bytes_validate(spirv_bytes); spirv_refusal != .None {
		return .Invalid_Spirv
	}
	payload_bytes := PAYLOAD_SIZE_CREATE_SHADER_MODULE_HEADER + len(spirv_bytes)
	slot, problem := encoder_reserve(encoder, .Create_Shader_Module, flags, payload_bytes)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, device_id)
	byte_order.write_u64_little_endian(slot, 8, shader_module_id)
	byte_order.write_u32_little_endian(slot, 16, u32(len(spirv_bytes) / 4))
	byte_order.write_u32_little_endian(slot, 20, 0)
	copy(slot[PAYLOAD_SIZE_CREATE_SHADER_MODULE_HEADER:], spirv_bytes)
	return .None
}

encode_create_render_pass :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Create_Render_Pass_Payload, flags: Venus_Command_Flags = {.Generate_Reply}) -> Venus_Problem {
	if p.device_id == 0 || p.render_pass_id == 0 {
		return .Zero_Handle_Id
	}
	if _, fmt_ok := webgpu_subset.texture_format_of_word(u32(p.color_format)); !fmt_ok {
		return .Unknown_Enum_Word
	}
	if p.color_format == .Depth24_Plus {
		return .Unknown_Enum_Word
	}
	if _, load_ok := webgpu_subset.load_op_of_word(u32(p.load_op)); !load_ok {
		return .Unknown_Enum_Word
	}
	if _, store_ok := webgpu_subset.store_op_of_word(u32(p.store_op)); !store_ok {
		return .Unknown_Enum_Word
	}
	slot, problem := encoder_reserve(encoder, .Create_Render_Pass, flags, PAYLOAD_SIZE_CREATE_RENDER_PASS)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.device_id)
	byte_order.write_u64_little_endian(slot, 8, p.render_pass_id)
	byte_order.write_u32_little_endian(slot, 16, u32(p.color_format))
	byte_order.write_u32_little_endian(slot, 20, p.has_depth ? 1 : 0)
	byte_order.write_u32_little_endian(slot, 24, u32(p.load_op))
	byte_order.write_u32_little_endian(slot, 28, u32(p.store_op))
	return .None
}

encode_create_graphics_pipelines :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Create_Graphics_Pipelines_Payload, flags: Venus_Command_Flags = {.Generate_Reply}) -> Venus_Problem {
	if p.device_id == 0 || p.pipeline_id == 0 || p.render_pass_id == 0 || p.vertex_shader_id == 0 || p.fragment_shader_id == 0 {
		return .Zero_Handle_Id
	}
	if _, topo_ok := webgpu_subset.primitive_topology_of_word(u32(p.topology)); !topo_ok {
		return .Unknown_Enum_Word
	}
	if _, src_ok := webgpu_subset.blend_factor_of_word(u32(p.src_blend)); !src_ok {
		return .Unknown_Enum_Word
	}
	if _, dst_ok := webgpu_subset.blend_factor_of_word(u32(p.dst_blend)); !dst_ok {
		return .Unknown_Enum_Word
	}
	slot, problem := encoder_reserve(encoder, .Create_Graphics_Pipelines, flags, PAYLOAD_SIZE_CREATE_GRAPHICS_PIPELINES)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.device_id)
	byte_order.write_u64_little_endian(slot, 8, p.pipeline_id)
	byte_order.write_u64_little_endian(slot, 16, p.render_pass_id)
	byte_order.write_u64_little_endian(slot, 24, p.vertex_shader_id)
	byte_order.write_u64_little_endian(slot, 32, p.fragment_shader_id)
	byte_order.write_u32_little_endian(slot, 40, u32(p.topology))
	byte_order.write_u32_little_endian(slot, 44, u32(p.src_blend))
	byte_order.write_u32_little_endian(slot, 48, u32(p.dst_blend))
	byte_order.write_u32_little_endian(slot, 52, p.vertex_stride)
	return .None
}

encode_allocate_command_buffers :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Allocate_Command_Buffers_Payload, flags: Venus_Command_Flags = {.Generate_Reply}) -> Venus_Problem {
	if p.device_id == 0 || p.command_pool_id == 0 || p.command_buffer_id == 0 {
		return .Zero_Handle_Id
	}
	slot, problem := encoder_reserve(encoder, .Allocate_Command_Buffers, flags, PAYLOAD_SIZE_ALLOCATE_COMMAND_BUFFERS)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.device_id)
	byte_order.write_u64_little_endian(slot, 8, p.command_pool_id)
	byte_order.write_u64_little_endian(slot, 16, p.command_buffer_id)
	return .None
}

encode_begin_command_buffer :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Begin_Command_Buffer_Payload, flags: Venus_Command_Flags = {}) -> Venus_Problem {
	if p.command_buffer_id == 0 {
		return .Zero_Handle_Id
	}
	slot, problem := encoder_reserve(encoder, .Begin_Command_Buffer, flags, PAYLOAD_SIZE_BEGIN_COMMAND_BUFFER)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.command_buffer_id)
	return .None
}

encode_cmd_begin_render_pass :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Cmd_Begin_Render_Pass_Payload, flags: Venus_Command_Flags = {}) -> Venus_Problem {
	if p.command_buffer_id == 0 || p.render_pass_id == 0 || p.framebuffer_id == 0 {
		return .Zero_Handle_Id
	}
	if p.render_width == 0 || p.render_height == 0 {
		return .Zero_Extent
	}
	if p.render_width > MAX_IMAGE_DIMENSION || p.render_height > MAX_IMAGE_DIMENSION {
		return .Dimension_Too_Large
	}
	slot, problem := encoder_reserve(encoder, .Cmd_Begin_Render_Pass, flags, PAYLOAD_SIZE_CMD_BEGIN_RENDER_PASS)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.command_buffer_id)
	byte_order.write_u64_little_endian(slot, 8, p.render_pass_id)
	byte_order.write_u64_little_endian(slot, 16, p.framebuffer_id)
	byte_order.write_u32_little_endian(slot, 24, p.render_x)
	byte_order.write_u32_little_endian(slot, 28, p.render_y)
	byte_order.write_u32_little_endian(slot, 32, p.render_width)
	byte_order.write_u32_little_endian(slot, 36, p.render_height)
	byte_order.write_u32_little_endian(slot, 40, p.clear_color.r_bits)
	byte_order.write_u32_little_endian(slot, 44, p.clear_color.g_bits)
	byte_order.write_u32_little_endian(slot, 48, p.clear_color.b_bits)
	byte_order.write_u32_little_endian(slot, 52, p.clear_color.a_bits)
	return .None
}

encode_cmd_bind_pipeline :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Cmd_Bind_Pipeline_Payload, flags: Venus_Command_Flags = {}) -> Venus_Problem {
	if p.command_buffer_id == 0 || p.pipeline_id == 0 {
		return .Zero_Handle_Id
	}
	slot, problem := encoder_reserve(encoder, .Cmd_Bind_Pipeline, flags, PAYLOAD_SIZE_CMD_BIND_PIPELINE)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.command_buffer_id)
	byte_order.write_u64_little_endian(slot, 8, p.pipeline_id)
	return .None
}

encode_cmd_set_scissor :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Cmd_Set_Scissor_Payload, flags: Venus_Command_Flags = {}) -> Venus_Problem {
	if p.command_buffer_id == 0 {
		return .Zero_Handle_Id
	}
	if p.width == 0 || p.height == 0 {
		return .Zero_Extent
	}
	if p.width > MAX_IMAGE_DIMENSION || p.height > MAX_IMAGE_DIMENSION {
		return .Dimension_Too_Large
	}
	slot, problem := encoder_reserve(encoder, .Cmd_Set_Scissor, flags, PAYLOAD_SIZE_CMD_SET_SCISSOR)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.command_buffer_id)
	byte_order.write_u32_little_endian(slot, 8, p.x)
	byte_order.write_u32_little_endian(slot, 12, p.y)
	byte_order.write_u32_little_endian(slot, 16, p.width)
	byte_order.write_u32_little_endian(slot, 20, p.height)
	return .None
}

encode_cmd_bind_vertex_buffers :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Cmd_Bind_Vertex_Buffers_Payload, flags: Venus_Command_Flags = {}) -> Venus_Problem {
	if p.command_buffer_id == 0 || p.buffer_id == 0 {
		return .Zero_Handle_Id
	}
	if p.first_binding >= MAX_VERTEX_BUFFER_SLOTS {
		return .Invalid_Slot
	}
	slot, problem := encoder_reserve(encoder, .Cmd_Bind_Vertex_Buffers, flags, PAYLOAD_SIZE_CMD_BIND_VERTEX_BUFFERS)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.command_buffer_id)
	byte_order.write_u32_little_endian(slot, 8, p.first_binding)
	byte_order.write_u32_little_endian(slot, 12, 0)
	byte_order.write_u64_little_endian(slot, 16, p.buffer_id)
	byte_order.write_u64_little_endian(slot, 24, p.offset)
	return .None
}

encode_cmd_bind_index_buffer :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Cmd_Bind_Index_Buffer_Payload, flags: Venus_Command_Flags = {}) -> Venus_Problem {
	if p.command_buffer_id == 0 || p.buffer_id == 0 {
		return .Zero_Handle_Id
	}
	if _, fmt_ok := webgpu_subset.index_format_of_word(u32(p.index_format)); !fmt_ok {
		return .Unknown_Enum_Word
	}
	stride := webgpu_subset.index_format_byte_stride(p.index_format)
	if stride == 0 || p.offset % stride != 0 {
		return .Misaligned_Length
	}
	slot, problem := encoder_reserve(encoder, .Cmd_Bind_Index_Buffer, flags, PAYLOAD_SIZE_CMD_BIND_INDEX_BUFFER)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.command_buffer_id)
	byte_order.write_u64_little_endian(slot, 8, p.buffer_id)
	byte_order.write_u64_little_endian(slot, 16, p.offset)
	byte_order.write_u32_little_endian(slot, 24, u32(p.index_format))
	byte_order.write_u32_little_endian(slot, 28, 0)
	return .None
}

encode_cmd_bind_descriptor_sets :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Cmd_Bind_Descriptor_Sets_Payload, flags: Venus_Command_Flags = {}) -> Venus_Problem {
	if p.command_buffer_id == 0 || p.descriptor_set_id == 0 {
		return .Zero_Handle_Id
	}
	if p.set_index >= MAX_BIND_GROUPS {
		return .Invalid_Slot
	}
	slot, problem := encoder_reserve(encoder, .Cmd_Bind_Descriptor_Sets, flags, PAYLOAD_SIZE_CMD_BIND_DESCRIPTOR_SETS)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.command_buffer_id)
	byte_order.write_u32_little_endian(slot, 8, p.set_index)
	byte_order.write_u32_little_endian(slot, 12, 0)
	byte_order.write_u64_little_endian(slot, 16, p.descriptor_set_id)
	return .None
}

encode_cmd_draw :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Cmd_Draw_Payload, flags: Venus_Command_Flags = {}) -> Venus_Problem {
	if p.command_buffer_id == 0 {
		return .Zero_Handle_Id
	}
	if p.vertex_count == 0 || p.instance_count == 0 {
		return .Zero_Draw_Count
	}
	slot, problem := encoder_reserve(encoder, .Cmd_Draw, flags, PAYLOAD_SIZE_CMD_DRAW)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.command_buffer_id)
	byte_order.write_u32_little_endian(slot, 8, p.vertex_count)
	byte_order.write_u32_little_endian(slot, 12, p.instance_count)
	byte_order.write_u32_little_endian(slot, 16, p.first_vertex)
	byte_order.write_u32_little_endian(slot, 20, p.first_instance)
	return .None
}

encode_cmd_draw_indexed :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Cmd_Draw_Indexed_Payload, flags: Venus_Command_Flags = {}) -> Venus_Problem {
	if p.command_buffer_id == 0 {
		return .Zero_Handle_Id
	}
	if p.index_count == 0 || p.instance_count == 0 {
		return .Zero_Draw_Count
	}
	slot, problem := encoder_reserve(encoder, .Cmd_Draw_Indexed, flags, PAYLOAD_SIZE_CMD_DRAW_INDEXED)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.command_buffer_id)
	byte_order.write_u32_little_endian(slot, 8, p.index_count)
	byte_order.write_u32_little_endian(slot, 12, p.instance_count)
	byte_order.write_u32_little_endian(slot, 16, p.first_index)
	byte_order.write_u32_little_endian(slot, 20, u32(p.vertex_offset))
	byte_order.write_u32_little_endian(slot, 24, p.first_instance)
	byte_order.write_u32_little_endian(slot, 28, 0)
	return .None
}

encode_cmd_end_render_pass :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Cmd_End_Render_Pass_Payload, flags: Venus_Command_Flags = {}) -> Venus_Problem {
	if p.command_buffer_id == 0 {
		return .Zero_Handle_Id
	}
	slot, problem := encoder_reserve(encoder, .Cmd_End_Render_Pass, flags, PAYLOAD_SIZE_CMD_END_RENDER_PASS)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.command_buffer_id)
	return .None
}

encode_end_command_buffer :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: End_Command_Buffer_Payload, flags: Venus_Command_Flags = {}) -> Venus_Problem {
	if p.command_buffer_id == 0 {
		return .Zero_Handle_Id
	}
	slot, problem := encoder_reserve(encoder, .End_Command_Buffer, flags, PAYLOAD_SIZE_END_COMMAND_BUFFER)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.command_buffer_id)
	return .None
}

encode_cmd_copy_buffer :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Cmd_Copy_Buffer_Payload, flags: Venus_Command_Flags = {}) -> Venus_Problem {
	if p.command_buffer_id == 0 || p.src_buffer_id == 0 || p.dst_buffer_id == 0 {
		return .Zero_Handle_Id
	}
	if p.size == 0 {
		return .Zero_Extent
	}
	if p.src_offset % 4 != 0 || p.dst_offset % 4 != 0 || p.size % 4 != 0 {
		return .Misaligned_Length
	}
	slot, problem := encoder_reserve(encoder, .Cmd_Copy_Buffer, flags, PAYLOAD_SIZE_CMD_COPY_BUFFER)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.command_buffer_id)
	byte_order.write_u64_little_endian(slot, 8, p.src_buffer_id)
	byte_order.write_u64_little_endian(slot, 16, p.dst_buffer_id)
	byte_order.write_u64_little_endian(slot, 24, p.src_offset)
	byte_order.write_u64_little_endian(slot, 32, p.dst_offset)
	byte_order.write_u64_little_endian(slot, 40, p.size)
	return .None
}

encode_cmd_copy_buffer_to_image :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Cmd_Copy_Buffer_To_Image_Payload, flags: Venus_Command_Flags = {}) -> Venus_Problem {
	if p.command_buffer_id == 0 || p.src_buffer_id == 0 || p.dst_image_id == 0 {
		return .Zero_Handle_Id
	}
	if p.width == 0 || p.height == 0 || p.bytes_per_row == 0 {
		return .Zero_Extent
	}
	if p.width > MAX_IMAGE_DIMENSION || p.height > MAX_IMAGE_DIMENSION {
		return .Dimension_Too_Large
	}
	slot, problem := encoder_reserve(encoder, .Cmd_Copy_Buffer_To_Image, flags, PAYLOAD_SIZE_CMD_COPY_BUFFER_TO_IMAGE)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.command_buffer_id)
	byte_order.write_u64_little_endian(slot, 8, p.src_buffer_id)
	byte_order.write_u64_little_endian(slot, 16, p.dst_image_id)
	byte_order.write_u64_little_endian(slot, 24, p.src_offset)
	byte_order.write_u32_little_endian(slot, 32, p.bytes_per_row)
	byte_order.write_u32_little_endian(slot, 36, p.dst_x)
	byte_order.write_u32_little_endian(slot, 40, p.dst_y)
	byte_order.write_u32_little_endian(slot, 44, p.width)
	byte_order.write_u32_little_endian(slot, 48, p.height)
	byte_order.write_u32_little_endian(slot, 52, 0)
	return .None
}

encode_queue_submit :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Queue_Submit_Payload, flags: Venus_Command_Flags = {}) -> Venus_Problem {
	if p.queue_id == 0 || p.command_buffer_id == 0 {
		return .Zero_Handle_Id
	}
	slot, problem := encoder_reserve(encoder, .Queue_Submit, flags, PAYLOAD_SIZE_QUEUE_SUBMIT)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.queue_id)
	byte_order.write_u64_little_endian(slot, 8, p.command_buffer_id)
	byte_order.write_u64_little_endian(slot, 16, p.fence_id)
	return .None
}

encode_queue_wait_idle :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Queue_Wait_Idle_Payload, flags: Venus_Command_Flags = {.Generate_Reply}) -> Venus_Problem {
	if p.queue_id == 0 {
		return .Zero_Handle_Id
	}
	slot, problem := encoder_reserve(encoder, .Queue_Wait_Idle, flags, PAYLOAD_SIZE_QUEUE_WAIT_IDLE)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.queue_id)
	return .None
}

encode_ring_notify :: proc "contextless" (encoder: ^Venus_Stream_Encoder, p: Ring_Notify_Payload, flags: Venus_Command_Flags = {}) -> Venus_Problem {
	if p.ring_id == 0 {
		return .Zero_Handle_Id
	}
	slot, problem := encoder_reserve(encoder, .Ring_Notify, flags, PAYLOAD_SIZE_RING_NOTIFY)
	if problem != .None {
		return problem
	}
	byte_order.write_u64_little_endian(slot, 0, p.ring_id)
	byte_order.write_u32_little_endian(slot, 8, p.seqno)
	byte_order.write_u32_little_endian(slot, 12, 0)
	return .None
}

// Strict single-command decoder at cursor.
stream_decode_next :: proc "contextless" (source: []u8, cursor: int) -> (decoded: Venus_Decoded_Command, next_cursor: int, problem: Venus_Problem) {
	if cursor < 0 || cursor > len(source) || cursor % 4 != 0 {
		return {}, cursor, .Misaligned_Length
	}
	if len(source) - cursor < COMMAND_HEADER_SIZE {
		return {}, cursor, .Buffer_Too_Short
	}
	header_bytes := source[cursor : cursor + COMMAND_HEADER_SIZE]
	command_type, type_ok := command_type_of_word(byte_order.read_u32_little_endian(header_bytes, 0))
	if !type_ok {
		return {}, cursor, .Unknown_Command_Type
	}
	flags, flags_ok := command_flags_of_word(byte_order.read_u32_little_endian(header_bytes, 4))
	if !flags_ok {
		return {}, cursor, .Unknown_Command_Flags
	}
	payload_bytes := byte_order.read_u32_little_endian(header_bytes, 8)
	if byte_order.read_u32_little_endian(header_bytes, 12) != 0 {
		return {}, cursor, .Non_Zero_Reserved
	}
	if payload_bytes % 4 != 0 {
		return {}, cursor, .Misaligned_Length
	}
	if payload_bytes > MAX_COMMAND_PAYLOAD_BYTES {
		return {}, cursor, .Stream_Too_Large
	}
	packet_size := COMMAND_HEADER_SIZE + int(payload_bytes)
	if len(source) - cursor < packet_size {
		return {}, cursor, .Buffer_Too_Short
	}
	slot := source[cursor + COMMAND_HEADER_SIZE : cursor + packet_size]
	decoded.header = Venus_Command_Header{
		command_type  = command_type,
		flags         = flags,
		payload_bytes = payload_bytes,
	}

	switch command_type {
	case .Set_Reply_Command_Stream:
		if payload_bytes != PAYLOAD_SIZE_SET_REPLY_COMMAND_STREAM {
			return {}, cursor, .Payload_Size_Mismatch
		}
		if byte_order.read_u32_little_endian(slot, 12) != 0 {
			return {}, cursor, .Non_Zero_Reserved
		}
		p := Set_Reply_Command_Stream_Payload{
			stream_resource_id = byte_order.read_u32_little_endian(slot, 0),
			offset             = byte_order.read_u32_little_endian(slot, 4),
			size               = byte_order.read_u32_little_endian(slot, 8),
		}
		if p.stream_resource_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		if p.size == 0 {
			return {}, cursor, .Zero_Extent
		}
		if p.offset % 4 != 0 || p.size % 4 != 0 {
			return {}, cursor, .Misaligned_Length
		}
		decoded.payload = p

	case .Create_Instance:
		if payload_bytes != PAYLOAD_SIZE_CREATE_INSTANCE {
			return {}, cursor, .Payload_Size_Mismatch
		}
		if byte_order.read_u32_little_endian(slot, 12) != 0 {
			return {}, cursor, .Non_Zero_Reserved
		}
		p := Create_Instance_Payload{
			instance_id = byte_order.read_u64_little_endian(slot, 0),
			api_version = byte_order.read_u32_little_endian(slot, 8),
		}
		if p.instance_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		decoded.payload = p

	case .Destroy_Instance:
		if payload_bytes != PAYLOAD_SIZE_DESTROY_INSTANCE {
			return {}, cursor, .Payload_Size_Mismatch
		}
		p := Destroy_Instance_Payload{
			instance_id = byte_order.read_u64_little_endian(slot, 0),
		}
		if p.instance_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		decoded.payload = p

	case .Enumerate_Physical_Devices:
		if payload_bytes != PAYLOAD_SIZE_ENUMERATE_PHYSICAL_DEVICES {
			return {}, cursor, .Payload_Size_Mismatch
		}
		if byte_order.read_u32_little_endian(slot, 12) != 0 {
			return {}, cursor, .Non_Zero_Reserved
		}
		p := Enumerate_Physical_Devices_Payload{
			instance_id      = byte_order.read_u64_little_endian(slot, 0),
			max_device_count = byte_order.read_u32_little_endian(slot, 8),
		}
		if p.instance_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		if p.max_device_count == 0 || p.max_device_count > MAX_PHYSICAL_DEVICES {
			return {}, cursor, .Count_Out_Of_Range
		}
		decoded.payload = p

	case .Create_Device:
		if payload_bytes != PAYLOAD_SIZE_CREATE_DEVICE {
			return {}, cursor, .Payload_Size_Mismatch
		}
		p := Create_Device_Payload{
			physical_device_id = byte_order.read_u64_little_endian(slot, 0),
			device_id          = byte_order.read_u64_little_endian(slot, 8),
			queue_family_index = byte_order.read_u32_little_endian(slot, 16),
			queue_count        = byte_order.read_u32_little_endian(slot, 20),
		}
		if p.physical_device_id == 0 || p.device_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		if p.queue_family_index >= MAX_QUEUE_FAMILIES || p.queue_count == 0 || p.queue_count > MAX_QUEUE_FAMILIES {
			return {}, cursor, .Count_Out_Of_Range
		}
		decoded.payload = p

	case .Destroy_Device:
		if payload_bytes != PAYLOAD_SIZE_DESTROY_DEVICE {
			return {}, cursor, .Payload_Size_Mismatch
		}
		p := Destroy_Device_Payload{
			device_id = byte_order.read_u64_little_endian(slot, 0),
		}
		if p.device_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		decoded.payload = p

	case .Allocate_Memory:
		if payload_bytes != PAYLOAD_SIZE_ALLOCATE_MEMORY {
			return {}, cursor, .Payload_Size_Mismatch
		}
		if byte_order.read_u32_little_endian(slot, 28) != 0 {
			return {}, cursor, .Non_Zero_Reserved
		}
		p := Allocate_Memory_Payload{
			device_id         = byte_order.read_u64_little_endian(slot, 0),
			memory_id         = byte_order.read_u64_little_endian(slot, 8),
			allocation_size   = byte_order.read_u64_little_endian(slot, 16),
			memory_type_index = byte_order.read_u32_little_endian(slot, 24),
		}
		if p.device_id == 0 || p.memory_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		if p.allocation_size == 0 {
			return {}, cursor, .Zero_Extent
		}
		decoded.payload = p

	case .Free_Memory:
		if payload_bytes != PAYLOAD_SIZE_FREE_MEMORY {
			return {}, cursor, .Payload_Size_Mismatch
		}
		p := Free_Memory_Payload{
			device_id = byte_order.read_u64_little_endian(slot, 0),
			memory_id = byte_order.read_u64_little_endian(slot, 8),
		}
		if p.device_id == 0 || p.memory_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		decoded.payload = p

	case .Create_Buffer:
		if payload_bytes != PAYLOAD_SIZE_CREATE_BUFFER {
			return {}, cursor, .Payload_Size_Mismatch
		}
		if byte_order.read_u32_little_endian(slot, 28) != 0 {
			return {}, cursor, .Non_Zero_Reserved
		}
		usage, usage_ok := webgpu_subset.buffer_usage_of_word(byte_order.read_u32_little_endian(slot, 24))
		if !usage_ok {
			return {}, cursor, .Unknown_Usage_Bits
		}
		p := Create_Buffer_Payload{
			device_id = byte_order.read_u64_little_endian(slot, 0),
			buffer_id = byte_order.read_u64_little_endian(slot, 8),
			size      = byte_order.read_u64_little_endian(slot, 16),
			usage     = usage,
		}
		if p.device_id == 0 || p.buffer_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		if p.size == 0 {
			return {}, cursor, .Zero_Extent
		}
		decoded.payload = p

	case .Create_Image:
		if payload_bytes != PAYLOAD_SIZE_CREATE_IMAGE {
			return {}, cursor, .Payload_Size_Mismatch
		}
		format, fmt_ok := webgpu_subset.texture_format_of_word(byte_order.read_u32_little_endian(slot, 24))
		if !fmt_ok {
			return {}, cursor, .Unknown_Enum_Word
		}
		usage, usage_ok := webgpu_subset.texture_usage_of_word(byte_order.read_u32_little_endian(slot, 28))
		if !usage_ok {
			return {}, cursor, .Unknown_Usage_Bits
		}
		p := Create_Image_Payload{
			device_id = byte_order.read_u64_little_endian(slot, 0),
			image_id  = byte_order.read_u64_little_endian(slot, 8),
			width     = byte_order.read_u32_little_endian(slot, 16),
			height    = byte_order.read_u32_little_endian(slot, 20),
			format    = format,
			usage     = usage,
		}
		if p.device_id == 0 || p.image_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		if p.width == 0 || p.height == 0 {
			return {}, cursor, .Zero_Extent
		}
		if p.width > MAX_IMAGE_DIMENSION || p.height > MAX_IMAGE_DIMENSION {
			return {}, cursor, .Dimension_Too_Large
		}
		decoded.payload = p

	case .Create_Shader_Module:
		if payload_bytes < PAYLOAD_SIZE_CREATE_SHADER_MODULE_HEADER {
			return {}, cursor, .Payload_Size_Mismatch
		}
		if byte_order.read_u32_little_endian(slot, 20) != 0 {
			return {}, cursor, .Non_Zero_Reserved
		}
		device_id := byte_order.read_u64_little_endian(slot, 0)
		shader_module_id := byte_order.read_u64_little_endian(slot, 8)
		word_count := byte_order.read_u32_little_endian(slot, 16)
		if device_id == 0 || shader_module_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		if word_count > MAX_SPIRV_WORDS {
			return {}, cursor, .Spirv_Too_Large
		}
		expected_payload := u64(PAYLOAD_SIZE_CREATE_SHADER_MODULE_HEADER) + u64(word_count) * 4
		if u64(payload_bytes) != expected_payload {
			return {}, cursor, .Payload_Size_Mismatch
		}
		spirv_bytes := slot[PAYLOAD_SIZE_CREATE_SHADER_MODULE_HEADER:]
		info, spirv_refusal := webgpu_subset.spirv_bytes_validate(spirv_bytes)
		if spirv_refusal != .None {
			return {}, cursor, .Invalid_Spirv
		}
		decoded.payload = Create_Shader_Module_Payload{
			device_id        = device_id,
			shader_module_id = shader_module_id,
			spirv_bytes      = spirv_bytes,
			spirv_info       = info,
		}

	case .Create_Render_Pass:
		if payload_bytes != PAYLOAD_SIZE_CREATE_RENDER_PASS {
			return {}, cursor, .Payload_Size_Mismatch
		}
		color_format, fmt_ok := webgpu_subset.texture_format_of_word(byte_order.read_u32_little_endian(slot, 16))
		if !fmt_ok || color_format == .Depth24_Plus {
			return {}, cursor, .Unknown_Enum_Word
		}
		has_depth_word := byte_order.read_u32_little_endian(slot, 20)
		if has_depth_word > 1 {
			return {}, cursor, .Unknown_Enum_Word
		}
		load_op, load_ok := webgpu_subset.load_op_of_word(byte_order.read_u32_little_endian(slot, 24))
		if !load_ok {
			return {}, cursor, .Unknown_Enum_Word
		}
		store_op, store_ok := webgpu_subset.store_op_of_word(byte_order.read_u32_little_endian(slot, 28))
		if !store_ok {
			return {}, cursor, .Unknown_Enum_Word
		}
		p := Create_Render_Pass_Payload{
			device_id      = byte_order.read_u64_little_endian(slot, 0),
			render_pass_id = byte_order.read_u64_little_endian(slot, 8),
			color_format   = color_format,
			has_depth      = has_depth_word == 1,
			load_op        = load_op,
			store_op       = store_op,
		}
		if p.device_id == 0 || p.render_pass_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		decoded.payload = p

	case .Create_Graphics_Pipelines:
		if payload_bytes != PAYLOAD_SIZE_CREATE_GRAPHICS_PIPELINES {
			return {}, cursor, .Payload_Size_Mismatch
		}
		topology, topo_ok := webgpu_subset.primitive_topology_of_word(byte_order.read_u32_little_endian(slot, 40))
		if !topo_ok {
			return {}, cursor, .Unknown_Enum_Word
		}
		src_blend, src_ok := webgpu_subset.blend_factor_of_word(byte_order.read_u32_little_endian(slot, 44))
		if !src_ok {
			return {}, cursor, .Unknown_Enum_Word
		}
		dst_blend, dst_ok := webgpu_subset.blend_factor_of_word(byte_order.read_u32_little_endian(slot, 48))
		if !dst_ok {
			return {}, cursor, .Unknown_Enum_Word
		}
		p := Create_Graphics_Pipelines_Payload{
			device_id          = byte_order.read_u64_little_endian(slot, 0),
			pipeline_id        = byte_order.read_u64_little_endian(slot, 8),
			render_pass_id     = byte_order.read_u64_little_endian(slot, 16),
			vertex_shader_id   = byte_order.read_u64_little_endian(slot, 24),
			fragment_shader_id = byte_order.read_u64_little_endian(slot, 32),
			topology           = topology,
			src_blend          = src_blend,
			dst_blend          = dst_blend,
			vertex_stride      = byte_order.read_u32_little_endian(slot, 52),
		}
		if p.device_id == 0 || p.pipeline_id == 0 || p.render_pass_id == 0 || p.vertex_shader_id == 0 || p.fragment_shader_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		decoded.payload = p

	case .Allocate_Command_Buffers:
		if payload_bytes != PAYLOAD_SIZE_ALLOCATE_COMMAND_BUFFERS {
			return {}, cursor, .Payload_Size_Mismatch
		}
		p := Allocate_Command_Buffers_Payload{
			device_id         = byte_order.read_u64_little_endian(slot, 0),
			command_pool_id   = byte_order.read_u64_little_endian(slot, 8),
			command_buffer_id = byte_order.read_u64_little_endian(slot, 16),
		}
		if p.device_id == 0 || p.command_pool_id == 0 || p.command_buffer_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		decoded.payload = p

	case .Begin_Command_Buffer:
		if payload_bytes != PAYLOAD_SIZE_BEGIN_COMMAND_BUFFER {
			return {}, cursor, .Payload_Size_Mismatch
		}
		p := Begin_Command_Buffer_Payload{
			command_buffer_id = byte_order.read_u64_little_endian(slot, 0),
		}
		if p.command_buffer_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		decoded.payload = p

	case .Cmd_Begin_Render_Pass:
		if payload_bytes != PAYLOAD_SIZE_CMD_BEGIN_RENDER_PASS {
			return {}, cursor, .Payload_Size_Mismatch
		}
		p := Cmd_Begin_Render_Pass_Payload{
			command_buffer_id = byte_order.read_u64_little_endian(slot, 0),
			render_pass_id    = byte_order.read_u64_little_endian(slot, 8),
			framebuffer_id    = byte_order.read_u64_little_endian(slot, 16),
			render_x          = byte_order.read_u32_little_endian(slot, 24),
			render_y          = byte_order.read_u32_little_endian(slot, 28),
			render_width      = byte_order.read_u32_little_endian(slot, 32),
			render_height     = byte_order.read_u32_little_endian(slot, 36),
			clear_color = webgpu_subset.Clear_Color{
				r_bits = byte_order.read_u32_little_endian(slot, 40),
				g_bits = byte_order.read_u32_little_endian(slot, 44),
				b_bits = byte_order.read_u32_little_endian(slot, 48),
				a_bits = byte_order.read_u32_little_endian(slot, 52),
			},
		}
		if p.command_buffer_id == 0 || p.render_pass_id == 0 || p.framebuffer_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		if p.render_width == 0 || p.render_height == 0 {
			return {}, cursor, .Zero_Extent
		}
		if p.render_width > MAX_IMAGE_DIMENSION || p.render_height > MAX_IMAGE_DIMENSION {
			return {}, cursor, .Dimension_Too_Large
		}
		decoded.payload = p

	case .Cmd_Bind_Pipeline:
		if payload_bytes != PAYLOAD_SIZE_CMD_BIND_PIPELINE {
			return {}, cursor, .Payload_Size_Mismatch
		}
		p := Cmd_Bind_Pipeline_Payload{
			command_buffer_id = byte_order.read_u64_little_endian(slot, 0),
			pipeline_id       = byte_order.read_u64_little_endian(slot, 8),
		}
		if p.command_buffer_id == 0 || p.pipeline_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		decoded.payload = p

	case .Cmd_Set_Scissor:
		if payload_bytes != PAYLOAD_SIZE_CMD_SET_SCISSOR {
			return {}, cursor, .Payload_Size_Mismatch
		}
		p := Cmd_Set_Scissor_Payload{
			command_buffer_id = byte_order.read_u64_little_endian(slot, 0),
			x                 = byte_order.read_u32_little_endian(slot, 8),
			y                 = byte_order.read_u32_little_endian(slot, 12),
			width             = byte_order.read_u32_little_endian(slot, 16),
			height            = byte_order.read_u32_little_endian(slot, 20),
		}
		if p.command_buffer_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		if p.width == 0 || p.height == 0 {
			return {}, cursor, .Zero_Extent
		}
		if p.width > MAX_IMAGE_DIMENSION || p.height > MAX_IMAGE_DIMENSION {
			return {}, cursor, .Dimension_Too_Large
		}
		decoded.payload = p

	case .Cmd_Bind_Vertex_Buffers:
		if payload_bytes != PAYLOAD_SIZE_CMD_BIND_VERTEX_BUFFERS {
			return {}, cursor, .Payload_Size_Mismatch
		}
		if byte_order.read_u32_little_endian(slot, 12) != 0 {
			return {}, cursor, .Non_Zero_Reserved
		}
		p := Cmd_Bind_Vertex_Buffers_Payload{
			command_buffer_id = byte_order.read_u64_little_endian(slot, 0),
			first_binding     = byte_order.read_u32_little_endian(slot, 8),
			buffer_id         = byte_order.read_u64_little_endian(slot, 16),
			offset            = byte_order.read_u64_little_endian(slot, 24),
		}
		if p.command_buffer_id == 0 || p.buffer_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		if p.first_binding >= MAX_VERTEX_BUFFER_SLOTS {
			return {}, cursor, .Invalid_Slot
		}
		decoded.payload = p

	case .Cmd_Bind_Index_Buffer:
		if payload_bytes != PAYLOAD_SIZE_CMD_BIND_INDEX_BUFFER {
			return {}, cursor, .Payload_Size_Mismatch
		}
		if byte_order.read_u32_little_endian(slot, 28) != 0 {
			return {}, cursor, .Non_Zero_Reserved
		}
		index_format, fmt_ok := webgpu_subset.index_format_of_word(byte_order.read_u32_little_endian(slot, 24))
		if !fmt_ok {
			return {}, cursor, .Unknown_Enum_Word
		}
		p := Cmd_Bind_Index_Buffer_Payload{
			command_buffer_id = byte_order.read_u64_little_endian(slot, 0),
			buffer_id         = byte_order.read_u64_little_endian(slot, 8),
			offset            = byte_order.read_u64_little_endian(slot, 16),
			index_format      = index_format,
		}
		if p.command_buffer_id == 0 || p.buffer_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		stride := webgpu_subset.index_format_byte_stride(index_format)
		if stride == 0 || p.offset % stride != 0 {
			return {}, cursor, .Misaligned_Length
		}
		decoded.payload = p

	case .Cmd_Bind_Descriptor_Sets:
		if payload_bytes != PAYLOAD_SIZE_CMD_BIND_DESCRIPTOR_SETS {
			return {}, cursor, .Payload_Size_Mismatch
		}
		if byte_order.read_u32_little_endian(slot, 12) != 0 {
			return {}, cursor, .Non_Zero_Reserved
		}
		p := Cmd_Bind_Descriptor_Sets_Payload{
			command_buffer_id = byte_order.read_u64_little_endian(slot, 0),
			set_index         = byte_order.read_u32_little_endian(slot, 8),
			descriptor_set_id = byte_order.read_u64_little_endian(slot, 16),
		}
		if p.command_buffer_id == 0 || p.descriptor_set_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		if p.set_index >= MAX_BIND_GROUPS {
			return {}, cursor, .Invalid_Slot
		}
		decoded.payload = p

	case .Cmd_Draw:
		if payload_bytes != PAYLOAD_SIZE_CMD_DRAW {
			return {}, cursor, .Payload_Size_Mismatch
		}
		p := Cmd_Draw_Payload{
			command_buffer_id = byte_order.read_u64_little_endian(slot, 0),
			vertex_count      = byte_order.read_u32_little_endian(slot, 8),
			instance_count    = byte_order.read_u32_little_endian(slot, 12),
			first_vertex      = byte_order.read_u32_little_endian(slot, 16),
			first_instance    = byte_order.read_u32_little_endian(slot, 20),
		}
		if p.command_buffer_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		if p.vertex_count == 0 || p.instance_count == 0 {
			return {}, cursor, .Zero_Draw_Count
		}
		decoded.payload = p

	case .Cmd_Draw_Indexed:
		if payload_bytes != PAYLOAD_SIZE_CMD_DRAW_INDEXED {
			return {}, cursor, .Payload_Size_Mismatch
		}
		if byte_order.read_u32_little_endian(slot, 28) != 0 {
			return {}, cursor, .Non_Zero_Reserved
		}
		p := Cmd_Draw_Indexed_Payload{
			command_buffer_id = byte_order.read_u64_little_endian(slot, 0),
			index_count       = byte_order.read_u32_little_endian(slot, 8),
			instance_count    = byte_order.read_u32_little_endian(slot, 12),
			first_index       = byte_order.read_u32_little_endian(slot, 16),
			vertex_offset     = i32(byte_order.read_u32_little_endian(slot, 20)),
			first_instance    = byte_order.read_u32_little_endian(slot, 24),
		}
		if p.command_buffer_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		if p.index_count == 0 || p.instance_count == 0 {
			return {}, cursor, .Zero_Draw_Count
		}
		decoded.payload = p

	case .Cmd_End_Render_Pass:
		if payload_bytes != PAYLOAD_SIZE_CMD_END_RENDER_PASS {
			return {}, cursor, .Payload_Size_Mismatch
		}
		p := Cmd_End_Render_Pass_Payload{
			command_buffer_id = byte_order.read_u64_little_endian(slot, 0),
		}
		if p.command_buffer_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		decoded.payload = p

	case .End_Command_Buffer:
		if payload_bytes != PAYLOAD_SIZE_END_COMMAND_BUFFER {
			return {}, cursor, .Payload_Size_Mismatch
		}
		p := End_Command_Buffer_Payload{
			command_buffer_id = byte_order.read_u64_little_endian(slot, 0),
		}
		if p.command_buffer_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		decoded.payload = p

	case .Cmd_Copy_Buffer:
		if payload_bytes != PAYLOAD_SIZE_CMD_COPY_BUFFER {
			return {}, cursor, .Payload_Size_Mismatch
		}
		p := Cmd_Copy_Buffer_Payload{
			command_buffer_id = byte_order.read_u64_little_endian(slot, 0),
			src_buffer_id     = byte_order.read_u64_little_endian(slot, 8),
			dst_buffer_id     = byte_order.read_u64_little_endian(slot, 16),
			src_offset        = byte_order.read_u64_little_endian(slot, 24),
			dst_offset        = byte_order.read_u64_little_endian(slot, 32),
			size              = byte_order.read_u64_little_endian(slot, 40),
		}
		if p.command_buffer_id == 0 || p.src_buffer_id == 0 || p.dst_buffer_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		if p.size == 0 {
			return {}, cursor, .Zero_Extent
		}
		if p.src_offset % 4 != 0 || p.dst_offset % 4 != 0 || p.size % 4 != 0 {
			return {}, cursor, .Misaligned_Length
		}
		decoded.payload = p

	case .Cmd_Copy_Buffer_To_Image:
		if payload_bytes != PAYLOAD_SIZE_CMD_COPY_BUFFER_TO_IMAGE {
			return {}, cursor, .Payload_Size_Mismatch
		}
		if byte_order.read_u32_little_endian(slot, 52) != 0 {
			return {}, cursor, .Non_Zero_Reserved
		}
		p := Cmd_Copy_Buffer_To_Image_Payload{
			command_buffer_id = byte_order.read_u64_little_endian(slot, 0),
			src_buffer_id     = byte_order.read_u64_little_endian(slot, 8),
			dst_image_id      = byte_order.read_u64_little_endian(slot, 16),
			src_offset        = byte_order.read_u64_little_endian(slot, 24),
			bytes_per_row     = byte_order.read_u32_little_endian(slot, 32),
			dst_x             = byte_order.read_u32_little_endian(slot, 36),
			dst_y             = byte_order.read_u32_little_endian(slot, 40),
			width             = byte_order.read_u32_little_endian(slot, 44),
			height            = byte_order.read_u32_little_endian(slot, 48),
		}
		if p.command_buffer_id == 0 || p.src_buffer_id == 0 || p.dst_image_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		if p.width == 0 || p.height == 0 || p.bytes_per_row == 0 {
			return {}, cursor, .Zero_Extent
		}
		if p.width > MAX_IMAGE_DIMENSION || p.height > MAX_IMAGE_DIMENSION {
			return {}, cursor, .Dimension_Too_Large
		}
		decoded.payload = p

	case .Queue_Submit:
		if payload_bytes != PAYLOAD_SIZE_QUEUE_SUBMIT {
			return {}, cursor, .Payload_Size_Mismatch
		}
		p := Queue_Submit_Payload{
			queue_id          = byte_order.read_u64_little_endian(slot, 0),
			command_buffer_id = byte_order.read_u64_little_endian(slot, 8),
			fence_id          = byte_order.read_u64_little_endian(slot, 16),
		}
		if p.queue_id == 0 || p.command_buffer_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		decoded.payload = p

	case .Queue_Wait_Idle:
		if payload_bytes != PAYLOAD_SIZE_QUEUE_WAIT_IDLE {
			return {}, cursor, .Payload_Size_Mismatch
		}
		p := Queue_Wait_Idle_Payload{
			queue_id = byte_order.read_u64_little_endian(slot, 0),
		}
		if p.queue_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		decoded.payload = p

	case .Ring_Notify:
		if payload_bytes != PAYLOAD_SIZE_RING_NOTIFY {
			return {}, cursor, .Payload_Size_Mismatch
		}
		if byte_order.read_u32_little_endian(slot, 12) != 0 {
			return {}, cursor, .Non_Zero_Reserved
		}
		p := Ring_Notify_Payload{
			ring_id = byte_order.read_u64_little_endian(slot, 0),
			seqno   = byte_order.read_u32_little_endian(slot, 8),
		}
		if p.ring_id == 0 {
			return {}, cursor, .Zero_Handle_Id
		}
		decoded.payload = p
	}

	return decoded, cursor + packet_size, .None
}

// stream_validate walks a complete Venus wire command stream, enforcing
// alignment, packet boundaries, per-command invariants, balanced command buffer
// recording, and balanced render passes.
stream_validate :: proc "contextless" (source: []u8) -> (summary: Venus_Stream_Summary, problem: Venus_Problem) {
	if len(source) == 0 {
		return {}, .Stream_Empty
	}
	if len(source) > MAX_STREAM_BYTES {
		return {}, .Stream_Too_Large
	}
	if len(source) % 4 != 0 {
		return {}, .Misaligned_Length
	}

	recording_cmd_buffer: u64 = 0
	in_render_pass := false

	cursor := 0
	for cursor < len(source) {
		cmd, next_cursor, decode_problem := stream_decode_next(source, cursor)
		if decode_problem != .None {
			return {}, decode_problem
		}

		switch payload in cmd.payload {
		case Set_Reply_Command_Stream_Payload,
		     Create_Instance_Payload,
		     Destroy_Instance_Payload,
		     Enumerate_Physical_Devices_Payload,
		     Create_Device_Payload,
		     Destroy_Device_Payload,
		     Allocate_Memory_Payload,
		     Free_Memory_Payload,
		     Create_Buffer_Payload,
		     Create_Image_Payload,
		     Create_Render_Pass_Payload,
		     Create_Graphics_Pipelines_Payload,
		     Allocate_Command_Buffers_Payload,
		     Queue_Wait_Idle_Payload,
		     Ring_Notify_Payload:
			// Setup and synchronization commands are valid outside command buffer recording.

		case Create_Shader_Module_Payload:
			summary.shader_count += 1

		case Begin_Command_Buffer_Payload:
			if recording_cmd_buffer != 0 {
				return {}, .Command_Buffer_Already_Active
			}
			recording_cmd_buffer = payload.command_buffer_id

		case End_Command_Buffer_Payload:
			if recording_cmd_buffer == 0 {
				return {}, .Command_Buffer_Not_Active
			}
			if in_render_pass {
				return {}, .Unbalanced_Render_Pass
			}
			if payload.command_buffer_id != recording_cmd_buffer {
				return {}, .Command_Buffer_Mismatch
			}
			recording_cmd_buffer = 0

		case Cmd_Begin_Render_Pass_Payload:
			if recording_cmd_buffer == 0 {
				return {}, .Command_Buffer_Not_Active
			}
			if payload.command_buffer_id != recording_cmd_buffer {
				return {}, .Command_Buffer_Mismatch
			}
			if in_render_pass {
				return {}, .Render_Pass_Already_Active
			}
			in_render_pass = true
			summary.render_pass_count += 1

		case Cmd_End_Render_Pass_Payload:
			if recording_cmd_buffer == 0 {
				return {}, .Command_Buffer_Not_Active
			}
			if payload.command_buffer_id != recording_cmd_buffer {
				return {}, .Command_Buffer_Mismatch
			}
			if !in_render_pass {
				return {}, .Render_Pass_Not_Active
			}
			in_render_pass = false

		case Cmd_Bind_Pipeline_Payload:
			if recording_cmd_buffer == 0 {
				return {}, .Command_Buffer_Not_Active
			}
			if payload.command_buffer_id != recording_cmd_buffer {
				return {}, .Command_Buffer_Mismatch
			}
			if !in_render_pass {
				return {}, .Render_Pass_Not_Active
			}

		case Cmd_Set_Scissor_Payload:
			if recording_cmd_buffer == 0 {
				return {}, .Command_Buffer_Not_Active
			}
			if payload.command_buffer_id != recording_cmd_buffer {
				return {}, .Command_Buffer_Mismatch
			}
			if !in_render_pass {
				return {}, .Render_Pass_Not_Active
			}

		case Cmd_Bind_Vertex_Buffers_Payload:
			if recording_cmd_buffer == 0 {
				return {}, .Command_Buffer_Not_Active
			}
			if payload.command_buffer_id != recording_cmd_buffer {
				return {}, .Command_Buffer_Mismatch
			}
			if !in_render_pass {
				return {}, .Render_Pass_Not_Active
			}

		case Cmd_Bind_Index_Buffer_Payload:
			if recording_cmd_buffer == 0 {
				return {}, .Command_Buffer_Not_Active
			}
			if payload.command_buffer_id != recording_cmd_buffer {
				return {}, .Command_Buffer_Mismatch
			}
			if !in_render_pass {
				return {}, .Render_Pass_Not_Active
			}

		case Cmd_Bind_Descriptor_Sets_Payload:
			if recording_cmd_buffer == 0 {
				return {}, .Command_Buffer_Not_Active
			}
			if payload.command_buffer_id != recording_cmd_buffer {
				return {}, .Command_Buffer_Mismatch
			}
			if !in_render_pass {
				return {}, .Render_Pass_Not_Active
			}

		case Cmd_Draw_Payload:
			if recording_cmd_buffer == 0 {
				return {}, .Command_Buffer_Not_Active
			}
			if payload.command_buffer_id != recording_cmd_buffer {
				return {}, .Command_Buffer_Mismatch
			}
			if !in_render_pass {
				return {}, .Render_Pass_Not_Active
			}
			summary.draw_call_count += 1

		case Cmd_Draw_Indexed_Payload:
			if recording_cmd_buffer == 0 {
				return {}, .Command_Buffer_Not_Active
			}
			if payload.command_buffer_id != recording_cmd_buffer {
				return {}, .Command_Buffer_Mismatch
			}
			if !in_render_pass {
				return {}, .Render_Pass_Not_Active
			}
			summary.draw_call_count += 1

		case Cmd_Copy_Buffer_Payload:
			if recording_cmd_buffer == 0 {
				return {}, .Command_Buffer_Not_Active
			}
			if payload.command_buffer_id != recording_cmd_buffer {
				return {}, .Command_Buffer_Mismatch
			}
			if in_render_pass {
				return {}, .Copy_Inside_Render_Pass
			}
			summary.copy_count += 1

		case Cmd_Copy_Buffer_To_Image_Payload:
			if recording_cmd_buffer == 0 {
				return {}, .Command_Buffer_Not_Active
			}
			if payload.command_buffer_id != recording_cmd_buffer {
				return {}, .Command_Buffer_Mismatch
			}
			if in_render_pass {
				return {}, .Copy_Inside_Render_Pass
			}
			summary.copy_count += 1

		case Queue_Submit_Payload:
			if recording_cmd_buffer != 0 {
				return {}, .Unbalanced_Command_Buffer
			}
			summary.submit_count += 1
		}

		summary.command_count += 1
		cursor = next_cursor
	}

	if in_render_pass {
		return {}, .Unbalanced_Render_Pass
	}
	if recording_cmd_buffer != 0 {
		return {}, .Unbalanced_Command_Buffer
	}
	return summary, .None
}

// webgpu_stream_to_venus validates a webgpu_subset command stream against its
// resource registry and translates every command into a Venus Vulkan wire stream
// wrapped in Begin_Command_Buffer, End_Command_Buffer, and Queue_Submit.
//
// Pre-computes the exact output byte size before writing so destination stays
// untouched when the caller's buffer is too small or the input stream is refused.
webgpu_stream_to_venus :: proc "contextless" (
	stream: webgpu_subset.Gpu_Command_Stream,
	resources: webgpu_subset.Resource_Registry,
	handles: Venus_Translation_Handles,
	destination: []u8,
) -> (written: int, problem: Venus_Problem) {
	if handles.command_buffer_id == 0 || handles.queue_id == 0 {
		return 0, .Zero_Handle_Id
	}
	if _, ws_refusal := webgpu_subset.stream_validate(stream, resources); ws_refusal != .None {
		return 0, .Webgpu_Stream_Invalid
	}

	record_count := len(stream.bytes) / webgpu_subset.COMMAND_RECORD_SIZE
	needed_bytes := (COMMAND_HEADER_SIZE + PAYLOAD_SIZE_BEGIN_COMMAND_BUFFER) +
		(COMMAND_HEADER_SIZE + PAYLOAD_SIZE_END_COMMAND_BUFFER) +
		(COMMAND_HEADER_SIZE + PAYLOAD_SIZE_QUEUE_SUBMIT)

	for index in 0 ..< record_count {
		record := stream.bytes[index * webgpu_subset.COMMAND_RECORD_SIZE : (index + 1) * webgpu_subset.COMMAND_RECORD_SIZE]
		kind, kind_ok := webgpu_subset.gpu_command_kind_of_word(byte_order.read_u32_little_endian(record, 0))
		if !kind_ok {
			return 0, .Webgpu_Stream_Invalid
		}
		switch kind {
		case .None:
			return 0, .Webgpu_Stream_Invalid
		case .Begin_Render_Pass:
			needed_bytes += COMMAND_HEADER_SIZE + PAYLOAD_SIZE_CMD_BEGIN_RENDER_PASS
		case .Set_Pipeline:
			needed_bytes += COMMAND_HEADER_SIZE + PAYLOAD_SIZE_CMD_BIND_PIPELINE
		case .Set_Vertex_Buffer:
			needed_bytes += COMMAND_HEADER_SIZE + PAYLOAD_SIZE_CMD_BIND_VERTEX_BUFFERS
		case .Set_Index_Buffer:
			needed_bytes += COMMAND_HEADER_SIZE + PAYLOAD_SIZE_CMD_BIND_INDEX_BUFFER
		case .Set_Bind_Group:
			needed_bytes += COMMAND_HEADER_SIZE + PAYLOAD_SIZE_CMD_BIND_DESCRIPTOR_SETS
		case .Set_Scissor_Rect:
			needed_bytes += COMMAND_HEADER_SIZE + PAYLOAD_SIZE_CMD_SET_SCISSOR
		case .Draw:
			needed_bytes += COMMAND_HEADER_SIZE + PAYLOAD_SIZE_CMD_DRAW
		case .Draw_Indexed:
			needed_bytes += COMMAND_HEADER_SIZE + PAYLOAD_SIZE_CMD_DRAW_INDEXED
		case .End_Render_Pass:
			needed_bytes += COMMAND_HEADER_SIZE + PAYLOAD_SIZE_CMD_END_RENDER_PASS
		case .Copy_Buffer_To_Buffer:
			needed_bytes += COMMAND_HEADER_SIZE + PAYLOAD_SIZE_CMD_COPY_BUFFER
		case .Copy_Buffer_To_Texture:
			needed_bytes += COMMAND_HEADER_SIZE + PAYLOAD_SIZE_CMD_COPY_BUFFER_TO_IMAGE
		}
		if needed_bytes > MAX_STREAM_BYTES {
			return 0, .Stream_Too_Large
		}
	}

	if len(destination) < needed_bytes {
		return 0, .Buffer_Too_Short
	}

	enc := encoder_init(destination[:needed_bytes])
	if err := encode_begin_command_buffer(&enc, Begin_Command_Buffer_Payload{command_buffer_id = handles.command_buffer_id}); err != .None {
		return 0, err
	}

	for index in 0 ..< record_count {
		record := stream.bytes[index * webgpu_subset.COMMAND_RECORD_SIZE : (index + 1) * webgpu_subset.COMMAND_RECORD_SIZE]
		kind, _ := webgpu_subset.gpu_command_kind_of_word(byte_order.read_u32_little_endian(record, 0))
		switch kind {
		case .None:
			return 0, .Webgpu_Stream_Invalid

		case .Begin_Render_Pass:
			color_texture_id := byte_order.read_u32_little_endian(record, 8)
			color_desc := resources.textures[color_texture_id - 1]
			clear := webgpu_subset.Clear_Color{
				r_bits = byte_order.read_u32_little_endian(record, 24),
				g_bits = byte_order.read_u32_little_endian(record, 28),
				b_bits = byte_order.read_u32_little_endian(record, 32),
				a_bits = byte_order.read_u32_little_endian(record, 36),
			}
			if err := encode_cmd_begin_render_pass(&enc, Cmd_Begin_Render_Pass_Payload{
				command_buffer_id = handles.command_buffer_id,
				render_pass_id    = handles.render_pass_id_base + u64(color_texture_id),
				framebuffer_id    = handles.framebuffer_id_base + u64(color_texture_id),
				render_x          = 0,
				render_y          = 0,
				render_width      = color_desc.width,
				render_height     = color_desc.height,
				clear_color       = clear,
			}); err != .None {
				return 0, err
			}

		case .Set_Pipeline:
			pipeline_id := byte_order.read_u32_little_endian(record, 8)
			if err := encode_cmd_bind_pipeline(&enc, Cmd_Bind_Pipeline_Payload{
				command_buffer_id = handles.command_buffer_id,
				pipeline_id       = handles.pipeline_id_base + u64(pipeline_id),
			}); err != .None {
				return 0, err
			}

		case .Set_Vertex_Buffer:
			slot_index := byte_order.read_u32_little_endian(record, 8)
			buffer_id := byte_order.read_u32_little_endian(record, 12)
			offset := byte_order.read_u64_little_endian(record, 16)
			if err := encode_cmd_bind_vertex_buffers(&enc, Cmd_Bind_Vertex_Buffers_Payload{
				command_buffer_id = handles.command_buffer_id,
				first_binding     = slot_index,
				buffer_id         = handles.buffer_id_base + u64(buffer_id),
				offset            = offset,
			}); err != .None {
				return 0, err
			}

		case .Set_Index_Buffer:
			buffer_id := byte_order.read_u32_little_endian(record, 8)
			index_format, _ := webgpu_subset.index_format_of_word(byte_order.read_u32_little_endian(record, 12))
			offset := byte_order.read_u64_little_endian(record, 16)
			if err := encode_cmd_bind_index_buffer(&enc, Cmd_Bind_Index_Buffer_Payload{
				command_buffer_id = handles.command_buffer_id,
				buffer_id         = handles.buffer_id_base + u64(buffer_id),
				offset            = offset,
				index_format      = index_format,
			}); err != .None {
				return 0, err
			}

		case .Set_Bind_Group:
			slot_index := byte_order.read_u32_little_endian(record, 8)
			bind_group_id := byte_order.read_u32_little_endian(record, 12)
			if err := encode_cmd_bind_descriptor_sets(&enc, Cmd_Bind_Descriptor_Sets_Payload{
				command_buffer_id = handles.command_buffer_id,
				set_index         = slot_index,
				descriptor_set_id = handles.descriptor_set_base + u64(bind_group_id),
			}); err != .None {
				return 0, err
			}

		case .Set_Scissor_Rect:
			if err := encode_cmd_set_scissor(&enc, Cmd_Set_Scissor_Payload{
				command_buffer_id = handles.command_buffer_id,
				x                 = byte_order.read_u32_little_endian(record, 8),
				y                 = byte_order.read_u32_little_endian(record, 12),
				width             = byte_order.read_u32_little_endian(record, 16),
				height            = byte_order.read_u32_little_endian(record, 20),
			}); err != .None {
				return 0, err
			}

		case .Draw:
			if err := encode_cmd_draw(&enc, Cmd_Draw_Payload{
				command_buffer_id = handles.command_buffer_id,
				vertex_count      = byte_order.read_u32_little_endian(record, 8),
				instance_count    = byte_order.read_u32_little_endian(record, 12),
				first_vertex      = byte_order.read_u32_little_endian(record, 16),
				first_instance    = byte_order.read_u32_little_endian(record, 20),
			}); err != .None {
				return 0, err
			}

		case .Draw_Indexed:
			if err := encode_cmd_draw_indexed(&enc, Cmd_Draw_Indexed_Payload{
				command_buffer_id = handles.command_buffer_id,
				index_count       = byte_order.read_u32_little_endian(record, 8),
				instance_count    = byte_order.read_u32_little_endian(record, 12),
				first_index       = byte_order.read_u32_little_endian(record, 16),
				vertex_offset     = i32(byte_order.read_u32_little_endian(record, 20)),
				first_instance    = byte_order.read_u32_little_endian(record, 24),
			}); err != .None {
				return 0, err
			}

		case .End_Render_Pass:
			if err := encode_cmd_end_render_pass(&enc, Cmd_End_Render_Pass_Payload{
				command_buffer_id = handles.command_buffer_id,
			}); err != .None {
				return 0, err
			}

		case .Copy_Buffer_To_Buffer:
			src_buffer_id := byte_order.read_u32_little_endian(record, 8)
			dst_buffer_id := byte_order.read_u32_little_endian(record, 12)
			if err := encode_cmd_copy_buffer(&enc, Cmd_Copy_Buffer_Payload{
				command_buffer_id = handles.command_buffer_id,
				src_buffer_id     = handles.buffer_id_base + u64(src_buffer_id),
				dst_buffer_id     = handles.buffer_id_base + u64(dst_buffer_id),
				src_offset        = byte_order.read_u64_little_endian(record, 16),
				dst_offset        = byte_order.read_u64_little_endian(record, 24),
				size              = byte_order.read_u64_little_endian(record, 32),
			}); err != .None {
				return 0, err
			}

		case .Copy_Buffer_To_Texture:
			src_buffer_id := byte_order.read_u32_little_endian(record, 8)
			dst_texture_id := byte_order.read_u32_little_endian(record, 12)
			if err := encode_cmd_copy_buffer_to_image(&enc, Cmd_Copy_Buffer_To_Image_Payload{
				command_buffer_id = handles.command_buffer_id,
				src_buffer_id     = handles.buffer_id_base + u64(src_buffer_id),
				dst_image_id      = handles.image_id_base + u64(dst_texture_id),
				src_offset        = byte_order.read_u64_little_endian(record, 16),
				bytes_per_row     = byte_order.read_u32_little_endian(record, 24),
				dst_x             = byte_order.read_u32_little_endian(record, 28),
				dst_y             = byte_order.read_u32_little_endian(record, 32),
				width             = byte_order.read_u32_little_endian(record, 36),
				height            = byte_order.read_u32_little_endian(record, 40),
			}); err != .None {
				return 0, err
			}
		}
	}

	if err := encode_end_command_buffer(&enc, End_Command_Buffer_Payload{command_buffer_id = handles.command_buffer_id}); err != .None {
		return 0, err
	}
	if err := encode_queue_submit(&enc, Queue_Submit_Payload{
		queue_id          = handles.queue_id,
		command_buffer_id = handles.command_buffer_id,
		fence_id          = handles.fence_id,
	}); err != .None {
		return 0, err
	}

	return enc.used_bytes, .None
}

// webgpu_stream_to_submit_3d translates a validated webgpu_subset command stream
// directly into a VirtIO-GPU Submit_3D control-queue packet ready for transport.
webgpu_stream_to_submit_3d :: proc "contextless" (
	ctx_id: u32,
	stream: webgpu_subset.Gpu_Command_Stream,
	resources: webgpu_subset.Resource_Registry,
	handles: Venus_Translation_Handles,
	destination: []u8,
	virtio_fence_id: u64 = 0,
) -> (written: int, problem: Venus_Problem) {
	if ctx_id == 0 {
		return 0, .Zero_Handle_Id
	}
	if len(destination) < virtio_gpu.SUBMIT_3D_HEADER_SIZE {
		return 0, .Buffer_Too_Short
	}
	payload_slot := destination[virtio_gpu.SUBMIT_3D_HEADER_SIZE:]
	venus_bytes, venus_problem := webgpu_stream_to_venus(stream, resources, handles, payload_slot)
	if venus_problem != .None {
		return 0, venus_problem
	}
	// Frame the encoded Venus payload in place using a VirtIO-GPU Submit_3D header.
	header_flags := virtio_gpu.Header_Flags{}
	if virtio_fence_id != 0 {
		header_flags = {.Fence}
	}
	_, hdr_problem := virtio_gpu.ctrl_header_encode(virtio_gpu.Ctrl_Header{
		command_type = .Submit_3D,
		flags        = header_flags,
		fence_id     = virtio_fence_id,
		ctx_id       = ctx_id,
	}, destination)
	if hdr_problem != .None {
		return 0, .Virtio_Frame_Invalid
	}
	byte_order.write_u32_little_endian(destination, 24, u32(venus_bytes))
	return virtio_gpu.SUBMIT_3D_HEADER_SIZE + venus_bytes, .None
}
