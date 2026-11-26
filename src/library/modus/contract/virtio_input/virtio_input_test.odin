#+build !freestanding
#+build !modus
package virtio_input

import "core:testing"

// The border of Raw_Event decoding refuses every unknown event type,
// unknown code for each known type, and invalid button state, returning
// the zero Decoded_Event in every refusal.
@(test)
event_decode_refuses_unknown_types_codes_and_button_values :: proc(t: ^testing.T) {
	unknown_types := [?]u16{u16(max(Event_Type)) + 1, 0x04, 0x05, 0x100, max(u16)}
	for word in unknown_types {
		decoded, problem := event_decode({type_word = word, code_word = 0, value = 0})
		testing.expectf(t, problem == .Unknown_Event_Type, "type %d gave %v", word, problem)
		testing.expect_value(t, decoded, Decoded_Event{})
	}

	unknown_syn_codes := [?]u16{1, 2, 0xFFFF}
	for code in unknown_syn_codes {
		decoded, problem := event_decode({type_word = u16(Event_Type.Syn), code_word = code, value = 0})
		testing.expectf(t, problem == .Unknown_Event_Code, "syn code %d gave %v", code, problem)
		testing.expect_value(t, decoded, Decoded_Event{})
	}

	unknown_abs_codes := [?]u16{2, 3, 0x35, max(u16)}
	for code in unknown_abs_codes {
		decoded, problem := event_decode({type_word = u16(Event_Type.Abs), code_word = code, value = 100})
		testing.expectf(t, problem == .Unknown_Event_Code, "abs code %d gave %v", code, problem)
		testing.expect_value(t, decoded, Decoded_Event{})
	}

	unknown_rel_codes := [?]u16{0, 1, 7, 9, max(u16)}
	for code in unknown_rel_codes {
		decoded, problem := event_decode({type_word = u16(Event_Type.Rel), code_word = code, value = 1})
		testing.expectf(t, problem == .Unknown_Event_Code, "rel code %d gave %v", code, problem)
		testing.expect_value(t, decoded, Decoded_Event{})
	}

	unknown_key_codes := [?]u16{0, 1, u16(Button_Code.Left) - 1, u16(Button_Code.Middle) + 1, max(u16)}
	for code in unknown_key_codes {
		decoded, problem := event_decode({type_word = u16(Event_Type.Key), code_word = code, value = 1})
		testing.expectf(t, problem == .Unknown_Event_Code, "key code %d gave %v", code, problem)
		testing.expect_value(t, decoded, Decoded_Event{})
	}

	bad_button_values := [?]i32{-1, 2, 3, min(i32), max(i32)}
	for val in bad_button_values {
		decoded, problem := event_decode({type_word = u16(Event_Type.Key), code_word = u16(Button_Code.Left), value = val})
		testing.expectf(t, problem == .Bad_Button_Value, "button value %d gave %v", val, problem)
		testing.expect_value(t, decoded, Decoded_Event{})
	}

	// Valid events pass the border and carry their closed enum members.
	syn, syn_problem := event_decode({type_word = u16(Event_Type.Syn), code_word = u16(Syn_Code.Report), value = 0})
	testing.expect(t, syn_problem == .None && syn.event_type == .Syn && syn.syn_code == .Report)

	abs_x, abs_problem := event_decode({type_word = u16(Event_Type.Abs), code_word = u16(Abs_Axis.X), value = 16384})
	testing.expect(t, abs_problem == .None && abs_x.event_type == .Abs && abs_x.abs_axis == .X && abs_x.value == 16384)

	abs_y, abs_y_problem := event_decode({type_word = u16(Event_Type.Abs), code_word = u16(Abs_Axis.Y), value = -5})
	testing.expect(t, abs_y_problem == .None && abs_y.event_type == .Abs && abs_y.abs_axis == .Y && abs_y.value == -5)

	wheel, wheel_problem := event_decode({type_word = u16(Event_Type.Rel), code_word = u16(Rel_Axis.Wheel), value = -3})
	testing.expect(t, wheel_problem == .None && wheel.event_type == .Rel && wheel.rel_axis == .Wheel && wheel.value == -3)

	for button in Button_Code {
		for val in ([2]i32{0, 1}) {
			btn, btn_problem := event_decode({type_word = u16(Event_Type.Key), code_word = u16(button), value = val})
			testing.expect(t, btn_problem == .None && btn.event_type == .Key && btn.button_code == button && btn.value == val)
		}
	}
}

// Config_Select border refuses unknown bytes and accepts each defined selector.
@(test)
config_select_border_refuses_unknown_selectors :: proc(t: ^testing.T) {
	unknown := [?]u8{0x04, 0x0F, 0x13, 0xFF}
	for word in unknown {
		_, ok := config_select_of_word(word)
		testing.expectf(t, !ok, "selector %x was accepted", word)
	}
	for member in Config_Select {
		selected, ok := config_select_of_word(u8(member))
		testing.expectf(t, ok && selected == member, "selector %v failed", member)
	}
}

// Wire serialization and deserialization refuse short slices and round-trip
// exact little-endian bytes, including negative values.
@(test)
wire_event_and_abs_info_bytes_round_trip :: proc(t: ^testing.T) {
	short: [EVENT_SIZE - 1]u8
	_, ok := event_from_bytes(short[:])
	testing.expect(t, !ok)
	testing.expect(t, !event_to_bytes({}, short[:]))

	buf: [EVENT_SIZE]u8
	original := Raw_Event{type_word = u16(Event_Type.Abs), code_word = u16(Abs_Axis.Y), value = -123456}
	testing.expect(t, event_to_bytes(original, buf[:]))
	read, read_ok := event_from_bytes(buf[:])
	testing.expect(t, read_ok && read == original)

	short_abs: [ABS_INFO_SIZE - 1]u8
	_, abs_ok := abs_info_from_bytes(short_abs[:])
	testing.expect(t, !abs_ok)

	abs_buf: [ABS_INFO_SIZE]u8
	// minimum = 0, maximum = 32767 (0x7FFF), fuzz = 0, flat = 0, resolution = 100
	abs_buf[4], abs_buf[5] = 0xFF, 0x7F
	abs_buf[16] = 100
	info, info_ok := abs_info_from_bytes(abs_buf[:])
	testing.expect(t, info_ok && info.minimum == 0 && info.maximum == 32767 && info.resolution == 100)
}

// Coordinate scaling refuses invalid ranges (min >= max) and zero screen
// extent, clamps out-of-range values to edges, maps endpoints exactly, and
// never overflows u64 even at the extremes of i32 and u32.
@(test)
scale_axis_coordinate_refuses_bad_inputs_and_maps_edges_exactly :: proc(t: ^testing.T) {
	bad_ranges := [?]Axis_Range{
		{0, 0},
		{1, 1},
		{32767, 32767},
		{10, 9},
		{max(i32), min(i32)},
		{-5, -10},
	}
	for r in bad_ranges {
		pixel, problem := scale_axis_coordinate(0, r, 1280)
		testing.expectf(t, problem == .Bad_Axis_Range && pixel == 0, "range %v gave (%d, %v)", r, pixel, problem)
	}

	pixel, problem := scale_axis_coordinate(100, {0, 32767}, 0)
	testing.expect(t, problem == .Zero_Screen_Extent && pixel == 0)

	// Screen extent of 1 always maps to pixel 0.
	for val in ([?]i32{min(i32), -1, 0, 16384, 32767, max(i32)}) {
		p, pr := scale_axis_coordinate(val, {0, 32767}, 1)
		testing.expect(t, pr == .None && p == 0)
	}

	// Standard QEMU virtio-tablet-pci range [0..32767] onto 1280 and 1920.
	qemu := Axis_Range{ABSOLUTE_AXIS_DEFAULT_MINIMUM, ABSOLUTE_AXIS_DEFAULT_MAXIMUM}
	cases := [?]struct {
		raw:      i32,
		extent:   u32,
		expected: u32,
	}{
		{0, 1280, 0},
		{32767, 1280, 1279},
		{16384, 1280, 640},
		{-1, 1280, 0},
		{min(i32), 1280, 0},
		{32768, 1280, 1279},
		{max(i32), 1280, 1279},
		{0, 1920, 0},
		{32767, 1920, 1919},
		{0, 1080, 0},
		{32767, 1080, 1079},
		{16384, 1080, 540},
	}
	for c in cases {
		p, pr := scale_axis_coordinate(c.raw, qemu, c.extent)
		testing.expectf(t, pr == .None && p == c.expected, "raw=%d extent=%d gave (%d, %v), want %d", c.raw, c.extent, p, pr, c.expected)
	}

	// Non-zero and negative axis ranges.
	shifted := Axis_Range{-1000, 1000}
	p_min, pr_min := scale_axis_coordinate(-2000, shifted, 801)
	testing.expect(t, pr_min == .None && p_min == 0)
	p_mid, pr_mid := scale_axis_coordinate(0, shifted, 801)
	testing.expect(t, pr_mid == .None && p_mid == 400)
	p_max, pr_max := scale_axis_coordinate(2000, shifted, 801)
	testing.expect(t, pr_max == .None && p_max == 800)

	// Extreme full i32 span onto max(u32) extent: zero overflow.
	extreme := Axis_Range{min(i32), max(i32)}
	p_lo, pr_lo := scale_axis_coordinate(min(i32), extreme, max(u32))
	testing.expect(t, pr_lo == .None && p_lo == 0)
	p_hi, pr_hi := scale_axis_coordinate(max(i32), extreme, max(u32))
	testing.expect(t, pr_hi == .None && p_hi == max(u32) - 1)
	p_zero, pr_zero := scale_axis_coordinate(0, extreme, 1001)
	testing.expect(t, pr_zero == .None && p_zero == 500)

	// Monotonicity across the entire QEMU range on 1920 pixels.
	prev: u32 = 0
	for raw in i32(0) ..= 32767 {
		cur, cur_pr := scale_axis_coordinate(raw, qemu, 1920)
		testing.expect(t, cur_pr == .None && cur >= prev && cur < 1920)
		prev = cur
	}
	testing.expect_value(t, prev, u32(1919))
}
