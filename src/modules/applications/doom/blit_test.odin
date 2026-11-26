#+build !freestanding
package doom

import "core:testing"
import "modus:graphics"

// Host test stubs for the C doomgeneric entry points linked in freestanding builds.
modus_doom_init :: proc "c" (host: ^Doom_Host) -> i32 {
	_ = host
	return 0
}

modus_doom_tick :: proc "c" () -> i32 {
	return 0
}

@(private = "file")
BLIT_TEST_SEED :: u64(0xD00D_F00D_1993_1210)
@(private = "file")
GUARD_WORD :: graphics.Color(0xA55A_5AA5)

@(private = "file")
next_prng :: proc(state: ^u64) -> u64 {
	x := state^
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	state^ = x
	return x
}

@(private = "file")
fill_test_palette :: proc(palette: ^[256]graphics.Color, seed: ^u64) {
	palette[0] = 0x0000_0000
	palette[1] = 0x0001_0101
	palette[254] = 0x00FE_FEFE
	palette[255] = 0x00FF_FFFF
	for i in 2 ..< 254 {
		palette[i] = graphics.Color(next_prng(seed) & 0x00FF_FFFF)
	}
}

@(test)
indexed_row_blit_matches_scalar_across_edge_widths_and_alignments :: proc(t: ^testing.T) {
	seed := BLIT_TEST_SEED
	palette: [256]graphics.Color
	fill_test_palette(&palette, &seed)

	src: [128]u8
	for i in 0 ..< len(src) {
		switch i % 8 {
		case 0: src[i] = 0
		case 1: src[i] = 1
		case 2: src[i] = 254
		case 3: src[i] = 255
		case: src[i] = u8(next_prng(&seed) & 0xFF)
		}
	}

	// Test every width from 0 to 67 and every alignment offset 0..3 against
	// guard words before and after the written slice.
	for width in 0 ..= 67 {
		for align in 0 ..< 4 {
			scalar_buf: [160]graphics.Color
			vector_buf: [160]graphics.Color
			for i in 0 ..< len(scalar_buf) {
				scalar_buf[i] = GUARD_WORD
				vector_buf[i] = GUARD_WORD
			}
			start := 4 + align
			blit_indexed_row_scalar(raw_data(scalar_buf[start:]), raw_data(src[align:]), &palette, width)
			blit_indexed_row(raw_data(vector_buf[start:]), raw_data(src[align:]), &palette, width)

			for i in 0 ..< len(scalar_buf) {
				if scalar_buf[i] != vector_buf[i] {
					testing.expectf(t, false, "1:1 blit mismatch at width=%d align=%d index=%d: scalar=0x%08x vector=0x%08x", width, align, i, scalar_buf[i], vector_buf[i])
					return
				}
				if (i < start || i >= start + width) && vector_buf[i] != GUARD_WORD {
					testing.expectf(t, false, "1:1 blit overwrote guard at width=%d align=%d index=%d: 0x%08x", width, align, i, vector_buf[i])
					return
				}
			}
		}
	}
}

@(test)
indexed_row_2x_and_scaled_blit_match_scalar :: proc(t: ^testing.T) {
	seed := BLIT_TEST_SEED ~ 0x55AA_55AA
	palette: [256]graphics.Color
	fill_test_palette(&palette, &seed)

	src: [DOOM_WIDTH]u8
	for i in 0 ..< len(src) {
		src[i] = u8(next_prng(&seed) & 0xFF)
	}

	// 2x expansion across widths 0..67 and alignments 0..3.
	for width in 0 ..= 67 {
		for align in 0 ..< 4 {
			scalar_buf: [200]graphics.Color
			vector_buf: [200]graphics.Color
			for i in 0 ..< len(scalar_buf) {
				scalar_buf[i] = GUARD_WORD
				vector_buf[i] = GUARD_WORD
			}
			start := 4 + align
			blit_indexed_row_2x_scalar(raw_data(scalar_buf[start:]), raw_data(src[:]), &palette, width)
			blit_indexed_row_2x(raw_data(vector_buf[start:]), raw_data(src[:]), &palette, width)
			out_len := width * 2
			for i in 0 ..< len(scalar_buf) {
				testing.expectf(t, scalar_buf[i] == vector_buf[i], "2x blit mismatch width=%d align=%d idx=%d", width, align, i)
				if i < start || i >= start + out_len {
					testing.expect_value(t, vector_buf[i], GUARD_WORD)
				}
			}
		}
	}

	// Scaled row across edge widths and HiDPI widths (320, 640, 800, 960, 1280).
	dst_widths := [?]int{0, 1, 2, 3, 4, 5, 15, 16, 17, 63, 64, 65, 67, 320, 640, 800, 960, 1280}
	for dst_w in dst_widths {
		scalar_buf := make([]graphics.Color, dst_w + 16)
		vector_buf := make([]graphics.Color, dst_w + 16)
		defer delete(scalar_buf)
		defer delete(vector_buf)
		for i in 0 ..< len(scalar_buf) {
			scalar_buf[i] = GUARD_WORD
			vector_buf[i] = GUARD_WORD
		}
		start := 5
		blit_indexed_row_scaled_scalar(raw_data(scalar_buf[start:]), dst_w, raw_data(src[:]), DOOM_WIDTH, &palette)
		blit_indexed_row_scaled(raw_data(vector_buf[start:]), dst_w, raw_data(src[:]), DOOM_WIDTH, &palette)
		for i in 0 ..< len(scalar_buf) {
			if scalar_buf[i] != vector_buf[i] {
				testing.expectf(t, false, "scaled blit mismatch dst_w=%d idx=%d: scalar=0x%08x vector=0x%08x", dst_w, i, scalar_buf[i], vector_buf[i])
				return
			}
			if (i < start || i >= start + dst_w) && vector_buf[i] != GUARD_WORD {
				testing.expectf(t, false, "scaled blit guard overwrite dst_w=%d idx=%d", dst_w, i)
				return
			}
		}
	}
}

@(test)
full_frame_blit_matches_scalar_at_all_scales :: proc(t: ^testing.T) {
	seed := BLIT_TEST_SEED ~ 0xCAFE_BABE
	palette: [256]graphics.Color
	fill_test_palette(&palette, &seed)

	src := make([]u8, DOOM_WIDTH * DOOM_HEIGHT)
	defer delete(src)
	for i in 0 ..< len(src) {
		src[i] = u8(next_prng(&seed) & 0xFF)
	}

	Size_Case :: struct {
		w, h, stride: int,
	}
	cases := [?]Size_Case{
		{0, 0, 0},
		{1, 1, 4},
		{67, 31, 72},
		{320, 200, 320},
		{640, 400, 640},
		{640, 400, 648},
		{800, 500, 800},
		{960, 600, 960},
		{1280, 800, 1280},
	}
	for c in cases {
		total := max(c.stride * c.h, 0) + 16
		scalar_pixels := make([]graphics.Color, total)
		vector_pixels := make([]graphics.Color, total)
		defer delete(scalar_pixels)
		defer delete(vector_pixels)
		for i in 0 ..< total {
			scalar_pixels[i] = GUARD_WORD
			vector_pixels[i] = GUARD_WORD
		}
		scalar_canvas := graphics.Canvas{pixels = raw_data(scalar_pixels[8:]), width = c.w, height = c.h, stride = c.stride}
		vector_canvas := graphics.Canvas{pixels = raw_data(vector_pixels[8:]), width = c.w, height = c.h, stride = c.stride}
		blit_indexed_frame_scalar(scalar_canvas, raw_data(src), DOOM_WIDTH, DOOM_HEIGHT, &palette)
		blit_indexed_frame(vector_canvas, raw_data(src), DOOM_WIDTH, DOOM_HEIGHT, &palette)
		for i in 0 ..< total {
			if scalar_pixels[i] != vector_pixels[i] {
				testing.expectf(t, false, "frame mismatch %dx%d (stride %d) at %d: scalar=0x%08x vector=0x%08x", c.w, c.h, c.stride, i, scalar_pixels[i], vector_pixels[i])
				return
			}
		}
	}
}
