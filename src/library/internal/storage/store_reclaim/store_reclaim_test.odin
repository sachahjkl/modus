#+build !freestanding
package store_reclaim

import "core:testing"
import "internal:storage/storage_mount"
import block_tree "internal:storage/storage_object"
import "internal:storage/storage_release"
import "internal:storage/store_encryption"
import format "modus:contract/store"
import "modus:principals"

// ---------------------------------------------------------------------
// In-memory STORAGE7 test disk with real Copy-on-Write commits and full
// storage_mount verification after every step.

@(private = "file")
TEST_DISK_BLOCKS :: 512

@(private = "file")
Test_Disk :: struct {
	blocks:       [TEST_DISK_BLOCKS]Block,
	refs:         [TEST_DISK_BLOCKS]u32,
	owners:       [TEST_DISK_BLOCKS]u16,
	wrong:        [TEST_DISK_BLOCKS]bool,
	root:         format.Root,
	root_place:   u64,
	store_page:   format.Store_Table_Page,
	// Per-commit pending state:
	active_store: int,
	deltas:       [TEST_DISK_BLOCKS]i64,
	used_delta:   i64,
	damaged_hits: u64,
	queued:       [32]format.Release_State,
	queued_count: int,
	alloc_cursor: u64,
}

@(private = "file")
test_disk_init :: proc(d: ^Test_Disk) {
	d^ = {}
	d.refs[0] = 1
	d.refs[1] = 1
	d.alloc_cursor = 2
	d.store_page = {magic = format.STORE_TABLE_MAGIC}
	page_blk := disk_alloc_raw(d, storage_mount.STORE_TABLE_OWNER)
	d.blocks[page_blk] = ((^Block)(&d.store_page))^
	d.root = {
		magic            = format.ROOT_MAGIC,
		generation       = 1,
		disk_blocks      = TEST_DISK_BLOCKS,
		store_page_count = 1,
		store_pages      = {0 = {block = page_blk, check = format.check(d.blocks[page_blk][:])}},
	}
	d.root.check = format.root_check(&d.root)
	d.blocks[0] = ((^Block)(&d.root))^
	d.root_place = 0
}

@(private = "file")
disk_alloc_raw :: proc(d: ^Test_Disk, owner: u16) -> u64 {
	for step in u64(0) ..< TEST_DISK_BLOCKS - 2 {
		cand := 2 + ((d.alloc_cursor - 2 + step) % (TEST_DISK_BLOCKS - 2))
		if d.refs[cand] == 0 && d.deltas[cand] == 0 {
			d.refs[cand] = 1
			d.owners[cand] = owner
			d.alloc_cursor = 2 + ((cand - 2 + 1) % (TEST_DISK_BLOCKS - 2))
			return cand
		}
	}
	return 0
}

@(private = "file")
disk_blocks_in_use :: proc(d: ^Test_Disk) -> u64 {
	total := u64(0)
	for b in 0 ..< TEST_DISK_BLOCKS {
		if d.refs[b] > 0 {
			total += 1
		}
	}
	return total
}

@(private = "file")
disk_reader_read :: proc "contextless" (reader: ^storage_mount.Block_Reader, numbers: []u64, into: []u8) -> bool {
	d := (^Test_Disk)(reader.data)
	for num, idx in numbers {
		if num >= TEST_DISK_BLOCKS {
			return false
		}
		copy(into[idx * format.BLOCK_SIZE:][:format.BLOCK_SIZE], d.blocks[num][:])
	}
	return true
}

@(private = "file")
disk_verify_mount :: proc(t: ^testing.T, d: ^Test_Disk, expect_clean := true) -> storage_mount.Mount {
	state := new(storage_mount.State)
	defer free(state)
	layout, layout_ok := storage_mount.state_layout(TEST_DISK_BLOCKS, TEST_DISK_BLOCKS)
	testing.expect(t, layout_ok)
	mem := make([]u8, layout.bytes)
	defer delete(mem)
	testing.expect(t, storage_mount.state_bind(state, mem, TEST_DISK_BLOCKS, TEST_DISK_BLOCKS))
	reader := storage_mount.Block_Reader{read = disk_reader_read, data = d}
	res := storage_mount.mount(state, &reader, TEST_DISK_BLOCKS)
	testing.expect(t, !res.failed, "mount must not fail")
	testing.expect_value(t, res.damaged_store_pages, u64(0))
	if expect_clean {
		testing.expect_value(t, res.wrong, u64(0))
		testing.expect_value(t, res.damaged_stores, u64(0))
		testing.expect_value(t, res.damaged_objects, u64(0))
		testing.expect_value(t, res.damaged_versions, u64(0))
		testing.expect_value(t, res.stores_with_wrong_count, u64(0))
		testing.expect_value(t, res.stores_recounted, u64(0))
		testing.expect_value(t, res.named_twice, u64(0))
		testing.expect_value(t, res.named_by_two_stores, u64(0))
		testing.expect_value(t, storage_mount.blocks_in_use(state), disk_blocks_in_use(d))
	}
	return res
}

// ---------------------------------------------------------------------
// Reclaim Ops wiring over Test_Disk (mirrors live storage/reclaim.odin).

@(private = "file")
disk_commit_begin :: proc(d: ^Test_Disk, store_index: int) {
	d.active_store = store_index
	d.deltas = {}
	d.used_delta = 0
	d.queued_count = 0
}

@(private = "file")
disk_commit_apply :: proc(d: ^Test_Disk, store_index: int, new_sb: ^format.Store_Block, free_cell: bool) {
	cell := &d.store_page.cells[store_index]
	if free_cell {
		// Drop Store_Block and zero cell.
		sb_blk := cell.store.block
		d.deltas[sb_blk] -= 1
		cell^ = {}
	} else {
		old_sb := cell.store.block
		d.deltas[old_sb] -= 1
		d.used_delta -= 1
		new_sb_blk := disk_commit_alloc(d, u16(store_index + 1))
		d.blocks[new_sb_blk] = ((^Block)(new_sb))^
		d.used_delta += 1
		cell.store = {block = new_sb_blk, check = format.check(d.blocks[new_sb_blk][:])}
		cell.used = u64(i64(cell.used) + d.used_delta)
	}
	// Copy-on-write Store_Table_Page.
	old_page := d.root.store_pages[0].block
	d.deltas[old_page] -= 1
	new_page := disk_commit_alloc(d, storage_mount.STORE_TABLE_OWNER)
	d.blocks[new_page] = ((^Block)(&d.store_page))^
	d.root.store_pages[0] = {block = new_page, check = format.check(d.blocks[new_page][:])}
	d.root.generation += 1
	d.root.check = format.root_check(&d.root)
	d.root_place = 1 - d.root_place
	d.blocks[d.root_place] = ((^Block)(&d.root))^
	// Apply deltas.
	for b in 2 ..< TEST_DISK_BLOCKS {
		if d.deltas[b] != 0 {
			after := i64(d.refs[b]) + d.deltas[b]
			d.refs[b] = u32(max(after, 0))
			if d.refs[b] == 0 {
				d.owners[b] = 0
				d.blocks[b] = {}
			}
		}
	}
	d.deltas = {}
	d.used_delta = 0
}

@(private = "file")
disk_commit_alloc :: proc "contextless" (d: ^Test_Disk, owner: u16) -> u64 {
	for step in u64(0) ..< TEST_DISK_BLOCKS - 2 {
		cand := 2 + ((d.alloc_cursor - 2 + step) % (TEST_DISK_BLOCKS - 2))
		if d.refs[cand] == 0 && d.deltas[cand] == 0 {
			d.deltas[cand] = 1
			d.owners[cand] = owner
			d.alloc_cursor = 2 + ((cand - 2 + 1) % (TEST_DISK_BLOCKS - 2))
			return cand
		}
	}
	return 0
}

@(private = "file")
ops_make :: proc(d: ^Test_Disk, direct_limit := 0) -> Ops {
	return Ops{
		read_block = proc "contextless" (ops: ^Ops, ptr: format.Pointer, into: ^Block) -> Read {
			d := (^Test_Disk)(ops.data)
			if ptr.block < 2 || ptr.block >= TEST_DISK_BLOCKS {
				return .Wrong
			}
			into^ = d.blocks[ptr.block]
			if format.check(into[:]) != ptr.check {
				return .Wrong
			}
			return .Good
		},
		write_block = proc "contextless" (ops: ^Ops, bytes: ^Block) -> (format.Pointer, bool) {
			d := (^Test_Disk)(ops.data)
			blk := disk_commit_alloc(d, u16(d.active_store + 1))
			if blk == 0 {
				return {}, false
			}
			d.blocks[blk] = bytes^
			d.used_delta += 1
			return {block = blk, check = format.check(bytes[:])}, true
		},
		count_after = proc "contextless" (ops: ^Ops, number: u64) -> i64 {
			d := (^Test_Disk)(ops.data)
			if number >= TEST_DISK_BLOCKS {
				return 0
			}
			return i64(d.refs[number]) + d.deltas[number]
		},
		drop = proc "contextless" (ops: ^Ops, number: u64) {
			d := (^Test_Disk)(ops.data)
			if number < 2 || number >= TEST_DISK_BLOCKS {
				return
			}
			before := i64(d.refs[number]) + d.deltas[number]
			d.deltas[number] -= 1
			if before == 1 {
				d.used_delta -= 1
			}
		},
		wrong_block = proc "contextless" (ops: ^Ops, number: u64) -> bool {
			d := (^Test_Disk)(ops.data)
			return number < TEST_DISK_BLOCKS && d.wrong[number]
		},
		mark_wrong = proc "contextless" (ops: ^Ops, number: u64) {
			d := (^Test_Disk)(ops.data)
			if number < TEST_DISK_BLOCKS {
				d.wrong[number] = true
			}
		},
		note_damaged = proc "contextless" (ops: ^Ops, damaged_nodes: u64, damaged_blocks: u64) {
			d := (^Test_Disk)(ops.data)
			_ = damaged_blocks
			d.damaged_hits += damaged_nodes
		},
		enqueue_release = proc "contextless" (ops: ^Ops, root: format.Pointer, size: u64) -> bool {
			d := (^Test_Disk)(ops.data)
			if d.queued_count >= len(d.queued) {
				return false
			}
			d.queued[d.queued_count] = {root = root, size = size}
			d.queued_count += 1
			return true
		},
		release_step = proc "contextless" (ops: ^Ops, list: ^format.Release_List) -> (empty: bool, device: bool) {
			d := (^Test_Disk)(ops.data)
			rel := storage_release.Releaser{
				count_after = proc "contextless" (r: ^storage_release.Releaser, number: u64) -> i64 {
					d := (^Test_Disk)(r.data)
					return i64(d.refs[number]) + d.deltas[number]
				},
				drop = proc "contextless" (r: ^storage_release.Releaser, number: u64) {
					d := (^Test_Disk)(r.data)
					before := i64(d.refs[number]) + d.deltas[number]
					d.deltas[number] -= 1
					if before == 1 {
						d.used_delta -= 1
					}
				},
				drop_whole = proc "contextless" (r: ^storage_release.Releaser, child: format.Object_Child, level: int) {
					d := (^Test_Disk)(r.data)
					before := i64(d.refs[child.block]) + d.deltas[child.block]
					d.deltas[child.block] -= 1
					if before == 1 {
						d.used_delta -= 1
					}
					if level > 0 && before == 1 {
						node := (^format.Object_Node)(&d.blocks[child.block])^
						for c in node.children {
							if c.block != 0 {
								r.drop_whole(r, c, level - 1)
							}
						}
					}
				},
				read_node = proc "contextless" (r: ^storage_release.Releaser, child: format.Object_Child, level: int, into: ^format.Object_Node) -> storage_release.Read {
					d := (^Test_Disk)(r.data)
					if child.block < 2 || child.block >= TEST_DISK_BLOCKS || d.wrong[child.block] {
						return .Wrong
					}
					into^ = (^format.Object_Node)(&d.blocks[child.block])^
					if format.check((^Block)(into)[:]) != child.check || into.header.magic != format.OBJECT_NODE_MAGIC || int(into.header.level) != level {
						d.wrong[child.block] = true
						return .Wrong
					}
					return .Good
				},
				data = d,
			}
			storage_release.step_begin(&rel, 2)
			freed := 0
			for freed < int(list.count) {
				st := &list.states[freed]
				if !storage_release.step_state(&rel, st.root, st.size, &st.cursor) {
					break
				}
				freed += 1
			}
			d.damaged_hits += rel.damaged
			left := int(list.count) - freed
			copy(list.states[:left], list.states[freed:list.count])
			for &st in list.states[left:list.count] {
				st = {}
			}
			list.count = u32(left)
			return left == 0, rel.device
		},
		direct_blocks_limit = direct_limit,
		data = d,
	}
}

// ---------------------------------------------------------------------
// Helper to populate a real sealed encrypted store (nested tree, 1-block
// object, 3-block object with shared data block + versions, and a sealed
// Release_List) plus a clear principal-0 store.

@(private = "file")
add_clear_machine_store :: proc(d: ^Test_Disk, slot: int, name: string) {
	owner := u16(slot + 1)
	data_blk := disk_alloc_raw(d, owner)
	for &b, i in d.blocks[data_blk] {
		b = u8(0x31 + (i % 19))
	}
	dv := block_tree.block_value(&d.blocks[data_blk], 0)
	leaf_blk := disk_alloc_raw(d, owner)
	leaf := &d.blocks[leaf_blk]
	(^format.Tree_Header)(leaf)^ = {level = 0, count = 1, magic = format.NODE_MAGIC}
	copy(leaf[format.TREE_HEADER_SIZE:][:format.ENTRY_NAME_STORAGE], "machine_obj")
	entry := (^format.Entry)(&leaf[format.TREE_HEADER_SIZE + format.ENTRY_NAME_STORAGE])
	entry^ = {
		kind    = u64(format.Entry_Kind.Object),
		size    = format.BLOCK_SIZE,
		pointer = {block = data_blk, check = format.value_check(dv)},
	}
	sb_blk := disk_alloc_raw(d, owner)
	sb := (^format.Store_Block)(&d.blocks[sb_blk])
	sb^ = {
		tree           = {block = leaf_blk, check = format.check(leaf[:])},
		objects        = 1,
		current_blocks = 1,
		node_blocks    = 1,
	}
	cell := &d.store_page.cells[slot]
	cell^ = {
		limit = 64,
		used  = 3,
		store = {block = sb_blk, check = format.check(d.blocks[sb_blk][:])},
	}
	copy(cell.name[:], name)
	// Commit page + root.
	old_page := d.root.store_pages[0].block
	d.refs[old_page] = 0
	d.owners[old_page] = 0
	new_page := disk_alloc_raw(d, storage_mount.STORE_TABLE_OWNER)
	d.blocks[new_page] = ((^Block)(&d.store_page))^
	d.root.store_pages[0] = {block = new_page, check = format.check(d.blocks[new_page][:])}
	d.root.generation += 1
	d.root.check = format.root_check(&d.root)
	d.root_place = 1 - d.root_place
	d.blocks[d.root_place] = ((^Block)(&d.root))^
}

@(private = "file")
add_encrypted_principal_store :: proc(t: ^testing.T, d: ^Test_Disk, slot: int, principal_id: principals.Principal_Identifier, salt_seed: u8) {
	owner := u16(slot + 1)
	skey := store_encryption.Key{0 = 0x55, 1 = salt_seed, 31 = 0xAA}
	salt := [format.OWNER_FIELD_SIZE]u8{0 = salt_seed, 31 = 0x99}
	keys, ok := store_encryption.store_keys_of(skey, principal_id, salt)
	testing.expect(t, ok)

	// 1. Shared encrypted data block referenced by BOTH a nested object and a version!
	shared_data_blk := disk_alloc_raw(d, owner)
	shared_plain: Block
	for &b, i in shared_plain {
		b = u8(0x61 + (i % 23))
	}
	shared_val := block_tree.block_value(&shared_plain, 0)
	shared_dc := format.value_check(shared_val)
	d.blocks[shared_data_blk] = shared_plain
	shared_check := store_encryption.data_block_encrypt(&keys, shared_data_blk, shared_dc, &d.blocks[shared_data_blk])

	// 2. Second unique encrypted data block for a 2-block object.
	data2_blk := disk_alloc_raw(d, owner)
	plain2: Block
	for &b, i in plain2 {
		b = u8(0x71 + (i % 17))
	}
	val2 := block_tree.block_value(&plain2, 1)
	dc2 := format.value_check(val2)
	d.blocks[data2_blk] = plain2
	check2 := store_encryption.data_block_encrypt(&keys, data2_blk, dc2, &d.blocks[data2_blk])

	// 3. Sealed Object_Node (level 1, 2 children: shared_data_blk + data2_blk).
	obj_node_blk := disk_alloc_raw(d, owner)
	obj_node: format.Object_Node
	obj_node.header = {level = 1, count = 2, magic = format.OBJECT_NODE_MAGIC}
	obj_node.children[0] = {block = shared_data_blk, check = shared_check, blocks = 1, value = shared_val}
	obj_node.children[1] = {block = data2_blk, check = check2, blocks = 1, value = val2}
	obj_node_check, on_ok := store_encryption.object_node_seal(&keys, obj_node_blk, &obj_node)
	testing.expect(t, on_ok)
	d.blocks[obj_node_blk] = ((^Block)(&obj_node))^

	// 4. Sealed Version_Leaf & Version_Index holding 1 version pointing to shared_data_blk (refcount 2!).
	d.refs[shared_data_blk] += 1
	vl_blk := disk_alloc_raw(d, owner)
	vl: format.Version_Leaf
	vl.count = 1
	vl.entries[0] = {
		size       = format.BLOCK_SIZE,
		root       = {block = shared_data_blk, check = shared_check},
		generation = 1,
		data_check = shared_dc,
	}
	vl_check, vl_ok := store_encryption.version_leaf_seal(&keys, vl_blk, &vl)
	testing.expect(t, vl_ok)
	d.blocks[vl_blk] = ((^Block)(&vl))^

	vi_blk := disk_alloc_raw(d, owner)
	vi: format.Version_Index
	vi.leaf_count = 1
	vi.leaves[0] = {block = vl_blk, check = vl_check}
	vi_check, vi_ok := store_encryption.version_index_seal(&keys, vi_blk, &vi)
	testing.expect(t, vi_ok)
	d.blocks[vi_blk] = ((^Block)(&vi))^

	// 5. Nested subtree leaf holding 1 object (1-block encrypted object sharing shared_data_blk -> refcount 3!).
	d.refs[shared_data_blk] += 1
	nested_leaf_blk := disk_alloc_raw(d, owner)
	nested_leaf: Block
	(^format.Tree_Header)(&nested_leaf)^ = {level = 0, count = 1, magic = format.NODE_MAGIC}
	copy(nested_leaf[format.TREE_HEADER_SIZE:][:format.ENTRY_NAME_STORAGE], "child_obj")
	(^format.Entry)(&nested_leaf[format.TREE_HEADER_SIZE + format.ENTRY_NAME_STORAGE])^ = {
		kind       = u64(format.Entry_Kind.Object),
		size       = format.BLOCK_SIZE,
		generation = 2,
		data_check = shared_dc,
		pointer    = {block = shared_data_blk, check = shared_check},
	}
	nested_check, nl_ok := store_encryption.tree_node_seal(&keys, nested_leaf_blk, &nested_leaf)
	testing.expect(t, nl_ok)
	d.blocks[nested_leaf_blk] = nested_leaf

	// 6. Top tree leaf holding 2 entries: entry 0 = nested subtree, entry 1 = 2-block versioned object.
	top_leaf_blk := disk_alloc_raw(d, owner)
	top_leaf: Block
	(^format.Tree_Header)(&top_leaf)^ = {level = 0, count = 2, magic = format.NODE_MAGIC}
	stride := format.ENTRY_NAME_STORAGE + size_of(format.Entry)
	copy(top_leaf[format.TREE_HEADER_SIZE:][:format.ENTRY_NAME_STORAGE], "a_sub")
	(^format.Entry)(&top_leaf[format.TREE_HEADER_SIZE + format.ENTRY_NAME_STORAGE])^ = {
		kind    = u64(format.Entry_Kind.Tree),
		size    = 1,
		pointer = {block = nested_leaf_blk, check = nested_check},
	}
	copy(top_leaf[format.TREE_HEADER_SIZE + stride:][:format.ENTRY_NAME_STORAGE], "b_big")
	(^format.Entry)(&top_leaf[format.TREE_HEADER_SIZE + stride + format.ENTRY_NAME_STORAGE])^ = {
		kind       = u64(format.Entry_Kind.Object),
		size       = 2 * format.BLOCK_SIZE,
		generation = 2,
		pointer    = {block = obj_node_blk, check = obj_node_check},
		versions   = {block = vi_blk, check = vi_check},
	}
	top_check, tl_ok := store_encryption.tree_node_seal(&keys, top_leaf_blk, &top_leaf)
	testing.expect(t, tl_ok)
	d.blocks[top_leaf_blk] = top_leaf

	// 7. Existing sealed Release_List in sb.removals holding 1 queued data block.
	queued_data_blk := disk_alloc_raw(d, owner)
	qplain: Block
	qplain[0] = 0xCC
	qdc := format.value_check(block_tree.block_value(&qplain, 0))
	d.blocks[queued_data_blk] = qplain
	qcheck := store_encryption.data_block_encrypt(&keys, queued_data_blk, qdc, &d.blocks[queued_data_blk])

	rl_blk := disk_alloc_raw(d, owner)
	rl: format.Release_List
	rl.magic = format.RELEASE_LIST_MAGIC
	rl.count = 1
	rl.states[0] = {root = {block = queued_data_blk, check = qcheck}, size = format.BLOCK_SIZE}
	rl_check, rl_ok := store_encryption.release_list_seal(&keys, rl_blk, &rl)
	testing.expect(t, rl_ok)
	d.blocks[rl_blk] = ((^Block)(&rl))^

	rem_leaf_blk := disk_alloc_raw(d, owner)
	rem_leaf: Block
	(^format.Tree_Header)(&rem_leaf)^ = {level = 0, count = 1, magic = format.NODE_MAGIC}
	rkey := format.removal_name(1)
	copy(rem_leaf[format.TREE_HEADER_SIZE:][:format.ENTRY_NAME_STORAGE], rkey[:])
	(^format.Entry)(&rem_leaf[format.TREE_HEADER_SIZE + format.ENTRY_NAME_STORAGE])^ = {
		kind    = u64(format.Entry_Kind.Release),
		pointer = {block = rl_blk, check = rl_check},
	}
	rem_check, rem_ok := store_encryption.tree_node_seal(&keys, rem_leaf_blk, &rem_leaf)
	testing.expect(t, rem_ok)
	d.blocks[rem_leaf_blk] = rem_leaf

	// 8. Sealed Store_Block.
	// Distinct blocks in this store:
	// sb + top_leaf + nested_leaf + obj_node + shared_data + data2 + vi + vl + rem_leaf + rl + queued_data = 11.
	sb_blk := disk_alloc_raw(d, owner)
	sb: format.Store_Block
	sb.tree = {block = top_leaf_blk, check = top_check}
	sb.removals = {block = rem_leaf_blk, check = rem_check}
	sb.next_removal = 1
	sb.objects = 2
	sb.trees = 1
	sb.current_blocks = 1 + 3 // 1 for nested 1-block object + 3 for 2-block object (node + 2 data)
	sb.node_blocks = 3 // top_leaf + nested_leaf + rem_leaf
	sb.removing = 1
	sb.owner = principal_id
	sb.salt = salt
	sb.key_check = keys.check
	sb.store_generation = d.root.generation + 1
	sb_check, sb_ok := store_encryption.store_block_seal(&keys, sb_blk, &sb)
	testing.expect(t, sb_ok)
	d.blocks[sb_blk] = ((^Block)(&sb))^

	cell := &d.store_page.cells[slot]
	cell^ = {
		limit = 128,
		used  = 11,
		store = {block = sb_blk, check = sb_check},
	}
	cell.name[0] = format.OWNED_CELL_MARK
	cell.name[1] = salt_seed
	cell.name[31] = 0xEE

	old_page := d.root.store_pages[0].block
	d.refs[old_page] = 0
	d.owners[old_page] = 0
	new_page := disk_alloc_raw(d, storage_mount.STORE_TABLE_OWNER)
	d.blocks[new_page] = ((^Block)(&d.store_page))^
	d.root.store_pages[0] = {block = new_page, check = format.check(d.blocks[new_page][:])}
	d.root.generation += 1
	d.root.check = format.root_check(&d.root)
	d.root_place = 1 - d.root_place
	d.blocks[d.root_place] = ((^Block)(&d.root))^
}

@(private = "file")
run_mark_and_reclaim :: proc(t: ^testing.T, d: ^Test_Disk, store_index: int, direct_limit := 0, expect_clean_mount := true) -> int {
	// Step 0: Mark store reclaiming and scrub identifying metadata.
	disk_commit_begin(d, store_index)
	sb := (^format.Store_Block)(&d.blocks[d.store_page.cells[store_index].store.block])^
	scrub_store_cell_and_block(&d.store_page.cells[store_index], &sb)
	// Verify scrubbed fields immediately.
	testing.expect_value(t, d.store_page.cells[store_index].name[0], format.RECLAIMING_CELL_MARK)
	for b in d.store_page.cells[store_index].name[1:] {
		testing.expect_value(t, b, u8(0))
	}
	testing.expect(t, sb.owner == {})
	testing.expect(t, sb.salt == {})
	testing.expect(t, sb.key_check == {})
	testing.expect(t, sb.name_sealed == {})
	testing.expect_value(t, sb.store_generation, u64(0))
	testing.expect(t, sb.mac == {})
	disk_commit_apply(d, store_index, &sb, false)
	disk_verify_mount(t, d, expect_clean_mount)

	work := new(Work)
	defer free(work)
	ops := ops_make(d, direct_limit)

	steps := 0
	for steps < 64 {
		steps += 1
		disk_commit_begin(d, store_index)
		cur_sb := (^format.Store_Block)(&d.blocks[d.store_page.cells[store_index].store.block])^
		res := step(&ops, work, &cur_sb, 1) // entry_limit = 1 forces multi-commit stepping + crash points!
		if res == .Empty {
			disk_commit_apply(d, store_index, &cur_sb, true)
			disk_verify_mount(t, d, expect_clean_mount)
			return steps
		}
		testing.expect_value(t, res, Step_Outcome.Progressed)
		// If any large state was deferred, write a clear Release_List and prepend to sb.removals.
		if d.queued_count > 0 {
			rl: format.Release_List = {magic = format.RELEASE_LIST_MAGIC, count = u32(d.queued_count)}
			for i in 0 ..< d.queued_count {
				rl.states[i] = d.queued[i]
			}
			rl_ptr, ok := ops.write_block(&ops, (^Block)(&rl))
			testing.expect(t, ok)
			prep := prepend_release_entry(&ops, work, &cur_sb, rl_ptr)
			testing.expect_value(t, prep, Step_Outcome.Progressed)
		}
		disk_commit_apply(d, store_index, &cur_sb, false)
		// Verify storage_mount validates EVERY SINGLE INTERMEDIATE COMMIT (simulating crash/reboot at every commit!).
		disk_verify_mount(t, d, expect_clean_mount)
	}
	testing.expect(t, false, "reclamation did not finish within step bound")
	return steps
}

// Reclaiming a complex encrypted store (nested tree, 1-block & multi-block
// objects, shared/deduplicated blocks across current & versions, existing
// sealed Release_List) leaves zero leaked blocks, frees the cell for reuse,
// passes storage_mount after every single intermediate commit (crash-resume),
// and never touches principal-0 or sibling principal stores.
@(test)
keyless_reclaim_frees_all_blocks_and_preserves_live_stores :: proc(t: ^testing.T) {
	d := new(Test_Disk)
	defer free(d)
	test_disk_init(d)

	// Principal 0 clear store at cell 0, live sibling principal B at cell 2.
	id_a := principals.Principal_Identifier{0 = 0xAA, 31 = 0x11}
	id_b := principals.Principal_Identifier{0 = 0xBB, 31 = 0x22}
	add_clear_machine_store(d, 0, "machine")
	add_encrypted_principal_store(t, d, 2, id_b, 0x22)
	disk_verify_mount(t, d, true)
	baseline_blocks := disk_blocks_in_use(d)

	// Multi-cycle zero-leak test: create -> populate -> reclaim across 4 cycles,
	// including a cycle with direct_limit = 1 forcing large-state Release_List deferral.
	for cycle in 0 ..< 4 {
		direct_lim := cycle == 2 ? 1 : 0
		add_encrypted_principal_store(t, d, 1, id_a, u8(0x30 + cycle))
		disk_verify_mount(t, d, true)
		testing.expect(t, disk_blocks_in_use(d) == baseline_blocks + 11)

		steps := run_mark_and_reclaim(t, d, 1, direct_lim, true)
		testing.expect(t, steps >= 4, "multi-step reclamation must step incrementally")
		testing.expect_value(t, disk_blocks_in_use(d), baseline_blocks)
		testing.expect_value(t, d.store_page.cells[1].name[0], u8(0))
		testing.expect_value(t, d.store_page.cells[1].used, u64(0))
		// Live machine store (cell 0) and sibling principal B store (cell 2) stay untouched!
		testing.expect_value(t, d.store_page.cells[0].used, u64(3))
		testing.expect_value(t, d.store_page.cells[2].used, u64(11))
		testing.expect_value(t, d.store_page.cells[2].name[0], format.OWNED_CELL_MARK)
	}
}

// Damaged metadata inside a reclaiming store is pruned cleanly with damage
// noted (for recount) without stalling reclamation or affecting live stores.
@(test)
keyless_reclaim_prunes_corrupt_nodes_without_stalling :: proc(t: ^testing.T) {
	d := new(Test_Disk)
	defer free(d)
	test_disk_init(d)

	id_a := principals.Principal_Identifier{0 = 0xCC, 31 = 0x33}
	add_clear_machine_store(d, 0, "machine")
	add_encrypted_principal_store(t, d, 1, id_a, 0x44)
	disk_verify_mount(t, d, true)

	// Corrupt the queued Release_List block on disk inside store 1!
	sb := (^format.Store_Block)(&d.blocks[d.store_page.cells[1].store.block])^
	rem_leaf := d.blocks[sb.removals.block]
	rl_ptr := (^format.Entry)(&rem_leaf[format.TREE_HEADER_SIZE + format.ENTRY_NAME_STORAGE]).pointer
	d.blocks[rl_ptr.block][0] ~= 0xFF

	steps := run_mark_and_reclaim(t, d, 1, 0, false)
	testing.expect(t, steps >= 2)
	testing.expect(t, d.damaged_hits > 0, "corrupt block must report damage for recount")
	testing.expect_value(t, d.store_page.cells[1].name[0], u8(0))
	testing.expect_value(t, d.store_page.cells[0].used, u64(3))
}
