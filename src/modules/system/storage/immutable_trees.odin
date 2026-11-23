package storage_service

import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import format "modus:contract/store"
import "modus:contract/tree_hash"
import "modus:contract/value_kinds"
import "internal:storage/immutable_tree"
import "internal:storage/module_gc"
import tree "internal:storage/storage_tree"
import "modus:system"

// Immutable content-addressed trees and mark-and-sweep garbage collection for
// the storage service (src/md/features/declarations.md;
// src/md/features/recipes.md).

GC_CANDIDATE_CAPACITY :: 4096 // Maximum content-addressed objects scanned in one GC pass.
GC_ROOT_CAPACITY :: 1024 // Maximum roots accepted in one collect_garbage call.

// One entry returned by tree_entry: its kind (word of tree_hash.Tree_Entry_Kind)
// and its 32-byte BLAKE3 hash. Zero padding.
Tree_Entry_Row :: struct {
	kind: i64,
	hash: value_kinds.Hash_Field,
}
#assert(size_of(Tree_Entry_Row) == 40)

// One root passed to collect_garbage: its kind (word of module_gc.Root_Kind)
// and its 32-byte BLAKE3 hash. Zero padding.
Garbage_Root_Row :: struct {
	kind: i64,
	hash: value_kinds.Hash_Field,
}
#assert(size_of(Garbage_Root_Row) == 40)

// One row returned by collect_garbage: counts of the completed pass.
Garbage_Measure :: struct {
	marked:          i64,
	swept:           i64,
	trees_traversed: i64,
}
#assert(size_of(Garbage_Measure) == 24)

// Dedicated static workspaces so immutable tree operations never alias
// reading_pool or plan.pool and perform zero dynamic allocation.
freeze_tree_pool: tree.Pool
freeze_work: immutable_tree.Freeze_Work
immutable_tree_scratch: [tree_hash.MAX_ENCODED_TREE_BYTES]u8
gc_state: module_gc.Collector_State
gc_roots_copy: [GC_ROOT_CAPACITY]module_gc.Root
gc_stored_hashes: [GC_CANDIDATE_CAPACITY]blake3.Hash
gc_sweep_hashes: [GC_CANDIDATE_CAPACITY]blake3.Hash

// Context carried by immutable_tree.Store_Backend callbacks inside one call.
@(private = "file")
Immutable_Context :: struct {
	caller:            ^Caller,
	source_path:       ^Path,
	target_path:       ^Path,
	last_error:        errors.Error_Record,
	last_outcome:      call_outcome.Call_Outcome, // The outcome of the last refused step of the store; Succeeded for none.
	objects_written:   int, // The objects that the call wrote: a refusal after one is a partial change.
}

// path_is_same_or_under says whether candidate equals base or lies inside base.
@(private = "file")
path_is_same_or_under :: proc "contextless" (candidate: ^Path, base: ^Path) -> bool {
	if candidate.store.name != base.store.name || candidate.depth < base.depth {
		return false
	}
	for index in 0 ..< base.depth {
		if candidate.names[index] != base.names[index] {
			return false
		}
	}
	return true
}

@(private = "file")
kept_name_of_hex :: proc "contextless" (hex: [immutable_tree.HASH_HEX_LENGTH]u8) -> (kept: Kept_Name) {
	kept.key = hex
	kept.count = immutable_tree.HASH_HEX_LENGTH
	return kept
}

@(private = "file")
immutable_has_object :: proc "contextless" (backend: ^immutable_tree.Store_Backend, name: [immutable_tree.HASH_HEX_LENGTH]u8) -> (bool, immutable_tree.Backend_Status) {
	ctx := (^Immutable_Context)(backend.data)
	store_index := store_find(ctx.target_path.store.name)
	if store_index < 0 {
		return false, .Ok
	}
	if store_damaged[store_index] {
		return false, .Damaged
	}
	value, outcome := entry_of(store_index, path_names(ctx.target_path), name)
	switch outcome {
	case .Found:
		return value.kind == u64(format.Entry_Kind.Object), .Ok
	case .Absent:
		return false, .Ok
	case .Wrong:
		return false, .Damaged
	case .Device:
		return false, .Device_Error
	}
	return false, .Damaged
}

@(private = "file")
immutable_read_object :: proc "contextless" (backend: ^immutable_tree.Store_Backend, name: [immutable_tree.HASH_HEX_LENGTH]u8, buffer: []u8) -> (int, immutable_tree.Backend_Status) {
	ctx := (^Immutable_Context)(backend.data)
	store_index := store_find(ctx.target_path.store.name)
	if store_index < 0 {
		return 0, .Absent
	}
	if store_damaged[store_index] {
		return 0, .Damaged
	}
	value, outcome := entry_of(store_index, path_names(ctx.target_path), name)
	switch outcome {
	case .Found:
	case .Absent:
		return 0, .Absent
	case .Wrong:
		return 0, .Damaged
	case .Device:
		return 0, .Device_Error
	}
	if value.kind != u64(format.Entry_Kind.Object) {
		return 0, .Absent
	}
	if value.size > u64(len(buffer)) {
		return int(min(value.size, u64(max(int)))), .Buffer_Too_Small
	}
	read_err: errors.Error_Record
	read_bytes, read_outcome := state_read(current_state(&value), 0, buffer[:value.size], &read_err, 2)
	if read_outcome != .Succeeded {
		ctx.last_error = read_err
		ctx.last_outcome = read_outcome
		return 0, read_outcome == .Callee_Unavailable ? .Device_Error : .Damaged
	}
	return int(read_bytes), .Ok
}

@(private = "file")
export_error_to_backend_status :: proc "contextless" (result: call_outcome.Call_Outcome) -> immutable_tree.Backend_Status {
	switch result {
	case .Succeeded:
		return .Ok
	case .Callee_Unavailable:
		return .Device_Error
	case .Budget_Or_Capacity_Exhausted:
		return .Full
	case .Argument_Refused, .Nothing_Has_That_Name, .Name_Already_Taken, .Grant_Or_Right_Missing, .Callee_Busy, .Wrong_State, .Another_Change_Came_First, .Operation_Unsupported, .Data_Damaged, .Stopped_After_A_Partial_Change, .Callee_Stopped_During_The_Call, .Connection_Ended_During_The_Call, .Deadline_Passed_During_The_Call, .Answer_Unreadable:
	}
	return .Damaged
}

@(private = "file")
immutable_write_object :: proc "contextless" (backend: ^immutable_tree.Store_Backend, name: [immutable_tree.HASH_HEX_LENGTH]u8, data: []u8) -> immutable_tree.Backend_Status {
	ctx := (^Immutable_Context)(backend.data)
	kept := kept_name_of_hex(name)
	write_err: errors.Error_Record
	_, result := object_change(
		ctx.target_path.store,
		path_names(ctx.target_path),
		kept,
		.Write,
		data,
		{},
		reaches_whole_store(ctx.caller),
		&write_err,
		2,
	)
	if result != .Succeeded {
		ctx.last_error = write_err
		ctx.last_outcome = result
		return export_error_to_backend_status(result)
	}
	ctx.objects_written += 1
	return .Ok
}

@(private = "file")
immutable_persist_entry_object :: proc "contextless" (backend: ^immutable_tree.Store_Backend, entry: format.Entry, name: [immutable_tree.HASH_HEX_LENGTH]u8) -> immutable_tree.Backend_Status {
	ctx := (^Immutable_Context)(backend.data)
	if state_damaged(entry.pointer) {
		return .Damaged
	}
	kept := kept_name_of_hex(name)
	write_err: errors.Error_Record
	// Same store: zero-copy block-tree clone shares every data block immediately.
	if ctx.source_path.store.name == ctx.target_path.store.name {
		entry_copy := entry
		_, result := object_change(
			ctx.target_path.store,
			path_names(ctx.target_path),
			kept,
			.Clone,
			nil,
			current_state(&entry_copy),
			reaches_whole_store(ctx.caller),
			&write_err,
			2,
		)
		if result != .Succeeded {
			ctx.last_error = write_err
			ctx.last_outcome = result
			return export_error_to_backend_status(result)
		}
		ctx.objects_written += 1
		return .Ok
	}
	// Cross-store freeze: blocks cannot be shared across stores, so copy bytes.
	if entry.size > u64(len(immutable_tree_scratch)) {
		return .Full
	}
	entry_copy := entry
	read_bytes, read_outcome := state_read(current_state(&entry_copy), 0, immutable_tree_scratch[:entry.size], &write_err, 1)
	if read_outcome != .Succeeded {
		ctx.last_error = write_err
		ctx.last_outcome = read_outcome
		return read_outcome == .Callee_Unavailable ? .Device_Error : .Damaged
	}
	_, result := object_change(
		ctx.target_path.store,
		path_names(ctx.target_path),
		kept,
		.Write,
		immutable_tree_scratch[:read_bytes],
		{},
		reaches_whole_store(ctx.caller),
		&write_err,
		2,
	)
	if result != .Succeeded {
		ctx.last_error = write_err
		ctx.last_outcome = result
		return export_error_to_backend_status(result)
	}
	ctx.objects_written += 1
	return .Ok
}

@(private = "file")
tree_store_status_fail :: proc "contextless" (
	status: immutable_tree.Tree_Store_Status,
	ctx: ^Immutable_Context,
	error: ^errors.Error_Record,
	argument: i64,
) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	refused: call_outcome.Call_Outcome
	switch {
	case ctx != nil && ctx.last_outcome != .Succeeded:
		if error != nil {
			error^ = ctx.last_error
		}
		refused = ctx.last_outcome
	case:
		refused = tree_store_status_refusal(status, error, argument)
	}
	// The objects that the call wrote stay: a change that happened is never
	// hidden behind a refusal.
	return call_outcome.outcome_passed_on(refused, ctx != nil && ctx.objects_written > 0), 0
}

// tree_store_status_refusal writes the error record of a status of the
// immutable trees, and gives its outcome.
@(private = "file")
tree_store_status_refusal :: proc "contextless" (status: immutable_tree.Tree_Store_Status, error: ^errors.Error_Record, argument: i64) -> call_outcome.Call_Outcome {
	switch status {
	case .Ok:
		return .Succeeded
	case .Absent, .Not_A_Tree:
		return refuse(error, .Nothing_Has_That_Name, .Absent, .Trees, argument)
	case .Corrupt_Tree, .Damaged:
		return refuse(error, .Data_Damaged, .Damaged, .Trees, argument)
	case .Invalid_Name:
		return refuse(error, .Argument_Refused, .Bad_Byte, .Bytes, argument)
	case .Depth_Exceeded:
		return refuse(error, .Argument_Refused, .Too_Long, .Trees, argument, NESTING_LIMIT + 1, NESTING_LIMIT)
	case .Too_Many_Entries:
		return refuse(error, .Argument_Refused, .Too_Long, .Records, argument, tree_hash.MAX_TREE_ENTRIES + 1, tree_hash.MAX_TREE_ENTRIES)
	case .Capacity_Exceeded, .Full:
		return refuse(error, .Budget_Or_Capacity_Exhausted, .Full, .Trees, argument)
	case .Buffer_Too_Small:
		return refuse(error, .Argument_Refused, .Too_Small, .Bytes, argument)
	case .Device_Error:
		return refuse(error, .Callee_Unavailable, .Device)
	}
	return refuse(error, .Data_Damaged, .Damaged, .Trees, argument)
}

@(private = "file")
parse_hex_hash_argument :: proc "contextless" (given: string, error: ^errors.Error_Record, argument: i64) -> (hash: blake3.Hash, ok: bool) {
	// Copy from the call region once before checking.
	copied: [immutable_tree.HASH_HEX_LENGTH + 1]u8
	count := copy(copied[:], given)
	if len(given) == 0 {
		call_outcome.fail_with_value_first(error, .Argument_Refused, .Empty, .Bytes, argument, 0, immutable_tree.HASH_HEX_LENGTH)
		return {}, false
	}
	if len(given) != immutable_tree.HASH_HEX_LENGTH {
		call_outcome.fail_with_value_first(error, .Argument_Refused, .Bad_Value, .Bytes, argument, i64(len(given)), immutable_tree.HASH_HEX_LENGTH)
		return {}, false
	}
	parsed, valid := immutable_tree.hex_to_hash(copied[:count])
	if !valid {
		call_outcome.fail_with_value_first(error, .Argument_Refused, .Bad_Byte, .Bytes, argument)
		return {}, false
	}
	return parsed, true
}

// freeze_tree hashes the mutable tree at `place` bottom-up into canonical
// immutable tree objects stored under `target_place` (cloning leaf objects by
// hash), and writes the 32-byte domain-separated root tree hash into `result`.
//
// **Error kinds**
//
// - `No_Grant` (Grant_Or_Right_Missing: no store, read-only connection, or target_place is not the caller's own store);
// - `Absent` (Argument_Refused, Nothing_Has_That_Name: place or target_place absent);
// - `Bad_Value` (Argument_Refused, unit Trees: target_place is equal to or inside place);
// - `Too_Long` (Argument_Refused: tree nesting past 32 levels or more than 512 entries in one tree);
// - `Over_Limit` (Budget_Or_Capacity_Exhausted: store block limit exceeded);
// - `Full`, `Device`, `Damaged`.
@(export, link_name = "freeze_tree")
freeze_tree :: proc "c" (place: i64, target_place: i64, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	caller := caller_of()
	if refused, refusal := change_refusal(&caller, error); refused {
		return refusal, 0
	}
	source_path, source_ok := place_path(&caller, place, error, 1)
	if !source_ok {
		return .Argument_Refused, 0
	}
	target_path, target_ok := place_path(&caller, target_place, error, 2)
	if !target_ok {
		return .Argument_Refused, 0
	}
	if !target_path.own {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Store, 2)
	}
	if path_is_same_or_under(&target_path, &source_path) {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Trees, 2)
	}
	if len(result) < blake3.HASH_SIZE {
		return .Succeeded, blake3.HASH_SIZE
	}

	source_root: Pointer
	source_store_index := store_find(source_path.store.name)
	if source_store_index >= 0 {
		if store_damaged[source_store_index] {
			return call_outcome.fail(error, .Data_Damaged, .Damaged, .Stores)
		}
		lookup: Lookup
		source_root, lookup = tree_of(source_store_index, path_names(&source_path))
		if lookup != .Found {
			if lookup == .Absent {
				return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Places, 1)
			}
			return lookup_refusal(lookup, error, 1), 0
		}
	} else if source_path.depth > 0 {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Places, 1)
	}

	ctx := Immutable_Context {
		caller      = &caller,
		source_path = &source_path,
		target_path = &target_path,
	}
	backend := immutable_tree.Store_Backend {
		read_object          = immutable_read_object,
		has_object           = immutable_has_object,
		write_object         = immutable_write_object,
		persist_entry_object = immutable_persist_entry_object,
		data                 = &ctx,
	}
	root_hash, status := immutable_tree.freeze_tree(&freeze_work, &node_source, &freeze_tree_pool, source_root, &backend)
	if status != .Ok {
		return tree_store_status_fail(status, &ctx, error, 1)
	}
	copy(result^[:blake3.HASH_SIZE], root_hash[:])
	return .Succeeded, blake3.HASH_SIZE
}

// tree_read loads an immutable tree object by its 64-byte lowercase hex hash
// under `place`, validates its canonical encoding and domain-separated BLAKE3
// tree hash, and writes the canonical bytes into `result`.
//
// **Error kinds**
//
// - `No_Grant`;
// - `Absent` (Argument_Refused, Nothing_Has_That_Name: place or tree hash absent);
// - `Empty`, `Bad_Value`, `Bad_Byte` (Argument_Refused: invalid 64-byte lowercase hex hash);
// - `Damaged` (Data_Damaged: stored tree object failed canonical or hash verification);
// - `Device`.
@(export, link_name = "tree_read")
tree_read :: proc "c" (place: i64, hash_hex: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if refused, refusal := disk_unopened_refusal(error); refused {
		return refusal, 0
	}
	caller := caller_of()
	if caller.connection == nil {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Store)
	}
	target_path, ok := place_path(&caller, place, error, 1)
	if !ok {
		return .Argument_Refused, 0
	}
	if target_path.own && target_path.store.limit == 0 {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Store)
	}
	hash, hash_ok := parse_hex_hash_argument(hash_hex^, error, 2)
	if !hash_ok {
		return .Argument_Refused, 0
	}
	ctx := Immutable_Context {
		caller      = &caller,
		source_path = &target_path,
		target_path = &target_path,
	}
	backend := immutable_tree.Store_Backend {
		read_object = immutable_read_object,
		data        = &ctx,
	}
	canonical, status := immutable_tree.tree_read(&backend, hash, immutable_tree_scratch[:])
	if status != .Ok {
		return tree_store_status_fail(status, &ctx, error, 2)
	}
	if len(canonical) > len(result) {
		return .Succeeded, i64(len(canonical))
	}
	copy(result^[:len(canonical)], canonical)
	return .Succeeded, i64(len(canonical))
}

// tree_entry looks up entry `name` inside the immutable tree `hash_hex` under
// `place` via binary search after full canonical and hash verification, and
// returns one Tree_Entry_Row.
//
// **Error kinds**
//
// - those of [tree_read](storage.tree_read), plus `Absent` (Nothing_Has_That_Name: entry absent)
//   and name validation errors (Argument_Refused: argument 3).
@(export, link_name = "tree_entry")
tree_entry :: proc "c" (place: i64, hash_hex: ^string, name: ^string, result: ^[]Tree_Entry_Row, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if refused, refusal := disk_unopened_refusal(error); refused {
		return refusal, 0
	}
	caller := caller_of()
	if caller.connection == nil {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Store)
	}
	target_path, ok := place_path(&caller, place, error, 1)
	if !ok {
		return .Argument_Refused, 0
	}
	if target_path.own && target_path.store.limit == 0 {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Store)
	}
	hash, hash_ok := parse_hex_hash_argument(hash_hex^, error, 2)
	if !hash_ok {
		return .Argument_Refused, 0
	}
	kept_name, name_ok := name_keep(name^, error, 3)
	if !name_ok {
		return .Argument_Refused, 0
	}
	ctx := Immutable_Context {
		caller      = &caller,
		source_path = &target_path,
		target_path = &target_path,
	}
	backend := immutable_tree.Store_Backend {
		read_object = immutable_read_object,
		data        = &ctx,
	}
	found_entry, status := immutable_tree.tree_entry(&backend, hash, kept_text(&kept_name), immutable_tree_scratch[:])
	if status != .Ok {
		return tree_store_status_fail(status, &ctx, error, status == .Invalid_Name ? 3 : 2)
	}
	if len(result) > 0 {
		result[0] = {
			kind = i64(found_entry.kind),
			hash = value_kinds.Hash_Field(found_entry.hash),
		}
	}
	return .Succeeded, 1
}

// Context carried by module_gc callbacks during collect_garbage.
@(private = "file")
GC_Context :: struct {
	target_path: ^Path,
	store_index: int,
}

@(private = "file")
gc_read_object :: proc "contextless" (reader: ^module_gc.Object_Reader, hash: blake3.Hash, buffer: []u8) -> (int, module_gc.Read_Status) {
	ctx := (^GC_Context)(reader.data)
	if ctx.store_index < 0 {
		return 0, .Absent
	}
	if store_damaged[ctx.store_index] {
		return 0, .Device_Error
	}
	name := immutable_tree.hash_to_hex(hash)
	value, outcome := entry_of(ctx.store_index, path_names(ctx.target_path), name)
	switch outcome {
	case .Found:
	case .Absent:
		return 0, .Absent
	case .Wrong, .Device:
		return 0, .Device_Error
	}
	if value.kind != u64(format.Entry_Kind.Object) {
		return 0, .Absent
	}
	if value.size > u64(len(buffer)) {
		return 0, .Too_Large
	}
	read_err: errors.Error_Record
	read_bytes, read_outcome := state_read(current_state(&value), 0, buffer[:value.size], &read_err, 1)
	if read_outcome != .Succeeded {
		return 0, .Device_Error
	}
	return int(read_bytes), .Found
}

@(private = "file")
gc_delete_object :: proc "contextless" (user_data: rawptr, hash: blake3.Hash) -> bool {
	ctx := (^GC_Context)(user_data)
	kept := kept_name_of_hex(immutable_tree.hash_to_hex(hash))
	remove_err: errors.Error_Record
	_, removed := entry_remove(ctx.target_path.store, path_names(ctx.target_path), kept, &remove_err)
	return removed == .Succeeded
}

// collect_garbage runs mark-and-sweep garbage collection over the
// content-addressed objects under `place`, keeping every hash reachable from
// `roots` (signed system modules, kept applied plans, disk grant modules, and
// pinned trees). Any invalid or corrupt root or tree aborts the pass with zero
// deletions.
//
// **Error kinds**
//
// - `No_Grant` (Grant_Or_Right_Missing: no store, read-only connection, share, or foreign store);
// - `Absent` (Argument_Refused, Nothing_Has_That_Name: place absent, or a pinned tree root or child tree is absent);
// - `Too_Long` (Budget_Or_Capacity_Exhausted: more than GC_ROOT_CAPACITY roots or depth bound exceeded);
// - `Bad_Value` (Argument_Refused: unknown Root_Kind word or zero root hash);
// - `Damaged` (Data_Damaged: corrupt root, corrupt tree, or cycle detected; zero deletions performed);
// - `Full` (Budget_Or_Capacity_Exhausted: collector capacity exceeded);
// - `Device`.
@(export, link_name = "collect_garbage")
collect_garbage :: proc "c" (place: i64, roots: ^system.Table_To_Read(Garbage_Root_Row), result: ^[]Garbage_Measure, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	caller := caller_of()
	if refused, refusal := change_refusal(&caller, error); refused {
		return refusal, 0
	}
	if share_of(caller.connection) != nil {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Changes)
	}
	target_path, ok := place_path(&caller, place, error, 1)
	if !ok {
		return .Argument_Refused, 0
	}
	if !target_path.own {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Store, 1)
	}

	records := system.table_records(roots)
	if len(records) > GC_ROOT_CAPACITY {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Records, 2, i64(len(records)), GC_ROOT_CAPACITY)
	}
	// Copy roots from call region and convert Root_Kind at the border.
	root_count := len(records)
	for index in 0 ..< root_count {
		row := records[index]
		checked_kind, kind_ok := module_gc.root_kind_of_word(u64(row.kind))
		if !kind_ok {
			return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Records, 2, row.kind, i64(module_gc.Root_Kind.Pinned_Tree), i64(index + 1))
		}
		gc_roots_copy[index] = {
			kind = checked_kind,
			hash = blake3.Hash(row.hash),
		}
	}

	store_index := store_find(target_path.store.name)
	stored_count := 0
	if store_index >= 0 {
		if store_damaged[store_index] {
			return call_outcome.fail(error, .Data_Damaged, .Damaged, .Stores)
		}
		root_node, lookup := tree_of(store_index, path_names(&target_path))
		if lookup != .Found {
			if lookup == .Absent {
				return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Places, 1)
			}
			return lookup_refusal(lookup, error, 1), 0
		}
		// Scan content-addressed (64 lowercase hex digit) object entries under place.
		cursor: Entry_Name
		has_cursor := false
		for {
			tree.pool_reset(&freeze_tree_pool)
			work := tree.Work{pool = &freeze_tree_pool, source = &node_source, shape = tree.TREE_SHAPE, root = root_node}
			key: Entry_Name
			value: Entry
			if !tree.first_from(&work, cursor[:], has_cursor, key[:], entry_bytes(&value)) {
				if freeze_tree_pool.failure != .None {
					return call_outcome.fail(error, freeze_tree_pool.failure == .Device ? .Callee_Unavailable : .Data_Damaged, freeze_tree_pool.failure == .Device ? .Device : .Damaged, .Stores)
				}
				break
			}
			cursor = key
			has_cursor = true
			if value.kind != u64(format.Entry_Kind.Object) {
				continue
			}
			name_text := format.name_of(&key)
			parsed_hash, is_hex := immutable_tree.hex_to_hash(transmute([]u8)name_text)
			if !is_hex {
				continue
			}
			if stored_count >= GC_CANDIDATE_CAPACITY {
				return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Full, .Objects, 1, GC_CANDIDATE_CAPACITY + 1, GC_CANDIDATE_CAPACITY)
			}
			gc_stored_hashes[stored_count] = parsed_hash
			stored_count += 1
		}
	}

	gc_ctx := GC_Context {
		target_path = &target_path,
		store_index = store_index,
	}
	gc_reader := module_gc.Object_Reader {
		read_object = gc_read_object,
		data        = &gc_ctx,
	}
	collect_result, deleted_count := module_gc.collect_and_sweep(
		&gc_state,
		gc_roots_copy[:root_count],
		gc_stored_hashes[:stored_count],
		&gc_reader,
		gc_sweep_hashes[:],
		gc_delete_object,
		&gc_ctx,
	)
	switch collect_result.status {
	case .Ok:
	case .Bad_Root_Kind, .Zero_Root_Hash, .Bad_Depth_Bound:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Records, 2)
	case .Missing_Root, .Missing_Tree:
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Trees, 2)
	case .Corrupt_Root, .Corrupt_Tree, .Cycle_Detected:
		return call_outcome.fail(error, .Data_Damaged, .Damaged, .Trees, 2)
	case .Depth_Exceeded:
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Trees, 2, module_gc.MAX_TRAVERSAL_DEPTH + 1, module_gc.MAX_TRAVERSAL_DEPTH)
	case .Device_Error:
		return call_outcome.fail(error, .Callee_Unavailable, .Device)
	case .Mark_Capacity_Exceeded, .Stack_Capacity_Exceeded, .Sweep_Capacity_Exceeded:
		return call_outcome.fail(error, .Budget_Or_Capacity_Exhausted, .Full, .Objects, 1)
	}
	if len(result) > 0 {
		result[0] = {
			marked          = i64(collect_result.marked_count),
			swept           = i64(deleted_count),
			trees_traversed = i64(collect_result.trees_traversed),
		}
	}
	return .Succeeded, 1
}
