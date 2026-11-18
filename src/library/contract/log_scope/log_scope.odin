// The log scope of a reader: which log records a caller of the log service
// receives from `records` and `value_runs`.
//
// The memory of the log holds the records of every process, so a reader
// never maps it: the log service, which holds it, chooses the records of
// each caller. The root service writes what the caller may read in the
// grant of its connection (isolated.Service_Command), and the caller cannot
// change it:
//
// - **The whole log**: the caller acts for the principal
//   (isolated.CALLER_ACTS_FOR_PRINCIPAL).
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

import "modus:contract/isolated"

OWN_SERIAL_BITS :: 32 // The bits of the process serial in the amount: bits 0 to 31.
OWN_SERIAL_MASK :: u64(1) << OWN_SERIAL_BITS - 1
OWN_SLOT_SHIFT :: OWN_SERIAL_BITS // The first bit of the process slot in the amount.
OWN_SLOT_LIMIT :: u64(1) << 14 // The process slots that the amount holds: bits 32 to 45.
#assert(OWN_SLOT_LIMIT << OWN_SLOT_SHIFT - 1 == isolated.CALLER_AMOUNT_MASK)

// What a caller of the log service receives.
Scope :: struct {
	whole_log:      bool, // The caller acts for the principal: each record.
	process:        u64, // Its own records: the process slot. 0: no record.
	process_serial: u64, // Its own records: the process serial.
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
	return {whole_log = false, process = process, process_serial = process_serial}
}

// scope_of gives the scope of a caller from the grant of its connection.
scope_of :: proc "contextless" (grant: u64) -> Scope {
	amount := grant & isolated.CALLER_AMOUNT_MASK
	return {
		whole_log = grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0,
		process = amount >> OWN_SLOT_SHIFT,
		process_serial = amount & OWN_SERIAL_MASK,
	}
}

// reads_own_records says if a caller with a scope reads the own log ring of
// a process (operation.Operation.Log_Read): it does not act for the
// principal, and its amount names a process. The slot 0 is the kernel,
// which has no own log ring: a caller with the amount 0 reads no record.
reads_own_records :: proc "contextless" (scope: Scope) -> bool {
	return !scope.whole_log && scope.process != 0
}
