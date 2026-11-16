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
//   which the kernel writes in each log record (operation.Log_Record). Its
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
import op "modus:contract/operation"

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

// A reader of its own records sees no number of the whole log: its rows
// carry the own number of each record (operation.Log_Record.own_number),
// which counts the records of its program only. The own number has 32 bits
// and starts again from 0 after 2^32 records, so two own numbers are
// compared by their distance: a reader can copy at most
// op.LOG_RECORD_CAPACITY - 1 records, far fewer than 2^31. An `after` more
// than 2^31 past an own number is read modulo 2^32, so it gives that record
// with a meaningless `lost`: the caller asked a meaningless thing, and the
// answer holds its own records only.
OWN_NUMBER_HALF :: u32(1) << 31

// own_number_at_or_after says if a record with an own number comes at
// `after` or later, for a reader that asks from `after` on. A negative
// `after` is 0; `after` counts in the own numbers, modulo 2^32.
//
// Example: `own_number_at_or_after(3, 2)` is true; after a wrap,
// `own_number_at_or_after(1, 0xFFFF_FFFE)` is true too.
own_number_at_or_after :: proc "contextless" (own_number: u32, after: i64) -> bool {
	return own_number - u32(max(after, 0)) < OWN_NUMBER_HALF
}

// own_records_lost gives the own records from `after` that come before the
// first own record that the reader receives: the kernel wrote over them.
// The own numbers of one program follow each other, so the gap is the
// count, and it counts records of that program only.
own_records_lost :: proc "contextless" (first_own_number: u32, after: i64) -> u64 {
	return u64(first_own_number - u32(max(after, 0)))
}

// record_in_scope says if a caller with a scope receives a record: each
// record for the whole log; else only a record of the program of the scope,
// by its slot and its serial. A record of the kernel (slot 0) is never an
// own record.
record_in_scope :: proc "contextless" (scope: Scope, record: ^op.Log_Record) -> bool {
	if scope.whole_log {
		return true
	}
	return scope.program != 0 && u64(record.program) == scope.program && u64(record.program_serial) == scope.program_serial
}
