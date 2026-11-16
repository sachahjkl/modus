package disk_program

import module "modus:contract/module"

// The budget that pays every disk program together: the root service makes
// it from its own budget at the first disk program, and keeps it. A disk
// program is a file that its principal chose, not a program of the
// system, so the sum of all of them has one bound, and the programs of the
// boot image keep the rest of the budget of the root service
// (docs/MODULE_CONTRACT.md, "The budget that a module asks for").
//
// - 4 programs and 16 threads: 4 disk programs at one time, each with at
//   most 4 threads. The root service has 63 programs and 255 threads, and
//   the programs of the boot image keep 59 and 239 of them.
// - 16384 pages, 64 MiB: two disk programs of the largest budget, or four
//   of half that, each with the two pictures of a window of about 1000 x
//   704 (1400 pages) and its working memory.
PROGRAMS_BUDGET :: module.Budget_Request{pages = 16384, programs = 4, threads = 16}

// The processor time of all disk programs together, in microseconds in
// each second: two processors. A disk program that computes with no end
// then leaves the other processors to the programs of the system.
PROGRAMS_PROCESSOR :: 2_000_000

// The most that one disk program gets. A disk program holds no grant that
// starts a program, so it needs its own program slot only, and with one
// slot it creates no child; 4 threads; and 8192 pages, half of the budget
// of the disk programs, so one disk program never takes all of it.
LARGEST_BUDGET :: module.Budget_Request{pages = 8192, programs = 1, threads = 4}
