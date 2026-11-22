#+build !freestanding
package process_memory

import "core:testing"
import "modus:contract/byte_order"
import software "modus:contract/software_machine"

// A memory of 4 MiB: frame 0 stays empty, the tables come from the bottom,
// and the 2 MiB frame at 2 MiB is the large page of the tests.
TEST_MEMORY_BYTES :: 4 << 20
TEST_LARGE_FRAME :: u64(2 << 20)
UPPER :: software.PAGE_PRESENT | software.PAGE_WRITE | software.PAGE_USER
USER_READ :: software.PAGE_PRESENT | software.PAGE_USER | software.PAGE_NO_EXECUTE
USER_WRITE :: USER_READ | software.PAGE_WRITE
SUPERVISOR_WRITE :: software.PAGE_PRESENT | software.PAGE_WRITE | software.PAGE_NO_EXECUTE

Test_Memory :: struct {
	bytes:      []u8,
	next_frame: u64,
	table:      u64,
}

memory_make :: proc() -> Test_Memory {
	memory := Test_Memory {
		bytes      = make([]u8, TEST_MEMORY_BYTES),
		next_frame = software.PAGE_SIZE,
	}
	memory.table = frame_take(&memory)
	return memory
}

frame_take :: proc(memory: ^Test_Memory) -> u64 {
	frame := memory.next_frame
	memory.next_frame += software.PAGE_SIZE
	return frame
}

// table_of gives the table of the level below the entry of address at level
// (3 is the top), and makes it when it is absent.
table_of :: proc(memory: ^Test_Memory, table: u64, address: u64, level: uint, upper: u64) -> u64 {
	offset := int(table + ((address >> (12 + 9 * level)) & software.PAGE_TABLE_INDEX_MASK) * 8)
	entry := byte_order.read_u64_little_endian(memory.bytes, offset)
	if entry & software.PAGE_PRESENT == 0 {
		child := frame_take(memory)
		byte_order.write_u64_little_endian(memory.bytes, offset, child | upper)
		return child
	}
	return entry & software.PAGE_ADDRESS_MASK
}

map_page :: proc(memory: ^Test_Memory, address: u64, frame: u64, flags: u64, upper: u64 = UPPER) {
	table := memory.table
	for level := uint(3); level >= 1; level -= 1 {
		table = table_of(memory, table, address, level, upper)
	}
	byte_order.write_u64_little_endian(memory.bytes, int(table + ((address >> 12) & software.PAGE_TABLE_INDEX_MASK) * 8), frame | flags)
}

map_large_page :: proc(memory: ^Test_Memory, address: u64, frame: u64, flags: u64) {
	table := memory.table
	for level := uint(3); level >= 2; level -= 1 {
		table = table_of(memory, table, address, level, UPPER)
	}
	byte_order.write_u64_little_endian(memory.bytes, int(table + ((address >> 21) & software.PAGE_TABLE_INDEX_MASK) * 8), frame | flags | software.PAGE_LARGE)
}

// The edges of the address space: no copy reaches a page that the table
// does not map, an address that is not canonical, or a range that wraps.
@(test)
addresses_outside_the_table_are_refused :: proc(t: ^testing.T) {
	memory := memory_make()
	defer delete(memory.bytes)
	map_page(&memory, 0x1000, frame_take(&memory), USER_WRITE)
	before := make([]u8, len(memory.bytes))
	defer delete(before)
	copy(before, memory.bytes)
	buffer := [8]u8{1, 2, 3, 4, 5, 6, 7, 8}
	addresses := [?]u64 {
		0, // Page 0 is not mapped.
		0x2000, // The page after the mapped one.
		software.CANONICAL_LOWER_MAX - 3, // Ends past the lower half.
		software.CANONICAL_LOWER_MAX + 1, // The first address that is not canonical.
		0x8000_0000_0000_0000,
		software.CANONICAL_UPPER_MIN, // Canonical, but the kernel half has no user page.
		max(u64) - 3, // Wraps past the top.
		max(u64),
	}
	for address in addresses {
		testing.expectf(t, !copy_to_process(memory.bytes, memory.table, address, buffer[:]), "a write at %x is accepted", address)
		read := [8]u8{0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA}
		testing.expectf(t, !copy_from_process(memory.bytes, memory.table, address, read[:]), "a read at %x is accepted", address)
		testing.expectf(t, read == [8]u8{0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA}, "a refused read at %x wrote the destination", address)
	}
	testing.expect(t, string(memory.bytes) == string(before), "a refused copy changed the memory")
}

// A range whose second page is absent is refused whole: the first page
// keeps its bytes and its entry gets no accessed or dirty bit.
@(test)
a_missing_second_page_refuses_the_whole_copy :: proc(t: ^testing.T) {
	memory := memory_make()
	defer delete(memory.bytes)
	first := frame_take(&memory)
	map_page(&memory, 0x40_0000, first, USER_WRITE)
	before := make([]u8, len(memory.bytes))
	defer delete(before)
	copy(before, memory.bytes)
	source: [64]u8
	for &value, index in source {
		value = u8(index + 1)
	}
	testing.expect(t, !copy_to_process(memory.bytes, memory.table, 0x40_1000 - 32, source[:]), "a write over a missing page is accepted")
	testing.expect(t, string(memory.bytes) == string(before), "a refused write changed a byte or a bit")
	destination: [64]u8
	testing.expect(t, !copy_from_process(memory.bytes, memory.table, 0x40_1000 - 32, destination[:]), "a read over a missing page is accepted")
	testing.expect(t, destination == [64]u8{}, "a refused read wrote the destination")
}

// A page of the supervisor is refused to both directions, also when its
// leaf has the user bit and only a level above lacks it.
@(test)
supervisor_pages_are_refused :: proc(t: ^testing.T) {
	memory := memory_make()
	defer delete(memory.bytes)
	map_page(&memory, 0x1000, frame_take(&memory), SUPERVISOR_WRITE)
	map_page(&memory, 0x80_0000_0000, frame_take(&memory), USER_WRITE, software.PAGE_PRESENT | software.PAGE_WRITE)
	value := [4]u8{9, 9, 9, 9}
	for address in ([]u64{0x1000, 0x80_0000_0000}) {
		testing.expectf(t, !copy_to_process(memory.bytes, memory.table, address, value[:]), "a write to the supervisor page %x is accepted", address)
		testing.expectf(t, !copy_from_process(memory.bytes, memory.table, address, value[:]), "a read of the supervisor page %x is accepted", address)
	}
}

// A page that is read only is refused to a write, at the leaf or at a level
// above, and still accepted to a read.
@(test)
read_only_pages_refuse_a_write :: proc(t: ^testing.T) {
	memory := memory_make()
	defer delete(memory.bytes)
	leaf_frame := frame_take(&memory)
	memory.bytes[leaf_frame] = 0x5A
	map_page(&memory, 0x3000, leaf_frame, USER_READ)
	upper_frame := frame_take(&memory)
	map_page(&memory, 0x100_0000_0000, upper_frame, USER_WRITE, software.PAGE_PRESENT | software.PAGE_USER)
	value := [1]u8{0xC3}
	testing.expect(t, !copy_to_process(memory.bytes, memory.table, 0x3000, value[:]), "a write to a read-only leaf is accepted")
	testing.expect(t, !copy_to_process(memory.bytes, memory.table, 0x100_0000_0000, value[:]), "a write under a read-only level is accepted")
	testing.expect_value(t, memory.bytes[leaf_frame], 0x5A)
	read: [1]u8
	testing.expect(t, copy_from_process(memory.bytes, memory.table, 0x3000, read[:]), "a read of a read-only page is refused")
	testing.expect_value(t, read[0], 0x5A)
}

// An entry with a reserved bit, and a table or a frame past the end of the
// memory, are refused: the walk never reads or writes outside the memory.
@(test)
damaged_tables_are_refused :: proc(t: ^testing.T) {
	memory := memory_make()
	defer delete(memory.bytes)
	map_page(&memory, 0x5000, u64(TEST_MEMORY_BYTES), USER_WRITE) // The frame is past the end.
	map_large_page(&memory, 0x20_0000_0000, TEST_LARGE_FRAME | 0x2000, USER_WRITE) // A reserved bit of a large entry.
	value := [8]u8{}
	for address in ([]u64{0x5000, 0x20_0000_0000}) {
		testing.expectf(t, !copy_to_process(memory.bytes, memory.table, address, value[:]), "a write at %x is accepted", address)
		testing.expectf(t, !copy_from_process(memory.bytes, memory.table, address, value[:]), "a read at %x is accepted", address)
	}
	testing.expect(t, !copy_from_process(memory.bytes, u64(TEST_MEMORY_BYTES), 0x1000, value[:]), "a table past the end is walked")
	testing.expect(t, !copy_from_process(memory.bytes, memory.table | 8, 0x1000, value[:]), "a table that is not aligned is walked")
}

// A copy of 0 bytes moves nothing and is accepted at any address, as the
// copy of the processor with a count of 0.
@(test)
an_empty_copy_touches_nothing :: proc(t: ^testing.T) {
	memory := memory_make()
	defer delete(memory.bytes)
	testing.expect(t, copy_to_process(memory.bytes, memory.table, max(u64), nil), "an empty write is refused")
	testing.expect(t, copy_from_process(memory.bytes, memory.table, max(u64), nil), "an empty read is refused")
}

// A copy across two pages whose frames are far apart moves each byte to
// its frame, and sets the accessed bit, and the dirty bit for a write.
@(test)
a_copy_across_pages_follows_each_frame :: proc(t: ^testing.T) {
	memory := memory_make()
	defer delete(memory.bytes)
	first := frame_take(&memory)
	_ = frame_take(&memory)
	second := frame_take(&memory)
	map_page(&memory, 0x7000, first, USER_WRITE)
	map_page(&memory, 0x8000, second, USER_WRITE)
	source: [300]u8
	for &value, index in source {
		value = u8(index * 7 + 3)
	}
	start := u64(0x8000 - 100)
	testing.expect(t, copy_to_process(memory.bytes, memory.table, start, source[:]), "a write across two pages is refused")
	testing.expect(t, string(memory.bytes[first + 0x1000 - 100:][:100]) == string(source[:100]), "the first page has the wrong bytes")
	testing.expect(t, string(memory.bytes[second:][:200]) == string(source[100:]), "the second page has the wrong bytes")
	destination: [300]u8
	testing.expect(t, copy_from_process(memory.bytes, memory.table, start, destination[:]), "a read across two pages is refused")
	testing.expect(t, destination == source, "the read gives other bytes")
	leaf_table := table_of(&memory, table_of(&memory, table_of(&memory, memory.table, 0x7000, 3, UPPER), 0x7000, 2, UPPER), 0x7000, 1, UPPER)
	for page in ([]u64{0x7000, 0x8000}) {
		entry := byte_order.read_u64_little_endian(memory.bytes, int(leaf_table + (page >> 12) * 8))
		testing.expectf(t, entry & (software.PAGE_ACCESSED | software.PAGE_DIRTY) == software.PAGE_ACCESSED | software.PAGE_DIRTY, "the entry of %x is %x", page, entry)
	}
}

// A large page of 2 MiB is walked to its frame, across the 4 KiB borders
// inside it.
@(test)
a_large_page_is_walked :: proc(t: ^testing.T) {
	memory := memory_make()
	defer delete(memory.bytes)
	base := u64(0x4000_0000)
	map_large_page(&memory, base, TEST_LARGE_FRAME, USER_WRITE)
	source := [6]u8{1, 2, 3, 4, 5, 6}
	address := base + 0x1F_F000 - 3
	testing.expect(t, copy_to_process(memory.bytes, memory.table, address, source[:]), "a write in a large page is refused")
	testing.expect(t, string(memory.bytes[TEST_LARGE_FRAME + 0x1F_F000 - 3:][:6]) == string(source[:]), "the large page has the wrong bytes")
	read: [6]u8
	testing.expect(t, copy_from_process(memory.bytes, memory.table, address, read[:]), "a read in a large page is refused")
	testing.expect(t, read == source, "the read of the large page gives other bytes")
	// The end of the large page meets the next 2 MiB, which has no mapping.
	testing.expect(t, !copy_to_process(memory.bytes, memory.table, base + 0x20_0000 - 2, source[:]), "a write past the large page is accepted")
}
