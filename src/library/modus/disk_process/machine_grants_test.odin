#+build !freestanding
#+build !modus
package disk_process

import "core:testing"

@(private = "file")
machine_id_of :: proc(seed: u8) -> (id: [MACHINE_GRANT_IDENTIFIER_SIZE]u8) {
	for &b, index in id {
		b = seed ~ u8(index + 1)
	}
	if id == {} {
		id[0] = 1
	}
	return id
}

@(private = "file")
machine_key_of :: proc(seed: u8) -> (key: [KEY_SIZE]u8) {
	for &b, index in key {
		b = seed + u8(index)
	}
	return key
}

// Machine scope border conversion refuses 0, out-of-range bits, and max(u64).
@(test)
machine_scope_border_refuses_bad_words :: proc(t: ^testing.T) {
	for bad in ([?]u64{0, 1 << 2, 1 << 7, 1 << 63, max(u64)}) {
		_, ok := machine_scopes_from_word(bad)
		testing.expectf(t, !ok, "machine_scopes_from_word accepted 0x%x", bad)
	}
	for expected in ([?]Machine_Scopes{{.Principals}, {.System}, {.Principals, .System}}) {
		got, ok := machine_scopes_from_word(machine_scopes_to_word(expected))
		testing.expect(t, ok && got == expected)
	}
	for bad in ([?]u64{2, 255, max(u64)}) {
		_, ok := machine_scope_of_word(bad)
		testing.expectf(t, !ok, "machine_scope_of_word accepted %d", bad)
	}
	for expected in Machine_Scope {
		got, ok := machine_scope_of_word(u64(expected))
		testing.expect(t, ok && got == expected)
	}
}

// Refusals first: zero identifier, empty scopes, capacity overflow, revoking
// absent or unheld scopes, and removing the last System holder all refuse
// without mutating the table.
@(test)
machine_grants_enforce_invariants_and_last_system_holder :: proc(t: ^testing.T) {
	table: Grant_Table
	alice := machine_id_of(1)
	bob := machine_id_of(2)
	carol := machine_id_of(3)

	// Zero identifier and empty scopes are refused without changing the table.
	testing.expect_value(t, table_machine_grant_set(&table, {}, {.Principals}), Table_Problem.Zero_Identifier)
	testing.expect_value(t, table_machine_grant_set(&table, alice, {}), Table_Problem.Bad_Machine_Scopes)
	testing.expect_value(t, table_machine_grant_bootstrap_first_principal(&table, {}), Table_Problem.Zero_Identifier)
	testing.expect_value(t, table_machine_grant_revoke(&table, {}, {.System}), Table_Problem.Zero_Identifier)
	testing.expect_value(t, table_machine_grant_revoke(&table, alice, {}), Table_Problem.Bad_Machine_Scopes)
	testing.expect_value(t, table_machine_grant_revoke(&table, alice, {.System}), Table_Problem.Absent)
	testing.expect_value(t, table_machine_grant_remove_principal(&table, {}, false), Table_Problem.Zero_Identifier)
	testing.expect_value(t, table.machine_grant_count, 0)

	// First named principal receives both Principals and System.
	testing.expect_value(t, table_machine_grant_bootstrap_first_principal(&table, alice), Table_Problem.None)
	testing.expect(t, table_machine_grant_holds(&table, alice, .Principals))
	testing.expect(t, table_machine_grant_holds(&table, alice, .System))
	testing.expect_value(t, table_machine_grant_count_scope(&table, .System), 1)
	// Bootstrap runs only once while rows exist.
	testing.expect_value(t, table_machine_grant_bootstrap_first_principal(&table, bob), Table_Problem.Not_Held)

	// Removing System from the sole System holder is refused with Last_System_Grant.
	before := table
	testing.expect_value(t, table_machine_grant_revoke(&table, alice, {.System}), Table_Problem.Last_System_Grant)
	testing.expect_value(t, table_machine_grant_revoke(&table, alice, ALL_MACHINE_SCOPES), Table_Problem.Last_System_Grant)
	testing.expect_value(t, table_machine_grant_remove_principal(&table, alice, false), Table_Problem.Last_System_Grant)
	testing.expect(t, table == before)

	// Revoking Principals alone from alice succeeds because System remains.
	testing.expect_value(t, table_machine_grant_revoke(&table, alice, {.Principals}), Table_Problem.None)
	testing.expect(t, !table_machine_grant_holds(&table, alice, .Principals))
	testing.expect(t, table_machine_grant_holds(&table, alice, .System))
	testing.expect_value(t, table_machine_grant_revoke(&table, alice, {.Principals}), Table_Problem.Not_Held)

	// Grant Principals only to bob, then verify bob can be removed without
	// affecting alice's System grant.
	testing.expect_value(t, table_machine_grant_set(&table, bob, {.Principals}), Table_Problem.None)
	testing.expect(t, table_machine_grant_holds(&table, bob, .Principals))
	testing.expect(t, !table_machine_grant_holds(&table, bob, .System))
	testing.expect_value(t, table_machine_grant_revoke(&table, bob, {.Principals}), Table_Problem.None)
	testing.expect_value(t, table_machine_grant_find(&table, bob), -1)

	// Recovery key restores both scopes to bob; now two System holders exist,
	// so alice can lose System and be removed while bob still holds System.
	testing.expect_value(t, table_machine_grant_recovery_restore(&table, bob), Table_Problem.None)
	testing.expect(t, table_machine_grant_holds(&table, bob, .Principals))
	testing.expect(t, table_machine_grant_holds(&table, bob, .System))
	testing.expect_value(t, table_machine_grant_count_scope(&table, .System), 2)
	testing.expect_value(t, table_machine_grant_remove_principal(&table, alice, false), Table_Problem.None)
	testing.expect_value(t, table_machine_grant_find(&table, alice), -1)
	testing.expect_value(t, table_machine_grant_count_scope(&table, .System), 1)

	// Removing bob when another named principal remains is refused, but
	// removing bob as the last named principal clears the row cleanly.
	testing.expect_value(t, table_machine_grant_remove_principal(&table, bob, false), Table_Problem.Last_System_Grant)
	testing.expect_value(t, table_machine_grant_remove_principal(&table, bob, true), Table_Problem.None)
	testing.expect_value(t, table.machine_grant_count, 0)

	// Capacity edge: fill all MACHINE_GRANT_CAPACITY rows; one past capacity
	// refuses with Full without changing state.
	for i in 0 ..< MACHINE_GRANT_CAPACITY {
		testing.expect_value(t, table_machine_grant_set(&table, machine_id_of(u8(10 + i)), {.Principals}), Table_Problem.None)
	}
	full_before := table
	testing.expect_value(t, table_machine_grant_set(&table, carol, {.System}), Table_Problem.Full)
	testing.expect(t, table == full_before)
}

// Machine grant rows survive persisted encode/decode even when
// forget_by_default is set, refuse tampering or hostile rows, and are refused
// on any named principal's table.
@(test)
machine_grants_persist_under_machine_tag_and_refuse_named_tables :: proc(t: ^testing.T) {
	table: Grant_Table
	key := machine_key_of(19)
	alice := machine_id_of(1)
	bob := machine_id_of(2)

	testing.expect_value(t, table_machine_grant_bootstrap_first_principal(&table, alice), Table_Problem.None)
	testing.expect_value(t, table_machine_grant_set(&table, bob, {.Principals}), Table_Problem.None)
	table.forget_by_default = true

	bytes: [TABLE_SIZE]u8
	table_encode(&table, &key, &bytes)
	decoded, problem := table_decode(bytes[:], &key)
	testing.expect_value(t, problem, Table_File_Problem.None)
	testing.expect_value(t, decoded.machine_grant_count, 2)
	testing.expect(t, table_machine_grant_holds(&decoded, alice, .Principals))
	testing.expect(t, table_machine_grant_holds(&decoded, alice, .System))
	testing.expect(t, table_machine_grant_holds(&decoded, bob, .Principals))
	testing.expect(t, !table_machine_grant_holds(&decoded, bob, .System))

	// Named principal table holding machine grants is refused; principal 0 passes.
	testing.expect_value(t, table_principal_problem(&decoded, false), Table_File_Problem.Machine_Grant_Of_A_Named_Principal)
	testing.expect_value(t, table_principal_problem(&decoded, true), Table_File_Problem.None)

	// Hostile signed rows: zero identifier, duplicate identifier, bad scope byte,
	// non-zero reserved pad byte, and trailing non-zero byte past count.
	{
		zero := bytes
		for &b in zero[TABLE_OFFSET_MACHINE_GRANTS:][:MACHINE_GRANT_IDENTIFIER_SIZE] {
			b = 0
		}
		table_tag_put(&key, &zero)
		_, p := table_decode(zero[:], &key)
		testing.expect_value(t, p, Table_File_Problem.Bad_Machine_Grants)
	}
	{
		dup := bytes
		copy(dup[TABLE_OFFSET_MACHINE_GRANTS + MACHINE_GRANT_ROW_SIZE:][:MACHINE_GRANT_ROW_SIZE], bytes[TABLE_OFFSET_MACHINE_GRANTS:][:MACHINE_GRANT_ROW_SIZE])
		table_tag_put(&key, &dup)
		_, p := table_decode(dup[:], &key)
		testing.expect_value(t, p, Table_File_Problem.Bad_Machine_Grants)
	}
	{
		bad_scope := bytes
		bad_scope[TABLE_OFFSET_MACHINE_GRANTS + MACHINE_GRANT_ROW_OFFSET_SCOPES] = 0x04
		table_tag_put(&key, &bad_scope)
		_, p := table_decode(bad_scope[:], &key)
		testing.expect_value(t, p, Table_File_Problem.Bad_Machine_Grants)
	}
	{
		bad_pad := bytes
		bad_pad[TABLE_OFFSET_MACHINE_GRANTS + MACHINE_GRANT_ROW_SIZE - 1] = 1
		table_tag_put(&key, &bad_pad)
		_, p := table_decode(bad_pad[:], &key)
		testing.expect_value(t, p, Table_File_Problem.Bad_Machine_Grants)
	}
	{
		trailing := bytes
		trailing[TABLE_OFFSET_MACHINE_GRANTS + 2 * MACHINE_GRANT_ROW_SIZE] = 1
		table_tag_put(&key, &trailing)
		_, p := table_decode(trailing[:], &key)
		testing.expect_value(t, p, Table_File_Problem.Bad_Machine_Grants)
	}
}
