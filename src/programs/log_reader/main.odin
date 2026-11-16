// A test of the log scope: a program that reads its own log records back
// through the log service, with a connection that does not act for the
// principal.
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
// program in the same slot, would be a second row. The machine test starts
// it two times (src/md/features/log_reader_scope.md).
//
// **What a reader sees.** It has no window. Start it with
// `start("log_reader")` in the console. It writes on the log:
//
// - `log_reader: the record that this program reads back, with the value 42`;
// - `log_reader: its own records: 1 rows from the own number 0, its first
//   record, in the slot <slot>, lost 0: no row of another program or of an
//   earlier run: as it must`;
// - `log_reader: the value runs: <count> rows, each of a record of this
//   program, with the run of its value 42: as it must`;
// - `log_reader: ok`, then it stops with the code 0.
//
// A check that fails writes a line with `WRONG`, and the program stops with
// the code 1.
//
// **Its grants**: **Connect**, to the log service only, with no grant to
// act for the principal; and **Image**, for the description of the exports
// of the log service.
package log_reader

import "modus:contract/isolated"
import module "modus:contract/module"
import "modus:contract/value_kinds"
import "modus:support/system"

// Its rows and its call region: no window, one thread.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 64, programs = 1, threads = 1}

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
// region, which has 64 KiB.
ROWS :: 64
// The calls of one read of the log: the log keeps 2047 records, so 32
// calls of 64 rows read all of them; more calls mean that the service
// gives no end.
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
	if !row_size_holds(file, records_export, size_of(Record)) || !row_size_holds(file, value_runs_export, size_of(Value_Run)) {
		return "a row of the log service has another size than in this program"
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
	// with the same name and the same texts. This program wrote one record
	// before it connected, so it must receive exactly that one: the own
	// number 0, with nothing lost.
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
		system.log("log_reader: WRONG: the log service gave ", u64(own_count), " rows, and not the record that this program wrote")
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
	return ""
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	system.log(OWN_TEXT, u64(OWN_VALUE))
	if problem := check(ctx); problem != "" {
		system.log("log_reader: WRONG: ", problem)
		system.stop(1)
	}
	system.log("log_reader: ok")
	system.stop(0)
}
