// Pure freestanding multi-machine helpers: the content-addressed store
// difference of two machines, peer-authenticated bounded cross-machine
// grants with a nonce replay set, and the bounded store of objects by hash
// (src/md/features/several_machines.md). The frames that cross a stream of
// remote are in modus:contract/machine_wire.
package machine_sync

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/object_cache"
import "modus:contract/role_contract"

HASH_BYTES :: 32
MAX_SYNC_HASHES :: 64
MAX_GRANT_TTL_SECONDS :: u64(86_400) // 24 hours max TTL
MAX_SEEN_NONCES :: 64

// store_missing_hashes computes deduplicated object hashes in remote_have that
// are absent from local_have, enforcing MAX_SYNC_HASHES and reporting truncation.
store_missing_hashes :: proc "contextless" (
	local_have: [][HASH_BYTES]u8,
	remote_have: [][HASH_BYTES]u8,
	out_missing: [][HASH_BYTES]u8,
) -> (count: int, truncated: bool) {
	if len(local_have) > MAX_SYNC_HASHES || len(remote_have) > MAX_SYNC_HASHES {
		return 0, true
	}
	for rh in remote_have {
		found := false
		for lh in local_have {
			if lh == rh {
				found = true
				break
			}
		}
		if found {
			continue
		}
		// Deduplicate repeated remote hashes.
		dup := false
		for i in 0 ..< count {
			if out_missing[i] == rh {
				dup = true
				break
			}
		}
		if dup {
			continue
		}
		if count >= len(out_missing) {
			return count, true
		}
		out_missing[count] = rh
		count += 1
	}
	return count, false
}

Cross_Machine_Grant :: struct {
	issuer_machine: [32]u8,
	target_machine: [32]u8,
	role_word:      u16,
	scope_flags:    u16,
	expiry_seconds: u64,
	grant_nonce:    u64,
	mac:            [32]u8,
}

Nonce_Replay_Set :: struct {
	nonces: [MAX_SEEN_NONCES]u64,
	count:  int,
}

cross_grant_mac :: proc "contextless" (shared_secret: [32]u8, g: Cross_Machine_Grant) -> [32]u8 {
	sec := shared_secret
	gc := g
	buf: [32 + 32 + 32 + 20]u8
	copy(buf[0:32], sec[:])
	copy(buf[32:64], gc.issuer_machine[:])
	copy(buf[64:96], gc.target_machine[:])
	byte_order.write_u16_little_endian(buf[:], 96, gc.role_word)
	byte_order.write_u16_little_endian(buf[:], 98, gc.scope_flags)
	byte_order.write_u64_little_endian(buf[:], 100, gc.expiry_seconds)
	byte_order.write_u64_little_endian(buf[:], 108, gc.grant_nonce)
	return blake3.derive_key("modus cross machine grant v1", buf[:])
}

// cross_grant_verify verifies peer/local machine identity, role enum border,
// bounded expiry TTL, nonce replay exclusion, and constant-time MAC equality.
// A full replay set refuses each new grant: a nonce that the set cannot
// record could be replayed later.
cross_grant_verify :: proc "contextless" (
	shared_secret: [32]u8,
	local_machine: [32]u8,
	peer_machine: [32]u8,
	g: Cross_Machine_Grant,
	now_seconds: u64,
	seen: ^Nonce_Replay_Set,
) -> bool {
	if g.target_machine != local_machine || g.issuer_machine != peer_machine || local_machine == peer_machine {
		return false
	}
	role, role_ok := enum_word.member_of_word(role_contract.Role, u64(g.role_word))
	if !role_ok || role == .None {
		return false
	}
	if g.grant_nonce == 0 || g.expiry_seconds == 0 || now_seconds > g.expiry_seconds {
		return false
	}
	if g.expiry_seconds - now_seconds > MAX_GRANT_TTL_SECONDS {
		return false
	}
	if seen != nil {
		for i in 0 ..< seen.count {
			if seen.nonces[i] == g.grant_nonce {
				return false // Replayed nonce refused.
			}
		}
	}
	exp := cross_grant_mac(shared_secret, g)
	diff := u8(0)
	for i in 0 ..< 32 {
		diff |= exp[i] ~ g.mac[i]
	}
	if diff != 0 {
		return false
	}
	if seen != nil {
		if seen.count < 0 || seen.count >= MAX_SEEN_NONCES {
			return false
		}
		seen.nonces[seen.count] = g.grant_nonce
		seen.count += 1
	}
	return true
}

// One object of an Object_Store: its hash and its place in the bytes.
Stored_Object :: struct {
	hash:   [HASH_BYTES]u8,
	kind:   object_cache.Cache_Object_Kind,
	offset: int,
	length: int,
}

// An object that arrives in pieces: its hash, its kind, its size, and the
// bytes received so far, past the bytes in use of the store. The store
// keeps it only when it is whole and its bytes hash to its hash.
Object_Assembly :: struct {
	active:   bool,
	hash:     [HASH_BYTES]u8,
	kind:     object_cache.Cache_Object_Kind,
	total:    int,
	received: int,
}

// A store of objects that came from a paired machine, by hash. The caller
// gives the rows and the bytes, sized from its budget, so the store
// allocates nothing. It never evicts: a full store refuses, and the caller
// fetches again later. An object larger than one frame arrives in pieces
// (object_store_begin, object_store_write, object_store_finish), one object
// at a time.
Object_Store :: struct {
	objects:    []Stored_Object,
	bytes:      []u8,
	count:      int,
	bytes_used: int,
	assembly:   Object_Assembly,
}

Object_Store_Status :: enum u8 {
	Stored                = 1,
	Already_Stored        = 2,
	Refused_Nil_Input     = 3,
	Refused_Hash_Mismatch = 4,
	Refused_Malformed     = 5,
	Refused_Full          = 6,
	Refused_Too_Large     = 7,
}

object_store_init :: proc "contextless" (store: ^Object_Store, objects: []Stored_Object, bytes: []u8) -> bool {
	if store == nil || len(objects) == 0 || len(bytes) == 0 {
		return false
	}
	store^ = Object_Store{objects = objects, bytes = bytes}
	return true
}

// object_store_lookup gives the bytes of the object with this hash.
object_store_lookup :: proc "contextless" (store: ^Object_Store, hash: [HASH_BYTES]u8) -> (bytes: []u8, kind: object_cache.Cache_Object_Kind, found: bool) {
	if store == nil || store.count < 0 || store.count > len(store.objects) {
		return nil, {}, false
	}
	for index in 0 ..< store.count {
		object := store.objects[index]
		if object.hash == hash {
			return store.bytes[object.offset:object.offset + object.length], object.kind, true
		}
	}
	return nil, {}, false
}

// object_store_accept keeps the bytes that a paired machine sent for a
// requested hash, only when they hash to it (BLAKE3 for a blob, the tree hash
// for a tree). The hash is checked before any byte is copied, so a refused
// object leaves the store unchanged.
object_store_accept :: proc "contextless" (
	store: ^Object_Store,
	kind: object_cache.Cache_Object_Kind,
	requested_hash: [HASH_BYTES]u8,
	payload: []u8,
) -> Object_Store_Status {
	if store == nil || store.count < 0 || store.count > len(store.objects) || store.bytes_used < 0 || store.bytes_used > len(store.bytes) {
		return .Refused_Nil_Input
	}
	// A whole object takes the free bytes that an assembly writes into: the
	// assembly ends.
	store.assembly = {}
	switch object_cache.verify_object_content(kind, requested_hash, payload) {
	case .Trust_By_Hash:
	case .Refuse_Hash_Mismatch:
		return .Refused_Hash_Mismatch
	case .Trust_By_Signer, .Refuse_Untrusted_Signer, .Refuse_Bad_Signature, .Refuse_Malformed:
		// An object by hash proves itself; any other answer is no proof.
		return .Refused_Malformed
	}
	if _, _, found := object_store_lookup(store, requested_hash); found {
		return .Already_Stored
	}
	if len(payload) > len(store.bytes) - store.bytes_used {
		return .Refused_Too_Large
	}
	if store.count >= len(store.objects) {
		return .Refused_Full
	}
	offset := store.bytes_used
	copy(store.bytes[offset:offset + len(payload)], payload)
	store.objects[store.count] = Stored_Object{hash = requested_hash, kind = kind, offset = offset, length = len(payload)}
	store.count += 1
	store.bytes_used += len(payload)
	return .Stored
}


// object_store_begin starts an object that arrives in pieces: total bytes
// with this hash and kind. An object that the store holds already is
// Already_Stored, and no assembly starts. An object larger than the free
// bytes is Refused_Too_Large, and a store with no free row Refused_Full:
// the caller asks for nothing more of it. A new begin ends an assembly
// that was not whole.
object_store_begin :: proc "contextless" (store: ^Object_Store, kind: object_cache.Cache_Object_Kind, hash: [HASH_BYTES]u8, total: int) -> Object_Store_Status {
	if store == nil || store.count < 0 || store.count > len(store.objects) || store.bytes_used < 0 || store.bytes_used > len(store.bytes) || total < 0 {
		return .Refused_Nil_Input
	}
	store.assembly = {}
	if _, held_kind, found := object_store_lookup(store, hash); found {
		if held_kind != kind {
			return .Refused_Malformed
		}
		return .Already_Stored
	}
	if total > len(store.bytes) - store.bytes_used {
		return .Refused_Too_Large
	}
	if store.count >= len(store.objects) {
		return .Refused_Full
	}
	store.assembly = {active = true, hash = hash, kind = kind, total = total}
	return .Stored
}

// object_store_write adds the bytes of the object in assembly at offset.
// The pieces come in order: a piece that does not start where the object
// ends now, or that passes its size, ends the assembly and is refused.
object_store_write :: proc "contextless" (store: ^Object_Store, hash: [HASH_BYTES]u8, offset: int, bytes: []u8) -> Object_Store_Status {
	if store == nil || !store.assembly.active || store.assembly.hash != hash {
		return .Refused_Nil_Input
	}
	assembly := &store.assembly
	if offset != assembly.received || len(bytes) > assembly.total - assembly.received {
		store.assembly = {}
		return .Refused_Malformed
	}
	copy(store.bytes[store.bytes_used + assembly.received:][:len(bytes)], bytes)
	assembly.received += len(bytes)
	return .Stored
}

// object_store_whole says if the object in assembly has all its bytes.
object_store_whole :: proc "contextless" (store: ^Object_Store) -> bool {
	return store.assembly.active && store.assembly.received == store.assembly.total
}

// object_store_finish keeps the object in assembly when it is whole and
// its bytes hash to its hash (BLAKE3 for a blob, the tree hash for a tree).
// The bytes in use grow only then: a refused object leaves the store as it
// was before its first piece.
object_store_finish :: proc "contextless" (store: ^Object_Store) -> Object_Store_Status {
	if store == nil || !object_store_whole(store) {
		return .Refused_Nil_Input
	}
	assembly := store.assembly
	store.assembly = {}
	bytes := store.bytes[store.bytes_used:][:assembly.total]
	switch object_cache.verify_object_content(assembly.kind, assembly.hash, bytes) {
	case .Trust_By_Hash:
	case .Refuse_Hash_Mismatch:
		return .Refused_Hash_Mismatch
	case .Trust_By_Signer, .Refuse_Untrusted_Signer, .Refuse_Bad_Signature, .Refuse_Malformed:
		return .Refused_Malformed
	}
	store.objects[store.count] = Stored_Object{hash = assembly.hash, kind = assembly.kind, offset = store.bytes_used, length = assembly.total}
	store.count += 1
	store.bytes_used += assembly.total
	return .Stored
}
