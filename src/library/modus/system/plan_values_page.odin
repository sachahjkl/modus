package system

import "modus:contract/fixed_addresses"
import op "modus:contract/operation"
import "modus:contract/plan_values"

// plan_values_of_process gives the plan values of this process: the
// defaults and the locks that the plan of principal 0 gives its owner, on
// the page that the root service wrote at its start
// (src/md/features/module_settings.md, "Plan records"). A process with no
// page, or a page that the border refuses, has no value of the plan: the
// defaults of its contract hold. The page never changes after the start, so
// the records point into it for the life of the process.
plan_values_of_process :: proc "contextless" (values: ^[op.CONTEXT_VALUES]u64) -> (owner_values: plan_values.Owner_Values, found: bool) {
	if .Plan_Values_Page not_in fixed_addresses.ranges_mapped(values) {
		return {}, false
	}
	address := uintptr(plan_values.OWNER_PAGE_ADDRESS)
	page := ([^]u8)(address)[:plan_values.OWNER_PAGE_SIZE]
	return plan_values.owner_page_read(page)
}
