#+build !freestanding
package entropy_service

import "core:testing"

// The bytes of a read go through the values of a completion and come back
// the same, in order, for each count up to the limit.
@(test)
bytes_of_a_read_come_back_in_order :: proc(t: ^testing.T) {
	sent: [READ_BYTES_LIMIT]u8
	for &byte, index in sent {
		byte = u8(index * 7 + 1)
	}
	for count in 0 ..= READ_BYTES_LIMIT {
		values := bytes_pack(sent[:count])
		testing.expect_value(t, values[0], u64(count))
		received: [READ_BYTES_LIMIT]u8
		testing.expect_value(t, bytes_unpack(values, &received), count)
		testing.expect(t, string(received[:count]) == string(sent[:count]))
	}
}

// A count from the service above the limit gives the limit: the client
// never reads past the six values of the bytes.
@(test)
a_count_above_the_limit_gives_the_limit :: proc(t: ^testing.T) {
	values := bytes_pack(nil)
	values[0] = READ_BYTES_LIMIT + 1
	received: [READ_BYTES_LIMIT]u8
	testing.expect_value(t, bytes_unpack(values, &received), READ_BYTES_LIMIT)
	values[0] = max(u64)
	testing.expect_value(t, bytes_unpack(values, &received), READ_BYTES_LIMIT)
	// A pack of more bytes than the limit takes the limit.
	more: [READ_BYTES_LIMIT + 8]u8
	testing.expect_value(t, bytes_pack(more[:])[0], u64(READ_BYTES_LIMIT))
}
