#+build !freestanding
package storage_mount

import format "modus:contract/store"
import block_tree "internal:storage/storage_object"
import "core:testing"

// A disk built in memory, block by block, and read through a Block_Reader.
Test_Disk :: struct {
	using reader: Block_Reader,
	bytes:        []u8,
	next:         u64, // The next free block; 0 and 1 are the roots.
}

test_read :: proc "contextless" (reader: ^Block_Reader, numbers: []u64, into: []u8) -> bool {
	disk := (^Test_Disk)(reader)
	for number, index in numbers {
		if (number + 1) * BLOCK_SIZE > u64(len(disk.bytes)) {
			return false
		}
		copy(into[index * BLOCK_SIZE:][:BLOCK_SIZE], disk.bytes[number * BLOCK_SIZE:][:BLOCK_SIZE])
	}
	return true
}

disk_make :: proc(blocks: int) -> (disk: Test_Disk) {
	disk.reader = {read = test_read}
	disk.bytes = make([]u8, blocks * BLOCK_SIZE)
	disk.next = 2
	return disk
}

// disk_put writes a value in the next free block and gives its Pointer.
disk_put :: proc(disk: ^Test_Disk, value: ^$T) -> format.Pointer where size_of(T) == BLOCK_SIZE {
	number := disk.next
	disk.next += 1
	block := disk.bytes[number * BLOCK_SIZE:][:BLOCK_SIZE]
	copy(block, ([^]u8)(value)[:BLOCK_SIZE])
	return {block = number, check = format.check(block)}
}

// The blocks that the tables of a test state hold, and the roots of its
// hash index: more than each disk of these tests.
TEST_STATE_BLOCKS :: 4096
TEST_STATE_HASH_ROOTS :: 4096

// test_state_make gives a State with memory for its tables.
test_state_make :: proc(blocks: u64 = TEST_STATE_BLOCKS, hash_roots: u64 = TEST_STATE_HASH_ROOTS) -> ^State {
	state := new(State)
	layout, ok := state_layout(blocks, hash_roots)
	assert(ok)
	memory := make([]u64, (layout.bytes + 7) / 8)
	bound := state_bind(state, ([^]u8)(raw_data(memory))[:layout.bytes], blocks, hash_roots)
	assert(bound)
	return state
}

// test_state_free frees a State of test_state_make and its memory.
test_state_free :: proc(state: ^State) {
	free(raw_data(state.in_use))
	free(state)
}

// disk_page writes a page of the store table with one store in each cell
// that `stores` gives, and gives its Pointer.
disk_page :: proc(disk: ^Test_Disk, stores: []format.Store_Entry) -> format.Pointer {
	page: format.Store_Table_Page
	page.magic = format.STORE_TABLE_MAGIC
	copy(page.cells[:], stores)
	return disk_put(disk, &page)
}

// root_of_page gives a root of the disk with one page of the store table.
root_of_page :: proc(disk_blocks: u64, generation: u64, page: format.Pointer) -> (root: format.Root) {
	root = {magic = format.ROOT_MAGIC, generation = generation, disk_blocks = disk_blocks, store_page_count = 1}
	root.store_pages[0] = page
	root.check = format.root_check(&root)
	return root
}

// store_s gives the cell of one store "s".
store_s :: proc(store_block: format.Pointer, used: u64) -> (cell: format.Store_Entry) {
	cell.name[0] = 's'
	cell.limit = 1 << 20
	cell.used = used
	cell.store = store_block
	return cell
}

// disk_root writes the page of one store "s", and the root that names it
// in block 0.
disk_root :: proc(disk: ^Test_Disk, store_block: format.Pointer, used: u64) {
	page := disk_page(disk, {store_s(store_block, used)})
	root := root_of_page(u64(len(disk.bytes) / BLOCK_SIZE), 2, page)
	copy(disk.bytes[:BLOCK_SIZE], ([^]u8)(&root)[:BLOCK_SIZE])
}

// One object "a" of 10 bytes: one block of data, the root of its block
// tree. size: its size in the entry.
Object_Blocks :: struct {
	root: format.Pointer,
	data: format.Pointer,
	size: u64,
}

// disk_data writes a block of data of an object, at the block `index` of
// it: its check is its value at that place.
disk_data :: proc(disk: ^Test_Disk, bytes: ^block_tree.Block, index: u64) -> (pointer: format.Pointer, value: format.Block_Value) {
	value = block_tree.block_value(bytes, index)
	pointer = disk_put(disk, bytes)
	pointer.check = format.value_check(value)
	return pointer, value
}

disk_object :: proc(disk: ^Test_Disk) -> (blocks: Object_Blocks) {
	data: block_tree.Block
	copy(data[:], "ten bytes!")
	blocks.data, _ = disk_data(disk, &data, 0)
	blocks.root = blocks.data
	blocks.size = 10
	return blocks
}

// disk_large_object writes an object of two blocks: an object node of
// level 1 and its two blocks of data.
disk_large_object :: proc(disk: ^Test_Disk) -> (blocks: Object_Blocks) {
	node: format.Object_Node
	node.header = {level = 1, count = 2, magic = format.OBJECT_NODE_MAGIC}
	for index in 0 ..< 2 {
		data: block_tree.Block
		for &byte, place in data {
			byte = u8(index + 1 + place % 13)
		}
		pointer, value := disk_data(disk, &data, u64(index))
		node.children[index] = {block = pointer.block, check = pointer.check, blocks = 1, value = value}
		if index == 0 {
			blocks.data = pointer
		}
	}
	blocks.root = disk_put(disk, &node)
	blocks.size = BLOCK_SIZE + 100
	return blocks
}

Named_Entry :: struct {
	name:  string,
	entry: format.Entry,
}

// disk_leaf writes a leaf of a tree with these entries, in their order.
disk_leaf :: proc(disk: ^Test_Disk, entries: []Named_Entry) -> format.Pointer {
	node: [BLOCK_SIZE]u8
	header := (^format.Tree_Header)(&node)
	header.magic = format.NODE_MAGIC
	header.count = u32(len(entries))
	size := size_of(format.Entry_Name) + size_of(format.Entry)
	for item, index in entries {
		place := node[format.TREE_HEADER_SIZE + index * size:]
		copy(place, item.name)
		entry := item.entry
		copy(place[size_of(format.Entry_Name):], ([^]u8)(&entry)[:size_of(format.Entry)])
	}
	return disk_put(disk, &node)
}

object_entry :: proc(object: Object_Blocks, versions: format.Pointer) -> format.Entry {
	return {kind = u64(format.Entry_Kind.Object), size = object.size, pointer = object.root, versions = versions}
}

// disk_store writes a leaf with the one object "a", and the store block
// that names it, with the counts of that store.
disk_store :: proc(disk: ^Test_Disk, object: Object_Blocks, versions: format.Pointer) -> format.Pointer {
	entries := []Named_Entry{{"a", object_entry(object, versions)}}
	leaf := disk_leaf(disk, entries)
	block: format.Store_Block
	block.tree = leaf
	block.objects = 1
	block.current_blocks = 1
	block.node_blocks = 1
	return disk_put(disk, &block)
}

// An index that names more leaves than an index holds is damage: the open
// marks it wrong, and does not read past its leaves.
@(test)
an_index_with_too_many_leaves :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	index: format.Version_Index
	index.leaf_count = 300
	index_pointer := disk_put(&disk, &index)
	table := disk_store(&disk, object, index_pointer)
	disk_root(&disk, table, 4)
	state := test_state_make()
	defer test_state_free(state)
	result := mount(state, &disk, 16)
	testing.expect(t, !result.failed)
	testing.expect_value(t, result.damaged_versions, 1)
	testing.expect_value(t, result.wrong, 1)
	testing.expect(t, wrong_block(state, index_pointer.block))
	testing.expect_value(t, result.objects, 1)
	testing.expect_value(t, result.damaged_objects, 0)
}

// A leaf with no entry, and a leaf with more entries than it holds, are
// damage.
@(test)
leaves_with_a_wrong_count :: proc(t: ^testing.T) {
	for count in ([]u64{0, format.VERSION_LEAF_CAPACITY + 1}) {
		disk := disk_make(16)
		defer delete(disk.bytes)
		object := disk_object(&disk)
		leaf: format.Version_Leaf
		leaf.count = count
		leaf_pointer := disk_put(&disk, &leaf)
		index: format.Version_Index
		index.leaf_count = 1
		index.leaves[0] = leaf_pointer
		index_pointer := disk_put(&disk, &index)
		disk_root(&disk, disk_store(&disk, object, index_pointer), 5)
		state := test_state_make()
		defer test_state_free(state)
		result := mount(state, &disk, 16)
		testing.expectf(t, result.damaged_versions == 1 && wrong_block(state, leaf_pointer.block), "a leaf of %d entries: %d damaged versions", count, result.damaged_versions)
		testing.expect_value(t, result.versions, 0)
	}
}

// A version whose size passes the size of an object is damage: its root is
// marked wrong, so the engine never releases the blocks under it.
@(test)
a_version_too_large :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	other := disk_large_object(&disk)
	leaf: format.Version_Leaf
	leaf.count = 1
	leaf.entries[0] = {generation = 1, size = format.OBJECT_SIZE_LIMIT + 1, root = other.root}
	leaf_pointer := disk_put(&disk, &leaf)
	index: format.Version_Index
	index.leaf_count = 1
	index.leaves[0] = leaf_pointer
	index_pointer := disk_put(&disk, &index)
	disk_root(&disk, disk_store(&disk, object, index_pointer), 8)
	state := test_state_make()
	defer test_state_free(state)
	result := mount(state, &disk, 32)
	testing.expect_value(t, result.damaged_versions, 1)
	testing.expect(t, wrong_block(state, other.root.block))
	testing.expect_value(t, state.references[other.data.block], 0)
}

// The count of a store in the root that is not its distinct blocks: the open
// takes the recount, and says that the engine wrote a wrong count.
@(test)
the_recount_of_a_store :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	disk_root(&disk, disk_store(&disk, object, {}), 99)
	state := test_state_make()
	defer test_state_free(state)
	result := mount(state, &disk, 16)
	testing.expect_value(t, state.store_recount[0], 3) // The store block, the leaf, the block of data.
	testing.expect_value(t, result.stores_recounted, 1)
	testing.expect_value(t, result.stores_with_wrong_count, 1)
	testing.expect(t, !state.store_faulty[0])
}

// A store with a damaged object: the recount does not count the blocks under
// the wrong object node, and it is no fault of the engine.
@(test)
the_recount_of_a_damaged_store :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_large_object(&disk)
	disk.bytes[object.root.block * BLOCK_SIZE + 40] ~= 1 // The object node no longer has its check.
	disk_root(&disk, disk_store(&disk, object, {}), 4)
	state := test_state_make()
	defer test_state_free(state)
	result := mount(state, &disk, 16)
	testing.expect_value(t, result.damaged_objects, 1)
	testing.expect_value(t, state.store_damaged_objects[0], 1)
	testing.expect_value(t, state.store_recount[0], 3) // The store block, the leaf and the wrong object node; not the blocks of data.
	testing.expect_value(t, result.stores_with_wrong_count, 0)
	testing.expect(t, !used(state, object.data.block))
	testing.expect(t, damaged_under(state, object.root.block))
	testing.expect(t, !state.store_damaged[0])
}

// A block of data whose bytes changed on the disk: its value at its place
// is not the value that its node holds. Its object is damaged; the node is
// read and counted.
@(test)
a_changed_block_of_data :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_large_object(&disk)
	disk.bytes[object.data.block * BLOCK_SIZE + 7] ~= 0x40
	disk_root(&disk, disk_store(&disk, object, {}), 6)
	state := test_state_make()
	defer test_state_free(state)
	result := mount(state, &disk, 16)
	testing.expect_value(t, result.damaged_objects, 1)
	testing.expect_value(t, result.wrong, 1)
	testing.expect(t, wrong_block(state, object.data.block))
	testing.expect(t, damaged_under(state, object.root.block))
	testing.expect_value(t, state.store_recount[0], 5) // The store block, the leaf, the node, its two blocks.
}

// An object of two blocks and a version that shares its root: the blocks
// are read one time, each named once by the node, and the root twice.
@(test)
a_shared_block_tree :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_large_object(&disk)
	leaf: format.Version_Leaf
	leaf.count = 1
	leaf.entries[0] = {generation = 1, size = object.size, root = object.root}
	leaf_pointer := disk_put(&disk, &leaf)
	index: format.Version_Index
	index.leaf_count = 1
	index.version_count = 1
	index.leaves[0] = leaf_pointer
	index_pointer := disk_put(&disk, &index)
	entries := []Named_Entry{{"a", object_entry(object, index_pointer)}}
	block: format.Store_Block
	block.tree = disk_leaf(&disk, entries)
	block.objects = 1
	block.current_blocks = 3
	block.node_blocks = 1
	disk_root(&disk, disk_put(&disk, &block), 7)
	state := test_state_make()
	defer test_state_free(state)
	result := mount(state, &disk, 16)
	testing.expect_value(t, result.wrong, 0)
	testing.expect_value(t, state.references[object.root.block], 2)
	testing.expect_value(t, state.references[object.data.block], 1)
	testing.expect_value(t, result.stores_with_wrong_count, 0)
	testing.expect_value(t, state.store_heads[0].current_blocks, 3)
}

// A store whose counts are right: no fault, and the open keeps them.
@(test)
a_store_with_its_counts :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	disk_root(&disk, disk_store(&disk, object, {}), 3)
	state := test_state_make()
	defer test_state_free(state)
	result := mount(state, &disk, 16)
	testing.expect_value(t, result.stores_with_wrong_count, 0)
	testing.expect_value(t, result.stores_recounted, 0)
	testing.expect_value(t, result.objects, 1)
	testing.expect_value(t, state.store_heads[0].current_blocks, 1)
}

// A tree inside a tree: its nodes and its entries are walked and counted;
// an entry that gives another count of entries than its tree has is a
// fault of the engine.
@(test)
a_tree_inside_a_tree :: proc(t: ^testing.T) {
	for given_count in ([]u64{2, 3}) {
		disk := disk_make(16)
		defer delete(disk.bytes)
		first := disk_object(&disk)
		second := disk_object(&disk)
		inner := disk_leaf(&disk, {{"x", object_entry(first, {})}, {"y", object_entry(second, {})}})
		outer := disk_leaf(&disk, {{"inner", {kind = u64(format.Entry_Kind.Tree), size = given_count, pointer = inner}}})
		block: format.Store_Block
		block.tree = outer
		block.objects = 2
		block.trees = 1
		block.current_blocks = 2
		block.node_blocks = 2
		disk_root(&disk, disk_put(&disk, &block), 5)
		state := test_state_make()
		defer test_state_free(state)
		result := mount(state, &disk, 16)
		testing.expect_value(t, result.objects, 2)
		testing.expect_value(t, result.trees, 1)
		testing.expect_value(t, result.wrong, 0)
		testing.expect_value(t, state.store_recount[0], 5)
		testing.expect_value(t, result.stores_with_wrong_count, given_count == 2 ? 0 : 1)
	}
}

// A leaf whose names are out of order breaks a rule of the format: its
// store is damaged, as with a wrong check.
@(test)
a_leaf_out_of_order :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	first := disk_object(&disk)
	second := disk_object(&disk)
	leaf := disk_leaf(&disk, {{"b", object_entry(first, {})}, {"a", object_entry(second, {})}})
	block: format.Store_Block
	block.tree = leaf
	disk_root(&disk, disk_put(&disk, &block), 6)
	state := test_state_make()
	defer test_state_free(state)
	result := mount(state, &disk, 16)
	testing.expect(t, !result.failed)
	testing.expect(t, state.store_damaged[0])
	testing.expect_value(t, result.damaged_stores, 1)
	testing.expect(t, wrong_block(state, leaf.block))
}

// The checks of a root with no block that a damaged disk can hold: the
// smallest, a value that a conversion to int makes negative, the largest.
DAMAGED_ROOT_CHECKS :: [?]u64{1, 1 << 63, max(u64)}

// A root of the tree or of the removal queue of a store, with no block and
// a check that is not 0, names no node: the commits of the service refuse
// it, so the open marks its store damaged, and names no wrong block. The
// counts of the store block stay the ones of the disk.
@(test)
a_store_root_with_no_block_is_damaged :: proc(t: ^testing.T) {
	checks := DAMAGED_ROOT_CHECKS
	for which in 0 ..< 2 {
		for check in checks {
			disk := disk_make(16)
			defer delete(disk.bytes)
			block: format.Store_Block
			block.objects = 7
			if which == 0 {
				block.tree = {block = 0, check = check}
			} else {
				block.removals = {block = 0, check = check}
			}
			disk_root(&disk, disk_put(&disk, &block), 1)
			state := test_state_make()
			defer test_state_free(state)
			result := mount(state, &disk, 16)
			testing.expect(t, !result.failed)
			testing.expectf(t, state.store_damaged[0], "the root %d with the check %d: the store is not damaged", which, check)
			testing.expect_value(t, result.damaged_stores, 1)
			testing.expect_value(t, result.wrong, 0)
			testing.expect_value(t, state.store_heads[0].objects, 7)
		}
	}
	// Two empty roots: an empty store, with no damage.
	disk := disk_make(16)
	defer delete(disk.bytes)
	block: format.Store_Block
	disk_root(&disk, disk_put(&disk, &block), 1)
	state := test_state_make()
	defer test_state_free(state)
	result := mount(state, &disk, 16)
	testing.expect(t, !state.store_damaged[0])
	testing.expect_value(t, result.damaged_stores, 0)
	testing.expect_value(t, result.stores_with_wrong_count, 0)
}

// The entry of an inner tree whose root has no block and a check that is
// not 0, with a size of 0: no empty tree, but damage of its store.
@(test)
a_tree_entry_with_no_block_is_damaged :: proc(t: ^testing.T) {
	checks := DAMAGED_ROOT_CHECKS
	for check in checks {
		disk := disk_make(16)
		defer delete(disk.bytes)
		outer := disk_leaf(&disk, {{"inner", {kind = u64(format.Entry_Kind.Tree), pointer = {block = 0, check = check}}}})
		block: format.Store_Block
		block.tree = outer
		block.trees = 1
		block.node_blocks = 1
		disk_root(&disk, disk_put(&disk, &block), 2)
		state := test_state_make()
		defer test_state_free(state)
		result := mount(state, &disk, 16)
		testing.expect(t, !result.failed)
		testing.expectf(t, state.store_damaged[0], "the check %d: the store is not damaged", check)
		testing.expect_value(t, result.damaged_stores, 1)
		testing.expect_value(t, result.wrong, 0)
	}
	// An empty inner tree: a root with no block and the check 0.
	disk := disk_make(16)
	defer delete(disk.bytes)
	outer := disk_leaf(&disk, {{"inner", {kind = u64(format.Entry_Kind.Tree)}}})
	block: format.Store_Block
	block.tree = outer
	block.trees = 1
	block.node_blocks = 1
	disk_root(&disk, disk_put(&disk, &block), 2)
	state := test_state_make()
	defer test_state_free(state)
	result := mount(state, &disk, 16)
	testing.expect(t, !state.store_damaged[0])
	testing.expect_value(t, result.damaged_stores, 0)
	testing.expect_value(t, result.trees, 1)
	testing.expect_value(t, result.stores_with_wrong_count, 0)
}

// More than 65535 names of one block: four objects with full version
// indexes, each version the same root. The count holds them all.
@(test)
a_count_above_sixteen_bits :: proc(t: ^testing.T) {
	OBJECTS :: 4
	blocks := 8 + OBJECTS * (format.VERSION_INDEX_CAPACITY + 1)
	disk := disk_make(blocks)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	leaf: format.Version_Leaf
	leaf.count = format.VERSION_LEAF_CAPACITY
	for &entry, place in leaf.entries {
		entry = {generation = u64(place + 1), size = 10, root = object.root}
	}
	entries: [OBJECTS]Named_Entry
	names := [OBJECTS]string{"a", "b", "c", "d"}
	for object_index in 0 ..< OBJECTS {
		index: format.Version_Index
		index.leaf_count = format.VERSION_INDEX_CAPACITY
		index.version_count = format.VERSIONS_LIMIT
		for &pointer in index.leaves {
			pointer = disk_put(&disk, &leaf)
		}
		entries[object_index] = {names[object_index], object_entry(object, disk_put(&disk, &index))}
	}
	block: format.Store_Block
	block.tree = disk_leaf(&disk, entries[:])
	block.objects = OBJECTS
	block.current_blocks = OBJECTS
	block.node_blocks = 1
	store_block := disk_put(&disk, &block)
	disk_root(&disk, store_block, disk.next - 2)
	state := test_state_make()
	defer test_state_free(state)
	result := mount(state, &disk, u64(blocks))
	references := u64(OBJECTS) * (1 + format.VERSIONS_LIMIT)
	testing.expect(t, references > 65535)
	testing.expect_value(t, u64(state.references[object.root.block]), references)
	testing.expect_value(t, result.reference_overflow, 0)
	testing.expect_value(t, result.stores_with_wrong_count, 0)
	testing.expect(t, !state.store_faulty[0])
	testing.expect_value(t, result.versions, u64(OBJECTS) * format.VERSIONS_LIMIT)
}

// More stores than the 60 cells of the format before, in two pages of the
// store table: the open walks each one. A page with a wrong check damages
// its stores only, and the open serves the stores of the other page.
@(test)
more_than_sixty_stores_in_two_pages :: proc(t: ^testing.T) {
	STORES :: 100
	disk := disk_make(STORES + 8)
	defer delete(disk.bytes)
	empty: format.Store_Block
	cells: [STORES]format.Store_Entry
	for &cell, index in cells {
		cell.name[0] = 'a' + u8(index / 26)
		cell.name[1] = 'a' + u8(index % 26)
		cell.limit = 64
		cell.used = 1 // The store block alone: the tree is empty.
		cell.store = disk_put(&disk, &empty)
	}
	first := disk_page(&disk, cells[:format.STORES_OF_A_PAGE])
	second := disk_page(&disk, cells[format.STORES_OF_A_PAGE:])
	root := format.Root{magic = format.ROOT_MAGIC, generation = 2, disk_blocks = u64(len(disk.bytes) / BLOCK_SIZE), store_page_count = 2}
	root.store_pages[0], root.store_pages[1] = first, second
	root.check = format.root_check(&root)
	copy(disk.bytes[:BLOCK_SIZE], ([^]u8)(&root)[:BLOCK_SIZE])
	state := test_state_make()
	defer test_state_free(state)
	result := mount(state, &disk, root.disk_blocks)
	testing.expect(t, !result.failed)
	testing.expect_value(t, result.stores, STORES)
	testing.expect_value(t, result.wrong, 0)
	testing.expect_value(t, result.stores_with_wrong_count, 0)
	testing.expect_value(t, store_numbers(state), 2 * format.STORES_OF_A_PAGE)
	testing.expect_value(t, store_cell(state, STORES - 1).store, cells[STORES - 1].store)
	testing.expect_value(t, state.owner[second.block], STORE_TABLE_OWNER)
	// The in-use blocks: the two roots, the store blocks and the two pages.
	testing.expect_value(t, state.in_use_count, u64(2 + STORES + 2))

	// One byte of the second page changed: its 37 stores are not served.
	disk.bytes[second.block * BLOCK_SIZE + 100] ~= 1
	damaged := mount(state, &disk, root.disk_blocks)
	testing.expect(t, !damaged.failed)
	testing.expect_value(t, damaged.damaged_store_pages, 1)
	testing.expect_value(t, damaged.stores, format.STORES_OF_A_PAGE)
	testing.expect(t, state.store_page_damaged[1] && !state.store_page_damaged[0])
	testing.expect(t, wrong_block(state, second.block))
}

// A page whose magic is not the magic of a page, or whose name has a byte
// after its end, is damage, as a wrong check.
@(test)
a_page_that_breaks_a_rule :: proc(t: ^testing.T) {
	for which in 0 ..< 2 {
		disk := disk_make(16)
		defer delete(disk.bytes)
		page: format.Store_Table_Page
		page.magic = format.STORE_TABLE_MAGIC
		page.cells[0] = store_s({}, 1)
		if which == 0 {
			page.magic = format.NODE_MAGIC
		} else {
			page.cells[0].name[5] = 'x'
		}
		root := root_of_page(16, 2, disk_put(&disk, &page))
		copy(disk.bytes[:BLOCK_SIZE], ([^]u8)(&root)[:BLOCK_SIZE])
		state := test_state_make()
		defer test_state_free(state)
		result := mount(state, &disk, 16)
		testing.expect_value(t, result.damaged_store_pages, 1)
		testing.expect_value(t, result.stores, 0)
	}
}

// A disk whose root names more blocks than the tables hold: the open uses
// no root rather than lose the blocks past the tables, and says why.
@(test)
a_disk_larger_than_the_tables :: proc(t: ^testing.T) {
	disk := disk_make(32)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	disk_root(&disk, disk_store(&disk, object, {}), 3)
	state := test_state_make(16, 16)
	defer test_state_free(state)
	result := mount(state, &disk, 32)
	testing.expect(t, result.failed)
	testing.expect(t, result.larger_than_capacity)
	// A State with no memory opens nothing.
	unbound := new(State)
	defer free(unbound)
	testing.expect(t, mount(unbound, &disk, 32).failed)
}

// The memory of the tables follows the disk: 3 bits and BLOCK_STATE_BYTES
// for each block, and the hash index for its roots. A count of blocks or
// of roots that no disk has, and a memory too small or not aligned, are
// refused.
@(test)
the_memory_of_the_tables :: proc(t: ^testing.T) {
	blocks_64gib := u64(1) << 24
	layout, ok := state_layout(blocks_64gib, 1 << 17)
	testing.expect(t, ok)
	testing.expect_value(t, layout.hash_capacity, u64(1) << 18)
	expected := 3 * (blocks_64gib / 64) * 8 + blocks_64gib * BLOCK_STATE_BYTES + (u64(1) << 18) * (size_of(Root_Record) + size_of(u64))
	testing.expect_value(t, layout.bytes, expected)
	// The largest disk: its layout does not wrap.
	largest, largest_ok := state_layout(format.DISK_BLOCKS_MAX, 16)
	testing.expect(t, largest_ok && largest.bytes > format.DISK_BLOCKS_MAX * BLOCK_STATE_BYTES)
	for blocks in ([?]u64{0, 1, format.DISK_BLOCKS_MAX + 1, max(u64)}) {
		_, refused := state_layout(blocks, 16)
		testing.expectf(t, !refused, "a layout of %d blocks is taken", blocks)
	}
	_, no_roots := state_layout(16, 0)
	testing.expect(t, !no_roots)
	small, _ := state_layout(16, 16)
	memory := make([]u64, small.bytes / 8 + 1)
	defer delete(memory)
	state := new(State)
	defer free(state)
	bytes := ([^]u8)(raw_data(memory))[:small.bytes + 8]
	testing.expect(t, !state_bind(state, bytes[:small.bytes - 1], 16, 16))
	testing.expect(t, !state_bind(state, bytes[1:], 16, 16))
	testing.expect(t, state_bind(state, bytes[:small.bytes], 16, 16))
	testing.expect_value(t, state.capacity, u64(16))
}

// A store block named from two stores: a fault of the engine, and each of
// the two stores is faulty.
@(test)
a_block_named_from_two_stores :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_object(&disk)
	store_block := disk_store(&disk, object, {})
	cells: [2]format.Store_Entry
	for &cell, index in cells {
		cell.name[0] = u8('s' + index)
		cell.limit = 64
		cell.used = 4
		cell.store = store_block
	}
	root := root_of_page(16, 2, disk_page(&disk, cells[:]))
	copy(disk.bytes[:BLOCK_SIZE], ([^]u8)(&root)[:BLOCK_SIZE])
	state := test_state_make()
	defer test_state_free(state)
	result := mount(state, &disk, 16)
	testing.expect(t, result.named_by_two_stores > 0)
	testing.expect(t, state.store_faulty[0] && state.store_faulty[1])
}

// A hash whose first 8 bytes are `prefix`, and `tail` after them.
hash_with_prefix :: proc(prefix: u64, tail: u8) -> (hash: [32]u8) {
	for index in 0 ..< 8 {
		hash[index] = u8(prefix >> uint(8 * index))
	}
	for index in 8 ..< 32 {
		hash[index] = tail
	}
	return hash
}

// Two entries that name one root (the same object under two names): the
// open puts the root in the hash index one time, with two entries, and a
// search by the hash finds it. The removal of one name keeps the root in
// the index; the removal of the other takes it out.
@(test)
two_names_of_one_object :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	object := disk_large_object(&disk)
	hash := hash_with_prefix(0x0123_4567_89AB_CDEF, 7)
	first := object_entry(object, {})
	first.hash = hash
	block: format.Store_Block
	block.tree = disk_leaf(&disk, {{"a", first}, {"b", first}})
	block.objects = 2
	block.current_blocks = 2 * 3 // A block that two objects share counts two times.
	block.node_blocks = 1
	disk_root(&disk, disk_put(&disk, &block), 5)
	state := test_state_make()
	defer test_state_free(state)
	result := mount(state, &disk, 16)
	testing.expect_value(t, result.wrong, 0)
	testing.expect_value(t, result.stores_with_wrong_count, 0)
	testing.expect_value(t, result.repeated_hashes, 0)
	testing.expect_value(t, state.hash_index.roots, 1)
	testing.expect_value(t, hash_index_entries(state, object.root.block), 2)
	testing.expect_value(t, state.references[object.root.block], 2)
	testing.expect_value(t, hash_index_check(state), 0)
	search := hash_search_begin(state, hash, object.size, 0)
	found_root, found := hash_index_next(state, &search)
	testing.expect(t, found && found_root == object.root, "the search by the hash finds the root")
	_, more := hash_index_next(state, &search)
	testing.expect(t, !more, "one root for the hash")
	other_size := hash_search_begin(state, hash, object.size + 1, 0)
	_, found = hash_index_next(state, &other_size)
	testing.expect(t, !found, "another size is another object")
	other_store := hash_search_begin(state, hash, object.size, 1)
	_, found = hash_index_next(state, &other_store)
	testing.expect(t, !found, "a root of another store is never a candidate")
	hash_index_release(state, object.root)
	testing.expect_value(t, hash_index_entries(state, object.root.block), 1)
	testing.expect_value(t, state.hash_index.roots, 1)
	hash_index_release(state, object.root)
	testing.expect_value(t, hash_index_entries(state, object.root.block), 0)
	testing.expect_value(t, state.hash_index.roots, 0)
	testing.expect_value(t, hash_index_check(state), 0)
}

// Two roots with one hash in one store: the open counts the second one as
// a repeated hash, and gives it a record with no slot: one key has one
// slot, so equal keys make no run of slots.
@(test)
two_roots_with_one_hash :: proc(t: ^testing.T) {
	disk := disk_make(16)
	defer delete(disk.bytes)
	first_object := disk_object(&disk)
	second_object := disk_object(&disk)
	hash := hash_with_prefix(42, 9)
	first := object_entry(first_object, {})
	second := object_entry(second_object, {})
	first.hash, second.hash = hash, hash
	block: format.Store_Block
	block.tree = disk_leaf(&disk, {{"a", first}, {"b", second}})
	block.objects = 2
	block.current_blocks = 2
	block.node_blocks = 1
	disk_root(&disk, disk_put(&disk, &block), 4)
	state := test_state_make()
	defer test_state_free(state)
	result := mount(state, &disk, 16)
	testing.expect_value(t, result.repeated_hashes, 1)
	testing.expect_value(t, state.hash_index.roots, 1)
	testing.expect_value(t, hash_index_entries(state, first_object.root.block), 1)
	testing.expect_value(t, hash_index_entries(state, second_object.root.block), 1)
	testing.expect(t, hash_index_slotted(state, first_object.root.block) != hash_index_slotted(state, second_object.root.block), "one of the two roots has the slot of the key")
	testing.expect_value(t, hash_index_check(state), 0)
}

// The first slot of a prefix, as hash_index.odin computes it.
test_home :: proc(state: ^State, prefix: u64) -> u64 {
	return ((prefix ~ state.hash_index.slot_key) * HASH_SLOT_MIX) >> (64 - state.hash_index.slot_bits)
}

// prefixes_with_home gives prefixes whose first slot is `home`, from the
// prefix `from` on.
prefixes_with_home :: proc(state: ^State, home: u64, from: u64, into: []u64) {
	found := 0
	for prefix := from; found < len(into); prefix += 1 {
		if test_home(state, prefix) == home {
			into[found] = prefix
			found += 1
		}
	}
}

// Roots whose keys start at one slot, and at the last slot of the table: a
// removal in the middle of a run moves the later roots back, and each root
// that stays is found from its key.
@(test)
removals_in_a_run_of_slots :: proc(t: ^testing.T) {
	state := test_state_make()
	defer test_state_free(state)
	ROOTS :: 12
	roots: [ROOTS]format.Pointer
	sizes: [ROOTS]u64
	hashes: [ROOTS][32]u8
	// Half of the keys start at the slot 5, the other half at the last slot,
	// so their run goes around the end of the table.
	low_prefixes: [ROOTS / 2]u64
	high_prefixes: [ROOTS / 2]u64
	prefixes_with_home(state, 5, 1, low_prefixes[:])
	prefixes_with_home(state, hash_slot_capacity(&state.hash_index) - 1, 1, high_prefixes[:])
	for index in 0 ..< ROOTS {
		roots[index] = {block = u64(100 + index), check = u64(1000 + index)}
		sizes[index] = u64(index + 1)
		state.owner[roots[index].block] = 1
		prefix := index % 2 == 0 ? low_prefixes[index / 2] : high_prefixes[index / 2]
		hashes[index] = hash_with_prefix(prefix, u8(index))
		testing.expect(t, !hash_index_name(state, hashes[index], roots[index], sizes[index]))
	}
	testing.expect_value(t, state.hash_index.roots, ROOTS)
	testing.expect_value(t, hash_index_check(state), 0)
	removed := [?]int{0, 3, 6, 11}
	for index in removed {
		hash_index_release(state, roots[index])
	}
	testing.expect_value(t, state.hash_index.roots, ROOTS - len(removed))
	testing.expect_value(t, hash_index_check(state), 0)
	for index in 0 ..< ROOTS {
		search := hash_search_begin(state, hashes[index], sizes[index], 0)
		found_root, found := hash_index_next(state, &search)
		is_removed := false
		for gone in removed {
			is_removed ||= gone == index
		}
		testing.expectf(t, found == !is_removed && (!found || found_root == roots[index]), "the root %d: found %v", index, found)
	}
}

// More roots with one first slot than HASH_PROBE_LIMIT: the roots past the
// bound keep a record and no slot, and no search reads past the bound.
@(test)
the_bound_of_a_run :: proc(t: ^testing.T) {
	state := test_state_make()
	defer test_state_free(state)
	ROOTS :: HASH_PROBE_LIMIT + 8
	prefixes: [ROOTS]u64
	prefixes_with_home(state, 77, 1, prefixes[:])
	for prefix, index in prefixes {
		block := u64(200 + index)
		state.owner[block] = 1
		hash_index_name(state, hash_with_prefix(prefix, 1), {block = block, check = 1}, BLOCK_SIZE)
	}
	testing.expect_value(t, state.hash_index.roots, HASH_PROBE_LIMIT)
	testing.expect_value(t, hash_index_check(state), 0)
	for index in 0 ..< ROOTS {
		testing.expectf(t, hash_index_slotted(state, u64(200 + index)) == (index < HASH_PROBE_LIMIT), "the root %d", index)
	}
	last := hash_search_begin(state, hash_with_prefix(prefixes[ROOTS - 1], 1), BLOCK_SIZE, 0)
	_, found := hash_index_next(state, &last)
	testing.expect(t, !found && last.read <= HASH_PROBE_LIMIT, "a root past the bound is not found, and the search stops at the bound")
	// A removal in the full run keeps each other slotted root found.
	hash_index_release(state, {block = 200, check = 1})
	testing.expect_value(t, hash_index_check(state), 0)
	for index in 1 ..< HASH_PROBE_LIMIT {
		search := hash_search_begin(state, hash_with_prefix(prefixes[index], 1), BLOCK_SIZE, 0)
		found_root, has := hash_index_next(state, &search)
		testing.expectf(t, has && found_root.block == u64(200 + index), "the root %d after the removal", index)
	}
}

// A linear congruential generator of Knuth (MMIX): a fixed run with no
// random source.
TEST_GENERATOR_SEED :: u64(20261115)
TEST_GENERATOR_MULTIPLIER :: u64(6364136223846793005)
TEST_GENERATOR_INCREMENT :: u64(1442695040888963407)
TEST_GENERATOR_SHIFT :: 33 // The high bits of the state: the low bits of such a generator repeat with a short period.

test_next_number :: proc(seed: ^u64) -> int {
	seed^ = seed^ * TEST_GENERATOR_MULTIPLIER + TEST_GENERATOR_INCREMENT
	return int(seed^ >> TEST_GENERATOR_SHIFT)
}

// Random inserts and removals of roots whose first slots are a few
// neighbour slots, one of them at the end of the table, so that runs merge,
// pass the bound and go around the end. After each step the index has no
// fault, with no empty slot inside a run, and each root keeps the slot that
// it had at its insert: a removal never makes another root unreachable.
@(test)
random_inserts_and_removals :: proc(t: ^testing.T) {
	state := test_state_make()
	defer test_state_free(state)
	HOMES :: 4
	ROOTS_OF_A_HOME :: 12
	ROOTS :: HOMES * ROOTS_OF_A_HOME
	STEPS :: 600 // Each step checks the whole table.
	FIRST_BLOCK :: 400
	last := hash_slot_capacity(&state.hash_index) - 1
	homes := [HOMES]u64{last - 1, last, 0, 3}
	prefixes: [ROOTS]u64
	for home, home_index in homes {
		prefixes_with_home(state, home, 1, prefixes[home_index * ROOTS_OF_A_HOME:][:ROOTS_OF_A_HOME])
	}
	live: [ROOTS]bool
	slotted_at_insert: [ROOTS]bool
	for index in 0 ..< ROOTS {
		state.owner[FIRST_BLOCK + index] = 1
	}
	seed := TEST_GENERATOR_SEED
	faults := 0
	lost := 0
	for _ in 0 ..< STEPS {
		index := test_next_number(&seed) % ROOTS
		root := format.Pointer{block = u64(FIRST_BLOCK + index), check = u64(index)}
		if live[index] {
			hash_index_release(state, root)
			live[index] = false
		} else {
			hash_index_name(state, hash_with_prefix(prefixes[index], u8(index)), root, BLOCK_SIZE)
			live[index] = true
			slotted_at_insert[index] = hash_index_slotted(state, root.block)
		}
		if hash_index_check(state) != 0 {
			faults += 1
		}
		for other in 0 ..< ROOTS {
			if live[other] && hash_index_slotted(state, u64(FIRST_BLOCK + other)) != slotted_at_insert[other] {
				lost += 1
			}
		}
	}
	testing.expect_value(t, faults, 0)
	testing.expect_value(t, lost, 0)
}

// A hidden root has no slot: no search finds it, and its release takes its
// record out. A rekey gives a root the key of its true hash.
@(test)
hidden_roots_and_rekeys :: proc(t: ^testing.T) {
	state := test_state_make()
	defer test_state_free(state)
	hidden_root := format.Pointer{block = 300, check = 3}
	state.owner[hidden_root.block] = 1
	hidden_hash := hash_with_prefix(0xABCD, 2)
	hash_index_name(state, hidden_hash, hidden_root, BLOCK_SIZE, true)
	testing.expect_value(t, hash_index_entries(state, hidden_root.block), 1)
	testing.expect_value(t, state.hash_index.roots, 0)
	search := hash_search_begin(state, hidden_hash, BLOCK_SIZE, 0)
	_, found := hash_index_next(state, &search)
	testing.expect(t, !found, "a hidden root is never a candidate")
	hash_index_release(state, hidden_root)
	testing.expect_value(t, hash_index_entries(state, hidden_root.block), 0)
	testing.expect_value(t, hash_index_check(state), 0)

	lying_root := format.Pointer{block = 301, check = 4}
	state.owner[lying_root.block] = 1
	lie := hash_with_prefix(0x1111, 5)
	truth := hash_with_prefix(0x2222, 6)
	hash_index_name(state, lie, lying_root, BLOCK_SIZE)
	hash_index_rekey(state, lying_root, truth)
	by_lie := hash_search_begin(state, lie, BLOCK_SIZE, 0)
	_, found = hash_index_next(state, &by_lie)
	testing.expect(t, !found, "after the rekey, the hash that the entry gave finds nothing")
	by_truth := hash_search_begin(state, truth, BLOCK_SIZE, 0)
	found_root, by_truth_found := hash_index_next(state, &by_truth)
	testing.expect(t, by_truth_found && found_root == lying_root, "the true hash finds the root")
	testing.expect_value(t, hash_index_check(state), 0)

	// A damaged root leaves the slots, and its key is free for a new root
	// with the same bytes.
	hash_index_hide(state, lying_root)
	testing.expect_value(t, hash_index_entries(state, lying_root.block), 1)
	testing.expect(t, !hash_index_slotted(state, lying_root.block), "a hidden root has no slot")
	repaired_root := format.Pointer{block = 302, check = 7}
	state.owner[repaired_root.block] = 1
	testing.expect(t, !hash_index_name(state, truth, repaired_root, BLOCK_SIZE), "the key is free")
	testing.expect(t, hash_index_slotted(state, repaired_root.block), "the new root takes the slot of the key")
	testing.expect_value(t, hash_index_check(state), 0)
}

// The index that commits change, step by step, is the index that a fresh
// open of the same entries makes. A seeded run of writes (a new object or
// the root of another name), removals and renames goes through
// hash_index_entry_change, as the storage service calls it after each
// commit; a rename changes no root, as in the service. Then a disk with
// the entries of the end is opened, and the two indexes are compared root
// by root.
@(test)
the_index_after_commits_is_the_index_of_a_new_open :: proc(t: ^testing.T) {
	OBJECTS :: 8
	NAMES :: 12
	STEPS :: 400
	DISK_BLOCKS :: 32
	Model :: struct {
		entries: [NAMES]format.Entry,
	}
	names := [NAMES]string{"n00", "n01", "n02", "n03", "n04", "n05", "n06", "n07", "n08", "n09", "n10", "n11"}
	objects_entry :: proc(object: Object_Blocks, number: int) -> format.Entry {
		entry := object_entry(object, {})
		entry.hash = hash_with_prefix(u64(number + 1) * 0x0101_0101, u8(number))
		return entry
	}
	// The disk of the start: the objects, then the names n00 to n03.
	disk_of :: proc(model: ^Model, names: []string) -> (disk: Test_Disk, objects: [OBJECTS]Object_Blocks) {
		disk = disk_make(DISK_BLOCKS)
		for &object in objects {
			object = disk_object(&disk)
		}
		named := make([dynamic]Named_Entry, context.temp_allocator)
		for &entry, index in model.entries {
			if entry.kind == u64(format.Entry_Kind.Object) {
				append(&named, Named_Entry{names[index], entry})
			}
		}
		block: format.Store_Block
		block.tree = disk_leaf(&disk, named[:])
		block.objects = u64(len(named))
		block.current_blocks = u64(len(named))
		block.node_blocks = 1
		disk_root(&disk, disk_put(&disk, &block), disk.next - 2)
		return disk, objects
	}
	// The objects have the same blocks on each disk: a first disk gives
	// them to the model.
	model: Model
	probe_disk, objects := disk_of(&model, names[:])
	delete(probe_disk.bytes)
	START_NAMES :: 4 // The names of the disk of the start: n00 to n03.
	for index in 0 ..< START_NAMES {
		model.entries[index] = objects_entry(objects[index], index)
	}
	start_disk, _ := disk_of(&model, names[:])
	defer delete(start_disk.bytes)
	live := test_state_make()
	defer test_state_free(live)
	start := mount(live, &start_disk, DISK_BLOCKS)
	testing.expect_value(t, start.wrong, 0)
	for &object in objects {
		live.owner[object.root.block] = 1 // A commit gives each block that it names to its store.
	}
	seed := TEST_GENERATOR_SEED
	next_number := test_next_number
	for _ in 0 ..< STEPS {
		name := next_number(&seed) % NAMES
		before := model.entries[name]
		switch next_number(&seed) % 3 {
		case 0: // A write: a new object, or the bytes of another name.
			number := next_number(&seed) % OBJECTS
			after := objects_entry(objects[number], number)
			hash_index_entry_change(live, before, after, false, false)
			model.entries[name] = after
		case 1: // A removal.
			if before.kind == u64(format.Entry_Kind.Object) {
				hash_index_entry_change(live, before, {}, true, false)
				model.entries[name] = {}
			}
		case 2: // A rename to a free name: no root changes.
			to := next_number(&seed) % NAMES
			if before.kind == u64(format.Entry_Kind.Object) && model.entries[to].kind != u64(format.Entry_Kind.Object) {
				model.entries[to] = before
				model.entries[name] = {}
			}
		}
	}
	if model.entries[0].kind != u64(format.Entry_Kind.Object) {
		after := objects_entry(objects[0], 0)
		hash_index_entry_change(live, model.entries[0], after, false, false)
		model.entries[0] = after
	}
	end_disk, _ := disk_of(&model, names[:])
	defer delete(end_disk.bytes)
	fresh := test_state_make()
	defer test_state_free(fresh)
	end := mount(fresh, &end_disk, DISK_BLOCKS)
	testing.expect_value(t, end.wrong, 0)
	testing.expect_value(t, hash_index_check(live), 0)
	testing.expect_value(t, hash_index_check(fresh), 0)
	testing.expect_value(t, live.hash_index.roots, fresh.hash_index.roots)
	different := 0
	for block in 0 ..< u64(DISK_BLOCKS) {
		live_record, fresh_record := hash_index_record(live, block), hash_index_record(fresh, block)
		same_record := (live_record == nil) == (fresh_record == nil) && (live_record == nil || live_record^ == fresh_record^)
		if !same_record || hash_index_slotted(live, block) != hash_index_slotted(fresh, block) {
			different += 1
		}
	}
	testing.expect_value(t, different, 0)
}

entry_of :: proc(generation: u64) -> format.Version_Entry {
	return {generation = generation, size = 1}
}

// Leaves with one entry each, as the retention rule leaves them: the
// compaction fills the first leaves, in the order of the entries.
@(test)
compaction_of_sparse_leaves :: proc(t: ^testing.T) {
	leaves := new([format.VERSION_INDEX_CAPACITY]format.Version_Leaf)
	defer free(leaves)
	for &leaf, index in leaves[:] {
		leaf.count = 1
		leaf.entries[0] = entry_of(u64(index + 1))
	}
	testing.expect(t, version_leaves_full(format.VERSION_INDEX_CAPACITY, 85) && !version_leaves_full(format.VERSION_INDEX_CAPACITY, 1))
	used := version_leaves_compact(leaves[:])
	testing.expect_value(t, used, 3) // 254 entries: 85, 85, 84.
	testing.expect_value(t, leaves[0].count, 85)
	testing.expect_value(t, leaves[1].count, 85)
	testing.expect_value(t, leaves[2].count, 84)
	testing.expect_value(t, leaves[3].count, 0)
	generation: u64 = 1
	for &leaf in leaves[:used] {
		for entry in leaf.entries[:leaf.count] {
			testing.expect_value(t, entry.generation, generation)
			generation += 1
		}
	}
	testing.expect_value(t, leaves[2].entries[84], format.Version_Entry{})
}

// A model of the version index of one object, with the rule of the engine
// (src/modules/system/storage/engine.odin, version_add): at the limit of the versions
// the oldest goes; when the last leaf of a full index is full, the leaves
// are compacted. A long run where the retention rule keeps one version in
// each leaf, then many writes, and 30000 restores in a row: no add fails,
// and the versions stay in their order.
Index_Model :: struct {
	leaves:     [format.VERSION_INDEX_CAPACITY]format.Version_Leaf,
	leaf_count: int,
	versions:   u64,
	compactions: int,
}

model_remove_first :: proc(model: ^Index_Model) {
	for &leaf in model.leaves[:model.leaf_count] {
		if leaf.count != 0 {
			copy(leaf.entries[:leaf.count - 1], leaf.entries[1:leaf.count])
			leaf.count -= 1
			leaf.entries[leaf.count] = {}
			model.versions -= 1
			return
		}
	}
}

model_add :: proc(model: ^Index_Model, entry: format.Version_Entry) -> bool {
	if model.versions >= format.VERSIONS_LIMIT {
		model_remove_first(model)
	}
	if model.leaf_count > 0 && version_leaves_full(model.leaf_count, model.leaves[model.leaf_count - 1].count) {
		model.leaf_count = version_leaves_compact(model.leaves[:model.leaf_count])
		model.compactions += 1
	}
	if model.leaf_count == 0 || model.leaves[model.leaf_count - 1].count >= format.VERSION_LEAF_CAPACITY {
		if model.leaf_count >= format.VERSION_INDEX_CAPACITY {
			return false
		}
		model.leaves[model.leaf_count] = {}
		model.leaf_count += 1
	}
	leaf := &model.leaves[model.leaf_count - 1]
	leaf.entries[leaf.count] = entry
	leaf.count += 1
	model.versions += 1
	return true
}

model_in_order :: proc(model: ^Index_Model) -> bool {
	last: u64
	for &leaf in model.leaves[:model.leaf_count] {
		for entry in leaf.entries[:leaf.count] {
			if entry.generation <= last {
				return false
			}
			last = entry.generation
		}
	}
	return true
}

@(test)
a_long_run_of_versions :: proc(t: ^testing.T) {
	model := new(Index_Model)
	defer free(model)
	generation: u64
	// The index fills; then a thinning keeps one version in each leaf.
	for _ in 0 ..< format.VERSIONS_LIMIT {
		generation += 1
		testing.expect(t, model_add(model, entry_of(generation)))
	}
	for &leaf in model.leaves[:model.leaf_count] {
		last := leaf.entries[leaf.count - 1]
		leaf.entries = {}
		leaf.entries[0] = last
		leaf.count = 1
	}
	model.versions = u64(model.leaf_count)
	testing.expect_value(t, model.leaf_count, format.VERSION_INDEX_CAPACITY)
	// Writes go on: with no compaction the index has no room after 84 more.
	for _ in 0 ..< 10_000 {
		generation += 1
		if !model_add(model, entry_of(generation)) {
			testing.expectf(t, false, "the add of the generation %d failed", generation)
			return
		}
	}
	testing.expect(t, model.compactions >= 1)
	testing.expect(t, model_in_order(model))
	// Restores in a row: each one adds a version; at the limit the oldest
	// goes.
	for _ in 0 ..< 30_000 {
		generation += 1
		if !model_add(model, entry_of(generation)) {
			testing.expectf(t, false, "the restore of the generation %d failed", generation)
			return
		}
	}
	testing.expect_value(t, model.versions, u64(format.VERSIONS_LIMIT))
	testing.expect(t, model_in_order(model))
}
