#+build !freestanding
#+build !modus
package quic

import "core:testing"

@(test)
an_identifier_over_the_limit_is_refused :: proc(t: ^testing.T) {
	// One byte over the limit, and far over it: no identifier is cut.
	one_over: [CONNECTION_ID_LIMIT + 1]u8
	for &value in one_over {
		value = 0xAB
	}
	identifier, made := connection_identifier_make(one_over[:])
	testing.expect(t, !made, "21 bytes make no identifier")
	testing.expect_value(t, identifier, Connection_Identifier{})
	far_over: [255]u8
	identifier, made = connection_identifier_make(far_over[:])
	testing.expect(t, !made, "255 bytes, the most that a length byte names, make no identifier")
	testing.expect_value(t, identifier, Connection_Identifier{})
}

@(test)
the_edges_of_an_identifier :: proc(t: ^testing.T) {
	// 0 bytes: the empty identifier, which is the zero record.
	empty, empty_made := connection_identifier_make(nil)
	testing.expect(t, empty_made)
	testing.expect_value(t, empty, Connection_Identifier{})
	testing.expect_value(t, len(connection_identifier_bytes(&empty)), 0)
	// 1 byte, and the limit.
	one, one_made := connection_identifier_make([]u8{0x5A})
	testing.expect(t, one_made)
	testing.expect_value(t, one.length, 1)
	testing.expect_value(t, connection_identifier_bytes(&one)[0], 0x5A)
	whole: [CONNECTION_ID_LIMIT]u8
	for &value, index in whole {
		value = u8(index + 1)
	}
	limit, limit_made := connection_identifier_make(whole[:])
	testing.expect(t, limit_made)
	testing.expect_value(t, int(limit.length), CONNECTION_ID_LIMIT)
	testing.expect_value(t, string(connection_identifier_bytes(&limit)), string(whole[:]))
}

@(test)
the_bytes_after_the_length_are_zero :: proc(t: ^testing.T) {
	// The record of a short identifier compares equal to one made again from
	// the same bytes, and differs from a longer one with the same start: so
	// `==` is the equality of the identifiers.
	identifier, _ := connection_identifier_make([]u8{1, 2, 3})
	for value in identifier.bytes[identifier.length:] {
		testing.expect_value(t, value, 0)
	}
	again, _ := connection_identifier_make([]u8{1, 2, 3})
	testing.expect(t, identifier == again)
	longer, _ := connection_identifier_make([]u8{1, 2, 3, 0})
	testing.expect(t, identifier != longer, "a trailing zero byte is a byte of the identifier")
	empty: Connection_Identifier
	zero, _ := connection_identifier_make([]u8{0})
	testing.expect(t, empty != zero, "the identifier of one zero byte is not the empty identifier")
}

@(test)
an_identifier_that_this_side_chose :: proc(t: ^testing.T) {
	chosen := [CONNECTION_ID_SIZE]u8{8, 7, 6, 5, 4, 3, 2, 1}
	identifier := connection_identifier_of_chosen(chosen)
	made, _ := connection_identifier_make(chosen[:])
	testing.expect(t, identifier == made)
	testing.expect_value(t, int(identifier.length), CONNECTION_ID_SIZE)
}
