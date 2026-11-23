#+build !freestanding
package machine_sync

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/role_contract"

@(test)
merkle_sync_peer_authenticated_grant_replay_defense :: proc(t: ^testing.T) {
	h1: [HASH_BYTES]u8; h1[0] = 1
	h2: [HASH_BYTES]u8; h2[0] = 2
	h3: [HASH_BYTES]u8; h3[0] = 3
	local := [2][HASH_BYTES]u8{h1, h2}
	remote := [2][HASH_BYTES]u8{h2, h3}
	missing: [4][HASH_BYTES]u8
	mn, next, more, status := store_missing_hashes(local[:], remote[:], 0, missing[:])
	testing.expect(t, status == .Ok && mn == 1 && missing[0] == h3 && next == 2 && !more)
	// A repeat in a list is refused, not dropped.
	repeated := [3][HASH_BYTES]u8{h2, h3, h3}
	_, _, _, status = store_missing_hashes(local[:], repeated[:], 0, missing[:])
	testing.expect_value(t, status, Missing_Hashes_Status.Refused_Not_Sorted)

	secret: [32]u8; secret[0] = 0xAA
	m_local: [32]u8; m_local[0] = 0x11
	m_peer: [32]u8; m_peer[0] = 0x22
	seen: Nonce_Replay_Set
	g := Cross_Machine_Grant{
		issuer_machine = m_peer,
		target_machine = m_local,
		role_word      = u16(role_contract.Role.Storage),
		scope_flags    = 1,
		expiry_seconds = 10_000,
		grant_nonce    = 7,
	}
	g.mac = cross_grant_mac(secret, g)
	// Reflection back to peer refused!
	testing.expect(t, !cross_grant_verify(secret, m_peer, m_local, g, 9_500, &seen))
	// Valid first verification succeeds, replay of same nonce refused!
	testing.expect(t, cross_grant_verify(secret, m_local, m_peer, g, 9_500, &seen))
	testing.expect(t, !cross_grant_verify(secret, m_local, m_peer, g, 9_501, &seen))
}

// An object in pieces: the edges first (an empty object, a store with no
// row, an object one byte past the free bytes), then pieces out of order,
// past the size and with a changed byte, each refused with nothing kept,
// and last an object of three pieces kept whole.
@(test)
object_store_keeps_an_object_of_pieces_only_whole :: proc(t: ^testing.T) {
	rows: [2]Stored_Object
	bytes: [100]u8
	store: Object_Store
	testing.expect(t, object_store_init(&store, rows[:], bytes[:]))
	object: [90]u8
	for index in 0 ..< len(object) {
		object[index] = u8(index * 3)
	}
	hash := blake3.hash(object[:])

	// An empty object is whole at its begin.
	empty_hash := blake3.hash(nil)
	testing.expect_value(t, object_store_begin(&store, .Blob, empty_hash, 0), Object_Store_Status.Stored)
	testing.expect(t, object_store_whole(&store))
	testing.expect_value(t, object_store_finish(&store), Object_Store_Status.Stored)
	testing.expect_value(t, object_store_begin(&store, .Blob, empty_hash, 0), Object_Store_Status.Already_Stored)
	testing.expect_value(t, object_store_begin(&store, .Blob, hash, len(bytes) + 1), Object_Store_Status.Refused_Too_Large)
	testing.expect_value(t, object_store_begin(&store, .Blob, hash, -1), Object_Store_Status.Refused_Nil_Input)

	// Out of order, past the size, a write with no begin.
	testing.expect_value(t, object_store_write(&store, hash, 0, object[:10]), Object_Store_Status.Refused_Nil_Input)
	testing.expect_value(t, object_store_begin(&store, .Blob, hash, len(object)), Object_Store_Status.Stored)
	testing.expect_value(t, object_store_write(&store, hash, 10, object[10:20]), Object_Store_Status.Refused_Malformed)
	testing.expect(t, !store.assembly.active)
	testing.expect_value(t, object_store_begin(&store, .Blob, hash, 10), Object_Store_Status.Stored)
	testing.expect_value(t, object_store_write(&store, hash, 0, object[:11]), Object_Store_Status.Refused_Malformed)

	// A changed byte: the whole object is refused at its end.
	changed := object
	changed[45] ~= 1
	testing.expect_value(t, object_store_begin(&store, .Blob, hash, len(object)), Object_Store_Status.Stored)
	testing.expect_value(t, object_store_write(&store, hash, 0, changed[:30]), Object_Store_Status.Stored)
	testing.expect_value(t, object_store_write(&store, hash, 30, changed[30:60]), Object_Store_Status.Stored)
	testing.expect_value(t, object_store_write(&store, hash, 60, changed[60:]), Object_Store_Status.Stored)
	testing.expect_value(t, object_store_finish(&store), Object_Store_Status.Refused_Hash_Mismatch)
	testing.expect_value(t, store.count, 1)
	testing.expect_value(t, store.bytes_used, 0)
	testing.expect_value(t, object_store_finish(&store), Object_Store_Status.Refused_Nil_Input)

	// The true pieces.
	testing.expect_value(t, object_store_begin(&store, .Blob, hash, len(object)), Object_Store_Status.Stored)
	testing.expect_value(t, object_store_write(&store, hash, 0, object[:30]), Object_Store_Status.Stored)
	testing.expect_value(t, object_store_finish(&store), Object_Store_Status.Refused_Nil_Input)
	testing.expect_value(t, object_store_write(&store, hash, 30, object[30:]), Object_Store_Status.Stored)
	testing.expect_value(t, object_store_finish(&store), Object_Store_Status.Stored)
	kept, _, found := object_store_lookup(&store, hash)
	testing.expect(t, found && string(kept) == string(object[:]))
	// The rows are full now.
	other := [1]u8{7}
	testing.expect_value(t, object_store_begin(&store, .Blob, blake3.hash(other[:]), 1), Object_Store_Status.Refused_Full)
}

// The missing hashes of 300 remote hashes against 100 local ones, past the
// 64 of a list that did not page: pages of 64, of 1 and of the whole,
// each hash once and in order; then the refusals at the border.
@(test)
missing_hashes_page_over_lists_of_any_length :: proc(t: ^testing.T) {
	hash_of :: proc(index: int) -> (hash: [HASH_BYTES]u8) {
		hash[0] = u8(index >> 8)
		hash[1] = u8(index)
		hash[2] = 1
		return
	}
	REMOTE :: 300
	remote: [REMOTE][HASH_BYTES]u8
	local: [100][HASH_BYTES]u8
	for index in 0 ..< REMOTE {
		remote[index] = hash_of(index)
	}
	// The local machine holds each third hash.
	for index in 0 ..< len(local) {
		local[index] = hash_of(index * 3)
	}
	for page_size in ([?]int{1, 64, REMOTE}) {
		page := make([][HASH_BYTES]u8, page_size, context.temp_allocator)
		seen := 0
		cursor := 0
		for {
			count, next, more, status := store_missing_hashes(local[:], remote[:], cursor, page)
			testing.expect_value(t, status, Missing_Hashes_Status.Ok)
			for hash in page[:count] {
				index := int(hash[0]) << 8 | int(hash[1])
				testing.expectf(t, index % 3 != 0 || index >= 300, "the hash %d is held locally", index)
				seen += 1
			}
			cursor = next
			if !more {
				break
			}
		}
		testing.expectf(t, seen == REMOTE - len(local), "page of %d: %d missing", page_size, seen)
	}
	// The end of the list, an empty list, and the refusals.
	one: [1][HASH_BYTES]u8
	count, next, more, status := store_missing_hashes(local[:], remote[:], REMOTE, one[:])
	testing.expect(t, status == .Ok && count == 0 && next == REMOTE && !more)
	count, _, _, status = store_missing_hashes(nil, nil, 0, one[:])
	testing.expect(t, status == .Ok && count == 0)
	_, _, _, status = store_missing_hashes(local[:], remote[:], REMOTE + 1, one[:])
	testing.expect_value(t, status, Missing_Hashes_Status.Refused_Bad_Cursor)
	_, _, _, status = store_missing_hashes(local[:], remote[:], -1, one[:])
	testing.expect_value(t, status, Missing_Hashes_Status.Refused_Bad_Cursor)
	_, _, _, status = store_missing_hashes(local[:], remote[:], 0, nil)
	testing.expect_value(t, status, Missing_Hashes_Status.Refused_No_Room)
	unsorted := remote
	unsorted[10], unsorted[11] = unsorted[11], unsorted[10]
	_, _, _, status = store_missing_hashes(local[:], unsorted[:], 0, one[:])
	testing.expect_value(t, status, Missing_Hashes_Status.Refused_Not_Sorted)
	_, _, _, status = store_missing_hashes(unsorted[:], remote[:], 0, one[:])
	testing.expect_value(t, status, Missing_Hashes_Status.Refused_Not_Sorted)
}
