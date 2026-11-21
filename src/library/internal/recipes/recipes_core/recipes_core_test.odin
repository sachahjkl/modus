#+build !freestanding
package recipes_core

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"

@(private = "file")
make_hash :: proc(tag: u8) -> blake3.Hash {
	data := [4]u8{'r', 'c', 'p', tag}
	return blake3.hash(data[:])
}

@(private = "file")
make_key :: proc(tag: u8) -> [object_cache.PUBLIC_KEY_SIZE]u8 {
	key: [object_cache.PUBLIC_KEY_SIZE]u8
	for index in 0 ..< len(key) {
		key[index] = tag ~ u8(index + 3)
	}
	return key
}

@(private = "file")
mock_sign_bytes :: proc "contextless" (public_key: [object_cache.PUBLIC_KEY_SIZE]u8, message: []u8) -> [object_cache.SIGNATURE_SIZE]u8 {
	sig: [object_cache.SIGNATURE_SIZE]u8
	first := blake3.derive_key("rcp-sig-1", message)
	key_copy := public_key
	second := blake3.derive_key("rcp-sig-2", key_copy[:])
	for index in 0 ..< 32 {
		sig[index] = first[index] ~ second[index]
		sig[32 + index] = first[31 - index] ~ second[index]
	}
	return sig
}

@(private = "file")
mock_verify :: proc "contextless" (
	public_key: [object_cache.PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [object_cache.SIGNATURE_SIZE]u8,
	user_data: rawptr,
) -> bool {
	_ = user_data
	expected := mock_sign_bytes(public_key, message)
	return signature == expected
}

@(private = "file")
make_canonical_tree :: proc(name: string, obj_hash: blake3.Hash, out: []u8) -> (written: int, digest: blake3.Hash) {
	entry, _ := tree_hash.tree_entry_make(.Object, name, obj_hash)
	entries := [1]tree_hash.Tree_Entry{entry}
	written, _ = tree_hash.tree_encode(entries[:], out)
	digest, _ = tree_hash.tree_hash(out[:written])
	return written, digest
}

@(private = "file")
Test_Harness :: struct {
	has_cache:           bool,
	cache_realisation:   object_cache.Realisation_Record,
	cache_payload_len:   int,
	cache_payload:       [512]u8,
	builder_calls:       int,
	builder_saw_network: bool,
	builder_saw_date:    u64,
	builder_saw_seed:    blake3.Hash,
	builder_payload_len: int,
	builder_payload:     [512]u8,
	builder_ok:          bool,
	local_signer_key:    [object_cache.PUBLIC_KEY_SIZE]u8,
}

@(private = "file")
harness_cache_lookup :: proc "contextless" (
	recipe_hash: blake3.Hash,
	out_realisation: ^object_cache.Realisation_Record,
	out_payload: []u8,
	user_data: rawptr,
) -> (int, bool) {
	h := (^Test_Harness)(user_data)
	if !h.has_cache || h.cache_realisation.recipe_hash != recipe_hash {
		return 0, false
	}
	out_realisation^ = h.cache_realisation
	copy(out_payload[:h.cache_payload_len], h.cache_payload[:h.cache_payload_len])
	return h.cache_payload_len, true
}

@(private = "file")
harness_builder_invoke :: proc "contextless" (
	sandbox: ^pr.Builder_Sandbox_Spec,
	out_payload: []u8,
	user_data: rawptr,
) -> (int, bool) {
	h := (^Test_Harness)(user_data)
	h.builder_calls += 1
	h.builder_saw_network = sandbox.allow_network
	h.builder_saw_date = sandbox.frozen_date_unix
	h.builder_saw_seed = sandbox.random_seed
	if !h.builder_ok {
		return 0, false
	}
	copy(out_payload[:h.builder_payload_len], h.builder_payload[:h.builder_payload_len])
	return h.builder_payload_len, true
}

@(private = "file")
harness_sign_local :: proc "contextless" (
	signing_bytes: []u8,
	out_public_key: ^[object_cache.PUBLIC_KEY_SIZE]u8,
	out_signature: ^[object_cache.SIGNATURE_SIZE]u8,
	user_data: rawptr,
) -> bool {
	h := (^Test_Harness)(user_data)
	out_public_key^ = h.local_signer_key
	out_signature^ = mock_sign_bytes(h.local_signer_key, signing_bytes)
	return true
}

@(test)
test_recipes_build_cache_sandbox_verify_and_refusals :: proc(t: ^testing.T) {
	state := new(Recipes_State)
	defer free(state)
	state_init(state)

	spec := pr.Recipe_Spec {
		builder_hash       = make_hash(1),
		output_kind_word   = u64(object_cache.Cache_Object_Kind.Tree),
		source_date_unix   = 1700001234,
		output_block_limit = 256,
		input_count        = 1,
	}
	spec.inputs[0], _ = pr.recipe_input_make("src", .Tree, make_hash(2))
	rhash, _ := pr.recipe_hash(&spec)

	trusted_key := make_key(10)
	local_key := make_key(20)
	signers := [1][object_cache.PUBLIC_KEY_SIZE]u8{trusted_key}
	policy := object_cache.Substitution_Policy{mode = .Prefer_Cache, trusted_signers = signers[:]}

	harness := Test_Harness{builder_ok = true, local_signer_key = local_key}
	n_built, h_built := make_canonical_tree("out.module", make_hash(50), harness.builder_payload[:])
	harness.builder_payload_len = n_built

	// Cache_Only with miss refuses without invoking builder.
	res_miss := build_recipe(state, &spec, .Cache_Only, policy, harness_cache_lookup, harness_builder_invoke, mock_verify, harness_sign_local, &harness)
	testing.expect_value(t, res_miss.outcome, pr.Recipe_Build_Outcome.Refused)
	testing.expect_value(t, res_miss.refusal, pr.Recipe_Refusal.Cache_Miss)
	testing.expect_value(t, harness.builder_calls, 0)

	// Cache_First on miss falls back to sandboxed builder with frozen date, zero network, seed == recipe_hash.
	res_local := build_recipe(state, &spec, .Cache_First, policy, harness_cache_lookup, harness_builder_invoke, mock_verify, harness_sign_local, &harness)
	testing.expect_value(t, res_local.outcome, pr.Recipe_Build_Outcome.Built_Locally)
	testing.expect_value(t, res_local.output_hash, h_built)
	testing.expect_value(t, harness.builder_calls, 1)
	testing.expect(t, !harness.builder_saw_network, "builder must have zero network")
	testing.expect_value(t, harness.builder_saw_date, u64(1700001234))
	testing.expect_value(t, harness.builder_saw_seed, rhash)

	// Second Cache_First hits local store without invoking builder again.
	res_hit := build_recipe(state, &spec, .Cache_First, policy, harness_cache_lookup, harness_builder_invoke, mock_verify, harness_sign_local, &harness)
	testing.expect_value(t, res_hit.outcome, pr.Recipe_Build_Outcome.From_Cache)
	testing.expect_value(t, res_hit.output_hash, h_built)
	testing.expect_value(t, harness.builder_calls, 1)

	// Provenance recorded locally.
	prov, prov_found := query_provenance(state, rhash)
	testing.expect(t, prov_found, "provenance must be recorded")
	testing.expect_value(t, prov.origin, Provenance_Origin.Local_Build)
	testing.expect_value(t, prov.record.output_hash, h_built)

	// Verify mode: remote cache matches local build -> Built_Locally with verified_reproducible = true.
	harness.has_cache = true
	copy(harness.cache_payload[:n_built], harness.builder_payload[:n_built])
	harness.cache_payload_len = n_built
	harness.cache_realisation = {
		recipe_hash       = rhash,
		output_hash       = h_built,
		output_kind       = .Tree,
		signer_public_key = trusted_key,
	}
	sbytes, _ := object_cache.realisation_signing_bytes(&harness.cache_realisation)
	harness.cache_realisation.signature = mock_sign_bytes(trusted_key, sbytes[:])

	res_verify := build_recipe(state, &spec, .Verify, policy, harness_cache_lookup, harness_builder_invoke, mock_verify, harness_sign_local, &harness)
	testing.expect_value(t, res_verify.outcome, pr.Recipe_Build_Outcome.Built_Locally)
	testing.expect(t, res_verify.verified_reproducible, "matching Verify build must mark verified_reproducible")
	testing.expect_value(t, state.counters.verify_agreements, u64(1))

	// Verify mode disagreement: local builder produces a different tree -> Refused(Verify_Disagreement).
	n_diff, h_diff := make_canonical_tree("out.module", make_hash(51), harness.builder_payload[:])
	harness.builder_payload_len = n_diff
	res_disagree := build_recipe(state, &spec, .Verify, policy, harness_cache_lookup, harness_builder_invoke, mock_verify, harness_sign_local, &harness)
	testing.expect_value(t, res_disagree.outcome, pr.Recipe_Build_Outcome.Refused)
	testing.expect_value(t, res_disagree.refusal, pr.Recipe_Refusal.Verify_Disagreement)
	testing.expect_value(t, res_disagree.output_hash, h_built)
	testing.expect_value(t, res_disagree.local_output_hash, h_diff)
	testing.expect_value(t, state.counters.verify_disagreements, u64(1))

	// Tampered remote cache payload in fresh state is refused immediately.
	state_init(state)
	harness.cache_payload[n_built - 1] ~= 0x01
	res_tampered := build_recipe(state, &spec, .Cache_First, policy, harness_cache_lookup, harness_builder_invoke, mock_verify, harness_sign_local, &harness)
	testing.expect_value(t, res_tampered.outcome, pr.Recipe_Build_Outcome.Refused)
	testing.expect_value(t, res_tampered.refusal, pr.Recipe_Refusal.Hash_Mismatch)

	// Build_Only ignores remote cache entirely and runs sandboxed builder.
	calls_before := harness.builder_calls
	res_bo := build_recipe(state, &spec, .Build_Only, policy, harness_cache_lookup, harness_builder_invoke, mock_verify, harness_sign_local, &harness)
	testing.expect_value(t, res_bo.outcome, pr.Recipe_Build_Outcome.Built_Locally)
	testing.expect_value(t, res_bo.output_hash, h_diff)
	testing.expect_value(t, harness.builder_calls, calls_before + 1)
}
