package operation

import "modus:contract/enum_word"
import "modus:contract/errors"

// The table of error details of a kernel command (docs/MODULE_CONTRACT.md,
// "Kernel operations"). A command whose kind has this bit names, in its
// last value, a table place of error records in memory of the process.
// When the kernel refuses the command, it writes one error detail for each
// argument that it finds wrong: the error record of the completion first,
// then the others, in the order of the arguments. A command that succeeds
// leaves the table as it was.
//
// Example: `Memory_Create` with a budget handle that names nothing and the
// flags 0x100 gives the status `Bad_Handle`, the error record of the budget,
// and two details: the budget, then the flags.
COMMAND_NAMES_ERROR_DETAILS :: u32(1) << 31

// The value of the command that holds the address of the table place.
ERROR_DETAILS_VALUE :: 6

// The most error details of one command: the error record, then at most
// one for each argument before the table place. A record of the call as a
// whole names no argument, so each argument can have its own detail.
ERROR_DETAILS_MOST :: 1 + ERROR_DETAILS_VALUE

// The table place of the error details of a command: the layout of
// `system.Error_Details`, an Append table of `errors.Error_Record`. The
// kernel writes the records `count ..< capacity` that fit, and sets `count`
// to the count of the full answer: a count above the capacity says that
// details did not fit.
Error_Details_Place :: struct {
	address:  u64, // The first record, in memory of the process.
	count:    u64, // On the command, the records already there; after a refusal, the count of the full answer.
	capacity: u64, // The records that fit at `address`.
}
#assert(size_of(Error_Details_Place) == 24)

// command_takes_error_details says if a command of an operation can name a
// table of error details: its last value is not one of its parameters
// (`Log` uses it), and it is not `Guest_Run`, which the kernel runs before
// the dispatch of the other operations.
command_takes_error_details :: proc "contextless" (operation: Operation) -> bool {
	return operation != .None && operation != .Guest_Run && OPERATIONS[operation].parameters[ERROR_DETAILS_VALUE].form == .None
}

// argument_value_problem says what the form of a parameter refuses in its
// value, from the values of the command alone: a count above its limit
// (`Too_Long`), a flag outside the flags of the form (`Bad_Flags`), a choice
// above its largest value or 0 where 0 names nothing, a bounded value above
// its limit (`Bad_Value`). `limit`
// is the bound that the value passed. `None`: the form refuses nothing in
// it. A handle, an address and a plain value are never refused here.
//
// The check is sound, not complete: each value that it refuses, the
// operation refuses too. Where the limit of a count depends on another
// argument, the count is not checked.
argument_value_problem :: proc "contextless" (operation: Operation, index: int, values: [7]u64) -> (problem: errors.Kind, limit: u64) {
	if index < 0 || index >= len(values) {
		return .None, 0
	}
	parameter := OPERATIONS[operation].parameters[index]
	value := values[index]
	switch parameter.form {
	case .None, .Value, .Handle, .Handle_Or_Zero, .Address:
		// The form refuses nothing in the value alone.
	case .Count:
		if parameter.limit == 0 || !count_limit_holds(operation, index, values) {
			return .None, 0
		}
		if value > parameter.limit {
			return .Too_Long, parameter.limit
		}
	case .Flags:
		if parameter.limit != 0 && value & ~parameter.limit != 0 {
			return .Bad_Flags, parameter.limit
		}
	case .Choice:
		if value > parameter.limit || value == 0 && !choice_zero_names_something(operation, index) {
			return .Bad_Value, parameter.limit
		}
	case .Bounded:
		if value > parameter.limit {
			return .Bad_Value, parameter.limit
		}
	}
	return .None, 0
}

// argument_is_read says if the operation reads the argument at an index with
// the other values of the command. An argument that another argument makes
// unused, or that the operation reads only for a value of another argument
// that is out of its range, is not read: a detail about it would name a
// fault that no value of it can cause. A handle of the form `Handle_Or_Zero`
// with the value 0 is not read either.
//
// The cases: the budget of `Memory_Commit` with `Decommit`; the thread of
// `Thread_Control` with a command out of range; the thread of
// `Fault_Handler_Set` with an end other than `Set`.
argument_is_read :: proc "contextless" (operation: Operation, index: int, values: [7]u64) -> bool {
	if index < 0 || index >= len(values) {
		return false
	}
	parameter := OPERATIONS[operation].parameters[index]
	if parameter.form == .None || parameter.form == .Handle_Or_Zero && values[index] == 0 {
		return false
	}
	switch operation {
	case .None, .Log, .Memory_Create, .Memory_Map, .Memory_Unmap, .Memory_Size, .Process_Create, .Process_Start, .Process_Stop, .Process_State, .Handle_Give, .Handle_Close, .Interrupt_Read, .Device_Create, .Inspect, .Machine_Stop, .Thread_Create, .Thread_Stop, .Thread_State, .Word_Wait, .Word_Wake, .Budget_Create, .Budget_Read, .Handle_State, .Handle_Revoke, .Memory_Physical, .Process_Module, .Strategy_Set, .Memory_Protect, .Fault_Answer, .Events_Set, .Guest_Run, .Log_Read:
		// Each argument of these is read when its form says so. A new
		// operation stops the build here, and its author says which of its
		// arguments it reads.
	case .Memory_Commit:
		// A decommit gives pages back to the budget of the object: it reads
		// no budget handle.
		return index != 1 || transmute(Commit_Flags)values[4] & {.Decommit} == {}
	case .Thread_Control:
		// The command decides what the thread argument names; with no
		// command, the operation returns before it.
		command, known := enum_word.member_of_word(Thread_Control_Command, values[2])
		return index != 0 || known && command != .None
	case .Fault_Handler_Set:
		// The end of the delivery, or a word of no action, returns before
		// the thread is read.
		return index != 0 || values[1] == u64(Fault_Handler_Action.Set)
	}
	return true
}

// count_limit_holds says if the limit of the form of a count holds with the
// other values of the command.
@(private = "file")
count_limit_holds :: proc "contextless" (operation: Operation, index: int, values: [7]u64) -> bool {
	switch operation {
	case .None, .Log, .Memory_Map, .Memory_Unmap, .Memory_Size, .Process_Create, .Process_Start, .Process_Stop, .Process_State, .Handle_Give, .Handle_Close, .Interrupt_Read, .Device_Create, .Inspect, .Machine_Stop, .Thread_Create, .Thread_Stop, .Thread_State, .Word_Wait, .Word_Wake, .Budget_Create, .Budget_Read, .Handle_State, .Handle_Revoke, .Memory_Physical, .Process_Module, .Strategy_Set, .Memory_Commit, .Memory_Protect, .Fault_Handler_Set, .Fault_Answer, .Thread_Control, .Guest_Run, .Log_Read:
		// The limit of the form of each count of these holds alone. A new
		// operation stops the build here.
	case .Memory_Create:
		// A contiguous object has no frame list: its pages have no limit of
		// the form, only what its budget pays.
		flags := transmute(Memory_Flags)values[2]
		return index != 1 || flags & {.Contiguous, .Large_Pages} == {}
	case .Events_Set:
		// With no memory the call takes the table away and reads no count.
		return values[1] != 0
	}
	return true
}

// choice_zero_names_something says if 0 is a value that the operation takes
// for a choice: the level Info of `Log`, and the action `Set` of
// `Fault_Handler_Set`. Each other choice names nothing with 0.
@(private = "file")
choice_zero_names_something :: proc "contextless" (operation: Operation, index: int) -> bool {
	return operation == .Log && index == 3 || operation == .Fault_Handler_Set && index == 1
}
