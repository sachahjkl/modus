// Persistent disk-module powerbox choices, requestable service allowlist
// entries, and single-call console handle requests
// (src/md/features/powerbox.md).
//
// Contract package: imports base and contract packages only, calls no kernel
// operation, and allocates no memory.
package powerbox

import "modus:contract/blake3"
import "modus:contract/enum_word"
import "modus:contract/text_encoding"

// Inline capacity: fixed table sized for one principal's persisted disk-module
// grant choices without heap allocation.
PERSISTENT_GRANT_TABLE_CAPACITY :: 64

// Plan value: upper bound on requestable service entries registered in one
// powerbox allowlist.
REQUESTABLE_SERVICE_TABLE_CAPACITY :: 32

// Closed set of choice persistence levels offered by a powerbox screen.
// Zero means unset and is refused at the border.
Powerbox_Choice_Persistence :: enum u8 {
	None              = 0,
	Once              = 1,
	This_Run          = 2,
	Always_For_Module = 3,
	Never_Ask_Again   = 4,
}

// Closed set of refusal reasons for persistent disk-module grants, requestable
// service entries, and console missing-handle requests. Zero means accepted.
Powerbox_Persistent_Refusal :: enum u8 {
	None                         = 0,
	Nil_Input                    = 1,
	Boot_Module_Forbidden        = 2,
	Zero_Module_Hash             = 3,
	Bad_Persistence              = 4,
	Bad_Item_Kind                = 5,
	Zero_Target_Hash             = 6,
	Bad_Rights                   = 7,
	Duplicate_Entry              = 8,
	Table_Full                   = 9,
	Not_Found                    = 10,
	Bad_Service_Name             = 11,
	Duplicate_Service            = 12,
	Wide_Service_Forbidden       = 13,
	Acts_For_Principal_Forbidden = 14,
	Zero_Parameter_Index         = 15,
	Bad_Export_Name              = 16,
	Non_Once_Console_Ask         = 17,
	Zero_Asker_Slot              = 18,
	Zero_Request_Serial          = 19,
	Too_Many_Services            = 20,
}

// One persisted powerbox choice bound strictly to the non-zero 32-byte BLAKE3
// hash of a disk module file. Boot-image modules are never persisted here.
Persistent_Module_Grant :: struct {
	active:        bool,
	module_origin: Module_Origin,
	module_hash:   blake3.Hash,
	item_kind:     Request_Item_Kind,
	target_hash:   blake3.Hash,
	rights_word:   u64,
	persistence:   Powerbox_Choice_Persistence,
}

// Fixed-capacity table of persisted disk-module grant choices and permanent
// refusals for one principal.
Persistent_Grant_Table :: struct {
	count:   u32,
	entries: [PERSISTENT_GRANT_TABLE_CAPACITY]Persistent_Module_Grant,
}

// One service allowlist entry describing a caller-scoped service that a running
// process can ask the powerbox to connect to.
Requestable_Service_Entry :: struct {
	name_bytes:         [MAX_NAME_BYTES]u8,
	name_length:        u8,
	acts_for_principal: bool,
	is_wide_service:    bool,
	requires_consent:   bool,
}

// Single-call powerbox lend request formed by the console when a command omits
// a required Handle parameter of a service export.
Console_Handle_Ask :: struct {
	request_serial:       u64,
	console_process_slot: u32,
	principal_id:         u64,
	service_name_bytes:   [MAX_NAME_BYTES]u8,
	service_name_length:  u8,
	export_name_bytes:    [MAX_NAME_BYTES]u8,
	export_name_length:   u8,
	parameter_index:      u32,
	item_kind:            Request_Item_Kind,
	rights_word:          u64,
	persistence:          Powerbox_Choice_Persistence,
}

// powerbox_choice_persistence_from_word converts a raw transport word into a
// Powerbox_Choice_Persistence, refusing zero and every unknown word.
powerbox_choice_persistence_from_word :: proc "contextless" (word: u64) -> (persistence: Powerbox_Choice_Persistence, ok: bool) {
	member := enum_word.member_of_word(Powerbox_Choice_Persistence, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// powerbox_persistent_refusal_from_word converts a raw transport word into a
// Powerbox_Persistent_Refusal, refusing every unknown word.
powerbox_persistent_refusal_from_word :: proc "contextless" (word: u64) -> (refusal: Powerbox_Persistent_Refusal, ok: bool) {
	return enum_word.member_of_word(Powerbox_Persistent_Refusal, word)
}

@(private = "file")
item_rights_valid :: proc "contextless" (kind: Request_Item_Kind, rights_word: u64) -> bool {
	switch kind {
	case .None, .Plan_Difference:
		return false
	case .Network_Endpoint:
		_, ok := network_endpoint_rights_from_word(rights_word)
		return ok
	case .Store_Share:
		_, ok := store_access_mode_from_word(rights_word)
		return ok
	case .Service_Connection:
		return rights_word == 1
	}
	return false
}

@(private = "file")
persistent_bytes_equal :: proc "contextless" (first, second: []u8) -> bool {
	if len(first) != len(second) {
		return false
	}
	for index in 0 ..< len(first) {
		if first[index] != second[index] {
			return false
		}
	}
	return true
}

// persistent_grant_record records an Always_For_Module or Never_Ask_Again
// choice bound to a disk module's non-zero BLAKE3 hash. Refuses boot-image
// modules, zero hashes, non-persistent choices, Plan_Difference items, bad
// rights, duplicate entries, or a full table without mutating table.
persistent_grant_record :: proc "contextless" (
	table: ^Persistent_Grant_Table,
	origin_word: u64,
	module_hash: blake3.Hash,
	item_kind_word: u64,
	target_hash: blake3.Hash,
	rights_word: u64,
	persistence_word: u64,
) -> Powerbox_Persistent_Refusal {
	if table == nil {
		return .Nil_Input
	}
	origin, origin_ok := module_origin_from_word(origin_word)
	if !origin_ok || origin != .Disk_Module {
		return .Boot_Module_Forbidden
	}
	if module_hash == (blake3.Hash{}) {
		return .Zero_Module_Hash
	}
	persistence, persistence_ok := powerbox_choice_persistence_from_word(persistence_word)
	if !persistence_ok {
		return .Bad_Persistence
	}
	switch persistence {
	case .Always_For_Module, .Never_Ask_Again:
	case .None, .Once, .This_Run:
		return .Bad_Persistence
	}
	item_kind, kind_ok := request_item_kind_from_word(item_kind_word)
	if !kind_ok || item_kind == .Plan_Difference {
		return .Bad_Item_Kind
	}
	if target_hash == (blake3.Hash{}) {
		return .Zero_Target_Hash
	}
	switch persistence {
	case .Always_For_Module:
		if !item_rights_valid(item_kind, rights_word) {
			return .Bad_Rights
		}
	case .Never_Ask_Again:
		if rights_word != 0 {
			return .Bad_Rights
		}
	case .None, .Once, .This_Run:
		return .Bad_Persistence
	}

	free_slot := -1
	for &entry, slot in table.entries {
		if !entry.active {
			if free_slot < 0 {
				free_slot = slot
			}
			continue
		}
		if entry.module_hash == module_hash && entry.item_kind == item_kind && entry.target_hash == target_hash {
			return .Duplicate_Entry
		}
	}
	if free_slot < 0 {
		return .Table_Full
	}

	table.entries[free_slot] = Persistent_Module_Grant {
		active        = true,
		module_origin = .Disk_Module,
		module_hash   = module_hash,
		item_kind     = item_kind,
		target_hash   = target_hash,
		rights_word   = rights_word,
		persistence   = persistence,
	}
	table.count += 1
	return .None
}

// persistent_grant_lookup finds a persisted choice for a disk module hash and
// target object. Refuses boot-image modules and zero hashes.
persistent_grant_lookup :: proc "contextless" (
	table: ^Persistent_Grant_Table,
	origin_word: u64,
	module_hash: blake3.Hash,
	item_kind_word: u64,
	target_hash: blake3.Hash,
) -> (entry: Persistent_Module_Grant, found: bool) {
	if table == nil || module_hash == (blake3.Hash{}) || target_hash == (blake3.Hash{}) {
		return {}, false
	}
	origin, origin_ok := module_origin_from_word(origin_word)
	if !origin_ok || origin != .Disk_Module {
		return {}, false
	}
	item_kind, kind_ok := request_item_kind_from_word(item_kind_word)
	if !kind_ok || item_kind == .Plan_Difference {
		return {}, false
	}
	for stored in table.entries {
		if !stored.active {
			continue
		}
		if stored.module_origin == .Disk_Module &&
			stored.module_hash == module_hash &&
			stored.item_kind == item_kind &&
			stored.target_hash == target_hash {
			return stored, true
		}
	}
	return {}, false
}

// persistent_grant_revoke removes one persisted grant or permanent refusal
// identified by (module_hash, item_kind, target_hash).
persistent_grant_revoke :: proc "contextless" (
	table: ^Persistent_Grant_Table,
	module_hash: blake3.Hash,
	item_kind_word: u64,
	target_hash: blake3.Hash,
) -> Powerbox_Persistent_Refusal {
	if table == nil {
		return .Nil_Input
	}
	if module_hash == (blake3.Hash{}) {
		return .Zero_Module_Hash
	}
	item_kind, kind_ok := request_item_kind_from_word(item_kind_word)
	if !kind_ok || item_kind == .Plan_Difference {
		return .Bad_Item_Kind
	}
	if target_hash == (blake3.Hash{}) {
		return .Zero_Target_Hash
	}
	for &stored in table.entries {
		if !stored.active {
			continue
		}
		if stored.module_hash == module_hash && stored.item_kind == item_kind && stored.target_hash == target_hash {
			stored = {}
			if table.count > 0 {
				table.count -= 1
			}
			return .None
		}
	}
	return .Not_Found
}

// persistent_grant_revoke_module removes every persisted grant and permanent
// refusal bound to module_hash, used when a disk module is replaced or removed.
persistent_grant_revoke_module :: proc "contextless" (
	table: ^Persistent_Grant_Table,
	module_hash: blake3.Hash,
) -> (removed: u32, refusal: Powerbox_Persistent_Refusal) {
	if table == nil {
		return 0, .Nil_Input
	}
	if module_hash == (blake3.Hash{}) {
		return 0, .Zero_Module_Hash
	}
	for &stored in table.entries {
		if !stored.active || stored.module_hash != module_hash {
			continue
		}
		stored = {}
		removed += 1
		if table.count > 0 {
			table.count -= 1
		}
	}
	if removed == 0 {
		return 0, .Not_Found
	}
	return removed, .None
}

// requestable_service_build constructs a validated caller-scoped
// Requestable_Service_Entry for name.
requestable_service_build :: proc "contextless" (
	name: string,
	requires_consent: bool,
) -> (entry: Requestable_Service_Entry, refusal: Powerbox_Persistent_Refusal) {
	raw := transmute([]u8)name
	if len(raw) == 0 || len(raw) > MAX_NAME_BYTES || !text_encoding.identifier_valid(raw) {
		return {}, .Bad_Service_Name
	}
	copy(entry.name_bytes[:len(raw)], raw)
	entry.name_length = u8(len(raw))
	entry.acts_for_principal = false
	entry.is_wide_service = false
	entry.requires_consent = requires_consent
	return entry, .None
}

// requestable_service_validate checks one Requestable_Service_Entry at the
// border. Refuses empty or malformed names, wide services, and services that
// act for a whole principal rather than the caller alone.
requestable_service_validate :: proc "contextless" (entry: ^Requestable_Service_Entry) -> Powerbox_Persistent_Refusal {
	if entry == nil {
		return .Nil_Input
	}
	if entry.name_length == 0 || int(entry.name_length) > MAX_NAME_BYTES {
		return .Bad_Service_Name
	}
	if !text_encoding.identifier_valid(entry.name_bytes[:entry.name_length]) {
		return .Bad_Service_Name
	}
	if entry.is_wide_service {
		return .Wide_Service_Forbidden
	}
	if entry.acts_for_principal {
		return .Acts_For_Principal_Forbidden
	}
	return .None
}

// requestable_service_table_validate validates every entry in an allowlist and
// refuses over-capacity tables and duplicate service names.
requestable_service_table_validate :: proc "contextless" (entries: []Requestable_Service_Entry) -> (refusal: Powerbox_Persistent_Refusal, bad_index: u32) {
	if len(entries) > REQUESTABLE_SERVICE_TABLE_CAPACITY {
		return .Too_Many_Services, u32(REQUESTABLE_SERVICE_TABLE_CAPACITY)
	}
	for index in 0 ..< len(entries) {
		candidate := entries[index]
		entry_refusal := requestable_service_validate(&candidate)
		if entry_refusal != .None {
			return entry_refusal, u32(index)
		}
		for earlier in 0 ..< index {
			if persistent_bytes_equal(
				entries[earlier].name_bytes[:entries[earlier].name_length],
				candidate.name_bytes[:candidate.name_length],
			) {
				return .Duplicate_Service, u32(index)
			}
		}
	}
	return .None, 0
}

// requestable_service_table_find returns the matching Requestable_Service_Entry
// when name matches a validated entry in entries.
requestable_service_table_find :: proc "contextless" (
	entries: []Requestable_Service_Entry,
	name: []u8,
) -> (entry: Requestable_Service_Entry, found: bool) {
	if len(name) == 0 || len(name) > MAX_NAME_BYTES || !text_encoding.identifier_valid(name) {
		return {}, false
	}
	for candidate in entries {
		local := candidate
		if requestable_service_validate(&local) != .None {
			continue
		}
		if persistent_bytes_equal(local.name_bytes[:local.name_length], name) {
			return local, true
		}
	}
	return {}, false
}

// console_missing_handle_request forms a single-call powerbox lend request
// with the console as asker when an export's Handle parameter is omitted.
// Refuses zero serial, zero console slot, bad service or export names, zero
// parameter index, non-ordinary item kinds, bad rights, or any persistence
// other than Once.
console_missing_handle_request :: proc "contextless" (
	request_serial: u64,
	console_process_slot: u32,
	principal_id: u64,
	service_name: []u8,
	export_name: []u8,
	parameter_index: u32,
	item_kind_word: u64,
	rights_word: u64,
	persistence_word: u64,
) -> (ask: Console_Handle_Ask, refusal: Powerbox_Persistent_Refusal) {
	if request_serial == 0 {
		return {}, .Zero_Request_Serial
	}
	if console_process_slot == 0 {
		return {}, .Zero_Asker_Slot
	}
	if len(service_name) == 0 || len(service_name) > MAX_NAME_BYTES || !text_encoding.identifier_valid(service_name) {
		return {}, .Bad_Service_Name
	}
	if len(export_name) == 0 || len(export_name) > MAX_NAME_BYTES || !text_encoding.identifier_valid(export_name) {
		return {}, .Bad_Export_Name
	}
	if parameter_index == 0 {
		return {}, .Zero_Parameter_Index
	}
	item_kind, kind_ok := request_item_kind_from_word(item_kind_word)
	if !kind_ok || item_kind == .Plan_Difference {
		return {}, .Bad_Item_Kind
	}
	if !item_rights_valid(item_kind, rights_word) {
		return {}, .Bad_Rights
	}
	persistence, persistence_ok := powerbox_choice_persistence_from_word(persistence_word)
	if !persistence_ok {
		return {}, .Bad_Persistence
	}
	if persistence != .Once {
		return {}, .Non_Once_Console_Ask
	}

	ask = Console_Handle_Ask {
		request_serial       = request_serial,
		console_process_slot = console_process_slot,
		principal_id         = principal_id,
		service_name_length  = u8(len(service_name)),
		export_name_length   = u8(len(export_name)),
		parameter_index      = parameter_index,
		item_kind            = item_kind,
		rights_word          = rights_word,
		persistence          = .Once,
	}
	copy(ask.service_name_bytes[:len(service_name)], service_name)
	copy(ask.export_name_bytes[:len(export_name)], export_name)
	return ask, .None
}
