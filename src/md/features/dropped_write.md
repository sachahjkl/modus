# A dropped write

A dropped write ([`docs/glossary/storage.md`](../../../docs/glossary/storage.md), "Dropped write") is a write that the disk answers with Ok and does not keep. A firmware fault, a cache that loses power with no report, and a device that lies about a `Flush` all give it. No error comes back: the storage service learns of it only from the bytes that it reads later.

This file records what the storage service does with a dropped write, and how a machine test proves it.

## Purpose

The storage service promises that a commit is on the disk when the call returns, and that a loss of power never shows a part of a commit ([`docs/STORAGE.md`](../../../docs/STORAGE.md), "3.3 The commit and the open"). A disk that drops a write breaks the first promise, and nothing in the system can mend that: the bytes are gone. Two promises must still hold: the service never gives bytes that do not match their check, and it never shows a mix of two commits. A third one is the aim of the read back: a program loses one commit, the one with the dropped write, and never the state of an object.

## Constraints

- **The root before is the one way back.** A commit writes only to blocks that are free in the state of the last commit. The blocks that it stops naming become free only after its root is on the disk. So no write of a commit touches a block that the root before it names, and that root is whole whatever happened to the writes of the commit after it.
- **The next commit can end that way back.** After the root of commit N is on the disk, the blocks that N stopped naming are free, and commit N + 1 can write over them. Commit N + 1 also writes its root over the root before N. After it, no root on the disk is whole if N lost a write. So the service must know whether N is whole before the next commit starts.
- **No error comes back.** The block service answers Ok. Only a read can show the loss.
- **The device can lie at the read too.** A disk that loses a write from its cache can answer the read of the block from that same cache. No read in the system finds that: the check at the next open is the guard for it.

## The chosen form

**The commit read back** ([`docs/glossary/storage.md`](../../../docs/glossary/storage.md), "Commit read back"), in two steps of the commit itself. The commit call returns after them, so the next commit never starts before them.

1. **The blocks, before the root.** After the `Flush` of its blocks, the commit reads each block that it wrote back from the device and compares the bytes with the bytes that it wrote. If one differs, the disk did not keep a write: the service refuses the commit before it writes the root. The call gives `Device` with the unit `Dropped_Writes` and the count of the blocks that differ, and the log has one line: "storage: the read back of the commit of generation G found 1 block with other bytes: the disk did not keep it; the commit is refused before its root, and the service goes on from generation G - 1". No root on the disk names a block of the refused commit.
2. **The root, after its `Flush`.** The commit reads its root back. If it differs, the disk did not keep the root, and the root before is still the newest on the disk: the service refuses the commit with `Dropped_Writes` and a count of 1, and writes the line "storage: the read back of the root of the commit of generation G found other bytes: the disk did not keep it; the commit is refused, and the service goes on from generation G - 1".

On a refusal the service does not take the state of the commit: its state in memory stays the state of the root before, which is the state of the disk. The objects read as they were before the commit, at once, with no restart. The next commit takes the same generation, writes to blocks that are free in that state, and writes its root in the other place of the root before. The blocks of the refused commit are free in that state; the allocator of the service takes them again only after it went around the disk.

**A read that fails.** If the read of the blocks fails, no root names them: the service refuses the commit and goes on ("storage: the read back of the commit of generation G failed on the device: the commit is refused before its root"). If the write of the root or its read fails on the device, the root can be on the disk or not: the commit is not taken, the service makes no change until its next start, and the open of that start decides. Both cases have one line and one count, the commits for the next open to decide: "storage: the root of the commit of generation G: its write failed on the device; the commit is not taken, the open of the next start decides, and the service makes no change until then", or "...: its read back failed on the device; ...". The caller gets `Device` with no unit: the commit can still come back at the next start.

**A place of the root that drops each write.** A commit puts its blocks in free blocks, which move on at each commit, but its root has two fixed places. A place that drops each write would refuse each commit, each at the cost of its writes and a line. So after `ROOT_REFUSAL_LIMIT` (3) roots in a row that the disk did not keep, the service makes no change until its next start, and writes one line: "storage: the disk did not keep the root of 3 commits in a row: a place of the root drops its writes; the service makes no change until its next start, and its objects can still be read". Three tells such a place from one lost write; a root that reads back whole sets the count to 0. The second root of an erase counts too. A block that drops its writes needs no such rule: a refused commit frees it, and the next commits take other blocks first.

**One read back for all the commits.** The erase of versions needs the same read back before its second root, and it reads back that second root and its zeros too ([version_erase.md](version_erase.md)).

**The cost.** One read of a block for each block that the commit wrote, up to 64 in flight at once, and one read of the root: one round trip for each 64 blocks, and one for the root. A commit of one small object writes about five blocks. The service counts the blocks read back and the time of the reads since its start, and `stores()` gives both with the count of refused commits: they are a measure, and no test reads a bound from them.

## The open still checks

A device that answers the read back from the cache that lost the write passes it, and the commit is taken. A loss of power then leaves the root of that commit on the disk, naming a block that the medium does not hold. The open at the next start walks each block that the newest root names. If a block has a wrong check, and the root before it names no such block, the open refuses the newest commit and uses the root before it, with the line "storage: the newest root names a block with a wrong check, and the root before it names none: the root before it is used", then its usual line "storage: ok, generation G: ..." with the generation of the root before and `0 wrong`.

## The limit of the rule

- **A drop that the read back does not see.** A device that answers the read from the cache that lost the write passes the read back. If the machine runs on, the next commit is built on that commit, and both roots then name the wrong block. The open then takes the newest root with its damage, and the object that holds the block reads `Damaged`; the other objects are served. This is the rule "If each valid root names a wrong block, the newest one, with its damage" of `mount` in `src/library/private/storage/storage_mount`.

- **A root that the disk writes late.** The read back of a root can give other bytes because the device writes the root later, not because it lost it. Until the next root replaces it in that place, the late root of the refused commit names whole blocks, and a loss of power in that time opens the refused commit. This is the device that lies at the read, as above; the blocks of the refused commit stay out of use until the allocator goes around the disk, so the window ends at the next commit.

A refused commit has no other limit: with the read back of the blocks before the root, no root of a commit with a dropped block reaches the disk, so no later write can make such a root whole.

## The tests

**The host test** (`src/library/private/storage/storage_mount`, `dropped_write_test.odin`) checks a model of the writes, built by hand in the order of the service, with the code of the open; it does not run the service. A commit whose block of data the disk dropped, refused before its root; then the next commit from the state of the root before, on the blocks of the refused commit, with its root in the other place. Each image after each write of the next commit, each write of a block alone, and its root cut, opens at the root before or at the next commit, with no wrong block and no fallback. The model runs a second time with the bytes of the refused commit written again to the dropped block: no image shows the refused commit. The model takes the blocks of the refused commit again at once, the worst case: the allocator takes them only after it went around the disk. A third case is the second root of an erase that the disk dropped: the root before the commit of the end stays in its place, the next commit takes the blocks that only it names, and each image opens at the commit of the end or at the next commit.

**The machine test.** The tool serves the data disk (`tools/modustool/network_block_device.odin`). It drops two writes of the console, each the first block written that starts with a marker text; it keeps every other block, of that request too.

- **The dropped write.** The disk answers Ok and keeps nothing of the block of data of the second version of an object. The test waits for the line of the refusal, with the generation of the commit, and for the answer of the console: `Device` with the unit `Dropped_Writes`. The console then reads the first version of the object, on the same machine.
- **The dropped root.** The disk keeps the blocks of a later version of the same object and drops its root. The test waits for the line of the refusal of the root and for the same answer of the console, then reads the first version again.
- **The hidden write.** The disk answers Ok to the block of data of a fourth version of the same object (the store of the console has a limit of 3 blocks, too few for a second object), gives its bytes at each read, and never makes them durable: a cache that a loss of power empties. The read back passes, and the commit is taken. When the root of that commit is durable, the disk keeps a copy of its durable image: the image that a loss of power at that moment leaves. The tool opens it on the host with the code of the open: the open refuses the newest root, uses the generation before it, finds no wrong block, and gives the first version of the object. A second machine starts on that image, and waits for the line of the fallback and for "storage: ok" with that generation; the console reads the first version.
- **The end.** The durable image at the end of the first machine shows the limit: the commits after the hidden write name its block too, so the open takes the newest root, with the object damaged: its current version names the lost block.
- **The measure.** `storage.stores()` gives the blocks read back and their time.

The same test device drops one write of zeros of an erase of versions in `modustool test principals`: a write of a block of zero bytes over a block that holds a marker, the salt of the old file of a principal ([version_erase.md](version_erase.md), "The machine test of a dropped write of zeros").

## Refused forms

- **A read back of the root only.** A root that reached the disk says nothing of the blocks that it names: the dropped write in the test is a block of data under a whole root.
- **Trust in the `Flush`.** The `Flush` is the promise of the device; a dropped write is the device that breaks it. A commit that trusts it learns of the loss only at the next open, after the next commit ended the way back.
- **One read back of the blocks and the root, after the root.** It costs one round trip less. But the root of a refused commit then stays on the disk until the next root replaces it, and the next commit can write the bytes of the refused commit to the dropped block: the writes before a `Flush` reach the disk in any subset, so a loss of power can leave that root whole, and the open then shows a commit that the caller was told was refused. The read back of the blocks before the root leaves no such root.
- **A read back at the start of the next commit.** The caller of the commit would get Ok for a commit that the disk did not keep, and a service that stops before the next commit never reads back.
- **A stop of the service after one refusal, until its next start.** The state of the root before is in memory already: the service did not take the state of the refused commit. A stop would refuse each change of each program for a fault that the next commit does not repeat. A fault that each commit repeats is a place of the root, and the limit of three roots in a row stops for it.
- **A drop by the Nth write of a range of blocks in the test.** The order and the grouping of the writes come from the block service and from QEMU, which can join two writes into one request. A count can hit a block of the line history of the console in place of the object. A marker in the bytes names one block of one commit, whatever the order; the disk changes that block only, so the count of the blocks that differ is one.
- **A stop of the writes of the test disk after the dropped write.** It was the way to test the fallback of the open. The read back now refuses a dropped write before its root, so the open falls back only after a drop that the read back did not see: the hidden write gives that, and the copy of the durable image at its root gives the image of a loss of power, while the machine runs on.

## State

Built: the commit read back of the blocks before the root and of the root after it, with their refusals and their lines, the commits for the next open to decide, the stop after three roots in a row, the unit `Dropped_Writes`, the counts in `stores()`, the read back of the erase of versions through it, the host test of the model with the same bytes case and the dropped second root, the test device that drops one block, drops one root, hides one block and drops one write of zeros, the machine test `modustool test power` (the case `dropped_write_run`), and the dropped write of zeros in `modustool test principals`.

Left: a drop that the device hides behind its cache is found only at the next open, and a later commit can carry it. A read past the cache of a real device needs a command that the block service does not have.
