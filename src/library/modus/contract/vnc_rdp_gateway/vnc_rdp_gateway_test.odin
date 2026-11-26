#+build !freestanding
#+build !modus
package vnc_rdp_gateway

import "core:testing"

@(test)
vnc_rfb_banner_events_and_raw_update_round_trip :: proc(t: ^testing.T) {
	_, bad_p := gateway_protocol_of_word(99)
	testing.expect(t, !bad_p)

	testing.expect_value(t, rfb_parse_banner(transmute([]u8)string("RFB 003.008\n")), Gateway_Refusal.None)
	testing.expect_value(t, rfb_parse_banner(transmute([]u8)string("RFB 003.003\n")), Gateway_Refusal.Bad_Banner)
	testing.expect_value(t, rfb_parse_banner([]u8{1, 2}), Gateway_Refusal.Truncated)

	// KeyEvent: down=1, keysym='A' (0x41).
	ke, rk := rfb_decode_key_event([]u8{4, 1, 0, 0, 0, 0, 0, 0x41})
	testing.expect_value(t, rk, Gateway_Refusal.None)
	testing.expect(t, ke.down && ke.keysym == 0x41)

	// PointerEvent bounds check refuses OOB coordinates.
	_, rp_oob := rfb_decode_pointer_event([]u8{5, 1, 0x07, 0x80, 0x00, 0x10}, 1920, 1080)
	testing.expect_value(t, rp_oob, Gateway_Refusal.Dimensions_Invalid)
	pe, rp := rfb_decode_pointer_event([]u8{5, 1, 0x00, 0x64, 0x00, 0x32}, 1920, 1080)
	testing.expect_value(t, rp, Gateway_Refusal.None)
	testing.expect(t, pe.buttons == 1 && pe.x == 100 && pe.y == 50)

	// A screen past 8K in either side is refused; an 8K screen takes a
	// pointer at its last pixel and refuses one past it.
	_, wide := rfb_decode_pointer_event([]u8{5, 0, 0, 0, 0, 0}, MAX_GATEWAY_WIDTH + 1, 1080)
	testing.expect_value(t, wide, Gateway_Refusal.Dimensions_Invalid)
	_, tall := rfb_decode_pointer_event([]u8{5, 0, 0, 0, 0, 0}, 1920, MAX_GATEWAY_HEIGHT + 1)
	testing.expect_value(t, tall, Gateway_Refusal.Dimensions_Invalid)
	_, past := rfb_decode_pointer_event([]u8{5, 0, 0x1E, 0x00, 0x00, 0x00}, MAX_GATEWAY_WIDTH, MAX_GATEWAY_HEIGHT)
	testing.expect_value(t, past, Gateway_Refusal.Dimensions_Invalid)
	corner, at_corner := rfb_decode_pointer_event([]u8{5, 0, 0x1D, 0xFF, 0x10, 0xDF}, MAX_GATEWAY_WIDTH, MAX_GATEWAY_HEIGHT)
	testing.expect_value(t, at_corner, Gateway_Refusal.None)
	testing.expect(t, corner.x == 7679 && corner.y == 4319)

	// 2x2 RGBA Raw FramebufferUpdate.
	pixels: [16]u8
	pixels[0] = 0xFF
	out: [64]u8
	n, ru := rfb_encode_raw_update(Rfb_Rect{x = 10, y = 20, width = 2, height = 2}, pixels[:], out[:])
	testing.expect_value(t, ru, Gateway_Refusal.None)
	testing.expect_value(t, n, 32)
	testing.expect_value(t, out[16], u8(0xFF))
}

@(test)
rdp_x224_cr_and_cc_framing :: proc(t: ^testing.T) {
	cr := [19]u8{
		3, 0, 0, 19, // TPKT v3, len 19
		14, 0xE0, 0, 0, 0, 0, 0, // X.224 CR
		0x01, 0x00, 0x08, 0x00, 0x01, 0x00, 0x00, 0x00, // RDP_NEG_REQ: TLS
	}
	req, r := rdp_decode_x224_cr(cr[:])
	testing.expect_value(t, r, Gateway_Refusal.None)
	testing.expect(t, req.has_neg_req && req.requested_protocols == RDP_PROTOCOL_TLS)

	// Bad TPKT version refused.
	bad := cr
	bad[0] = 2
	_, rb := rdp_decode_x224_cr(bad[:])
	testing.expect_value(t, rb, Gateway_Refusal.Bad_Header)

	// Encode Connection Confirm.
	cc: [19]u8
	n, rcc := rdp_encode_x224_cc(RDP_PROTOCOL_TLS, cc[:])
	testing.expect_value(t, rcc, Gateway_Refusal.None)
	testing.expect_value(t, n, 19)
	testing.expect_value(t, cc[5], X224_TPDU_CC)
}
