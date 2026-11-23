// Pure state machine for the delegated recipes service
// (src/md/features/recipes.md).
//
// Realises a Recipe_Spec strictly according to Build_Mode and
// object_cache.Substitution_Policy with zero dynamic allocation:
// 1. checks the local content-addressed store (re-verifying stored bytes);
// 2. checks remote object_cache via callback and strictly verifies signature,
//    trusted signer, recipe hash, output kind, and object/tree hash;
// 3. invokes the sandboxed builder with read-only inputs, empty output store,
//    frozen source_date, deterministic seed equal to recipe_hash, and zero
//    network;
// 4. hashes the builder's output with tree_hash (or BLAKE3 for blobs), compares
//    against the cached realisation in Verify mode, and records the signed
//    realisation and provenance in the local store.
//
// The local store is the memory of the service and its private store: each
// realisation is written to the private store with its output before the
// memory takes it, so a build of the same recipe after a start reads it
// back, checks its output against its hash, and builds nothing.
package recipes_core

import "modus:contract/blake3"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"

// Fixed-capacity limits for the in-memory local store of the recipes engine.
MAX_LOCAL_OBJECTS :: 32
MAX_LOCAL_REALISATIONS :: 32
MAX_OBJECT_BYTES :: 65536

// Where a recorded realisation came from for provenance auditing.
Provenance_Origin :: enum u8 {
	None         = 0,
	Local_Build  = 1,
	Remote_Cache = 2,
}

// Callback to query a remote object cache for a realisation and its payload.
Cache_Lookup_Proc :: #type proc "contextless" (
	recipe_hash: blake3.Hash,
	out_realisation: ^object_cache.Realisation_Record,
	out_payload: []u8,
	user_data: rawptr,
) -> (payload_length: int, found: bool)

// Callback to invoke a sandboxed builder process under the validated sandbox.
Builder_Invoke_Proc :: #type proc "contextless" (
	sandbox: ^pr.Builder_Sandbox_Spec,
	out_payload: []u8,
	user_data: rawptr,
) -> (payload_length: int, ok: bool)

// Callback to sign a locally built realisation with the principal's Ed25519 key.
Sign_Realisation_Proc :: #type proc "contextless" (
	signing_bytes: []u8,
	out_public_key: ^[object_cache.PUBLIC_KEY_SIZE]u8,
	out_signature: ^[object_cache.SIGNATURE_SIZE]u8,
	user_data: rawptr,
) -> bool

// One content-addressed object held in the local store.
Local_Object_Slot :: struct {
	active:  bool,
	hash:    blake3.Hash,
	kind:    object_cache.Cache_Object_Kind,
	length:  int,
	payload: [MAX_OBJECT_BYTES]u8,
}

// One recorded realisation and its provenance in the local store.
Local_Realisation_Slot :: struct {
	active:                bool,
	origin:                Provenance_Origin,
	verified_reproducible: bool,
	record:                object_cache.Realisation_Record,
}

// Aggregate counters for status inspection.
Recipes_Counters :: struct {
	total_builds:          u64,
	cache_hits_local:      u64,
	cache_hits_store:      u64, // The local hits that the private store answered, after a start.
	cache_hits_remote:     u64,
	local_builds:          u64,
	verify_agreements:     u64,
	verify_disagreements:  u64,
	total_refusals:        u64,
}

// Complete fixed-capacity state of the recipes build and cache engine.
Recipes_State :: struct {
	initialized:    bool,
	objects:        [MAX_LOCAL_OBJECTS]Local_Object_Slot,
	realisations:   [MAX_LOCAL_REALISATIONS]Local_Realisation_Slot,
	cache_staging:  [MAX_OBJECT_BYTES]u8,
	build_staging:  [MAX_OBJECT_BYTES]u8,
	counters:       Recipes_Counters,
	store:          pr.Private_Store_Port,
	// One realisation object of the private store: its head and its output.
	store_staging:  [pr.REALISATION_OBJECT_HEAD_SIZE + MAX_OBJECT_BYTES]u8,
}

// state_init zeroes state, binds the private store that keeps the
// realisations, and marks it ready.
state_init :: proc "contextless" (state: ^Recipes_State, store: pr.Private_Store_Port) {
	state^ = {}
	state.initialized = true
	state.store = store
}

// realisation_persist writes the realisation object of record and its
// output to the private store, before the memory takes them: a refusal of
// the store records nothing.
@(private = "file")
realisation_persist :: proc "contextless" (state: ^Recipes_State, record: ^object_cache.Realisation_Record, origin: Provenance_Origin, payload: []u8) -> pr.Recipe_Refusal {
	written, refusal := pr.encode_realisation_object(record, u64(origin), payload, state.store_staging[:])
	if refusal != .None {
		return refusal
	}
	name := pr.realisation_object_name(record.recipe_hash)
	if pr.private_store_write(&state.store, pr.private_object_name_text(&name), state.store_staging[:written]) != .Ok {
		return .Store_Failed
	}
	return .None
}

// realisation_recall reads the realisation of recipe_hash from the private
// store into the memory: found is false when the store holds none. A
// realisation whose output does not match its hash is Store_Damaged.
@(private = "file")
realisation_recall :: proc "contextless" (state: ^Recipes_State, recipe_hash: blake3.Hash, expected_kind: object_cache.Cache_Object_Kind) -> (found: bool, refusal: pr.Recipe_Refusal) {
	name := pr.realisation_object_name(recipe_hash)
	bytes, status := pr.private_store_read(&state.store, pr.private_object_name_text(&name), state.store_staging[:])
	switch status {
	case .Ok:
	case .Absent:
		return false, .None
	case .Failed:
		// A service with no store, or a store that does not answer: the
		// build goes on as a miss, and the record of its realisation then
		// fails with Store_Failed.
		return false, .None
	case .Too_Large:
		return false, .Store_Damaged
	}
	record, origin_word, payload, decode_refusal := pr.decode_realisation_object(bytes, recipe_hash, expected_kind)
	if decode_refusal != .None {
		return false, decode_refusal
	}
	origin := Provenance_Origin.Local_Build
	switch origin_word {
	case u64(Provenance_Origin.Local_Build):
		origin = .Local_Build
	case u64(Provenance_Origin.Remote_Cache):
		origin = .Remote_Cache
	case:
		return false, .Store_Damaged
	}
	if !store_local_object(state, record.output_hash, record.output_kind, payload) || !store_local_realisation(state, record, origin, false) {
		return false, .Store_Full
	}
	return true, .None
}

// cache_hit_count returns the builds that a cached realisation answered, from
// the local store or from a remote cache. The sum stops at the largest u64, so
// two large counters never wrap to a small count.
cache_hit_count :: proc "contextless" (state: ^Recipes_State) -> u64 {
	local := state.counters.cache_hits_local
	remote := state.counters.cache_hits_remote
	if remote > max(u64) - local {
		return max(u64)
	}
	return local + remote
}

@(private)
find_local_object :: proc "contextless" (state: ^Recipes_State, hash: blake3.Hash) -> ^Local_Object_Slot {
	for &slot in state.objects {
		if slot.active && slot.hash == hash {
			return &slot
		}
	}
	return nil
}

@(private = "file")
find_local_realisation :: proc "contextless" (state: ^Recipes_State, recipe_hash: blake3.Hash) -> ^Local_Realisation_Slot {
	for &slot in state.realisations {
		if slot.active && slot.record.recipe_hash == recipe_hash {
			return &slot
		}
	}
	return nil
}

@(private = "file")
store_local_object :: proc "contextless" (
	state: ^Recipes_State,
	hash: blake3.Hash,
	kind: object_cache.Cache_Object_Kind,
	payload: []u8,
) -> bool {
	if len(payload) > MAX_OBJECT_BYTES {
		return false
	}
	if existing := find_local_object(state, hash); existing != nil {
		return existing.kind == kind && existing.length == len(payload)
	}
	for &slot in state.objects {
		if !slot.active {
			slot.active = true
			slot.hash = hash
			slot.kind = kind
			slot.length = len(payload)
			copy(slot.payload[:len(payload)], payload)
			return true
		}
	}
	return false
}

@(private = "file")
store_local_realisation :: proc "contextless" (
	state: ^Recipes_State,
	record: object_cache.Realisation_Record,
	origin: Provenance_Origin,
	verified_reproducible: bool,
) -> bool {
	if existing := find_local_realisation(state, record.recipe_hash); existing != nil {
		existing.record = record
		existing.origin = origin
		existing.verified_reproducible = existing.verified_reproducible || verified_reproducible
		return true
	}
	for &slot in state.realisations {
		if !slot.active {
			slot = {
				active                = true,
				origin                = origin,
				verified_reproducible = verified_reproducible,
				record                = record,
			}
			return true
		}
	}
	return false
}

// build_recipe executes the full recipes.build pipeline:
//   local store -> remote object_cache (under Substitution_Policy) ->
//   sandboxed builder -> output hashing (tree_hash / BLAKE3) -> record realisation.
build_recipe :: proc "contextless" (
	state: ^Recipes_State,
	spec: ^pr.Recipe_Spec,
	mode: pr.Build_Mode,
	policy: object_cache.Substitution_Policy,
	cache_lookup: Cache_Lookup_Proc,
	builder_invoke: Builder_Invoke_Proc,
	verify_signature: object_cache.Signature_Verify_Proc,
	sign_realisation: Sign_Realisation_Proc,
	user_data: rawptr = nil,
) -> (result: pr.Recipe_Build_Result) {
	checked_mode, mode_ok := pr.build_mode_of_word(u64(mode))
	if !mode_ok {
		state.counters.total_refusals += 1
		return {outcome = .Refused, refusal = .Bad_Build_Mode}
	}
	sub_mode, sub_ok := pr.build_mode_to_substitution_mode(checked_mode)
	if !sub_ok {
		state.counters.total_refusals += 1
		return {outcome = .Refused, refusal = .Bad_Build_Mode}
	}

	rhash, hash_refusal := pr.recipe_hash(spec)
	if hash_refusal != .None {
		state.counters.total_refusals += 1
		return {outcome = .Refused, refusal = hash_refusal}
	}
	// recipe_hash refused a spec whose kinds name no member.
	expected_kind := spec.output_kind
	result.recipe_hash = rhash
	result.output_kind = expected_kind
	state.counters.total_builds += 1

	effective_policy := object_cache.Substitution_Policy {
		mode            = sub_mode,
		trusted_signers = policy.trusted_signers,
	}

	// Step 1: check local store for Cache_First and Cache_Only: the memory,
	// then the private store.
	if checked_mode == .Cache_First || checked_mode == .Cache_Only {
		recalled := false
		if find_local_realisation(state, rhash) == nil {
			found, recall_refusal := realisation_recall(state, rhash, expected_kind)
			if recall_refusal != .None {
				state.counters.total_refusals += 1
				return {outcome = .Refused, refusal = recall_refusal, recipe_hash = rhash, output_kind = expected_kind}
			}
			recalled = found
		}
		if existing_real := find_local_realisation(state, rhash); existing_real != nil {
			if obj := find_local_object(state, existing_real.record.output_hash); obj != nil && obj.kind == expected_kind {
				// Re-verify stored bytes against hash before trusting local cache.
				recomputed, check_ref := pr.recipe_hash_output(obj.kind, obj.payload[:obj.length])
				if check_ref == .None && recomputed == existing_real.record.output_hash {
					state.counters.cache_hits_local += 1
					if recalled {
						state.counters.cache_hits_store += 1
					}
					return {
						outcome               = .From_Cache,
						refusal               = .None,
						recipe_hash           = rhash,
						output_hash           = existing_real.record.output_hash,
						output_kind           = expected_kind,
						signer_public_key     = existing_real.record.signer_public_key,
						verified_reproducible = existing_real.verified_reproducible,
					}
				}
			}
		}
	}

	// Step 2: check remote object_cache for Cache_First, Cache_Only, and Verify.
	have_verified_cache := false
	cached_realisation: object_cache.Realisation_Record
	cached_payload_len := 0
	if checked_mode == .Cache_First || checked_mode == .Cache_Only || checked_mode == .Verify {
		if cache_lookup != nil {
			remote_real: object_cache.Realisation_Record
			payload_len, found := cache_lookup(rhash, &remote_real, state.cache_staging[:], user_data)
			if found {
				if payload_len < 0 || payload_len > MAX_OBJECT_BYTES {
					state.counters.total_refusals += 1
					result.outcome = .Refused
					result.refusal = .Malformed_Output
					return result
				}
				verified_hash, verify_refusal := pr.recipe_verify_cache_realisation(
					spec,
					effective_policy,
					&remote_real,
					state.cache_staging[:payload_len],
					verify_signature,
					user_data,
				)
				if verify_refusal == .None {
					have_verified_cache = true
					cached_realisation = remote_real
					cached_realisation.output_hash = verified_hash
					cached_payload_len = payload_len
				} else {
					// Tampered payload, bad signature, or malformed data from a
					// cache is always refused immediately. An untrusted signer
					// is refused in Cache_Only/Verify, and falls back to local
					// sandboxed build in Cache_First.
					if verify_refusal != .Untrusted_Realisation || checked_mode == .Cache_Only || checked_mode == .Verify {
						state.counters.total_refusals += 1
						result.outcome = .Refused
						result.refusal = verify_refusal
						return result
					}
				}
			}
		}

		if have_verified_cache && (checked_mode == .Cache_First || checked_mode == .Cache_Only) {
			if persist_refusal := realisation_persist(state, &cached_realisation, .Remote_Cache, state.cache_staging[:cached_payload_len]); persist_refusal != .None {
				state.counters.total_refusals += 1
				result.outcome = .Refused
				result.refusal = persist_refusal
				return result
			}
			if !store_local_object(state, cached_realisation.output_hash, expected_kind, state.cache_staging[:cached_payload_len]) {
				state.counters.total_refusals += 1
				result.outcome = .Refused
				result.refusal = .Store_Full
				return result
			}
			if !store_local_realisation(state, cached_realisation, .Remote_Cache, false) {
				state.counters.total_refusals += 1
				result.outcome = .Refused
				result.refusal = .Store_Full
				return result
			}
			state.counters.cache_hits_remote += 1
			return {
				outcome               = .From_Cache,
				refusal               = .None,
				recipe_hash           = rhash,
				output_hash           = cached_realisation.output_hash,
				output_kind           = expected_kind,
				signer_public_key     = cached_realisation.signer_public_key,
				verified_reproducible = false,
			}
		}

		if checked_mode == .Cache_Only {
			state.counters.total_refusals += 1
			result.outcome = .Refused
			result.refusal = .Cache_Miss
			return result
		}
	}

	// Step 3: invoke sandboxed builder (Build_Only, Cache_First fallback, or Verify).
	sandbox, sb_refusal := pr.builder_sandbox_prepare(spec)
	if sb_refusal != .None {
		state.counters.total_refusals += 1
		result.outcome = .Refused
		result.refusal = sb_refusal
		return result
	}
	if check_sb := pr.builder_sandbox_validate(&sandbox); check_sb != .None {
		state.counters.total_refusals += 1
		result.outcome = .Refused
		result.refusal = check_sb
		return result
	}
	if builder_invoke == nil {
		state.counters.total_refusals += 1
		result.outcome = .Refused
		result.refusal = .Builder_Failed
		return result
	}
	built_len, built_ok := builder_invoke(&sandbox, state.build_staging[:], user_data)
	if !built_ok || built_len < 0 || built_len > MAX_OBJECT_BYTES {
		state.counters.total_refusals += 1
		result.outcome = .Refused
		result.refusal = .Builder_Failed
		return result
	}

	// Step 4: hash builder output with tree_hash (for Tree) or BLAKE3 (for Blob).
	local_hash, out_refusal := pr.recipe_hash_output(expected_kind, state.build_staging[:built_len])
	if out_refusal != .None {
		state.counters.total_refusals += 1
		result.outcome = .Refused
		result.refusal = out_refusal
		return result
	}

	// Verify mode comparison against remote cache realisation.
	verified_match := false
	if checked_mode == .Verify && have_verified_cache {
		if local_hash != cached_realisation.output_hash {
			state.counters.verify_disagreements += 1
			state.counters.total_refusals += 1
			return {
				outcome               = .Refused,
				refusal               = .Verify_Disagreement,
				recipe_hash           = rhash,
				output_hash           = cached_realisation.output_hash,
				local_output_hash     = local_hash,
				output_kind           = expected_kind,
				signer_public_key     = cached_realisation.signer_public_key,
				verified_reproducible = false,
			}
		}
		state.counters.verify_agreements += 1
		verified_match = true
	}

	// Step 5: record output and signed realisation in local store.
	local_realisation := object_cache.Realisation_Record {
		recipe_hash = rhash,
		output_hash = local_hash,
		output_kind = expected_kind,
	}
	if sign_realisation != nil {
		if sign_bytes, sign_ok := object_cache.realisation_signing_bytes(&local_realisation); sign_ok {
			if !sign_realisation(sign_bytes[:], &local_realisation.signer_public_key, &local_realisation.signature, user_data) {
				state.counters.total_refusals += 1
				result.outcome = .Refused
				result.refusal = .Bad_Signature
				return result
			}
		}
	}

	if persist_refusal := realisation_persist(state, &local_realisation, .Local_Build, state.build_staging[:built_len]); persist_refusal != .None {
		state.counters.total_refusals += 1
		result.outcome = .Refused
		result.refusal = persist_refusal
		return result
	}
	if !store_local_object(state, local_hash, expected_kind, state.build_staging[:built_len]) {
		state.counters.total_refusals += 1
		result.outcome = .Refused
		result.refusal = .Store_Full
		return result
	}
	if !store_local_realisation(state, local_realisation, .Local_Build, verified_match) {
		state.counters.total_refusals += 1
		result.outcome = .Refused
		result.refusal = .Store_Full
		return result
	}
	state.counters.local_builds += 1
	return {
		outcome               = .Built_Locally,
		refusal               = .None,
		recipe_hash           = rhash,
		output_hash           = local_hash,
		local_output_hash     = local_hash,
		output_kind           = expected_kind,
		signer_public_key     = local_realisation.signer_public_key,
		verified_reproducible = verified_match,
	}
}

// query_provenance returns the locally stored realisation and origin for
// recipe_hash, or found = false if absent.
query_provenance :: proc "contextless" (state: ^Recipes_State, recipe_hash: blake3.Hash) -> (slot: Local_Realisation_Slot, found: bool) {
	if existing := find_local_realisation(state, recipe_hash); existing != nil {
		return existing^, true
	}
	return {}, false
}
