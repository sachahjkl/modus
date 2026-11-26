#+build !freestanding
#+build !modus
package graphics

import "core:fmt"
import "core:testing"
import "core:time"

// Exhaustive adversarial equivalence tests and opt-in throughput measures
// for blend_span_simd, horizontal_gradient_span_simd,
// horizontal_gradient_with_alpha_span_simd, mix_with_alpha_span_simd, and
// path_coverage_span_simd against their scalar references (docs/SIMD.md).

@(private = "file")
MEASURE_VECTORS :: #config(MEASURE, false)

@(private = "file")
Vector_Random :: struct {
	state: u64,
}

@(private = "file")
vector_next :: proc(rng: ^Vector_Random) -> u32 {
	rng.state ~= rng.state >> 12
	rng.state ~= rng.state << 25
	rng.state ~= rng.state >> 27
	return u32((rng.state * 0x2545F4914F6CDD1D) >> 32)
}

@(private = "file")
TEST_WIDTHS :: [?]int{0, 1, 2, 3, 4, 5, 7, 8, 15, 16, 17, 63, 64, 65, 1023}

@(private = "file")
ALPHA_EDGES :: [?]u32{0, 1, 127, 128, 254, 255}

@(private = "file")
SATURATED_COLORS :: [?]u32{
	0x000000,
	0xFFFFFF,
	0xFF0000,
	0x00FF00,
	0x0000FF,
	0x01FE80,
	0xFE017F,
	DARK_TITLE,
	DARK_TITLE_END,
}

@(private = "file")
GUARD_PIXELS :: 16

@(test)
blend_span_simd_matches_scalar_all_edges :: proc(t: ^testing.T) {
	when ODIN_ARCH == .amd64 {
		table: [4096]u8
		square_root_table_fill(&table)
		rng := Vector_Random{state = 0x9E3779B97F4A7C15}
		MAX_BUF :: GUARD_PIXELS + 3 + 1023 + GUARD_PIXELS
		scalar_buf, simd_buf: [MAX_BUF]Color

		// Negative count must touch zero pixels in both forms.
		for &p in scalar_buf {
			p = 0xDEADBEEF
		}
		simd_buf = scalar_buf
		blend_span_scalar(raw_data(scalar_buf[GUARD_PIXELS:]), -7, 0x80ABCDEF, &table)
		blend_span_simd(raw_data(simd_buf[GUARD_PIXELS:]), -7, 0x80ABCDEF, &table)
		testing.expect(t, scalar_buf == simd_buf, "negative count must match scalar and leave buffer untouched")

		wrong := 0
		for width in TEST_WIDTHS {
			for align in 0 ..< 4 {
				for alpha in ALPHA_EDGES {
					for base_color in SATURATED_COLORS {
						color := alpha << 24 | base_color
						total := GUARD_PIXELS + align + width + GUARD_PIXELS
						for index in 0 ..< total {
							scalar_buf[index] = vector_next(&rng)
							simd_buf[index] = scalar_buf[index]
						}
						start := GUARD_PIXELS + align
						blend_span_scalar(raw_data(scalar_buf[start:]), width, color, &table)
						blend_span_simd(raw_data(simd_buf[start:]), width, color, &table)
						for index in 0 ..< total {
							if scalar_buf[index] != simd_buf[index] {
								wrong += 1
								if wrong <= 5 {
									testing.expectf(t, false, "blend_span width=%d align=%d color=%08x idx=%d: scalar=%08x simd=%08x", width, align, color, index, scalar_buf[index], simd_buf[index])
								}
							}
						}
					}
				}
			}
		}
		testing.expect_value(t, wrong, 0)
	}
}

@(test)
blend_span_matches_blend_straight_alpha_row :: proc(t: ^testing.T) {
	table: [4096]u8
	square_root_table_fill(&table)
	rng := Vector_Random{state = 0x123456789ABCDEF1}
	WIDTH :: 257
	ref_buf, span_buf: [WIDTH]Color
	src_buf: [WIDTH]u32
	for alpha in ALPHA_EDGES {
		color := alpha << 24 | 0x3F7CC4
		for i in 0 ..< WIDTH {
			ref_buf[i] = vector_next(&rng)
			span_buf[i] = ref_buf[i]
			src_buf[i] = color
		}
		blend_straight_alpha_row_scalar(raw_data(ref_buf[:]), raw_data(src_buf[:]), WIDTH, &table)
		blend_span(raw_data(span_buf[:]), WIDTH, color, &table)
		testing.expectf(t, ref_buf == span_buf, "blend_span must match blend_straight_alpha_row_scalar for color=%08x", color)
	}
}

@(test)
horizontal_gradient_span_simd_matches_scalar_all_edges :: proc(t: ^testing.T) {
	when ODIN_ARCH == .amd64 {
		MAX_BUF :: GUARD_PIXELS + 3 + 1023 + GUARD_PIXELS
		scalar_buf, simd_buf: [MAX_BUF]Color
		totals := [?]int{-10, 0, 1, 2, 3, 4, 17, 256, 1023, 4096}
		firsts := [?]int{-100_000, -17, -1, 0, 1, 13, 500, 100_000}
		pairs := [?][2]u32{
			{0x00000000, 0xFFFFFFFF},
			{0xFFFFFFFF, 0x00000000},
			{0x01_FF_00_80, 0xFE_00_FF_7F},
			{0x80_3F_7C_C4, 0x80_16_2C_45},
			{0xFF_17_21_2E, 0xFF_11_18_22},
		}

		wrong := 0
		for width in TEST_WIDTHS {
			for align in 0 ..< 4 {
				total_buf := GUARD_PIXELS + align + width + GUARD_PIXELS
				start_idx := GUARD_PIXELS + align
				for pair in pairs {
					for total in totals {
						for first in firsts {
							for i in 0 ..< total_buf {
								scalar_buf[i] = 0xA5A5A5A5
								simd_buf[i] = 0xA5A5A5A5
							}
							horizontal_gradient_span_scalar(scalar_buf[start_idx:start_idx + width], pair[0], pair[1], total, first)
							horizontal_gradient_span_simd(simd_buf[start_idx:start_idx + width], pair[0], pair[1], total, first)
							for i in 0 ..< total_buf {
								if scalar_buf[i] != simd_buf[i] {
									wrong += 1
									if wrong <= 5 {
										testing.expectf(t, false, "hgrad width=%d align=%d total=%d first=%d idx=%d: scalar=%08x simd=%08x", width, align, total, first, i, scalar_buf[i], simd_buf[i])
									}
								}
							}

							for i in 0 ..< total_buf {
								scalar_buf[i] = 0x5A5A5A5A
								simd_buf[i] = 0x5A5A5A5A
							}
							horizontal_gradient_with_alpha_span_scalar(scalar_buf[start_idx:start_idx + width], pair[0], pair[1], total, first)
							horizontal_gradient_with_alpha_span_simd(simd_buf[start_idx:start_idx + width], pair[0], pair[1], total, first)
							for i in 0 ..< total_buf {
								if scalar_buf[i] != simd_buf[i] {
									wrong += 1
									if wrong <= 5 {
										testing.expectf(t, false, "hgrad_alpha width=%d align=%d total=%d first=%d idx=%d: scalar=%08x simd=%08x", width, align, total, first, i, scalar_buf[i], simd_buf[i])
									}
								}
							}
						}
					}
				}
			}
		}
		testing.expect_value(t, wrong, 0)
	}
}

@(test)
mix_with_alpha_span_simd_matches_scalar_all_levels :: proc(t: ^testing.T) {
	when ODIN_ARCH == .amd64 {
		// Exhaustively verify every level 0..255 against every edge channel pair.
		levels: [256]u8
		for i in 0 ..< 256 {
			levels[i] = u8(i)
		}
		scalar_row, simd_row: [256]u32
		edge_bytes := [?]u32{0, 1, 2, 127, 128, 254, 255}
		wrong := 0
		for a in edge_bytes {
			for b in edge_bytes {
				start := a << 24 | a << 16 | (255 - a) << 8 | b
				end := b << 24 | b << 16 | (255 - b) << 8 | a
				mix_with_alpha_span_scalar(scalar_row[:], start, end, levels[:])
				mix_with_alpha_span_simd(simd_row[:], start, end, levels[:])
				if scalar_row != simd_row {
					wrong += 1
				}
			}
		}
		testing.expect_value(t, wrong, 0)

		// Verify all test widths with guard words.
		MAX_BUF :: GUARD_PIXELS + 3 + 1023 + GUARD_PIXELS
		scalar_buf, simd_buf: [MAX_BUF]u32
		lvl_buf: [1023]u8
		for i in 0 ..< len(lvl_buf) {
			lvl_buf[i] = u8((i * 37) & 0xFF)
		}
		for width in TEST_WIDTHS {
			for align in 0 ..< 4 {
				total := GUARD_PIXELS + align + width + GUARD_PIXELS
				for i in 0 ..< total {
					scalar_buf[i] = 0xCAFEBABE
					simd_buf[i] = 0xCAFEBABE
				}
				start_idx := GUARD_PIXELS + align
				mix_with_alpha_span_scalar(scalar_buf[start_idx:start_idx + width], 0x10_FF_01_80, 0xF0_00_FE_7F, lvl_buf[:width])
				mix_with_alpha_span_simd(simd_buf[start_idx:start_idx + width], 0x10_FF_01_80, 0xF0_00_FE_7F, lvl_buf[:width])
				for i in 0 ..< total {
					if scalar_buf[i] != simd_buf[i] {
						wrong += 1
					}
				}
			}
		}
		testing.expect_value(t, wrong, 0)
	}
}

@(test)
path_coverage_span_simd_matches_scalar_all_edges :: proc(t: ^testing.T) {
	when ODIN_ARCH == .amd64 {
		table: [4096]u8
		square_root_table_fill(&table)
		rng := Vector_Random{state = 0xD1B54A32D192ED03}
		MAX_BUF :: GUARD_PIXELS + 3 + 1023 + GUARD_PIXELS
		scalar_buf, simd_buf: [MAX_BUF]Color
		cells_buf: [MAX_BUF]i32

		// Negative count returns initial_sum and touches zero pixels.
		for &p in scalar_buf {
			p = 0x13572468
		}
		simd_buf = scalar_buf
		s_neg := path_coverage_span_scalar(raw_data(scalar_buf[GUARD_PIXELS:]), raw_data(cells_buf[GUARD_PIXELS:]), -3, 0xFF112233, &table, 4096)
		v_neg := path_coverage_span_simd(raw_data(simd_buf[GUARD_PIXELS:]), raw_data(cells_buf[GUARD_PIXELS:]), -3, 0xFF112233, &table, 4096)
		testing.expect_value(t, v_neg, s_neg)
		testing.expect(t, scalar_buf == simd_buf, "negative count must leave buffer untouched")

		// Extreme signed values including min(i32) and max(i32) clamping.
		extreme_cells := [8]i32{min(i32), 0, max(i32), 1, -4096, 4096, 8192, -8192}
		ext_scalar, ext_simd: [8]Color
		for i in 0 ..< 8 {
			ext_scalar[i] = 0xAB123456
			ext_simd[i] = 0xAB123456
		}
		es := path_coverage_span_scalar(raw_data(ext_scalar[:]), raw_data(extreme_cells[:]), 8, 0x80F0E0D0, &table, 0)
		ev := path_coverage_span_simd(raw_data(ext_simd[:]), raw_data(extreme_cells[:]), 8, 0x80F0E0D0, &table, 0)
		testing.expect_value(t, ev, es)
		testing.expect(t, ext_scalar == ext_simd, "extreme i32 cells must match bit-for-bit")

		initial_sums := [?]i32{-16384, -8192, -1, 0, 1, 4096, 8192}
		saturated := SATURATED_COLORS
		wrong := 0
		for width in TEST_WIDTHS {
			for align in 0 ..< 4 {
				total := GUARD_PIXELS + align + width + GUARD_PIXELS
				start := GUARD_PIXELS + align
				for alpha in ALPHA_EDGES {
					color := alpha << 24 | saturated[(width + align + int(alpha)) % len(saturated)]
					for pattern in 0 ..< 5 {
						for i in 0 ..< total {
							scalar_buf[i] = vector_next(&rng)
							simd_buf[i] = scalar_buf[i]
						}
						for i in 0 ..< width {
							switch pattern {
							case 0:
								// All zeros: tests fast skip path.
								cells_buf[start + i] = 0
							case 1:
								// Immediately saturated opaque run, then drops back to 0.
								if i == 0 {
									cells_buf[start + i] = PATH_COVERAGE_FULL_PIXEL
								} else if i == width / 2 {
									cells_buf[start + i] = -PATH_COVERAGE_FULL_PIXEL
								} else {
									cells_buf[start + i] = 0
								}
							case 2:
								// Mixed partial/zero/opaque inside every 4-pixel group.
								switch i % 4 {
								case 0:
									cells_buf[start + i] = 2048
								case 1:
									cells_buf[start + i] = 6144
								case 2:
									cells_buf[start + i] = -8192
								case 3:
									cells_buf[start + i] = 0
								}
							case 3:
								// Negative winding and overshoot beyond +/-PATH_COVERAGE_FULL_PIXEL.
								cells_buf[start + i] = i32(vector_next(&rng) % 24001) - 12000
							case 4:
								// Small antialiased step deltas.
								cells_buf[start + i] = i32(vector_next(&rng) % 513) - 256
							}
						}
						init_sum := initial_sums[(width + pattern + int(alpha)) % len(initial_sums)]
						s_sum := path_coverage_span_scalar(raw_data(scalar_buf[start:]), raw_data(cells_buf[start:]), width, color, &table, init_sum)
						v_sum := path_coverage_span_simd(raw_data(simd_buf[start:]), raw_data(cells_buf[start:]), width, color, &table, init_sum)
						if s_sum != v_sum {
							wrong += 1
							if wrong <= 5 {
								testing.expectf(t, false, "path_coverage sum mismatch width=%d pattern=%d alpha=%d: scalar=%d simd=%d", width, pattern, alpha, s_sum, v_sum)
							}
						}
						for i in 0 ..< total {
							if scalar_buf[i] != simd_buf[i] {
								wrong += 1
								if wrong <= 5 {
									testing.expectf(t, false, "path_coverage pixel mismatch width=%d align=%d pattern=%d color=%08x idx=%d: scalar=%08x simd=%08x", width, align, pattern, color, i, scalar_buf[i], simd_buf[i])
								}
							}
						}
					}
				}
			}
		}
		testing.expect_value(t, wrong, 0)
	}
}

@(test)
graphics_vectors_throughput_measure :: proc(t: ^testing.T) {
	if !MEASURE_VECTORS {
		return
	}
	when ODIN_ARCH == .amd64 {
		table: [4096]u8
		square_root_table_fill(&table)
		PIXELS :: 1920
		ITERS :: 8000
		RUNS :: 5

		dst_scalar := make([]Color, PIXELS)
		dst_simd := make([]Color, PIXELS)
		cells := make([]i32, PIXELS)
		levels := make([]u8, PIXELS)
		defer delete(dst_scalar)
		defer delete(dst_simd)
		defer delete(cells)
		defer delete(levels)

		rng := Vector_Random{state = 42}
		for i in 0 ..< PIXELS {
			dst_scalar[i] = vector_next(&rng) & 0x00FFFFFF
			dst_simd[i] = dst_scalar[i]
			levels[i] = u8((i * 255) / (PIXELS - 1))
			// Mix of edge ramps and filled interior spans typical of UI paths.
			switch i % 32 {
			case 0:
				cells[i] = 2048
			case 1:
				cells[i] = 6144
			case 16:
				cells[i] = -6144
			case 17:
				cells[i] = -2048
			case:
				cells[i] = 0
			}
		}

		// 1. Translucent solid span blend
		best_blend_scalar := max(f64)
		best_blend_simd := max(f64)
		for _ in 0 ..< RUNS {
			t0 := time.tick_now()
			for _ in 0 ..< ITERS {
				blend_span_scalar(raw_data(dst_scalar), PIXELS, 0x80_3F_7C_C4, &table)
			}
			best_blend_scalar = min(best_blend_scalar, time.duration_seconds(time.tick_since(t0)))

			t1 := time.tick_now()
			for _ in 0 ..< ITERS {
				blend_span_simd(raw_data(dst_simd), PIXELS, 0x80_3F_7C_C4, &table)
			}
			best_blend_simd = min(best_blend_simd, time.duration_seconds(time.tick_since(t1)))
		}
		testing.expect(t, slice_equal(dst_scalar, dst_simd), "benchmark blend_span mismatch")
		total_pixels := f64(PIXELS) * f64(ITERS)
		total_mib := total_pixels * 4.0 / f64(1 << 20)
		fmt.printfln(
			"graphics: measure: blend_span (1920 px): scalar %.2f ns/px (%.0f MiB/s), sse2 %.2f ns/px (%.0f MiB/s), speedup %.2fx",
			best_blend_scalar * 1e9 / total_pixels,
			total_mib / best_blend_scalar,
			best_blend_simd * 1e9 / total_pixels,
			total_mib / best_blend_simd,
			best_blend_scalar / best_blend_simd,
		)

		// 2. Horizontal gradient span
		best_grad_scalar := max(f64)
		best_grad_simd := max(f64)
		for _ in 0 ..< RUNS {
			t0 := time.tick_now()
			for _ in 0 ..< ITERS {
				horizontal_gradient_span_scalar(dst_scalar, DARK_TITLE, DARK_TITLE_END, PIXELS, 0)
			}
			best_grad_scalar = min(best_grad_scalar, time.duration_seconds(time.tick_since(t0)))

			t1 := time.tick_now()
			for _ in 0 ..< ITERS {
				horizontal_gradient_span_simd(dst_simd, DARK_TITLE, DARK_TITLE_END, PIXELS, 0)
			}
			best_grad_simd = min(best_grad_simd, time.duration_seconds(time.tick_since(t1)))
		}
		testing.expect(t, slice_equal(dst_scalar, dst_simd), "benchmark horizontal_gradient_span mismatch")
		fmt.printfln(
			"graphics: measure: horizontal_gradient_span (1920 px): scalar %.2f ns/px (%.0f MiB/s), sse2 %.2f ns/px (%.0f MiB/s), speedup %.2fx",
			best_grad_scalar * 1e9 / total_pixels,
			total_mib / best_grad_scalar,
			best_grad_simd * 1e9 / total_pixels,
			total_mib / best_grad_simd,
			best_grad_scalar / best_grad_simd,
		)

		// 3. Mix with alpha levels span (draw-record horizontal gradient)
		best_mix_scalar := max(f64)
		best_mix_simd := max(f64)
		for _ in 0 ..< RUNS {
			t0 := time.tick_now()
			for _ in 0 ..< ITERS {
				mix_with_alpha_span_scalar(dst_scalar, 0xFF_3F_7C_C4, 0x80_16_2C_45, levels)
			}
			best_mix_scalar = min(best_mix_scalar, time.duration_seconds(time.tick_since(t0)))

			t1 := time.tick_now()
			for _ in 0 ..< ITERS {
				mix_with_alpha_span_simd(dst_simd, 0xFF_3F_7C_C4, 0x80_16_2C_45, levels)
			}
			best_mix_simd = min(best_mix_simd, time.duration_seconds(time.tick_since(t1)))
		}
		testing.expect(t, slice_equal(dst_scalar, dst_simd), "benchmark mix_with_alpha_span mismatch")
		fmt.printfln(
			"graphics: measure: mix_with_alpha_span (1920 px): scalar %.2f ns/px (%.0f MiB/s), sse2 %.2f ns/px (%.0f MiB/s), speedup %.2fx",
			best_mix_scalar * 1e9 / total_pixels,
			total_mib / best_mix_scalar,
			best_mix_simd * 1e9 / total_pixels,
			total_mib / best_mix_simd,
			best_mix_scalar / best_mix_simd,
		)

		// 4. Path coverage span
		best_path_scalar := max(f64)
		best_path_simd := max(f64)
		for i in 0 ..< PIXELS {
			dst_scalar[i] = 0x0B1018
			dst_simd[i] = 0x0B1018
		}
		for _ in 0 ..< RUNS {
			t0 := time.tick_now()
			for _ in 0 ..< ITERS {
				_ = path_coverage_span_scalar(raw_data(dst_scalar), raw_data(cells), PIXELS, 0xCC_4A_9C_F0, &table)
			}
			best_path_scalar = min(best_path_scalar, time.duration_seconds(time.tick_since(t0)))

			t1 := time.tick_now()
			for _ in 0 ..< ITERS {
				_ = path_coverage_span_simd(raw_data(dst_simd), raw_data(cells), PIXELS, 0xCC_4A_9C_F0, &table)
			}
			best_path_simd = min(best_path_simd, time.duration_seconds(time.tick_since(t1)))
		}
		testing.expect(t, slice_equal(dst_scalar, dst_simd), "benchmark path_coverage_span mismatch")
		fmt.printfln(
			"graphics: measure: path_coverage_span (1920 px): scalar %.2f ns/px (%.0f MiB/s), sse2 %.2f ns/px (%.0f MiB/s), speedup %.2fx",
			best_path_scalar * 1e9 / total_pixels,
			total_mib / best_path_scalar,
			best_path_simd * 1e9 / total_pixels,
			total_mib / best_path_simd,
			best_path_scalar / best_path_simd,
		)
	}
}

@(private = "file")
slice_equal :: proc(a, b: []Color) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
