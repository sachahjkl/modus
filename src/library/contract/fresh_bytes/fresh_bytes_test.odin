#+build !freestanding
package fresh_bytes

import op "modus:contract/operation"
import "modus:contract/fixed_addresses"
import "core:testing"

test_bytes :: proc(first: u8) -> (bytes: [BYTES]u8) {
	for &byte, index in bytes {
		byte = first + u8(index)
	}
	return
}

// A write gives its bytes once: the reader that mixed the change count of
// a write reads nothing until the next write, and the next write gives its
// own bytes.
@(test)
a_write_is_read_once :: proc(t: ^testing.T) {
	page := new(Page)
	defer free(page)
	_, count, fresh := read(page, 0)
	testing.expect(t, !fresh)
	testing.expect_value(t, count, u32(0))
	first := test_bytes(1)
	write(page, &first)
	testing.expect_value(t, page.change_count, u32(CHANGE_STEP))
	bytes: [BYTES]u8
	bytes, count, fresh = read(page, 0)
	testing.expect(t, fresh)
	testing.expect_value(t, count, u32(CHANGE_STEP))
	testing.expect_value(t, bytes, test_bytes(1))
	// The same change again: nothing new.
	_, count, fresh = read(page, count)
	testing.expect(t, !fresh)
	testing.expect_value(t, count, u32(CHANGE_STEP))
	second := test_bytes(100)
	write(page, &second)
	bytes, count, fresh = read(page, count)
	testing.expect(t, fresh)
	testing.expect_value(t, count, u32(2 * CHANGE_STEP))
	testing.expect_value(t, bytes, test_bytes(100))
	// No page: nothing.
	_, _, fresh = read(nil, 0)
	testing.expect(t, !fresh)
}

// A page that the root service left in the middle of a change gives no
// bytes: the reader stops after its tries, and does not wait.
@(test)
a_change_in_progress_gives_nothing :: proc(t: ^testing.T) {
	page := new(Page)
	defer free(page)
	bytes := test_bytes(7)
	write(page, &bytes)
	page.change_count += 1
	_, count, fresh := read(page, 0)
	testing.expect(t, !fresh)
	testing.expect_value(t, count, u32(0))
}

// A clear makes the page of a new program: no bytes, the change count 0,
// so the new program reads nothing that the program before it read.
@(test)
a_clear_gives_no_bytes :: proc(t: ^testing.T) {
	page := new(Page)
	defer free(page)
	bytes := test_bytes(9)
	write(page, &bytes)
	clear(page)
	testing.expect_value(t, page.change_count, u32(0))
	testing.expect_value(t, page.bytes, [WORDS]u64{})
	_, _, fresh := read(page, 0)
	testing.expect(t, !fresh)
}

// The page of a program is at its fixed range only when the bit of the
// range is set.
@(test)
the_page_of_a_program :: proc(t: ^testing.T) {
	ctx: op.Context
	testing.expect(t, page_of(&ctx) == nil)
	fixed_addresses.range_mapped_add(&ctx.values, .Fresh_Bytes_Page)
	testing.expect(t, uintptr(page_of(&ctx)) == uintptr(PAGE_ADDRESS))
}
