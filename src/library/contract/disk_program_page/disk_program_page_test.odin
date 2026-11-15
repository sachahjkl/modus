#+build !freestanding
package disk_program_page

import "core:testing"

// A row that the root service writes is found by its program slot and its
// program serial, with its nickname and its hash; another serial in the
// same slot is another program, and finds nothing.
@(test)
a_row_is_found_by_its_slot_and_its_serial :: proc(t: ^testing.T) {
	page := new(Page)
	defer free(page)
	hash: [HASH_SIZE]u8
	for &byte, index in hash {
		byte = u8(index * 7 + 1)
	}
	row_write(page, 3, row_of(5, 9, "store_importer", hash))
	testing.expect_value(t, page.change_count, u64(2))
	found, ok := row_find(page, 5, 9)
	testing.expect(t, ok)
	nickname := nickname_of(found.nickname)
	testing.expect_value(t, nickname_text(&nickname), "store_importer")
	testing.expect_value(t, transmute([HASH_SIZE]u8)found.hash, hash)
	_, other_serial := row_find(page, 5, 10)
	testing.expect(t, !other_serial)
	_, other_slot := row_find(page, 6, 9)
	testing.expect(t, !other_slot)
	// The clear of the row: the program is found no more.
	row_write(page, 3, {})
	_, cleared := row_find(page, 5, 9)
	testing.expect(t, !cleared)
	// No page, and the slot 0 that no program has: no row.
	_, no_page := row_find(nil, 5, 9)
	testing.expect(t, !no_page)
	_, slot_zero := row_find(page, 0, 0)
	testing.expect(t, !slot_zero)
}

// A page that the root service left in the middle of a change gives no
// row: the reader stops after its tries, and does not wait.
@(test)
a_page_in_the_middle_of_a_change_gives_no_row :: proc(t: ^testing.T) {
	page := new(Page)
	defer free(page)
	row_write(page, 0, row_of(2, 1, "visitor", {}))
	page.change_count += 1
	_, found := row_find(page, 2, 1)
	testing.expect(t, !found)
}

// The nickname takes 23 bytes at most, and the hash prefix is the first 16
// digits of the whole hash, the first byte first.
@(test)
the_nickname_and_the_hash_prefix :: proc(t: ^testing.T) {
	long := row_of(1, 1, "a_nickname_of_more_than_23_bytes", {})
	nickname := nickname_of(long.nickname)
	testing.expect_value(t, nickname.length, NICKNAME_LIMIT)
	hash: [HASH_SIZE]u8
	hash[0], hash[1], hash[7], hash[8] = 0x5f, 0x0c, 0xa9, 0xff
	prefix: [HASH_PREFIX_DIGITS]u8
	hash_prefix_write(&prefix, hash_head(hash))
	testing.expect_value(t, string(prefix[:]), "5f0c0000000000a9")
}
