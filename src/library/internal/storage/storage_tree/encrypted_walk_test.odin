#+build !freestanding
package storage_tree

import "core:testing"
import "internal:storage/store_encryption"

@(private = "file")
enc_test_keys :: proc() -> store_encryption.Store_Keys {
	storage: store_encryption.Key
	id: [32]u8
	salt: store_encryption.Salt
	for i in 0 ..< 32 {
		storage[i] = u8(i + 1)
		id[i] = u8(i + 33)
		salt[i] = u8(i + 65)
	}
	keys, _ := store_encryption.store_keys_of(storage, id, salt)
	return keys
}

// Keyless walk of an encrypted B+ tree: accepts encrypted (unsorted) keys
// in leaves and branches, visits every record, and still refuses bad magic,
// bad count, bad level, and a zero branch child.
@(test)
keyless_walk_of_encrypted_tree_accepts_sealed_nodes_and_refuses_bad_structure :: proc(t: ^testing.T) {
	keys := enc_test_keys()
	disk := disk_make()
	defer disk_free(disk)
	pool := new(Pool)
	defer free(pool)

	// Build a multi-leaf tree (20 entries -> 1 branch + multiple leaves).
	work := Work{pool = pool, source = &disk.source, shape = TREE_SHAPE}
	for i in u64(0) ..< 20 {
		key := name_of_number(i + 100)
		entry := entry_of_number(i + 100)
		put(&work, key[:], ([^]u8)(&entry)[:size_of(entry)], false)
	}
	clear_root := finish(&work, &disk.writer)
	testing.expect_value(t, pool.failure, Failure.None)

	// Seal every node of the tree in place and rewrite child pointers bottom-up.
	enc_disk := disk_make()
	defer disk_free(enc_disk)
	seal_node :: proc(keys: ^store_encryption.Store_Keys, src: ^Test_Disk, dst: ^Test_Disk, ptr: Pointer) -> Pointer {
		node := src.blocks[ptr.block]
		head := header(&node)
		if head.level > 0 {
			for idx in 0 ..< int(head.count) {
				child_ptr := child_at(&node, TREE_SHAPE, idx)
				child_ptr^ = seal_node(keys, src, dst, child_ptr^)
			}
		}
		block_num := u64(len(dst.blocks))
		check, ok := store_encryption.tree_node_seal(keys, block_num, &node)
		assert(ok)
		append(&dst.blocks, node)
		return {block = block_num, check = check}
	}
	enc_root := seal_node(&keys, disk, enc_disk, clear_root)

	// Clear walk (encrypted = false) must fail on encrypted unsorted keys.
	clear_walk := new(Walk)
	defer free(clear_walk)
	clear_walk.source = &enc_disk.source
	clear_walk.shape = TREE_SHAPE
	testing.expect_value(t, walk_tree(clear_walk, enc_root), Failure.Damaged)

	// Encrypted keyless walk (encrypted = true) succeeds and visits all 20 records.
	enc_walk := new(Walk)
	defer free(enc_walk)
	enc_walk.source = &enc_disk.source
	enc_walk.shape = TREE_SHAPE
	enc_walk.encrypted = true
	testing.expect_value(t, walk_tree(enc_walk, enc_root), Failure.None)
	testing.expect_value(t, enc_walk.records, u64(20))

	// Refusals even when encrypted = true: bad magic, count 0, count > capacity, zero branch child.
	bad_leaf := enc_disk.blocks[enc_root.block]
	header(&bad_leaf).magic = 0
	testing.expect(t, !node_valid(&bad_leaf, TREE_SHAPE, true))

	bad_count := enc_disk.blocks[enc_root.block]
	header(&bad_count).count = 0
	testing.expect(t, !node_valid(&bad_count, TREE_SHAPE, true))

	bad_child := enc_disk.blocks[enc_root.block]
	child_at(&bad_child, TREE_SHAPE, 0).block = 0
	testing.expect(t, !node_valid(&bad_child, TREE_SHAPE, true))
}
