// Contract between the delegated disk_processes service and the root service
// core for starting a disk process from verified module bytes
// (src/md/api/root_service_split.md).
//
// The core never trusts the delegated service's claim about a module's hash or
// grants: validate_start_from_bytes_request recomputes the BLAKE3 hash of the
// supplied module bytes, checks the nickname and import hashes, and refuses
// System_Part, machine-authority, and unknown grants.
//
// This is a contract package: it imports base and contract packages only,
// allocates no memory, and calls no kernel operation.
package root_delegation

import "modus:contract/blake3"
import "modus:contract/enum_word"
import "modus:contract/start_grant"

// Maximum length in bytes of a disk process nickname, matching the root ring
// transport bound.
NICKNAME_CAPACITY :: 23

// Maximum byte length of a single disk module file accepted by the core.
MODULE_BYTES_LIMIT :: 4 << 20

// Maximum number of resolved transitive import hashes attached to one start
// request.
IMPORT_HASH_CAPACITY :: 32

// Maximum number of grant words carried in one start request.
GRANT_REQUEST_CAPACITY :: 16

// Upper bound on pages requested for a single disk process budget.
DISK_PROCESS_BUDGET_PAGES_LIMIT :: 16384

// Context handle slots used by the delegated disk_processes service.
DISK_PROCESSES_RING_SLOT :: 10
DISK_PROCESSES_REGION_SLOT :: 11

// Narrow set of grants that a disk process may receive through Start_From_Bytes.
Disk_Start_Grant :: enum u8 {
	Store = 0,
}

Disk_Start_Grants :: bit_set[Disk_Start_Grant; u8]

// Commands accepted on the delegated disk_processes service ring.
// Zero means unset and is refused at the border.
Disk_Processes_Ring_Command :: enum u32 {
	None                   = 0,
	Register_Catalog_Entry = 1,
	Validate_Imports       = 2,
	Lookup_Debug_Object    = 3,
	Prepare_Start          = 4,
}

// Completion statuses returned on the delegated disk_processes service ring.
Disk_Processes_Ring_Status :: enum u32 {
	Ok          = 0,
	Refused     = 1,
	Bad_Command = 2,
}

// Why validate_start_from_bytes_request refused a Start_From_Bytes_Request.
Start_From_Bytes_Refusal :: enum u8 {
	None                        = 0,
	Empty_Nickname              = 1,
	Nickname_Too_Long           = 2,
	Bad_Nickname_Byte           = 3,
	Reserved_Nickname           = 4,
	Zero_Module_Hash            = 5,
	Empty_Module_Bytes          = 6,
	Module_Too_Large            = 7,
	Module_Size_Mismatch        = 8,
	Hash_Mismatch               = 9,
	Too_Many_Imports            = 10,
	Zero_Import_Hash            = 11,
	Duplicate_Import_Hash       = 12,
	Self_Import_Hash            = 13,
	Too_Many_Grants             = 14,
	Unknown_Grant               = 15,
	Forbidden_System_Part_Grant = 16,
	Forbidden_Machine_Grant     = 17,
	Duplicate_Grant             = 18,
	Invalid_Budget              = 19,
	Trailing_Nickname_Bytes     = 20,
}

// Request sent from disk_processes to the root core to start one disk process
// from module bytes that disk_processes read from module_files.
Start_From_Bytes_Request :: struct {
	principal:             u64,
	nickname:              [NICKNAME_CAPACITY]u8,
	nickname_length:       u8,
	expected_module_hash:  blake3.Hash,
	module_byte_count:     u64,
	import_hashes:         [IMPORT_HASH_CAPACITY]blake3.Hash,
	import_count:          u32,
	requested_grant_words: [GRANT_REQUEST_CAPACITY]u64,
	requested_grant_count: u32,
	budget_pages:          u64,
}

// Result of validating a Start_From_Bytes_Request at the core border.
Start_From_Bytes_Validation :: struct {
	refusal:         Start_From_Bytes_Refusal,
	computed_hash:   blake3.Hash,
	offending_index: u32,
	grants:          Disk_Start_Grants,
}

// Reserved names that a disk process cannot claim as its nickname because they
// collide with system stores, grant tables, or privileged system parts.
@(private = "file", rodata)
reserved_disk_nicknames := [?]string {
	"module_files",
	"grant_table",
	"root",
	"wiring",
	"disk_processes",
	"principals",
	"devices",
	"powerbox",
	"collector",
	"plans",
	"recipes",
	"projects",
	"settings",
	"start_policy",
}

// disk_processes_ring_command_from_word converts a ring command word into a
// Disk_Processes_Ring_Command, refusing zero and every unknown word.
disk_processes_ring_command_from_word :: proc "contextless" (word: u32) -> (command: Disk_Processes_Ring_Command, ok: bool) {
	member := enum_word.member_of_word(Disk_Processes_Ring_Command, u64(word)) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// disk_processes_ring_status_from_word converts a completion status word into
// a Disk_Processes_Ring_Status, refusing every unknown word.
disk_processes_ring_status_from_word :: proc "contextless" (word: u32) -> (status: Disk_Processes_Ring_Status, ok: bool) {
	return enum_word.member_of_word(Disk_Processes_Ring_Status, u64(word))
}

// validate_nickname checks that a disk process nickname is non-empty, within
// NICKNAME_CAPACITY, composed solely of ASCII letters, digits, '-', and '_',
// and does not collide with reserved system names.
validate_nickname :: proc "contextless" (name: string) -> Start_From_Bytes_Refusal {
	if len(name) == 0 {
		return .Empty_Nickname
	}
	if len(name) > NICKNAME_CAPACITY {
		return .Nickname_Too_Long
	}
	for index in 0 ..< len(name) {
		ch := name[index]
		allowed := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_'
		if !allowed {
			return .Bad_Nickname_Byte
		}
	}
	for reserved in reserved_disk_nicknames {
		if name == reserved {
			return .Reserved_Nickname
		}
	}
	return .None
}

// request_nickname_slice validates the stored nickname buffer and trailing zero
// padding of a Start_From_Bytes_Request.
@(private = "file")
request_nickname_slice :: proc "contextless" (nickname: ^[NICKNAME_CAPACITY]u8, length: u8) -> (name: string, refusal: Start_From_Bytes_Refusal) {
	if length == 0 {
		return "", .Empty_Nickname
	}
	if int(length) > NICKNAME_CAPACITY {
		return "", .Nickname_Too_Long
	}
	for index in int(length) ..< NICKNAME_CAPACITY {
		if nickname[index] != 0 {
			return "", .Trailing_Nickname_Bytes
		}
	}
	name = string(nickname[:length])
	refusal = validate_nickname(name)
	if refusal != .None {
		return "", refusal
	}
	return name, .None
}

// classify_disk_start_grant maps a validated start_grant.Grant to the narrow
// set of grants allowed on Start_From_Bytes. System_Part, machine-wide,
// device, principal, and root-ring grants are strictly refused.
@(private = "file")
classify_disk_start_grant :: proc "contextless" (grant: start_grant.Grant) -> (mapped: Disk_Start_Grant, refusal: Start_From_Bytes_Refusal) {
	switch grant {
	case .Store:
		return .Store, .None
	case .System_Part:
		return .Store, .Forbidden_System_Part_Grant
	case .Root_Ring, .Inspect, .Stop, .Image, .Log_Records, .Serve, .Terminal,
		.Acts_For_Principal, .Data_Disk, .Scratch_Disk, .Replacements, .Replace,
		.Network, .Network_Device, .Connect, .Schedule, .Settings, .Clock,
		.History_Store, .Events, .Principals, .Debug_Image, .Debugger, .Palette,
		.Tpm, .Versions_Erase, .Counters, .Remote_Clients, .Sound_Device,
		.Start_Policy, .Screen_Capture:
		return .Store, .Forbidden_Machine_Grant
	}
	return .Store, .Unknown_Grant
}

// validate_start_from_bytes_request verifies every field of a
// Start_From_Bytes_Request against module_bytes at the root core border.
// It checks nickname validity, non-zero budget within bounds, exact BLAKE3
// hash match against module_bytes, well-formed unique import hashes, and
// strictly refuses System_Part, machine, unknown, and duplicate grants.
validate_start_from_bytes_request :: proc "contextless" (request: ^Start_From_Bytes_Request, module_bytes: []u8) -> Start_From_Bytes_Validation {
	if request == nil {
		return {refusal = .Empty_Module_Bytes}
	}
	if _, nick_refusal := request_nickname_slice(&request.nickname, request.nickname_length); nick_refusal != .None {
		return {refusal = nick_refusal}
	}
	if request.budget_pages == 0 || request.budget_pages > DISK_PROCESS_BUDGET_PAGES_LIMIT {
		return {refusal = .Invalid_Budget}
	}
	if request.expected_module_hash == (blake3.Hash{}) {
		return {refusal = .Zero_Module_Hash}
	}
	if len(module_bytes) == 0 {
		return {refusal = .Empty_Module_Bytes}
	}
	if len(module_bytes) > MODULE_BYTES_LIMIT || request.module_byte_count > MODULE_BYTES_LIMIT {
		return {refusal = .Module_Too_Large}
	}
	if u64(len(module_bytes)) != request.module_byte_count {
		return {refusal = .Module_Size_Mismatch}
	}
	computed := blake3.hash(module_bytes)
	if computed != request.expected_module_hash {
		return {refusal = .Hash_Mismatch, computed_hash = computed}
	}

	if request.import_count > IMPORT_HASH_CAPACITY {
		return {refusal = .Too_Many_Imports, computed_hash = computed}
	}
	for index in u32(0) ..< request.import_count {
		imp := request.import_hashes[index]
		if imp == (blake3.Hash{}) {
			return {refusal = .Zero_Import_Hash, computed_hash = computed, offending_index = index}
		}
		if imp == computed {
			return {refusal = .Self_Import_Hash, computed_hash = computed, offending_index = index}
		}
		for earlier in u32(0) ..< index {
			if request.import_hashes[earlier] == imp {
				return {refusal = .Duplicate_Import_Hash, computed_hash = computed, offending_index = index}
			}
		}
	}

	if request.requested_grant_count > GRANT_REQUEST_CAPACITY {
		return {refusal = .Too_Many_Grants, computed_hash = computed}
	}
	parsed_grants: Disk_Start_Grants
	for index in u32(0) ..< request.requested_grant_count {
		word := request.requested_grant_words[index]
		grant, grant_ok := enum_word.member_of_word(start_grant.Grant, word)
		if !grant_ok {
			return {refusal = .Unknown_Grant, computed_hash = computed, offending_index = index}
		}
		mapped, grant_refusal := classify_disk_start_grant(grant)
		if grant_refusal != .None {
			return {refusal = grant_refusal, computed_hash = computed, offending_index = index}
		}
		if mapped in parsed_grants {
			return {refusal = .Duplicate_Grant, computed_hash = computed, offending_index = index}
		}
		parsed_grants += {mapped}
	}

	return {
		refusal       = .None,
		computed_hash = computed,
		grants        = parsed_grants,
	}
}
