#+build !freestanding
package machine_wire

import "core:testing"

// The kept pages hold at the edge of the budget: a growth that leaves the
// kept pages whole is allowed, one page more is refused; a store and a
// partner stop at their shares; the largest counts do not wrap.
@(test)
memory_growth_keeps_the_kept_pages_and_the_shares :: proc(t: ^testing.T) {
	shares := memory_shares_of(2048 + 512, 512)
	testing.expect(t, shares.store_share_pages == 512 && shares.peer_share_pages == 1024)
	// The edge of the budget: 512 kept, 16 left to take.
	testing.expect(t, memory_growth_allowed(shares, 512 + 16, 16, 0, 0))
	testing.expect(t, !memory_growth_allowed(shares, 512 + 16, 17, 0, 0))
	testing.expect(t, memory_growth_allowed(shares, 512, 0, 0, 0))
	testing.expect(t, !memory_growth_allowed(shares, 511, 0, 0, 0))
	testing.expect(t, !memory_growth_allowed(shares, 0, 1, 0, 0))
	// A step of 512 pages on a budget that holds 513 past the kept pages
	// would take the kept pages: an exact commit of 1 page does not.
	testing.expect(t, !memory_growth_allowed(shares, 512 + 100, 512, 0, 0))
	testing.expect(t, memory_growth_allowed(shares, 512 + 100, 1, 0, 0))
	// The share of a store, then of a partner.
	testing.expect(t, memory_growth_allowed(shares, 1 << 20, 12, 500, 500))
	testing.expect(t, !memory_growth_allowed(shares, 1 << 20, 13, 500, 500))
	testing.expect(t, !memory_growth_allowed(shares, 1 << 20, 1, 100, 1024))
	testing.expect(t, !memory_growth_allowed(shares, 1 << 20, 1, 600, 600))
	testing.expect(t, !memory_growth_allowed(shares, max(u64), max(u64), 0, 0))
	// A budget under the kept pages leaves the mesh nothing.
	none := memory_shares_of(100, 512)
	testing.expect(t, !memory_growth_allowed(none, 1 << 20, 1, 0, 0))
}
