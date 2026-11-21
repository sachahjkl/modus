# Swiss tables and the fast hash

`src/library/modus/hash_table` provides fixed-capacity Swiss tables (`Hash_Table` and `Hash_Index`) for lookups by outside keys in system modules. `src/library/modus/fast_hash` provides rapidhash V3 and a folded 64-bit word mixer for short in-memory keys. The SSE2 group-match specification and host speed measures are in [`docs/SIMD.md`](../../../docs/SIMD.md), "9. The 16-tag group match".

## Purpose

Modules outside the kernel look up entries by keys that come from outside the table: glyph keys, content hashes, remote addresses, and names. Before these packages existed, each module wrote its own chained or linear-probing table (such as the chained bucket array of the private glyph cache) or scanned arrays linearly. One shared Swiss-table implementation gives every module bounded memory, SIMD-accelerated 16-slot probing, high load factor (7/8), in-place tombstone cleanup, and seeded hashing against hash flooding.

## Constraints

- **Freestanding, zero allocation, no kernel calls.** Both packages import `base:` and `modus:` only. A table is a fixed-size value placed in module data, a struct, or pages of a memory object.
- **Zero-initialised memory is empty and valid.** Fresh pages from the kernel start all zero, so `Control_Mark.Empty` must be `0x00` and prepared seed `0` must be valid.
- **No vector instructions and no support imports in the kernel.** The kernel never imports support packages and compiles with vector instructions disabled ([`docs/SIMD.md`](../../../docs/SIMD.md), "2. One form: SSE2").
- **Same results on every architecture.** The SSE2 group match must produce the exact 16-bit mask of the scalar fallback for every control group ([`docs/SIMD.md`](../../../docs/SIMD.md), "1. The rule of the same bytes").
- **Defence against hostile keys.** When another party chooses the keys of a table, the table must accept a secret seed so that no party can craft keys that collide in one probe chain.
- **Support-package ownership.** Each support package must be reached by at least two modules ([../infrastructure/repository_layout.md](../infrastructure/repository_layout.md)).

## Survey of lookups in the system

Lookups in modus fall into two distinct classes. Only the second belongs in a hash table.

### 1. Lookups by a system-issued handle (generational index: slot + serial)

When the system itself issues an identifier to a caller, it indexes directly into a fixed array by slot and checks a generation or serial counter. No hash table is needed and no collision can occur:

- **Kernel handles** (`src/modulus/process.odin`): `Process.handles` is a fixed array of `Handle_Slot`; an `op.Handle` packs `(index + 1) | (generation << 16)`. Closing increments `generation`, so stale handles fail in one array read.
- **Kernel objects and waits** (`src/modulus/process.odin`, `src/modulus/wait.odin`): `processes[slot].serial`, `threads[slot].serial`, `regions[slot].serial`, and `thread.wait_serial`.
- **Process references across services** (`root`, `monitor`, `inspect`, `debugger`, `log`): `(process_slot, process_serial)` pairs (`process_page.row_find`, `logged_disk_process[slot]`).
- **Compositor surfaces, clipboards, and key serials** (`src/modules/system/compositor/`): `surface_serial`, `resize_serial`, `clipboard.lend_serial`, and `key_serial`.
- **Host tool candidates** (`tools/modustool/`): dense tables addressed by internal handles in host tools belong in Odin's `core:container/handle_map` (slot + generation). Outside-key symbol and path maps in `tools/modustool` (`site/`, `similarity/`, `build/`) already use Odin's built-in `map`.

### 2. Lookups by an outside key

When keys are chosen externally (glyph descriptors, hashes, IP addresses, names):

- **First user — private glyph cache** (`src/library/modus/text_rendering/private_cache.odin`): up to 4 096 entries keyed by a packed 64-bit glyph key, queried on every glyph of every drawn text run in every window process. Switched from a custom chained table to `hash_table.Hash_Index`.
- **Future candidates**:
  - **Storage hash index** (`src/library/internal/storage/storage_mount/hash_index.odin`, [hash_index.md](hash_index.md)): up to 262 144 object roots keyed by `(hash_prefix, size, store)`, currently seeded linear probing at 1/2 load with a hard `HASH_PROBE_LIMIT` and single-slot-per-key rule. Candidate for `Hash_Index(u32, ...)` when its probe bound and duplicate-key rules are adapted.
  - **QUIC per-address budgets** (`src/library/modus/quic/server_budgets.odin`): 1 024 entries keyed by remote IPv4 address (`u32`), currently scanned linearly; hostile remote addresses make a seeded Swiss table a direct fit.
  - **QUIC and TCP connection tables** (`src/library/modus/quic/server.odin`, `src/library/modus/tcp/`) and **storage block cache** (`src/modules/system/storage/engine.odin`, 64 cached blocks): small today, candidates for `Hash_Index` if their capacities grow beyond linear-scan range.
- **Stay linear scans**: small name tables with tens of entries (`disk_process.Grant_Table`, `root` roles and running processes, `console` commands and variables, `network` ARP neighbors, `storage` store names).
- **Excluded**: the kernel wait table (`src/modulus/wait.odin`, 64 intrusive linked-list buckets keyed by physical word address). The kernel imports no support packages and executes no SSE2 instructions.

## The chosen form

### Two table types sharing one probe

`src/library/modus/hash_table` provides two generic fixed-capacity structs with `GROUP_COUNT > 0` groups of 16 slots (`GROUP_WIDTH :: 16`):

- **`Hash_Table(Key, Value, GROUP_COUNT)`**: stores `controls`, `keys`, and `values` in flat parallel arrays. Keys are hashed and compared by their raw bytes; compile-time constraints (`intrinsics.type_is_simple_compare` and `!intrinsics.type_struct_has_implicit_padding`) refuse structs with implicit padding, floats, pointers, and strings.
- **`Hash_Index(Reference, GROUP_COUNT)`**: stores only `controls` (1 byte per slot) and integer `references` (`u16`, `u32`, ...) pointing into the caller's own record array. The caller computes the hash (`index_hash_word` or `index_hash_bytes`), walks candidates with `index_search_begin` / `index_search_next`, compares keys on its own records, and removes by slot (`index_remove_slot`). This avoids duplicating keys when records already store them for eviction or iteration.

### 16-slot groups, H1/H2 tags, and SIMD matching

- Each slot has a 1-byte control mark:
  - `Control_Mark.Empty` (`0x00`): never taken since the last rebuild; a probe stops at the first group containing an empty slot.
  - `Control_Mark.Deleted` (`0x01`): tombstone; a probe continues past it, and an insert can reuse it.
  - Full slot (`0x80 | tag`): bit 7 (`FULL_BIT`) is set, and bits 0..6 hold the 7-bit H2 tag (`hash & 0x7F`).
- H1 selects the starting group via Lemire fast range reduction: `((hash >> 32) * u64(group_count)) >> 32`. This uses one multiply and shifts, requires no division, and accepts any positive `GROUP_COUNT` (not only powers of two).
- Probing advances linearly by whole groups (`next_group`), wrapping around `GROUP_COUNT`.
- `group_match_tag`, `group_match_empty`, and `group_match_free` compare 16 control bytes at once on amd64 using SSE2 (`pcmpeqb` and `pmovmskb` via `base:intrinsics`), returning a `u16` bitmask. Hits in `Hash_Table.find` and `Hash_Index` skip `group_match_empty` until a group's tag matches are exhausted.

### Load bound, tombstones, and in-place rebuild

- The load bound is 7/8 (`LOAD_BOUND_EIGHTHS :: 7`, 14 keys per 16-slot group). Every table therefore keeps at least 2 empty slots per group on average (and at least 2 empty slots in a 1-group table), guaranteeing that every probe terminates.
- On removal (`mark_removed`), if the slot's group still contains an `Empty` byte, no probe ever crossed that group, so the slot is marked `Empty` immediately. Only removal from a full group writes `Deleted`.
- When `count + deleted_count` reaches `entry_capacity` and an insert would occupy an `Empty` slot, `rebuild_in_place` drops all tombstones without allocating auxiliary memory: every full slot is temporarily marked `Deleted`, every tombstone becomes `Empty`, and each unplaced entry is moved or swapped to the first free slot in its probe sequence. Each swap places one entry, so the work is linear in slot count.

## The hash

`src/library/modus/fast_hash` implements **rapidhash V3** (`rapidhash_withSeed` with compact, fast defaults) in Odin from the published algorithm, verified against 105 reference vectors covering every length branch from 0 to 1 000 bytes, three seeds, and all 16 byte alignments.

- **`hash_bytes` / `hash_bytes_with_prepared_seed`**: rapidhash V3 for byte slices (measured on the host with `-o:speed -microarch:x86-64`: 2.68 ns on 8 B and 16 B, 3.71 ns on 32 B, 6.19 ns on 64 B).
- **`hash_word_with_prepared_seed`**: rapidhash V3 of an 8-byte little-endian word without a memory read.
- **`mix_word_with_prepared_seed`**: single 64x64->128 folded multiply `multiply_and_fold(word ~ prepared_seed, SECRET[0])`, matching Abseil's integer mixer so that both the high 32 bits (H1 group) and low 7 bits (H2 tag) depend on every bit of the word at half the cost of full rapidhash. Used by `Hash_Table` for 8-byte keys and by `Hash_Index.index_hash_word`.
- **Why BLAKE3 stays for identity and security.** rapidhash is a non-cryptographic hash optimised for short in-memory keys. Module hashes, resource verification, content addressing, and cryptographic protocols keep BLAKE3 (`src/library/modus/contract/blake3`).
- **Hash-flooding protection.** `seed_set` prepares a per-table 64-bit seed once (`seed_prepare`). Tables exposed to untrusted keys seed from `modus:random` (or the fresh bytes of the process) at startup. `seed_set` refuses a non-empty table or a table containing tombstones and leaves it unchanged.

## First user: the private glyph cache

`src/library/modus/text_rendering/private_cache.odin` (`Private_Cache`) is the first user outside the kernel. It maps packed 64-bit glyph keys to up to 4 096 `Private_Entry` records in every process that draws text (`compositor`, `terminal`, `settings`, `drawing`, and all window processes).

- Switched from its custom chained bucket array (`buckets: [8192]u16`, 16 384 bytes, plus `next_in_bucket` chain pointers) to `hash_table.Hash_Index(u16, 340)` (5 440 slots, 4 760 capacity at 7/8 load, 75.3% peak load at 4 096 entries, 16 344 bytes).
- Keeps `size_of(Glyph_Memory)` within the exact 354-page budget (`display.GLYPH_MEMORY_PAGES_IN_THE_BUDGETS`) declared by every window process.
- Eliminates bucket-chain walks in `entry_find` and `evict_oldest`, and gives both `hash_table` and `fast_hash` more than a dozen module owners.

## Refused forms

- **Chained hash tables.** Chaining requires 2x bucket slots for low load plus a per-entry link field, and chases pointers into the entry array on bucket collisions and misses. Swiss tables keep 16 tags per cache line and reject 127/128 misses without touching keys or values.
- **Dynamic resizing and heap allocation.** System modules operate under fixed memory budgets without a general allocator; fixed-capacity value types place memory explicitly and never fail by surprise mid-operation.
- **Power-of-two-only capacities.** Forcing powers of two wastes up to half the table memory when a fixed capacity sits just above a power of two (for example, 4 096 entries at 7/8 load would require 8 192 slots instead of 5 440). Fast range reduction supports any `GROUP_COUNT` at negligible cost.
- **Sentinel keys (`key == 0` as empty).** Reserving a key value forbids callers from storing 0 or `max(u64)`. Control bytes keep the entire key domain available.
- **Using a Swiss table for system-issued handles.** Generational indices (`slot + generation`) resolve in one array read with zero hashing and zero collisions.
- **Using `hash_table` inside the kernel.** The kernel imports no support packages and uses no vector registers.
- **Using BLAKE3 for table lookup keys, or rapidhash for identity.** BLAKE3 is far too slow for 8-byte cache lookups; rapidhash has no cryptographic collision resistance.
- **Accepting `nil` `hash_of_reference` in `index_insert`.** Deferring a nil check until tombstones trigger `rebuild_in_place` hides a latent crash; `index_insert` refuses `nil` immediately with nothing changed.

## Sources and licences

Both packages are clean Odin implementations of published algorithms, with no copied C++ source files:

- **Abseil SwissTable** (Matt Kulukundis, Google; Apache-2.0): 16-byte control groups, 7-bit H2 tags, SSE2 match with bitmask extraction, empty-group deletion rule, and in-place tombstone rebuild.
- **Folly F14** (Facebook; Apache-2.0): 16-way SIMD tag probing and compact high-load open-addressing layout.
- **rapidhash V3** (Nicolas De Carli; MIT): short-key and streaming mixing algorithm (`rapidhash_withSeed`), verified against the published V3 test vectors.

## Subtle points

- **Sequential keys and multiplicative mixing.** With `mix_word_with_prepared_seed`, sequential integers `0..N` distribute with near-zero variance across groups (Fibonacci hashing), so filling a table with sequential integers to 7/8 load leaves every group at 14 of 16 slots and creates no full groups and no tombstones on removal. Tests that exercise tombstones and in-place rebuild must use non-sequential or colliding keys.
- **Standalone freestanding `-vet` checks.** Because all public table operations are polymorphic, checking `hash_table` in isolation without a non-polymorphic reference to `fast_hash` triggers an unused-import `-vet` error; `seed_prepare_for_table` stays non-polymorphic to keep the import checked in standalone builds.
- **Pointer stability.** Pointers returned by `Hash_Table.find` and `iterate` remain valid only until the next `insert`, `remove`, or `clear`, because `rebuild_in_place` moves and swaps keys and values.

## State

Built: `src/library/modus/fast_hash` (rapidhash V3 + word mixers, 6 host tests including 105 reference vectors and opt-in host measure), `src/library/modus/hash_table` (`Hash_Table`, `Hash_Index`, SSE2 and scalar 16-tag group match, 19 host tests including 700 000 deterministic fuzz operations and opt-in host measure), and the first user `src/library/modus/text_rendering/private_cache.odin`. Left: adopting `Hash_Index` in `quic/server_budgets.odin` and evaluating `storage_mount/hash_index.odin` against its probe-bound rules.
