# The log limit and the time of a `Log`

## Purpose

A reader of its own records reads them from its own log ring, which only its own records fill ([own_log_ring.md](own_log_ring.md)). Two other facts of the log still told a program how much the other programs wrote:

- **A refused record.** The log limit of each second was counted in the budget of the program and in each budget above it. A program whose own count was low got `No_Budget` when a sibling, or any program below a common budget, wrote much in that second.
- **The time of a `Log`.** The operation wrote its line on the serial port under the one log lock. The serial port is slow, so a `Log` waited for each line that the other programs wrote before it.

Both are a measure of the activity of other programs, and a covert channel between two programs that hold no ring between them. This design closes the first and narrows the second to a short section of memory copies. The guides are [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The serial port and the log limit", and [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "Locks of the kernel".

## Constraints

- A program sees no other program, and side channels are reduced ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", rows 1 and 17).
- Each resource is a handle with a limit, and a program divides its limit among its children ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", row 16).
- The serial port is the log of the host: the machine tests wait for its lines, in the order of the records, and a line of a fault of the kernel must reach it.
- A program writes the lines of its normal use with no refusal: a refused line of a program that a test waits for fails the test.
- No queue drops a record in silence. A full queue stops its writer, or it has a stated capacity and counts each refusal.

## The irreducible choice

The serial port is one device with a finite rate, shared by all programs. A writer that is faster than the device has three answers: it waits for the device, which is the time channel; its lines are lost; or each budget holds a fixed part of the rate, and the sum stays below what the device keeps. Under KVM a port write exits to QEMU and costs 2 to 10 µs, so the device keeps far less than the lines of normal use in a burst, and the third answer would cut normal use. This design takes the second answer for a flood, with a count: the serial port loses the lines of a flood, says how many, and a test fails on that line. The budgets keep a fixed part of the records of the log, which closes the channel of a refusal.

## The chosen form

**The log records of each second are an amount that a budget holds.** `Budget_Create` moves them from the budget that pays to the new budget, as it moves pages, programs and threads, and the end of the budget gives them back. A budget counts only the records of its own programs, against its own amount. A `Log` of N records spends N: the kernel counts the records that the text takes after its copy, as `log_record` cuts it (`log_records_of_text`). So a refusal says only that the budget of the writer wrote its own amount in this second, and `Budget_Read` gives the amount that the budget still holds after its children.

The reason: a limit that two budgets share always tells each one what the other used. A division with no sharing tells nothing. The cost is that a child does not use the records that its starter or a sibling leaves unused.

**The count of the second moves with the amount.** Without it, a program that wrote its whole amount could start a child, which starts at a count of 0, write through it, stop it and start it again: each start would give new records in the same second, bounded only by the rate of the starts. So at `Budget_Create`, in the same second, the child takes the part of the count of its parent that its new amount no longer holds: `min(N, max(0, count − (amount − N)))` for a child of N records. At the end of a budget, its count of this second returns to its parent. Both run under the frame lock, with a compare and exchange on the word of the count. The sum of the counts of a tree in one second then stays at most the amount of its top. A child learns from its first count only what its own starter wrote, which its starter already knows.

**The amounts are those of normal use.** Each program gets the amount that it had when the limit was counted in each budget above: `op.LOG_RECORDS_OF_A_PROGRAM`, 1000 records in each second, and `limits` 40, the one exception, whose case reaches the limit. The kernel gives the root service `op.LOG_RECORDS_OF_THE_MACHINE`: 1000 for each of the 64 program slots, 64 000, the sum that the root service divides. The root service gives 1000 to each program that it starts and keeps what is left for its own lines; an assertion checks that its 63 slots at 1000 each and its own share fit. The budget of the disk programs holds 1000 for each of its 4 programs. A starter divides its own 1000 among its children: the 12 call hosts of the console get 50 each, a call host of `system.call_host_start` 100 by default, the storm child of `log_reader` 900, and the other children 10 to 100 each, the amounts that they had.

**The kernel bounds its own records.** The kernel writes records of its own: the stop of a program on a fault, a refused return, a full fault ring, a kernel event. A program can cause them as fast as it faults, so the kernel bounds them: at most `op.LOG_RECORDS_OF_THE_KERNEL`, 64, in each second after the first tick. A line of the kernel past the bound is not written and is counted; the next line that fits is preceded by one record `kernel: <n> lines of the kernel were over its limit of 64 records in each second`, inside the bound. Before the first tick, each writer drains its record at once, so the boot needs no bound.

**`system.log` never waits.** A line that the kernel refuses is dropped and counted in the program (`log_lines_refused`, one atomic count for its threads). The next line that the kernel accepts is preceded by one record `<n> lines of this program were refused by its log limit`, inside the amount. A line longer than the whole amount, and each line of a program with 0 log records, are counted the same way; the kernel also counts each refused record in the budget, which `Budget_Read` gives to the starter. No thread with a deadline waits for a second: the compositor, the input service and the console under its lock write at once or count.

**A refusal that no later line says is written at the stop.** The kernel counts, for each program, the `Log` operations that it refused since its last accepted one (`log_lines_refused` of the program record). When the program stops with that count above 0, the kernel writes `kernel: <program>: <n> lines were refused by its log limit, the last ones before its stop`, inside its own bound. So a refusal is said, also when the program wrote nothing after it. Two cases still lose it, because the kernel resets its count on any accepted `Log` and the program resets its own only on an accepted note: two threads of the program race, and the line of one is accepted between the refusal of the other and its note; or the note is refused and the next line is accepted. In both cases the count stays in the program only, and a stop before its next accepted line loses it. A note that the kernel writes in front of the next accepted `Log`, from one count, closes both; it is not built.

**The serial port is written by a drain, not by `Log`.** `Log` and the records of the kernel write the records of the log only, under the log lock. The serial writer writes on the serial port the records of the whole log that the serial port does not have yet, in their order. The line of a record is the line of before: `[name:channel] text` for a program, the text alone for the kernel; a long text that the log splits into records is one line again.

- **One writer of the serial port, from any processor.** The serial writer (`serial_writer`, the identifier of the processor plus one) is a word that a processor takes with a compare and exchange. The tick of each processor tries it, so a hang of one processor does not silence the others. A processor that waits for a lock longer than `LOCK_WAIT_BEFORE_DRAIN_MILLISECONDS` tries it too, at each turn of its wait: a hang of the machine still writes the lines that explain it. The flush before the machine stops and the report of a fault of the kernel wait for it a bounded time. `serial_next` keeps the order. It is not a lock of the lock order: no path waits for it with no end, and its holder takes no lock.
- **The drain writes only while the device takes bytes, and for a bounded time.** It writes up to 16 bytes, the queue of the device, when the line status says that the transmit register is empty. The drain of a tick ends after `SERIAL_MICROSECONDS_OF_A_TICK`, 100 µs by the cycle counter, whatever bytes it wrote: interrupts are off for no longer than that, a tenth of a tick, and a device interrupt waits at most that. No spin with interrupts off. The line of the record in progress waits in a buffer of the drain (`serial_line`) for the next tick. Between two writes, the drain of a tick answers `processor_sync`, and leaves when the machine stops.
- **The drain reads the whole log as a reader does.** It copies each record into one buffer of the kernel (`serial_copy`), and keeps the copy only when the rule of a reader of the whole log holds (`op.log_first_kept`, `op.log_copy_kept`). It takes no log lock: a `Log` never waits for the serial port.
- **A record that the drain did not reach in time is counted.** When the log wrote over records before the drain wrote them, the serial port gets the line `kernel: <n> records of the log did not reach the serial port`. Each scenario of the tool fails at once on that line, and once more on the whole log after the machine ends.
- **The rate of the drain is a measure.** The first drains that wrote 64 KiB together write their measured rate on the log once. No test asserts it.
- **The time of the drain is not charged.** The tick counts the time of the thread that it interrupted before the drain, and moves the start of the next count past the drain: no budget pays for the lines of others.
- **Before the first tick**, each writer of a record writes the serial port at once, after it frees the log lock: the timer does not run yet, and a hang of the start must still show its lines.
- **The machine stops after the flush.** `machine_stop` writes the records that the serial port does not have yet before it ends the machine, so the last line of a test reaches the host. It waits at most 1 s for another writer, and writes at most the whole log: 2047 records, at most 422 KB.
- **A fault of the kernel writes the waiting records first.** The report takes the serial writer, writes the records that the log holds and the serial port does not, then its own lines: the records before a fault are often its cause. The flush and the report wait for the device, with interrupts off: they end the machine.

## The known limit

**The serial port can lose the lines of a flood.** The amounts of the budgets let the programs together write far more records in one second than the drain writes on the serial port, under KVM most of all. When the log writes over records that the drain did not reach, the serial port gets the line with their count, and the test fails at once with that cause. The records stay in the whole log until newer records push them out, for a reader that acts for the principal. A serial port that keeps every line of a flood is planned work (`ROADMAP.md`).

## Refused forms

- **The limit counted in each budget above, as before.** It is the channel that this design closes.
- **A count of the calls in place of the records.** A call of 4096 bytes writes 27 records: the amount would not bound the lines.
- **A limit of the whole machine beside the amounts of the budgets.** It is one shared count, the same channel between any two programs.
- **Amounts sized from the ring of the log.** The records of the machine in two seconds then fit the whole log: 959 in each second, 7 to 48 for a program. That cut normal use: the main machine test failed when the compositor wrote more than 48 records in one second, and the line that the test waited for was refused. And it kept no guarantee: under KVM the drain writes far less than the 210 738 bytes in each second that those records need, so a flood still loses lines on the serial port.
- **The serial line written by `Log` after the log lock, under a lock of the serial port.** The `Log` then waits for the lines of the others under that lock: the channel moves, it does not close.
- **A wait for the serial port when the drain is behind.** A writer that waits for the drain learns how much the others wrote.
- **The drain on the first processor only.** A hang of that processor with interrupts off silences each line of the others, often the lines that explain the hang.
- **The drain that spins for the device.** At 115 200 baud, 1 KiB is 89 ms with interrupts off at each tick.
- **The drain with no bound at each tick, or a bound in bytes.** A port write that exits to QEMU costs 2 to 10 µs, so 512 bytes are whole milliseconds with interrupts off. Only a bound in time bounds the time.
- **`system.log` that waits for the next second.** A refused line then stops the calling thread for up to 1 s: the frame loop of the compositor, the loop of the input service, the console under its output lock.
- **`system.log` that drops a refused line with no count.** A line would be lost in silence.
- **The count of refused lines only in the memory of the program.** A program that stops after a refusal and writes no other line would leave it silent. The kernel holds the count, and writes it at the stop.
- **A new budget that starts at a count of 0.** A loop of starts of a child would write past the amount in one second.
- **The records of the kernel with no bound.** A program that faults in a loop would make the kernel flood the log.
- **The serial port read by a program.** The serial port belongs to the host; a program reads the log through the log service.

## Subtle points

- **The order of the lines is the order of the records.** The lines of one long text are contiguous in the whole log, because one `Log` writes them under one hold of the log lock. A line that the drain begins at one tick and ends at another, on any processor, stays whole: `serial_line` and `serial_next` belong to the serial writer, not to a processor.
- **A record lost in the middle of a line.** The drain ends the open line, writes the count, and starts the next record with its name.
- **A fault inside the drain.** The report finds that its own processor holds the serial writer: it does not drain again, and says that the line above is cut.
- **The name of a program is whole.** `Program_Create` keeps at most 31 bytes of a name and a zero, and the record keeps the same 31 bytes: the line shows the whole name.
- **What stays of the time of a `Log`.** A `Log` still waits for the log lock while another `Log` copies its records, or `Log_Read` copies an own log ring, into memory. That section is bounded by the copy of 4096 bytes of text twice, and of one ring of 16 KiB. The tick of a processor also takes the time of the drain from the thread that it interrupts, in wall time, and its ticks of the slice: a program that measures its own progress with a precise clock can still see that the others wrote. A precise clock is not yet a grant.
- **The amount of a budget changes.** The amount that `Budget_Read` gives, and the limit that `Log` checks, change when a budget comes from it or ends, under the frame lock. `Log` reads the amount once, with no lock: a record checked against the amount before a change is accepted against a value that held.
- **A child that stops gives its amount back** at the end of its budget, when its program stops, with its count of this second: the starter has the records again in the next second.
- **The count moves under the frame lock, a `Log` does not take it.** A `Log` that read the amount before a `Budget_Create` and counts after the move can pass the new amount of the parent by its own records, at most 28, once for each processor at that instant. The next second starts from 0.
- **The note of the refused lines is a line of its own.** It costs one record of the amount, so a program at its amount writes the note only in a second where it has room; the lines that it lost meanwhile add to the count. The kernel counts the refused `Log` operations, the program counts its refused lines: both reset when a later line is accepted.

## State

Built: the log records of each second as an amount that a budget holds and counts alone, counted by records, with the count of the second that moves with the amount; the amounts of normal use from `op.LOG_RECORDS_OF_A_PROGRAM`; the bound of the records of the kernel; the count of the refused lines of `system.log` and its note, and the line of the kernel at the stop of a program whose refusals no later line said; the drain of the serial port at the tick of each processor and in a long wait for a lock, which writes only while the device takes bytes and for 100 µs at most, with the count of the lost records, the flush before the machine stops, the drain of the report of a fault, and the measure of its rate once; the fail line of every scenario on a lost record, during each wait and once on the whole log after the machine ends, with host tests; the check of `log_reader` that its storm child takes 900 of its 1000 log records of each second while it runs, and that each child gives its records back at its stop; a host test of the head of a line of the serial port.

No test runs the drain of a long wait for a lock.

Left: the serial port loses the lines of a flood (above, "The known limit"). The wait for the log lock and the time of the drain in wall time, above. The processor time of a budget is still a limit that each budget above counts; a thread that gets less time in a period because a sibling used it learns that the sibling ran.
