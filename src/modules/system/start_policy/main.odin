// The default start policy: it reads a start list in its order, and asks
// the root service for each start (src/md/features/start_policy.md).
//
// **What it is for.** The root service keeps the mechanism of the start
// and holds no order: it starts this one process, which holds the policy.
// The same module is the rescue start policy, with the rescue list: the
// code of the rescue then runs at each start and in each machine test.
//
// **What it does.** It reads the machine parts page, then the list, each
// through its border in modus:contract/start_list, which refuses a word
// that names no member. It starts each row in its order, and waits for the
// completion of each Start before the next one. A row whose part is absent
// starts or not by its rule, with one line when it does not. When each row
// with the mark Needed runs, or did not start because its part is absent,
// it sends Machine_Usable. Then it stays, and starts a row again at its
// stop, within the count of its restarts for the whole run of the machine,
// unless the row stopped itself with Done or Refused.
//
// **What it cannot do.** It holds no graph and no logic of its own: the
// tool refuses its source past 400 lines, and an import past base:, the
// root ring, the ring, the start list and the support package system. Its
// one grant is Start_Policy: a root ring for Start, Stop and Machine_Usable,
// and the machine parts page, read-only. It has no window, no store and no
// right of the machine.
//
// **What a reader sees.** No window. The log gets
// `start_policy: the start list has N rows: each starts in its order`, one
// line for each row that does not start, with its cause, then
// `start_policy: each needed row runs: the machine is usable`.
package start_policy

import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:contract/start_list"
import "modus:contract/value_kinds"
import "modus:support/system"

// One thread and the rows on its stack, which the tool counts; the working
// memory pays what the process maps at its start: its root ring and its
// region, the machine parts page and the start list, with their page tables.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 32, processes = 1, threads = 1}

// The state of one row while the machine runs.
Row_State :: struct {
	row:           start_list.Start_Row,
	process:       system.Handle, // The process of the row, with the right Read. 0: it does not run.
	restarts_left: u32,
}

// The root ring, and the tag of the next command.
requests: ring.Ring
next_tag: u32 = 1

// Each stop before Machine_Usable writes its line first, and the root
// service then starts the rescue start policy. A list that is absent or
// refused is a refused input; each other stop is a failure.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	ring_status: system.Status
	requests, ring_status = system.ring_open(ctx.handles[system.GRANT_ROOT])
	if ring_status != .Ok {
		system.log(.Error, "start_policy: the root ring does not open: status ", ring_status)
		system.stop(.Failed)
	}
	// The root service maps the page and the list together: with no list,
	// it mapped neither, and a read of the page would fault.
	list_size := ctx.values[start_list.VALUE_LIST_SIZE]
	if list_size == 0 {
		system.log(.Error, "start_policy: the context names no start list: no row starts")
		system.stop(.Refused)
	}
	parts, _, _, page_read := start_list.parts_page_read(rawptr(uintptr(start_list.MACHINE_PARTS_PAGE_ADDRESS)))
	if !page_read {
		system.log(.Error, "start_policy: the machine parts page is refused: no row starts")
		system.stop(.Failed)
	}
	rows: [start_list.ROW_CAPACITY]start_list.Start_Row
	list_start := ([^]u8)(uintptr(start_list.START_LIST_ADDRESS))
	bytes := list_start[:list_size]
	count, problem, place := start_list.list_read(bytes, &rows)
	if problem != .None {
		system.log_fact(.Error, Start_List_Refused{row = u64(place), list_problem = value_kinds.text_field(start_list.LIST_PROBLEM_TEXTS[problem], LIST_PROBLEM_FIELD_BYTES)})
		system.stop(.Refused)
	}
	states: [start_list.ROW_CAPACITY]Row_State
	for index in 0 ..< count {
		states[index] = {row = rows[index], restarts_left = rows[index].restart_count}
	}
	system.log_fact(.Info, Start_List_Read{rows = u64(count)})
	for &state in states[:count] {
		name := start_list.row_name(&state.row)
		if missing := state.row.needs - parts; missing != {} && state.row.absent_rule == .Not_Started {
			system.log_fact(.Info, Row_Not_Started{row_process = value_kinds.module_name_field(name), missing_part = value_kinds.text_field(start_list.PART_NAMES[first_part(missing)], PART_FIELD_BYTES)})
			continue
		}
		if !row_start(&state) && state.row.usable_mark == .Needed {
			system.log_fact(.Error, Machine_Not_Usable_Without{row_process = value_kinds.module_name_field(name)})
			system.stop(.Failed)
		}
	}
	if status, _ := command_call(.Machine_Usable, ""); status != .Ok {
		system.log(.Error, "start_policy: the root service refused Machine_Usable: status ", status)
		system.stop(.Failed)
	}
	system.log(.Info, "start_policy: each needed row runs: the machine is usable")
	for {
		wait := system.wait_begin()
		for &state in states[:count] {
			row_watch(&state)
		}
		// The stop of a process that this process holds is an event of its
		// thread: the wait ends with it.
		system.wait_end(&wait)
	}
}

// first_part gives the first part of a set that is not empty.
first_part :: proc "contextless" (parts: start_list.Machine_Parts) -> start_list.Machine_Part {
	for part in start_list.Machine_Part {
		if part in parts {
			return part
		}
	}
	return .Screen
}

// row_start asks the root service for the start of one row, and keeps the
// handle of its process. false: the root service refused it, with one line.
row_start :: proc "contextless" (state: ^Row_State) -> bool {
	name := start_list.row_name(&state.row)
	status, values := command_call(.Start, name)
	if status != .Ok {
		system.log(.Warning, "start_policy: cannot start ", system.Module_Name{name}, ": status ", status)
		return false
	}
	state.process = system.Handle(values[0])
	return true
}

// row_watch reads whether the process of a row stopped, and starts it again
// while the row has restarts left, unless it stopped itself with Done or
// Refused. A row with no restart writes no line: the root service already
// wrote the stop.
row_watch :: proc "contextless" (state: ^Row_State) {
	if state.process == 0 {
		return
	}
	process_state, cause, outcome := system.process_state(state.process)
	if process_state != .Stopped {
		return
	}
	system.close(state.process)
	state.process = 0
	// A stop of the row by itself has its outcome, and each other stop has
	// none: each sentence is a fact type, as for the stops of the root
	// service.
	row_process := value_kinds.module_name_field(start_list.row_name(&state.row))
	stopped_itself := cause == .Itself
	if !start_list.stop_restarts(outcome) {
		if state.row.restart_count != 0 {
			if stopped_itself {
				system.log_fact(.Info, Row_Stopped_Not_Restarted{cause = cause, outcome = outcome, row_process = row_process})
			} else {
				system.log_fact(.Info, Row_Stopped_Not_Restarted_Without_Outcome{cause = cause, row_process = row_process})
			}
		}
		return
	}
	if state.restarts_left == 0 {
		if state.row.restart_count != 0 {
			if stopped_itself {
				system.log_fact(.Warning, Row_Stopped_Past_Restarts{restarts = state.row.restart_count, cause = cause, outcome = outcome, row_process = row_process})
			} else {
				system.log_fact(.Warning, Row_Stopped_Past_Restarts_Without_Outcome{restarts = state.row.restart_count, cause = cause, row_process = row_process})
			}
		}
		return
	}
	state.restarts_left -= 1
	if stopped_itself {
		system.log_fact(.Info, Row_Restarted{restarts_left = state.restarts_left, cause = cause, outcome = outcome, row_process = row_process})
	} else {
		system.log_fact(.Info, Row_Restarted_Without_Outcome{restarts_left = state.restarts_left, cause = cause, row_process = row_process})
	}
	row_start(state)
}

// command_call sends one command of the root ring with a name, and waits
// for its completion. The root service answers each command, and this
// process has one command in flight, so the ring always has room for it.
// A completion of another tag is a fault of the root service: one line,
// and the wait goes on for the tag of the command.
command_call :: proc "contextless" (command: root_ring.Root_Command, name: string) -> (status: system.Status, values: [7]u64) {
	packed := system.name_pack(name)
	tag := next_tag
	next_tag += 1
	if !system.send(&requests.commands, ring.Record{kind = u32(command), tag = tag, values = {packed[0], packed[1], packed[2], packed[3], 0, 0, 0}}) {
		return .No_Slot, {}
	}
	for {
		wait := system.wait_begin()
		if answer, received := system.receive(&requests.completions); received {
			if answer.tag != tag {
				system.log_fact(.Warning, Completion_Tag_Refused{tag = u64(answer.tag)})
				continue
			}
			read, refusal := system.status_of_word(answer.kind)
			if refusal.kind != 0 {
				system.log_fact(.Warning, Completion_Status_Refused{status_word = u64(answer.kind)})
				return .Bad_Operation, {}
			}
			return read, answer.values
		}
		system.wait_records(&wait, &requests.completions)
		system.wait_end(&wait)
	}
}
