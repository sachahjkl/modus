// The default start policy, and the rescue start policy with the rescue
// list (src/md/features/start_policy.md). It reads the machine parts page
// and the list through their borders, starts each row in its order, sends
// Machine_Usable when each row with the mark Needed runs, then starts a
// row again at its stop within its restarts. The start of a writer row
// carries the wiring list that internal:start_policy/wiring_rows
// decides. Its one grant is Start_Policy: a root ring for Start, Stop,
// Machine_Usable and Wire, and the machine parts page. The tool refuses its
// source past 400 lines and an import past its set: it holds no logic of
// its own. No window; one line for each row that does not start.
package start_policy

import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:contract/start_list"
import "modus:contract/value_kinds"
import "internal:start_policy/wiring_rows"
import "modus:system"

// 32 pages for what it maps at its start, with their page tables, and the
// reserve of its wirings, which the tool checks against each list.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 96, processes = 1, threads = 1}
#assert(MODULE_BUDGET.working_memory_pages == 32 + start_list.WIRING_PAGES_RESERVE)

// The state of one row while the machine runs.
Row_State :: struct {
	row:           start_list.Start_Row,
	process:       system.Handle, // The process of the row, with the rights Read and Give. 0: it does not run.
	restarts_left: u32,
}

// The root ring, its memory for the lends, and the tag of the next command.
requests: ring.Ring
requests_memory: system.Handle
next_tag: u32 = 1

// The list, its rows, and the list page, which the first writer asks for.
list: start_list.List
states: [start_list.ROW_CAPACITY]Row_State
list_page: []u8

// Each stop before Machine_Usable writes its line first, and the root
// service then starts the rescue start policy. A list that is absent or
// refused is a refused input; each other stop is a failure.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	ring_status: system.Status
	requests_memory = ctx.handles[system.GRANT_ROOT]
	requests, ring_status = system.ring_open(requests_memory)
	if ring_status != .Ok {
		system.log_fact(.Error, Root_Ring_Refused{status = ring_status})
		system.stop(.Failed)
	}
	// The root service maps the page and the list together: with no list,
	// it mapped neither, and a read of the page would fault.
	list_size := ctx.values[start_list.VALUE_LIST_SIZE]
	if list_size == 0 {
		system.log_fact(.Error, No_Start_List{})
		system.stop(.Refused)
	}
	parts, _, _, page_read := start_list.parts_page_read(rawptr(uintptr(start_list.MACHINE_PARTS_PAGE_ADDRESS)))
	if !page_read {
		system.log_fact(.Error, Machine_Parts_Page_Refused{})
		system.stop(.Failed)
	}
	list_start := ([^]u8)(uintptr(start_list.START_LIST_ADDRESS))
	bytes := list_start[:list_size]
	problem, place, _ := start_list.list_read(bytes, &list)
	if problem != .None {
		system.log_fact(.Error, Start_List_Refused{row = u64(place), list_problem = value_kinds.text_field(start_list.LIST_PROBLEM_TEXTS[problem], LIST_PROBLEM_FIELD_BYTES)})
		system.stop(.Refused)
	}
	count := list.row_count
	for index in 0 ..< count {
		states[index] = {row = list.rows[index], restarts_left = list.rows[index].restart_count}
	}
	system.log_fact(.Info, Start_List_Read{rows = u64(count)})
	for &state, index in states[:count] {
		name := start_list.row_name(&state.row)
		if missing := state.row.needs - parts; missing != {} && state.row.absent_rule == .Not_Started {
			system.log_fact(.Info, Row_Not_Started{row_process = value_kinds.module_name_field(name), missing_part = value_kinds.text_field(start_list.PART_NAMES[start_list.first_part(missing)], PART_FIELD_BYTES)})
			continue
		}
		if !row_start(index) && state.row.usable_mark == .Needed {
			system.log_fact(.Error, Machine_Not_Usable_Without{row_process = value_kinds.module_name_field(name)})
			system.stop(.Failed)
		}
	}
	if status, _ := command_call(.Machine_Usable, {}); status != .Ok {
		system.log_fact(.Error, Machine_Usable_Refused{status = status})
		system.stop(.Failed)
	}
	system.log_fact(.Info, Machine_Usable{})
	for {
		wait := system.wait_begin()
		started := false
		for index in 0 ..< count {
			started |= row_watch(index)
		}
		// The wait of a start can take the event of the stop of the process
		// that it started, so the rows are read again before any wait.
		if started {
			continue
		}
		system.wait_end(&wait) // The stop of a process that it holds ends the wait.
	}
}

// row_start asks for the start of the row index, with the wiring list that
// wiring_rows decides. false: it did not start, with one line.
row_start :: proc "contextless" (index: int) -> bool {
	state := &states[index]
	row_process := value_kinds.module_name_field(start_list.row_name(&state.row))
	running: [start_list.ROW_CAPACITY]bool
	for &other, other_index in states[:list.row_count] {
		if other.process != 0 {
			other_state, _, _ := system.process_state(other.process)
			running[other_index] = other_state != .Stopped
		}
	}
	if list_page == nil && wiring_rows.row_has_wirings(&list, index) {
		// A refusal holds its error record in the values: only an answer
		// Ok names the page.
		status, values := command_call(.Wire, {0 = u64(root_ring.Wire_Step.List_Page)})
		address: rawptr
		if status == .Ok {
			address, status = system.memory_map(system.Handle(values[0]))
		}
		if status != .Ok {
			system.log_fact(.Warning, Row_Wiring_Refused{status = status, row_process = row_process})
			return false
		}
		list_page = ([^]u8)(address)[:wiring_rows.PAGE_BYTES]
		system.close(system.Handle(values[1])) // The root service gives a start policy no end to read: its wiring ring stays empty.
	}
	prepared := wiring_rows.row_list_prepare(&list, index, running[:list.row_count], list_page, reader_lend)
	if prepared.give_back {
		command_call(.Wire, {0 = u64(root_ring.Wire_Step.Apply)})
	}
	switch prepared.outcome {
	case .Reader_Not_Running:
		system.log_fact(.Warning, Row_Reader_Not_Running{reader_row = prepared.reader_row, row_process = row_process})
		return false
	case .Lend_Refused, .List_Not_Written:
		system.log_fact(.Warning, Row_Wiring_Refused{reader_row = prepared.reader_row, status = prepared.status, row_process = row_process})
		return false
	case .No_List, .Listed:
	}
	wiring := prepared.outcome == .Listed ? root_ring.Start_Wiring_List.In_The_List_Page : .None
	packed := system.name_pack(start_list.row_name(&state.row))
	status, values := command_call(.Start, {packed[0], packed[1], packed[2], packed[3], u64(wiring), 0, 0})
	if status != .Ok {
		system.log_fact(.Warning, Row_Start_Refused{status = status, row_process = row_process})
		return false
	}
	state.process = system.Handle(values[0])
	return true
}

// reader_lend lends the process of a reader row through the root ring.
reader_lend :: proc "contextless" (reader_row: int) -> (u32, system.Status) {
	given, status := system.give(requests_memory, states[reader_row].process, {.Read})
	return u32(given), status
}

// row_watch starts a stopped row again within its restarts, unless it
// stopped itself with Done or Refused. A row with no restart writes no
// line: the root service wrote the stop. started: it asked for a start.
row_watch :: proc "contextless" (index: int) -> (started: bool) {
	state := &states[index]
	if state.process == 0 {
		return false
	}
	process_state, cause, outcome := system.process_state(state.process)
	if process_state != .Stopped {
		return false
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
	row_start(index)
	return true
}

// command_call sends one command of the root ring and waits for its
// completion: with one command in flight, the ring has room for it. A
// completion of another tag is a fault of the root service: one line.
command_call :: proc "contextless" (command: root_ring.Root_Command, arguments: [7]u64) -> (status: system.Status, values: [7]u64) {
	tag := next_tag
	next_tag += 1
	if !system.send(&requests.commands, ring.Record{kind = u32(command), tag = tag, values = arguments}) {
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
