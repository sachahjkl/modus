#+build !freestanding
package root_delegation

import "core:testing"

// The step Loaded is a member of the border; the word after the last step
// and the largest word are refused.
@(test)
plan_roles_step_border_takes_loaded :: proc(t: ^testing.T) {
	step, known := plan_roles_step_of_word(4)
	testing.expect(t, known)
	testing.expect_value(t, step, Plan_Roles_Step.Loaded)
	for word in ([?]u64{0, 5, max(u64)}) {
		_, refused_known := plan_roles_step_of_word(word)
		testing.expectf(t, !refused_known, "word %v", word)
	}
}

// The outcome of Loaded: None, the word after the last member and the
// largest word are refused; each member is read back.
@(test)
plan_roles_load_outcome_border :: proc(t: ^testing.T) {
	for word in ([?]u64{0, 6, 255, 256, max(u64)}) {
		outcome, known := plan_roles_load_outcome_of_word(word)
		testing.expectf(t, !known, "word %v", word)
		testing.expect_value(t, outcome, Plan_Roles_Load_Outcome.None)
	}
	for member in Plan_Roles_Load_Outcome {
		if member == .None {
			continue
		}
		outcome, known := plan_roles_load_outcome_of_word(u64(member))
		testing.expect(t, known)
		testing.expect_value(t, outcome, member)
	}
}

// Only None and Stale_Serial are no refusal of the content of a set: each
// other refusal comes again on each send of the same set.
@(test)
plan_roles_refusal_of_content_names_each_refusal :: proc(t: ^testing.T) {
	for refusal in Plan_Roles_Refusal {
		expected := refusal != .None && refusal != .Stale_Serial
		testing.expectf(t, plan_roles_refusal_of_content(refusal) == expected, "refusal %v", refusal)
	}
}
