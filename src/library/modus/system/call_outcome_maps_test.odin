#+build !freestanding
package system

import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/errors"

// A refusal of the kernel changes nothing: each status but Ok maps, in both
// maps, to an outcome of the group Nothing_Changed, and Ok to Succeeded.
@(test)
kernel_refusals_change_nothing :: proc(t: ^testing.T) {
	for status in Status {
		for outcome in ([2]call_outcome.Call_Outcome{outcome_of_status(status), outcome_of_own_status(status)}) {
			if status == .Ok {
				testing.expect_value(t, outcome, call_outcome.Call_Outcome.Succeeded)
				continue
			}
			testing.expectf(t, call_outcome.effect_group_of(outcome) == .Nothing_Changed, "the status %v gives %v, which is not in Nothing_Changed", status, outcome)
		}
	}
}

// A refusal on an object of the callee is never a fault of the caller: no
// change of the arguments or of the grants of the caller makes it run.
@(test)
own_refusals_never_blame_the_caller :: proc(t: ^testing.T) {
	for status in Status {
		outcome := outcome_of_own_status(status)
		testing.expectf(t, outcome != .Argument_Refused && outcome != .Grant_Or_Right_Missing && outcome != .Nothing_Has_That_Name, "the status %v of an object of the callee gives %v", status, outcome)
	}
	testing.expect_value(t, outcome_of_own_status(.Bad_Handle), call_outcome.Call_Outcome.Callee_Unavailable)
	testing.expect_value(t, outcome_of_own_status(.No_Right), call_outcome.Call_Outcome.Callee_Unavailable)
	testing.expect_value(t, outcome_of_own_status(.No_Memory), call_outcome.Call_Outcome.Callee_Busy)
	testing.expect_value(t, outcome_of_own_status(.No_Budget), call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted)
	// The same statuses on a handle that the caller gave are its fault.
	testing.expect_value(t, outcome_of_status(.Bad_Handle), call_outcome.Call_Outcome.Argument_Refused)
	testing.expect_value(t, outcome_of_status(.No_Right), call_outcome.Call_Outcome.Grant_Or_Right_Missing)
}

// The path ends a call with the value 0 and its record, and a caller that
// asked for no record gets the outcome alone.
@(test)
a_failure_of_the_path_gives_zero_and_its_record :: proc(t: ^testing.T) {
	record: errors.Error_Record
	value, outcome := path_failure(&record, .Callee_Busy, errors.error_make(.Full, .Requests, 0, 64, 64))
	testing.expect_value(t, value, 0)
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Callee_Busy)
	testing.expect_value(t, record.kind, i64(errors.Kind.Full))
	value, outcome = path_failure(nil, .Deadline_Passed_During_The_Call, errors.error_make(.No_Answer))
	testing.expect_value(t, value, 0)
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Deadline_Passed_During_The_Call)
}

// A connection is renewed after an outcome of the path only, never after an
// answer of the callee.
@(test)
a_connection_is_renewed_only_when_it_cannot_be_trusted :: proc(t: ^testing.T) {
	for outcome in call_outcome.Call_Outcome {
		in_doubt := call_outcome.effect_group_of(outcome) == .Change_In_Doubt
		testing.expectf(t, connection_to_renew(outcome) == in_doubt, "the outcome %v", outcome)
	}
	testing.expect(t, connection_to_renew(.Answer_Unreadable))
	testing.expect(t, connection_to_renew(.Deadline_Passed_During_The_Call))
	testing.expect(t, !connection_to_renew(.Argument_Refused))
	testing.expect(t, !connection_to_renew(.Callee_Unavailable))
	testing.expect(t, !connection_to_renew(.Succeeded))
}

// The lent handles are tested in the order of the tests of a callee: an
// absent handle or a table of another kind of object is an argument that
// breaks a rule, before a right that a handle lacks; each case first, then
// the one that holds alone.
@(test)
a_lent_handle_is_an_argument_before_a_right :: proc(t: ^testing.T) {
	testing.expect_value(t, lent_handle_outcome(true, false, true), call_outcome.Call_Outcome.Argument_Refused)
	testing.expect_value(t, lent_handle_outcome(false, true, true), call_outcome.Call_Outcome.Argument_Refused)
	testing.expect_value(t, lent_handle_outcome(true, true, false), call_outcome.Call_Outcome.Argument_Refused)
	testing.expect_value(t, lent_handle_outcome(false, false, true), call_outcome.Call_Outcome.Grant_Or_Right_Missing)
	testing.expect_value(t, lent_handle_outcome(false, false, false), call_outcome.Call_Outcome.Succeeded)
}
