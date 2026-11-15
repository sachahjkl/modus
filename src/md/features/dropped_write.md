# A dropped write

A dropped write ([`docs/GLOSSARY.md`](../../docs/GLOSSARY.md), "Dropped write") is a write that the disk answers with Ok and does not keep. A firmware fault, a cache that loses power with no report, and a device that lies about a `Flush` all give it. No error comes back: the storage service learns of it only from the bytes that it reads later.

This file records what the storage service must do with a dropped write, and how a machine test proves it.

## Purpose

The storage service promises that a commit is on the disk when the call returns, and that a loss of power never shows a part of a commit ([`docs/STORAGE.md`](../../docs/STORAGE.md), "3.3 The commit and the open"). A disk that drops a write breaks the first promise, and nothing in the system can mend that: the bytes are gone. The second promise must still hold: the service never gives bytes that do not match their check, and it never shows a mix of two commits.

## The rule

- The service finds a dropped write at the next read of its block: the bytes do not have the check that the pointer above them holds. A block of data is checked by its value at its place; each other block by the BLAKE3 hash of its bytes.
- The service never uses a block that does not have its check. A read of an object with such a block gives `Damaged`; it never gives the bytes.
- At the start, the open walks each block that the newest root names. If a block has a wrong check, and the root before it names no such block, the open refuses the newest commit and uses the root before it. The log has one line for it: "storage: the newest root names a block with a wrong check, and the root before it names none: the root before it is used". The open then writes its usual line, "storage: ok, generation G: ...", with the generation of the root before and `0 wrong`.
- The objects then read as they were at the commit before: the commit with the dropped write is lost whole, never in part.

## Why the root before is whole

A commit writes only to blocks that are free in the state of the last commit. The blocks that the commit stops naming become free only after its root is on the disk. So a commit never writes a block that the root before it names, and that root is whole whatever happened to the writes of the commit after it.

## The limit of the rule

The fallback holds for one commit. The service learns nothing at the dropped write, so it goes on from the state in its memory. The next commit is built on that state and names the same wrong block, and it can reuse blocks that the older root names. After that commit, both roots name a wrong block: the open takes the newest one with its damage, and the object that holds the block reads `Damaged`. The other objects are served. This is the rule "If each valid root names a wrong block, the newest one, with its damage" of `mount` in `src/library/support/storage_mount`.

A dropped write of a root block is not found. The disk then keeps the root before, which is whole: the commit is lost, and nothing on the disk is wrong. No check names a root, so no read can see the loss.

## The test

The tool serves the data disk (`tools/modustool/network_block_device.odin`). For this test it drops the first write that holds a block whose bytes start with a marker text. The test writes an object two times from the console: the second version is the marker, so the dropped write is the block of data of the second version. The commit continues with its object nodes, its tree nodes, its store block and its root, and each of those reaches the disk.

After the root of that commit is durable, the disk takes no more write: it answers nothing, as a disk with no power. So no later commit reaches the disk, and the test stays inside the limit of the rule. The tool then ends the machine.

The tool checks the durable image on the host with the code of the open: the open refuses the newest root, uses the generation before it, finds no wrong block, and gives the first version of the object. A second machine starts on that image. The test waits for the exact line of the fallback and the line "storage: ok" with that generation, and the console reads the first version of the object.

## Refused forms

- **A read back of each written block before the root.** The service would read each block of the commit after its `Flush` and compare it. It doubles the reads of each commit, and it proves nothing on a real disk: a disk that drops a write from its cache gives the bytes from that same cache at the read. The check at the open does not trust the disk.
- **The Nth write of a range of blocks as the target of the drop.** The order and the grouping of the writes come from the block service and from QEMU, which can join two writes into one request. A count can hit a block of the line history of the console in place of the object. A marker in the bytes names one block of one commit, whatever the order.
- **A drop with no stop of the writes after it.** The console commits its line history after each line, so a commit follows the dropped one. Both roots would then name the wrong block, and the test would check the limit of the rule, not the fallback.

## State

Built: the test device, the machine test `modustool test power` (the case `dropped_write_run`). The storage service needed no change: its open already refused the newest root and used the root before it.

Left: a dropped write that a later commit carries has no repair but a write of the object. A scrub that reads the blocks of the last commit back before the next commit is not built. It has the hazard of the read back above: a read that the cache of the disk answers proves nothing, so a scrub is useful only on a device whose cache it can pass.
