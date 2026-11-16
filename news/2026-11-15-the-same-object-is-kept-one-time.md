title: The same object is kept one time
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/STORAGE.md

A program that keeps the same bytes under two names now pays their blocks one time. The storage service finds an object of a store by its hash. When a commit gives an entry the bytes of an object that the store holds already, the entry names the blocks of that object, and no block of it is written.

In the machine test, the program `ranges` writes an object of 1 MiB under two names. The store holds 261 blocks for both: 256 blocks of data, 4 object nodes and the root. A change of one block of the second name writes 3 blocks, and the first name keeps its bytes. After a new start of the machine, a third name of the same bytes takes no block.

The index is in the memory of the service, and the open of the disk makes it from the entries. So a loss of power leaves nothing of it to repair. The service never trusts the hash of an entry alone: it computes the hash again from the blocks before an entry names them.
