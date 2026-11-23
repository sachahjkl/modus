package machine_wire

// The shares of the memory of the mesh (src/md/features/several_machines.md,
// "The memory of the mesh"): the tables of a peer grow from the budget of
// its process, and the process keeps a part of that budget for its other
// work. One store, and the stores of one partner, hold at most a share of
// what the mesh may take, so one partner cannot hold the mesh: a partner
// that sends a version past its share is refused at the page that passes
// it, and the others keep their room.

// The shares, in pages, from the budget of the process at the start of the
// mesh.
Memory_Shares :: struct {
	kept_pages:        u64, // Never taken by a table of the mesh.
	store_share_pages: u64, // The versions of one store.
	peer_share_pages:  u64, // The versions of the stores of one partner. An object in assembly, which names no store, counts as its own store.
}

// The parts: a store holds a quarter of the mesh, a partner a half.
MEMORY_STORE_SHARE_PARTS :: 4
MEMORY_PEER_SHARE_PARTS :: 2

// memory_shares_of gives the shares of a budget of budget_pages that keeps
// kept_pages for the rest of its process.
memory_shares_of :: proc "contextless" (budget_pages, kept_pages: u64) -> Memory_Shares {
	mesh := budget_pages > kept_pages ? budget_pages - kept_pages : 0
	return {kept_pages = kept_pages, store_share_pages = mesh / MEMORY_STORE_SHARE_PARTS, peer_share_pages = mesh / MEMORY_PEER_SHARE_PARTS}
}

// memory_growth_allowed says if a growth of push_pages may take place: the
// budget left keeps the kept pages after it, the store that grows stays in
// its share, and its partner in its share. store_pages and peer_pages are
// the pages that they hold before the growth; a growth of no store (an
// object) names the same count for both.
memory_growth_allowed :: proc "contextless" (shares: Memory_Shares, budget_pages_left, push_pages, store_pages, peer_pages: u64) -> bool {
	if budget_pages_left < shares.kept_pages || push_pages > budget_pages_left - shares.kept_pages {
		return false
	}
	if store_pages > shares.store_share_pages || push_pages > shares.store_share_pages - store_pages {
		return false
	}
	if peer_pages > shares.peer_share_pages || push_pages > shares.peer_share_pages - peer_pages {
		return false
	}
	return true
}
