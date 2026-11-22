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

import "modus:contract/errors"
import "modus:contract/input_history"
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
}

// The record of the process of the session. session_end forgets it with
// the session.
Record_Session :: struct {
	state:       Record_State,
	history:     system.Handle, // The contiguous memory object of the history: Read and Write, for the kernel.
	bytes:       []u8, // Its mapping in this process, without Write.
	checkpoints: input_history.Checkpoint_Ring,
}

record_session: Record_Session

@(rodata)
record_state_names := [Record_State]string {
	.None      = "none",
	.Recording = "recording",
	.Ended     = "ended",
}

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

// kernel_refused gives the result of an export whose kernel operation
// failed: the record of the kernel when it gave one, else Refused with the
// status.
kernel_refused :: proc "contextless" (error: ^errors.Error_Record, status: system.Status) -> i64 {
	if error != nil && error.kind != i64(errors.Kind.None) {
		return ERROR_REFUSED
	}
	return refused(error, status)
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
// process stopped, the history is full, the bound, a revocation) to Ended.
record_state_refresh :: proc "contextless" () {
	if record_session.state != .Recording {
		return
	}
	if _, end, ok := history_header_read(); ok && end != .None {
		record_session.state = .Ended
	}
}

// record_session_release unmaps and closes the history. The kernel keeps
// its own reference while it records, so the close ends nothing there.
record_session_release :: proc "contextless" () {
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
// service and not only from the close of the handle.
record_session_end :: proc "contextless" () {
	if record_session.state == .Recording {
		system.process_record_end(session.process)
	}
	record_session_release()
}

// record_begin makes the history, maps it without Write, and asks the
// kernel to record the process of the session into it. A failure gives the
// result of the export, and leaves no history.
record_begin :: proc "contextless" (error: ^errors.Error_Record) -> (failure: i64) {
	record_session_release()
	history, made := system.memory_create(HISTORY_PAGES, flags = {.Contiguous}, error = error)
	if made != .Ok {
		return kernel_refused(error, made)
	}
	record_session.history = history
	address, mapped := system.memory_map(history, {}, error = error)
	if mapped != .Ok {
		record_session_release()
		return kernel_refused(error, mapped)
	}
	record_session.bytes = ([^]u8)(address)[:HISTORY_PAGES * system.PAGE_SIZE]
	if started := system.process_record_start(session.process, history, error); started != .Ok {
		record_session_release()
		return kernel_refused(error, started)
	}
	input_history.checkpoint_ring_init(&record_session.checkpoints)
	record_session.state = .Recording
	return 0
}

// record_row_fill writes the row of the record from the header of the
// history. False: the header is not a valid header.
record_row_fill :: proc "contextless" (row: ^Record_Row) -> bool {
	header, end, ok := history_header_read()
	if !ok {
		return false
	}
	row^ = {points = i64(header.point_count), bytes = i64(header.written_bytes), capacity = i64(header.capacity_bytes), checkpoints = i64(record_session.checkpoints.count)}
	system.format(row.state[:], record_state_names[record_session.state])
	system.format(row.end[:], history_end_names[end])
	return true
}

// record_rows gives the one row of the record, or the failure of the
// export when the header of the history is damaged.
record_rows :: proc "contextless" (result: ^[]Record_Row, error: ^errors.Error_Record) -> i64 {
	row: Record_Row
	if !record_row_fill(&row) {
		return errors.fail(error, ERROR_RECORD, .Damaged, .Input_Histories)
	}
	if len(result^) > 0 {
		result[0] = row
	}
	return 1
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
