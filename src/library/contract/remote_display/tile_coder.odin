package remote_display

// The tile coder: the pixels of one tile without loss, in the manner of QOI
// (the Quite OK Image format), for opaque pixels 0x00RRGGBB. Each tile is
// coded alone, from the same start state, so a tile decodes in any order
// and a damaged tile spoils no other.
//
// The codes, each a tag in the high bits of its first byte:
//
// - 0b00iiiiii: the color at the place i of the 64 recent colors;
// - 0b01rrggbb: the last color, each channel changed by -2 to 1 (the value
//   plus 2);
// - 0b10gggggg, then 0brrrrbbbb: green changed by -32 to 31 (plus 32), red
//   and blue by the change of green and -8 to 7 more (plus 8);
// - 0b11nnnnnn, n from 0 to 61: the last color, n + 1 times;
// - 0xFE, then red, green, blue: a whole color;
// - 0xFF: reserved for a color with alpha, which this protocol does not
//   have; the decoder refuses it.
//
// A channel changes with the wrap of a byte, as in QOI. The place of a
// color among the recent ones is (red * 3 + green * 5 + blue * 7 + 255 * 11)
// modulo 64. The last color starts as black, and each recent color as a
// value that no pixel has.

// The most bytes of the code of one pixel: the tag and three channels.
CODED_PIXEL_LIMIT :: 4
CODED_TILE_LIMIT :: TILE_PIXEL_LIMIT * CODED_PIXEL_LIMIT

TAG_INDEX :: 0x00
TAG_DIFFERENCE :: 0x40
TAG_LUMA :: 0x80
TAG_RUN :: 0xC0
TAG_COLOR :: 0xFE
TAG_RESERVED :: 0xFF
TAG_MASK :: 0xC0
RUN_LIMIT :: 62
RECENT_COLORS :: 64
// The value of a recent color at the start: its high byte is set, so no
// opaque pixel equals it.
RECENT_COLOR_START :: u32(0xFF00_0000)
COLOR_MASK :: u32(0x00FF_FFFF)

// coded_limit gives the most bytes of the code of a count of pixels.
coded_limit :: proc "contextless" (pixels: u32) -> u32 {
	return pixels * CODED_PIXEL_LIMIT
}

@(private)
recent_place :: #force_inline proc "contextless" (color: u32) -> u32 {
	red, green, blue := color >> 16 & 0xFF, color >> 8 & 0xFF, color & 0xFF
	return (red * 3 + green * 5 + blue * 7 + 255 * 11) % RECENT_COLORS
}

// tile_encode codes the pixels of a rectangle of a picture whose rows have
// stride pixels, from (x, y), into out, and gives the bytes of the code.
// out must hold coded_limit of the pixels: tile_record_write checks it. The
// high byte of each pixel is not coded: the screen is opaque.
tile_encode :: proc "contextless" (pixels: []u32, stride, x, y, width, height: int, out: []u8) -> int {
	recent: [RECENT_COLORS]u32
	for &color in recent {
		color = RECENT_COLOR_START
	}
	last := u32(0)
	run := 0
	written := 0
	total := width * height
	for row in 0 ..< height {
		line := pixels[(y + row) * stride + x:][:width]
		for column in 0 ..< width {
			color := line[column] & COLOR_MASK
			if color == last {
				run += 1
				if run == RUN_LIMIT || row * width + column == total - 1 {
					out[written] = u8(TAG_RUN | (run - 1))
					written += 1
					run = 0
				}
				continue
			}
			if run > 0 {
				out[written] = u8(TAG_RUN | (run - 1))
				written += 1
				run = 0
			}
			place := recent_place(color)
			if recent[place] == color {
				out[written] = u8(TAG_INDEX | place)
				written += 1
				last = color
				continue
			}
			recent[place] = color
			// The changes as signed bytes, with the wrap of a byte.
			red_change := i8(u8(color >> 16) - u8(last >> 16))
			green_change := i8(u8(color >> 8) - u8(last >> 8))
			blue_change := i8(u8(color) - u8(last))
			red_from_green := red_change - green_change
			blue_from_green := blue_change - green_change
			switch {
			case red_change >= -2 && red_change <= 1 && green_change >= -2 && green_change <= 1 && blue_change >= -2 && blue_change <= 1:
				out[written] = u8(TAG_DIFFERENCE) | u8(red_change + 2) << 4 | u8(green_change + 2) << 2 | u8(blue_change + 2)
				written += 1
			case green_change >= -32 && green_change <= 31 && red_from_green >= -8 && red_from_green <= 7 && blue_from_green >= -8 && blue_from_green <= 7:
				out[written] = u8(TAG_LUMA) | u8(green_change + 32)
				out[written + 1] = u8(red_from_green + 8) << 4 | u8(blue_from_green + 8)
				written += 2
			case:
				out[written] = TAG_COLOR
				out[written + 1] = u8(color >> 16)
				out[written + 2] = u8(color >> 8)
				out[written + 3] = u8(color)
				written += 4
			}
			last = color
		}
	}
	return written
}

// Why tile_decode refused a code.
Tile_Problem :: enum u8 {
	None,
	Past_Pixels, // A run or a pixel past the pixels of the tile.
	Short, // The code ends before the last pixel.
	Bytes_After, // A byte after the last pixel.
	Cut_Code, // A code whose bytes the code does not hold.
	Reserved_Tag, // The tag of a color with alpha.
	Empty_Recent, // A recent color that no pixel of the tile gave.
}

// The sentence of each problem, for a line of the log.
@(rodata)
TILE_PROBLEM_SENTENCES := [Tile_Problem]string {
	.None         = "the tile holds",
	.Past_Pixels  = "its code gives more pixels than the tile has",
	.Short        = "its code ends before the last pixel",
	.Bytes_After  = "its code has bytes after the last pixel",
	.Cut_Code     = "its last code is cut",
	.Reserved_Tag = "its code has the reserved tag of a color with alpha",
	.Empty_Recent = "its code names a recent color that no pixel gave",
}

// tile_decode decodes a code into out, which holds the pixels of the tile
// row after row. Each refusal can leave pixels written in out: the caller
// decodes into its own memory, and copies the tile to the screen only when
// the decode held, so a damaged tile changes nothing.
tile_decode :: proc "contextless" (coded: []u8, out: []u32) -> Tile_Problem {
	recent: [RECENT_COLORS]u32
	for &color in recent {
		color = RECENT_COLOR_START
	}
	last := u32(0)
	place := 0
	read := 0
	for place < len(out) {
		if read >= len(coded) {
			return .Short
		}
		tag := coded[read]
		read += 1
		color: u32
		switch {
		case tag == TAG_RESERVED:
			return .Reserved_Tag
		case tag == TAG_COLOR:
			if len(coded) - read < 3 {
				return .Cut_Code
			}
			color = u32(coded[read]) << 16 | u32(coded[read + 1]) << 8 | u32(coded[read + 2])
			read += 3
		case tag & TAG_MASK == TAG_RUN:
			count := int(tag & ~u8(TAG_MASK)) + 1
			if count > len(out) - place {
				return .Past_Pixels
			}
			for _ in 0 ..< count {
				out[place] = last
				place += 1
			}
			continue
		case tag & TAG_MASK == TAG_INDEX:
			color = recent[tag & ~u8(TAG_MASK)]
			if color == RECENT_COLOR_START {
				// A place that no color took: the encoder never names it.
				return .Empty_Recent
			}
		case tag & TAG_MASK == TAG_DIFFERENCE:
			red := u8(last >> 16) + (tag >> 4 & 3) - 2
			green := u8(last >> 8) + (tag >> 2 & 3) - 2
			blue := u8(last) + (tag & 3) - 2
			color = u32(red) << 16 | u32(green) << 8 | u32(blue)
		case:
			// TAG_LUMA: the last tag of the four.
			if read >= len(coded) {
				return .Cut_Code
			}
			second := coded[read]
			read += 1
			green_change := (tag & 0x3F) - 32
			red := u8(last >> 16) + green_change + (second >> 4) - 8
			green := u8(last >> 8) + green_change
			blue := u8(last) + green_change + (second & 0x0F) - 8
			color = u32(red) << 16 | u32(green) << 8 | u32(blue)
		}
		recent[recent_place(color)] = color
		out[place] = color
		place += 1
		last = color
	}
	if read != len(coded) {
		return .Bytes_After
	}
	return .None
}
