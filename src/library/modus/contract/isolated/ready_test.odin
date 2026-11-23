#+build !freestanding
package isolated

import "core:testing"
import "modus:contract/call_outcome"
import module "modus:contract/module"
import "modus:contract/ring"

@(test)
test_ready_of_first_completion_refuses :: proc(t: ^testing.T) {
	// The answer of a call, with each tag from 1 to the largest.
	for tag in ([]u32{1, 2, max(u32)}) {
		testing.expect_value(t, ready_of_first_completion({kind = u32(call_outcome.Call_Outcome.Succeeded), tag = tag}), Ready_Reading.Refused)
	}
	// Each outcome that no first completion gives, the first word past the
	// last outcome, and the largest word.
	for kind in ([]u32{u32(call_outcome.Call_Outcome.Name_Already_Taken), u32(call_outcome.Call_Outcome.Operation_Unsupported), u32(call_outcome.Call_Outcome.Callee_Stopped_During_The_Call), u32(call_outcome.Call_Outcome.Answer_Unreadable), u32(max(call_outcome.Call_Outcome)) + 1, max(u32)}) {
		testing.expect_value(t, ready_of_first_completion({kind = kind, tag = READY_TAG}), Ready_Reading.Refused)
	}
	// The ready kind with a value that is not zero, in the first and the
	// last place.
	with_first := ready_record()
	with_first.values[0] = 1
	testing.expect_value(t, ready_of_first_completion(with_first), Ready_Reading.Refused)
	with_last := ready_record()
	with_last.values[6] = max(u64)
	testing.expect_value(t, ready_of_first_completion(with_last), Ready_Reading.Refused)
	failed_with_value := load_failed_record(.Bind)
	failed_with_value.values[3] = 7
	testing.expect_value(t, ready_of_first_completion(failed_with_value), Ready_Reading.Refused)
}

@(test)
test_ready_of_first_completion_reads :: proc(t: ^testing.T) {
	// A load that the load source cannot find names nothing; each other
	// stage refuses the file. Both read as a failed load.
	testing.expect_value(t, ring.Record(load_failed_record(.Find)).kind, u32(call_outcome.Call_Outcome.Nothing_Has_That_Name))
	for stage in module.Load_Stage {
		if stage != .Find {
			testing.expect_value(t, load_failed_record(stage).kind, u32(call_outcome.Call_Outcome.Argument_Refused))
		}
		testing.expect_value(t, ready_of_first_completion(load_failed_record(stage)), Ready_Reading.Load_Failed)
	}
	testing.expect_value(t, ready_of_first_completion(ready_record()), Ready_Reading.Ready)
}

// The ready completion crosses a ring as the first completion: the reader
// pops it first, and the answer of a call after it.
@(test)
test_ready_record_crosses_a_ring :: proc(t: ^testing.T) {
	memory := make([]u8, ring.pages(ring.CAPACITY) * ring.PAGE_SIZE)
	defer delete(memory)
	server, server_ok := ring.open(raw_data(memory), ring.PAGE_COUNT)
	caller, caller_ok := ring.open(raw_data(memory), ring.PAGE_COUNT)
	testing.expect(t, server_ok && caller_ok)
	_, popped := ring.pop(&caller.completions)
	testing.expect(t, !popped, "an empty ring has no first completion")
	testing.expect(t, ring.push(&server.completions, ready_record()))
	testing.expect(t, ring.push(&server.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = 1}))
	first, first_ok := ring.pop(&caller.completions)
	testing.expect(t, first_ok)
	testing.expect_value(t, ready_of_first_completion(first), Ready_Reading.Ready)
	second, second_ok := ring.pop(&caller.completions)
	testing.expect(t, second_ok)
	testing.expect_value(t, ready_of_first_completion(second), Ready_Reading.Refused)
}
