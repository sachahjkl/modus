// The exchange of one store of a principal between two paired machines
// (src/md/features/several_machines.md, "The exchange of a store between
// machines").
//
// A version of a store is its entries: an object identifier and the hash of
// the object, sorted by identifier. Each machine writes its own version at
// once, also with no link. When the two machines meet, the sender offers its
// version, the receiver answers with its own version before any merge, and
// each side runs the same three-way merge against the common version of the
// pair. The merge is symmetric (machine_mesh.reconcile_object orders the two
// sides), so both machines end with the same version and the same conflicts.
//
// An object that both sides changed to two hashes becomes a conflict value:
// the merged entry holds its hash, and the store keeps the base and both
// sides. A write of that object is refused until the principal resolves the
// conflict, once; the resolution is a change like any other, and the next
// exchange carries it to the other machine. No side of a conflict is ever
// dropped by the merge.
package machine_wire

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/machine_mesh"

STORE_ENTRY_CAPACITY :: 32 // The objects of one exchanged store at most.
EXCHANGED_STORE_CAPACITY :: 4 // The stores that the plan of the principal exchanges on this machine.
STORE_ENTRY_WIRE_SIZE :: 2 * blake3.HASH_SIZE
STORE_OFFER_HEADER_SIZE :: blake3.HASH_SIZE + 8 // The store identifier, the count of entries, a zero word.
STORE_OFFER_LIMIT :: STORE_OFFER_HEADER_SIZE + STORE_ENTRY_CAPACITY * STORE_ENTRY_WIRE_SIZE
STORE_VERSION_HASH_DOMAIN :: "modus exchanged store version v1"

// One object of a version: its identifier, which a rename keeps, and the
// hash of its bytes. A zero hash is no entry: the object is absent.
Store_Entry :: struct {
	identifier: blake3.Hash,
	hash:       blake3.Hash,
}

Store_Version :: struct {
	entries: [STORE_ENTRY_CAPACITY]Store_Entry,
	count:   int,
}

// A conflict value: the merged entry of identifier holds value.conflict_value_hash.
Store_Conflict :: struct {
	identifier: blake3.Hash,
	value:      machine_mesh.Conflict_Value,
}

Exchanged_Store :: struct {
	in_use:           bool,
	store_identifier: blake3.Hash,
	partner_identity: [machine_mesh.PUBLIC_KEY_SIZE]u8, // The one paired machine that the plan names for this store.
	current:          Store_Version,
	common:           Store_Version, // The newest version that both machines hold: the base of the next merge.
	conflicts:        [STORE_ENTRY_CAPACITY]Store_Conflict,
	conflict_count:   int,
}

Store_Status :: enum u8 {
	Ok                      = 1,
	Refused_Nil_Input       = 2,
	Refused_Zero_Identifier = 3, // A store identifier, an object identifier or a partner key is zero.
	Refused_Unknown_Store   = 4, // No exchanged store has this identifier.
	Refused_Not_Partner     = 5, // The plan exchanges this store with another machine.
	Refused_Full            = 6, // The table of stores, or the version, has no room.
	Refused_Holds_Conflict  = 7, // A write of an object whose entry is a conflict value: resolve it first.
	Refused_No_Conflict     = 8, // A resolution of an object that holds no conflict.
	Refused_Bad_Resolution  = 9, // A resolution that keeps the conflict value itself.
	Refused_Not_Sorted      = 10, // The entries of an offer are not strictly increasing by identifier.
	Refused_Bad_Count       = 11, // The count of an offer is over the capacity or differs from its bytes.
	Refused_Zero_Hash       = 12, // An offer holds an entry with a zero hash.
	Refused_Reserved_Set    = 13, // The zero word of an offer is not zero.
	Refused_Exists          = 14, // The store is exchanged already.
	Refused_Other_Store     = 15, // The answer names another store than the offer.
}

@(private)
identifier_compare :: proc "contextless" (left, right: blake3.Hash) -> int {
	for index in 0 ..< blake3.HASH_SIZE {
		if left[index] != right[index] {
			return left[index] < right[index] ? -1 : 1
		}
	}
	return 0
}

@(private)
hash_is_zero :: proc "contextless" (value: blake3.Hash) -> bool {
	return machine_mesh.key_is_zero(value)
}

// store_version_lookup gives the hash of identifier in a version, or zero.
store_version_lookup :: proc "contextless" (version: ^Store_Version, identifier: blake3.Hash) -> blake3.Hash {
	for index in 0 ..< version.count {
		if version.entries[index].identifier == identifier {
			return version.entries[index].hash
		}
	}
	return {}
}

// store_version_hash names a whole version: two machines compare a store by
// this one hash.
store_version_hash :: proc "contextless" (version: ^Store_Version) -> blake3.Hash {
	bytes: [STORE_ENTRY_CAPACITY * STORE_ENTRY_WIRE_SIZE]u8
	for index in 0 ..< version.count {
		entry := version.entries[index]
		copy(bytes[index * STORE_ENTRY_WIRE_SIZE:][:blake3.HASH_SIZE], entry.identifier[:])
		copy(bytes[index * STORE_ENTRY_WIRE_SIZE + blake3.HASH_SIZE:][:blake3.HASH_SIZE], entry.hash[:])
	}
	return blake3.derive_key(STORE_VERSION_HASH_DOMAIN, bytes[:version.count * STORE_ENTRY_WIRE_SIZE])
}

// store_exchange_add names a store that the plan exchanges with one paired machine.
store_exchange_add :: proc "contextless" (stores: ^[EXCHANGED_STORE_CAPACITY]Exchanged_Store, store_identifier: blake3.Hash, partner_identity: [machine_mesh.PUBLIC_KEY_SIZE]u8) -> (store: ^Exchanged_Store, status: Store_Status) {
	if stores == nil {
		return nil, .Refused_Nil_Input
	}
	if hash_is_zero(store_identifier) || machine_mesh.key_is_zero(partner_identity) {
		return nil, .Refused_Zero_Identifier
	}
	free: ^Exchanged_Store
	for &item in stores {
		if item.in_use && item.store_identifier == store_identifier {
			return nil, .Refused_Exists
		}
		if !item.in_use && free == nil {
			free = &item
		}
	}
	if free == nil {
		return nil, .Refused_Full
	}
	free^ = Exchanged_Store{in_use = true, store_identifier = store_identifier, partner_identity = partner_identity}
	return free, .Ok
}

store_exchange_find :: proc "contextless" (stores: ^[EXCHANGED_STORE_CAPACITY]Exchanged_Store, store_identifier: blake3.Hash) -> ^Exchanged_Store {
	if stores == nil {
		return nil
	}
	for &item in stores {
		if item.in_use && item.store_identifier == store_identifier {
			return &item
		}
	}
	return nil
}

// store_conflict_find gives the conflict of identifier, or nil.
store_conflict_find :: proc "contextless" (store: ^Exchanged_Store, identifier: blake3.Hash) -> ^Store_Conflict {
	for index in 0 ..< store.conflict_count {
		if store.conflicts[index].identifier == identifier {
			return &store.conflicts[index]
		}
	}
	return nil
}

@(private)
version_set :: proc "contextless" (version: ^Store_Version, identifier: blake3.Hash, hash: blake3.Hash) -> Store_Status {
	place := 0
	for place < version.count && identifier_compare(version.entries[place].identifier, identifier) < 0 {
		place += 1
	}
	if place < version.count && version.entries[place].identifier == identifier {
		if hash_is_zero(hash) {
			copy(version.entries[place:version.count - 1], version.entries[place + 1:version.count])
			version.count -= 1
			version.entries[version.count] = {}
		} else {
			version.entries[place].hash = hash
		}
		return .Ok
	}
	if hash_is_zero(hash) {
		return .Ok
	}
	if version.count >= STORE_ENTRY_CAPACITY {
		return .Refused_Full
	}
	index := version.count
	for index > place {
		version.entries[index] = version.entries[index - 1]
		index -= 1
	}
	version.entries[place] = Store_Entry{identifier = identifier, hash = hash}
	version.count += 1
	return .Ok
}

// store_write is a change of this machine: the object identifier now holds
// hash, or is removed when hash is zero. An object that holds a conflict
// value is refused: the principal resolves it first.
store_write :: proc "contextless" (store: ^Exchanged_Store, identifier: blake3.Hash, hash: blake3.Hash) -> Store_Status {
	if store == nil || !store.in_use {
		return .Refused_Nil_Input
	}
	if hash_is_zero(identifier) {
		return .Refused_Zero_Identifier
	}
	if store_conflict_find(store, identifier) != nil {
		return .Refused_Holds_Conflict
	}
	return version_set(&store.current, identifier, hash)
}

// store_conflict_resolve is the one resolution of a conflict by the
// principal: the object takes chosen (a side, the base, a new hash, or zero
// to remove it), and the conflict ends. A second resolution is refused.
store_conflict_resolve :: proc "contextless" (store: ^Exchanged_Store, identifier: blake3.Hash, chosen: blake3.Hash) -> Store_Status {
	if store == nil || !store.in_use {
		return .Refused_Nil_Input
	}
	conflict := store_conflict_find(store, identifier)
	if conflict == nil {
		return .Refused_No_Conflict
	}
	if chosen == conflict.value.conflict_value_hash {
		return .Refused_Bad_Resolution
	}
	status := version_set(&store.current, identifier, chosen)
	if status != .Ok {
		return status
	}
	place := int(uintptr(conflict) - uintptr(&store.conflicts[0])) / size_of(Store_Conflict)
	copy(store.conflicts[place:store.conflict_count - 1], store.conflicts[place + 1:store.conflict_count])
	store.conflict_count -= 1
	store.conflicts[store.conflict_count] = {}
	return .Ok
}

// version_take gives the hash of identifier at the cursor of a version and
// moves the cursor past it, or gives zero: the object is absent there.
@(private)
version_take :: proc "contextless" (version: ^Store_Version, index: ^int, identifier: blake3.Hash) -> blake3.Hash {
	if index^ < version.count && version.entries[index^].identifier == identifier {
		index^ += 1
		return version.entries[index^ - 1].hash
	}
	return {}
}

// store_merge_compute runs the three-way merge of the common version, this
// version and the version of the partner, entry by entry in the order of
// the identifiers. It changes nothing: store_merge_apply does.
store_merge_compute :: proc "contextless" (store: ^Exchanged_Store, theirs: ^Store_Version) -> (merged: Store_Version, conflicts: [STORE_ENTRY_CAPACITY]Store_Conflict, conflict_count: int, status: Store_Status) {
	base := &store.common
	ours := &store.current
	base_index, our_index, their_index := 0, 0, 0
	for base_index < base.count || our_index < ours.count || their_index < theirs.count {
		// The smallest identifier of the three heads.
		smallest: blake3.Hash
		has_smallest := false
		heads := [3]^Store_Version{base, ours, theirs}
		indexes := [3]int{base_index, our_index, their_index}
		for version, which in heads {
			if indexes[which] < version.count {
				candidate := version.entries[indexes[which]].identifier
				if !has_smallest || identifier_compare(candidate, smallest) < 0 {
					smallest, has_smallest = candidate, true
				}
			}
		}
		base_hash := version_take(base, &base_index, smallest)
		our_hash := version_take(ours, &our_index, smallest)
		their_hash := version_take(theirs, &their_index, smallest)
		decision, chosen, conflict := machine_mesh.reconcile_object(base_hash, our_hash, their_hash)
		switch decision {
		case .Unchanged, .Take_Local, .Take_Remote, .Both_Same:
		case .Conflict_Keep_Both:
			// The same conflict on both sides keeps its one record.
			if conflict_count >= STORE_ENTRY_CAPACITY {
				return {}, {}, 0, .Refused_Full
			}
			conflicts[conflict_count] = Store_Conflict{identifier = smallest, value = conflict}
			conflict_count += 1
		}
		if hash_is_zero(chosen) {
			continue
		}
		if merged.count >= STORE_ENTRY_CAPACITY {
			return {}, {}, 0, .Refused_Full
		}
		merged.entries[merged.count] = Store_Entry{identifier = smallest, hash = chosen}
		merged.count += 1
	}
	// The conflicts that this machine held and that the merge kept.
	for index in 0 ..< store.conflict_count {
		held := store.conflicts[index]
		if store_version_lookup(&merged, held.identifier) != held.value.conflict_value_hash {
			continue
		}
		known := false
		for earlier in 0 ..< conflict_count {
			if conflicts[earlier].identifier == held.identifier {
				known = true
				break
			}
		}
		if known {
			continue
		}
		if conflict_count >= STORE_ENTRY_CAPACITY {
			return {}, {}, 0, .Refused_Full
		}
		conflicts[conflict_count] = held
		conflict_count += 1
	}
	return merged, conflicts, conflict_count, .Ok
}

@(private)
store_merge_apply :: proc "contextless" (store: ^Exchanged_Store, merged: ^Store_Version, conflicts: ^[STORE_ENTRY_CAPACITY]Store_Conflict, conflict_count: int) {
	store.current = merged^
	store.common = merged^
	store.conflicts = conflicts^
	store.conflict_count = conflict_count
}

// store_offer_write writes a Store_Offer or a Store_Offer_Reply with the
// current version of the store.
store_offer_write :: proc "contextless" (store: ^Exchanged_Store, message: Message, output: []u8) -> []u8 {
	if store == nil || (message != .Store_Offer && message != .Store_Offer_Reply) {
		return nil
	}
	body, ok := frame_begin(output, message, STORE_OFFER_HEADER_SIZE + store.current.count * STORE_ENTRY_WIRE_SIZE)
	if !ok {
		return nil
	}
	copy(body[:blake3.HASH_SIZE], store.store_identifier[:])
	byte_order.write_u32_little_endian(body, blake3.HASH_SIZE, u32(store.current.count))
	byte_order.write_u32_little_endian(body, blake3.HASH_SIZE + 4, 0)
	for index in 0 ..< store.current.count {
		entry := store.current.entries[index]
		place := STORE_OFFER_HEADER_SIZE + index * STORE_ENTRY_WIRE_SIZE
		copy(body[place:][:blake3.HASH_SIZE], entry.identifier[:])
		copy(body[place + blake3.HASH_SIZE:][:blake3.HASH_SIZE], entry.hash[:])
	}
	return frame_bytes(output, body)
}

// store_offer_read reads the body of an offer or of its reply: the border
// of each count and of the order of the entries.
store_offer_read :: proc "contextless" (body: []u8) -> (store_identifier: blake3.Hash, version: Store_Version, status: Store_Status) {
	if len(body) < STORE_OFFER_HEADER_SIZE {
		return {}, {}, .Refused_Bad_Count
	}
	copy(store_identifier[:], body[:blake3.HASH_SIZE])
	if hash_is_zero(store_identifier) {
		return {}, {}, .Refused_Zero_Identifier
	}
	count := u64(byte_order.read_u32_little_endian(body, blake3.HASH_SIZE))
	if byte_order.read_u32_little_endian(body, blake3.HASH_SIZE + 4) != 0 {
		return {}, {}, .Refused_Reserved_Set
	}
	if count > STORE_ENTRY_CAPACITY || u64(len(body)) != STORE_OFFER_HEADER_SIZE + count * STORE_ENTRY_WIRE_SIZE {
		return {}, {}, .Refused_Bad_Count
	}
	for index in 0 ..< int(count) {
		place := STORE_OFFER_HEADER_SIZE + index * STORE_ENTRY_WIRE_SIZE
		entry: Store_Entry
		copy(entry.identifier[:], body[place:][:blake3.HASH_SIZE])
		copy(entry.hash[:], body[place + blake3.HASH_SIZE:][:blake3.HASH_SIZE])
		if hash_is_zero(entry.identifier) {
			return {}, {}, .Refused_Zero_Identifier
		}
		if hash_is_zero(entry.hash) {
			return {}, {}, .Refused_Zero_Hash
		}
		if index > 0 && identifier_compare(version.entries[index - 1].identifier, entry.identifier) >= 0 {
			return {}, {}, .Refused_Not_Sorted
		}
		version.entries[index] = entry
	}
	version.count = int(count)
	return store_identifier, version, .Ok
}

// store_offer_reply_accept takes the reply of the partner to an offer of
// this machine, and merges as the partner merged.
store_offer_reply_accept :: proc "contextless" (store: ^Exchanged_Store, answer: []u8) -> (status: Store_Status, reason: Refusal_Reason, detail: u32) {
	if store == nil || !store.in_use {
		return .Refused_Nil_Input, .None, 0
	}
	body, refusal, refusal_detail, ok := answer_expect(answer, .Store_Offer_Reply)
	if !ok {
		return .Refused_Nil_Input, refusal, refusal_detail
	}
	identifier, theirs, read_status := store_offer_read(body)
	if read_status != .Ok {
		return read_status, .Malformed, 0
	}
	if identifier != store.store_identifier {
		return .Refused_Other_Store, .Malformed, 0
	}
	merged, conflicts, conflict_count, merge_status := store_merge_compute(store, &theirs)
	if merge_status != .Ok {
		return merge_status, .None, 0
	}
	store_merge_apply(store, &merged, &conflicts, conflict_count)
	return .Ok, .None, 0
}
