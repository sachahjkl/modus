#+build !freestanding
package replacement_list

import "core:testing"

// list_of writes a list as the tool does: the header, then the rows.
@(private = "file")
list_of :: proc(list: []Row) -> []u8 {
	bytes := make([]u8, size_of(Header) + len(list) * size_of(Row), context.temp_allocator)
	header := Header{magic = MAGIC, version = VERSION, row_count = u32(len(list))}
	copy(bytes, (cast([^]u8)&header)[:size_of(Header)])
	if len(list) > 0 {
		copy(bytes[size_of(Header):], (cast([^]u8)raw_data(list))[:len(list) * size_of(Row)])
	}
	return bytes
}

@(private = "file")
hash_filled :: proc(value: u8) -> (hash: [HASH_SIZE]u8) {
	for &item in hash {
		item = value
	}
	return
}

@(private = "file")
row_of :: proc(from, to: u8, scope: Scope = .System, principal: u32 = 0) -> Row {
	return {from = hash_filled(from), to = hash_filled(to), scope = scope, principal = principal}
}

@(test)
test_a_valid_list_gives_its_rows :: proc(t: ^testing.T) {
	list := [?]Row{row_of(1, 2), row_of(1, 3), row_of(1, 2, .Principal, 1)}
	found, problem := rows(list_of(list[:]))
	testing.expect_value(t, problem, List_Problem.None)
	testing.expect_value(t, len(found), 3)
	empty, empty_problem := rows(list_of(nil))
	testing.expect_value(t, empty_problem, List_Problem.None)
	testing.expect_value(t, len(empty), 0)
}

@(test)
test_the_reader_refuses_each_fault_of_the_form :: proc(t: ^testing.T) {
	good := [?]Row{row_of(1, 2)}
	bytes := list_of(good[:])
	_, problem := rows(bytes[:size_of(Header) - 1])
	testing.expect_value(t, problem, List_Problem.Too_Small)
	_, problem = rows(bytes[:len(bytes) - 1])
	testing.expect_value(t, problem, List_Problem.Size)

	changed := make([]u8, len(bytes), context.temp_allocator)
	copy(changed, bytes)
	changed[0] ~= 0x01
	_, problem = rows(changed)
	testing.expect_value(t, problem, List_Problem.Magic)

	copy(changed, bytes)
	(^Header)(raw_data(changed)).version = VERSION + 1
	_, problem = rows(changed)
	testing.expect_value(t, problem, List_Problem.Version)

	copy(changed, bytes)
	(^Header)(raw_data(changed)).row_count = ROW_CAPACITY + 1
	_, problem = rows(changed)
	testing.expect_value(t, problem, List_Problem.Count)

	// A count that names more rows than the bytes hold.
	copy(changed, bytes)
	(^Header)(raw_data(changed)).row_count = 2
	_, problem = rows(changed)
	testing.expect_value(t, problem, List_Problem.Size)
}

@(test)
test_the_reader_refuses_each_fault_of_a_row :: proc(t: ^testing.T) {
	Case :: struct {
		row:     Row,
		problem: List_Problem,
	}
	cases := [?]Case {
		{row_of(1, 2, .None), .Scope},
		{row_of(1, 2, Scope(7)), .Scope},
		{row_of(1, 2, Scope(u32(max(Scope)) + 1)), .Scope},
		{row_of(1, 2, Scope(max(u32))), .Scope},
		{row_of(1, 2, .System, 1), .Scope},
		{row_of(1, 2, .Principal, 0), .Scope},
		{row_of(1, 1), .Same_Hash},
		{row_of(0, 2), .Same_Hash},
		{row_of(1, 0), .Same_Hash},
	}
	for item in cases {
		list := [1]Row{item.row}
		_, problem := rows(list_of(list[:]))
		testing.expect_value(t, problem, item.problem)
	}
	repeated := [?]Row{row_of(1, 2), row_of(3, 4), row_of(1, 2)}
	_, problem := rows(list_of(repeated[:]))
	testing.expect_value(t, problem, List_Problem.Repeated)
}

@(test)
test_row_find_names_one_pair_in_one_scope :: proc(t: ^testing.T) {
	list := [?]Row{row_of(1, 2), row_of(1, 3, .Principal, 1)}
	row, found := row_find(list[:], hash_filled(1), hash_filled(2), .System, 0)
	testing.expect(t, found)
	testing.expect_value(t, row.to, hash_filled(2))
	// The reverse pair, another scope, another principal: no row.
	_, found = row_find(list[:], hash_filled(2), hash_filled(1), .System, 0)
	testing.expect(t, !found)
	_, found = row_find(list[:], hash_filled(1), hash_filled(3), .System, 0)
	testing.expect(t, !found)
	_, found = row_find(list[:], hash_filled(1), hash_filled(3), .Principal, 2)
	testing.expect(t, !found)
}

@(test)
test_the_signed_message_holds_each_field :: proc(t: ^testing.T) {
	message := signed_message(hash_filled(1), hash_filled(2), .Principal, 0x0403_0201)
	testing.expect_value(t, string(message[:len(SIGNATURE_LABEL)]), SIGNATURE_LABEL)
	testing.expect_value(t, message[len(SIGNATURE_LABEL)], 0)
	testing.expect_value(t, message[32], 1)
	testing.expect_value(t, message[32 + HASH_SIZE], 2)
	tail := 32 + 2 * HASH_SIZE
	testing.expect_value(t, message[tail], u8(Scope.Principal))
	testing.expect_value(t, message[tail + 4], 0x01)
	testing.expect_value(t, message[tail + 7], 0x04)
	// Each field changes the message: the pair, its direction, the scope.
	testing.expect(t, message != signed_message(hash_filled(2), hash_filled(1), .Principal, 0x0403_0201))
	testing.expect(t, message != signed_message(hash_filled(1), hash_filled(2), .System, 0x0403_0201))
	testing.expect(t, message != signed_message(hash_filled(1), hash_filled(2), .Principal, 1))
}
