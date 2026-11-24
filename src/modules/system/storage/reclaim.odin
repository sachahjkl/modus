package storage_service

import "base:intrinsics"
import principal_keys "internal:storage/principal_keys"
import "internal:storage/storage_mount"
import "internal:storage/store_reclaim"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/ring"
import format "modus:contract/store"
import "modus:system"

// Keyless crash-resumable reclamation of orphaned encrypted stores of removed
// named principals (src/md/features/store_encryption.md, "Reclaiming orphaned
// stores of a removed principal").
//
// Two phases:
// 1. Durable marking (storage_principal_reclaim): triggered by root via
//    Service_Command.Principal_Reclaim after the principal's keys are erased.
//    Scans OWNED_CELL_MARK cells whose Store_Block.owner matches the removed
//    principal identifier, scrubs identifying fields, marks the cell
//    RECLAIMING_CELL_MARK in atomic flushed commits, and replies on the
//    service ring completions queue.
// 2. Background reclamation (reclaim_step): drains every RECLAIMING_CELL_MARK
//    store incrementally when no caller waits, using store_reclaim.step over
//    clear structural pointers, then frees the Store_Block and zeroes the
//    Store_Entry cell for reuse.

// Format bound: one reclaim step unwinds at most (NESTING_LIMIT + 2) tree paths
// (removals queue + root + NESTING_LIMIT nested levels = 18) of depth
// TREE_DEPTH_LIMIT (6) -> 108 blocks, plus Release_List and
// prepend_release_entry nodes (<= 16) -> 124 <= 128 staging blocks.
RECLAIM_WRITE_STAGE_CAPACITY :: 128

reclaim_work: store_reclaim.Work
reclaim_write_blocks: [RECLAIM_WRITE_STAGE_CAPACITY]Block
reclaim_write_count: int
reclaim_stalled: [format.STORE_CAPACITY]bool

// reclaiming_cell reports whether a store cell is marked for keyless
// reclamation of a removed named principal's store.
reclaiming_cell :: proc "contextless" (index: int) -> bool {
	if index < 0 || index >= store_numbers() {
		return false
	}
	return store_cell(index).name[0] == format.RECLAIMING_CELL_MARK
}

// reclaim_stalled_clear re-enables stalled reclaiming stores after another
// commit changes the disk (for example freeing space).
reclaim_stalled_clear :: proc "contextless" (except_store := -1) {
	for &stalled, index in reclaim_stalled {
		if index != except_store {
			stalled = false
		}
	}
}

// reclaim_cache_evict_store removes all cached blocks and owned metadata for
// a store cell transitioning to or leaving reclamation.
@(private = "file")
reclaim_cache_evict_store :: proc "contextless" (store_index: int) {
	for &entry in block_cache {
		if entry.number != 0 && int(entry.store_index) == store_index {
			intrinsics.mem_zero_volatile(&entry, size_of(Cached_Block))
		}
	}
	for &entry in owned_key_cache {
		if entry.occupied && int(entry.store_index) == store_index {
			intrinsics.mem_zero_volatile(&entry, size_of(Owned_Key_Cache_Entry))
		}
	}
	owned_checked[store_index] = 0
	owned_min_generation[store_index] = 0
	storage_mount.hash_index_clear_store(&opened, store_index)
}

// storage_principal_reclaim handles Service_Command.Principal_Reclaim from
// the root service: validates that the target principal is not unlocked,
// durably marks every owned store cell belonging to that identifier as
// RECLAIMING_CELL_MARK with scrubbed metadata, and sends the completion.
storage_principal_reclaim :: proc "contextless" (svc: ^system.Service, tag: u32, values: ^[7]u64) {
	id, ok := principal_keys.reclaim_identifier_check(&principal_storage, values^)
	if !ok {
		system.log_fact(.Warning, Principal_Reclaim_Refused{slot = values[4]})
		_ = system.send(&svc.names.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Argument_Refused), tag = tag})
		return
	}
	if broken || disk_size == 0 || disk_silent {
		_ = system.send(&svc.names.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Callee_Unavailable), tag = tag})
		return
	}
	marked: u64
	for index in 0 ..< store_numbers() {
		if !store_listed(index) || !owned_cell(index) {
			continue
		}
		sb: format.Store_Block
		read_outcome := read_single_tagged(store_cell(index).store, (^Block)(&sb), index, 0)
		switch read_outcome {
		case .Device:
			_ = system.send(&svc.names.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Callee_Unavailable), tag = tag})
			return
		case .Wrong:
			continue
		case .Good:
		}
		if sb.owner != id {
			continue
		}
		// Atomically scrub owner metadata and transition the cell mark to
		// RECLAIMING_CELL_MARK in a flushed copy-on-write commit.
		plan_reset_reclaim(index, sb)
		store_reclaim.scrub_store_cell_and_block(plan_cell(), &plan.store_block)
		old_block := plan_cell().store.block
		if old_block != 0 {
			delta_add(old_block, -1)
		}
		intrinsics.mem_copy_non_overlapping(&plan.store_block_bytes, &plan.store_block, BLOCK_SIZE)
		plan_cell().store = plan_write(&plan.store_block_bytes)
		err: errors.Error_Record
		_, commit_outcome := plan_commit(&err)
		if commit_outcome != .Succeeded {
			_ = system.send(&svc.names.completions, ring.Record{kind = u32(commit_outcome), tag = tag, values = errors.completion_values(err)})
			return
		}
		reclaim_cache_evict_store(index)
		reclaim_stalled[index] = false
		system.log_fact(.Info, Principal_Store_Marked_Reclaiming{store = u64(index), blocks = blocks_field(store_cell(index).used)})
		marked += 1
	}
	_ = system.send(&svc.names.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = tag, values = {0 = marked}})
}

// reclaim_waits reports whether any reclaiming store has work that
// reclaim_step can run now without spinning.
reclaim_waits :: proc "contextless" () -> bool {
	if broken || opened.damage_set_full || opened.counts.wrong_leaves_full || storage_mount.repair_active(&opened) {
		return false
	}
	for index in 0 ..< store_numbers() {
		if store_listed(index) && reclaiming_cell(index) && !reclaim_stalled[index] && !store_faulty[index] {
			return true
		}
	}
	return false
}

// Callbacks connecting store_reclaim to the active clear reclaim plan.
reclaim_ops := store_reclaim.Ops {
	read_block      = reclaim_ops_read_block,
	write_block     = reclaim_ops_write_block,
	count_after     = reclaim_ops_count_after,
	drop            = reclaim_ops_drop,
	wrong_block     = reclaim_ops_wrong_block,
	mark_wrong      = reclaim_ops_mark_wrong,
	note_damaged    = reclaim_ops_note_damaged,
	enqueue_release = reclaim_ops_enqueue_release,
	release_step    = reclaim_ops_release_step,
}

@(private = "file")
reclaim_ops_read_block :: proc "contextless" (_: ^store_reclaim.Ops, pointer: format.Pointer, into: ^store_reclaim.Block) -> store_reclaim.Read {
	switch read_single_tagged(pointer, into, plan.store_index, 0) {
	case .Good:
		return .Good
	case .Wrong:
		return .Wrong
	case .Device:
		return .Device
	}
	return .Device
}

@(private = "file")
reclaim_ops_write_block :: proc "contextless" (_: ^store_reclaim.Ops, bytes: ^store_reclaim.Block) -> (pointer: format.Pointer, ok: bool) {
	if reclaim_write_count >= len(reclaim_write_blocks) {
		return {}, false
	}
	slot := reclaim_write_count
	reclaim_write_blocks[slot] = bytes^
	reclaim_write_count += 1
	ptr := plan_write(&reclaim_write_blocks[slot])
	if ptr.block == 0 || plan_refused() {
		return {}, false
	}
	return ptr, true
}

@(private = "file")
reclaim_ops_count_after :: proc "contextless" (_: ^store_reclaim.Ops, number: u64) -> i64 {
	return count_after(number)
}

@(private = "file")
reclaim_ops_drop :: proc "contextless" (_: ^store_reclaim.Ops, number: u64) {
	delta_add(number, -1)
}

@(private = "file")
reclaim_ops_wrong_block :: proc "contextless" (_: ^store_reclaim.Ops, number: u64) -> bool {
	return storage_mount.wrong_block(&opened, number) || storage_mount.damaged_under(&opened, number)
}

@(private = "file")
reclaim_ops_mark_wrong :: proc "contextless" (_: ^store_reclaim.Ops, number: u64) {
	storage_mount.wrong_block_set(&opened, number)
}

@(private = "file")
reclaim_ops_note_damaged :: proc "contextless" (_: ^store_reclaim.Ops, damaged_nodes: u64, damaged_blocks: u64) {
	plan.release_damaged += damaged_nodes
	plan.dead_blocks += damaged_blocks
}

@(private = "file")
reclaim_ops_enqueue_release :: proc "contextless" (_: ^store_reclaim.Ops, root: format.Pointer, size: u64) -> bool {
	before := plan.release_count
	release_queue(root, size)
	return !plan.capacity_reached && plan.release_count > before
}

@(private = "file")
reclaim_ops_release_step :: proc "contextless" (_: ^store_reclaim.Ops, list: ^format.Release_List) -> (empty: bool, device: bool) {
	empty = release_step(list)
	return empty, plan.device
}

// reclaim_prepend_queued_releases writes any large states deferred during
// store_reclaim.step into a chain of clear Release_List blocks and prepends
// them to sb.removals.
@(private = "file")
reclaim_prepend_queued_releases :: proc "contextless" () -> store_reclaim.Step_Outcome {
	if plan.release_count == 0 {
		return .Progressed
	}
	lists := (plan.release_count + format.RELEASES_OF_A_LIST - 1) / format.RELEASES_OF_A_LIST
	plan.release_count = 0
	next: format.Pointer
	for idx := lists - 1; idx >= 0; idx -= 1 {
		list := &plan_fixed.release_lists[idx]
		list.next = next
		list.mac = {}
		next = plan_write_release_list(list)
		if next.block == 0 || plan_refused() {
			return plan.device ? .Device : .Full
		}
	}
	return store_reclaim.prepend_release_entry(&reclaim_ops, &reclaim_work, &plan.store_block, next)
}

// reclaim_step executes one bounded copy-on-write reclamation commit for a
// RECLAIMING_CELL_MARK store when no caller waits. Returns true if a step ran.
reclaim_step :: proc "contextless" () -> bool {
	if broken || opened.damage_set_full || opened.counts.wrong_leaves_full || storage_mount.repair_active(&opened) {
		return false
	}
	store_index := -1
	for index in 0 ..< store_numbers() {
		if store_listed(index) && reclaiming_cell(index) && !reclaim_stalled[index] && !store_faulty[index] {
			store_index = index
			break
		}
	}
	if store_index < 0 {
		return false
	}
	sb: format.Store_Block
	sb_ptr := store_cell(store_index).store
	sb_read := read_single_tagged(sb_ptr, (^Block)(&sb), store_index, 0)
	if sb_read == .Device {
		reclaim_stalled[store_index] = true
		system.log_fact(.Warning, Principal_Reclaim_Stalled{store = u64(store_index)})
		return true
	}
	if sb_read == .Wrong {
		// Corrupt Store_Block on a reclaiming cell: drop the Store_Block
		// pointer, flag recount for any unreachable blocks under it, and free
		// the cell so reclamation never stalls permanently.
		plan_reset_reclaim(store_index, {})
		if sb_ptr.block != 0 {
			storage_mount.wrong_block_set(&opened, sb_ptr.block)
			delta_add(sb_ptr.block, -1)
		}
		plan.release_damaged += 1
		plan.dead_blocks += max(store_cell(store_index).used, 1) - 1
		plan.cell_freed = true
		err: errors.Error_Record
		if _, outcome := plan_commit(&err); outcome != .Succeeded {
			reclaim_stalled[store_index] = true
			system.log_fact(.Warning, Principal_Reclaim_Stalled{store = u64(store_index)})
		} else {
			reclaim_cache_evict_store(store_index)
			system.log_fact(.Info, Principal_Store_Reclaimed{store = u64(store_index)})
		}
		return true
	}

	plan_reset_reclaim(store_index, sb)
	reclaim_write_count = 0
	step_outcome := store_reclaim.step(&reclaim_ops, &reclaim_work, &plan.store_block)
	switch step_outcome {
	case .Empty:
		if sb_ptr.block != 0 {
			delta_add(sb_ptr.block, -1)
		}
		plan.cell_freed = true
		plan.versions_change = -i64(opened.store_versions[store_index])
		err: errors.Error_Record
		if _, outcome := plan_commit(&err); outcome != .Succeeded {
			reclaim_stalled[store_index] = true
			system.log_fact(.Warning, Principal_Reclaim_Stalled{store = u64(store_index)})
		} else {
			reclaim_cache_evict_store(store_index)
			system.log_fact(.Info, Principal_Store_Reclaimed{store = u64(store_index)})
		}
	case .Progressed:
		if plan.release_count > 0 {
			if queue_outcome := reclaim_prepend_queued_releases(); queue_outcome != .Progressed {
				plan_drop()
				reclaim_stalled[store_index] = true
				system.log_fact(.Warning, Principal_Reclaim_Stalled{store = u64(store_index)})
				return true
			}
		}
		if sb_ptr.block != 0 {
			delta_add(sb_ptr.block, -1)
		}
		intrinsics.mem_copy_non_overlapping(&plan.store_block_bytes, &plan.store_block, BLOCK_SIZE)
		plan_cell().store = plan_write(&plan.store_block_bytes)
		plan.versions_change -= i64(reclaim_work.versions_freed)
		err: errors.Error_Record
		if _, outcome := plan_commit(&err); outcome != .Succeeded {
			reclaim_stalled[store_index] = true
			system.log_fact(.Warning, Principal_Reclaim_Stalled{store = u64(store_index)})
		}
	case .Device, .Full:
		plan_drop()
		reclaim_stalled[store_index] = true
		system.log_fact(.Warning, Principal_Reclaim_Stalled{store = u64(store_index)})
	}
	return true
}
