#+build !freestanding
#+build !modus
package blur_filter

import "core:testing"

@(test)
blur_filter_preserves_constant_color_and_smooths_impulse :: proc(t: ^testing.T) {
	W :: 16
	H :: 16
	pix: [W * H * 4]u8
	scratch: [W * H * 4]u8

	// Constant field stays invariant under blur.
	for i := 0; i < len(pix); i += 4 {
		pix[i + 0] = 80
		pix[i + 1] = 160
		pix[i + 2] = 240
		pix[i + 3] = 255
	}
	testing.expect_value(t, blur_rgba_separable(pix[:], scratch[:], W, H, 2, 3), Blur_Refusal.None)
	testing.expect_value(t, pix[(8 * W + 8) * 4 + 1], u8(160))

	// Impulse at center spreads energy symmetrically to neighbors.
	pix = {}
	pix[(8 * W + 8) * 4 + 0] = 255
	testing.expect_value(t, blur_rgba_separable(pix[:], scratch[:], W, H, 1, 1), Blur_Refusal.None)
	center := pix[(8 * W + 8) * 4 + 0]
	neighbor := pix[(8 * W + 7) * 4 + 0]
	testing.expect(t, center > 0 && center < 255)
	testing.expect_value(t, neighbor, center)

	// Invalid radius and small scratch refused.
	testing.expect_value(t, blur_rgba_separable(pix[:], scratch[:], W, H, MAX_BLUR_RADIUS + 1, 1), Blur_Refusal.Radius_Too_Large)
	testing.expect_value(t, blur_rgba_separable(pix[:], scratch[:16], W, H, 1, 1), Blur_Refusal.Scratch_Too_Small)
}
