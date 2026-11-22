package disk_process

// The disk grant table of a principal as the whole set of rows that the
// root service gives the delegated principals service
// (src/md/api/root_service_split.md, "State").

import "modus:contract/remote"
import rd "modus:contract/root_delegation"

#assert(NAME_LIMIT == rd.NICKNAME_CAPACITY)
#assert(HASH_SIZE == len(rd.Disk_Row_Entry{}.module_hash))
#assert(ROW_CAPACITY <= rd.STORE_ROWS_LIMIT)
#assert(CLIENT_KEY_CAPACITY <= rd.CLIENT_KEY_ROWS_LIMIT)

// disk_rows_set_request_of_table writes the rows of a table in request:
// a row with the grant Start_Policy as the row Start_Policy, a row with
// the grant Store as a row Store, and each client key with its uses. A row
// with no grant gives nothing: it names a file and grants nothing, and the
// set holds grants only. The table holds no count of blocks, so a row Store
// has none. ok is false, and request is zero, when the table has a count
// out of its capacity or a row that the border of the set refuses: the
// caller then sends nothing.
disk_rows_set_request_of_table :: proc "contextless" (table: ^Grant_Table, principal, generation: u64, request: ^rd.Disk_Rows_Set_Request) -> (ok: bool) {
	request^ = {}
	if table == nil || table.count < 0 || table.count > ROW_CAPACITY || table.client_key_count < 0 || table.client_key_count > CLIENT_KEY_CAPACITY {
		return false
	}
	request.principal = principal
	request.generation = generation
	for &row in table.rows[:table.count] {
		class: rd.Disk_Row_Class
		switch {
		case .Start_Policy in row.grants:
			class = .Start_Policy
		case .Store in row.grants:
			class = .Store
		case:
			continue
		}
		if row.nickname_length <= 0 || row.nickname_length > NAME_LIMIT {
			request^ = {}
			return false
		}
		entry := &request.rows[request.row_count]
		entry.class_word = u32(class)
		copy(entry.nickname[:], row.nickname[:row.nickname_length])
		entry.nickname_length = u8(row.nickname_length)
		entry.module_hash = row.hash
		request.row_count += 1
	}
	for &key in table.client_keys[:table.client_key_count] {
		request.rows[request.row_count] = {
			class_word       = u32(rd.Disk_Row_Class.Client_Key),
			client_key       = key.key,
			client_uses_word = remote.client_uses_word(key.uses),
		}
		request.row_count += 1
	}
	if rd.validate_disk_rows_set_request(request).refusal != .None {
		request^ = {}
		return false
	}
	return true
}
