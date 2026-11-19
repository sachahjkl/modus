package root

// The wirings of this service: the command Wire, the wiring list of a
// Start, the list page and the wiring pages of each asker, and the end of
// each wiring at a stop and at a revocation
// (src/md/features/module_outputs.md, "The wiring and its rights").
//
// The order of the work of a list is a rule, so that a list is whole or
// refused:
//
// 1. The copy and the border: this service maps its own handle of the
//    list page of the asker, copies it, unmaps it, and output.
//    wiring_list_check takes the copy. A revocation by the asker reaches
//    only its own handle, never the mapping of this service.
// 2. The lent handles: each one is proved to come through the root ring,
//    named by the process slot and the process serial of its process, and
//    closed. Each refusal closes each number that the proof accepted.
// 3. The rows: each end, the rule of the asker, the indexes in the module
//    files, the type check, the terms, the count One, the limits of the
//    asker and of each process, the room of each wiring ring. No step
//    before this one changes anything.
// 4. The making: each ring, each end page, each terms page, each
//    description file and each wiring record, from the budget of the asker.
//    A refusal ends what this step made.
// 5. The delivery: the ends of the child go into the start, and the other
//    ends into the wiring ring of each process, the asker too. For a
//    Start, the delivery comes after the whole start of the child.
//
// What this service holds, at the limits of this file
// (src/md/features/module_outputs.md, "The budget"):
//
// - each wiring that runs: one handle, of its end page, and no mapping. It
//   maps the end page only to write the end words.
// - each asker that took a list page, LIST_PAGE_ASKERS_MOST of them: the
//   handles of its budget, its list page and its wiring ring, and the
//   mapping of its wiring ring; while it has a wiring that runs, the
//   handle and the mapping of its wiring page too. That is 4 handles and
//   2 mappings for each asker.
// - each process with a record stream: the handle and the mapping of its
//   wiring ring.
// - one command: at most output.WIRING_LIST_HANDLE_LIMIT lent handles,
//   closed before the command ends.
//
// The list page and the wiring ring of an asker stay until it stops: the
// asker holds its own handle of each, and its library its mapping of the
// wiring ring, so a page that this service gave back would leave the
// asker a ring that no command reaches. LIST_PAGE_ASKERS_MOST bounds them.

import "base:intrinsics"
import "modus:contract/errors"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:support/system"

// The ends that one process holds at one time: the table of the library
// (system.STREAM_END_CAPACITY).
ENDS_OF_A_PROCESS_MOST :: 16
// The ends of one service that one asker holds through its connections:
// each asker that wires a service has a share of its ends, so that two
// askers alone cannot take the ends of a service from each other asker.
CONNECTED_ENDS_OF_AN_ASKER_MOST :: 4
// The wirings of the whole machine at one time: the handle table of this
// service holds 128 handles, as each process, and the processes that it
// starts take most of them.
WIRINGS_OF_THE_MACHINE_MOST :: 24
// The askers that hold a list page at one time: each one costs this
// service 4 handles and 2 mappings until it stops.
LIST_PAGE_ASKERS_MOST :: 4
#assert(LIST_PAGE_ASKERS_MOST * CONNECTED_ENDS_OF_AN_ASKER_MOST <= ENDS_OF_A_PROCESS_MOST)

// One wiring, as this service keeps it in a wiring page of its asker. Free
// when end_memory is 0.
Wiring_Kept :: struct {
	end_memory:      system.Handle, // The end page, which this service alone writes.
	number:          u32, // The number of the wiring: the tag of its ends. No two wirings that run have one number.
	writer_index:    u32, // The record output of the writer.
	reader_index:    u32, // The record input of the reader; 0 for the asker.
	reader_is_asker: bool,
	writer_counted:  bool, // The writer holds its end: one end of its count.
	reader_counted:  bool,
	writer_answered: bool, // The writer answered the command of its end: a later answer is dropped.
	reader_answered: bool,
	writer_closed:   bool, // The writer said Closed: a later word is dropped.
	reader_closed:   bool,
	asked_counted:   bool, // The wiring is one of the count of its asker.
	writer:          ^Started,
	reader:          ^Started, // The asker, for a reader Asker.
	dropped_told:    bool, // The line of a dropped word of this wiring is written: one line for each wiring.
	padding:         [23]u8,
}
#assert(size_of(Wiring_Kept) == 64)

WIRING_PAGE_RECORDS :: 63

// One wiring page of an asker: a page of its budget, mapped in this
// service alone. With output.WIRINGS_OF_AN_ASKER_MOST, an asker has one
// page.
Wiring_Page :: struct {
	next:     ^Wiring_Page,
	memory:   system.Handle,
	count:    u32, // The wiring records in use.
	reserved: [48]u8,
	records:  [WIRING_PAGE_RECORDS]Wiring_Kept,
}
#assert(size_of(Wiring_Page) == system.PAGE_SIZE)
#assert(output.WIRINGS_OF_AN_ASKER_MOST <= WIRING_PAGE_RECORDS)

// The number of the next wiring, and the wirings that run.
wiring_number_next: u32 = 1
wirings_running: int

// The private copy of a list page, and of a description file before it
// goes into its page.
wiring_list_copy: [output.WIRING_LIST_BYTES_MOST]u8
description_copy: [output.DESCRIPTION_FILE_BYTES_MOST]u8

// What the work of one row resolved and made.
Wiring_Plan :: struct {
	row:                output.Checked_Wiring,
	writer:             ^Started,
	reader:             ^Started, // The asker for a reader Asker.
	writer_file:        []u8,
	description:        u32, // The record description of the record output, in the file of the writer.
	terms_size:         u32, // The size of the description of the terms of the record input; 0: it takes none.
	ring_memory:        system.Handle,
	end_memory:         system.Handle,
	terms_memory:       system.Handle,
	description_memory: system.Handle,
	kept:               ^Wiring_Kept,
	page:               ^Wiring_Page,
	number:             u32,
}

// The work of one list.
Wiring_Work :: struct {
	asker:           ^Started,
	command:         root_ring.Root_Command, // Wire or Start: the operation of its error records.
	form:            output.Wiring_List_Form,
	list:            output.Checked_Wiring_List,
	lent:            [output.WIRING_LIST_HANDLE_LIMIT]^Started, // The process of each lent handle.
	plans:           [output.WIRING_LIST_ROW_LIMIT]Wiring_Plan,
	child:           ^Started, // A Start: the place of the child, before it runs.
	child_file:      []u8,
	child_ends:      [output.WIRING_LIST_ROW_LIMIT]output.Given_End,
	child_end_count: int,
	refusal:         [7]u64, // The error record of a refusal, with the operation of the command.
}

// The work of the command that runs: one command at a time, in the loop
// of this service. It is large, so it is not on the stack.
wire_work: Wiring_Work

// wiring_refuse keeps the error record of a refusal and gives its status.
@(private = "file")
wiring_refuse :: proc "contextless" (work: ^Wiring_Work, status: system.Status, kind: errors.Kind, unit: errors.Unit, argument: i64 = 0, value: i64 = 0, limit: i64 = 0, found: i64 = 0) -> system.Status {
	work.refusal = errors.ring_fail(u32(work.command), kind, unit, argument, value, limit, found)
	return status
}

// lent_handle_of gives the kind of the object of a lent number, and says
// if the handle came through the root ring of the asker. Only such a
// handle is read and closed: a number that the asker did not give names a
// handle of this service.
@(private = "file")
lent_handle_of :: proc "contextless" (asker: ^Started, handle: u32) -> (kind: op.Object_Kind, through: bool) {
	if handle == 0 {
		return {}, false
	}
	kind, _, through = system.handle_state(system.Handle(handle), asker.requests_memory)
	return kind, through
}

// process_of_lent_handle gives the process of the table that a proved
// process handle names: the one whose process slot and process serial
// the kernel gives for both handles.
@(private = "file")
process_of_lent_handle :: proc "contextless" (handle: system.Handle) -> ^Started {
	// The slot and the serial name one process, and never a later one in
	// the same slot.
	lent_slot, lent_serial, lent_status := system.process_place(handle)
	if lent_status != .Ok {
		return nil
	}
	for &item in started {
		if item.process == 0 {
			continue
		}
		slot, serial, status := system.process_place(item.process)
		if status == .Ok && slot == lent_slot && serial == lent_serial {
			return &item
		}
	}
	return nil
}

// list_page_copy copies the list page of the asker into wiring_list_copy,
// from the handle of this service. false: the asker has no list page, or
// this service cannot map it.
@(private = "file")
list_page_copy :: proc "contextless" (asker: ^Started) -> bool {
	if asker.list_memory == 0 {
		return false
	}
	address, status := system.memory_map(asker.list_memory, {})
	if status != .Ok {
		return false
	}
	intrinsics.mem_copy_non_overlapping(&wiring_list_copy[0], address, output.WIRING_LIST_BYTES_MOST)
	system.memory_unmap(address)
	return true
}

// lent_handles_close closes each lent number of the list that came
// through the root ring of the asker, whatever the kind of its object, on
// a refusal before the lent handles are read: the asker gave them to this
// service for the command, which keeps none. copied says that
// wiring_list_copy holds the list of this command already; else the list
// page is copied first. A head whose counts do not fit names no number,
// and nothing is closed then.
lent_handles_close :: proc "contextless" (asker: ^Started, copied := false) {
	if !copied && !list_page_copy(asker) {
		return
	}
	head: output.Wiring_List_Head
	intrinsics.mem_copy_non_overlapping(&head, &wiring_list_copy[0], size_of(head))
	if head.row_count > output.WIRING_LIST_ROW_LIMIT || head.handle_count > output.WIRING_LIST_HANDLE_LIMIT {
		return
	}
	first := size_of(output.Wiring_List_Head) + int(head.row_count) * size_of(output.Wiring)
	for place in 0 ..< int(head.handle_count) {
		word: u32
		intrinsics.mem_copy_non_overlapping(&word, &wiring_list_copy[first + place * size_of(u32)], size_of(u32))
		// A number twice is closed once: the second proof fails.
		if _, through := lent_handle_of(asker, word); through {
			system.close(system.Handle(word))
		}
	}
}

// list_page_give runs Wire with List_Page: the list page of the asker,
// made once from its budget, and a wiring ring for an asker that has none,
// as the ends of the rows whose reader it is come there. values[0] is the
// list page, values[1] the wiring ring, or 0 when the asker has its
// wiring ring at the handle 16 of its context.
list_page_give :: proc "contextless" (asker: ^Started, values: ^[7]u64) -> system.Status {
	command := u32(root_ring.Root_Command.Wire)
	if asker.budget == 0 {
		values^ = errors.ring_fail(command, .Budget_Hidden, .Pages)
		return .No_Budget
	}
	error: errors.Error_Record
	made_page, made_ring: bool
	if asker.list_memory == 0 {
		holders := 0
		for &item in started {
			if item.process != 0 && item.list_memory != 0 {
				holders += 1
			}
		}
		if holders >= LIST_PAGE_ASKERS_MOST {
			values^ = errors.ring_fail(command, .Full, .Wirings, 0, i64(holders + 1), LIST_PAGE_ASKERS_MOST)
			return .No_Slot
		}
		memory, status := system.memory_create(output.WIRING_LIST_PAGES_MOST, asker.budget, error = &error)
		if status != .Ok {
			error.operation = i64(command)
			values^ = errors.completion_values(error)
			return status
		}
		asker.list_memory = memory
		made_page = true
	}
	ring_given: system.Handle
	if asker.wiring.head == nil {
		memory, status := system.memory_create(ring.pages(output.WIRING_RING_CAPACITY), asker.budget, error = &error)
		if status == .Ok {
			asker.wiring, status = system.ring_open(memory)
			if status != .Ok {
				system.close(memory)
			} else {
				asker.wiring_memory = memory
				made_ring = true
				ring_given, status = system.give(asker.requests_memory, memory, {.Read, .Write})
			}
		}
		if status != .Ok {
			list_page_unmake(asker, made_page, made_ring)
			error.operation = i64(command)
			values^ = errors.completion_values(error)
			return status
		}
	}
	page_given, status := system.give(asker.requests_memory, asker.list_memory, {.Read, .Write})
	if status != .Ok {
		list_page_unmake(asker, made_page, made_ring)
		values^ = errors.ring_fail(command, .Refused, .Wirings, 0, 0, 0, i64(status))
		return status
	}
	values^ = {u64(page_given), u64(ring_given), 0, 0, 0, 0, 0}
	return .Ok
}

// list_page_unmake ends what a refused List_Page made.
@(private = "file")
list_page_unmake :: proc "contextless" (asker: ^Started, made_page, made_ring: bool) {
	if made_ring {
		system.ring_close(&asker.wiring)
		system.close(asker.wiring_memory)
		asker.wiring_memory = 0
	}
	if made_page {
		system.close(asker.list_memory)
		asker.list_memory = 0
	}
}

// wiring_list_take copies the list page of the asker, checks the copy,
// and then, in one pass, proves each lent handle, names the process of a
// process handle and closes each handle that came through the root ring,
// whatever its kind: the command keeps none. The first number that fails
// gives the refusal: one that did not come through the ring, then one of
// another kind than Process, then one that names no process of the table.
wiring_list_take :: proc "contextless" (work: ^Wiring_Work) -> system.Status {
	asker := work.asker
	if !list_page_copy(asker) {
		return wiring_refuse(work, .Bad_State, .Absent, .Wirings)
	}
	refusal, ok := output.wiring_list_check(wiring_list_copy[:], work.form, &work.list)
	if !ok {
		lent_handles_close(asker, copied = true)
		refusal.operation = i64(work.command)
		work.refusal = errors.completion_values(refusal)
		return .Bad_Operation
	}
	status := system.Status.Ok
	for place in 0 ..< work.list.handle_count {
		number := work.list.handles[place]
		handle := system.Handle(number)
		kind, through := lent_handle_of(asker, number)
		if through {
			if kind == .Process {
				work.lent[place] = process_of_lent_handle(handle)
			}
			system.close(handle)
		}
		if status != .Ok {
			continue
		}
		switch {
		case !through:
			status = wiring_refuse(work, .Bad_Handle, .Handle_Absent, .Lent_Handles, 0, i64(place) + 1)
		case kind != .Process:
			status = wiring_refuse(work, .Bad_Handle, .Handle_Kind, .Lent_Handles, 0, i64(place) + 1, i64(op.Object_Kind.Process), i64(kind))
		case work.lent[place] == nil:
			status = wiring_refuse(work, .Bad_Handle, .Handle_Absent, .Lent_Handles, 0, i64(place) + 1)
		}
	}
	return status
}

// end_process gives the process of one end: the child, a lent process, or
// the asker.
@(private = "file")
end_process :: proc "contextless" (work: ^Wiring_Work, end: output.Wiring_End, place: u32) -> ^Started {
	switch end {
	case .Child:
		return work.child
	case .Started, .Connected:
		return work.lent[place - 1]
	case .Asker:
		return work.asker
	case .None:
	}
	return nil
}

// end_allowed is the rule of the asker for one end: a Started end is a
// process whose start the asker asked for; a Connected end a service to
// which it holds a connection, for which it acts for the principal.
@(private = "file")
end_allowed :: proc "contextless" (work: ^Wiring_Work, end: output.Wiring_End, process: ^Started) -> bool {
	asker := work.asker
	switch end {
	case .Child, .Asker:
		return true
	case .Started:
		return process.asker == asker || (.Start_Policy in asker.role.grants && process.asked_by_start_policy)
	case .Connected:
		if .Acts_For_Principal not_in grants_held(asker) || process.service.head == nil {
			return false
		}
		for &connection in connections {
			if connection.caller == asker && connection.service == process && !connection.history && connection.client.place == 0 {
				return true
			}
		}
		return false
	case .None:
	}
	return false
}

// wiring_row_resolve is step 3 for one row: it changes nothing.
@(private = "file")
wiring_row_resolve :: proc "contextless" (work: ^Wiring_Work, number: u32) -> system.Status {
	plan := &work.plans[number - 1]
	row := plan.row
	found := i64(number)
	plan.writer = end_process(work, row.writer_end, row.writer_handle)
	plan.reader = end_process(work, row.reader_end, row.reader_handle)
	if plan.writer == nil || plan.reader == nil {
		return wiring_refuse(work, .Bad_Handle, .Handle_Absent, .Lent_Handles, 0, 0, 0, found)
	}
	if !end_allowed(work, row.writer_end, plan.writer) || !end_allowed(work, row.reader_end, plan.reader) {
		return wiring_refuse(work, .No_Right, .No_Grant, .Wirings, 0, 0, 0, found)
	}
	if plan.writer == plan.reader {
		return wiring_refuse(work, .Bad_State, .Bad_Value, .Wirings, i64(output.Wiring_Field.Reader_End), 0, 0, found)
	}
	// The record output log of the child comes with its own step.
	if row.writer_stream == .Log {
		return wiring_refuse(work, .Bad_Operation, .Unsupported, .Wiring_Rows, i64(output.Wiring_Field.Writer_Stream), i64(output.Writer_Stream.Log), 0, found)
	}
	plan.writer_file = plan.writer == work.child ? work.child_file : plan.writer.file
	if len(plan.writer_file) == 0 {
		return wiring_refuse(work, .Bad_State, .Absent, .Modules, 0, 0, 0, found)
	}
	output_row, _, _, output_ok := module.record_output(plan.writer_file, row.writer_index)
	if !output_ok {
		outputs := max(module.count(plan.writer_file, .Record_Outputs), 1) - 1
		return wiring_refuse(work, .Bad_Operation, .Bad_Value, .Wiring_Rows, i64(output.Wiring_Field.Writer_Index), i64(row.writer_index), i64(outputs), found)
	}
	plan.description = output_row.record
	reader_file := plan.writer_file
	reader_description := plan.description
	if row.reader_end != .Asker {
		reader_file = plan.reader == work.child ? work.child_file : plan.reader.file
		if len(reader_file) == 0 {
			return wiring_refuse(work, .Bad_State, .Absent, .Modules, 0, 0, 0, found)
		}
		input_row, wirings, _, terms, input_ok := module.record_input(reader_file, row.reader_index)
		if !input_ok {
			inputs := max(module.count(reader_file, .Record_Inputs), 1) - 1
			return wiring_refuse(work, .Bad_Operation, .Bad_Value, .Wiring_Rows, i64(output.Wiring_Field.Reader_Index), i64(row.reader_index), i64(inputs), found)
		}
		reader_description = input_row.record
		if input_row.terms != 0 {
			plan.terms_size = terms.size
		}
		// A record input of the count One takes one wiring: in this list
		// and among the wirings that run.
		if wirings == .One && record_input_taken(work, number, plan.reader, row.reader_index) {
			return wiring_refuse(work, .Bad_State, .Exists, .Wirings, i64(output.Wiring_Field.Reader_Index), i64(row.reader_index), 0, found)
		}
	}
	// The type check. A generic end has the description 0, which no
	// wiring fixes before the step of generic record inputs.
	difference, part := output.record_descriptions_compare(plan.writer_file, plan.description, reader_file, reader_description)
	if difference != .Equal {
		return wiring_refuse(work, .Bad_Operation, .Bad_Value, .Record_Types, 0, i64(difference), i64(part), found)
	}
	if row.terms_count != plan.terms_size {
		return wiring_refuse(work, .Bad_Operation, .Bad_Value, .Wiring_Terms, i64(output.Wiring_Field.Terms_Count), i64(row.terms_count), i64(plan.terms_size), found)
	}
	return .Ok
}

// record_input_taken says if a record input of the count One has a
// wiring already: a row before this one in the list, or a wiring that
// runs.
@(private = "file")
record_input_taken :: proc "contextless" (work: ^Wiring_Work, number: u32, reader: ^Started, index: u32) -> bool {
	for before in 1 ..< number {
		plan := &work.plans[before - 1]
		if plan.reader == reader && plan.row.reader_end != .Asker && plan.row.reader_index == index {
			return true
		}
	}
	for &asker in started {
		for page := asker.wiring_pages; page != nil; page = page.next {
			for &kept in page.records {
				if kept.end_memory != 0 && kept.reader == reader && !kept.reader_is_asker && kept.reader_index == index {
					return true
				}
			}
		}
	}
	return false
}

// ends_needed gives the ends that a list gives one process.
@(private = "file")
ends_needed :: proc "contextless" (work: ^Wiring_Work, process: ^Started) -> (needed: u32) {
	for number in 1 ..= work.list.row_count {
		plan := &work.plans[number - 1]
		if plan.writer == process {
			needed += 1
		}
		if plan.reader == process {
			needed += 1
		}
	}
	return needed
}

// asker_ends_in gives the ends that the running wirings of an asker give a
// process now.
@(private = "file")
asker_ends_in :: proc "contextless" (asker: ^Started, process: ^Started) -> (held: int) {
	for page := asker.wiring_pages; page != nil; page = page.next {
		for &kept in page.records {
			if kept.end_memory == 0 {
				continue
			}
			if kept.writer == process && kept.writer_counted {
				held += 1
			}
			if kept.reader == process && kept.reader_counted {
				held += 1
			}
		}
	}
	return held
}

// wiring_limits_check refuses a list past the limits of the asker, of the
// machine and of each process, the ends of a connected service past the
// share of the asker, and a list whose ends do not fit the
// wiring ring of a running process: this service never waits for a
// process that does not read its wiring ring.
@(private = "file")
wiring_limits_check :: proc "contextless" (work: ^Wiring_Work) -> system.Status {
	rows := int(work.list.row_count)
	if work.asker.wirings_asked + rows > output.WIRINGS_OF_AN_ASKER_MOST {
		return wiring_refuse(work, .No_Slot, .Full, .Wirings, 0, i64(work.asker.wirings_asked + rows), output.WIRINGS_OF_AN_ASKER_MOST)
	}
	if wirings_running + rows > WIRINGS_OF_THE_MACHINE_MOST {
		return wiring_refuse(work, .No_Slot, .Full, .Wirings, 0, i64(wirings_running + rows), WIRINGS_OF_THE_MACHINE_MOST)
	}
	for number in 1 ..= work.list.row_count {
		plan := &work.plans[number - 1]
		ends := [2]^Started{plan.writer, plan.reader}
		connected := [2]bool{plan.row.writer_end == .Connected, plan.row.reader_end == .Connected}
		for process, side in ends {
			needed := ends_needed(work, process)
			if process.ends_given + int(needed) > ENDS_OF_A_PROCESS_MOST {
				return wiring_refuse(work, .No_Slot, .Full, .Wirings, 0, i64(process.ends_given + int(needed)), ENDS_OF_A_PROCESS_MOST, i64(number))
			}
			if connected[side] {
				held := asker_ends_in(work.asker, process)
				if held + int(needed) > CONNECTED_ENDS_OF_AN_ASKER_MOST {
					return wiring_refuse(work, .No_Slot, .Full, .Wirings, 0, i64(held + int(needed)), CONNECTED_ENDS_OF_AN_ASKER_MOST, i64(number))
				}
			}
			// The child takes its ends in the start, in a wiring ring of
			// their count.
			if process == work.child {
				continue
			}
			if process.wiring.head == nil {
				return wiring_refuse(work, .Bad_State, .Absent, .Wirings, 0, 0, 0, i64(number))
			}
			commands := &process.wiring.commands
			if ring.capacity(commands) - ring.count(commands) < needed {
				return wiring_refuse(work, .No_Slot, .Busy, .Wirings, 0, i64(needed), i64(ring.capacity(commands)), i64(number))
			}
		}
	}
	return .Ok
}

// wiring_list_resolve is step 3 for each row, then the count of the rows
// whose reader is the asker, and the limits.
wiring_list_resolve :: proc "contextless" (work: ^Wiring_Work) -> system.Status {
	asker_rows := 0
	for number in 1 ..= work.list.row_count {
		work.plans[number - 1] = {row = work.list.rows[number - 1]}
		wiring_row_resolve(work, number) or_return
		if work.plans[number - 1].row.reader_end == .Asker {
			asker_rows += 1
		}
	}
	if work.form == .Start && asker_rows > output.WIRING_ASKER_ROWS_OF_A_START {
		return wiring_refuse(work, .Bad_Operation, .Bad_Value, .Wiring_Rows, i64(output.Wiring_Field.Reader_End), i64(asker_rows), output.WIRING_ASKER_ROWS_OF_A_START)
	}
	return wiring_limits_check(work)
}

// wiring_number_take gives the next number that no running wiring has: a
// number that wraps never names two wirings.
@(private = "file")
wiring_number_take :: proc "contextless" () -> u32 {
	for {
		number := wiring_number_next
		wiring_number_next = wiring_number_next == max(u32) ? 1 : wiring_number_next + 1
		if number != 0 && !wiring_number_running(number) {
			return number
		}
	}
}

@(private = "file")
wiring_number_running :: proc "contextless" (number: u32) -> bool {
	for &asker in started {
		for page := asker.wiring_pages; page != nil; page = page.next {
			for &kept in page.records {
				if kept.end_memory != 0 && kept.number == number {
					return true
				}
			}
		}
	}
	return false
}

// wiring_record_take gives a free wiring record of the asker, and makes a
// wiring page from its budget when it has none with room.
@(private = "file")
wiring_record_take :: proc "contextless" (asker: ^Started, error: ^errors.Error_Record) -> (kept: ^Wiring_Kept, page: ^Wiring_Page, status: system.Status) {
	for page = asker.wiring_pages; page != nil; page = page.next {
		if page.count == WIRING_PAGE_RECORDS {
			continue
		}
		for &record in page.records {
			if record.end_memory == 0 {
				return &record, page, .Ok
			}
		}
	}
	memory: system.Handle
	memory, status = system.memory_create(1, asker.budget, error = error)
	if status != .Ok {
		return nil, nil, status
	}
	address, map_status := system.memory_map(memory)
	if map_status != .Ok {
		system.close(memory)
		return nil, nil, map_status
	}
	page = (^Wiring_Page)(address)
	page^ = {}
	page.memory = memory
	page.next = asker.wiring_pages
	asker.wiring_pages = page
	return &page.records[0], page, .Ok
}

// wiring_page_release frees a wiring record, and gives its page back to
// the budget of the asker when it was the last one.
@(private = "file")
wiring_page_release :: proc "contextless" (asker: ^Started, page: ^Wiring_Page, kept: ^Wiring_Kept) {
	kept^ = {}
	page.count -= 1
	if page.count != 0 {
		return
	}
	if asker.wiring_pages == page {
		asker.wiring_pages = page.next
	} else {
		for before := asker.wiring_pages; before != nil; before = before.next {
			if before.next == page {
				before.next = page.next
				break
			}
		}
	}
	memory := page.memory
	system.memory_unmap(page)
	system.close(memory)
}

// page_write makes a memory object of the bytes from the budget of the
// asker, and writes them in it with one mapping of this service, which it
// ends at once.
@(private = "file")
page_write :: proc "contextless" (asker: ^Started, bytes: []u8, error: ^errors.Error_Record) -> (memory: system.Handle, status: system.Status) {
	pages := u64(max(len(bytes), 1) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	memory = system.memory_create(pages, asker.budget, error = error) or_return
	address, map_status := system.memory_map(memory, {.Write}, error = error)
	if map_status != .Ok {
		system.close(memory)
		return 0, map_status
	}
	if len(bytes) > 0 {
		intrinsics.mem_copy_non_overlapping(address, raw_data(bytes), len(bytes))
	}
	system.memory_unmap(address)
	return memory, .Ok
}

// wiring_list_make is step 4: each ring, each end page, each terms page,
// each description file and each wiring record, from the budget of the
// asker. A refusal ends what it made, and the error record is the one of
// the kernel.
wiring_list_make :: proc "contextless" (work: ^Wiring_Work) -> system.Status {
	if work.asker.budget == 0 {
		return wiring_refuse(work, .No_Budget, .Budget_Hidden, .Pages)
	}
	for number in 1 ..= work.list.row_count {
		error: errors.Error_Record
		status := wiring_plan_make(work, &work.plans[number - 1], &error)
		if status != .Ok {
			error.operation = i64(work.command)
			error.found = i64(number)
			work.refusal = errors.completion_values(error)
			wiring_list_unmake(work)
			return status
		}
	}
	return .Ok
}

// wiring_plan_make makes what one row needs. It maps no memory past its
// own steps: each object that it made is in the plan, so that
// wiring_list_unmake ends it.
@(private = "file")
wiring_plan_make :: proc "contextless" (work: ^Wiring_Work, plan: ^Wiring_Plan, error: ^errors.Error_Record) -> system.Status {
	asker := work.asker
	description, _ := module.record_stream_type(plan.writer_file, plan.description)
	compartment := output.compartment_size(description.size)
	plan.ring_memory = system.memory_create(ring.compartment_pages(plan.row.capacity, compartment), asker.budget, error = error) or_return
	plan.end_memory = system.memory_create(output.END_WORDS_PAGES, asker.budget, error = error) or_return
	if plan.row.terms_count != 0 {
		plan.terms_memory = page_write(asker, wiring_list_copy[plan.row.terms_offset:][:plan.row.terms_count], error) or_return
	}
	size, described := output.description_file_write(description_copy[:], plan.writer_file, plan.description)
	if !described {
		error^ = errors.error_make(.Too_Long, .Bytes, 0, 0, output.DESCRIPTION_FILE_BYTES_MOST)
		return .Bad_Operation
	}
	plan.description_memory = page_write(asker, description_copy[:size], error) or_return
	kept, page, status := wiring_record_take(asker, error)
	if status != .Ok {
		return status
	}
	plan.number = wiring_number_take()
	kept^ = {
		end_memory      = plan.end_memory,
		number          = plan.number,
		writer_index    = plan.row.writer_index,
		reader_index    = plan.row.reader_index,
		reader_is_asker = plan.row.reader_end == .Asker,
		writer          = plan.writer,
		reader          = plan.reader,
	}
	page.count += 1
	wirings_running += 1
	plan.kept, plan.page = kept, page
	return .Ok
}

// wiring_handles_close closes the handles of a plan that this service
// does not keep: the ring, the terms and the description file, which the
// sides hold. The end page stays in the wiring record.
@(private = "file")
wiring_handles_close :: proc "contextless" (plan: ^Wiring_Plan) {
	handles := [3]^system.Handle{&plan.ring_memory, &plan.terms_memory, &plan.description_memory}
	for handle in handles {
		if handle^ != 0 {
			system.close(handle^)
			handle^ = 0
		}
	}
}

// wiring_list_unmake ends what wiring_list_make made, before any end
// reached a running process.
wiring_list_unmake :: proc "contextless" (work: ^Wiring_Work) {
	for number in 1 ..= work.list.row_count {
		plan := &work.plans[number - 1]
		if plan.kept != nil {
			wiring_page_release(work.asker, plan.page, plan.kept)
			wirings_running -= 1
			plan.kept, plan.page = nil, nil
		}
		if plan.end_memory != 0 {
			system.close(plan.end_memory)
			plan.end_memory = 0
		}
		wiring_handles_close(plan)
	}
}

// wiring_end_of_plan gives the end of one side of a plan.
@(private = "file")
wiring_end_of_plan :: proc "contextless" (plan: ^Wiring_Plan, writer: bool) -> output.Given_End {
	if writer {
		return {command = .Writer_End, tag = plan.number, ring = plan.ring_memory, index = plan.row.writer_index, pace = plan.row.pace, end_words = plan.end_memory}
	}
	command := plan.row.reader_end == .Asker ? output.Wiring_Command.Asker_End : output.Wiring_Command.Reader_End
	return {command = command, tag = plan.number, ring = plan.ring_memory, index = plan.row.reader_index, terms = plan.terms_memory, description = plan.description_memory, end_words = plan.end_memory}
}

// wiring_child_ends gives the ends of the child, for system.process_start:
// each with the handles of this service, which the start gives through
// the wiring ring of the child.
wiring_child_ends :: proc "contextless" (work: ^Wiring_Work) -> []output.Given_End {
	work.child_end_count = 0
	for number in 1 ..= work.list.row_count {
		plan := &work.plans[number - 1]
		if plan.writer == work.child {
			work.child_ends[work.child_end_count] = wiring_end_of_plan(plan, true)
			work.child_end_count += 1
		}
		if plan.row.reader_end == .Child {
			work.child_ends[work.child_end_count] = wiring_end_of_plan(plan, false)
			work.child_end_count += 1
		}
	}
	return work.child_ends[:work.child_end_count]
}

// wiring_end_give gives one end to a running process through its wiring
// ring: the handles through the memory of the ring, then the command. On
// a refused gift, each handle that it gave is revoked in that process: a
// handle with no command names nothing that the process can use.
@(private = "file")
wiring_end_give :: proc "contextless" (process: ^Started, end: output.Given_End) -> system.Status {
	given := end
	sources := [4]system.Handle{end.ring, end.end_words, end.terms, end.description}
	rights := [4]system.Rights{{.Read, .Write}, {.Read}, {.Read}, {.Read}}
	results := [4]^system.Handle{&given.ring, &given.end_words, &given.terms, &given.description}
	status := system.Status.Ok
	gifts := 0
	for source, index in sources {
		if source == 0 {
			continue
		}
		results[index]^, status = system.give(process.wiring_memory, source, rights[index])
		if status != .Ok {
			break
		}
		gifts = index + 1
	}
	// wiring_limits_check found the room, and only this service writes the
	// queue.
	if status == .Ok && !system.send(&process.wiring.commands, output.given_end_record(given)) {
		status = .No_Slot
	}
	if status != .Ok {
		for index in 0 ..< gifts {
			if sources[index] != 0 {
				system.handle_revoke(sources[index], process.process)
			}
		}
	}
	return status
}

// wiring_list_deliver is step 5 for the ends that are not the child's.
// An end that does not reach its process ends its wiring with the end
// word Refused, and one line: the other side then reads the end at once.
wiring_list_deliver :: proc "contextless" (work: ^Wiring_Work) {
	asker := work.asker
	for number in 1 ..= work.list.row_count {
		plan := &work.plans[number - 1]
		status := system.Status.Ok
		if plan.writer != work.child {
			status = wiring_end_give(plan.writer, wiring_end_of_plan(plan, true))
		}
		if status == .Ok {
			plan.kept.writer_counted = true
			plan.writer.ends_given += 1
			if plan.row.reader_end != .Child {
				status = wiring_end_give(plan.reader, wiring_end_of_plan(plan, false))
			}
		}
		if status == .Ok {
			plan.kept.reader_counted = true
			plan.reader.ends_given += 1
		}
		// The sides hold their own handles of the ring, the terms and the
		// description file.
		wiring_handles_close(plan)
		if status != .Ok {
			system.log(.Warning, "root: the wiring ", u64(plan.number), " of ", system.Module_Name{system.name_of(asker.name[:])}, " did not reach its process: status ", status, "; it ends")
			wiring_end(asker, plan.page, plan.kept, .Refused)
			plan.kept = nil
			continue
		}
		plan.kept.asked_counted = true
		asker.wirings_asked += 1
		// One line for each wiring, of a Wire as of a Start.
		system.log(.Info, "root: wired the record output ", u64(plan.row.writer_index), " of ", system.Module_Name{system.name_of(plan.writer.name[:])}, " to ", plan.row.reader_end == .Asker ? "its asker " : "", system.Module_Name{system.name_of(plan.reader.name[:])}, ", wiring ", u64(plan.number))
	}
	asker.granted += {.Wirings}
}

// wiring_end ends one wiring: the end words, written with one mapping of
// the end page that ends at once, a wake of each side that waits on the
// end word, the close of the handle of this service, and the record. The
// end word None writes nothing: both sides closed their ends, and no one
// reads the page.
wiring_end :: proc "contextless" (asker: ^Started, page: ^Wiring_Page, kept: ^Wiring_Kept, end: output.End_Word, stop_cause: op.Stop_Cause = .None, stop_outcome: op.Stop_Outcome = .None) {
	if end != .None {
		address, status := system.memory_map(kept.end_memory)
		if status == .Ok {
			words := (^output.End_Words)(address)
			output.end_words_write(words, end, stop_cause, stop_outcome)
			system.word_wake(&words.end, system.WAKE_ALL)
			system.memory_unmap(address)
		} else {
			// The sides then learn the end from the close of the ring by
			// the other side only: one line says it.
			system.log(.Warning, "root: cannot map the end page of the wiring ", u64(kept.number), ": status ", status, "; its end word is not written")
		}
	}
	system.close(kept.end_memory)
	if kept.writer_counted {
		kept.writer.ends_given -= 1
	}
	if kept.reader_counted {
		kept.reader.ends_given -= 1
	}
	if kept.asked_counted {
		asker.wirings_asked -= 1
	}
	wirings_running -= 1
	wiring_page_release(asker, page, kept)
}

// wirings_at_stop ends each wiring that names a process that ends: as its
// reader, Reader_Stopped; as its asker, Asker_Stopped; as its writer,
// Writer_Stopped with its stop cause and its stop outcome when the kernel
// recorded its stop. A process that this service lets go with no stop
// (an abandoned start, a state that the kernel does not give as Stopped)
// gives Revoked, with one line: a reader never reads a stop that did not
// happen. Then it closes the wiring ring, the list page and the budget
// handle of the process.
wirings_at_stop :: proc "contextless" (item: ^Started, state: op.Process_State, stop_cause: op.Stop_Cause, stop_outcome: op.Stop_Outcome) {
	stopped := state == .Stopped && stop_cause != .None
	told := false
	// The end of the last record of a page unmaps the page: each end is
	// found again from the start of the chains, never read in a page that
	// an end freed.
	for {
		asker, page, kept, end := wiring_of_a_stop(item)
		if kept == nil {
			break
		}
		if end != .Writer_Stopped {
			wiring_end(asker, page, kept, end)
		} else if stopped {
			wiring_end(asker, page, kept, end, stop_cause, stop_outcome)
		} else {
			if !told {
				told = true
				system.log(.Warning, "root: ", system.Module_Name{system.name_of(item.name[:])}, " ends with no stop that the kernel recorded, state word ", u64(state), ": its record outputs end as Revoked")
			}
			wiring_end(asker, page, kept, .Revoked)
		}
	}
	if item.wiring.head != nil {
		system.ring_close(&item.wiring)
	}
	handles := [3]^system.Handle{&item.wiring_memory, &item.list_memory, &item.budget}
	for handle in handles {
		if handle^ != 0 {
			system.close(handle^)
			handle^ = 0
		}
	}
	item.ends_given, item.wirings_asked = 0, 0
}

// wiring_of_a_stop gives the first wiring that names a process that stops,
// and its end word. nil: none is left.
@(private = "file")
wiring_of_a_stop :: proc "contextless" (item: ^Started) -> (asker: ^Started, page: ^Wiring_Page, kept: ^Wiring_Kept, end: output.End_Word) {
	for &each in started {
		for each_page := each.wiring_pages; each_page != nil; each_page = each_page.next {
			for &record in each_page.records {
				if record.end_memory == 0 {
					continue
				}
				switch {
				case record.writer == item:
					return &each, each_page, &record, .Writer_Stopped
				case record.reader == item && !record.reader_is_asker:
					return &each, each_page, &record, .Reader_Stopped
				case &each == item:
					return &each, each_page, &record, .Asker_Stopped
				}
			}
		}
	}
	return nil, nil, nil, .None
}

// wirings_revoke ends each wiring that a process asked for, with the end
// word Revoked. count is the count of the wirings that ended.
wirings_revoke :: proc "contextless" (asker: ^Started) -> (count: u64) {
	for asker.wiring_pages != nil {
		page := asker.wiring_pages
		for &kept in page.records {
			if kept.end_memory == 0 {
				continue
			}
			last := page.count == 1
			wiring_end(asker, page, &kept, .Revoked)
			count += 1
			if last {
				break
			}
		}
	}
	return count
}

// wiring_completions_read reads the completions of the wiring ring of a
// process. Each end that this service gave has two words at most:
//
// - its answer, first. A refusal, or a completion that its border refuses,
//   ends the wiring with the end word Refused and one line: the process
//   does not hold that end, and the other side then reads the end at once.
// - the word Closed, after the answer Taken: the count of that side goes
//   back. The wiring ends, with no end word, when its two sides closed.
//
// Each other word is dropped: it ends nothing, as no side holds a command
// that ends a wiring. One line tells the first dropped word of each
// wiring, and one line for each pass counts the words that name no
// wiring of the process.
wiring_completions_read :: proc "contextless" (item: ^Started) {
	unknown: u64
	for _ in 0 ..< system.records_of_turn(&item.wiring.completions) {
		record := system.receive(&item.wiring.completions) or_break
		status, tag, answer, _, ok := output.wiring_completion_of_record(record)
		asker, page, kept := wiring_of_a_side(item, record.tag)
		if kept == nil {
			unknown += 1
			continue
		}
		writer := kept.writer == item
		answered := writer ? &kept.writer_answered : &kept.reader_answered
		closed := writer ? &kept.writer_closed : &kept.reader_closed
		counted := writer ? &kept.writer_counted : &kept.reader_counted
		if counted^ && !answered^ {
			answered^ = true
			if ok && status == .Ok && answer == .Taken {
				continue
			}
			if ok {
				system.log(.Info, "root: ", system.Module_Name{system.name_of(item.name[:])}, " refused its end of the wiring ", u64(tag), " with ", status, ": the wiring ends")
			} else {
				system.log(.Warning, "root: ", system.Module_Name{system.name_of(item.name[:])}, " answered its end of the wiring ", u64(record.tag), " with a completion that names no status or carries values: the wiring ends")
			}
			wiring_end(asker, page, kept, .Refused)
			continue
		}
		if counted^ && !closed^ && ok && status == .Ok && answer == .Closed {
			closed^ = true
			counted^ = false
			item.ends_given -= 1
			if kept.writer_closed && kept.reader_closed {
				wiring_end(asker, page, kept, .None)
			}
			continue
		}
		if !kept.dropped_told {
			kept.dropped_told = true
			system.log(.Warning, "root: ", system.Module_Name{system.name_of(item.name[:])}, " wrote a word of its wiring ring for the wiring ", u64(record.tag), " past the answer and the close of its end: the word is dropped, and so is each later one of that wiring")
		}
	}
	if unknown != 0 {
		system.log(.Warning, "root: ", system.Module_Name{system.name_of(item.name[:])}, " wrote ", unknown, " words of its wiring ring that name no wiring of it: they are dropped")
	}
}

// wiring_of_a_side gives the running wiring of a number whose writer or
// reader is a process. A number of a wiring of another process names
// nothing: a process speaks only of its own ends, and no two running
// wirings have one number.
@(private = "file")
wiring_of_a_side :: proc "contextless" (item: ^Started, number: u32) -> (asker: ^Started, page: ^Wiring_Page, kept: ^Wiring_Kept) {
	for &each in started {
		for each_page := each.wiring_pages; each_page != nil; each_page = each_page.next {
			for &record in each_page.records {
				if record.end_memory != 0 && record.number == number && (record.writer == item || record.reader == item) {
					return &each, each_page, &record
				}
			}
		}
	}
	return nil, nil, nil
}

// wire runs the command Wire. values is its completion, or its error
// record.
wire :: proc "contextless" (asker: ^Started, record: ring.Record, values: ^[7]u64) -> system.Status {
	command := root_ring.Root_Command.Wire
	step, step_ok := root_ring.wire_step_of_word(record.values[0])
	if !step_ok {
		lent_handles_close(asker)
		values^ = root_ring.word_refusal(command, 1, record.values[0], u64(max(root_ring.Wire_Step)))
		return .Bad_Operation
	}
	for index in 1 ..< len(record.values) {
		if record.values[index] != 0 {
			lent_handles_close(asker)
			values^ = root_ring.word_refusal(command, i64(index) + 1, record.values[index], 0)
			return .Bad_Operation
		}
	}
	switch step {
	case .List_Page:
		return list_page_give(asker, values)
	case .Apply:
	case .None:
		// wire_step_of_word refused None; the case keeps the switch whole.
		return .Bad_Operation
	}
	work := &wire_work
	work^ = {asker = asker, command = command, form = .Wire}
	status := wiring_list_take(work)
	if status == .Ok {
		status = wiring_list_resolve(work)
	}
	if status == .Ok {
		status = wiring_list_make(work)
	}
	if status != .Ok {
		values^ = work.refusal
		return status
	}
	wiring_list_deliver(work)
	plan := &work.plans[0]
	if plan.kept == nil {
		// The end did not reach its process: the line says it.
		values^ = errors.ring_fail(u32(command), .Refused, .Wirings, 0, 0, 0, i64(system.Status.Bad_State))
		return .Bad_State
	}
	values^ = {u64(plan.number), 0, 0, 0, 0, 0, 0}
	return .Ok
}
