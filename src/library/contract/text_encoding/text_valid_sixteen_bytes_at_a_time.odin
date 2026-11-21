// The vector form of the check of a text, sixteen bytes at a time
// (src/md/data/utf8_validation.md). The algorithm is the one of John Keiser
// and Daniel Lemire, "Validating UTF-8 In Less Than One Instruction Per
// Byte" (2021): each byte is checked against the one, two and three bytes
// before it, in lanes, with no branch for each character. The three table
// lookups of the paper become comparisons here, because a module is
// compiled for SSE2, which has no lookup of a byte in a table of 16: there
// each lookup becomes 16 loads of one byte.
//
// The source names no instruction and no target: each operation (compare,
// saturating subtraction, shuffle by constant places, the mask of bit 7)
// exists in each vector unit, so a later target compiles the same source.
// The kernel, which has no vector unit, calls none of it: the build refuses
// a vector instruction in the kernel.
package text_encoding

import "base:intrinsics"

Sixteen_Bytes :: #simd[16]u8

@(private = "file")
Sixteen_Signed_Bytes :: #simd[16]i8

// The bytes that a lead of 2, 3 or 4 bytes leaves to come, in bit 7 of a
// saturating subtraction: the last byte of a group from C0, the byte
// before it from E0, the byte before that from F0.
@(private = "file")
INCOMPLETE_SUBTRAHENDS :: Sixteen_Bytes{0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x70, 0x60, 0x40}

// text_valid_sixteen_bytes_at_a_time gives the answer of
// text_valid_byte_by_byte for every input. It reads each byte once, as
// character_decode does: the bytes can be in memory that another party
// writes. A group of the end that is shorter than sixteen bytes is copied
// into a group of spaces, a character of a text, so no load reads past the
// slice.
text_valid_sixteen_bytes_at_a_time :: proc "contextless" (bytes: []u8) -> bool {
	previous_group := Sixteen_Bytes(0)
	previous_incomplete := Sixteen_Bytes(0)
	place := 0
	for ; place + 16 <= len(bytes); place += 16 {
		group := intrinsics.unaligned_load((^Sixteen_Bytes)(&bytes[place]))
		errors := group_errors(group, previous_group, &previous_incomplete)
		// A text from another party can be long and wrong from its start:
		// the test of each group costs one compare of a mask and stops there.
		if intrinsics.simd_extract_msbs(errors) != {} {
			return false
		}
		previous_group = group
	}
	if place < len(bytes) {
		last_bytes: [16]u8 = ' '
		for value, index in bytes[place:] {
			last_bytes[index] = value
		}
		errors := group_errors(transmute(Sixteen_Bytes)last_bytes, previous_group, &previous_incomplete)
		return intrinsics.simd_extract_msbs(errors) == {}
	}
	return intrinsics.simd_extract_msbs(previous_incomplete) == {}
}

// group_errors gives a group whose bit 7 is set in each lane where a byte
// breaks the rule, given the group before it. Only bit 7 of each lane has a
// meaning. previous_incomplete holds, for the group before, the leads that
// wait for bytes past it; it gets the leads of this group.
@(private = "file")
group_errors :: #force_inline proc "contextless" (group, previous_group: Sixteen_Bytes, previous_incomplete: ^Sixteen_Bytes) -> Sixteen_Bytes {
	controls := control_bytes(group)
	if intrinsics.simd_extract_msbs(group) == {} {
		// A group of ASCII has no lead and no continuation: only a lead at
		// the end of the group before can be cut short here.
		errors := intrinsics.simd_bit_or(controls, previous_incomplete^)
		previous_incomplete^ = 0
		return errors
	}
	one_before := intrinsics.simd_shuffle(previous_group, group, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30)
	two_before := intrinsics.simd_shuffle(previous_group, group, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29)
	three_before := intrinsics.simd_shuffle(previous_group, group, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28)

	// A continuation is 10xxxxxx. The addition moves bit 6 to bit 7, so bit
	// 7 of the result is set for a continuation alone.
	continuation := intrinsics.simd_bit_and_not(group, group + group)
	// A byte must be a continuation after a lead of 2, 3 or 4 bytes. The
	// saturating subtraction puts each answer in bit 7: a byte from C0 minus
	// 40 is 80 or more, a smaller byte gives less than 80.
	expected := intrinsics.simd_bit_or(
		intrinsics.simd_saturating_sub(one_before, Sixteen_Bytes(0xC0 - 0x80)),
		intrinsics.simd_bit_or(
			intrinsics.simd_saturating_sub(two_before, Sixteen_Bytes(0xE0 - 0x80)),
			intrinsics.simd_saturating_sub(three_before, Sixteen_Bytes(0xF0 - 0x80)),
		),
	)
	// A lone continuation, a lead cut short, and a fifth byte.
	count_errors := intrinsics.simd_bit_xor(continuation, expected)

	// C0 and C1 start only overlong forms, F5 to FF only code points past
	// U+10FFFF or no UTF-8.
	no_lead := intrinsics.simd_bit_or(
		lanes_equal(intrinsics.simd_bit_and(group, Sixteen_Bytes(0xFE)), 0xC0),
		intrinsics.simd_saturating_sub(group, Sixteen_Bytes(0xF5 - 0x80)),
	)

	// The bounds of the second byte. After a lead, a byte that is no
	// continuation is a count error already, so a signed compare, one
	// instruction of SSE2, is enough: as signed bytes, 80 to 9F are below
	// A0 and 80 to 8F below 90. C2 80 to C2 9F are U+0080 to U+009F, the
	// controls of C1.
	below_a0_bytes := intrinsics.simd_lanes_lt(transmute(Sixteen_Signed_Bytes)group, Sixteen_Signed_Bytes(-0x60))
	below_90_bytes := intrinsics.simd_lanes_lt(transmute(Sixteen_Signed_Bytes)group, Sixteen_Signed_Bytes(-0x70))
	bound_errors := intrinsics.simd_bit_or(
		intrinsics.simd_bit_or(
			intrinsics.simd_bit_and(intrinsics.simd_bit_or(lanes_equal(one_before, 0xE0), lanes_equal(one_before, 0xC2)), below_a0_bytes),
			intrinsics.simd_bit_and_not(lanes_equal(one_before, 0xED), below_a0_bytes),
		),
		intrinsics.simd_bit_or(
			intrinsics.simd_bit_and(lanes_equal(one_before, 0xF0), below_90_bytes),
			intrinsics.simd_bit_and_not(lanes_equal(one_before, 0xF4), below_90_bytes),
		),
	)

	previous_incomplete^ = intrinsics.simd_saturating_sub(group, INCOMPLETE_SUBTRAHENDS)
	return intrinsics.simd_bit_or(intrinsics.simd_bit_or(count_errors, no_lead), intrinsics.simd_bit_or(bound_errors, controls))
}

// control_bytes sets each lane that holds a control character of one byte:
// 00 to 1F and 7F.
@(private = "file")
control_bytes :: #force_inline proc "contextless" (group: Sixteen_Bytes) -> Sixteen_Bytes {
	below_space := intrinsics.simd_lanes_le(group, Sixteen_Bytes(0x1F))
	return intrinsics.simd_bit_or(below_space, lanes_equal(group, 0x7F))
}

@(private = "file")
lanes_equal :: #force_inline proc "contextless" (group: Sixteen_Bytes, $VALUE: u8) -> Sixteen_Bytes {
	return intrinsics.simd_lanes_eq(group, Sixteen_Bytes(VALUE))
}
