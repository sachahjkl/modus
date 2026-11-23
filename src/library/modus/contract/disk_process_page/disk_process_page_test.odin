#+build !freestanding
package disk_process_page

import op "modus:contract/operation"
import "core:testing"

// A row that the root service writes is found by its process slot and its
// process serial, with its nickname and its hash; another serial in the
// same slot is another process, and finds nothing.
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
	// The clear of the row: the process is found no more.
	row_write(page, 3, {})
	_, cleared := row_find(page, 5, 9)
	testing.expect(t, !cleared)
	// No page, and the slot 0 that no process has: no row.
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

// The page has a row for each place of the table of the root service: the
// last place holds a row; a write at the capacity, one past it, or at a
// negative place changes nothing.
@(test)
a_write_past_the_rows_changes_nothing :: proc(t: ^testing.T) {
	page := new(Page)
	defer free(page)
	testing.expect(t, ROW_CAPACITY == op.PROCESS_SLOTS_OF_THE_MACHINE - 1)
	testing.expect(t, PAGE_PAGES * 4096 >= size_of(Page))
	for place in ([?]int{-1, ROW_CAPACITY, ROW_CAPACITY + 1, max(int)}) {
		row_write(page, place, row_of(7, 1, "outside", {}))
		testing.expect_value(t, page.change_count, u64(0))
	}
	_, outside := row_find(page, 7, 1)
	testing.expect(t, !outside)
	row_write(page, ROW_CAPACITY - 1, row_of(255, 4, "last", {}))
	found, ok := row_find(page, 255, 4)
	testing.expect(t, ok)
	nickname := nickname_of(found.nickname)
	testing.expect_value(t, nickname_text(&nickname), "last")
}
