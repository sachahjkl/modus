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
// The local store is the private store of the service, and an index of it
// in the memory of the service (src/md/features/recipes.md, "The local
// store"): each output is the object "blob_<hash>" of any size that the
// store holds, and each realisation the object "realisation_<recipe hash>"
// that names it. The output is written before its realisation, so a
// realisation never names an output that the store lacks; a build of the
// same recipe after a start reads them back, checks the output against its
// hash, and builds nothing. A retention rule removes the oldest
// realisations when an output would pass the share of the store.
package recipes_core

import "modus:contract/blake3"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"

// The entries of the index of the local store in memory. A full index
// forgets the entry that was used least recently: the store keeps it, and
// a later build reads it back.
OBJECT_INDEX_CAPACITY :: 1024
REALISATION_INDEX_CAPACITY :: 1024

// The bytes of the output of a builder that the service runs itself (the
// tree of the inputs), and of an object that a remote cache gives: a C
// module comes from its call host in a memory object of its own size. The
// bytes of one output object of the store: one object of a cache.
STAGING_BYTES :: 65536
OUTPUT_BYTES_MOST :: object_cache.MAX_OBJECT_PAYLOAD_BYTES

// The bytes of one read of an object of the store: the call region of the
// storage service holds them with the arguments.
STORE_PIECE_BYTES :: 32 * 1024

// The retention rule: the outputs and their realisations keep at most this
// share of the blocks of the store; the rest holds the recipes, the inputs
// that a writer keeps, and the blocks that a commit writes.
RETENTION_PERCENT :: 75
// The oldest realisations that one listing of the store finds, and the
// entries of one page of the listing.
RETENTION_BATCH :: 16
RETENTION_LIST_ROWS :: 32
// The blocks of the store: 4 KiB each.
STORE_BLOCK_BYTES :: 4096

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

// Callback to invoke a sandboxed builder process under the validated
// sandbox. The builder writes its output into staging, or into memory of
// its own that stays mapped until build_recipe returns, and gives the view
// of the output: a C module comes in a memory object of its own size.
Builder_Invoke_Proc :: #type proc "contextless" (
	sandbox: ^pr.Builder_Sandbox_Spec,
	staging: []u8,
	user_data: rawptr,
) -> (payload: []u8, ok: bool)

// Callback to sign a locally built realisation with the principal's Ed25519 key.
Sign_Realisation_Proc :: #type proc "contextless" (
	signing_bytes: []u8,
	out_public_key: ^[object_cache.PUBLIC_KEY_SIZE]u8,
	out_signature: ^[object_cache.SIGNATURE_SIZE]u8,
	user_data: rawptr,
) -> bool

// One output object of the store that the index knows: its bytes are the
// object blob_object_name(hash).
Local_Object_Slot :: struct {
	active:   bool,
	hash:     blake3.Hash,
	kind:     object_cache.Cache_Object_Kind,
	length:   u64,
	last_use: u64,
}

// One recorded realisation and its provenance in the local store.
Local_Realisation_Slot :: struct {
	active:                bool,
	origin:                Provenance_Origin,
	verified_reproducible: bool,
	record:                object_cache.Realisation_Record,
	last_use:              u64,
}

// Aggregate counters for status inspection.
Recipes_Counters :: struct {
	total_builds:          u64,
	cache_hits_local:      u64,
	cache_hits_store:      u64, // The local hits that the private store answered, after a start.
	cache_hits_remote:     u64,
	retention_removals:    u64, // The realisations that the retention rule removed from the store.
	local_builds:          u64,
	verify_agreements:     u64,
	verify_disagreements:  u64,
	total_refusals:        u64,
}

// Complete state of the recipes build and cache engine: the index of the
// local store, and the memory of one build.
Recipes_State :: struct {
	initialized:    bool,
	objects:        [OBJECT_INDEX_CAPACITY]Local_Object_Slot,
	realisations:   [REALISATION_INDEX_CAPACITY]Local_Realisation_Slot,
	uses:           u64, // The clock of the index: each use of an entry takes the next value.
	cache_staging:  [STAGING_BYTES]u8,
	build_staging:  [STAGING_BYTES]u8,
	counters:       Recipes_Counters,
	// The sandbox of the build that runs: about 90 KiB, too large for the
	// stack of the service.
	sandbox:        pr.Builder_Sandbox_Spec,
	store:          pr.Private_Store_Port,
	store_head:     [pr.REALISATION_OBJECT_HEAD_SIZE]u8,
	// One piece of an object that the service reads: the hash of an output
	// is checked piece by piece, so an output costs no memory of its size.
	store_piece:    [STORE_PIECE_BYTES]u8,
	// The listing of the store of the retention rule.
	list_rows:      [RETENTION_LIST_ROWS]pr.Private_Store_Entry,
	list_names:     [RETENTION_LIST_ROWS * 64]u8,
}

// state_init zeroes state, binds the private store that keeps the
// realisations, and marks it ready.
state_init :: proc "contextless" (state: ^Recipes_State, store: pr.Private_Store_Port) {
	state^ = {}
	state.initialized = true
	state.store = store
}

// realisation_persist keeps an output and its realisation in the private
// store, before the index takes them: the retention rule makes room, the
// output goes first, then the realisation that names it. A refusal of the
// store records nothing.
@(private = "file")
realisation_persist :: proc "contextless" (state: ^Recipes_State, record: ^object_cache.Realisation_Record, origin: Provenance_Origin, payload: []u8) -> pr.Recipe_Refusal {
	if u64(len(payload)) > OUTPUT_BYTES_MOST {
		return .Malformed_Output
	}
	if refusal := retention_make_room(state, u64(len(payload))); refusal != .None {
		return refusal
	}
	output_name := pr.blob_object_name(record.output_hash)
	if pr.private_store_write(&state.store, pr.private_object_name_text(&output_name), payload) != .Ok {
		return .Store_Failed
	}
	written, refusal := pr.encode_realisation_object(record, u64(origin), u64(len(payload)), state.store_head[:])
	if refusal != .None {
		return refusal
	}
	name := pr.realisation_object_name(record.recipe_hash)
	if pr.private_store_write(&state.store, pr.private_object_name_text(&name), state.store_head[:written]) != .Ok {
		return .Store_Failed
	}
	return .None
}

// What the read of an output of the store found.
Stored_Output :: enum u8 {
	Whole, // The bytes have the length and the hash of the realisation.
	Absent, // The store holds no such object: a retention removed an output that two recipes share.
	Damaged, // The bytes are not the bytes that the hash names.
}

// stored_output_check reads the output of hash from the store, piece by
// piece, and checks its length and its hash. A tree is read whole into the
// staging of the cache, as its hash needs its encoding whole: a tree has at
// most STAGING_BYTES.
@(private = "file")
stored_output_check :: proc "contextless" (state: ^Recipes_State, hash: blake3.Hash, kind: object_cache.Cache_Object_Kind, length: u64) -> Stored_Output {
	name := pr.blob_object_name(hash)
	text := pr.private_object_name_text(&name)
	switch kind {
	case .Tree:
		if length > STAGING_BYTES {
			return .Damaged
		}
		bytes, outcome := stored_output_read(state, text, length, state.cache_staging[:length])
		if outcome != .Whole {
			return outcome
		}
		recomputed, refusal := pr.recipe_hash_output(.Tree, bytes)
		return refusal == .None && recomputed == hash ? .Whole : .Damaged
	case .Blob:
		hasher := blake3.hasher_make()
		read: u64 = 0
		for {
			bytes, status := pr.private_store_read_range(&state.store, text, read, state.store_piece[:])
			switch status {
			case .Ok:
			case .Absent:
				return read == 0 ? .Absent : .Damaged
			case .Too_Large, .Failed:
				return .Damaged
			}
			if len(bytes) == 0 {
				break
			}
			read += u64(len(bytes))
			if read > length {
				return .Damaged
			}
			blake3.hasher_update(&hasher, bytes)
		}
		return read == length && blake3.hasher_finish(&hasher) == hash ? .Whole : .Damaged
	}
	return .Damaged
}

// stored_output_read reads the object name of the store into into, of
// length bytes, by pieces.
@(private = "file")
stored_output_read :: proc "contextless" (state: ^Recipes_State, name: string, length: u64, into: []u8) -> (bytes: []u8, outcome: Stored_Output) {
	read: u64 = 0
	for read < length {
		piece, status := pr.private_store_read_range(&state.store, name, read, into[read:length])
		switch status {
		case .Ok:
		case .Absent:
			return nil, read == 0 ? .Absent : .Damaged
		case .Too_Large, .Failed:
			return nil, .Damaged
		}
		if len(piece) == 0 {
			return nil, .Damaged
		}
		read += u64(len(piece))
	}
	// One byte more than the realisation says is an object of another size.
	if extra, status := pr.private_store_read_range(&state.store, name, length, state.store_piece[:1]); status != .Ok || len(extra) != 0 {
		return nil, .Damaged
	}
	return into[:length], .Whole
}

// realisation_recall reads the realisation of recipe_hash from the private
// store into the index: found is false when the store holds none. A
// realisation that does not decode is Store_Damaged.
@(private = "file")
realisation_recall :: proc "contextless" (state: ^Recipes_State, recipe_hash: blake3.Hash, expected_kind: object_cache.Cache_Object_Kind) -> (found: bool, refusal: pr.Recipe_Refusal) {
	name := pr.realisation_object_name(recipe_hash)
	bytes, status := pr.private_store_read(&state.store, pr.private_object_name_text(&name), state.store_head[:])
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
	record, origin_word, output_length, decode_refusal := pr.decode_realisation_object(bytes, recipe_hash, expected_kind)
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
	store_local_object(state, record.output_hash, record.output_kind, output_length)
	store_local_realisation(state, record, origin, false)
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

@(private = "file")
use_next :: proc "contextless" (state: ^Recipes_State) -> u64 {
	state.uses += 1
	return state.uses
}

@(private)
find_local_object :: proc "contextless" (state: ^Recipes_State, hash: blake3.Hash) -> ^Local_Object_Slot {
	for &slot in state.objects {
		if slot.active && slot.hash == hash {
			slot.last_use = use_next(state)
			return &slot
		}
	}
	return nil
}

@(private = "file")
find_local_realisation :: proc "contextless" (state: ^Recipes_State, recipe_hash: blake3.Hash) -> ^Local_Realisation_Slot {
	for &slot in state.realisations {
		if slot.active && slot.record.recipe_hash == recipe_hash {
			slot.last_use = use_next(state)
			return &slot
		}
	}
	return nil
}

// store_local_object puts an output of the store in the index: a free
// entry, or the entry used least recently, which the index forgets.
@(private = "file")
store_local_object :: proc "contextless" (state: ^Recipes_State, hash: blake3.Hash, kind: object_cache.Cache_Object_Kind, length: u64) {
	if existing := find_local_object(state, hash); existing != nil {
		existing.kind, existing.length = kind, length
		return
	}
	place := &state.objects[0]
	for &slot in state.objects {
		if !slot.active {
			place = &slot
			break
		}
		if slot.last_use < place.last_use {
			place = &slot
		}
	}
	place^ = {active = true, hash = hash, kind = kind, length = length, last_use = use_next(state)}
}

// store_local_realisation puts a realisation in the index, as
// store_local_object puts an output.
@(private = "file")
store_local_realisation :: proc "contextless" (
	state: ^Recipes_State,
	record: object_cache.Realisation_Record,
	origin: Provenance_Origin,
	verified_reproducible: bool,
) {
	if existing := find_local_realisation(state, record.recipe_hash); existing != nil {
		existing.record = record
		existing.origin = origin
		existing.verified_reproducible = existing.verified_reproducible || verified_reproducible
		return
	}
	place := &state.realisations[0]
	for &slot in state.realisations {
		if !slot.active {
			place = &slot
			break
		}
		if slot.last_use < place.last_use {
			place = &slot
		}
	}
	place^ = {
		active                = true,
		origin                = origin,
		verified_reproducible = verified_reproducible,
		record                = record,
		last_use              = use_next(state),
	}
}

// retention_make_room keeps the outputs and the realisations under
// RETENTION_PERCENT of the blocks of the store: before an output of bytes,
// it removes the oldest realisations, by the commit of their object, and
// their outputs, until the output fits. An output past the whole share is
// Store_Full at once, and removes nothing. A store with no counts or no
// listing has no rule: its own refusal bounds it.
@(private)
retention_make_room :: proc "contextless" (state: ^Recipes_State, bytes: u64) -> pr.Recipe_Refusal {
	if state.store.usage == nil || state.store.list == nil {
		return .None
	}
	// The blocks of the output, the node of its blocks and the head.
	needed := i64((bytes + STORE_BLOCK_BYTES - 1) / STORE_BLOCK_BYTES) + 2
	fits, refusal := retention_fits(state, needed)
	for refusal == .None && !fits {
		// One listing finds a batch of the oldest; each remove is followed
		// by a count, so the rule removes no more than the output needs.
		oldest: [RETENTION_BATCH]Retention_Candidate
		count, list_refusal := retention_oldest(state, oldest[:])
		if list_refusal != .None {
			return list_refusal
		}
		if count == 0 {
			return .Store_Full
		}
		for &candidate in oldest[:count] {
			if refusal = retention_remove(state, &candidate); refusal != .None {
				return refusal
			}
			if fits, refusal = retention_fits(state, needed); fits || refusal != .None {
				break
			}
		}
	}
	return refusal
}

// retention_fits says if needed blocks more stay under the share of the
// store. A need past the whole share is Store_Full: no remove helps.
@(private = "file")
retention_fits :: proc "contextless" (state: ^Recipes_State, needed: i64) -> (fits: bool, refusal: pr.Recipe_Refusal) {
	blocks, limit, status := pr.private_store_usage(&state.store)
	if status != .Ok || blocks < 0 || limit < 0 {
		return false, .Store_Failed
	}
	share := limit / 100 * RETENTION_PERCENT + limit % 100 * RETENTION_PERCENT / 100
	if needed > share {
		return false, .Store_Full
	}
	return blocks <= share - needed, .None
}

// One realisation that the retention rule can remove: its name and the
// commit of its last change.
Retention_Candidate :: struct {
	name:       [64]u8,
	length:     int,
	generation: i64,
}

// retention_oldest lists the store and gives its oldest realisations,
// oldest first, at most len(oldest).
@(private = "file")
retention_oldest :: proc "contextless" (state: ^Recipes_State, oldest: []Retention_Candidate) -> (count: int, refusal: pr.Recipe_Refusal) {
	after: [64]u8
	after_length := 0
	for {
		page, status := pr.private_store_list(&state.store, string(after[:after_length]), state.list_rows[:], state.list_names[:])
		if status != .Ok {
			return 0, .Store_Failed
		}
		if len(page) == 0 {
			return count, .None
		}
		for row in page {
			name := string(state.list_names[row.name_offset:][:row.name_count])
			if len(name) > len(after) {
				return 0, .Store_Failed
			}
			after_length = copy(after[:], name)
			if len(name) <= len(pr.REALISATION_OBJECT_PREFIX) || name[:len(pr.REALISATION_OBJECT_PREFIX)] != pr.REALISATION_OBJECT_PREFIX {
				continue
			}
			// The candidates stay sorted, the oldest first: a newer one than
			// each of a full list is no candidate.
			place := count
			for place > 0 && oldest[place - 1].generation > row.generation {
				place -= 1
			}
			if place == len(oldest) {
				continue
			}
			last := min(count, len(oldest) - 1)
			for index := last; index > place; index -= 1 {
				oldest[index] = oldest[index - 1]
			}
			oldest[place] = {generation = row.generation}
			oldest[place].length = copy(oldest[place].name[:], name)
			count = min(count + 1, len(oldest))
		}
	}
}

// retention_remove removes one realisation, then its output, from the
// store and from the index. Its output goes too when another realisation
// names it: that realisation then finds no output, and builds again.
@(private = "file")
retention_remove :: proc "contextless" (state: ^Recipes_State, candidate: ^Retention_Candidate) -> pr.Recipe_Refusal {
	name := string(candidate.name[:candidate.length])
	head, status := pr.private_store_read(&state.store, name, state.store_head[:])
	output_hash: blake3.Hash
	has_output := false
	if status == .Ok && len(head) == pr.REALISATION_OBJECT_HEAD_SIZE {
		// The hashes are read as they are: the remove does not trust the
		// head, and a head that does not decode goes too.
		recipe_hash: blake3.Hash
		copy(recipe_hash[:], head[8:8 + blake3.HASH_SIZE])
		copy(output_hash[:], head[8 + blake3.HASH_SIZE:8 + 2 * blake3.HASH_SIZE])
		has_output = true
		for &slot in state.realisations {
			if slot.active && slot.record.recipe_hash == recipe_hash {
				slot = {}
			}
		}
	}
	if removed := pr.private_store_remove(&state.store, name); removed != .Ok && removed != .Absent {
		return .Store_Failed
	}
	if has_output {
		output_name := pr.blob_object_name(output_hash)
		if removed := pr.private_store_remove(&state.store, pr.private_object_name_text(&output_name)); removed != .Ok && removed != .Absent {
			return .Store_Failed
		}
		for &slot in state.objects {
			if slot.active && slot.hash == output_hash {
				slot = {}
			}
		}
	}
	state.counters.retention_removals += 1
	return .None
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
				// The bytes of the store are checked against the hash before
				// a hit. An output that is absent or damaged is a miss: the
				// build writes it again.
				if stored_output_check(state, obj.hash, obj.kind, obj.length) == .Whole {
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
				if payload_len < 0 || payload_len > len(state.cache_staging) {
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
			store_local_object(state, cached_realisation.output_hash, expected_kind, u64(cached_payload_len))
			store_local_realisation(state, cached_realisation, .Remote_Cache, false)
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
	sandbox := &state.sandbox
	sb_refusal := pr.builder_sandbox_prepare(spec, sandbox)
	if sb_refusal != .None {
		state.counters.total_refusals += 1
		result.outcome = .Refused
		result.refusal = sb_refusal
		return result
	}
	if check_sb := pr.builder_sandbox_validate(sandbox); check_sb != .None {
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
	built, built_ok := builder_invoke(sandbox, state.build_staging[:], user_data)
	if !built_ok {
		state.counters.total_refusals += 1
		result.outcome = .Refused
		result.refusal = .Builder_Failed
		return result
	}

	// Step 4: hash builder output with tree_hash (for Tree) or BLAKE3 (for
	// Blob). A blob past one object of a cache is Malformed_Output.
	local_hash, out_refusal := pr.recipe_hash_output(expected_kind, built)
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

	if persist_refusal := realisation_persist(state, &local_realisation, .Local_Build, built); persist_refusal != .None {
		state.counters.total_refusals += 1
		result.outcome = .Refused
		result.refusal = persist_refusal
		return result
	}
	store_local_object(state, local_hash, expected_kind, u64(len(built)))
	store_local_realisation(state, local_realisation, .Local_Build, verified_match)
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

// output_length gives the bytes of an output of the local store by its
// hash: the module of a C build that build_recipe built or substituted.
// found is false when the index holds no such output.
output_length :: proc "contextless" (state: ^Recipes_State, hash: blake3.Hash) -> (length: u64, found: bool) {
	slot := find_local_object(state, hash)
	if slot == nil {
		return 0, false
	}
	return slot.length, true
}

// output_read reads an output of the local store into into, of
// output_length bytes at least, and checks the bytes against the hash:
// Cache_Miss when the store does not hold it, Store_Damaged when its bytes
// are not the bytes of the hash, Buffer_Too_Small for a short into.
output_read :: proc "contextless" (state: ^Recipes_State, hash: blake3.Hash, into: []u8) -> (bytes: []u8, refusal: pr.Recipe_Refusal) {
	slot := find_local_object(state, hash)
	if slot == nil {
		return nil, .Cache_Miss
	}
	if u64(len(into)) < slot.length {
		return nil, .Buffer_Too_Small
	}
	name := pr.blob_object_name(hash)
	read, outcome := stored_output_read(state, pr.private_object_name_text(&name), slot.length, into)
	switch outcome {
	case .Whole:
	case .Absent:
		return nil, .Cache_Miss
	case .Damaged:
		return nil, .Store_Damaged
	}
	recomputed, output_refusal := pr.recipe_hash_output(slot.kind, read)
	if output_refusal != .None || recomputed != hash {
		return nil, .Store_Damaged
	}
	return read, .None
}

// query_provenance returns the locally stored realisation and origin for
// recipe_hash, or found = false if absent.
query_provenance :: proc "contextless" (state: ^Recipes_State, recipe_hash: blake3.Hash) -> (slot: Local_Realisation_Slot, found: bool) {
	if existing := find_local_realisation(state, recipe_hash); existing != nil {
		return existing^, true
	}
	return {}, false
}
