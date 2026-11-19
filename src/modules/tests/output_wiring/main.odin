// The asker of the machine test of the record outputs
// (src/md/features/module_outputs.md, "How a test waits on a record
// output"). It starts `output_writer` and `output_reader`, wires them with
// Wire and with the wiring list of Start, and tries each refusal of the
// root service, with the check that its budget did not change: the rings
// of a wiring are paid from the budget of its asker.
//
// The cases, in order:
//
// 1. The refusals of Wire before the list page and of its words.
// 2. The probes: a reader in the wiring list of the start of the writer
//    joins at 0, and a reader that a Wire adds after five probes joins at
//    5. Before that Wire: the refusals of a wiring, among them a second
//    wiring of the record input of the first reader, refused by the count
//    One. The handle of the list page of this process was revoked before:
//    the revocation does not reach the copy of the root service.
// 3. The refusals of Start and of its list: its words, the record output
//    log, the rows of the asker past six, and a list whose rings the
//    budget refuses after some of them were made.
// 4. The end words: Writer_Stopped, Reader_Stopped.
// 5. The limit of the wirings of an asker, one past it, and the
//    revocation of the grant wirings: Revoked.
// 6. A wiring to this process as its asker, read with asker_read; then
//    this process stops: Asker_Stopped.
//
// **Start**: `start("output_wiring")` in the console. **What a reader
// sees**: no window; one line "output_wiring: ...: as it must" for each
// case, or a line "output_wiring: WRONG: ...". It stops with the code 0.
package output_wiring

import "modus:contract/errors"
import "modus:contract/output"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:support/system"

// The probe of the writer, to read the wiring of which this process is
// the asker.
Probe :: struct {
	serial: u64,
	mark:   u64,
}

// The indexes of the record outputs of output_writer and of the record
// inputs and outputs of output_reader: the rows of each table are sorted
// by name.
WRITER_ASKED :: 1
WRITER_LARGE :: 2
WRITER_OTHERS :: 3
WRITER_PROBES :: 4
WRITER_UNENDED :: 5
WRITER_WATCHED :: 6
READER_PROBES :: 1
READER_UNENDED :: 2
READER_WATCHED :: 3
READER_ECHO :: 1

// A number that names no handle that this process gave the root service.
NUMBER_NOT_LENT :: 0x7FFF_0000

// The capacity whose rings the budget of this process cannot pay six
// times.
LARGEST_CAPACITY :: output.WIRING_CAPACITY_MOST

requests: ring.Ring
requests_memory: system.Handle
next_tag: u32 = 1
list_page: []u8
refusals: int

@(private = "file")
hang_deadline :: proc "contextless" () -> u64 {
	return system.time() + system.TEST_HANG_BOUND_MILLISECONDS
}

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log(.Error, "output_wiring: WRONG: ", text, " ", value)
	system.stop(1)
}

// root_call sends one command on the root ring and waits for its
// completion.
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

// lend gives the root service a handle through the root ring, and gives
// its number there.
@(private = "file")
lend :: proc "contextless" (handle: system.Handle) -> u32 {
	given, status := system.give(requests_memory, handle, {.Read})
	if status != .Ok {
		wrong("the gift of a handle to the root service gave the status", u64(status))
	}
	return u32(given)
}

// list_write writes a wiring list in the list page, with its terms after
// the lent handles.
@(private = "file")
list_write :: proc "contextless" (rows: []output.Wiring, handles: []u32, terms: []u8 = nil) {
	for &value in list_page {
		value = 0
	}
	if !output.wiring_list_write(list_page, rows, handles) {
		wrong("the list does not fit the list page; rows:", u64(len(rows)))
	}
	copy(list_page[output.wiring_terms_start(len(rows), len(handles)):], terms)
}

// wire applies a list of one row.
@(private = "file")
wire :: proc "contextless" (row: output.Wiring, handles: []u32, terms: []u8 = nil) -> (system.Status, [7]u64) {
	rows := [1]output.Wiring{row}
	list_write(rows[:], handles, terms)
	return root_call(.Wire, {0 = u64(root_ring.Wire_Step.Apply)})
}

// start_listed starts a module with the list in the list page, or with
// none, and asks for its process handle.
@(private = "file")
start_listed :: proc "contextless" (name: string, listed: bool) -> (system.Status, [7]u64) {
	packed := system.name_pack(name)
	list := listed ? root_ring.Start_Wiring_List.In_The_List_Page : root_ring.Start_Wiring_List.None
	return root_call(.Start, {packed[0], packed[1], packed[2], packed[3], u64(list), u64(root_ring.Start_Answer.Process_Handle), 0})
}

// start_child starts a module with no list, and gives its process handle.
@(private = "file")
start_child :: proc "contextless" (name: string) -> system.Handle {
	status, answer := start_listed(name, false)
	if status != .Ok || answer[0] == 0 {
		wrong("the start of a child gave the status", u64(status))
	}
	return system.Handle(answer[0])
}

// row gives a row from a writer to a reader.
@(private = "file")
row :: proc "contextless" (writer_end: output.Wiring_End, writer_place, writer_index: u32, reader_end: output.Wiring_End, reader_place, reader_index: u32) -> output.Wiring {
	return {writer_end = u32(writer_end), writer_handle = writer_place, writer_stream = u32(output.Writer_Stream.Record_Output), writer_index = writer_index, reader_end = u32(reader_end), reader_handle = reader_place, reader_index = reader_index}
}

@(private = "file")
budget_pages :: proc "contextless" () -> u64 {
	amounts, _ := system.budget_read()
	return amounts.pages
}

// refused checks one refusal: its status, the kind and the unit of its
// error record, and that the budget of this process holds the pages that
// it held before the command.
@(private = "file")
refused :: proc "contextless" (what: string, before: u64, status: system.Status, answer: [7]u64, wanted: system.Status, kind: errors.Kind, unit: errors.Unit) {
	record := errors.completion_record(answer)
	if status != wanted || record.kind != i64(kind) || record.unit != i64(unit) {
		system.log(.Error, "output_wiring: WRONG: ", what, ": the status ", status, ", the kind ", record.kind, ", the unit ", record.unit)
		system.stop(1)
	}
	if after := budget_pages(); after != before {
		system.log(.Error, "output_wiring: WRONG: ", what, ": the budget held ", before, " pages before and ", after, " after")
		system.stop(1)
	}
	refusals += 1
}

// stopped_wait waits until each process stopped.
@(private = "file")
stopped_wait :: proc "contextless" (processes: []system.Handle) {
	deadline := hang_deadline()
	for {
		wait := system.wait_begin()
		all := true
		for process in processes {
			if state, _ := system.process_state(process); state != .Stopped {
				all = false
			}
		}
		if all {
			return
		}
		if system.time() >= deadline {
			wrong("a child did not stop within the hang bound", 0)
		}
		system.wait_end(&wait, deadline)
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
	words_case()
	probes_case()
	start_case()
	end_words_case()
	limit_case()
	asker_case()
}

// words_case: Wire before the list page, a step that names nothing, and a
// word that is not 0. Then the list page.
@(private = "file")
words_case :: proc "contextless" () {
	before := budget_pages()
	status, answer := root_call(.Wire, {0 = u64(root_ring.Wire_Step.Apply)})
	refused("Apply before the list page", before, status, answer, .Bad_State, .Absent, .Wirings)
	status, answer = root_call(.Wire, {0 = u64(max(root_ring.Wire_Step)) + 1})
	refused("a step that names nothing", before, status, answer, .Bad_Operation, .Bad_Value, .None)
	status, answer = root_call(.Wire, {0 = u64(root_ring.Wire_Step.Apply), 6 = 1})
	refused("a reserved word", before, status, answer, .Bad_Operation, .Bad_Value, .None)
	status, answer = root_call(.Wire, {0 = u64(root_ring.Wire_Step.List_Page)})
	if status != .Ok || answer[0] == 0 {
		wrong("the list page was refused with the status", u64(status))
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
	// The revocation of the handle of this process ends what came from it,
	// and never the handle or a mapping of the root service: the next
	// commands copy the page.
	system.handle_revoke(page)
	system.log(.Info, "output_wiring: Wire before its list page, with a step that names nothing and with a reserved word: refused, each with its status and its error record, the budget unchanged; then the list page: as it must")
}

// probes_case: the reader of the start joins at 0, the reader of a Wire at
// 5; the refusals of a wiring between them, and the count One after.
@(private = "file")
probes_case :: proc "contextless" () {
	first_reader := start_child("output_reader")
	second_reader := start_child("output_reader")
	rows := [1]output.Wiring{row(.Child, 0, WRITER_PROBES, .Started, 1, READER_PROBES)}
	handles := [1]u32{lend(first_reader)}
	list_write(rows[:], handles[:])
	status, answer := start_listed("output_writer", true)
	if status != .Ok || answer[0] == 0 {
		wrong("the start of the writer with its list gave the status", u64(status))
	}
	writer := system.Handle(answer[0])

	before := budget_pages()
	// A number that this process did not give through the ring.
	not_lent := [2]u32{lend(writer), NUMBER_NOT_LENT}
	status, answer = wire(row(.Started, 1, WRITER_PROBES, .Started, 2, READER_PROBES), not_lent[:])
	refused("a number that did not come through the ring", before, status, answer, .Bad_Handle, .Handle_Absent, .Lent_Handles)
	// One number in two places.
	repeated := lend(writer)
	twice := [2]u32{repeated, repeated}
	status, answer = wire(row(.Started, 1, WRITER_PROBES, .Started, 2, READER_PROBES), twice[:])
	refused("one number in two places", before, status, answer, .Bad_Operation, .Bad_Value, .Lent_Handles)
	// A process that this process did not start, and a service for which
	// it does not act for the principal.
	packed := system.name_pack("log")
	connect_status, connected := root_call(.Connect, {packed[0], packed[1], packed[2], packed[3], 0, 0, 0})
	if connect_status != .Ok {
		wrong("the connection to the log service gave the status", u64(connect_status))
	}
	service := system.Handle(connected[0])
	not_started := [2]u32{lend(service), lend(second_reader)}
	status, answer = wire(row(.Started, 1, 1, .Started, 2, READER_PROBES), not_started[:])
	refused("a process that this process did not start", before, status, answer, .No_Right, .No_Grant, .Wirings)
	not_acting := [2]u32{lend(service), lend(second_reader)}
	status, answer = wire(row(.Connected, 1, 1, .Started, 2, READER_PROBES), not_acting[:])
	refused("a service for which this process does not act for the principal", before, status, answer, .No_Right, .No_Grant, .Wirings)
	// One process at both ends, named by two handles.
	same := [2]u32{lend(second_reader), lend(second_reader)}
	status, answer = wire(row(.Started, 1, READER_ECHO, .Started, 2, READER_PROBES), same[:])
	refused("one process at both ends", before, status, answer, .Bad_State, .Bad_Value, .Wirings)
	// An index past the record outputs of the writer.
	past := [2]u32{lend(writer), lend(second_reader)}
	status, answer = wire(row(.Started, 1, WRITER_WATCHED + 1, .Started, 2, READER_PROBES), past[:])
	refused("an index past the record outputs", before, status, answer, .Bad_Operation, .Bad_Value, .Wiring_Rows)
	// A record of another type.
	other_type := [2]u32{lend(writer), lend(second_reader)}
	status, answer = wire(row(.Started, 1, WRITER_OTHERS, .Started, 2, READER_PROBES), other_type[:])
	refused("a record of another type", before, status, answer, .Bad_Operation, .Bad_Value, .Record_Types)
	// Wiring terms for a record input that takes none.
	with_terms := [2]u32{lend(writer), lend(second_reader)}
	terms_row := row(.Started, 1, WRITER_PROBES, .Started, 2, READER_PROBES)
	terms_row.terms_offset = u32(output.wiring_terms_start(1, len(with_terms)))
	terms_row.terms_count = 8
	terms := [8]u8{1, 2, 3, 4, 5, 6, 7, 8}
	status, answer = wire(terms_row, with_terms[:], terms[:])
	refused("terms for a record input that takes none", before, status, answer, .Bad_Operation, .Bad_Value, .Wiring_Terms)

	// The count One: the record input of the first reader has its wiring,
	// which runs until the writer has its second reader, so no stop races
	// with this refusal.
	again := [2]u32{lend(writer), lend(first_reader)}
	status, answer = wire(row(.Started, 1, WRITER_PROBES, .Started, 2, READER_PROBES), again[:])
	refused("a record input of the count One that has its wiring", before, status, answer, .Bad_State, .Exists, .Wirings)

	// The second reader joins after the five probes of the writer, which
	// waits for it.
	second := [2]u32{lend(writer), lend(second_reader)}
	status, answer = wire(row(.Started, 1, WRITER_PROBES, .Started, 2, READER_PROBES), second[:])
	if status != .Ok || answer[0] == 0 {
		wrong("the Wire of the second reader gave the status", u64(status))
	}
	system.log(.Info, "output_wiring: the refusals of a wiring, each with its status and its error record and the budget unchanged, and the Wire of the second reader: as it must")
	processes := [3]system.Handle{writer, first_reader, second_reader}
	stopped_wait(processes[:])
	for process in processes {
		system.close(process)
	}
}

// start_case: the refusals of Start and of its list.
@(private = "file")
start_case :: proc "contextless" () {
	before := budget_pages()
	packed := system.name_pack("output_writer")
	status, answer := root_call(.Start, {packed[0], packed[1], packed[2], packed[3], u64(max(root_ring.Start_Wiring_List)) + 1, 0, 0})
	refused("a list word that names nothing", before, status, answer, .Bad_Operation, .Bad_Value, .None)
	status, answer = root_call(.Start, {packed[0], packed[1], packed[2], packed[3], 0, u64(max(root_ring.Start_Answer)) + 1, 0})
	refused("an answer word that names nothing", before, status, answer, .Bad_Operation, .Bad_Value, .None)
	status, answer = root_call(.Start, {packed[0], packed[1], packed[2], packed[3], 0, 0, 1})
	refused("a reserved word", before, status, answer, .Bad_Operation, .Bad_Value, .None)

	// The record output log of the child, before its step: refused before
	// its reader matters, so the reader is this asker.
	log_row := row(.Child, 0, 0, .Asker, 0, 0)
	log_row.writer_stream = u32(output.Writer_Stream.Log)
	log_rows := [1]output.Wiring{log_row}
	list_write(log_rows[:], nil)
	status, answer = start_listed("output_writer", true)
	refused("the record output log", before, status, answer, .Bad_Operation, .Unsupported, .Wiring_Rows)
	// One row of the asker past six.
	asker_rows: [output.WIRING_ASKER_ROWS_OF_A_START + 1]output.Wiring
	for &each in asker_rows {
		each = row(.Child, 0, WRITER_PROBES, .Asker, 0, 0)
	}
	list_write(asker_rows[:], nil)
	status, answer = start_listed("output_writer", true)
	refused("a seventh row of the asker", before, status, answer, .Bad_Operation, .Bad_Value, .Wiring_Rows)
	// Six rings of the largest record and the largest capacity: the budget
	// refuses one of them, and each one made before it goes back.
	large_rows: [output.WIRING_ASKER_ROWS_OF_A_START]output.Wiring
	for &each in large_rows {
		each = row(.Child, 0, WRITER_LARGE, .Asker, 0, 0)
		each.capacity = LARGEST_CAPACITY
	}
	list_write(large_rows[:], nil)
	status, answer = start_listed("output_writer", true)
	refused("rings past the budget, after some of them were made", before, status, answer, .No_Budget, .Budget, .Pages)
	system.log(.Info, "output_wiring: the refusals of Start and of its list, each with its status and its error record and the budget unchanged: as it must")
}

// end_words_case: Writer_Stopped and Reader_Stopped.
@(private = "file")
end_words_case :: proc "contextless" () {
	cases := [2][2]u32{{WRITER_UNENDED, READER_UNENDED}, {WRITER_WATCHED, READER_WATCHED}}
	for pair in cases {
		reader := start_child("output_reader")
		rows := [1]output.Wiring{row(.Child, 0, pair[0], .Started, 1, pair[1])}
		handles := [1]u32{lend(reader)}
		list_write(rows[:], handles[:])
		status, answer := start_listed("output_writer", true)
		if status != .Ok || answer[0] == 0 {
			wrong("the start of a writer of an end word gave the status", u64(status))
		}
		writer := system.Handle(answer[0])
		processes := [2]system.Handle{writer, reader}
		stopped_wait(processes[:])
		system.close(writer)
		system.close(reader)
	}
	system.log(.Info, "output_wiring: the writer that stopped and the reader that stopped: as it must")
}

// limit_case: the wirings of this process up to its limit, one past it,
// and the revocation of the grant wirings.
@(private = "file")
limit_case :: proc "contextless" () {
	writer := start_child("output_writer")
	for _ in 0 ..< WIRINGS_OF_AN_ASKER_MOST {
		handles := [1]u32{lend(writer)}
		status, answer := wire(row(.Started, 1, WRITER_LARGE, .Asker, 0, 0), handles[:])
		if status != .Ok || answer[0] == 0 {
			wrong("a wiring up to the limit gave the status", u64(status))
		}
	}
	before := budget_pages()
	handles := [1]u32{lend(writer)}
	status, answer := wire(row(.Started, 1, WRITER_LARGE, .Asker, 0, 0), handles[:])
	refused("one wiring past the limit of an asker", before, status, answer, .No_Slot, .Full, .Wirings)
	packed := system.name_pack("output_wiring")
	revoke_status, revoked := root_call(.Revoke, {packed[0], packed[1], packed[2], packed[3], u64(system.Root_Grant.Wirings), 0, 0})
	if revoke_status != .Ok || revoked[0] != WIRINGS_OF_AN_ASKER_MOST {
		wrong("the revocation of the grant wirings ended this count of wirings:", revoked[0])
	}
	processes := [1]system.Handle{writer}
	stopped_wait(processes[:])
	system.close(writer)
	system.log(.Info, "output_wiring: ", u64(WIRINGS_OF_AN_ASKER_MOST), " wirings, one past them refused with its status and its error record and the budget unchanged, then the revocation of the grant wirings: as it must")
}

// The wirings of an asker at most: the limit of the root service.
WIRINGS_OF_AN_ASKER_MOST :: 8

// asker_case: a wiring to this process as its asker, read with
// asker_read; this process then stops, and the writer reads
// Asker_Stopped.
@(private = "file")
asker_case :: proc "contextless" () {
	rows := [1]output.Wiring{row(.Child, 0, WRITER_ASKED, .Asker, 0, 0)}
	list_write(rows[:], nil)
	status, answer := start_listed("output_writer", true)
	if status != .Ok || answer[1] == 0 {
		wrong("the start of the writer with a row of the asker gave the status", u64(status))
	}
	number := u32(answer[1])
	probe: Probe
	joined, joined_status := system.asker_read(number, &probe, hang_deadline())
	item, item_status := system.asker_read(number, &probe, hang_deadline())
	if joined_status != .Ok || joined.kind != .Joined || joined.serial != 0 || item_status != .Ok || item.kind != .Record || probe.serial != 0 {
		wrong("the wiring of the asker did not give the joined record of 0 and the probe 0; the status", u64(item_status))
	}
	system.log(.Info, "output_wiring: the wiring of this asker gave the joined record of 0 and the probe 0, after ", u64(refusals), " refusals; this asker stops: as it must")
	system.log(.Info, "output_wiring: ok")
	system.stop(0)
}
