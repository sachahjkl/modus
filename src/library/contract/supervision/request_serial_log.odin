// Request serial deduplication table: pure fixed-capacity helper guaranteeing
// at-most-once execution for Serial_Tracked calls across holder restarts
// (src/md/features/supervision.md, "The rule that makes a replay safe").
package supervision

// One committed (request_serial -> result_word) entry kept for a client.
Committed_Request_Entry :: struct {
	occupied:       bool,
	request_serial: u64,
	result_word:    u64,
}

// Per-client deduplication window storing the most recent
// REQUEST_SERIALS_IN_FLIGHT committed serials plus the high-water mark so even
// ancient evicted serials are never executed a second time.
Client_Serial_Window :: struct {
	active:                   bool,
	client_id:                u64,
	highest_committed_serial: u64,
	entries:                  [REQUEST_SERIALS_IN_FLIGHT]Committed_Request_Entry,
}

// Fixed-capacity deduplication table persisted by a stateful holder alongside
// its store commits. Valid when zero-initialized.
Request_Serial_Log :: struct {
	clients: [REQUEST_LOG_CLIENT_CAPACITY]Client_Serial_Window,
}

// Outcome of checking an incoming (client_id, request_serial) before executing.
Serial_Lookup_Status :: enum u8 {
	Execute_New       = 0, // Serial has not been committed yet: execute and commit.
	Already_Committed = 1, // Serial was already committed: return stored result_word without re-executing.
	Serial_Too_Old    = 2, // Serial is older than the kept window of committed serials: refuse execution.
	Invalid_Input     = 3, // Zero client_id or zero request_serial.
	Table_Full        = 4, // Unknown client and all client slots are full.
}

// Why committing a (client_id, request_serial, result_word) failed. On any
// refusal, the log is unchanged.
Serial_Commit_Refusal :: enum u8 {
	None                = 0,
	Zero_Client_Id      = 1,
	Zero_Request_Serial = 2,
	Duplicate_Serial    = 3,
	Serial_Too_Old      = 4,
	Table_Full          = 5,
}

@(private = "file")
find_client_slot :: proc "contextless" (log: ^Request_Serial_Log, client_id: u64) -> (index: int, found: bool) {
	for &client, slot in log.clients {
		if client.active && client.client_id == client_id {
			return slot, true
		}
	}
	return -1, false
}

@(private = "file")
find_free_client_slot :: proc "contextless" (log: ^Request_Serial_Log) -> (index: int, found: bool) {
	for &client, slot in log.clients {
		if !client.active {
			return slot, true
		}
	}
	return -1, false
}

@(private = "file")
serial_below_retention_floor :: proc "contextless" (highest: u64, serial: u64) -> bool {
	if highest < u64(REQUEST_SERIALS_IN_FLIGHT) {
		return false
	}
	// Serials strictly older than (highest - REQUEST_SERIALS_IN_FLIGHT + 1)
	// have rolled past the in-flight window and cannot be re-executed.
	return serial <= highest - u64(REQUEST_SERIALS_IN_FLIGHT)
}

// request_serial_log_check inspects (client_id, request_serial) before running
// a Serial_Tracked export. If already committed, returns Already_Committed and
// the stored result_word so the caller skips re-execution.
request_serial_log_check :: proc "contextless" (
	log: ^Request_Serial_Log,
	client_id: u64,
	request_serial: u64,
) -> (status: Serial_Lookup_Status, stored_result_word: u64) {
	if log == nil || client_id == 0 || request_serial == 0 {
		return .Invalid_Input, 0
	}
	slot, found := find_client_slot(log, client_id)
	if !found {
		_, has_room := find_free_client_slot(log)
		if !has_room {
			return .Table_Full, 0
		}
		return .Execute_New, 0
	}
	client := &log.clients[slot]
	for entry in client.entries {
		if entry.occupied && entry.request_serial == request_serial {
			return .Already_Committed, entry.result_word
		}
	}
	if serial_below_retention_floor(client.highest_committed_serial, request_serial) {
		return .Serial_Too_Old, 0
	}
	return .Execute_New, 0
}

// request_serial_log_commit records (client_id, request_serial) -> result_word
// once the call's side effect commits. Re-committing an already-committed or
// evicted-old serial is refused and leaves the stored result untouched.
request_serial_log_commit :: proc "contextless" (
	log: ^Request_Serial_Log,
	client_id: u64,
	request_serial: u64,
	result_word: u64,
) -> Serial_Commit_Refusal {
	if log == nil || client_id == 0 {
		return .Zero_Client_Id
	}
	if request_serial == 0 {
		return .Zero_Request_Serial
	}
	slot, found := find_client_slot(log, client_id)
	if !found {
		free_slot, has_room := find_free_client_slot(log)
		if !has_room {
			return .Table_Full
		}
		log.clients[free_slot] = {
			active                   = true,
			client_id                = client_id,
			highest_committed_serial = request_serial,
		}
		log.clients[free_slot].entries[0] = {
			occupied       = true,
			request_serial = request_serial,
			result_word    = result_word,
		}
		return .None
	}

	client := &log.clients[slot]
	for entry in client.entries {
		if entry.occupied && entry.request_serial == request_serial {
			return .Duplicate_Serial
		}
	}
	if serial_below_retention_floor(client.highest_committed_serial, request_serial) {
		return .Serial_Too_Old
	}

	// Pick a free slot if available; otherwise evict the entry with the
	// smallest request_serial so the newest REQUEST_SERIALS_IN_FLIGHT results
	// remain cached.
	target_index := -1
	oldest_serial := max(u64)
	oldest_index := 0
	for entry, index in client.entries {
		if !entry.occupied {
			target_index = index
			break
		}
		if entry.request_serial < oldest_serial {
			oldest_serial = entry.request_serial
			oldest_index = index
		}
	}
	if target_index < 0 {
		target_index = oldest_index
	}
	client.entries[target_index] = {
		occupied       = true,
		request_serial = request_serial,
		result_word    = result_word,
	}
	if request_serial > client.highest_committed_serial {
		client.highest_committed_serial = request_serial
	}
	return .None
}

// request_serial_log_remove_client drops all stored serials for a client when
// its connection disconnects.
request_serial_log_remove_client :: proc "contextless" (log: ^Request_Serial_Log, client_id: u64) -> bool {
	if log == nil || client_id == 0 {
		return false
	}
	slot, found := find_client_slot(log, client_id)
	if !found {
		return false
	}
	log.clients[slot] = {}
	return true
}

// request_serial_log_clear resets the entire table (used on a holder's first
// start in a machine run, when no surviving connection exists).
request_serial_log_clear :: proc "contextless" (log: ^Request_Serial_Log) {
	if log == nil {
		return
	}
	log^ = {}
}
