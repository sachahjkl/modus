# The hash index: the same object is kept one time

The storage service finds an object of a store by its hash. So when a commit gives an entry the bytes of an object that the store holds already, the entry names the block tree of that object, and the bytes take their blocks one time. The guide is [`docs/STORAGE.md`](../../docs/STORAGE.md), "4.7 The same object one time".

## Purpose

A program that keeps two copies of one document, a picture under two names, or the same module file twice pays the blocks two times with no index. The model names an object by its hash ([`docs/STORAGE.md`](../../docs/STORAGE.md), "1. The model"): two entries with one hash name one object. The hash index makes the disk follow the model.

## Constraints

- **The disk format does not change for it.** An entry keeps the hash of its object already. The reference counts are already in memory, and the open counts them again from the roots.
- **A loss of power must leave nothing to repair.** A commit is one switch of the root block; a structure on the disk beside the trees would be one more thing that a cut write can leave half done.
- **A block is named from one store only** (`src/library/contract/store`): the limit of a store counts its blocks, and the open takes a block that two stores name for a fault of the engine.
- **The disk is not trusted.** The hash in an entry is a value that the open does not compare with the bytes. A wrong hash must never make one entry name the bytes of another object.
- **The cost of a commit stays bounded by the blocks that it changes**, not by the count of the objects of the store.

## The chosen form

**The index is in the memory of the service, and the open makes it.** It is a table in `storage_mount.State`, beside the reference counts, built by the same walk. For each block that is the root of the current state of an object (the state that an entry names, in a tree of the store or in its removal queue), the table keeps the first 8 bytes of the hash of the entry, the size, the check of the root, and the count of the entries that name that root. A table of slots finds a root by its key: the 8 bytes, the size and the store. A root is one block, so the table never holds more roots than the disk has blocks, and it has twice that many slots.

**The cost of the slots is bounded.** Three rules bound it, because a program can choose its bytes and a hostile disk can choose the hash of each entry:

- The first slot of a key mixes the 8 bytes with a key of the slots that the service draws from its seed at each start (`HASH_SLOT_MIX`, a product by an odd constant). No party knows it, so no party can choose hashes whose first slots make one long run.
- One key has at most one slot. A second root with the same key keeps its record and gets no slot, so a thousand entries with one lying hash make no run.
- A search, an insert, and the scan past each slot that a removal moves back read at most `HASH_PROBE_LIMIT` (32) slots. At a load of one half with first slots that no party chooses, a longer run is far rarer than one insert in a million. A root that finds no slot inside the bound keeps its record with no slot: a later commit does not find it, and nothing else changes.

**A power loss cannot leave it wrong.** The index is never written. The open of each image makes it from the entries of the root that it uses, as it makes the reference counts. A commit changes the index in memory only after its root is on the disk, from the entries that the commit changed: the value before and the value after of each one.

**Where it is used.** A commit that gives an entry a new state (a write, a commit of ranges, a restore, a clone) looks up the hash of that state first:

1. The work on the block tree computes the values and the hash of the new state, and writes nothing yet (`storage_object.work_hash`).
2. The service looks up the roots of that hash in the store: the same store, the same size, the same 8 bytes, a root that the service does not know as damaged.
3. It confirms each root that it finds: it computes the hash of that state again from its block tree on the disk (the path of the last block, checked) and compares the 32 bytes. Only a confirmed root is used. A root whose blocks give another hash takes the key of that hash, so an entry that lies costs one confirmation. One lookup confirms at most `HASH_CONFIRMATION_LIMIT` (4) roots.
4. With a confirmed root, the work drops what it made (`storage_object.work_drop`: each name that its copies gave goes back), and the entry names the found root: one more name of that block. No block of the object is written.
5. With none, the work writes its blocks as before (`storage_object.work_write`).

A restore and a clone write no block, so step 4 changes only which root the entry names: a restore of a version whose bytes another entry holds names the root of that entry, and the blocks of the version are freed when the version is thinned.

**Reference counts, not a mark from the roots.** A found root takes one more name, as a clone does. A change of one of the two entries is copy on write as always: the new state copies the nodes on the paths that it changes, and the other entry keeps its root. A removal takes one name; the blocks are free when their count goes to 0. A mark from the roots would walk each tree at each removal, or need a collection step; the counts already free each block at the commit that drops its last name.

**A share of a tree learns nothing of the rest of the store.** A writable share reaches one tree of the store, and `usage()` gives it the blocks of the whole store. Two channels follow, one in each direction:

- The holder writes bytes. If its write took no block because the rest of the store holds the same bytes, it learns that the store holds them.
- The holder writes a guess. If a later write of the maker took no block because the guess holds the same bytes, the holder learns, from the count or from its own removal, what the maker wrote.

The rule that closes both: **while a store has a writable share of a tree open** (a share that can write, whose root is not the root of the store), no commit of the store looks up a hash, and each root that a commit of the store adds to the index is hidden: it has a record, so that its entries are counted, and no slot, so it is never a candidate, until its last entry goes. Besides, a commit looks up a hash only when the caller's own connection reaches the whole store: the program of the store, or a share of the root of the store. A share of the root and a read-only share open no channel: the first reads the whole store, and the second writes no guess.

What is left: the open does not know which roots a share made in an earlier start, so it makes each root a candidate. A holder that wrote a guess, lost its share, and gets a new writable share after a new start of the machine, can learn by the removal of its guess whether the maker wrote those bytes while no such share was open. Closing it needs a mark of the origin of each root on the disk; the format does not have one, and the leak needs a new start between the two shares.

A share names no store with `open_store`, not even the store of its maker: a place on the root of the store would reach and change the whole store.

## The cost of a write

- A lookup: at most `HASH_PROBE_LIMIT` slots; with at most half of the slots in use, a few slots.
- A confirmation, for each candidate, at most `HASH_CONFIRMATION_LIMIT` of them: the hash of a state, which reads the object nodes on the path of its last block and the last block, through the cache. At most `OBJECT_LEVEL_LIMIT` nodes and one block of data each.
- The update at a commit: one insert and one removal for each entry that the commit changed, each bounded by `HASH_PROBE_LIMIT` slots for each slot that it moves.
- A found root saves the writes of the block tree: the data and the object nodes of the new state. The values and the hash are computed before the lookup, so the hashing work is the same as before.
- The table costs 10 MiB of the memory of the service: 32 bytes for each block of the disk, and 4 bytes for each of twice as many slots.

## Refused forms

- **An index on the disk** (a B+ tree of hashes in each store). Each commit would write its path, a loss of power would need it to agree with the trees, and the open walks every entry anyway. Refused: it adds writes and a second truth.
- **A hash in each version, and versions in the index.** A version entry has no hash: the format would change (fewer versions in a leaf), or the open would compute the hash of each version. The current states are the objects that a program names; a version shares its blocks with the state after it already. Refused.
- **One index for all the stores.** A block would be named from two stores, so the limit of one store would pay for the blocks of another, and a write that takes no block would tell one principal what another one has ([`docs/STORAGE.md`](../../docs/STORAGE.md), "1.2 The hard points", the secrecy). Refused.
- **Trust the hash of the entry.** A disk that another party changed can give an entry the hash of other bytes; the entry would then name the bytes of another object. Refused: each candidate is confirmed from its blocks.
- **The full 32 bytes of the hash in the table.** 8 MiB more of memory for a comparison that the confirmation makes anyway. Refused.
- **An equal block inside two different objects** (a search by the value of each block). The value of a block depends on its place, so two equal blocks at two places have two values; a table of the blocks would be as large as the disk and its search would cost each commit. Refused: the unit that the model names by its hash is the object.

## Subtle points

- **Two roots can have one hash.** A state that a commit made before its root was found (a root that the service knew as damaged, a commit while a writable share of a tree was open), and a disk that another service wrote, give two roots for one hash. The first root of a key gets its slot, the others a record only. The open counts them: `Mount.repeated_hashes` is the count of roots of current objects whose store has another root with the same key. When the root with the slot goes, the others stay without a slot until the next open: a loss of sharing only.
- **The confirmation checks the path of the last block only.** The other blocks of the found state were checked by the open, or by the commit that wrote them. A block that goes wrong after that damages each entry that names it, as for a clone.
- **The global count of free blocks.** A store that fills the disk sees, by its own refusal `Full`, that a commit of another store took no block. It learns only that the other store wrote a copy of its own bytes, not what they are.
- **The count of the current objects counts a shared block two times** (`Store_Block.current_blocks`), as for a clone, so a change at the limit of a store can be refused early. The blocks in use of the store (`usage().blocks`) count it one time.
- **A found root can be the root of the state before of the same entry.** The entry names it again, and its version keeps its own name: two names, as for a restore.
- **The measure of a commit of ranges** gives 0 blocks of the block tree written when the root was found.

## State

Built: the table in the open, its change at each commit, the key of the slots, the bound of a run, the lookup with its confirmation and its rekey for a write, a commit of ranges, a restore and a clone, the rule of a writable share of a tree, the host tests of the table, of the work and of the index after a run of commits against a new open, the check of each image of a loss of power, the cases of the machine tests `ranges` and `hierarchy`. Left: a module named by its hash in the store `programs` still reads all the objects of the store ([`docs/STORAGE.md`](../../docs/STORAGE.md), "5. Not built: the next steps").
