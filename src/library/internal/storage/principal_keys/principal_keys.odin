// The keys of each named principal whose session runs, in the memory of
// the storage service only (src/md/features/store_encryption.md, "The
// keys"). The root service sends them at the unlock, on the service ring
// that it alone writes, and tells the lock; no disk keeps them.
//
// No allocator and no kernel operation: the storage service and the host
// tests call the same procedures.
package principal_keys

import "base:intrinsics"
import "modus:contract/isolated"
import format "modus:contract/store"
import "modus:principals"
import "internal:storage/store_encryption"

Principal_Storage :: struct {
	identity_set: bool,
	key_set:      bool,
	identifier:   principals.Principal_Identifier,
	storage_key:  store_encryption.Key,
	name_key:     store_encryption.Key,
}

// By the slot of the principal in this run; slot 0, the machine, has no
// keys: its stores stay in clear.
Table :: [principals.PRINCIPAL_CAPACITY]Principal_Storage

// What a command did.
Outcome :: enum u8 {
	Refused, // A slot that names no named principal, a word after the slot, zero bytes, a key with no identity before it, a second key while one is held, or no command of the keys: no key changed.
	Identity_Taken, // The identity of the slot; the keys of another principal in the slot went.
	Key_Taken, // The storage key, after the identity of the slot.
	Erased, // The lock: each byte of the slot is zero.
}

// erase erases the keys of a slot.
erase :: proc "contextless" (table: ^Table, slot: int) {
	intrinsics.mem_zero_volatile(&table[slot], size_of(Principal_Storage))
}

// take takes a command of the keys of a principal from the root service:
// its identity, then its storage key, and its lock. other_identity says
// that an identity replaced the identity of another principal in the slot.
// It erases the words of the command, whatever it does with them.
take :: proc "contextless" (table: ^Table, command: isolated.Service_Command, values: ^[7]u64) -> (outcome: Outcome, other_identity: bool) {
	defer intrinsics.mem_zero_volatile(values, size_of(values^))
	slot := values[4]
	if slot == principals.MACHINE || slot >= principals.PRINCIPAL_CAPACITY || values[5] != 0 || values[6] != 0 {
		return .Refused, false
	}
	held := &table[slot]
	words := [4]u64{values[0], values[1], values[2], values[3]}
	defer intrinsics.mem_zero_volatile(&words, size_of(words))
	bytes := transmute([32]u8)words
	defer intrinsics.mem_zero_volatile(&bytes, size_of(bytes))
	switch command {
	case .Principal_Identity:
		if principals.identifier_is_zero(bytes[:]) {
			return .Refused, false
		}
		if held.identity_set && held.identifier != principals.Principal_Identifier(bytes) {
			erase(table, int(slot))
			other_identity = true
		}
		held.identity_set = true
		held.identifier = principals.Principal_Identifier(bytes)
		return .Identity_Taken, other_identity
	case .Principal_Storage_Key:
		name_key, ok := store_encryption.name_key_of(store_encryption.Key(bytes))
		defer intrinsics.mem_zero_volatile(&name_key, size_of(name_key))
		// A second key while one is held: the stores that the service
		// checked with the first would stay open under a key that changed.
		// The lock comes first.
		if !held.identity_set || held.key_set || !ok {
			return .Refused, false
		}
		held.storage_key = store_encryption.Key(bytes)
		held.name_key = name_key
		held.key_set = true
		return .Key_Taken, false
	case .Principal_Locked:
		erase(table, int(slot))
		return .Erased, false
	case .None, .Connect, .Disconnect, .Grant, .Principal_Reclaim:
	}
	return .Refused, false
}

// reclaim_identifier_check validates a Principal_Reclaim command from the root
// service: slot must name a named principal, values[5..6] must be 0, the
// 256-bit identifier in values[0..3] must be non-zero, and no slot may hold an
// active unlocked storage key for that identifier.
reclaim_identifier_check :: proc "contextless" (table: ^Table, values: [7]u64) -> (identifier: principals.Principal_Identifier, ok: bool) {
	slot := values[4]
	if slot == principals.MACHINE || slot >= principals.PRINCIPAL_CAPACITY || values[5] != 0 || values[6] != 0 {
		return {}, false
	}
	words := [4]u64{values[0], values[1], values[2], values[3]}
	bytes := transmute([32]u8)words
	if principals.identifier_is_zero(bytes[:]) {
		return {}, false
	}
	id := principals.Principal_Identifier(bytes)
	for entry in table^ {
		if entry.key_set && entry.identifier == id {
			return {}, false
		}
	}
	return id, true
}

// held gives the keys of a slot whose session runs, or nil.
held :: proc "contextless" (table: ^Table, slot: u64) -> ^Principal_Storage {
	if slot == principals.MACHINE || slot >= principals.PRINCIPAL_CAPACITY || !table[slot].key_set {
		return nil
	}
	return &table[slot]
}

// cell_field gives the field of the cell of a store of a principal: the
// mark, then the first 31 bytes of the name tag. ok is false for a name
// that no tag takes.
cell_field :: proc "contextless" (keys: ^Principal_Storage, name: string) -> (field: [format.NAME_CAPACITY]u8, ok: bool) {
	tag := store_encryption.name_tag(keys.name_key, name) or_return
	field[0] = format.OWNED_CELL_MARK
	copy(field[1:], tag[:format.NAME_CAPACITY - 1])
	return field, true
}

// owner_seal gives the owner fields of a new store of a principal, from a
// salt that the caller drew: its identifier, the key check, and the name
// sealed under the key of the store. ok is false for a name too long for
// its field and for a salt that gives no key.
owner_seal :: proc "contextless" (keys: ^Principal_Storage, name: string, salt: [format.OWNER_FIELD_SIZE]u8) -> (owner: format.Store_Owner, ok: bool) {
	if len(name) == 0 || len(name) >= format.OWNER_FIELD_SIZE {
		return {}, false
	}
	store_keys := store_encryption.store_keys_of(keys.storage_key, keys.identifier, salt) or_return
	defer intrinsics.mem_zero_volatile(&store_keys, size_of(store_keys))
	owner.owner = keys.identifier
	owner.salt = salt
	owner.key_check = store_keys.check
	copy(owner.name_sealed[:], name)
	// The nonce of the block 0 and the check 0 is used by this one write
	// under the key of the store: no block of a store is block 0.
	nonce := store_encryption.block_nonce(&store_keys, 0, 0)
	store_encryption.xchacha20(&store_keys.cipher, &nonce, owner.name_sealed[:])
	return owner, true
}

// owner_open opens the name of an owned store into buffer, after it checked
// the owner fields of its store block against the keys held: its owner, its
// key check, and the tag of the opened name, which must be the field of its
// cell. So a cell that a writer of the disk pointed at another store block
// of the same principal, whose owner and key check pass, is refused: each
// cell is bound to its store block by its name. On a refusal, buffer holds
// zeros.
owner_open :: proc "contextless" (keys: ^Principal_Storage, owner: ^format.Store_Owner, cell: [format.NAME_CAPACITY]u8, buffer: ^[format.OWNER_FIELD_SIZE]u8) -> (name: string, ok: bool) {
	buffer^ = {}
	if cell[0] != format.OWNED_CELL_MARK || owner.owner != keys.identifier {
		return "", false
	}
	store_keys, keys_ok := store_encryption.store_keys_of(keys.storage_key, keys.identifier, owner.salt)
	defer intrinsics.mem_zero_volatile(&store_keys, size_of(store_keys))
	if !keys_ok || !store_encryption.key_check_matches(&store_keys, owner.key_check) {
		return "", false
	}
	buffer^ = owner.name_sealed
	nonce := store_encryption.block_nonce(&store_keys, 0, 0)
	store_encryption.xchacha20(&store_keys.cipher, &nonce, buffer[:])
	length := 0
	for length < len(buffer) && buffer[length] != 0 {
		length += 1
	}
	// The bytes after the name are zeros, as owner_seal wrote them.
	for rest in buffer[length:] {
		if rest != 0 {
			buffer^ = {}
			return "", false
		}
	}
	name = string(buffer[:length])
	field, tag_ok := cell_field(keys, name)
	if length == 0 || !tag_ok || field != cell {
		buffer^ = {}
		return "", false
	}
	return name, true
}
