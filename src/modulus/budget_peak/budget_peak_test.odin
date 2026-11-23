#+build !freestanding
package budget_peak

import "core:os"
import "core:strings"
import "core:testing"

// A model of the paths of the kernel that take and give pages of a budget,
// in the order of one start: the top table and the own log ring at
// Process_Create, an object at Memory_Create, a commit of pages, a page
// table that a map pays, a child budget that the parent carves, the end of
// the object, and the end of the child, whose pages return to the parent.
// The least count holds the peak of the takes; the returns never raise it.
@(test)
the_least_count_holds_the_peak_of_each_spend_path :: proc(t: ^testing.T) {
	free, least: u64
	created(&free, &least, 1000)
	testing.expect(t, free == 1000 && least == 1000)
	testing.expect(t, spend(&free, &least, 1 + 4)) // The top table and the own log ring.
	testing.expect(t, spend(&free, &least, 17)) // An object of 16 pages and its list page.
	testing.expect(t, spend(&free, &least, 32)) // A commit of 32 pages.
	testing.expect(t, spend(&free, &least, 1)) // A page table of a map.
	testing.expect_value(t, peak(1000, least), 55)
	// A child budget carved from this one: its pages leave the parent.
	child_free, child_least: u64
	testing.expect(t, spend(&free, &least, 400))
	created(&child_free, &child_least, 400)
	testing.expect_value(t, peak(1000, least), 455)
	// The child spends: its own least count moves, never the parent's.
	testing.expect(t, spend(&child_free, &child_least, 300))
	testing.expect_value(t, peak(400, child_least), 300)
	testing.expect_value(t, peak(1000, least), 455)
	// The object ends, then the child ends: its pages return to the parent.
	give_back(&free, 17)
	give_back(&child_free, 300)
	give_back(&free, child_free)
	testing.expect_value(t, free, 1000 - 5 - 32 - 1)
	testing.expect_value(t, peak(1000, least), 455)
	// A second rise below the first peak changes nothing; one above it does.
	testing.expect(t, spend(&free, &least, 100))
	testing.expect_value(t, peak(1000, least), 455)
	testing.expect(t, spend(&free, &least, 500))
	testing.expect_value(t, peak(1000, least), 638)
}

// The edges: a spend of 0, a spend of every free page, a spend of one page
// more (refused, nothing changes), a budget of no page, a budget of the
// largest count, and a least count above the creation.
@(test)
a_spend_past_the_free_pages_changes_nothing :: proc(t: ^testing.T) {
	free, least: u64
	created(&free, &least, 10)
	testing.expect(t, spend(&free, &least, 0))
	testing.expect(t, free == 10 && least == 10)
	testing.expect(t, !spend(&free, &least, 11))
	testing.expect(t, free == 10 && least == 10)
	testing.expect(t, spend(&free, &least, 10))
	testing.expect(t, free == 0 && least == 0)
	testing.expect(t, !spend(&free, &least, 1))
	testing.expect_value(t, peak(10, least), 10)
	created(&free, &least, 0)
	testing.expect(t, !spend(&free, &least, 1))
	testing.expect_value(t, peak(0, least), 0)
	created(&free, &least, max(u64))
	testing.expect(t, spend(&free, &least, max(u64)))
	testing.expect_value(t, peak(max(u64), least), max(u64))
	testing.expect_value(t, peak(5, 9), 0)
}

// Each place of the kernel that takes pages from a budget goes through its
// one spend procedure: a new path that lowered the free pages by itself
// would leave the least count behind, and the peak would be false.
@(test)
the_kernel_takes_budget_pages_at_one_place :: proc(t: ^testing.T) {
	folder := "src/modulus"
	entries, read_error := os.read_all_directory_by_path(folder, context.temp_allocator)
	if !testing.expect(t, read_error == nil, "the sources of the kernel are readable") {
		return
	}
	found_spend := false
	for entry in entries {
		if !strings.has_suffix(entry.name, ".odin") {
			continue
		}
		bytes, file_error := os.read_entire_file(entry.fullpath, context.temp_allocator)
		if !testing.expect(t, file_error == nil) {
			continue
		}
		for line, number in strings.split_lines(string(bytes), context.temp_allocator) {
			code := strings.trim_space(line)
			if strings.has_prefix(code, "//") {
				continue
			}
			if strings.contains(code, "budget_peak.spend(") {
				found_spend = true
			}
			testing.expectf(t, !strings.contains(code, "amounts.pages -="), "%s, line %d, takes pages of a budget with no spend: %s", entry.name, number + 1, code)
		}
	}
	testing.expect(t, found_spend, "the kernel spends through budget_peak.spend")
}
