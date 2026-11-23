package root

// Role holder registry and plan-bound local service resolution for the root
// service (src/md/features/roles_and_contracts.md).
//
// Delegates pure policy decisions to internal:root/role_policy so every
// scope rule, trusted-path check, contract check, and local-name isolation rule
// is verified by host tests.

import "modus:contract/role_contract"
import "internal:root/role_policy"

// The active role holder and local service binding table of this root service.
// Zero-initialized empty state.
root_role_registry: role_policy.Role_Registry

// role_registry_slot_number maps a Started pointer in the started table to its
// 1-based process slot number. Returns 0 when item is nil or outside started.
role_registry_slot_number :: proc "contextless" (item: ^Started) -> u32 {
	if item == nil {
		return 0
	}
	if len(started) == 0 {
		return 0
	}
	base := uintptr(&started[0])
	address := uintptr(item)
	if address < base {
		return 0
	}
	offset := address - base
	if offset % size_of(Started) != 0 {
		return 0
	}
	index := offset / size_of(Started)
	if index >= uintptr(len(started)) {
		return 0
	}
	return u32(index + 1)
}

// role_registry_rescue_mode_set records whether the root service is running in
// rescue mode, where only boot-image role holders are allowed.
role_registry_rescue_mode_set :: proc "contextless" (active: bool) {
	root_role_registry.rescue_mode = active
}

// role_registry_bind verifies and binds a started process as the holder of a
// role in a scope. On any refusal, the registry is unchanged.
role_registry_bind :: proc "contextless" (
	holder: ^Started,
	role: role_contract.Role,
	scope: role_policy.Scope_Key,
	origin: role_policy.Holder_Origin,
	chosen_by_principal: u64,
	module_bytes: []u8,
	declaration: role_contract.Module_Role_Declaration,
	contract: role_contract.Role_Contract,
	interposed_below: ^Started = nil,
) -> role_policy.Bind_Result {
	slot_number := role_registry_slot_number(holder)
	if slot_number == 0 {
		return {refusal = .Zero_Process_Slot, holder_index = -1}
	}
	request := role_policy.Bind_Request {
		role                  = role,
		scope                 = scope,
		module_hash           = holder.hash,
		origin                = origin,
		chosen_by_principal   = chosen_by_principal,
		process_slot          = slot_number,
		interposed_below_slot = role_registry_slot_number(interposed_below),
		module_bytes          = module_bytes,
		declaration           = declaration,
		contract              = contract,
	}
	return role_policy.bind_holder(&root_role_registry, request)
}

// role_registry_holder returns the active Started process holding role in
// scope, if any.
role_registry_holder :: proc "contextless" (role: role_contract.Role, scope: role_policy.Scope_Key) -> (holder: ^Started, entry: role_policy.Role_Holder, found: bool) {
	entry, found = role_policy.holder_find(&root_role_registry, role, scope)
	if !found || entry.process_slot == 0 || int(entry.process_slot) > len(started) {
		return nil, {}, false
	}
	return &started[entry.process_slot - 1], entry, true
}

// role_registry_release_process clears every role holding and local service
// binding owned by a stopped process.
role_registry_release_process :: proc "contextless" (item: ^Started) -> int {
	slot_number := role_registry_slot_number(item)
	if slot_number == 0 {
		return 0
	}
	return role_policy.unbind_process(&root_role_registry, slot_number)
}

// role_registry_bind_local_service records a plan-bound module hash for one
// local non-role service name in a caller's scope.
role_registry_bind_local_service :: proc "contextless" (
	caller: ^Started,
	local_name: string,
	module_hash: role_contract.Contract_Hash,
) -> role_policy.Local_Service_Refusal {
	return role_policy.local_service_bind(&root_role_registry, role_registry_slot_number(caller), local_name, module_hash)
}

// role_registry_resolve_local_service resolves a caller's declared local
// service dependency to its plan-bound module hash. A name absent from the
// caller's start grant set is refused with No_Grant before checking bindings.
role_registry_resolve_local_service :: proc "contextless" (
	caller: ^Started,
	local_name: string,
) -> (module_hash: role_contract.Contract_Hash, refusal: role_policy.Local_Service_Refusal) {
	if caller == nil {
		return {}, .Zero_Caller_Slot
	}
	return role_policy.local_service_resolve(
		&root_role_registry,
		role_registry_slot_number(caller),
		local_name,
		caller.start_grant_set.callable[:],
	)
}
