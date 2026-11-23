#+build !freestanding
package output

import "core:testing"

// A Started end of a process that the asker did not start is refused,
// whatever else holds: the asker acts for the principal, holds a
// connection to it, the process is a service, or the start policy started
// it for an asker that is not the start policy. The start policy is
// refused for a process that it did not ask for. The machine test cannot
// lend such a process: an asker receives a process handle with Give only
// from its own Start.
@(test)
a_started_end_that_the_asker_did_not_start_is_refused :: proc(t: ^testing.T) {
	everything_else := End_Facts {
		started_by_start_policy  = true,
		asker_acts_for_principal = true,
		process_is_a_service     = true,
		asker_holds_a_connection = true,
	}
	testing.expect(t, !wiring_end_allowed(.Started, everything_else))
	testing.expect(t, !wiring_end_allowed(.Started, {}))
	testing.expect(t, !wiring_end_allowed(.Started, {asker_is_start_policy = true}))
	testing.expect(t, !wiring_end_allowed(.Started, {asker_is_start_policy = true, asker_acts_for_principal = true, asker_holds_a_connection = true}))
}

// A Connected end is refused when one of its three facts is missing: the
// grant to act for the principal, a process that serves calls, and a
// plain connection of the asker to it. Started facts never stand in for
// them.
@(test)
a_connected_end_with_a_fact_missing_is_refused :: proc(t: ^testing.T) {
	whole := End_Facts {
		asker_acts_for_principal = true,
		process_is_a_service     = true,
		asker_holds_a_connection = true,
	}
	no_grant := whole
	no_grant.asker_acts_for_principal = false
	no_grant.started_by_asker = true
	testing.expect(t, !wiring_end_allowed(.Connected, no_grant))
	not_a_service := whole
	not_a_service.process_is_a_service = false
	testing.expect(t, !wiring_end_allowed(.Connected, not_a_service))
	no_connection := whole
	no_connection.asker_holds_a_connection = false
	no_connection.asker_is_start_policy, no_connection.started_by_start_policy = true, true
	testing.expect(t, !wiring_end_allowed(.Connected, no_connection))
	testing.expect(t, !wiring_end_allowed(.Connected, {started_by_asker = true}))
}

// The end None names no process, and a word past the members is no end:
// both are refused with every fact true.
@(test)
an_end_that_names_nothing_is_refused :: proc(t: ^testing.T) {
	every_fact := End_Facts{true, true, true, true, true, true, true}
	testing.expect(t, !wiring_end_allowed(.None, every_fact))
	testing.expect(t, !wiring_end_allowed(Wiring_End(u32(max(Wiring_End)) + 1), every_fact))
}

// The rows of a start policy. Refused first, with the end that the rule
// names: the two scenarios of a start policy from the disk that reads a
// stream (the log of its child to the Asker in a Start; a lent child as
// the writer and the Asker in a Wire), each other pair of ends of a Start,
// and each pair of a Wire, the one row of the start list among them. The
// row of a start list in a Start is taken last.
@(test)
a_start_policy_names_only_the_ends_of_a_start_list :: proc(t: ^testing.T) {
	expect :: proc(t: ^testing.T, form: Wiring_List_Form, writer, reader: Wiring_End, field: Wiring_Field, loc := #caller_location) {
		refused, allowed := start_policy_row_allowed(form, writer, reader)
		testing.expect(t, !allowed, "the row is taken", loc = loc)
		testing.expect_value(t, refused, field, loc = loc)
	}
	expect(t, .Start, .Child, .Asker, .Reader_End)
	expect(t, .Wire, .Started, .Asker, .Writer_End)
	for writer in Wiring_End {
		for reader in Wiring_End {
			if writer == .Child && reader == .Started {
				continue
			}
			expect(t, .Start, writer, reader, writer == .Child ? .Reader_End : .Writer_End)
		}
	}
	for writer in Wiring_End {
		for reader in Wiring_End {
			expect(t, .Wire, writer, reader, .Writer_End)
		}
	}
	field, allowed := start_policy_row_allowed(.Start, .Child, .Started)
	testing.expect(t, allowed, "the row of a start list is refused")
	testing.expect_value(t, field, Wiring_Field.Whole)
}

// The ends that the rule takes, last: the child and the asker with no
// fact; a Started end that the asker started; a Started end that the start
// policy asked for, named by the start policy; a Connected end with its
// three facts.
@(test)
the_ends_of_the_rule_are_taken :: proc(t: ^testing.T) {
	testing.expect(t, wiring_end_allowed(.Child, {}))
	testing.expect(t, wiring_end_allowed(.Asker, {}))
	testing.expect(t, wiring_end_allowed(.Started, {started_by_asker = true}))
	testing.expect(t, wiring_end_allowed(.Started, {asker_is_start_policy = true, started_by_start_policy = true}))
	testing.expect(t, wiring_end_allowed(.Started, {audit_wired_by_root = true}))
	// The fact of the audit opens no other end.
	testing.expect(t, !wiring_end_allowed(.Connected, {audit_wired_by_root = true}))
	testing.expect(t, !wiring_end_allowed(.None, {audit_wired_by_root = true}))
	testing.expect(t, wiring_end_allowed(.Connected, {asker_acts_for_principal = true, process_is_a_service = true, asker_holds_a_connection = true}))
}
