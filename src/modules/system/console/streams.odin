package console

import "modus:contract/blake3"
import "modus:contract/enum_word"
import "modus:contract/errors"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/output"
import "modus:contract/root_ring"
import "modus:console_condition"
import "internal:console/console_results"
import "internal:console/console_stream"
import "modus:sentence"
import "modus:system"
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
	// The record that a list of start of this console fixed for the generic
	// record input of the owner, which its generic record output takes
	// (src/md/features/module_outputs.md, "The decisions of the generic record inputs"): the
	// file that describes it, and its index there. nil: none.
	generic_file:   []u8,
	generic_detail: u32,
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
	is_log:          bool, // Implicit process record output log: wired only in start(module, wire(module.log, ...)).
	is_log_follow:   bool, // Live kernel log follow stream: protected by the self-feedback loop breaker.
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

// Canonical description file for the implicit record output log, built once.
log_output_desc_buffer: [output.DESCRIPTION_FILE_BYTES_MOST]u8
log_output_desc_size: int

// Cached process slot of this console for self-feedback exclusion on log.follow.
own_process_slot_cached: i64
own_process_slot_known: bool

// log_output_description_file returns the canonical module description file
// for output.Log_Output_Record, initializing it once in BSS.
log_output_description_file :: proc "contextless" () -> []u8 {
	if log_output_desc_size == 0 {
		if size, ok := output.log_output_file_write(log_output_desc_buffer[:]); ok {
			log_output_desc_size = size
		}
	}
	return log_output_desc_buffer[:log_output_desc_size]
}

// console_own_process_slot resolves this console's kernel process slot via
// Inspect so log.follow excludes records emitted by this console itself.
console_own_process_slot :: proc "contextless" () -> i64 {
	if own_process_slot_known {
		return own_process_slot_cached
	}
	own_process_slot_known = true
	if machine == 0 {
		return 0
	}
	report: op.System_Report
	if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report)); status != .Ok {
		return 0
	}
	for slot in u64(1) ..< report.process_slots {
		process: op.Process_Report
		if _, p_status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), slot, u64(uintptr(&process)), size_of(process)); p_status != .Ok {
			continue
		}
		if process.state != .None && system.name_of(process.name[:]) == "console" {
			own_process_slot_cached = i64(slot)
			return own_process_slot_cached
		}
	}
	return 0
}

// follow_row_slot_and_process extracts the slot and process fields from a raw
// log.Follow_Row record buffer for self-feedback filtering.
@(private = "file")
follow_row_slot_and_process :: proc "contextless" (record: []u8) -> (slot: i64, process_name: string) {
	if len(record) != console_stream.FOLLOW_ROW_SIZE {
		return 0, ""
	}
	wire: console_stream.Follow_Row_Wire
	intrinsics.mem_copy_non_overlapping(&wire, raw_data(record), size_of(wire))
	name_len := 0
	for name_len < len(wire.process) && wire.process[name_len] != 0 {
		name_len += 1
	}
	return wire.slot, string(record[offset_of(console_stream.Follow_Row_Wire, process):][:name_len])
}

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
	if console_stream.is_log_output_name(owner_name, stream_name) {
		desc := log_output_description_file()
		if len(desc) > 0 {
			return desc, output.DESCRIPTION_RECORD_INDEX, .Stream, true
		}
		return nil, 0, .None, false
	}
	_, output_record, output_found := console_stream.record_output_find(owner.file, stream_name)
	switch output_found {
	case .Found:
		return owner.file, output_record, .Stream, true
	case .Generic:
		// A generic record output reads as the record that a list of
		// this console fixed for it.
		if owner.generic_file != nil {
			return owner.generic_file, owner.generic_detail, .Stream, true
		}
		return nil, 0, .None, false
	case .Absent, .Damaged:
	}
	// A generic record input has no fields: the record 0.
	if _, record, found := console_stream.record_input_find(owner.file, stream_name); found == .Found || found == .Generic {
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
	is_log := console_stream.is_log_output_name(owner_name, stream_name)
	index := u32(0)
	record := u32(0)
	file := owner.file
	if is_log {
		file = log_output_description_file()
		record = output.DESCRIPTION_RECORD_INDEX
		if len(file) == 0 {
			return fail("the record output log has no valid description"), true
		}
	} else {
		how: console_stream.Output_Find
		index, record, how = console_stream.record_output_find(owner.file, stream_name)
		if how == .Absent {
			index, record, how = console_stream.record_input_find(owner.file, stream_name)
			is_input = true
		}
		// The record that the line reads: of the declaration, or for a generic
		// record output the record that a list of this console fixed.
		switch how {
		case .Found:
		case .Absent:
			return stream_names_fail(owner_name, stream_name, owner.file), true
		case .Generic:
			switch {
			case is_input:
				// wire takes it; the root service checks the record of each
				// wiring, as the first one fixes it.
			case owner.generic_file != nil:
				file, record = owner.generic_file, owner.generic_detail
			case:
				return fail(name, " is generic: it writes the record that the first wiring of the generic record input of ", owner_name, " fixed, and no list of a start of ", owner_name, " by this console fixed one"), true
			}
		case .Damaged:
			return fail("the module file of ", owner_name, " has a row of its record streams that the module contract refuses"), true
		}
	}
	if line_stream_count >= LINE_STREAM_CAPACITY {
		return fail("a line names at most ", u64(LINE_STREAM_CAPACITY), " record streams"), true
	}
	// A generic record input has no record of its own: size 0, which only
	// wire reads.
	size := 0
	if record != 0 {
		described, described_ok := module.record_type(file, record)
		if !described_ok || described.size == 0 {
			return fail("the record of ", name, " has no valid description"), true
		}
		size = int(described.size)
	}
	line_streams[line_stream_count] = {
		owner         = owner.name,
		stream_name   = stream_name,
		process       = owner.process,
		end           = owner.end,
		is_input      = is_input,
		is_log        = is_log,
		is_log_follow = !is_input && !is_log && console_stream.is_log_follow_name(owner.name, stream_name),
		index         = index,
		file          = file,
		detail        = record,
		size          = size,
	}
	line_stream_count += 1
	kind := is_input ? Kind.Record_Input : Kind.Stream
	return {kind = kind, file = file, detail = record, integer = i64(line_stream_count - 1)}, true
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
	case .Whole, .Reserved_First, .Reserved_Second:
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
	if stream.is_log {
		return fail("where: the record output log takes no condition")
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
	if stream.is_log {
		fail("read: the record output log is wired only in start(module, wire(module.log, ...))")
		return false
	}
	if stream.closed {
		fail("the record stream ", stream.owner, ".", stream.stream_name, " ended already")
		return false
	}
	if stream.end == .Child {
		not_running_fail("read", stream.owner)
		return false
	}
	// Self-feedback loop breaker: when following log.follow with no user
	// wiring condition, push slot != own_process_slot into the wiring itself.
	if stream.is_log_follow && stream.condition_count == 0 {
		if own_slot := console_own_process_slot(); own_slot > 0 {
			if described, rec_ok := module.record_type(stream.file, stream.detail); rec_ok {
				if self_terms, terms_ok := output.condition_terms_of_field(stream.file, described, "slot", .Not_Equal, own_slot, "", false); terms_ok {
					terms_bytes := transmute([size_of(output.Condition_Terms)]u8)self_terms
					if resolved, _, resolved_ok := output.writer_condition_of_terms(terms_bytes[:], stream.file, described); resolved_ok {
						resolved_bytes := transmute([size_of(output.Writer_Condition)]u8)resolved
						if checked, checked_ok := output.writer_condition_check(resolved_bytes[:], u32(stream.size)); checked_ok {
							stream.conditions[0] = {field = "slot", comparison = .Not_Equal, compared = own_slot}
							stream.terms[0] = self_terms
							stream.checks[0] = checked
							stream.condition_count = 1
						}
					}
				}
			}
		}
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
	breaker := console_stream.follow_loop_breaker_make(stream.is_log_follow ? console_own_process_slot() : 0)
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
			if item.kind == .Record {
				if stream.is_log_follow {
					row_slot, row_proc := follow_row_slot_and_process(record[:stream.size])
					if console_stream.follow_filter_record(&breaker, record[:stream.size], row_slot, row_proc) != .Pass {
						continue
					}
				}
				if stream_passes(stream, record[:stream.size]) {
					stream_row_write(stream, record[:stream.size], table_memory[start + kept * row_size:][:row_size])
					kept += 1
				}
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
	columns := [5]Column{integer_column("written"), integer_column("discarded"), integer_column("refused"), integer_column("held"), integer_column("rings_past_gap")}
	table, made := made_table("Writer_Counts", columns[:])
	if !made {
		return fail("stream_counts: the line has no room for the description")
	}
	row := made_row(&table)
	made_integer(&table, row, 0, i64(min(counts.written, u64(max(i64)))))
	made_integer(&table, row, 1, i64(min(counts.discarded, u64(max(i64)))))
	made_integer(&table, row, 2, i64(min(counts.refused, u64(max(i64)))))
	made_integer(&table, row, 3, i64(min(counts.held, u64(max(i64)))))
	made_integer(&table, row, 4, i64(min(counts.rings_past_gap, u64(max(i64)))))
	return made_record(&table, "stream_counts")
}

// stream_note_draw draws one note of a Stream: its joined record, a gap,
// its end, Escape. A joined record of 0 draws nothing.
stream_note_draw :: proc "contextless" (note: console_stream.Note, breaker: ^console_stream.Follow_Loop_Breaker = nil) {
	buffer: [160]u8
	writer := sentence.Writer {
		buffer = buffer[:],
	}
	if !console_stream.note_write(&writer, note) {
		return
	}
	system.lock(&output_lock)
	defer system.unlock(&output_lock)
	guard: console_stream.Follow_Render_Guard
	if breaker != nil {
		guard = console_stream.follow_render_begin(breaker, &output_logged)
	}
	defer if breaker != nil {
		console_stream.follow_render_end(breaker, guard, &output_logged)
	}
	sink := result_sink()
	console_results.draw_note(&sink, sentence.written(&writer))
	output_continuation = 0
}

// stream_draw draws a Stream at the end of a line: the head of its
// columns, then each record that passes its conditions as it comes, until
// the end of the stream or Escape. The output lock is held for one line at
// a time, never while the read waits: the thread of the keys draws its
// line meanwhile. When drawing log.follow, Follow_Loop_Breaker suppresses
// echoing drawn lines into the kernel log and drops self-emitted records.
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
	breaker := console_stream.follow_loop_breaker_make(stream.is_log_follow ? console_own_process_slot() : 0)
	active_breaker: ^console_stream.Follow_Loop_Breaker = stream.is_log_follow ? &breaker : nil
	{
		system.lock(&output_lock)
		defer system.unlock(&output_lock)
		guard: console_stream.Follow_Render_Guard
		if active_breaker != nil {
			guard = console_stream.follow_render_begin(active_breaker, &output_logged)
		}
		defer if active_breaker != nil {
			console_stream.follow_render_end(active_breaker, guard, &output_logged)
		}
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
			stream_note_draw({kind = .Escape, count = drawn}, active_breaker)
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
				if active_breaker != nil {
					row_slot, row_proc := follow_row_slot_and_process(record[:stream.size])
					if console_stream.follow_filter_record(active_breaker, record[:stream.size], row_slot, row_proc) != .Pass {
						continue
					}
				}
				if stream_passes(stream, record[:stream.size]) {
					stream_row_write(stream, record[:stream.size], row[:row_size])
					system.lock(&output_lock)
					guard: console_stream.Follow_Render_Guard
					if active_breaker != nil {
						guard = console_stream.follow_render_begin(active_breaker, &output_logged)
					}
					sink := result_sink()
					console_results.draw_stream_row(&sink, &columns, row[:row_size])
					output_continuation = 0
					if active_breaker != nil {
						console_stream.follow_render_end(active_breaker, guard, &output_logged)
					}
					system.unlock(&output_lock)
					drawn += 1
				}
			case .Joined:
				stream_note_draw({kind = .Joined, count = u64(item.serial)}, active_breaker)
			case .Gap:
				stream_note_draw({kind = .Gap, count = u64(item.gap_count)}, active_breaker)
			case .End:
				// An end comes with the status Ended.
			}
		case .Ended:
			switch {
			case item.end_word != .None:
				stream_note_draw({kind = .Ended_By, end_word = item.end_word}, active_breaker)
			case item.error.kind == 0:
				stream_note_draw({kind = .Clean_End, count = u64(item.serial)}, active_breaker)
			case:
				stream_note_draw({kind = .Error_End, count = u64(item.serial)}, active_breaker)
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
	if from.is_log && from.condition_count > 0 {
		return fail("wire: the record output log takes no condition")
	}
	if from.condition_count > 1 {
		return fail("wire: a wiring takes one condition; the record stream ", from.owner, ".", from.stream_name, " has ", u64(from.condition_count))
	}
	if from.owner == to.owner {
		return fail("wire: ", from.owner, " is at both ends: a wiring joins two processes")
	}
	// A generic record input takes the record of its wiring: the root
	// service checks it against the type that the first wiring fixed.
	difference, part := output.Description_Difference.Equal, u32(0)
	if to.detail != 0 {
		difference, part = output.record_descriptions_compare(from.file, from.detail, to.file, to.detail)
	}
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
// the name in the module file of the end; for the child's implicit log output,
// is_log is true and index is 0.
@(private = "file")
start_end_of :: proc "contextless" (number: int, module_name: string, child_file: []u8, owner_name, stream_name: string, is_child, is_input: bool) -> (owner: Stream_Owner, index: u32, is_log: bool, ok: bool) {
	if !is_input && stream_name == console_stream.LOG_STREAM_NAME {
		if !is_child {
			fail("start: the row ", u64(number), " names ", owner_name, ".log, and only the log of the module that starts can be wired")
			return {}, 0, false, false
		}
		return {name = module_name, end = .Child}, 0, true, true
	}
	file := child_file
	if !is_child {
		found: bool
		owner, found = stream_owner_find(owner_name, true)
		if !found {
			fail("start: the row ", u64(number), " names ", owner_name, ", which is no process that this console started or connected and no module")
			return {}, 0, false, false
		}
		if owner.end == .Child {
			not_running_fail("start", owner_name)
			return {}, 0, false, false
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
	// A generic end is a row too: the root service fixes and checks its
	// record.
	if how != .Found && how != .Generic {
		stream_names_fail(owner_name, stream_name, file)
		return {}, 0, false, false
	}
	return owner, index, false, true
}

// start_row_type gives the record that the writer of a row writes: the
// record of its record output, Log_Output_Record for log, or for a generic
// one the record that a list of this console fixed for its owner.
@(private = "file")
start_row_type :: proc "contextless" (owner: Stream_Owner, index: u32, child_file: []u8, is_child: bool, is_log: bool) -> (file: []u8, detail: u32) {
	if is_log {
		desc := log_output_description_file()
		if len(desc) > 0 {
			return desc, output.DESCRIPTION_RECORD_INDEX
		}
		return nil, 0
	}
	file = is_child ? child_file : owner.file
	value, _, _, ok := module.record_output(file, index)
	if !ok {
		return nil, 0
	}
	if value.record != 0 {
		return file, value.record
	}
	return owner.generic_file, owner.generic_detail
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
	fixed_file: []u8
	fixed_detail: u32
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
		writer_owner, writer_index, writer_is_log, writer_ok := start_end_of(index + 1, child_name, child_file, writer, module.field_text(row, items[WIRING_COLUMN_OUTPUT]), writer_is_child, false)
		if !writer_ok {
			return {}
		}
		reader_owner, reader_index, _, reader_ok := start_end_of(index + 1, child_name, child_file, reader, module.field_text(row, items[WIRING_COLUMN_INPUT]), reader_is_child, true)
		if !reader_ok {
			return {}
		}
		planned.writer_owner, planned.reader_owner = writer_owner, reader_owner
		writer_stream := writer_is_log ? output.Writer_Stream.Log : output.Writer_Stream.Record_Output
		planned.row = {writer_end = u32(writer_owner.end), writer_stream = u32(writer_stream), writer_index = writer_index, reader_end = u32(reader_owner.end), reader_index = reader_index}
		// The first row to the generic record input of the module, of the
		// counts One or Many, fixes its record, as the root service does:
		// its generic record output then reads as that record.
		if reader_is_child && fixed_file == nil {
			if input, wirings, _, _, input_ok := module.record_input(child_file, reader_index); input_ok && input.record == 0 && wirings != .Many_Types {
				fixed_file, fixed_detail = start_row_type(writer_owner, writer_index, child_file, writer_is_child, writer_is_log)
			}
		}
		handle_count += int(writer_owner.end == .Started) + int(reader_owner.end == .Started)
		if field := module.field_integer(row, items[WIRING_COLUMN_FIELD]); field != 0 {
			if writer_is_log {
				return fail("start: the row ", u64(index + 1), " puts a condition on log, which takes no condition")
			}
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
	process := system.Handle(completion.values[0])
	if !stream_owner_keep(name, process) {
		return fail("start: ", name, " runs, and has no typed name: the console names the record outputs of ", u64(STREAM_OWNER_CAPACITY), " processes that it started at most, until one of them stops")
	}
	if fixed_file != nil {
		for &owner in stream_owners {
			if owner.process == process {
				owner.generic_file, owner.generic_detail = fixed_file, fixed_detail
			}
		}
	}
	return {}
}
