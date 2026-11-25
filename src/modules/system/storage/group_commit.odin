package storage_service

import "base:intrinsics"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import module "modus:contract/module"
import "modus:contract/ring"
import "modus:contract/storage_status"
import "internal:storage/block_counts"
import gc_batch "internal:storage/group_commit"
import "internal:storage/storage_mount"
import "modus:system"

// Group commit coordinator for the storage service
// (src/md/features/storage_coalesce_and_group_commit.md).
//
// When two or more commands are queued across connections and shares in one
// service pass, groupable mutations targeting distinct stores plan one by one
// into `plan`, stage their validated sealed writes and per-block deltas into
// `group_batch`, and hold their completions until one shared
// `plan_write_with_root` commits and reads back the root. Any single-command
// pass bypasses staging completely.

Group_Participant :: struct {
	connection:        ^system.Connection,
	command_kind:      u32,
	completion:        ring.Record,
	pending:           ^Pending_Object,
	has_range_measure: bool,
	range_measure:     Commit_Measure,
	range_result:      ^Commit_Measure,
	range_start:       u64,
	range_name:        Kept_Name,
}

group_batch: gc_batch.Batch
group_participants: [gc_batch.STORE_CAPACITY]Group_Participant

group_call_allowed: bool
group_call_staged: bool
group_call_retry_solo: bool
group_last_staged_slot: int = -1
group_flush_active: bool

// Static scratch arrays for translating Plan entries into batch_stage_store
// inputs without putting multi-kilobyte arrays on the stack.
stage_writes_scratch: [gc_batch.WRITE_CAPACITY]gc_batch.Write_Input
stage_deltas_scratch: [gc_batch.DELTA_CAPACITY]gc_batch.Delta
stage_later_scratch: [gc_batch.LATER_CAPACITY]gc_batch.Later_Input
stage_hash_before: [gc_batch.HASH_ENTRY_CAPACITY]Entry
stage_hash_entry: [gc_batch.HASH_ENTRY_CAPACITY]Entry
stage_hash_gone: [gc_batch.HASH_ENTRY_CAPACITY]bool

// Export indices of the seven groupable mutating exports, resolved once from
// service.file at startup.
GROUPABLE_EXPORT_COUNT :: 7
groupable_export_indices: [GROUPABLE_EXPORT_COUNT]u32
groupable_export_count: int

// group_exports_init resolves the module export indices of the seven groupable
// mutating exports from the service's own module file.
group_exports_init :: proc "contextless" (file: []u8) {
	groupable_export_count = 0
	total := module.count(file, .Functions)
	for idx in 0 ..< total {
		fn, ok := module.function(file, u32(idx))
		if !ok {
			continue
		}
		name := module.string_at(file, fn.name_offset, fn.name_count)
		switch name {
		case "write", "remove", "add", "rename", "restore", "clone", "commit":
			if groupable_export_count < len(groupable_export_indices) {
				groupable_export_indices[groupable_export_count] = u32(idx)
				groupable_export_count += 1
			}
		}
	}
}

group_export_is_groupable :: proc "contextless" (kind: u32) -> bool {
	for i in 0 ..< groupable_export_count {
		if groupable_export_indices[i] == kind {
			return true
		}
	}
	return false
}

// group_block_taken reports whether number was already allocated by a store
// staged in group_batch (used by Count_Tree free-block search).
group_block_taken :: proc "contextless" (number: u64) -> bool {
	return gc_batch.batch_block_taken(&group_batch, number)
}

// group_flush_if_conflict flushes any active group batch when the incoming
// call creates a new store or targets a store already staged in group_batch.
// Must run before reading any block of that store.
group_flush_if_conflict :: proc "contextless" (store_name: string) {
	if group_batch.store_count == 0 {
		return
	}
	idx := store_find(store_name)
	if idx < 0 || gc_batch.batch_has_store(&group_batch, idx) {
		group_flush()
	}
}

// group_stage_current_plan attempts to stage the current validated `plan` into
// `group_batch`. Returns:
//   - staged = true: plan is staged into group_batch; caller returns Succeeded
//     and holds its completion until group_flush.
//   - retry_solo = true: plan exceeded remaining group capacity while another
//     store is staged; plan was dropped and caller must flush group_batch then
//     retry this command solo.
//   - staged = false, retry_solo = false, outcome == .Succeeded: this single
//     plan alone exceeds group inline capacity (group_batch was empty); caller
//     falls through to normal solo plan_commit directly.
//   - outcome != .Succeeded (and !retry_solo): a count-tree read failed before
//     staging; plan was dropped and error holds the refusal.
group_stage_current_plan :: proc "contextless" (error: ^errors.Error_Record) -> (staged: bool, retry_solo: bool, outcome: call_outcome.Call_Outcome) {
	hash_count := plan.reclaiming ? 0 : plan.entry_count
	decision := gc_batch.batch_can_stage(
		&group_batch,
		plan.store_index,
		plan.write_count,
		plan.taken_count,
		plan.delta_count,
		later_count,
		hash_count,
	)
	if decision == .Flush_First {
		if group_batch.store_count == 0 {
			// Single large commit: run normal solo plan_commit directly.
			return false, false, .Succeeded
		}
		plan_drop()
		return false, true, .Callee_Busy
	}

	// Compute per-store shared_change now while the pre-batch count tree is
	// active, matching solo plan_commit.
	shared_change: i64
	for at in plan.delta_places[:plan.delta_count] {
		number := plan.delta_blocks[at]
		before := i64(storage_mount.block_count(&opened, number))
		after := before + i64(plan.delta_values[at])
		if !outside_block(number) {
			if before < 2 && after >= 2 {
				shared_change += 1
			} else if before >= 2 && after < 2 {
				shared_change -= 1
			}
		}
	}
	switch opened.counts.failure {
	case .Good:
	case .Device:
		plan_drop()
		return false, false, refuse(error, .Callee_Unavailable, .Device)
	case .Wrong:
		plan_drop()
		if busy, result := repair_refusal(error); busy {
			return false, false, result
		}
		return false, false, refuse(error, .Data_Damaged, .Damaged, .Counts)
	}

	for i in 0 ..< plan.write_count {
		w := plan.writes[i]
		stage_writes_scratch[i] = {
			number         = w.number,
			bytes          = w.bytes,
			encrypted_data = w.encrypted_data,
			data_check     = w.data_check,
		}
	}
	for i in 0 ..< plan.delta_count {
		place := plan.delta_places[i]
		stage_deltas_scratch[i] = {
			number = plan.delta_blocks[place],
			change = plan.delta_values[place],
			owner  = u16(plan.store_index + 1),
		}
	}
	for i in 0 ..< later_count {
		stage_later_scratch[i] = {
			pointer = later[i].pointer,
			bytes   = later[i].bytes,
		}
	}
	for i in 0 ..< hash_count {
		stage_hash_before[i] = plan.entries[i].before
		stage_hash_entry[i] = plan.entries[i].entry
		stage_hash_gone[i] = plan.entries[i].gone
	}

	store_name := plan_store_name()
	input := gc_batch.Store_Input {
		store_index      = plan.store_index,
		cell             = plan_cell()^,
		store_block      = plan.store_block,
		versions_change  = plan.versions_change,
		shared_change    = shared_change,
		dropped_versions = plan.dropped_versions,
		release_damaged  = plan.release_damaged,
		dead_blocks      = plan.dead_blocks,
		encrypted        = plan.encrypted,
		owner_slot       = plan.owner_slot,
		store_keys       = plan.encrypted ? &plan.store_keys : nil,
		store_name       = store_name,
		hidden_hash      = writable_tree_share_open(store_name),
	}
	slot, ok := gc_batch.batch_stage_store(
		&group_batch,
		&input,
		stage_writes_scratch[:plan.write_count],
		plan.taken[:plan.taken_count],
		stage_deltas_scratch[:plan.delta_count],
		stage_later_scratch[:later_count],
		stage_hash_before[:hash_count],
		stage_hash_entry[:hash_count],
		stage_hash_gone[:hash_count],
	)
	if !ok {
		if group_batch.store_count == 0 {
			return false, false, .Succeeded
		}
		plan_drop()
		return false, true, .Callee_Busy
	}

	// Ownership of plan.taken moved to group_batch.taken; clear plan state and
	// volatile-zero plan.store_keys immediately before the next store plans.
	plan.taken_count = 0
	later_count = 0
	plan_crypto_end()
	group_participants[slot] = {}
	group_last_staged_slot = slot
	group_call_staged = true
	return true, false, .Succeeded
}

@(private = "file")
group_free_block_cb :: proc "contextless" (_: rawptr, number: u64) {
	mark(number, false)
}

@(private = "file")
group_fail_all :: proc "contextless" (outcome: call_outcome.Call_Outcome, err: errors.Error_Record) {
	count := group_batch.store_count
	for i in 0 ..< count {
		p := &group_participants[i]
		if p.pending != nil && storage_status.commit_refusal_drops_pending(outcome) {
			pending_drop(p.pending)
		}
		if p.connection != nil {
			completion := isolated.answer_completion(p.completion.tag, p.command_kind, 0, u64(outcome), err)
			_ = system.send(&p.connection.calls.completions, completion)
		}
		p^ = {}
	}
	gc_batch.batch_abort(&group_batch, group_free_block_cb, nil)
	group_last_staged_slot = -1
}

// group_flush commits all stores currently staged in `group_batch` with one
// merged Store_Table_Page pass, one count-tree update, and one
// `plan_write_with_root`, then sends completions to all participants.
group_flush :: proc "contextless" () {
	if group_batch.store_count == 0 {
		return
	}
	group_flush_active = true
	defer group_flush_active = false

	plan_reset(-1)
	plan.release_damaged = group_batch.release_damaged
	plan.dead_blocks = group_batch.dead_blocks
	plan.dropped_versions = group_batch.dropped_versions

	// Populate plan.writes from already-sealed/encrypted group staging blocks.
	for i in 0 ..< group_batch.write_count {
		w := group_batch.writes[i]
		plan.writes[plan.write_count] = {number = w.number, bytes = &group_batch.blocks[w.block_index]}
		plan.write_count += 1
	}

	// Replay every store's block deltas into plan.delta_* (owner_after reads
	// per-block owners from group_batch during group_flush_active).
	for i in 0 ..< group_batch.delta_count {
		d := group_batch.deltas[i]
		delta_add(d.number, i64(d.change))
	}

	flush_err: errors.Error_Record
	if plan.capacity_reached {
		plan_drop()
		_ = refuse(&flush_err, .Budget_Or_Capacity_Exhausted, .Full, .Commit_Blocks, 0, 0, i64(plan.capacity_limit))
		group_fail_all(.Budget_Or_Capacity_Exhausted, flush_err)
		return
	}
	if plan.count_fault || plan.count_overflow {
		plan_drop()
		_ = refuse(&flush_err, .Data_Damaged, .Damaged, .Counts)
		group_fail_all(.Data_Damaged, flush_err)
		return
	}

	// Merge all staged Store_Entry cells per touched Store_Table_Page and
	// allocate one block per distinct touched page.
	gc_batch.batch_merge_store_pages(&group_batch, root.store_page_count, opened.store_pages[:])
	for p in 0 ..< group_batch.page_count {
		page_index := group_batch.page_indices[p]
		if plan.write_count >= len(plan.writes) || plan.taken_count >= len(plan.taken) {
			plan_drop()
			_ = refuse(&flush_err, .Budget_Or_Capacity_Exhausted, .Full, .Commit_Blocks, 0, 0, i64(len(plan.writes)))
			group_fail_all(.Budget_Or_Capacity_Exhausted, flush_err)
			return
		}
		number := allocate()
		if number == 0 {
			plan_drop()
			_ = refuse(&flush_err, .Budget_Or_Capacity_Exhausted, .Full)
			group_fail_all(.Budget_Or_Capacity_Exhausted, flush_err)
			return
		}
		plan.taken[plan.taken_count] = number
		plan.taken_count += 1
		delta_add_outside(number, 1, storage_mount.STORE_TABLE_OWNER)
		if before := root.store_pages[page_index].block; before != 0 && page_index < int(root.store_page_count) {
			delta_add_outside(before, -1, 0)
		}
		bytes := (^Block)(&group_batch.pages[p])
		plan.writes[plan.write_count] = {number = number, bytes = bytes}
		plan.write_count += 1
		plan.next.store_pages[page_index] = {block = number, check = check_of(bytes[:])}
		plan.next.store_page_count = max(plan.next.store_page_count, u64(page_index + 1))
	}

	if refusal, refused := count_pages_make(&flush_err); refused {
		block_counts.commit_drop(&opened.count_commit)
		plan_drop()
		if busy, result := repair_refusal(&flush_err); busy {
			group_fail_all(result, flush_err)
			return
		}
		group_fail_all(refusal, flush_err)
		return
	}

	total_writes := plan.write_count
	place, written := plan_write_with_root(&flush_err)
	if written != .Succeeded {
		// plan_write_with_root already called plan_drop() for page/count
		// blocks; group_fail_all frees all staged store blocks and notifies
		// every participant.
		group_fail_all(written, flush_err)
		return
	}

	// Commit succeeded on disk and passed read-back: install new state atomically.
	root = plan.next
	root_place = place
	commits += 1
	for p in 0 ..< group_batch.page_count {
		opened.store_pages[group_batch.page_indices[p]] = group_batch.pages[p]
	}

	for i in 0 ..< group_batch.store_count {
		s := &group_batch.stores[i]
		store_blocks[s.store_index] = storage_mount.store_head_of(&s.store_block)
		opened.store_versions[s.store_index] = u64(max(i64(opened.store_versions[s.store_index]) + s.versions_change, 0))
		if s.dropped_versions != 0 {
			system.log_fact(.Warning, Versions_Dropped_At_Commit{generation = root.generation, dropped = s.dropped_versions, store = store_field(store_name_of(s.store_index))})
		}
		opened.store_shared[s.store_index] = u64(max(i64(opened.store_shared[s.store_index]) + s.shared_change, 0))
		if s.encrypted {
			owned_checked[s.store_index] = u8(s.owner_slot + 1)
			if s.store_block.store_generation > owned_min_generation[s.store_index] {
				owned_min_generation[s.store_index] = s.store_block.store_generation
			}
			owned_store_keys_put(s.store_index, s.owner_slot, &s.store_keys)
		}
		if s.at_limit_thinned != 0 && !limit_reached[s.store_index] {
			limit_reached[s.store_index] = true
			name := gc_batch.store_name_of(s)
			if s.at_limit_thinned == 1 {
				system.log_fact(.Info, Store_At_Limit_Thinned_One_Version{limit = blocks_field(s.store_limit), generation = root.generation, store = store_field(name)})
			} else {
				system.log_fact(.Info, Store_At_Limit_Thinned_Versions{limit = blocks_field(s.store_limit), generation = root.generation, thinned = s.at_limit_thinned, store = store_field(name)})
			}
		}
	}

	if opened.form == .Tables {
		for at in plan.delta_places[:plan.delta_count] {
			number := plan.delta_blocks[at]
			after := i64(storage_mount.block_count(&opened, number)) + i64(plan.delta_values[at])
			storage_mount.block_set(&opened, number, u32(after), after == 0 ? 0 : owner_after(number))
		}
	}
	count_pages_install()

	for i in 0 ..< group_batch.hash_entry_count {
		item := &group_batch.hash_entries[i]
		storage_mount.hash_index_entry_change(&opened, item.before, item.entry, item.gone, item.hidden)
	}
	for i in 0 ..< group_batch.later_count {
		item := group_batch.later[i]
		cache_put(item.pointer, &group_batch.blocks[item.block_index], item.store_index, item.owner_slot)
	}

	plan.taken_count = 0
	plan_crypto_end()
	reclaim_stalled_clear(-1)
	storage_mount.repair_commit_came(&opened)

	if group_batch.store_count > 1 {
		group_commit_batches += 1
		group_commit_members += u64(group_batch.store_count)
		system.log_fact(.Info, Group_Commit_Batch{generation = root.generation, stores = u64(group_batch.store_count), blocks = u64(total_writes)})
	}

	count := group_batch.store_count
	for i in 0 ..< count {
		p := &group_participants[i]
		if p.pending != nil {
			pending_drop(p.pending)
		}
		if p.has_range_measure {
			p.range_measure.generation = i64(root.generation)
			p.range_measure.milliseconds = i64(system.time() - p.range_start)
			if p.range_result != nil {
				p.range_result^ = p.range_measure
			}
			system.log_fact(.Info, Ranges_Committed{generation = root.generation, changed = u64(p.range_measure.changed), object_blocks = u64(p.range_measure.object_blocks), hashed_blocks = u64(p.range_measure.hashed_blocks), hashed_nodes = u64(p.range_measure.hashed_nodes), written = u64(p.range_measure.written), held = blocks_field(u64(p.range_measure.held_blocks)), elapsed = milliseconds_field(u64(p.range_measure.milliseconds))}, kept_text(&p.range_name))
		}
		if p.connection != nil {
			_ = system.send(&p.connection.calls.completions, p.completion)
		}
		p^ = {}
	}
	gc_batch.batch_reset(&group_batch)
	group_last_staged_slot = -1
}

// queued_commands_count returns the total number of commands currently waiting
// across all client connections and share connections.
@(private = "file")
queued_commands_count :: proc "contextless" () -> int {
	total := 0
	for &connection in service.connections {
		if connection.calls.head != nil {
			total += int(ring.count(&connection.calls.commands))
		}
	}
	for &item in shares {
		if item.connection.calls.head != nil {
			total += int(ring.count(&item.connection.calls.commands))
		}
	}
	return total
}

@(private = "file")
storage_serve_one :: proc "contextless" (connection: ^system.Connection, command: ring.Record, allow_group: bool) {
	if !allow_group || !group_export_is_groupable(command.kind) {
		if group_batch.store_count > 0 {
			group_flush()
		}
		completion := system.connection_call_execute(&service, connection, command)
		_ = system.send(&connection.calls.completions, completion)
		return
	}

	group_call_allowed = true
	group_call_staged = false
	group_call_retry_solo = false
	completion := system.connection_call_execute(&service, connection, command)
	group_call_allowed = false

	if group_call_retry_solo {
		group_call_retry_solo = false
		group_flush()
		retry_completion := system.connection_call_execute(&service, connection, command)
		_ = system.send(&connection.calls.completions, retry_completion)
		return
	}

	if group_call_staged {
		group_call_staged = false
		p := &group_participants[group_last_staged_slot]
		p.connection = connection
		p.command_kind = command.kind
		p.completion = completion
		if group_batch.store_count >= gc_batch.STORE_CAPACITY {
			group_flush()
		}
		return
	}

	_ = system.send(&connection.calls.completions, completion)
}

// storage_serve_pass handles root service control messages and then dispatches
// all currently queued client and share commands in round-robin sweeps,
// grouping concurrent distinct-store commits automatically with zero delay on
// single-command passes.
storage_serve_pass :: proc "contextless" () -> (calls: int) {
	system.service_control_run(&service)
	for _ in 0 ..< ring.CAPACITY {
		queued := queued_commands_count()
		if queued == 0 {
			break
		}
		allow_group := queued >= 2
		sweep_calls := 0
		for &connection in service.connections {
			if connection.calls.head == nil {
				continue
			}
			command, has_command := system.receive(&connection.calls.commands)
			if !has_command {
				continue
			}
			storage_serve_one(&connection, command, allow_group)
			sweep_calls += 1
		}
		for &item in shares {
			if item.connection.calls.head == nil {
				continue
			}
			command, has_command := system.receive(&item.connection.calls.commands)
			if !has_command {
				continue
			}
			storage_serve_one(&item.connection, command, allow_group)
			sweep_calls += 1
		}
		if group_batch.store_count > 0 {
			group_flush()
		}
		calls += sweep_calls
		if sweep_calls == 0 {
			break
		}
	}
	return calls
}
