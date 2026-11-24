#+build !freestanding
package share_quota

import "core:testing"

@(test)
effective_share_limit_edges_and_refusals :: proc(t: ^testing.T) {
	// Negative limits refused for both read-only and writable shares.
	for neg in ([?]i64{-1, -100, min(i64)}) {
		limit, refusal := effective_share_limit(neg, false, 1024)
		testing.expect_value(t, limit, u64(0))
		testing.expect_value(t, refusal, Limit_Refusal.Negative)

		limit_ro, refusal_ro := effective_share_limit(neg, true, 1024)
		testing.expect_value(t, limit_ro, u64(0))
		testing.expect_value(t, refusal_ro, Limit_Refusal.Negative)
	}

	// Zero means no separate per-share cap for both read-only and writable shares.
	limit0, ref0 := effective_share_limit(0, false, 1024)
	testing.expect_value(t, limit0, u64(0))
	testing.expect_value(t, ref0, Limit_Refusal.None)
	limit0_ro, ref0_ro := effective_share_limit(0, true, 1024)
	testing.expect_value(t, limit0_ro, u64(0))
	testing.expect_value(t, ref0_ro, Limit_Refusal.None)

	// Non-zero limit on a read-only share is refused.
	for val in ([?]i64{1, 64, 1024}) {
		limit, refusal := effective_share_limit(val, true, 1024)
		testing.expect_value(t, limit, u64(0))
		testing.expect_value(t, refusal, Limit_Refusal.Read_Only_Has_Limit)
	}

	// Writable share limit above store_limit is refused.
	limit_over, ref_over := effective_share_limit(1025, false, 1024)
	testing.expect_value(t, limit_over, u64(0))
	testing.expect_value(t, ref_over, Limit_Refusal.Exceeds_Store_Limit)

	limit_max, ref_max := effective_share_limit(max(i64), false, 1024)
	testing.expect_value(t, limit_max, u64(0))
	testing.expect_value(t, ref_max, Limit_Refusal.Exceeds_Store_Limit)

	// Exact edges: 1 and exact store_limit succeed.
	limit_one, ref_one := effective_share_limit(1, false, 1024)
	testing.expect_value(t, limit_one, u64(1))
	testing.expect_value(t, ref_one, Limit_Refusal.None)

	limit_eq, ref_eq := effective_share_limit(1024, false, 1024)
	testing.expect_value(t, limit_eq, u64(1024))
	testing.expect_value(t, ref_eq, Limit_Refusal.None)
}

@(test)
check_commit_enforces_share_quota_without_evicting_parent :: proc(t: ^testing.T) {
	// Parent store holds 500 blocks out of 1000; share holds 0 out of 64.
	// A 64-block write fits cleanly inside the share quota.
	dec, p_share, p_store := check_commit(64, 0, 64, 500, 1000, true)
	testing.expect_value(t, dec, Check_Decision.Allow)
	testing.expect_value(t, p_share, i64(64))
	testing.expect_value(t, p_store, i64(564))

	// One block past the share quota is refused even though parent store has 436 free blocks.
	dec, p_share, p_store = check_commit(64, 64, 1, 564, 1000, true)
	testing.expect_value(t, dec, Check_Decision.Over_Share_Limit)
	testing.expect_value(t, p_share, i64(65))
	testing.expect_value(t, p_store, i64(565))

	// If the parent store itself has only 10 free blocks left, a 20-block write
	// inside a 64-block share is refused with Over_Store_Limit rather than thinning
	// sibling versions of the parent store.
	dec, p_share, p_store = check_commit(64, 0, 20, 990, 1000, true)
	testing.expect_value(t, dec, Check_Decision.Over_Store_Limit)
	testing.expect_value(t, p_share, i64(20))
	testing.expect_value(t, p_store, i64(1010))

	// Uncounted tree (tree_usage over bound or damaged) refuses growth.
	dec, p_share, _ = check_commit(64, 0, 1, 100, 1000, false)
	testing.expect_value(t, dec, Check_Decision.Uncounted)
	testing.expect_value(t, p_share, i64(65))

	// Shrinking or deleting (delta <= 0) is always allowed, even at cap or uncounted.
	dec, p_share, p_store = check_commit(64, 64, -10, 1000, 1000, false)
	testing.expect_value(t, dec, Check_Decision.Allow)
	testing.expect_value(t, p_share, i64(54))
	testing.expect_value(t, p_store, i64(990))

	dec_zero, _, _ := check_commit(64, 64, 0, 1000, 1000, false)
	testing.expect_value(t, dec_zero, Check_Decision.Allow)

	// Overflow safety: max(u64) blocks + positive delta never wraps to allowed.
	dec_ovf, _, _ := check_commit(64, max(u64) - 5, 10, 0, max(u64), true)
	testing.expect_value(t, dec_ovf, Check_Decision.Over_Share_Limit)
}

@(test)
effective_pending_and_usage_limits :: proc(t: ^testing.T) {
	// Zero share limit inherits store limit.
	testing.expect_value(t, effective_pending_limit(0, 4096), u64(4096))
	testing.expect_value(t, effective_usage_limit(0, 4096), u64(4096))

	// Smaller share limit wins; if store limit later shrank below share limit, store limit caps both.
	testing.expect_value(t, effective_pending_limit(128, 4096), u64(128))
	testing.expect_value(t, effective_usage_limit(128, 4096), u64(128))
	testing.expect_value(t, effective_pending_limit(500, 200), u64(200))
	testing.expect_value(t, effective_usage_limit(500, 200), u64(200))
}
