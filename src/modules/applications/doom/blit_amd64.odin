#+build amd64
package doom

import "base:intrinsics"
import "modus:graphics"

// SSE2 vector forms of the Doom indexed-to-BGRA32 palette blit (docs/SIMD.md).
// Every vector store writes four 32-bit pixels inside the caller's slice, with
// the scalar twin handling any remaining 0..3 pixels so no load or store ever
// crosses the end of a row.

@(private)
Four_Pixels :: #simd[4]u32

// blit_indexed_row_sse2 converts 4 indexed pixels per 128-bit store.
blit_indexed_row_sse2 :: proc "contextless" (dst: [^]graphics.Color, src: [^]u8, palette: ^[256]graphics.Color, count: int) {
	x := 0
	for ; x + 4 <= count; x += 4 {
		vec := Four_Pixels{
			palette[src[x]],
			palette[src[x + 1]],
			palette[src[x + 2]],
			palette[src[x + 3]],
		}
		intrinsics.unaligned_store((^Four_Pixels)(&dst[x]), vec)
	}
	if x < count {
		blit_indexed_row_scalar(dst[x:], src[x:], palette, count - x)
	}
}

// blit_indexed_row_2x_sse2 expands 2 source pixels into 4 destination pixels
// per 128-bit store for the native 320x200 -> 640x400 fast path.
blit_indexed_row_2x_sse2 :: proc "contextless" (dst: [^]graphics.Color, src: [^]u8, palette: ^[256]graphics.Color, src_width: int) {
	x := 0
	for ; x + 2 <= src_width; x += 2 {
		c0 := palette[src[x]]
		c1 := palette[src[x + 1]]
		vec := Four_Pixels{c0, c0, c1, c1}
		intrinsics.unaligned_store((^Four_Pixels)(&dst[x * 2]), vec)
	}
	if x < src_width {
		blit_indexed_row_2x_scalar(dst[x * 2:], src[x:], palette, src_width - x)
	}
}

// blit_indexed_row_scaled_sse2 writes 4 nearest-neighbor scaled destination
// pixels per 128-bit store, matching blit_indexed_row_scaled_scalar byte for
// byte across every width.
blit_indexed_row_scaled_sse2 :: proc "contextless" (dst: [^]graphics.Color, dst_width: int, src: [^]u8, src_width: int, palette: ^[256]graphics.Color) {
	if dst_width <= 0 || src_width <= 0 {
		return
	}
	x := 0
	for ; x + 4 <= dst_width; x += 4 {
		c0 := palette[src[((x + 0) * src_width) / dst_width]]
		c1 := palette[src[((x + 1) * src_width) / dst_width]]
		c2 := palette[src[((x + 2) * src_width) / dst_width]]
		c3 := palette[src[((x + 3) * src_width) / dst_width]]
		vec := Four_Pixels{c0, c1, c2, c3}
		intrinsics.unaligned_store((^Four_Pixels)(&dst[x]), vec)
	}
	for ; x < dst_width; x += 1 {
		dst[x] = palette[src[(x * src_width) / dst_width]]
	}
}
