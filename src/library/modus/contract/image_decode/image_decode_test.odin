#+build !freestanding
#+build !modus
package image_decode

import "core:fmt"
import "core:math"
import "core:testing"
import "core:time"
import "modus:contract/byte_order"

// Exhaustive adversarial host tests and opt-in SIMD throughput benchmarks for
// the freestanding PNG and baseline JPEG decoders.

@(private = "file")
MEASURE_CODECS :: #config(MEASURE, false)

@(private = "file")
Test_Rng :: struct {
	state: u64,
}

@(private = "file")
rng_next :: proc(rng: ^Test_Rng) -> u32 {
	rng.state ~= rng.state >> 12
	rng.state ~= rng.state << 25
	rng.state ~= rng.state >> 27
	return u32((rng.state * 0x2545F4914F6CDD1D) >> 32)
}

@(private = "file")
all_bytes_equal :: proc(buf: []u8, expected: u8) -> bool {
	for b in buf {
		if b != expected {
			return false
		}
	}
	return true
}

@(private = "file")
slices_equal :: proc(a, b: []u8) -> bool {
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

// ---------------------------------------------------------------------------
// Test PNG encoder helpers (real IEEE CRC-32, real zlib Adler-32, all 5
// filters, stored + fixed Huffman + dynamic Huffman DEFLATE)
// ---------------------------------------------------------------------------

@(private = "file")
append_u16_be :: proc(dst: ^[dynamic]u8, v: u16) {
	append(dst, u8(v >> 8), u8(v))
}

@(private = "file")
append_u32_be :: proc(dst: ^[dynamic]u8, v: u32) {
	append(dst, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
}

@(private = "file")
append_png_chunk :: proc(dst: ^[dynamic]u8, chunk_type: [4]u8, payload: []u8) {
	append_u32_be(dst, u32(len(payload)))
	type_start := len(dst)
	append(dst, chunk_type[0], chunk_type[1], chunk_type[2], chunk_type[3])
	append(dst, ..payload)
	crc := png_crc32(dst[type_start:])
	append_u32_be(dst, crc)
}

@(private = "file")
encode_png_filter_row :: proc(filter: Png_Filter, raw_out: []u8, curr: []u8, prev: []u8, bpp: int) {
	n := len(curr)
	switch filter {
	case .None:
		for i in 0 ..< n {
			raw_out[i] = curr[i]
		}
	case .Sub:
		for i in 0 ..< n {
			left := i >= bpp ? curr[i - bpp] : 0
			raw_out[i] = curr[i] - left
		}
	case .Up:
		for i in 0 ..< n {
			raw_out[i] = curr[i] - prev[i]
		}
	case .Average:
		for i in 0 ..< n {
			left := i >= bpp ? curr[i - bpp] : 0
			raw_out[i] = curr[i] - u8((u16(left) + u16(prev[i])) >> 1)
		}
	case .Paeth:
		for i in 0 ..< n {
			left := i >= bpp ? curr[i - bpp] : 0
			up_left := i >= bpp ? prev[i - bpp] : 0
			raw_out[i] = curr[i] - paeth_predictor(left, prev[i], up_left)
		}
	}
}

@(private = "file")
Bit_Emitter_Lsb :: struct {
	out: ^[dynamic]u8,
	buf: u64,
	cnt: u32,
}

@(private = "file")
lsb_emit :: proc(e: ^Bit_Emitter_Lsb, bits: u32, count: u32) {
	e.buf |= u64(bits) << e.cnt
	e.cnt += count
	for e.cnt >= 8 {
		append(e.out, u8(e.buf & 0xFF))
		e.buf >>= 8
		e.cnt -= 8
	}
}

@(private = "file")
lsb_emit_huff :: proc(e: ^Bit_Emitter_Lsb, code: u32, length: u32) {
	lsb_emit(e, reverse_bits(code, length), length)
}

@(private = "file")
lsb_flush :: proc(e: ^Bit_Emitter_Lsb) {
	if e.cnt > 0 {
		append(e.out, u8(e.buf & 0xFF))
		e.buf = 0
		e.cnt = 0
	}
}

@(private = "file")
Deflate_Test_Mode :: enum u8 {
	Stored,
	Fixed_Huffman,
	Dynamic_Huffman,
}

@(private = "file")
zlib_compress_test :: proc(raw: []u8, mode: Deflate_Test_Mode, allocator := context.allocator) -> [dynamic]u8 {
	out := make([dynamic]u8, 0, len(raw) + 64, allocator)
	// Zlib header: CMF=0x78 (DEFLATE, 32K window), FLG=0x01 (0x7801 % 31 == 0).
	append(&out, 0x78, 0x01)

	switch mode {
	case .Stored:
		offset := 0
		for {
			remaining := len(raw) - offset
			chunk := min(remaining, 65535)
			is_final := offset + chunk == len(raw)
			append(&out, is_final ? 0x01 : 0x00)
			l := u16(chunk)
			nl := ~l
			append(&out, u8(l), u8(l >> 8), u8(nl), u8(nl >> 8))
			append(&out, ..raw[offset:offset + chunk])
			offset += chunk
			if is_final {
				break
			}
		}

	case .Fixed_Huffman:
		e := Bit_Emitter_Lsb{out = &out}
		lsb_emit(&e, 1, 1) // BFINAL = 1
		lsb_emit(&e, 1, 2) // BTYPE = 01 (fixed Huffman)
		i := 0
		for i < len(raw) {
			// Emit an LZ77 RLE back-reference (distance=1) whenever 4+ identical bytes appear.
			run := 1
			if i > 0 {
				for i + run < len(raw) && run < 10 && raw[i + run] == raw[i - 1] {
					run += 1
				}
			}
			if i > 0 && raw[i] == raw[i - 1] && run >= 4 {
				// Length 4..10 -> symbol 258..264 (7 bits, code 2..8, 0 extra bits).
				sym := u32(257 + (run - 3))
				lsb_emit_huff(&e, sym - 256, 7)
				// Distance 1 -> distance symbol 0 (5 bits, code 0).
				lsb_emit_huff(&e, 0, 5)
				i += run
				continue
			}
			b := u32(raw[i])
			if b <= 143 {
				lsb_emit_huff(&e, 0x30 + b, 8)
			} else {
				lsb_emit_huff(&e, 0x190 + (b - 144), 9)
			}
			i += 1
		}
		// EOB (256): 7-bit code 0.
		lsb_emit_huff(&e, 0, 7)
		lsb_flush(&e)

	case .Dynamic_Huffman:
		// Build a valid dynamic Huffman block with uniform 9-bit codes for all 257
		// symbols (0..255 + EOB=256) plus length sym 257 (length 3) and 1-bit dist sym 0,
		// encoded using dynamic code-length symbols including repeat code 16!
		e := Bit_Emitter_Lsb{out = &out}
		lsb_emit(&e, 1, 1) // BFINAL = 1
		lsb_emit(&e, 2, 2) // BTYPE = 10 (dynamic Huffman)
		// HLIT = 258 (257 + 1): symbols 0..257 (0..255 literals, 256 EOB, 257 len=3).
		// HDIST = 1 (1 + 0): distance symbol 0 (distance = 1).
		// HCLEN = 19 (4 + 15): emit all 19 code-length lengths.
		lsb_emit(&e, 1, 5)  // HLIT - 257 = 1 -> 258
		lsb_emit(&e, 0, 5)  // HDIST - 1 = 0 -> 1
		lsb_emit(&e, 15, 4) // HCLEN - 4 = 15 -> 19
		// Code-length alphabet: we only use symbols 1 (len=2), 8 (len=2), 9 (len=2), 16 (len=2).
		// Wait: 4 symbols each of length 2 is a complete 2-bit tree!
		// Canonical codes: sym 1 -> 00, sym 8 -> 01, sym 9 -> 10, sym 16 -> 11.
		cl_lens: [19]u8
		cl_lens[1] = 2
		cl_lens[8] = 2
		cl_lens[9] = 2
		cl_lens[16] = 2
		order := DEFLATE_CODELEN_ORDER
		for k in 0 ..< 19 {
			lsb_emit(&e, u32(cl_lens[order[k]]), 3)
		}
		// Lit/len lengths (258 symbols):
		//   0..253 -> 8 bits (254 symbols)
		//   254..257 -> 9 bits (4 symbols)
		// Check Kraft sum: 254 / 256 + 4 / 512 = 508/512 + 4/512 = 512/512 = 1.0 (COMPLETE!).
		// Emit 254 copies of length 8: one literal '8' (code 01), then 42 * 6 = 252 + 1?
		// Let's emit: '8', then 42 repeats of 6 (252), plus one more '8' = 254!
		lsb_emit_huff(&e, 0b01, 2) // literal 8 (count = 1)
		for _ in 0 ..< 42 {
			lsb_emit_huff(&e, 0b11, 2) // sym 16 (repeat previous)
			lsb_emit(&e, 3, 2)         // repeat 3 + 3 = 6 times
		}
		lsb_emit_huff(&e, 0b01, 2) // literal 8 (count = 254)
		// Emit 4 copies of length 9: literal '9' (code 10), then sym 16 repeat 3 times.
		lsb_emit_huff(&e, 0b10, 2) // literal 9 (count = 1)
		lsb_emit_huff(&e, 0b11, 2) // sym 16
		lsb_emit(&e, 0, 2)         // repeat 3 + 0 = 3 times (total = 4)
		// Distance lengths (1 symbol): sym 0 has length 1 -> code 00.
		lsb_emit_huff(&e, 0b00, 2) // literal 1

		// Canonical codes for our dynamic lit/len tree:
		//   length 8: syms 0..253 -> codes 0..253 (8 bits)
		//   length 9: syms 254..257 -> first_code = (0 + 254) << 1 = 508 -> codes 508, 509, 510, 511 (9 bits)
		// Distance tree: sym 0 -> code 0 (1 bit).
		i := 0
		for i < len(raw) {
			if i > 0 && i + 3 <= len(raw) && raw[i] == raw[i - 1] && raw[i + 1] == raw[i - 1] && raw[i + 2] == raw[i - 1] {
				lsb_emit_huff(&e, 511, 9) // sym 257 (length 3)
				lsb_emit_huff(&e, 0, 1)   // dist sym 0 (distance 1)
				i += 3
				continue
			}
			b := u32(raw[i])
			if b <= 253 {
				lsb_emit_huff(&e, b, 8)
			} else {
				lsb_emit_huff(&e, 508 + (b - 254), 9)
			}
			i += 1
		}
		// EOB = sym 256 -> code 510 (9 bits).
		lsb_emit_huff(&e, 510, 9)
		lsb_flush(&e)
	}

	s1, s2 := adler32_update(1, 0, raw)
	append_u32_be(&out, (s2 << 16) | s1)
	return out
}

@(private = "file")
build_test_png :: proc(
	width, height: u32,
	color_type: Png_Color_Type,
	pixel_data: []u8,
	row_filters: []Png_Filter,
	deflate_mode: Deflate_Test_Mode,
	palette: [][3]u8 = nil,
	trns: []u8 = nil,
	split_idat_size := 0,
) -> [dynamic]u8 {
	bpp := png_bytes_per_pixel(color_type)
	row_bytes := int(width) * bpp
	raw_stream := make([]u8, int(height) * (1 + row_bytes))
	defer delete(raw_stream)
	zero_row := make([]u8, row_bytes)
	defer delete(zero_row)

	for y in 0 ..< int(height) {
		f := row_filters[y % len(row_filters)]
		dst_start := y * (1 + row_bytes)
		raw_stream[dst_start] = u8(f)
		curr := pixel_data[y * row_bytes:(y + 1) * row_bytes]
		prev := y == 0 ? zero_row : pixel_data[(y - 1) * row_bytes:y * row_bytes]
		encode_png_filter_row(f, raw_stream[dst_start + 1:dst_start + 1 + row_bytes], curr, prev, bpp)
	}

	zdata := zlib_compress_test(raw_stream, deflate_mode)
	defer delete(zdata)

	png := make([dynamic]u8, 0, len(zdata) + 128)
	sig := PNG_SIGNATURE
	append(&png, ..sig[:])

	ihdr: [13]u8
	byte_order.write_u32_big_endian(ihdr[:], 0, width)
	byte_order.write_u32_big_endian(ihdr[:], 4, height)
	ihdr[8] = 8
	ihdr[9] = u8(color_type)
	ihdr[10] = 0
	ihdr[11] = 0
	ihdr[12] = 0
	append_png_chunk(&png, {'I', 'H', 'D', 'R'}, ihdr[:])

	if len(palette) > 0 {
		plte := make([]u8, len(palette) * 3)
		defer delete(plte)
		for entry, idx in palette {
			plte[idx * 3] = entry[0]
			plte[idx * 3 + 1] = entry[1]
			plte[idx * 3 + 2] = entry[2]
		}
		append_png_chunk(&png, {'P', 'L', 'T', 'E'}, plte)
	}
	if len(trns) > 0 {
		append_png_chunk(&png, {'t', 'R', 'N', 'S'}, trns)
	}

	if split_idat_size > 0 {
		off := 0
		for off < len(zdata) {
			end := min(off + split_idat_size, len(zdata))
			append_png_chunk(&png, {'I', 'D', 'A', 'T'}, zdata[off:end])
			off = end
		}
	} else {
		append_png_chunk(&png, {'I', 'D', 'A', 'T'}, zdata[:])
	}

	append_png_chunk(&png, {'I', 'E', 'N', 'D'}, nil)
	return png
}

// ---------------------------------------------------------------------------
// Test baseline JPEG encoder helpers (real 8x8 forward DCT, standard ITU-T
// T.81 Huffman tables, 0xFF 0x00 byte stuffing, optional DRI restart markers)
// ---------------------------------------------------------------------------

@(private = "file")
Bit_Emitter_Msb :: struct {
	out: ^[dynamic]u8,
	buf: u64,
	cnt: u32,
}

@(private = "file")
msb_emit :: proc(e: ^Bit_Emitter_Msb, bits: u32, count: u32) {
	if count == 0 {
		return
	}
	e.buf = (e.buf << count) | u64(bits & ((u32(1) << count) - 1))
	e.cnt += count
	for e.cnt >= 8 {
		b := u8((e.buf >> (e.cnt - 8)) & 0xFF)
		e.cnt -= 8
		append(e.out, b)
		if b == 0xFF {
			append(e.out, 0x00)
		}
	}
}

@(private = "file")
msb_flush_ones :: proc(e: ^Bit_Emitter_Msb) {
	if e.cnt > 0 {
		pad := 8 - e.cnt
		msb_emit(e, (u32(1) << pad) - 1, pad)
	}
}

// Standard ITU-T T.81 Annex K luminance DC and AC Huffman specs.
@(private = "file")
STD_DC_COUNTS :: [16]u8{0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0}
@(private = "file")
STD_DC_SYMS :: [12]u8{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}

@(private = "file")
STD_AC_COUNTS :: [16]u8{0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D}
@(private = "file")
STD_AC_SYMS :: [162]u8{
	0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12,
	0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
	0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
	0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
	0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16,
	0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
	0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
	0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
	0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
	0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
	0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
	0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
	0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
	0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
	0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
	0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
	0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4,
	0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
	0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA,
	0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
	0xF9, 0xFA,
}

@(private = "file")
Huff_Encode_Table :: struct {
	code: [256]u32,
	bits: [256]u32,
}

@(private = "file")
build_huff_encode_table :: proc(counts: [16]u8, syms: []u8) -> Huff_Encode_Table {
	t: Huff_Encode_Table
	code := u32(0)
	idx := 0
	for length in u32(1) ..= 16 {
		for _ in 0 ..< int(counts[length - 1]) {
			s := syms[idx]
			t.code[s] = code
			t.bits[s] = length
			code += 1
			idx += 1
		}
		code <<= 1
	}
	return t
}

@(private = "file")
jpeg_category_and_bits :: proc(val: i32) -> (cat: u32, bits: u32) {
	if val == 0 {
		return 0, 0
	}
	abs_v := val < 0 ? u32(-val) : u32(val)
	c := u32(0)
	for (u32(1) << c) <= abs_v {
		c += 1
	}
	if val < 0 {
		return c, u32(val + i32((u32(1) << c) - 1))
	}
	return c, u32(val)
}

// Forward 2D DCT (exact float reference, host test only; angles converted to
// radians at the core:math.cos call per project convention).
@(private = "file")
forward_dct_8x8 :: proc(pixels: [64]u8, qt: [64]u8) -> [64]i32 {
	out: [64]i32
	for v in 0 ..< 8 {
		cv := v == 0 ? 1.0 / math.sqrt_f64(2.0) : 1.0
		for u in 0 ..< 8 {
			cu := u == 0 ? 1.0 / math.sqrt_f64(2.0) : 1.0
			sum := 0.0
			for y in 0 ..< 8 {
				// core:math.cos takes radians; angle in turns is (2*y + 1) * v / 32.
				cy := math.cos_f64((f64(2 * y + 1) * f64(v) / 32.0) * (2.0 * math.PI))
				for x in 0 ..< 8 {
					cx := math.cos_f64((f64(2 * x + 1) * f64(u) / 32.0) * (2.0 * math.PI))
					sum += (f64(pixels[y * 8 + x]) - 128.0) * cx * cy
				}
			}
			coeff := 0.25 * cu * cv * sum
			out[v * 8 + u] = i32(math.round_f64(coeff / f64(qt[v * 8 + u])))
		}
	}
	return out
}

@(private = "file")
encode_jpeg_block :: proc(e: ^Bit_Emitter_Msb, qcoeffs: [64]i32, dc_pred: ^i32, dc_enc, ac_enc: ^Huff_Encode_Table) {
	diff := qcoeffs[0] - dc_pred^
	dc_pred^ = qcoeffs[0]
	cat, bits := jpeg_category_and_bits(diff)
	msb_emit(e, dc_enc.code[cat], dc_enc.bits[cat])
	msb_emit(e, bits, cat)

	zigzag := JPEG_ZIGZAG
	zero_run := 0
	for k in 1 ..< 64 {
		val := qcoeffs[zigzag[k]]
		if val == 0 {
			zero_run += 1
			continue
		}
		for zero_run >= 16 {
			msb_emit(e, ac_enc.code[0xF0], ac_enc.bits[0xF0])
			zero_run -= 16
		}
		ac_cat, ac_bits := jpeg_category_and_bits(val)
		rs := u8((zero_run << 4) | int(ac_cat))
		msb_emit(e, ac_enc.code[rs], ac_enc.bits[rs])
		msb_emit(e, ac_bits, ac_cat)
		zero_run = 0
	}
	if zero_run > 0 {
		msb_emit(e, ac_enc.code[0x00], ac_enc.bits[0x00])
	}
}

@(private = "file")
build_test_jpeg :: proc(
	width, height: int,
	subsampling: Jpeg_Chroma_Subsampling,
	y_plane, cb_plane, cr_plane: []u8,
	restart_interval: u16 = 0,
	qt_val: u8 = 1,
) -> [dynamic]u8 {
	out := make([dynamic]u8, 0, 4096)
	append(&out, 0xFF, 0xD8) // SOI

	// APP0 JFIF marker + COM marker to exercise metadata skipping.
	append(&out, 0xFF, 0xE0)
	append_u16_be(&out, 16)
	append(&out, 'J', 'F', 'I', 'F', 0, 1, 1, 0, 0, 1, 0, 1, 0, 0)
	append(&out, 0xFF, 0xFE)
	append_u16_be(&out, 6)
	append(&out, 't', 'e', 's', 't')

	// DQT (table 0, 8-bit)
	qt: [64]u8
	for &q in qt {
		q = qt_val
	}
	append(&out, 0xFF, 0xDB)
	append_u16_be(&out, 67)
	append(&out, 0x00)
	append(&out, ..qt[:])

	// DHT (DC 0 and AC 0)
	dc_counts := STD_DC_COUNTS
	dc_syms := STD_DC_SYMS
	ac_counts := STD_AC_COUNTS
	ac_syms := STD_AC_SYMS
	append(&out, 0xFF, 0xC4)
	append_u16_be(&out, u16(2 + 1 + 16 + len(dc_syms) + 1 + 16 + len(ac_syms)))
	append(&out, 0x00)
	append(&out, ..dc_counts[:])
	append(&out, ..dc_syms[:])
	append(&out, 0x10)
	append(&out, ..ac_counts[:])
	append(&out, ..ac_syms[:])

	if restart_interval > 0 {
		append(&out, 0xFF, 0xDD)
		append_u16_be(&out, 4)
		append_u16_be(&out, restart_interval)
	}

	nf := subsampling == .Grayscale ? 1 : 3
	h_max, v_max := 1, 1
	switch subsampling {
	case .Grayscale, .Subsampling_444:
		h_max, v_max = 1, 1
	case .Subsampling_422:
		h_max, v_max = 2, 1
	case .Subsampling_420:
		h_max, v_max = 2, 2
	}

	// SOF0
	append(&out, 0xFF, 0xC0)
	append_u16_be(&out, u16(8 + 3 * nf))
	append(&out, 8) // precision
	append_u16_be(&out, u16(height))
	append_u16_be(&out, u16(width))
	append(&out, u8(nf))
	if nf == 1 {
		append(&out, 1, 0x11, 0)
	} else {
		append(&out, 1, u8((h_max << 4) | v_max), 0)
		append(&out, 2, 0x11, 0)
		append(&out, 3, 0x11, 0)
	}

	// SOS
	append(&out, 0xFF, 0xDA)
	append_u16_be(&out, u16(6 + 2 * nf))
	append(&out, u8(nf))
	for c in 1 ..= nf {
		append(&out, u8(c), 0x00) // DC table 0, AC table 0
	}
	append(&out, 0, 63, 0) // Ss=0, Se=63, Ah/Al=0

	dc_enc := build_huff_encode_table(dc_counts, dc_syms[:])
	ac_enc := build_huff_encode_table(ac_counts, ac_syms[:])
	e := Bit_Emitter_Msb{out = &out}

	mcu_w := h_max * 8
	mcu_h := v_max * 8
	mcus_x := (width + mcu_w - 1) / mcu_w
	mcus_y := (height + mcu_h - 1) / mcu_h
	dc_pred: [3]i32
	mcu_idx := 0
	rst_num := u8(0)

	sample_clamped :: proc(plane: []u8, w, h, x, y: int) -> u8 {
		cx := clamp(x, 0, w - 1)
		cy := clamp(y, 0, h - 1)
		return plane[cy * w + cx]
	}

	for my in 0 ..< mcus_y {
		for mx in 0 ..< mcus_x {
			if restart_interval > 0 && mcu_idx > 0 && mcu_idx % int(restart_interval) == 0 {
				msb_flush_ones(&e)
				append(&out, 0xFF, 0xD0 + rst_num)
				rst_num = (rst_num + 1) & 7
				dc_pred = {}
			}
			for by in 0 ..< v_max {
				for bx in 0 ..< h_max {
					block: [64]u8
					for py in 0 ..< 8 {
						for px in 0 ..< 8 {
							block[py * 8 + px] = sample_clamped(y_plane, width, height, mx * mcu_w + bx * 8 + px, my * mcu_h + by * 8 + py)
						}
					}
					encode_jpeg_block(&e, forward_dct_8x8(block, qt), &dc_pred[0], &dc_enc, &ac_enc)
				}
			}
			if nf == 3 {
				cb_blk, cr_blk: [64]u8
				for py in 0 ..< 8 {
					for px in 0 ..< 8 {
						sx := mx * mcu_w + px * h_max
						sy := my * mcu_h + py * v_max
						cb_blk[py * 8 + px] = sample_clamped(cb_plane, width, height, sx, sy)
						cr_blk[py * 8 + px] = sample_clamped(cr_plane, width, height, sx, sy)
					}
				}
				encode_jpeg_block(&e, forward_dct_8x8(cb_blk, qt), &dc_pred[1], &dc_enc, &ac_enc)
				encode_jpeg_block(&e, forward_dct_8x8(cr_blk, qt), &dc_pred[2], &dc_enc, &ac_enc)
			}
			mcu_idx += 1
		}
	}
	msb_flush_ones(&e)
	append(&out, 0xFF, 0xD9) // EOI
	return out
}

// ---------------------------------------------------------------------------
// 1. Enum border tests
// ---------------------------------------------------------------------------

@(test)
enum_borders_refuse_unknown_words :: proc(t: ^testing.T) {
	_, ok_f0 := image_format_of_word(0)
	testing.expect(t, !ok_f0, "format 0 must be refused")
	f1, ok_f1 := image_format_of_word(1)
	testing.expect(t, ok_f1 && f1 == .Png, "format 1 must be Png")
	f2, ok_f2 := image_format_of_word(2)
	testing.expect(t, ok_f2 && f2 == .Jpeg, "format 2 must be Jpeg")
	_, ok_f3 := image_format_of_word(3)
	testing.expect(t, !ok_f3, "format 3 must be refused")

	for w in u8(0) ..= 9 {
		_, ok := image_decode_refusal_of_word(w)
		testing.expectf(t, ok, "refusal %d must be valid", w)
	}
	_, ok_r10 := image_decode_refusal_of_word(10)
	testing.expect(t, !ok_r10, "refusal 10 must be refused")

	_, ok_ct1 := png_color_type_of_word(1)
	_, ok_ct5 := png_color_type_of_word(5)
	_, ok_ct7 := png_color_type_of_word(7)
	testing.expect(t, !ok_ct1 && !ok_ct5 && !ok_ct7, "invalid PNG color types must be refused")

	_, ok_flt5 := png_filter_of_word(5)
	testing.expect(t, !ok_flt5, "PNG filter 5 must be refused")

	_, ok_m0 := jpeg_marker_of_word(0x00)
	_, ok_mc1 := jpeg_marker_of_word(0xC1)
	testing.expect(t, !ok_m0 && !ok_mc1, "unknown JPEG markers must be refused")
}

// ---------------------------------------------------------------------------
// 2. PNG exact decode tests (all 5 color types, all 5 filters, all 3 DEFLATE
//    block modes, multi-IDAT, single-pass and compact scratch)
// ---------------------------------------------------------------------------

@(test)
png_decodes_all_color_types_filters_and_deflate_modes :: proc(t: ^testing.T) {
	scratch_big := make([]u8, PNG_MINIMUM_SCRATCH_BYTES + 65536)
	scratch_min := make([]u8, PNG_MINIMUM_SCRATCH_BYTES)
	defer delete(scratch_big)
	defer delete(scratch_min)

	all_filters := [5]Png_Filter{.None, .Sub, .Up, .Average, .Paeth}
	deflate_modes := [3]Deflate_Test_Mode{.Stored, .Fixed_Huffman, .Dynamic_Huffman}

	// Test 1: RGBA (color type 6), 37x19, exercising all 5 filters + all 3 DEFLATE modes + split IDAT!
	W :: 37
	H :: 19
	rgba_src := make([]u8, W * H * 4)
	defer delete(rgba_src)
	rng := Test_Rng{state = 0x1122334455667788}
	for y in 0 ..< H {
		for x in 0 ..< W {
			idx := (y * W + x) * 4
			if y == 3 {
				// Repeated bytes trigger LZ77 back-references in Fixed and Dynamic Huffman.
				rgba_src[idx] = 0xAA
				rgba_src[idx + 1] = 0xAA
				rgba_src[idx + 2] = 0xAA
				rgba_src[idx + 3] = 0xAA
			} else {
				v := rng_next(&rng)
				rgba_src[idx] = u8(v)
				rgba_src[idx + 1] = u8(v >> 8)
				rgba_src[idx + 2] = u8(v >> 16)
				rgba_src[idx + 3] = u8(v >> 24)
			}
		}
	}

	out := make([]u8, W * H * 4)
	defer delete(out)
	for mode in deflate_modes {
		png := build_test_png(W, H, .Truecolor_Alpha, rgba_src, all_filters[:], mode, split_idat_size = 29)
		defer delete(png)
		// Single-pass scratch
		hdr, refusal := image_decode_rgba(png[:], out, scratch_big)
		testing.expect_value(t, refusal, Image_Decode_Refusal.None)
		testing.expect_value(t, hdr.format, Image_Format.Png)
		testing.expect_value(t, hdr.width, u32(W))
		testing.expect_value(t, hdr.height, u32(H))
		testing.expectf(t, slices_equal(out, rgba_src), "PNG RGBA mismatch for mode %v (big scratch)", mode)

		// Compact minimum scratch (two-pass streaming)
		for &b in out {
			b = 0x00
		}
		_, refusal2 := image_decode_rgba(png[:], out, scratch_min)
		testing.expect_value(t, refusal2, Image_Decode_Refusal.None)
		testing.expectf(t, slices_equal(out, rgba_src), "PNG RGBA mismatch for mode %v (min scratch)", mode)
	}

	// Test 2: Grayscale (0) with tRNS
	gray_src := [12]u8{0, 42, 128, 255, 42, 1, 254, 42, 10, 20, 30, 40}
	trns_gray := [2]u8{0x00, 42}
	png_gray := build_test_png(4, 3, .Grayscale, gray_src[:], all_filters[:], .Fixed_Huffman, trns = trns_gray[:])
	defer delete(png_gray)
	out_small := make([]u8, 12 * 4)
	defer delete(out_small)
	_, r_gray := png_decode_rgba(png_gray[:], out_small, scratch_big)
	testing.expect_value(t, r_gray, Image_Decode_Refusal.None)
	for i in 0 ..< 12 {
		g := gray_src[i]
		exp_a := u8(g == 42 ? 0 : 255)
		testing.expect_value(t, out_small[i * 4 + 0], g)
		testing.expect_value(t, out_small[i * 4 + 1], g)
		testing.expect_value(t, out_small[i * 4 + 2], g)
		testing.expect_value(t, out_small[i * 4 + 3], exp_a)
	}

	// Test 3: Truecolor RGB (2) with tRNS
	rgb_src := [6 * 3]u8{
		255, 0, 128,
		10, 20, 30,
		0, 255, 0,
		10, 20, 30,
		1, 2, 3,
		254, 253, 252,
	}
	trns_rgb := [6]u8{0, 10, 0, 20, 0, 30}
	png_rgb := build_test_png(3, 2, .Truecolor, rgb_src[:], all_filters[:], .Dynamic_Huffman, trns = trns_rgb[:])
	defer delete(png_rgb)
	out_rgb := make([]u8, 6 * 4)
	defer delete(out_rgb)
	_, r_rgb := png_decode_rgba(png_rgb[:], out_rgb, scratch_big)
	testing.expect_value(t, r_rgb, Image_Decode_Refusal.None)
	for i in 0 ..< 6 {
		r, g, b := rgb_src[i * 3], rgb_src[i * 3 + 1], rgb_src[i * 3 + 2]
		exp_a := u8(r == 10 && g == 20 && b == 30 ? 0 : 255)
		testing.expect_value(t, out_rgb[i * 4 + 0], r)
		testing.expect_value(t, out_rgb[i * 4 + 1], g)
		testing.expect_value(t, out_rgb[i * 4 + 2], b)
		testing.expect_value(t, out_rgb[i * 4 + 3], exp_a)
	}

	// Test 4: Indexed PLTE (3) with partial tRNS
	pal := [4][3]u8{{10, 20, 30}, {40, 50, 60}, {70, 80, 90}, {200, 210, 220}}
	trns_idx := [2]u8{0, 128}
	idx_src := [8]u8{0, 1, 2, 3, 3, 2, 1, 0}
	png_idx := build_test_png(4, 2, .Indexed, idx_src[:], all_filters[:], .Stored, palette = pal[:], trns = trns_idx[:])
	defer delete(png_idx)
	out_idx := make([]u8, 8 * 4)
	defer delete(out_idx)
	_, r_idx := png_decode_rgba(png_idx[:], out_idx, scratch_big)
	testing.expect_value(t, r_idx, Image_Decode_Refusal.None)
	for i in 0 ..< 8 {
		p := int(idx_src[i])
		exp_a := u8(p == 0 ? 0 : (p == 1 ? 128 : 255))
		testing.expect_value(t, out_idx[i * 4 + 0], pal[p][0])
		testing.expect_value(t, out_idx[i * 4 + 1], pal[p][1])
		testing.expect_value(t, out_idx[i * 4 + 2], pal[p][2])
		testing.expect_value(t, out_idx[i * 4 + 3], exp_a)
	}

	// Test 5: Grayscale + Alpha (4)
	ga_src := [6 * 2]u8{0, 0, 128, 127, 255, 255, 64, 1, 192, 254, 17, 200}
	png_ga := build_test_png(3, 2, .Grayscale_Alpha, ga_src[:], all_filters[:], .Fixed_Huffman)
	defer delete(png_ga)
	out_ga := make([]u8, 6 * 4)
	defer delete(out_ga)
	_, r_ga := png_decode_rgba(png_ga[:], out_ga, scratch_min)
	testing.expect_value(t, r_ga, Image_Decode_Refusal.None)
	for i in 0 ..< 6 {
		g, a := ga_src[i * 2], ga_src[i * 2 + 1]
		testing.expect_value(t, out_ga[i * 4 + 0], g)
		testing.expect_value(t, out_ga[i * 4 + 1], g)
		testing.expect_value(t, out_ga[i * 4 + 2], g)
		testing.expect_value(t, out_ga[i * 4 + 3], a)
	}
}

// ---------------------------------------------------------------------------
// 3. PNG SIMD == scalar filter equivalence across all filters, bpp, widths
// ---------------------------------------------------------------------------

@(test)
png_unfilter_simd_matches_scalar_all_edges :: proc(t: ^testing.T) {
	when ODIN_ARCH == .amd64 {
		GUARD :: 16
		widths := [?]int{0, 1, 2, 3, 4, 5, 7, 8, 11, 12, 15, 16, 17, 31, 32, 33, 63, 64, 65, 257}
		MAX_BYTES :: GUARD + 15 + 257 * 4 + GUARD
		raw_buf, prev_buf, dst_scalar, dst_simd: [MAX_BYTES]u8
		rng := Test_Rng{state = 0xA0761D6478BD642F}
		wrong := 0

		for filter in Png_Filter {
			for bpp in 1 ..= 4 {
				for w in widths {
					n := w * bpp
					for align in 0 ..< 4 {
						total := GUARD + align + n + GUARD
						start := GUARD + align
						for i in 0 ..< total {
							raw_buf[i] = u8(rng_next(&rng))
							prev_buf[i] = u8(rng_next(&rng))
							dst_scalar[i] = 0xCC
							dst_simd[i] = 0xCC
						}
						png_unfilter_row_scalar(filter, dst_scalar[start:start + n], raw_buf[start:start + n], prev_buf[start:start + n], bpp)
						png_unfilter_row_simd(filter, dst_simd[start:start + n], raw_buf[start:start + n], prev_buf[start:start + n], bpp)
						for i in 0 ..< total {
							if dst_scalar[i] != dst_simd[i] {
								wrong += 1
								if wrong <= 5 {
									testing.expectf(t, false, "png_unfilter %v bpp=%d w=%d align=%d idx=%d: scalar=%02x simd=%02x", filter, bpp, w, align, i, dst_scalar[i], dst_simd[i])
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

// ---------------------------------------------------------------------------
// 4. Baseline JPEG decode tests (Grayscale, YCbCr 4:4:4, 4:2:2, 4:2:0, DRI)
// ---------------------------------------------------------------------------

// The pixel bound of a header, from its edges: a side of 0, the largest
// side words, one pixel past the bound in each shape, then the bound
// itself, a photo of 6000 x 4000 and a panorama of 30000 x 2000.
@(test)
the_pixel_bound_replaces_the_bound_of_each_side :: proc(t: ^testing.T) {
	Case :: struct {
		width, height: u32,
		refusal:       Image_Decode_Refusal,
	}
	cases := [?]Case {
		{0, 4000, .Dimensions_Invalid},
		{6000, 0, .Dimensions_Invalid},
		{max(u32), max(u32), .Decompression_Bomb},
		{65535, 65535, .Decompression_Bomb},
		{IMAGE_PIXELS_LIMIT + 1, 1, .Decompression_Bomb},
		{1, IMAGE_PIXELS_LIMIT + 1, .Decompression_Bomb},
		{16384, 16385, .Decompression_Bomb},
	}
	for each in cases {
		bytes, refusal := validate_dimensions(each.width, each.height)
		testing.expectf(t, refusal == each.refusal && bytes == 0, "%d x %d gives %v and %d bytes", each.width, each.height, refusal, bytes)
	}
	taken := [?][2]u32{{16384, 16384}, {IMAGE_PIXELS_LIMIT, 1}, {6000, 4000}, {30000, 2000}, {4097, 1}, {1, 1}}
	for size in taken {
		bytes, refusal := validate_dimensions(size[0], size[1])
		testing.expectf(t, refusal == .None && bytes == u64(size[0]) * u64(size[1]) * RGBA_BYTES_PER_PIXEL, "%v gives %v", size, refusal)
	}
	testing.expect_value(t, u64(IMAGE_PIXELS_LIMIT) * RGBA_BYTES_PER_PIXEL, u64(1) << 30)
}

// Images wider than 4096 pixels, the old bound of a side. A PNG of 6000 x 2
// needs the three row buffers in its scratch: one byte short of them is
// refused and writes no pixel; the least scratch decodes in two passes; a larger one in
// one pass, with the same pixels. A JPEG of 6000 x 16 decodes. The same
// JPEG with the height of a photo of 6000 x 4000 probes to 96 000 000
// bytes, and a buffer one byte short of them is refused before any pixel.
@(test)
images_wider_than_4096_decode_within_the_memory_of_the_caller :: proc(t: ^testing.T) {
	W :: 6000
	{
		H :: 2
		pixels := make([]u8, W * H * 4)
		defer delete(pixels)
		for i in 0 ..< len(pixels) {
			pixels[i] = u8(i * 13 + i / 4096)
		}
		filters := [2]Png_Filter{.Sub, .Paeth}
		png := build_test_png(W, H, .Truecolor_Alpha, pixels, filters[:], .Fixed_Huffman)
		defer delete(png)
		header, probe_refusal := image_probe(png[:])
		testing.expect_value(t, probe_refusal, Image_Decode_Refusal.None)
		least := png_minimum_scratch_bytes(W * 4)
		testing.expect_value(t, header.minimum_scratch_bytes, least)
		testing.expect_value(t, least, u64(PNG_MINIMUM_SCRATCH_BYTES + 3 * W * 4 + 1))
		out := make([]u8, W * H * 4)
		defer delete(out)
		scratch := make([]u8, int(least) + int(H * (1 + W * 4)))
		defer delete(scratch)
		for &b in out {
			b = 0xA5
		}
		// The scratch of make is aligned: the workspace starts at its first
		// byte, and the 16 bytes of the least scratch for an alignment stay
		// free. One byte short of the rows past the workspace is refused.
		testing.expect(t, uintptr(raw_data(scratch)) & 7 == 0)
		_, short := image_decode_rgba(png[:], out, scratch[:size_of(Png_Workspace) + 3 * W * 4])
		testing.expect_value(t, short, Image_Decode_Refusal.Scratch_Too_Small)
		testing.expect(t, all_bytes_equal(out, 0xA5))
		_, streamed := image_decode_rgba(png[:], out, scratch[:least])
		testing.expect_value(t, streamed, Image_Decode_Refusal.None)
		testing.expect(t, slices_equal(out, pixels))
		for &b in out {
			b = 0
		}
		_, whole := image_decode_rgba(png[:], out, scratch)
		testing.expect_value(t, whole, Image_Decode_Refusal.None)
		testing.expect(t, slices_equal(out, pixels))
	}
	{
		H :: 16
		gray := make([]u8, W * H)
		defer delete(gray)
		for i in 0 ..< len(gray) {
			gray[i] = u8(40 + (i % W) / 32)
		}
		jpg := build_test_jpeg(W, H, .Grayscale, gray, nil, nil)
		defer delete(jpg)
		scratch := make([]u8, JPEG_MINIMUM_SCRATCH_BYTES)
		defer delete(scratch)
		out := make([]u8, W * H * 4)
		defer delete(out)
		header, refusal := image_decode_rgba(jpg[:], out, scratch)
		testing.expect_value(t, refusal, Image_Decode_Refusal.None)
		testing.expect(t, header.width == W && header.height == H)
		for i in 0 ..< W * H {
			if abs(i32(out[i * 4]) - i32(gray[i])) > 2 {
				testing.expectf(t, false, "pixel %d: %d, not %d", i, out[i * 4], gray[i])
				break
			}
		}
		// The height of SOF0 is 5 bytes past its marker: the length, then the
		// precision.
		sof := -1
		for i in 0 ..< len(jpg) - 1 {
			if jpg[i] == 0xFF && jpg[i + 1] == 0xC0 {
				sof = i
				break
			}
		}
		testing.expect(t, sof > 0)
		photo := make([]u8, len(jpg))
		defer delete(photo)
		copy(photo, jpg[:])
		byte_order.write_u16_big_endian(photo, sof + 5, 4000)
		probed, probe_refusal := image_probe(photo)
		testing.expect_value(t, probe_refusal, Image_Decode_Refusal.None)
		testing.expect(t, probed.width == 6000 && probed.height == 4000 && probed.output_bytes == 96_000_000)
		for &b in out {
			b = 0xA5
		}
		_, too_small := image_decode_rgba(photo, out, scratch)
		testing.expect_value(t, too_small, Image_Decode_Refusal.Output_Buffer_Too_Small)
		testing.expect(t, all_bytes_equal(out, 0xA5))
	}
}

@(test)
jpeg_decodes_grayscale_444_422_and_420_with_restarts :: proc(t: ^testing.T) {
	scratch := make([]u8, JPEG_MINIMUM_SCRATCH_BYTES)
	defer delete(scratch)

	// 1. Grayscale 13x11 (non-multiple of 8) with restart interval = 1
	{
		W :: 13
		H :: 11
		y := make([]u8, W * H)
		defer delete(y)
		for py in 0 ..< H {
			for px in 0 ..< W {
				y[py * W + px] = u8(20 + px * 14 + py * 5)
			}
		}
		jpg := build_test_jpeg(W, H, .Grayscale, y, nil, nil, restart_interval = 1, qt_val = 1)
		defer delete(jpg)
		out := make([]u8, W * H * 4)
		defer delete(out)
		hdr, refusal := image_decode_rgba(jpg[:], out, scratch)
		testing.expect_value(t, refusal, Image_Decode_Refusal.None)
		testing.expect_value(t, hdr.format, Image_Format.Jpeg)
		testing.expect_value(t, hdr.width, u32(W))
		testing.expect_value(t, hdr.height, u32(H))
		for i in 0 ..< W * H {
			diff := abs(i32(out[i * 4]) - i32(y[i]))
			testing.expectf(t, diff <= 2, "gray pixel %d: got %d expected %d", i, out[i * 4], y[i])
			testing.expect_value(t, out[i * 4 + 1], out[i * 4])
			testing.expect_value(t, out[i * 4 + 2], out[i * 4])
			testing.expect_value(t, out[i * 4 + 3], u8(255))
		}
	}

	// 2. YCbCr 4:4:4 (19x13) with restart interval = 2
	{
		W :: 19
		H :: 13
		y := make([]u8, W * H)
		cb := make([]u8, W * H)
		cr := make([]u8, W * H)
		defer delete(y)
		defer delete(cb)
		defer delete(cr)
		for py in 0 ..< H {
			for px in 0 ..< W {
				i := py * W + px
				// Distinct smooth color quadrants (also exercises high-amplitude blocks / byte stuffing).
				y[i] = u8(40 + (px * 9) % 180)
				cb[i] = u8(px < 10 ? 90 : 170)
				cr[i] = u8(py < 7 ? 180 : 85)
			}
		}
		jpg := build_test_jpeg(W, H, .Subsampling_444, y, cb, cr, restart_interval = 2, qt_val = 1)
		defer delete(jpg)
		// Verify 0xFF 0x00 byte-stuffing is exercised on high-contrast data too.
		y_hi := make([]u8, 16 * 16)
		defer delete(y_hi)
		for py in 0 ..< 16 {
			for px in 0 ..< 16 {
				y_hi[py * 16 + px] = u8(((px + py) & 1) == 0 ? 255 : 0)
			}
		}
		jpg_stuff := build_test_jpeg(16, 16, .Grayscale, y_hi, nil, nil, qt_val = 1)
		defer delete(jpg_stuff)
		found_stuff := false
		for i in 0 ..< len(jpg_stuff) - 1 {
			if jpg_stuff[i] == 0xFF && jpg_stuff[i + 1] == 0x00 {
				found_stuff = true
				break
			}
		}
		testing.expect(t, found_stuff, "checkerboard JPEG must exercise 0xFF 0x00 byte stuffing")
		out_stuff := make([]u8, 16 * 16 * 4)
		defer delete(out_stuff)
		_, r_stuff := image_decode_rgba(jpg_stuff[:], out_stuff, scratch)
		testing.expect_value(t, r_stuff, Image_Decode_Refusal.None)
		for i in 0 ..< 16 * 16 {
			testing.expectf(t, abs(i32(out_stuff[i * 4]) - i32(y_hi[i])) <= 2, "stuffed JPEG pixel %d", i)
		}
		out := make([]u8, W * H * 4)
		defer delete(out)
		hdr, refusal := image_decode_rgba(jpg[:], out, scratch)
		testing.expect_value(t, refusal, Image_Decode_Refusal.None)
		testing.expect_value(t, hdr.width, u32(W))
		testing.expect_value(t, hdr.height, u32(H))

		expected := make([]u8, W * H * 4)
		defer delete(expected)
		jpeg_ycbcr_to_rgba_row_scalar(raw_data(y), raw_data(cb), raw_data(cr), raw_data(expected), W * H)
		max_err := i32(0)
		for i in 0 ..< W * H * 4 {
			err := abs(i32(out[i]) - i32(expected[i]))
			if err > max_err {
				max_err = err
			}
		}
		testing.expectf(t, max_err <= 4, "4:4:4 max channel error %d exceeds tolerance", max_err)
	}

	// 3. YCbCr 4:2:0 (21x19, non-multiple of 16) with restart interval = 2
	{
		W :: 21
		H :: 19
		y := make([]u8, W * H)
		cb := make([]u8, W * H)
		cr := make([]u8, W * H)
		defer delete(y)
		defer delete(cb)
		defer delete(cr)
		for py in 0 ..< H {
			for px in 0 ..< W {
				i := py * W + px
				y[i] = u8(50 + px * 6 + py * 3)
				// Constant chroma per 2x2 block so 4:2:0 subsampling is exact.
				cb[i] = u8((px / 8) == 0 ? 100 : 165)
				cr[i] = u8((py / 8) == 0 ? 160 : 95)
			}
		}
		jpg := build_test_jpeg(W, H, .Subsampling_420, y, cb, cr, restart_interval = 2, qt_val = 1)
		defer delete(jpg)
		out := make([]u8, W * H * 4)
		defer delete(out)
		hdr, refusal := image_decode_rgba(jpg[:], out, scratch)
		testing.expect_value(t, refusal, Image_Decode_Refusal.None)
		testing.expect_value(t, hdr.width, u32(W))
		testing.expect_value(t, hdr.height, u32(H))

		expected := make([]u8, W * H * 4)
		defer delete(expected)
		jpeg_ycbcr_to_rgba_row_scalar(raw_data(y), raw_data(cb), raw_data(cr), raw_data(expected), W * H)
		max_err := i32(0)
		for i in 0 ..< W * H * 4 {
			err := abs(i32(out[i]) - i32(expected[i]))
			if err > max_err {
				max_err = err
			}
		}
		testing.expectf(t, max_err <= 4, "4:2:0 max channel error %d exceeds tolerance", max_err)
	}

	// 4. YCbCr 4:2:2 (17x9)
	{
		W :: 17
		H :: 9
		y := make([]u8, W * H)
		cb := make([]u8, W * H)
		cr := make([]u8, W * H)
		defer delete(y)
		defer delete(cb)
		defer delete(cr)
		for py in 0 ..< H {
			for px in 0 ..< W {
				i := py * W + px
				y[i] = u8(60 + px * 8)
				cb[i] = 110
				cr[i] = 155
			}
		}
		jpg := build_test_jpeg(W, H, .Subsampling_422, y, cb, cr, qt_val = 1)
		defer delete(jpg)
		out := make([]u8, W * H * 4)
		defer delete(out)
		_, refusal := image_decode_rgba(jpg[:], out, scratch)
		testing.expect_value(t, refusal, Image_Decode_Refusal.None)
		expected := make([]u8, W * H * 4)
		defer delete(expected)
		jpeg_ycbcr_to_rgba_row_scalar(raw_data(y), raw_data(cb), raw_data(cr), raw_data(expected), W * H)
		max_err := i32(0)
		for i in 0 ..< W * H * 4 {
			err := abs(i32(out[i]) - i32(expected[i]))
			if err > max_err {
				max_err = err
			}
		}
		testing.expectf(t, max_err <= 4, "4:2:2 max channel error %d exceeds tolerance", max_err)
	}
}

// ---------------------------------------------------------------------------
// 5. JPEG SIMD == scalar equivalence (2D IDCT & YCbCr -> RGBA)
// ---------------------------------------------------------------------------

@(test)
jpeg_idct_and_ycbcr_simd_match_scalar_bit_for_bit :: proc(t: ^testing.T) {
	when ODIN_ARCH == .amd64 {
		rng := Test_Rng{state = 0xD1B54A32D192ED03}
		coeffs: [64]i32
		out_scalar, out_simd: [64]u8

		// 1. All-zero block -> all 128
		jpeg_idct_8x8_scalar(&coeffs, &out_scalar)
		jpeg_idct_8x8_simd(&coeffs, &out_simd)
		testing.expect(t, out_scalar == out_simd, "zero IDCT block mismatch")
		for b in out_simd {
			testing.expect_value(t, b, u8(128))
		}

		// 2. Single-coefficient impulses across all 64 positions
		for pos in 0 ..< 64 {
			for val in ([?]i32{-2048, -1024, -1, 1, 512, 1024, 2047, min(i32), max(i32)}) {
				coeffs = {}
				coeffs[pos] = val
				jpeg_idct_8x8_scalar(&coeffs, &out_scalar)
				jpeg_idct_8x8_simd(&coeffs, &out_simd)
				testing.expectf(t, out_scalar == out_simd, "IDCT impulse pos=%d val=%d mismatch", pos, val)
			}
		}

		// 3. 500 random & adversarial extreme blocks
		for round in 0 ..< 500 {
			for k in 0 ..< 64 {
				switch round % 3 {
				case 0:
					coeffs[k] = i32(rng_next(&rng) % 4096) - 2048
				case 1:
					coeffs[k] = (rng_next(&rng) & 1) == 0 ? 2047 : -2048
				case 2:
					coeffs[k] = i32(rng_next(&rng))
				}
			}
			jpeg_idct_8x8_scalar(&coeffs, &out_scalar)
			jpeg_idct_8x8_simd(&coeffs, &out_simd)
			testing.expectf(t, out_scalar == out_simd, "IDCT random round %d mismatch", round)
		}

		// 4. YCbCr -> RGBA across all edge widths, alignments, and channel edges
		GUARD :: 16
		widths := [?]int{0, 1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 63, 64, 65, 257}
		MAX_PX :: GUARD + 7 + 257 + GUARD
		y_buf, cb_buf, cr_buf: [MAX_PX]u8
		rgba_scalar, rgba_simd: [MAX_PX * 4]u8
		edges := [?]u8{0, 1, 127, 128, 254, 255}
		wrong := 0

		for w in widths {
			for align in 0 ..< 4 {
				total := GUARD + align + w + GUARD
				start := GUARD + align
				for i in 0 ..< total {
					if i % 5 == 0 {
						y_buf[i] = edges[rng_next(&rng) % len(edges)]
						cb_buf[i] = edges[rng_next(&rng) % len(edges)]
						cr_buf[i] = edges[rng_next(&rng) % len(edges)]
					} else {
						y_buf[i] = u8(rng_next(&rng))
						cb_buf[i] = u8(rng_next(&rng))
						cr_buf[i] = u8(rng_next(&rng))
					}
				}
				for i in 0 ..< total * 4 {
					rgba_scalar[i] = 0x5A
					rgba_simd[i] = 0x5A
				}
				jpeg_ycbcr_to_rgba_row_scalar(&y_buf[start], &cb_buf[start], &cr_buf[start], &rgba_scalar[start * 4], w)
				jpeg_ycbcr_to_rgba_row_simd(&y_buf[start], &cb_buf[start], &cr_buf[start], &rgba_simd[start * 4], w)
				for i in 0 ..< total * 4 {
					if rgba_scalar[i] != rgba_simd[i] {
						wrong += 1
					}
				}
			}
		}
		testing.expect_value(t, wrong, 0)
	}
}

// ---------------------------------------------------------------------------
// 6. Adversarial refusals: zero panics, zero OOB, ZERO pixel writes!
// ---------------------------------------------------------------------------

@(test)
adversarial_refusals_never_write_output_buffer :: proc(t: ^testing.T) {
	scratch := make([]u8, PNG_MINIMUM_SCRATCH_BYTES + 4096)
	defer delete(scratch)
	out := make([]u8, 64 * 64 * 4)
	defer delete(out)

	CANARY :: u8(0xA5)
	expect_refusal :: proc(t: ^testing.T, label: string, input: []u8, out: []u8, scratch: []u8, expected: Image_Decode_Refusal) {
		for &b in out {
			b = CANARY
		}
		_, got := image_decode_rgba(input, out, scratch)
		testing.expectf(t, got == expected, "%s: expected refusal %v, got %v", label, expected, got)
		testing.expectf(t, all_bytes_equal(out, CANARY), "%s: output_rgba was modified on refusal %v!", label, got)
	}

	// Empty, truncated magic, bad magic
	expect_refusal(t, "empty", nil, out, scratch, .Truncated)
	expect_refusal(t, "1 byte PNG prefix", []u8{0x89}, out, scratch, .Truncated)
	expect_refusal(t, "7 byte PNG prefix", []u8{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A}, out, scratch, .Truncated)
	expect_refusal(t, "1 byte JPEG prefix", []u8{0xFF}, out, scratch, .Truncated)
	expect_refusal(t, "GIF magic", transmute([]u8)string("GIF89a123456"), out, scratch, .Bad_Magic)
	expect_refusal(t, "corrupt JPEG SOI", []u8{0xFF, 0x00, 0x00, 0x00}, out, scratch, .Bad_Magic)

	// Build a valid 4x4 RGBA PNG to mutate adversarially
	valid_pixels := make([]u8, 4 * 4 * 4)
	defer delete(valid_pixels)
	for i in 0 ..< len(valid_pixels) {
		valid_pixels[i] = u8(i * 7)
	}
	f_none := [1]Png_Filter{.None}
	valid_png := build_test_png(4, 4, .Truecolor_Alpha, valid_pixels, f_none[:], .Fixed_Huffman)
	defer delete(valid_png)

	// Truncated PNG at every prefix length
	for cut in 1 ..< len(valid_png) {
		for &b in out {
			b = CANARY
		}
		_, r := image_decode_rgba(valid_png[:cut], out, scratch)
		testing.expectf(t, r != .None, "truncated PNG at %d/%d must be refused", cut, len(valid_png))
		testing.expectf(t, all_bytes_equal(out, CANARY), "truncated PNG at %d wrote output", cut)
	}

	// Corrupt CRC-32 (flip 1 bit in IHDR data)
	{
		mut := make([]u8, len(valid_png))
		defer delete(mut)
		copy(mut, valid_png[:])
		mut[20] ~= 0x01
		expect_refusal(t, "PNG bad CRC", mut, out, scratch, .Checksum_Mismatch)
	}

	// Corrupt Adler-32 (flip 1 bit in last byte of IDAT payload, recompute chunk CRC!)
	{
		mut := make([]u8, len(valid_png))
		defer delete(mut)
		copy(mut, valid_png[:])
		// IHDR is 8 + (12 + 13) = 33; IDAT starts at offset 33.
		idat_len := int(byte_order.read_u32_big_endian(mut, 33))
		mut[33 + 8 + idat_len - 1] ~= 0x01
		new_crc := png_crc32(mut[33 + 4:33 + 8 + idat_len])
		byte_order.write_u32_big_endian(mut, 33 + 8 + idat_len, new_crc)
		expect_refusal(t, "PNG bad Adler-32 (big scratch)", mut, out, scratch, .Checksum_Mismatch)
		expect_refusal(t, "PNG bad Adler-32 (min scratch)", mut, out, scratch[:PNG_MINIMUM_SCRATCH_BYTES], .Checksum_Mismatch)
	}

	// PNG width = 0, height = 0, and decompression bomb 65535x65535
	make_png_ihdr_only :: proc(w, h: u32, bit_depth: u8 = 8, color_type: u8 = 6, interlace: u8 = 0) -> [dynamic]u8 {
		buf := make([dynamic]u8, 0, 64)
		sig := PNG_SIGNATURE
		append(&buf, ..sig[:])
		ihdr: [13]u8
		byte_order.write_u32_big_endian(ihdr[:], 0, w)
		byte_order.write_u32_big_endian(ihdr[:], 4, h)
		ihdr[8] = bit_depth
		ihdr[9] = color_type
		ihdr[12] = interlace
		append_png_chunk(&buf, {'I', 'H', 'D', 'R'}, ihdr[:])
		append_png_chunk(&buf, {'I', 'E', 'N', 'D'}, nil)
		return buf
	}
	{
		p_w0 := make_png_ihdr_only(0, 4)
		defer delete(p_w0)
		expect_refusal(t, "PNG width=0", p_w0[:], out, scratch, .Dimensions_Invalid)

		p_h0 := make_png_ihdr_only(4, 0)
		defer delete(p_h0)
		expect_refusal(t, "PNG height=0", p_h0[:], out, scratch, .Dimensions_Invalid)

		p_bomb := make_png_ihdr_only(65535, 65535)
		defer delete(p_bomb)
		expect_refusal(t, "PNG 65535x65535 bomb", p_bomb[:], out, scratch, .Decompression_Bomb)

		p_16bit := make_png_ihdr_only(4, 4, bit_depth = 16)
		defer delete(p_16bit)
		expect_refusal(t, "PNG 16-bit unsupported", p_16bit[:], out, scratch, .Unsupported_Variant)

		p_interlace := make_png_ihdr_only(4, 4, interlace = 1)
		defer delete(p_interlace)
		expect_refusal(t, "PNG interlaced unsupported", p_interlace[:], out, scratch, .Unsupported_Variant)
	}

	// PNG decompression bomb in DEFLATE payload (claims 1x1 = 5 bytes, inflates 100 bytes!)
	{
		bomb_raw := make([]u8, 100)
		defer delete(bomb_raw)
		zdata := zlib_compress_test(bomb_raw, .Fixed_Huffman)
		defer delete(zdata)
		p := make([dynamic]u8, 0, 128)
		defer delete(p)
		sig := PNG_SIGNATURE
		append(&p, ..sig[:])
		ihdr: [13]u8
		byte_order.write_u32_big_endian(ihdr[:], 0, 1)
		byte_order.write_u32_big_endian(ihdr[:], 4, 1)
		ihdr[8] = 8
		ihdr[9] = 6
		append_png_chunk(&p, {'I', 'H', 'D', 'R'}, ihdr[:])
		append_png_chunk(&p, {'I', 'D', 'A', 'T'}, zdata[:])
		append_png_chunk(&p, {'I', 'E', 'N', 'D'}, nil)
		expect_refusal(t, "PNG DEFLATE overflow bomb", p[:], out, scratch, .Decompression_Bomb)
	}

	// PNG malformed DEFLATE BTYPE = 3
	{
		bad_z := [8]u8{0x78, 0x01, 0x07, 0x00, 0x00, 0x00, 0x00, 0x01} // BFINAL=1, BTYPE=11 (invalid)
		p := make([dynamic]u8, 0, 64)
		defer delete(p)
		sig := PNG_SIGNATURE
		append(&p, ..sig[:])
		ihdr: [13]u8
		byte_order.write_u32_big_endian(ihdr[:], 0, 1)
		byte_order.write_u32_big_endian(ihdr[:], 4, 1)
		ihdr[8] = 8
		ihdr[9] = 6
		append_png_chunk(&p, {'I', 'H', 'D', 'R'}, ihdr[:])
		append_png_chunk(&p, {'I', 'D', 'A', 'T'}, bad_z[:])
		append_png_chunk(&p, {'I', 'E', 'N', 'D'}, nil)
		expect_refusal(t, "PNG BTYPE=3 corrupt", p[:], out, scratch, .Corrupt_Stream)
	}

	// PNG output buffer 1 byte too small and scratch 1 byte too small
	expect_refusal(t, "PNG output 1 byte short", valid_png[:], out[:4 * 4 * 4 - 1], scratch, .Output_Buffer_Too_Small)
	expect_refusal(t, "PNG scratch 1 byte short", valid_png[:], out, scratch[:PNG_MINIMUM_SCRATCH_BYTES - 1], .Scratch_Too_Small)

	// Valid JPEG to mutate adversarially
	y_small := make([]u8, 8 * 8)
	defer delete(y_small)
	for &v, i in y_small {
		v = u8(40 + i * 2)
	}
	valid_jpg := build_test_jpeg(8, 8, .Grayscale, y_small, nil, nil, restart_interval = 1)
	defer delete(valid_jpg)

	// Truncated JPEG at every prefix (including truncated SOS scan!)
	for cut in 1 ..< len(valid_jpg) {
		for &b in out {
			b = CANARY
		}
		_, r := image_decode_rgba(valid_jpg[:cut], out, scratch)
		testing.expectf(t, r != .None, "truncated JPEG at %d/%d must be refused", cut, len(valid_jpg))
		testing.expectf(t, all_bytes_equal(out, CANARY), "truncated JPEG at %d wrote output", cut)
	}

	// JPEG output buffer 1 byte too small and scratch 1 byte too small
	expect_refusal(t, "JPEG output 1 byte short", valid_jpg[:], out[:8 * 8 * 4 - 1], scratch, .Output_Buffer_Too_Small)
	expect_refusal(t, "JPEG scratch 1 byte short", valid_jpg[:], out, scratch[:JPEG_MINIMUM_SCRATCH_BYTES - 1], .Scratch_Too_Small)

	// JPEG width = 0, height = 0, 65535x65535 bomb, progressive SOF2
	make_jpg_sof :: proc(marker_code: u8, w, h: u16) -> [dynamic]u8 {
		buf := make([dynamic]u8, 0, 32)
		append(&buf, 0xFF, 0xD8, 0xFF, marker_code)
		append_u16_be(&buf, 11)
		append(&buf, 8)
		append_u16_be(&buf, h)
		append_u16_be(&buf, w)
		append(&buf, 1, 1, 0x11, 0)
		append(&buf, 0xFF, 0xD9)
		return buf
	}
	{
		j_w0 := make_jpg_sof(0xC0, 0, 8)
		defer delete(j_w0)
		expect_refusal(t, "JPEG width=0", j_w0[:], out, scratch, .Dimensions_Invalid)

		j_h0 := make_jpg_sof(0xC0, 8, 0)
		defer delete(j_h0)
		expect_refusal(t, "JPEG height=0", j_h0[:], out, scratch, .Dimensions_Invalid)

		j_bomb := make_jpg_sof(0xC0, 65535, 65535)
		defer delete(j_bomb)
		expect_refusal(t, "JPEG 65535x65535 bomb", j_bomb[:], out, scratch, .Decompression_Bomb)

		j_prog := make_jpg_sof(0xC2, 8, 8)
		defer delete(j_prog)
		expect_refusal(t, "JPEG progressive SOF2", j_prog[:], out, scratch, .Unsupported_Variant)
	}

	// PNG invalid filter byte (5) inside valid DEFLATE + CRC + Adler-32
	{
		raw_bad_filter := [5]u8{5, 10, 20, 30, 40}
		zdata := zlib_compress_test(raw_bad_filter[:], .Stored)
		defer delete(zdata)
		p := make([dynamic]u8, 0, 64)
		defer delete(p)
		sig := PNG_SIGNATURE
		append(&p, ..sig[:])
		ihdr: [13]u8
		byte_order.write_u32_big_endian(ihdr[:], 0, 1)
		byte_order.write_u32_big_endian(ihdr[:], 4, 1)
		ihdr[8] = 8
		ihdr[9] = 6
		append_png_chunk(&p, {'I', 'H', 'D', 'R'}, ihdr[:])
		append_png_chunk(&p, {'I', 'D', 'A', 'T'}, zdata[:])
		append_png_chunk(&p, {'I', 'E', 'N', 'D'}, nil)
		expect_refusal(t, "PNG invalid filter byte 5 (big scratch)", p[:], out, scratch, .Corrupt_Stream)
		expect_refusal(t, "PNG invalid filter byte 5 (min scratch)", p[:], out, scratch[:PNG_MINIMUM_SCRATCH_BYTES], .Corrupt_Stream)
	}

	// PNG indexed pixel referencing out-of-range palette index
	{
		pal := [2][3]u8{{1, 2, 3}, {4, 5, 6}}
		idx_bad := [2]u8{0, 2} // index 2 out of bounds for 2-entry palette
		p := build_test_png(2, 1, .Indexed, idx_bad[:], f_none[:], .Stored, palette = pal[:])
		defer delete(p)
		expect_refusal(t, "PNG out-of-range palette index (big scratch)", p[:], out, scratch, .Corrupt_Stream)
		expect_refusal(t, "PNG out-of-range palette index (min scratch)", p[:], out, scratch[:PNG_MINIMUM_SCRATCH_BYTES], .Corrupt_Stream)
	}

	// PNG invalid DEFLATE back-reference distance exceeding emitted bytes
	{
		z := make([dynamic]u8, 0, 16)
		defer delete(z)
		append(&z, 0x78, 0x01)
		e := Bit_Emitter_Lsb{out = &z}
		lsb_emit(&e, 1, 1) // BFINAL=1
		lsb_emit(&e, 1, 2) // Fixed Huffman
		// Emit length 3 (sym 257, 7-bit code 1) with distance 1 (dist sym 0) at byte 0!
		lsb_emit_huff(&e, 1, 7)
		lsb_emit_huff(&e, 0, 5)
		lsb_emit_huff(&e, 0, 7) // EOB
		lsb_flush(&e)
		append_u32_be(&z, 1)
		p := make([dynamic]u8, 0, 64)
		defer delete(p)
		sig := PNG_SIGNATURE
		append(&p, ..sig[:])
		ihdr: [13]u8
		byte_order.write_u32_big_endian(ihdr[:], 0, 1)
		byte_order.write_u32_big_endian(ihdr[:], 4, 1)
		ihdr[8] = 8
		ihdr[9] = 6
		append_png_chunk(&p, {'I', 'H', 'D', 'R'}, ihdr[:])
		append_png_chunk(&p, {'I', 'D', 'A', 'T'}, z[:])
		append_png_chunk(&p, {'I', 'E', 'N', 'D'}, nil)
		expect_refusal(t, "PNG DEFLATE distance before start", p[:], out, scratch, .Corrupt_Stream)
	}

	// JPEG oversubscribed DHT table (3 symbols of 1-bit length!)
	{
		bad_dht := [?]u8{
			0xFF, 0xD8,
			0xFF, 0xC4, 0x00, 22,
			0x00,
			3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 1, 2,
			0xFF, 0xD9,
		}
		expect_refusal(t, "JPEG oversubscribed DHT", bad_dht[:], out, scratch, .Corrupt_Stream)
	}

	// JPEG 16-bit DQT precision unsupported
	{
		dqt16 := make([dynamic]u8, 0, 140)
		defer delete(dqt16)
		append(&dqt16, 0xFF, 0xD8, 0xFF, 0xDB)
		append_u16_be(&dqt16, 131)
		append(&dqt16, 0x10) // Pq=1 (16-bit), Tq=0
		for _ in 0 ..< 128 {
			append(&dqt16, 0x01)
		}
		append(&dqt16, 0xFF, 0xD9)
		expect_refusal(t, "JPEG 16-bit DQT unsupported", dqt16[:], out, scratch, .Unsupported_Variant)
	}

	// JPEG malformed Huffman code inside SOS scan (only 1-bit code 0 defined, scan feeds 0xFF 0x00 -> all 1s!)
	{
		bad_huff_scan := make([dynamic]u8, 0, 160)
		defer delete(bad_huff_scan)
		append(&bad_huff_scan, 0xFF, 0xD8)
		// DQT 0
		append(&bad_huff_scan, 0xFF, 0xDB)
		append_u16_be(&bad_huff_scan, 67)
		append(&bad_huff_scan, 0x00)
		for _ in 0 ..< 64 {
			append(&bad_huff_scan, 1)
		}
		// DHT: DC 0 has only 1 symbol (cat 0, code '0'); AC 0 has only EOB (0x00, code '0')
		append(&bad_huff_scan, 0xFF, 0xC4)
		append_u16_be(&bad_huff_scan, 2 + 18 + 18)
		append(&bad_huff_scan, 0x00, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x00)
		append(&bad_huff_scan, 0x10, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x00)
		// SOF0 8x8 grayscale
		append(&bad_huff_scan, 0xFF, 0xC0, 0x00, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0)
		// SOS
		append(&bad_huff_scan, 0xFF, 0xDA, 0x00, 8, 1, 1, 0x00, 0, 63, 0)
		// Stuffed 0xFF byte: bit '1' matches no code in DC table!
		append(&bad_huff_scan, 0xFF, 0x00, 0xFF, 0xD9)
		expect_refusal(t, "JPEG malformed Huffman code in scan", bad_huff_scan[:], out, scratch, .Corrupt_Stream)
	}

	// JPEG corrupt restart marker (corrupt RST0 -> RST1 in a 2-MCU grayscale JPEG)
	{
		y16 := make([]u8, 16 * 8)
		defer delete(y16)
		jpg_rst := build_test_jpeg(16, 8, .Grayscale, y16, nil, nil, restart_interval = 1)
		defer delete(jpg_rst)
		// Find 0xFF 0xD0 (RST0) and flip it to 0xD1 (RST1)
		found_rst := false
		for i in 0 ..< len(jpg_rst) - 1 {
			if jpg_rst[i] == 0xFF && jpg_rst[i + 1] == 0xD0 {
				jpg_rst[i + 1] = 0xD1
				found_rst = true
				break
			}
		}
		testing.expect(t, found_rst, "test fixture must contain RST0")
		expect_refusal(t, "JPEG wrong restart marker", jpg_rst[:], out, scratch, .Corrupt_Stream)
	}
}

// ---------------------------------------------------------------------------
// 7. Opt-in SIMD throughput benchmarks (-define:MEASURE=true)
// ---------------------------------------------------------------------------

@(test)
image_decode_simd_throughput_measure :: proc(t: ^testing.T) {
	if !MEASURE_CODECS {
		return
	}
	when ODIN_ARCH == .amd64 {
		RUNS :: 5
		rng := Test_Rng{state = 99}

		// 1. PNG scanline unfilters (1024 RGBA pixels = 4096 bytes)
		ROW_BYTES :: 4096
		PNG_ITERS :: 8000
		raw := make([]u8, ROW_BYTES)
		prev := make([]u8, ROW_BYTES)
		dst_s := make([]u8, ROW_BYTES)
		dst_v := make([]u8, ROW_BYTES)
		defer delete(raw)
		defer delete(prev)
		defer delete(dst_s)
		defer delete(dst_v)
		for i in 0 ..< ROW_BYTES {
			raw[i] = u8(rng_next(&rng))
			prev[i] = u8(rng_next(&rng))
		}

		for filter in ([4]Png_Filter{.Up, .Sub, .Average, .Paeth}) {
			best_s := max(f64)
			best_v := max(f64)
			for _ in 0 ..< RUNS {
				t0 := time.tick_now()
				for _ in 0 ..< PNG_ITERS {
					png_unfilter_row_scalar(filter, dst_s, raw, prev, 4)
				}
				best_s = min(best_s, time.duration_seconds(time.tick_since(t0)))

				t1 := time.tick_now()
				for _ in 0 ..< PNG_ITERS {
					png_unfilter_row_simd(filter, dst_v, raw, prev, 4)
				}
				best_v = min(best_v, time.duration_seconds(time.tick_since(t1)))
			}
			testing.expect(t, slices_equal(dst_s, dst_v), "benchmark PNG filter mismatch")
			mib := f64(ROW_BYTES) * f64(PNG_ITERS) / f64(1 << 20)
			fmt.printfln(
				"image_decode: measure: png_unfilter %v (4096 B, bpp=4): scalar %.0f MiB/s, sse2 %.0f MiB/s, speedup %.2fx",
				filter,
				mib / best_s,
				mib / best_v,
				best_s / best_v,
			)
		}

		// 2. JPEG 8x8 2D IDCT (4096 blocks)
		BLOCKS :: 4096
		IDCT_ITERS :: 40
		blocks := make([][64]i32, BLOCKS)
		out_idct_s := make([][64]u8, BLOCKS)
		out_idct_v := make([][64]u8, BLOCKS)
		defer delete(blocks)
		defer delete(out_idct_s)
		defer delete(out_idct_v)
		for b in 0 ..< BLOCKS {
			for k in 0 ..< 64 {
				blocks[b][k] = i32(rng_next(&rng) % 512) - 256
			}
		}
		best_idct_s := max(f64)
		best_idct_v := max(f64)
		for _ in 0 ..< RUNS {
			t0 := time.tick_now()
			for _ in 0 ..< IDCT_ITERS {
				for b in 0 ..< BLOCKS {
					jpeg_idct_8x8_scalar(&blocks[b], &out_idct_s[b])
				}
			}
			best_idct_s = min(best_idct_s, time.duration_seconds(time.tick_since(t0)))

			t1 := time.tick_now()
			for _ in 0 ..< IDCT_ITERS {
				for b in 0 ..< BLOCKS {
					jpeg_idct_8x8_simd(&blocks[b], &out_idct_v[b])
				}
			}
			best_idct_v = min(best_idct_v, time.duration_seconds(time.tick_since(t1)))
		}
		for b in 0 ..< BLOCKS {
			testing.expect(t, out_idct_s[b] == out_idct_v[b], "benchmark IDCT mismatch")
		}
		total_blocks := f64(BLOCKS) * f64(IDCT_ITERS)
		fmt.printfln(
			"image_decode: measure: jpeg_idct_8x8: scalar %.1f ns/block, sse2 %.1f ns/block, speedup %.2fx",
			best_idct_s * 1e9 / total_blocks,
			best_idct_v * 1e9 / total_blocks,
			best_idct_s / best_idct_v,
		)

		// 3. JPEG YCbCr -> RGBA (1920 pixels)
		PIXELS :: 1920
		YCC_ITERS :: 10000
		y_row := make([]u8, PIXELS)
		cb_row := make([]u8, PIXELS)
		cr_row := make([]u8, PIXELS)
		rgba_s := make([]u8, PIXELS * 4)
		rgba_v := make([]u8, PIXELS * 4)
		defer delete(y_row)
		defer delete(cb_row)
		defer delete(cr_row)
		defer delete(rgba_s)
		defer delete(rgba_v)
		for i in 0 ..< PIXELS {
			y_row[i] = u8(rng_next(&rng))
			cb_row[i] = u8(rng_next(&rng))
			cr_row[i] = u8(rng_next(&rng))
		}
		best_ycc_s := max(f64)
		best_ycc_v := max(f64)
		for _ in 0 ..< RUNS {
			t0 := time.tick_now()
			for _ in 0 ..< YCC_ITERS {
				jpeg_ycbcr_to_rgba_row_scalar(raw_data(y_row), raw_data(cb_row), raw_data(cr_row), raw_data(rgba_s), PIXELS)
			}
			best_ycc_s = min(best_ycc_s, time.duration_seconds(time.tick_since(t0)))

			t1 := time.tick_now()
			for _ in 0 ..< YCC_ITERS {
				jpeg_ycbcr_to_rgba_row_simd(raw_data(y_row), raw_data(cb_row), raw_data(cr_row), raw_data(rgba_v), PIXELS)
			}
			best_ycc_v = min(best_ycc_v, time.duration_seconds(time.tick_since(t1)))
		}
		testing.expect(t, slices_equal(rgba_s, rgba_v), "benchmark YCbCr mismatch")
		ycc_mib := f64(PIXELS * 4) * f64(YCC_ITERS) / f64(1 << 20)
		fmt.printfln(
			"image_decode: measure: jpeg_ycbcr_to_rgba (1920 px): scalar %.0f MiB/s, sse2 %.0f MiB/s, speedup %.2fx",
			ycc_mib / best_ycc_s,
			ycc_mib / best_ycc_v,
			best_ycc_s / best_ycc_v,
		)
	}
}
