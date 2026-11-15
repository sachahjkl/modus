# The budget that a module asks for

## Purpose

A program runs inside a budget: pages of memory, programs, threads, processor time and log records. The starter of the program pays that budget from its own. This file records who states the amounts, and who decides them (`docs/DECISIONS.md`, D-254).

The guide of the budgets is [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "K1. Handle table". The guide of the table is [`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "The budget that a module asks for".

## Constraints

- **A program never grants itself anything.** The budget of a program is a part of the budget of its starter. A number that the file of a module states is a request, never a grant.
- **A module of another project runs.** Its developer changes no source of the system: no table of the root service can name it.
- **An amount that is too small shows only when the program runs.** The program does not start, or it stops at its first window. A fixed table of amounts in the starter gave three such faults in one day: a second picture for each window, a program that gained four children, a child with eight threads.
- **The kernel and the loaders read the file of a module.** The format gains fields only at the end of a record, or a table that an older reader ignores.

## The chosen form

**The request is a table of the module file.** The table `Budget` holds one record, `module.Budget_Request`: the pages, the programs and the threads that the module asks for. A module with no such table asks for the least budget. A part that is 0 asks for the least budget of that part, so a record of an older, shorter size reads its missing parts as the least.

**The source states the request as one constant.** The form is:

```odin
// Its loop, and the thread that makes the lists of the palette.
MODULE_BUDGET :: system.Budget_Request{pages = 4096, programs = 1, threads = 2}
```

The step that describes the exports reads it from the tree of the parser, as it reads an export, and the conversion writes the table. The reasons of this form:

- **The compiler checks the names.** The constant has the type of the record, so a field with a wrong name stops the compile. The tool then reads only integer literals: the number in the file is the number in the source, with no evaluation.
- **No new import.** Each program imports `modus:support/system`, and `system.Budget_Request` is the record of the contract. A module of another project states it the same way.
- **The comment before the constant gives the reasons.** The tool refuses the constant with no comment. The site shows the comment beside the amounts on the page of the module.
- **No silent least budget.** A declaration named `MODULE_BUDGET` that the tool would not read is an error of the tool: inside a `when` (the tool reads the source with no setting of the build, and cannot know the branch that the compiler takes), or with other names in one declaration. A refused form says why in its message.
- **The forms of Odin that hold the same value are taken.** The type can be on the declaration, `MODULE_BUDGET : system.Budget_Request : {...}`, and a part can be written with the prefix `0x`, `0o` or `0b` and with `_` between its digits.

**The tool adds what it can count.** This is the second layer, not built. Three parts of a budget are facts, not choices:

- the pages of the loaded module and of each module that it imports: the sizes of their segments are in their files;
- the pages of each thread: its stack and its thread area;
- the pages of the two pictures of a window, when the source states the size of its window as constants.

The request of the source then is only the working memory that the program chooses: a table, a cache, a region of large pages. The step that writes the table adds the counted parts, and prints each part, so that a reader of the build sees where an amount comes from.

**The starter decides.** `system.budget_decide` is the rule, and each starter can use it. For each part:

- a part that is 0 takes the part of the least budget;
- the starter accepts the part when it is not above its largest budget for one program;
- it limits a part above that: the program gets the largest budget of that part, and one line of the log says so.

The root service keeps a table of budget exceptions (`budget_exceptions` in `src/programs/root/budgets.odin`). A row names one program of the boot image, gives it another largest budget for a part, or other limits of processor time and of log records, and has the reason beside it. A row that is larger widens, a row that is smaller limits. A row is the exception, not the normal case: two rows exist, `address_space` (64 MiB of large pages and two ranges of 1 GiB) and `limits` (small time limits that its cases reach).

**A disk program is paid by one budget of its own.** A disk program and a module of another project (which runs as a disk program) are files that a principal chose, not programs of the system. The root service makes one budget for all of them, from its own, at the first disk program, and keeps it (`disk_program.PROGRAMS_BUDGET`): 16384 pages, 4 programs, 16 threads, two processors of time and 1000 log records in each second. One disk program gets its request up to a largest budget of its own (`disk_program.LARGEST_BUDGET`): 8192 pages, one program, 4 threads. The reasons of the amounts:

- `budget_create` moves the programs and the threads out of the budget of the root service at the start, whatever the program does with them. With the largest budget of the boot image, eight hostile files of 8 programs and 32 threads each took the program and thread slots that a driver, the terminal or a service needs to start again. The one budget bounds the sum of all disk programs, whatever their count and their files: the programs of the boot image keep 59 of the 63 programs and 239 of the 255 threads.
- A disk program holds no grant that starts a program, so one program slot loses nothing, and with it the program creates no child.
- 4 threads give 4 processors of time at most to one program; the one budget gives two to all of them together.
- 8192 pages hold the two pictures of a window of about 1000 x 704 and a working memory; it is half of the one budget, so two of the largest run at one time, and more of a smaller request.
- The pages of the one budget leave the root service at the first disk program, and return to it never: a machine that starts no disk program keeps them.

A part above the largest budget of a disk program starts the program with that part, and the log says so. The name of a disk program never selects a row: a name gives nothing.

**The policy of the principal.** A disk program gets its store of its nickname, and the size of that store is a line of the budget that the module asks for; the principal sets the policy that accepts, limits or widens it (`docs/DECISIONS.md`, D-260). This form is the place of that policy: the request gains the part of the store at the end of its record, as the format allows; the one budget of the disk programs and their largest budget are the two amounts that the policy of the principal sets, in place of the constants of today; and the rule `system.budget_decide` stays the one rule. The principal then decides the share of the machine that the files of a principal take, and a file never decides it.

**A refusal names the amount.** When a start fails for the budget, the line of the log gives what the program was to get and what the budget that pays holds (the budget of the root service, or the one budget of the disk programs), and names the first part that is short. When the budget of the starter holds the request, the request itself was too small for the load, and the line says that.

## The refused forms

- **The flat table of the starter**, one case with fixed amounts for each program. It was the first form. Each new program changed the root service, and each amount was a guess that nobody checked.
- **A budget that the module file grants.** The file is data of a third party. A starter that gives what a file asks, with no limit, lets any program take the memory of the machine.
- **A request in a file beside the module** (the module build file of a module of another project). The request then is not in the bytes that the hash names, and a starter cannot trust the pair.
- **A request as a call of the program at its start.** The program runs before it has its budget, so the starter must give a first budget by a guess: the same fault, one step later.
- **A measure of a run in place of a request.** A run gives what one scenario used, not what the program needs at its largest.
- **An attribute or a comment in place of a constant.** The compiler checks neither, and a typing fault in a name gives a module that asks for the least budget with no word.
- **An expression in the constant** (`2048 + 1024`). The tool would then compute what the compiler computes, a second evaluator of Odin. The second layer computes the counted parts in the tool, from the facts of the files.
- **A disk program paid by the budget of the root service, up to the largest budget of the boot image.** Each start moved up to 8 programs and 32 threads out of the budget that the programs of the boot image need, and a few hostile files stopped a restart of a driver. A smaller largest budget alone still has no bound on the sum: the count of disk programs then decides it.
- **Processor time and log records in the request.** They are limits that protect the other programs, and the starter owns them: one processor for each thread, and 1000 log records in each second.

## Subtle points

- **A window in two sizes.** A program whose window follows a setting states its largest size.
- **A program that starts programs** asks for the sum: its children are paid from its budget. Its request is the place where that sum is stated one time.
- **The request is a part of what is signed.** The table is in the bytes of the module, so the hash of the module names it, and the system description holds that hash. A new table changed the hash of each module, the kernel too: the directory has one more entry.
- **The kernel reads no request.** The kernel and the boot program check the range of each table of the directory (`module.validate`), the new one too, and read only the header, the segments, the rebases, the imports and the exports. No line of the kernel changed.
- **The counted parts change with a build** (second layer). A module that grows then changes its request with no edit of its source.

## State

Built: the first layer. The table `Budget` and its reader; the constant `MODULE_BUDGET` of the source, read by the describe step and written by the conversion, and compared by `modustool test descriptions`; each amount of the old table of the root service moved to the source of its program, with its reasons; the rule of the starter, the two exceptions, the least and the largest budget; the one budget of the disk programs and the largest budget of a disk program; the line of a limit and the line of a refusal.

Left: the part of the store in the request, and the policy of the principal over the budget of the disk programs (`docs/DECISIONS.md`, D-260). The second layer, where the tool counts the pages of the module and of its imports, of each thread and of the two pictures of a window. The starters other than the root service (`scheduler`, `rings`, the console for its sandboxes) still give their children fixed amounts.
