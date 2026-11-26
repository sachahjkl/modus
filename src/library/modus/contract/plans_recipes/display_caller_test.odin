#+build !freestanding
#+build !modus
package plans_recipes

import "core:testing"
import "modus:contract/isolated"

@(test)
plan_display_caller_refuses_each_grant_that_names_no_holder_of_plans :: proc(t: ^testing.T) {
	principal_zero := isolated.caller_grant_make(0, 0, false)
	refused := [?]u64 {
		0,
		principal_zero,
		// Another amount: the amount of a store, or one past the holder.
		isolated.caller_grant_make(DISPLAY_AMOUNT_PLANS_HOLDER + 1, 0, false),
		isolated.caller_grant_make(isolated.CALLER_AMOUNT_MASK, 0, false),
		isolated.caller_grant_make(DISPLAY_AMOUNT_PLANS_HOLDER << 1, 0, false),
		// The other flags give nothing.
		isolated.CALLER_READS_ONLY,
		isolated.CALLER_ERASES_VERSIONS,
		isolated.CALLER_PRINCIPAL_MASK,
		isolated.CALLER_READS_ONLY | isolated.CALLER_ERASES_VERSIONS | isolated.CALLER_PRINCIPAL_MASK,
	}
	for grant in refused {
		testing.expectf(t, !plan_display_caller_allowed(grant), "the grant %x names no holder of Plans", grant)
	}
}

@(test)
plan_display_caller_serves_the_holder_of_plans_and_a_caller_that_acts_for_its_principal :: proc(t: ^testing.T) {
	testing.expect(t, plan_display_caller_allowed(isolated.caller_grant_make(0, 1, true)))
	testing.expect(t, plan_display_caller_allowed(isolated.caller_grant_make(DISPLAY_AMOUNT_PLANS_HOLDER, 0, false)))
	testing.expect(t, plan_display_caller_allowed(isolated.caller_grant_make(DISPLAY_AMOUNT_PLANS_HOLDER, 0, false) | isolated.CALLER_READS_ONLY))
}

// The right to ask an act is its own amount: the amount of the holder of
// Plans, another amount, and the other flags open no act dialog, and the
// amount of an asker of acts opens no dialog of a plan.
@(test)
act_display_caller_refuses_each_grant_that_names_no_asker_of_acts :: proc(t: ^testing.T) {
	refused := [?]u64 {
		0,
		isolated.caller_grant_make(0, 0, false),
		isolated.caller_grant_make(DISPLAY_AMOUNT_PLANS_HOLDER, 0, false),
		isolated.caller_grant_make(DISPLAY_AMOUNT_ACT_ASKER + 1, 0, false),
		isolated.caller_grant_make(DISPLAY_AMOUNT_ACT_ASKER | DISPLAY_AMOUNT_PLANS_HOLDER, 0, false),
		isolated.caller_grant_make(isolated.CALLER_AMOUNT_MASK, 0, false),
		isolated.CALLER_READS_ONLY | isolated.CALLER_ERASES_VERSIONS | isolated.CALLER_PRINCIPAL_MASK,
	}
	for grant in refused {
		testing.expectf(t, !act_display_caller_allowed(grant), "the grant %x names no asker of acts", grant)
	}
	testing.expect(t, !plan_display_caller_allowed(isolated.caller_grant_make(DISPLAY_AMOUNT_ACT_ASKER, 0, false)))
	testing.expect(t, act_display_caller_allowed(isolated.caller_grant_make(DISPLAY_AMOUNT_ACT_ASKER, 3, false)))
	testing.expect(t, act_display_caller_allowed(isolated.caller_grant_make(0, 1, true)))
}
