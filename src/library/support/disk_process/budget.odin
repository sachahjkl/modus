package disk_process

import module "modus:contract/module"

// The budget that pays every disk process together: the root service makes
// it from its own budget at the first disk process, and keeps it. A disk
// process is a file that its principal chose, not a process of the
// system, so the sum of all of them has one bound, and the processes of the
// boot image keep the rest of the budget of the root service
// (docs/MODULE_CONTRACT.md, "The budget that a module asks for").
//
// - 4 processes and 16 threads: 4 disk processes at one time, each with at
//   most 4 threads. The root service has 63 processes and 255 threads, and
//   the processes of the boot image keep 59 and 239 of them.
// - 16384 pages, 64 MiB: two disk processes of the largest budget, or four
//   of half that, each with the two pictures of a window of about 1000 x
//   704 (1400 pages) and its working memory.
PROCESSES_BUDGET :: module.Budget_Request{pages = 16384, processes = 4, threads = 16}

// The processor time of all disk processes together, in microseconds in
// each second: two processors. A disk process that computes with no end
// then leaves the other processors to the processes of the system.
PROCESSES_PROCESSOR :: 2_000_000

// The most that one disk process gets. A disk process holds no grant that
// starts a process, so it needs its own process slot only, and with one
// slot it creates no child; 4 threads; and 8192 pages, half of the budget
// of the disk processes, so one disk process never takes all of it.
LARGEST_BUDGET :: module.Budget_Request{pages = 8192, processes = 1, threads = 4}
