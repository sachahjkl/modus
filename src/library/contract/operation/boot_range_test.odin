#+build !freestanding
package operation

import info "modus:contract/boot_info"
import "core:testing"

@(private = "file")
PAGE :: 4096 // The pages of a run, as boot_range_add counts them.
@(private = "file")
FREE :: u64(info.Memory_Kind.Free)
@(private = "file")
LOADED :: u64(info.Memory_Kind.Boot)

// A full table keeps its runs: a run past the capacity is counted and not
// kept, and no kept run changes. A run that continues the last kept run
// still joins it.
@(test)
a_full_table_of_runs_counts_each_run_and_keeps_the_first :: proc(t: ^testing.T) {
	report := new(Boot_Report)
	defer free(report)
	// Runs of one page with a gap of one page: none follows the run before.
	for index in 0 ..< u64(BOOT_RANGE_CAPACITY) {
		boot_range_add(report, index * 2 * PAGE, 1, FREE)
	}
	testing.expect_value(t, report.range_count, BOOT_RANGE_CAPACITY)
	testing.expect_value(t, report.firmware_ranges, BOOT_RANGE_CAPACITY)
	before := report.ranges
	boot_range_add(report, BOOT_RANGE_CAPACITY * 2 * PAGE, 1, FREE)
	testing.expect_value(t, report.range_count, BOOT_RANGE_CAPACITY)
	testing.expect_value(t, report.firmware_ranges, BOOT_RANGE_CAPACITY + 1)
	testing.expect(t, report.ranges == before, "a run past the capacity changes no kept run")
	last := before[BOOT_RANGE_CAPACITY - 1]
	boot_range_add(report, last.start + last.page_count * PAGE, 2, FREE)
	testing.expect_value(t, report.range_count, BOOT_RANGE_CAPACITY)
	testing.expect_value(t, report.firmware_ranges, BOOT_RANGE_CAPACITY + 2)
	testing.expect_value(t, report.ranges[BOOT_RANGE_CAPACITY - 1].page_count, 3)
}

// A run of no page is counted and kept nowhere, first or after a run, and
// joins nothing.
@(test)
a_run_of_no_page_is_counted_and_not_kept :: proc(t: ^testing.T) {
	report := new(Boot_Report)
	defer free(report)
	boot_range_add(report, 0, 0, FREE)
	testing.expect_value(t, report.range_count, 0)
	testing.expect_value(t, report.firmware_ranges, 1)
	boot_range_add(report, PAGE, 1, FREE)
	boot_range_add(report, 2 * PAGE, 0, LOADED)
	boot_range_add(report, 2 * PAGE, 0, FREE)
	testing.expect_value(t, report.range_count, 1)
	testing.expect_value(t, report.firmware_ranges, 4)
	testing.expect_value(t, report.ranges[0], Boot_Range{start = PAGE, page_count = 1, kind = FREE})
}

// A run whose end passes the top of the addresses joins no run: its end
// would wrap to a low address and join a run there that does not follow
// it.
@(test)
a_run_at_the_top_of_the_addresses_joins_no_run :: proc(t: ^testing.T) {
	report := new(Boot_Report)
	defer free(report)
	top_page := u64(max(u64) - (PAGE - 1))
	boot_range_add(report, top_page, 1, FREE)
	boot_range_add(report, 0, 1, FREE)
	testing.expect_value(t, report.range_count, 2)
	testing.expect_value(t, report.ranges[0], Boot_Range{start = top_page, page_count = 1, kind = FREE})
	testing.expect_value(t, report.ranges[1], Boot_Range{start = 0, page_count = 1, kind = FREE})
	// A run that follows the last one, but whose pages would pass the top.
	report^ = {}
	below_top := (top_page - PAGE) / PAGE
	boot_range_add(report, PAGE, below_top, FREE)
	end := PAGE + below_top * PAGE
	boot_range_add(report, end, 2, FREE)
	testing.expect_value(t, report.range_count, 2)
	testing.expect_value(t, report.ranges[0].page_count, below_top)
	testing.expect_value(t, report.ranges[1], Boot_Range{start = end, page_count = 2, kind = FREE})
}

// A run joins the last run only when it follows it with the same kind.
// The successful cases last: the joins.
@(test)
a_run_joins_only_the_run_that_it_follows :: proc(t: ^testing.T) {
	report := new(Boot_Report)
	defer free(report)
	boot_range_add(report, PAGE, 2, FREE)
	boot_range_add(report, 3 * PAGE, 1, LOADED) // Follows, of another kind.
	boot_range_add(report, 5 * PAGE, 1, LOADED) // The same kind, after a gap.
	boot_range_add(report, 5 * PAGE, 1, LOADED) // The same start again: it does not follow.
	testing.expect_value(t, report.range_count, 4)
	testing.expect_value(t, report.ranges[0], Boot_Range{start = PAGE, page_count = 2, kind = FREE})
	testing.expect_value(t, report.ranges[1], Boot_Range{start = 3 * PAGE, page_count = 1, kind = LOADED})
	testing.expect_value(t, report.ranges[2], Boot_Range{start = 5 * PAGE, page_count = 1, kind = LOADED})
	testing.expect_value(t, report.ranges[3], Boot_Range{start = 5 * PAGE, page_count = 1, kind = LOADED})
	boot_range_add(report, 6 * PAGE, 3, LOADED)
	boot_range_add(report, 9 * PAGE, 1, LOADED)
	testing.expect_value(t, report.range_count, 4)
	testing.expect_value(t, report.firmware_ranges, 6)
	testing.expect_value(t, report.ranges[3], Boot_Range{start = 5 * PAGE, page_count = 5, kind = LOADED})
}
