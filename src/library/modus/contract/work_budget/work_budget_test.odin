#+build !freestanding
package work_budget

import "core:testing"
import "modus:contract/errors"
import op "modus:contract/operation"

@(private = "file")
test_requirements :: proc() -> Work_Budget_Requirements {
	return {
		stack_pages                    = WORK_THREAD_DEFAULT_STACK_PAGES, // 16 -> memory_cost 17
		scratch_pages                  = 8,                               // 8 -> memory_cost 9
		ring_pages                     = DEFAULT_RING_AND_REGION_PAGES,   // 19
		minimum_processor_microseconds = 50_000,
		maximum_pages                  = 512,
	}
}

@(test)
enum_word_borders_refuse_unknown_values :: proc(t: ^testing.T) {
	// Unknown Work_Account_State words: 0, one past the bound, and max(u64).
	for bad_word in ([]u64{0, 6, 7, 100, max(u64)}) {
		_, ok := work_account_state_from_word(bad_word)
		testing.expectf(t, !ok, "state word %d must be refused", bad_word)
	}
	for state in Work_Account_State {
		decoded, ok := work_account_state_from_word(u64(state))
		testing.expect(t, ok, "known state word must decode")
		testing.expect_value(t, decoded, state)
	}

	// Unknown Work_Budget_Refusal words: one past the bound and max(u64).
	for bad_word in ([]u64{10, 11, 255, max(u64)}) {
		_, ok := work_budget_refusal_from_word(bad_word)
		testing.expectf(t, !ok, "refusal word %d must be refused", bad_word)
	}
	for refusal in Work_Budget_Refusal {
		decoded, ok := work_budget_refusal_from_word(u64(refusal))
		testing.expect(t, ok, "known refusal word must decode")
		testing.expect_value(t, decoded, refusal)
	}

	// Every refusal maps to a valid error record; None maps to zero.
	none_record := work_budget_refusal_to_error_record(.None)
	testing.expect_value(t, none_record.kind, i64(errors.Kind.None))
	for refusal in Work_Budget_Refusal {
		if refusal == .None {
			continue
		}
		record := work_budget_refusal_to_error_record(refusal, 1, 2, 3, 4)
		_, kind_ok := errors.kind_of_word(record.kind)
		_, unit_ok := errors.unit_of_word(record.unit)
		testing.expect(t, kind_ok && record.kind != i64(errors.Kind.None), "refusal must produce a known non-None error kind")
		testing.expect(t, unit_ok, "refusal must produce a known error unit")
	}
}

@(test)
requirements_and_child_amounts_edges :: proc(t: ^testing.T) {
	req := test_requirements()
	base_pages, base_ok := work_budget_base_pages(req)
	testing.expect(t, base_ok, "valid requirements have base pages")
	// stack_cost(16) = 17, thread area = 3, ring_pages = 19 -> 39.
	testing.expect_value(t, base_pages, u64(39))

	min_pages, min_ok := work_budget_minimum_pages(req)
	testing.expect(t, min_ok, "valid requirements have minimum pages")
	// base(39) + scratch_cost(8 = 9) -> 48.
	testing.expect_value(t, min_pages, u64(48))

	// Refused malformed requirements: edges 0, bound+1, max(u64).
	bad_cases := [?]Work_Budget_Requirements{
		{stack_pages = 0, scratch_pages = 4, ring_pages = 19, minimum_processor_microseconds = 10_000},
		{stack_pages = MAX_WORK_BUDGET_PAGES + 1, scratch_pages = 0, ring_pages = 0, minimum_processor_microseconds = 10_000},
		{stack_pages = max(u64), scratch_pages = 0, ring_pages = 0, minimum_processor_microseconds = 10_000},
		{stack_pages = 16, scratch_pages = max(u64), ring_pages = 0, minimum_processor_microseconds = 10_000},
		{stack_pages = 16, scratch_pages = 0, ring_pages = max(u64), minimum_processor_microseconds = 10_000},
		{stack_pages = 16, scratch_pages = 4, ring_pages = 19, minimum_processor_microseconds = 0},
		{stack_pages = 16, scratch_pages = 4, ring_pages = 19, minimum_processor_microseconds = MAX_PROCESSOR_MICROSECONDS_PER_SECOND + 1},
		{stack_pages = 16, scratch_pages = 4, ring_pages = 19, minimum_processor_microseconds = max(u64)},
		{stack_pages = 16, scratch_pages = 8, ring_pages = 19, minimum_processor_microseconds = 10_000, maximum_pages = min_pages - 1},
		{stack_pages = 16, scratch_pages = 8, ring_pages = 19, minimum_processor_microseconds = 10_000, maximum_pages = MAX_WORK_BUDGET_PAGES + 1},
	}
	for bad in bad_cases {
		testing.expect(t, !work_budget_requirements_valid(bad), "malformed requirements must be refused")
		_, ok := work_budget_child_amounts(bad)
		testing.expect(t, !ok, "child amounts must fail for malformed requirements")
	}

	// Child amounts: exact minimum, exact cap, one past cap, and max(u64).
	amounts, ok := work_budget_child_amounts(req)
	testing.expect(t, ok, "child amounts for exact minimum must succeed")
	testing.expect_value(t, amounts.pages, min_pages)
	testing.expect_value(t, amounts.processes, u64(0))
	testing.expect_value(t, amounts.threads, u64(1))
	testing.expect_value(t, amounts.processor, req.minimum_processor_microseconds)
	testing.expect_value(t, amounts.log_records, u64(0))

	at_cap, at_cap_ok := work_budget_child_amounts(req, req.maximum_pages - min_pages)
	testing.expect(t, at_cap_ok, "child amounts at maximum_pages must succeed")
	testing.expect_value(t, at_cap.pages, req.maximum_pages)

	_, over_cap_ok := work_budget_child_amounts(req, req.maximum_pages - min_pages + 1)
	testing.expect(t, !over_cap_ok, "child amounts one past maximum_pages must fail")

	_, overflow_ok := work_budget_child_amounts(req, max(u64))
	testing.expect(t, !overflow_ok, "child amounts with max(u64) extra pages must fail")
}

@(test)
work_budget_check_refuses_all_edge_violations :: proc(t: ^testing.T) {
	req := test_requirements()
	min_pages, _ := work_budget_minimum_pages(req)
	min_time := req.minimum_processor_microseconds

	// Missing Spend right is always refused first.
	testing.expect_value(t, work_budget_check(req, min_pages, min_time, 1, false), Work_Budget_Refusal.Missing_Spend_Right)
	testing.expect_value(t, work_budget_check_rights(req, {pages = min_pages, threads = 1, processor = min_time}, {.Read, .Commit, .Give}), Work_Budget_Refusal.Missing_Spend_Right)

	// Missing thread slot: 0 refused, 1 accepted.
	testing.expect_value(t, work_budget_check(req, min_pages, min_time, 0, true), Work_Budget_Refusal.Missing_Thread_Slot)

	// Time edges: 0, 1, bound-1 refused; bound accepted; over limit and max(u64) refused.
	testing.expect_value(t, work_budget_check(req, min_pages, 0, 1, true), Work_Budget_Refusal.Too_Little_Time)
	testing.expect_value(t, work_budget_check(req, min_pages, 1, 1, true), Work_Budget_Refusal.Too_Little_Time)
	testing.expect_value(t, work_budget_check(req, min_pages, min_time - 1, 1, true), Work_Budget_Refusal.Too_Little_Time)
	testing.expect_value(t, work_budget_check(req, min_pages, MAX_PROCESSOR_MICROSECONDS_PER_SECOND + 1, 1, true), Work_Budget_Refusal.Invalid_State)
	testing.expect_value(t, work_budget_check(req, min_pages, max(u64), 1, true), Work_Budget_Refusal.Invalid_State)

	// Page edges: 0, 1, bound-1 refused; bound and maximum_pages accepted; one past maximum and max(u64) refused.
	testing.expect_value(t, work_budget_check(req, 0, min_time, 1, true), Work_Budget_Refusal.Too_Few_Pages)
	testing.expect_value(t, work_budget_check(req, 1, min_time, 1, true), Work_Budget_Refusal.Too_Few_Pages)
	testing.expect_value(t, work_budget_check(req, min_pages - 1, min_time, 1, true), Work_Budget_Refusal.Too_Few_Pages)
	testing.expect_value(t, work_budget_check(req, req.maximum_pages + 1, min_time, 1, true), Work_Budget_Refusal.Invalid_State)
	testing.expect_value(t, work_budget_check(req, max(u64), min_time, 1, true), Work_Budget_Refusal.Invalid_State)

	// Malformed requirements refused even with valid offer.
	bad_req := req
	bad_req.stack_pages = 0
	testing.expect_value(t, work_budget_check(bad_req, min_pages, min_time, 1, true), Work_Budget_Refusal.Invalid_State)

	// Valid cases: exact minimum, exact maximum, and Spend-only rights.
	testing.expect_value(t, work_budget_check(req, min_pages, min_time, 1, true), Work_Budget_Refusal.None)
	testing.expect_value(t, work_budget_check(req, req.maximum_pages, min_time, 1, true), Work_Budget_Refusal.None)
	testing.expect_value(t, work_budget_check_rights(req, {pages = min_pages, threads = 1, processor = min_time}, {.Spend}), Work_Budget_Refusal.None)
}

@(test)
accounting_snapshot_border_validation :: proc(t: ^testing.T) {
	valid_active := Accounting_Snapshot{
		connection_identifier        = 7,
		state                        = .Active,
		pages_limit                  = 128,
		pages_charged                = 48,
		pages_peak                   = 64,
		processor_limit_microseconds = 50_000,
		processor_nanoseconds        = 1_200_000,
		step_debt_nanoseconds        = 40_000,
		requests_served              = 12,
		exhaustion_count             = 0,
	}
	raw := accounting_snapshot_encode(valid_active)

	// Unknown state words: 0, one past bound, max(u64).
	for bad_state in ([]u64{0, 6, max(u64)}) {
		corrupted := raw
		corrupted.state_word = bad_state
		_, refusal := accounting_snapshot_decode(corrupted)
		testing.expect_value(t, refusal, Work_Budget_Refusal.Invalid_State)
	}

	// Wrong version words.
	for bad_version in ([]u64{0, 2, max(u64)}) {
		corrupted := raw
		corrupted.version = bad_version
		_, refusal := accounting_snapshot_decode(corrupted)
		testing.expect_value(t, refusal, Work_Budget_Refusal.Invalid_State)
	}

	// Zero connection identifier.
	zero_id := raw
	zero_id.connection_identifier = 0
	_, refusal := accounting_snapshot_decode(zero_id)
	testing.expect_value(t, refusal, Work_Budget_Refusal.Invalid_State)

	// Charged exceeds limit.
	over_charged := raw
	over_charged.pages_charged = over_charged.pages_limit + 1
	over_charged.pages_peak = over_charged.pages_charged
	_, refusal = accounting_snapshot_decode(over_charged)
	testing.expect_value(t, refusal, Work_Budget_Refusal.Invalid_State)

	// Peak below charged or above limit.
	low_peak := raw
	low_peak.pages_peak = low_peak.pages_charged - 1
	_, refusal = accounting_snapshot_decode(low_peak)
	testing.expect_value(t, refusal, Work_Budget_Refusal.Invalid_State)

	high_peak := raw
	high_peak.pages_peak = high_peak.pages_limit + 1
	_, refusal = accounting_snapshot_decode(high_peak)
	testing.expect_value(t, refusal, Work_Budget_Refusal.Invalid_State)

	// Limits above maximum bounds.
	huge_pages := raw
	huge_pages.pages_limit = MAX_WORK_BUDGET_PAGES + 1
	_, refusal = accounting_snapshot_decode(huge_pages)
	testing.expect_value(t, refusal, Work_Budget_Refusal.Invalid_State)

	huge_time := raw
	huge_time.processor_limit_microseconds = MAX_PROCESSOR_MICROSECONDS_PER_SECOND + 1
	_, refusal = accounting_snapshot_decode(huge_time)
	testing.expect_value(t, refusal, Work_Budget_Refusal.Invalid_State)

	// Active with zero processor limit or zero page limit.
	no_time := raw
	no_time.processor_limit_microseconds = 0
	_, refusal = accounting_snapshot_decode(no_time)
	testing.expect_value(t, refusal, Work_Budget_Refusal.Invalid_State)

	// Exhausted with zero exhaustion_count refused.
	bad_exhausted := raw
	bad_exhausted.state_word = u64(Work_Account_State.Exhausted)
	bad_exhausted.exhaustion_count = 0
	_, refusal = accounting_snapshot_decode(bad_exhausted)
	testing.expect_value(t, refusal, Work_Budget_Refusal.Invalid_State)

	// Revoked or Closed with non-zero charged pages refused.
	for ended_state in ([]Work_Account_State{.Revoked, .Closed}) {
		leaked := raw
		leaked.state_word = u64(ended_state)
		leaked.pages_charged = 1
		_, refusal = accounting_snapshot_decode(leaked)
		testing.expect_value(t, refusal, Work_Budget_Refusal.Invalid_State)
	}

	// Valid round-trip for every valid state.
	decoded, ok_refusal := accounting_snapshot_decode(raw)
	testing.expect_value(t, ok_refusal, Work_Budget_Refusal.None)
	testing.expect_value(t, decoded, valid_active)

	exhausted_ok := valid_active
	exhausted_ok.state = .Exhausted
	exhausted_ok.exhaustion_count = 1
	decoded, ok_refusal = accounting_snapshot_decode(accounting_snapshot_encode(exhausted_ok))
	testing.expect_value(t, ok_refusal, Work_Budget_Refusal.None)
	testing.expect_value(t, decoded, exhausted_ok)

	revoked_ok := valid_active
	revoked_ok.state = .Revoked
	revoked_ok.pages_charged = 0
	decoded, ok_refusal = accounting_snapshot_decode(accounting_snapshot_encode(revoked_ok))
	testing.expect_value(t, ok_refusal, Work_Budget_Refusal.None)
	testing.expect_value(t, decoded, revoked_ok)
}

@(test)
table_refuses_service_own_budget_and_double_open_and_capacity :: proc(t: ^testing.T) {
	req := test_requirements()
	min_pages, _ := work_budget_minimum_pages(req)
	min_time := req.minimum_processor_microseconds
	SERVICE_BUDGET :: op.Handle(0x1001)

	// Uninitialized table refuses operations.
	uninit: Connection_Worker_Table
	testing.expect_value(t, connection_open(&uninit, 1, op.Handle(2), min_pages, min_time, 1, true, op.Handle(10)), Work_Budget_Refusal.Invalid_State)

	// Malformed requirements refused at table_init.
	bad_req := req
	bad_req.minimum_processor_microseconds = 0
	_, init_refusal := table_init(bad_req, SERVICE_BUDGET)
	testing.expect_value(t, init_refusal, Work_Budget_Refusal.Invalid_State)

	table, ok_refusal := table_init(req, SERVICE_BUDGET)
	testing.expect_value(t, ok_refusal, Work_Budget_Refusal.None)

	// Service NEVER runs client work on its own budget or handle 0.
	testing.expect_value(t, connection_open(&table, 1, 0, min_pages, min_time, 1, true, op.Handle(10)), Work_Budget_Refusal.Missing_Spend_Right)
	testing.expect_value(t, connection_open(&table, 1, SERVICE_BUDGET, min_pages, min_time, 1, true, op.Handle(10)), Work_Budget_Refusal.Invalid_State)
	testing.expect_value(t, connection_open(&table, 0, op.Handle(2), min_pages, min_time, 1, true, op.Handle(10)), Work_Budget_Refusal.Invalid_State)
	testing.expect_value(t, table_occupied_count(&table), 0)

	// Fill table to exact capacity MAX_ACCOUNTED_CONNECTIONS.
	for i in 1 ..= MAX_ACCOUNTED_CONNECTIONS {
		refusal := connection_open(&table, u64(i), op.Handle(100 + i), min_pages, min_time, 1, true, op.Handle(200 + i))
		testing.expect_value(t, refusal, Work_Budget_Refusal.None)
	}
	testing.expect_value(t, table_occupied_count(&table), MAX_ACCOUNTED_CONNECTIONS)
	testing.expect_value(t, table_active_count(&table), MAX_ACCOUNTED_CONNECTIONS)

	// Double-open of an existing ID returns Duplicate_Connection even when full.
	testing.expect_value(t, connection_open(&table, 1, op.Handle(999), min_pages, min_time, 1, true, op.Handle(998)), Work_Budget_Refusal.Duplicate_Connection)

	// One past capacity (MAX_ACCOUNTED_CONNECTIONS + 1) returns Too_Many_Connections.
	testing.expect_value(t, connection_open(&table, u64(MAX_ACCOUNTED_CONNECTIONS + 1), op.Handle(999), min_pages, min_time, 1, true, op.Handle(998)), Work_Budget_Refusal.Too_Many_Connections)
	testing.expect_value(t, table_occupied_count(&table), MAX_ACCOUNTED_CONNECTIONS)

	// Closing slot 3 frees a slot so MAX_ACCOUNTED_CONNECTIONS + 1 succeeds.
	closed_snap, close_refusal := connection_close(&table, 3)
	testing.expect_value(t, close_refusal, Work_Budget_Refusal.None)
	testing.expect_value(t, closed_snap.state, Work_Account_State.Closed)
	testing.expect_value(t, closed_snap.pages_charged, u64(0))
	testing.expect_value(t, accounting_snapshot_validate(closed_snap), Work_Budget_Refusal.None)
	testing.expect_value(t, table_occupied_count(&table), MAX_ACCOUNTED_CONNECTIONS - 1)

	// Stale close on slot 3 refused and changes nothing.
	_, stale_close := connection_close(&table, 3)
	testing.expect_value(t, stale_close, Work_Budget_Refusal.Invalid_State)
	testing.expect_value(t, table.closed_total, u64(1))

	// New connection now fits into reclaimed slot.
	testing.expect_value(t, connection_open(&table, u64(MAX_ACCOUNTED_CONNECTIONS + 1), op.Handle(999), min_pages, min_time, 1, true, op.Handle(998)), Work_Budget_Refusal.None)
	testing.expect_value(t, table_occupied_count(&table), MAX_ACCOUNTED_CONNECTIONS)
}

@(test)
exhaustion_isolates_one_client_while_siblings_keep_running :: proc(t: ^testing.T) {
	req := test_requirements()
	min_pages, _ := work_budget_minimum_pages(req) // 48; base = 39 -> 9 pages spare
	min_time := req.minimum_processor_microseconds

	table, init_refusal := table_init(req, op.Handle(1))
	testing.expect_value(t, init_refusal, Work_Budget_Refusal.None)

	// Open Client A (Inactive -> Active) with tight budget and Client B with ample budget.
	testing.expect_value(t, connection_open(&table, 10, op.Handle(10), min_pages, min_time, 1, true), Work_Budget_Refusal.None)
	// Cannot run work while Inactive.
	testing.expect_value(t, connection_begin_request(&table, 10), Work_Budget_Refusal.Invalid_State)
	// Activate with zero thread handle refused.
	testing.expect_value(t, connection_activate(&table, 10, 0), Work_Budget_Refusal.Invalid_State)
	// Activate cleanly.
	testing.expect_value(t, connection_activate(&table, 10, op.Handle(100)), Work_Budget_Refusal.None)
	// Double activate refused.
	testing.expect_value(t, connection_activate(&table, 10, op.Handle(101)), Work_Budget_Refusal.Invalid_State)

	// Open Client B directly as Active with 256 pages.
	testing.expect_value(t, connection_open(&table, 20, op.Handle(20), 256, min_time * 2, 1, true, op.Handle(200)), Work_Budget_Refusal.None)

	// Client A spends its remaining 9 pages exactly, then asks for 1 more page -> Exhausted!
	testing.expect_value(t, connection_begin_request(&table, 10), Work_Budget_Refusal.None)
	testing.expect_value(t, connection_charge_pages(&table, 10, 9), Work_Budget_Refusal.None)
	testing.expect_value(t, connection_charge_pages(&table, 10, 1), Work_Budget_Refusal.Budget_Exhausted)

	snap_a, snap_a_refusal := connection_snapshot(&table, 10)
	testing.expect_value(t, snap_a_refusal, Work_Budget_Refusal.None)
	testing.expect_value(t, snap_a.state, Work_Account_State.Exhausted)
	testing.expect_value(t, snap_a.exhaustion_count, u64(1))
	testing.expect_value(t, snap_a.pages_charged, min_pages)
	testing.expect_value(t, accounting_snapshot_validate(snap_a), Work_Budget_Refusal.None)

	// Exhausted Client A is refused further requests and charges.
	testing.expect_value(t, connection_begin_request(&table, 10), Work_Budget_Refusal.Budget_Exhausted)
	testing.expect_value(t, connection_charge_pages(&table, 10, 1), Work_Budget_Refusal.Budget_Exhausted)
	testing.expect_value(t, connection_charge_processor_time(&table, 10, 1000), Work_Budget_Refusal.Budget_Exhausted)

	// Sibling Client B is completely unaffected and continues serving requests.
	testing.expect_value(t, table_active_count(&table), 1)
	testing.expect_value(t, connection_begin_request(&table, 20), Work_Budget_Refusal.None)
	testing.expect_value(t, connection_charge_pages(&table, 20, 64), Work_Budget_Refusal.None)
	testing.expect_value(t, connection_complete_request(&table, 20, 250_000, 10_000), Work_Budget_Refusal.None)

	snap_b, snap_b_refusal := connection_snapshot(&table, 20)
	testing.expect_value(t, snap_b_refusal, Work_Budget_Refusal.None)
	testing.expect_value(t, snap_b.state, Work_Account_State.Active)
	testing.expect_value(t, snap_b.requests_served, u64(1))
	testing.expect_value(t, snap_b.processor_nanoseconds, u64(250_000))
	testing.expect_value(t, snap_b.step_debt_nanoseconds, u64(10_000))
	testing.expect_value(t, snap_b.exhaustion_count, u64(0))

	// Releasing below base pages is refused; releasing scratch pages succeeds.
	testing.expect_value(t, connection_release_pages(&table, 10, 10), Work_Budget_Refusal.Invalid_State)
	testing.expect_value(t, connection_release_pages(&table, 10, 9), Work_Budget_Refusal.None)

	// Replenishing Client A resumes it cleanly; overflow or too-little-time replenish is refused.
	testing.expect_value(t, connection_replenish(&table, 10, max(u64), min_time), Work_Budget_Refusal.Invalid_State)
	testing.expect_value(t, connection_replenish(&table, 10, 16, min_time - 1), Work_Budget_Refusal.Too_Little_Time)
	testing.expect_value(t, connection_replenish(&table, 10, 16, min_time), Work_Budget_Refusal.None)
	testing.expect_value(t, table_active_count(&table), 2)
	testing.expect_value(t, connection_begin_request(&table, 10), Work_Budget_Refusal.None)
	testing.expect_value(t, connection_complete_request(&table, 10, 50_000, 5_000), Work_Budget_Refusal.None)
}

@(test)
revoke_mid_call_reclaims_slot_and_rejects_stale_operations :: proc(t: ^testing.T) {
	req := test_requirements()
	min_pages, _ := work_budget_minimum_pages(req)
	min_time := req.minimum_processor_microseconds

	table, _ := table_init(req, op.Handle(1))

	// Fill table so reclaiming a revoked slot is proven under full capacity.
	for i in 1 ..= MAX_ACCOUNTED_CONNECTIONS {
		testing.expect_value(t, connection_open(&table, u64(i), op.Handle(10 + i), min_pages + 16, min_time, 1, true, op.Handle(100 + i)), Work_Budget_Refusal.None)
	}

	// Start a request on connection 4 and charge some pages + CPU time.
	testing.expect_value(t, connection_begin_request(&table, 4), Work_Budget_Refusal.None)
	testing.expect_value(t, connection_charge_pages(&table, 4, 4), Work_Budget_Refusal.None)
	testing.expect_value(t, connection_charge_processor_time(&table, 4, 80_000), Work_Budget_Refusal.None)

	// Revoke mid-call!
	revoked_snap, revoke_refusal := connection_revoke(&table, 4)
	testing.expect_value(t, revoke_refusal, Work_Budget_Refusal.None)
	testing.expect_value(t, revoked_snap.state, Work_Account_State.Revoked)
	testing.expect_value(t, revoked_snap.pages_charged, u64(0))
	testing.expect_value(t, revoked_snap.processor_nanoseconds, u64(80_000))
	testing.expect_value(t, accounting_snapshot_validate(revoked_snap), Work_Budget_Refusal.None)
	testing.expect_value(t, table_occupied_count(&table), MAX_ACCOUNTED_CONNECTIONS - 1)

	// Stale mid-call completion, second revoke, stale close, and new request all report Budget_Revoked.
	testing.expect_value(t, connection_complete_request(&table, 4, 10_000), Work_Budget_Refusal.Budget_Revoked)
	testing.expect_value(t, connection_begin_request(&table, 4), Work_Budget_Refusal.Budget_Revoked)
	testing.expect_value(t, connection_charge_pages(&table, 4, 1), Work_Budget_Refusal.Budget_Revoked)
	_, second_revoke := connection_revoke(&table, 4)
	testing.expect_value(t, second_revoke, Work_Budget_Refusal.Budget_Revoked)
	_, stale_close := connection_close(&table, 4)
	testing.expect_value(t, stale_close, Work_Budget_Refusal.Budget_Revoked)
	testing.expect_value(t, table.revoked_total, u64(1))

	// Sibling connection 5 is unaffected and can complete requests.
	testing.expect_value(t, connection_begin_request(&table, 5), Work_Budget_Refusal.None)
	testing.expect_value(t, connection_complete_request(&table, 5, 12_000, 2_000), Work_Budget_Refusal.None)

	// Reclaimed slot immediately accepts a brand-new connection.
	testing.expect_value(t, connection_open(&table, 99, op.Handle(99), min_pages, min_time, 1, true, op.Handle(199)), Work_Budget_Refusal.None)
	testing.expect_value(t, table_occupied_count(&table), MAX_ACCOUNTED_CONNECTIONS)
}

@(test)
shared_step_selection_and_overflow_refusal :: proc(t: ^testing.T) {
	req := test_requirements()
	min_pages, _ := work_budget_minimum_pages(req)
	min_time := req.minimum_processor_microseconds

	table, _ := table_init(req, op.Handle(1))
	testing.expect_value(t, connection_open(&table, 1, op.Handle(11), min_pages, min_time, 1, true, op.Handle(101)), Work_Budget_Refusal.None)
	testing.expect_value(t, connection_open(&table, 2, op.Handle(12), min_pages, min_time, 1, true, op.Handle(102)), Work_Budget_Refusal.None)

	// Connection 1 runs a heavy shared step (100_000 ns); connection 2 runs a light step (10_000 ns).
	testing.expect_value(t, connection_begin_request(&table, 1), Work_Budget_Refusal.None)
	testing.expect_value(t, connection_complete_request(&table, 1, 500_000, 100_000), Work_Budget_Refusal.None)
	testing.expect_value(t, connection_begin_request(&table, 2), Work_Budget_Refusal.None)
	testing.expect_value(t, connection_complete_request(&table, 2, 50_000, 10_000), Work_Budget_Refusal.None)

	// Connection 2 has less step debt, so it is chosen first.
	waiting := [?]u64{1, 2}
	next_id, ok := connection_next_shared_step(&table, waiting[:])
	testing.expect(t, ok, "a waiting active connection must be chosen")
	testing.expect_value(t, next_id, u64(2))

	// A newly opened connection 3 starts at the least active step debt (10_000), not 0.
	testing.expect_value(t, connection_open(&table, 3, op.Handle(13), min_pages, min_time, 1, true, op.Handle(103)), Work_Budget_Refusal.None)
	snap3, _ := connection_snapshot(&table, 3)
	testing.expect_value(t, snap3.step_debt_nanoseconds, u64(10_000))

	// Exhausting connection 2 excludes it from shared step selection.
	testing.expect_value(t, connection_mark_exhausted(&table, 2), Work_Budget_Refusal.None)
	waiting_all := [?]u64{999, 2, 1, 3}
	next_id, ok = connection_next_shared_step(&table, waiting_all[:])
	testing.expect(t, ok, "active connection 3 must be chosen when connection 2 is exhausted")
	testing.expect_value(t, next_id, u64(3))

	// Overflow on processor nanoseconds or step debt is refused without corrupting counters.
	testing.expect_value(t, connection_charge_processor_time(&table, 1, max(u64), 0), Work_Budget_Refusal.Invalid_State)
	testing.expect_value(t, connection_charge_processor_time(&table, 1, 0, max(u64)), Work_Budget_Refusal.Invalid_State)
	snap1, _ := connection_snapshot(&table, 1)
	testing.expect_value(t, snap1.processor_nanoseconds, u64(500_000))
	testing.expect_value(t, snap1.step_debt_nanoseconds, u64(100_000))
}
