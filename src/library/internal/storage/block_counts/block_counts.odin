package block_counts

// The count tree of a disk: the count of names and the owner of each block,
// in leaves of 512 blocks under directories of 128 children
// (src/md/data/storage_capacity.md, "The counts of names live on the disk";
// the format is in modus:contract/store). This package reads the tree
// through a cache of pages in the memory of its caller, makes the new pages
// of a commit with copy on write, and finds a free block. It writes
// nothing: the caller writes the pages of a commit with the other blocks of
// the commit, before the root.

import "base:intrinsics"
import format "modus:contract/store"

Block :: [format.BLOCK_SIZE]u8
Pointer :: format.Pointer

// The outcome of a read of a page.
Read :: enum u8 {
	Good   = 0,
	Wrong  = 1, // The page has a wrong check, or breaks a rule of the format.
	Device = 2, // The device reported an error.
}

// Where the pages come from.
Source :: struct {
	// read reads one block. false: the device reported an error.
	read: proc "contextless" (source: ^Source, number: u64, into: ^Block) -> bool,
	data: rawptr,
}

Frame_State :: enum u8 {
	Free   = 0,
	Clean  = 1, // A page of the tree that the root names.
	Staged = 2, // A page of a commit, not on the disk yet.
}

// One page in memory.
Frame :: struct {
	bytes:      Block,
	first:      u64, // The first block under it.
	block:      u64, // Its block: the block on the disk, or the new block of a staged page (0 until the commit takes one).
	old_block:  u64, // A staged page: the block of the page that it replaces, 0 for none.
	free:       u64, // A staged page: the blocks of count 0 under it.
	level:      int,
	state:      Frame_State,
	referenced: bool, // Used since the hand of the cache passed it.
}

// The count tree that the root of the disk names, read through a cache.
Counts :: struct {
	source:       ^Source,
	root:         Pointer,
	levels:       int,
	disk_blocks:  u64,
	frames:       []Frame, // Memory of the caller: the cache.
	slots:        []i32, // The index of the frames by their page: 1 + the frame, 0 for none. A power of 2, at least twice the frames.
	hand:         int,
	failure:      Read, // The first failure of a read since counts_failure_clear.
	failed_block: u64,
	// The leaves found wrong: their counts are not known until a repair
	// counts them again. The search of a free block passes them. A wrong
	// directory of level 1 makes each leaf under it wrong: its pointers to
	// them are not known.
	wrong_leaves:      [WRONG_LEAVES_MOST]u64, // The first block of each one.
	wrong_leaf_count:  int,
	wrong_leaves_full: bool, // More leaves were wrong than the list holds, or a directory above level 1 is wrong: the damage is not known whole.
	// The directories of level 1 found wrong: the commit of their repair
	// makes each of them again from its repaired leaves.
	wrong_directories:      [WRONG_DIRECTORIES_MOST]u64, // The first block under each one.
	wrong_directory_count:  int,
	// The leaves that a repair counted again, until a commit writes them,
	// in the order of their first block: their counts come from here, not
	// from their pages.
	repaired:          []Repaired_Leaf,
	// The last leaves of the disk that wait for a recount, as the top
	// directory names them: known once the top is read or a commit
	// installs a new one.
	leaves_to_recount: u64,
}

// The wrong leaves that the counts keep: the leaves of two directories.
WRONG_LEAVES_MOST :: 2 * format.COUNT_DIRECTORY_FANOUT
// The wrong directories of level 1 that the counts keep.
WRONG_DIRECTORIES_MOST :: 2

// A leaf that a repair counted again.
Repaired_Leaf :: struct {
	first:  u64,
	counts: [format.COUNTS_OF_A_PAGE]u32,
	owners: [format.COUNTS_OF_A_PAGE]u16,
}

// leaf_is_wrong says if a leaf is in the list of the wrong leaves.
leaf_is_wrong :: proc "contextless" (counts: ^Counts, first: u64) -> bool {
	for wrong in counts.wrong_leaves[:counts.wrong_leaf_count] {
		if wrong == first {
			return true
		}
	}
	return false
}

// leaf_repaired gives the counts of a leaf that a repair counted again, or
// nil.
leaf_repaired :: proc "contextless" (counts: ^Counts, first: u64) -> ^Repaired_Leaf {
	return repaired_find(counts.repaired, first)
}

// repaired_find finds a leaf in repaired leaves in the order of their first
// block, or nil: the walk of a repair asks it at each name.
repaired_find :: proc "contextless" (leaves: []Repaired_Leaf, first: u64) -> ^Repaired_Leaf {
	low, high := 0, len(leaves)
	for low < high {
		middle := (low + high) / 2
		if leaves[middle].first < first {
			low = middle + 1
		} else {
			high = middle
		}
	}
	if low < len(leaves) && leaves[low].first == first {
		return &leaves[low]
	}
	return nil
}

// directory_is_wrong says if a directory of level 1 is in the list of the
// wrong directories.
directory_is_wrong :: proc "contextless" (counts: ^Counts, first: u64) -> bool {
	for wrong in counts.wrong_directories[:counts.wrong_directory_count] {
		if wrong == first {
			return true
		}
	}
	return false
}

// leaf_wrong_note keeps a leaf in the list of the wrong leaves.
@(private)
leaf_wrong_note :: proc "contextless" (counts: ^Counts, first: u64) {
	if leaf_is_wrong(counts, first) {
		return
	}
	if counts.wrong_leaf_count < WRONG_LEAVES_MOST {
		counts.wrong_leaves[counts.wrong_leaf_count] = first
		counts.wrong_leaf_count += 1
	} else {
		counts.wrong_leaves_full = true
	}
}

// directory_wrong_note keeps a wrong directory: one of level 1 and each
// leaf under it, which a repair counts and makes again; one above level 1
// has more leaves than a repair holds, and its damage is not known whole.
@(private)
directory_wrong_note :: proc "contextless" (counts: ^Counts, level: int, first: u64) {
	if level != 1 {
		counts.wrong_leaves_full = true
		return
	}
	if directory_is_wrong(counts, first) {
		return
	}
	if counts.wrong_directory_count >= WRONG_DIRECTORIES_MOST {
		counts.wrong_leaves_full = true
		return
	}
	counts.wrong_directories[counts.wrong_directory_count] = first
	counts.wrong_directory_count += 1
	for leaf := first; leaf < min(first + format.count_span(1), counts.disk_blocks); leaf += format.COUNTS_OF_A_PAGE {
		leaf_wrong_note(counts, leaf)
	}
}

// directories_written forgets the wrong directories that a commit made
// again: each leaf under them was repaired.
directories_written :: proc "contextless" (counts: ^Counts) {
	kept := 0
	for index in 0 ..< counts.wrong_directory_count {
		first := counts.wrong_directories[index]
		whole := true
		for leaf := first; leaf < min(first + format.count_span(1), counts.disk_blocks); leaf += format.COUNTS_OF_A_PAGE {
			whole &&= leaf_repaired(counts, leaf) != nil
		}
		if !whole {
			counts.wrong_directories[kept] = first
			kept += 1
		}
	}
	counts.wrong_directory_count = kept
}

// span_has_repaired says if a part of the disk holds a leaf that a repair
// counted: the free counts of the directories above it are not known.
@(private)
span_has_repaired :: proc "contextless" (counts: ^Counts, first: u64, span: u64) -> bool {
	for &leaf in counts.repaired {
		if leaf.first >= first && leaf.first - first < span {
			return true
		}
	}
	return false
}

// counts_bind gives a count tree its memory and its root. The frames hold
// at least COUNT_LEVEL_LIMIT + 2 pages, so that a read keeps a page of
// each level; slots has a length of a power of 2 at least twice the frames.
counts_bind :: proc "contextless" (counts: ^Counts, source: ^Source, root: Pointer, disk_blocks: u64, frames: []Frame, slots: []i32) -> bool {
	if len(frames) < format.COUNT_LEVEL_LIMIT + 2 || len(slots) < 2 * len(frames) || len(slots) & (len(slots) - 1) != 0 || !format.disk_blocks_valid(disk_blocks) {
		return false
	}
	counts^ = {source = source, root = root, levels = format.count_tree_levels(disk_blocks), disk_blocks = disk_blocks, frames = frames, slots = slots}
	for &frame in frames {
		frame.state = .Free
	}
	intrinsics.mem_zero(raw_data(slots), len(slots) * size_of(i32))
	return true
}

// counts_failure_clear forgets the failures of the reads before it.
counts_failure_clear :: proc "contextless" (counts: ^Counts) {
	counts.failure = .Good
	counts.failed_block = 0
}

@(private)
counts_fail :: proc "contextless" (counts: ^Counts, outcome: Read, block: u64) {
	if counts.failure == .Good {
		counts.failure = outcome
		counts.failed_block = block
	}
}

// page_first gives the first block of the page of a level that holds a block.
page_first :: proc "contextless" (level: int, number: u64) -> u64 {
	span := format.count_span(level)
	return number - number % span
}

@(private)
slot_home :: proc "contextless" (slots: []i32, level: int, first: u64) -> int {
	key := (first / format.count_span(level)) * 0x9E37_79B9_7F4A_7C15 + u64(level) * 0xC2B2_AE3D_27D4_EB4F
	key ~= key >> 31
	return int(key & u64(len(slots) - 1))
}

// frame_find gives the frame of a page in a set of frames, or nil.
@(private)
frame_find :: proc "contextless" (frames: []Frame, slots: []i32, level: int, first: u64) -> (frame: ^Frame, slot: int) {
	mask := len(slots) - 1
	at := slot_home(slots, level, first)
	for _ in 0 ..< len(slots) {
		held := slots[at]
		if held == 0 {
			return nil, at
		}
		candidate := &frames[held - 1]
		if candidate.state != .Free && candidate.level == level && candidate.first == first {
			return candidate, at
		}
		at = (at + 1) & mask
	}
	return nil, -1
}

// slot_remove takes a frame out of an index: each later frame of its run
// whose home is not after the hole moves into it.
@(private)
slot_remove :: proc "contextless" (frames: []Frame, slots: []i32, hole_slot: int) {
	mask := len(slots) - 1
	hole := hole_slot
	slots[hole] = 0
	next := hole
	for {
		next = (next + 1) & mask
		held := slots[next]
		if held == 0 {
			return
		}
		moved := &frames[held - 1]
		home := slot_home(slots, moved.level, moved.first)
		if (hole - home) & mask < (next - home) & mask {
			slots[hole] = held
			slots[next] = 0
			hole = next
		}
	}
}

@(private)
slot_insert :: proc "contextless" (frames: []Frame, slots: []i32, index: int) {
	frame := &frames[index]
	mask := len(slots) - 1
	at := slot_home(slots, frame.level, frame.first)
	for slots[at] != 0 {
		at = (at + 1) & mask
	}
	slots[at] = i32(index + 1)
}

// frame_evict gives a frame of the cache for a new page: a free one, or the
// clean frame that the hand finds first with no use since its last pass.
@(private)
frame_evict :: proc "contextless" (counts: ^Counts) -> int {
	for _ in 0 ..< 2 * len(counts.frames) + 1 {
		index := counts.hand
		counts.hand = (counts.hand + 1) % len(counts.frames)
		frame := &counts.frames[index]
		if frame.state == .Free {
			return index
		}
		if frame.referenced {
			frame.referenced = false
			continue
		}
		_, slot := frame_find(counts.frames, counts.slots, frame.level, frame.first)
		if slot >= 0 && counts.slots[slot] == i32(index + 1) {
			slot_remove(counts.frames, counts.slots, slot)
		}
		frame.state = .Free
		return index
	}
	return -1
}

// page_valid says if the bytes of a page are a page of its level and place.
// Only the top directory names leaves to recount, at most each leaf.
@(private)
page_valid :: proc "contextless" (counts: ^Counts, bytes: ^Block, level: int, first: u64) -> bool {
	if level == 0 {
		page := (^format.Count_Page)(bytes)
		return page.magic == format.COUNT_PAGE_MAGIC && page.level == 0 && page.first == first
	}
	directory := (^format.Count_Directory)(bytes)
	recount_limit := level == counts.levels ? format.count_tree_leaves(counts.disk_blocks) : 0
	return directory.magic == format.COUNT_DIRECTORY_MAGIC && int(directory.level) == level && directory.first == first && directory.leaves_to_recount <= recount_limit
}

// page_get gives the frame of the page of a level that starts at first, as
// the root names it: nil with Good for a page that no directory names (each
// count under it is 0). A wrong or unread page gives its outcome, which the
// counts keep as their failure. The frame stays valid until the next call.
page_get :: proc "contextless" (counts: ^Counts, level: int, first: u64) -> (frame: ^Frame, outcome: Read) {
	if level > counts.levels || counts.root.block == 0 {
		return nil, .Good
	}
	if found, _ := frame_find(counts.frames, counts.slots, level, first); found != nil {
		found.referenced = true
		return found, .Good
	}
	// A wrong directory is not read again: its pointers stay unknown.
	if level == 1 && directory_is_wrong(counts, first) {
		counts_fail(counts, .Wrong, 0)
		return nil, .Wrong
	}
	pointer: Pointer
	if level == counts.levels {
		if first != 0 {
			return nil, .Good
		}
		pointer = counts.root
	} else {
		parent, parent_outcome := page_get(counts, level + 1, page_first(level + 1, first))
		if parent_outcome != .Good || parent == nil {
			return nil, parent_outcome
		}
		directory := (^format.Count_Directory)(&parent.bytes)
		place := (first - directory.first) / format.count_span(level)
		child := directory.children[place]
		if child.block == 0 {
			return nil, .Good
		}
		pointer = {block = child.block, check = child.check}
	}
	index := frame_evict(counts)
	if index < 0 {
		counts_fail(counts, .Device, pointer.block)
		return nil, .Device
	}
	frame = &counts.frames[index]
	if pointer.block < 2 || pointer.block >= counts.disk_blocks {
		counts_fail(counts, .Wrong, pointer.block)
		return nil, .Wrong
	}
	if !counts.source.read(counts.source, pointer.block, &frame.bytes) {
		counts_fail(counts, .Device, pointer.block)
		return nil, .Device
	}
	if format.check(frame.bytes[:]) != pointer.check || !page_valid(counts, &frame.bytes, level, first) {
		counts_fail(counts, .Wrong, pointer.block)
		if level == 0 {
			leaf_wrong_note(counts, first)
		} else {
			directory_wrong_note(counts, level, first)
		}
		return nil, .Wrong
	}
	frame.level, frame.first, frame.block = level, first, pointer.block
	frame.state = .Clean
	frame.referenced = true
	slot_insert(counts.frames, counts.slots, index)
	if level == counts.levels {
		counts.leaves_to_recount = (^format.Count_Directory)(&frame.bytes).leaves_to_recount
	}
	return frame, .Good
}

// leaf_in_use_next gives the first leaf at or after the leaf that holds
// `from` that can hold a block in use, or disk_blocks when none can: a
// child whose free count is each block under it is passed whole, with no
// read under it. A page that cannot be read gives its outcome and the
// leaf where the search stopped.
leaf_in_use_next :: proc "contextless" (counts: ^Counts, from: u64) -> (first: u64, outcome: Read) {
	number := page_first(0, from)
	if counts.root.block == 0 {
		return counts.disk_blocks, .Good
	}
	search: for number < counts.disk_blocks {
		for level := counts.levels; level >= 1; level -= 1 {
			// A wrong directory is not read again: its leaves are taken.
			if level == 1 && directory_is_wrong(counts, page_first(1, number)) {
				return number, .Good
			}
			directory, read := page_get(counts, level, page_first(level, number))
			if read != .Good {
				return number, read
			}
			if directory == nil {
				return number, .Good
			}
			page := (^format.Count_Directory)(&directory.bytes)
			span := format.count_span(level - 1)
			place := (number - page.first) / span
			child := page.children[place]
			child_first := page.first + place * span
			if child.block == 0 || child.free >= format.count_free_blocks(level - 1, child_first, counts.disk_blocks) {
				number = child_first + span
				continue search
			}
		}
		return number, .Good
	}
	return counts.disk_blocks, .Good
}

// count_get gives the count of names and the owner of a block, as the root
// names them.
count_get :: proc "contextless" (counts: ^Counts, number: u64) -> (count: u32, owner: u16, outcome: Read) {
	if number >= counts.disk_blocks {
		return 0, 0, .Good
	}
	if repaired := leaf_repaired(counts, page_first(0, number)); repaired != nil {
		place := number - repaired.first
		return repaired.counts[place], repaired.owners[place], .Good
	}
	leaf: ^Frame
	leaf, outcome = page_get(counts, 0, page_first(0, number))
	if leaf == nil {
		return 0, 0, outcome
	}
	page := (^format.Count_Page)(&leaf.bytes)
	place := number - page.first
	return page.counts[place], page.owners[place], .Good
}

// The search of a free block. taken says if the caller holds a block that
// the root gives as free (a block of the commit in progress).
Taken :: #type proc "contextless" (data: rawptr, number: u64) -> bool

// free_search gives the first block from \`from\`, then from block 2, whose
// count is 0 and that taken does not hold, or 0 when the disk has none.
// A directory child with no free block is passed whole.
free_search :: proc "contextless" (counts: ^Counts, from: u64, taken: Taken, data: rawptr) -> u64 {
	start := clamp(from, 2, max(counts.disk_blocks, 2))
	for pass in 0 ..< 2 {
		number := pass == 0 ? start : 2
		end := pass == 0 ? counts.disk_blocks : start
		for number < end {
			skip := free_skip(counts, number)
			if skip > number {
				number = skip
				continue
			}
			leaf_first := page_first(0, number)
			leaf_end := min(leaf_first + format.COUNTS_OF_A_PAGE, end)
			// A leaf that a repair counted and no commit wrote yet gives its
			// counts from the memory of the repair: the commit of the repair
			// takes its pages there too, on a disk with no other free block.
			if repaired := leaf_repaired(counts, leaf_first); repaired != nil {
				for ; number < leaf_end; number += 1 {
					if number >= 2 && repaired.counts[number - leaf_first] == 0 && (taken == nil || !taken(data, number)) {
						return number
					}
				}
				continue
			}
			// A wrong leaf is passed: its blocks wait for the repair.
			if leaf_is_wrong(counts, leaf_first) {
				number = leaf_end
				continue
			}
			leaf, outcome := page_get(counts, 0, leaf_first)
			if outcome == .Wrong && page_first(0, number) == leaf_first && leaf_is_wrong(counts, leaf_first) {
				number = leaf_end
				continue
			}
			if outcome != .Good {
				return 0
			}
			for ; number < leaf_end; number += 1 {
				free := leaf == nil || (^format.Count_Page)(&leaf.bytes).counts[number % format.COUNTS_OF_A_PAGE] == 0
				if free && (taken == nil || !taken(data, number)) {
					return number
				}
			}
		}
	}
	return 0
}

// free_skip gives the first block past the largest page that holds
// \`number\` and has no free block, as the directories count them, or
// number itself.
@(private)
free_skip :: proc "contextless" (counts: ^Counts, number: u64) -> u64 {
	for level := counts.levels; level >= 1; level -= 1 {
		// A wrong directory is not read again.
		if level == 1 && directory_is_wrong(counts, page_first(1, number)) {
			return number
		}
		directory, outcome := page_get(counts, level, page_first(level, number))
		if outcome != .Good || directory == nil {
			return number
		}
		page := (^format.Count_Directory)(&directory.bytes)
		place := (number - page.first) / format.count_span(level - 1)
		child := page.children[place]
		// The free count of a child with a repaired leaf under it is the
		// count before the repair: the level below decides.
		if span_has_repaired(counts, page.first + place * format.count_span(level - 1), format.count_span(level - 1)) {
			continue
		}
		if child.free == 0 && (child.block != 0 || format.count_free_blocks(level - 1, page.first + place * format.count_span(level - 1), counts.disk_blocks) == 0) {
			return page.first + (place + 1) * format.count_span(level - 1)
		}
	}
	return number
}
