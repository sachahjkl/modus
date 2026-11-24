#+build !freestanding
package budget_growth

import "core:strings"
import "core:testing"

// Refusals and edge cases come first: no row refused before reading pool or
// rate limit; 0 and > ceiling refused; rate limit enforced on both growth
// and refusal; ceiling overflow refused; capacity refused; pool shortage
// refused with no leaked amount in any refusal sentence.
@(test)
decide_enforces_refusals_and_edges :: proc(t: ^testing.T) {
	// 1. No growth row (ceiling == 0): refused at border even if pool is 0
	// and rate limit would otherwise trigger.
	ref, res, pool, counted := decide({
		ceiling_pages     = 0,
		asked_pages       = 100,
		now               = 10,
		last_decision_at  = 10,
		has_last_decision = true,
		period_ms         = 1000,
		shared_pool_pages = 0,
	})
	testing.expect(t, ref == .No_Row && res == 0 && pool == 0 && !counted)

	// 2. Bad pages: 0, ceiling + 1, max(u64).
	for bad in ([?]u64{0, 4097, max(u64)}) {
		r, _, _, c := decide({ceiling_pages = 4096, asked_pages = bad, period_ms = 1000, shared_pool_pages = 100_000})
		testing.expectf(t, r == .Bad_Pages && !c, "asked %d gave %v", bad, r)
	}

	// 3. Rate limit: now == last, now == last + period - 1 refused; now == last + period allowed.
	r_same, _, _, c_same := decide({ceiling_pages = 4096, asked_pages = 100, now = 5000, last_decision_at = 5000, has_last_decision = true, period_ms = 1000, shared_pool_pages = 10_000})
	testing.expect(t, r_same == .Too_Soon && !c_same)
	r_before, _, _, _ := decide({ceiling_pages = 4096, asked_pages = 100, now = 5999, last_decision_at = 5000, has_last_decision = true, period_ms = 1000, shared_pool_pages = 10_000})
	testing.expect(t, r_before == .Too_Soon)
	r_edge, _, p_edge, c_edge := decide({ceiling_pages = 4096, asked_pages = 100, now = 6000, last_decision_at = 5000, has_last_decision = true, period_ms = 1000, shared_pool_pages = 10_000})
	testing.expect(t, r_edge == .None && p_edge == 100 && c_edge)

	// 4. Ceiling edges: paid + asked == ceiling succeeds, +1 fails, overflow fails.
	r_exact, _, p_exact, _ := decide({ceiling_pages = 4096, paid_pages = 3096, asked_pages = 1000, period_ms = 1000, shared_pool_pages = 1000})
	testing.expect(t, r_exact == .None && p_exact == 1000)
	r_over, _, _, c_over := decide({ceiling_pages = 4096, paid_pages = 3096, asked_pages = 1001, period_ms = 1000, shared_pool_pages = 10_000})
	testing.expect(t, r_over == .Over_Ceiling && c_over)
	r_wrap, _, _, _ := decide({ceiling_pages = 4096, paid_pages = max(u64) - 10, asked_pages = 20, period_ms = 1000, shared_pool_pages = 10_000})
	testing.expect(t, r_wrap == .Over_Ceiling)

	// 5. Capacity: EXTRAS_PER_PROCESS and TABLE_CAPACITY refused.
	r_proc_full, _, _, _ := decide({ceiling_pages = 4096, asked_pages = 1, extras_held = EXTRAS_PER_PROCESS, period_ms = 1000, shared_pool_pages = 10_000})
	testing.expect(t, r_proc_full == .Full)
	r_tbl_full, _, _, _ := decide({ceiling_pages = 4096, asked_pages = 1, table_used = TABLE_CAPACITY, period_ms = 1000, shared_pool_pages = 10_000})
	testing.expect(t, r_tbl_full == .Full)

	// 6. Growth reserve bypasses an empty shared pool; overflow into empty shared pool fails.
	r_res, from_res, from_pool, _ := decide({
		ceiling_pages        = 4096,
		growth_reserve_pages = 1024,
		reserve_used_pages   = 256,
		asked_pages          = 768,
		period_ms            = 1000,
		shared_pool_pages    = 0,
	})
	testing.expect(t, r_res == .None && from_res == 768 && from_pool == 0)

	r_short, _, _, c_short := decide({
		ceiling_pages        = 4096,
		growth_reserve_pages = 1024,
		reserve_used_pages   = 256,
		asked_pages          = 769,
		period_ms            = 1000,
		shared_pool_pages    = 0,
	})
	testing.expect(t, r_short == .No_Pages && c_short)

	// 7. Split between reserve and shared pool when both contribute.
	r_split, s_res, s_pool, _ := decide({
		ceiling_pages        = 4096,
		growth_reserve_pages = 500,
		reserve_used_pages   = 200,
		asked_pages          = 600,
		period_ms            = 1000,
		shared_pool_pages    = 300,
	})
	testing.expect(t, r_split == .None && s_res == 300 && s_pool == 300)

	// 8. Every refusal sentence is non-empty (except None) and obeys docs/WRITING.md.
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

// Table lifecycle: take, duplicate/zero refusal, release, drain waiting for
// full pages back, stop cleanup, and rate-limit cleanup.
@(test)
table_lifecycle_take_release_drain_and_stop :: proc(t: ^testing.T) {
	tbl: Table
	// Zero/invalid inputs refused.
	testing.expect(t, grow_take(&tbl, 0, 10, 100, 0, 1000) == 0)
	testing.expect(t, grow_take(&tbl, 1, 0, 100, 0, 1000) == 0)
	testing.expect(t, grow_take(&tbl, 1, 10, 0, 0, 1000) == 0)
	testing.expect(t, grow_take(&tbl, 1, 10, 100, 101, 1000) == 0)

	g1 := grow_take(&tbl, 1, 101, 512, 128, 2000)
	testing.expect(t, g1 == 1)
	// Duplicate handle refused.
	testing.expect(t, grow_take(&tbl, 2, 101, 512, 0, 2000) == 0)

	count, pages, res := held_by(&tbl, 1)
	testing.expect(t, count == 1 && pages == 512 && res == 128)
	at, has_last := last_decision(&tbl, 1)
	testing.expect(t, has_last && at == 2000)

	// Another owner cannot release owner 1's growth.
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
