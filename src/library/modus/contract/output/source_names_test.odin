#+build !freestanding
package output

import "core:testing"

// A page with each name written: the border gives both back, with their
// lengths, at the bound of 31 bytes and at 1 byte.
@(test)
the_names_of_a_source_come_back_through_the_page :: proc(t: ^testing.T) {
	page: [SOURCE_NAMES_PAGE_BYTES]u8
	long_name := "abcdefghijklmnopqrstuvwxyz01234"
	testing.expect(t, source_names_write(page[:], long_name, "l"))
	names, source_length, output_length, ok := source_names_of_page(page[:])
	testing.expect(t, ok)
	testing.expect_value(t, source_length, 31)
	testing.expect_value(t, output_length, 1)
	testing.expect_value(t, string(names.source[:source_length]), long_name)
	testing.expect_value(t, string(names.output[:output_length]), "l")
	// The terms before the names are not touched.
	for value in page[:SOURCE_NAMES_OFFSET] {
		testing.expect_value(t, value, 0)
	}
}

// The writer refuses a name of 0 bytes, of the whole field, with a space,
// with a control character or with a byte past ASCII, and a page smaller
// than one page; the page then stays as it was.
@(test)
a_name_that_the_border_refuses_is_never_written :: proc(t: ^testing.T) {
	page: [SOURCE_NAMES_PAGE_BYTES]u8
	bad_names := [?]string{"", "abcdefghijklmnopqrstuvwxyz012345", "a b", "a\x01", "caf\u00e9"}
	for bad in bad_names {
		testing.expectf(t, !source_names_write(page[:], bad, "log"), "source %q", bad)
		testing.expectf(t, !source_names_write(page[:], "server", bad), "output %q", bad)
	}
	for value in page {
		testing.expect_value(t, value, 0)
	}
	testing.expect(t, !source_names_write(page[:SOURCE_NAMES_PAGE_BYTES - 1], "server", "log"))
	_, _, _, small_ok := source_names_of_page(page[:SOURCE_NAMES_PAGE_BYTES - 1])
	testing.expect(t, !small_ok)
}

// The reader refuses a page with no names (a page that the root service
// did not write), a byte after a name that is not 0, a field with no zero,
// and a control character inside a name.
@(test)
a_page_whose_names_the_border_refuses_gives_no_name :: proc(t: ^testing.T) {
	empty: [SOURCE_NAMES_PAGE_BYTES]u8
	_, _, _, empty_ok := source_names_of_page(empty[:])
	testing.expect(t, !empty_ok)
	good: [SOURCE_NAMES_PAGE_BYTES]u8
	testing.expect(t, source_names_write(good[:], "server", "requests"))
	damages := [?]int{SOURCE_NAMES_OFFSET + 10, SOURCE_NAMES_OFFSET + SOURCE_NAME_BYTES - 1, SOURCE_NAMES_OFFSET + SOURCE_NAME_BYTES + 20, SOURCE_NAMES_OFFSET + 2 * SOURCE_NAME_BYTES - 1}
	for place in damages {
		page := good
		page[place] = 'x'
		_, _, _, ok := source_names_of_page(page[:])
		testing.expectf(t, !ok, "a byte at %d after a name", place)
	}
	whole := good
	for index in 0 ..< SOURCE_NAME_BYTES {
		whole[SOURCE_NAMES_OFFSET + index] = 'a'
	}
	_, _, _, whole_ok := source_names_of_page(whole[:])
	testing.expect(t, !whole_ok)
	control := good
	control[SOURCE_NAMES_OFFSET + 1] = 0x7F
	_, _, _, control_ok := source_names_of_page(control[:])
	testing.expect(t, !control_ok)
}
