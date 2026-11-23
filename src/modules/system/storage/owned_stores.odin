package storage_service

import "base:intrinsics"
import "modus:contract/errors"
import format "modus:contract/store"
import "modus:principals"
import "modus:random"
import "modus:store_encryption"
import "modus:system"

// The stores of a named principal (src/md/features/store_encryption.md).
// Their cell keeps the name tag of their name, with OWNED_CELL_MARK as its
// first byte, and their store block keeps the owner, the salt, the key
// check and the sealed name, in clear. A store of a named principal is
// found, made and opened only with the keys of that principal, which the
// root service gives at its unlock (principal_keys.odin): a locked
// principal has no store that this service finds.

// The generator of the salts of new stores: its stream starts with the key
// of the slots of the hash index (entry). A salt is public; its one duty is
// to never come two times.
salt_generator: random.Generator

// For each store whose owner and key check matched the keys held: the slot
// plus 1. Cleared for a slot at its lock, so a new principal in the slot
// checks again.
owned_checked: [format.STORE_CAPACITY]u8

// owned_cell says if the cell of a store keeps a name tag.
owned_cell :: proc "contextless" (index: int) -> bool {
	return store_cell(index).name[0] == format.OWNED_CELL_MARK
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
	tag := store_encryption.name_tag(keys.name_key, name) or_return
	field[0] = format.OWNED_CELL_MARK
	copy(field[1:], tag[:format.NAME_CAPACITY - 1])
	return field, true
}

// owned_find gives the store of a name of a named principal: the cell with
// its tag, whose store block names the owner and the key check of the keys
// held. -1: the principal is locked, the store does not exist, or its
// owner or its key check is another one.
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
		if owned_checked[index] == u8(slot + 1) || owned_store_check(index, keys) {
			owned_checked[index] = u8(slot + 1)
			return index
		}
		system.log_fact(.Warning, Owned_Store_Refused{store = u64(index), slot = slot})
		return -1
	}
	return -1
}

// owned_store_check reads the store block of an owned store, and checks its
// owner and its key check against the keys held.
owned_store_check :: proc "contextless" (index: int, keys: ^Principal_Storage) -> bool {
	owner, read := owned_fields_read(index)
	if !read || owner.owner != keys.identifier {
		return false
	}
	store_keys, ok := store_encryption.store_keys_of(keys.storage_key, keys.identifier, owner.salt)
	defer intrinsics.mem_zero_volatile(&store_keys, size_of(store_keys))
	return ok && store_encryption.key_check_matches(&store_keys, owner.key_check)
}

// owned_fields_read reads the owner fields of the store block of a store.
owned_fields_read :: proc "contextless" (index: int) -> (owner: format.Store_Owner, ok: bool) {
	block: Block
	if read_single(store_cell(index).store, &block) != .Good {
		return {}, false
	}
	return format.store_owner_of((^format.Store_Block)(&block)), true
}

// owned_make gives the owner fields of a new store of a principal: its
// identifier, a new salt, the key check and the sealed name. ok is false
// with no keys, and with a weak seed.
owned_make :: proc "contextless" (slot: u64, name: string, error: ^errors.Error_Record) -> (owner: format.Store_Owner, field: [format.NAME_CAPACITY]u8, ok: bool) {
	keys := principal_keys_held(slot)
	if keys == nil || len(name) >= format.OWNER_FIELD_SIZE {
		return {}, {}, false
	}
	field = owned_tag(keys, name) or_return
	if !random.fill_for_a_key(&salt_generator, owner.salt[:], .Processor, error) {
		return {}, {}, false
	}
	store_keys := store_encryption.store_keys_of(keys.storage_key, keys.identifier, owner.salt) or_return
	defer intrinsics.mem_zero_volatile(&store_keys, size_of(store_keys))
	owner.owner = keys.identifier
	owner.key_check = store_keys.check
	copy(owner.name_sealed[:], name)
	// The nonce of the block 0 and the check 0 is used by this one write
	// under the key of the store: no block of a store is block 0.
	nonce := store_encryption.block_nonce(&store_keys, 0, 0)
	store_encryption.xchacha20(&store_keys.cipher, &nonce, owner.name_sealed[:])
	return owner, field, true
}

// owned_name_into gives the name of an owned store, opened with the keys
// held, into buffer: "" when the principal is locked or the store is of
// another one.
owned_name_into :: proc "contextless" (index: int, slot: u64, buffer: ^[format.OWNER_FIELD_SIZE]u8) -> string {
	keys := principal_keys_held(slot)
	if keys == nil || !owned_cell(index) {
		return ""
	}
	owner, read := owned_fields_read(index)
	if !read || owner.owner != keys.identifier {
		return ""
	}
	store_keys, ok := store_encryption.store_keys_of(keys.storage_key, keys.identifier, owner.salt)
	defer intrinsics.mem_zero_volatile(&store_keys, size_of(store_keys))
	if !ok || !store_encryption.key_check_matches(&store_keys, owner.key_check) {
		return ""
	}
	buffer^ = owner.name_sealed
	nonce := store_encryption.block_nonce(&store_keys, 0, 0)
	store_encryption.xchacha20(&store_keys.cipher, &nonce, buffer[:])
	return system.name_of(buffer[:])
}

// owned_checks_clear forgets the checks of the stores of a slot: its keys
// were erased.
owned_checks_clear :: proc "contextless" (slot: u64) {
	for &checked in owned_checked {
		if checked == u8(slot + 1) {
			checked = 0
		}
	}
}
