// The exchange of one store of a principal between two paired machines
// (src/md/features/several_machines.md, "The exchange of a store between
// machines", and "The store exchange in frames").
//
// A version of a store is its entries, an object identifier and the hash of
// the object sorted by identifier, with the record of each conflict value
// that an entry holds. Each machine writes its own version at once, also
// with no link. When the two machines meet, the sender offers a snapshot of
// its version with the hash of the common version; the receiver answers its
// own version, then each side runs the same three-way merge against the
// common version. The merge is symmetric (machine_mesh.reconcile_object
// orders the two sides), so both machines end with the same common version.
//
// An object that both sides changed to two hashes becomes a conflict value:
// the merged entry holds its hash, and its record keeps the base and both
// sides. A side can itself be a conflict value, when a write in flight meets
// a conflict of the merge: the version then keeps the record of that older
// conflict too, so no write is lost. A conflict record crosses with its
// entry, and its reader computes its hash again. A write of that object is
// refused until the principal resolves the conflict, once, with all the
// records of the object.
//
// A reply can be lost after the receiver merged. The sender then keeps its
// offer and sends the same snapshot again; the receiver knows the last
// exchange that it answered and answers it again, unchanged. Any other offer
// whose common version differs from the common version of the receiver is
// refused, and changes nothing.
package machine_wire

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/machine_mesh"

STORE_ENTRY_CAPACITY :: 32 // The objects of one exchanged store at most.
STORE_CONFLICT_CAPACITY :: 16 // The conflict values of one version at most.
EXCHANGED_STORE_CAPACITY :: 2 // The stores that the plan of the principal exchanges on this machine.
STORE_ENTRY_WIRE_SIZE :: 2 * blake3.HASH_SIZE // The identifier and the hash.
STORE_CONFLICT_WIRE_SIZE :: 4 * blake3.HASH_SIZE // The identifier, the base, the two sides.
// The store identifier, the hash of the common version, the count of the
// entries and the count of the conflicts.
STORE_OFFER_HEADER_SIZE :: 2 * blake3.HASH_SIZE + 8
STORE_OFFER_LIMIT :: STORE_OFFER_HEADER_SIZE + STORE_ENTRY_CAPACITY * STORE_ENTRY_WIRE_SIZE + STORE_CONFLICT_CAPACITY * STORE_CONFLICT_WIRE_SIZE
#assert(STORE_OFFER_LIMIT <= FRAME_BODY_LIMIT)
STORE_VERSION_HASH_DOMAIN :: "modus exchanged store version v1"

// One object of a version: its identifier, which a rename keeps, and the
// hash of its bytes. A zero hash is no entry: the object is absent.
Store_Entry :: struct {
	identifier: blake3.Hash,
	hash:       blake3.Hash,
}

// A conflict value: the entry of identifier holds value.conflict_value_hash.
Store_Conflict :: struct {
	identifier: blake3.Hash,
	value:      machine_mesh.Conflict_Value,
}

Store_Version :: struct {
	entries:        [STORE_ENTRY_CAPACITY]Store_Entry,
	count:          int,
	conflicts:      [STORE_CONFLICT_CAPACITY]Store_Conflict, // Sorted by identifier, then by the hash of the conflict value.
	conflict_count: int,
}

Exchanged_Store :: struct {
	in_use:            bool,
	store_identifier:  blake3.Hash,
	partner_identity:  [machine_mesh.PUBLIC_KEY_SIZE]u8, // The one paired machine that the plan names for this store.
	current:           Store_Version,
	common:            Store_Version, // The newest version that both machines hold: the base of the next merge.
	// The sender side: the snapshot of the offer in flight. It goes again
	// until a reply comes; writes after it go to current.
	offered:           Store_Version,
	has_offer:         bool,
	// The receiver side: the last exchange that this machine answered, so
	// that the repeat of an offer whose reply was lost gets the same reply.
	previous_common:   Store_Version,
	last_offer_hash:   blake3.Hash,
	last_reply:        Store_Version,
	has_last_exchange: bool,
}

Store_Status :: enum u8 {
	Ok                           = 1,
	Refused_Nil_Input            = 2,
	Refused_Zero_Identifier      = 3, // A store identifier, an object identifier or a partner key is zero.
	Refused_Unknown_Store        = 4, // No exchanged store has this identifier.
	Refused_Not_Partner          = 5, // The plan exchanges this store with another machine.
	Refused_Full                 = 6, // The table of stores, the entries or the conflicts of a version have no room.
	Refused_Holds_Conflict       = 7, // A write of an object whose entry is a conflict value: resolve it first.
	Refused_No_Conflict          = 8, // A resolution of an object that holds no conflict.
	Refused_Bad_Resolution       = 9, // A resolution that keeps the conflict value itself.
	Refused_Not_Sorted           = 10, // The entries or the conflicts of an offer are not in the order of the identifiers.
	Refused_Bad_Count            = 11, // A count of an offer is over its capacity or differs from its bytes.
	Refused_Zero_Hash            = 12, // An offer holds an entry with a zero hash.
	Refused_Duplicate_Identifier = 13, // An offer names one identifier twice.
	Refused_Exists               = 14, // The store is exchanged already.
	Refused_Other_Store          = 15, // The answer names another store than the offer.
	Refused_Base_Differs         = 16, // The common version of the other machine is not the common version of this one.
	Refused_Bad_Conflict         = 17, // A conflict record whose hash or whose entry does not match.
	Refused_No_Offer             = 18, // A reply, and this machine has no offer in flight.
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
// this one hash. The hash of a conflict value is in its entry, so the
// records add nothing to it.
store_version_hash :: proc "contextless" (version: ^Store_Version) -> blake3.Hash {
	bytes: [STORE_ENTRY_CAPACITY * STORE_ENTRY_WIRE_SIZE]u8
	for index in 0 ..< version.count {
		entry := version.entries[index]
		copy(bytes[index * STORE_ENTRY_WIRE_SIZE:][:blake3.HASH_SIZE], entry.identifier[:])
		copy(bytes[index * STORE_ENTRY_WIRE_SIZE + blake3.HASH_SIZE:][:blake3.HASH_SIZE], entry.hash[:])
	}
	return blake3.derive_key(STORE_VERSION_HASH_DOMAIN, bytes[:version.count * STORE_ENTRY_WIRE_SIZE])
}

// store_conflict_find gives the conflict whose value the entry of
// identifier holds, or nil. Older records of the object are its sides.
store_conflict_find :: proc "contextless" (version: ^Store_Version, identifier: blake3.Hash) -> ^Store_Conflict {
	entry := store_version_lookup(version, identifier)
	for index in 0 ..< version.conflict_count {
		if version.conflicts[index].identifier == identifier && version.conflicts[index].value.conflict_value_hash == entry {
			return &version.conflicts[index]
		}
	}
	return nil
}

@(private)
version_holds_conflict :: proc "contextless" (version: ^Store_Version, identifier: blake3.Hash) -> bool {
	for index in 0 ..< version.conflict_count {
		if version.conflicts[index].identifier == identifier {
			return true
		}
	}
	return false
}

// conflict_compare orders two records by identifier, then by the hash of
// the conflict value.
@(private)
conflict_compare :: proc "contextless" (left, right: ^Store_Conflict) -> int {
	order := identifier_compare(left.identifier, right.identifier)
	if order != 0 {
		return order
	}
	return identifier_compare(left.value.conflict_value_hash, right.value.conflict_value_hash)
}

@(private)
conflict_names :: proc "contextless" (record: ^Store_Conflict, hash: blake3.Hash) -> bool {
	return record.value.base_hash == hash || record.value.local_hash == hash || record.value.remote_hash == hash
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

// store_exchange_remove ends the exchange of a store: the plan no longer
// names it. The versions of this machine stay in the store itself.
store_exchange_remove :: proc "contextless" (stores: ^[EXCHANGED_STORE_CAPACITY]Exchanged_Store, store_identifier: blake3.Hash) -> Store_Status {
	store := store_exchange_find(stores, store_identifier)
	if store == nil {
		return .Refused_Unknown_Store
	}
	store^ = {}
	return .Ok
}

store_exchange_find :: proc "contextless" (stores: ^[EXCHANGED_STORE_CAPACITY]Exchanged_Store, store_identifier: blake3.Hash) -> ^Exchanged_Store {
	if stores == nil || hash_is_zero(store_identifier) {
		return nil
	}
	for &item in stores {
		if item.in_use && item.store_identifier == store_identifier {
			return &item
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
// hash, or is removed when hash is zero. It goes to the current version,
// also while an offer is in flight. An object that holds a conflict value
// is refused: the principal resolves it first.
store_write :: proc "contextless" (store: ^Exchanged_Store, identifier: blake3.Hash, hash: blake3.Hash) -> Store_Status {
	if store == nil || !store.in_use {
		return .Refused_Nil_Input
	}
	if hash_is_zero(identifier) {
		return .Refused_Zero_Identifier
	}
	if version_holds_conflict(&store.current, identifier) {
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
	conflict := store_conflict_find(&store.current, identifier)
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
	// The resolution ends the conflict and each older conflict that it holds.
	version := &store.current
	kept := 0
	for index in 0 ..< version.conflict_count {
		if version.conflicts[index].identifier != identifier {
			version.conflicts[kept] = version.conflicts[index]
			kept += 1
		}
	}
	for index in kept ..< version.conflict_count {
		version.conflicts[index] = {}
	}
	version.conflict_count = kept
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

// merge_conflict_records gives the merged version the records of the
// object identifier that its chosen hash reaches: the new conflict, a
// record of either side whose value is the chosen hash, and each older
// record that a kept record names as its base or a side. They go in the
// order of their value hashes.
@(private)
merge_conflict_records :: proc "contextless" (merged: ^Store_Version, identifier, chosen: blake3.Hash, ours, theirs: ^Store_Version, new_record: ^Store_Conflict) -> Store_Status {
	if hash_is_zero(chosen) {
		return .Ok
	}
	start := merged.conflict_count
	if new_record != nil {
		if merged.conflict_count >= STORE_CONFLICT_CAPACITY {
			return .Refused_Full
		}
		merged.conflicts[merged.conflict_count] = new_record^
		merged.conflict_count += 1
	}
	changed := true
	for changed {
		changed = false
		for source in ([2]^Store_Version{ours, theirs}) {
			for index in 0 ..< source.conflict_count {
				record := &source.conflicts[index]
				if record.identifier != identifier {
					continue
				}
				known := false
				reached := record.value.conflict_value_hash == chosen
				for kept in start ..< merged.conflict_count {
					if merged.conflicts[kept].value.conflict_value_hash == record.value.conflict_value_hash {
						known = true
					}
					if conflict_names(&merged.conflicts[kept], record.value.conflict_value_hash) {
						reached = true
					}
				}
				if known || !reached {
					continue
				}
				if merged.conflict_count >= STORE_CONFLICT_CAPACITY {
					return .Refused_Full
				}
				merged.conflicts[merged.conflict_count] = record^
				merged.conflict_count += 1
				changed = true
			}
		}
	}
	// The order of the value hashes within the object.
	for index in start + 1 ..< merged.conflict_count {
		place := index
		for place > start && conflict_compare(&merged.conflicts[place - 1], &merged.conflicts[place]) > 0 {
			merged.conflicts[place - 1], merged.conflicts[place] = merged.conflicts[place], merged.conflicts[place - 1]
			place -= 1
		}
	}
	return .Ok
}

// store_merge runs the three-way merge of base, ours and theirs, entry by
// entry in the order of the identifiers. A new conflict gets its record;
// the record of an older conflict, from either side, stays while the merged
// entry still holds its hash. It changes nothing: the caller applies the
// result only when each merge of the exchange fits.
store_merge :: proc "contextless" (base, ours, theirs: ^Store_Version) -> (merged: Store_Version, status: Store_Status) {
	base_index, our_index, their_index := 0, 0, 0
	for base_index < base.count || our_index < ours.count || their_index < theirs.count {
		// The smallest identifier of the three cursors.
		smallest: blake3.Hash
		has_smallest := false
		versions := [3]^Store_Version{base, ours, theirs}
		indexes := [3]int{base_index, our_index, their_index}
		for version, which in versions {
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
		new_record: Store_Conflict
		has_new_record := false
		switch decision {
		case .Unchanged, .Take_Local, .Take_Remote, .Both_Same:
		case .Conflict_Keep_Both:
			new_record, has_new_record = Store_Conflict{identifier = smallest, value = conflict}, true
		}
		if records_status := merge_conflict_records(&merged, smallest, chosen, ours, theirs, has_new_record ? &new_record : nil); records_status != .Ok {
			return {}, records_status
		}
		if hash_is_zero(chosen) {
			continue
		}
		if merged.count >= STORE_ENTRY_CAPACITY {
			return {}, .Refused_Full
		}
		merged.entries[merged.count] = Store_Entry{identifier = smallest, hash = chosen}
		merged.count += 1
	}
	return merged, .Ok
}

// store_offer_write writes a Store_Offer or a Store_Offer_Reply: a version
// with its conflict records, and the hash of the common version.
store_offer_write :: proc "contextless" (output: []u8, message: Message, store_identifier: blake3.Hash, common_hash: blake3.Hash, version: ^Store_Version) -> []u8 {
	if version == nil || (message != .Store_Offer && message != .Store_Offer_Reply) {
		return nil
	}
	body, ok := frame_begin(output, message, STORE_OFFER_HEADER_SIZE + version.count * STORE_ENTRY_WIRE_SIZE + version.conflict_count * STORE_CONFLICT_WIRE_SIZE)
	if !ok {
		return nil
	}
	identifier, common := store_identifier, common_hash
	copy(body[:32], identifier[:])
	copy(body[32:64], common[:])
	byte_order.write_u32_little_endian(body, 64, u32(version.count))
	byte_order.write_u32_little_endian(body, 68, u32(version.conflict_count))
	place := STORE_OFFER_HEADER_SIZE
	for index in 0 ..< version.count {
		entry := version.entries[index]
		copy(body[place:][:32], entry.identifier[:])
		copy(body[place + 32:][:32], entry.hash[:])
		place += STORE_ENTRY_WIRE_SIZE
	}
	for index in 0 ..< version.conflict_count {
		conflict := version.conflicts[index]
		copy(body[place:][:32], conflict.identifier[:])
		copy(body[place + 32:][:32], conflict.value.base_hash[:])
		copy(body[place + 64:][:32], conflict.value.local_hash[:])
		copy(body[place + 96:][:32], conflict.value.remote_hash[:])
		place += STORE_CONFLICT_WIRE_SIZE
	}
	return frame_bytes(output, body)
}

// store_offer_read reads the whole body of an offer or of its reply before
// any store changes: each count against the bytes and the capacities, the
// order and the uniqueness of the identifiers, and each conflict record
// against its entry, whose hash it computes again.
store_offer_read :: proc "contextless" (body: []u8) -> (store_identifier: blake3.Hash, common_hash: blake3.Hash, version: Store_Version, status: Store_Status) {
	if len(body) < STORE_OFFER_HEADER_SIZE {
		return {}, {}, {}, .Refused_Bad_Count
	}
	copy(store_identifier[:], body[:32])
	copy(common_hash[:], body[32:64])
	if hash_is_zero(store_identifier) {
		return {}, {}, {}, .Refused_Zero_Identifier
	}
	count := u64(byte_order.read_u32_little_endian(body, 64))
	conflict_count := u64(byte_order.read_u32_little_endian(body, 68))
	if count > STORE_ENTRY_CAPACITY || conflict_count > STORE_CONFLICT_CAPACITY || u64(len(body)) != STORE_OFFER_HEADER_SIZE + count * STORE_ENTRY_WIRE_SIZE + conflict_count * STORE_CONFLICT_WIRE_SIZE {
		return {}, {}, {}, .Refused_Bad_Count
	}
	place := STORE_OFFER_HEADER_SIZE
	for index in 0 ..< int(count) {
		entry: Store_Entry
		copy(entry.identifier[:], body[place:][:32])
		copy(entry.hash[:], body[place + 32:][:32])
		place += STORE_ENTRY_WIRE_SIZE
		if hash_is_zero(entry.identifier) {
			return {}, {}, {}, .Refused_Zero_Identifier
		}
		if hash_is_zero(entry.hash) {
			return {}, {}, {}, .Refused_Zero_Hash
		}
		if index > 0 {
			order := identifier_compare(version.entries[index - 1].identifier, entry.identifier)
			if order == 0 {
				return {}, {}, {}, .Refused_Duplicate_Identifier
			}
			if order > 0 {
				return {}, {}, {}, .Refused_Not_Sorted
			}
		}
		version.entries[index] = entry
	}
	version.count = int(count)
	for index in 0 ..< int(conflict_count) {
		conflict: Store_Conflict
		copy(conflict.identifier[:], body[place:][:32])
		copy(conflict.value.base_hash[:], body[place + 32:][:32])
		copy(conflict.value.local_hash[:], body[place + 64:][:32])
		copy(conflict.value.remote_hash[:], body[place + 96:][:32])
		place += STORE_CONFLICT_WIRE_SIZE
		// The record proves its hash: the merge of its base and its sides.
		decision, value_hash, _ := machine_mesh.reconcile_object(conflict.value.base_hash, conflict.value.local_hash, conflict.value.remote_hash)
		if decision != .Conflict_Keep_Both {
			return {}, {}, {}, .Refused_Bad_Conflict
		}
		conflict.value.conflict_value_hash = value_hash
		if index > 0 {
			order := conflict_compare(&version.conflicts[index - 1], &conflict)
			if order == 0 {
				return {}, {}, {}, .Refused_Duplicate_Identifier
			}
			if order > 0 {
				return {}, {}, {}, .Refused_Not_Sorted
			}
		}
		version.conflicts[index] = conflict
	}
	version.conflict_count = int(conflict_count)
	// Each record is the conflict that its entry holds, or an older conflict
	// that another record of the same object names: no record stands alone.
	for index in 0 ..< version.conflict_count {
		record := &version.conflicts[index]
		reached := store_version_lookup(&version, record.identifier) == record.value.conflict_value_hash
		for other in 0 ..< version.conflict_count {
			if other != index && version.conflicts[other].identifier == record.identifier && conflict_names(&version.conflicts[other], record.value.conflict_value_hash) {
				reached = true
			}
		}
		if !reached {
			return {}, {}, {}, .Refused_Bad_Conflict
		}
	}
	return store_identifier, common_hash, version, .Ok
}

// store_offer_begin writes the offer of this machine. The first call takes
// the snapshot of the current version; each call until a reply sends that
// same snapshot, so a repeat after a lost reply finds its answer.
store_offer_begin :: proc "contextless" (store: ^Exchanged_Store, output: []u8) -> []u8 {
	if store == nil || !store.in_use {
		return nil
	}
	if !store.has_offer {
		store.offered = store.current
		store.has_offer = true
	}
	return store_offer_write(output, .Store_Offer, store.store_identifier, store_version_hash(&store.common), &store.offered)
}

// store_offer_answer is the receiver of an offer of the partner: the whole
// body is read and the merge computed before any change. It answers the
// version of this machine before the merge, then applies the merge.
store_offer_answer :: proc "contextless" (store: ^Exchanged_Store, body: []u8, output: []u8) -> (frame: []u8, status: Store_Status) {
	identifier, common_hash, theirs, read_status := store_offer_read(body)
	if read_status != .Ok {
		return nil, read_status
	}
	if store == nil || !store.in_use || identifier != store.store_identifier {
		return nil, .Refused_Unknown_Store
	}
	offer_hash := store_version_hash(&theirs)
	if common_hash != store_version_hash(&store.common) {
		// The repeat of the last offer that this machine answered: its
		// reply was lost, so it gets the same reply, and nothing changes.
		if store.has_last_exchange && common_hash == store_version_hash(&store.previous_common) && offer_hash == store.last_offer_hash {
			frame = store_offer_write(output, .Store_Offer_Reply, store.store_identifier, common_hash, &store.last_reply)
			return frame, frame == nil ? .Refused_Full : .Ok
		}
		return nil, .Refused_Base_Differs
	}
	merged, merge_status := store_merge(&store.common, &store.current, &theirs)
	if merge_status != .Ok {
		return nil, merge_status
	}
	frame = store_offer_write(output, .Store_Offer_Reply, store.store_identifier, common_hash, &store.current)
	if frame == nil {
		return nil, .Refused_Full
	}
	store.previous_common = store.common
	store.last_offer_hash = offer_hash
	store.last_reply = store.current
	store.has_last_exchange = true
	store.current = merged
	store.common = merged
	// An offer of this machine in flight is void: the merge took its current
	// version, and the next offer starts from the new common version.
	store.has_offer = false
	store.offered = {}
	return frame, .Ok
}

// store_offer_reply_accept takes the reply of the partner to the offer in
// flight. It merges as the partner merged, from the snapshot of the offer,
// then merges the writes made since the snapshot over that result. Both
// merges are computed before any change.
store_offer_reply_accept :: proc "contextless" (store: ^Exchanged_Store, answer: []u8) -> (status: Store_Status, reason: Refusal_Reason, detail: u32) {
	if store == nil || !store.in_use {
		return .Refused_Nil_Input, .None, 0
	}
	if !store.has_offer {
		return .Refused_No_Offer, .None, 0
	}
	body, refusal, refusal_detail, ok := answer_expect(answer, .Store_Offer_Reply)
	if !ok {
		return .Refused_Nil_Input, refusal, refusal_detail
	}
	identifier, common_hash, theirs, read_status := store_offer_read(body)
	if read_status != .Ok {
		return read_status, .Malformed, 0
	}
	if identifier != store.store_identifier {
		return .Refused_Other_Store, .Malformed, 0
	}
	if common_hash != store_version_hash(&store.common) {
		return .Refused_Base_Differs, .None, 0
	}
	merged, merge_status := store_merge(&store.common, &store.offered, &theirs)
	if merge_status != .Ok {
		return merge_status, .None, 0
	}
	with_later_writes, later_status := store_merge(&store.offered, &store.current, &merged)
	if later_status != .Ok {
		return later_status, .None, 0
	}
	store.common = merged
	store.current = with_later_writes
	store.has_offer = false
	store.offered = {}
	return .Ok, .None, 0
}
