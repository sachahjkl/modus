# The floor of a module and the size of its budget

Status: Accepted, built in part: the peak of a budget and its check, the counted floor, the floors of a start list first and the default size. The rows of the plan, `Budget_Grow` and the frames are not built. The study, its prior art and its measures are in [`docs/research/budgets_as_policy_study.md`](../../../docs/research/budgets_as_policy_study.md), the critique in [`docs/research/budgets_as_policy_critique.md`](../../../docs/research/budgets_as_policy_critique.md), and the decisions in the study, section 10. The frames that a process gets for its pages are a separate design: [frames_of_a_process.md](frames_of_a_process.md).

## Purpose

A process runs inside a budget: pages of memory, processes, threads, processor time and log records. Its starter pays that budget from its own. This file records which part of a budget is a fact of the module, which part is a policy of the machine, how a starter divides its pages, and how a process gets more than its size.

The guide of the budgets is [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "K1. Handle table". The rules are [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller", and "20. No ambient access", lines 16 and 17.

## Constraints

- **A process never grants itself anything.** A value in the file of a module is a fact, never a grant.
- **The size of a budget is a reservation.** Each page of the size is held from the start: no fault fails for memory, and no process sees the pressure of another inside its size.
- **A module of another project runs.** No table of the code of the root service names it.
- **A number that a developer guesses is wrong on some day.** The working memory of today mixes fixed tables, tables sized from the machine and data that grows.
- **The size spends a resource of the machine.** The principal who owns the machine decides it, not the file of a module.
- **No bare constant.** Each amount follows from a measured or stated fact, or is a plan value with a default and its reason (the list is in the study, section 10.3).
- **The kernel reads no module file.** It has `Budget_Create` and `Budget_Read`, and no operation adds pages to a budget that lives.

## The chosen form

**Two records with two owners.**

- **The floor** is the table `Floor` of the module file: what the process needs to reach its first state of work. The module and the tool own it; the hash of the module names it. A file with no table `Floor` is refused: before 1.0 nothing is kept for an older tool.
- **The budget policy** is a row of the plan. The plan of principal 0 owns the rows of the machine and of the modules of the image; the plan of a principal owns the row of its class of disk processes. A row of a module of the image is keyed by its name, which the signed image fixes; a row of a disk process is keyed by its hash or by its class, never by its name. The signed image holds the default plan. The image of the tests carries its own plan file, which the default image does not have.

**The floor is counted whole.** The hand writes names and counts of slots, never pages. The tool counts:

- the module pages: the module and each import, with their zero part;
- the thread pages, from the stack that each thread states (`op.STACK_PAGES` for the first, `op.THREAD_STACK_PAGES` by default, or the constant that the source passes to `system.thread_start`), its thread area, the context page and the own log ring;
- the window pages: two pictures of the stated window at the largest scale;
- the load pages: the frame lists, the page tables of the mappings and the private copy of the writable data, priced by the cost functions of the contract (`op.memory_cost`, one table for each 2 MiB of a mapping);
- the start objects: a list of named constants in the package of the module (`MODULE_START_OBJECTS :: [?]system.Start_Object{RING_PAGES, LENT_PAGES}`) and in each package compiled into it (`PACKAGE_START_OBJECTS`). Each name is a constant whose value is one integer literal, which the code passes to `memory_create`. The tool prices each object as the kernel charges it: `op.memory_cost` and `op.mapping_table_pages_most`. The list is an array of inferred length, so it has no bound; the type of its elements, `system.Start_Object`, lets the compiler check each name;
- the floors of the children: the modules that the process starts before its first state of work. The module table of the tool names them (`children`), beside the imports: the build converts a child before its parent, as it converts an import first, and the floor of the child is an input of the conversion of the parent. A name in the source as well would be a second copy of the same list.

The load pages are a worst case that the contract prices: the top table and the tables of the time page; for each module, the larger of the frame list of one copy of the module and the frame lists of its segments, and the tables of its mapping at any address; the frame list and the tables of each stack, of the context page and of each picture of the window. Two mappings that share a table cost less, never more.

A module with an entry has a table `Floor` even when its source states nothing: its counted parts, one process and one thread. A library module has none.

A fixed table that every start uses is a variable of the package, so the module pages count it. A table that only some importers use stays an object made at its first use, and is a start object of its package. The source still states `processes`, `threads`, the window size and `screen_pictures`.

**The floor of a start.** The starter adds to the floor of the file what it computes from the plan and the machine: the screen pictures at the screen of the machine, the wiring budget of the rows of the plan, the audit pages of the collector. `system.budget_size` takes that sum, not the number of the file.

**The sum first.** A starter reserves the floors of its whole start list, then divides what is left. A process of the start list is never refused for a size that another process took. The tool adds the floors of the default start list and compares the sum with the least machine of the system (1 GiB, the reference screen); the build fails when the image cannot start there.

The rule of the division (`system.start_list_sizes`) runs once, before the first row starts. The floors come first. Of the pages left, one share of the machine stays with the starter, for itself and for the starts after the list: the most that one later start gets. What remains goes to the growth of each row, its default size less its floor: each gets its whole growth when the sum fits, else the same part of its growth as each other, rounded down to 512 pages and never below its floor. The order of the rows then changes no size. Until a row starts, the starter keeps its floor from every other start, of the list or not. The sum that the tool proves holds the floor of the root service and of the start policy, which start before the rows.

**The size, part by part.**

- **Pages.** A row gives `pages` (a count) or `share` (a fraction of the pages of the starter at its start), never both. With no row, the size is `2 × floor`. The reason: a process can double its start memory before it needs a growth or a row, and its default follows its real need, not a fixed count. The factor is a value of the plan of principal 0, `default_growth_factor`, with 2 as its default. The size is rounded up to a multiple of `LIST_ENTRIES` pages (512): an arena pays one page of frame list for each 512 pages, so a size of another count leaves a last step that never fits.
- **A row below the floor** gives the floor and one log fact with both numbers. **A floor that the starter cannot pay** refuses the start, with one line that names both amounts; no page moves.
- **Processes and threads** are slots: the floor is the amount. A class row bounds them; no row of a disk process raises them.
- **Processor time** is one processor for each thread, a fact: a thread runs on one processor at a time. A row can lower it.
- **Log records** are the records of the machine divided by its process slots and the root service (`LOG_RECORDS_OF_A_PROCESS`), so the sum fits. A row can lower it.

**The ceiling** bounds a growth only, and comes with the growth. It is a share of the machine, a value of the plan of principal 0, with a quarter as its default: the largest process leaves three quarters to the others. The border of the share refuses a share whose ceiling is below the largest floor of the start list. Until the growth exists, the share stays what it is on the branch of integration: the most that a start gets.

**The peak of a budget.** A budget keeps the least count of its free pages since its creation; the kernel writes it where it subtracts pages, under the frame lock that it holds there (`budget_pages_spend`), and `Process_Report` gives it (`budget_least_pages`). At the first state of work of a process, the root service reads it. A process that passed its floor fails the machine test. The difference between the floor and the peak is a measure of each build, followed over the releases, never a test.

**The first state of work** is an act of the process: `system.ready` sends `Root_Command.Ready` on its root ring when its start is done and it waits for its work. The root service reads the peak at the first `Ready` alone, and writes the fact `Budget_Peak_At_Ready` with the peak and the floor of the start; a peak past the floor writes `Budget_Floor_Passed`, and the machine test fails on that line. A `Ready` that runs has no completion, so the sender waits for nothing. Each process with a root ring can send it. A process with no root ring (a disk process, a module with no start grant that sends a command) is not checked yet.

**The growth is a second budget.** A process of the root service with a growth row asks with `Budget_Grow` on the root ring. The answer is a new budget handle, made from the free pages of the root service, up to the ceiling, or a refusal with no amount. The process makes on it the objects of one purpose (the arena of one document); when the purpose ends, it closes them and the budget, and the pages return. A growth never extends an object that exists. A process with no row is refused at the border, before any read of the pages of the starter. `Screen_Budget` is the pair form of this command for the compositor and the remote display, with its replacement rule.

**The growth is not reserved, and says so.** The pages between the size and the ceiling come from one pool, first come, first served. Three rules reduce what a refusal tells: it carries no amount; each process gets at most one decision in each period, a value of the plan of principal 0 whose default is one second, which bounds the channel to about one bit in a second; each growth and each refusal is a log fact that the principal sees. A row can give a growth reserve, pages that the starter holds for that row alone, with 0 as its default: a growth inside its reserve reads no pool and tells nothing.

**The class of the disk processes.** Its row gives its pages, its slots and its processor time. The defaults: the pages of two disk processes at the least ceiling of the machine; 4 processes and 4 threads each, so the processes of the image keep the other slots; the default share of the processors, a quarter. Its pages return to the root service never; a row that lowers the class takes effect when the class holds no process.

## The refused forms

- **The working memory in the source, or a sum `start_objects_pages`.** One number that the hand writes and that nothing ties to the code.
- **A size in the module file, or a hint of the usual size.** It spends the machine; the plan decides it.
- **A default size of a fixed page count** (`floor + max(floor, 2048)`). It gives a small module eight times its need and a large one nothing more.
- **A floor measured on a run.** The peak checks the floor; it never writes it.
- **A count of the memory objects that the code creates, by the tool.** A second evaluator of Odin.
- **A clamp of one process with no sum.** The start order then decides who runs.
- **A row keyed by the name of a disk process.** A file chooses its name.
- **A table of exceptions in the code of the root service, or rows of tests in the default plan.**
- **A kernel operation that adds pages to a budget that lives.** One more operation, and a growth with no return.
- **A refusal that gives the amount held.** A channel at the rate of a ring command.
- **A file with no table `Floor` that gets a least budget.**
- **The first state of work guessed by the kernel or by the root service** (the first wait of a thread, a process seen idle). A wait is no state of work: a process waits for its disk during its start. The process alone knows when its start is done.
- **A check of the peak at the stop of a process.** The peak of a whole life holds the growth past the floor, which the size allows.
- **A list of start objects with a fixed capacity** (`[N]Start_Object`). A bound that no fact gives; the array of inferred length has none.
- **The children named in the source and in the module table.** Two copies of one list; the build needs the table for its order.

## Subtle points

- **A table sized from the machine is a floor on that machine.** The root service, the compositor and the collector need it before their first state of work. The floor in the file is the floor on the least machine; the floor of a start adds the rest.
- **A parent pays the floors of the children that it starts before its first state of work.** The source names their modules, and the tool adds their floors.
- **The channel of the growth** stays, about one bit in a second between two processes that both hold a growth row: line 17 of property 20, reduced, not solved.
- **A disk process holds no growth row by default.** Its class row can give one.

## State

Built: the least count of free pages of a budget and its read in `Process_Report`; `Root_Command.Ready` and `system.ready`, sent by the console; the facts of the peak and the stop of the machine test on a passed floor; the table `Floor` for each module with an entry, counted whole (module, load, threads, window, start objects, children) with the working memory that is left; the refusal of a file with no floor; the floor of a start (screen pictures, audits, wirings); `system.budget_size` with `module.DEFAULT_GROWTH_FACTOR`; the reserve of the floors of the start list and its division before the first row; the proof at the build that the floors of each list fit in the least machine; the refusal of a floor that the starter cannot pay, with one line that names both amounts. Each module with an entry that stated no budget states the 2048 pages of the least budget in which it ran, as working memory that leaves with the rest.

Left, in the order of the study, section 10.4: each process says its first state of work, and the working memory leaves module by module, each checked by its peak (the glyph memory of `display` first, once the count knows which copy of the text rendering draws); the rows of the plan, with `default_growth_factor` read from the plan of principal 0 in place of the default of the contract; the frames of a process; `Budget_Grow`. The starters other than the root service (`scheduler`, `rings`, the console for its sandboxes) still give their children fixed amounts.
