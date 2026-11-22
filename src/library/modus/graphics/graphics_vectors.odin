package graphics

// Vector forms and scalar references for the hot drawing spans of the
// compositor and the draw table (docs/SIMD.md):
//
// - blend_span: blends one translucent straight-alpha color over a row of
//   canvas pixels in linear light, with all color terms precomputed once.
// - horizontal_gradient_span / horizontal_gradient_with_alpha_span: steps
//   a horizontal color gradient across a row in fixed point.
// - mix_with_alpha_span: mixes two straight-alpha colors from a row of
//   gradient levels (0..255) without per-pixel integer division.
// - path_coverage_span: computes the prefix sum of signed path area cells,
//   clamps to full pixel coverage, scales by alpha, and composites directly
//   onto the destination row in one pass.
//
// Each public procedure selects the SSE2 form on amd64 and the scalar form
// on other targets. Both forms produce the exact same bytes for every input.

// Area value of a fully covered path pixel: height 64 * twice width 64.
PATH_COVERAGE_FULL_PIXEL :: 8192
PATH_COVERAGE_FULL_SHIFT :: 13

#assert(PATH_COVERAGE_FULL_PIXEL == 1 << PATH_COVERAGE_FULL_SHIFT)

// blend_span blends one straight-alpha color (0xAARRGGBB) over count pixels
// starting at to, in linear light with a gamma of 2. Alpha 0 leaves every
// pixel untouched; alpha 255 writes color & 0x00FFFFFF to every pixel.
blend_span :: #force_inline proc "contextless" (to: [^]Color, count: int, color: u32, square_root: ^[4096]u8) {
	when ODIN_ARCH == .amd64 {
		blend_span_simd(to, count, color, square_root)
	} else {
		blend_span_scalar(to, count, color, square_root)
	}
}

// blend_span_scalar is the scalar reference form of blend_span.
blend_span_scalar :: proc "contextless" (to: [^]Color, count: int, color: u32, square_root: ^[4096]u8) #no_bounds_check {
	if count <= 0 {
		return
	}
	alpha := color >> 24
	if alpha == 0 {
		return
	}
	channels := color & 0x00FFFFFF
	if alpha == 255 {
		for column in 0 ..< count {
			to[column] = channels
		}
		return
	}
	inverse := 255 - alpha
	color_red := color >> 16 & 0xFF
	color_green := color >> 8 & 0xFF
	color_blue := color & 0xFF
	red_term := color_red * color_red * alpha
	green_term := color_green * color_green * alpha
	blue_term := color_blue * color_blue * alpha
	for column in 0 ..< count {
		under := to[column]
		under_red := under >> 16 & 0xFF
		under_green := under >> 8 & 0xFF
		under_blue := under & 0xFF
		red := u32(square_root[(under_red * under_red * inverse + red_term) >> 12])
		green := u32(square_root[(under_green * under_green * inverse + green_term) >> 12])
		blue := u32(square_root[(under_blue * under_blue * inverse + blue_term) >> 12])
		to[column] = red << 16 | green << 8 | blue
	}
}

// horizontal_gradient_span fills row with the colors of columns
// first ..< first + len(row) of a horizontal line of total columns from
// start (column 0) to end (column total - 1).
horizontal_gradient_span :: #force_inline proc "contextless" (row: []Color, start, end: Color, total, first: int) {
	when ODIN_ARCH == .amd64 {
		horizontal_gradient_span_simd(row, start, end, total, first)
	} else {
		horizontal_gradient_span_scalar(row, start, end, total, first)
	}
}

// horizontal_gradient_span_scalar is the scalar reference form of
// horizontal_gradient_span.
horizontal_gradient_span_scalar :: proc "contextless" (row: []Color, start, end: Color, total, first: int) #no_bounds_check {
	if len(row) == 0 {
		return
	}
	steps := i64(max(total - 1, 1))
	value, step: [3]i64
	for channel in 0 ..< 3 {
		shift := uint(16 - 8 * channel)
		from, to := i64(start >> shift & 0xFF), i64(end >> shift & 0xFF)
		step[channel] = (to - from) * 65536 / steps
		value[channel] = from * 65536 + step[channel] * i64(first) + 32768
	}
	for &color in row {
		color = rgb(u32(value[0] >> 16), u32(value[1] >> 16), u32(value[2] >> 16))
		value += step
	}
}

// horizontal_gradient_with_alpha_span fills row with straight-alpha colors
// (0xAARRGGBB) stepping alpha, red, green, and blue across a horizontal line.
horizontal_gradient_with_alpha_span :: #force_inline proc "contextless" (row: []u32, start, end: u32, total, first: int) {
	when ODIN_ARCH == .amd64 {
		horizontal_gradient_with_alpha_span_simd(row, start, end, total, first)
	} else {
		horizontal_gradient_with_alpha_span_scalar(row, start, end, total, first)
	}
}

// horizontal_gradient_with_alpha_span_scalar is the scalar reference form of
// horizontal_gradient_with_alpha_span.
horizontal_gradient_with_alpha_span_scalar :: proc "contextless" (row: []u32, start, end: u32, total, first: int) #no_bounds_check {
	if len(row) == 0 {
		return
	}
	steps := i64(max(total - 1, 1))
	value, step: [4]i64
	for channel in 0 ..< 4 {
		shift := uint(24 - 8 * channel)
		from, to := i64(start >> shift & 0xFF), i64(end >> shift & 0xFF)
		step[channel] = (to - from) * 65536 / steps
		value[channel] = from * 65536 + step[channel] * i64(first) + 32768
	}
	for &color in row {
		color = u32(value[0] >> 16) << 24 | rgb(u32(value[1] >> 16), u32(value[2] >> 16), u32(value[3] >> 16))
		value += step
	}
}

// mix_with_alpha_span writes mix_with_alpha(start, end, u32(levels[i])) into
// row[i] for each pixel in min(len(row), len(levels)).
mix_with_alpha_span :: #force_inline proc "contextless" (row: []u32, start, end: u32, levels: []u8) {
	when ODIN_ARCH == .amd64 {
		mix_with_alpha_span_simd(row, start, end, levels)
	} else {
		mix_with_alpha_span_scalar(row, start, end, levels)
	}
}

// mix_with_alpha_span_scalar is the scalar reference form of
// mix_with_alpha_span.
mix_with_alpha_span_scalar :: proc "contextless" (row: []u32, start, end: u32, levels: []u8) #no_bounds_check {
	count := min(len(row), len(levels))
	for index in 0 ..< count {
		row[index] = mix_with_alpha(start, end, u32(levels[index]))
	}
}

// path_coverage_span accumulates the signed area deltas in cells[0 ..< count]
// starting from initial_sum, clamps each pixel's coverage magnitude to
// PATH_COVERAGE_FULL_PIXEL, scales by the straight alpha of color, and blends
// onto to[0 ..< count] in linear light. Returns the final running sum.
path_coverage_span :: #force_inline proc "contextless" (to: [^]Color, cells: [^]i32, count: int, color: u32, square_root: ^[4096]u8, initial_sum: i32 = 0) -> i32 {
	when ODIN_ARCH == .amd64 {
		return path_coverage_span_simd(to, cells, count, color, square_root, initial_sum)
	} else {
		return path_coverage_span_scalar(to, cells, count, color, square_root, initial_sum)
	}
}

// path_coverage_span_scalar is the scalar reference form of
// path_coverage_span.
path_coverage_span_scalar :: proc "contextless" (to: [^]Color, cells: [^]i32, count: int, color: u32, square_root: ^[4096]u8, initial_sum: i32 = 0) -> i32 #no_bounds_check {
	sum := initial_sum
	if count <= 0 {
		return sum
	}
	alpha := color >> 24
	if alpha == 0 {
		for column in 0 ..< count {
			sum += cells[column]
		}
		return sum
	}
	channels := color & 0x00FFFFFF
	color_red := color >> 16 & 0xFF
	color_green := color >> 8 & 0xFF
	color_blue := color & 0xFF
	red_square := color_red * color_red
	green_square := color_green * color_green
	blue_square := color_blue * color_blue
	for column in 0 ..< count {
		sum += cells[column]
		abs_sum := sum < 0 ? u32(-i64(sum)) : u32(sum)
		covered := min(abs_sum, PATH_COVERAGE_FULL_PIXEL)
		part := (alpha * covered + PATH_COVERAGE_FULL_PIXEL / 2) >> PATH_COVERAGE_FULL_SHIFT
		if part == 0 {
			continue
		}
		if part == 255 {
			to[column] = channels
			continue
		}
		under := to[column]
		under_red := under >> 16 & 0xFF
		under_green := under >> 8 & 0xFF
		under_blue := under & 0xFF
		inverse := 255 - part
		red := u32(square_root[(under_red * under_red * inverse + red_square * part) >> 12])
		green := u32(square_root[(under_green * under_green * inverse + green_square * part) >> 12])
		blue := u32(square_root[(under_blue * under_blue * inverse + blue_square * part) >> 12])
		to[column] = red << 16 | green << 8 | blue
	}
	return sum
}
