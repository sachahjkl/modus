package disk_process

import module "modus:contract/module"
import op "modus:contract/operation"

// The budget that pays every disk process together: the root service makes
// it from its own budget at the first disk process, and keeps it. A disk
// process runs a file that its principal chose, not a module of the
// system, so the sum of all of them has one bound, and the processes of the
// boot image keep the rest of the budget of the root service
// (docs/MODULE_CONTRACT.md, "The floor of a module").
//
// Its amounts are stated, not a share of the machine: the budget never
// returns to the root service, so a share would keep a quarter of a large
// machine for files that may never run. The need that they cover:
//
// - 8 processes and 16 threads: 4 disk processes at one time, each with at
//   most 1 isolated child process and 4 threads. The processes of the boot
//   image keep the other slots and threads of the root service.
// - 32768 pages, 128 MiB: two disk processes of the largest budget, or
//   four of half that, each with the two pictures of a window of the
//   reference screen (4050 pages) and its working memory.
PROCESSES_BUDGET :: op.Budget_Amounts{pages = 32768, processes = 8, threads = 16}

// The processor time of all disk processes together, in microseconds in
// each second: two processors. A disk process that computes with no end
// then leaves the other processors to the processes of the system.
SHARED_PROCESSOR_TIME :: 2_000_000

// The most that one disk process gets: 2 process slots (its own slot plus at
// most 1 zero-grant isolated child call host, paid from the same memory and
// thread budget; a disk process that omits `processes` gets 1 slot and creates
// no child); 4 threads; and half of the pages of the budget of the disk
// processes, the least largest budget of a process of the boot image, so one
// disk process never takes all of it. A floor above one of these parts does
// not start: no row of a disk process raises them.
LARGEST_BUDGET :: op.Budget_Amounts{pages = PROCESSES_BUDGET.pages / 2, processes = 2, threads = 4}
#assert(LARGEST_BUDGET.pages == module.LARGEST_BUDGET_LEAST_PAGES)

// Plan value: the block limit of the private store of a disk process (16 MiB,
// 4096 blocks of 4 KiB). Holds helper modules (such as sqlite.module and
// host.module) and application databases with copy-on-write version history,
// while bounding one disk process to a small share of the disk.
PRIVATE_STORE_BLOCKS_LIMIT :: u64(4096)
