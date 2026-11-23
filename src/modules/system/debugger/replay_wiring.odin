// The record of the debugged process: its input history, which the kernel
// writes, and the checkpoints that the service keeps of it
// (src/md/features/record_and_replay.md, "The debugger: step back, and a
// watch back").
//
// The service never writes a byte of the history: it maps it without Write,
// and reads its header through the border of the contract, which copies
// the header once before it checks it, because the kernel writes it during
// each kernel entry of the recorded thread.
package debugger

import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/input_history"
import "modus:contract/isolated"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:system"

// The pages of the input history: 64 KiB, the header and about one thousand
// kernel entries of a small process.
HISTORY_PAGES :: 16
// The point copies that the kernel takes from the budget of the history at
// a start: one page each, at most POINT_COPY_CAPACITY in the kernel.
POINT_COPY_PAGES :: 32

// Where the record of the debugged process is.
Record_State :: enum u8 {
	None      = 0, // The service started no record of the process of the session.
	Recording = 1, // The kernel writes the history.
	Ended     = 2, // The history has its end record: the service, the kernel or the bound ended it.
	Replaying = 3, // A replay of the module runs from the history (replay_start).
	Replayed  = 4, // The replay ended: the header of the history says why.
}

// The record of the process of the session. It stays after the session,
// for the same caller, so that a history whose process stopped can still
// be read and replayed; the next record, and the end of the connection of
// its caller, forget it.
Record_Session :: struct {
	state:       Record_State,
	caller_ring: system.Handle, // The call ring of the caller that recorded: only this caller reads the history.
	name:        [32]u8, // The module that was recorded: a replay starts it again.
	name_count:  int,
	history:     system.Handle, // The contiguous memory object of the history: Read and Write, for the kernel.
	bytes:       []u8, // Its mapping in this process, without Write.
	checkpoints: input_history.Checkpoint_Ring,
	// The process of the replay: the handle with Debug from the root
	// service, and its slot and serial for the reports of Inspect. 0: none.
	replay_process: system.Handle,
	replay_slot:    u64,
	replay_serial:  u64,
	// The first divergence of the last replay, read once from the history
	// when its header says that the replay diverged: the kernel writes that
	// end once, and a replay_status() then reads no record again.
	divergence_read:   Divergence_Read,
	divergence_report: input_history.Divergence_Report,
}

// Whether the service read the first divergence of the last replay.
Divergence_Read :: enum u8 {
	Not_Read = 0, // No replay diverged since the last replay began.
	Read     = 1, // divergence_report holds it.
	Damaged  = 2, // A record before its point failed the border: only the header shows the point.
}

record_session: Record_Session

@(rodata)
record_state_names := [Record_State]string {
	.None      = "none",
	.Recording = "recording",
	.Ended     = "ended",
	.Replaying = "replaying",
	.Replayed  = "replayed",
}

// The words of the replay_status column differed for each divergence kind.
@(rodata)
divergence_kind_names := [input_history.Divergence_Kind]string {
	.None                   = "",
	.Unexpected_Operation   = "operation",
	.Unexpected_Instruction = "instruction",
	.Missing_Record         = "record",
	.Kind_Mismatch          = "kind",
	.Unexpected_Arguments   = "arguments",
	.Unexpected_End         = "end",
}

// One record of the history, private to the service: the scan of a
// divergence copies each record once before the border reads it, because
// the kernel writes the history while the service can read it.
divergence_record_scratch: [input_history.MAX_RECORD_PAYLOAD_BYTES]u8

@(rodata)
history_end_names := [input_history.History_End_Reason]string {
	.None                = "",
	.Normal_Stop         = "process stopped",
	.Recorder_Stopped    = "record ended",
	.Stint_Bound_Reached = "stint bound",
	.Revocation          = "revocation",
	.Buffer_Full         = "history full",
	.Divergence          = "divergence",
}

// kernel_refused gives the result of an export whose kernel operation on
// the debugged process failed: the record of the kernel when it gave one,
// else Refused with the status. The outcome is the one of session_refused.
kernel_refused :: proc "contextless" (error: ^errors.Error_Record, status: system.Status) -> call_outcome.Call_Outcome {
	if error != nil && error.kind != i64(errors.Kind.None) {
		return status == .Bad_State ? .Wrong_State : system.outcome_of_own_status(status)
	}
	return session_refused(error, status)
}

// own_kernel_refused gives the outcome of a kernel refusal on an object
// that the service owns (its history memory), never blaming the caller.
own_kernel_refused :: proc "contextless" (error: ^errors.Error_Record, status: system.Status) -> call_outcome.Call_Outcome {
	outcome := system.outcome_of_own_status(status)
	if error != nil && error.kind != i64(errors.Kind.None) {
		return outcome
	}
	return refuse(error, outcome, .Refused, .Kernel_Status, 0, 0, 0, i64(status))
}

// history_header_read copies the header of the history once, through the
// border of the contract, and gives why the history ended.
history_header_read :: proc "contextless" () -> (header: input_history.History_Header, end: input_history.History_End_Reason, ok: bool) {
	reader, opened := input_history.history_reader_open(record_session.bytes)
	if !opened {
		return {}, .None, false
	}
	end, ok = input_history.history_end_reason_of_word(u64(reader.header.end_reason))
	return reader.header, end, ok
}

// record_state_refresh moves a record that the kernel ended by itself (the
// process stopped, the history is full, the bound, a revocation) to Ended,
// and a replay whose process ended to Replayed. A replay ends when its
// process stops: at the end of the history, at a divergence, or by a stop.
// The header of the history held the end of the record before the replay,
// so only the process says when the replay ended.
record_state_refresh :: proc "contextless" () {
	switch record_session.state {
	case .None, .Ended, .Replayed:
	case .Recording:
		if _, end, ok := history_header_read(); ok && end != .None {
			record_session.state = .Ended
		}
	case .Replaying:
		process: op.Process_Report
		if !inspect_call(.Process, record_session.replay_slot, &process, size_of(process)) || process.process_serial != record_session.replay_serial || process.state == .None || process.state == .Stopped {
			replay_process_forget()
			record_session.state = .Replayed
		}
	}
}

// replay_process_forget closes the handle of the process of a replay. The
// root service ends the debug access when that process stops.
replay_process_forget :: proc "contextless" () {
	if record_session.replay_process != 0 {
		system.close(record_session.replay_process)
	}
	record_session.replay_process, record_session.replay_slot, record_session.replay_serial = 0, 0, 0
}

// record_session_release unmaps and closes the history. The kernel keeps
// its own reference while it records, so the close ends nothing there.
record_session_release :: proc "contextless" () {
	replay_process_forget()
	if record_session.bytes != nil {
		system.memory_unmap(raw_data(record_session.bytes))
	}
	if record_session.history != 0 {
		system.close(record_session.history)
	}
	record_session = {}
}

// record_session_end ends a record that runs, before the session closes
// its process handle, so that the history has its end record from this
// service and not only from the close of the handle. The history stays for
// replay_status and replay_start of the same caller.
record_session_end :: proc "contextless" () {
	if record_session.state == .Recording {
		system.process_record_end(session.process)
		record_session.state = .Ended
	}
}

// record_session_name gives the module that was recorded.
record_session_name :: proc "contextless" () -> string {
	return string(record_session.name[:record_session.name_count])
}

// record_of_caller checks that the caller of the export that runs is the
// caller whose history the service keeps, and that its connection still
// runs: a history is as secret as the process, and the end of the
// connection of its caller forgets it. A failure gives the result of the
// export.
record_of_caller :: proc "contextless" (error: ^errors.Error_Record) -> (failure: call_outcome.Call_Outcome) {
	caller := system.service_caller()
	if caller == nil || caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL == 0 {
		return refuse(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	if record_session.state != .None {
		if kind, _, _ := system.handle_state(record_session.caller_ring); kind != .Memory {
			record_session_release()
		}
	}
	if record_session.state == .None || record_session.caller_ring != caller.ring_memory {
		return refuse(error, .Nothing_Has_That_Name, .Absent, .Input_Histories)
	}
	record_state_refresh()
	return .Succeeded
}

// record_begin makes the history, maps it without Write, and asks the
// kernel to record the process of the session into it. A failure gives the
// result of the export, and leaves no history.
record_begin :: proc "contextless" (error: ^errors.Error_Record) -> (failure: call_outcome.Call_Outcome) {
	record_session_release()
	history, made := system.memory_create(HISTORY_PAGES, flags = {.Contiguous}, error = error)
	if made != .Ok {
		return own_kernel_refused(error, made)
	}
	record_session.history = history
	address, mapped := system.memory_map(history, {}, error = error)
	if mapped != .Ok {
		record_session_release()
		return own_kernel_refused(error, mapped)
	}
	record_session.bytes = ([^]u8)(address)[:HISTORY_PAGES * system.PAGE_SIZE]
	if started := system.process_record_start(session.process, history, error); started != .Ok {
		record_session_release()
		return kernel_refused(error, started)
	}
	input_history.checkpoint_ring_init(&record_session.checkpoints)
	record_session.caller_ring = session.caller_ring
	record_session.name_count = copy(record_session.name[:], session_name())
	record_session.state = .Recording
	return .Succeeded
}

// record_row_fill writes the row of the record from the header of the
// history. False: the header is not a valid header.
record_row_fill :: proc "contextless" (row: ^Record_Row) -> bool {
	header, end, ok := history_header_read()
	if !ok {
		return false
	}
	row^ = {points = i64(header.point_count), bytes = i64(header.written_bytes), capacity = i64(header.capacity_bytes), checkpoints = i64(record_session.checkpoints.count)}
	if end == .Divergence {
		row.divergence = i64(min(header.divergence_point, u64(max(i64))))
		// The first divergence in full, once the replay ended: while a new
		// replay runs, the header still holds the end of the one before. A
		// history whose records before that point fail the border shows the
		// point from its header only.
		if record_session.state == .Replayed && record_session.divergence_read == .Not_Read {
			report, found, report_ok := input_history.divergence_report_of_history(record_session.bytes, divergence_record_scratch[:])
			record_session.divergence_read = report_ok && found ? .Read : .Damaged
			record_session.divergence_report = report
		}
		switch record_session.divergence_read {
		case .Not_Read, .Damaged:
		case .Read:
			report := record_session.divergence_report
			system.format(row.differed[:], divergence_kind_names[report.kind])
			hex_column(row.expected[:], report.expected)
			hex_column(row.actual[:], report.actual)
			if report.recorded_kind != .None {
				hex_column(row.recorded_at[:], report.recorded_instruction_address)
			}
		}
	}
	system.format(row.state[:], record_state_names[record_session.state])
	system.format(row.end[:], history_end_names[end])
	return true
}

// record_rows gives the one row of the record, or the failure of the
// export when the header of the history is damaged.
record_rows :: proc "contextless" (result: ^[]Record_Row, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	row: Record_Row
	if !record_row_fill(&row) {
		return call_outcome.fail(error, .Data_Damaged, .Damaged, .Input_Histories)
	}
	if len(result^) > 0 {
		result[0] = row
	}
	return .Succeeded, 1
}

// held_session_begin makes the service the debugger of a process that the
// root service holds before its first instruction (Debug_Start), as attach
// does for a process that runs. A failure stops the held process: it was
// started for this debugging only. It gives the result of the export.
held_session_begin :: proc "contextless" (name: string, caller: ^system.Connection, completion: [7]u64, error: ^errors.Error_Record) -> (failure: call_outcome.Call_Outcome) {
	// The handle is a number from another process: it must be a process
	// handle with Debug that came through the ring to the root service.
	handle := system.Handle(completion[0])
	if kind, rights, through := system.handle_state(handle, requests_memory); kind != .Process || .Debug not_in rights || !through {
		root_debug_start(name, caller.ring_memory, .Abandon)
		return party_answer_refused(error)
	}
	hash := transmute([32]u8)[4]u64{completion[1], completion[2], completion[3], completion[4]}
	slot, process_serial, matches := slot_find(name, hash, held_only = true)
	if matches != 1 {
		system.close(handle)
		root_debug_start(name, caller.ring_memory, .Abandon)
		if matches == 0 {
			return refuse(error, .Nothing_Has_That_Name, .Absent, .Processes, 1)
		}
		system.log_fact(.Info, Attach_Ambiguous{matches = u64(matches), debugged_process = value_kinds.module_name_field(name)})
		return refuse(error, .Argument_Refused, .Bad_Value, .Processes, 1, i64(matches), 1)
	}
	// The records of an earlier debugging are of no thread of this process.
	for {
		if _, more := record_next_ready(); !more {
			break
		}
	}
	if status := system.debug_attach(handle); status != .Ok {
		system.close(handle)
		root_debug_start(name, caller.ring_memory, .Abandon)
		return session_refused(error, status)
	}
	session = {
		attached       = true,
		process        = handle,
		caller_ring    = caller.ring_memory,
		slot           = slot,
		process_serial = process_serial,
	}
	session.name_count = copy(session.name[:], name)
	reports_read()
	system.log_fact(.Info, Attach_Done{threads = 0, modules = u64(min(report_modules.count, op.PROCESS_MODULE_CAPACITY)), described = 0, debugged_process = value_kinds.module_name_field(name), caller = value_kinds.module_name_field(system.name_of(caller.caller[:]))})
	return .Succeeded
}

// replay_begin starts the module of the history again, held before its
// first instruction with no start grant, gives it the history with
// Replay_Start, and lets it run. The kernel writes the context of the
// record into it, answers each kernel entry from the history, and stops it
// at the first difference. A failure stops the held process and gives the
// result of the export.
replay_begin :: proc "contextless" (caller: ^system.Connection, error: ^errors.Error_Record) -> (failure: call_outcome.Call_Outcome) {
	name := record_session_name()
	header, _, ok := history_header_read()
	if !ok {
		return refuse(error, .Data_Damaged, .Damaged, .Input_Histories)
	}
	completion, answered := root_debug_start(name, caller.ring_memory, .Start_Replay)
	if !answered {
		return refuse(error, .Callee_Unavailable, .No_Answer, .Milliseconds, 0, 0, ROOT_ANSWER_MILLISECONDS)
	}
	if system.Status(completion.kind) != .Ok {
		if error != nil {
			error^ = errors.completion_record(completion.values)
		}
		return outcome_of_status_word(completion.kind)
	}
	handle := system.Handle(completion.values[0])
	if kind, rights, through := system.handle_state(handle, requests_memory); kind != .Process || .Debug not_in rights || !through {
		root_debug_start(name, caller.ring_memory, .Abandon)
		return party_answer_refused(error)
	}
	// The boot image can hold another module of this name than the one
	// that was recorded: its replay would prove another run.
	hash := transmute([32]u8)[4]u64{completion.values[1], completion.values[2], completion.values[3], completion.values[4]}
	if hash != header.module_hash {
		system.close(handle)
		root_debug_start(name, caller.ring_memory, .Abandon)
		return refuse(error, .Argument_Refused, .Bad_Value, .Input_Histories, 1)
	}
	slot, process_serial, matches := slot_find(name, hash, held_only = true)
	if matches != 1 {
		system.close(handle)
		root_debug_start(name, caller.ring_memory, .Abandon)
		if matches == 0 {
			return refuse(error, .Nothing_Has_That_Name, .Absent, .Processes, 1)
		}
		return refuse(error, .Argument_Refused, .Bad_Value, .Processes, 1, i64(matches), 1)
	}
	if status := system.process_replay_start(handle, record_session.history, error); status != .Ok {
		system.close(handle)
		root_debug_start(name, caller.ring_memory, .Abandon)
		return kernel_refused(error, status)
	}
	released, released_answered := root_debug_start(name, caller.ring_memory, .Release)
	if !released_answered {
		system.close(handle)
		return refuse(error, .Callee_Unavailable, .No_Answer, .Milliseconds, 0, 0, ROOT_ANSWER_MILLISECONDS)
	}
	if system.Status(released.kind) != .Ok {
		system.close(handle)
		if error != nil {
			error^ = errors.completion_record(released.values)
		}
		return outcome_of_status_word(released.kind)
	}
	record_session.replay_process = handle
	record_session.replay_slot = slot
	record_session.replay_serial = process_serial
	// The report of a replay before this one no longer holds.
	record_session.divergence_read = .Not_Read
	record_session.divergence_report = {}
	record_session.state = .Replaying
	return .Succeeded
}

// checkpoint_rows gives one row for each checkpoint that the service keeps,
// the oldest first.
checkpoint_rows :: proc "contextless" (result: ^[]Checkpoint_Row) -> i64 {
	count := record_session.checkpoints.count
	for index in u32(0) ..< count {
		checkpoint, ok := input_history.checkpoint_ring_get(&record_session.checkpoints, index)
		if !ok || int(index) >= len(result^) {
			continue
		}
		row := &result[index]
		row^ = {checkpoint = i64(checkpoint.id), point = i64(checkpoint.position.point_number), offset = i64(checkpoint.history_byte_offset)}
		hex_column(row.instruction[:], checkpoint.instruction_address)
		hex_column(row.stack[:], checkpoint.stack_pointer)
	}
	return i64(count)
}
