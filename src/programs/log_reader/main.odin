// A test of the log scope: a program that reads its own log records back
// through the log service, with a connection that does not act for the
// principal, and the records of the two children that it starts.
//
// **What it is for.** The memory of the log holds the records of every
// program, and a program sees no other program. So the log service gives a
// caller that does not act for the principal its
// [own records](term:own-records) only: the records of its program slot
// with its program serial, which the root service writes in the grant of
// the connection ([log scope](term:log-scope)). This program proves it: it
// writes one record before it connects, reads the log from the own number
// 0, and checks that it receives that one record, as the own number 0, and
// no other row. A row of another program, or of an earlier run of this
// program in the same slot, would be a second row.
//
// A starter sees the programs that it started. Before it connects, this
// program starts two children, `log_reader child 1` and `log_reader child
// 2`, which each write one record and stop. It lends the program handle of
// each child to `log.program_records` and `log.program_value_runs`, and
// checks that it receives the one record of that child, as the own number
// 0: no record of the other child, of this program, or of a child of an
// earlier run, which has the same name and the same text. The records of
// its children are not in its own records. It also lends a memory object
// in place of a program handle, and the program handle of the log service
// that `connect` gave it with Read and no Give, and checks both refusals.
//
// The kernel keeps the records of each program in its
// [own log ring](term:own-log-ring), which only the records of that program
// fill. So after the two children, this program starts a third child,
// `log_reader storm`, which writes more records than the whole log keeps
// and pushes the records of this program and of its two children out of
// the whole log. Each check above runs after that storm, and still finds
// each record, with nothing lost. The machine test starts it two times.
// The designs: (src/md/features/log_reader_scope.md) and
// (src/md/features/own_log_ring.md).
//
// **What a reader sees.** It has no window. Start it with
// `start("log_reader")` in the console. It writes on the log:
//
// - `log_reader: the record that this program reads back, with the value 42`;
// - its storm child writes `log_reader storm: a record` many times, then
//   `log_reader storm: the last record, after more records than the whole
//   log keeps`;
// - `log_reader: its own records: 1 rows from the own number 0, its first
//   record, in the slot <slot>, lost 0: no row of another program or of an
//   earlier run: as it must`;
// - `log_reader: the value runs: <count> rows, each of a record of this
//   program, with the run of its value 42: as it must`;
// - for each child, `log_reader: the records of log_reader child 1: 1 rows
//   from the own number 0, its one record, lost 0: no row of this program,
//   of the other child or of an earlier run: as it must`, and `log_reader:
//   the value runs of log_reader child 1: 1 rows, the run of its value 1:
//   as it must`;
// - `log_reader: a child wrote <count> records after the records of this
//   program and of its two children, more than the <capacity> that the
//   whole log keeps, and the own log ring of each one kept its records: as
//   it must`;
// - `log_reader: the storm child took 900 of the 1000 log records of each
//   second of this program, which kept 100, and each child gave its
//   records back at its stop: as it must`: a budget holds its log records
//   as it holds its pages, and counts only its own, so the storm never
//   makes the kernel refuse a line of this program
//   (src/md/features/log_side_channels.md);
// - `log_reader: a memory object in place of a program handle: the log
//   service refused it with Handle_Kind: as it must`;
// - `log_reader: the program handle of the log service from connect, with
//   Read and no Give: the lend failed with No_Right, and it reads no record
//   of the service: as it must`;
// - `log_reader: ok`, then it stops with the code 0.
//
// Each child writes `log_reader child: the record that the starter reads
// back, with the value <n>`, its number, and stops with the code 0.
//
// A check that fails writes a line with `WRONG`, and the program stops with
// the code 1.
//
// **Its grants**: **Connect**, to the log service only, with no grant to
// act for the principal; **Image**, for the description of the exports of
// the log service and for the module of its children; and the log with the
// right Give, so that each child writes its records. A child receives the
// log only.
package log_reader

import "modus:contract/errors"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:support/random"
import "modus:support/system"

// Its rows and its call region, 64 pages, the budgets of its two children,
// CHILD_PAGES each, and the budget of its storm child, STORM_PAGES: no
// window, its one thread and the thread of each child.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1152, programs = 4, threads = 4}

// The children: the same module, with the value VALUE_CHILD of the
// context. The root service writes no value there, so a program that it
// starts is the starter.
VALUE_CHILD :: 5
CHILD_TAG :: u64(0x4C4F_4752_0000_0000) // "LOGR" in the high half, the number of the child in the low half.
CHILD_TAG_MASK :: u64(0xFFFF_FFFF_0000_0000)
CHILD_COUNT :: 2
CHILD_PAGES :: 256
CHILD_AMOUNTS :: system.Budget_Amounts{pages = CHILD_PAGES, programs = 1, threads = 1, processor = 200_000, log_records = 10}
CHILD_TEXT :: "log_reader child: the record that the starter reads back, with the value "

// The name and the whole text of the record of each child: its value is
// its number, from 1.
@(rodata)
child_names := [CHILD_COUNT]string{"log_reader child 1", "log_reader child 2"}
@(rodata)
child_lines := [CHILD_COUNT]string{CHILD_TEXT + "1", CHILD_TEXT + "2"}

// The storm child: the same module, with the value VALUE_STORM of the
// context, which the root service never sets. It writes more records than
// the whole log keeps, after the records of this program and of its two
// children. In the one ring of before, they pushed those records out.
VALUE_STORM :: 8
STORM_NAME :: "log_reader storm"
STORM_RECORDS :: op.LOG_RECORD_CAPACITY + 64
STORM_LINE :: "log_reader storm: a record"
STORM_LAST_LINE :: "log_reader storm: the last record, after more records than the whole log keeps"
// The storm child pays its own copy of the module, its stack, its page
// tables and its own log ring. Its log records of each second come from the
// budget of this program, which keeps the rest for its own lines: a budget
// counts only its own records, so the storm never makes the kernel refuse a
// line of this program.
STORM_PAGES :: 512
// The root service gives this program 1000 records of each second
// (op.LOG_RECORDS_OF_A_PROGRAM): the storm takes 900, and this program
// keeps 100 for its lines.
STORM_LOG_RECORDS :: 900
STORM_AMOUNTS :: system.Budget_Amounts{pages = STORM_PAGES, programs = 1, threads = 1, processor = 1_000_000, log_records = STORM_LOG_RECORDS}
// The log limit of a budget counts the records of each second.
MILLISECONDS_OF_A_SECOND :: 1000

// The parameter of log.program_records that holds the program handle, from
// 1: the argument that its error record names.
LENT_PROGRAM_ARGUMENT :: 1

program_generator: random.Generator
children: [CHILD_COUNT]system.Handle
// The log records of each second of the budget of this program before any
// child, and while the storm child runs: the line of the storm says them
// after the checks of the own records, which must find one line only.
whole_log_records: u64
storm_log_records_kept: u64

// One row of log.records(): the form of `Record` in
// src/programs/log/exports.odin. The program compares its size with the
// description of the export before its first call.
Record :: struct {
	number:    i64,
	time:      i64,
	program:   [32]u8,
	slot:      i64,
	level:     [8]u8,
	channel:   [16]u8,
	lost:      i64,
	continues: i64,
	runs:      i64,
	text:      [152]u8,
}
#assert(size_of(Record) == 256)

// One row of log.value_runs(): the form of `Value_Run` in
// src/programs/log/exports.odin.
Value_Run :: struct {
	number: i64,
	start:  i64,
	length: i64,
	kind:   [16]u8,
}
#assert(size_of(Value_Run) == 40)

PROGRAM_NAME :: "log_reader"
OWN_TEXT :: "log_reader: the record that this program reads back, with the value "
OWN_VALUE :: 42
// The whole text of its record: the value is written as a number.
OWN_LINE :: "log_reader: the record that this program reads back, with the value 42"
// The rows of one call: 64 rows of 256 bytes take 16 KiB of the call
// region, which has 64 KiB. An own log ring holds as many records.
ROWS :: 64
#assert(ROWS >= op.OWN_LOG_RECORD_CAPACITY)
// The calls of one read of the log: one call reads the whole own log ring;
// more calls mean that the service gives no end.
CALL_LIMIT :: 64

record_rows: [ROWS]Record
run_rows: [ROWS]Value_Run
// The numbers of the records of this program that records() gave.
own_numbers: [ROWS]i64
own_count: int

bytes_of :: proc "contextless" (rows: []$T) -> []u8 {
	return ([^]u8)(raw_data(rows))[:len(rows) * size_of(T)]
}

// row_size_holds says if the export with an index gives rows of a size.
row_size_holds :: proc "contextless" (file: []u8, export: u32, size: int) -> bool {
	function, described := module.function(file, export)
	if export == 0 || !described {
		return false
	}
	record, has_record := module.record_type(file, function.result_detail)
	return has_record && int(record.size) == size
}

is_own_number :: proc "contextless" (number: i64) -> bool {
	for own in own_numbers[:own_count] {
		if own == number {
			return true
		}
	}
	return false
}

// check reads the log through the log service and gives the reason of the
// first check that fails, or "".
check :: proc "contextless" (ctx: ^system.Context) -> string {
	address, mapped := system.memory_map(ctx.handles[system.GRANT_IMAGE], {})
	if mapped != .Ok {
		return "the boot image does not map"
	}
	image := ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	file := system.image_find(image, "log")
	if file == nil {
		return "the boot image has no module log"
	}
	records_export := module.export_find(file, "records")
	value_runs_export := module.export_find(file, "value_runs")
	program_records_export := module.export_find(file, "program_records")
	program_value_runs_export := module.export_find(file, "program_value_runs")
	if !row_size_holds(file, records_export, size_of(Record)) || !row_size_holds(file, value_runs_export, size_of(Value_Run)) || !row_size_holds(file, program_records_export, size_of(Record)) || !row_size_holds(file, program_value_runs_export, size_of(Value_Run)) {
		return "a row of the log service has another size than in this program"
	}
	own, read_status := system.budget_read()
	if read_status != .Ok {
		return "the budget of this program does not read"
	}
	whole_log_records = own.log_records
	if problem := children_start(ctx, image); problem != "" {
		return problem
	}
	if problem := storm_run(ctx, image); problem != "" {
		return problem
	}
	if ctx.handles[system.GRANT_ROOT] == 0 {
		return "this program has no ring to the root service"
	}
	requests, opened := system.ring_open(ctx.handles[system.GRANT_ROOT])
	if opened != .Ok {
		return "the ring to the root service does not open"
	}
	connection, connected := system.service_connection(&requests, 1, "log")
	if connected != .Ok {
		return "the root service gave no connection to the log service"
	}
	defer system.call_connection_end(&connection)

	// The records from the own number 0. Without the log scope, the rows
	// would be the records of the kernel and of every program since the
	// oldest one that the log keeps; without the program serial, they would
	// hold the records of an earlier run of this program in the same slot,
	// with the same name and the same texts; without the own log ring, the
	// storm child would have pushed the record of this program out (`lost`
	// 1, and no row). This program wrote one record before it connected, so
	// it must receive exactly that one: the own number 0, with nothing lost.
	other_rows := 0
	found_own_record := false
	own_number: i64 = -1
	first_number: i64 = -1
	first_lost: i64 = -1
	slot: i64 = 0
	slots_differ := false
	after: u64 = 0
	for _ in 0 ..< CALL_LIMIT {
		arguments := [1]isolated.Argument{{integer = after}}
		count, status := system.call_isolated(&connection, file, records_export, arguments[:], nil, false, bytes_of(record_rows[:]))
		if status != .Ok {
			return "the call of log.records did not come back"
		}
		if count <= 0 {
			break
		}
		given := min(int(count), ROWS)
		if first_number < 0 {
			first_number, first_lost = record_rows[0].number, record_rows[0].lost
		}
		for &row in record_rows[:given] {
			if system.name_of(row.program[:]) != PROGRAM_NAME {
				other_rows += 1
				continue
			}
			if slot == 0 {
				slot = row.slot
			} else if row.slot != slot {
				slots_differ = true
			}
			if own_count < len(own_numbers) {
				own_numbers[own_count] = row.number
				own_count += 1
			}
			if system.name_of(row.text[:]) == OWN_LINE {
				found_own_record = true
				own_number = row.number
			}
		}
		after = u64(record_rows[given - 1].number + 1)
	}
	if other_rows != 0 {
		system.log("log_reader: WRONG: the log service gave ", u64(other_rows), " rows of other programs")
		return "the log service gave records of other programs"
	}
	if !found_own_record {
		system.log("log_reader: WRONG: the log service gave ", u64(own_count), " rows, the first with lost ", first_lost, ", and not the record that this program wrote")
		return "the log service did not give the record of this program"
	}
	if slot == 0 || slots_differ {
		return "the rows of this program name the kernel, or two slots"
	}
	if own_count != 1 || first_number != 0 || own_number != 0 || first_lost != 0 {
		system.log("log_reader: WRONG: the log service gave ", u64(own_count), " rows of the name log_reader, the first with the number ", first_number, " and lost ", first_lost, ", the record of this program with the number ", own_number, "; one row, its first record, with the number 0 and lost 0, was the answer")
		return "the log service gave a row before the first record of this program, or of an earlier run"
	}

	// The value runs from the number 0: each one of a record of this
	// program, and the run of the value of its record. This program writes
	// no line before this call, so each run of its own is of a record that
	// records() gave.
	run_arguments := [1]isolated.Argument{{integer = 0}}
	run_count, run_status := system.call_isolated(&connection, file, value_runs_export, run_arguments[:], nil, false, bytes_of(run_rows[:]))
	if run_status != .Ok {
		return "the call of log.value_runs did not come back"
	}
	runs_given := min(max(int(run_count), 0), ROWS)
	other_runs := 0
	found_own_run := false
	for &row in run_rows[:runs_given] {
		if !is_own_number(row.number) {
			other_runs += 1
			continue
		}
		if row.number == own_number && row.start == i64(len(OWN_TEXT)) && system.name_of(row.kind[:]) == value_kinds.VALUE_KIND_NAMES[.Number] {
			found_own_run = true
		}
	}
	if other_runs != 0 {
		system.log("log_reader: WRONG: the log service gave ", u64(other_runs), " value runs of other records")
		return "the log service gave value runs of other records"
	}
	if !found_own_run {
		return "the log service did not give the value run of the record of this program"
	}
	system.log("log_reader: its own records: ", u64(own_count), " rows from the own number 0, its first record, in the slot ", slot, ", lost 0: no row of another program or of an earlier run: as it must")
	system.log("log_reader: the value runs: ", u64(runs_given), " rows, each of a record of this program, with the run of its value ", u64(OWN_VALUE), ": as it must")

	for index in 0 ..< CHILD_COUNT {
		if problem := child_records_check(&connection, file, program_records_export, program_value_runs_export, index); problem != "" {
			return problem
		}
	}
	system.log("log_reader: a child wrote ", u64(STORM_RECORDS), " records after the records of this program and of its two children, more than the ", u64(op.LOG_RECORD_CAPACITY), " that the whole log keeps, and the own log ring of each one kept its records: as it must")
	system.log("log_reader: the storm child took ", u64(STORM_LOG_RECORDS), " of the ", whole_log_records, " log records of each second of this program, which kept ", storm_log_records_kept, ", and each child gave its records back at its stop: as it must")
	if problem := lent_memory_refused(&connection, file, program_records_export); problem != "" {
		return problem
	}
	return lent_service_handle_refused(&connection, file, program_records_export)
}

// lent_service_handle_refused lends the program handle of the log service
// that the root service gave with the connection. That handle has Read and
// no Give: this program did not start the service, and a handle with no
// Give cannot be lent, so it reads no record of the service. It gives the
// reason of a wrong answer, or "".
lent_service_handle_refused :: proc "contextless" (connection: ^system.Call_Connection, file: []u8, records_export: u32) -> string {
	function, described := module.function(file, records_export)
	if !described {
		return "log.program_records has no description"
	}
	arguments := [2]isolated.Argument{{integer = u64(connection.program)}, {integer = 0}}
	lending: system.Lending
	status := system.lend(file, function, arguments[:], connection.ring_memory, &lending)
	system.lend_end(&lending)
	if status != .No_Right {
		system.log("log_reader: WRONG: the lend of the program handle of the log service gave ", op.STATUS_NAMES[status])
		return "the program handle of the log service, with no Give, was lent"
	}
	call_arguments := [2]isolated.Argument{{integer = u64(connection.program)}, {integer = 0}}
	_, call_status := system.call_isolated(connection, file, records_export, call_arguments[:], nil, false, bytes_of(record_rows[:]))
	if call_status != .Lend_Failed {
		system.log("log_reader: WRONG: the call of log.program_records with the program handle of the log service gave the status ", u64(call_status))
		return "the call with the program handle of the log service was not refused"
	}
	system.log("log_reader: the program handle of the log service from connect, with Read and no Give: the lend failed with No_Right, and it reads no record of the service: as it must")
	return ""
}

// child_wait waits until a child stopped, and gives its stop code. The
// bound only ends a hang.
child_wait :: proc "contextless" (child: system.Handle) -> (code: u32, stopped: bool) {
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; system.time() < deadline; {
		if state, stop_code := system.program_state(child); state == .Stopped {
			return stop_code, true
		}
		system.sleep(system.time() + 10)
	}
	return 0, false
}

// children_start starts the two children, and waits until each one
// stopped: then each one wrote its record. This program keeps the handle
// of each child, so the own log ring of each one stays after its stop. It
// gives the reason of the first failure, or "".
children_start :: proc "contextless" (ctx: ^system.Context, image: []u8) -> string {
	file := system.image_find(image, PROGRAM_NAME)
	if file == nil {
		return "the boot image has no module log_reader"
	}
	if !random.generator_from_context(&program_generator, ctx) {
		return "the context has no random seed"
	}
	for index in 0 ..< CHILD_COUNT {
		// The log with the right Write only: a child gives it to nobody.
		grants: [op.CONTEXT_HANDLES]system.Grant
		grants[op.CONTEXT_LOG] = {ctx.handles[op.CONTEXT_LOG], {.Write}}
		values: [op.CONTEXT_VALUES]u64
		values[VALUE_CHILD] = CHILD_TAG | u64(index + 1)
		program, status := system.program_start(file, child_names[index], grants, random.values_with_seed(&program_generator, values), CHILD_AMOUNTS, nil, nil, {image = image})
		if status != .Ok {
			system.log("log_reader: WRONG: ", child_names[index], " did not start: ", op.STATUS_NAMES[status])
			return "a child did not start"
		}
		children[index] = program
	}
	for index in 0 ..< CHILD_COUNT {
		code, stopped := child_wait(children[index])
		if !stopped {
			system.log("log_reader: WRONG: ", child_names[index], " did not stop")
			return "a child did not stop"
		}
		if code != 0 {
			system.log("log_reader: WRONG: ", child_names[index], " stopped with the code ", u64(code))
			return "a child did not write its record"
		}
	}
	return ""
}

// next_second waits until the next second of the clock: the log limit of a
// budget then has room again.
next_second :: proc "contextless" () {
	system.sleep((system.time() / MILLISECONDS_OF_A_SECOND + 1) * MILLISECONDS_OF_A_SECOND)
}

// storm_write writes one record of the storm child, and writes it again in
// the next second when the log limit refused it: each record of the storm
// must be in the log. false: the kernel refused it for another reason.
storm_write :: proc "contextless" (log: u64, text: string) -> bool {
	for {
		_, status := system.call(.Log, log, u64(uintptr(raw_data(text))), u64(len(text)), u64(op.Log_Level.Info), 0, 0, 0)
		switch status {
		case .Ok:
			return true
		case .No_Budget:
			next_second()
		case .Bad_Operation, .Bad_Handle, .Bad_Address, .No_Memory, .No_Slot, .Bad_State, .No_Right:
			return false
		}
	}
}

// storm is the storm child: it writes STORM_RECORDS records, then its last
// line, and stops with the code 0; with the code 1 when the kernel refused
// a record for another reason than the log limit.
storm :: proc "contextless" (ctx: ^system.Context) -> ! {
	log := u64(ctx.handles[op.CONTEXT_LOG])
	for _ in 0 ..< STORM_RECORDS {
		if !storm_write(log, STORM_LINE) {
			system.stop(1)
		}
	}
	if !storm_write(log, STORM_LAST_LINE) {
		system.stop(1)
	}
	system.stop(0)
}

// log_records_wait waits until the budget of this program holds `amount`
// log records of each second: a child gives its records back when its
// program is cleaned, after its stop. It gives what the budget holds. The
// bound only ends a hang.
log_records_wait :: proc "contextless" (amount: u64) -> (held: u64, reached: bool) {
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for {
		own, _ := system.budget_read()
		if own.log_records == amount {
			return own.log_records, true
		}
		if system.time() >= deadline {
			return own.log_records, false
		}
		system.sleep(system.time() + 10)
	}
}

// storm_run starts the storm child after the two children stopped, and
// waits for its stop. The log records of each second of the storm child
// leave the budget of this program while it runs, and come back after its
// stop. It gives the reason of the first check that fails, or "".
storm_run :: proc "contextless" (ctx: ^system.Context, image: []u8) -> string {
	file := system.image_find(image, PROGRAM_NAME)
	if file == nil {
		return "the boot image has no module log_reader"
	}
	if held, reached := log_records_wait(whole_log_records); !reached {
		system.log("log_reader: WRONG: after the stop of the two children, this program holds ", held, " log records of each second, and not ", whole_log_records)
		return "the two children did not give their log records back"
	}
	grants: [op.CONTEXT_HANDLES]system.Grant
	grants[op.CONTEXT_LOG] = {ctx.handles[op.CONTEXT_LOG], {.Write}}
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_STORM] = 1
	child, status := system.program_start(file, STORM_NAME, grants, random.values_with_seed(&program_generator, values), STORM_AMOUNTS, nil, nil, {image = image})
	if status != .Ok {
		system.log("log_reader: WRONG: ", STORM_NAME, " did not start: ", op.STATUS_NAMES[status])
		return "the storm child did not start"
	}
	defer system.close(child)
	// The child holds its records until its stop: the budget of this
	// program keeps the rest.
	during, _ := system.budget_read()
	storm_log_records_kept = during.log_records
	if whole_log_records < STORM_LOG_RECORDS || storm_log_records_kept != whole_log_records - STORM_LOG_RECORDS {
		system.log("log_reader: WRONG: while the storm child runs, this program holds ", storm_log_records_kept, " log records of each second of its ", whole_log_records)
		return "the storm child did not take its log records from the budget of this program"
	}
	code, stopped := child_wait(child)
	if !stopped {
		return "the storm child did not stop within the hang bound"
	}
	if code != 0 {
		return "the storm child stopped with a code other than 0"
	}
	if held, reached := log_records_wait(whole_log_records); !reached {
		system.log("log_reader: WRONG: after the stop of the storm child, this program holds ", held, " log records of each second, and not ", whole_log_records)
		return "the storm child did not give its log records back"
	}
	return ""
}

// child_records_check reads the records and the value runs of one child
// with its program handle, which this program lends for each call, and
// gives the reason of the first check that fails, or "". The child wrote
// one record, so the answer is that one record, as the own number 0: a row
// of this program, of the other child, or of a child of an earlier run,
// which has the same name and the same text, would be a second row. The
// storm child pushed that record out of the whole log: the own log ring of
// the child keeps it.
child_records_check :: proc "contextless" (connection: ^system.Call_Connection, file: []u8, records_export: u32, value_runs_export: u32, index: int) -> string {
	name := child_names[index]
	arguments := [2]isolated.Argument{{integer = u64(children[index])}, {integer = 0}}
	count, status := system.call_isolated(connection, file, records_export, arguments[:], nil, false, bytes_of(record_rows[:]))
	if status != .Ok {
		system.log("log_reader: WRONG: the call of log.program_records for ", name, " gave the status ", u64(status))
		return "the call of log.program_records did not come back"
	}
	given := min(max(int(count), 0), ROWS)
	other_rows := 0
	found_child_record := false
	for &row in record_rows[:given] {
		if system.name_of(row.program[:]) != name {
			other_rows += 1
			continue
		}
		if system.name_of(row.text[:]) == child_lines[index] && row.number == 0 {
			found_child_record = true
		}
	}
	if other_rows != 0 {
		system.log("log_reader: WRONG: the records of ", name, ": ", u64(other_rows), " rows of another program")
		return "the log service gave a child the records of another program"
	}
	if given != 1 || !found_child_record || record_rows[0].lost != 0 {
		system.log("log_reader: WRONG: the records of ", name, ": ", u64(given), " rows; one row, its record with the number 0 and lost 0, was the answer")
		return "the log service did not give exactly the record of the child"
	}

	run_arguments := [2]isolated.Argument{{integer = u64(children[index])}, {integer = 0}}
	run_count, run_status := system.call_isolated(connection, file, value_runs_export, run_arguments[:], nil, false, bytes_of(run_rows[:]))
	if run_status != .Ok {
		system.log("log_reader: WRONG: the call of log.program_value_runs for ", name, " gave the status ", u64(run_status))
		return "the call of log.program_value_runs did not come back"
	}
	runs_given := min(max(int(run_count), 0), ROWS)
	if runs_given != 1 || run_rows[0].number != 0 || run_rows[0].start != i64(len(CHILD_TEXT)) || system.name_of(run_rows[0].kind[:]) != value_kinds.VALUE_KIND_NAMES[.Number] {
		system.log("log_reader: WRONG: the value runs of ", name, ": ", u64(runs_given), " rows; one row, the run of its value, was the answer")
		return "the log service did not give exactly the value run of the record of the child"
	}
	system.log("log_reader: the records of ", name, ": ", u64(given), " rows from the own number 0, its one record, lost 0: no row of this program, of the other child or of an earlier run: as it must")
	system.log("log_reader: the value runs of ", name, ": ", u64(runs_given), " rows, the run of its value ", u64(index + 1), ": as it must")
	return ""
}

// lent_memory_refused lends a memory object in place of a program handle:
// the handle came through the call ring with the right Read, so only its
// kind tells the log service that it names no program. It gives the reason
// of a wrong answer, or "".
lent_memory_refused :: proc "contextless" (connection: ^system.Call_Connection, file: []u8, records_export: u32) -> string {
	memory, created := system.memory_create(1)
	if created != .Ok {
		return "the memory object of the refusal was not created"
	}
	defer system.close(memory)
	arguments := [2]isolated.Argument{{integer = u64(memory)}, {integer = 0}}
	refusal: errors.Error_Record
	_, status := system.call_isolated(connection, file, records_export, arguments[:], &refusal, false, bytes_of(record_rows[:]))
	if status != .Failed || refusal.kind != i64(errors.Kind.Handle_Kind) || refusal.argument != LENT_PROGRAM_ARGUMENT || refusal.limit != i64(op.Object_Kind.Program) || refusal.found != i64(op.Object_Kind.Memory) {
		system.log("log_reader: WRONG: a memory object in place of a program handle gave the status ", u64(status), ", the kind ", refusal.kind, ", the argument ", refusal.argument, " and the found kind ", refusal.found)
		return "the log service did not refuse a memory object in place of a program handle"
	}
	system.log("log_reader: a memory object in place of a program handle: the log service refused it with Handle_Kind: as it must")
	return ""
}

// child_number_of gives the number of a child, from 1, from the value
// VALUE_CHILD of its context. A value with no tag is the starter.
child_number_of :: proc "contextless" (value: u64) -> (number: u64, is_child: bool) {
	number = value & ~CHILD_TAG_MASK
	if value & CHILD_TAG_MASK != CHILD_TAG || number == 0 || number > CHILD_COUNT {
		return 0, false
	}
	return number, true
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	// A child writes its one record, which its starter reads back with the
	// handle of the child, and stops.
	if number, is_child := child_number_of(ctx.values[VALUE_CHILD]); is_child {
		system.log(CHILD_TEXT, number)
		system.stop(0)
	}
	if ctx.values[VALUE_STORM] != 0 {
		storm(ctx)
	}
	system.log(OWN_TEXT, u64(OWN_VALUE))
	if problem := check(ctx); problem != "" {
		system.log("log_reader: WRONG: ", problem)
		system.stop(1)
	}
	system.log("log_reader: ok")
	system.stop(0)
}
