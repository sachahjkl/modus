#+build !freestanding
package scale_factor

import "core:testing"

@(test)
view_zoom_steps_composition_and_hit_test_inverse :: proc(t: ^testing.T) {
	_, bad := view_zoom_of_word(99)
	testing.expect(t, !bad)
	z1, ok1 := view_zoom_of_word(u64(View_Zoom.Two))
	testing.expect(t, ok1 && z1 == .Two)

	// Stepping in/out clamps cleanly at .Half and .Four.
	testing.expect_value(t, view_zoom_step(.One, 1), View_Zoom.Nine_Eighths)
	testing.expect_value(t, view_zoom_step(.One, -1), View_Zoom.Seven_Eighths)
	testing.expect_value(t, view_zoom_step(.One, 100), View_Zoom.Four)
	testing.expect_value(t, view_zoom_step(.One, -100), View_Zoom.Half)

	// At View_Zoom.One (8/8), view_screen_pixel matches screen_pixel_of_logical_pixel exactly.
	for px in i32(-64) ..= i32(256) {
		testing.expect_value(t, view_screen_pixel(px, .Ten_Eighths, .One), screen_pixel_of_logical_pixel(px, .Ten_Eighths))
	}

	// At desktop 1.25x (10/8) * view 2.0x (16/8) = 2.5x (160/64): 8 view pixels = 20 screen pixels.
	testing.expect_value(t, view_screen_pixel(8, .Ten_Eighths, .Two), i64(20))
	testing.expect_value(t, view_screen_pixel(100, .Ten_Eighths, .Two), i64(250))

	// Pointer hit-testing inverse maps each screen pixel cleanly to its owning view pixel.
	for sp in i32(0) ..< i32(100) {
		vp := view_logical_pixel(sp, .Ten_Eighths, .Two)
		left := view_screen_pixel(i32(vp), .Ten_Eighths, .Two)
		right := view_screen_pixel(i32(vp + 1), .Ten_Eighths, .Two)
		testing.expect(t, i64(sp) >= left && i64(sp) < right)
	}
}
