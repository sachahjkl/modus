#+build !freestanding
package disk_process

import "core:testing"
import "modus:contract/remote"
import "modus:contract/role_contract"
import rd "modus:contract/root_delegation"

@(private = "file")
rows_hash_of :: proc(first: u8) -> (hash: [HASH_SIZE]u8) {
	for &byte, index in hash {
		byte = first + u8(index)
	}
	return
}

@(private = "file")
rows_key_of :: proc(first: u8) -> (key: [CLIENT_KEY_SIZE]u8) {
	for &byte, index in key {
		byte = first ~ u8(index + 1)
	}
	return
}

// A table that the core cannot hold gives no set, and a zero request: a
// negative count, a count past the capacity, a client key count past its
// capacity, a nickname of 0 bytes, a nickname past the limit, and a start
// policy in the table of a named principal.
@(test)
a_table_out_of_its_bounds_gives_no_set_of_rows :: proc(t: ^testing.T) {
	request: rd.Disk_Rows_Set_Request
	testing.expect(t, !disk_rows_set_request_of_table(nil, 0, 1, &request))
	bad_counts := [?]struct {
		rows: int,
		keys: int,
	}{{-1, 0}, {ROW_CAPACITY + 1, 0}, {0, -1}, {0, CLIENT_KEY_CAPACITY + 1}, {max(int), 0}}
	for counts in bad_counts {
		table: Grant_Table
		table.count = counts.rows
		table.client_key_count = counts.keys
		request.generation = 7
		testing.expect(t, !disk_rows_set_request_of_table(&table, 0, 1, &request))
		testing.expect(t, request == rd.Disk_Rows_Set_Request{})
	}
	for length in ([?]int{0, -1, NAME_LIMIT + 1}) {
		table: Grant_Table
		testing.expect_value(t, table_allow(&table, "store_one", rows_hash_of(1), .Store), Table_Problem.None)
		table.rows[0].nickname_length = length
		testing.expectf(t, !disk_rows_set_request_of_table(&table, 0, 1, &request), "a nickname of %d bytes is sent", length)
		testing.expect(t, request == rd.Disk_Rows_Set_Request{})
	}
	named: Grant_Table
	testing.expect_value(t, table_allow(&named, "policy", rows_hash_of(2), .Store), Table_Problem.None)
	named.rows[0].grants = {.Start_Policy}
	testing.expect(t, !disk_rows_set_request_of_table(&named, 1, 1, &request))
	// A generation of 0 is refused by the border.
	empty: Grant_Table
	testing.expect(t, !disk_rows_set_request_of_table(&empty, 0, 0, &request))
}

// A full table gives each row in its class, in its order, and passes the
// border: rows Store, the row Start_Policy of principal 0, each client key
// with its uses; a row with no grant gives nothing.
@(test)
the_rows_of_a_table_become_one_set_that_passes_the_border :: proc(t: ^testing.T) {
	table: Grant_Table
	testing.expect_value(t, table_allow(&table, "editor", rows_hash_of(10), .Store), Table_Problem.None)
	testing.expect_value(t, table_allow(&table, "Policy_9", rows_hash_of(20), .Store), Table_Problem.None)
	table.rows[1].grants = {.Start_Policy}
	testing.expect_value(t, table_allow(&table, "no-grant", rows_hash_of(30), .Store), Table_Problem.None)
	table.rows[2].grants = {}
	testing.expect_value(t, table_client_key_add(&table, rows_key_of(1), {.Calls}), Table_Problem.None)
	testing.expect_value(t, table_client_key_add(&table, rows_key_of(2), {.View, .Input}), Table_Problem.None)
	request: rd.Disk_Rows_Set_Request
	testing.expect(t, disk_rows_set_request_of_table(&table, role_contract.MACHINE_PRINCIPAL, max(u64), &request))
	testing.expect_value(t, request.principal, role_contract.MACHINE_PRINCIPAL)
	testing.expect_value(t, request.generation, max(u64))
	testing.expect_value(t, request.row_count, u32(4))
	testing.expect_value(t, request.rows[0].class_word, u32(rd.Disk_Row_Class.Store))
	testing.expect_value(t, string(request.rows[0].nickname[:request.rows[0].nickname_length]), "editor")
	testing.expect(t, request.rows[0].module_hash == rows_hash_of(10))
	testing.expect_value(t, request.rows[0].store_blocks, u64(0))
	testing.expect_value(t, request.rows[1].class_word, u32(rd.Disk_Row_Class.Start_Policy))
	testing.expect_value(t, string(request.rows[1].nickname[:request.rows[1].nickname_length]), "Policy_9")
	testing.expect_value(t, request.rows[2].class_word, u32(rd.Disk_Row_Class.Client_Key))
	testing.expect(t, request.rows[2].client_key == rows_key_of(1))
	testing.expect_value(t, request.rows[2].client_uses_word, remote.client_uses_word({.Calls}))
	testing.expect_value(t, request.rows[3].client_uses_word, remote.client_uses_word({.View, .Input}))
	testing.expect_value(t, rd.validate_disk_rows_set_request(&request).refusal, rd.Disk_Rows_Set_Refusal.None)

	// The capacity of the rows and of the keys of one table fits one set.
	full: Grant_Table
	for index in 0 ..< ROW_CAPACITY {
		name := [?]u8{'r', 'o', 'w', 'a' + u8(index)}
		testing.expect_value(t, table_allow(&full, string(name[:]), rows_hash_of(u8(index + 1)), .Store), Table_Problem.None)
	}
	for index in 0 ..< CLIENT_KEY_CAPACITY {
		testing.expect_value(t, table_client_key_add(&full, rows_key_of(u8(index + 1))), Table_Problem.None)
	}
	testing.expect(t, disk_rows_set_request_of_table(&full, 1, 1, &request))
	testing.expect_value(t, request.row_count, u32(ROW_CAPACITY + CLIENT_KEY_CAPACITY))
}
