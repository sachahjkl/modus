# The sizes of the kernel tables, the thread areas and a wait

The kernel keeps its state in flat tables ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "13. Data-oriented kernel internals"). This file records how large each table is, why, and what a table of that size costs: the process slots, the threads, the memory objects, the threads of one process with their thread areas, the mappings of one process with their order, and the words of one wait.

## The constraints

- A limit that refuses a real use is a fault. A desktop with its services, many windows and a build that starts its workers runs hundreds of processes; a server holds a thousand handles; a compiler starts a thread for each processor.
- The tables are memory of the kernel that no budget pays. The root budget is the free memory less the tables, so a table that is too large takes pages from every process. The test machine has 1 GiB, and must keep most of it for the budgets.
- No table grows while the machine runs: a growth is a heap of the kernel that a process can fill ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller").
- The kernel stack has 64 KiB, and a waiting thread of a process has 64 KiB of stack: no record of a table, and no list of a wait, lives there whole.

## The sizes are chosen once, at the start, from the memory of the machine

The kernel counts the usable pages of the memory map of the firmware (the pages of its free ranges, `usable_pages`, before the kernel takes any), and `modulus:table_sizes` gives the sizes from that count, before the first processor and the first process:

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
| Thread, with the entries of its first 64 waited words (4 096 bytes) | 7 424 | 4 | 29 696 |
| Memory object, with its lock | 152 | 64 | 9 728 |
| Sum | | | 192 032 (187.5 KiB) |

The buckets of the word wait add 8 bytes for each page frame of the machine: 2 MiB on a machine of 1 GiB, 0.2 % of the memory.

So the tables take 187.5 KiB for each 4 MiB of usable memory and 8 bytes for each frame: 4.8 % of the memory of the machine, whatever its size, between the floor and the ceiling. A machine of 1 GiB has 256 slots and 48.9 MiB of tables; the floor of 64 slots is 11.7 MiB and the buckets of its frames; the ceiling of 1024 slots is 187.5 MiB and the buckets of its frames. The fixed tables add 0.7 MiB: the budgets (384 KiB) and the guests (312 KiB). The words of a wait past 64 are in the wait room of their thread, which its budget pays (below).

**Why a ratio and not a constant.** A constant large enough for a server took a fixed share of a small machine (the browser machine runs in 256 MiB), and a constant small enough for it refused the processes of a large machine. A ratio is one rule for both.

**Why a ceiling.** The sets of process slots and the log record have the size of `op.PROCESS_SLOTS_MOST`. A machine with more slots needs them sized at run time too; until then, 1024 slots hold a real desktop and a build.

**The tables of the services follow the slots of the machine.** A service with one entry for each process slot reads `System_Report.process_slots` at its start (`system.process_slots_of`) and takes its tables from an arena that its budget pays (`system.arena_take`): the places of the root service, its fresh bytes, its devices bound to a place and the wait set of its loop (`root/root_tables.odin`); the disk process page, whose rows follow the places (`disk_process_page.page_pages`, `Page.row_count`); the bind places of the region of the devices service (`root_delegation.devices_region_pages`); the tables of `inspect` and `monitor`. On a machine of 1 GiB the root service pays 255 places, not 1023. The constants of the most (`STARTED_CAPACITY`, `ROW_CAPACITY`, `DEVICES_BIND_PLACE_COUNT`) stay as bounds that a reader checks, not as sizes.

Two tables keep their most, and say why: the count of the log by process in `log` (it holds no handle that reads the report of the machine, and it counts the processes that it saw in the log, with a count of the others past its table), and the rows of a round of the share policy in the demonstration `scheduler` (a round is a value that the window copies whole).

**Refused: a table that grows in a reserve of addresses.** It pays the kernel only for the entries that run, but it needs a page fault or a commit of the kernel on a path that creates an object, and a frame that is missing there is a failure that no budget names. The one sizing at the start has no such path.

**Refused: a table in the budget of the root service.** The root service would then pay for the kernel objects of every process, and a process slot of the kernel would be a page of a process: the kernel would read its own state through memory that a process maps.

## The log record names a process slot in two bytes

`op.Log_Record` names the process slot in a `u16`, so the slot is not bound to 256 by the record. Its head stays 32 bytes: the count of the bytes of the text is one byte, since a record holds at most 168 bytes of text, and the thread is its number in its process, one byte for at most 256 threads.

## A process holds 256 threads

A process weight of the share policy gives each of its threads a part of 1 or more, so the unit of a weight is finer than the count of threads: the full weight is 8192, 32 times the 256 threads, and the narrowest share stays 1/32 ([../features/scheduling_policy.md](../features/scheduling_policy.md), "The unit of a weight is finer than the count of threads").

A thread has a thread area of 4 pages: its thread record, its kernel ring and a guard page. The 256 areas of a process are 4 MiB, from `op.THREAD_AREA_BASE` up to the time page. The context and the stack of the first thread are below the areas, in the same 2 MiB as the first 8 areas: a process with at most 8 threads pays the page tables that it paid before. The kernel keeps the areas in use as a set of 256 bits, and `Inspect` gives up to 256 threads in a thread report.

## The mappings of a process in the order of their addresses

The kernel keeps, beside the 1024 mappings of a process, the places of the mappings in the order of their addresses. A map at an address that the kernel chooses walks that order once, from `op.CHOSEN_BASE`, and moves past a module record of the starter when it meets one: one pass over the mappings, where a search with no order passed over each mapping once for each mapping that it moved past (a million reads under the lock of the process with 1024 mappings). A map and an unmap move the places after them by one: 1024 moves of two bytes at most. The report of the mappings reads the same order, and sorts nothing.

## A wait holds 64 words on the stack, and more in a wait set of its caller

The kernel holds 64 words of a wait for each thread (`op.WORD_WAIT_INLINE`), in its thread table. A `system.Wait` holds as many in itself, about 3.5 KiB of the stack: a stream end, a call and a window wait on fewer. A thread that waits on more (the loop of the root service, the compositor, `wiring`, the follow of `log`, `collector`) sizes a `system.Wait_Set` to its own tables, in its memory, and gives it to `wait_begin`. The first wait with the set asks the kernel for a wait room of its words (`op.Thread_Control_Command.Wait_Room`): pages that the budget of the process pays, an entry of 64 bytes for each word past the 64 and one page that names the others, up to `op.WORD_WAIT_MOST` (32768) words. One set serves one thread at a time: a set that two threads fill at once mixes their lists.

**The room is of the thread.** The kernel writes the words of the room in the thread record (`Thread_Record.wait_room_words`), and the library reads them there: a set grows the room of the thread to its words when the room is smaller, and never makes it smaller, so a thread that uses two sets has the room of the larger, and no set shrinks the room under another. A set whose room the kernel refused for the budget asks no more.

**The room returns to the budget of its process.** The end of a thread gives the pages of its room to the budget that the field of its process names under the frame lock, as a page table does: the end of a budget moves that field to the parent (`budget_release`), so the pages never return to a budget that ended. A room keeps no budget of its own.

Each service sizes its set so that each of its rings fits: the root service 12 + 2 × (2 × places + 2) words (1036 on a machine of 1 GiB, 17 pages), the compositor 27 fixed words and 4 for each of its 128 clients (539, 9 pages).

## The lists of the word wait are keyed by the word

A room of 32768 words for each thread would make a few buckets hold a million entries: one process would make each wake of the machine walk them. The table of the word wait (`modulus:word_table`) has one bucket for each page frame of the machine, sized at the start from the frames, and a few more for the frames of devices. In a bucket each distinct word has one first entry; the other entries of the same word hang from it. A wake reads the distinct words of its frame, at most 1024, then the entries of its own word. A thread holds a word once in a wait: the kernel refuses a second entry of the same word (`Bad_Operation`, with the place of the word in its record), so the entries of a word are at most the threads of the machine. The host tests count the steps of a wake against that bound.

The library keeps a list that names a word twice from a fault of its caller: on that refusal it keeps the first place of each word, waits again, and writes one line. The search costs the square of the words, on that refusal only.

A `Word_Wait` of more than 1024 words registers its words in chunks of 1024, each one a section of the process lock: a wait of 32768 words releases the lock 32 times. By estimate a word costs under a microsecond; the case `locks` prints the time of one wait of 32768 words, which is not measured yet.

## The word of a wait is a frame of its process

The kernel names a waited word by its physical address. A page that the process never touched has no frame and no entry in its page table, and its entry would give the offset of the word alone: a low physical address that the same offset in an untouched page of another process gives too, so the two waits would share a word, and a wake of one process would end the wait of the other.

**The choice: the page is made present, as the access would.** Before the kernel registers a word, `user_range` makes its page present for a read, as a read of the word by the process does: a page on first use gets its frame of the object now, paid as that read pays it, and a page that the process cannot read is refused (`Bad_Address`, and the entry does not wait). Then only an entry that names a present page of the process gives an address (`word_table.word_physical`, with host tests: no entry, an entry with no Present bit or no User bit, a page of 4 KiB and a large page). The same holds for `Word_Wake` and for the diagnosis of a refused wait, which take the same path (`word_address`).

**Refused: a refusal of a word on a page with no frame.** A correct caller reads the word before it waits, which makes the page present, but a thread can wait on a word that a peer will write first, as a counter of a ring that is new: it would get `Bad_Address` for a page that it can read, and loop. The access that the wait implies is a read, and the kernel already gives that read its frame.

The case `locks` starts two processes that each wait on the word at one offset of a page that they never touched: the wake of the first counts one thread, and the waiter of the second still waits.

**Refused: 64 buckets for the machine.** A bucket held the words of every thread whose words had its hash, so one process with a large room made each wake of the machine walk its entries.

**Refused: a hash table with a key.** The kernel has no secret to key it with at its start, and a process that knows the hash puts its words in the bucket of another word. A bucket for each frame needs no key: a process can put only the 1024 words of one frame in one bucket. So no service refuses a client, a start or a ring for its wait. A list that does not fit anyway (the kernel refused the room for the budget) is refused past the 64 words, ends only at its deadline, and writes one line: no loop turns with no wait.

**Refused: a cap of the kernel for every thread.** 256 words for each thread took 5 KiB of each entry of the thread table, the root service then held 122 queues for its 1023 places, and the compositor 96 windows. A room that the caller sizes and its budget pays has no cap but the budget.

**Refused: the room in the memory of the process.** The kernel links each entry into the list of its word, and follows the links under the wait lock: a link that a process writes would make the kernel follow an address that the process chose.

**Refused: the whole list on the stack.** 256 words took 12 KiB of each waiting thread, which most threads never use.

**Refused: one list for each thread, kept by the library.** A wait inside a wait (a send that waits for room while the loop builds its list) would write over the list of the outer one.

## The subtle points

- The sizes of the tables are in `System_Report.process_slots`: a process that reads each slot reads that count, never `op.PROCESS_SLOTS_MOST`, so a small machine costs it no call for a slot that does not exist.
- The root budget holds `process_slots - 1` processes, `4 × process_slots - 1` threads and 1000 log records of each second for each process slot.
- A wait room is taken before the room that it replaces is given back, so a refusal for the budget changes nothing; the thread asks it in its own entry with no word registered, so no entry of the old room is in a list of the kernel when its pages leave.
- The counts of the mappings of a memory object (`mapping_count`, `writable_mapping_count`) are taken before the check of the record, and each refusal gives them back: a writer that holds only its own process lock is then seen by the scan of a recorded process that maps the object at the same time (`record_replay.odin`, `region_others_none`), or it sees that process. A protect that gives Write counts it the same way before its check.
- The largest budget of a process is a share of the machine: a quarter by default (`module.LARGEST_BUDGET_SHARE_DEFAULT`). It is a value of the plan of principal 0, because it spends a resource of the machine; the root service takes it through one border (`module.budget_share_of_word`) when the plan gives it ([../features/module_budget_request.md](../features/module_budget_request.md)).

## State

Built: the sizes at the start from the usable pages of the memory map, the log record with two bytes of process slot, 256 threads in a process with the finer unit of a weight, the order of the mappings, the wait set with the wait room of the thread, the lists of the word wait keyed by the word, the chunks of a long wait, the tables of the services from the slots of the machine, and the border of the share of a plan. Left: the plan of principal 0 gives no share yet, so the share is the default. The machine cases of the wait room (`locks`: its edges, its pages at each end, the time of a wait of 32768 words) have not run on a machine yet.
