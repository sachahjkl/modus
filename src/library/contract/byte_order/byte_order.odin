// The reads and writes of a number in a byte order, and the checksum of the
// Internet (RFC 1071).
//
// This package has no party: it is pure code that many packages share. It
// is under contract so that every folder of the library can import it: a
// contract package imports no support package, and the kernel imports the
// contract packages only (docs/TOOLS.md, "The imports of the sources of the
// system"). One copy of each shift leaves one place for a fault of a shift.
//
// Each procedure takes a slice and the offset of the first byte. A slice
// shorter than the offset and the size stops the process on the check of
// the bounds of the slice: the caller checks its lengths first, as each
// reader of a header does.
package byte_order

// read_u16_big_endian reads a number of 16 bits in network order: the most
// significant byte first.
read_u16_big_endian :: #force_inline proc "contextless" (bytes: []u8, offset: int) -> u16 {
	return u16(bytes[offset]) << 8 | u16(bytes[offset + 1])
}

// read_u32_big_endian reads a number of 32 bits in network order.
read_u32_big_endian :: #force_inline proc "contextless" (bytes: []u8, offset: int) -> u32 {
	return u32(bytes[offset]) << 24 | u32(bytes[offset + 1]) << 16 | u32(bytes[offset + 2]) << 8 | u32(bytes[offset + 3])
}

// read_u64_big_endian reads a number of 64 bits in network order.
read_u64_big_endian :: #force_inline proc "contextless" (bytes: []u8, offset: int) -> u64 {
	return u64(read_u32_big_endian(bytes, offset)) << 32 | u64(read_u32_big_endian(bytes, offset + 4))
}

// write_u16_big_endian writes a number of 16 bits in network order.
write_u16_big_endian :: #force_inline proc "contextless" (bytes: []u8, offset: int, value: u16) {
	bytes[offset] = u8(value >> 8)
	bytes[offset + 1] = u8(value)
}

// write_u32_big_endian writes a number of 32 bits in network order.
write_u32_big_endian :: #force_inline proc "contextless" (bytes: []u8, offset: int, value: u32) {
	bytes[offset] = u8(value >> 24)
	bytes[offset + 1] = u8(value >> 16)
	bytes[offset + 2] = u8(value >> 8)
	bytes[offset + 3] = u8(value)
}

// write_u64_big_endian writes a number of 64 bits in network order.
write_u64_big_endian :: #force_inline proc "contextless" (bytes: []u8, offset: int, value: u64) {
	write_u32_big_endian(bytes, offset, u32(value >> 32))
	write_u32_big_endian(bytes, offset + 4, u32(value))
}

// read_u16_little_endian reads a number of 16 bits, the least significant
// byte first.
read_u16_little_endian :: #force_inline proc "contextless" (bytes: []u8, offset: int) -> u16 {
	return u16(bytes[offset]) | u16(bytes[offset + 1]) << 8
}

// read_u32_little_endian reads a number of 32 bits, the least significant
// byte first.
read_u32_little_endian :: #force_inline proc "contextless" (bytes: []u8, offset: int) -> u32 {
	return u32(bytes[offset]) | u32(bytes[offset + 1]) << 8 | u32(bytes[offset + 2]) << 16 | u32(bytes[offset + 3]) << 24
}

// read_u64_little_endian reads a number of 64 bits, the least significant
// byte first.
read_u64_little_endian :: #force_inline proc "contextless" (bytes: []u8, offset: int) -> u64 {
	return u64(read_u32_little_endian(bytes, offset)) | u64(read_u32_little_endian(bytes, offset + 4)) << 32
}

// write_u16_little_endian writes a number of 16 bits, the least significant
// byte first.
write_u16_little_endian :: #force_inline proc "contextless" (bytes: []u8, offset: int, value: u16) {
	bytes[offset] = u8(value)
	bytes[offset + 1] = u8(value >> 8)
}

// write_u32_little_endian writes a number of 32 bits, the least significant
// byte first.
write_u32_little_endian :: #force_inline proc "contextless" (bytes: []u8, offset: int, value: u32) {
	bytes[offset] = u8(value)
	bytes[offset + 1] = u8(value >> 8)
	bytes[offset + 2] = u8(value >> 16)
	bytes[offset + 3] = u8(value >> 24)
}

// write_u64_little_endian writes a number of 64 bits, the least significant
// byte first.
write_u64_little_endian :: #force_inline proc "contextless" (bytes: []u8, offset: int, value: u64) {
	write_u32_little_endian(bytes, offset, u32(value))
	write_u32_little_endian(bytes, offset + 4, u32(value >> 32))
}

// internet_checksum_add adds bytes, as 16-bit words in network order, to the
// sum of a checksum of the Internet (RFC 1071). An odd last byte is the high
// byte of a word. The sum is not folded: a caller adds the parts of a
// checksum (a pseudo-header, then a header, then the data) and ends it once
// with internet_checksum_end. A part with an odd count of bytes is the last
// part. 64 bits hold the sum of 2^48 words with no carry lost.
internet_checksum_add :: proc "contextless" (total: u64, bytes: []u8) -> u64 {
	total := total
	count := len(bytes)
	index := 0
	for ; index + 1 < count; index += 2 {
		total += u64(bytes[index]) << 8 | u64(bytes[index + 1])
	}
	if index < count {
		total += u64(bytes[index]) << 8
	}
	return total
}

// internet_checksum_end folds a sum to 16 bits with its carries and gives
// its complement: the value of the checksum field. Over bytes that hold
// their own checksum, it gives 0.
internet_checksum_end :: proc "contextless" (total: u64) -> u16 {
	total := total
	for total > 0xFFFF {
		total = (total & 0xFFFF) + (total >> 16)
	}
	return ~u16(total)
}

// internet_checksum_pseudo_header gives the sum of the pseudo-header of UDP
// or of TCP over IPv4 (RFC 768, RFC 9293, section 3.1): the two addresses,
// the protocol and the length of the datagram or of the segment.
internet_checksum_pseudo_header :: proc "contextless" (source, destination: u32, protocol: u8, length: int) -> u64 {
	return u64(source >> 16) + u64(source & 0xFFFF) + u64(destination >> 16) + u64(destination & 0xFFFF) + u64(protocol) + u64(length)
}
