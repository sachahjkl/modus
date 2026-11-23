// The put of the recipes service (src/md/features/recipes.md, "The guest
// builder in the service"): an object kept in the private store by its
// hash, so a recipe names it as an input, or a guest build as its kernel
// or its initial archive. A principal keeps at most
// PUT_OBJECTS_PER_PRINCIPAL_MOST objects in one window of an hour; the
// retention pass keeps the puts of the window and of the window before it,
// and past them only what a recipe or a realisation names.
package recipes_core

import "modus:contract/blake3"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"

// The bytes of the largest object that one put takes.
PUT_OBJECT_BYTES_MOST :: 32 * 1024
// The objects that one principal keeps in one window.
PUT_OBJECTS_PER_PRINCIPAL_MOST :: 256
// The principals that put objects in one window.
PUT_PRINCIPALS_MOST :: 16
// The length of a window, in seconds of the clock of the system.
PUT_WINDOW_SECONDS :: u64(3_600)

// The puts of one window: the count of each principal, and the hash of
// each object, which the retention pass keeps.
Put_Window :: struct {
	principals: [PUT_PRINCIPALS_MOST]Put_Principal,
	hashes:     [PUT_PRINCIPALS_MOST * PUT_OBJECTS_PER_PRINCIPAL_MOST]blake3.Hash,
	hash_count: int,
}

Put_Principal :: struct {
	key:   u64, // The principal of the caller, plus one; 0: a free place.
	count: int,
}

// The puts of the window of now and of the window before it.
Put_Ledger :: struct {
	window:   u64, // The number of the window of now: the seconds of the clock divided by PUT_WINDOW_SECONDS.
	started:  bool,
	now:      Put_Window,
	previous: Put_Window,
}

// put_ledger_age moves the ledger to the window of now_seconds: a new
// window makes the window of now the window before, and a gap of two
// windows or more forgets both. A clock that goes back keeps the window.
put_ledger_age :: proc "contextless" (ledger: ^Put_Ledger, now_seconds: u64) {
	window := now_seconds / PUT_WINDOW_SECONDS
	if !ledger.started {
		ledger.started = true
		ledger.window = window
		return
	}
	if window <= ledger.window {
		return
	}
	if window == ledger.window + 1 {
		ledger.previous = ledger.now
	} else {
		ledger.previous = {}
	}
	ledger.now = {}
	ledger.window = window
}

@(private = "file")
window_holds :: proc "contextless" (window: ^Put_Window, hash: blake3.Hash) -> bool {
	for index in 0 ..< window.hash_count {
		if window.hashes[index] == hash {
			return true
		}
	}
	return false
}

// put_object checks one put and keeps its object: the kind word at its
// border, the size, the bytes against their kind (a tree must be a
// canonical MODTREE1 node), and the quota of the principal of the caller in
// the window of now_seconds. A refused put keeps nothing and counts
// nothing. An object put before in this window is kept again and counts
// once. principal is the number of the principal of the caller.
put_object :: proc "contextless" (state: ^Recipes_State, ledger: ^Put_Ledger, principal: u64, now_seconds: u64, kind_word: i64, bytes: []u8) -> (hash: blake3.Hash, refusal: pr.Recipe_Refusal) {
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
	if principal == max(u64) {
		return {}, .Bad_Head_Value
	}
	hash, refusal = pr.recipe_hash_output(kind, bytes)
	if refusal != .None {
		return {}, refusal
	}
	put_ledger_age(ledger, now_seconds)
	window := &ledger.now
	key := principal + 1
	known := window_holds(window, hash)
	holder: ^Put_Principal
	for &place in window.principals {
		if place.key == key {
			holder = &place
			break
		}
	}
	if holder == nil && !known {
		for &place in window.principals {
			if place.key == 0 {
				holder = &place
				break
			}
		}
	}
	if !known && (holder == nil || holder.count >= PUT_OBJECTS_PER_PRINCIPAL_MOST || window.hash_count >= len(window.hashes)) {
		return {}, .Put_Quota_Reached
	}
	name := pr.blob_object_name(hash)
	if pr.private_store_write(&state.store, pr.private_object_name_text(&name), bytes) != .Ok {
		return {}, .Store_Failed
	}
	if !known {
		holder.key = key
		holder.count += 1
		window.hashes[window.hash_count] = hash
		window.hash_count += 1
	}
	return hash, .None
}

// put_hashes gives the objects of the puts of the window of now and of the
// window before it, in hashes, which holds both.
put_hashes :: proc "contextless" (ledger: ^Put_Ledger, hashes: ^[2 * PUT_PRINCIPALS_MOST * PUT_OBJECTS_PER_PRINCIPAL_MOST]blake3.Hash) -> []blake3.Hash {
	count := copy(hashes[:], ledger.now.hashes[:ledger.now.hash_count])
	count += copy(hashes[count:], ledger.previous.hashes[:ledger.previous.hash_count])
	return hashes[:count]
}
