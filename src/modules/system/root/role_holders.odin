// Central role-to-holder resolution table in the root service
// (src/md/features/roles_and_contracts.md).
//
// Maps each system Role to its active holder module name (defaulting to the
// boot image's built-in holders and allowing a principal plan to override any
// replaceable role without changing module callers).
package root

import "modus:contract/role_contract"
import rd "modus:contract/root_delegation"

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

// device_class_holder_name resolves the module name holding a PCI device class role.
device_class_holder_name :: proc "contextless" (class: rd.Device_Class_Role, fallback: string) -> string {
	if sys_role, ok := rd.device_class_to_system_role(class); ok {
		if holder := role_holder_name(sys_role); holder != "" {
			return holder
		}
	}
	return fallback
}
