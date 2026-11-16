# The log limit and the time of a `Log`

## Purpose

A reader of its own records reads them from its own log ring, which only its own records fill ([own_log_ring.md](own_log_ring.md)). Two other facts of the log still told a program how much the other programs wrote:

- **A refused record.** The log limit of each second was counted in the budget of the program and in each budget above it. A program whose own count was low got `No_Budget` when a sibling, or any program below a common budget, wrote much in that second.
- **The time of a `Log`.** The operation wrote its line on the serial port under the one log lock. The serial port is slow, so a `Log` waited for each line that the other programs wrote before it.

Both are a measure of the activity of other programs, and a covert channel between two programs that hold no ring between them. This design closes the first and narrows the second to a short section of memory copies. The guides are [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The serial port and the log limit", and [`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "Locks of the kernel".

## Constraints

- A program sees no other program, and side channels are reduced ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", rows 1 and 17).
- Each resource is a handle with a limit, and a program divides its limit among its children ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", row 16).
- The serial port never loses a line in normal use. It is the log of the host: the machine tests wait for its lines, in the order of the records, and a line of a fault of the kernel must reach it.
- No queue drops a record in silence. A full queue stops its writer, or it has a stated capacity and counts each refusal.

## The irreducible choice

The serial port is one device with a finite rate, shared by all programs. A writer that is faster than the device has three answers: it waits for the device, which is the time channel; its lines are lost; or each budget holds a fixed part of the rate, and the sum stays below what the device keeps. This design takes the third answer: it is property 20, row 16, applied to the lines of the serial port.

## The chosen form

**The log records of each second are an amount that a budget holds.** `Budget_Create` moves them from the budget that pays to the new budget, as it moves pages, programs and threads, and the end of the budget gives them back. A budget counts only the records of its own programs, against its own amount. A `Log` of N records spends N: the kernel counts the records that the text takes after its copy, as `log_record` cuts it (`log_records_of_text`). So a refusal says only that the budget of the writer wrote its own amount in this second, and `Budget_Read` gives the amount that the budget still holds after its children.

The reason: a limit that two budgets share always tells each one what the other used. A division with no sharing tells nothing. The cost is that a child does not use the records that its starter or a sibling leaves unused.

**The count of the second moves with the amount.** Without it, a program that wrote its whole amount could start a child, which starts at a count of 0, write through it, stop it and start it again: each start would give new records in the same second, bounded only by the rate of the starts. So at `Budget_Create`, in the same second, the child takes the part of the count of its parent that its new amount no longer holds: `min(N, max(0, count − (amount − N)))` for a child of N records. At the end of a budget, its count of this second returns to its parent. Both run under the frame lock, with a compare and exchange on the word of the count. The sum of the counts of a tree in one second then stays at most the amount of its top. A child learns from its first count only what its own starter wrote, which its starter already knows.

**The machine and the kernel have half of the whole log in each second.** The kernel writes records of its own: the stop of a program on a fault, a refused return, a full fault ring, a kernel event. A program can cause them as fast as it faults, so the kernel bounds them: at most `op.LOG_RECORDS_OF_THE_KERNEL`, 64, in each second after the first tick. A line of the kernel past the bound is not written and is counted; the next line that fits is preceded by one record `kernel: <n> lines of the kernel were over its limit of 64 records in each second`, inside the bound. The kernel gives the root service `op.LOG_RECORDS_OF_THE_MACHINE`: `LOG_RECORD_CAPACITY / 2 − LOG_RECORDS_OF_THE_KERNEL`, 959. The counts of two seconds can come back to back at the edge of a second: 2 × (959 + 64) = 2046 records, under the 2047 of the whole log, so the drain never has more than the whole log to write before the log writes over a record. Before the first tick, each writer drains its record at once, so the boot needs no bound.

**The rate that the drain needs.** The longest line of one record is `op.LOG_SERIAL_LINE_BYTES_MOST`, 206 bytes: the head, 152 bytes of text and the end of the line. So the drain must keep `op.LOG_SERIAL_BYTES_OF_A_SECOND`: (959 + 64) × 206 = 210 738 bytes in each second. The drain of a tick ends after `SERIAL_MICROSECONDS_OF_A_TICK`, 100 µs by the cycle counter, whatever bytes it wrote: interrupts are off for no longer than that, a tenth of a tick, and a device interrupt waits at most that. The drain keeps the need when a byte costs less than about 0.47 µs on one processor, or less with more processors that tick; a port write that exits to QEMU costs more. The first drains that wrote 64 KiB together write their measured rate on the log once, as a measure: the line says if the device of the machine keeps the need.

**The amounts of the root service** come from `op.LOG_RECORDS_OF_THE_MACHINE` and are checked by the compiler:

| Who | Records of each second | Why |
|---|---|---|
| The root service itself | 120 | its lines of the starts, the stops and the calls, many in the first seconds |
| `limits` | 40 | its burst of 100 reaches the limit |
| `log_reader` | 112 | its storm child takes 100, it keeps 12 |
| `console` | 72 | its 12 call hosts take 4 each, it keeps 24 |
| `compositor` | 48 | the lines of the elements of each window |
| `inspect` | 36 | its tables |
| `rings` | 36 | its 6 nodes take 4 each |
| `locks` | 32 | its 5 children take 4 each |
| `frames` | 28 | its 4 twins take 4 each |
| `imports` | 16 | its 2 children take 4 each |
| each other program, and each disk program | 7 | what is left for the 54 other slots |

`LOG_RECORDS_OF_A_PROGRAM` is the rest divided by the slots: (959 − 120 − 420) / 54 = 7, and an assertion keeps it at least `system.LOG_RECORDS_OF_A_LINE`, 4: the records of the longest line that `system.log` sends in one call. The rows of log records are a table of their own (`log_records_exceptions`), whose count the compiler checks. A call host of `system.call_host_start` gets the records that its starter gives, 4 by default. A starter gives each child that writes 4. Three kinds of children keep 0, because they write no line: the child of `errors`, whose case measures a refused `Log` with the raw operation; the programs of the shares of `scheduler`; and the children of `kernel_events`, which have no log handle.

**`system.log` never waits.** A line that the kernel refuses is dropped and counted in the program (`log_lines_refused`, one atomic count for its threads). The next line that the kernel accepts is preceded by one record `<n> lines of this program were refused by its log limit`, inside the amount. A line longer than the whole amount, and each line of a program with 0 log records, are counted the same way; the kernel also counts each refused record in the budget, which `Budget_Read` gives to the starter. So no line is dropped in silence, and no thread with a deadline waits for a second: the compositor, the input service and the console under its lock write at once or count.

**The serial port is written by a drain, not by `Log`.** `Log` and the records of the kernel write the records of the log only, under the log lock. The serial writer writes on the serial port the records of the whole log that the serial port does not have yet, in their order. The line of a record is the line of before: `[name:channel] text` for a program, the text alone for the kernel; a long text that the log splits into records is one line again.

- **One writer of the serial port, from any processor.** The serial writer (`serial_writer`, the identifier of the processor plus one) is a word that a processor takes with a compare and exchange. The tick of each processor tries it, so a hang of one processor does not silence the others. A processor that waits for a lock longer than `LOCK_WAIT_BEFORE_DRAIN_MILLISECONDS` tries it too, at each turn of its wait: a hang of the machine still writes the lines that explain it. The flush before the machine stops and the report of a fault of the kernel wait for it a bounded time. `serial_next` keeps the order. It is not a lock of the lock order: no path waits for it with no end, and its holder takes no lock.
- **The drain writes only while the device takes bytes, and for a bounded time.** It writes up to 16 bytes, the queue of the device, when the line status says that the transmit register is empty, and the tick leaves the drain when it is not, or after `SERIAL_MICROSECONDS_OF_A_TICK`: no spin with interrupts off. The line of the record in progress waits in a buffer of the drain (`serial_line`) for the next tick. Between two writes, the drain of a tick answers `processor_sync`, and leaves when the machine stops.
- **The drain reads the whole log as a reader does.** It copies each record into one buffer of the kernel (`serial_copy`), and keeps the copy only when the rule of a reader of the whole log holds (`op.log_first_kept`, `op.log_copy_kept`). It takes no log lock: a `Log` never waits for the serial port.
- **A record that the drain did not reach in time is counted.** When the log wrote over records before the drain wrote them, the serial port gets the line `kernel: <n> records of the log did not reach the serial port`. Each scenario of the tool fails at once on that line: in normal use it never comes.
- **The time of the drain is not charged.** The tick counts the time of the thread that it interrupted before the drain, and moves the start of the next count past the drain: no budget pays for the lines of others.
- **Before the first tick**, each writer of a record writes the serial port at once, after it frees the log lock: the timer does not run yet, and a hang of the start must still show its lines.
- **The machine stops after the flush.** `machine_stop` writes the records that the serial port does not have yet before it ends the machine, so the last line of a test reaches the host. It waits at most 1 s for another writer, and writes at most the whole log: 2047 records, at most 422 KB.
- **A fault of the kernel writes the waiting records first.** The report takes the serial writer, writes the records that the log holds and the serial port does not, then its own lines: the records before a fault are often its cause. The flush and the report wait for the device, with interrupts off: they end the machine.

## Refused forms

- **The limit counted in each budget above, as before.** It is the channel that this design closes.
- **A count of the calls in place of the records.** A call of 4096 bytes writes 27 records: the amount would not bound the lines.
- **A limit of the whole machine beside the amounts of the budgets.** It is one shared count, the same channel between any two programs.
- **The amounts of before, 1000 for each program.** The machine then wrote 64 000 calls in each second, up to 1.7 million records, far more than any drain keeps: a line was lost as soon as a program wrote fast.
- **The serial line written by `Log` after the log lock, under a lock of the serial port.** The `Log` then waits for the lines of the others under that lock: the channel moves, it does not close.
- **A wait for the serial port when the drain is behind.** A writer that waits for the drain learns how much the others wrote.
- **The drain on the first processor only.** A hang of that processor with interrupts off silences each line of the others, often the lines that explain the hang.
- **The drain that spins for the device.** At 115 200 baud, 1 KiB is 89 ms with interrupts off at each tick.
- **The drain with no bound at each tick, or a bound in bytes.** A port write that exits to QEMU costs 2 to 10 µs, so 512 bytes are whole milliseconds with interrupts off. Only a bound in time bounds the time.
- **`system.log` that waits for the next second.** A refused line then stops the calling thread for up to 1 s: the frame loop of the compositor, the loop of the input service, the console under its output lock.
- **`system.log` that drops a refused line with no count.** A line would be lost in silence.
- **A new budget that starts at a count of 0.** A loop of starts of a child would write past the amount in one second.
- **The records of the kernel with no bound.** A program that faults in a loop would make the kernel write past the half of the whole log.
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
- **The note of the refused lines is a line of its own.** It costs one record of the amount, so a program at its amount writes the note only in a second where it has room; the lines that it lost meanwhile add to the count.

## State

Built: the log records of each second as an amount that a budget holds and counts alone, counted by records, with the count of the second that moves with the amount; the bound of the records of the kernel; the amounts from `op.LOG_RECORDS_OF_THE_MACHINE`; the count of the refused lines of `system.log` and its note; the drain of the serial port at the tick of each processor and in a long wait for a lock, which writes only while the device takes bytes and for 100 µs at most, with the count of the lost records, the flush before the machine stops, the drain of the report of a fault, and the measure of its rate once; the fail line of every scenario on a lost record, during each wait and once on the whole log after the machine ends, with host tests; the check of `log_reader` that its storm child takes 100 of its 112 log records of each second while it runs, and that each child gives its records back at its stop; host tests of the head of a line of the serial port and of the records of a second against the whole log.

The amounts of the table are not measured: no measure gives the most lines of each program in one second yet. A program that writes more than its amount loses lines, and the note "<n> lines of this program were refused by its log limit" names it. No test runs the drain of a long wait for a lock.

Left: the wait for the log lock and the time of the drain in wall time, above. The processor time of a budget is still a limit that each budget above counts; a thread that gets less time in a period because a sibling used it learns that the sibling ran.
