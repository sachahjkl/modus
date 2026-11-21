#+build !freestanding
package operation

import "core:testing"

// The list pages at each edge of the frame list: the inline pages, one list
// page, the top page, the limit of an object, one past it, and the counts
// at the top of the type, where a sum that rounds up would wrap to a few
// list pages.
@(test)
the_list_pages_at_each_edge :: proc(t: ^testing.T) {
	Edge :: struct {
		page_count: u64,
		list_pages: u64,
	}
	edges := [?]Edge {
		{max(u64), (1 << 55) + 1}, // 2^55 - 1 full list pages, one part list page and the top page.
		{max(u64) - (MEMORY_LIST_ENTRIES - 2), (1 << 55) + 1}, // The count whose rounding sum was 2^64.
		{max(u64) - (MEMORY_LIST_ENTRIES - 1), 1 << 55}, // 2^55 - 1 full list pages and the top page.
		{MEMORY_PAGE_LIMIT + 1, MEMORY_LIST_ENTRIES + 2},
		{MEMORY_PAGE_LIMIT, MEMORY_LIST_ENTRIES + 1},
		{2 * MEMORY_LIST_ENTRIES + 1, 4},
		{2 * MEMORY_LIST_ENTRIES, 3},
		{MEMORY_LIST_ENTRIES + 1, 3}, // Two list pages and the top page.
		{MEMORY_LIST_ENTRIES, 1},
		{MEMORY_INLINE_PAGES + 1, 1},
		{MEMORY_INLINE_PAGES, 0},
		{1, 0},
		{0, 0},
		{1000, 3}, // The example of the comment.
	}
	for edge in edges {
		testing.expectf(t, memory_list_pages(edge.page_count) == edge.list_pages, "%v pages: %v list pages, not %v", edge.page_count, memory_list_pages(edge.page_count), edge.list_pages)
	}
}

// The cost of an object is its pages and its list pages, and it never
// wraps: a count whose cost passes the type costs the largest value, which
// no budget holds.
@(test)
the_cost_of_an_object_never_wraps :: proc(t: ^testing.T) {
	testing.expect_value(t, memory_cost(max(u64)), max(u64))
	testing.expect_value(t, memory_cost(max(u64) - 1), max(u64))
	testing.expect_value(t, memory_cost(max(u64) - (MEMORY_LIST_ENTRIES - 2)), max(u64))
	// Each count costs at least its pages and its list pages, and a larger
	// count never costs less.
	counts := [?]u64{0, 1, MEMORY_INLINE_PAGES, MEMORY_INLINE_PAGES + 1, MEMORY_LIST_ENTRIES, MEMORY_LIST_ENTRIES + 1, MEMORY_PAGE_LIMIT, MEMORY_PAGE_LIMIT + 1, 1 << 62, max(u64) - (1 << 56), max(u64) - (MEMORY_LIST_ENTRIES - 1), max(u64)}
	previous := u64(0)
	for page_count in counts {
		cost := memory_cost(page_count)
		testing.expectf(t, cost >= page_count && cost >= memory_list_pages(page_count), "%v pages cost %v", page_count, cost)
		testing.expectf(t, cost >= previous, "%v pages cost %v, less than a smaller count", page_count, cost)
		previous = cost
	}
	// The successful cases last: the exact costs of the frame list.
	testing.expect_value(t, memory_cost(0), 0)
	testing.expect_value(t, memory_cost(1), 1)
	testing.expect_value(t, memory_cost(MEMORY_INLINE_PAGES), MEMORY_INLINE_PAGES)
	testing.expect_value(t, memory_cost(MEMORY_INLINE_PAGES + 1), MEMORY_INLINE_PAGES + 2)
	testing.expect_value(t, memory_cost(16), 17) // The example of the comment.
	testing.expect_value(t, memory_cost(MEMORY_LIST_ENTRIES), MEMORY_LIST_ENTRIES + 1)
	testing.expect_value(t, memory_cost(MEMORY_LIST_ENTRIES + 1), MEMORY_LIST_ENTRIES + 4)
	testing.expect_value(t, memory_cost(MEMORY_PAGE_LIMIT), MEMORY_PAGE_LIMIT + MEMORY_LIST_ENTRIES + 1)
}
