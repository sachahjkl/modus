package block_counts

import "base:intrinsics"
import format "modus:contract/store"

// Why the new pages of a commit could not be made.
Commit_Failure :: enum u8 {
	None     = 0,
	Full     = 1, // The staging holds no more pages: the commit changes the counts of too many leaves.
	No_Block = 2, // The disk has no free block for a page.
	Wrong    = 3, // A page of the tree before has a wrong check: its other counts are not known.
	Device   = 4, // The device reported an error at the read of a page of the tree before.
}

// The new pages of one commit. The caller gives the counts after its plan
// (after), takes a block for each new page (take: the caller counts it with
// the owner of the count tree and adds its leaf), and drops the name of
// each page that a new page replaces (release: the caller counts one name
// less and adds its leaf). The pages are copies in the staging: nothing of
// the counts changes until commit_install.
Commit :: struct {
	counts:       ^Counts,
	staging:      []Frame, // Memory of the caller.
	staged:       int,
	staged_slots: []i32, // The index of the staged pages: a power of 2, at least twice the staging.
	after:        proc "contextless" (commit: ^Commit, number: u64) -> (count: u32, owner: u16),
	take:         proc "contextless" (commit: ^Commit) -> u64,
	release:      proc "contextless" (commit: ^Commit, number: u64),
	data:         rawptr,
	failure:      Commit_Failure,
}

// commit_begin starts the new pages of a commit on a count tree.
commit_begin :: proc "contextless" (commit: ^Commit, counts: ^Counts, staging: []Frame, staged_slots: []i32) -> bool {
	if len(staged_slots) < 2 * len(staging) || len(staged_slots) & (len(staged_slots) - 1) != 0 {
		return false
	}
	commit.counts = counts
	commit.staging = staging
	commit.staged_slots = staged_slots
	commit.staged = 0
	commit.failure = .None
	intrinsics.mem_zero(raw_data(staged_slots), len(staged_slots) * size_of(i32))
	return true
}

@(private)
commit_fail :: proc "contextless" (commit: ^Commit, failure: Commit_Failure) {
	if commit.failure == .None {
		commit.failure = failure
	}
}

// commit_staged gives the staged page of a level that starts at first, or nil.
commit_staged :: proc "contextless" (commit: ^Commit, level: int, first: u64) -> ^Frame {
	frame, _ := frame_find(commit.staging[:commit.staged], commit.staged_slots, level, first)
	return frame
}

// stage puts a page of a level in the staging, with the block of the page
// that it replaces, and each directory above it. Its bytes come later.
@(private)
stage :: proc "contextless" (commit: ^Commit, level: int, first: u64) {
	for at := level; at <= commit.counts.levels; at += 1 {
		page := page_first(at, first)
		if commit_staged(commit, at, page) != nil {
			return
		}
		if commit.staged == len(commit.staging) {
			commit_fail(commit, .Full)
			return
		}
		old_block: u64
		if at == commit.counts.levels {
			old_block = commit.counts.root.block
		} else if commit.counts.root.block != 0 {
			parent, outcome := page_get(commit.counts, at + 1, page_first(at + 1, page))
			switch outcome {
			case .Good:
			case .Wrong:
				commit_fail(commit, .Wrong)
				return
			case .Device:
				commit_fail(commit, .Device)
				return
			}
			if parent != nil {
				directory := (^format.Count_Directory)(&parent.bytes)
				old_block = directory.children[(page - directory.first) / format.count_span(at)].block
			}
		}
		index := commit.staged
		commit.staged += 1
		commit.staging[index] = {first = page, level = at, old_block = old_block, state = .Staged}
		slot_insert(commit.staging, commit.staged_slots, index)
	}
}

// commit_leaf_add stages the leaf that holds a block whose count or owner
// the commit changes, and its directories. The failure Full says that the
// staging holds no more.
commit_leaf_add :: proc "contextless" (commit: ^Commit, number: u64) {
	if number >= commit.counts.disk_blocks || commit.failure != .None {
		return
	}
	stage(commit, 0, page_first(0, number))
}

// commit_finish gives each staged page a new block, until no page is added
// (the new blocks and the blocks that they replace change the counts of
// their leaves), then makes the bytes of each page from the counts after
// the commit, from the leaves up, and gives the new root of the tree. The
// pages to write are commit.staging[:commit.staged], each with its block.
commit_finish :: proc "contextless" (commit: ^Commit) -> (root: Pointer, ok: bool) {
	if commit.staged == 0 {
		return commit.counts.root, commit.failure == .None
	}
	// The new blocks: a pass can stage more pages, which the next pass sees.
	for taken := 0; taken < commit.staged && commit.failure == .None; taken += 1 {
		frame := &commit.staging[taken]
		frame.block = commit.take(commit)
		if frame.block == 0 {
			commit_fail(commit, .No_Block)
			break
		}
		if frame.old_block != 0 {
			commit.release(commit, frame.old_block)
		}
	}
	if commit.failure != .None {
		return {}, false
	}
	for level in 0 ..= commit.counts.levels {
		for &frame in commit.staging[:commit.staged] {
			if frame.level != level {
				continue
			}
			if level == 0 {
				leaf_fill(commit, &frame)
			} else if !directory_fill(commit, &frame) {
				return {}, false
			}
		}
	}
	top := commit_staged(commit, commit.counts.levels, 0)
	return {block = top.block, check = format.check(top.bytes[:])}, true
}

// leaf_fill makes the bytes of a staged leaf from the counts after the
// commit.
@(private)
leaf_fill :: proc "contextless" (commit: ^Commit, frame: ^Frame) {
	intrinsics.mem_zero(&frame.bytes, size_of(Block))
	page := (^format.Count_Page)(&frame.bytes)
	page.magic = format.COUNT_PAGE_MAGIC
	page.first = frame.first
	frame.free = 0
	for place in 0 ..< format.COUNTS_OF_A_PAGE {
		number := frame.first + u64(place)
		if number >= commit.counts.disk_blocks {
			break
		}
		page.counts[place], page.owners[place] = commit.after(commit, number)
		if page.counts[place] == 0 && number >= 2 {
			frame.free += 1
		}
	}
}

// directory_fill makes the bytes of a staged directory: the children of the
// directory before, each staged child in place of its old one.
@(private)
directory_fill :: proc "contextless" (commit: ^Commit, frame: ^Frame) -> bool {
	counts := commit.counts
	span := format.count_span(frame.level - 1)
	before: ^Frame
	if counts.root.block != 0 {
		outcome: Read
		before, outcome = page_get(counts, frame.level, frame.first)
		if outcome != .Good {
			commit_fail(commit, outcome == .Device ? .Device : .Wrong)
			return false
		}
	}
	if before != nil {
		frame.bytes = before.bytes
	} else {
		intrinsics.mem_zero(&frame.bytes, size_of(Block))
	}
	directory := (^format.Count_Directory)(&frame.bytes)
	directory.magic = format.COUNT_DIRECTORY_MAGIC
	directory.level = u32(frame.level)
	directory.first = frame.first
	frame.free = 0
	for &child, place in directory.children {
		child_first := frame.first + u64(place) * span
		if staged := commit_staged(commit, frame.level - 1, child_first); staged != nil {
			child = {block = staged.block, check = format.check(staged.bytes[:]), free = staged.free}
		} else if child.block == 0 {
			child.free = format.count_free_blocks(frame.level - 1, child_first, counts.disk_blocks)
		}
		frame.free += child.free
	}
	return true
}

// commit_install makes the staged pages the pages of the tree: the root of
// the disk names the new top directory now. The cache drops each page that
// the commit replaced.
commit_install :: proc "contextless" (commit: ^Commit, root: Pointer) {
	counts := commit.counts
	for &staged in commit.staging[:commit.staged] {
		if cached, slot := frame_find(counts.frames, counts.slots, staged.level, staged.first); cached != nil {
			slot_remove(counts.frames, counts.slots, slot)
			cached.state = .Free
		}
	}
	// The new pages stay in the cache: the next commit reads the same
	// directories, and the leaves of its blocks.
	for &staged in commit.staging[:commit.staged] {
		index := frame_evict(counts)
		if index < 0 {
			break
		}
		frame := &counts.frames[index]
		frame.bytes = staged.bytes
		frame.level, frame.first, frame.block = staged.level, staged.first, staged.block
		frame.state = .Clean
		frame.referenced = false
		slot_insert(counts.frames, counts.slots, index)
	}
	counts.root = root
	commit.staged = 0
}

// commit_drop forgets the staged pages: the counts are those of the tree
// before.
commit_drop :: proc "contextless" (commit: ^Commit) {
	commit.staged = 0
	commit.failure = .None
}
