// The TCP library: TCP in the process that uses it, so that the kernel is
// not on the path of the data (docs/NETWORK.md). This file: the numbers of
// TCP, the order of sequence numbers, and the header of a segment.
//
// A segment is the bytes of TCP: the header, its options and the data,
// with no IPv4 header. Numbers are in the order of the machine; a segment
// holds them in network order (the first byte is the high byte). An IPv4
// address is a u32: 10.0.2.15 is 0x0A00020F.
package tcp

import "modus:contract/byte_order"

PROTOCOL :: 6 // The protocol number of TCP in the IPv4 header.
HEADER :: 20 // The header with no option.
HEADER_MSS :: 24 // The header with the MSS option.
HEADER_SYN :: 28 // The header with the MSS option, a no-operation and the window scale option: each SYN that this library sends.
SEGMENT_LIMIT :: 1480 // One frame of Ethernet (1500 bytes of IPv4) less the IPv4 header.
MSS_LOCAL :: 1460 // The MSS that this library gives: SEGMENT_LIMIT less the header.
MSS_DEFAULT :: 536 // The MSS of a remote that gave no MSS option (RFC 9293 3.7.1).
WINDOW_LIMIT :: 65535 // The largest window field. With window scaling, the window is the field shifted left by the scale of its sender.
// The largest shift of a window scale (RFC 7323, section 2.3): a window of
// about 1 GiB, which the sequence numbers still order.
WINDOW_SCALE_LIMIT :: 14

// A control bit of a segment (RFC 9293, section 3.1).
Flag :: enum u8 {
	Fin = 0, // The sender has no more data.
	Syn = 1, // Synchronize the sequence numbers: the first segment of each side.
	Rst = 2, // Reset the connection.
	Psh = 3, // Push: give the data to the process now.
	Ack = 4, // The acknowledgment number is valid.
	Urg = 5, // Urgent data: this library ignores it.
	Ece = 6, // ECN echo: this library ignores it.
	Cwr = 7, // Congestion window reduced: this library ignores it.
}
Flags :: bit_set[Flag;u8] // The byte 13 of the header.

// Header is what header_read found in a segment. data is a part of the segment.
Header :: struct {
	source_port:      u16, // The TCP port of the sender.
	destination_port: u16, // The TCP port of the receiver.
	sequence:         u32, // The sequence number of the first byte of data, or of the SYN.
	acknowledgment:   u32, // The next sequence number that the sender expects, with Ack.
	flags:            Flags, // The control bits.
	window:           u16, // The window field: the bytes that the sender can receive after `acknowledgment`, shifted right by its window scale (never in a SYN).
	mss:              u16, // The MSS option. 0: the segment has none.
	window_scale:     u8, // The window scale option: the shift of the windows of its sender, at most WINDOW_SCALE_LIMIT.
	has_window_scale: bool, // The segment has the window scale option.
	data:             []u8, // The data of the segment, after the header.
}

// The order of sequence numbers is modulo 2^32 (RFC 9293 3.4): a is before
// b when b - a, as a signed number of 32 bits, is positive. The comparison
// holds for two numbers that are less than 2^31 apart.
before :: #force_inline proc "contextless" (a, b: u32) -> bool {
	return i32(a - b) < 0
}

// after says if a is after b.
after :: #force_inline proc "contextless" (a, b: u32) -> bool {
	return i32(a - b) > 0
}

// before_or_same says if a is before b or is b.
before_or_same :: #force_inline proc "contextless" (a, b: u32) -> bool {
	return i32(a - b) <= 0
}

// after_or_same says if a is after b or is b.
after_or_same :: #force_inline proc "contextless" (a, b: u32) -> bool {
	return i32(a - b) >= 0
}

// inside says if value is in [first, first + count).
inside :: #force_inline proc "contextless" (value, first, count: u32) -> bool {
	return value - first < count
}

// checksum gives the checksum of a segment from source to destination, with
// its checksum field taken as zero.
checksum :: proc "contextless" (source, destination: u32, segment: []u8) -> u16 {
	pseudo_header := byte_order.internet_checksum_pseudo_header(source, destination, PROTOCOL, len(segment))
	return byte_order.internet_checksum_end(byte_order.internet_checksum_add(byte_order.internet_checksum_add(pseudo_header, segment[:16]), segment[18:]))
}

// checksum_valid says if a segment from source to destination holds its
// checksum, over the pseudo-header of the two addresses, the header and
// the data. The network service does not check it: it finds the endpoint
// by the port and copies the segment. `step` calls this for each segment
// that arrives, and drops a segment with a wrong checksum.
checksum_valid :: proc "contextless" (source, destination: u32, segment: []u8) -> bool {
	if len(segment) < HEADER {
		return false
	}
	pseudo_header := byte_order.internet_checksum_pseudo_header(source, destination, PROTOCOL, len(segment))
	return byte_order.internet_checksum_end(byte_order.internet_checksum_add(pseudo_header, segment)) == 0
}

// header_read reads the header of a segment. ok is false when the segment
// is shorter than its header, or when its data offset or an option breaks a
// rule. An option that the library does not know is passed over.
header_read :: proc "contextless" (segment: []u8) -> (header: Header, ok: bool) {
	if len(segment) < HEADER {
		return {}, false
	}
	offset := int(segment[12] >> 4) * 4
	if offset < HEADER || offset > len(segment) {
		return {}, false
	}
	header.source_port = byte_order.read_u16_big_endian(segment, 0)
	header.destination_port = byte_order.read_u16_big_endian(segment, 2)
	header.sequence = byte_order.read_u32_big_endian(segment, 4)
	header.acknowledgment = byte_order.read_u32_big_endian(segment, 8)
	header.flags = transmute(Flags)segment[13]
	header.window = byte_order.read_u16_big_endian(segment, 14)
	header.data = segment[offset:]
	options := segment[HEADER:offset]
	for place := 0; place < len(options); {
		kind := options[place]
		if kind == 0 {
			break // The end of the options.
		}
		if kind == 1 {
			place += 1 // No operation.
			continue
		}
		if place + 1 >= len(options) {
			return {}, false
		}
		length := int(options[place + 1])
		if length < 2 || place + length > len(options) {
			return {}, false
		}
		if kind == 2 && length == 4 {
			header.mss = byte_order.read_u16_big_endian(options, place + 2)
		}
		if kind == 3 && length == 3 {
			// A shift past the limit is taken as the limit (RFC 7323,
			// section 2.3), so a window never passes 1 GiB.
			header.window_scale = min(options[place + 2], WINDOW_SCALE_LIMIT)
			header.has_window_scale = true
		}
		place += length
	}
	return header, true
}

// header_size gives the bytes of the header of a segment with its options:
// HEADER, 4 more for the MSS option, 4 more for a no-operation and the
// window scale option.
header_size :: proc "contextless" (header: Header) -> int {
	return HEADER + (header.mss != 0 ? 4 : 0) + (header.has_window_scale ? 4 : 0)
}

// window_scale_of_buffer gives the shift that a receive buffer needs so
// that its whole room fits the window field: the least shift whose window
// holds the buffer, at most WINDOW_SCALE_LIMIT.
window_scale_of_buffer :: proc "contextless" (receive_size: u32) -> u8 {
	shift: u8
	for shift < WINDOW_SCALE_LIMIT && u64(WINDOW_LIMIT) << shift < u64(receive_size) {
		shift += 1
	}
	return shift
}

// header_write writes the header of a segment whose data is already at
// segment[header_size(header):], and its checksum. length is the bytes of
// the whole segment.
header_write :: proc "contextless" (segment: []u8, source, destination: u32, header: Header, length: int) {
	offset := header_size(header)
	byte_order.write_u16_big_endian(segment, 0, header.source_port)
	byte_order.write_u16_big_endian(segment, 2, header.destination_port)
	byte_order.write_u32_big_endian(segment, 4, header.sequence)
	byte_order.write_u32_big_endian(segment, 8, header.acknowledgment)
	segment[12] = u8(offset / 4) << 4
	segment[13] = transmute(u8)header.flags
	byte_order.write_u16_big_endian(segment, 14, header.window)
	byte_order.write_u16_big_endian(segment, 16, 0)
	byte_order.write_u16_big_endian(segment, 18, 0) // No urgent data.
	option := HEADER
	if header.mss != 0 {
		segment[option] = 2
		segment[option + 1] = 4
		byte_order.write_u16_big_endian(segment, option + 2, header.mss)
		option += 4
	}
	if header.has_window_scale {
		segment[option] = 1 // A no-operation: the option of 3 bytes ends on a word.
		segment[option + 1] = 3
		segment[option + 2] = 3
		segment[option + 3] = min(header.window_scale, WINDOW_SCALE_LIMIT)
	}
	byte_order.write_u16_big_endian(segment, 16, checksum(source, destination, segment[:length]))
}
