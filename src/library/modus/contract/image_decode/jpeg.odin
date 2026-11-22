package image_decode

// Freestanding, zero-allocation baseline sequential DCT JPEG decoder
// (ITU-T T.81): validates SOI, DQT (8-bit quantization tables), DHT (DC/AC
// canonical Huffman tables), DRI (restart intervals), SOF0 (baseline 8-bit
// grayscale or YCbCr 4:4:4, 4:2:2, 4:2:0), SOS (byte-stuffed entropy scan),
// and EOI.
//
// Zero writes to output_rgba on refusal: Pass 1 validates every marker and
// every MCU's Huffman codes, coefficient bounds, restart markers, and EOI
// without writing pixels; Pass 2 runs dequantization, separable integer 2D
// IDCT (SSE2 on amd64), and YCbCr to RGBA conversion (SSE2 on amd64).

import "base:intrinsics"
import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Closed set of JPEG markers handled directly by the baseline decoder.
Jpeg_Marker :: enum u8 {
	Sof0 = 0xC0,
	Dht  = 0xC4,
	Soi  = 0xD8,
	Eoi  = 0xD9,
	Sos  = 0xDA,
	Dqt  = 0xDB,
	Dri  = 0xDD,
	Com  = 0xFE,
}

// Closed set of supported JPEG chroma subsampling layouts.
Jpeg_Chroma_Subsampling :: enum u8 {
	Grayscale       = 1,
	Subsampling_444 = 2,
	Subsampling_422 = 3,
	Subsampling_420 = 4,
}

// jpeg_marker_of_word converts a marker code byte at the border.
jpeg_marker_of_word :: proc "contextless" (word: u8) -> (marker: Jpeg_Marker, ok: bool) {
	return enum_word.member_of_word(Jpeg_Marker, u64(word))
}

@(private)
JPEG_HUFF_FAST_BITS :: 8
@(private)
JPEG_HUFF_FAST_SIZE :: 1 << JPEG_HUFF_FAST_BITS
@(private)
JPEG_HUFF_MAX_BITS :: 16

// Canonical MSB-first JPEG Huffman table.
@(private)
Jpeg_Huffman :: struct {
	fast:       [JPEG_HUFF_FAST_SIZE]u16, // (bits << 8) | symbol, or 0 for slow path / invalid.
	bl_count:   [JPEG_HUFF_MAX_BITS + 1]u32,
	first_code: [JPEG_HUFF_MAX_BITS + 1]u32,
	offset:     [JPEG_HUFF_MAX_BITS + 1]u32,
	symbols:    [256]u8,
	max_bits:   u32,
}

// Per-component frame and scan descriptors.
@(private)
Jpeg_Component :: struct {
	id:          u8,
	h_samp:      u8,
	v_samp:      u8,
	qt_id:       u8,
	dc_table_id: u8,
	ac_table_id: u8,
}

// Working memory placed inside caller-provided scratch (~9 KiB).
@(private)
Jpeg_Workspace :: struct {
	qt:               [4][64]u8,
	qt_present:       [4]bool,
	dc_huff:          [4]Jpeg_Huffman,
	dc_present:       [4]bool,
	ac_huff:          [4]Jpeg_Huffman,
	ac_present:       [4]bool,
	components:       [3]Jpeg_Component,
	component_count:  int,
	subsampling:      Jpeg_Chroma_Subsampling,
	h_max:            int,
	v_max:            int,
	width:            u32,
	height:           u32,
	output_bytes:     u64,
	restart_interval: u16,
	scan_data_offset: int,
	y_blocks:         [4][64]u8,
	cb_block:         [64]u8,
	cr_block:         [64]u8,
	cb_row:           [16]u8,
	cr_row:           [16]u8,
	rgba_row:         [16 * RGBA_BYTES_PER_PIXEL]u8,
}

// Minimum caller-provided scratch size for baseline JPEG decoding.
JPEG_MINIMUM_SCRATCH_BYTES :: size_of(Jpeg_Workspace) + 16

// Standard zigzag to natural 8x8 block index mapping.
@(rodata, private)
JPEG_ZIGZAG := [64]u8{
	0,  1,  8, 16,  9,  2,  3, 10,
	17, 24, 32, 25, 18, 11,  4,  5,
	12, 19, 26, 33, 40, 48, 41, 34,
	27, 20, 13,  6,  7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36,
	29, 22, 15, 23, 30, 37, 44, 51,
	58, 59, 52, 45, 38, 31, 39, 46,
	53, 60, 61, 54, 47, 55, 62, 63,
}

// Fixed-point 12-bit Loeffler / IJG integer 1D IDCT constants (scale = 4096).
@(private)
IDCT_F_0_541196100 :: i32(2217)
@(private)
IDCT_F_M1_847759065 :: i32(-7568)
@(private)
IDCT_F_0_765366865 :: i32(3135)
@(private)
IDCT_F_1_175875602 :: i32(4816)
@(private)
IDCT_F_0_298631336 :: i32(1223)
@(private)
IDCT_F_2_053119869 :: i32(8410)
@(private)
IDCT_F_3_072711026 :: i32(12586)
@(private)
IDCT_F_1_501321110 :: i32(6149)
@(private)
IDCT_F_M0_899976223 :: i32(-3686)
@(private)
IDCT_F_M2_562915447 :: i32(-10498)
@(private)
IDCT_F_M1_961570560 :: i32(-8035)
@(private)
IDCT_F_M0_390180644 :: i32(-1598)

// Clamping limits guaranteeing zero 32-bit overflow in both row and column IDCT passes.
@(private)
IDCT_INPUT_LIMIT :: i32(2048)
@(private)
IDCT_ROW_OUT_LIMIT :: i32(16383)

// Fixed-point 12-bit BT.601 full-range YCbCr -> RGB constants (scale = 4096).
@(private)
YCBCR_CR_TO_R :: i32(5743)
@(private)
YCBCR_CB_TO_G :: i32(-1410)
@(private)
YCBCR_CR_TO_G :: i32(-2925)
@(private)
YCBCR_CB_TO_B :: i32(7258)

// ---------------------------------------------------------------------------
// Separable integer 2D IDCT (scalar reference + SSE2 dispatch)
// ---------------------------------------------------------------------------

// jpeg_idct_8x8 transforms an 8x8 block of dequantized DCT coefficients into
// 8x8 unsigned 8-bit sample values (level-shifted by +128 and clamped to 0..255).
jpeg_idct_8x8 :: #force_inline proc "contextless" (coeffs: ^[64]i32, out_pixels: ^[64]u8) {
	when ODIN_ARCH == .amd64 {
		jpeg_idct_8x8_simd(coeffs, out_pixels)
	} else {
		jpeg_idct_8x8_scalar(coeffs, out_pixels)
	}
}

// jpeg_idct_8x8_scalar is the scalar reference form of jpeg_idct_8x8.
jpeg_idct_8x8_scalar :: proc "contextless" (coeffs: ^[64]i32, out_pixels: ^[64]u8) #no_bounds_check {
	temp: [64]i32
	// Row pass
	for row in 0 ..< 8 {
		base := row * 8
		s0 := clamp(coeffs[base + 0], -IDCT_INPUT_LIMIT, IDCT_INPUT_LIMIT - 1)
		s1 := clamp(coeffs[base + 1], -IDCT_INPUT_LIMIT, IDCT_INPUT_LIMIT - 1)
		s2 := clamp(coeffs[base + 2], -IDCT_INPUT_LIMIT, IDCT_INPUT_LIMIT - 1)
		s3 := clamp(coeffs[base + 3], -IDCT_INPUT_LIMIT, IDCT_INPUT_LIMIT - 1)
		s4 := clamp(coeffs[base + 4], -IDCT_INPUT_LIMIT, IDCT_INPUT_LIMIT - 1)
		s5 := clamp(coeffs[base + 5], -IDCT_INPUT_LIMIT, IDCT_INPUT_LIMIT - 1)
		s6 := clamp(coeffs[base + 6], -IDCT_INPUT_LIMIT, IDCT_INPUT_LIMIT - 1)
		s7 := clamp(coeffs[base + 7], -IDCT_INPUT_LIMIT, IDCT_INPUT_LIMIT - 1)

		p1 := (s2 + s6) * IDCT_F_0_541196100
		t2 := p1 + s6 * IDCT_F_M1_847759065
		t3 := p1 + s2 * IDCT_F_0_765366865
		t0 := (s0 + s4) << 12
		t1 := (s0 - s4) << 12
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
		p5 := (p3 + p4) * IDCT_F_1_175875602
		o0 = o0 * IDCT_F_0_298631336
		o1 = o1 * IDCT_F_2_053119869
		o2 = o2 * IDCT_F_3_072711026
		o3 = o3 * IDCT_F_1_501321110
		q1 = p5 + q1 * IDCT_F_M0_899976223
		q2 = p5 + q2 * IDCT_F_M2_562915447
		p3 = p3 * IDCT_F_M1_961570560
		p4 = p4 * IDCT_F_M0_390180644
		o3 += q1 + p4
		o2 += q2 + p3
		o1 += q2 + p4
		o0 += q1 + p3

		temp[base + 0] = clamp((x0 + o3 + 512) >> 10, -IDCT_ROW_OUT_LIMIT - 1, IDCT_ROW_OUT_LIMIT)
		temp[base + 7] = clamp((x0 - o3 + 512) >> 10, -IDCT_ROW_OUT_LIMIT - 1, IDCT_ROW_OUT_LIMIT)
		temp[base + 1] = clamp((x1 + o2 + 512) >> 10, -IDCT_ROW_OUT_LIMIT - 1, IDCT_ROW_OUT_LIMIT)
		temp[base + 6] = clamp((x1 - o2 + 512) >> 10, -IDCT_ROW_OUT_LIMIT - 1, IDCT_ROW_OUT_LIMIT)
		temp[base + 2] = clamp((x2 + o1 + 512) >> 10, -IDCT_ROW_OUT_LIMIT - 1, IDCT_ROW_OUT_LIMIT)
		temp[base + 5] = clamp((x2 - o1 + 512) >> 10, -IDCT_ROW_OUT_LIMIT - 1, IDCT_ROW_OUT_LIMIT)
		temp[base + 3] = clamp((x3 + o0 + 512) >> 10, -IDCT_ROW_OUT_LIMIT - 1, IDCT_ROW_OUT_LIMIT)
		temp[base + 4] = clamp((x3 - o0 + 512) >> 10, -IDCT_ROW_OUT_LIMIT - 1, IDCT_ROW_OUT_LIMIT)
	}

	// Column pass
	BIAS :: i32(65536 + (128 << 17))
	for col in 0 ..< 8 {
		s0 := temp[col + 0]
		s1 := temp[col + 8]
		s2 := temp[col + 16]
		s3 := temp[col + 24]
		s4 := temp[col + 32]
		s5 := temp[col + 40]
		s6 := temp[col + 48]
		s7 := temp[col + 56]

		p1 := (s2 + s6) * IDCT_F_0_541196100
		t2 := p1 + s6 * IDCT_F_M1_847759065
		t3 := p1 + s2 * IDCT_F_0_765366865
		t0 := (s0 + s4) << 12
		t1 := (s0 - s4) << 12
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
		p5 := (p3 + p4) * IDCT_F_1_175875602
		o0 = o0 * IDCT_F_0_298631336
		o1 = o1 * IDCT_F_2_053119869
		o2 = o2 * IDCT_F_3_072711026
		o3 = o3 * IDCT_F_1_501321110
		q1 = p5 + q1 * IDCT_F_M0_899976223
		q2 = p5 + q2 * IDCT_F_M2_562915447
		p3 = p3 * IDCT_F_M1_961570560
		p4 = p4 * IDCT_F_M0_390180644
		o3 += q1 + p4
		o2 += q2 + p3
		o1 += q2 + p4
		o0 += q1 + p3

		out_pixels[col + 0]  = u8(clamp((x0 + o3 + BIAS) >> 17, 0, 255))
		out_pixels[col + 56] = u8(clamp((x0 - o3 + BIAS) >> 17, 0, 255))
		out_pixels[col + 8]  = u8(clamp((x1 + o2 + BIAS) >> 17, 0, 255))
		out_pixels[col + 48] = u8(clamp((x1 - o2 + BIAS) >> 17, 0, 255))
		out_pixels[col + 16] = u8(clamp((x2 + o1 + BIAS) >> 17, 0, 255))
		out_pixels[col + 40] = u8(clamp((x2 - o1 + BIAS) >> 17, 0, 255))
		out_pixels[col + 24] = u8(clamp((x3 + o0 + BIAS) >> 17, 0, 255))
		out_pixels[col + 32] = u8(clamp((x3 - o0 + BIAS) >> 17, 0, 255))
	}
}

// ---------------------------------------------------------------------------
// YCbCr -> RGBA color conversion (scalar reference + SSE2 dispatch)
// ---------------------------------------------------------------------------

// jpeg_ycbcr_to_rgba_row converts count pixels from separate Y, Cb, Cr planes
// into interleaved 4-byte RGBA pixels (with alpha 255).
jpeg_ycbcr_to_rgba_row :: #force_inline proc "contextless" (y, cb, cr: [^]u8, out_rgba: [^]u8, count: int) {
	when ODIN_ARCH == .amd64 {
		jpeg_ycbcr_to_rgba_row_simd(y, cb, cr, out_rgba, count)
	} else {
		jpeg_ycbcr_to_rgba_row_scalar(y, cb, cr, out_rgba, count)
	}
}

// jpeg_ycbcr_to_rgba_row_scalar is the scalar reference form of
// jpeg_ycbcr_to_rgba_row.
jpeg_ycbcr_to_rgba_row_scalar :: proc "contextless" (y, cb, cr: [^]u8, out_rgba: [^]u8, count: int) #no_bounds_check {
	if count <= 0 {
		return
	}
	for i in 0 ..< count {
		yv := i32(y[i]) << 12
		cbv := i32(cb[i]) - 128
		crv := i32(cr[i]) - 128
		r := clamp((yv + crv * YCBCR_CR_TO_R + 2048) >> 12, 0, 255)
		g := clamp((yv + cbv * YCBCR_CB_TO_G + crv * YCBCR_CR_TO_G + 2048) >> 12, 0, 255)
		b := clamp((yv + cbv * YCBCR_CB_TO_B + 2048) >> 12, 0, 255)
		out := i * 4
		out_rgba[out] = u8(r)
		out_rgba[out + 1] = u8(g)
		out_rgba[out + 2] = u8(b)
		out_rgba[out + 3] = 255
	}
}

// ---------------------------------------------------------------------------
// JPEG Huffman tables, marker parsing, and entropy decoding
// ---------------------------------------------------------------------------

@(private)
jpeg_huffman_build :: proc "contextless" (table: ^Jpeg_Huffman, counts: [16]u8, symbols: []u8) -> bool #no_bounds_check {
	table.fast = {}
	table.bl_count = {}
	table.first_code = {}
	table.offset = {}
	table.max_bits = 0

	total := 0
	for i in 0 ..< 16 {
		c := int(counts[i])
		table.bl_count[i + 1] = u32(c)
		total += c
		if c > 0 {
			table.max_bits = u32(i + 1)
		}
	}
	if total != len(symbols) || total > 256 {
		return false
	}
	if table.max_bits == 0 {
		return false
	}

	// Verify Kraft inequality so oversubscribed DHT tables are refused.
	left := i32(1)
	for bits in u32(1) ..= table.max_bits {
		left <<= 1
		left -= i32(table.bl_count[bits])
		if left < 0 {
			return false
		}
	}

	code := u32(0)
	running := u32(0)
	for bits in u32(1) ..= JPEG_HUFF_MAX_BITS {
		code = (code + table.bl_count[bits - 1]) << 1
		table.first_code[bits] = code
		table.offset[bits] = running
		running += table.bl_count[bits]
	}

	for i in 0 ..< total {
		table.symbols[i] = symbols[i]
	}

	for bits in u32(1) ..= JPEG_HUFF_FAST_BITS {
		count := table.bl_count[bits]
		base_code := table.first_code[bits]
		base_offset := table.offset[bits]
		shift := JPEG_HUFF_FAST_BITS - bits
		fill := u32(1) << shift
		for k in u32(0) ..< count {
			sym := table.symbols[base_offset + k]
			entry := u16((bits << 8) | u32(sym))
			prefix := (base_code + k) << shift
			for f in u32(0) ..< fill {
				table.fast[prefix + f] = entry
			}
		}
	}
	return true
}

@(private)
jpeg_is_unsupported_sof :: proc "contextless" (code: u8) -> bool {
	// SOF1..SOF3, SOF5..SOF7, SOF9..SOF11, SOF13..SOF15, and DAC (0xCC).
	if code >= 0xC1 && code <= 0xCF && code != u8(Jpeg_Marker.Dht) && code != 0xC8 {
		return true
	}
	return false
}

// jpeg_parse_headers parses SOI through SOS (inclusive), populating ws when non-nil.
@(private)
jpeg_parse_headers :: proc "contextless" (bytes: []u8, ws: ^Jpeg_Workspace) -> (header: Image_Header, refusal: Image_Decode_Refusal) #no_bounds_check {
	if len(bytes) == 0 {
		return {}, .Truncated
	}
	if bytes[0] != 0xFF {
		return {}, .Bad_Magic
	}
	if len(bytes) < 2 {
		return {}, .Truncated
	}
	if bytes[1] != u8(Jpeg_Marker.Soi) {
		return {}, .Bad_Magic
	}

	if ws != nil {
		ws^ = {}
	}

	offset := 2
	seen_sof0 := false
	seen_sos := false
	local_width: u32
	local_height: u32
	local_output_bytes: u64
	local_comp_count := 0
	local_comps: [3]Jpeg_Component
	local_qt_present: [4]bool
	local_dc_present: [4]bool
	local_ac_present: [4]bool

	for offset < len(bytes) {
		if bytes[offset] != 0xFF {
			return {}, .Corrupt_Stream
		}
		// Skip fill 0xFF bytes per ITU-T T.81 B.1.1.2.
		for offset < len(bytes) && bytes[offset] == 0xFF {
			offset += 1
		}
		if offset >= len(bytes) {
			return {}, .Truncated
		}
		code := bytes[offset]
		offset += 1

		if code == 0x00 {
			return {}, .Corrupt_Stream
		}
		if jpeg_is_unsupported_sof(code) {
			return {}, .Unsupported_Variant
		}
		// APP0..APP15 segments are metadata: verify length and skip cleanly.
		if code >= 0xE0 && code <= 0xEF {
			if offset + 2 > len(bytes) {
				return {}, .Truncated
			}
			seg_len := int(byte_order.read_u16_big_endian(bytes, offset))
			if seg_len < 2 || offset + seg_len > len(bytes) {
				return {}, .Truncated
			}
			offset += seg_len
			continue
		}

		marker, marker_ok := jpeg_marker_of_word(code)
		if !marker_ok {
			// Skip unknown length-prefixed non-SOF marker segments safely only for TEM/DNL? No: refuse unknown markers.
			return {}, .Unsupported_Variant
		}

		switch marker {
		case .Soi:
			return {}, .Corrupt_Stream
		case .Eoi:
			return {}, .Corrupt_Stream
		case .Com:
			if offset + 2 > len(bytes) {
				return {}, .Truncated
			}
			seg_len := int(byte_order.read_u16_big_endian(bytes, offset))
			if seg_len < 2 || offset + seg_len > len(bytes) {
				return {}, .Truncated
			}
			offset += seg_len

		case .Dri:
			if offset + 2 > len(bytes) {
				return {}, .Truncated
			}
			seg_len := int(byte_order.read_u16_big_endian(bytes, offset))
			if seg_len != 4 {
				return {}, .Corrupt_Stream
			}
			if offset + seg_len > len(bytes) {
				return {}, .Truncated
			}
			if ws != nil {
				ws.restart_interval = byte_order.read_u16_big_endian(bytes, offset + 2)
			}
			offset += seg_len

		case .Dqt:
			if offset + 2 > len(bytes) {
				return {}, .Truncated
			}
			seg_len := int(byte_order.read_u16_big_endian(bytes, offset))
			if seg_len < 2 || offset + seg_len > len(bytes) {
				return {}, .Truncated
			}
			pos := offset + 2
			end := offset + seg_len
			if pos == end {
				return {}, .Corrupt_Stream
			}
			for pos < end {
				pq_tq := bytes[pos]
				pos += 1
				precision := pq_tq >> 4
				table_id := pq_tq & 0x0F
				if precision == 1 {
					return {}, .Unsupported_Variant
				}
				if precision != 0 || table_id >= 4 {
					return {}, .Corrupt_Stream
				}
				if pos + 64 > end {
					return {}, .Corrupt_Stream
				}
				local_qt_present[table_id] = true
				if ws != nil {
					ws.qt_present[table_id] = true
					for k in 0 ..< 64 {
						ws.qt[table_id][k] = bytes[pos + k]
					}
				}
				pos += 64
			}
			offset = end

		case .Dht:
			if offset + 2 > len(bytes) {
				return {}, .Truncated
			}
			seg_len := int(byte_order.read_u16_big_endian(bytes, offset))
			if seg_len < 2 || offset + seg_len > len(bytes) {
				return {}, .Truncated
			}
			pos := offset + 2
			end := offset + seg_len
			if pos == end {
				return {}, .Corrupt_Stream
			}
			for pos < end {
				tc_th := bytes[pos]
				pos += 1
				table_class := tc_th >> 4
				table_id := tc_th & 0x0F
				if table_class > 1 || table_id >= 4 {
					return {}, .Corrupt_Stream
				}
				if pos + 16 > end {
					return {}, .Corrupt_Stream
				}
				counts: [16]u8
				sym_total := 0
				for i in 0 ..< 16 {
					counts[i] = bytes[pos + i]
					sym_total += int(counts[i])
				}
				pos += 16
				if sym_total > 256 || pos + sym_total > end {
					return {}, .Corrupt_Stream
				}
				if table_class == 0 {
					local_dc_present[table_id] = true
					if ws != nil {
						if !jpeg_huffman_build(&ws.dc_huff[table_id], counts, bytes[pos:pos + sym_total]) {
							return {}, .Corrupt_Stream
						}
						ws.dc_present[table_id] = true
					}
				} else {
					local_ac_present[table_id] = true
					if ws != nil {
						if !jpeg_huffman_build(&ws.ac_huff[table_id], counts, bytes[pos:pos + sym_total]) {
							return {}, .Corrupt_Stream
						}
						ws.ac_present[table_id] = true
					}
				}
				pos += sym_total
			}
			offset = end

		case .Sof0:
			if seen_sof0 {
				return {}, .Corrupt_Stream
			}
			if offset + 2 > len(bytes) {
				return {}, .Truncated
			}
			seg_len := int(byte_order.read_u16_big_endian(bytes, offset))
			if seg_len < 8 || offset + seg_len > len(bytes) {
				return {}, .Truncated
			}
			pos := offset + 2
			precision := bytes[pos]
			if precision != 8 {
				return {}, .Unsupported_Variant
			}
			height := u32(byte_order.read_u16_big_endian(bytes, pos + 1))
			width := u32(byte_order.read_u16_big_endian(bytes, pos + 3))
			out_bytes, dim_refusal := validate_dimensions(width, height)
			if dim_refusal != .None {
				return {}, dim_refusal
			}
			nf := int(bytes[pos + 5])
			if seg_len != 8 + 3 * nf {
				return {}, .Corrupt_Stream
			}
			if nf != 1 && nf != 3 {
				return {}, .Unsupported_Variant
			}
			pos += 6
			for c in 0 ..< nf {
				cid := bytes[pos]
				hv := bytes[pos + 1]
				qt_id := bytes[pos + 2]
				pos += 3
				h_s := hv >> 4
				v_s := hv & 0x0F
				if h_s == 0 || v_s == 0 || h_s > 4 || v_s > 4 || qt_id >= 4 {
					return {}, .Corrupt_Stream
				}
				for prev in 0 ..< c {
					if local_comps[prev].id == cid {
						return {}, .Corrupt_Stream
					}
				}
				local_comps[c] = Jpeg_Component{id = cid, h_samp = h_s, v_samp = v_s, qt_id = qt_id}
			}

			subsampling: Jpeg_Chroma_Subsampling
			h_max, v_max := 1, 1
			if nf == 1 {
				subsampling = .Grayscale
				local_comps[0].h_samp = 1
				local_comps[0].v_samp = 1
			} else {
				y := local_comps[0]
				cb := local_comps[1]
				cr := local_comps[2]
				if cb.h_samp != 1 || cb.v_samp != 1 || cr.h_samp != 1 || cr.v_samp != 1 {
					return {}, .Unsupported_Variant
				}
				if y.h_samp == 1 && y.v_samp == 1 {
					subsampling = .Subsampling_444
					h_max, v_max = 1, 1
				} else if y.h_samp == 2 && y.v_samp == 1 {
					subsampling = .Subsampling_422
					h_max, v_max = 2, 1
				} else if y.h_samp == 2 && y.v_samp == 2 {
					subsampling = .Subsampling_420
					h_max, v_max = 2, 2
				} else {
					return {}, .Unsupported_Variant
				}
			}

			local_width = width
			local_height = height
			local_output_bytes = out_bytes
			local_comp_count = nf
			seen_sof0 = true
			if ws != nil {
				ws.width = width
				ws.height = height
				ws.output_bytes = out_bytes
				ws.component_count = nf
				ws.subsampling = subsampling
				ws.h_max = h_max
				ws.v_max = v_max
				ws.components = local_comps
			}
			offset += seg_len

		case .Sos:
			if !seen_sof0 {
				return {}, .Corrupt_Stream
			}
			if offset + 2 > len(bytes) {
				return {}, .Truncated
			}
			seg_len := int(byte_order.read_u16_big_endian(bytes, offset))
			if seg_len < 6 || offset + seg_len > len(bytes) {
				return {}, .Truncated
			}
			pos := offset + 2
			ns := int(bytes[pos])
			pos += 1
			if ns != local_comp_count || seg_len != 6 + 2 * ns {
				return {}, .Unsupported_Variant
			}
			matched: [3]bool
			for _ in 0 ..< ns {
				cs := bytes[pos]
				td_ta := bytes[pos + 1]
				pos += 2
				dc_id := td_ta >> 4
				ac_id := td_ta & 0x0F
				if dc_id >= 4 || ac_id >= 4 {
					return {}, .Corrupt_Stream
				}
				if !local_dc_present[dc_id] || !local_ac_present[ac_id] {
					return {}, .Corrupt_Stream
				}
				found := -1
				for c in 0 ..< local_comp_count {
					if local_comps[c].id == cs {
						found = c
						break
					}
				}
				if found < 0 || matched[found] {
					return {}, .Corrupt_Stream
				}
				matched[found] = true
				if !local_qt_present[local_comps[found].qt_id] {
					return {}, .Corrupt_Stream
				}
				if ws != nil {
					ws.components[found].dc_table_id = dc_id
					ws.components[found].ac_table_id = ac_id
				}
			}
			ss := bytes[pos]
			se := bytes[pos + 1]
			ah_al := bytes[pos + 2]
			if ss != 0 || se != 63 || ah_al != 0 {
				return {}, .Unsupported_Variant
			}
			seen_sos = true
			if ws != nil {
				ws.scan_data_offset = offset + seg_len
			}
			break
		}

		if seen_sos {
			break
		}
	}

	if !seen_sof0 || !seen_sos {
		return {}, .Truncated
	}
	return Image_Header{
		format                = .Jpeg,
		width                 = local_width,
		height                = local_height,
		output_bytes          = local_output_bytes,
		minimum_scratch_bytes = JPEG_MINIMUM_SCRATCH_BYTES,
	}, .None
}

// jpeg_probe validates baseline JPEG headers and dimensions without decoding pixels.
jpeg_probe :: proc "contextless" (bytes: []u8) -> (header: Image_Header, refusal: Image_Decode_Refusal) {
	return jpeg_parse_headers(bytes, nil)
}

// MSB-first byte-stuffed entropy bit reader for JPEG scans.
@(private)
Jpeg_Bit_Reader :: struct {
	bytes:      []u8,
	pos:        int,
	bit_buffer: u64,
	bit_count:  u32,
	hit_marker: bool,
	truncated:  bool,
}

@(private)
jpeg_refill_bits :: #force_inline proc "contextless" (br: ^Jpeg_Bit_Reader, needed: u32) #no_bounds_check {
	for br.bit_count < needed && !br.hit_marker && !br.truncated {
		if br.pos >= len(br.bytes) {
			br.truncated = true
			return
		}
		b := br.bytes[br.pos]
		if b == 0xFF {
			if br.pos + 1 >= len(br.bytes) {
				br.truncated = true
				return
			}
			next := br.bytes[br.pos + 1]
			if next == 0x00 {
				br.pos += 2
				br.bit_buffer = (br.bit_buffer << 8) | 0xFF
				br.bit_count += 8
			} else {
				br.hit_marker = true
				return
			}
		} else {
			br.pos += 1
			br.bit_buffer = (br.bit_buffer << 8) | u64(b)
			br.bit_count += 8
		}
	}
}

@(private)
jpeg_read_bits :: #force_inline proc "contextless" (br: ^Jpeg_Bit_Reader, count: u32) -> (value: u32, refusal: Image_Decode_Refusal) {
	if count == 0 {
		return 0, .None
	}
	jpeg_refill_bits(br, count)
	if br.bit_count < count {
		return 0, br.truncated ? .Truncated : .Corrupt_Stream
	}
	mask := (u64(1) << count) - 1
	value = u32((br.bit_buffer >> (br.bit_count - count)) & mask)
	br.bit_count -= count
	return value, .None
}

@(private)
jpeg_extend :: #force_inline proc "contextless" (bits: u32, count: u32) -> i32 {
	if count == 0 {
		return 0
	}
	half := u32(1) << (count - 1)
	if bits < half {
		return i32(bits) - i32((u32(1) << count) - 1)
	}
	return i32(bits)
}

@(private)
jpeg_decode_huffman :: #force_inline proc "contextless" (br: ^Jpeg_Bit_Reader, table: ^Jpeg_Huffman) -> (symbol: u8, refusal: Image_Decode_Refusal) #no_bounds_check {
	jpeg_refill_bits(br, JPEG_HUFF_MAX_BITS)
	if br.bit_count == 0 {
		return 0, br.truncated ? .Truncated : .Corrupt_Stream
	}
	if br.bit_count >= JPEG_HUFF_FAST_BITS {
		top8 := (br.bit_buffer >> (br.bit_count - JPEG_HUFF_FAST_BITS)) & 0xFF
		entry := table.fast[top8]
		if entry != 0 {
			bits := u32(entry >> 8)
			br.bit_count -= bits
			return u8(entry & 0xFF), .None
		}
	}
	code := u32(0)
	for bits in u32(1) ..= table.max_bits {
		if br.bit_count < bits {
			return 0, br.truncated ? .Truncated : .Corrupt_Stream
		}
		bit := u32((br.bit_buffer >> (br.bit_count - bits)) & 1)
		code = (code << 1) | bit
		count := table.bl_count[bits]
		first := table.first_code[bits]
		if count > 0 && code >= first && code - first < count {
			br.bit_count -= bits
			return table.symbols[table.offset[bits] + (code - first)], .None
		}
	}
	return 0, .Corrupt_Stream
}

@(private)
jpeg_decode_block :: proc "contextless" (
	br: ^Jpeg_Bit_Reader,
	dc_table: ^Jpeg_Huffman,
	ac_table: ^Jpeg_Huffman,
	qt: ^[64]u8,
	dc_pred: ^i32,
	coeffs: ^[64]i32,
	emit_coeffs: bool,
) -> Image_Decode_Refusal #no_bounds_check {
	if emit_coeffs {
		coeffs^ = {}
	}
	dc_cat, dc_refusal := jpeg_decode_huffman(br, dc_table)
	if dc_refusal != .None {
		return dc_refusal
	}
	if dc_cat > 11 {
		return .Corrupt_Stream
	}
	dc_bits, dc_bits_refusal := jpeg_read_bits(br, u32(dc_cat))
	if dc_bits_refusal != .None {
		return dc_bits_refusal
	}
	dc_pred^ += jpeg_extend(dc_bits, u32(dc_cat))
	if emit_coeffs {
		coeffs[0] = dc_pred^ * i32(qt[0])
	}

	zigzag := JPEG_ZIGZAG
	k := 1
	for k < 64 {
		rs, ac_refusal := jpeg_decode_huffman(br, ac_table)
		if ac_refusal != .None {
			return ac_refusal
		}
		if rs == 0x00 {
			// End of block.
			break
		}
		if rs == 0xF0 {
			// Zero run length (16 zeros).
			k += 16
			if k >= 64 {
				return .Corrupt_Stream
			}
			continue
		}
		run := int(rs >> 4)
		size := u32(rs & 0x0F)
		if size == 0 || size > 10 {
			return .Corrupt_Stream
		}
		k += run
		if k >= 64 {
			return .Corrupt_Stream
		}
		ac_bits, ac_bits_refusal := jpeg_read_bits(br, size)
		if ac_bits_refusal != .None {
			return ac_bits_refusal
		}
		if emit_coeffs {
			coeffs[zigzag[k]] = jpeg_extend(ac_bits, size) * i32(qt[k])
		}
		k += 1
	}
	return .None
}

@(private)
jpeg_expect_marker :: proc "contextless" (br: ^Jpeg_Bit_Reader, expected_code: u8) -> Image_Decode_Refusal #no_bounds_check {
	// Discard intra-byte padding bits.
	br.bit_count &= ~u32(7)
	if br.bit_count > 0 {
		return .Corrupt_Stream
	}
	br.bit_buffer = 0
	br.hit_marker = false
	if br.pos >= len(br.bytes) {
		return .Truncated
	}
	if br.bytes[br.pos] != 0xFF {
		return .Corrupt_Stream
	}
	for br.pos < len(br.bytes) && br.bytes[br.pos] == 0xFF {
		br.pos += 1
	}
	if br.pos >= len(br.bytes) {
		return .Truncated
	}
	code := br.bytes[br.pos]
	br.pos += 1
	if code != expected_code {
		return .Corrupt_Stream
	}
	return .None
}

// jpeg_write_mcu writes one decoded MCU (8x8, 16x8, or 16x16) clipped to
// image width/height into output_rgba.
@(private)
jpeg_write_mcu :: proc "contextless" (ws: ^Jpeg_Workspace, mcu_x, mcu_y: int, output_rgba: []u8) #no_bounds_check {
	img_w := int(ws.width)
	img_h := int(ws.height)
	mcu_w := ws.h_max * 8
	mcu_h := ws.v_max * 8
	base_x := mcu_x * mcu_w
	base_y := mcu_y * mcu_h
	copy_w := min(mcu_w, img_w - base_x)
	copy_h := min(mcu_h, img_h - base_y)
	if copy_w <= 0 || copy_h <= 0 {
		return
	}

	switch ws.subsampling {
	case .Grayscale:
		for py in 0 ..< copy_h {
			dst_offset := ((base_y + py) * img_w + base_x) * RGBA_BYTES_PER_PIXEL
			src_row := py * 8
			for px in 0 ..< copy_w {
				g := ws.y_blocks[0][src_row + px]
				out := dst_offset + px * 4
				output_rgba[out] = g
				output_rgba[out + 1] = g
				output_rgba[out + 2] = g
				output_rgba[out + 3] = 255
			}
		}

	case .Subsampling_444:
		for py in 0 ..< copy_h {
			src_row := py * 8
			jpeg_ycbcr_to_rgba_row(&ws.y_blocks[0][src_row], &ws.cb_block[src_row], &ws.cr_block[src_row], raw_data(ws.rgba_row[:]), copy_w)
			dst_offset := ((base_y + py) * img_w + base_x) * RGBA_BYTES_PER_PIXEL
			intrinsics.mem_copy_non_overlapping(&output_rgba[dst_offset], raw_data(ws.rgba_row[:]), copy_w * RGBA_BYTES_PER_PIXEL)
		}

	case .Subsampling_422:
		y_line: [16]u8 = ---
		for py in 0 ..< copy_h {
			c_row := py * 8
			for cx in 0 ..< 8 {
				cb_v := ws.cb_block[c_row + cx]
				cr_v := ws.cr_block[c_row + cx]
				ws.cb_row[cx * 2] = cb_v
				ws.cb_row[cx * 2 + 1] = cb_v
				ws.cr_row[cx * 2] = cr_v
				ws.cr_row[cx * 2 + 1] = cr_v
			}
			for px in 0 ..< 8 {
				y_line[px] = ws.y_blocks[0][py * 8 + px]
				y_line[px + 8] = ws.y_blocks[1][py * 8 + px]
			}
			jpeg_ycbcr_to_rgba_row(raw_data(y_line[:]), raw_data(ws.cb_row[:]), raw_data(ws.cr_row[:]), raw_data(ws.rgba_row[:]), copy_w)
			dst_offset := ((base_y + py) * img_w + base_x) * RGBA_BYTES_PER_PIXEL
			intrinsics.mem_copy_non_overlapping(&output_rgba[dst_offset], raw_data(ws.rgba_row[:]), copy_w * RGBA_BYTES_PER_PIXEL)
		}

	case .Subsampling_420:
		y_line: [16]u8 = ---
		for py in 0 ..< copy_h {
			c_row := (py >> 1) * 8
			for cx in 0 ..< 8 {
				cb_v := ws.cb_block[c_row + cx]
				cr_v := ws.cr_block[c_row + cx]
				ws.cb_row[cx * 2] = cb_v
				ws.cb_row[cx * 2 + 1] = cb_v
				ws.cr_row[cx * 2] = cr_v
				ws.cr_row[cx * 2 + 1] = cr_v
			}
			y_block_row := (py >> 3) * 2
			local_y := (py & 7) * 8
			for px in 0 ..< 8 {
				y_line[px] = ws.y_blocks[y_block_row][local_y + px]
				y_line[px + 8] = ws.y_blocks[y_block_row + 1][local_y + px]
			}
			jpeg_ycbcr_to_rgba_row(raw_data(y_line[:]), raw_data(ws.cb_row[:]), raw_data(ws.cr_row[:]), raw_data(ws.rgba_row[:]), copy_w)
			dst_offset := ((base_y + py) * img_w + base_x) * RGBA_BYTES_PER_PIXEL
			intrinsics.mem_copy_non_overlapping(&output_rgba[dst_offset], raw_data(ws.rgba_row[:]), copy_w * RGBA_BYTES_PER_PIXEL)
		}
	}
}

// jpeg_run_scan runs the baseline entropy scan across all MCUs and verifies EOI.
// When emit_pixels is false, validates every Huffman code, coefficient bound,
// restart marker, and EOI without running IDCT or writing output_rgba.
@(private)
jpeg_run_scan :: proc "contextless" (bytes: []u8, ws: ^Jpeg_Workspace, output_rgba: []u8, emit_pixels: bool) -> Image_Decode_Refusal #no_bounds_check {
	br := Jpeg_Bit_Reader{bytes = bytes, pos = ws.scan_data_offset}
	mcu_w := ws.h_max * 8
	mcu_h := ws.v_max * 8
	mcus_x := (int(ws.width) + mcu_w - 1) / mcu_w
	mcus_y := (int(ws.height) + mcu_h - 1) / mcu_h

	dc_pred: [3]i32
	coeffs: [64]i32
	mcu_index := 0
	expected_rst := u8(0)
	restart := int(ws.restart_interval)

	for mcu_y in 0 ..< mcus_y {
		for mcu_x in 0 ..< mcus_x {
			if restart > 0 && mcu_index > 0 && mcu_index % restart == 0 {
				rst_refusal := jpeg_expect_marker(&br, 0xD0 + expected_rst)
				if rst_refusal != .None {
					return rst_refusal
				}
				dc_pred = {}
				expected_rst = (expected_rst + 1) & 7
			}

			// Component 0 (Y / grayscale): h_samp * v_samp blocks.
			c0 := ws.components[0]
			y_block_idx := 0
			for _ in 0 ..< int(c0.v_samp) {
				for _ in 0 ..< int(c0.h_samp) {
					refusal := jpeg_decode_block(&br, &ws.dc_huff[c0.dc_table_id], &ws.ac_huff[c0.ac_table_id], &ws.qt[c0.qt_id], &dc_pred[0], &coeffs, emit_pixels)
					if refusal != .None {
						return refusal
					}
					if emit_pixels {
						jpeg_idct_8x8(&coeffs, &ws.y_blocks[y_block_idx])
					}
					y_block_idx += 1
				}
			}

			if ws.component_count == 3 {
				c1 := ws.components[1]
				r1 := jpeg_decode_block(&br, &ws.dc_huff[c1.dc_table_id], &ws.ac_huff[c1.ac_table_id], &ws.qt[c1.qt_id], &dc_pred[1], &coeffs, emit_pixels)
				if r1 != .None {
					return r1
				}
				if emit_pixels {
					jpeg_idct_8x8(&coeffs, &ws.cb_block)
				}

				c2 := ws.components[2]
				r2 := jpeg_decode_block(&br, &ws.dc_huff[c2.dc_table_id], &ws.ac_huff[c2.ac_table_id], &ws.qt[c2.qt_id], &dc_pred[2], &coeffs, emit_pixels)
				if r2 != .None {
					return r2
				}
				if emit_pixels {
					jpeg_idct_8x8(&coeffs, &ws.cr_block)
				}
			}

			if emit_pixels {
				jpeg_write_mcu(ws, mcu_x, mcu_y, output_rgba)
			}
			mcu_index += 1
		}
	}

	return jpeg_expect_marker(&br, u8(Jpeg_Marker.Eoi))
}

// jpeg_decode_rgba decodes a baseline JPEG into caller-provided output_rgba
// using caller-provided scratch memory. Leaves output_rgba untouched on any refusal.
jpeg_decode_rgba :: proc "contextless" (bytes: []u8, output_rgba: []u8, scratch: []u8) -> (header: Image_Header, refusal: Image_Decode_Refusal) #no_bounds_check {
	if len(scratch) < JPEG_MINIMUM_SCRATCH_BYTES {
		_, probe_refusal := jpeg_probe(bytes)
		if probe_refusal != .None {
			return {}, probe_refusal
		}
		return {}, .Scratch_Too_Small
	}
	base_addr := uintptr(raw_data(scratch))
	align_pad := int((8 - (base_addr & 7)) & 7)
	if align_pad + size_of(Jpeg_Workspace) > len(scratch) {
		return {}, .Scratch_Too_Small
	}
	ws := (^Jpeg_Workspace)(raw_data(scratch[align_pad:]))

	header, refusal = jpeg_parse_headers(bytes, ws)
	if refusal != .None {
		return {}, refusal
	}
	if u64(len(output_rgba)) < header.output_bytes {
		return {}, .Output_Buffer_Too_Small
	}

	// Pass 1: validate the complete entropy stream and EOI before writing any pixel.
	if verify_refusal := jpeg_run_scan(bytes, ws, nil, false); verify_refusal != .None {
		return {}, verify_refusal
	}
	// Pass 2: run IDCT and YCbCr -> RGBA into output_rgba.
	if decode_refusal := jpeg_run_scan(bytes, ws, output_rgba, true); decode_refusal != .None {
		return {}, decode_refusal
	}
	return header, .None
}
