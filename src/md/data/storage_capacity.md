# The capacity of the data disk: its size, its stores, its names and its trees

The storage service uses each block of its device, holds thousands of stores on one disk, takes names of 255 bytes, and freezes folders of thousands of entries. The guide is [`docs/STORAGE.md`](../../../docs/STORAGE.md), "3. The format on the disk".

## Purpose

The format `STORAGE4` had four fixed caps that a person meets on the first day: the service used the first 1 GiB of any disk, a disk held 60 stores (each process has one), a name had 64 bytes, and a content tree held 512 entries (a whole-store snapshot 128 objects, a history 64 snapshots). Each was a constant of the code, not a budget. This file records how each cap became the device, a budget, or a bound that real use does not meet.

## Constraints

- **A loss of power leaves the state of one commit** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "9. A storage engine with one private store per process"). Each new block follows the rule of copy on write, and the tool checks each image that a loss can leave.
- **Memory is supplied by the caller** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller"). A table whose size follows the disk is memory of a budget, never a static array sized for the largest disk.
- **No backward compatibility.** The format changes in place: `STORAGE5`, `MODTREE2`. An older disk is not read.
- **A store is named by a number in the tables of the service** (its owner of each block, its counts, its damage). That number must be stable while the service runs.

## The chosen form

**The disk is the device.** The service reads the count of blocks of its device and binds the tables of the open to memory of that size (`storage_mount.state_layout`, `state_bind`): for each block a count of names (4 bytes), an owner (2 bytes) and three bits (in use, wrong, damaged under). A disk of 64 GiB costs 102 MiB of these tables. The service creates that memory from its budget; a budget that pays less gives the tables of half as many blocks, then half again, and the service uses the first blocks of the disk and writes `Disk_Larger_Than_Tables`. A root that names more blocks than the tables hold is refused whole (`Mount.larger_than_capacity`): a root is never opened in part. The search of a free block passes 64 blocks at a time over a word of the bitmap with each bit set.

**The stores are a paged table.** The root holds the pointers of up to 251 pages of the store table; a page holds 63 cells of 64 bytes, each one store: 15 813 stores on a disk. A store keeps its cell for the life of the disk, so its number (page and cell) is stable: the owner of each block, the counts and the flags of the open and of the service are indexed by it. A commit changes one store, so it writes one page again to a free block, after the last change of the cell's count, and the root names the new page. A page is named by the root only, not by a store: its block is outside the counts of the stores (`STORE_TABLE_OWNER`), so a limit of a store never pays for it. A page with a wrong check damages its 63 stores only; the service makes no new store in it.

**A name has 1 to 255 bytes**, as in the other file systems, in a key of 256 bytes so that each record of a node stays aligned on 8 bytes. A leaf holds 11 entries and a branch 14 children; the B+ tree holds 10 levels. A log fact names an object with a text view, whose long text goes in the out-of-line area of the fact.

**A content tree has entries of variable length** (`MODTREE2`): the kind, the length of the name, the name, the hash. A node holds up to 4096 entries, about 1.2 MB with names of 255 bytes, a sixth of that with short names. A lookup walks the entries in their order and stops past the name: its check already walks them.

**A snapshot history is memory of its caller**: a table of records and one pool of objects that the snapshots share. The count of snapshots and of objects is the memory that the caller gives; a full table or pool is a refusal with no change. A diff is read in pages from a count.

## Refused forms

- **A B+ tree of the stores.** It has no bound at all, but a store then has no stable number: each change of the tree moves the cells, and the owner of each block, the counts and the flags would need a key by name. The paged table keeps one number for each store at the cost of a bound of 15 813 stores, past any real use of one disk. Refused for now; a disk past that bound would need it.
- **Static tables sized for the largest disk.** A static array for 1 TiB is gigabytes of the module of the service on every machine. Refused: the tables follow the device.
- **The counts of names on the disk.** It removes the memory of the tables, so a disk of any size opens with a small budget, but each commit would write the counts of each block that it changes, in a structure that a loss of power must leave whole. It is the form for disks of many terabytes; it waits for a disk that the budget of the service cannot hold.
- **A fixed stride of 289 bytes for each entry of a content tree.** Binary search with no walk, but a folder of short names costs six times its bytes on the disk and on the wire. Refused.
- **A tree of tree nodes for a folder of any size.** It lifts the bound of 4096 entries of a node, at the cost of a second format of node and of a split rule that each writer of a tree must follow. It waits for a folder past 4096 entries.
- **A history with its tables inside its record.** The record of 64 snapshots of 128 objects was 2.4 MB with names of 255 bytes, whatever the use. Refused: the caller gives the memory.

## Subtle points

- **The page of a commit is written after the count of its cell is final.** `plan_commit` changes `used`, then writes the page with its check: a page written earlier would carry a stale count under a valid check.
- **The block of the page before is freed after the root**, as each block that a commit stops naming, but outside the change of the reference counts: the erase of versions writes no zeros over it, as it holds names and counts, no byte of an object.
- **The open counts a page of the store table as a block of one name.** A page named two times is a fault of the engine, as a store block named two times.
- **The hash index is sized by roots**, not by blocks ([hash_index.md](hash_index.md)).
- **One commit releases at most 262 144 blocks** (the table of the changes of a commit): the removal of an object larger than 1 GiB in one commit is refused with `Full`, unit `Commit_Blocks`.
- **The guest disk image has its own bound of a path**, 124 bytes: a name of 255 bytes is a name of a store, not of a path of a guest.

## State

Built: the format `STORAGE5` with the paged store table, the tables of the open bound to memory of the size of the device, the service that binds them from its budget and halves them when the budget refuses, names of 255 bytes in the store, the trees, the notes, the editor and the load of a disk process, `MODTREE2` with 4096 entries, the history in the memory of its caller with diffs in pages, the writer of the tool that builds the B+ tree of a store, the host tests (the geometry of a disk of 64 GiB and of the largest disk, the edges of a name of 255 and 256 bytes, 100 stores in two pages, a damaged page, a disk larger than its tables, a tree of 4096 names of 255 bytes, a snapshot of 1000 notes). Left: the removal of an object larger than 1 GiB in steps, the counts of names on the disk for disks past the budget, and a tree of tree nodes for a folder past 4096 entries.
