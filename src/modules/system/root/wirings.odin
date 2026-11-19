package root

// The wirings of this service (src/md/features/module_outputs.md, "The
// wiring and its rights"; src/md/features/module_outputs.md, "The wiring
// list of a start"; src/md/features/module_outputs.md, "The budget"):
// the command Wire, the wiring list of a Start, the wiring pages of each
// asker, and the end of each wiring at a stop and at a revocation.
//
// The order of the work of a list is a rule, so that a list is whole or
// refused:
//
// 1. The copy and the border: the memory of the list, proved to come
//    through the root ring, is copied once, then output.wiring_list_check
//    takes the copy.
// 2. The lent handles: each one is proved to come through the root ring,
//    then named by the process slot and the process serial of its process.
// 3. The rows: each end, the rule of the asker, the indexes in the module
//    files, the type check, the terms, the count One, the room of each
//    wiring ring. No step before this one changes anything.
// 4. The making: each ring, each terms page and each wiring record, from
//    the budget of the asker. A refusal ends what this step made.
// 5. The delivery: the ends of the child go into the start, and the other
//    ends into the wiring rings of the running processes and the root ring
//    of the asker. For a Start, the delivery to the running processes
//    comes after the start of the child.

import "base:intrinsics"
import "modus:contract/errors"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:support/system"

// One wiring, as this service keeps it in a wiring page of its asker. Free
// when ring_memory is 0.
Wiring_Kept :: struct {
	ring_memory:     system.Handle, // The output ring, as this service holds it.
	number:          u32, // The number of the wiring: the tag of its commands in the wiring rings.
	writer_index:    u32, // The record output of the writer.
	reader_index:    u32, // The record input of the reader; 0 for the asker.
	reader_is_asker: bool,
	reserved:        [7]u8,
	head:            ^ring.Head, // The head page of the ring, mapped in this service: the end words.
	writer:          ^Started,
	reader:          ^Started, // The asker, for a reader Asker.
	padding:         [16]u8,
}
#assert(size_of(Wiring_Kept) == 64)

WIRING_PAGE_RECORDS :: 63

// One wiring page of an asker: a page of its budget, mapped in this
// service alone. The pages of an asker are a chain.
Wiring_Page :: struct {
	next:     ^Wiring_Page,
	memory:   system.Handle,
	count:    u32, // The wiring records in use.
	reserved: [48]u8,
	records:  [WIRING_PAGE_RECORDS]Wiring_Kept,
}
#assert(size_of(Wiring_Page) == system.PAGE_SIZE)

// The number of the next wiring. 0 names no wiring.
wiring_number_next: u32 = 1

// The private copy of the memory of a list: the asker can change the lent
// bytes at any time, so this service reads them once.
wiring_list_copy: [output.WIRING_LIST_BYTES_MOST]u8

// What the work of one row resolved and made.
Wiring_Plan :: struct {
	row:            output.Checked_Wiring,
	writer:         ^Started,
	reader:         ^Started, // The asker for a reader Asker.
	writer_file:    []u8,
	description:    u32, // The record description of the record output, in the file of the writer.
	record_size:    u32,
	terms_size:     u32, // The size of the description of the terms of the record input; 0: it takes none.
	ring_memory:    system.Handle,
	terms_memory:   system.Handle,
	kept:           ^Wiring_Kept,
	page:           ^Wiring_Page,
	number:         u32,
	asker_ring:     system.Handle, // A reader Asker: the ring, as the asker names it.
}

// The work of one list: its rows, its lent processes, and what the start
// of a child gives it.
Wiring_Work :: struct {
	asker:      ^Started,
	command:    root_ring.Root_Command, // Wire or Start: the operation of its error records.
	form:       output.Wiring_List_Form,
	list:       output.Checked_Wiring_List,
	lent:       [output.WIRING_LIST_HANDLE_LIMIT]^Started, // The process of each lent handle.
	plans:      [output.WIRING_LIST_ROW_LIMIT]Wiring_Plan,
	child:      ^Started, // A Start: the place of the child, before it runs.
	child_file: []u8,
	child_ends: [output.WIRING_LIST_ROW_LIMIT]output.Given_End,
	child_end_count: int,
	refusal:    [7]u64, // The error record of a refusal, with the operation of the command.
}

// wiring_refuse keeps the error record of a refusal and gives its status.
@(private = "file")
wiring_refuse :: proc "contextless" (work: ^Wiring_Work, status: system.Status, kind: errors.Kind, unit: errors.Unit, argument: i64 = 0, value: i64 = 0, limit: i64 = 0, found: i64 = 0) -> system.Status {
	work.refusal = errors.ring_fail(u32(work.command), kind, unit, argument, value, limit, found)
	return status
}

// lent_handle_proved says if a handle came through the root ring of the
// asker. Only such a handle is read, and closed at the end of the command:
// a number that the asker did not give names a handle of this service.
@(private = "file")
lent_handle_proved :: proc "contextless" (asker: ^Started, handle: u32, kind: op.Object_Kind) -> bool {
	if handle == 0 {
		return false
	}
	found, _, through := system.handle_state(system.Handle(handle), asker.requests_memory)
	return through && found == kind
}

// process_of_lent_handle gives the process of the table that a proved
// process handle names: the one whose process slot and process serial
// the kernel gives for both handles.
@(private = "file")
process_of_lent_handle :: proc "contextless" (handle: system.Handle) -> ^Started {
	lent, lent_status := system.call(.Process_State, u64(handle))
	if lent_status != .Ok {
		return nil
	}
	for &item in started {
		if item.process == 0 {
			continue
		}
		known, known_status := system.call(.Process_State, u64(item.process))
		if known_status == .Ok && known[3] == lent[3] && known[4] == lent[4] {
			return &item
		}
	}
	return nil
}

// wiring_list_take copies the memory of a list that the asker lent, proves
// each lent handle and names its process, then closes the proved handles.
// It refuses a memory that did not come through the root ring, a memory
// past WIRING_LIST_PAGES_MOST, each refusal of output.wiring_list_check,
// and a lent handle that did not come through the ring or that names no
// process of the table.
wiring_list_take :: proc "contextless" (work: ^Wiring_Work, memory_word: u64) -> system.Status {
	asker := work.asker
	list_argument: i64 = work.command == .Wire ? 1 : 2
	if memory_word > u64(max(u32)) || !lent_handle_proved(asker, u32(memory_word), .Memory) {
		return wiring_refuse(work, .Bad_Handle, .Handle_Absent, .Lent_Handles, list_argument, i64(min(memory_word, 1 << 62)))
	}
	memory := system.Handle(memory_word)
	defer system.close(memory)
	pages, size_status := system.memory_size(memory)
	if size_status != .Ok || pages == 0 || pages > output.WIRING_LIST_PAGES_MOST {
		return wiring_refuse(work, .Bad_Operation, .Too_Long, .Pages, list_argument, i64(min(pages, 1 << 62)), output.WIRING_LIST_PAGES_MOST)
	}
	address, map_status := system.memory_map(memory, {})
	if map_status != .Ok {
		return wiring_refuse(work, map_status, .Refused, .None, list_argument, 0, 0, i64(map_status))
	}
	size := int(pages) * system.PAGE_SIZE
	intrinsics.mem_copy_non_overlapping(&wiring_list_copy[0], address, size)
	system.memory_unmap(address)
	refusal, ok := output.wiring_list_check(wiring_list_copy[:size], work.form, &work.list)
	if !ok {
		refusal.operation = i64(work.command)
		work.refusal = errors.completion_values(refusal)
		return .Bad_Operation
	}
	// Each lent handle is proved before any is closed: a refused one is
	// never closed, as it can be a handle of this service.
	for place in 0 ..< work.list.handle_count {
		handle := work.list.handles[place]
		if !lent_handle_proved(asker, handle, .Process) {
			// The handles proved before this one came from the asker:
			// this service does not keep them.
			for before in 0 ..< place {
				system.close(system.Handle(work.list.handles[before]))
			}
			return wiring_refuse(work, .Bad_Handle, .Handle_Absent, .Lent_Handles, list_argument, i64(place) + 1)
		}
	}
	status := system.Status.Ok
	for place in 0 ..< work.list.handle_count {
		handle := system.Handle(work.list.handles[place])
		work.lent[place] = process_of_lent_handle(handle)
		system.close(handle)
		if work.lent[place] == nil && status == .Ok {
			status = wiring_refuse(work, .Bad_Handle, .Handle_Absent, .Lent_Handles, list_argument, i64(place) + 1)
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
	description, _ := module.record_stream_type(plan.writer_file, plan.description)
	plan.record_size = description.size
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
				if kept.ring_memory != 0 && kept.reader == reader && !kept.reader_is_asker && kept.reader_index == index {
					return true
				}
			}
		}
	}
	return false
}

// wiring_room_check refuses a list whose ends do not fit the wiring ring
// of a running process: this service never waits for a process that does
// not read its wiring ring.
@(private = "file")
wiring_room_check :: proc "contextless" (work: ^Wiring_Work) -> system.Status {
	for number in 1 ..= work.list.row_count {
		plan := &work.plans[number - 1]
		// The asker receives its end on its root ring, not a wiring ring.
		reader: ^Started
		if plan.row.reader_end != .Asker {
			reader = plan.reader
		}
		ends := [2]^Started{plan.writer, reader}
		for process in ends {
			if process == nil || process == work.child {
				continue
			}
			needed: u32
			for other in 1 ..= work.list.row_count {
				other_plan := &work.plans[other - 1]
				if other_plan.writer == process {
					needed += 1
				}
				if other_plan.row.reader_end != .Asker && other_plan.reader == process {
					needed += 1
				}
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

// wiring_list_resolve is step 3 for each row, then the counts of the rows
// whose reader is the asker, and the room of the wiring rings.
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
	return wiring_room_check(work)
}

// wiring_record_take gives a free wiring record of the asker, and makes a
// new wiring page from its budget when its pages are full.
@(private = "file")
wiring_record_take :: proc "contextless" (asker: ^Started, error: ^errors.Error_Record) -> (kept: ^Wiring_Kept, page: ^Wiring_Page, status: system.Status) {
	for page = asker.wiring_pages; page != nil; page = page.next {
		if page.count == WIRING_PAGE_RECORDS {
			continue
		}
		for &record in page.records {
			if record.ring_memory == 0 {
				return &record, page, .Ok
			}
		}
	}
	memory := system.memory_create(1, asker.budget, error = error) or_return
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

// wiring_list_make is step 4: each ring, each terms page and each wiring
// record, from the budget of the asker. A refusal ends what it made.
wiring_list_make :: proc "contextless" (work: ^Wiring_Work) -> system.Status {
	asker := work.asker
	if asker.budget == 0 {
		return wiring_refuse(work, .No_Budget, .Budget_Hidden, .Pages)
	}
	for number in 1 ..= work.list.row_count {
		plan := &work.plans[number - 1]
		error: errors.Error_Record
		status := wiring_plan_make(work, plan, &error)
		if status != .Ok {
			error.operation = i64(work.command)
			work.refusal = errors.completion_values(error)
			wiring_list_unmake(work)
			return status
		}
	}
	return .Ok
}

@(private = "file")
wiring_plan_make :: proc "contextless" (work: ^Wiring_Work, plan: ^Wiring_Plan, error: ^errors.Error_Record) -> system.Status {
	asker := work.asker
	compartment := output.compartment_size(plan.record_size)
	pages := ring.compartment_pages(plan.row.capacity, compartment)
	plan.ring_memory = system.memory_create(pages, asker.budget, error = error) or_return
	head, map_status := system.memory_map(plan.ring_memory, {.Write}, 0, 0, 0, 1, error)
	if map_status != .Ok {
		return map_status
	}
	if plan.row.terms_count != 0 {
		plan.terms_memory = system.memory_create(1, asker.budget, error = error) or_return
		terms, terms_status := system.memory_map(plan.terms_memory, {.Write}, error = error)
		if terms_status != .Ok {
			system.memory_unmap(head)
			return terms_status
		}
		intrinsics.mem_copy_non_overlapping(terms, &wiring_list_copy[plan.row.terms_offset], int(plan.row.terms_count))
		system.memory_unmap(terms)
	}
	kept, page, status := wiring_record_take(asker, error)
	if status != .Ok {
		system.memory_unmap(head)
		return status
	}
	plan.number = wiring_number_next
	wiring_number_next = wiring_number_next == max(u32) ? 1 : wiring_number_next + 1
	kept^ = {
		ring_memory     = plan.ring_memory,
		number          = plan.number,
		writer_index    = plan.row.writer_index,
		reader_index    = plan.row.reader_index,
		reader_is_asker = plan.row.reader_end == .Asker,
		head            = (^ring.Head)(head),
		writer          = plan.writer,
		reader          = plan.reader,
	}
	page.count += 1
	plan.kept, plan.page = kept, page
	return .Ok
}

// wiring_list_unmake ends what wiring_list_make made, before any end
// reached a process: nothing to write in the end words.
wiring_list_unmake :: proc "contextless" (work: ^Wiring_Work) {
	for number in 1 ..= work.list.row_count {
		plan := &work.plans[number - 1]
		if plan.kept != nil {
			system.memory_unmap(plan.kept.head)
			wiring_page_release(work.asker, plan.page, plan.kept)
			plan.kept, plan.page = nil, nil
		}
		if plan.ring_memory != 0 {
			system.close(plan.ring_memory)
			plan.ring_memory = 0
		}
		if plan.terms_memory != 0 {
			system.close(plan.terms_memory)
			plan.terms_memory = 0
		}
	}
}

// wiring_child_ends gives the ends of the child, for system.process_start:
// each with the handles of this service, which the start gives through
// the wiring ring of the child.
wiring_child_ends :: proc "contextless" (work: ^Wiring_Work) -> []output.Given_End {
	work.child_end_count = 0
	for number in 1 ..= work.list.row_count {
		plan := &work.plans[number - 1]
		if plan.writer == work.child {
			work.child_ends[work.child_end_count] = {command = .Writer_End, tag = plan.number, ring = plan.ring_memory, index = plan.row.writer_index, pace = plan.row.pace}
			work.child_end_count += 1
		}
		if plan.row.reader_end == .Child {
			work.child_ends[work.child_end_count] = {command = .Reader_End, tag = plan.number, ring = plan.ring_memory, index = plan.row.reader_index, terms = plan.terms_memory}
			work.child_end_count += 1
		}
	}
	return work.child_ends[:work.child_end_count]
}

// wiring_end_give gives one end to a running process through its wiring
// ring: the handles through the memory of the ring, then the command.
@(private = "file")
wiring_end_give :: proc "contextless" (process: ^Started, end: output.Given_End) -> system.Status {
	given := end
	status: system.Status
	given.ring, status = system.give(process.wiring_memory, end.ring, {.Read, .Write})
	if status == .Ok && end.terms != 0 {
		given.terms, status = system.give(process.wiring_memory, end.terms, {.Read})
	}
	if status != .Ok {
		return status
	}
	// wiring_room_check found the room, and only this service writes the
	// queue.
	if !system.send(&process.wiring.commands, output.given_end_record(given)) {
		return .No_Slot
	}
	return .Ok
}

// wiring_list_deliver is step 5 for the ends that are not the child's:
// the wiring rings of the running processes, and the root ring of the
// asker for a reader Asker. An end that does not reach its process ends
// its wiring with the end word Refused, and a line: the other side then
// reads the end at once.
wiring_list_deliver :: proc "contextless" (work: ^Wiring_Work) {
	asker := work.asker
	for number in 1 ..= work.list.row_count {
		plan := &work.plans[number - 1]
		status := system.Status.Ok
		if plan.writer != work.child {
			status = wiring_end_give(plan.writer, {command = .Writer_End, tag = plan.number, ring = plan.ring_memory, index = plan.row.writer_index, pace = plan.row.pace})
		}
		if status == .Ok {
			switch plan.row.reader_end {
			case .Asker:
				plan.asker_ring, status = system.give(asker.requests_memory, plan.ring_memory, {.Read, .Write})
			case .Started, .Connected:
				status = wiring_end_give(plan.reader, {command = .Reader_End, tag = plan.number, ring = plan.ring_memory, index = plan.row.reader_index, terms = plan.terms_memory})
			case .Child, .None:
			}
		}
		// The reader holds its own handle of the terms.
		if plan.terms_memory != 0 {
			system.close(plan.terms_memory)
			plan.terms_memory = 0
		}
		if status != .Ok {
			system.log(.Warning, "root: the wiring ", u64(plan.number), " of ", system.Module_Name{system.name_of(asker.name[:])}, " did not reach its process: status ", status, "; it ends")
			wiring_end(asker, plan.page, plan.kept, .Refused)
			plan.kept = nil
		}
	}
	asker.granted += {.Wirings}
}

// wiring_end ends one wiring: the end words, a wake of both sides, the
// unmap of the head page, the close of the handle of this service, and
// the record. The memory of the ring ends with the last end that a side
// holds.
wiring_end :: proc "contextless" (asker: ^Started, page: ^Wiring_Page, kept: ^Wiring_Kept, end: output.End_Word) {
	if kept.head != nil {
		// The stop cause and the stop outcome of a writer that stopped come
		// with the record of the stop of the process
		// (src/md/api/process_stop.md); until then their words are 0.
		output.end_words_write(kept.head, end)
		system.word_wake(&kept.head.commands.write, system.WAKE_ALL)
		system.word_wake(&kept.head.commands.read, system.WAKE_ALL)
		system.memory_unmap(kept.head)
	}
	system.close(kept.ring_memory)
	wiring_page_release(asker, page, kept)
}

// wirings_at_stop ends each wiring that names a process that stops: as
// its writer, Writer_Stopped; as its reader, Reader_Stopped; as its asker,
// Asker_Stopped. Then it closes the wiring ring and the budget handle of
// the process.
wirings_at_stop :: proc "contextless" (item: ^Started) {
	// The end of the last record of a page unmaps the page: each end is
	// found again from the start of the chains, never read in a page that
	// an end freed.
	for {
		asker, page, kept, end := wiring_of_a_stop(item)
		if kept == nil {
			break
		}
		wiring_end(asker, page, kept, end)
	}
	if item.wiring.head != nil {
		system.ring_close(&item.wiring)
	}
	if item.wiring_memory != 0 {
		system.close(item.wiring_memory)
		item.wiring_memory = 0
	}
	if item.budget != 0 {
		system.close(item.budget)
		item.budget = 0
	}
}

// wiring_of_a_stop gives the first wiring that names a process that stops,
// and its end word: Writer_Stopped as its writer, Reader_Stopped as its
// reader, Asker_Stopped as its asker. nil: none is left.
@(private = "file")
wiring_of_a_stop :: proc "contextless" (item: ^Started) -> (asker: ^Started, page: ^Wiring_Page, kept: ^Wiring_Kept, end: output.End_Word) {
	for &each in started {
		for each_page := each.wiring_pages; each_page != nil; each_page = each_page.next {
			for &record in each_page.records {
				if record.ring_memory == 0 {
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
			if kept.ring_memory == 0 {
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
// process: a refused end, or a completion that its border refuses, ends
// the wiring of its tag with the end word Refused.
wiring_completions_read :: proc "contextless" (item: ^Started) {
	for _ in 0 ..< system.records_of_turn(&item.wiring.completions) {
		record := system.receive(&item.wiring.completions) or_break
		status, tag, _, ok := output.wiring_completion_of_record(record)
		if ok && status == .Ok {
			continue
		}
		if !ok {
			system.log(.Warning, "root: ", system.Module_Name{system.name_of(item.name[:])}, " wrote a completion of its wiring ring that names no status: its wiring ", u64(record.tag), " ends")
			tag = record.tag
		} else {
			system.log(.Info, "root: ", system.Module_Name{system.name_of(item.name[:])}, " refused its end of the wiring ", u64(tag), " with ", status, ": the wiring ends")
		}
		wiring_end_by_number(item, tag)
	}
}

// wiring_end_by_number ends the wiring of a number whose writer or reader
// is a process, with the end word Refused. A number of a wiring of another
// process is not ended: a process ends only its own wirings so.
@(private = "file")
wiring_end_by_number :: proc "contextless" (item: ^Started, number: u32) {
	for &asker in started {
		for page := asker.wiring_pages; page != nil; page = page.next {
			for &kept in page.records {
				if kept.ring_memory != 0 && kept.number == number && (kept.writer == item || kept.reader == item) {
					wiring_end(&asker, page, &kept, .Refused)
					return
				}
			}
		}
	}
}

// wire runs the command Wire: a list of one row, checked, resolved, made
// and delivered. values is its completion, or its error record.
wire :: proc "contextless" (asker: ^Started, record: ring.Record, values: ^[7]u64) -> system.Status {
	work := &wire_work
	work^ = {asker = asker, command = .Wire, form = .Wire}
	for index in 1 ..< len(record.values) {
		if record.values[index] != 0 {
			values^ = root_ring.word_refusal(.Wire, i64(index) + 1, record.values[index], 0)
			return .Bad_Operation
		}
	}
	status := wiring_list_take(work, record.values[0])
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
		values^ = errors.ring_fail(u32(root_ring.Root_Command.Wire), .Refused, .Wirings, 0, 0, 0, i64(system.Status.Bad_State))
		return .Bad_State
	}
	hash := transmute([4]u64)plan.writer.hash
	values^ = {u64(plan.asker_ring), u64(plan.number), u64(plan.description), hash[0], hash[1], hash[2], hash[3]}
	system.log(.Info, "root: wired the record output ", u64(plan.row.writer_index), " of ", system.Module_Name{system.name_of(plan.writer.name[:])}, " to ", plan.row.reader_end == .Asker ? "its asker " : "", system.Module_Name{system.name_of(plan.reader.name[:])}, ", wiring ", u64(plan.number))
	return .Ok
}

// The work of the command that runs: one command at a time, in the loop
// of this service. It is large, so it is not on the stack.
wire_work: Wiring_Work
