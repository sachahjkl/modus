// Pure state machine for the delegated principals service
// (src/md/api/root_service_split.md).
//
// Manages named principal records and session lifecycle, principal disk grant
// tables strictly restricted to Store, one Start_Policy for principal 0, and
// Client_Key rows via root_delegation.Disk_Rows_Set_Request, live client keys
// of remote and remote_display, and principal 0 start policy choices.
//
// Every refusal happens before domain state mutation. Allocates no memory and
// calls no kernel operation.
package principals_core

import "modus:contract/blake3"
import "modus:contract/remote"
import "modus:contract/role_contract"
import rd "modus:contract/root_delegation"
import "modus:principals"

// Fixed capacities of the principals service state.
MAX_PRINCIPALS :: 8
MACHINE_PRINCIPAL_NAME :: "machine"

#assert(MAX_PRINCIPALS >= 2)

// Lifecycle state of one principal slot.
Session_State :: enum u8 {
	Absent = 0,
	Locked = 1,
	Active = 2,
}

// Why a principals_core operation refused its input.
Principals_Refusal :: enum u8 {
	None                                   = 0,
	Uninitialized                          = 1,
	Unknown_Principal                      = 2,
	Invalid_Principal_Id                   = 3,
	Duplicate_Principal                    = 4,
	Principals_Full                        = 5,
	Invalid_Principal_Name                 = 6,
	Duplicate_Principal_Name               = 7,
	Zero_Public_Key                        = 8,
	Duplicate_Public_Key                   = 9,
	Invalid_Session_Action                 = 10,
	Session_State_Conflict                 = 11,
	Machine_Principal_Protected            = 12,
	Border_Validation                      = 13,
	Stale_Generation                       = 14,
	Zero_Client_Key                        = 15,
	Bad_Client_Uses                        = 16,
	Duplicate_Client_Key                   = 17,
	Principal_Client_Limit                 = 18,
	Client_Table_Full                      = 19,
	Client_Key_Not_Found                   = 20,
	Wrong_Principal                        = 21,
	Start_Policy_Requires_Principal_Zero   = 22,
	Start_Policy_Forbidden_With_Passphrase = 23,
	Invalid_Nickname                       = 24,
	Zero_Module_Hash                       = 25,
	Duplicate_Nickname                     = 26,
	Store_Row_Limit_Exceeded               = 27,
	Invalid_Client_Key_Action              = 28,
	Invalid_Start_Policy_Action            = 29,
	Trailing_Name_Bytes                    = 30,
}

// One Store disk grant row owned by a principal.
Store_Grant_Row :: struct {
	active:          bool,
	nickname:        [rd.NICKNAME_CAPACITY]u8,
	nickname_length: u8,
	module_hash:     blake3.Hash,
	store_blocks:    u64,
}

// Principal 0's persisted choice of a start policy module from disk.
Start_Policy_Choice :: struct {
	active:          bool,
	nickname:        [rd.NICKNAME_CAPACITY]u8,
	nickname_length: u8,
	module_hash:     blake3.Hash,
}

// One registered principal record and its disk grant table state.
Principal_Entry :: struct {
	active:           bool,
	id:               u64,
	state:            Session_State,
	name:             [rd.PRINCIPAL_NAME_CAPACITY]u8,
	name_length:      u8,
	public_key:       [32]u8,
	session_serial:   u64,
	table_generation: u64,
	store_rows:       [rd.STORE_ROWS_LIMIT]Store_Grant_Row,
	store_row_count:  u32,
}

// Operational counters exposed through the principals service status export.
Principals_Counters :: struct {
	principal_count:      u64,
	active_sessions:      u64,
	disk_rows_applied:    u64,
	active_client_keys:   u64,
	start_policy_updates: u64,
	total_refusals:       u64,
}

// Fixed-capacity state of the delegated principals service.
Principals_State :: struct {
	initialized:                 bool,
	principals:                  [MAX_PRINCIPALS]Principal_Entry,
	front_principal:             u64,
	start_policy:                Start_Policy_Choice,
	machine_passphrase_required: bool,
	client_table:                remote.Client_Table,
	next_client_serial:          u64,
	counters:                    Principals_Counters,
}

// state_init resets state and installs principal 0 (the machine) in Active
// state as the initial front principal.
state_init :: proc "contextless" (state: ^Principals_State) {
	if state == nil {
		return
	}
	state^ = {}
	machine := &state.principals[0]
	machine.active = true
	machine.id = role_contract.MACHINE_PRINCIPAL
	machine.state = .Active
	machine.session_serial = 1
	copy(machine.name[:], MACHINE_PRINCIPAL_NAME)
	machine.name_length = u8(len(MACHINE_PRINCIPAL_NAME))
	state.front_principal = role_contract.MACHINE_PRINCIPAL
	state.next_client_serial = 1
	state.counters.principal_count = 1
	state.counters.active_sessions = 1
	state.initialized = true
}

@(private = "file")
find_principal_index :: proc "contextless" (state: ^Principals_State, principal_id: u64) -> int {
	for &entry, idx in state.principals {
		if entry.active && entry.id == principal_id {
			return idx
		}
	}
	return -1
}

@(private = "file")
validate_principal_name :: proc "contextless" (bytes: ^[rd.PRINCIPAL_NAME_CAPACITY]u8, length: u8) -> Principals_Refusal {
	if length == 0 || int(length) > rd.PRINCIPAL_NAME_CAPACITY {
		return .Invalid_Principal_Name
	}
	for idx in int(length) ..< rd.PRINCIPAL_NAME_CAPACITY {
		if bytes[idx] != 0 {
			return .Trailing_Name_Bytes
		}
	}
	// The core takes a name of a principal by the rule of the principals
	// library: a stricter rule here would refuse a principal that the core
	// holds, and the mirror of the core would lose it.
	if principals.name_problem(string(bytes[:length])) != .None {
		return .Invalid_Principal_Name
	}
	if string(bytes[:length]) == MACHINE_PRINCIPAL_NAME {
		return .Duplicate_Principal_Name
	}
	return .None
}

@(private = "file")
validate_nickname_field :: proc "contextless" (bytes: ^[rd.NICKNAME_CAPACITY]u8, length: u8) -> (name: string, refusal: Principals_Refusal) {
	if length == 0 || int(length) > rd.NICKNAME_CAPACITY {
		return "", .Invalid_Nickname
	}
	for idx in int(length) ..< rd.NICKNAME_CAPACITY {
		if bytes[idx] != 0 {
			return "", .Trailing_Name_Bytes
		}
	}
	candidate := string(bytes[:length])
	if rd.validate_nickname(candidate) != .None {
		return "", .Invalid_Nickname
	}
	return candidate, .None
}

@(private = "file")
next_serial :: proc "contextless" (state: ^Principals_State) -> u64 {
	serial := state.next_client_serial
	state.next_client_serial += 1
	if state.next_client_serial == 0 {
		state.next_client_serial = 1
	}
	return serial
}

@(private = "file")
sync_client_table_front :: proc "contextless" (state: ^Principals_State) {
	state.client_table.version += 1
	for &row in state.client_table.clients {
		if row.serial == 0 {
			continue
		}
		row.not_in_front = u64(remote.client_display_paused(row.principal, state.front_principal))
	}
	state.client_table.version += 1
}

// register_principal adds a named principal in Locked state, refusing
// principal 0, duplicate IDs/names/keys, invalid names, zero keys, and full
// capacity with zero domain state mutation.
register_principal :: proc "contextless" (state: ^Principals_State, input: ^rd.Register_Principal_Input) -> Principals_Refusal {
	if state == nil || !state.initialized || input == nil {
		return .Uninitialized
	}
	if input.principal_id == role_contract.MACHINE_PRINCIPAL {
		state.counters.total_refusals += 1
		return .Invalid_Principal_Id
	}
	if name_ref := validate_principal_name(&input.name, input.name_length); name_ref != .None {
		state.counters.total_refusals += 1
		return name_ref
	}
	if input.public_key == ([32]u8{}) {
		state.counters.total_refusals += 1
		return .Zero_Public_Key
	}

	candidate_name := string(input.name[:input.name_length])
	free_index := -1
	for &entry, idx in state.principals {
		if !entry.active {
			if free_index < 0 {
				free_index = idx
			}
			continue
		}
		if entry.id == input.principal_id {
			state.counters.total_refusals += 1
			return .Duplicate_Principal
		}
		if string(entry.name[:entry.name_length]) == candidate_name {
			state.counters.total_refusals += 1
			return .Duplicate_Principal_Name
		}
		if entry.public_key == input.public_key {
			state.counters.total_refusals += 1
			return .Duplicate_Public_Key
		}
	}
	if free_index < 0 {
		state.counters.total_refusals += 1
		return .Principals_Full
	}

	slot := &state.principals[free_index]
	slot^ = {}
	slot.active = true
	slot.id = input.principal_id
	slot.state = .Locked
	slot.name = input.name
	slot.name_length = input.name_length
	slot.public_key = input.public_key
	state.counters.principal_count += 1
	return .None
}

// session_transition applies a validated Session_Action to a registered
// principal, updating session lock state, front-principal display pausing,
// and client key serials atomically.
session_transition :: proc "contextless" (state: ^Principals_State, input: ^rd.Session_Transition_Input) -> Principals_Refusal {
	if state == nil || !state.initialized || input == nil {
		return .Uninitialized
	}
	action, ok := rd.session_action_from_word(input.action_word)
	if !ok {
		state.counters.total_refusals += 1
		return .Invalid_Session_Action
	}
	idx := find_principal_index(state, input.principal_id)
	if idx < 0 {
		state.counters.total_refusals += 1
		return .Unknown_Principal
	}
	entry := &state.principals[idx]

	switch action {
	case .None:
		state.counters.total_refusals += 1
		return .Invalid_Session_Action

	case .Unlock:
		if entry.id == role_contract.MACHINE_PRINCIPAL {
			state.counters.total_refusals += 1
			return .Machine_Principal_Protected
		}
		if entry.state != .Locked {
			state.counters.total_refusals += 1
			return .Session_State_Conflict
		}
		entry.state = .Active
		entry.session_serial += 1
		state.counters.active_sessions += 1
		state.client_table.version += 1
		for &row in state.client_table.clients {
			if row.serial != 0 && row.principal == entry.id {
				row.session_locked = 0
				row.serial = next_serial(state)
				row.not_in_front = u64(remote.client_display_paused(row.principal, state.front_principal))
			}
		}
		state.client_table.version += 1
		return .None

	case .Lock, .Stop_Session:
		if entry.id == role_contract.MACHINE_PRINCIPAL {
			state.counters.total_refusals += 1
			return .Machine_Principal_Protected
		}
		if entry.state != .Active {
			state.counters.total_refusals += 1
			return .Session_State_Conflict
		}
		entry.state = .Locked
		state.counters.active_sessions -= 1
		if state.front_principal == entry.id {
			state.front_principal = role_contract.MACHINE_PRINCIPAL
		}
		state.client_table.version += 1
		for &row in state.client_table.clients {
			if row.serial == 0 {
				continue
			}
			if row.principal == entry.id {
				row.session_locked = 1
				row.serial = next_serial(state)
			}
			row.not_in_front = u64(remote.client_display_paused(row.principal, state.front_principal))
		}
		state.client_table.version += 1
		return .None

	case .Bring_To_Front:
		if entry.state != .Active {
			state.counters.total_refusals += 1
			return .Session_State_Conflict
		}
		state.front_principal = entry.id
		sync_client_table_front(state)
		return .None
	}

	state.counters.total_refusals += 1
	return .Invalid_Session_Action
}

// apply_disk_rows_set validates a Disk_Rows_Set_Request through the strict
// root_delegation border and atomically installs the principal's Store rows,
// principal-0 Start_Policy choice, and Client_Key rows. Any refusal leaves all
// domain state unchanged.
apply_disk_rows_set :: proc "contextless" (
	state: ^Principals_State,
	request: ^rd.Disk_Rows_Set_Request,
) -> (
	refusal: Principals_Refusal,
	border_refusal: rd.Disk_Rows_Set_Refusal,
) {
	if state == nil || !state.initialized || request == nil {
		return .Uninitialized, .None
	}
	validation := rd.validate_disk_rows_set_request(request)
	if validation.refusal != .None {
		state.counters.total_refusals += 1
		return .Border_Validation, validation.refusal
	}
	idx := find_principal_index(state, request.principal)
	if idx < 0 {
		state.counters.total_refusals += 1
		return .Unknown_Principal, .None
	}
	entry := &state.principals[idx]
	if entry.state != .Active {
		state.counters.total_refusals += 1
		return .Session_State_Conflict, .None
	}
	if request.generation <= entry.table_generation {
		state.counters.total_refusals += 1
		return .Stale_Generation, .None
	}
	if validation.start_policy_row_count > 0 && state.machine_passphrase_required {
		state.counters.total_refusals += 1
		return .Start_Policy_Forbidden_With_Passphrase, .None
	}

	// Pre-validate cross-principal client key uniqueness and global table
	// capacity before mutating any state.
	other_principal_keys := u32(0)
	for &row in state.client_table.clients {
		if row.serial != 0 && row.principal != request.principal {
			other_principal_keys += 1
		}
	}
	if other_principal_keys + validation.client_key_row_count > remote.CLIENT_CAPACITY {
		state.counters.total_refusals += 1
		return .Client_Table_Full, .None
	}
	for row_idx in u32(0) ..< request.row_count {
		req_row := &request.rows[row_idx]
		class, _ := rd.disk_row_class_from_word(u64(req_row.class_word))
		if class != .Client_Key {
			continue
		}
		for &existing in state.client_table.clients {
			if existing.serial != 0 && existing.principal != request.principal && existing.key == req_row.client_key {
				state.counters.total_refusals += 1
				return .Duplicate_Client_Key, .None
			}
		}
	}

	// All checks passed: commit store rows, start policy, and client keys.
	entry.store_rows = {}
	entry.store_row_count = 0
	if request.principal == role_contract.MACHINE_PRINCIPAL {
		state.start_policy = {}
	}

	state.client_table.version += 1
	removed_keys := u64(0)
	for &existing in state.client_table.clients {
		if existing.serial != 0 && existing.principal == request.principal {
			existing = {}
			removed_keys += 1
		}
	}
	state.counters.active_client_keys -= removed_keys

	for row_idx in u32(0) ..< request.row_count {
		req_row := &request.rows[row_idx]
		class, _ := rd.disk_row_class_from_word(u64(req_row.class_word))
		switch class {
		case .None:
		case .Store:
			dest := &entry.store_rows[entry.store_row_count]
			dest.active = true
			dest.nickname = req_row.nickname
			dest.nickname_length = req_row.nickname_length
			dest.module_hash = req_row.module_hash
			dest.store_blocks = req_row.store_blocks
			entry.store_row_count += 1

		case .Start_Policy:
			state.start_policy = {
				active          = true,
				nickname        = req_row.nickname,
				nickname_length = req_row.nickname_length,
				module_hash     = req_row.module_hash,
			}
			state.counters.start_policy_updates += 1

		case .Client_Key:
			for &slot in state.client_table.clients {
				if slot.serial == 0 {
					slot = {
						key            = req_row.client_key,
						principal      = request.principal,
						serial         = next_serial(state),
						session_locked = 0,
						contested      = 0,
						uses           = req_row.client_uses_word,
						not_in_front   = u64(remote.client_display_paused(request.principal, state.front_principal)),
					}
					state.counters.active_client_keys += 1
					break
				}
			}
		}
	}
	state.client_table.version += 1

	entry.table_generation = request.generation
	state.counters.disk_rows_applied += 1
	return .None, .None
}

// client_key_command executes Allow or Revoke for a principal's remote client
// key, refusing unknown actions, locked sessions, invalid uses, duplicate
// keys, cross-principal revocations, and capacity overflow.
client_key_command :: proc "contextless" (state: ^Principals_State, input: ^rd.Client_Key_Input) -> (serial: u64, refusal: Principals_Refusal) {
	if state == nil || !state.initialized || input == nil {
		return 0, .Uninitialized
	}
	action, ok := rd.client_key_action_from_word(input.action_word)
	if !ok {
		state.counters.total_refusals += 1
		return 0, .Invalid_Client_Key_Action
	}
	idx := find_principal_index(state, input.principal_id)
	if idx < 0 {
		state.counters.total_refusals += 1
		return 0, .Unknown_Principal
	}
	entry := &state.principals[idx]
	if input.client_key == ([32]u8{}) {
		state.counters.total_refusals += 1
		return 0, .Zero_Client_Key
	}

	switch action {
	case .None:
		state.counters.total_refusals += 1
		return 0, .Invalid_Client_Key_Action

	case .Allow:
		if entry.state != .Active {
			state.counters.total_refusals += 1
			return 0, .Session_State_Conflict
		}
		if _, uses_ok := remote.client_uses_of_word(input.client_uses_word); !uses_ok {
			state.counters.total_refusals += 1
			return 0, .Bad_Client_Uses
		}
		principal_rows := u32(0)
		free_slot := -1
		for &row, slot_idx in state.client_table.clients {
			if row.serial == 0 {
				if free_slot < 0 {
					free_slot = slot_idx
				}
				continue
			}
			if row.key == input.client_key {
				state.counters.total_refusals += 1
				return 0, .Duplicate_Client_Key
			}
			if row.principal == input.principal_id {
				principal_rows += 1
			}
		}
		if principal_rows >= remote.CLIENT_ROWS_OF_ONE_PRINCIPAL {
			state.counters.total_refusals += 1
			return 0, .Principal_Client_Limit
		}
		if free_slot < 0 {
			state.counters.total_refusals += 1
			return 0, .Client_Table_Full
		}

		assigned := next_serial(state)
		state.client_table.version += 1
		state.client_table.clients[free_slot] = {
			key            = input.client_key,
			principal      = input.principal_id,
			serial         = assigned,
			session_locked = 0,
			contested      = 0,
			uses           = input.client_uses_word,
			not_in_front   = u64(remote.client_display_paused(input.principal_id, state.front_principal)),
		}
		state.client_table.version += 1
		state.counters.active_client_keys += 1
		return assigned, .None

	case .Revoke:
		for &row in state.client_table.clients {
			if row.serial != 0 && row.key == input.client_key {
				if row.principal != input.principal_id {
					state.counters.total_refusals += 1
					return 0, .Wrong_Principal
				}
				state.client_table.version += 1
				row = {}
				state.client_table.version += 1
				state.counters.active_client_keys -= 1
				return 0, .None
			}
		}
		state.counters.total_refusals += 1
		return 0, .Client_Key_Not_Found
	}

	state.counters.total_refusals += 1
	return 0, .Invalid_Client_Key_Action
}

// client_key_lookup finds an active client key entry in the live client table.
client_key_lookup :: proc "contextless" (state: ^Principals_State, key: [32]u8) -> (row: remote.Client, found: bool) {
	if state == nil || !state.initialized || key == ([32]u8{}) {
		return {}, false
	}
	for &slot in state.client_table.clients {
		if slot.serial != 0 && slot.key == key {
			return slot, true
		}
	}
	return {}, false
}

// start_policy_command validates and applies a principal 0 start policy
// choice update. Non-principal-0 callers are always refused.
start_policy_command :: proc "contextless" (state: ^Principals_State, input: ^rd.Start_Policy_Input) -> Principals_Refusal {
	if state == nil || !state.initialized || input == nil {
		return .Uninitialized
	}
	action, ok := rd.start_policy_action_from_word(input.action_word)
	if !ok {
		state.counters.total_refusals += 1
		return .Invalid_Start_Policy_Action
	}
	if input.principal_id != role_contract.MACHINE_PRINCIPAL {
		state.counters.total_refusals += 1
		return .Start_Policy_Requires_Principal_Zero
	}
	machine := &state.principals[0]

	switch action {
	case .None:
		state.counters.total_refusals += 1
		return .Invalid_Start_Policy_Action

	case .Set_Passphrase_Required:
		state.machine_passphrase_required = input.passphrase_required
		if input.passphrase_required && state.start_policy.active {
			state.start_policy = {}
			state.counters.start_policy_updates += 1
		}
		return .None

	case .Clear_Choice:
		state.start_policy = {}
		state.counters.start_policy_updates += 1
		return .None

	case .Set_Choice:
		if state.machine_passphrase_required {
			state.counters.total_refusals += 1
			return .Start_Policy_Forbidden_With_Passphrase
		}
		candidate_name, name_ref := validate_nickname_field(&input.nickname, input.nickname_length)
		if name_ref != .None {
			state.counters.total_refusals += 1
			return name_ref
		}
		if input.module_hash == (blake3.Hash{}) {
			state.counters.total_refusals += 1
			return .Zero_Module_Hash
		}
		for row_idx in u32(0) ..< machine.store_row_count {
			existing := &machine.store_rows[row_idx]
			if existing.active && string(existing.nickname[:existing.nickname_length]) == candidate_name {
				state.counters.total_refusals += 1
				return .Duplicate_Nickname
			}
		}
		if !state.start_policy.active && machine.store_row_count >= rd.STORE_ROWS_LIMIT {
			state.counters.total_refusals += 1
			return .Store_Row_Limit_Exceeded
		}
		state.start_policy = {
			active          = true,
			nickname        = input.nickname,
			nickname_length = input.nickname_length,
			module_hash     = input.module_hash,
		}
		state.counters.start_policy_updates += 1
		return .None
	}

	state.counters.total_refusals += 1
	return .Invalid_Start_Policy_Action
}

// build_disk_rows_set_request materializes a principal's current Store rows,
// principal-0 Start_Policy row, and Client_Key rows into a border-validated
// Disk_Rows_Set_Request ready for the root core.
build_disk_rows_set_request :: proc "contextless" (
	state: ^Principals_State,
	principal_id: u64,
) -> (
	request: rd.Disk_Rows_Set_Request,
	refusal: Principals_Refusal,
) {
	if state == nil || !state.initialized {
		return {}, .Uninitialized
	}
	idx := find_principal_index(state, principal_id)
	if idx < 0 {
		return {}, .Unknown_Principal
	}
	entry := &state.principals[idx]
	request.principal = principal_id
	request.generation = entry.table_generation + 1

	for row_idx in u32(0) ..< entry.store_row_count {
		row := &entry.store_rows[row_idx]
		if !row.active {
			continue
		}
		request.rows[request.row_count] = {
			class_word      = u32(rd.Disk_Row_Class.Store),
			nickname        = row.nickname,
			nickname_length = row.nickname_length,
			module_hash     = row.module_hash,
			store_blocks    = row.store_blocks,
		}
		request.row_count += 1
	}

	if principal_id == role_contract.MACHINE_PRINCIPAL && state.start_policy.active {
		request.rows[request.row_count] = {
			class_word      = u32(rd.Disk_Row_Class.Start_Policy),
			nickname        = state.start_policy.nickname,
			nickname_length = state.start_policy.nickname_length,
			module_hash     = state.start_policy.module_hash,
		}
		request.row_count += 1
	}

	for &client in state.client_table.clients {
		if client.serial == 0 || client.principal != principal_id {
			continue
		}
		request.rows[request.row_count] = {
			class_word       = u32(rd.Disk_Row_Class.Client_Key),
			client_key       = client.key,
			client_uses_word = client.uses,
		}
		request.row_count += 1
	}

	validation := rd.validate_disk_rows_set_request(&request)
	if validation.refusal != .None {
		return {}, .Border_Validation
	}
	return request, .None
}
