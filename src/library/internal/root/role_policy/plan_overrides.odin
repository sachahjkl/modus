package role_policy

// The overrides of the roles that the plan of principal 0 gives
// (src/md/features/declarations.md, "Apply, the difference and the
// rollback"). The holder of Plans sends the whole set of the overrides of
// one generation; the core checks each override, then replaces the whole
// set in one step. A set that one override refuses changes nothing, so the
// core never runs with half of a plan.

import "modus:contract/blake3"
import "modus:contract/role_contract"
import rd "modus:contract/root_delegation"

// The bytes of the name of a module of the boot image, with zero bytes
// after the name.
HOLDER_NAME_BYTES :: 32

// The bytes behind the overrides of Holder_Names: a name of the table is
// a slice of these bytes, so a set replaces both together.
Override_Names :: struct {
	bytes:      [role_contract.Role][HOLDER_NAME_BYTES]u8,
	lengths:    [role_contract.Role]u8,
	// The count of the sets that replaced the overrides since the start:
	// each set names the serial that it follows.
	serial:     u64,
	// The generation of the plan of the set in force, 0 for the defaults of
	// the image.
	generation: u64,
}

// What the core knows of the boot image: the module that a hash names, and
// whether a module fills the contract of a role. A host test gives its own.
Holder_Resolver :: struct {
	user:         rawptr,
	name_of_hash: proc "contextless" (user: rawptr, hash: blake3.Hash) -> (name: string, found: bool),
	fills:        proc "contextless" (user: rawptr, role: role_contract.Role, module_name: string) -> bool,
}

// holder_overrides_replace checks a whole set of overrides and replaces the
// overrides of names with it, in one step. On a refusal, names and kept do
// not change. A rollback is a set like another: the set of the generation
// that it goes back to.
holder_overrides_replace :: proc "contextless" (
	names: ^Holder_Names,
	kept: ^Override_Names,
	set: ^rd.Plan_Roles_Set,
	step: rd.Plan_Roles_Step,
	resolver: Holder_Resolver,
) -> (refusal: rd.Plan_Roles_Refusal, index: int) {
	if refusal, index = rd.plan_roles_set_check(set, step, kept.serial); refusal != .None {
		return refusal, index
	}
	if resolver.name_of_hash == nil || resolver.fills == nil {
		return .Not_In_Image, 0
	}
	staged: Override_Names
	for &override, place in set.overrides[:set.override_count] {
		// The border checked the word: it names a role.
		role, _ := role_contract.role_from_word(override.role_word)
		name, found := resolver.name_of_hash(resolver.user, override.module_hash)
		if !found || len(name) == 0 || len(name) >= HOLDER_NAME_BYTES {
			return .Not_In_Image, place
		}
		if !resolver.fills(resolver.user, role, name) {
			return .Contract_Not_Filled, place
		}
		staged.lengths[role] = u8(copy(staged.bytes[role][:], name))
	}
	staged.serial = kept.serial + 1
	staged.generation = set.generation
	kept^ = staged
	for role in role_contract.Role {
		length := kept.lengths[role]
		names.overrides[role] = length == 0 ? "" : string(kept.bytes[role][:length])
	}
	return .None, 0
}
