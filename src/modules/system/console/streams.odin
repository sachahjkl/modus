package console

import "modus:contract/blake3"
import "modus:contract/enum_word"
import "modus:contract/errors"
import module "modus:contract/module"
import "modus:contract/output"
import "modus:contract/root_ring"
import "modus:private/console/console_condition"
import "modus:private/console/console_results"
import "modus:private/console/console_stream"
import "modus:support/sentence"
import "modus:support/system"
import "base:intrinsics"

// The record streams of the console (src/md/features/module_outputs.md,
// "The console form"; docs/CONSOLE.md, "Streams").
//
// A typed name, `owner.name`, names a record output or a record input of a
// process that the console started, of a service that it connected, or of
// a module of the boot image that does not run yet (an owner Planned,
// which only the list of its own start names). A record output gives a
// value of the kind Stream, a record input a value of the kind
// Record_Input; neither holds a wiring. The first command that reads a
// Stream (`first`, `table`, `stream_counts`, or the draw at the end of the
// line) sends Wire to the root service, with this console as the asker
// and the reader, and the first condition of the Stream as the condition
// of the wiring. Each Stream that a line wired ends with the line.
//
// `wire(from, to)` gives the rows of a list as a Table of the console, and
// `start(module, list)` turns them into a wiring list of the contract.
//
// Each command is one function with typed parameters, which parses
// nothing: the commands move as they are to the evaluation host of Lex.
//
// The thread that runs the lines owns this state; the thread of the keys
// reads the owners only to color a name and to complete it, and never
// loads a module file.

// The processes that the console started and whose module declares a
// record output: the console keeps their process handles, with Read and
// Give, as the ends Started of a wiring.
STREAM_OWNER_CAPACITY :: 8
// The module files of the planned owners that the lines read, checked
// once each: the hash of a module file is no work for each key.
PLANNED_FILE_CAPACITY :: 8
// The Streams and the record inputs of one line, and the conditions of
// each Stream.
LINE_STREAM_CAPACITY :: 8
STREAM_CONDITION_CAPACITY :: 4
// How long the console waits for the answer of the root service to Wire
// and to a Start with a list.
WIRE_ANSWER_LIMIT :: 3000

// The owner of a typed name.
Stream_Owner :: struct {
	name:    string, // The name of the module in the boot image.
	process: system.Handle, // Started: the process handle. Connected: the number of the handle of the connection. Planned: 0.
	file:    []u8, // Its module file in the boot image, checked once.
	// Started, Connected, or Child for a module that does not run: the end
	// that it is in the list of its own start.
	end:     output.Wiring_End,
}

stream_owners: [STREAM_OWNER_CAPACITY]Stream_Owner

// One module file of a planned owner, checked once.
Planned_File :: struct {
	name: string,
	file: []u8,
}

planned_files: [PLANNED_FILE_CAPACITY]Planned_File
planned_next: int // The place that the next planned file takes, in turn.

// One Stream or one record input of the line that runs.
Line_Stream :: struct {
	owner:           string,
	stream_name:     string, // The name of the record output or of the record input.
	process:         system.Handle, // The handle or the number of the owner: the console keeps it, the line does not.
	end:             output.Wiring_End,
	is_input:        bool, // A record input: only wire takes it.
	index:           u32, // The record output or the record input, from 1, in the module file of the owner.
	file:            []u8,
	detail:          u32, // The record description, in file: the whole record.
	size:            int, // The bytes of one whole record.
	// The conditions: the first goes with the wiring; the console checks
	// each one on each record, with the one test of the contract.
	conditions:      [STREAM_CONDITION_CAPACITY]Condition,
	terms:           [STREAM_CONDITION_CAPACITY]output.Condition_Terms,
	checks:          [STREAM_CONDITION_CAPACITY]output.Checked_Condition,
	condition_count: int,
	// The fields that columns chose: nil for the whole record.
	projection_file:    []u8,
	projection_columns: [COLUMN_CAPACITY]Column,
	projection_count:   int,
	projection_size:    int,
	number:          u32, // The wiring that the root service gave; 0: not wired.
	closed:          bool,
}

line_streams: [LINE_STREAM_CAPACITY]Line_Stream
line_stream_count: int

// The list page of the root service: the console writes the rows of each
// Wire and of each Start with a list in it
// (src/md/features/module_outputs.md, "The wiring and its rights").
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

// planned_file_of gives the module file of a module of the boot image that
// a line names before it runs. load: the thread of the lines checks a file
// that it has not checked yet; the thread of the keys never does.
planned_file_of :: proc "contextless" (name: string, load: bool) -> (file: []u8, image_name: string, found: bool) {
	for item in planned_files {
		if item.name != "" && item.name == name {
			return item.file, item.name, true
		}
	}
	if !load {
		return nil, "", false
	}
	file, image_name = image_module_file(name) or_return
	planned_files[planned_next] = {name = image_name, file = file}
	planned_next = (planned_next + 1) % PLANNED_FILE_CAPACITY
	return file, image_name, true
}

// stream_owner_keep keeps the process handle of a process that the console
// started, when its module declares a record output; else it closes the
// handle. false: the table of the owners is full, and the handle is closed.
stream_owner_keep :: proc "contextless" (name: string, process: system.Handle) -> bool {
	file, image_name, found := planned_file_of(name, true)
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
// then a connected service, then a module of the boot image that does not
// run (load: as planned_file_of).
stream_owner_find :: proc "contextless" (name: string, load: bool) -> (owner: Stream_Owner, found: bool) {
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
	file, image_name := planned_file_of(name, load) or_return
	return {name = image_name, file = file, end = .Child}, true
}

// stream_owner_named says if a name is the name of a process that the
// console started with a record output.
stream_owner_named :: proc "contextless" (name: string) -> bool {
	for item in stream_owners {
		if item.process != 0 && item.name == name {
			return true
		}
	}
	return false
}

// stream_name_known gives the record description of a typed name, and
// whether it names a record output (Stream) or a record input
// (Record_Input), with no failure and no value: the colors of a line, the
// completion and the checks before the run read it. It loads no module
// file.
stream_name_known :: proc "contextless" (name: string) -> (file: []u8, detail: u32, kind: Kind, known: bool) {
	owner_name, stream_name := console_stream.typed_name_split(name) or_return
	owner := stream_owner_find(owner_name, false) or_return
	if _, record, found := console_stream.record_output_find(owner.file, stream_name); found == .Found {
		return owner.file, record, .Stream, true
	}
	if _, record, found := console_stream.record_input_find(owner.file, stream_name); found == .Found {
		return owner.file, record, .Record_Input, true
	}
	return nil, 0, .None, false
}

// stream_names_fail fails the line for a typed name that its owner does not
// declare, with the names that it declares.
stream_names_fail :: proc "contextless" (owner_name, stream_name: string, file: []u8) -> Value {
	if console_stream.record_output_count(file) == 0 && console_stream.record_input_count(file) == 0 {
		return fail(owner_name, " declares no record output and no record input")
	}
	writer := sentence.Writer {
		buffer = scratch[scratch_count:],
	}
	console_stream.record_output_names_write(&writer, file)
	if console_stream.record_input_count(file) > 0 {
		sentence.write_part(&writer, "; its record inputs are ")
		for row in 1 ..= console_stream.record_input_count(file) {
			value, _, _, _, ok := module.record_input(file, row)
			if ok {
				sentence.write_part(&writer, row > 1 ? ", " : "")
				sentence.write_part(&writer, module.string_at(file, value.name_offset, value.name_count))
			}
		}
	}
	names := sentence.written(&writer)
	scratch_count += len(names)
	return fail(owner_name, " declares no record output or record input ", stream_name, "; its record outputs are ", names)
}

// stream_value_of_name gives the value of a typed name: a Stream for a
// record output, a Record_Input for a record input. named is false when the
// first part names no owner: the name is then no typed name, and the
// parser says so. A name that the owner does not declare fails the line.
stream_value_of_name :: proc "contextless" (name: string) -> (value: Value, named: bool) {
	owner_name, stream_name, split := console_stream.typed_name_split(name)
	if !split {
		return {}, false
	}
	owner, found := stream_owner_find(owner_name, true)
	if !found {
		return {}, false
	}
	is_input := false
	index, record, how := console_stream.record_output_find(owner.file, stream_name)
	if how == .Absent {
		index, record, how = console_stream.record_input_find(owner.file, stream_name)
		is_input = true
	}
	switch how {
	case .Found:
	case .Absent:
		return stream_names_fail(owner_name, stream_name, owner.file), true
	case .Generic:
		return fail(name, " is generic: its record comes with its wiring, and the console names a record output or a record input of a record only"), true
	case .Damaged:
		return fail("the module file of ", owner_name, " has a row of its record streams that the module contract refuses"), true
	}
	if line_stream_count >= LINE_STREAM_CAPACITY {
		return fail("a line names at most ", u64(LINE_STREAM_CAPACITY), " record streams"), true
	}
	described, described_ok := module.record_type(owner.file, record)
	if !described_ok || described.size == 0 {
		return fail("the record of ", name, " has no valid description"), true
	}
	line_streams[line_stream_count] = {
		owner       = owner.name,
		stream_name = stream_name,
		process     = owner.process,
		end         = owner.end,
		is_input    = is_input,
		index       = index,
		file        = owner.file,
		detail      = record,
		size        = int(described.size),
	}
	line_stream_count += 1
	kind := is_input ? Kind.Record_Input : Kind.Stream
	return {kind = kind, file = owner.file, detail = record, integer = i64(line_stream_count - 1)}, true
}

// line_stream_of gives the Stream or the record input of a value of the
// line, or nil.
line_stream_of :: proc "contextless" (value: Value) -> ^Line_Stream {
	if (value.kind != .Stream && value.kind != .Record_Input) || value.integer < 0 || value.integer >= i64(line_stream_count) {
		return nil
	}
	return &line_streams[value.integer]
}

// stream_value gives the value of a Stream: the description of its rows,
// which columns may have made.
stream_value :: proc "contextless" (stream: ^Line_Stream, place: int) -> Value {
	if stream.projection_file != nil {
		return {kind = .Stream, file = stream.projection_file, detail = 1, integer = i64(place)}
	}
	return {kind = .Stream, file = stream.file, detail = stream.detail, integer = i64(place)}
}

// stream_place gives the place of a Stream in the line.
stream_place :: proc "contextless" (stream: ^Line_Stream) -> int {
	return int((uintptr(stream) - uintptr(&line_streams[0])) / size_of(Line_Stream))
}

// condition_terms_fail fails the line for a condition that the border of a
// wiring refuses: the writer filters it not.
condition_terms_fail :: proc "contextless" (condition: Condition, refusal: output.Condition_Terms_Field) -> Value {
	switch refusal {
	case .Field:
		return fail("where: a record stream takes no condition on the field ", condition.field, ": the writer filters an Integer, a status or a Text")
	case .Comparison:
		return fail("where: a record stream takes no order on the field ", condition.field, ": a Text and a status take = and != only")
	case .Value_Kind, .Integer:
		return fail("where: the field ", condition.field, " cannot hold the value of the condition")
	case .Text_Count, .Text:
		return fail("where: a record stream compares a Text of at most ", u64(output.CONDITION_TEXT_BYTES_MOST), " bytes and the bytes of its field, with no zero byte and no control character")
	case .Whole, .Reserved:
	}
	return fail("where: the terms of the condition on ", condition.field, " are refused")
}

// stream_where adds a condition to a Stream, and gives the same Stream: no
// record is read yet. condition_evaluate checked the field and the value
// against the description of the Stream. The condition becomes the terms
// of a wiring here, through the border of the root service, so a condition
// that the writer does not filter fails the line before any wiring.
stream_where :: proc "contextless" (value: Value, condition: ^Condition) -> Value {
	stream := line_stream_of(value)
	if stream == nil || stream.is_input {
		return fail("where: the record stream is not one of this line")
	}
	if stream.number != 0 {
		return fail("where: the record stream is read already")
	}
	if stream.condition_count >= STREAM_CONDITION_CAPACITY {
		return fail("where: a record stream takes at most ", u64(STREAM_CONDITION_CAPACITY), " conditions")
	}
	if len(condition.text) > output.CONDITION_TEXT_BYTES_MOST {
		return fail("where: a record stream compares a Text of at most ", u64(output.CONDITION_TEXT_BYTES_MOST), " bytes; this one has ", u64(len(condition.text)))
	}
	// The conditions read the whole record: columns keeps the names and the
	// types of the fields that it chose.
	described, _ := module.record_type(stream.file, stream.detail)
	item, found := console_condition.field_find(stream.file, described, condition.field)
	if !found {
		return fail("where: the records of the record stream have no field ", condition.field)
	}
	is_text := item.type == u8(module.Type.Text)
	terms, terms_ok := output.condition_terms_of_field(stream.file, described, condition.field, console_stream.comparison_of(condition.comparison), condition.compared, condition.text, is_text)
	if !terms_ok {
		return fail("where: the records of the record stream have no field ", condition.field)
	}
	bytes := transmute([size_of(output.Condition_Terms)]u8)terms
	resolved, refusal, resolved_ok := output.writer_condition_of_terms(bytes[:], stream.file, described)
	if !resolved_ok {
		// The argument of the refusal names the part of the terms that it
		// refuses; a word that names no part gives the general sentence.
		part, part_ok := enum_word.member_of_word(output.Condition_Terms_Field, u64(refusal.argument))
		if !part_ok {
			part = .Whole
		}
		return condition_terms_fail(condition^, part)
	}
	resolved_bytes := transmute([size_of(output.Writer_Condition)]u8)resolved
	checked, checked_ok := output.writer_condition_check(resolved_bytes[:], u32(stream.size))
	if !checked_ok {
		return fail("where: the condition on ", condition.field, " does not fit the record")
	}
	stream.conditions[stream.condition_count] = condition^
	stream.terms[stream.condition_count] = terms
	stream.checks[stream.condition_count] = checked
	stream.condition_count += 1
	return value
}

// stream_passes says if a whole record passes each condition of its
// Stream: the one test of a condition, which the writer applies to the
// first one too.
stream_passes :: proc "contextless" (stream: ^Line_Stream, record: []u8) -> bool {
	for index in 0 ..< stream.condition_count {
		if !output.writer_condition_holds(stream.checks[index], record) {
			return false
		}
	}
	return true
}

// stream_columns gives a Stream whose rows hold the fields that the names
// choose, in their order: columns(s, a, b). The conditions still read the
// whole record. names holds the names, separated by commas or spaces, as
// the parser read them.
stream_columns :: proc "contextless" (value: Value, names: string) -> Value {
	stream := line_stream_of(value)
	if stream == nil || stream.is_input {
		return fail("columns: the record stream is not one of this line")
	}
	whole, _ := module.record_type(stream.file, stream.detail)
	// The names that a former columns kept, by the description of the value.
	shown, shown_ok := module.record_type(value.file, value.detail)
	if !shown_ok {
		return fail("columns: the record stream has no valid description")
	}
	shown_table := Table {
		file   = value.file,
		record = shown,
	}
	columns: [COLUMN_CAPACITY]Column
	count := 0
	rest := names
	for len(rest) > 0 {
		end := 0
		for end < len(rest) && rest[end] != ' ' && rest[end] != ',' {
			end += 1
		}
		name := rest[:end]
		rest = rest[min(end + 1, len(rest)):]
		if name == "" {
			continue
		}
		if _, in_shown := table_field(shown_table, name); !in_shown {
			return fail("columns: the records ", type_text(value.file, .Record, value.detail), " have no field ", name, "; their fields are ", field_names(shown_table))
		}
		item, _ := console_condition.field_find(stream.file, whole, name)
		if count == COLUMN_CAPACITY {
			return fail("columns: more than ", i64(COLUMN_CAPACITY), " fields")
		}
		column, column_ok := console_results.column_of_field(name, item)
		if !column_ok {
			return fail("columns: the field ", name, " has a type or a kind that names nothing")
		}
		columns[count] = column
		count += 1
	}
	if count == 0 {
		return fail("columns: no field is named; the fields are ", field_names(shown_table))
	}
	file, size, made := description_make(module.string_at(stream.file, whole.name_offset, whole.name_count), columns[:count])
	if !made {
		return fail("columns: no room for the description")
	}
	// description_make wrote the offset of each column in the new record;
	// from is its offset in the whole record.
	stream.projection_file, stream.projection_count, stream.projection_size = file, count, int(size)
	described, _ := module.record_type(file, 1)
	for index in 0 ..< count {
		item, _ := module.field(file, described, u32(index))
		stream.projection_columns[index] = columns[index]
		stream.projection_columns[index].offset = item.offset
	}
	return stream_value(stream, stream_place(stream))
}

// stream_row_size gives the bytes of one row of a Stream: of its fields
// that columns chose, or of the whole record.
stream_row_size :: proc "contextless" (stream: ^Line_Stream) -> int {
	return stream.projection_file != nil ? stream.projection_size : stream.size
}

// stream_row_write writes the row of a whole record: the record, or its
// fields that columns chose.
stream_row_write :: proc "contextless" (stream: ^Line_Stream, record: []u8, row: []u8) {
	if stream.projection_file == nil {
		copy(row, record)
		return
	}
	for &column in stream.projection_columns[:stream.projection_count] {
		width := int(module.field_size(console_results.column_field(column)))
		copy(row[column.offset:][:width], record[column.from:][:width])
	}
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

// lent_handles_return gives the root service back the handles that the
// console lent for a command that it does not send: a list of no row that
// names them, and a Wire that the border of the list refuses. The root
// service closes each lent number of a refused list (lent_handles_close of
// the root service), so no lent handle stays in its table, whose room
// each start and each wiring needs. The answer is that refusal: the
// console reads it and keeps nothing of it.
lent_handles_return :: proc "contextless" (handles: []u32) {
	if len(handles) == 0 || list_page == nil {
		return
	}
	for &value in list_page {
		value = 0
	}
	if !output.wiring_list_write(list_page, nil, handles) {
		return
	}
	disk_request(.Wire, {0 = u64(root_ring.Wire_Step.Apply)}, WIRE_ANSWER_LIMIT)
}

// not_running_fail fails the line for an end of a module that does not
// run.
not_running_fail :: proc "contextless" (command: string, owner: string) -> Value {
	return fail(command, ": ", owner, " does not run: start(\"", owner, "\") starts it, and start(\"", owner, "\", list) names it in a list")
}

// stream_wire wires the record output of a Stream to this console, as its
// asker, once: Wire with one row from the owner to the asker, and the first
// condition of the Stream as the condition of the wiring. The pace is the
// choice of the writer, and the ring has the default capacity.
stream_wire :: proc "contextless" (stream: ^Line_Stream) -> bool {
	if stream.number != 0 {
		return true
	}
	if stream.closed {
		fail("the record stream ", stream.owner, ".", stream.stream_name, " ended already")
		return false
	}
	if stream.end == .Child {
		not_running_fail("read", stream.owner)
		return false
	}
	if !list_page_ready() {
		return false
	}
	row := output.Wiring {
		writer_end    = u32(stream.end),
		writer_stream = u32(output.Writer_Stream.Record_Output),
		writer_index  = stream.index,
		reader_end    = u32(output.Wiring_End.Asker),
	}
	handles: [1]u32
	handle_count := 0
	switch stream.end {
	case .Started:
		// The process handle goes to the root service through its ring,
		// which is how it proves the handle (src/md/features/module_outputs.md,
		// "How the root service names a lent handle").
		lent, give_status := system.give(requests_memory, stream.process, {.Read})
		if give_status != .Ok {
			fail("the console cannot lend the handle of ", stream.owner, " to the root service: ", give_status)
			return false
		}
		handles[0] = u32(lent)
		handle_count = 1
		row.writer_handle = 1
	case .Connected:
		// A connection is named by the number of its handle, never lent.
		row.writer_handle = u32(stream.process)
	case .Child, .Asker, .None:
		fail("the record stream ", stream.owner, ".", stream.stream_name, " has no writer that runs")
		return false
	}
	if stream.condition_count > 0 {
		row.condition_offset = u32(output.wiring_terms_start(1, handle_count))
		row.condition_count = size_of(output.Condition_Terms)
	}
	rows := [1]output.Wiring{row}
	for &value in list_page {
		value = 0
	}
	if !output.wiring_list_write(list_page, rows[:], handles[:handle_count]) {
		lent_handles_return(handles[:handle_count])
		fail("the row of the wiring does not fit the list page")
		return false
	}
	if stream.condition_count > 0 {
		terms := transmute([size_of(output.Condition_Terms)]u8)stream.terms[0]
		copy(list_page[row.condition_offset:], terms[:])
	}
	completion, answered := disk_request(.Wire, {0 = u64(root_ring.Wire_Step.Apply)}, WIRE_ANSWER_LIMIT)
	if !answered {
		fail_no_answer()
		return false
	}
	if status, _ := system.status_of_word(completion.kind); status != .Ok {
		fail_root(scratch_text("cannot read ", stream.owner, ".", stream.stream_name, ": "), completion)
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

// stream_read_next reads the next compartment of a wired Stream into
// record, of the size of the whole record. escaped: Escape ended the wait:
// the read waits on the word that Escape changes beside the words of its
// ring.
stream_read_next :: proc "contextless" (stream: ^Line_Stream, record: []u8) -> (item: system.Input_Item, status: output.Stream_Status, escaped: bool) {
	item, status = system.asker_read_bytes(stream.number, record, system.WAIT_FOREVER, &work.cancel, 0)
	if status == .No_Record && intrinsics.atomic_load(&work.cancel) != 0 {
		return item, status, true
	}
	return item, status, false
}

// stream_refused fails the line with the refusal of a compartment, or of
// the counters of its ring.
stream_refused :: proc "contextless" (command: string, stream: ^Line_Stream, item: system.Input_Item) {
	already := failed
	fail(command, ": the console refused a record of ", stream.owner, ".", stream.stream_name, ", and closed the record stream")
	if !already {
		failure_record_set(item.refusal, "output.record_of_compartment", nil)
	}
}

// stream_writer_kept says if a record passes the condition of its wiring,
// the first condition of the Stream, which the writer applies: a record
// that fails it is one that the writer had to leave out. A Stream with no
// condition has none to check.
stream_writer_kept :: proc "contextless" (stream: ^Line_Stream, record: []u8) -> bool {
	return stream.condition_count == 0 || output.writer_condition_holds(stream.checks[0], record)
}

// stream_writer_lied fails the line for a record that fails the condition
// of its wiring: a fault of the writer, never a record to drop in silence
// (src/md/features/module_outputs.md, "The condition of a wiring"). The
// console closes the record stream: it trusts no later record of it. The
// error record: Bad_Value of the unit Wiring_Terms, the field of the terms
// as its argument, the serial of the record as its value, and the number
// of the field as found.
stream_writer_lied :: proc "contextless" (command: string, stream: ^Line_Stream, item: system.Input_Item) {
	stream_close(stream)
	already := failed
	condition := stream.conditions[0]
	value_text := condition.text
	if stream.terms[0].value_kind == u32(output.Condition_Value_Kind.Integer) {
		value_text = scratch_text(condition.compared)
	}
	fail(command, ": the writer of ", stream.owner, ".", stream.stream_name, " wrote the record ", u64(item.serial), ", which fails the condition of its wiring (", condition.field, " ", console_condition.COMPARISON_TEXTS[condition.comparison], " ", value_text, "); the console closed the record stream")
	if !already {
		failure_record_set(errors.error_make(.Bad_Value, .Wiring_Terms, i64(output.Condition_Terms_Field.Field), i64(item.serial), 0, i64(stream.terms[0].field)), "output.writer_condition_holds", nil)
	}
}

// stream_of_argument gives the Stream of an argument that must be one.
stream_of_argument :: proc "contextless" (command: string, value: Value) -> ^Line_Stream {
	stream := line_stream_of(value)
	if stream == nil || stream.is_input {
		fail(command, ": the record stream is not one of this line")
		return nil
	}
	return stream
}

// stream_collect reads the rows of a Stream that pass its conditions into
// a Table of the line: first(s, n) with its count, table(s) until the end.
stream_collect :: proc "contextless" (command: string, value: Value, wanted: int) -> Value {
	stream := stream_of_argument(command, value)
	if stream == nil {
		return {}
	}
	row_size := stream_row_size(stream)
	shown := stream_value(stream, int(value.integer))
	start := min((table_used + 7) &~ 7, len(table_memory))
	capacity := len(table_memory) - start
	if wanted == console_stream.TABLE_ROWS_WANTED_ALL {
		capacity = min(capacity, TABLE_KEPT)
	}
	kept := 0
	// A count of 0 reads no record, and wires nothing.
	if console_stream.collect_step_of(kept, wanted, row_size, capacity) == .Done {
		return {kind = .Table, record = table_memory[start:start], file = shown.file, detail = shown.detail}
	}
	if !stream_wire(stream) {
		return {}
	}
	intrinsics.atomic_store(&work.call_stoppable, 1)
	defer intrinsics.atomic_store(&work.call_stoppable, 0)
	record: [module.RECORD_SIZE_LIMIT]u8
	read: for {
		switch console_stream.collect_step_of(kept, wanted, row_size, capacity) {
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
		item, status, escaped := stream_read_next(stream, record[:stream.size])
		if escaped {
			stream_close(stream)
			return fail(command, ": Escape closed the stream after ", u64(kept), kept == 1 ? " row" : " rows")
		}
		switch status {
		case .Ok:
			if item.kind == .Record && !stream_writer_kept(stream, record[:stream.size]) {
				stream_writer_lied(command, stream, item)
				return {}
			}
			if item.kind == .Record && stream_passes(stream, record[:stream.size]) {
				stream_row_write(stream, record[:stream.size], table_memory[start + kept * row_size:][:row_size])
				kept += 1
			}
		case .Ended:
			break read
		case .Bad_Record:
			stream_refused(command, stream, item)
			return {}
		case .No_Writer:
			stream_close(stream)
			return fail(command, ": the console holds no end of the wiring of ", stream.owner, ".", stream.stream_name)
		case .No_Reader, .Full, .No_Record:
			// A read gives none of these, but No_Record after Escape.
		}
	}
	stream_close(stream)
	table_used = start + kept * row_size
	return {kind = .Table, record = table_memory[start:table_used], file = shown.file, detail = shown.detail}
}

// stream_table gives the rows of a Stream until its end.
stream_table :: proc "contextless" (arguments: []Value) -> Value {
	if arguments[0].kind == .Table {
		return arguments[0]
	}
	return stream_collect("table", arguments[0], console_stream.TABLE_ROWS_WANTED_ALL)
}

// stream_counts gives the counts of the writer of a Stream: the records
// written, discarded, and refused as Full, as the writer published them at
// its last write before this read, which comes after the first compartment
// of the ring. They are at least as new as the joined record, and can be
// newer (src/md/features/module_outputs.md, "The counts of a record
// output").
stream_counts :: proc "contextless" (arguments: []Value) -> Value {
	stream := stream_of_argument("stream_counts", arguments[0])
	if stream == nil {
		return {}
	}
	if !stream_wire(stream) {
		return {}
	}
	intrinsics.atomic_store(&work.call_stoppable, 1)
	defer intrinsics.atomic_store(&work.call_stoppable, 0)
	record: [module.RECORD_SIZE_LIMIT]u8
	item, status, escaped := stream_read_next(stream, record[:stream.size])
	if escaped {
		stream_close(stream)
		return fail("stream_counts: Escape closed the stream before its first compartment")
	}
	if status == .Bad_Record {
		stream_refused("stream_counts", stream, item)
		return {}
	}
	counts, counted := system.asker_writer_counts(stream.number)
	stream_close(stream)
	if status != .Ok || !counted {
		return fail("stream_counts: the record stream ", stream.owner, ".", stream.stream_name, " ended before its first compartment")
	}
	columns := [3]Column{integer_column("written"), integer_column("discarded"), integer_column("refused")}
	table, made := made_table("Writer_Counts", columns[:])
	if !made {
		return fail("stream_counts: the line has no room for the description")
	}
	row := made_row(&table)
	made_integer(&table, row, 0, i64(min(counts.written, u64(max(i64)))))
	made_integer(&table, row, 1, i64(min(counts.discarded, u64(max(i64)))))
	made_integer(&table, row, 2, i64(min(counts.refused, u64(max(i64)))))
	return made_record(&table, "stream_counts")
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
		fail("the record stream is not one of this line")
		return
	}
	if stream.is_input {
		fail(stream.owner, ".", stream.stream_name, " is a record input: it has no record to draw, and wire(from, to) names it")
		return
	}
	columns, columns_ok := console_results.stream_columns_of(value.file, value.detail)
	if !columns_ok {
		fail("the record stream ", stream.owner, ".", stream.stream_name, " has no valid description")
		return
	}
	if !stream_wire(stream) {
		return
	}
	{
		system.lock(&output_lock)
		defer system.unlock(&output_lock)
		sink := result_sink()
		console_results.draw_stream_head(&sink, &columns, value.file)
		output_continuation = 0
	}
	intrinsics.atomic_store(&work.call_stoppable, 1)
	defer intrinsics.atomic_store(&work.call_stoppable, 0)
	record: [module.RECORD_SIZE_LIMIT]u8
	row: [module.RECORD_SIZE_LIMIT]u8
	row_size := stream_row_size(stream)
	drawn: u64
	read: for {
		item, status, escaped := stream_read_next(stream, record[:stream.size])
		if escaped {
			stream_note_draw({kind = .Escape, count = drawn})
			break read
		}
		switch status {
		case .Ok:
			switch item.kind {
			case .Record:
				if !stream_writer_kept(stream, record[:stream.size]) {
					stream_writer_lied("the draw", stream, item)
					break read
				}
				if stream_passes(stream, record[:stream.size]) {
					stream_row_write(stream, record[:stream.size], row[:row_size])
					system.lock(&output_lock)
					sink := result_sink()
					console_results.draw_stream_row(&sink, &columns, row[:row_size])
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
			fail("the console holds no end of the wiring of ", stream.owner, ".", stream.stream_name)
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
	file, _, found := planned_file_of(name, true)
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

// ---- The rows of a wiring list.

// The columns of the record Wiring of the console: the names of the ends,
// a text of the condition for a reader of the table, and the terms of the
// condition. 252 bytes: the most of a record is 256.
WIRING_COLUMN_COUNT :: 10
WIRING_COLUMN_WRITER :: 0
WIRING_COLUMN_OUTPUT :: 1
WIRING_COLUMN_READER :: 2
WIRING_COLUMN_INPUT :: 3
WIRING_COLUMN_CONDITION :: 4
WIRING_COLUMN_FIELD :: 5
WIRING_COLUMN_COMPARISON :: 6
WIRING_COLUMN_VALUE_KIND :: 7
WIRING_COLUMN_INTEGER :: 8
WIRING_COLUMN_TEXT :: 9

// wiring_columns gives the columns of the record Wiring of the console.
wiring_columns :: proc "contextless" () -> [WIRING_COLUMN_COUNT]Column {
	return {
		text_column("writer", 32),
		text_column("output", 32),
		text_column("reader", 32),
		text_column("input", 32),
		text_column("condition", 40),
		{name = "field", type = .Integer, detail = 4, unsigned = true},
		{name = "comparison", type = .Integer, detail = 4, unsigned = true},
		{name = "value_kind", type = .Integer, detail = 4, unsigned = true},
		integer_column("integer"),
		text_column("text", output.CONDITION_TEXT_BYTES_MOST),
	}
}

// wire gives the Table of one row of a wiring list, from a record output
// to a record input: wire(shop.orders, server.orders). The first condition
// of the Stream goes with the row as its condition. The row names its ends
// by their names: start turns them into the ends of the contract.
wire :: proc "contextless" (arguments: []Value) -> Value {
	from := stream_of_argument("wire", arguments[0])
	to := line_stream_of(arguments[1])
	if from == nil {
		return {}
	}
	if to == nil || !to.is_input {
		return fail("wire: the record input is not one of this line")
	}
	if from.projection_file != nil {
		return fail("wire: a wiring carries a record output whole, not the fields that columns chose")
	}
	if from.condition_count > 1 {
		return fail("wire: a wiring takes one condition; the record stream ", from.owner, ".", from.stream_name, " has ", u64(from.condition_count))
	}
	if from.owner == to.owner {
		return fail("wire: ", from.owner, " is at both ends: a wiring joins two processes")
	}
	difference, part := output.record_descriptions_compare(from.file, from.detail, to.file, to.detail)
	if difference != .Equal {
		writer_record, _ := module.record_type(from.file, from.detail)
		reader_record, _ := module.record_type(to.file, to.detail)
		return fail("wire: ", from.owner, ".", from.stream_name, " writes ", module.string_at(from.file, writer_record.name_offset, writer_record.name_count), " and ", to.owner, ".", to.stream_name, " reads ", module.string_at(to.file, reader_record.name_offset, reader_record.name_count), ": the two records differ in the part ", i64(part), ", and a wiring joins two equal records")
	}
	columns := wiring_columns()
	table, made := made_table("Wiring", columns[:])
	if !made {
		return fail("wire: the line has no room for the description")
	}
	row := made_row(&table)
	made_text(&table, row, WIRING_COLUMN_WRITER, from.owner)
	made_text(&table, row, WIRING_COLUMN_OUTPUT, from.stream_name)
	made_text(&table, row, WIRING_COLUMN_READER, to.owner)
	made_text(&table, row, WIRING_COLUMN_INPUT, to.stream_name)
	if from.condition_count == 1 {
		condition := from.conditions[0]
		terms := from.terms[0]
		value_text := condition.text
		if terms.value_kind == u32(output.Condition_Value_Kind.Integer) {
			value_text = scratch_text(condition.compared)
		}
		made_text(&table, row, WIRING_COLUMN_CONDITION, scratch_text(condition.field, " ", console_condition.COMPARISON_TEXTS[condition.comparison], " ", value_text))
		made_integer(&table, row, WIRING_COLUMN_FIELD, i64(terms.field))
		made_integer(&table, row, WIRING_COLUMN_COMPARISON, i64(terms.comparison))
		made_integer(&table, row, WIRING_COLUMN_VALUE_KIND, i64(terms.value_kind))
		made_integer(&table, row, WIRING_COLUMN_INTEGER, terms.integer)
		made_text(&table, row, WIRING_COLUMN_TEXT, condition.text)
	}
	return made_value(&table, "wire")
}

// A row of a list of a start, resolved against the module that starts and
// the owners of the console, before any handle is lent.
Start_Row :: struct {
	row:          output.Wiring,
	writer_owner: Stream_Owner, // Not the child.
	reader_owner: Stream_Owner,
	has_terms:    bool,
	terms:        output.Condition_Terms,
}

start_rows: [output.WIRING_LIST_ROW_LIMIT]Start_Row

// start_end_of resolves one end of a row: the child, a started process, a
// connected service. The index is the record output or the record input of
// the name in the module file of the end.
@(private = "file")
start_end_of :: proc "contextless" (number: int, module_name: string, child_file: []u8, owner_name, stream_name: string, is_child, is_input: bool) -> (owner: Stream_Owner, index: u32, ok: bool) {
	file := child_file
	if !is_child {
		found: bool
		owner, found = stream_owner_find(owner_name, true)
		if !found {
			fail("start: the row ", u64(number), " names ", owner_name, ", which is no process that this console started or connected and no module")
			return {}, 0, false
		}
		if owner.end == .Child {
			not_running_fail("start", owner_name)
			return {}, 0, false
		}
		file = owner.file
	} else {
		owner = {name = module_name, end = .Child}
	}
	how: console_stream.Output_Find
	if is_input {
		index, _, how = console_stream.record_input_find(file, stream_name)
	} else {
		index, _, how = console_stream.record_output_find(file, stream_name)
	}
	if how != .Found {
		stream_names_fail(owner_name, stream_name, file)
		return {}, 0, false
	}
	return owner, index, true
}

// start_with_list starts a module with the rows of a Table of the record
// Wiring of the console: each end that names the module becomes the end
// Child, each other one a started process (a lent handle) or a connected
// service (the number of its connection). Each check of the console comes
// before the first lent handle, so a refusal of the console lends nothing.
start_with_list :: proc "contextless" (name: string, list: Value) -> Value {
	reference_columns := wiring_columns()
	reference, reference_made := made_table("Wiring", reference_columns[:])
	if !reference_made {
		return fail("start: the line has no room for the description")
	}
	if list.kind != .Table || !module.records_equal(list.file, list.detail, reference.file, 1) {
		return fail("start: the list is a Table of Wiring, as wire(from, to) gives it; this one is ", type_text(list.file, list.kind, list.detail))
	}
	table, table_ok := table_of(list)
	if !table_ok {
		return fail("start: the list has no valid description")
	}
	if table.rows == 0 || table.rows > output.WIRING_LIST_ROW_LIMIT {
		return fail("start: a list holds 1 to ", u64(output.WIRING_LIST_ROW_LIMIT), " rows; this one has ", u64(table.rows))
	}
	child_file, child_name, child_found := planned_file_of(name, true)
	if !child_found {
		return fail("start: no module of the boot image has the name ", name)
	}
	items: [WIRING_COLUMN_COUNT]module.Field
	for column, index in reference_columns {
		items[index], _ = table_field(table, column.name)
	}
	handle_count := 0
	condition_count := 0
	for index in 0 ..< table.rows {
		row := table_row(table, list, index)
		writer := module.field_text(row, items[WIRING_COLUMN_WRITER])
		reader := module.field_text(row, items[WIRING_COLUMN_READER])
		writer_is_child, reader_is_child, refusal := console_stream.start_row_ends(child_name, writer, reader)
		switch refusal {
		case .None:
		case .No_End_Of_Module:
			return fail("start: the row ", u64(index + 1), " wires ", writer, " to ", reader, ", and names no end of ", child_name)
		case .Module_Twice:
			return fail("start: the row ", u64(index + 1), " wires ", child_name, " to itself")
		}
		planned := &start_rows[index]
		planned^ = {}
		writer_owner, writer_index, writer_ok := start_end_of(index + 1, child_name, child_file, writer, module.field_text(row, items[WIRING_COLUMN_OUTPUT]), writer_is_child, false)
		if !writer_ok {
			return {}
		}
		reader_owner, reader_index, reader_ok := start_end_of(index + 1, child_name, child_file, reader, module.field_text(row, items[WIRING_COLUMN_INPUT]), reader_is_child, true)
		if !reader_ok {
			return {}
		}
		planned.writer_owner, planned.reader_owner = writer_owner, reader_owner
		planned.row = {writer_end = u32(writer_owner.end), writer_stream = u32(output.Writer_Stream.Record_Output), writer_index = writer_index, reader_end = u32(reader_owner.end), reader_index = reader_index}
		handle_count += int(writer_owner.end == .Started) + int(reader_owner.end == .Started)
		if field := module.field_integer(row, items[WIRING_COLUMN_FIELD]); field != 0 {
			planned.has_terms = true
			planned.terms = {field = u32(field), comparison = u32(module.field_integer(row, items[WIRING_COLUMN_COMPARISON])), value_kind = u32(module.field_integer(row, items[WIRING_COLUMN_VALUE_KIND])), integer = module.field_integer(row, items[WIRING_COLUMN_INTEGER])}
			text := module.field_text(row, items[WIRING_COLUMN_TEXT])
			planned.terms.text_count = u32(copy(planned.terms.text[:], text))
			condition_count += 1
		}
	}
	conditions_start, fits := console_stream.start_list_fits(table.rows, handle_count, condition_count)
	if !fits {
		return fail("start: the list needs ", u64(handle_count), " lent handles, and a list takes at most ", u64(output.WIRING_LIST_HANDLE_LIMIT))
	}
	if !list_page_ready() {
		return {}
	}
	// Each check passed: now the handles go to the root service, which
	// closes each one on each path of the command.
	rows: [output.WIRING_LIST_ROW_LIMIT]output.Wiring
	handles: [output.WIRING_LIST_HANDLE_LIMIT]u32
	lent_count := 0
	condition_place := conditions_start
	for index in 0 ..< table.rows {
		planned := &start_rows[index]
		ends := [2]^Stream_Owner{&planned.writer_owner, &planned.reader_owner}
		words := [2]^u32{&planned.row.writer_handle, &planned.row.reader_handle}
		for owner, side in ends {
			switch owner.end {
			case .Started:
				lent, give_status := system.give(requests_memory, owner.process, {.Read})
				if give_status != .Ok {
					// The handles lent before this one go back to the root
					// service, which would keep them for its whole life.
					lent_handles_return(handles[:lent_count])
					return fail("start: the console cannot lend the handle of ", owner.name, " to the root service: ", give_status)
				}
				handles[lent_count] = u32(lent)
				lent_count += 1
				words[side]^ = u32(lent_count)
			case .Connected:
				words[side]^ = u32(owner.process)
			case .Child, .Asker, .None:
			}
		}
		if planned.has_terms {
			planned.row.condition_offset = u32(condition_place)
			planned.row.condition_count = size_of(output.Condition_Terms)
			condition_place += size_of(output.Condition_Terms)
		}
		rows[index] = planned.row
	}
	for &value in list_page {
		value = 0
	}
	if !output.wiring_list_write(list_page, rows[:table.rows], handles[:lent_count]) {
		lent_handles_return(handles[:lent_count])
		return fail("start: the list does not fit the list page")
	}
	for index in 0 ..< table.rows {
		planned := &start_rows[index]
		if planned.has_terms {
			terms := transmute([size_of(output.Condition_Terms)]u8)planned.terms
			copy(list_page[planned.row.condition_offset:], terms[:])
		}
	}
	packed := system.name_pack(name)
	completion, answered := disk_request(.Start, {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3], 4 = u64(root_ring.Start_Wiring_List.In_The_List_Page), 5 = u64(root_ring.Start_Answer.Process_Handle)}, WIRE_ANSWER_LIMIT)
	if !answered {
		return fail_no_answer()
	}
	if status, _ := system.status_of_word(completion.kind); status != .Ok {
		return fail_root(scratch_text("start: ", name, ": "), completion)
	}
	if !stream_owner_keep(name, system.Handle(completion.values[0])) {
		return fail("start: ", name, " runs, and has no typed name: the console names the record outputs of ", u64(STREAM_OWNER_CAPACITY), " processes that it started at most, until one of them stops")
	}
	return {}
}
