package console

import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:system"
import terminal "modus:terminal"

// The log records of a line.
//
// While a line calls an export, the console shows under the line the log
// records that the called process writes: grouped by process, with each
// value in the color of its value kind, as the window of the log draws
// them (docs/CONSOLE.md, "The log records of a line").
//
// The console has no grant to read the memory of the log. It reads the
// records as any caller that acts for the principal does: it calls the
// exports `records` and `value_runs` of the service `log`, through a
// connection that the root service gives. With no service `log`, or with a
// refusal, a line shows no record: the console gets no other access.
//
// Which records: those that a process called by the line wrote, from the
// first call of the line on. A module that `load` put in the console
// writes as the console. The lines go to the terminal only: the records are
// in the log already.

LINE_RECORD_SERVICE :: "log" // The service that serves the log records.
LINE_RECORD_BATCH :: 32 // The records that the console draws from one answer of the service.
LINE_RECORD_ANSWERS :: 8 // The most answers that the console reads at one time: a process that writes faster keeps its records in the log.
LINE_RECORD_PROCESSES :: 4 // The processes that one line follows.
// Hang bound for an answer from the log service; a stopped service ends the
// wait immediately (src/md/api/call_ring_ready.md).
LINE_RECORD_ANSWER_LIMIT :: system.ANSWER_BOUND_MILLISECONDS
LINE_RECORD_INDENT :: 4 // The column of the text of a record.

Line_Records :: struct {
	file:        []u8, // The file of the log service in the boot image: the descriptions of its exports.
	file_hash:   [32]u8,
	records:     module.Function,
	records_export: u32,
	value_runs:  module.Function,
	value_runs_export: u32,
	fact_records: module.Function,
	fact_records_export: u32,
	next:        u64, // The number of the first log record that the console did not read.
	marked:      bool, // The line called a process: next is the first record of the line.
	unavailable: bool, // The service gave no answer for this line.
	refused:     bool, // The root service gave no connection: the console asks again after a start or a connect.
	processes:    [LINE_RECORD_PROCESSES]string, // The processes that the line called.
	process_count: int,
	// The group of the last record that the console drew: a record of the
	// same process needs no new head.
	head_process: [32]u8,
	head_drawn:   bool,
	rows:        [LINE_RECORD_BATCH * module.RECORD_SIZE_LIMIT]u8, // The rows of one answer that the console draws.
	// The facts of the rows of one answer, out of the call region: the call
	// of value_runs writes over it.
	facts:       [LINE_RECORD_BATCH]Line_Fact,
	fact_count:  int,
}

// What the console shows for one record of a fact.
Line_Fact_State :: enum u8 {
	Waits  = 0, // A record of a fact before its last: nothing, and the line goes on.
	Whole  = 1, // The last record of a fact: the sentence of the whole fact.
	Broken = 2, // A record of a fact that the console cannot join: its part, raw, after the mark.
}

// One record of a fact of the rows that the console draws: what the render
// needs. The last record of a whole fact holds the values of each of its
// records, joined.
Line_Fact :: struct {
	number:     i64,
	hash:       [32]u8,
	key:        u64,
	state:      Line_Fact_State,
	part:       int,
	part_count: int,
	count:      int, // The value bytes of the record, or of the whole fact for Whole.
	values:     [op.LOG_FACT_VALUES_MOST]u8,
}

line_records: Line_Records
// The join of the facts of one read of the records of a line: not on the
// stack, it holds the values of a whole fact.
line_records_join: op.Log_Fact_Join

// line_records_start forgets the calls of the line before.
line_records_start :: proc "contextless" () {
	line_records.marked, line_records.unavailable, line_records.process_count, line_records.head_drawn = false, false, 0, false
}

// line_records_try_again lets the console ask for the connection again: a
// process started, or a service was connected.
line_records_try_again :: proc "contextless" () {
	line_records.refused = false
}

// line_records_sandbox gives the connection to the log service, or nil.
line_records_sandbox :: proc "contextless" () -> (found: ^Sandbox, number: int) {
	for &sandbox, index in sandboxes {
		if sandbox.service && sandbox.name == LINE_RECORD_SERVICE {
			return &sandbox, index + 1
		}
	}
	return nil, 0
}

// line_records_connect gives a connection to the log service that runs:
// the one that connect("log") made, or one that the console asks for
// itself, with no command. false: no service, or the root service refused.
line_records_connect :: proc "contextless" () -> bool {
	sandbox, _ := line_records_sandbox()
	if sandbox == nil {
		if line_records.refused {
			return false
		}
		place, _ := sandbox_free()
		if place == nil {
			return false
		}
		place^ = {
			name    = LINE_RECORD_SERVICE,
			service = true,
			quiet   = true,
		}
		sandbox = place
	}
	if sandbox.process == 0 {
		if line_records.refused {
			return false
		}
		if service_connect(sandbox) != .Succeeded {
			// A connection of the console itself that the root service
			// refuses leaves no place taken.
			if sandbox.quiet {
				sandbox^ = {}
			}
			line_records.refused = true
			return false
		}
	}
	// The descriptions of the two exports, from the file that the root
	// service named by its hash.
	if line_records.file == nil || line_records.file_hash != sandbox.hash {
		line_records.file = nil
		entry := system.image_entry_of(image, sandbox.hash)
		if entry == nil {
			return false
		}
		file := image[entry.offset:][:entry.size]
		if module.validate(file) != .None {
			return false
		}
		records_export := module.export_find(file, "records")
		value_runs_export := module.export_find(file, "value_runs")
		fact_records_export := module.export_find(file, "fact_records")
		records, has_records := module.function(file, records_export)
		value_runs, has_value_runs := module.function(file, value_runs_export)
		fact_records, has_fact_records := module.function(file, fact_records_export)
		if records_export == 0 || value_runs_export == 0 || fact_records_export == 0 || !has_records || !has_value_runs || !has_fact_records {
			return false
		}
		if records.parameter_count != 1 || value_runs.parameter_count != 1 || fact_records.parameter_count != 1 || records.result != u8(module.Type.Table) || value_runs.result != u8(module.Type.Table) || fact_records.result != u8(module.Type.Table) {
			return false
		}
		line_records.file, line_records.file_hash = file, sandbox.hash
		line_records.records, line_records.records_export = records, records_export
		line_records.value_runs, line_records.value_runs_export = value_runs, value_runs_export
		line_records.fact_records, line_records.fact_records_export = fact_records, fact_records_export
	}
	return true
}

// line_records_ask calls one export of the log service with the number of
// a log record, and gives the rows of its table: they are in the call
// region, until the next call. total is the count of the rows of the full
// answer. The service wrote the rows and the count: the console reads no
// more than the buffer, and reads each row with the description.
line_records_ask :: proc "contextless" (function: module.Function, export: u32, after: u64) -> (table: Value, total: u64, ok: bool) {
	sandbox, _ := line_records_sandbox()
	if sandbox == nil || sandbox.process == 0 {
		return {}, 0, false
	}
	arguments := [1]isolated.Argument{{integer = after}}
	offset, size, buffer, encoded := isolated.encode(line_records.file, function, arguments[:], sandbox.region)
	if !encoded {
		return {}, 0, false
	}
	sandbox.calls += 1
	if !system.send(&sandbox.ring.commands, ring.Record{kind = export, tag = sandbox.calls, values = {0 = offset, 1 = size}}) {
		return {}, 0, false
	}
	limit := system.time() + LINE_RECORD_ANSWER_LIMIT
	for {
		wait := system.wait_begin()
		for _ in 0 ..< ring.CAPACITY {
			completion, has_completion := system.receive(&sandbox.ring.completions)
			if !has_completion {
				break
			}
			if completion.tag != sandbox.calls {
				continue
			}
			// A refusal, a failure and an unreadable outcome word end the
			// read alike.
			value, outcome, _ := isolated.answer_of_completion(completion)
			if outcome != .Succeeded {
				return {}, 0, false
			}
			described, has_record := module.record_type(line_records.file, function.result_detail)
			if !has_record {
				return {}, 0, false
			}
			rows, _ := isolated.result_table(sandbox.region, buffer, u64(value), u64(described.size))
			return {kind = .Table, record = rows, file = line_records.file, detail = function.result_detail}, u64(value), true
		}
		if state, _, _ := system.process_state(sandbox.process); state == .Stopped {
			return {}, 0, false
		}
		system.wait_records(&wait, &sandbox.ring.completions)
		if system.wait_end(&wait, limit) >= limit {
			return {}, 0, false
		}
	}
}

// line_records_call_begins notes that the line calls a process now. At the
// first call of a line, the console finds the number of the next log
// record: the records before it are not records of the line.
line_records_call_begins :: proc "contextless" (process: string) {
	// The console reads the records through the log service: it does not
	// call it while the line calls it.
	if process == LINE_RECORD_SERVICE || line_records.unavailable {
		return
	}
	known := false
	for name in line_records.processes[:line_records.process_count] {
		known ||= name == process
	}
	if !known && line_records.process_count < LINE_RECORD_PROCESSES {
		line_records.processes[line_records.process_count] = process
		line_records.process_count += 1
	}
	if line_records.marked {
		return
	}
	line_records.marked = true
	if !line_records_connect() {
		line_records.unavailable = true
		return
	}
	// The count of the rows from a number on is the count of the records
	// that the log has from it: the next record has the number after them.
	for _ in 0 ..< LINE_RECORD_ANSWERS {
		answer, total, ok := line_records_ask(line_records.records, line_records.records_export, line_records.next)
		table, valid := table_of(answer)
		if !ok {
			line_records.unavailable = true
			return
		}
		if !valid || table.rows == 0 || total == 0 {
			return
		}
		number, has_number := table_field(table, "number")
		if !has_number {
			line_records.unavailable = true
			return
		}
		first := u64(max(module.field_integer(table_row(table, answer, 0), number), 0))
		reached := first + total
		if reached <= line_records.next {
			return
		}
		line_records.next = reached
	}
}

// line_records_follows says if the line called a process with a name.
line_records_follows :: proc "contextless" (process: string) -> bool {
	for name in line_records.processes[:line_records.process_count] {
		if name == process {
			return true
		}
	}
	return false
}

// line_records_show_during shows the new records while a call waits for
// its process. active: the sandbox of the call; the console does not use
// the connection of a call that runs.
line_records_show_during :: proc "contextless" (active: int) {
	if _, number := line_records_sandbox(); number == active {
		return
	}
	line_records_show()
}

// line_records_show reads the log records that came since the last read,
// and draws those of the processes that the line called.
line_records_show :: proc "contextless" () {
	if !line_records.marked || line_records.unavailable || line_records.process_count == 0 {
		return
	}
	for _ in 0 ..< LINE_RECORD_ANSWERS {
		answer, total, ok := line_records_ask(line_records.records, line_records.records_export, line_records.next)
		if !ok {
			line_records.unavailable = true
			return
		}
		table, valid := table_of(answer)
		if !valid || table.rows == 0 || table.size > module.RECORD_SIZE_LIMIT {
			return
		}
		number, has_number := table_field(table, "number")
		process, has_process := table_field(table, "process")
		runs, has_runs := table_field(table, "runs")
		if !has_number || !has_process || !has_runs {
			line_records.unavailable = true
			return
		}
		// The rows of the processes of the line, out of the call region:
		// the next call writes over it.
		kept := 0
		taken := 0
		with_runs := false
		for index in 0 ..< table.rows {
			if kept == LINE_RECORD_BATCH {
				break
			}
			row := table_row(table, answer, index)
			taken += 1
			line_records.next = max(line_records.next, u64(max(module.field_integer(row, number), 0)) + 1)
			if !line_records_follows(module.field_text(row, process)) {
				continue
			}
			copy(line_records.rows[kept * table.size:][:table.size], row)
			with_runs ||= module.field_integer(row, runs) > 0
			kept += 1
		}
		if kept > 0 {
			kept_rows := Value{kind = .Table, record = line_records.rows[:kept * table.size], file = answer.file, detail = answer.detail}
			line_records_draw(table, kept_rows, kept, with_runs)
		}
		if taken == table.rows && total <= u64(table.rows) {
			return
		}
	}
}

// line_records_facts_read keeps the facts of the rows that the console
// draws: it asks the service for the facts from the first such row on,
// and keeps the facts whose numbers the rows have, out of the call region.
line_records_facts_read :: proc "contextless" (table: Table, kept_rows: Value, kept: int, number, form: module.Field) {
	line_records.fact_count = 0
	first, last := i64(-1), i64(-1)
	for index in 0 ..< kept {
		row := table_row(table, kept_rows, index)
		if module.field_integer(row, form) != i64(op.Log_Record_Form.Fact) {
			continue
		}
		row_number := module.field_integer(row, number)
		first = first < 0 ? row_number : min(first, row_number)
		last = max(last, row_number)
	}
	if first < 0 {
		return
	}
	after := u64(first)
	// The join of the records of a fact of several records, in the order
	// of their numbers (op.log_fact_join_take), and the first kept item of
	// the open fact.
	join := &line_records_join
	join^ = {}
	join_first_item := 0
	// The read stopped at its page: a record of the scope after the last
	// row that the console draws, or the count of answers. An open fact
	// then goes on past the page; else its next record is lost.
	stopped_at_page := false
	answers: for answer_index in 0 ..< LINE_RECORD_ANSWERS {
		answer, total, ok := line_records_ask(line_records.fact_records, line_records.fact_records_export, after)
		answer_table, valid := table_of(answer)
		if !ok || !valid || answer_table.rows == 0 {
			break answers
		}
		fields, fields_ok := fact_row_fields(answer_table)
		if !fields_ok {
			break answers
		}
		reached := i64(after)
		for index in 0 ..< answer_table.rows {
			row := table_row(answer_table, answer, index)
			fact_number := module.field_integer(row, fields.number)
			reached = max(reached, fact_number)
			hash := module.field_bytes(row, fields.module_hash)
			values := module.field_bytes(row, fields.values)
			count := module.field_integer(row, fields.value_count)
			if fact_number > last {
				stopped_at_page = true
				continue
			}
			if len(hash) != 32 || values == nil || count < 0 || count > i64(len(values)) {
				continue
			}
			// A row of fact_records names no process: the writer is 0 for
			// each. The records of one fact have numbers that follow each
			// other in one numbering, which the kernel writes under one
			// lock, so a number with no gap says that no record of
			// another process came between them.
			part := op.Log_Fact_Part {
				number     = u64(max(fact_number, 0)),
				key        = u64(module.field_integer(row, fields.key)),
				part       = int(module.field_integer(row, fields.part)),
				part_count = int(module.field_integer(row, fields.part_count)),
				values     = values[:count],
			}
			copy(part.module_hash[:], hash)
			was_open := join.open
			whole, fault := op.log_fact_join_take(join, part)
			if fault != .None && was_open {
				for &broken in line_records.facts[join_first_item:line_records.fact_count] {
					broken.state = .Broken
				}
			}
			if join.open && part.part == 0 {
				join_first_item = line_records.fact_count
			}
			if line_records.fact_count == LINE_RECORD_BATCH || !line_records_has_number(table, kept_rows, kept, number, fact_number) {
				continue
			}
			item := &line_records.facts[line_records.fact_count]
			item.number, item.key, item.part, item.part_count = fact_number, part.key, part.part, part.part_count
			item.hash = part.module_hash
			switch {
			case whole:
				item.state, item.count = .Whole, join.value_count
				copy(item.values[:], join.values[:join.value_count])
			case join.open:
				item.state, item.count = .Waits, int(count)
				copy(item.values[:], values[:count])
			case:
				item.state, item.count = .Broken, int(count)
				copy(item.values[:], values[:count])
			}
			line_records.fact_count += 1
		}
		if u64(answer_table.rows) >= total {
			break answers
		}
		if reached >= last || answer_index == LINE_RECORD_ANSWERS - 1 {
			stopped_at_page = true
			break answers
		}
		after = u64(max(reached, 0)) + 1
	}
	line_records_join_end(join, join_first_item, stopped_at_page)
}

// line_records_join_end ends the join of a read: a fact that is still open
// when the read had no record after it lost its next record, and each of
// its records shows raw after the mark, never nothing. A read that stopped
// at its page keeps the fact open: its next record is past the rows that
// the console draws.
line_records_join_end :: proc "contextless" (join: ^op.Log_Fact_Join, first_item: int, stopped_at_page: bool) {
	if op.log_fact_join_end(join, stopped_at_page) == .None {
		return
	}
	for &broken in line_records.facts[min(first_item, line_records.fact_count):line_records.fact_count] {
		broken.state = .Broken
	}
}

// line_records_has_number says if the rows that the console draws hold a
// record of a number.
line_records_has_number :: proc "contextless" (table: Table, kept_rows: Value, kept: int, number: module.Field, wanted: i64) -> bool {
	for index in 0 ..< kept {
		if module.field_integer(table_row(table, kept_rows, index), number) == wanted {
			return true
		}
	}
	return false
}

// line_records_fact gives the fact of a record that the console keeps, or
// nil when the service did not give it.
line_records_fact :: proc "contextless" (record_number: i64) -> ^Line_Fact {
	for &item in line_records.facts[:line_records.fact_count] {
		if item.number == record_number {
			return &item
		}
	}
	return nil
}

// line_records_draw draws records of one answer: for each process, in the
// order of its first record, one head line and its records. A fact is its
// sentence, or its raw form (facts.odin). With runs, the console asks the
// service for the value runs of the records from the first one on, after
// the facts: each answer writes over the call region.
line_records_draw :: proc "contextless" (table: Table, kept_rows: Value, kept: int, with_runs: bool) {
	number, _ := table_field(table, "number")
	process, _ := table_field(table, "process")
	level, has_level := table_field(table, "level")
	form, has_form := table_field(table, "form")
	text, has_text := table_field(table, "text")
	continues, has_continues := table_field(table, "continues")
	if !has_level || !has_form || !has_text || !has_continues {
		return
	}
	line_records_facts_read(table, kept_rows, kept, number, form)
	run_rows: Value
	run_table: Table
	has_run_table := false
	if with_runs {
		first := u64(max(module.field_integer(table_row(table, kept_rows, 0), number), 0))
		if answer, _, ok := line_records_ask(line_records.value_runs, line_records.value_runs_export, first); ok {
			run_rows = answer
			run_table, has_run_table = table_of(answer)
		}
	}
	system.lock(&output_lock)
	defer system.unlock(&output_lock)
	// The records are in the log already: these lines go to the terminal
	// only.
	output_logged = false
	defer output_logged = true
	drawn: [LINE_RECORD_BATCH]bool
	for first in 0 ..< kept {
		if drawn[first] {
			continue
		}
		first_row := table_row(table, kept_rows, first)
		group_process := module.field_text(first_row, process)
		if !line_records.head_drawn || system.name_of(line_records.head_process[:]) != group_process {
			line_records.head_process = {}
			copy(line_records.head_process[:len(line_records.head_process) - 1], group_process)
			line_records.head_drawn = true
			output_continuation = LINE_RECORD_INDENT
			emit("  ", {})
			emit(group_process, value_kind_style(.Module))
			emit_end()
		}
		open := false // The text of the record before goes on in this one.
		for index in first ..< kept {
			row := table_row(table, kept_rows, index)
			if drawn[index] || module.field_text(row, process) != group_process {
				continue
			}
			drawn[index] = true
			plain: terminal.Style
			if module.field_integer(row, level) == i64(op.Log_Level.Error) {
				plain.tone = u8(terminal.Tone.Bad)
			}
			output_continuation = LINE_RECORD_INDENT
			if !open {
				emit("    ", {})
			}
			if module.field_integer(row, form) == i64(op.Log_Record_Form.Fact) {
				// A fact is its sentence in the place of its last record,
				// and the line ends there.
				fact := line_records_fact(module.field_integer(row, number))
				if fact == nil {
					emit("a log fact whose values the service log did not give", {tone = u8(terminal.Tone.Dim)})
					open = false
					emit_end()
					continue
				}
				switch fact.state {
				case .Waits:
					open = true
					continue
				case .Whole:
					fact_emit(fact.hash, fact.key, fact.values[:fact.count], plain)
				case .Broken:
					emit(op.LOG_FACT_JOIN_BROKEN_MARK, {tone = u8(terminal.Tone.Dim)})
					fact_part_raw_emit(fact.hash, fact.key, fact.part, fact.part_count, fact.values[:fact.count], plain)
				}
				open = false
				emit_end()
				continue
			}
			record_text := module.field_text(row, text)
			place := 0
			if has_run_table {
				place = line_records_runs_emit(run_table, run_rows, module.field_integer(row, number), record_text, plain)
			}
			emit(record_text[place:], plain)
			open = module.field_integer(row, continues) != 0
			if !open {
				emit_end()
			}
		}
		if open {
			emit_end()
		}
	}
	output_continuation = 0
}

// line_records_runs_emit writes the text of a record up to the end of its
// last value run: each run in the color of its value kind, the text
// between two runs plain. It gives the count of the bytes that it wrote.
// A run that is not in the text after the run before it is not drawn: the
// service wrote the rows.
line_records_runs_emit :: proc "contextless" (run_table: Table, run_rows: Value, record_number: i64, record_text: string, plain: terminal.Style) -> (place: int) {
	number, has_number := table_field(run_table, "number")
	start_field, has_start := table_field(run_table, "start")
	length_field, has_length := table_field(run_table, "length")
	kind_field, has_kind := table_field(run_table, "kind")
	if !has_number || !has_start || !has_length || !has_kind {
		return 0
	}
	for index in 0 ..< run_table.rows {
		row := table_row(run_table, run_rows, index)
		of_record := module.field_integer(row, number)
		// The rows are in the order of the records.
		if of_record > record_number {
			break
		}
		if of_record != record_number {
			continue
		}
		start_value, length_value := module.field_integer(row, start_field), module.field_integer(row, length_field)
		if start_value < i64(place) || length_value < 1 || start_value > i64(len(record_text)) || length_value > i64(len(record_text)) - start_value {
			continue
		}
		start, length := int(start_value), int(length_value)
		kind := value_kinds.Value_Kind.None
		kind_name := module.field_text(row, kind_field)
		for candidate in value_kinds.Value_Kind {
			if candidate != .None && value_kinds.VALUE_KIND_NAMES[candidate] == kind_name {
				kind = candidate
			}
		}
		emit(record_text[place:start], plain)
		emit(record_text[start:start + length], kind == .None ? plain : value_kind_style(kind))
		place = start + length
	}
	return place
}
