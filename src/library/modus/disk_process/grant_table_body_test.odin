#+build !freestanding
package disk_process

import "core:testing"

// The table that the principals service gives the root service is read
// again with table_body_decode: a forged or damaged table gives no row. Each
// case breaks one field of a good table; the good table comes last.

@(private = "file")
body_hash :: proc(first: u8) -> (hash: [HASH_SIZE]u8) {
	for &byte, index in hash {
		byte = first + u8(index)
	}
	return
}

@(private = "file")
body_key :: proc(value: u8) -> (key: [KEY_SIZE]u8) {
	for &byte in key {
		byte = value
	}
	return
}

@(private = "file")
good_body :: proc(t: ^testing.T) -> (bytes: [TABLE_SIZE]u8) {
	table: Grant_Table
	testing.expect_value(t, table_allow(&table, "visitor", body_hash(1), .Store), Table_Problem.None)
	testing.expect_value(t, table_allow(&table, "editor", body_hash(2), .Store), Table_Problem.None)
	testing.expect_value(t, table_client_key_add(&table, body_hash(3)), Table_Problem.None)
	table_body_encode(&table, &bytes)
	return bytes
}

@(test)
table_body_decode_refuses_each_forged_field :: proc(t: ^testing.T) {
	Case :: struct {
		offset:  int,
		value:   u8,
		problem: Table_File_Problem,
	}
	second_row := TABLE_HEADER_SIZE + ROW_SIZE
	cases := [?]Case {
		{TABLE_OFFSET_MAGIC, 'X', .Wrong_Magic},
		{TABLE_OFFSET_FORMAT, u8(TABLE_FORMAT + 1), .Wrong_Format},
		// A count past the bound, and the largest count of the byte.
		{TABLE_OFFSET_COUNT, ROW_CAPACITY + 1, .Too_Many_Rows},
		{TABLE_OFFSET_COUNT, 255, .Too_Many_Rows},
		{TABLE_OFFSET_SETTING, 2, .Bad_Setting},
		{TABLE_OFFSET_CLIENT_KEY_COUNT + 1, 1, .Bad_Setting},
		// A nickname longer than a name.
		{TABLE_HEADER_SIZE + ROW_OFFSET_LENGTH, NAME_LIMIT + 1, .Bad_Row},
		{TABLE_HEADER_SIZE + ROW_OFFSET_LENGTH, 255, .Bad_Row},
		// A byte after the nickname, and after the persistence.
		{TABLE_HEADER_SIZE + ROW_OFFSET_NICKNAME + NAME_LIMIT - 1, 'x', .Bad_Row},
		{TABLE_HEADER_SIZE + ROW_SIZE - 1, 1, .Bad_Row},
		// A grant that no disk grant names, and a persistence past its enum.
		{TABLE_HEADER_SIZE + ROW_OFFSET_GRANTS, 0x80, .Bad_Row},
		{TABLE_HEADER_SIZE + ROW_OFFSET_PERSISTENCE, 255, .Bad_Row},
		// The start policy with the store.
		{TABLE_HEADER_SIZE + ROW_OFFSET_GRANTS, transmute(u8)Disk_Grants{.Store, .Start_Policy}, .Bad_Row},
		// A row after the count.
		{TABLE_HEADER_SIZE + 2 * ROW_SIZE, 1, .Bytes_After_Rows},
		// More client keys than the bound, and a key after the count.
		{TABLE_OFFSET_CLIENT_KEY_COUNT, CLIENT_KEY_CAPACITY + 1, .Bad_Client_Keys},
		{TABLE_OFFSET_CLIENT_KEYS + CLIENT_KEY_ROW_SIZE, 1, .Bad_Client_Keys},
		// Client uses that name no use.
		{TABLE_OFFSET_CLIENT_KEYS + CLIENT_KEY_ROW_OFFSET_USES + 7, 0x80, .Bad_Client_Keys},
		// The second row takes the nickname of the first.
		{second_row + ROW_OFFSET_LENGTH, 7, .None},
	}
	for item, index in cases {
		bytes := good_body(t)
		bytes[item.offset] = item.value
		if index == len(cases) - 1 {
			copy(bytes[second_row + ROW_OFFSET_NICKNAME:][:NAME_LIMIT], bytes[TABLE_HEADER_SIZE + ROW_OFFSET_NICKNAME:][:NAME_LIMIT])
			_, problem := table_body_decode(&bytes)
			testing.expect_value(t, problem, Table_File_Problem.Two_Rows)
			continue
		}
		table, problem := table_body_decode(&bytes)
		testing.expectf(t, problem == item.problem, "case %d: %v, not %v", index, problem, item.problem)
		testing.expect_value(t, table.count, 0)
		testing.expect_value(t, table.client_key_count, 0)
	}
	// A hash of zero bytes in a row.
	bytes := good_body(t)
	for &byte in bytes[TABLE_HEADER_SIZE + ROW_OFFSET_HASH:][:HASH_SIZE] {
		byte = 0
	}
	_, problem := table_body_decode(&bytes)
	testing.expect_value(t, problem, Table_File_Problem.Bad_Row)
	// A client key of zero bytes.
	bytes = good_body(t)
	for &byte in bytes[TABLE_OFFSET_CLIENT_KEYS:][:CLIENT_KEY_SIZE] {
		byte = 0
	}
	_, problem = table_body_decode(&bytes)
	testing.expect_value(t, problem, Table_File_Problem.Bad_Client_Keys)
}

// A table of a named principal that holds the start policy is refused
// after the decode: a principals service cannot give principal 1 the start
// policy of the machine.
@(test)
table_body_of_a_named_principal_refuses_a_start_policy :: proc(t: ^testing.T) {
	table: Grant_Table
	testing.expect_value(t, table_start_policy_choose(&table, "policy", body_hash(5)), Table_Problem.None)
	bytes: [TABLE_SIZE]u8
	table_body_encode(&table, &bytes)
	decoded, problem := table_body_decode(&bytes)
	testing.expect_value(t, problem, Table_File_Problem.None)
	testing.expect_value(t, table_principal_problem(&decoded, false), Table_File_Problem.Start_Policy_Of_A_Named_Principal)
	testing.expect_value(t, table_principal_problem(&decoded, true), Table_File_Problem.None)
}

// The body and the tag: the root service writes the body, the principals
// service adds the tag, and the decode of the disk reads the same table.
// A tag of another key does not verify; the body decode never reads the tag.
@(test)
table_body_and_tag_give_the_table_of_the_disk :: proc(t: ^testing.T) {
	bytes := good_body(t)
	for byte in bytes[TABLE_OFFSET_TAG:] {
		testing.expect_value(t, byte, 0)
	}
	key := body_key(7)
	tagged := bytes
	table_tag_put(&key, &tagged)
	from_disk, problem := table_decode(tagged[:], &key)
	testing.expect_value(t, problem, Table_File_Problem.None)
	from_body, body_problem := table_body_decode(&tagged)
	testing.expect_value(t, body_problem, Table_File_Problem.None)
	testing.expect_value(t, from_body, from_disk)
	testing.expect_value(t, from_body.count, 2)
	testing.expect_value(t, from_body.client_key_count, 1)

	other := body_key(8)
	_, other_problem := table_decode(tagged[:], &other)
	testing.expect_value(t, other_problem, Table_File_Problem.Not_Authentic)
	// The encode with a key is the body and the tag.
	encoded: [TABLE_SIZE]u8
	table := from_disk
	table_encode(&table, &key, &encoded)
	testing.expect_value(t, encoded, tagged)
}
