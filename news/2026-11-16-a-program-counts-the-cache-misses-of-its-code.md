title: A program counts the cache misses of its own code
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/ARCHITECTURE.md

A thread can now count four events of the processor for its own code: the instructions retired, the cycles, the cache misses and the branch misses. It counts in user mode only, so no work of the kernel and no other thread is in its counts. The kernel keeps the counts of a thread when it leaves a processor. A developer measures with them what a data layout costs in cache misses, and not only in time. The program `counters` reads the same 2 MiB of memory in order and one page apart, and writes the counts of each order on the log. A count of the misses of a shared cache also shows what other programs do, so the counters are a grant: the right `Counters` of the machine handle. The kernel programs the counters of Intel and of AMD Zen; on a machine with neither, the commands say `Unsupported`.
