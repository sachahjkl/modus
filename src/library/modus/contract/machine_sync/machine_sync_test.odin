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
	remote := [3][HASH_BYTES]u8{h2, h3, h3} // Duplicate h3 deduplicated!
	missing: [4][HASH_BYTES]u8
	mn, trunc := store_missing_hashes(local[:], remote[:], missing[:])
	testing.expect(t, !trunc && mn == 1 && missing[0] == h3)

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
