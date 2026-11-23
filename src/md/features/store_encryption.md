# The encryption of the stores of a principal

Status: Decided. Built: the keys and their transfer to the storage service, the owner of a store in the format `STORAGE7`, the name tag, and the cipher of a block and of a node as procedures with host tests and a measure. Not built: the encryption of the blocks in the engine of the storage service (see "Where the engine stops").

The stores of a named principal are encrypted under keys that come from its unlock key, so a reader of the disk, and the storage service while the principal is locked, read nothing of them. This is layer 6 of [several_principals.md](several_principals.md), "The layers". The guide of the storage is [`docs/STORAGE.md`](../../../docs/STORAGE.md), "1.2 The hard points".

## Purpose

- A copy of the disk, a lost disk, and a fault of the storage service while a principal is locked give no byte, no name and no hash of an object of that principal.
- A change of one block of a store of a principal on the disk is found at its read, and never read as data.
- The lock of a principal erases its keys in the storage service.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "9. A storage engine with one private store per process": copy on write, one commit as one switch of the root block, versions.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "21. Principals: who acts, without users": the kernel knows no principal; the storage service is a process.
- The rule of each use of the unlock key ([processes_from_a_disk.md](processes_from_a_disk.md), "The grants of a disk process"): the secret unlock key is never used as it is; each use derives its own key by keyed BLAKE2b over a text of its own.
- A block is 4096 bytes and holds no room for a tag or a nonce of its own: a block of data is all data, and a node is full.
- A block number serves a new block after a free; a nonce that repeats under one key for two texts breaks ChaCha20.
- The open, the count repair and the hash index read the nodes of each store ([`docs/STORAGE.md`](../../../docs/STORAGE.md), "3.5 The count tree").
- Principal 0 has no unlock key: its stores stay in clear.

## The chosen form

### The keys

| Key | From | Where it lives |
|---|---|---|
| The storage key of a principal | Keyed BLAKE2b of the unlock key over "modus storage key of a principal" (`principals.principal_storage_key`) | `unlock` makes it at the unlock; the root service passes it to the storage service and keeps no copy; memory of the storage service only, until the lock |
| The key of a store | Keyed BLAKE3, under the storage key, of a domain text, the principal identifier and the salt of the store | Derived when the store is used; memory only |
| The cipher key, the tag key, the nonce key and the key check of a store | Keyed BLAKE3 of four texts under the key of the store | Memory only; the key check is kept in clear |
| The name key of a principal | Keyed BLAKE3 of a text under the storage key | Memory only |

- **The salt of a store** is 32 random bytes that the storage service draws when it makes the store, kept in clear in the store block. A store made again in the same cell gets a new salt, so a new key.
- **The key check.** The store block keeps the key check of the key of the store. A wrong key, or the key of another principal, is found before any block is read, and the store is not served.
- **The transfer.** At the unlock, `unlock` gives the root service the storage key (`Principal_Storage_Key`), before `Principal_Unlock`. The root service writes the identifier and the key on the service ring of the holder of `Storage` (`Principal_Identity`, `Principal_Storage_Key` of `isolated.Service_Command`), the ring that it alone writes, and keeps no copy. At the lock it writes `Principal_Locked`, and the storage service erases the keys of that slot and forgets the stores that it checked. A key with no identity before it, a slot past the capacity and zero bytes are refused and said. Another service refuses each of the three commands.

### The owner of a store

- **The store block** keeps in clear, after its counts: the owner (the principal identifier), the salt, the key check, and the name of the store sealed with XChaCha20 under the cipher key of the store. A store of principal 0 has zero bytes there. The commit of a store keeps the four fields of its store block, which the head of a store in memory does not hold.
- **The cell** of a store of a named principal keeps `OWNED_CELL_MARK`, then the first 31 bytes of its name tag: the keyed BLAKE3 hash of its name under the name key of its principal. No name of a store starts with that byte, which is a control character.
- **The search of a store** of a named principal computes the tag with the keys held for the slot of the caller, finds the cell, then checks the owner and the key check of its store block once for each slot. A locked principal has no store that the service finds, and makes none: the first change of a new store is refused with `Wrong_State`. The list of the stores of a principal opens the sealed names with its keys.

### What is encrypted

| Part | Form |
|---|---|
| A block of data of an object | XChaCha20 under the cipher key of its store, with its synthetic nonce |
| A node of a tree, an object node, a version index and a version leaf | XChaCha20 with its synthetic nonce, after a tag of its clear bytes |
| The name of a store | Its name tag in the cell, and its sealed name in the store block |
| The store block | In clear: the pointers of its trees, its counts and its owner fields |
| The count tree, the store table, the root block | In clear |

**The nonce.** The nonce of a block is the keyed BLAKE3 hash, under the nonce key of the store, of its block number and of the check of its pointer (`store_encryption.block_nonce`). The check comes from the clear bytes: for a block of data, the first 8 bytes of its value, which the object node keeps; for a node, its tag. So two writes share a nonce only when they write the same bytes to the same block: the same text gives the same cipher text, and nothing is told. A nonce from the generation of the commit needs the generation at the read, which no pointer keeps; a counter in memory repeats after a loss of power; a random nonce of each block has no room.

### The integrity

- **A block of data** is checked by its value after the decryption: the hash tree of an object already checks each block, and its object node is a tagged node.
- **A node** is tagged: the check of its pointer, 8 bytes, is the keyed BLAKE3 hash of its block number and its clear bytes under the tag key of its store (`node_check`). A node that does not pass is erased before any byte is read (`node_open`). Each link of a store is a tagged node, up to the store block.

### Where the engine stops

The cipher is built and measured; the engine does not call it yet. Three parts of the engine read each node of each store, with no caller and no key:

- **The open** walks the trees of each store to count the names of its blocks, and in the form `Tables` the counts come from that walk only.
- **The count repair** walks the trees of the stores whose leaves are wrong.
- **The hash index** is made from the entries of the walk of the open.

A store of a locked principal cannot be walked. The next form keeps in clear, in each node, the pointers that a walk follows, and encrypts the names, the entries, the hashes and the data: the open and the repair count with no key, and the hash index of a principal is made at its unlock. It changes the format of a node, so it is its own step.

### The measure

On the host, built with `-o:speed`, the median of 21 runs of 4096 blocks of 4096 bytes (`store_encryption_measure_test.odin`, opt-in with `-define:STORE_ENCRYPTION_MEASURE=true`): a copy of a block 41 ns, a block of data encrypted 33.5 µs, a node sealed and opened 131 µs. The XChaCha20 of the system is the portable form, at about 120 MB/s. A commit of 64 MiB would take about half a second more, which is more than the copy to the device: by the rule of this design, a vector form of XChaCha20 comes before the engine encrypts.

## Refused forms

- **Whole-volume encryption with one key for each principal.** It separates nothing between principals.
- **The encryption in the block device service.** It does not know the owner of a block.
- **AEAD with a tag of each data block.** A block has no room for it, and the hash tree of the object already checks the bytes under a tagged node.
- **A deterministic encryption of a block with no nonce of its own.** Two equal blocks at two places give two equal cipher texts.
- **The nonce from the generation of the commit.** No pointer keeps the generation of the write of its block.
- **A key of each object.** A key of each store with a nonce of each write is enough.
- **The name of a store in clear in its cell, or encrypted with the cipher.** A process finds a store by its name: a tag finds it with one comparison, and a reader of the disk reads no name.
- **The unlock key in the storage service.** The storage service needs one derived key; the unlock key also signs and opens documents.
- **The owner fields in the head of each store in memory.** The heads are a table of each store of a disk; four fields of 32 bytes would add 2 MiB to the open and 2 MiB to the service. The commit reads them from the store block, one cached read.
- **The stores of principal 0 under the machine key, now.** It protects the copy of a disk only. It is a later layer of its own.

## Subtle points

- **A tag of 64 bits.** A forged node passes with a chance of 2^-64 for each read of it.
- **A rollback.** A copy of an older disk gives older states of a store, each with valid tags.
- **The sizes.** The counts of blocks of a store and the times of the commits stay in clear.
- **The slot in the name of a store.** The root service names a store of a session with the slot of its principal. The cell keeps only the tag of that name under the key of its principal, so no slot is written on the disk, and two principals in one slot have two tags.

## State

Built: the keys (`principals.principal_storage_key`, `modus:store_encryption`), their transfer from `unlock` through the root service to the storage service and their erase at the lock; the format `STORAGE7` with the owner fields of a store block, the refusal of a disk of `STORAGE6` with a sentence; the name tag in the cell, the search, the making and the list of the stores of a named principal with its keys; the cipher of a block and of a node (`cryptography_primitives.xchacha20_xor`), with host tests of each refusal and the measure. Not built: the encryption of the blocks in the engine, which waits for the node form above and for a vector form of XChaCha20.
