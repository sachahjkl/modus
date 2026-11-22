package venus_vulkan

import "modus:contract/byte_order"

// The Venus capset (struct virgl_renderer_capset_venus of venus_hw.h): what
// the renderer of the host supports. An older host sends a shorter capset;
// the fields that it does not send read as 0.

VENUS_CAPSET_MIN_BYTES :: 16
VENUS_CAPSET_BYTES :: 160
VENUS_EXTENSION_MASK_WORDS :: 32

Venus_Capset :: struct {
	wire_format_version:                       u32,
	vk_xml_version:                            u32,
	vk_ext_command_serialization_spec_version: u32,
	vk_mesa_venus_protocol_spec_version:       u32,
	supports_blob_id_0:                        bool,
	allow_vk_wait_syncs:                       bool,
	supports_multiple_timelines:               bool,
	use_guest_vram:                            bool,
	vk_extension_mask:                         [VENUS_EXTENSION_MASK_WORDS]u32,
}

@(private = "file")
capset_word :: proc "contextless" (data: []u8, index: int) -> u32 {
	offset := index * 4
	if offset + 4 > len(data) {
		return 0
	}
	return byte_order.read_u32_little_endian(data, offset)
}

@(private = "file")
capset_flag :: proc "contextless" (data: []u8, index: int) -> (flag: bool, ok: bool) {
	word := capset_word(data, index)
	return word == 1, word <= 1
}

// venus_capset_decode reads the capset bytes of a Response_Ok_Capset.
venus_capset_decode :: proc "contextless" (data: []u8) -> (capset: Venus_Capset, problem: Venus_Problem) {
	if len(data) < VENUS_CAPSET_MIN_BYTES {
		return {}, .Capset_Too_Short
	}
	if len(data) % 4 != 0 {
		return {}, .Misaligned_Length
	}
	capset.wire_format_version = capset_word(data, 0)
	if capset.wire_format_version != WIRE_FORMAT_VERSION {
		return {}, .Capset_Wire_Format_Unsupported
	}
	capset.vk_xml_version = capset_word(data, 1)
	capset.vk_ext_command_serialization_spec_version = capset_word(data, 2)
	capset.vk_mesa_venus_protocol_spec_version = capset_word(data, 3)
	flag_ok: [4]bool
	capset.supports_blob_id_0, flag_ok[0] = capset_flag(data, 4)
	for index in 0 ..< VENUS_EXTENSION_MASK_WORDS {
		capset.vk_extension_mask[index] = capset_word(data, 5 + index)
	}
	capset.allow_vk_wait_syncs, flag_ok[1] = capset_flag(data, 37)
	capset.supports_multiple_timelines, flag_ok[2] = capset_flag(data, 38)
	capset.use_guest_vram, flag_ok[3] = capset_flag(data, 39)
	for ok in flag_ok {
		if !ok {
			return {}, .Capset_Boolean_Invalid
		}
	}
	return capset, .None
}

// venus_capset_encode writes the 160 capset bytes as a host does. The tests
// use it to stand for the host.
venus_capset_encode :: proc "contextless" (capset: Venus_Capset, destination: []u8) -> (written: int, problem: Venus_Problem) {
	if len(destination) < VENUS_CAPSET_BYTES {
		return 0, .Buffer_Too_Short
	}
	byte_order.write_u32_little_endian(destination, 0, capset.wire_format_version)
	byte_order.write_u32_little_endian(destination, 4, capset.vk_xml_version)
	byte_order.write_u32_little_endian(destination, 8, capset.vk_ext_command_serialization_spec_version)
	byte_order.write_u32_little_endian(destination, 12, capset.vk_mesa_venus_protocol_spec_version)
	byte_order.write_u32_little_endian(destination, 16, capset.supports_blob_id_0 ? 1 : 0)
	for index in 0 ..< VENUS_EXTENSION_MASK_WORDS {
		byte_order.write_u32_little_endian(destination, 20 + index * 4, capset.vk_extension_mask[index])
	}
	byte_order.write_u32_little_endian(destination, 148, capset.allow_vk_wait_syncs ? 1 : 0)
	byte_order.write_u32_little_endian(destination, 152, capset.supports_multiple_timelines ? 1 : 0)
	byte_order.write_u32_little_endian(destination, 156, capset.use_guest_vram ? 1 : 0)
	return VENUS_CAPSET_BYTES, .None
}
