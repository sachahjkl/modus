package key_path

// The packets of a PS/2 mouse, as code with no kernel entry, so that a test
// of the host runs them. The input service gives each byte of the mouse to
// mouse_decoder_byte, which gives a Pointer_Packet when a packet is whole.

// The protocols of a PS/2 mouse, by the identity that the mouse answers
// after the sample rates 200, 100 and 80.
Mouse_Protocol :: enum u8 {
	Standard, // Packets of 3 bytes, no wheel.
	Wheel, // IntelliMouse (MOUSE_IDENTITY_WHEEL): packets of 4 bytes; the fourth byte is the notches, MOUSE_WHEEL_LEAST to MOUSE_WHEEL_MOST.
	Wheel_And_Buttons, // IntelliMouse Explorer (MOUSE_IDENTITY_WHEEL_AND_BUTTONS): packets of 4 bytes; the low 4 bits of the fourth byte are the notches, bits 4 and 5 two more buttons, bits 6 and 7 zero.
}

MOUSE_IDENTITY_WHEEL :: 3
MOUSE_IDENTITY_WHEEL_AND_BUTTONS :: 4

MOUSE_PACKET_BYTES_STANDARD :: 3
MOUSE_PACKET_BYTES_WITH_WHEEL :: 4

// The bits of the first byte of a packet.
MOUSE_FIRST_BYTE_BUTTONS :: 0x07 // Left, right, middle.
MOUSE_FIRST_BYTE_ALWAYS_SET :: 0x08 // Set in each first byte: the packets find their start by it.
MOUSE_FIRST_BYTE_SIGN_X :: 0x10
MOUSE_FIRST_BYTE_SIGN_Y :: 0x20
MOUSE_FIRST_BYTE_OVERFLOW_X :: 0x40
MOUSE_FIRST_BYTE_OVERFLOW_Y :: 0x80
// A move is 9 bits: a byte, and its sign in the first byte.
MOUSE_MOTION_RANGE :: 256
// The fourth byte of the protocol Wheel: a count of 4 bits, signed, in a
// whole byte.
MOUSE_WHEEL_LEAST :: -8
MOUSE_WHEEL_MOST :: 7
// The fourth byte of the protocol Wheel_And_Buttons: the notches in its low
// 4 bits, signed, and two bits that are always 0.
MOUSE_WHEEL_LOW_BITS :: 0x0F
MOUSE_WHEEL_LOW_RANGE :: 16
MOUSE_EXPLORER_ZERO_BITS :: 0xC0

// The state of the packets of one mouse.
Mouse_Decoder :: struct {
	protocol: Mouse_Protocol,
	bytes:    [MOUSE_PACKET_BYTES_WITH_WHEEL]u8, // The bytes of the packet that is not whole yet.
	count:    int, // The bytes of `bytes` in use.
	resyncs:  u64, // The packets whose fourth byte was not a count of notches: the start was a wrong byte.
	overflows: u64, // The packets that a move too fast for 9 bits made false, and that were dropped.
}

// mouse_protocol_of_identity gives the protocol of a mouse by the identity
// that it answered.
mouse_protocol_of_identity :: proc "contextless" (identity: u8) -> Mouse_Protocol {
	switch identity {
	case MOUSE_IDENTITY_WHEEL:
		return .Wheel
	case MOUSE_IDENTITY_WHEEL_AND_BUTTONS:
		return .Wheel_And_Buttons
	}
	return .Standard
}

// mouse_packet_bytes gives the bytes of one packet of a protocol.
mouse_packet_bytes :: proc "contextless" (protocol: Mouse_Protocol) -> int {
	return protocol == .Standard ? MOUSE_PACKET_BYTES_STANDARD : MOUSE_PACKET_BYTES_WITH_WHEEL
}

// mouse_wheel_of gives the notches of the fourth byte of a packet, toward
// the principal. valid is false for a byte that the protocol never sends:
// the packet did not start at its first byte.
mouse_wheel_of :: proc "contextless" (protocol: Mouse_Protocol, value: u8) -> (notches: i64, valid: bool) {
	switch protocol {
	case .Standard:
		return 0, true
	case .Wheel:
		notches = i64(i8(value))
		if notches < MOUSE_WHEEL_LEAST || notches > MOUSE_WHEEL_MOST {
			return 0, false
		}
		return notches, true
	case .Wheel_And_Buttons:
		if value & MOUSE_EXPLORER_ZERO_BITS != 0 {
			return 0, false
		}
		notches = i64(value & MOUSE_WHEEL_LOW_BITS)
		if notches >= MOUSE_WHEEL_LOW_RANGE / 2 {
			notches -= MOUSE_WHEEL_LOW_RANGE
		}
		return notches, true
	}
	return 0, false
}

// mouse_decoder_byte takes one byte of the mouse. whole is true when the
// byte ends a packet that is right: packet holds its move, its buttons and
// its notches toward the principal.
//
// - A first byte without MOUSE_FIRST_BYTE_ALWAYS_SET is not the start of a
//   packet, and is dropped.
// - A fourth byte that the protocol never sends says that the packet began
//   at a wrong byte: the first byte is dropped, and the packet starts again
//   at the next byte that can be a first byte. Else a byte of a move read
//   as notches would move a view by a hundred lines.
// - A packet with an overflow bit holds a false move: it is dropped, and
//   the next byte starts a packet.
mouse_decoder_byte :: proc "contextless" (decoder: ^Mouse_Decoder, value: u8) -> (packet: Pointer_Packet, whole: bool) {
	if decoder.count == 0 && value & MOUSE_FIRST_BYTE_ALWAYS_SET == 0 {
		return {}, false
	}
	decoder.bytes[decoder.count] = value
	decoder.count += 1
	if decoder.count < mouse_packet_bytes(decoder.protocol) {
		return {}, false
	}
	notches: i64
	if decoder.protocol != .Standard {
		valid: bool
		notches, valid = mouse_wheel_of(decoder.protocol, decoder.bytes[MOUSE_PACKET_BYTES_WITH_WHEEL - 1])
		if !valid {
			decoder.resyncs += 1
			mouse_decoder_start_again(decoder)
			return {}, false
		}
	}
	decoder.count = 0
	first := decoder.bytes[0]
	if first & (MOUSE_FIRST_BYTE_OVERFLOW_X | MOUSE_FIRST_BYTE_OVERFLOW_Y) != 0 {
		decoder.overflows += 1
		return {}, false
	}
	motion_x := i64(decoder.bytes[1]) - (first & MOUSE_FIRST_BYTE_SIGN_X != 0 ? MOUSE_MOTION_RANGE : 0)
	motion_y := i64(decoder.bytes[2]) - (first & MOUSE_FIRST_BYTE_SIGN_Y != 0 ? MOUSE_MOTION_RANGE : 0)
	// The mouse counts y up; the screen counts it down.
	return {motion_x = motion_x, motion_y = -motion_y, buttons = u64(first & MOUSE_FIRST_BYTE_BUTTONS), wheel = notches}, true
}

// mouse_decoder_start_again drops the first byte of the packet, then each
// byte after it that cannot be a first byte: the packet starts again at
// the next byte that can.
@(private = "file")
mouse_decoder_start_again :: proc "contextless" (decoder: ^Mouse_Decoder) {
	for {
		for index in 1 ..< decoder.count {
			decoder.bytes[index - 1] = decoder.bytes[index]
		}
		decoder.count -= 1
		if decoder.count == 0 || decoder.bytes[0] & MOUSE_FIRST_BYTE_ALWAYS_SET != 0 {
			return
		}
	}
}
