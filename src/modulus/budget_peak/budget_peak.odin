// The free pages of a budget and the least count of them since its
// creation (src/md/features/module_budget_request.md, "The peak of a
// budget"). The kernel takes pages from a budget at each place that pays
// for memory, and gives them back at each end of what they paid; the least
// count follows only the takes, so the pages at the creation less it are
// the most that the budget paid at one time: its peak. The root service
// reads it at the first state of work of a process, against its floor.
//
// The kernel holds the frame lock around each call: this package reads and
// writes plain words.
//
// This package allocates no memory and calls no kernel operation.
package budget_peak

// created starts the count of a budget made with pages: nothing is paid
// yet, so the least count is the pages.
created :: proc "contextless" (free: ^u64, least: ^u64, pages: u64) {
	free^ = pages
	least^ = pages
}

// spend takes count pages from a budget that holds them, and lowers the
// least count when the free pages go below it. The caller checked that the
// budget holds them: a count past the free pages is a fault of the caller,
// and the budget then keeps its pages and its least count.
spend :: proc "contextless" (free: ^u64, least: ^u64, count: u64) -> (taken: bool) {
	if count > free^ {
		return false
	}
	free^ -= count
	least^ = min(least^, free^)
	return true
}

// give_back returns count pages to a budget: what they paid ended. The
// least count keeps the peak that the budget reached.
give_back :: proc "contextless" (free: ^u64, count: u64) {
	free^ += count
}

// peak gives the most pages that a budget paid at one time: its pages at
// the creation less its least count of free pages. A least count above
// the pages at the creation, which only a budget that received pages back
// past its creation shows, gives 0.
peak :: proc "contextless" (pages_at_creation: u64, least: u64) -> u64 {
	return pages_at_creation - min(pages_at_creation, least)
}
