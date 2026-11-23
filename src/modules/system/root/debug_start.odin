package root

// The start of a process held before its first instruction for the debugger
// service (Root_Command.Debug_Start): the kernel records or replays a process
// only before it runs (src/md/features/record_and_replay.md, "Who records,
// and the commands"), and the debugger holds no right to start a process.
// So this service starts it for a caller of the debugger, gives the debugger
// the handle with Debug under the rule of Debug, and lets the process run
// when the debugger asks, or when the debug access ends.

import "modus:contract/call_outcome"
import "modus:contract/root_ring"
import "modus:contract/start_grant"
import "modus:system"

// debug_start runs Debug_Start for the debugger service holder, on behalf
// of the caller of its connection with the call ring of record_values[4].
// values is the completion: for a start the completion of Debug, for a
// release 0; a refusal writes its error record there.
debug_start :: proc "contextless" (holder: ^Started, name: string, record_values: [7]u64, values: ^[7]u64) -> call_outcome.Call_Outcome {
	kind := u32(root_ring.Root_Command.Debug_Start)
	step, border_outcome, border_refusal := root_ring.debug_start_border(record_values)
	if border_outcome != .Succeeded {
		values^ = border_refusal
		return border_outcome
	}
	connection_ring := record_values[4]
	caller, caller_principal, caller_row := debug_caller_of(holder, connection_ring)
	if caller == nil {
		return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Connections, 2)
	}
	held := held_process_of(holder, caller, caller_row)
	hold: Start_Hold
	switch step {
	case .None:
		// The border refuses it; the case keeps the switch whole.
		return root_ring.refuse(values, .Argument_Refused, kind, .Bad_Value, .None, 3)
	case .Release:
		if held == nil || system.name_of(held.name[:]) != name {
			return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Processes, 1)
		}
		if status := held_process_release(held); status != .Ok {
			// A process that cannot start holds its place for nothing: it
			// stops, and the caller sees that change.
			started_process_stop(held)
			return changed_then_refused(values, kernel_refused(values, kind, status))
		}
		values^ = {}
		return .Succeeded
	case .Abandon:
		if held == nil || system.name_of(held.name[:]) != name {
			return root_ring.refuse(values, .Nothing_Has_That_Name, kind, .Absent, .Processes, 1)
		}
		held.held_entry = 0
		started_process_stop(held)
		values^ = {}
		return .Succeeded
	case .Start_Held:
		hold = .At_First_Instruction
	case .Start_Replay:
		hold = .For_Replay
	}
	if .Debug in caller.revoked {
		return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .No_Grant, .Debug_Access, 1)
	}
	if .Acts_For_Principal not_in grants_held(caller) {
		return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .No_Grant, .Acts_For_Principal, 1)
	}
	// The caller starts the process: it needs what Start needs.
	if !root_ring.sender_allowed(.Start, caller.start_grant_set.grants) {
		return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .No_Grant, .Root_Commands, 1)
	}
	// The rule of the debug access, on the start grants that the process
	// gets, before any service starts for it. A replay gets none.
	if hold == .At_First_Instruction {
		probe := Started {
			start_grant_set = start_grant_set_of(name),
		}
		if grant, refuses := debug_refusing_grant(caller, &probe); refuses {
			system.log_fact(.Info, Debug_Access_Refused{caller = module_name_field(system.name_of(caller.name[:])), target = module_name_field(name), grant = text_field(start_grant.GRANT_NAMES[grant], 24)})
			return root_ring.refuse(values, .Grant_Or_Right_Missing, kind, .No_Grant, .Debug_Access, 1, 0, 0, 1 + i64(grant))
		}
	}
	// One held process for each caller: a release names it by its caller.
	// After the grants, so that a caller with no grant learns nothing of
	// the place.
	if held != nil {
		return root_ring.refuse(values, .Callee_Busy, kind, .Full, .Debugged_Processes, 1, 0, 1)
	}
	place: ^Started
	if outcome := start(name, caller_principal, asker = caller, place = &place, refusal = values, hold = hold); outcome != .Succeeded {
		return outcome
	}
	if outcome := debug_give(holder, caller, caller_principal, caller_row, place, name, kind, values); outcome != .Succeeded {
		// No debugger holds the process: it does not run, unseen, from a
		// start that the debugger asked for.
		started_process_stop(place)
		return outcome
	}
	system.log_fact(.Info, Process_Held_For_Debugger{held_process = module_name_field(name), caller = module_name_field(system.name_of(caller.name[:]))})
	return .Succeeded
}

// held_process_of gives the process that Debug_Start holds for a caller of
// a debugger service, or nil.
held_process_of :: proc "contextless" (holder: ^Started, caller: ^Started, caller_row: int) -> ^Started {
	for &item in started {
		if item.process != 0 && item.held_entry != 0 && item.debugger == holder && item.debug_for == caller && item.debug_for_row == caller_row {
			return &item
		}
	}
	return nil
}

// held_process_release lets a held process run from its entry. The process
// is no longer held, whatever the status: a release is tried once. A
// replay keeps its mark: it stays a process with no start grant, whose
// context the history wrote, for as long as it runs.
held_process_release :: proc "contextless" (item: ^Started) -> system.Status {
	entry := item.held_entry
	item.held_entry = 0
	return system.process_release(item.process, entry)
}
