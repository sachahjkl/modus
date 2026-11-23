#+build !freestanding
package storage_status

import "core:testing"
import "modus:contract/call_outcome"

// A commit that the state before refuses as damaged keeps the pending
// changes of the connection; only a race lost drops them. Each outcome is
// tried.
@(test)
a_commit_on_a_damaged_object_keeps_the_pending_changes :: proc(t: ^testing.T) {
	testing.expect(t, !commit_refusal_drops_pending(.Data_Damaged))
	testing.expect(t, commit_refusal_drops_pending(.Another_Change_Came_First))
	for outcome in call_outcome.Call_Outcome {
		testing.expectf(t, commit_refusal_drops_pending(outcome) == (outcome == .Another_Change_Came_First), "the outcome %v", outcome)
	}
}
