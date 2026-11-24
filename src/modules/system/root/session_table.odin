package root

import "modus:contract/call_outcome"
import "modus:contract/log_scope"
import "modus:principals"
import "modus:system"

// The session table: the principal of each process that this service
// starts, by its process slot and its process serial. The log service maps
// it with Read, and gives a caller that acts for a principal the records
// of the processes of that principal only
// (src/md/features/log_reader_scope.md, "The scope of a principal").
// This service is its one writer.

session_table_memory: system.Handle
session_table: ^log_scope.SESSION_TABLE

// session_table_create makes the table, with the row of this service: its
// records are records of principal 0, as those of the kernel.
session_table_create :: proc "contextless" () {
	status: call_outcome.Call_Outcome
	session_table_memory, status = system.memory_create(log_scope.SESSION_TABLE_PAGES)
	table: rawptr
	if status == .Succeeded {
		table, status = system.memory_map(session_table_memory)
	}
	if status != .Succeeded {
		fail("cannot create the session table", status)
	}
	session_table = (^log_scope.SESSION_TABLE)(table)
	_ = log_scope.session_entry_put(session_table, log_scope.ROOT_SERVICE_SLOT, log_scope.ROOT_SERVICE_SERIAL, principals.MACHINE)
}

// session_table_record writes the row of a process that starts, before it
// runs a line: each of its records then has its principal. A row that the
// table refuses leaves the records of that process to no principal, and
// says so.
session_table_record :: proc "contextless" (process_slot: u64, process_serial: u64, principal: u64) {
	if session_table == nil {
		return
	}
	if !log_scope.session_entry_put(session_table, process_slot, process_serial, principal) {
		system.log_fact(.Warning, Session_Table_Row_Refused{slot = process_slot, serial = process_serial, principal = principal})
	}
}
