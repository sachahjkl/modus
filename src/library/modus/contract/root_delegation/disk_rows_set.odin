// Contract between the delegated principals service and the root service core
// for updating a principal's disk grant rows (src/md/api/root_service_split.md).
//
// Disk_Rows_Set accepts only the narrow disk grant classes: Store rows, at
// most one Start_Policy row (for principal 0 only), and Client_Key rows with
// validated remote client uses. Any unknown class or out-of-scope field is
// refused whole before mutating core state.
package root_delegation

import "modus:contract/blake3"
import "modus:contract/enum_word"
import "modus:contract/remote"
import "modus:contract/role_contract"

// Maximum total rows accepted in a single Disk_Rows_Set_Request: up to
// STORE_ROWS_LIMIT disk process rows plus CLIENT_KEY_ROWS_LIMIT client keys.
STORE_ROWS_LIMIT :: 16
CLIENT_KEY_ROWS_LIMIT :: remote.CLIENT_ROWS_OF_ONE_PRINCIPAL
DISK_ROWS_CAPACITY :: STORE_ROWS_LIMIT + CLIENT_KEY_ROWS_LIMIT

// Maximum blocks that a Store row may grant to a disk process, matching the
// module_files store ceiling.
STORE_BLOCKS_LIMIT :: 4096

// Context handle slots used by the delegated principals service.
PRINCIPALS_RING_SLOT :: 10
PRINCIPALS_REGION_SLOT :: 11

// Commands accepted on the delegated principals service ring.
// Zero means unset and is refused at the border.
Principals_Ring_Command :: enum u32 {
	None                 = 0,
	Register_Principal   = 1,
	Session_Transition   = 2,
	Replace_Disk_Rows    = 3,
	Client_Key_Command   = 4,
	Start_Policy_Command = 5,
}

// Completion statuses returned on the delegated principals service ring.
Principals_Ring_Status :: enum u32 {
	Ok          = 0,
	Refused     = 1,
	Bad_Command = 2,
}

// Closed set of row classes that principals may push to the root core via
// Disk_Rows_Set. Zero means unset and is refused at the border.
Disk_Row_Class :: enum u32 {
	None         = 0,
	Store        = 1,
	Start_Policy = 2,
	Client_Key   = 3,
}

// Why validate_disk_rows_set_request refused a Disk_Rows_Set_Request.
Disk_Rows_Set_Refusal :: enum u8 {
	None                               = 0,
	Zero_Generation                    = 1,
	Too_Many_Rows                      = 2,
	Unknown_Row_Class                  = 3,
	Invalid_Nickname                   = 4,
	Zero_Module_Hash                   = 5,
	Duplicate_Nickname                 = 6,
	Store_Blocks_Out_Of_Range          = 7,
	Multiple_Start_Policy_Rows         = 8,
	Start_Policy_Requires_Principal_Zero = 9,
	Zero_Client_Key                    = 10,
	Bad_Client_Uses                    = 11,
	Duplicate_Client_Key               = 12,
	Store_Row_Limit_Exceeded           = 13,
	Client_Key_Limit_Exceeded          = 14,
	Unexpected_Field_Data              = 15,
}

// One row inside a Disk_Rows_Set_Request. Unused fields for the selected class
// must be zero so callers cannot smuggle hidden attributes across the border.
Disk_Row_Entry :: struct {
	class_word:       u32,
	nickname:         [NICKNAME_CAPACITY]u8,
	nickname_length:  u8,
	module_hash:      blake3.Hash,
	store_blocks:     u64,
	client_key:       [32]u8,
	client_uses_word: u64,
}

// Whole replacement set of disk grant rows pushed from principals to the root
// core for a single principal.
Disk_Rows_Set_Request :: struct {
	principal:  u64,
	generation: u64,
	row_count:  u32,
	rows:       [DISK_ROWS_CAPACITY]Disk_Row_Entry,
}

// Validation summary returned by validate_disk_rows_set_request.
Disk_Rows_Set_Validation :: struct {
	refusal:                Disk_Rows_Set_Refusal,
	offending_index:        u32,
	store_row_count:        u32,
	start_policy_row_count: u32,
	client_key_row_count:   u32,
}

// principals_ring_command_from_word converts a ring command word into a
// Principals_Ring_Command, refusing zero and every unknown word.
principals_ring_command_from_word :: proc "contextless" (word: u32) -> (command: Principals_Ring_Command, ok: bool) {
	member := enum_word.member_of_word(Principals_Ring_Command, u64(word)) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// principals_ring_status_from_word converts a completion status word into a
// Principals_Ring_Status, refusing every unknown word.
principals_ring_status_from_word :: proc "contextless" (word: u32) -> (status: Principals_Ring_Status, ok: bool) {
	return enum_word.member_of_word(Principals_Ring_Status, u64(word))
}

// disk_row_class_from_word converts a transport word into a Disk_Row_Class,
// refusing zero and every unknown value.
disk_row_class_from_word :: proc "contextless" (word: u64) -> (class: Disk_Row_Class, ok: bool) {
	member := enum_word.member_of_word(Disk_Row_Class, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

@(private = "file")
nickname_bytes_all_zero :: proc "contextless" (bytes: ^[NICKNAME_CAPACITY]u8) -> bool {
	for b in bytes^ {
		if b != 0 {
			return false
		}
	}
	return true
}

@(private = "file")
entry_nickname_valid :: proc "contextless" (entry: ^Disk_Row_Entry) -> (name: string, ok: bool) {
	if entry.nickname_length == 0 || int(entry.nickname_length) > NICKNAME_CAPACITY {
		return "", false
	}
	for index in int(entry.nickname_length) ..< NICKNAME_CAPACITY {
		if entry.nickname[index] != 0 {
			return "", false
		}
	}
	candidate := string(entry.nickname[:entry.nickname_length])
	if validate_nickname(candidate) != .None {
		return "", false
	}
	return candidate, true
}

// validate_disk_rows_set_request enforces the strict border rules of
// Disk_Rows_Set: only Store, at most one Start_Policy (for principal 0), and
// Client_Key rows are accepted, with unique nicknames, unique client keys,
// bounded block counts, valid remote client uses, and zeroed unused fields.
validate_disk_rows_set_request :: proc "contextless" (request: ^Disk_Rows_Set_Request) -> Disk_Rows_Set_Validation {
	if request == nil || request.generation == 0 {
		return {refusal = .Zero_Generation}
	}
	if request.row_count > DISK_ROWS_CAPACITY {
		return {refusal = .Too_Many_Rows}
	}

	store_rows := u32(0)
	start_policy_rows := u32(0)
	client_key_rows := u32(0)
	disk_process_rows := u32(0)

	for index in u32(0) ..< request.row_count {
		entry := &request.rows[index]
		class, class_ok := disk_row_class_from_word(u64(entry.class_word))
		if !class_ok {
			return {refusal = .Unknown_Row_Class, offending_index = index}
		}

		switch class {
		case .None:
			return {refusal = .Unknown_Row_Class, offending_index = index}
		case .Store:
			if entry.client_key != ([32]u8{}) || entry.client_uses_word != 0 {
				return {refusal = .Unexpected_Field_Data, offending_index = index}
			}
			name, name_ok := entry_nickname_valid(entry)
			if !name_ok {
				return {refusal = .Invalid_Nickname, offending_index = index}
			}
			if entry.module_hash == (blake3.Hash{}) {
				return {refusal = .Zero_Module_Hash, offending_index = index}
			}
			if entry.store_blocks > STORE_BLOCKS_LIMIT {
				return {refusal = .Store_Blocks_Out_Of_Range, offending_index = index}
			}
			for earlier_index in u32(0) ..< index {
				earlier := &request.rows[earlier_index]
				earlier_class, _ := disk_row_class_from_word(u64(earlier.class_word))
				if earlier_class == .Store || earlier_class == .Start_Policy {
					if string(earlier.nickname[:earlier.nickname_length]) == name {
						return {refusal = .Duplicate_Nickname, offending_index = index}
					}
				}
			}
			disk_process_rows += 1
			if disk_process_rows > STORE_ROWS_LIMIT {
				return {refusal = .Store_Row_Limit_Exceeded, offending_index = index}
			}
			store_rows += 1

		case .Start_Policy:
			if entry.client_key != ([32]u8{}) || entry.client_uses_word != 0 || entry.store_blocks != 0 {
				return {refusal = .Unexpected_Field_Data, offending_index = index}
			}
			if request.principal != role_contract.MACHINE_PRINCIPAL {
				return {refusal = .Start_Policy_Requires_Principal_Zero, offending_index = index}
			}
			if start_policy_rows >= 1 {
				return {refusal = .Multiple_Start_Policy_Rows, offending_index = index}
			}
			name, name_ok := entry_nickname_valid(entry)
			if !name_ok {
				return {refusal = .Invalid_Nickname, offending_index = index}
			}
			if entry.module_hash == (blake3.Hash{}) {
				return {refusal = .Zero_Module_Hash, offending_index = index}
			}
			for earlier_index in u32(0) ..< index {
				earlier := &request.rows[earlier_index]
				earlier_class, _ := disk_row_class_from_word(u64(earlier.class_word))
				if earlier_class == .Store || earlier_class == .Start_Policy {
					if string(earlier.nickname[:earlier.nickname_length]) == name {
						return {refusal = .Duplicate_Nickname, offending_index = index}
					}
				}
			}
			disk_process_rows += 1
			if disk_process_rows > STORE_ROWS_LIMIT {
				return {refusal = .Store_Row_Limit_Exceeded, offending_index = index}
			}
			start_policy_rows += 1

		case .Client_Key:
			if entry.nickname_length != 0 || !nickname_bytes_all_zero(&entry.nickname) || entry.module_hash != (blake3.Hash{}) || entry.store_blocks != 0 {
				return {refusal = .Unexpected_Field_Data, offending_index = index}
			}
			if entry.client_key == ([32]u8{}) {
				return {refusal = .Zero_Client_Key, offending_index = index}
			}
			if _, uses_ok := remote.client_uses_of_word(entry.client_uses_word); !uses_ok {
				return {refusal = .Bad_Client_Uses, offending_index = index}
			}
			for earlier_index in u32(0) ..< index {
				earlier := &request.rows[earlier_index]
				earlier_class, _ := disk_row_class_from_word(u64(earlier.class_word))
				if earlier_class == .Client_Key && earlier.client_key == entry.client_key {
					return {refusal = .Duplicate_Client_Key, offending_index = index}
				}
			}
			client_key_rows += 1
			if client_key_rows > CLIENT_KEY_ROWS_LIMIT {
				return {refusal = .Client_Key_Limit_Exceeded, offending_index = index}
			}
		}
	}

	return {
		refusal                = .None,
		store_row_count        = store_rows,
		start_policy_row_count = start_policy_rows,
		client_key_row_count   = client_key_rows,
	}
}
