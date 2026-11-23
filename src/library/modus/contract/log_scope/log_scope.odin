// The log scope of a reader: which log records a caller of the log service
// receives from `records` and `value_runs`.
//
// The memory of the log holds the records of every process, so a reader
// never maps it: the log service, which holds it, chooses the records of
// each caller. The root service writes what the caller may read in the
// grant of its connection (isolated.Service_Command), and the caller cannot
// change it:
//
// - **The records of its principal**: the caller acts for its principal
//   (isolated.CALLER_ACTS_FOR_PRINCIPAL). It receives the records of the
//   processes of the session of that principal, and no other record: the
//   records of the kernel and of the root service count as records of
//   principal 0. The session table says which principal each process
//   belongs to (see below).
// - **Its own records**: each other caller. The amount of the grant names
//   the process of the caller by its process slot and its process serial,
//   which the kernel writes in each log record (operation.Log_Record). The
//   log service reads them from the own log ring of that process
//   (operation.Operation.Log_Read), which only its own records fill. Its
//   rows are numbered by their own number, and `lost` counts its own
//   records only: no number or count of the records of other processes.
// - **A lent process**: the exports `process_records` and
//   `process_value_runs` give, to each caller, the records of the process
//   whose process handle the caller lends for the call, with the right
//   Read. A starter holds the handle of each child, so it reads what its
//   children wrote. The log service reads the process slot and the process
//   serial of that process from the kernel (`Process_State`); the rows are
//   numbered by the own numbers of that process, as for own records.
//
// The amount of the grant (isolated.CALLER_AMOUNT_MASK): bits 0 to 31 are
// the process serial, bits 32 to 45 the process slot. The slot 0 is the
// kernel, which is never a caller: an amount of 0 names no process, and its
// caller receives no record.
//
// Example: the caller in the process slot 12 with the process serial 3
// has the amount `12 << 32 | 3`, and receives the records whose `process`
// is 12 and whose `process_serial` is 3.
//
// See [log scope](term:log-scope) and [own records](term:own-records).
package log_scope

import "base:intrinsics"
import "modus:contract/isolated"
import op "modus:contract/operation"

OWN_SERIAL_BITS :: 32 // The bits of the process serial in the amount: bits 0 to 31.
OWN_SERIAL_MASK :: u64(1) << OWN_SERIAL_BITS - 1
OWN_SLOT_SHIFT :: OWN_SERIAL_BITS // The first bit of the process slot in the amount.
OWN_SLOT_LIMIT :: u64(1) << 14 // The process slots that the amount holds: bits 32 to 45.
#assert(OWN_SLOT_LIMIT << OWN_SLOT_SHIFT - 1 == isolated.CALLER_AMOUNT_MASK)

// What a caller of the log service receives.
Scope_Kind :: enum u8 {
	Own_Records, // The records of one process: its own, or a lent one.
	Principal_Records, // The records of the processes of one principal.
	Whole_Log, // Each record: the log service itself, for its own window.
}

Scope :: struct {
	kind:           Scope_Kind,
	principal:      u64, // Principal_Records: the principal of the caller.
	process:        u64, // Own_Records: the process slot. 0: no record.
	process_serial: u64, // Own_Records: the process serial.
}

// own_records_amount gives the amount of the grant for the own records of
// a process. ok is false for the slot 0, a slot past the field and a serial
// past the field: the root service then gives the amount 0, which names no
// process.
//
// Example: `own_records_amount(12, 3)` is `12 << 32 | 3, true`.
own_records_amount :: proc "contextless" (process: u64, process_serial: u64) -> (amount: u64, ok: bool) {
	if process == 0 || process >= OWN_SLOT_LIMIT || process_serial > OWN_SERIAL_MASK {
		return 0, false
	}
	return process << OWN_SLOT_SHIFT | process_serial, true
}

// lent_process_scope gives the scope of a call that names a process by the
// handle that its caller lent: the records of that process only, never the
// whole log, also for a caller that acts for the principal. `process` and
// `process_serial` are what `Process_State` gives for the lent handle. The
// slot 0 is the kernel, which no process handle names: it gives a scope
// with no record.
//
// Example: a child in the process slot 9 with the process serial 4 gives
// the scope of the records whose `process` is 9 and whose
// `process_serial` is 4.
lent_process_scope :: proc "contextless" (process: u64, process_serial: u64) -> Scope {
	return {kind = .Own_Records, process = process, process_serial = process_serial}
}

// scope_of gives the scope of a caller from the grant of its connection.
scope_of :: proc "contextless" (grant: u64) -> Scope {
	if grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0 {
		return {kind = .Principal_Records, principal = isolated.caller_principal(grant)}
	}
	amount := grant & isolated.CALLER_AMOUNT_MASK
	return {kind = .Own_Records, process = amount >> OWN_SLOT_SHIFT, process_serial = amount & OWN_SERIAL_MASK}
}

// reads_own_records says if a caller with a scope reads the own log ring of
// a process (operation.Operation.Log_Read): it does not act for the
// principal, and its amount names a process. The slot 0 is the kernel,
// which has no own log ring: a caller with the amount 0 reads no record.
reads_own_records :: proc "contextless" (scope: Scope) -> bool {
	return scope.kind == .Own_Records && scope.process != 0
}

// reads_whole_ring says if a caller with a scope reads the ring of the
// whole log, record by record: a reader of the records of a principal, and
// the log service itself. Each other scope reads an own log ring.
reads_whole_ring :: proc "contextless" (scope: Scope) -> bool {
	switch scope.kind {
	case .Principal_Records, .Whole_Log:
		return true
	case .Own_Records:
	}
	return false
}

// The session table: for each process slot, the principal of the process
// that the root service started there, and of the one before it
// (src/md/features/log_reader_scope.md, "The scope of a principal").
//
// The root service is its one writer, and the log service maps it with
// Read only. The log service reads the principal of each record of the
// whole log from the slot and the serial that the kernel wrote in the
// record. A process that the root service did not start (a child that a
// process made with Process_Create) has no row: its records belong to no
// principal, and only a reader of its own records or of the lent process
// receives them.
//
// Each word holds a serial and a principal, written with one store, so a
// reader never reads half a row: bit 63 says that the word names a
// process, bits 32 to 46 the principal, bits 0 to 31 the serial. The
// previous word keeps the process before in the slot: its records stay in
// the ring after a new process takes the slot.
Session_Table_Entry :: struct {
	current:  u64,
	previous: u64,
}

// The rows of the table: one for each process slot that the kernel can
// have (format property: op.PROCESS_SLOTS_MOST, the most slots of any
// machine), so the table never refuses a slot.
SESSION_TABLE_ENTRIES :: op.PROCESS_SLOTS_MOST
SESSION_TABLE_PAGES :: (SESSION_TABLE_ENTRIES * size_of(Session_Table_Entry) + 4095) / 4096
SESSION_TABLE :: [SESSION_TABLE_ENTRIES]Session_Table_Entry

SESSION_WORD_PRESENT :: u64(1) << 63
SESSION_WORD_PRINCIPAL_SHIFT :: 32
#assert(isolated.CALLER_PRINCIPAL_LIMIT << SESSION_WORD_PRINCIPAL_SHIFT <= SESSION_WORD_PRESENT)

// The kernel makes the root service first, in the first slot of an empty
// table of processes (format property of the kernel: slot 1, serial 1).
// The root service writes this row for itself.
ROOT_SERVICE_SLOT :: 1
ROOT_SERVICE_SERIAL :: 1

// session_word gives the word of a process of a principal. ok is false for
// a serial past 32 bits and a principal past the field of the grant: the
// root service then writes no row, and the records of that process belong
// to no principal.
session_word :: proc "contextless" (process_serial: u64, principal: u64) -> (word: u64, ok: bool) {
	if process_serial > OWN_SERIAL_MASK || principal >= isolated.CALLER_PRINCIPAL_LIMIT {
		return 0, false
	}
	return SESSION_WORD_PRESENT | principal << SESSION_WORD_PRINCIPAL_SHIFT | process_serial, true
}

// session_entry_put writes the row of a slot for a process that starts:
// the process before moves to the previous word. ok is false for a slot
// past the table and a word that session_word refuses; nothing changes.
session_entry_put :: proc "contextless" (table: ^SESSION_TABLE, process: u64, process_serial: u64, principal: u64) -> bool {
	if process == 0 || process >= SESSION_TABLE_ENTRIES {
		return false
	}
	word, ok := session_word(process_serial, principal)
	if !ok {
		return false
	}
	entry := &table[process]
	current := intrinsics.atomic_load(&entry.current)
	if current == word {
		return true
	}
	// The previous word first: a reader that reads the current word, then
	// the previous one, sees each process of the slot at each moment.
	intrinsics.atomic_store(&entry.previous, current)
	intrinsics.atomic_store(&entry.current, word)
	return true
}

// record_principal gives the principal of a record of the whole log from
// the slot and the serial that the kernel wrote in it. known is false when
// no row names that process: a slot past the table, a slot that the root
// service never wrote, a process that it did not start. The kernel (slot 0)
// is principal 0.
//
// Example: a row of slot 9 whose current word names the serial 4 and
// principal 1 gives principal 1 for a record of slot 9 and serial 4, and
// no principal for a record of slot 9 and serial 3.
record_principal :: proc "contextless" (table: ^SESSION_TABLE, process: u64, process_serial: u64) -> (principal: u64, known: bool) {
	if process == 0 {
		return 0, true
	}
	if process >= SESSION_TABLE_ENTRIES {
		return 0, false
	}
	entry := &table[process]
	for word in ([2]u64{intrinsics.atomic_load(&entry.current), intrinsics.atomic_load(&entry.previous)}) {
		if word & SESSION_WORD_PRESENT != 0 && word & OWN_SERIAL_MASK == process_serial {
			return (word & ~SESSION_WORD_PRESENT) >> SESSION_WORD_PRINCIPAL_SHIFT, true
		}
	}
	return 0, false
}

// record_in_scope says if a reader of the whole ring receives a record of
// a principal: the log service receives each record, a reader of a
// principal the records of that principal only. A record of no known
// principal reaches no reader of a principal.
record_in_scope :: proc "contextless" (scope: Scope, principal: u64, known: bool) -> bool {
	switch scope.kind {
	case .Whole_Log:
		return true
	case .Principal_Records:
		return known && principal == scope.principal
	case .Own_Records:
	}
	return false
}
