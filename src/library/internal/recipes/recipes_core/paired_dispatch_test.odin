#+build !freestanding
package recipes_core

import "base:runtime"
import "core:crypto/ed25519"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/machine_mesh"
import "modus:contract/machine_wire"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"

@(private = "file")
pd_keypair :: proc(seed_byte: u8) -> (priv: ed25519.Private_Key, pub: [machine_mesh.PUBLIC_KEY_SIZE]u8) {
	seed: [ed25519.PRIVATE_KEY_SIZE]u8
	for idx in 0 ..< len(seed) {
		seed[idx] = seed_byte + u8(idx * 17 + 9)
	}
	ok := ed25519.private_key_set_bytes(&priv, seed[:])
	assert(ok)
	ed25519.private_key_public_bytes(&priv, pub[:])
	return priv, pub
}

@(private = "file")
pd_verify_ed25519 :: proc "contextless" (
	public_key: [object_cache.PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [object_cache.SIGNATURE_SIZE]u8,
	_: rawptr,
) -> bool {
	context = runtime.default_context()
	pub_copy := public_key
	sig_copy := signature
	parsed: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&parsed, pub_copy[:]) {
		return false
	}
	return ed25519.verify(&parsed, message, sig_copy[:])
}

@(private = "file")
pd_sign_record :: proc(
	recipe_hash: blake3.Hash,
	output_hash: blake3.Hash,
	output_kind: object_cache.Cache_Object_Kind,
	priv: ^ed25519.Private_Key,
	pub: [object_cache.PUBLIC_KEY_SIZE]u8,
) -> object_cache.Realisation_Record {
	record := object_cache.Realisation_Record {
		recipe_hash       = recipe_hash,
		output_hash       = output_hash,
		output_kind       = output_kind,
		signer_public_key = pub,
	}
	sign_bytes, ok := object_cache.realisation_signing_bytes(&record)
	assert(ok)
	ed25519.sign(priv, sign_bytes[:], record.signature[:])
	return record
}

@(private = "file")
pd_make_tree_bytes :: proc(tag: string, out: []u8) -> (written: int, digest: blake3.Hash) {
	leaf_hash := blake3.hash(transmute([]u8)tag)
	entry, ref := tree_hash.tree_entry_make(.Object, "out", leaf_hash)
	assert(ref == .None)
	entries := [1]tree_hash.Tree_Entry{entry}
	w, enc_ref := tree_hash.tree_encode(entries[:], out)
	assert(enc_ref == .None)
	h, h_ref := pr.recipe_hash_output(.Tree, out[:w])
	assert(h_ref == .None)
	return w, h
}

@(private = "file")
pd_make_recipe :: proc(spec: ^pr.Recipe_Spec) {
	spec^ = {}
	spec.builder_hash = blake3.hash(transmute([]u8)string("paired-builder-v1"))
	spec.output_kind = .Tree
	spec.source_date_unix = 1_700_000_000
	inp, ref := pr.recipe_input_make("src", .Blob, blake3.hash(transmute([]u8)string("source-bytes")))
	assert(ref == .None)
	spec.input_count = 1
	spec.inputs[0] = inp
}

@(private = "file")
Mock_Peer_Mode :: enum u8 {
	Valid_Tree      = 0,
	Untrusted_Signer = 1,
	Tampered_Output = 2,
	Drop_Unavailable = 3,
	Drop_In_Doubt   = 4,
	Miss            = 5,
	Different_Tree  = 6,
}

@(private = "file")
Mock_Mesh :: struct {
	peer_ids:       [4][machine_mesh.PUBLIC_KEY_SIZE]u8,
	peer_modes:     [4]Mock_Peer_Mode,
	trusted_priv:   ed25519.Private_Key,
	trusted_pub:    [object_cache.PUBLIC_KEY_SIZE]u8,
	untrusted_priv: ed25519.Private_Key,
	untrusted_pub:  [object_cache.PUBLIC_KEY_SIZE]u8,
	local_tag:      string,
	remote_calls:   int,
	cache_calls:    int,
	local_calls:    int,
}

@(private = "file")
mock_peer_mode :: proc "contextless" (mesh: ^Mock_Mesh, id: [machine_mesh.PUBLIC_KEY_SIZE]u8) -> Mock_Peer_Mode {
	for idx in 0 ..< len(mesh.peer_ids) {
		if machine_mesh.keys_equal_constant_time(mesh.peer_ids[idx], id) {
			return mesh.peer_modes[idx]
		}
	}
	return .Miss
}

@(private = "file")
mock_respond :: proc "contextless" (
	mesh: ^Mock_Mesh,
	mode: Mock_Peer_Mode,
	recipe_hash: blake3.Hash,
	out_record: ^object_cache.Realisation_Record,
	out_payload: []u8,
) -> (int, call_outcome.Call_Outcome) {
	context = runtime.default_context()
	switch mode {
	case .Miss:
		return 0, .Nothing_Has_That_Name
	case .Drop_Unavailable:
		return 0, .Callee_Unavailable
	case .Drop_In_Doubt:
		return 0, .Connection_Ended_During_The_Call
	case .Valid_Tree:
		n, digest := pd_make_tree_bytes("canonical-output", out_payload)
		out_record^ = pd_sign_record(recipe_hash, digest, .Tree, &mesh.trusted_priv, mesh.trusted_pub)
		return n, .Succeeded
	case .Different_Tree:
		n, digest := pd_make_tree_bytes("divergent-remote-output", out_payload)
		out_record^ = pd_sign_record(recipe_hash, digest, .Tree, &mesh.trusted_priv, mesh.trusted_pub)
		return n, .Succeeded
	case .Untrusted_Signer:
		n, digest := pd_make_tree_bytes("canonical-output", out_payload)
		out_record^ = pd_sign_record(recipe_hash, digest, .Tree, &mesh.untrusted_priv, mesh.untrusted_pub)
		return n, .Succeeded
	case .Tampered_Output:
		n, digest := pd_make_tree_bytes("canonical-output", out_payload)
		out_record^ = pd_sign_record(recipe_hash, digest, .Tree, &mesh.trusted_priv, mesh.trusted_pub)
		out_payload[n - 1] ~= 0xFF
		return n, .Succeeded
	}
	return 0, .Nothing_Has_That_Name
}

@(private = "file")
mock_cache_fetch :: proc "contextless" (
	peer: ^Paired_Builder_Entry,
	recipe_hash: blake3.Hash,
	out_record: ^object_cache.Realisation_Record,
	out_payload: []u8,
	user_data: rawptr,
) -> (int, call_outcome.Call_Outcome) {
	mesh := (^Mock_Mesh)(user_data)
	mesh.cache_calls += 1
	return mock_respond(mesh, mock_peer_mode(mesh, peer.identity), recipe_hash, out_record, out_payload)
}

@(private = "file")
mock_remote_build :: proc "contextless" (
	peer: ^Paired_Builder_Entry,
	_: ^pr.Recipe_Spec,
	recipe_hash: blake3.Hash,
	out_record: ^object_cache.Realisation_Record,
	out_payload: []u8,
	user_data: rawptr,
) -> (int, call_outcome.Call_Outcome) {
	mesh := (^Mock_Mesh)(user_data)
	mesh.remote_calls += 1
	return mock_respond(mesh, mock_peer_mode(mesh, peer.identity), recipe_hash, out_record, out_payload)
}

@(private = "file")
mock_local_build :: proc "contextless" (
	_: ^pr.Builder_Sandbox_Spec,
	staging: []u8,
	user_data: rawptr,
) -> ([]u8, bool) {
	context = runtime.default_context()
	mesh := (^Mock_Mesh)(user_data)
	mesh.local_calls += 1
	n, _ := pd_make_tree_bytes(mesh.local_tag, staging)
	return staging[:n], true
}

@(test)
paired_dispatch_enum_borders_refuse_unknown_words :: proc(t: ^testing.T) {
	for role in Paired_Peer_Role {
		got, ok := paired_peer_role_of_word(u64(role))
		testing.expect(t, ok && got == role)
	}
	_, bad_role_0 := paired_peer_role_of_word(0)
	_, bad_role_4 := paired_peer_role_of_word(4)
	testing.expect(t, !bad_role_0 && !bad_role_4)

	for health in Paired_Peer_Health {
		got, ok := paired_peer_health_of_word(u64(health))
		testing.expect(t, ok && got == health)
	}
	_, bad_h_0 := paired_peer_health_of_word(0)
	_, bad_h_5 := paired_peer_health_of_word(5)
	testing.expect(t, !bad_h_0 && !bad_h_5)

	for out in Paired_Dispatch_Outcome {
		got, ok := paired_dispatch_outcome_of_word(u64(out))
		testing.expect(t, ok && got == out)
	}
	_, bad_o_0 := paired_dispatch_outcome_of_word(0)
	_, bad_o_13 := paired_dispatch_outcome_of_word(13)
	testing.expect(t, !bad_o_0 && !bad_o_13)
}

@(test)
paired_builder_table_refuses_invalid_peers_and_capacity_overflow :: proc(t: ^testing.T) {
	_, own_id := pd_keypair(1)
	zero_id: [machine_mesh.PUBLIC_KEY_SIZE]u8
	full_uses := machine_wire.Machine_Uses{.Roles, .Objects}

	table: Paired_Builder_Table
	testing.expect_value(t, paired_builder_table_init(nil, own_id), Paired_Dispatch_Outcome.Refused_Bad_Input)
	testing.expect_value(t, paired_builder_table_init(&table, zero_id), Paired_Dispatch_Outcome.Refused_Bad_Peer)
	testing.expect(t, !table.initialized)

	testing.expect_value(t, paired_builder_table_init(&table, own_id), Paired_Dispatch_Outcome.Remote_Build_Ok)
	testing.expect_value(t, paired_builder_table_add(&table, zero_id, .Builder, full_uses), Paired_Dispatch_Outcome.Refused_Bad_Peer)
	testing.expect_value(t, paired_builder_table_add(&table, own_id, .Builder, full_uses), Paired_Dispatch_Outcome.Refused_Bad_Peer)
	testing.expect_value(t, paired_builder_table_add(&table, own_id, Paired_Peer_Role(99), full_uses), Paired_Dispatch_Outcome.Refused_Bad_Peer)

	_, p1 := pd_keypair(10)
	testing.expect_value(t, paired_builder_table_add(&table, p1, .Builder, {.Roles}), Paired_Dispatch_Outcome.Refused_Peer_Lacks_Use)
	testing.expect_value(t, paired_builder_table_add(&table, p1, .Builder, {.Objects}), Paired_Dispatch_Outcome.Refused_Peer_Lacks_Use)
	testing.expect_value(t, table.count, u32(0))

	// Fill to exact capacity and verify duplicate + capacity+1 refusals.
	for idx in u8(0) ..< u8(PAIRED_BUILDER_CAPACITY) {
		_, pid := pd_keypair(20 + idx)
		testing.expect_value(t, paired_builder_table_add(&table, pid, .Builder, full_uses), Paired_Dispatch_Outcome.Remote_Build_Ok)
	}
	_, dup_id := pd_keypair(20)
	testing.expect_value(t, paired_builder_table_add(&table, dup_id, .Builder, full_uses), Paired_Dispatch_Outcome.Refused_Bad_Peer)
	_, extra_id := pd_keypair(99)
	testing.expect_value(t, paired_builder_table_add(&table, extra_id, .Builder, full_uses), Paired_Dispatch_Outcome.Refused_Table_Full)
	testing.expect_value(t, table.count, u32(PAIRED_BUILDER_CAPACITY))

	testing.expect(t, !paired_builder_table_mark_health(&table, PAIRED_BUILDER_CAPACITY, .Unreachable))
	testing.expect(t, !paired_builder_table_mark_health(&table, 0, Paired_Peer_Health(0)))
	testing.expect(t, paired_builder_table_mark_health(&table, 0, .Unreachable))
	testing.expect_value(t, table.entries[0].health, Paired_Peer_Health.Unreachable)
}

@(test)
paired_dispatch_peer_cache_hit_and_tamper_refusal :: proc(t: ^testing.T) {
	mesh := new(Mock_Mesh)
	defer free(mesh)
	mesh.trusted_priv, mesh.trusted_pub = pd_keypair(30)
	mesh.untrusted_priv, mesh.untrusted_pub = pd_keypair(31)
	mesh.local_tag = "canonical-output"

	_, own_id := pd_keypair(1)
	_, mesh.peer_ids[0] = pd_keypair(2)
	_, mesh.peer_ids[1] = pd_keypair(3)
	_, mesh.peer_ids[2] = pd_keypair(4)
	mesh.peer_modes[0] = .Untrusted_Signer
	mesh.peer_modes[1] = .Tampered_Output
	mesh.peer_modes[2] = .Valid_Tree

	table: Paired_Builder_Table
	testing.expect_value(t, paired_builder_table_init(&table, own_id), Paired_Dispatch_Outcome.Remote_Build_Ok)
	full_uses := machine_wire.Machine_Uses{.Roles, .Objects}
	for i in 0 ..< 3 {
		testing.expect_value(t, paired_builder_table_add(&table, mesh.peer_ids[i], .Peer_Cache, full_uses), Paired_Dispatch_Outcome.Remote_Build_Ok)
	}

	spec := new(pr.Recipe_Spec)
	sandbox := new(pr.Builder_Sandbox_Spec)
	defer free(spec)
	defer free(sandbox)
	pd_make_recipe(spec)

	trusted := [1][object_cache.PUBLIC_KEY_SIZE]u8{mesh.trusted_pub}
	hooks := Paired_Dispatch_Hooks {
		mode                = .Prefer_Cache,
		trusted_signers     = trusted[:],
		verify_signature    = pd_verify_ed25519,
		remote_cache_fetch  = mock_cache_fetch,
		remote_build        = mock_remote_build,
		local_sandbox_build = mock_local_build,
		user_data           = mesh,
	}

	out_buf: [512]u8
	res := recipe_graph_dispatch_step(&table, spec, sandbox, &hooks, out_buf[:])
	testing.expect_value(t, res.outcome, Paired_Dispatch_Outcome.Peer_Cache_Hit)
	testing.expect(t, machine_mesh.keys_equal_constant_time(res.serving_peer, mesh.peer_ids[2]))
	testing.expect_value(t, table.entries[1].health, Paired_Peer_Health.Untrusted)
	testing.expect_value(t, table.untrusted_skips, u64(1))
	testing.expect_value(t, table.hash_faults, u64(1))
	testing.expect_value(t, mesh.local_calls, 0)
}

@(test)
paired_dispatch_link_drop_failover_and_local_sandbox_fallback :: proc(t: ^testing.T) {
	mesh := new(Mock_Mesh)
	defer free(mesh)
	mesh.trusted_priv, mesh.trusted_pub = pd_keypair(40)
	mesh.untrusted_priv, mesh.untrusted_pub = pd_keypair(41)
	mesh.local_tag = "canonical-output"

	_, own_id := pd_keypair(1)
	_, mesh.peer_ids[0] = pd_keypair(5)
	_, mesh.peer_ids[1] = pd_keypair(6)
	mesh.peer_modes[0] = .Drop_Unavailable
	mesh.peer_modes[1] = .Drop_In_Doubt

	table: Paired_Builder_Table
	testing.expect_value(t, paired_builder_table_init(&table, own_id), Paired_Dispatch_Outcome.Remote_Build_Ok)
	full_uses := machine_wire.Machine_Uses{.Roles, .Objects}
	testing.expect_value(t, paired_builder_table_add(&table, mesh.peer_ids[0], .Builder, full_uses), Paired_Dispatch_Outcome.Remote_Build_Ok)
	testing.expect_value(t, paired_builder_table_add(&table, mesh.peer_ids[1], .Builder, full_uses), Paired_Dispatch_Outcome.Remote_Build_Ok)

	spec := new(pr.Recipe_Spec)
	sandbox := new(pr.Builder_Sandbox_Spec)
	defer free(spec)
	defer free(sandbox)
	pd_make_recipe(spec)

	trusted := [1][object_cache.PUBLIC_KEY_SIZE]u8{mesh.trusted_pub}
	hooks := Paired_Dispatch_Hooks {
		mode                = .Prefer_Cache,
		trusted_signers     = trusted[:],
		verify_signature    = pd_verify_ed25519,
		remote_cache_fetch  = mock_cache_fetch,
		remote_build        = mock_remote_build,
		local_sandbox_build = mock_local_build,
		user_data           = mesh,
	}

	out_buf: [512]u8
	res := recipe_graph_dispatch_step(&table, spec, sandbox, &hooks, out_buf[:])
	testing.expect_value(t, res.outcome, Paired_Dispatch_Outcome.Local_Fallback_Ok)
	testing.expect(t, res.fell_back_to_local)
	testing.expect_value(t, res.failovers_attempted, u32(2))
	testing.expect_value(t, table.entries[0].health, Paired_Peer_Health.Unreachable)
	testing.expect_value(t, table.entries[1].health, Paired_Peer_Health.Unreachable)
	testing.expect_value(t, mesh.local_calls, 1)

	// Recover builder 1 as healthy -> next dispatch succeeds remotely via builder 1.
	mesh.peer_modes[1] = .Valid_Tree
	testing.expect(t, paired_builder_table_mark_health(&table, 1, .Ready))
	res2 := recipe_graph_dispatch_step(&table, spec, sandbox, &hooks, out_buf[:])
	testing.expect_value(t, res2.outcome, Paired_Dispatch_Outcome.Remote_Build_Ok)
	testing.expect(t, !res2.fell_back_to_local)
	testing.expect(t, machine_mesh.keys_equal_constant_time(res2.serving_peer, mesh.peer_ids[1]))
	testing.expect_value(t, res2.output_hash, res.output_hash)
}

@(test)
paired_dispatch_cache_only_build_only_and_verify_modes :: proc(t: ^testing.T) {
	mesh := new(Mock_Mesh)
	defer free(mesh)
	mesh.trusted_priv, mesh.trusted_pub = pd_keypair(50)
	mesh.untrusted_priv, mesh.untrusted_pub = pd_keypair(51)
	mesh.local_tag = "canonical-output"

	_, own_id := pd_keypair(1)
	_, mesh.peer_ids[0] = pd_keypair(7)
	mesh.peer_modes[0] = .Valid_Tree

	table: Paired_Builder_Table
	testing.expect_value(t, paired_builder_table_init(&table, own_id), Paired_Dispatch_Outcome.Remote_Build_Ok)
	full_uses := machine_wire.Machine_Uses{.Roles, .Objects}
	testing.expect_value(t, paired_builder_table_add(&table, mesh.peer_ids[0], .Builder, full_uses), Paired_Dispatch_Outcome.Remote_Build_Ok)

	spec := new(pr.Recipe_Spec)
	sandbox := new(pr.Builder_Sandbox_Spec)
	defer free(spec)
	defer free(sandbox)
	pd_make_recipe(spec)

	trusted := [1][object_cache.PUBLIC_KEY_SIZE]u8{mesh.trusted_pub}
	hooks := Paired_Dispatch_Hooks {
		mode                = .Cache_Only,
		trusted_signers     = trusted[:],
		verify_signature    = pd_verify_ed25519,
		remote_cache_fetch  = mock_cache_fetch,
		remote_build        = mock_remote_build,
		local_sandbox_build = mock_local_build,
		user_data           = mesh,
	}

	out_buf: [512]u8
	verify_buf: [512]u8

	// Cache_Only refuses when no Peer_Cache holds the realisation.
	res_cache := recipe_graph_dispatch_step(&table, spec, sandbox, &hooks, out_buf[:])
	testing.expect_value(t, res_cache.outcome, Paired_Dispatch_Outcome.Refused_Cache_Miss)
	testing.expect_value(t, mesh.remote_calls, 0)
	testing.expect_value(t, mesh.local_calls, 0)

	// Build_Only skips peers and builds locally.
	hooks.mode = .Build_Only
	res_build := recipe_graph_dispatch_step(&table, spec, sandbox, &hooks, out_buf[:])
	testing.expect_value(t, res_build.outcome, Paired_Dispatch_Outcome.Local_Fallback_Ok)
	testing.expect_value(t, mesh.remote_calls, 0)
	testing.expect_value(t, mesh.local_calls, 1)

	// Verify succeeds when remote and local produce identical MODTREE2 output.
	hooks.mode = .Verify
	res_agree := recipe_graph_dispatch_step(&table, spec, sandbox, &hooks, out_buf[:], verify_buf[:])
	testing.expect_value(t, res_agree.outcome, Paired_Dispatch_Outcome.Verify_Agreed)
	testing.expect_value(t, res_agree.output_hash, res_agree.second_output_hash)

	// Verify refuses Determinism_Mismatch when remote diverges from local.
	mesh.peer_modes[0] = .Different_Tree
	res_div := recipe_graph_dispatch_step(&table, spec, sandbox, &hooks, out_buf[:], verify_buf[:])
	testing.expect_value(t, res_div.outcome, Paired_Dispatch_Outcome.Refused_Determinism_Mismatch)
	testing.expect(t, res_div.output_hash != res_div.second_output_hash)
}
