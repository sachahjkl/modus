package machine

import "core:fmt"
import "core:os"
import "modustool:foundation"
import "modustool:build"
import "modustool:checks"

// The measure runs of the processes
// (docs/TOOLS.md, "A check by count, a measure by time").
//
// A process that measures a rate over a duration does so only in a measure
// run: a machine whose boot image holds the resource `measure_run`. The
// root service then writes 1 in the value of the context for it, in each
// process that it starts. The modules are the modules of the test: only
// the boot image differs. In a test, the same process runs its checks,
// which end after a count of work.

// One process that measures itself in a measure run, with no other process
// than the desktop.
Measure_Process :: struct {
	name:       string,
	lines:      [2]string, // Parts of the lines of its measures that the scenario waits for, in the order of the log: only a measure run writes them. "": none.
	done:       string, // The last line of the process: its checks passed, in a measure run too.
	start_line: string, // The line that the console types to start a process that the start menu does not list. "": the start menu starts it.
	// A service that the process connects to, which the start list of the
	// image does not start: the start menu starts it before the process,
	// as the main test does, and the scenario waits for its line `ready`.
	// The root service refuses a connection to a service with no process.
	// "": none.
	service:    string,
	ready:      string,
}

@(rodata)
measure_processes := [?]Measure_Process {
	{name = "clock", lines = {"clock: the time page: ", " reads in one second, 0 kernel entries for one million reads"}, done = "clock: ok, the time never went back, the page and the kernel give the same time, the kernel refuses to remove the time page"},
	{name = "crowd", lines = {"crowd: shared queue, 1 writers, 1 readers: ", " records in one second, "}, done = "crowd: ok, 5 runs, each record written is read one time, each event started all the threads"},
	{name = "disk", lines = {"disk: read, 1 block in each request, 32 in flight: ", " blocks in one second, kernel entries for 100 requests: "}, done = "disk: ok, 5 runs, 0 errors, write then read back: 0 wrong"},
	{name = "flow", lines = {"flow: capacity 32, wait at once: ", " records in one second, "}, done = "flow: ok, 4 rings, 0 records lost"},
	{name = "limits", lines = {"limits: processor time of one second, used of limit: ", ""}, done = "limits: ok, 4 budgets within their processor time, "},
	// The measures of the log facts: the write, the operation Log and the
	// render (src/md/features/log_facts.md, "The measures that decide it").
	// log_reader connects to the service log, which is the window log: the
	// main test launches that window before it, and so does this run.
	{name = "log_reader", lines = {"log_reader: measure: the write of one line, ", "log_reader: measure: the render of a log fact "}, done = "log_reader: ok", start_line = "start(\"log_reader\")", service = "log", ready = "[log] log: ok, "},
}

// measure_process_output gives the log of the measure run of a process.
// The text is in memory of its own: a scenario frees the temporary memory
// after each step.
measure_process_output :: proc(name: string) -> string {
	return fmt.aprintf("%s/test_output_measure_%s.txt", foundation.BUILD_FOLDER, name)
}

// measure_process_find gives the process of the table with a name.
measure_process_find :: proc(name: string) -> (process: Measure_Process, found: bool) {
	for item in measure_processes {
		if item.name == name {
			return item, true
		}
	}
	return {}, false
}

// measure_process_steps adds the scenario of the measure run of one
// process: the start of the machine, the process, the lines of its
// measures, its last line, and the stop.
measure_process_steps :: proc(process: Measure_Process, steps: ^[dynamic]Step) {
	append(steps, Step{kind = .Wait, text = "boot program: ok"}, Step{kind = .Wait, text = "kernel: ok"}, Step{kind = .Wait, text = "root: ok"})
	append(steps, Step{kind = .Wait, text = "compositor: first frame", any_order = true}, Step{kind = .Wait, text = "compositor: surface console"})
	if process.service != "" {
		// The process starts only after the service wrote its line: before
		// that line, the root service can have no process of the service.
		append(steps, Step{kind = .Launch, text = process.service}, Step{kind = .Wait, text = process.ready})
	}
	if process.start_line != "" {
		append(steps, Step{kind = .Front, text = "console"}, Step{kind = .Type, text = process.start_line})
	} else {
		append(steps, Step{kind = .Launch, text = process.name})
	}
	for line in process.lines {
		if line != "" {
			append(steps, Step{kind = .Wait, text = line})
		}
	}
	append(steps, Step{kind = .Wait, text = process.done}, Step{kind = .Front, text = "console"}, Step{kind = .Type, text = "shutdown()"}, Step{kind = .Wait, text = "kernel: the machine stops with code 0"})
}

// measure_process_run starts one process alone on a machine of a measure
// run, waits for its last line, stops the machine, and prints the lines of
// the process. The tool checks no number: the process checks its counts.
measure_process_run :: proc(part: ^Test_Part_Run, process: Measure_Process) -> bool {
	output := measure_process_output(process.name)
	defer delete(output)
	// Not in the temporary allocator: the scenario frees it after each step.
	steps := make([dynamic]Step)
	defer delete(steps)
	measure_process_steps(process, &steps)
	if !machine_test(part, steps[:], {volume = build.BOOT_VOLUME_MEASURE, output = output, exit_status = build.MACHINE_STOP_OK}) {
		return false
	}
	data, read_error := os.read_entire_file(output, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", output, read_error)
		return false
	}
	log, render_problem := checks.measure_log_rendered(string(data))
	if render_problem != "" {
		fmt.eprintfln("modustool: the facts of %s cannot be rendered: %s", output, render_problem)
		return false
	}
	fmt.printfln("modustool: the measure run of %s (%s):", process.name, output)
	for line in checks.measure_process_lines(log, process.name) {
		fmt.println(line)
	}
	return true
}

// measure_runs_of_the_record runs the measure runs whose lines the measure
// record holds: the locks, the time page, the disk and the scheduling
// strategies. `modustool screenshots` calls it on the host, with no other
// machine: the test itself measures no rate.
measure_runs_of_the_record :: proc() -> bool {
	part := test_part_run_make(build.MEASURE_COMMAND)
	defer test_part_run_free(&part)
	test_part_run_start(&part) or_return
	if !machine_test(&part, scenario_measure[:], {volume = build.BOOT_VOLUME_MEASURE, output = checks.TEST_OUTPUT_MEASURE, exit_status = build.MACHINE_STOP_OK}) || !checks.processor_frame_lines_check(checks.TEST_OUTPUT_MEASURE) || !checks.quality_lines_check(checks.TEST_OUTPUT_MEASURE) {
		return false
	}
	for name in ([]string{"clock", "disk", "log_reader"}) {
		process := measure_process_find(name) or_return
		measure_process_run(&part, process) or_return
	}
	part.passed = machine_test(&part, scenario_measure_scheduler[:], {volume = build.BOOT_VOLUME_MEASURE, output = checks.TEST_OUTPUT_MEASURE_SCHEDULER, exit_status = build.MACHINE_STOP_OK})
	return part.passed
}
