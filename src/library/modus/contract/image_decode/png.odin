package image_decode

// Freestanding, zero-allocation PNG decoder supporting bit depth 8 and
// color types Grayscale (0), Truecolor (2), Indexed (3), Grayscale+Alpha (4),
// and Truecolor+Alpha (6), with full CRC-32 chunk validation, PLTE/tRNS,
// concatenated IDAT zlib + RFC 1951 DEFLATE inflate (stored, fixed Huffman,
// dynamic Huffman), Adler-32 checksum verification, and all 5 scanline filters.
//
// Zero writes to output_rgba on refusal: chunk CRCs and metadata are verified
// first; when scratch holds the full inflated stream, inflate + Adler-32 +
// filter/palette checks complete before output_rgba is touched; with compact
// streaming scratch, a validation pass verifies the entire DEFLATE stream,
// Adler-32, filter bytes, and palette indices before the write pass runs.

import "base:intrinsics"
import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Standard 8-byte PNG file signature.
PNG_SIGNATURE :: [8]u8{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}

// Supported PNG color types (bit depth 8).
Png_Color_Type :: enum u8 {
	Grayscale       = 0,
	Truecolor       = 2,
	Indexed         = 3,
	Grayscale_Alpha = 4,
	Truecolor_Alpha = 6,
}

// Closed set of PNG scanline filter types (RFC 2083, section 6).
Png_Filter :: enum u8 {
	None    = 0,
	Sub     = 1,
	Up      = 2,
	Average = 3,
	Paeth   = 4,
}

// Closed set of RFC 1951 DEFLATE block compression types.
Deflate_Block_Kind :: enum u8 {
	Stored          = 0,
	Fixed_Huffman   = 1,
	Dynamic_Huffman = 2,
}

// png_color_type_of_word converts a raw IHDR color-type byte at the border.
png_color_type_of_word :: proc "contextless" (word: u8) -> (color_type: Png_Color_Type, ok: bool) {
	return enum_word.member_of_word(Png_Color_Type, u64(word))
}

// png_filter_of_word converts a raw scanline filter byte at the border.
png_filter_of_word :: proc "contextless" (word: u8) -> (filter: Png_Filter, ok: bool) {
	return enum_word.member_of_word(Png_Filter, u64(word))
}

// deflate_block_kind_of_word converts a 2-bit BTYPE field at the border.
@(private)
deflate_block_kind_of_word :: proc "contextless" (word: u8) -> (kind: Deflate_Block_Kind, ok: bool) {
	return enum_word.member_of_word(Deflate_Block_Kind, u64(word))
}

// Maximum raw row byte count: MAX_IMAGE_WIDTH * 4 (16 KiB).
@(private)
PNG_MAX_ROW_BYTES :: MAX_IMAGE_WIDTH * RGBA_BYTES_PER_PIXEL

// DEFLATE sliding window size (32 KiB) and mask.
@(private)
DEFLATE_WINDOW_SIZE :: 32768
@(private)
DEFLATE_WINDOW_MASK :: DEFLATE_WINDOW_SIZE - 1

// Direct lookup bit width for DEFLATE canonical Huffman tables.
@(private)
DEFLATE_FAST_BITS :: 9
@(private)
DEFLATE_FAST_SIZE :: 1 << DEFLATE_FAST_BITS
@(private)
DEFLATE_FAST_MASK :: DEFLATE_FAST_SIZE - 1
@(private)
DEFLATE_MAX_BITS :: 15
@(private)
DEFLATE_MAX_SYMBOLS :: 288

// Canonical Huffman decoding table stored inside caller-provided scratch.
@(private)
Deflate_Huffman :: struct {
	fast:       [DEFLATE_FAST_SIZE]u16, // (length << 12) | symbol, or 0 for slow path / invalid.
	bl_count:   [DEFLATE_MAX_BITS + 1]u32,
	first_code: [DEFLATE_MAX_BITS + 1]u32,
	offset:     [DEFLATE_MAX_BITS + 1]u32,
	symbols:    [DEFLATE_MAX_SYMBOLS]u16,
	max_bits:   u32,
}

// Working memory placed in caller-provided scratch for PNG decoding (~88 KiB).
@(private)
Png_Workspace :: struct {
	window:        [DEFLATE_WINDOW_SIZE]u8,
	prev_row:      [PNG_MAX_ROW_BYTES]u8,
	curr_row:      [PNG_MAX_ROW_BYTES]u8,
	raw_row:       [1 + PNG_MAX_ROW_BYTES]u8,
	litlen_table:  Deflate_Huffman,
	dist_table:    Deflate_Huffman,
	codelen_table: Deflate_Huffman,
	palette:       [256][3]u8,
	palette_alpha: [256]u8,
}

// Minimum caller-provided scratch size for any PNG up to 4096x4096.
PNG_MINIMUM_SCRATCH_BYTES :: size_of(Png_Workspace) + 16

// IEEE 802.3 CRC-32 lookup table.
@(rodata, private)
PNG_CRC32_TABLE := [256]u32{
	0x00000000, 0x77073096, 0xEE0E612C, 0x990951BA, 0x076DC419, 0x706AF48F, 0xE963A535, 0x9E6495A3,
	0x0EDB8832, 0x79DCB8A4, 0xE0D5E91E, 0x97D2D988, 0x09B64C2B, 0x7EB17CBD, 0xE7B82D07, 0x90BF1D91,
	0x1DB71064, 0x6AB020F2, 0xF3B97148, 0x84BE41DE, 0x1ADAD47D, 0x6DDDE4EB, 0xF4D4B551, 0x83D385C7,
	0x136C9856, 0x646BA8C0, 0xFD62F97A, 0x8A65C9EC, 0x14015C4F, 0x63066CD9, 0xFA0F3D63, 0x8D080DF5,
	0x3B6E20C8, 0x4C69105E, 0xD56041E4, 0xA2677172, 0x3C03E4D1, 0x4B04D447, 0xD20D85FD, 0xA50AB56B,
	0x35B5A8FA, 0x42B2986C, 0xDBBBC9D6, 0xACBCF940, 0x32D86CE3, 0x45DF5C75, 0xDCD60DCF, 0xABD13D59,
	0x26D930AC, 0x51DE003A, 0xC8D75180, 0xBFD06116, 0x21B4F4B5, 0x56B3C423, 0xCFBA9599, 0xB8BDA50F,
	0x2802B89E, 0x5F058808, 0xC60CD9B2, 0xB10BE924, 0x2F6F7C87, 0x58684C11, 0xC1611DAB, 0xB6662D3D,
	0x76DC4190, 0x01DB7106, 0x98D220BC, 0xEFD5102A, 0x71B18589, 0x06B6B51F, 0x9FBFE4A5, 0xE8B8D433,
	0x7807C9A2, 0x0F00F934, 0x9609A88E, 0xE10E9818, 0x7F6A0DBB, 0x086D3D2D, 0x91646C97, 0xE6635C01,
	0x6B6B51F4, 0x1C6C6162, 0x856530D8, 0xF262004E, 0x6C0695ED, 0x1B01A57B, 0x8208F4C1, 0xF50FC457,
	0x65B0D9C6, 0x12B7E950, 0x8BBEB8EA, 0xFCB9887C, 0x62DD1DDF, 0x15DA2D49, 0x8CD37CF3, 0xFBD44C65,
	0x4DB26158, 0x3AB551CE, 0xA3BC0074, 0xD4BB30E2, 0x4ADFA541, 0x3DD895D7, 0xA4D1C46D, 0xD3D6F4FB,
	0x4369E96A, 0x346ED9FC, 0xAD678846, 0xDA60B8D0, 0x44042D73, 0x33031DE5, 0xAA0A4C5F, 0xDD0D7CC9,
	0x5005713C, 0x270241AA, 0xBE0B1010, 0xC90C2086, 0x5768B525, 0x206F85B3, 0xB966D409, 0xCE61E49F,
	0x5EDEF90E, 0x29D9C998, 0xB0D09822, 0xC7D7A8B4, 0x59B33D17, 0x2EB40D81, 0xB7BD5C3B, 0xC0BA6CAD,
	0xEDB88320, 0x9ABFB3B6, 0x03B6E20C, 0x74B1D29A, 0xEAD54739, 0x9DD277AF, 0x04DB2615, 0x73DC1683,
	0xE3630B12, 0x94643B84, 0x0D6D6A3E, 0x7A6A5AA8, 0xE40ECF0B, 0x9309FF9D, 0x0A00AE27, 0x7D079EB1,
	0xF00F9344, 0x8708A3D2, 0x1E01F268, 0x6906C2FE, 0xF762575D, 0x806567CB, 0x196C3671, 0x6E6B06E7,
	0xFED41B76, 0x89D32BE0, 0x10DA7A5A, 0x67DD4ACC, 0xF9B9DF6F, 0x8EBEEFF9, 0x17B7BE43, 0x60B08ED5,
	0xD6D6A3E8, 0xA1D1937E, 0x38D8C2C4, 0x4FDFF252, 0xD1BB67F1, 0xA6BC5767, 0x3FB506DD, 0x48B2364B,
	0xD80D2BDA, 0xAF0A1B4C, 0x36034AF6, 0x41047A60, 0xDF60EFC3, 0xA867DF55, 0x316E8EEF, 0x4669BE79,
	0xCB61B38C, 0xBC66831A, 0x256FD2A0, 0x5268E236, 0xCC0C7795, 0xBB0B4703, 0x220216B9, 0x5505262F,
	0xC5BA3BBE, 0xB2BD0B28, 0x2BB45A92, 0x5CB36A04, 0xC2D7FFA7, 0xB5D0CF31, 0x2CD99E8B, 0x5BDEAE1D,
	0x9B64C2B0, 0xEC63F226, 0x756AA39C, 0x026D930A, 0x9C0906A9, 0xEB0E363F, 0x72076785, 0x05005713,
	0x95BF4A82, 0xE2B87A14, 0x7BB12BAE, 0x0CB61B38, 0x92D28E9B, 0xE5D5BE0D, 0x7CDCEFB7, 0x0BDBDF21,
	0x86D3D2D4, 0xF1D4E242, 0x68DDB3F8, 0x1FDA836E, 0x81BE16CD, 0xF6B9265B, 0x6FB077E1, 0x18B74777,
	0x88085AE6, 0xFF0F6A70, 0x66063BCA, 0x11010B5C, 0x8F659EFF, 0xF862AE69, 0x616BFFD3, 0x166CCF45,
	0xA00AE278, 0xD70DD2EE, 0x4E048354, 0x3903B3C2, 0xA7672661, 0xD06016F7, 0x4969474D, 0x3E6E77DB,
	0xAED16A4A, 0xD9D65ADC, 0x40DF0B66, 0x37D83BF0, 0xA9BCAE53, 0xDEBB9EC5, 0x47B2CF7F, 0x30B5FFE9,
	0xBDBDF21C, 0xCABAC28A, 0x53B39330, 0x24B4A3A6, 0xBAD03605, 0xCDD70693, 0x54DE5729, 0x23D967BF,
	0xB3667A2E, 0xC4614AB8, 0x5D681B02, 0x2A6F2B94, 0xB40BBE37, 0xC30C8EA1, 0x5A05DF1B, 0x2D02EF8D,
}

// png_crc32 computes the IEEE 802.3 CRC-32 over chunk type and payload bytes.
png_crc32 :: proc "contextless" (bytes: []u8) -> u32 #no_bounds_check {
	crc := u32(0xFFFFFFFF)
	table := &PNG_CRC32_TABLE
	for b in bytes {
		crc = table[(crc ~ u32(b)) & 0xFF] ~ (crc >> 8)
	}
	return ~crc
}

// adler32_update updates a running RFC 1950 Adler-32 state with bytes.
@(private)
adler32_update :: proc "contextless" (s1_in, s2_in: u32, bytes: []u8) -> (s1, s2: u32) #no_bounds_check {
	MOD_ADLER :: 65521
	s1, s2 = s1_in, s2_in
	index := 0
	for index < len(bytes) {
		// Process up to 5552 bytes before modulo so s2 never overflows u32.
		chunk_end := min(index + 5552, len(bytes))
		for ; index < chunk_end; index += 1 {
			s1 += u32(bytes[index])
			s2 += s1
		}
		s1 %= MOD_ADLER
		s2 %= MOD_ADLER
	}
	return s1, s2
}

// adler32_byte updates an Adler-32 state by one byte.
@(private)
adler32_byte :: #force_inline proc "contextless" (s1_in, s2_in: u32, b: u8) -> (s1, s2: u32) {
	MOD_ADLER :: 65521
	s1 = s1_in + u32(b)
	if s1 >= MOD_ADLER {
		s1 -= MOD_ADLER
	}
	s2 = s2_in + s1
	if s2 >= MOD_ADLER {
		s2 -= MOD_ADLER
	}
	return s1, s2
}

// Parsed PNG header metadata validated across all chunks before pixel decode.
@(private)
Png_Metadata :: struct {
	width:            u32,
	height:           u32,
	color_type:       Png_Color_Type,
	bytes_per_pixel:  int,
	row_bytes:        int,
	output_bytes:     u64,
	expected_raw:     u64,
	first_idat_start: int,
	total_idat_bytes: u64,
	has_palette:      bool,
	palette_count:    int,
	has_trns:         bool,
	trns_gray:        u8,
	trns_r:           u8,
	trns_g:           u8,
	trns_b:           u8,
}

@(private)
png_bytes_per_pixel :: proc "contextless" (color_type: Png_Color_Type) -> int {
	switch color_type {
	case .Grayscale, .Indexed:
		return 1
	case .Grayscale_Alpha:
		return 2
	case .Truecolor:
		return 3
	case .Truecolor_Alpha:
		return 4
	}
	return 1
}

@(private)
chunk_type_equals :: #force_inline proc "contextless" (bytes: []u8, offset: int, a, b, c, d: u8) -> bool #no_bounds_check {
	return bytes[offset] == a && bytes[offset + 1] == b && bytes[offset + 2] == c && bytes[offset + 3] == d
}

// png_parse_chunks validates the signature, every chunk's bounds and CRC-32,
// IHDR, PLTE, tRNS, IDAT ordering, and IEND. When ws is non-nil, populates
// palette and palette_alpha inside ws.
@(private)
png_parse_chunks :: proc "contextless" (bytes: []u8, ws: ^Png_Workspace) -> (meta: Png_Metadata, refusal: Image_Decode_Refusal) {
	if len(bytes) == 0 {
		return {}, .Truncated
	}
	sig := PNG_SIGNATURE
	check_len := min(len(bytes), len(sig))
	for i in 0 ..< check_len {
		if bytes[i] != sig[i] {
			return {}, .Bad_Magic
		}
	}
	if len(bytes) < len(sig) {
		return {}, .Truncated
	}
	if ws != nil {
		for &a in ws.palette_alpha {
			a = 255
		}
	}

	offset := len(sig)
	seen_ihdr := false
	seen_plte := false
	seen_trns := false
	seen_idat := false
	ended_idat := false
	seen_iend := false

	for offset < len(bytes) {
		if len(bytes) - offset < 12 {
			return {}, .Truncated
		}
		chunk_len := byte_order.read_u32_big_endian(bytes, offset)
		if chunk_len > 0x7FFF_FFFF {
			return {}, .Corrupt_Stream
		}
		total_chunk := u64(12) + u64(chunk_len)
		if u64(offset) + total_chunk > u64(len(bytes)) {
			return {}, .Truncated
		}
		type_offset := offset + 4
		data_offset := offset + 8
		data_end := data_offset + int(chunk_len)
		expected_crc := byte_order.read_u32_big_endian(bytes, data_end)
		actual_crc := png_crc32(bytes[type_offset:data_end])
		if actual_crc != expected_crc {
			return {}, .Checksum_Mismatch
		}

		if chunk_type_equals(bytes, type_offset, 'I', 'H', 'D', 'R') {
			if seen_ihdr || offset != len(sig) || chunk_len != 13 {
				return {}, .Corrupt_Stream
			}
			width := byte_order.read_u32_big_endian(bytes, data_offset)
			height := byte_order.read_u32_big_endian(bytes, data_offset + 4)
			output_bytes, dim_refusal := validate_dimensions(width, height)
			if dim_refusal != .None {
				return {}, dim_refusal
			}
			bit_depth := bytes[data_offset + 8]
			color_word := bytes[data_offset + 9]
			compression := bytes[data_offset + 10]
			filter_method := bytes[data_offset + 11]
			interlace := bytes[data_offset + 12]

			color_type, color_ok := png_color_type_of_word(color_word)
			if !color_ok {
				return {}, .Corrupt_Stream
			}
			if bit_depth != 8 {
				return {}, .Unsupported_Variant
			}
			if compression != 0 || filter_method != 0 {
				return {}, .Corrupt_Stream
			}
			if interlace == 1 {
				return {}, .Unsupported_Variant
			}
			if interlace != 0 {
				return {}, .Corrupt_Stream
			}
			bpp := png_bytes_per_pixel(color_type)
			row_bytes := int(width) * bpp
			meta.width = width
			meta.height = height
			meta.color_type = color_type
			meta.bytes_per_pixel = bpp
			meta.row_bytes = row_bytes
			meta.output_bytes = output_bytes
			meta.expected_raw = u64(height) * u64(1 + row_bytes)
			seen_ihdr = true
		} else if !seen_ihdr {
			return {}, .Corrupt_Stream
		} else if chunk_type_equals(bytes, type_offset, 'P', 'L', 'T', 'E') {
			if seen_plte || seen_idat || seen_trns {
				return {}, .Corrupt_Stream
			}
			if chunk_len == 0 || chunk_len > 768 || chunk_len % 3 != 0 {
				return {}, .Corrupt_Stream
			}
			if meta.color_type == .Grayscale || meta.color_type == .Grayscale_Alpha {
				return {}, .Corrupt_Stream
			}
			count := int(chunk_len / 3)
			meta.has_palette = true
			meta.palette_count = count
			if ws != nil {
				for i in 0 ..< count {
					ws.palette[i][0] = bytes[data_offset + i * 3]
					ws.palette[i][1] = bytes[data_offset + i * 3 + 1]
					ws.palette[i][2] = bytes[data_offset + i * 3 + 2]
				}
			}
			seen_plte = true
		} else if chunk_type_equals(bytes, type_offset, 't', 'R', 'N', 'S') {
			if seen_trns || seen_idat {
				return {}, .Corrupt_Stream
			}
			switch meta.color_type {
			case .Indexed:
				if !seen_plte || int(chunk_len) > meta.palette_count {
					return {}, .Corrupt_Stream
				}
				if ws != nil {
					for i in 0 ..< int(chunk_len) {
						ws.palette_alpha[i] = bytes[data_offset + i]
					}
				}
			case .Grayscale:
				if chunk_len != 2 {
					return {}, .Corrupt_Stream
				}
				meta.trns_gray = u8(byte_order.read_u16_big_endian(bytes, data_offset) & 0xFF)
			case .Truecolor:
				if chunk_len != 6 {
					return {}, .Corrupt_Stream
				}
				meta.trns_r = u8(byte_order.read_u16_big_endian(bytes, data_offset) & 0xFF)
				meta.trns_g = u8(byte_order.read_u16_big_endian(bytes, data_offset + 2) & 0xFF)
				meta.trns_b = u8(byte_order.read_u16_big_endian(bytes, data_offset + 4) & 0xFF)
			case .Grayscale_Alpha, .Truecolor_Alpha:
				return {}, .Corrupt_Stream
			}
			meta.has_trns = true
			seen_trns = true
		} else if chunk_type_equals(bytes, type_offset, 'I', 'D', 'A', 'T') {
			if ended_idat {
				return {}, .Corrupt_Stream
			}
			if !seen_idat {
				meta.first_idat_start = offset
				seen_idat = true
			}
			meta.total_idat_bytes += u64(chunk_len)
		} else if chunk_type_equals(bytes, type_offset, 'I', 'E', 'N', 'D') {
			if chunk_len != 0 {
				return {}, .Corrupt_Stream
			}
			seen_iend = true
			break
		} else {
			if seen_idat {
				ended_idat = true
			}
			// Ancillary chunks have bit 5 set in their first byte (lowercase).
			// Unknown critical chunks must be refused.
			if bytes[type_offset] & 0x20 == 0 {
				return {}, .Unsupported_Variant
			}
		}

		offset = data_end + 4
	}

	if !seen_ihdr || !seen_iend {
		return {}, .Truncated
	}
	if !seen_idat || meta.total_idat_bytes < 6 {
		return {}, .Corrupt_Stream
	}
	if meta.color_type == .Indexed && !seen_plte {
		return {}, .Corrupt_Stream
	}
	return meta, .None
}

// png_probe validates all PNG chunks, CRCs, and IHDR bounds without decoding pixels.
png_probe :: proc "contextless" (bytes: []u8) -> (header: Image_Header, refusal: Image_Decode_Refusal) {
	meta, parse_refusal := png_parse_chunks(bytes, nil)
	if parse_refusal != .None {
		return {}, parse_refusal
	}
	return Image_Header{
		format                = .Png,
		width                 = meta.width,
		height                = meta.height,
		output_bytes          = meta.output_bytes,
		minimum_scratch_bytes = PNG_MINIMUM_SCRATCH_BYTES,
	}, .None
}

// ---------------------------------------------------------------------------
// Concatenated IDAT stream reader and RFC 1951 DEFLATE inflate
// ---------------------------------------------------------------------------

@(private)
Idat_Cursor :: struct {
	bytes:       []u8,
	chunk_start: int, // Start of current IDAT chunk header (length field).
	data_pos:    int, // Current byte position inside current IDAT data.
	data_end:    int, // End of current IDAT data.
	exhausted:   bool,
	bit_buffer:  u64,
	bit_count:   u32,
}

@(private)
idat_cursor_init :: proc "contextless" (bytes: []u8, first_idat_start: int) -> Idat_Cursor {
	cursor := Idat_Cursor{bytes = bytes, chunk_start = first_idat_start}
	idat_cursor_enter_chunk(&cursor)
	return cursor
}

@(private)
idat_cursor_enter_chunk :: proc "contextless" (cursor: ^Idat_Cursor) {
	for {
		if cursor.chunk_start + 12 > len(cursor.bytes) {
			cursor.exhausted = true
			return
		}
		if !chunk_type_equals(cursor.bytes, cursor.chunk_start + 4, 'I', 'D', 'A', 'T') {
			cursor.exhausted = true
			return
		}
		chunk_len := int(byte_order.read_u32_big_endian(cursor.bytes, cursor.chunk_start))
		cursor.data_pos = cursor.chunk_start + 8
		cursor.data_end = cursor.data_pos + chunk_len
		if chunk_len > 0 {
			return
		}
		// Skip empty IDAT chunks cleanly.
		cursor.chunk_start = cursor.data_end + 4
	}
}

@(private)
idat_next_byte :: #force_inline proc "contextless" (cursor: ^Idat_Cursor) -> (b: u8, ok: bool) #no_bounds_check {
	if cursor.exhausted {
		return 0, false
	}
	if cursor.data_pos >= cursor.data_end {
		cursor.chunk_start = cursor.data_end + 4
		idat_cursor_enter_chunk(cursor)
		if cursor.exhausted {
			return 0, false
		}
	}
	b = cursor.bytes[cursor.data_pos]
	cursor.data_pos += 1
	return b, true
}

@(private)
idat_refill_bits :: #force_inline proc "contextless" (cursor: ^Idat_Cursor, needed: u32) {
	for cursor.bit_count < needed {
		b, ok := idat_next_byte(cursor)
		if !ok {
			return
		}
		cursor.bit_buffer |= u64(b) << cursor.bit_count
		cursor.bit_count += 8
	}
}

@(private)
idat_read_bits :: #force_inline proc "contextless" (cursor: ^Idat_Cursor, count: u32) -> (value: u32, ok: bool) {
	if count == 0 {
		return 0, true
	}
	idat_refill_bits(cursor, count)
	if cursor.bit_count < count {
		return 0, false
	}
	mask := (u64(1) << count) - 1
	value = u32(cursor.bit_buffer & mask)
	cursor.bit_buffer >>= count
	cursor.bit_count -= count
	return value, true
}

@(private)
idat_align_to_byte :: #force_inline proc "contextless" (cursor: ^Idat_Cursor) {
	drop := cursor.bit_count & 7
	cursor.bit_buffer >>= drop
	cursor.bit_count -= drop
}

@(private)
idat_read_aligned_byte :: #force_inline proc "contextless" (cursor: ^Idat_Cursor) -> (b: u8, ok: bool) {
	if cursor.bit_count >= 8 {
		b = u8(cursor.bit_buffer & 0xFF)
		cursor.bit_buffer >>= 8
		cursor.bit_count -= 8
		return b, true
	}
	return idat_next_byte(cursor)
}

@(private)
reverse_bits :: #force_inline proc "contextless" (code: u32, length: u32) -> u32 {
	result := u32(0)
	v := code
	for _ in 0 ..< length {
		result = (result << 1) | (v & 1)
		v >>= 1
	}
	return result
}

// deflate_huffman_build builds a canonical RFC 1951 Huffman table from
// symbol bit lengths. Rejects oversubscribed trees.
@(private)
deflate_huffman_build :: proc "contextless" (table: ^Deflate_Huffman, lengths: []u8) -> bool #no_bounds_check {
	table.fast = {}
	table.bl_count = {}
	table.first_code = {}
	table.offset = {}
	table.max_bits = 0

	max_bits := u32(0)
	for length in lengths {
		if length > DEFLATE_MAX_BITS {
			return false
		}
		if length > 0 {
			table.bl_count[length] += 1
			if u32(length) > max_bits {
				max_bits = u32(length)
			}
		}
	}
	table.max_bits = max_bits
	if max_bits == 0 {
		return true
	}

	// Verify Kraft inequality: tree must not be oversubscribed.
	left := i32(1)
	for bits in u32(1) ..= max_bits {
		left <<= 1
		left -= i32(table.bl_count[bits])
		if left < 0 {
			return false
		}
	}

	code := u32(0)
	running_offset := u32(0)
	next_code: [DEFLATE_MAX_BITS + 1]u32
	next_offset: [DEFLATE_MAX_BITS + 1]u32
	for bits in u32(1) ..= DEFLATE_MAX_BITS {
		code = (code + table.bl_count[bits - 1]) << 1
		table.first_code[bits] = code
		next_code[bits] = code
		table.offset[bits] = running_offset
		next_offset[bits] = running_offset
		running_offset += table.bl_count[bits]
	}

	for length, sym in lengths {
		if length == 0 {
			continue
		}
		bits := u32(length)
		sym_code := next_code[bits]
		next_code[bits] += 1
		table.symbols[next_offset[bits]] = u16(sym)
		next_offset[bits] += 1

		if bits <= DEFLATE_FAST_BITS {
			rev := reverse_bits(sym_code, bits)
			entry := u16((bits << 12) | u32(sym))
			step := u32(1) << bits
			for slot := rev; slot < DEFLATE_FAST_SIZE; slot += step {
				table.fast[slot] = entry
			}
		}
	}
	return true
}

// deflate_huffman_decode reads one Huffman-coded symbol from cursor.
@(private)
deflate_huffman_decode :: #force_inline proc "contextless" (cursor: ^Idat_Cursor, table: ^Deflate_Huffman) -> (symbol: u16, ok: bool) #no_bounds_check {
	if table.max_bits == 0 {
		return 0, false
	}
	idat_refill_bits(cursor, DEFLATE_MAX_BITS)
	if cursor.bit_count == 0 {
		return 0, false
	}
	fast_entry := table.fast[cursor.bit_buffer & DEFLATE_FAST_MASK]
	if fast_entry != 0 {
		bits := u32(fast_entry >> 12)
		if cursor.bit_count >= bits {
			cursor.bit_buffer >>= bits
			cursor.bit_count -= bits
			return fast_entry & 0x0FFF, true
		}
		return 0, false
	}
	// Canonical slow path for 10..15-bit codes (or invalid bit sequences).
	code := u32(0)
	for bits in u32(1) ..= table.max_bits {
		if cursor.bit_count < bits {
			return 0, false
		}
		bit := u32((cursor.bit_buffer >> (bits - 1)) & 1)
		code = (code << 1) | bit
		count := table.bl_count[bits]
		first := table.first_code[bits]
		if count > 0 && code >= first && code - first < count {
			cursor.bit_buffer >>= bits
			cursor.bit_count -= bits
			return table.symbols[table.offset[bits] + (code - first)], true
		}
	}
	return 0, false
}

@(rodata, private)
DEFLATE_LENGTH_BASE := [29]u16{
	3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
	35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
}

@(rodata, private)
DEFLATE_LENGTH_EXTRA := [29]u8{
	0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
	3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
}

@(rodata, private)
DEFLATE_DIST_BASE := [30]u16{
	1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
	257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
}

@(rodata, private)
DEFLATE_DIST_EXTRA := [30]u8{
	0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
	7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
}

@(rodata, private)
DEFLATE_CODELEN_ORDER := [19]u8{
	16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
}

@(private)
deflate_build_fixed_tables :: proc "contextless" (ws: ^Png_Workspace) -> bool {
	lit_lengths: [288]u8
	for i in 0 ..= 143 {
		lit_lengths[i] = 8
	}
	for i in 144 ..= 255 {
		lit_lengths[i] = 9
	}
	for i in 256 ..= 279 {
		lit_lengths[i] = 7
	}
	for i in 280 ..= 287 {
		lit_lengths[i] = 8
	}
	dist_lengths: [32]u8
	for &d in dist_lengths {
		d = 5
	}
	return deflate_huffman_build(&ws.litlen_table, lit_lengths[:]) && deflate_huffman_build(&ws.dist_table, dist_lengths[:])
}

@(private)
deflate_read_dynamic_tables :: proc "contextless" (cursor: ^Idat_Cursor, ws: ^Png_Workspace) -> Image_Decode_Refusal #no_bounds_check {
	hlit_bits, ok1 := idat_read_bits(cursor, 5)
	hdist_bits, ok2 := idat_read_bits(cursor, 5)
	hclen_bits, ok3 := idat_read_bits(cursor, 4)
	if !ok1 || !ok2 || !ok3 {
		return .Truncated
	}
	hlit := int(hlit_bits) + 257
	hdist := int(hdist_bits) + 1
	hclen := int(hclen_bits) + 4
	if hlit > 286 || hdist > 30 {
		return .Corrupt_Stream
	}

	codelen_order := DEFLATE_CODELEN_ORDER
	codelen_lengths: [19]u8
	for i in 0 ..< hclen {
		v, ok := idat_read_bits(cursor, 3)
		if !ok {
			return .Truncated
		}
		codelen_lengths[codelen_order[i]] = u8(v)
	}
	if !deflate_huffman_build(&ws.codelen_table, codelen_lengths[:]) {
		return .Corrupt_Stream
	}

	total_codes := hlit + hdist
	all_lengths: [286 + 30]u8
	index := 0
	for index < total_codes {
		sym, ok := deflate_huffman_decode(cursor, &ws.codelen_table)
		if !ok {
			return .Corrupt_Stream
		}
		if sym < 16 {
			all_lengths[index] = u8(sym)
			index += 1
		} else if sym == 16 {
			if index == 0 {
				return .Corrupt_Stream
			}
			extra, extra_ok := idat_read_bits(cursor, 2)
			if !extra_ok {
				return .Truncated
			}
			repeat := int(extra) + 3
			if index + repeat > total_codes {
				return .Corrupt_Stream
			}
			prev := all_lengths[index - 1]
			for _ in 0 ..< repeat {
				all_lengths[index] = prev
				index += 1
			}
		} else if sym == 17 {
			extra, extra_ok := idat_read_bits(cursor, 3)
			if !extra_ok {
				return .Truncated
			}
			repeat := int(extra) + 3
			if index + repeat > total_codes {
				return .Corrupt_Stream
			}
			for _ in 0 ..< repeat {
				all_lengths[index] = 0
				index += 1
			}
		} else if sym == 18 {
			extra, extra_ok := idat_read_bits(cursor, 7)
			if !extra_ok {
				return .Truncated
			}
			repeat := int(extra) + 11
			if index + repeat > total_codes {
				return .Corrupt_Stream
			}
			for _ in 0 ..< repeat {
				all_lengths[index] = 0
				index += 1
			}
		} else {
			return .Corrupt_Stream
		}
	}

	// End-of-block symbol 256 must have a non-zero code length.
	if all_lengths[256] == 0 {
		return .Corrupt_Stream
	}
	if !deflate_huffman_build(&ws.litlen_table, all_lengths[:hlit]) {
		return .Corrupt_Stream
	}
	if !deflate_huffman_build(&ws.dist_table, all_lengths[hlit:total_codes]) {
		return .Corrupt_Stream
	}
	return .None
}

// ---------------------------------------------------------------------------
// PNG scanline filters (scalar reference + SSE2 dispatch)
// ---------------------------------------------------------------------------

// paeth_predictor implements the exact RFC 2083 Paeth predictor.
@(private)
paeth_predictor :: #force_inline proc "contextless" (a, b, c: u8) -> u8 {
	ia, ib, ic := i32(a), i32(b), i32(c)
	p := ia + ib - ic
	pa := abs(p - ia)
	pb := abs(p - ib)
	pc := abs(p - ic)
	if pa <= pb && pa <= pc {
		return a
	}
	if pb <= pc {
		return b
	}
	return c
}

// png_unfilter_row applies a PNG scanline filter in the target's vector form.
png_unfilter_row :: #force_inline proc "contextless" (filter: Png_Filter, dst: []u8, raw: []u8, prev: []u8, bytes_per_pixel: int) {
	when ODIN_ARCH == .amd64 {
		png_unfilter_row_simd(filter, dst, raw, prev, bytes_per_pixel)
	} else {
		png_unfilter_row_scalar(filter, dst, raw, prev, bytes_per_pixel)
	}
}

// png_unfilter_row_scalar is the scalar reference implementation of all 5
// PNG scanline filters (None, Sub, Up, Average, Paeth).
png_unfilter_row_scalar :: proc "contextless" (filter: Png_Filter, dst: []u8, raw: []u8, prev: []u8, bytes_per_pixel: int) #no_bounds_check {
	n := len(raw)
	if n == 0 {
		return
	}
	bpp := bytes_per_pixel
	switch filter {
	case .None:
		intrinsics.mem_copy_non_overlapping(raw_data(dst), raw_data(raw), n)
	case .Sub:
		limit := min(bpp, n)
		for i in 0 ..< limit {
			dst[i] = raw[i]
		}
		for i in limit ..< n {
			dst[i] = raw[i] + dst[i - bpp]
		}
	case .Up:
		for i in 0 ..< n {
			dst[i] = raw[i] + prev[i]
		}
	case .Average:
		limit := min(bpp, n)
		for i in 0 ..< limit {
			dst[i] = raw[i] + (prev[i] >> 1)
		}
		for i in limit ..< n {
			dst[i] = raw[i] + u8((u16(dst[i - bpp]) + u16(prev[i])) >> 1)
		}
	case .Paeth:
		limit := min(bpp, n)
		for i in 0 ..< limit {
			dst[i] = raw[i] + paeth_predictor(0, prev[i], 0)
		}
		for i in limit ..< n {
			dst[i] = raw[i] + paeth_predictor(dst[i - bpp], prev[i], prev[i - bpp])
		}
	}
}

// png_expand_row_to_rgba expands one unfiltered scanline into 4-byte RGBA pixels.
// When emit_rgba is false, validates indexed palette entries without writing output.
@(private)
png_expand_row_to_rgba :: proc "contextless" (meta: ^Png_Metadata, ws: ^Png_Workspace, row: []u8, dst_rgba: []u8, emit_rgba: bool) -> Image_Decode_Refusal #no_bounds_check {
	width := int(meta.width)
	switch meta.color_type {
	case .Grayscale:
		if !emit_rgba {
			return .None
		}
		for x in 0 ..< width {
			g := row[x]
			a := u8(255)
			if meta.has_trns && g == meta.trns_gray {
				a = 0
			}
			out := x * 4
			dst_rgba[out] = g
			dst_rgba[out + 1] = g
			dst_rgba[out + 2] = g
			dst_rgba[out + 3] = a
		}
	case .Truecolor:
		if !emit_rgba {
			return .None
		}
		for x in 0 ..< width {
			src := x * 3
			r, g, b := row[src], row[src + 1], row[src + 2]
			a := u8(255)
			if meta.has_trns && r == meta.trns_r && g == meta.trns_g && b == meta.trns_b {
				a = 0
			}
			out := x * 4
			dst_rgba[out] = r
			dst_rgba[out + 1] = g
			dst_rgba[out + 2] = b
			dst_rgba[out + 3] = a
		}
	case .Indexed:
		for x in 0 ..< width {
			idx := int(row[x])
			if idx >= meta.palette_count {
				return .Corrupt_Stream
			}
			if emit_rgba {
				out := x * 4
				dst_rgba[out] = ws.palette[idx][0]
				dst_rgba[out + 1] = ws.palette[idx][1]
				dst_rgba[out + 2] = ws.palette[idx][2]
				dst_rgba[out + 3] = ws.palette_alpha[idx]
			}
		}
	case .Grayscale_Alpha:
		if !emit_rgba {
			return .None
		}
		for x in 0 ..< width {
			src := x * 2
			g, a := row[src], row[src + 1]
			out := x * 4
			dst_rgba[out] = g
			dst_rgba[out + 1] = g
			dst_rgba[out + 2] = g
			dst_rgba[out + 3] = a
		}
	case .Truecolor_Alpha:
		if emit_rgba {
			intrinsics.mem_copy_non_overlapping(raw_data(dst_rgba), raw_data(row), width * 4)
		}
	}
	return .None
}

// State for streaming DEFLATE output directly into PNG scanline processing
// (or into a flat scratch buffer when scratch has room for single-pass decode).
@(private)
Png_Inflate_Sink :: struct {
	meta:        ^Png_Metadata,
	ws:          ^Png_Workspace,
	output_rgba: []u8,
	flat_raw:    []u8, // Non-empty when inflating into scratch in single-pass mode.
	emit_rgba:   bool,
	total_out:   u64,
	window_pos:  int,
	adler_s1:    u32,
	adler_s2:    u32,
	row_index:   int,
	row_pos:     int,
	stride_raw:  int, // 1 + row_bytes
}

@(private)
png_sink_emit_byte :: #force_inline proc "contextless" (sink: ^Png_Inflate_Sink, b: u8) -> Image_Decode_Refusal #no_bounds_check {
	if sink.total_out >= sink.meta.expected_raw {
		return .Decompression_Bomb
	}
	sink.ws.window[sink.window_pos] = b
	sink.window_pos = (sink.window_pos + 1) & DEFLATE_WINDOW_MASK
	sink.adler_s1, sink.adler_s2 = adler32_byte(sink.adler_s1, sink.adler_s2, b)

	if len(sink.flat_raw) > 0 {
		sink.flat_raw[sink.total_out] = b
		sink.total_out += 1
		return .None
	}

	sink.total_out += 1
	sink.ws.raw_row[sink.row_pos] = b
	sink.row_pos += 1
	if sink.row_pos == sink.stride_raw {
		sink.row_pos = 0
		refusal := png_finish_streamed_row(sink)
		if refusal != .None {
			return refusal
		}
	}
	return .None
}

@(private)
png_finish_streamed_row :: proc "contextless" (sink: ^Png_Inflate_Sink) -> Image_Decode_Refusal #no_bounds_check {
	filter, filter_ok := png_filter_of_word(sink.ws.raw_row[0])
	if !filter_ok {
		return .Corrupt_Stream
	}
	row_bytes := sink.meta.row_bytes
	if sink.row_index == 0 {
		// Row 0 has an all-zero previous scanline.
		for i in 0 ..< row_bytes {
			sink.ws.prev_row[i] = 0
		}
	}
	png_unfilter_row(filter, sink.ws.curr_row[:row_bytes], sink.ws.raw_row[1:1 + row_bytes], sink.ws.prev_row[:row_bytes], sink.meta.bytes_per_pixel)
	dst_slice: []u8
	if sink.emit_rgba {
		row_out_bytes := int(sink.meta.width) * RGBA_BYTES_PER_PIXEL
		dst_offset := sink.row_index * row_out_bytes
		dst_slice = sink.output_rgba[dst_offset:dst_offset + row_out_bytes]
	}
	refusal := png_expand_row_to_rgba(sink.meta, sink.ws, sink.ws.curr_row[:row_bytes], dst_slice, sink.emit_rgba)
	if refusal != .None {
		return refusal
	}
	intrinsics.mem_copy_non_overlapping(raw_data(sink.ws.prev_row[:]), raw_data(sink.ws.curr_row[:]), row_bytes)
	sink.row_index += 1
	return .None
}

// png_inflate_idat parses the zlib header, inflates all DEFLATE blocks from
// the concatenated IDAT stream, and verifies the trailing Adler-32 checksum.
@(private)
png_inflate_idat :: proc "contextless" (bytes: []u8, sink: ^Png_Inflate_Sink) -> Image_Decode_Refusal #no_bounds_check {
	cursor := idat_cursor_init(bytes, sink.meta.first_idat_start)
	cmf, ok_cmf := idat_next_byte(&cursor)
	flg, ok_flg := idat_next_byte(&cursor)
	if !ok_cmf || !ok_flg {
		return .Truncated
	}
	if (cmf & 0x0F) != 8 || (cmf >> 4) > 7 {
		return .Unsupported_Variant
	}
	if (u16(cmf) * 256 + u16(flg)) % 31 != 0 {
		return .Corrupt_Stream
	}
	if (flg & 0x20) != 0 {
		// Preset dictionary (FDICT) is not used in PNG.
		return .Unsupported_Variant
	}

	sink.total_out = 0
	sink.window_pos = 0
	sink.adler_s1 = 1
	sink.adler_s2 = 0
	sink.row_index = 0
	sink.row_pos = 0
	sink.stride_raw = 1 + sink.meta.row_bytes

	len_base := DEFLATE_LENGTH_BASE
	len_extra := DEFLATE_LENGTH_EXTRA
	dist_base := DEFLATE_DIST_BASE
	dist_extra := DEFLATE_DIST_EXTRA

	for {
		bfinal, ok_final := idat_read_bits(&cursor, 1)
		btype_word, ok_type := idat_read_bits(&cursor, 2)
		if !ok_final || !ok_type {
			return .Truncated
		}
		block_kind, kind_ok := deflate_block_kind_of_word(u8(btype_word))
		if !kind_ok {
			return .Corrupt_Stream
		}

		switch block_kind {
		case .Stored:
			idat_align_to_byte(&cursor)
			l0, ok0 := idat_read_aligned_byte(&cursor)
			l1, ok1 := idat_read_aligned_byte(&cursor)
			n0, ok2 := idat_read_aligned_byte(&cursor)
			n1, ok3 := idat_read_aligned_byte(&cursor)
			if !ok0 || !ok1 || !ok2 || !ok3 {
				return .Truncated
			}
			stored_len := u16(l0) | (u16(l1) << 8)
			stored_nlen := u16(n0) | (u16(n1) << 8)
			if stored_len != ~stored_nlen {
				return .Corrupt_Stream
			}
			if sink.total_out + u64(stored_len) > sink.meta.expected_raw {
				return .Decompression_Bomb
			}
			for _ in 0 ..< int(stored_len) {
				b, ok_b := idat_read_aligned_byte(&cursor)
				if !ok_b {
					return .Truncated
				}
				refusal := png_sink_emit_byte(sink, b)
				if refusal != .None {
					return refusal
				}
			}

		case .Fixed_Huffman, .Dynamic_Huffman:
			if block_kind == .Fixed_Huffman {
				if !deflate_build_fixed_tables(sink.ws) {
					return .Corrupt_Stream
				}
			} else {
				dyn_refusal := deflate_read_dynamic_tables(&cursor, sink.ws)
				if dyn_refusal != .None {
					return dyn_refusal
				}
			}
			for {
				sym, sym_ok := deflate_huffman_decode(&cursor, &sink.ws.litlen_table)
				if !sym_ok {
					return .Corrupt_Stream
				}
				if sym < 256 {
					refusal := png_sink_emit_byte(sink, u8(sym))
					if refusal != .None {
						return refusal
					}
				} else if sym == 256 {
					break
				} else if sym <= 285 {
					len_idx := int(sym) - 257
					extra_bits, ok_le := idat_read_bits(&cursor, u32(len_extra[len_idx]))
					if !ok_le {
						return .Truncated
					}
					match_len := int(len_base[len_idx]) + int(extra_bits)
					dist_sym, dist_ok := deflate_huffman_decode(&cursor, &sink.ws.dist_table)
					if !dist_ok || dist_sym >= 30 {
						return .Corrupt_Stream
					}
					dist_extra_bits, ok_de := idat_read_bits(&cursor, u32(dist_extra[dist_sym]))
					if !ok_de {
						return .Truncated
					}
					distance := int(dist_base[dist_sym]) + int(dist_extra_bits)
					if distance <= 0 || u64(distance) > sink.total_out || distance > DEFLATE_WINDOW_SIZE {
						return .Corrupt_Stream
					}
					if sink.total_out + u64(match_len) > sink.meta.expected_raw {
						return .Decompression_Bomb
					}
					for _ in 0 ..< match_len {
						src_pos := (sink.window_pos - distance) & DEFLATE_WINDOW_MASK
						refusal := png_sink_emit_byte(sink, sink.ws.window[src_pos])
						if refusal != .None {
							return refusal
						}
					}
				} else {
					return .Corrupt_Stream
				}
			}
		}

		if bfinal == 1 {
			break
		}
	}

	if sink.total_out != sink.meta.expected_raw {
		return .Corrupt_Stream
	}

	idat_align_to_byte(&cursor)
	a0, ok_a0 := idat_read_aligned_byte(&cursor)
	a1, ok_a1 := idat_read_aligned_byte(&cursor)
	a2, ok_a2 := idat_read_aligned_byte(&cursor)
	a3, ok_a3 := idat_read_aligned_byte(&cursor)
	if !ok_a0 || !ok_a1 || !ok_a2 || !ok_a3 {
		return .Truncated
	}
	expected_adler := (u32(a0) << 24) | (u32(a1) << 16) | (u32(a2) << 8) | u32(a3)
	actual_adler := (sink.adler_s2 << 16) | sink.adler_s1
	if actual_adler != expected_adler {
		return .Checksum_Mismatch
	}
	return .None
}

// png_decode_rgba decodes a PNG image into caller-provided output_rgba using
// caller-provided scratch memory. Leaves output_rgba untouched on any refusal.
png_decode_rgba :: proc "contextless" (bytes: []u8, output_rgba: []u8, scratch: []u8) -> (header: Image_Header, refusal: Image_Decode_Refusal) #no_bounds_check {
	if len(scratch) < PNG_MINIMUM_SCRATCH_BYTES {
		// Still report header/format errors before Scratch_Too_Small when probing fails.
		_, probe_refusal := png_probe(bytes)
		if probe_refusal != .None {
			return {}, probe_refusal
		}
		return {}, .Scratch_Too_Small
	}
	// Align workspace pointer to 8 bytes inside scratch.
	base_addr := uintptr(raw_data(scratch))
	align_pad := int((8 - (base_addr & 7)) & 7)
	if align_pad + size_of(Png_Workspace) > len(scratch) {
		return {}, .Scratch_Too_Small
	}
	ws := (^Png_Workspace)(raw_data(scratch[align_pad:]))

	meta, parse_refusal := png_parse_chunks(bytes, ws)
	if parse_refusal != .None {
		return {}, parse_refusal
	}
	if u64(len(output_rgba)) < meta.output_bytes {
		return {}, .Output_Buffer_Too_Small
	}

	tail_offset := align_pad + size_of(Png_Workspace)
	tail_bytes := len(scratch) - tail_offset

	if u64(tail_bytes) >= meta.expected_raw {
		// Single-pass mode: inflate into scratch tail, verify Adler-32 and
		// every filter/palette index, then unfilter + expand into output_rgba.
		flat := scratch[tail_offset:tail_offset + int(meta.expected_raw)]
		sink := Png_Inflate_Sink{
			meta     = &meta,
			ws       = ws,
			flat_raw = flat,
		}
		inflate_refusal := png_inflate_idat(bytes, &sink)
		if inflate_refusal != .None {
			return {}, inflate_refusal
		}
		stride_raw := 1 + meta.row_bytes
		// Validate all filter bytes and (for indexed images) all palette indices
		// before touching a single byte of output_rgba.
		for row_idx in 0 ..< int(meta.height) {
			row_start := row_idx * stride_raw
			filter, filter_ok := png_filter_of_word(flat[row_start])
			if !filter_ok {
				return {}, .Corrupt_Stream
			}
			if meta.color_type == .Indexed {
				if row_idx == 0 {
					for i in 0 ..< meta.row_bytes {
						ws.prev_row[i] = 0
					}
				}
				png_unfilter_row(filter, ws.curr_row[:meta.row_bytes], flat[row_start + 1:row_start + stride_raw], ws.prev_row[:meta.row_bytes], meta.bytes_per_pixel)
				check_refusal := png_expand_row_to_rgba(&meta, ws, ws.curr_row[:meta.row_bytes], nil, false)
				if check_refusal != .None {
					return {}, check_refusal
				}
				intrinsics.mem_copy_non_overlapping(raw_data(ws.prev_row[:]), raw_data(ws.curr_row[:]), meta.row_bytes)
			}
		}
		row_out_bytes := int(meta.width) * RGBA_BYTES_PER_PIXEL
		for row_idx in 0 ..< int(meta.height) {
			row_start := row_idx * stride_raw
			filter, _ := png_filter_of_word(flat[row_start])
			if row_idx == 0 {
				for i in 0 ..< meta.row_bytes {
					ws.prev_row[i] = 0
				}
			}
			png_unfilter_row(filter, ws.curr_row[:meta.row_bytes], flat[row_start + 1:row_start + stride_raw], ws.prev_row[:meta.row_bytes], meta.bytes_per_pixel)
			dst_offset := row_idx * row_out_bytes
			_ = png_expand_row_to_rgba(&meta, ws, ws.curr_row[:meta.row_bytes], output_rgba[dst_offset:dst_offset + row_out_bytes], true)
			intrinsics.mem_copy_non_overlapping(raw_data(ws.prev_row[:]), raw_data(ws.curr_row[:]), meta.row_bytes)
		}
	} else {
		// Compact streaming scratch mode: Pass 1 validates DEFLATE, Adler-32,
		// every filter byte, and every palette index with zero pixel writes.
		verify_sink := Png_Inflate_Sink{
			meta      = &meta,
			ws        = ws,
			emit_rgba = false,
		}
		verify_refusal := png_inflate_idat(bytes, &verify_sink)
		if verify_refusal != .None {
			return {}, verify_refusal
		}
		// Pass 2 decodes and writes validated pixels into output_rgba.
		write_sink := Png_Inflate_Sink{
			meta        = &meta,
			ws          = ws,
			output_rgba = output_rgba,
			emit_rgba   = true,
		}
		write_refusal := png_inflate_idat(bytes, &write_sink)
		if write_refusal != .None {
			return {}, write_refusal
		}
	}

	return Image_Header{
		format                = .Png,
		width                 = meta.width,
		height                = meta.height,
		output_bytes          = meta.output_bytes,
		minimum_scratch_bytes = PNG_MINIMUM_SCRATCH_BYTES,
	}, .None
}
