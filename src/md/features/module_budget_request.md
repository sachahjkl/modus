# The budget that a module asks for

## Purpose

A process runs inside a budget: pages of memory, processes, threads, processor time and log records. The starter of the process pays that budget from its own. This file records who states the amounts, and who decides them.

The guide of the budgets is [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "K1. Handle table". The guide of the table is [`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "The budget that a module asks for".

## Constraints

- **A process never grants itself anything.** The budget of a process is a part of the budget of its starter. A number that the file of a module states is a request, never a grant.
- **A module of another project runs.** Its developer changes no source of the system: no table of the root service can name it.
- **An amount that is too small shows only when the process runs.** The process does not start, or it stops at its first window. A fixed table of amounts in the starter gave three such faults in one day: a second picture for each window, a process that gained four children, a child with eight threads.
- **The kernel and the loaders read the file of a module.** The format gains fields only at the end of a record, or a table that an older reader ignores.

## The chosen form

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
- **No new import.** Each process imports `modus:support/system`. A module of another project states it the same way.
- **The comment before the constant gives the reasons of the working memory.** The tool refuses the constant with no comment. The site shows the comment beside the parts on the page of the module.
- **No silent least budget.** A declaration named `MODULE_BUDGET` that the tool would not read is an error of the tool: inside a `when` (the tool reads the source with no setting of the build, and cannot know the branch that the compiler takes), or with other names in one declaration. A refused form says why in its message.
- **The forms of Odin that hold the same value are taken.** The type can be on the declaration, `MODULE_BUDGET : system.Stated_Budget : {...}`, and a part can be written with the prefix `0x`, `0o` or `0b` and with `_` between its digits.

**The tool counts three parts.** Each one is a fact of the build, not a choice of the developer. The request is the sum: `pages = working memory + module pages + thread pages + window pages`. The processes and the threads go to the table as the source states them.

- **The module pages.** The memory size of the module, from the header of the file that the conversion writes, and the memory size of each module that it imports, at each level, each module one time, from their files. The conversion reads the file of each import already, for its hash. This is what a load pays when the process has its own copy of each module. A starter that shares the code of a module pays less, and the difference stays free in the budget of the process: an amount above the need, never below it.
- **The thread pages.** The first thread: its stack (`op.STACK_PAGES`), the page of the context, its thread area, and the own log ring of the process (`op.OWN_LOG_PAGES`), which the kernel takes from the budget at `Process_Create`. The ring is counted here because a process does not choose it: a source that stated it in its working memory would break at the next change of its size. Each other thread that the source states: a stack of `op.THREAD_STACK_PAGES`, the stack that `system.thread_start` makes when its caller gives no count, and its thread area. A thread area is the pages that the kernel pays from the budget: the thread record and the kernel ring (`op.THREAD_AREA_PAGES` minus the guard page, which has no memory). With no part `threads`, the tool counts the first thread.
- **The window pages.** The two pictures of the window, as `display.open` makes them: the width times the height times the 4 bytes of a pixel, times 2, in whole pages. The parts `window_width` and `window_height` each name a constant of the package whose value is one integer literal, or are an integer literal. The process passes the same constants to `display.open`, so the counted pictures are the pictures that it opens. A size that the source computes (`WIDTH :: BAR_X + BAR_WIDTH + 64`) is written as a literal, with `#assert` of the expression beside it: the compiler checks the number, and the tool still evaluates nothing.

What stays in the working memory: what the process chooses (a table, a cache, a region of large pages, the call regions of its connections), the budgets of its children, a stack that a thread asks for with another count, the page tables of its address space, and the 4 pages of its own log ring ([own_log_ring.md](own_log_ring.md)).

**Where a reader sees the parts.** `modustool test descriptions` computes the request again from the source and the files, compares it with the table, and prints the four parts of each module. The site shows on the page of the module the parts that the source gives: the working memory, the thread pages and the window pages; it builds no module, so it names the module pages as counted from the files of the build. The measure of each build has one line with the request of each module that has a table, so that a reader sees an amount change when a module grows.

**The starter decides.** `system.budget_decide` is the rule, and each starter can use it. For each part:

- a part that is 0 takes the part of the least budget;
- the starter accepts the part when it is not above its largest budget for one process;
- it limits a part above that: the process gets the largest budget of that part, and one line of the log says so.

The root service keeps a table of budget exceptions (`budget_exceptions` in `src/modules/system/root/budgets.odin`). A row names one process of the boot image, gives it another largest budget for a part, or other limits of processor time and of log records, and has the reason beside it. A row that is larger widens, a row that is smaller limits. A row is the exception, not the normal case: two rows exist, `address_space` (64 MiB of large pages and two ranges of 1 GiB) and `limits` (small time limits that its cases reach).

**A disk process is paid by one budget of its own.** A disk process and a module of another project (which runs as a disk process) are files that a principal chose, not processes of the system. The root service makes one budget for all of them, from its own, at the first disk process, and keeps it (`disk_process.PROCESSES_BUDGET`): 16384 pages, 4 processes, 16 threads, two processors of time and 4000 log records in each second, 1000 for each of its processes: a budget gives a child a part of its log records, as of its pages ([log_side_channels.md](log_side_channels.md)). One disk process gets its request up to a largest budget of its own (`disk_process.LARGEST_BUDGET`): 8192 pages, one process, 4 threads. The reasons of the amounts:

- `budget_create` moves the processes and the threads out of the budget of the root service at the start, whatever the process does with them. With the largest budget of the boot image, eight hostile files of 8 processes and 32 threads each took the process and thread slots that a driver, the terminal or a service needs to start again. The one budget bounds the sum of all disk processes, whatever their count and their files: the processes of the boot image keep 59 of the 63 processes and 239 of the 255 threads.
- A disk process holds no grant that starts a process, so one process slot loses nothing, and with it the process creates no child.
- 4 threads give 4 processors of time at most to one process; the one budget gives two to all of them together.
- 8192 pages hold the two pictures of a window of about 1000 x 704 and a working memory; it is half of the one budget, so two of the largest run at one time, and more of a smaller request.
- The pages of the one budget leave the root service at the first disk process, and return to it never: a machine that starts no disk process keeps them.

A part above the largest budget of a disk process starts the process with that part, and the log says so. The name of a disk process never selects a row: a name gives nothing.

**The policy of the principal.** A disk process gets its store of its nickname, and the size of that store is a line of the budget that the module asks for; the principal sets the policy that accepts, limits or widens it ([processes_from_a_disk.md](processes_from_a_disk.md)). This form is the place of that policy: the request gains the part of the store at the end of its record, as the format allows; the one budget of the disk processes and their largest budget are the two amounts that the policy of the principal sets, in place of the constants of today; and the rule `system.budget_decide` stays the one rule. The principal then decides the share of the machine that the files of a principal take, and a file never decides it.

**A refusal names the amount.** When a start fails for the budget, the line of the log gives what the process was to get and what the budget that pays holds (the budget of the root service, or the one budget of the disk processes), and names the first part that is short. When the budget of the starter holds the request, the request itself was too small for the load, and the line says that.

## The refused forms

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

## Subtle points

- **The request is a part of what is signed.** The table is in the bytes of the module, so the hash of the module names it, and the system description holds that hash. A new table changed the hash of each module, the kernel too: the directory has one more entry.
- **The kernel reads no request.** The kernel and the boot program check the range of each table of the directory (`module.validate`), the new one too, and read only the header, the segments, the rebases, the imports and the exports. No line of the kernel changed.
- **The counted parts change with a build.** A module that grows changes its request with no edit of its source, and its hash changes. An import that grows changes the request of each importer: the file of the import is an input of the conversion already, so the importer is converted again.
- **A process that starts processes.** Its children are paid from its budget. Its stated threads hold the threads of its children, and the tool counts a stack and a thread area for each, as the children pay them; its working memory holds the rest of the budgets of its children.
- **The window is checked by the compiler, not by the tool.** The tool cannot know that the process passes `WIDTH` to `display.open`. It knows that the counted size is the size of a constant of the process, and the `#assert` of a computed size keeps the literal equal to its expression.
- **A window whose size follows a value** (the terminal: its columns and its rows come from its starter) states no window part. Its pictures stay in its working memory, at its largest size.

## State

Built: the table `Budget` and its reader; the stated budget of the source, read by the describe step; the three counted parts, added by the conversion, compared again by `modustool test descriptions` and shown with their parts there and on the site; one line of the measure of the build with the request of each module; the rule of the starter, the two exceptions, the least and the largest budget; the one budget of the disk processes and the largest budget of a disk process; the line of a limit and the line of a refusal. The working memory of each process is its old amount minus the counted parts of the build of that day, so no total changed.

Left: the part of the store in the request, and the policy of the principal over the budget of the disk processes. The page tables of the address space are not counted. The starters other than the root service (`scheduler`, `rings`, the console for its sandboxes) still give their children fixed amounts.
