#+build !freestanding
package system

import module "modus:contract/module"
import "modus:disk_process"
import "core:testing"

// The rule of a starter (docs/MODULE_CONTRACT.md, "The budget that a module
// asks for"): the least for a part of 0, the request up to the largest
// budget, and each limited part named.
@(test)
budget_decide_accepts_limits_and_fills :: proc(t: ^testing.T) {
	least := Budget_Request{pages = 2048, processes = 1, threads = 1}
	largest := Budget_Request{pages = 16384, processes = 8, threads = 32}

	// A request under the largest budget is accepted as it is, also a part
	// below the least: a module that asks for less is not given more.
	granted, limited := budget_decide({pages = 4096, processes = 1, threads = 2}, least, largest)
	testing.expect_value(t, granted, Budget_Request{pages = 4096, processes = 1, threads = 2})
	testing.expect_value(t, limited, Budget_Parts{})
	granted, limited = budget_decide({pages = 256, processes = 1, threads = 1}, least, largest)
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
	testing.expect_value(t, granted, Budget_Request{pages = 5000, processes = 1, threads = 1})

	// A part above the largest budget gets the largest, and is named.
	granted, limited = budget_decide({pages = 50000, processes = 9, threads = 2}, least, largest)
	testing.expect_value(t, granted, Budget_Request{pages = 16384, processes = 8, threads = 2})
	testing.expect_value(t, limited, Budget_Parts{.Pages, .Processes})
	granted, limited = budget_decide({pages = max(u64), processes = max(u64), threads = max(u64)}, least, largest)
	testing.expect_value(t, granted, largest)
	testing.expect_value(t, limited, Budget_Parts{.Pages, .Processes, .Threads})

	// A larger largest budget for one process widens: its request is
	// accepted.
	granted, limited = budget_decide({pages = 41984, processes = 2, threads = 6}, least, {pages = 41984, processes = 8, threads = 32})
	testing.expect_value(t, granted.pages, 41984)
	testing.expect_value(t, limited, Budget_Parts{})
}

// The largest budget of a process of the boot image is a quarter of the
// pages of the machine, never below the least largest budget. The edges
// first: no page, one page, the pages where the share reaches the least,
// one more, and the largest count that a machine can name.
@(test)
the_largest_budget_is_a_share_of_the_machine :: proc(t: ^testing.T) {
	least := module.LARGEST_BUDGET_LEAST
	share := u64(module.LARGEST_BUDGET_SHARE_OF_THE_MACHINE)
	testing.expect_value(t, module.largest_budget_of_machine(0), least)
	testing.expect_value(t, module.largest_budget_of_machine(1), least)
	at_least := least.pages * share
	testing.expect_value(t, module.largest_budget_of_machine(at_least - 1).pages, least.pages)
	testing.expect_value(t, module.largest_budget_of_machine(at_least).pages, least.pages)
	testing.expect_value(t, module.largest_budget_of_machine(at_least + share).pages, least.pages + 1)
	most := module.largest_budget_of_machine(max(u64))
	testing.expect_value(t, most.pages, max(u64) / share)
	// The processes and the threads do not follow the memory.
	testing.expect_value(t, most.processes, least.processes)
	testing.expect_value(t, most.threads, least.threads)
	// A machine of 1 GiB less the kernel: the address space test and the
	// Linux guest fit, which needed rows of exceptions under a cap of 64 MiB.
	machine := module.largest_budget_of_machine(200_000)
	testing.expect_value(t, machine.pages, 50_000)
	testing.expect(t, machine.pages >= 42338 && machine.pages >= 34932)
	// A request at the share is accepted, one page past it is limited.
	granted, limited := budget_decide({pages = machine.pages}, {pages = 2048, processes = 1, threads = 1}, machine)
	testing.expect_value(t, granted.pages, machine.pages)
	testing.expect_value(t, limited, Budget_Parts{})
	granted, limited = budget_decide({pages = machine.pages + 1}, {pages = 2048, processes = 1, threads = 1}, machine)
	testing.expect_value(t, granted.pages, machine.pages)
	testing.expect_value(t, limited, Budget_Parts{.Pages})
}

// The budget of the disk processes follows the largest budget of the
// machine, and one disk process gets half of it: never all of it, and
// never less than on the smallest machine.
@(test)
the_disk_budgets_follow_the_machine :: proc(t: ^testing.T) {
	smallest := disk_process.processes_budget_of(module.LARGEST_BUDGET_LEAST)
	testing.expect_value(t, smallest, disk_process.PROCESSES_BUDGET_LEAST)
	testing.expect_value(t, disk_process.largest_budget_of(smallest), disk_process.LARGEST_BUDGET_LEAST)
	// A largest budget below the least, which no machine gives, still gives
	// the least: the shared budget never shrinks under it.
	testing.expect_value(t, disk_process.processes_budget_of({pages = 1, processes = 1, threads = 1}), disk_process.PROCESSES_BUDGET_LEAST)
	shared := disk_process.processes_budget_of(module.largest_budget_of_machine(200_000))
	testing.expect_value(t, shared.pages, 50_000)
	testing.expect_value(t, shared.processes, disk_process.PROCESSES_BUDGET_LEAST.processes)
	testing.expect_value(t, shared.threads, disk_process.PROCESSES_BUDGET_LEAST.threads)
	one := disk_process.largest_budget_of(shared)
	testing.expect_value(t, one, Budget_Request{pages = 25_000, processes = 1, threads = 4})
	testing.expect(t, one.pages < shared.pages)
}

// A disk process gets at most one process slot and 4 threads, whatever its
// file asks, and the one budget of the disk processes pays a bounded count
// of them: the processes of the boot image keep the rest of the budget of
// the root service.
@(test)
a_disk_process_gets_at_most_its_own_largest_budget :: proc(t: ^testing.T) {
	least := Budget_Request{pages = 2048, processes = 1, threads = 1}
	largest := disk_process.LARGEST_BUDGET_LEAST
	shared := disk_process.PROCESSES_BUDGET_LEAST

	// A hostile file asks for everything: it gets the largest of a disk
	// process, each part named on the log.
	granted, limited := budget_decide({pages = max(u64), processes = 63, threads = 255}, least, largest)
	testing.expect_value(t, granted, Budget_Request{pages = 8192, processes = 1, threads = 4})
	testing.expect_value(t, limited, Budget_Parts{.Pages, .Processes, .Threads})

	// A file with no request gets the least budget, which the largest holds.
	granted, limited = budget_decide({}, least, largest)
	testing.expect_value(t, granted, least)
	testing.expect_value(t, limited, Budget_Parts{})

	// One disk process fits in the shared budget, and the largest is not the
	// whole of it: one disk process never takes every page.
	testing.expect(t, largest.pages < shared.pages && largest.processes <= shared.processes && largest.threads <= shared.threads)
	testing.expect_value(t, largest.processes, 1)
	testing.expect(t, largest.threads <= 4)

	// The disk processes that the shared budget pays at one time, each at its
	// largest: as many as its process slots, or fewer, whatever they ask.
	held := shared
	count := 0
	for {
		if _, short := budget_first_short_part(largest, held); short {
			break
		}
		held.pages -= largest.pages
		held.processes -= largest.processes
		held.threads -= largest.threads
		count += 1
	}
	testing.expect(t, count >= 1 && u64(count) <= shared.processes, "a bounded count of disk processes runs at one time")
	// The share of the root service that the disk processes take is a
	// small part of its 255 processes and 1023 threads.
	testing.expect(t, shared.processes <= 4 && shared.threads <= 16)
}

// The first part that a holder cannot pay: the part that a refusal names.
@(test)
budget_first_short_part_names_the_part :: proc(t: ^testing.T) {
	needed := Budget_Request{pages = 4096, processes = 2, threads = 6}
	part, short := budget_first_short_part(needed, {pages = 4096, processes = 2, threads = 6})
	testing.expect(t, !short, "a holder of exactly the amounts can pay")
	part, short = budget_first_short_part(needed, {pages = 9000, processes = 1, threads = 2})
	testing.expect(t, short)
	testing.expect_value(t, part, Budget_Part.Processes)
	part, short = budget_first_short_part(needed, {pages = 100, processes = 0, threads = 0})
	testing.expect_value(t, part, Budget_Part.Pages)
	testing.expect_value(t, budget_part_names[part], "pages")
}
