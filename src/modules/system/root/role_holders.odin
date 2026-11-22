// Central role-to-holder resolution table in the root service
// (src/md/features/roles_and_contracts.md).
//
// Maps each system Role to its active holder module name (defaulting to the
// boot image's built-in holders and allowing a principal plan to override any
// replaceable role without changing module callers). The rules live in
// internal:root/role_policy, whose host tests prove them with a holder of each
// role that is not the default of the image.
package root

import "internal:root/role_policy"
import "modus:contract/role_contract"
import rd "modus:contract/root_delegation"
import "modus:contract/supervision"
import "modus:system"

// The holder of each role: the default of the boot image, then the override
// that a plan installs. Nothing of this service names the module of a role
// elsewhere: it starts, routes and trusts the holder through this table.
role_holder_names := role_policy.Holder_Names {
	defaults = {
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
	},
}

// The renderer of the terminal of the console: the boot image and the screen
// choose it once, before the start policy (console_renderer_choose_at_start).
console_renderer: role_policy.Console_Renderer

// console_renderer_choose_at_start chooses the renderer of the terminal from
// the modules of the boot image and the screen of the machine, gives the
// role Terminal to its module and leaves Display with no holder
// (src/md/features/console_renderers.md, "Which renderer a machine runs").
// An image with the compositor keeps each holder as it is.
console_renderer_choose_at_start :: proc "contextless" (screen_at_the_start: bool) {
	parts := role_policy.Console_Parts {
		compositor      = len(system.image_find(image, role_holder_name(.Display))) != 0,
		serial_terminal = len(system.image_find(image, role_policy.SERIAL_TERMINAL_MODULE)) != 0,
		grid_terminal   = len(system.image_find(image, role_policy.GRID_TERMINAL_MODULE)) != 0,
		dom_terminal    = len(system.image_find(image, role_policy.DOM_TERMINAL_MODULE)) != 0,
		screen          = screen_at_the_start,
	}
	console_renderer = role_policy.console_renderer_choose(parts)
	role_policy.console_renderer_holders_set(&role_holder_names, console_renderer)
	switch console_renderer {
	case .Desktop_Terminal:
	case .Serial_Terminal:
		system.log_fact(.Info, Console_Renderer_Serial{})
	case .Grid_Terminal:
		system.log_fact(.Info, Console_Renderer_Grid{})
	case .Dom_Terminal:
		system.log_fact(.Info, Console_Renderer_Dom{})
	}
}

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

// role_holder_name returns the active module name holding role.
role_holder_name :: proc "contextless" (role: role_contract.Role) -> string {
	return role_policy.holder_name(&role_holder_names, role)
}

// is_role_holder reports whether module_name is the active holder of role.
is_role_holder :: proc "contextless" (module_name: string, role: role_contract.Role) -> bool {
	return role_policy.is_holder(&role_holder_names, module_name, role)
}

// name_is_a_role_name reports whether name equals any canonical closed role name
// so disk processes cannot claim a role name as a nickname.
name_is_a_role_name :: proc "contextless" (name: string) -> bool {
	return role_policy.role_of_name(name) != .None
}

// role_target_resolve_strict resolves a canonical role name to its active
// holder module name. When a role has no holder (e.g. assistive/speech), ok is
// false so Connect refuses cleanly instead of falling through to a disk process.
// Non-role module names pass through unchanged with ok = true.
role_target_resolve_strict :: proc "contextless" (name: string) -> (resolved: string, ok: bool) {
	return role_policy.target_resolve(&role_holder_names, name)
}

// role_of_module_name returns the closed Role currently held by module_name, or .None.
role_of_module_name :: proc "contextless" (module_name: string) -> role_contract.Role {
	return role_policy.role_of_module(&role_holder_names, module_name)
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
