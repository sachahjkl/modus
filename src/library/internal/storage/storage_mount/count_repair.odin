package storage_mount

import "base:intrinsics"
import format "modus:contract/store"
import "internal:storage/block_counts"
import block_tree "internal:storage/storage_object"

// The repair of the wrong leaves of the count tree (the form Count_Tree;
// src/md/data/storage_capacity.md, "The repair state"). While it runs, the
// service makes no change and no commit, so the trees do not change
// between two steps. Each step reads at most REPAIR_NODES_PER_STEP nodes,
// and the walk resumes where the step before stopped: by its path in the
// trees of the store, by its place in the entry (the current
// state, a version, a state of a release list), and by the first block of
// data of the state that it did not count yet. It counts the names of the
// blocks of the wrong leaves only, in memory, and records each node that
// it walked in a scratch of its own on free blocks of the disk, so a node
// that several states name is walked once, and no set fills. When the walk
// ends, the service writes the counted leaves in one commit.

// The leaves that one run of a repair counts: the leaves of one wrong
// directory of level 1. More wrong leaves wait for the next run.
REPAIR_LEAVES_MOST :: format.COUNT_DIRECTORY_FANOUT

// The reads and the writes that one step of a repair makes at most: nodes
// of trees and of objects, versions, lists, and pages of the scratch.
REPAIR_NODES_PER_STEP :: 4096

// What the service gives to a repair: the state of the last commit, never
// the root that the open read, and the writes of the scratch.
Repair_Disk :: struct {
	root:          ^format.Root, // The root of the last commit.
	heads:         []Store_Head, // The head of each store as the last commit left it.
	// write writes one block of the scratch in place, with no flush: no
	// root names the scratch. false: the device reported an error.
	write:         proc "contextless" (disk: ^Repair_Disk, number: u64, bytes: ^[BLOCK_SIZE]u8) -> bool,
	// store_damaged says that a tree of a store has a wrong node: the
	// blocks under it are not counted, and the store takes no change.
	store_damaged: proc "contextless" (disk: ^Repair_Disk, store_index: int),
	nonce:         u64, // Differs at each start of the service: a page of the scratch of another run is not taken for one of this run.
	data:          rawptr,
}

// How a step of a repair ended.
Repair_Outcome :: enum u8 {
	Running = 0, // The walk goes on at the next step.
	Done    = 1, // The walk ended: counts.repaired holds the leaves, which one commit writes.
	Device  = 2, // A read or a write of the device failed: the walk starts again after the next call.
	No_Room = 3, // The disk has no free block for the scratch: the walk starts again after the next commit.
}

// Where the walk is in the entry that it counts.
Repair_Phase :: enum u8 {
	Current       = 0, // The current state of an object.
	Version_Index = 1, // The version index of an object.
	Version_Leaf  = 2, // The next leaf of the version index.
	Version       = 3, // The next version of the leaf.
	Release_List  = 4, // The next list of a release.
	Release_State = 5, // The next state of the list.
}

// One node on the path of the walk in a tree, and the next of its records
// that the walk takes.
Repair_Level :: struct {
	pointer: format.Pointer,
	place:   int,
}

// One tree on the path of the walk: the path from its root to the node of
// its next entry. Only the tree on top has its nodes in memory
// (repair.nodes); a tree under it reads its path again when the walk comes
// back to it.
Repair_Frame :: struct {
	root:   format.Pointer,
	levels: int, // The nodes of the path: 0 before the root is read, and at the end.
	done:   bool, // The walk of the tree ended.
	path:   [format.TREE_DEPTH_LIMIT + 1]Repair_Level,
}

// The state of an object that the walk counts.
Repair_Object :: struct {
	root:   format.Pointer,
	size:   u64,
	start:  u64, // The cursor of a release: the blocks of data before it hold no name of the state.
	resume: u64, // The first block of data that the walk did not count yet.
	set:    bool, // The walk of this state is in progress.
	begun:  bool, // Its root is counted.
}

// A page of the scratch: a page of bits, one for each block (level 0), or
// a directory of the blocks of the pages under it. The header names the
// run, so a block that the device did not write is not taken for a page.
SCRATCH_PAGE_MAGIC :: u32(0x50524353) // The bytes "SCRP".
Scratch_Header :: struct {
	magic: u32,
	level: u32,
	index: u64,
	nonce: u64,
	run:   u64,
}
SCRATCH_WORDS :: (BLOCK_SIZE - size_of(Scratch_Header)) / size_of(u64)
SCRATCH_BITS_OF_A_PAGE :: SCRATCH_WORDS * 64
Scratch_Page :: struct {
	header: Scratch_Header,
	words:  [SCRATCH_WORDS]u64,
}
#assert(size_of(Scratch_Page) == BLOCK_SIZE)

// The pages of the scratch in memory. The directory of the highest level
// is in memory too: 508^5 pages of 32 512 bits pass DISK_BLOCKS_MAX, so the
// largest disk has four levels of directories on the disk.
SCRATCH_FRAMES :: 32

Scratch_Frame :: struct {
	page:       Scratch_Page,
	block:      u64,
	used:       bool,
	dirty:      bool,
	referenced: bool,
}

// The shape of the scratch: the bits of a page, the children of a
// directory, the pages in memory. A zero field takes the size of the
// format; a host test takes smaller ones, so that a small disk has
// several pages and levels, and pages leave the memory.
Scratch_Shape :: struct {
	page_bits:   u64, // At most SCRATCH_BITS_OF_A_PAGE.
	children:    u64, // At most SCRATCH_WORDS.
	frame_count: int, // At most SCRATCH_FRAMES.
}

// The scratch of a repair: the bits of the nodes that it walked.
Scratch :: struct {
	shape:      Scratch_Shape, // The shape of this run: each field at most the size of the format.
	levels:     int,
	top:        [SCRATCH_WORDS]u64, // The blocks of the pages of the highest level.
	frames:     [SCRATCH_FRAMES]Scratch_Frame,
	hand:       int,
	next_block: u64, // The scratch takes free blocks in their order, so never one twice.
	in_memory:  bool, // Each page of the scratch fits in its frames: no page goes to the disk, and no block is taken.
	run:        u64, // The runs of the repair since the open: a page of a run before is not taken.
}

// The state of a repair.
Repair :: struct {
	running:        bool,
	wait_for_call:  bool, // A step failed on the device: the next one waits for a call.
	no_room:        bool, // The scratch found no free block: the repair waits for a commit.
	leaf_count:     int,
	leaves:         [REPAIR_LEAVES_MOST]block_counts.Repaired_Leaf, // In the order of their first block.
	store:          int, // The store that the walk is in: -1 before the first.
	stores_walked:  u64,
	stores_total:   u64,
	in_removals:    bool, // The walk is in the removal queue of the store.
	depth:          int,
	frames:         [format.NESTING_LIMIT + 1]Repair_Frame,
	nodes:          [format.TREE_DEPTH_LIMIT + 1][BLOCK_SIZE]u8, // The nodes of the path of the tree on top.
	loaded:         bool, // nodes holds the path of the tree on top.
	entry_active:   bool,
	entry:          format.Entry,
	phase:          Repair_Phase,
	object:         Repair_Object,
	version_index:  format.Version_Index,
	version_leaf:   format.Version_Leaf,
	leaf_index:     int,
	place:          int,
	list:           format.Release_List,
	list_next:      format.Pointer,
	lists:          u64, // The lists of the release that the walk read: a loop of lists ends at the blocks of the disk.
	store_failed:   bool, // A tree of the store has a wrong node: the walk of the store ends.
	failure:        Repair_Outcome,
	step_reads:     int, // The reads and the writes of the step: nodes, lists, versions and pages of the scratch.
	reads:          u64, // The reads and the writes of the run: a measure.
	nodes_per_step: int, // REPAIR_NODES_PER_STEP; a host test takes a smaller one.
	shape:          Scratch_Shape, // The shape of the scratch of the next run.
	scratch:        Scratch,
}

// repair_active says if the service is in the repair state: it makes no
// change until the commit of the repaired leaves.
repair_active :: proc "contextless" (state: ^State) -> bool {
	if state.form != .Count_Tree || state.repair.no_room {
		return false
	}
	return state.repair.running || len(state.counts.repaired) != 0 || state.counts.wrong_leaf_count > 0
}

// repair_waits says if a step of a repair waits: a walk in progress, or
// wrong leaves that no walk counted yet.
repair_waits :: proc "contextless" (state: ^State) -> bool {
	if !repair_active(state) || state.repair.wait_for_call {
		return false
	}
	return state.repair.running || len(state.counts.repaired) == 0
}

// repair_progress gives the stores that the walk ended and the stores in all.
repair_progress :: proc "contextless" (state: ^State) -> (walked: u64, total: u64) {
	return state.repair.stores_walked, state.repair.stores_total
}

// repair_call_came says that a call came: a repair that failed on the
// device tries again.
repair_call_came :: proc "contextless" (state: ^State) {
	state.repair.wait_for_call = false
}

// repair_commit_came says that a commit came: a repair that found no room
// for its scratch tries again.
repair_commit_came :: proc "contextless" (state: ^State) {
	state.repair.no_room = false
}

// repair_name counts one name of a block if it is in a leaf that the
// repair counts again.
repair_name :: proc "contextless" (state: ^State, number: u64, owner: u16) {
	first := number - number % format.COUNTS_OF_A_PAGE
	if leaf := block_counts.repaired_find(state.repair.leaves[:state.repair.leaf_count], first); leaf != nil {
		place := number - first
		if u64(leaf.counts[place]) < REFERENCE_LIMIT {
			leaf.counts[place] += 1
		}
		leaf.owners[place] = owner
	}
}

// repair_in_range says if a block is in a leaf that the repair counts.
@(private)
repair_in_range :: proc "contextless" (state: ^State, number: u64) -> bool {
	first := number - number % format.COUNTS_OF_A_PAGE
	return block_counts.repaired_find(state.repair.leaves[:state.repair.leaf_count], first) != nil
}

@(private)
repair_fail :: proc "contextless" (state: ^State, why: Repair_Outcome) {
	if state.repair.failure == .Running {
		state.repair.failure = why
	}
}

// scratch_reset empties the scratch for a new run: the pages of the run
// before are not read again.
@(private)
scratch_reset :: proc "contextless" (state: ^State) {
	scratch := &state.repair.scratch
	shape := state.repair.shape
	scratch.shape = {
		page_bits   = shape.page_bits == 0 ? SCRATCH_BITS_OF_A_PAGE : clamp(shape.page_bits, 1, SCRATCH_BITS_OF_A_PAGE),
		children    = shape.children == 0 ? SCRATCH_WORDS : clamp(shape.children, 2, SCRATCH_WORDS),
		frame_count = shape.frame_count == 0 ? SCRATCH_FRAMES : clamp(shape.frame_count, 1, SCRATCH_FRAMES),
	}
	pages := (state.disk_size + scratch.shape.page_bits - 1) / scratch.shape.page_bits
	scratch.levels = 0
	all_pages := pages
	for cover := scratch.shape.children; cover < pages; cover *= scratch.shape.children {
		scratch.levels += 1
		all_pages += (pages + cover - 1) / cover
	}
	// A small disk keeps its scratch in memory: a repair whose wrong leaves
	// cover the whole disk knows no free block for it.
	scratch.in_memory = all_pages <= u64(scratch.shape.frame_count)
	scratch.top = {}
	for &frame in scratch.frames {
		frame.used = false
	}
	scratch.hand = 0
	scratch.next_block = 2
	scratch.run += 1
}

// scratch_take gives a free block to a new page of the scratch, after each
// block that it took before, or 0.
@(private)
scratch_take :: proc "contextless" (state: ^State) -> u64 {
	scratch := &state.repair.scratch
	// No plan runs during a repair: a failure of a read of the count tree is
	// the failure of this search.
	block_counts.counts_failure_clear(&state.counts)
	number := block_counts.free_search(&state.counts, scratch.next_block, nil, nil)
	if state.counts.failure == .Device {
		repair_fail(state, .Device)
		return 0
	}
	if number == 0 || number < scratch.next_block {
		repair_fail(state, .No_Room)
		return 0
	}
	scratch.next_block = number + 1
	return number
}

// scratch_evict gives a frame for a new page: a dirty page goes to its block.
@(private)
scratch_evict :: proc "contextless" (state: ^State, disk: ^Repair_Disk) -> int {
	scratch := &state.repair.scratch
	for _ in 0 ..< 2 * scratch.shape.frame_count + 1 {
		index := scratch.hand
		scratch.hand = (scratch.hand + 1) % scratch.shape.frame_count
		frame := &scratch.frames[index]
		if !frame.used {
			return index
		}
		if frame.referenced {
			frame.referenced = false
			continue
		}
		if frame.dirty {
			state.repair.step_reads += 1
			state.repair.reads += 1
			if !disk.write(disk, frame.block, (^[BLOCK_SIZE]u8)(&frame.page)) {
				repair_fail(state, .Device)
				return -1
			}
		}
		frame.used = false
		return index
	}
	return -1
}

// scratch_frame gives the page of a level and an index, read or made.
@(private)
scratch_frame :: proc "contextless" (state: ^State, reader: ^Block_Reader, disk: ^Repair_Disk, level: int, index: u64) -> ^Scratch_Frame {
	scratch := &state.repair.scratch
	for &frame in scratch.frames[:scratch.shape.frame_count] {
		if frame.used && int(frame.page.header.level) == level && frame.page.header.index == index {
			frame.referenced = true
			return &frame
		}
	}
	// The place of its block in its parent. The parent can leave the memory
	// when the page takes a frame: the place is written first, and the
	// parent is dirty.
	block: u64
	fresh := false
	if level >= scratch.levels {
		if index >= scratch.shape.children {
			repair_fail(state, .Device)
			return nil
		}
		block = scratch.top[index]
		if scratch.in_memory {
			fresh = true
		} else if block == 0 {
			block = scratch_take(state)
			if block == 0 {
				return nil
			}
			scratch.top[index] = block
			fresh = true
		}
	} else {
		parent := scratch_frame(state, reader, disk, level + 1, index / scratch.shape.children)
		if parent == nil {
			return nil
		}
		slot := &parent.page.words[index % scratch.shape.children]
		block = slot^
		if scratch.in_memory {
			fresh = true
		} else if block == 0 {
			block = scratch_take(state)
			if block == 0 {
				return nil
			}
			slot^ = block
			parent.dirty = true
			fresh = true
		}
	}
	at := scratch_evict(state, disk)
	if at < 0 {
		repair_fail(state, .Device)
		return nil
	}
	frame := &scratch.frames[at]
	header := Scratch_Header{magic = SCRATCH_PAGE_MAGIC, level = u32(level), index = index, nonce = disk.nonce, run = scratch.run}
	if fresh {
		frame.page = {header = header}
	} else {
		numbers := [1]u64{block}
		state.repair.step_reads += 1
		state.repair.reads += 1
		if !reader.read(reader, numbers[:], ([^]u8)(&frame.page)[:BLOCK_SIZE]) {
			repair_fail(state, .Device)
			return nil
		}
		// A page that the device did not keep: the bits are not known.
		if frame.page.header != header {
			repair_fail(state, .Device)
			return nil
		}
	}
	frame.block = block
	frame.used, frame.dirty, frame.referenced = true, fresh, true
	return frame
}

// repair_first records a node that the walk walks, and says if it is the
// first time.
@(private)
repair_first :: proc "contextless" (state: ^State, reader: ^Block_Reader, disk: ^Repair_Disk, number: u64) -> bool {
	bits := state.repair.scratch.shape.page_bits
	frame := scratch_frame(state, reader, disk, 0, number / bits)
	if frame == nil {
		return false
	}
	bit := number % bits
	word := &frame.page.words[bit / 64]
	if word^ >> (bit % 64) & 1 != 0 {
		return false
	}
	word^ |= 1 << (bit % 64)
	frame.dirty = true
	return true
}

// repair_read reads a block with its check into a record of the repair.
@(private)
repair_read :: proc "contextless" (state: ^State, reader: ^Block_Reader, pointer: format.Pointer, into: rawptr) -> Read {
	state.repair.step_reads += 1
	state.repair.reads += 1
	_, outcome := read_checked(state, reader, {pointer}, 0)
	switch outcome {
	case .Good:
		intrinsics.mem_copy_non_overlapping(into, raw_data(scratch_block(state, 0)), BLOCK_SIZE)
	case .Device:
		repair_fail(state, .Device)
	case .Wrong:
	}
	return outcome
}

@(private)
LEAF_RECORD_SIZE :: size_of(format.Entry_Name) + size_of(format.Entry)
@(private)
BRANCH_RECORD_SIZE :: size_of(format.Entry_Name) + size_of(format.Pointer)

// repair_tree_node_take counts the one name of a node of a tree, and says
// if the walk walks it: a node that the walk took before (a tree named two
// times, a fault of the engine) is not walked again, so a store whose trees
// name one tree again and again ends its walk.
@(private)
repair_tree_node_take :: proc "contextless" (state: ^State, reader: ^Block_Reader, disk: ^Repair_Disk, pointer: format.Pointer) -> bool {
	repair := &state.repair
	if pointer.block == 0 {
		return false
	}
	if pointer.block < 2 || pointer.block >= state.disk_size {
		repair.store_failed = true
		return false
	}
	repair_name(state, pointer.block, u16(repair.store + 1))
	return repair_first(state, reader, disk, pointer.block)
}

// repair_tree_read reads a node of a tree into the node of its level of the
// path, with its check and its form: a node under a branch has the level
// below it. A wrong node ends the walk of the store.
@(private)
repair_tree_read :: proc "contextless" (state: ^State, reader: ^Block_Reader, level: int, pointer: format.Pointer) -> bool {
	repair := &state.repair
	node := &repair.nodes[level]
	switch repair_read(state, reader, pointer, node) {
	case .Good:
	case .Device:
		return false
	case .Wrong:
		repair.store_failed = true
		return false
	}
	header := (^format.Tree_Header)(node)
	if header.magic != format.NODE_MAGIC || header.level > format.TREE_DEPTH_LIMIT {
		repair.store_failed = true
		return false
	}
	if level > 0 && u32(header.level) + 1 != u32((^format.Tree_Header)(&repair.nodes[level - 1]).level) {
		repair.store_failed = true
		return false
	}
	return true
}

// repair_tree_start puts the root of a tree of a store on the path: the
// store block names it.
@(private)
repair_tree_start :: proc "contextless" (state: ^State, reader: ^Block_Reader, disk: ^Repair_Disk, root: format.Pointer) {
	repair := &state.repair
	repair.depth = 0
	repair.frames[0] = {}
	repair.loaded = false
	if repair_tree_node_take(state, reader, disk, root) {
		repair.frames[0].root = root
	}
}

// repair_tree_next gives the next entry of the tree on top of the path. The
// path of the last entry stays, so the entries of one leaf cost one read,
// and each node of the tree is read once; a tree under it reads its path
// again only when the walk comes back to it. found is false at the end of
// the tree, at a wrong node, or at a failure.
@(private)
repair_tree_next :: proc "contextless" (state: ^State, reader: ^Block_Reader, disk: ^Repair_Disk, entry: ^format.Entry) -> (found: bool) {
	repair := &state.repair
	frame := &repair.frames[repair.depth]
	if frame.levels == 0 {
		if frame.root.block == 0 || frame.done {
			return false
		}
		if !repair_tree_read(state, reader, 0, frame.root) {
			return false
		}
		frame.path[0] = {pointer = frame.root}
		frame.levels = 1
		repair.loaded = true
	}
	if !repair.loaded {
		for level in 0 ..< frame.levels {
			if !repair_tree_read(state, reader, level, frame.path[level].pointer) {
				return false
			}
		}
		repair.loaded = true
	}
	for frame.levels > 0 && repair.failure == .Running && !repair.store_failed {
		top := frame.levels - 1
		node := &repair.nodes[top]
		header := (^format.Tree_Header)(node)
		at := &frame.path[top]
		if header.level == 0 {
			if at.place < min(int(header.count), format.LEAF_CAPACITY) {
				record := node[format.TREE_HEADER_SIZE + at.place * LEAF_RECORD_SIZE:]
				intrinsics.mem_copy_non_overlapping(entry, &record[size_of(format.Entry_Name)], size_of(format.Entry))
				at.place += 1
				return true
			}
		} else if at.place < min(int(header.count), format.BRANCH_CAPACITY) {
			child := (^format.Pointer)(&node[format.TREE_HEADER_SIZE + at.place * BRANCH_RECORD_SIZE + size_of(format.Entry_Name)])^
			at.place += 1
			if !repair_tree_node_take(state, reader, disk, child) {
				continue
			}
			if frame.levels > format.TREE_DEPTH_LIMIT {
				repair.store_failed = true
				return false
			}
			if !repair_tree_read(state, reader, frame.levels, child) {
				return false
			}
			frame.path[frame.levels] = {pointer = child}
			frame.levels += 1
			continue
		}
		frame.levels -= 1
	}
	frame.done = frame.levels == 0
	return false
}

// repair_object_node counts the names that a node of a state holds, from
// the first block of data that the walk did not count, and walks under
// each child at its first name. It gives false when the step stops: at its
// bound, after a whole child, or at a failure.
@(private)
repair_object_node :: proc "contextless" (state: ^State, reader: ^Block_Reader, disk: ^Repair_Disk, pointer: format.Object_Child, level: int, base: u64, owner: u16) -> bool {
	repair := &state.repair
	object := &repair.object
	node := &state.object_nodes[level - 1]
	numbers := [1]u64{pointer.block}
	repair.step_reads += 1
	repair.reads += 1
	if !reader.read(reader, numbers[:], ([^]u8)(node)[:BLOCK_SIZE]) {
		repair_fail(state, .Device)
		return false
	}
	// A wrong node: the blocks under it are not known, as at the open.
	store_page, store_cell := format.store_place(repair.store)
	encrypted := state.store_pages[store_page].cells[store_cell].name[0] == format.OWNED_CELL_MARK
	if check_of_block(reader, pointer.block, ([^]u8)(node)[:BLOCK_SIZE]) != pointer.check || !block_tree.node_valid(node, level, base, object.size, encrypted) {
		return true
	}
	span := format.object_span(level - 1)
	for place in 0 ..< format.OBJECT_FANOUT {
		// A copy: the level below reads into its own node, not this one.
		item := state.object_nodes[level - 1].children[place]
		child_base := base + u64(place) * span
		if item.block == 0 || child_base + span <= object.resume {
			continue
		}
		if item.block < 2 || item.block >= state.disk_size {
			continue
		}
		if level == 1 {
			// A block of data: one name, and no read.
			repair_name(state, item.block, owner)
			continue
		}
		// A child that holds the resume point past the start was entered by
		// a step before: its name is counted.
		entered := child_base < object.resume && object.resume > object.start
		if !entered {
			repair_name(state, item.block, owner)
			first := repair_first(state, reader, disk, item.block)
			if repair.failure != .Running {
				return false
			}
			if !first {
				object.resume = child_base + span
				continue
			}
		}
		if !repair_object_node(state, reader, disk, item, level - 1, child_base, owner) {
			return false
		}
		object.resume = child_base + span
		if repair.step_reads >= repair.nodes_per_step {
			return false
		}
	}
	return true
}

// repair_object_walk counts the names under the state of repair.object,
// from where the step before stopped. It gives true when the state is done.
@(private)
repair_object_walk :: proc "contextless" (state: ^State, reader: ^Block_Reader, disk: ^Repair_Disk) -> bool {
	repair := &state.repair
	object := &repair.object
	owner := u16(repair.store + 1)
	// A size that no object has: the open counts nothing under it.
	if object.root.block < 2 || object.root.block >= state.disk_size || object.size > format.OBJECT_SIZE_LIMIT {
		return true
	}
	levels := format.object_levels(object.size)
	if !object.begun {
		object.begun = true
		object.resume = object.start
		repair_name(state, object.root.block, owner)
		if levels == 0 {
			return true
		}
		first := repair_first(state, reader, disk, object.root.block)
		if repair.failure != .Running {
			return false
		}
		if !first {
			return true
		}
	}
	if levels == 0 {
		return true
	}
	return repair_object_node(state, reader, disk, {block = object.root.block, check = object.root.check}, levels, 0, owner)
}

// repair_entry_begin takes an entry of a tree: an object or a release goes
// on in its phases, a tree goes on the path of the walk.
@(private)
repair_entry_begin :: proc "contextless" (state: ^State, reader: ^Block_Reader, disk: ^Repair_Disk, entry: ^format.Entry, queued: bool) {
	repair := &state.repair
	kind, ok := format.entry_kind_of_word(entry.kind)
	if !ok {
		return
	}
	switch kind {
	case .None:
	case .Object:
		repair.entry = entry^
		repair.entry_active = true
		repair.phase = .Current
		repair.object = {root = entry.pointer, size = entry.size, set = true}
	case .Tree:
		if repair.depth >= format.NESTING_LIMIT {
			repair.store_failed = true
			return
		}
		if !repair_tree_node_take(state, reader, disk, entry.pointer) {
			return
		}
		repair.depth += 1
		repair.frames[repair.depth] = {root = entry.pointer}
		repair.loaded = false
	case .Release:
		if !queued {
			return
		}
		repair.entry = entry^
		repair.entry_active = true
		repair.phase = .Release_List
		repair.list_next = entry.pointer
		repair.lists = 0
	}
}

// repair_entry_walk counts the names under the entry in progress, from its
// phase. It gives true when the entry is done.
@(private)
repair_entry_walk :: proc "contextless" (state: ^State, reader: ^Block_Reader, disk: ^Repair_Disk) -> bool {
	repair := &state.repair
	owner := u16(repair.store + 1)
	for repair.failure == .Running {
		if repair.step_reads >= repair.nodes_per_step {
			return false
		}
		switch repair.phase {
		case .Current:
			if !repair_object_walk(state, reader, disk) {
				return false
			}
			repair.object = {}
			if repair.entry.versions.block == 0 {
				return true
			}
			repair.phase = .Version_Index
		case .Version_Index:
			pointer := repair.entry.versions
			repair_name(state, pointer.block, owner)
			if repair_read(state, reader, pointer, &repair.version_index) != .Good || repair.version_index.leaf_count > format.VERSION_INDEX_CAPACITY {
				return repair.failure == .Running
			}
			repair.leaf_index = 0
			repair.phase = .Version_Leaf
		case .Version_Leaf:
			if repair.leaf_index >= int(repair.version_index.leaf_count) {
				return true
			}
			pointer := repair.version_index.leaves[repair.leaf_index]
			repair_name(state, pointer.block, owner)
			outcome := repair_read(state, reader, pointer, &repair.version_leaf)
			if outcome == .Device {
				return false
			}
			if outcome == .Wrong || repair.version_leaf.count == 0 || repair.version_leaf.count > format.VERSION_LEAF_CAPACITY {
				repair.leaf_index += 1
				continue
			}
			repair.place = 0
			repair.phase = .Version
		case .Version:
			if repair.place >= int(repair.version_leaf.count) {
				repair.leaf_index += 1
				repair.phase = .Version_Leaf
				continue
			}
			if !repair.object.set {
				version := repair.version_leaf.entries[repair.place]
				repair.object = {root = version.root, size = version.size, set = true}
			}
			if !repair_object_walk(state, reader, disk) {
				return false
			}
			repair.object = {}
			repair.place += 1
		case .Release_List:
			pointer := repair.list_next
			if pointer.block == 0 || repair.lists >= state.disk_size {
				return true
			}
			repair.lists += 1
			if pointer.block >= 2 && pointer.block < state.disk_size {
				repair_name(state, pointer.block, owner)
			}
			// A wrong list ends the chain, as at the open.
			if repair_read(state, reader, pointer, &repair.list) != .Good || !format.release_list_valid(&repair.list) {
				return repair.failure == .Running
			}
			repair.place = 0
			repair.phase = .Release_State
		case .Release_State:
			if repair.place >= int(repair.list.count) {
				repair.list_next = repair.list.next
				repair.phase = .Release_List
				continue
			}
			if !repair.object.set {
				released := repair.list.states[repair.place]
				repair.object = {root = released.root, size = released.size, start = released.cursor, set = true}
			}
			if !repair_object_walk(state, reader, disk) {
				return false
			}
			repair.object = {}
			repair.place += 1
		}
	}
	return false
}

// repair_store_walk walks the store of the repair from where the step
// before stopped. It gives true when the store is done.
@(private)
repair_store_walk :: proc "contextless" (state: ^State, reader: ^Block_Reader, disk: ^Repair_Disk) -> bool {
	repair := &state.repair
	for repair.failure == .Running && !repair.store_failed {
		if repair.step_reads >= repair.nodes_per_step {
			return false
		}
		if repair.entry_active {
			if !repair_entry_walk(state, reader, disk) {
				return false
			}
			repair.entry_active = false
			continue
		}
		entry: format.Entry
		if repair_tree_next(state, reader, disk, &entry) {
			repair_entry_begin(state, reader, disk, &entry, repair.in_removals && repair.depth == 0)
			continue
		}
		if repair.failure != .Running || repair.store_failed {
			break
		}
		// The tree is done: back to its parent, which reads its path again,
		// or to the removal queue.
		if repair.depth > 0 {
			repair.depth -= 1
			repair.loaded = false
		} else if !repair.in_removals {
			repair.in_removals = true
			repair_tree_start(state, reader, disk, disk.heads[repair.store].removals)
		} else {
			return true
		}
	}
	// A store with a wrong node of a tree is done: the rest of it is not
	// known.
	return repair.failure == .Running && repair.store_failed
}

// repair_store_listed says if a number names a store of the last commit.
@(private)
repair_store_listed :: proc "contextless" (state: ^State, index: int) -> bool {
	page, _ := format.store_place(index)
	return !state.store_page_damaged[page] && store_cell(state, index).name[0] != 0
}

@(private)
repair_store_numbers :: proc "contextless" (disk: ^Repair_Disk) -> int {
	return int(min(disk.root.store_page_count, format.STORE_PAGE_CAPACITY)) * format.STORES_OF_A_PAGE
}

// repair_begin starts a walk: the leaves that it counts, an empty scratch,
// the first store.
@(private)
repair_begin :: proc "contextless" (state: ^State, disk: ^Repair_Disk) {
	repair := &state.repair
	counts := &state.counts
	repair.leaf_count = 0
	// The leaves of a wrong directory come whole, first: the commit makes
	// the directory again from each of them. Then the other wrong leaves,
	// while they fit; the others wait for the next run.
	for directory in counts.wrong_directories[:counts.wrong_directory_count] {
		end := min(directory + format.count_span(1), counts.disk_blocks)
		if repair.leaf_count + int((end - directory + format.COUNTS_OF_A_PAGE - 1) / format.COUNTS_OF_A_PAGE) > REPAIR_LEAVES_MOST {
			continue
		}
		for leaf := directory; leaf < end; leaf += format.COUNTS_OF_A_PAGE {
			repair.leaves[repair.leaf_count] = {first = leaf}
			repair.leaf_count += 1
		}
	}
	for leaf in counts.wrong_leaves[:counts.wrong_leaf_count] {
		if repair.leaf_count >= REPAIR_LEAVES_MOST {
			break
		}
		if !block_counts.directory_is_wrong(counts, block_counts.page_first(1, leaf)) {
			repair.leaves[repair.leaf_count] = {first = leaf}
			repair.leaf_count += 1
		}
	}
	// In the order of their first block, for the search at each name.
	for index in 1 ..< repair.leaf_count {
		for at := index; at > 0 && repair.leaves[at - 1].first > repair.leaves[at].first; at -= 1 {
			repair.leaves[at - 1].first, repair.leaves[at].first = repair.leaves[at].first, repair.leaves[at - 1].first
		}
	}
	repair.store = -1
	repair.stores_walked, repair.stores_total = 0, 0
	for index in 0 ..< repair_store_numbers(disk) {
		if repair_store_listed(state, index) {
			repair.stores_total += 1
		}
	}
	repair.entry_active = false
	repair.object = {}
	repair.reads = 0
	scratch_reset(state)
	repair.running = true
}

// repair_step runs one step of the repair of the wrong leaves of the count
// tree. The first step takes the wrong leaves; each step walks the stores
// from where the step before stopped, up to its bound of nodes; after the
// last store it counts the pages of the store table and of the count tree,
// and gives the leaves to the counts (counts.repaired), which the service
// writes in one commit. A failure ends the walk: the next walk starts
// again from the first store.
repair_step :: proc "contextless" (state: ^State, reader: ^Block_Reader, disk: ^Repair_Disk) -> Repair_Outcome {
	repair := &state.repair
	if !repair.running {
		repair_begin(state, disk)
	}
	repair.step_reads = 0
	repair.failure = .Running
	for {
		if repair.store >= 0 {
			if !repair_store_walk(state, reader, disk) {
				break
			}
			if repair.store_failed {
				disk.store_damaged(disk, repair.store)
			}
			repair.stores_walked += 1
		}
		repair.store += 1
		for repair.store < repair_store_numbers(disk) && !repair_store_listed(state, repair.store) {
			repair.store += 1
		}
		if repair.store >= repair_store_numbers(disk) {
			repair_finish(state, disk)
			break
		}
		// The store block: one name.
		repair.in_removals, repair.depth, repair.store_failed = false, 0, false
		repair.entry_active = false
		repair.object = {}
		repair_name(state, store_cell(state, repair.store).store.block, u16(repair.store + 1))
		repair_tree_start(state, reader, disk, disk.heads[repair.store].tree)
		if repair.failure != .Running {
			break
		}
		if repair.step_reads >= repair.nodes_per_step {
			break
		}
	}
	switch repair.failure {
	case .Running:
		return repair.running ? .Running : .Done
	case .Done:
	case .Device:
		repair.running = false
		repair.wait_for_call = true
	case .No_Room:
		repair.running = false
		repair.no_room = true
	}
	return repair.failure
}

// repair_finish counts the pages that the root of the last commit names,
// each one name, and gives the counted leaves to the counts.
@(private)
repair_finish :: proc "contextless" (state: ^State, disk: ^Repair_Disk) {
	repair := &state.repair
	for pointer in disk.root.store_pages[:min(disk.root.store_page_count, format.STORE_PAGE_CAPACITY)] {
		repair_name(state, pointer.block, STORE_TABLE_OWNER)
	}
	if state.counts.root.block != 0 {
		repair_name(state, state.counts.root.block, COUNT_TREE_OWNER)
		if repair_count_pages(state, state.counts.levels, 0) == .Device {
			repair_fail(state, .Device)
			return
		}
	}
	repair.running = false
	state.counts.repaired = repair.leaves[:repair.leaf_count]
}

// repair_count_pages names each page of the count tree under a page: the
// directories that the cache reads, and the blocks of their children,
// wrong leaves too.
@(private)
repair_count_pages :: proc "contextless" (state: ^State, level: int, first: u64) -> block_counts.Read {
	frame, outcome := block_counts.page_get(&state.counts, level, first)
	if outcome != .Good || frame == nil || level == 0 {
		return outcome
	}
	// The frame can leave the cache while a child is read: the children are
	// copied first.
	children := (^format.Count_Directory)(&frame.bytes).children
	span := format.count_span(level - 1)
	for child, place in children {
		if child.block == 0 {
			continue
		}
		repair_name(state, child.block, COUNT_TREE_OWNER)
		if level > 1 {
			if under := repair_count_pages(state, level - 1, first + u64(place) * span); under == .Device {
				return under
			}
		}
	}
	return .Good
}

// repair_written forgets the repaired leaves: a commit wrote them. The
// leaves found wrong since stay, for the next repair; a list that was full
// is found again by the reads.
repair_written :: proc "contextless" (state: ^State) {
	counts := &state.counts
	block_counts.directories_written(counts)
	kept := 0
	for index in 0 ..< counts.wrong_leaf_count {
		first := counts.wrong_leaves[index]
		if block_counts.leaf_repaired(counts, first) == nil {
			counts.wrong_leaves[kept] = first
			kept += 1
		}
	}
	counts.wrong_leaf_count = kept
	counts.wrong_leaves_full = false
	counts.repaired = nil
	state.repair.leaf_count = 0
}
