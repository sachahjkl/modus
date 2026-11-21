package machine

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

// The folder of the whole build logs of the failed parts.
FAILED_PARTS_FOLDER :: foundation.BUILD_FOLDER + "/failed_parts"

// The name of the host checks in the list, beside the names of the parts.
FAILED_PARTS_HOST_CHECKS :: "host_checks"

// The start of each line of the tool that says that a check failed, and of
// the line that names the log of the machine of a failed scenario.
FAILED_LINE_START :: "modustool: test failed"
MACHINE_LOG_LINE_START :: "modustool: the log of the kernel of "

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
part_log_failure :: proc(log: string) -> Part_Failure {
	failure: Part_Failure
	rest := log
	for line in strings.split_lines_iterator(&rest) {
		text := strings.trim_right(line, "\r")
		if failure.first_failure == "" {
			if strings.has_prefix(text, FAILED_LINE_START) {
				failure.first_failure = text
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
	return failure
}

// What became of one derivation of the check.
Part_Outcome :: enum u8 {
	Passed, // Its output is in the store.
	Failed, // Nix has its build log: it ran, and failed.
	Not_Run, // No output and no log: a derivation that it needs failed.
}

// failed_part_line gives the line of the list for one derivation that did
// not pass.
failed_part_line :: proc(name: string, outcome: Part_Outcome, failure: Part_Failure, log_path, derivation: string) -> string {
	switch outcome {
	case .Passed:
		return fmt.tprintf("modustool: %s passed", name)
	case .Not_Run:
		return fmt.tprintf("modustool: %s did not run: a derivation that it needs failed (%s)", name, derivation)
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

// failed_parts_report lists each derivation of the check of the flake whose
// output is not in the store: the host checks and each part, in the order
// of the table. It gives false when one failed or did not run, and when it
// cannot evaluate the check.
failed_parts_report :: proc(flake_check_attribute: string) -> bool {
	outputs, outputs_ok := text_map_of_json(host_command_output({"nix", "eval", "--json", foundation.join(flake_check_attribute, ".partOutputs")}) or_return)
	derivations, derivations_ok := text_map_of_json(host_command_output({"nix", "eval", "--json", foundation.join(flake_check_attribute, ".partDerivations")}) or_return)
	if !outputs_ok || !derivations_ok {
		fmt.eprintln("modustool: the outputs and the derivations of the parts are no object of texts")
		return false
	}
	host_output := strings.trim_space(host_command_output({"nix", "eval", "--raw", foundation.join(flake_check_attribute, ".hostChecksOutput")}) or_return)
	host_derivation := strings.trim_space(host_command_output({"nix", "eval", "--raw", foundation.join(flake_check_attribute, ".hostChecksDerivation")}) or_return)
	foundation.reset_folder(FAILED_PARTS_FOLDER) or_return
	names := make([dynamic]string, context.temp_allocator)
	append(&names, FAILED_PARTS_HOST_CHECKS)
	outputs[FAILED_PARTS_HOST_CHECKS] = host_output
	derivations[FAILED_PARTS_HOST_CHECKS] = host_derivation
	for part in test_parts {
		append(&names, part.name)
	}
	counts: [Part_Outcome]int
	for name in names {
		output, derivation := outputs[name], derivations[name]
		outcome := Part_Outcome.Passed
		failure: Part_Failure
		log_path := ""
		if !store_path_valid(output) {
			outcome = .Not_Run
			state, log, _, exec_error := os.process_exec({command = {"nix", "log", derivation}}, context.temp_allocator)
			if exec_error == nil && state.exited && state.success && len(log) > 0 {
				outcome = .Failed
				log_path = fmt.tprintf("%s/%s.log", FAILED_PARTS_FOLDER, name)
				if write_error := os.write_entire_file(log_path, log); write_error != nil {
					fmt.eprintfln("modustool: cannot write %s: %v", log_path, write_error)
					log_path = fmt.tprintf("`nix log %s`", derivation)
				}
				failure = part_log_failure(string(log))
			}
		}
		counts[outcome] += 1
		if outcome != .Passed {
			fmt.eprintln(failed_part_line(name, outcome, failure, log_path, derivation))
		}
	}
	fmt.printfln("modustool: the check of the flake: %d failed, %d did not run, %d passed (the host checks and %d parts)", counts[.Failed], counts[.Not_Run], counts[.Passed], len(names) - 1)
	return counts[.Failed] == 0 && counts[.Not_Run] == 0
}

// store_path_valid says if a path is in the store of this host.
@(private = "file")
store_path_valid :: proc(path: string) -> bool {
	if path == "" {
		return false
	}
	state, _, _, exec_error := os.process_exec({command = {"nix", "path-info", path}}, context.temp_allocator)
	return exec_error == nil && state.exited && state.success
}
