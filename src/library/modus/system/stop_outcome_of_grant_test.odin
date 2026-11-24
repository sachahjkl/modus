#+build !freestanding
package system

import "modus:contract/call_outcome"
import op "modus:contract/operation"
import "core:testing"

// A context that gave no handle, or a handle of the wrong kind or with a
// missing right, is refused; each other outcome is a failure, which a start
// policy starts again. The handle 0 is refused whatever the outcome,
// Succeeded included; the edges of the handle come first: 0, 1 and the
// largest.
@(test)
a_missing_grant_is_refused_and_each_other_status_fails :: proc(t: ^testing.T) {
	for outcome in call_outcome.Call_Outcome {
		testing.expectf(t, stop_outcome_of_grant(0, outcome) == op.Stop_Outcome.Refused, "the handle 0 with %v is not Refused", outcome)
	}
	for handle in ([]Handle{1, max(Handle)}) {
		testing.expect_value(t, stop_outcome_of_grant(handle, .Argument_Refused), op.Stop_Outcome.Refused)
		testing.expect_value(t, stop_outcome_of_grant(handle, .Grant_Or_Right_Missing), op.Stop_Outcome.Refused)
		for outcome in call_outcome.Call_Outcome {
			if outcome == .Argument_Refused || outcome == .Grant_Or_Right_Missing {
				continue
			}
			testing.expectf(t, stop_outcome_of_grant(handle, outcome) == op.Stop_Outcome.Failed, "the handle %d with %v is not Failed", handle, outcome)
		}
	}
}
