# The losses of the window of the log

## Purpose

The process `log` reads the ring of the log and counts the records that it did not read. Its count must say one thing: whether the window keeps up with the log once it reads it. A reader of the window and the main machine test both use that count.

## Constraints

- The ring keeps 2047 records, and a reader copies the last 2046 at most (`op.log_first_kept`, `op.log_copy_kept`; [log_reader_scope.md](log_reader_scope.md)).
- The process starts at any time. The records written before its start grow with each new line of each process that runs before it.
- A count that depends on the length of the boot proves nothing about the reader, and a new log line of an unrelated process breaks a check of it.

## The chosen form: two counts

The process splits the records that it did not read into two counts:

- **Gone before its start**: the records that the kernel wrote over before the process kept its first record. This is the number of the first record that it keeps, because its reader starts at record 0. A torn copy of that first record counts here too: the process had read no record yet.
- **Lost since**: each record after the first kept record that the process did not read. This is a fault of the reader: the window was too slow for the writers.

The window and the line `log: ok, ...` show both counts. Only "lost since" is in the color of a failure when it is not 0: a count of records gone before the start is a fact of the boot, not a fault.

The line is written at the end of the first read of the ring. At that moment, the reader went from the oldest kept record to the newest one, at the place in the ring that the writer reaches first. So "0 lost since" in that line proves that the reader caught up with the log from its oldest record with no gap. The machine test requires it, and prints the count gone before the start as a measure.

## Refused forms

- **One count, required to be 0.** It held only while the boot wrote fewer than 2046 records before the process started. Each new line of a process broke the check, and a larger ring only moved the edge.
- **Start the process `log` earlier.** A process started earlier still depends on the order of the start, and each new line before it moves the edge again. The check must not depend on what other processes write.
- **Start the reader at the newest record.** The window then shows no record of the boot, and the counts of the levels and of the channels lose their meaning.

## Subtle points

- During the first read, the reader is at the oldest record: the writer writes over the record right before it. A copy of a record is a copy of memory. A writer writes a record through a kernel entry, and no longer waits for the serial port ([log_side_channels.md](log_side_channels.md)), so the reader keeps up only while it copies faster than the writers enter the kernel. A reader that does not keep up loses records there: that loss is real and counts as "lost since".
## The other checks of the log in the main test

A check that reads a record of the boot through the ring has the same fault as one count: it holds only while the boot is short. So each check of the log reads a fact that the ring still holds when it runs, or reads the boot where each line stays:

- **The stages of the boot.** The kernel writes one record for each stage of the boot, on the channel `boot`. The test waits for the seven lines on the serial port, right after "kernel: ok": the serial port keeps each line. The window no longer writes its count of the records of the kernel in the channel `boot`: that count depended on the boot, and the window shows each channel with its count.
- **A record of the kernel keeps its channel.** The test starts the process `fault` just before the check. The kernel writes "kernel: process fault stopped: page fault ..." on the channel `fault`, at the level warning, and the step `Record` reads it through `log.records`.
- **A record keeps the kind of each value.** At its start, the process `log` writes "log: the memory of the log: <count> records in <size>": the size is a value of the kind size. The step `Record` finds that record, and `log.value_runs({record})` reads the runs from its number. The tool writes the number of the record that the last step `Record` found in place of `{record}`: a scenario cannot know the number of a record before it runs.
- **`log.records(0)`** gives the rows that the ring still holds, from the oldest one. The check needs any rows of `Record`, not a given record, so it does not depend on the boot.

Refused: a check of the records of the boot through `remote` early in the test. `remote` starts after many other processes, so that check also depends on what they write, only with more room. Refused also: a count of the records of the boot in the kernel, read with a new operation or a new field of the head of the log. It adds a contract to the kernel for a test, and the serial port already keeps the lines.

## State

Built: the two counts in the window and in the line, the check of the main machine test, and the other checks of the log that do not depend on the length of the boot.
