package console

import "modus:contract/blake3"
import module "modus:contract/module"
import "modus:contract/output"
import "modus:contract/root_ring"
import "modus:private/console/console_condition"
import "modus:private/console/console_results"
import "modus:private/console/console_stream"
import "modus:support/sentence"
import "modus:support/system"
import "base:intrinsics"

// The streams of the console (src/md/features/module_outputs.md, "The
// console form"; docs/CONSOLE.md, "Streams").
//
// A typed name, `owner.output`, names a record output of a process that
// the console started, or of a service that it connected. It gives a value
// of the kind Stream, which holds no wiring: the first command that reads
// it (`first`, `table`, or the draw at the end of the line) sends Wire to
// the root service, with this console as the asker and the reader. Each
// Stream that a line wired ends with the line: the console closes its end.
//
// The thread that runs the lines owns this state; the thread of the keys
// reads the owners only to color a name and to complete it.

// The processes that the console started and whose module declares a
// record output: the console keeps their process handles, with Read and
// Give, as the ends Started of a wiring.
STREAM_OWNER_CAPACITY :: 8
// The Streams of one line, and the conditions of each one.
LINE_STREAM_CAPACITY :: 8
STREAM_CONDITION_CAPACITY :: 4
// How long the console waits for the answer of the root service to Wire.
WIRE_ANSWER_LIMIT :: 3000

// The owner of a typed name: a process that the console started, or a
// service that it connected.
Stream_Owner :: struct {
	name:    string, // The name of the module in the boot image.
	process: system.Handle, // 0: the place is free.
	file:    []u8, // Its module file in the boot image, checked once.
	end:     output.Wiring_End, // Started or Connected.
}

stream_owners: [STREAM_OWNER_CAPACITY]Stream_Owner

// One Stream of the line that runs.
Line_Stream :: struct {
	owner:           string,
	output_name:     string,
	process:         system.Handle, // The handle of the owner: the console keeps it, the Stream does not.
	end:             output.Wiring_End,
	index:           u32, // The record output, from 1, in the module file of the owner.
	file:            []u8,
	detail:          u32, // The record description, in file.
	size:            int, // The bytes of one record.
	conditions:      [STREAM_CONDITION_CAPACITY]^Condition,
	condition_items: [STREAM_CONDITION_CAPACITY]module.Field,
	condition_count: int,
	number:          u32, // The wiring that the root service gave; 0: not wired.
	closed:          bool,
}

line_streams: [LINE_STREAM_CAPACITY]Line_Stream
line_stream_count: int

// The list page of the root service: the console writes the row of each
// Wire in it (src/md/features/module_outputs.md, "The wiring and its
// rights").
list_page: []u8

// image_module_file gives the module file of a name in the boot image,
// after it checked its hash and its form, as connect does.
image_module_file :: proc "contextless" (name: string) -> (file: []u8, image_name: string, found: bool) {
	for &entry in system.image_entries(image) {
		if system.name_of(entry.name[:]) != name || entry.offset > u64(len(image)) || entry.size > u64(len(image)) - entry.offset {
			continue
		}
		bytes := image[entry.offset:][:entry.size]
		if blake3.hash(bytes) != entry.hash || module.validate(bytes) != .None {
			return nil, "", false
		}
		return bytes, system.name_of(entry.name[:]), true
	}
	return nil, "", false
}

// stream_owner_keep keeps the process handle of a process that the console
// started, when its module declares a record output; else it closes the
// handle. false: the table of the owners is full, and the handle is closed.
stream_owner_keep :: proc "contextless" (name: string, process: system.Handle) -> bool {
	file, image_name, found := image_module_file(name)
	if !found || console_stream.record_output_count(file) == 0 {
		system.close(process)
		return true
	}
	stream_owners_check()
	for &owner in stream_owners {
		if owner.process == 0 {
			owner = {name = image_name, process = process, file = file, end = .Started}
			return true
		}
	}
	system.close(process)
	return false
}

// stream_owners_check closes the handle of each started process that
// stopped: its typed names end with it.
stream_owners_check :: proc "contextless" () {
	for &owner in stream_owners {
		if owner.process == 0 {
			continue
		}
		if state, _, _ := system.process_state(owner.process); state == .Stopped {
			system.close(owner.process)
			owner = {}
		}
	}
}

// stream_owner_find gives the owner of a name: a started process first,
// then a connected service.
stream_owner_find :: proc "contextless" (name: string) -> (owner: Stream_Owner, found: bool) {
	for item in stream_owners {
		if item.process != 0 && item.name == name {
			return item, true
		}
	}
	for &sandbox in sandboxes {
		if !sandbox.service || sandbox.quiet || sandbox.process == 0 || sandbox.name != name {
			continue
		}
		// connect checked the hash and the form of this file.
		entry := system.image_entry_of(image, sandbox.hash)
		if entry == nil || entry.offset > u64(len(image)) || entry.size > u64(len(image)) - entry.offset {
			continue
		}
		return {name = sandbox.name, process = sandbox.process, file = image[entry.offset:][:entry.size], end = .Connected}, true
	}
	return {}, false
}

// stream_owner_named says if a name is the name of an owner of typed names.
stream_owner_named :: proc "contextless" (name: string) -> bool {
	for item in stream_owners {
		if item.process != 0 && item.name == name {
			return true
		}
	}
	return false
}

// stream_name_known gives the record description of a typed name, with no
// failure and no Stream: the colors of a line, the completion and the
// check of a condition before the run read it.
stream_name_known :: proc "contextless" (name: string) -> (file: []u8, detail: u32, known: bool) {
	owner_name, output_name := console_stream.typed_name_split(name) or_return
	owner := stream_owner_find(owner_name) or_return
	_, record, found := console_stream.record_output_find(owner.file, output_name)
	if found != .Found {
		return nil, 0, false
	}
	return owner.file, record, true
}

// stream_value_of_name gives the Stream of a typed name. named is false
// when the first part names no owner: the name is then no typed name, and
// the parser says so. A name whose owner exists and that names no record
// output of it fails the line, with the names that it declares.
stream_value_of_name :: proc "contextless" (name: string) -> (value: Value, named: bool) {
	owner_name, output_name, split := console_stream.typed_name_split(name)
	if !split {
		return {}, false
	}
	owner, found := stream_owner_find(owner_name)
	if !found {
		return {}, false
	}
	index, record, how := console_stream.record_output_find(owner.file, output_name)
	switch how {
	case .Found:
	case .Absent:
		if console_stream.record_output_count(owner.file) == 0 {
			return fail(owner_name, " declares no record output"), true
		}
		writer := sentence.Writer {
			buffer = scratch[scratch_count:],
		}
		console_stream.record_output_names_write(&writer, owner.file)
		names := sentence.written(&writer)
		scratch_count += len(names)
		return fail(owner_name, " declares no record output ", output_name, "; its record outputs are ", names), true
	case .Generic:
		return fail(name, " is a generic record output: its record comes with its wiring, and the console reads a record output of a record only"), true
	case .Damaged:
		return fail("the module file of ", owner_name, " has a row of its record outputs that the module contract refuses"), true
	}
	if line_stream_count >= LINE_STREAM_CAPACITY {
		return fail("a line reads at most ", u64(LINE_STREAM_CAPACITY), " streams"), true
	}
	described, described_ok := module.record_type(owner.file, record)
	if !described_ok || described.size == 0 {
		return fail("the record of ", name, " has no valid description"), true
	}
	line_streams[line_stream_count] = {
		owner       = owner.name,
		output_name = output_name,
		process     = owner.process,
		end         = owner.end,
		index       = index,
		file        = owner.file,
		detail      = record,
		size        = int(described.size),
	}
	line_stream_count += 1
	return {kind = .Stream, file = owner.file, detail = record, integer = i64(line_stream_count - 1)}, true
}

// line_stream_of gives the Stream of a value of the line, or nil.
line_stream_of :: proc "contextless" (value: Value) -> ^Line_Stream {
	if value.kind != .Stream || value.integer < 0 || value.integer >= i64(line_stream_count) {
		return nil
	}
	return &line_streams[value.integer]
}

// stream_where adds a condition to a Stream, and gives the same Stream: no
// record is read yet. condition_read checked the field and the value
// against the record description of the Stream.
stream_where :: proc "contextless" (value: Value, condition: ^Condition) -> Value {
	stream := line_stream_of(value)
	if stream == nil {
		return fail("where: the Stream is not one of this line")
	}
	if stream.number != 0 {
		return fail("where: the Stream is read already")
	}
	if stream.condition_count >= STREAM_CONDITION_CAPACITY {
		return fail("where: a Stream takes at most ", u64(STREAM_CONDITION_CAPACITY), " conditions")
	}
	described, _ := module.record_type(stream.file, stream.detail)
	item, found := console_condition.field_find(stream.file, described, condition.field)
	if !found {
		return fail("where: the records of the Stream have no field ", condition.field)
	}
	stream.conditions[stream.condition_count] = condition
	stream.condition_items[stream.condition_count] = item
	stream.condition_count += 1
	return value
}

// stream_passes says if a record passes each condition of its Stream.
stream_passes :: proc "contextless" (stream: ^Line_Stream, row: []u8) -> bool {
	for index in 0 ..< stream.condition_count {
		field_value, _ := console_condition.field_value_of(row, stream.condition_items[index])
		if !console_condition.condition_holds(field_value, stream.conditions[index]^) {
			return false
		}
	}
	return true
}

// list_page_ready asks the root service for its list page once, maps it,
// and takes the wiring ring that comes with it: the console declares no
// record stream, so its context holds no wiring ring.
list_page_ready :: proc "contextless" () -> bool {
	if list_page != nil {
		return true
	}
	completion, answered := disk_request(.Wire, {0 = u64(root_ring.Wire_Step.List_Page)}, WIRE_ANSWER_LIMIT)
	if !answered {
		fail_no_answer()
		return false
	}
	if status, _ := system.status_of_word(completion.kind); status != .Ok {
		fail_root("the list page of the root service: ", completion)
		return false
	}
	page := system.Handle(completion.values[0])
	address, map_status := system.memory_map(page)
	pages, _ := system.memory_size(page)
	if map_status != .Ok || pages * system.PAGE_SIZE < output.WIRING_LIST_BYTES_MOST {
		fail("the list page of the root service does not map: ", map_status)
		return false
	}
	if completion.values[1] != 0 {
		if taken := system.wiring_ring_take(system.Handle(completion.values[1])); taken != .Ok {
			fail("the wiring ring of the root service does not open: ", taken)
			return false
		}
	}
	list_page = ([^]u8)(address)[:output.WIRING_LIST_BYTES_MOST]
	return true
}

// stream_wire wires the record output of a Stream to this console, as its
// asker, once: Wire with one row from the owner to the asker. The pace is
// the choice of the writer, and the ring has the default capacity.
stream_wire :: proc "contextless" (stream: ^Line_Stream) -> bool {
	if stream.number != 0 {
		return true
	}
	if stream.closed {
		fail("the Stream ", stream.owner, ".", stream.output_name, " ended already")
		return false
	}
	if !list_page_ready() {
		return false
	}
	// The process handle goes to the root service through its ring, which
	// is how it proves the handle (src/md/features/module_outputs.md, "How
	// the root service names a lent handle").
	lent, give_status := system.give(requests_memory, stream.process, {.Read})
	if give_status != .Ok {
		fail("the console cannot lend the handle of ", stream.owner, " to the root service: ", give_status)
		return false
	}
	rows := [1]output.Wiring {
		{
			writer_end = u32(stream.end),
			writer_handle = 1,
			writer_stream = u32(output.Writer_Stream.Record_Output),
			writer_index = stream.index,
			reader_end = u32(output.Wiring_End.Asker),
		},
	}
	handles := [1]u32{u32(lent)}
	for &value in list_page {
		value = 0
	}
	if !output.wiring_list_write(list_page, rows[:], handles[:]) {
		fail("the row of the wiring does not fit the list page")
		return false
	}
	completion, answered := disk_request(.Wire, {0 = u64(root_ring.Wire_Step.Apply)}, WIRE_ANSWER_LIMIT)
	if !answered {
		fail_no_answer()
		return false
	}
	if status, _ := system.status_of_word(completion.kind); status != .Ok {
		fail_root(scratch_text("cannot read ", stream.owner, ".", stream.output_name, ": "), completion)
		return false
	}
	stream.number = u32(completion.values[0])
	return true
}

// stream_close closes the end of a Stream that the line wired: the writer
// reads the end word Side_Closed. A Stream that ended by its end record or
// its end word holds no end any more, and asker_close finds none.
stream_close :: proc "contextless" (stream: ^Line_Stream) {
	if stream.number != 0 && !stream.closed {
		system.asker_close(stream.number)
	}
	stream.closed = true
}

// line_streams_end closes each Stream of the line: a Stream lives for one
// line.
line_streams_end :: proc "contextless" () {
	for &stream in line_streams[:line_stream_count] {
		stream_close(&stream)
	}
}

// stream_read_next reads the next compartment of a wired Stream into row.
// escaped: Escape ended the wait: the read waits on the word that Escape
// changes beside the words of its ring.
stream_read_next :: proc "contextless" (stream: ^Line_Stream, row: []u8) -> (item: system.Input_Item, status: output.Stream_Status, escaped: bool) {
	item, status = system.asker_read_bytes(stream.number, row, system.WAIT_FOREVER, &work.cancel, 0)
	if status == .No_Record && intrinsics.atomic_load(&work.cancel) != 0 {
		return item, status, true
	}
	return item, status, false
}

// stream_refused fails the line with the refusal of a compartment, or of
// the counters of its ring.
stream_refused :: proc "contextless" (command: string, stream: ^Line_Stream, item: system.Input_Item) {
	already := failed
	fail(command, ": the console refused a record of ", stream.owner, ".", stream.output_name, ", and closed the stream")
	if !already {
		failure_record_set(item.refusal, "output.record_of_compartment", nil)
	}
}

// stream_collect reads the rows of a Stream that pass its conditions into
// a Table of the line: first(s, n) with its count, table(s) until the end.
stream_collect :: proc "contextless" (command: string, value: Value, wanted: int) -> Value {
	stream := line_stream_of(value)
	if stream == nil {
		return fail(command, ": the Stream is not one of this line")
	}
	start := min((table_used + 7) &~ 7, len(table_memory))
	capacity := len(table_memory) - start
	if wanted == console_stream.TABLE_ROWS_WANTED_ALL {
		capacity = min(capacity, TABLE_KEPT)
	}
	kept := 0
	// A count of 0 reads no record, and wires nothing.
	if console_stream.collect_step_of(kept, wanted, stream.size, capacity) == .Done {
		return {kind = .Table, record = table_memory[start:start], file = stream.file, detail = stream.detail}
	}
	if !stream_wire(stream) {
		return {}
	}
	intrinsics.atomic_store(&work.call_stoppable, 1)
	defer intrinsics.atomic_store(&work.call_stoppable, 0)
	read: for {
		switch console_stream.collect_step_of(kept, wanted, stream.size, capacity) {
		case .Keep:
		case .Done:
			break read
		case .Too_Large:
			stream_close(stream)
			if wanted == console_stream.TABLE_ROWS_WANTED_ALL {
				writer := sentence.Writer {
					buffer = scratch[scratch_count:],
				}
				console_stream.table_too_large_write(&writer, kept, capacity)
				text := sentence.written(&writer)
				scratch_count += len(text)
				return fail(text)
			}
			return fail(command, ": the line has no room for more than ", u64(kept), " rows")
		}
		// The record goes in the place of the next row; a record that does
		// not pass is written over by the next one.
		row := table_memory[start + kept * stream.size:][:stream.size]
		item, status, escaped := stream_read_next(stream, row)
		if escaped {
			stream_close(stream)
			return fail(command, ": Escape closed the stream after ", u64(kept), kept == 1 ? " row" : " rows")
		}
		switch status {
		case .Ok:
			if item.kind == .Record && stream_passes(stream, row) {
				kept += 1
			}
		case .Ended:
			break read
		case .Bad_Record:
			stream_refused(command, stream, item)
			return {}
		case .No_Writer:
			stream_close(stream)
			return fail(command, ": the console holds no end of the wiring of ", stream.owner, ".", stream.output_name)
		case .No_Reader, .Full, .No_Record:
			// A read gives none of these, but No_Record after Escape.
		}
	}
	stream_close(stream)
	table_used = start + kept * stream.size
	return {kind = .Table, record = table_memory[start:table_used], file = stream.file, detail = stream.detail}
}

// stream_table gives the rows of a Stream until its end.
stream_table :: proc "contextless" (arguments: []Value) -> Value {
	if arguments[0].kind == .Table {
		return arguments[0]
	}
	return stream_collect("table", arguments[0], console_stream.TABLE_ROWS_WANTED_ALL)
}

// stream_note_draw draws one note of a Stream: its joined record, a gap,
// its end, Escape. A joined record of 0 draws nothing.
stream_note_draw :: proc "contextless" (note: console_stream.Note) {
	buffer: [160]u8
	writer := sentence.Writer {
		buffer = buffer[:],
	}
	if !console_stream.note_write(&writer, note) {
		return
	}
	system.lock(&output_lock)
	defer system.unlock(&output_lock)
	sink := result_sink()
	console_results.draw_note(&sink, sentence.written(&writer))
	output_continuation = 0
}

// stream_draw draws a Stream at the end of a line: the head of its
// columns, then each record that passes its conditions as it comes, until
// the end of the stream or Escape. The output lock is held for one line at
// a time, never while the read waits: the thread of the keys draws its
// line meanwhile.
stream_draw :: proc "contextless" (value: Value) {
	stream := line_stream_of(value)
	if stream == nil {
		fail("the Stream is not one of this line")
		return
	}
	columns, columns_ok := console_results.stream_columns_of(stream.file, stream.detail)
	if !columns_ok {
		fail("the Stream ", stream.owner, ".", stream.output_name, " has no valid description")
		return
	}
	if !stream_wire(stream) {
		return
	}
	{
		system.lock(&output_lock)
		defer system.unlock(&output_lock)
		sink := result_sink()
		console_results.draw_stream_head(&sink, &columns, stream.file)
		output_continuation = 0
	}
	intrinsics.atomic_store(&work.call_stoppable, 1)
	defer intrinsics.atomic_store(&work.call_stoppable, 0)
	row: [module.RECORD_SIZE_LIMIT]u8
	drawn: u64
	read: for {
		item, status, escaped := stream_read_next(stream, row[:stream.size])
		if escaped {
			stream_note_draw({kind = .Escape, count = drawn})
			break read
		}
		switch status {
		case .Ok:
			switch item.kind {
			case .Record:
				if stream_passes(stream, row[:stream.size]) {
					system.lock(&output_lock)
					sink := result_sink()
					console_results.draw_stream_row(&sink, &columns, row[:stream.size])
					output_continuation = 0
					system.unlock(&output_lock)
					drawn += 1
				}
			case .Joined:
				stream_note_draw({kind = .Joined, count = u64(item.serial)})
			case .Gap:
				stream_note_draw({kind = .Gap, count = u64(item.gap_count)})
			case .End:
				// An end comes with the status Ended.
			}
		case .Ended:
			switch {
			case item.end_word != .None:
				stream_note_draw({kind = .Ended_By, end_word = item.end_word})
			case item.error.kind == 0:
				stream_note_draw({kind = .Clean_End, count = u64(item.serial)})
			case:
				stream_note_draw({kind = .Error_End, count = u64(item.serial)})
			}
			break read
		case .Bad_Record:
			stream_refused("the draw", stream, item)
			break read
		case .No_Writer:
			fail("the console holds no end of the wiring of ", stream.owner, ".", stream.output_name)
			break read
		case .No_Reader, .Full, .No_Record:
			// A read gives none of these, but No_Record after Escape.
		}
	}
	stream_close(stream)
}

// record_outputs gives one row for each record output that a module of the
// boot image declares.
record_outputs :: proc "contextless" (arguments: []Value) -> Value {
	name := arguments[0].text
	file, _, found := image_module_file(name)
	if !found {
		return fail("record_outputs: no module of the boot image has the name ", name)
	}
	columns := [3]Column{text_column("output", 32), text_column("record", 32), text_column("about", 96)}
	table, made := made_table("Record_Output", columns[:])
	if !made {
		return fail("record_outputs: the line has no room for the description")
	}
	for index in 1 ..= console_stream.record_output_count(file) {
		value, _, _, ok := module.record_output(file, index)
		if !ok {
			return fail("record_outputs: the module file of ", name, " has a row of its record outputs that the module contract refuses")
		}
		record_name := "any record" // A generic record output: its record comes with its wiring.
		if value.record != 0 {
			described, _ := module.record_type(file, value.record)
			record_name = module.string_at(file, described.name_offset, described.name_count)
		}
		row := made_row(&table)
		made_text(&table, row, 0, module.string_at(file, value.name_offset, value.name_count))
		made_text(&table, row, 1, record_name)
		made_text(&table, row, 2, module.string_at(file, value.about_offset, value.about_count))
	}
	return made_value(&table, "record_outputs")
}
