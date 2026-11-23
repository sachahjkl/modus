package disk_process

import module "modus:contract/module"

// The budget that pays every disk process together: the root service makes
// it from its own budget at the first disk process, and keeps it. A disk
// process runs a file that its principal chose, not a module of the
// system, so the sum of all of them has one bound, and the processes of the
// boot image keep the rest of the budget of the root service
// (docs/MODULE_CONTRACT.md, "The budget that a module asks for").
//
// Its amounts are stated, not a share of the machine: the budget never
// returns to the root service, so a share would keep a quarter of a large
// machine for files that may never run. The need that they cover:
//
// - 4 processes and 16 threads: 4 disk processes at one time, each with at
//   most 4 threads. The processes of the boot image keep the other slots
//   and threads of the root service.
// - 32768 pages, 128 MiB: two disk processes of the largest budget, or
//   four of half that, each with the two pictures of a window of the
//   reference screen (4050 pages) and its working memory.
PROCESSES_BUDGET :: module.Budget_Request{pages = 32768, processes = 4, threads = 16}

// The processor time of all disk processes together, in microseconds in
// each second: two processors. A disk process that computes with no end
// then leaves the other processors to the processes of the system.
SHARED_PROCESSOR_TIME :: 2_000_000

// The most that one disk process gets. A disk process holds no grant that
// starts a process, so it needs its own process slot only, and with one
// slot it creates no child; 4 threads; and half of the pages of the budget
// of the disk processes, the least largest budget of a process of the boot
// image, so one disk process never takes all of it.
LARGEST_BUDGET :: module.Budget_Request{pages = PROCESSES_BUDGET.pages / 2, processes = 1, threads = 4}
#assert(LARGEST_BUDGET.pages == module.LARGEST_BUDGET_LEAST_PAGES)
