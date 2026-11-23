// The asker of the machine test of the audit of the collector
// (src/md/features/module_outputs.md, "The audit"). It starts `collector`
// with no list. The root service first refuses two lists of pairs, each
// with its status and its error record, and the budget of this process
// unchanged:
//
// - a Wire of collector.forward with no source row (paired_row 0);
// - a Start of generic_source whose list gives one source two pairs.
//
// Neither starts generic_source, so the collector opens no space for them;
// the console counts the sources of the collector after this process.
// Last, `generic_source` with one list of three rows:
//
// 1. generic_source.left to collector.sources, with the terms Audit and
//    Forward, at the pace of an audit;
// 2. collector.forward to this process, the pair of the row 1;
// 3. generic_source.right to collector.sources, with the terms Audit and
//    Keeps: generic_source writes only when both of its outputs have a
//    reader.
//
// This process reads the pair: each probe of left once, in its order, then
// the clean end of the source, which the collector gives after the last
// record that its space kept. The console then reads the spaces of the
// collector, and checks their chains after a stop of the collector and
// after a restart of the machine.
//
// **Start**: `start("audit_asker")` in the console of principal 0. **What
// a reader sees**: no window; one line "audit_asker: ..." when the pair
// gave each probe, or a line "audit_asker: WRONG: ...". It stops itself
// with Done, or Failed after a WRONG line.
package audit_asker

import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/module"
import "modus:contract/output"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:contract/wide_grants"
import "modus:system"

// The probe of generic_source.
Probe :: struct {
	side:   u64,
	number: u64,
	mark:   u64,
}

// The constants of generic_source, and the rows of the tables of the
// modules, sorted by name.
PROBES_OF_A_SIDE :: 20
SOURCE_LEFT :: 1
SOURCE_RIGHT :: 3
COLLECTOR_SOURCES :: 1
COLLECTOR_FORWARD :: 1

// The bound of each audit space, in records: the probes of a side fit.
SPACE_BOUND_RECORDS :: 32

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

// lend gives the root service a process handle through the root ring: it
// closes each lent number at the end of the command that names it.
@(private = "file")
lend :: proc "contextless" (handle: system.Handle) -> u32 {
	given, status := system.give(requests_memory, handle, {.Read})
	if status != .Ok {
		wrong("the gift of a handle to the root service gave the status", u64(status))
	}
	return u32(given)
}

@(private = "file")
start_listed :: proc "contextless" (name: string, listed: bool) -> (call_outcome.Call_Outcome, [7]u64) {
	packed := system.name_pack(name)
	list := listed ? root_ring.Start_Wiring_List.In_The_List_Page : root_ring.Start_Wiring_List.None
	return root_call(.Start, {packed[0], packed[1], packed[2], packed[3], u64(list), u64(root_ring.Start_Answer.Process_Handle), 0})
}

// row gives one row of a list, at the pace of an audit.
@(private = "file")
row :: proc "contextless" (writer_end: output.Wiring_End, writer_place, writer_index: u32, reader_end: output.Wiring_End, reader_place, reader_index: u32) -> output.Wiring {
	return {writer_end = u32(writer_end), writer_handle = writer_place, writer_stream = u32(output.Writer_Stream.Record_Output), writer_index = writer_index, reader_end = u32(reader_end), reader_handle = reader_place, reader_index = reader_index, pace = u32(output.Wiring_Pace.Always_Holds_Writer)}
}

@(private = "file")
budget_pages :: proc "contextless" () -> u64 {
	amounts, _ := system.budget_read()
	return amounts.pages
}

// refused checks one refusal whole: its status, each field of its error
// record, and the pages of the budget of this process.
@(private = "file")
refused :: proc "contextless" (what: string, before: u64, status: call_outcome.Call_Outcome, answer: [7]u64, wanted: call_outcome.Call_Outcome, expected: [7]u64) {
	record := errors.completion_record(answer)
	want := errors.completion_record(expected)
	if status != wanted || record != want {
		system.log_fact(.Error, Wrong_Refusal{outcome = call_outcome.Call_Outcome_Word(status), kind = record.kind, unit = record.unit, operation = record.operation, argument = record.argument, value = record.value, limit = record.limit, found = record.found}, what)
		system.log_fact(.Error, Wrong_Refusal_Wanted{outcome = call_outcome.Call_Outcome_Word(wanted), kind = want.kind, unit = want.unit, operation = want.operation, argument = want.argument, value = want.value, limit = want.limit, found = want.found}, what)
		system.stop(.Failed)
	}
	if after := budget_pages(); after != before {
		wrong("the pages of the budget changed after a refusal; now", after)
	}
}

// list_write writes a wiring list in the list page, with the terms of its
// rows after the lent handles.
@(private = "file")
list_write :: proc "contextless" (rows: []output.Wiring, handles: []u32, terms: []wide_grants.Space_Terms) {
	for &value in list_page {
		value = 0
	}
	if !output.wiring_list_write(list_page, rows, handles) {
		wrong("the list does not fit the list page; rows:", u64(len(rows)))
	}
	terms_start := output.wiring_terms_start(len(rows), len(handles))
	copy(list_page[terms_start:], ([^]u8)(raw_data(terms))[:len(terms) * size_of(wide_grants.Space_Terms)])
}

// refusals_case: the two lists of pairs that the root service refuses.
@(private = "file")
refusals_case :: proc "contextless" (collector: system.Handle) {
	before := budget_pages()
	// A pair that names no source row.
	{
		handles := [1]u32{lend(collector)}
		rows := [1]output.Wiring{row(.Started, 1, COLLECTOR_FORWARD, .Asker, 0, 0)}
		list_write(rows[:], handles[:], nil)
		status, answer := root_call(.Wire, {0 = u64(root_ring.Wire_Step.Apply)})
		refused("a pair of collector.forward with no source row", before, status, answer, .Argument_Refused, errors.ring_fail(u32(root_ring.Root_Command.Wire), .Bad_Value, .Wiring_Rows, i64(output.Wiring_Field.Paired_Row), 0, 0, 1))
	}
	// Two pairs of one source: the second is refused, and nothing starts.
	{
		handles := [1]u32{lend(collector)}
		rows := [3]output.Wiring {
			row(.Child, 0, SOURCE_LEFT, .Started, 1, COLLECTOR_SOURCES),
			row(.Started, 1, COLLECTOR_FORWARD, .Asker, 0, 0),
			row(.Started, 1, COLLECTOR_FORWARD, .Asker, 0, 0),
		}
		rows[1].paired_row = 1
		rows[2].paired_row = 1
		rows[0].terms_offset = u32(output.wiring_terms_start(len(rows), len(handles)))
		rows[0].terms_count = size_of(wide_grants.Space_Terms)
		terms := [1]wide_grants.Space_Terms{audit_terms(.Forward)}
		list_write(rows[:], handles[:], terms[:])
		status, answer := start_listed("generic_source", true)
		refused("a second pair of one source", before, status, answer, .Name_Already_Taken, errors.ring_fail(u32(root_ring.Root_Command.Start), .Exists, .Wirings, i64(output.Wiring_Field.Paired_Row), 1, 0, 3))
	}
	system.log_fact(.Info, Pair_Refusals_Checked{})
}

// display_refusal_case calls plan_diff_ask of the holder of Display as a
// caller that holds no role Plans and does not act for its principal: the
// display refuses it with No_Grant, and shows nothing
// (src/md/features/declarations.md, "The trusted display of a plan").
@(private = "file")
display_refusal_case :: proc "contextless" (ctx: ^system.Context) {
	image_handle := ctx.handles[system.GRANT_IMAGE]
	address, map_status := system.memory_map(image_handle, {})
	if image_handle == 0 || map_status != .Ok {
		wrong("the boot image does not map; the status word", u64(map_status))
	}
	image := ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	connection, connected := system.service_connection(&requests, next_tag, "display")
	next_tag += 1
	if connected != .Succeeded {
		wrong("the root service gave no connection to the holder of Display; the outcome word", u64(connected))
	}
	entry := system.image_entry_of(image, connection.module_hash)
	if entry == nil {
		wrong("the holder of Display is no module of the boot image", 0)
	}
	file := image[entry.offset:][:entry.size]
	if blake3.hash(file) != connection.module_hash {
		wrong("the file of the holder of Display has not its hash", 0)
	}
	ask := module.export_find(file, "plan_diff_ask")
	if ask == 0 {
		wrong("the holder of Display has no export plan_diff_ask", 0)
	}
	name := "not the holder of plans"
	added := "notes: store documents"
	removed := ""
	arguments := [3]isolated.Argument{{text = transmute([]u8)name}, {text = transmute([]u8)added}, {text = transmute([]u8)removed}}
	error: errors.Error_Record
	result, outcome := system.call_isolated(&connection, file, ask, arguments[:], &error)
	if outcome != .Grant_Or_Right_Missing || result != 0 || error.kind != i64(errors.Kind.No_Grant) || error.unit != i64(errors.Unit.Acts_For_Principal) {
		system.log_fact(.Error, Wrong_Display_Answer{outcome = call_outcome.Call_Outcome_Word(outcome), result = result, error_kind = error.kind, error_unit = error.unit})
		system.stop(.Failed)
	}
	system.call_connection_end(&connection)
	system.log_fact(.Info, Display_Refused_A_Stranger{})
}

// audit_terms gives the terms of an audit space of probes.
@(private = "file")
audit_terms :: proc "contextless" (forwarding: wide_grants.Space_Forwarding) -> wide_grants.Space_Terms {
	return {kind_word = i64(wide_grants.Collector_Space_Kind.Audit), bound_records = SPACE_BOUND_RECORDS, forwarding_word = i64(forwarding), record_size = size_of(Probe)}
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
	collector_status, collector_answer := start_listed("collector", false)
	if collector_status != .Succeeded || collector_answer[0] == 0 {
		wrong_refused("the start of the collector gave the status", collector_status, collector_answer)
	}
	collector := system.Handle(collector_answer[0])
	refusals_case(collector)
	display_refusal_case(ctx)

	// The audited list, last.
	handles := [1]u32{lend(collector)}
	rows := [3]output.Wiring {
		row(.Child, 0, SOURCE_LEFT, .Started, 1, COLLECTOR_SOURCES),
		row(.Started, 1, COLLECTOR_FORWARD, .Asker, 0, 0),
		row(.Child, 0, SOURCE_RIGHT, .Started, 1, COLLECTOR_SOURCES),
	}
	rows[1].paired_row = 1
	terms := [2]wide_grants.Space_Terms{audit_terms(.Forward), audit_terms(.Keeps)}
	terms_start := output.wiring_terms_start(len(rows), len(handles))
	rows[0].terms_offset = u32(terms_start)
	rows[0].terms_count = size_of(wide_grants.Space_Terms)
	rows[2].terms_offset = u32(terms_start + size_of(wide_grants.Space_Terms))
	rows[2].terms_count = size_of(wide_grants.Space_Terms)
	list_write(rows[:], handles[:], terms[:])
	status, answer := start_listed("generic_source", true)
	if status != .Succeeded || answer[0] == 0 || answer[1] == 0 {
		wrong_refused("the start of generic_source with the audited list gave the status", status, answer)
	}
	source := system.Handle(answer[0])
	number := u32(answer[1])

	// The pair gives the records of its source only: each probe of left,
	// in its order, then the end of the source. Its serials move forward
	// by any count, as the serial of forward counts each pair.
	probe: Probe
	item, read_status := system.asker_read(number, &probe, hang_deadline())
	if read_status != .Ok || item.kind != .Joined {
		wrong("the first compartment of the pair is not a joined record; the status word", u64(read_status))
	}
	received := u64(0)
	last_serial: u32
	for {
		item, read_status = system.asker_read(number, &probe, hang_deadline())
		if read_status == .Ended {
			break
		}
		if read_status != .Ok || item.kind != .Record || (received > 0 && item.serial <= last_serial) || probe.side != 1 || probe.number != received || probe.mark != received % 2 {
			system.log_fact(.Error, Wrong_Forwarded_Record{status_word = u64(read_status), kind_word = u64(item.kind), serial = u64(item.serial), probe_side = probe.side, probe_number = probe.number, wanted_number = received})
			system.stop(.Failed)
		}
		last_serial = item.serial
		received += 1
	}
	if item.end_word != .None || item.error != {} || received != PROBES_OF_A_SIDE {
		system.log_fact(.Error, Wrong_Pair_End{end_word = u64(item.end_word), error_kind = u64(item.error.kind), records = received, wanted_records = PROBES_OF_A_SIDE})
		system.stop(.Failed)
	}
	// The source stops itself once both of its outputs ended.
	deadline := hang_deadline()
	for {
		state, cause, outcome := system.process_state(source)
		if state == .Stopped {
			if cause != .Itself || outcome != .Done {
				wrong("generic_source did not stop itself with Done; its stop cause word", u64(cause))
			}
			break
		}
		if system.time() >= deadline {
			wrong("generic_source did not stop within the hang bound, in milliseconds:", system.TEST_HANG_BOUND_MILLISECONDS)
		}
		wait := system.wait_begin()
		system.wait_end(&wait, deadline)
	}
	system.close(source)
	system.close(collector)
	system.log_fact(.Info, Pair_Forwarded{probes = received})
	system.stop(.Done)
}
