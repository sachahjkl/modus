# Budgets as policy: a critique of the study

This file reads [`budgets_as_policy_study.md`](budgets_as_policy_study.md) and the proposed intent [`src/md/features/module_budget_request.md`](../../src/md/features/module_budget_request.md) against the code of `master` and of the branch of integration. It changes no code. It names the faults that it finds, then the form that it recommends, the order of the work, and the questions for the owner.

The direction is kept: the module declares its floor, the size is plan policy, the budget is a reservation, large and prefaulted pages need no privilege. The faults are in the mechanisms, not in the direction.

## 1. The verdict in short

| Part of the study | Verdict |
|---|---|
| Two records, the floor and the policy row | Keep |
| `clamp(policy size, floor, ceiling)` | Not enough: it is a rule for one process, and the reservation is a sum (section 2) |
| A floor that the tool counts | A lower bound, not the need of the start: four parts are not counted (section 3) |
| Fixed tables as variables of the package | Keep for a table that every start uses. Refuse for a table of a library that only some importers use (section 4) |
| `start_objects_pages` | The working memory again, smaller. Replace it with a list of named objects that the tool prices (section 5) |
| `Budget_Grow` | The kernel cannot do what the study says. It is also the pressure channel that the reservation removed (section 6) |
| `Frames_Now` and the two kernel changes | Keep the map that writes present entries. Move the prefault from a flag of the creation to a flag of a range (section 7) |
| Promotion and demotion after FreeBSD | The wrong model for a system with no overcommit. A run is decided at the commit, not counted slot by slot (section 8) |
| The zero pool | Work that no budget pays, for a gain that no measure shows yet. Later, behind a measure, with a rate bound (section 9) |
| The migration | Four rows of the table are incomplete or wrong (section 10) |

Three statements of the study do not agree with the code:

- "`Budget_Grow` ... moves pages from the budget of the starter to the budget of the process", and "Property 1: no new operation". The kernel has `Budget_Create` and `Budget_Read` only (`operation.odin`). No operation adds pages to a budget that lives. `Screen_Budget` makes a second budget and gives its handle.
- "The guest `linux` gets its 128 MiB in 2 MiB entries when runs are free". Guest memory is a switching mapping: each 4 KiB page changes between Write and Execute at a nested fault (`guest.odin`, `mapping_is_switching`, `guest_page_answer`). Its slots never have one state, so it never promotes.
- "The flag `Contiguous` stays for the memory of a device". Processes with no device use it today, because the kernel writes these objects through the direct map: the rings of the kernel events (`events.odin`), the input history of a recording (`record_replay.odin`, `replay_wiring.odin`), the mailbox of `operation_fuzzing`, a picture of the compositor (`compositor/main.odin`).

One reason of the study has no source: "a dirty bit of a 2 MiB entry would make each snapshot diff 2 MiB". `record_replay.odin` and `record_and_replay.md` read no dirty bit. The code refuses a large mapping at five places for another reason: a stand-in replaces one 4 KiB page of a mapping.

## 2. Is `clamp(size, floor, ceiling)` enough

No. Six faults.

1. **The clamp has no fourth bound.** The reservation is a sum: the sizes of all processes must fit the pages of the starter. The clamp reads one process. A process that starts early takes `floor + max(floor, 2048)`, and a later process finds less than its floor: its start is refused. The start order then decides who runs. The floors are in the files, so the starter can know the sum before the first start.
   - **Rule to add.** A starter reserves the floors of its whole start list first. It divides what is left after that. A process of the start list is never refused for a growth that another process took.
   - **Check to add.** The tool adds the floors of the default start list and compares the sum with the least machine (1 GiB, the reference screen). The build fails when the image cannot start there. This check is the first proof that the floor gives.
2. **A row in pages does not move between machines.** The ceiling is a share; the size is a count. A row `pages = 40 000` is a tenth of a machine of 1 GiB and nothing on a machine of 64 GiB. The row needs one form. Recommended: a row gives `pages` (a count) or `share` (parts of 1024 of the machine at its start), never both.
3. **`ceiling_pages` has no meaning before `Budget_Grow`.** "The size never grows by itself", so the ceiling bounds only a growth. In the layers 3 to 7 of the study the field is dead. Add the field in the layer that adds the growth.
4. **A row below the floor is raised in silence.** The principal wrote 1000, the process gets 3000. The starter must write one log fact with both numbers, as it does today for a limited part.
5. **The clamp covers pages only.** Processes and threads are slots: the floor is the amount, and no policy size exists for them. Processor time and log records have no floor. The record `system.budget_size` must say this part by part; one formula for five parts is wrong for four.
6. **A row keyed by a name is forged by a disk process.** The built form says "the name of a disk process never selects a row". The row of a module of the boot image is keyed by its name, which the signed image fixes. The row of a disk process is keyed by its hash or by its class. The study says "a module, a role or a class" and must say which key each one uses.

One more amount is missing. The frame list of an arena costs one page for each 512 pages (`arena_reservation_pages`). The size must be a whole number of 512 pages; else the last arena step never fits.

## 3. Is a floor counted by the tool a floor

It is a lower bound that the tool can prove. It is not what the process needs at its start. Four parts are outside the count today, and the comments of the modules show them.

1. **The load.** `guest_demo` states 180 pages for "its page tables, its stack guard, the copy of its writable data ... as the other small processes that hold no window". No tool counts these 180 pages. The page tables of the mappings, the frame lists and the private copy of the writable data are costs of the kernel and of the loader. The tool can price them: `op.memory_cost` gives the frame list, a mapping costs one table for each 2 MiB, and the file gives the size of the writable data. This must be a counted part, `load_pages`, with the cost functions of the contract as its one source.
2. **The objects of a library.** About forty modules add "354 pages (`display.TEXT_MEMORY_PAGES`)" by hand: the glyph memory that `display` makes at the first text. A module cannot see the objects of the packages that it imports. The floor must compose: a package states its own start objects, and the tool adds them for each module that imports the package (section 5).
3. **A thread with another stack.** `clock` adds 48 pages for a worker with a stack of 64 pages. The tool counts 19 for each thread.
4. **A table sized from the machine.** The root service, the compositor and the collector size tables from the machine, and they need them before their first state of work. The study calls these tables growth. For these processes they are the floor of that machine. A size equal to the floor then fails at the start. The floor is "the least on the least machine"; the study must say so, and the refusal "floor above ceiling" is necessary, not sufficient.

The check at run time has three faults.

- **It reads a level, not a peak.** `Budget_Read` gives what a budget can still pay. A process that makes and ends an object before `Ready` shows nothing. The budget needs one more word: the least count of free pages since its creation. The kernel writes it where it subtracts pages, under the frame lock that it holds there.
- **A log fact that no test reads rots.** The fact must fail the machine test: `modustool` reads the facts of the run and stops on a floor that was passed. A floor above the use by more than a margin is a second fact, since a floor that is too large reserves pages that no process can use.
- **The moment is not defined for a process with children.** A parent that starts three children before `Ready` pays their floors. The hand states `processes = 3` and guesses their pages. Recommended: the source names the modules of the children that it starts before its first state of work, and the tool adds their floors.

## 4. Fixed tables as variables of the package

The idea is right for a table that the process always uses. The tool then counts it with no evaluation. Four limits.

1. **A variable of a library package is copied into each module that imports the package.** A table of `display` or of `text_rendering` then enters the floor of each importer, also of one that draws no text. Today the glyph memory is made at the first text (`text_memory_reserve`). With no overcommit a floor is real: 354 pages for each of 63 processes are 87 MiB of a machine of 1 GiB. Rule: a table that only some importers use stays an object made at its first use, and is a start object of the package (section 5).
2. **The study contradicts itself on the zero part.** Section 4.6 gives the zero part `Frames_Now`. The rule of the same section keeps "a fixed table of 1023 places of which it uses 30" on first use. The zero part holds the tables. Keep the rule: no prefault of the zero part.
3. **A variable never ends.** A table that only the start uses stays paid for the life of the process. An object can end.
4. **To verify before the migration.** The cost of a larger zero part for a twin of a process (`modus:twins`), and for the load: whether the loader makes the image as one object whose frames come now. If it does, each start zeroes each table.

## 5. `start_objects_pages`

It is one number of pages that the hand writes with a comment. That is the working memory with a narrower definition. Three faults.

- **The number is not the pages of the objects.** An object costs its pages, its frame list and the tables of its mapping. The hand must know these costs: a detail of an implementation, which property 22 refuses for a useful task.
- **Nothing ties the number to the code.** The size of a ring changes, and the number stays.
- **A module cannot state the objects of its imports** (section 3, part 2).

Recommended form: a list, not a sum.

```odin
// In a package: the objects that it makes before the first state of work.
PACKAGE_START_OBJECTS :: system.Start_Objects{TEXT_MEMORY_PAGES}
// In the module: its own.
MODULE_START_OBJECTS :: system.Start_Objects{RING_PAGES, RING_PAGES, LENT_PAGES}
```

Each part names a constant whose value is one integer literal, as `window_width` does today, and the code passes the same constant to `memory_create`. The tool reads the lists of the module and of each package that it imports, prices each object with `op.memory_cost` and the cost of its mapping, and adds them. The tool still evaluates nothing. The forty copies of "354" go away.

## 6. `Budget_Grow` as a general command of the root ring

### 6.1 The kernel cannot grow a budget

A budget gets its pages at `Budget_Create` and never after. `Screen_Budget` works around this: it makes two new budgets and gives each process a handle. The study takes `Screen_Budget` as the pair form of a general growth, but the general growth of section 4.4 is another thing: more pages for the arenas that exist.

An object has one payer for its whole life (`docs/ARCHITECTURE.md`, "Who pays a commit"). A commit with another budget is `Bad_Handle`, kind `Not_Payer`. An arena is one object that never moves. So an arena that got `No_Budget` cannot continue on a second budget.

Two forms are possible.

- **A. A new kernel operation** that moves pages from a budget to a budget made from it. It makes the sentence of the study true. It costs one operation of the counted interface (property 1), and it needs the reverse operation, else growth is a ratchet (6.3).
- **B. A growth is a second budget with its own life.** `Budget_Grow` gives a new budget handle. The process makes on it the objects of one purpose (the arena of one document). When the purpose ends, the process closes the objects and the budget, and the pages return to the starter. No kernel change. The cost: the process asks before it makes the arena, not when a push fails, and it knows which budget pays which arena.

Recommended: form B. It is what the kernel and `Screen_Budget` do today, it is the session quota of Genode, and the return of the pages is the close of a handle. The intent must then say: a growth never extends an object that exists.

### 6.2 Who can grow

- The command is "of the root ring". A process that another starter made (a disk process of a console sandbox, a child of `scheduler`) has no root ring. Either the growth is a protocol of each starter, in `system`, or only a process of the root service can grow. Recommended: the second, in the first layer.
- `Screen_Budget` is gated by a grant (`.Screen_Capture`, `sender_allowed`). The general command needs its gate: a row of the plan that names the module or the role. A process with no row cannot ask; its command is refused at the border, before any read of the pages of the starter.

### 6.3 Against what, and the ratchet

The growth is paid from the free pages of the starter: one pool, first come, first served. The sum of the ceilings is above the machine, or the ceilings are useless. So the pages between the size and the ceiling are overcommitted at the level of the policy. The reservation holds for the size only. The study must say this in plain words; today it says "the reservation stays".

A growth with no return captures the machine: each process keeps its peak until it stops, and four processes at a quarter each hold everything. Form B gives the return. A row can also give a growth an end: the starter revokes a growth budget whose objects ended.

### 6.4 The covert channel by refusals

A refusal of `Budget_Grow` says that the pool is low, and the study adds "the part that is short". Two processes with rows then talk: one takes and returns a growth, the other asks and reads the refusal. The rate is the rate of a ring command, thousands in a second. This is the memory-pressure channel that section 3.1 of the study refuses for `memory.min`.

Reductions, all needed:

- The refusal carries no amount. The process learns "refused", never how many pages the starter holds.
- One decision for each process in each period (one second). `Screen_Budget` already keeps `last_growth_at` for this. The channel falls to about one bit in a second.
- Each growth and each refusal is a log fact that the principal sees.
- A row can give a module a growth reserve: pages that the starter holds for that row alone. A growth inside the reserve never reads the pool, so it tells nothing. This is the form for a process that handles secrets.

What stays: a channel of about one bit in a second between two processes that both hold a growth row. It is of the class of line 17 of property 20, and the intent must name it.

## 7. `Frames_Now` and the two kernel changes

**The map that writes the present entries: keep.** It also removes the faults of the second process that maps an object, such as the compositor on the pictures of a client. The study does not count that gain. Four conditions:

- The map must use the same rule as `page_give` for each entry: the bits of the slot, `No_Access`, a switching mapping of a guest (no entry before the first nested fault), a stand-in of a recorded process (never the shared frame).
- A map of an object with no present page must cost nothing more: test `region.present == 0` first. The map of an empty arena of 1 GiB is measured at 1117 µs; a walk of 262 144 slots must not be added to it.
- The walk runs with interrupts off. It needs the bound of `RANGE_TABLE_PAGE_LIMIT`, or a lower one.
- `present_page_count` of the mapping must follow, since the test build checks it against the tables.

**`Frames_Now` as a flag of `Memory_Create`: not enough.** The table of section 4.6 asks for "the top 16 pages" of a stack and for a step of an arena. A flag of the creation covers a whole object and no uncommitted object. The prefault must be a flag of `Memory_Commit`: a table of ranges of an object, with the bound of the operation. `Memory_Create` with `Frames_Now` stays as its short form for a whole object.

**"One batch of frames under the frame lock": needs a bound.** The frame lock is the one lock of the machine for frames. Two pictures at 4K are 16 200 frames; one section for all of them stops each refill of each other processor. And the zeroing of 64 MiB in one kernel operation is one section of several milliseconds with no preemption, where 16 200 faults were each short. Rule: at most one run (512 frames) for each section of the frame lock, the zeroing outside the lock, and at most a stated count of pages for each command. The measure "the longest kernel section" is a gate of this layer.

**The gain is smaller than the study says.** Without the zero pool, the prefault removes the fault and its locks, not the zeroing: about 2 to 3 ms of a start of 11.8 ms at 1080p, inside a limit of 100 ms. The layer 1 (measure) must show the number before the layer is built. This is the rule of the project: a claim of speed has a measured number.

## 8. Promotion and demotion

### 8.1 The model of FreeBSD answers a question that this system does not have

FreeBSD reserves a run at the first fault and fills it page by page because it does not know whether the process will use the other 511 pages, and the memory is not paid. Here the budget pays 512 pages at the commit. The memory is held from that moment. The one open cost is the zeroing.

So the incremental model brings its whole state machine for nothing:

- a slot state "the frame is reserved at its offset, and not given yet", which the study never places. The run base must live somewhere. If it lives in the slot, each reader of `slot & PAGE_ADDRESS` (`region_frame`, the recording, the IOMMU declaration, `Memory_Read`, the decommit) sees a frame that is not zero and not present. "Each feature that reads a slot stays as it is" is then false;
- a count of the frames of a run that are neither free nor present, in the invariant of the frames;
- the zeroing "in place" of the empty slots of a reserved run by an idle processor, which races the first use under the region lock, and puts a region lock in the idle loop;
- a promotion as an event that some later fault starts, with its shoot-down.

**The form that this critique recommends: a run is decided at the commit.**

- A commit with the flag `Frames_Now` of an aligned whole range of 512 pages takes a free run when one exists. It zeroes the run in the caller, outside the locks (50 to 200 µs for 2 MiB, an estimate; less than the 400 to 600 µs of 512 faults). It writes the 512 slots, and sets one state bit, `SLOT_RUN`, in the first slot of the range.
- A map writes one 2 MiB entry for each range whose first slot has `SLOT_RUN` and whose address is aligned with its offset.
- A change of a part of the range (a mark, a protection of a part, a decommit of a part) clears `SLOT_RUN` and demotes, as the study designs it, with the table paid at the map.
- No range promotes later. A range that lost its run stays in 4 KiB entries until its whole decommit.
- A page on first use never takes a run. An object made with no `Frames_Now` is as today.

This form keeps "no flag for a page size and no privilege": the flag says "frames now", which the process pays in time, and the page size follows. The arena step of 512 pages asks for it. It removes the reserved state, the count, the in-place zeroing and the late promotion. `Process_Mapping` and `System_Report` keep their counts.

### 8.2 The partial decommit multiplies the damage by about 170

In the form of the study, and in the form of 8.1, a process can do this in a loop: commit an aligned range (it takes a run), then decommit 511 of its pages. The budget gets 511 pages back. One page still holds the block. Each turn costs about 3 pages (the page, a part of the frame list, the table). A budget of 2048 pages breaks about 680 runs: 1.3 GiB of contiguity for 8 MiB of budget. A budget of a quarter of the machine breaks every run of the machine, for as long as it lives.

Today this is not possible: a `Large_Pages` object refuses a decommit, so a run costs 512 pages.

The same loop is the sender of a channel. It frees its pages and the runs return at once. So "both channels change slowly" (section 4.13 of the study) is wrong: the rate is the rate of `Memory_Commit`.

**Rule to add: a run quota.** Each budget has a count of the runs that it took and that are not whole and free again. Each 2 MiB block has the budget that took it as a run (4 bytes for each 2 MiB). A budget takes a run only while its count is below its pages divided by 512. A decommit of a part returns its frames to the frame table at their place, not to the stack of a processor, so the block heals when its last page leaves. A budget then breaks at most the contiguity that its own pages are worth. The channel stays, at a rate that the quota bounds in size and not in time: the intent must say "reduced, not slow".

### 8.3 The correctness of each feature

| Feature | Finding |
|---|---|
| Copy-on-write | The kernel has none. The storage engine has it, on blocks. Nothing to check |
| A stand-in of a recorded process (a point copy) | A stand-in replaces one 4 KiB page of a mapping, so the entries of that mapping are not the frames of the object. The condition of a large entry must read what the mapping maps. The simplest rule holds: a recorded process has no large entry |
| The start of a recording | The study demotes "each mapping of the process" at once. A mapping of 1 GiB is 262 144 entries under the process lock with interrupts off, four times `RANGE_TABLE_PAGE_LIMIT`. The demotion must run in bounded steps, between which the processor takes its interrupts. The threads of the process are at input points then, so no thread runs between two steps |
| The reason "the dirty bit" | Not in the code or the intent (section 1). Replace it with the stand-in reason |
| `mapping.large` | Today a fact of a mapping, fixed at the map. It becomes a fact of a range that changes. Each reader needs a new rule: `page_give`, `guest_page_answer`, five places of `record_replay.odin`, `diagnose.odin` (the whole-only protection), the reports, the unmap. The study lists none of them |
| `No_Access` and a protection of a part | Correct as designed: they need an object that only this process names, with one mapping, so the demotion touches one page table. The study must say that this condition is what makes the demotion local |
| A whole protection change of a shared object | Keeps its large entries in each process. Correct |
| Decommit of a part | Correct with the rule of 8.2. The wake of the waiters of a frame that leaves is unchanged |
| IOMMU | A declared object has each frame from the declaration and refuses `Uncommitted`, and its frames never move. Unchanged. A contiguous object must stay below `iommu.WINDOW_BASE`; "from the low end" agrees with it |
| `Memory_Read` | Reads `region_frame` for each page. Unchanged in the form of 8.1. Wrong in the form of the study if a reserved frame is in the slot |
| The word of a wait | The key is the physical address, and no frame moves at a promotion or a demotion: correct. `word_physical` knows a 2 MiB entry only; a 1 GiB entry needs its case and its test. A later compaction moves frames: it must wake or move each waited word, which the study does not list beside the frames of a device |
| The guest | The memory of a guest is a switching mapping and never has a large entry (section 1). The gain that the study gives to `linux` needs another design: a switch of Write and Execute for each 2 MiB. That is a work of `guest.md`, not of this layer |
| The interleavings | "A commit never takes a frame: there is no frame to lose" (interleaving 1 of `docs/ARCHITECTURE.md`) becomes false. The intent must write the new interleavings: a commit with frames and a first use on another processor; a demotion and a fault on another processor |

### 8.4 Who uses a large page today

One process: the demonstration `address_space`. No service, no application and no guest maps a large page. The measured gain is 6 % on random reads under KVM. The whole of the layers 5 to 7 serves this one user and a gain on a real machine that no measure shows.

This does not refuse the design. It sets its place: after the floor, the policy and the prefault, and after a measure on a real machine. `Large_Pages` stays until then. Its removal is the last step of the layer of the runs, not a step of the migration.

### 8.5 1 GiB

A machine of the reference size has no 1 GiB run after its start. `word_physical`, the walk `page_entry`, the unmap and the reports each need a third size. No user exists. Recommended: design the formats for it (the counts of `Process_Mapping` have a field for each size), and build nothing until a process needs it. "Every page size of the hardware" then means: no privilege and no format stands in the way.

### 8.6 The software processor

The kernel also builds for `wasm64p32` (`processor_loop_wasm64p32.odin`, `page_attribute_table_wasm64p32.odin`). The study does not name it. A run, a large entry, `movnti` and an idle zeroing have no meaning there. Each of them must go behind a file with the suffix of its system, and the counts of the reports must read 0 there.

## 9. The zero pool

1. **No budget pays the work.** A process that commits a run and decommits it in a loop sends dirty runs to the idle processors for ever. Their time, the memory bus and the energy are spent outside the processor time of every budget. Line 16 of property 20 says that each resource has a limit. Rule: the pool refills at a bounded rate (a count of runs in each second for each processor). Past it, the caller zeroes in its own time, which its budget counts.
2. **An idle processor that zeroes is not idle.** It does not sleep. On a machine with two threads for each core it slows its twin. A stream of `movnti` takes the memory bus from the processors that work: the noisy neighbour, by another door, and a channel by the speed of the memory. The study gives a target and no measure of this cost.
3. **`movnti` needs `sfence`.** A store that bypasses the cache is weakly ordered. The processor must run `sfence` before the run goes to the pool, so that another processor never reads the bytes of before. The study does not say it. A missed `sfence` gives a process the data of another one.
4. **The zero bit is a global invariant.** Today "a frame is zero when a page takes it" is true by the three lines of `region_frame`. With `frame_zero_bits`, it is true only if each path that frees a frame clears the bit. Safer rule: the bit means something only for a frame in the frame table, and `frames_take` clears it. Then one place writes "dirty", and no path of a free can forget it. The check of 64 bytes at a random place is too weak for a rule that keeps processes apart: the test build must check the whole run.
5. **A guest machine.** The target bounds the memory that the host backs. It does not bound the time: with the loop of part 1, a guest never halts its processors, and the host pays. The rate bound of part 1 closes this. The kernel knows that it is a guest (`stolen_time.odin`), so a plan value can turn the pool off there.
6. **The pool is a shared fact.** "The pool target is for each processor, so the channel stays inside the processors that two processes share" is not shown: the runs come from one frame table under one lock, and a prefault can take the run that another processor zeroed.
7. **With the form of 8.1, the pool is an option, not a base.** The caller zeroes its run in its own time, charged and bounded. The pool only moves that time away from the caller. Build it when a measure of a start shows that the zeroing is the cost that matters.

## 10. The migration, part by part

| Part | Finding |
|---|---|
| The share of a quarter | Becomes the default ceiling. But a ceiling bounds a growth only (section 2, fault 3). Until the growth exists, the share stays what it is today: the most that a start gets. Do not rename it twice |
| `Screen_Budget` | Not a pair form of the growth of the study: it is the only form that the kernel allows (6.1). Turn the sentence round: `Budget_Grow` is the single form of `Screen_Budget`. Keep its rate limit and its replacement rule for both |
| `screen_pictures` | A part of the floor that the starter computes from the screen of the machine. So the floor in the file is not the floor of the start. The check of the sum (section 2, fault 1) must take the reference screen, and the starter must refuse with a line that names the screen |
| `wiring_pages` of a module, "by default half of the growth part" | "Half" is the guess of today under a new name, and it now depends on a policy value, so a wiring fails or not by the size of a row. Recommended: the wiring budget of a module is a start object that the plan prices, since the plan holds the wirings; a module that wires at run time asks a growth |
| The audit pages of the collector | "The floor of the collector plus the pages of each audit that the plan declares" is right, and it shows a general case that the study has no word for: a floor that the plan computes. The collector, the wirings of a start list and the screen pictures are three such cases. Name it once: the floor of a start is the floor of the file plus the parts that the starter adds from the plan and the machine. `system.budget_size` takes that sum, not the number of the file |
| The budget of the disk processes | Becomes the size and the ceiling of a class. Two points. The pages of that budget "return to the root service never" today; a class row that the principal lowers must have a rule. And `budget_create` moves processes and threads at once, so the reason of the built form (eight hostile files took the slots) must stay: the class row bounds slots, and no row of a disk process can raise them |
| `budget_exceptions` for pages | Already removed by the share on the branch of integration. No row is needed on the reference machine. Do not add rows for `address_space` and `linux` that only repeat the share |
| `processor_exceptions`, `log_records_exceptions` | "Rows of the plan of the test machine". These are facts of three test modules, not choices of a principal. A plan row for a test puts test data in the default plan of the signed image. Recommended: the image of the tests carries its own plan file, which the default image does not have |
| `LEAST_BUDGET` as the floor of a file with no table | 2048 pages as a floor makes `floor + max(floor, 2048)` 4096 pages for a module that states nothing. Before 1.0 nothing is kept for an older tool: a file with no table `Floor` is refused |
| `budget_decide` | Its line "a part above the largest takes the largest" goes. Each test that checks a limited part changes with it |
| The 125 uses of `working_memory_pages` | The migration is module by module. Each module needs the split of its number into the load, the start objects, the children and the growth. The Ready check (with the peak, section 3) is the tool of this split: build it first, read the peak of each module, then remove the number |

## 11. The joint recommendation

The form that this critique signs.

1. **Two records.** The floor in the file; the policy in the plan. As the study says.
2. **The floor is counted whole.** Module pages, thread pages, window pages, load pages, the start objects of the module and of its packages as a list of named constants, and the floors of the children that the source names. The hand writes names and counts of slots, never pages.
3. **The floor of a start** is the floor of the file plus what the starter adds from the plan and the machine: screen pictures, wirings, audits.
4. **The sum first.** A starter reserves the floors of its start list, then divides the rest. The tool proves at the build that the default image starts on the least machine.
5. **The size** is a row (`pages` or `share`) or the default `floor + max(floor, 2048)`, rounded up to 512 pages. A row below the floor gives the floor and one log fact. A floor that the starter cannot pay refuses the start.
6. **The peak.** A budget keeps its least free pages. The machine test fails when a process passes its floor before its first state of work.
7. **The growth** is a second budget with its own life (`Budget_Grow`, form B), for a process of the root service with a plan row, at most one decision in a second, refused with no amount, logged, with an optional reserve for a row. `ceiling_pages` comes with it. The intent says that the pages past the size are not reserved.
8. **The prefault** is a flag of `Memory_Commit` for ranges, and the map writes the present entries. Bounded sections. No privilege.
9. **A run is decided at a commit with frames now** of an aligned whole range, zeroed in the caller, marked by one slot bit. A change of a part demotes. No late promotion. A run quota for each budget. No privilege.
10. **`Contiguous`** stays for each object that the kernel or a device reads by its physical address, not for devices only.
11. **Later, each behind its measure:** the zero pool (with its rate bound, `sfence`, the bit that the take clears), 1 GiB entries, large entries for a guest, compaction, the runs that a row reserves for one budget.

## 12. The order of the work

1. **Measure.** As the study: the first use of a page, `Frames_Now`, the first frame at 1080p and at 4K, the arena. Add the longest kernel section, and one run on a real machine for the large pages.
2. **The peak of a budget and the Ready check.** One word in the budget, one fact, one stop of the machine test. It works on the request of today, and it gives the true need of each of the modules.
3. **The counted floor.** `load_pages`, the list of start objects, the children by name, in the tool. The table `Floor`. The working memory leaves, module by module, each one checked by step 2.
4. **The sum and the size.** The reserve of the floors of the start list, the check of the least machine at the build, `system.budget_size`, the default size, the refusal of a floor that cannot be paid.
5. **The rows of the plan.** `pages`, `share`, `processor`, `log_records`; the class of the disk processes; the plan file of the test image; the tables of exceptions leave.
6. **The map writes present entries; the prefault of a range.** Only if step 1 shows the gain. Kernel code: an independent review before the merge.
7. **`Budget_Grow`**, form B, with its row, its rate and its facts; `Screen_Budget` on the same table.
8. **Runs of 2 MiB at a commit with frames now**, the demotion, the quota, the placement of single frames, the new interleavings in `docs/ARCHITECTURE.md`; then the removal of `Large_Pages`. Only after the measure on a real machine. An independent review.
9. **Later:** the zero pool, 1 GiB, the guest, compaction.

The steps 2 to 5 change no kernel path of memory except one word of a budget. They give the whole of "budgets as policy". The steps 6 to 9 are another subject, "the frames of a process", and need their own intent file: `module_budget_request.md` holds two designs today, and the second one is three quarters of the risk.

**The test that breaks this design on its first day** (step 4): a start list of the least machine whose floors fit and whose default sizes do not. The first processes take their default size; the test checks that the last one still starts with its floor, that no process got less than its floor, and that the pages left were divided by the rule and not by the start order. Then one process gets a floor one page above what the starter holds: its start is refused with one line that names both amounts, and no page moved. The test of the study (the demotion under a reader thread) stays the first test of step 8, with one more case: the loop of 8.2, which must stop at the quota.

## 13. The questions for the owner

1. **Does the growth past the size extend an arena that exists, or is it a second budget?**
   Recommended: a second budget with its own life. Consequence: no new kernel operation, and the pages return by a close. A process asks before it builds its large data, and an arena that reached its budget cannot continue.
2. **Is it accepted that the pages between the size and the ceiling are not reserved?**
   Recommended: yes, and written in the intent, with the rate limit and the refusal with no amount. Consequence: a channel of about one bit in a second stays between two processes that both hold a growth row. The other answer is no growth at all: each size is final, and a row is the only way to a larger budget.
3. **The default size: `floor + max(floor, 2048)`?**
   Recommended: yes, after the floors of the start list are reserved. Consequence: on a small machine the last processes get their floor alone, and the log says it. No process fails for the size of another.
4. **A hint of the usual size in the module file?**
   Recommended: no, as the study says. Consequence: a module of another project runs with the default until the principal gives it a row. A hint is the request of today again.
5. **Do the frames of a process become their own design, after the budgets?**
   Recommended: yes. Consequence: the floor and the policy are built first with no change of the memory paths of the kernel. `Large_Pages` and the first use of today stay until a measure on a real machine asks for the runs.
6. **A run at a commit with frames now, in place of the promotion of FreeBSD?**
   Recommended: yes. Consequence: a range whose pages come one by one, at their first use, never gets a large page. The arena step of 512 pages and each prefaulted object do. The kernel gets no reserved state of a frame and no late promotion.
7. **The contiguity: shared with a run quota, or runs that a row reserves for one budget?**
   Recommended: shared with the quota first; the reserved runs later, for a budget that must not see the others. Consequence: the channel of the contiguity stays, bounded in size. A reserved run is memory that no other process can use while that budget lives.
8. **The zero pool on a guest machine?**
   Recommended: no pool is built in the first layers, on any machine. When a measure asks for it: the same target on a guest, with the rate bound, and a plan value to turn it off. Consequence: until then a prefault zeroes in the time of its caller, which its budget counts.
9. **1 GiB entries now?**
   Recommended: no. The formats keep a place for them. Consequence: "every page size with no privilege" is true of the design; the code has 4 KiB and 2 MiB until a process needs more.
