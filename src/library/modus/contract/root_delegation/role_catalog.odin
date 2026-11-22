// Canonical BLAKE3 role contract catalog for all 14 remaining core system and
// delegated roles (src/md/features/roles_and_contracts.md;
// src/md/api/root_service_split.md).
//
// Each role contract is described strictly in terms of required exports, ring
// faces, and record streams, then hashed canonically by role_contract.contract_hash.
package root_delegation

import op "modus:contract/operation"
import "modus:contract/palette_table"
import "modus:contract/role_contract"

// Version number of the first canonical contract catalog revision.
CORE_ROLE_CONTRACT_VERSION :: u32(1)

// Exact list of the 14 remaining core roles covered by this catalog.
@(rodata)
CORE_CATALOG_ROLES := [14]role_contract.Role {
	.Input,
	.Console,
	.Terminal,
	.Start_Policy,
	.Storage,
	.Network,
	.Remote_Display,
	.Disk_Processes,
	.Principals,
	.Devices,
	.Settings,
	.Plans,
	.Recipes,
	.Projects,
}

@(private = "file")
READ_ONLY_RIGHTS :: u32(1) << u32(op.Right.Read)
@(private = "file")
READ_WRITE_RIGHTS :: (u32(1) << u32(op.Right.Read)) | (u32(1) << u32(op.Right.Write))

// --- Input ---
@(private = "file")
input_faces := [1]role_contract.Required_Face {
	{
		kind = .Ring,
		name = "input_ring",
		ring_face = {
			name             = "input_ring",
			command_count    = 2,
			event_count      = 0,
			carries_handles  = false,
			handle_rights    = 0,
			protocol_version = 1,
		},
	},
}

// --- Console ---
@(private = "file", rodata)
console_exports := [1]role_contract.Required_Export {
	{
		name              = "status",
		parameters        = nil,
		result            = .Integer,
		has_error_record  = true,
		error_record_name = "Error_Record",
	},
}

@(private = "file")
console_faces := [2]role_contract.Required_Face {
	{kind = .Exports, name = "console_exports", exports = console_exports[:]},
	{
		kind = .Ring,
		name = "palette_ring",
		ring_face = {
			name             = "palette_ring",
			command_count    = 5,
			event_count      = 7,
			carries_handles  = false,
			handle_rights    = 0,
			protocol_version = palette_table.VERSION,
		},
	},
}

// --- Terminal ---
@(private = "file")
terminal_faces := [1]role_contract.Required_Face {
	{
		kind = .Ring,
		name = "terminal_ring",
		ring_face = {
			name             = "terminal_ring",
			command_count    = 4,
			event_count      = 4,
			carries_handles  = true,
			handle_rights    = READ_WRITE_RIGHTS,
			protocol_version = 1,
		},
	},
}

// --- Start_Policy ---
@(private = "file")
start_policy_faces := [2]role_contract.Required_Face {
	{
		kind = .Ring,
		name = "start_policy_ring",
		ring_face = {
			name             = "start_policy_ring",
			command_count    = 4,
			event_count      = 4,
			carries_handles  = false,
			handle_rights    = 0,
			protocol_version = 1,
		},
	},
	{
		kind = .Record_Stream,
		name = "stops",
		record_stream = {
			name        = "stops",
			is_input    = true,
			record_name = "Process_Stop_Notice",
		},
	},
}

// --- Storage ---
@(private = "file", rodata)
storage_read_params := [3]role_contract.Required_Parameter {
	{type = .Integer, direction = .Read},
	{type = .Text, direction = .Read},
	{type = .Bytes, direction = .Change},
}

@(private = "file", rodata)
storage_write_params := [3]role_contract.Required_Parameter {
	{type = .Integer, direction = .Read},
	{type = .Text, direction = .Read},
	{type = .Bytes, direction = .Read},
}

@(private = "file", rodata)
storage_remove_params := [2]role_contract.Required_Parameter {
	{type = .Integer, direction = .Read},
	{type = .Text, direction = .Read},
}

@(private = "file")
storage_exports := [3]role_contract.Required_Export {
	{
		name              = "read",
		parameters        = storage_read_params[:],
		result            = .Integer,
		has_error_record  = true,
		error_record_name = "Error_Record",
	},
	{
		name              = "write",
		parameters        = storage_write_params[:],
		result            = .Integer,
		has_error_record  = true,
		error_record_name = "Error_Record",
	},
	{
		name              = "remove",
		parameters        = storage_remove_params[:],
		result            = .Integer,
		has_error_record  = true,
		error_record_name = "Error_Record",
	},
}

@(private = "file")
storage_faces := [1]role_contract.Required_Face {
	{kind = .Exports, name = "storage_exports", exports = storage_exports[:]},
}

// --- Network ---
@(private = "file")
network_faces := [2]role_contract.Required_Face {
	{
		kind = .Ring,
		name = "network_control_ring",
		ring_face = {
			name             = "network_control_ring",
			command_count    = 4,
			event_count      = 4,
			carries_handles  = true,
			handle_rights    = READ_WRITE_RIGHTS,
			protocol_version = 1,
		},
	},
	{
		kind = .Ring,
		name = "network_endpoint_ring",
		ring_face = {
			name             = "network_endpoint_ring",
			command_count    = 6,
			event_count      = 6,
			carries_handles  = false,
			handle_rights    = 0,
			protocol_version = 1,
		},
	},
}

// --- Remote_Display ---
@(private = "file")
remote_display_faces := [2]role_contract.Required_Face {
	{
		kind = .Ring,
		name = "capture_ring",
		ring_face = {
			name             = "capture_ring",
			command_count    = 3,
			event_count      = 3,
			carries_handles  = true,
			handle_rights    = READ_ONLY_RIGHTS,
			protocol_version = 2,
		},
	},
	{
		kind = .Ring,
		name = "remote_input_ring",
		ring_face = {
			name             = "remote_input_ring",
			command_count    = 3,
			event_count      = 1,
			carries_handles  = false,
			handle_rights    = 0,
			protocol_version = 2,
		},
	},
}

// --- Disk_Processes ---
@(private = "file", rodata)
disk_processes_exports := [1]role_contract.Required_Export {
	{
		name               = "status",
		parameters         = nil,
		result             = .Record,
		result_record_name = "Disk_Processes_Status",
		has_error_record   = true,
		error_record_name  = "Error_Record",
	},
}

@(private = "file")
disk_processes_faces := [2]role_contract.Required_Face {
	{kind = .Exports, name = "disk_processes_exports", exports = disk_processes_exports[:]},
	{
		kind = .Ring,
		name = "disk_processes_ring",
		ring_face = {
			name             = "disk_processes_ring",
			command_count    = 4,
			event_count      = 3,
			carries_handles  = true,
			handle_rights    = READ_ONLY_RIGHTS,
			protocol_version = 1,
		},
	},
}

// --- Principals ---
@(private = "file", rodata)
principals_exports := [1]role_contract.Required_Export {
	{
		name               = "status",
		parameters         = nil,
		result             = .Record,
		result_record_name = "Principals_Status",
		has_error_record   = true,
		error_record_name  = "Error_Record",
	},
}

@(private = "file")
principals_faces := [2]role_contract.Required_Face {
	{kind = .Exports, name = "principals_exports", exports = principals_exports[:]},
	{
		kind = .Ring,
		name = "principals_ring",
		ring_face = {
			name             = "principals_ring",
			command_count    = 5,
			event_count      = 4,
			carries_handles  = false,
			handle_rights    = 0,
			protocol_version = 1,
		},
	},
}

// --- Devices ---
@(private = "file", rodata)
devices_exports := [1]role_contract.Required_Export {
	{
		name               = "status",
		parameters         = nil,
		result             = .Record,
		result_record_name = "Devices_Status",
		has_error_record   = true,
		error_record_name  = "Error_Record",
	},
}

@(private = "file")
devices_faces := [2]role_contract.Required_Face {
	{kind = .Exports, name = "devices_exports", exports = devices_exports[:]},
	{
		kind = .Ring,
		name = "devices_ring",
		ring_face = {
			name             = "devices_ring",
			command_count    = 4,
			event_count      = 3,
			carries_handles  = true,
			handle_rights    = READ_WRITE_RIGHTS,
			protocol_version = 1,
		},
	},
}

// --- Settings ---
@(private = "file", rodata)
settings_zone_params := [1]role_contract.Required_Parameter {
	{type = .Text, direction = .Read},
}

@(private = "file")
settings_exports := [4]role_contract.Required_Export {
	{
		name              = "set_time_zone",
		parameters        = settings_zone_params[:],
		result            = .Integer,
		has_error_record  = true,
		error_record_name = "Error_Record",
	},
	{
		name              = "font",
		parameters        = nil,
		result            = .Integer,
		has_error_record  = false,
	},
	{
		name              = "appearance",
		parameters        = nil,
		result            = .Integer,
		has_error_record  = false,
	},
	{
		name              = "scale",
		parameters        = nil,
		result            = .Integer,
		has_error_record  = false,
	},
}

@(private = "file")
settings_faces := [1]role_contract.Required_Face {
	{kind = .Exports, name = "settings_exports", exports = settings_exports[:]},
}

// --- Plans ---
@(private = "file")
plans_exports := [2]role_contract.Required_Export {
	{
		name               = "status",
		parameters         = nil,
		result             = .Record,
		result_record_name = "Plans_Status",
		has_error_record   = true,
		error_record_name  = "Error_Record",
	},
	{
		name              = "current_generation",
		parameters        = nil,
		result            = .Integer,
		has_error_record  = true,
		error_record_name = "Error_Record",
	},
}

@(private = "file")
plans_faces := [2]role_contract.Required_Face {
	{kind = .Exports, name = "plans_exports", exports = plans_exports[:]},
	{
		kind = .Ring,
		name = "plans_service_ring",
		ring_face = {
			name             = "plans_service_ring",
			command_count    = 4,
			event_count      = 4,
			carries_handles  = false,
			handle_rights    = 0,
			protocol_version = 1,
		},
	},
}

// --- Recipes ---
@(private = "file", rodata)
recipes_exports := [1]role_contract.Required_Export {
	{
		name               = "status",
		parameters         = nil,
		result             = .Record,
		result_record_name = "Recipes_Status",
		has_error_record   = true,
		error_record_name  = "Error_Record",
	},
}

@(private = "file")
recipes_faces := [2]role_contract.Required_Face {
	{kind = .Exports, name = "recipes_exports", exports = recipes_exports[:]},
	{
		kind = .Ring,
		name = "recipes_service_ring",
		ring_face = {
			name             = "recipes_service_ring",
			command_count    = 3,
			event_count      = 4,
			carries_handles  = false,
			handle_rights    = 0,
			protocol_version = 1,
		},
	},
}

// --- Projects ---
@(private = "file", rodata)
projects_exports := [2]role_contract.Required_Export {
	{
		name               = "status",
		parameters         = nil,
		result             = .Record,
		result_record_name = "Projects_Status",
		has_error_record   = true,
		error_record_name  = "Error_Record",
	},
	{
		name              = "active_console_count",
		parameters        = nil,
		result            = .Integer,
		has_error_record  = true,
		error_record_name = "Error_Record",
	},
}

@(private = "file")
projects_faces := [2]role_contract.Required_Face {
	{kind = .Exports, name = "projects_exports", exports = projects_exports[:]},
	{
		kind = .Ring,
		name = "projects_service_ring",
		ring_face = {
			name             = "projects_service_ring",
			command_count    = 4,
			event_count      = 4,
			carries_handles  = false,
			handle_rights    = 0,
			protocol_version = 1,
		},
	},
}

// role_contract_by_role returns the canonical Role_Contract for each of the 14
// core and delegated roles in this catalog as well as Display and Powerbox.
// Unknown roles and roles without a defined contract are refused.
role_contract_by_role :: proc "contextless" (role: role_contract.Role) -> (contract: role_contract.Role_Contract, ok: bool) {
	validated, valid := role_contract.role_from_word(u64(role))
	if !valid {
		return {}, false
	}
	switch validated {
	case .None:
		return {}, false
	case .Display:
		return role_contract.display_contract(), true
	case .Powerbox:
		return role_contract.powerbox_contract(), true
	case .Input:
		return {role = .Input, version = CORE_ROLE_CONTRACT_VERSION, faces = input_faces[:]}, true
	case .Console:
		return {role = .Console, version = CORE_ROLE_CONTRACT_VERSION, faces = console_faces[:]}, true
	case .Terminal:
		return {role = .Terminal, version = CORE_ROLE_CONTRACT_VERSION, faces = terminal_faces[:]}, true
	case .Start_Policy:
		return {role = .Start_Policy, version = CORE_ROLE_CONTRACT_VERSION, faces = start_policy_faces[:]}, true
	case .Storage:
		return {role = .Storage, version = CORE_ROLE_CONTRACT_VERSION, faces = storage_faces[:]}, true
	case .Network:
		return {role = .Network, version = CORE_ROLE_CONTRACT_VERSION, faces = network_faces[:]}, true
	case .Remote_Display:
		return {role = .Remote_Display, version = CORE_ROLE_CONTRACT_VERSION, faces = remote_display_faces[:]}, true
	case .Disk_Processes:
		return {role = .Disk_Processes, version = CORE_ROLE_CONTRACT_VERSION, faces = disk_processes_faces[:]}, true
	case .Principals:
		return {role = .Principals, version = CORE_ROLE_CONTRACT_VERSION, faces = principals_faces[:]}, true
	case .Devices:
		return {role = .Devices, version = CORE_ROLE_CONTRACT_VERSION, faces = devices_faces[:]}, true
	case .Settings:
		return {role = .Settings, version = CORE_ROLE_CONTRACT_VERSION, faces = settings_faces[:]}, true
	case .Plans:
		return {role = .Plans, version = CORE_ROLE_CONTRACT_VERSION, faces = plans_faces[:]}, true
	case .Recipes:
		return {role = .Recipes, version = CORE_ROLE_CONTRACT_VERSION, faces = recipes_faces[:]}, true
	case .Projects:
		return {role = .Projects, version = CORE_ROLE_CONTRACT_VERSION, faces = projects_faces[:]}, true
	case .Assistive, .Speech, .Block_Device, .Network_Device, .Sound_Device, .Entropy_Device, .Tpm:
		return {}, false
	}
	return {}, false
}

// role_contract_hash_by_role computes the deterministic BLAKE3 digest of the
// canonical role contract for role.
role_contract_hash_by_role :: proc "contextless" (role: role_contract.Role) -> (hash: role_contract.Contract_Hash, ok: bool) {
	contract := role_contract_by_role(role) or_return
	return role_contract.contract_hash(contract)
}
