#+build !freestanding
package work_budget

import "core:testing"

@(test)
work_accounting_enum_word_border_refuses_unknown_refusals :: proc(t: ^testing.T) {
	ref, ok := work_accounting_refusal_of_word(u64(Work_Accounting_Refusal.None))
	testing.expect(t, ok)
	testing.expect_value(t, ref, Work_Accounting_Refusal.None)

	ref, ok = work_accounting_refusal_of_word(u64(Work_Accounting_Refusal.Overflow))
	testing.expect(t, ok)
	testing.expect_value(t, ref, Work_Accounting_Refusal.Overflow)

	_, bad_high := work_accounting_refusal_of_word(u64(Work_Accounting_Refusal.Overflow) + 1)
	testing.expect(t, !bad_high)
	_, bad_max := work_accounting_refusal_of_word(max(u64))
	testing.expect(t, !bad_max)
}

@(test)
processor_time_budget_enforces_strict_sibling_isolation :: proc(t: ^testing.T) {
	// Refusal edges on nil, zero share, over-budget share, backward period.
	_, ref := divide_to_child(nil, 100)
	testing.expect_value(t, ref, Work_Accounting_Refusal.Bad_Value)
	testing.expect_value(t, charge_period(nil, 1, 0), Work_Accounting_Refusal.Bad_Value)
	testing.expect_value(t, reclaim_from_child(nil, nil), Work_Accounting_Refusal.Bad_Value)

	parent := processor_budget_init(PROCESSOR_PERIOD_MICROSECONDS, 10)
	_, ref = divide_to_child(&parent, 0)
	testing.expect_value(t, ref, Work_Accounting_Refusal.Bad_Value)
	_, ref = divide_to_child(&parent, PROCESSOR_PERIOD_MICROSECONDS + 1)
	testing.expect_value(t, ref, Work_Accounting_Refusal.Insufficient_Budget)
	testing.expect_value(t, parent.allowance_us, PROCESSOR_PERIOD_MICROSECONDS)

	// Parent spends 60_000 us in period 10, then carves 50_000 us to Child A.
	// Parent can hold at most 50_000 us now, so 10_000 us of used time moves
	// to Child A (no time minting by child creation!).
	testing.expect_value(t, charge_period(&parent, 60_000, 10), Work_Accounting_Refusal.None)
	child_a, ref_a := divide_to_child(&parent, 50_000)
	testing.expect_value(t, ref_a, Work_Accounting_Refusal.None)
	testing.expect_value(t, parent.allowance_us, u64(50_000))
	testing.expect_value(t, parent.used_us, u64(50_000))
	testing.expect_value(t, child_a.allowance_us, u64(50_000))
	testing.expect_value(t, child_a.used_us, u64(10_000))

	// Advance both to period 11 and divide a fresh sibling Child B from parent.
	testing.expect_value(t, processor_budget_advance_period(&parent, 11), Work_Accounting_Refusal.None)
	testing.expect_value(t, processor_budget_advance_period(&parent, 10), Work_Accounting_Refusal.Bad_Value)
	child_b, ref_b := divide_to_child(&parent, 30_000)
	testing.expect_value(t, ref_b, Work_Accounting_Refusal.None)

	// Child A consumes 100% of its share in period 11; 1 us past fails with zero mutation.
	testing.expect_value(t, charge_period(&child_a, 50_000, 11), Work_Accounting_Refusal.None)
	testing.expect_value(t, processor_budget_remaining(child_a), u64(0))
	testing.expect_value(t, charge_period(&child_a, 1, 11), Work_Accounting_Refusal.Period_Exhausted)
	testing.expect_value(t, child_a.used_us, u64(50_000))
	testing.expect_value(t, child_a.total_us, u64(50_000))

	// Strict sibling isolation: Child B still has 100% of its 30_000 us untouched.
	testing.expect_value(t, processor_budget_remaining(child_b), u64(30_000))
	testing.expect_value(t, charge_period(&child_b, 30_000, 11), Work_Accounting_Refusal.None)
	testing.expect_value(t, processor_budget_remaining(child_b), u64(0))

	// Self-reclaim refused; valid reclaim returns allowance + same-period used_us.
	testing.expect_value(t, reclaim_from_child(&parent, &parent), Work_Accounting_Refusal.Bad_Value)
	testing.expect_value(t, reclaim_from_child(&parent, &child_b), Work_Accounting_Refusal.None)
	testing.expect_value(t, parent.allowance_us, u64(50_000))
	testing.expect_value(t, parent.used_us, u64(30_000))
	testing.expect_value(t, child_b.allowance_us, u64(0))

	// Overflow guard on total_us leaves budget unchanged.
	near_max := Processor_Time_Budget{allowance_us = 100, used_us = 0, total_us = max(u64) - 5, period_index = 1}
	testing.expect_value(t, charge_period(&near_max, 6, 1), Work_Accounting_Refusal.Overflow)
	testing.expect_value(t, near_max.used_us, u64(0))
	testing.expect_value(t, near_max.total_us, max(u64) - 5)
}

@(test)
service_work_table_charges_pages_time_and_builds_report_rows :: proc(t: ^testing.T) {
	table := new(Service_Work_Table)
	defer free(table)

	// Refusals for nil, zero connection_id, zero limit, and absent client.
	testing.expect_value(t, service_work_register(nil, 1, 10), Work_Accounting_Refusal.Bad_Value)
	testing.expect_value(t, service_work_register(table, 0, 10), Work_Accounting_Refusal.Bad_Value)
	testing.expect_value(t, service_work_register(table, 1, 0), Work_Accounting_Refusal.Bad_Value)
	testing.expect_value(t, charge_client_pages_and_time(table, 99, 1, 10, 0), Work_Accounting_Refusal.Not_Found)

	// Fill table up to SERVICE_WORK_CAPACITY; duplicate and capacity+1 refused cleanly.
	for i in 0 ..< SERVICE_WORK_CAPACITY {
		testing.expect_value(t, service_work_register(table, u64(i + 1), 16, 0, 1), Work_Accounting_Refusal.None)
	}
	testing.expect_value(t, table.count, SERVICE_WORK_CAPACITY)
	testing.expect_value(t, service_work_register(table, 1, 16, 0, 1), Work_Accounting_Refusal.Duplicate_Connection)
	testing.expect_value(t, service_work_register(table, u64(SERVICE_WORK_CAPACITY + 1), 16, 0, 1), Work_Accounting_Refusal.Capacity_Full)
	testing.expect_value(t, table.count, SERVICE_WORK_CAPACITY)

	// Charge connection 1 up to exact limit, refuse limit+1 with zero mutation on BOTH pages and time.
	testing.expect_value(t, charge_client_pages_and_time(table, 1, 16, 500, 1), Work_Accounting_Refusal.None)
	testing.expect_value(t, charge_client_pages_and_time(table, 1, 1, 999, 1), Work_Accounting_Refusal.Pages_Exceeded)
	snap, ref := service_work_snapshot(table, 1)
	testing.expect_value(t, ref, Work_Accounting_Refusal.None)
	testing.expect_value(t, snap.pages_used, u64(16))
	testing.expect_value(t, snap.pages_peak, u64(16))
	testing.expect_value(t, snap.processor_last_period_us, u64(500))
	testing.expect_value(t, snap.processor_total_us, u64(500))

	// Underflow and min(i64) refused with zero mutation.
	testing.expect_value(t, charge_client_pages_and_time(table, 1, -17, 10, 1), Work_Accounting_Refusal.Bad_Value)
	testing.expect_value(t, charge_client_pages_and_time(table, 1, min(i64), 10, 1), Work_Accounting_Refusal.Bad_Value)
	testing.expect_value(t, charge_client_pages_and_time(table, 1, -4, 250, 2), Work_Accounting_Refusal.None)

	// Period rollover resets processor_last_period_us while keeping processor_total_us cumulative.
	testing.expect_value(t, service_work_set_step_debt(table, 1, 42_000), Work_Accounting_Refusal.None)
	snap, ref = service_work_snapshot(table, 1)
	testing.expect_value(t, ref, Work_Accounting_Refusal.None)
	testing.expect_value(t, snap.pages_used, u64(12))
	testing.expect_value(t, snap.pages_peak, u64(16))
	testing.expect_value(t, snap.processor_last_period_us, u64(250))
	testing.expect_value(t, snap.processor_total_us, u64(750))
	testing.expect_value(t, snap.step_debt_ns, u64(42_000))

	// Build Process_Work_Report_Row and check border refusals.
	_, row_ref := process_work_report_row_of("", snap)
	testing.expect_value(t, row_ref, Work_Accounting_Refusal.Bad_Value)
	_, row_ref = process_work_report_row_of("012345678901234567890123456789012", snap)
	testing.expect_value(t, row_ref, Work_Accounting_Refusal.Bad_Value)
	_, row_ref = process_work_report_row_of("storage", Client_Work_Snapshot{})
	testing.expect_value(t, row_ref, Work_Accounting_Refusal.Bad_Value)

	row, ok_ref := process_work_report_row_of("storage", snap)
	testing.expect_value(t, ok_ref, Work_Accounting_Refusal.None)
	testing.expect_value(t, process_work_report_service_name(&row), "storage")
	testing.expect_value(t, row.connection_id, u64(1))
	testing.expect_value(t, row.pages_used, u64(12))
	testing.expect_value(t, row.pages_limit, u64(16))
	testing.expect_value(t, row.processor_last_period_us, u64(250))
	testing.expect_value(t, row.processor_total_us, u64(750))
	testing.expect_value(t, row.step_debt_ns, u64(42_000))

	// Remove frees a slot so capacity+1 succeeds.
	testing.expect_value(t, service_work_remove(table, 2), Work_Accounting_Refusal.None)
	testing.expect_value(t, service_work_remove(table, 2), Work_Accounting_Refusal.Not_Found)
	testing.expect_value(t, service_work_register(table, u64(SERVICE_WORK_CAPACITY + 1), 8), Work_Accounting_Refusal.None)
}

@(test)
step_debt_scheduler_deterministic_fairness_and_zero_starvation :: proc(t: ^testing.T) {
	sched := new(Step_Debt_Scheduler)
	defer free(sched)

	// Empty queue and invalid inputs refused cleanly.
	_, empty_ref := next_client_by_lowest_step_debt(sched)
	testing.expect_value(t, empty_ref, Work_Accounting_Refusal.Queue_Empty)
	_, nil_ref := next_client_by_lowest_step_debt(nil)
	testing.expect_value(t, nil_ref, Work_Accounting_Refusal.Bad_Value)
	testing.expect_value(t, step_debt_register(sched, 0), Work_Accounting_Refusal.Bad_Value)

	// Register 3 clients; enqueue in order 30, 10, 20 with equal debt 0 -> FIFO tie-break (30, 10, 20).
	testing.expect_value(t, step_debt_register(sched, 10), Work_Accounting_Refusal.None)
	testing.expect_value(t, step_debt_register(sched, 20), Work_Accounting_Refusal.None)
	testing.expect_value(t, step_debt_register(sched, 30), Work_Accounting_Refusal.None)

	testing.expect_value(t, step_debt_mark_waiting(sched, 30), Work_Accounting_Refusal.None)
	testing.expect_value(t, step_debt_mark_waiting(sched, 10), Work_Accounting_Refusal.None)
	testing.expect_value(t, step_debt_mark_waiting(sched, 20), Work_Accounting_Refusal.None)

	id, r := next_client_by_lowest_step_debt(sched)
	testing.expect_value(t, r, Work_Accounting_Refusal.None)
	testing.expect_value(t, id, u64(30))
	// Client 30 runs a heavy 10_000 ns step and re-queues immediately.
	testing.expect_value(t, step_debt_record_duration(sched, 30, 10_000), Work_Accounting_Refusal.None)
	testing.expect_value(t, step_debt_mark_waiting(sched, 30), Work_Accounting_Refusal.None)

	// Light clients 10 and 20 must run ahead of heavy client 30 (zero starvation).
	id, r = next_client_by_lowest_step_debt(sched)
	testing.expect_value(t, r, Work_Accounting_Refusal.None)
	testing.expect_value(t, id, u64(10))
	testing.expect_value(t, step_debt_record_duration(sched, 10, 100), Work_Accounting_Refusal.None)

	id, r = next_client_by_lowest_step_debt(sched)
	testing.expect_value(t, r, Work_Accounting_Refusal.None)
	testing.expect_value(t, id, u64(20))
	testing.expect_value(t, step_debt_record_duration(sched, 20, 100), Work_Accounting_Refusal.None)

	// Once 10 and 20 are no longer waiting, 30 runs cleanly.
	id, r = next_client_by_lowest_step_debt(sched)
	testing.expect_value(t, r, Work_Accounting_Refusal.None)
	testing.expect_value(t, id, u64(30))

	// Overflow guard on step_debt_record_duration leaves debt unchanged.
	testing.expect_value(t, step_debt_record_duration(sched, 30, max(u64)), Work_Accounting_Refusal.Overflow)

	// Capacity boundary: fill to STEP_DEBT_CAPACITY, refuse capacity+1.
	for i in 3 ..< STEP_DEBT_CAPACITY {
		testing.expect_value(t, step_debt_register(sched, u64(100 + i)), Work_Accounting_Refusal.None)
	}
	testing.expect_value(t, sched.count, STEP_DEBT_CAPACITY)
	testing.expect_value(t, step_debt_register(sched, 9999), Work_Accounting_Refusal.Capacity_Full)
	testing.expect_value(t, step_debt_remove(sched, 10), Work_Accounting_Refusal.None)
	testing.expect_value(t, step_debt_register(sched, 9999), Work_Accounting_Refusal.None)
}
