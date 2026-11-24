#+build !freestanding
package capture_filter

import "core:testing"

@(test)
mask_excluded_regions_refuses_bad_buffers_and_empty_rects :: proc(t: ^testing.T) {
	pixels: [64]u32
	for &p in pixels {
		p = 0xFFAA5533
	}
	before := pixels
	excluded := [?]Rect{{x = 0, y = 0, width = 4, height = 4}}

	// Zero and negative dimensions, stride smaller than width, and short buffer.
	testing.expect_value(t, mask_excluded_regions(pixels[:], 8, {0, 0, 0, 4}, excluded[:]), -1)
	testing.expect_value(t, mask_excluded_regions(pixels[:], 8, {0, 0, 4, 0}, excluded[:]), -1)
	testing.expect_value(t, mask_excluded_regions(pixels[:], 8, {0, 0, -2, 4}, excluded[:]), -1)
	testing.expect_value(t, mask_excluded_regions(pixels[:], 3, {0, 0, 4, 4}, excluded[:]), -1)
	testing.expect_value(t, mask_excluded_regions(pixels[:15], 4, {0, 0, 4, 4}, excluded[:]), -1)
	testing.expect(t, pixels == before, "refused call must not mutate pixels")

	// Empty excluded list or non-overlapping rectangles change nothing.
	testing.expect_value(t, mask_excluded_regions(pixels[:], 8, {10, 10, 8, 8}, nil), 0)
	non_overlapping := [?]Rect{
		{x = 2, y = 10, width = 8, height = 8},   // touches left edge
		{x = 18, y = 10, width = 8, height = 8},  // touches right edge
		{x = 10, y = 2, width = 8, height = 8},   // touches top edge
		{x = 10, y = 18, width = 8, height = 8},  // touches bottom edge
		{x = 12, y = 12, width = 0, height = 4},  // empty width
		{x = 12, y = 12, width = 4, height = -1}, // negative height
	}
	testing.expect_value(t, mask_excluded_regions(pixels[:], 8, {10, 10, 8, 8}, non_overlapping[:]), 0)
	testing.expect(t, pixels == before, "non-overlapping regions must not mutate pixels")
}

@(test)
mask_excluded_regions_clips_offscreen_partial_and_moving_unlock_windows :: proc(t: ^testing.T) {
	W :: 16
	H :: 12
	STRIDE :: 20 // Stride larger than width to test row stepping.
	SECRET :: u32(0xFFDEADBE)
	BACKGROUND :: u32(0xFF224466)

	pixels: [H * STRIDE]u32
	fill_screen :: proc(buf: []u32, bg: u32, secret: u32, unlock_rect: Rect, origin_x, origin_y: int) {
		for row in 0 ..< H {
			for col in 0 ..< W {
				sx := origin_x + col
				sy := origin_y + row
				inside := sx >= unlock_rect.x && sx < unlock_rect.x + unlock_rect.width && sy >= unlock_rect.y && sy < unlock_rect.y + unlock_rect.height
				buf[row * STRIDE + col] = inside ? secret : bg
			}
		}
	}

	// Case 1: unlock window partially off-screen (negative x/y) overlapping top-left corner by 1+ pixels.
	unlock_offscreen := Rect{x = -3, y = -2, width = 6, height = 5}
	captured := Rect{x = 0, y = 0, width = W, height = H}
	fill_screen(pixels[:], BACKGROUND, SECRET, unlock_offscreen, 0, 0)
	excluded := [?]Rect{unlock_offscreen}
	testing.expect_value(t, mask_excluded_regions(pixels[:], STRIDE, captured, excluded[:]), 1)
	for row in 0 ..< H {
		for col in 0 ..< W {
			got := pixels[row * STRIDE + col]
			testing.expect(t, got != SECRET, "secret pixel survived capture masking")
			expected := (col < 3 && row < 3) ? MASK_PIXEL : BACKGROUND
			testing.expect_value(t, got, expected)
		}
	}

	// Case 2: dirty rectangle offset on screen, unlock window overhangs right/bottom by 1 pixel overlap.
	dirty := Rect{x = 100, y = 200, width = W, height = H}
	unlock_corner := Rect{x = 100 + W - 1, y = 200 + H - 1, width = 50, height = 50}
	fill_screen(pixels[:], BACKGROUND, SECRET, unlock_corner, dirty.x, dirty.y)
	excluded = {unlock_corner}
	testing.expect_value(t, mask_excluded_regions(pixels[:], STRIDE, dirty, excluded[:]), 1)
	for row in 0 ..< H {
		for col in 0 ..< W {
			got := pixels[row * STRIDE + col]
			expected := (col == W - 1 && row == H - 1) ? MASK_PIXEL : BACKGROUND
			testing.expect_value(t, got, expected)
		}
	}

	// Case 3: unlock window moves across two frames — old region clean, new region fully masked.
	moved_unlock := Rect{x = 104, y = 203, width = 5, height = 4}
	fill_screen(pixels[:], BACKGROUND, SECRET, moved_unlock, dirty.x, dirty.y)
	excluded = {moved_unlock}
	testing.expect_value(t, mask_excluded_regions(pixels[:], STRIDE, dirty, excluded[:]), 1)
	for row in 0 ..< H {
		for col in 0 ..< W {
			got := pixels[row * STRIDE + col]
			in_moved := col >= 4 && col < 9 && row >= 3 && row < 7
			expected := in_moved ? MASK_PIXEL : BACKGROUND
			testing.expect_value(t, got, expected)
		}
	}

	// Case 4: unlock window covers entire captured rectangle.
	full_cover := Rect{x = 50, y = 50, width = 500, height = 500}
	fill_screen(pixels[:], BACKGROUND, SECRET, full_cover, dirty.x, dirty.y)
	excluded = {full_cover}
	testing.expect_value(t, mask_excluded_regions(pixels[:], STRIDE, dirty, excluded[:]), 1)
	for row in 0 ..< H {
		for col in 0 ..< W {
			testing.expect_value(t, pixels[row * STRIDE + col], MASK_PIXEL)
		}
	}
}
