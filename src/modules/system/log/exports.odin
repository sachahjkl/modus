package log

import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/log_scope"
import "modus:contract/value_kinds"
import op "modus:contract/operation"
import "modus:support/system"
import "base:intrinsics"

// The log is also a service: records() gives the log records as a table of
// records with typed fields, so that a reader checks the
// process and the level of a record, not a line of text. The
// serial port keeps the same records as lines: it works before any service
// runs, and when the network does not.
//
// The records of the log are facts of all the processes, and a process sees
// no other process: the exports give the whole log only to a caller that
// acts for the principal, and to each other caller its own records, by the
// process slot and the process serial that the root service wrote in the
// grant of its connection (modus:contract/log_scope). A starter also reads
// the records of a child: it lends the process handle of the child, which
// is what lets it see that child. This process holds the memory of the
// log, so it makes the choice: a reader never maps that memory
// (src/md/features/log_reader_scope.md). The whole log is the ring of that
// memory. The records of one process, the own records of a caller or the
// records of a lent child, come from the own log ring of that process,
// which the kernel copies for the holder of that memory (Log_Read): the
// records of other processes never push them out
// (src/md/features/own_log_ring.md).

// One row of the log: records(). A row has 256 bytes, the most that a
// record of a description has, and holds one log record: its text has the
// 168 bytes of the text of a log record. A row says that its text goes on in
// the next row (continues), as a log record says that its text goes on in
// the next log record (Log_Record.more). The level and the form are members
// of contract enums, so a reader compares a member and parses no text
// (src/md/features/log_facts.md, "The reader path").
Record :: struct {
	number:    i64, // The number of the log record, from 0.
	time:      i64, // Microseconds since the start of the machine.
	process:   [32]u8, // The name of the process, or "kernel".
	slot:      i64, // The slot of the process. 0: the kernel.
	level:     op.Log_Level, // Info, Debug, Warning or Error.
	form:      op.Log_Record_Form, // Text, or Fact: fact_records() gives the fact, and the text is empty.
	lost:      i64, // The first row only: the log records after `after` that the kernel wrote over before this call read them.
	continues: i64, // 1: the text goes on in the next row.
	runs:      i64, // The count of the value runs of the text: value_runs() gives them.
	text:      [168]u8, // op.LOG_TEXT_CAPACITY: the tool that reads the descriptions needs the number.
}
#assert(size_of(Record) == 256)
#assert(offset_of(Record, lost) == 64)
#assert(op.LOG_TEXT_CAPACITY == 168)

// One value run of a log record: value_runs(). It says that the bytes start ..<
// start + length of the text of the record `number` are a value of the
// kind `kind`: number, size, time, module, version, status...
Value_Run :: struct {
	number: i64, // The number of the log record.
	start:  i64, // From 0, in bytes of the text of the record.
	length: i64, // In bytes, at least 1.
	kind:   [16]u8, // The name of the value kind, as the site names it.
}

service: system.Service
reader_head: ^op.Log_Head
reader_records: [^]op.Log_Record
log_memory: system.Handle // The memory of the log: the whole log, and the authority of Log_Read.

// The copy of the own log ring of a caller. The service answers one call
// at a time, on its one thread, so one copy serves each call.
own_copy: [op.OWN_LOG_RECORD_CAPACITY]op.Log_Record

// own_records_read copies the own log ring of the process of a scope from
// the own number `after` on: the records, the own records from `after` that
// the ring no longer keeps, and the records of the ring from the first one
// to the last one. A scope that names no process, and a process that has
// no ring now, give none.
own_records_read :: proc "contextless" (scope: log_scope.Scope, after: i64) -> (copies: []op.Log_Record, lost: u64, total: u64) {
	if !log_scope.reads_own_records(scope) {
		return nil, 0, 0
	}
	// An own number has 32 bits: `after` counts modulo 2^32.
	own_after := u64(u32(max(after, 0)))
	results, status := system.call(.Log_Read, u64(log_memory), scope.process, scope.process_serial, own_after, u64(uintptr(&own_copy[0])), u64(len(own_copy)))
	if status != .Ok {
		return nil, 0, 0
	}
	return own_copy[:int(min(results[0], u64(len(own_copy))))], results[1], results[2]
}

// row_fill writes the row of a record with its number: the number in the
// whole log, or the own number for a reader of its own records. A fact has
// no text and no runs: its bytes are not text, and fact_records gives them.
// The form and the level pass their borders before this call
// (record_borders): the caller gives no row for a record whose form or
// level names no member, and counts it as lost, as a torn record, because
// no reader can read its bytes.
row_fill :: proc "contextless" (row: ^Record, number: i64, record: ^op.Log_Record, form: op.Log_Record_Form, level: op.Log_Level) {
	row^ = {number = number, time = i64(record.time), slot = i64(record.process), level = level, form = form}
	copy(row.process[:len(row.process) - 1], system.name_of(record.name[:]))
	switch form {
	case .Text:
		text_count := min(int(record.text_count), len(record.text))
		copy(row.text[:], record.text[:text_count])
		row.continues = record.more != 0 ? 1 : 0
		row.runs = i64(min(int(record.run_count), len(record.runs)))
	case .Fact:
	}
}

// record_borders reads the form and the level of a record through their
// borders: the record is in memory that the kernel writes, and a byte of
// it becomes an enum at this one place. ok is false when either byte names
// no member.
record_borders :: proc "contextless" (record: ^op.Log_Record) -> (form: op.Log_Record_Form, level: op.Log_Level, ok: bool) {
	form = op.log_record_form(record) or_return
	level = enum_word.member_of_word(op.Log_Level, u64(transmute(u8)record.level)) or_return
	return form, level, true
}

// runs_add adds the rows of the value runs of a record with its number,
// and counts each run, also the ones that do not fit in the result.
runs_add :: proc "contextless" (number: i64, record: ^op.Log_Record, result: ^[]Value_Run, total: ^int, count: ^int) {
	text_count := min(int(record.text_count), len(record.text))
	for index in 0 ..< min(int(record.run_count), len(record.runs)) {
		run := record.runs[index]
		start, end, kind, ok := value_kinds.value_run_in_text(run, text_count)
		if !ok {
			continue
		}
		total^ += 1
		if count^ < len(result^) {
			row := &result[count^]
			row^ = {number = number, start = i64(start), length = i64(end - start)}
			copy(row.kind[:], value_kinds.VALUE_KIND_NAMES[kind])
			count^ += 1
		}
	}
}

// record_copy copies the record `number` of the whole log, and says if the
// copy is whole: the kernel did not start to write over it during the copy
// (op.log_copy_kept). The fence keeps each load of the copy before the
// second load of `written`.
record_copy :: proc "contextless" (number: u64) -> (record: op.Log_Record, whole: bool) {
	record = reader_records[number % op.LOG_RECORD_CAPACITY]
	intrinsics.atomic_thread_fence(.Acquire)
	return record, op.log_copy_kept(number, intrinsics.atomic_load(&reader_head.written))
}

// caller_scope gives the log scope of the caller of the export that runs.
// With no connection (a call of this process itself), the whole log.
caller_scope :: proc "contextless" () -> log_scope.Scope {
	caller := system.service_caller()
	if caller == nil {
		return {whole_log = true}
	}
	return log_scope.scope_of(caller.grant)
}

// The result of an export that fails: the error record says why.
ERROR :: -1

// The parameter of process_records and process_value_runs that holds the
// lent process handle, from 1: the argument of their error records.
LENT_PROCESS_ARGUMENT :: 1

// scope_of_lent_process gives the scope of a call that names a process by
// the handle that its caller lent: the records of that process. The service
// proved that the handle came through the call ring with the right Read,
// but not its kind: a caller can lend any handle. ok is false, with the
// error record, for a handle that names no process.
scope_of_lent_process :: proc "contextless" (process: system.Handle, error: ^errors.Error_Record) -> (scope: log_scope.Scope, ok: bool) {
	kind, _, _ := system.handle_state(process)
	if kind != .Process {
		errors.fail(error, ERROR, .Handle_Kind, .None, LENT_PROCESS_ARGUMENT, i64(process), i64(op.Object_Kind.Process), i64(kind))
		return {}, false
	}
	// The lent handle keeps the slot of the process for the whole call, so
	// the slot and the serial name that process, also after it stopped.
	slot, serial, status := system.process_place(process)
	if status != .Ok {
		errors.fail(error, ERROR, .Refused, .None, LENT_PROCESS_ARGUMENT, 0, 0, i64(status))
		return {}, false
	}
	return log_scope.lent_process_scope(slot, serial), true
}

// records gives the log records of the log scope of the caller from the number `after` on, one row each: the number, the time in microseconds, the process and its slot, the level, the count of its value runs, and the text. A row says when its text goes on in the next row. The first row also gives the records that the kernel wrote over before this call read them. The result is the count of the rows of the scope from `after` to the last record.
//
// **What it is for.** A reader of the log checks the process and the level
// of a record as fields, not by a search in a line of text.
// The machine test reads the log this way, through the remote service. A
// process reads its own records back, with their times, levels and value
// runs.
//
// **Parameter**: `after`, the number of the first record to give, from 0.
// A negative number is 0. A number past the last record gives no row.
//
// **A row** (`Record`): `number`, the number of the record in the whole
// log, or for a reader of its own records its own number: the count of the
// records of its process before it; `time`, microseconds since the start of the machine; `process`, its
// name or `kernel`; `slot`, its process slot, 0 for the kernel; `level`,
// a member of `Log_Level`: `Info`, `Debug`, `Warning` or `Error`; `form`,
// `Text`, or `Fact` for a [log fact](term:log-fact), whose text is empty
// and whose values `fact_records` gives; `lost`, in the first row only;
// `continues`, 1 when the text goes on in the next row; `runs`, the count of
// its value runs; `text`, at most 168 bytes.
//
// **The result** counts the rows of the scope from `after` to the last
// record, also the ones that do not fit in the table of the caller: a
// caller that gets a result larger than its table calls again with `after`
// set past its last row. A reader can copy the last 2046 records only:
// `lost` in the first row counts the records after `after` that the kernel
// wrote over before the read, and the rows start after them. For a reader
// of its own records, `after`, `number` and `lost` count its own records
// only: no number or count of the records of other processes. Its rows come
// from the own log ring of its process, which keeps its last 64 records and
// which the records of others never fill
// (src/md/features/own_log_ring.md). A reader whose records are all gone
// receives no row, so no `lost` either. A record whose form or level byte
// names no member gives no row, counts in `lost`, and is not in the
// result.
//
// **Grant**: the [log scope](term:log-scope) of the connection. A caller
// that **acts for the principal** receives the whole log: the records are
// facts of all the processes. Each other caller receives its
// [own records](term:own-records) only: the records that the kernel wrote
// for its process, which the root service names in the grant of the
// connection by its process slot and its process serial.
//
// ```
// connect("log")
// log.records(0)
// log.records(0) |> where(process = "console") |> where(level = Warning)
// ```
@(export, link_name = "records")
records :: proc "c" (after: i64, result: ^[]Record) -> i64 {
	return records_in_scope(caller_scope(), after, result)
}

// process_records gives the log records of one process whose process handle the caller lends, from the own number `after` on, one row each, as records() gives its own records to a caller. A starter reads what its children wrote this way. The result is the count of the rows of that process from `after` to the last record.
//
// **What it is for.** A process that starts processes, such as a test,
// shows what each child wrote, with no right to read the whole log. The
// handle that it received when it started the child is the proof that it
// may see that child.
//
// **Parameters**: `process`, the process handle of the child, lent with the
// right Read; `after`, the own number of the first record to give, from 0.
//
// **A row** (`Record`): as for `records`. `number` is the own number of the
// record among the records of that process; `lost` in the first row counts
// the records of that process after `after` that its own log ring no longer
// keeps. The rows come from that ring, which keeps the last 64 records of
// the process, also after its stop while a handle names it; the records of
// other processes never fill it.
//
// **Grant**: the lent handle. Each caller with a connection to the log
// service receives the records of the process of the handle only, also a
// caller that acts for the principal. The records of a grandchild need its
// handle, which only the child holds and can give.
//
// **Errors**: `Handle_Kind` for a handle that names no process.
@(export, link_name = "process_records")
process_records :: proc "c" (process: system.Lent({.Read}), after: i64, result: ^[]Record, error: ^errors.Error_Record) -> i64 {
	scope, ok := scope_of_lent_process(process.handle, error)
	if !ok {
		return ERROR
	}
	return records_in_scope(scope, after, result)
}

// records_in_scope gives the rows of records() for one scope: see records.
// A scope of one process, its own records or a lent process, reads the own
// log ring of that process: the records of other processes never push them
// out (src/md/features/own_log_ring.md).
records_in_scope :: proc "contextless" (scope: log_scope.Scope, after: i64, result: ^[]Record) -> i64 {
	if !scope.whole_log {
		// The numbers and `lost` count the records of that process only,
		// so the reader learns no count of the records of others.
		own, own_lost, own_total := own_records_read(scope, after)
		own_count := 0
		for index in 0 ..< len(own) {
			form, level, known := record_borders(&own[index])
			if !known {
				// No row: the record is lost, and it leaves the count of
				// the rows of the scope, so the result counts rows only.
				own_lost += 1
				own_total -= min(own_total, 1)
				continue
			}
			if own_count == len(result^) {
				continue
			}
			row_fill(&result[own_count], i64(own[index].own_number), &own[index], form, level)
			own_count += 1
		}
		if own_count > 0 {
			result[0].lost = i64(own_lost)
		}
		return i64(own_total)
	}
	written := intrinsics.atomic_load(&reader_head.written)
	next, lost := op.log_first_kept(u64(max(after, 0)), written)
	count := 0
	total: u64
	for ; next < written; next += 1 {
		if count == len(result^) {
			// The rest of the whole log does not fit: each record is a row.
			total += written - next
			break
		}
		record, whole := record_copy(next)
		if !whole {
			lost += 1
			continue
		}
		form, level, known := record_borders(&record)
		if !known {
			// No row, and no place in the count of the rows.
			lost += 1
			continue
		}
		total += 1
		// Each place of the result has a row (a Table result: the caller
		// reads min(count, capacity) rows).
		row_fill(&result[count], i64(record.sequence), &record, form, level)
		count += 1
	}
	if count > 0 {
		result[0].lost = i64(lost)
	}
	return i64(total)
}

// value_runs gives the value runs of the log records of the log scope of the caller from the number `after` on: for each one, the number of its record, its start and its length in bytes of the text of the record, and the name of its kind (number, size, time, module, version, status...). The rows of one record are in the order of its text. The result is the count of the runs of the scope from `after` to the last record.
//
// **What it is for.** A value run says that a part of the text of a record
// is a value of a known kind. A reader joins these rows to the rows of
// `records` by `number`, and finds each value without a parse of the text:
// the window of the log draws each run in the color of its kind.
//
// **Parameter**: `after`, the number of the first record, as for
// `records`. The records that the kernel wrote over are skipped.
//
// **A row** (`Value_Run`): `number`, the record; `start` and `length`, in
// bytes of its text; `kind`, the name of the value kind. A run that does
// not fit in the text of its record gives no row.
//
// **The result** counts all the runs from `after` on, also the ones that do
// not fit in the table of the caller.
//
// **Grant**: the [log scope](term:log-scope) of the connection, as for
// `records`: the whole log for a caller that **acts for the principal**,
// else the runs of its [own records](term:own-records) only.
//
// ```
// connect("log")
// join(log.records(0), log.value_runs(0), "number")
// ```
@(export, link_name = "value_runs")
value_runs :: proc "c" (after: i64, result: ^[]Value_Run) -> i64 {
	return value_runs_in_scope(caller_scope(), after, result)
}

// process_value_runs gives the value runs of the log records of one process whose process handle the caller lends, from the own number `after` on, as value_runs() gives the runs of its own records. The result is the count of the runs of that process from `after` to the last record.
//
// **What it is for.** A starter joins these rows to the rows of
// `process_records` of the same child by `number`.
//
// **Parameters**: `process`, the process handle, lent with the right Read;
// `after`, as for `process_records`.
//
// **Grant**: the lent handle, as for `process_records`.
//
// **Errors**: `Handle_Kind` for a handle that names no process.
@(export, link_name = "process_value_runs")
process_value_runs :: proc "c" (process: system.Lent({.Read}), after: i64, result: ^[]Value_Run, error: ^errors.Error_Record) -> i64 {
	scope, ok := scope_of_lent_process(process.handle, error)
	if !ok {
		return ERROR
	}
	return value_runs_in_scope(scope, after, result)
}

// value_runs_in_scope gives the rows of value_runs() for one scope: see
// value_runs. A scope of one process reads its own log ring, as
// records_in_scope does.
value_runs_in_scope :: proc "contextless" (scope: log_scope.Scope, after: i64, result: ^[]Value_Run) -> i64 {
	total := 0
	count := 0
	if !scope.whole_log {
		own, _, _ := own_records_read(scope, after)
		for &record in own {
			runs_add(i64(record.own_number), &record, result, &total, &count)
		}
		return i64(total)
	}
	written := intrinsics.atomic_load(&reader_head.written)
	next, _ := op.log_first_kept(u64(max(after, 0)), written)
	for ; next < written; next += 1 {
		record, whole := record_copy(next)
		if !whole {
			continue
		}
		runs_add(i64(record.sequence), &record, result, &total, &count)
	}
	return i64(total)
}

// One log fact of the log: fact_records(). The row of `records` with the
// same number holds its head; a row there has no room for these fields. The
// fields are the bytes of the record as the kernel wrote them: the service
// renders nothing, and a reader writes the sentence from the values with
// the description that the hash and the key name
// (src/md/features/log_facts.md, "The reader path").
Fact_Row :: struct {
	number:      i64, // The number of the log record, as in records().
	form:        op.Log_Record_Form, // Fact for each row, as the field form of records() names it: the same enum in the two tables.
	continues:   i64, // The byte `more` of the record: 1 for a record of a fact before its last.
	key:         value_kinds.Hexadecimal_64, // The fact key that the writer gave.
	module_hash: value_kinds.Hash_Field, // The module hash that the writer gave: its own-hash place.
	value_count: i64, // The value bytes of this record, as the kernel counted them from the length.
	part:        u32, // The place of the record among the records of its fact, from 0, which the kernel writes.
	part_count:  u32, // The records of its fact, 1 to op.LOG_FACT_RECORDS_MOST, which the kernel writes.
	values:      value_kinds.Fact_Values_Field, // The value bytes of this record, each of them: the bytes past value_count are 0.
}
#assert(size_of(Fact_Row) == 224)
// A reader that reads records and fact_records from one number, in call
// regions of one size, gets a row of each fact of its answer of records:
// a fact row is not larger than a row of records, and only a fact has one.
// The step Record of the machine tests counts on it.
#assert(size_of(Fact_Row) <= size_of(Record))

// fact_row_add adds the row of a record of the form Fact, and counts each
// such record, also the ones that do not fit in the result. A record of
// another form, and a byte that names no form, give no row.
fact_row_add :: proc "contextless" (number: i64, record: ^op.Log_Record, result: ^[]Fact_Row, total: ^int, count: ^int) {
	if form, known := op.log_record_form(record); !known || form != .Fact {
		return
	}
	total^ += 1
	if count^ >= len(result^) {
		return
	}
	fact := op.log_record_fact(record)
	row := &result[count^]
	row^ = {number = number, form = .Fact, continues = i64(record.more), key = value_kinds.Hexadecimal_64(fact.key), value_count = i64(fact.value_count), part = u32(fact.part), part_count = u32(fact.part_count)}
	copy(row.module_hash[:], fact.module_hash[:])
	// The bytes past the count that the kernel wrote are the zeros of the
	// record, so a value never carries bytes of an older record.
	copy(row.values[:min(int(fact.value_count), len(row.values))], fact.values[:])
	count^ += 1
}

// fact_records gives the log facts of the log scope of the caller from the number `after` on, one row each, with the bytes that its writer gave: the record form, the fact key, the module hash, the count of the value bytes, its part and its count of parts, and the value bytes of the record. The result is the count of the facts of the scope from `after` to the last record.
//
// **What it is for.** A log fact is a record with no text: its row in
// `records` has its number, its time, its process and its level, and an
// empty text. A reader joins these rows to the rows of `records` by
// `number`. `log_reader` checks with them what the kernel wrote for each
// fact that it gave to `Log`.
//
// **Parameter**: `after`, the number of the first record, as for
// `records`.
//
// **A row** (`Fact_Row`): `number`, the record; `form`, `Fact`, a member
// of `Log_Record_Form` as in a row of `records`; `continues`, its byte `more`; `key`; `module_hash`;
// `value_count`; `part`, from 0, and `part_count`, the records of its fact
// (src/md/features/log_facts.md, "A fact of several records"); `values`,
// the 144 value bytes of the record, with 0 past `value_count`.
//
// **Grant**: the [log scope](term:log-scope) of the connection, as for
// `records`.
//
// The console reads these rows for `facts(...)`, which gives the fields of
// one fact type as columns.
//
// ```
// connect("log")
// join(log.records(0), log.fact_records(0), "number")
// log.records(0) |> facts(log_reader.Fact_Probe)
// ```
@(export, link_name = "fact_records")
fact_records :: proc "c" (after: i64, result: ^[]Fact_Row) -> i64 {
	scope := caller_scope()
	total := 0
	count := 0
	if !scope.whole_log {
		own, _, _ := own_records_read(scope, after)
		for &record in own {
			fact_row_add(i64(record.own_number), &record, result, &total, &count)
		}
		return i64(total)
	}
	written := intrinsics.atomic_load(&reader_head.written)
	next, _ := op.log_first_kept(u64(max(after, 0)), written)
	for ; next < written; next += 1 {
		record, whole := record_copy(next)
		if !whole {
			continue
		}
		fact_row_add(i64(record.sequence), &record, result, &total, &count)
	}
	return i64(total)
}
