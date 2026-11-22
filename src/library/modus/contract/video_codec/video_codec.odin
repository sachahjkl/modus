// Pure freestanding low-latency tile-delta + LZ4 screen video codec for
// remote display streaming (src/md/features/remote_display.md).
//
// Encodes keyframes and inter-frame temporal XOR deltas over 16x16 RGBA tiles
// with LZ4 compression, achieving high compression ratios on desktop frames
// while guaranteeing exact pixel-for-pixel lossless reconstruction.
package video_codec

import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/lz4"

CODEC_MAGIC :: u32(0x3156_444D) // "MDV1"
TILE_DIM :: 16
TILE_BYTES :: TILE_DIM * TILE_DIM * 4 // 1024 bytes per 16x16 RGBA tile
MAX_FRAME_WIDTH :: u16(4096)
MAX_FRAME_HEIGHT :: u16(4096)
FRAME_HEADER_BYTES :: 16

Frame_Kind :: enum u8 {
	Keyframe   = 1,
	Deltaframe = 2,
}

frame_kind_of_word :: proc "contextless" (word: u64) -> (k: Frame_Kind, ok: bool) {
	return enum_word.member_of_word(Frame_Kind, word)
}

Codec_Refusal :: enum u8 {
	None               = 0,
	Bad_Magic          = 1,
	Bad_Frame_Kind     = 2,
	Dimensions_Invalid = 3,
	Truncated          = 4,
	Buffer_Too_Small   = 5,
	Corrupt_Payload    = 6,
}

// encode_frame encodes current_rgba (width * height * 4 bytes) as either a
// Keyframe (when prev_rgba == nil) or a Deltaframe (skipping unchanged 16x16
// tiles and XOR-delta + LZ4 compressing changed tiles).
encode_frame :: proc "contextless" (
	width, height: u16,
	current_rgba: []u8,
	prev_rgba: []u8,
	out: []u8,
) -> (written: int, changed_tiles: int, refusal: Codec_Refusal) {
	if width == 0 || height == 0 || width > MAX_FRAME_WIDTH || height > MAX_FRAME_HEIGHT {
		return 0, 0, .Dimensions_Invalid
	}
	expected := int(u64(width) * u64(height) * 4)
	if len(current_rgba) != expected {
		return 0, 0, .Dimensions_Invalid
	}
	is_delta := prev_rgba != nil
	if is_delta && len(prev_rgba) != expected {
		return 0, 0, .Dimensions_Invalid
	}
	if len(out) < FRAME_HEADER_BYTES {
		return 0, 0, .Buffer_Too_Small
	}

	tiles_x := (int(width) + TILE_DIM - 1) / TILE_DIM
	tiles_y := (int(height) + TILE_DIM - 1) / TILE_DIM
	pos := FRAME_HEADER_BYTES

	tile_raw: [TILE_BYTES]u8
	lz_scratch: lz4.Hash_Table

	for ty in 0 ..< tiles_y {
		for tx in 0 ..< tiles_x {
			x0 := tx * TILE_DIM
			y0 := ty * TILE_DIM
			tw := min(TILE_DIM, int(width) - x0)
			th := min(TILE_DIM, int(height) - y0)
			raw_len := tw * th * 4

			changed := !is_delta
			dst_off := 0
			for row in 0 ..< th {
				src_off := ((y0 + row) * int(width) + x0) * 4
				for col in 0 ..< tw * 4 {
					cur_b := current_rgba[src_off + col]
					if is_delta {
						prev_b := prev_rgba[src_off + col]
						diff := cur_b ~ prev_b
						if diff != 0 {
							changed = true
						}
						tile_raw[dst_off + col] = diff
					} else {
						tile_raw[dst_off + col] = cur_b
					}
				}
				dst_off += tw * 4
			}
			if !changed {
				continue
			}

			// Tile header: tx(2), ty(2), compressed_len(2), flags(1: bit0=compressed), reserved(1) = 8 bytes
			if pos + 8 > len(out) {
				return 0, 0, .Buffer_Too_Small
			}
			comp_buf := out[pos + 8:]
			comp_n, comp_refusal := lz4.compress_block(tile_raw[:raw_len], comp_buf, &lz_scratch)
			tile_flags := u8(0)
			payload_n := raw_len
			if comp_refusal == .None && comp_n > 0 && comp_n < raw_len {
				tile_flags = 1
				payload_n = comp_n
			} else {
				if pos + 8 + raw_len > len(out) {
					return 0, 0, .Buffer_Too_Small
				}
				copy(out[pos + 8 : pos + 8 + raw_len], tile_raw[:raw_len])
			}
			byte_order.write_u16_little_endian(out, pos + 0, u16(tx))
			byte_order.write_u16_little_endian(out, pos + 2, u16(ty))
			byte_order.write_u16_little_endian(out, pos + 4, u16(payload_n))
			out[pos + 6] = tile_flags
			out[pos + 7] = 0
			pos += 8 + payload_n
			changed_tiles += 1
		}
	}

	byte_order.write_u32_little_endian(out, 0, CODEC_MAGIC)
	out[4] = u8(is_delta ? Frame_Kind.Deltaframe : Frame_Kind.Keyframe)
	out[5] = 0
	byte_order.write_u16_little_endian(out, 6, width)
	byte_order.write_u16_little_endian(out, 8, height)
	byte_order.write_u32_little_endian(out, 10, u32(changed_tiles))
	byte_order.write_u16_little_endian(out, 14, 0)
	return pos, changed_tiles, .None
}

// decode_frame applies an encoded MDV1 Keyframe or Deltaframe directly into
// framebuffer_rgba, validating every header, tile coordinate, and LZ4 payload.
decode_frame :: proc "contextless" (
	wire: []u8,
	width, height: u16,
	framebuffer_rgba: []u8,
) -> (decoded_tiles: int, refusal: Codec_Refusal) {
	if len(wire) < FRAME_HEADER_BYTES {
		return 0, .Truncated
	}
	if byte_order.read_u32_little_endian(wire, 0) != CODEC_MAGIC {
		return 0, .Bad_Magic
	}
	kind, kind_ok := frame_kind_of_word(u64(wire[4]))
	if !kind_ok || wire[5] != 0 || byte_order.read_u16_little_endian(wire, 14) != 0 {
		return 0, .Bad_Frame_Kind
	}
	w := byte_order.read_u16_little_endian(wire, 6)
	h := byte_order.read_u16_little_endian(wire, 8)
	if w != width || h != height || w == 0 || h == 0 || w > MAX_FRAME_WIDTH || h > MAX_FRAME_HEIGHT {
		return 0, .Dimensions_Invalid
	}
	expected := int(u64(w) * u64(h) * 4)
	if len(framebuffer_rgba) != expected {
		return 0, .Dimensions_Invalid
	}
	tile_count := int(byte_order.read_u32_little_endian(wire, 10))
	tiles_x := (int(w) + TILE_DIM - 1) / TILE_DIM
	tiles_y := (int(h) + TILE_DIM - 1) / TILE_DIM
	if tile_count > tiles_x * tiles_y {
		return 0, .Corrupt_Payload
	}

	pos := FRAME_HEADER_BYTES
	tile_raw: [TILE_BYTES]u8

	for _ in 0 ..< tile_count {
		if pos + 8 > len(wire) {
			return 0, .Truncated
		}
		tx := int(byte_order.read_u16_little_endian(wire, pos + 0))
		ty := int(byte_order.read_u16_little_endian(wire, pos + 2))
		plen := int(byte_order.read_u16_little_endian(wire, pos + 4))
		flags := wire[pos + 6]
		if wire[pos + 7] != 0 || tx >= tiles_x || ty >= tiles_y || flags > 1 || pos + 8 + plen > len(wire) {
			return 0, .Corrupt_Payload
		}
		x0 := tx * TILE_DIM
		y0 := ty * TILE_DIM
		tw := min(TILE_DIM, int(w) - x0)
		th := min(TILE_DIM, int(h) - y0)
		raw_len := tw * th * 4

		payload := wire[pos + 8 : pos + 8 + plen]
		pos += 8 + plen

		if flags == 1 {
			dec_n, dec_refusal := lz4.decompress_block(payload, tile_raw[:raw_len])
			if dec_refusal != .None || dec_n != raw_len {
				return 0, .Corrupt_Payload
			}
		} else {
			if plen != raw_len {
				return 0, .Corrupt_Payload
			}
			copy(tile_raw[:raw_len], payload)
		}

		src_off := 0
		for row in 0 ..< th {
			dst_off := ((y0 + row) * int(w) + x0) * 4
			for col in 0 ..< tw * 4 {
				if kind == .Deltaframe {
					framebuffer_rgba[dst_off + col] ~= tile_raw[src_off + col]
				} else {
					framebuffer_rgba[dst_off + col] = tile_raw[src_off + col]
				}
			}
			src_off += tw * 4
		}
		decoded_tiles += 1
	}
	if pos != len(wire) {
		return 0, .Corrupt_Payload
	}
	return decoded_tiles, .None
}
