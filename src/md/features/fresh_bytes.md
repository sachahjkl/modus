# Fresh bytes for a running process

## Purpose

A process gets one seed at its start, and its random generator runs from that seed for the whole life of the process ([`docs/RANDOMNESS.md`](../../../docs/RANDOMNESS.md), "2. The generator"). Two facts make that weak for a process that runs a long time:

- **The processes of the start have no device bytes.** `input`, the compositor and each process that starts while the entropy device answers have a seed from the processor only ([entropy_device.md](entropy_device.md)). A key that such a process makes an hour later still has no byte of the device.
- **A leak of the state is for ever.** A reader that copies the memory of a process once (a fault, a debug grant that was given, a bug of another kind) has the key of its generator. Fast key erasure keeps the bytes before the copy secret, but each byte after it is known, for the life of the process.

This design gives each process that the root service starts new bytes, now and then, which it mixes into its own generator. A key that a process makes late in its life then has bytes newer than its start, and a reader who copied the state once loses it at the next mix.

The terms are in [`docs/glossary/randomness.md`](../../../docs/glossary/randomness.md): "Fresh bytes page", "Fresh bytes refresh".

## Constraints

- **No call and no kernel entry for a draw** ([`docs/RANDOMNESS.md`](../../../docs/RANDOMNESS.md), "1. Where a process gets random bytes"). A draw stays a copy from memory of the process.
- **No new right and no new operation.** A process gets the bytes as it gets the date page: a mapping that its starter places at a fixed range. A process with no handle reads nothing of another process.
- **The bytes of one process are not the bytes of another.** Bytes that every process reads add nothing against a process that reads them too.
- **A source that the system cannot check only adds.** The bytes of the device go into the key of the root service with the old key, never in place of it, as at the start.
- **The device and the root service do a bounded amount of work**, whatever the count of draws of the processes.
- **No log line for each refresh.** A line every period fills the log over a day.

## The chosen form

**The source.** The entropy device, through the entropy service, as at the start. The root service asks for one read of 32 bytes (`ENTROPY_READ_BYTES`) every 30 seconds (`FRESH_BYTES_PERIOD_MILLISECONDS`), the first one 30 seconds after the two reads of the start. It mixes each read into its generator with `random.device_bytes_mix`, with the same refusals as at the start: no byte, one value only, or the read before again.

**The bytes of each process.** After a read that it mixed, the root service draws 32 bytes of its generator for each process that has a fresh bytes page, and writes them there. Each process then has its own bytes, and each of them depends on the new read of the device and on the seed of the processor. No process learns the bytes of another. The root service knows them, as it knows the seed of each process that it starts.

**The page.** The root service creates one memory object of `STARTED_CAPACITY` pages (48) at its start, and maps it with Write in itself. The page of a process is the page of its place in the table `started`. The root service maps that page, read-only, at the fixed range `Fresh_Bytes_Page`, into each process that it starts by its name, into the compositor and into each disk process, and sets the bit of the range in the context value 20. The form of the page is `modus:contract/fresh_bytes`: a change count and 32 bytes, with the change count odd during a write, as the date page.

**The mix in the process.** The generator of a process reads the change count of its page at two moments, and nowhere else:

- at each refill, before it runs ChaCha20 for the next 800 bytes;
- in `random.fill_for_a_key`, before the bytes of a key.

When the count is even, not 0, and not the count that it mixed last, the generator copies the 32 bytes, checks that the count did not move during the copy, and sets its key to BLAKE3 of the domain text `kernel random: the fresh bytes of a process, version 1`, the old key and the bytes (`key_derive`). It drops its buffer, so the next byte comes from the new key. It erases its copy of the bytes. One change of the page is mixed once.

**The rate, and why.** 30 seconds bounds the time that a reader of one copy of the state keeps the stream: one period, then the next refill or key of the process. A shorter period gives no new protection that a process can use: the process mixes at its own refills, and a process that draws little refills rarely. The cost of one refresh is counted, not timed: one read of 32 bytes of the device and one interrupt, two BLAKE3 hashes in the root service (the hash of the read that finds a repeat, and the new key), 32 bytes of its stream for each process (at most 1024 bytes, two refills), and one write of one page for each process. A process pays one atomic load at each refill and each key, and one BLAKE3 hash for each change of its page.

**Why the mix is never done for each draw.**

- The bytes of the page change once a period. A mix at each draw would mix the same bytes again, and the same bytes again add nothing to a key that already has them.
- A mix drops the buffer of 800 bytes and hashes the key. For each draw, a draw of 32 bytes, about 0.1 to 0.3 us today, would cost a BLAKE3 hash and a refill of ChaCha20 each time.
- The protection of the bytes before a copy of the state is the fast key erasure, at each refill. The mix gives the protection after a copy, and that needs new bytes, not more mixes.
- A check at each draw would read memory of the root service on the hot path of each process: the refill and the key are the two moments where a stale key costs a secret.

**The lines of the log.** The root service writes one line at the first refresh, and no line for the next ones:

`root: the first fresh bytes: 32 bytes of the entropy device mixed into the random generator of the system, then 32 bytes of its stream in the fresh bytes page of each of <N> processes; a read every 30 seconds after this one, with no line`

A refused read of a refresh writes one line at the level warning. After 3 refused reads in a row, the root service asks for no more reads, with one line:

`root: the entropy device gave 3 refused reads in a row: no more fresh bytes for the running processes`

An entropy service that stops after the reads of the start writes one line too:

`root: the entropy service stopped: no more fresh bytes for the running processes`

A read that the device takes and never ends would hold every later read, as the entropy service serves one at a time. Each read has a deadline of the hang bound from its ask; past it, the reads in flight count as refused, the root service stops the entropy service, and one line says both ([missing_hardware.md](missing_hardware.md)):

`root: the entropy device did not answer a read in <seconds> seconds: <count> reads count as refused, and the entropy service stops: no more bytes of the device`

The deadline and its number: [`docs/RANDOMNESS.md`](../../../docs/RANDOMNESS.md), "3. The seed of the system, and what is claimed".

**The process `randomness`** shows the mixes of its generator in its window, and writes one line at its first mix:

`randomness: the fresh bytes of the root service are mixed into the generator of this process, at the change <C> of its page`

## Refused forms

- **One page for all the processes.** Each process would read the bytes of each other. A process that a reader took would then know the fresh bytes of every process, and they would protect none of them.
- **A call of the root service for fresh bytes.** It needs a ring for each process, and the root service would answer at the rate that each process chooses. The page has neither cost, and a process reads it with no wait.
- **A connection of each process to the entropy service.** It gives each process a part of a device, a new right, and the entropy service many clients; the root service is its one client.
- **The bytes of the device given as they are.** One read of 32 bytes would go to one process, or the same bytes to several. The stream of the root service after the mix gives each process its own bytes, from one read.
- **A memory object for each process.** Each object is one more handle of the root service, and a full handle table of the root service refuses the load of the next process (the comment of `fresh_bytes_memory` in `src/modules/system/root/fresh_bytes.odin` says how the table fills). One object of 32 pages is one handle.
- **A check of the page at each draw.** See "Why the mix is never done for each draw".
- **A refresh with no entropy device.** The stream of the root service alone holds nothing that the seed of a process did not already come from. A machine with no device writes no fresh bytes, and each page keeps the change count 0.
- **A line of the log for each refresh.** 120 lines an hour say the same fact.
- **A wake of each process at each refresh.** A process reads the page at its next refill or key. A wake would cost each process a turn of its loop for a key that it does not make. So the root service wakes no process, and `randomness` mixes at a refill of its live draw.

## Subtle points

- **A page that a new process takes.** A place of `started` serves a new process after the process before it stopped. The root service writes the page to zero with the change count 0 when it gives the page, so the new process reads no byte that the process before it read.
- **The change count only grows during the life of a process.** The root service adds 2 at each write. A process that sees a count equal to the count that it mixed last does nothing. A count that wraps after 2^31 refreshes (2000 years at one each 30 seconds) is not handled.
- **A read of the page during a write.** The generator reads the count, copies the bytes, and reads the count again. An odd count, or a count that moved, gives no mix at this moment; the next refill or key tries again.
- **The page is read-only in the process.** The process cannot erase the bytes there. A reader that copies the memory of the process later finds the bytes of the last change, which are already in the key; it does not find the bytes of the next change, which come after its copy.
- **The tag of a read.** The root service gives each read the number of the read in the tag of its command, and refuses a completion with another tag. A service that writes a completion that was not asked for then adds no bytes, and counts as a refused read.
- **A second thread.** A generator from `random.seed_for_a_child` has no page. A process that wants the page in the generator of another thread calls `random.fresh_bytes_attach` with the page of its context. Two generators that mix the same bytes stay apart: each has its own key.
- **The entropy report** keeps the facts of the two reads of the start only, so the line of `randomness` "64 bytes mixed after the gathering" stays true whatever the time of its start.
- **Its slot in the band.** `Fresh_Bytes_Page` has the value 15 of `Fixed_Range`, written in the enumeration, because the value is its bit in the context. The band has 17 slots (`SLOT_COUNT`), the values 0 to 16; the slots 3, 4, 5, 9, 10 and 13 of the ranges that left name no member, and the border refuses their bits (`fixed_ranges_of_word`). A new fixed range takes a free slot only when no module of an earlier build can still run; else it needs a larger `SLOT_COUNT`, which the compiler says.
- **The time of a refresh is a fact that a process sees.** The change count says when the root service wrote. It is the clock of the root service, not a fact of another process.

## State

Built: the read of the device every 30 seconds, the mix in the root service, the pages of 32 bytes for each process, the mix at each refill and each key, the line of the first refresh, the stop after 3 refused reads, the deadline of a read and the stop of the entropy service past it, the line of `randomness` and the row of its window, the host tests of the contract and of the generator, and the machine test of `modustool test random`.

Left: the processes that the root service starts with no mappings (the device services, the TPM service, `input`) and the processes that another process starts get no page. A starter that gives its child a page of its own is not built (ROADMAP.md, "Fresh bytes for the services and the children of a process").
