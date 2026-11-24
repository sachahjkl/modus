// Per-share block quota policy for writable storage shares
// (src/md/features/recipes.md, "Per-share block quota").
//
// Keeps the border validation of share block limits and the overflow-safe
// commit check that prevents a limited share from exceeding its own quota or
// thinning versions of the parent store in one freestanding package owned by
// the storage service.
package share_quota

// Closed set of reasons why a share block limit request at storage.share is
// accepted or refused.
Limit_Refusal :: enum u8 {
	None                    = 0,
	Negative                = 1,
	Read_Only_Has_Limit     = 2,
	Exceeds_Store_Limit     = 3,
}

// Closed set of commit quota decisions for a share with a block cap.
Check_Decision :: enum u8 {
	Allow            = 0,
	Over_Share_Limit = 1,
	Over_Store_Limit = 2,
	Uncounted        = 3,
}

// effective_share_limit validates block_limit passed to storage.share against
// read_only and the maker's store_limit.
// - 0 means no separate per-share cap (inherits store_limit as before).
// - Negative values, values above store_limit, and non-zero values on a
//   read-only share are refused.
effective_share_limit :: proc "contextless" (requested_limit: i64, read_only: bool, store_limit: u64) -> (limit: u64, refusal: Limit_Refusal) {
	if requested_limit < 0 {
		return 0, .Negative
	}
	if requested_limit == 0 {
		return 0, .None
	}
	if read_only {
		return 0, .Read_Only_Has_Limit
	}
	if u64(requested_limit) > store_limit {
		return 0, .Exceeds_Store_Limit
	}
	return u64(requested_limit), .None
}

// effective_pending_limit returns the block cap on in-memory pending writes
// (write_range) for a connection.
effective_pending_limit :: proc "contextless" (share_limit: u64, store_limit: u64) -> u64 {
	if share_limit == 0 {
		return store_limit
	}
	return min(share_limit, store_limit)
}

// effective_usage_limit returns the limit reported by storage.usage() so a
// limited share sees its own cap and never learns the parent store's limit.
effective_usage_limit :: proc "contextless" (share_limit: u64, store_limit: u64) -> u64 {
	if share_limit == 0 {
		return store_limit
	}
	return min(share_limit, store_limit)
}

// check_commit decides whether a commit of net block change `delta` on a share
// with cap `share_limit` is permitted without thinning any version of the
// parent store.
// - Releases and shrinks (delta <= 0) are always allowed so a holder at or
//   above its cap can remove entries and free space.
// - Growth (delta > 0) requires a counted share tree (`counted == true`),
//   projected share usage <= share_limit, and projected store usage <= store_limit.
check_commit :: proc "contextless" (
	share_limit: u64,
	share_blocks_before: u64,
	delta: i64,
	store_used: u64,
	store_limit: u64,
	counted: bool,
) -> (decision: Check_Decision, projected_share: i64, projected_store: i64) {
	if share_limit == 0 {
		return .Allow, 0, 0
	}
	cap_i64 := i64(min(share_limit, u64(max(i64))))
	store_cap_i64 := i64(min(store_limit, u64(max(i64))))

	// Shrinking or zero-net-block commits never violate a quota and must
	// always succeed so a full share can delete objects.
	if delta <= 0 {
		dec := u64(-delta)
		rem_share := share_blocks_before > dec ? share_blocks_before - dec : 0
		rem_store := store_used > dec ? store_used - dec : 0
		return .Allow, i64(min(rem_share, u64(max(i64)))), i64(min(rem_store, u64(max(i64))))
	}

	if !counted {
		over := cap_i64 < max(i64) ? cap_i64 + 1 : max(i64)
		return .Uncounted, over, store_cap_i64
	}

	add := u64(delta)
	share_after := share_blocks_before > max(u64) - add ? max(u64) : share_blocks_before + add
	store_after := store_used > max(u64) - add ? max(u64) : store_used + add
	projected_share = i64(min(share_after, u64(max(i64))))
	projected_store = i64(min(store_after, u64(max(i64))))

	if share_after > share_limit {
		return .Over_Share_Limit, projected_share, projected_store
	}
	if store_after > store_limit {
		return .Over_Store_Limit, projected_share, projected_store
	}
	return .Allow, projected_share, projected_store
}
