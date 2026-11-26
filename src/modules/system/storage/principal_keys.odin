package storage_service

import keys "internal:storage/principal_keys"
import "modus:contract/isolated"
import "modus:system"

// The keys of each named principal whose session runs, in the memory of
// this service only (internal:storage/principal_keys).

Principal_Storage :: keys.Principal_Storage
principal_storage: keys.Table

// storage_principal_keys takes a command of the keys of a principal from
// the root service, and says each refusal: no key of another slot changes.
storage_principal_keys :: proc "contextless" (_: ^system.Service, command: isolated.Service_Command, values: ^[7]u64) {
	slot := values[4]
	outcome, other_identity := keys.take(&principal_storage, command, values)
	switch outcome {
	case .Refused:
		system.log_fact(.Warning, Principal_Keys_Refused{slot = slot, command_code = u64(command)})
	case .Identity_Taken:
		if other_identity {
			owned_checks_clear(slot) // owned_stores.odin
		}
	case .Key_Taken:
		// The stores checked under no key or a key of before are checked
		// again under this one.
		owned_checks_clear(slot)
		system.log_fact(.Info, Principal_Keys_Taken{slot = slot})
	case .Erased:
		owned_checks_clear(slot)
		storage_object_purge_principal(slot, clear_pins = false)
		system.log_fact(.Info, Principal_Keys_Erased{slot = slot})
	}
}

// principal_keys_held gives the keys of a slot whose session runs, or nil.
principal_keys_held :: proc "contextless" (slot: u64) -> ^Principal_Storage {
	return keys.held(&principal_storage, slot)
}
