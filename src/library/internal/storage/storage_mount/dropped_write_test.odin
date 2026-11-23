#+build !freestanding
package storage_mount

import format "modus:contract/store"
import block_tree "internal:storage/storage_object"
import "core:testing"

// A refused commit and the commit after it
// (src/md/features/dropped_write.md). The object "a" holds its first
// version at the root before. The commit of its second version wrote its
// block of data, its leaf and its store block, and the disk dropped the
// block of data: the read back of the blocks refused the commit before its
// root, so no root names those blocks. The next commit starts from the
// state of the root before: it writes its version to blocks that are free
// in it, which are the blocks of the refused commit, then its root in the
// other place. This test builds each image that a loss of power can leave
// in that order, and opens each one with the code of the open. It checks a
// model of the writes, built by hand in the order of the service, not the
// service itself.
//
// The model runs two times: once with other bytes in the dropped block,
// and once with the same bytes as the refused commit (a later write of the
// same version). With the read back before the root, no image shows the
// refused commit in either case: no root on the disk ever named it.

@(private = "file")
DROPPED_DISK_BLOCKS :: 16
@(private = "file")
DROPPED_BEFORE_GENERATION :: 10 // The generation of the root before the refused commit.
@(private = "file")
DROPPED_TEXT :: "the version that the disk drops"

// One write of the commit after the refusal: a block number and its bytes.
@(private = "file")
Dropped_Write_Model_Write :: struct {
	number: u64,
	bytes:  []u8,
}

// One state of the model: the store block, and the page of the store table
// that names it.
@(private = "file")
Dropped_State :: struct {
	store: format.Pointer,
	page:  format.Pointer,
}

// dropped_root gives the bytes of a root of one page of the store table.
@(private = "file")
dropped_root :: proc(generation: u64, state: Dropped_State) -> []u8 {
	root := new(format.Root, context.temp_allocator)
	root^ = root_of_page(DROPPED_DISK_BLOCKS, generation, state.page)
	return ([^]u8)(root)[:BLOCK_SIZE]
}

// dropped_state writes one version of "a": its block of data, its leaf,
// its store block and the page of the store table.
@(private = "file")
dropped_state :: proc(disk: ^Test_Disk, text: string) -> (state: Dropped_State) {
	bytes: block_tree.Block
	copy(bytes[:], text)
	data, _ := disk_data(disk, &bytes, 0)
	state.store = disk_store(disk, {root = data, data = data, size = u64(len(text))}, {})
	state.page = disk_page(disk, {store_s(state.store, STATE_BLOCKS)})
	return state
}

// The blocks of a state that the store counts: the data, the leaf and the
// store block. The page belongs to the store table.
@(private = "file")
STATE_BLOCKS :: 3

// dropped_check opens one image: it opens with no wrong block, at the root
// before or at the commit after the refusal. It gives true for the commit
// after the refusal.
@(private = "file")
dropped_check :: proc(t: ^testing.T, state: ^State, image_disk: ^Test_Disk, before: Dropped_State, next_state: Dropped_State, what: string) -> (next: bool) {
	before_store, next_store := before.store, next_state.store
	opened := mount(state, image_disk, DROPPED_DISK_BLOCKS)
	testing.expectf(t, !opened.failed, "%s: the disk does not open", what)
	testing.expectf(t, !opened.older, "%s: the open fell back: a root on the disk names a wrong block", what)
	testing.expectf(t, opened.wrong == 0 && opened.damaged_objects == 0 && opened.damaged_stores == 0, "%s: %d wrong blocks, %d damaged objects, %d damaged stores", what, opened.wrong, opened.damaged_objects, opened.damaged_stores)
	testing.expectf(t, opened.objects == 1, "%s: %d objects", what, opened.objects)
	store := store_cell(state, 0).store
	next = opened.generation == DROPPED_BEFORE_GENERATION + 1
	if next {
		testing.expectf(t, store == next_store, "%s: the generation of the next commit names another store block", what)
	} else {
		testing.expectf(t, opened.generation == DROPPED_BEFORE_GENERATION && store == before_store, "%s: the generation %d, not the root before", what, opened.generation)
	}
	return next
}

// dropped_model builds the images of one run and checks each one. The next
// commit writes `next_text` as the version of "a".
@(private = "file")
dropped_model :: proc(t: ^testing.T, next_text: string) {
	disk := disk_make(DROPPED_DISK_BLOCKS)
	defer delete(disk.bytes)
	// The data, the leaf and the store block of each state.

	// The root before, in the place 0, and an older root in the place 1:
	// the root of the commit before it, which names the same state here.
	store_before := dropped_state(&disk, "the version that the disk keeps")
	copy(disk.bytes[:BLOCK_SIZE], dropped_root(DROPPED_BEFORE_GENERATION, store_before))
	copy(disk.bytes[BLOCK_SIZE:][:BLOCK_SIZE], dropped_root(DROPPED_BEFORE_GENERATION - 1, store_before))

	// The blocks of the refused commit. The disk did not keep its block of
	// data, which holds the zero bytes of a free block, and the read back
	// refused the commit before its root.
	refused_first := disk.next
	_ = dropped_state(&disk, DROPPED_TEXT)
	for &byte in disk.bytes[refused_first * BLOCK_SIZE:][:BLOCK_SIZE] {
		byte = 0
	}
	base := make([]u8, len(disk.bytes))
	defer delete(base)
	copy(base, disk.bytes)

	// The commit after the refusal, from the state of the root before: the
	// blocks of the refused commit are free in it, so it can take them
	// again. The allocator of the service takes them again only after a wrap
	// of the disk; the model takes them at once, the worst case, so that its
	// block of data is the dropped block.
	disk.next = refused_first
	store_next := dropped_state(&disk, next_text)
	writes := make([dynamic]Dropped_Write_Model_Write, context.temp_allocator)
	for number in refused_first ..< disk.next {
		bytes := make([]u8, BLOCK_SIZE, context.temp_allocator)
		copy(bytes, disk.bytes[number * BLOCK_SIZE:][:BLOCK_SIZE])
		append(&writes, Dropped_Write_Model_Write{number = number, bytes = bytes})
	}
	// Its root goes to the other place of the root before.
	next_root := len(writes)
	append(&writes, Dropped_Write_Model_Write{number = 1, bytes = dropped_root(DROPPED_BEFORE_GENERATION + 1, store_next)})

	image := make([]u8, len(base))
	defer delete(image)
	image_disk := Test_Disk{reader = {read = test_read}, bytes = image}
	state := test_state_make()
	defer test_state_free(state)

	// The image that the refusal leaves: the root before, with no fallback.
	copy(image, base)
	testing.expect(t, !dropped_check(t, state, &image_disk, store_before, store_next, "the refused commit"))

	// A loss of power after each write of the next commit.
	for count in 0 ..= len(writes) {
		copy(image, base)
		for write in writes[:count] {
			copy(image[write.number * BLOCK_SIZE:][:BLOCK_SIZE], write.bytes)
		}
		next := dropped_check(t, state, &image_disk, store_before, store_next, "a loss of power after a write of the next commit")
		testing.expectf(t, next == (count > next_root), "after %d writes: the next commit is %s", count, next ? "open" : "not open")
	}
	// Each write of a block alone: the writes before a Flush reach the disk
	// in any subset. The write of the dropped block alone is the case that
	// a root of the refused commit on the disk would have made whole.
	for write in writes[:next_root] {
		copy(image, base)
		copy(image[write.number * BLOCK_SIZE:][:BLOCK_SIZE], write.bytes)
		testing.expect(t, !dropped_check(t, state, &image_disk, store_before, store_next, "one block of the next commit alone"))
	}
	// The root of the next commit cut in its middle: the open takes the
	// root before.
	copy(image, base)
	for write in writes[:next_root] {
		copy(image[write.number * BLOCK_SIZE:][:BLOCK_SIZE], write.bytes)
	}
	copy(image[BLOCK_SIZE:][:BLOCK_SIZE / 2], writes[next_root].bytes[:BLOCK_SIZE / 2])
	testing.expect(t, !dropped_check(t, state, &image_disk, store_before, store_next, "the root of the next commit cut"))
}

@(test)
a_refused_commit_and_the_commit_after_it :: proc(t: ^testing.T) {
	dropped_model(t, "the third version")
}

// The next commit writes the bytes of the refused commit to the dropped
// block: the image never shows the refused commit, as no root names it.
@(test)
a_refused_commit_and_the_same_bytes_after_it :: proc(t: ^testing.T) {
	dropped_model(t, DROPPED_TEXT)
}

// The second root of an erase of versions that the disk dropped
// (src/md/features/version_erase.md, step 3). The commit of the end, N, is
// in the place 0; the root before it, P, is in the place 1 and names the
// blocks that N freed. The disk did not keep the second root, so P stays,
// and the service keeps N and writes no zeros. The next commit starts from
// N: the blocks that only P names are free in it, and the model takes them
// at once, the worst case. Its root goes over P. Each image opens at N or
// at the next commit, never at P, with no wrong block.
@(test)
a_dropped_second_root_and_the_commit_after_it :: proc(t: ^testing.T) {
	disk := disk_make(DROPPED_DISK_BLOCKS)
	defer delete(disk.bytes)

	// P: the state with the version, in the blocks 2 to 4.
	first_freed := disk.next
	store_p := dropped_state(&disk, "the version that the erase ends")
	copy(disk.bytes[BLOCK_SIZE:][:BLOCK_SIZE], dropped_root(DROPPED_BEFORE_GENERATION - 1, store_p))
	// N: the commit of the end, in the blocks after them.
	store_n := dropped_state(&disk, "the current version")
	copy(disk.bytes[:BLOCK_SIZE], dropped_root(DROPPED_BEFORE_GENERATION, store_n))
	base := make([]u8, len(disk.bytes))
	defer delete(base)
	copy(base, disk.bytes)

	// The next commit from N, on the blocks that only P names.
	after_n := disk.next
	disk.next = first_freed
	store_next := dropped_state(&disk, "the next version")
	testing.expect(t, disk.next <= after_n)
	writes := make([dynamic]Dropped_Write_Model_Write, context.temp_allocator)
	for number in first_freed ..< disk.next {
		bytes := make([]u8, BLOCK_SIZE, context.temp_allocator)
		copy(bytes, disk.bytes[number * BLOCK_SIZE:][:BLOCK_SIZE])
		append(&writes, Dropped_Write_Model_Write{number = number, bytes = bytes})
	}
	next_root := len(writes)
	append(&writes, Dropped_Write_Model_Write{number = 1, bytes = dropped_root(DROPPED_BEFORE_GENERATION + 1, store_next)})

	image := make([]u8, len(base))
	defer delete(image)
	image_disk := Test_Disk{reader = {read = test_read}, bytes = image}
	state := test_state_make()
	defer test_state_free(state)

	for count in 0 ..= len(writes) {
		copy(image, base)
		for write in writes[:count] {
			copy(image[write.number * BLOCK_SIZE:][:BLOCK_SIZE], write.bytes)
		}
		next := dropped_check(t, state, &image_disk, store_n, store_next, "a loss of power after a write of the commit after a dropped second root")
		testing.expectf(t, next == (count > next_root), "after %d writes: the next commit is %s", count, next ? "open" : "not open")
	}
	for write in writes[:next_root] {
		copy(image, base)
		copy(image[write.number * BLOCK_SIZE:][:BLOCK_SIZE], write.bytes)
		testing.expect(t, !dropped_check(t, state, &image_disk, store_n, store_next, "one block of the commit after a dropped second root alone"))
	}
	copy(image, base)
	for write in writes[:next_root] {
		copy(image[write.number * BLOCK_SIZE:][:BLOCK_SIZE], write.bytes)
	}
	copy(image[BLOCK_SIZE:][:BLOCK_SIZE / 2], writes[next_root].bytes[:BLOCK_SIZE / 2])
	testing.expect(t, !dropped_check(t, state, &image_disk, store_n, store_next, "the root of the commit after a dropped second root cut"))
}
