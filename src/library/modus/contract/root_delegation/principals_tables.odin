// The disk grant tables of the principals, kept in the store module_files of
// each principal by the delegated principals service
// (src/md/api/root_service_split.md, "State").
//
// The core holds each table in memory and decides each grant from it; it
// holds no key of a table and calls no storage service. The service holds
// the key of the tag of each table, which the core passes on from unlock
// and does not keep, and reads and writes the table through a connection
// that the core makes for one call. The core checks each table that the
// service read with the decoder of the disk (disk_process.table_body_decode),
// so a service that lies gives no row that the disk could not give.
package root_delegation

import "modus:contract/enum_word"

// The bytes of a persisted table, with its tag: disk_process.TABLE_SIZE,
// which the core checks with an assertion. A contract package does not
// import that support package.
TABLE_BYTES :: 1968

// The bytes of the name of the storage service in a Table_Call_Input.
STORAGE_MODULE_NAME_BYTES :: 32

#assert(size_of(Table_Call_Input) <= PRINCIPALS_TRANSFER_PLACE_BYTES)

// The input of a Table_Read or a Table_Write, in one place of the transfer
// region. For a write, table is the table that the core encoded with no tag
// (disk_process.table_body_encode): the service adds the tag with its key.
// For a read, the service writes there the table that it read, whose tag
// verified under the key.
Table_Call_Input :: struct {
	principal:             u64,
	storage_module_length: u64,
	storage_module:        [STORAGE_MODULE_NAME_BYTES]u8,
	table:                 [TABLE_BYTES]u8,
}

// Why the service could not make the call of a table, in values[0] of a
// completion Refused. A refusal of the storage service itself is the status
// Storage_Refused, with its error record.
Table_Call_Failure :: enum u64 {
	None            = 0,
	Not_Mapped      = 1, // The call ring and the call region of the storage service do not map.
	Call_Not_Taken  = 2, // The storage service took no call.
	Storage_Stopped = 3, // The storage service stopped.
	No_Answer       = 4, // The storage service gave no answer in time.
	No_Key          = 5, // The service holds no key for the table: it started again since the key came.
	Bad_Input       = 6, // The handles or the input of the command do not pass the border of the service.
}

// What the read of a table found, in values[0] of a completion Ok of a
// Table_Read. values[1] is the disk_process.Table_File_Problem of a table
// that the store holds, None for a table whose tag verified.
Table_Read_Outcome :: enum u64 {
	None    = 0,
	Absent  = 1, // The store holds no table.
	Decoded = 2, // The store holds a table: values[1] says if it verified.
}

// table_key_check is the border of the values of a Table_Key: a principal
// below principal_capacity, a key that is not zero bytes, and values[5] and
// values[6] zero. It gives the principal and the key.
table_key_check :: proc "contextless" (values: [7]u64, principal_capacity: u64) -> (principal: u64, key: [32]u8, failure: Table_Call_Failure) {
	principal = values[4]
	if principal >= principal_capacity || values[5] != 0 || values[6] != 0 {
		return 0, {}, .Bad_Input
	}
	key = transmute([32]u8)[4]u64{values[0], values[1], values[2], values[3]}
	if key == {} {
		return 0, {}, .Bad_Input
	}
	return principal, key, .None
}

// table_call_input_check is the border of the input of a Table_Read or a
// Table_Write that the service copied out of its place: a principal below
// principal_capacity and a name of the storage service of 1 to
// STORAGE_MODULE_NAME_BYTES bytes, with zero bytes after it.
table_call_input_check :: proc "contextless" (input: ^Table_Call_Input, principal_capacity: u64) -> Table_Call_Failure {
	if input.principal >= principal_capacity {
		return .Bad_Input
	}
	if input.storage_module_length == 0 || input.storage_module_length > STORAGE_MODULE_NAME_BYTES {
		return .Bad_Input
	}
	for after in input.storage_module[input.storage_module_length:] {
		if after != 0 {
			return .Bad_Input
		}
	}
	return .None
}

// table_call_failure_of_word is the border of values[0] of a completion
// Refused of a table call: None and a word that names no member are
// refused.
table_call_failure_of_word :: proc "contextless" (word: u64) -> (failure: Table_Call_Failure, ok: bool) {
	member, known := enum_word.member_of_word(Table_Call_Failure, word)
	if !known || member == .None {
		return .None, false
	}
	return member, true
}

// table_read_outcome_of_word is the border of values[0] of a completion Ok
// of a Table_Read.
table_read_outcome_of_word :: proc "contextless" (word: u64) -> (outcome: Table_Read_Outcome, ok: bool) {
	member, known := enum_word.member_of_word(Table_Read_Outcome, word)
	if !known || member == .None {
		return .None, false
	}
	return member, true
}
