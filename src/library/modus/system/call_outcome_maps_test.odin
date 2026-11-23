#+build !freestanding
package system

import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/call_status"
import "modus:contract/isolated"

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

// A status of the path gives an outcome in doubt only when the command can
// have reached the receiver: a stop of the receiver or an answer that the
// reader cannot read. Each other status of the path changed nothing.
@(test)
path_statuses_in_doubt_only_after_the_command_left :: proc(t: ^testing.T) {
	for status in call_status.Call_Status {
		outcome := outcome_of_call_status(status)
		group := call_outcome.effect_group_of(outcome)
		switch status {
		case .Ok, .Failed:
			// The outcome of the export decides: the map gives Succeeded.
			testing.expect_value(t, outcome, call_outcome.Call_Outcome.Succeeded)
		case .Stopped:
			testing.expect_value(t, outcome, call_outcome.Call_Outcome.Callee_Stopped_During_The_Call)
		case .Wrong_Answer, .Failed_With_Wrong_Details:
			testing.expect_value(t, outcome, call_outcome.Call_Outcome.Answer_Unreadable)
		case .Lend_Failed, .No_Room, .Ring_Full, .Refused, .Not_Done:
			testing.expectf(t, group == .Nothing_Changed, "the status %v gives %v, which is not in Nothing_Changed", status, outcome)
		}
	}
	testing.expect_value(t, outcome_of_call_status(.Refused, .Bad_Export), call_outcome.Call_Outcome.Operation_Unsupported)
	testing.expect_value(t, outcome_of_call_status(.Refused, isolated.Status.Bad_Arguments), call_outcome.Call_Outcome.Argument_Refused)
	testing.expect_value(t, outcome_of_call_status(.Ring_Full), call_outcome.Call_Outcome.Callee_Busy)
}
