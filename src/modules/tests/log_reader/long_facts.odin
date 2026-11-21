package log_reader

import "modus:contract/isolated"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:random"
import "modus:system"

// The facts of several records (src/md/features/log_facts.md, "A fact of
// several records"), through the kernel:
//
// - long_facts_check gives Log a fact of one value byte more than one
//   record holds, and a fact at the bound of a call, and reads them back
//   through log.fact_records: each record with its part, the count of its
//   parts, its count of value bytes and its bytes, and the records joined
//   whole into the bytes given;
// - fact_budget_check starts a child whose log limit is
//   FACT_BUDGET_LOG_RECORDS records of each second (fact_budget_run): a
//   fact of more records than the limit, and a fact of more records than
//   the second has left, are refused whole, and the child holds only the
//   records of whole facts.

// The values of the fact of several records of the fewest bytes: one byte
// more than one record holds, so two records.
SHORT_LONG_FACT_VALUES :: op.LOG_FACT_VALUE_CAPACITY + 1
// The key of the facts of several records that this process gives to Log
// itself: no fact type has it, so the readers show them raw.
LONG_FACT_KEY :: u64(0x0123_4567_89AB_CDF0)

// The fact that this process gives to Log, and the join of its records
// read back. Not on the stack, which is small.
long_fact: op.Log_Fact_Call
long_fact_join: op.Log_Fact_Join

// The log limit of the child of the budget, in records of each second: a
// fact of more records than this is refused whole.
FACT_BUDGET_LOG_RECORDS :: 4
FACT_BUDGET_NAME :: "log_reader fact budget"
// The child pays the copy of the module, its stack and its own log ring
// from the pages that the storm child gave back.
FACT_BUDGET_AMOUNTS :: system.Budget_Amounts{pages = CHILD_PAGES, processes = 1, threads = 1, processor = 200_000, log_records = FACT_BUDGET_LOG_RECORDS}
// The fact that the child gives to Log: its values are zero, and its
// length gives its count of records.
budget_fact: op.Log_Fact_Call
BUDGET_FACT_KEY :: u64(0x0123_4567_89AB_CDF1)

// long_fact_byte gives the value byte at a place of the facts of several
// records: never 0, so that a byte that the kernel did not copy shows.
long_fact_byte :: proc "contextless" (place: int) -> u8 {
	return u8(place % 251 + 1)
}

// long_facts_check gives Log the two facts of several records and reads
// them back. It gives the reason of the first check that fails, or "".
long_facts_check :: proc "contextless" (connection: ^system.Call_Connection, file: []u8, records_export: u32, fact_records_export: u32) -> string {
	long_fact = {key = LONG_FACT_KEY}
	for &byte_value, place in long_fact.values {
		byte_value = long_fact_byte(place)
	}
	// The kernel writes the count, the part and the count of the parts of
	// each record, over the bytes that this process gives there.
	long_fact.value_count, long_fact.part, long_fact.part_count = max(u16), FACT_BODY_RESERVED_BYTE, FACT_BODY_RESERVED_BYTE
	// The own number of the first record: the own log ring held each record
	// of this process from the own number 0.
	first, counted := own_record_count(connection, file, records_export)
	if !counted {
		return "log.records did not give the count of the own records"
	}
	log := u64(system.context_record().handles[op.CONTEXT_LOG])
	totals := [2]int{SHORT_LONG_FACT_VALUES, op.LOG_FACT_VALUES_MOST}
	expected_rows := 0
	for total in totals {
		if _, status := system.call(.Log, log, u64(uintptr(&long_fact)), u64(op.LOG_FACT_HEAD_BYTES + total), u64(op.Log_Level.Info), 0, u64(op.Log_Record_Form.Fact)); status != .Ok {
			return "the operation Log refused a fact of several records that it takes"
		}
		expected_rows += op.log_fact_part_count(total)
	}
	arguments := [1]isolated.Argument{{integer = u64(first)}}
	count, status := system.call_isolated(connection, file, fact_records_export, arguments[:], nil, false, bytes_of(fact_rows[:]))
	if status != .Ok {
		return "the call of log.fact_records did not come back"
	}
	if count != i64(expected_rows) {
		system.log_fact(.Error, Wrong_Fact_Count{facts = count})
		return "log.fact_records gave another count of records of the facts of several records"
	}
	zero_hash: [32]u8
	long_fact_join = {}
	fact_index := 0
	next_part := 0
	for &row, index in fact_rows[:expected_rows] {
		total := totals[fact_index]
		part_count := op.log_fact_part_count(total)
		value_count := min(op.LOG_FACT_VALUE_CAPACITY, total - next_part * op.LOG_FACT_VALUE_CAPACITY)
		last := next_part == part_count - 1
		if row.form != .Fact || row.key != LONG_FACT_KEY || row.module_hash != zero_hash || int(row.part) != next_part || int(row.part_count) != part_count || row.value_count != i64(value_count) || row.continues != (last ? 0 : 1) {
			first_values: u64
			for place in 0 ..< 8 {
				first_values |= u64(row.values[place]) << (8 * u64(place))
			}
			system.log_fact(.Error, Wrong_Fact_Row{index = u64(index), form = op.Log_Record_Form_Word(row.form), continues = row.continues, part = u64(row.part), part_count = u64(row.part_count), key = value_kinds.Hexadecimal_Sixteen_Digits(row.key), value_count = row.value_count, first_values = value_kinds.Hexadecimal_Sixteen_Digits(first_values), last_value = u64(row.values[len(row.values) - 1])})
			return "a record of a fact of several records has another part, count or value count"
		}
		for byte_value, place in row.values {
			expected: u8 = 0
			if place < value_count {
				expected = long_fact_byte(next_part * op.LOG_FACT_VALUE_CAPACITY + place)
			}
			if byte_value != expected {
				return "a record of a fact of several records holds other bytes, or no zeros past them"
			}
		}
		// One numbering, the own records of this process: the writer is 0,
		// as for each reader of log.fact_records.
		whole, fault := op.log_fact_join_take(&long_fact_join, {number = u64(row.number), module_hash = row.module_hash, key = row.key, part = int(row.part), part_count = int(row.part_count), values = row.values[:value_count]})
		if fault != .None || whole != last {
			return "the records of a fact of several records do not join"
		}
		if !whole {
			next_part += 1
			continue
		}
		if long_fact_join.value_count != total || string(long_fact_join.values[:total]) != string(long_fact.values[:total]) {
			return "a fact of several records joins to other bytes than the bytes given"
		}
		fact_index += 1
		next_part = 0
	}
	system.log_fact(.Info, Long_Facts_Read_Back{short_bytes = u64(SHORT_LONG_FACT_VALUES), short_records = u64(op.log_fact_part_count(SHORT_LONG_FACT_VALUES)), long_bytes = u64(op.LOG_FACT_VALUES_MOST), long_records = u64(op.log_fact_part_count(op.LOG_FACT_VALUES_MOST))})
	return ""
}

// fact_budget_check starts the child of the log limit, waits for its
// stop, and reads its records with its process handle: each group of
// records that `more` joins is a whole fact that the child wrote, the
// first of FACT_BUDGET_LOG_RECORDS records, the next of 2 or 3, and no
// record of a fact that the kernel refused. The child checks each status
// and each count of refused records, and stops with Done when each held.
// It gives the reason of the first check that fails, or "".
fact_budget_check :: proc "contextless" (ctx: ^system.Context, image: []u8, connection: ^system.Call_Connection, file: []u8, process_records_export: u32) -> string {
	module_file := system.image_find(image, PROCESS_NAME)
	if module_file == nil {
		return "the boot image has no module log_reader"
	}
	grants: [op.CONTEXT_HANDLES]system.Grant
	grants[op.CONTEXT_LOG] = {ctx.handles[op.CONTEXT_LOG], {.Write}}
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_CHILD_RUN] = u64(Child_Run.Fact_Budget)
	child, status := system.process_start(module_file, FACT_BUDGET_NAME, grants, random.values_with_seed(&process_generator, values), FACT_BUDGET_AMOUNTS, nil, nil, {image = image})
	if status != .Ok {
		system.log_fact(.Info, Wrong_Child_Not_Started{status = status, child = value_kinds.module_name_field(FACT_BUDGET_NAME)})
		return "the child of the log limit did not start"
	}
	defer system.close(child)
	cause, outcome, stopped := system.process_stop_wait(child, system.time() + system.TEST_HANG_BOUND_MILLISECONDS)
	if !stopped {
		system.log_fact(.Info, Wrong_Child_Not_Stopped{child = value_kinds.module_name_field(FACT_BUDGET_NAME)})
		return "the child of the log limit did not stop"
	}
	if outcome != .Done {
		if cause == .Itself {
			system.log_fact(.Info, Wrong_Child_Stopped{cause = cause, outcome = outcome, child = value_kinds.module_name_field(FACT_BUDGET_NAME)})
		} else {
			system.log_fact(.Info, Wrong_Child_Stopped_Without_Outcome{cause = cause, child = value_kinds.module_name_field(FACT_BUDGET_NAME)})
		}
		return "the child of the log limit saw a fact that was not refused whole"
	}
	arguments := [2]isolated.Argument{{integer = u64(child)}, {integer = 0}}
	count, records_status := system.call_isolated(connection, file, process_records_export, arguments[:], nil, false, bytes_of(record_rows[:]))
	if records_status != .Ok {
		system.log_fact(.Info, Wrong_Child_Records_Call{status = call_status_word(records_status), child = value_kinds.module_name_field(FACT_BUDGET_NAME)})
		return "the call of log.process_records for the child of the log limit did not come back"
	}
	given := min(max(int(count), 0), ROWS)
	if given == 0 || record_rows[0].lost != 0 {
		return "the child of the log limit has no record, or lost records"
	}
	group := 0
	groups := 0
	pairs := 0
	for &row in record_rows[:given] {
		if row.form != .Fact {
			return "the child of the log limit has a record that is not a fact"
		}
		group += 1
		if row.continues != 0 {
			continue
		}
		// The first fact fills the limit; each next one is the fact of 2
		// records, or the fact of 3 that a new second took.
		if groups == 0 && group != FACT_BUDGET_LOG_RECORDS || groups > 0 && group != 2 && group != 3 {
			return "the records of the child of the log limit hold a part of a refused fact"
		}
		if groups > 0 && group == 2 {
			pairs += 1
		}
		groups += 1
		group = 0
	}
	if group != 0 || pairs == 0 {
		return "the records of the child of the log limit end inside a fact, or lack a fact"
	}
	system.log_fact(.Info, Fact_Budget_Checked{log_limit = FACT_BUDGET_LOG_RECORDS, most_records = u64(op.LOG_FACT_RECORDS_MOST), past_limit_records = FACT_BUDGET_LOG_RECORDS + 1})
	return ""
}

// budget_fact_write gives Log the fact of the child with a count of value
// bytes, and gives the status of the kernel.
budget_fact_write :: proc "contextless" (log: u64, value_bytes: int) -> system.Status {
	_, status := system.call(.Log, log, u64(uintptr(&budget_fact)), u64(op.LOG_FACT_HEAD_BYTES + value_bytes), u64(op.Log_Level.Info), 0, u64(op.Log_Record_Form.Fact))
	return status
}

// budget_fact_refused_whole gives Log a fact that the limit cannot take,
// and says if the kernel refused it with No_Budget and counted each of its
// records as refused.
budget_fact_refused_whole :: proc "contextless" (log: u64, value_bytes: int) -> bool {
	_, refused_before := system.budget_used()
	status := budget_fact_write(log, value_bytes)
	_, refused_after := system.budget_used()
	return status == .No_Budget && refused_after - refused_before == u64(op.log_fact_part_count(value_bytes))
}

// fact_budget_run is the child of the log limit. A fact of the most
// records and a fact of one record more than its limit are refused whole,
// in any second. In a new second, a fact of as many records as its limit
// is taken. Then, in one second, a fact of 2 records is taken, and a fact
// of 3 records is refused: the second has 2 left. A new second between the
// two calls makes the pair say nothing, and the child writes it again in
// the next second; the hang bound only ends a hang. It stops with Done
// when each status and each count of refused records held, else Failed.
// Its parent reads its records.
fact_budget_run :: proc "contextless" (ctx: ^system.Context) -> ! {
	log := u64(ctx.handles[op.CONTEXT_LOG])
	budget_fact = {key = BUDGET_FACT_KEY}
	record := op.LOG_FACT_VALUE_CAPACITY
	if !budget_fact_refused_whole(log, op.LOG_FACT_VALUES_MOST) || !budget_fact_refused_whole(log, FACT_BUDGET_LOG_RECORDS * record + 1) {
		system.stop(.Failed)
	}
	next_second()
	if budget_fact_write(log, FACT_BUDGET_LOG_RECORDS * record) != .Ok {
		system.stop(.Failed)
	}
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for system.time() < deadline {
		next_second()
		second := system.time() / MILLISECONDS_OF_A_SECOND
		taken := budget_fact_write(log, record + 1)
		_, refused_before := system.budget_used()
		left := budget_fact_write(log, 2 * record + 1)
		_, refused_after := system.budget_used()
		if system.time() / MILLISECONDS_OF_A_SECOND != second {
			continue
		}
		if taken != .Ok || left != .No_Budget || refused_after - refused_before != 3 {
			system.stop(.Failed)
		}
		system.stop(.Done)
	}
	system.stop(.Failed)
}
