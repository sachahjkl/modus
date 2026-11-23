## Access

### Handle

A handle is a number that a process holds to name one kernel object with a set of rights: a process can act only on the objects of its handles.

A handle removes ambient access: no global name exists, so a kernel operation names each object that it acts on by a handle. The kernel checks the kind of the object and the rights of the handle: a wrong handle gives `Bad_Handle`, a missing right `No_Right`. A process gets a handle in its context from its starter, as the result of an operation that makes an object, or from another process with `Handle_Give`, which never adds a right. A handle is not a file descriptor: no child inherits it, and it carries rights.

The design: `docs/ARCHITECTURE.md`, "K1. Handle table".

Do not use: file descriptor, capability, token, reference.

### Memory object

A memory object is a set of pages that the kernel names by a handle; processes map it, and two processes that map the same one share its pages.

A memory object is the one form of memory in the system: the memory of a process, a ring, a call region, a framebuffer, the registers of a device. `Memory_Create` makes one, and a budget pays for each page at once, so an access never fails for lack of memory. `Memory_Map` maps it into a process with the rights of the handle. Its pages return to the budget that paid when its last handle or mapping ends. A memory object is not anonymous memory of one process: it has no owner but its handles.

The design: `docs/ARCHITECTURE.md`, "K2. Memory".

Do not use: region, shared memory segment, buffer.

### Page on first use

A page on first use is a page of a memory object that gets its page frame at its first read or write, from a process (a page fault) or from the kernel.

The frame is all zero. The budget paid for the page when the memory object was created, so the kernel keeps a free frame for it at all times: the first use never fails. A page that nobody touches costs no frame and no zeroing. A kernel event `Fault` with the outcome "first use" records it.

Do not use: lazy allocation, demand paging, demand-zero page.

### Uncommitted object

An uncommitted object is a memory object made with the flag `Uncommitted`: its budget pays only its frame list, and each page is paid when it is committed.

An uncommitted object reserves a range of addresses with no memory behind it: its mapping is the reservation. A process commits the pages that it needs with `Memory_Commit`, and gives them back with a decommit. An access to a page that is not committed is a fault: with no fault handler it stops the process with the stop cause `Not_Committed`; with one, the handler can commit the page and answer Resume. A process builds arenas, stacks that grow and sparse tables this way.

The design: `docs/ARCHITECTURE.md`, "The virtual memory of a process".

Do not use: reserved object, reservation, VirtualAlloc(MEM_RESERVE), mmap(PROT_NONE).

### Committed page

A committed page is a page of a memory object that its budget paid for: it gets a frame at its first use.

Each page of an object that is not uncommitted is committed. A page of an uncommitted object is committed after `Memory_Commit`; the kernel keeps it as one bit in the slot of the page.

The design: `docs/ARCHITECTURE.md`, "The state of a page".

Do not use: committed memory.

### Decommit

A decommit is the act of `Memory_Commit` with the flag `Decommit`: the pages of an uncommitted object are no longer paid.

Their frames and their pages return to the budget of the object at once; the addresses stay reserved, and a page committed again is zero. A decommit needs an object that only this process names, with one mapping at most, so the shoot-down is the one of this process.

The design: `docs/ARCHITECTURE.md`, "Commit and decommit".

Do not use: madvise(DONTNEED), VirtualFree(MEM_DECOMMIT), discard.

### Arena

An arena is an uncommitted object of a process that grows by an explicit commit and ends whole.

A process holds in an arena data with no known bound, such as the tree of a document. A push past the committed end commits the next pages; a budget that cannot pay refuses with `No_Budget`, which the push gives back to its caller, and the arena stays as it was. No object of an arena is freed alone: its end returns every page. A scratch arena of a frame is set back to its start at each frame. An arena is not an allocator of the language and not a heap of the system.

The design: `src/md/features/memory_without_a_bound.md`.

Do not use: heap, memory pool, bump allocator.

### Page protection

A page protection is what a page of a mapping lets a process do: read, read and write, read and execute, or nothing (`No_Access`).

`Memory_Map` sets the protection of a whole mapping from the rights of the handle. `Memory_Protect` changes it for ranges of pages, and can only take away what the mapping has: write and execute together are refused. A guard page, a read-only table after its build, and a collector that traps writes use it.

The design: `docs/ARCHITECTURE.md`, "Protection and the shoot-down".

Do not use: mprotect, page rights.

### Held entry

A held entry is an entry of a page table of a process that a mapping covers: a page of the mapping, present or not, a large page, or an entry that names a table with held entries.

A table with no held entry is freed, and its page returns to the budget that paid for it. So a process that maps and unmaps memory does not keep page tables that no budget sees.

The design: `docs/ARCHITECTURE.md`, "The page tables of a process".

Do not use: used entry, reference of a table.

### Shoot-down

A shoot-down is the step where each other processor that uses the page table of a process forgets its old translations, after the kernel cleared or reduced entries.

The kernel sends `processor_sync` to each processor whose page table is the one of the process; each one reloads its page table at its next kernel entry, its idle wait or its wait for a lock. The operation returns after each of them did, so no thread uses an old entry afterwards. A table of ranges in one command makes one shoot-down for all its ranges.

Do not use: TLB flush, TLB shootdown (for this).

### Large page

A large page is a page of 2 MiB: one entry of the second level of a page table.

Only an object made with `Large_Pages` uses them: it is contiguous, aligned on 2 MiB, and a whole number of large pages. A mapping uses a large page for each 2 MiB that is aligned in it. One entry then covers 512 pages, so random reads over a large object miss the translation cache less.

The design: `docs/ARCHITECTURE.md`, "Large pages".

Do not use: huge page, superpage.

### Fault kind

A fault kind is a processor exception that the kernel can give to a fault handler, named by its vector (`op.Fault_Kind`).

The kinds are divide error, debug, breakpoint, invalid opcode, segment not present, stack fault, general protection, page fault, x87 floating point, alignment check and SIMD floating point. A handler asks for a set of them (`op.Fault_Kinds`); 0 is page faults only. The non-maskable interrupt, the double fault and the machine check are never given: they are not faults of an instruction of a thread.

The design: `docs/ARCHITECTURE.md`, "The fault ring".

Do not use: signal number, exception code, trap number.

### Fault class

A fault class says where a thread continues after a fault kind: a fault did not run its instruction, which runs again; a trap ran it, and the thread continues at the next one.

Debug and breakpoint are traps; the other fault kinds are faults. One debug exception is a fault: an execute breakpoint of the thread, which stops it before its instruction. The class decides the rule of Resume: a trap and a page fault resume by themselves, and another fault resumes only after thread control wrote the registers or the extended state of the thread: without that write, the same instruction faults again with no end.

Do not use: exception class, exception type, abort (for this).

### Fault handler

A fault handler is the thread of a process that `Fault_Handler_Set` named, with the fault kinds that it takes: the faults of these kinds of the other threads of the process become records in its thread record.

A fault handler lets a process decide what a fault means: a guard page, a stack that grows, memory committed at the first touch, the barrier of a collector. The kernel holds no policy. A process has one handler at most. A fault of the handler itself, or of a kind that it did not ask for, stops the process. A fault handler is not a signal handler: the thread that faulted waits, and another thread reads a record and answers with an operation.

The design: `docs/ARCHITECTURE.md`, "The fault ring".

Do not use: signal handler, exception handler, pager (for this).

### Fault ring

The fault ring is the records of the faults of a process that the kernel gives to its fault handler, in place of a stop: a part of the thread record of the handler.

When a thread faults, the kernel writes a fault record, adds 1 to `fault_written`, and wakes the threads that wait on that word; the faulting thread waits, as a held thread. A thread of the process repairs with `Memory_Commit`, `Memory_Protect` or thread control, and answers with `Fault_Answer`: Resume or Stop. A fault that finds the ring full stops the process. The ring needs no new memory: the budget paid for the thread record with the thread.

The design: `docs/ARCHITECTURE.md`, "The fault ring".

Do not use: signal, SIGSEGV handler, userfaultfd, exception port.

### Fault record

A fault record is one record of the fault ring (`op.Fault_Record`, 64 bytes): the number of the faulting thread, the serial of the fault, the address and the kind of access of a page fault, the address where the thread continues, the fault kind and the error code of the processor.

`Fault_Answer` names the thread number and the serial, so an answer for an earlier fault, or for an ended thread whose number serves again, is refused. The serial is a count of the process, so it shows nothing of other processes.

Do not use: siginfo, fault message.

### Thread control

Thread control is the kernel operation `Thread_Control`: it stops a thread, reads and writes its registers and its extended state, and resumes it.

No other operation stops a thread without its end, or gives its registers. A debugger, a collector, a profiler and the process of a guest need both. One operation with a command (`op.Thread_Control_Command`) keeps the count of kernel operations low: `Stop`, `Resume`, the reads and writes of the registers, and commands for the schedule, the placement, the breakpoints, the memory and the thread counters. **Control**, the right to end a thread, does not read or write its registers. It is not ptrace: the rights of a handle decide everything.

The design: `docs/ARCHITECTURE.md`, "The control of a thread".

Do not use: ptrace, debug API, SuspendThread, thread_suspend (for this).

### Stop count

The stop count of a thread is the count of the stops of thread control that hold it: each `Stop` adds 1, each `Resume` takes 1, and the thread runs only at 0.

A stop is a count, not a state, so two holders that each stop a thread each resume it, and neither releases the hold of the other. The stops of the debugger of the process are counted apart, and the end of the debugging takes back those only. `Resume` at 0 gives `Bad_State`. When `Stop` returns, the thread runs no instruction. The count does not change the wait of the thread: its wait ends as before, but the thread does not run until its count is 0.

The design: `docs/ARCHITECTURE.md`, "The control of a thread".

Do not use: suspend count, freeze.

### Held thread

A held thread is a thread that no processor runs and that stays off every processor: its stop count is above 0, or it waits for an answer of the fault ring.

Only a held thread has complete registers in the kernel: the frame of its last kernel entry, and the extended state that the switch of threads saved. A thread that runs has its registers in a processor, where no other thread can read them. So thread control reads and writes the registers of a held thread only, and gives `Bad_State` for any other. A thread that waits for the answer of its fault handler is held too: the handler reads its registers, corrects them and answers.

The design: `docs/ARCHITECTURE.md`, "The control of a thread".

Do not use: stopped thread, suspended thread (for this).

### Register image

A register image is the general registers, the instruction address, the flags and the two selectors of a held thread, as thread control reads and writes them (`op.Thread_Registers`, 176 bytes).

It holds the 16 general registers, `rip`, `rflags`, `cs`, `ss`, and `in_kernel_entry`, which is 1 while the last kernel entry of the thread, a `syscall`, has not returned. The kernel refuses a write whole when a field holds a value that a thread of a process cannot hold, such as a selector of the kernel or an `rip` in the kernel half, and the error record names the refused field. The extended state (vector registers) has its own commands and its own area.

The design: `docs/ARCHITECTURE.md`, "The control of a thread".

Do not use: register context, CONTEXT, user_regs_struct.

### Debugger

A debugger is a process that holds the handle of another process with the right **Debug**, and that made one of its own threads the debug handler of that process.

It receives the debug exceptions and the breakpoints of that process, holds its threads, reads and writes their registers and their breakpoints, and reads the memory of the process. A process has one debugger at a time, and does not debug itself. Two holders have the right Debug: the debugger service and the creator of the process. A debugger that ends never holds and never stops the process. It is not ptrace, and not a developer tool, which never reads the bytes of a process.

The design: `docs/ARCHITECTURE.md`, "The debugger of a process".

Do not use: tracer, attach to a process.

### Debugger service

The debugger service is the process `debugger`: the one debugger of the system for the processes that the root service starts, whose exports are the commands of a debugger.

It asks the root service for the debug access to a process on behalf of one of its callers, becomes the debugger of that process for the kernel, and gives each fact of the debugging as a table: the threads, the registers, the stack, the variables. The console calls its exports under short names (`debug("clock")`, `stack(0)`), and a window or a developer on another machine calls the same exports. It debugs one process at a time, for one caller. It is not the process `debugged`, which tests the contract of the kernel.

The design: `docs/TOOLS.md`, "The debugger".

Do not use: debug server, debug agent, gdbserver, debug stub.

### Debug access

The debug access is the handle of one process with the right **Debug**, which the root service gives to the debugger service on behalf of a caller.

One rule over grants, which names no process, gives it: the caller acts for the principal whose session runs the process, holds each start grant of the process, and no such grant reaches what belongs to that one process, such as a service or a private store. The access is the grant `debug` of the caller: `revoke` ends it. It is not the right Debug of the creator of a process.

Example: `debug("storage")` is refused with `No_Grant`: "the grant Serve of the process refuses it".

The design: `docs/TOOLS.md`, "Who can debug which process".

Do not use: debug permission, ptrace scope, debug privilege.

### Watch

A watch is a data breakpoint that the debugger service sets on 1, 2, 4 or 8 bytes of the debugged process: a thread that writes one of them stops after the instruction of the write.

It takes one of the four breakpoints of the debugger, as an execute breakpoint does. It names its bytes by an address or by the path of a global. It does not see an access that the kernel makes for the process.

Example: `watch("debug_target::rounds", 8)`, then `wait_stop(3000)` gives a row with the kind `watch 0` and the procedure that wrote the count.

The design: `docs/TOOLS.md`, "The exports of the service".

Do not use: watchpoint, data watch, memory breakpoint.

### Value path

A value path is the text that names one value of a debugged process: the name of a variable or of a global, then steps to one of its parts.

A step is `.field` (a field of a record), `[number]` (an element of an array or of a slice, from 0) or `^` (the value that a pointer points to). The name is a variable that is visible at the instruction of a frame, else a global; a global has its package in its name, and then needs no held thread. As in the language, the field of a pointer to a record is the field of the record. A path has 8 steps at most.

Example: `pair.next^.first`, `table[3]`, `debug_target::shape.size`.

The design: `docs/TOOLS.md`, "The variables and the types".

Do not use: expression, watch expression, selector, accessor.

### Debug place

A debug place is the text that names a place of a debugged process for the debugger service: a procedure, a file and a line, an address or a value path of a global.

`break_at` takes a procedure (`debug_target::add_step`) or a file and a line (`src/modules/tests/debug_target/main.odin:82`); `watch` and `memory` take an address (`0x403010`) or a global (`debug_target::rounds`). The service parses it: the console and the window of the debugger pass the text as it is, and compute no address. The window of the debugger has a field for it, with the buttons break at, watch and memory.

It is not a place of the storage service ("Place"), which a connection holds as a number.

Example: `debugger.break_at("src/modules/demonstrations/fault/main.odin:15")`; in the window, `debug_target::rounds 4` then the button watch.

The design: `docs/TOOLS.md`, "The window of the debugger"; `src/md/features/debugger_window.md`.

Do not use: breakpoint location, location spec, address expression.

### Debug handler

A debug handler is the thread of a debugger whose fault ring receives the faults of the kinds Debug and Breakpoint of the debugged process.

The debugger names it with `Fault_Handler_Set` and its process handle with Debug. Those faults go to it before the fault handler of the process itself, and only the debugger answers them (`Fault_Answer` with the same handle, `Resume` only). The ring is in the thread record of the debug handler, so the debugger pays for it. A thread is the debug handler of one process, and it is not the fault handler of its own process: one ring has one role.

The design: `docs/ARCHITECTURE.md`, "The debugger of a process".

Do not use: tracer thread, exception port.

### Breakpoint

A breakpoint is one of the four places where a thread stops with a fault of the kind Debug: an instruction that it reaches, or bytes that it writes or reads.

It is a debug register of the processor, not a byte written in the code: the code of a module is shared by each process that maps it. Only the debugger of its process writes them. An execute breakpoint stops the thread before its instruction; a data breakpoint of 1, 2, 4 or 8 bytes stops it after its access. A breakpoint belongs to one thread, and is never at an address of the kernel. It is not the fault kind `Breakpoint`, which `int3` gives.

The design: `docs/ARCHITECTURE.md`, "The debugger of a process".

Do not use: watchpoint.

### Debug status

The debug status is the error code of a fault record of the kind Debug: it says what made the debug exception.

Bit n is the breakpoint n of the thread (`op.DEBUG_STATUS_BREAKPOINTS`); bit 14 is a single step, one instruction that ran with the trap flag set (`op.DEBUG_STATUS_STEP`); 0 is the instruction `int1` of the process. The kernel reads it from the status register of the processor at each debug exception, clears that register, and keeps only the breakpoints that the thread has on.

The design: `docs/ARCHITECTURE.md`, "The debugger of a process".

Do not use: trap reason, debug cause.

### Reserved page

A reserved page is a page that a budget paid for and that has no page frame yet.

The kernel keeps one free frame for each reserved page, so an access never fails for lack of memory, and the system never takes memory back from a process that paid.

Do not use: overcommit.

### Frame list

A frame list is the record of the page frames of one memory object: in the kernel record of the object for at most 4 pages, else in list pages that the budget pays for.

Each slot of the list is 8 bytes: the frame, and in its low bits the state of the page (committed, deny write, deny execute, no access). 0 is a page with no frame yet.

The design: `docs/ARCHITECTURE.md`, "The state of a page".

Do not use: page list, radix tree.

### Right

A right is one kind of operation that a handle permits on its object.

The rights are Give, Read, Write, Execute, Control, Inspect, Devices, Stop, Spend, Physical, Schedule, Commit, Events, Debug and Counters. Each one means something for each kind of object: Read on a memory object is a mapping that reads, Control on a process starts and stops it. A new object has each right of its kind; `Handle_Give` copies a handle with a part of its rights, and no operation adds a right. Narrow rights let a process give exactly what another needs: Commit pays pages of one object, and nothing more.

The list: `src/library/modus/contract/operation/operation.odin`.

Do not use: permission, privilege, mode.

### Budget

A budget is an object that holds pages, process slots, thread slots and the log records of each second, and has one limit in time, processor time; it pays for each object that a process creates.

A budget makes every cost visible and bounded: `Memory_Create`, `Process_Create` and `Thread_Create` take a budget handle with the right Spend, and the budget pays. When an object ends, what it used returns to the budget that paid. A process moves a part of its budget to a new budget with `Budget_Create`, and gives that one to a child, which can never use more. A budget is not a quota on a user: it is a handle, which a process divides among its children.

The design: `docs/PROPERTIES.md`, "20. No ambient access: the other holes to close".

Do not use: quota, limit, cgroup, job.

### Limit

A limit is a property of a budget for time: the microseconds of processor time that the budget can use in each second.

Time does not return, so it does not move as pages do. A limit holds for the budget and for each budget that came from it: what a thread uses counts in its budget and in each budget above. A new budget has a limit that is not above the limit of the budget that it came from. With the limit 0 a budget has no time: its threads do not run. The log records of each second are an amount, not a limit (`src/md/features/log_side_channels.md`).

Do not use: quota, cap, bandwidth, rate limit.

### Budget request

A budget request is the pages, the processes and the threads that a module asks for its process: the table `Budget` of its file (`module.Budget_Request`).

The source states its stated budget; the build adds the counted parts and writes the table, so the hash of the module names it. It is never a grant: the starter decides, by its least budget and its largest budget, and a budget exception can widen or limit it. A part that is 0, or a file with no table, asks for the least budget. Processor time and log records are not in it: the starter sets them.

The design: `docs/MODULE_CONTRACT.md`, "The budget that a module asks for".

Do not use: budget grant, resource manifest, reservation.

### Stated budget

A stated budget is the part of a budget request that the source of a module states: its working memory, its processes, its threads and the size of its window.

It is one constant of the source, `MODULE_BUDGET`, of the type `system.Stated_Budget`, with the reasons in its comment. It holds only what the tool cannot count. The build adds the counted parts to it and writes the sum as the budget request. A window part names the constant of the size that the process passes to `display.open`, or is a literal.

Example: `MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 3799, processes = 1, threads = 2}`.

The design: `src/md/features/module_budget_request.md`.

Do not use: budget manifest, declared budget.

### Working memory

The working memory is the pages that a process chooses to use: its tables, its caches, the budgets of its children, a stack of another size, its page tables.

It is the part `working_memory_pages` of a stated budget. It holds what no file of the build shows. A table in the data of the module is not working memory: the tool counts it with the module.

Do not use: heap, scratch memory.

### Counted part

A counted part is a part of a budget request that the tool computes from the files of the build: the module pages, the thread pages and the window pages.

The module pages are the memory size of the module and of each module that it imports. The thread pages are a stack and a thread area for each thread: 72 pages for the first one, with the context and the own log ring of the process, and 19 for each other one. The window pages are the two pictures of its window. A counted part changes with a build, with no change of the source.

The design: `src/md/features/module_budget_request.md`; the guide: `docs/MODULE_CONTRACT.md`, "The budget that a module asks for".

Do not use: overhead, estimate, automatic budget.

### Least budget

The least budget is the budget that a starter gives to a module that asks for nothing, and for each part of a budget request that is 0.

The least budget of the root service is 2048 pages, one process and one thread (`LEAST_BUDGET` in `src/modules/system/root/budgets.odin`). A module whose request is smaller gets its smaller request: the least budget fills a part that the module does not state, it is no floor.

Do not use: default budget, minimum budget.

### Largest budget

The largest budget is the most that a starter gives to one process for each part of a budget request.

A part above it starts the process with the largest budget of that part, and the starter writes one line on the log. The largest budget of the root service for a process of the boot image is one share of the pages and of the threads of the machine, a quarter unless the plan of principal 0 gives another share, never less than 16384 pages and 32 threads, with 8 processes (`module.largest_budget_of_machine`). A disk process, and a module of another project, has a smaller one, 16384 pages, one process and 4 threads; one stated budget of 32768 pages, 4 processes and 16 threads pays all of them together (`src/library/modus/disk_process/budget.odin`).

Do not use: maximum budget, cap, ceiling.

### Budget exception

A budget exception is a row of a starter that gives one process, by its name, other limits in time, with the reason beside it.

A row gives a limit in time that a request cannot hold: the root service has one, a limit of processor time (`processor_exceptions` in `src/modules/system/root/budgets.odin`), and one table of limits of log records. No row gives pages: the largest budget is the share of the machine for each process. The name of a disk process never selects a row: a name gives nothing.

Do not use: budget override, special case.

### Period

The period is the 100 ms in which the kernel applies the processor limit of a budget.

A thread of a budget that used its part of the period does not run until the next period.

Do not use: window, slice.

### Work budget

A work budget is the budget that the root service takes from the budget of a client at each `Connect`, and gives to the service with the right Spend.

The service pays from it the memory of its work for that client: the call ring, the call region, the connection page, and the tables of the connection. Its work thread runs on it, so the kernel counts that time in the client. A spent work budget gives the client `No_Budget` of the unit `Work_Budget`, and changes nothing in the service. At the end of the connection, what it holds goes back to the client. Designed, not built.

The design: `src/md/features/work_accounting.md`.

Do not use: client quota, resource container, donated budget.

### Work thread

A work thread is the thread of a service that runs the calls of one connection, created with the work budget of that connection.

Its time counts in the work budget and in each budget above it, so the limit of the client holds for its own threads and for its work in the service together. A client that spends its time delays only its own calls. A work thread never changes the state that all clients share: it prepares a change and gives it to the shared step. Designed, not built.

The design: `src/md/features/work_accounting.md`, "The work thread".

Do not use: worker, handler thread, borrowed thread.

### Shared step

A shared step is the bounded part of a call that changes the state of all clients, which the thread of the service runs, never a work thread.

A commit of the storage service and a frame of the compositor are shared steps. The service measures the time of each one and adds it to the step debt of its connection, and takes the next step from the connection with the least step debt. So a client that asks for large steps waits behind the clients that ask for small ones, and no work thread holds a lock while its budget runs out.

The design: `src/md/features/work_accounting.md`, "The shared step".

Do not use: critical section, server work, commit queue.

### Grant

A grant is the act that gives a handle to a process, and the record of that act.

A grant is the one way that access grows. The root service records each grant that it makes, by the name of the grant and the process, at the start of the process or at a connection. The console shows the grants of a process (`grants("notes")`) and revokes one (`revoke("kernel_events", "machine")`).

A grant is not a permission in a list that a check reads: once given, the handle is the access, and a revocation ends it.

The rules: `docs/PROPERTIES.md`, "20. No ambient access: the other holes to close".

Do not use: permission, authorization, consent.

### Start grant

A start grant is one thing of the list of what the root service gives a process by its name: a service, a private store, a right of the machine.

The root service takes the start grants of a process from its row of `start_grant_sets` at its start, and keeps them in its start grant set. Each later rule reads them there: the sender of a root ring command, the grant of a connection, the debug access. The list and the number of each start grant are a contract (`src/library/modus/contract/start_grant`). A start grant is not a recorded grant: `Inspect`, `Stop` and `Schedule` are rights of the one recorded grant `machine`.

Example: `debug("notes")` is refused: "the grant Store of the process refuses it".

The design: `docs/TOOLS.md`, "Who can debug which process".

Do not use: capability set, permission, privilege.

### Recorded grant

A recorded grant is a handle, or a connection, that the root service gave a process and can end while the process runs.

The root service records it by the process and by one of eleven names in lower case (`Root_Grant` and `root_grant_names` in `src/library/modus/system/grants.odin`): `log`, `machine`, `image`, `store`, `debug`, `wirings`. `grants("notes")` in the console shows the recorded grants of a process, and `revoke("notes", "store")` ends one: the kernel ends each handle and each mapping that came from it.

A recorded grant is not a start grant, which says what the root service gives a process by its name, and whose name has capital letters (`Store`).

The design: `docs/ARCHITECTURE.md`, "U2. Root service".

Do not use: permission, access right, token.

### Start grant set

A start grant set is what the root service gives a process at its start: its start grants and the terms beside them, kept with the process while it runs.

The root service reads it from the row of the process in the table `start_grant_sets`: its start grants, the services that it can connect to, the blocks of its store, the size of its terminal. Each later rule reads it, never the name. A disk process has the row of its nickname in the disk grant table. A start grant set is not a role: it gives the grants of the roles that its process holds.

Example: the start grant set of `remote` holds Connect, Network, Acts_For_Principal and Remote_Clients, and the nine services that it connects to.

The design: `src/md/api/root_ring.md`.

Do not use: process role, permission set, role (alone, for this).

### Role

A role is a place of the system that one process fills for the others, such as the display, the console, the storage or a device class, named by a member of the enum `Role`.

The set of the roles is closed. The root service gives each role to a role holder, which the plan names, after a check against its role contract. A client gets a connection to the holder in its context, or with `connect(role.display)` when its start grant set holds that right; it never finds the holder by a name.

The design: `src/md/features/roles_and_contracts.md`.

Do not use: service name, interface, well-known name, bus name.

### Role holder

A role holder is the process to which the root service gave a role, for one scope: the machine, a session, one client or one device.

A role has one holder in each scope; the assistive role is the one exception, with several holders at once. The plan names the module of each holder, and the signed image names a default one. The root service checks the module against the role contract before it gives the role, and gives the grants that the role needs. A holder of the display, the input, the console or the assistive role from the disk needs a choice of principal 0, measured into PCR 12. Example: the compositor holds `Display` for the machine.

The design: `src/md/features/roles_and_contracts.md`.

Do not use: provider (for this), implementation, daemon, server.

### Interposed holder

An interposed holder is a role holder that stands between the clients of a role and the holder below it, and fills the same role contract.

A client sees no difference, because it holds a connection to the contract only. The holder forwards each call and record, and adds one function: a filter, an audit, a nesting, a view from another machine. Each handle that crosses it comes from it, so its revocation ends all of them. A holder that adds no function is refused. Each one adds a hop, which is measured.

The design: `src/md/features/roles_and_contracts.md`, "Composition by interposition".

Do not use: proxy, middleware, wrapper, membrane (for this).

### Delegated service

A delegated service is a process to which the root service gives one attenuated class of its own authority, such as the wiring of record outputs or the disk grant tables.

The root service keeps a small core: the making of a process, the origin of each handle, the roles, the start. Each other domain goes to a delegated service, which holds a role and a narrow grant, and which the core checks at its border as any process. It acts only for the principal of its caller. A revocation by the core ends each handle that it gave.

The design: `src/md/api/root_service_split.md`.

Do not use: subsystem, manager, privileged helper, broker.

### Root ring

The root ring is the ring of a process to the root service: the process writes a command record on it, and the root service answers with a completion.

A process receives a root ring at its start only when its start grant set holds a start grant that sends a command (Root_Ring, Connect, Principals, Debugger, Start_Policy); a disk process has none. The root service reads the kind of each record at one border, which refuses a word that names no command, then checks the sender with the table `ROOT_COMMAND_SENDERS`, then runs the command. The commands and their words are the contract `src/library/modus/contract/root_ring`.

Example: `start("clock")` in the console sends `Root_Command.Start` with the name `clock` on the root ring of the console.

The design: `src/md/api/root_ring.md`.

Do not use: control socket, init channel.

### Nickname

A nickname is the name that the principal gives a disk process: the name of the entry of its module file in the store `module_files`.

The principal chooses the nickname, and the file never does. The root service names a disk process by its nickname, and the log writes the hash of the file beside it; its window has the nickname as its title. The store of a disk process is attached to its nickname, so a new version under the same nickname keeps its data. A nickname gives no grant by itself, and it is not the name of a module of the boot image.

Example: `allow("visitor", "store")`, then `start_from_disk("visitor", "")`.

The design: `docs/MODULE_CONTRACT.md`, "The grants of a disk process".

Do not use: alias, pet name, display name.

### Hash prefix

The hash prefix is the first 16 hexadecimal digits of the hash of a module file: the first 8 bytes of the hash, the first byte first.

The menu of the windows and the palette show it faded beside the nickname of a disk process, and the monitor under it, so that a reader tells two files under one nickname apart, and a nickname that only looks like the name of a process of the system from that process: `store_importer 5f0c1a2b9e3d4f60`. The hash prefix is a help, not an identity: the root service checks the whole hash of the command before a start, and its line on the log writes all 64 digits.

Do not use: short hash, abbreviated hash, fingerprint.

### Disk process page

The disk process page is one page that the root service writes and maps read-only, at its fixed range, into each process that it starts with the right Inspect of the machine: one row for each disk process that runs, with its process slot, its process serial, its nickname and the whole hash of its file.

The monitor reads the process slot and the process serial of each process from the kernel, and finds in the page which processes the root service started from a disk, with the hash that it checked: its window shows the hash prefix, and `monitor.processes()` gives the whole hash. A row names a process by its slot and its serial, not by its name. The page gives no handle and no right to act. It is not a list of the processes: the reports of `Inspect` list them.

The design: `docs/MODULE_CONTRACT.md`, "The grants of a disk process".

Do not use: program table, origin page.

### Disk grant table

A disk grant table is the table of the root service that binds each nickname of one principal to the hash of one module file, with the grants of that file.

The root service keeps one disk grant table for each principal. `allow` and `disallow` change the grants of a row, and each start of a disk process reads it: a row with another hash refuses the start, and the grants of the row are the grants of the start. It persists under a key of its principal, with a keyed BLAKE2b tag; a table whose tag fails gives no grant. Principal 0 keeps its chosen start policy there. It is not the table `start_grant_sets` of the boot image.

The design: `docs/MODULE_CONTRACT.md`, "The grants of a disk process".

Do not use: permission table, access list, manifest.

### Powerbox

The powerbox is the path by which a running process asks for a grant, the principal answers on the trusted display, and the root service gives reduced, revocable handles.

A process with a window writes a grant request on its grant request ring. The root service checks it at one border, merges the requests of one process into one grant dialog, and gives the dialog to the trusted display. It makes a handle for each item that the principal kept, with the rights kept, and records it as a requested grant. The asker never draws the dialog and never sees the candidates of a picker.

The design: `src/md/features/powerbox.md`.

Do not use: permission prompt, consent dialog, UAC.

### Grant request

A grant request is the typed record in which a process asks the powerbox for 1 to 16 grant items at once.

The process writes the items in its grant request region and sends `Ask` on its grant request ring. The border refuses a kind, a rights word or a reason that names no member, an object that the kind does not take, and a scope of wide authority. The answer is one record that gives, item by item, the outcome, the rights given and the handles. A grant request holds no text that the principal reads.

The design: `src/md/features/powerbox.md`, "The grant request".

Do not use: permission request, intent, scope string.

### Grant item

A grant item is one line of a grant request: the kind of one object, the object or a choice of the principal, the rights asked, and an optional reason.

The kinds at first are a network endpoint, a store that the principal picks, and a service connection. The reason is a member of `Grant_Reason`, which the trusted display shows as a claim of the process. Two items with the same kind, object and rights are merged into one row of the grant dialog. An item can name a requested grant that the process holds, to ask for more rights on its object.

The design: `src/md/features/powerbox.md`, "The grant request".

Do not use: scope, permission.

### Requested grant

A requested grant is a grant that the root service made from a grant item that the principal kept, recorded by the process and a number.

It lasts for the run of its process, or, for a disk process, always for the hash of its module, in the disk grant table of the principal. `grants("name")` lists the requested grants of a process under the recorded grant `requested`, and `revoke("name", "requested", number)` ends one through `Handle_Revoke`. A requested grant is not a start grant: no role holds it.

The design: `src/md/features/powerbox.md`, "The grant".

Do not use: runtime permission, granted scope.

### Wide grant

A wide grant is a grant of wide authority to one agent: a set of wide scopes with their bounds in time and in place, given after a proof of the principal.

Its holder is a client key of `remote`, later the hash of a module. The trusted display shows the screen of a wide grant, never the ordinary grant dialog, and the passphrase of the principal, typed with the keys of the machine, gives it. While it holds, the mark of wide authority shows in the trusted display; each act under it is an act record. It is never written on the disk.

The design: `src/md/features/wide_grants.md`.

Do not use: full access, admin mode, override, superuser.

### Wide scope

A wide scope is one member of the closed set of what a wide grant can give: the lines of an agent console, the screen, the input, the processes, the log, the stores.

Each wide scope has a boundary that one mechanism enforces: the start grant set of the agent console, the uses of a client key, the input face of the trusted display, the shares of the picked stores. The principal unticks a scope, bounds it in place, and sets it to ask each time. No wide scope changes a grant or answers a trusted surface, and none joins a grant request.

The design: `src/md/features/wide_grants.md`, "The wide scopes".

Do not use: permission, entitlement, OAuth scope.

### Agent console

An agent console is a console that the root service starts for the client key of an agent, whose lines the agent sends and whose start grant set is its reach: the read-only list for a key with the use `Calls`, or the union of the wide scopes that a wide grant kept.

It runs in the session of the principal and reaches only what its start grant set gives: no command that changes a grant, no command of the principals. `remote` carries the lines of the agent into its line ring and reads none. Each line is an act record before it runs. A change of its reach starts a new agent console. It is not the console of the principal, whose start grant set holds each grant of a console.

The design: `src/md/features/wide_grants.md`, "The wide scopes", and `src/md/features/agent_code_mode.md`.

Do not use: agent shell, bot session.

### Assistant

The assistant is the application whose window shows a conversation of the principal with an agent: the requests, the replies, each act that the agent proposes, and its result.

The agent runs on the host as the agent runner; the window keeps the conversation and asks the trusted display for the act dialog. It holds no store and no network. It is not the agent console, which runs the lines of an agent under a wide grant.

The design: `src/md/features/assistant.md`.

Do not use: chatbot, copilot, AI window.

### Agent runner

The agent runner is the command `modustool assistant` on the host: it reads each request of the assistant through `remote`, asks a language model, and runs each act of the model reply through the host agent bridge.

It holds the endpoint and the key of the model, which never reach the machine. It never answers an act dialog: an act that the bridge stops waits for the principal. It is not the bridge, which it calls as any agent does.

The design: `src/md/features/assistant.md`, "Four parties".

Do not use: bot, daemon, agent server.

### Model reply

A model reply is the one JSON object that a language model gives to the agent runner: the words for the principal and up to four acts.

The runner reads it at one border before any act runs, and refuses a reply with an unknown, missing, duplicated or mistyped field, or a text past its bound, whole, with an error record that the window shows. It is not an act record.

The design: `src/md/features/assistant.md`, "The model reply".

Do not use: completion, response, output.

### Act dialog

The act dialog is the dialog of the trusted display that asks the principal to allow once or to refuse one act of an agent, named `service.export`.

The asker is the process that called `compositor.act_ask`, which the trusted display reads from the connection; the act is two identifiers that it checks, never a word of the agent. Its focus starts on Refuse, as the dialog of a plan; a move of the focus counts only after the arm time and starts it again. Its decision goes to its asker only, and it closes with a refusal when its asker exits. It is not the grant dialog of the powerbox.

The design: `src/md/features/assistant.md`, "The act dialog".

Do not use: confirmation popup, approval prompt.

### Right to ask an act

The right to ask an act lets a process ask the trusted display for an act dialog, and for nothing else that serves the principal.

It is the term `asks_acts` of a start grant set; the root service writes it as the amount `DISPLAY_AMOUNT_ACT_ASKER` of the grant of a connection to the holder of Display. The assistant holds it in place of the grant to act for the principal, which would open each export of the trusted display that serves the principal. It is not a start grant, and it opens no dialog of a plan.

The design: `src/md/features/assistant.md`, "The right to ask an act".

Do not use: act permission, approval right.

### Act record

An act record is the record of one act done under a wide grant, written on a record output before the act runs.

The root service, the agent console, `remote` and the trusted display each write the acts that they do for the agent, and the collector keeps them in a space that the agent cannot read or erase. A writer that finds its ring full refuses the act, so no act runs without its record. The principal reads them with `acts(key)`. An act record is not a log fact, which the log can lose.

The design: `src/md/features/wide_grants.md`, "The record of each act".

Do not use: audit log, activity log.

### Authority key

The authority key is the secret key of 32 bytes of one principal under which the root service tags the proof of each wide grant of that principal, and with which the collector of that principal checks it.

The root service makes a fresh key of the run at each start, from a seed of the strength `Processor` at least, makes from it the key of each principal, and erases it. It gives the collector of a principal the key of that principal only, in four values of its context, which the collector erases after it reads them. No disk keeps it, so a proof of one start gives no grant after a restart. A collector with no key, or with the all-zero key, refuses each wide grant. It is not the signing key of a principal.

The design: `src/md/features/wide_grants.md`, "The deliberate act: the proof of the principal".

Do not use: grant secret, collector key.

### Agent step

An agent step is an ordered list of 1 to 16 console lines of Lex that an agent sends at once, and that its agent console runs, each to its typed result.

A line can bind a name, which the later lines and steps of the same request read. The step ends at its last line, at the first line that fails, or at a bound: its calls, its time, its result size. A call that asks the principal holds the step until the answer. Each step, line and call is an act record. It is not a text that a process gives another process to parse: the agent writes it, and only the agent console reads it.

The design: `src/md/features/agent_code_mode.md`, "The language of a step: Lex, run by an agent console".

Do not use: code mode (for this), script, agent program, tool call.

### Agent loop

An agent loop is the series of agent steps that one request of the principal becomes, each written by the agent after it read the typed results of the step before.

It ends at the final answer of the agent, at a bound of 16 steps, at a step that repeats the step before, at a stop of the principal, or at the end of the reach. Its end cause is one member of a closed set, which the window of the agent shows once. It is not a loop of Lex: Lex has no loop.

The design: `src/md/features/agent_code_mode.md`, "The loop".

Do not use: agentic loop, ReAct loop, iteration (for this).

### Guest

A guest is a machine that a process of the system runs on the processor, with the virtualization support of the processor, and with its own kernel and its own processes.

A guest holds only what its process was granted. It is a process that `Process_Create` made and that no thread ran: its addresses are the guest physical addresses, and `Memory_Map` with its handle gives it memory. The process that holds it runs its guest processor with `Guest_Run`, and answers each guest exit. A foreign system (Linux) runs in a guest, and its concepts stay inside it. Built: the AMD form, up to 32 guest processors for each guest; the process `guest_demo` runs a guest of seven bytes.

The design: `docs/ARCHITECTURE.md`, "A guest", and `docs/PROPERTIES.md`, "Objective".

Do not use: virtual machine, VM, container.

### Guest processor

A guest processor is the processor of a guest, as the kernel keeps it between two runs: its registers, its segments, its control registers and its extended state.

A thread runs it with `Guest_Run`: during the operation, the thread is the guest processor, and its budget pays the time. The general registers, `rip`, `rflags`, the control registers, the 64-bit system state (the targets of `syscall` and the bases of `fs` and `gs`) and the interrupt shadow go in and out in a `Guest_Registers` record of the caller; the kernel keeps the rest in the control block of the processor. One thread runs a guest processor at a time; a guest has up to four, which several threads run at once.

The design: `docs/ARCHITECTURE.md`, "A guest".

Do not use: vCPU, virtual processor.

### Guest exit

A guest exit is the moment when a guest processor stops and the kernel gets the processor back: an instruction that the guest may not run alone, an access to memory that no mapping allows, or an interrupt of the machine.

The kernel handles one exit itself: a page on first use. Each other exit ends `Guest_Run`, and its completion record says what it was (`Guest_Exit_Kind`): a port write with its port and its value, a port read, `hlt`, `cpuid`, an access to memory, an interrupt, the interrupt window that a waiting interrupt asked for. The process answers it with a change of the registers record, then runs the guest again.

The design: `docs/ARCHITECTURE.md`, "A guest", section 3.

Do not use: VM exit, world switch.

### Interrupt window

An interrupt window is the moment when a guest processor takes interrupts again: its interrupt flag set, and out of the shadow of `sti` or `mov ss`.

`Guest_Run` delivers an external interrupt that its record asks for only at such a moment: the processor would deliver it with no check, into code that `cli` protects. When the guest takes no interrupt, the kernel asks the processor for a virtual interrupt and intercepts it; the run then ends with the exit `Interrupt_Window` as soon as the guest takes interrupts, and the next run delivers the request. It is not an interrupt of the machine, and the guest receives nothing at that exit.

The design: `src/md/features/guest.md`, "The interrupt window".

Do not use: IRQ window, VINTR window.

### Nested page table

A nested page table is the page table that translates the guest physical addresses of a guest to the memory of the machine.

The processor walks it for each access of a guest, after the page table of the guest itself. The nested page table of a guest is the page table of its process: a mapping of a memory object in that process is guest memory, and an unmap or a revocation takes it away.

The design: `docs/ARCHITECTURE.md`, "A guest", section 1.

Do not use: extended page table, EPT, second-level table.

### Console line

A console line is the line that a Linux guest writes now on its serial port, as the process that runs the guest keeps it: its text and a cursor.

The process `linux` turns the bytes of the serial port into lines with it (`guest_os.Console_Line`): a line that ends goes to the terminal and to the log, and the line that does not end yet is the edit line of the terminal. It reads the few sequences of the line editing of a shell and drops the others, so no escape sequence of the guest reaches a process of the system. It is not a terminal emulator: it keeps one line, not a screen.

The design: `src/md/features/linux_shell.md`, "The console line".

Do not use: tty, pty, terminal emulator.

### Initial archive

An initial archive is an archive of files in the cpio form that the process of a Linux guest places in the memory of the guest beside the kernel, and that Linux unpacks as its first tree of files.

It is a concept of the foreign system, inside its guest only: Linux finds it through its zero page, and runs its `init` from it when no disk holds one. The process places it at the top of the memory of the guest, above the kernel (`linux_boot_prepare` in `modus:contract/guest_os`). The spec of a guest build names it by its BLAKE3 hash, which the guest builder checks on its copy in the guest before the boot. It is not the boot image of the system, which no guest sees.

The design: `src/md/features/foreign_systems.md`, "The machine of a Linux guest".

Do not use: initrd, initramfs, ramdisk.

### Driver domain

A driver domain is a guest that owns one device and serves it to the system; it is not built yet.

The device reaches only the memory of that guest, so a driver of another system can serve a device with no access to the rest.

Do not use: passthrough, driver VM.

### Holding

A holding is a handle or a mapping of a process: one thing that the process has of an object.

The kernel keeps the origin of each holding, so that a revocation reaches each handle and each mapping that came from a handle, in any process.

Do not use: reference, capability.

### Origin

The origin of a holding is the handle that it came from.

A handle that `Handle_Give` made came from the handle that was given. A mapping came from the memory handle that was mapped. A holding that the kernel made has no origin. When a handle closes, what came from it comes from its own origin, so the chain stays whole. The kernel keeps the origins in one table under the origin lock.

Do not use: parent, derivation, delegation chain.

### Revocation

A revocation is the act that ends each holding that came from a handle, in one process or in each process (`Handle_Revoke`).

A revocation makes a grant temporary: what a process gave, it can take back, through each chain of gifts. The handle that revokes stays. A process that lost a holding gets an event and cannot refuse; a thread that uses memory that its process lost stops its process on a page fault. A revocation ends holdings, not objects: an object that a process made with a budget handle lives on after the handle is revoked.

Example: `revoke("kernel_events", "machine")` in the console ends the machine handle of `kernel_events`.

The design: `docs/ARCHITECTURE.md`, "Rules that keep each path correct".

Do not use: recall, invalidation.

### Lent handle

A lent handle is a handle that a caller gives to a callee for the time of one call.

The description of an export names the rights that it needs on each Handle parameter. The caller gives the callee a handle that comes from a copy of its own handle with these rights only, and revokes the copy after the call (`system.lend`, `system.lend_end`). The callee proves the handle with `Handle_State` before it uses it. The caller keeps its own handle. A mapping that the export kept for later ends with the revocation, and its next use stops the process of the callee.

The design: `docs/MODULE_CONTRACT.md`, "Records and handles, as implemented".

Do not use: borrowed handle, loan, passed capability, inherited descriptor.

### Ambient access

Ambient access is access that a process has because it runs, and not because it received a handle.

The system has none: a process with no handle can compute and stop, and reach nothing. Each new interface passes one test: "can a process with zero handles use it?" If yes, the interface is a defect.

The rule: `docs/PROPERTIES.md`, "20. No ambient access: the other holes to close".

Do not use: ambient authority.

### Sandbox

A sandbox is the state of every process: it can reach only the objects of its handles.

The sandbox is not a mode that a process enters: it is how each process starts, with the handles of its context only.

The rule: `docs/PROPERTIES.md`, "2. Sandbox by default".

Do not use: jail, container.

### Principal

A principal is a key pair and the root handles that the key unlocks: documents, grant records, settings.

A principal answers "for whom does this run" without users. The kernel does not know it: the answer to "who executes" is always a process with its handles. The root service names each principal by its number, and records the principal of the session of each process that it starts; the storage service gives each principal its own stores. Principal 0 is the machine: the processes of the system belong to it, and it does not see the stores of a named principal.

The design: `docs/PRINCIPALS.md`, "2. Principal 0: the machine".

Do not use: user, account, owner, root, administrator, executor, person, publisher.

### Named principal

A named principal is a principal with a number of 1 or more: a name for display, an Ed25519 key to sign grants, an X25519 key to unlock documents, and a passphrase.

The process `unlock` keeps its record in its own store; the two secret keys are sealed with ChaCha20-Poly1305 under a key that Argon2id derives from the passphrase. `principal_create("name")` in the console makes one.

The design: `docs/PRINCIPALS.md`, "3. A named principal".

Do not use: user account, login.

### Session

A session is the tree of processes that started from the root handles of one principal.

The root service records the principal of each process that it starts: 0 for the processes of the system, the named principal that is unlocked for a process that the desktop starts, and the principal of the asking process for a process that a process starts. The log says it: "root: started notes, in the session of principal 1 "alice"". The principal of the session names the stores of the process. A process of the session with the grant to act for the principal acts for that principal only.

The design: `docs/PRINCIPALS.md`, "5. The session".

Do not use: login, user session.

### Unlock

The unlock is the act that starts the session of a named principal: Argon2id derives a key from its passphrase, and that key opens the seal of its secret keys.

A wrong passphrase gives another key, and the seal does not open: no passphrase and no hash of a passphrase is kept or compared. After the unlock the process `unlock` tells the root service, which starts the session, and gives it the key of the tag of the disk grant table of the principal, which keyed BLAKE2b derives from the unlock key. Then it erases the secret keys.

The design: `docs/PRINCIPALS.md`, "4. The unlock and the lock".

Do not use: login, sign in, authentication.

### Lock of a session

The lock of a session is the act that ends the session of a named principal: each process of the session stops, and an unlock is needed again (`lock()` in the console).

The processes stop; they are not frozen. A process that keeps its state in its store at each change loses nothing. The lock also stops the window of `unlock` that the session asked for (a change of the passphrase, a machine passphrase, a seal of the machine key), so nobody at the locked machine reads its recovery key; such a window writes nothing before Enter, so the stop loses no recovery key (`PRINCIPALS.md`, "4. The unlock and the lock"). The lock of a session is not a lock of memory.

Do not use: log out, sign out.

### Passphrase

A passphrase is the text that derives the key of the seal of a named principal: 8 to 128 bytes of UTF-8 with no control character.

It is typed in the window of `unlock` only, shown as dots, and kept nowhere. It is never a text of the console, which keeps each line in its history. When the TPM seals the keys of the principal, the passphrase also gives the authorization value of the sealed object, so the TPM counts each wrong one.

The design: `docs/PRINCIPALS.md`, "The passphrase".

Do not use: password, PIN.

### Change of the passphrase

A change of the passphrase is the act by which a named principal, in its session, proves its current passphrase in the window of `unlock` and has its keys sealed again under a new passphrase, or under a new recovery key.

A console of the session asks with `passphrase_change()` or `recovery_key_change()`; the console of the machine cannot. The current passphrase opens the keys as an unlock does. The keys themselves do not change. After the write, `unlock` erases the versions of the file, so the old passphrase and the old recovery key open nothing that the storage service reads on the disk; a copy of the disk made before the change still opens with them. A lost passphrase is not changed this way: the recovery key replaces it.

The design: `docs/PRINCIPALS.md`, "A change of the passphrase".

Do not use: password reset, password change.

### Machine passphrase

A machine passphrase is an optional passphrase of principal 0, the machine, that guards the machine key.

It has the rules of a passphrase, and it is typed in the window of `unlock` only: two times after `machine_passphrase()` in the console, then at each start of the machine. It opens no session: principal 0 stays the machine. With a machine passphrase, the disk grant table of principal 0 persists, and until the passphrase is typed the disk processes of principal 0 start with no grant. With the TPM service and Secure Boot on, the TPM seals the machine key with it and counts each wrong one.

The design: `docs/PRINCIPALS.md`, "Principal 0 and its machine passphrase".

Do not use: admin password, root password, master password.

### Machine key

The machine key is a key of 32 random bytes of principal 0 that signs its disk grant table.

The record of the machine key holds it in one of three forms: sealed under the machine passphrase alone (`MACHINEK`), sealed by the TPM with the machine passphrase (`MACHINEP`), or sealed by the TPM with no passphrase (`MACHINET`, after `machine_seal()`). `unlock` opens it, and gives the root service only the key of the tag of the table, which keyed BLAKE2b derives from the machine key: the root service cannot open a seal with it. The machine key is not the attestation key of the TPM.

The design: `docs/PRINCIPALS.md`, "Principal 0 and its machine passphrase".

Do not use: master key, device key.

### Acts for the principal

Acts for the principal is a grant of the root service (`acts_for_principal`): in each service that the process is connected to, it sees what the service holds for all callers, for the principal of its session.

Without it, a caller of a service sees only its own data. The console and the remote service have it; `revoke("remote", "acts_for_principal")` ends it, and the next call is refused. The grant travels in bit 63 of the grant of each connection (`isolated.CALLER_ACTS_FOR_PRINCIPAL`). A connection of the remote service acts for the principal of the client key that it is for, not for the session of the remote service.

The design: `docs/PRINCIPALS.md`, "5. The session".

Do not use: superuser, privileged, person.

### Client key

A client key is the Ed25519 public key that a client of the remote service or a viewer of the remote display proves in the QUIC handshake, and that a principal allows for its uses.

The client sends it as a raw public key, with a CertificateVerify signed by its private key (mutual TLS 1.3). A principal allows it from a console that acts for it, with `remote_allow(key)` or `remote_display_allow(key, use)`, and ends the grant with `remote_disallow(key)`. One key belongs to one principal, and the disk grant table of the principal keeps it across a restart. A key that no principal allowed is refused in the handshake, before any call. It is not the key of the server of `remote`.

The design: `docs/PRINCIPALS.md`, "The client keys of remote".

Do not use: client certificate, API key.

### Client table

The client table is the page in which the root service keeps each client key that a principal allowed, with that principal and a serial; the remote service reads it and never writes it.

Each row is one grant (`remote.Client`), and its serial names that grant: a new row, a lock and an unlock of the session of its principal each give a new serial, and the connections that the root service made for the row end when the serial changes. The remote service maps the table with the right Read only, by its start grant `Remote_Clients`, and waits on its version. The table lasts until the machine stops; the disk grant table of each principal keeps its keys across a restart.

The design: `docs/PRINCIPALS.md`, "The client keys of remote".

Do not use: allow list, access list, key ring.

### Use of a client key

A use of a client key is one of the three things that its row allows: Calls through `remote`, View of the screen through `remote_display`, and Input of keys and of the pointer.

A row holds a set of uses (`remote.Client_Uses`), carried as a word that one border reads; it refuses an unknown bit, no use, and Input without View. `remote_allow` gives Calls; `remote_display_allow` gives View, or View and Input. An allow adds uses and keeps the serial; `remote_disallow` ends them all. Only Calls lasts across a restart.

The design: `src/md/features/remote_display.md`, "The authority".

Do not use: scope, permission, role.

### Machine identity key

The machine identity key is the Ed25519 key pair of principal 0 whose public key names the machine to other machines.

Its seed is keyed BLAKE2b of the machine key, so the TPM roots it where the machine key is sealed by the TPM, and the recovery key of the machine key opens it too. The root service holds the secret key and signs only the CertificateVerify of a handshake for `remote`, which presents the key as its server key. It is not the machine key, a client key, or the attestation key of the TPM. Designed, not built.

The design: `src/md/features/several_machines.md`, "The identity of a machine".

Do not use: host key, node key, device key, machine certificate.

### Pairing

Pairing is the explicit act by which a principal makes two machines know each other's machine identity key, with the uses that each gives the other.

The principal shows a pairing code on one machine with `machine_pair()` and gives it to the other with `machine_join`. Each machine then writes the row of the other in its client table, for that principal, after the principal accepts it there. No machine finds another in any other way: no broadcast, no directory. A pairing gives no grant on the other machine; the plan of the principal on each machine does. Designed, not built.

The design: `src/md/features/several_machines.md`, "Pairing, and no discovery".

Do not use: discovery, enrolment, bonding, trust on first use.

### Pairing code

A pairing code is a secret of one use, with an address, that one machine shows in the window of `unlock` and that the principal gives to the other machine.

It holds 50 bits as ten groups of base32, and a QR code holds the same with the whole identity key. The two machines run the PAKE CPace over Ristretto255 over the TLS exporter of their connection with it, so both prove the same code and bind it to both identity keys. One wrong code ends the pairing on both sides, and a code ends 10 minutes after it was shown. Designed, not built.

The design: `src/md/features/several_machines.md`, "Pairing, and no discovery".

Do not use: invitation, token, PIN.

### Paired machine

A paired machine is another machine whose machine identity key a principal allowed on this machine by a pairing, as a row of the client table with its uses.

`remote` accepts it in the handshake, and each connection that the root service makes for its row acts for the principal of the row, as for a client key. It is an object cache of this machine, the holder of a remote role, or a machine with which a store is exchanged, each only when the plan of the principal says so. `remote_disallow` ends it on this machine; `machine_remove` ends it on every machine of the principal. Designed, not built.

The design: `src/md/features/several_machines.md`.

Do not use: peer (for this), node, device, remote host, cluster member.

### Machine list

The machine list is the record that the principal root key of a principal signs: for each of its machines, the identity key of the machine, the public signing key of the principal there and its uses, and a number that only grows.

Each machine of the list keeps the newest list that it has seen and refuses a lower number, and its root service derives from it a row of the client table for each other machine. So a join on one machine of the list reaches all of them, and a lost machine is removed by a new list that the root key signs on any other. It has the form of a release pointer. Designed, not built.

The design: `src/md/features/several_machines.md`, "A principal across machines".

Do not use: device list, roster, keyring.

### Principal root key

The principal root key is the Ed25519 key pair whose public key is the identity of a principal across its machines, and whose secret key stays on no machine.

It signs the machine list: the keys that the principal has on each machine, which each machine makes and seals with its own TPM. The principal brings it to a machine for a join or a removal, from a removable disk or a recovery text, and takes it away after the act. So the theft of one machine never gives it, and a stolen machine is removed with no change of the identity. It is not the signing key of the system, and not a key of a machine. Designed, not built.

The design: `src/md/features/several_machines.md`, "A principal across machines".

Do not use: master key, primary key, account key.

### Signed grant

A signed grant is a record that the signing key of one principal signs for the principal root key of another principal: one object or one role of a machine of the giver, an end time, and a grant serial.

The machine that serves it checks the signature against the machine list of the giver, the key of the receiver against the machine list of the receiver, the end time and the revocation list of the giver, then makes a connection for the receiver. A grant has a short life of at most one day, or names a revocation list. The receiver cannot give it on. Designed, not built.

The design: `src/md/features/several_machines.md`, "Sharing between two principals".

Do not use: token, capability token, invitation, certificate.

### Remote role

A remote role is a role whose holder runs on a paired machine, and which `remote` fills on this machine as an interposed holder.

`remote` carries each call and record of the contract over QUIC to `remote` on the paired machine, which connects to the real holder for this machine's row. Only calls and records cross: a face that lends memory or carries a handle does not. A call with no answer gets `Connection_Ended_During_The_Call`; a call while the link is down gets `Callee_Unavailable`. The call frames and proxy are built (`modus:contract/machine_wire`); connecting to the real holder is not.

The design: `src/md/features/several_machines.md`, "A role held on another machine".

Do not use: proxy, stub, remote service (for this), mount.

### Mesh frame

A mesh frame is the request or the answer of a protocol between paired machines, on one stream of a connection to `remote`.

The first word of the stream is the word of `Request_Kind.Mesh`, so a stream carries either a call request of a client or a mesh frame, never both. The frame names its message: a pairing step, an object by hash, a signed grant, a store exchange, a role call, or a relay envelope. The answer is one frame, or a refusal with its reason. The identity key of the sender comes from the handshake, never from the frame.

The design: `src/md/features/several_machines.md`, "The frames on a stream of remote".

Do not use: packet, message (alone), mesh request.

### Outbound link

An outbound link is a QUIC connection that `remote` opens to a paired machine, whose handshake pins the identity key of that machine.

It is the other direction of the mesh frames: this machine sends the requests (an object by hash, a role call, a store offer, the two pairing steps of the joiner) and the other machine answers. The link refuses a handshake that proves any other key. Each request ends with a call outcome: in doubt when it left and lost its answer, `Callee_Unavailable` when the link was not up. It is not a grant: the other machine still checks the uses that its plan gives this machine.

The design: `src/md/features/several_machines.md`, "The outbound link".

Do not use: dial, client connection (alone), tunnel.

### Relay envelope

A relay envelope is a datagram that a relay machine carries between two machines: a routing token and the sealed bytes, which only the two ends open.

The two ends seal the datagram under a key that they share, with the routing token as associated data. The routing token is a keyed hash of that key and an epoch, so the envelope adds no identity key and the relay cannot link two epochs. The relay is a paired machine of the principal; it keeps an envelope only for a route that its principal added, only from the sender of that route, and gives it back byte for byte to its receiver.

The design: `src/md/features/several_machines.md`, "The relay envelope".

Do not use: tunnel, relay packet, forwarded frame.

### Input

Input is the keys and the pointer, as the system receives them.

A text that describes an act at the desktop names the input or the act ("Space is pressed"), not who acts: the system knows processes and principals, not people.

Do not use: user, person.
