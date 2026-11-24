// The asker of the machine test of the record outputs
// (src/md/features/module_outputs.md, "How a test waits on a record
// output"). It starts `output_writer`, `output_reader` and `output_side`,
// wires them with Wire and with the wiring list of Start, and tries each
// refusal of the root service. Each refusal is checked whole: its status,
// each field of its error record, and the budget of this process, which
// did not change: the rings of a wiring are paid from the budget of its
// asker.
//
// The cases, in order:
//
// 1. The refusals of Wire before the list page and of its words; the list
//    page refused by the budget; the list page; then the revocation, the
//    unmap and the close of the handle of this process, and a new handle
//    of the same page.
// 2. The probes: a reader in the wiring list of the start of the writer
//    joins at 0, and a reader that a Wire adds after five probes joins at
//    5. Before that Wire: the refusals of a wiring, among them a second
//    wiring of the record input of the first reader, refused by the count
//    One, and lent memory handles in more rounds than the handle table of
//    the root service holds.
// 3. The refusals of Start and of its list: its words; the record output
//    log of a service, with Wire and with Start, with an index, twice, with
//    the pace Never_Holds_Writer and with a condition; the rows of the
//    asker past six; and a list whose rings the budget refuses after some
//    of them were made.
// 4. The end words: Writer_Stopped, Reader_Stopped.
// 5. The record output log of `log_flood`, wired to this asker at its
//    start: each record, in order, while the kernel refuses each of its
//    calls; then Writer_Stopped.
// 6. The limit of the wirings of an asker, one past it with Wire and with
//    the list of a Start, and the revocation of the grant wirings:
//    Revoked.
// 7. A side that writes its own words: a refused end, words that the root
//    service drops, and a wiring ring that it never reads, until the root
//    service refuses an end for it with Busy.
// 8. A wiring to this process as its asker, read with asker_read; then
//    this process stops: Asker_Stopped.
//
// **Start**: `start("output_wiring")` in the console. **What a reader
// sees**: no window; one line "output_wiring: ...: as it must" for each
// case, or a line "output_wiring: WRONG: ...". It stops itself with the
// outcome Done, or Failed after a WRONG line.
package output_wiring

import "modus:contract/call_outcome"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:system"

// The probe of the writer, to read the wiring of which this process is
// the asker.
Probe :: struct {
	serial: u64,
	mark:   u64,
}

// The largest record of the writer: the record of the wirings up to the
// limit of this asker.
Large :: struct {
	serial: u64,
	note:   [248]u8,
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
WRITER_OUTPUTS :: 6
READER_PROBES :: 1
READER_UNENDED :: 2
READER_WATCHED :: 3
READER_ECHO :: 1
SIDE_ECHO :: 1

// The fields of the probe: serial and mark.
PROBE_FIELDS :: 2

// A number that names no handle that this process gave the root service.
NUMBER_NOT_LENT :: 0x7FFF_0000

// The capacity whose rings the budget of this process cannot pay six
// times.
LARGEST_CAPACITY :: output.WIRING_CAPACITY_MOST

// The rounds of two lent memory handles: more handles than the table of
// the root service holds, so a handle that it kept would fill it.
LENT_MEMORY_ROUNDS :: 70

// The commands that the wiring ring of output_side holds: the capacity of
// the ring of a start with one end.
SIDE_RING_CAPACITY :: output.WIRING_RING_CAPACITY

// The constants and the fact of log_flood, which this process checks in
// its log: the same values as in log_flood.
FLOOD_LINES :: 600
FLOOD_LONG_LINE_BYTES :: 400
FLOOD_MARK :: 0x5a5a_a5a5
Flood_Fact :: struct {
	number: u64,
	mark:   u64,
}
// More lines than the default ring holds: log_flood is held at least once.
#assert(FLOOD_LINES > output.WIRING_CAPACITY_DEFAULT)
// Three records for the long line, the last one shorter.
#assert(FLOOD_LONG_LINE_BYTES > 2 * op.LOG_TEXT_CAPACITY && FLOOD_LONG_LINE_BYTES < 3 * op.LOG_TEXT_CAPACITY)

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
	system.log_fact(.Error, Wrong{value = value}, text)
	system.stop(.Failed)
}

// wrong_refused stops as wrong does, and writes the seven words of the
// error record of the completion too: several limits of the root service
// give one status, and the record names the one that refused.
wrong_refused :: proc "contextless" (text: string, status: call_outcome.Call_Outcome, answer: [7]u64) -> ! {
	system.log_fact(.Error, Wrong_Refused{status = u64(status), error_kind = answer[0], error_unit = answer[1], error_operation = answer[2], error_argument = answer[3], error_value = answer[4], error_limit = answer[5], error_found = answer[6]}, text)
	system.stop(.Failed)
}

// root_call sends one command on the root ring and waits for its
// completion.
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

// lend gives the root service a handle through the root ring, and gives
// its number there.
@(private = "file")
lend :: proc "contextless" (handle: system.Handle) -> u32 {
	given, status := system.give(requests_memory, handle, {.Read})
	if status != .Succeeded {
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
wire :: proc "contextless" (row: output.Wiring, handles: []u32, terms: []u8 = nil) -> (call_outcome.Call_Outcome, [7]u64) {
	rows := [1]output.Wiring{row}
	list_write(rows[:], handles, terms)
	return root_call(.Wire, {0 = u64(root_ring.Wire_Step.Apply)})
}

// start_listed starts a module with the list in the list page, or with
// none, and asks for its process handle.
@(private = "file")
start_listed :: proc "contextless" (name: string, listed: bool) -> (call_outcome.Call_Outcome, [7]u64) {
	packed := system.name_pack(name)
	list := listed ? root_ring.Start_Wiring_List.In_The_List_Page : root_ring.Start_Wiring_List.None
	return root_call(.Start, {packed[0], packed[1], packed[2], packed[3], u64(list), u64(root_ring.Start_Answer.Process_Handle), 0})
}

// start_child starts a module with no list, and gives its process handle.
@(private = "file")
start_child :: proc "contextless" (name: string) -> system.Handle {
	status, answer := start_listed(name, false)
	if status != .Succeeded || answer[0] == 0 {
		wrong_refused("the start of a child gave the status", status, answer)
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

// The fields of an error record that the kernel fills from the state of
// the moment, which a test cannot know before the call: the number of a
// budget handle of the root service, and what a budget held when a ring
// among several did not fit.
@(private = "file")
Unknown_Field :: enum u8 {
	Value,
	Limit,
	Found,
}
@(private = "file")
Unknown_Fields :: bit_set[Unknown_Field;u8]

// fail gives the error record of a refusal of a command, as the root
// service writes it.
@(private = "file")
fail :: proc "contextless" (command: root_ring.Root_Command, kind: errors.Kind, unit: errors.Unit, argument: i64 = 0, value: i64 = 0, limit: i64 = 0, found: i64 = 0) -> [7]u64 {
	return errors.ring_fail(u32(command), kind, unit, argument, value, limit, found)
}

// refused checks one refusal whole: its status, each field of its error
// record but those that unknown names, and that the budget of this
// process holds the pages that it held before the command.
@(private = "file")
refused :: proc "contextless" (what: string, before: u64, status: call_outcome.Call_Outcome, answer: [7]u64, wanted: call_outcome.Call_Outcome, expected: [7]u64, unknown: Unknown_Fields = {}) {
	record := errors.completion_record(answer)
	want := errors.completion_record(expected)
	if .Value in unknown {
		want.value = record.value
	}
	if .Limit in unknown {
		want.limit = record.limit
	}
	if .Found in unknown {
		want.found = record.found
	}
	if status != wanted || record != want {
		system.log_fact(.Error, Wrong_Refusal{outcome = call_outcome.Call_Outcome_Word(status), kind = record.kind, unit = record.unit, operation = record.operation, argument = record.argument, value = record.value, limit = record.limit, found = record.found}, what)
		system.log_fact(.Error, Wrong_Refusal_Wanted{outcome = call_outcome.Call_Outcome_Word(wanted), kind = want.kind, unit = want.unit, operation = want.operation, argument = want.argument, value = want.value, limit = want.limit, found = want.found}, what)
		system.stop(.Failed)
	}
	if after := budget_pages(); after != before {
		system.log_fact(.Error, Wrong_Budget{pages_before = before, pages_after = after}, what)
		system.stop(.Failed)
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
			if state, _, _ := system.process_state(process); state != .Stopped {
				all = false
			}
		}
		if all {
			return
		}
		if system.time() >= deadline {
			wrong("a child did not stop within the hang bound, in milliseconds:", system.TEST_HANG_BOUND_MILLISECONDS)
		}
		system.wait_end(&wait, deadline)
	}
}

// budget_settled_wait waits until the budget of this process holds the
// pages that it held at the start of a case. A case ends when its children
// are Stopped, but the root service ends their wirings only when it reaps
// them, in its own loop and later: then it closes the end page of each
// wiring and, with the last one, the wiring page of this asker, which this
// budget paid. A refusal of the next case would else see those pages come
// back during its call. Each round waits for one answer of the root
// service, whose loop reaps between its answers: no round waits a time,
// and the hang bound ends a wait that never settles.
@(private = "file")
budget_settled_wait :: proc "contextless" (wanted: u64, case_name: string) {
	deadline := hang_deadline()
	asker_name := system.name_pack("output_wiring")
	for {
		held := budget_pages()
		if held == wanted {
			return
		}
		if system.time() >= deadline {
			system.log_fact(.Error, Wrong_Budget_Not_Settled{pages_held = held, pages_wanted = wanted}, case_name)
			system.stop(.Failed)
		}
		root_call(.Grants, {asker_name[0], asker_name[1], asker_name[2], asker_name[3], 0, 0, 0})
	}
}

// grant_wirings_revoke revokes the grant wirings of this process, which
// ends each of its wirings, and checks the status, then their count. With
// no wiring held, this process holds no grant wirings: the revocation is
// refused as the revocation of any grant not held, and checked whole.
//
// Before that refusal, the end of the last wiring must be over in the
// root service: it writes the end word, then ends the grant and frees the
// wiring page of this asker, in one call of its single pass. A process
// that read the end word can read its budget while that call still runs
// on another processor, and see the page come back during the Revoke. A
// Grants that shows no grant was served after that call, so the budget
// that this process reads after it no longer moves: the pages that the
// sides hold come back only when the sides close them.
@(private = "file")
grant_wirings_revoke :: proc "contextless" (wanted: int) {
	packed := system.name_pack("output_wiring")
	if wanted == 0 {
		grant_wirings_gone_wait("the grant wirings stayed after the last wiring of this process ended; the grants")
	}
	before := budget_pages()
	status, revoked := root_call(.Revoke, {packed[0], packed[1], packed[2], packed[3], u64(system.Root_Grant.Wirings), 0, 0})
	if wanted == 0 {
		refused("the revocation of the grant wirings with no wiring held", before, status, revoked, .Nothing_Has_That_Name, fail(.Revoke, .Absent, .Grants, 2))
		// The refusal changed no grant: wirings is neither granted nor
		// marked revoked, so this process can still ask for wirings.
		granted, revoked_grants := grants_read()
		if .Wirings in granted || .Wirings in revoked_grants {
			wrong("a refused revocation of the grant wirings left it granted or revoked; the grants", transmute(u64)granted)
		}
		return
	}
	if status != .Succeeded {
		wrong_refused("the revocation of the grant wirings gave the status", status, revoked)
	}
	if revoked[0] != u64(wanted) {
		wrong("the revocation of the grant wirings ended this count of wirings:", revoked[0])
	}
	for index in 1 ..< len(revoked) {
		if revoked[index] != 0 {
			wrong("the revocation of the grant wirings gave a value past its count:", revoked[index])
		}
	}
}

// grants_read gives the grants of this process that the root service
// records: those that it holds, and those that a revocation ended.
@(private = "file")
grants_read :: proc "contextless" () -> (granted, revoked: system.Root_Grants) {
	packed := system.name_pack("output_wiring")
	status, answer := root_call(.Grants, {packed[0], packed[1], packed[2], packed[3], 0, 0, 0})
	if status != .Succeeded {
		wrong_refused("the Grants of this process gave the status", status, answer)
	}
	return transmute(system.Root_Grants)answer[0], transmute(system.Root_Grants)answer[1]
}

// grant_wirings_gone_wait waits until the root service records no grant
// wirings for this process, within the hang bound: the root service reads
// the answers of a process after its commands in one pass, but serves each
// command that comes during that pass first, so the end of a wiring by a
// word Closed can come after the answer of a command.
@(private = "file")
grant_wirings_gone_wait :: proc "contextless" (what: string) {
	deadline := hang_deadline()
	for {
		granted, _ := grants_read()
		if .Wirings not_in granted {
			return
		}
		if system.time() >= deadline {
			wrong(what, transmute(u64)granted)
		}
	}
}

// asker_ends_close reads the end of each wiring of this asker that a
// revocation ended, with a record of the type of the wiring: each one
// gives Ended with the end word Revoked, and its end leaves the table of
// the library.
@(private = "file")
asker_ends_close :: proc "contextless" (numbers: []u32, $Record_Type: typeid) {
	for number in numbers {
		record: Record_Type
		item, status := system.asker_read(number, &record, hang_deadline())
		if status != .Ended || item.end_word != .Revoked {
			wrong("a revoked wiring of this asker did not end with Revoked; the status", u64(status))
		}
	}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	requests_memory = ctx.handles[system.GRANT_ROOT]
	opened, ring_status := system.ring_open(requests_memory, receive_handles = true)
	if ring_status != .Succeeded {
		wrong("no root ring; the status", u64(ring_status))
	}
	requests = opened
	words_case()
	lent_return_case()
	probes_case()
	start_case()
	end_words_case()
	log_case()
	limit_case()
	side_case()
	asker_case()
}

// list_page_take asks for the list page, maps it, and takes the wiring
// ring of an asker that the root service gives with the first one.
@(private = "file")
list_page_take :: proc "contextless" () -> (page: system.Handle, address: rawptr) {
	status, answer := root_call(.Wire, {0 = u64(root_ring.Wire_Step.List_Page)})
	if status != .Succeeded || answer[0] == 0 {
		wrong("the list page was refused with the status", u64(status))
	}
	page = system.Handle(answer[0])
	map_status: call_outcome.Call_Outcome
	address, map_status = system.memory_map(page)
	pages, _ := system.memory_size(page)
	if map_status != .Succeeded || pages * system.PAGE_SIZE < output.WIRING_LIST_BYTES_MOST {
		wrong("the list page does not map; the status", u64(map_status))
	}
	list_page = ([^]u8)(address)[:output.WIRING_LIST_BYTES_MOST]
	if answer[1] != 0 {
		if taken := system.wiring_ring_take(system.Handle(answer[1])); taken != .Succeeded {
			wrong("the wiring ring of the asker does not open; the status", u64(taken))
		}
	}
	return page, address
}

// words_case: Wire before the list page, a step that names nothing, a
// word that is not 0, and the list page refused by the budget. Then the
// list page; its handle of this process revoked, unmapped and closed; and
// a new handle of the same page, which the next cases use.
@(private = "file")
words_case :: proc "contextless" () {
	before := budget_pages()
	status, answer := root_call(.Wire, {0 = u64(root_ring.Wire_Step.Apply)})
	refused("Apply before the list page", before, status, answer, .Nothing_Has_That_Name, fail(.Wire, .Absent, .Wirings))
	step_word := u64(max(root_ring.Wire_Step)) + 1
	status, answer = root_call(.Wire, {0 = step_word})
	refused("a step that names nothing", before, status, answer, .Argument_Refused, root_ring.word_refusal(.Wire, 1, step_word, u64(max(root_ring.Wire_Step))))
	status, answer = root_call(.Wire, {0 = u64(root_ring.Wire_Step.Apply), 6 = 1})
	refused("a reserved word", before, status, answer, .Argument_Refused, root_ring.word_refusal(.Wire, 7, 1, 0))

	// The budget of this process keeps fewer pages than the list page
	// costs: the root service makes it from that budget, so it refuses.
	cost := op.memory_cost(output.WIRING_LIST_PAGES_MOST)
	if before < cost {
		wrong("the budget of this process does not pay one list page; its pages:", before)
	}
	// The filler keeps fewer pages than the cost: the cost of the filler
	// grows by one page or two for each page of it.
	filler_pages := before - cost + 1
	for filler_pages > 1 && op.memory_cost(filler_pages) > before {
		filler_pages -= 1
	}
	filler, filler_status := system.memory_create(filler_pages)
	if filler_status != .Succeeded {
		wrong("the memory that fills the budget was refused with the status", u64(filler_status))
	}
	short := budget_pages()
	if short >= cost {
		wrong("the budget still pays the list page; its pages:", short)
	}
	status, answer = root_call(.Wire, {0 = u64(root_ring.Wire_Step.List_Page)})
	refused("the list page past the budget", short, status, answer, .Budget_Or_Capacity_Exhausted, fail(.Wire, .Budget, .Pages, 1, 0, i64(cost), i64(short)), {.Value})
	system.close(filler)

	first, first_address := list_page_take()
	// The revocation of the handle of this process ends what came from it,
	// and never the handle or a mapping of the root service. This process
	// then ends its own mapping and handle, and takes a new handle of the
	// same page, as an asker that lost its handle does.
	system.handle_revoke(first)
	system.memory_unmap(first_address)
	system.close(first)
	list_page_take()
	system.log_fact(.Info, List_Page_Checked{})
}

// lent_return_case: handles that an asker lent and names in a list of no
// row, sent with Wire, as the console gives back the handles of a command
// that it does not send. The border refuses the count of rows, and the
// root service closes each lent number: in more rounds than its handle
// table holds, so a handle that it kept would fill it, and the starts and
// the wirings of the cases after this one would fail.
@(private = "file")
lent_return_case :: proc "contextless" () {
	memory, memory_status := system.memory_create(1)
	if memory_status != .Succeeded {
		wrong("the memory to lend was refused with the status", u64(memory_status))
	}
	before := budget_pages()
	for _ in 0 ..< LENT_MEMORY_ROUNDS {
		lent := [2]u32{lend(memory), lend(memory)}
		list_write(nil, lent[:])
		status, answer := root_call(.Wire, {0 = u64(root_ring.Wire_Step.Apply)})
		refused("a list of no row that gives back its lent handles", before, status, answer, .Argument_Refused, fail(.Wire, .Bad_Value, .Wiring_Rows, 0, 0, 1))
	}
	system.close(memory)
	system.log_fact(.Info, Lent_Handles_Given_Back{lent_handles = 2 * LENT_MEMORY_ROUNDS})
}

// probes_case: the reader of the start joins at 0, the reader of a Wire at
// 5; the refusals of a wiring between them, and the count One after.
@(private = "file")
probes_case :: proc "contextless" () {
	settled := budget_pages()
	first_reader := start_child("output_reader")
	second_reader := start_child("output_reader")
	rows := [1]output.Wiring{row(.Child, 0, WRITER_PROBES, .Started, 1, READER_PROBES)}
	handles := [1]u32{lend(first_reader)}
	list_write(rows[:], handles[:])
	status, answer := start_listed("output_writer", true)
	if status != .Succeeded || answer[0] == 0 {
		wrong_refused("the start of the writer with its list gave the status", status, answer)
	}
	writer := system.Handle(answer[0])

	before := budget_pages()
	// A number that this process did not give through the ring: the
	// second place.
	not_lent := [2]u32{lend(writer), NUMBER_NOT_LENT}
	status, answer = wire(row(.Started, 1, WRITER_PROBES, .Started, 2, READER_PROBES), not_lent[:])
	refused("a number that did not come through the ring", before, status, answer, .Argument_Refused, fail(.Wire, .Handle_Absent, .Lent_Handles, 0, 2))
	// One number in two places: the second place, and the first.
	repeated := lend(writer)
	twice := [2]u32{repeated, repeated}
	status, answer = wire(row(.Started, 1, WRITER_PROBES, .Started, 2, READER_PROBES), twice[:])
	refused("one number in two places", before, status, answer, .Argument_Refused, fail(.Wire, .Bad_Value, .Lent_Handles, 0, 2, 1))
	// Memory handles in place of process handles, in more rounds than the
	// handle table of the root service holds: each one is closed with its
	// refusal, so each round finds the same room. The memory that this
	// process lends is paid by its own budget: the rounds compare with the
	// budget after its creation, and the refusals after its close compare
	// with the budget before it, which comes back only if the root service
	// closed each lent copy.
	memory, memory_status := system.memory_create(1)
	if memory_status != .Succeeded {
		wrong("the memory to lend was refused with the status", u64(memory_status))
	}
	with_memory := budget_pages()
	for _ in 0 ..< LENT_MEMORY_ROUNDS {
		memories := [2]u32{lend(memory), lend(memory)}
		status, answer = wire(row(.Started, 1, WRITER_PROBES, .Started, 2, READER_PROBES), memories[:])
		refused("a lent memory handle", with_memory, status, answer, .Argument_Refused, fail(.Wire, .Handle_Kind, .Lent_Handles, 0, 1, i64(op.Object_Kind.Process), i64(op.Object_Kind.Memory)))
	}
	system.close(memory)
	// A Started end of a process that this process did not start has its
	// host test (output.wiring_end_allowed): an asker receives a process
	// handle that it can lend only from its own Start.
	//
	// A Connected end names the connection by the number of the process
	// handle that Connect gave, and lends nothing: that handle has no Give.
	// A service for which this process does not act for the principal is
	// refused; a number that no Connect gave names no connection.
	// The one path of a Connect: the answer, then the ready completion of
	// the service.
	connection, connect_status := system.service_connection(&requests, next_tag, "log")
	next_tag += 1
	if connect_status != .Succeeded {
		wrong("the connection to the log service gave the outcome word", u64(connect_status))
	}
	defer system.call_connection_end(&connection)
	service_number := u32(connection.process)
	not_acting := [1]u32{lend(second_reader)}
	status, answer = wire(row(.Connected, service_number, 1, .Started, 1, READER_PROBES), not_acting[:])
	refused("a service for which this process does not act for the principal", before, status, answer, .Grant_Or_Right_Missing, fail(.Wire, .No_Grant, .Wirings, 0, 0, 0, 1))
	// The handle of the writer is a handle of this process, but no Connect
	// gave it.
	no_connection := [1]u32{lend(second_reader)}
	status, answer = wire(row(.Connected, u32(writer), 1, .Started, 1, READER_PROBES), no_connection[:])
	refused("a number that no Connect gave", before, status, answer, .Nothing_Has_That_Name, fail(.Wire, .Absent, .Connections, i64(output.Wiring_Field.Writer_Handle), i64(u32(writer)), 0, 1))
	// One process at both ends, named by two handles.
	same := [2]u32{lend(second_reader), lend(second_reader)}
	status, answer = wire(row(.Started, 1, READER_ECHO, .Started, 2, READER_PROBES), same[:])
	refused("one process at both ends", before, status, answer, .Argument_Refused, fail(.Wire, .Bad_Value, .Wirings, i64(output.Wiring_Field.Reader_End), 0, 0, 1))
	// An index past the record outputs of the writer.
	past := [2]u32{lend(writer), lend(second_reader)}
	status, answer = wire(row(.Started, 1, WRITER_OUTPUTS + 1, .Started, 2, READER_PROBES), past[:])
	refused("an index past the record outputs", before, status, answer, .Argument_Refused, fail(.Wire, .Bad_Value, .Wiring_Rows, i64(output.Wiring_Field.Writer_Index), WRITER_OUTPUTS + 1, WRITER_OUTPUTS, 1))
	// A record of another type: its name differs first.
	other_type := [2]u32{lend(writer), lend(second_reader)}
	status, answer = wire(row(.Started, 1, WRITER_OTHERS, .Started, 2, READER_PROBES), other_type[:])
	refused("a record of another type", before, status, answer, .Argument_Refused, fail(.Wire, .Bad_Value, .Record_Types, 0, i64(output.Description_Difference.Name), 0, 1))
	// Wiring terms for a record input that takes none.
	with_terms := [2]u32{lend(writer), lend(second_reader)}
	terms_row := row(.Started, 1, WRITER_PROBES, .Started, 2, READER_PROBES)
	terms_row.terms_offset = u32(output.wiring_terms_start(1, len(with_terms)))
	terms_row.terms_count = 8
	terms := [8]u8{1, 2, 3, 4, 5, 6, 7, 8}
	status, answer = wire(terms_row, with_terms[:], terms[:])
	refused("terms for a record input that takes none", before, status, answer, .Argument_Refused, fail(.Wire, .Bad_Value, .Wiring_Terms, i64(output.Wiring_Field.Terms_Count), 8, 0, 1))
	// Conditions that the root service refuses at its border, in more
	// rounds than its handle table holds: a condition on no field, and a
	// Text for an Integer field. Each refusal closes its lent handles and
	// makes no page, so the budget does not change, and the wirings after
	// them find the room of the table.
	no_field := output.Condition_Terms{field = 0, comparison = u32(output.Condition_Comparison.Equal), value_kind = u32(output.Condition_Value_Kind.Integer)}
	text_for_integer := output.Condition_Terms{field = 1, comparison = u32(output.Condition_Comparison.Equal), value_kind = u32(output.Condition_Value_Kind.Text), text_count = 1}
	text_for_integer.text[0] = 'a'
	for _ in 0 ..< LENT_MEMORY_ROUNDS / 2 {
		conditions := [2]output.Condition_Terms{no_field, text_for_integer}
		for condition, index in conditions {
			ends := [2]u32{lend(writer), lend(second_reader)}
			condition_row := row(.Started, 1, WRITER_PROBES, .Started, 2, READER_PROBES)
			condition_row.condition_offset = u32(output.wiring_terms_start(1, len(ends)))
			condition_row.condition_count = size_of(output.Condition_Terms)
			bytes := transmute([size_of(output.Condition_Terms)]u8)condition
			status, answer = wire(condition_row, ends[:], bytes[:])
			if index == 0 {
				refused("a condition on no field", before, status, answer, .Argument_Refused, fail(.Wire, .Bad_Value, .Wiring_Terms, i64(output.Condition_Terms_Field.Field), 0, PROBE_FIELDS, 1))
			} else {
				refused("a Text for an Integer field", before, status, answer, .Argument_Refused, fail(.Wire, .Bad_Value, .Wiring_Terms, i64(output.Condition_Terms_Field.Value_Kind), i64(output.Condition_Value_Kind.Text), i64(output.Condition_Value_Kind.Integer), 1))
			}
		}
	}

	// The count One: the record input of the first reader has its wiring,
	// which runs until the writer has its second reader, so no stop races
	// with this refusal.
	again := [2]u32{lend(writer), lend(first_reader)}
	status, answer = wire(row(.Started, 1, WRITER_PROBES, .Started, 2, READER_PROBES), again[:])
	refused("a record input of the count One that has its wiring", before, status, answer, .Name_Already_Taken, fail(.Wire, .Exists, .Wirings, i64(output.Wiring_Field.Reader_Index), READER_PROBES, 0, 1))

	// The second reader joins after the five probes of the writer, which
	// waits for it.
	second := [2]u32{lend(writer), lend(second_reader)}
	status, answer = wire(row(.Started, 1, WRITER_PROBES, .Started, 2, READER_PROBES), second[:])
	if status != .Succeeded || answer[0] == 0 {
		wrong("the Wire of the second reader gave the status", u64(status))
	}
	system.log_fact(.Info, Wiring_Refusals_Checked{lent_handles = 2 * LENT_MEMORY_ROUNDS, conditions = LENT_MEMORY_ROUNDS})
	processes := [3]system.Handle{writer, first_reader, second_reader}
	stopped_wait(processes[:])
	for process in processes {
		system.close(process)
	}
	budget_settled_wait(settled, "the probes")
}

// start_case: the refusals of Start and of its list.
@(private = "file")
start_case :: proc "contextless" () {
	before := budget_pages()
	packed := system.name_pack("output_writer")
	list_word := u64(max(root_ring.Start_Wiring_List)) + 1
	status, answer := root_call(.Start, {packed[0], packed[1], packed[2], packed[3], list_word, 0, 0})
	refused("a list word that names nothing", before, status, answer, .Argument_Refused, root_ring.word_refusal(.Start, 2, list_word, u64(max(root_ring.Start_Wiring_List))))
	answer_word := u64(max(root_ring.Start_Answer)) + 1
	status, answer = root_call(.Start, {packed[0], packed[1], packed[2], packed[3], 0, answer_word, 0})
	refused("an answer word that names nothing", before, status, answer, .Argument_Refused, root_ring.word_refusal(.Start, 3, answer_word, u64(max(root_ring.Start_Answer))))
	status, answer = root_call(.Start, {packed[0], packed[1], packed[2], packed[3], 0, 0, 1})
	refused("a reserved word", before, status, answer, .Argument_Refused, root_ring.word_refusal(.Start, 4, 1, 0))

	// The record output log: only the starter of a process wires it, in
	// the list of its Start, once, to a reader that holds the writer. A
	// Wire of the log of a service that this asker does not start, and a
	// Start that names the log of a process other than its child, are
	// refused at the border of the row.
	log_row := row(.Child, 0, 0, .Asker, 0, 0)
	log_row.writer_stream = u32(output.Writer_Stream.Log)
	not_owned := log_row
	not_owned.writer_end, not_owned.writer_handle = u32(output.Wiring_End.Connected), 1
	status, answer = wire(not_owned, nil)
	refused("a Wire of the log of a service", before, status, answer, .Argument_Refused, fail(.Wire, .Bad_Value, .Wiring_Rows, i64(output.Wiring_Field.Writer_Stream), i64(output.Writer_Stream.Log), i64(max(output.Writer_Stream)), 1))
	log_rows := [1]output.Wiring{not_owned}
	list_write(log_rows[:], nil)
	status, answer = start_listed("output_writer", true)
	refused("a Start that names the log of a service", before, status, answer, .Argument_Refused, fail(.Start, .Bad_Value, .Wiring_Rows, i64(output.Wiring_Field.Writer_Stream), i64(output.Writer_Stream.Log), i64(max(output.Writer_Stream)), 1))
	// The log has no index: the smallest index that is not 0.
	indexed := log_row
	indexed.writer_index = 1
	log_rows[0] = indexed
	list_write(log_rows[:], nil)
	status, answer = start_listed("output_writer", true)
	refused("an index of the log", before, status, answer, .Argument_Refused, fail(.Start, .Bad_Value, .Wiring_Rows, i64(output.Wiring_Field.Writer_Index), 1, 0, 1))
	// A second row of the log of the same child.
	two_logs := [2]output.Wiring{log_row, log_row}
	list_write(two_logs[:], nil)
	status, answer = start_listed("output_writer", true)
	refused("a second row of the log", before, status, answer, .Argument_Refused, fail(.Start, .Bad_Value, .Wiring_Rows, i64(output.Wiring_Field.Writer_Stream), i64(output.Writer_Stream.Log), 0, 2))
	// A pace that says the writer never waits: the writer of log waits.
	never := log_row
	never.pace = u32(output.Wiring_Pace.Never_Holds_Writer)
	log_rows[0] = never
	list_write(log_rows[:], nil)
	status, answer = start_listed("output_writer", true)
	refused("the log with the pace Never_Holds_Writer", before, status, answer, .Operation_Unsupported, fail(.Start, .Unsupported, .Wiring_Rows, i64(output.Wiring_Field.Pace), i64(output.Wiring_Pace.Never_Holds_Writer), 0, 1))
	// A condition: an audit keeps each record, and the writer of log takes
	// no condition. The terms are zero: the root service refuses the row
	// before it reads them.
	conditioned := log_row
	conditioned.condition_offset = u32(output.wiring_terms_start(1, 0))
	conditioned.condition_count = size_of(output.Condition_Terms)
	log_rows[0] = conditioned
	no_terms: [size_of(output.Condition_Terms)]u8
	list_write(log_rows[:], nil, no_terms[:])
	status, answer = start_listed("output_writer", true)
	refused("a condition on the log", before, status, answer, .Operation_Unsupported, fail(.Start, .Unsupported, .Wiring_Rows, i64(output.Wiring_Field.Condition_Offset), i64(conditioned.condition_offset), 0, 1))
	// One row of the asker past six.
	asker_rows: [output.WIRING_ASKER_ROWS_OF_A_START + 1]output.Wiring
	for &each in asker_rows {
		each = row(.Child, 0, WRITER_PROBES, .Asker, 0, 0)
	}
	list_write(asker_rows[:], nil)
	status, answer = start_listed("output_writer", true)
	refused("a seventh row of the asker", before, status, answer, .Argument_Refused, fail(.Start, .Bad_Value, .Wiring_Rows, i64(output.Wiring_Field.Reader_End), output.WIRING_ASKER_ROWS_OF_A_START + 1, output.WIRING_ASKER_ROWS_OF_A_START))
	// Six rings of the largest record and the largest capacity: the budget
	// refuses one of them, and each one made before it goes back. The
	// delegated wiring service holds the child budget with Spend only (no
	// Read right), so the kernel returns Budget_Hidden with the cost of
	// the object that did not fit; wiring gives that row in found.
	large_rows: [output.WIRING_ASKER_ROWS_OF_A_START]output.Wiring
	for &each in large_rows {
		each = row(.Child, 0, WRITER_LARGE, .Asker, 0, 0)
		each.capacity = LARGEST_CAPACITY
	}
	list_write(large_rows[:], nil)
	status, answer = start_listed("output_writer", true)
	refused("rings past the budget, after some of them were made", before, status, answer, .Budget_Or_Capacity_Exhausted, fail(.Start, .Budget_Hidden, .Pages, 1), {.Value, .Limit, .Found})
	if found := errors.completion_record(answer).found; found < 1 || found > output.WIRING_ASKER_ROWS_OF_A_START {
		wrong("the rings past the budget name the row", u64(found))
	}
	system.log_fact(.Info, Start_Refusals_Checked{})
}

// end_words_case: Writer_Stopped and Reader_Stopped.
@(private = "file")
end_words_case :: proc "contextless" () {
	settled := budget_pages()
	cases := [2][2]u32{{WRITER_UNENDED, READER_UNENDED}, {WRITER_WATCHED, READER_WATCHED}}
	for pair in cases {
		reader := start_child("output_reader")
		rows := [1]output.Wiring{row(.Child, 0, pair[0], .Started, 1, pair[1])}
		handles := [1]u32{lend(reader)}
		list_write(rows[:], handles[:])
		status, answer := start_listed("output_writer", true)
		if status != .Succeeded || answer[0] == 0 {
			wrong_refused("the start of a writer of an end word gave the status", status, answer)
		}
		writer := system.Handle(answer[0])
		processes := [2]system.Handle{writer, reader}
		stopped_wait(processes[:])
		system.close(writer)
		system.close(reader)
	}
	budget_settled_wait(settled, "the end words")
	system.log_fact(.Info, Stopped_Ends_Checked{})
}

// decimal_text writes value in decimal into digits, and gives the text.
@(private = "file")
decimal_text :: proc "contextless" (digits: []u8, value: u64) -> string {
	count := 0
	rest := value
	for {
		count += 1
		rest /= 10
		if rest == 0 || count == len(digits) {
			break
		}
	}
	rest = value
	for place := count - 1; place >= 0; place -= 1 {
		digits[place] = u8('0' + rest % 10)
		rest /= 10
	}
	return string(digits[:count])
}

// log_text_wrong stops with the serial, the form, the level and the text
// of a record of the log of log_flood that is not the one that it wrote.
@(private = "file")
log_text_wrong :: proc "contextless" (serial: u32, record: ^output.Log_Output_Record, wanted: string) -> ! {
	text, _ := output.log_output_text(record)
	system.log_fact(.Error, Wrong_Log_Text{record_serial = u64(serial), form_word = u64(record.form), level_word = u64(record.level), more = u64(record.more), runs = u64(record.run_count)}, text, wanted)
	system.stop(.Failed)
}

// log_text_expect checks one text record of the log of log_flood.
@(private = "file")
log_text_expect :: proc "contextless" (serial: u32, record: ^output.Log_Output_Record, wanted: string, level: op.Log_Level, more: u8, runs: u8) {
	text, ok := output.log_output_text(record)
	if !ok || text != wanted || record.level != level || record.more != more || record.run_count != runs {
		log_text_wrong(serial, record, wanted)
	}
}

// log_case: the record output log of log_flood wired to this asker at its
// start. The log budget of log_flood is 0: the kernel refuses each of its
// calls, and its log holds each record, in order, from the joined record
// of 0 to its stop. Its last line says the count of the calls that the
// kernel refused, which must be each call before it.
@(private = "file")
log_case :: proc "contextless" () {
	log_row := row(.Child, 0, 0, .Asker, 0, 0)
	log_row.writer_stream = u32(output.Writer_Stream.Log)
	log_row.pace = u32(output.Wiring_Pace.Always_Holds_Writer)
	rows := [1]output.Wiring{log_row}
	list_write(rows[:], nil)
	status, answer := start_listed("log_flood", true)
	if status != .Succeeded || answer[0] == 0 || answer[1] == 0 {
		wrong_refused("the start of log_flood with its log wired gave the status", status, answer)
	}
	flood := system.Handle(answer[0])
	number := u32(answer[1])
	record: output.Log_Output_Record
	item, read_status := system.asker_read(number, &record, hang_deadline())
	if read_status != .Ok || item.kind != .Joined || item.serial != 0 {
		wrong("the first compartment of the log of log_flood is not the joined record of 0; the status word", u64(read_status))
	}
	// Snapshot after the first asker_read, which initializes this process's
	// permanent stream-end and reader-wait arenas from its own budget.
	settled := budget_pages()
	next := u32(0)
	read_next :: proc "contextless" (number: u32, record: ^output.Log_Output_Record, serial: u32) {
		item, read_status := system.asker_read(number, record, hang_deadline())
		if read_status != .Ok || item.kind != .Record || item.serial != serial {
			system.log_fact(.Error, Wrong_Log_Record{record_serial = u64(serial), status_word = u64(read_status), kind_word = u64(item.kind), serial = u64(item.serial)})
			system.stop(.Failed)
		}
	}
	// 1. The lines, each with its number as one value run.
	line: [64]u8
	digits: [20]u8
	for number_of_line in u64(0) ..< FLOOD_LINES {
		read_next(number, &record, next)
		count := copy(line[:], "log_flood: line ")
		count += copy(line[count:], decimal_text(digits[:], number_of_line))
		log_text_expect(next, &record, string(line[:count]), .Info, 0, 1)
		next += 1
	}
	// 2. The long line, cut as the kernel cuts it.
	long: [FLOOD_LONG_LINE_BYTES]u8
	for &letter, index in long {
		letter = 'a' + u8(index % 26)
	}
	for start := 0; start < len(long); start += op.LOG_TEXT_CAPACITY {
		end := min(start + op.LOG_TEXT_CAPACITY, len(long))
		read_next(number, &record, next)
		log_text_expect(next, &record, string(long[start:end]), .Info, end < len(long) ? 1 : 0, 0)
		next += 1
	}
	// 3. The fact: one part, its values the bytes of the record.
	read_next(number, &record, next)
	wanted_fact := Flood_Fact{number = FLOOD_LINES, mark = FLOOD_MARK}
	wanted_bytes := transmute([size_of(Flood_Fact)]u8)wanted_fact
	fact, fact_ok := output.log_output_fact(&record)
	if !fact_ok || record.level != .Warning || record.more != 0 || fact.part != 0 || fact.part_count != 1 || fact.key == 0 || int(fact.value_count) != size_of(Flood_Fact) || string(fact.values[:size_of(Flood_Fact)]) != string(wanted_bytes[:]) {
		system.log_fact(.Error, Wrong_Flood_Fact{record_serial = u64(next), form_word = u64(record.form), level_word = u64(record.level), part = u64(fact.part), part_count = u64(fact.part_count), value_count = u64(fact.value_count)})
		system.stop(.Failed)
	}
	next += 1
	// 4. The count of the calls that the kernel refused: each one before.
	calls := u64(FLOOD_LINES + 2)
	read_next(number, &record, next)
	count := copy(line[:], "log_flood: the kernel refused ")
	count += copy(line[count:], decimal_text(digits[:], calls))
	count += copy(line[count:], " lines")
	log_text_expect(next, &record, string(line[:count]), .Info, 0, 1)
	next += 1
	// 5. The end of the reader while the writer waits: log_flood writes
	// more lines than the ring holds, which this asker never reads. This
	// asker waits, by a state and within the hang bound, until the ring is
	// full and log_flood waits for room in it; then it closes its end. The
	// end word ends that wait, and log_flood stops with Done: its log never
	// holds it past the end of its reader.
	full, held_now, capacity := system.asker_full_and_writer_waits(number, output.Log_Output_Record, hang_deadline())
	if full != .Held || held_now != capacity {
		system.log_fact(.Error, Wrong_Log_Ring_Not_Full{end_word = u64(full), held_compartments = u64(held_now), capacity = u64(capacity)})
		system.stop(.Failed)
	}
	if !system.asker_close(number) {
		wrong("the end of the log of log_flood was not an end of this asker", u64(number))
	}
	processes := [1]system.Handle{flood}
	stopped_wait(processes[:])
	_, cause, outcome := system.process_state(flood)
	if cause != .Itself || outcome != .Done {
		system.log_fact(.Error, Wrong_Flood_Stop{stop_cause_word = u64(cause), stop_outcome_word = u64(outcome)})
		system.stop(.Failed)
	}
	system.close(flood)
	budget_settled_wait(settled, "the log")
	system.log_fact(.Info, Flood_Log_Kept{records = u64(next), calls = calls})
}

// The wirings that limit_case holds at most: a bound of the test, which the
// budget of this asker meets first.
LIMIT_CASE_WIRINGS_MOST :: 1024

// limit_case: the wirings of an asker have no count: this process holds 8,
// a 9th and 20, then wires until the budget of its wirings or of its own
// ends pays no more; the next Wire and the row of a Start are refused, each
// with the budget unchanged; then the revocation of the grant wirings.
@(private = "file")
limit_case :: proc "contextless" () {
	writer := start_child("output_writer")
	numbers: [LIMIT_CASE_WIRINGS_MOST]u32
	held := 0
	status: call_outcome.Call_Outcome
	answer: [7]u64
	for held < len(numbers) {
		handles := [1]u32{lend(writer)}
		status, answer = wire(row(.Started, 1, WRITER_LARGE, .Asker, 0, 0), handles[:])
		if status != .Succeeded || answer[0] == 0 {
			break
		}
		numbers[held] = u32(answer[0])
		held += 1
		// Take the end from this process's wiring ring so the ring does not
		// fill at WIRING_RING_CAPACITY before the wiring budget runs out.
		probe: Large
		_, _ = system.asker_read(numbers[held - 1], &probe, 0)
		// The root service records the grant before it answers the Wire.
		if granted, _ := grants_read(); .Wirings not_in granted {
			wrong("a wiring is held and the grant wirings is not granted; the grants", transmute(u64)granted)
		}
	}
	if held < 20 {
		wrong_refused("a wiring of an asker before its 20th gave the status", status, answer)
	}
	if held == len(numbers) {
		wrong("the budget of this asker paid each wiring of the test; wirings:", u64(held))
	}
	// The refusal that ended the loop is the budget's: of the wirings
	// (Budget or Budget_Hidden of Pages, since wiring holds Spend only) or of
	// the place of an end (Full), and it changed nothing.
	budget_refused :: proc "contextless" (what: string, before: u64, status: call_outcome.Call_Outcome, answer: [7]u64) {
		record := errors.completion_record(answer)
		by_budget := status == .Budget_Or_Capacity_Exhausted && (errors.Kind(record.kind) == .Budget || errors.Kind(record.kind) == .Budget_Hidden) && errors.Unit(record.unit) == .Pages
		by_place := (status == .Budget_Or_Capacity_Exhausted || status == .Callee_Busy) && errors.Kind(record.kind) == .Full
		if !by_budget && !by_place {
			wrong_refused(what, status, answer)
		}
		if budget_pages() != before {
			wrong("a refused wiring changed the budget of this asker; pages:", budget_pages())
		}
	}
	before := budget_pages()
	handles := [1]u32{lend(writer)}
	status, answer = wire(row(.Started, 1, WRITER_LARGE, .Asker, 0, 0), handles[:])
	budget_refused("one wiring past the budget of an asker gave the status", before, status, answer)
	// The row of a Start counts as a Wire does: the start is refused
	// whole, before the child runs.
	rows := [1]output.Wiring{row(.Child, 0, WRITER_ASKED, .Asker, 0, 0)}
	list_write(rows[:], nil)
	status, answer = start_listed("output_writer", true)
	budget_refused("one row of a Start past the budget of an asker gave the status", before, status, answer)
	grant_wirings_revoke(held)
	asker_ends_close(numbers[:held], Large)
	processes := [1]system.Handle{writer}
	stopped_wait(processes[:])
	system.close(writer)
	grant_wirings_gone_wait("the grant wirings stayed after limit_case revoked its wirings; the grants")
	system.log_fact(.Info, Asker_Limit_Checked{wirings = u64(held)})
}

// side_case: output_side refuses the end of its start, then writes words
// that the root service drops, answers the end of a Wire, writes one probe
// and closes that end, then reads no command. This process reads the
// probe and the end word Side_Closed, then wires it until its wiring ring
// is full: the root service refuses the next end with Busy. The wirings of this process are revoked when they reach its
// limit, and their ends leave its own wiring ring, which stays read.
@(private = "file")
side_case :: proc "contextless" () {
	settled := budget_pages()
	rows := [1]output.Wiring{row(.Child, 0, SIDE_ECHO, .Asker, 0, 0)}
	list_write(rows[:], nil)
	status, answer := start_listed("output_side", true)
	if status != .Succeeded || answer[0] == 0 || answer[1] == 0 {
		wrong("the start of output_side with its list gave the status", u64(status))
	}
	side := system.Handle(answer[0])
	refused_number := u32(answer[1])
	// The root service waits on the answers of each process: the refusal
	// starts its pass, and the end word comes with no command of this one.
	probe: Probe
	refused_end, refused_status := system.asker_read(refused_number, &probe, hang_deadline())
	if refused_status != .Ended || refused_end.end_word != .Refused {
		wrong("the end that output_side refused did not end with Refused; the status", u64(refused_status))
	}
	// That wiring was the only one of this process: limit_case revoked
	// its own, and the wirings of the cases before ended with their
	// processes. The root service writes the end word before it ends the
	// grant and frees the wiring page, so the revocation first waits for
	// the end of that call (grant_wirings_revoke).
	grant_wirings_revoke(0)

	// The wirings of output_side go back in batches, so a full wiring ring
	// of output_side, not the budget of this asker, refuses the next end.
	SIDE_BATCH :: 8
	numbers: [SIDE_BATCH]u32
	held := 0
	wire_side :: proc "contextless" (process: system.Handle) -> (call_outcome.Call_Outcome, [7]u64) {
		handles := [1]u32{lend(process)}
		return wire(row(.Started, 1, SIDE_ECHO, .Asker, 0, 0), handles[:])
	}
	// The end of this Wire is the one that output_side answers with Taken,
	// Taken again, one probe and Closed; it takes no other command.
	status, answer = wire_side(side)
	if status != .Succeeded || answer[0] == 0 {
		wrong_refused("the Wire of output_side gave the status", status, answer)
	}
	closed_number := u32(answer[0])
	// The Closed of the writer keeps the wiring for this reader: the
	// joined record and the probe come, then the end word Side_Closed.
	joined, joined_status := system.asker_read(closed_number, &probe, hang_deadline())
	written, written_status := system.asker_read(closed_number, &probe, hang_deadline())
	if joined_status != .Ok || joined.kind != .Joined || joined.serial != 0 || written_status != .Ok || written.kind != .Record || probe.serial != 0 {
		wrong("the wiring that output_side closed did not give the joined record of 0 and the probe 0; the status", u64(written_status))
	}
	side_closed, side_closed_status := system.asker_read(closed_number, &probe, hang_deadline())
	if side_closed_status != .Ended || side_closed.end_word != .Side_Closed {
		wrong("the wiring that output_side closed did not end with Side_Closed; the end word", u64(side_closed.end_word))
	}
	// This reader said Closed in turn, before asker_read gave Side_Closed,
	// and the wiring ends with the two Closed words. It was the only wiring
	// of this process, so the grant ends with it: the revocation waits
	// until the root service read the word, then it is refused.
	grant_wirings_revoke(0)
	for _ in 0 ..< SIDE_RING_CAPACITY {
		if held == len(numbers) {
			grant_wirings_revoke(held)
			asker_ends_close(numbers[:held], Probe)
			held = 0
		}
		status, answer = wire_side(side)
		if status != .Succeeded || answer[0] == 0 {
			wrong_refused("a Wire of output_side before its wiring ring is full gave the status", status, answer)
		}
		numbers[held] = u32(answer[0])
		held += 1
	}
	if held == len(numbers) {
		grant_wirings_revoke(held)
		asker_ends_close(numbers[:held], Probe)
		held = 0
	}
	before := budget_pages()
	status, answer = wire_side(side)
	refused("an end for a wiring ring that is full", before, status, answer, .Callee_Busy, fail(.Wire, .Busy, .Wirings, 0, 1, SIDE_RING_CAPACITY, 1))
	// The ring holds a multiple of the limit of an asker, so the loop
	// revoked each wiring and held is 0 here: the refused Wire gave no
	// grant, and the revocation is refused whole.
	grant_wirings_revoke(held)
	asker_ends_close(numbers[:held], Probe)
	packed := system.name_pack("output_side")
	stop_status, _ := root_call(.Stop, {packed[0], packed[1], packed[2], packed[3], 0, 0, 0})
	if stop_status != .Succeeded {
		wrong("the stop of output_side gave the status", u64(stop_status))
	}
	processes := [1]system.Handle{side}
	stopped_wait(processes[:])
	system.close(side)
	budget_settled_wait(settled, "the side")
	system.log_fact(.Info, Side_Checked{ends = SIDE_RING_CAPACITY})
}

// asker_case: a wiring to this process as its asker, read with
// asker_read; this process then stops, and the writer reads
// Asker_Stopped.
@(private = "file")
asker_case :: proc "contextless" () -> ! {
	rows := [1]output.Wiring{row(.Child, 0, WRITER_ASKED, .Asker, 0, 0)}
	list_write(rows[:], nil)
	status, answer := start_listed("output_writer", true)
	if status != .Succeeded || answer[1] == 0 {
		wrong_refused("the start of the writer with a row of the asker gave the status", status, answer)
	}
	number := u32(answer[1])
	probe: Probe
	joined, joined_status := system.asker_read(number, &probe, hang_deadline())
	item, item_status := system.asker_read(number, &probe, hang_deadline())
	if joined_status != .Ok || joined.kind != .Joined || joined.serial != 0 || item_status != .Ok || item.kind != .Record || probe.serial != 0 {
		wrong("the wiring of the asker did not give the joined record of 0 and the probe 0; the status", u64(item_status))
	}
	system.log_fact(.Info, Asker_Wiring_Checked{refusals = u64(refusals)})
	system.log_fact(.Info, Checked{})
	system.stop(.Done)
}

// Measure pending: the 2048 pages of the least budget in which it ran
// before its floor was counted. The first machine pass with the check of
// the floors (the check boot-test of the flake) writes the peak of its
// budget at its first state of work; modustool floors measured on the log
// of that pass gives the working memory that replaces this number
// (src/md/features/module_budget_request.md, "The first state of work").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 2048}
