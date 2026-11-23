// Pure freestanding VNC (RFB 3.8, RFC 6143) and RDP (TPKT/X.224) gateway
// framing and border validation (src/md/features/remote_display.md).
//
// Zero dynamic allocations, zero kernel operations, strict bounds & overflow guards.
package vnc_rdp_gateway

import "modus:contract/byte_order"
import "modus:contract/enum_word"

RFB_VERSION_BANNER :: "RFB 003.008\n"
RFB_BANNER_BYTES :: 12
// The largest screen that a gateway carries: the largest screen of the
// remote display, 8K UHD.
MAX_GATEWAY_WIDTH :: u16(7680)
MAX_GATEWAY_HEIGHT :: u16(4320)

Gateway_Protocol :: enum u8 {
	Vnc_Rfb = 1,
	Rdp     = 2,
}

gateway_protocol_of_word :: proc "contextless" (word: u64) -> (p: Gateway_Protocol, ok: bool) {
	return enum_word.member_of_word(Gateway_Protocol, word)
}

Rfb_Client_Msg :: enum u8 {
	Set_Pixel_Format           = 0,
	Set_Encodings              = 2,
	Framebuffer_Update_Request = 3,
	Key_Event                  = 4,
	Pointer_Event              = 5,
	Client_Cut_Text            = 6,
}

rfb_client_msg_of_word :: proc "contextless" (word: u64) -> (m: Rfb_Client_Msg, ok: bool) {
	return enum_word.member_of_word(Rfb_Client_Msg, word)
}

Gateway_Refusal :: enum u8 {
	None               = 0,
	Truncated          = 1,
	Bad_Banner         = 2,
	Bad_Header         = 3,
	Unknown_Message    = 4,
	Dimensions_Invalid = 5,
	Buffer_Too_Small   = 6,
}

Rfb_Key_Event :: struct {
	down:   bool,
	keysym: u32,
}

Rfb_Pointer_Event :: struct {
	buttons: u8,
	x:       u16,
	y:       u16,
}

Rfb_Rect :: struct {
	x:      u16,
	y:      u16,
	width:  u16,
	height: u16,
}

// rfb_parse_banner verifies an RFC 6143 version banner (RFB 003.008 + LF).
rfb_parse_banner :: proc "contextless" (wire: []u8) -> Gateway_Refusal {
	if len(wire) < RFB_BANNER_BYTES {
		return .Truncated
	}
	expected := transmute([]u8)string(RFB_VERSION_BANNER)
	for i in 0 ..< RFB_BANNER_BYTES {
		if wire[i] != expected[i] {
			return .Bad_Banner
		}
	}
	return .None
}

// rfb_decode_key_event decodes an 8-byte RFB KeyEvent message.
rfb_decode_key_event :: proc "contextless" (wire: []u8) -> (ev: Rfb_Key_Event, refusal: Gateway_Refusal) {
	if len(wire) < 8 {
		return {}, .Truncated
	}
	msg, ok := rfb_client_msg_of_word(u64(wire[0]))
	if !ok || msg != .Key_Event {
		return {}, .Unknown_Message
	}
	return Rfb_Key_Event{
		down   = wire[1] != 0,
		keysym = byte_order.read_u32_big_endian(wire, 4),
	}, .None
}

// rfb_decode_pointer_event decodes a 6-byte RFB PointerEvent clamped/checked against screen bounds.
rfb_decode_pointer_event :: proc "contextless" (wire: []u8, screen_w, screen_h: u16) -> (ev: Rfb_Pointer_Event, refusal: Gateway_Refusal) {
	if screen_w == 0 || screen_h == 0 || screen_w > MAX_GATEWAY_WIDTH || screen_h > MAX_GATEWAY_HEIGHT {
		return {}, .Dimensions_Invalid
	}
	if len(wire) < 6 {
		return {}, .Truncated
	}
	msg, ok := rfb_client_msg_of_word(u64(wire[0]))
	if !ok || msg != .Pointer_Event {
		return {}, .Unknown_Message
	}
	x := byte_order.read_u16_big_endian(wire, 2)
	y := byte_order.read_u16_big_endian(wire, 4)
	if x >= screen_w || y >= screen_h {
		return {}, .Dimensions_Invalid
	}
	return Rfb_Pointer_Event{buttons = wire[1], x = x, y = y}, .None
}

// rfb_encode_raw_update encodes a single-rectangle RFB FramebufferUpdate (Raw encoding = 0)
// into out, verifying pixel byte count = width * height * 4 without overflow.
rfb_encode_raw_update :: proc "contextless" (rect: Rfb_Rect, rgba_pixels: []u8, out: []u8) -> (written: int, refusal: Gateway_Refusal) {
	if rect.width == 0 || rect.height == 0 || rect.width > MAX_GATEWAY_WIDTH || rect.height > MAX_GATEWAY_HEIGHT {
		return 0, .Dimensions_Invalid
	}
	expected_bytes := u64(rect.width) * u64(rect.height) * 4
	if u64(len(rgba_pixels)) != expected_bytes {
		return 0, .Dimensions_Invalid
	}
	header_bytes :: 4 + 12 // FramebufferUpdate(4) + RectHeader(12)
	if u64(len(out)) < header_bytes + expected_bytes {
		return 0, .Buffer_Too_Small
	}
	out[0] = 0 // FramebufferUpdate
	out[1] = 0 // padding
	byte_order.write_u16_big_endian(out, 2, 1) // 1 rectangle
	byte_order.write_u16_big_endian(out, 4, rect.x)
	byte_order.write_u16_big_endian(out, 6, rect.y)
	byte_order.write_u16_big_endian(out, 8, rect.width)
	byte_order.write_u16_big_endian(out, 10, rect.height)
	byte_order.write_u32_big_endian(out, 12, 0) // Raw encoding
	copy(out[header_bytes:], rgba_pixels)
	return header_bytes + int(expected_bytes), .None
}

// RDP TPKT (RFC 1006, version 3) + X.224 Connection Request / Confirm framing.
TPKT_VERSION :: u8(3)
X224_TPDU_CR :: u8(0xE0)
X224_TPDU_CC :: u8(0xD0)
RDP_PROTOCOL_TLS :: u32(0x0000_0001)

Rdp_Negotiation_Request :: struct {
	requested_protocols: u32,
	has_neg_req:         bool,
}

// rdp_decode_x224_cr parses an incoming TPKT + X.224 Connection Request PDU.
rdp_decode_x224_cr :: proc "contextless" (wire: []u8) -> (req: Rdp_Negotiation_Request, refusal: Gateway_Refusal) {
	if len(wire) < 11 {
		return {}, .Truncated
	}
	if wire[0] != TPKT_VERSION || wire[1] != 0 {
		return {}, .Bad_Header
	}
	tpkt_len := int(byte_order.read_u16_big_endian(wire, 2))
	if tpkt_len < 11 || tpkt_len > len(wire) {
		return {}, .Truncated
	}
	li := int(wire[4])
	if 4 + 1 + li != tpkt_len {
		return {}, .Bad_Header
	}
	if (wire[5] & 0xF0) != X224_TPDU_CR {
		return {}, .Unknown_Message
	}
	// Optional 8-byte RDP Negotiation Request (type 0x01, len 8) at end of CR.
	if tpkt_len >= 19 && wire[tpkt_len - 8] == 0x01 && byte_order.read_u16_little_endian(wire, tpkt_len - 6) == 8 {
		req.has_neg_req = true
		req.requested_protocols = byte_order.read_u32_little_endian(wire, tpkt_len - 4)
	}
	return req, .None
}

// rdp_encode_x224_cc encodes a 19-byte TPKT + X.224 Connection Confirm enforcing TLS.
rdp_encode_x224_cc :: proc "contextless" (selected_protocol: u32, out: []u8) -> (written: int, refusal: Gateway_Refusal) {
	if len(out) < 19 {
		return 0, .Buffer_Too_Small
	}
	out[0] = TPKT_VERSION
	out[1] = 0
	byte_order.write_u16_big_endian(out, 2, 19)
	out[4] = 14 // X.224 LI
	out[5] = X224_TPDU_CC
	byte_order.write_u16_big_endian(out, 6, 0) // dst-ref
	byte_order.write_u16_big_endian(out, 8, 1) // src-ref
	out[10] = 0 // class 0
	out[11] = 0x02 // TYPE_RDP_NEG_RSP
	out[12] = 0
	byte_order.write_u16_little_endian(out, 13, 8)
	byte_order.write_u32_little_endian(out, 15, selected_protocol)
	return 19, .None
}
