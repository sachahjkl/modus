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
//
// A recount is a run of the same walk that counts every name of the leaves
// to recount into a tally, then writes the leaves that differ from it, one
// directory of level 1 in each commit (src/md/data/storage_capacity.md,
// "A recount is one walk").

// The leaves that one run of a repair counts, and that one commit of the
// write of a recount writes: the leaves of one directory of level 1, a
// format property. A wrong directory comes whole, and its commit makes it
// again from them. More wrong leaves wait for the next run.
REPAIR_LEAVES_MOST :: format.COUNT_DIRECTORY_FANOUT

// A recount starts when the free blocks of the disk fall under the blocks
// of the disk divided by this. A plan value, default 16 (about 6 %): under
// it the disk nears the refusal Full, and the blocks that dead names keep
// are worth a walk of each store; above it the walk refuses the changes
// and gives no space that a change needs. A request starts it at any time.
RECOUNT_FREE_SHARE :: 16

// The names that the walk of a recount keeps before it sorts them by leaf
// and adds them to the tally, so that each page of the tally is read and
// written once for the names of a sort. An inline capacity. The measure
// (count_tree_test.odin, "the cost of the tally on an aged disk"): with no
// sort the tally costs 1.02 reads and writes for each name with its 32
// pages over 64 leaves, and 1.86 with 4 pages, as on a disk of 8 times
// more leaves, toward 2 on a large disk; sorted, 0.02. A node of an object
// gives up to 64 names, so 16 384 names hold the names of 256 nodes, a
// sixteenth of the reads of a step, in 192 KiB of the state. Past it the
// names so far are sorted and added, and the step goes on; a sort then
// touches each page once for its names, not once for the step
// (recount_sorts_full counts it, and Count_Recount_Sorts_Full says it).
TALLY_ORDER_BITS :: 14
TALLY_NAMES_MOST :: 1 << TALLY_ORDER_BITS

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
	No_Room = 3, // The disk has no free block for the scratch: a repair starts again after the next commit; a recount when the free blocks grow.
	Damage_Full = 4, // The walk of a recount found more wrong blocks than the set of damage holds: the recount stops, and none starts again until the service starts again; the changes go on.
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

// A page of the tally of a recount: the counts and the owners of the 512
// blocks of one leaf, the form of a leaf.
TALLY_PAGE_MAGIC :: u32(0x594C4154) // The bytes "TALY".
Tally_Page :: struct {
	header:  Scratch_Header,
	counts:  [format.COUNTS_OF_A_PAGE]u32,
	owners:  [format.COUNTS_OF_A_PAGE]u16,
	padding: [BLOCK_SIZE - size_of(Scratch_Header) - format.COUNTS_OF_A_PAGE * 6]u8,
}
#assert(size_of(Tally_Page) == BLOCK_SIZE)

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

// The shape of the scratch: the bits of a page (the tally: 512 blocks, one
// leaf, whatever the shape), the children of a directory, the pages in
// memory. A zero field takes the size of the
// format; a host test takes smaller ones, so that a small disk has
// several pages and levels, and pages leave the memory.
Scratch_Shape :: struct {
	page_bits:   u64, // At most SCRATCH_BITS_OF_A_PAGE.
	children:    u64, // At most SCRATCH_WORDS.
	frame_count: int, // At most SCRATCH_FRAMES.
}

// A scratch of a repair: the bits of the nodes that it walked, or the
// tally of a recount.
Scratch :: struct {
	magic:      u32, // SCRATCH_PAGE_MAGIC, or TALLY_PAGE_MAGIC.
	shape:      Scratch_Shape, // The shape of this run: each field at most the size of the format.
	levels:     int,
	top:        [SCRATCH_WORDS]u64, // The blocks of the pages of the highest level.
	frames:     [SCRATCH_FRAMES]Scratch_Frame,
	hand:       int,
	in_memory:  bool,
	all_pages:  u64, // The pages of the scratch, its directories too, when each is made.
	transfers:  u64, // The pages that the run read and wrote: a measure. // Each page of the scratch fits in its frames: no page goes to the disk, and no block is taken.
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
	scratch_next:   u64, // The two scratches take free blocks in their order from here, so never one twice; the commits of the write of a recount take none below it.
	step_reader:    ^Block_Reader, // The reader and the disk of the step, for the pages of the tally.
	step_disk:      ^Repair_Disk,
	// The recount (src/md/data/storage_capacity.md, "A recount is one walk").
	recount:           bool, // The run is a recount: its walk counts each name into the tally.
	recount_writing:   bool, // The walk ended: the run compares each leaf with its tally, one directory of level 1 at a time.
	recount_first:     u64, // The first block of the first leaf to recount.
	recount_next:      u64, // The first block of the next leaf that the write compares.
	recount_freed:     u64, // The blocks that the write freed: a name in the tree and none in the tally.
	recount_requested: bool, // A caller asked for a recount: it starts with no wait for the free space.
	recount_settled:   bool, // The recount ended and no commit of it wrote the last record: the next commit writes 0.
	recount_ended:     bool, // The recount ended since the service last read it (recount_ended_take).
	tally_shape:       Scratch_Shape, // The shape of the tally of the next recount; its page_bits is always a leaf.
	recount_blocked:   bool, // A recount found no room for its tally, or its commit no block: none starts until the free blocks pass recount_blocked_free.
	recount_blocked_free: u64,
	recount_room_need: u64, // The free blocks that the tally and the scratch of the last refused start needed: a measure for the log.
	recount_room_said: bool, // The refusal for room waits for its line on the log (recount_blocked_take).
	recount_damage_stopped: bool, // The walk of a recount filled the set of damage: no recount starts until the service starts again.
	recount_names:     u64, // The names that the walk gave the tally: a measure.
	recount_sorts_full: u64, // The sorts of names that a full buffer forced inside a step: a measure of the slower tier.
	recount_sort_most: u64, // The most names that one sort took: a measure.
	tally_keys:        [TALLY_NAMES_MOST]u64, // The names of a step, before their sort: the leaf, then the order of the name.
	tally_places:      [TALLY_NAMES_MOST]u32, // For each order of a name: the place of its block in its leaf, and its owner.
	tally_name_count:  int,
	tally_names_most:  int, // TALLY_NAMES_MOST; a host test takes fewer, or 1 for no sort.
	recount_batch:     int, // The leaves that differ in one commit of the write: 0 for the leaves of one directory (REPAIR_LEAVES_MOST); a host test takes fewer, so that a small disk writes in several commits.
	tallies:           Scratch,
}

// repair_active says if the service is in the repair state: it makes no
// change until the commit of the repaired leaves.
repair_active :: proc "contextless" (state: ^State) -> bool {
	if state.form != .Count_Tree || state.repair.no_room {
		return false
	}
	return state.repair.running || len(state.counts.repaired) != 0 || state.counts.wrong_leaf_count > 0
}

// repair_commit_waits says if a run ended and the commit of its leaves
// waits.
repair_commit_waits :: proc "contextless" (state: ^State) -> bool {
	return len(state.counts.repaired) != 0
}

// recount_running says if the run in progress is a recount: a change is
// refused with the unit Count_Recount.
recount_running :: proc "contextless" (state: ^State) -> bool {
	return state.repair.running && state.repair.recount
}

// recount_free_bound gives the free blocks under which a recount starts.
recount_free_bound :: proc "contextless" (state: ^State) -> u64 {
	return state.counts.disk_blocks / RECOUNT_FREE_SHARE
}

// recount_waits says if a recount can start: leaves wait for it, no other
// run, commit or failure of a run waits, and the disk needs the space (its
// free blocks under recount_free_bound) or a caller asked for it. Until
// then the dead names only keep their blocks in use.
recount_waits :: proc "contextless" (state: ^State) -> bool {
	if state.form != .Count_Tree || state.counts.leaves_to_recount == 0 || state.repair.recount_settled || state.counts.wrong_leaves_full || state.repair.recount_damage_stopped {
		return false
	}
	if state.repair.wait_for_call || state.repair.no_room || repair_active(state) {
		return false
	}
	free, read := block_counts.free_blocks(&state.counts)
	if read != .Good {
		return false
	}
	// A recount that found no room starts again only when the free blocks
	// grew: a person who removes files gets no Busy for a walk that cannot
	// end.
	if state.repair.recount_blocked && free <= state.repair.recount_blocked_free {
		return false
	}
	return state.repair.recount_requested || free < recount_free_bound(state)
}

// recount_request asks for a recount, and gives the leaves that wait for
// it: 0 when none waits (the form Tables counts each name at its open), and
// nothing starts.
recount_request :: proc "contextless" (state: ^State) -> (leaves: u64) {
	if state.form != .Count_Tree || state.repair.recount_settled {
		return 0
	}
	leaves = state.counts.leaves_to_recount
	if leaves != 0 {
		state.repair.recount_requested = true
	}
	return leaves
}

// recount_ended_take says once that a recount ended, with the blocks that
// its write freed.
recount_ended_take :: proc "contextless" (state: ^State) -> (ended: bool, freed: u64) {
	ended, freed = state.repair.recount_ended, state.repair.recount_freed
	state.repair.recount_ended = false
	return
}

// recount_holds_block says if a block holds a page of a scratch of the
// recount whose write runs: the commits of the write take no such block,
// as the tally of the leaves after them is still read.
recount_holds_block :: proc "contextless" (state: ^State, number: u64) -> bool {
	return state.repair.running && state.repair.recount && state.repair.recount_writing && number < state.repair.scratch_next
}

// recount_record_decide gives the leaves to recount that the top directory
// of a commit names, and set false when the commit keeps the record of the
// top before. dead_names: the commit leaves names that no state holds (a
// release that met a wrong block, a version index or leaf dropped). In
// order: dead names name each leaf; the commit of the write of a recount
// names the leaves after its directory; a recount that ended with no
// commit of its last record writes 0; the form Tables writes 0 once it
// wrote each leaf that differs from its walk, unless a commit of its own
// left dead names since its open.
recount_record_decide :: proc "contextless" (state: ^State, dead_names: bool) -> (leaves: u64, set: bool) {
	if dead_names {
		return format.count_tree_leaves(state.counts.disk_blocks), true
	}
	if state.repair.recount && state.repair.recount_writing && len(state.counts.repaired) != 0 {
		return recount_leaves_from(state, state.repair.recount_next), true
	}
	if state.repair.recount_settled {
		return 0, true
	}
	if state.form == .Tables && !state.recount_dead_since_open && !state.recount_cleared_since_open && state.leaves_to_write_count == 0 && state.counts.leaves_to_recount != 0 {
		return 0, true
	}
	return 0, false
}

// recount_record_written says that a commit wrote the record that
// recount_record_decide gave.
recount_record_written :: proc "contextless" (state: ^State, dead_names: bool, leaves: u64, set: bool) {
	if !set {
		return
	}
	if dead_names {
		state.recount_dead_since_open = true
		state.repair.recount_settled = false
	}
	if leaves == 0 {
		state.repair.recount_settled = false
		state.repair.recount_requested = false
		if state.form == .Tables {
			state.recount_cleared_since_open = true
		}
	}
}

// recount_leaves_from gives the leaves of the disk from the leaf that holds
// a block to the last.
@(private)
recount_leaves_from :: proc "contextless" (state: ^State, number: u64) -> u64 {
	total := format.count_tree_leaves(state.counts.disk_blocks)
	at := number / format.COUNTS_OF_A_PAGE
	return at >= total ? 0 : total - at
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
// repair counts again: a leaf of the run, or of the tally of a recount.
repair_name :: proc "contextless" (state: ^State, number: u64, owner: u16) {
	if state.repair.recount {
		if number >= state.repair.recount_first && number < state.counts.disk_blocks {
			tally_name_add(state, number, owner)
		}
		return
	}
	first := number - number % format.COUNTS_OF_A_PAGE
	if leaf := block_counts.repaired_find(state.repair.leaves[:state.repair.leaf_count], first); leaf != nil {
		place := number - first
		if u64(leaf.counts[place]) < REFERENCE_LIMIT {
			leaf.counts[place] += 1
		}
		leaf.owners[place] = owner
	}
}

@(private)
repair_fail :: proc "contextless" (state: ^State, why: Repair_Outcome) {
	if state.repair.failure == .Running {
		state.repair.failure = why
	}
}

// scratch_reset empties a scratch for a new run: the pages of the run
// before are not read again. The bits take the shape of the repair; the
// tally has one leaf in each page.
@(private)
scratch_reset :: proc "contextless" (state: ^State, scratch: ^Scratch, magic: u32) {
	tally := magic == TALLY_PAGE_MAGIC
	shape := tally ? state.repair.tally_shape : state.repair.shape
	scratch.magic = magic
	scratch.shape = {
		page_bits   = tally ? format.COUNTS_OF_A_PAGE : shape.page_bits == 0 ? SCRATCH_BITS_OF_A_PAGE : clamp(shape.page_bits, 1, SCRATCH_BITS_OF_A_PAGE),
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
	scratch.all_pages = all_pages
	scratch.transfers = 0
	scratch.top = {}
	for &frame in scratch.frames {
		frame.used = false
	}
	scratch.hand = 0
	scratch.run += 1
}

// scratch_take gives a free block to a new page of the scratch, after each
// block that it took before, or 0.
@(private)
scratch_take :: proc "contextless" (state: ^State) -> u64 {
	repair := &state.repair
	// No plan runs during a repair: a failure of a read of the count tree is
	// the failure of this search.
	block_counts.counts_failure_clear(&state.counts)
	number := block_counts.free_search(&state.counts, repair.scratch_next, nil, nil)
	if state.counts.failure == .Device {
		repair_fail(state, .Device)
		return 0
	}
	if number == 0 || number < repair.scratch_next {
		repair_fail(state, .No_Room)
		return 0
	}
	repair.scratch_next = number + 1
	return number
}

// scratch_evict gives a frame for a new page: a dirty page goes to its block.
@(private)
scratch_evict :: proc "contextless" (state: ^State, disk: ^Repair_Disk, scratch: ^Scratch) -> int {
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
			scratch.transfers += 1
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

// scratch_frame gives the page of a level and an index of a scratch, read
// or made. With make false, a page that no step made gives nil and no
// failure: its words are all 0.
@(private)
scratch_frame :: proc "contextless" (state: ^State, reader: ^Block_Reader, disk: ^Repair_Disk, scratch: ^Scratch, level: int, index: u64, create: bool = true) -> ^Scratch_Frame {
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
		if !create && (scratch.in_memory || block == 0) {
			return nil
		}
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
		parent := scratch_frame(state, reader, disk, scratch, level + 1, index / scratch.shape.children, create)
		if parent == nil {
			return nil
		}
		slot := &parent.page.words[index % scratch.shape.children]
		block = slot^
		if !create && (scratch.in_memory || block == 0) {
			return nil
		}
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
	at := scratch_evict(state, disk, scratch)
	if at < 0 {
		repair_fail(state, .Device)
		return nil
	}
	frame := &scratch.frames[at]
	header := Scratch_Header{magic = scratch.magic, level = u32(level), index = index, nonce = disk.nonce, run = scratch.run}
	if fresh {
		frame.page = {header = header}
	} else {
		numbers := [1]u64{block}
		state.repair.step_reads += 1
		state.repair.reads += 1
		scratch.transfers += 1
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
	frame := scratch_frame(state, reader, disk, &state.repair.scratch, 0, number / bits)
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

// tally_change adds a change to the count of a block in the tally of a
// recount: a name more or less. A count that falls to 0 has no owner.
@(private)
tally_change :: proc "contextless" (state: ^State, number: u64, change: i64, owner: u16) {
	repair := &state.repair
	frame := scratch_frame(state, repair.step_reader, repair.step_disk, &repair.tallies, 0, number / format.COUNTS_OF_A_PAGE)
	if frame == nil {
		return
	}
	tally := (^Tally_Page)(&frame.page)
	place := number % format.COUNTS_OF_A_PAGE
	switch {
	case change > 0:
		if u64(tally.counts[place]) < REFERENCE_LIMIT {
			tally.counts[place] += 1
		}
		tally.owners[place] = owner
	case change < 0 && tally.counts[place] > 0:
		tally.counts[place] -= 1
		if tally.counts[place] == 0 {
			tally.owners[place] = 0
		}
	}
	frame.dirty = true
}

// tally_name_add keeps one name of the walk of a recount for the sort of
// the step. A full buffer is sorted and added first.
@(private)
tally_name_add :: proc "contextless" (state: ^State, number: u64, owner: u16) {
	repair := &state.repair
	most := clamp(repair.tally_names_most, 1, TALLY_NAMES_MOST)
	if repair.tally_name_count >= most {
		repair.recount_sorts_full += 1
		tally_names_apply(state)
	}
	order := repair.tally_name_count
	repair.tally_keys[order] = (number / format.COUNTS_OF_A_PAGE) << TALLY_ORDER_BITS | u64(order)
	repair.tally_places[order] = u32(number % format.COUNTS_OF_A_PAGE) | u32(owner) << 16
	repair.tally_name_count += 1
	repair.recount_names += 1
}

// tally_names_apply sorts the names kept by their leaf, and in their order
// inside a leaf, so that the last name of a block still gives its owner,
// then adds each one to the tally: each page is touched once.
@(private)
tally_names_apply :: proc "contextless" (state: ^State) {
	repair := &state.repair
	keys := repair.tally_keys[:repair.tally_name_count]
	repair.recount_sort_most = max(repair.recount_sort_most, u64(len(keys)))
	keys_sort(keys)
	for key in keys {
		order := key & (TALLY_NAMES_MOST - 1)
		place := repair.tally_places[order]
		number := (key >> TALLY_ORDER_BITS) * format.COUNTS_OF_A_PAGE + u64(place & 0xFFFF)
		tally_change(state, number, 1, u16(place >> 16))
		if repair.failure != .Running {
			break
		}
	}
	repair.tally_name_count = 0
}

// keys_sort sorts keys in place, with no memory: a heap sort. The keys are
// distinct, so the order of equal keys does not matter.
@(private)
keys_sort :: proc "contextless" (keys: []u64) {
	sift :: proc "contextless" (keys: []u64, start: int, end: int) {
		root := start
		for {
			child := 2 * root + 1
			if child >= end {
				return
			}
			if child + 1 < end && keys[child + 1] > keys[child] {
				child += 1
			}
			if keys[root] >= keys[child] {
				return
			}
			keys[root], keys[child] = keys[child], keys[root]
			root = child
		}
	}
	for start := len(keys) / 2 - 1; start >= 0; start -= 1 {
		sift(keys, start, len(keys))
	}
	for end := len(keys) - 1; end > 0; end -= 1 {
		keys[0], keys[end] = keys[end], keys[0]
		sift(keys, 0, end)
	}
}

// recount_delta gives the tally the change of a count that a commit of the
// write of a recount made: the pages of the count tree that it took and
// freed. A leaf that the write passed is on the disk, and its tally is not
// read again; a failure of a page of the tally ends the recount, whose
// record on the disk stays right.
recount_delta :: proc "contextless" (state: ^State, reader: ^Block_Reader, disk: ^Repair_Disk, number: u64, change: i64, owner: u16) {
	repair := &state.repair
	if !repair.running || !repair.recount || !repair.recount_writing || number < repair.recount_next || number >= state.counts.disk_blocks || change == 0 {
		return
	}
	repair.step_reader, repair.step_disk = reader, disk
	repair.failure = .Running
	tally_change(state, number, change, owner)
	if repair.failure != .Running {
		recount_stop(state)
		repair.wait_for_call = true
	}
}

// recount_stop ends a recount before its end: the record on the disk names
// the leaves that no commit wrote, and the next recount starts again from
// the first of them.
@(private)
recount_stop :: proc "contextless" (state: ^State) {
	repair := &state.repair
	repair.running, repair.recount, repair.recount_writing = false, false, false
	repair.leaf_count = 0
	repair.tally_name_count = 0
	state.counts.repaired = nil
}

// recount_block keeps a recount from starting again until the free blocks
// grow: it found no room for its tally, or its commit found no block. The
// request ends with it.
@(private)
recount_block :: proc "contextless" (state: ^State, need: u64) {
	repair := &state.repair
	free, _ := block_counts.free_blocks(&state.counts)
	repair.recount_blocked, repair.recount_blocked_free = true, free
	repair.recount_room_need = need
	repair.recount_room_said = true
	repair.recount_requested = false
}

// recount_stop_for_room ends the write of a recount whose commit the
// service refused for space: the record on the disk names the leaves that
// no commit wrote, and the changes come back. No recount starts again until
// the free blocks grow.
recount_stop_for_room :: proc "contextless" (state: ^State) {
	recount_stop(state)
	recount_block(state, 0)
}

// recount_blocked_take says once that a recount found no room, with the
// free blocks then and the blocks that its tally needed (0: a commit of
// its write found no block).
recount_blocked_take :: proc "contextless" (state: ^State) -> (said: bool, free: u64, need: u64) {
	repair := &state.repair
	said, free, need = repair.recount_room_said, repair.recount_blocked_free, repair.recount_room_need
	repair.recount_room_said = false
	return
}

// recount_room_need gives the free blocks that a recount needs: the pages
// of the scratch of the walked nodes and of the tally that do not stay in
// memory. The tally has one page for each leaf in use from the first leaf
// to recount: the top directory bounds them by the blocks in use under
// each child. A free count that lies gives a wrong bound; the walk then
// ends with No_Room, as it does on a disk that fills during it.
@(private)
recount_room_need :: proc "contextless" (state: ^State) -> (need: u64, outcome: block_counts.Read) {
	repair := &state.repair
	counts := &state.counts
	if !repair.scratch.in_memory {
		need += repair.scratch.all_pages
	}
	if repair.tallies.in_memory {
		return need, .Good
	}
	top: ^block_counts.Frame
	top, outcome = block_counts.page_get(counts, counts.levels, 0)
	if outcome != .Good {
		return need, outcome
	}
	leaves: u64
	if top != nil {
		directory := (^format.Count_Directory)(&top.bytes)
		span := format.count_span(counts.levels - 1)
		for child, place in directory.children {
			first := u64(place) * span
			if child.block == 0 || first >= counts.disk_blocks || first + span <= repair.recount_first {
				continue
			}
			start := max(first, repair.recount_first)
			end := min(first + span, counts.disk_blocks)
			span_leaves := (end - start + format.COUNTS_OF_A_PAGE - 1) / format.COUNTS_OF_A_PAGE
			all_free := format.count_free_blocks(counts.levels - 1, first, counts.disk_blocks)
			in_use := all_free > child.free ? all_free - child.free : 0
			leaves += min(span_leaves, in_use)
		}
	}
	children := max(repair.tallies.shape.children, 2)
	need += leaves + leaves / (children - 1) + u64(repair.tallies.levels) + 1
	return need, .Good
}

// repair_wrong_note keeps a block that the walk found wrong in the set of
// the wrong blocks.
@(private)
repair_wrong_note :: proc "contextless" (state: ^State, number: u64) {
	if number < 2 || number >= state.disk_size || wrong_block(state, number) {
		return
	}
	// A recount that would fill the set of damage stops its walk: the set
	// full would stop each change, for a walk that the service can leave.
	if state.repair.recount && !wrong_set_has_room(state) {
		repair_fail(state, .Damage_Full)
		return
	}
	wrong_block_set(state, number)
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
	// A wrong node is kept wrong: no later change trusts it.
	switch repair_read(state, reader, pointer, node) {
	case .Good:
	case .Device:
		return false
	case .Wrong:
		repair_wrong_note(state, pointer.block)
		repair.store_failed = true
		return false
	}
	header := (^format.Tree_Header)(node)
	if header.magic != format.NODE_MAGIC || header.level > format.TREE_DEPTH_LIMIT {
		repair_wrong_note(state, pointer.block)
		repair.store_failed = true
		return false
	}
	if level > 0 && u32(header.level) + 1 != u32((^format.Tree_Header)(&repair.nodes[level - 1]).level) {
		repair_wrong_note(state, pointer.block)
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
	// A wrong node: the blocks under it are not known, as at the open. It is
	// kept wrong, so a later step of a release never trusts it.
	store_page, store_cell := format.store_place(repair.store)
	encrypted := format.cell_uses_encrypted_layout(state.store_pages[store_page].cells[store_cell].name)
	if check_of_block(reader, pointer.block, ([^]u8)(node)[:BLOCK_SIZE]) != pointer.check || !block_tree.node_valid(node, level, base, object.size, encrypted) {
		repair_wrong_note(state, pointer.block)
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
			outcome := repair_read(state, reader, pointer, &repair.version_index)
			if outcome == .Wrong || outcome == .Good && repair.version_index.leaf_count > format.VERSION_INDEX_CAPACITY {
				repair_wrong_note(state, pointer.block)
			}
			if outcome != .Good || repair.version_index.leaf_count > format.VERSION_INDEX_CAPACITY {
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
				repair_wrong_note(state, pointer.block)
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
			// A wrong list ends the chain, as at the open, and is kept wrong.
			outcome := repair_read(state, reader, pointer, &repair.list)
			if outcome == .Wrong || outcome == .Good && !format.release_list_valid(&repair.list) {
				repair_wrong_note(state, pointer.block)
			}
			if outcome != .Good || !format.release_list_valid(&repair.list) {
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

// repair_begin starts a walk of a repair: the wrong leaves that it counts.
@(private)
repair_begin :: proc "contextless" (state: ^State, disk: ^Repair_Disk) {
	repair := &state.repair
	counts := &state.counts
	repair.leaf_count = 0
	repair.recount, repair.recount_writing = false, false
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
	walk_begin(state, disk)
}

// recount_begin starts a recount: a walk that counts each name of a block
// of the leaves to recount into an empty tally.
@(private)
recount_begin :: proc "contextless" (state: ^State, disk: ^Repair_Disk) -> Repair_Outcome {
	repair := &state.repair
	repair.leaf_count = 0
	repair.recount, repair.recount_writing = true, false
	total := format.count_tree_leaves(state.counts.disk_blocks)
	repair.recount_first = (total - min(state.counts.leaves_to_recount, total)) * format.COUNTS_OF_A_PAGE
	repair.recount_next = repair.recount_first
	repair.recount_freed = 0
	repair.recount_names, repair.recount_sorts_full, repair.recount_sort_most = 0, 0, 0
	repair.tally_name_count = 0
	scratch_reset(state, &repair.tallies, TALLY_PAGE_MAGIC)
	walk_begin(state, disk)
	// The room first: a walk that would end with no room for its tally
	// refuses the changes for nothing.
	need, read := recount_room_need(state)
	free, free_read := block_counts.free_blocks(&state.counts)
	if read == .Device || free_read == .Device {
		repair.recount_requested = false
		recount_stop(state)
		repair.wait_for_call = true
		return .Device
	}
	if read != .Good || free_read != .Good || free < need {
		recount_stop(state)
		recount_block(state, need)
		return .No_Room
	}
	repair.recount_blocked = false
	return .Running
}

// walk_begin starts the walk of the stores of a run: an empty scratch of
// the walked nodes, the first store.
@(private)
walk_begin :: proc "contextless" (state: ^State, disk: ^Repair_Disk) {
	repair := &state.repair
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
	repair.scratch_next = 2
	scratch_reset(state, &repair.scratch, SCRATCH_PAGE_MAGIC)
	repair.running = true
}

// repair_step runs one step of a run: the repair of the wrong leaves of
// the count tree, or else a recount. The first step takes the wrong leaves
// or starts the tally; each step walks the stores from where the step
// before stopped, up to its bound of reads and writes; after the last
// store it counts the pages of the store table and of the count tree. A
// repair then gives its leaves to the counts (counts.repaired), which the
// service writes in one commit; a recount compares each leaf with its
// tally, and gives the leaves of one directory that differ to the counts
// for each commit. A failure ends the run: the next run starts again from
// the first store.
repair_step :: proc "contextless" (state: ^State, reader: ^Block_Reader, disk: ^Repair_Disk) -> Repair_Outcome {
	repair := &state.repair
	repair.step_reader, repair.step_disk = reader, disk
	if !repair.running {
		if state.counts.wrong_leaf_count > 0 || state.counts.wrong_directory_count > 0 {
			repair_begin(state, disk)
		} else if started := recount_begin(state, disk); started != .Running {
			return started
		}
	}
	repair.step_reads = 0
	repair.failure = .Running
	if repair.recount_writing {
		return recount_write_step(state)
	}
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
	// The names of the step, sorted by leaf, go to the tally.
	if repair.recount && repair.failure == .Running && repair.tally_name_count > 0 {
		tally_names_apply(state)
	}
	return repair_step_end(state)
}

// repair_step_end gives the outcome of a step, and ends the run at a
// failure.
@(private)
repair_step_end :: proc "contextless" (state: ^State) -> Repair_Outcome {
	repair := &state.repair
	switch repair.failure {
	case .Running:
		if repair.running {
			return len(state.counts.repaired) != 0 ? .Done : .Running
		}
		return .Done
	case .Done:
	case .Device:
		// A failing walk is not started again by a request.
		if repair.recount {
			repair.recount_requested = false
		}
		recount_stop(state)
		repair.wait_for_call = true
	case .No_Room:
		was_recount := repair.recount
		recount_stop(state)
		if was_recount {
			recount_block(state, 0)
		} else {
			repair.no_room = true
		}
	case .Damage_Full:
		recount_stop(state)
		repair.recount_damage_stopped = true
		repair.recount_requested = false
	}
	return repair.failure
}

// repair_finish counts the pages that the root of the last commit names,
// each one name. A repair gives the counted leaves to the counts; a
// recount starts its write.
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
	if repair.failure != .Running {
		return
	}
	if repair.recount {
		if repair.tally_name_count > 0 {
			tally_names_apply(state)
		}
		repair.recount_writing = true
		repair.stores_walked = repair.stores_total
		return
	}
	repair.running = false
	state.counts.repaired = repair.leaves[:repair.leaf_count]
}

// recount_write_step compares the leaves of the tree with their tally, from
// where the step before stopped, up to the bound of a step. At the end of
// a directory of level 1 whose leaves differ, it gives them to the counts
// (Done: one commit writes them, with the leaves still to recount after the
// directory); a directory where no leaf differs makes no commit. A leaf
// that no directory names and that no name reached is passed with no read;
// no free count of a directory is trusted.
@(private)
recount_write_step :: proc "contextless" (state: ^State) -> Repair_Outcome {
	repair := &state.repair
	counts := &state.counts
	for repair.recount_next < counts.disk_blocks {
		if repair.step_reads >= repair.nodes_per_step {
			return .Running
		}
		leaf := repair.recount_next
		repair.step_reads += 1
		block_counts.counts_failure_clear(counts)
		tree_leaf, read := block_counts.page_get(counts, 0, leaf)
		switch read {
		case .Good:
		case .Device:
			repair_fail(state, .Device)
			return repair_step_end(state)
		case .Wrong:
			// A wrong leaf: its repair runs first, and the recount starts
			// again from its record.
			recount_stop(state)
			return .Done
		}
		tally_frame := scratch_frame(state, repair.step_reader, repair.step_disk, &repair.tallies, 0, leaf / format.COUNTS_OF_A_PAGE, false)
		if repair.failure != .Running {
			return repair_step_end(state)
		}
		if tree_leaf != nil || tally_frame != nil {
			tree_page := tree_leaf != nil ? (^format.Count_Page)(&tree_leaf.bytes) : nil
			tally := tally_frame != nil ? (^Tally_Page)(&tally_frame.page) : nil
			differs := false
			for place in 0 ..< format.COUNTS_OF_A_PAGE {
				tree_count := tree_page != nil ? tree_page.counts[place] : 0
				tree_owner := tree_page != nil ? tree_page.owners[place] : 0
				tally_count := tally != nil ? tally.counts[place] : 0
				tally_owner := tally != nil ? tally.owners[place] : 0
				if tree_count != tally_count || tree_owner != tally_owner {
					differs = true
				}
				if tree_count != 0 && tally_count == 0 {
					repair.recount_freed += 1
				}
			}
			if differs {
				kept := &repair.leaves[repair.leaf_count]
				kept^ = {first = leaf}
				if tally != nil {
					kept.counts = tally.counts
					kept.owners = tally.owners
				}
				repair.leaf_count += 1
			}
		}
		repair.recount_next = leaf + format.COUNTS_OF_A_PAGE
		// The end of a directory of level 1: its leaves that differ go in one
		// commit.
		batch := repair.recount_batch == 0 ? REPAIR_LEAVES_MOST : clamp(repair.recount_batch, 1, REPAIR_LEAVES_MOST)
		if (repair.recount_next % format.count_span(1) == 0 || repair.leaf_count >= batch) && repair.leaf_count > 0 {
			state.counts.repaired = repair.leaves[:repair.leaf_count]
			return .Done
		}
	}
	if repair.leaf_count > 0 {
		state.counts.repaired = repair.leaves[:repair.leaf_count]
		return .Done
	}
	recount_end(state)
	return .Done
}

// recount_end ends a recount whose write passed the last leaf. A record on
// the disk that still names leaves goes at the next commit of any kind: a
// run with no leaf to write makes no commit.
@(private)
recount_end :: proc "contextless" (state: ^State) {
	repair := &state.repair
	repair.running, repair.recount, repair.recount_writing = false, false, false
	repair.recount_requested = false
	repair.recount_ended = true
	repair.recount_settled = state.counts.leaves_to_recount != 0
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
// is found again by the reads. The write of a recount goes on at the next
// step, or ends after its last leaf.
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
	if state.repair.recount && state.repair.recount_writing && state.repair.recount_next >= counts.disk_blocks {
		recount_end(state)
	}
}
