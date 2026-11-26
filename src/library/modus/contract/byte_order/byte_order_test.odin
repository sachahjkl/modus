#+build !freestanding
#+build !modus
package byte_order

import "core:testing"

// A write touches its own bytes only: the bytes before and after keep their
// value. The guard byte is a value that no write of the cases puts there.
@(private = "file")
GUARD :: u8(0xA5)
@(private = "file")
BUFFER_SIZE :: 12

@(private = "file")
guarded :: proc() -> (buffer: [BUFFER_SIZE]u8) {
	for &byte_of_buffer in buffer {
		byte_of_buffer = GUARD
	}
	return
}

@(private = "file")
expect_guards :: proc(t: ^testing.T, buffer: []u8, first, count: int, location := #caller_location) {
	for value, index in buffer {
		if index < first || index >= first + count {
			testing.expect_value(t, value, GUARD, loc = location)
		}
	}
}

@(test)
the_edges_of_the_values_in_each_order :: proc(t: ^testing.T) {
	// 0, 1, the largest value, and a value whose bytes all differ, at the
	// offset 0 and at the last offset where the number fits.
	values_16 := [?]u16{0, 1, max(u16), 0x0102}
	values_32 := [?]u32{0, 1, max(u32), 0x0102_0304}
	values_64 := [?]u64{0, 1, max(u64), 0x0102_0304_0506_0708}
	offsets_16 := [?]int{0, BUFFER_SIZE - 2}
	offsets_32 := [?]int{0, BUFFER_SIZE - 4}
	offsets_64 := [?]int{0, BUFFER_SIZE - 8}
	for value in values_16 {
		for offset in offsets_16 {
			buffer := guarded()
			write_u16_big_endian(buffer[:], offset, value)
			testing.expect_value(t, read_u16_big_endian(buffer[:], offset), value)
			expect_guards(t, buffer[:], offset, 2)
			buffer = guarded()
			write_u16_little_endian(buffer[:], offset, value)
			testing.expect_value(t, read_u16_little_endian(buffer[:], offset), value)
			expect_guards(t, buffer[:], offset, 2)
		}
	}
	for value in values_32 {
		for offset in offsets_32 {
			buffer := guarded()
			write_u32_big_endian(buffer[:], offset, value)
			testing.expect_value(t, read_u32_big_endian(buffer[:], offset), value)
			expect_guards(t, buffer[:], offset, 4)
			buffer = guarded()
			write_u32_little_endian(buffer[:], offset, value)
			testing.expect_value(t, read_u32_little_endian(buffer[:], offset), value)
			expect_guards(t, buffer[:], offset, 4)
		}
	}
	for value in values_64 {
		for offset in offsets_64 {
			buffer := guarded()
			write_u64_big_endian(buffer[:], offset, value)
			testing.expect_value(t, read_u64_big_endian(buffer[:], offset), value)
			expect_guards(t, buffer[:], offset, 8)
			buffer = guarded()
			write_u64_little_endian(buffer[:], offset, value)
			testing.expect_value(t, read_u64_little_endian(buffer[:], offset), value)
			expect_guards(t, buffer[:], offset, 8)
		}
	}
}

@(test)
the_place_of_each_byte :: proc(t: ^testing.T) {
	// A read and a write that agree with each other but both reverse the
	// bytes pass the case above: this case names each byte.
	bytes := [8]u8{0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08}
	testing.expect_value(t, read_u16_big_endian(bytes[:], 0), 0x0102)
	testing.expect_value(t, read_u16_little_endian(bytes[:], 0), 0x0201)
	testing.expect_value(t, read_u32_big_endian(bytes[:], 0), 0x0102_0304)
	testing.expect_value(t, read_u32_little_endian(bytes[:], 0), 0x0403_0201)
	testing.expect_value(t, read_u64_big_endian(bytes[:], 0), 0x0102_0304_0506_0708)
	testing.expect_value(t, read_u64_little_endian(bytes[:], 0), 0x0807_0605_0403_0201)
	// The offset moves the window: one byte later, each number starts at 0x02.
	testing.expect_value(t, read_u16_big_endian(bytes[:], 1), 0x0203)
	testing.expect_value(t, read_u32_little_endian(bytes[:], 1), 0x0504_0302)
	written: [8]u8
	write_u32_big_endian(written[:], 0, 0x0102_0304)
	write_u32_little_endian(written[:], 4, 0x0807_0605)
	testing.expect_value(t, written, bytes)
	// A high bit in each byte: a shift of a signed value would spread it.
	high: [8]u8
	write_u64_big_endian(high[:], 0, 0x8081_8283_8485_8687)
	testing.expect_value(t, high, [8]u8{0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87})
	testing.expect_value(t, read_u16_big_endian(high[:], 0), 0x8081)
}

@(test)
the_checksum_of_nothing :: proc(t: ^testing.T) {
	testing.expect_value(t, internet_checksum_add(0, nil), 0)
	testing.expect_value(t, internet_checksum_add(0x1234, nil), 0x1234)
	testing.expect_value(t, internet_checksum_end(0), 0xFFFF)
	// One byte: the high byte of a word.
	testing.expect_value(t, internet_checksum_add(0, []u8{0xAB}), 0xAB00)
}

@(test)
the_fold_of_the_carries :: proc(t: ^testing.T) {
	// 0xFFFF and its carries: a sum of all ones is 0 as a checksum, and one
	// more fold of 0x1_0000 gives 1.
	testing.expect_value(t, internet_checksum_end(0xFFFF), 0)
	testing.expect_value(t, internet_checksum_end(0x1_0000), ~u16(1))
	testing.expect_value(t, internet_checksum_end(0x1_FFFE), 0) // 0xFFFE + 1 = 0xFFFF.
	// A carry that makes a new carry: 0xFFFF_FFFF folds to 0xFFFF + 0xFFFF
	// = 0x1_FFFE, then to 0xFFFF.
	testing.expect_value(t, internet_checksum_end(0xFFFF_FFFF), 0)
	// The largest sum: each fold keeps the value in one's complement.
	testing.expect_value(t, internet_checksum_end(max(u64)), 0)
	// Many words of all ones: the sum carries far past 16 bits.
	ones: [4096]u8
	for &value in ones {
		value = 0xFF
	}
	testing.expect_value(t, internet_checksum_end(internet_checksum_add(0, ones[:])), 0)
}

@(test)
the_known_answers :: proc(t: ^testing.T) {
	// The example of RFC 1071, section 3, and an IPv4 header with a correct
	// checksum, 0xB861, which sums to all ones.
	words := []u8{0x00, 0x01, 0xF2, 0x03, 0xF4, 0xF5, 0xF6, 0xF7}
	// The sum keeps its carries: the fold comes once, at the end. RFC 1071
	// gives 0x2DDF0 before its fold to 0xDDF2.
	testing.expect_value(t, internet_checksum_add(0, words), 0x2DDF0)
	testing.expect_value(t, internet_checksum_add(0x2DDF0, nil), 0x2DDF0)
	testing.expect_value(t, internet_checksum_end(internet_checksum_add(0, words)), 0x220D)
	header := []u8{0x45, 0x00, 0x00, 0x73, 0x00, 0x00, 0x40, 0x00, 0x40, 0x11, 0xB8, 0x61, 0xC0, 0xA8, 0x00, 0x01, 0xC0, 0xA8, 0x00, 0xC7}
	testing.expect_value(t, internet_checksum_end(internet_checksum_add(0, header)), 0)
	// The sum of parts is the sum of the whole when each part but the last
	// has an even count of bytes.
	parts := internet_checksum_add(internet_checksum_add(0, header[:10]), header[10:])
	testing.expect_value(t, parts, internet_checksum_add(0, header))
}

@(test)
the_pseudo_header :: proc(t: ^testing.T) {
	testing.expect_value(t, internet_checksum_pseudo_header(0, 0, 0, 0), 0)
	// Each address as its two words, the protocol and the length.
	testing.expect_value(t, internet_checksum_pseudo_header(0x0A00_020F, 0x0A00_0202, 17, 8), u64(0x0A00 + 0x020F + 0x0A00 + 0x0202 + 17 + 8))
	// The largest addresses: no word is lost to a carry before the fold.
	testing.expect_value(t, internet_checksum_pseudo_header(max(u32), max(u32), max(u8), 0xFFFF), u64(4 * 0xFFFF + 0xFF + 0xFFFF))
}
