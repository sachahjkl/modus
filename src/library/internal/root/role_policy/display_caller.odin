package role_policy

// The amount of the grant of a connection to the holder of Display
// (src/md/features/declarations.md, "The trusted display of a plan"): the
// display serves the dialog of a difference to the holder of Plans, which
// acts for nobody. The root service gives this amount at each connection,
// and gives it again after each change of the roles, so the trust follows
// the role and never the module name.

import pr "modus:contract/plans_recipes"

// display_caller_amount gives the amount of the grant of a connection of
// caller_name to service_name: DISPLAY_AMOUNT_PLANS_HOLDER when the service
// holds Display and the caller holds Plans now, else 0.
display_caller_amount :: proc "contextless" (names: ^Holder_Names, service_name, caller_name: string) -> u64 {
	if is_holder(names, service_name, .Display) && is_holder(names, caller_name, .Plans) {
		return pr.DISPLAY_AMOUNT_PLANS_HOLDER
	}
	return 0
}
