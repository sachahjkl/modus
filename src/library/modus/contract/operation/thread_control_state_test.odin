#+build !freestanding
#+build !modus
package operation

import "core:testing"
import "modus:contract/errors"

// Unknown words are refused by thread_control_state_refusal_of_word at the
// edges: one past the last member, shifted past u8, and max(u64).
@(test)
thread_control_state_refusal_border_refuses_unknown_words :: proc(t: ^testing.T) {
	refused := [?]u64{
		u64(max(Thread_Control_State_Refusal)) + 1,
		u64(max(u8)) + 1,
		u64(max(u8)) + 1 + u64(Thread_Control_State_Refusal.Thread_Absent),
		max(u64),
	}
	for word in refused {
		member, ok := thread_control_state_refusal_of_word(word)
		testing.expectf(t, !ok, "word %d must be refused", word)
		testing.expect_value(t, member, Thread_Control_State_Refusal.None)
	}
	for member in Thread_Control_State_Refusal {
		read, ok := thread_control_state_refusal_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
}

// None produces no error record; every other refusal produces a specific
// record (never Refused) with valid Kind, Unit, Operation, and fields.
@(test)
thread_control_state_error_maps_every_refusal :: proc(t: ^testing.T) {
	none_record, none_ok := thread_control_state_error(.None, 2, 7, 0, 0)
	testing.expect(t, !none_ok)
	testing.expect_value(t, none_record, errors.Error_Record{})

	Case :: struct {
		refusal:        Thread_Control_State_Refusal,
		argument:       i64,
		value:          u64,
		limit:          u64,
		found:          u64,
		expected_kind:  errors.Kind,
		expected_unit:  errors.Unit,
		expected_limit: u64,
	}
	cases := [?]Case {
		{.Thread_Absent, 2, 99, THREAD_CAPACITY - 1, 0, .Absent, .Threads, THREAD_CAPACITY - 1},
		{.Process_Absent, 2, 0x10000_0001, 0, 0, .Absent, .Processes, 0},
		{.Thread_Ended, 1, 0x10005, 0, u64(Process_State.Stopped), .State, .Threads, 0},
		{.Process_Stopped, 1, 0x10003, 0, u64(Process_State.Stopped), .State, .Processes, 0},
		{.Not_Debugger, 1, 0x10004, 0, 0, .State, .Debugged_Processes, 0},
		{.Stop_Count_Limit, 2, THREAD_STOP_COUNT_LIMIT + 1, 0, 0, .Over_Limit, .None, THREAD_STOP_COUNT_LIMIT},
		{.Not_Stopped, 2, 1, 0, u64(Process_State.Ready), .State, .Threads, 1},
		{.Not_Held, 2, 1, 0, u64(Process_State.Ready), .State, .Held_Threads, 1},
		{.Counters_Not_Started, 3, u64(Thread_Control_Command.Read_Counters), 0, u64(Process_State.Ready), .State, .Threads, 1},
		{.Thread_Recording, 2, 0, 0, u64(Process_State.Ready), .State, .Threads, 0},
		{.Process_Recording, 1, 0x10007, 0, u64(Process_State.Created), .State, .Processes, 0},
		{.Process_Not_Created, 1, 0x10008, 0, u64(Process_State.Ready), .State, .Processes, u64(Process_State.Created)},
		{.Process_Disqualified, 1, 0x10009, 0, u64(Process_State.Created), .State, .Processes, 0},
		{.History_In_Use, 2, 0x1000A, 0, 0, .Object_Shared, .Memory, 0},
		{.No_Pinned_Processor, 1, 0x1000B, 0, u64(Process_State.Created), .State, .Processes, 0},
		{.Not_Recording, 1, 0x1000C, 0, u64(Process_State.Ready), .State, .Processes, 0},
	}
	covered: [Thread_Control_State_Refusal]bool
	covered[.None] = true
	for item in cases {
		covered[item.refusal] = true
		record, ok := thread_control_state_error(item.refusal, item.argument, item.value, item.limit, item.found)
		testing.expectf(t, ok, "refusal %v must produce a record", item.refusal)
		kind, kind_ok := errors.kind_of_word(record.kind)
		unit, unit_ok := errors.unit_of_word(record.unit)
		testing.expect(t, kind_ok && unit_ok)
		testing.expect_value(t, kind, item.expected_kind)
		testing.expect_value(t, unit, item.expected_unit)
		testing.expect(t, kind != .Refused)
		testing.expect_value(t, record.operation, i64(Operation.Thread_Control))
		testing.expect_value(t, record.argument, item.argument)
		testing.expect_value(t, record.value, i64(item.value))
		testing.expect_value(t, record.limit, i64(item.expected_limit))
		testing.expect_value(t, record.found, i64(item.found))
	}
	for member in Thread_Control_State_Refusal {
		testing.expectf(t, covered[member], "refusal %v is not covered by a test case", member)
	}
}
