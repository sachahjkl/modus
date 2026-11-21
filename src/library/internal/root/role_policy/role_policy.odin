// Pure role holder and local service binding policy for the root service
// (src/md/features/roles_and_contracts.md).
//
// Enforces:
// - one holder per (role, scope), with Assistive as the sole multi-holder role;
// - trusted-path roles (Display, Input, Console, Assistive) accept a disk
//   module only when chosen by principal 0, and rescue mode refuses all disk
//   holders;
// - every candidate holder passes role_contract.module_fills_contract before
//   binding;
// - non-role services resolve only from a caller's declared local dependencies
//   to a plan-bound module hash, never through a global name lookup.
package role_policy

import "modus:contract/enum_word"
import "modus:contract/role_contract"
import "modus:contract/text_encoding"

// Maximum active role holders tracked across all scopes.
HOLDER_CAPACITY :: 64

// Maximum simultaneous Assistive holders permitted in one machine scope.
ASSISTIVE_HOLDER_LIMIT :: 8

// Maximum per-caller plan-bound local service bindings.
LOCAL_BINDING_CAPACITY :: 64

// Maximum length in bytes of a local service name in a start grant set.
LOCAL_NAME_CAPACITY :: 32

// Identifies one scope instance:
// - Machine: identifier must be 0.
// - Session: identifier is the principal identifier (0 for principal 0).
// - Client: identifier is the client process slot (must be non-zero).
// - Device: identifier is the device identifier (must be non-zero).
Scope_Key :: struct {
	scope:      role_contract.Role_Scope,
	identifier: u64,
}

// Where a role holder module came from.
Holder_Origin :: enum u8 {
	None        = 0,
	Boot_Image  = 1,
	Disk_Module = 2,
}

// One active role holder entry in the registry.
Role_Holder :: struct {
	active:                bool,
	role:                  role_contract.Role,
	scope:                 Scope_Key,
	module_hash:           role_contract.Contract_Hash,
	contract_hash:         role_contract.Contract_Hash,
	origin:                Holder_Origin,
	chosen_by_principal:   u64,
	process_slot:          u32,
	interposed_below_slot: u32,
}

// Input to bind_holder.
Bind_Request :: struct {
	role:                  role_contract.Role,
	scope:                 Scope_Key,
	module_hash:           role_contract.Contract_Hash,
	origin:                Holder_Origin,
	chosen_by_principal:   u64,
	process_slot:          u32,
	interposed_below_slot: u32,
	module_bytes:          []u8,
	declaration:           role_contract.Module_Role_Declaration,
	contract:              role_contract.Role_Contract,
}

// Why bind_holder refused a binding. On any refusal, registry state is
// unchanged.
Bind_Refusal :: enum u8 {
	None                                 = 0,
	Unknown_Role                         = 1,
	Invalid_Origin                       = 2,
	Zero_Process_Slot                    = 3,
	Zero_Module_Hash                     = 4,
	Scope_Mismatch                       = 5,
	Role_Contract_Mismatch               = 6,
	Rescue_Refuses_Disk_Holder           = 7,
	Trusted_Path_Requires_Principal_Zero = 8,
	Contract_Not_Filled                  = 9,
	Role_Already_Held                    = 10,
	Duplicate_Holder                     = 11,
	Assistive_Limit_Reached              = 12,
	Table_Full                           = 13,
}

// Outcome of bind_holder.
Bind_Result :: struct {
	refusal:        Bind_Refusal,
	contract_check: role_contract.Contract_Check_Result,
	holder_index:   int,
}

// One plan-bound local service dependency for a single caller slot.
Local_Service_Binding :: struct {
	active:            bool,
	caller_slot:       u32,
	local_name:        [LOCAL_NAME_CAPACITY]u8,
	local_name_length: u8,
	module_hash:       role_contract.Contract_Hash,
}

// Why a local service bind or resolve failed.
Local_Service_Refusal :: enum u8 {
	None               = 0,
	Zero_Caller_Slot   = 1,
	Invalid_Local_Name = 2,
	Zero_Module_Hash   = 3,
	Duplicate_Binding  = 4,
	Table_Full         = 5,
	No_Grant           = 6,
	Unbound_Local_Name = 7,
}

// Fixed-capacity registry of active role holders and per-caller local service
// bindings. Valid when all zero bytes.
Role_Registry :: struct {
	rescue_mode:    bool,
	holders:        [HOLDER_CAPACITY]Role_Holder,
	local_bindings: [LOCAL_BINDING_CAPACITY]Local_Service_Binding,
}

// holder_origin_from_word converts a transport word into a Holder_Origin,
// refusing zero and any unknown word.
holder_origin_from_word :: proc "contextless" (word: u64) -> (origin: Holder_Origin, ok: bool) {
	member := enum_word.member_of_word(Holder_Origin, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// scope_key_valid_for_role checks that a Scope_Key matches the role's fixed
// scope and carries a valid scope identifier.
scope_key_valid_for_role :: proc "contextless" (role: role_contract.Role, key: Scope_Key) -> bool {
	props := role_contract.role_properties(role)
	if props.scope == .None || key.scope != props.scope {
		return false
	}
	switch key.scope {
	case .None:
		return false
	case .Machine:
		return key.identifier == 0
	case .Session:
		return true
	case .Client, .Device:
		return key.identifier != 0
	}
	return false
}

// bind_holder validates the request against scope rules, trusted-path rules,
// rescue mode, contract conformance, and holder multiplicity, then records the
// holder. Any refusal leaves registry unchanged.
bind_holder :: proc "contextless" (registry: ^Role_Registry, request: Bind_Request) -> Bind_Result {
	role, role_ok := role_contract.role_from_word(u64(request.role))
	if !role_ok {
		return {refusal = .Unknown_Role, holder_index = -1}
	}
	origin, origin_ok := holder_origin_from_word(u64(request.origin))
	if !origin_ok {
		return {refusal = .Invalid_Origin, holder_index = -1}
	}
	if request.process_slot == 0 {
		return {refusal = .Zero_Process_Slot, holder_index = -1}
	}
	if request.module_hash == {} {
		return {refusal = .Zero_Module_Hash, holder_index = -1}
	}
	if !scope_key_valid_for_role(role, request.scope) {
		return {refusal = .Scope_Mismatch, holder_index = -1}
	}
	if request.contract.role != role {
		return {refusal = .Role_Contract_Mismatch, holder_index = -1}
	}
	if registry.rescue_mode && origin == .Disk_Module {
		return {refusal = .Rescue_Refuses_Disk_Holder, holder_index = -1}
	}
	if origin == .Disk_Module && !role_contract.disk_holder_allowed_for_principal(role, request.chosen_by_principal) {
		return {refusal = .Trusted_Path_Requires_Principal_Zero, holder_index = -1}
	}

	check := role_contract.module_fills_contract(request.module_bytes, request.declaration, request.contract)
	if check.refusal != .None {
		return {refusal = .Contract_Not_Filled, contract_check = check, holder_index = -1}
	}

	allows_multiple := role_contract.role_allows_multiple_holders(role)
	existing_in_scope := 0
	free_slot := -1
	for &entry, index in registry.holders {
		if !entry.active {
			if free_slot < 0 {
				free_slot = index
			}
			continue
		}
		if entry.role == role && entry.scope == request.scope {
			if entry.process_slot == request.process_slot {
				return {refusal = .Duplicate_Holder, contract_check = check, holder_index = -1}
			}
			existing_in_scope += 1
		}
	}

	if !allows_multiple && existing_in_scope > 0 {
		return {refusal = .Role_Already_Held, contract_check = check, holder_index = -1}
	}
	if allows_multiple && existing_in_scope >= ASSISTIVE_HOLDER_LIMIT {
		return {refusal = .Assistive_Limit_Reached, contract_check = check, holder_index = -1}
	}
	if free_slot < 0 {
		return {refusal = .Table_Full, contract_check = check, holder_index = -1}
	}

	registry.holders[free_slot] = {
		active                = true,
		role                  = role,
		scope                 = request.scope,
		module_hash           = request.module_hash,
		contract_hash         = check.expected_hash,
		origin                = origin,
		chosen_by_principal   = request.chosen_by_principal,
		process_slot          = request.process_slot,
		interposed_below_slot = request.interposed_below_slot,
	}
	return {refusal = .None, contract_check = check, holder_index = free_slot}
}

// unbind_process removes every role holding and local service binding owned by
// a stopped process slot. Returns the number of role holder entries removed.
unbind_process :: proc "contextless" (registry: ^Role_Registry, process_slot: u32) -> (removed: int) {
	if process_slot == 0 {
		return 0
	}
	for &entry in registry.holders {
		if entry.active && entry.process_slot == process_slot {
			entry = {}
			removed += 1
		}
	}
	for &binding in registry.local_bindings {
		if binding.active && binding.caller_slot == process_slot {
			binding = {}
		}
	}
	return removed
}

// holder_find looks up the active holder of a role in a scope. For Assistive,
// use holders_for_scope to read all active holders.
holder_find :: proc "contextless" (registry: ^Role_Registry, role: role_contract.Role, scope: Scope_Key) -> (holder: Role_Holder, found: bool) {
	valid_role, ok := role_contract.role_from_word(u64(role))
	if !ok || !scope_key_valid_for_role(valid_role, scope) {
		return {}, false
	}
	for entry in registry.holders {
		if entry.active && entry.role == valid_role && entry.scope == scope {
			return entry, true
		}
	}
	return {}, false
}

// holders_for_scope copies active holders of a role in a scope into out and
// returns the total count of active holders in that scope.
holders_for_scope :: proc "contextless" (registry: ^Role_Registry, role: role_contract.Role, scope: Scope_Key, out: []Role_Holder) -> (total: int) {
	valid_role, ok := role_contract.role_from_word(u64(role))
	if !ok || !scope_key_valid_for_role(valid_role, scope) {
		return 0
	}
	for entry in registry.holders {
		if entry.active && entry.role == valid_role && entry.scope == scope {
			if total < len(out) {
				out[total] = entry
			}
			total += 1
		}
	}
	return total
}

@(private = "file")
local_name_valid :: proc "contextless" (name: string) -> bool {
	if len(name) == 0 || len(name) > LOCAL_NAME_CAPACITY {
		return false
	}
	return text_encoding.identifier_valid(transmute([]u8)name)
}

@(private = "file")
binding_name :: proc "contextless" (binding: ^Local_Service_Binding) -> string {
	return string(binding.local_name[:binding.local_name_length])
}

// local_service_bind binds a local non-role service name in one caller's plan
// to a specific module hash. Names are never global: another caller slot cannot
// resolve this binding.
local_service_bind :: proc "contextless" (
	registry: ^Role_Registry,
	caller_slot: u32,
	local_name: string,
	module_hash: role_contract.Contract_Hash,
) -> Local_Service_Refusal {
	if caller_slot == 0 {
		return .Zero_Caller_Slot
	}
	if !local_name_valid(local_name) {
		return .Invalid_Local_Name
	}
	if module_hash == {} {
		return .Zero_Module_Hash
	}
	free_slot := -1
	for &binding, index in registry.local_bindings {
		if !binding.active {
			if free_slot < 0 {
				free_slot = index
			}
			continue
		}
		if binding.caller_slot == caller_slot && binding_name(&binding) == local_name {
			return .Duplicate_Binding
		}
	}
	if free_slot < 0 {
		return .Table_Full
	}
	entry := Local_Service_Binding {
		active            = true,
		caller_slot       = caller_slot,
		local_name_length = u8(len(local_name)),
		module_hash       = module_hash,
	}
	copy(entry.local_name[:], local_name)
	registry.local_bindings[free_slot] = entry
	return .None
}

// local_service_resolve resolves a local non-role service name to the module
// hash bound by the plan for caller_slot. If caller_declared_callable does not
// list local_name, it refuses with No_Grant before checking the binding table,
// so a caller never learns whether another service exists.
local_service_resolve :: proc "contextless" (
	registry: ^Role_Registry,
	caller_slot: u32,
	local_name: string,
	caller_declared_callable: []string,
) -> (module_hash: role_contract.Contract_Hash, refusal: Local_Service_Refusal) {
	if caller_slot == 0 {
		return {}, .Zero_Caller_Slot
	}
	if !local_name_valid(local_name) {
		return {}, .Invalid_Local_Name
	}
	declared := false
	for allowed in caller_declared_callable {
		if allowed == "" {
			continue
		}
		if allowed == local_name {
			declared = true
			break
		}
	}
	if !declared {
		return {}, .No_Grant
	}
	for &binding in registry.local_bindings {
		if binding.active && binding.caller_slot == caller_slot && binding_name(&binding) == local_name {
			return binding.module_hash, .None
		}
	}
	return {}, .Unbound_Local_Name
}
