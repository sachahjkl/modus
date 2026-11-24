#+build !freestanding
package system

import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/isolated"
import module "modus:contract/module"

// The deadline of a call: no deadline never passes, even at the largest
// time; a deadline passes at its own time and after it, and not one
// millisecond before; a deadline already past at the start passes.
@(test)
a_deadline_passes_at_its_time_and_after :: proc(t: ^testing.T) {
	testing.expect(t, !deadline_passed(0, 0))
	testing.expect(t, !deadline_passed(max(u64), 0))
	testing.expect(t, !deadline_passed(99, 100))
	testing.expect(t, deadline_passed(100, 100))
	testing.expect(t, deadline_passed(101, 100))
	testing.expect(t, deadline_passed(max(u64), 1))
	testing.expect(t, deadline_passed(1_000_000, 5))
}

// The start of a call host refuses, before any operation of the kernel, a
// handle that its starter puts in the slot of the call ring or of the call
// region, and one mapping past CALL_HOST_ADDED_MAPPING_CAPACITY.
@(test)
a_call_host_refuses_a_context_that_takes_its_call_slots :: proc(t: ^testing.T) {
	load_error: module.Load_Error
	for slot in ([?]int{isolated.GRANT_RING, isolated.GRANT_REGION}) {
		added := Call_Host_Context{}
		added.grants[slot] = {Handle(7), {.Read}}
		_, status := call_host_start(nil, 0, nil, "builder", {}, &load_error, added = &added)
		testing.expect_value(t, status, call_outcome.Call_Outcome.Argument_Refused)
	}
	mappings: [CALL_HOST_ADDED_MAPPING_CAPACITY + 1]Mapping
	added := Call_Host_Context{mappings = mappings[:]}
	_, status := call_host_start(nil, 0, nil, "builder", {}, &load_error, added = &added)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Argument_Refused)
}
