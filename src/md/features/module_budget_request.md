# The budget that a module asks for

## Purpose

A program runs inside a budget: pages of memory, programs, threads, processor time and log records. The starter of the program pays that budget from its own. This file records who states the amounts, and who decides them (`docs/DECISIONS.md`, D-254).

The guide of the budgets is [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "K1. Handle table".

## Constraints

- **A program never grants itself anything.** The budget of a program is a part of the budget of its starter. A number that the file of a module states is a request, never a grant.
- **A module of another project runs.** Its developer changes no source of the system: no table of the root service can name it.
- **An amount that is too small shows only when the program runs.** The program does not start, or it stops at its first window. A fixed table of amounts in the starter gave three such faults in one day: a second picture for each window, a program that gained four children, a child with eight threads.
- **The kernel and the loaders read the file of a module.** The format gains fields only at the end of a record, or a table that an older reader ignores.

## The chosen form

**The request is a table of the module file.** The table `Budget` holds one record: the pages, the programs and the threads that the module asks for. A module with no such table asks for the default. The source of the module states the request as one constant, and the step that describes the exports writes the table. A module of another project states it the same way.

**The tool adds what it can count.** Three parts of a budget are facts, not choices:

- the pages of the loaded module and of each module that it imports: the sizes of their segments are in their files;
- the pages of each thread: its stack and its thread area;
- the pages of the two pictures of a window, when the source states the size of its window as constants.

The request of the source is then only the working memory that the program chooses: a table, a cache, a region of large pages. The step that writes the table adds the counted parts, and prints each part, so that a reader of the build sees where an amount comes from.

**The starter decides.** A starter reads the request and gives the program its budget by one rule:

- it accepts the request when the request is under its limit for one program;
- it limits a request above that limit: the program gets the limit, and one line of the log says so;
- it widens a request for a program that it names, when it knows a need that the file cannot state.

The root service keeps a table for the third case only, and for the limit of a program that it wants smaller than its request. A row of that table is an exception with its reason, not the normal case. A disk program and a module of another project get their request up to the limit of a program with no row.

**A refusal names the amount.** When a start fails for the budget, the sentence gives what the starter could give, what the module asked for, and which part was the largest. The program `scheduler` already writes such a line for its children.

## The refused forms

- **The flat table of the starter**, one case with fixed amounts for each program. It was the first form. Each new program changed the root service, and each amount was a guess that nobody checked.
- **A budget that the module file grants.** The file is data of a third party. A starter that gives what a file asks, with no limit, lets any program take the memory of the machine.
- **A request in a file beside the module** (the module build file of a module of another project). The request then is not in the bytes that the hash names, and a starter cannot trust the pair.
- **A request as a call of the program at its start.** The program runs before it has its budget, so the starter must give a first budget by a guess: the same fault, one step later.
- **A measure of a run in place of a request.** A run gives what one scenario used, not what the program needs at its largest.

## Subtle points

- **Processor time and log records are not in the request.** They are limits that protect the other programs, and the starter owns them: one processor for each thread, and a count of log records for each second.
- **A window in two sizes.** A program whose window follows a setting states its largest size.
- **A program that starts programs** asks for the sum: its children are paid from its budget. Its request is the place where that sum is stated one time.
- **The counted parts change with a build.** A module that grows changes its request with no edit of its source, and the system description holds the new hash: the request is a part of what is signed.

## State

Decided, not built. The first layer moves each amount of the table of the root service to the source of its program, with no other change: the request is the whole amount, and the root service reads it. The second layer makes the tool count the three parts, and each source keeps only its working memory.
