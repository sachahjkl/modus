package disk_process

import module "modus:contract/module"

// The budget that pays every disk process together: the root service makes
// it from its own budget at the first disk process, and keeps it. A disk
// process runs a file that its principal chose, not a module of the
// system, so the sum of all of them has one bound, and the processes of the
// boot image keep the rest of the budget of the root service
// (docs/MODULE_CONTRACT.md, "The budget that a module asks for").
//
// The pages follow the memory of the machine: the budget of the disk
// processes holds the largest budget of one process of the boot image
// (module.largest_budget_of_machine), and one disk process gets at most
// half of it, so one disk process never takes all of it.
//
// - 4 processes and 16 threads: 4 disk processes at one time, each with at
//   most 4 threads. The processes of the boot image keep the other slots
//   and threads of the root service.
// - On the smallest machine: 16384 pages, 64 MiB: two disk processes of the
//   largest budget, or four of half that, each with the two pictures of a
//   window of about 1000 x 704 (1400 pages) and its working memory.
PROCESSES_BUDGET_LEAST :: module.Budget_Request{pages = module.LARGEST_BUDGET_LEAST_PAGES, processes = 4, threads = 16}

// The processor time of all disk processes together, in microseconds in
// each second: two processors. A disk process that computes with no end
// then leaves the other processors to the processes of the system.
SHARED_PROCESSOR_TIME :: 2_000_000

// The most that one disk process gets on the smallest machine. A disk
// process holds no grant that starts a process, so it needs its own
// process slot only, and with one slot it creates no child; 4 threads; and
// half of the pages of the budget of the disk processes.
LARGEST_BUDGET_LEAST :: module.Budget_Request{pages = PROCESSES_BUDGET_LEAST.pages / 2, processes = 1, threads = 4}

// processes_budget_of gives the budget of the disk processes on a machine
// whose largest budget of a process of the boot image is largest: its
// pages, and the processes and the threads of PROCESSES_BUDGET_LEAST.
processes_budget_of :: proc "contextless" (largest: module.Budget_Request) -> module.Budget_Request {
	budget := PROCESSES_BUDGET_LEAST
	budget.pages = max(largest.pages, PROCESSES_BUDGET_LEAST.pages)
	return budget
}

// largest_budget_of gives the most that one disk process gets from the
// budget of the disk processes shared: half of its pages, one process
// and 4 threads.
largest_budget_of :: proc "contextless" (shared: module.Budget_Request) -> module.Budget_Request {
	largest := LARGEST_BUDGET_LEAST
	largest.pages = shared.pages / 2
	return largest
}
