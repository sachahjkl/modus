#+build !freestanding
package storage_mount

import format "modus:contract/store"
import block_tree "modus:support/storage_object"
import "core:testing"

// The erase of versions through a loss of power
// (src/md/features/version_erase.md). The object "a" has two versions; the
// newer one names the block of the object "b", as the hash index makes it.
// The storage service writes, in this order: the blocks of the commit that
// ends the versions (a Flush), its root (a Flush), the same root with the
// next generation in the other place (a Flush), then zeros over each block
// that the commit freed (a Flush). This test builds each image that a loss
// of power can leave in that order, and opens each one with the code of
// the open.

@(private = "file")
ERASE_DISK_BLOCKS :: 16
@(private = "file")
ERASE_BEFORE_GENERATION :: 10 // The generation of the root before the erase.

// One write of the erase: a block number and its new bytes.
@(private = "file")
Erase_Write :: struct {
	number: u64,
	bytes:  []u8,
}

// erase_root gives the bytes of a root of one store "s".
@(private = "file")
erase_root :: proc(disk_blocks: u64, generation: u64, store_block: format.Pointer, used_blocks: u64) -> []u8 {
	root := new(format.Root, context.temp_allocator)
	root^ = {magic = format.ROOT_MAGIC, generation = generation, disk_blocks = disk_blocks}
	root.stores[0].name[0] = 's'
	root.stores[0].limit = 1 << 20
	root.stores[0].used = used_blocks
	root.stores[0].store = store_block
	root.check = format.root_check(root)
	return ([^]u8)(root)[:BLOCK_SIZE]
}

// erase_data writes a block of data that holds a text, and gives its
// Pointer and the size of the text.
@(private = "file")
erase_data :: proc(disk: ^Test_Disk, text: string) -> (pointer: format.Pointer, size: u64) {
	bytes: block_tree.Block
	copy(bytes[:], text)
	pointer, _ = disk_data(disk, &bytes, 0)
	return pointer, u64(len(text))
}

// image_with gives the base image with the first `count` writes, and the
// write `torn` (when it is not -1) with only its first half.
@(private = "file")
image_with :: proc(image: []u8, base: []u8, writes: []Erase_Write, count: int, torn: int = -1) {
	copy(image, base)
	for write in writes[:count] {
		copy(image[write.number * BLOCK_SIZE:][:BLOCK_SIZE], write.bytes)
	}
	if torn >= 0 {
		write := writes[torn]
		copy(image[write.number * BLOCK_SIZE:][:BLOCK_SIZE / 2], write.bytes[:BLOCK_SIZE / 2])
	}
}

@(test)
the_erase_of_versions_through_a_loss_of_power :: proc(t: ^testing.T) {
	disk := disk_make(ERASE_DISK_BLOCKS)
	defer delete(disk.bytes)

	// The state before the erase: "a" with two versions, the newer one on
	// the block of "b".
	first_version, first_size := erase_data(&disk, "the first version of a, a secret")
	shared, shared_size := erase_data(&disk, "the bytes of b")
	current, current_size := erase_data(&disk, "the current version of a")
	leaf: format.Version_Leaf
	leaf.count = 2
	leaf.entries[0] = {generation = 3, size = first_size, root = first_version}
	leaf.entries[1] = {generation = 4, size = shared_size, root = shared}
	leaf_pointer := disk_put(&disk, &leaf)
	index: format.Version_Index
	index.leaf_count = 1
	index.version_count = 2
	index.leaves[0] = leaf_pointer
	index_pointer := disk_put(&disk, &index)
	entry_a := format.Entry{kind = u64(format.Entry_Kind.Object), size = current_size, generation = 5, pointer = current, versions = index_pointer}
	entry_b := format.Entry{kind = u64(format.Entry_Kind.Object), size = shared_size, generation = 4, pointer = shared}
	tree_before := disk_leaf(&disk, []Named_Entry{{"a", entry_a}, {"b", entry_b}})
	store_before := format.Store_Block{tree = tree_before, objects = 2, current_blocks = 2, node_blocks = 1}
	store_before_pointer := disk_put(&disk, &store_before)
	// The store block, the leaf of the tree, the index, the leaf of the
	// versions, and three blocks of data.
	copy(disk.bytes[:BLOCK_SIZE], erase_root(ERASE_DISK_BLOCKS, ERASE_BEFORE_GENERATION, store_before_pointer, 7))

	// The commit of the end: a new leaf of the tree, whose entry "a" names
	// no version index, and a new store block. Each goes to a free block.
	first_pending := disk.next
	entry_a_after := entry_a
	entry_a_after.versions = {}
	tree_after := disk_leaf(&disk, []Named_Entry{{"a", entry_a_after}, {"b", entry_b}})
	store_after := format.Store_Block{tree = tree_after, objects = 2, current_blocks = 2, node_blocks = 1}
	store_after_pointer := disk_put(&disk, &store_after)
	writes := make([dynamic]Erase_Write, context.temp_allocator)
	for number in first_pending ..< disk.next {
		bytes := make([]u8, BLOCK_SIZE, context.temp_allocator)
		copy(bytes, disk.bytes[number * BLOCK_SIZE:][:BLOCK_SIZE])
		append(&writes, Erase_Write{number = number, bytes = bytes})
		// The base image is the disk before the erase: these blocks are free
		// in it.
		for &byte in disk.bytes[number * BLOCK_SIZE:][:BLOCK_SIZE] {
			byte = 0
		}
	}
	// The root of the commit, in the other place; then the same root with
	// the next generation, over the root before.
	root_of_end := len(writes)
	append(&writes, Erase_Write{number = 1, bytes = erase_root(ERASE_DISK_BLOCKS, ERASE_BEFORE_GENERATION + 1, store_after_pointer, 4)})
	root_again := len(writes)
	append(&writes, Erase_Write{number = 0, bytes = erase_root(ERASE_DISK_BLOCKS, ERASE_BEFORE_GENERATION + 2, store_after_pointer, 4)})
	// The zeros: each block that the commit freed. The block of "b" is not
	// one of them: "b" still names it.
	freed := [?]u64{store_before_pointer.block, tree_before.block, index_pointer.block, leaf_pointer.block, first_version.block}
	first_zero := len(writes)
	zeros := make([]u8, BLOCK_SIZE, context.temp_allocator)
	for number in freed {
		append(&writes, Erase_Write{number = number, bytes = zeros})
	}

	base := disk.bytes
	image := make([]u8, len(base))
	defer delete(image)
	image_disk := Test_Disk{reader = {read = test_read}, bytes = image}
	state := new(State)
	defer free(state)

	// check opens one image: it opens, with no wrong block, and with the two
	// versions at the generation before the erase, or with none after it.
	check :: proc(t: ^testing.T, state: ^State, image_disk: ^Test_Disk, what: string) -> Mount {
		result := mount(state, image_disk, ERASE_DISK_BLOCKS)
		testing.expectf(t, !result.failed, "%s: the disk does not open", what)
		testing.expectf(t, result.wrong == 0 && result.damaged_versions == 0 && result.damaged_objects == 0, "%s: %d wrong blocks, %d damaged versions, %d damaged objects", what, result.wrong, result.damaged_versions, result.damaged_objects)
		testing.expectf(t, result.objects == 2, "%s: %d objects", what, result.objects)
		before := result.generation == ERASE_BEFORE_GENERATION
		testing.expectf(t, before ? result.versions == 2 : result.versions == 0, "%s: %d versions at the generation %d", what, result.versions, result.generation)
		return result
	}

	// Each prefix of the writes: a loss of power after each write.
	for count in 0 ..= len(writes) {
		image_with(image, base, writes[:], count)
		result := check(t, state, &image_disk, "a loss of power after a write of the erase")
		switch {
		case count <= root_of_end:
			testing.expectf(t, result.generation == ERASE_BEFORE_GENERATION, "after %d writes: the generation %d", count, result.generation)
		case count == root_again:
			// The root of the end is on the disk: the open takes it, and the
			// freed blocks are free in it, with their bytes.
			testing.expect_value(t, result.generation, u64(ERASE_BEFORE_GENERATION + 1))
			for number in freed {
				testing.expectf(t, !used(state, number), "the block %d that the commit freed is in use", number)
			}
			testing.expect_value(t, state.references[shared.block], 1)
		case:
			testing.expect_value(t, result.generation, u64(ERASE_BEFORE_GENERATION + 2))
		}
	}
	// The write of each root cut in its middle: the open takes the root in
	// the other place.
	image_with(image, base, writes[:], root_of_end, root_of_end)
	result := check(t, state, &image_disk, "the root of the end cut")
	testing.expect_value(t, result.generation, u64(ERASE_BEFORE_GENERATION))
	image_with(image, base, writes[:], root_again, root_again)
	result = check(t, state, &image_disk, "the second root cut")
	testing.expect_value(t, result.generation, u64(ERASE_BEFORE_GENERATION + 1))
	// Each write of zeros alone after the two roots: the writes after the
	// last Flush can reach the disk in any subset.
	for zero in first_zero ..< len(writes) {
		image_with(image, base, writes[:], first_zero)
		copy(image[writes[zero].number * BLOCK_SIZE:][:BLOCK_SIZE], writes[zero].bytes)
		check(t, state, &image_disk, "one write of zeros alone")
	}
	// A disk that dropped the write of the second root and kept the zeros:
	// the place of that root still holds the root before the erase, which
	// names blocks of zeros. The open takes the newer root of the end, which
	// names none.
	image_with(image, base, writes[:], root_again)
	for zero in first_zero ..< len(writes) {
		copy(image[writes[zero].number * BLOCK_SIZE:][:BLOCK_SIZE], writes[zero].bytes)
	}
	result = check(t, state, &image_disk, "the second root dropped")
	testing.expect_value(t, result.generation, u64(ERASE_BEFORE_GENERATION + 1))

	// The end: the versions are gone, the freed blocks hold zeros, and the
	// block of "b" keeps its bytes.
	image_with(image, base, writes[:], len(writes))
	result = check(t, state, &image_disk, "the whole erase")
	testing.expect_value(t, result.versions, 0)
	for number in freed {
		testing.expectf(t, block_tree.is_zero(image[number * BLOCK_SIZE:][:BLOCK_SIZE]), "the freed block %d does not hold zeros", number)
	}
	testing.expect(t, string(image[shared.block * BLOCK_SIZE:][:shared_size]) == "the bytes of b")
	testing.expect(t, used(state, shared.block))
	testing.expect(t, used(state, current.block))
}
