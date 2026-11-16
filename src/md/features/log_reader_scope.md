# The log scope of a reader

## Purpose

A program shows its own log records, with the time, the level, the channel and the value runs that the kernel keeps, without the right to read the whole machine. Before this design, the log service gave its tables to a caller that acts for the principal and to no other caller. A program that wanted its own records back had to hold a grant that also showed it every other program. The guide is [`docs/TOOLS.md`](../../../docs/TOOLS.md), "Who reads which records".

## Constraints

- A program sees no other program ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", row 1). The records of the log are facts of every program.
- The memory of the log holds every record. A program that maps it reads the whole machine. So the choice of the records is made by the owner of that memory, the log service, never by the reader.
- The root service is the one source of grants. It writes the grant of each connection, and the caller cannot change it (`isolated.Service_Command`).
- The grant of a connection is one word: 46 bits of amount that each service gives a meaning, the number of the principal, and the bit that the caller acts for that principal.
- No queue drops a record in silence, and a reader knows what it lost.

## The chosen form

**The log scope.** The log scope of a connection to the log service is what its caller receives from `records` and `value_runs`:

- **The whole log**: the caller acts for the principal (the bit `CALLER_ACTS_FOR_PRINCIPAL`). The console and `remote` have it. This is the form of before.
- **Its own records**: every other caller. The root service writes the program slot and the program serial of the caller in the amount of the grant, and the log service gives the records whose program is that slot with that serial, and no other record.

The contract package `modus:contract/log_scope` holds the form of the amount and the one test of a record against a scope. The root service and the log service both use it.

**Own records are named by the program slot and the program serial.** A program slot serves a new program after the last handle of the program before it closes; the program serial changes with each new program in the slot. The two numbers name one program, as they do on the disk program page and in the monitor. So the kernel writes the program serial in each log record (`op.Log_Record.program_serial`), beside the slot. It sets the serial as it sets the slot: a program cannot write a record in the name of another one.

**A reader of its own records sees no number of the whole log.** The number of a record in the whole log, and a count of the records that the kernel wrote over, tell a reader how many records the other programs wrote: a measure of their activity, and a covert channel between two programs that hold no ring between them (one writes N records, the other reads the gap). [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", row 17 reduces such side channels; this one is closed. The numbers of a reader name its own records only, and its records come from its own log ring, which only its own records fill ([own_log_ring.md](own_log_ring.md)): the records of the others never push them out. The kernel counts the records of each program (`log_records_written`, under the log lock) and writes that count in each record as its own number (`op.Log_Record.own_number`), from 0 at the start of the program. A reader of its own records receives the own number as `number`, gives `after` in own numbers, and its `lost` counts its own records from `after` that its ring no longer keeps. The own number has 32 bits and starts again from 0 after 2^32 records; the kernel reads `after` by its distance to its count, which is exact because the ring holds 64 records.

**The record became narrower to hold the two numbers.** A log record has 256 bytes and had no free place of 8 bytes. The slot of the program and the slot of the thread are 1 byte each now: the kernel has 64 program slots and 256 thread slots, and an assertion in the kernel keeps both at most 256.

**A torn copy of the whole log is never kept.** A reader of its own records receives copies that the kernel made under the log lock (`Log_Read`), which are never torn. A reader of the whole log copies the ring itself. The kernel writes record W over the record W − 2047 and stores `written = W + 1` only after the whole record, so while it writes, `written − 2047` is the number of a record that can be half written. A copy of the old head (the slot and the serial of the reader) with the new text would give one program the text of another one. So a reader keeps a copy only when `written − number < 2047` after the copy, with an acquire fence before that second load, and the first record that it reads is one past the record under the writer (`op.log_first_kept`, `op.log_copy_kept`, with a host test of the edge). So a reader copies 2046 records at most, one fewer than the ring holds. The kernel puts a release fence before the first store of each record, after the store of `written` for the record before: inside one long text no lock orders the two. The window of the log and every other reader of the whole log use the same two rules.

**The amount.** Bits 0 to 31 are the program serial, bits 32 to 45 the program slot: the 46 bits of the amount, exactly. The slot 0 is the kernel, which is never a caller: an amount of 0 names no program, and its caller receives no record.

**A program with no grant reads none.** The log service is reached through a connection, and the root service gives a connection only to a program whose role names the service (`callable_of`), or to the console. A program with no such grant has no connection, and reads no record through the service. Its records stay on the serial port, and in the log for a reader of the whole log. A connection to the log service is the grant to read the own records; the grant to act for the principal makes it the whole log.

**A revocation narrows the scope.** `revoke("console", "acts_for_principal")` sends the new grant to each connection of the console. The new grant of its connection to the log service has its own records only, so the console then reads its own records and no other. A connection that kept its old grant would keep the whole log while the record of the root service says that the grant is revoked. So before it changes anything, the root service checks that each service ring holds one Grant record for each connection of the program, with the room for one Disconnect of each connection of that service still kept. If one ring is short, it refuses the revocation with `No_Slot`, changes nothing, and writes a warning; the principal asks again. The root service is the one writer of a service ring, so the room cannot shrink between the check and the sends.

**The program `log_reader`** is the test of the form. Its role is the grant `Connect`, with the log service as its one service, and the grant `Image`, for the description of the exports. It writes one record before it connects, reads the log from the own number 0, and checks that it receives exactly that record, as the own number 0, with `lost` 0. The machine test starts it two times: the second run must not receive the records of the first one, which the ring still keeps with the same name, the same texts and often the same slot. Only the serial tells them apart.

## Refused forms

- **A grant that names a channel, for the records of every program.** A channel is a name that the writer chooses, not a fact that the kernel sets: each program can write each channel. A reader of the channel `devices` would receive each record that any program wrote in it, and a program cannot know who reads the name that it chose. The reader then sees other programs, which property 20 forbids for a program that does not manage the system. A reader that must see other programs holds the grant to act for the principal: it is rare, visible and revocable.
- **Its own records, narrowed to some channels.** No border is there: the program wrote these records itself. A reader chooses its rows with `where(log.records(0), "channel", "...")`.
- **The records of a program by its name.** A starter gives the name of a program. Another program can start a child with the same name, and a disk program has a nickname that its principal chose. A name is not the identity of a program.
- **The records of a program slot, with no serial.** A new program in the slot would read the records of the program before it, while the ring keeps them.
- **The number of the whole log for a reader of its own records, and a count of every lost record.** It tells the reader how many records the other programs wrote. See "A reader of its own records sees no number of the whole log".
- **A cursor that the log service keeps for each connection.** The service would number the rows that it gave to one connection. A record that the kernel wrote over before the first call has no number then, and a new connection of the same program starts again from 0: the numbers would name no record. The own number of the kernel names each record of a program once.
- **The end of a connection whose Grant record did not fit.** The Disconnect goes to the same full ring and is lost too, while the root service forgets the connection: the service keeps the old grant, and the caller the whole log. The check of the room before any change refuses the revocation instead.
- **A first record number in place of the serial.** The root service would read the head of the log before each start and give the number to the log service. The number has 64 bits and the amount has 46. The serial is the identity of a program that the system already uses.
- **The reader maps the memory of the log and skips the records of others.** The reader then holds every record.
- **Each program reads its own records with no grant.** Each other access of a program comes through a handle that someone granted. The log service is no exception: a program reaches it through a connection.

## Subtle points

- **Two numbers for one row.** A reader of the whole log receives the number of the whole log, a reader of its own records the own number. The two never mix in one answer: the scope of a call is one.
- **Two calls of the kernel for one answer.** `records` and `value_runs` of a reader of its own records each call `Log_Read` once. A record that the program writes between the two calls is in the second answer only.
- **The result counts the rows of the scope.** The integer result of `records` and `value_runs` counts the rows that the caller can receive from `after` on, not all the records of the log.
- **The records that are about a program are not its own.** The line "root: started log_reader" is a record of the root service; a line of the kernel about a program is a record of the kernel (slot 0). A reader of its own records receives neither.
- **The amount bits of a connection to the log service are not a store.** The root service counts the grant `store` of a caller from a connection with an amount; it counts it for the storage service only.
- **The serial wraps.** The program serial has 32 bits and grows at each creation in a slot, a failed one too. After 2^32 creations in one slot, a serial comes back, and a record of the earlier program with that serial would match while the ring keeps it. Only the root service makes a connection with a scope, so a program cannot drive that count; the 2047 records of the ring are gone long before 2^32 creations.
- **A reader whose own records are all gone.** It receives no row, and `lost` is in the first row only, so it learns no count of what it lost: only that it has no record now. The result 0 is true. Only its own records push them out.
- **An `after` far from the count.** An `after` more than 2^31 before the count of the program is read as past the count: no record comes back. It holds own records only.
- **The records of the programs that a program started.** Property 20, row 1, lets a program see the programs that it started, so a starter that reads the records of its children agrees with the property. The log service does not know who started a program; this form is a planned work of `ROADMAP.md`, not a refused one.

## State

Built: the program serial and the own number in the log record, the two rules of a reader of the ring, the contract package `log_scope`, the grant that the root service writes for each connection to the log service, the check of the room of each service ring before a revocation, the own records in `records` and `value_runs` from the own log ring of the caller, host tests of the form and of the edge of the ring, and the program `log_reader` with its machine test of two runs.

Left: the whole log is not split by principal. A caller that acts for principal 1 reads the records of the programs of principal 0 too. A starter does not read the records of its children. The side channels of the log that stay are in [own_log_ring.md](own_log_ring.md), "State".
