package storage_mount

import "base:intrinsics"
import format "modus:contract/store"
import "internal:storage/block_counts"

// The repair of wrong leaves of the count tree (the form Count_Tree;
// src/md/data/storage_capacity.md, "The open has two forms"). It counts the
// names of the blocks of the wrong leaves only, by a walk of each store
// that resumes between steps: each step reads at most
// REPAIR_NODES_PER_STEP nodes, and the walk keeps, for each tree on its
// path, the name of the tree in its parent and the name of its last entry.
// At each step it finds the roots again from the store: a commit between
// two steps changes no name of a block of a wrong leaf (a commit that would
// is refused), and no entry moves to another tree (a rename and the remove
// of a tree are refused while a repair runs), so the names that the walk
// counts are those of one state of the disk.

// The nodes that one step of a repair reads at most, between two entries:
// the walk of the state of one entry is not cut.
REPAIR_NODES_PER_STEP :: 4096

// The blocks of the wrong leaves that a repair counts at most: the nodes of
// the trees among them are counted once, in a set of this many places.
REPAIR_SEEN_SLOTS :: 2 * block_counts.WRONG_LEAVES_MOST * format.COUNTS_OF_A_PAGE

// One tree on the path of the walk of a repair.
Repair_Frame :: struct {
	name:       format.Entry_Name, // The name of the tree in its parent: not used for the tree of the store.
	cursor:     format.Entry_Name, // The name of the last entry that the walk counted.
	has_cursor: bool,
}

// Why a repair stopped before its end.
Repair_Stop :: enum u8 {
	None    = 0,
	Device  = 1, // A read failed on the device.
	Damaged = 2, // A node of a tree has a wrong check, or a path of the walk is gone.
	Bound   = 3, // The walk read more nodes than the disk has blocks, or its set of shared nodes is full.
}

// The roots of a store as the last commit left them: the service gives
// them, as the state of the open does not follow the commits.
Store_Roots :: #type proc "contextless" (state: ^State, store_index: int) -> (tree: format.Pointer, removals: format.Pointer)

// repair_running says if a repair is in progress: a rename and the remove
// of a tree wait for its end.
repair_running :: proc "contextless" (state: ^State) -> bool {
	return state.repairing
}

// repair_in_range says if a block is in a leaf that the repair counts.
@(private)
repair_in_range :: proc "contextless" (state: ^State, number: u64) -> bool {
	first := number - number % format.COUNTS_OF_A_PAGE
	for &leaf in state.repair_leaves[:state.repair_count] {
		if leaf.first == first {
			return true
		}
	}
	return false
}

// repair_node_first says if the walk of a repair reads a node for the first
// time, and so counts the names under it. A node of one name (its count in
// the count tree) has one parent: the walk meets it once, and keeps no
// record of it. A node of more names, or in a wrong leaf, is kept in the
// set of the visited nodes; a full set stops the repair.
repair_node_first :: proc "contextless" (state: ^State, number: u64) -> bool {
	state.node_reads += 1
	state.repair_step_reads += 1
	if state.node_reads > state.disk_size {
		repair_stop(state, .Bound)
		return false
	}
	if !repair_in_range(state, number) && block_count(state, number) <= 1 {
		return true
	}
	if block_set_has(state.visited, number) {
		return false
	}
	if 2 * (state.visited_count + 1) > u64(len(state.visited)) {
		repair_stop(state, .Bound)
		return false
	}
	mask := u64(len(state.visited) - 1)
	at := (number * 0x9E37_79B9_7F4A_7C15 >> 20) & mask
	for state.visited[at] != 0 {
		at = (at + 1) & mask
	}
	state.visited[at] = number
	state.visited_count += 1
	return true
}

@(private)
repair_stop :: proc "contextless" (state: ^State, why: Repair_Stop) {
	if state.repair_stop == .None {
		state.repair_stop = why
	}
}

// repair_tree_node counts the one name of a node of a tree of a store when
// it is in a wrong leaf, once for the whole repair.
@(private)
repair_tree_node :: proc "contextless" (state: ^State, number: u64, store_index: int) {
	if !repair_in_range(state, number) {
		return
	}
	mask := u64(REPAIR_SEEN_SLOTS - 1)
	at := (number * 0x9E37_79B9_7F4A_7C15 >> 20) & mask
	for state.repair_seen[at] != 0 {
		if state.repair_seen[at] == number {
			return
		}
		at = (at + 1) & mask
	}
	state.repair_seen[at] = number
	repair_name(state, number, u16(store_index + 1))
}

// repair_node_read reads a node of a tree with its checks into the node of
// a level of the walk.
@(private)
repair_node_read :: proc "contextless" (state: ^State, reader: ^Block_Reader, pointer: format.Pointer, into: ^[BLOCK_SIZE]u8) -> bool {
	_, outcome := read_checked(state, reader, {pointer}, 0)
	switch outcome {
	case .Good:
	case .Device:
		repair_stop(state, .Device)
		return false
	case .Wrong:
		repair_stop(state, .Damaged)
		return false
	}
	intrinsics.mem_copy_non_overlapping(into, raw_data(scratch_block(state, 0)), BLOCK_SIZE)
	header := (^format.Tree_Header)(into)
	if header.magic != format.NODE_MAGIC || header.level > format.TREE_DEPTH_LIMIT {
		repair_stop(state, .Damaged)
		return false
	}
	state.node_reads += 1
	state.repair_step_reads += 1
	return true
}

@(private)
LEAF_RECORD_SIZE :: size_of(format.Entry_Name) + size_of(format.Entry)
@(private)
BRANCH_RECORD_SIZE :: size_of(format.Entry_Name) + size_of(format.Pointer)

@(private)
name_compare :: proc "contextless" (left, right: ^format.Entry_Name) -> int {
	for index in 0 ..< len(left) {
		if left[index] != right[index] {
			return left[index] < right[index] ? -1 : 1
		}
	}
	return 0
}

// repair_next finds the first entry of a tree after a name (or the first
// entry), and counts the nodes of the tree on its way that are in a wrong
// leaf. found is false at the end of the tree.
@(private)
repair_next :: proc "contextless" (state: ^State, reader: ^Block_Reader, pointer: format.Pointer, level: int, cursor: ^format.Entry_Name, has_cursor: bool, store_index: int, key: ^format.Entry_Name, entry: ^format.Entry) -> (found: bool) {
	if pointer.block == 0 || level > format.TREE_DEPTH_LIMIT {
		return false
	}
	node := &state.repair_nodes[level]
	if !repair_node_read(state, reader, pointer, node) {
		return false
	}
	repair_tree_node(state, pointer.block, store_index)
	header := (^format.Tree_Header)(node)
	if header.level == 0 {
		count := min(int(header.count), format.LEAF_CAPACITY)
		for place in 0 ..< count {
			record := node[format.TREE_HEADER_SIZE + place * LEAF_RECORD_SIZE:]
			name := (^format.Entry_Name)(raw_data(record))
			if !has_cursor || name_compare(name, cursor) > 0 {
				key^ = name^
				intrinsics.mem_copy_non_overlapping(entry, &record[size_of(format.Entry_Name)], size_of(format.Entry))
				return true
			}
		}
		return false
	}
	count := min(int(header.count), format.BRANCH_CAPACITY)
	// The child of the cursor: the last whose name (from record 1) is at
	// most the cursor; then the children after it.
	first_child := 0
	if has_cursor {
		for place in 1 ..< count {
			name := (^format.Entry_Name)(&node[format.TREE_HEADER_SIZE + place * BRANCH_RECORD_SIZE])
			if name_compare(name, cursor) <= 0 {
				first_child = place
			}
		}
	}
	for place in first_child ..< count {
		// A deeper call reads into the node of its own level.
		child := (^format.Pointer)(&state.repair_nodes[level][format.TREE_HEADER_SIZE + place * BRANCH_RECORD_SIZE + size_of(format.Entry_Name)])^
		if repair_next(state, reader, child, level + 1, cursor, has_cursor, store_index, key, entry) {
			return true
		}
		if state.repair_stop != .None {
			return false
		}
	}
	return false
}

// repair_lookup gives the entry of a name in a tree, by repair_next.
@(private)
repair_lookup :: proc "contextless" (state: ^State, reader: ^Block_Reader, root: format.Pointer, name: ^format.Entry_Name, store_index: int) -> (entry: format.Entry, found: bool) {
	// The entry after the name just before: the name itself when it is there.
	before := name^
	borrow := true
	for index := len(before) - 1; index >= 0 && borrow; index -= 1 {
		borrow = before[index] == 0
		before[index] -= 1
	}
	key: format.Entry_Name
	if !repair_next(state, reader, root, 0, &before, !borrow, store_index, &key, &entry) || key != name^ {
		return {}, false
	}
	return entry, true
}

// repair_entry counts the names of the blocks of the wrong leaves under one
// entry: the state of an object and its versions, the list of a release.
// A tree goes on the path of the walk.
@(private)
repair_entry :: proc "contextless" (state: ^State, reader: ^Block_Reader, key: ^format.Entry_Name, entry: ^format.Entry, store_index: int, queued: bool) {
	result := &state.repair_result
	named: u64
	kind, ok := format.entry_kind_of_word(entry.kind)
	if !ok {
		return
	}
	owner := u16(store_index + 1)
	switch kind {
	case .None:
	case .Object:
		if read, _ := reference_state(state, reader, entry.pointer, entry.size, store_index, result, &named); read == .Device {
			repair_stop(state, .Device)
			return
		}
		if entry.versions.block == 0 {
			return
		}
		repair_name(state, entry.versions.block, owner)
		if _, outcome := read_checked(state, reader, {entry.versions}, 0); outcome != .Good {
			if outcome == .Device {
				repair_stop(state, .Device)
			}
			return
		}
		index := (^format.Version_Index)(raw_data(scratch_block(state, 0)))^
		for leaf_pointer in index.leaves[:min(index.leaf_count, format.VERSION_INDEX_CAPACITY)] {
			repair_name(state, leaf_pointer.block, owner)
			if _, outcome := read_checked(state, reader, {leaf_pointer}, 0); outcome != .Good {
				if outcome == .Device {
					repair_stop(state, .Device)
				}
				continue
			}
			leaf := (^format.Version_Leaf)(raw_data(scratch_block(state, 0)))^
			for version in leaf.entries[:min(leaf.count, format.VERSION_LEAF_CAPACITY)] {
				if read, _ := reference_state(state, reader, version.root, version.size, store_index, result, &named); read == .Device {
					repair_stop(state, .Device)
					return
				}
			}
		}
	case .Tree:
		if entry.pointer.block == 0 {
			return
		}
		if state.repair_depth >= format.NESTING_LIMIT {
			repair_stop(state, .Damaged)
			return
		}
		state.repair_depth += 1
		state.repair_frames[state.repair_depth] = {name = key^}
	case .Release:
		if !queued {
			return
		}
		repair_name(state, entry.pointer.block, owner)
		if _, outcome := read_checked(state, reader, {entry.pointer}, 0); outcome != .Good {
			if outcome == .Device {
				repair_stop(state, .Device)
			}
			return
		}
		list := (^format.Release_List)(raw_data(scratch_block(state, 0)))^
		if !format.release_list_valid(&list) {
			return
		}
		for released in list.states[:list.count] {
			if reference_release(state, reader, released.root, released.size, released.cursor, store_index, result, &named) == .Device {
				repair_stop(state, .Device)
				return
			}
		}
	}
}

// repair_store_walk walks the store of the repair from where the step
// before stopped, up to the bound of a step. It gives true when the store
// is done.
@(private)
repair_store_walk :: proc "contextless" (state: ^State, reader: ^Block_Reader, roots: Store_Roots) -> bool {
	index := state.repair_store
	for state.repair_stop == .None {
		if state.repair_step_reads >= state.repair_nodes_per_step {
			return false
		}
		tree_root, removals_root := roots(state, index)
		root := state.repair_which == 0 ? tree_root : removals_root
		// The root of the tree on the path: found again by its names.
		for depth in 1 ..= state.repair_depth {
			entry, found := repair_lookup(state, reader, root, &state.repair_frames[depth].name, index)
			if !found || entry.kind != u64(format.Entry_Kind.Tree) {
				repair_stop(state, .Damaged)
				return false
			}
			root = entry.pointer
		}
		frame := &state.repair_frames[state.repair_depth]
		key: format.Entry_Name
		entry: format.Entry
		if repair_next(state, reader, root, 0, &frame.cursor, frame.has_cursor, index, &key, &entry) {
			frame.cursor = key
			frame.has_cursor = true
			repair_entry(state, reader, &key, &entry, index, state.repair_which == 1 && state.repair_depth == 0)
			continue
		}
		if state.repair_stop != .None {
			return false
		}
		// The tree is done: back to its parent, or the removal queue, or
		// the next store.
		if state.repair_depth > 0 {
			state.repair_depth -= 1
		} else if state.repair_which == 0 {
			state.repair_which = 1
			state.repair_frames[0] = {}
		} else {
			return true
		}
	}
	return false
}

// repair_step runs one step of the repair of the wrong leaves of the count
// tree: at its first step it takes the wrong leaves; each step walks the
// stores from where the step before stopped, up to REPAIR_NODES_PER_STEP
// nodes; after the last store it counts the pages of the store table and of
// the count tree, and gives the leaves to the counts, which a commit then
// writes. A repair that stops (Repair_Stop) does not start again until the
// next open: its leaves stay wrong, and the service makes no change that
// needs them. It gives the reason of a stop, or None.
repair_step :: proc "contextless" (state: ^State, reader: ^Block_Reader, roots: Store_Roots) -> Repair_Stop {
	if state.repair_off {
		return .None
	}
	if !state.repairing {
		state.repair_count = state.counts.wrong_leaf_count
		for index in 0 ..< state.repair_count {
			state.repair_leaves[index] = {first = state.counts.wrong_leaves[index]}
		}
		state.repair_store = -1
		state.repair_stop = .None
		state.repair_seen = {}
		visited_clear(state)
		state.repairing = true
	}
	state.repair_step_reads = 0
	for {
		if state.repair_store >= 0 && state.repair_store < store_numbers(state) {
			if !repair_store_walk(state, reader, roots) {
				break
			}
		}
		// The next listed store.
		state.repair_store += 1
		for state.repair_store < store_numbers(state) {
			page, _ := format.store_place(state.repair_store)
			if !state.store_page_damaged[page] && store_cell(state, state.repair_store).name[0] != 0 {
				break
			}
			state.repair_store += 1
		}
		if state.repair_store >= store_numbers(state) {
			repair_finish(state)
			return state.repair_stop
		}
		state.repair_which, state.repair_depth = 0, 0
		state.repair_frames[0] = {}
		cell := store_cell(state, state.repair_store)
		repair_name(state, cell.store.block, u16(state.repair_store + 1))
		if state.repair_step_reads >= state.repair_nodes_per_step {
			return .None
		}
	}
	if state.repair_stop != .None {
		state.repairing = false
		state.repair_off = true
		state.repair_failed_store = state.repair_store
		return state.repair_stop
	}
	return .None
}

// repair_finish counts the pages that the root names, each one name, and
// gives the counted leaves to the counts.
@(private)
repair_finish :: proc "contextless" (state: ^State) {
	for pointer in state.root.store_pages[:min(state.root.store_page_count, format.STORE_PAGE_CAPACITY)] {
		repair_name(state, pointer.block, STORE_TABLE_OWNER)
	}
	if repair_count_pages(state, state.counts.levels, 0) == .Device {
		repair_stop(state, .Device)
		state.repairing = false
		state.repair_off = true
		return
	}
	state.repairing = false
	state.counts.repaired = state.repair_leaves[:state.repair_count]
}
