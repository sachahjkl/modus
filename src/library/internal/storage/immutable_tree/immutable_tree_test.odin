#+build !freestanding
package immutable_tree

import "core:testing"
import "modus:contract/blake3"
import format "modus:contract/store"
import "modus:contract/tree_hash"
import "internal:storage/storage_tree"

// Fixed-capacity in-memory B+ tree disk + content-addressed immutable object
// store for host tests (contextless-safe for callbacks).
IMMUTABLE_TEST_CAPACITY :: 512

Test_Slot :: struct {
	used: bool,
	name: [HASH_HEX_LENGTH]u8,
	len:  int,
	data: [tree_hash.MAX_ENCODED_TREE_BYTES]u8,
}

Blob_Slot :: struct {
	used: bool,
	id:   u64,
	len:  int,
	data: [1024]u8,
}

Pure_Env :: struct {
	blocks:         [512]storage_tree.Block,
	next_block:     u64,
	blobs:          [256]Blob_Slot,
	next_blob:      u64,
	immutable:      [IMMUTABLE_TEST_CAPACITY]Test_Slot,
	immutable_used: int,
	source:         storage_tree.Source,
	writer:         storage_tree.Writer,
	backend:        Store_Backend,
	pool:           storage_tree.Pool,
	work:           Freeze_Work,
}

pure_env_make :: proc() -> ^Pure_Env {
	env := new(Pure_Env)
	env.next_block = 2
	env.next_blob = 1
	env.source = {
		read = proc "contextless" (source: ^storage_tree.Source, pointer: format.Pointer, into: ^storage_tree.Block) -> storage_tree.Read {
			e := (^Pure_Env)(source.data)
			if pointer.block < 2 || pointer.block >= e.next_block {
				return .Wrong
			}
			blk := &e.blocks[pointer.block]
			if format.check(blk[:]) != pointer.check {
				return .Wrong
			}
			into^ = blk^
			return .Good
		},
		data = env,
	}
	env.writer = {
		write = proc "contextless" (writer: ^storage_tree.Writer, bytes: ^storage_tree.Block) -> format.Pointer {
			e := (^Pure_Env)(writer.data)
			if e.next_block >= u64(len(e.blocks)) {
				return {}
			}
			number := e.next_block
			e.next_block += 1
			e.blocks[number] = bytes^
			return {block = number, check = format.check(bytes[:])}
		},
		data = env,
	}
	env.backend = {
		read_object          = pure_read_object,
		has_object           = pure_has_object,
		write_object         = pure_write_object,
		persist_entry_object = pure_persist_entry_object,
		data                 = env,
	}
	return env
}

pure_find_slot :: proc "contextless" (env: ^Pure_Env, name: [HASH_HEX_LENGTH]u8) -> int {
	for index in 0 ..< env.immutable_used {
		if env.immutable[index].used && env.immutable[index].name == name {
			return index
		}
	}
	return -1
}

pure_has_object :: proc "contextless" (backend: ^Store_Backend, name: [HASH_HEX_LENGTH]u8) -> (bool, Backend_Status) {
	env := (^Pure_Env)(backend.data)
	return pure_find_slot(env, name) >= 0, .Ok
}

pure_read_object :: proc "contextless" (backend: ^Store_Backend, name: [HASH_HEX_LENGTH]u8, buffer: []u8) -> (int, Backend_Status) {
	env := (^Pure_Env)(backend.data)
	slot_idx := pure_find_slot(env, name)
	if slot_idx < 0 {
		return 0, .Absent
	}
	slot := &env.immutable[slot_idx]
	if slot.len > len(buffer) {
		return slot.len, .Buffer_Too_Small
	}
	copy(buffer[:slot.len], slot.data[:slot.len])
	return slot.len, .Ok
}

pure_write_object :: proc "contextless" (backend: ^Store_Backend, name: [HASH_HEX_LENGTH]u8, data: []u8) -> Backend_Status {
	env := (^Pure_Env)(backend.data)
	if len(data) > tree_hash.MAX_ENCODED_TREE_BYTES {
		return .Full
	}
	slot_idx := pure_find_slot(env, name)
	if slot_idx < 0 {
		if env.immutable_used >= IMMUTABLE_TEST_CAPACITY {
			return .Full
		}
		slot_idx = env.immutable_used
		env.immutable_used += 1
	}
	slot := &env.immutable[slot_idx]
	slot.used = true
	slot.name = name
	slot.len = len(data)
	copy(slot.data[:len(data)], data)
	return .Ok
}

pure_persist_entry_object :: proc "contextless" (backend: ^Store_Backend, entry: format.Entry, name: [HASH_HEX_LENGTH]u8) -> Backend_Status {
	env := (^Pure_Env)(backend.data)
	if entry.size == 0 && entry.pointer.block == 0 {
		return pure_write_object(backend, name, nil)
	}
	for &blob in env.blobs {
		if blob.used && blob.id == entry.pointer.block {
			return pure_write_object(backend, name, blob.data[:blob.len])
		}
	}
	return .Absent
}

// Helpers to build mutable B+ trees in Pure_Env.
put_object :: proc(env: ^Pure_Env, tree_root: format.Pointer, name: string, content: []u8) -> format.Pointer {
	blob_id: u64 = 0
	if len(content) > 0 {
		blob_id = env.next_blob
		env.next_blob += 1
		slot := &env.blobs[blob_id]
		slot.used = true
		slot.id = blob_id
		slot.len = len(content)
		copy(slot.data[:len(content)], content)
	}
	entry := format.Entry {
		kind    = u64(format.Entry_Kind.Object),
		size    = u64(len(content)),
		hash    = blake3.hash(content),
		pointer = {block = blob_id, check = 0},
	}
	storage_tree.pool_reset(&env.pool)
	work := storage_tree.Work{pool = &env.pool, source = &env.source, shape = storage_tree.TREE_SHAPE, root = tree_root}
	key := format.entry_name(name)
	storage_tree.put(&work, key[:], ([^]u8)(&entry)[:size_of(format.Entry)], true)
	return storage_tree.finish(&work, &env.writer)
}

put_subtree :: proc(env: ^Pure_Env, tree_root: format.Pointer, name: string, child_root: format.Pointer, child_entries: u64 = 0) -> format.Pointer {
	entry := format.Entry {
		kind    = u64(format.Entry_Kind.Tree),
		size    = child_entries,
		pointer = child_root,
	}
	storage_tree.pool_reset(&env.pool)
	work := storage_tree.Work{pool = &env.pool, source = &env.source, shape = storage_tree.TREE_SHAPE, root = tree_root}
	key := format.entry_name(name)
	storage_tree.put(&work, key[:], ([^]u8)(&entry)[:size_of(format.Entry)], true)
	return storage_tree.finish(&work, &env.writer)
}

@(test)
freeze_and_read_empty_tree :: proc(t: ^testing.T) {
	env := pure_env_make()
	defer free(env)

	root_hash, status := freeze_tree(&env.work, &env.source, &env.pool, {}, &env.backend)
	testing.expect_value(t, status, Tree_Store_Status.Ok)
	testing.expect_value(t, env.work.stats.trees_written, 1)
	testing.expect_value(t, env.work.stats.trees_reused, 0)

	scratch := make([]u8, tree_hash.MAX_ENCODED_TREE_BYTES)
	defer delete(scratch)
	bytes, read_status := tree_read(&env.backend, root_hash, scratch)
	testing.expect_value(t, read_status, Tree_Store_Status.Ok)
	testing.expect_value(t, len(bytes), tree_hash.HEADER_SIZE)

	// Empty tree lookup returns Absent.
	_, entry_status := tree_entry(&env.backend, root_hash, "anything", scratch)
	testing.expect_value(t, entry_status, Tree_Store_Status.Absent)
}

@(test)
nested_trees_and_path_walk :: proc(t: ^testing.T) {
	env := pure_env_make()
	defer free(env)

	// Build:
	//   root/
	//     README.md  ("modus")
	//     src/
	//       main.odin ("package main")
	//       sub/
	//         empty_dir/
	//         leaf.txt ("hello leaf")
	sub_root: format.Pointer
	sub_root = put_subtree(env, sub_root, "empty_dir", {})
	sub_root = put_object(env, sub_root, "leaf.txt", transmute([]u8)string("hello leaf"))

	src_root: format.Pointer
	src_root = put_object(env, src_root, "main.odin", transmute([]u8)string("package main"))
	src_root = put_subtree(env, src_root, "sub", sub_root, 2)

	root: format.Pointer
	root = put_object(env, root, "README.md", transmute([]u8)string("modus"))
	root = put_subtree(env, root, "src", src_root, 2)

	root_hash, status := freeze_tree(&env.work, &env.source, &env.pool, root, &env.backend)
	testing.expect_value(t, status, Tree_Store_Status.Ok)
	testing.expect_value(t, env.work.stats.trees_written, 4) // root, src, sub, empty_dir
	testing.expect_value(t, env.work.stats.objects_written, 3)

	scratch := make([]u8, tree_hash.MAX_ENCODED_TREE_BYTES)
	defer delete(scratch)

	// Walk to nested object src/sub/leaf.txt.
	path := [3]string{"src", "sub", "leaf.txt"}
	leaf_entry, walk_status := tree_walk_path(&env.backend, root_hash, path[:], scratch)
	testing.expect_value(t, walk_status, Tree_Store_Status.Ok)
	testing.expect_value(t, leaf_entry.kind, tree_hash.Tree_Entry_Kind.Object)
	testing.expect_value(t, leaf_entry.hash, blake3.hash(transmute([]u8)string("hello leaf")))

	// Walk to nested empty tree src/sub/empty_dir.
	empty_path := [3]string{"src", "sub", "empty_dir"}
	empty_entry, empty_status := tree_walk_path(&env.backend, root_hash, empty_path[:], scratch)
	testing.expect_value(t, empty_status, Tree_Store_Status.Ok)
	testing.expect_value(t, empty_entry.kind, tree_hash.Tree_Entry_Kind.Tree)

	// Attempting to traverse through an Object fails with Not_A_Tree.
	bad_path := [2]string{"README.md", "child"}
	_, bad_status := tree_walk_path(&env.backend, root_hash, bad_path[:], scratch)
	testing.expect_value(t, bad_status, Tree_Store_Status.Not_A_Tree)

	// Missing path returns Absent.
	missing_path := [2]string{"src", "nope"}
	_, missing_status := tree_walk_path(&env.backend, root_hash, missing_path[:], scratch)
	testing.expect_value(t, missing_status, Tree_Store_Status.Absent)
}

@(test)
identical_subtrees_deduplicate_to_one_hash :: proc(t: ^testing.T) {
	env := pure_env_make()
	defer free(env)

	// Build two distinct mutable B+ subtrees with identical entries.
	sub_a: format.Pointer
	sub_a = put_object(env, sub_a, "a.txt", transmute([]u8)string("same content"))
	sub_a = put_object(env, sub_a, "b.txt", transmute([]u8)string("second file"))

	sub_b: format.Pointer
	// Insert in reverse order to ensure B+ tree insertion order does not affect canonical hash!
	sub_b = put_object(env, sub_b, "b.txt", transmute([]u8)string("second file"))
	sub_b = put_object(env, sub_b, "a.txt", transmute([]u8)string("same content"))

	root: format.Pointer
	root = put_subtree(env, root, "copy_one", sub_a, 2)
	root = put_subtree(env, root, "copy_two", sub_b, 2)

	root_hash, status := freeze_tree(&env.work, &env.source, &env.pool, root, &env.backend)
	testing.expect_value(t, status, Tree_Store_Status.Ok)
	// copy_one writes its subtree; copy_two reuses it! Root is written once -> 2 written, 1 reused.
	testing.expect_value(t, env.work.stats.trees_written, 2)
	testing.expect_value(t, env.work.stats.trees_reused, 1)
	testing.expect_value(t, env.work.stats.objects_written, 2)
	testing.expect_value(t, env.work.stats.objects_reused, 2)

	scratch := make([]u8, tree_hash.MAX_ENCODED_TREE_BYTES)
	defer delete(scratch)
	e1, s1 := tree_entry(&env.backend, root_hash, "copy_one", scratch)
	e2, s2 := tree_entry(&env.backend, root_hash, "copy_two", scratch)
	testing.expect_value(t, s1, Tree_Store_Status.Ok)
	testing.expect_value(t, s2, Tree_Store_Status.Ok)
	testing.expect_value(t, e1.hash, e2.hash)
}

@(test)
mutation_after_freeze_produces_new_hash_while_old_stays_intact :: proc(t: ^testing.T) {
	env := pure_env_make()
	defer free(env)

	// Version 1.
	root: format.Pointer
	root = put_object(env, root, "config.lex", transmute([]u8)string("v1"))
	root = put_object(env, root, "shared.bin", transmute([]u8)string("unchanged"))

	hash_v1, status_v1 := freeze_tree(&env.work, &env.source, &env.pool, root, &env.backend)
	testing.expect_value(t, status_v1, Tree_Store_Status.Ok)

	// Mutate config.lex to v2.
	root = put_object(env, root, "config.lex", transmute([]u8)string("v2-updated"))
	hash_v2, status_v2 := freeze_tree(&env.work, &env.source, &env.pool, root, &env.backend)
	testing.expect_value(t, status_v2, Tree_Store_Status.Ok)
	testing.expect(t, hash_v1 != hash_v2)
	// shared.bin was reused!
	testing.expect_value(t, env.work.stats.objects_reused, 1)
	testing.expect_value(t, env.work.stats.objects_written, 1)

	scratch := make([]u8, tree_hash.MAX_ENCODED_TREE_BYTES)
	defer delete(scratch)

	// Old tree hash_v1 still resolves config.lex to "v1" AND its persisted object is intact!
	e_v1, s_v1 := tree_entry(&env.backend, hash_v1, "config.lex", scratch)
	testing.expect_value(t, s_v1, Tree_Store_Status.Ok)
	testing.expect_value(t, e_v1.hash, blake3.hash(transmute([]u8)string("v1")))
	v1_blob_buf: [64]u8
	v1_len, v1_blob_status := pure_read_object(&env.backend, hash_to_hex(e_v1.hash), v1_blob_buf[:])
	testing.expect_value(t, v1_blob_status, Backend_Status.Ok)
	testing.expect_value(t, string(v1_blob_buf[:v1_len]), "v1")

	// New tree hash_v2 resolves config.lex to "v2-updated".
	e_v2, s_v2 := tree_entry(&env.backend, hash_v2, "config.lex", scratch)
	testing.expect_value(t, s_v2, Tree_Store_Status.Ok)
	testing.expect_value(t, e_v2.hash, blake3.hash(transmute([]u8)string("v2-updated")))
}

@(test)
corrupt_and_missing_tree_hash_refused :: proc(t: ^testing.T) {
	env := pure_env_make()
	defer free(env)

	root: format.Pointer
	root = put_object(env, root, "data", transmute([]u8)string("payload"))
	root_hash, status := freeze_tree(&env.work, &env.source, &env.pool, root, &env.backend)
	testing.expect_value(t, status, Tree_Store_Status.Ok)

	scratch := make([]u8, tree_hash.MAX_ENCODED_TREE_BYTES)
	defer delete(scratch)

	// Missing tree hash -> Absent.
	missing_hash := blake3.hash(transmute([]u8)string("no such tree"))
	_, absent_status := tree_read(&env.backend, missing_hash, scratch)
	testing.expect_value(t, absent_status, Tree_Store_Status.Absent)

	// Corrupt stored bytes (flip 1 bit in stored tree payload) -> Corrupt_Tree.
	slot_idx := pure_find_slot(env, hash_to_hex(root_hash))
	testing.expect(t, slot_idx >= 0)
	env.immutable[slot_idx].data[tree_hash.HEADER_SIZE + 70] ~= 0x01
	_, corrupt_status := tree_read(&env.backend, root_hash, scratch)
	testing.expect_value(t, corrupt_status, Tree_Store_Status.Corrupt_Tree)
	_, entry_corrupt := tree_entry(&env.backend, root_hash, "data", scratch)
	testing.expect_value(t, entry_corrupt, Tree_Store_Status.Corrupt_Tree)

	// Hex parsing rejects uppercase, wrong length, and non-hex characters.
	good_hex := hash_to_hex(root_hash)
	parsed, ok := hex_to_hash(good_hex[:])
	testing.expect(t, ok && parsed == root_hash)

	upper_hex := good_hex
	for &b in upper_hex {
		if b >= 'a' && b <= 'f' {
			b = b - 'a' + 'A'
		}
	}
	if upper_hex != good_hex {
		_, upper_ok := hex_to_hash(upper_hex[:])
		testing.expect(t, !upper_ok)
	}
	_, short_ok := hex_to_hash(good_hex[:63])
	testing.expect(t, !short_ok)
}

@(test)
freeze_depth_bound_and_one_past_bound :: proc(t: ^testing.T) {
	env := pure_env_make()
	defer free(env)

	// Build a nested chain of depth 4: d0 -> d1 -> d2 -> d3 -> leaf.
	current := put_object(env, {}, "leaf", transmute([]u8)string("bottom"))
	for _ in 0 ..< 4 {
		current = put_subtree(env, {}, "next", current, 1)
	}

	// max_depth == 4 succeeds.
	h_ok, s_ok := freeze_tree(&env.work, &env.source, &env.pool, current, &env.backend, max_depth = 4)
	testing.expect_value(t, s_ok, Tree_Store_Status.Ok)
	testing.expect(t, h_ok != blake3.Hash{})

	// max_depth == 3 (one past bound) refused with Depth_Exceeded.
	_, s_over := freeze_tree(&env.work, &env.source, &env.pool, current, &env.backend, max_depth = 3)
	testing.expect_value(t, s_over, Tree_Store_Status.Depth_Exceeded)
}
