# Memory without a bound: arenas paid by the budget

Some processes hold data whose size they cannot know before they read it: the tree of a document of the web, a style sheet, the heap of a language, a long text in an editor. Today each process of the system holds tables of a fixed size, which its stated budget names ([module_budget_request.md](module_budget_request.md)). This file records how a process holds such data with no fixed table and with no allocator of the language: in arenas that its budget pays for. The growable arena is built in the support package `system` (`src/library/modus/system/arena.odin`); the state is at the end.

The rule is [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller". The mechanism that the arenas use is [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "The virtual memory of a process". The terms are in [`docs/glossary/access.md`](../../../docs/glossary/access.md): "Arena", "Uncommitted object", "Committed page", "Decommit", "Budget".

## The constraints

- Each page that a process uses is paid by a budget, and a budget never pays past its amount ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", line 16).
- A lack of memory is a value that the process reads, never a stop. A process that reads a page of the web must be able to say "this page is too large" and keep its other pages.
- The kernel gets no new operation and no heap. The operations exist already: `Memory_Create` with the flag `Uncommitted`, `Memory_Map`, `Memory_Commit` with and without `Decommit`, and `Budget_Read`.
- The code of the system calls no allocator of the language, and names none: `modustool check` refuses `make`, `new`, `delete`, `free`, `context.allocator` and `[dynamic]` in each source of `src/` that is not a test. That rule stays for the kernel, the services and the library.

## The chosen form

An arena is a memory object of the process that grows by an explicit commit and that ends whole.

1. **The reservation.** The process makes an uncommitted object and maps it once. The mapping is the reserved range of addresses: one of the 128 mappings of the process, whatever the size. The budget pays the frame list of the object at once, 8 bytes for each page of the range, and no page.
2. **The growth.** A push past the committed end asks `Memory_Commit` for the next pages, in steps of several pages so that a run of small pushes costs few kernel commands. The budget pays the new pages, or refuses the whole commit with `No_Budget`. The push then returns that refusal to its caller, with its error record, and the arena stays as it was.
3. **The end.** The process ends the arena whole: a decommit of every committed page, or the close of the object and of its mapping. Each page returns to the budget at once. No object of the arena is freed alone.

A procedure of the arena is a plain procedure of a support package, not an Odin allocator: the code calls `arena_push` with the arena, the size and the alignment, and reads a result and a status. So the check of the tool still finds no allocator in the system, and each push that can fail shows its failure in the code that called it.

The procedures are `arena_create` (the reservation and its mapping), `arena_push`, `arena_reset` (the end back to 0, the pages kept) and `arena_end` (the unmap and the close). They are in the support package `system`, which each module imports: a package `arena` of its own would have one owner today, and the tool refuses a support package with fewer than two. A push refuses with a status of the kernel and an error record:

- `Bad_Operation`: a size of 0 (`Too_Small`), an alignment that is not a power of two or is above the page (`Bad_Value`), a size above the whole reservation (`Too_Long`). The last check comes before any sum, so a size near the top of the type never wraps the end to a small one.
- `No_Slot`: the bytes do not fit in the rest of the reservation (`Full`, unit `Bytes`).
- `No_Budget`: the record of `Memory_Commit`.
- `Bad_State`: the undo of a refused push of several calls was refused (the subtle points).
- Each other status of `Memory_Commit`, with its record and with no retry.

The page change is a procedure value of the arena: `Memory_Commit` on a machine, a fake in a host test. The arithmetic of a push then runs on the host with no kernel, and the host tests give it each refusal.

Two kinds of arena are planned:

- **The growable arena.** It holds data that lives as long as a thing of the process: a document, a page of the web, a heap of a language. It ends with that thing.
- **The scratch arena of a frame.** It holds what one frame computes and drops: the boxes of a layout, a text that a frame shapes. The process sets its end back to 0 at the start of each frame and keeps its committed pages, so a frame commits nothing in the usual case. Its committed size is the largest frame so far, and the process can give back the pages past a mark that it chooses.

The process learns its limit from `Budget_Read`: the pages that its budget still holds. It reads it at its start to choose the size of each reservation, and after a refusal to say what was refused. The budget that a module asks for in its file states the working memory of its tables; a process with arenas states there the pages that it expects for its usual data, and it receives at most the largest budget of its starter.

## Why this form

- **The property already names it.** Property 14 says that "reserve address space" and "commit pages" are two cheap operations on which processes build arenas. The uncommitted object and `Memory_Commit` are those two operations. An arena adds no concept to the kernel.
- **A refusal is a value.** A commit returns `No_Budget` to the code that asked, in the order of its own work. A process that reads hostile data (a page of the web, a file of a document) can refuse that data and keep running.
- **A whole end is cheap and certain.** The data of a document dies with the document. One decommit returns every page, and no free of one object can be forgotten or done twice.

## The refused forms

| Form | Why refused |
|---|---|
| A growth through the fault handler: a touch of a page that is not committed commits it | The growth is then hidden in an access. A budget that refuses the commit stops the process, or the handler must turn a fault into a value that no code path waits for. The refusal must come back at a call |
| An allocator of the language (`context.allocator`) over an arena, in the code of the system | Each `make` and each `append` can then fail where the code does not look. The check of the tool could no longer tell which source spends memory |
| A heap of the system, shared by the processes, with free of one object | Property 14 forbids a global heap that the system imposes. A heap in each process brings back a free of one object, its faults, and a size that no budget foresaw |
| A large fixed table for each kind of data | It pays the largest page of the web for every page. The budget of the process is spent before the first read |
| A new kernel operation "grow" | `Memory_Commit` already pays pages of an object that lives, with the refusal of the whole table |

## What must change in the properties

Property 14 held as it was written: this form applies its second rule. Its field **Open** said "the accounting model"; this design decides it, so the text changed with the first arena:

- a new rule: "A process that holds data with no known bound holds it in arenas: memory objects of its budget that grow by an explicit commit and end whole. A refused growth is the status `No_Budget`, which the process reads; it never stops the process."
- a new forbid: "a growth of memory that a process does not ask for at a call: a commit that the kernel makes on a fault, an allocator of the language in the code of the system."
- **Open**: the reservation size of each arena and the rule of the scratch arena, below.

## The decision points

- **The size of a reservation.** One object holds at most 262144 pages (1 GiB). Its frame list costs one page for each 512 pages of range: a reservation of 1 GiB costs 2 MiB of the budget before any data. The proposal: a reservation of the pages that the budget holds, rounded up to 512, so the frame list costs at most 0.2 % of the budget; an arena that needs more than 1 GiB chains a second object.
- **The step of the growth.** The proposal: 16 pages, then the double of the last step, up to 512 pages. A measure of the commits of a large page of the web decides it.
- **The scratch arena.** Whether it gives back its pages past a mark, and when: never, after a number of frames below the mark, or at a request of the process.
- **Large pages.** The kernel refuses `Uncommitted` with `Large_Pages`, so an arena has 4 KiB pages only. Large pages in an arena need a commit by whole runs of 2 MiB, a change of the kernel that waits for a measure of an arena with many random reads ([desktop_to_browser.md](desktop_to_browser.md), "Large pages for large buffers").
- **The largest budget.** The largest budget of the root service is 16384 pages (64 MiB) for a process of the boot image and 8192 pages for a disk process. A browser needs more. A larger budget for one process is a budget exception, or a grant of the principal; the choice comes with the first process that needs it.

## The subtle points

- **A decommit needs an object that only this process names, with one mapping.** An arena is private to its process, so a decommit always applies. An arena that a process shares with another process cannot give back a part of its pages.
- **A committed page has no frame until its first touch.** A commit of 512 pages costs the budget 512 pages at once, and the frames come later. The budget limits the memory that a process can use, not the memory that it uses now.
- **An address into an arena does not cross a border.** A record of a contract never holds an address. A process that sends a part of an arena to another process copies it into a call region, or gives a separate memory object.
- **A process that reads hostile data bounds each arena below its budget.** Else a hostile page takes the whole budget, and the process has no pages left for its other documents.
- **A refused step is not a refused push.** The budget refuses a commit whole. A step of 512 pages that a budget of 100 pages refuses would stop the arena while the budget still pays the push. So a refused step is followed by a commit of the missing pages alone, and the push gives `No_Budget` only when the budget cannot pay those. The arena then grows until its budget holds no page for the push.
- **A retry halves the step.** An accepted step doubles the next one; a retry halves it, down to the first step of 16 pages. With a step that doubled after each retry, the budget near its end refused the step at each push, and each push paid one refused call and one accepted call: the machine test counted 410 commits for 1923 pages. A step that stays the same after a retry was refused: it costs the same two calls at each push until the budget ends. A halved step reaches a size that the budget pays after a few retries. A retry commits fewer pages than a step, so it is always one call.
- **A push past one call is whole.** One `Memory_Commit` commits at most `RANGE_TABLE_PAGE_LIMIT` pages. A larger push makes several calls, and a refused call decommits the pages that the calls before it committed, so a push is whole or changes nothing, as one call is. The undo gives back the last call first. If a decommit of the undo is refused, the push gives `Bad_State` with the record of that decommit, and the committed end of the arena moves past the pages that stay committed, which follow it.
- **The arena owns its object alone.** A decommit is refused for an object that another holder names, or that has a second mapping. A process that copies the handle of an arena, gives it, or maps the object again breaks the undo of a refused push. The arena does not check it: it is a rule for the process, as the address of a push that it must not keep past a reset.
- **A record of the arena names no operation.** A refusal that the arena makes itself (a size, an alignment, the end of the reservation) has `operation` `None`, so a reader does not take it for a refusal of the kernel. A value past `max(i64)` is written as `max(i64)`: the record holds signed values. A record of a refused commit or decommit is the record of the kernel.

## State

Built: the growable arena and its procedures in the support package `system`, with the step of 16 pages that doubles up to 512 and halves after a retry, and the reservation of the pages of the budget rounded up to 512 (`arena_reservation_pages`), both as proposed and not yet measured. A scratch arena is a growable arena that its process resets at each frame. The host tests give a push each refusal and check that nothing changed; the test module `arena` grows an arena on a machine until its budget refuses, and checks that its budget comes back whole at the end.

Built too: the first processes that hold data with no known bound: `paint` keeps its picture, its copy before a stroke and the bitmap of a fill in three arenas of its budget ([paint_application.md](paint_application.md), "The memory of a picture"), and the browser and `web_engine` keep the tree, the style sheet and the boxes of a page in arenas, one for each part, through the grow procedures of `html_css` ([desktop_to_browser.md](desktop_to_browser.md), "The memory of a document"); each reserves the pages that its budget holds. Left: the measure of the step; the give back of the pages of a scratch arena past a mark; a second object for an arena past 1 GiB; the largest budget.
