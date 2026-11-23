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
