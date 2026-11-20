package machine

import "core:strings"
import "core:testing"
import "modustool:checks"

// The main scenario of the test waits for no rate: a line with "in one
// second" comes from a measure run only.
@(test)
main_scenario_waits_for_no_rate :: proc(t: ^testing.T) {
	for step in scenario {
		if step.kind == .Wait || step.kind == .Record {
			testing.expectf(t, !strings.contains(step.text, " in one second"), "the step %q of the main scenario waits for a rate: a rate is a line of a measure run", step.text)
		}
	}
}

// The scenario of the measure run of a process starts it, from the start
// menu or by the line of the console that the table names, waits for each
// line of its measures in the order of the table, then for its last line,
// and stops the machine. A process with a line of the console is not
// started from the start menu.
@(test)
measure_process_steps_wait_for_the_lines :: proc(t: ^testing.T) {
	for process in measure_processes {
		steps := make([dynamic]Step)
		defer delete(steps)
		measure_process_steps(process, &steps)
		launched, last_wait, menu_starts := -1, -1, 0
		for step, index in steps {
			if step.kind == .Launch && step.text == process.name {
				menu_starts += 1
				if process.start_line == "" {
					launched = index
				}
			}
			if step.kind == .Type && process.start_line != "" && step.text == process.start_line {
				launched = index
			}
			if step.kind == .Wait && step.text == process.done {
				last_wait = index
			}
		}
		testing.expectf(t, launched >= 0 && last_wait > launched, "the scenario of %s starts it and waits for its last line", process.name)
		menu_starts_expected := 0
		if process.start_line == "" {
			menu_starts_expected = 1
		}
		testing.expectf(t, menu_starts == menu_starts_expected, "the scenario of %s starts it %d times from the start menu", process.name, menu_starts)
		at := launched + 1
		for line in process.lines {
			if line == "" {
				continue
			}
			testing.expectf(t, at < last_wait && steps[at].kind == .Wait && steps[at].text == line, "the scenario of %s waits for %q after the start", process.name, line)
			at += 1
		}
		testing.expect_value(t, at, last_wait)
		testing.expect_value(t, steps[len(steps) - 1].text, "kernel: the machine stops with code 0")
	}
	_, found := measure_process_find("clock")
	testing.expect(t, found)
	_, found = measure_process_find("log_reader")
	testing.expect(t, found)
	_, found = measure_process_find("life")
	testing.expect(t, !found, "a process that measures nothing has no measure run")
}

// The lines of a process in a log are the lines that hold its name and a
// colon.
@(test)
measure_process_lines_keeps_the_lines_of_the_process :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	log := "[kernel] kernel: ok\n[clock] clock: the time page: 5 reads in one second\r\n[root] root: started clock\n[clock] clock: ok\n"
	lines := checks.measure_process_lines(log, "clock")
	testing.expect_value(t, len(lines), 2)
	if len(lines) == 2 {
		testing.expect_value(t, lines[0], "[clock] clock: the time page: 5 reads in one second")
		testing.expect_value(t, lines[1], "[clock] clock: ok")
	}
}
