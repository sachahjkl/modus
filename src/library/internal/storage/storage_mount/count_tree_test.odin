#+build !freestanding
package storage_mount

import "base:runtime"
import "core:testing"
import format "modus:contract/store"
import "internal:storage/block_counts"

// The count tree of a test disk, made from the tables of an open of it: as
// a commit makes its pages, with the pages written to the next free blocks
// of the disk. skew changes the count of one block in the tree, so that the
// tree differs from the walk.
@(private = "file")
Tree_Build :: struct {
	state: ^State,
	disk:  ^Test_Disk,
	taken: map[u64]bool,
	skew:  u64,
}

@(private = "file")
build_after :: proc "contextless" (commit: ^block_counts.Commit, number: u64) -> (count: u32, owner: u16) {
	build := (^Tree_Build)(commit.data)
	context = runtime.default_context()
	if build.taken[number] {
		return 1, COUNT_TREE_OWNER
	}
	count = build.state.references[number]
	if number == build.skew && count != 0 {
		count += 1
	}
	return count, build.state.owner[number]
}

@(private = "file")
build_take :: proc "contextless" (commit: ^block_counts.Commit) -> u64 {
	build := (^Tree_Build)(commit.data)
	context = runtime.default_context()
	number := build.disk.next
	build.disk.next += 1
	build.taken[number] = true
	block_counts.commit_leaf_add(commit, number)
	return number
}

@(private = "file")
count_tree_write :: proc(t: ^testing.T, state: ^State, disk: ^Test_Disk, skew: u64 = 0) -> format.Pointer {
	build := Tree_Build{state = state, disk = disk, skew = skew}
	defer delete(build.taken)
	commit := &state.count_commit
	testing.expect(t, block_counts.commit_begin(commit, &state.counts, state.count_staging, state.count_staged_slots))
	commit.after = build_after
	commit.take = build_take
	commit.release = proc "contextless" (commit: ^block_counts.Commit, number: u64) {}
	commit.data = rawptr(&build)
	for number in 0 ..< state.disk_size {
		if state.references[number] != 0 {
			block_counts.commit_leaf_add(commit, number)
		}
	}
	root, made := block_counts.commit_finish(commit)
	testing.expect(t, made)
	for &page in commit.staging[:commit.staged] {
		copy(disk.bytes[page.block * BLOCK_SIZE:][:BLOCK_SIZE], page.bytes[:])
	}
	block_counts.commit_drop(commit)
	// The build lives on this stack only.
	commit.data = nil
	return root
}

// root_counts_set writes the root of block 0 again with a count tree.
@(private = "file")
root_counts_set :: proc(disk: ^Test_Disk, counts: format.Pointer, complete: u64) {
	root := (^format.Root)(raw_data(disk.bytes))
	root.counts = counts
	root.counts_complete = complete
	root.check = format.root_check(root)
}

// A State of the form Count_Tree for a disk: no table of each block.
@(private = "file")
tree_state_make :: proc(blocks: u64) -> (state: ^State, memory: []u64) {
	state = new(State)
	layout, ok := state_layout(blocks, TEST_STATE_HASH_ROOTS, .Count_Tree, 64)
	assert(ok)
	memory = make([]u64, (layout.bytes + 7) / 8)
	bound := state_bind(state, ([^]u8)(raw_data(memory))[:layout.bytes], blocks, TEST_STATE_HASH_ROOTS, .Count_Tree, 64)
	assert(bound)
	return state, memory
}

// A disk with no count tree has each leaf of a count to write; with the
// tree of its counts, none, and each page of the tree has one name with
// the owner of the tree. A tree that differs in one count has that leaf to
// write.
@(test)
the_open_compares_the_count_tree :: proc(t: ^testing.T) {
	disk := disk_make(64)
	defer delete(disk.bytes)
	object := disk_large_object(&disk)
	table := disk_store(&disk, object, {})
	disk_root(&disk, table, 5)
	state := test_state_make(64)
	defer test_state_free(state)
	first := mount(state, &disk, 64)
	testing.expect(t, !first.failed && !first.count_tree_damaged)
	testing.expect_value(t, first.count_leaves_differ, u64(1))

	root := count_tree_write(t, state, &disk)
	root_counts_set(&disk, root, 1)
	second := mount(state, &disk, 64)
	testing.expect(t, !second.failed && !second.count_tree_damaged)
	testing.expect_value(t, second.count_leaves_differ, u64(0))
	testing.expect_value(t, block_count(state, root.block), u32(1))
	testing.expect_value(t, block_owner(state, root.block), COUNT_TREE_OWNER)

	// One count of the tree is wrong: its leaf is to write.
	skewed := count_tree_write(t, state, &disk, object.data.block)
	root_counts_set(&disk, skewed, 1)
	third := mount(state, &disk, 64)
	testing.expect(t, !third.failed && !third.count_tree_damaged)
	testing.expect_value(t, third.count_leaves_differ, u64(1))
}

// A count tree with a wrong page is no tree: the open counts by its walk
// and each leaf of a count is to write.
@(test)
a_damaged_count_tree_is_no_tree :: proc(t: ^testing.T) {
	disk := disk_make(64)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	table := disk_store(&disk, object, {})
	disk_root(&disk, table, 4)
	state := test_state_make(64)
	defer test_state_free(state)
	_ = mount(state, &disk, 64)
	root := count_tree_write(t, state, &disk)
	root_counts_set(&disk, root, 1)
	// A byte of the leaf under the top directory.
	directory := (^format.Count_Directory)(&disk.bytes[root.block * BLOCK_SIZE])
	leaf := directory.children[0].block
	disk.bytes[leaf * BLOCK_SIZE + 100] ~= 1
	result := mount(state, &disk, 64)
	testing.expect(t, !result.failed)
	testing.expect(t, result.count_tree_damaged)
	testing.expect_value(t, result.count_leaves_differ, u64(1))
	testing.expect_value(t, state.counts.root, format.Pointer{})
}

// The form Count_Tree opens a disk with no table of each block: each count
// and owner is the count of the walk of the form Tables; the counts of the
// store are those of the disk. A root with no complete tree is refused.
@(test)
the_form_count_tree_opens_from_the_tree :: proc(t: ^testing.T) {
	disk := disk_make(64)
	defer delete(disk.bytes)
	object := disk_large_object(&disk)
	table := disk_store(&disk, object, {})
	disk_root(&disk, table, 5)
	tables := test_state_make(64)
	defer test_state_free(tables)
	_ = mount(tables, &disk, 64)
	root := count_tree_write(t, tables, &disk)
	root_counts_set(&disk, root, 1)
	walked := mount(tables, &disk, 64)
	testing.expect_value(t, walked.count_leaves_differ, u64(0))

	state, memory := tree_state_make(64)
	defer delete(memory)
	defer free(state)
	result := mount(state, &disk, 64)
	testing.expect(t, !result.failed && !result.larger_than_capacity)
	testing.expect_value(t, result.objects, walked.objects)
	for number in u64(0) ..< 64 {
		testing.expectf(t, block_count(state, number) == tables.references[number], "block %d: count %d, not %d", number, block_count(state, number), tables.references[number])
		testing.expectf(t, block_owner(state, number) == tables.owner[number], "block %d: owner %d, not %d", number, block_owner(state, number), tables.owner[number])
	}
	testing.expect_value(t, state.store_recount[0], u64(5))
	testing.expect(t, used(state, object.data.block) && !used(state, 63), "in use is a count that is not 0")
	testing.expect_value(t, blocks_in_use(state), tables.in_use_count)
	// The damage of the form Count_Tree is a set.
	testing.expect(t, !wrong_block(state, 40))
	wrong_block_set(state, 40)
	testing.expect(t, wrong_block(state, 40) && !wrong_block(state, 41))

	// The same root with its tree not complete: refused whole.
	root_counts_set(&disk, root, 0)
	refused := mount(state, &disk, 64)
	testing.expect(t, refused.failed && refused.larger_than_capacity)
	// No tree at all: refused, whatever the root says of it, since the disk
	// has a store.
	for complete in ([?]u64{0, 1, 2, max(u64)}) {
		root_counts_set(&disk, {}, complete)
		refused = mount(state, &disk, 64)
		testing.expectf(t, refused.failed && refused.larger_than_capacity, "no tree, complete %d", complete)
	}
	// A tree with a word of complete that is not 1: refused.
	root_counts_set(&disk, root, 2)
	refused = mount(state, &disk, 64)
	testing.expect(t, refused.failed && refused.larger_than_capacity)
	// A disk with no store and no tree, complete: every count is 0.
	empty := disk_make(64)
	defer delete(empty.bytes)
	fresh := format.Root{magic = format.ROOT_MAGIC, generation = 1, disk_blocks = 64, counts_complete = 1}
	fresh.check = format.root_check(&fresh)
	copy(empty.bytes[BLOCK_SIZE:][:BLOCK_SIZE], ([^]u8)(&fresh)[:BLOCK_SIZE])
	opened := mount(state, &empty, 64)
	testing.expect(t, !opened.failed && !opened.larger_than_capacity)
	testing.expect_value(t, block_count(state, 10), u32(0))
}
