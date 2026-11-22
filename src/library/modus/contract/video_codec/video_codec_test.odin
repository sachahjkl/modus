#+build !freestanding
package video_codec

import "core:testing"

@(test)
video_codec_keyframe_and_sparse_delta_lossless_round_trip :: proc(t: ^testing.T) {
	_, bad := frame_kind_of_word(99)
	testing.expect(t, !bad)

	W :: u16(64)
	H :: u16(48)
	frame1: [int(W) * int(H) * 4]u8
	for i in 0 ..< len(frame1) {
		frame1[i] = u8((i / 4) % 17)
	}
	wire: [32768]u8
	key_n, key_tiles, r1 := encode_frame(W, H, frame1[:], nil, wire[:])
	testing.expect_value(t, r1, Codec_Refusal.None)
	testing.expect_value(t, key_tiles, 12) // 4x3 tiles
	testing.expect(t, key_n < len(frame1)) // LZ4 compresses desktop patterns significantly!

	recon: [len(frame1)]u8
	dec_tiles, r2 := decode_frame(wire[:key_n], W, H, recon[:])
	testing.expect_value(t, r2, Codec_Refusal.None)
	testing.expect_value(t, dec_tiles, 12)
	testing.expect(t, recon == frame1)

	// Change a single pixel -> delta encodes ONLY 1 of 12 tiles!
	frame2 := frame1
	frame2[128] = 0xEE
	delta_n, delta_tiles, r3 := encode_frame(W, H, frame2[:], frame1[:], wire[:])
	testing.expect_value(t, r3, Codec_Refusal.None)
	testing.expect_value(t, delta_tiles, 1)
	testing.expect(t, delta_n < 128) // Tiny compressed single-tile delta!

	dec2, r4 := decode_frame(wire[:delta_n], W, H, recon[:])
	testing.expect_value(t, r4, Codec_Refusal.None)
	testing.expect_value(t, dec2, 1)
	testing.expect(t, recon == frame2)

	// Corrupt magic & trailing byte refused.
	bad_wire := wire[:delta_n]
	bad_wire[0] = 0
	_, rb := decode_frame(bad_wire, W, H, recon[:])
	testing.expect_value(t, rb, Codec_Refusal.Bad_Magic)
}
