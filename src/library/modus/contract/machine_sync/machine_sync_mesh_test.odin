#+build !freestanding
#+build !modus
package machine_sync

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/object_cache"
import "modus:contract/role_contract"

@(private = "file")
LOCAL_MACHINE :: [32]u8{0 = 0x11}
@(private = "file")
PEER_MACHINE :: [32]u8{0 = 0x22}
@(private = "file")
SECRET :: [32]u8{0 = 0xAA, 31 = 0x55}

@(private = "file")
grant_for :: proc(nonce: u64, expiry_seconds: u64) -> Cross_Machine_Grant {
	grant := Cross_Machine_Grant {
		issuer_machine = PEER_MACHINE,
		target_machine = LOCAL_MACHINE,
		role_word      = u16(role_contract.Role.Storage),
		scope_flags    = 1,
		expiry_seconds = expiry_seconds,
		grant_nonce    = nonce,
	}
	grant.mac = cross_grant_mac(SECRET, grant)
	return grant
}

@(test)
cross_grant_refuses_more_than_one_day_expiry_tampering_and_replay :: proc(t: ^testing.T) {
	now := u64(1_000_000)
	seen: Nonce_Replay_Set
	// Exactly one day ahead is accepted; one second more is refused.
	testing.expect(t, cross_grant_verify(SECRET, LOCAL_MACHINE, PEER_MACHINE, grant_for(1, now + MAX_GRANT_TTL_SECONDS), now, &seen))
	testing.expect(t, !cross_grant_verify(SECRET, LOCAL_MACHINE, PEER_MACHINE, grant_for(2, now + MAX_GRANT_TTL_SECONDS + 1), now, &seen))
	testing.expect(t, !cross_grant_verify(SECRET, LOCAL_MACHINE, PEER_MACHINE, grant_for(3, max(u64)), now, &seen))
	// Past its expiry; at its expiry it still holds.
	testing.expect(t, !cross_grant_verify(SECRET, LOCAL_MACHINE, PEER_MACHINE, grant_for(4, now - 1), now, &seen))
	testing.expect(t, cross_grant_verify(SECRET, LOCAL_MACHINE, PEER_MACHINE, grant_for(5, now), now, &seen))
	testing.expect(t, !cross_grant_verify(SECRET, LOCAL_MACHINE, PEER_MACHINE, grant_for(6, 0), 0, &seen))
	testing.expect(t, !cross_grant_verify(SECRET, LOCAL_MACHINE, PEER_MACHINE, grant_for(0, now + 10), now, &seen))
	testing.expect_value(t, seen.count, 2)

	// Each field changed after the tag, and another secret, are refused.
	base := grant_for(7, now + 10)
	changed := [?]Cross_Machine_Grant{base, base, base, base, base}
	changed[0].scope_flags = 3
	changed[1].expiry_seconds += 1
	changed[2].role_word = u16(role_contract.Role.Network)
	changed[3].mac[31] ~= 1
	changed[4].grant_nonce = 8
	for grant in changed {
		testing.expect(t, !cross_grant_verify(SECRET, LOCAL_MACHINE, PEER_MACHINE, grant, now, &seen))
	}
	other_secret := SECRET
	other_secret[0] ~= 1
	testing.expect(t, !cross_grant_verify(other_secret, LOCAL_MACHINE, PEER_MACHINE, base, now, &seen))
	// A role word that names no member, and the role None, are refused.
	unknown := base
	unknown.role_word = 0xFFFF
	unknown.mac = cross_grant_mac(SECRET, unknown)
	testing.expect(t, !cross_grant_verify(SECRET, LOCAL_MACHINE, PEER_MACHINE, unknown, now, &seen))
	none := base
	none.role_word = u16(role_contract.Role.None)
	none.mac = cross_grant_mac(SECRET, none)
	testing.expect(t, !cross_grant_verify(SECRET, LOCAL_MACHINE, PEER_MACHINE, none, now, &seen))
	// The machine itself as the issuer.
	testing.expect(t, !cross_grant_verify(SECRET, LOCAL_MACHINE, LOCAL_MACHINE, base, now, &seen))
	testing.expect_value(t, seen.count, 2)

	// The good grant once, then its replay.
	testing.expect(t, cross_grant_verify(SECRET, LOCAL_MACHINE, PEER_MACHINE, base, now, &seen))
	testing.expect(t, !cross_grant_verify(SECRET, LOCAL_MACHINE, PEER_MACHINE, base, now, &seen))
}

@(test)
cross_grant_refuses_each_grant_once_the_replay_set_is_full :: proc(t: ^testing.T) {
	now := u64(500)
	seen: Nonce_Replay_Set
	for nonce in 1 ..= u64(MAX_SEEN_NONCES) {
		testing.expect(t, cross_grant_verify(SECRET, LOCAL_MACHINE, PEER_MACHINE, grant_for(nonce, now + 60), now, &seen))
	}
	testing.expect_value(t, seen.count, MAX_SEEN_NONCES)
	// A new nonce that the set cannot record is refused, and the first nonce
	// is still refused as a replay.
	testing.expect(t, !cross_grant_verify(SECRET, LOCAL_MACHINE, PEER_MACHINE, grant_for(MAX_SEEN_NONCES + 1, now + 60), now, &seen))
	testing.expect(t, !cross_grant_verify(SECRET, LOCAL_MACHINE, PEER_MACHINE, grant_for(1, now + 60), now, &seen))
	testing.expect_value(t, seen.count, MAX_SEEN_NONCES)
	damaged: Nonce_Replay_Set
	damaged.count = -1
	testing.expect(t, !cross_grant_verify(SECRET, LOCAL_MACHINE, PEER_MACHINE, grant_for(99, now + 60), now, &damaged))
}

@(test)
object_store_keeps_only_bytes_that_hash_to_the_requested_hash :: proc(t: ^testing.T) {
	rows: [3]Stored_Object
	bytes: [64]u8
	store: Object_Store
	testing.expect(t, !object_store_init(nil, rows[:], bytes[:]))
	testing.expect(t, !object_store_init(&store, nil, bytes[:]))
	testing.expect(t, !object_store_init(&store, rows[:], nil))
	testing.expect(t, object_store_init(&store, rows[:], bytes[:]))
	testing.expect_value(t, object_store_accept(nil, .Blob, {}, nil), Object_Store_Status.Refused_Nil_Input)

	payload := transmute([]u8)string("the bytes of one object")
	hash := blake3.hash(payload)

	// One bit changed in the bytes, or in the requested hash.
	corrupted: [23]u8
	copy(corrupted[:], payload)
	corrupted[0] ~= 0x01
	testing.expect_value(t, object_store_accept(&store, .Blob, hash, corrupted[:]), Object_Store_Status.Refused_Hash_Mismatch)
	wrong_hash := hash
	wrong_hash[31] ~= 0x80
	testing.expect_value(t, object_store_accept(&store, .Blob, wrong_hash, payload), Object_Store_Status.Refused_Hash_Mismatch)
	// The bytes of an object under the hash of the empty object.
	testing.expect_value(t, object_store_accept(&store, .Blob, blake3.hash(nil), payload), Object_Store_Status.Refused_Hash_Mismatch)
	// A zero hash, a kind that names no member, and a blob sent as a tree.
	testing.expect_value(t, object_store_accept(&store, .Blob, {}, payload), Object_Store_Status.Refused_Malformed)
	testing.expect_value(t, object_store_accept(&store, object_cache.Cache_Object_Kind(0), hash, payload), Object_Store_Status.Refused_Malformed)
	testing.expect_value(t, object_store_accept(&store, object_cache.Cache_Object_Kind(3), hash, payload), Object_Store_Status.Refused_Malformed)
	testing.expect_value(t, object_store_accept(&store, .Tree, hash, payload), Object_Store_Status.Refused_Malformed)
	// No refusal wrote a row or a byte.
	testing.expect_value(t, store.count, 0)
	testing.expect_value(t, store.bytes_used, 0)
	_, _, found := object_store_lookup(&store, hash)
	testing.expect(t, !found)

	testing.expect_value(t, object_store_accept(&store, .Blob, hash, payload), Object_Store_Status.Stored)
	testing.expect_value(t, object_store_accept(&store, .Blob, hash, payload), Object_Store_Status.Already_Stored)
	testing.expect_value(t, store.count, 1)
	kept, kind, kept_found := object_store_lookup(&store, hash)
	testing.expect(t, kept_found && kind == .Blob && string(kept) == string(payload))

	// The bytes left: 64 - 23 = 41. One byte more is refused.
	large: [42]u8
	large[0] = 1
	testing.expect_value(t, object_store_accept(&store, .Blob, blake3.hash(large[:]), large[:]), Object_Store_Status.Refused_Too_Large)
	exact := large[:41]
	testing.expect_value(t, object_store_accept(&store, .Blob, blake3.hash(exact), exact), Object_Store_Status.Stored)
	testing.expect_value(t, store.bytes_used, 64)
	// The empty object fits in no byte; then the rows are full.
	testing.expect_value(t, object_store_accept(&store, .Blob, blake3.hash(nil), nil), Object_Store_Status.Stored)
	other := [1]u8{7}
	testing.expect_value(t, object_store_accept(&store, .Blob, blake3.hash(other[:]), other[:0]), Object_Store_Status.Refused_Hash_Mismatch)
	testing.expect_value(t, object_store_accept(&store, .Blob, blake3.hash(nil), nil), Object_Store_Status.Already_Stored)
	store.bytes_used = 0
	store.count = 3
	testing.expect_value(t, object_store_accept(&store, .Blob, blake3.hash(other[:]), other[:]), Object_Store_Status.Refused_Full)
	// A store whose counts are damaged is refused, never read past its end.
	store.count = 4
	testing.expect_value(t, object_store_accept(&store, .Blob, hash, payload), Object_Store_Status.Refused_Nil_Input)
	_, _, found = object_store_lookup(&store, hash)
	testing.expect(t, !found)
	store.count = 1
	store.bytes_used = 65
	testing.expect_value(t, object_store_accept(&store, .Blob, hash, payload), Object_Store_Status.Refused_Nil_Input)
}
