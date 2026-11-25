// Canonical measurement of principal 0's active role-holder set in the root
// service (src/md/features/attestation.md).
//
// Walks the closed Role enum, resolves each active holder name through the
// central role_holder_names table, verifies its boot-image entry hash through
// image_entry_give, and computes the order-invariant BLAKE3 digest via
// modus:contract/attestation.
package root

import "modus:contract/attestation"
import "modus:contract/blake3"
import "modus:contract/role_contract"
import "modus:system"

#assert(len(role_contract.Role) <= attestation.ROLE_HOLDER_CAPACITY)

// image_module_hash_checked returns the verified BLAKE3 hash of module name
// in the boot image. present is false when the boot image omits the module;
// valid is false when the module is present but fails its hash check.
@(private = "file")
image_module_hash_checked :: proc "contextless" (name: string) -> (hash: blake3.Hash, present: bool, valid: bool) {
	for &entry in system.image_entries(image) {
		if system.name_of(entry.name[:]) != name {
			continue
		}
		if !image_entry_give(&entry) {
			return {}, true, false
		}
		return entry.hash, true, true
	}
	return {}, false, true
}

// root_role_holders_measure computes the canonical BLAKE3 measurement of
// principal 0's active role-holder set from verified boot-image entries.
// Optional default roles absent from a minimal boot image are skipped; a
// present module that fails hash verification causes immediate refusal.
root_role_holders_measure :: proc "contextless" () -> (digest: blake3.Hash, holder_count: int, ok: bool) {
	holders: [attestation.ROLE_HOLDER_CAPACITY]attestation.Measured_Role_Holder
	count := 0
	for role in role_contract.Role {
		if role == .None {
			continue
		}
		name := role_holder_name(role)
		if len(name) == 0 {
			continue
		}
		module_hash, present, valid := image_module_hash_checked(name)
		if !valid {
			return {}, 0, false
		}
		if !present {
			continue
		}
		if count >= len(holders) {
			return {}, 0, false
		}
		holders[count] = {
			role_word   = u64(role),
			module_name = name,
			module_hash = module_hash,
		}
		count += 1
	}
	measured, measured_ok := attestation.measure_role_holders(holders[:count])
	if !measured_ok {
		return {}, 0, false
	}
	return measured, count, true
}
