#+build !freestanding
package recipes_core

import "core:testing"
import "modus:contract/blake3"
import gb "modus:contract/guest_builder"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"

@(private = "file")
Retention_Test :: struct {
	state:     ^Recipes_State,
	store:     ^pr.Memory_Private_Store,
	registry:  ^Recipe_Registry,
	workspace: ^Retention_Workspace,
	trees:     [4][512]u8,
}

@(private = "file")
retention_test_make :: proc() -> ^Retention_Test {
	test := new(Retention_Test)
	test.state = new(Recipes_State)
	test.store = recipes_test_state_init(test.state)
	test.registry = new(Recipe_Registry)
	test.workspace = new(Retention_Workspace)
	return test
}

@(private = "file")
retention_test_end :: proc(test: ^Retention_Test) {
	free(test.workspace)
	free(test.registry)
	free(test.store)
	free(test.state)
	free(test)
}

@(private = "file")
put_object :: proc(test: ^Retention_Test, bytes: []u8) {
	hash, _ := pr.recipe_hash_output(.Blob, bytes)
	name := pr.blob_object_name(hash)
	assert(pr.private_store_write(&test.state.store, pr.private_object_name_text(&name), bytes) == .Ok)
}

@(private = "file")
put_tree :: proc(test: ^Retention_Test, slot: int, entries: []tree_hash.Tree_Entry) -> (hash: blake3.Hash, bytes: []u8) {
	written, _ := tree_hash.tree_encode(entries, test.trees[slot][:])
	bytes = test.trees[slot][:written]
	hash, _ = tree_hash.tree_hash(bytes)
	name := pr.blob_object_name(hash)
	assert(pr.private_store_write(&test.state.store, pr.private_object_name_text(&name), bytes) == .Ok)
	return hash, bytes
}

@(private = "file")
has_blob :: proc(test: ^Retention_Test, hash: blake3.Hash) -> bool {
	name := pr.blob_object_name(hash)
	return pr.memory_private_store_find(test.store, pr.private_object_name_text(&name)) != nil
}

// A pass keeps each object that a realisation, a recipe of the store, a
// recipe of the registry or a put of this run names, to the leaves of
// their trees, and removes the rest; the realisations and the recipes
// themselves stay.
@(test)
retention_keeps_what_is_named_and_removes_the_rest :: proc(t: ^testing.T) {
	test := retention_test_make()
	defer retention_test_end(test)

	a, b, c, k, p, z := []u8{'a'}, []u8{'b'}, []u8{'c'}, []u8{'k'}, []u8{'p'}, []u8{'z'}
	hash_of :: proc(bytes: []u8) -> blake3.Hash {
		return blake3.hash(bytes)
	}
	for bytes in ([?][]u8{a, b, c, k, p, z}) {
		put_object(test, bytes)
	}
	// The output tree of a realisation: a, and the tree sub that names b.
	b_entry, _ := tree_hash.tree_entry_make(.Object, "b", hash_of(b))
	sub_entries := [1]tree_hash.Tree_Entry{b_entry}
	sub_hash, _ := put_tree(test, 0, sub_entries[:])
	a_entry, _ := tree_hash.tree_entry_make(.Object, "a", hash_of(a))
	sub_entry, _ := tree_hash.tree_entry_make(.Tree, "sub", sub_hash)
	root_entries := [2]tree_hash.Tree_Entry{a_entry, sub_entry}
	root_hash, root_bytes := put_tree(test, 1, root_entries[:])
	record := object_cache.Realisation_Record{recipe_hash = blake3.hash([]u8{'r'}), output_hash = root_hash, output_kind = .Tree}
	object: [pr.REALISATION_OBJECT_HEAD_SIZE + 512]u8
	written, _ := pr.encode_realisation_object(&record, 1, u64(len(root_bytes)), object[:])
	realisation_name := pr.realisation_object_name(record.recipe_hash)
	assert(pr.private_store_write(&test.state.store, pr.private_object_name_text(&realisation_name), object[:written]) == .Ok)

	// A recipe of the store that names c and the kernel k.
	guest: gb.Guest_Build_Spec
	guest.kernel_hash = hash_of(k)
	guest.root_image_hash = blake3.hash([]u8{2})
	guest.memory_pages = 16_384
	guest.output_size_bound = 8192
	gb.build_spec_set_command(&guest, "true")
	spec: pr.Recipe_Spec
	spec.builder_hash = pr.guest_builder_hash()
	spec.output_kind = .Tree
	spec.input_count = 1
	spec.inputs[0], _ = pr.recipe_input_make("c", .Blob, hash_of(c))
	arguments_written, _ := gb.encode_build_spec(&guest, spec.arguments[:])
	spec.arguments_length = u32(arguments_written)
	recipe_hash, _ := pr.recipe_hash(&spec)
	recipe_bytes: [pr.MAX_RECIPE_OBJECT_BYTES]u8
	recipe_written, _ := pr.recipe_object_encode(&spec, recipe_bytes[:])
	recipe_name := pr.recipe_object_name(recipe_hash)
	assert(pr.private_store_write(&test.state.store, pr.private_object_name_text(&recipe_name), recipe_bytes[:recipe_written]) == .Ok)
	// An orphan tree that names a, which a realisation names too.
	orphan_entries := [1]tree_hash.Tree_Entry{a_entry}
	orphan_hash, _ := put_tree(test, 2, orphan_entries[:])

	extra := [1]blake3.Hash{hash_of(p)}
	result := retention_collect(test.state, test.registry, extra[:], test.workspace)
	testing.expect_value(t, result.refusal, Retention_Refusal.None)
	testing.expect_value(t, result.removed, 2)
	for kept in ([?]blake3.Hash{hash_of(a), hash_of(b), hash_of(c), hash_of(k), hash_of(p), sub_hash, root_hash}) {
		testing.expect(t, has_blob(test, kept), "a named object stays")
	}
	testing.expect(t, !has_blob(test, hash_of(z)), "an orphan blob goes")
	testing.expect(t, !has_blob(test, orphan_hash), "an orphan tree goes")
	testing.expect(t, pr.memory_private_store_find(test.store, pr.private_object_name_text(&realisation_name)) != nil)
	testing.expect(t, pr.memory_private_store_find(test.store, pr.private_object_name_text(&recipe_name)) != nil)

	// A second pass finds nothing more to remove.
	again := retention_collect(test.state, test.registry, extra[:], test.workspace)
	testing.expect_value(t, again.removed, 0)
	testing.expect_value(t, again.kept, 7)
}

// A pass that cannot see everything removes nothing: a tree deeper than
// the walk, and a store whose list fails.
@(test)
retention_removes_nothing_when_it_cannot_see_all :: proc(t: ^testing.T) {
	test := retention_test_make()
	defer retention_test_end(test)
	orphan := []u8{'o'}
	put_object(test, orphan)
	// A chain of trees one deeper than the walk, named by a put.
	leaf := []u8{'l'}
	put_object(test, leaf)
	entry, _ := tree_hash.tree_entry_make(.Object, "l", blake3.hash(leaf))
	hash: blake3.Hash
	for _ in 0 ..= RETENTION_DEPTH_MOST {
		entries := [1]tree_hash.Tree_Entry{entry}
		written, _ := tree_hash.tree_encode(entries[:], test.trees[3][:])
		hash, _ = tree_hash.tree_hash(test.trees[3][:written])
		name := pr.blob_object_name(hash)
		assert(pr.private_store_write(&test.state.store, pr.private_object_name_text(&name), test.trees[3][:written]) == .Ok)
		entry, _ = tree_hash.tree_entry_make(.Tree, "d", hash)
	}
	spec: pr.Recipe_Spec
	spec.builder_hash = pr.inputs_tree_builder_hash()
	spec.output_kind = .Tree
	spec.input_count = 1
	spec.inputs[0], _ = pr.recipe_input_make("deep", .Tree, hash)
	_, refusal := register_recipe(test.registry, &spec)
	assert(refusal == .None)
	result := retention_collect(test.state, test.registry, nil, test.workspace)
	testing.expect_value(t, result.refusal, Retention_Refusal.Too_Deep)
	testing.expect_value(t, result.removed, 0)
	testing.expect(t, has_blob(test, blake3.hash(orphan)), "nothing is removed")

	test.registry^ = {}
	test.state.store.list = nil
	failed := retention_collect(test.state, test.registry, nil, test.workspace)
	testing.expect_value(t, failed.refusal, Retention_Refusal.Store_Failed)
	testing.expect_value(t, failed.removed, 0)
	testing.expect(t, has_blob(test, blake3.hash(orphan)), "nothing is removed")
}

// A tree that a put of this window keeps, and that a recipe names, keeps
// its children: the put marks the tree first, and the walk of the tree
// still runs. A put tree that no recipe names keeps its children too, for
// the time of the put.
@(test)
retention_walks_a_put_tree_that_a_recipe_names :: proc(t: ^testing.T) {
	for named in ([?]bool{true, false}) {
		test := retention_test_make()
		defer retention_test_end(test)
		child := []u8{'c', 'h', 'i', 'l', 'd'}
		put_object(test, child)
		entry, _ := tree_hash.tree_entry_make(.Object, "child", blake3.hash(child))
		entries := [1]tree_hash.Tree_Entry{entry}
		tree, _ := put_tree(test, 0, entries[:])
		if named {
			spec: pr.Recipe_Spec
			spec.builder_hash = pr.inputs_tree_builder_hash()
			spec.output_kind = .Tree
			spec.input_count = 1
			spec.inputs[0], _ = pr.recipe_input_make("put", .Tree, tree)
			_, refusal := register_recipe(test.registry, &spec)
			assert(refusal == .None)
		}
		extra := [1]blake3.Hash{tree}
		result := retention_collect(test.state, test.registry, extra[:], test.workspace)
		testing.expect_value(t, result.refusal, Retention_Refusal.None)
		testing.expect_value(t, result.removed, 0)
		testing.expect(t, has_blob(test, blake3.hash(child)), "the child of a put tree stays")
		testing.expect(t, has_blob(test, tree), "the put tree stays")
	}
}

// A build that waits in the queue keeps what it will read: the inputs and
// the kernel of a build of the ring, which no registry holds, and the
// inputs of a registered recipe, while no realisation names them. With no
// queue, the pass removes them.
@(test)
retention_keeps_what_the_queue_will_read :: proc(t: ^testing.T) {
	for with_queue in ([?]bool{true, false}) {
		test := retention_test_make()
		defer retention_test_end(test)
		input, kernel := []u8{'i', 'n'}, []u8{'k', 'e'}
		put_object(test, input)
		put_object(test, kernel)
		guest: gb.Guest_Build_Spec
		guest.kernel_hash = blake3.hash(kernel)
		guest.root_image_hash = blake3.hash([]u8{2})
		guest.memory_pages = 16_384
		guest.output_size_bound = 8192
		gb.build_spec_set_command(&guest, "true")
		queue := new(Guest_Queue)
		defer free(queue)
		job := Guest_Queue_Job{principal = GUEST_QUEUE_RING_PRINCIPAL, from_ring = true, mode = .Build_Only}
		job.spec.builder_hash = pr.guest_builder_hash()
		job.spec.output_kind = .Tree
		job.spec.input_count = 1
		job.spec.inputs[0], _ = pr.recipe_input_make("in", .Blob, blake3.hash(input))
		written, _ := gb.encode_build_spec(&guest, job.spec.arguments[:])
		job.spec.arguments_length = u32(written)
		job.recipe_hash, _ = pr.recipe_hash(&job.spec)
		assert(guest_queue_push(queue, job) == .None)
		result := retention_collect(test.state, test.registry, nil, test.workspace, with_queue ? queue : nil)
		testing.expect_value(t, result.refusal, Retention_Refusal.None)
		testing.expectf(t, has_blob(test, blake3.hash(input)) == with_queue, "the input of a queued build stays: %v", with_queue)
		testing.expectf(t, has_blob(test, blake3.hash(kernel)) == with_queue, "the kernel of a queued build stays: %v", with_queue)
	}
}

// An active build on state.building and explicit pinned output trees keep
// every referenced object and recursive tree child alive across collection.
@(test)
retention_keeps_active_build_and_pinned_trees :: proc(t: ^testing.T) {
	test := retention_test_make()
	defer retention_test_end(test)

	active_in := []u8{'a', 'c', 't'}
	pin_leaf := []u8{'p', 'i', 'n'}
	orphan := []u8{'o', 'r', 'p'}
	put_object(test, active_in)
	put_object(test, pin_leaf)
	put_object(test, orphan)

	pin_entry, _ := tree_hash.tree_entry_make(.Object, "pinned", blake3.hash(pin_leaf))
	pin_entries := [1]tree_hash.Tree_Entry{pin_entry}
	pin_tree, _ := put_tree(test, 0, pin_entries[:])

	active_spec: pr.Recipe_Spec
	active_spec.builder_hash = pr.inputs_tree_builder_hash()
	active_spec.output_kind = .Tree
	active_spec.input_count = 1
	active_spec.inputs[0], _ = pr.recipe_input_make("in", .Blob, blake3.hash(active_in))
	test.state.building = &active_spec
	defer { test.state.building = nil }

	pins := [1]blake3.Hash{pin_tree}
	result := retention_collect(test.state, test.registry, nil, test.workspace, nil, pins[:])
	testing.expect_value(t, result.refusal, Retention_Refusal.None)
	testing.expect_value(t, result.removed, 1)
	testing.expect(t, has_blob(test, blake3.hash(active_in)), "active build input stays")
	testing.expect(t, has_blob(test, pin_tree), "pinned tree root stays")
	testing.expect(t, has_blob(test, blake3.hash(pin_leaf)), "pinned tree child stays")
	testing.expect(t, !has_blob(test, blake3.hash(orphan)), "unreferenced orphan goes")

	// Once the build finishes and the pin is dropped, the next pass reclaims all three.
	test.state.building = nil
	after := retention_collect(test.state, test.registry, nil, test.workspace, nil, nil)
	testing.expect_value(t, after.refusal, Retention_Refusal.None)
	testing.expect_value(t, after.removed, 3)
	testing.expect_value(t, after.kept, 0)
}

// retention_make_room runs collect_before_evict to reclaim unreferenced orphans
// before evicting any live cached realisation.
@(test)
retention_make_room_collects_orphans_before_evicting_realisations :: proc(t: ^testing.T) {
	test := retention_test_make()
	defer retention_test_end(test)

	// Give the memory store a usage callback with a tight 20-block limit
	// (75% retention guard = 15 blocks).
	test.state.store.usage = proc "contextless" (user: rawptr) -> (blocks: i64, limit: i64, status: pr.Private_Store_Status) {
		ms := (^pr.Memory_Private_Store)(user)
		total: i64 = 0
		for &obj in ms.objects {
			if obj.used {
				total += i64((u64(obj.length) + STORE_BLOCK_BYTES - 1) / STORE_BLOCK_BYTES) + 1
			}
		}
		return total, 20, .Ok
	}

	// Write one live realisation referencing a 4 KiB output (3 blocks + head).
	live_payload: [4096]u8
	for i in 0 ..< len(live_payload) {
		live_payload[i] = u8((i * 7 + 3) & 0xFF)
	}
	live_hash := blake3.hash(live_payload[:])
	live_name := pr.blob_object_name(live_hash)
	assert(pr.private_store_write(&test.state.store, pr.private_object_name_text(&live_name), live_payload[:]) == .Ok)
	record := object_cache.Realisation_Record{recipe_hash = blake3.hash([]u8{'l', 'i', 'v', 'e'}), output_hash = live_hash, output_kind = .Blob}
	head: [pr.REALISATION_OBJECT_HEAD_SIZE]u8
	written, _ := pr.encode_realisation_object(&record, 1, u64(len(live_payload)), head[:])
	real_name := pr.realisation_object_name(record.recipe_hash)
	assert(pr.private_store_write(&test.state.store, pr.private_object_name_text(&real_name), head[:written]) == .Ok)

	// Write several unreferenced orphan blobs so the store exceeds 75% guard.
	orphan_hashes: [4]blake3.Hash
	for k in 0 ..< 4 {
		buf: [8192]u8
		for i in 0 ..< len(buf) {
			buf[i] = u8((i + k * 53) & 0xFF)
		}
		orphan_hashes[k] = blake3.hash(buf[:])
		oname := pr.blob_object_name(orphan_hashes[k])
		assert(pr.private_store_write(&test.state.store, pr.private_object_name_text(&oname), buf[:]) == .Ok)
	}

	Collect_Ctx :: struct {
		test:  ^Retention_Test,
		calls: int,
	}
	ctx := Collect_Ctx{test = test}
	test.state.collect_before_evict = proc "contextless" (user_data: rawptr) -> int {
		c := (^Collect_Ctx)(user_data)
		c.calls += 1
		res := retention_collect(c.test.state, c.test.registry, nil, c.test.workspace)
		return res.refusal == .None ? res.removed : 0
	}
	test.state.collect_before_evict_user = &ctx

	// Asking room for a 4 KiB output must collect the 4 orphans and keep the live realisation intact.
	refusal := retention_make_room(test.state, 4096)
	testing.expect_value(t, refusal, pr.Recipe_Refusal.None)
	testing.expect_value(t, ctx.calls, 1)
	testing.expect_value(t, test.state.counters.retention_removals, u64(0))
	testing.expect(t, has_blob(test, live_hash), "live realisation output stayed untouched")
	testing.expect(t, pr.memory_private_store_find(test.store, pr.private_object_name_text(&real_name)) != nil, "live realisation head stayed untouched")
	for h in orphan_hashes {
		testing.expect(t, !has_blob(test, h), "unreferenced orphan was reclaimed")
	}
}

@(test)
builder_output_block_limit_reserves_parent_headroom :: proc(t: ^testing.T) {
	// Full or zero-limit store refuses before starting the builder.
	testing.expect_value(t, builder_output_block_limit(64, 0, 0), u64(0))
	testing.expect_value(t, builder_output_block_limit(64, 1000, 1000), u64(0))
	testing.expect_value(t, builder_output_block_limit(64, 1000, 1200), u64(0))

	// Store of 1000 blocks reserves 125 blocks (1/8); with 875 used, 0 left for builder.
	testing.expect_value(t, builder_output_block_limit(64, 1000, 875), u64(0))
	testing.expect_value(t, builder_output_block_limit(64, 1000, 874), u64(1))

	// Explicit recipe limit smaller than available headroom is honoured exactly.
	testing.expect_value(t, builder_output_block_limit(200, 1000, 100), u64(200))

	// Explicit recipe limit larger than available headroom (775) is capped to available headroom.
	testing.expect_value(t, builder_output_block_limit(5000, 1000, 100), u64(775))

	// Default recipe limit (0) uses DEFAULT_BUILDER_OUTPUT_BLOCK_LIMIT on large stores.
	testing.expect_value(t, builder_output_block_limit(0, 1_000_000, 10_000), DEFAULT_BUILDER_OUTPUT_BLOCK_LIMIT)
	// And shrinks cleanly to available headroom on smaller stores.
	testing.expect_value(t, builder_output_block_limit(0, 1000, 100), u64(775))

	// Tiny test store (<= 32 blocks) uses zero reserve so small-store tests can still build.
	testing.expect_value(t, builder_output_block_limit(10, 32, 10), u64(10))
	testing.expect_value(t, builder_output_block_limit(100, 32, 10), u64(22))
}
