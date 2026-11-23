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
	written, _ := pr.encode_realisation_object(&record, 1, root_bytes, object[:])
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
	recipe_bytes: [pr.RECIPE_OBJECT_WIRE_MOST]u8
	recipe_written, _ := pr.encode_recipe_object(&spec, recipe_bytes[:])
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
