package machine

import "core:fmt"
import "core:time"
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

// fact_lines_forget forgets the lines of facts that log_read kept.
fact_lines_forget :: proc(machine: ^Machine) {
	for place in machine.fact_lines {
		delete(place.process, machine.fact_lines.allocator)
	}
	clear(&machine.fact_lines)
}
