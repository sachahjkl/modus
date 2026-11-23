// The asker of the measures 1, 2, 4 and 9 of the record outputs
// (src/md/features/module_outputs.md, "The measures that decide it"). For
// each count of readers of READER_COUNTS, it starts that many
// `output_measure_reader`, then starts `output_measure_writer` with a
// wiring list of one row for each reader, and waits until each one stopped
// with the outcome Done: each reader read each record in order. The writer
// prints the time of a write with that count of readers; the run of one
// reader also prints the time of a log fact, of a line and the wake. A last
// run has one reader and wires the record output `log` of the writer to
// this process, which reads each of its log records: the writer prints the
// same log calls with the wiring (measure 9).
//
// The largest count is 8 (READERS_MOST), a choice of the measure: an asker
// holds the wirings that its budget pays.
//
// **Start**: `start("output_measure")` in the console, in a measure run.
// **What a reader sees**: no window; the lines of the writer and of the
// reader, then "output_measure: ...: as it must", or a line
// "output_measure: WRONG: ...". It stops itself with the outcome Done, or
// Failed after a WRONG line.
package output_measure

import "modus:contract/output"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:system"

// The counts of readers of the measure of the fan-out.
READER_COUNTS :: [4]int{1, 2, 4, 8}
READERS_MOST :: 8

// The record output samples of the writer, and the record input samples
// of the reader: one row each.
WRITER_SAMPLES :: 1
READER_SAMPLES :: 1

requests: ring.Ring
requests_memory: system.Handle
next_tag: u32 = 1
list_page: []u8

@(private = "file")
hang_deadline :: proc "contextless" () -> u64 {
	return system.time() + system.TEST_HANG_BOUND_MILLISECONDS
}

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log_fact(.Error, Wrong{value = value}, text)
	system.stop(.Failed)
}

@(private = "file")
wrong_refused :: proc "contextless" (text: string, status: system.Status, answer: [7]u64) -> ! {
	system.log_fact(.Error, Wrong_Refused{status = u64(status), error_kind = answer[0], error_unit = answer[1], error_operation = answer[2], error_argument = answer[3], error_value = answer[4], error_limit = answer[5], error_found = answer[6]}, text)
	system.stop(.Failed)
}

// root_call sends one command on the root ring and waits for its
// completion, within the hang bound.
@(private = "file")
root_call :: proc "contextless" (command: root_ring.Root_Command, values: [7]u64) -> (status: system.Status, answer: [7]u64) {
	tag := next_tag
	next_tag += 1
	if !system.send(&requests.commands, ring.Record{kind = u32(command), tag = tag, values = values}) {
		wrong("the root ring is full", 0)
	}
	deadline := hang_deadline()
	for {
		wait := system.wait_begin()
		if record, received := system.receive(&requests.completions); received {
			if record.tag != tag {
				continue
			}
			read, refusal := system.status_of_word(record.kind)
			if refusal.kind != 0 {
				wrong("the root service answered a status word that names no status", u64(record.kind))
			}
			return read, record.values
		}
		if system.time() >= deadline {
			wrong("the root service did not answer within the hang bound; the command", u64(command))
		}
		system.wait_records(&wait, &requests.completions)
		system.wait_end(&wait, deadline)
	}
}

@(private = "file")
start_listed :: proc "contextless" (name: string, listed: bool) -> (system.Status, [7]u64) {
	packed := system.name_pack(name)
	list := listed ? root_ring.Start_Wiring_List.In_The_List_Page : root_ring.Start_Wiring_List.None
	return root_call(.Start, {packed[0], packed[1], packed[2], packed[3], u64(list), u64(root_ring.Start_Answer.Process_Handle), 0})
}

@(private = "file")
list_page_take :: proc "contextless" () {
	status, answer := root_call(.Wire, {0 = u64(root_ring.Wire_Step.List_Page)})
	if status != .Ok || answer[0] == 0 {
		wrong_refused("the list page was refused with the status", status, answer)
	}
	page := system.Handle(answer[0])
	address, map_status := system.memory_map(page)
	pages, _ := system.memory_size(page)
	if map_status != .Ok || pages * system.PAGE_SIZE < output.WIRING_LIST_BYTES_MOST {
		wrong("the list page does not map; the status", u64(map_status))
	}
	list_page = ([^]u8)(address)[:output.WIRING_LIST_BYTES_MOST]
	if answer[1] != 0 {
		if taken := system.wiring_ring_take(system.Handle(answer[1])); taken != .Ok {
			wrong("the wiring ring of the asker does not open; the status", u64(taken))
		}
	}
}

// done_wait waits until each process stopped, and stops this process
// when one of them did not stop itself with the outcome Done.
@(private = "file")
done_wait :: proc "contextless" (processes: []system.Handle) {
	deadline := hang_deadline()
	for {
		wait := system.wait_begin()
		all := true
		for process in processes {
			state, cause, outcome := system.process_state(process)
			if state != .Stopped {
				all = false
				continue
			}
			if cause != .Itself || outcome != .Done {
				wrong("a writer or a reader of the measures did not stop itself with Done; its stop cause word", u64(cause))
			}
		}
		if all {
			return
		}
		if system.time() >= deadline {
			wrong("a writer or a reader of the measures did not stop within the hang bound, in milliseconds:", system.TEST_HANG_BOUND_MILLISECONDS)
		}
		system.wait_end(&wait, deadline)
	}
}

// measure_run runs the writer with a count of readers.
@(private = "file")
measure_run :: proc "contextless" (count: int) {
	processes: [READERS_MOST + 1]system.Handle
	rows: [READERS_MOST]output.Wiring
	handles: [READERS_MOST]u32
	for index in 0 ..< count {
		status, answer := start_listed("output_measure_reader", false)
		if status != .Ok || answer[0] == 0 {
			wrong_refused("the start of a reader gave the status", status, answer)
		}
		processes[index] = system.Handle(answer[0])
		lent, lend_status := system.give(requests_memory, processes[index], {.Read})
		if lend_status != .Ok {
			wrong("the gift of the handle of a reader to the root service gave the status", u64(lend_status))
		}
		handles[index] = u32(lent)
		rows[index] = {writer_end = u32(output.Wiring_End.Child), writer_stream = u32(output.Writer_Stream.Record_Output), writer_index = WRITER_SAMPLES, reader_end = u32(output.Wiring_End.Started), reader_handle = u32(index + 1), reader_index = READER_SAMPLES}
	}
	for &value in list_page {
		value = 0
	}
	if !output.wiring_list_write(list_page, rows[:count], handles[:count]) {
		wrong("the list does not fit the list page; rows:", u64(count))
	}
	status, answer := start_listed("output_measure_writer", true)
	if status != .Ok || answer[0] == 0 {
		wrong_refused("the start of the writer with its list gave the status", status, answer)
	}
	processes[count] = system.Handle(answer[0])
	done_wait(processes[:count + 1])
	for process in processes[:count + 1] {
		system.close(process)
	}
	wirings_ended_wait()
}

// The ring of the log of the writer in the run of measure 9: room for the
// log records of the run, so the writer is held only if this process falls
// behind; the times print the cost either way.
LOG_RING_CAPACITY :: 1024
#assert(LOG_RING_CAPACITY <= output.WIRING_CAPACITY_MOST)

// measure_log_run runs the writer with one reader and its record output log
// wired to this process (measure 9). This process reads each log record of
// the writer until the end word, while the writer runs: the pace of log
// holds the writer, so a reader that waits for the stop first would hold
// it forever.
@(private = "file")
measure_log_run :: proc "contextless" () {
	status, answer := start_listed("output_measure_reader", false)
	if status != .Ok || answer[0] == 0 {
		wrong_refused("the start of a reader gave the status", status, answer)
	}
	processes: [2]system.Handle
	processes[0] = system.Handle(answer[0])
	lent, lend_status := system.give(requests_memory, processes[0], {.Read})
	if lend_status != .Ok {
		wrong("the gift of the handle of a reader to the root service gave the status", u64(lend_status))
	}
	rows := [2]output.Wiring {
		{writer_end = u32(output.Wiring_End.Child), writer_stream = u32(output.Writer_Stream.Record_Output), writer_index = WRITER_SAMPLES, reader_end = u32(output.Wiring_End.Started), reader_handle = 1, reader_index = READER_SAMPLES},
		{writer_end = u32(output.Wiring_End.Child), writer_stream = u32(output.Writer_Stream.Log), reader_end = u32(output.Wiring_End.Asker), pace = u32(output.Wiring_Pace.Always_Holds_Writer), capacity = LOG_RING_CAPACITY},
	}
	handles := [1]u32{u32(lent)}
	for &value in list_page {
		value = 0
	}
	if !output.wiring_list_write(list_page, rows[:], handles[:]) {
		wrong("the list does not fit the list page; rows:", u64(len(rows)))
	}
	status, answer = start_listed("output_measure_writer", true)
	if status != .Ok || answer[0] == 0 || answer[1] == 0 {
		wrong_refused("the start of the writer with its log wired gave the status", status, answer)
	}
	processes[1] = system.Handle(answer[0])
	number := u32(answer[1])
	record: output.Log_Output_Record
	item, read_status := system.asker_read(number, &record, hang_deadline())
	if read_status != .Ok || item.kind != .Joined || item.serial != 0 {
		wrong("the first compartment of the log of the writer is not the joined record of 0; the status word", u64(read_status))
	}
	records := u32(0)
	for {
		item, read_status = system.asker_read(number, &record, hang_deadline())
		if read_status == .Ended {
			break
		}
		if read_status != .Ok || item.kind != .Record || item.serial != records {
			system.log_fact(.Error, Wrong_Log_Record{record_serial = u64(records), status_word = u64(read_status), kind_word = u64(item.kind), serial = u64(item.serial)})
			system.stop(.Failed)
		}
		records += 1
	}
	if item.end_word != .Writer_Stopped || item.stop_outcome != .Done {
		system.log_fact(.Error, Wrong_Log_End{end_word = u64(item.end_word), stop_outcome = u64(item.stop_outcome), records = u64(records)})
		system.stop(.Failed)
	}
	system.log_fact(.Info, Log_Read{records = u64(records)})
	done_wait(processes[:])
	for process in processes {
		system.close(process)
	}
	wirings_ended_wait()
}

// wirings_ended_wait waits until the root service ended each wiring of the
// run: it reaps a stopped process in its own loop, after the kernel says
// that it stopped, and the next run asks for up to the limit of this
// asker. The grant wirings of this process ends with its last wiring.
@(private = "file")
wirings_ended_wait :: proc "contextless" () {
	packed := system.name_pack("output_measure")
	deadline := hang_deadline()
	for {
		status, answer := root_call(.Grants, {packed[0], packed[1], packed[2], packed[3], 0, 0, 0})
		if status != .Ok {
			wrong_refused("the Grants of this process gave the status", status, answer)
		}
		if .Wirings not_in transmute(system.Root_Grants)answer[0] {
			return
		}
		if system.time() >= deadline {
			wrong("the wirings of a run did not end within the hang bound; the grants", answer[0])
		}
	}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	requests_memory = ctx.handles[system.GRANT_ROOT]
	opened, ring_status := system.ring_open(requests_memory, receive_handles = true)
	if ring_status != .Ok {
		wrong("no root ring; the status", u64(ring_status))
	}
	requests = opened
	list_page_take()
	counts := READER_COUNTS
	for count in counts {
		measure_run(count)
	}
	measure_log_run()
	system.log_fact(.Info, Measured{})
	system.stop(.Done)
}
