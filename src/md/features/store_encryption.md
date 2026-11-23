# The encryption of the stores of a principal

Status: Decided. Built: the key hierarchy, the nonce, the name tag and the tag of a node, as pure procedures with host tests (`modus:store_encryption`). Not built: the storage format `STORAGE7`, the service that encrypts, and the transfer of the key.

The stores of a named principal are encrypted under keys that come from its unlock key, so a reader of the disk, and the storage service while the principal is locked, read nothing of them. This is layer 6 of [several_principals.md](several_principals.md), "The layers". The guide of the storage is [`docs/STORAGE.md`](../../../docs/STORAGE.md), "1.2 The hard points", where the secrecy was a rule with no design.

## Purpose

- A copy of the disk, a lost disk, and a fault of the storage service while a principal is locked give no byte, no name and no hash of an object of that principal.
- A change of one block of a store of a principal on the disk is found at its read, and never read as data.
- The lock of a principal erases its keys in the storage service.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "9. A storage engine with one private store per process": copy on write, one commit as one switch of the root block, versions.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "21. Principals: who acts, without users": the kernel knows no principal; the storage service is a process.
- The rule of each use of the unlock key ([processes_from_a_disk.md](processes_from_a_disk.md), "The grants of a disk process"): the secret unlock key is never used as it is; each use derives its own key by keyed BLAKE2b over a text of its own.
- A block is 4096 bytes and holds no room for a tag of its own: a data block is all data, and a node is full.
- A block number serves a new block after a free; a nonce that repeats under one key breaks ChaCha20.
- The count repair walks the trees of a store to count the names of its blocks ([`docs/STORAGE.md`](../../../docs/STORAGE.md), "3.5 The count tree").
- Principal 0 has no unlock key: its stores stay in clear in this layer.

## The chosen form

### The keys

| Key | From | Where it lives |
|---|---|---|
| The storage key of a principal | Keyed BLAKE2b of the unlock key over "modus storage key of a principal" | `unlock` makes it at the unlock, the root service passes it to the storage service; memory of the storage service only, until the lock |
| The key of a store | Keyed BLAKE3, under the storage key, of a domain text, the principal identifier and the salt of the store | Derived by the storage service when the store opens; memory only |
| The cipher key and the tag key of a store | Keyed BLAKE3 of two texts under the key of the store | Memory only |
| The name key of a principal | Keyed BLAKE3 of a text under the storage key | Memory only |

- **The salt of a store** is 32 random bytes that the storage service draws when it makes the store, kept in clear in the store block. A store made again in the same cell gets a new salt, so a new key: no nonce of the old store repeats under it.
- **The key check.** The store block keeps the keyed hash of a text under the key of the store. A wrong key, or the key of another principal, is found before any block is read, and the store is refused whole.
- **The transfer.** At the unlock, `unlock` gives the root service the storage key beside the key of the tag of the disk grant table; the root service gives it to the storage service with the principal identifier on its control ring, and keeps no copy. At the lock, the root service tells the storage service, which erases the storage key and each key derived from it, and closes the stores of that principal.

### What is encrypted

| Part | Form |
|---|---|
| A data block of an object | XChaCha20 under the cipher key of its store; nonce: the block number and the generation of the commit that writes it |
| A node of a tree, an object node, a version index and a version leaf | XChaCha20 as a data block, after the header of the block |
| The name of a store in its cell | Its name tag: the keyed BLAKE3 hash of the name under the name key, its first 32 bytes |
| The store block | In clear: the pointers of its trees, its counts, the owner identifier, the salt, the key check |
| The count tree, the store table, the root block | In clear |

- **The nonce never repeats under one key.** A commit writes each block number once, and the generation of the root grows by one at each commit, for the life of the disk. The pair of a block number and a generation names one write. A nonce from a counter in memory would repeat after a loss of power; a random nonce of each block has no room.
- **The name tag.** A process names a store by its name; the storage service finds the cell whose tag is the tag of that name under the name key of the principal of the caller. A name is found only while its principal is unlocked, and two principals with one name have two tags.

### The integrity

- **A data block** is checked by its BLAKE3 chaining value, which its object node keeps, after the decryption: the hash tree of an object is already a check of each block ([`docs/STORAGE.md`](../../../docs/STORAGE.md), "4.6 Large objects"). The object node is encrypted and tagged, so the value cannot be changed with the block.
- **A node** is tagged: the check of its pointer, 8 bytes, is the keyed BLAKE3 hash of its encrypted bytes under the tag key of its store, in place of the BLAKE3 hash of the bytes. The parent of a node is a node, so each link is tagged, up to the store block.
- **The store block** keeps the full tag of 32 bytes of the root node of its tree and of its removal queue.

### What the storage service sees

- While the principal is unlocked: each name, each byte and each hash of its stores, as today. The storage service is a joint process ([several_principals.md](several_principals.md), "The services that keep data").
- While it is locked: the block numbers, the counts, the owner identifier and the salt of each store, the sizes of the objects as counts of blocks, the times of the commits. No name, no byte, no hash.
- **The count repair of a locked store waits.** The service walks no tree of a locked principal: the count tree keeps the counts of its blocks, and a repair whose leaves hold a block of a locked store finishes that store at the next unlock (`Count_Repair_Store_Locked`).
- **The hash index** of the stores of a principal is made at its unlock, from the entries that the keys open, and dropped at its lock.

### The format

The storage format becomes `STORAGE7`: the store block gains the owner identifier, the salt and the key check. A disk of `STORAGE6` is refused at the open with the sentence "the data disk has the format of an older release of modus, which this release does not read: write the data disk again". Before 1.0 a format changes with no migration.

### The measure

The cost is one XChaCha20 over each block written and read, and one keyed BLAKE3 over each node. The measure run of the storage gives, on the test machine, the time of a commit of 1 MiB and of 64 MiB and of a read of the same, with and without the encryption, as the median of 21 runs. It is a measure, printed with its condition, never a bound of a test. The form is kept if the encryption costs less than the copy of the block to the device; else a vector form of XChaCha20 comes first.

## Refused forms

- **Whole-volume encryption with one key for each principal.** It separates nothing between principals, and the block device sees each block of each principal in clear while the machine runs.
- **The encryption in the block device service.** It does not know the owner of a block.
- **AEAD with a tag of each data block.** A block has no room for it, and the hash tree of the object already checks the bytes under a tagged node.
- **A deterministic encryption of a block.** Two equal blocks give two equal ciphertexts: a reader of the disk sees the shape of the data.
- **A key of each object.** A key of each store with a nonce of each write is enough, and the hash index shares blocks inside one store.
- **The name of a store encrypted with the cipher.** A process finds a store by its name; a tag finds it with one comparison, and a cipher needs a nonce of its own.
- **The unlock key in the storage service.** The storage service needs one derived key; the unlock key also signs and opens documents.
- **The stores of principal 0 under the machine key, now.** The machine key with no machine passphrase opens to anyone at the machine of the measured system; it protects the copy of a disk only. It is a later layer of its own.

## Subtle points

- **A link of 64 bits.** The check of a pointer has 8 bytes. A forged node needs the tag key; a guess passes with a chance of 2^-64 for each read of the forged block. The store block keeps full tags of its two roots.
- **A rollback.** A copy of an older disk gives older states of a store, each with valid tags. The encryption does not find it; the pin of the TPM pins the file of the principal, not its stores.
- **The sizes.** The count of blocks of an object and the times of the commits stay in clear.
- **A shared block.** The hash index shares blocks inside one store only, so no block holds the bytes of two principals.

## State

Built: the key hierarchy (the storage key of a principal, `principals.principal_storage_key`, the key of a store, its cipher key, tag key and key check, the name key and the name tag), the nonce of a block, and the tag of a node, in `modus:store_encryption` with host tests. Not built: `STORAGE7`, the encryption of the blocks in the storage service, the transfer of the storage key, the count repair of a locked store, the hash index at the unlock, and the measure.
