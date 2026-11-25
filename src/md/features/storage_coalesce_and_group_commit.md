# Storage extent coalescing and group commit

The storage service reduces block-device round trips per commit in two ways without changing the `STORAGE7` on-disk format: contiguous multi-block extent coalescing in `transfer()` and group commit across concurrent client commits queued in the same service pass.

## Purpose

Each commit in `storage` writes its changed blocks, sends `Flush`, reads those blocks back, writes the new root, sends `Flush`, and reads the root back ([`dropped_write.md`](dropped_write.md)). Previously, `transfer()` sent one VirtIO block request per 4 KiB block (`count = 1`), and each client commit ran its own full flush and root-flip cycle even when several processes had commits waiting in the same service pass. Coalescing contiguous block runs cuts VirtIO requests and kernel entries per commit, and grouping concurrent commits across distinct stores amortizes the `Store_Table_Page` write, count-tree update, `Flush`, and root flip across all participating clients.

## Constraints

- **Identical on-disk format (`STORAGE7`).** No change to `Root`, `Store_Table_Page`, `Store_Block`, B+ trees, object trees, count tree, or recovery rules.
- **Power-loss atomicity.** Every group commit flips the root once at `root.generation + 1`. A power loss leaves either the previous root or the whole group commit, never a mix.
- **Dropped-write read-back before the root.** Every block of the group is flushed and read back before the root is written, and the root is flushed and read back before any client in the group receives `Succeeded`.
- **Single-client fast path.** When at most one command is queued across all connections and shares, the service never delays or waits for more clients; it runs the direct solo commit path.
- **Per-store planning isolation.** If store B fails planning (`Over_Limit`, `Absent`, `Exists`, `Damaged`, `Full`, or argument refusal), store B receives its refusal immediately and store A's staged changes stay untouched.
- **Multi-principal key isolation.** Encrypted stores of different named principals never share keys in a group commit. Each store's data blocks are encrypted with its own `Store_Keys` into the staging buffer when that store stages, and `plan.store_keys` is volatile-zeroed before the next store plans. Lock eviction (`owned_checks_clear`) runs only when no group is active and volatile-zeroes all group staging buffers and keys.
- **Memory bounded by inline capacities.** Group staging uses fixed inline capacities (`group_commit.STORE_CAPACITY`, `WRITE_CAPACITY`, `DELTA_CAPACITY`, `LATER_CAPACITY`, `HASH_ENTRY_CAPACITY`); a commit that does not fit flushes the staged group first and runs solo with full `plan_fixed` or pending-pool tables, so grouping never causes a spurious capacity refusal.

## The chosen form

### 1. Contiguous multi-block extent coalescing (`internal:storage/block_runs`)

At `disk_open`, `storage` records `max_blocks_per_request` from `block.Command.Info` (`values[1]`, clamped to `[1, REGION_BLOCKS]`).

`block_runs.coalesce_block_runs` merges adjacent `Request{number, slot}` entries into one `Run{first_block, count, first_slot}` whenever:

- `count < max_blocks_per_request`;
- `number == first_block + count` (with overflow guard `first_block <= max(u64) - count`);
- `slot == first_slot + count` (with overflow guard `first_slot <= max(u64) - count`).

`transfer()` coalesces every batch of reads and writes (including `plan_write_with_root`, `commit_blocks_read_back`, `read_checked`, `read_through_block_service`, and `freed_blocks_zero`) and sends one `block` ring command with `values = {first_block, count, first_slot * BLOCK_SIZE}` per run. Because the data region is created with `{.Contiguous}`, one VirtIO descriptor covers the whole run with no scatter-gather list.

Before writing, `plan_write_with_root` sorts `plan.writes[:plan.write_count]` by ascending disk block number with an iterative in-place heapsort (`O(N log N)` worst case, zero allocation). Because `allocate()` hands out sequential free blocks, sorting packs newly allocated blocks into long contiguous runs for both the write pass and the read-back pass. `freed_blocks_zero` sorts each batch of freed block numbers before assigning region slots so zero writes and zero read-backs coalesce as well.

### 2. Group commit (`internal:storage/group_commit` and `storage`)

`system.service_control_run` handles root service control commands (`Connect`, `Grant`, `Principal_Identity`, `Principal_Storage_Key`, `Principal_Locked`, `Principal_Reclaim`, `Disconnect`) before any call dispatch, and `system.connection_call_execute` runs one isolated call and returns its completion `ring.Record` without pushing it to the client ring yet.

In `storage`:

- When `active_queued_connections() <= 1`, the service executes commands immediately on the solo path with zero staging overhead, including single-connection bursts.
- When two or more distinct connections or shares have commands queued, the service dispatches in round-robin sweeps (one command per ready connection per sweep).
- The seven standard mutating exports (`write`, `remove`, `add`, `rename`, `restore`, `clone`, and normal range `commit`) are groupable. Every other export (`read`, `list`, `erase_versions`, `freeze_tree`, `collect_garbage`, `share`, `stores`, etc.) flushes any staged group before running.
- Each distinct `store_index` appears at most once in a batch. Before touching a store or running `store_prepare` guards (`broken`, repair, damage-set bounds), the service flushes any staged group if the target store is already in the batch or if the call creates a new store.
- Each groupable call plans normally in `plan`. If planning fails, `plan_drop()` frees only that store's taken blocks and the refusal completion goes back to the caller immediately.
- When `plan_commit` succeeds its checks and the store fits in `group_commit.Batch`, `group_stage` encrypts any `encrypted_data` blocks with the store's own `plan.store_keys` into `group_batch.blocks`, records the store's cell, `Store_Block`, deltas (each tagged with `owner = u16(store_index + 1)`), cached leaves/indexes, hash-index entry changes, and post-commit metadata, transfers ownership of `plan.taken` to the batch, and volatile-zeroes `plan.store_keys`. The dispatcher holds the client's command and completion record in `group_participants`.
- If a second store hits `plan.full` or `plan.capacity_reached` during planning (`plan_refusal` or `plan_commit`) or does not fit in the remaining inline capacity of `group_batch`, `plan_drop()` drops that store's plan cleanly (leaving any pending range object intact), the dispatcher flushes the staged group, and the store retries once solo. Likewise, if a multi-store `group_flush` hits `Budget_Or_Capacity_Exhausted` before `plan_write_with_root`, `group_replay_solo` aborts the batch, frees its staged blocks, and executes each saved participant command solo so grouping never introduces a capacity or out-of-space refusal.
- At the end of a sweep (or before any conflict, non-groupable call, or control pass), `group_flush` merges all staged cells per touched `Store_Table_Page` (writing each touched page once even when several stores share it), runs `count_pages_make()` once over the union of per-store deltas (using `group_batch` per-block owners), and runs one `plan_write_with_root()`.
- On `Succeeded`, `group_flush` commits `root`, `opened.store_pages`, per-store heads/versions/shared counts, `count_pages_install()`, per-store hash-index updates, store-tagged `block_cache` fills, encrypted store key cache updates, pending range drops, and post-commit log facts (`Store_At_Limit_Thinned`, `Ranges_Committed`, and `Group_Commit_Batch` when two or more stores share a batch), then delivers all held `Succeeded` completions.
- On dropped write or device error, `group_abort` frees every taken block across every store in the batch, volatile-zeroes all staged blocks and keys, keeps `root` at the previous generation, preserves pending changes when `storage_status.commit_refusal_drops_pending` returns false, and sends the failure completion with its `Error_Record` to every participant in the batch.

## Refused forms

- **Waiting on a timer to collect a larger group.** Adds latency to single-client commits and violates the rule against fixed-delay batching. Grouping only batches commands already queued in the client and share rings.
- **Mutating one shared `plan` across stores during planning.** A refusal in store B would require undoing partial B+ tree, version, and delta mutations interleaved with store A. Planning each store in `plan` and staging only validated plans makes isolation trivial.
- **Keeping plaintext data blocks in the group staging buffer until `plan_write_with_root`.** Would require holding multiple principals' data blocks in clear and selecting keys during transfer. Encrypting into `group_batch.blocks` at stage time seals ciphertext immediately and lets read-back compare ciphertext bytes directly.
- **Allowing two commits to the same store inside one batch.** The second commit would read the pre-batch `store_blocks[store_index]` and overwrite the first commit. Flushing on same-store conflict keeps per-store ordering linearizable.
- **Weakening commit read-back for grouped batches.** Every block of the group and the single shared root still pass read-back before any client receives `Succeeded`.

## Subtle points

- **Free-block search in `Count_Tree` mode.** `allocate()` in `.Count_Tree` mode checks `group_block_taken(number)` inside its `in_plan` predicate so store B never allocates a block already claimed by store A in the active group.
- **Per-block owner attribution.** `owner_after(number)` checks `outside_find(number)` first, then looks up `number` in `group_batch`'s O(1) owner hash table during `group_flush`, so `block_counts` and `opened.block_owner` attribute every block to its exact owning store.
- **Observability.** `stores()` reports `group_commit_batches` (batches of 2+ stores), `group_commit_members`, `block_requests_sent`, and `blocks_transferred`; each multi-store flush also emits `storage_service.Group_Commit_Batch`.

## State

Built: `internal:storage/block_runs` (extent coalescing, overflow guards, iterative heapsort, host tests), `internal:storage/group_commit` (staging batch, multi-principal ciphertext isolation, page merging, per-block owners, rollback, capacity checks, host tests), `system.service_control_run` and `system.connection_call_execute`, and integration in `src/modules/system/storage/` with `stores()` counters and `Group_Commit_Batch` log fact.
