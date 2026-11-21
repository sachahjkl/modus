package machine

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modustool:build"
import "modustool:checks"
import "modustool:foundation"

// The steps Fact of a scenario (src/md/features/log_facts.md, "The machine
// tests"): the tool waits for a log fact by its fact type, its process and
// a condition on a field, and checks each such step against the fact
// tables of the module files of the build before the machine starts. A
// renamed fact type or field fails the scenario at once, with its cause,
// in place of a wait that ends at the bound of a hang.

// scenario_check_before_start refuses a scenario that cannot pass, before
// its machine starts, with one line for each fault: a call of `remote`
// with no key, and each step Fact that the fact tables refuse.
scenario_check_before_start :: proc(steps: []Step, places: []int = nil) -> bool {
	if problem := remote_key_problem(steps); problem != "" {
		fmt.eprintfln("modustool: test failed: the scenario is refused before its machine starts: %s", problem)
		return false
	}
	has_fact_step := false
	for step in steps {
		has_fact_step ||= step.kind == .Fact
	}
	if !has_fact_step {
		return true
	}
	// The temporary memory: the first step of the scenario frees it.
	catalog, catalog_problem := build.fact_catalog_of_build(context.temp_allocator)
	if catalog_problem != "" {
		fmt.eprintfln("modustool: test failed: the steps Fact of the scenario cannot be checked: %s", catalog_problem)
		return false
	}
	problems := scenario_fact_problems(&catalog, steps, places)
	for problem in problems {
		fmt.eprintfln("modustool: test failed: the scenario is refused before its machine starts: %s", problem)
	}
	return len(problems) == 0
}

// scenario_fact_problems gives one line for each step Fact of a scenario
// that the fact tables of a catalog refuse, with its number and its cause.
// places, when it is not nil, gives the place of each step in its scenario:
// the steps of a step range.
scenario_fact_problems :: proc(catalog: ^build.Fact_Catalog, steps: []Step, places: []int = nil) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	for step, position in steps {
		if step.kind != .Fact {
			continue
		}
		index := step_place(places, position)
		_, fault, _, problem := build.fact_step_check(catalog, step.fact, step.process, step.condition)
		if fault != .None {
			append(&problems, fmt.tprintf("step %d (Fact %s of %s): %s", index + 1, step.fact, step.process, problem))
		}
	}
	return problems[:]
}

// fact_step_run waits for the line of a fact that matches a step Fact,
// after the text of the last Wait: log_read renders each line of a fact
// and keeps its place and its fields (Machine.fact_lines). The step is
// checked again against the catalog of the machine, which the first line
// of a fact makes: the same files that the check before the start read.
fact_step_run :: proc(machine: ^Machine, index: int, step: Step) -> bool {
	wait_started := time.tick_now()
	defer test_times_wait_note(machine, wait_started)
	checked: build.Fact_Step
	is_checked := false
	for start := time.now(); time.since(start) < foundation.HANG_BOUND; {
		log := log_read(machine)
		if common_failure_check(machine, log) {
			return false
		}
		if machine.fact_catalog != nil {
			if !is_checked {
				fault: build.Fact_Step_Fault
				problem: string
				checked, fault, _, problem = build.fact_step_check(machine.fact_catalog, step.fact, step.process, step.condition)
				if fault != .None {
					fmt.eprintfln("modustool: test failed: step %d: %s", index + 1, problem)
					return false
				}
				is_checked = true
			}
			if place, found := fact_line_after(machine, checked); found {
				if !step.any_order {
					machine.seen = place.end
				}
				foundation.test_passed_print("the log fact %s of %s%s%s, at the byte %d of the log", step.fact, step.process, step.condition == "" ? "" : ", where ", step.condition, place.start)
				return true
			}
		}
		log_change_wait(machine)
	}
	fmt.eprintfln("modustool: test failed: step %d: no log fact %s of %s%s%s after the last Wait within %v", index + 1, step.fact, step.process, step.condition == "" ? "" : " where ", step.condition, foundation.HANG_BOUND)
	return false
}

// fact_line_after gives the first line of a fact that matches a checked
// step and starts at the place of the last Wait or after it. The places
// grow: a search by halves finds the first one after the place.
fact_line_after :: proc(machine: ^Machine, checked: build.Fact_Step) -> (place: build.Fact_Line_Place, found: bool) {
	places := machine.fact_lines[:]
	low, high := 0, len(places)
	for low < high {
		middle := low + (high - low) / 2
		if places[middle].start < machine.seen {
			low = middle + 1
		} else {
			high = middle
		}
	}
	for candidate in places[low:] {
		if build.fact_step_matches(checked, candidate) {
			return candidate, true
		}
	}
	return {}, false
}

// record_fact_sentences gives the sentence of each log fact of the log
// scope of `remote` from the record `from` on, by the number of its record.
// A row of log.records has an empty text for a fact: log.fact_records gives
// its module hash, its key and its values, and the tool writes the sentence
// with the template of the module file of the build that the hash names,
// as the readers of the system write it. A fact whose module the build
// does not hold has no sentence: a step Record does not find it by a text.
// read_through is the number of the last record that the answer reached:
// the last record of the log when the answer holds each fact of the scope
// from `from`, else the record of its last row. A failed call reached no
// record. A row that the tool cannot read prints a line with its cause.
record_fact_sentences :: proc(machine: ^Machine, from: i64) -> (sentences: map[i64]string, read_through: i64) {
	sentences = make(map[i64]string, context.temp_allocator)
	read_through = from - 1
	table, ok := table_call(&machine.client, fmt.tprintf("log.fact_records(%d)", from))
	if !ok {
		return sentences, read_through
	}
	machine_fact_catalog_ensure(machine)
	rows := len(table.rows) / table.size
	if i64(rows) >= table.total {
		read_through = max(i64)
	}
	read_rows := make([dynamic]Fact_Record_Row, context.temp_allocator)
	for row in 0 ..< rows {
		number, number_ok := strconv.parse_i64(table_value(&table, row, "number"))
		if !number_ok {
			fmt.eprintfln("modustool: a row of log.fact_records(%d) has no number that the tool reads: its fact has no sentence", from)
			continue
		}
		if read_through != max(i64) {
			read_through = max(read_through, number)
		}
		value_count, count_ok := strconv.parse_int(table_value(&table, row, "value_count"))
		hash_bytes := table_field_bytes(&table, row, "module_hash")
		key_bytes := table_field_bytes(&table, row, "key")
		values := table_field_bytes(&table, row, "values")
		if !count_ok || len(hash_bytes) != module.HASH_SIZE || len(key_bytes) != 8 {
			fmt.eprintfln("modustool: the row of the log fact %d of log.fact_records has no module hash, key or count that the tool reads: it has no sentence", number)
			continue
		}
		if value_count < 0 || value_count > len(values) {
			fmt.eprintfln("modustool: the log fact %d has %d value bytes, and a fact holds 0 to %d: it has no sentence", number, value_count, len(values))
			continue
		}
		hash: [module.HASH_SIZE]u8
		copy(hash[:], hash_bytes)
		// The key is an Integer of 8 bytes in the order of the memory of
		// the machine: little-endian.
		key: u64
		for index in 0 ..< 8 {
			key |= u64(key_bytes[index]) << (8 * u64(index))
		}
		part, part_ok := strconv.parse_int(table_value(&table, row, "part"))
		part_count, part_count_ok := strconv.parse_int(table_value(&table, row, "part_count"))
		if !part_ok || !part_count_ok {
			fmt.eprintfln("modustool: the log fact %d has no part that the tool reads: it has no sentence", number)
			continue
		}
		append(&read_rows, Fact_Record_Row{number = number, hash = hash, key = key, part = part, part_count = part_count, values = slice.clone(values[:value_count], context.temp_allocator)})
	}
	// An answer that did not reach the last record of the scope stopped at
	// its page: a fact open at its end goes on in the next answer, which
	// starts at its first record.
	if open_first, open := fact_record_rows_sentences(machine.fact_catalog, read_rows[:], read_through != max(i64), &sentences); open {
		read_through = min(read_through, open_first - 1)
	}
	return sentences, read_through
}

// One row of log.fact_records, as the tool read it.
Fact_Record_Row :: struct {
	number:           i64,
	hash:             [module.HASH_SIZE]u8,
	key:              u64,
	part, part_count: int,
	values:           []u8,
}

// fact_record_rows_sentences writes the sentence of each fact of the rows
// of one read, in the order of their numbers, into sentences. The records
// of a fact of several records join (src/md/features/log_facts.md, "A fact
// of several records"): a record before the last has no sentence of its
// own, "", since the sentence is in the place of the last record and the
// text of the records joins; a record of a fact that does not join is its
// raw part after the mark. A fact still open at the end of a read that did
// not stop at its page lost its next record: its records are raw after the
// mark too. A fact whose module the catalog does not hold has no sentence.
// A fact still open at the end of a read that stopped at its page has no
// entry: open_first is the number of its first record, where the next read
// starts.
//
// A row of fact_records names no process: the writer is 0 for each. The
// records of one fact have numbers that follow each other in one
// numbering, which the kernel writes under one lock, so a number with no
// gap says that no record of another process came between them.
fact_record_rows_sentences :: proc(catalog: ^build.Fact_Catalog, rows: []Fact_Record_Row, stopped_at_page: bool, sentences: ^map[i64]string) -> (open_first: i64, open: bool) {
	join := new(op.Log_Fact_Join, context.temp_allocator)
	open_rows := make([dynamic]Fact_Record_Row, context.temp_allocator)
	broken :: proc(sentences: ^map[i64]string, open_rows: []Fact_Record_Row) {
		for item in open_rows {
			sentences^[item.number] = fact_broken_text(item.hash, item.key, item.part, item.part_count, item.values)
		}
	}
	for row in rows {
		was_open := join.open
		whole, fault := op.log_fact_join_take(join, {number = u64(max(row.number, 0)), module_hash = row.hash, key = row.key, part = row.part, part_count = row.part_count, values = row.values})
		if fault != .None && was_open {
			broken(sentences, open_rows[:])
		}
		if fault != .None || whole || join.open && row.part == 0 {
			clear(&open_rows)
		}
		switch {
		case whole:
			// The whole hash names the module: two modules that share the
			// 8 bytes of a serial line are refused in the catalog, and a
			// row of fact_records holds all 32 bytes.
			if file := build.fact_catalog_file_of_hash(catalog, row.hash); file != nil {
				if sentence, rendered := build.fact_values_render(file, row.key, join.values[:join.value_count]); rendered {
					sentences^[row.number] = sentence
				}
			}
		case join.open:
			sentences^[row.number] = ""
			append(&open_rows, row)
		case:
			sentences^[row.number] = fact_broken_text(row.hash, row.key, row.part, row.part_count, row.values)
		}
	}
	if op.log_fact_join_end(join, stopped_at_page) != .None {
		broken(sentences, open_rows[:])
	}
	// A fact open at the page goes on in the next read, which must start
	// at its first record: a read that starts at a later part of it has no
	// first part and would show it raw.
	if join.open && len(open_rows) > 0 {
		for item in open_rows {
			delete_key(sentences, item.number)
		}
		return open_rows[0].number, true
	}
	return 0, false
}

// fact_broken_text gives the text of a record of a fact that does not
// join: the mark, then the raw line of its part.
fact_broken_text :: proc(hash: [module.HASH_SIZE]u8, key: u64, part, part_count: int, values: []u8) -> string {
	fact := op.Log_Fact{module_hash = hash, key = key, value_count = u16(min(len(values), op.LOG_FACT_VALUE_CAPACITY)), part = u8(clamp(part, 0, 255)), part_count = u8(clamp(part_count, 0, 255))}
	copy(fact.values[:], values)
	line: [op.LOG_FACT_LINE_BYTES_MOST]u8
	count := op.log_fact_line(&fact, &line)
	return fmt.tprintf("%s%s", op.LOG_FACT_JOIN_BROKEN_MARK, string(line[:count]))
}


// log_file_rendered gives the text of the log file of a machine that
// stopped, with the line of each fact rendered by the module files of the
// build, as a step reads it: QEMU writes the raw lines, and a check after
// the run reads the sentences. It renders with the one helper of the
// readers of a log, checks.measure_log_rendered, so each module file is
// read once in a run of the tool, by the catalog that the run keeps. The
// text is in the temporary memory.
log_file_rendered :: proc(log_path: string) -> (text: string, ok: bool) {
	log, read_error := os.read_entire_file(log_path, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: test failed: cannot read %s: %v", log_path, read_error)
		return "", false
	}
	rendered, problem := checks.measure_log_rendered(string(log))
	if problem != "" {
		fmt.eprintfln("modustool: test failed: the facts of %s cannot be rendered: %s", log_path, problem)
		return "", false
	}
	return rendered, true
}

// fact_lines_forget forgets the lines of facts that log_read kept.
fact_lines_forget :: proc(machine: ^Machine) {
	for place in machine.fact_lines {
		delete(place.process, machine.fact_lines.allocator)
	}
	clear(&machine.fact_lines)
}
