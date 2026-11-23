#+build !freestanding
package plans_recipes

import "core:testing"

@(private = "file")
large_bytes :: proc(count: int) -> []u8 {
	bytes := make([]u8, count)
	for &value, index in bytes {
		value = u8(index * 31 + index / 251)
	}
	return bytes
}

// A read in ranges refuses what it cannot give whole: an absent object, an
// object above the buffer, a store with no ranges, and a range of 0 bytes
// before the end. A store that gives fewer bytes than asked still gives
// the object whole.
@(test)
private_store_read_large_refusals_then_short_ranges :: proc(t: ^testing.T) {
	store := new(Memory_Private_Store)
	defer free(store)
	port := memory_private_store_port(store)
	into := make([]u8, 3 * MEMORY_PRIVATE_STORE_RANGE_BYTES)
	defer delete(into)

	_, absent := private_store_read_large(&port, "absent", into)
	testing.expect_value(t, absent, Private_Store_Status.Absent)

	data := large_bytes(2 * MEMORY_PRIVATE_STORE_RANGE_BYTES + 1)
	defer delete(data)
	testing.expect_value(t, private_store_write_large(&port, "kernel", data), Private_Store_Status.Ok)

	_, too_large := private_store_read_large(&port, "kernel", into[:len(data) - 1])
	testing.expect_value(t, too_large, Private_Store_Status.Too_Large)

	no_ranges := port
	no_ranges.read_range = nil
	_, failed := private_store_read_large(&no_ranges, "kernel", into)
	testing.expect_value(t, failed, Private_Store_Status.Failed)
	testing.expect_value(t, private_store_write_large(nil, "kernel", data), Private_Store_Status.Failed)

	// A store that gives 0 bytes before the end: the read fails, never a part.
	zero := port
	zero.read_range = proc "contextless" (user: rawptr, name: string, offset: u64, into: []u8) -> (int, Private_Store_Status) {
		return 0, .Ok
	}
	_, zero_status := private_store_read_large(&zero, "kernel", into)
	testing.expect_value(t, zero_status, Private_Store_Status.Failed)

	// Short ranges of 1 and of 1000 bytes give the object whole.
	for short in ([?]int{1000, 1}) {
		store.range_short = short
		bytes, status := private_store_read_large(&port, "kernel", into)
		testing.expect_value(t, status, Private_Store_Status.Ok)
		testing.expect(t, string(bytes) == string(data), "the object comes whole")
	}
}

// A write in ranges keeps nothing when a range fails: the object is
// removed, so no reader finds a part of it. An object of one range takes
// one write.
@(test)
private_store_write_large_keeps_nothing_on_failure :: proc(t: ^testing.T) {
	store := new(Memory_Private_Store)
	defer free(store)
	port := memory_private_store_port(store)
	data := large_bytes(3 * MEMORY_PRIVATE_STORE_RANGE_BYTES)
	defer delete(data)

	store.writes_allowed = 2 // The third range fails.
	testing.expect_value(t, private_store_write_large(&port, "output", data), Private_Store_Status.Failed)
	testing.expect(t, memory_private_store_find(store, "output") == nil, "a failed write leaves no part")
	testing.expect_value(t, store.removes, 1)

	store.writes_allowed = -1
	no_commit := port
	no_commit.commit = proc "contextless" (user: rawptr, name: string) -> Private_Store_Status {
		return .Failed
	}
	testing.expect_value(t, private_store_write_large(&no_commit, "output", data), Private_Store_Status.Failed)
	testing.expect(t, memory_private_store_find(store, "output") == nil, "a failed commit leaves no part")

	writes := store.writes
	testing.expect_value(t, private_store_write_large(&port, "small", data[:MEMORY_PRIVATE_STORE_RANGE_BYTES]), Private_Store_Status.Ok)
	testing.expect_value(t, store.writes, writes + 1)

	testing.expect_value(t, private_store_write_large(&port, "output", data), Private_Store_Status.Ok)
	into := make([]u8, len(data))
	defer delete(into)
	bytes, status := private_store_read_large(&port, "output", into)
	testing.expect_value(t, status, Private_Store_Status.Ok)
	testing.expect(t, string(bytes) == string(data), "the object comes back whole")
}

// The list gives the names in byte order, page after page, and a remove
// takes a name out of it.
@(test)
private_store_list_pages_in_order :: proc(t: ^testing.T) {
	store := new(Memory_Private_Store)
	defer free(store)
	port := memory_private_store_port(store)
	for name in ([?]string{"c", "a", "b", "d"}) {
		testing.expect_value(t, private_store_write(&port, name, []u8{1}), Private_Store_Status.Ok)
	}
	testing.expect_value(t, private_store_remove(&port, "b"), Private_Store_Status.Ok)
	testing.expect_value(t, private_store_remove(&port, "b"), Private_Store_Status.Absent)
	page: [2]Private_Object_Name
	first, _ := private_store_list(&port, "", page[:])
	testing.expect_value(t, len(first), 2)
	testing.expect_value(t, private_object_name_text(&first[0]), "a")
	testing.expect_value(t, private_object_name_text(&first[1]), "c")
	second, _ := private_store_list(&port, "c", page[:])
	testing.expect_value(t, len(second), 1)
	testing.expect_value(t, private_object_name_text(&second[0]), "d")
	last, _ := private_store_list(&port, "d", page[:])
	testing.expect_value(t, len(last), 0)
}
