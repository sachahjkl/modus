#+build !freestanding
package terminal_records

import "core:testing"

// The parts of an edit line: past the limit first (a part that passes it
// is cut after a whole character, and the line keeps what came before),
// then the empty line, then parts in order, and the staging empty after
// the end of a line.
@(test)
edit_staging_keeps_the_parts_in_order_and_cuts_past_the_limit :: proc(t: ^testing.T) {
	staging := new(Edit_Staging)
	defer free(staging)
	text := new([EDIT_TEXT_LIMIT]u8)
	defer free(text)
	part := make([]u8, RUN_LIMIT)
	defer delete(part)
	for &b in part {
		b = 'a'
	}
	for _ in 0 ..< EDIT_TEXT_LIMIT / RUN_LIMIT - 1 {
		edit_part_keep(staging, part, nil)
	}
	// The last record: an é across the limit.
	last := make([]u8, RUN_LIMIT + 1)
	defer delete(last)
	for &b in last {
		b = 'b'
	}
	last[RUN_LIMIT - 1], last[RUN_LIMIT] = 0xC3, 0xA9
	length := edit_staging_end(staging, last[:RUN_LIMIT - 1], last[RUN_LIMIT - 1:], text)
	testing.expect_value(t, length, EDIT_TEXT_LIMIT - 1)
	testing.expect_value(t, text[length - 1], u8('b'))
	testing.expect_value(t, staging.length, 0)
	testing.expect(t, !staging.cut)

	// One part more than the limit: the bytes past it are not kept.
	for _ in 0 ..< EDIT_TEXT_LIMIT / RUN_LIMIT + 1 {
		edit_part_keep(staging, part, nil)
	}
	testing.expect_value(t, staging.length, EDIT_TEXT_LIMIT)
	testing.expect(t, staging.cut)
	testing.expect_value(t, edit_staging_end(staging, nil, nil, text), EDIT_TEXT_LIMIT)

	// No part: the text of the Edit record alone; then parts in order.
	testing.expect_value(t, edit_staging_end(staging, nil, nil, text), 0)
	edit_part_keep(staging, transmute([]u8)string("> one "), transmute([]u8)string("two "))
	length = edit_staging_end(staging, transmute([]u8)string("three"), nil, text)
	testing.expect_value(t, string(text[:length]), "> one two three")
	// A damaged length from the memory of the reader is brought back.
	staging.length = -5
	edit_part_keep(staging, transmute([]u8)string("x"), nil)
	testing.expect_value(t, staging.length, 1)
}
