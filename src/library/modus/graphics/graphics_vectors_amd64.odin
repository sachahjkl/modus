#+build amd64
package graphics

import "base:intrinsics"

// SSE2 vector forms of the solid translucent span blend, horizontal gradient,
// level color mix, and path coverage scanline accumulation & compositing
// (docs/SIMD.md). Every procedure matches its scalar reference bit for bit
// across all widths, alignments, and edge values, with a scalar tail for the
// final 0..3 pixels so no load or store crosses the end of a span.

@(private)
Four_Signed :: #simd[4]i32

// Fixed-point bound inside which 32-bit signed lanes match 64-bit stepping
// without overflow even after adding 4 * step (|step| <= 255 * 65536 < 2^24).
@(private)
GRADIENT_SIMD_SAFE_BOUND :: i64(1) << 29

// blend_span_simd is the SSE2 form of blend_span_scalar: 4 pixels at a time
// with the source color terms and inverse alpha hoisted out of the row loop.
blend_span_simd :: proc "contextless" (to: [^]Color, count: int, color: u32, square_root: ^[4096]u8) #no_bounds_check {
	if count <= 0 {
		return
	}
	alpha := color >> 24
	if alpha == 0 {
		return
	}
	channels := color & 0x00FFFFFF
	if alpha == 255 {
		solid := Four_Pixels{channels, channels, channels, channels}
		column := 0
		for ; column + 4 <= count; column += 4 {
			intrinsics.unaligned_store((^Four_Pixels)(&to[column]), solid)
		}
		for ; column < count; column += 1 {
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
	// Pixel memory layout is little-endian 0x00RRGGBB: byte 0 = blue,
	// byte 1 = green, byte 2 = red, byte 3 = 0.
	color_terms := Sixteen_Wide_Channels{
		blue_term, green_term, red_term, 0,
		blue_term, green_term, red_term, 0,
		blue_term, green_term, red_term, 0,
		blue_term, green_term, red_term, 0,
	}
	inverse_vec := Sixteen_Wide_Channels(inverse)
	column := 0
	for ; column + 4 <= count; column += 4 {
		address := (^Four_Pixels)(&to[column])
		under_pixels := intrinsics.unaligned_load(address)
		under := channels_of_four_pixels(under_pixels)
		under_squares := cast(Sixteen_Wide_Channels)(under * under)
		indices := intrinsics.simd_shr(under_squares * inverse_vec + color_terms, Sixteen_Wide_Channels(12))
		// square_roots_one_at_a_time writes 0 into lanes 3, 7, 11, 15, so the
		// high byte of each blended pixel is already 0.
		from_table := square_roots_one_at_a_time(indices, square_root)
		intrinsics.unaligned_store(address, four_pixels_of_channels(from_table))
	}
	if column < count {
		blend_span_scalar(to[column:], count - column, color, square_root)
	}
}

// gradient_channel_fits_i32 reports whether a fixed-point channel starting at
// value_start and ending at value_end stays inside GRADIENT_SIMD_SAFE_BOUND.
@(private)
gradient_channel_fits_i32 :: #force_inline proc "contextless" (value_start, value_end: i64) -> bool {
	return value_start >= -GRADIENT_SIMD_SAFE_BOUND && value_start <= GRADIENT_SIMD_SAFE_BOUND &&
		value_end >= -GRADIENT_SIMD_SAFE_BOUND && value_end <= GRADIENT_SIMD_SAFE_BOUND
}

// horizontal_gradient_span_simd is the SSE2 form of
// horizontal_gradient_span_scalar: steps 4 pixels per iteration in #simd[4]i32.
horizontal_gradient_span_simd :: proc "contextless" (row: []Color, start, end: Color, total, first: int) #no_bounds_check {
	count := len(row)
	if count == 0 {
		return
	}
	if count < 4 {
		horizontal_gradient_span_scalar(row, start, end, total, first)
		return
	}
	steps := i64(max(total - 1, 1))
	value, step: [3]i64
	for channel in 0 ..< 3 {
		shift := uint(16 - 8 * channel)
		from, to := i64(start >> shift & 0xFF), i64(end >> shift & 0xFF)
		step[channel] = (to - from) * 65536 / steps
		value[channel] = from * 65536 + step[channel] * i64(first) + 32768
		last_value := value[channel] + step[channel] * i64(count - 1)
		if !gradient_channel_fits_i32(value[channel], last_value) {
			horizontal_gradient_span_scalar(row, start, end, total, first)
			return
		}
	}
	r0, sr := i32(value[0]), i32(step[0])
	g0, sg := i32(value[1]), i32(step[1])
	b0, sb := i32(value[2]), i32(step[2])
	r := Four_Signed{r0, r0 + sr, r0 + 2 * sr, r0 + 3 * sr}
	g := Four_Signed{g0, g0 + sg, g0 + 2 * sg, g0 + 3 * sg}
	b := Four_Signed{b0, b0 + sb, b0 + 2 * sb, b0 + 3 * sb}
	step_r := Four_Signed(4 * sr)
	step_g := Four_Signed(4 * sg)
	step_b := Four_Signed(4 * sb)
	pixels_ptr := raw_data(row)
	column := 0
	for ; column + 4 <= count; column += 4 {
		ru := transmute(Four_Pixels)intrinsics.simd_shr(r, Four_Pixels(16))
		gu := transmute(Four_Pixels)intrinsics.simd_shr(g, Four_Pixels(16))
		bu := transmute(Four_Pixels)intrinsics.simd_shr(b, Four_Pixels(16))
		packed := intrinsics.simd_bit_or(
			intrinsics.simd_bit_or(
				intrinsics.simd_shl(ru, Four_Pixels(16)),
				intrinsics.simd_shl(gu, Four_Pixels(8)),
			),
			bu,
		)
		intrinsics.unaligned_store((^Four_Pixels)(&pixels_ptr[column]), packed)
		r += step_r
		g += step_g
		b += step_b
	}
	if column < count {
		horizontal_gradient_span_scalar(row[column:], start, end, total, first + column)
	}
}

// horizontal_gradient_with_alpha_span_simd is the SSE2 form of
// horizontal_gradient_with_alpha_span_scalar: computes all 4 channels in one
// pass, 4 pixels per iteration.
horizontal_gradient_with_alpha_span_simd :: proc "contextless" (row: []u32, start, end: u32, total, first: int) #no_bounds_check {
	count := len(row)
	if count == 0 {
		return
	}
	if count < 4 {
		horizontal_gradient_with_alpha_span_scalar(row, start, end, total, first)
		return
	}
	steps := i64(max(total - 1, 1))
	value, step: [4]i64
	for channel in 0 ..< 4 {
		shift := uint(24 - 8 * channel)
		from, to := i64(start >> shift & 0xFF), i64(end >> shift & 0xFF)
		step[channel] = (to - from) * 65536 / steps
		value[channel] = from * 65536 + step[channel] * i64(first) + 32768
		last_value := value[channel] + step[channel] * i64(count - 1)
		if !gradient_channel_fits_i32(value[channel], last_value) {
			horizontal_gradient_with_alpha_span_scalar(row, start, end, total, first)
			return
		}
	}
	a0, sa := i32(value[0]), i32(step[0])
	r0, sr := i32(value[1]), i32(step[1])
	g0, sg := i32(value[2]), i32(step[2])
	b0, sb := i32(value[3]), i32(step[3])
	a := Four_Signed{a0, a0 + sa, a0 + 2 * sa, a0 + 3 * sa}
	r := Four_Signed{r0, r0 + sr, r0 + 2 * sr, r0 + 3 * sr}
	g := Four_Signed{g0, g0 + sg, g0 + 2 * sg, g0 + 3 * sg}
	b := Four_Signed{b0, b0 + sb, b0 + 2 * sb, b0 + 3 * sb}
	step_a := Four_Signed(4 * sa)
	step_r := Four_Signed(4 * sr)
	step_g := Four_Signed(4 * sg)
	step_b := Four_Signed(4 * sb)
	pixels_ptr := raw_data(row)
	column := 0
	for ; column + 4 <= count; column += 4 {
		au := transmute(Four_Pixels)intrinsics.simd_shr(a, Four_Pixels(16))
		ru := transmute(Four_Pixels)intrinsics.simd_shr(r, Four_Pixels(16))
		gu := transmute(Four_Pixels)intrinsics.simd_shr(g, Four_Pixels(16))
		bu := transmute(Four_Pixels)intrinsics.simd_shr(b, Four_Pixels(16))
		packed := intrinsics.simd_bit_or(
			intrinsics.simd_bit_or(
				intrinsics.simd_shl(au, Four_Pixels(24)),
				intrinsics.simd_shl(ru, Four_Pixels(16)),
			),
			intrinsics.simd_bit_or(
				intrinsics.simd_shl(gu, Four_Pixels(8)),
				bu,
			),
		)
		intrinsics.unaligned_store((^Four_Pixels)(&pixels_ptr[column]), packed)
		a += step_a
		r += step_r
		g += step_g
		b += step_b
	}
	if column < count {
		horizontal_gradient_with_alpha_span_scalar(row[column:], start, end, total, first + column)
	}
}

// mix_with_alpha_span_simd is the SSE2 form of mix_with_alpha_span_scalar:
// computes floor((a * (255 - level) + b * level) / 255) for 4 pixels (16
// channels) at once using the exact 16-bit division identity
// floor(n / 255) == ((n + 1) + ((n + 1) >> 8)) >> 8 for 0 <= n <= 65025.
mix_with_alpha_span_simd :: proc "contextless" (row: []u32, start, end: u32, levels: []u8) #no_bounds_check {
	count := min(len(row), len(levels))
	if count <= 0 {
		return
	}
	start_channels := channels_of_four_pixels(Four_Pixels{start, start, start, start})
	end_channels := channels_of_four_pixels(Four_Pixels{end, end, end, end})
	row_ptr := raw_data(row)
	levels_ptr := raw_data(levels)
	index := 0
	for ; index + 4 <= count; index += 4 {
		l0 := u16(levels_ptr[index])
		l1 := u16(levels_ptr[index + 1])
		l2 := u16(levels_ptr[index + 2])
		l3 := u16(levels_ptr[index + 3])
		lvl := Sixteen_Channels{l0, l0, l0, l0, l1, l1, l1, l1, l2, l2, l2, l2, l3, l3, l3, l3}
		inv := Sixteen_Channels(255) - lvl
		num := start_channels * inv + end_channels * lvl
		t := num + Sixteen_Channels(1)
		quot := intrinsics.simd_shr(t + intrinsics.simd_shr(t, Sixteen_Channels(8)), Sixteen_Channels(8))
		intrinsics.unaligned_store((^Four_Pixels)(&row_ptr[index]), four_pixels_of_channels(quot))
	}
	if index < count {
		mix_with_alpha_span_scalar(row[index:count], start, end, levels[index:count])
	}
}

// path_coverage_span_simd is the SSE2 form of path_coverage_span_scalar:
// performs an in-register 4-lane prefix sum of signed area deltas, exact
// absolute value (including min(i32)), clamp to PATH_COVERAGE_FULL_PIXEL,
// alpha scaling, and linear-light compositing directly onto to[0 ..< count].
path_coverage_span_simd :: proc "contextless" (to: [^]Color, cells: [^]i32, count: int, color: u32, square_root: ^[4096]u8, initial_sum: i32 = 0) -> i32 #no_bounds_check {
	sum := initial_sum
	if count <= 0 {
		return sum
	}
	alpha := color >> 24
	if alpha == 0 {
		acc := Four_Signed(0)
		column := 0
		for ; column + 4 <= count; column += 4 {
			acc += intrinsics.unaligned_load((^Four_Signed)(&cells[column]))
		}
		sum += intrinsics.simd_extract(acc, 0) + intrinsics.simd_extract(acc, 1) + intrinsics.simd_extract(acc, 2) + intrinsics.simd_extract(acc, 3)
		for ; column < count; column += 1 {
			sum += cells[column]
		}
		return sum
	}
	channels := color & 0x00FFFFFF
	solid_pixels := Four_Pixels{channels, channels, channels, channels}
	color_channels := intrinsics.simd_bit_and(channels_of_four_pixels(solid_pixels), COLOR_LANES_OF_FOUR_PIXELS)
	color_squares := color_channels * color_channels
	alpha_vec := Four_Pixels{alpha, alpha, alpha, alpha}
	full_pixel_vec := Four_Pixels(PATH_COVERAGE_FULL_PIXEL)
	half_pixel_vec := Four_Pixels(PATH_COVERAGE_FULL_PIXEL / 2)
	carry := Four_Signed{sum, sum, sum, sum}
	zero_signed := Four_Signed(0)

	color_red := color >> 16 & 0xFF
	color_green := color >> 8 & 0xFF
	color_blue := color & 0xFF
	red_sq := color_red * color_red
	green_sq := color_green * color_green
	blue_sq := color_blue * color_blue

	column := 0
	for ; column + 4 <= count; column += 4 {
		deltas := intrinsics.unaligned_load((^Four_Signed)(&cells[column]))
		// Fast path for flat exterior and interior spans where all 4 deltas are 0:
		// all 4 pixels share the current running sum and need no prefix sum or per-lane masks.
		if intrinsics.simd_reduce_or(transmute(Four_Pixels)deltas) == 0 {
			if sum == 0 {
				continue
			}
			abs_sum := sum < 0 ? u32(-i64(sum)) : u32(sum)
			covered_scalar := min(abs_sum, PATH_COVERAGE_FULL_PIXEL)
			part_scalar := (alpha * covered_scalar + PATH_COVERAGE_FULL_PIXEL / 2) >> PATH_COVERAGE_FULL_SHIFT
			if part_scalar == 0 {
				continue
			}
			address := (^Four_Pixels)(&to[column])
			if part_scalar == 255 {
				intrinsics.unaligned_store(address, solid_pixels)
				continue
			}
			inv_vec := Sixteen_Wide_Channels(255 - part_scalar)
			r_term := red_sq * part_scalar
			g_term := green_sq * part_scalar
			b_term := blue_sq * part_scalar
			c_terms := Sixteen_Wide_Channels{
				b_term, g_term, r_term, 0,
				b_term, g_term, r_term, 0,
				b_term, g_term, r_term, 0,
				b_term, g_term, r_term, 0,
			}
			under_pixels := intrinsics.unaligned_load(address)
			under := channels_of_four_pixels(under_pixels)
			under_sq := cast(Sixteen_Wide_Channels)(under * under)
			indices := intrinsics.simd_shr(under_sq * inv_vec + c_terms, Sixteen_Wide_Channels(12))
			intrinsics.unaligned_store(address, four_pixels_of_channels(square_roots_one_at_a_time(indices, square_root)))
			continue
		}

		// Two-stage Hillis-Steele prefix sum across the 4 lanes.
		stage1 := deltas + intrinsics.simd_shuffle(zero_signed, deltas, 0, 4, 5, 6)
		stage2 := stage1 + intrinsics.simd_shuffle(zero_signed, stage1, 0, 1, 4, 5)
		sums := stage2 + carry
		carry = intrinsics.simd_shuffle(sums, sums, 3, 3, 3, 3)
		sum = intrinsics.simd_extract(carry, 0)

		// Unsigned absolute value in SSE2: works for every i32 including min(i32).
		sign_mask := intrinsics.simd_shr(sums, Four_Pixels(31))
		abs_u32 := transmute(Four_Pixels)(intrinsics.simd_bit_xor(sums, sign_mask)) - transmute(Four_Pixels)sign_mask
		covered := intrinsics.simd_min(abs_u32, full_pixel_vec)
		parts := intrinsics.simd_shr(covered * alpha_vec + half_pixel_vec, Four_Pixels(PATH_COVERAGE_FULL_SHIFT))

		if intrinsics.simd_reduce_or(parts) == 0 {
			continue
		}
		address := (^Four_Pixels)(&to[column])
		if intrinsics.simd_reduce_and(parts) == 255 {
			intrinsics.unaligned_store(address, solid_pixels)
			continue
		}

		// Each lane of parts holds a value in 0..255 in its low byte (bytes 0, 4, 8, 12).
		part_lanes := channels_of_four_pixels(parts)
		part_channels := intrinsics.simd_shuffle(part_lanes, part_lanes, 0, 0, 0, 0, 4, 4, 4, 4, 8, 8, 8, 8, 12, 12, 12, 12)
		under_pixels := intrinsics.unaligned_load(address)
		under := channels_of_four_pixels(under_pixels)
		from_table := square_roots_one_at_a_time(square_root_indices(under, part_channels, color_squares), square_root)
		blended := four_pixels_of_channels(from_table)
		is_zero := intrinsics.simd_lanes_eq(parts, Four_Pixels(0))
		is_opaque := intrinsics.simd_lanes_eq(parts, Four_Pixels(255))
		intrinsics.unaligned_store(address, intrinsics.simd_select(is_zero, under_pixels, intrinsics.simd_select(is_opaque, solid_pixels, blended)))
	}
	if column < count {
		sum = path_coverage_span_scalar(to[column:], cells[column:], count - column, color, square_root, sum)
	}
	return sum
}
