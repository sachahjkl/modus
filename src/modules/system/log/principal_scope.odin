package log

import "base:intrinsics"
import "modus:contract/log_scope"
import op "modus:contract/operation"
import "modus:system"

// The principal of each record of the whole log, for a caller that acts
// for a principal (src/md/features/log_reader_scope.md, "The scope of a
// principal").
//
// The root service writes the principal of each process that it starts in
// the session table, by its slot and its serial. A slot serves a new
// process after the last handle of the one before closes, and the table
// keeps the current and the previous process of each slot only. So this
// service reads the principal of a record soon after the kernel wrote it,
// at each pass of its loop, and keeps it beside the place of the record
// in the ring: a process that stopped long ago keeps its principal while
// the ring keeps its records.
//
// A record whose process has no row yet (the root service writes the row
// right after the start, and the process can write first) is read again
// at the next pass and at each call: it is never kept as known with no
// principal.

// The session table, with Read. nil: the root service gave none, and no
// record reaches a reader of a principal.
session_table: ^log_scope.SESSION_TABLE

// The principal of the record at each place of the ring, and the number
// of that record: a place names the record of that number only.
Record_Principal :: struct {
	number:    u64,
	principal: u64,
	known:     bool,
}
record_principals: [op.LOG_RECORD_CAPACITY]Record_Principal
// The first record that principals_read has not read.
principals_read_next: u64

// session_table_open maps the session table that the root service gives.
session_table_open :: proc "contextless" (ctx: ^system.Context) {
	handle := ctx.handles[system.GRANT_SESSION_TABLE]
	if handle == 0 {
		return
	}
	if address, status := system.memory_map(handle, {}); status == .Ok {
		session_table = (^log_scope.SESSION_TABLE)(address)
	}
}

// principals_read reads the principal of each record that the kernel
// wrote since the last pass.
principals_read :: proc "contextless" () {
	written := intrinsics.atomic_load(&reader_head.written)
	next, _ := op.log_first_kept(principals_read_next, written)
	for ; next < written; next += 1 {
		_, _ = record_principal_of(next)
	}
	principals_read_next = written
}

// record_principal_of gives the principal of the record of a number: from
// its place when it was read, else from the session table now, kept when
// the table names it.
record_principal_of :: proc "contextless" (number: u64) -> (principal: u64, known: bool) {
	place := &record_principals[number % op.LOG_RECORD_CAPACITY]
	if place.number == number && place.known {
		return place.principal, true
	}
	if session_table == nil {
		return 0, false
	}
	record, whole := record_copy(number)
	if !whole {
		return 0, false
	}
	principal, known = log_scope.record_principal(session_table, u64(record.process), u64(record.process_serial))
	place^ = {number = number, principal = principal, known = known}
	return principal, known
}

// record_reaches says if a record of the whole ring reaches a scope.
record_reaches :: proc "contextless" (scope: log_scope.Scope, number: u64) -> bool {
	if scope.kind == .Whole_Log {
		return true
	}
	principal, known := record_principal_of(number)
	return log_scope.record_in_scope(scope, principal, known)
}
