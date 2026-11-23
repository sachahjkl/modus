#+build !freestanding
package log_scope

import "modus:contract/isolated"
import "core:testing"

// The grant that the root service writes gives back the slot and the
// serial, next to the principal and the bit to act for it.
@(test)
own_records_amount_round_trip :: proc(t: ^testing.T) {
	amount, ok := own_records_amount(12, 3)
	testing.expect(t, ok)
	grant := isolated.caller_grant_make(amount, 1, false)
	scope := scope_of(grant)
	testing.expect_value(t, scope.kind, Scope_Kind.Own_Records)
	testing.expect_value(t, scope.process, 12)
	testing.expect_value(t, scope.process_serial, 3)
	testing.expect_value(t, isolated.caller_principal(grant), 1)

	// The largest slot and serial of the fields: the amount fills its 46 bits
	// and no bit of the principal.
	largest, largest_ok := own_records_amount(OWN_SLOT_LIMIT - 1, OWN_SERIAL_MASK)
	testing.expect(t, largest_ok)
	testing.expect_value(t, largest, isolated.CALLER_AMOUNT_MASK)
	largest_scope := scope_of(isolated.caller_grant_make(largest, 0, false))
	testing.expect_value(t, largest_scope.process, OWN_SLOT_LIMIT - 1)
	testing.expect_value(t, largest_scope.process_serial, OWN_SERIAL_MASK)
}

// The kernel is never a caller, and a value past its field is refused, not
// cut: a cut slot or serial would name another process.
@(test)
own_records_amount_refusals :: proc(t: ^testing.T) {
	_, kernel_ok := own_records_amount(0, 1)
	testing.expect(t, !kernel_ok)
	_, slot_ok := own_records_amount(OWN_SLOT_LIMIT, 1)
	testing.expect(t, !slot_ok)
	_, serial_ok := own_records_amount(1, OWN_SERIAL_MASK + 1)
	testing.expect(t, !serial_ok)
}

// A starter that lends the handle of its child reads the own log ring of
// that child: its slot and its serial, which the kernel checks against the
// process in the slot (Log_Read), so neither an earlier nor a later process
// of the slot, nor the starter itself.
@(test)
records_of_a_lent_process :: proc(t: ^testing.T) {
	CHILD_SLOT :: 9
	CHILD_SERIAL :: 4
	child := lent_process_scope(CHILD_SLOT, CHILD_SERIAL)
	testing.expect_value(t, child.kind, Scope_Kind.Own_Records)
	testing.expect(t, reads_own_records(child))
	testing.expect_value(t, child.process, CHILD_SLOT)
	testing.expect_value(t, child.process_serial, CHILD_SERIAL)
}

// The scope of a lent process does not depend on the grant of the
// connection: a caller that acts for the principal and lends a handle reads
// the ring of that process only, and the slot 0, which no process handle
// names, reads no ring.
@(test)
lent_process_is_never_the_whole_log :: proc(t: ^testing.T) {
	principal := scope_of(isolated.caller_grant_make(0, 0, true))
	testing.expect_value(t, principal.kind, Scope_Kind.Principal_Records)
	child := lent_process_scope(3, 2)
	testing.expect_value(t, child.kind, Scope_Kind.Own_Records)
	testing.expect(t, !reads_whole_ring(child))
	testing.expect(t, reads_own_records(child))

	none := lent_process_scope(0, 0)
	testing.expect(t, !reads_own_records(none))
}

// The grant of a caller with no amount names no process: it reads no own
// log ring, not the records of the kernel (slot 0). The grant to act for
// the principal is the records of that principal, whatever its amount.
@(test)
no_amount_reads_no_record :: proc(t: ^testing.T) {
	none := scope_of(isolated.caller_grant_make(0, 0, false))
	testing.expect(t, !reads_whole_ring(none))
	testing.expect(t, !reads_own_records(none))
	amount, _ := own_records_amount(5, 7)
	own := scope_of(isolated.caller_grant_make(amount, 0, false))
	testing.expect(t, reads_own_records(own))
	principal := scope_of(isolated.caller_grant_make(amount, 1, true))
	testing.expect_value(t, principal.kind, Scope_Kind.Principal_Records)
	testing.expect_value(t, principal.principal, 1)
	testing.expect(t, reads_whole_ring(principal))
	testing.expect(t, !reads_own_records(principal))
}

// No grant of a connection gives the whole log: a caller that acts for
// any principal, with any amount, receives the records of that principal
// only. Only the log service, with no connection, has the whole log.
@(test)
no_grant_gives_the_whole_log :: proc(t: ^testing.T) {
	for principal in ([?]u64{0, 1, isolated.CALLER_PRINCIPAL_LIMIT - 1}) {
		for amount in ([?]u64{0, 1, isolated.CALLER_AMOUNT_MASK}) {
			for acts in ([?]bool{false, true}) {
				scope := scope_of(isolated.caller_grant_make(amount, principal, acts))
				testing.expect(t, scope.kind != .Whole_Log)
				if acts {
					testing.expect_value(t, scope.principal, principal)
				}
			}
		}
	}
}

// The table refuses each row that would name another process: the slot of
// the kernel, a slot past the table, a serial or a principal past its
// field. Nothing changes.
@(test)
the_session_table_refuses_each_row_past_its_fields :: proc(t: ^testing.T) {
	table := new(SESSION_TABLE)
	defer free(table)
	testing.expect(t, !session_entry_put(table, 0, 1, 0), "the kernel has no row")
	testing.expect(t, !session_entry_put(table, SESSION_TABLE_ENTRIES, 1, 0), "one past the table")
	testing.expect(t, !session_entry_put(table, max(u64), 1, 0), "the largest slot")
	testing.expect(t, !session_entry_put(table, 5, OWN_SERIAL_MASK + 1, 0), "a serial past 32 bits")
	testing.expect(t, !session_entry_put(table, 5, 1, isolated.CALLER_PRINCIPAL_LIMIT), "a principal past the field")
	testing.expect(t, !session_entry_put(table, 5, 1, max(u64)), "the largest principal")
	for entry in table {
		testing.expect(t, entry == {}, "a refused row changed the table")
	}
	// The edges that pass: the last slot, the largest serial and principal.
	testing.expect(t, session_entry_put(table, SESSION_TABLE_ENTRIES - 1, OWN_SERIAL_MASK, isolated.CALLER_PRINCIPAL_LIMIT - 1))
	principal, known := record_principal(table, SESSION_TABLE_ENTRIES - 1, OWN_SERIAL_MASK)
	testing.expect(t, known)
	testing.expect_value(t, principal, isolated.CALLER_PRINCIPAL_LIMIT - 1)
}

// A record of a process that no row names belongs to no principal, and no
// reader of a principal receives it: a slot never written, a serial of no
// row, a slot past the table.
@(test)
a_record_of_no_row_reaches_no_principal :: proc(t: ^testing.T) {
	table := new(SESSION_TABLE)
	defer free(table)
	_, known := record_principal(table, 7, 0)
	testing.expect(t, !known, "an empty row names the serial 0 of no process")
	_, known = record_principal(table, 7, 1)
	testing.expect(t, !known)
	_, known = record_principal(table, SESSION_TABLE_ENTRIES, 1)
	testing.expect(t, !known)
	_, known = record_principal(table, max(u64), 1)
	testing.expect(t, !known)
	for principal in ([?]u64{0, 1}) {
		scope := Scope{kind = .Principal_Records, principal = principal}
		testing.expect(t, !record_in_scope(scope, principal, false), "an unknown record reached a principal")
	}
	// The kernel is principal 0.
	principal, kernel_known := record_principal(table, 0, 0)
	testing.expect(t, kernel_known)
	testing.expect_value(t, principal, 0)
}

// The records of one principal never reach a reader of another, whatever
// the order of the starts in a slot: the current and the previous process
// of a slot keep their principals, and a third process pushes the first
// one out, to no principal.
@(test)
no_reader_receives_the_records_of_another_principal :: proc(t: ^testing.T) {
	table := new(SESSION_TABLE)
	defer free(table)
	SLOT :: 9
	testing.expect(t, session_entry_put(table, SLOT, 3, 0))
	testing.expect(t, session_entry_put(table, SLOT, 4, 1))
	machine_reader := Scope{kind = .Principal_Records, principal = 0}
	named_reader := Scope{kind = .Principal_Records, principal = 1}
	principal, known := record_principal(table, SLOT, 3)
	testing.expect(t, known && principal == 0)
	testing.expect(t, record_in_scope(machine_reader, principal, known))
	testing.expect(t, !record_in_scope(named_reader, principal, known))
	principal, known = record_principal(table, SLOT, 4)
	testing.expect(t, known && principal == 1)
	testing.expect(t, !record_in_scope(machine_reader, principal, known))
	testing.expect(t, record_in_scope(named_reader, principal, known))
	// The same row again changes nothing: the previous word stays.
	testing.expect(t, session_entry_put(table, SLOT, 4, 1))
	principal, known = record_principal(table, SLOT, 3)
	testing.expect(t, known && principal == 0)
	testing.expect(t, session_entry_put(table, SLOT, 5, 1))
	_, known = record_principal(table, SLOT, 3)
	testing.expect(t, !known, "the third process pushes the first one out")
	// An own-records scope never reads the whole ring.
	testing.expect(t, !record_in_scope(Scope{kind = .Own_Records, process = SLOT, process_serial = 4}, 1, true))
	// The log service itself reads each record, known or not.
	testing.expect(t, record_in_scope(Scope{kind = .Whole_Log}, 0, false))
}

// A record of no row waits for its row only while the row can come: a
// newer process in the slot, or the bound of the wait, settles it to no
// principal; a row that comes during the wait gives its principal.
@(test)
a_record_waits_for_its_row_only_while_it_can_come :: proc(t: ^testing.T) {
	table := new(SESSION_TABLE)
	defer free(table)
	_, decision := settle_decision(table, SESSION_TABLE_ENTRIES, 1, 0)
	testing.expect_value(t, decision, Settle_Decision.No_Principal)
	_, decision = settle_decision(table, max(u64), 1, 0)
	testing.expect_value(t, decision, Settle_Decision.No_Principal)
	// An empty slot: the row can come, until the bound.
	_, decision = settle_decision(table, 9, 5, 0)
	testing.expect_value(t, decision, Settle_Decision.Wait)
	_, decision = settle_decision(table, 9, 5, ROW_WAIT_MICROSECONDS - 1)
	testing.expect_value(t, decision, Settle_Decision.Wait)
	_, decision = settle_decision(table, 9, 5, ROW_WAIT_MICROSECONDS)
	testing.expect_value(t, decision, Settle_Decision.No_Principal)
	_, decision = settle_decision(table, 9, 5, max(u64))
	testing.expect_value(t, decision, Settle_Decision.No_Principal)
	// A row of an older serial: the row can come.
	testing.expect(t, session_entry_put(table, 9, 4, 0))
	_, decision = settle_decision(table, 9, 5, 0)
	testing.expect_value(t, decision, Settle_Decision.Wait)
	// A row of a newer serial: never.
	testing.expect(t, session_entry_put(table, 9, 6, 0))
	_, decision = settle_decision(table, 9, 5, 0)
	testing.expect_value(t, decision, Settle_Decision.No_Principal)
	// The row of the process: known, at any age.
	testing.expect(t, session_entry_put(table, 9, 7, 1))
	principal, known_decision := settle_decision(table, 9, 7, max(u64))
	testing.expect_value(t, known_decision, Settle_Decision.Known)
	testing.expect_value(t, principal, 1)
	// The kernel is known.
	_, decision = settle_decision(table, 0, 0, 0)
	testing.expect_value(t, decision, Settle_Decision.Known)
}
