// The put of the recipes service (src/md/features/recipes.md, "The guest
// builder in the service"): an object kept in the private store by its exact
// 64 lowercase hexadecimal hash, so a recipe names it as an input, or a guest
// build as its kernel or its initial archive. A principal keeps at most
// PUT_OBJECTS_PER_PRINCIPAL_MOST objects and PUT_BYTES_PER_PRINCIPAL_MOST
// bytes in one window of an hour, and every put obeys the 75 %
// RETENTION_PERCENT guard of the store; the retention pass keeps the puts of
// the window and of the window before it, and past them only what a recipe or
// a realisation names.
package recipes_core

import "modus:contract/blake3"
import "modus:contract/object_cache"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"

// Format/call-region bound: largest inline object accepted by recipes.put.
PUT_OBJECT_BYTES_MOST :: 32 * 1024
// Policy bound matching C_SOURCE_BYTES_LIMIT and disk_process.MAX_MODULE_BYTES:
// largest object accepted by recipes.put_memory in one lent memory object.
PUT_MEMORY_BYTES_MOST :: u64(64 * 1024 * 1024)
// Policy bound: objects that one principal keeps in one hourly window.
PUT_OBJECTS_PER_PRINCIPAL_MOST :: 256
// Policy bound: total bytes that one principal ingests in one hourly window
// (prevents store-exhaustion DoS across large put_memory calls).
PUT_BYTES_PER_PRINCIPAL_MOST :: u64(64 * 1024 * 1024)
// Policy bound: distinct principals tracked in one hourly window.
PUT_PRINCIPALS_MOST :: 16
// Policy bound: length of one quota window in seconds of the system clock.
PUT_WINDOW_SECONDS :: u64(3_600)

// The puts of one window: the count and bytes of each principal, and the hash
// of each object, which the retention pass keeps.
Put_Window :: struct {
	principals: [PUT_PRINCIPALS_MOST]Put_Principal,
	hashes:     [PUT_PRINCIPALS_MOST * PUT_OBJECTS_PER_PRINCIPAL_MOST]blake3.Hash,
	hash_count: int,
}

Put_Principal :: struct {
	key:   u64, // The principal of the caller, plus one; 0: a free place.
	count: int,
	bytes: u64,
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

@(private = "file")
window_principal_find :: proc "contextless" (window: ^Put_Window, key: u64, create: bool) -> ^Put_Principal {
	for &place in window.principals {
		if place.key == key {
			return &place
		}
	}
	if !create {
		return nil
	}
	for &place in window.principals {
		if place.key == 0 {
			return &place
		}
	}
	return nil
}

// put_memory_preflight validates kind, size, principal, hourly object-count
// and byte quotas, and the 75 % store retention guard BEFORE streaming bytes
// from a lent memory object. Refusals change nothing.
put_memory_preflight :: proc "contextless" (
	state: ^Recipes_State,
	ledger: ^Put_Ledger,
	principal: u64,
	now_seconds: u64,
	kind_word: i64,
	size: u64,
) -> (kind: object_cache.Cache_Object_Kind, refusal: pr.Recipe_Refusal) {
	if kind_word < 0 {
		return {}, .Bad_Input_Kind
	}
	kind_ok: bool
	kind, kind_ok = object_cache.cache_object_kind_of_word(u64(kind_word))
	if !kind_ok {
		return {}, .Bad_Input_Kind
	}
	if size == 0 {
		return {}, .Malformed_Output
	}
	if size > PUT_MEMORY_BYTES_MOST {
		return {}, .Arguments_Too_Large
	}
	if kind == .Tree && size > u64(tree_hash.MAX_ENCODED_TREE_BYTES) {
		return {}, .Arguments_Too_Large
	}
	if principal == max(u64) {
		return {}, .Bad_Head_Value
	}
	put_ledger_age(ledger, now_seconds)
	window := &ledger.now
	key := principal + 1
	holder := window_principal_find(window, key, true)
	if holder == nil || holder.count >= PUT_OBJECTS_PER_PRINCIPAL_MOST || window.hash_count >= len(window.hashes) {
		return {}, .Put_Quota_Reached
	}
	if size > PUT_BYTES_PER_PRINCIPAL_MOST || holder.bytes > PUT_BYTES_PER_PRINCIPAL_MOST - size {
		return {}, .Put_Quota_Reached
	}
	if room_refusal := retention_make_room(state, size); room_refusal != .None {
		return {}, room_refusal
	}
	return kind, .None
}

// put_memory_commit records a completed put_memory object in ledger after its
// bytes have been verified and committed to the store. An object already
// recorded in the current window counts once.
put_memory_commit :: proc "contextless" (
	ledger: ^Put_Ledger,
	principal: u64,
	now_seconds: u64,
	hash: blake3.Hash,
	size: u64,
) -> pr.Recipe_Refusal {
	if principal == max(u64) || size == 0 || size > PUT_MEMORY_BYTES_MOST {
		return .Bad_Head_Value
	}
	put_ledger_age(ledger, now_seconds)
	window := &ledger.now
	if window_holds(window, hash) {
		return .None
	}
	key := principal + 1
	holder := window_principal_find(window, key, true)
	if holder == nil || holder.count >= PUT_OBJECTS_PER_PRINCIPAL_MOST || window.hash_count >= len(window.hashes) {
		return .Put_Quota_Reached
	}
	if size > PUT_BYTES_PER_PRINCIPAL_MOST || holder.bytes > PUT_BYTES_PER_PRINCIPAL_MOST - size {
		return .Put_Quota_Reached
	}
	holder.key = key
	holder.count += 1
	holder.bytes += size
	window.hashes[window.hash_count] = hash
	window.hash_count += 1
	return .None
}

// put_object checks one inline put and keeps its object: the kind word at its
// border, the size, the bytes against their kind (a tree must be a
// canonical MODTREE1 node), the object-count and byte quotas of the principal
// in the window of now_seconds, and the 75 % retention guard of the store. A
// refused put keeps nothing and counts nothing. An object put before in this
// window is kept again and counts once.
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
	size := u64(len(bytes))
	put_ledger_age(ledger, now_seconds)
	window := &ledger.now
	key := principal + 1
	known := window_holds(window, hash)
	holder := window_principal_find(window, key, !known)
	if !known {
		if holder == nil || holder.count >= PUT_OBJECTS_PER_PRINCIPAL_MOST || window.hash_count >= len(window.hashes) {
			return {}, .Put_Quota_Reached
		}
		if size > PUT_BYTES_PER_PRINCIPAL_MOST || holder.bytes > PUT_BYTES_PER_PRINCIPAL_MOST - size {
			return {}, .Put_Quota_Reached
		}
	}
	if room_refusal := retention_make_room(state, size); room_refusal != .None {
		return {}, room_refusal
	}
	name := pr.blob_object_name(hash)
	if pr.private_store_write(&state.store, pr.private_object_name_text(&name), bytes) != .Ok {
		return {}, .Store_Failed
	}
	if !known {
		holder.key = key
		holder.count += 1
		holder.bytes += size
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
