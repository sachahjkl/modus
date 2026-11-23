package system

import "modus:contract/fixed_addresses"
import op "modus:contract/operation"
import "modus:contract/plan_values"

// The copy of the plan values page in the memory of one reader. The records
// that plan_values_of_process gives point into it, never into the page:
// the core writes the page again when the plan of principal 0 changes
// (src/md/features/module_settings.md, "How the values reach their owner").
// Each reader gives its own copy, which lives as long as the records that
// it holds: a later read into another copy never changes them.
Plan_Values_Copy :: struct {
	bytes:    [plan_values.OWNER_PAGE_SIZE]u8,
	sequence: u32, // The sequence of the page that the copy holds.
}

// plan_values_of_process gives the plan values of this process: the
// defaults and the locks that the plan of principal 0 gives its owner, on
// the page that the root service writes at its start and writes again at
// each change of the plan, copied whole into copy. A read that meets a
// write of the core waits on the sequence word until the write ends. A
// process with no page holds the defaults of its contract; a page that the
// border refuses does too, and the log says it.
plan_values_of_process :: proc "contextless" (values: ^[op.CONTEXT_VALUES]u64, copy: ^Plan_Values_Copy) -> (owner_values: plan_values.Owner_Values, found: bool) {
	page, mapped := plan_values_page_of_process(values)
	if !mapped || !plan_values.owner_page_sizes_valid(page, copy.bytes[:]) {
		return {}, false
	}
	for {
		sequence, copied, met := plan_values.owner_page_copy(page, copy.bytes[:])
		if copied {
			copy.sequence = sequence
			break
		}
		// An odd word is a write in progress: the core wakes the word when it
		// ends (owner_page_publish). An even word changed during the copy:
		// copy again at once.
		if met & 1 != 0 {
			word_wait(plan_values.owner_page_sequence(page), met)
		}
	}
	owner_values, found = plan_values.owner_page_read(copy.bytes[:])
	if !found {
		log(.Warning, "plan values: the page of the plan values of this process does not pass its border: the defaults of its contract hold")
	}
	return owner_values, found
}

// plan_values_wait adds the sequence word of the plan values page to a
// wait: the wait ends when the root service writes the page again after the
// read into copy. A process with no page adds nothing.
plan_values_wait :: proc "contextless" (wait: ^Wait, values: ^[op.CONTEXT_VALUES]u64, copy: ^Plan_Values_Copy) {
	page, mapped := plan_values_page_of_process(values)
	if !mapped {
		return
	}
	wait_word(wait, plan_values.owner_page_sequence(page), copy.sequence)
}

// plan_values_changed says if the root service wrote the page again after
// the read into copy: the owner then reads its values again.
plan_values_changed :: proc "contextless" (values: ^[op.CONTEXT_VALUES]u64, copy: ^Plan_Values_Copy) -> bool {
	page, mapped := plan_values_page_of_process(values)
	if !mapped {
		return false
	}
	return plan_values.owner_page_sequence_load(page) != copy.sequence
}

@(private = "file")
plan_values_page_of_process :: proc "contextless" (values: ^[op.CONTEXT_VALUES]u64) -> (page: []u8, mapped: bool) {
	if .Plan_Values_Page not_in fixed_addresses.ranges_mapped(values) {
		return nil, false
	}
	address := uintptr(plan_values.OWNER_PAGE_ADDRESS)
	return ([^]u8)(address)[:plan_values.OWNER_PAGE_SIZE], true
}
