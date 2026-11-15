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
// The slots find a root by its key: the 8 bytes of the hash, the size and
// the store. One key has at most one slot: a second root with the same key
// keeps a record and no slot, so equal keys never make a run of slots. The
// first slot of a key comes from the 8 bytes mixed with a key of the slots
// that the service draws at each start: no party can choose hashes that
// fall in one run. A search and an insert read at most HASH_PROBE_LIMIT
// slots. A removal reads at most HASH_PROBE_LIMIT slots past each slot that
// it moves back: its cost follows the length of the run, which stays short
// when no party chooses the first slots.

// HASH_SLOT_BITS gives the count of the slots: twice the blocks of a disk.
// A root is one block, so at most half of the slots are in use.
HASH_SLOT_BITS :: 19
HASH_SLOT_CAPACITY :: u64(1) << HASH_SLOT_BITS
#assert(HASH_SLOT_CAPACITY == 2 * format.DISK_BLOCKS_LIMIT)

// HASH_PROBE_LIMIT is the most slots that a search or an insert reads from
// the first slot of a key. At a load of one half, with first slots that no
// party chooses, a run of this length is far rarer than one in a million
// inserts; a root that finds no slot inside the bound keeps a record with
// no slot, and the only loss is that a later commit does not find it.
HASH_PROBE_LIMIT :: 32

// The odd constant of the mix of the first slot (the golden ratio of 64
// bits): a product by it spreads the bits of the key into the high bits.
HASH_SLOT_MIX :: u64(0x9E37_79B9_7F4A_7C15)

// What the index knows of one root. 32 bytes.
Root_Record :: struct {
	hash_prefix: u64, // The first 8 bytes of the hash of the state, as the entry that named it first gave it, or as a confirmation found it.
	size:        u64, // The size of the state.
	check:       u64, // The check of the root: its Pointer is the block and this check.
	entries:     u32, // The current entries that name the block as their root. 0: the block is not in the index.
	hidden:      bool, // Never a candidate, and no slot: the root was named first while its store had a writable share of a tree open, or the service found it damaged.
	reserved:    [3]u8, // 0.
}
#assert(size_of(Root_Record) == 32)

// The index of one disk: about 10 MiB.
Hash_Index :: struct {
	records:  [format.DISK_BLOCKS_LIMIT]Root_Record, // At the number of the root block.
	slots:    [HASH_SLOT_CAPACITY]u32, // The number of a root block; 0: empty. Linear probing from the first slot of the key.
	roots:    u64, // The roots that have a slot.
	slot_key: u64, // Mixed into the first slot of each key. The service draws it at its start; the reset keeps it.
}

// hash_prefix gives the first 8 bytes of a hash.
hash_prefix :: proc "contextless" (hash: [32]u8) -> u64 {
	copy_of := hash
	return intrinsics.unaligned_load((^u64)(&copy_of[0]))
}

// hash_home gives the first slot of a key.
@(private = "file")
hash_home :: #force_inline proc "contextless" (index: ^Hash_Index, prefix: u64) -> u64 {
	return ((prefix ~ index.slot_key) * HASH_SLOT_MIX) >> (64 - HASH_SLOT_BITS)
}

@(private = "file")
slot_next :: #force_inline proc "contextless" (at: u64) -> u64 {
	return (at + 1) & (HASH_SLOT_CAPACITY - 1)
}

// same_key says if the root in a slot has the key of a record: the same 8
// bytes of hash, the same size, the same store.
@(private = "file")
same_key :: proc "contextless" (state: ^State, block: u32, prefix: u64, size: u64, owner: u8) -> bool {
	record := &state.hash_index.records[block]
	return record.hash_prefix == prefix && record.size == size && state.owner[block] == owner
}

// hash_index_reset empties the index, and keeps its key of the slots.
hash_index_reset :: proc "contextless" (state: ^State) {
	state.hash_index.records = {}
	state.hash_index.slots = {}
	state.hash_index.roots = 0
}

// slot_insert gives a root a slot, unless its key has one already or no
// slot is free inside HASH_PROBE_LIMIT. It gives true when its key had a
// slot already: another root of the store with the same key.
@(private = "file")
slot_insert :: proc "contextless" (state: ^State, block: u64) -> (repeated: bool) {
	index := &state.hash_index
	record := &index.records[block]
	owner := state.owner[block]
	at := hash_home(index, record.hash_prefix)
	for _ in 0 ..< HASH_PROBE_LIMIT {
		other := index.slots[at]
		if other == 0 {
			index.slots[at] = u32(block)
			index.roots += 1
			return false
		}
		if same_key(state, other, record.hash_prefix, record.size, owner) {
			return true
		}
		at = slot_next(at)
	}
	return false
}

// slot_remove takes the slot of a root out of the table, when it has one.
// Each later slot of the same run whose first slot is not after the hole
// moves into it, so that a search never stops at a hole before its root.
// A root lies at most HASH_PROBE_LIMIT slots after its first slot, so a
// slot that far past the hole cannot move into it: the scan stops there.
@(private = "file")
slot_remove :: proc "contextless" (state: ^State, block: u64) {
	index := &state.hash_index
	at := hash_home(index, index.records[block].hash_prefix)
	found := false
	for _ in 0 ..< HASH_PROBE_LIMIT {
		if index.slots[at] == 0 {
			break
		}
		if u64(index.slots[at]) == block {
			found = true
			break
		}
		at = slot_next(at)
	}
	if !found {
		return
	}
	index.roots -= 1
	hole := at
	next := at
	for (next - hole) & (HASH_SLOT_CAPACITY - 1) < HASH_PROBE_LIMIT {
		next = slot_next(next)
		moved := index.slots[next]
		if moved == 0 {
			break
		}
		home := hash_home(index, index.records[moved].hash_prefix)
		// The distance from its first slot to its slot, and from its first
		// slot to the hole, around the end of the table.
		to_next := (next - home) & (HASH_SLOT_CAPACITY - 1)
		to_hole := (hole - home) & (HASH_SLOT_CAPACITY - 1)
		if to_hole < to_next {
			index.slots[hole] = moved
			hole = next
		}
	}
	index.slots[hole] = 0
}

// hash_index_name counts one more entry that names `root` as the root of
// a state of `size` bytes with the hash `hash`. A root that the index does
// not hold yet gets a record, and a slot unless `hidden`. It gives true
// when the store of the root has another root with the same key: the open
// counts these.
hash_index_name :: proc "contextless" (state: ^State, hash: [32]u8, root: format.Pointer, size: u64, hidden: bool = false) -> (repeated: bool) {
	if root.block < 2 || root.block >= format.DISK_BLOCKS_LIMIT {
		return false
	}
	record := &state.hash_index.records[root.block]
	if record.entries != 0 {
		if record.entries < max(u32) {
			record.entries += 1
		}
		return false
	}
	record^ = {hash_prefix = hash_prefix(hash), size = size, check = root.check, entries = 1, hidden = hidden}
	if hidden {
		return false
	}
	return slot_insert(state, root.block)
}

// hash_index_release counts one entry less that names `root`. The last
// one takes the root out of the index.
hash_index_release :: proc "contextless" (state: ^State, root: format.Pointer) {
	if root.block < 2 || root.block >= format.DISK_BLOCKS_LIMIT {
		return
	}
	record := &state.hash_index.records[root.block]
	if record.entries == 0 {
		return
	}
	record.entries -= 1
	if record.entries != 0 {
		return
	}
	if !record.hidden {
		slot_remove(state, root.block)
	}
	record^ = {}
}

// hash_index_entry_change follows one entry that a commit changed: its
// value before (kind None: a new entry) and after (gone: the commit removes
// it). `hidden`: the store had a writable share of a tree open at the
// commit, so a root that the index does not hold yet is never a candidate.
// The storage service calls it after the root of the commit is on the disk.
hash_index_entry_change :: proc "contextless" (state: ^State, before: format.Entry, after: format.Entry, gone: bool, hidden: bool) {
	if !gone && after == before {
		return
	}
	if before.kind == .Object {
		hash_index_release(state, before.pointer)
	}
	if !gone && after.kind == .Object {
		hash_index_name(state, after.hash, after.pointer, after.size, hidden)
	}
}

// hash_index_rekey gives a root the key of the hash that its block tree
// gave at a confirmation: the hash of an entry comes from the disk, and a
// root whose entry gave another hash is then a candidate for its true bytes
// only, so a lie costs one confirmation.
hash_index_rekey :: proc "contextless" (state: ^State, root: format.Pointer, hash: [32]u8) {
	if root.block < 2 || root.block >= format.DISK_BLOCKS_LIMIT {
		return
	}
	record := &state.hash_index.records[root.block]
	if record.entries == 0 || record.hidden {
		return
	}
	slot_remove(state, root.block)
	record.hash_prefix = hash_prefix(hash)
	slot_insert(state, root.block)
}

// hash_index_hide takes a root out of the slots for good: the service found
// it damaged. Its record stays, so that its entries are counted, and the
// key is free for a later root with the same bytes.
hash_index_hide :: proc "contextless" (state: ^State, root: format.Pointer) {
	if root.block < 2 || root.block >= format.DISK_BLOCKS_LIMIT {
		return
	}
	record := &state.hash_index.records[root.block]
	if record.entries == 0 || record.hidden {
		return
	}
	slot_remove(state, root.block)
	record.hidden = true
}

// Hash_Search is the state of a lookup of one key: hash_index_next gives
// the next candidate.
Hash_Search :: struct {
	prefix: u64,
	size:   u64,
	owner:  u8, // The store, plus 1.
	at:     u64, // The next slot to read.
	read:   u64, // The slots read.
}

// hash_search_begin starts a lookup of the roots of a state with this hash
// and this size in a store.
hash_search_begin :: proc "contextless" (state: ^State, hash: [32]u8, size: u64, store_index: int) -> Hash_Search {
	prefix := hash_prefix(hash)
	return {prefix = prefix, size = size, owner = u8(store_index + 1), at = hash_home(&state.hash_index, prefix)}
}

// hash_index_next gives the next root of the index with the key of the
// search. It is a candidate: its state must give the whole hash before a
// commit names it. It reads at most HASH_PROBE_LIMIT slots in all.
hash_index_next :: proc "contextless" (state: ^State, search: ^Hash_Search) -> (root: format.Pointer, found: bool) {
	index := &state.hash_index
	for search.read < HASH_PROBE_LIMIT {
		block := index.slots[search.at]
		if block == 0 {
			return {}, false
		}
		search.at = slot_next(search.at)
		search.read += 1
		if same_key(state, block, search.prefix, search.size, search.owner) {
			record := &index.records[block]
			return {block = u64(block), check = record.check}, true
		}
	}
	return {}, false
}

// hash_index_entries gives the count of the current entries that name a
// block as their root: 0 when the index does not hold it.
hash_index_entries :: proc "contextless" (state: ^State, block: u64) -> u32 {
	return block < format.DISK_BLOCKS_LIMIT ? state.hash_index.records[block].entries : 0
}

// hash_index_slotted says if a root has a slot: a search can find it.
hash_index_slotted :: proc "contextless" (state: ^State, block: u64) -> bool {
	if block < 2 || block >= format.DISK_BLOCKS_LIMIT || state.hash_index.records[block].entries == 0 {
		return false
	}
	index := &state.hash_index
	at := hash_home(index, index.records[block].hash_prefix)
	for _ in 0 ..< HASH_PROBE_LIMIT {
		other := index.slots[at]
		if other == 0 {
			return false
		}
		if u64(other) == block {
			return true
		}
		at = slot_next(at)
	}
	return false
}

// hash_index_check gives the count of the faults of the index: a slot that
// names a block with no record, or a hidden one, or that lies past
// HASH_PROBE_LIMIT from its first slot, an empty slot between the first
// slot of a root and its slot (a search would stop there and miss it), two
// slots with one key, and a count of the roots that is not the count of
// the slots in use. The tests run it on each image of a loss of power.
hash_index_check :: proc "contextless" (state: ^State) -> (faults: u64) {
	index := &state.hash_index
	in_slots: u64
	for block, at in index.slots {
		if block == 0 {
			continue
		}
		in_slots += 1
		record := &index.records[block]
		if record.entries == 0 || record.hidden {
			faults += 1
			continue
		}
		if (u64(at) - hash_home(index, record.hash_prefix)) & (HASH_SLOT_CAPACITY - 1) >= HASH_PROBE_LIMIT {
			faults += 1
		}
		// Each slot of the run before it is in use, and none has its key.
		probe := hash_home(index, record.hash_prefix)
		for probe != u64(at) {
			if index.slots[probe] == 0 {
				faults += 1
			} else if same_key(state, index.slots[probe], record.hash_prefix, record.size, state.owner[block]) {
				faults += 1
			}
			probe = slot_next(probe)
			if (probe - hash_home(index, record.hash_prefix)) & (HASH_SLOT_CAPACITY - 1) >= HASH_PROBE_LIMIT {
				break
			}
		}
	}
	if in_slots != index.roots {
		faults += 1
	}
	return faults
}
