#+build !freestanding
package system

import op "modus:contract/operation"
import "core:testing"

// A context that gave no handle, or a handle of the wrong kind or with a
// missing right, is refused; each other status is a failure, which a start
// policy starts again. The handle 0 is refused whatever the status, Ok
// included; the edges of the handle come first: 0, 1 and the largest.
@(test)
a_missing_grant_is_refused_and_each_other_status_fails :: proc(t: ^testing.T) {
	for status in Status {
		testing.expectf(t, stop_outcome_of_grant(0, status) == op.Stop_Outcome.Refused, "the handle 0 with %v is not Refused", status)
	}
	for handle in ([]Handle{1, max(Handle)}) {
		testing.expect_value(t, stop_outcome_of_grant(handle, .Bad_Handle), op.Stop_Outcome.Refused)
		testing.expect_value(t, stop_outcome_of_grant(handle, .No_Right), op.Stop_Outcome.Refused)
		for status in Status {
			if status == .Bad_Handle || status == .No_Right {
				continue
			}
			testing.expectf(t, stop_outcome_of_grant(handle, status) == op.Stop_Outcome.Failed, "the handle %d with %v is not Failed", handle, status)
		}
	}
}
