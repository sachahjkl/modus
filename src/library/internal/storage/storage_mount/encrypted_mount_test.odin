#+build !freestanding
package storage_mount

import "core:testing"
import format "modus:contract/store"
import block_tree "internal:storage/storage_object"
import "internal:storage/store_encryption"

@(private = "file")
enc_mount_keys :: proc() -> store_encryption.Store_Keys {
	storage: store_encryption.Key
	id: [32]u8
	salt: store_encryption.Salt
	for i in 0 ..< 32 {
		storage[i] = u8(i + 11)
		id[i] = u8(i + 55)
		salt[i] = u8(i + 99)
	}
	keys, _ := store_encryption.store_keys_of(storage, id, salt)
	return keys
}

@(private = "file")
disk_set_block :: proc(disk: ^Test_Disk, number: u64, bytes: []u8) {
	copy(disk.bytes[number * BLOCK_SIZE:][:BLOCK_SIZE], bytes[:BLOCK_SIZE])
}

@(private = "file")
disk_take_block :: proc(disk: ^Test_Disk) -> u64 {
	number := disk.next
	disk.next += 1
	return number
}

// Owned store cells hold OWNED_CELL_MARK followed by 31 binary tag bytes
// (which can include embedded zero bytes and a non-zero last byte).
// An all-zero tag after OWNED_CELL_MARK is refused.
@(test)
store_page_read_accepts_owned_binary_tags_and_refuses_all_zero_tag :: proc(t: ^testing.T) {
	disk := disk_make(64)
	defer delete(disk.bytes)
	state := test_state_make(64, 64)
	defer test_state_free(state)

	// Build a valid owned store block with no entries.
	keys := enc_mount_keys()
	sb: format.Store_Block
	sb.owner[0] = 1
	sb.salt[0] = 2
	sb.key_check = keys.check
	sb.store_generation = 1
	sb_block := disk_take_block(&disk)
	sb_check, ok := store_encryption.store_block_seal(&keys, sb_block, &sb)
	testing.expect(t, ok)
	disk_set_block(&disk, sb_block, ([^]u8)(&sb)[:BLOCK_SIZE])

	// Owned cell tag with embedded zero at [5] and non-zero byte at [31].
	cell: format.Store_Entry
	cell.name[0] = format.OWNED_CELL_MARK
	cell.name[1] = 0xAB
	cell.name[5] = 0x00
	cell.name[format.NAME_CAPACITY - 1] = 0xFE
	cell.limit = 16
	cell.used = 1
	cell.store = {block = sb_block, check = sb_check}
	page_ptr := disk_page(&disk, {cell})

	root := root_of_page(64, 1, page_ptr)
	disk_set_block(&disk, 0, ([^]u8)(&root)[:BLOCK_SIZE])

	res := mount(state, &disk.reader, 64)
	testing.expect(t, !res.failed)
	testing.expect_value(t, res.damaged_store_pages, u64(0))
	testing.expect_value(t, res.damaged_stores, u64(0))
	testing.expect_value(t, res.stores, u64(1))
	testing.expect_value(t, res.wrong, u64(0))

	// Refusal: OWNED_CELL_MARK followed by 31 zero bytes must damage the page.
	bad_cell := cell
	bad_cell.name = {}
	bad_cell.name[0] = format.OWNED_CELL_MARK
	bad_page_ptr := disk_page(&disk, {bad_cell})
	root2 := root_of_page(64, 2, bad_page_ptr)
	disk_set_block(&disk, 1, ([^]u8)(&root2)[:BLOCK_SIZE])

	// With older good root at block 0, mount detects damage on newest root and falls back to block 0.
	res2 := mount(state, &disk.reader, 64)
	testing.expect(t, !res2.failed)
	testing.expect(t, res2.older, "mount must fall back to older root when newest has damaged owned cell")
	testing.expect_value(t, res2.generation, u64(1))
}

// Keyless mount of a full encrypted store: sealed Store_Block, sealed tree
// leaf, 1-block encrypted object, 2-block encrypted object with sealed
// Object_Node, sealed Version_Index/Version_Leaf, and sealed Release_List.
// Mount counts every block accurately, skips indexing encrypted hashes, and
// detects tampered ciphertext on disk.
@(test)
keyless_mount_walks_encrypted_store_and_detects_tampered_ciphertext :: proc(t: ^testing.T) {
	disk := disk_make(128)
	defer delete(disk.bytes)
	state := test_state_make(128, 128)
	defer test_state_free(state)
	keys := enc_mount_keys()

	// 1. Encrypted 1-block object data.
	b0: block_tree.Block
	for i in 0 ..< BLOCK_SIZE {
		b0[i] = u8(i + 1)
	}
	v0 := block_tree.block_value(&b0, 0)
	dc0 := format.value_check(v0)
	d0_block := disk_take_block(&disk)
	d0_cipher := b0
	d0_check := store_encryption.data_block_encrypt(&keys, d0_block, dc0, &d0_cipher)
	disk_set_block(&disk, d0_block, d0_cipher[:])

	// 2. Encrypted 2-block object (level-1 Object_Node + 2 encrypted data blocks).
	b1, b2: block_tree.Block
	for i in 0 ..< BLOCK_SIZE {
		b1[i] = u8(i * 3 + 2)
		b2[i] = u8(i * 5 + 3)
	}
	v1 := block_tree.block_value(&b1, 0)
	v2 := block_tree.block_value(&b2, 1)
	d1_block := disk_take_block(&disk)
	d1_cipher := b1
	d1_check := store_encryption.data_block_encrypt(&keys, d1_block, format.value_check(v1), &d1_cipher)
	disk_set_block(&disk, d1_block, d1_cipher[:])
	d2_block := disk_take_block(&disk)
	d2_cipher := b2
	d2_check := store_encryption.data_block_encrypt(&keys, d2_block, format.value_check(v2), &d2_cipher)
	disk_set_block(&disk, d2_block, d2_cipher[:])

	obj_node: format.Object_Node
	obj_node.header = {level = 1, count = 2, magic = format.OBJECT_NODE_MAGIC}
	obj_node.children[0] = {block = d1_block, check = d1_check, blocks = 1, value = v1}
	obj_node.children[1] = {block = d2_block, check = d2_check, blocks = 1, value = v2}
	obj_block := disk_take_block(&disk)
	obj_check, obj_ok := store_encryption.object_node_seal(&keys, obj_block, &obj_node)
	testing.expect(t, obj_ok)
	disk_set_block(&disk, obj_block, ([^]u8)(&obj_node)[:BLOCK_SIZE])

	// 3. Sealed Version_Leaf + Version_Index referencing the 1-block object as a version.
	vl: format.Version_Leaf
	vl.count = 1
	vl.entries[0] = {size = 500, root = {block = d0_block, check = d0_check}, generation = 1, data_check = dc0}
	vl_block := disk_take_block(&disk)
	vl_check, vl_ok := store_encryption.version_leaf_seal(&keys, vl_block, &vl)
	testing.expect(t, vl_ok)
	disk_set_block(&disk, vl_block, ([^]u8)(&vl)[:BLOCK_SIZE])

	vi: format.Version_Index
	vi.leaf_count = 1
	vi.version_count = 1
	vi.leaves[0] = {block = vl_block, check = vl_check}
	vi_block := disk_take_block(&disk)
	vi_check, vi_ok := store_encryption.version_index_seal(&keys, vi_block, &vi)
	testing.expect(t, vi_ok)
	disk_set_block(&disk, vi_block, ([^]u8)(&vi)[:BLOCK_SIZE])

	// 4. Sealed B+ tree leaf with both objects (names encrypted).
	leaf: [BLOCK_SIZE]u8
	hdr := (^format.Tree_Header)(&leaf)
	hdr^ = {level = 0, count = 2, magic = format.NODE_MAGIC}
	stride :: size_of(format.Entry_Name) + size_of(format.Entry)
	hash_a: [32]u8
	hash_a[0] = 1
	hash_b: [32]u8
	hash_b[0] = 2
	(^format.Entry_Name)(&leaf[format.TREE_HEADER_SIZE])^ = format.entry_name("alpha")
	(^format.Entry)(&leaf[format.TREE_HEADER_SIZE + size_of(format.Entry_Name)])^ = {
		kind       = u64(format.Entry_Kind.Object),
		size       = 500,
		generation = 1,
		hash       = hash_a,
		data_check = dc0,
		pointer    = {block = d0_block, check = d0_check},
	}
	(^format.Entry_Name)(&leaf[format.TREE_HEADER_SIZE + stride])^ = format.entry_name("beta")
	(^format.Entry)(&leaf[format.TREE_HEADER_SIZE + stride + size_of(format.Entry_Name)])^ = {
		kind       = u64(format.Entry_Kind.Object),
		size       = BLOCK_SIZE + 100,
		generation = 2,
		hash       = hash_b,
		pointer    = {block = obj_block, check = obj_check},
		versions   = {block = vi_block, check = vi_check},
	}
	leaf_block := disk_take_block(&disk)
	leaf_check, leaf_ok := store_encryption.tree_node_seal(&keys, leaf_block, &leaf)
	testing.expect(t, leaf_ok)
	disk_set_block(&disk, leaf_block, leaf[:])

	// 5. Sealed Release_List + removal queue leaf.
	rl: format.Release_List
	rl.magic = format.RELEASE_LIST_MAGIC
	rl.count = 1
	rl.states[0] = {root = {block = d0_block, check = d0_check}, size = 500, cursor = 0}
	rl_block := disk_take_block(&disk)
	rl_check, rl_ok := store_encryption.release_list_seal(&keys, rl_block, &rl)
	testing.expect(t, rl_ok)
	disk_set_block(&disk, rl_block, ([^]u8)(&rl)[:BLOCK_SIZE])

	rem_leaf: [BLOCK_SIZE]u8
	(^format.Tree_Header)(&rem_leaf)^ = {level = 0, count = 1, magic = format.NODE_MAGIC}
	(^format.Entry_Name)(&rem_leaf[format.TREE_HEADER_SIZE])^ = format.removal_name(0)
	(^format.Entry)(&rem_leaf[format.TREE_HEADER_SIZE + size_of(format.Entry_Name)])^ = {
		kind    = u64(format.Entry_Kind.Release),
		pointer = {block = rl_block, check = rl_check},
	}
	rem_block := disk_take_block(&disk)
	rem_check, rem_ok := store_encryption.tree_node_seal(&keys, rem_block, &rem_leaf)
	testing.expect(t, rem_ok)
	disk_set_block(&disk, rem_block, rem_leaf[:])

	// 6. Sealed Store_Block.
	sb: format.Store_Block
	sb.tree = {block = leaf_block, check = leaf_check}
	sb.removals = {block = rem_block, check = rem_check}
	sb.objects = 2
	sb.current_blocks = 4 // d0 + obj_node + d1 + d2
	sb.node_blocks = 2 // leaf + rem_leaf
	sb.removing = 1
	sb.owner[0] = 1
	sb.salt[0] = 2
	sb.key_check = keys.check
	sb.store_generation = 1
	sb_block := disk_take_block(&disk)
	sb_check, sb_ok := store_encryption.store_block_seal(&keys, sb_block, &sb)
	testing.expect(t, sb_ok)
	disk_set_block(&disk, sb_block, ([^]u8)(&sb)[:BLOCK_SIZE])

	// Distinct blocks of this store: sb, leaf, rem_leaf, rl, vi, vl, obj_node, d0, d1, d2 = 10 blocks.
	cell: format.Store_Entry
	cell.name[0] = format.OWNED_CELL_MARK
	cell.name[1] = 0x55
	cell.name[31] = 0xAA
	cell.limit = 64
	cell.used = 10
	cell.store = {block = sb_block, check = sb_check}
	page_ptr := disk_page(&disk, {cell})

	root := root_of_page(128, 1, page_ptr)
	disk_set_block(&disk, 0, ([^]u8)(&root)[:BLOCK_SIZE])

	res := mount(state, &disk.reader, 128)
	testing.expect(t, !res.failed)
	testing.expect_value(t, res.wrong, u64(0))
	testing.expect_value(t, res.damaged_stores, u64(0))
	testing.expect_value(t, res.damaged_objects, u64(0))
	testing.expect_value(t, res.damaged_versions, u64(0))
	testing.expect_value(t, res.stores_with_wrong_count, u64(0))
	testing.expect_value(t, state.store_recount[0], u64(10))
	testing.expect_value(t, state.references[d0_block], u32(3)) // current + version + release list
	testing.expect_value(t, state.hash_index.record_count, u64(0)) // encrypted hashes not indexed at keyless mount

	// Tamper one byte of encrypted data block d2 on disk: keyless mount must detect it.
	disk.bytes[d2_block * BLOCK_SIZE + 17] ~= 0x01
	res_bad := mount(state, &disk.reader, 128)
	testing.expect_value(t, res_bad.wrong, u64(1))
	testing.expect_value(t, res_bad.damaged_objects, u64(1))
}

// hash_index_clear_store removes every record and slot of one store while
// keeping other stores intact and leaving hash_index_check at 0 faults.
@(test)
hash_index_clear_store_removes_only_target_store :: proc(t: ^testing.T) {
	state := test_state_make(128, 128)
	defer test_state_free(state)

	// Populate blocks owned by store 0 (owner 1) and store 1 (owner 2).
	for i in u64(0) ..< 12 {
		b0 := u64(10 + i)
		b1 := u64(40 + i)
		block_set(state, b0, 1, 1) // store 0
		block_set(state, b1, 1, 2) // store 1
		h0: [32]u8
		h1: [32]u8
		h0[0] = u8(i + 1)
		h1[0] = u8(i + 100)
		hash_index_name(state, h0, {block = b0, check = b0 * 7}, 512, false, 0xCAFE + i)
		hash_index_name(state, h1, {block = b1, check = b1 * 7}, 512, false, 0xBEEF + i)
	}
	testing.expect_value(t, state.hash_index.record_count, u64(24))
	testing.expect_value(t, hash_index_check(state), u64(0))
	testing.expect_value(t, hash_index_record(state, 10).data_check, u64(0xCAFE))

	// Clear store 0 only.
	hash_index_clear_store(state, 0)
	testing.expect_value(t, state.hash_index.record_count, u64(12))
	testing.expect_value(t, state.hash_index.roots, u64(12))
	testing.expect_value(t, hash_index_check(state), u64(0))
	for i in u64(0) ..< 12 {
		testing.expect(t, hash_index_record(state, 10 + i) == nil, "store 0 record must be removed")
		rec := hash_index_record(state, 40 + i)
		testing.expect(t, rec != nil, "store 1 record must remain")
		if rec != nil {
			testing.expect_value(t, rec.data_check, u64(0xBEEF + i))
		}
	}
}
