// The put of the recipes service (src/md/features/recipes.md, "The guest
// builder in the service"): an object kept in the private store by its
// hash, so a recipe names it as an input, or a guest build as its kernel
// or its initial archive. A caller keeps at most PUT_OBJECTS_PER_CALLER_MOST
// objects in one run of the service; the retention pass keeps them for the
// run, and past it only what a recipe or a realisation names.
package recipes_core

import "modus:contract/blake3"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"

// The bytes of the largest object that one put takes.
PUT_OBJECT_BYTES_MOST :: 32 * 1024
// The objects that one caller keeps in one run of the service.
PUT_OBJECTS_PER_CALLER_MOST :: 256
// The callers that put objects in one run of the service.
PUT_CALLERS_MOST :: 16

// The puts of one run of the service: the count of each caller, and the
// hash of each object, which the retention pass keeps.
Put_Ledger :: struct {
	callers:     [PUT_CALLERS_MOST]Put_Caller,
	hashes:      [PUT_CALLERS_MOST * PUT_OBJECTS_PER_CALLER_MOST]blake3.Hash,
	hash_count:  int,
}

Put_Caller :: struct {
	key:   u64, // The connection of the caller; 0: a free place.
	count: int,
}

// put_object checks one put and keeps its object: the kind word at its
// border, the size, the bytes against their kind (a tree must be a
// canonical MODTREE1 node), and the quota of the caller. A refused put
// keeps nothing and counts nothing. An object that this caller put before
// is kept again and counts once.
put_object :: proc "contextless" (state: ^Recipes_State, ledger: ^Put_Ledger, caller_key: u64, kind_word: i64, bytes: []u8) -> (hash: blake3.Hash, refusal: pr.Recipe_Refusal) {
	if kind_word < 0 {
		return {}, .Bad_Input_Kind
	}
	kind, kind_ok := object_cache.cache_object_kind_of_word(u64(kind_word))
	if !kind_ok {
		return {}, .Bad_Input_Kind
	}
	if len(bytes) == 0 {
		return {}, .Malformed_Output
	}
	if len(bytes) > PUT_OBJECT_BYTES_MOST {
		return {}, .Arguments_Too_Large
	}
	if caller_key == 0 {
		return {}, .Bad_Head_Value
	}
	hash, refusal = pr.recipe_hash_output(kind, bytes)
	if refusal != .None {
		return {}, refusal
	}
	known := false
	for index in 0 ..< ledger.hash_count {
		if ledger.hashes[index] == hash {
			known = true
			break
		}
	}
	caller: ^Put_Caller
	for &place in ledger.callers {
		if place.key == caller_key {
			caller = &place
			break
		}
	}
	if caller == nil && !known {
		for &place in ledger.callers {
			if place.key == 0 {
				caller = &place
				break
			}
		}
	}
	if !known && (caller == nil || caller.count >= PUT_OBJECTS_PER_CALLER_MOST || ledger.hash_count >= len(ledger.hashes)) {
		return {}, .Put_Quota_Reached
	}
	name := pr.blob_object_name(hash)
	if pr.private_store_write_large(&state.store, pr.private_object_name_text(&name), bytes) != .Ok {
		return {}, .Store_Failed
	}
	if !known {
		caller.key = caller_key
		caller.count += 1
		ledger.hashes[ledger.hash_count] = hash
		ledger.hash_count += 1
	}
	return hash, .None
}

// put_hashes gives the objects of this run's puts.
put_hashes :: proc "contextless" (ledger: ^Put_Ledger) -> []blake3.Hash {
	return ledger.hashes[:ledger.hash_count]
}
