# Fresh bytes for a running program

## Purpose

A program gets one seed at its start, and its random generator runs from that seed for the whole life of the program ([`docs/RANDOMNESS.md`](../../../docs/RANDOMNESS.md), "2. The generator"). Two facts make that weak for a program that runs a long time:

- **The programs of the start have no device bytes.** `input`, the compositor and each program that starts while the entropy device answers have a seed from the processor only ([entropy_device.md](entropy_device.md)). A key that such a program makes an hour later still has no byte of the device.
- **A leak of the state is for ever.** A reader that copies the memory of a program once (a fault, a debug grant that was given, a bug of another kind) has the key of its generator. Fast key erasure keeps the bytes before the copy secret, but each byte after it is known, for the life of the program.

This design gives each program that the root service starts new bytes, now and then, which it mixes into its own generator. A key that a program makes late in its life then has bytes newer than its start, and a reader who copied the state once loses it at the next mix.

The terms are in [`docs/glossary/randomness.md`](../../../docs/glossary/randomness.md): "Fresh bytes page", "Fresh bytes refresh".

## Constraints

- **No call and no kernel entry for a draw** ([`docs/RANDOMNESS.md`](../../../docs/RANDOMNESS.md), "1. Where a program gets random bytes"). A draw stays a copy from memory of the program.
- **No new right and no new operation.** A program gets the bytes as it gets the date page: a mapping that its starter places at a fixed range. A program with no handle reads nothing of another program.
- **The bytes of one program are not the bytes of another.** Bytes that every program reads add nothing against a program that reads them too.
- **A source that the system cannot check only adds.** The bytes of the device go into the key of the root service with the old key, never in place of it, as at the start.
- **The device and the root service do a bounded amount of work**, whatever the count of draws of the programs.
- **No log line for each refresh.** A line every period fills the log over a day.

## The chosen form

**The source.** The entropy device, through the entropy service, as at the start. The root service asks for one read of 32 bytes (`ENTROPY_READ_BYTES`) every 30 seconds (`FRESH_BYTES_PERIOD_MILLISECONDS`), the first one 30 seconds after the two reads of the start. It mixes each read into its generator with `random.device_bytes_mix`, with the same refusals as at the start: no byte, one value only, or the read before again.

**The bytes of each program.** After a read that it mixed, the root service draws 32 bytes of its generator for each program that has a fresh bytes page, and writes them there. Each program then has its own bytes, and each of them depends on the new read of the device and on the seed of the processor. No program learns the bytes of another. The root service knows them, as it knows the seed of each program that it starts.

**The page.** The root service creates one memory object of `STARTED_CAPACITY` pages (32) at its start, and maps it with Write in itself. The page of a program is the page of its place in the table `started`. The root service maps that page, read-only, at the fixed range `Fresh_Bytes_Page`, into each program that it starts by its name, into the compositor and into each disk program, and sets the bit of the range in the context value 20. The form of the page is `modus:contract/fresh_bytes`: a change count and 32 bytes, with the change count odd during a write, as the date page.

**The mix in the program.** The generator of a program reads the change count of its page at two moments, and nowhere else:

- at each refill, before it runs ChaCha20 for the next 800 bytes;
- in `random.fill_for_a_key`, before the bytes of a key.

When the count is even, not 0, and not the count that it mixed last, the generator copies the 32 bytes, checks that the count did not move during the copy, and sets its key to BLAKE3 of the domain text `kernel random: the fresh bytes of a program, version 1`, the old key and the bytes (`key_derive`). It drops its buffer, so the next byte comes from the new key. It erases its copy of the bytes. One change of the page is mixed once.

**The rate, and why.** 30 seconds bounds the time that a reader of one copy of the state keeps the stream: one period, then the next refill or key of the program. A shorter period gives no new protection that a program can use: the program mixes at its own refills, and a program that draws little refills rarely. The cost of one refresh is counted, not timed: one read of 32 bytes of the device and one interrupt, two BLAKE3 hashes in the root service (the hash of the read that finds a repeat, and the new key), 32 bytes of its stream for each program (at most 1024 bytes, two refills), and one write of one page for each program. A program pays one atomic load at each refill and each key, and one BLAKE3 hash for each change of its page.

**Why the mix is never done for each draw.**

- The bytes of the page change once a period. A mix at each draw would mix the same bytes again, and the same bytes again add nothing to a key that already has them.
- A mix drops the buffer of 800 bytes and hashes the key. For each draw, a draw of 32 bytes, about 0.1 to 0.3 us today, would cost a BLAKE3 hash and a refill of ChaCha20 each time.
- The protection of the bytes before a copy of the state is the fast key erasure, at each refill. The mix gives the protection after a copy, and that needs new bytes, not more mixes.
- A check at each draw would read memory of the root service on the hot path of each program: the refill and the key are the two moments where a stale key costs a secret.

**The lines of the log.** The root service writes one line at the first refresh, and no line for the next ones:

`root: the first fresh bytes: 32 bytes of the entropy device mixed into the random generator of the system, then 32 bytes of its stream in the fresh bytes page of each of <N> programs; a read every 30 seconds after this one, with no line`

A refused read of a refresh writes one line at the level warning. After 3 refused reads in a row, the root service asks for no more reads, with one line:

`root: the entropy device gave 3 refused reads in a row: no more fresh bytes for the running programs`

An entropy service that stops after the reads of the start writes one line too:

`root: the entropy service stopped: no more fresh bytes for the running programs`

**The program `randomness`** shows the mixes of its generator in its window, and writes one line at its first mix:

`randomness: the fresh bytes of the root service are mixed into the generator of this program, at the change <C> of its page`

## Refused forms

- **One page for all the programs.** Each program would read the bytes of each other. A program that a reader took would then know the fresh bytes of every program, and they would protect none of them.
- **A call of the root service for fresh bytes.** It needs a ring for each program, and the root service would answer at the rate that each program chooses. The page has neither cost, and a program reads it with no wait.
- **A connection of each program to the entropy service.** It gives each program a part of a device, a new right, and the entropy service many clients; the root service is its one client.
- **The bytes of the device given as they are.** One read of 32 bytes would go to one program, or the same bytes to several. The stream of the root service after the mix gives each program its own bytes, from one read.
- **A memory object for each program.** Each object is one more handle of the root service, and a full handle table of the root service refuses the load of the next program (the comment of `demand_cache_memory` in `src/modules/system/root/font_service.odin` says how the table fills). One object of 32 pages is one handle.
- **A check of the page at each draw.** See "Why the mix is never done for each draw".
- **A refresh with no entropy device.** The stream of the root service alone holds nothing that the seed of a program did not already come from. A machine with no device writes no fresh bytes, and each page keeps the change count 0.
- **A line of the log for each refresh.** 120 lines an hour say the same fact.
- **A wake of each program at each refresh.** A program reads the page at its next refill or key. A wake would cost each program a turn of its loop for a key that it does not make. So the root service wakes no program, and `randomness` mixes at a refill of its live draw.

## Subtle points

- **A page that a new program takes.** A place of `started` serves a new program after the program before it stopped. The root service writes the page to zero with the change count 0 when it gives the page, so the new program reads no byte that the program before it read.
- **The change count only grows during the life of a program.** The root service adds 2 at each write. A program that sees a count equal to the count that it mixed last does nothing. A count that wraps after 2^31 refreshes (2000 years at one each 30 seconds) is not handled.
- **A read of the page during a write.** The generator reads the count, copies the bytes, and reads the count again. An odd count, or a count that moved, gives no mix at this moment; the next refill or key tries again.
- **The page is read-only in the program.** The program cannot erase the bytes there. A reader that copies the memory of the program later finds the bytes of the last change, which are already in the key; it does not find the bytes of the next change, which come after its copy.
- **The tag of a read.** The root service gives each read the number of the read in the tag of its command, and refuses a completion with another tag. A service that writes a completion that was not asked for then adds no bytes, and counts as a refused read.
- **A second thread.** A generator from `random.seed_for_a_child` has no page. A program that wants the page in the generator of another thread calls `random.fresh_bytes_attach` with the page of its context. Two generators that mix the same bytes stay apart: each has its own key.
- **The entropy report** keeps the facts of the two reads of the start only, so the line of `randomness` "64 bytes mixed after the gathering" stays true whatever the time of its start.
- **The last slot of the band.** `Fresh_Bytes_Page` is the 16th member of `Fixed_Range`, and the band has 16 slots: the next fixed range needs a larger `SLOT_COUNT` first, which the compiler says.
- **The time of a refresh is a fact that a program sees.** The change count says when the root service wrote. It is the clock of the root service, not a fact of another program.

## State

Built: the read of the device every 30 seconds, the mix in the root service, the pages of 32 bytes for each program, the mix at each refill and each key, the line of the first refresh, the stop after 3 refused reads, the line of `randomness` and the row of its window, the host tests of the contract and of the generator, and the machine test of `modustool test random`.

Left: the programs that the root service starts with no mappings (the device services, the TPM service, `input`) and the programs that another program starts get no page. A starter that gives its child a page of its own is not built (ROADMAP.md, "Fresh bytes for the services and the children of a program").
