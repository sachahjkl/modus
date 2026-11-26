package doom

import "modus:graphics"

// Format property: vanilla Doom software renderer framebuffer dimensions.
DOOM_WIDTH :: 320
DOOM_HEIGHT :: 200

// Plan value: logical window dimensions (exact 2x of 320x200).
WINDOW_WIDTH :: 640
WINDOW_HEIGHT :: 400

// blit_indexed_row_scalar converts `count` 8-bit palette-indexed pixels into
// 32-bit 0x00RRGGBB pixels. Serves as the reference twin for SSE2 host tests,
// non-amd64 targets, and trailing 0..3 pixels.
blit_indexed_row_scalar :: proc "contextless" (dst: [^]graphics.Color, src: [^]u8, palette: ^[256]graphics.Color, count: int) {
	for x in 0 ..< count {
		dst[x] = palette[src[x]]
	}
}

// blit_indexed_row converts `count` 8-bit indexed pixels to 32-bit colors,
// using the SSE2 vector form on amd64 and the scalar twin elsewhere.
blit_indexed_row :: #force_inline proc "contextless" (dst: [^]graphics.Color, src: [^]u8, palette: ^[256]graphics.Color, count: int) {
	when ODIN_ARCH == .amd64 {
		blit_indexed_row_sse2(dst, src, palette, count)
	} else {
		blit_indexed_row_scalar(dst, src, palette, count)
	}
}

// blit_indexed_row_2x_scalar expands `src_width` indexed pixels 2x horizontally
// into `src_width * 2` destination colors.
blit_indexed_row_2x_scalar :: proc "contextless" (dst: [^]graphics.Color, src: [^]u8, palette: ^[256]graphics.Color, src_width: int) {
	for x in 0 ..< src_width {
		color := palette[src[x]]
		dst[x * 2] = color
		dst[x * 2 + 1] = color
	}
}

// blit_indexed_row_2x expands `src_width` indexed pixels 2x horizontally,
// picking the SSE2 vector form on amd64.
blit_indexed_row_2x :: #force_inline proc "contextless" (dst: [^]graphics.Color, src: [^]u8, palette: ^[256]graphics.Color, src_width: int) {
	when ODIN_ARCH == .amd64 {
		blit_indexed_row_2x_sse2(dst, src, palette, src_width)
	} else {
		blit_indexed_row_2x_scalar(dst, src, palette, src_width)
	}
}

// blit_indexed_row_scaled_scalar maps `src_width` indexed pixels to `dst_width`
// destination colors using exact integer nearest-neighbor coordinates
// `src_x = (dst_x * src_width) / dst_width`.
blit_indexed_row_scaled_scalar :: proc "contextless" (dst: [^]graphics.Color, dst_width: int, src: [^]u8, src_width: int, palette: ^[256]graphics.Color) {
	if dst_width <= 0 || src_width <= 0 {
		return
	}
	for x in 0 ..< dst_width {
		src_x := (x * src_width) / dst_width
		dst[x] = palette[src[src_x]]
	}
}

// blit_indexed_row_scaled maps `src_width` indexed pixels to `dst_width`
// destination colors, picking the SSE2 vector form on amd64.
blit_indexed_row_scaled :: #force_inline proc "contextless" (dst: [^]graphics.Color, dst_width: int, src: [^]u8, src_width: int, palette: ^[256]graphics.Color) {
	when ODIN_ARCH == .amd64 {
		blit_indexed_row_scaled_sse2(dst, dst_width, src, src_width, palette)
	} else {
		blit_indexed_row_scaled_scalar(dst, dst_width, src, src_width, palette)
	}
}

// blit_indexed_frame_scalar is the scalar twin for full-frame indexed blitting
// across arbitrary canvas dimensions and strides.
blit_indexed_frame_scalar :: proc "contextless" (canvas: graphics.Canvas, src: [^]u8, src_width, src_height: int, palette: ^[256]graphics.Color) {
	if canvas.width <= 0 || canvas.height <= 0 || src_width <= 0 || src_height <= 0 {
		return
	}
	if canvas.width == src_width * 2 && canvas.height == src_height * 2 {
		for y in 0 ..< src_height {
			src_row := src[y * src_width:]
			dst_top := canvas.pixels[(y * 2) * canvas.stride:]
			dst_bot := canvas.pixels[(y * 2 + 1) * canvas.stride:]
			blit_indexed_row_2x_scalar(dst_top, src_row, palette, src_width)
			blit_indexed_row_2x_scalar(dst_bot, src_row, palette, src_width)
		}
		return
	}
	for y in 0 ..< canvas.height {
		src_y := (y * src_height) / canvas.height
		src_row := src[src_y * src_width:]
		dst_row := canvas.pixels[y * canvas.stride:]
		if canvas.width == src_width {
			blit_indexed_row_scalar(dst_row, src_row, palette, src_width)
		} else {
			blit_indexed_row_scaled_scalar(dst_row, canvas.width, src_row, src_width, palette)
		}
	}
}

// blit_indexed_frame blits an 8-bit palette-indexed Doom framebuffer into
// `canvas` at any logical or HiDPI scale (1x 640x400, 1.25x 800x500,
// 1.5x 960x600, 2x 1280x800, or clamped sizes) without writing out of bounds.
blit_indexed_frame :: proc "contextless" (canvas: graphics.Canvas, src: [^]u8, src_width, src_height: int, palette: ^[256]graphics.Color) {
	if canvas.width <= 0 || canvas.height <= 0 || src_width <= 0 || src_height <= 0 {
		return
	}
	if canvas.width == src_width * 2 && canvas.height == src_height * 2 {
		for y in 0 ..< src_height {
			src_row := src[y * src_width:]
			dst_top := canvas.pixels[(y * 2) * canvas.stride:]
			dst_bot := canvas.pixels[(y * 2 + 1) * canvas.stride:]
			blit_indexed_row_2x(dst_top, src_row, palette, src_width)
			// Reuse the already-converted row for the duplicate scanline.
			for x in 0 ..< canvas.width {
				dst_bot[x] = dst_top[x]
			}
		}
		return
	}
	last_src_y := -1
	for y in 0 ..< canvas.height {
		src_y := (y * src_height) / canvas.height
		dst_row := canvas.pixels[y * canvas.stride:]
		if src_y == last_src_y && y > 0 {
			prev_row := canvas.pixels[(y - 1) * canvas.stride:]
			for x in 0 ..< canvas.width {
				dst_row[x] = prev_row[x]
			}
			continue
		}
		last_src_y = src_y
		src_row := src[src_y * src_width:]
		if canvas.width == src_width {
			blit_indexed_row(dst_row, src_row, palette, src_width)
		} else {
			blit_indexed_row_scaled(dst_row, canvas.width, src_row, src_width, palette)
		}
	}
}
