#+build !freestanding
package venus_vulkan

import "core:testing"
import "modus:contract/byte_order"

@(test)
limit_table_counts_every_field_of_vulkan_core :: proc(t: ^testing.T) {
	value_count := 0
	wire_bytes := 0
	for field in LIMIT_FIELDS {
		value_count += int(field.count)
		width := field.kind == .Unsigned_64 ? 8 : 4
		wire_bytes += width * int(field.count) + (field.count > 1 ? 8 : 0)
	}
	testing.expect_value(t, value_count, LIMIT_VALUE_COUNT)
	// 91 fields of 4 bytes, 9 of 8 bytes, 6 fixed arrays of 14 words.
	testing.expect_value(t, wire_bytes, 540)
	testing.expect_value(t, LIMIT_FIELDS[LIMIT_VALUE_MAX_IMAGE_DIMENSION_2D].kind, Limit_Kind.Unsigned_32)
	testing.expect_value(t, LIMIT_FIELDS[LIMIT_FIELD_COUNT - 1].kind, Limit_Kind.Unsigned_64)
}

@(test)
replies_decode_results_and_echoed_objects :: proc(t: ^testing.T) {
	storage: [4096]u8
	encoder := encoder_init(storage[:])
	physical := [2]Object_Id{2, 4}
	command_buffers := [2]Object_Id{20, 21}
	testing.expect_value(t, encode_create_object_reply(&encoder, .Create_Instance, .Success, 1), Venus_Problem.None)
	testing.expect_value(t, encode_enumerate_physical_devices_reply(&encoder, .Success, 2, nil), Venus_Problem.None)
	testing.expect_value(t, encode_enumerate_physical_devices_reply(&encoder, .Incomplete, 1, physical[:1]), Venus_Problem.None)
	testing.expect_value(t, encode_create_object_reply(&encoder, .Create_Device, .Error_Initialization_Failed, 3), Venus_Problem.None)
	testing.expect_value(t, encode_get_device_queue_2_reply(&encoder, 12), Venus_Problem.None)
	testing.expect_value(t, encode_allocate_command_buffers_reply(&encoder, .Success, command_buffers[:]), Venus_Problem.None)
	testing.expect_value(t, encode_result_reply(&encoder, .Queue_Wait_Idle, .Error_Device_Lost), Venus_Problem.None)

	// The reply stream holds the replies in order; each decoder advances.
	decoder := decoder_init(encoder_bytes(&encoder))
	result, problem := decode_create_object_reply(&decoder, .Create_Instance, 1)
	testing.expect_value(t, problem, Venus_Problem.None)
	testing.expect_value(t, result, Vulkan_Result.Success)
	enumerate_result, device_count, enumerate_problem := decode_enumerate_physical_devices_reply(&decoder, nil)
	testing.expect_value(t, enumerate_problem, Venus_Problem.None)
	testing.expect_value(t, enumerate_result, Vulkan_Result.Success)
	testing.expect_value(t, device_count, u32(2))
	enumerate_result, device_count, enumerate_problem = decode_enumerate_physical_devices_reply(&decoder, physical[:])
	testing.expect_value(t, enumerate_problem, Venus_Problem.None)
	testing.expect_value(t, enumerate_result, Vulkan_Result.Incomplete)
	testing.expect_value(t, device_count, u32(1))
	result, problem = decode_create_object_reply(&decoder, .Create_Device, 3)
	testing.expect_value(t, problem, Venus_Problem.None)
	testing.expect_value(t, result, Vulkan_Result.Error_Initialization_Failed)
	testing.expect_value(t, decode_get_device_queue_2_reply(&decoder, 12), Venus_Problem.None)
	result, problem = decode_allocate_command_buffers_reply(&decoder, command_buffers[:])
	testing.expect_value(t, problem, Venus_Problem.None)
	result, problem = decode_result_reply(&decoder, .Queue_Wait_Idle)
	testing.expect_value(t, problem, Venus_Problem.None)
	testing.expect_value(t, result, Vulkan_Result.Error_Device_Lost)
	testing.expect(t, decoder_done(&decoder), "the reply stream must be read whole")
}

@(test)
replies_refuse_wrong_types_results_ids_and_cuts :: proc(t: ^testing.T) {
	storage: [256]u8
	encoder := encoder_init(storage[:])
	_ = encode_create_object_reply(&encoder, .Create_Buffer, .Success, 9)
	reply := encoder_bytes(&encoder)
	testing.expect_value(t, len(reply), 24)

	decoder := decoder_init(reply)
	_, problem := decode_create_object_reply(&decoder, .Create_Buffer, 10)
	testing.expect_value(t, problem, Venus_Problem.Object_Id_Mismatch)
	testing.expect_value(t, decoder.cursor, 0)
	_, problem = decode_create_object_reply(&decoder, .Allocate_Memory, 9)
	testing.expect_value(t, problem, Venus_Problem.Unexpected_Command_Type)
	_, problem = decode_create_object_reply(&decoder, .Cmd_Draw, 9)
	testing.expect_value(t, problem, Venus_Problem.Unexpected_Command_Type)
	_, problem = decode_create_object_reply(&decoder, .Create_Buffer, 0)
	testing.expect_value(t, problem, Venus_Problem.Zero_Object_Id)
	_, problem = decode_result_reply(&decoder, .Create_Buffer)
	testing.expect_value(t, problem, Venus_Problem.Unexpected_Command_Type)

	for cut in 0 ..< len(reply) {
		cut_decoder := decoder_init(reply[:cut])
		_, cut_problem := decode_create_object_reply(&cut_decoder, .Create_Buffer, 9)
		testing.expect_value(t, cut_problem, Venus_Problem.Stream_Truncated)
		testing.expect_value(t, cut_decoder.cursor, 0)
	}

	for word in ([]u32{6, 0xFFFF_FFF2, 0x8000_0000, 1000001003}) {
		corrupt: [24]u8
		copy(corrupt[:], reply)
		byte_order.write_u32_little_endian(corrupt[:], 4, word)
		corrupt_decoder := decoder_init(corrupt[:])
		_, corrupt_problem := decode_create_object_reply(&corrupt_decoder, .Create_Buffer, 9)
		testing.expectf(t, corrupt_problem == .Unknown_Result, "result word 0x%x must be refused", word)
	}
	{
		corrupt: [24]u8
		copy(corrupt[:], reply)
		byte_order.write_u64_little_endian(corrupt[:], 8, 2)
		corrupt_decoder := decoder_init(corrupt[:])
		_, corrupt_problem := decode_create_object_reply(&corrupt_decoder, .Create_Buffer, 9)
		testing.expect_value(t, corrupt_problem, Venus_Problem.Pointer_Invalid)
		byte_order.write_u64_little_endian(corrupt[:], 8, 0)
		corrupt_decoder = decoder_init(corrupt[:])
		_, corrupt_problem = decode_create_object_reply(&corrupt_decoder, .Create_Buffer, 9)
		testing.expect_value(t, corrupt_problem, Venus_Problem.Pointer_Invalid)
	}

	// vkEnumeratePhysicalDevices: ids that differ, more devices than ids, an
	// array for a count query, a count over the bound.
	physical := [2]Object_Id{2, 4}
	encoder = encoder_init(storage[:])
	_ = encode_enumerate_physical_devices_reply(&encoder, .Success, 2, []Object_Id{2, 5})
	decoder = decoder_init(encoder_bytes(&encoder))
	_, _, problem = decode_enumerate_physical_devices_reply(&decoder, physical[:])
	testing.expect_value(t, problem, Venus_Problem.Object_Id_Mismatch)
	_, _, problem = decode_enumerate_physical_devices_reply(&decoder, physical[:1])
	testing.expect_value(t, problem, Venus_Problem.Array_Size_Mismatch)
	_, _, problem = decode_enumerate_physical_devices_reply(&decoder, nil)
	testing.expect_value(t, problem, Venus_Problem.Array_Size_Mismatch)
	encoder = encoder_init(storage[:])
	_ = encode_enumerate_physical_devices_reply(&encoder, .Success, MAX_ARRAY_ELEMENTS + 1, nil)
	decoder = decoder_init(encoder_bytes(&encoder))
	_, _, problem = decode_enumerate_physical_devices_reply(&decoder, nil)
	testing.expect_value(t, problem, Venus_Problem.Count_Out_Of_Range)

	// vkAllocateCommandBuffers: a different id, a different count.
	encoder = encoder_init(storage[:])
	_ = encode_allocate_command_buffers_reply(&encoder, .Success, []Object_Id{20, 22})
	decoder = decoder_init(encoder_bytes(&encoder))
	_, problem = decode_allocate_command_buffers_reply(&decoder, []Object_Id{20, 21})
	testing.expect_value(t, problem, Venus_Problem.Object_Id_Mismatch)
	_, problem = decode_allocate_command_buffers_reply(&decoder, []Object_Id{20})
	testing.expect_value(t, problem, Venus_Problem.Array_Size_Mismatch)
	_, problem = decode_allocate_command_buffers_reply(&decoder, nil)
	testing.expect_value(t, problem, Venus_Problem.Count_Out_Of_Range)
}

@(test)
physical_device_properties_reply_roundtrip :: proc(t: ^testing.T) {
	properties: Physical_Device_Properties
	properties.api_version = API_VERSION_1_1
	properties.vendor_id = 0x1AF4
	properties.device_id = 0x1050
	properties.device_type = .Virtual_Gpu
	copy(properties.device_name[:], "Virtio-GPU Venus (llvmpipe)")
	properties.pipeline_cache_uuid[15] = 0xEE
	for index in 0 ..< LIMIT_VALUE_COUNT {
		properties.limits[index] = u64(index + 1)
	}
	properties.limits[LIMIT_VALUE_NON_COHERENT_ATOM_SIZE] = 0x1_0000_0040
	min_texel_offset := i64(-8)
	properties.limits[70 + 6] = u64(min_texel_offset) // minTexelOffset
	properties.sparse_properties[4] = 1

	storage: [2048]u8
	encoder := encoder_init(storage[:])
	testing.expect_value(t, encode_get_physical_device_properties_reply(&encoder, &properties), Venus_Problem.None)
	reply := encoder_bytes(&encoder)
	testing.expect_value(t, len(reply), 880)

	decoded: Physical_Device_Properties
	decoder := decoder_init(reply)
	testing.expect_value(t, decode_get_physical_device_properties_reply(&decoder, &decoded), Venus_Problem.None)
	testing.expect(t, decoder_done(&decoder), "the properties reply must be read whole")
	testing.expect_value(t, decoded.device_type, Physical_Device_Type.Virtual_Gpu)
	testing.expect_value(t, device_name_text(&decoded), "Virtio-GPU Venus (llvmpipe)")
	testing.expect_value(t, decoded.pipeline_cache_uuid[15], u8(0xEE))
	testing.expect_value(t, decoded.limits[LIMIT_VALUE_MAX_IMAGE_DIMENSION_2D], u64(2))
	testing.expect_value(t, decoded.limits[LIMIT_VALUE_MAX_COLOR_ATTACHMENTS], u64(LIMIT_VALUE_MAX_COLOR_ATTACHMENTS + 1))
	testing.expect_value(t, decoded.limits[LIMIT_VALUE_NON_COHERENT_ATOM_SIZE], u64(0x1_0000_0040))
	testing.expect_value(t, i64(decoded.limits[76]), i64(-8))
	testing.expect_value(t, decoded.sparse_properties[4], u32(1))

	// The device type at 28, the name size at 32, the name at 40.
	corrupt: [2048]u8
	copy(corrupt[:], reply)
	byte_order.write_u32_little_endian(corrupt[:], 28, 5)
	decoder = decoder_init(corrupt[:len(reply)])
	testing.expect_value(t, decode_get_physical_device_properties_reply(&decoder, &decoded), Venus_Problem.Unknown_Enum_Word)
	copy(corrupt[:], reply)
	byte_order.write_u64_little_endian(corrupt[:], 32, 255)
	decoder = decoder_init(corrupt[:len(reply)])
	testing.expect_value(t, decode_get_physical_device_properties_reply(&decoder, &decoded), Venus_Problem.Array_Size_Mismatch)
	copy(corrupt[:], reply)
	corrupt[40 + PHYSICAL_DEVICE_NAME_BYTES - 1] = 'x'
	decoder = decoder_init(corrupt[:len(reply)])
	testing.expect_value(t, decode_get_physical_device_properties_reply(&decoder, &decoded), Venus_Problem.String_Unterminated)
	decoder = decoder_init(reply[:len(reply) - 4])
	testing.expect_value(t, decode_get_physical_device_properties_reply(&decoder, &decoded), Venus_Problem.Stream_Truncated)
}

@(test)
venus_capset_decodes_and_refuses :: proc(t: ^testing.T) {
	capset := Venus_Capset{
		wire_format_version                       = WIRE_FORMAT_VERSION,
		vk_xml_version                            = (1 << 22) | (4 << 12) | 309,
		vk_ext_command_serialization_spec_version = 1,
		vk_mesa_venus_protocol_spec_version       = 3,
		supports_blob_id_0                        = true,
		supports_multiple_timelines               = true,
	}
	capset.vk_extension_mask[0] = 1
	bytes: [VENUS_CAPSET_BYTES]u8
	written, problem := venus_capset_encode(capset, bytes[:])
	testing.expect_value(t, problem, Venus_Problem.None)
	testing.expect_value(t, written, VENUS_CAPSET_BYTES)
	decoded, decode_problem := venus_capset_decode(bytes[:])
	testing.expect_value(t, decode_problem, Venus_Problem.None)
	testing.expect_value(t, decoded, capset)

	// An older host sends only the first four words.
	short, short_problem := venus_capset_decode(bytes[:VENUS_CAPSET_MIN_BYTES])
	testing.expect_value(t, short_problem, Venus_Problem.None)
	testing.expect_value(t, short.vk_mesa_venus_protocol_spec_version, u32(3))
	testing.expect_value(t, short.supports_blob_id_0, false)

	_, too_short := venus_capset_decode(bytes[:VENUS_CAPSET_MIN_BYTES - 4])
	testing.expect_value(t, too_short, Venus_Problem.Capset_Too_Short)
	_, empty := venus_capset_decode(nil)
	testing.expect_value(t, empty, Venus_Problem.Capset_Too_Short)
	_, odd := venus_capset_decode(bytes[:VENUS_CAPSET_MIN_BYTES + 2])
	testing.expect_value(t, odd, Venus_Problem.Misaligned_Length)
	_, short_buffer := venus_capset_encode(capset, bytes[:VENUS_CAPSET_BYTES - 1])
	testing.expect_value(t, short_buffer, Venus_Problem.Buffer_Too_Short)

	for version in ([]u32{0, 2, max(u32)}) {
		corrupt := bytes
		byte_order.write_u32_little_endian(corrupt[:], 0, version)
		_, version_problem := venus_capset_decode(corrupt[:])
		testing.expect_value(t, version_problem, Venus_Problem.Capset_Wire_Format_Unsupported)
	}
	for offset in ([]int{16, 148, 152, 156}) {
		corrupt := bytes
		byte_order.write_u32_little_endian(corrupt[:], offset, 2)
		_, flag_problem := venus_capset_decode(corrupt[:])
		testing.expectf(t, flag_problem == .Capset_Boolean_Invalid, "a flag of 2 at %d must be refused", offset)
	}
}
