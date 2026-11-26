#+build !freestanding
#+build !modus
package machine_wire

import "modus:contract/machine_sync"

// The memory of a peer of the tests, from the temporary memory of the test:
// two stores with TEST_STORE_ENTRIES entries in each version, more than the
// entries of one page, and objects of several pieces.
TEST_STORES :: 2
TEST_STORE_ENTRIES :: 400
TEST_STORE_CONFLICTS :: 64
TEST_OBJECT_ROWS :: 16
TEST_OBJECT_BYTES :: 4 * OBJECT_CHUNK_BYTES + 4096

test_peer_memory :: proc() -> Peer_Memory {
	return Peer_Memory {
		object_rows = make([]machine_sync.Stored_Object, TEST_OBJECT_ROWS, context.temp_allocator),
		object_bytes = make([]u8, TEST_OBJECT_BYTES, context.temp_allocator),
		stores = make([]Exchanged_Store, TEST_STORES, context.temp_allocator),
		store_entries = make([]Store_Entry, TEST_STORES * STORE_VERSIONS_OF_A_STORE * TEST_STORE_ENTRIES, context.temp_allocator),
		store_conflicts = make([]Store_Conflict, TEST_STORES * STORE_VERSIONS_OF_A_STORE * TEST_STORE_CONFLICTS, context.temp_allocator),
	}
}

// test_store_state gives the hash of each version of a store that holds its
// state, and its flags: two states are the same store, whatever memory
// holds them. The versions that a page or a merge writes as work memory
// (incoming, reply, merged, merged_later) are no state: a refused page can
// leave bytes there, and the next first page starts them again.
Test_Store_State :: struct {
	versions: [5][2]u64,
	hashes:   [5][32]u8,
	flags:    [3]bool,
	cursor:   Store_Cursor,
}

test_store_state :: proc(store: ^Exchanged_Store) -> (state: Test_Store_State) {
	versions := [5]^Store_Version{&store.current, &store.common, &store.offered, &store.previous_common, &store.last_reply}
	for version, index in versions {
		state.versions[index] = {u64(version.count), u64(version.conflict_count)}
		state.hashes[index] = store_version_hash(version)
	}
	state.flags = {store.in_use, store.has_offer, store.has_last_exchange}
	state.cursor = store.offer_cursor
	return state
}
