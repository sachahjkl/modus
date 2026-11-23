// The exchange of one store of a principal between two paired machines
// (src/md/features/several_machines.md, "The exchange of a store between
// machines").
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
// A version has any count of entries: its tables are memory of the caller
// (store_exchange_memory_bind), and it crosses in pages. Each page names the
// hash of the whole version, its counts, and the cursor where it starts;
// the reader appends the pages in order and checks the hash of the whole
// version before any merge. The offer goes page by page, the receiver takes
// each one (Page_Taken), merges at the last one and answers the first page
// of its reply; the sender asks for the other pages of the reply
// (Reply_Page_Request) and merges at the last one.
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
// offer and sends the same snapshot again from its first page; the receiver
// knows the last exchange that it answered (by the hash of the offer) and
// answers it again, unchanged, from its first page. Any other offer whose
// common version differs from the common version of the receiver is
// refused, and changes nothing.
package machine_wire

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/machine_mesh"

STORE_ENTRY_WIRE_SIZE :: 2 * blake3.HASH_SIZE // The identifier and the hash.
STORE_CONFLICT_WIRE_SIZE :: 4 * blake3.HASH_SIZE // The identifier, the base, the two sides.
// The head of a page: the store identifier, the hash of the common version,
// the hash of the whole version of the page, then eight words: the phase,
// the entries and the conflicts of the whole version, the place of the
// first entry and of the first conflict of the page, the entries and the
// conflicts of the page, and a zero word.
STORE_PAGE_HEADER_SIZE :: 3 * blake3.HASH_SIZE + 8 * 4
// The bytes of the entries and the conflicts of one page at most: what one
// frame carries past its head.
STORE_PAGE_ITEM_BYTES :: FRAME_BODY_LIMIT - STORE_PAGE_HEADER_SIZE
#assert(STORE_PAGE_ITEM_BYTES >= STORE_CONFLICT_WIRE_SIZE)
STORE_VERSION_HASH_DOMAIN :: "modus exchanged store version v1"

// The versions that one exchanged store keeps: current, common, the
// snapshot of its offer, the common version and the reply of its last
// answer, the offer and the reply that it assembles, and two merges.
STORE_VERSIONS_OF_A_STORE :: 9

// What a page of a store exchange carries.
Store_Page_Phase :: enum u32 {
	None               = 0, // Not a phase: refused.
	Offer_Page         = 1, // A page of the offer of the sender.
	Reply_Page_Request = 2, // The sender asks for the page of the reply at the cursor.
	Page_Taken         = 3, // The receiver took a page of the offer: the cursor names the next one.
	Reply_Page         = 4, // A page of the reply of the receiver: its version before its merge.
}

// One object of a version: its identifier, which a rename keeps, and the
// hash of its bytes. A zero hash is no entry: the object is absent.
Store_Entry :: struct {
	identifier: blake3.Hash,
	hash:       blake3.Hash,
}
#assert(size_of(Store_Entry) == STORE_ENTRY_WIRE_SIZE)

// A conflict value: the entry of identifier holds value.conflict_value_hash.
Store_Conflict :: struct {
	identifier: blake3.Hash,
	value:      machine_mesh.Conflict_Value,
}

// The procedure that grows the tables of a version in place: after it, the
// entries hold at least entries_least and the conflicts at least
// conflicts_least, with the content of before kept. The owner of the
// memory commits the pages that its budget pays; false is a budget that
// pays no more, and the version keeps its tables.
Store_Version_Grow :: #type proc "contextless" (user: rawptr, version: ^Store_Version, entries_least, conflicts_least: int) -> bool

// The procedure that gives back the memory of an empty version, after a
// refusal emptied it: the pages that a partner made it take go back to
// the budget of the owner. The version then holds no table, and grows
// again at its next page.
Store_Version_Trim :: #type proc "contextless" (user: rawptr, version: ^Store_Version)

// A version: its tables are memory of the caller, and their lengths are
// its capacities now. With grow, the tables grow when a write, a merge or
// a page needs room, so a version has the size that the budget of its
// owner pays, and no count of the contract.
Store_Version :: struct {
	entries:        []Store_Entry,
	count:          int,
	conflicts:      []Store_Conflict, // Sorted by identifier, then by the hash of the conflict value.
	conflict_count: int,
	grow:           Store_Version_Grow,
	grow_user:      rawptr,
	trim:           Store_Version_Trim,
}

// version_trim empties a version and gives its memory back.
@(private)
version_trim :: proc "contextless" (version: ^Store_Version) {
	version_clear(version)
	if version.trim != nil {
		version.trim(version.grow_user, version)
	}
}

// version_room makes room in a version for entries and conflicts: true
// when its tables hold them, after a growth when they did not.
@(private)
version_room :: proc "contextless" (version: ^Store_Version, entries, conflicts: int) -> bool {
	if entries <= len(version.entries) && conflicts <= len(version.conflicts) {
		return true
	}
	if version.grow == nil || !version.grow(version.grow_user, version, entries, conflicts) {
		return false
	}
	return entries <= len(version.entries) && conflicts <= len(version.conflicts)
}

// The table of the exchanged stores of a peer: its rows are memory of the
// caller, and grow (when given) adds rows in place when each row is taken.
Store_Table_Grow :: #type proc "contextless" (user: rawptr, table: ^Store_Table, rows_least: int) -> bool

Store_Table :: struct {
	rows:      []Exchanged_Store,
	grow:      Store_Table_Grow,
	grow_user: rawptr,
	// The growth of the versions of each store: each version of a row takes
	// it when the row is taken.
	version_grow:      Store_Version_Grow,
	version_grow_user: rawptr,
	version_trim:      Store_Version_Trim,
}

// The place of a page in a version: its first entry and its first conflict.
Store_Cursor :: struct {
	entry:    int,
	conflict: int,
}

// A version that arrives in pages: the hash and the counts that its first
// page announced, and the cursor of the next page.
Store_Assembly :: struct {
	active:         bool,
	version_hash:   blake3.Hash,
	common_hash:    blake3.Hash,
	entry_total:    int,
	conflict_total: int,
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
	offer_cursor:      Store_Cursor, // The next page of the offer to send.
	reply:             Store_Version, // The reply of the partner, page by page.
	reply_assembly:    Store_Assembly,
	// The receiver side: the offer of the partner, page by page, and the
	// last exchange that this machine answered, so that the repeat of an
	// offer whose reply was lost gets the same reply.
	incoming:          Store_Version,
	incoming_assembly: Store_Assembly,
	previous_common:   Store_Version,
	last_offer_hash:   blake3.Hash,
	last_reply:        Store_Version,
	has_last_exchange: bool,
	// Two versions for the merges of an exchange, before it applies them.
	merged:            Store_Version,
	merged_later:      Store_Version,
	// The pages that the owner of the memory counts for the versions of this
	// store: its share of the memory of the mesh (memory_shares.odin). The
	// contract keeps it; only the owner writes it.
	memory_pages:      u64,
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
	Refused_Bad_Count            = 11, // A count of a page differs from its bytes or passes the counts of its version.
	Refused_Zero_Hash            = 12, // An offer holds an entry with a zero hash.
	Refused_Duplicate_Identifier = 13, // An offer names one identifier twice.
	Refused_Exists               = 14, // The store is exchanged already.
	Refused_Other_Store          = 15, // The answer names another store than the offer.
	Refused_Base_Differs         = 16, // The common version of the other machine is not the common version of this one.
	Refused_Bad_Conflict         = 17, // A conflict record whose hash or whose entry does not match.
	Refused_No_Offer             = 18, // A reply, and this machine has no offer in flight.
	Refused_Out_Of_Order         = 19, // A page that does not start where the pages before ended, or of another version.
	Refused_Version_Hash         = 20, // The pages of a version, whole, do not have the hash that its first page named.
	Refused_Bad_Phase            = 21, // A phase that names no member, or that this side does not take.
	// The exchange stopped between two pages: the next page did not leave,
	// or its answer did not come. The store of this side kept what it held;
	// the next sync starts the version again at its first page.
	Stopped_Between_Pages        = 22,
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

// store_exchange_memory_bind gives a store the memory of its versions: the
// entries and the conflicts are divided among its STORE_VERSIONS_OF_A_STORE
// versions, so each version holds len(entries) / STORE_VERSIONS_OF_A_STORE
// entries.
store_exchange_memory_bind :: proc "contextless" (store: ^Exchanged_Store, entries: []Store_Entry, conflicts: []Store_Conflict) {
	entry_share := len(entries) / STORE_VERSIONS_OF_A_STORE
	conflict_share := len(conflicts) / STORE_VERSIONS_OF_A_STORE
	versions := [STORE_VERSIONS_OF_A_STORE]^Store_Version{&store.current, &store.common, &store.offered, &store.reply, &store.incoming, &store.previous_common, &store.last_reply, &store.merged, &store.merged_later}
	for version, index in versions {
		version^ = Store_Version {
			entries   = entries[index * entry_share:][:entry_share],
			conflicts = conflicts[index * conflict_share:][:conflict_share],
		}
	}
}

// store_exchange_reset empties a store and keeps its memory.
@(private)
store_exchange_reset :: proc "contextless" (store: ^Exchanged_Store) {
	versions := [STORE_VERSIONS_OF_A_STORE]^Store_Version{&store.current, &store.common, &store.offered, &store.reply, &store.incoming, &store.previous_common, &store.last_reply, &store.merged, &store.merged_later}
	kept: [STORE_VERSIONS_OF_A_STORE]Store_Version
	for version, index in versions {
		kept[index] = {entries = version.entries, conflicts = version.conflicts, grow = version.grow, grow_user = version.grow_user, trim = version.trim}
	}
	// The pages that the owner counts follow the memory of the versions.
	memory_pages := store.memory_pages
	store^ = {}
	store.memory_pages = memory_pages
	for version, index in versions {
		version^ = kept[index]
	}
}

@(private)
version_clear :: proc "contextless" (version: ^Store_Version) {
	version.count = 0
	version.conflict_count = 0
}

// version_copy makes destination the same version as source, in the memory
// of destination.
@(private)
version_copy :: proc "contextless" (destination, source: ^Store_Version) -> Store_Status {
	if destination == source {
		return .Ok
	}
	if !version_room(destination, source.count, source.conflict_count) {
		return .Refused_Full
	}
	copy(destination.entries, source.entries[:source.count])
	copy(destination.conflicts, source.conflicts[:source.conflict_count])
	destination.count = source.count
	destination.conflict_count = source.conflict_count
	return .Ok
}

// store_version_lookup gives the hash of identifier in a version, or zero.
store_version_lookup :: proc "contextless" (version: ^Store_Version, identifier: blake3.Hash) -> blake3.Hash {
	low, high := 0, version.count
	for low < high {
		middle := (low + high) / 2
		order := identifier_compare(version.entries[middle].identifier, identifier)
		if order == 0 {
			return version.entries[middle].hash
		}
		if order < 0 {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return {}
}

// store_version_hash names a whole version: two machines compare a store by
// this one hash. The hash of a conflict value is in its entry, so the
// records add nothing to it.
store_version_hash :: proc "contextless" (version: ^Store_Version) -> blake3.Hash {
	if version.count == 0 {
		return blake3.derive_key(STORE_VERSION_HASH_DOMAIN, nil)
	}
	bytes := ([^]u8)(raw_data(version.entries))[:version.count * STORE_ENTRY_WIRE_SIZE]
	return blake3.derive_key(STORE_VERSION_HASH_DOMAIN, bytes)
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

// store_exchange_add names a store that the plan exchanges with one paired
// machine. The store takes a free row of the table, with the memory of its
// versions that the row holds.
store_exchange_add :: proc "contextless" (stores: ^Store_Table, store_identifier: blake3.Hash, partner_identity: [machine_mesh.PUBLIC_KEY_SIZE]u8) -> (store: ^Exchanged_Store, status: Store_Status) {
	if stores == nil {
		return nil, .Refused_Nil_Input
	}
	if hash_is_zero(store_identifier) || machine_mesh.key_is_zero(partner_identity) {
		return nil, .Refused_Zero_Identifier
	}
	free: ^Exchanged_Store
	for &item in stores.rows {
		if item.in_use && item.store_identifier == store_identifier {
			return nil, .Refused_Exists
		}
		if !item.in_use && free == nil {
			free = &item
		}
	}
	if free == nil {
		// Each row is taken: the table grows by one row in place, when its
		// owner pays it.
		rows := len(stores.rows)
		if stores.grow == nil || !stores.grow(stores.grow_user, stores, rows + 1) || len(stores.rows) <= rows {
			return nil, .Refused_Full
		}
		free = &stores.rows[rows]
		free^ = {}
	}
	store_exchange_reset(free)
	if stores.version_grow != nil {
		versions := [STORE_VERSIONS_OF_A_STORE]^Store_Version{&free.current, &free.common, &free.offered, &free.reply, &free.incoming, &free.previous_common, &free.last_reply, &free.merged, &free.merged_later}
		for version in versions {
			version.grow = stores.version_grow
			version.grow_user = stores.version_grow_user
			version.trim = stores.version_trim
		}
	}
	free.in_use = true
	free.store_identifier = store_identifier
	free.partner_identity = partner_identity
	return free, .Ok
}

// store_exchange_remove ends the exchange of a store: the plan no longer
// names it. The versions of this machine stay in the store itself.
store_exchange_remove :: proc "contextless" (stores: ^Store_Table, store_identifier: blake3.Hash) -> Store_Status {
	store := store_exchange_find(stores, store_identifier)
	if store == nil {
		return .Refused_Unknown_Store
	}
	store_exchange_reset(store)
	return .Ok
}

store_exchange_find :: proc "contextless" (stores: ^Store_Table, store_identifier: blake3.Hash) -> ^Exchanged_Store {
	if stores == nil || hash_is_zero(store_identifier) {
		return nil
	}
	for &item in stores.rows {
		if item.in_use && item.store_identifier == store_identifier {
			return &item
		}
	}
	return nil
}

@(private)
version_set :: proc "contextless" (version: ^Store_Version, identifier: blake3.Hash, hash: blake3.Hash) -> Store_Status {
	place := 0
	low, high := 0, version.count
	for low < high {
		middle := (low + high) / 2
		if identifier_compare(version.entries[middle].identifier, identifier) < 0 {
			low = middle + 1
		} else {
			high = middle
		}
	}
	place = low
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
	if !version_room(version, version.count + 1, version.conflict_count) {
		return .Refused_Full
	}
	copy(version.entries[place + 1:version.count + 1], version.entries[place:version.count])
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
		if !version_room(merged, merged.count, merged.conflict_count + 1) {
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
				if !version_room(merged, merged.count, merged.conflict_count + 1) {
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

// store_merge runs the three-way merge of base, ours and theirs into
// merged, entry by entry in the order of the identifiers. A new conflict
// gets its record; the record of an older conflict, from either side,
// stays while the merged entry still holds its hash. merged is memory of
// the caller that no other version shares; the caller applies the result
// only when each merge of the exchange fits.
store_merge :: proc "contextless" (base, ours, theirs: ^Store_Version, merged: ^Store_Version) -> Store_Status {
	version_clear(merged)
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
		if records_status := merge_conflict_records(merged, smallest, chosen, ours, theirs, has_new_record ? &new_record : nil); records_status != .Ok {
			return records_status
		}
		if hash_is_zero(chosen) {
			continue
		}
		if !version_room(merged, merged.count + 1, merged.conflict_count) {
			return .Refused_Full
		}
		merged.entries[merged.count] = Store_Entry{identifier = smallest, hash = chosen}
		merged.count += 1
	}
	return .Ok
}

// One page of a version, as store_page_read gives it: its head, and views
// of its entries and conflicts in the bytes of the frame.
Store_Page :: struct {
	store_identifier: blake3.Hash,
	common_hash:      blake3.Hash,
	version_hash:     blake3.Hash,
	phase:            Store_Page_Phase,
	entry_total:      int,
	conflict_total:   int,
	first:            Store_Cursor,
	entry_count:      int,
	conflict_count:   int,
	items:            []u8, // The entries, then the conflicts, as on the wire.
}

// store_page_write writes one page of a Store_Offer or of a
// Store_Offer_Reply: the head with the counts of the whole version, and the
// entries from first.entry, then the conflicts from first.conflict, as many
// as one frame carries. The conflicts start only after the last entry. A
// phase with no items (Reply_Page_Request, Page_Taken) writes the head only,
// with first as its cursor. totals are the counts of the whole version
// when version holds a part of it only (Page_Taken); else the counts of
// version. It gives the frame and the cursor after it.
store_page_write :: proc "contextless" (output: []u8, message: Message, phase: Store_Page_Phase, store_identifier, common_hash, version_hash: blake3.Hash, version: ^Store_Version, first: Store_Cursor, totals: Maybe(Store_Cursor) = nil) -> (frame: []u8, next: Store_Cursor) {
	if version == nil || (message != .Store_Offer && message != .Store_Offer_Reply) || first.entry > version.count || first.conflict > version.conflict_count || first.entry < 0 || first.conflict < 0 {
		return nil, first
	}
	entries, conflicts := 0, 0
	switch phase {
	case .None:
		return nil, first
	case .Reply_Page_Request, .Page_Taken:
	case .Offer_Page, .Reply_Page:
		room := STORE_PAGE_ITEM_BYTES
		entries = min(version.count - first.entry, room / STORE_ENTRY_WIRE_SIZE)
		room -= entries * STORE_ENTRY_WIRE_SIZE
		if first.entry + entries == version.count {
			conflicts = min(version.conflict_count - first.conflict, room / STORE_CONFLICT_WIRE_SIZE)
		}
	}
	body, ok := frame_begin(output, message, STORE_PAGE_HEADER_SIZE + entries * STORE_ENTRY_WIRE_SIZE + conflicts * STORE_CONFLICT_WIRE_SIZE)
	if !ok {
		return nil, first
	}
	identifier, common, whole := store_identifier, common_hash, version_hash
	copy(body[:32], identifier[:])
	copy(body[32:64], common[:])
	copy(body[64:96], whole[:])
	byte_order.write_u32_little_endian(body, 96, u32(phase))
	whole_counts := totals.? or_else Store_Cursor{version.count, version.conflict_count}
	byte_order.write_u32_little_endian(body, 100, u32(whole_counts.entry))
	byte_order.write_u32_little_endian(body, 104, u32(whole_counts.conflict))
	byte_order.write_u32_little_endian(body, 108, u32(first.entry))
	byte_order.write_u32_little_endian(body, 112, u32(first.conflict))
	byte_order.write_u32_little_endian(body, 116, u32(entries))
	byte_order.write_u32_little_endian(body, 120, u32(conflicts))
	byte_order.write_u32_little_endian(body, 124, 0)
	place := STORE_PAGE_HEADER_SIZE
	for index in first.entry ..< first.entry + entries {
		entry := version.entries[index]
		copy(body[place:][:32], entry.identifier[:])
		copy(body[place + 32:][:32], entry.hash[:])
		place += STORE_ENTRY_WIRE_SIZE
	}
	for index in first.conflict ..< first.conflict + conflicts {
		conflict := version.conflicts[index]
		copy(body[place:][:32], conflict.identifier[:])
		copy(body[place + 32:][:32], conflict.value.base_hash[:])
		copy(body[place + 64:][:32], conflict.value.local_hash[:])
		copy(body[place + 96:][:32], conflict.value.remote_hash[:])
		place += STORE_CONFLICT_WIRE_SIZE
	}
	return frame_bytes(output, body), Store_Cursor{first.entry + entries, first.conflict + conflicts}
}

// store_page_read reads the head of a page and checks its counts against
// its bytes and against the counts of its whole version, before any store
// changes. The entries and the conflicts are checked when they are
// appended (version_append_page).
store_page_read :: proc "contextless" (body: []u8) -> (page: Store_Page, status: Store_Status) {
	if len(body) < STORE_PAGE_HEADER_SIZE {
		return {}, .Refused_Bad_Count
	}
	copy(page.store_identifier[:], body[:32])
	copy(page.common_hash[:], body[32:64])
	copy(page.version_hash[:], body[64:96])
	if hash_is_zero(page.store_identifier) {
		return {}, .Refused_Zero_Identifier
	}
	phase, phase_ok := enum_word.member_of_word(Store_Page_Phase, u64(byte_order.read_u32_little_endian(body, 96)))
	if !phase_ok || phase == .None {
		return {}, .Refused_Bad_Phase
	}
	page.phase = phase
	entry_total := u64(byte_order.read_u32_little_endian(body, 100))
	conflict_total := u64(byte_order.read_u32_little_endian(body, 104))
	first_entry := u64(byte_order.read_u32_little_endian(body, 108))
	first_conflict := u64(byte_order.read_u32_little_endian(body, 112))
	entries := u64(byte_order.read_u32_little_endian(body, 116))
	conflicts := u64(byte_order.read_u32_little_endian(body, 120))
	if byte_order.read_u32_little_endian(body, 124) != 0 {
		return {}, .Refused_Bad_Count
	}
	if first_entry + entries > entry_total || first_conflict + conflicts > conflict_total || u64(len(body)) != STORE_PAGE_HEADER_SIZE + entries * STORE_ENTRY_WIRE_SIZE + conflicts * STORE_CONFLICT_WIRE_SIZE {
		return {}, .Refused_Bad_Count
	}
	// A conflict comes only after the last entry: the entries of a version
	// are whole before its records, which name them.
	if conflicts > 0 && first_entry + entries != entry_total {
		return {}, .Refused_Bad_Count
	}
	switch phase {
	case .None:
	case .Reply_Page_Request, .Page_Taken:
		if entries != 0 || conflicts != 0 {
			return {}, .Refused_Bad_Count
		}
	case .Offer_Page, .Reply_Page:
	}
	page.entry_total = int(entry_total)
	page.conflict_total = int(conflict_total)
	page.first = {int(first_entry), int(first_conflict)}
	page.entry_count = int(entries)
	page.conflict_count = int(conflicts)
	page.items = body[STORE_PAGE_HEADER_SIZE:]
	return page, .Ok
}

// assembly_take_page appends one page to a version that arrives in pages. The
// first page of a version (cursor 0, 0) starts it again, and names its hash
// and its counts; each other page must start where the version ends now and
// name the same hash. Each entry must follow the entry before it, with no
// zero identifier and no zero hash; each conflict record proves its hash.
// When the version is whole, its hash and the reach of each record are
// checked. A refusal leaves the version unwhole: the next page must be its
// first page again.
@(private)
assembly_take_page :: proc "contextless" (assembly: ^Store_Assembly, version: ^Store_Version, page: ^Store_Page) -> (whole: bool, status: Store_Status) {
	if page.first == {} {
		version_clear(version)
		assembly^ = {active = true, version_hash = page.version_hash, common_hash = page.common_hash, entry_total = page.entry_total, conflict_total = page.conflict_total}
	} else if !assembly.active || assembly.version_hash != page.version_hash || assembly.common_hash != page.common_hash || assembly.entry_total != page.entry_total || assembly.conflict_total != page.conflict_total || page.first != {version.count, version.conflict_count} {
		return false, .Refused_Out_Of_Order
	}
	// The room of the records that this page carries, not of the totals
	// that the sender states: a total is a claim until its pages arrive, so
	// a peer that names a huge total gets no memory for it.
	if !version_room(version, version.count + page.entry_count, version.conflict_count + page.conflict_count) {
		assembly.active = false
		return false, .Refused_Full
	}
	place := 0
	for _ in 0 ..< page.entry_count {
		entry: Store_Entry
		copy(entry.identifier[:], page.items[place:][:32])
		copy(entry.hash[:], page.items[place + 32:][:32])
		place += STORE_ENTRY_WIRE_SIZE
		if hash_is_zero(entry.identifier) {
			assembly.active = false
			return false, .Refused_Zero_Identifier
		}
		if hash_is_zero(entry.hash) {
			assembly.active = false
			return false, .Refused_Zero_Hash
		}
		if version.count > 0 {
			order := identifier_compare(version.entries[version.count - 1].identifier, entry.identifier)
			if order >= 0 {
				assembly.active = false
				return false, order == 0 ? .Refused_Duplicate_Identifier : .Refused_Not_Sorted
			}
		}
		version.entries[version.count] = entry
		version.count += 1
	}
	for _ in 0 ..< page.conflict_count {
		conflict: Store_Conflict
		copy(conflict.identifier[:], page.items[place:][:32])
		copy(conflict.value.base_hash[:], page.items[place + 32:][:32])
		copy(conflict.value.local_hash[:], page.items[place + 64:][:32])
		copy(conflict.value.remote_hash[:], page.items[place + 96:][:32])
		place += STORE_CONFLICT_WIRE_SIZE
		// The record proves its hash: the merge of its base and its sides.
		decision, value_hash, _ := machine_mesh.reconcile_object(conflict.value.base_hash, conflict.value.local_hash, conflict.value.remote_hash)
		if decision != .Conflict_Keep_Both {
			assembly.active = false
			return false, .Refused_Bad_Conflict
		}
		conflict.value.conflict_value_hash = value_hash
		if version.conflict_count > 0 {
			order := conflict_compare(&version.conflicts[version.conflict_count - 1], &conflict)
			if order >= 0 {
				assembly.active = false
				return false, order == 0 ? .Refused_Duplicate_Identifier : .Refused_Not_Sorted
			}
		}
		version.conflicts[version.conflict_count] = conflict
		version.conflict_count += 1
	}
	if version.count < assembly.entry_total || version.conflict_count < assembly.conflict_total {
		return false, .Ok
	}
	assembly.active = false
	if store_version_hash(version) != assembly.version_hash {
		return false, .Refused_Version_Hash
	}
	// Each record is the conflict that its entry holds, or an older conflict
	// that another record of the same object names: no record stands alone.
	for index in 0 ..< version.conflict_count {
		record := &version.conflicts[index]
		reached := store_version_lookup(version, record.identifier) == record.value.conflict_value_hash
		for other in 0 ..< version.conflict_count {
			if other != index && version.conflicts[other].identifier == record.identifier && conflict_names(&version.conflicts[other], record.value.conflict_value_hash) {
				reached = true
			}
		}
		if !reached {
			return false, .Refused_Bad_Conflict
		}
	}
	return true, .Ok
}

// store_offer_begin starts an exchange and writes the first page of the
// offer of this machine. The first call takes the snapshot of the current
// version; each call until a reply sends that same snapshot again from its
// first page, so a repeat after a lost reply finds its answer.
store_offer_begin :: proc "contextless" (store: ^Exchanged_Store, output: []u8) -> []u8 {
	if store == nil || !store.in_use {
		return nil
	}
	if !store.has_offer {
		if version_copy(&store.offered, &store.current) != .Ok {
			return nil
		}
		store.has_offer = true
	}
	store.offer_cursor = {}
	store.reply_assembly = {}
	version_clear(&store.reply)
	return store_offer_next(store, output)
}

// store_offer_next writes the next request of the exchange in flight: the
// next page of the offer, or, once a page of the reply came, the request
// for the next page of the reply.
store_offer_next :: proc "contextless" (store: ^Exchanged_Store, output: []u8) -> []u8 {
	if store == nil || !store.in_use || !store.has_offer {
		return nil
	}
	common_hash := store_version_hash(&store.common)
	if store.reply_assembly.active {
		frame, _ := store_page_write(output, .Store_Offer, .Reply_Page_Request, store.store_identifier, common_hash, store_version_hash(&store.offered), &store.reply, {store.reply.count, store.reply.conflict_count})
		return frame
	}
	frame, _ := store_page_write(output, .Store_Offer, .Offer_Page, store.store_identifier, common_hash, store_version_hash(&store.offered), &store.offered, store.offer_cursor)
	return frame
}

// store_offer_answer is the receiver of a page of the partner. A page of
// the offer is appended; at its last page the merge is computed whole
// before any change, then applied, and the answer is the first page of the
// version of this machine before the merge. A request for a page of that
// reply is answered from the last exchange.
store_offer_answer :: proc "contextless" (store: ^Exchanged_Store, body: []u8, output: []u8) -> (frame: []u8, status: Store_Status) {
	page, read_status := store_page_read(body)
	if read_status != .Ok {
		return nil, read_status
	}
	if store == nil || !store.in_use || page.store_identifier != store.store_identifier {
		return nil, .Refused_Unknown_Store
	}
	common_hash := store_version_hash(&store.common)
	// The repeat of the last offer that this machine answered: its reply was
	// lost, so it gets the same reply, and nothing changes.
	repeat := store.has_last_exchange && page.common_hash == store_version_hash(&store.previous_common) && page.version_hash == store.last_offer_hash
	switch page.phase {
	case .None, .Page_Taken, .Reply_Page:
		return nil, .Refused_Bad_Phase
	case .Reply_Page_Request:
		if !repeat {
			return nil, .Refused_Base_Differs
		}
		if page.first.entry > store.last_reply.count || page.first.conflict > store.last_reply.conflict_count {
			return nil, .Refused_Bad_Count
		}
		frame, _ = store_page_write(output, .Store_Offer_Reply, .Reply_Page, store.store_identifier, page.common_hash, store_version_hash(&store.last_reply), &store.last_reply, page.first)
		return frame, frame == nil ? .Refused_Full : .Ok
	case .Offer_Page:
	}
	if page.common_hash != common_hash {
		if repeat && page.first == {} {
			frame, _ = store_page_write(output, .Store_Offer_Reply, .Reply_Page, store.store_identifier, page.common_hash, store_version_hash(&store.last_reply), &store.last_reply, {})
			return frame, frame == nil ? .Refused_Full : .Ok
		}
		return nil, .Refused_Base_Differs
	}
	whole, take_status := assembly_take_page(&store.incoming_assembly, &store.incoming, &page)
	if take_status != .Ok {
		// A refused version is no version: its pages go back.
		version_trim(&store.incoming)
		return nil, take_status
	}
	if !whole {
		frame, _ = store_page_write(output, .Store_Offer_Reply, .Page_Taken, store.store_identifier, page.common_hash, page.version_hash, &store.incoming, {store.incoming.count, store.incoming.conflict_count}, Store_Cursor{store.incoming_assembly.entry_total, store.incoming_assembly.conflict_total})
		return frame, frame == nil ? .Refused_Full : .Ok
	}
	// When this machine has its own offer in flight, merge and reply from its
	// snapshot so crossing offers compute the same common version on both
	// sides, then carry any local writes made since the snapshot onto current.
	reply_version := store.has_offer ? &store.offered : &store.current
	if merge_status := store_merge(&store.common, reply_version, &store.incoming, &store.merged); merge_status != .Ok {
		return nil, merge_status
	}
	next_current := &store.merged
	if store.has_offer {
		if later_status := store_merge(&store.offered, &store.current, &store.merged, &store.merged_later); later_status != .Ok {
			return nil, later_status
		}
		next_current = &store.merged_later
	}
	// Each version makes its room before any copy, so the store changes
	// whole or not at all.
	if !version_room(&store.last_reply, reply_version.count, reply_version.conflict_count) || !version_room(&store.previous_common, store.common.count, store.common.conflict_count) || !version_room(&store.current, next_current.count, next_current.conflict_count) || !version_room(&store.common, store.merged.count, store.merged.conflict_count) {
		return nil, .Refused_Full
	}
	version_copy(&store.last_reply, reply_version)
	version_copy(&store.previous_common, &store.common)
	store.last_offer_hash = page.version_hash
	store.has_last_exchange = true
	version_copy(&store.current, next_current)
	version_copy(&store.common, &store.merged)
	store.has_offer = false
	version_clear(&store.offered)
	frame, _ = store_page_write(output, .Store_Offer_Reply, .Reply_Page, store.store_identifier, page.common_hash, store_version_hash(&store.last_reply), &store.last_reply, {})
	return frame, frame == nil ? .Refused_Full : .Ok
}

// store_offer_reply_accept takes the answer of the partner to a page of the
// exchange in flight. Page_Taken moves the cursor of the offer. A page of
// the reply is appended; at its last page this machine merges as the
// partner merged, from the snapshot of the offer, then merges the writes
// made since the snapshot over that result. Both merges are computed before
// any change. more is true while the exchange needs another request
// (store_offer_next).
store_offer_reply_accept :: proc "contextless" (store: ^Exchanged_Store, answer: []u8) -> (status: Store_Status, reason: Refusal_Reason, detail: u32, more: bool) {
	if store == nil || !store.in_use {
		return .Refused_Nil_Input, .None, 0, false
	}
	if !store.has_offer {
		return .Refused_No_Offer, .None, 0, false
	}
	body, refusal, refusal_detail, ok := answer_expect(answer, .Store_Offer_Reply)
	if !ok {
		return .Refused_Nil_Input, refusal, refusal_detail, false
	}
	page, read_status := store_page_read(body)
	if read_status != .Ok {
		return read_status, .Malformed, 0, false
	}
	if page.store_identifier != store.store_identifier {
		return .Refused_Other_Store, .Malformed, 0, false
	}
	if page.common_hash != store_version_hash(&store.common) {
		return .Refused_Base_Differs, .None, 0, false
	}
	switch page.phase {
	case .None, .Offer_Page, .Reply_Page_Request:
		return .Refused_Bad_Phase, .Malformed, 0, false
	case .Page_Taken:
		// The receiver took the pages up to its cursor: the cursor must move
		// forward, inside the offer.
		if page.version_hash != store_version_hash(&store.offered) || page.entry_total != store.offered.count || page.conflict_total != store.offered.conflict_count {
			return .Refused_Out_Of_Order, .Malformed, 0, false
		}
		if page.first.entry < store.offer_cursor.entry || page.first.conflict < store.offer_cursor.conflict || page.first == store.offer_cursor || (page.first.entry == store.offered.count && page.first.conflict == store.offered.conflict_count) {
			return .Refused_Out_Of_Order, .Malformed, 0, false
		}
		store.offer_cursor = page.first
		return .Ok, .None, 0, true
	case .Reply_Page:
	}
	whole, take_status := assembly_take_page(&store.reply_assembly, &store.reply, &page)
	if take_status != .Ok {
		version_trim(&store.reply)
		return take_status, .None, 0, false
	}
	if !whole {
		// The next request asks for the next page of the reply.
		store.reply_assembly.active = true
		return .Ok, .None, 0, true
	}
	if merge_status := store_merge(&store.common, &store.offered, &store.reply, &store.merged); merge_status != .Ok {
		return merge_status, .None, 0, false
	}
	if later_status := store_merge(&store.offered, &store.current, &store.merged, &store.merged_later); later_status != .Ok {
		return later_status, .None, 0, false
	}
	if !version_room(&store.common, store.merged.count, store.merged.conflict_count) || !version_room(&store.current, store.merged_later.count, store.merged_later.conflict_count) {
		return .Refused_Full, .None, 0, false
	}
	version_copy(&store.common, &store.merged)
	version_copy(&store.current, &store.merged_later)
	store.has_offer = false
	version_clear(&store.offered)
	version_clear(&store.reply)
	return .Ok, .None, 0, false
}
