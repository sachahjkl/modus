package system

import "modus:contract/fixed_addresses"
import op "modus:contract/operation"
import "modus:contract/plan_values"

// The copy of the plan values page in the memory of this process. The
// records that plan_values_of_process gives point into it, never into the
// page: the core writes the page again when the plan of principal 0
// changes, and a record that pointed into the page would change under its
// reader (src/md/features/module_settings.md, "Plan records").
@(private = "file")
plan_values_copy: [plan_values.OWNER_PAGE_SIZE]u8

// The sequence of the page that the copy holds.
@(private = "file")
plan_values_copy_sequence: u32

// plan_values_of_process gives the plan values of this process: the
// defaults and the locks that the plan of principal 0 gives its owner, on
// the page that the root service writes at its start and writes again at
// each change of the plan (src/md/features/module_settings.md, "Plan
// records"). A process with no page, a page that the border refuses, or a
// page that no read met whole has no value of the plan: the defaults of
// its contract hold. Each call copies the page again: the records of an
// earlier call then name the new values.
plan_values_of_process :: proc "contextless" (values: ^[op.CONTEXT_VALUES]u64) -> (owner_values: plan_values.Owner_Values, found: bool) {
	page, mapped := plan_values_page_of_process(values)
	if !mapped {
		return {}, false
	}
	sequence, copied := plan_values.owner_page_copy(page, plan_values_copy[:])
	if !copied {
		return {}, false
	}
	plan_values_copy_sequence = sequence
	return plan_values.owner_page_read(plan_values_copy[:])
}

// plan_values_wait adds the sequence word of the plan values page to a
// wait: the wait ends when the root service writes the page again after
// the last plan_values_of_process. A process with no page adds nothing.
plan_values_wait :: proc "contextless" (wait: ^Wait, values: ^[op.CONTEXT_VALUES]u64) {
	page, mapped := plan_values_page_of_process(values)
	if !mapped {
		return
	}
	wait_word(wait, plan_values.owner_page_sequence(page), plan_values_copy_sequence)
}

// plan_values_changed says if the root service wrote the page again after
// the last plan_values_of_process: the owner then reads its values again.
plan_values_changed :: proc "contextless" (values: ^[op.CONTEXT_VALUES]u64) -> bool {
	page, mapped := plan_values_page_of_process(values)
	if !mapped {
		return false
	}
	return plan_values.owner_page_sequence_load(page) != plan_values_copy_sequence
}

@(private = "file")
plan_values_page_of_process :: proc "contextless" (values: ^[op.CONTEXT_VALUES]u64) -> (page: []u8, mapped: bool) {
	if .Plan_Values_Page not_in fixed_addresses.ranges_mapped(values) {
		return nil, false
	}
	address := uintptr(plan_values.OWNER_PAGE_ADDRESS)
	return ([^]u8)(address)[:plan_values.OWNER_PAGE_SIZE], true
}
