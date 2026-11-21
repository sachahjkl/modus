// The asker of the test of fan-out and the pace
// (src/md/features/module_outputs.md, "Fan-out and flow control"). It
// starts `requests_reader`, then starts `server` with a wiring list of three
// rows from the record output `requests`:
//
// - to the record input `held` of the reader, of the pace
//   Always_Holds_Writer, in a ring of PACE_RING_CAPACITY compartments;
// - to the record input `gapped` of the reader, of the pace
//   Never_Holds_Writer, in a ring of the same capacity;
// - to this process as its asker, of the pace Writer_Chooses, in a ring of
//   the default capacity, which holds each record of the test: this is the
//   fast reader.
//
// The tool then sends PACE_REQUESTS requests to the server. This process
// reads each record of its ring, and checks that the slow reader did not
// change what the fast reader receives: the joined record of 0, then each
// record in order, with no gap. The counts that the server publishes in the
// head page of its ring say the rest: it was held exactly twice, once for
// each phase of the slow reader, and refused no record. Then it waits until
// the principal stops the server, `stop("server")` in the console, and the
// slow reader reads the end of its two rings and stops.
//
// **Start**: `start("requests_pace")` in the console, once `server` does
// not run. **What a reader sees**: no window; one line "requests_pace:
// ...: as it must", or a line "requests_pace: WRONG: ...". It stops itself
// with the outcome Done, or Failed after a WRONG line.
package requests_pace

import "modus:contract/output"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:contract/value_kinds"
import "modus:system"

// The access record of `server`. This process reads it as the asker, with
// no record input: the root service compares no description for it, and
// the size of the record is the one that it checks.
Access_Record :: struct {
	status:      u64,
	answer_size: value_kinds.Size_In_Bytes,
	answer_time: value_kinds.Time_In_Microseconds,
	method:      [8]u8,
	target:      [56]u8,
	peer:        [32]u8,
}

// The index of the record output `requests` of server, and of the record
// inputs of requests_reader: the rows of each table are sorted by name.
SERVER_REQUESTS :: 1
READER_GAPPED :: 1
READER_HELD :: 2

// The constants of requests_reader, which its checks share.
PACE_REQUESTS :: 80
PACE_RING_CAPACITY :: output.WIRING_CAPACITY_LEAST

// The holds of the server: one for each phase of the slow reader, which
// reads nothing until its ring is full and the server waits on it.
HOLDS_OF_THE_TEST :: 2

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
	system.log(.Error, "requests_pace: WRONG: ", text, " ", value)
	system.stop(.Failed)
}

// wrong_refused stops as wrong does, and writes the seven words of the
// error record of the completion too.
@(private = "file")
wrong_refused :: proc "contextless" (text: string, status: system.Status, answer: [7]u64) -> ! {
	system.log(.Error, "requests_pace: WRONG: ", text, " ", u64(status), "; the error record: ", answer[0], " ", answer[1], " ", answer[2], " ", answer[3], " ", answer[4], " ", answer[5], " ", answer[6])
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

// start_listed starts a module, with the list in the list page or with
// none, and asks for its process handle.
@(private = "file")
start_listed :: proc "contextless" (name: string, listed: bool) -> (system.Status, [7]u64) {
	packed := system.name_pack(name)
	list := listed ? root_ring.Start_Wiring_List.In_The_List_Page : root_ring.Start_Wiring_List.None
	return root_call(.Start, {packed[0], packed[1], packed[2], packed[3], u64(list), u64(root_ring.Start_Answer.Process_Handle), 0})
}

// list_page_take asks for the list page, maps it, and takes the wiring
// ring of an asker that the root service gives with it.
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

// stopped_wait waits until each process stopped, within the hang bound.
@(private = "file")
stopped_wait :: proc "contextless" (processes: []system.Handle) {
	deadline := hang_deadline()
	for {
		wait := system.wait_begin()
		all := true
		for process in processes {
			if state, _, _ := system.process_state(process); state != .Stopped {
				all = false
			}
		}
		if all {
			return
		}
		if system.time() >= deadline {
			wrong("a process did not stop within the hang bound, in milliseconds:", system.TEST_HANG_BOUND_MILLISECONDS)
		}
		system.wait_end(&wait, deadline)
	}
}

// requests_row gives the row from the record output requests of the child
// to one reader.
@(private = "file")
requests_row :: proc "contextless" (reader_end: output.Wiring_End, reader_handle, reader_index: u32, pace: output.Wiring_Pace, capacity: u32) -> output.Wiring {
	return {writer_end = u32(output.Wiring_End.Child), writer_stream = u32(output.Writer_Stream.Record_Output), writer_index = SERVER_REQUESTS, reader_end = u32(reader_end), reader_handle = reader_handle, reader_index = reader_index, pace = u32(pace), capacity = capacity}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	requests_memory = ctx.handles[system.GRANT_ROOT]
	opened, ring_status := system.ring_open(requests_memory)
	if ring_status != .Ok {
		wrong("no root ring; the status", u64(ring_status))
	}
	requests = opened
	list_page_take()

	status, answer := start_listed("requests_reader", false)
	if status != .Ok || answer[0] == 0 {
		wrong_refused("the start of requests_reader gave the status", status, answer)
	}
	reader := system.Handle(answer[0])
	lent, lend_status := system.give(requests_memory, reader, {.Read})
	if lend_status != .Ok {
		wrong("the gift of the handle of the reader to the root service gave the status", u64(lend_status))
	}
	rows := [3]output.Wiring {
		requests_row(.Started, 1, READER_HELD, .Always_Holds_Writer, PACE_RING_CAPACITY),
		requests_row(.Started, 1, READER_GAPPED, .Never_Holds_Writer, PACE_RING_CAPACITY),
		requests_row(.Asker, 0, 0, .Writer_Chooses, 0),
	}
	for &value in list_page {
		value = 0
	}
	handles := [1]u32{u32(lent)}
	if !output.wiring_list_write(list_page, rows[:], handles[:]) {
		wrong("the list does not fit the list page; rows:", u64(len(rows)))
	}
	status, answer = start_listed("server", true)
	if status != .Ok || answer[0] == 0 || answer[1] == 0 {
		wrong_refused("the start of server with its list gave the status", status, answer)
	}
	server := system.Handle(answer[0])
	number := u32(answer[1])
	system.log(.Info, "requests_pace: server runs with three readers of requests: held of the pace Always_Holds_Writer and gapped of the pace Never_Holds_Writer, in rings of ", u64(PACE_RING_CAPACITY), ", and this process, the fast reader")

	// The fast reader: each record of the test, in order, with no gap.
	record: Access_Record
	item, read_status := system.asker_read(number, &record, hang_deadline())
	if read_status != .Ok || item.kind != .Joined || item.serial != 0 {
		wrong("the first compartment of the fast reader is not the joined record of 0; the status word", u64(read_status))
	}
	for serial in u32(0) ..< PACE_REQUESTS {
		item, read_status = system.asker_read(number, &record, hang_deadline())
		if read_status != .Ok || item.kind != .Record || item.serial != serial {
			system.log(.Error, "requests_pace: WRONG: the fast reader wanted the record ", u64(serial), ", and read the status word ", u64(read_status), ", the kind word ", u64(item.kind), " and the serial ", u64(item.serial))
			system.stop(.Failed)
		}
	}
	// The counts that the server published at its last write, before that
	// record: each record before it was taken, and the slow reader held the
	// server once in each of its two phases.
	counts, counted := system.asker_writer_counts(number)
	if !counted {
		wrong("the ring of the fast reader gives no counts", 0)
	}
	if counts.written != PACE_REQUESTS - 1 || counts.discarded != 0 || counts.refused != 0 || counts.held != HOLDS_OF_THE_TEST {
		system.log(.Error, "requests_pace: WRONG: the counts of the server: written ", counts.written, ", discarded ", counts.discarded, ", refused ", counts.refused, ", held ", counts.held, "; wanted ", u64(PACE_REQUESTS - 1), ", 0, 0 and ", u64(HOLDS_OF_THE_TEST))
		system.stop(.Failed)
	}

	// The end: the principal stops the server once the tool has the answer
	// of its last request: the record of a request comes before its answer
	// leaves, so a stop by this process could cut that answer. The slow
	// reader then reads the end word of each of its rings after the records
	// that they hold, and stops.
	system.log(.Info, "requests_pace: the fast reader read the ", u64(PACE_REQUESTS), " records; it waits for the stop of server")
	processes := [2]system.Handle{server, reader}
	stopped_wait(processes[:])
	for process in processes {
		system.close(process)
	}
	system.log(.Info, "requests_pace: the fast reader: the joined record of 0 and the ", u64(PACE_REQUESTS), " records in order, no gap; the server was held ", counts.held, " times by the slow reader of the pace Always_Holds_Writer and refused no record: as it must")
	system.stop(.Done)
}
