#+build !freestanding
package system

import "modus:support/disk_program"
import "core:testing"

// The rule of a starter (docs/MODULE_CONTRACT.md, "The budget that a module
// asks for"): the least for a part of 0, the request up to the largest
// budget, and each limited part named.
@(test)
budget_decide_accepts_limits_and_fills :: proc(t: ^testing.T) {
	least := Budget_Request{pages = 2048, programs = 1, threads = 1}
	largest := Budget_Request{pages = 16384, programs = 8, threads = 32}

	// A request under the largest budget is accepted as it is, also a part
	// below the least: a module that asks for less is not given more.
	granted, limited := budget_decide({pages = 4096, programs = 1, threads = 2}, least, largest)
	testing.expect_value(t, granted, Budget_Request{pages = 4096, programs = 1, threads = 2})
	testing.expect_value(t, limited, Budget_Parts{})
	granted, limited = budget_decide({pages = 256, programs = 1, threads = 1}, least, largest)
	testing.expect_value(t, granted.pages, 256)
	testing.expect_value(t, limited, Budget_Parts{})

	// A request of exactly the largest budget is accepted.
	granted, limited = budget_decide(largest, least, largest)
	testing.expect_value(t, granted, largest)
	testing.expect_value(t, limited, Budget_Parts{})

	// No request, or a part of 0 (a record of an older, shorter size): the
	// least budget of that part.
	granted, limited = budget_decide({}, least, largest)
	testing.expect_value(t, granted, least)
	testing.expect_value(t, limited, Budget_Parts{})
	granted, _ = budget_decide({pages = 5000}, least, largest)
	testing.expect_value(t, granted, Budget_Request{pages = 5000, programs = 1, threads = 1})

	// A part above the largest budget gets the largest, and is named.
	granted, limited = budget_decide({pages = 50000, programs = 9, threads = 2}, least, largest)
	testing.expect_value(t, granted, Budget_Request{pages = 16384, programs = 8, threads = 2})
	testing.expect_value(t, limited, Budget_Parts{.Pages, .Programs})
	granted, limited = budget_decide({pages = max(u64), programs = max(u64), threads = max(u64)}, least, largest)
	testing.expect_value(t, granted, largest)
	testing.expect_value(t, limited, Budget_Parts{.Pages, .Programs, .Threads})

	// A larger largest budget for one program widens: its request is
	// accepted.
	granted, limited = budget_decide({pages = 41984, programs = 2, threads = 6}, least, {pages = 41984, programs = 8, threads = 32})
	testing.expect_value(t, granted.pages, 41984)
	testing.expect_value(t, limited, Budget_Parts{})
}

// A disk program gets at most one program slot and 4 threads, whatever its
// file asks, and the one budget of the disk programs pays a bounded count
// of them: the programs of the boot image keep the rest of the budget of
// the root service.
@(test)
a_disk_program_gets_at_most_its_own_largest_budget :: proc(t: ^testing.T) {
	least := Budget_Request{pages = 2048, programs = 1, threads = 1}
	largest := disk_program.LARGEST_BUDGET
	shared := disk_program.PROGRAMS_BUDGET

	// A hostile file asks for everything: it gets the largest of a disk
	// program, each part named on the log.
	granted, limited := budget_decide({pages = max(u64), programs = 63, threads = 255}, least, largest)
	testing.expect_value(t, granted, Budget_Request{pages = 8192, programs = 1, threads = 4})
	testing.expect_value(t, limited, Budget_Parts{.Pages, .Programs, .Threads})

	// A file with no request gets the least budget, which the largest holds.
	granted, limited = budget_decide({}, least, largest)
	testing.expect_value(t, granted, least)
	testing.expect_value(t, limited, Budget_Parts{})

	// One disk program fits in the shared budget, and the largest is not the
	// whole of it: one disk program never takes every page.
	testing.expect(t, largest.pages < shared.pages && largest.programs <= shared.programs && largest.threads <= shared.threads)
	testing.expect_value(t, largest.programs, 1)
	testing.expect(t, largest.threads <= 4)

	// The disk programs that the shared budget pays at one time, each at its
	// largest: as many as its program slots, or fewer, whatever they ask.
	held := shared
	count := 0
	for {
		if _, short := budget_first_short_part(largest, held); short {
			break
		}
		held.pages -= largest.pages
		held.programs -= largest.programs
		held.threads -= largest.threads
		count += 1
	}
	testing.expect(t, count >= 1 && u64(count) <= shared.programs, "a bounded count of disk programs runs at one time")
	// The share of the root service that the disk programs take is a
	// small part of its 63 programs and 255 threads.
	testing.expect(t, shared.programs <= 4 && shared.threads <= 16)
}

// The first part that a holder cannot pay: the part that a refusal names.
@(test)
budget_first_short_part_names_the_part :: proc(t: ^testing.T) {
	needed := Budget_Request{pages = 4096, programs = 2, threads = 6}
	part, short := budget_first_short_part(needed, {pages = 4096, programs = 2, threads = 6})
	testing.expect(t, !short, "a holder of exactly the amounts can pay")
	part, short = budget_first_short_part(needed, {pages = 9000, programs = 1, threads = 2})
	testing.expect(t, short)
	testing.expect_value(t, part, Budget_Part.Programs)
	part, short = budget_first_short_part(needed, {pages = 100, programs = 0, threads = 0})
	testing.expect_value(t, part, Budget_Part.Pages)
	testing.expect_value(t, budget_part_names[part], "pages")
}
