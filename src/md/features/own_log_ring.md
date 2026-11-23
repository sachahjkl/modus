# The own log ring of a process

## Purpose

A process reads its own log records back through the log service ([log_reader_scope.md](log_reader_scope.md)). When all records shared one ring, the records of the other processes pushed the records of a reader out. A reader that wrote K records and read them back later counted how many were gone, and so learned how many records the others wrote meanwhile: a measure of their activity, and a covert channel between two processes that hold no ring between them. The own log ring closes that channel: the records of a process stay in a ring that only its own records fill. The guide is [`docs/TOOLS.md`](../../../docs/TOOLS.md), "Who reads which records".

## Constraints

- A process sees no other process, and side channels are reduced ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", rows 1 and 17).
- The memory that a kernel object uses is charged to the process that created it ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller").
- The kernel interface is small and counted ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "1. Small kernel with a small, counted interface").
- The reader of the whole log (the console, `remote`, the window of the log, the machine tests) reads one ring in the order of the writes, with the records of the kernel and of the processes that stopped.
- A reader never maps memory that holds the records of another process ([log_reader_scope.md](log_reader_scope.md), "Refused forms").

## The chosen form

**Two places for each record of a process.** The kernel writes each record of a process in the whole log, the one ring of before, and in the own log ring of the process. The two copies are the same 256 bytes (`op.Log_Record`), with the same own number. A record of the kernel goes to the whole log only: the kernel is never a caller of the log service, so no reader asks for its own records.

**The own log ring is small, and the budget of the process pays it.** It has `op.OWN_LOG_PAGES` pages, 4, which hold `op.OWN_LOG_RECORD_CAPACITY` records, 64. `Process_Create` takes its frames from the budget that pays the process, beside the top table of the address space; the cleanup of the process gives them back to that budget. The ring has no head in memory: the kernel keeps the count of the records of the process (`log_records_written`, 64 bits, under the log lock) in the process record, and the record `n` is in the place `n % 64`. The reasons of the size:

- 64 records fill the rows of one call of `log.records` of a reader with 64 rows (16 KiB of a call region of 64 KiB, as `log_reader` has): one call reads the whole ring.
- 4 pages are 16 KiB for each process: 0.2 % of the least budget of a process, 2048 pages. A budget that does not hold them refuses `Process_Create` with `No_Budget`, as for its top table. The working memory of a module holds them, as it holds its page tables ([module_budget_request.md](module_budget_request.md)).

**The whole log stays one ring.** A reader of the whole log reads the ring of before, with no change: the merge of the own log rings was refused (see the refused forms). The cost of the second copy is one store of 256 bytes for each record, under the log lock, which the record already holds.

**`Log_Read` copies an own log ring.** The log service is the one reader of the own log rings. It calls `Log_Read(memory, process, serial, after, records, count) -> copied, lost, total`, the kernel operation 35:

- `memory` is a handle of the memory of the log with **Read**: the authority to read every record. Its holder already reads each record in the whole log, so it gains no new fact. No new right and no new grant exist: the root service gives this handle to the log service only (`GRANT_LOG_RECORDS`).
- `process` and `serial` name the process, as the grant of the connection names it ([log_reader_scope.md](log_reader_scope.md)). The kernel checks under the log lock that the slot holds a process with that serial and a ring; else `Bad_State`. A reader of another process, of a process that stopped, or of a slot with a new process receives no record.
- `after` is an own number, modulo 2^32. The kernel gives the records from `after` on that the ring still keeps (`op.own_log_window`): `lost` counts the own records from `after` that the ring no longer keeps, and `total` counts the records from the first one copied to the last one.
- The kernel copies whole records under the log lock into a buffer of the processor, then to the caller after the lock, so no copy is torn: the two rules of a reader of the whole log (`op.log_first_kept`, `op.log_copy_kept`) do not apply to an own log ring.

The reason of a new operation: the own log ring is memory of the kernel that the budget of a process pays, and the log service holds no handle of that process. No operation of before copies a record of the kernel for a holder of the memory of the log. `Inspect` copies records of the kernel, but needs the machine handle with **Inspect**, which shows the whole machine: a new right for the log service. The kernel has 35 operations.

**The ring ends with the slot of its process.** After the stop, when the last handle to the process closes, the free of the slot (`process_free`) clears the ring under the log lock and gives its pages back to the budget, with the slot. Two readers exist: the process itself, through its connection, which ends with it; and a holder of its process handle with Read and Give, such as its starter, which lends the handle to `log.process_records` ([log_reader_scope.md](log_reader_scope.md)). The handle keeps the slot, so the starter of a stopped child still reads the last records of that child, often the reason of its stop. The records also stay in the whole log, for a reader that acts for the principal. A guest frees its ring earlier, at its first run (see the subtle points).

**The records of a lent process come from its ring too.** `process_records` and `process_value_runs` call `Log_Read` with the slot and the serial of the lent process. So a storm of one child never pushes out the records of another child, nor the own records of the starter.

**A log storm now evicts only the own records of its writer.** A process that writes many records fills its own ring and pushes its own records out. In the whole log it still pushes the records of the others out, but only a reader that acts for the principal reads the whole log, and that reader sees each record of each process: the eviction tells it nothing that it does not see. The log records of each second of its budget still limit the storm (`Budget_Amounts.log_records`), and only its own budget counts them ([log_side_channels.md](log_side_channels.md)).

## Refused forms

- **The whole log as a merge by time of the own log rings.** The ring of a process ends with its slot, so its last records, often the reason of its stop, would leave the whole log when its last handle closes. The records of the kernel have no own ring. A reader of the whole log would merge up to 63 rings at each call and map memory that each process pays. The number of a record in the whole log would no longer exist, and the tool, the window of the log and `remote` read by that number. One more copy of each record costs less than all of that.
- **The own log rings mapped by the log service.** The frames of a ring come and go with each process. A shared mapping of them needs a shoot-down in the log service at each stop of a process, and a read of a page that left is a fault of the log service. A memory object for each ring needs a handle that the root service sends to the log service for each connection; the grant of a connection is one word.
- **The own log rings in one memory object of the kernel that the kernel makes at its start.** It is memory that no budget pays: 256 slots of 4 pages that the kernel holds whatever processes run.
- **A ring that the process reads itself.** A process reaches each other access through a handle that someone granted; the log service is no exception ([log_reader_scope.md](log_reader_scope.md), "Refused forms").
- **The ring freed at the stop of the process.** The starter of a child that stopped would lose the last records of that child while it still holds its handle, and those records are often the reason of the stop. The pages stay out of the budget only as long as the slot, which the same handle keeps.
- **The ring kept after the slot is free, until its records are read.** No handle names the process then, so no reader can name it: the pages would stay out of the budget for nothing.
- **A copy of the own records in the log service.** The service reads the whole log after the kernel writes it. A storm of others can push a record of the reader out of the whole log before the service copies it: the channel narrows, it does not close.
- **A larger ring.** A reader that wants more than its last 64 records keeps them itself as it reads them. Each page of the ring is paid by each process, also by each process that never reads its records.

## Subtle points

- **The order of the locks.** The `Log` operation holds the process lock of the writer, then the log lock; `Log_Read` holds the process lock of its caller, then the log lock. `Process_Create`, the free of the slot (under the control lock, with at most process locks) and the first run of a guest set and clear the frames of the ring under the log lock, and take the frame lock only after they free the log lock: no path takes the frame lock under the log lock.
- **A holder pins the ring.** A holder of the handle of a stopped process keeps its slot and its 16 KiB, which the budget of the payer holds, until the holder closes the handle, stops, or loses it by a revocation.
- **The serial is set before the ring.** `Process_Create` writes the new serial with the reset of the process record, then sets the frames under the log lock. The free of the slot clears the frames under the log lock before the slot can serve a new process. So a reader that finds frames under the log lock finds the serial of their process.
- **The copy to memory of the caller comes after the log lock.** A reader of its own records makes the log service call `Log_Read` at will, and each `Log` of every process waits for the one log lock. So under the lock the kernel copies the ring only into a buffer of the processor record (`own_log_copy`, 16 KiB, one ring), and copies the buffer to the caller after the lock. The kernel stack cannot hold that buffer: the build measures the deepest chain and keeps a quarter of the 64 KiB stack free. `user_range` makes each page of the caller present before the lock, and the process lock of the caller keeps the pages mapped until the copy ends.
- **A guest gives its ring back.** A guest is a process that `Process_Create` made, so its budget paid the ring. A guest has no thread and never writes a record: its first `Guest_Run` frees the ring, as the time page leaves it then.
- **The own number wraps at 2^32.** The kernel count has 64 bits; the record keeps its low 32 bits. `after` is read modulo 2^32 against the count: an `after` up to 2^31 before the count names a past record, and an `after` past the count gives no record. The ring holds 64 records, so the distance is exact.
- **A reader whose own records are all gone** receives no row, and `lost` is in the first row only. The result 0 is true. With the own log ring, only its own records push them out.

## State

Built: the own log ring of each process, paid by its budget at `Process_Create` and freed with its slot or at the first run of a guest; the copy under the log lock into a buffer of the processor; the two copies of each record; the operation `Log_Read`; the log service that reads with it the own records of a caller and the records of a lent process; `op.own_log_window` with host tests; the machine test where a child of `log_reader` writes more records than the whole log keeps, after which `log_reader` still reads its one record and the one record of each of its two other children, which stopped before, and the whole log still reads in order.

The two other side channels of the log, the log limit counted in each budget above a process and the wait of a `Log` for the serial port under the log lock, are closed or narrowed by [log_side_channels.md](log_side_channels.md), with what stays of them.
