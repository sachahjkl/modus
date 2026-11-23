#+build !freestanding
package storage_mount

import "base:runtime"
import "core:fmt"
import "core:testing"
import format "modus:contract/store"
import "internal:storage/block_counts"
import block_tree "internal:storage/storage_object"

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

	repair := test_repair_make(state, &disk)
	defer free(repair)
	repair_until_done(t, state, &disk, repair)
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
	// A list out of its form: a count of 0, a count past the bound, a wrong
	// check. Its states are not counted, and the store is whole: a step
	// drops the entry.
	Bad :: struct {
		label: string,
		build: proc(disk: ^Test_Disk, object: Object_Blocks),
	}
	lists := [?]Bad {
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
	}
	for item in lists {
		disk := disk_make(64)
		defer delete(disk.bytes)
		object := disk_large_object(&disk)
		item.build(&disk, object)
		state := test_state_make(64)
		defer test_state_free(state)
		result := mount(state, &disk, 64)
		testing.expectf(t, !result.failed && !state.store_damaged[0] && result.wrong >= 1, "%s: the store is whole, the list is wrong", item.label)
		testing.expectf(t, state.references[object.root.block] == 0, "%s: no state of the list is counted", item.label)
	}
	// The entry out of its form, or in the wrong place: an entry with
	// another word than 0, a release in a tree, a kind 4.
	bad := [?]Bad {
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

// The service side of a test repair: the root of the last commit, the
// writes of the scratch on the test disk, and the stores found damaged.
@(private = "file")
Test_Repair :: struct {
	using repair_disk: Repair_Disk,
	disk:          ^Test_Disk,
	last_root:     format.Root,
	damaged:       [8]int,
	damaged_count: int,
	drop_writes:   bool, // The device answers each write and keeps none.
	writes:        int,
}

@(private = "file")
test_repair_write :: proc "contextless" (disk: ^Repair_Disk, number: u64, bytes: ^[BLOCK_SIZE]u8) -> bool {
	repair := (^Test_Repair)(disk)
	repair.writes += 1
	if repair.drop_writes {
		return true
	}
	copy(repair.disk.bytes[number * BLOCK_SIZE:][:BLOCK_SIZE], bytes[:])
	return true
}

@(private = "file")
test_store_damaged :: proc "contextless" (disk: ^Repair_Disk, store_index: int) {
	repair := (^Test_Repair)(disk)
	if repair.damaged_count < len(repair.damaged) {
		repair.damaged[repair.damaged_count] = store_index
		repair.damaged_count += 1
	}
}

// test_repair_make gives the service side of a repair: the root of block 0
// of the disk, and the heads of the stores of the state.
@(private = "file")
test_repair_make :: proc(state: ^State, disk: ^Test_Disk) -> ^Test_Repair {
	repair := new(Test_Repair)
	repair.disk = disk
	repair.last_root = (^format.Root)(raw_data(disk.bytes))^
	repair.repair_disk = {root = &repair.last_root, heads = state.store_heads[:], write = test_repair_write, store_damaged = test_store_damaged, nonce = 7}
	return repair
}

// repair_until_done runs the steps of a repair to its end.
@(private = "file")
repair_until_done :: proc(t: ^testing.T, state: ^State, disk: ^Test_Disk, repair: ^Test_Repair) -> (steps: int) {
	for repair_waits(state) {
		outcome := repair_step(state, disk, &repair.repair_disk)
		testing.expectf(t, outcome == .Running || outcome == .Done, "a step ends with %v", outcome)
		steps += 1
		if steps > 100_000 {
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
	leaf_zero_damage(t, state, disk, root, blocks)
	return state, memory, tables
}

// leaf_zero_damage changes a byte of leaf 0 of the count tree on the disk,
// and reads it with a cold cache, so that it is known wrong.
@(private = "file")
leaf_zero_damage :: proc(t: ^testing.T, state: ^State, disk: ^Test_Disk, root: format.Pointer, blocks: u64) {
	directory := (^format.Count_Directory)(&disk.bytes[root.block * BLOCK_SIZE])
	disk.bytes[directory.children[0].block * BLOCK_SIZE + 100] ~= 1
	testing.expect(t, block_counts.counts_bind(&state.counts, &state.count_source, root, blocks, state.counts.frames, state.counts.slots))
	_, _, outcome := block_counts.count_get(&state.counts, 5)
	testing.expect_value(t, outcome, block_counts.Read.Wrong)
}

// counts_expect compares the counts of leaf 0 with the walk of the tables.
@(private = "file")
counts_expect :: proc(t: ^testing.T, state: ^State, tables: ^State, label: string) {
	for number in u64(0) ..< format.COUNTS_OF_A_PAGE {
		count, owner, _ := block_counts.count_get(&state.counts, number)
		testing.expectf(t, count == tables.references[number] && owner == tables.owner[number], "%s: block %d: %d of %d, not %d of %d", label, number, count, owner, tables.references[number], tables.owner[number])
	}
}

// disk_deep_object writes an object of two levels: a root with these many
// nodes of level 1, each with two blocks of data.
@(private = "file")
disk_deep_object :: proc(disk: ^Test_Disk, children: int) -> (blocks: Object_Blocks) {
	root: format.Object_Node
	root.header = {level = 2, count = u32(children), magic = format.OBJECT_NODE_MAGIC}
	for child in 0 ..< children {
		node: format.Object_Node
		node.header = {level = 1, count = 2, magic = format.OBJECT_NODE_MAGIC}
		for index in 0 ..< 2 {
			data: block_tree.Block
			for &byte, place in data {
				byte = u8(child * 7 + index + 1 + place % 11)
			}
			pointer, value := disk_data(disk, &data, u64(child * format.OBJECT_FANOUT + index))
			node.children[index] = {block = pointer.block, check = pointer.check, blocks = 1, value = value}
		}
		pointer := disk_put(disk, &node)
		root.children[child] = {block = pointer.block, check = pointer.check, blocks = 3, value = block_tree.node_value(&node)}
	}
	blocks.root = disk_put(disk, &root)
	blocks.size = u64((children - 1) * format.OBJECT_FANOUT + 2) * BLOCK_SIZE
	return blocks
}

// A tree of 40 entries that name one object of two levels: its root has 40
// names, each node under it one. The repair walks the shared root once, in
// steps of one node that resume inside the state, with a scratch of small
// pages of which two stay in memory, and gives the counts of the walk of
// the tables.
@(test)
a_repair_counts_a_shared_tree_once :: proc(t: ^testing.T) {
	disk := disk_make(1100)
	defer delete(disk.bytes)
	object := disk_deep_object(&disk, 5)
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
	disk_root(&disk, disk_put(&disk, &block), 23)
	state, memory, tables := leaf_zero_break(t, &disk, 1100)
	defer delete(memory)
	defer free(state)
	defer test_state_free(tables)
	testing.expect_value(t, tables.references[object.root.block], u32(40))
	testing.expect(t, repair_active(state), "the service is in the repair state")
	state.repair.nodes_per_step = 1
	state.repair.shape = {page_bits = 64, children = 4, frame_count = 2}
	repair := test_repair_make(state, &disk)
	defer free(repair)
	steps := repair_until_done(t, state, &disk, repair)
	testing.expect(t, steps > 10, "the repair took several steps")
	testing.expect(t, repair.writes > 0, "pages of the scratch left the memory")
	testing.expect(t, state.repair.scratch.levels >= 2, "the scratch has directories on the disk")
	testing.expect(t, repair_active(state), "the repair state lasts until the commit")
	walked, total := repair_progress(state)
	testing.expect(t, walked == 1 && total == 1)
	counts_expect(t, state, tables, "shared")
	repair_written(state)
	testing.expect(t, !repair_active(state), "the commit ends the repair state")
}

// The repair takes the root of the last commit, not the root that the open
// read: after the open, commits made a second store with its own object
// and moved the page of the store table. The counts are those of the walk
// of the new disk.
@(test)
a_repair_takes_the_root_of_the_last_commit :: proc(t: ^testing.T) {
	disk := disk_make(1100)
	defer delete(disk.bytes)
	first := disk_large_object(&disk)
	first_table := disk_store(&disk, first, {})
	disk_root(&disk, first_table, 5)
	state, memory := tree_state_make(1100)
	defer delete(memory)
	defer free(state)
	tables := test_state_make(1100)
	defer test_state_free(tables)
	_ = mount(tables, &disk, 1100)
	root_counts_set(&disk, count_tree_write(t, tables, &disk), 1)
	testing.expect(t, !mount(state, &disk, 1100).failed)

	// The commits: a second store, a new page of the store table, a new root.
	second := disk_deep_object(&disk, 2)
	second_table := disk_store(&disk, second, {})
	cells := [2]format.Store_Entry{store_s(first_table, 5), store_s(second_table, 9)}
	cells[1].name[0] = 't'
	page := disk_page(&disk, cells[:])
	new_root := root_of_page(1100, 3, page)
	copy(disk.bytes[:BLOCK_SIZE], ([^]u8)(&new_root)[:BLOCK_SIZE])
	_ = mount(tables, &disk, 1100)
	root := count_tree_write(t, tables, &disk)
	root_counts_set(&disk, root, 1)
	testing.expect_value(t, mount(tables, &disk, 1100).count_leaves_differ, u64(0))
	// The service keeps the pages and the heads of the stores up to date;
	// the open state keeps the root that it read.
	copy(state.store_pages[0].cells[:], cells[:])
	state.store_heads[1] = tables.store_heads[1]
	leaf_zero_damage(t, state, &disk, root, 1100)
	testing.expect(t, state.root.generation != (^format.Root)(raw_data(disk.bytes)).generation, "the open read the root before")

	repair := test_repair_make(state, &disk)
	defer free(repair)
	repair_until_done(t, state, &disk, repair)
	walked, total := repair_progress(state)
	testing.expect(t, walked == 2 && total == 2, "both stores are walked")
	counts_expect(t, state, tables, "the last commit")
}

// A loss of power during a repair: the scratch is on free blocks, which no
// root names. The next open finds the wrong leaf again, and its repair
// starts from the first store and gives the counts of the walk.
@(test)
a_loss_of_power_during_a_repair :: proc(t: ^testing.T) {
	disk := disk_make(1100)
	defer delete(disk.bytes)
	object := disk_deep_object(&disk, 4)
	table := disk_store(&disk, object, {})
	disk_root(&disk, table, 9)
	state, memory, tables := leaf_zero_break(t, &disk, 1100)
	defer delete(memory)
	defer free(state)
	defer test_state_free(tables)
	state.repair.nodes_per_step = 1
	state.repair.shape = {page_bits = 64, children = 4, frame_count = 2}
	repair := test_repair_make(state, &disk)
	defer free(repair)
	for _ in 0 ..< 3 {
		testing.expect_value(t, repair_step(state, &disk, &repair.repair_disk), Repair_Outcome.Running)
	}
	root := (^format.Root)(raw_data(disk.bytes)).counts

	// The next start: a new state opens the same disk.
	again, again_memory := tree_state_make(1100)
	defer delete(again_memory)
	defer free(again)
	testing.expect(t, !mount(again, &disk, 1100).failed)
	testing.expect(t, block_counts.counts_bind(&again.counts, &again.count_source, root, 1100, again.counts.frames, again.counts.slots))
	_, _, outcome := block_counts.count_get(&again.counts, 5)
	testing.expect_value(t, outcome, block_counts.Read.Wrong)
	testing.expect(t, repair_waits(again), "the repair starts again")
	again.repair.shape = {page_bits = 64, children = 4, frame_count = 2}
	second := test_repair_make(again, &disk)
	defer free(second)
	repair_until_done(t, again, &disk, second)
	counts_expect(t, again, tables, "after the loss of power")
}

// A device that does not keep a write of the scratch: the page read back
// is not the page of the run, so the repair fails and waits for a call;
// the next run, with a device that keeps its writes, ends with the counts
// of the walk.
@(test)
a_dropped_write_of_the_scratch_starts_the_repair_again :: proc(t: ^testing.T) {
	disk := disk_make(1100)
	defer delete(disk.bytes)
	object := disk_deep_object(&disk, 6)
	table := disk_store(&disk, object, {})
	disk_root(&disk, table, 11)
	state, memory, tables := leaf_zero_break(t, &disk, 1100)
	defer delete(memory)
	defer free(state)
	defer test_state_free(tables)
	state.repair.shape = {page_bits = 8, children = 2, frame_count = 1}
	repair := test_repair_make(state, &disk)
	defer free(repair)
	repair.drop_writes = true
	outcome := Repair_Outcome.Running
	for steps := 0; outcome == .Running && steps < 1000; steps += 1 {
		outcome = repair_step(state, &disk, &repair.repair_disk)
	}
	testing.expect_value(t, outcome, Repair_Outcome.Device)
	testing.expect(t, repair_active(state), "the changes stay refused")
	testing.expect(t, !repair_waits(state), "the repair waits for a call")
	testing.expect_value(t, len(state.counts.repaired), 0)
	repair_call_came(state)
	testing.expect(t, repair_waits(state))
	repair.drop_writes = false
	repair_until_done(t, state, &disk, repair)
	counts_expect(t, state, tables, "the run after the device")
}

// A tree of one store has a wrong node: the service learns that the store
// is damaged, and the repair goes on with the other store, whose blocks
// have the counts of the walk.
@(test)
a_damaged_store_during_a_repair :: proc(t: ^testing.T) {
	disk := disk_make(1100)
	defer delete(disk.bytes)
	first := disk_large_object(&disk)
	first_table := disk_store(&disk, first, {})
	second := disk_large_object(&disk)
	second_table := disk_store(&disk, second, {})
	cells := [2]format.Store_Entry{store_s(first_table, 5), store_s(second_table, 5)}
	cells[1].name[0] = 't'
	page := disk_page(&disk, cells[:])
	root := root_of_page(1100, 2, page)
	copy(disk.bytes[:BLOCK_SIZE], ([^]u8)(&root)[:BLOCK_SIZE])
	state, memory, tables := leaf_zero_break(t, &disk, 1100)
	defer delete(memory)
	defer free(state)
	defer test_state_free(tables)
	// The leaf of the tree of the first store changes on the disk.
	disk.bytes[state.store_heads[0].tree.block * BLOCK_SIZE + 64] ~= 1
	repair := test_repair_make(state, &disk)
	defer free(repair)
	repair_until_done(t, state, &disk, repair)
	testing.expect_value(t, repair.damaged_count, 1)
	testing.expect_value(t, repair.damaged[0], 0)
	testing.expect_value(t, len(state.counts.repaired), 1)
	for number in ([?]u64{second.root.block, second.data.block, second.data.block + 1, state.store_heads[1].tree.block, second_table.block}) {
		count, _, _ := block_counts.count_get(&state.counts, number)
		testing.expectf(t, count == tables.references[number], "block %d of the second store: %d, not %d", number, count, tables.references[number])
	}
	// Under the wrong node, nothing is counted, as at an open.
	count, _, _ := block_counts.count_get(&state.counts, first.root.block)
	testing.expect_value(t, count, u32(0))
}

// A disk with no free block outside the wrong leaf: the scratch finds no
// room, the service takes changes again, and the repair waits for a commit.
@(test)
a_repair_with_no_room_for_its_scratch :: proc(t: ^testing.T) {
	disk := disk_make(520)
	defer delete(disk.bytes)
	object := disk_large_object(&disk)
	table := disk_store(&disk, object, {})
	disk_root(&disk, table, 5)
	// Each block past leaf 0 in use: the count tree says so. Its own pages
	// go to the next blocks, in leaf 0.
	tables := test_state_make(520)
	defer test_state_free(tables)
	_ = mount(tables, &disk, 520)
	for number in u64(format.COUNTS_OF_A_PAGE) ..< 520 {
		tables.references[number] = 1
		tables.owner[number] = 1
	}
	root := count_tree_write(t, tables, &disk)
	root_counts_set(&disk, root, 1)
	state, memory := tree_state_make(520)
	defer delete(memory)
	defer free(state)
	testing.expect(t, !mount(state, &disk, 520).failed)
	leaf_zero_damage(t, state, &disk, root, 520)
	// A scratch of more pages than its frames, so that it needs blocks.
	state.repair.shape = {page_bits = 8, children = 2, frame_count = 1}
	repair := test_repair_make(state, &disk)
	defer free(repair)
	outcome := repair_step(state, &disk, &repair.repair_disk)
	testing.expect_value(t, outcome, Repair_Outcome.No_Room)
	testing.expect(t, !repair_active(state), "the service takes changes again")
	repair_commit_came(state)
	testing.expect(t, repair_active(state) && repair_waits(state), "a commit starts the repair again")
}

// The releases of the removal queue: a chain of 70 lists of 127 states,
// 8890 states, past the 64 lists of 127 that one commit held before, each
// one a name of one shared object, with a cursor in one. The open counts
// each state; a repair gives the same counts.
@(test)
a_chain_of_release_lists :: proc(t: ^testing.T) {
	disk := disk_make(1100)
	defer delete(disk.bytes)
	object := disk_deep_object(&disk, 3)
	LISTS :: 70
	next: format.Pointer
	for list_index := LISTS - 1; list_index >= 0; list_index -= 1 {
		list := format.Release_List{magic = format.RELEASE_LIST_MAGIC, count = format.RELEASES_OF_A_LIST, next = next}
		for &released in list.states {
			released = {root = object.root, size = object.size}
		}
		// A cursor past the first node of level 1 in the first state of the
		// first list: the blocks before it have no name of that state.
		if list_index == 0 {
			list.states[0].cursor = format.OBJECT_FANOUT
		}
		next = disk_put(&disk, &list)
	}
	disk_queue(&disk, {kind = u64(format.Entry_Kind.Release), pointer = next})
	state, memory, tables := leaf_zero_break(t, &disk, 1100)
	defer delete(memory)
	defer free(state)
	defer test_state_free(tables)
	testing.expect_value(t, tables.references[object.root.block], u32(LISTS * format.RELEASES_OF_A_LIST))
	testing.expect_value(t, tables.references[next.block], u32(1))
	repair := test_repair_make(state, &disk)
	defer free(repair)
	repair_until_done(t, state, &disk, repair)
	counts_expect(t, state, tables, "a chain of lists")
}

// A wrong list in a chain: the lists before it are counted, it and the
// lists after it are not, and the store stays whole, as at run time.
@(test)
a_wrong_release_list_drops_its_entry_only :: proc(t: ^testing.T) {
	Break :: enum {Check, Padding, Next_Of_Block_One, Next_Of_No_Block_With_A_Check}
	for broken in Break {
		disk := disk_make(64)
		defer delete(disk.bytes)
		object := disk_large_object(&disk)
		other := disk_object(&disk)
		third := disk_object(&disk)
		last := disk_release_list(&disk, {{root = third.root, size = third.size}})
		middle_list := format.Release_List{magic = format.RELEASE_LIST_MAGIC, count = 1, next = last}
		middle_list.states[0] = {root = other.root, size = other.size}
		switch broken {
		case .Check:
		case .Padding:
			middle_list.padding[3] = 1
		case .Next_Of_Block_One:
			middle_list.next = {block = 1}
		case .Next_Of_No_Block_With_A_Check:
			middle_list.next = {check = 5}
		}
		middle := disk_put(&disk, &middle_list)
		if broken == .Check {
			middle.check ~= 1
		}
		first_list := format.Release_List{magic = format.RELEASE_LIST_MAGIC, count = 1, next = middle}
		first_list.states[0] = {root = object.root, size = object.size}
		first := disk_put(&disk, &first_list)
		disk_queue(&disk, {kind = u64(format.Entry_Kind.Release), pointer = first})
		state := test_state_make(64)
		defer test_state_free(state)
		result := mount(state, &disk, 64)
		testing.expectf(t, !result.failed && !state.store_damaged[0] && !state.store_faulty[0], "%v: the store is whole", broken)
		testing.expectf(t, state.references[object.root.block] == 1, "%v: the first list is counted", broken)
		testing.expectf(t, state.references[other.root.block] == 0 && state.references[third.root.block] == 0, "%v: the wrong list and the lists after it are not", broken)
		testing.expectf(t, result.wrong >= 1, "%v: the wrong list is a wrong block", broken)
	}
	// The border of the list: padding, next, count.
	list := format.Release_List{magic = format.RELEASE_LIST_MAGIC, count = 1}
	testing.expect(t, format.release_list_valid(&list))
	list.padding[len(list.padding) - 1] = 1
	testing.expect(t, !format.release_list_valid(&list))
	list.padding = {}
	list.next = {block = 0, check = 1}
	testing.expect(t, !format.release_list_valid(&list))
	list.next = {block = 1, check = 1}
	testing.expect(t, !format.release_list_valid(&list))
	list.next = {block = 2, check = 1}
	testing.expect(t, format.release_list_valid(&list))
	list.count = 0
	testing.expect(t, !format.release_list_valid(&list))
	list.count = format.RELEASES_OF_A_LIST + 1
	testing.expect(t, !format.release_list_valid(&list))
	list.count = format.RELEASES_OF_A_LIST
	testing.expect(t, format.release_list_valid(&list))
	list.count = format.RELEASES_OF_A_LIST - 1
	list.states[format.RELEASES_OF_A_LIST - 1].size = 1
	testing.expect(t, !format.release_list_valid(&list))
}

// The commit of a repair in the host model: the leaves that the repair
// counted, their directories, and blocks for the new pages from the free
// search, as the commit of the service makes them.
@(private = "file")
Repair_Commit_Model :: struct {
	counts:   ^block_counts.Counts,
	taken:    map[u64]bool,
	released: map[u64]bool,
}

@(private = "file")
model_taken :: proc "contextless" (data: rawptr, number: u64) -> bool {
	context = runtime.default_context()
	return (^Repair_Commit_Model)(data).taken[number]
}

@(private = "file")
model_after :: proc "contextless" (commit: ^block_counts.Commit, number: u64) -> (count: u32, owner: u16) {
	model := (^Repair_Commit_Model)(commit.data)
	context = runtime.default_context()
	if model.taken[number] {
		return 1, COUNT_TREE_OWNER
	}
	if model.released[number] {
		return 0, 0
	}
	count, owner, _ = block_counts.count_get(model.counts, number)
	return count, owner
}

@(private = "file")
model_take :: proc "contextless" (commit: ^block_counts.Commit) -> u64 {
	model := (^Repair_Commit_Model)(commit.data)
	context = runtime.default_context()
	number := block_counts.free_search(model.counts, 2, model_taken, model)
	if number != 0 {
		model.taken[number] = true
		block_counts.commit_leaf_add(commit, number)
	}
	return number
}

@(private = "file")
model_release :: proc "contextless" (commit: ^block_counts.Commit, number: u64) {
	model := (^Repair_Commit_Model)(commit.data)
	context = runtime.default_context()
	model.released[number] = true
	block_counts.commit_leaf_add(commit, number)
}

// repair_commit_model writes the commit of the repaired leaves on the test
// disk and makes its root name the new count tree. It gives the blocks
// that the commit took.
@(private = "file")
repair_commit_model :: proc(t: ^testing.T, state: ^State, disk: ^Test_Disk) -> (taken: [dynamic]u64, made: bool) {
	model := Repair_Commit_Model{counts = &state.counts}
	defer delete(model.taken)
	defer delete(model.released)
	// As plan_reset of the service: the read that found the wrong page
	// is not a failure of this commit.
	block_counts.counts_failure_clear(&state.counts)
	commit := &state.count_commit
	testing.expect(t, block_counts.commit_begin(commit, &state.counts, state.count_staging, state.count_staged_slots))
	commit.after, commit.take, commit.release = model_after, model_take, model_release
	commit.data = &model
	for &leaf in state.counts.repaired {
		block_counts.commit_leaf_add(commit, leaf.first)
	}
	if leaves, set := repair_recount_after(state); set {
		block_counts.commit_recount_set(commit, leaves)
	}
	root: format.Pointer
	root, made = block_counts.commit_finish(commit)
	commit.data = nil
	if !made {
		block_counts.commit_drop(commit)
		return
	}
	for &page in commit.staging[:commit.staged] {
		copy(disk.bytes[page.block * BLOCK_SIZE:][:BLOCK_SIZE], page.bytes[:])
	}
	for number in model.taken {
		append(&taken, number)
	}
	block_counts.commit_install(commit, root)
	root_counts_set(disk, root, 1)
	return
}

// A hostile store: eleven entries on each of six levels name one tree
// inside, so its walk by paths meets the leaf under them 11^6 times. The
// repair walks each node of a tree once, whatever leaf of the count tree
// it is in, counts each name, and ends in a few reads, with the counts of
// the walk of the tables.
@(test)
a_repair_walks_a_repeated_tree_once :: proc(t: ^testing.T) {
	disk := disk_make(1100)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	under := disk_leaf(&disk, {{"a", object_entry(object, {})}})
	for _ in 0 ..< 6 {
		names := [11]string{"t00", "t01", "t02", "t03", "t04", "t05", "t06", "t07", "t08", "t09", "t10"}
		entries: [11]Named_Entry
		for &item, place in entries {
			item = {names[place], {kind = u64(format.Entry_Kind.Tree), size = 11, pointer = under}}
		}
		under = disk_leaf(&disk, entries[:])
	}
	block: format.Store_Block
	block.tree = under
	disk_root(&disk, disk_put(&disk, &block), 10)
	state, memory, tables := leaf_zero_break(t, &disk, 1100)
	defer delete(memory)
	defer free(state)
	defer test_state_free(tables)
	repair := test_repair_make(state, &disk)
	defer free(repair)
	repair_until_done(t, state, &disk, repair)
	testing.expectf(t, state.repair.reads < 50, "the repair read %d blocks", state.repair.reads)
	counts_expect(t, state, tables, "repeated trees")
}

// disk_folder writes a tree of a store of entries named in their order,
// each one an object, in leaves of 11 entries under branches of 14: the
// form of the writer of the service. It gives its root and its nodes.
@(private = "file")
disk_folder :: proc(disk: ^Test_Disk, entries: int, object: Object_Blocks) -> (root: format.Pointer, nodes: int) {
	pointers := make([dynamic]format.Pointer)
	names := make([dynamic]format.Entry_Name)
	defer delete(pointers)
	defer delete(names)
	entry := object_entry(object, {})
	for first := 0; first < entries; first += format.LEAF_CAPACITY {
		node: [BLOCK_SIZE]u8
		count := min(format.LEAF_CAPACITY, entries - first)
		header := (^format.Tree_Header)(&node)
		header^ = {magic = format.NODE_MAGIC, count = u32(count)}
		for index in 0 ..< count {
			record := node[format.TREE_HEADER_SIZE + index * LEAF_RECORD_SIZE:]
			name := (^format.Entry_Name)(raw_data(record))
			value := first + index
			for digit in 0 ..< 8 {
				name[7 - digit] = u8('0' + value % 10)
				value /= 10
			}
			copy(record[size_of(format.Entry_Name):], ([^]u8)(&entry)[:size_of(format.Entry)])
			if index == 0 {
				append(&names, name^)
			}
		}
		append(&pointers, disk_put(disk, &node))
	}
	nodes = len(pointers)
	for level := u32(1); len(pointers) > 1; level += 1 {
		above_pointers := make([dynamic]format.Pointer)
		above_names := make([dynamic]format.Entry_Name)
		for first := 0; first < len(pointers); first += format.BRANCH_CAPACITY {
			node: [BLOCK_SIZE]u8
			count := min(format.BRANCH_CAPACITY, len(pointers) - first)
			header := (^format.Tree_Header)(&node)
			header^ = {magic = format.NODE_MAGIC, level = level, count = u32(count)}
			for index in 0 ..< count {
				record := node[format.TREE_HEADER_SIZE + index * BRANCH_RECORD_SIZE:]
				(^format.Entry_Name)(raw_data(record))^ = names[first + index]
				(^format.Pointer)(&record[size_of(format.Entry_Name)])^ = pointers[first + index]
			}
			append(&above_names, names[first])
			append(&above_pointers, disk_put(disk, &node))
		}
		nodes += len(above_pointers)
		delete(pointers)
		delete(names)
		pointers, names = above_pointers, above_names
	}
	return pointers[0], nodes
}

// REPAIR_LARGE_FOLDER runs the repair of a folder of 500 000 entries, a
// disk of 200 MB in memory: opt-in (-define:REPAIR_LARGE_FOLDER=true).
REPAIR_LARGE_FOLDER :: #config(REPAIR_LARGE_FOLDER, false)

// The repair keeps the path of the last entry of a tree: each node of the
// tree is read once, and the entries of one leaf share its read. The reads
// of the run are the nodes of the folder, a few blocks more, never one
// path for each entry. It prints the measure.
@(test)
a_repair_reads_each_node_of_a_large_folder_once :: proc(t: ^testing.T) {
	entries := REPAIR_LARGE_FOLDER ? 500_000 : 20_000
	blocks := u64(entries / format.LEAF_CAPACITY * 11 / 10 + 1100)
	disk := disk_make(int(blocks))
	defer delete(disk.bytes)
	object := disk_object(&disk)
	tree, nodes := disk_folder(&disk, entries, object)
	block: format.Store_Block
	block.tree = tree
	block.objects = u64(entries)
	disk_root(&disk, disk_put(&disk, &block), u64(nodes + 2))
	state, memory, tables := leaf_zero_break(t, &disk, blocks)
	defer delete(memory)
	defer free(state)
	defer test_state_free(tables)
	testing.expect_value(t, tables.references[object.root.block], u32(entries))
	repair := test_repair_make(state, &disk)
	defer free(repair)
	steps := repair_until_done(t, state, &disk, repair)
	fmt.printfln("the repair of a folder of %d entries in %d nodes: %d reads and writes, %d steps", entries, nodes, state.repair.reads, steps)
	testing.expectf(t, state.repair.reads <= u64(nodes) + 16, "%d reads for %d nodes", state.repair.reads, nodes)
	counts_expect(t, state, tables, "a large folder")
}

// A disk nearly full: past the wrong leaf, one free block, which the
// scratch takes. The commit of the repair takes the blocks of its pages in
// the repaired leaf, from the counts of the repair, and the open of its
// root in the form Tables finds each leaf whole.
@(test)
the_commit_of_a_repair_on_a_full_disk :: proc(t: ^testing.T) {
	disk := disk_make(520)
	defer delete(disk.bytes)
	object := disk_large_object(&disk)
	table := disk_store(&disk, object, {})
	disk_root(&disk, table, 5)
	tables := test_state_make(520)
	defer test_state_free(tables)
	_ = mount(tables, &disk, 520)
	// Each block past leaf 0 in use but the last: the count tree says so.
	for number in u64(format.COUNTS_OF_A_PAGE) ..< 519 {
		tables.references[number] = 1
		tables.owner[number] = 1
	}
	root := count_tree_write(t, tables, &disk)
	root_counts_set(&disk, root, 1)
	state, memory := tree_state_make(520)
	defer delete(memory)
	defer free(state)
	testing.expect(t, !mount(state, &disk, 520).failed)
	leaf_zero_damage(t, state, &disk, root, 520)
	repair := test_repair_make(state, &disk)
	defer free(repair)
	repair_until_done(t, state, &disk, repair)
	testing.expect_value(t, len(state.counts.repaired), 1)
	taken, made := repair_commit_model(t, state, &disk)
	defer delete(taken)
	testing.expect(t, made, "the commit finds blocks for its pages")
	in_leaf := 0
	for number in taken {
		in_leaf += int(number < format.COUNTS_OF_A_PAGE)
	}
	testing.expect(t, in_leaf > 0, "the commit took a block of the repaired leaf")
	// The new tree, in the form Tables: whole, and it holds the walk. The
	// blocks past leaf 0 are in use in the tree only: the walk does not
	// name them.
	check := test_state_make(520)
	defer test_state_free(check)
	result := mount(check, &disk, 520)
	testing.expect(t, !result.failed && !result.count_tree_damaged)
	page, outcome := block_counts.page_get(&check.counts, 0, 0)
	testing.expect(t, outcome == .Good && page != nil, "leaf 0 reads whole")
}

// The top directory of the count tree is wrong: its pointers to the leaves
// are lost, so each leaf under it is wrong. The repair counts them all,
// and its commit makes the directory again from them; the open of the new
// root in the form Tables finds the counts of its walk. The old leaves,
// which no page names now, are free.
@(test)
a_wrong_directory_is_made_again :: proc(t: ^testing.T) {
	disk := disk_make(1100)
	defer delete(disk.bytes)
	object := disk_deep_object(&disk, 3)
	table := disk_store(&disk, object, {})
	disk_root(&disk, table, 9)
	tables := test_state_make(1100)
	defer test_state_free(tables)
	_ = mount(tables, &disk, 1100)
	root := count_tree_write(t, tables, &disk)
	root_counts_set(&disk, root, 1)
	testing.expect_value(t, mount(tables, &disk, 1100).count_leaves_differ, u64(0))
	testing.expect_value(t, format.count_tree_levels(1100), 1)
	state, memory := tree_state_make(1100)
	defer delete(memory)
	defer free(state)
	testing.expect(t, !mount(state, &disk, 1100).failed)
	disk.bytes[root.block * BLOCK_SIZE + 100] ~= 1
	testing.expect(t, block_counts.counts_bind(&state.counts, &state.count_source, root, 1100, state.counts.frames, state.counts.slots))
	_, _, outcome := block_counts.count_get(&state.counts, 5)
	testing.expect_value(t, outcome, block_counts.Read.Wrong)
	testing.expect_value(t, state.counts.wrong_directory_count, 1)
	testing.expect_value(t, state.counts.wrong_leaf_count, 3)
	repair := test_repair_make(state, &disk)
	defer free(repair)
	repair_until_done(t, state, &disk, repair)
	testing.expect_value(t, len(state.counts.repaired), 3)
	// The counts of the walk, but for the pages of the count tree under the
	// wrong directory: no page names them, so the repair gives them none.
	for number in u64(0) ..< 1100 {
		count, _, _ := block_counts.count_get(&state.counts, number)
		expected := tables.references[number]
		if tables.owner[number] == COUNT_TREE_OWNER && number != root.block {
			expected = 0
		}
		testing.expectf(t, count == expected, "block %d: %d, not %d", number, count, expected)
	}
	_, made := repair_commit_model(t, state, &disk)
	testing.expect(t, made, "the commit makes the directory again")
	repair_written(state)
	testing.expect_value(t, state.counts.wrong_directory_count, 0)
	testing.expect_value(t, state.counts.wrong_leaf_count, 0)
	check := test_state_make(1100)
	defer test_state_free(check)
	result := mount(check, &disk, 1100)
	testing.expect(t, !result.failed && !result.count_tree_damaged)
	testing.expect_value(t, result.count_leaves_differ, u64(0))
}

// recount_record_write writes in the top directory of the count tree of
// the disk the leaves to recount, as the commit of a release that met a
// wrong block does, and gives the new pointer of the top.
@(private = "file")
recount_record_write :: proc(disk: ^Test_Disk, top: format.Pointer, leaves: u64) -> format.Pointer {
	bytes := disk.bytes[top.block * BLOCK_SIZE:][:BLOCK_SIZE]
	(^format.Count_Directory)(raw_data(bytes)).leaves_to_recount = leaves
	pointer := format.Pointer{block = top.block, check = format.check(bytes)}
	root_counts_set(disk, pointer, 1)
	return pointer
}

// Recount_Disk is a store whose tree holds a live object of two levels in
// leaf 0, and whose removal queue holds one release: a list of one state
// in leaf 1 that shares the first node of level 1 of the live object.
@(private = "file")
Recount_Disk :: struct {
	disk:     Test_Disk,
	live:     Object_Blocks,
	shared:   format.Object_Child, // The node of level 1 that both states name.
	released: format.Pointer, // The root of the state of the release.
	own:      format.Object_Child, // A node of level 1 of the release only.
	list:     format.Pointer,
	top:      format.Pointer, // The top directory of the count tree, with each leaf to recount.
}

@(private = "file")
recount_disk_make :: proc(t: ^testing.T) -> (made: Recount_Disk) {
	made.disk = disk_make(1100)
	disk := &made.disk
	made.live = disk_deep_object(disk, 2)
	live_root := (^format.Object_Node)(&disk.bytes[made.live.root.block * BLOCK_SIZE])^
	made.shared = live_root.children[0]
	disk.next = 600
	other := disk_deep_object(disk, 2)
	mixed := (^format.Object_Node)(&disk.bytes[other.root.block * BLOCK_SIZE])^
	mixed.children[0] = made.shared
	made.own = mixed.children[1]
	made.released = disk_put(disk, &mixed)
	made.list = disk_release_list(disk, {{root = made.released, size = other.size}})
	disk.next = 100
	key := format.removal_name(1)
	block: format.Store_Block
	block.tree = disk_leaf(disk, {{"a", object_entry(made.live, {})}})
	block.removals = disk_leaf(disk, {{string(key[:8]), {kind = u64(format.Entry_Kind.Release), pointer = made.list}}})
	block.removing = 1
	block.objects = 1
	disk_root(disk, disk_put(disk, &block), 20)
	// The counts while the list was whole: the state of the release holds
	// its names.
	tables := test_state_make(1100)
	defer test_state_free(tables)
	_ = mount(tables, disk, 1100)
	testing.expect_value(t, tables.references[made.shared.block], u32(2))
	made.top = count_tree_write(t, tables, disk)
	made.top = recount_record_write(disk, made.top, format.count_tree_leaves(1100))
	return
}

// recount_until_done runs each run of the recount, each with the commit
// of the host model, and gives the count of the runs. Between two runs the
// service is not in the repair state: it takes changes.
@(private = "file")
recount_until_done :: proc(t: ^testing.T, state: ^State, disk: ^Test_Disk, repair: ^Test_Repair) -> (runs: int) {
	for recount_waits(state) {
		testing.expect(t, !repair_active(state), "the service takes changes between two runs")
		repair.last_root = (^format.Root)(raw_data(disk.bytes))^
		outcome := repair_step(state, disk, &repair.repair_disk)
		testing.expectf(t, outcome == .Running || outcome == .Done, "a run starts with %v", outcome)
		testing.expect(t, repair_active(state), "the service is in the repair state during a run")
		repair_until_done(t, state, disk, repair)
		testing.expect(t, repair_commit_waits(state), "the run ends with its commit")
		taken, made := repair_commit_model(t, state, disk)
		delete(taken)
		testing.expect(t, made, "the commit of the run is made")
		repair_written(state)
		runs += 1
		if runs > 100 {
			testing.fail_now(t, "the recount does not end")
		}
	}
	return runs
}

// recount_expect compares each count of the form Count_Tree with the walk
// of the form Tables of the same disk, and checks that the tree holds the
// counts of that walk.
@(private = "file")
recount_expect :: proc(t: ^testing.T, state: ^State, disk: ^Test_Disk, label: string) {
	check := test_state_make(1100)
	defer test_state_free(check)
	result := mount(check, disk, 1100)
	testing.expectf(t, !result.failed && !result.count_tree_damaged, "%s: the form Tables opens the disk", label)
	testing.expectf(t, result.count_leaves_differ == 0, "%s: %d leaves differ from the walk", label, result.count_leaves_differ)
	for number in u64(0) ..< 1100 {
		count, owner, read := block_counts.count_get(&state.counts, number)
		testing.expectf(t, read == .Good && count == check.references[number] && owner == check.owner[number], "%s: block %d: %d of %d, not %d of %d", label, number, count, owner, check.references[number], check.owner[number])
	}
}

// node_data gives the two data blocks of a node of level 1 of the test disk.
@(private = "file")
node_data :: proc(disk: ^Test_Disk, node: format.Object_Child) -> [2]u64 {
	read := (^format.Object_Node)(&disk.bytes[node.block * BLOCK_SIZE])
	return {read.children[0].block, read.children[1].block}
}

// A wrong release list in the form Count_Tree: the commit that dropped it
// wrote each leaf to recount in the top directory. The open reads that
// record; runs of one leaf count leaf 0 and leaf 1, and pass leaf 2,
// which holds no block in use. The blocks that only the list named are
// free after it; the node that the live object shares keeps its one live
// name, and each count is that of the walk.
@(test)
a_recount_frees_the_blocks_of_a_wrong_release_list :: proc(t: ^testing.T) {
	made := recount_disk_make(t)
	disk := &made.disk
	defer delete(disk.bytes)
	own_data := node_data(disk, made.own)
	disk.bytes[made.list.block * BLOCK_SIZE + 100] ~= 1
	state, memory := tree_state_make(1100)
	defer delete(memory)
	defer free(state)
	testing.expect(t, !mount(state, disk, 1100).failed)
	testing.expect_value(t, state.counts.leaves_to_recount, u64(3))
	testing.expect(t, recount_waits(state), "the recount waits for a run")
	testing.expect(t, !repair_active(state), "the service takes changes before the first run")
	count, _, _ := block_counts.count_get(&state.counts, own_data[0])
	testing.expect_value(t, count, u32(1))
	state.repair.recount_leaves = 1
	repair := test_repair_make(state, disk)
	defer free(repair)
	runs := recount_until_done(t, state, disk, repair)
	testing.expect_value(t, runs, 2)
	testing.expect_value(t, state.counts.leaves_to_recount, u64(0))
	testing.expect(t, !recount_waits(state) && !repair_active(state), "the recount ended")
	for number in ([?]u64{made.released.block, made.own.block, own_data[0], own_data[1]}) {
		count, _, _ = block_counts.count_get(&state.counts, number)
		testing.expectf(t, count == 0, "block %d of the wrong list: %d names", number, count)
	}
	count, _, _ = block_counts.count_get(&state.counts, made.shared.block)
	testing.expect_value(t, count, u32(1))
	for number in node_data(disk, made.shared) {
		count, _, _ = block_counts.count_get(&state.counts, number)
		testing.expectf(t, count == 1, "live block %d: %d names", number, count)
	}
	count, _, _ = block_counts.count_get(&state.counts, made.list.block)
	testing.expect_value(t, count, u32(1))
	recount_expect(t, state, disk, "a wrong list")
}

// A wrong node of a state of a release: the blocks under it have no name
// after the recount; the root of the state and the shared node keep
// theirs.
@(test)
a_recount_frees_the_blocks_under_a_wrong_release_node :: proc(t: ^testing.T) {
	made := recount_disk_make(t)
	disk := &made.disk
	defer delete(disk.bytes)
	own_data := node_data(disk, made.own)
	disk.bytes[made.own.block * BLOCK_SIZE + 100] ~= 1
	state, memory := tree_state_make(1100)
	defer delete(memory)
	defer free(state)
	testing.expect(t, !mount(state, disk, 1100).failed)
	repair := test_repair_make(state, disk)
	defer free(repair)
	runs := recount_until_done(t, state, disk, repair)
	testing.expect_value(t, runs, 1)
	for number in own_data {
		count, _, _ := block_counts.count_get(&state.counts, number)
		testing.expectf(t, count == 0, "block %d under the wrong node: %d names", number, count)
	}
	count, _, _ := block_counts.count_get(&state.counts, made.shared.block)
	testing.expect_value(t, count, u32(2))
	count, _, _ = block_counts.count_get(&state.counts, made.released.block)
	testing.expect_value(t, count, u32(1))
	recount_expect(t, state, disk, "a wrong node")
}

// A loss of power during the second run: the scratch is lost, the record
// is not. The next open reads the leaves left to recount from the top that
// the commit of the first run wrote, and goes on from there.
@(test)
a_loss_of_power_during_a_recount :: proc(t: ^testing.T) {
	made := recount_disk_make(t)
	disk := &made.disk
	defer delete(disk.bytes)
	own_data := node_data(disk, made.own)
	disk.bytes[made.list.block * BLOCK_SIZE + 100] ~= 1
	state, memory := tree_state_make(1100)
	defer delete(memory)
	defer free(state)
	testing.expect(t, !mount(state, disk, 1100).failed)
	state.repair.recount_leaves = 1
	repair := test_repair_make(state, disk)
	defer free(repair)
	first := repair_step(state, disk, &repair.repair_disk)
	testing.expect(t, first == .Running || first == .Done, "the first run starts")
	repair_until_done(t, state, disk, repair)
	taken, committed := repair_commit_model(t, state, disk)
	delete(taken)
	testing.expect(t, committed)
	repair_written(state)
	testing.expect_value(t, state.counts.leaves_to_recount, u64(2))
	state.repair.nodes_per_step = 1
	repair.last_root = (^format.Root)(raw_data(disk.bytes))^
	for _ in 0 ..< 3 {
		testing.expect_value(t, repair_step(state, disk, &repair.repair_disk), Repair_Outcome.Running)
	}

	again, again_memory := tree_state_make(1100)
	defer delete(again_memory)
	defer free(again)
	testing.expect(t, !mount(again, disk, 1100).failed)
	testing.expect_value(t, again.counts.leaves_to_recount, u64(2))
	again.repair.recount_leaves = 1
	second := test_repair_make(again, disk)
	defer free(second)
	testing.expect_value(t, recount_until_done(t, again, disk, second), 1)
	testing.expect_value(t, again.counts.leaves_to_recount, u64(0))
	count, _, _ := block_counts.count_get(&again.counts, own_data[0])
	testing.expect_value(t, count, u32(0))
	recount_expect(t, again, disk, "after the loss of power")
}

// The record of the top directory names at most each leaf of the disk:
// one more, or the largest value, makes the top wrong. Its repair makes the
// top again with each leaf to recount, the safe side, and the recount then
// gives the counts of the walk.
@(test)
a_record_past_the_leaves_makes_the_top_wrong :: proc(t: ^testing.T) {
	for leaves in ([?]u64{format.count_tree_leaves(1100) + 1, max(u64)}) {
		made := recount_disk_make(t)
		disk := &made.disk
		defer delete(disk.bytes)
		_ = recount_record_write(disk, made.top, leaves)
		state, memory := tree_state_make(1100)
		defer delete(memory)
		defer free(state)
		testing.expect(t, !mount(state, disk, 1100).failed)
		testing.expectf(t, state.counts.leaves_to_recount == 0, "%d: no record is taken", leaves)
		testing.expectf(t, state.counts.wrong_directory_count == 1, "%d: the top is a wrong directory", leaves)
		testing.expect(t, !recount_waits(state) && repair_waits(state), "the repair of the top runs first")
		repair := test_repair_make(state, disk)
		defer free(repair)
		repair_until_done(t, state, disk, repair)
		taken, committed := repair_commit_model(t, state, disk)
		delete(taken)
		testing.expect(t, committed)
		repair_written(state)
		testing.expectf(t, state.counts.leaves_to_recount == format.count_tree_leaves(1100), "%d: the new top names each leaf", leaves)
		recount_until_done(t, state, disk, repair)
		recount_expect(t, state, disk, "a record past the leaves")
	}
	// The edges of the count of the leaves.
	testing.expect_value(t, format.count_tree_leaves(0), u64(0))
	testing.expect_value(t, format.count_tree_leaves(1), u64(1))
	testing.expect_value(t, format.count_tree_leaves(format.COUNTS_OF_A_PAGE), u64(1))
	testing.expect_value(t, format.count_tree_leaves(format.COUNTS_OF_A_PAGE + 1), u64(2))
}
