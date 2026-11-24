// Swiss tables: hash tables of fixed capacity whose slots are in groups of
// 16, with one control byte for each slot, so a search compares 16 tags at
// once. The design, its sources and its refused forms are in
// src/md/data/swiss_table.md.
//
// Two forms share one probe:
//
// - Hash_Table holds its keys and its values.
// - Hash_Index holds the number of a record of its caller in each slot: the
//   caller keeps its records (and their keys) in its own array, and
//   compares a key through the record that a search gives.
//
// A table is one value of a fixed size: the caller puts it where its
// memory is (a global, a part of a record, pages of an arena). It calls no
// allocator and no operation of the kernel. A table of all zero is empty
// and valid, as the pages of a new memory object are.
package hash_table

import "base:intrinsics"
import "modus:fast_hash"

// The slots of one group: the control bytes that one compare of 16 lanes
// reads.
GROUP_WIDTH :: 16

// The two control bytes of a slot that holds no key. A full slot has bit 7
// set and the tag of its key in bits 0 to 6. Empty is 0, so a table of all
// zero is empty.
Control_Mark :: enum u8 {
	Empty   = 0x00, // No key took the slot since the last rebuild: a search stops at its group.
	Deleted = 0x01, // A tombstone: a key left a group that was full, so a search goes on past it.
}

FULL_BIT :: 0x80 // The bit of a control byte that marks a full slot.
TAG_MASK :: 0x7F // The bits of the hash that make the tag of a key: bits 0 to 6.

// The load bound, in eighths of the slots: keys and tombstones together
// take at most 7 of each 8 slots, so a search always meets an empty slot.
LOAD_BOUND_EIGHTHS :: 7

// ---- The probe, shared by the two forms.

// keys_bound gives the most keys of a count of slots.
@(private)
keys_bound :: #force_inline proc "contextless" (slot_count: int) -> int {
	return slot_count / 8 * LOAD_BOUND_EIGHTHS
}

@(private)
tag_of_hash :: #force_inline proc "contextless" (hash: u64) -> u8 {
	return FULL_BIT | u8(hash & TAG_MASK)
}

// first_group gives the first group of a hash: the high 32 bits, times the
// count of the groups, over 2^32. A product and a shift, no division, and
// any count of groups: the size of a table is not a power of two.
@(private)
first_group :: #force_inline proc "contextless" (hash: u64, group_count: int) -> int {
	return int(((hash >> 32) * u64(group_count)) >> 32)
}

@(private)
next_group :: #force_inline proc "contextless" (group, group_count: int) -> int {
	following := group + 1
	return following == group_count ? 0 : following
}

// Probe: a search in progress. It visits the groups from the first group
// of the hash, one after the other, each at most once, and gives the slots
// whose tag is the tag of the hash. It ends after the first group that has
// an empty slot: no key went past that group.
Probe :: struct {
	tag:         u8,
	group:       int,
	groups_left: int, // The groups that the search can still read.
	matches:     u16, // The slots of the group read last whose tag matches, not given yet.
}

@(private)
probe_begin :: #force_inline proc "contextless" (hash: u64, group_count: int) -> Probe {
	return {tag = tag_of_hash(hash), group = first_group(hash, group_count), groups_left = group_count}
}

// probe_next gives the next slot whose tag matches; ok is false at the end
// of the search.
@(private)
probe_next :: #force_inline proc "contextless" (probe: ^Probe, controls: [^]u8, group_count: int) -> (slot: int, ok: bool) {
	for {
		if probe.matches != 0 {
			lane := int(intrinsics.count_trailing_zeros(probe.matches))
			probe.matches &= probe.matches - 1
			return probe.group * GROUP_WIDTH + lane, true
		}
		if probe.groups_left == group_count {
			// The first group: read below.
		} else {
			if probe.groups_left == 0 {
				return -1, false
			}
			if group_match_empty((^[GROUP_WIDTH]u8)(&controls[probe.group * GROUP_WIDTH])) != 0 {
				probe.groups_left = 0
				return -1, false
			}
			probe.group = next_group(probe.group, group_count)
		}
		group_controls := (^[GROUP_WIDTH]u8)(&controls[probe.group * GROUP_WIDTH])
		probe.matches = group_match_tag(group_controls, probe.tag)
		probe.groups_left -= 1
	}
}

// free_slot gives the first slot that is empty or deleted along the probe
// sequence of a hash, or -1 when no group has one.
@(private)
free_slot :: proc "contextless" (controls: [^]u8, group_count: int, hash: u64) -> int {
	group := first_group(hash, group_count)
	for _ in 0 ..< group_count {
		if free := group_match_free((^[GROUP_WIDTH]u8)(&controls[group * GROUP_WIDTH])); free != 0 {
			return group * GROUP_WIDTH + int(intrinsics.count_trailing_zeros(free))
		}
		group = next_group(group, group_count)
	}
	return -1
}

// mark_removed marks a full slot as no longer full: empty when its group
// still has an empty slot, as a group with an empty slot was never full
// since the last rebuild and no search went past it; else a tombstone.
// It gives true for a tombstone.
@(private)
mark_removed :: proc "contextless" (controls: [^]u8, slot: int) -> (tombstone: bool) {
	if group_match_empty((^[GROUP_WIDTH]u8)(&controls[slot - slot % GROUP_WIDTH])) != 0 {
		controls[slot] = u8(Control_Mark.Empty)
		return false
	}
	controls[slot] = u8(Control_Mark.Deleted)
	return true
}

// The work of a rebuild on the slots of one form.
@(private)
Rebuild_Slots :: struct {
	data:         rawptr,
	hash_of_slot: proc "contextless" (data: rawptr, slot: int) -> u64,
	move:         proc "contextless" (data: rawptr, from, to: int), // The slot `from` becomes empty.
	swap:         proc "contextless" (data: rawptr, first, second: int),
}

// rebuild_in_place drops the tombstones with no other memory, as the
// rehash in place of Abseil does: each key becomes a key to place, each
// tombstone an empty slot; then each key to place goes to the first free
// slot of its probe sequence. A key whose first free group is its own
// group stays; a key that goes to an empty slot moves; a key that goes to
// the slot of another key to place swaps with it, and the slot is visited
// again. Each swap places one key, so the work is bounded by the slots and
// the keys.
@(private)
rebuild_in_place :: proc "contextless" (controls: [^]u8, group_count: int, slots: Rebuild_Slots) {
	slot_count := group_count * GROUP_WIDTH
	for slot in 0 ..< slot_count {
		controls[slot] = controls[slot] & FULL_BIT != 0 ? u8(Control_Mark.Deleted) : u8(Control_Mark.Empty)
	}
	slot := 0
	for slot < slot_count {
		if controls[slot] != u8(Control_Mark.Deleted) {
			slot += 1
			continue
		}
		hash := slots.hash_of_slot(slots.data, slot)
		// The slot itself is free, so the search finds a slot.
		target := free_slot(controls, group_count, hash)
		switch {
		case target < 0 || target / GROUP_WIDTH == slot / GROUP_WIDTH:
			controls[slot] = tag_of_hash(hash)
			slot += 1
		case controls[target] == u8(Control_Mark.Empty):
			controls[target] = tag_of_hash(hash)
			slots.move(slots.data, slot, target)
			controls[slot] = u8(Control_Mark.Empty)
			slot += 1
		case:
			controls[target] = tag_of_hash(hash)
			slots.swap(slots.data, slot, target)
		}
	}
}

// slot_take gives the slot where a new key of a hash goes, after a
// rebuild when keys and tombstones are at the load bound and the slot is
// empty; -1 when the keys are at their bound. The caller writes the slot.
@(private)
slot_take :: proc "contextless" (controls: [^]u8, group_count: int, count, deleted_count: ^int, hash: u64, slots: Rebuild_Slots) -> int {
	bound := keys_bound(group_count * GROUP_WIDTH)
	if count^ >= bound {
		return -1
	}
	slot := free_slot(controls, group_count, hash)
	// An empty slot adds one to the keys and tombstones together: at the
	// load bound, the tombstones go first, and the free slot is found again.
	if slot >= 0 && controls[slot] == u8(Control_Mark.Empty) && count^ + deleted_count^ >= bound {
		rebuild_in_place(controls, group_count, slots)
		deleted_count^ = 0
		slot = free_slot(controls, group_count, hash)
	}
	// The load bound leaves a free slot: this is a table that another
	// party changed in memory.
	if slot < 0 {
		return -1
	}
	if controls[slot] == u8(Control_Mark.Deleted) {
		deleted_count^ -= 1
	}
	controls[slot] = tag_of_hash(hash)
	count^ += 1
	return slot
}

// ---- Hash_Table: the keys and the values in the table.

// Hash_Table: GROUP_COUNT groups of 16 slots. The key is compared and
// hashed as its bytes: a type with padding, a float, a pointer to its
// content or a string is refused.
Hash_Table :: struct($Key: typeid, $Value: typeid, $GROUP_COUNT: int) where GROUP_COUNT > 0,
	intrinsics.type_is_simple_compare(Key) {
	controls:      [GROUP_COUNT * GROUP_WIDTH]u8,
	keys:          [GROUP_COUNT * GROUP_WIDTH]Key,
	values:        [GROUP_COUNT * GROUP_WIDTH]Value,
	count:         int, // The keys in the table.
	deleted_count: int, // The tombstones.
	prepared_seed: u64, // fast_hash.seed_prepare of the seed of the table; 0 is valid.
}

// The outcome of an insert.
Insert_Outcome :: enum u8 {
	Added, // The key was not in the table: it is now, with its value.
	Replaced, // The key was in the table: its value is the new one.
	Full, // The key was not in the table, and the table holds entry_capacity keys: nothing changed.
}

// hash_of_key gives the hash of the bytes of a key with a prepared seed: a
// key of one word takes one folded multiply, any other key rapidhash.
hash_of_key :: #force_inline proc "contextless" (key: ^$Key, prepared_seed: u64) -> u64 {
	when intrinsics.type_is_struct(Key) {
		#assert(!intrinsics.type_struct_has_implicit_padding(Key), "a key with padding has bytes that its value does not fix")
	}
	when size_of(Key) == 8 {
		return fast_hash.mix_word_with_prepared_seed(u64(intrinsics.unaligned_load((^u64le)(key))), prepared_seed)
	} else {
		return fast_hash.hash_bytes_with_prepared_seed(([^]u8)(key)[:size_of(Key)], prepared_seed)
	}
}

// table_entry_capacity gives the most keys that a table holds: 7 of each
// 8 slots.
table_entry_capacity :: #force_inline proc "contextless" (table: ^$T/Hash_Table($Key, $Value, $GROUP_COUNT)) -> int {
	return keys_bound(GROUP_COUNT * GROUP_WIDTH)
}

// seed_prepare_for_table computes the prepared seed of a table or an index
// once. Keeping it non-polymorphic also checks the fast_hash import when
// the package is checked without a caller.
@(private)
seed_prepare_for_table :: #force_inline proc "contextless" (seed: u64) -> u64 {
	return fast_hash.seed_prepare(seed)
}

// table_seed_set gives an empty table its seed, from bytes that no other
// party knows (the fresh bytes of the process) when another party chooses
// its keys. false: the table holds a key or a tombstone, whose slot
// depends on the seed before, and nothing changed.
table_seed_set :: proc "contextless" (table: ^$T/Hash_Table($Key, $Value, $GROUP_COUNT), seed: u64) -> bool {
	if table.count != 0 || table.deleted_count != 0 {
		return false
	}
	table.prepared_seed = seed_prepare_for_table(seed)
	return true
}

@(private)
table_slot_of_key :: #force_inline proc "contextless" (table: ^$T/Hash_Table($Key, $Value, $GROUP_COUNT), key: ^Key, hash: u64) -> int #no_bounds_check {
	tag := tag_of_hash(hash)
	group := first_group(hash, GROUP_COUNT)
	for _ in 0 ..< GROUP_COUNT {
		base := group * GROUP_WIDTH
		group_controls := (^[GROUP_WIDTH]u8)(&table.controls[base])
		matches := group_match_tag(group_controls, tag)
		for matches != 0 {
			lane := int(intrinsics.count_trailing_zeros(matches))
			if table.keys[base + lane] == key^ {
				return base + lane
			}
			matches &= matches - 1
		}
		if group_match_empty(group_controls) != 0 {
			return -1
		}
		group = next_group(group, GROUP_COUNT)
	}
	return -1
}

// find gives the place of the value of a key. The place holds until the
// next insert or remove, which can move the values.
find :: #force_inline proc "contextless" (table: ^$T/Hash_Table($Key, $Value, $GROUP_COUNT), key: Key) -> (value: ^Value, found: bool) #no_bounds_check {
	key := key
	slot := table_slot_of_key(table, &key, hash_of_key(&key, table.prepared_seed))
	if slot < 0 {
		return nil, false
	}
	return &table.values[slot], true
}

@(private)
table_rebuild_slots :: proc "contextless" (table: ^$T/Hash_Table($Key, $Value, $GROUP_COUNT)) -> Rebuild_Slots {
	return {
		data = table,
		hash_of_slot = proc "contextless" (data: rawptr, slot: int) -> u64 {
			table := (^T)(data)
			return hash_of_key(&table.keys[slot], table.prepared_seed)
		},
		move = proc "contextless" (data: rawptr, from, to: int) {
			table := (^T)(data)
			table.keys[to], table.values[to] = table.keys[from], table.values[from]
			table.keys[from], table.values[from] = {}, {}
		},
		swap = proc "contextless" (data: rawptr, first, second: int) {
			table := (^T)(data)
			table.keys[first], table.keys[second] = table.keys[second], table.keys[first]
			table.values[first], table.values[second] = table.values[second], table.values[first]
		},
	}
}

// insert puts a key with its value in the table, or gives a key that is in
// it the new value.
insert :: proc "contextless" (table: ^$T/Hash_Table($Key, $Value, $GROUP_COUNT), key: Key, value: Value) -> Insert_Outcome #no_bounds_check {
	key := key
	hash := hash_of_key(&key, table.prepared_seed)
	if slot := table_slot_of_key(table, &key, hash); slot >= 0 {
		table.values[slot] = value
		return .Replaced
	}
	slot := slot_take(&table.controls[0], GROUP_COUNT, &table.count, &table.deleted_count, hash, table_rebuild_slots(table))
	if slot < 0 {
		return .Full
	}
	table.keys[slot] = key
	table.values[slot] = value
	return .Added
}

// remove takes a key and its value out of the table. false: the key was
// not in it, and nothing changed.
remove :: proc "contextless" (table: ^$T/Hash_Table($Key, $Value, $GROUP_COUNT), key: Key) -> bool #no_bounds_check {
	key := key
	slot := table_slot_of_key(table, &key, hash_of_key(&key, table.prepared_seed))
	if slot < 0 {
		return false
	}
	if mark_removed(&table.controls[0], slot) {
		table.deleted_count += 1
	}
	table.keys[slot] = {}
	table.values[slot] = {}
	table.count -= 1
	return true
}

// table_clear empties the table and keeps its seed.
table_clear :: proc "contextless" (table: ^$T/Hash_Table($Key, $Value, $GROUP_COUNT)) {
	prepared_seed := table.prepared_seed
	table^ = {}
	table.prepared_seed = prepared_seed
}

// iterate gives the next key of the table after a place, and moves the
// place past it; ok is false after the last key. The order is the order of
// the slots: it depends on the seed and on the history of the table.
//
//	place := 0
//	for key, value in hash_table.iterate(&table, &place) { ... }
iterate :: proc "contextless" (table: ^$T/Hash_Table($Key, $Value, $GROUP_COUNT), place: ^int) -> (key: Key, value: ^Value, ok: bool) #no_bounds_check {
	for place^ >= 0 && place^ < GROUP_COUNT * GROUP_WIDTH {
		slot := place^
		place^ += 1
		if table.controls[slot] & FULL_BIT != 0 {
			return table.keys[slot], &table.values[slot], true
		}
	}
	return {}, nil, false
}

// ---- Hash_Index: the numbers of the records of the caller.

// Hash_Index: GROUP_COUNT groups of 16 slots, each with the number of a
// record of the caller (Reference, an integer). The caller hashes the key
// of a record with index_hash_word or index_hash_bytes, and compares the
// key of each record that a search gives: the index holds no key, so it
// costs a control byte and a number for each slot.
Hash_Index :: struct($Reference: typeid, $GROUP_COUNT: int) where GROUP_COUNT > 0,
	intrinsics.type_is_integer(Reference) {
	controls:      [GROUP_COUNT * GROUP_WIDTH]u8,
	references:    [GROUP_COUNT * GROUP_WIDTH]Reference,
	count:         int, // The references in the index.
	deleted_count: int, // The tombstones.
	prepared_seed: u64, // fast_hash.seed_prepare of the seed of the index; 0 is valid.
}

// The hash of a record that a rebuild of an index asks its caller for.
Hash_Of_Reference :: proc "contextless" (owner: rawptr, reference: u64) -> u64

index_entry_capacity :: #force_inline proc "contextless" (index: ^$I/Hash_Index($Reference, $GROUP_COUNT)) -> int {
	return keys_bound(GROUP_COUNT * GROUP_WIDTH)
}

// index_seed_set gives an empty index its seed: as table_seed_set.
index_seed_set :: proc "contextless" (index: ^$I/Hash_Index($Reference, $GROUP_COUNT), seed: u64) -> bool {
	if index.count != 0 || index.deleted_count != 0 {
		return false
	}
	index.prepared_seed = seed_prepare_for_table(seed)
	return true
}

// index_hash_word gives the hash of a key of one word in an index.
index_hash_word :: #force_inline proc "contextless" (index: ^$I/Hash_Index($Reference, $GROUP_COUNT), word: u64) -> u64 {
	return fast_hash.mix_word_with_prepared_seed(word, index.prepared_seed)
}

// index_hash_bytes gives the hash of a key of bytes in an index.
index_hash_bytes :: #force_inline proc "contextless" (index: ^$I/Hash_Index($Reference, $GROUP_COUNT), bytes: []u8) -> u64 {
	return fast_hash.hash_bytes_with_prepared_seed(bytes, index.prepared_seed)
}

// index_search_begin starts the search of a hash. Each call of
// index_search_next then gives a candidate: a record whose key can be the
// key searched. The caller compares the key of the record.
index_search_begin :: #force_inline proc "contextless" (index: ^$I/Hash_Index($Reference, $GROUP_COUNT), hash: u64) -> Probe {
	return probe_begin(hash, GROUP_COUNT)
}

// index_search_next gives the next candidate of a search and its slot; ok
// is false at the end of the search.
//
//	search := hash_table.index_search_begin(&index, hash)
//	for reference, slot in hash_table.index_search_next(&index, &search) {
//		if records[reference].key == key { ... }
//	}
index_search_next :: #force_inline proc "contextless" (index: ^$I/Hash_Index($Reference, $GROUP_COUNT), search: ^Probe) -> (reference: Reference, slot: int, ok: bool) #no_bounds_check {
	slot = probe_next(search, &index.controls[0], GROUP_COUNT) or_return
	return index.references[slot], slot, true
}

// index_insert puts the number of a record whose key has a hash in the
// index. The caller searched the key first and found no record: the index
// does not compare keys. hash_of_reference gives the hash of the key of a
// record for a rebuild and must not be nil. false: hash_of_reference is
// nil, or the index holds index_entry_capacity references, and nothing
// changed.
index_insert :: proc "contextless" (index: ^$I/Hash_Index($Reference, $GROUP_COUNT), hash: u64, reference: Reference, owner: rawptr, hash_of_reference: Hash_Of_Reference) -> bool #no_bounds_check {
	if hash_of_reference == nil {
		return false
	}
	Rebuild_Data :: struct {
		index:             ^I,
		owner:             rawptr,
		hash_of_reference: Hash_Of_Reference,
	}
	data := Rebuild_Data{index, owner, hash_of_reference}
	slots := Rebuild_Slots {
		data = &data,
		hash_of_slot = proc "contextless" (data: rawptr, slot: int) -> u64 {
			data := (^Rebuild_Data)(data)
			return data.hash_of_reference(data.owner, u64(data.index.references[slot]))
		},
		move = proc "contextless" (data: rawptr, from, to: int) {
			index := (^Rebuild_Data)(data).index
			index.references[to] = index.references[from]
			index.references[from] = 0
		},
		swap = proc "contextless" (data: rawptr, first, second: int) {
			index := (^Rebuild_Data)(data).index
			index.references[first], index.references[second] = index.references[second], index.references[first]
		},
	}
	slot := slot_take(&index.controls[0], GROUP_COUNT, &index.count, &index.deleted_count, hash, slots)
	if slot < 0 {
		return false
	}
	index.references[slot] = reference
	return true
}

// index_remove_slot takes the reference of a slot that index_search_next
// gave out of the index. false: the slot holds no reference (a slot out of
// the index, or a slot already removed), and nothing changed.
index_remove_slot :: proc "contextless" (index: ^$I/Hash_Index($Reference, $GROUP_COUNT), slot: int) -> bool #no_bounds_check {
	if slot < 0 || slot >= GROUP_COUNT * GROUP_WIDTH || index.controls[slot] & FULL_BIT == 0 {
		return false
	}
	if mark_removed(&index.controls[0], slot) {
		index.deleted_count += 1
	}
	index.references[slot] = 0
	index.count -= 1
	return true
}

// index_clear empties the index and keeps its seed.
index_clear :: proc "contextless" (index: ^$I/Hash_Index($Reference, $GROUP_COUNT)) {
	prepared_seed := index.prepared_seed
	index^ = {}
	index.prepared_seed = prepared_seed
}

// ---- Slice_Hash_Index: slice-backed Swiss index for caller-supplied arenas.

// Slice_Hash_Index: runtime-sized Swiss index backed by caller-supplied
// controls and references slices (16-slot groups, 7/8 load bound, ZII empty
// controls). A zero-initialised Slice_Hash_Index has group_count == 0 and
// safely returns no match and refuses inserts.
Slice_Hash_Index :: struct($Reference: typeid) where intrinsics.type_is_integer(Reference) {
	controls:      []u8,
	references:    []Reference,
	group_count:   int,
	count:         int,
	deleted_count: int,
	prepared_seed: u64,
}

// slice_index_groups_for_entries computes the minimum number of 16-slot
// groups needed to hold `entries` references within the 7/8 load bound
// (14 entries per group). Returns 0 for negative counts or overflow.
slice_index_groups_for_entries :: proc "contextless" (entries: int) -> int {
	if entries < 0 {
		return 0
	}
	if entries == 0 {
		return 1
	}
	per_group := GROUP_WIDTH / 8 * LOAD_BOUND_EIGHTHS // 14
	if entries > max(int) - (per_group - 1) {
		return 0
	}
	groups := (entries + per_group - 1) / per_group
	if groups > max(int) / GROUP_WIDTH {
		return 0
	}
	return groups
}

// slice_index_init binds caller-owned controls and references slices into an
// empty Slice_Hash_Index and prepares its seed. Refuses buffers smaller than
// one group, controls whose length is not a multiple of GROUP_WIDTH, or a
// references slice shorter than controls, leaving caller memory untouched.
slice_index_init :: proc "contextless" ($Reference: typeid, controls: []u8, references: []Reference, seed: u64 = 0) -> (index: Slice_Hash_Index(Reference), ok: bool) {
	if len(controls) < GROUP_WIDTH || len(controls) % GROUP_WIDTH != 0 || len(references) < len(controls) {
		return {}, false
	}
	slot_count := len(controls)
	for &c in controls[:slot_count] {
		c = u8(Control_Mark.Empty)
	}
	return {
		controls      = controls[:slot_count],
		references    = references[:slot_count],
		group_count   = slot_count / GROUP_WIDTH,
		count         = 0,
		deleted_count = 0,
		prepared_seed = seed_prepare_for_table(seed),
	}, true
}

slice_index_entry_capacity :: #force_inline proc "contextless" (index: ^Slice_Hash_Index($Reference)) -> int {
	if index.group_count <= 0 {
		return 0
	}
	return keys_bound(index.group_count * GROUP_WIDTH)
}

slice_index_seed_set :: proc "contextless" (index: ^Slice_Hash_Index($Reference), seed: u64) -> bool {
	if index.group_count <= 0 || index.count != 0 || index.deleted_count != 0 {
		return false
	}
	index.prepared_seed = seed_prepare_for_table(seed)
	return true
}

slice_index_hash_word :: #force_inline proc "contextless" (index: ^Slice_Hash_Index($Reference), word: u64) -> u64 {
	return fast_hash.mix_word_with_prepared_seed(word, index.prepared_seed)
}

slice_index_hash_bytes :: #force_inline proc "contextless" (index: ^Slice_Hash_Index($Reference), bytes: []u8) -> u64 {
	return fast_hash.hash_bytes_with_prepared_seed(bytes, index.prepared_seed)
}

slice_index_search_begin :: #force_inline proc "contextless" (index: ^Slice_Hash_Index($Reference), hash: u64) -> Probe {
	if index.group_count <= 0 || len(index.controls) < index.group_count * GROUP_WIDTH {
		return {}
	}
	return probe_begin(hash, index.group_count)
}

slice_index_search_next :: #force_inline proc "contextless" (index: ^Slice_Hash_Index($Reference), search: ^Probe) -> (reference: Reference, slot: int, ok: bool) #no_bounds_check {
	if index.group_count <= 0 || len(index.controls) < index.group_count * GROUP_WIDTH || len(index.references) < index.group_count * GROUP_WIDTH {
		return 0, -1, false
	}
	if search.groups_left == 0 && search.matches == 0 {
		return 0, -1, false
	}
	slot = probe_next(search, raw_data(index.controls), index.group_count) or_return
	return index.references[slot], slot, true
}

slice_index_insert :: proc "contextless" (index: ^Slice_Hash_Index($Reference), hash: u64, reference: Reference, owner: rawptr, hash_of_reference: Hash_Of_Reference) -> bool #no_bounds_check {
	if hash_of_reference == nil || index.group_count <= 0 || len(index.controls) < index.group_count * GROUP_WIDTH || len(index.references) < index.group_count * GROUP_WIDTH {
		return false
	}
	Rebuild_Data :: struct {
		index:             ^Slice_Hash_Index(Reference),
		owner:             rawptr,
		hash_of_reference: Hash_Of_Reference,
	}
	data := Rebuild_Data{index, owner, hash_of_reference}
	slots := Rebuild_Slots {
		data = &data,
		hash_of_slot = proc "contextless" (data: rawptr, slot: int) -> u64 {
			data := (^Rebuild_Data)(data)
			return data.hash_of_reference(data.owner, u64(data.index.references[slot]))
		},
		move = proc "contextless" (data: rawptr, from, to: int) {
			index := (^Rebuild_Data)(data).index
			index.references[to] = index.references[from]
			index.references[from] = 0
		},
		swap = proc "contextless" (data: rawptr, first, second: int) {
			index := (^Rebuild_Data)(data).index
			index.references[first], index.references[second] = index.references[second], index.references[first]
		},
	}
	slot := slot_take(raw_data(index.controls), index.group_count, &index.count, &index.deleted_count, hash, slots)
	if slot < 0 {
		return false
	}
	index.references[slot] = reference
	return true
}

slice_index_remove_slot :: proc "contextless" (index: ^Slice_Hash_Index($Reference), slot: int) -> bool #no_bounds_check {
	slot_count := index.group_count * GROUP_WIDTH
	if index.group_count <= 0 || slot < 0 || slot >= slot_count || len(index.controls) < slot_count || len(index.references) < slot_count {
		return false
	}
	if index.controls[slot] & FULL_BIT == 0 {
		return false
	}
	if mark_removed(raw_data(index.controls), slot) {
		index.deleted_count += 1
	}
	index.references[slot] = 0
	index.count -= 1
	return true
}

slice_index_clear :: proc "contextless" (index: ^Slice_Hash_Index($Reference)) {
	slot_count := index.group_count * GROUP_WIDTH
	if index.group_count > 0 && len(index.controls) >= slot_count {
		for &c in index.controls[:slot_count] {
			c = u8(Control_Mark.Empty)
		}
	}
	if index.group_count > 0 && len(index.references) >= slot_count {
		for &r in index.references[:slot_count] {
			r = 0
		}
	}
	index.count = 0
	index.deleted_count = 0
}

// The procedures of all forms under one name.
entry_capacity :: proc {
	table_entry_capacity,
	index_entry_capacity,
	slice_index_entry_capacity,
}
seed_set :: proc {
	table_seed_set,
	index_seed_set,
	slice_index_seed_set,
}
clear :: proc {
	table_clear,
	index_clear,
	slice_index_clear,
}
