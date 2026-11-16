# The own log ring of a program

## Purpose

A program reads its own log records back through the log service ([log_reader_scope.md](log_reader_scope.md)). When all records shared one ring, the records of the other programs pushed the records of a reader out. A reader that wrote K records and read them back later counted how many were gone, and so learned how many records the others wrote meanwhile: a measure of their activity, and a covert channel between two programs that hold no ring between them. The own log ring closes that channel: the records of a program stay in a ring that only its own records fill. The guide is [`docs/TOOLS.md`](../../../docs/TOOLS.md), "Who reads which records".

## Constraints

- A program sees no other program, and side channels are reduced ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", rows 1 and 17).
- The memory that a kernel object uses is charged to the program that created it ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller").
- The kernel interface is small and counted ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "1. Small kernel with a small, counted interface").
- The reader of the whole log (the console, `remote`, the window of the log, the machine tests) reads one ring in the order of the writes, with the records of the kernel and of the programs that stopped.
- A reader never maps memory that holds the records of another program ([log_reader_scope.md](log_reader_scope.md), "Refused forms").

## The chosen form

**Two places for each record of a program.** The kernel writes each record of a program in the whole log, the one ring of before, and in the own log ring of the program. The two copies are the same 256 bytes (`op.Log_Record`), with the same own number. A record of the kernel goes to the whole log only: the kernel is never a caller of the log service, so no reader asks for its own records.

**The own log ring is small, and the budget of the program pays it.** It has `op.OWN_LOG_PAGES` pages, 4, which hold `op.OWN_LOG_RECORD_CAPACITY` records, 64. `Program_Create` takes its frames from the budget that pays the program, beside the top table of the address space; the cleanup of the program gives them back to that budget. The ring has no head in memory: the kernel keeps the count of the records of the program (`log_records_written`, 64 bits, under the log lock) in the program record, and the record `n` is in the place `n % 64`. The reasons of the size:

- 64 records fill the rows of one call of `log.records` of a reader with 64 rows (16 KiB of a call region of 64 KiB, as `log_reader` has): one call reads the whole ring.
- 4 pages are 16 KiB for each program: 0.2 % of the least budget of a program, 2048 pages. A budget that does not hold them refuses `Program_Create` with `No_Budget`, as for its top table. The working memory of a module holds them, as it holds its page tables ([module_budget_request.md](module_budget_request.md)).

**The whole log stays one ring.** A reader of the whole log reads the ring of before, with no change: the merge of the own log rings was refused (see the refused forms). The cost of the second copy is one store of 256 bytes for each record, under the log lock, which the record already holds.

**`Log_Read` copies an own log ring.** The log service is the one reader of the own log rings. It calls `Log_Read(memory, program, serial, after, records, count) -> copied, lost, total`, the kernel operation 35:

- `memory` is a handle of the memory of the log with **Read**: the authority to read every record. Its holder already reads each record in the whole log, so it gains no new fact. No new right and no new grant exist: the root service gives this handle to the log service only (`GRANT_LOG_RECORDS`).
- `program` and `serial` name the program, as the grant of the connection names it ([log_reader_scope.md](log_reader_scope.md)). The kernel checks under the log lock that the slot holds a program with that serial and a ring; else `Bad_State`. A reader of another program, of a program that stopped, or of a slot with a new program receives no record.
- `after` is an own number, modulo 2^32. The kernel gives the records from `after` on that the ring still keeps (`op.own_log_window`): `lost` counts the own records from `after` that the ring no longer keeps, and `total` counts the records from the first one copied to the last one.
- The kernel copies whole records under the log lock into a buffer of the processor, then to the caller after the lock, so no copy is torn: the two rules of a reader of the whole log (`op.log_first_kept`, `op.log_copy_kept`) do not apply to an own log ring.

The reason of a new operation: the own log ring is memory of the kernel that the budget of a program pays, and the log service holds no handle of that program. No operation of before copies a record of the kernel for a holder of the memory of the log. `Inspect` copies records of the kernel, but needs the machine handle with **Inspect**, which shows the whole machine: a new right for the log service. The kernel has 35 operations.

**The ring ends with the slot of its program.** After the stop, when the last handle to the program closes, the free of the slot (`program_free`) clears the ring under the log lock and gives its pages back to the budget, with the slot. Two readers exist: the program itself, through its connection, which ends with it; and a holder of its program handle with Read and Give, such as its starter, which lends the handle to `log.program_records` ([log_reader_scope.md](log_reader_scope.md)). The handle keeps the slot, so the starter of a stopped child still reads the last records of that child, often the reason of its stop. The records also stay in the whole log, for a reader that acts for the principal. A guest frees its ring earlier, at its first run (see the subtle points).

**The records of a lent program come from its ring too.** `program_records` and `program_value_runs` call `Log_Read` with the slot and the serial of the lent program. So a storm of one child never pushes out the records of another child, nor the own records of the starter.

**A log storm now evicts only the own records of its writer.** A program that writes many records fills its own ring and pushes its own records out. In the whole log it still pushes the records of the others out, but only a reader that acts for the principal reads the whole log, and that reader sees each record of each program: the eviction tells it nothing that it does not see. The log limit of each second still limits the storm (`Budget_Amounts.log_records`).

## Refused forms

- **The whole log as a merge by time of the own log rings.** The ring of a program ends with its slot, so its last records, often the reason of its stop, would leave the whole log when its last handle closes. The records of the kernel have no own ring. A reader of the whole log would merge up to 63 rings at each call and map memory that each program pays. The number of a record in the whole log would no longer exist, and the tool, the window of the log and `remote` read by that number. One more copy of each record costs less than all of that.
- **The own log rings mapped by the log service.** The frames of a ring come and go with each program. A shared mapping of them needs a shoot-down in the log service at each stop of a program, and a read of a page that left is a fault of the log service. A memory object for each ring needs a handle that the root service sends to the log service for each connection; the grant of a connection is one word.
- **The own log rings in one memory object of the kernel that the kernel makes at its start.** It is memory that no budget pays: 64 slots of 4 pages that the kernel holds whatever programs run.
- **A ring that the program reads itself.** A program reaches each other access through a handle that someone granted; the log service is no exception ([log_reader_scope.md](log_reader_scope.md), "Refused forms").
- **The ring freed at the stop of the program.** The starter of a child that stopped would lose the last records of that child while it still holds its handle, and those records are often the reason of the stop. The pages stay out of the budget only as long as the slot, which the same handle keeps.
- **The ring kept after the slot is free, until its records are read.** No handle names the program then, so no reader can name it: the pages would stay out of the budget for nothing.
- **A copy of the own records in the log service.** The service reads the whole log after the kernel writes it. A storm of others can push a record of the reader out of the whole log before the service copies it: the channel narrows, it does not close.
- **A larger ring.** A reader that wants more than its last 64 records keeps them itself as it reads them. Each page of the ring is paid by each program, also by each program that never reads its records.

## Subtle points

- **The order of the locks.** The `Log` operation holds the program lock of the writer, then the log lock; `Log_Read` holds the program lock of its caller, then the log lock. `Program_Create`, the free of the slot (under the control lock, with no program lock) and the first run of a guest set and clear the frames of the ring under the log lock, and take the frame lock only after they free the log lock: no path takes the frame lock under the log lock.
- **The serial is set before the ring.** `Program_Create` writes the new serial with the reset of the program record, then sets the frames under the log lock. The free of the slot clears the frames under the log lock before the slot can serve a new program. So a reader that finds frames under the log lock finds the serial of their program.
- **The copy to memory of the caller comes after the log lock.** A reader of its own records makes the log service call `Log_Read` at will, and each `Log` of every program waits for the one log lock. So under the lock the kernel copies the ring only into a buffer of the processor record (`own_log_copy`, 16 KiB, one ring), and copies the buffer to the caller after the lock. The kernel stack cannot hold that buffer: the build measures the deepest chain and keeps a quarter of the 64 KiB stack free. `user_range` makes each page of the caller present before the lock, and the program lock of the caller keeps the pages mapped until the copy ends.
- **A guest gives its ring back.** A guest is a program that `Program_Create` made, so its budget paid the ring. A guest has no thread and never writes a record: its first `Guest_Run` frees the ring, as the time page leaves it then.
- **The own number wraps at 2^32.** The kernel count has 64 bits; the record keeps its low 32 bits. `after` is read modulo 2^32 against the count: an `after` up to 2^31 before the count names a past record, and an `after` past the count gives no record. The ring holds 64 records, so the distance is exact.
- **A reader whose own records are all gone** receives no row, and `lost` is in the first row only. The result 0 is true. With the own log ring, only its own records push them out.

## State

Built: the own log ring of each program, paid by its budget at `Program_Create` and freed with its slot or at the first run of a guest; the copy under the log lock into a buffer of the processor; the two copies of each record; the operation `Log_Read`; the log service that reads with it the own records of a caller and the records of a lent program; `op.own_log_window` with host tests; the machine test where a child of `log_reader` writes more records than the whole log keeps, after which `log_reader` still reads its one record and the one record of each of its two other children, which stopped before, and the whole log still reads in order.

Left: two other side channels of the log stay open for a reader of its own records. The log limit of each second is also counted in each budget above the budget of a program, so a refused `Log` can say that the others wrote much. The `Log` operation waits for the serial port under the one log lock, so the time of a `Log` says how much the others wrote. A precise clock is not yet a grant.
