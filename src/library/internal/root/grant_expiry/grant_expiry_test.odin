#+build !freestanding
package grant_expiry

import "core:testing"
import "modus:contract/grant_policy"

@(test)
grant_expiry_refusals_leave_table_unchanged :: proc(t: ^testing.T) {
	table: Grant_Expiry_Table
	valid_term := grant_policy.Timed_Grant_Term{granted_at_ms = 10, expires_at_ms = 50}

	// Nil table and zero grant ID are refused everywhere.
	testing.expect_value(t, grant_expiry_register(nil, 1, 0, .Store, valid_term), grant_policy.Grant_Policy_Refusal.Bad_Value)
	testing.expect_value(t, grant_expiry_register(&table, 0, 0, .Store, valid_term), grant_policy.Grant_Policy_Refusal.Bad_Value)
	testing.expect_value(t, grant_expiry_remove(nil, 1), grant_policy.Grant_Policy_Refusal.Bad_Value)
	testing.expect_value(t, grant_expiry_remove(&table, 0), grant_policy.Grant_Policy_Refusal.Bad_Value)
	testing.expect_value(t, grant_expiry_remove(&table, 99), grant_policy.Grant_Policy_Refusal.Not_Found)

	active, ref := grant_expiry_is_active(nil, 1, 20)
	testing.expect(t, !active)
	testing.expect_value(t, ref, grant_policy.Grant_Policy_Refusal.Bad_Value)

	active, ref = grant_expiry_is_active(&table, 0, 20)
	testing.expect(t, !active)
	testing.expect_value(t, ref, grant_policy.Grant_Policy_Refusal.Bad_Value)

	active, ref = grant_expiry_is_active(&table, 42, 20)
	testing.expect(t, !active)
	testing.expect_value(t, ref, grant_policy.Grant_Policy_Refusal.Not_Found)

	// Unknown Grant_Class and inverted/equal non-zero expiry timestamps are refused.
	testing.expect_value(t, grant_expiry_register(&table, 1, 0, grant_policy.Grant_Class(77), valid_term), grant_policy.Grant_Policy_Refusal.Bad_Value)
	equal_term := grant_policy.Timed_Grant_Term{granted_at_ms = 50, expires_at_ms = 50}
	testing.expect_value(t, grant_expiry_register(&table, 1, 0, .Network, equal_term), grant_policy.Grant_Policy_Refusal.Bad_Value)
	inverted_term := grant_policy.Timed_Grant_Term{granted_at_ms = 50, expires_at_ms = 49}
	testing.expect_value(t, grant_expiry_register(&table, 1, 0, .Network, inverted_term), grant_policy.Grant_Policy_Refusal.Bad_Value)
	testing.expect_value(t, table.count, 0)

	deadline, has_deadline := grant_expiry_next_deadline_ms(nil)
	testing.expect(t, !has_deadline)
	testing.expect_value(t, deadline, u64(0))

	swept, more := grant_expiry_sweep(nil, 100, nil)
	testing.expect_value(t, swept, 0)
	testing.expect(t, !more)
}

@(test)
grant_expiry_sweep_and_deadlines_honor_exact_boundaries :: proc(t: ^testing.T) {
	table: Grant_Expiry_Table

	// Register permanent grant, early expiry (100), middle expiry (200), late expiry (300).
	perm := grant_policy.Timed_Grant_Term{granted_at_ms = 10, expires_at_ms = 0}
	t100 := grant_policy.Timed_Grant_Term{granted_at_ms = 10, expires_at_ms = 100}
	t200 := grant_policy.Timed_Grant_Term{granted_at_ms = 10, expires_at_ms = 200}
	t300 := grant_policy.Timed_Grant_Term{granted_at_ms = 10, expires_at_ms = 300}

	testing.expect_value(t, grant_expiry_register(&table, 1, 0, .Store, perm), grant_policy.Grant_Policy_Refusal.None)
	testing.expect_value(t, grant_expiry_register(&table, 2, 1, .Network, t200), grant_policy.Grant_Policy_Refusal.None)
	testing.expect_value(t, grant_expiry_register(&table, 3, 1, .Device, t100), grant_policy.Grant_Policy_Refusal.None)
	testing.expect_value(t, grant_expiry_register(&table, 4, 2, .Wide_Agent, t300), grant_policy.Grant_Policy_Refusal.None)
	testing.expect_value(t, table.count, 4)

	// Earliest deadline ignores permanent grant and returns 100.
	deadline, has_deadline := grant_expiry_next_deadline_ms(&table)
	testing.expect(t, has_deadline)
	testing.expect_value(t, deadline, u64(100))

	// At now = 99 nothing is expired.
	buf: [8]Grant_Expiry_Entry
	swept, more := grant_expiry_sweep(&table, 99, buf[:])
	testing.expect_value(t, swept, 0)
	testing.expect(t, !more)
	testing.expect_value(t, table.count, 4)

	active, ref := grant_expiry_is_active(&table, 3, 99)
	testing.expect(t, active)
	testing.expect_value(t, ref, grant_policy.Grant_Policy_Refusal.None)

	// At exact boundary now = 100, grant 3 is expired.
	active, ref = grant_expiry_is_active(&table, 3, 100)
	testing.expect(t, !active)
	testing.expect_value(t, ref, grant_policy.Grant_Policy_Refusal.Expired)

	// Zero-length output slice reports more_expired without dropping entries.
	swept, more = grant_expiry_sweep(&table, 250, nil)
	testing.expect_value(t, swept, 0)
	testing.expect(t, more)
	testing.expect_value(t, table.count, 4)

	// 1-slot output buffer sweeps one expired entry and signals more_expired.
	one: [1]Grant_Expiry_Entry
	swept, more = grant_expiry_sweep(&table, 250, one[:])
	testing.expect_value(t, swept, 1)
	testing.expect(t, more)
	testing.expect_value(t, table.count, 3)

	// Second pass sweeps the remaining expired entry at now = 250.
	swept, more = grant_expiry_sweep(&table, 250, one[:])
	testing.expect_value(t, swept, 1)
	testing.expect(t, !more)
	testing.expect_value(t, table.count, 2)

	// Next deadline advances to 300.
	deadline, has_deadline = grant_expiry_next_deadline_ms(&table)
	testing.expect(t, has_deadline)
	testing.expect_value(t, deadline, u64(300))

	// Sweeping at max(u64) expires grant 4 and leaves permanent grant 1 intact.
	swept, more = grant_expiry_sweep(&table, max(u64), buf[:])
	testing.expect_value(t, swept, 1)
	testing.expect(t, !more)
	testing.expect_value(t, buf[0].grant_id, u64(4))
	testing.expect_value(t, table.count, 1)

	active, ref = grant_expiry_is_active(&table, 1, max(u64))
	testing.expect(t, active)
	testing.expect_value(t, ref, grant_policy.Grant_Policy_Refusal.None)

	deadline, has_deadline = grant_expiry_next_deadline_ms(&table)
	testing.expect(t, !has_deadline)
	testing.expect_value(t, deadline, u64(0))
}

@(test)
grant_expiry_capacity_update_and_remove :: proc(t: ^testing.T) {
	table := new(Grant_Expiry_Table)
	defer free(table)

	for i in 0 ..< GRANT_EXPIRY_CAPACITY {
		id := u64(i + 1)
		term := grant_policy.Timed_Grant_Term{granted_at_ms = 1, expires_at_ms = 1000 + id}
		testing.expect_value(t, grant_expiry_register(table, id, 0, .Store, term), grant_policy.Grant_Policy_Refusal.None)
	}
	testing.expect_value(t, table.count, GRANT_EXPIRY_CAPACITY)

	// Capacity + 1 for a new grant_id is refused without mutation.
	extra := grant_policy.Timed_Grant_Term{granted_at_ms = 1, expires_at_ms = 5000}
	testing.expect_value(t, grant_expiry_register(table, u64(GRANT_EXPIRY_CAPACITY + 1), 0, .Store, extra), grant_policy.Grant_Policy_Refusal.Capacity_Full)
	testing.expect_value(t, table.count, GRANT_EXPIRY_CAPACITY)

	// Renewing an existing grant_id updates in place even when the table is full.
	renewed := grant_policy.Timed_Grant_Term{granted_at_ms = 500, expires_at_ms = 9000}
	testing.expect_value(t, grant_expiry_register(table, 1, 2, .Network, renewed), grant_policy.Grant_Policy_Refusal.None)
	testing.expect_value(t, table.count, GRANT_EXPIRY_CAPACITY)
	active, ref := grant_expiry_is_active(table, 1, 8999)
	testing.expect(t, active)
	testing.expect_value(t, ref, grant_policy.Grant_Policy_Refusal.None)

	// Removing frees a slot so a new grant_id succeeds.
	testing.expect_value(t, grant_expiry_remove(table, 2), grant_policy.Grant_Policy_Refusal.None)
	testing.expect_value(t, table.count, GRANT_EXPIRY_CAPACITY - 1)
	testing.expect_value(t, grant_expiry_remove(table, 2), grant_policy.Grant_Policy_Refusal.Not_Found)
	testing.expect_value(t, grant_expiry_register(table, u64(GRANT_EXPIRY_CAPACITY + 1), 0, .Store, extra), grant_policy.Grant_Policy_Refusal.None)
	testing.expect_value(t, table.count, GRANT_EXPIRY_CAPACITY)
}
