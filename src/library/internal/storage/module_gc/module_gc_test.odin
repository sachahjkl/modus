#+build !freestanding
package module_gc

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/tree_hash"

// In-memory store for adversarial host tests of module_gc.
STORE_CAPACITY :: 256
EXTRA_REF_CAPACITY :: 64

Mock_Object :: struct {
	used:      bool,
	too_large: bool,
	hash:      blake3.Hash,
	len:       int,
	data:      [tree_hash.MAX_ENCODED_TREE_BYTES]u8,
}

Mock_Extra_Ref :: struct {
	from: blake3.Hash,
	to:   blake3.Hash,
}

Mock_Store :: struct {
	objects:       [STORE_CAPACITY]Mock_Object,
	object_count:  int,
	extra_refs:    [EXTRA_REF_CAPACITY]Mock_Extra_Ref,
	extra_count:   int,
	deleted_count: int,
	fail_device:   bool,
	reader:        Object_Reader,
	collector:     Collector_State,
}

mock_store_make :: proc() -> ^Mock_Store {
	store := new(Mock_Store)
	store.reader = {
		read_object     = mock_read_object,
		read_references = mock_read_references,
		data            = store,
	}
	return store
}

mock_find :: proc "contextless" (store: ^Mock_Store, hash: blake3.Hash) -> int {
	for index in 0 ..< store.object_count {
		if store.objects[index].used && store.objects[index].hash == hash {
			return index
		}
	}
	return -1
}

mock_read_object :: proc "contextless" (reader: ^Object_Reader, hash: blake3.Hash, buffer: []u8) -> (int, Read_Status) {
	store := (^Mock_Store)(reader.data)
	if store.fail_device {
		return 0, .Device_Error
	}
	idx := mock_find(store, hash)
	if idx < 0 {
		return 0, .Absent
	}
	obj := &store.objects[idx]
	if obj.too_large {
		return 0, .Too_Large
	}
	if obj.len > len(buffer) {
		return 0, .Too_Large
	}
	copy(buffer[:obj.len], obj.data[:obj.len])
	return obj.len, .Found
}

mock_read_references :: proc "contextless" (reader: ^Object_Reader, hash: blake3.Hash, out: []blake3.Hash) -> (int, Reference_Status) {
	store := (^Mock_Store)(reader.data)
	count := 0
	for ref in store.extra_refs[:store.extra_count] {
		if ref.from == hash && count < len(out) {
			out[count] = ref.to
			count += 1
		}
	}
	return count, .Ok
}

mock_delete :: proc "contextless" (user_data: rawptr, hash: blake3.Hash) -> bool {
	store := (^Mock_Store)(user_data)
	idx := mock_find(store, hash)
	if idx < 0 {
		return false
	}
	store.objects[idx].used = false
	store.deleted_count += 1
	return true
}

mock_put_blob :: proc(store: ^Mock_Store, bytes: []u8) -> blake3.Hash {
	h := blake3.hash(bytes)
	return mock_put_raw(store, h, bytes)
}

mock_put_raw :: proc(store: ^Mock_Store, key_hash: blake3.Hash, bytes: []u8, too_large := false) -> blake3.Hash {
	idx := mock_find(store, key_hash)
	if idx < 0 {
		idx = store.object_count
		store.object_count += 1
	}
	obj := &store.objects[idx]
	obj.used = true
	obj.too_large = too_large
	obj.hash = key_hash
	obj.len = len(bytes)
	copy(obj.data[:len(bytes)], bytes)
	return key_hash
}

mock_put_tree :: proc(store: ^Mock_Store, entries: []tree_hash.Tree_Entry) -> blake3.Hash {
	buf: [tree_hash.MAX_ENCODED_TREE_BYTES]u8
	written, ref := tree_hash.tree_encode(entries, buf[:])
	assert(ref == .None)
	h, href := tree_hash.tree_hash(buf[:written])
	assert(href == .None)
	return mock_put_raw(store, h, buf[:written])
}

mock_add_extra_ref :: proc(store: ^Mock_Store, from, to: blake3.Hash) {
	store.extra_refs[store.extra_count] = {from = from, to = to}
	store.extra_count += 1
}

mock_all_hashes :: proc(store: ^Mock_Store, allocator := context.temp_allocator) -> []blake3.Hash {
	list := make([dynamic]blake3.Hash, 0, store.object_count, allocator)
	for index in 0 ..< store.object_count {
		if store.objects[index].used {
			append(&list, store.objects[index].hash)
		}
	}
	return list[:]
}

@(test)
empty_store_collects_nothing :: proc(t: ^testing.T) {
	store := mock_store_make()
	defer free(store)

	sweep: [16]blake3.Hash
	result, deleted := collect_and_sweep(&store.collector, nil, nil, &store.reader, sweep[:], mock_delete, store)
	testing.expect_value(t, result.status, Collect_Status.Ok)
	testing.expect_value(t, result.marked_count, 0)
	testing.expect_value(t, result.sweep_count, 0)
	testing.expect_value(t, deleted, 0)
}

@(test)
all_reachable_and_none_reachable :: proc(t: ^testing.T) {
	store := mock_store_make()
	defer free(store)

	h1 := mock_put_blob(store, transmute([]u8)string("module-one"))
	h2 := mock_put_blob(store, transmute([]u8)string("module-two"))
	e1, _ := tree_hash.tree_entry_make(.Object, "one", h1)
	e2, _ := tree_hash.tree_entry_make(.Object, "two", h2)
	t_root := mock_put_tree(store, []tree_hash.Tree_Entry{e1, e2})

	all := mock_all_hashes(store)
	sweep: [16]blake3.Hash

	// All reachable via Pinned_Tree -> 0 swept, 0 deleted.
	roots := [1]Root{{kind = .Pinned_Tree, hash = t_root}}
	res_all, del_all := collect_and_sweep(&store.collector, roots[:], all, &store.reader, sweep[:], mock_delete, store)
	testing.expect_value(t, res_all.status, Collect_Status.Ok)
	testing.expect_value(t, res_all.marked_count, 3)
	testing.expect_value(t, res_all.sweep_count, 0)
	testing.expect_value(t, del_all, 0)

	// None reachable (empty root set) -> all 3 objects swept and deleted.
	res_none, del_none := collect_and_sweep(&store.collector, nil, all, &store.reader, sweep[:], mock_delete, store)
	testing.expect_value(t, res_none.status, Collect_Status.Ok)
	testing.expect_value(t, res_none.marked_count, 0)
	testing.expect_value(t, res_none.sweep_count, 3)
	testing.expect_value(t, del_none, 3)
	testing.expect_value(t, store.deleted_count, 3)
}

@(test)
diamond_dag_shared_subtree_preserved :: proc(t: ^testing.T) {
	store := mock_store_make()
	defer free(store)

	// Diamond DAG:
	//        root
	//       /    \
	//    left    right
	//       \    /
	//       shared
	//         |
	//        leaf
	// Plus an unreachable orphan.
	leaf := mock_put_blob(store, transmute([]u8)string("shared-leaf-bytes"))
	orphan := mock_put_blob(store, transmute([]u8)string("dead-garbage"))

	e_leaf, _ := tree_hash.tree_entry_make(.Object, "leaf", leaf)
	shared := mock_put_tree(store, []tree_hash.Tree_Entry{e_leaf})

	e_shared_l, _ := tree_hash.tree_entry_make(.Tree, "sub", shared)
	left := mock_put_tree(store, []tree_hash.Tree_Entry{e_shared_l})

	e_shared_r, _ := tree_hash.tree_entry_make(.Tree, "alias", shared)
	right := mock_put_tree(store, []tree_hash.Tree_Entry{e_shared_r})

	e_left, _ := tree_hash.tree_entry_make(.Tree, "left", left)
	e_right, _ := tree_hash.tree_entry_make(.Tree, "right", right)
	root := mock_put_tree(store, []tree_hash.Tree_Entry{e_left, e_right})

	all := mock_all_hashes(store)
	roots := [1]Root{{kind = .Pinned_Tree, hash = root}}
	sweep: [16]blake3.Hash

	result, deleted := collect_and_sweep(&store.collector, roots[:], all, &store.reader, sweep[:], mock_delete, store)
	testing.expect_value(t, result.status, Collect_Status.Ok)
	testing.expect_value(t, result.marked_count, 5) // root, left, right, shared, leaf
	// shared is traversed once (not duplicated) -> 4 distinct trees traversed.
	testing.expect_value(t, result.trees_traversed, 4)
	testing.expect_value(t, result.sweep_count, 1)
	testing.expect_value(t, sweep[0], orphan)
	testing.expect_value(t, deleted, 1)
	testing.expect(t, mock_find(store, orphan) < 0)
	testing.expect(t, mock_find(store, leaf) >= 0)
	testing.expect(t, mock_find(store, shared) >= 0)
}

@(test)
deep_tree_at_depth_bound_and_one_past_bound :: proc(t: ^testing.T) {
	store := mock_store_make()
	defer free(store)

	// Build a valid chain of depth MAX_TRAVERSAL_DEPTH (32):
	// T_0 (depth 0) -> T_1 -> ... -> T_32 (depth 32, holds leaf object).
	leaf := mock_put_blob(store, transmute([]u8)string("deep-leaf"))
	orphan := mock_put_blob(store, transmute([]u8)string("deep-orphan"))

	e_leaf, _ := tree_hash.tree_entry_make(.Object, "leaf", leaf)
	current := mock_put_tree(store, []tree_hash.Tree_Entry{e_leaf}) // depth 32
	for _ in 0 ..< MAX_TRAVERSAL_DEPTH {
		e_child, _ := tree_hash.tree_entry_make(.Tree, "next", current)
		current = mock_put_tree(store, []tree_hash.Tree_Entry{e_child})
	}
	root_at_bound := current

	// Exact bound (depth 32): succeeds and sweeps only orphan.
	all_at_bound := mock_all_hashes(store)
	sweep: [16]blake3.Hash
	roots_at_bound := [1]Root{{kind = .Pinned_Tree, hash = root_at_bound}}
	res_ok := collect(&store.collector, roots_at_bound[:], all_at_bound, &store.reader, sweep[:])
	testing.expect_value(t, res_ok.status, Collect_Status.Ok)
	testing.expect_value(t, res_ok.max_depth_seen, MAX_TRAVERSAL_DEPTH)
	testing.expect_value(t, res_ok.sweep_count, 1)
	testing.expect_value(t, sweep[0], orphan)

	// One past bound (depth 33): wrap root_at_bound one more time -> refused with Depth_Exceeded and ZERO deletions!
	e_wrap, _ := tree_hash.tree_entry_make(.Tree, "too_deep", root_at_bound)
	root_past_bound := mock_put_tree(store, []tree_hash.Tree_Entry{e_wrap})
	all_past_bound := mock_all_hashes(store)
	roots_past_bound := [1]Root{{kind = .Pinned_Tree, hash = root_past_bound}}
	res_over, deleted_over := collect_and_sweep(&store.collector, roots_past_bound[:], all_past_bound, &store.reader, sweep[:], mock_delete, store)
	testing.expect_value(t, res_over.status, Collect_Status.Depth_Exceeded)
	testing.expect_value(t, res_over.sweep_count, 0)
	testing.expect_value(t, deleted_over, 0)
	testing.expect(t, mock_find(store, orphan) >= 0) // Nothing deleted!
}

@(test)
corrupt_cyclic_and_missing_trees_refused_with_zero_deletions :: proc(t: ^testing.T) {
	store := mock_store_make()
	defer free(store)

	orphan := mock_put_blob(store, transmute([]u8)string("must-not-delete-on-error"))
	sweep: [16]blake3.Hash

	// 1. Corrupt tree bytes stored under a Pinned_Tree hash -> Corrupt_Tree, 0 deletions.
	fake_tree_hash := blake3.hash(transmute([]u8)string("fake-tree-id"))
	mock_put_raw(store, fake_tree_hash, transmute([]u8)string("not a valid tree node"))
	all := mock_all_hashes(store)
	roots_corrupt := [1]Root{{kind = .Pinned_Tree, hash = fake_tree_hash}}
	res_corrupt, del_corrupt := collect_and_sweep(&store.collector, roots_corrupt[:], all, &store.reader, sweep[:], mock_delete, store)
	testing.expect_value(t, res_corrupt.status, Collect_Status.Corrupt_Tree)
	testing.expect_value(t, res_corrupt.sweep_count, 0)
	testing.expect_value(t, del_corrupt, 0)
	testing.expect(t, mock_find(store, orphan) >= 0)

	// 2. Self-referential (cyclic) tree payload stored under its own key -> refused, 0 deletions.
	cycle_hash := blake3.hash(transmute([]u8)string("cycle-node"))
	cycle_entry, _ := tree_hash.tree_entry_make(.Tree, "self", cycle_hash)
	cycle_buf: [tree_hash.HEADER_SIZE + tree_hash.ENTRY_SIZE]u8
	cycle_len, _ := tree_hash.tree_encode([]tree_hash.Tree_Entry{cycle_entry}, cycle_buf[:])
	mock_put_raw(store, cycle_hash, cycle_buf[:cycle_len])
	roots_cycle := [1]Root{{kind = .Pinned_Tree, hash = cycle_hash}}
	res_cycle, del_cycle := collect_and_sweep(&store.collector, roots_cycle[:], mock_all_hashes(store), &store.reader, sweep[:], mock_delete, store)
	testing.expect(t, res_cycle.status == .Corrupt_Tree || res_cycle.status == .Cycle_Detected)
	testing.expect_value(t, res_cycle.sweep_count, 0)
	testing.expect_value(t, del_cycle, 0)
	testing.expect(t, mock_find(store, orphan) >= 0)

	// 3. Missing Pinned_Tree root -> Missing_Root, 0 deletions.
	missing_tree := blake3.hash(transmute([]u8)string("absent-root-tree"))
	roots_missing := [1]Root{{kind = .Pinned_Tree, hash = missing_tree}}
	res_missing, del_missing := collect_and_sweep(&store.collector, roots_missing[:], mock_all_hashes(store), &store.reader, sweep[:], mock_delete, store)
	testing.expect_value(t, res_missing.status, Collect_Status.Missing_Root)
	testing.expect_value(t, res_missing.sweep_count, 0)
	testing.expect_value(t, del_missing, 0)

	// 4. Valid outer tree pointing to a missing inner child tree -> Missing_Tree, 0 deletions.
	e_missing_child, _ := tree_hash.tree_entry_make(.Tree, "gone", missing_tree)
	outer_tree := mock_put_tree(store, []tree_hash.Tree_Entry{e_missing_child})
	roots_outer := [1]Root{{kind = .Pinned_Tree, hash = outer_tree}}
	res_child_missing, del_child_missing := collect_and_sweep(&store.collector, roots_outer[:], mock_all_hashes(store), &store.reader, sweep[:], mock_delete, store)
	testing.expect_value(t, res_child_missing.status, Collect_Status.Missing_Tree)
	testing.expect_value(t, res_child_missing.sweep_count, 0)
	testing.expect_value(t, del_child_missing, 0)

	// 5. Corrupt Disk_Grant_Module root (bytes do not hash to root hash) -> Corrupt_Root, 0 deletions.
	tampered_mod_hash := blake3.hash(transmute([]u8)string("expected-module"))
	mock_put_raw(store, tampered_mod_hash, transmute([]u8)string("tampered-bytes"))
	roots_tampered := [1]Root{{kind = .Disk_Grant_Module, hash = tampered_mod_hash}}
	res_tampered, del_tampered := collect_and_sweep(&store.collector, roots_tampered[:], mock_all_hashes(store), &store.reader, sweep[:], mock_delete, store)
	testing.expect_value(t, res_tampered.status, Collect_Status.Corrupt_Root)
	testing.expect_value(t, res_tampered.sweep_count, 0)
	testing.expect_value(t, del_tampered, 0)
	testing.expect(t, mock_find(store, orphan) >= 0)
}

@(test)
invalid_root_kind_and_zero_hash_refused :: proc(t: ^testing.T) {
	store := mock_store_make()
	defer free(store)

	orphan := mock_put_blob(store, transmute([]u8)string("orphan"))
	all := mock_all_hashes(store)
	sweep: [16]blake3.Hash

	// Border root_kind_of_word rejects 0, 5, 255, max(u64).
	for bad_word in ([?]u64{0, 5, 255, max(u64)}) {
		_, ok := root_kind_of_word(bad_word)
		testing.expect(t, !ok)
	}

	// Bad Root_Kind in roots slice -> Bad_Root_Kind, 0 deletions.
	bad_roots := [1]Root{{kind = Root_Kind(0), hash = orphan}}
	res_bad, del_bad := collect_and_sweep(&store.collector, bad_roots[:], all, &store.reader, sweep[:], mock_delete, store)
	testing.expect_value(t, res_bad.status, Collect_Status.Bad_Root_Kind)
	testing.expect_value(t, res_bad.sweep_count, 0)
	testing.expect_value(t, del_bad, 0)

	// Zero hash in roots slice -> Zero_Root_Hash, 0 deletions.
	zero_roots := [1]Root{{kind = .Applied_Plan, hash = {}}}
	res_zero, del_zero := collect_and_sweep(&store.collector, zero_roots[:], all, &store.reader, sweep[:], mock_delete, store)
	testing.expect_value(t, res_zero.status, Collect_Status.Zero_Root_Hash)
	testing.expect_value(t, res_zero.sweep_count, 0)
	testing.expect_value(t, del_zero, 0)
	testing.expect(t, mock_find(store, orphan) >= 0)
}

@(test)
active_plan_rollback_plan_disk_grant_and_system_roots_preserved :: proc(t: ^testing.T) {
	store := mock_store_make()
	defer free(store)

	// Signed system module (large non-tree module > 50 KiB in module_files).
	sys_mod := blake3.hash(transmute([]u8)string("signed-system-module"))
	mock_put_raw(store, sys_mod, nil, too_large = true)

	// Active plan tree referencing active_app and shared_lib.
	shared_lib := mock_put_blob(store, transmute([]u8)string("shared-library-module"))
	active_app := mock_put_blob(store, transmute([]u8)string("active-app-v2"))
	e_act, _ := tree_hash.tree_entry_make(.Object, "app", active_app)
	e_lib, _ := tree_hash.tree_entry_make(.Object, "lib", shared_lib)
	active_plan_tree := mock_put_tree(store, []tree_hash.Tree_Entry{e_act, e_lib})

	// Rollback plan tree referencing old_app_v1 and shared_lib.
	old_app_v1 := mock_put_blob(store, transmute([]u8)string("rollback-app-v1"))
	e_old, _ := tree_hash.tree_entry_make(.Object, "app", old_app_v1)
	rollback_plan_tree := mock_put_tree(store, []tree_hash.Tree_Entry{e_old, e_lib})

	// Disk grant module + its imported library + debug object (via extra_references).
	disk_grant_mod := mock_put_blob(store, transmute([]u8)string("disk-granted-tool"))
	disk_grant_dep := mock_put_blob(store, transmute([]u8)string("imported-by-disk-tool"))
	disk_grant_dbg := mock_put_blob(store, transmute([]u8)string("debug-info-of-disk-tool"))
	mock_add_extra_ref(store, disk_grant_mod, disk_grant_dep)
	mock_add_extra_ref(store, disk_grant_mod, disk_grant_dbg)

	// Unreachable garbage: stale build output and abandoned module.
	stale_mod := mock_put_blob(store, transmute([]u8)string("stale-abandoned-v0"))
	e_stale, _ := tree_hash.tree_entry_make(.Object, "old", stale_mod)
	stale_tree := mock_put_tree(store, []tree_hash.Tree_Entry{e_stale})

	roots := [4]Root {
		{kind = .Signed_System_Module, hash = sys_mod},
		{kind = .Applied_Plan, hash = active_plan_tree},
		{kind = .Applied_Plan, hash = rollback_plan_tree},
		{kind = .Disk_Grant_Module, hash = disk_grant_mod},
	}

	all := mock_all_hashes(store)
	sweep: [32]blake3.Hash
	result, deleted := collect_and_sweep(&store.collector, roots[:], all, &store.reader, sweep[:], mock_delete, store)
	testing.expect_value(t, result.status, Collect_Status.Ok)
	testing.expect_value(t, result.sweep_count, 2) // stale_mod and stale_tree only!
	testing.expect_value(t, deleted, 2)

	// Verify every live object survived.
	for live in ([?]blake3.Hash{sys_mod, shared_lib, active_app, active_plan_tree, old_app_v1, rollback_plan_tree, disk_grant_mod, disk_grant_dep, disk_grant_dbg}) {
		testing.expect(t, mock_find(store, live) >= 0)
	}
	// Verify both unreachable objects were deleted.
	testing.expect(t, mock_find(store, stale_mod) < 0)
	testing.expect(t, mock_find(store, stale_tree) < 0)
}

@(test)
device_error_aborts_with_zero_deletions :: proc(t: ^testing.T) {
	store := mock_store_make()
	defer free(store)

	orphan := mock_put_blob(store, transmute([]u8)string("orphan"))
	live := mock_put_blob(store, transmute([]u8)string("live"))
	e, _ := tree_hash.tree_entry_make(.Object, "live", live)
	t_root := mock_put_tree(store, []tree_hash.Tree_Entry{e})

	store.fail_device = true
	roots := [1]Root{{kind = .Pinned_Tree, hash = t_root}}
	sweep: [16]blake3.Hash
	result, deleted := collect_and_sweep(&store.collector, roots[:], mock_all_hashes(store), &store.reader, sweep[:], mock_delete, store)
	testing.expect_value(t, result.status, Collect_Status.Device_Error)
	testing.expect_value(t, result.sweep_count, 0)
	testing.expect_value(t, deleted, 0)
	testing.expect(t, mock_find(store, orphan) >= 0)
}

@(test)
asymmetric_diamond_enforces_exact_depth_bound :: proc(t: ^testing.T) {
	store := mock_store_make()
	defer free(store)

	// shared has height 1 (shared -> inner_tree -> leaf).
	leaf := mock_put_blob(store, transmute([]u8)string("deep-shared-leaf"))
	orphan := mock_put_blob(store, transmute([]u8)string("orphan-kept-on-refusal"))
	e_leaf, _ := tree_hash.tree_entry_make(.Object, "leaf", leaf)
	inner := mock_put_tree(store, []tree_hash.Tree_Entry{e_leaf})
	e_inner, _ := tree_hash.tree_entry_make(.Tree, "inner", inner)
	shared := mock_put_tree(store, []tree_hash.Tree_Entry{e_inner})

	// Deep branch wraps shared 3 times (depth 3 -> shared at depth 3, inner at depth 4).
	deep := shared
	for _ in 0 ..< 3 {
		e_step, _ := tree_hash.tree_entry_make(.Tree, "step", deep)
		deep = mock_put_tree(store, []tree_hash.Tree_Entry{e_step})
	}
	// Root has both shallow ("a_shallow" -> shared at depth 1) and deep ("z_deep" -> deep -> ... -> shared at depth 4, inner at depth 5).
	e_shallow, _ := tree_hash.tree_entry_make(.Tree, "a_shallow", shared)
	e_deep, _ := tree_hash.tree_entry_make(.Tree, "z_deep", deep)
	root := mock_put_tree(store, []tree_hash.Tree_Entry{e_shallow, e_deep})

	all := mock_all_hashes(store)
	roots := [1]Root{{kind = .Pinned_Tree, hash = root}}
	sweep: [16]blake3.Hash

	// max_depth == 5 succeeds (root=0, deep=1..3, shared=4, inner=5).
	res_ok := collect(&store.collector, roots[:], all, &store.reader, sweep[:], max_depth = 5)
	testing.expect_value(t, res_ok.status, Collect_Status.Ok)
	testing.expect_value(t, res_ok.max_depth_seen, 5)
	testing.expect_value(t, res_ok.sweep_count, 1)

	// max_depth == 4 fails with Depth_Exceeded even though shared was first visited on the shallow branch!
	res_over, del_over := collect_and_sweep(&store.collector, roots[:], all, &store.reader, sweep[:], mock_delete, store, max_depth = 4)
	testing.expect_value(t, res_over.status, Collect_Status.Depth_Exceeded)
	testing.expect_value(t, res_over.sweep_count, 0)
	testing.expect_value(t, del_over, 0)
	testing.expect(t, mock_find(store, orphan) >= 0)
}

@(test)
applied_plan_tree_as_last_root_drains_extra_references :: proc(t: ^testing.T) {
	store := mock_store_make()
	defer free(store)

	mod := mock_put_blob(store, transmute([]u8)string("plan-module"))
	imported := mock_put_blob(store, transmute([]u8)string("plan-module-import"))
	orphan := mock_put_blob(store, transmute([]u8)string("unreferenced"))
	mock_add_extra_ref(store, mod, imported)

	e_mod, _ := tree_hash.tree_entry_make(.Object, "mod", mod)
	plan_tree := mock_put_tree(store, []tree_hash.Tree_Entry{e_mod})

	roots := [1]Root{{kind = .Applied_Plan, hash = plan_tree}}
	sweep: [16]blake3.Hash
	result, deleted := collect_and_sweep(&store.collector, roots[:], mock_all_hashes(store), &store.reader, sweep[:], mock_delete, store)
	testing.expect_value(t, result.status, Collect_Status.Ok)
	testing.expect_value(t, result.sweep_count, 1)
	testing.expect_value(t, sweep[0], orphan)
	testing.expect_value(t, deleted, 1)
	testing.expect(t, mock_find(store, imported) >= 0)
}
