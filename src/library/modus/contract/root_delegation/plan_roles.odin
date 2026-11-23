// Contract of the roles of a plan between the holder of the role Plans and
// the root service core (src/md/features/declarations.md, "Apply, the
// difference and the rollback"; src/md/api/root_service_split.md).
//
// The holder of Plans computes the difference of a plan and asks the
// principal on the trusted display. It does not give roles: the core does.
// When the principal accepted, the holder writes the whole set of the role
// overrides of the plan in the roles page that the core lent it, and sends
// the command Plan_Roles of the root ring. The core checks the whole set at
// this border, then replaces its overrides in one step: a set that one
// override refuses changes nothing. A rollback is a set of the generation
// that it goes back to, with the same check and the same one step.
package root_delegation

import "modus:contract/blake3"
import "modus:contract/enum_word"
import op "modus:contract/operation"
import "modus:contract/role_contract"

// The most role overrides of one set: one for each role that a plan can
// give, with room left.
PLAN_ROLES_OVERRIDE_CAPACITY :: 24

// The roles page: one page that the core makes once and lends to the
// holder of Plans with Read and Write.
PLAN_ROLES_PAGE_BYTES :: op.PAGE_SIZE

#assert(size_of(Plan_Roles_Set) <= PLAN_ROLES_PAGE_BYTES)
#assert(len(role_contract.Role) <= PLAN_ROLES_OVERRIDE_CAPACITY)

// values[0] of a command Plan_Roles: what it asks.
Plan_Roles_Step :: enum u64 {
	None     = 0, // Refused.
	Page     = 1, // Give the roles page and the serial of the set in force.
	Apply    = 2, // Replace the overrides with the set of the page: a new generation.
	Rollback = 3, // Replace the overrides with the set of the page: an earlier generation.
	// The holder read the current plan of principal 0 at its start and gave
	// its roles, or found none: values[1] is a Plan_Roles_Load_Outcome. At
	// the start of the machine, the core waits for it before the start
	// policy.
	Loaded   = 4,
}

// values[1] of a Plan_Roles with the step Loaded: what the holder of Plans
// found at its start. With each outcome but Applied, the roles of the boot
// image hold.
Plan_Roles_Load_Outcome :: enum u64 {
	None         = 0, // Refused.
	No_Plan      = 1, // Principal 0 has no current plan in the store.
	Applied      = 2, // The core holds the roles of the current plan of principal 0.
	// The core refused the content of the roles of the current plan (a
	// module that the boot image lacks, a contract that it does not fill):
	// the roles of the image hold until the next apply or rollback.
	Plan_Refused = 3,
	Store_Unread = 4, // The store failed, or holds a damaged plan.
	Core_Unread  = 5, // No roles page, or no answer of the core.
}

// plan_roles_load_outcome_of_word is the border of values[1] of a
// Plan_Roles with the step Loaded: None and a word that names no member are
// refused.
plan_roles_load_outcome_of_word :: proc "contextless" (word: u64) -> (outcome: Plan_Roles_Load_Outcome, ok: bool) {
	member, known := enum_word.member_of_word(Plan_Roles_Load_Outcome, word)
	if !known || member == .None {
		return .None, false
	}
	return member, true
}

// plan_roles_refusal_of_content says if a refusal names the content of the
// set: the same set is refused again on each send, so the holder falls back
// to the roles of the image instead of a retry. Stale_Serial names the
// order of the sets, and Grants_Busy the room of a service ring: a read of
// the core and a new send can pass.
plan_roles_refusal_of_content :: proc "contextless" (refusal: Plan_Roles_Refusal) -> bool {
	switch refusal {
	case .None, .Stale_Serial, .Grants_Busy:
		return false
	case .Not_Machine, .Too_Many_Overrides, .Unknown_Role, .Role_Not_Replaceable, .Zero_Module_Hash, .Duplicate_Role, .Zero_Generation, .Not_In_Image, .Contract_Not_Filled, .Bytes_After_Set:
		return true
	}
	return false
}

// One role of a plan: the role and the hash of the module of the boot
// image that holds it.
Plan_Role_Override :: struct {
	role_word:   u64,
	module_hash: blake3.Hash,
}

// The whole set of the role overrides of one generation of the plan of
// principal 0, as the holder of Plans writes it in the roles page.
// expected_serial is the serial of the set in force that the holder read:
// the core refuses a set that does not follow the set in force, so a set
// written before another one never replaces it.
Plan_Roles_Set :: struct {
	principal:       u64,
	generation:      u64,
	expected_serial: u64,
	override_count:  u64,
	overrides:       [PLAN_ROLES_OVERRIDE_CAPACITY]Plan_Role_Override,
}

// Why the core refused a set. A refusal changes no override.
Plan_Roles_Refusal :: enum u8 {
	None                 = 0,
	Not_Machine          = 1, // The set is not of principal 0: the roles of the machine come from its plan only.
	Too_Many_Overrides   = 2, // override_count is past PLAN_ROLES_OVERRIDE_CAPACITY.
	Unknown_Role         = 3, // A role word names no role, or None.
	Role_Not_Replaceable = 4, // A role that the core starts in its own way before any plan.
	Zero_Module_Hash     = 5,
	Duplicate_Role       = 6, // Two overrides name one role.
	Stale_Serial         = 7, // The set does not follow the set in force.
	Zero_Generation      = 8, // An apply names no generation.
	Not_In_Image         = 9, // The hash names no module of the boot image.
	Contract_Not_Filled  = 10, // The module does not fill the contract of the role.
	Bytes_After_Set      = 11, // An override after override_count is not zero bytes.
	// A service ring has no room for the new grants of the connections that
	// the set changes: nothing changed, and a later send can pass.
	Grants_Busy          = 12,
}

// plan_roles_step_of_word is the border of values[0] of a Plan_Roles: None
// and a word that names no member are refused.
plan_roles_step_of_word :: proc "contextless" (word: u64) -> (step: Plan_Roles_Step, ok: bool) {
	member, known := enum_word.member_of_word(Plan_Roles_Step, word)
	if !known || member == .None {
		return .None, false
	}
	return member, true
}

// plan_role_replaceable says if a plan can name the holder of a role. The
// core starts the device services with the layout of a device, the start
// policy by its own choice, and the delegated services of the start before
// it reads any plan: a plan names none of them.
plan_role_replaceable :: proc "contextless" (role: role_contract.Role) -> bool {
	switch role {
	case .None, .Start_Policy, .Block_Device, .Network_Device, .Sound_Device, .Entropy_Device, .Tpm, .Principals, .Devices:
		return false
	case .Display, .Input, .Console, .Assistive, .Speech, .Terminal, .Storage, .Network, .Remote_Display, .Plans, .Projects, .Recipes, .Powerbox, .Disk_Processes, .Settings:
		return true
	}
	return false
}

// plan_roles_set_check is the border of a set that the core copied out of
// the roles page. It reads the set only, and gives the first refusal with
// the index of its override. The core then resolves each hash and checks
// each contract (role_policy.holder_overrides_replace).
plan_roles_set_check :: proc "contextless" (set: ^Plan_Roles_Set, step: Plan_Roles_Step, serial_in_force: u64) -> (refusal: Plan_Roles_Refusal, index: int) {
	if set.principal != 0 {
		return .Not_Machine, 0
	}
	if set.expected_serial != serial_in_force {
		return .Stale_Serial, 0
	}
	if step == .Apply && set.generation == 0 {
		return .Zero_Generation, 0
	}
	if set.override_count > PLAN_ROLES_OVERRIDE_CAPACITY {
		return .Too_Many_Overrides, 0
	}
	count := int(set.override_count)
	seen: [role_contract.Role]bool
	for &override, place in set.overrides[:count] {
		role, known := role_contract.role_from_word(override.role_word)
		if !known || role == .None {
			return .Unknown_Role, place
		}
		if !plan_role_replaceable(role) {
			return .Role_Not_Replaceable, place
		}
		if override.module_hash == {} {
			return .Zero_Module_Hash, place
		}
		if seen[role] {
			return .Duplicate_Role, place
		}
		seen[role] = true
	}
	for &override, place in set.overrides[count:] {
		if override != {} {
			return .Bytes_After_Set, count + place
		}
	}
	return .None, 0
}
