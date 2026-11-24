// Keyless, bounded, crash-resumable block reclamation for orphaned encrypted
// stores of removed named principals (src/md/features/store_encryption.md,
// "Reclaiming orphaned stores of a removed principal").
//
// Because every structural pointer in STORAGE7 stays in clear (Store_Block,
// Tree_Node, Object_Node, Version_Index, Version_Leaf, Release_List), this
// package walks and peels a reclaiming store without any encryption key.
// Every step produces a valid copy-on-write STORAGE7 tree with exact counts
// so a crash or power loss at any commit resumes cleanly at the next mount.
package store_reclaim

import "internal:storage/storage_tree"
import format "modus:contract/store"

Block :: [format.BLOCK_SIZE]u8

// Maximum entries popped from one leftmost leaf in a single reclaim commit.
// Matches storage/trees.odin REMOVAL_STEP_LIMIT so each commit stays within
// plan delta and count-tree leaf staging bounds.
RECLAIM_STEP_ENTRIES :: 16

// Maximum blocks dropped directly inside one reclaim commit before deferring
// a large object state to a clear Release_List. Sized so every commit fits
// comfortably inside the count-tree staging window and delta table.
RECLAIM_DIRECT_BLOCKS_LIMIT :: 256

// Outcome of one raw block read.
Read :: enum u8 {
	Good   = 0,
	Wrong  = 1,
	Device = 2,
}

// Outcome of one reclaim step.
Step_Outcome :: enum u8 {
	Progressed = 0, // Freed one or more entries/blocks; commit updated store block.
	Empty      = 1, // Store tree and removal queue are both empty; ready to free store block and cell.
	Device     = 2, // Disk read failed; abort commit and retry later.
	Full       = 3, // No free block or commit capacity reached; abort commit and retry later.
}

// Callbacks connecting the pure reclamation logic to either the live storage
// service engine or an in-memory host test disk.
Ops :: struct {
	// read_block reads a 4096-byte block and verifies Pointer.check == store.check(on_disk).
	read_block:      proc "contextless" (ops: ^Ops, pointer: format.Pointer, into: ^Block) -> Read,
	// write_block allocates a free block, registers its write, increments its refcount, and returns its Pointer.
	write_block:     proc "contextless" (ops: ^Ops, bytes: ^Block) -> (pointer: format.Pointer, ok: bool),
	// count_after returns the block's reference count after pending deltas in this commit.
	count_after:     proc "contextless" (ops: ^Ops, number: u64) -> i64,
	// drop decrements a block's reference count by 1 in this commit.
	drop:            proc "contextless" (ops: ^Ops, number: u64),
	// wrong_block reports whether `number` is already marked wrong or damaged_under.
	wrong_block:     proc "contextless" (ops: ^Ops, number: u64) -> bool,
	// mark_wrong records a newly discovered wrong block.
	mark_wrong:      proc "contextless" (ops: ^Ops, number: u64),
	// note_damaged records that a corrupt subtree was pruned and a count recount is needed.
	note_damaged:    proc "contextless" (ops: ^Ops, damaged_nodes: u64, damaged_blocks: u64),
	// enqueue_release queues a large object state into a clear Release_List for subsequent step commits.
	enqueue_release: proc "contextless" (ops: ^Ops, root: format.Pointer, size: u64) -> bool,
	// release_step runs storage_release.step over a Release_List using keyless encrypted-layout node reads.
	release_step:    proc "contextless" (ops: ^Ops, list: ^format.Release_List) -> (empty: bool, device: bool),
	// direct_blocks_limit overrides RECLAIM_DIRECT_BLOCKS_LIMIT when > 0 (for testing large-state deferral).
	direct_blocks_limit: int,
	data:            rawptr,
}

// Small caller-owned workspace for one reclaim step (~6 KiB, never placed on a
// deep call stack).
Tree_Path :: struct {
	depth: int, // Number of nodes on the leftmost path (1..=TREE_DEPTH_LIMIT).
	ptrs:  [format.TREE_DEPTH_LIMIT]format.Pointer,
}

Work :: struct {
	paths:          [format.NESTING_LIMIT + 1]Tree_Path,
	nesting:        int,
	node_buf:       Block,
	parent_buf:     Block,
	ver_index:      format.Version_Index,
	ver_leaf:       format.Version_Leaf,
	release_list:   format.Release_List,
	obj_nodes:      [format.OBJECT_LEVEL_LIMIT + 1]format.Object_Node,
	versions_freed: u64,
	entries_popped: int,
	direct_budget:  int,
}

// scrub_store_cell_and_block transitions an active owned store cell and its
// store block to the reclaiming state, zeroing all principal-identifying
// fields (name tag, owner identifier, salt, key check, sealed name, store
// generation, and MAC) while preserving structural roots and counts intact.
scrub_store_cell_and_block :: proc "contextless" (cell: ^format.Store_Entry, sb: ^format.Store_Block) {
	cell.name = {}
	cell.name[0] = format.RECLAIMING_CELL_MARK
	sb.owner = {}
	sb.salt = {}
	sb.key_check = {}
	sb.name_sealed = {}
	sb.store_generation = 0
	sb.mac = {}
}

// step executes one bounded keyless reclamation commit against `sb`.
// Drains `sb.removals` first, then `sb.tree`. Returns `.Empty` when both
// roots are zero (caller then frees `Store_Block` and zeroes the cell).
step :: proc "contextless" (ops: ^Ops, work: ^Work, sb: ^format.Store_Block, entry_limit := RECLAIM_STEP_ENTRIES) -> Step_Outcome {
	work.versions_freed = 0
	work.entries_popped = 0
	work.direct_budget = ops.direct_blocks_limit > 0 ? ops.direct_blocks_limit : RECLAIM_DIRECT_BLOCKS_LIMIT
	limit := entry_limit > 0 ? entry_limit : RECLAIM_STEP_ENTRIES

	if sb.removals.block != 0 {
		return step_removals(ops, work, sb, limit)
	}
	if sb.tree.block != 0 {
		return step_tree_stack(ops, work, &sb.tree, sb, limit, false)
	}
	return .Empty
}

// ---------------------------------------------------------------------
// Internal B+ tree raw node helpers (clear nodes, encrypted-layout safe).

@(private = "file")
leaf_entry_at :: proc "contextless" (node: ^Block, index: int) -> ^format.Entry {
	offset := format.TREE_HEADER_SIZE + index * (format.ENTRY_NAME_STORAGE + size_of(format.Entry)) + format.ENTRY_NAME_STORAGE
	return (^format.Entry)(&node[offset])
}

@(private = "file")
leaf_pop_front :: proc "contextless" (node: ^Block) -> (empty: bool) {
	head := (^format.Tree_Header)(node)
	if head.count <= 1 {
		return true
	}
	stride := format.ENTRY_NAME_STORAGE + size_of(format.Entry)
	remaining := int(head.count) - 1
	copy(node[format.TREE_HEADER_SIZE:][:remaining * stride], node[format.TREE_HEADER_SIZE + stride:][:remaining * stride])
	// Zero the vacated trailing record so clear nodes stay canonical.
	tail := node[format.TREE_HEADER_SIZE + remaining * stride:][:stride]
	for &b in tail {
		b = 0
	}
	head.count -= 1
	head.mac = {}
	return false
}

@(private = "file")
branch_child_at :: proc "contextless" (node: ^Block, index: int) -> ^format.Pointer {
	offset := format.TREE_HEADER_SIZE + index * (format.ENTRY_NAME_STORAGE + size_of(format.Pointer)) + format.ENTRY_NAME_STORAGE
	return (^format.Pointer)(&node[offset])
}

@(private = "file")
branch_pop_front :: proc "contextless" (node: ^Block) -> (empty: bool) {
	head := (^format.Tree_Header)(node)
	if head.count <= 1 {
		return true
	}
	stride := format.ENTRY_NAME_STORAGE + size_of(format.Pointer)
	remaining := int(head.count) - 1
	copy(node[format.TREE_HEADER_SIZE:][:remaining * stride], node[format.TREE_HEADER_SIZE + stride:][:remaining * stride])
	tail := node[format.TREE_HEADER_SIZE + remaining * stride:][:stride]
	for &b in tail {
		b = 0
	}
	head.count -= 1
	head.mac = {}
	return false
}

@(private = "file")
node_blocks_sub :: proc "contextless" (sb: ^format.Store_Block, n: u64) {
	sb.node_blocks = sb.node_blocks > n ? sb.node_blocks - n : 0
}

@(private = "file")
read_tree_node :: proc "contextless" (ops: ^Ops, ptr: format.Pointer, expected_level: int, into: ^Block) -> Read {
	if ops.wrong_block(ops, ptr.block) {
		return .Wrong
	}
	switch ops.read_block(ops, ptr, into) {
	case .Device:
		return .Device
	case .Wrong:
		ops.mark_wrong(ops, ptr.block)
		return .Wrong
	case .Good:
	}
	if !storage_tree.node_valid(into, storage_tree.TREE_SHAPE, encrypted = true) {
		ops.mark_wrong(ops, ptr.block)
		return .Wrong
	}
	head := (^format.Tree_Header)(into)
	if expected_level >= 0 && int(head.level) != expected_level {
		ops.mark_wrong(ops, ptr.block)
		return .Wrong
	}
	return .Good
}

// walk_leftmost fills `path` from `root` down to the leftmost leaf (loading
// the leaf into `work.node_buf`). On a damaged node at depth `d`, sets
// `path.depth = d + 1` and returns `.Wrong` so the caller can prune it.
@(private = "file")
walk_leftmost :: proc "contextless" (ops: ^Ops, root: format.Pointer, path: ^Tree_Path, leaf_out: ^Block) -> Read {
	path.depth = 0
	cur := root
	expected_level := -1
	for path.depth < format.TREE_DEPTH_LIMIT {
		path.ptrs[path.depth] = cur
		path.depth += 1
		read := read_tree_node(ops, cur, expected_level, leaf_out)
		if read != .Good {
			return read
		}
		head := (^format.Tree_Header)(leaf_out)
		if head.level == 0 {
			return .Good
		}
		expected_level = int(head.level) - 1
		cur = branch_child_at(leaf_out, 0)^
	}
	return .Wrong
}

// rewrite_leftmost_path propagates a modified or emptied child at index
// `start_idx` (0-based in `path.ptrs`) back up to the root of that tree,
// writing clear CoW nodes and updating `sb.node_blocks`.
// If `child_empty` is true, child 0 at `start_idx - 1` is popped; otherwise
// child 0 is updated to `new_child`.
@(private = "file")
rewrite_leftmost_path :: proc "contextless" (
	ops: ^Ops,
	work: ^Work,
	path: ^Tree_Path,
	start_idx: int,
	child_empty: bool,
	new_child: format.Pointer,
	sb: ^format.Store_Block,
) -> (new_root: format.Pointer, outcome: Step_Outcome) {
	empty := child_empty
	cur := new_child
	for level := start_idx - 1; level >= 0; level -= 1 {
		old_ptr := path.ptrs[level]
		read := read_tree_node(ops, old_ptr, -1, &work.parent_buf)
		if read == .Device {
			return {}, .Device
		}
		if read == .Wrong {
			// Ancestor unexpectedly corrupt: drop remaining chain above here.
			ops.drop(ops, old_ptr.block)
			node_blocks_sub(sb, 1)
			ops.note_damaged(ops, 1, 0)
			empty = true
			cur = {}
			continue
		}
		ops.drop(ops, old_ptr.block)
		if empty {
			empty = branch_pop_front(&work.parent_buf)
			if empty {
				node_blocks_sub(sb, 1)
				cur = {}
				continue
			}
		} else {
			branch_child_at(&work.parent_buf, 0)^ = cur
			(^format.Tree_Header)(&work.parent_buf).mac = {}
		}
		written, ok := ops.write_block(ops, &work.parent_buf)
		if !ok {
			return {}, .Full
		}
		cur = written
		empty = false
	}
	return empty ? format.Pointer{} : cur, .Progressed
}

// ---------------------------------------------------------------------
// Keyless object / version dropping.

@(private = "file")
read_object_node_keyless :: proc "contextless" (ops: ^Ops, ptr: format.Pointer, level: int, into: ^format.Object_Node) -> Read {
	if ops.wrong_block(ops, ptr.block) {
		return .Wrong
	}
	switch ops.read_block(ops, ptr, (^Block)(into)) {
	case .Device:
		return .Device
	case .Wrong:
		ops.mark_wrong(ops, ptr.block)
		return .Wrong
	case .Good:
	}
	if into.header.magic != format.OBJECT_NODE_MAGIC || int(into.header.level) != level {
		ops.mark_wrong(ops, ptr.block)
		return .Wrong
	}
	return .Good
}

// object_state_held_blocks computes the block count that storage_mount counts
// into `Store_Block.current_blocks` for a current object state.
@(private = "file")
object_state_held_blocks :: proc "contextless" (ops: ^Ops, work: ^Work, root: format.Pointer, size: u64) -> (held: u64, read: Read) {
	if root.block == 0 {
		return 0, .Good
	}
	if size > format.OBJECT_SIZE_LIMIT {
		return 0, .Wrong
	}
	levels := format.object_levels(size)
	if levels == 0 {
		return 1, .Good
	}
	node := &work.obj_nodes[levels]
	r := read_object_node_keyless(ops, root, levels, node)
	if r != .Good {
		return 0, r
	}
	total := u64(1)
	for child in node.children {
		total += child.blocks
	}
	return total, .Good
}

// drop_object_child_whole recursively decrements refcounts under an object
// node when its last reference is dropped.
@(private = "file")
drop_object_child_whole :: proc "contextless" (ops: ^Ops, work: ^Work, child: format.Object_Child, level: int) -> Read {
	ops.drop(ops, child.block)
	if level == 0 || ops.count_after(ops, child.block) != 0 || level > format.OBJECT_LEVEL_LIMIT {
		return .Good
	}
	node := &work.obj_nodes[level]
	switch read_object_node_keyless(ops, {block = child.block, check = child.check}, level, node) {
	case .Device:
		return .Device
	case .Wrong:
		ops.note_damaged(ops, 1, max(child.blocks, 1) - 1)
		return .Good
	case .Good:
	}
	for place in 0 ..< format.OBJECT_FANOUT {
		item := node.children[place]
		if item.block == 0 {
			continue
		}
		if drop_object_child_whole(ops, work, item, level - 1) == .Device {
			return .Device
		}
	}
	return .Good
}

// release_names_keyless counts how many refcount drops a state needs up to `limit`.
@(private = "file")
release_names_keyless :: proc "contextless" (ops: ^Ops, work: ^Work, child: format.Object_Child, level: int, names: ^int, limit: int) -> (within: bool, device: bool) {
	if level == 0 {
		names^ += 1
		return names^ <= limit, false
	}
	names^ += 1
	if names^ > limit {
		return false, false
	}
	if ops.count_after(ops, child.block) > 1 {
		return true, false
	}
	node := &work.obj_nodes[level]
	switch read_object_node_keyless(ops, {block = child.block, check = child.check}, level, node) {
	case .Device:
		return false, true
	case .Wrong:
		return true, false
	case .Good:
	}
	for place in 0 ..< format.OBJECT_FANOUT {
		item := node.children[place]
		if item.block == 0 {
			continue
		}
		if level == 1 {
			names^ += 1
			if names^ > limit {
				return false, false
			}
		} else {
			child_within, child_dev := release_names_keyless(ops, work, item, level - 1, names, limit)
			if child_dev {
				return false, true
			}
			if !child_within {
				return false, false
			}
		}
	}
	return true, false
}

// drop_object_state frees a state directly when it fits inside `work.direct_budget`,
// otherwise defers it to a clear Release_List through `ops.enqueue_release`.
@(private = "file")
drop_object_state :: proc "contextless" (ops: ^Ops, work: ^Work, root: format.Pointer, size: u64) -> Step_Outcome {
	if root.block == 0 {
		return .Progressed
	}
	if size > format.OBJECT_SIZE_LIMIT {
		ops.mark_wrong(ops, root.block)
		ops.drop(ops, root.block)
		ops.note_damaged(ops, 1, 0)
		return .Progressed
	}
	levels := format.object_levels(size)
	child := format.Object_Child{block = root.block, check = root.check}
	names := 0
	within, dev := release_names_keyless(ops, work, child, levels, &names, work.direct_budget)
	if dev {
		return .Device
	}
	if within {
		if drop_object_child_whole(ops, work, child, levels) == .Device {
			return .Device
		}
		work.direct_budget -= names
		return .Progressed
	}
	if !ops.enqueue_release(ops, root, size) {
		return .Full
	}
	return .Progressed
}

@(private = "file")
drop_object_entry :: proc "contextless" (ops: ^Ops, work: ^Work, entry: format.Entry, sb: ^format.Store_Block) -> Step_Outcome {
	held, held_read := object_state_held_blocks(ops, work, entry.pointer, entry.size)
	if held_read == .Device {
		return .Device
	}
	if res := drop_object_state(ops, work, entry.pointer, entry.size); res != .Progressed {
		return res
	}
	if entry.versions.block != 0 {
		if ops.wrong_block(ops, entry.versions.block) {
			ops.drop(ops, entry.versions.block)
			ops.note_damaged(ops, 1, 0)
		} else {
			switch ops.read_block(ops, entry.versions, (^Block)(&work.ver_index)) {
			case .Device:
				return .Device
			case .Wrong:
				ops.mark_wrong(ops, entry.versions.block)
				ops.drop(ops, entry.versions.block)
				ops.note_damaged(ops, 1, 0)
			case .Good:
				if work.ver_index.leaf_count > format.VERSION_INDEX_CAPACITY {
					ops.mark_wrong(ops, entry.versions.block)
					ops.drop(ops, entry.versions.block)
					ops.note_damaged(ops, 1, 0)
				} else {
					for leaf_ptr in work.ver_index.leaves[:work.ver_index.leaf_count] {
						if ops.wrong_block(ops, leaf_ptr.block) {
							ops.drop(ops, leaf_ptr.block)
							ops.note_damaged(ops, 1, 0)
							continue
						}
						switch ops.read_block(ops, leaf_ptr, (^Block)(&work.ver_leaf)) {
						case .Device:
							return .Device
						case .Wrong:
							ops.mark_wrong(ops, leaf_ptr.block)
							ops.drop(ops, leaf_ptr.block)
							ops.note_damaged(ops, 1, 0)
						case .Good:
							if work.ver_leaf.count == 0 || work.ver_leaf.count > format.VERSION_LEAF_CAPACITY {
								ops.mark_wrong(ops, leaf_ptr.block)
								ops.drop(ops, leaf_ptr.block)
								ops.note_damaged(ops, 1, 0)
								continue
							}
							for ver in work.ver_leaf.entries[:work.ver_leaf.count] {
								if vres := drop_object_state(ops, work, ver.root, ver.size); vres != .Progressed {
									return vres
								}
								work.versions_freed += 1
							}
							ops.drop(ops, leaf_ptr.block)
						}
					}
					ops.drop(ops, entry.versions.block)
				}
			}
		}
	}
	sb.objects = sb.objects > 0 ? sb.objects - 1 : 0
	sb.current_blocks = sb.current_blocks > held ? sb.current_blocks - held : 0
	return .Progressed
}

// ---------------------------------------------------------------------
// Step 1: Drain `sb.removals` (Release_List entries and queued Tree entries).

@(private = "file")
step_removals :: proc "contextless" (ops: ^Ops, work: ^Work, sb: ^format.Store_Block, limit: int) -> Step_Outcome {
	path := &work.paths[0]
	read := walk_leftmost(ops, sb.removals, path, &work.node_buf)
	if read == .Device {
		return .Device
	}
	if read == .Wrong {
		// Damaged node in removals queue: prune it and trigger recount.
		bad_idx := path.depth - 1
		ops.drop(ops, path.ptrs[bad_idx].block)
		node_blocks_sub(sb, 1)
		ops.note_damaged(ops, 1, 0)
		new_root, res := rewrite_leftmost_path(ops, work, path, bad_idx, true, {}, sb)
		if res != .Progressed {
			return res
		}
		sb.removals = new_root
		if new_root.block == 0 {
			sb.removing = 0
		}
		return .Progressed
	}

	leaf_idx := path.depth - 1
	queued := leaf_entry_at(&work.node_buf, 0)^
	kind, kind_ok := format.entry_kind_of_word(queued.kind)
	if !kind_ok || kind == .None || kind == .Object {
		// Corrupt queue entry: drop it so reclamation never stalls.
		ops.note_damaged(ops, 1, 0)
		ops.drop(ops, path.ptrs[leaf_idx].block)
		empty := leaf_pop_front(&work.node_buf)
		new_leaf: format.Pointer
		if empty {
			node_blocks_sub(sb, 1)
		} else {
			ok: bool
			new_leaf, ok = ops.write_block(ops, &work.node_buf)
			if !ok {
				return .Full
			}
		}
		new_root, res := rewrite_leftmost_path(ops, work, path, leaf_idx, empty, new_leaf, sb)
		if res != .Progressed {
			return res
		}
		sb.removals = new_root
		sb.removing = sb.removing > 0 ? sb.removing - 1 : 0
		return .Progressed
	}

	switch kind {
	case .Release:
		// Step the Release_List keylessly.
		list := &work.release_list
		rl_read: Read = .Good
		if ops.wrong_block(ops, queued.pointer.block) {
			rl_read = .Wrong
		} else {
			rl_read = ops.read_block(ops, queued.pointer, (^Block)(list))
		}
		if rl_read == .Device {
			return .Device
		}
		empty_entry := false
		if rl_read == .Wrong || !format.release_list_valid(list) {
			ops.mark_wrong(ops, queued.pointer.block)
			ops.drop(ops, queued.pointer.block)
			ops.note_damaged(ops, 1, 0)
			empty_entry = true
		} else {
			list_empty, dev := ops.release_step(ops, list)
			if dev {
				return .Device
			}
			ops.drop(ops, queued.pointer.block)
			if list_empty && list.next.block != 0 {
				leaf_entry_at(&work.node_buf, 0).pointer = list.next
				(^format.Tree_Header)(&work.node_buf).mac = {}
			} else if list_empty {
				empty_entry = true
			} else {
				list.mac = {}
				new_list_ptr, ok := ops.write_block(ops, (^Block)(list))
				if !ok {
					return .Full
				}
				leaf_entry_at(&work.node_buf, 0).pointer = new_list_ptr
				(^format.Tree_Header)(&work.node_buf).mac = {}
			}
		}
		ops.drop(ops, path.ptrs[leaf_idx].block)
		leaf_empty := false
		if empty_entry {
			leaf_empty = leaf_pop_front(&work.node_buf)
			sb.removing = sb.removing > 0 ? sb.removing - 1 : 0
		}
		new_leaf: format.Pointer
		if leaf_empty {
			node_blocks_sub(sb, 1)
		} else {
			ok: bool
			new_leaf, ok = ops.write_block(ops, &work.node_buf)
			if !ok {
				return .Full
			}
		}
		new_root, res := rewrite_leftmost_path(ops, work, path, leaf_idx, leaf_empty, new_leaf, sb)
		if res != .Progressed {
			return res
		}
		sb.removals = new_root
		return .Progressed

	case .Tree:
		if queued.pointer.block == 0 {
			ops.drop(ops, path.ptrs[leaf_idx].block)
			leaf_empty := leaf_pop_front(&work.node_buf)
			new_leaf: format.Pointer
			if leaf_empty {
				node_blocks_sub(sb, 1)
			} else {
				ok: bool
				new_leaf, ok = ops.write_block(ops, &work.node_buf)
				if !ok {
					return .Full
				}
			}
			new_root, res := rewrite_leftmost_path(ops, work, path, leaf_idx, leaf_empty, new_leaf, sb)
			if res != .Progressed {
				return res
			}
			sb.removals = new_root
			sb.removing = sb.removing > 0 ? sb.removing - 1 : 0
			sb.trees = sb.trees > 0 ? sb.trees - 1 : 0
			return .Progressed
		}
		// Peel entries from the queued tree; update its pointer (or pop when empty).
		child_root := queued.pointer
		res := step_tree_stack(ops, work, &child_root, sb, limit, true)
		if res != .Progressed && res != .Empty {
			return res
		}
		// Re-read the removals leftmost leaf because step_tree_stack used work.node_buf.
		leaf_ptr := path.ptrs[leaf_idx]
		r_leaf := read_tree_node(ops, leaf_ptr, 0, &work.node_buf)
		if r_leaf == .Device {
			return .Device
		}
		ops.drop(ops, leaf_ptr.block)
		leaf_empty := false
		if child_root.block == 0 {
			leaf_empty = leaf_pop_front(&work.node_buf)
			sb.removing = sb.removing > 0 ? sb.removing - 1 : 0
			sb.trees = sb.trees > 0 ? sb.trees - 1 : 0
		} else {
			entry := leaf_entry_at(&work.node_buf, 0)
			entry.pointer = child_root
			entry.size = entry.size > u64(work.entries_popped) ? entry.size - u64(work.entries_popped) : 0
			(^format.Tree_Header)(&work.node_buf).mac = {}
		}
		new_leaf: format.Pointer
		if leaf_empty {
			node_blocks_sub(sb, 1)
		} else {
			ok: bool
			new_leaf, ok = ops.write_block(ops, &work.node_buf)
			if !ok {
				return .Full
			}
		}
		new_root, r2 := rewrite_leftmost_path(ops, work, path, leaf_idx, leaf_empty, new_leaf, sb)
		if r2 != .Progressed {
			return r2
		}
		sb.removals = new_root
		return .Progressed

	case .None, .Object:
	}
	return .Progressed
}

// ---------------------------------------------------------------------
// Step 2: Peel entries from the deepest leftmost leaf of a tree (or nested trees).

@(private = "file")
step_tree_stack :: proc "contextless" (
	ops: ^Ops,
	work: ^Work,
	tree_root: ^format.Pointer,
	sb: ^format.Store_Block,
	limit: int,
	in_removals: bool,
) -> Step_Outcome {
	// Starting slot in work.paths: 1 when called under step_removals (which holds
	// the removals queue path in paths[0]), 0 when called for sb.tree.
	base_slot := in_removals ? 1 : 0
	nesting := 0
	cur_root := tree_root^

	// Descend into leftmost nested non-empty .Tree entries up to NESTING_LIMIT.
	for {
		path := &work.paths[base_slot + nesting]
		read := walk_leftmost(ops, cur_root, path, &work.node_buf)
		if read == .Device {
			return .Device
		}
		if read == .Wrong {
			// Prune damaged node at this nesting level and rewrite ancestors.
			bad_idx := path.depth - 1
			ops.drop(ops, path.ptrs[bad_idx].block)
			node_blocks_sub(sb, 1)
			ops.note_damaged(ops, 1, 0)
			new_sub, res := rewrite_leftmost_path(ops, work, path, bad_idx, true, {}, sb)
			if res != .Progressed {
				return res
			}
			return unwind_nesting(ops, work, base_slot, nesting, new_sub, 0, tree_root, sb)
		}

		// Inspect entry 0 of the leftmost leaf.
		first := leaf_entry_at(&work.node_buf, 0)^
		if first.kind == u64(format.Entry_Kind.Tree) && first.pointer.block != 0 && base_slot + nesting + 1 < len(work.paths) {
			cur_root = first.pointer
			nesting += 1
			continue
		}
		break
	}

	// Peel up to `limit` entries from the leftmost leaf at `base_slot + nesting`.
	path := &work.paths[base_slot + nesting]
	leaf_idx := path.depth - 1
	head := (^format.Tree_Header)(&work.node_buf)
	popped := 0
	leaf_empty := false

	peel: for popped < limit && !leaf_empty {
		entry := leaf_entry_at(&work.node_buf, 0)^
		kind, kind_ok := format.entry_kind_of_word(entry.kind)
		if !kind_ok || kind == .None || kind == .Release {
			ops.note_damaged(ops, 1, 0)
			leaf_empty = leaf_pop_front(&work.node_buf)
			popped += 1
			continue
		}
		switch kind {
		case .Tree:
			if entry.pointer.block != 0 {
				// Non-empty nested tree encountered after popping >=1 sibling entry:
				// stop this step so the next commit descends into it cleanly.
				if popped > 0 {
					break peel
				}
				// Reached nesting limit with non-empty subtree: prune safely.
				ops.note_damaged(ops, 1, 0)
				ops.drop(ops, entry.pointer.block)
			}
			sb.trees = sb.trees > 0 ? sb.trees - 1 : 0
			leaf_empty = leaf_pop_front(&work.node_buf)
			popped += 1
		case .Object:
			if popped > 0 && work.direct_budget <= 0 {
				break peel
			}
			res := drop_object_entry(ops, work, entry, sb)
			if res != .Progressed {
				return res
			}
			leaf_empty = leaf_pop_front(&work.node_buf)
			popped += 1
		case .None, .Release:
		}
		if head.count == 0 {
			leaf_empty = true
		}
	}

	work.entries_popped = popped
	ops.drop(ops, path.ptrs[leaf_idx].block)
	new_leaf: format.Pointer
	if leaf_empty {
		node_blocks_sub(sb, 1)
	} else {
		ok: bool
		new_leaf, ok = ops.write_block(ops, &work.node_buf)
		if !ok {
			return .Full
		}
	}
	new_sub, res := rewrite_leftmost_path(ops, work, path, leaf_idx, leaf_empty, new_leaf, sb)
	if res != .Progressed {
		return res
	}
	return unwind_nesting(ops, work, base_slot, nesting, new_sub, u64(popped), tree_root, sb)
}

// unwind_nesting propagates the updated child tree root back up through every
// enclosing nested `.Tree` entry (decrementing its `size` or popping it if
// empty!) up to `tree_root`.
@(private = "file")
unwind_nesting :: proc "contextless" (
	ops: ^Ops,
	work: ^Work,
	base_slot: int,
	nesting: int,
	child_root: format.Pointer,
	popped_in_child: u64,
	tree_root: ^format.Pointer,
	sb: ^format.Store_Block,
) -> Step_Outcome {
	cur := child_root
	popped := popped_in_child
	for level := nesting - 1; level >= 0; level -= 1 {
		parent_path := &work.paths[base_slot + level]
		leaf_idx := parent_path.depth - 1
		leaf_ptr := parent_path.ptrs[leaf_idx]
		r := read_tree_node(ops, leaf_ptr, 0, &work.node_buf)
		if r == .Device {
			return .Device
		}
		if r == .Wrong {
			ops.drop(ops, leaf_ptr.block)
			node_blocks_sub(sb, 1)
			ops.note_damaged(ops, 1, 0)
			new_p, res := rewrite_leftmost_path(ops, work, parent_path, leaf_idx, true, {}, sb)
			if res != .Progressed {
				return res
			}
			cur = new_p
			popped = 0
			continue
		}
		ops.drop(ops, leaf_ptr.block)
		leaf_empty := false
		parent_popped := u64(0)
		if cur.block == 0 {
			// Nested tree is now empty: pop its entry from parent leaf!
			leaf_empty = leaf_pop_front(&work.node_buf)
			sb.trees = sb.trees > 0 ? sb.trees - 1 : 0
			parent_popped = 1
		} else {
			entry := leaf_entry_at(&work.node_buf, 0)
			entry.pointer = cur
			entry.size = entry.size > popped ? entry.size - popped : 0
			(^format.Tree_Header)(&work.node_buf).mac = {}
		}
		new_leaf: format.Pointer
		if leaf_empty {
			node_blocks_sub(sb, 1)
		} else {
			ok: bool
			new_leaf, ok = ops.write_block(ops, &work.node_buf)
			if !ok {
				return .Full
			}
		}
		new_p, res := rewrite_leftmost_path(ops, work, parent_path, leaf_idx, leaf_empty, new_leaf, sb)
		if res != .Progressed {
			return res
		}
		cur = new_p
		popped = parent_popped
	}
	tree_root^ = cur
	work.entries_popped = int(popped)
	return .Progressed
}

// prepend_release_entry inserts a clear `.Release` entry into `sb.removals`
// without relying on sorted key comparisons (encrypted-layout safe).
prepend_release_entry :: proc "contextless" (ops: ^Ops, work: ^Work, sb: ^format.Store_Block, list_ptr: format.Pointer) -> Step_Outcome {
	number := sb.next_removal + 1
	sb.next_removal = number
	key := format.removal_name(number)
	entry := format.Entry{kind = u64(format.Entry_Kind.Release), pointer = list_ptr}

	if sb.removals.block == 0 {
		work.node_buf = {}
		head := (^format.Tree_Header)(&work.node_buf)
		head^ = {level = 0, count = 1, magic = format.NODE_MAGIC}
		copy(work.node_buf[format.TREE_HEADER_SIZE:][:format.ENTRY_NAME_STORAGE], key[:])
		leaf_entry_at(&work.node_buf, 0)^ = entry
		ptr, ok := ops.write_block(ops, &work.node_buf)
		if !ok {
			return .Full
		}
		sb.removals = ptr
		sb.node_blocks += 1
		sb.removing += 1
		return .Progressed
	}

	// Removals is non-empty (only happens when peeling a queued tree inside
	// removals hit a huge object): insert at index 0 of the leftmost leaf if it
	// has room, else wrap root in a 2-child branch with a fresh 1-entry leaf.
	path := &work.paths[0]
	read := walk_leftmost(ops, sb.removals, path, &work.node_buf)
	if read == .Device {
		return .Device
	}
	if read == .Good {
		head := (^format.Tree_Header)(&work.node_buf)
		if int(head.count) < format.LEAF_CAPACITY {
			stride := format.ENTRY_NAME_STORAGE + size_of(format.Entry)
			count := int(head.count)
			// Shift existing entries right by 1 slot.
			for i := count; i > 0; i -= 1 {
				copy(work.node_buf[format.TREE_HEADER_SIZE + i * stride:][:stride], work.node_buf[format.TREE_HEADER_SIZE + (i - 1) * stride:][:stride])
			}
			copy(work.node_buf[format.TREE_HEADER_SIZE:][:format.ENTRY_NAME_STORAGE], key[:])
			leaf_entry_at(&work.node_buf, 0)^ = entry
			head.count += 1
			head.mac = {}
			leaf_idx := path.depth - 1
			ops.drop(ops, path.ptrs[leaf_idx].block)
			new_leaf, ok := ops.write_block(ops, &work.node_buf)
			if !ok {
				return .Full
			}
			new_root, res := rewrite_leftmost_path(ops, work, path, leaf_idx, false, new_leaf, sb)
			if res != .Progressed {
				return res
			}
			sb.removals = new_root
			sb.removing += 1
			return .Progressed
		}
	}

	// Leftmost leaf is full: create a fresh leaf (and matching-height branch
	// spine if needed) and wrap under a new root branch.
	old_root_buf: Block
	r_root := read_tree_node(ops, sb.removals, -1, &old_root_buf)
	if r_root == .Device {
		return .Device
	}
	if r_root == .Wrong {
		return .Full
	}
	old_level := int((^format.Tree_Header)(&old_root_buf).level)
	if old_level + 1 >= format.TREE_DEPTH_LIMIT {
		return .Full
	}

	// Build a 1-entry leaf, then 1-child branches up to old_level.
	work.node_buf = {}
	(^format.Tree_Header)(&work.node_buf)^ = {level = 0, count = 1, magic = format.NODE_MAGIC}
	copy(work.node_buf[format.TREE_HEADER_SIZE:][:format.ENTRY_NAME_STORAGE], key[:])
	leaf_entry_at(&work.node_buf, 0)^ = entry
	left_ptr, ok := ops.write_block(ops, &work.node_buf)
	if !ok {
		return .Full
	}
	sb.node_blocks += 1
	for lvl := 1; lvl <= old_level; lvl += 1 {
		work.node_buf = {}
		(^format.Tree_Header)(&work.node_buf)^ = {level = u32(lvl), count = 1, magic = format.NODE_MAGIC}
		branch_child_at(&work.node_buf, 0)^ = left_ptr
		left_ptr, ok = ops.write_block(ops, &work.node_buf)
		if !ok {
			return .Full
		}
		sb.node_blocks += 1
	}

	work.node_buf = {}
	(^format.Tree_Header)(&work.node_buf)^ = {level = u32(old_level + 1), count = 2, magic = format.NODE_MAGIC}
	branch_child_at(&work.node_buf, 0)^ = left_ptr
	branch_child_at(&work.node_buf, 1)^ = sb.removals
	new_root, ok2 := ops.write_block(ops, &work.node_buf)
	if !ok2 {
		return .Full
	}
	sb.node_blocks += 1
	sb.removals = new_root
	sb.removing += 1
	return .Progressed
}
