// Paired-machine distributed recipe build and peer cache fetch dispatch
// (src/md/features/recipes.md, "Builds across paired machines").
//
// Maintains a bounded table of paired builders and peer caches (`Paired_Builder_Table`)
// and dispatches one ready uncached DAG leaf (`recipe_graph_dispatch_step`) across
// paired peers with strict MODTREE2 / BLAKE3 output hash verification, trusted
// signer Ed25519 realisation checks, and deterministic failover to local sandbox
// execution when a remote link drops (`Callee_Unavailable` or any `Change_In_Doubt`
// call outcome).
//
// This file imports base and contract packages only and allocates no memory.
package recipes_core

import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/enum_word"
import "modus:contract/machine_mesh"
import "modus:contract/machine_wire"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"

// Inline capacity: fast round-robin routing table for paired machines belonging
// to one principal on a local network or relay mesh.
PAIRED_BUILDER_CAPACITY :: 8

// Closed role assigned to a paired peer in Paired_Builder_Table.
Paired_Peer_Role :: enum u8 {
	Builder           = 1,
	Peer_Cache        = 2,
	Builder_And_Cache = 3,
}

// Closed health state of one paired peer during a dispatch run.
Paired_Peer_Health :: enum u8 {
	Ready       = 1,
	Unreachable = 2, // Link dropped (Callee_Unavailable or Change_In_Doubt).
	Refused     = 3, // Peer refused call (no grant or operation unsupported).
	Untrusted   = 4, // Peer returned a tampered hash or invalid signature.
}

// Closed outcome of a paired-machine dispatch step or table mutation.
Paired_Dispatch_Outcome :: enum u8 {
	Peer_Cache_Hit       = 1,
	Remote_Build_Ok      = 2,
	Local_Fallback_Ok    = 3,
	Verify_Agreed        = 4,
	Refused_Bad_Input    = 5,
	Refused_Table_Full   = 6,
	Refused_Bad_Peer     = 7,
	Refused_Peer_Lacks_Use = 8,
	Refused_Cache_Miss   = 9,
	Refused_Local_Failed = 10,
	Refused_Determinism_Mismatch = 11,
	Refused_Verify_Incomplete    = 12,
}

// One paired peer entry inside Paired_Builder_Table.
Paired_Builder_Entry :: struct {
	identity: [machine_mesh.PUBLIC_KEY_SIZE]u8,
	role:     Paired_Peer_Role,
	uses:     machine_wire.Machine_Uses,
	health:   Paired_Peer_Health,
}

// Deterministic round-robin routing table of paired remote builders and caches.
Paired_Builder_Table :: struct {
	initialized:   bool,
	own_identity:  [machine_mesh.PUBLIC_KEY_SIZE]u8,
	count:         u32,
	cursor:        u32,
	entries:       [PAIRED_BUILDER_CAPACITY]Paired_Builder_Entry,
	dispatched:    u64,
	cache_hits:    u64,
	remote_builds: u64,
	local_builds:  u64,
	failovers:     u64,
	hash_faults:   u64,
	untrusted_skips: u64,
}

// Callback querying a paired peer cache over an outbound remote link for a
// signed realisation and its output bytes (MODTREE2 for Tree, raw for Blob).
Paired_Cache_Fetch_Proc :: #type proc "contextless" (
	peer: ^Paired_Builder_Entry,
	recipe_hash: blake3.Hash,
	out_record: ^object_cache.Realisation_Record,
	out_payload: []u8,
	user_data: rawptr,
) -> (payload_length: int, outcome: call_outcome.Call_Outcome)

// Callback dispatching a recipe build to a paired remote builder over an
// outbound remote link, returning its signed realisation and output bytes.
Paired_Remote_Build_Proc :: #type proc "contextless" (
	peer: ^Paired_Builder_Entry,
	spec: ^pr.Recipe_Spec,
	recipe_hash: blake3.Hash,
	out_record: ^object_cache.Realisation_Record,
	out_payload: []u8,
	user_data: rawptr,
) -> (payload_length: int, outcome: call_outcome.Call_Outcome)

// Callbacks and verification policy passed to recipe_graph_dispatch_step.
Paired_Dispatch_Hooks :: struct {
	mode:               pr.Build_Mode,
	trusted_signers:    [][object_cache.PUBLIC_KEY_SIZE]u8,
	verify_signature:   object_cache.Signature_Verify_Proc,
	remote_cache_fetch: Paired_Cache_Fetch_Proc,
	remote_build:       Paired_Remote_Build_Proc,
	local_sandbox_build: Builder_Invoke_Proc,
	user_data:          rawptr,
}

// Result of dispatching one uncached DAG leaf recipe.
Paired_Dispatch_Result :: struct {
	outcome:             Paired_Dispatch_Outcome,
	recipe_hash:         blake3.Hash,
	output_hash:         blake3.Hash,
	second_output_hash:  blake3.Hash,
	output_kind:         object_cache.Cache_Object_Kind,
	output_length:       int,
	serving_peer:        [machine_mesh.PUBLIC_KEY_SIZE]u8,
	signer_public_key:   [object_cache.PUBLIC_KEY_SIZE]u8,
	fell_back_to_local:  bool,
	failovers_attempted: u32,
}

// Single borders converting raw words into closed enum members.

paired_peer_role_of_word :: proc "contextless" (word: u64) -> (role: Paired_Peer_Role, ok: bool) {
	return enum_word.member_of_word(Paired_Peer_Role, word)
}

paired_peer_health_of_word :: proc "contextless" (word: u64) -> (health: Paired_Peer_Health, ok: bool) {
	return enum_word.member_of_word(Paired_Peer_Health, word)
}

paired_dispatch_outcome_of_word :: proc "contextless" (word: u64) -> (outcome: Paired_Dispatch_Outcome, ok: bool) {
	return enum_word.member_of_word(Paired_Dispatch_Outcome, word)
}

// paired_builder_table_init initializes table with this machine's identity key.
// Refuses nil table or an all-zero own_identity without mutating table.
paired_builder_table_init :: proc "contextless" (
	table: ^Paired_Builder_Table,
	own_identity: [machine_mesh.PUBLIC_KEY_SIZE]u8,
) -> Paired_Dispatch_Outcome {
	if table == nil {
		return .Refused_Bad_Input
	}
	if machine_mesh.key_is_zero(own_identity) {
		return .Refused_Bad_Peer
	}
	table^ = {
		initialized  = true,
		own_identity = own_identity,
	}
	return .Remote_Build_Ok
}

// paired_builder_table_add registers one paired machine in table.
// Refuses zero keys, self-identity, duplicate keys, unknown roles, missing
// Roles/Objects remote uses, or a full table without mutating table.
paired_builder_table_add :: proc "contextless" (
	table: ^Paired_Builder_Table,
	identity: [machine_mesh.PUBLIC_KEY_SIZE]u8,
	role: Paired_Peer_Role,
	uses: machine_wire.Machine_Uses,
) -> Paired_Dispatch_Outcome {
	if table == nil || !table.initialized {
		return .Refused_Bad_Input
	}
	checked_role, role_ok := paired_peer_role_of_word(u64(role))
	if !role_ok {
		return .Refused_Bad_Peer
	}
	if machine_mesh.key_is_zero(identity) || machine_mesh.keys_equal_constant_time(identity, table.own_identity) {
		return .Refused_Bad_Peer
	}
	if .Roles not_in uses || .Objects not_in uses {
		return .Refused_Peer_Lacks_Use
	}
	for index in u32(0) ..< table.count {
		if machine_mesh.keys_equal_constant_time(table.entries[index].identity, identity) {
			return .Refused_Bad_Peer
		}
	}
	if table.count >= PAIRED_BUILDER_CAPACITY {
		return .Refused_Table_Full
	}
	table.entries[table.count] = {
		identity = identity,
		role     = checked_role,
		uses     = uses,
		health   = .Ready,
	}
	table.count += 1
	return .Remote_Build_Ok
}

// paired_builder_table_mark_health updates one peer's health state after a
// link failure or recovery. Refuses unknown health words or out-of-range indices.
paired_builder_table_mark_health :: proc "contextless" (
	table: ^Paired_Builder_Table,
	peer_index: u32,
	health: Paired_Peer_Health,
) -> bool {
	if table == nil || !table.initialized || peer_index >= table.count {
		return false
	}
	checked, ok := paired_peer_health_of_word(u64(health))
	if !ok {
		return false
	}
	table.entries[peer_index].health = checked
	return true
}

@(private = "file")
peer_serves_cache :: proc "contextless" (role: Paired_Peer_Role) -> bool {
	return role == .Peer_Cache || role == .Builder_And_Cache
}

@(private = "file")
peer_serves_builder :: proc "contextless" (role: Paired_Peer_Role) -> bool {
	return role == .Builder || role == .Builder_And_Cache
}

@(private = "file")
outcome_is_link_drop :: proc "contextless" (outcome: call_outcome.Call_Outcome) -> bool {
	if outcome == .Callee_Unavailable {
		return true
	}
	return call_outcome.EFFECT_GROUP_OF[outcome] == .Change_In_Doubt
}

@(private = "file")
signer_is_trusted :: proc "contextless" (
	signer: [object_cache.PUBLIC_KEY_SIZE]u8,
	trusted_signers: [][object_cache.PUBLIC_KEY_SIZE]u8,
) -> bool {
	if machine_mesh.key_is_zero(signer) {
		return false
	}
	for candidate in trusted_signers {
		if machine_mesh.keys_equal_constant_time(candidate, signer) {
			return true
		}
	}
	return false
}

@(private = "file")
Verified_Remote_Check :: enum u8 {
	Ok             = 0,
	Untrusted_Key  = 1,
	Tampered_Or_Bad = 2,
}

// verify_remote_realisation_and_output checks every cryptographic invariant on
// a remote peer response: recipe hash match, output kind match, trusted signer
// membership, Ed25519 signature over canonical signing bytes, and exact content
// digest (MODTREE2 canonical tree hash for Tree, BLAKE3 hash for Blob).
@(private = "file")
verify_remote_realisation_and_output :: proc "contextless" (
	hooks: ^Paired_Dispatch_Hooks,
	recipe_hash: blake3.Hash,
	expected_kind: object_cache.Cache_Object_Kind,
	record: ^object_cache.Realisation_Record,
	payload: []u8,
) -> Verified_Remote_Check {
	if record.recipe_hash != recipe_hash || record.output_kind != expected_kind {
		return .Tampered_Or_Bad
	}
	if !signer_is_trusted(record.signer_public_key, hooks.trusted_signers) {
		return .Untrusted_Key
	}
	if hooks.verify_signature == nil {
		return .Tampered_Or_Bad
	}
	signing_bytes, sign_ok := object_cache.realisation_signing_bytes(record)
	if !sign_ok {
		return .Tampered_Or_Bad
	}
	if !hooks.verify_signature(record.signer_public_key, signing_bytes[:], record.signature, hooks.user_data) {
		return .Tampered_Or_Bad
	}
	computed_hash, hash_ref := pr.recipe_hash_output(expected_kind, payload)
	if hash_ref != .None || computed_hash != record.output_hash {
		return .Tampered_Or_Bad
	}
	return .Ok
}

// invoke_local_sandbox validates the builder sandbox specification and runs the
// local sandboxed builder callback, verifying the produced MODTREE2 / BLAKE3
// output digest before returning.
@(private = "file")
invoke_local_sandbox :: proc "contextless" (
	spec: ^pr.Recipe_Spec,
	sandbox: ^pr.Builder_Sandbox_Spec,
	hooks: ^Paired_Dispatch_Hooks,
	output_buffer: []u8,
) -> (output_hash: blake3.Hash, output_length: int, ok: bool) {
	if hooks.local_sandbox_build == nil || sandbox == nil {
		return {}, 0, false
	}
	if pr.builder_sandbox_prepare(spec, sandbox) != .None {
		return {}, 0, false
	}
	if pr.builder_sandbox_validate(sandbox) != .None {
		return {}, 0, false
	}
	payload, built := hooks.local_sandbox_build(sandbox, output_buffer, hooks.user_data)
	if !built || len(payload) > len(output_buffer) {
		return {}, 0, false
	}
	if len(payload) > 0 && raw_data(payload) != raw_data(output_buffer) {
		copy(output_buffer, payload)
	}
	computed_hash, hash_ref := pr.recipe_hash_output(spec.output_kind, output_buffer[:len(payload)])
	if hash_ref != .None {
		return {}, 0, false
	}
	return computed_hash, len(payload), true
}

// recipe_graph_dispatch_step dispatches one uncached ready DAG leaf recipe
// across paired peer caches and paired remote builders according to hooks.mode.
//
// - Prefer_Cache: queries Ready peer caches first, then round-robins Ready
//   paired builders, verifying signed realisations and MODTREE2/BLAKE3 outputs.
//   Any link drop (Callee_Unavailable or Change_In_Doubt) marks the peer
//   Unreachable and fails over deterministically to the next peer or to the
//   local sandbox builder.
// - Cache_Only: queries Ready peer caches only; never builds remotely or locally.
// - Build_Only: executes directly in the local sandbox without contacting peers.
// - Verify: obtains one verified remote build and one local sandbox build and
//   compares their verified output hashes (Refused_Determinism_Mismatch on diff).
//
// Caller supplies sandbox (avoiding a 90 KiB stack allocation) and output_buffer.
recipe_graph_dispatch_step :: proc "contextless" (
	table: ^Paired_Builder_Table,
	spec: ^pr.Recipe_Spec,
	sandbox: ^pr.Builder_Sandbox_Spec,
	hooks: ^Paired_Dispatch_Hooks,
	output_buffer: []u8,
	verify_buffer: []u8 = nil,
) -> (result: Paired_Dispatch_Result) {
	if table == nil || !table.initialized || spec == nil || hooks == nil {
		result.outcome = .Refused_Bad_Input
		return result
	}
	mode, mode_ok := pr.build_mode_of_word(u64(hooks.mode))
	if !mode_ok {
		result.outcome = .Refused_Bad_Input
		return result
	}
	recipe_hash, hash_ref := pr.recipe_hash(spec)
	if hash_ref != .None {
		result.outcome = .Refused_Bad_Input
		return result
	}
	result.recipe_hash = recipe_hash
	result.output_kind = spec.output_kind
	table.dispatched += 1

	// Step 1: Build_Only runs strictly on the local sandbox.
	if mode == .Build_Only {
		local_hash, local_len, local_ok := invoke_local_sandbox(spec, sandbox, hooks, output_buffer)
		if !local_ok {
			result.outcome = .Refused_Local_Failed
			return result
		}
		table.local_builds += 1
		result.outcome = .Local_Fallback_Ok
		result.output_hash = local_hash
		result.output_length = local_len
		result.serving_peer = table.own_identity
		result.fell_back_to_local = false
		return result
	}

	// Step 2: Query Ready paired peer caches for Prefer_Cache and Cache_Only.
	if (mode == .Prefer_Cache || mode == .Cache_Only) && hooks.remote_cache_fetch != nil {
		for index in u32(0) ..< table.count {
			peer := &table.entries[index]
			if peer.health != .Ready || !peer_serves_cache(peer.role) {
				continue
			}
			record: object_cache.Realisation_Record
			length, outcome := hooks.remote_cache_fetch(peer, recipe_hash, &record, output_buffer, hooks.user_data)
			if outcome_is_link_drop(outcome) {
				peer.health = .Unreachable
				table.failovers += 1
				result.failovers_attempted += 1
				continue
			}
			if outcome != .Succeeded {
				if outcome == .Grant_Or_Right_Missing || outcome == .Operation_Unsupported {
					peer.health = .Refused
				}
				continue
			}
			if length < 0 || length > len(output_buffer) {
				peer.health = .Untrusted
				table.hash_faults += 1
				result.failovers_attempted += 1
				continue
			}
			check := verify_remote_realisation_and_output(hooks, recipe_hash, spec.output_kind, &record, output_buffer[:length])
			switch check {
			case .Ok:
				table.cache_hits += 1
				result.outcome = .Peer_Cache_Hit
				result.output_hash = record.output_hash
				result.output_length = length
				result.serving_peer = peer.identity
				result.signer_public_key = record.signer_public_key
				return result
			case .Untrusted_Key:
				table.untrusted_skips += 1
				continue
			case .Tampered_Or_Bad:
				peer.health = .Untrusted
				table.hash_faults += 1
				result.failovers_attempted += 1
				continue
			}
		}
	}

	if mode == .Cache_Only {
		result.outcome = .Refused_Cache_Miss
		return result
	}

	// Step 3: Dispatch to Ready paired remote builders in round-robin order.
	remote_succeeded := false
	remote_hash: blake3.Hash
	remote_length := 0
	remote_peer_id: [machine_mesh.PUBLIC_KEY_SIZE]u8
	remote_signer: [object_cache.PUBLIC_KEY_SIZE]u8

	if hooks.remote_build != nil && table.count > 0 {
		start := table.cursor % table.count
		for step in u32(0) ..< table.count {
			index := (start + step) % table.count
			peer := &table.entries[index]
			if peer.health != .Ready || !peer_serves_builder(peer.role) {
				continue
			}
			table.cursor = (index + 1) % table.count
			record: object_cache.Realisation_Record
			length, outcome := hooks.remote_build(peer, spec, recipe_hash, &record, output_buffer, hooks.user_data)
			if outcome_is_link_drop(outcome) {
				peer.health = .Unreachable
				table.failovers += 1
				result.failovers_attempted += 1
				continue
			}
			if outcome != .Succeeded {
				peer.health = .Refused
				table.failovers += 1
				result.failovers_attempted += 1
				continue
			}
			if length < 0 || length > len(output_buffer) {
				peer.health = .Untrusted
				table.hash_faults += 1
				table.failovers += 1
				result.failovers_attempted += 1
				continue
			}
			check := verify_remote_realisation_and_output(hooks, recipe_hash, spec.output_kind, &record, output_buffer[:length])
			switch check {
			case .Ok:
				table.remote_builds += 1
				remote_succeeded = true
				remote_hash = record.output_hash
				remote_length = length
				remote_peer_id = peer.identity
				remote_signer = record.signer_public_key
			case .Untrusted_Key:
				table.untrusted_skips += 1
				table.failovers += 1
				result.failovers_attempted += 1
			case .Tampered_Or_Bad:
				peer.health = .Untrusted
				table.hash_faults += 1
				table.failovers += 1
				result.failovers_attempted += 1
			}
			if remote_succeeded {
				break
			}
		}
	}

	if mode == .Prefer_Cache {
		if remote_succeeded {
			result.outcome = .Remote_Build_Ok
			result.output_hash = remote_hash
			result.output_length = remote_length
			result.serving_peer = remote_peer_id
			result.signer_public_key = remote_signer
			return result
		}
		// Deterministic fallback to local sandbox execution when no paired
		// builder succeeded or links dropped.
		local_hash, local_len, local_ok := invoke_local_sandbox(spec, sandbox, hooks, output_buffer)
		if !local_ok {
			result.outcome = .Refused_Local_Failed
			return result
		}
		table.local_builds += 1
		result.outcome = .Local_Fallback_Ok
		result.output_hash = local_hash
		result.output_length = local_len
		result.serving_peer = table.own_identity
		result.fell_back_to_local = true
		return result
	}

	// Step 4: Verify mode requires both a verified remote build and a verified
	// local sandbox build whose content hashes match exactly.
	if !remote_succeeded {
		result.outcome = .Refused_Verify_Incomplete
		return result
	}
	scratch := verify_buffer != nil ? verify_buffer : output_buffer
	local_hash, local_len, local_ok := invoke_local_sandbox(spec, sandbox, hooks, scratch)
	if !local_ok {
		result.outcome = .Refused_Local_Failed
		return result
	}
	table.local_builds += 1
	result.output_hash = remote_hash
	result.second_output_hash = local_hash
	result.output_length = remote_length
	result.serving_peer = remote_peer_id
	result.signer_public_key = remote_signer
	if local_hash != remote_hash || local_len != remote_length {
		result.outcome = .Refused_Determinism_Mismatch
		return result
	}
	result.outcome = .Verify_Agreed
	return result
}
