#+build !freestanding
package block_counts

import "base:runtime"
import "core:testing"
import format "modus:contract/store"

// A disk in memory, the counts that the plan of a commit gives, and the
// commit of the new pages, as the storage service does it.
@(private = "file")
Test_Disk :: struct {
	source:  Source,
	blocks:  map[u64]Block,
	counts:  map[u64][2]u64, // The truth: count and owner of each block with a count.
	taken:   map[u64]bool, // The blocks that the commit in progress took.
	tree:    Counts,
	frames:  []Frame,
	slots:   []i32,
	commit:  Commit,
	staging: []Frame,
	staged_slots: []i32,
	reads:   int,
	broken:  map[u64]bool, // A read of these blocks fails on the device.
	disk_blocks: u64,
}

@(private = "file")
test_read :: proc "contextless" (source: ^Source, number: u64, into: ^Block) -> bool {
	disk := (^Test_Disk)(source.data)
	context = runtime.default_context()
	disk.reads += 1
	if disk.broken[number] {
		return false
	}
	into^ = disk.blocks[number] or_else Block{}
	return true
}

@(private = "file")
test_after :: proc "contextless" (commit: ^Commit, number: u64) -> (count: u32, owner: u16) {
	disk := (^Test_Disk)(commit.data)
	context = runtime.default_context()
	held := disk.counts[number] or_else [2]u64{}
	return u32(held[0]), u16(held[1])
}

@(private = "file")
test_take :: proc "contextless" (commit: ^Commit) -> u64 {
	disk := (^Test_Disk)(commit.data)
	context = runtime.default_context()
	number := free_search(&disk.tree, 2, proc "contextless" (data: rawptr, number: u64) -> bool {
		disk := (^Test_Disk)(data)
		context = runtime.default_context()
		held := disk.counts[number] or_else [2]u64{}
		return held[0] != 0 || disk.taken[number]
	}, disk)
	if number == 0 {
		return 0
	}
	disk.taken[number] = true
	disk.counts[number] = {1, u64(format.COUNT_TREE_OWNER)}
	commit_leaf_add(commit, number)
	return number
}

@(private = "file")
test_release :: proc "contextless" (commit: ^Commit, number: u64) {
	disk := (^Test_Disk)(commit.data)
	context = runtime.default_context()
	delete_key(&disk.counts, number)
	commit_leaf_add(commit, number)
}

@(private = "file")
disk_make :: proc(disk_blocks: u64, frames: int = 64, staging: int = 256) -> ^Test_Disk {
	disk := new(Test_Disk)
	disk.disk_blocks = disk_blocks
	disk.source = {read = test_read, data = disk}
	disk.frames = make([]Frame, frames)
	disk.slots = make([]i32, power_of_two_at_least(2 * frames))
	disk.staging = make([]Frame, staging)
	disk.staged_slots = make([]i32, power_of_two_at_least(2 * staging))
	disk.commit = {after = test_after, take = test_take, release = test_release, data = disk}
	ok := counts_bind(&disk.tree, &disk.source, {}, disk_blocks, disk.frames, disk.slots)
	assert(ok)
	return disk
}

@(private = "file")
power_of_two_at_least :: proc(count: int) -> int {
	size := 1
	for size < count {
		size *= 2
	}
	return size
}

@(private = "file")
disk_free :: proc(disk: ^Test_Disk) {
	delete(disk.blocks)
	delete(disk.counts)
	delete(disk.taken)
	delete(disk.broken)
	delete(disk.frames)
	delete(disk.slots)
	delete(disk.staging)
	delete(disk.staged_slots)
	free(disk)
}

// disk_commit makes the pages of a commit that changes the counts of
// \`changed\` (the truth already holds them), writes them, and installs them.
@(private = "file")
disk_commit :: proc(disk: ^Test_Disk, changed: []u64) -> (root: Pointer, failure: Commit_Failure) {
	clear(&disk.taken)
	ok := commit_begin(&disk.commit, &disk.tree, disk.staging, disk.staged_slots)
	assert(ok)
	for number in changed {
		commit_leaf_add(&disk.commit, number)
	}
	made: bool
	root, made = commit_finish(&disk.commit)
	if !made {
		failure = disk.commit.failure
		commit_drop(&disk.commit)
		return {}, failure
	}
	for &page in disk.commit.staging[:disk.commit.staged] {
		disk.blocks[page.block] = page.bytes
	}
	commit_install(&disk.commit, root)
	return root, .None
}

// disk_expect reads each block of the disk through a new reader with the
// least cache and compares it with the truth, and each free count of the
// top directory with the truth.
@(private = "file")
disk_expect :: proc(t: ^testing.T, disk: ^Test_Disk, label: string) {
	frames := make([]Frame, format.COUNT_LEVEL_LIMIT + 2)
	defer delete(frames)
	slots := make([]i32, 32)
	defer delete(slots)
	reader: Counts
	testing.expect(t, counts_bind(&reader, &disk.source, disk.tree.root, disk.disk_blocks, frames, slots))
	free_blocks: u64
	for number in u64(0) ..< min(disk.disk_blocks, 4096) {
		count, owner, outcome := count_get(&reader, number)
		held := disk.counts[number] or_else [2]u64{}
		if !testing.expectf(t, outcome == .Good && u64(count) == held[0] && u64(owner) == held[1], "%s: block %d has %d of %d, not %v", label, number, count, owner, held) {
			return
		}
		if count == 0 && number >= 2 {
			free_blocks += 1
		}
	}
	if disk.disk_blocks <= 4096 {
		top, outcome := page_get(&reader, reader.levels, 0)
		testing.expect(t, outcome == .Good && top != nil)
		directory := (^format.Count_Directory)(&top.bytes)
		sum: u64
		for child in directory.children {
			sum += child.free
		}
		testing.expectf(t, sum == free_blocks, "%s: the directory counts %d free blocks, not %d", label, sum, free_blocks)
	}
}

// The tree grows from no tree, at the first and the last blocks of the
// disk, at the edges of a leaf (511, 512, 513), and the counts of its own
// pages are in it.
@(test)
a_tree_grows_from_no_tree :: proc(t: ^testing.T) {
	disk := disk_make(2000)
	defer disk_free(disk)
	// No tree: each count is 0.
	count, owner, outcome := count_get(&disk.tree, 1999)
	testing.expect(t, count == 0 && owner == 0 && outcome == .Good)
	// No change: no page, the same root.
	root, failure := disk_commit(disk, nil)
	testing.expect(t, failure == .None && root == {})
	changed := [?]u64{2, 511, 512, 513, 1999}
	for number in changed {
		disk.counts[number] = {1, 7}
	}
	root, failure = disk_commit(disk, changed[:])
	testing.expect_value(t, failure, Commit_Failure.None)
	testing.expect(t, root.block != 0)
	disk_expect(t, disk, "first commit")
	// The pages of the tree are counted in the tree: each one block of
	// count 1 with the owner of the tree.
	tree_blocks := 0
	for _, held in disk.counts {
		if held[1] == u64(format.COUNT_TREE_OWNER) {
			tree_blocks += 1
		}
	}
	// Leaves 0, 1 and 3 and the top directory, and the leaves of their own
	// blocks, which the first free blocks put in leaf 0.
	testing.expect_value(t, tree_blocks, 4)
	// A second commit: the pages before are released, the new ones counted.
	disk.counts[2] = {2, 7}
	delete_key(&disk.counts, 1999)
	root, failure = disk_commit(disk, {2, 1999})
	testing.expect_value(t, failure, Commit_Failure.None)
	disk_expect(t, disk, "second commit")
}

// The geometry at its edges: a disk of 513 blocks has two leaves, and a
// disk of 2^30 blocks three levels of directories, with pages only where
// a count is not 0.
@(test)
the_levels_follow_the_disk :: proc(t: ^testing.T) {
	testing.expect_value(t, format.count_tree_levels(2), 1)
	testing.expect_value(t, format.count_tree_levels(65536), 1)
	testing.expect_value(t, format.count_tree_levels(65537), 2)
	testing.expect_value(t, format.count_tree_levels(u64(1) << 30), 3)
	testing.expect_value(t, format.count_tree_levels((u64(1) << 30) + 1), 4)
	testing.expect_value(t, format.count_tree_levels(format.DISK_BLOCKS_MAX), format.COUNT_LEVEL_LIMIT)
	testing.expect(t, format.count_span(format.COUNT_LEVEL_LIMIT) >= format.DISK_BLOCKS_MAX)
	testing.expect_value(t, format.count_free_blocks(0, 0, 513), u64(510))
	testing.expect_value(t, format.count_free_blocks(0, 512, 513), u64(1))
	testing.expect_value(t, format.count_free_blocks(0, 1024, 513), u64(0))
	testing.expect_value(t, format.count_free_blocks(format.COUNT_LEVEL_LIMIT, 0, format.DISK_BLOCKS_MAX), format.DISK_BLOCKS_MAX - 2)

	large := disk_make(u64(1) << 30)
	defer disk_free(large)
	last := (u64(1) << 30) - 1
	large.counts[last] = {3, 2}
	_, failure := disk_commit(large, {last})
	testing.expect_value(t, failure, Commit_Failure.None)
	count, owner, outcome := count_get(&large.tree, last)
	testing.expect(t, count == 3 && owner == 2 && outcome == .Good, "the last block of a disk of 2^30 blocks")
	// One leaf and a directory on each level for the last block, one leaf
	// and its directories for the pages near block 2.
	testing.expect(t, len(large.blocks) <= 2 * (1 + format.count_tree_levels(u64(1) << 30)), "a sparse tree")
}

// The blocks of the pages come from leaves that the commit stages
// already, until no leaf is added: with leaf 0 full, the pages take
// blocks of another leaf, which the commit stages and counts.
@(test)
the_pages_of_a_commit_count_themselves :: proc(t: ^testing.T) {
	disk := disk_make(4096)
	defer disk_free(disk)
	changed := make([dynamic]u64, context.temp_allocator)
	for number in u64(2) ..< 512 {
		disk.counts[number] = {1, 1}
		append(&changed, number)
	}
	_, failure := disk_commit(disk, changed[:])
	testing.expect_value(t, failure, Commit_Failure.None)
	disk_expect(t, disk, "leaf 0 full")
	for number in u64(2) ..< 512 {
		count, _, _ := count_get(&disk.tree, number)
		testing.expect(t, count == 1, "leaf 0 keeps its counts")
	}
	disk.counts[100] = {2, 1}
	_, failure = disk_commit(disk, {100})
	testing.expect_value(t, failure, Commit_Failure.None)
	disk_expect(t, disk, "a change in a full leaf")
}

// A staging too small for the pages of a commit refuses it, and the tree
// before stays whole: the same root, the same counts.
@(test)
a_staging_too_small_refuses_and_changes_nothing :: proc(t: ^testing.T) {
	disk := disk_make(100_000, 64, 3)
	defer disk_free(disk)
	disk.counts[5] = {1, 1}
	root_before, failure := disk_commit(disk, {5})
	testing.expect_value(t, failure, Commit_Failure.None)
	before := disk.tree.root
	// Three leaves and two directories: more than three pages.
	for number in ([?]u64{70_000, 80_000, 90_000}) {
		disk.counts[number] = {1, 1}
	}
	_, failure = disk_commit(disk, {70_000, 80_000, 90_000})
	testing.expect_value(t, failure, Commit_Failure.Full)
	testing.expect_value(t, disk.tree.root, before)
	testing.expect_value(t, disk.tree.root, root_before)
	count, _, _ := count_get(&disk.tree, 70_000)
	testing.expect_value(t, count, u32(0))
	count, _, _ = count_get(&disk.tree, 5)
	testing.expect_value(t, count, u32(1))
}

// A wrong page and a failed read: the read gives its outcome and the
// counts keep it; a commit that needs the directory refuses with it.
@(test)
a_wrong_page_is_refused :: proc(t: ^testing.T) {
	disk := disk_make(2000)
	defer disk_free(disk)
	disk.counts[600] = {1, 3}
	_, failure := disk_commit(disk, {600})
	testing.expect_value(t, failure, Commit_Failure.None)
	// A byte of the leaf of block 600 changes on the disk; the cache is
	// cold.
	frames := make([]Frame, format.COUNT_LEVEL_LIMIT + 2)
	defer delete(frames)
	slots := make([]i32, 32)
	defer delete(slots)
	reader: Counts
	testing.expect(t, counts_bind(&reader, &disk.source, disk.tree.root, disk.disk_blocks, frames, slots))
	top, _ := page_get(&reader, reader.levels, 0)
	leaf_block := (^format.Count_Directory)(&top.bytes).children[1].block
	bytes := disk.blocks[leaf_block]
	bytes[100] ~= 1
	disk.blocks[leaf_block] = bytes
	_, _, outcome := count_get(&reader, 600)
	testing.expect_value(t, outcome, Read.Wrong)
	testing.expect_value(t, reader.failure, Read.Wrong)
	testing.expect_value(t, reader.failed_block, leaf_block)
	// The top directory read fails on the device.
	disk.broken[disk.tree.root.block] = true
	cold: Counts
	testing.expect(t, counts_bind(&cold, &disk.source, disk.tree.root, disk.disk_blocks, frames, slots))
	_, _, outcome = count_get(&cold, 5)
	testing.expect_value(t, outcome, Read.Device)
	disk.tree = cold
	disk.counts[5] = {1, 1}
	_, failure = disk_commit(disk, {5})
	testing.expect_value(t, failure, Commit_Failure.Device)
}

// counts_bind refuses memory that cannot hold a read, an index that is not
// a power of two, and a disk of fewer blocks than the two places of the
// root.
@(test)
counts_bind_refuses_its_wrong_memory :: proc(t: ^testing.T) {
	source: Source
	reader: Counts
	enough := make([]Frame, format.COUNT_LEVEL_LIMIT + 2)
	defer delete(enough)
	too_few := enough[:format.COUNT_LEVEL_LIMIT + 1]
	slots := make([]i32, 64)
	defer delete(slots)
	testing.expect(t, !counts_bind(&reader, &source, {}, 100, too_few, slots[:32]))
	testing.expect(t, !counts_bind(&reader, &source, {}, 100, enough, slots[:30]))
	testing.expect(t, !counts_bind(&reader, &source, {}, 100, enough, slots[:16]))
	testing.expect(t, !counts_bind(&reader, &source, {}, 1, enough, slots[:32]))
	testing.expect(t, !counts_bind(&reader, &source, {}, 0, enough, slots[:32]))
	testing.expect(t, counts_bind(&reader, &source, {}, 2, enough, slots[:32]))
}

// The search of a free block: the first block of count 0 from a place, the
// blocks that the caller holds passed, a wrap to block 2, and 0 for a full
// disk.
@(test)
free_search_finds_the_next_free_block :: proc(t: ^testing.T) {
	disk := disk_make(1200)
	defer disk_free(disk)
	changed := make([dynamic]u64, context.temp_allocator)
	// Two free blocks among the used ones, and the last 100 blocks free.
	for number in u64(2) ..< 1100 {
		if number != 700 && number != 3 {
			disk.counts[number] = {1, 1}
			append(&changed, number)
		}
	}
	_, failure := disk_commit(disk, changed[:])
	testing.expect_value(t, failure, Commit_Failure.None)
	disk_expect(t, disk, "a disk nearly full")
	// The pages took two free blocks: find what is left.
	free_left := make([dynamic]u64, context.temp_allocator)
	for number in u64(2) ..< 1200 {
		if count, _, _ := count_get(&disk.tree, number); count == 0 {
			append(&free_left, number)
		}
	}
	none :: proc "contextless" (data: rawptr, number: u64) -> bool {return false}
	if len(free_left) > 0 {
		testing.expect_value(t, free_search(&disk.tree, 2, none, nil), free_left[0])
		last := free_left[len(free_left) - 1]
		testing.expect_value(t, free_search(&disk.tree, last, none, nil), last)
		testing.expect_value(t, free_search(&disk.tree, last + 1, none, nil), free_left[0])
	}
	all :: proc "contextless" (data: rawptr, number: u64) -> bool {return true}
	testing.expect_value(t, free_search(&disk.tree, 2, all, nil), u64(0))
}

// A commit whose pages find no free block refuses with No_Block, and the
// tree before stays.
@(test)
a_full_disk_refuses_the_pages :: proc(t: ^testing.T) {
	disk := disk_make(600)
	defer disk_free(disk)
	changed := make([dynamic]u64, context.temp_allocator)
	for number in u64(2) ..< 599 {
		disk.counts[number] = {1, 1}
		append(&changed, number)
	}
	// One free block, 599: two leaves and a directory need three.
	_, failure := disk_commit(disk, changed[:])
	testing.expect_value(t, failure, Commit_Failure.No_Block)
	testing.expect_value(t, disk.tree.root, Pointer{})
}

// The counts after a commit, read through the cache of the tree as the
// service reads them: with the least cache, a leaf leaves it between two
// reads. A read that fails on the device then refuses the commit, and the
// tree stays as it was; no page holds a count of 0 for a block in use.
@(test)
a_failed_read_of_a_count_refuses_the_commit :: proc(t: ^testing.T) {
	disk := disk_make(200_000, format.COUNT_LEVEL_LIMIT + 2)
	defer disk_free(disk)
	changed := make([dynamic]u64, context.temp_allocator)
	for number in ([?]u64{5, 70_000, 140_000, 199_000}) {
		disk.counts[number] = {1, 1}
		append(&changed, number)
	}
	_, failure := disk_commit(disk, changed[:])
	testing.expect_value(t, failure, Commit_Failure.None)
	before := disk.tree.root
	// The plan reads the count before through the tree, and adds one.
	through_tree :: proc "contextless" (commit: ^Commit, number: u64) -> (count: u32, owner: u16) {
		disk := (^Test_Disk)(commit.data)
		context = runtime.default_context()
		if held, found := disk.counts[number]; found && held[1] == u64(format.COUNT_TREE_OWNER) {
			return u32(held[0]), u16(held[1])
		}
		count, owner, _ = count_get(&disk.tree, number)
		if number == 140_000 {
			count += 1
		}
		return count, owner
	}
	disk.commit.after = through_tree
	defer disk.commit.after = test_after
	// The leaf of block 199 000 fails on the device from now on, and the
	// cache is cold: the plan reads it again.
	for number, bytes in disk.blocks {
		copied := bytes
		page := (^format.Count_Page)(&copied)
		if page.magic == format.COUNT_PAGE_MAGIC && page.first == page_first(0, 199_000) {
			disk.broken[number] = true
		}
	}
	testing.expect(t, counts_bind(&disk.tree, &disk.source, before, disk.disk_blocks, disk.frames, disk.slots))
	counts_failure_clear(&disk.tree)
	_, failure = disk_commit(disk, {140_000, 199_000})
	testing.expect_value(t, failure, Commit_Failure.Device)
	testing.expect_value(t, disk.tree.root, before)
}
