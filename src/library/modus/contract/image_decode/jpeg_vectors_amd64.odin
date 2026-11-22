#+build amd64
package image_decode

import "base:intrinsics"

// SSE2 vector forms of the baseline JPEG 8x8 integer 2D IDCT and YCbCr to
// RGBA row conversion (docs/SIMD.md). Both match their scalar references bit
// for bit for every possible input.

@(private)
Four_I32 :: #simd[4]i32

@(private)
Eight_I32 :: #simd[8]i32

@(private)
Eight_U32 :: #simd[8]u32

@(private)
Eight_U8 :: #simd[8]u8

// transpose_4x4_i32 transposes four #simd[4]i32 rows in place using SSE2 shuffles.
@(private)
transpose_4x4_i32 :: #force_inline proc "contextless" (r0, r1, r2, r3: Four_I32) -> (c0, c1, c2, c3: Four_I32) {
	t0 := intrinsics.simd_shuffle(r0, r1, 0, 4, 1, 5)
	t1 := intrinsics.simd_shuffle(r2, r3, 0, 4, 1, 5)
	t2 := intrinsics.simd_shuffle(r0, r1, 2, 6, 3, 7)
	t3 := intrinsics.simd_shuffle(r2, r3, 2, 6, 3, 7)
	c0 = intrinsics.simd_shuffle(t0, t1, 0, 1, 4, 5)
	c1 = intrinsics.simd_shuffle(t0, t1, 2, 3, 6, 7)
	c2 = intrinsics.simd_shuffle(t2, t3, 0, 1, 4, 5)
	c3 = intrinsics.simd_shuffle(t2, t3, 2, 3, 6, 7)
	return
}

// transpose_8x8_i32 transposes an 8x8 matrix of i32 stored as 8 #simd[8]i32 rows.
@(private)
transpose_8x8_i32 :: #force_inline proc "contextless" (rows: ^[8]Eight_I32) #no_bounds_check {
	split_lo :: #force_inline proc "contextless" (v: Eight_I32) -> Four_I32 {
		return intrinsics.simd_shuffle(v, v, 0, 1, 2, 3)
	}
	split_hi :: #force_inline proc "contextless" (v: Eight_I32) -> Four_I32 {
		return intrinsics.simd_shuffle(v, v, 4, 5, 6, 7)
	}
	join :: #force_inline proc "contextless" (lo, hi: Four_I32) -> Eight_I32 {
		return intrinsics.simd_shuffle(lo, hi, 0, 1, 2, 3, 4, 5, 6, 7)
	}

	// Top-left 4x4 -> top-left 4x4
	tl0, tl1, tl2, tl3 := transpose_4x4_i32(split_lo(rows[0]), split_lo(rows[1]), split_lo(rows[2]), split_lo(rows[3]))
	// Top-right 4x4 -> bottom-left 4x4
	tr0, tr1, tr2, tr3 := transpose_4x4_i32(split_hi(rows[0]), split_hi(rows[1]), split_hi(rows[2]), split_hi(rows[3]))
	// Bottom-left 4x4 -> top-right 4x4
	bl0, bl1, bl2, bl3 := transpose_4x4_i32(split_lo(rows[4]), split_lo(rows[5]), split_lo(rows[6]), split_lo(rows[7]))
	// Bottom-right 4x4 -> bottom-right 4x4
	br0, br1, br2, br3 := transpose_4x4_i32(split_hi(rows[4]), split_hi(rows[5]), split_hi(rows[6]), split_hi(rows[7]))

	rows[0] = join(tl0, bl0)
	rows[1] = join(tl1, bl1)
	rows[2] = join(tl2, bl2)
	rows[3] = join(tl3, bl3)
	rows[4] = join(tr0, br0)
	rows[5] = join(tr1, br1)
	rows[6] = join(tr2, br2)
	rows[7] = join(tr3, br3)
}

// idct_1d_8lanes runs the exact Loeffler/IJG 1D IDCT butterfly on 8 independent
// 8-point transforms simultaneously in #simd[8]i32 lanes.
@(private)
idct_1d_8lanes :: #force_inline proc "contextless" (
	s0, s1, s2, s3, s4, s5, s6, s7: Eight_I32,
	bias: Eight_I32,
	shift: Eight_U32,
	min_val, max_val: Eight_I32,
) -> (r0, r1, r2, r3, r4, r5, r6, r7: Eight_I32) {
	p1 := (s2 + s6) * Eight_I32(IDCT_F_0_541196100)
	t2 := p1 + s6 * Eight_I32(IDCT_F_M1_847759065)
	t3 := p1 + s2 * Eight_I32(IDCT_F_0_765366865)
	t0 := intrinsics.simd_shl(s0 + s4, Eight_U32(12))
	t1 := intrinsics.simd_shl(s0 - s4, Eight_U32(12))
	x0 := t0 + t3
	x3 := t0 - t3
	x1 := t1 + t2
	x2 := t1 - t2

	o0 := s7
	o1 := s5
	o2 := s3
	o3 := s1
	p3 := o0 + o2
	p4 := o1 + o3
	q1 := o0 + o3
	q2 := o1 + o2
	p5 := (p3 + p4) * Eight_I32(IDCT_F_1_175875602)
	o0 = o0 * Eight_I32(IDCT_F_0_298631336)
	o1 = o1 * Eight_I32(IDCT_F_2_053119869)
	o2 = o2 * Eight_I32(IDCT_F_3_072711026)
	o3 = o3 * Eight_I32(IDCT_F_1_501321110)
	q1 = p5 + q1 * Eight_I32(IDCT_F_M0_899976223)
	q2 = p5 + q2 * Eight_I32(IDCT_F_M2_562915447)
	p3 = p3 * Eight_I32(IDCT_F_M1_961570560)
	p4 = p4 * Eight_I32(IDCT_F_M0_390180644)
	o3 += q1 + p4
	o2 += q2 + p3
	o1 += q2 + p4
	o0 += q1 + p3

	r0 = intrinsics.simd_clamp(intrinsics.simd_shr(x0 + o3 + bias, shift), min_val, max_val)
	r7 = intrinsics.simd_clamp(intrinsics.simd_shr(x0 - o3 + bias, shift), min_val, max_val)
	r1 = intrinsics.simd_clamp(intrinsics.simd_shr(x1 + o2 + bias, shift), min_val, max_val)
	r6 = intrinsics.simd_clamp(intrinsics.simd_shr(x1 - o2 + bias, shift), min_val, max_val)
	r2 = intrinsics.simd_clamp(intrinsics.simd_shr(x2 + o1 + bias, shift), min_val, max_val)
	r5 = intrinsics.simd_clamp(intrinsics.simd_shr(x2 - o1 + bias, shift), min_val, max_val)
	r3 = intrinsics.simd_clamp(intrinsics.simd_shr(x3 + o0 + bias, shift), min_val, max_val)
	r4 = intrinsics.simd_clamp(intrinsics.simd_shr(x3 - o0 + bias, shift), min_val, max_val)
	return
}

// jpeg_idct_8x8_simd is the SSE2 form of jpeg_idct_8x8_scalar: transposes the
// 8x8 block to run all 8 rows in parallel in #simd[8]i32, transposes back,
// and runs all 8 columns in parallel, giving the exact bytes of scalar.
jpeg_idct_8x8_simd :: proc "contextless" (coeffs: ^[64]i32, out_pixels: ^[64]u8) #no_bounds_check {
	rows: [8]Eight_I32 = ---
	in_min := Eight_I32(-IDCT_INPUT_LIMIT)
	in_max := Eight_I32(IDCT_INPUT_LIMIT - 1)
	for r in 0 ..< 8 {
		v := intrinsics.unaligned_load((^Eight_I32)(&coeffs[r * 8]))
		rows[r] = intrinsics.simd_clamp(v, in_min, in_max)
	}

	// Transpose so rows[k] holds element k of all 8 input rows.
	transpose_8x8_i32(&rows)

	// Row pass across all 8 rows simultaneously.
	rows[0], rows[1], rows[2], rows[3], rows[4], rows[5], rows[6], rows[7] = idct_1d_8lanes(
		rows[0], rows[1], rows[2], rows[3], rows[4], rows[5], rows[6], rows[7],
		Eight_I32(512),
		Eight_U32(10),
		Eight_I32(-IDCT_ROW_OUT_LIMIT - 1),
		Eight_I32(IDCT_ROW_OUT_LIMIT),
	)

	// Transpose back so rows[r] holds row r (column pass operates across rows[0..7]).
	transpose_8x8_i32(&rows)

	// Column pass across all 8 columns simultaneously.
	BIAS :: i32(65536 + (128 << 17))
	rows[0], rows[1], rows[2], rows[3], rows[4], rows[5], rows[6], rows[7] = idct_1d_8lanes(
		rows[0], rows[1], rows[2], rows[3], rows[4], rows[5], rows[6], rows[7],
		Eight_I32(BIAS),
		Eight_U32(17),
		Eight_I32(0),
		Eight_I32(255),
	)

	for r in 0 ..< 8 {
		packed := cast(Eight_U8)rows[r]
		intrinsics.unaligned_store((^Eight_U8)(&out_pixels[r * 8]), packed)
	}
}

// jpeg_ycbcr_to_rgba_row_simd is the SSE2 form of jpeg_ycbcr_to_rgba_row_scalar:
// converts 8 pixels per step in #simd[8]i32 and stores 32 RGBA bytes directly.
jpeg_ycbcr_to_rgba_row_simd :: proc "contextless" (y, cb, cr: [^]u8, out_rgba: [^]u8, count: int) #no_bounds_check {
	if count <= 0 {
		return
	}
	zero := Eight_I32(0)
	max255 := Eight_I32(255)
	c128 := Eight_I32(128)
	round_half := Eight_I32(2048)
	cr_r := Eight_I32(YCBCR_CR_TO_R)
	cb_g := Eight_I32(YCBCR_CB_TO_G)
	cr_g := Eight_I32(YCBCR_CR_TO_G)
	cb_b := Eight_I32(YCBCR_CB_TO_B)
	alpha_mask := Eight_U32(0xFF000000)

	i := 0
	for ; i + 8 <= count; i += 8 {
		yv := intrinsics.simd_shl(cast(Eight_I32)intrinsics.unaligned_load((^Eight_U8)(&y[i])), Eight_U32(12))
		cbv := cast(Eight_I32)intrinsics.unaligned_load((^Eight_U8)(&cb[i])) - c128
		crv := cast(Eight_I32)intrinsics.unaligned_load((^Eight_U8)(&cr[i])) - c128

		r := transmute(Eight_U32)intrinsics.simd_clamp(intrinsics.simd_shr(yv + crv * cr_r + round_half, Eight_U32(12)), zero, max255)
		g := transmute(Eight_U32)intrinsics.simd_clamp(intrinsics.simd_shr(yv + cbv * cb_g + crv * cr_g + round_half, Eight_U32(12)), zero, max255)
		b := transmute(Eight_U32)intrinsics.simd_clamp(intrinsics.simd_shr(yv + cbv * cb_b + round_half, Eight_U32(12)), zero, max255)

		// Little-endian u32 word 0xFFBBGGRR stores bytes [R, G, B, 255].
		rgba := intrinsics.simd_bit_or(
			intrinsics.simd_bit_or(r, intrinsics.simd_shl(g, Eight_U32(8))),
			intrinsics.simd_bit_or(intrinsics.simd_shl(b, Eight_U32(16)), alpha_mask),
		)
		intrinsics.unaligned_store((^Eight_U32)(&out_rgba[i * 4]), rgba)
	}
	if i < count {
		jpeg_ycbcr_to_rgba_row_scalar(y[i:], cb[i:], cr[i:], out_rgba[i * 4:], count - i)
	}
}
