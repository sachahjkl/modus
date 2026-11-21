// The contract of a virtio input device (VirtIO 1.2, section 5.8): device
// configuration selection, absolute axis metadata, the 8-byte wire event
// record, strict border decoding into closed enumerations, and exact
// integer coordinate scaling from an axis range onto screen pixels.
//
// All numbers on the wire are little-endian. This package allocates no
// memory and calls no kernel operation.
package virtio_input

import "modus:contract/byte_order"
import "modus:contract/enum_word"

// The virtqueue indices of a virtio input device.
EVENT_QUEUE_INDEX :: 0
STATUS_QUEUE_INDEX :: 1

// The byte offsets and sizes of the device-specific configuration space
// (virtio_input_config).
CONFIG_OFFSET_SELECT :: 0
CONFIG_OFFSET_SUBSEL :: 1
CONFIG_OFFSET_SIZE :: 2
CONFIG_OFFSET_DATA :: 8
CONFIG_DATA_CAPACITY :: 128
CONFIG_TOTAL_SIZE :: CONFIG_OFFSET_DATA + CONFIG_DATA_CAPACITY

// The size of one wire event record and of one Abs_Info record, in bytes.
EVENT_SIZE :: 8
ABS_INFO_SIZE :: 20

// The default absolute axis bounds that QEMU virtio-tablet-pci reports.
ABSOLUTE_AXIS_DEFAULT_MINIMUM :: i32(0)
ABSOLUTE_AXIS_DEFAULT_MAXIMUM :: i32(32767)

// The configuration query selector written to CONFIG_OFFSET_SELECT before
// reading CONFIG_OFFSET_SIZE and CONFIG_OFFSET_DATA.
Config_Select :: enum u8 {
	Unset     = 0x00,
	Id_Name   = 0x01,
	Id_Serial = 0x02,
	Id_Devids = 0x03,
	Prop_Bits = 0x10,
	Ev_Bits   = 0x11,
	Abs_Info  = 0x12,
}

// The closed set of Linux/VirtIO input event types that this system reads.
Event_Type :: enum u16 {
	Syn = 0x00,
	Key = 0x01,
	Rel = 0x02,
	Abs = 0x03,
}

// Synchronization event codes under Event_Type.Syn.
Syn_Code :: enum u16 {
	Report = 0x00,
}

// Absolute axis codes under Event_Type.Abs.
Abs_Axis :: enum u16 {
	X = 0x00,
	Y = 0x01,
}

// Relative axis codes under Event_Type.Rel.
Rel_Axis :: enum u16 {
	Wheel = 0x08,
}

// Pointer button codes under Event_Type.Key.
Button_Code :: enum u16 {
	Left   = 0x110,
	Right  = 0x111,
	Middle = 0x112,
}

// One 8-byte wire event record that the device writes into its event queue.
Raw_Event :: struct {
	type_word: u16,
	code_word: u16,
	value:     i32,
}
#assert(size_of(Raw_Event) == EVENT_SIZE)

// Absolute axis metadata read from CONFIG_OFFSET_DATA after selecting
// Config_Select.Abs_Info with subsel equal to an Abs_Axis value.
Abs_Info :: struct {
	minimum:    i32,
	maximum:    i32,
	fuzz:       i32,
	flat:       i32,
	resolution: i32,
}
#assert(size_of(Abs_Info) == ABS_INFO_SIZE)

// An inclusive integer range reported for an absolute axis.
Axis_Range :: struct {
	minimum: i32,
	maximum: i32,
}

// Why event_decode refused a Raw_Event at the border.
Decode_Problem :: enum u8 {
	None,
	Unknown_Event_Type,
	Unknown_Event_Code,
	Bad_Button_Value,
}

// Why scale_axis_coordinate or axis validation refused its arguments.
Scale_Problem :: enum u8 {
	None,
	Bad_Axis_Range,
	Zero_Screen_Extent,
}

// One decoded event past the border. Only the code field matching
// event_type carries a decoded member.
Decoded_Event :: struct {
	event_type:  Event_Type,
	syn_code:    Syn_Code,
	abs_axis:    Abs_Axis,
	rel_axis:    Rel_Axis,
	button_code: Button_Code,
	value:       i32,
}

// config_select_of_word checks a raw selector byte against Config_Select.
config_select_of_word :: proc "contextless" (word: u8) -> (selected: Config_Select, ok: bool) {
	return enum_word.member_of_word(Config_Select, u64(word))
}

// event_from_bytes reads one little-endian Raw_Event from the first
// EVENT_SIZE bytes. ok is false when fewer bytes are available.
event_from_bytes :: proc "contextless" (bytes: []u8) -> (raw: Raw_Event, ok: bool) {
	if len(bytes) < EVENT_SIZE {
		return {}, false
	}
	raw.type_word = byte_order.read_u16_little_endian(bytes, 0)
	raw.code_word = byte_order.read_u16_little_endian(bytes, 2)
	raw.value = i32(byte_order.read_u32_little_endian(bytes, 4))
	return raw, true
}

// event_to_bytes writes one little-endian Raw_Event into the first
// EVENT_SIZE bytes of out. Returns false when out is shorter than EVENT_SIZE.
event_to_bytes :: proc "contextless" (raw: Raw_Event, out: []u8) -> bool {
	if len(out) < EVENT_SIZE {
		return false
	}
	byte_order.write_u16_little_endian(out, 0, raw.type_word)
	byte_order.write_u16_little_endian(out, 2, raw.code_word)
	byte_order.write_u32_little_endian(out, 4, u32(raw.value))
	return true
}

// abs_info_from_bytes reads one little-endian Abs_Info from the first
// ABS_INFO_SIZE bytes. ok is false when fewer bytes are available.
abs_info_from_bytes :: proc "contextless" (bytes: []u8) -> (info: Abs_Info, ok: bool) {
	if len(bytes) < ABS_INFO_SIZE {
		return {}, false
	}
	info.minimum = i32(byte_order.read_u32_little_endian(bytes, 0))
	info.maximum = i32(byte_order.read_u32_little_endian(bytes, 4))
	info.fuzz = i32(byte_order.read_u32_little_endian(bytes, 8))
	info.flat = i32(byte_order.read_u32_little_endian(bytes, 12))
	info.resolution = i32(byte_order.read_u32_little_endian(bytes, 16))
	return info, true
}

// event_decode is the one border from wire words to closed enumerations.
// Unknown event types, unknown codes, and button values outside 0 or 1 are
// refused with the zero Decoded_Event.
event_decode :: proc "contextless" (raw: Raw_Event) -> (event: Decoded_Event, problem: Decode_Problem) {
	event_type, type_known := enum_word.member_of_word(Event_Type, u64(raw.type_word))
	if !type_known {
		return {}, .Unknown_Event_Type
	}
	switch event_type {
	case .Syn:
		code, known := enum_word.member_of_word(Syn_Code, u64(raw.code_word))
		if !known {
			return {}, .Unknown_Event_Code
		}
		return {event_type = .Syn, syn_code = code, value = raw.value}, .None
	case .Key:
		button, known := enum_word.member_of_word(Button_Code, u64(raw.code_word))
		if !known {
			return {}, .Unknown_Event_Code
		}
		if raw.value != 0 && raw.value != 1 {
			return {}, .Bad_Button_Value
		}
		return {event_type = .Key, button_code = button, value = raw.value}, .None
	case .Rel:
		axis, known := enum_word.member_of_word(Rel_Axis, u64(raw.code_word))
		if !known {
			return {}, .Unknown_Event_Code
		}
		return {event_type = .Rel, rel_axis = axis, value = raw.value}, .None
	case .Abs:
		axis, known := enum_word.member_of_word(Abs_Axis, u64(raw.code_word))
		if !known {
			return {}, .Unknown_Event_Code
		}
		return {event_type = .Abs, abs_axis = axis, value = raw.value}, .None
	}
	return {}, .Unknown_Event_Type
}

// axis_range_valid reports whether an axis range has minimum strictly less
// than maximum.
axis_range_valid :: proc "contextless" (axis_range: Axis_Range) -> bool {
	return axis_range.minimum < axis_range.maximum
}

// scale_axis_coordinate maps raw_value from axis_range [minimum..maximum]
// onto pixel coordinates [0..screen_extent-1] using exact 64-bit integer
// arithmetic with rounding to the nearest pixel and clamping at the edges.
//
// Invariants:
// - axis_range.minimum >= axis_range.maximum is refused with Bad_Axis_Range.
// - screen_extent == 0 is refused with Zero_Screen_Extent.
// - Values below minimum clamp to 0; values above maximum clamp to
//   screen_extent - 1.
// - No intermediate product or sum can overflow u64, even when
//   minimum == min(i32), maximum == max(i32), and screen_extent == max(u32).
scale_axis_coordinate :: proc "contextless" (raw_value: i32, axis_range: Axis_Range, screen_extent: u32) -> (pixel: u32, problem: Scale_Problem) {
	if !axis_range_valid(axis_range) {
		return 0, .Bad_Axis_Range
	}
	if screen_extent == 0 {
		return 0, .Zero_Screen_Extent
	}
	if screen_extent == 1 {
		return 0, .None
	}
	clamped := clamp(raw_value, axis_range.minimum, axis_range.maximum)
	offset := u64(i64(clamped) - i64(axis_range.minimum))
	span := u64(i64(axis_range.maximum) - i64(axis_range.minimum))
	target_maximum := u64(screen_extent - 1)
	// Maximum possible numerator is (2^32 - 1)^2 + (2^32 - 1)/2 < 2^64 - 1.
	scaled := (offset * target_maximum + span / 2) / span
	return u32(scaled), .None
}
