package role_policy

// The amount of the grant of a connection to the holder of Display
// (src/md/features/declarations.md, "The trusted display of a plan"): the
// display serves the dialog of a difference to the holder of Plans, which
// acts for nobody. The root service gives this amount at each connection,
// and gives it again after each change of the roles, so the trust follows
// the role and never the module name.

import pr "modus:contract/plans_recipes"

// display_caller_amount gives the amount of the grant of a connection of
// caller_name to service_name: when the service holds Display,
// DISPLAY_AMOUNT_PLANS_HOLDER for the holder of Plans now, else
// DISPLAY_AMOUNT_ACT_ASKER for a caller whose start grant set has the term
// asks_acts (src/md/features/assistant.md, "The right to ask an act");
// else 0.
display_caller_amount :: proc "contextless" (names: ^Holder_Names, service_name, caller_name: string, asks_acts: bool) -> u64 {
	if !is_holder(names, service_name, .Display) {
		return 0
	}
	if is_holder(names, caller_name, .Plans) {
		return pr.DISPLAY_AMOUNT_PLANS_HOLDER
	}
	if asks_acts {
		return pr.DISPLAY_AMOUNT_ACT_ASKER
	}
	return 0
}
