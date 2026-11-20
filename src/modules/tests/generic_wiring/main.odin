// The asker of the machine test of the generic record inputs, `merge` and
// `filter` (src/md/features/module_outputs.md, "Generic record inputs and
// the utility modules", and its decisions of step 8). It starts
// `generic_source` and `filter` with no list, then tries each refusal of
// the root service, each with its status, its error record and the budget
// of this process unchanged:
//
// 1. a second source of merge.sources of another record than the first;
// 2. a Wire of filter.kept before a wiring fixed the type of filter.source;
// 3. a condition on merge.merged that names no field of the record that
//    merge.sources fixed;
// 4. more wirings than an asker holds.
//
// Then one start list: filter.kept to this process, generic_source.left
// and generic_source.right to merge.sources, and merge.merged to
// filter.source with the terms mark = 1. This process reads kept: the
// joined record of 0, each probe of mark 1 of each side once, then a clean
// end. It checks the order of the probes of each side, and no order across
// the two sides: merge promises none.
//
// Last, filter with the terms of a field 0: it ends kept at once with the
// error record that names the field.
//
// **Start**: `start("generic_wiring")` in the console. **What a reader
// sees**: no window; one line "generic_wiring: ...: as it must" for each
// case, then "generic_wiring: ok", or a line "generic_wiring: WRONG: ...".
// It stops itself with Done, or Failed after a WRONG line.
package generic_wiring

import "modus:contract/errors"
import "modus:contract/output"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:support/system"

// The probe of generic_source.
Probe :: struct {
	side:   u64,
	number: u64,
	mark:   u64,
}

// The constants of generic_source, and the rows of the tables of the
// modules, sorted by name.
PROBES_OF_A_SIDE :: 20
PROBE_FIELDS :: 3
PROBE_FIELD_MARK :: 3
SOURCE_LEFT :: 1
SOURCE_OTHER :: 2
SOURCE_RIGHT :: 3
MERGE_SOURCES :: 1
MERGE_MERGED :: 1
FILTER_SOURCE :: 1
FILTER_KEPT :: 1

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
	system.log(.Error, "generic_wiring: WRONG: ", text, " ", value)
	system.stop(.Failed)
}

@(private = "file")
wrong_refused :: proc "contextless" (text: string, status: system.Status, answer: [7]u64) -> ! {
	system.log(.Error, "generic_wiring: WRONG: ", text, " ", u64(status), "; the error record: ", answer[0], " ", answer[1], " ", answer[2], " ", answer[3], " ", answer[4], " ", answer[5], " ", answer[6])
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

// lend gives the root service a process handle through the root ring:
// it closes each lent number at the end of the command that names it.
@(private = "file")
lend :: proc "contextless" (handle: system.Handle) -> u32 {
	given, status := system.give(requests_memory, handle, {.Read})
	if status != .Ok {
		wrong("the gift of a handle to the root service gave the status", u64(status))
	}
	return u32(given)
}

// list_write writes a wiring list in the list page, with the bytes of its
// terms and of its conditions after the lent handles.
@(private = "file")
list_write :: proc "contextless" (rows: []output.Wiring, handles: []u32, after_handles: []u8 = nil) {
	for &value in list_page {
		value = 0
	}
	if !output.wiring_list_write(list_page, rows, handles) {
		wrong("the list does not fit the list page; rows:", u64(len(rows)))
	}
	copy(list_page[output.wiring_terms_start(len(rows), len(handles)):], after_handles)
}

@(private = "file")
start_listed :: proc "contextless" (name: string, listed: bool) -> (system.Status, [7]u64) {
	packed := system.name_pack(name)
	list := listed ? root_ring.Start_Wiring_List.In_The_List_Page : root_ring.Start_Wiring_List.None
	return root_call(.Start, {packed[0], packed[1], packed[2], packed[3], u64(list), u64(root_ring.Start_Answer.Process_Handle), 0})
}

@(private = "file")
start_child :: proc "contextless" (name: string) -> system.Handle {
	status, answer := start_listed(name, false)
	if status != .Ok || answer[0] == 0 {
		wrong_refused("the start of a child gave the status", status, answer)
	}
	return system.Handle(answer[0])
}

// row gives one row of a list.
@(private = "file")
row :: proc "contextless" (writer_end: output.Wiring_End, writer_place, writer_index: u32, reader_end: output.Wiring_End, reader_place, reader_index: u32) -> output.Wiring {
	return {writer_end = u32(writer_end), writer_handle = writer_place, writer_stream = u32(output.Writer_Stream.Record_Output), writer_index = writer_index, reader_end = u32(reader_end), reader_handle = reader_place, reader_index = reader_index}
}

@(private = "file")
budget_pages :: proc "contextless" () -> u64 {
	amounts, _ := system.budget_read()
	return amounts.pages
}

@(private = "file")
fail :: proc "contextless" (command: root_ring.Root_Command, kind: errors.Kind, unit: errors.Unit, argument: i64 = 0, value: i64 = 0, limit: i64 = 0, found: i64 = 0) -> [7]u64 {
	return errors.ring_fail(u32(command), kind, unit, argument, value, limit, found)
}

// refused checks one refusal whole: its status, each field of its error
// record, and the pages of the budget of this process.
@(private = "file")
refused :: proc "contextless" (what: string, before: u64, status: system.Status, answer: [7]u64, wanted: system.Status, expected: [7]u64) {
	record := errors.completion_record(answer)
	want := errors.completion_record(expected)
	if status != wanted || record != want {
		system.log(.Error, "generic_wiring: WRONG: ", what, ": the status ", status, ", the kind ", record.kind, ", the unit ", record.unit, ", the operation ", record.operation, ", the argument ", record.argument, ", the value ", record.value, ", the limit ", record.limit, ", the found ", record.found)
		system.log(.Error, "generic_wiring: WRONG: ", what, ": wanted the status ", wanted, ", the kind ", want.kind, ", the unit ", want.unit, ", the operation ", want.operation, ", the argument ", want.argument, ", the value ", want.value, ", the limit ", want.limit, ", the found ", want.found)
		system.stop(.Failed)
	}
	if after := budget_pages(); after != before {
		system.log(.Error, "generic_wiring: WRONG: ", what, ": the budget held ", before, " pages before and ", after, " after")
		system.stop(.Failed)
	}
	refusals += 1
}

// done_wait waits until each process stopped itself with Done, within the
// hang bound.
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
				wrong("a child did not stop itself with Done; its stop cause word", u64(cause))
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

// stopped_wait waits until a process stopped, whatever its stop.
@(private = "file")
stopped_wait :: proc "contextless" (process: system.Handle) {
	deadline := hang_deadline()
	for {
		wait := system.wait_begin()
		if state, _, _ := system.process_state(process); state == .Stopped {
			return
		}
		if system.time() >= deadline {
			wrong("a child did not stop within the hang bound, in milliseconds:", system.TEST_HANG_BOUND_MILLISECONDS)
		}
		system.wait_end(&wait, deadline)
	}
}

// mark_terms gives the condition mark = value as the terms of filter.
@(private = "file")
mark_terms :: proc "contextless" (field: u32, value: i64) -> [size_of(output.Condition_Terms)]u8 {
	terms := output.Condition_Terms{field = field, comparison = u32(output.Condition_Comparison.Equal), value_kind = u32(output.Condition_Value_Kind.Integer), integer = value}
	return transmute([size_of(output.Condition_Terms)]u8)terms
}

// refusals_case: the refusals of the root service, with source and filter
// started and not wired.
@(private = "file")
refusals_case :: proc "contextless" (source, filter: system.Handle) {
	before := budget_pages()
	// 1. Two sources of merge.sources of two records: Probe fixes it at
	// the row 1, and Other at the row 2 differs by its name.
	{
		handles := [1]u32{lend(source)}
		rows := [2]output.Wiring{row(.Started, 1, SOURCE_LEFT, .Child, 0, MERGE_SOURCES), row(.Started, 1, SOURCE_OTHER, .Child, 0, MERGE_SOURCES)}
		list_write(rows[:], handles[:])
		status, answer := start_listed("merge", true)
		refused("a second source of merge.sources of another record", before, status, answer, .Bad_Operation, fail(.Start, .Bad_Value, .Record_Types, 0, i64(output.Description_Difference.Name), 0, 2))
	}
	// 2. filter.kept before any wiring of filter.source fixed its type.
	{
		handles := [1]u32{lend(filter)}
		rows := [1]output.Wiring{row(.Started, 1, FILTER_KEPT, .Asker, 0, 0)}
		list_write(rows[:], handles[:])
		status, answer := root_call(.Wire, {0 = u64(root_ring.Wire_Step.Apply)})
		refused("a Wire of filter.kept with no fixed type", before, status, answer, .Bad_Operation, fail(.Wire, .Bad_Value, .Record_Types, 0, i64(output.Description_Difference.Not_Fixed), 0, 1))
	}
	// 3. A condition on merge.merged that names no field of Probe: the
	// row 3 is resolved after the rows that fix the type of
	// merge.sources, against Probe.
	{
		handles := [1]u32{lend(source)}
		rows := [3]output.Wiring{row(.Started, 1, SOURCE_LEFT, .Child, 0, MERGE_SOURCES), row(.Started, 1, SOURCE_RIGHT, .Child, 0, MERGE_SOURCES), row(.Child, 0, MERGE_MERGED, .Asker, 0, 0)}
		rows[2].condition_offset = u32(output.wiring_terms_start(len(rows), len(handles)))
		rows[2].condition_count = size_of(output.Condition_Terms)
		no_field := mark_terms(PROBE_FIELDS + 1, 1)
		list_write(rows[:], handles[:], no_field[:])
		status, answer := start_listed("merge", true)
		refused("a condition on merge.merged that names no field", before, status, answer, .Bad_Operation, fail(.Start, .Bad_Value, .Wiring_Terms, i64(output.Condition_Terms_Field.Field), PROBE_FIELDS + 1, PROBE_FIELDS, 3))
	}
	// 4. One wiring past those that an asker holds: nine sources.
	{
		handles := [1]u32{lend(source)}
		rows: [output.WIRINGS_OF_AN_ASKER_MOST + 1]output.Wiring
		for &each in rows {
			each = row(.Started, 1, SOURCE_LEFT, .Child, 0, MERGE_SOURCES)
		}
		list_write(rows[:], handles[:])
		status, answer := start_listed("merge", true)
		refused("one source past the wirings of an asker", before, status, answer, .No_Slot, fail(.Start, .Full, .Wirings, 0, output.WIRINGS_OF_AN_ASKER_MOST + 1, output.WIRINGS_OF_AN_ASKER_MOST))
	}
	system.log(.Info, "generic_wiring: a second source of another record, a generic output with no fixed type, a condition on no field and one source past the wirings of an asker: refused, each with its status and its error record and the budget unchanged: as it must")
}

// chain_case: source.left and source.right to merge, merge to filter with
// the terms mark = 1, and filter to this process, in one start list.
@(private = "file")
chain_case :: proc "contextless" (source, filter: system.Handle) {
	handles := [2]u32{lend(filter), lend(source)}
	// filter.kept first: the rows reach their processes in this order, so
	// filter holds its reader before its first record.
	rows := [4]output.Wiring {
		row(.Started, 1, FILTER_KEPT, .Asker, 0, 0),
		row(.Started, 2, SOURCE_LEFT, .Child, 0, MERGE_SOURCES),
		row(.Started, 2, SOURCE_RIGHT, .Child, 0, MERGE_SOURCES),
		row(.Child, 0, MERGE_MERGED, .Started, 1, FILTER_SOURCE),
	}
	rows[3].terms_offset = u32(output.wiring_terms_start(len(rows), len(handles)))
	rows[3].terms_count = size_of(output.Condition_Terms)
	terms := mark_terms(PROBE_FIELD_MARK, 1)
	list_write(rows[:], handles[:], terms[:])
	status, answer := start_listed("merge", true)
	if status != .Ok || answer[0] == 0 || answer[1] == 0 {
		wrong_refused("the start of merge with the chain gave the status", status, answer)
	}
	merge := system.Handle(answer[0])
	number := u32(answer[1])
	probe: Probe
	item, read_status := system.asker_read(number, &probe, hang_deadline())
	if read_status != .Ok || item.kind != .Joined || item.serial != 0 {
		wrong("the first compartment of filter.kept is not the joined record of 0; the status word", u64(read_status))
	}
	// Each probe of mark 1 of each side, once, in the order of its side.
	// The two sides interleave in any order: merge reads its rings in
	// turn, and promises no order across them.
	next_of_side := [3]u64{0, 1, 1}
	kept := u32(0)
	for {
		item, read_status = system.asker_read(number, &probe, hang_deadline())
		if read_status == .Ended {
			break
		}
		if read_status != .Ok || item.kind != .Record || item.serial != kept || probe.side < 1 || probe.side > 2 || probe.mark != 1 || probe.number != next_of_side[probe.side] {
			system.log(.Error, "generic_wiring: WRONG: filter.kept gave the status word ", u64(read_status), ", the kind word ", u64(item.kind), ", the serial ", u64(item.serial), " and the probe of the side ", probe.side, ", number ", probe.number, ", mark ", probe.mark, "; wanted the serial ", u64(kept))
			system.stop(.Failed)
		}
		next_of_side[probe.side] += 2
		kept += 1
	}
	if item.end_word != .None || item.error != {} || kept != PROBES_OF_A_SIDE {
		system.log(.Error, "generic_wiring: WRONG: filter.kept ended with the end word ", u64(item.end_word), " and the error kind ", item.error.kind, " after ", u64(kept), " records; wanted a clean end record after ", u64(PROBES_OF_A_SIDE))
		system.stop(.Failed)
	}
	processes := [3]system.Handle{source, merge, filter}
	done_wait(processes[:])
	for process in processes {
		system.close(process)
	}
	system.log(.Info, "generic_wiring: generic_source to merge to filter with mark = 1 to this asker, in one start list: the joined record of 0, the ", u64(kept), " probes of mark 1 of the two sides, each side in its order, then a clean end: as it must")
}

// no_field_case: filter with the terms of the field 0 ends kept at once
// with the error record of that field, whatever its source writes.
@(private = "file")
no_field_case :: proc "contextless" () {
	source := start_child("generic_source")
	handles := [1]u32{lend(source)}
	rows := [2]output.Wiring{row(.Child, 0, FILTER_KEPT, .Asker, 0, 0), row(.Started, 1, SOURCE_LEFT, .Child, 0, FILTER_SOURCE)}
	rows[1].terms_offset = u32(output.wiring_terms_start(len(rows), len(handles)))
	rows[1].terms_count = size_of(output.Condition_Terms)
	terms := mark_terms(0, 1)
	list_write(rows[:], handles[:], terms[:])
	status, answer := start_listed("filter", true)
	if status != .Ok || answer[0] == 0 || answer[1] == 0 {
		wrong_refused("the start of filter with the field 0 gave the status", status, answer)
	}
	filter := system.Handle(answer[0])
	number := u32(answer[1])
	probe: Probe
	joined, joined_status := system.asker_read(number, &probe, hang_deadline())
	ended, ended_status := system.asker_read(number, &probe, hang_deadline())
	wanted := errors.error_make(.Bad_Value, .Wiring_Terms, i64(output.Condition_Terms_Field.Field), 0, PROBE_FIELDS)
	if joined_status != .Ok || joined.kind != .Joined || joined.serial != 0 || ended_status != .Ended || ended.end_word != .None || ended.error != wanted {
		system.log(.Error, "generic_wiring: WRONG: filter with the field 0: the joined status word ", u64(joined_status), ", the end status word ", u64(ended_status), ", the end word ", u64(ended.end_word), ", the error kind ", ended.error.kind, ", unit ", ended.error.unit, ", argument ", ended.error.argument, ", value ", ended.error.value, ", limit ", ended.error.limit)
		system.stop(.Failed)
	}
	// generic_source waits for a reader of right, which this case never
	// gives: the stop of the principal ends it.
	packed := system.name_pack("generic_source")
	if stop_status, stop_answer := root_call(.Stop, {packed[0], packed[1], packed[2], packed[3], 0, 0, 0}); stop_status != .Ok {
		wrong_refused("the stop of generic_source gave the status", stop_status, stop_answer)
	}
	stopped_wait(source)
	done := [1]system.Handle{filter}
	done_wait(done[:])
	system.close(source)
	system.close(filter)
	system.log(.Info, "generic_wiring: filter with a condition on the field 0 ended kept at once with the error record of that field: as it must")
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
	source := start_child("generic_source")
	filter := start_child("filter")
	refusals_case(source, filter)
	chain_case(source, filter)
	no_field_case()
	system.log(.Info, "generic_wiring: ok, after ", u64(refusals), " refusals")
	system.stop(.Done)
}
