# The encryption of the stores of a principal

Status: Decided. Built: the keys and their transfer to the storage service, the owner of a store in the format `STORAGE7`, the name tag, the vector form of XChaCha20, the split clear/encrypted block format with 128-bit SIV authentication and store rollback floor, and the encryption of blocks in the engine of the storage service.

The stores of a named principal are encrypted under keys that come from its unlock key, so a reader of the disk, and the storage service while the principal is locked, read nothing of them. This is layer 6 of [several_principals.md](several_principals.md), "The layers". The guide of the storage is [`docs/STORAGE.md`](../../../docs/STORAGE.md), "1.2 The hard points".

## Purpose

- A copy of the disk, a lost disk, and a fault of the storage service while a principal is locked give no byte, no name, no timestamp, and no hash of an object of that principal.
- A change of one block of a store of a principal on the disk, a move of a block to another block number, a block-type substitution, or a rollback of a store block to an older generation is found at its read, and never read as data.
- The lock of a principal erases its keys, evicts its cached blocks, removes its entries from the hash index, and erases transient plaintext working buffers in the storage service.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "9. A storage engine with one private store per process": copy on write, one commit as one switch of the root block, versions.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close": evicting one principal at lock must not evict cached blocks of another principal.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "21. Principals: who acts, without users": the kernel knows no principal; the storage service is a process.
- The rule of each use of the unlock key ([processes_from_a_disk.md](processes_from_a_disk.md), "The grants of a disk process"): the secret unlock key is never used as it is; each use derives its own key by keyed BLAKE2b over a text of its own.
- A block is 4096 bytes. A block of data is all data (4096 bytes) and holds no room for a tag or a nonce of its own.
- A block number serves a new block after a free; a nonce that repeats under one key for two texts breaks ChaCha20.
- The open, the count repair, and the dropped-write fallback read the structural pointers of each store at boot without keys ([`docs/STORAGE.md`](../../../docs/STORAGE.md), "3.5 The count tree").
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
- **The transfer.** At the unlock, `unlock` gives the root service the storage key (`Principal_Storage_Key`), before `Principal_Unlock`. The root service writes the identifier and the key on the service ring of the holder of `Storage` (`Principal_Identity`, `Principal_Storage_Key` of `isolated.Service_Command`), the ring that it alone writes, and keeps no copy. At the lock it writes `Principal_Locked`, and the storage service erases the keys of that slot, evicts cached blocks of that slot's stores, removes their entries from the hash index, drops their pending pools, and erases transient working buffers. A key with no identity before it, a slot past the capacity and zero bytes are refused and said. Another service refuses each of the three commands.

### The owner of a store

- **The store block** keeps in clear, after its counts: the owner (the principal identifier), the salt, the key check, the name of the store sealed with XChaCha20 under the cipher key of the store, `store_generation` (the root generation of the store's last commit, at least 1), and a 128-bit `mac` authenticating the whole store block. A store of principal 0 has zero bytes in these fields. The commit of a store keeps the four owner fields of its store block, which the head of a store in memory does not hold.
- **The cell** of a store of a named principal keeps `OWNED_CELL_MARK`, then the first 31 bytes of its name tag: the keyed BLAKE3 hash of its name under the name key of its principal. No name of a store starts with that byte, which is a control character. The store table reader accepts binary tag bytes (including embedded zeros and a non-zero last byte) for cells starting with `OWNED_CELL_MARK`, requiring only that the 31 tag bytes are not all zero.
- **Reclaiming orphaned stores of a removed principal.** When a named principal is removed (`several_principals.md`), the root service sends `isolated.Service_Command.Principal_Reclaim` with the removed 256-bit `Principal_Identifier` to the storage service after `Principal_Locked`. The storage service refuses an all-zero identifier or any identifier currently unlocked in `principal_storage`. For each `OWNED_CELL_MARK` store whose on-disk `Store_Block.owner` equals that identifier, the storage service commits a scrubbed cell marked `RECLAIMING_CELL_MARK` (`0x02` followed by 31 zero bytes) and a scrubbed `Store_Block` with `owner`, `salt`, `key_check`, `name_sealed`, `store_generation`, and `mac` zeroed. `storage_mount` and `count_repair` treat `RECLAIMING_CELL_MARK` cells as using the encrypted structural layout (`format.cell_uses_encrypted_layout`), refusing non-zero trailing bytes. Because every structural pointer in `Store_Block`, `Tree_Node`, `Object_Node`, `Version_Index`, `Version_Leaf`, and `Release_List` stays in clear, the storage service reclaims all trees, versions, release lists, and data blocks keylessly in bounded copy-on-write commits (`internal:storage/store_reclaim`), rewriting only modified leftmost path nodes in clear and delegating large object states to clear `Release_List` steps. When both `tree` and `removals` are empty, a final commit frees the `Store_Block` and zeroes the `Store_Entry` cell for reuse. Every intermediate commit is a valid `STORAGE7` tree that resumes automatically after any crash or power loss.
- **The search of a store** of a named principal computes the tag with the keys held for the slot of the caller, finds the cell, then checks the owner, key check, rollback floor, and 128-bit MAC of its store block before serving it. A locked principal has no store that the service finds, and makes none: the first change of a new store is refused with `Wrong_State`. The list of the stores of a principal opens the sealed names with its keys.

### Split clear and encrypted block format

At boot, principals are locked, so the open (`storage_mount`) and count repair (`count_repair`) must walk every store without keys to count block references and verify disk integrity. Every metadata block of an encrypted store therefore keeps its structural traversal fields in clear and encrypts all secret fields in place under XChaCha20 (128-bit SIV mode), authenticating the entire 4096-byte block (clear and secret fields, unused slots, and padding) with a 128-bit MAC stored in the block header.

| Block kind | Clear fields (for keyless mount and repair) | Encrypted fields (under XChaCha20 SIV) | Authentication |
|---|---|---|---|
| Data block (`Block_Kind.Data_Block`) | None (all 4096 bytes encrypted); `Pointer.check = store.check(ciphertext)` | All 4096 bytes | Ciphertext `Pointer.check` plus plaintext BLAKE3 `Block_Value` checked against authenticated parent `Object_Node` (`child.value`) or authenticated `Entry`/`Version_Entry` (`data_check` and `hash`) |
| B+ tree node (`Block_Kind.Tree_Node`) | `Tree_Header` (`level`, `count`, `magic`, `reserved`, `mac`); leaf `Entry.kind`, `Entry.size`, `Entry.pointer`, `Entry.versions`; branch child `Pointer`s | Every `Entry_Name` (256 bytes); leaf `Entry.generation`, `time`, `date`, `hash`, `data_check` (64 contiguous bytes) | 128-bit `Tree_Header.mac` over whole 4096-byte block plus `Pointer.check = store.check(on_disk)` |
| Object node (`Block_Kind.Object_Node`) | `Tree_Header` (`level`, `count`, `magic`, `reserved`, `mac`); for each child: `block`, `check`, `blocks` (holes stay all zero) | For each non-hole child (`block != 0`): `child.value` (32 bytes) | 128-bit `Tree_Header.mac` over whole 4096-byte block plus `Pointer.check = store.check(on_disk)` |
| Version index (`Block_Kind.Version_Index`) | `leaf_count`, `reserved`, `mac`, `leaves` pointers | `version_count`, `retention_time` (16 contiguous bytes) | 128-bit `Version_Index.mac` over whole 4096-byte block plus `Pointer.check = store.check(on_disk)` |
| Version leaf (`Block_Kind.Version_Leaf`) | `count`, `reserved`, `mac`; each `Version_Entry.size` and `root` | Each `Version_Entry.generation`, `time`, `date`, `data_check` (32 contiguous bytes) | 128-bit `Version_Leaf.mac` over whole 4096-byte block plus `Pointer.check = store.check(on_disk)` |
| Release list (`Block_Kind.Release_List`) | `magic`, `count`, `next`, `mac`, `states` | None (holds only structural roots, sizes, and cursors for keyless mount) | 128-bit `Release_List.mac` over whole 4096-byte block plus `Pointer.check = store.check(on_disk)` |
| Store block (`Block_Kind.Store_Block`) | `tree`, `removals`, counts, `owner`, `salt`, `key_check`, `store_generation`, `mac` | `name_sealed` (32 bytes) | 128-bit `Store_Block.mac` over whole 4096-byte block plus `Store_Entry.store.check = store.check(on_disk)` |
| Count tree, store table, root block | In clear | None | Clear `Pointer.check` and `Root.check` |

- **Outer check (`Pointer.check`).** For every block of an encrypted store — both metadata and data blocks — `Pointer.check` is the first 8 bytes of the BLAKE3 hash of the 4096 bytes on disk (`store.check(on_disk)`). No plaintext hash leaks into `Pointer.check`, and keyless mount verifies every block on disk without keys.
- **1-block object integrity (`data_check`).** A 1-block object (`level == 0`) has no `Object_Node`, so `Entry` and `Version_Entry` carry an encrypted `data_check: u64` holding `store.value_check(block_value(plaintext, 0))`. On decrypt, the service uses `data_check` to derive the data nonce and verifies the decrypted block's `value_check` (and `Entry.hash` on current entries).
- **Synthetic nonces with domain separation.** Each block type carries a `Block_Kind` enum byte (`1..=7`):
  - Metadata SIV MAC: `head = blake3.keyed_hash(keys.tag, [kind || block_le64])`, `mac = blake3.keyed_hash(head, clear_block_with_zero_mac)[:16]`.
  - Metadata SIV nonce: `blake3.keyed_hash(keys.nonce, [kind || block_le64 || mac])[:24]`.
  - Data block nonce: `blake3.keyed_hash(keys.nonce, [Block_Kind.Data_Block || block_le64 || data_check_le64])[:24]`.
  - Sealed store name nonce: `block_nonce(keys, 0, 0)` (16-byte input, disjoint from all 17-byte data nonces and 25-byte SIV nonces).
  - Secret ranges of a metadata block are packed into a single volatile-zeroed stack buffer so each block runs one `xchacha20_xor` call.
- **Refusal and zeroing.** Every `open` and `verify` procedure checks the outer `store.check`, validates structural bounds (`magic`, `level`, `count`, `reserved`), decrypts, and constant-time verifies the 128-bit MAC (or plaintext `Block_Value` for data blocks). On any mismatch, it erases the 4096-byte buffer with `intrinsics.mem_zero_volatile` before returning `false`.

### Rollback protection

Each commit of an owned store writes `store_generation = root.generation + 1` into its `Store_Block`, authenticated by `Store_Block.mac`. The storage service tracks the highest verified `store_generation` seen for each store cell (`owned_min_generation`) during the session. When opening or resetting a plan on an owned store, `store_block_verify` checks that `1 <= store_generation <= root.generation` and `store_generation >= owned_min_generation[index]`, refusing any substituted older `Store_Block`.

### Cache and lock erasure

The block cache of the storage service caches on-disk bytes (ciphertext for encrypted stores), never decrypted plaintext. Plaintext lives only in transient working buffers during a call or in pending blocks of an unlocked connection. On `Principal_Locked`, the storage service:

- Erases the slot's storage key, name key, and cached `Store_Keys` with volatile zeroing.
- Evicts only block cache entries owned by stores of that principal's slot, leaving other principals' cache entries untouched.
- Removes all hash-index records belonging to stores of that principal's slot.
- Drops pending pools of connections belonging to stores of that principal's slot and erases transient plaintext working buffers.

### Vector XChaCha20 and the measure

The system includes the 128-bit SIMD ChaCha20 core (`src/library/modus/cryptography/_chacha20/simd128/chacha20_simd128.odin`, imported from Odin `dev-2026-11a` with baseline SSE2 target features on `amd64` and NEON on `arm64`, backed by `compatibility_simd`). On the host, built with `-o:speed`, the median of 21 runs of 4096 blocks of 4096 bytes (`store_encryption_measure_test.odin`, opt-in with `-define:STORE_ENCRYPTION_MEASURE=true`): a copy of a block 30 ns, a block of data (vector XChaCha20 encrypt plus outer BLAKE3 check) 11.3 µs (vector XChaCha20 alone 3.35 µs, about 1.22 GB/s, compared with 33.5 µs for portable XChaCha20), and a full 11-entry B+ tree leaf (split SIV seal plus open) 40.3 µs.

## Refused forms

- **Whole-volume encryption with one key for each principal.** It separates nothing between principals.
- **The encryption in the block device service.** It does not know the owner of a block.
- **AEAD with a tag inside each data block.** A data block is 4096 bytes of data with no spare bytes; the authenticated `Object_Node` (`child.value`) and authenticated `Entry.data_check` already check every decrypted data block.
- **Full-block encryption of metadata nodes.** Keyless boot mount (`storage_mount`), count repair (`count_repair`), and dropped-write fallback must walk every store while all named principals are locked.
- **A deterministic encryption of a block with no nonce of its own.** Two equal blocks at two places give two equal cipher texts.
- **The nonce from the generation of the commit.** No pointer keeps the generation of the write of its block.
- **A key of each object.** A key of each store with a domain-separated synthetic nonce of each write is enough.
- **The name of a store in clear in its cell, or encrypted with the cipher.** A process finds a store by its name: a tag finds it with one comparison, and a reader of the disk reads no name.
- **The unlock key in the storage service.** The storage service needs one derived key; the unlock key also signs and opens documents.
- **The owner fields in the head of each store in memory.** The heads are a table of each store of a disk; four fields of 32 bytes would add 2 MiB to the open and 2 MiB to the service. The commit reads them from the store block, one cached read.
- **The stores of principal 0 under the machine key, now.** It protects the copy of a disk only. It is a later layer of its own.

## Subtle points

- **Cross-boot whole-disk rollback.** Within a session, `store_generation` and `owned_min_generation` reject any rollback of an owned store block, and `store_generation <= root.generation` rejects future-generation spoofing. Restoring an entire older disk image across a reboot remains outside disk-only storage because the disk itself holds no monotonic counter outside the disk.
- **Structural metadata in clear.** Object sizes, tree entry counts, block counts, and pointer graph shape stay in clear so keyless mount and count repair work while principals are locked. Names, hashes, timestamps, generations, and all object bytes are encrypted.
- **Deduplication across clear and encrypted stores.** Keyless mount skips populating the hash index for encrypted stores at boot. When an encrypted store writes an object, its hash index entry carries `data_check` for 1-block objects so deduplication compares decrypted bytes, and all entries of a store are removed from the hash index when its principal locks.
- **The slot in the name of a store.** The root service names a store of a session with the slot of its principal. The cell keeps only the tag of that name under the key of its principal, so no slot is written on the disk, and two principals in one slot have two tags.

## State

Built: the keys (`principals.principal_storage_key`, `internal:storage/store_encryption`), their transfer from `unlock` through the root service to the storage service, vector XChaCha20 (`simd128`), the split clear/encrypted `STORAGE7` block format with 128-bit SIV authentication and `store_generation` rollback protection, keyless mount and repair over encrypted stores, full engine sealing/opening and per-principal lock erasure, host tests of each refusal and edge, and the host cost measure.
