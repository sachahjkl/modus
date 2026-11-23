#+build !freestanding
package system

import module "modus:contract/module"
import op "modus:contract/operation"
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

// The largest budget of a process of the boot image is one share of the
// pages and the threads of the machine, never below the least largest
// budget, never more threads than a process holds. The edges first: no
// page, one page, the pages where the share reaches the least, one more,
// and the largest count that a machine can name.
@(test)
the_largest_budget_is_a_share_of_the_machine :: proc(t: ^testing.T) {
	least := module.LARGEST_BUDGET_LEAST
	share := u64(module.LARGEST_BUDGET_SHARE_DEFAULT)
	of_pages :: proc(pages: u64, share: u64) -> Budget_Request {
		return module.largest_budget_of_machine({pages = pages}, share)
	}
	testing.expect_value(t, of_pages(0, share), least)
	testing.expect_value(t, of_pages(1, share), least)
	at_least := least.pages * share
	testing.expect_value(t, of_pages(at_least - 1, share).pages, least.pages)
	testing.expect_value(t, of_pages(at_least, share).pages, least.pages)
	testing.expect_value(t, of_pages(at_least + share, share).pages, least.pages + 1)
	most := module.largest_budget_of_machine({pages = max(u64), threads = max(u64)}, share)
	testing.expect_value(t, most.pages, max(u64) / share)
	testing.expect_value(t, most.threads, u64(op.THREAD_CAPACITY))
	testing.expect_value(t, most.processes, least.processes)
	// A machine of 1 GiB less the kernel: the address space test and the
	// Linux guest fit, which needed rows of exceptions under a cap of 64 MiB,
	// and a process starts a thread for each of many processors.
	machine := module.largest_budget_of_machine({pages = 200_000, threads = 1023}, share)
	testing.expect_value(t, machine.pages, 50_000)
	testing.expect_value(t, machine.threads, 255)
	testing.expect(t, machine.pages >= 42338 && machine.pages >= 34932)
	// A request at the share is accepted, one page past it is limited.
	granted, limited := budget_decide({pages = machine.pages}, {pages = 2048, processes = 1, threads = 1}, machine)
	testing.expect_value(t, granted.pages, machine.pages)
	testing.expect_value(t, limited, Budget_Parts{})
	granted, limited = budget_decide({pages = machine.pages + 1}, {pages = 2048, processes = 1, threads = 1}, machine)
	testing.expect_value(t, granted.pages, machine.pages)
	testing.expect_value(t, limited, Budget_Parts{.Pages})
}

// The share of the plan passes one border: a word below the least, 0, past
// the most and the largest word are refused; the least and the most pass,
// and a share of 1 gives one process the whole machine.
@(test)
the_share_of_a_plan_passes_its_border :: proc(t: ^testing.T) {
	for word in ([?]u64{0, module.LARGEST_BUDGET_SHARE_MOST + 1, max(u64)}) {
		_, ok := module.budget_share_of_word(word)
		testing.expectf(t, !ok, "the share %d is taken", word)
	}
	least, least_ok := module.budget_share_of_word(module.LARGEST_BUDGET_SHARE_LEAST)
	most, most_ok := module.budget_share_of_word(module.LARGEST_BUDGET_SHARE_MOST)
	testing.expect(t, least_ok && most_ok && least == 1 && most == 64)
	whole := module.largest_budget_of_machine({pages = 200_000, threads = 1023}, least)
	testing.expect_value(t, whole.pages, 200_000)
	testing.expect_value(t, whole.threads, u64(op.THREAD_CAPACITY))
	small := module.largest_budget_of_machine({pages = 200_000, threads = 1023}, most)
	testing.expect_value(t, small.pages, module.LARGEST_BUDGET_LEAST_PAGES)
	// A share of 0 that skipped the border still divides by one, never by 0.
	testing.expect_value(t, module.largest_budget_of_machine({pages = 8}, 0).pages, module.LARGEST_BUDGET_LEAST_PAGES)
}

// The budget of the disk processes is stated, not a share: it never
// returns to the root service, so it covers their need and no more, and
// one disk process gets half of it.
@(test)
the_disk_budgets_are_stated :: proc(t: ^testing.T) {
	testing.expect_value(t, disk_process.PROCESSES_BUDGET, Budget_Request{pages = 32768, processes = 4, threads = 16})
	testing.expect_value(t, disk_process.LARGEST_BUDGET, Budget_Request{pages = 16384, processes = 1, threads = 4})
	testing.expect(t, disk_process.LARGEST_BUDGET.pages < disk_process.PROCESSES_BUDGET.pages)
}

// A disk process gets at most one process slot and 4 threads, whatever its
// file asks, and the one budget of the disk processes pays a bounded count
// of them: the processes of the boot image keep the rest of the budget of
// the root service.
@(test)
a_disk_process_gets_at_most_its_own_largest_budget :: proc(t: ^testing.T) {
	least := Budget_Request{pages = 2048, processes = 1, threads = 1}
	largest := disk_process.LARGEST_BUDGET
	shared := disk_process.PROCESSES_BUDGET

	// A hostile file asks for everything: it gets the largest of a disk
	// process, each part named on the log.
	granted, limited := budget_decide({pages = max(u64), processes = 63, threads = 255}, least, largest)
	testing.expect_value(t, granted, Budget_Request{pages = 16384, processes = 1, threads = 4})
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
