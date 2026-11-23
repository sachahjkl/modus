package storage_mount

import "base:intrinsics"
import format "modus:contract/store"

// The hash index (docs/STORAGE.md, "4.7 The same object one time"): for each
// block that is the root of the current state of an object, the first 8
// bytes of the hash of that state, its size and its check, and the count of
// the entries that name it. The open makes it from the entries; the storage
// service changes it after each commit, from the entries that the commit
// changed (hash_index_entry_change). It is never written: a loss of power
// leaves nothing of it to repair. A lookup gives candidates only: the
// service confirms each one by the hash that its block tree gives.
//
// Its size follows the roots that it can hold, not the blocks of the disk:
// the caller chooses it (state_bind), and the storage service takes it from
// its budget. The records are a table of their own, found by the number of
// the root block. When the records are half full, a new root gets no
// record: the only loss is that a later commit does not find its bytes, as
// for a root past HASH_PROBE_LIMIT.
//
// The slots find a root by its key: the 8 bytes of the hash, the size and
// the store. One key has at most one slot: a second root with the same key
// keeps a record and no slot, so equal keys never make a run of slots. The
// first slot of a key comes from the 8 bytes mixed with a key of the slots
// that the service draws at each start: no party can choose hashes that
// fall in one run. A search and an insert read at most HASH_PROBE_LIMIT
// slots. A removal reads at most HASH_PROBE_LIMIT slots past each slot that
// it moves back: its cost follows the length of the run, which stays short
// when no party chooses the first slots.

// HASH_PROBE_LIMIT is the most slots that a search or an insert reads from
// the first slot of a key. At a load of one half, with first slots that no
// party chooses, a run of this length is far rarer than one in a million
// inserts; a root that finds no slot inside the bound keeps a record with
// no slot, and the only loss is that a later commit does not find it.
HASH_PROBE_LIMIT :: 32

// The odd constant of the mix of the first slot (the golden ratio of 64
// bits): a product by it spreads the bits of the key into the high bits.
HASH_SLOT_MIX :: u64(0x9E37_79B9_7F4A_7C15)

// What the index knows of one root. 40 bytes.
Root_Record :: struct {
	block:       u64, // The root block. 0: the record is free.
	hash_prefix: u64, // The first 8 bytes of the hash of the state, as the entry that named it first gave it, or as a confirmation found it.
	size:        u64, // The size of the state.
	check:       u64, // The check of the root: its Pointer is the block and this check.
	entries:     u32, // The current entries that name the block as their root.
	hidden:      bool, // Never a candidate, and no slot: the root was named first while its store had a writable share of a tree open, or the service found it damaged.
	reserved:    [3]u8, // 0.
}
#assert(size_of(Root_Record) == 40)

// The index of one disk.
Hash_Index :: struct {
	records:   []Root_Record, // Found by the number of their block, with linear probing; a power of two.
	slots:     []u64, // The number of a root block; 0: empty. Linear probing from the first slot of the key. As many as the records.
	slot_bits: uint, // The bits of a number of a slot.
	record_count: u64, // The records in use.
	roots:     u64, // The roots that have a slot.
	slot_key:  u64, // Mixed into the first slot of each key. The service draws it at its start; the reset keeps it.
}

// hash_prefix gives the first 8 bytes of a hash.
hash_prefix :: proc "contextless" (hash: [32]u8) -> u64 {
	copy_of := hash
	return intrinsics.unaligned_load((^u64)(&copy_of[0]))
}

// hash_slot_capacity gives the slots of the index.
hash_slot_capacity :: #force_inline proc "contextless" (index: ^Hash_Index) -> u64 {
	return u64(len(index.slots))
}

// hash_home gives the first slot of a key.
hash_home :: #force_inline proc "contextless" (index: ^Hash_Index, prefix: u64) -> u64 {
	if index.slot_bits == 0 {
		return 0
	}
	return ((prefix ~ index.slot_key) * HASH_SLOT_MIX) >> (64 - index.slot_bits)
}

@(private = "file")
slot_next :: #force_inline proc "contextless" (index: ^Hash_Index, at: u64) -> u64 {
	return (at + 1) & (hash_slot_capacity(index) - 1)
}

// The first place of the record of a block.
@(private = "file")
record_home :: #force_inline proc "contextless" (index: ^Hash_Index, block: u64) -> u64 {
	if index.slot_bits == 0 {
		return 0
	}
	return (block * HASH_SLOT_MIX) >> (64 - index.slot_bits)
}

// record_place gives the place of the record of a block, or of the empty
// record where it would go.
@(private = "file")
record_place :: proc "contextless" (index: ^Hash_Index, block: u64) -> (place: u64, found: bool) {
	capacity := u64(len(index.records))
	if capacity == 0 {
		return 0, false
	}
	at := record_home(index, block)
	for _ in 0 ..< capacity {
		item := index.records[at].block
		if item == block {
			return at, true
		}
		if item == 0 {
			return at, false
		}
		at = (at + 1) & (capacity - 1)
	}
	return 0, false
}

// hash_index_record gives the record of a root block, or nil.
hash_index_record :: proc "contextless" (state: ^State, block: u64) -> ^Root_Record {
	if block < 2 {
		return nil
	}
	place, found := record_place(&state.hash_index, block)
	return found ? &state.hash_index.records[place] : nil
}

// record_take gives a new record of a block, or nil when the records are
// half full.
@(private = "file")
record_take :: proc "contextless" (index: ^Hash_Index, block: u64) -> ^Root_Record {
	if index.record_count >= u64(len(index.records)) / 2 {
		return nil
	}
	place, found := record_place(index, block)
	if found {
		return &index.records[place]
	}
	index.records[place] = {block = block}
	index.record_count += 1
	return &index.records[place]
}

// record_free frees the record of a block. Each later record of the same
// run whose first place is not after the hole moves into it, so that a
// search never stops at a hole before its record.
@(private = "file")
record_free :: proc "contextless" (index: ^Hash_Index, block: u64) {
	hole, found := record_place(index, block)
	if !found {
		return
	}
	capacity := u64(len(index.records))
	mask := capacity - 1
	index.records[hole] = {}
	index.record_count -= 1
	next := hole
	for _ in 0 ..< capacity {
		next = (next + 1) & mask
		moved := index.records[next]
		if moved.block == 0 {
			break
		}
		home := record_home(index, moved.block)
		if (hole - home) & mask < (next - home) & mask {
			index.records[hole] = moved
			index.records[next] = {}
			hole = next
		}
	}
}

// same_key says if the root in a slot has the key of a record: the same 8
// bytes of hash, the same size, the same store.
@(private = "file")
same_key :: proc "contextless" (state: ^State, block: u64, prefix: u64, size: u64, owner: u16) -> bool {
	record := hash_index_record(state, block)
	return record != nil && record.hash_prefix == prefix && record.size == size && block < state.capacity && block_owner(state, block) == owner
}

// hash_index_reset empties the index, and keeps its key of the slots.
hash_index_reset :: proc "contextless" (state: ^State) {
	index := &state.hash_index
	if len(index.records) > 0 {
		intrinsics.mem_zero(raw_data(index.records), len(index.records) * size_of(Root_Record))
	}
	if len(index.slots) > 0 {
		intrinsics.mem_zero(raw_data(index.slots), len(index.slots) * size_of(u64))
	}
	index.record_count = 0
	index.roots = 0
}

// slot_insert gives a root a slot, unless its key has one already or no
// slot is free inside HASH_PROBE_LIMIT. It gives true when its key had a
// slot already: another root of the store with the same key.
@(private = "file")
slot_insert :: proc "contextless" (state: ^State, record: ^Root_Record) -> (repeated: bool) {
	index := &state.hash_index
	block := record.block
	owner := block_owner(state, block)
	at := hash_home(index, record.hash_prefix)
	for _ in 0 ..< HASH_PROBE_LIMIT {
		other := index.slots[at]
		if other == 0 {
			index.slots[at] = block
			index.roots += 1
			return false
		}
		if same_key(state, other, record.hash_prefix, record.size, owner) {
			return true
		}
		at = slot_next(index, at)
	}
	return false
}

// slot_remove takes the slot of a root out of the table, when it has one.
// Each later slot of the same run whose first slot is not after the hole
// moves into it, so that a search never stops at a hole before its root.
// A root lies at most HASH_PROBE_LIMIT slots after its first slot, so a
// slot that far past the hole cannot move into it: the scan stops there.
@(private = "file")
slot_remove :: proc "contextless" (state: ^State, record: ^Root_Record) {
	index := &state.hash_index
	mask := hash_slot_capacity(index) - 1
	at := hash_home(index, record.hash_prefix)
	found := false
	for _ in 0 ..< HASH_PROBE_LIMIT {
		if index.slots[at] == 0 {
			break
		}
		if index.slots[at] == record.block {
			found = true
			break
		}
		at = slot_next(index, at)
	}
	if !found {
		return
	}
	index.roots -= 1
	hole := at
	next := at
	for (next - hole) & mask < HASH_PROBE_LIMIT {
		next = slot_next(index, next)
		moved := index.slots[next]
		if moved == 0 {
			break
		}
		moved_record := hash_index_record(state, moved)
		if moved_record == nil {
			break
		}
		home := hash_home(index, moved_record.hash_prefix)
		// The distance from its first slot to its slot, and from its first
		// slot to the hole, around the end of the table.
		to_next := (next - home) & mask
		to_hole := (hole - home) & mask
		if to_hole < to_next {
			index.slots[hole] = moved
			hole = next
		}
	}
	index.slots[hole] = 0
}

// hash_index_name counts one more entry that names `root` as the root of
// a state of `size` bytes with the hash `hash`. A root that the index does
// not hold yet gets a record, when the records have room, and a slot unless
// `hidden`. It gives true when the store of the root has another root with
// the same key: the open counts these.
hash_index_name :: proc "contextless" (state: ^State, hash: [32]u8, root: format.Pointer, size: u64, hidden: bool = false) -> (repeated: bool) {
	if root.block < 2 || root.block >= state.capacity {
		return false
	}
	if record := hash_index_record(state, root.block); record != nil {
		if record.entries < max(u32) {
			record.entries += 1
		}
		return false
	}
	record := record_take(&state.hash_index, root.block)
	if record == nil {
		return false
	}
	record^ = {block = root.block, hash_prefix = hash_prefix(hash), size = size, check = root.check, entries = 1, hidden = hidden}
	if hidden {
		return false
	}
	return slot_insert(state, record)
}

// hash_index_release counts one entry less that names `root`. The last
// one takes the root out of the index.
hash_index_release :: proc "contextless" (state: ^State, root: format.Pointer) {
	record := hash_index_record(state, root.block)
	if record == nil || record.entries == 0 {
		return
	}
	record.entries -= 1
	if record.entries != 0 {
		return
	}
	if !record.hidden {
		slot_remove(state, record)
	}
	record_free(&state.hash_index, root.block)
}

// hash_index_entry_change follows one entry that a commit changed: its
// value before (kind None: a new entry) and after (gone: the commit removes
// it). `hidden`: the store had a writable share of a tree open at the
// commit, so a root that the index does not hold yet is never a candidate.
// The storage service calls it after the root of the commit is on the disk.
hash_index_entry_change :: proc "contextless" (state: ^State, before: format.Entry, after: format.Entry, gone: bool, hidden: bool) {
	// The index keys a root by its hash and its size. A change that keeps
	// all three (an erase of the versions, which changes only the version
	// index) leaves the record as it is: a hidden root stays hidden.
	if !gone && after.kind == before.kind && after.pointer == before.pointer && after.hash == before.hash && after.size == before.size {
		return
	}
	if before.kind == u64(format.Entry_Kind.Object) {
		hash_index_release(state, before.pointer)
	}
	if !gone && after.kind == u64(format.Entry_Kind.Object) {
		hash_index_name(state, after.hash, after.pointer, after.size, hidden)
	}
}

// hash_index_rekey gives a root the key of the hash that its block tree
// gave at a confirmation: the hash of an entry comes from the disk, and a
// root whose entry gave another hash is then a candidate for its true bytes
// only, so a lie costs one confirmation.
hash_index_rekey :: proc "contextless" (state: ^State, root: format.Pointer, hash: [32]u8) {
	record := hash_index_record(state, root.block)
	if record == nil || record.entries == 0 || record.hidden {
		return
	}
	slot_remove(state, record)
	record.hash_prefix = hash_prefix(hash)
	slot_insert(state, record)
}

// hash_index_hide takes a root out of the slots for good: the service found
// it damaged. Its record stays, so that its entries are counted, and the
// key is free for a later root with the same bytes.
hash_index_hide :: proc "contextless" (state: ^State, root: format.Pointer) {
	record := hash_index_record(state, root.block)
	if record == nil || record.entries == 0 || record.hidden {
		return
	}
	slot_remove(state, record)
	record.hidden = true
}

// Hash_Search is the state of a lookup of one key: hash_index_next gives
// the next candidate.
Hash_Search :: struct {
	prefix: u64,
	size:   u64,
	owner:  u16, // The store, plus 1.
	at:     u64, // The next slot to read.
	read:   u64, // The slots read.
}

// hash_search_begin starts a lookup of the roots of a state with this hash
// and this size in a store.
hash_search_begin :: proc "contextless" (state: ^State, hash: [32]u8, size: u64, store_index: int) -> Hash_Search {
	prefix := hash_prefix(hash)
	return {prefix = prefix, size = size, owner = u16(store_index + 1), at = hash_home(&state.hash_index, prefix)}
}

// hash_index_next gives the next root of the index with the key of the
// search. It is a candidate: its state must give the whole hash before a
// commit names it. It reads at most HASH_PROBE_LIMIT slots in all.
hash_index_next :: proc "contextless" (state: ^State, search: ^Hash_Search) -> (root: format.Pointer, found: bool) {
	index := &state.hash_index
	if len(index.slots) == 0 {
		return {}, false
	}
	for search.read < HASH_PROBE_LIMIT {
		block := index.slots[search.at]
		if block == 0 {
			return {}, false
		}
		search.at = slot_next(index, search.at)
		search.read += 1
		if same_key(state, block, search.prefix, search.size, search.owner) {
			record := hash_index_record(state, block)
			return {block = block, check = record.check}, true
		}
	}
	return {}, false
}

// hash_index_entries gives the count of the current entries that name a
// block as their root: 0 when the index does not hold it.
hash_index_entries :: proc "contextless" (state: ^State, block: u64) -> u32 {
	record := hash_index_record(state, block)
	return record != nil ? record.entries : 0
}

// hash_index_slotted says if a root has a slot: a search can find it.
hash_index_slotted :: proc "contextless" (state: ^State, block: u64) -> bool {
	record := hash_index_record(state, block)
	if record == nil || record.entries == 0 {
		return false
	}
	index := &state.hash_index
	at := hash_home(index, record.hash_prefix)
	for _ in 0 ..< HASH_PROBE_LIMIT {
		other := index.slots[at]
		if other == 0 {
			return false
		}
		if other == block {
			return true
		}
		at = slot_next(index, at)
	}
	return false
}

// hash_index_check gives the count of the faults of the index: a slot that
// names a block with no record, or a hidden one, or that lies past
// HASH_PROBE_LIMIT from its first slot, an empty slot between the first
// slot of a root and its slot (a search would stop there and miss it), two
// slots with one key, a record that its own search does not find, and a
// count of the roots or of the records that is not the count of the slots
// or of the records in use. The tests run it on each image of a loss of
// power.
hash_index_check :: proc "contextless" (state: ^State) -> (faults: u64) {
	index := &state.hash_index
	mask := hash_slot_capacity(index) - 1
	in_records: u64
	for &record in index.records {
		if record.block == 0 {
			continue
		}
		in_records += 1
		if hash_index_record(state, record.block) != &record || record.entries == 0 {
			faults += 1
		}
	}
	if in_records != index.record_count {
		faults += 1
	}
	in_slots: u64
	for block, at in index.slots {
		if block == 0 {
			continue
		}
		in_slots += 1
		record := hash_index_record(state, block)
		if record == nil || record.entries == 0 || record.hidden {
			faults += 1
			continue
		}
		home := hash_home(index, record.hash_prefix)
		if (u64(at) - home) & mask >= HASH_PROBE_LIMIT {
			faults += 1
		}
		// Each slot of the run before it is in use, and none has its key.
		probe := home
		for probe != u64(at) {
			if index.slots[probe] == 0 {
				faults += 1
			} else if same_key(state, index.slots[probe], record.hash_prefix, record.size, block_owner(state, block)) {
				faults += 1
			}
			probe = slot_next(index, probe)
			if (probe - home) & mask >= HASH_PROBE_LIMIT {
				break
			}
		}
	}
	if in_slots != index.roots {
		faults += 1
	}
	return faults
}
