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
	testing.expect(t, !scope.whole_log)
	testing.expect_value(t, scope.program, 12)
	testing.expect_value(t, scope.program_serial, 3)
	testing.expect_value(t, isolated.caller_principal(grant), 1)

	// The largest slot and serial of the fields: the amount fills its 46 bits
	// and no bit of the principal.
	largest, largest_ok := own_records_amount(OWN_SLOT_LIMIT - 1, OWN_SERIAL_MASK)
	testing.expect(t, largest_ok)
	testing.expect_value(t, largest, isolated.CALLER_AMOUNT_MASK)
	largest_scope := scope_of(isolated.caller_grant_make(largest, 0, false))
	testing.expect_value(t, largest_scope.program, OWN_SLOT_LIMIT - 1)
	testing.expect_value(t, largest_scope.program_serial, OWN_SERIAL_MASK)
}

// The kernel is never a caller, and a value past its field is refused, not
// cut: a cut slot or serial would name another program.
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
// program in the slot (Log_Read), so neither an earlier nor a later program
// of the slot, nor the starter itself.
@(test)
records_of_a_lent_program :: proc(t: ^testing.T) {
	CHILD_SLOT :: 9
	CHILD_SERIAL :: 4
	child := lent_program_scope(CHILD_SLOT, CHILD_SERIAL)
	testing.expect(t, !child.whole_log)
	testing.expect(t, reads_own_records(child))
	testing.expect_value(t, child.program, CHILD_SLOT)
	testing.expect_value(t, child.program_serial, CHILD_SERIAL)
}

// The scope of a lent program does not depend on the grant of the
// connection: a caller that acts for the principal and lends a handle reads
// the ring of that program only, and the slot 0, which no program handle
// names, reads no ring.
@(test)
lent_program_is_never_the_whole_log :: proc(t: ^testing.T) {
	whole := scope_of(isolated.caller_grant_make(0, 0, true))
	testing.expect(t, whole.whole_log)
	child := lent_program_scope(3, 2)
	testing.expect(t, !child.whole_log)
	testing.expect(t, reads_own_records(child))

	none := lent_program_scope(0, 0)
	testing.expect(t, !reads_own_records(none))
}

// The grant of a caller with no amount names no program: it reads no own
// log ring, not the records of the kernel (slot 0). The grant to act for
// the principal is the whole log, whatever its amount.
@(test)
no_amount_reads_no_record :: proc(t: ^testing.T) {
	none := scope_of(isolated.caller_grant_make(0, 0, false))
	testing.expect(t, !none.whole_log)
	testing.expect(t, !reads_own_records(none))
	amount, _ := own_records_amount(5, 7)
	own := scope_of(isolated.caller_grant_make(amount, 0, false))
	testing.expect(t, reads_own_records(own))
	whole := scope_of(isolated.caller_grant_make(amount, 0, true))
	testing.expect(t, whole.whole_log)
	testing.expect(t, !reads_own_records(whole))
}
