#+build amd64
package image_decode

import "base:intrinsics"

// SSE2 vector forms of PNG scanline unfiltering (docs/SIMD.md):
// - Up: 16 bytes at a time via #simd[16]u8 addition (paddb).
// - Sub: 16-byte (or 12-byte for RGB) in-register byte-lane prefix sum in
//   #simd[16]u8 for bpp 1, 2, 3, and 4.
// - Average: pixel-parallel #simd[4]u16 exact floor average (a + b) >> 1
//   for bpp 3 and 4, and scalar for bpp 1 and 2.
// - Paeth: pixel-parallel #simd[4]i16 Paeth predictor for bpp 3 and 4.
//
// Every filter produces the exact same bytes as png_unfilter_row_scalar for
// every width, alignment, and byte value, with scalar tails preventing any
// out-of-bounds load or store.

@(private)
Sixteen_Bytes :: #simd[16]u8

@(private)
Four_U16 :: #simd[4]u16

@(private)
Four_I16 :: #simd[4]i16

@(private)
Four_U8 :: #simd[4]u8

// png_unfilter_row_simd is the SSE2 form of png_unfilter_row_scalar.
png_unfilter_row_simd :: proc "contextless" (filter: Png_Filter, dst: []u8, raw: []u8, prev: []u8, bytes_per_pixel: int) #no_bounds_check {
	n := len(raw)
	if n == 0 {
		return
	}
	dst_ptr := raw_data(dst)
	raw_ptr := raw_data(raw)
	prev_ptr := raw_data(prev)
	bpp := bytes_per_pixel

	switch filter {
	case .None:
		intrinsics.mem_copy_non_overlapping(dst_ptr, raw_ptr, n)

	case .Up:
		i := 0
		for ; i + 32 <= n; i += 32 {
			r0 := intrinsics.unaligned_load((^Sixteen_Bytes)(&raw_ptr[i]))
			p0 := intrinsics.unaligned_load((^Sixteen_Bytes)(&prev_ptr[i]))
			r1 := intrinsics.unaligned_load((^Sixteen_Bytes)(&raw_ptr[i + 16]))
			p1 := intrinsics.unaligned_load((^Sixteen_Bytes)(&prev_ptr[i + 16]))
			intrinsics.unaligned_store((^Sixteen_Bytes)(&dst_ptr[i]), r0 + p0)
			intrinsics.unaligned_store((^Sixteen_Bytes)(&dst_ptr[i + 16]), r1 + p1)
		}
		for ; i + 16 <= n; i += 16 {
			r := intrinsics.unaligned_load((^Sixteen_Bytes)(&raw_ptr[i]))
			p := intrinsics.unaligned_load((^Sixteen_Bytes)(&prev_ptr[i]))
			intrinsics.unaligned_store((^Sixteen_Bytes)(&dst_ptr[i]), r + p)
		}
		for ; i < n; i += 1 {
			dst_ptr[i] = raw_ptr[i] + prev_ptr[i]
		}

	case .Sub:
		zero := Sixteen_Bytes(0)
		carry := Sixteen_Bytes(0)
		i := 0
		switch bpp {
		case 4:
			for ; i + 16 <= n; i += 16 {
				v := intrinsics.unaligned_load((^Sixteen_Bytes)(&raw_ptr[i]))
				v = v + intrinsics.simd_shuffle(zero, v, 0, 1, 2, 3, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27)
				v = v + intrinsics.simd_shuffle(zero, v, 0, 1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19, 20, 21, 22, 23)
				v = v + carry
				intrinsics.unaligned_store((^Sixteen_Bytes)(&dst_ptr[i]), v)
				carry = intrinsics.simd_shuffle(v, v, 12, 13, 14, 15, 12, 13, 14, 15, 12, 13, 14, 15, 12, 13, 14, 15)
			}
		case 3:
			// Process 4 RGB pixels (12 bytes) per step only while a 16-byte load is in bounds.
			for ; i + 16 <= n; i += 12 {
				v := intrinsics.unaligned_load((^Sixteen_Bytes)(&raw_ptr[i]))
				v = v + intrinsics.simd_shuffle(zero, v, 0, 1, 2, 16, 17, 18, 19, 20, 21, 22, 23, 24, 0, 0, 0, 0)
				v = v + intrinsics.simd_shuffle(zero, v, 0, 1, 2, 3, 4, 5, 16, 17, 18, 19, 20, 21, 0, 0, 0, 0)
				v = v + carry
				arr := transmute([16]u8)v
				intrinsics.unaligned_store((^u64)(&dst_ptr[i]), intrinsics.unaligned_load((^u64)(&arr[0])))
				intrinsics.unaligned_store((^u32)(&dst_ptr[i + 8]), intrinsics.unaligned_load((^u32)(&arr[8])))
				carry = intrinsics.simd_shuffle(v, v, 9, 10, 11, 9, 10, 11, 9, 10, 11, 9, 10, 11, 0, 0, 0, 0)
			}
		case 2:
			for ; i + 16 <= n; i += 16 {
				v := intrinsics.unaligned_load((^Sixteen_Bytes)(&raw_ptr[i]))
				v = v + intrinsics.simd_shuffle(zero, v, 0, 1, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29)
				v = v + intrinsics.simd_shuffle(zero, v, 0, 1, 2, 3, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27)
				v = v + intrinsics.simd_shuffle(zero, v, 0, 1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19, 20, 21, 22, 23)
				v = v + carry
				intrinsics.unaligned_store((^Sixteen_Bytes)(&dst_ptr[i]), v)
				carry = intrinsics.simd_shuffle(v, v, 14, 15, 14, 15, 14, 15, 14, 15, 14, 15, 14, 15, 14, 15, 14, 15)
			}
		case 1:
			for ; i + 16 <= n; i += 16 {
				v := intrinsics.unaligned_load((^Sixteen_Bytes)(&raw_ptr[i]))
				v = v + intrinsics.simd_shuffle(zero, v, 0, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30)
				v = v + intrinsics.simd_shuffle(zero, v, 0, 1, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29)
				v = v + intrinsics.simd_shuffle(zero, v, 0, 1, 2, 3, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27)
				v = v + intrinsics.simd_shuffle(zero, v, 0, 1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19, 20, 21, 22, 23)
				v = v + carry
				intrinsics.unaligned_store((^Sixteen_Bytes)(&dst_ptr[i]), v)
				carry = intrinsics.simd_shuffle(v, v, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15)
			}
		}
		// Scalar tail continues from decoded bytes already written in dst[0 ..< i].
		for ; i < n; i += 1 {
			left := i >= bpp ? dst_ptr[i - bpp] : 0
			dst_ptr[i] = raw_ptr[i] + left
		}

	case .Average:
		if bpp == 4 {
			a := Four_U16(0)
			i := 0
			for ; i + 4 <= n; i += 4 {
				r_word := intrinsics.unaligned_load((^u32)(&raw_ptr[i]))
				p_word := intrinsics.unaligned_load((^u32)(&prev_ptr[i]))
				r := cast(Four_U16)(transmute(Four_U8)r_word)
				b := cast(Four_U16)(transmute(Four_U8)p_word)
				avg := intrinsics.simd_shr(a + b, Four_U16(1))
				a = intrinsics.simd_bit_and(r + avg, Four_U16(0xFF))
				intrinsics.unaligned_store((^u32)(&dst_ptr[i]), transmute(u32)(cast(Four_U8)a))
			}
			for ; i < n; i += 1 {
				left := i >= 4 ? dst_ptr[i - 4] : 0
				dst_ptr[i] = raw_ptr[i] + u8((u16(left) + u16(prev_ptr[i])) >> 1)
			}
		} else if bpp == 3 {
			a := Four_U16(0)
			i := 0
			for ; i + 4 <= n; i += 3 {
				r_word := intrinsics.unaligned_load((^u32)(&raw_ptr[i]))
				p_word := intrinsics.unaligned_load((^u32)(&prev_ptr[i]))
				r := cast(Four_U16)(transmute(Four_U8)r_word)
				b := cast(Four_U16)(transmute(Four_U8)p_word)
				avg := intrinsics.simd_shr(a + b, Four_U16(1))
				a = intrinsics.simd_bit_and(r + avg, Four_U16(0xFF))
				out := transmute([4]u8)(cast(Four_U8)a)
				dst_ptr[i] = out[0]
				dst_ptr[i + 1] = out[1]
				dst_ptr[i + 2] = out[2]
			}
			for ; i < n; i += 1 {
				left := i >= 3 ? dst_ptr[i - 3] : 0
				dst_ptr[i] = raw_ptr[i] + u8((u16(left) + u16(prev_ptr[i])) >> 1)
			}
		} else {
			png_unfilter_row_scalar(filter, dst, raw, prev, bpp)
		}

	case .Paeth:
		if bpp == 4 {
			a := Four_I16(0)
			c := Four_I16(0)
			i := 0
			for ; i + 4 <= n; i += 4 {
				r_word := intrinsics.unaligned_load((^u32)(&raw_ptr[i]))
				p_word := intrinsics.unaligned_load((^u32)(&prev_ptr[i]))
				r := cast(Four_I16)(transmute(Four_U8)r_word)
				b := cast(Four_I16)(transmute(Four_U8)p_word)
				diff_bc := b - c
				diff_ac := a - c
				pa := intrinsics.simd_max(diff_bc, -diff_bc)
				pb := intrinsics.simd_max(diff_ac, -diff_ac)
				sum_ab_2c := diff_ac + diff_bc
				pc := intrinsics.simd_max(sum_ab_2c, -sum_ab_2c)
				use_a := intrinsics.simd_bit_and(intrinsics.simd_lanes_le(pa, pb), intrinsics.simd_lanes_le(pa, pc))
				use_b := intrinsics.simd_lanes_le(pb, pc)
				pred := intrinsics.simd_select(use_a, a, intrinsics.simd_select(use_b, b, c))
				a = intrinsics.simd_bit_and(r + pred, Four_I16(0xFF))
				c = b
				intrinsics.unaligned_store((^u32)(&dst_ptr[i]), transmute(u32)(cast(Four_U8)a))
			}
			for ; i < n; i += 1 {
				left := i >= 4 ? dst_ptr[i - 4] : 0
				up_left := i >= 4 ? prev_ptr[i - 4] : 0
				dst_ptr[i] = raw_ptr[i] + paeth_predictor(left, prev_ptr[i], up_left)
			}
		} else if bpp == 3 {
			a := Four_I16(0)
			c := Four_I16(0)
			i := 0
			for ; i + 4 <= n; i += 3 {
				r_word := intrinsics.unaligned_load((^u32)(&raw_ptr[i]))
				p_word := intrinsics.unaligned_load((^u32)(&prev_ptr[i]))
				r := cast(Four_I16)(transmute(Four_U8)r_word)
				b := cast(Four_I16)(transmute(Four_U8)p_word)
				diff_bc := b - c
				diff_ac := a - c
				pa := intrinsics.simd_max(diff_bc, -diff_bc)
				pb := intrinsics.simd_max(diff_ac, -diff_ac)
				sum_ab_2c := diff_ac + diff_bc
				pc := intrinsics.simd_max(sum_ab_2c, -sum_ab_2c)
				use_a := intrinsics.simd_bit_and(intrinsics.simd_lanes_le(pa, pb), intrinsics.simd_lanes_le(pa, pc))
				use_b := intrinsics.simd_lanes_le(pb, pc)
				pred := intrinsics.simd_select(use_a, a, intrinsics.simd_select(use_b, b, c))
				a = intrinsics.simd_bit_and(r + pred, Four_I16(0xFF))
				c = b
				out := transmute([4]u8)(cast(Four_U8)a)
				dst_ptr[i] = out[0]
				dst_ptr[i + 1] = out[1]
				dst_ptr[i + 2] = out[2]
			}
			for ; i < n; i += 1 {
				left := i >= 3 ? dst_ptr[i - 3] : 0
				up_left := i >= 3 ? prev_ptr[i - 3] : 0
				dst_ptr[i] = raw_ptr[i] + paeth_predictor(left, prev_ptr[i], up_left)
			}
		} else {
			png_unfilter_row_scalar(filter, dst, raw, prev, bpp)
		}
	}
}
