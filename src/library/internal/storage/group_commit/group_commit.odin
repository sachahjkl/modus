// Group commit staging state for the storage service.
//
// Multiple concurrent commits targeting distinct stores are planned one by one
// in the service's single Plan, then staged into one Batch. Staging seals
// encrypted data blocks immediately under that store's own Store_Keys so two
// principals' keys never mix, tracks per-block store owners and allocated
// blocks in an O(1) hash table, and merges touched Store_Table_Pages once per
// page at flush time (src/md/features/storage_coalesce_and_group_commit.md).
//
// All bounds are inline capacities: when a store does not fit, the caller
// flushes the staged batch and runs that store solo so grouping never causes a
// spurious capacity refusal. This package is freestanding and allocates no
// memory.
package group_commit

import "base:intrinsics"
import format "modus:contract/store"
import "internal:storage/store_encryption"

Block :: [format.BLOCK_SIZE]u8

// Inline capacities for one grouped commit batch: sized for typical multi-store
// concurrent passes (~664 KiB total BSS) while keeping solo fallback automatic.
STORE_CAPACITY :: 16
WRITE_CAPACITY :: 128
DELTA_CAPACITY :: 2048
OWNER_SLOTS :: 4096 // Power of 2, twice DELTA_CAPACITY (load factor <= 0.5).
LATER_CAPACITY :: 256
HASH_ENTRY_CAPACITY :: 64
PAGE_CAPACITY :: STORE_CAPACITY

#assert(OWNER_SLOTS >= 2 * DELTA_CAPACITY)
#assert(OWNER_SLOTS & (OWNER_SLOTS - 1) == 0)

// Stage_Decision reports whether another store commit can join the current
// staged batch or whether the caller must flush the batch first.
Stage_Decision :: enum {
	Can_Stage,
	Flush_First,
}

// Write_Input describes one block produced by a store's plan before staging.
Write_Input :: struct {
	number:         u64,
	bytes:          ^Block,
	encrypted_data: bool,
	data_check:     u64,
}

// Later_Input describes a newly written tree or version block to place in the
// service's block cache after the group commit reaches the disk.
Later_Input :: struct {
	pointer: format.Pointer,
	bytes:   ^Block,
}

// Delta is one reference-count change attributed to its owning store
// (store_index + 1).
Delta :: struct {
	number: u64,
	change: i32,
	owner:  u16,
}

Staged_Write :: struct {
	number:      u64,
	block_index: int,
}

Staged_Later :: struct {
	pointer:     format.Pointer,
	block_index: int,
	store_index: int,
	owner_slot:  u8,
}

Staged_Hash_Entry :: struct {
	before: format.Entry,
	entry:  format.Entry,
	gone:   bool,
	hidden: bool,
}

// Store_Input carries one store's validated plan metadata into batch_stage_store.
// Passed by pointer so no large struct is copied by value.
Store_Input :: struct {
	store_index:      int,
	cell:             format.Store_Entry,
	store_block:      format.Store_Block,
	versions_change:  i64,
	shared_change:    i64,
	dropped_versions: u64,
	release_damaged:  u64,
	dead_blocks:      u64,
	encrypted:        bool,
	owner_slot:       u64,
	store_keys:       ^store_encryption.Store_Keys,
	at_limit_thinned: u64,
	store_limit:      u64,
	store_name:       string,
	hidden_hash:      bool,
}

// Staged_Store holds one store's post-flush state inside a Batch.
Staged_Store :: struct {
	store_index:      int,
	page_index:       int,
	cell_index:       int,
	cell:             format.Store_Entry,
	store_block:      format.Store_Block,
	versions_change:  i64,
	shared_change:    i64,
	dropped_versions: u64,
	encrypted:        bool,
	owner_slot:       u64,
	store_keys:       store_encryption.Store_Keys,
	at_limit_thinned: u64,
	store_limit:      u64,
	store_name_len:   u8,
	store_name:       [format.NAME_CAPACITY]u8,
	write_count:      int,
}

// Batch accumulates validated per-store plans until one shared root commit.
Batch :: struct {
	stores:      [STORE_CAPACITY]Staged_Store,
	store_count: int,

	// On-disk bytes (already sealed/encrypted with each store's own keys).
	blocks:      [WRITE_CAPACITY]Block,
	writes:      [WRITE_CAPACITY]Staged_Write,
	write_count: int,

	taken:       [WRITE_CAPACITY]u64,
	taken_count: int,

	deltas:      [DELTA_CAPACITY]Delta,
	delta_count: int,

	// Open-addressing index over all staged blocks for O(1) owner_of and
	// block_taken queries during subsequent store planning and flush.
	owner_blocks: [OWNER_SLOTS]u64,
	owner_values: [OWNER_SLOTS]u16,
	owner_taken:  [OWNER_SLOTS]bool,
	owner_places: [DELTA_CAPACITY]u16,
	owner_count:  int,

	later:       [LATER_CAPACITY]Staged_Later,
	later_count: int,

	hash_entries:     [HASH_ENTRY_CAPACITY]Staged_Hash_Entry,
	hash_entry_count: int,

	release_damaged:  u64,
	dead_blocks:      u64,
	dropped_versions: u64,

	// Merged Store_Table_Pages built at flush time by batch_merge_store_pages.
	pages:        [PAGE_CAPACITY]format.Store_Table_Page,
	page_indices: [PAGE_CAPACITY]int,
	page_count:   int,
}

// store_name_of returns the stored name slice for a Staged_Store.
store_name_of :: proc "contextless" (s: ^Staged_Store) -> string {
	return string(s.store_name[:s.store_name_len])
}

// batch_has_store reports whether store_index is already staged in b.
batch_has_store :: proc "contextless" (b: ^Batch, store_index: int) -> bool {
	if store_index < 0 {
		return false
	}
	for i in 0 ..< b.store_count {
		if b.stores[i].store_index == store_index {
			return true
		}
	}
	return false
}

@(private = "file")
owner_slot_find :: proc "contextless" (b: ^Batch, number: u64) -> (slot: int, found: bool) {
	if number == 0 {
		return -1, false
	}
	mask := u64(OWNER_SLOTS - 1)
	at := (number * 0x9E37_79B9_7F4A_7C15 >> 20) & mask
	for _ in 0 ..< OWNER_SLOTS {
		existing := b.owner_blocks[at]
		if existing == number {
			return int(at), true
		}
		if existing == 0 {
			return int(at), false
		}
		at = (at + 1) & mask
	}
	return -1, false
}

@(private = "file")
owner_index_put :: proc "contextless" (b: ^Batch, number: u64, owner: u16, taken: bool) -> bool {
	slot, found := owner_slot_find(b, number)
	if slot < 0 {
		return false
	}
	if !found {
		if b.owner_count >= len(b.owner_places) {
			return false
		}
		b.owner_blocks[slot] = number
		b.owner_values[slot] = owner
		b.owner_taken[slot] = taken
		b.owner_places[b.owner_count] = u16(slot)
		b.owner_count += 1
		return true
	}
	b.owner_values[slot] = owner
	if taken {
		b.owner_taken[slot] = true
	}
	return true
}

// batch_owner_of gives the owning store (store_index + 1) of a block staged in
// b, or (0, false) if b does not name that block.
batch_owner_of :: proc "contextless" (b: ^Batch, number: u64) -> (owner: u16, found: bool) {
	if b.owner_count == 0 {
		return 0, false
	}
	slot, ok := owner_slot_find(b, number)
	if !ok {
		return 0, false
	}
	return b.owner_values[slot], true
}

// batch_block_taken reports whether number was allocated by a store already
// staged in b (used by Count_Tree free-block search so later stores in the
// same batch never reuse a staged block).
batch_block_taken :: proc "contextless" (b: ^Batch, number: u64) -> bool {
	if b.owner_count == 0 {
		return false
	}
	slot, ok := owner_slot_find(b, number)
	return ok && b.owner_taken[slot]
}

// batch_can_stage checks whether a validated store plan fits inside b's inline
// capacities without conflicting with any already-staged store.
batch_can_stage :: proc "contextless" (b: ^Batch, store_index, writes, taken, deltas, later, hash_entries: int) -> Stage_Decision {
	if store_index < 0 || store_index >= format.STORE_CAPACITY {
		return .Flush_First
	}
	if writes < 0 || taken < 0 || deltas < 0 || later < 0 || hash_entries < 0 {
		return .Flush_First
	}
	if batch_has_store(b, store_index) {
		return .Flush_First
	}
	if b.store_count >= STORE_CAPACITY {
		return .Flush_First
	}
	if b.write_count + writes > WRITE_CAPACITY {
		return .Flush_First
	}
	if b.taken_count + taken > WRITE_CAPACITY {
		return .Flush_First
	}
	if b.delta_count + deltas > DELTA_CAPACITY {
		return .Flush_First
	}
	// Every unique taken block and delta block occupies at most one slot in
	// owner_places (sized to DELTA_CAPACITY).
	if b.owner_count + deltas + taken > DELTA_CAPACITY {
		return .Flush_First
	}
	if b.later_count + later > LATER_CAPACITY {
		return .Flush_First
	}
	if b.hash_entry_count + hash_entries > HASH_ENTRY_CAPACITY {
		return .Flush_First
	}
	return .Can_Stage
}

// batch_stage_store appends one validated store plan into b. Any
// encrypted_data write is encrypted immediately into b.blocks under
// input.store_keys so plaintext never lingers in shared staging buffers and
// two principals' keys never mix. Returns (store_slot, true) on success, or
// (-1, false) without mutating b if capacities or store uniqueness refuse it.
batch_stage_store :: proc "contextless" (
	b: ^Batch,
	input: ^Store_Input,
	writes: []Write_Input,
	taken: []u64,
	deltas: []Delta,
	later_inputs: []Later_Input,
	hash_before: []format.Entry,
	hash_entry: []format.Entry,
	hash_gone: []bool,
) -> (store_slot: int, ok: bool) {
	if len(hash_before) != len(hash_entry) || len(hash_before) != len(hash_gone) {
		return -1, false
	}
	if batch_can_stage(b, input.store_index, len(writes), len(taken), len(deltas), len(later_inputs), len(hash_before)) != .Can_Stage {
		return -1, false
	}
	if input.encrypted && input.store_keys == nil {
		return -1, false
	}

	write_base := b.write_count
	for w, i in writes {
		slot := write_base + i
		intrinsics.mem_copy_non_overlapping(&b.blocks[slot], w.bytes, format.BLOCK_SIZE)
		if w.encrypted_data {
			_ = store_encryption.data_block_encrypt(input.store_keys, w.number, w.data_check, &b.blocks[slot])
		}
		b.writes[slot] = {number = w.number, block_index = slot}
	}
	b.write_count = write_base + len(writes)

	owner := u16(input.store_index + 1)
	taken_base := b.taken_count
	for number, i in taken {
		b.taken[taken_base + i] = number
		_ = owner_index_put(b, number, owner, true)
	}
	b.taken_count = taken_base + len(taken)

	delta_base := b.delta_count
	for d, i in deltas {
		entry := d
		entry.owner = owner
		b.deltas[delta_base + i] = entry
		_ = owner_index_put(b, entry.number, owner, false)
	}
	b.delta_count = delta_base + len(deltas)

	owner_slot_mark: u8 = input.encrypted ? u8(input.owner_slot + 1) : 0
	for item in later_inputs {
		// Match against the blocks just copied for this store.
		for slot in write_base ..< b.write_count {
			if b.writes[slot].number == item.pointer.block {
				b.later[b.later_count] = {
					pointer     = item.pointer,
					block_index = slot,
					store_index = input.store_index,
					owner_slot  = owner_slot_mark,
				}
				b.later_count += 1
				break
			}
		}
	}

	for i in 0 ..< len(hash_before) {
		b.hash_entries[b.hash_entry_count] = {
			before = hash_before[i],
			entry  = hash_entry[i],
			gone   = hash_gone[i],
			hidden = input.hidden_hash,
		}
		b.hash_entry_count += 1
	}

	b.release_damaged += input.release_damaged
	b.dead_blocks += input.dead_blocks
	b.dropped_versions += input.dropped_versions

	page_index, cell_index := format.store_place(input.store_index)
	store_slot = b.store_count
	s := &b.stores[store_slot]
	s^ = {
		store_index      = input.store_index,
		page_index       = page_index,
		cell_index       = cell_index,
		cell             = input.cell,
		store_block      = input.store_block,
		versions_change  = input.versions_change,
		shared_change    = input.shared_change,
		dropped_versions = input.dropped_versions,
		encrypted        = input.encrypted,
		owner_slot       = input.owner_slot,
		at_limit_thinned = input.at_limit_thinned,
		store_limit      = input.store_limit,
		write_count      = len(writes),
	}
	if input.encrypted {
		s.store_keys = input.store_keys^
	}
	name_len := min(len(input.store_name), format.NAME_CAPACITY)
	copy(s.store_name[:name_len], input.store_name[:name_len])
	s.store_name_len = u8(name_len)
	b.store_count += 1
	return store_slot, true
}

// batch_merge_store_pages builds one Store_Table_Page per distinct page_index
// touched by b.stores[:b.store_count], starting from existing_pages (or a new
// page with STORE_TABLE_MAGIC when page_index >= existing_page_count) and
// applying every staged store's final Store_Entry cell.
batch_merge_store_pages :: proc "contextless" (b: ^Batch, existing_page_count: u64, existing_pages: []format.Store_Table_Page) {
	b.page_count = 0
	for i in 0 ..< b.store_count {
		s := &b.stores[i]
		slot := -1
		for p in 0 ..< b.page_count {
			if b.page_indices[p] == s.page_index {
				slot = p
				break
			}
		}
		if slot < 0 {
			slot = b.page_count
			b.page_indices[slot] = s.page_index
			if u64(s.page_index) < existing_page_count && s.page_index < len(existing_pages) {
				b.pages[slot] = existing_pages[s.page_index]
			} else {
				b.pages[slot] = format.Store_Table_Page{magic = format.STORE_TABLE_MAGIC}
			}
			b.page_count += 1
		}
		b.pages[slot].cells[s.cell_index] = s.cell
	}
}

// batch_reset clears all staged state and volatile-zeroes every staged block
// buffer and Store_Keys copy.
batch_reset :: proc "contextless" (b: ^Batch) {
	for i in 0 ..< b.owner_count {
		slot := b.owner_places[i]
		b.owner_blocks[slot] = 0
		b.owner_values[slot] = 0
		b.owner_taken[slot] = false
	}
	b.owner_count = 0
	if b.write_count > 0 {
		intrinsics.mem_zero_volatile(&b.blocks[0], b.write_count * size_of(Block))
	}
	for i in 0 ..< b.store_count {
		intrinsics.mem_zero_volatile(&b.stores[i].store_keys, size_of(store_encryption.Store_Keys))
		intrinsics.mem_zero_volatile(&b.stores[i].store_block, size_of(format.Store_Block))
	}
	b.store_count = 0
	b.write_count = 0
	b.taken_count = 0
	b.delta_count = 0
	b.later_count = 0
	b.hash_entry_count = 0
	b.release_damaged = 0
	b.dead_blocks = 0
	b.dropped_versions = 0
	b.page_count = 0
}

// batch_abort rolls back a multi-store batch on flush failure (dropped write
// or device error): frees every taken block of every staged store through
// free_block and volatile-zeroes all staged blocks and keys.
batch_abort :: proc "contextless" (b: ^Batch, free_block: proc "contextless" (ctx: rawptr, number: u64), ctx: rawptr) {
	if free_block != nil {
		for number in b.taken[:b.taken_count] {
			free_block(ctx, number)
		}
	}
	batch_reset(b)
}

// batch_erase_all volatile-zeroes the entire Batch (called on principal lock).
batch_erase_all :: proc "contextless" (b: ^Batch) {
	intrinsics.mem_zero_volatile(b, size_of(Batch))
}
