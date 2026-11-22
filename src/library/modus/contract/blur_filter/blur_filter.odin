// Pure freestanding separable RGBA box/Gaussian-approximation blur filter
// for surfaces and GPU draw-table blur operations.
//
// Operates strictly in integer arithmetic with caller-supplied scratch buffer
// (zero dynamic allocation, zero floating-point drift, exact edge clamping).
package blur_filter

MAX_BLUR_RADIUS :: 64
MAX_SURFACE_DIM :: 4096

Blur_Refusal :: enum u8 {
	None             = 0,
	Invalid_Bounds   = 1,
	Radius_Too_Large = 2,
	Scratch_Too_Small = 3,
}

// blur_rgba_separable applies passes iterations (typically 1..3; 3 approximates
// a Gaussian kernel closely) of horizontal + vertical sliding-window box blur
// of radius r over pixels (width * height * 4 RGBA bytes) using scratch (>= len(pixels)).
blur_rgba_separable :: proc "contextless" (
	pixels: []u8,
	scratch: []u8,
	width, height: int,
	radius: int,
	passes: int = 1,
) -> Blur_Refusal {
	if width <= 0 || height <= 0 || width > MAX_SURFACE_DIM || height > MAX_SURFACE_DIM || passes <= 0 {
		return .Invalid_Bounds
	}
	if radius < 0 || radius > MAX_BLUR_RADIUS {
		return .Radius_Too_Large
	}
	expected := width * height * 4
	if len(pixels) != expected {
		return .Invalid_Bounds
	}
	if len(scratch) < expected {
		return .Scratch_Too_Small
	}
	if radius == 0 {
		return .None
	}

	window := u32(2 * radius + 1)
	for _ in 0 ..< passes {
		// Horizontal pass: pixels -> scratch
		for y in 0 ..< height {
			row_off := y * width * 4
			sum: [4]u32
			for k := -radius; k <= radius; k += 1 {
				sx := clamp(k, 0, width - 1)
				off := row_off + sx * 4
				for c in 0 ..< 4 {
					sum[c] += u32(pixels[off + c])
				}
			}
			for x in 0 ..< width {
				dst := row_off + x * 4
				for c in 0 ..< 4 {
					scratch[dst + c] = u8((sum[c] + window / 2) / window)
				}
				rem_x := clamp(x - radius, 0, width - 1)
				add_x := clamp(x + radius + 1, 0, width - 1)
				rem_off := row_off + rem_x * 4
				add_off := row_off + add_x * 4
				for c in 0 ..< 4 {
					sum[c] = sum[c] - u32(pixels[rem_off + c]) + u32(pixels[add_off + c])
				}
			}
		}

		// Vertical pass: scratch -> pixels
		for x in 0 ..< width {
			sum: [4]u32
			for k := -radius; k <= radius; k += 1 {
				sy := clamp(k, 0, height - 1)
				off := (sy * width + x) * 4
				for c in 0 ..< 4 {
					sum[c] += u32(scratch[off + c])
				}
			}
			for y in 0 ..< height {
				dst := (y * width + x) * 4
				for c in 0 ..< 4 {
					pixels[dst + c] = u8((sum[c] + window / 2) / window)
				}
				rem_y := clamp(y - radius, 0, height - 1)
				add_y := clamp(y + radius + 1, 0, height - 1)
				rem_off := (rem_y * width + x) * 4
				add_off := (add_y * width + x) * 4
				for c in 0 ..< 4 {
					sum[c] = sum[c] - u32(scratch[rem_off + c]) + u32(scratch[add_off + c])
				}
			}
		}
	}
	return .None
}
