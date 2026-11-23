#+build !freestanding
package storage_mount

import "base:runtime"
import "core:fmt"
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

// count_tree_write writes the count tree of the tables of a state on its
// test disk, and gives its root.
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
	// No page of the damaged tree keeps a name: the top directory, read
	// before the wrong leaf, has none.
	testing.expect_value(t, block_count(state, root.block), u32(0))
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


// A hostile disk whose trees name one inner tree again and again: ten
// names on each of six levels, a million paths to one leaf. The open of the
// form Count_Tree reads each node once: it ends, the store is faulty, and
// the nodes read are the blocks of the disk at most.
@(test)
the_form_count_tree_reads_a_node_once :: proc(t: ^testing.T) {
	disk := disk_make(64)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	under := disk_leaf(&disk, {{"a", object_entry(object, {})}})
	for _ in 0 ..< 6 {
		names := [10]string{"t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "t9"}
		entries: [10]Named_Entry
		for &item, place in entries {
			item = {names[place], {kind = u64(format.Entry_Kind.Tree), size = 10, pointer = under}}
		}
		under = disk_leaf(&disk, entries[:])
	}
	block: format.Store_Block
	block.tree = under
	disk_root(&disk, disk_put(&disk, &block), 10)
	tables := test_state_make(64)
	defer test_state_free(tables)
	_ = mount(tables, &disk, 64)
	root := count_tree_write(t, tables, &disk)
	root_counts_set(&disk, root, 1)

	state, memory := tree_state_make(64)
	defer delete(memory)
	defer free(state)
	result := mount(state, &disk, 64)
	testing.expect(t, !result.failed)
	testing.expect(t, result.named_twice > 0, "the nodes named again are a fault")
	testing.expect(t, state.store_faulty[0], "the store is faulty")
	testing.expect(t, state.node_reads <= 64, "each node is read once")
}

// A pair of roots of two forms: the newest one names no complete count
// tree, the older one does. The form Count_Tree refuses the disk whole: it
// never opens the older root, which would lose the last commit. The form
// Tables opens the newest one.
@(test)
the_newest_root_that_a_form_refuses_refuses_the_disk :: proc(t: ^testing.T) {
	disk := disk_make(64)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	table := disk_store(&disk, object, {})
	disk_root(&disk, table, 4)
	tables := test_state_make(64)
	defer test_state_free(tables)
	_ = mount(tables, &disk, 64)
	root_counts_set(&disk, count_tree_write(t, tables, &disk), 1)
	newer := (^format.Root)(raw_data(disk.bytes))^
	newer.generation += 1
	newer.counts_complete = 0
	newer.check = format.root_check(&newer)
	copy(disk.bytes[BLOCK_SIZE:][:BLOCK_SIZE], ([^]u8)(&newer)[:BLOCK_SIZE])

	state, memory := tree_state_make(64)
	defer delete(memory)
	defer free(state)
	refused := mount(state, &disk, 64)
	testing.expect(t, refused.failed && refused.larger_than_capacity, "the older root does not open")
	opened := mount(tables, &disk, 64)
	testing.expect(t, !opened.failed)
	testing.expect_value(t, opened.generation, newer.generation)
}

// A wrong leaf in the form Count_Tree: a read of its counts fails and the
// leaf is kept as wrong; the search of a free block passes it; the repair
// walks each store, then the pages of the root, and gives the counts of
// the walk of the form Tables. A set of damage past half full stops the
// changes.
@(test)
a_wrong_leaf_is_counted_again :: proc(t: ^testing.T) {
	disk := disk_make(1100)
	defer delete(disk.bytes)
	object := disk_large_object(&disk)
	table := disk_store(&disk, object, {})
	disk_root(&disk, table, 5)
	tables := test_state_make(1100)
	defer test_state_free(tables)
	_ = mount(tables, &disk, 1100)
	root := count_tree_write(t, tables, &disk)
	root_counts_set(&disk, root, 1)
	// The counts of the walk, with the pages of the tree counted.
	testing.expect_value(t, mount(tables, &disk, 1100).count_leaves_differ, u64(0))

	state, memory := tree_state_make(1100)
	defer delete(memory)
	defer free(state)
	testing.expect(t, !mount(state, &disk, 1100).failed)
	// A byte of leaf 0 changes on the disk; the cache is cold.
	directory := (^format.Count_Directory)(&disk.bytes[root.block * BLOCK_SIZE])
	leaf := directory.children[0].block
	disk.bytes[leaf * BLOCK_SIZE + 100] ~= 1
	testing.expect(t, block_counts.counts_bind(&state.counts, &state.count_source, root, 1100, state.counts.frames, state.counts.slots))
	_, _, outcome := block_counts.count_get(&state.counts, object.data.block)
	testing.expect_value(t, outcome, block_counts.Read.Wrong)
	testing.expect_value(t, state.counts.wrong_leaf_count, 1)
	testing.expect(t, repair_waits(state))
	// The search of a free block passes the wrong leaf: the first free
	// block is in leaf 1.
	none :: proc "contextless" (data: rawptr, number: u64) -> bool {return false}
	free_block := block_counts.free_search(&state.counts, 2, none, nil)
	testing.expect(t, free_block >= format.COUNTS_OF_A_PAGE, "the wrong leaf is passed")

	for steps := 0; repair_waits(state); steps += 1 {
		testing.expect_value(t, repair_step(state, &disk, test_roots), Repair_Stop.None)
		if steps > 10 {
			testing.fail_now(t, "the repair does not end")
		}
	}
	testing.expect_value(t, len(state.counts.repaired), 1)
	for number in u64(0) ..< format.COUNTS_OF_A_PAGE {
		count, owner, read := block_counts.count_get(&state.counts, number)
		testing.expectf(t, read == .Good && count == tables.references[number] && owner == tables.owner[number], "block %d: %d of %d, not %d of %d", number, count, owner, tables.references[number], tables.owner[number])
	}
	repair_written(state)
	testing.expect_value(t, state.counts.wrong_leaf_count, 0)

	// The sets of damage: past half full the changes stop.
	testing.expect(t, !state.damage_set_full)
	for number in u64(2) ..< u64(2 + len(state.wrong_set)) {
		wrong_block_set(state, number)
	}
	testing.expect(t, state.damage_set_full)
}

// A device that grew since the format: the root names 64 blocks, the
// device has 70 000, past one directory of the tree. The count tree keeps
// the levels of its root, and each count reads as the walk counts it.
@(test)
a_grown_device_keeps_the_tree_of_its_root :: proc(t: ^testing.T) {
	disk := disk_make(64)
	defer delete(disk.bytes)
	object := disk_large_object(&disk)
	table := disk_store(&disk, object, {})
	disk_root(&disk, table, 5)
	root := (^format.Root)(raw_data(disk.bytes))
	root.disk_blocks = 64
	root.check = format.root_check(root)
	tables := test_state_make(64)
	defer test_state_free(tables)
	_ = mount(tables, &disk, 64)
	root_counts_set(&disk, count_tree_write(t, tables, &disk), 1)
	_ = mount(tables, &disk, 64)
	grown := make([]u8, 70_000 * BLOCK_SIZE)
	copy(grown, disk.bytes)
	delete(disk.bytes)
	disk.bytes = grown

	state, memory := tree_state_make(70_000)
	defer delete(memory)
	defer free(state)
	result := mount(state, &disk, 70_000)
	testing.expect(t, !result.failed)
	testing.expect_value(t, state.counts.levels, format.count_tree_levels(64))
	testing.expect_value(t, state.counts.disk_blocks, u64(64))
	for number in u64(0) ..< 64 {
		testing.expectf(t, block_count(state, number) == tables.references[number], "block %d", number)
	}
}

// disk_queue writes a store whose tree is empty and whose removal queue
// holds one entry, with the key of the first removal.
@(private = "file")
disk_queue :: proc(disk: ^Test_Disk, entry: format.Entry, in_tree: bool = false) {
	key := format.removal_name(1)
	leaf := disk_leaf(disk, {{string(key[:8]), entry}})
	block: format.Store_Block
	if in_tree {
		block.tree = leaf
	} else {
		block.removals = leaf
		block.removing = 1
	}
	disk_root(disk, disk_put(disk, &block), 6)
}

// disk_release_list writes a release list of these states, and gives its
// pointer.
@(private = "file")
disk_release_list :: proc(disk: ^Test_Disk, states: []format.Release_State, count: u32 = 0) -> format.Pointer {
	list := format.Release_List{magic = format.RELEASE_LIST_MAGIC, count = count != 0 ? count : u32(len(states))}
	copy(list.states[:], states)
	return disk_put(disk, &list)
}

// A release in the removal queue: a list of states, each counted from its
// cursor (reference_release, reference_part): no name for a block of data
// before it, one for each block from it, one for the node that holds it.
// A cursor of 0 is a whole state. A release in a tree of a store, a kind
// that names no member, and a list out of its form are damage.
@(test)
the_open_counts_a_release_from_its_cursor :: proc(t: ^testing.T) {
	for cursor in ([?]u64{0, 1, 2}) {
		disk := disk_make(64)
		defer delete(disk.bytes)
		object := disk_large_object(&disk)
		list := disk_release_list(&disk, {{root = object.root, size = object.size, cursor = cursor}})
		disk_queue(&disk, {kind = u64(format.Entry_Kind.Release), pointer = list})
		state := test_state_make(64)
		defer test_state_free(state)
		result := mount(state, &disk, 64)
		testing.expectf(t, !result.failed && !state.store_damaged[0], "cursor %d: the store opens", cursor)
		testing.expectf(t, result.removing == 1, "cursor %d: one entry in the queue", cursor)
		first := object.data.block
		testing.expectf(t, state.references[first] == (cursor == 0 ? 1 : 0), "cursor %d: the first block of data has %d names", cursor, state.references[first])
		testing.expectf(t, state.references[first + 1] == (cursor <= 1 ? 1 : 0), "cursor %d: the second block of data has %d names", cursor, state.references[first + 1])
		testing.expectf(t, state.references[object.root.block] == 1, "cursor %d: the node keeps its name", cursor)
		testing.expectf(t, state.references[list.block] == 1, "cursor %d: the list has one name", cursor)
	}
	// Two states in one list: each one counted.
	{
		disk := disk_make(64)
		defer delete(disk.bytes)
		one := disk_large_object(&disk)
		two := disk_object(&disk)
		list := disk_release_list(&disk, {{root = one.root, size = one.size}, {root = two.root, size = two.size}})
		disk_queue(&disk, {kind = u64(format.Entry_Kind.Release), pointer = list})
		state := test_state_make(64)
		defer test_state_free(state)
		result := mount(state, &disk, 64)
		testing.expect(t, !result.failed && !state.store_damaged[0])
		testing.expect(t, state.references[one.root.block] == 1 && state.references[two.root.block] == 1, "both states are counted")
	}
	// Out of form: a count of 0, a count past the bound, a wrong check, an
	// entry with another word than 0, a release in a tree, a kind 4.
	Bad :: struct {
		label: string,
		build: proc(disk: ^Test_Disk, object: Object_Blocks),
	}
	bad := [?]Bad {
		{"a count of 0", proc(disk: ^Test_Disk, object: Object_Blocks) {
				disk_queue(disk, {kind = u64(format.Entry_Kind.Release), pointer = disk_release_list(disk, nil)})
			}},
		{"a count of 128", proc(disk: ^Test_Disk, object: Object_Blocks) {
				disk_queue(disk, {kind = u64(format.Entry_Kind.Release), pointer = disk_release_list(disk, {{root = object.root, size = object.size}}, format.RELEASES_OF_A_LIST + 1)})
			}},
		{"a wrong check", proc(disk: ^Test_Disk, object: Object_Blocks) {
				list := disk_release_list(disk, {{root = object.root, size = object.size}})
				list.check ~= 1
				disk_queue(disk, {kind = u64(format.Entry_Kind.Release), pointer = list})
			}},
		{"a size in the entry", proc(disk: ^Test_Disk, object: Object_Blocks) {
				disk_queue(disk, {kind = u64(format.Entry_Kind.Release), size = 1, pointer = disk_release_list(disk, {{root = object.root, size = object.size}})})
			}},
		{"a release in a tree", proc(disk: ^Test_Disk, object: Object_Blocks) {
				disk_queue(disk, {kind = u64(format.Entry_Kind.Release), pointer = disk_release_list(disk, {{root = object.root, size = object.size}})}, true)
			}},
		{"a kind 4 in the queue", proc(disk: ^Test_Disk, object: Object_Blocks) {
				disk_queue(disk, {kind = 4, size = object.size, pointer = object.root})
			}},
	}
	for item in bad {
		disk := disk_make(64)
		defer delete(disk.bytes)
		object := disk_large_object(&disk)
		item.build(&disk, object)
		state := test_state_make(64)
		defer test_state_free(state)
		result := mount(state, &disk, 64)
		testing.expectf(t, !result.failed && state.store_damaged[0], "%s is damage", item.label)
	}
	// The border of the kind: Release is 3, and 4 names no member.
	kind, ok := format.entry_kind_of_word(3)
	testing.expect(t, ok && kind == .Release)
	_, ok = format.entry_kind_of_word(4)
	testing.expect(t, !ok)
}

// A hostile count tree that the form Tables meets: a page of another
// level under a valid check is a damaged tree; a leaf with another owner
// is a leaf that differs.
@(test)
a_hostile_count_tree_is_found_by_the_walk :: proc(t: ^testing.T) {
	disk := disk_make(64)
	defer delete(disk.bytes)
	object := disk_large_object(&disk)
	table := disk_store(&disk, object, {})
	disk_root(&disk, table, 5)
	state := test_state_make(64)
	defer test_state_free(state)
	_ = mount(state, &disk, 64)
	root := count_tree_write(t, state, &disk)
	// The leaf says another owner for a block: its check is made again, and
	// the directory and the root follow.
	directory := (^format.Count_Directory)(&disk.bytes[root.block * BLOCK_SIZE])
	leaf_block := directory.children[0].block
	leaf := (^format.Count_Page)(&disk.bytes[leaf_block * BLOCK_SIZE])
	leaf.owners[object.data.block] += 1
	directory.children[0].check = format.check(disk.bytes[leaf_block * BLOCK_SIZE:][:BLOCK_SIZE])
	root.check = format.check(disk.bytes[root.block * BLOCK_SIZE:][:BLOCK_SIZE])
	root_counts_set(&disk, root, 1)
	owner := mount(state, &disk, 64)
	testing.expect(t, !owner.count_tree_damaged)
	testing.expect_value(t, owner.count_leaves_differ, u64(1))
	// The leaf says level 1, with a check that matches.
	leaf.level = 1
	directory.children[0].check = format.check(disk.bytes[leaf_block * BLOCK_SIZE:][:BLOCK_SIZE])
	root.check = format.check(disk.bytes[root.block * BLOCK_SIZE:][:BLOCK_SIZE])
	root_counts_set(&disk, root, 1)
	level := mount(state, &disk, 64)
	testing.expect(t, level.count_tree_damaged)
}

// The roots of a store as the open read them: no commit runs between the
// steps of these repairs.
test_roots :: proc "contextless" (state: ^State, store_index: int) -> (tree: format.Pointer, removals: format.Pointer) {
	head := state.store_heads[store_index]
	return head.tree, head.removals
}

// repair_until_done runs the steps of a repair to its end.
@(private = "file")
repair_until_done :: proc(t: ^testing.T, state: ^State, disk: ^Test_Disk, between: proc(state: ^State, disk: ^Test_Disk, step: int) = nil) -> (steps: int) {
	for repair_waits(state) {
		testing.expect_value(t, repair_step(state, disk, test_roots), Repair_Stop.None)
		steps += 1
		if between != nil {
			between(state, disk, steps)
		}
		if steps > 10_000 {
			testing.fail_now(t, "the repair does not end")
		}
	}
	return steps
}

// leaf_zero_break gives the state of the form Count_Tree of a disk with a
// count tree whose leaf 0 has a wrong check, read once so that it is known
// wrong.
@(private = "file")
leaf_zero_break :: proc(t: ^testing.T, disk: ^Test_Disk, blocks: u64) -> (state: ^State, memory: []u64, tables: ^State) {
	tables = test_state_make(blocks)
	_ = mount(tables, disk, blocks)
	root := count_tree_write(t, tables, disk)
	root_counts_set(disk, root, 1)
	testing.expect_value(t, mount(tables, disk, blocks).count_leaves_differ, u64(0))
	state, memory = tree_state_make(blocks)
	testing.expect(t, !mount(state, disk, blocks).failed)
	directory := (^format.Count_Directory)(&disk.bytes[root.block * BLOCK_SIZE])
	disk.bytes[directory.children[0].block * BLOCK_SIZE + 100] ~= 1
	testing.expect(t, block_counts.counts_bind(&state.counts, &state.count_source, root, blocks, state.counts.frames, state.counts.slots))
	_, _, outcome := block_counts.count_get(&state.counts, 5)
	testing.expect_value(t, outcome, block_counts.Read.Wrong)
	return state, memory, tables
}

// A tree of 40 entries that name one large object: its root has 40 names,
// each node under it one. The repair reads the shared root once, in steps
// of one node, and gives the counts of the walk of the tables.
@(test)
a_repair_counts_a_shared_tree_once :: proc(t: ^testing.T) {
	disk := disk_make(1100)
	defer delete(disk.bytes)
	object := disk_large_object(&disk)
	names: [40]string
	for &name, index in names {
		name = fmt.tprintf("n%02d", index)
	}
	entries: [11]Named_Entry
	leaves: [4]format.Pointer
	for &leaf, place in leaves {
		for &item, index in entries[:10] {
			item = {names[place * 10 + index], object_entry(object, {})}
		}
		leaf = disk_leaf(&disk, entries[:10])
	}
	branch: [BLOCK_SIZE]u8
	header := (^format.Tree_Header)(&branch)
	header^ = {level = 1, count = 4, magic = format.NODE_MAGIC}
	for leaf, place in leaves {
		record := branch[format.TREE_HEADER_SIZE + place * (size_of(format.Entry_Name) + size_of(format.Pointer)):]
		copy(record, names[place * 10])
		(^format.Pointer)(&record[size_of(format.Entry_Name)])^ = leaf
	}
	block: format.Store_Block
	block.tree = disk_put(&disk, &branch)
	block.objects = 40
	disk_root(&disk, disk_put(&disk, &block), 12)
	state, memory, tables := leaf_zero_break(t, &disk, 1100)
	defer delete(memory)
	defer free(state)
	defer test_state_free(tables)
	testing.expect_value(t, tables.references[object.root.block], u32(40))
	state.repair_nodes_per_step = 1
	steps := repair_until_done(t, state, &disk)
	testing.expect(t, steps > 3, "the repair took several steps")
	for number in u64(0) ..< format.COUNTS_OF_A_PAGE {
		count, owner, _ := block_counts.count_get(&state.counts, number)
		testing.expectf(t, count == tables.references[number] && owner == tables.owner[number], "block %d: %d, not %d", number, count, tables.references[number])
	}
}

// A commit between two steps of a repair: a new object, outside the wrong
// leaf, joins the store, with a new leaf of its tree. The repair goes on
// from the new tree, and the counts of the wrong leaf are those of the
// walk, which the commit did not change.
@(test)
a_commit_between_two_steps_of_a_repair :: proc(t: ^testing.T) {
	disk := disk_make(1100)
	defer delete(disk.bytes)
	object := disk_large_object(&disk)
	disk.next = 600
	leaf := disk_leaf(&disk, {{"a", object_entry(object, {})}})
	block: format.Store_Block
	block.tree = leaf
	block.objects = 1
	disk_root(&disk, disk_put(&disk, &block), 6)
	state, memory, tables := leaf_zero_break(t, &disk, 1100)
	defer delete(memory)
	defer free(state)
	defer test_state_free(tables)
	state.repair_nodes_per_step = 1
	commit :: proc(state: ^State, disk: ^Test_Disk, step: int) {
		if step != 1 {
			return
		}
		// The commit writes its blocks past the wrong leaf, and the store
		// names the new leaf of its tree.
		disk.next = 700
		other := disk_object(disk)
		state.store_heads[0].tree = disk_leaf(disk, {{"a", repair_test_object_entry}, {"b", object_entry(other, {})}})
	}
	repair_test_object_entry = object_entry(object, {})
	repair_until_done(t, state, &disk, commit)
	for number in u64(0) ..< format.COUNTS_OF_A_PAGE {
		count, _, _ := block_counts.count_get(&state.counts, number)
		testing.expectf(t, count == tables.references[number], "block %d: %d, not %d", number, count, tables.references[number])
	}
}

@(private = "file")
repair_test_object_entry: format.Entry

// A repair that cannot read a node stops, and no repair starts again: the
// wrong leaves stay wrong.
@(test)
a_stopped_repair_does_not_start_again :: proc(t: ^testing.T) {
	disk := disk_make(1100)
	defer delete(disk.bytes)
	object := disk_large_object(&disk)
	table := disk_store(&disk, object, {})
	disk_root(&disk, table, 5)
	state, memory, tables := leaf_zero_break(t, &disk, 1100)
	defer delete(memory)
	defer free(state)
	defer test_state_free(tables)
	// The leaf of the tree of the store changes on the disk.
	tree_leaf := state.store_heads[0].tree.block
	disk.bytes[tree_leaf * BLOCK_SIZE + 64] ~= 1
	stop := Repair_Stop.None
	for steps := 0; repair_waits(state) && steps < 100; steps += 1 {
		stop = repair_step(state, &disk, test_roots)
	}
	testing.expect_value(t, stop, Repair_Stop.Damaged)
	testing.expect(t, state.repair_off && !repair_waits(state), "no repair starts again")
	testing.expect_value(t, len(state.counts.repaired), 0)
	testing.expect_value(t, state.counts.wrong_leaf_count, 1)
}
