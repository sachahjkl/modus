// Central role-to-holder resolution table in the root service
// (src/md/features/roles_and_contracts.md).
//
// Maps each system Role to its active holder module name (defaulting to the
// boot image's built-in holders and allowing a principal plan to override any
// replaceable role without changing module callers).
package root

import "modus:contract/role_contract"
import rd "modus:contract/root_delegation"
import "modus:contract/supervision"
import "modus:contract/work_budget"

// Default boot-image holders for every closed system role.
@(rodata)
DEFAULT_ROLE_HOLDERS := [role_contract.Role]string {
	.None           = "",
	.Display        = "compositor",
	.Input          = "input",
	.Console        = "console",
	.Assistive      = "",
	.Speech         = "",
	.Terminal       = "terminal",
	.Start_Policy   = "start_policy",
	.Storage        = "storage",
	.Network        = "network",
	.Block_Device   = "block",
	.Network_Device = "frame",
	.Sound_Device   = "sound",
	.Entropy_Device = "entropy",
	.Tpm            = "tpm",
	.Remote_Display = "remote_display",
	.Plans          = "plans",
	.Projects       = "projects",
	.Recipes        = "recipes",
	.Powerbox       = "powerbox",
	.Disk_Processes = "disk_processes",
	.Principals     = "principals",
	.Devices        = "devices",
	.Settings       = "settings",
}

// Active role holder overrides installed from a principal's plan (empty = use default).
role_holder_overrides: [role_contract.Role]string

// Live supervision generation per role for reconnecting Connection_Page holders.
role_service_generations: [role_contract.Role]u64

// role_supervision_advance bumps the generation of role when its holder restarts
// and updates an optional connection page in place.
role_supervision_advance :: proc "contextless" (role: role_contract.Role, page: ^supervision.Connection_Page) -> u64 {
	if role == .None {
		return 0
	}
	role_service_generations[role] += 1
	gen := role_service_generations[role]
	if page != nil {
		_ = supervision.connection_page_complete_reconnect(page, gen)
	}
	return gen
}

// role_connection_work_budget_check checks a requested per-connection work
// budget against the contract requirements before carving pages from the caller.
role_connection_work_budget_check :: proc "contextless" (requirements: work_budget.Work_Budget_Requirements, offered_pages, offered_time, offered_threads: u64) -> bool {
	return work_budget.work_budget_check(requirements, offered_pages, offered_time, offered_threads, true) == .None
}

// role_holder_name returns the active module name holding role.
role_holder_name :: proc "contextless" (role: role_contract.Role) -> string {
	if role == .None {
		return ""
	}
	if override := role_holder_overrides[role]; override != "" {
		return override
	}
	return DEFAULT_ROLE_HOLDERS[role]
}

// is_role_holder reports whether module_name is the active holder of role.
is_role_holder :: proc "contextless" (module_name: string, role: role_contract.Role) -> bool {
	holder := role_holder_name(role)
	return holder != "" && module_name == holder
}

// name_is_a_role_name reports whether name equals any canonical closed role name
// so disk processes cannot claim a role name as a nickname.
name_is_a_role_name :: proc "contextless" (name: string) -> bool {
	if name == "" {
		return false
	}
	for role in role_contract.Role {
		if role != .None && role_contract.role_properties(role).name == name {
			return true
		}
	}
	return false
}

// role_target_resolve_strict resolves a canonical role name to its active
// holder module name. When a role has no holder (e.g. assistive/speech), ok is
// false so Connect refuses cleanly instead of falling through to a disk process.
// Non-role module names pass through unchanged with ok = true.
role_target_resolve_strict :: proc "contextless" (name: string) -> (resolved: string, ok: bool) {
	if name == "" {
		return "", false
	}
	for role in role_contract.Role {
		if role == .None {
			continue
		}
		if role_contract.role_properties(role).name == name {
			holder := role_holder_name(role)
			if holder == "" {
				return "", false
			}
			return holder, true
		}
	}
	return name, true
}

// role_of_module_name returns the closed Role currently held by module_name, or .None.
role_of_module_name :: proc "contextless" (module_name: string) -> role_contract.Role {
	if module_name == "" {
		return .None
	}
	for role in role_contract.Role {
		if role != .None && role_holder_name(role) == module_name {
			return role
		}
	}
	return .None
}

// device_class_holder_name resolves the module name holding a PCI device class role.
device_class_holder_name :: proc "contextless" (class: rd.Device_Class_Role, fallback: string) -> string {
	if sys_role, ok := rd.device_class_to_system_role(class); ok {
		if holder := role_holder_name(sys_role); holder != "" {
			return holder
		}
	}
	return fallback
}
