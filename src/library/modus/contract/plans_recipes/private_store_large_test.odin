#+build !freestanding
package plans_recipes

import "core:testing"

// The list gives the names in byte order, page after page, and a remove
// takes a name out of it. A page of rows whose names do not fit the bytes
// of names is cut before the first that does not fit.
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
	rows: [2]Private_Store_Entry
	names: [16]u8
	name_of :: proc(names: []u8, row: Private_Store_Entry) -> string {
		return string(names[row.name_offset:][:row.name_count])
	}
	first, first_status := private_store_list(&port, "", rows[:], names[:])
	testing.expect_value(t, first_status, Private_Store_Status.Ok)
	testing.expect_value(t, len(first), 2)
	testing.expect_value(t, name_of(names[:], first[0]), "a")
	testing.expect_value(t, name_of(names[:], first[1]), "c")
	second, _ := private_store_list(&port, "c", rows[:], names[:])
	testing.expect_value(t, len(second), 1)
	testing.expect_value(t, name_of(names[:], second[0]), "d")
	last, _ := private_store_list(&port, "d", rows[:], names[:])
	testing.expect_value(t, len(last), 0)
}
