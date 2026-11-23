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
import "modus:principals"
import "modus:store_encryption"

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
	Refused, // A slot that names no named principal, a word after the slot, zero bytes, a key with no identity before it, or no command of the keys: no key changed.
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
take :: proc "contextless" (table: ^Table, command: isolated.Service_Command, values: [7]u64) -> (outcome: Outcome, other_identity: bool) {
	slot := values[4]
	if slot == principals.MACHINE || slot >= principals.PRINCIPAL_CAPACITY || values[5] != 0 || values[6] != 0 {
		return .Refused, false
	}
	held := &table[slot]
	words := [4]u64{values[0], values[1], values[2], values[3]}
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
		if !held.identity_set || !ok {
			return .Refused, false
		}
		held.storage_key = store_encryption.Key(bytes)
		held.name_key = name_key
		held.key_set = true
		return .Key_Taken, false
	case .Principal_Locked:
		erase(table, int(slot))
		return .Erased, false
	case .None, .Connect, .Disconnect, .Grant:
	}
	return .Refused, false
}

// held gives the keys of a slot whose session runs, or nil.
held :: proc "contextless" (table: ^Table, slot: u64) -> ^Principal_Storage {
	if slot == principals.MACHINE || slot >= principals.PRINCIPAL_CAPACITY || !table[slot].key_set {
		return nil
	}
	return &table[slot]
}
