package operation

import "modus:contract/enum_word"
import "modus:contract/errors"

// Why `Thread_Control` refused with `Bad_State`: the kernel records this
// member in `Operation_In_Progress` at the point of refusal, and
// `diagnose` turns it into an `errors.Error_Record` through
// `thread_control_state_error`. Keeping the mapping here lets host tests
// check every refusal path without booting a machine.
Thread_Control_State_Refusal :: enum u8 {
	None                 = 0,
	Thread_Absent        = 1,  // Thread number (process-local or machine) names no live thread.
	Process_Absent       = 2,  // Process slot and serial name no live process.
	Thread_Ended         = 3,  // Target thread ended or is stopping.
	Process_Stopped      = 4,  // Target process is stopped or empty.
	Not_Debugger         = 5,  // Caller is not the attached debugger of the target process.
	Stop_Count_Limit     = 6,  // Thread stop count reached THREAD_STOP_COUNT_LIMIT.
	Not_Stopped          = 7,  // Resume with no stop held by this caller.
	Not_Held             = 8,  // Registers, extended state, or breakpoints on a thread that is not held off a processor.
	Counters_Not_Started = 9,  // Read_Counters while the calling thread is not counting.
	Thread_Recording     = 10, // Write_Placement while the thread is recording or replaying.
	Process_Recording    = 11, // Record_Start or Replay_Start while recording or replaying is already active.
	Process_Not_Created  = 12, // Record_Start or Replay_Start on a process that is not Created, or is the caller.
	Process_Disqualified = 13, // Record_Start or Replay_Start on a process disqualified for recording.
	History_In_Use       = 14, // Record_Start or Replay_Start with a history memory object already in use.
	No_Pinned_Processor  = 15, // Record_Start or Replay_Start when no processor can be pinned.
	Not_Recording        = 16, // Record_End on a process not recorded by this caller.
}

// thread_control_state_refusal_of_word is the border of a
// Thread_Control_State_Refusal word.
thread_control_state_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Thread_Control_State_Refusal, ok: bool) {
	return enum_word.member_of_word(Thread_Control_State_Refusal, word)
}

// thread_control_state_error builds the error record for a `Bad_State`
// refusal of `Thread_Control`. Returns false for `None` so `diagnose`
// falls back to `Refused`.
thread_control_state_error :: proc "contextless" (
	refusal: Thread_Control_State_Refusal,
	argument: i64,
	value: u64,
	limit: u64,
	found: u64,
) -> (record: errors.Error_Record, ok: bool) {
	kind: errors.Kind
	unit: errors.Unit
	record_limit := limit
	switch refusal {
	case .None:
		return {}, false
	case .Thread_Absent:
		kind, unit = .Absent, .Threads
	case .Process_Absent:
		kind, unit = .Absent, .Processes
	case .Thread_Ended:
		kind, unit = .State, .Threads
	case .Process_Stopped:
		kind, unit = .State, .Processes
	case .Not_Debugger:
		kind, unit = .State, .Debugged_Processes
	case .Stop_Count_Limit:
		kind, unit = .Over_Limit, .None
		record_limit = THREAD_STOP_COUNT_LIMIT
	case .Not_Stopped:
		kind, unit = .State, .Threads
		record_limit = 1
	case .Not_Held:
		kind, unit = .State, .Held_Threads
		record_limit = 1
	case .Counters_Not_Started:
		kind, unit = .State, .Threads
		record_limit = 1
	case .Thread_Recording:
		kind, unit = .State, .Threads
	case .Process_Recording, .Process_Disqualified, .No_Pinned_Processor, .Not_Recording:
		kind, unit = .State, .Processes
	case .Process_Not_Created:
		kind, unit = .State, .Processes
		record_limit = u64(Process_State.Created)
	case .History_In_Use:
		kind, unit = .Object_Shared, .Memory
	}
	return errors.Error_Record {
		kind      = i64(kind),
		unit      = i64(unit),
		operation = i64(Operation.Thread_Control),
		argument  = argument,
		value     = i64(value),
		limit     = i64(record_limit),
		found     = i64(found),
	}, true
}
