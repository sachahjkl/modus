package machine

import "core:fmt"
import "core:strconv"
import "core:time"
import module "modus:contract/module"
import "modustool:build"
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
scenario_check_before_start :: proc(steps: []Step) -> bool {
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
	problems := scenario_fact_problems(&catalog, steps)
	for problem in problems {
		fmt.eprintfln("modustool: test failed: the scenario is refused before its machine starts: %s", problem)
	}
	return len(problems) == 0
}

// scenario_fact_problems gives one line for each step Fact of a scenario
// that the fact tables of a catalog refuse, with its number and its cause.
scenario_fact_problems :: proc(catalog: ^build.Fact_Catalog, steps: []Step) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	for step, index in steps {
		if step.kind != .Fact {
			continue
		}
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
// does not hold, or whose values do not fit its record, has no sentence:
// a step Record does not find it by a text.
record_fact_sentences :: proc(machine: ^Machine, from: i64) -> map[i64]string {
	sentences := make(map[i64]string, context.temp_allocator)
	table, ok := table_call(&machine.client, fmt.tprintf("log.fact_records(%d)", from))
	if !ok {
		return sentences
	}
	machine_fact_catalog_ensure(machine)
	for row in 0 ..< len(table.rows) / table.size {
		number, number_ok := strconv.parse_i64(table_value(&table, row, "number"))
		value_count, count_ok := strconv.parse_int(table_value(&table, row, "value_count"))
		hash_bytes := table_field_bytes(&table, row, "module_hash")
		key_bytes := table_field_bytes(&table, row, "key")
		values := table_field_bytes(&table, row, "values")
		if !number_ok || !count_ok || len(hash_bytes) != module.HASH_SIZE || len(key_bytes) != 8 || value_count < 0 || value_count > len(values) {
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
		file := build.fact_catalog_file(machine.fact_catalog, build.hash_prefix_of(hash))
		if file == nil {
			continue
		}
		if sentence, rendered := build.fact_values_render(file, key, values[:value_count]); rendered {
			sentences[number] = sentence
		}
	}
	return sentences
}

// fact_lines_forget forgets the lines of facts that log_read kept.
fact_lines_forget :: proc(machine: ^Machine) {
	for place in machine.fact_lines {
		delete(place.process, machine.fact_lines.allocator)
	}
	clear(&machine.fact_lines)
}
