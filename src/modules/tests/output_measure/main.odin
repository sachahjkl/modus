// The asker of the measures 1, 2 and 4 of the record outputs
// (src/md/features/module_outputs.md, "The measures that decide it"). For
// each count of readers of READER_COUNTS, it starts that many
// `output_measure_reader`, then starts `output_measure_writer` with a
// wiring list of one row for each reader, and waits until each one stopped
// with the outcome Done: each reader read each record in order. The writer
// prints the time of a write with that count of readers; the run of one
// reader also prints the time of a log fact and the wake.
//
// The largest count is 8, the wirings of one asker at most
// (output.WIRINGS_OF_AN_ASKER_MOST): the measure of 16 readers needs a
// second asker.
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
import "modus:support/system"

// The counts of readers of the measure of the fan-out.
READER_COUNTS :: [4]int{1, 2, 4, 8}
#assert(output.WIRINGS_OF_AN_ASKER_MOST >= 8)

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
	system.log(.Error, "output_measure: WRONG: ", text, " ", value)
	system.stop(.Failed)
}

@(private = "file")
wrong_refused :: proc "contextless" (text: string, status: system.Status, answer: [7]u64) -> ! {
	system.log(.Error, "output_measure: WRONG: ", text, " ", u64(status), "; the error record: ", answer[0], " ", answer[1], " ", answer[2], " ", answer[3], " ", answer[4], " ", answer[5], " ", answer[6])
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
	processes: [output.WIRINGS_OF_AN_ASKER_MOST + 1]system.Handle
	rows: [output.WIRINGS_OF_AN_ASKER_MOST]output.Wiring
	handles: [output.WIRINGS_OF_AN_ASKER_MOST]u32
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
	opened, ring_status := system.ring_open(requests_memory)
	if ring_status != .Ok {
		wrong("no root ring; the status", u64(ring_status))
	}
	requests = opened
	list_page_take()
	counts := READER_COUNTS
	for count in counts {
		measure_run(count)
	}
	system.log(.Info, "output_measure: the writer with 1, 2, 4 and 8 readers, each record read in order by each reader: as it must")
	system.stop(.Done)
}
