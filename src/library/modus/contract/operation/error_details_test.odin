#+build !freestanding
package operation

import "modus:contract/enum_word"
import "core:testing"
import "modus:contract/errors"

// The table place is the layout of an Append table: three words.
@(test)
the_table_place_of_error_details :: proc(t: ^testing.T) {
	testing.expect_value(t, offset_of(Error_Details_Place, address), uintptr(0))
	testing.expect_value(t, offset_of(Error_Details_Place, count), uintptr(8))
	testing.expect_value(t, offset_of(Error_Details_Place, capacity), uintptr(16))
	// The bit is outside each number of an operation, so a kind with it
	// reaches the default branch of the dispatch.
	testing.expect(t, u32(max(Operation)) & COMMAND_NAMES_ERROR_DETAILS == 0)
	testing.expect(t, u32(max(Operation)) < COMMAND_NAMES_ERROR_DETAILS)
}

// The operations that take a table: each one whose last value is free, but
// Guest_Run. Log takes its runs in its fifth value, so its last value is
// free: a refused Log writes its error details too.
@(test)
the_operations_that_take_error_details :: proc(t: ^testing.T) {
	testing.expect(t, !command_takes_error_details(.None))
	testing.expect(t, command_takes_error_details(.Log))
	testing.expect(t, !command_takes_error_details(.Guest_Run))
	testing.expect(t, command_takes_error_details(.Memory_Create))
	testing.expect(t, command_takes_error_details(.Memory_Map))
	testing.expect(t, command_takes_error_details(.Thread_Control))
	for operation in Operation {
		if command_takes_error_details(operation) {
			testing.expectf(t, OPERATIONS[operation].parameters[ERROR_DETAILS_VALUE].form == .None, "%v takes a table and uses its last value", operation)
		}
	}
}

// The form of `Log` is a choice whose 0 names the form Text: a text line
// with a table of error details gives no detail about its form. One past
// the last form, and the largest word, are refused.
@(test)
the_form_of_a_log_record_is_a_choice_of_zero_and_one :: proc(t: ^testing.T) {
	FORM :: 5
	for word in ([2]u64{u64(Log_Record_Form.Text), u64(Log_Record_Form.Fact)}) {
		values := [7]u64{0, 0, 0, 0, 0, word, 0}
		problem, _ := argument_value_problem(.Log, FORM, values)
		testing.expectf(t, problem == .None, "the form %d of Log gives %v", word, problem)
	}
	for word in ([2]u64{u64(max(Log_Record_Form)) + 1, max(u64)}) {
		values := [7]u64{0, 0, 0, 0, 0, word, 0}
		problem, limit := argument_value_problem(.Log, FORM, values)
		testing.expect_value(t, problem, errors.Kind.Bad_Value)
		testing.expect_value(t, limit, u64(max(Log_Record_Form)))
	}
}

// A count above the limit of its form, and one at the limit.
@(test)
a_count_above_its_limit :: proc(t: ^testing.T) {
	values := [7]u64{0, 0, 32, 0, 0, 0, 0}
	problem, limit := argument_value_problem(.Process_Create, 2, values)
	testing.expect_value(t, problem, errors.Kind.Too_Long)
	testing.expect_value(t, limit, u64(31))
	values[2] = 31
	problem, _ = argument_value_problem(.Process_Create, 2, values)
	testing.expect_value(t, problem, errors.Kind.None)
	// Process_Create flags (argument index 3): 0 and No_Clock pass; unknown bits fail with Bad_Flags.
	values = {0, 0, 0, 0, 0, 0, 0}
	problem, _ = argument_value_problem(.Process_Create, 3, values)
	testing.expect_value(t, problem, errors.Kind.None)
	values[3] = transmute(u64)Process_Flags{.No_Clock}
	problem, _ = argument_value_problem(.Process_Create, 3, values)
	testing.expect_value(t, problem, errors.Kind.None)
	for bad_flags in ([3]u64{u64(1) << 1, PROCESS_FLAGS_KNOWN | (u64(1) << 1), max(u64)}) {
		values[3] = bad_flags
		problem, limit = argument_value_problem(.Process_Create, 3, values)
		testing.expect_value(t, problem, errors.Kind.Bad_Flags)
		testing.expect_value(t, limit, u64(PROCESS_FLAGS_KNOWN))
	}
	// A count whose form has no limit is never refused here.
	values = {0, max(u64), 0, 0, 0, 0, 0}
	problem, _ = argument_value_problem(.Budget_Create, 1, values)
	testing.expect_value(t, problem, errors.Kind.None)
}

// The pages of a contiguous object have no limit of the form; the pages of
// another object have.
@(test)
the_pages_of_a_contiguous_object :: proc(t: ^testing.T) {
	values := [7]u64{0, MEMORY_PAGE_LIMIT + 1, 0, 0, 0, 0, 0}
	problem, limit := argument_value_problem(.Memory_Create, 1, values)
	testing.expect_value(t, problem, errors.Kind.Too_Long)
	testing.expect_value(t, limit, u64(MEMORY_PAGE_LIMIT))
	values[2] = transmute(u64)Memory_Flags{.Contiguous}
	problem, _ = argument_value_problem(.Memory_Create, 1, values)
	testing.expect_value(t, problem, errors.Kind.None)
	values[2] = transmute(u64)Memory_Flags{.Large_Pages}
	problem, _ = argument_value_problem(.Memory_Create, 1, values)
	testing.expect_value(t, problem, errors.Kind.None)
}

// Events_Set with no memory takes the table away and reads no count.
@(test)
the_counts_of_events_set :: proc(t: ^testing.T) {
	values := [7]u64{0, 0, 0, EVENT_RULE_CAPACITY + 1, 0, 0, 0}
	problem, _ := argument_value_problem(.Events_Set, 3, values)
	testing.expect_value(t, problem, errors.Kind.None)
	values[1] = 1
	problem, _ = argument_value_problem(.Events_Set, 3, values)
	testing.expect_value(t, problem, errors.Kind.Too_Long)
}

// A flag outside the flags of the form; a form with no flags named refuses
// none.
@(test)
a_flag_outside_its_form :: proc(t: ^testing.T) {
	known := OPERATIONS[.Memory_Create].parameters[2].limit
	values := [7]u64{0, 1, (known + 1) << 4, 0, 0, 0, 0}
	problem, limit := argument_value_problem(.Memory_Create, 2, values)
	testing.expect_value(t, problem, errors.Kind.Bad_Flags)
	testing.expect_value(t, limit, known)
	values[2] = known
	problem, _ = argument_value_problem(.Memory_Create, 2, values)
	testing.expect_value(t, problem, errors.Kind.None)
	// The rights of Handle_Give: any set, the kernel keeps the rights that
	// the handle has.
	values = {0, 0, max(u64), 0, 0, 0, 0}
	problem, _ = argument_value_problem(.Handle_Give, 2, values)
	testing.expect_value(t, problem, errors.Kind.None)
}

// A choice above its largest value, and 0 where it names nothing.
@(test)
a_choice_out_of_its_range :: proc(t: ^testing.T) {
	values := [7]u64{0, u64(max(Inspect_Kind)) + 1, 0, 0, 0, 0, 0}
	problem, limit := argument_value_problem(.Inspect, 1, values)
	testing.expect_value(t, problem, errors.Kind.Bad_Value)
	testing.expect_value(t, limit, u64(max(Inspect_Kind)))
	values[1] = 0
	problem, _ = argument_value_problem(.Inspect, 1, values)
	testing.expect_value(t, problem, errors.Kind.Bad_Value)
	values[1] = u64(Inspect_Kind.System)
	problem, _ = argument_value_problem(.Inspect, 1, values)
	testing.expect_value(t, problem, errors.Kind.None)
	// The level Info of Log and the action Set of Fault_Handler_Set are 0.
	values = {}
	problem, _ = argument_value_problem(.Log, 3, values)
	testing.expect_value(t, problem, errors.Kind.None)
	values[1] = u64(Fault_Handler_Action.Set)
	problem, _ = argument_value_problem(.Fault_Handler_Set, 1, values)
	testing.expect_value(t, problem, errors.Kind.None)
	values[1] = u64(max(Fault_Handler_Action)) + 1
	problem, limit = argument_value_problem(.Fault_Handler_Set, 1, values)
	testing.expect_value(t, problem, errors.Kind.Bad_Value)
	testing.expect_value(t, limit, u64(max(Fault_Handler_Action)))
	values[1] = max(u64)
	problem, _ = argument_value_problem(.Fault_Handler_Set, 1, values)
	testing.expect_value(t, problem, errors.Kind.Bad_Value)
}

// Each bound of the table is the named constant that the kernel checks, so
// the table and the kernel cannot drift apart; each flag mask holds each
// member of its set, and no other bit.
@(test)
the_bounds_of_the_table_are_the_named_constants :: proc(t: ^testing.T) {
	testing.expect_value(t, OPERATIONS[.Log].parameters[2].limit, u64(LOG_TEXT_BYTES_MOST))
	testing.expect_value(t, OPERATIONS[.Process_Create].parameters[2].limit, u64(PROCESS_NAME_BYTES_MOST))
	testing.expect_value(t, OPERATIONS[.Memory_Create].parameters[2].limit, MEMORY_FLAGS_KNOWN)
	testing.expect_value(t, OPERATIONS[.Memory_Map].parameters[3].limit, MAP_FLAGS_KNOWN)
	testing.expect_value(t, OPERATIONS[.Memory_Protect].parameters[2].limit, PROTECT_FLAGS_KNOWN)
	testing.expect_value(t, OPERATIONS[.Memory_Commit].parameters[4].limit, COMMIT_FLAGS_KNOWN)
	testing.expect_value(t, OPERATIONS[.Fault_Handler_Set].parameters[1].limit, u64(max(Fault_Handler_Action)))
	memory_flags: Memory_Flags
	for flag in Memory_Flag {
		memory_flags += {flag}
	}
	testing.expect_value(t, MEMORY_FLAGS_KNOWN, transmute(u64)memory_flags)
	map_flags: Map_Flags
	for flag in Map_Flag {
		map_flags += {flag}
	}
	testing.expect_value(t, MAP_FLAGS_KNOWN, transmute(u64)map_flags)
	commit_flags: Commit_Flags
	for flag in Commit_Flag {
		commit_flags += {flag}
	}
	testing.expect_value(t, COMMIT_FLAGS_KNOWN, transmute(u64)commit_flags)
	// The name of a process fits its field, with the zero byte after it.
	report: Process_Report
	testing.expect_value(t, len(report.name), PROCESS_NAME_BYTES_MOST + 1)
	// The code of Machine_Stop fits the one byte that the host receives.
	testing.expect_value(t, u64(MACHINE_STOP_CODE_MOST), u64(max(u8)))
	testing.expect_value(t, OPERATIONS[.Machine_Stop].parameters[1].limit, u64(MACHINE_STOP_CODE_MOST))
}

// A code of Machine_Stop past the one byte of the host is refused, with the
// bound: one past it and the largest word first, then 0 and the bound.
@(test)
a_stop_code_past_one_byte :: proc(t: ^testing.T) {
	values := [7]u64{0, MACHINE_STOP_CODE_MOST + 1, 0, 0, 0, 0, 0}
	problem, limit := argument_value_problem(.Machine_Stop, 1, values)
	testing.expect_value(t, problem, errors.Kind.Bad_Value)
	testing.expect_value(t, limit, u64(MACHINE_STOP_CODE_MOST))
	values[1] = max(u64)
	problem, limit = argument_value_problem(.Machine_Stop, 1, values)
	testing.expect_value(t, problem, errors.Kind.Bad_Value)
	testing.expect_value(t, limit, u64(MACHINE_STOP_CODE_MOST))
	values[1] = 0
	problem, _ = argument_value_problem(.Machine_Stop, 1, values)
	testing.expect_value(t, problem, errors.Kind.None)
	values[1] = MACHINE_STOP_CODE_MOST
	problem, _ = argument_value_problem(.Machine_Stop, 1, values)
	testing.expect_value(t, problem, errors.Kind.None)
}

// Each layout of the extended state area reads back from its word; a word
// past the last layout names none.
@(test)
each_extended_state_layout_reads_back :: proc(t: ^testing.T) {
	_, past_ok := enum_word.member_of_word(Extended_State_Layout, u64(max(Extended_State_Layout)) + 1)
	testing.expect(t, !past_ok)
	_, largest_ok := enum_word.member_of_word(Extended_State_Layout, max(u64))
	testing.expect(t, !largest_ok)
	for layout in Extended_State_Layout {
		read, ok := enum_word.member_of_word(Extended_State_Layout, u64(layout))
		testing.expect(t, ok)
		testing.expect_value(t, read, layout)
	}
}

// An argument that the other values make unused is not read, so it gets no
// detail; a handle of the form Handle_Or_Zero with 0 is not read either.
@(test)
the_arguments_that_the_operation_reads :: proc(t: ^testing.T) {
	values := [7]u64{1, 5, 0, 1, transmute(u64)Commit_Flags{.Decommit}, 0, 0}
	testing.expect(t, !argument_is_read(.Memory_Commit, 1, values))
	testing.expect(t, argument_is_read(.Memory_Commit, 0, values))
	values[4] = 0
	testing.expect(t, argument_is_read(.Memory_Commit, 1, values))
	// A commit reads its budget when it is 0 too: 0 names no budget, and
	// the kernel refuses it with a detail of the budget.
	values[1] = 0
	testing.expect(t, argument_is_read(.Memory_Commit, 1, values))
	values[4] = transmute(u64)Commit_Flags{.Frames_Now}
	testing.expect(t, argument_is_read(.Memory_Commit, 1, values))
	values[4] = transmute(u64)Commit_Flags{.Decommit}
	testing.expect(t, !argument_is_read(.Memory_Commit, 1, values))
	// A flag that the kernel does not know beside Decommit: still a
	// decommit for the read of the budget, and refused for its flags.
	values[4] = transmute(u64)Commit_Flags{.Decommit} | 1 << 40
	testing.expect(t, !argument_is_read(.Memory_Commit, 1, values))
	// Thread_Control: the thread is read only with a command in range.
	values = {5, 0, 0, 0, 0, 0, 0}
	testing.expect(t, !argument_is_read(.Thread_Control, 0, values))
	values[2] = u64(max(Thread_Control_Command)) + 1
	testing.expect(t, !argument_is_read(.Thread_Control, 0, values))
	values[2] = u64(Thread_Control_Command.Stop)
	testing.expect(t, argument_is_read(.Thread_Control, 0, values))
	// A command of no member, past the width of a cast, reads no thread.
	values[2] = u64(max(u32)) + 1 + u64(Thread_Control_Command.Stop)
	testing.expect(t, !argument_is_read(.Thread_Control, 0, values))
	values[2] = max(u64)
	testing.expect(t, !argument_is_read(.Thread_Control, 0, values))
	// Fault_Handler_Set: the end of the delivery, and a word of no action,
	// read no thread.
	values = {5, u64(Fault_Handler_Action.End), 0, 0, 0, 0, 0}
	testing.expect(t, !argument_is_read(.Fault_Handler_Set, 0, values))
	values[1] = u64(max(Fault_Handler_Action)) + 1
	testing.expect(t, !argument_is_read(.Fault_Handler_Set, 0, values))
	values[1] = u64(Fault_Handler_Action.Set)
	testing.expect(t, argument_is_read(.Fault_Handler_Set, 0, values))
	// A parameter that the operation does not have.
	testing.expect(t, !argument_is_read(.Memory_Size, 1, values))
	testing.expect(t, !argument_is_read(.Memory_Size, len(values), values))
}

// Map_Flag.Receive_Handles is accepted by Memory_Map and refused by
// Memory_Protect; unknown bits past the known flags and max(u64) are
// refused by both.
@(test)
receive_handles_flag_for_map_and_protect :: proc(t: ^testing.T) {
	receive := transmute(u64)Map_Flags{.Receive_Handles}
	write_receive := transmute(u64)Map_Flags{.Write, .Receive_Handles}
	unknown_bit := u64(1) << (u64(max(Map_Flag)) + 1)
	// Edges refused by Memory_Protect: Receive_Handles alone, with Write, unknown bit, max(u64).
	for bad in ([4]u64{receive, write_receive, unknown_bit, max(u64)}) {
		values := [7]u64{0, 1, bad, 0, 0, 0, 0}
		problem, limit := argument_value_problem(.Memory_Protect, 2, values)
		testing.expect_value(t, problem, errors.Kind.Bad_Flags)
		testing.expect_value(t, limit, PROTECT_FLAGS_KNOWN)
	}
	// Edges refused by Memory_Map: unknown bit, max(u64).
	for bad in ([2]u64{unknown_bit, max(u64)}) {
		values := [7]u64{0, 0, 0, bad, 0, 0, 0}
		problem, limit := argument_value_problem(.Memory_Map, 3, values)
		testing.expect_value(t, problem, errors.Kind.Bad_Flags)
		testing.expect_value(t, limit, MAP_FLAGS_KNOWN)
	}
	// Accepted by Memory_Map: 0, Receive_Handles, Write|Receive_Handles.
	for good in ([3]u64{0, receive, write_receive}) {
		values := [7]u64{0, 0, 0, good, 0, 0, 0}
		problem, _ := argument_value_problem(.Memory_Map, 3, values)
		testing.expect_value(t, problem, errors.Kind.None)
	}
	// Accepted by Memory_Protect: 0, Write, Execute, No_Access.
	for good in ([4]u64{0, transmute(u64)Map_Flags{.Write}, transmute(u64)Map_Flags{.Execute}, transmute(u64)Map_Flags{.No_Access}}) {
		values := [7]u64{0, 1, good, 0, 0, 0, 0}
		problem, _ := argument_value_problem(.Memory_Protect, 2, values)
		testing.expect_value(t, problem, errors.Kind.None)
	}
}

// A handle, an address and a value outside the command are never refused
// here: the kernel checks a handle against the table of the process.
@(test)
what_the_form_alone_does_not_refuse :: proc(t: ^testing.T) {
	values := [7]u64{max(u64), max(u64), 0, 0, 0, 0, 0}
	problem, _ := argument_value_problem(.Memory_Map, 0, values)
	testing.expect_value(t, problem, errors.Kind.None)
	problem, _ = argument_value_problem(.Process_Create, 1, values)
	testing.expect_value(t, problem, errors.Kind.None)
	problem, _ = argument_value_problem(.Memory_Map, 7, values)
	testing.expect_value(t, problem, errors.Kind.None)
	problem, _ = argument_value_problem(.Memory_Map, -1, values)
	testing.expect_value(t, problem, errors.Kind.None)
}
