package machine

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "modustool:foundation"

// The list of the failed parts of a check of the flake
// (src/md/infrastructure/scenario_fault_loop.md, "A full check that names
// every failed part"). Nix builds the check with --keep-going, so every
// part runs past the first one that fails; then the tool reads the build
// log of each derivation whose output is not in the store, keeps it whole
// in a file, and names its first failed step.
//
// The list reads the derivations of one evaluation of the flake, the one
// that the build built: `screenshots` evaluates the check once and builds
// that derivation path. An evaluation after the build reads the work tree
// again, and a work tree that changed meanwhile names other derivations,
// none of them built: each part then read as one that did not run.

// The folder of the whole build logs of the failed parts.
FAILED_PARTS_FOLDER :: foundation.BUILD_FOLDER + "/failed_parts"

// The name of the host checks in the list, beside the names of the parts.
FAILED_PARTS_HOST_CHECKS :: "host_checks"

// The start of each line of the tool that says that a check failed, and of
// the line that names the log of the machine of a failed scenario.
FAILED_LINE_START :: "modustool: test failed"
MACHINE_LOG_LINE_START :: "modustool: the log of the kernel of "

// One derivation of the check: the host checks or a part.
Check_Derivation :: struct {
	name:       string,
	derivation: string,
	output:     string,
}

// One evaluation of the check of the flake: the derivation of the whole
// check, and the host checks and each part in the order of the table.
Flake_Check_Evaluation :: struct {
	check_derivation: string,
	members:          []Check_Derivation,
}

// The reads of the store that the list needs. The live reader asks Nix; a
// host test gives its own sample.
Check_Store_Reader :: struct {
	output_valid: proc(path: string) -> bool,
	build_log:    proc(derivation: string) -> (log: string, ok: bool),
}

// What the build log of a failed part says.
Part_Failure :: struct {
	first_failure: string, // The first line that says that a check failed; "" when no line says it.
	machine_log:   string, // The log of the machine of that failure, after it; "" when no machine printed its log.
}

// part_log_failure reads the build log of a failed part: its first line
// that says that a check failed, and the first log of a machine that the
// tool printed after that line. The lines of the log of a machine start
// with four spaces, so a line of the machine is never taken for a line of
// the tool.
//
// A log with no such line, as the host checks that stop at a compile error
// ("modustool: odin failed (code 1)"), gives the last line of the tool that
// says that something failed.
part_log_failure :: proc(log: string) -> Part_Failure {
	failure: Part_Failure
	last_failed_line := ""
	rest := log
	for line in strings.split_lines_iterator(&rest) {
		text := strings.trim_right(line, "\r")
		if failure.first_failure == "" {
			if strings.has_prefix(text, FAILED_LINE_START) {
				failure.first_failure = text
			} else if strings.has_prefix(text, "modustool: ") && strings.contains(text, " failed") {
				last_failed_line = text
			}
			continue
		}
		if strings.has_prefix(text, MACHINE_LOG_LINE_START) {
			name := text[len(MACHINE_LOG_LINE_START):]
			if comma := strings.index_byte(name, ','); comma > 0 {
				name = name[:comma]
			}
			failure.machine_log = name
			break
		}
	}
	if failure.first_failure == "" {
		failure.first_failure = last_failed_line
	}
	return failure
}

// What became of one derivation of the check.
Part_Outcome :: enum u8 {
	Passed, // Its output is in the store.
	Failed, // Nix has its build log: it ran, and failed.
	Not_Run, // No output and no log: a derivation that it needs failed, or the build stopped first.
}

// failed_part_line gives the line of the list for one derivation that did
// not pass.
failed_part_line :: proc(name: string, outcome: Part_Outcome, failure: Part_Failure, log_path, derivation: string) -> string {
	switch outcome {
	case .Passed:
		return fmt.tprintf("modustool: %s passed", name)
	case .Not_Run:
		return fmt.tprintf("modustool: %s did not run: a derivation that it needs failed, or the build stopped before it (%s)", name, derivation)
	case .Failed:
	}
	first := failure.first_failure
	if first == "" {
		first = "no line says which check failed: read the end of its log"
	}
	machine := ""
	if failure.machine_log != "" {
		machine = fmt.tprintf("; the machine %s", machine_name_of_log(failure.machine_log))
	}
	return fmt.tprintf("modustool: %s failed: %s%s; its whole log: %s", name, first, machine, log_path)
}

// One build log of a failed derivation, to keep in a file.
Failed_Log :: struct {
	path: string,
	log:  string,
}

// The list of one evaluation: its lines, the logs to keep, and the counts.
Failed_Parts_List :: struct {
	lines:  [dynamic]string,
	logs:   [dynamic]Failed_Log,
	counts: [Part_Outcome]int,
}

// failed_parts_list reads the outcome of each derivation of an evaluation
// through a reader of the store, and gives the lines of the list, in the
// temporary memory. A list where no derivation passed and none failed says
// that no derivation of the evaluation was built: the evaluation is not the
// one that the build built, or the build stopped before any part.
failed_parts_list :: proc(evaluation: Flake_Check_Evaluation, reader: Check_Store_Reader) -> Failed_Parts_List {
	list := Failed_Parts_List {
		lines = make([dynamic]string, context.temp_allocator),
		logs  = make([dynamic]Failed_Log, context.temp_allocator),
	}
	for member in evaluation.members {
		outcome := Part_Outcome.Passed
		failure: Part_Failure
		log_path := ""
		if member.output == "" || !reader.output_valid(member.output) {
			outcome = .Not_Run
			if log, has_log := reader.build_log(member.derivation); has_log && len(log) > 0 {
				outcome = .Failed
				log_path = fmt.tprintf("%s/%s.log", FAILED_PARTS_FOLDER, member.name)
				append(&list.logs, Failed_Log{path = log_path, log = log})
				failure = part_log_failure(log)
			}
		}
		list.counts[outcome] += 1
		if outcome != .Passed {
			append(&list.lines, failed_part_line(member.name, outcome, failure, log_path, member.derivation))
		}
	}
	parts := max(len(evaluation.members) - 1, 0)
	append(&list.lines, fmt.tprintf("modustool: the check of the flake: %d failed, %d did not run, %d passed (the host checks and %d parts)", list.counts[.Failed], list.counts[.Not_Run], list.counts[.Passed], parts))
	if len(evaluation.members) > 0 && list.counts[.Not_Run] == len(evaluation.members) {
		append(&list.lines, fmt.tprintf("modustool: no derivation of the evaluation %s ran or is in the store: it is not the check that the build built (a work tree that changed after the build names other derivations), or the build stopped before any of them", evaluation.check_derivation))
	}
	return list
}

// flake_check_evaluate evaluates the check of the flake once: the
// derivation of the whole check, of the host checks and of each part, with
// their outputs. The evaluation builds the test inputs of the tree first.
flake_check_evaluate :: proc(flake_check_attribute: string) -> (evaluation: Flake_Check_Evaluation, ok: bool) {
	apply :: "check: { check = check.drvPath; parts = check.partDerivations; outputs = check.partOutputs; host = check.hostChecksDerivation; hostOutput = check.hostChecksOutput; }"
	text := host_command_output({"nix", "eval", "--json", flake_check_attribute, "--apply", apply}) or_return
	return flake_check_evaluation_of_json(text)
}

// flake_check_evaluation_of_json reads the answer of the evaluation, in
// the order of the table of the parts, the host checks first. A part of
// the table that the answer lacks, or a text that is no derivation path,
// is refused: a list with a hole would read a part as passed.
flake_check_evaluation_of_json :: proc(text: string) -> (evaluation: Flake_Check_Evaluation, ok: bool) {
	value, parse_error := json.parse_string(text, allocator = context.temp_allocator)
	if parse_error != .None {
		fmt.eprintln("modustool: the evaluation of the check of the flake is no JSON")
		return {}, false
	}
	object, is_object := value.(json.Object)
	if !is_object {
		fmt.eprintln("modustool: the evaluation of the check of the flake is no object")
		return {}, false
	}
	text_of :: proc(object: json.Object, key: string) -> string {
		entry, is_text := object[key].(json.String)
		return is_text ? entry : ""
	}
	evaluation.check_derivation = text_of(object, "check")
	parts, parts_ok := object["parts"].(json.Object)
	outputs, outputs_ok := object["outputs"].(json.Object)
	members := make([dynamic]Check_Derivation, context.temp_allocator)
	append(&members, Check_Derivation{name = FAILED_PARTS_HOST_CHECKS, derivation = text_of(object, "host"), output = text_of(object, "hostOutput")})
	for part in test_parts {
		member := Check_Derivation{name = part.name}
		if parts_ok && outputs_ok {
			member.derivation = text_of(parts, part.name)
			member.output = text_of(outputs, part.name)
		}
		append(&members, member)
	}
	for member in members {
		if !strings.has_suffix(member.derivation, ".drv") || member.output == "" {
			fmt.eprintfln("modustool: the evaluation of the check of the flake has no derivation and output of %s", member.name)
			return {}, false
		}
	}
	if !strings.has_suffix(evaluation.check_derivation, ".drv") {
		fmt.eprintln("modustool: the evaluation of the check of the flake has no derivation of the check")
		return {}, false
	}
	evaluation.members = members[:]
	return evaluation, true
}

// The reader of the store of this host.
store_reader := Check_Store_Reader {
	output_valid = store_path_valid,
	build_log    = store_build_log,
}

// failed_parts_report lists each derivation of an evaluation whose output
// is not in the store, keeps the build log of each failed one in
// FAILED_PARTS_FOLDER, and gives false when one failed or did not run.
failed_parts_report :: proc(evaluation: Flake_Check_Evaluation) -> bool {
	list := failed_parts_list(evaluation, store_reader)
	foundation.reset_folder(FAILED_PARTS_FOLDER) or_return
	for item in list.logs {
		if write_error := os.write_entire_file(item.path, item.log); write_error != nil {
			fmt.eprintfln("modustool: cannot write %s: %v", item.path, write_error)
		}
	}
	for line in list.lines {
		fmt.eprintln(line)
	}
	return list.counts[.Failed] == 0 && list.counts[.Not_Run] == 0
}

// store_path_valid says if a path is in the store of this host.
@(private = "file")
store_path_valid :: proc(path: string) -> bool {
	state, _, _, exec_error := os.process_exec({command = {"nix", "path-info", path}}, context.temp_allocator)
	return exec_error == nil && state.exited && state.success
}

// store_build_log gives the build log that Nix kept for a derivation.
@(private = "file")
store_build_log :: proc(derivation: string) -> (log: string, ok: bool) {
	state, standard_output, _, exec_error := os.process_exec({command = {"nix", "log", derivation}}, context.temp_allocator)
	if exec_error != nil || !state.exited || !state.success {
		return "", false
	}
	return string(standard_output), true
}
