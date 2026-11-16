title: A dropped write is found at its own commit
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/STORAGE.md

A disk can answer Ok to a write and not keep it. Before, the storage service found such a write only at the next start of the machine. A commit made in the meantime could then damage the object for good.

Now each commit reads back the blocks that it wrote before it writes its root, then reads back its root. If one block differs, the service refuses the commit, writes one line on the log, and serves the objects as they were before that commit, at once. The root of a refused commit never reaches the disk.

In the test, the disk of the tool drops the block of data of a second version. The console gets the refusal, and reads the first version on the same machine.

The read back costs one read for each block that a commit writes. `storage.stores()` gives the count of these reads and their time. A disk that answers the read from the same cache that lost the write is not found this way: the check at the next start stays for that case.
