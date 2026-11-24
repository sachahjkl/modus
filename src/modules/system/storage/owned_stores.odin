package storage_service

import "base:intrinsics"
import principal_keys "internal:storage/principal_keys"
import "internal:storage/storage_mount"
import "modus:contract/errors"
import format "modus:contract/store"
import "modus:principals"
import "modus:random"
import "internal:storage/store_encryption"
import "modus:system"

// The stores of a named principal (src/md/features/store_encryption.md).
// Their cell keeps the name tag of their name, with OWNED_CELL_MARK as its
// first byte, and their store block keeps the owner, the salt, the key
// check, the sealed name, the store generation, and a 128-bit MAC. A store
// of a named principal is found, made, and opened only with the keys of that
// principal, which the root service gives at its unlock (principal_keys.odin):
// a locked principal has no store that this service finds.

// The generator of the salts of new stores: its stream starts with the key
// of the slots of the hash index (entry). A salt is public; its one duty is
// to never come two times.
salt_generator: random.Generator

// For each store whose owner, key check, rollback floor, and Store_Block MAC
// matched the keys held: the slot plus 1. Cleared for a slot at its lock, so
// a new principal in the slot checks again.
owned_checked: [format.STORE_CAPACITY]u8

// Session-wide monotonic floor of verified store_generation for each store
// cell: rejects any rollback of an owned Store_Block to an older generation.
owned_min_generation: [format.STORE_CAPACITY]u64

// Inline capacity (same 64-slot scale as block_cache): keeps derived
// Store_Keys for recently used owned stores without a 2 MiB static table.
// Past this capacity, a miss re-derives keys from principal_storage and the
// cached Store_Block, incrementing owned_key_cache_misses.
OWNED_KEY_CACHE_CAPACITY :: 64

Owned_Key_Cache_Entry :: struct {
	store_index: i32,
	slot:        u8,
	occupied:    bool,
	used:        u64,
	keys:        store_encryption.Store_Keys,
}

owned_key_cache: [OWNED_KEY_CACHE_CAPACITY]Owned_Key_Cache_Entry
owned_key_cache_tick: u64
owned_key_cache_misses: u64

// Active store encryption context for block reads and writes during a call
// or plan. Keys are copied by value so cache eviction never aliases or dangles
// a scope across nested operations (e.g. freeze_tree reading a source store
// while committing objects to a target store).
Store_Crypto_Scope :: struct {
	keys:          store_encryption.Store_Keys,
	has_keys:      bool,
	store_index:   int,
	owner_slot:    u8,
	was_encrypted: bool,
}

active_store_keys_value: store_encryption.Store_Keys
active_store_keys: ^store_encryption.Store_Keys
active_store_index: int = -1
active_store_owner_slot: u8

// owned_cell says if the cell of a store keeps a name tag.
owned_cell :: proc "contextless" (index: int) -> bool {
	return store_cell(index).name[0] == format.OWNED_CELL_MARK
}

// owned_unlocked says if a store is either a clear store or an owned store
// whose principal slot is currently verified and unlocked.
owned_unlocked :: proc "contextless" (index: int) -> bool {
	if !owned_cell(index) {
		return true
	}
	checked := owned_checked[index]
	if checked == 0 {
		return false
	}
	return principal_keys_held(u64(checked - 1)) != nil
}

// owned_slot gives the slot of the principal whose store a name names, or
// principal 0 for a store of the machine (principals.store_name_principal).
owned_slot :: proc "contextless" (name: string) -> u64 {
	return principals.store_name_principal(name)
}

// owned_tag gives the field of the cell of a store of a principal: the mark,
// then the first 31 bytes of the name tag. ok is false for a name that no
// tag takes.
owned_tag :: proc "contextless" (keys: ^Principal_Storage, name: string) -> (field: [format.NAME_CAPACITY]u8, ok: bool) {
	return principal_keys.cell_field(keys, name)
}

// owned_store_keys_put caches derived Store_Keys for an owned store cell.
owned_store_keys_put :: proc "contextless" (store_index: int, slot: u64, keys: ^store_encryption.Store_Keys) {
	target := -1
	oldest := 0
	for &entry, idx in owned_key_cache {
		if entry.occupied && int(entry.store_index) == store_index {
			target = idx
			break
		}
		if !entry.occupied {
			target = idx
			break
		}
		if entry.used < owned_key_cache[oldest].used {
			oldest = idx
		}
	}
	if target < 0 {
		target = oldest
		intrinsics.mem_zero_volatile(&owned_key_cache[target].keys, size_of(store_encryption.Store_Keys))
	}
	owned_key_cache_tick += 1
	owned_key_cache[target] = {
		store_index = i32(store_index),
		slot        = u8(slot),
		occupied    = true,
		used        = owned_key_cache_tick,
		keys        = keys^,
	}
}

// owned_store_keys_get copies the verified Store_Keys for an owned store,
// deriving and caching them on a cache miss after verifying the Store_Block
// MAC and rollback floor. Distinguishes .Device from .Wrong (locked principal
// or verification failure).
owned_store_keys_get :: proc "contextless" (store_index: int) -> (keys: store_encryption.Store_Keys, outcome: Read) {
	if store_index < 0 || store_index >= store_numbers() || !owned_cell(store_index) {
		return {}, .Wrong
	}
	checked := owned_checked[store_index]
	if checked == 0 {
		return {}, .Wrong
	}
	slot := u64(checked - 1)
	pkeys := principal_keys_held(slot)
	if pkeys == nil {
		return {}, .Wrong
	}
	for &entry in owned_key_cache {
		if entry.occupied && int(entry.store_index) == store_index && entry.slot == u8(slot) {
			owned_key_cache_tick += 1
			entry.used = owned_key_cache_tick
			return entry.keys, .Good
		}
	}
	// Cache miss: re-derive from principal_storage and verify Store_Block.
	owned_key_cache_misses += 1
	sb: format.Store_Block
	defer intrinsics.mem_zero_volatile(&sb, size_of(sb))
	sb_ptr := store_cell(store_index).store
	read_outcome := read_single_tagged(sb_ptr, (^Block)(&sb), store_index, checked)
	if read_outcome != .Good {
		return {}, read_outcome
	}
	if sb.owner != pkeys.identifier {
		return {}, .Wrong
	}
	derived, ok := store_encryption.store_keys_of(pkeys.storage_key, pkeys.identifier, sb.salt)
	defer intrinsics.mem_zero_volatile(&derived, size_of(derived))
	if !ok {
		return {}, .Wrong
	}
	if !store_encryption.store_block_verify(&derived, sb_ptr.block, sb_ptr.check, owned_min_generation[store_index], root.generation, &sb) {
		return {}, .Wrong
	}
	if sb.store_generation > owned_min_generation[store_index] {
		owned_min_generation[store_index] = sb.store_generation
	}
	owned_store_keys_put(store_index, slot, &derived)
	return derived, .Good
}

// store_crypto_save captures the current active encryption scope by value.
@(private = "file")
store_crypto_save :: proc "contextless" () -> (prev: Store_Crypto_Scope) {
	prev.store_index = active_store_index
	prev.owner_slot = active_store_owner_slot
	prev.was_encrypted = object_source.encrypted
	if active_store_keys != nil {
		prev.keys = active_store_keys_value
		prev.has_keys = true
	}
	return prev
}

// store_crypto_set_active installs keys by value into active_store_keys_value
// (or volatile-zeroes it when keys == nil).
store_crypto_set_active :: proc "contextless" (store_index: int, owner_slot: u8, keys: ^store_encryption.Store_Keys) {
	if keys != nil {
		active_store_keys_value = keys^
		active_store_keys = &active_store_keys_value
		object_source.encrypted = true
	} else {
		intrinsics.mem_zero_volatile(&active_store_keys_value, size_of(active_store_keys_value))
		active_store_keys = nil
		object_source.encrypted = false
	}
	active_store_index = store_index
	active_store_owner_slot = owner_slot
}

// store_crypto_enter activates encryption keys for store_index (or clear
// mode for a store of principal 0), returning the previous scope to restore
// with store_crypto_leave. On failure (.Device or .Wrong), active state is
// unchanged and prev is zeroed.
store_crypto_enter :: proc "contextless" (store_index: int) -> (prev: Store_Crypto_Scope, outcome: Read) {
	prev = store_crypto_save()
	if store_index < 0 || store_index >= store_numbers() || !owned_cell(store_index) {
		store_crypto_set_active(store_index, 0, nil)
		return prev, .Good
	}
	keys, read := owned_store_keys_get(store_index)
	defer intrinsics.mem_zero_volatile(&keys, size_of(keys))
	if read != .Good {
		intrinsics.mem_zero_volatile(&prev.keys, size_of(prev.keys))
		prev = {}
		return {}, read
	}
	store_crypto_set_active(store_index, owned_checked[store_index], &keys)
	return prev, .Good
}

// store_crypto_enter_keys activates explicit keys by value (for a plan or a
// newly created owned store whose cell is not yet committed to the store table).
store_crypto_enter_keys :: proc "contextless" (store_index: int, owner_slot: u8, keys: ^store_encryption.Store_Keys) -> (prev: Store_Crypto_Scope) {
	prev = store_crypto_save()
	store_crypto_set_active(store_index, owner_slot, keys)
	return prev
}

// store_crypto_leave restores a previously saved Store_Crypto_Scope and
// volatile-zeroes the saved key copy.
store_crypto_leave :: proc "contextless" (prev: ^Store_Crypto_Scope) {
	if prev.has_keys {
		store_crypto_set_active(prev.store_index, prev.owner_slot, &prev.keys)
	} else {
		store_crypto_set_active(prev.store_index, prev.owner_slot, nil)
	}
	object_source.encrypted = prev.was_encrypted
	intrinsics.mem_zero_volatile(&prev.keys, size_of(prev.keys))
	prev.has_keys = false
}

// owned_find gives the store of a name of a named principal: the cell with
// its tag, whose store block passes owner, key check, rollback floor,
// Store_Block MAC, and sealed-name verification. -1: the principal is locked,
// the store does not exist, or verification fails.
owned_find :: proc "contextless" (slot: u64, name: string) -> int {
	keys := principal_keys_held(slot)
	if keys == nil {
		return -1
	}
	field, ok := owned_tag(keys, name)
	if !ok {
		return -1
	}
	for index in 0 ..< store_numbers() {
		if !store_listed(index) || store_cell(index).name != field {
			continue
		}
		if owned_checked[index] == u8(slot + 1) || owned_store_check(index, slot, keys) {
			owned_checked[index] = u8(slot + 1)
			return index
		}
		system.log_fact(.Warning, Owned_Store_Refused{store = u64(index), slot = slot})
		return -1
	}
	return -1
}

// owned_store_check reads the store block of an owned store, and checks its
// owner, key check, rollback floor, 128-bit MAC, and sealed name against
// the keys held and the cell (owned_store_open).
owned_store_check :: proc "contextless" (index: int, slot: u64, keys: ^Principal_Storage) -> bool {
	buffer: [format.OWNER_FIELD_SIZE]u8
	defer intrinsics.mem_zero_volatile(&buffer, size_of(buffer))
	_, ok := owned_store_open(index, slot, keys, &buffer)
	return ok
}

// owned_store_open opens the name of an owned store into buffer, after
// verifying the Store_Block MAC, rollback floor, owner, key check, and
// sealed-name cell binding. On success, caches the verified Store_Keys and
// advances owned_min_generation. On refusal, buffer holds zeros.
owned_store_open :: proc "contextless" (index: int, slot: u64, keys: ^Principal_Storage, buffer: ^[format.OWNER_FIELD_SIZE]u8) -> (name: string, ok: bool) {
	buffer^ = {}
	if !owned_cell(index) {
		return "", false
	}
	sb: format.Store_Block
	defer intrinsics.mem_zero_volatile(&sb, size_of(sb))
	sb_ptr := store_cell(index).store
	if read_single_tagged(sb_ptr, (^Block)(&sb), index, 0) != .Good {
		return "", false
	}
	if sb.owner != keys.identifier {
		return "", false
	}
	derived, keys_ok := store_encryption.store_keys_of(keys.storage_key, keys.identifier, sb.salt)
	defer intrinsics.mem_zero_volatile(&derived, size_of(derived))
	if !keys_ok {
		return "", false
	}
	if !store_encryption.store_block_verify(&derived, sb_ptr.block, sb_ptr.check, owned_min_generation[index], root.generation, &sb) {
		return "", false
	}
	owner := format.store_owner_of(&sb)
	opened_name, name_ok := principal_keys.owner_open(keys, &owner, store_cell(index).name, buffer)
	if !name_ok {
		return "", false
	}
	if sb.store_generation > owned_min_generation[index] {
		owned_min_generation[index] = sb.store_generation
	}
	mark := u8(slot + 1)
	owned_checked[index] = mark
	cache_tag(sb_ptr, index, mark)
	owned_store_keys_put(index, slot, &derived)
	return opened_name, true
}

// owned_fields_read reads the owner fields of the store block of a store,
// distinguishing transient .Device failures from .Wrong.
owned_fields_read :: proc "contextless" (index: int) -> (owner: format.Store_Owner, outcome: Read) {
	block: Block
	defer intrinsics.mem_zero_volatile(&block, size_of(block))
	read := read_single_tagged(store_cell(index).store, &block, index, owned_checked[index])
	if read != .Good {
		return {}, read
	}
	return format.store_owner_of((^format.Store_Block)(&block)), .Good
}

// owned_make gives the owner fields, cell tag, and derived Store_Keys of a
// new store of a principal. ok is false with no keys, and with a weak seed.
owned_make :: proc "contextless" (slot: u64, name: string, error: ^errors.Error_Record) -> (owner: format.Store_Owner, field: [format.NAME_CAPACITY]u8, store_keys: store_encryption.Store_Keys, ok: bool) {
	keys := principal_keys_held(slot)
	if keys == nil || len(name) >= format.OWNER_FIELD_SIZE {
		return {}, {}, {}, false
	}
	field = owned_tag(keys, name) or_return
	salt: [format.OWNER_FIELD_SIZE]u8
	if !random.fill_for_a_key(&salt_generator, salt[:], .Processor, error) {
		return {}, {}, {}, false
	}
	owner = principal_keys.owner_seal(keys, name, salt) or_return
	store_keys = store_encryption.store_keys_of(keys.storage_key, keys.identifier, salt) or_return
	return owner, field, store_keys, true
}

// owned_name_into gives the name of an owned store, opened with the keys
// held, into buffer: "" when the principal is locked or the store is of
// another one.
owned_name_into :: proc "contextless" (index: int, slot: u64, buffer: ^[format.OWNER_FIELD_SIZE]u8) -> string {
	buffer^ = {}
	keys := principal_keys_held(slot)
	if keys == nil {
		return ""
	}
	name, _ := owned_store_open(index, slot, keys, buffer)
	return name
}

// erase_transient_buffers volatile-zeroes all static working buffers of the
// storage service that may have held decrypted plaintext from an unlocked
// principal.
erase_transient_buffers :: proc "contextless" () {
	store_crypto_set_active(-1, 0, nil)
	intrinsics.mem_zero_volatile(&plan.prev_crypto, size_of(plan.prev_crypto))
	intrinsics.mem_zero_volatile(&plan.store_block, size_of(plan.store_block))
	intrinsics.mem_zero_volatile(&plan.store_block_bytes, size_of(plan.store_block_bytes))
	intrinsics.mem_zero_volatile(&plan.store_keys, size_of(plan.store_keys))
	intrinsics.mem_zero_volatile(&plan.entries, size_of(plan.entries))
	intrinsics.mem_zero_volatile(&plan.trees, size_of(plan.trees))
	intrinsics.mem_zero_volatile(&plan.index_work, size_of(plan.index_work))
	intrinsics.mem_zero_volatile(&plan.index_blocks, size_of(plan.index_blocks))
	intrinsics.mem_zero_volatile(&plan.leaf_work, size_of(plan.leaf_work))
	intrinsics.mem_zero_volatile(&plan.release_nodes, size_of(plan.release_nodes))
	intrinsics.mem_zero_volatile(&plan.pool, size_of(plan.pool))
	intrinsics.mem_zero_volatile(&plan_store_name_bytes, size_of(plan_store_name_bytes))
	intrinsics.mem_zero_volatile(&reading_pool, size_of(reading_pool))
	intrinsics.mem_zero_volatile(&freeze_tree_pool, size_of(freeze_tree_pool))
	intrinsics.mem_zero_volatile(&freeze_work, size_of(freeze_work))
	intrinsics.mem_zero_volatile(&gc_state, size_of(gc_state))
	intrinsics.mem_zero_volatile(&gc_roots_copy, size_of(gc_roots_copy))
	intrinsics.mem_zero_volatile(&gc_stored_hashes, size_of(gc_stored_hashes))
	intrinsics.mem_zero_volatile(&gc_sweep_hashes, size_of(gc_sweep_hashes))
	intrinsics.mem_zero_volatile(&object_work, size_of(object_work))
	intrinsics.mem_zero_volatile(&object_node, size_of(object_node))
	intrinsics.mem_zero_volatile(&object_nodes, size_of(object_nodes))
	intrinsics.mem_zero_volatile(&object_hash_room, size_of(object_hash_room))
	intrinsics.mem_zero_volatile(&whole_blocks, size_of(whole_blocks))
	intrinsics.mem_zero_volatile(&compare_blocks, size_of(compare_blocks))
	intrinsics.mem_zero_volatile(&compaction, size_of(compaction))
	intrinsics.mem_zero_volatile(&read_room, size_of(read_room))
	intrinsics.mem_zero_volatile(&immutable_tree_scratch, size_of(immutable_tree_scratch))
	intrinsics.mem_zero_volatile(&listed, size_of(listed))
	intrinsics.mem_zero_volatile(&oldest, size_of(oldest))
	intrinsics.mem_zero_volatile(&oldest_walks, size_of(oldest_walks))
	intrinsics.mem_zero_volatile(&added_rows, size_of(added_rows))
	intrinsics.mem_zero_volatile(&added_names, size_of(added_names))
	intrinsics.mem_zero_volatile(&removal_names, size_of(removal_names))
	intrinsics.mem_zero_volatile(&removal_values, size_of(removal_values))
	intrinsics.mem_zero_volatile(&plan_fixed.release_lists, size_of(plan_fixed.release_lists))
	intrinsics.mem_zero_volatile(&plan_fixed.step_list, size_of(plan_fixed.step_list))
	if region != nil {
		intrinsics.mem_zero_volatile(region, REGION_BLOCKS * BLOCK_SIZE)
	}
}

// owned_checks_clear runs on lock or key/identity replacement for a slot:
// evicts only block_cache entries of that slot's stores (never other
// principals), removes their hash-index records, erases cached Store_Keys,
// drops their pending pools, and erases transient plaintext buffers.
owned_checks_clear :: proc "contextless" (slot: u64) {
	mark := u8(slot + 1)
	// Evict only block_cache entries tagged to this slot or its verified stores.
	for &entry in block_cache {
		if entry.number == 0 {
			continue
		}
		if entry.owner_slot == mark || (entry.store_index >= 0 && int(entry.store_index) < format.STORE_CAPACITY && owned_checked[entry.store_index] == mark) {
			intrinsics.mem_zero_volatile(&entry, size_of(Cached_Block))
		}
	}
	for &checked, index in owned_checked {
		if checked == mark {
			storage_mount.hash_index_clear_store(&opened, index)
			checked = 0
		}
	}
	for &entry in owned_key_cache {
		if entry.occupied && entry.slot == u8(slot) {
			intrinsics.mem_zero_volatile(&entry, size_of(Owned_Key_Cache_Entry))
		}
	}
	pending_drop_slot(slot)
	erase_transient_buffers()
}
