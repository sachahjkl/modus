// Canonical BLAKE3 role contract catalog for all 21 core system, device,
// accessibility, and delegated roles beyond Display and Powerbox
// (src/md/features/roles_and_contracts.md; src/md/api/root_service_split.md).
//
// Each role contract is described strictly in terms of required exports, ring
// faces, and record streams, then hashed canonically by role_contract.contract_hash.
//
// Each table is constant data, with its slices as literals inside it: a
// table whose initializer slices another variable needs the start of a
// program, which a module never runs, and stays zero on the machine
// (docs/MODULE_CONTRACT.md, "Package variables are constant data at the
// load").
package root_delegation

import "modus:contract/blake3"
import op "modus:contract/operation"
import "modus:contract/palette_table"
import "modus:contract/role_contract"

// Version number of the first canonical contract catalog revision.
CORE_ROLE_CONTRACT_VERSION :: u32(1)

// Exact list of all 21 roles defined in this catalog (every Role except None,
// Display, and Powerbox, which live in modus:contract/role_contract).
@(rodata)
CORE_CATALOG_ROLES := [21]role_contract.Role {
	.Input,
	.Console,
	.Assistive,
	.Speech,
	.Terminal,
	.Start_Policy,
	.Storage,
	.Network,
	.Block_Device,
	.Network_Device,
	.Sound_Device,
	.Entropy_Device,
	.Tpm,
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
@(private = "file", rodata)
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
console_faces := [2]role_contract.Required_Face {
	{kind = .Exports, name = "console_exports", exports = {
		{
			name              = "status",
			parameters        = nil,
			result            = .Integer,
			has_error_record  = true,
			error_record_name = "Error_Record",
		},
	}},
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
@(private = "file", rodata)
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
@(private = "file", rodata)
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
storage_faces := [1]role_contract.Required_Face {
	{kind = .Exports, name = "storage_exports", exports = {
		{
			name              = "read",
			parameters        = {
				{type = .Integer, direction = .Read},
				{type = .Text, direction = .Read},
			},
			result            = .Text,
			has_error_record  = true,
			error_record_name = "Error_Record",
		},
		{
			name              = "write",
			parameters        = {
				{type = .Integer, direction = .Read},
				{type = .Text, direction = .Read},
				{type = .Text, direction = .Read},
			},
			result            = .Integer,
			has_error_record  = true,
			error_record_name = "Error_Record",
		},
		{
			name              = "remove",
			parameters        = {
				{type = .Integer, direction = .Read},
				{type = .Text, direction = .Read},
			},
			result            = .Integer,
			has_error_record  = true,
			error_record_name = "Error_Record",
		},
	}},
}

// --- Network ---
@(private = "file", rodata)
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
@(private = "file", rodata)
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
disk_processes_faces := [2]role_contract.Required_Face {
	{kind = .Exports, name = "disk_processes_exports", exports = {
		{
			name               = "status",
			parameters         = nil,
			result             = .Record,
			result_record_name = "Disk_Processes_Status",
			has_error_record   = true,
			error_record_name  = "Error_Record",
		},
	}},
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
principals_faces := [2]role_contract.Required_Face {
	{kind = .Exports, name = "principals_exports", exports = {
		{
			name               = "status",
			parameters         = nil,
			result             = .Record,
			result_record_name = "Principals_Status",
			has_error_record   = true,
			error_record_name  = "Error_Record",
		},
	}},
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
devices_faces := [2]role_contract.Required_Face {
	{kind = .Exports, name = "devices_exports", exports = {
		{
			name               = "status",
			parameters         = nil,
			result             = .Record,
			result_record_name = "Devices_Status",
			has_error_record   = true,
			error_record_name  = "Error_Record",
		},
	}},
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
// The getters give a member of a closed set (settings.Font,
// settings.Appearance, scale_factor.Scale): their result is an Enum, as the
// module file of `settings` describes it.
@(private = "file", rodata)
settings_faces := [1]role_contract.Required_Face {
	{kind = .Exports, name = "settings_exports", exports = {
		{
			name              = "set_time_zone",
			parameters        = {
				{type = .Text, direction = .Read},
			},
			result            = .Integer,
			has_error_record  = true,
			error_record_name = "Error_Record",
		},
		{
			name              = "font",
			parameters        = nil,
			result            = .Enum,
			has_error_record  = false,
		},
		{
			name              = "appearance",
			parameters        = nil,
			result            = .Enum,
			has_error_record  = false,
		},
		{
			name              = "scale",
			parameters        = nil,
			result            = .Enum,
			has_error_record  = false,
		},
		// The settings of the role are kept by the holder in the store of
		// the role: a reset makes a choice absent, and the state gives the
		// layer of each value (src/md/features/module_settings.md).
		{
			name              = "reset",
			parameters        = {{type = .Enum, direction = .Read, record_name = "Setting"}},
			result            = .Integer,
			has_error_record  = true,
			error_record_name = "Error_Record",
		},
		{
			name               = "settings_state",
			parameters         = nil,
			result             = .Table,
			result_record_name = "Setting_State",
			has_error_record   = true,
			error_record_name  = "Error_Record",
		},
	}},
}

// --- Plans ---
@(private = "file", rodata)
plans_faces := [2]role_contract.Required_Face {
	{kind = .Exports, name = "plans_exports", exports = {
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
	}},
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
recipes_faces := [2]role_contract.Required_Face {
	{kind = .Exports, name = "recipes_exports", exports = {
		{
			name               = "status",
			parameters         = nil,
			result             = .Record,
			result_record_name = "Recipes_Status",
			has_error_record   = true,
			error_record_name  = "Error_Record",
		},
	}},
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
projects_faces := [2]role_contract.Required_Face {
	{kind = .Exports, name = "projects_exports", exports = {
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
	}},
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

// --- Assistive ---
@(private = "file", rodata)
assistive_faces := [1]role_contract.Required_Face {
	{
		kind = .Ring,
		name = "assistive_ring",
		ring_face = {
			name             = "assistive_ring",
			command_count    = 4,
			event_count      = 4,
			carries_handles  = true,
			handle_rights    = READ_ONLY_RIGHTS,
			protocol_version = 1,
		},
	},
}

// --- Speech ---
@(private = "file", rodata)
speech_faces := [2]role_contract.Required_Face {
	{
		kind = .Record_Stream,
		name = "utterances",
		record_stream = {
			name        = "utterances",
			is_input    = true,
			record_name = "Speech_Utterance",
		},
	},
	{
		kind = .Ring,
		name = "speech_stream_ring",
		ring_face = {
			name             = "speech_stream_ring",
			command_count    = 3,
			event_count      = 9,
			carries_handles  = true,
			handle_rights    = READ_ONLY_RIGHTS,
			protocol_version = 1,
		},
	},
}

// --- Block_Device ---
@(private = "file", rodata)
block_device_faces := [1]role_contract.Required_Face {
	{
		kind = .Ring,
		name = "block_ring",
		ring_face = {
			name             = "block_ring",
			command_count    = 6,
			event_count      = 1,
			carries_handles  = true,
			handle_rights    = READ_WRITE_RIGHTS,
			protocol_version = 1,
		},
	},
}

// --- Network_Device ---
@(private = "file", rodata)
network_device_faces := [1]role_contract.Required_Face {
	{
		kind = .Ring,
		name = "frame_ring",
		ring_face = {
			name             = "frame_ring",
			command_count    = 7,
			event_count      = 1,
			carries_handles  = true,
			handle_rights    = READ_WRITE_RIGHTS,
			protocol_version = 1,
		},
	},
}

// --- Sound_Device ---
@(private = "file", rodata)
sound_device_faces := [1]role_contract.Required_Face {
	{
		kind = .Ring,
		name = "sound_stream_ring",
		ring_face = {
			name             = "sound_stream_ring",
			command_count    = 3,
			event_count      = 9,
			carries_handles  = true,
			handle_rights    = READ_ONLY_RIGHTS,
			protocol_version = 1,
		},
	},
}

// --- Entropy_Device ---
@(private = "file", rodata)
entropy_device_faces := [1]role_contract.Required_Face {
	{
		kind = .Ring,
		name = "entropy_ring",
		ring_face = {
			name             = "entropy_ring",
			command_count    = 1,
			event_count      = 1,
			carries_handles  = false,
			handle_rights    = 0,
			protocol_version = 1,
		},
	},
}

// --- Tpm ---
@(private = "file", rodata)
tpm_faces := [2]role_contract.Required_Face {
	{
		kind = .Ring,
		name = "tpm_client_ring",
		ring_face = {
			name             = "tpm_client_ring",
			command_count    = 4,
			event_count      = 1,
			carries_handles  = false,
			handle_rights    = 0,
			protocol_version = 1,
		},
	},
	{
		kind = .Ring,
		name = "tpm_measure_ring",
		ring_face = {
			name             = "tpm_measure_ring",
			command_count    = 1,
			event_count      = 1,
			carries_handles  = false,
			handle_rights    = 0,
			protocol_version = 1,
		},
	},
}

// role_contract_by_role returns the canonical Role_Contract for every member of
// role_contract.Role except .None. Unknown roles are refused.
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
	case .Assistive:
		return {role = .Assistive, version = CORE_ROLE_CONTRACT_VERSION, faces = assistive_faces[:]}, true
	case .Speech:
		return {role = .Speech, version = CORE_ROLE_CONTRACT_VERSION, faces = speech_faces[:]}, true
	case .Terminal:
		return {role = .Terminal, version = CORE_ROLE_CONTRACT_VERSION, faces = terminal_faces[:]}, true
	case .Start_Policy:
		return {role = .Start_Policy, version = CORE_ROLE_CONTRACT_VERSION, faces = start_policy_faces[:]}, true
	case .Storage:
		return {role = .Storage, version = CORE_ROLE_CONTRACT_VERSION, faces = storage_faces[:]}, true
	case .Network:
		return {role = .Network, version = CORE_ROLE_CONTRACT_VERSION, faces = network_faces[:]}, true
	case .Block_Device:
		return {role = .Block_Device, version = CORE_ROLE_CONTRACT_VERSION, faces = block_device_faces[:]}, true
	case .Network_Device:
		return {role = .Network_Device, version = CORE_ROLE_CONTRACT_VERSION, faces = network_device_faces[:]}, true
	case .Sound_Device:
		return {role = .Sound_Device, version = CORE_ROLE_CONTRACT_VERSION, faces = sound_device_faces[:]}, true
	case .Entropy_Device:
		return {role = .Entropy_Device, version = CORE_ROLE_CONTRACT_VERSION, faces = entropy_device_faces[:]}, true
	case .Tpm:
		return {role = .Tpm, version = CORE_ROLE_CONTRACT_VERSION, faces = tpm_faces[:]}, true
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
	}
	return {}, false
}

// role_contract_hash_by_role computes the deterministic BLAKE3 digest of the
// canonical role contract for role.
role_contract_hash_by_role :: proc "contextless" (role: role_contract.Role) -> (hash: role_contract.Contract_Hash, ok: bool) {
	contract := role_contract_by_role(role) or_return
	return role_contract.contract_hash(contract)
}

// role_contracts_digest gives one hash of the contracts of each role, in
// the order of the roles: for each role with a contract, its number, 1
// when its contract passes its canonical encoding, and its hash. The root
// service writes it at its start and the tool computes it on the host: a
// contract that a machine reads in another form gives another digest.
role_contracts_digest :: proc "contextless" () -> (digest: blake3.Hash, contracts: u64, encoded: u64) {
	bytes: [len(role_contract.Role) * (2 + blake3.HASH_SIZE)]u8
	written := 0
	for role in role_contract.Role {
		if _, known := role_contract_by_role(role); !known {
			continue
		}
		hash, hashed := role_contract_hash_by_role(role)
		bytes[written] = u8(role)
		bytes[written + 1] = hashed ? 1 : 0
		copy(bytes[written + 2:][:blake3.HASH_SIZE], hash[:])
		written += 2 + blake3.HASH_SIZE
		contracts += 1
		encoded += hashed ? 1 : 0
	}
	return blake3.hash(bytes[:written]), contracts, encoded
}
