# The frames of a process: prefault and page sizes

Status: Accepted and built for 2 MiB and 1 GiB runs, including thread-level resumable 1 GiB zeroing continuations across `schedule()`. Built: `Commit_Flag.Frames_Now`, `map_region` prefaulted entries, 2 MiB and 1 GiB aligned frame runs (`modulus:frame_runs`), bounded resumable zeroing (`frame_runs.Zero_Run_Progress`) driven by thread-level continuations across `schedule()`, per-budget run quota, zero-allocation demotion through parked page tables (`Process.demotion_tables`), counted fallback in `System_Report`, per-size entry counts in `Process_Mapping`, and 1 GiB lookup in `modulus:word_table`. `Large_Pages` stays until its callers move to runs and the Odin fork updates. The study is [`docs/research/budgets_as_policy_study.md`](../../../docs/research/budgets_as_policy_study.md) (sections 4.5 to 4.13 and 10); the critique is [`docs/research/budgets_as_policy_critique.md`](../../../docs/research/budgets_as_policy_critique.md) (sections 7 to 9). The budgets that pay these frames are [module_budget_request.md](module_budget_request.md).

## Purpose

A budget reserves pages; a frame is the physical memory of one page. Today a page gets its frame, zeroed, at its first use, and the kernel maps 2 MiB only for an object made with `Large_Pages`. This file records how a process gets its frames before its first frame, and how it gets pages of 2 MiB and 1 GiB with no flag of a page size and no privilege.

The guide is [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "The virtual memory of a process".

## Constraints

- **No overcommit.** A frame taken early costs no memory: the budget reserved it. It costs the work of its zeroing.
- **No privilege.** A large page holds no frame that its budget did not pay. Windows asks for `SeLockMemoryPrivilege` because its large pages cannot go to its page file; this system has no page file.
- **Each feature works per 4 KiB.** Marks, protection of a part, decommit, `Memory_Read`, the word of a wait, the IOMMU, the stand-ins of a recording.
- **No kernel section is long.** Each walk and each zeroing with interrupts off has a bound, and the time of a zeroing is charged to the caller that asked for it.
- **A page size changes the speed, never the result.**

## The chosen form

**The map writes the entries of the pages that have frames**, with the rule of `page_give` for each entry: the bits of the slot, `No_Access`, no entry for a switching mapping of a guest, never the shared frame of a stand-in. A map of an object with no present page reads `region.present == 0` and walks nothing. The walk has the bound of `RANGE_TABLE_PAGE_LIMIT`, and `present_page_count` of the mapping follows. It also removes the faults of a second process that maps the object, as the compositor on the pictures of a client.

**The prefault is a flag of `Memory_Commit`**, `Frames_Now`, for a table of ranges; `Memory_Create` with `Frames_Now` stays its short form for a whole object. The frames are taken one run at most in each section of the frame lock, and zeroed outside the lock. The library that makes an object written whole at the start (the pictures of a window, a ring) sets the flag. An object that the process touches in parts stays on first use. A stack stays on first use until the measure of the first layer gives the pages of a stack that a start touches.

**A run is decided at a commit with frames now.** A run is an aligned block of free frames of one page size: 2 MiB, or 1 GiB on a processor with `pdpe1gb`. A commit with `Frames_Now` of an aligned whole range of an object takes the largest free run that fits: a 1 GiB run when a free aligned 1 GiB exists, else 2 MiB runs, else single frames. It writes the slots, and sets one state bit, `SLOT_RUN`, in the first slot of each range of a run. A map writes one entry of the size of the run for each range whose first slot has `SLOT_RUN` and whose address is aligned with its offset in the object. A page on first use never takes a run, and no range promotes later.

**A 1 GiB run is zeroed in bounded sections of the caller's time.** The commit takes the run and pays its pages at once, all or nothing. It then zeroes the run in steps of at most 2 MiB; between two steps the processor takes its interrupts, and when the slice of the thread is over, the thread yields with the step of its command kept in its thread record and continues at its next run. The slots of a 2 MiB step are written after its zeroing: a page that is not written yet is not committed, and a touch there is the fault of a page that is not committed. A process that stops during the command returns the frames of the steps that remain. The size of a step is a measured fact: the largest power of two of bytes, at most 2 MiB, whose zeroing fits in the longest kernel section that the measure of the first layer gives. The same steps zero a 2 MiB run when one step is smaller than 2 MiB.

**A change of a part demotes.** A mark, a protection of a part or a decommit of a part clears `SLOT_RUN_2M` or `SLOT_RUN_1G` of its range: a 1 GiB entry becomes 512 entries of 2 MiB, and the range of 2 MiB that holds the change becomes 512 entries of 4 KiB. The tables are paid at the map: one page for each 2 MiB, and a directory plus 512 level-1 tables for each 1 GiB, as a mapping of 4 KiB pages pays them today. When a map installs a large entry, it parks the replaced empty table pages on a per-process linked list (`Process.demotion_tables`, linked through word 0 of each parked page). Demotion pops from that list, so no demotion takes a frame; unmap pops and frees the parked pages of each large entry that it clears. A demotion needs an object that only this process names, with one mapping, as a protection of a part does today: it touches one page table. It ends with the shoot-down of a protection change. A range that lost its run stays small until its whole decommit.

**A run quota for each budget.** A budget counts the runs that it took and that are not whole and free again; each 2 MiB block and each 1 GiB block records the budget that took it. A budget takes a run only while its count of runs of that size is below its pages divided by the pages of a run. A decommit of a part returns its frames to the frame table at their place, so a block heals when its last page leaves. So a budget breaks at most the contiguity that its own pages are worth.

**No free run gives a smaller size, counted.** The commit never fails for a run. `Process_Mapping` gives, for each mapping, its entries of 4 KiB, 2 MiB and 1 GiB. `System_Report` gives the commits that got a smaller size than their range allowed, by size, and the free runs of each size. No compaction: a frame of a process never moves.

**`Contiguous` stays** for each object that the kernel or a device reads by its physical address: the memory of a device, the rings of the kernel events, the input history of a recording, a mailbox, a picture of the compositor. **`Large_Pages` stays** until the runs are built; its removal is the last step of their layer.

**The other machines.** The runs, the large entries and the counts are behind files with the suffix of their system. On the software processor (`wasm64p32`) the counts read 0. The sizes of ARM64 (the blocks of 2 MiB and 1 GiB, the contiguous hint of 16 entries) fit the same rule of a run decided at a commit; the port is not started.

## The refused forms

- **The promotion of FreeBSD**: a run reserved at the first fault and promoted when its pages are present. It answers a question of a system with overcommit, and brings a reserved state of a frame, a count of frames neither free nor present, and a late promotion with its shoot-down.
- **A flag of a page size, or a contiguous object for large pages.** A second memory model in which each feature per 4 KiB is refused.
- **A privilege for large or prefaulted pages.**
- **A refusal of a commit when no run is free.** A second path in each caller, and a status that tells what other processes did.
- **A fallback that no count shows.**
- **A demotion that takes a frame.**
- **A zeroing of a run in one kernel section.** 100 µs to 100 ms with interrupts off.
- **A 1 GiB page that waits for a later layer.** One more level of the same run, with the same rules, costs less than a second design later.
- **Compaction.** It moves frames of processes, and a frame that a device holds, or that a word of a wait names, cannot move in silence.
- **A pool of zero runs in the first layers.** Work that no budget pays, for a gain that no measure shows yet.

## Subtle points

- **The contiguity is a shared fact of the machine.** A process that reads its counts learns a little of what other processes did. The quota bounds the size of this channel, not its rate: reduced, not slow (line 17 of property 20).
- **A recorded process has no large entry.** A stand-in replaces one 4 KiB page of a mapping, so the entries of that mapping are not the frames of the object. The start of a recording demotes its mappings in bounded steps, while its threads are at input points.
- **The memory of a guest never has a large entry.** It is a switching mapping: each 4 KiB page changes between Write and Execute at a nested fault.
- **`mapping.large` becomes a fact of a range.** Each reader gets the rule of `SLOT_RUN`: `page_give`, `guest_page_answer`, the places of `record_replay.odin`, `diagnose.odin`, the reports, the unmap.
- **The word of a wait** keeps the physical address of its 4 KiB frame; `word_physical` gets the case of a 1 GiB entry, with its host test.
- **A commit takes frames now.** The interleaving "a commit never takes a frame" of `docs/ARCHITECTURE.md` changes: a commit with frames and a first use on another processor, and a demotion and a fault on another processor, get their written interleavings.
- **The frame list of an object of 1 GiB costs 2 MiB**, also when one entry maps it: the price of one model of features for each page size.

## State

Built: `Commit_Flag.Frames_Now` on `Memory_Commit` (refused with `Decommit`), `map_region` writing present 4 KiB, 2 MiB, and 1 GiB entries with early-skip when `region.present == 0` and shootdown before parking replaced tables, pure host-tested 2 MiB and 1 GiB run allocator and quota tracker `modulus:frame_runs` (with 4 GiB host tests), pure host-tested bounded resumable 1 GiB zeroing state machine (`frame_runs.Zero_Run_Progress`, 2 MiB slices with abort tail reclamation), thread-level continuation yields across `schedule()` in `src/modulus/` driving `Zero_Run_Progress` (and 512 x 2 MiB fallback slices) with locks released and `interrupt_window()` opened between slices plus abort reclamation in `thread_finish`, `pdpe1gb` feature detection in `frame_runs_amd64.odin` with zero counts on `wasm64p32`, 2 MiB prefaulting zeroed outside `frame_lock`, zero-allocation demotion via `Process.demotion_tables` (including all mappings at recording/replay start), 1 GiB entries in `modulus:word_table`, entry-size counts in `Process_Mapping`, free runs and fallback counts in `System_Report`, and the 4 GiB `+pdpe1gb` test module `pdpe1gb_probe` and test part `gigabyte_pages`. Left: removing `Memory_Flag.Large_Pages` alongside the pinned Odin fork sync after migrating remaining `Large_Pages` references.
