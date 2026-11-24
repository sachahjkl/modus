#+build !freestanding
package store

import "core:strings"
import "core:testing"

// A word of the kind of an entry that names no kind is refused: one past
// the last kind, a word past 255 and the largest word. The record keeps its
// size and the place of its kind. Each kind then reads back from its word.
@(test)
a_word_of_an_entry_kind_that_names_no_kind :: proc(t: ^testing.T) {
	refused_words := [?]u64{u64(max(Entry_Kind)) + 1, 0x100, max(u64)}
	for word in refused_words {
		_, ok := entry_kind_of_word(word)
		testing.expectf(t, !ok, "the word %d names no kind of an entry, and it is taken", word)
	}
	testing.expect_value(t, size_of(Entry), 112)
	testing.expect_value(t, offset_of(Entry, kind), 0)
	for member in Entry_Kind {
		kind, ok := entry_kind_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, kind, member)
	}
}

// Entry name edges: 0 bytes, 1 byte, 64 bytes, 255 bytes (exact bound), and
// 256 bytes (one past bound), plus forbidden bytes and invalid UTF-8.
@(test)
entry_name_bounds_and_refusals :: proc(t: ^testing.T) {
	testing.expect_value(t, ENTRY_NAME_CAPACITY, 255)
	testing.expect_value(t, size_of(Entry_Name), 256)

	refusal, _, _ := name_refusal("")
	testing.expect_value(t, refusal, Name_Refusal.Empty)

	// 1 byte, 64 bytes, 76-byte UTF-8 name, and exact 255-byte bound succeed.
	name_255 := strings.repeat("a", 255, context.temp_allocator)
	for valid in ([?]string{"a", strings.repeat("b", 64, context.temp_allocator), "Rapport annuel 2026 – comptes consolidés et annexes (version finale).pdf", name_255}) {
		r, _, _ := name_refusal(valid)
		testing.expectf(t, r == .None, "expected valid name of %d bytes, got %v", len(valid), r)
		key := entry_name(valid)
		testing.expect_value(t, name_of(&key), valid)
		testing.expect_value(t, key[ENTRY_NAME_CAPACITY], u8(0))
	}

	// One past bound (256 bytes) is refused.
	name_256 := strings.repeat("a", 256, context.temp_allocator)
	r_over, _, _ := name_refusal(name_256)
	testing.expect_value(t, r_over, Name_Refusal.Too_Long)

	// Forbidden names and bytes.
	for bad in ([?]string{".", "..", "a/b", "a\x00b", "a\nb"}) {
		r_bad, _, _ := name_refusal(bad)
		testing.expect_value(t, r_bad, Name_Refusal.Bad_Byte)
	}
}

// Multi-GiB disk geometry calculations and overflow edges: 0, 1, 2, 1 GiB,
// 64 GiB, 1 TiB, DISK_BLOCKS_MAX, DISK_BLOCKS_MAX + 1, and max(u64).
@(test)
disk_geometry_multi_gib_and_overflow :: proc(t: ^testing.T) {
	for bad in ([?]u64{0, 1, DISK_BLOCKS_MAX + 1, max(u64)}) {
		testing.expectf(t, !disk_blocks_valid(bad), "block count %d must be refused", bad)
		_, ok_bytes := disk_bytes(bad)
		testing.expect(t, !ok_bytes)
		_, ok_words := bitmap_words_for_blocks(bad)
		testing.expect(t, !ok_words)
	}

	// Valid edge: 2 blocks (minimum).
	b_min, ok_min := disk_bytes(DISK_BLOCKS_MIN)
	testing.expect(t, ok_min)
	testing.expect_value(t, b_min, u64(2 * BLOCK_SIZE))
	w_min, ok_wmin := bitmap_words_for_blocks(DISK_BLOCKS_MIN)
	testing.expect(t, ok_wmin)
	testing.expect_value(t, w_min, u64(1))

	// 64 GiB disk = 2^24 blocks.
	blocks_64gib := u64(1) << 24
	bytes_64gib, ok_64 := disk_bytes(blocks_64gib)
	testing.expect(t, ok_64)
	testing.expect_value(t, bytes_64gib, u64(64) << 30)
	words_64gib, ok_w64 := bitmap_words_for_blocks(blocks_64gib)
	testing.expect(t, ok_w64)
	testing.expect_value(t, words_64gib, u64(1) << 18) // A bitmap of 2 MiB.
	// One block past a whole word takes one word more.
	words_past, _ := bitmap_words_for_blocks(64 + 1)
	testing.expect_value(t, words_past, u64(2))

	// 1 TiB disk = 2^28 blocks.
	blocks_1tib := u64(1) << 28
	bytes_1tib, ok_1t := disk_bytes(blocks_1tib)
	testing.expect(t, ok_1t)
	testing.expect_value(t, bytes_1tib, u64(1) << 40)

	// Exact DISK_BLOCKS_MAX does not overflow u64.
	bytes_max, ok_max := disk_bytes(DISK_BLOCKS_MAX)
	testing.expect(t, ok_max)
	testing.expect_value(t, bytes_max, DISK_BLOCKS_MAX * BLOCK_SIZE)
	words_max, ok_wmax := bitmap_words_for_blocks(DISK_BLOCKS_MAX)
	testing.expect(t, ok_wmax)
	testing.expect(t, words_max > 0)
}

// A root is refused for a wrong magic, a wrong check, a count of blocks out
// of its bounds or past the disk, and a count of store pages past the root.
@(test)
root_validation_edges :: proc(t: ^testing.T) {
	blocks_64gib := u64(1) << 24
	root := Root{magic = ROOT_MAGIC, generation = 1, disk_blocks = blocks_64gib}
	root.check = root_check(&root)
	testing.expect(t, root_valid(&root, blocks_64gib))
	testing.expect(t, !root_valid(&root, blocks_64gib - 1))

	// The formats before: "STORAGE5" (no count tree) and "STORAGE4".
	for before in ([?]u64{0x35454741524F5453, 0x34454741524F5453}) {
		wrong_magic := root
		wrong_magic.magic = before
		wrong_magic.check = root_check(&wrong_magic)
		testing.expect(t, !root_valid(&wrong_magic, blocks_64gib))
	}

	wrong_check := root
	wrong_check.check ~= 1
	testing.expect(t, !root_valid(&wrong_check, blocks_64gib))

	for blocks in ([?]u64{0, 1, DISK_BLOCKS_MAX + 1, max(u64)}) {
		bad := root
		bad.disk_blocks = blocks
		bad.check = root_check(&bad)
		testing.expectf(t, !root_valid(&bad, max(u64)), "a root of %d blocks is taken", blocks)
	}

	for pages, index in ([?]u64{0, 1, STORE_PAGE_CAPACITY, STORE_PAGE_CAPACITY + 1, max(u64)}) {
		item := root
		item.store_page_count = pages
		item.check = root_check(&item)
		testing.expectf(t, root_valid(&item, blocks_64gib) == (index < 3), "a root of %d store pages", pages)
	}
}

// The store table holds thousands of stores, far past the 60 cells of the
// root of the format before, and each number maps to one page and one cell.
@(test)
the_store_table_holds_thousands_of_stores :: proc(t: ^testing.T) {
	testing.expect_value(t, STORES_OF_A_PAGE, 63)
	testing.expect_value(t, STORE_PAGE_CAPACITY, 251)
	testing.expect(t, STORE_CAPACITY > 10000)
	testing.expect_value(t, offset_of(Root, store_pages), 64)
	testing.expect_value(t, offset_of(Root, check), BLOCK_SIZE - 8)
	for number, index in ([?]int{0, 62, 63, 64, STORE_CAPACITY - 1}) {
		page, cell := store_place(number)
		expected := [?][2]int{{0, 0}, {0, 62}, {1, 0}, {1, 1}, {STORE_PAGE_CAPACITY - 1, STORES_OF_A_PAGE - 1}}
		testing.expect_value(t, page, expected[index][0])
		testing.expect_value(t, cell, expected[index][1])
	}
}
