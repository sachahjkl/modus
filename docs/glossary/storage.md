## Storage

### Object

An object is bytes that never change, named by their hash: a new content is a new object.

The object is the unit of stored data. A module, a font, a picture and the text of a note are the same thing: bytes and their hash. Today an object is an entry of kind object in a tree. A process writes it with `storage.write(place, name, data)`, or by ranges and `commit`, and reads it with `read` or `read_range`. A write gives the entry a new state, and the state before becomes a version. An object is not a file: it has no path, no owner and no permission bits.

The design: `docs/STORAGE.md`, "1. The model".

Do not use: file, blob, inode.

### Tree

A tree is an object that names other objects and trees, each by an entry with a name.

A tree is the only kind of folder. A handle on a tree reaches what is under it and nothing above it. On the disk, each tree is its own B+ tree of nodes, with no limit of entries but the disk. A process makes a tree with `storage.add`, opens it with `storage.open(place, name)`, which gives a new place, and lists it by pages with `storage.list`. A tree is not a directory: no entry names its parent. Today a tree that changes has no hash.

The design: `docs/STORAGE.md`, "1. The model".

Do not use: directory, folder, list (for this), manifest, catalog (for this).

### Entry

An entry is one name of a tree and what it names: an object or a tree.

An entry is the only link between a name and data. It holds the kind, the size, the generation, the time and the date of its last change, the hash of an object, the pointer of its root, and the version index of an object. A name has 1 to 64 bytes, no byte `/`, and is not `.` or `..`, so a name always goes one step down. A rename moves an entry with its versions. An entry is not a path and not a hard link.

The design: `docs/STORAGE.md`, "3.2 An entry".

Do not use: directory entry, link, file name, path.

### Node

A node is one block of the B+ tree of a tree: a leaf of up to 24 entries, or a branch of up to 50 children.

A node keeps a tree of any size in blocks of 4096 bytes, with a search in a few reads. A commit never writes over a node that the root on the disk names: it writes each changed node to a free block, then the node above it (copy on write). The open of the disk checks each node; a node that breaks a rule of its format is damage of its store. A node is not an object node, which is a block of the block tree of one object.

The design: `docs/STORAGE.md`, "3.1 The blocks".

Do not use: page (for this), bucket, inode.

### Store

A store is a cell that names one tree now: the one thing of storage that changes.

The store is the unit of access and of accounting. A grant of the root service gives a process a connection to one store, with a limit of blocks. A commit moves the store to another tree in one atomic step. A process sees the counts of its store with `storage.usage()`. A store is not a volume or a mount: a process never names a store by a path. It is not a head of a version control system either: today the versions are kept for each object, not for the store.

The design: `docs/STORAGE.md`, "1. The model".

Do not use: reference (for this), volume, file system, mount, head.

### Place

A place is a number that a connection to the storage service holds: the names of a path from the root of the connection, and the right to change or read only.

A place lets a process name a tree with no path in a call: each export takes a place and one name, as `storage.write(place, name, data)`. The place 0 is the root of the connection. `storage.open(place, name)` gives a new place, and `storage.close(place)` frees it. A place follows the names, not the bytes, and is valid on its connection only. A place is not a file descriptor and not a working directory: it is not a handle of the kernel, and it never reaches above its root.

The design: `docs/STORAGE.md`, "4.1 Places".

Do not use: file descriptor, directory handle, working directory, path.

### Share

A share is a connection to the storage service that the service itself makes for a caller, whose root is a tree of the store of the caller, with or without the right to change.

A share gives another process one part of a store. `storage.share(place, read_only)` gives the caller two handles, which it gives to the other process with `Handle_Give`. That process reaches the tree and what is under it, and nothing above. `storage.unshare(share)` revokes the handles in each process. When the grant of the store of the maker ends, each of its shares ends too. A share is not a mount: it adds no name to any tree.

The design: `docs/STORAGE.md`, "4.3 Read only, and revocation".

Do not use: mount, bind, export (for this), link.

### Removal queue

The removal queue is the trees of a store that a remove took out of their tree and whose blocks the storage service has not freed yet.

A remove of a large tree must not be one huge commit. So `storage.remove(place, name)` of a tree takes the entry out of its tree in one commit, and the name is gone at once. The service then frees the queue in small commits, when no call waits. The queue is on the disk, so a loss of power loses no step. Its blocks stay counted in the store until they are free. The removal queue is not a trash: nothing in it comes back, and no process reads it.

The design: `docs/STORAGE.md`, "4.4 The removal of a tree".

Do not use: trash, bin, garbage list.

### Version

A version is the state of one object at one commit: its size, the root of its block tree, and the generation, the time and the date of that commit.

Versions remove the save action: each commit that changes an object keeps the state before it as a version, with no call of the process. A version costs only the blocks that only it names. A process reads them with `versions`, `version` and `compare`, and uses them with `restore` and `clone`. The retention rule and the limit of the store thin them; a version erase ends them all. A version is not a backup on another disk, and not a revision that a process makes on purpose.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service".

Do not use: snapshot (when it means one object), backup, revision, undo step.

### Current version

The current version is the state of an object that its last commit made: what a read gives.

The entry of the object names the current version directly: its size, its hash and the root of its block tree. It is not in the version index. A commit makes a new current version, and the current version of before becomes a version. A pending change of a connection is not yet the current version: the connection sees it on its reads, and each other connection sees the current version.

The current version is not a working copy: it is on the disk, at the commit that made it.

The design: `docs/STORAGE.md`, "3.2 An entry".

Do not use: head, working copy, latest revision.

### Version index

The version index is the blocks of one object that list its versions: an index block that names leaf blocks, which hold the version entries, the oldest first.

The entry of an object points to its version index. A commit that changes the object rewrites the index and the leaf that it changes: 2 blocks, copy on write. The index also keeps the time of the last application of the retention rule to the object. A version index with a wrong check does not lock its object: `versions`, `version` and `restore` give `Damaged`, and the next commit drops those versions. A version index is not a journal: it records states, not operations, and nothing replays it.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service".

Do not use: history file, journal, log.

### Shared block

A shared block is a block that two states, two objects or two nodes name: a block that a change did not touch, or a block of a clone.

Copy on write makes shared blocks: a commit writes new blocks only on the paths that it changes, and the new state names each other block of the state before. A store counts each distinct block one time in its blocks in use. Example: after 1000 writes in an object of 8 GiB, the version before them holds 4 blocks of its own, and the others are shared. Two objects of one store with the same bytes share their blocks through the hash index. A shared block is not an extent reference.

The design: `docs/STORAGE.md`, "Versions, thinning and the limit".

Do not use: deduplicated block, extent reference.

### Reference count

A reference count is, for each block in use, the count of what names it: the nodes that name it, and the entries and versions that name it as a root.

The reference count lets the storage service free a block at the commit that drops its last name, with no walk of the disk. A node with no name left gives one name less to each of its children. The counts are in the memory of the service only: the open of the disk makes them again. Only object nodes and blocks of data can have a count above 1. A reference count is not a link count of a file: no process sees it.

The design: `docs/STORAGE.md`, "Versions, thinning and the limit".

Do not use: link count, refcount (in text).

### Thinning

Thinning is the removal of versions of an object in a commit, by the retention rule or at the limit of the store; its blocks that no other state names become free.

Thinning keeps the versions from filling the disk, with no action of a process. The retention rule thins an object at a commit of that object. At the limit of the store, a change that does not fit thins the oldest versions of the store in its own commit. A change that does not fit with each earlier version thinned is refused before any thinning, so a refused change destroys no history. Thinning is not a collection of garbage, and a freed block keeps its bytes: a version erase writes zeros over them.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service".

Do not use: garbage collection, pruning, cleanup, compaction.

### Version erase

A version erase ends each version of one object in one commit, then writes zero bytes over each block that this commit freed.

It removes an old state that is a hazard: after a change of the passphrase of a principal, `unlock` erases the versions of its file, so the old secret opens nothing on the disk. `storage.erase_versions(place, name)` needs the grant to erase versions. The current version stays, and a block that another state names keeps its bytes. A version erase is not a thinning, not a remove, and not an erase of the medium: a flash disk or a snapshot of the host can keep the old sectors.

The design: `docs/STORAGE.md`, "4.8 The erase of versions".

Do not use: wipe, shred, secure delete, purge.

### Grant to erase versions

The grant to erase versions is the start grant `Versions_Erase`: the storage service lets its holder end the versions of the objects of its own private store, with a version erase.

Versions protect the principal against a fault of the process that writes an object, so no process ends them by itself. The root service gives this grant only to a process that keeps a secret that an earlier version must not keep: today `unlock`. A call of `erase_versions` with no such grant is refused with `No_Grant`, unit `Versions_Erase`. A share never has it. The grant is not a right over another store, and not a right to remove an object.

The design: `src/md/features/version_erase.md`.

Do not use: delete right, history right.

### Retention rule

The retention rule is which versions the storage service keeps: each version for 10 minutes, then the newest of each hour until it is one day old, then the newest of each day.

The rule keeps many versions of a recent state and few of an old one, with no setting. The service applies it to an object at a commit of that object. The age of a version is the smaller of its age by the date and by the time since the format, so a wrong clock never makes a version older. It is not a policy that a process sets: it is the same for each store, and the limit of the store can still thin a version that it keeps.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service".

Do not use: backup policy, history limit.

### Clone

A clone is a new entry that names the block tree of another object: the two share each block until one of them changes.

A clone copies an object of any size in one commit that writes no block of data. `storage.clone(place, name, new_name)` makes `new_name` under the same place name the root of the block tree of `name`. A state of `new_name` before the clone becomes a version. After the clone, a change of either object writes new blocks on its own paths only. A clone is not a copy of the bytes, not a hard link (a change of one does not change the other), and not a reflink of a file system.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service".

Do not use: copy (for this), hard link, reflink.

### Restore

A restore is a commit that makes a version of an object its current version again; the current version before it becomes a version, so nothing is lost.

`storage.restore(place, name, generation)` writes no block of data: the entry names the root of the block tree of the version. The result is the generation of the commit. Because the state of before becomes a version, a restore can itself be undone by another restore.

A restore is not a rollback of the store: it changes one object, and each other object keeps its current version.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service".

Do not use: revert, rollback, undo.

### Time since the format

The time since the format is the milliseconds of the storage service since the format of the data disk: the root block keeps it at each commit.

A version needs a time that never goes back, also when the machine has no date. At its start, the service takes the time since the format from the root and adds its own time since its start. Each entry and each version keeps it beside the date, and the retention rule counts its hours and days from it. It is not the time since the start of the machine, and not a date: it does not count the time when no machine ran.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service".

Do not use: uptime, timestamp.

### Snapshot

A snapshot is the tree that a store named at one commit; the system does not keep it apart.

The state of a store at a generation G is, for each object, its version with the highest generation at or below G. So the versions of each object hold each snapshot, with no structure of its own. In the model, the versions of a store will be the trees that it named; that history of a store is a later step.

A snapshot is not a copy and not a backup.

The design: `docs/STORAGE.md`, "1.3 Where the model does not hold as it was first stated".

Do not use: checkpoint, backup.

### Private store

A private store is the store of one process: the root service names it after the process and gives it a limit of blocks, and no other process sees it.

The private store replaces the shared file system: a process keeps its data where no other process can read or damage it. A process with the grant `Store` gets a connection to it. Two principals that run one process have two stores, as `notes` and `notes.principal.1`. The limit of blocks counts the versions too. Another process reaches a part of it only through a share. A private store is not a home folder of a user and not a container.

The design: `docs/PROPERTIES.md`, "8. No global, mutable, shared file system".

Do not use: home directory, app data, container.

### Document

A document is an object that belongs to the principal and not to one process, which a process reaches only through a grant of the document service.

A document solves what the private store does not: data that several processes open, such as a text or a picture. In the design, the document service owns the documents, shows the picker where the principal chooses one, returns a handle to the process that asked, and records each grant so that it can be listed and revoked. The document service is not built. A document is not a file of a shared file system: a process cannot list or open the documents by itself.

The design: `docs/ARCHITECTURE.md`, "U6. Document service".

Do not use: file, user file.

### Module store

The module store is the set of all modules and system data, each named by the hash of its content.

In the model, the module store is the objects of the tree of the system: the root service loads each module, font and pointer theme by its hash, and an object can come by any channel, because its hash proves it. It is not built: today the boot image is the source of each module, except the module files of the disk processes in the store `module_files`. The module store is not a store of the storage service, and not a repository of packages with versions by name.

The design: `docs/STORAGE.md`, "5. Not built: the next steps".

Do not use: package store, repository, the Nix store.

### System description

The system description is the list of hashes that defines one version of the whole system: the kernel, then each module and each resource of the boot image, with its kind, its size and its BLAKE3 hash.

The system description makes the system reproducible and verifiable: two machines with the same description run the same bytes. The signing key of the machine signs its hash. The boot program verifies the signature and each hash before it starts the kernel, and the root service checks the boot image against it again. The system description is not the boot image, which carries the bytes, and not a generation of the storage service.

The design: `docs/TRUSTED_BOOT.md`, "3. The system description".

Do not use: image, generation, manifest, profile, system list.

### Distinct result

A distinct result is one content of one output of a build (a module, its LLVM IR, its object, the boot program) among the contents that several builds of the same source gave.

The identity of a module is the hash of its content, so one source must give one distinct result for each output. `modustool check` builds everything a second time and compares; `modustool repeat` builds again and again. When an output differs, each distinct result stays in `build/different_builds/`, and the tool prints where the first difference is. A distinct result is not a version of a module: it is a fault of the build to correct.

The design: `docs/REPRODUCIBLE_BUILD.md`, "6. What is proved, and what is not".

Do not use: variant (except in the names of the kept files), version.

### Storage service

The storage service is the service that keeps the stores, their trees, their objects and their versions on the data disk, through the block service of that disk.

The storage service is the one process that writes the data disk. Each other process reaches its own store through a connection that the root service gives, with a limit of blocks. Each change is one commit, on the disk when the call returns, and a stop of the machine never shows a part of a commit. At its start, the service opens the disk and checks each block. The storage service is not a file system: it has no paths, no mount, and no global tree of names.

The design: `docs/STORAGE.md`, "4. The interface of the service".

Do not use: file system.

### Root block

The root block is the block of the data disk that names each store, with the generation of the last commit; the disk has two places for it.

The root block makes a commit atomic. A commit writes its new blocks to free blocks, asks the disk to keep them (`Flush`), then writes the root block in the place of the older of the two roots. The root has its own check. At the start, the storage service takes the valid root with the highest generation. The root block is not a superblock that a process can read: only the storage service and the modus tool read it.

The design: `docs/STORAGE.md`, "3.3 The commit and the open".

Do not use: superblock, uberblock, meta page.

### Commit

A commit is one change of the stores that is on the disk completely or not at all: new blocks first, then a new root block.

The commit is the unit of change and of history: each commit that changes an object makes a version, and each commit has its own generation. Each export that changes something is one commit, on the disk when the call returns: `write`, `add`, `rename`, `remove`, `restore`, `clone`, and `commit` for pending changes. A refused commit changes nothing. A commit is not a save that a process asks for, and not a transaction that holds several calls open.

The design: `docs/STORAGE.md`, "3.3 The commit and the open".

Do not use: transaction (for this), save, sync.

### Commit read back

The commit read back is the step of each commit in which the storage service reads back from the device each block that the commit wrote, before its root, and then its root, and compares the bytes with the bytes that it wrote.

It finds a dropped write while the root before the commit is still whole. If the bytes differ, the service refuses the commit (`Device`, unit `Dropped_Writes`) and keeps the state of the root before, with no restart. It costs one read for each block that the commit wrote. It is not a check of the medium: a device that answers the read from the cache that lost the write passes it.

The design: `src/md/features/dropped_write.md`.

Do not use: write check, readback.

### Generation

A generation is the number of a commit: each commit has the generation of the commit before it plus 1, on the whole disk.

The generation orders every state on the disk. The root block keeps it, so the start takes the root with the highest valid one. Each entry and each version keeps the generation of its commit; `version`, `restore` and `compare` name a version by it. A generation counts the commits of the whole disk, not of one store, so a test cannot predict an absolute generation: it reads a base of the generations. A generation is not a version of an object and not a time.

The design: `docs/STORAGE.md`, "3.3 The commit and the open".

Do not use: epoch, transaction id, version (for this).

### History store

The history store is the store of the line history of the console in the storage service, apart from its private store.

The line history must survive a stop, but the console must not need the grant of its private store, or the grant to act for the principal, for it. So the root service gives the console a second connection, with the grant `history`. Its store is `console.history`, and its limit is 24 blocks. The history store is not a file of a shell in a home folder: no other process reads it, and `revoke("console", "history")` ends it.

The design: `docs/CONSOLE.md`, "6. The line history across a stop".

Do not use: shell history file, profile directory.

### Base of the generations

The base of the generations is, in a machine test, the generation of one commit that a step `Generation` reads from the log, so that the steps after it name the generations that they wait for as the base and a count.

A generation counts the commits of the whole disk, and the console commits its line history after each line, so an absolute generation in a test changes with each line before it. A later step names `{generation}` or `{generation+4}` in its text. A step that names `{generation}` before any step `Generation` stops the test. The base is a number of the modus tool, not of the system.

The design: the step `Generation` of `tools/modustool/machine/machine.odin`.

Do not use: offset, delta.

### Damaged object

A damaged object is an object whose state names a block with a wrong check under a valid root block: the storage service does not give its bytes.

Damage is a change on the disk that the service did not make. The open of the disk checks each block that a root names. A wrong block of an object damages only that object: a read gives `Damaged`, and the other objects are served. A write or a remove of the object replaces the damaged state. A wrong node damages its whole store. A damaged object is not a bad sector: the device reported no error, and the check found the damage.

The design: `docs/STORAGE.md`, "3.3 The commit and the open".

Do not use: corrupt file, bad sector.

### Dropped write

A dropped write is a write that the disk answers with Ok and does not keep.

The device reports no error, so the storage service learns of a dropped write only at a read. The commit read back finds it first: the service refuses the commit, and the objects read as they were before it. After a loss of power before the read back, the open uses the root before, when that root names no wrong block. A device that answers from the cache that lost the write hides the drop. A dropped write is not a loss of power, and not a torn write: no part of the block reaches the disk.

The design: `src/md/features/dropped_write.md`.

Do not use: lost write (for this), silent write failure, phantom write.

### Check

A check is 8 bytes of a hash of a block, kept in the pointer that names the block: a block that does not have its check is not used.

The check finds each change of a block that the storage service did not make, and each block that a cut commit left. A pointer is a block number and a check. The check of a block of data is the first 8 bytes of its value; the check of each other block is the first 8 bytes of its BLAKE3 hash. The open compares the check of each block that a root names. A check is not a CRC: it is a cryptographic hash, kept in the block above.

The design: `docs/STORAGE.md`, "3.1 The blocks".

Do not use: checksum, CRC, digest.

### Block tree

A block tree is the blocks of one state of an object: its blocks of data, where the block n holds the bytes from n × 4096, and the object nodes above them.

The block tree makes a large object cheap to change: a commit of K changed blocks writes those K blocks and the object nodes on their paths, and names each other block of the state before. A block of zero bytes is a hole and is not in the tree. A process never sees the block tree: it reads and writes bytes and ranges. Example: an object of 8 GiB written by three range writes holds 13 blocks. A block tree is not an extent tree: it has no runs of blocks.

The design: `docs/STORAGE.md`, "The block tree".

Do not use: extent tree, block map, list of blocks.

### Object node

An object node is one block of a block tree above the blocks of data: 64 children, each an object node of the level below, a block of data, or a hole.

Each child holds its block number, its check, the count of blocks under it, and its value. 64 is a power of two, so an object node covers a whole subtree of the BLAKE3 tree of the bytes, and its value comes from the values of its children. The open checks each object node. An object node is not a node, which is a block of the B+ tree of a tree. It is not an indirect block either: it carries the value of each child.

The design: `docs/STORAGE.md`, "The block tree".

Do not use: indirect block, extent node, node (for this: a node is of a tree).

### Hole

A hole is a part of an object whose bytes are all zero: nothing names it, it costs no block, and it reads as zero bytes.

Holes let an object have a large size and few blocks. The service never writes a block of zero bytes: a write that leaves one makes a hole. A hole has the value zero, so it costs nothing in the hash of the object either, and no block in the limit of the store. Example: `read_range` across a hole gives zero bytes. A hole is not a reserved area: a write in a hole takes new blocks at its commit.

The design: `docs/STORAGE.md`, "The block tree".

Do not use: sparse region, gap, zero block (for this).

### Value

A value is the BLAKE3 chaining value of a part of an object, as a subtree of the BLAKE3 tree of its bytes, with zero bytes past its size; a hole has the value zero.

Values let the storage service compute the hash of an object from the blocks that a commit changed, not from the whole object. The value of a block of data is its chaining value at its place in the object, and its first 8 bytes are the check of the block. Each object node keeps the value of each child. A value is not a hash of a block alone: the same bytes at two places have two values.

The design: `docs/STORAGE.md`, "The block tree".

Do not use: digest, checksum, fingerprint.

### Hash of an object

The hash of an object is its name: the BLAKE3 hash of its bytes, except that a hole before its last block counts with the value zero.

The hash comes from the values on the path of the last block and the bytes of that block, so a commit never hashes the whole object. With no hole before its last block, the hash is exactly the BLAKE3 hash of its bytes. It is always a function of the bytes alone, because a block of zero bytes is always a hole. The hash of an object is not always the hash of a module: a module file with a hole has another hash as an object.

The design: `docs/STORAGE.md`, "The hash of an object".

Do not use: content id, checksum (for this).

### Hash index

The hash index is the table in the memory of the storage service that finds the root of the current state of an object of a store by the hash of that state.

The hash index keeps the same object one time: a commit whose new state has the hash and the size of a current object of the same store names the root of that object, and writes no block of it. The open of the disk makes the index, so it is never on the disk. Example: the process `ranges` writes an object of 1 MiB under two names, and the store holds 261 blocks for both. The hash index is not an index on the disk, and never names a block of another store.

The design: `src/md/data/hash_index.md`.

Do not use: deduplication, dedup table, content-addressed store.

### Range

A range is a count of bytes from an offset of an object.

Ranges let a process read and change a part of a large object with no copy of the rest. `storage.read_range(place, name, offset, result)` reads bytes from `offset`, with the pending changes of the connection. `storage.write_range(place, name, offset, data)` changes one range as a pending change, and `storage.compare` gives the ranges that differ between two states. Example: the process `ranges` makes 1000 writes of 16 bytes in an object of 8 GiB, then one commit. A range is not an extent of the disk: it says nothing of the blocks.

The design: `docs/STORAGE.md`, "Ranges".

Do not use: extent (for this), segment, slice (for this).

### Pending change

A pending change is a range write or a change of size that the storage service keeps for one connection until its commit: not on the disk, and not hashed.

Pending changes group many small writes into one commit, which is one version. A read of the connection sees its pending changes; another connection sees the last commit. `storage.commit(place, name)` makes them one commit. Another change of the object before the commit comes first: the commit is then refused, and the pending changes are dropped. A loss of power or the end of the connection drops them. A pending change is not a dirty page that the system writes later by itself.

The design: `docs/STORAGE.md`, "Ranges".

Do not use: dirty page, write buffer, uncommitted write, transaction (for this).

### Tree hash

The tree hash is the BLAKE3 hash of the list of the entries of a tree, each its name, its kind and its hash, sorted by name.

A tree that does not change after its commit has one tree hash, so it is named by its hash, as an object is. The output of a recipe, the source of a project and a declaration are trees with a tree hash; `here()` gives the tree hash of the current version of a store. It is not the check of a node. It is designed, not built: today a tree that changes has no hash.

The design: `src/md/features/recipes.md`, "Trees".

Do not use: Merkle root, tree checksum, commit hash.

### Stored type

A stored type is a record type whose records a module keeps in its store.

The module names it in its module file, with the objects that hold it. Its description has no Handle field and holds the members of each enum field. From 1.0, a change of it needs a migration; before 1.0, a change breaks the old data. A document has no stored type. It is designed for after 1.0, not built.

The design: `src/md/features/data_evolution.md`.

Do not use: schema, persisted struct, file format.

### Typed object

A typed object is an object that holds tables of records of stored types, each with its canonical description.

The process that owns the store reads it through one border, which checks each description and each record, and refuses a description that the module does not know. The module never writes over an object that it refused. The console shows a typed object by the descriptions in it. It is designed for after 1.0, not built.

The design: `src/md/features/data_evolution.md`.

Do not use: record file, container, typed file.

### Description hash

The description hash is the BLAKE3 hash of the canonical description of a stored type.

It names the form of the records of a table. The reader computes it from the description in the typed object, and the tool computes it at the build. Two descriptions that differ in one field, unit, kind or member have two hashes. It is not a version number: it gives no order. It is designed for after 1.0, not built.

The design: `src/md/features/data_evolution.md`.

Do not use: schema version, format number, fingerprint.

### Migration

A migration is the procedure that takes the records of a typed object from one description to another.

A forward migration runs in the process that owns the store, at the first start of the new module and at a read that meets an older description. A backward migration runs in the newer module, in a migration start before a rollback. A migration is derived from the two descriptions, or declared by the author, and commits one object. The system has none before 1.0. It is designed for after 1.0, not built.

The design: `src/md/features/data_evolution.md`.

Do not use: upgrade script, conversion, schema change.

### Shipped description

A shipped description is the canonical description of a stored type that a release shipped.

From the release 1.0.0, the release command writes each one beside `src/library/modus/contract/release/release.odin`. The check of the stored types needs a migration from each shipped description of a type to its new description, and back. It refuses a migration from a description that no release shipped. It is designed for after 1.0, not built.

The design: `src/md/features/data_evolution.md`.

Do not use: frozen schema, baseline.
### Store exchange

A store exchange keeps one store of a principal on two machines or more: each machine writes its own copy, and the machines send each other the versions that the other lacks, then merge.

Each machine has the whole store and keeps the rule of no save action with no link. The versions become a graph, in which a merge has two parents. Only a store that the plan of the principal names is exchanged, with the paired machines that the plan names. The trees and the objects cross by hash, with the protocol of the cache. Designed, not built.

The design: `src/md/features/several_machines.md`, "The exchange of a store between machines".

Do not use: sync, replication, mirror.

### Common version

The common version of a store and a paired machine is the newest version of the store that both machines hold: the base of their next merge.

The retention rule never thins it, so its blocks stay while the paired machine stays. Each exchange moves it forward. The removal of the paired machine ends it. It is not the current version. Designed, not built.

The design: `src/md/features/several_machines.md`, "The exchange of a store between machines".

Do not use: merge base, ancestor, last sync.

### Merge export

A merge export is the export `merge(base, ours, theirs)` of the module that owns a store: it merges three versions of one object of its format, or says that it cannot.

The store exchange calls it for each object that both machines changed, in a process of the session of the principal that holds a connection to that store only. A text merges by lines, a table by the key of its rows, and a CRDT document by its own merge. An object whose module has no merge export becomes a conflict value. Designed, not built.

The design: `src/md/features/several_machines.md`, "The exchange of a store between machines".

Do not use: merge driver, resolver, conflict handler.

### Conflict value

A conflict value is an object that holds a conflict as data: the hashes of the base and of the two sides that a merge could not join.

The merge commits it, so the store exchange never stops on a conflict and both machines keep working. The principal resolves it once, in the module of the store or in a view of the two sides, and the resolution is a version that crosses as any change. A reader of a store refuses or shows a conflict value; it never reads it as the content. Designed, not built.

The design: `src/md/features/several_machines.md`, "The exchange of a store between machines".

Do not use: conflict file, conflict marker, sync conflict.
