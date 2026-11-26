#+build !freestanding
package budget_growth

import "core:strings"
import "core:testing"
import "modus:contract/root_plan_values"

// Refusals and edge cases come first: no row refused before reading pool or
// rate limit; 0 and > ceiling refused; rate limit enforced on both growth
// and refusal (including now < last_decision_at and period_ms == 0);
// ceiling overflow refused; capacity and rate-slot exhaustion refused;
// start-list reserve theft and caller-reserve double-counting both refused;
// no leaked amount in any refusal sentence.
@(test)
decide_enforces_refusals_and_edges :: proc(t: ^testing.T) {
	// 1. No growth row (ceiling == 0): refused at border even if available is 0
	// and rate limit would otherwise trigger.
	ref, res, pool, counted := decide({
		ceiling_pages       = 0,
		asked_pages         = 100,
		rate_slot_available = true,
		now                 = 10,
		last_decision_at    = 10,
		has_last_decision   = true,
		period_ms           = 1000,
		available_pages     = 0,
	})
	testing.expect(t, ref == .No_Row && res == 0 && pool == 0 && !counted)

	// 2. Bad pages: 0, ceiling + 1, max(u64).
	for bad in ([?]u64{0, 4097, max(u64)}) {
		r, _, _, c := decide({ceiling_pages = 4096, asked_pages = bad, rate_slot_available = true, period_ms = 1000, available_pages = 100_000})
		testing.expectf(t, r == .Bad_Pages && !c, "asked %d gave %v", bad, r)
	}

	// 3. Rate limit: now < last, now == last, now == last + period - 1 refused;
	// now == last + period allowed; period_ms == 0 clamped to 1 ms.
	r_back, _, _, c_back := decide({ceiling_pages = 4096, asked_pages = 100, rate_slot_available = true, now = 4999, last_decision_at = 5000, has_last_decision = true, period_ms = 1000, available_pages = 10_000})
	testing.expect(t, r_back == .Too_Soon && !c_back)
	r_same, _, _, c_same := decide({ceiling_pages = 4096, asked_pages = 100, rate_slot_available = true, now = 5000, last_decision_at = 5000, has_last_decision = true, period_ms = 1000, available_pages = 10_000})
	testing.expect(t, r_same == .Too_Soon && !c_same)
	r_zero_period, _, _, _ := decide({ceiling_pages = 4096, asked_pages = 100, rate_slot_available = true, now = 5000, last_decision_at = 5000, has_last_decision = true, period_ms = 0, available_pages = 10_000})
	testing.expect(t, r_zero_period == .Too_Soon)
	r_before, _, _, _ := decide({ceiling_pages = 4096, asked_pages = 100, rate_slot_available = true, now = 5999, last_decision_at = 5000, has_last_decision = true, period_ms = 1000, available_pages = 10_000})
	testing.expect(t, r_before == .Too_Soon)
	r_edge, _, p_edge, c_edge := decide({ceiling_pages = 4096, asked_pages = 100, rate_slot_available = true, now = 6000, last_decision_at = 5000, has_last_decision = true, period_ms = 1000, available_pages = 10_000})
	testing.expect(t, r_edge == .None && p_edge == 100 && c_edge)

	// 4. Ceiling edges: paid + asked == ceiling succeeds, +1 fails, u64 wrap fails.
	r_exact, _, p_exact, _ := decide({ceiling_pages = 4096, paid_pages = 3096, asked_pages = 1000, rate_slot_available = true, period_ms = 1000, available_pages = 1000})
	testing.expect(t, r_exact == .None && p_exact == 1000)
	r_over, _, _, c_over := decide({ceiling_pages = 4096, paid_pages = 3096, asked_pages = 1001, rate_slot_available = true, period_ms = 1000, available_pages = 10_000})
	testing.expect(t, r_over == .Over_Ceiling && c_over)
	r_wrap, _, _, _ := decide({ceiling_pages = max(u64), paid_pages = max(u64) - 10, asked_pages = 20, rate_slot_available = true, period_ms = 1000, available_pages = 10_000})
	testing.expect(t, r_wrap == .Over_Ceiling)

	// 5. Capacity: EXTRAS_PER_PROCESS, TABLE_CAPACITY, and full rate table refused.
	r_proc_full, _, _, _ := decide({ceiling_pages = 4096, asked_pages = 1, extras_held = EXTRAS_PER_PROCESS, rate_slot_available = true, period_ms = 1000, available_pages = 10_000})
	testing.expect(t, r_proc_full == .Full)
	r_tbl_full, _, _, _ := decide({ceiling_pages = 4096, asked_pages = 1, table_used = TABLE_CAPACITY, rate_slot_available = true, period_ms = 1000, available_pages = 10_000})
	testing.expect(t, r_tbl_full == .Full)
	r_rate_full, _, _, _ := decide({ceiling_pages = 4096, asked_pages = 1, rate_slot_available = false, period_ms = 1000, available_pages = 10_000})
	testing.expect(t, r_rate_full == .Full)

	// 6. Start-list reserve protection: caller's reserve_left (50) cannot
	// steal pages when available_pages (own - start_list_reserved = 20) < asked (50).
	r_steal, _, _, c_steal := decide({
		ceiling_pages        = 4096,
		growth_reserve_pages = 50,
		asked_pages          = 50,
		rate_slot_available  = true,
		period_ms            = 1000,
		available_pages      = 20,
	})
	testing.expect(t, r_steal == .No_Pages && c_steal)

	// 7. No double-counting of caller reserve: own/available = 100, caller
	// reserve = 50, asked = 120 must be refused (only 100 exist in total).
	r_double, _, _, c_double := decide({
		ceiling_pages        = 4096,
		growth_reserve_pages = 50,
		asked_pages          = 120,
		rate_slot_available  = true,
		period_ms            = 1000,
		available_pages      = 100,
	})
	testing.expect(t, r_double == .No_Pages && c_double)

	// 8. Reserve-only and split allocations within available_pages succeed.
	r_res, from_res, from_pool, _ := decide({
		ceiling_pages        = 4096,
		growth_reserve_pages = 1024,
		reserve_used_pages   = 256,
		asked_pages          = 768,
		rate_slot_available  = true,
		period_ms            = 1000,
		available_pages      = 768,
	})
	testing.expect(t, r_res == .None && from_res == 768 && from_pool == 0)

	r_split, s_res, s_pool, _ := decide({
		ceiling_pages        = 4096,
		growth_reserve_pages = 500,
		reserve_used_pages   = 200,
		asked_pages          = 600,
		rate_slot_available  = true,
		period_ms            = 1000,
		available_pages      = 600,
	})
	testing.expect(t, r_split == .None && s_res == 300 && s_pool == 300)

	// 9. Every refusal sentence is non-empty (except None) and obeys docs/WRITING.md.
	for kind in Grow_Refusal {
		sentence := GROW_REFUSAL_SENTENCES[kind]
		if kind == .None {
			testing.expect(t, sentence == "")
		} else {
			testing.expect(t, len(sentence) > 0 && len(sentence) < 96)
			testing.expect(t, !strings.contains(sentence, "invalid") && !strings.contains(sentence, "failed"))
		}
	}
}

// Table lifecycle: take, duplicate/zero/capacity+1 refusal, rate-table
// saturation, double release refusal, drain waiting for full pages back,
// and stop cleanup.
@(test)
table_lifecycle_take_release_drain_and_stop :: proc(t: ^testing.T) {
	tbl: Table
	// Zero/invalid inputs refused.
	testing.expect(t, grow_take(&tbl, 0, 10, 100, 0, 1000) == 0)
	testing.expect(t, grow_take(&tbl, 1, 0, 100, 0, 1000) == 0)
	testing.expect(t, grow_take(&tbl, 1, 10, 0, 0, 1000) == 0)
	testing.expect(t, grow_take(&tbl, 1, 10, 100, 101, 1000) == 0)
	testing.expect(t, !has_rate_slot(&tbl, 0))

	// Fill EXTRAS_PER_PROCESS slots for owner 1; slot EXTRAS_PER_PROCESS + 1 refused.
	for idx in u64(0) ..< u64(EXTRAS_PER_PROCESS) {
		g := grow_take(&tbl, 1, 100 + idx, 64, 0, 1000 + idx)
		testing.expect(t, g == idx + 1)
	}
	testing.expect(t, grow_take(&tbl, 1, 999, 64, 0, 2000) == 0)
	handles1, count1 := stop(&tbl, 1)
	testing.expect(t, count1 == EXTRAS_PER_PROCESS && handles1[0] == 100)
	testing.expect(t, table_used(&tbl) == 0)

	// Fill TABLE_CAPACITY across owners; TABLE_CAPACITY + 1 refused.
	for idx in u64(0) ..< u64(TABLE_CAPACITY) {
		owner := 10 + idx / u64(EXTRAS_PER_PROCESS)
		testing.expect(t, grow_take(&tbl, owner, 1000 + idx, 32, 0, 3000) != 0)
	}
	testing.expect(t, table_used(&tbl) == TABLE_CAPACITY)
	testing.expect(t, grow_take(&tbl, 99, 9999, 32, 0, 3000) == 0)
	tbl = {}

	// Fill rate table completely: existing owner keeps its slot, new owner gets false.
	for idx in u64(1) ..= u64(PROCESS_LIMIT_CAPACITY) {
		testing.expect(t, has_rate_slot(&tbl, idx))
		note_decision(&tbl, idx, 5000)
	}
	testing.expect(t, has_rate_slot(&tbl, 1))
	testing.expect(t, !has_rate_slot(&tbl, u64(PROCESS_LIMIT_CAPACITY) + 1))
	tbl = {}

	g1 := grow_take(&tbl, 1, 101, 512, 128, 2000)
	testing.expect(t, g1 == 1)
	// Duplicate handle refused.
	testing.expect(t, grow_take(&tbl, 2, 101, 512, 0, 2000) == 0)

	count, pages, res := held_by(&tbl, 1)
	testing.expect(t, count == 1 && pages == 512 && res == 128)
	at, has_last := last_decision(&tbl, 1)
	testing.expect(t, has_last && at == 2000)

	// Another owner cannot release owner 1's growth; 0 growth refused.
	_, wrong_owner := release(&tbl, 2, g1)
	testing.expect(t, !wrong_owner)
	_, zero_growth := release(&tbl, 1, 0)
	testing.expect(t, !zero_growth)

	// Release marks draining; double release refused; pages stay counted until drained.
	rel_handle, rel_ok := release(&tbl, 1, g1)
	testing.expect(t, rel_ok && rel_handle == 101 && draining(&tbl))
	_, rel_again := release(&tbl, 1, g1)
	testing.expect(t, !rel_again)
	c_drain, p_drain, _ := held_by(&tbl, 1)
	testing.expect(t, c_drain == 1 && p_drain == 512)

	// Partial return does not drain; full return drains and frees the slot.
	testing.expect(t, !drained(&tbl, 101, 511))
	testing.expect(t, drained(&tbl, 101, 512))
	testing.expect(t, !draining(&tbl))
	c_after, p_after, r_after := held_by(&tbl, 1)
	testing.expect(t, c_after == 0 && p_after == 0 && r_after == 0)

	// Stop cleans up all active & draining budgets and clears rate entry.
	g2 := grow_take(&tbl, 7, 201, 256, 0, 3000)
	g3 := grow_take(&tbl, 7, 202, 128, 64, 4000)
	testing.expect(t, g2 == 2 && g3 == 3)
	_, _ = release(&tbl, 7, g2)
	handles, hcount := stop(&tbl, 7)
	testing.expect(t, hcount == 2 && handles[0] == 201 && handles[1] == 202)
	testing.expect(t, table_used(&tbl) == 0)
	_, still_rated := last_decision(&tbl, 7)
	testing.expect(t, !still_rated)

	// Line bound allows REFUSED_LINES_PER_SECOND per second.
	bound: Line_Bound
	for _ in 0 ..< REFUSED_LINES_PER_SECOND {
		testing.expect(t, line_allowed(&bound, 1500))
	}
	testing.expect(t, !line_allowed(&bound, 1999))
	testing.expect(t, line_allowed(&bound, 2000))
}

// Unbounded row integration with Budget_Grow: grows up to the machine's
// safety ceiling (or lower row ceiling), never past the safety ceiling,
// and growth pages remain unreserved (pool exhaustion returns No_Pages).
@(test)
unbounded_row_growth_meets_safety_ceiling_and_stays_unreserved :: proc(t: ^testing.T) {
	SAFETY_CEILING :: u64(50_000)

	// 1. Unbounded row with no explicit ceiling grows up to safety ceiling,
	// refused at safety ceiling + 1, and refused when pool is short.
	unb_policy := root_plan_values.Module_Budget_Policy{size_kind = .Unbounded}
	ceil, res, capped := root_plan_values.effective_growth_of(unb_policy, SAFETY_CEILING)
	testing.expect(t, ceil == SAFETY_CEILING && res == 0 && !capped)

	// Pool short: growth is not reserved, so No_Pages is returned (never reserves).
	r_short, _, _, c_short := decide({
		ceiling_pages        = ceil,
		growth_reserve_pages = res,
		paid_pages           = 2048,
		asked_pages          = 4096,
		rate_slot_available  = true,
		period_ms            = 1000,
		available_pages      = 4095,
	})
	testing.expect(t, r_short == .No_Pages && c_short)

	// Exact hit of safety ceiling succeeds; one page past fails Over_Ceiling.
	r_fit, f_res, f_pool, _ := decide({
		ceiling_pages        = ceil,
		growth_reserve_pages = res,
		paid_pages           = 2048,
		asked_pages          = SAFETY_CEILING - 2048,
		rate_slot_available  = true,
		period_ms            = 1000,
		available_pages      = 100_000,
	})
	testing.expect(t, r_fit == .None && f_res == 0 && f_pool == SAFETY_CEILING - 2048)

	r_past, _, _, c_past := decide({
		ceiling_pages        = ceil,
		growth_reserve_pages = res,
		paid_pages           = SAFETY_CEILING,
		asked_pages          = 1,
		rate_slot_available  = true,
		period_ms            = 1000,
		available_pages      = 100_000,
	})
	testing.expect(t, r_past == .Over_Ceiling && c_past)

	// 2. Unbounded row with lower ceiling stops at the lower ceiling.
	lower_policy := root_plan_values.Module_Budget_Policy{size_kind = .Unbounded, has_ceiling = true, ceiling_pages = 16_384}
	low_ceil, _, low_capped := root_plan_values.effective_growth_of(lower_policy, SAFETY_CEILING)
	testing.expect(t, low_ceil == 16_384 && !low_capped)
	r_low_past, _, _, _ := decide({
		ceiling_pages       = low_ceil,
		paid_pages          = 16_384,
		asked_pages         = 1,
		rate_slot_available = true,
		period_ms           = 1000,
		available_pages     = 100_000,
	})
	testing.expect(t, r_low_past == .Over_Ceiling)

	// 3. Unbounded row attempting ceiling > safety ceiling is capped at safety ceiling.
	bypass_policy := root_plan_values.Module_Budget_Policy{size_kind = .Unbounded, has_ceiling = true, ceiling_pages = 200_000}
	cap_ceil, _, was_capped := root_plan_values.effective_growth_of(bypass_policy, SAFETY_CEILING)
	testing.expect(t, cap_ceil == SAFETY_CEILING && was_capped)
	r_bypass, _, _, _ := decide({
		ceiling_pages       = cap_ceil,
		paid_pages          = SAFETY_CEILING,
		asked_pages         = 1,
		rate_slot_available = true,
		period_ms           = 1000,
		available_pages     = 200_000,
	})
	testing.expect(t, r_bypass == .Over_Ceiling)
}
