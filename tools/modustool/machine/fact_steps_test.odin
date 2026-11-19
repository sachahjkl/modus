package machine

import "core:strings"
import "core:testing"
import "modustool:build"

// The check of the steps Fact of a scenario before its machine starts: one
// line for each step that the fact tables refuse, with its number, and no
// line for a step of another kind. A catalog with no fact type refuses each
// step Fact; the refusals of one step, and the steps that the check takes,
// are the host tests of build (fact_step_test.odin).
@(test)
the_steps_of_facts_are_checked_before_the_machine_starts :: proc(t: ^testing.T) {
	empty := build.Fact_Catalog{allocator = context.temp_allocator}
	steps := [?]Step {
		{kind = .Wait, text = "log_reader: ok"},
		{kind = .Fact, process = "", fact = "log_reader.Fact_Probe"},
		{kind = .Fact, process = "log_reader", fact = "log_reader.Fact_Probe", condition = "value = 42"},
		{kind = .Record, process = "log_reader", level = "Info", text = "log_reader: ok"},
		{kind = .Fact, process = "log_reader", fact = "log_reader"},
	}
	problems := scenario_fact_problems(&empty, steps[:])
	testing.expect_value(t, len(problems), 3)
	if len(problems) == 3 {
		testing.expect(t, strings.has_prefix(problems[0], "step 2 (Fact log_reader.Fact_Probe of ): the step of the fact log_reader.Fact_Probe names no process"))
		testing.expect_value(t, problems[1], "step 3 (Fact log_reader.Fact_Probe of log_reader): no module of the build writes a fact type: log_reader.Fact_Probe names nothing")
		testing.expect(t, strings.has_prefix(problems[2], "step 5 (Fact log_reader of log_reader): \"log_reader\" is not the name of a fact type"))
	}
	testing.expect_value(t, len(scenario_fact_problems(&empty, steps[:1])), 0)
	testing.expect_value(t, len(scenario_fact_problems(&empty, nil)), 0)
	// A scenario with no step Fact reads no module file: a host with no
	// build passes the check.
	testing.expect(t, scenario_check_before_start(steps[:1]))
}

// Each step Fact of the main scenario names a fact type, a process and a
// condition of the form that the check reads: the check against the build
// runs before the machine starts.
@(test)
the_steps_of_facts_of_the_main_scenario_are_whole :: proc(t: ^testing.T) {
	fact_steps := 0
	for step, index in scenario {
		if step.kind != .Fact {
			continue
		}
		fact_steps += 1
		_, _, named := build.fact_name_parts(step.fact)
		testing.expectf(t, named && step.process != "", "the step %d names a fact type and a process", index + 1)
	}
	testing.expect(t, fact_steps > 0)
}
