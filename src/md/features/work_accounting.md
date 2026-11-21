# Work accounting: a service charges its work to the client

A shared service does work for many clients: the storage service commits, the compositor composes, the log service reads the log, `recipes` hashes the inputs of a recipe. Today that work is paid by the budget of the service. So a client that calls in a loop, or that asks for the largest change each time, spends the memory and the processor time of the service, and every other client waits or gets `Full`. This file designs the charge of that work to the client: the memory that the service uses for one client comes from a budget of that client, and the processor time of its work counts in that budget. An abusive client exhausts itself, not the service.

## The constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller": whoever asks for work gives the memory for it, and whoever creates an object pays for it.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", line 16: a process does not consume all memory, processor time or storage. Each resource is a handle with a limit, and a process divides its limit among its children.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "1. Small kernel with a small, counted interface", and "5. Kernel off the data path": a call between two processes needs no kernel entry, and the kernel does not learn where a call starts and ends.
- **The budget model of the kernel.** `Memory_Create`, `Thread_Create` and `Process_Create` take a budget handle with the right Spend. `Budget_Create` moves pages, process slots, thread slots and log records to a new budget. The time of a thread counts in its budget and in each budget above it, and the limit of each holds in each period of 100 ms. When the last handle of a budget closes, what it holds goes back to the budget that it came from (`Budget_Amounts` in `src/library/modus/contract/operation/operation.odin`).
- **A service never stops or stalls for one client.** A refusal of one client is an error record for that client; the other clients see nothing ([supervision.md](supervision.md), "The subtle points").
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "23. A role is a contract; its implementation is replaceable": each shared service is the holder of a role, and a role contract is the place to say what a client pays.

## Where a client can exhaust a shared service today

- **The places of the storage service.** One table of 512 places serves every connection (`PLACE_CAPACITY`, `src/modules/system/storage/main.odin:60`). `open` refuses with `Full` when no place is free (`src/modules/system/storage/main.odin:488`). One client that opens 512 places makes each `open` of every other client fail.
- **The pending blocks of the storage service.** The pending changes of every connection share 1024 blocks and 16 objects (`PENDING_BLOCK_CAPACITY` and `PENDING_OBJECT_CAPACITY`, `src/modules/system/storage/ranges.odin:24`). One client whose `write_range` calls hold 1024 blocks leaves no pending block for any other client.
- **The one thread of a service.** `service_run` takes every call that waits on one connection, up to the capacity of the ring, before it reads the next connection (`src/library/modus/system/service.odin:157`). A client that fills its call ring with commits of 4096 blocks (`WRITE_CAPACITY`, `src/modules/system/storage/engine.odin:586`) holds the thread of the storage service, and the time of those commits counts in the budget of the service.
- **The call ring and the call region of each connection.** The root service makes both from its own budget (`connect` and `connection_open`, `src/modules/system/root/main.odin:1725` and `:1836`): 16 pages of region and the pages of the ring for each connection. The bound of 8 connections for each service (`SERVICE_CONNECTION_CAPACITY`, `src/library/modus/contract/isolated/isolated.odin:155`) limits the sum, but the client does not pay.
- **The compositor** is better placed. A window ring gives one turn of the records that it holds at the start of the turn (`src/modules/system/compositor/main.odin:840`), each surface is memory of the client ([window_resize.md](window_resize.md)), and each glyph is drawn and kept by its own process ([glyphs_on_demand.md](glyphs_on_demand.md)). What stays is the time of the composition: a window that presents its whole surface at each frame makes the compositor copy it, and that time counts in the budget of the compositor.
- **The log service** is better placed too. The log records of each second are an amount of the budget of the writer ([log_side_channels.md](log_side_channels.md)), and a follow ring is paid by its asker ([module_outputs.md](module_outputs.md)). What stays is the time of a read: a reader that asks for the whole log again and again spends the time of the log service.
- **`recipes`** is designed, not built ([recipes.md](recipes.md)). A builder is its own process with its own budget, which bounds the store "out". The work of the service itself for one client (the hash of each input, a fetch from the object cache) has no payer yet. It is the first service that takes the form below from its start.

## The three forms compared

**1. The client gives the pages to work in.** This is property 14 as it is built for a result: the call region, and a table in a memory object that the client lends. It holds for the result of a call. It does not hold for the working state of a service: the places of a connection, the pending blocks, a cache line of the index of the hashes. That state outlives one call and is read by the code of the service. A lent memory object can be revoked during a call, and the fault in the export then stops the service for every client; this is why a service refuses a table in a lent memory object today (`export_serve`, `src/library/modus/system/service.odin:275`). And it gives nothing for time.

**2. A budget handle that the client lends.** The service creates the memory of its work for that client with the budget of that client. The kernel then counts each page, and a spent budget gives `No_Budget` to the service, which turns it into an error record for that client. With `Thread_Create` on the same budget, the time of a thread of the service counts in the budget of the client too. This needs no new kernel operation. Lent with each call, it costs a give and a proof of the handle for each call, which a call does not need today. Lent once for the connection, it costs nothing for each call.

**3. A scheduling context that the client donates, in the way of seL4 MCS** (Lyons, McLeod, Almatary and Heiser, "Scheduling-context capabilities", EuroSys 2018). The kernel runs the thread of the service on the time of the client for the length of one call. The kernel must then see the start and the end of each call: in seL4 the call is a kernel operation. In modus a call is a record in a ring in shared memory, which the kernel never reads (properties 4, 5, 6). Donation needs a new kernel call path for each service call, or a kernel that reads the call rings. It also gives time only, not memory. And a donated context that runs out inside the service stops the service while it holds its shared state, which seL4 answers with a timeout fault and a handler in each server.

**The choice: form 2, lent once for each connection, and form 1 kept for results.** The root service makes a **work budget** for each connection from the budget of the client, and gives it to the service with the right Spend beside the connection. The service pays the memory of its work for that client from it, and runs the calls of that client on a **work thread** that it creates with it, so the kernel counts their time in the budget of the client. A result still goes into memory of the client: the call region, or a table that the client lends to a call host. No new kernel operation is needed.

## The chosen form

### The work budget

At `Connect`, the root service calls `Budget_Create` on the budget of the client, which it holds with Read and Spend already for the wirings of the client ([module_outputs.md](module_outputs.md), "The budget"). The new budget holds:

- **pages**: the work pages of the connection, which the role contract of the service states (a base for the call ring, the call region and the connection page, and a part for the working state), or the amount that the client asks for in its `Connect`, between a least and a largest amount of the contract;
- **one thread slot**, for the work thread;
- **a processor limit** equal to the limit of the client: the time of the work thread counts in the work budget and in each budget above it, so the limit of the client holds for its own threads and its work in the service together;
- **no process slot and no log records**: the service writes its lines with its own log records, and a client cannot fill the log of the service.

The root service gives the work budget to the service in the record `Connect`, beside the call ring and the call region, and keeps its own handle. The call ring, the call region and the connection page ([supervision.md](supervision.md), "What a client sees when the holder of its role stops") come from the work budget too, so the root service no longer pays for a connection.

**The end.** At `Disconnect`, the service ends the work thread and each memory object of the connection, then closes its handle of the work budget. The root service closes its own. What the budget holds goes back to the budget of the client. An object that the service forgot to end stays paid by the budget of the client, as the kernel rule says, and the next count of the client shows it: a leak of the service is visible in the report of the client that caused it, and it never reaches another client.

**The client cannot take it back.** `Budget_Create` moved the pages, and the client holds no handle of the work budget. It can stop using the connection, or `disconnect`; it cannot revoke the pages that the service holds while a call runs.

### The work thread

The service creates one work thread for each connection, with `Thread_Create` on the work budget, so the thread is created on the budget of the client. The work thread runs the calls of that connection, in their order. Its stack and its thread area are pages of the work budget. It costs one thread slot of the client and 19 pages of its budget, so a client with eight connections pays eight: the cost is the client's, and it pays it at the `Connect`, never at a call.

- **Time.** The kernel counts each run of the work thread in the work budget, in the budget of the client and in each budget above. A client that spends its time spends the time of its own calls. Its work thread waits for the next period, and every other work thread and the thread of the service run.
- **Memory.** The work thread makes the working state of the connection with the work budget: its places, its pending blocks, its arenas ([memory_without_a_bound.md](memory_without_a_bound.md)). A table of the service for all connections, such as the 512 places, becomes a table for each connection, sized by the work budget of that connection.
- **A service with no private work** runs no work thread. Its calls have no part that one client alone needs: an append of a record, a read of a small page. Only its memory then comes from the work budget, and its time is a shared step (below).

### The shared step

Some work changes the state that all clients share: a commit of the storage service writes the tree of the disk; a frame of the compositor writes the screen. A work thread must not do it. If the work thread holds the lock of the shared state and its budget runs out, every other client waits for the next period of that client: the stall that this design removes, as a timeout of a donated context does in seL4.

So a call has two parts:

1. **The private part**, on the work thread and the work budget: copy and check the arguments, compute the checksums and the hashes of the blocks, read the blocks that the change needs, and prepare the change as one bounded record in memory of the work budget.
2. **The shared step**, on the thread of the service: apply the prepared change to the shared state, in one bounded step. For the storage service the bound is the commit: at most 4096 written blocks.

The work thread gives the prepared change to the thread of the service through a queue of its own, with one writer and one reader, and waits for its answer. It holds no lock.

**The order of the shared steps is the step debt.** The service measures the time of each shared step on the clock of the system and adds it to the step debt of its connection. It takes the next shared step from the connection with the least step debt. A new connection starts at the least step debt of the connections that have a step waiting, as a new thread takes the clock of its queue under the fair strategy ([`docs/SCHEDULING.md`](../../../docs/SCHEDULING.md), "Three strategies"). A client that asks for large commits waits behind the clients that asked for small ones.

**The time of the shared step is not charged by the kernel.** The thread of the service runs it, so the kernel counts it in the budget of the service. The step debt is the charge: it orders the steps, and the report shows it. A kernel operation that moves time from one budget to another was refused (below). The bound of the step keeps this part small: the private part holds the work that grows with the size of a call, and the shared step holds only the writes.

### When the budget of a client is spent

- **Memory.** A `Memory_Create` or a commit of an arena on the work budget gives `No_Budget`. The export ends with the error record `No_Budget` of the unit `Work_Budget`, with the pages that the call needed and the pages that the work budget holds. The call changed nothing: the private part makes nothing shared, and a call that fails before its shared step leaves no trace. The service and every other client go on.
- **Time.** Time is a limit for each period, not an amount: a spent period delays, it does not refuse. The calls of the client wait for the next period of its budget, within their deadline. A deadline that passes gives the caller `No_Answer`, as for a holder that stops ([supervision.md](supervision.md), "What a client sees when the holder of its role stops"). A work budget with the limit 0 has no time at all: the service refuses each call of that connection at once, with `No_Budget` of the unit `Processor`, because a work thread that never runs holds its calls for ever.
- **A thread slot.** A client whose budget holds no thread slot gets no work budget: the root service refuses the `Connect` with `No_Budget` of the unit `Threads`, before it makes anything.

In each case the service writes no line for the client: the error record goes to the client. One line at the first refusal of a connection, and the count at its end, is the most, as the compositor does for a window that writes words of no command.

### The shared services

- **Storage.** The places and the pending blocks of each connection become tables of the connection, sized by its work budget. The private part of a commit (the checksums of the new blocks, the hash of the object, the reads of the block tree for the path) runs on the work thread. The shared step is the commit, with its read back ([dropped_write.md](dropped_write.md)). The block service is a second shared service behind it: its time for a client is the time of the block service, which the storage service is the one client of. The time of the disk itself is not counted (an open question below).
- **The compositor.** The time of a frame is the shared step: one frame for all the windows. The copy of the damage of each window is the part that grows with one client. The compositor measures the time of each copy, as it measures each frame today, adds it to the step debt of the window, and when a frame cannot take every damage within its bound, it takes the damage of the windows with the least debt first; the damage of a window that is left merges into its next frame, as the debt of a remote viewer does ([remote_display.md](remote_display.md)).
- **`recipes`.** The hash of each input and each fetch from the object cache run on the work thread of the client that asked for the recipe. The shared step is the write of the realisation into the store of the service.
- **The log.** A read of the records runs on the work thread of the reader. The writes need nothing: the kernel writes the log, and the writer pays its log records.

### What the report of a process shows

The report of a process (`monitor.processes()`, `Process_Report`) adds the work that services did for it:

- `work("console")` gives one row for each connection of the process: the service, the pages of the work budget in use and their total, the processor time of the work thread in the last period and since the connection, and the step debt.
- The root service reads the pages with `Budget_Read` on the work budget that it holds. The service writes the step debt and the time of the work thread of each connection on a page of the connection that the root service maps, as the counts of a writer are on its output state ([module_outputs.md](module_outputs.md)).
- The processor time of the process counts its work threads already, as the kernel counts their time in its budget. The row says which part of that time a service spent, so a principal sees "the console spent 40 ms in its own threads and 300 ms in the storage service".

## The refused forms

- **The pages of the client for the working state.** See "The three forms compared": a revocation during a call would stop the service, and it gives nothing for time.
- **A budget handle lent with each call.** A give and a proof of a handle for each call, where a call needs no kernel entry today. And a client that lends a nearly empty budget for each call makes the service fail in the middle of a call; with one work budget for the connection, the pages are moved at the `Connect` and cannot leave.
- **A scheduling context that the client donates.** See "The three forms compared": it needs the kernel on the path of each call, and gives no memory.
- **A kernel operation that charges time to another budget.** It lets a service write any time into any budget that it holds: a claim that the kernel cannot check, and a way to drain a client. The kernel counts only the time that it saw a thread run.
- **A share of the processor for each client inside the service, with no work thread.** The service counts and orders the time of each client in its own code, and the kernel counts it all in the service. The limit of the client does not hold for the work done for it, and a service with a fault in that count charges no one.
- **One fixed table for all connections, with a bound for each connection.** It fixes the share of each client at the build of the service, and the sum of the bounds is the size of the table: a client that needs more cannot pay for more.
- **The root service pays for the connections, as today.** A client then reaches the budget of the root service through the count of its connections, the process that holds every grant.
- **A work thread that runs the shared step under a lock.** The stall of every client for the next period of one client, which is the fault that this design removes.
- **A pool of work threads.** A thread counts its time in the budget that it was created on, and the kernel cannot move a thread from one budget to another at each call. A pool then needs a `Thread_Create` on the budget of the client for each call, a cost on the path of each call, or a thread that serves several clients and charges none of them.

## The subtle points

- **The work thread runs in the address space of the service.** It holds the handles of the service and maps its memory. The budget says who pays; it gives the client no access to the service, and gives the service no access to the client beyond the work budget, on which it can only spend.
- **A client that spends its own time stops its own work.** The limit of the work budget holds with the limit of the client above it: a client that spins its own threads leaves no time to its work thread. That is the purpose: the client chose how to spend its time.
- **The lost time of a fault.** A work thread that faults stops the service, as each thread of a process does. The time spent until the fault counts in the client; the restart of the service is the service's ([supervision.md](supervision.md)). The fault comes from the code of the service, not from the client, so the rule of "let it crash" holds: a hostile argument is an error record.
- **A work budget is a child of the budget of the client.** The share policy of the scheduler ([scheduling_policy.md](scheduling_policy.md), "A share for each budget") reads the threads of each process. A work thread is a thread of the service process, so the policy counts it with the service; its weight must follow its budget. The round reads the budget of each thread, not only its process.
- **A client with a large number of small calls** pays the switch between its work thread and the thread of the service for each shared step. That cost is a measure to take before the first service moves: a call of the storage service that is now one turn of a loop becomes a wake of one thread and a wake back.
- **The step debt is a claim of the service.** The service measures it, so a faulty service can order its clients wrong. It cannot charge a client for it: the step debt orders, it does not take time from a budget.

## The frequent tasks

- **See what services do for a process.** `work("console")`.
- **See which client a service works for.** `work_of("storage")`: one row for each connection of the service, with the client, its pages and its time.
- **Give a client more room in a service.** The amount in its start grant set, or in the call `connect("storage", pages = 4096)`, between the least and the largest amount of the contract.

## Open questions

- **The time of a device.** A commit spends the time of the disk, which no budget counts. A client that asks for many reads delays the reads of the others through the queue of the device. A count of the blocks of each connection, as a second order beside the step debt, is the first candidate.
- **The amount of a work budget.** A base in the role contract, and a part that the client asks for. The size of each base comes from a measure of each service under the test of its role.

## State

Layer 1 built: the contract package `src/library/modus/contract/work_budget/` (closed enums `Work_Account_State` and `Work_Budget_Refusal`, `Work_Budget_Requirements` with exact child budget calculation, border-validated `Accounting_Snapshot` and `Accounting_Snapshot_Record`, pure `work_budget_check`, and the `Connection_Worker_Table` state machine with per-connection exhaustion isolation, mid-call revocation, slot reclamation, and least-step-debt shared-step selection) and the test module `src/modules/tests/work_accounting_probe/` (spawning one work thread and uncommitted scratch memory per connection strictly on the client's offered child budget with `Spend` right, never on the service's own budget), both with adversarial host tests. Built before it: the budget with its amounts and its limit, `Budget_Create`, `Thread_Create` on a budget, the budget handle of each process that the root service holds for the wirings, the turn of a window ring of the compositor, the log records as an amount of the writer, and the follow ring paid by its asker. Left: the work budget at `Connect` and its handle in the record of the service ring; the call ring, the call region and the connection page from it; the work thread of the library of a service; the tables of each connection of the storage service in place of its places and its pending blocks of all connections; the error records of the unit `Work_Budget`; the rows `work` and `work_of`; and a machine test where one client spends its work budget and another client of the same service sees no refusal and no delay past its own.
