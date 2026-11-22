#+build !freestanding
package root_delegation

import "core:testing"

// The borders of the table commands of the principals service: each word
// that names no member, each principal at and past the bound, and each
// input that a hostile core or a damaged region gives, before the one input
// that passes.

@(test)
principals_table_key_border_refuses_each_bad_record :: proc(t: ^testing.T) {
	CAPACITY :: u64(2)
	good := [7]u64{1, 2, 3, 4, 1, 0, 0}
	cases := [?][7]u64 {
		{1, 2, 3, 4, CAPACITY, 0, 0}, // The first principal past the bound.
		{1, 2, 3, 4, max(u64), 0, 0}, // A forged principal.
		{0, 0, 0, 0, 0, 0, 0}, // A key of zero bytes.
		{1, 2, 3, 4, 0, 1, 0}, // values[5] not zero.
		{1, 2, 3, 4, 0, 0, max(u64)}, // values[6] not zero.
	}
	for values in cases {
		principal, key, failure := table_key_check(values, CAPACITY)
		testing.expect_value(t, failure, Table_Call_Failure.Bad_Input)
		testing.expect_value(t, principal, 0)
		testing.expect_value(t, key, [32]u8{})
	}
	principal, key, failure := table_key_check(good, CAPACITY)
	testing.expect_value(t, failure, Table_Call_Failure.None)
	testing.expect_value(t, principal, 1)
	testing.expect_value(t, key, transmute([32]u8)[4]u64{1, 2, 3, 4})
}

@(test)
principals_table_input_border_refuses_each_bad_input :: proc(t: ^testing.T) {
	CAPACITY :: u64(2)
	input: Table_Call_Input
	input.principal = 1
	input.storage_module_length = u64(copy(input.storage_module[:], "storage"))
	testing.expect_value(t, table_call_input_check(&input, CAPACITY), Table_Call_Failure.None)

	forged := input
	forged.principal = CAPACITY
	testing.expect_value(t, table_call_input_check(&forged, CAPACITY), Table_Call_Failure.Bad_Input)
	forged.principal = max(u64)
	testing.expect_value(t, table_call_input_check(&forged, CAPACITY), Table_Call_Failure.Bad_Input)

	empty_name := input
	empty_name.storage_module_length = 0
	testing.expect_value(t, table_call_input_check(&empty_name, CAPACITY), Table_Call_Failure.Bad_Input)

	long_name := input
	long_name.storage_module_length = STORAGE_MODULE_NAME_BYTES + 1
	testing.expect_value(t, table_call_input_check(&long_name, CAPACITY), Table_Call_Failure.Bad_Input)
	long_name.storage_module_length = max(u64)
	testing.expect_value(t, table_call_input_check(&long_name, CAPACITY), Table_Call_Failure.Bad_Input)

	// A byte after the name: the name that the core wrote is not this one.
	trailing := input
	trailing.storage_module[STORAGE_MODULE_NAME_BYTES - 1] = 'x'
	testing.expect_value(t, table_call_input_check(&trailing, CAPACITY), Table_Call_Failure.Bad_Input)

	// The longest name passes.
	whole := input
	whole.storage_module = {}
	for &item in whole.storage_module {
		item = 's'
	}
	whole.storage_module_length = STORAGE_MODULE_NAME_BYTES
	testing.expect_value(t, table_call_input_check(&whole, CAPACITY), Table_Call_Failure.None)
}

@(test)
principals_table_answer_words_refuse_unknown_members :: proc(t: ^testing.T) {
	for word in ([?]u64{0, u64(max(Table_Call_Failure)) + 1, max(u64)}) {
		_, ok := table_call_failure_of_word(word)
		testing.expect(t, !ok)
	}
	for word in ([?]u64{0, u64(max(Table_Read_Outcome)) + 1, max(u64)}) {
		_, ok := table_read_outcome_of_word(word)
		testing.expect(t, !ok)
	}
	failure, failure_ok := table_call_failure_of_word(u64(Table_Call_Failure.No_Key))
	testing.expect(t, failure_ok)
	testing.expect_value(t, failure, Table_Call_Failure.No_Key)
	outcome, outcome_ok := table_read_outcome_of_word(2)
	testing.expect(t, outcome_ok)
	testing.expect_value(t, outcome, Table_Read_Outcome.Decoded)
	// A Storage_Refused status is a member; a word past it is not.
	_, status_ok := principals_ring_status_from_word(u32(Principals_Ring_Status.Storage_Refused))
	testing.expect(t, status_ok)
	_, status_ok = principals_ring_status_from_word(u32(max(Principals_Ring_Status)) + 1)
	testing.expect(t, !status_ok)
	_, command_ok := principals_ring_command_from_word(u32(max(Principals_Ring_Command)) + 1)
	testing.expect(t, !command_ok)
}
