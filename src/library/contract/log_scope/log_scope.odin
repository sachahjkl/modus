// The log scope of a reader: which log records a caller of the log service
// receives from `records` and `value_runs`.
//
// The memory of the log holds the records of every program, so a reader
// never maps it: the log service, which holds it, chooses the records of
// each caller. The root service writes what the caller may read in the
// grant of its connection (isolated.Service_Command), and the caller cannot
// change it:
//
// - **The whole log**: the caller acts for the principal
//   (isolated.CALLER_ACTS_FOR_PRINCIPAL).
// - **Its own records**: each other caller. The amount of the grant names
//   the program of the caller by its program slot and its program serial,
//   which the kernel writes in each log record (operation.Log_Record). The
//   log service reads them from the own log ring of that program
//   (operation.Operation.Log_Read), which only its own records fill. Its
//   rows are numbered by their own number, and `lost` counts its own
//   records only: no number or count of the records of other programs.
//
// The amount of the grant (isolated.CALLER_AMOUNT_MASK): bits 0 to 31 are
// the program serial, bits 32 to 45 the program slot. The slot 0 is the
// kernel, which is never a caller: an amount of 0 names no program, and its
// caller receives no record.
//
// Example: the caller in the program slot 12 with the program serial 3
// has the amount `12 << 32 | 3`, and receives the records whose `program`
// is 12 and whose `program_serial` is 3.
//
// See [log scope](term:log-scope) and [own records](term:own-records).
package log_scope

import "modus:contract/isolated"

OWN_SERIAL_BITS :: 32 // The bits of the program serial in the amount: bits 0 to 31.
OWN_SERIAL_MASK :: u64(1) << OWN_SERIAL_BITS - 1
OWN_SLOT_SHIFT :: OWN_SERIAL_BITS // The first bit of the program slot in the amount.
OWN_SLOT_LIMIT :: u64(1) << 14 // The program slots that the amount holds: bits 32 to 45.
#assert(OWN_SLOT_LIMIT << OWN_SLOT_SHIFT - 1 == isolated.CALLER_AMOUNT_MASK)

// What a caller of the log service receives.
Scope :: struct {
	whole_log:      bool, // The caller acts for the principal: each record.
	program:        u64, // Its own records: the program slot. 0: no record.
	program_serial: u64, // Its own records: the program serial.
}

// own_records_amount gives the amount of the grant for the own records of
// a program. ok is false for the slot 0, a slot past the field and a serial
// past the field: the root service then gives the amount 0, which names no
// program.
//
// Example: `own_records_amount(12, 3)` is `12 << 32 | 3, true`.
own_records_amount :: proc "contextless" (program: u64, program_serial: u64) -> (amount: u64, ok: bool) {
	if program == 0 || program >= OWN_SLOT_LIMIT || program_serial > OWN_SERIAL_MASK {
		return 0, false
	}
	return program << OWN_SLOT_SHIFT | program_serial, true
}

// scope_of gives the scope of a caller from the grant of its connection.
scope_of :: proc "contextless" (grant: u64) -> Scope {
	amount := grant & isolated.CALLER_AMOUNT_MASK
	return {
		whole_log = grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0,
		program = amount >> OWN_SLOT_SHIFT,
		program_serial = amount & OWN_SERIAL_MASK,
	}
}

// reads_own_records says if a caller with a scope reads the own log ring of
// a program (operation.Operation.Log_Read): it does not act for the
// principal, and its amount names a program. The slot 0 is the kernel,
// which has no own log ring: a caller with the amount 0 reads no record.
reads_own_records :: proc "contextless" (scope: Scope) -> bool {
	return !scope.whole_log && scope.program != 0
}
