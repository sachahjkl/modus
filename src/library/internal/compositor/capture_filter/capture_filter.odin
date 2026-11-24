package capture_filter

// Capture masking for windows that must never enter Screen_View or
// remote_display frames (src/md/features/several_principals.md,
// "The seat, and a display for each session").
//
// Operates purely on pixel buffers and screen-space rectangles so host tests
// verify clipping, partial overlaps, off-screen windows, and movement.

// Screen-space rectangle in pixels.
Rect :: struct {
	x:      int,
	y:      int,
	width:  int,
	height: int,
}

// Solid opaque dark mask pixel written over excluded window regions.
MASK_PIXEL :: u32(0xFF101218)

// rect_intersection computes the pixel overlap of two screen rectangles.
// Returns ok = false when either rectangle is empty or they do not overlap.
rect_intersection :: proc "contextless" (a, b: Rect) -> (hit: Rect, ok: bool) {
	if a.width <= 0 || a.height <= 0 || b.width <= 0 || b.height <= 0 {
		return {}, false
	}
	a_right := i64(a.x) + i64(a.width)
	a_bottom := i64(a.y) + i64(a.height)
	b_right := i64(b.x) + i64(b.width)
	b_bottom := i64(b.y) + i64(b.height)
	left := max(i64(a.x), i64(b.x))
	top := max(i64(a.y), i64(b.y))
	right := min(a_right, b_right)
	bottom := min(a_bottom, b_bottom)
	if right <= left || bottom <= top {
		return {}, false
	}
	return Rect{
		x      = int(left),
		y      = int(top),
		width  = int(right - left),
		height = int(bottom - top),
	}, true
}

// mask_excluded_regions overwrites every pixel of `pixels` that falls inside
// both `captured` (the screen rectangle backed by `pixels` starting at
// `(captured.x, captured.y)`) and any rectangle in `excluded` with `mask_pixel`.
// Returns the count of excluded rectangles that intersected `captured`, or -1
// when buffer bounds or stride are out of range.
mask_excluded_regions :: proc "contextless" (
	pixels: []u32,
	stride: int,
	captured: Rect,
	excluded: []Rect,
	mask_pixel: u32 = MASK_PIXEL,
) -> int {
	if captured.width <= 0 || captured.height <= 0 || stride < captured.width {
		return -1
	}
	needed := i64(captured.height - 1) * i64(stride) + i64(captured.width)
	if needed > i64(len(pixels)) {
		return -1
	}
	masked := 0
	for region in excluded {
		hit, overlaps := rect_intersection(captured, region)
		if !overlaps {
			continue
		}
		masked += 1
		local_x := hit.x - captured.x
		local_y := hit.y - captured.y
		for row in 0 ..< hit.height {
			base := (local_y + row) * stride + local_x
			for col in 0 ..< hit.width {
				pixels[base + col] = mask_pixel
			}
		}
	}
	return masked
}
