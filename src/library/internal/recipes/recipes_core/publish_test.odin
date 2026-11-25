#+build !freestanding
package recipes_core

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"

@(private = "file")
pub_test_hash :: proc(tag: u8) -> blake3.Hash {
	data := [4]u8{'p', 'u', 'b', tag}
	return blake3.hash(data[:])
}

@(private = "file")
pub_test_sign_fail :: proc "contextless" (
	_: []u8,
	_: ^[object_cache.SIGNATURE_SIZE]u8,
	_: rawptr,
) -> bool {
	return false
}

@(private = "file")
pub_test_sign_ok :: proc "contextless" (
	message: []u8,
	out_signature: ^[object_cache.SIGNATURE_SIZE]u8,
	_: rawptr,
) -> bool {
	d := blake3.hash(message)
	copy(out_signature[:32], d[:])
	copy(out_signature[32:], d[:])
	return true
}

@(private = "file")
pub_store_put_object :: proc(t: ^testing.T, state: ^Recipes_State, hash: blake3.Hash, data: []u8) {
	name := pr.blob_object_name(hash)
	status := pr.private_store_write(&state.store, pr.private_object_name_text(&name), data)
	testing.expect_value(t, status, pr.Private_Store_Status.Ok)
}

@(test)
publish_refuses_bad_arguments_absent_and_damaged_realisations :: proc(t: ^testing.T) {
	state := new(Recipes_State)
	defer free(state)
	store := recipes_test_state_init(state)
	defer free(store)

	client := new(Cache_Quic_Client)
	defer free(client)

	signer_pub := pub_test_hash(9)
	recipe_hash := pub_test_hash(1)
	output_hash := pub_test_hash(2)

	// Unconfigured / nil client refused before any store or network access.
	_, ref, _, err := cache_quic_publish_realisation(nil, state, recipe_hash, signer_pub, pub_test_sign_ok, nil)
	testing.expect_value(t, err, Cache_Client_Error.Not_Configured)
	testing.expect_value(t, ref, pr.Recipe_Refusal.Cache_Miss)

	_, ref, _, err = cache_quic_publish_realisation(client, state, recipe_hash, signer_pub, pub_test_sign_ok, nil)
	testing.expect_value(t, err, Cache_Client_Error.Not_Configured)
	testing.expect_value(t, ref, pr.Recipe_Refusal.Cache_Miss)

	// Mark configured for input-border checks (no QUIC exchange occurs on pre-network refusals).
	client.configured = true

	// Nil state / nil sign_proc refused.
	_, ref, _, err = cache_quic_publish_realisation(client, nil, recipe_hash, signer_pub, pub_test_sign_ok, nil)
	testing.expect_value(t, err, Cache_Client_Error.Bad_Request)
	testing.expect_value(t, ref, pr.Recipe_Refusal.Buffer_Too_Small)

	_, ref, _, err = cache_quic_publish_realisation(client, state, recipe_hash, signer_pub, nil, nil)
	testing.expect_value(t, err, Cache_Client_Error.Bad_Request)
	testing.expect_value(t, ref, pr.Recipe_Refusal.Buffer_Too_Small)

	// Zero recipe hash or zero signer key refused.
	_, ref, _, err = cache_quic_publish_realisation(client, state, {}, signer_pub, pub_test_sign_ok, nil)
	testing.expect_value(t, err, Cache_Client_Error.Bad_Request)
	testing.expect_value(t, ref, pr.Recipe_Refusal.Malformed_Output)

	_, ref, _, err = cache_quic_publish_realisation(client, state, recipe_hash, {}, pub_test_sign_ok, nil)
	testing.expect_value(t, err, Cache_Client_Error.Bad_Request)
	testing.expect_value(t, ref, pr.Recipe_Refusal.Malformed_Output)

	// cache_quic_put_realisation refuses zero fields and unknown object kind.
	_, pr_err := cache_quic_put_realisation(client, {})
	testing.expect_value(t, pr_err, Cache_Client_Error.Bad_Request)
	_, pr_err = cache_quic_put_realisation(client, {
		recipe_hash       = recipe_hash,
		output_hash       = output_hash,
		output_kind       = object_cache.Cache_Object_Kind(99),
		signer_public_key = signer_pub,
	})
	testing.expect_value(t, pr_err, Cache_Client_Error.Bad_Request)

	// Absent realisation in both index and store -> Unknown_Recipe.
	_, ref, _, err = cache_quic_publish_realisation(client, state, recipe_hash, signer_pub, pub_test_sign_ok, nil)
	testing.expect_value(t, ref, pr.Recipe_Refusal.Unknown_Recipe)
	testing.expect_value(t, err, Cache_Client_Error.None)

	// Damaged realisation_<hash> in store -> Store_Damaged.
	real_name := pr.realisation_object_name(recipe_hash)
	garbage := [16]u8{0 = 1, 1 = 2, 2 = 3, 3 = 4}
	testing.expect_value(t, pr.private_store_write(&state.store, pr.private_object_name_text(&real_name), garbage[:]), pr.Private_Store_Status.Ok)
	_, ref, _, err = cache_quic_publish_realisation(client, state, recipe_hash, signer_pub, pub_test_sign_ok, nil)
	testing.expect_value(t, ref, pr.Recipe_Refusal.Store_Damaged)
	testing.expect_value(t, err, Cache_Client_Error.None)
}

@(test)
publish_closure_refuses_tampered_missing_cyclic_deep_and_sign_failure :: proc(t: ^testing.T) {
	state := new(Recipes_State)
	defer free(state)
	store := recipes_test_state_init(state)
	defer free(store)

	client := new(Cache_Quic_Client)
	defer free(client)
	client.configured = true

	signer_pub := pub_test_hash(11)
	stats: Cache_Publish_Stats

	// 1. Missing root blob -> Cache_Miss.
	ref, _, _ := cache_quic_put_closure_from_store(client, state, pub_test_hash(20), .Blob, signer_pub, pub_test_sign_ok, nil, &stats)
	testing.expect_value(t, ref, pr.Recipe_Refusal.Cache_Miss)

	// 2. Tampered blob (stored under hash of A, bytes are B) -> Hash_Mismatch before any signing or network call.
	blob_data := transmute([]u8)string("real-content")
	blob_hash := blake3.hash(blob_data)
	tampered := transmute([]u8)string("evil-content")
	pub_store_put_object(t, state, blob_hash, tampered)
	ref, _, _ = cache_quic_put_closure_from_store(client, state, blob_hash, .Blob, signer_pub, pub_test_sign_ok, nil, &stats)
	testing.expect_value(t, ref, pr.Recipe_Refusal.Hash_Mismatch)

	// 3. Valid blob with failing sign_proc -> Bad_Signature before network call.
	pub_store_put_object(t, state, blob_hash, blob_data)
	ref, _, _ = cache_quic_put_closure_from_store(client, state, blob_hash, .Blob, signer_pub, pub_test_sign_fail, nil, &stats)
	testing.expect_value(t, ref, pr.Recipe_Refusal.Bad_Signature)

	// 4. Tree with missing child blob -> Cache_Miss before signing or uploading tree.
	missing_hash := pub_test_hash(30)
	e_miss, _ := tree_hash.tree_entry_make(.Object, "missing", missing_hash)
	tree_buf: [512]u8
	t_len, _ := tree_hash.tree_encode([]tree_hash.Tree_Entry{e_miss}, tree_buf[:])
	t_hash, _ := tree_hash.tree_hash(tree_buf[:t_len])
	pub_store_put_object(t, state, t_hash, tree_buf[:t_len])
	ref, _, _ = cache_quic_put_closure_from_store(client, state, t_hash, .Tree, signer_pub, pub_test_sign_ok, nil, &stats)
	testing.expect_value(t, ref, pr.Recipe_Refusal.Cache_Miss)

	// 5. Tree exceeding CACHE_PUBLISH_DEPTH_MOST (32) -> Malformed_Output before any leaf upload.
	leaf_bytes := transmute([]u8)string("deep-leaf")
	leaf_hash := blake3.hash(leaf_bytes)
	pub_store_put_object(t, state, leaf_hash, leaf_bytes)
	child_hash := leaf_hash
	child_kind := tree_hash.Tree_Entry_Kind.Object
	for level in 0 ..= CACHE_PUBLISH_DEPTH_MOST {
		entry, _ := tree_hash.tree_entry_make(child_kind, "d", child_hash)
		n, enc_ref := tree_hash.tree_encode([]tree_hash.Tree_Entry{entry}, tree_buf[:])
		testing.expect_value(t, enc_ref, tree_hash.Tree_Refusal.None)
		h, h_ref := tree_hash.tree_hash(tree_buf[:n])
		testing.expect_value(t, h_ref, tree_hash.Tree_Refusal.None)
		pub_store_put_object(t, state, h, tree_buf[:n])
		child_hash = h
		child_kind = .Tree
		_ = level
	}
	ref, _, _ = cache_quic_put_closure_from_store(client, state, child_hash, .Tree, signer_pub, pub_test_sign_ok, nil, &stats)
	testing.expect_value(t, ref, pr.Recipe_Refusal.Malformed_Output)
}

@(test)
retention_never_sweeps_publisher_key_object :: proc(t: ^testing.T) {
	state := new(Recipes_State)
	defer free(state)
	store := recipes_test_state_init(state)
	defer free(store)

	// Write a publisher_key_0 object and an unreferenced <64-hex> blob.
	seed := [32]u8{0 = 1, 1 = 2, 2 = 3, 3 = 4, 4 = 5, 5 = 6, 6 = 7, 7 = 8}
	testing.expect_value(t, pr.private_store_write(&state.store, "publisher_key_0", seed[:]), pr.Private_Store_Status.Ok)

	orphan := transmute([]u8)string("orphan-blob-data")
	orphan_hash := blake3.hash(orphan)
	pub_store_put_object(t, state, orphan_hash, orphan)

	workspace := new(Retention_Workspace)
	defer free(workspace)
	summary := retention_collect(state, nil, nil, workspace)
	testing.expect_value(t, summary.refusal, Retention_Refusal.None)
	testing.expect_value(t, summary.removed, 1)

	// Orphan <64-hex> blob was swept, but publisher_key_0 remains intact.
	out: [32]u8
	got, st := pr.private_store_read(&state.store, "publisher_key_0", out[:])
	testing.expect_value(t, st, pr.Private_Store_Status.Ok)
	testing.expect_value(t, len(got), 32)
	testing.expect_value(t, out, seed)
}
