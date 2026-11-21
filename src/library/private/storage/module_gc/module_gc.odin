// Pure mark-and-sweep garbage collector for the machine store `module_files`
// (src/md/features/declarations.md, "The garbage collector").
//
// Zero dynamic allocation, zero recursion, fail-closed design:
// - Takes a root set of hashes (signed system modules, kept applied plans,
//   disk grant table module hashes, pinned immutable trees).
// - Validates every root kind through its enum border and refuses zero hashes.
// - Traverses immutable tree objects transitively with an explicit iterative
//   DFS stack, strict depth bound (MAX_TRAVERSAL_DEPTH), cycle detection,
//   diamond DAG deduplication with exact height tracking, and full canonical
//   + domain-separated BLAKE3 verification on every node.
// - Follows optional extra object references (module imports, debug objects,
//   realisation outputs) transitively.
// - On ANY refusal (bad root kind, zero hash, missing pinned tree root,
//   corrupt root, corrupt or missing tree, cycle, depth exceeded, device
//   error, or capacity limit), aborts immediately with sweep_count == 0 and
//   deletes nothing.
package module_gc

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import format "modus:contract/store"
import "modus:contract/tree_hash"

// Strict maximum tree nesting depth traversed during mark (matches store.NESTING_LIMIT).
MAX_TRAVERSAL_DEPTH :: format.NESTING_LIMIT

// Fixed capacities of the zero-allocation Collector_State tables.
MAX_MARKED_HASHES :: 8192
MARK_TABLE_SLOTS :: 16384 // Power of two; load factor <= 0.5.
MAX_COMPLETED_TREES :: 4096
COMPLETED_TABLE_SLOTS :: 8192 // Power of two; load factor <= 0.5.
WORK_STACK_CAPACITY :: 4096
REF_QUEUE_CAPACITY :: 4096
MAX_EXTRA_REFS_PER_OBJECT :: 64

#assert((MARK_TABLE_SLOTS & (MARK_TABLE_SLOTS - 1)) == 0)
#assert((COMPLETED_TABLE_SLOTS & (COMPLETED_TABLE_SLOTS - 1)) == 0)

// Closed set of garbage-collector root categories.
Root_Kind :: enum u8 {
	Signed_System_Module = 1, // Module hash from the signed system description.
	Applied_Plan         = 2, // Hash referenced by a kept applied plan (active or rollback).
	Disk_Grant_Module    = 3, // Module hash from a principal's disk grant table.
	Pinned_Tree          = 4, // Pinned immutable tree hash (source, declaration, build output).
}

// One garbage-collector root.
Root :: struct {
	kind: Root_Kind,
	hash: blake3.Hash,
}

// Closed set of outcomes returned by Object_Reader.read_object.
Read_Status :: enum u8 {
	Found        = 1,
	Absent       = 2,
	Too_Large    = 3, // Larger than buffer: valid for large non-tree modules, corrupt for trees.
	Device_Error = 4,
}

// Closed set of outcomes returned by Object_Reader.read_references.
Reference_Status :: enum u8 {
	Ok           = 0,
	Corrupt      = 1,
	Device_Error = 2,
}

// Closed set of outcomes returned by collect / collect_and_sweep.
Collect_Status :: enum u8 {
	Ok                      = 0,
	Bad_Root_Kind           = 1,
	Zero_Root_Hash          = 2,
	Missing_Root            = 3,
	Corrupt_Root            = 4,
	Corrupt_Tree            = 5,
	Missing_Tree            = 6,
	Cycle_Detected          = 7,
	Depth_Exceeded          = 8,
	Device_Error            = 9,
	Mark_Capacity_Exceeded  = 10,
	Stack_Capacity_Exceeded = 11,
	Sweep_Capacity_Exceeded = 12,
	Bad_Depth_Bound         = 13,
}

// Abstract read-only view of `module_files` used during the mark phase.
Object_Reader :: struct {
	read_object: proc "contextless" (reader: ^Object_Reader, hash: blake3.Hash, buffer: []u8) -> (length: int, status: Read_Status),
	// Optional callback that extracts non-tree references (e.g. module imports,
	// debug object hash, or realisation outputs) from a reachable object hash.
	read_references: proc "contextless" (reader: ^Object_Reader, hash: blake3.Hash, out: []blake3.Hash) -> (count: int, status: Reference_Status),
	data:            rawptr,
}

// Callback invoked for each unreachable hash during collect_and_sweep (only when collect returns Ok).
Delete_Callback :: proc "contextless" (user_data: rawptr, hash: blake3.Hash) -> bool

// Summary returned by one collection pass.
Collect_Result :: struct {
	status:          Collect_Status,
	marked_count:    int,
	sweep_count:     int,
	trees_traversed: int,
	max_depth_seen:  int,
	failing_hash:    blake3.Hash,
}

// Open-addressed hash set of BLAKE3 hashes (1-based indices into items; 0 = empty).
@(private)
Hash_Set :: struct {
	items: [MAX_MARKED_HASHES]blake3.Hash,
	count: int,
	slots: [MARK_TABLE_SLOTS]u16,
}

// Completed tree table storing the exact subtree height of each visited tree
// so diamond DAG skips still enforce max_depth accurately.
@(private)
Completed_Tree_Set :: struct {
	hashes:  [MAX_COMPLETED_TREES]blake3.Hash,
	heights: [MAX_COMPLETED_TREES]u8,
	count:   int,
	slots:   [COMPLETED_TABLE_SLOTS]u16,
}

// One frame on the explicit iterative DFS stack.
@(private)
Stack_Item :: struct {
	hash:     blake3.Hash,
	depth:    int,
	expanded: bool,
}

// Caller-owned fixed workspace for mark-and-sweep collection.
Collector_State :: struct {
	marked:           Hash_Set,
	swept:            Hash_Set,
	completed:        Completed_Tree_Set,
	work_stack:       [WORK_STACK_CAPACITY]Stack_Item,
	work_top:         int,
	ancestors:        [MAX_TRAVERSAL_DEPTH + 1]blake3.Hash,
	ancestor_heights: [MAX_TRAVERSAL_DEPTH + 1]u8,
	ancestor_count:   int,
	ref_queue:        [REF_QUEUE_CAPACITY]blake3.Hash,
	ref_head:         int,
	ref_tail:         int,
	read_buffer:      [tree_hash.MAX_ENCODED_TREE_BYTES]u8,
}

// root_kind_of_word is the single border converting a transport word into a
// closed Root_Kind member. Unknown values are refused.
root_kind_of_word :: proc "contextless" (word: u64) -> (kind: Root_Kind, ok: bool) {
	return enum_word.member_of_word(Root_Kind, word)
}

@(private)
hash_is_zero :: proc "contextless" (hash: blake3.Hash) -> bool {
	zero: blake3.Hash
	return hash == zero
}

@(private)
hash_slot_start :: #force_inline proc "contextless" (hash: blake3.Hash, mask: u64) -> u64 {
	copy_of := hash
	return byte_order.read_u64_little_endian(copy_of[:], 0) & mask
}

@(private)
hash_set_reset :: proc "contextless" (set: ^Hash_Set) {
	set.count = 0
	set.slots = {}
}

@(private)
hash_set_contains :: proc "contextless" (set: ^Hash_Set, hash: blake3.Hash) -> bool {
	mask := u64(MARK_TABLE_SLOTS - 1)
	slot := hash_slot_start(hash, mask)
	for _ in 0 ..< MARK_TABLE_SLOTS {
		entry := set.slots[slot]
		if entry == 0 {
			return false
		}
		if set.items[entry - 1] == hash {
			return true
		}
		slot = (slot + 1) & mask
	}
	return false
}

@(private)
hash_set_insert :: proc "contextless" (set: ^Hash_Set, hash: blake3.Hash) -> (added: bool, ok: bool) {
	mask := u64(MARK_TABLE_SLOTS - 1)
	slot := hash_slot_start(hash, mask)
	for _ in 0 ..< MARK_TABLE_SLOTS {
		entry := set.slots[slot]
		if entry == 0 {
			if set.count >= MAX_MARKED_HASHES {
				return false, false
			}
			index := set.count
			set.items[index] = hash
			set.count += 1
			set.slots[slot] = u16(index + 1)
			return true, true
		}
		if set.items[entry - 1] == hash {
			return false, true
		}
		slot = (slot + 1) & mask
	}
	return false, false
}

@(private)
completed_reset :: proc "contextless" (set: ^Completed_Tree_Set) {
	set.count = 0
	set.slots = {}
}

@(private)
completed_find :: proc "contextless" (set: ^Completed_Tree_Set, hash: blake3.Hash) -> (height: u8, found: bool) {
	mask := u64(COMPLETED_TABLE_SLOTS - 1)
	slot := hash_slot_start(hash, mask)
	for _ in 0 ..< COMPLETED_TABLE_SLOTS {
		entry := set.slots[slot]
		if entry == 0 {
			return 0, false
		}
		if set.hashes[entry - 1] == hash {
			return set.heights[entry - 1], true
		}
		slot = (slot + 1) & mask
	}
	return 0, false
}

@(private)
completed_insert :: proc "contextless" (set: ^Completed_Tree_Set, hash: blake3.Hash, height: u8) -> bool {
	mask := u64(COMPLETED_TABLE_SLOTS - 1)
	slot := hash_slot_start(hash, mask)
	for _ in 0 ..< COMPLETED_TABLE_SLOTS {
		entry := set.slots[slot]
		if entry == 0 {
			if set.count >= MAX_COMPLETED_TREES {
				return false
			}
			index := set.count
			set.hashes[index] = hash
			set.heights[index] = height
			set.count += 1
			set.slots[slot] = u16(index + 1)
			return true
		}
		if set.hashes[entry - 1] == hash {
			if height > set.heights[entry - 1] {
				set.heights[entry - 1] = height
			}
			return true
		}
		slot = (slot + 1) & mask
	}
	return false
}

@(private)
has_tree_magic :: proc "contextless" (bytes: []u8) -> bool {
	if len(bytes) < len(tree_hash.HEADER_MAGIC) {
		return false
	}
	magic := tree_hash.HEADER_MAGIC
	for index in 0 ..< len(magic) {
		if bytes[index] != magic[index] {
			return false
		}
	}
	return true
}

@(private)
mark_object_and_queue_refs :: proc "contextless" (state: ^Collector_State, reader: ^Object_Reader, hash: blake3.Hash) -> Collect_Status {
	added, ok := hash_set_insert(&state.marked, hash)
	if !ok {
		return .Mark_Capacity_Exceeded
	}
	if added && reader.read_references != nil {
		if state.ref_tail >= REF_QUEUE_CAPACITY {
			return .Stack_Capacity_Exceeded
		}
		state.ref_queue[state.ref_tail] = hash
		state.ref_tail += 1
	}
	return .Ok
}

// drain_extra_references follows non-tree references (such as module imports or
// debug objects) iteratively for every newly marked object.
@(private)
drain_extra_references :: proc "contextless" (state: ^Collector_State, reader: ^Object_Reader, failing: ^blake3.Hash) -> Collect_Status {
	if reader.read_references == nil {
		return .Ok
	}
	refs: [MAX_EXTRA_REFS_PER_OBJECT]blake3.Hash
	for state.ref_head < state.ref_tail {
		current := state.ref_queue[state.ref_head]
		state.ref_head += 1
		count, ref_status := reader.read_references(reader, current, refs[:])
		switch ref_status {
		case .Ok:
		case .Corrupt:
			failing^ = current
			return .Corrupt_Root
		case .Device_Error:
			failing^ = current
			return .Device_Error
		}
		if count < 0 || count > len(refs) {
			failing^ = current
			return .Corrupt_Root
		}
		for ref_hash in refs[:count] {
			if hash_is_zero(ref_hash) {
				failing^ = current
				return .Corrupt_Root
			}
			if status := mark_object_and_queue_refs(state, reader, ref_hash); status != .Ok {
				failing^ = ref_hash
				return status
			}
		}
	}
	return .Ok
}

// traverse_tree_iterative marks root_tree_hash and every object and subtree
// reachable from it using an explicit iterative DFS stack with cycle detection
// and exact subtree height tracking for diamond DAGs.
@(private)
traverse_tree_iterative :: proc "contextless" (
	state: ^Collector_State,
	reader: ^Object_Reader,
	root_tree_hash: blake3.Hash,
	max_depth: int,
	trees_traversed: ^int,
	max_depth_seen: ^int,
	failing: ^blake3.Hash,
) -> Collect_Status {
	state.work_top = 0
	state.ancestor_count = 0
	state.work_stack[0] = {hash = root_tree_hash, depth = 0, expanded = false}
	state.work_top = 1

	for state.work_top > 0 {
		state.work_top -= 1
		item := state.work_stack[state.work_top]

		if item.expanded {
			state.ancestor_count -= 1
			finished_height := state.ancestor_heights[state.ancestor_count]
			if !completed_insert(&state.completed, item.hash, finished_height) {
				failing^ = item.hash
				return .Mark_Capacity_Exceeded
			}
			if state.ancestor_count > 0 {
				parent_height := &state.ancestor_heights[state.ancestor_count - 1]
				candidate := finished_height + 1
				if candidate > parent_height^ {
					parent_height^ = candidate
				}
			}
			continue
		}

		// Explicit cycle check against the active ancestor path.
		for ancestor in state.ancestors[:state.ancestor_count] {
			if ancestor == item.hash {
				failing^ = item.hash
				return .Cycle_Detected
			}
		}

		// Strict depth bound check before any diamond skip.
		if item.depth > max_depth {
			failing^ = item.hash
			return .Depth_Exceeded
		}

		// Diamond DAG: if this subtree was already completely validated and
		// marked, verify that its height still fits within max_depth from
		// this path and reuse the mark without re-reading.
		if sub_height, already_done := completed_find(&state.completed, item.hash); already_done {
			total_depth := item.depth + int(sub_height)
			if total_depth > max_depth {
				failing^ = item.hash
				return .Depth_Exceeded
			}
			if total_depth > max_depth_seen^ {
				max_depth_seen^ = total_depth
			}
			if state.ancestor_count > 0 {
				parent_height := &state.ancestor_heights[state.ancestor_count - 1]
				candidate := sub_height + 1
				if candidate > parent_height^ {
					parent_height^ = candidate
				}
			}
			continue
		}

		// Read and strictly verify the canonical tree node and its hash.
		length, read_status := reader.read_object(reader, item.hash, state.read_buffer[:])
		switch read_status {
		case .Found:
		case .Absent:
			failing^ = item.hash
			return item.depth == 0 ? .Missing_Root : .Missing_Tree
		case .Too_Large:
			failing^ = item.hash
			return .Corrupt_Tree
		case .Device_Error:
			failing^ = item.hash
			return .Device_Error
		}
		if length < 0 || length > len(state.read_buffer) {
			failing^ = item.hash
			return .Corrupt_Tree
		}
		canonical := state.read_buffer[:length]
		entry_count, val_refusal := tree_hash.tree_validate(canonical)
		if val_refusal != .None {
			failing^ = item.hash
			return .Corrupt_Tree
		}
		computed_hash, hash_refusal := tree_hash.tree_hash(canonical)
		if hash_refusal != .None || computed_hash != item.hash {
			failing^ = item.hash
			return .Corrupt_Tree
		}

		// Mark the verified tree node.
		if _, mark_ok := hash_set_insert(&state.marked, item.hash); !mark_ok {
			failing^ = item.hash
			return .Mark_Capacity_Exceeded
		}
		trees_traversed^ += 1
		if item.depth > max_depth_seen^ {
			max_depth_seen^ = item.depth
		}

		// Push onto active ancestor path and schedule exit marker.
		if state.ancestor_count > max_depth || state.work_top >= WORK_STACK_CAPACITY {
			failing^ = item.hash
			return .Stack_Capacity_Exceeded
		}
		state.ancestors[state.ancestor_count] = item.hash
		state.ancestor_heights[state.ancestor_count] = 0
		state.ancestor_count += 1
		state.work_stack[state.work_top] = {hash = item.hash, depth = item.depth, expanded = true}
		state.work_top += 1

		// Inspect every entry of the validated canonical tree.
		for index in 0 ..< entry_count {
			entry, ok := tree_hash.tree_entry_at(canonical, index)
			if !ok {
				failing^ = item.hash
				return .Corrupt_Tree
			}
			switch entry.kind {
			case .Object:
				if status := mark_object_and_queue_refs(state, reader, entry.hash); status != .Ok {
					failing^ = entry.hash
					return status
				}
			case .Tree:
				// Check cycle against active ancestors immediately.
				for ancestor in state.ancestors[:state.ancestor_count] {
					if ancestor == entry.hash {
						failing^ = entry.hash
						return .Cycle_Detected
					}
				}
				if item.depth + 1 > max_depth {
					failing^ = entry.hash
					return .Depth_Exceeded
				}
				if state.work_top >= WORK_STACK_CAPACITY {
					failing^ = entry.hash
					return .Stack_Capacity_Exceeded
				}
				state.work_stack[state.work_top] = {hash = entry.hash, depth = item.depth + 1, expanded = false}
				state.work_top += 1
			}
		}
	}
	return .Ok
}

// collect runs a full mark-and-sweep calculation over stored_objects starting
// from roots. On any error or integrity violation, it returns status != .Ok
// with sweep_count == 0 (fail-closed: nothing may be deleted).
collect :: proc "contextless" (
	state: ^Collector_State,
	roots: []Root,
	stored_objects: []blake3.Hash,
	reader: ^Object_Reader,
	sweep_out: []blake3.Hash,
	max_depth: int = MAX_TRAVERSAL_DEPTH,
) -> (result: Collect_Result) {
	if state == nil || reader == nil || reader.read_object == nil {
		return {status = .Device_Error}
	}
	if max_depth < 0 || max_depth > MAX_TRAVERSAL_DEPTH {
		return {status = .Bad_Depth_Bound}
	}

	hash_set_reset(&state.marked)
	hash_set_reset(&state.swept)
	completed_reset(&state.completed)
	state.ref_head = 0
	state.ref_tail = 0

	// Pass 1: validate every root at the border before marking anything.
	for root in roots {
		if _, kind_ok := root_kind_of_word(u64(root.kind)); !kind_ok {
			return {status = .Bad_Root_Kind, failing_hash = root.hash}
		}
		if hash_is_zero(root.hash) {
			return {status = .Zero_Root_Hash}
		}
	}

	// Pass 2: mark every root and traverse reachable trees and references.
	for root in roots {
		checked_kind, _ := root_kind_of_word(u64(root.kind))
		switch checked_kind {
		case .Pinned_Tree:
			status := traverse_tree_iterative(
				state,
				reader,
				root.hash,
				max_depth,
				&result.trees_traversed,
				&result.max_depth_seen,
				&result.failing_hash,
			)
			if status != .Ok {
				result.status = status
				result.sweep_count = 0
				return result
			}
		case .Signed_System_Module, .Applied_Plan, .Disk_Grant_Module:
			if mark_status := mark_object_and_queue_refs(state, reader, root.hash); mark_status != .Ok {
				result.status = mark_status
				result.failing_hash = root.hash
				result.sweep_count = 0
				return result
			}
			length, read_status := reader.read_object(reader, root.hash, state.read_buffer[:])
			switch read_status {
			case .Absent:
				// External or boot-image root not materialized in module_files:
				// still marked so any copy cannot be swept.
			case .Too_Large:
				// Larger than MAX_ENCODED_TREE_BYTES: a large non-tree module
				// object, already marked.
			case .Device_Error:
				result.status = .Device_Error
				result.failing_hash = root.hash
				result.sweep_count = 0
				return result
			case .Found:
				if length < 0 || length > len(state.read_buffer) {
					result.status = .Corrupt_Root
					result.failing_hash = root.hash
					result.sweep_count = 0
					return result
				}
				bytes := state.read_buffer[:length]
				handled_as_tree := false
				if has_tree_magic(bytes) {
					if computed_tree, tree_ref := tree_hash.tree_hash(bytes); tree_ref == .None && computed_tree == root.hash {
						status := traverse_tree_iterative(
							state,
							reader,
							root.hash,
							max_depth,
							&result.trees_traversed,
							&result.max_depth_seen,
							&result.failing_hash,
						)
						if status != .Ok {
							result.status = status
							result.sweep_count = 0
							return result
						}
						handled_as_tree = true
					}
				}
				if !handled_as_tree && blake3.hash(bytes) != root.hash {
					result.status = .Corrupt_Root
					result.failing_hash = root.hash
					result.sweep_count = 0
					return result
				}
			}
		}
		if ref_status := drain_extra_references(state, reader, &result.failing_hash); ref_status != .Ok {
			result.status = ref_status
			result.sweep_count = 0
			return result
		}
	}

	// Pass 3: compute the exact deduplicated sweep set of unreachable objects.
	sweep_count := 0
	for stored_hash in stored_objects {
		if hash_set_contains(&state.marked, stored_hash) {
			continue
		}
		added, set_ok := hash_set_insert(&state.swept, stored_hash)
		if !set_ok {
			result.status = .Sweep_Capacity_Exceeded
			result.failing_hash = stored_hash
			result.sweep_count = 0
			return result
		}
		if !added {
			continue
		}
		if sweep_count >= len(sweep_out) {
			result.status = .Sweep_Capacity_Exceeded
			result.failing_hash = stored_hash
			result.sweep_count = 0
			return result
		}
		sweep_out[sweep_count] = stored_hash
		sweep_count += 1
	}

	result.status = .Ok
	result.marked_count = state.marked.count
	result.sweep_count = sweep_count
	return result
}

// collect_and_sweep computes the sweep set via collect and invokes
// delete_object on each unreachable hash ONLY when collect succeeds with Ok.
// Any refusal guarantees zero calls to delete_object.
collect_and_sweep :: proc "contextless" (
	state: ^Collector_State,
	roots: []Root,
	stored_objects: []blake3.Hash,
	reader: ^Object_Reader,
	sweep_scratch: []blake3.Hash,
	delete_object: Delete_Callback,
	delete_user_data: rawptr = nil,
	max_depth: int = MAX_TRAVERSAL_DEPTH,
) -> (result: Collect_Result, deleted_count: int) {
	result = collect(state, roots, stored_objects, reader, sweep_scratch, max_depth)
	if result.status != .Ok || delete_object == nil {
		return result, 0
	}
	for hash in sweep_scratch[:result.sweep_count] {
		if delete_object(delete_user_data, hash) {
			deleted_count += 1
		}
	}
	return result, deleted_count
}
