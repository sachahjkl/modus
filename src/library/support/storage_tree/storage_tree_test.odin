#+build !freestanding
package storage_tree

import "base:runtime"
import format "modus:contract/store"
import "core:fmt"
import "core:math/rand"
import "core:strconv"
import "core:slice"
import "core:testing"

// A disk in memory: a block is written one time, and never written again,
// as copy on write needs.
Test_Disk :: struct {
	using source: Source,
	writer:       Writer,
	blocks:       [dynamic]Block,
	reads:        int,
}

test_read :: proc "contextless" (source: ^Source, pointer: Pointer, into: ^Block) -> Read {
	disk := (^Test_Disk)(source)
	if pointer.block < 2 || int(pointer.block) >= len(disk.blocks) {
		return .Wrong
	}
	into^ = disk.blocks[pointer.block]
	disk.reads += 1
	return format.check(into[:]) == pointer.check ? .Good : .Wrong
}

test_write :: proc "contextless" (writer: ^Writer, bytes: ^Block) -> Pointer {
	disk := (^Test_Disk)(writer.data)
	context = runtime.default_context()
	number := len(disk.blocks)
	append(&disk.blocks, bytes^)
	return {block = u64(number), check = format.check(bytes[:])}
}

disk_make :: proc() -> ^Test_Disk {
	disk := new(Test_Disk)
	disk.source = {read = test_read}
	disk.writer = {write = test_write, data = disk}
	disk.blocks = make([dynamic]Block)
	append(&disk.blocks, Block{}, Block{}) // The two places of the root.
	return disk
}

disk_free :: proc(disk: ^Test_Disk) {
	delete(disk.blocks)
	free(disk)
}

// The name of the number n: its decimal digits, 8 of them, so that the
// order of the names is the order of the numbers.
name_of_number :: proc(number: u64) -> format.Entry_Name {
	return format.entry_name(fmt.tprintf("k%08d", number))
}

number_of_name :: proc(key: []u8) -> u64 {
	name := (^format.Entry_Name)(raw_data(key))
	number, _ := strconv.parse_u64(format.name_of(name)[1:])
	return number
}

entry_of_number :: proc(number: u64) -> (value: format.Entry) {
	value.kind = u64(format.Entry_Kind.Object)
	value.size = number * 3
	value.generation = number
	return value
}

// The records of a whole tree, in the order of the walk.
Walked :: struct {
	keys:       [dynamic]u64,
	bad_values: int,
}

walk_record_entry :: proc "contextless" (walk: ^Walk, key: []u8, value: []u8) {
	context = runtime.default_context()
	walked := (^Walked)(walk.data)
	number := number_of_name(key)
	entry := (^format.Entry)(raw_data(value))
	if entry.size != number * 3 {
		walked.bad_values += 1
	}
	append(&walked.keys, number)
}

walk_all :: proc(disk: ^Test_Disk, root: Pointer) -> (keys: [dynamic]u64, nodes: u64, failure: Failure, bad_values: int) {
	walked := Walked{keys = make([dynamic]u64)}
	walk := new(Walk)
	defer free(walk)
	walk.source = &disk.source
	walk.shape = TREE_SHAPE
	walk.visit_record = walk_record_entry
	walk.data = &walked
	failure = walk_tree(walk, root)
	return walked.keys, walk.nodes, failure, walked.bad_values
}

@(test)
the_sizes_of_the_format :: proc(t: ^testing.T) {
	testing.expect_value(t, format.LEAF_CAPACITY, 24)
	testing.expect_value(t, format.BRANCH_CAPACITY, 50)
	testing.expect_value(t, record_size(TREE_SHAPE, 0), 168)
	testing.expect_value(t, record_size(TREE_SHAPE, 1), 80)
	testing.expect(t, HEADER_SIZE + TREE_SHAPE.leaf_capacity * record_size(TREE_SHAPE, 0) <= BLOCK_SIZE)
	testing.expect(t, HEADER_SIZE + TREE_SHAPE.branch_capacity * record_size(TREE_SHAPE, 1) <= BLOCK_SIZE)
	testing.expect_value(t, size_of(format.Store_Block), BLOCK_SIZE)
	testing.expect_value(t, size_of(format.Root), BLOCK_SIZE)
	// The removal queue is in the order of the removes.
	first := format.removal_name(255)
	second := format.removal_name(256)
	testing.expect(t, compare(first[:], second[:]) < 0)
}

// Inserts in a random order split leaves and branches; the walk gives each
// key once, in order, and each value; a search finds each one.
@(test)
insert_split_and_order :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)
	pool_reset(pool)
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE}
	COUNT :: 20000
	order := make([]u64, COUNT)
	defer delete(order)
	for &identifier, index in order {
		identifier = u64(index) + 16
	}
	generator := rand.create(20261112)
	rand.shuffle(order, rand.default_random_generator(&generator))
	// Commits of 100 inserts: the pool holds the dirty nodes of one commit.
	for first := 0; first < COUNT; first += 100 {
		for identifier in order[first:][:100] {
			key := name_of_number(identifier)
			value := entry_of_number(identifier)
			existed := put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false)
			testing.expect(t, !existed)
		}
		testing.expect_value(t, pool.failure, Failure.None)
		finish(&work, &disk.writer)
		pool_reset(pool)
	}
	keys, nodes, failure, bad := walk_all(disk, work.root)
	defer delete(keys)
	testing.expect_value(t, failure, Failure.None)
	testing.expect_value(t, len(keys), COUNT)
	testing.expect_value(t, bad, 0)
	testing.expect(t, slice.is_sorted(keys[:]))
	// Each node at least a third full: at most COUNT / 8 leaves, and the
	// branches above them.
	testing.expect(t, nodes <= COUNT / 8 + 100)
	for identifier in ([]u64{16, 17, 9000, COUNT + 15}) {
		key := name_of_number(identifier)
		value: format.Entry
		testing.expect(t, get(&work, key[:], ([^]u8)(&value)[:size_of(value)]))
		testing.expect_value(t, value.size, identifier * 3)
	}
	missing := name_of_number(COUNT + 16)
	value: format.Entry
	testing.expect(t, !get(&work, missing[:], ([^]u8)(&value)[:size_of(value)]))
	// A key that exists is not put again without replace.
	key := name_of_number(100)
	other := entry_of_number(7)
	testing.expect(t, put(&work, key[:], ([^]u8)(&other)[:size_of(other)], false))
	testing.expect(t, !is_reference(work.root))
}

// Removes in a random order merge and rebalance nodes; the keys left are
// in order, and a tree of no key has no root.
@(test)
remove_merge_and_empty :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)
	pool_reset(pool)
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE}
	COUNT :: 6000
	for identifier in 16 ..< u64(16 + COUNT) {
		key := name_of_number(identifier)
		value := entry_of_number(identifier)
		put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false)
		if identifier % 100 == 0 {
			finish(&work, &disk.writer)
			pool_reset(pool)
		}
	}
	finish(&work, &disk.writer)
	pool_reset(pool)
	_, full_nodes, _, _ := walk_all(disk, work.root)
	order := make([]u64, COUNT)
	defer delete(order)
	for &identifier, index in order {
		identifier = u64(index) + 16
	}
	generator := rand.create(7)
	rand.shuffle(order, rand.default_random_generator(&generator))
	// Remove nine keys of ten.
	removed := COUNT - COUNT / 10
	for first := 0; first < removed; first += 50 {
		for identifier in order[first:][:min(50, removed - first)] {
			key := name_of_number(identifier)
			testing.expect(t, remove(&work, key[:]))
		}
		testing.expect_value(t, pool.failure, Failure.None)
		finish(&work, &disk.writer)
		pool_reset(pool)
	}
	keys, nodes, failure, bad := walk_all(disk, work.root)
	testing.expect_value(t, failure, Failure.None)
	testing.expect_value(t, len(keys), COUNT / 10)
	testing.expect_value(t, bad, 0)
	testing.expect(t, slice.is_sorted(keys[:]))
	// The merges keep the nodes at least a third full.
	testing.expect(t, nodes < full_nodes / 3)
	expected := slice.clone(order[removed:])
	defer delete(expected)
	slice.sort(expected)
	testing.expect(t, slice.equal(keys[:], expected))
	delete(keys)
	// A key that is not there.
	key := name_of_number(order[0])
	testing.expect(t, !remove(&work, key[:]))
	for identifier in order[removed:] {
		key = name_of_number(identifier)
		testing.expect(t, remove(&work, key[:]))
	}
	finish(&work, &disk.writer)
	testing.expect(t, is_empty(work.root))
}

// Copy on write: a commit never writes a node of the tree before it, so the
// root before it still reads the keys before it; the nodes that the commit
// released are the ones that the new tree no longer names.
@(test)
copy_on_write_keeps_the_tree_before :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)
	pool_reset(pool)
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE}
	for identifier in 16 ..< u64(2016) {
		key := name_of_number(identifier)
		value := entry_of_number(identifier)
		put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false)
		if identifier % 64 == 0 {
			finish(&work, &disk.writer)
			pool_reset(pool)
		}
	}
	before := finish(&work, &disk.writer)
	pool_reset(pool)
	blocks_before := len(disk.blocks)
	key := name_of_number(1000)
	remove(&work, key[:])
	key = name_of_number(5000)
	value := entry_of_number(5000)
	put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false)
	after := finish(&work, &disk.writer)
	released := pool.released[:pool.released_count]
	// Only new blocks were written.
	testing.expect(t, pool.written == len(disk.blocks) - blocks_before)
	old_keys, _, old_failure, _ := walk_all(disk, before)
	defer delete(old_keys)
	testing.expect_value(t, old_failure, Failure.None)
	testing.expect_value(t, len(old_keys), 2000)
	new_keys, _, new_failure, _ := walk_all(disk, after)
	defer delete(new_keys)
	testing.expect_value(t, new_failure, Failure.None)
	testing.expect_value(t, len(new_keys), 2000)
	testing.expect(t, !slice.contains(new_keys[:], 1000) && slice.contains(new_keys[:], 5000))
	// Each released block was a node of the tree before, and is not a node
	// of the new tree.
	Named :: struct {
		blocks: [dynamic]u64,
	}
	named_new := Named{blocks = make([dynamic]u64)}
	defer delete(named_new.blocks)
	walk := new(Walk)
	defer free(walk)
	walk.source = &disk.source
	walk.shape = TREE_SHAPE
	walk.data = &named_new
	walk.visit_node = proc "contextless" (walk: ^Walk, pointer: Pointer) -> bool {
		context = runtime.default_context()
		append(&(^Named)(walk.data).blocks, pointer.block)
		return true
	}
	walk_tree(walk, after)
	testing.expect(t, len(released) > 0)
	for pointer in released {
		testing.expect(t, int(pointer.block) < blocks_before)
		testing.expect(t, !slice.contains(named_new.blocks[:], pointer.block))
	}
}

// The entries of a tree are in the order of the bytes of their names; a
// listing gives them in pages, each page after the last name of the page
// before, as the export list does.
@(test)
names_in_order_and_in_pages :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)
	pool_reset(pool)
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE}
	names := []string{"b", "ab", "a", "abc", "z", "B", "é"}
	for name, index in names {
		key := format.entry_name(name)
		value := format.Entry{kind = u64(format.Entry_Kind.Object), size = u64(index)}
		put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false)
	}
	finish(&work, &disk.writer)
	pool_reset(pool)
	listed := make([dynamic]string, context.temp_allocator)
	cursor: format.Entry_Name
	after := false
	for {
		key_out: format.Entry_Name
		value_out: format.Entry
		if !first_from(&work, cursor[:], after, key_out[:], ([^]u8)(&value_out)[:size_of(value_out)]) {
			break
		}
		append(&listed, fmt.tprint(format.name_of(&key_out)))
		cursor = key_out
		after = true
	}
	expected := []string{"B", "a", "ab", "abc", "b", "z", "é"}
	testing.expect_value(t, len(listed), len(expected))
	for name, index in expected {
		testing.expect_value(t, listed[index], name)
	}
	// Pages over many leaves: each name once, in order.
	for number in 0 ..< u64(3000) {
		key := name_of_number(number)
		value := entry_of_number(number)
		put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false)
		if number % 200 == 0 {
			finish(&work, &disk.writer)
			pool_reset(pool)
		}
	}
	finish(&work, &disk.writer)
	pool_reset(pool)
	start := name_of_number(0)
	cursor = start
	after = false
	count: u64
	for {
		key_out: format.Entry_Name
		value_out: format.Entry
		if !first_from(&work, cursor[:], after, key_out[:], ([^]u8)(&value_out)[:size_of(value_out)]) {
			break
		}
		if key_out[0] != 'k' {
			break
		}
		testing.expect_value(t, number_of_name(key_out[:]), count)
		count += 1
		cursor = key_out
		after = true
	}
	testing.expect_value(t, count, 3000)
}

@(test)
names_that_are_refused :: proc(t: ^testing.T) {
	Case :: struct {
		name:    string,
		refusal: format.Name_Refusal,
		offset:  int,
	}
	long: [format.ENTRY_NAME_CAPACITY + 1]u8
	for &byte in long {
		byte = 'x'
	}
	cases := []Case {
		{"", .Empty, 0},
		{".", .Bad_Byte, 0},
		{"..", .Bad_Byte, 0},
		{"/etc", .Bad_Byte, 0},
		{"a/../b", .Bad_Byte, 1},
		{"a\x00b", .Bad_Byte, 1},
		{"résumé", .None, 0}, // UTF-8.
		{"caf\xc3", .Bad_Byte, 3}, // A character cut short.
		{"ab\xc0\xaf", .Bad_Byte, 2}, // An overlong form.
		{"a\x0ab", .Bad_Byte, 1}, // A control character.
		{"a\xc2\x9bb", .Bad_Byte, 1}, // A control character of C1.
		{string(long[:]), .Too_Long, 0},
		{string(long[:format.ENTRY_NAME_CAPACITY]), .None, 0},
		{"...", .None, 0},
		{".hidden", .None, 0},
	}
	for item in cases {
		refusal, offset, _ := format.name_refusal(item.name)
		testing.expectf(t, refusal == item.refusal && offset == item.offset, "%q: %v at %d", item.name, refusal, offset)
	}
}

// A block of another kind, or a node with keys out of order, is damage: the walk
// and the search stop on it.
@(test)
a_damaged_node_is_found :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)
	pool_reset(pool)
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE}
	for identifier in 16 ..< u64(30) {
		key := name_of_number(identifier)
		value := entry_of_number(identifier)
		put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false)
	}
	root := finish(&work, &disk.writer)
	// The same bytes with another magic: a block of another kind.
	wrong := disk.blocks[root.block]
	header(&wrong).magic = 0
	pointer := test_write(&disk.writer, &wrong)
	_, _, failure, _ := walk_all(disk, pointer)
	testing.expect_value(t, failure, Failure.Damaged)
	// Two keys out of order.
	swapped := disk.blocks[root.block]
	first := slice.clone(key_at(&swapped, TREE_SHAPE, 0))
	defer delete(first)
	copy(key_at(&swapped, TREE_SHAPE, 0), key_at(&swapped, TREE_SHAPE, 1))
	copy(key_at(&swapped, TREE_SHAPE, 1), first)
	pointer = test_write(&disk.writer, &swapped)
	pool_reset(pool)
	work.root = pointer
	key := name_of_number(20)
	value: format.Entry
	testing.expect(t, !get(&work, key[:], ([^]u8)(&value)[:size_of(value)]))
	testing.expect_value(t, pool.failure, Failure.Damaged)
	// A wrong check.
	pool_reset(pool)
	work.root = {block = root.block, check = root.check ~ 1}
	testing.expect(t, !get(&work, key[:], ([^]u8)(&value)[:size_of(value)]))
	testing.expect_value(t, pool.failure, Failure.Wrong)
}

// A branch whose record 0 has a stale name: the names first go in from
// 1000 up, so the root branch takes the name of its first leaf then; the
// names below 1000 that come after go into the child 0, which splits, and
// the new separator at the record 1 is smaller than the name of the record
// 0. That branch is valid: the search never reads the name of the record 0.
@(test)
a_stale_name_at_the_record_0_of_a_branch :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)
	pool_reset(pool)
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE}
	for number in u64(1000) ..< 1100 {
		key := name_of_number(number)
		value := entry_of_number(number)
		put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false)
	}
	finish(&work, &disk.writer)
	pool_reset(pool)
	for number in u64(0) ..< 100 {
		key := name_of_number(number)
		value := entry_of_number(number)
		put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false)
	}
	testing.expect_value(t, pool.failure, Failure.None)
	finish(&work, &disk.writer)
	pool_reset(pool)
	root_node := disk.blocks[work.root.block]
	testing.expect(t, header(&root_node).level > 0)
	testing.expect(t, compare(key_at(&root_node, TREE_SHAPE, 0), key_at(&root_node, TREE_SHAPE, 1)) > 0)
	testing.expect(t, node_valid(&root_node, TREE_SHAPE))
	keys, _, failure, bad := walk_all(disk, work.root)
	defer delete(keys)
	testing.expect_value(t, failure, Failure.None)
	testing.expect_value(t, len(keys), 200)
	testing.expect_value(t, bad, 0)
	for number in ([]u64{0, 99, 1000, 1099}) {
		key := name_of_number(number)
		value: format.Entry
		testing.expect(t, get(&work, key[:], ([^]u8)(&value)[:size_of(value)]))
	}
}

// A reference to a slot that names no slot of the pool: one past the pool,
// or one above 2^63 that a conversion to int makes negative, is damage.
@(test)
a_reference_out_of_the_pool_is_damaged :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)
	for check in ([?]u64{POOL_CAPACITY + 1, 1 << 63, max(u64)}) {
		pool_reset(pool)
		work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE}
		testing.expect_value(t, load(&work, Pointer{block = 0, check = check}, -1), -1)
		testing.expect_value(t, pool.failure, Failure.Damaged)
	}
}

// The checks of a Pointer with no block that a damaged disk can hold: no
// node, the first slot (the root that a change makes dirty), the edges of
// the pool, a value that a conversion to int makes negative, the value
// that the fuzz target found, and the largest.
DAMAGED_REFERENCE_CHECKS :: [?]u64{0, 1, POOL_CAPACITY, POOL_CAPACITY + 1, 1 << 63, 7534161270214233299, max(u64)}

// two_level_tree writes a tree whose root is a branch over leaves.
two_level_tree :: proc(t: ^testing.T, disk: ^Test_Disk, pool: ^Pool) -> Pointer {
	pool_reset(pool)
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE}
	for identifier in 16 ..< u64(16 + 2 * TREE_SHAPE.leaf_capacity) {
		key := name_of_number(identifier)
		value := entry_of_number(identifier)
		put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false)
	}
	root := finish(&work, &disk.writer)
	testing.expect_value(t, pool.failure, Failure.None)
	testing.expect(t, header(&disk.blocks[root.block]).level > 0)
	pool_reset(pool)
	return root
}

// expect_damaged_tree checks that the tree of a root with a damaged node
// is refused by the walk, by a change in its first key with its commit, and
// by a read, and that nothing changes: no block is written or released,
// and the root stays the one of the disk. The damaged node is the block
// `damaged_block`.
expect_damaged_tree :: proc(t: ^testing.T, disk: ^Test_Disk, pool: ^Pool, damaged_root: Pointer, damaged_block: u64, location := #caller_location) {
	keys, _, walk_failure, _ := walk_all(disk, damaged_root)
	delete(keys)
	testing.expect_value(t, walk_failure, Failure.Damaged, loc = location)
	// A change in the child 0, then the commit: the path of the fault.
	pool_reset(pool)
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE, root = damaged_root}
	blocks_before := len(disk.blocks)
	key := name_of_number(16)
	value := entry_of_number(16)
	testing.expect(t, !put(&work, key[:], ([^]u8)(&value)[:size_of(value)], true), "put accepts the change", loc = location)
	testing.expect_value(t, pool.failure, Failure.Damaged, loc = location)
	testing.expect_value(t, pool.failed_block, damaged_block, loc = location)
	testing.expect_value(t, finish(&work, &disk.writer), damaged_root, loc = location)
	testing.expect_value(t, work.root, damaged_root, loc = location)
	testing.expect(t, !work.root_is_reference, "the root is a reference", loc = location)
	testing.expect_value(t, len(disk.blocks), blocks_before, loc = location)
	testing.expect_value(t, pool.written, 0, loc = location)
	testing.expect_value(t, pool.released_count, 0, loc = location)
	// The reads refuse it too.
	pool_reset(pool)
	testing.expect(t, !get(&work, key[:], ([^]u8)(&value)[:size_of(value)]), "get reads the tree", loc = location)
	testing.expect_value(t, pool.failure, Failure.Damaged, loc = location)
}

// A branch of the disk whose first or last child has no block: its check
// has the form of a reference to a slot. The commit of a change in another
// child took that check for the number of a slot and faulted; the read
// refuses the branch, and nothing changes: no block is written or
// released, and the root stays the one of the disk.
@(test)
a_child_with_no_block_is_damaged :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)
	root := two_level_tree(t, disk, pool)
	last := int(header(&disk.blocks[root.block]).count) - 1
	checks := DAMAGED_REFERENCE_CHECKS
	positions := [2]int{0, last}
	for position in positions {
		for check in checks {
			damaged := disk.blocks[root.block]
			child_at(&damaged, TREE_SHAPE, position)^ = Pointer{block = 0, check = check}
			testing.expectf(t, !node_valid(&damaged, TREE_SHAPE), "the child %d, the check %d: the branch is valid", position, check)
			damaged_root := test_write(&disk.writer, &damaged)
			expect_damaged_tree(t, disk, pool, damaged_root, damaged_root.block)
		}
	}
	// The branch of the disk with a block for each child is still read.
	pool_reset(pool)
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE, root = root}
	key := name_of_number(16)
	value: format.Entry
	testing.expect(t, get(&work, key[:], ([^]u8)(&value)[:size_of(value)]))
	testing.expect_value(t, value.size, 16 * 3)
}

// three_level_tree writes a tree whose root is a branch of the level 2:
// enough keys, in order, to split the root branch of the level 1. Commits
// of 100 keys keep each commit inside the pool.
three_level_tree :: proc(t: ^testing.T, disk: ^Test_Disk, pool: ^Pool) -> Pointer {
	pool_reset(pool)
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE}
	root: Pointer
	for identifier in 16 ..< u64(16 + 2 * TREE_SHAPE.leaf_capacity * TREE_SHAPE.branch_capacity) {
		key := name_of_number(identifier)
		value := entry_of_number(identifier)
		put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false)
		if identifier % 100 == 0 {
			root = finish(&work, &disk.writer)
			pool_reset(pool)
		}
	}
	root = finish(&work, &disk.writer)
	testing.expect_value(t, pool.failure, Failure.None)
	testing.expect_value(t, header(&disk.blocks[root.block]).level, 2)
	pool_reset(pool)
	return root
}

// A child with no block in a branch of each level: in the root of the
// level 2, and in its first child, a branch of the level 1 that the change
// of the first key reads.
@(test)
a_child_with_no_block_at_each_level_is_damaged :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)
	root := three_level_tree(t, disk, pool)
	checks := DAMAGED_REFERENCE_CHECKS
	for check in checks {
		// In the root, at the level 2: its last child.
		damaged_root_node := disk.blocks[root.block]
		last := int(header(&damaged_root_node).count) - 1
		child_at(&damaged_root_node, TREE_SHAPE, last)^ = Pointer{block = 0, check = check}
		testing.expectf(t, !node_valid(&damaged_root_node, TREE_SHAPE), "the check %d: the root is valid", check)
		damaged_root := test_write(&disk.writer, &damaged_root_node)
		expect_damaged_tree(t, disk, pool, damaged_root, damaged_root.block)
		// In the branch of the level 1 under the child 0 of the root: its
		// last child. The root names the damaged branch with its check.
		first_branch := child_at(&disk.blocks[root.block], TREE_SHAPE, 0)^
		damaged_branch := disk.blocks[first_branch.block]
		testing.expect_value(t, header(&damaged_branch).level, 1)
		branch_last := int(header(&damaged_branch).count) - 1
		child_at(&damaged_branch, TREE_SHAPE, branch_last)^ = Pointer{block = 0, check = check}
		testing.expectf(t, !node_valid(&damaged_branch, TREE_SHAPE), "the check %d: the branch is valid", check)
		damaged_branch_pointer := test_write(&disk.writer, &damaged_branch)
		root_node := disk.blocks[root.block]
		child_at(&root_node, TREE_SHAPE, 0)^ = damaged_branch_pointer
		testing.expect(t, node_valid(&root_node, TREE_SHAPE))
		root_over_damage := test_write(&disk.writer, &root_node)
		expect_damaged_tree(t, disk, pool, root_over_damage, damaged_branch_pointer.block)
	}
	// The tree with a block for each child is still read.
	pool_reset(pool)
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE, root = root}
	key := name_of_number(16)
	value: format.Entry
	testing.expect(t, get(&work, key[:], ([^]u8)(&value)[:size_of(value)]))
	testing.expect_value(t, value.size, 16 * 3)
}

// A root that the caller read from a damaged disk, with no block and a
// check: it names no node of the disk, even when its check is the number
// of a dirty slot of another tree of the same commit. Each operation and
// the commit refuse it, and the other tree keeps its node.
@(test)
a_root_of_the_disk_with_no_block_is_damaged :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)
	// The check 0 is the empty tree, the last case.
	checks := DAMAGED_REFERENCE_CHECKS
	for check in checks[1:] {
		// Another tree of the commit makes the slot 0 dirty.
		pool_reset(pool)
		other := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE}
		other_key := name_of_number(7)
		other_value := entry_of_number(7)
		put(&other, other_key[:], ([^]u8)(&other_value)[:size_of(other_value)], false)
		testing.expect(t, other.root_is_reference)
		other_node := pool.slots[0].bytes
		damaged_root := Pointer{block = 0, check = check}
		work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE, root = damaged_root}
		key := name_of_number(8)
		value := entry_of_number(8)
		testing.expect(t, !put(&work, key[:], ([^]u8)(&value)[:size_of(value)], false))
		testing.expectf(t, pool.failure == .Damaged, "the check %d: the failure %v", check, pool.failure)
		testing.expect_value(t, work.root, damaged_root)
		testing.expect(t, !work.root_is_reference)
		testing.expect(t, pool.slots[0].state == .Dirty)
		testing.expect(t, pool.slots[0].bytes == other_node)
		testing.expect(t, !get(&work, key[:], ([^]u8)(&value)[:size_of(value)]))
		testing.expect(t, !remove(&work, key[:]))
		blocks_before := len(disk.blocks)
		testing.expect_value(t, finish(&work, &disk.writer), damaged_root)
		testing.expect_value(t, len(disk.blocks), blocks_before)
		testing.expect_value(t, pool.written, 0)
		// The commit of a tree that no change touched refuses that root too.
		pool_reset(pool)
		untouched := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE, root = damaged_root}
		testing.expect_value(t, finish(&untouched, &disk.writer), damaged_root)
		testing.expect_value(t, pool.failure, Failure.Damaged)
		testing.expect_value(t, len(disk.blocks), blocks_before)
	}
	// An empty root is no damage.
	pool_reset(pool)
	empty := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE}
	testing.expect_value(t, finish(&empty, &disk.writer), Pointer{})
	testing.expect_value(t, pool.failure, Failure.None)
}

// A reference that a dirty node holds is checked where it becomes an
// index: one out of the pool, or one that names a slot with no dirty
// node, refuses the commit, and no block is written.
@(test)
a_reference_to_no_dirty_slot_refuses_the_commit :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)
	root := two_level_tree(t, disk, pool)
	// A reference with the check 0 is no reference: the first case is 1.
	checks := DAMAGED_REFERENCE_CHECKS
	for check in checks[1:] {
		pool_reset(pool)
		work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE, root = root}
		// A change in the last child: the first child, which the commit
		// writes first, keeps the Pointer of the disk until the damage.
		key := name_of_number(16 + 2 * u64(TREE_SHAPE.leaf_capacity) - 1)
		value := entry_of_number(16 + 2 * u64(TREE_SHAPE.leaf_capacity) - 1)
		testing.expect(t, put(&work, key[:], ([^]u8)(&value)[:size_of(value)], true))
		testing.expect_value(t, pool.failure, Failure.None)
		testing.expect(t, work.root_is_reference)
		root_index := int(work.root.check - 1)
		branch := &pool.slots[root_index].bytes
		testing.expect(t, int(header(branch).count) >= 2)
		child_at(branch, TREE_SHAPE, 0)^ = Pointer{block = 0, check = check}
		// The check 1 names the slot of the root itself: a cycle that the
		// bound of the depth ends before any write.
		blocks_before := len(disk.blocks)
		finish(&work, &disk.writer)
		testing.expectf(t, pool.failure == .Damaged, "the check %d: the failure %v", check, pool.failure)
		testing.expect(t, work.root_is_reference)
		testing.expect_value(t, len(disk.blocks), blocks_before)
	}
	// The damage in the last child, and a change in the first: the commit
	// writes the first child before it meets the damage. The commit is
	// still refused, and its root names no block; the blocks that it wrote
	// are the ones that the caller drops with the commit.
	for check in checks[1:] {
		pool_reset(pool)
		work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE, root = root}
		key := name_of_number(16)
		value := entry_of_number(16)
		testing.expect(t, put(&work, key[:], ([^]u8)(&value)[:size_of(value)], true))
		testing.expect_value(t, pool.failure, Failure.None)
		reference_before := work.root
		branch := &pool.slots[int(work.root.check - 1)].bytes
		last := int(header(branch).count) - 1
		testing.expect(t, last >= 1)
		child_at(branch, TREE_SHAPE, last)^ = Pointer{block = 0, check = check}
		blocks_before := len(disk.blocks)
		testing.expect_value(t, finish(&work, &disk.writer), reference_before)
		testing.expectf(t, pool.failure == .Damaged, "the check %d: the failure %v", check, pool.failure)
		testing.expect(t, work.root_is_reference)
		testing.expect_value(t, work.root, reference_before)
		testing.expect_value(t, pool.written, 1)
		testing.expect_value(t, len(disk.blocks), blocks_before + pool.written)
	}
}

// A root branch of one child gives its place to that child. When the child
// is a block of the disk, the root becomes that Pointer of the disk, not a
// reference: the commit writes nothing, and gives that block as the root.
// A merge always makes the child dirty, so this calls rebalance on a root
// of the disk with one child, as a damaged but valid disk can hold.
@(test)
a_root_collapsed_onto_a_child_of_the_disk :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)
	root := two_level_tree(t, disk, pool)
	child := child_at(&disk.blocks[root.block], TREE_SHAPE, 0)^
	single := disk.blocks[root.block]
	for index in 1 ..< int(header(&single).count) {
		for &byte in record_at(&single, TREE_SHAPE, index) {
			byte = 0
		}
	}
	header(&single).count = 1
	testing.expect(t, node_valid(&single, TREE_SHAPE))
	single_root := test_write(&disk.writer, &single)
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE, root = single_root}
	index := load(&work, single_root, -1)
	testing.expect(t, index >= 0)
	path := Path{depth = 1}
	path.slots[0] = index
	path_dirty(&work, &path)
	testing.expect(t, work.root_is_reference)
	rebalance(&work, &path, 0)
	testing.expect_value(t, pool.failure, Failure.None)
	testing.expect_value(t, work.root, child)
	testing.expect(t, !work.root_is_reference)
	testing.expect(t, pool.slots[index].state == .Free)
	testing.expect_value(t, pool.released_count, 1)
	testing.expect_value(t, pool.released[0], single_root)
	blocks_before := len(disk.blocks)
	testing.expect_value(t, finish(&work, &disk.writer), child)
	testing.expect_value(t, pool.failure, Failure.None)
	testing.expect_value(t, len(disk.blocks), blocks_before)
	keys, _, failure, _ := walk_all(disk, work.root)
	defer delete(keys)
	testing.expect_value(t, failure, Failure.None)
	testing.expect(t, len(keys) > 0 && keys[0] == 16)
}

// Removes that leave one leaf: the merges collapse the root branch onto
// its child, a dirty slot, and the commit writes that leaf as the root.
@(test)
a_remove_collapses_the_root :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)
	root := two_level_tree(t, disk, pool)
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE, root = root}
	KEPT :: 4
	for identifier in 16 ..< u64(16 + 2 * TREE_SHAPE.leaf_capacity - KEPT) {
		key := name_of_number(identifier)
		testing.expect(t, remove(&work, key[:]))
	}
	testing.expect_value(t, pool.failure, Failure.None)
	testing.expect(t, work.root_is_reference)
	testing.expect_value(t, header(&pool.slots[int(work.root.check - 1)].bytes).level, 0)
	new_root := finish(&work, &disk.writer)
	testing.expect_value(t, pool.failure, Failure.None)
	testing.expect(t, !work.root_is_reference)
	testing.expect(t, new_root.block != 0)
	testing.expect_value(t, header(&disk.blocks[new_root.block]).level, 0)
	keys, _, failure, _ := walk_all(disk, new_root)
	defer delete(keys)
	testing.expect_value(t, failure, Failure.None)
	testing.expect_value(t, len(keys), KEPT)
	testing.expect_value(t, keys[0], 16 + 2 * u64(TREE_SHAPE.leaf_capacity) - KEPT)
}

// The list of the released blocks of a commit has a bound: one release
// past it is the failure Full, and the slot stays as it was.
@(test)
a_release_past_the_list_is_full :: proc(t: ^testing.T) {
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)
	root := two_level_tree(t, disk, pool)
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE, root = root}
	index := load(&work, root, -1)
	testing.expect(t, index >= 0)
	pool.released_count = len(pool.released)
	dirty(&work, index)
	testing.expect_value(t, pool.failure, Failure.Full)
	testing.expect_value(t, pool.released_count, len(pool.released))
	testing.expect(t, pool.slots[index].state == .Clean)
	testing.expect_value(t, pool.slots[index].original, root)
	// One place left: the release is recorded.
	pool_reset(pool)
	index = load(&work, root, -1)
	pool.released_count = len(pool.released) - 1
	dirty(&work, index)
	testing.expect_value(t, pool.failure, Failure.None)
	testing.expect_value(t, pool.released[len(pool.released) - 1], root)
	testing.expect(t, pool.slots[index].state == .Dirty)
}
