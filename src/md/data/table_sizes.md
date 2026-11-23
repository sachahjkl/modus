# The sizes of the kernel tables, the thread areas and a wait

The kernel keeps its state in flat tables ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "13. Data-oriented kernel internals"). This file records how large each table is, why, and what a table of that size costs: the process slots, the threads, the memory objects, the threads of one process with their thread areas, the mappings of one process with their order, and the words of one wait.

## The constraints

- A limit that refuses a real use is a fault. A desktop with its services, many windows and a build that starts its workers runs hundreds of processes; a server holds a thousand handles; a compiler starts a thread for each processor.
- The tables are memory of the kernel that no budget pays. The root budget is the free memory less the tables, so a table that is too large takes pages from every process. The test machine has 1 GiB, and must keep most of it for the budgets.
- No table grows while the machine runs: a growth is a heap of the kernel that a process can fill ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller").
- The kernel stack has 64 KiB, and a waiting thread of a process has 64 KiB of stack: no record of a table, and no list of a wait, lives there whole.

## The sizes are chosen once, at the start, from the memory of the machine

The kernel counts the usable pages of the memory map of the firmware, and `modulus:table_sizes` gives the sizes from that count, before the first processor and the first process:

- **Process slots**: one for each 4 MiB of usable memory, rounded up to a multiple of 64, at least `op.PROCESS_SLOTS_LEAST` (64) and at most `op.PROCESS_SLOTS_MOST` (1024). A machine of 1 GiB has 256; a machine of 4 GiB or more has 1024.
- **Threads of the machine**: 4 for each process slot.
- **Memory objects**: 64 for each process slot.

The tables of these three, and the tables that have one entry for each process slot (the origin tree, the state of a recorded process), are taken from the free frames in one contiguous run each, with zeros, before the root budget is made. A machine that has no run for them stops at its start with one line. The small tables keep a fixed size at their most: the budgets (4096), the locks of the processes, the guests and the sets of process slots (`modulus:slot_set`, 1024 bits).

**The cost, measured.** This is the one statement of the cost; the other places link here. The sizes are the `size_of` of the records in the kernel object of this tree (`odin build src/modulus -build-mode:obj`), multiplied by the counts of the rule:

| Table | Bytes for one entry | Entries for one process slot | Bytes for one process slot |
|---|---|---|---|
| Process record, with its handle table, its mappings and their order | 95 104 | 1 | 95 104 |
| Links of the origin tree | 32 768 | 1 | 32 768 |
| State of a recorded process | 24 736 | 1 | 24 736 |
| Thread, with its 256 waited words (3 072 bytes) | 8 448 | 4 | 33 792 |
| Memory object, with its lock | 152 | 64 | 9 728 |
| Sum | | | 196 128 (191.5 KiB) |

So the tables take 191.5 KiB for each 4 MiB of usable memory: 4.7 % of the memory of the machine, whatever its size, between the floor and the ceiling. A machine of 1 GiB has 256 slots and 47.9 MiB of tables; the floor of 64 slots is 12 MiB; the ceiling of 1024 slots is 191.5 MiB. The fixed tables add 0.7 MiB: the budgets (384 KiB) and the guests (312 KiB).

**Why a ratio and not a constant.** A constant large enough for a server took a fixed share of a small machine (the browser machine runs in 256 MiB), and a constant small enough for it refused the processes of a large machine. A ratio is one rule for both.

**Why a ceiling.** The sets of process slots, the log record and the tables of the services that have one entry for each process (the root service, the disk process page, the bind places of the devices service) have the size of `op.PROCESS_SLOTS_MOST`. A machine with more slots needs these tables sized at run time too; until then, 1024 slots hold a real desktop and a build.

**Refused: a table that grows in a reserve of addresses.** It pays the kernel only for the entries that run, but it needs a page fault or a commit of the kernel on a path that creates an object, and a frame that is missing there is a failure that no budget names. The one sizing at the start has no such path.

**Refused: a table in the budget of the root service.** The root service would then pay for the kernel objects of every process, and a process slot of the kernel would be a page of a process: the kernel would read its own state through memory that a process maps.

## The log record names a process slot in two bytes

`op.Log_Record` names the process slot in a `u16`, so the slot is not bound to 256 by the record. Its head stays 32 bytes: the count of the bytes of the text is one byte, since a record holds at most 168 bytes of text, and the thread is its number in its process, one byte for at most 256 threads.

## A process holds 256 threads

A thread has a thread area of 4 pages: its thread record, its kernel ring and a guard page. The 256 areas of a process are 4 MiB, from `op.THREAD_AREA_BASE` up to the time page. The context and the stack of the first thread are below the areas, in the same 2 MiB as the first 8 areas: a process with at most 8 threads pays the page tables that it paid before. The kernel keeps the areas in use as a set of 256 bits, and `Inspect` gives up to 256 threads in a thread report.

## The mappings of a process in the order of their addresses

The kernel keeps, beside the 1024 mappings of a process, the places of the mappings in the order of their addresses. A map at an address that the kernel chooses walks that order once, from `op.CHOSEN_BASE`, and moves past a module record of the starter when it meets one: one pass over the mappings, where a search with no order passed over each mapping once for each mapping that it moved past (a million reads under the lock of the process with 1024 mappings). A map and an unmap move the places after them by one: 1024 moves of two bytes at most. The report of the mappings reads the same order, and sorts nothing.

## A wait holds 64 words on the stack, and more in a wait set of its caller

The kernel takes up to `op.WORD_WAIT_CAPACITY` (256) words in one wait. A `system.Wait` holds `system.WAIT_INLINE_WORDS` (64) of them in itself, about 3.5 KiB of the stack: a stream end, a call and a window wait on fewer. A thread that waits on more (the loop of the root service, `wiring`, the follow of `log`, `collector`) gives a `system.Wait_Set` of its own memory to `wait_begin`: the list then has 256 places, in that set. One set serves one thread: a set that two threads fill at once mixes their lists.

**Refused: the whole list on the stack.** 256 words took 12 KiB of each waiting thread, which most threads never use.

**Refused: one list for each thread, kept by the library.** A wait inside a wait (a send that waits for room while the loop builds its list) would write over the list of the outer one.

## The subtle points

- The sizes of the tables are in `System_Report.process_slots`: a process that reads each slot reads that count, never `op.PROCESS_SLOTS_MOST`, so a small machine costs it no call for a slot that does not exist.
- The root budget holds `process_slots - 1` processes, `4 × process_slots - 1` threads and 1000 log records of each second for each process slot.
- The largest budget of a process is a share of the machine: a quarter by default (`module.LARGEST_BUDGET_SHARE_DEFAULT`). It is a value of the plan of principal 0, because it spends a resource of the machine; the root service takes it through one border (`module.budget_share_of_word`) when the plan gives it ([../features/module_budget_request.md](../features/module_budget_request.md)).

## State

Built: the sizes at the start, the log record with two bytes of process slot, 256 threads in a process, the order of the mappings, the wait set, and the border of the share of a plan. The readers of every slot (`inspect`, `scheduler`, `frames`, `address_space`, the own tables and the fresh bytes of the root service) read `System_Report.process_slots`. Left: the services whose tables have one entry for each process slot keep the size of `op.PROCESS_SLOTS_MOST` in their memory; the plan of principal 0 gives no share yet, so the share is the default.
