// The follower of the machine test of `log.follow`
// (src/md/features/log_facts.md, "The frequent tasks"). It connects to the
// log service, wires `log.follow` to itself as its asker, in a ring of
// FOLLOW_CAPACITY compartments, and reads the joined record. Then it falls
// behind on purpose: it reads nothing, and writes log records of its own
// until the kernel took FLOOD_TARGET of them, more than the whole log
// holds past the ring. The log service keeps its place at the first row
// that the full ring refused, and the kernel writes over the records after
// it: when this process reads again, the service must write one gap record
// of their count where they were.
//
// The checks, on what this process reads after the joined record:
//
// - the rows before the gap have consecutive serials and consecutive
//   numbers of the whole log;
// - the gap record comes before the rows can no longer meet, at most
//   FOLLOW_CAPACITY + 1 compartments after the joined record, with a count
//   of 1 or more, at the serial after the last row;
// - the row after the gap has the serial after the gap, and a number of
//   the whole log that is the number of the last row before the gap, plus
//   the count of the gap, plus 1: the gap says exactly the records lost.
//
// No check reads a time. The flood is paced by the clock of the log budget:
// each batch starts at the next whole second, and its lines are fewer than
// half the records of a second, so the kernel takes each one wherever the
// second of the kernel falls; a refused line only makes one more batch.
// Its lines before the result wait for the next second as well: no step
// waits for a line right after this process wrote more lines than its log
// records of one second.
//
// **Start**: `start("log_follower")` in the console, with the window log
// running. **What a reader sees**: no window; one line
// "log_follower: ...: as it must", or a line "log_follower: WRONG: ...".
// It stops itself with the outcome Done, or Failed after a WRONG line.
package log_follower

import op "modus:contract/operation"
import "modus:contract/call_outcome"
import "modus:contract/output"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:system"

// One row of log.follow, as the log service declares it: this process
// reads it as the asker, whose end the root service checks by its size.
Follow_Row :: struct {
	number:     i64,
	time:       i64,
	slot:       i64,
	process:    [32]u8,
	level:      op.Log_Level,
	form:       op.Log_Record_Form,
	continues:  u8,
	runs:       u8,
	text_count: u32,
	text:       [168]u8,
}
#assert(size_of(Follow_Row) == 232)

// The index of the record output follow of the log service: its one row.
FOLLOW_INDEX :: 1
// The least ring: the service fills it fast, and keeps its place.
FOLLOW_CAPACITY :: output.WIRING_CAPACITY_LEAST
// The records that the kernel must take from this process while it does
// not read: the whole log, and the ring, and one more. The rows that the
// ring holds and the place that the service keeps are behind each of them.
FLOOD_TARGET :: op.LOG_RECORD_CAPACITY + FOLLOW_CAPACITY + 1
// The lines of one batch: less than half of the log records of one second
// of a process, so two batches never share one second of the kernel.
FLOOD_BATCH :: 400
// The tag of the Connect, apart from the tags of root_call.
CONNECT_TAG :: 1

requests: ring.Ring
requests_memory: system.Handle
next_tag: u32 = CONNECT_TAG + 1
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
wrong_refused :: proc "contextless" (text: string, status: call_outcome.Call_Outcome, answer: [7]u64) -> ! {
	system.log_fact(.Error, Wrong_Refused{status = u64(status), error_kind = answer[0], error_unit = answer[1], error_operation = answer[2], error_argument = answer[3], error_value = answer[4], error_limit = answer[5], error_found = answer[6]}, text)
	system.stop(.Failed)
}

// root_call sends one command on the root ring and waits for its
// completion, within the hang bound.
@(private = "file")
root_call :: proc "contextless" (command: root_ring.Root_Command, values: [7]u64) -> (outcome: call_outcome.Call_Outcome, answer: [7]u64) {
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
			read, _ := call_outcome.completion_outcome(record.kind, record.values)
			if read == .Answer_Unreadable {
				wrong("the root service answered a completion that this process cannot read; the outcome word", u64(record.kind))
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

// list_page_take asks for the list page, maps it, and takes the wiring
// ring of an asker that the root service gives with it.
@(private = "file")
list_page_take :: proc "contextless" () {
	status, answer := root_call(.Wire, {0 = u64(root_ring.Wire_Step.List_Page)})
	if status != .Succeeded || answer[0] == 0 {
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

// next_second_wait waits until the next whole second of the clock: a new
// second of the log budget of this process. It decides nothing by the
// time: it only paces the lines.
@(private = "file")
next_second_wait :: proc "contextless" () {
	next := (system.time() / 1000 + 1) * 1000
	for system.time() < next {
		wait := system.wait_begin()
		system.wait_end(&wait, next)
	}
}

// flood writes lines until the kernel took FLOOD_TARGET of them: the
// lines written, less each record that the kernel refused to this process
// since refused_before, is a count that the kernel took at least.
@(private = "file")
flood :: proc "contextless" (refused_before: u64) -> (written: u64) {
	// The flood takes some seconds of the log budget; a kernel that takes
	// none of its lines ends it at the hang bound, never in a loop.
	deadline := hang_deadline()
	for {
		_, refused := system.budget_used(0)
		if written >= refused - refused_before && written - (refused - refused_before) >= FLOOD_TARGET {
			return written
		}
		if system.time() >= deadline {
			system.log_fact(.Error, Wrong_Flood_Not_Taken{target = FLOOD_TARGET, written = written, bound_milliseconds = system.TEST_HANG_BOUND_MILLISECONDS})
			system.stop(.Failed)
		}
		next_second_wait()
		for _ in 0 ..< FLOOD_BATCH {
			system.log_fact(.Info, Flood_Record{})
			written += 1
		}
	}
}

// read_one reads the next compartment, within the hang bound.
@(private = "file")
read_one :: proc "contextless" (number: u32, row: ^Follow_Row) -> system.Input_Item {
	item, status := system.asker_read(number, row, hang_deadline())
	if status != .Ok {
		system.log_fact(.Error, Wrong_Read{status_word = u64(status), kind_word = u64(item.kind), end_word = u64(item.end_word)})
		system.stop(.Failed)
	}
	return item
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
	connection, connected := system.service_connection(&requests, CONNECT_TAG, "log")
	if connected != .Succeeded {
		wrong("the root service gave no connection to the log service; the outcome word", u64(connected))
	}

	// log.follow to this process: the end Connected names the service of
	// the connection, which only a caller that acts for the principal may
	// name.
	rows := [1]output.Wiring{{writer_end = u32(output.Wiring_End.Connected), writer_handle = u32(connection.process), writer_stream = u32(output.Writer_Stream.Record_Output), writer_index = FOLLOW_INDEX, reader_end = u32(output.Wiring_End.Asker), pace = u32(output.Wiring_Pace.Writer_Chooses), capacity = FOLLOW_CAPACITY}}
	for &value in list_page {
		value = 0
	}
	if !output.wiring_list_write(list_page, rows[:], nil) {
		wrong("the list does not fit the list page; rows:", 1)
	}
	status, answer := root_call(.Wire, {0 = u64(root_ring.Wire_Step.Apply)})
	if status != .Succeeded || answer[0] == 0 {
		wrong_refused("the Wire of log.follow gave the status", status, answer)
	}
	number := u32(answer[0])
	row: Follow_Row
	joined := read_one(number, &row)
	if joined.kind != .Joined {
		wrong("the first compartment of log.follow is not a joined record; the kind word", u64(joined.kind))
	}

	// Behind: the service fills the ring and keeps its place; the kernel
	// writes over each record after that place.
	_, refused_before := system.budget_used(0)
	written := flood(refused_before)
	next_second_wait()

	// The rows that the ring holds, then the gap, then the rows after it.
	last: Follow_Row
	last_serial := joined.serial
	rows_before := 0
	for compartments := 0; ; compartments += 1 {
		if compartments > FOLLOW_CAPACITY + 1 {
			wrong("no gap record in log.follow after the compartments of a whole ring:", u64(compartments))
		}
		item := read_one(number, &row)
		if item.kind == .Gap {
			if rows_before == 0 || item.serial != last_serial + 1 || item.gap_count == 0 {
				system.log_fact(.Error, Wrong_Gap{serial = u64(item.serial), gap_count = u64(item.gap_count), rows_before = u64(rows_before), last_serial = u64(last_serial)})
				system.stop(.Failed)
			}
			after := read_one(number, &row)
			if after.kind != .Record || after.serial != item.serial + item.gap_count || row.number != last.number + i64(item.gap_count) + 1 {
				system.log_fact(.Error, Wrong_After_Gap{gap_count = u64(item.gap_count), gap_serial = u64(item.serial), kind_word = u64(after.kind), serial = u64(after.serial), row_number = row.number, last_row_number = last.number})
				system.stop(.Failed)
			}
			system.asker_close(number)
			system.call_connection_end(&connection)
			system.log_fact(.Info, Gap_Read{rows_before = u64(rows_before), gap_count = u64(item.gap_count), written = written})
			system.stop(.Done)
		}
		if item.kind != .Record || item.serial != last_serial + (rows_before == 0 ? 0 : 1) || (rows_before > 0 && row.number != last.number + 1) {
			system.log_fact(.Error, Wrong_Before_Gap{kind_word = u64(item.kind), serial = u64(item.serial), row_number = row.number, last_serial = u64(last_serial), last_row_number = last.number})
			system.stop(.Failed)
		}
		last, last_serial = row, item.serial
		rows_before += 1
	}
}

// The least budget of 2048 pages, in which it ran before its floor was
// counted. It leaves when the peak of its budget at its first state of
// work is read (src/md/features/module_budget_request.md, "State").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 2048}
