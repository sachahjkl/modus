# Budgets as policy: the floor of a module, the size that the plan sets, and the frames that a process gets at its start

This study is a design study. It changes no code. Its result is the proposed intent [`src/md/features/module_budget_request.md`](../../src/md/features/module_budget_request.md). The decisions of the owner, after the critique, are in section 10; where they differ from sections 4 to 9, section 10 holds. The intent before this study is kept at the end of this file, in "Appendix: the intent before this study".

## 1. The question

A budget of a process today holds pages, processes, threads, processor time and log records. The module states a request in its file; the starter decides it. Over time, the request took parts that are not facts of the module: a working memory that the developer guesses, a table of exceptions in the root service, a share of the machine, the pictures of the screen of the machine, the wiring pages, the pages of the audits of the collector, a budget of its own for the disk processes.

The direction that is agreed:

- The module declares only its **floor**: what it needs to start. The tool counts the floor as far as it can. The hand writes almost nothing.
- The **size** of the budget is policy. The plan or the starter sets it, with a default. The **ceiling** of a process or of a role is a plan value. The size is a reservation: no overcommit. Past the floor, a process grows in arenas inside its reserved budget.
- The table of exceptions and most special parts (the screen, the wirings, the audits) become plan policy.
- The reservation stays. No overcommit gives no memory-pressure covert channel and no noisy neighbour.

Two more questions:

- Can the floor serve to give the process its frames before it runs (a prefault), from frames that idle processors zeroed ahead, with large pages where the floor allows it?
- Large and prefaulted pages need no privilege. A module whose budget pays them gets them. This study covers every page size of the hardware (4 KiB, 2 MiB and 1 GiB on x86-64; the sizes of ARM64 and its contiguous hint for later), what each costs in this system, and what happens when no contiguous frames are free.

## 2. What exists

### 2.1 The parts of a budget and who sets each one

This table holds the state of `master` and of the branch of integration (marked "integration"), which holds newer mechanisms.

| Part | Where | Who sets it | Fact of the module, or policy |
|---|---|---|---|
| Module pages (the module and its imports) | `tools/modustool/build/budget_count.odin`, `module_pages` | the tool | fact |
| Thread pages: 72 for the first thread (stack 64, context 1, thread area 3, own log ring 4), 19 for each other one | `BUDGET_FIRST_THREAD_PAGES`, `BUDGET_OTHER_THREAD_PAGES` | the tool, from the stated threads | fact |
| Window pages: two pictures at the largest scale, cut to the reference screen for a resizable window | `budget_count` | the tool, from the stated size | fact |
| Working memory | `system.Stated_Budget.working_memory_pages` | the hand, with a comment | a guess: tables of fixed size, tables sized from the machine, caches, arenas, budgets of children |
| Processes, threads | `Stated_Budget` | the hand | fact of the code, which the tool cannot count |
| Screen pictures (integration) | `Budget_Request.screen_pictures`, `budget_request_of_screen` | the module states a count; the starter adds the pages of the screen of the machine | fact of the module times a fact of the machine |
| Plan rows that lower the screen pages (integration) | `plan_screen_rows` in `root/budgets.odin`, empty | the plan of principal 0, not given yet | policy |
| Wiring pages (integration) | `Budget_Request.wiring_pages`; 0 gives half of the pages | the hand; the tool for a start list (`start_list.wiring_pages_of_list`) | fact for a list, guess for a module |
| Pages of the audits of the collector (integration) | the root service widens the collector by `SPACE_AUDIT_PAGES` for each wiring row with audit terms | the root service, from the start list | fact of the plan |
| Least budget: 2048 pages, 1 process, 1 thread | `root.LEAST_BUDGET` | the root service | policy |
| Largest budget: 16 384 pages, 8 processes, 32 threads (`master`); a quarter of the pages and threads of the root service at its start, at least 16 384 pages (integration, `largest_budget_of_machine`, `budget_share_take`) | `module.LARGEST_BUDGET`, `module.LARGEST_BUDGET_SHARE_DEFAULT` | a constant; the plan of principal 0 later (integration) | policy |
| Exceptions of pages: `address_space` 42 338, `linux` 34 932 (`master`); removed by the share (integration) | `budget_exceptions` | a table in the code of the root service | policy written as code |
| Exceptions of processor time: `limits` 1.5 processors | `budget_exceptions` / `processor_exceptions` | a table in the code | policy written as code |
| Exceptions of log records: `limits` 40, `log_flood` 0 | `log_records_exceptions` | a table in the code | policy written as code |
| Processor time: one processor for each thread | `PROCESSOR_OF_A_THREAD` | a constant | policy |
| Budget of the disk processes: 16 384 pages (`master`), 32 768 (integration), 4 processes, 16 threads, 2 processors; largest for one: half of the pages, 1 process, 4 threads | `disk_process.PROCESSES_BUDGET`, `LARGEST_BUDGET` | constants | policy |
| Extra budgets of a screen of memory (integration) | root ring command `Screen_Budget`, `screen_budgets`, `memory_screen.screen_budget_grow_decide` | the root service, at a request of the compositor | a growth of two budgets at run time |
| The budgets of the children of `scheduler`, `rings`, the console sandboxes | each starter | fixed amounts | policy written as code |

The rule of a starter is `system.budget_decide`: a part of 0 takes the least, a part above the largest takes the largest, with one line of the log. A process that gets less than its request starts all the same, and fails later at its first window or its first table.

### 2.2 The memory of the kernel, as the code shows it

- `Memory_Create` pays the budget at once. A page gets its frame at its first use (`page_give` → `region_frame` → `frame_reserved_take` → `frames_zero`), under the process lock and the region lock of the object. The flag `Frames_Now` runs the same `region_frame` for each page at the creation, one page at a time.
- A map writes no entry for the pages of an object that is not contiguous: each page takes one fault, also when it has its frame. A map of an object of large pages writes its entries.
- The frame table is a bitmap (`frame_bits`). `frames_take` is a first fit from a hint; `frames_take_aligned` walks for an aligned run. Each processor keeps a stack of at most 256 free frames (`FRAME_CACHE_CAPACITY`), filled in batches. The frames on a stack are not zero; a frame is zeroed when a page takes it, after the locks.
- No reserve can fail: `free_frames` = the pages of all budgets + `reserved_pages` at each moment that the frame lock is free. A reserved page always finds a free frame. This invariant is the "no overcommit" of the kernel.
- `Large_Pages` makes a contiguous object: one run aligned on 2 MiB, a whole number of 2 MiB, frames zeroed at the creation (`frames_zero(region.physical, page_count)`, under no lock but in the operation). Such an object refuses `Uncommitted`, refuses a decommit, and takes a protection change only for its whole mapping. The kernel has no 1 GiB page.
- `frames_zero` is `intrinsics.mem_zero`. The kernel has no vector code (`docs/ARCHITECTURE.md`, "3a. The kernel has no vector code").

### 2.3 What the measures show

| Measure | Value | Source |
|---|---|---|
| Pages committed and used in one second, an arena of 1 GiB, 1 range for each kernel entry | 810 775 (1.23 µs for each page) | `address_space`, log of a machine test, QEMU with KVM |
| The same, 16 ranges for each entry | 1 290 112 (0.78 µs) | same |
| The same, 256 ranges for each entry | 1 163 182 (0.86 µs) | same |
| The map of an arena of 1 GiB (frame list of 513 pages) | 1 117 µs | same |
| One random read over 64 MiB | 11.60 ns through large pages, 12.40 ns through 4 KiB pages | `address_space`, same run |
| The start of the window `locks`, from `Process_Start` to its first frame | 11 827.5 µs | `docs/measures/measures.txt` |

The case `frames` prints "the first use of a page" and "create and map 8192 pages with each frame now / with pages on first use", but the logs that this study found keep only the template of the line, not a value. The first layer of the work records them in the measure of the build (section 8).

What the numbers say, with the parts that are estimates marked:

- **A page on first use costs about 0.8 to 1.2 µs under KVM**: the commit (amortised over a step), the fault, the two locks, the take of a frame, the zeroing of 4 KiB, the entry, the return. The zeroing of 4 KiB with `rep stosb` at 10 to 30 GB/s is 0.14 to 0.4 µs (an estimate). The rest, 0.4 to 0.8 µs, is the fault and its locks (an estimate).
- **A window pays this at its first frame.** One picture of 1920 × 1080 is 2025 pages; of 3840 × 2160, 8100 pages. Two pictures on first use cost 3 to 5 ms at 1080p and 13 to 20 ms at 4K, inside the 100 ms of "a window shown" (property 18). The start of `locks` is 11.8 ms whole.
- **The gain of a large page under KVM is small here**: 6 % on random reads, because the host backs the guest with its own pages and walks its own tables (the nested walk). On a real machine, and for a guest that this system runs (`linux`, whose memory is mapped by the nested page table of its process), the gain is larger: the miss of a 4 KiB translation in a nested walk reads up to 24 entries, and a 2 MiB page removes one level on each side.

## 3. Prior art

### 3.1 Linux cgroups v2, memory controller

- `memory.min`: a hard protection. The kernel never reclaims below it. `memory.low`: a soft protection. `memory.high`: a throttle point; past it the group is reclaimed hard and slowed. `memory.max`: a hard limit; past it the OOM killer runs in the group.
- The sizes are set from outside, by the manager of the system (systemd, Kubernetes). The program declares nothing. Kubernetes adds `requests` (what the scheduler reserves on a node) and `limits` (the `max`), set by the author of the deployment, not by the program.
- What to take: **the size is policy of the manager, not a fact of the program**, and a protection (`min`) is a separate value from a limit (`max`).
- What to leave: overcommit. `min` protects only against reclaim; the memory is still taken on demand, so a group can fail at a page fault (the OOM killer) and another group sees the pressure (a covert channel, and the noisy neighbour). Here the floor and the size are paid at the start, so no fault fails.

### 3.2 Fuchsia (Zircon): jobs, VMOs, commit

- A job is a node of a tree that holds processes and other jobs, with policies (which syscalls, which objects). Memory accounting is by attribution to the job; Zircon has no hard memory limit on a job as such, and commits memory on demand, with a memory-pressure signal and an out-of-memory killer of the system.
- A VMO is a memory object. `zx_vmo_op_range` with `ZX_VMO_OP_COMMIT` gives the pages at once; `ZX_VMO_OP_DECOMMIT` gives them back. `ZX_VM_MAP_RANGE` maps the committed pages at once, so no fault follows. Contiguous VMOs exist for drivers (`zx_vmo_create_contiguous`, with a bus transaction initiator handle).
- What to take: **commit and map-at-once are two flags of operations that exist**, not a new concept. This system has the commit and the flag `Frames_Now`; it lacks the map that writes the entries.
- What to leave: the pressure signal and the killer. They are what a reservation removes.

### 3.3 seL4: untyped memory

- All memory is untyped capabilities at boot. A holder retypes a part into kernel objects (frames, page tables, thread records). The kernel has no allocator; the size of each object is the size of its untyped region. Large frames are untyped regions of 2 MiB or 1 GiB, aligned, retyped to a large frame object.
- What to take: **memory is a capability that is paid before use, and the payer is explicit** (property 14 already takes this). Large frames need no privilege: whoever holds an aligned untyped region of that size can make one.
- What to leave: the work of the user to keep alignment. In seL4 the holder of the untyped memory solves the fragmentation itself. Here the kernel owns the frames, so it can choose runs; the budget remains a count.

### 3.4 Genode: RAM quotas and session quotas

- Each component has a RAM quota that its parent gave. A component that opens a session with a service gives the service a part of its quota, the session quota, so the service pays its state for that client from the client's memory. A quota upgrade is a request to the parent. A quota is a reservation: no overcommit.
- The sizes are written in the configuration of the parent (`<resource name="RAM" quantum="16M"/>` in the `init` configuration), not in the binary. The binary can ask for more at run time with a resource request to its parent, which the parent's policy accepts or refuses.
- What to take: **the closest model to this design**. A reserved quota, set by the configuration of the parent, with a run-time upgrade that the parent decides. The session quota is the answer of this system's "Who pays a commit" (a narrow `Commit` right on a child budget).
- What to leave: the hand-written quantum in the configuration for every component, which is a guess as the working memory is today. Here the floor comes from the tool, and the configuration gives only what is above it.

### 3.5 Windows job objects and large pages

- A job object limits the committed memory of a process (`JOB_OBJECT_LIMIT_PROCESS_MEMORY`) and of the job (`JOB_OBJECT_LIMIT_JOB_MEMORY`). The commit charge is real: Windows counts commit against RAM plus page file, so a commit can fail, and a commit is not a frame. Windows 10 adds hard working-set limits and CPU rate control.
- Large pages: `VirtualAlloc` with `MEM_LARGE_PAGES` needs `SeLockMemoryPrivilege`, the memory is non-pageable and committed at once, and the allocation fails when no contiguous run is free. The privilege exists because the pages cannot go to the page file: a process with large pages holds physical memory that the system cannot take back.
- What to take: **a hard limit on commit at the job**, and the fact that a large page is committed whole.
- What to leave: the privilege. Its reason is the page file. Here no page goes to disk, and every page is reserved by a budget: a large page holds no more physical memory than the budget already reserved. The other reason, contiguity, is a resource of the machine that a policy can divide, not a right.

### 3.6 Plan 9

- No quotas. Memory is allocated on demand with `segattach` and `brk`; a machine out of memory kills the largest process (`killbig`). Plan 9 is the case of no policy at all, with simple code.
- What to take: the simplicity of one segment model.
- What to leave: no limit at all. Property 20, line 16, refuses it.

### 3.7 The others that bear on the page sizes

- **FreeBSD superpages** (Navarro, Iyer, Druschel, Cox, "Practical, transparent operating system support for superpages", OSDI 2002). At the first fault in an aligned 2 MiB of an object, the kernel reserves an aligned run of frames for the whole 2 MiB, gives each 4 KiB page its frame at its fixed offset in the run, and promotes the mapping to one 2 MiB entry when all 512 pages are present. A demotion splits it back. Contiguity is kept by grouping the frames of the free lists by run. **This is the model that this design takes**, because it keeps each feature per 4 KiB and needs no flag.
- **Linux transparent huge pages** and `khugepaged`: a fault in a 2 MiB region takes a huge page when one is free, else 4 KiB pages; a thread collapses them later by a copy. Compaction moves frames to rebuild runs. The fault of a huge page zeroes 2 MiB on the fault path, which shows as latency spikes; the `defrag` setting chooses between waiting for compaction and falling back.
- **Linux hugetlbfs**: a pool of huge pages that the administrator reserves at boot; 1 GiB pages usually only at boot. A reservation at boot is the reliable way to have 1 GiB pages.
- **Pre-zeroing of free pages.** Several kernels tried an idle thread that zeroes free pages (Windows has one: the zero page thread of the memory manager, at the lowest priority; Linux rejected several patches). The objection of Linux: a page zeroed ahead is cold in the caches, and a page zeroed at its fault is hot for the write that follows. The measure decides, per size: for 4 KiB the warm cache wins; for a run of 2 MiB, which is larger than the L1 and L2 caches, the zeroing evicts the cache anyway, and the time on the fault path is the cost.

## 4. The design

### 4.1 Two records with two owners

The design separates two records that today share one record, `module.Budget_Request`:

- **The floor** is a table of the module file. It holds what the process needs to reach its first state of work: its pages, its processes, its threads, and the count of screen pictures. The module and the tool own it. It is signed with the module (property 11).
- **The budget policy** is a record of the plan. It holds the size, the ceiling, the processor time and the log records of a module, of a role or of a class of processes (the disk processes). The plan of principal 0 owns it for the machine, the plan of a principal for its disk processes. The signed boot image holds the default plan, so the system starts before any plan exists.

A starter computes a budget from both: `size = clamp(policy size, floor, ceiling)`. The budget is reserved at the start, as today.

### 4.2 The floor: what the tool counts

The floor is a sum of facts. The tool counts all of them, except three that the code alone knows.

Counted by the tool, as today:

- the module pages: the memory size of the module and of each import, each one time;
- the thread pages: 72 for the first thread, 19 for each other stated thread;
- the window pages: two pictures of the stated window at the largest scale.

Counted by the tool, new:

- **the fixed tables**. A table of a fixed size is a variable of the package (`[N]Record`), so it is in the memory size of the module (its zero part) and the module pages count it. Today many processes make such tables at run time from their budget, then state their pages by hand in the working memory. The migration moves each fixed table to a variable of the package (section 6). The hand then states nothing for it, and the tool counts it with no evaluation.
- the wiring pages of a start list: already counted (`start_list.wiring_pages_of_list`).

Stated by the hand, with a comment of reasons, as today:

- `processes` and `threads`: the children and the threads that the process runs at one time;
- the window size: the constants that the process passes to `display.open`;
- `screen_pictures`: the count of pictures of the size of the screen;
- **`start_objects_pages`**: the memory objects of a constant size that the process makes before its first state of work, and that cannot be variables of the package because the process shares them or maps them at a place (a ring, a surface of a fixed size, a page that it lends). This part replaces the working memory. It holds no table, no cache and no arena.

Not in the floor: each table sized from the machine (`process_slots_of`), each cache, each arena, the budgets of children past their floors, the page tables of mappings past the floor. These are the growth. They come from the budget past the floor, and a refusal is the status `No_Budget`, which the process reads (property 14).

**The floor is checked at run time.** At the first state of work of a process (its `Ready` on the root ring, or its first frame for a process with a window), the root service reads its budget with `Budget_Read`. If the process used more than its floor, one log fact says by how much. A wrong floor then shows on the first boot, with a number, and no test needs to guess it.

### 4.3 The size: policy, with a default

- **The size** is what the plan gives a module or a role. A row of the plan names a module, a role or a class of processes, and gives some of: `pages`, `ceiling_pages`, `processor`, `log_records`. A part that the row leaves out takes the default rule.
- **The default size** is the floor plus a growth: `floor + max(floor, 2048)` pages, at most the ceiling. A process with no row then has room to double its floor, and at least 8 MiB past it. The choice of the rule is a question for the owner (section 9).
- **The ceiling** is the share of the machine (integration: a quarter of the pages and threads of the root service at its start, at least 16 384 pages). It stays a plan value of principal 0, with the share as its default. A row can lower or raise the ceiling of one module or role; the share is the ceiling of a module with no row.
- **The floor above the ceiling is a refusal of the start**, with one line that names the floor and the ceiling. Today the starter gives the largest budget and the process fails later; a budget below the floor never serves.
- **The size never grows by itself.** A process that needs more than its size asks its starter (section 4.4). The starter answers from its free pages, up to the ceiling. The answer is a reservation, or a refusal that the process reads.

### 4.4 The growth past the size

A process holds its growth in arenas, as `memory_without_a_bound.md` designs. When its budget is spent, an arena push gives `No_Budget`. A process that has a reason to grow further asks its starter for more pages with one command of the root ring, `Budget_Grow` (pages, a reason of an enum). The starter decides by the plan: a row says which modules or roles can grow, up to their ceiling. The answer moves pages from the budget of the starter to the budget of the process, or refuses with a status and the part that is short.

This is the general form of `Screen_Budget` (integration). `Screen_Budget` grows two budgets together, the compositor and the service of the remote display, for one size of a screen of memory. It keeps its pair rule, as a rule of the root service for these two roles, on top of the general growth (section 6).

### 4.5 The page sizes: one model, the run of slots

The model, taken from FreeBSD:

- **A run** is an aligned block of free frames of one page size: 512 frames (2 MiB) or 262 144 frames (1 GiB) on x86-64.
- **A commit of an aligned whole run of an object** (the range of pages of the object starts on a multiple of 512 and covers 512 pages, or the same for 1 GiB) takes a free run when one exists. Each 4 KiB slot of the range gets its frame at its fixed offset in the run, at its first use or at once (`Frames_Now`). Else the commit takes single frames, as today. A commit is never refused for a run: the budget paid for pages, not for a page size.
- **A mapping uses the largest entry that the state allows.** When the 512 slots of an aligned range have their frames, those frames are one run, the slots have the same state bits, and the address of the mapping is aligned with the offset in the object, the kernel writes one 2 MiB entry: a promotion. The same rule over 512 promoted ranges gives a 1 GiB entry, on a processor that has 1 GiB pages (CPUID `pdpe1gb`).
- **A change of one slot demotes the entry**: a `No_Access` mark, a protection change of a part, a decommit of a part, the start of a recording. The kernel writes the 512 entries of the table from the slots, then replaces the 2 MiB entry with the entry of that table, then makes the shoot-down of a protection change (`docs/ARCHITECTURE.md`, "Protection and the shoot-down").
- **A demotion never takes a frame.** The map of a range that can hold a large entry makes and pays the tables of the last level, as a map of 4 KiB pages pays them today (one page for each 2 MiB, 0.2 %); the promoted mapping keeps its table aside. A 1 GiB entry keeps the 512 tables and its directory the same way (513 pages for each 1 GiB, the cost of a 4 KiB mapping of 1 GiB today). So no demotion has a path that fails.
- **The frame list stays per 4 KiB**, also for a run: 8 bytes for each 4 KiB page, 0.2 %. Each feature that reads a slot stays as it is.

What this removes:

- the flag `Large_Pages` and its contiguous object. A large page is what the kernel gives each committed aligned run, with no flag and no privilege (property 22: one mechanism). The flag `Contiguous` stays for the memory of a device that needs physical contiguity for its transfers, which is a fact of the device, not a page size.
- the refusal of `Uncommitted` with large pages, of a decommit of large pages, and of a protection change of a part of a large mapping. Each of them demotes now.

Why no privilege: the budget reserves each page that a run holds. The process holds no frame that its budget did not pay, so a large page takes nothing from another process. Windows needs `SeLockMemoryPrivilege` because a large page cannot go to its page file; this system has no page file. The other resource, the contiguity of the free frames, is a fact of the machine that the kernel shares by its rule of placement (section 4.8), not by a right.

### 4.6 The prefault of the floor

The kernel reads no floor: it knows no module file (`module_budget_request.md`, "The kernel reads no request"). The kernel can take no object of the floor at `Process_Create`, because the loader and the process make those objects. So the prefault is a flag of the objects of the floor, which the library that makes each one sets:

| Object of the floor | Who makes it | Prefault |
|---|---|---|
| The module image and its imports | the loader | present today: the loader writes it. Its zero part (the fixed tables) gets `Frames_Now` |
| The stack of the first thread (64 pages), of each other thread (16) | the starter, `system.thread_start` | `Frames_Now` for the top 16 pages; the rest on first use (a deep stack is rare) |
| The context page, the thread area, the own log ring | the kernel, at `Process_Create` and `Thread_Create` | the kernel zeroes them now |
| The two pictures of a window, the screen pictures | `display.open`, the compositor | `Frames_Now`; each is written whole at the first frame |
| The start objects (rings, lent pages) | the process | `Frames_Now`, by the library of the ring |

Two changes of the kernel make the flag cheap:

1. **A map writes the entries of the pages that have frames.** Today only an object of large pages gets its entries at the map; another object takes one fault for each page, also with `Frames_Now`. The map walks the slots it covers and writes an entry for each present page, under the process lock that it takes anyway.
2. **`Frames_Now` takes its frames in one section**: one batch of frames under the frame lock, from runs where the object has aligned ranges (section 4.5), and from the zero pool (section 4.7). Today it takes the region lock and a frame for each page.

What the prefault gains and costs, by the numbers of section 2.3:

- **Gain**: the faults of the floor at the first frame. Two pictures of 1080p are 4050 faults: 3 to 5 ms at the first frame, which is the measure "a window shown". With frames of the zero pool, the same pictures cost a few large entries and no zeroing on the path of the start.
- **Cost without the zero pool**: the start takes the zeroing that the first frame took before, plus the zeroing of pages that the process never touches. A page of the floor that the process never touches costs 0.14 to 0.4 µs of zeroing and no memory: its budget reserved it anyway, so its frame was held from every other process already. This is the reason of the prefault in this system: **with no overcommit, a frame taken early costs no memory, only the work of its zeroing**.
- **Rule**: prefault an object that the process writes whole at its start (pictures, rings, the top of a stack). An object that the process touches in parts (a fixed table of 1023 places of which it uses 30) stays on first use, until a measure of its touched part says otherwise.

### 4.7 The zero pool

- **Each free frame has a state**: dirty or zero. A second bitmap, `frame_zero_bits`, one bit for each frame (32 KiB for each GiB), holds it. A frame that returns is dirty. A frame that a page takes, dirty, is zeroed as today; zero, it is given at once.
- **The pool is a set of zero runs of 2 MiB.** An idle processor, before it waits (`idle_wait`), takes one dirty free run from the frame table when the pool is below its target, under the frame lock. It moves the run to a count of frames in zeroing, so the invariant of the frames becomes `free_frames + zeroing_frames` = the pages of all budgets + `reserved_pages`. It releases the lock and zeroes the run in steps of 64 KiB, and after each step reads its `pending` flag and takes its interrupts (`interrupt_window`). A wake stops the zeroing: the run returns to the frame table with the bits of the steps that ended. A run whose 512 bits are zero returns to the pool.
- **The zeroing of a run uses `movnti`**, a store that bypasses the cache, so the idle processor does not evict the caches of the next thread. `movnti` takes a general register, so the rule "the kernel has no vector code" holds. A 4 KiB page keeps its zeroing at its first use with `rep stosb`, because the write that follows finds it in the cache.
- **The target** is a count of runs: 2 runs for each processor and at most 1/64 of the memory of the machine, as a default; a value of the plan of principal 0 can change it. A machine that is a guest of a hypervisor zeroes memory that the host has not backed yet, and the zeroing makes the host back it: the default on a guest is the same target, which bounds that cost to 4 MiB for each processor.
- **Who uses the pool**: `Frames_Now` of an aligned run, the commit of a run, a 2 MiB promotion of a range whose pages are first used one at a time (the idle processor can zero in place the slots of a reserved run that have no frame yet, so the range promotes earlier). Single frames come from the stacks of the processors, dirty, as today.
- **ZII holds**: each frame that a process receives is zero (property 13, "Zero is initialization"). A test build checks that a frame of the pool reads zero on 64 bytes at a random place of the run, at the take.

### 4.8 The placement of frames, against fragmentation

A free run exists only if single frames did not take one frame of each run. Today `frames_take` is a first fit from a hint, and a refill of a stack takes 1 frame at a time: the single frames spread over the whole memory with uptime.

- **The single frames come from broken runs first.** The kernel keeps a count of free frames for each 2 MiB of the frame table (an array of `u16`, 1 KiB for each GiB). A refill of the stack of a processor takes from the 2 MiB block with the fewest free frames that is not full; a whole free block is broken last. This is the grouping of FreeBSD and of the `pageblock` of Linux, in its simplest form.
- **The kernel tables** are taken at the start (`src/md/data/table_sizes.md`), so they break no run later.
- **The frames of a device** (`Contiguous` for a device, the declared memory of the IOMMU) cannot move. They come from the low end of the frame table, the single frames of the processes from a broken block, and the runs from the high end, so the three fragment each other less.
- **No compaction in the first layers.** A compaction moves the frames of a process to build a run: a copy, a change of each slot and of each entry, and a shoot-down, refused for each frame that a device or the IOMMU holds. It is a later layer, after a measure of the runs that a machine of a day of work has left.
- **A 1 GiB run on a small machine.** A machine of 1 GiB has no free aligned 1 GiB run after the kernel. A 1 GiB run exists on a machine of 8 GiB or more, at its start, for the first large commits. With no compaction, the chance of a 1 GiB run falls with uptime. A plan can give a budget its runs at its creation (section 9, question 3).

### 4.9 When no run is free

The commit gives single frames. The mapping uses 4 KiB entries in that range. No status says it to the code of the process.

The reasons:

- **The code of the module stays one path.** With a status "no run", each caller of a commit writes a second path, retries with smaller steps, and chooses between a refusal and a slower memory. A page size changes the speed, never the result, so it is not a result of the call.
- **The behaviour stays visible.** `Process_Mapping` gives, for each mapping, the count of its 4 KiB, 2 MiB and 1 GiB entries. `System_Report` gives the count of aligned commits that got single frames, and the free runs of each size. The measure of a process that depends on large pages (the guest `linux`, `address_space`) reads the counts and prints them.
- **A refusal is a memory-pressure channel**: a process learns from a status that other processes fragmented the memory. The counts of `Process_Mapping` give the same fact (section 4.13, the subtle points). A refusal gives it at a call, and a call can be timed in a loop.

### 4.10 The features that work per 4 KiB

| Feature | Today | With runs |
|---|---|---|
| `No_Access` marks, a protection change of a part (`Memory_Protect`) | refused on a large mapping; per slot elsewhere | per slot; the range demotes |
| Decommit of a part | refused on a large object | the range demotes; the decommitted frames return to the stack of the processor as single frames; the run is broken |
| Record and replay: point copies and the diffs of a snapshot | per 4 KiB page of an object | the start of a recording demotes each mapping of the process, and no range promotes while it records: a dirty bit of a 2 MiB entry would make each snapshot diff 2 MiB |
| The IOMMU windows of a device | 4 KiB entries in the tables of the domain | unchanged: the tables of a domain are not the tables of the process |
| `Memory_Read` and its check of each page | `region_frame` per 4 KiB slot | unchanged: the slots stay per 4 KiB |
| The word table of a wait, keyed by the frame | `word_table.word_physical` gives the 4 KiB frame of a word, also in a large page | unchanged: the key is the 4 KiB frame inside the run |
| The guest: the nested page table of its process | 4 KiB, or 2 MiB for a large object | the same promotion; the guest `linux` gets its 128 MiB in 2 MiB entries when runs are free |
| The fault ring | per 4 KiB | unchanged: a promoted range has no fault |

### 4.11 1 GiB pages, and their zeroing

- A 1 GiB page is a promotion of 512 promoted 2 MiB ranges of one run of 1 GiB that a commit took whole. No path zeroes 1 GiB at once: the 2 MiB ranges are zeroed as the 2 MiB runs are (from the pool, by the idle processors in place, or per 4 KiB at first use), and the promotion to 1 GiB follows the last one.
- The zeroing of 1 GiB is 50 to 100 ms of one processor at 10 to 20 GB/s (an estimate). The design keeps it off every critical path: no kernel section zeroes more than 64 KiB with interrupts off.
- The kernel enables 1 GiB entries only when CPUID gives `pdpe1gb`. Under QEMU, the processor of the machine tests needs it (`-cpu host`).

### 4.12 ARM64, for later

The port of ARM64 is not started. The model holds there with no change of its concepts:

- With the 4 KiB granule, a level 2 block is 2 MiB and a level 1 block is 1 GiB, as on x86-64.
- The contiguous hint marks 16 adjacent entries that map one aligned run: 64 KiB at level 3, 32 MiB at level 2. It is one more size of run in the same rule: 16 slots with frames of one aligned run and one state get the hint.
- The 16 KiB and 64 KiB granules change the size of a page, not the model; the system keeps 4 KiB (property 13: one layout on all machines).
- A change of the size of a live mapping needs the "break-before-make" sequence of ARM64: the entry becomes invalid, the TLB is invalidated, then the new entry is written. The demotion and the promotion of section 4.5 already write in that order.

### 4.13 The subtle points

- **The contiguity is a shared fact of the machine.** A process that reads its counts of large entries, or times its reads, learns whether the memory is fragmented, and the fragmentation depends on other processes. This is a covert channel of a low rate (the fragmentation changes slowly, and the sender must free and take runs). It is of the class of line 17 of property 20: reduced, not solved. A budget with runs of its own at its creation removes it for that budget (question 3).
- **The zero pool is a shared fact too.** A process that empties the pool makes the next prefault of another process zero inline: a timing channel of the same class. The pool target is for each processor, so the channel stays inside the processors that two processes share.
- **A promotion can race a fault on another processor.** The promotion holds the process lock, as each writer of the entries does (`docs/ARCHITECTURE.md`, "Rules that keep each path correct"); a thread that faults in the range waits for that lock and finds the entry present.
- **The first use of a slot of a reserved run** takes the frame at its fixed offset, not a frame of the stack of the processor. The run is held for the object from the commit: its frames are out of the free count, as reserved pages are, so the invariant of the frames holds.
- **A decommit of a whole run** returns a run, not 512 single frames: a decommit of an aligned 2 MiB of a promoted range gives the run back whole, dirty.
- **The frame list of 1 GiB is 2 MiB**, paid by the budget, as today: an object of 1 GiB that is promoted to one entry still pays 513 pages of slots and 513 pages of tables. That is the price of one model of features for each page size.

## 5. The forms refused

| Form | Why refused |
|---|---|
| The working memory in the source, as today | It is the one guess of the developer that no tool checks, and it mixes three things: fixed tables (a fact), tables sized from the machine (policy), and arenas (growth) |
| A floor measured on a run | A run gives one scenario, not the need of the start. The check of section 4.2 reads it, and says when the floor is wrong; it does not write it |
| The tool counts the memory objects of constant size that the code creates | The tool then finds calls in the tree and evaluates their arguments: a second evaluator of Odin. The objects of constant size become variables of the package, or the stated part `start_objects_pages` |
| A size in the module file, beside the floor | The size spends a resource of the machine: the plan decides it. A module that states it is the request of today again |
| Overcommit with a floor as the protection (`memory.min`) | A fault can fail, and a process sees the pressure of another: the noisy neighbour and the covert channel that the reservation removes |
| A table of exceptions in the code of the root service | A new large program needs a change of the code. A row of the plan gives the same value, with its reason, and the principal sees it |
| A flag `Large_Pages` with a contiguous object | Two mechanisms for one memory (property 22), and each feature per 4 KiB is refused on it. The run of slots keeps one object model |
| A privilege for large pages or for a prefault | The budget reserves each page; a large page holds no frame that its budget did not pay. The privilege of Windows exists for its page file, which this system does not have |
| A refusal of a commit when no run is free | A second path in each caller, and a status that tells the pressure of the machine (section 4.9) |
| A silent fallback with no count | The speed of a process changes with no fact that a reader can find |
| A frame list per 2 MiB for a run | Each feature per 4 KiB (marks, decommit, words, `Memory_Read`, the point copies) needs a slot per 4 KiB; a second form of the list doubles each path |
| A demotion that takes a table frame when it happens | A protection change or a decommit then fails when no frame is free, a failure that no budget names. The table is paid at the map |
| A prefault that the kernel decides from the floor | The kernel reads no module file and makes no object for a process |
| A prefault of the whole floor with no rule | A table of 1023 places that the process uses for 30 is zeroed for nothing; the rule takes the objects that the process writes whole |
| A zero pool with no target | An idle machine zeroes all its free memory, and on a guest makes the host back all of it |
| Zeroing a run of 2 MiB or 1 GiB in one kernel section | 100 µs to 100 ms with interrupts off |
| Compaction in the first layers | It moves frames of processes, and a frame that a device holds cannot move; its value waits for a measure of the runs left after a day of work |
| A hugetlbfs-like pool that a principal sets for the machine | A pool for the machine is a second payer beside the budgets. A run that a budget holds is the same idea, paid by the budget that uses it (question 3) |

## 6. The migration of each part

| Part today | Becomes |
|---|---|
| `Budget_Request` (the table `Budget`): pages, processes, threads, screen pictures, wiring pages | `Floor` (the table `Floor`): pages (counted), processes, threads, screen pictures. The record has no wiring part; the format allows a new table, which an older reader ignores |
| `Stated_Budget.working_memory_pages` | removed. Fixed tables become variables of the package; constant objects go to `start_objects_pages`; the rest is growth |
| `LEAST_BUDGET` (2048, 1, 1) | the floor of a module file with no table `Floor` (a module of another project built by an older tool); every module of the system has a table |
| `system.budget_decide` | `system.budget_size`: `clamp(policy size, floor, ceiling)`, and a refusal when the floor is above the ceiling |
| `module.LARGEST_BUDGET`, the share of a quarter, `budget_share_take` (integration) | the default ceiling; the share is a value of the plan of principal 0, as designed; `budget_share_take` stays its border |
| `budget_exceptions`: `address_space`, `linux` pages (`master`; removed by the share on integration) | rows of the default plan when the share does not hold them; none on a machine of 1 GiB with the share |
| `processor_exceptions`: `limits` | a row of the plan of the test machine: `processor` |
| `log_records_exceptions`: `limits`, `log_flood` | rows of the plan of the test machine: `log_records` |
| `PROCESSOR_OF_A_THREAD` | the default rule of `processor` |
| `plan_screen_rows` (integration, empty) | rows of the plan: a lower ceiling of the screen pages of a module, as designed |
| `screen_pictures` | a part of the floor; the starter computes its pages from the screen of the machine at the start |
| `Screen_Budget` and `screen_budgets` (integration) | the pair rule of the compositor and the remote display on top of `Budget_Grow`; the ceiling of each side is a plan value |
| `wiring_pages` stated by a module; 0 gives half of the pages (integration) | the wirings of a start list stay counted by the tool in the floor of the start policy; the wiring budget of a module is a child budget that it carves from its size at its first wiring, of the size that the plan gives, by default half of the growth part |
| `SPACE_AUDIT_PAGES` for each audited wiring row, added by the root service (integration) | a size rule of the role of the collector in the default plan: the floor of the collector plus the pages of each audit that the plan declares. The plan holds the audits and their cost in one place |
| `disk_process.PROCESSES_BUDGET` and `LARGEST_BUDGET` | the size and the ceiling of the class of the disk processes, values of the plan of the principal, with these defaults, as `module_budget_request.md` already designs |
| The fixed amounts of `scheduler`, `rings`, the console sandboxes | each applies `system.budget_size` with the floor of the file of its child and its own default rule |
| `Frames_Now` | the flag of the prefault, taken in one batch from runs and the zero pool |
| `Large_Pages` | removed: the kernel gives a run to each committed aligned range |
| `Contiguous` | kept, for the memory of a device |
| The arena step of 16 pages that doubles to 512 | unchanged; a step of 512 pages is aligned on a multiple of 512 pages in the object, so it can take a run |

## 7. Against the properties

- **Property 1** (counted interface): no new operation. `Memory_Create` loses `Large_Pages`; `Memory_Map` writes the entries of present pages; `Process_Mapping` and `System_Report` gain counts. `Budget_Grow` is a command of the root ring, not of the kernel.
- **Property 11, 12**: the floor is a table of the module file, signed with it.
- **Property 13**: the zero pool and the count of each block are per processor or under the frame lock; no fast path gains a shared write.
- **Property 14**: the caller still pays each page; the promotion commits nothing ("a commit that the kernel makes on a fault" stays forbidden: the first use of a slot of a run fills a page that a commit paid). The pool holds free frames, which no process fills.
- **Property 20, line 16**: each resource stays a budget with a limit; line 17: the contiguity and the zero pool are two shared facts of a low rate, reduced (section 4.13).
- **Property 21**: the size and the ceiling are machine policy, in the plan of principal 0; the class of the disk processes in the plan of a principal.
- **Property 22**: one mechanism for the size (the plan row), one for the growth (`Budget_Grow`), one for the page size (the run). The table of exceptions, the special rows and the flag `Large_Pages` go.

One phrase of the direction needs a correction: "the kernel can commit and map the floor's frames at process creation". The kernel reads no module file and makes no object for a process, so the floor reaches the kernel as a flag of each object, set by the library that makes it (section 4.6).

## 8. The order of the work, in layers

Each layer adds one capability to a system that works.

1. **Measure.** Record in the measure of each build: the first use of a page and `Frames_Now` of 8192 pages (`frames`), the first frame of a window at 1080p and 4K, the commit and use of an arena. No design change.
2. **The floor.** The table `Floor` and `system.budget_size`; the tool counts the zero part of the module; `start_objects_pages` replaces the working memory; the fixed tables move to variables of the package, module by module; the starter refuses a floor above the ceiling; the fact of a floor used past its amount at the first state of work. The default size `floor + max(floor, 2048)`.
3. **The size as policy.** The rows of the plan (`pages`, `ceiling_pages`, `processor`, `log_records`) in the plan of principal 0, and their default plan in the signed image; the tables of exceptions and the constants of the disk processes become rows; the other starters apply the same rule.
4. **The map writes present entries; `Frames_Now` in one batch.** `display.open` and the rings prefault. Measure the first frame again.
5. **Runs of 2 MiB.** The commit of an aligned range takes a run; promotion and demotion; the tables paid at the map; the alignment of a chosen address with the offset in the object (`chosen_address` aligns a mapping of 2 MiB or more); the counts of `Process_Mapping` and `System_Report`; the removal of `Large_Pages`; the placement of single frames in broken blocks.
6. **The zero pool.** `frame_zero_bits`, the zeroing of the idle processors with `movnti` in steps of 64 KiB, the target, the zeroing in place of reserved runs.
7. **1 GiB.** The promotion of 512 ranges; the CPUID gate.
8. **`Budget_Grow`.** The command of the root ring and its plan rows; `Screen_Budget` on top of it.

Later: compaction, after a measure of the runs left after a day of work; the sizes of ARM64 with the port.

**The test that breaks the design on its first day** (layer 5): a process commits one aligned 2 MiB, writes one word in each 4 KiB page so the range promotes, and checks with `Process_Mapping` that it has one 2 MiB entry. A second thread on another processor reads the range in a loop. The first thread then, in one batch: waits with a deadline on a word of page 7, marks page 100 `No_Access`, and decommits page 300. The test checks: the budget did not change by more than the one decommitted page (the demotion took no frame); a read of page 100 is a fault in the fault ring; page 300 reads zero after a commit; a write to page 7 by the reader thread wakes the wait (the key of the word survived the demotion); the reader thread never read a stale value. Then the case `frames` empties the free runs with single frames and commits an aligned 2 MiB: the commit succeeds with 4 KiB entries, and the count of the fallback in `System_Report` grows by one.

## 9. The questions for the owner

1. **The default size of a budget with no row of the plan.** The proposal is `floor + max(floor, 2048)` pages, up to the ceiling. The other forms: the floor alone (each growth needs a row or `Budget_Grow`), or the ceiling (each process gets a quarter of the machine, and the sum of a few processes holds the machine).
2. **A hint of the usual size in the module file.** A browser needs much more than its floor to be useful, and with no row of the plan it gets the default. The proposal is no hint: the default plan of the signed image holds rows for the modules of the system, and the principal sets a row for a module of another project. The other form: a field of the floor table, `usual_pages`, that the default rule reads and the plan overrides.
3. **The runs of a budget.** The proposal is that the contiguity stays shared, with its low-rate channel (section 4.13). The other form: a row of the plan gives a budget a count of 2 MiB or 1 GiB runs, which the root service takes at the creation of that budget (at the start of the machine for a service of the image) and which only that budget uses. It gives the guest `linux` and a large program their large pages for certain, and removes the channel for them, at the cost of runs that no other process can use while that budget lives.
4. **The zero pool on a guest machine.** The proposal is the same target on a guest (2 runs for each processor, at most 1/64 of the memory), which makes the host back at most that memory. The other form: no pool when the kernel finds a hypervisor, so a guest never zeroes ahead.

## 10. The decisions

The critique ([`budgets_as_policy_critique.md`](budgets_as_policy_critique.md)) read this study against the code. The owner accepted each recommendation of its section 13, with two changes: the 1 GiB pages are built with the 2 MiB runs, and the default size is `2 × floor`. This section records the result. Where it differs from sections 4 to 9 above, this section holds. The intents are [`module_budget_request.md`](../../src/md/features/module_budget_request.md), for the budgets, and [`frames_of_a_process.md`](../../src/md/features/frames_of_a_process.md), for the frames, both Proposed.

### 10.1 The answers

| Question of the critique | Decision | What changes in this study |
|---|---|---|
| 1. A growth extends an arena, or is a second budget | A second budget with its own life (form B). No new kernel operation; the pages return at its close | Section 4.4: `Budget_Grow` gives a new budget handle; a growth never extends an object that exists |
| 2. The pages between the size and the ceiling are not reserved | Accepted, and written in the intent, with one decision in each period, a refusal with no amount, the log facts, and an optional reserve of a row | "The reservation stays" holds for the size only |
| 3. The default size | **Changed**: `2 × floor`, after the floors of the start list are reserved (section 10.2) | Section 4.3 |
| 4. A hint of the usual size | No | — |
| 5. The frames, a design of their own | Yes: `frames_of_a_process.md`. The floor and the policy are built first, with no change of the memory paths of the kernel but one word of a budget | Sections 4.5 to 4.12 move there |
| 6. A run at a commit with frames now | Yes. A page on first use never takes a run; no late promotion; one bit `SLOT_RUN` | Section 4.5: the promotion of FreeBSD is refused |
| 7. The contiguity | Shared, with a run quota for each budget; runs that a row reserves for one budget are later | Section 4.13: the channel is bounded in size, not slow |
| 8. The zero pool | Not built in the first layers, on any machine. When a measure asks for it: a rate bound, `sfence` after `movnti`, the bit that `frames_take` clears, a whole-run check in the test build, a plan value to turn it off on a guest | Section 4.7 |
| 9. 1 GiB entries | **Changed**: built in the same layer as the 2 MiB runs (section 10.2) | Section 4.11 |

The other recommendations of the critique are taken with them: the floor counted whole (load pages, start objects as lists of named constants in the module and its packages, floors of named children), the floor of a start, the sum of the floors first and its check against the least machine at the build, the peak of a budget and its machine test, rows keyed by name for the image and by hash or class for a disk process, a plan file of the test image, a file with no table `Floor` refused, the prefault as a flag of `Memory_Commit`, the map that writes present entries under the rule of `page_give`, `Contiguous` for each object that the kernel or a device reads by its physical address, the bounded steps of a demotion at the start of a recording, no large entry for a recorded process or for a guest, the files with a system suffix for the software processor, and the removal of `Large_Pages` as the last step of the layer of the runs.

### 10.2 The two changes

**1 GiB in the same layer as 2 MiB.** A 1 GiB page is one more level of the same run, with the same rules:

- **Decided at a commit with frames now** of an aligned whole 1 GiB range of an object, on a processor with `pdpe1gb`. The commit takes the largest free run that fits: a free aligned 1 GiB, else 2 MiB runs, else single frames. No compaction. Each fallback is counted by size in `System_Report` and seen by size in `Process_Mapping`.
- **A run quota for each budget**, for each size: a budget takes a 1 GiB run only while its count of 1 GiB runs is below its pages divided by 262 144.
- **Demotion on a change of a part**: the 1 GiB entry becomes 512 entries of 2 MiB, and the 2 MiB range of the change becomes 512 entries of 4 KiB. The map pays the directory and the tables, so no demotion takes a frame.
- **Zeroed in bounded sections of the caller's time.** The commit pays and takes the run at once, then zeroes it in steps; between steps the processor takes its interrupts, and a thread whose slice is over yields with the step of its command in its thread record. The slots of a step are written after its zeroing. A stop during the command returns the frames of the steps left. 1 GiB is 262 144 pages, four times `RANGE_TABLE_PAGE_LIMIT`, so the resumable command is needed for this size in any form.
- **The new work of 1 GiB**: a third size in `page_entry`, the unmap, the reports and `word_physical` (with its host test), and the written interleavings of the resumable commit.
- **The test** runs on a QEMU machine of 4 GiB or more, with `pdpe1gb`: a machine of 1 GiB has no free aligned 1 GiB after the kernel. Its cases, edges first: a budget one page below 262 144 takes no 1 GiB run and gets 2 MiB runs; a commit with no free aligned 1 GiB gets 2 MiB runs and the count of the fallback grows by one; a commit that gets one 1 GiB entry, during which a thread of the same processor with a higher weight runs between two steps (checked by order, never by a time); a mark of one page that demotes with no change of the budget, then a read of that page that is a fault and a read of a page of another 2 MiB that is not; a stop of the process during the command, after which its budget and the free frames are as before.

**The default size is `2 × floor`.** No constant of 2048 pages. The process can double its start memory before it needs a growth or a row of the plan, so the default follows the real need of the module. The factor is a value of the plan of principal 0, `default_growth_factor`, with 2 as its default and this reason beside it. A module with a floor of 1000 pages gets 2000; with 40 000, it gets 80 000, up to the share of the machine.

### 10.3 The constants

Each amount of the study, of the critique and of the code that they name, and its decision. "Fact" names the fact that the amount follows from; "measure" names the measure that sets it; "plan value" gives the default and its reason.

| Constant | Where | Decision |
|---|---|---|
| `max(floor, 2048)` of the default growth | study 4.3, critique 11 | removed; plan value `default_growth_factor`, default 2: a process can double its start memory |
| `LEAST_BUDGET` 2048 pages, 1 process, 1 thread | `root/budgets.odin` | removed: a file with no table `Floor` is refused |
| The rounding of a size to 512 pages | critique 2 and 11 | fact: `LIST_ENTRIES`, the slots of one page of a frame list (4096 / 8); an arena pays one page for each 512 |
| The arena reservation rounded to 512 | `arena_reservation_pages` | the same fact |
| 512 and 262 144 pages of a run | study 4.5 | fact of the hardware: the entries of one page table, at one and two levels |
| 72 pages of the first thread, 19 of another | `budget_count.odin` | fact: the sum of `op.STACK_PAGES`, `op.THREAD_STACK_PAGES`, `op.THREAD_AREA_PAGES`, `op.OWN_LOG_PAGES` and the context page, constants of the contract with their reasons there; a thread with another stack is counted from the constant that its source names |
| The top 16 pages of a stack prefaulted | study 4.6 | removed: a stack stays on first use until the measure of the first layer gives the pages that a start touches |
| The share of a quarter (`LARGEST_BUDGET_SHARE_DEFAULT`) | integration | plan value, default 1/4: the largest process leaves three quarters to the others |
| The border of the share, 1 to 64 | integration | fact: the border refuses a share above the whole machine, and a share whose ceiling is below the largest floor of the start list |
| `LARGEST_BUDGET_LEAST`: 16 384 pages, 32 threads | integration | fact: the default share of the least machine of the system |
| A share row in parts of 1024 | critique 2 | removed: a share is a fraction of two integers |
| The least machine: 1 GiB and the reference screen | critique 2, `TEST_MACHINE_MEMORY_MIB` | fact: the least machine that the system supports, stated once in the contract |
| One decision of `Budget_Grow` in each second | critique 6.4 | plan value, default one second: it bounds the channel of the refusals to about one bit in a second, the rate of `Screen_Budget` today |
| `REFUSED_LINES_PER_SECOND` 4 | `screen_budgets.odin` | removed: one decision in each period for each process bounds its refused lines to one in a period |
| The growth reserve of a row | critique 6.4 | plan value, default 0: a reserve holds pages that no other process can use, so only a row that handles secrets asks for it |
| The run quota: pages divided by 512 | critique 8.2 | fact: the pages of a run of each size, so a budget breaks at most the contiguity that its pages are worth |
| One run in each section of the frame lock | critique 7 | fact: the size of a run |
| The pages of one command | critique 7 | fact: `RANGE_TABLE_PAGE_LIMIT`, the bound of a walk with interrupts off; the measure of the longest kernel section in the first layer checks it |
| The zeroing step: 64 KiB (study), 2 MiB (owner) | study 4.7, 10.2 | measure: the largest power of two of bytes, at most 2 MiB, whose zeroing fits in the longest kernel section that the first layer measures |
| The pool target: 2 runs for each processor, 1/64 of memory; the rate of refill | study 4.7, critique 9 | not built; when a measure asks for the pool, plan values whose defaults come from that measure |
| 4 bytes of owner for each block, a `u16` count for each 2 MiB, one zero bit for each frame | study 4.7, 4.8, critique 8.2 | facts: sizes that follow from the frame table |
| The margin of a floor above its peak | critique 3 | removed: a peak above the floor fails the test; the difference is a measure of each build, not a test |
| The budget of the disk processes: 32 768 pages | `disk_process/budget.odin` | fact: two disk processes at the least ceiling of the machine |
| The largest of one disk process: half of those pages | same | fact: the least ceiling |
| 4 disk processes at one time | same | plan value of the principal, default 4: the processes of the image keep the other slots |
| 4 threads for a disk process; 16 for the class | same | plan value, default 4: at most 4 processors of time for one file; 16 is 4 × 4 |
| Two processors of time for the class | same | plan value, default the share of the processors of the machine, a quarter, the rule of the ceiling |
| One processor for each thread (`PROCESSOR_OF_A_THREAD`) | `root/budgets.odin` | fact: a thread runs on one processor at a time |
| 1000 log records of a process (`LOG_RECORDS_OF_A_PROCESS`) | `op` | fact: the records of the machine divided by its process slots and the root service, so the sum fits |
| `limits`: 1.5 processors, 40 log records; `log_flood`: 0 | `root/budgets.odin` | facts of three test cases, with their reasons, in the plan file of the test image |
| `SCREEN_PICTURES_LIMIT` 4 | integration | fact: the largest count of the roles that hold screen pictures, 3 for the remote display; 4 names no holder, so it becomes 3 |
| `SPACE_AUDIT_PAGES` of an audit | integration | fact: the pages of one space window and its ring, priced by the contract |
| The wiring pages: half of the pages, then half of the growth | integration, study 6 | removed: the wiring budget is priced by the plan from its rows; a module that wires at run time asks a growth |
| The arena step: 16 pages, doubled up to 512 | `memory_without_a_bound.md` | 512 is a fact, the run; 16 stays the open decision of that file, which a measure of a large page of the web decides |
| `FRAME_CACHE_CAPACITY` 256 | `processor.odin` | measure, already chosen by one |
| The machine of 4 GiB of the 1 GiB test | owner | fact: a free aligned 1 GiB after the kernel and the hole of the devices |

### 10.4 The order of the work

1. **Measure.** The first use of a page, `Frames_Now`, the first frame at 1080p and 4K, the arena, the longest kernel section, and one run on a real machine for the large pages.
2. **The peak of a budget and its check** at the first state of work, on the request of today. It gives the true need of each module.
3. **The counted floor.** `load_pages`, the lists of start objects, the children by name, the table `Floor`; the working memory leaves module by module, each checked by step 2.
4. **The sum and the size.** The floors of the start list first, the check of the least machine at the build, `system.budget_size`, `2 × floor`, the refusal of a floor that cannot be paid.
5. **The rows of the plan.** `pages`, `share`, `processor`, `log_records`, `default_growth_factor`; the class of the disk processes; the plan file of the test image; the tables of exceptions leave.
6. **The map writes present entries; the prefault of a range**, if step 1 shows the gain. An independent review.
7. **`Budget_Grow`**, with its row, its period, its facts, `ceiling`; `Screen_Budget` on it.
8. **The runs of 2 MiB and 1 GiB** at a commit with frames now, the resumable zeroing, the demotion, the quota, the placement of single frames, the counts, the new interleavings in `docs/ARCHITECTURE.md`, the test machine of 4 GiB; then the removal of `Large_Pages`. After the measure on a real machine. An independent review.
9. **Later, each behind its measure:** the zero pool, large entries for a guest, runs that a row reserves for one budget, compaction, the sizes of ARM64 with its port.

The test that breaks the budgets on their first day is the one of the critique, section 12. The test that breaks the runs on their first day is the one of section 8 above, with the loop of the critique, section 8.2, which stops at the quota, and the cases of 1 GiB of section 10.2.

## Appendix: the intent before this study

The text of `src/md/features/module_budget_request.md` on `master` before this study, with its headings one level lower. The branch of integration changes it in three places: the wiring pages, the largest budget as a share of the machine, and the budget of the disk processes of 32 768 pages (section 2.1).

### The budget that a module asks for

#### Purpose

A process runs inside a budget: pages of memory, processes, threads, processor time and log records. The starter of the process pays that budget from its own. This file records who states the amounts, and who decides them.

The guide of the budgets is [`docs/ARCHITECTURE.md`](../ARCHITECTURE.md), "K1. Handle table". The guide of the table is [`docs/MODULE_CONTRACT.md`](../MODULE_CONTRACT.md), "The budget that a module asks for".

#### Constraints

- **A process never grants itself anything.** The budget of a process is a part of the budget of its starter. A number that the file of a module states is a request, never a grant.
- **A module of another project runs.** Its developer changes no source of the system: no table of the root service can name it.
- **An amount that is too small shows only when the process runs.** The process does not start, or it stops at its first window. A fixed table of amounts in the starter gave three such faults in one day: a second picture for each window, a process that gained four children, a child with eight threads.
- **The kernel and the loaders read the file of a module.** The format gains fields only at the end of a record, or a table that an older reader ignores.

#### The chosen form

**The request is a table of the module file.** The table `Budget` holds one record, `module.Budget_Request`: the pages, the processes and the threads that the module asks for. A module with no such table asks for the least budget. A part that is 0 asks for the least budget of that part, so a record of an older, shorter size reads its missing parts as the least.

**The source states only what the tool cannot count.** The source states a stated budget: one constant of the type `system.Stated_Budget`. Its parts are the working memory, the processes, the threads and the size of the window. The tool counts the other pages, and writes the sum in the table. The form is:

```odin
// Its loop, the thread that makes the lists of the palette, and the
// tables of its surfaces.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 3799, threads = 2}

// A process with a window names the constants of its size.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 2536, window_width = WIDTH, window_height = HEIGHT}
```

The step that describes the exports reads it from the tree of the parser, as it reads an export, and the conversion adds the counted parts and writes the table. The reasons of this form:

- **The compiler checks the names.** The constant has the type of the record, so a field with a wrong name stops the compile. The tool reads only integer literals: the number in the file is the number in the source, with no evaluation.
- **The source and the table are two records.** `system.Stated_Budget` exists only in a source; `module.Budget_Request` exists only in a file. A field `pages` that meant the working memory in a source and the whole pages in a file would be one name for two concepts.
- **No new import.** Each module imports `modus:system`. A module of another project states it the same way.
- **The comment before the constant gives the reasons of the working memory.** The tool refuses the constant with no comment. The site shows the comment beside the parts on the page of the module.
- **No silent least budget.** A declaration named `MODULE_BUDGET` that the tool would not read is an error of the tool: inside a `when` (the tool reads the source with no setting of the build, and cannot know the branch that the compiler takes), or with other names in one declaration. A refused form says why in its message.
- **The forms of Odin that hold the same value are taken.** The type can be on the declaration, `MODULE_BUDGET : system.Stated_Budget : {...}`, and a part can be written with the prefix `0x`, `0o` or `0b` and with `_` between its digits.

**The tool counts three parts.** Each one is a fact of the build, not a choice of the developer. The request is the sum: `pages = working memory + module pages + thread pages + window pages`. The processes and the threads go to the table as the source states them.

- **The module pages.** The memory size of the module, from the header of the file that the conversion writes, and the memory size of each module that it imports, at each level, each module one time, from their files. The conversion reads the file of each import already, for its hash. This is what a load pays when the process has its own copy of each module. A starter that shares the code of a module pays less, and the difference stays free in the budget of the process: an amount above the need, never below it.
- **The thread pages.** The first thread: its stack (`op.STACK_PAGES`), the page of the context, its thread area, and the own log ring of the process (`op.OWN_LOG_PAGES`), which the kernel takes from the budget at `Process_Create`. The ring is counted here because a process does not choose it: a source that stated it in its working memory would break at the next change of its size. Each other thread that the source states: a stack of `op.THREAD_STACK_PAGES`, the stack that `system.thread_start` makes when its caller gives no count, and its thread area. A thread area is the pages that the kernel pays from the budget: the thread record and the kernel ring (`op.THREAD_AREA_PAGES` minus the guard page, which has no memory). With no part `threads`, the tool counts the first thread.
- **The window pages.** The two pictures of the window, as `display.open` makes them: the width times the height times the 4 bytes of a pixel, times 2, in whole pages. The width and the height are pixels of the screen at the largest scale. For a resizable window whose least size fits the logical screen at that scale, each is cut to the reference screen: the fit of the compositor keeps its surface within the screen ([desktop_to_browser.md](../../src/md/features/desktop_to_browser.md), "The budgets"). The parts `window_least_width` and `window_least_height` state that least size: each names the constant that the source passes to `display.resizable_set`, and the describe step checks the names against each call of `resizable_set` in the package. A number there would be a second copy of the least size that the tool cannot compare with the call. The manifest of a module from outside the system has no least parts: its window is counted with no cut. The parts `window_width` and `window_height` each name a constant of the package whose value is one integer literal, or are an integer literal. The process passes the same constants to `display.open`, so the counted pictures are the pictures that it opens. A size that the source computes (`WIDTH :: BAR_X + BAR_WIDTH + 64`) is written as a literal, with `#assert` of the expression beside it: the compiler checks the number, and the tool still evaluates nothing.

What stays in the working memory: what the process chooses (a table, a cache, a region of large pages, the call regions of its connections), the budgets of its children, a stack that a thread asks for with another count, the page tables of its address space, and the 4 pages of its own log ring ([own_log_ring.md](../../src/md/features/own_log_ring.md)).

**Where a reader sees the parts.** `modustool test descriptions` computes the request again from the source and the files, compares it with the table, and prints the four parts of each module. The site shows on the page of the module the parts that the source gives: the working memory, the thread pages and the window pages; it builds no module, so it names the module pages as counted from the files of the build. The measure of each build has one line with the request of each module that has a table, so that a reader sees an amount change when a module grows.

**The starter decides.** `system.budget_decide` is the rule, and each starter can use it. For each part:

- a part that is 0 takes the part of the least budget;
- the starter accepts the part when it is not above its largest budget for one process;
- it limits a part above that: the process gets the largest budget of that part, and one line of the log says so.

The root service keeps a table of budget exceptions (`budget_exceptions` in `src/modules/system/root/budgets.odin`). A row names one module of the boot image, gives it another largest budget for a part, or other limits of processor time and of log records, and has the reason beside it. A row that is larger widens, a row that is smaller limits. A row is the exception, not the normal case: two rows exist, `address_space` (64 MiB of large pages and two ranges of 1 GiB) and `limits` (small time limits that its cases reach).

**A disk process is paid by one budget of its own.** A disk process and a module of another project (which runs as a disk process) are files that a principal chose, not modules of the system. The root service makes one budget for all of them, from its own, at the first disk process, and keeps it (`disk_process.PROCESSES_BUDGET`): 16384 pages, 4 processes, 16 threads, two processors of time and 4000 log records in each second, 1000 for each of its processes: a budget gives a child a part of its log records, as of its pages ([log_side_channels.md](../../src/md/features/log_side_channels.md)). One disk process gets its request up to a largest budget of its own (`disk_process.LARGEST_BUDGET`): 8192 pages, one process, 4 threads. The reasons of the amounts:

- `budget_create` moves the processes and the threads out of the budget of the root service at the start, whatever the process does with them. With the largest budget of the boot image, eight hostile files of 8 processes and 32 threads each took the process and thread slots that a driver, the terminal or a service needs to start again. The one budget bounds the sum of all disk processes, whatever their count and their files: the processes of the boot image keep 59 of the 63 processes and 239 of the 255 threads.
- A disk process holds no grant that starts a process, so one process slot loses nothing, and with it the process creates no child.
- 4 threads give 4 processors of time at most to one process; the one budget gives two to all of them together.
- 8192 pages hold the two pictures of a window of about 1000 x 704 and a working memory; it is half of the one budget, so two of the largest run at one time, and more of a smaller request.
- The pages of the one budget leave the root service at the first disk process, and return to it never: a machine that starts no disk process keeps them.

A part above the largest budget of a disk process starts the process with that part, and the log says so. The name of a disk process never selects a row: a name gives nothing.

**The policy of the principal.** A disk process gets its store of its nickname, and the size of that store is a line of the budget that the module asks for; the principal sets the policy that accepts, limits or widens it ([processes_from_a_disk.md](../../src/md/features/processes_from_a_disk.md)). This form is the place of that policy: the request gains the part of the store at the end of its record, as the format allows; the one budget of the disk processes and their largest budget are the two amounts that the policy of the principal sets, in place of the constants of today; and the rule `system.budget_decide` stays the one rule. The principal then decides the share of the machine that the files of a principal take, and a file never decides it.

**A refusal names the amount.** When a start fails for the budget, the line of the log gives what the process was to get and what the budget that pays holds (the budget of the root service, or the one budget of the disk processes), and names the first part that is short. When the budget of the starter holds the request, the request itself was too small for the load, and the line says that.

#### The refused forms

- **The flat table of the starter**, one case with fixed amounts for each process. It was the first form. Each new process changed the root service, and each amount was a guess that nobody checked.
- **A budget that the module file grants.** The file is data of a third party. A starter that gives what a file asks, with no limit, lets any process take the memory of the machine.
- **A request in a file beside the module** (the module build file of a module of another project). The request then is not in the bytes that the hash names, and a starter cannot trust the pair.
- **A request as a call of the process at its start.** The process runs before it has its budget, so the starter must give a first budget by a guess: the same fault, one step later.
- **A measure of a run in place of a request.** A run gives what one scenario used, not what the process needs at its largest.
- **An attribute or a comment in place of a constant.** The compiler checks neither, and a typing fault in a name gives a module that asks for the least budget with no word.
- **An expression in the constant** (`2048 + 1024`). The tool would then compute what the compiler computes, a second evaluator of Odin. The tool computes the counted parts from the facts of the files, and reads a name only for the size of a window, and only a name whose value is one literal.
- **The whole pages in the source, as the first form had them.** Each amount was a guess of the developer: the size of the module, the stacks and the pictures, written once and never checked. A module that grew kept its old amount, and the fault showed only when the process ran.
- **A field `pages` that means the working memory.** One name for two concepts: the same field of the table holds the whole pages.
- **A count of the window from the call of `display.open`.** The tool would find the call in the tree and evaluate its arguments: a second evaluator, and a call in a loop or in another package gives no size. The parts of the stated budget name the constants, and the process passes them.
- **The two pictures at the largest size of the screen for each window.** A fact, but an amount far above the need of a small window: the sum of the processes of the boot image would leave less for the others.
- **A count for a module with no constant.** It states no thread and no working memory, so a count of its module and of one thread would be smaller than the least budget, which it gets today. It keeps the least budget.
- **The parts in the record of the table.** The table would explain itself, but the record would grow for a reader only; a starter decides on the sum. The tool computes the parts again from the source and the files, where a reader needs them.
- **A disk process paid by the budget of the root service, up to the largest budget of the boot image.** Each start moved up to 8 processes and 32 threads out of the budget that the processes of the boot image need, and a few hostile files stopped a restart of a driver. A smaller largest budget alone still has no bound on the sum: the count of disk processes then decides it.
- **Processor time and log records in the request.** They protect the other processes, and the starter owns them: one processor for each thread, and 1000 log records in each second from the budget of the starter.

#### Subtle points

- **The request is a part of what is signed.** The table is in the bytes of the module, so the hash of the module names it, and the system description holds that hash. A new table changed the hash of each module, the kernel too: the directory has one more entry.
- **The kernel reads no request.** The kernel and the boot program check the range of each table of the directory (`module.validate`), the new one too, and read only the header, the segments, the rebases, the imports and the exports. No line of the kernel changed.
- **The counted parts change with a build.** A module that grows changes its request with no edit of its source, and its hash changes. An import that grows changes the request of each importer: the file of the import is an input of the conversion already, so the importer is converted again.
- **A process that starts processes.** Its children are paid from its budget. Its stated threads hold the threads of its children, and the tool counts a stack and a thread area for each, as the children pay them; its working memory holds the rest of the budgets of its children.
- **The window is checked by the compiler, not by the tool.** The tool cannot know that the process passes `WIDTH` to `display.open`. It knows that the counted size is the size of a constant of the process, and the `#assert` of a computed size keeps the literal equal to its expression.
- **A window whose size follows a value** (the terminal: its columns and its rows come from its starter) states no window part. Its pictures stay in its working memory, at its largest size.

#### State

Built: the table `Budget` and its reader; the stated budget of the source, read by the describe step; the three counted parts, added by the conversion, compared again by `modustool test descriptions` and shown with their parts there and on the site; one line of the measure of the build with the request of each module; the rule of the starter, the two exceptions, the least and the largest budget; the one budget of the disk processes and the largest budget of a disk process; the line of a limit and the line of a refusal. The working memory of each process is its old amount minus the counted parts of the build of that day, so no total changed.

Left: the part of the store in the request, and the policy of the principal over the budget of the disk processes. The page tables of the address space are not counted. The starters other than the root service (`scheduler`, `rings`, the console for its sandboxes) still give their children fixed amounts.