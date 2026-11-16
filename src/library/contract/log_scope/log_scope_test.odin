#+build !freestanding
package log_scope

import "modus:contract/isolated"
import op "modus:contract/operation"
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

// A reader of its own records receives the records of its slot with its
// serial, and no record of another program, of an earlier program of the
// same slot, or of the kernel. A reader of the whole log receives each one.
@(test)
records_in_a_scope :: proc(t: ^testing.T) {
	amount, _ := own_records_amount(5, 7)
	own := scope_of(isolated.caller_grant_make(amount, 0, false))
	whole := scope_of(isolated.caller_grant_make(0, 0, true))

	its_record := op.Log_Record{program = 5, program_serial = 7}
	earlier_program_of_its_slot := op.Log_Record{program = 5, program_serial = 6}
	other_program := op.Log_Record{program = 6, program_serial = 7}
	kernel := op.Log_Record{}

	testing.expect(t, record_in_scope(own, &its_record))
	testing.expect(t, !record_in_scope(own, &earlier_program_of_its_slot))
	testing.expect(t, !record_in_scope(own, &other_program))
	testing.expect(t, !record_in_scope(own, &kernel))
	records := [4]op.Log_Record{its_record, earlier_program_of_its_slot, other_program, kernel}
	for &record in records {
		testing.expect(t, record_in_scope(whole, &record))
	}
}

// The own numbers: a record at `after` or later is given, an earlier one is
// not, and the order holds across the wrap at 2^32. The gap before the
// first given record counts the own records that the kernel wrote over.
@(test)
own_numbers_in_order :: proc(t: ^testing.T) {
	testing.expect(t, own_number_at_or_after(5, 5))
	testing.expect(t, own_number_at_or_after(6, 5))
	testing.expect(t, !own_number_at_or_after(4, 5))
	testing.expect(t, own_number_at_or_after(0, -3))
	last := max(u32)
	testing.expect(t, own_number_at_or_after(1, i64(last)))
	testing.expect(t, !own_number_at_or_after(last, 1))
	testing.expect_value(t, own_records_lost(7, 4), 3)
	testing.expect_value(t, own_records_lost(4, 4), 0)
	testing.expect_value(t, own_records_lost(2, i64(last)), 3)
}

// The grant of a caller with no amount names no program: it receives no
// record, not the records of the kernel.
@(test)
no_amount_reads_no_record :: proc(t: ^testing.T) {
	none := scope_of(isolated.caller_grant_make(0, 0, false))
	testing.expect_value(t, none.program, 0)
	kernel := op.Log_Record{}
	testing.expect(t, !record_in_scope(none, &kernel))
}
