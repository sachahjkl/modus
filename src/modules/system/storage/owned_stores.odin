package storage_service

import principal_keys "internal:storage/principal_keys"
import "modus:contract/errors"
import format "modus:contract/store"
import "modus:principals"
import "modus:random"
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
	return principal_keys.cell_field(keys, name)
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
// owner, its key check and its sealed name against the keys held and the
// cell (owned_store_open).
owned_store_check :: proc "contextless" (index: int, keys: ^Principal_Storage) -> bool {
	buffer: [format.OWNER_FIELD_SIZE]u8
	_, ok := owned_store_open(index, keys, &buffer)
	return ok
}

// owned_store_open opens the name of an owned store into buffer, after it
// checked the store block against the keys held: its owner, its key check,
// and the tag of the opened name, which must be the tag of the cell. So a
// cell that a writer of the disk pointed at another store block of the same
// principal, whose owner and key check pass, is refused: each cell is bound
// to its store block by its name. On a refusal, buffer holds zeros.
owned_store_open :: proc "contextless" (index: int, keys: ^Principal_Storage, buffer: ^[format.OWNER_FIELD_SIZE]u8) -> (name: string, ok: bool) {
	buffer^ = {}
	if !owned_cell(index) {
		return "", false
	}
	owner, read := owned_fields_read(index)
	if !read {
		return "", false
	}
	return principal_keys.owner_open(keys, &owner, store_cell(index).name, buffer)
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
	salt: [format.OWNER_FIELD_SIZE]u8
	if !random.fill_for_a_key(&salt_generator, salt[:], .Processor, error) {
		return {}, {}, false
	}
	owner = principal_keys.owner_seal(keys, name, salt) or_return
	return owner, field, true
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
	name, _ := owned_store_open(index, keys, buffer)
	return name
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
