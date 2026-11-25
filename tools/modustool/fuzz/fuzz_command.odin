package fuzz

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "modus:contract/blake3"
import "modus:contract/enum_word"
import "modustool:foundation"

// The commands of the fuzzing (src/md/infrastructure/fuzzing.md, "The run
// of the check and the long runs"; docs/TOOLS.md, "The fuzzing"): the
// parent that builds the child, starts it, watches its count of
// executions, and turns what the child left in its mailbox into a fuzz
// finding with a signature and a minimized input.

// The new executions of each target in `modustool check`, after its
// corpus: a count, never a time. A target can ask for fewer when one
// execution does much (Fuzz_Target.check_executions).
FUZZ_CHECK_EXECUTIONS :: 20_000

// The candidates that the minimizer runs, at most, for one finding.
FUZZ_MINIMIZE_CANDIDATE_LIMIT :: 4096

// How often the parent reads the count of executions of its children: a
// poll interval, not a bound. The bound of a stall is HANG_BOUND.
FUZZ_POLL_INTERVAL :: 200 * time.Millisecond

// The children of `modustool check` at once, at most, beside the bound of
// the processors: each child is one target, and more of them at once take
// the memory and the processors that the rest of the host needs.
FUZZ_CHECK_CHILDREN_LIMIT :: 8

// What a child left when it ended.
Fuzz_Child_Outcome :: struct {
	state:         Fuzz_Child_State,
	oracle:        Fuzz_Oracle,
	text:          string, // The verdict, or what the parent saw.
	signature:     string, // The oracle and the place: two outcomes with one signature are one finding.
	input:         []u8, // The input of a finding, a fault or a stall.
	executions:    u64,
	kept:          u64,
	edges_reached: u64,
	edges:         u64,
	corpus_inputs: u64,
	seconds:       f64,
}

// One child that runs.
Fuzz_Running_Child :: struct {
	host_process:       os.Process,
	mailbox:       ^Fuzz_Mailbox,
	error_path:    string, // The standard error of the child: the message of a bounds check of Odin.
	last_count:    u64,
	last_change:   time.Tick,
	started:       time.Tick,
	ended:         bool,
	stalled:       bool,
}

fuzz_target_folder :: proc(target_name: string) -> string {
	return strings.concatenate({FUZZING_BUILD_FOLDER, "/", target_name}, context.temp_allocator)
}

// fuzz_child_start creates the mailbox of one child and starts it. The
// paths are in the allocator of the context: they outlive the temporary
// memory of a long run. With an output path, the standard output of the
// child goes to that file, so that children at once do not mix their
// lines; else it goes to the standard output of the tool.
fuzz_child_start :: proc(binary: string, mode: Fuzz_Child_Mode, target: ^Fuzz_Target, seed: u64, executions: u64, number: int, file := "", output_path := "") -> (child: Fuzz_Running_Child, ok: bool) {
	folder := fuzz_target_folder(target.name)
	if !foundation.make_folder(folder) {
		return {}, false
	}
	mailbox_path := fmt.tprintf("%s/mailbox_%d", folder, number)
	child.error_path = fmt.aprintf("%s/child_error_%d.txt", folder, number)
	mailbox, mapped := fuzz_mailbox_map(mailbox_path, create = true)
	if !mapped {
		fmt.eprintfln("modustool: cannot make the mailbox %s", mailbox_path)
		return {}, false
	}
	mailbox.magic = FUZZ_MAILBOX_MAGIC
	child.mailbox = mailbox
	error_file, open_error := os.open(child.error_path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if open_error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", child.error_path, open_error)
		return {}, false
	}
	defer {
		_ = os.close(error_file)
	}
	output_file := os.stdout
	if output_path != "" {
		opened, output_error := os.open(output_path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
		if output_error != nil {
			fmt.eprintfln("modustool: cannot write %s: %v", output_path, output_error)
			return {}, false
		}
		output_file = opened
	}
	defer if output_path != "" {
		_ = os.close(output_file)
	}
	command := make([dynamic]string, context.temp_allocator)
	append(&command, binary, "fuzz-child", fuzz_child_mode_names[mode], target.name, mailbox_path, fmt.tprintf("%d", seed), fmt.tprintf("%d", executions))
	if file != "" {
		append(&command, file)
	}
	host_process, start_error := os.process_start({command = command[:], stdout = output_file, stderr = error_file})
	if start_error != nil {
		fmt.eprintfln("modustool: cannot start the child %s: %v", binary, start_error)
		return {}, false
	}
	child.host_process = host_process
	child.started = time.tick_now()
	child.last_change = child.started
	return child, true
}

// What one look of the parent at a child saw.
Fuzz_Child_Poll :: enum {
	Running,
	Ended, // The process exited; its mailbox says how.
	Stalled, // Its count of executions did not grow for the hang bound.
}

// fuzz_child_poll looks once at a child that has not ended, and does not
// block. A child stalls when its count of executions does not grow for the
// hang bound: one execution that never returns. The parent marks it
// stalled; the caller ends it.
fuzz_child_poll :: proc(child: ^Fuzz_Running_Child) -> Fuzz_Child_Poll {
	// A wait of 0 does not block: Timeout says that the child runs.
	_, wait_error := os.process_wait(child.host_process, 0)
	if wait_error != os.General_Error.Timeout {
		child.ended = true
		return .Ended
	}
	count := intrinsics.atomic_load_explicit(&child.mailbox.executions, .Acquire)
	if count != child.last_count {
		child.last_count = count
		child.last_change = time.tick_now()
	} else if time.tick_since(child.last_change) > foundation.HANG_BOUND {
		child.stalled = true
		return .Stalled
	}
	return .Running
}

// fuzz_child_end kills a child that runs and waits for its end.
fuzz_child_end :: proc(child: ^Fuzz_Running_Child) {
	if child.ended {
		return
	}
	_ = os.process_kill(child.host_process)
	_, _ = os.process_wait(child.host_process)
	child.ended = true
}

// fuzz_children_watch waits until each child ended, or until one stalled
// or broke an oracle: then it ends the others. The children of a long run
// fuzz one target together, so one finding ends the run.
fuzz_children_watch :: proc(children: []Fuzz_Running_Child) {
	for {
		running := 0
		stop_all := false
		for &child in children {
			if child.ended {
				continue
			}
			switch fuzz_child_poll(&child) {
			case .Running:
				running += 1
			case .Ended:
				if intrinsics.atomic_load_explicit(&child.mailbox.state, .Acquire) != u32(Fuzz_Child_State.Done) {
					stop_all = true
				}
			case .Stalled:
				stop_all = true
			}
		}
		if stop_all {
			for &child in children {
				fuzz_child_end(&child)
			}
			return
		}
		if running == 0 {
			return
		}
		time.sleep(FUZZ_POLL_INTERVAL)
	}
}

// fuzz_fault_place finds the place of a bounds check of Odin in the
// standard error of a child: the file and its line and column, with no
// folder and no value.
fuzz_fault_place :: proc(error_text: string) -> string {
	at := strings.index(error_text, ".odin(")
	if at < 0 {
		return ""
	}
	start := strings.last_index_any(error_text[:at], "/\n ") + 1
	end := strings.index_byte(error_text[at:], ')')
	if end < 0 {
		return ""
	}
	return error_text[start:at + end + 1]
}

// fuzz_child_outcome reads what an ended child left.
fuzz_child_outcome :: proc(child: ^Fuzz_Running_Child) -> (outcome: Fuzz_Child_Outcome) {
	mailbox := child.mailbox
	state_word := intrinsics.atomic_load_explicit(&mailbox.state, .Acquire)
	state, state_known := enum_word.member_of_word(Fuzz_Child_State, u64(state_word))
	outcome.state = state
	outcome.executions = intrinsics.atomic_load_explicit(&mailbox.executions, .Acquire)
	outcome.kept = mailbox.kept
	outcome.edges_reached = mailbox.edges_reached
	outcome.edges = mailbox.edges
	outcome.corpus_inputs = mailbox.corpus_inputs
	outcome.seconds = time.duration_seconds(time.tick_since(child.started))
	input := fuzz_mailbox_input(mailbox)[:min(mailbox.input_length, FUZZ_INPUT_CAPACITY)]
	error_bytes, _ := os.read_entire_file(child.error_path, context.temp_allocator)
	error_text := string(error_bytes)
	// The mailbox is memory that the child writes: a word that names no
	// state, or no oracle, is a child that broke its mailbox.
	oracle, oracle_known := enum_word.member_of_word(Fuzz_Oracle, u64(mailbox.oracle))
	switch {
	case !state_known || state == .Finding && !oracle_known:
		outcome.oracle = .Fault
		outcome.text = fmt.tprintf("the mailbox of the child names the state %d and the oracle %d, one of which names nothing\n%s", state_word, mailbox.oracle, error_text)
		outcome.signature = "fault: the mailbox names no state or no oracle"
	case child.stalled:
		outcome.oracle = .End
		outcome.text = fmt.tprintf("an execution did not end in %v", foundation.HANG_BOUND)
		outcome.signature = "end"
	case outcome.state == .Finding:
		outcome.oracle = oracle
		outcome.text = strings.clone(string(mailbox.text[:min(int(mailbox.text_length), len(mailbox.text))]), context.temp_allocator)
		// The words before the first colon name the broken fact; the values
		// after it change with the input, so they are not a part of the
		// signature.
		head := outcome.text
		if colon := strings.index_byte(head, ':'); colon >= 0 {
			head = head[:colon]
		}
		outcome.signature = fmt.tprintf("%s: %s", fuzz_oracle_names[outcome.oracle], head)
	case outcome.state == .Fault:
		outcome.oracle = .Fault
		place := fuzz_fault_place(error_text)
		if place == "" {
			place = fmt.tprintf("signal %d at the instruction %+x", mailbox.signal, i64(mailbox.instruction_offset))
		}
		outcome.text = fmt.tprintf("signal %d at the address %x, %s\n%s", mailbox.signal, mailbox.fault_address, place, error_text)
		outcome.signature = fmt.tprintf("fault: %s", place)
	case outcome.state != .Done:
		// The child ended with no record: a signal that the handler does
		// not take, a lack of memory, or an exit of the code under test.
		outcome.oracle = .Fault
		outcome.text = fmt.tprintf("the child ended in the state %v\n%s", outcome.state, error_text)
		outcome.signature = "fault: the child ended with no record"
	}
	if outcome.oracle != .None {
		outcome.input = slice.clone(input, context.temp_allocator)
	}
	return outcome
}

// fuzz_child_run starts one child, waits for its end, and gives its
// outcome.
fuzz_child_run :: proc(binary: string, mode: Fuzz_Child_Mode, target: ^Fuzz_Target, seed: u64, executions: u64, file := "") -> (outcome: Fuzz_Child_Outcome, ok: bool) {
	child := fuzz_child_start(binary, mode, target, seed, executions, 0, file) or_return
	children := [1]Fuzz_Running_Child{child}
	fuzz_children_watch(children[:])
	return fuzz_child_outcome(&children[0]), true
}

// The state of the predicate of the minimizer.
Fuzz_Minimize_Data :: struct {
	binary:    string,
	target:    ^Fuzz_Target,
	signature: string,
	file:      string,
}

fuzz_still_found :: proc(data: rawptr, candidate: []u8) -> bool {
	state := (^Fuzz_Minimize_Data)(data)
	if error := os.write_entire_file(state.file, candidate); error != nil {
		return false
	}
	outcome, ok := fuzz_child_run(state.binary, .Replay, state.target, 0, 0, state.file)
	return ok && outcome.signature == state.signature
}

// fuzz_finding_keep minimizes a finding, writes its input and its text to
// the folder of the findings of the target, and prints them.
fuzz_finding_keep :: proc(binary: string, target: ^Fuzz_Target, outcome: Fuzz_Child_Outcome) -> (path: string, ok: bool) {
	folder := fuzz_run_folder(target.name, FUZZ_FINDINGS_PART)
	fmt.eprintfln("modustool: fuzz %s: a fuzz finding: %s", target.name, outcome.signature)
	fmt.eprintfln("modustool:   %s", outcome.text)
	data := Fuzz_Minimize_Data{binary = binary, target = target, signature = outcome.signature, file = strings.concatenate({fuzz_target_folder(target.name), "/candidate"}, context.temp_allocator)}
	smallest, tried := fuzz_minimize(outcome.input, fuzz_still_found, &data, FUZZ_MINIMIZE_CANDIDATE_LIMIT)
	defer delete(smallest)
	path = fuzz_input_write(folder, smallest) or_return
	text := fmt.tprintf("%s\n%s\n", outcome.signature, outcome.text)
	_ = os.write_entire_file(strings.concatenate({path, ".txt"}, context.temp_allocator), transmute([]u8)text)
	fmt.eprintfln("modustool:   minimized from %d to %d bytes in %d candidates: %s", len(outcome.input), len(smallest), tried, path)
	fmt.eprintfln("modustool:   `modustool fuzz show %s %s` prints it as the bytes of a host test", target.name, path)
	return path, true
}

// The tool packages that compile into the instrumented fuzz child: hashing
// only these packages keeps the check seed identical on the host and in the
// narrow Nix fuzz derivations, independent of site, machine, checks, and docs.
FUZZ_SEED_TOOL_FOLDERS :: [?]string {
	foundation.TOOL_SOURCE_FOLDER + "/foundation",
	foundation.TOOL_SOURCE_FOLDER + "/resources",
	foundation.TOOL_SOURCE_FOLDER + "/build",
	foundation.TOOL_SOURCE_FOLDER + "/fuzz",
	foundation.TOOL_SOURCE_FOLDER + "/fuzz_runner",
}

// fuzz_sources_seed gives the seed of `modustool check`: the BLAKE3 hash of
// the paths and the bytes of each source of the fuzz runner packages, of the
// source library and of the kernel parts, the inputs of the child. The same
// sources run the same inputs; a change of the code under test explores
// other ones.
fuzz_sources_seed :: proc() -> u64 {
	tool_folders := FUZZ_SEED_TOOL_FOLDERS
	return fuzz_sources_seed_of_tool_folders(tool_folders[:], foundation.SOURCE_FOLDER_LIBRARY, foundation.SOURCE_FOLDER_KERNEL)
}

// fuzz_sources_seed_of_folders gives the seed of the sources under three
// folders. The tool is read to any depth: each package of the tool is a
// folder under the folder of the tool, and a seed that skips one would
// run the same inputs after a change of its code.
fuzz_sources_seed_of_folders :: proc(tool_folder, library_folder, kernel_folder: string) -> u64 {
	tool_folders := [1]string{tool_folder}
	return fuzz_sources_seed_of_tool_folders(tool_folders[:], library_folder, kernel_folder)
}

// fuzz_sources_seed_of_tool_folders hashes each .odin file under tool_folders,
// library_folder, and each subfolder of kernel_folder.
fuzz_sources_seed_of_tool_folders :: proc(tool_folders: []string, library_folder, kernel_folder: string) -> u64 {
	paths := make([dynamic]string, context.temp_allocator)
	for folder in tool_folders {
		fuzz_sources_list(folder, &paths)
	}
	fuzz_sources_list(library_folder, &paths)
	// The kernel parts are the folders under the kernel; the files of the
	// kernel itself are no input of the child.
	if kernel_entries, kernel_error := os.read_all_directory_by_path(kernel_folder, context.temp_allocator); kernel_error == nil {
		for entry in kernel_entries {
			if entry.type == .Directory {
				fuzz_sources_list(entry.fullpath, &paths)
			}
		}
	}
	slice.sort(paths[:])
	all := make([dynamic]u8, context.temp_allocator)
	for path in paths {
		bytes, error := os.read_entire_file(path, context.temp_allocator)
		if error != nil {
			continue
		}
		hash := blake3.hash(bytes)
		append(&all, ..transmute([]u8)path)
		append(&all, ..hash[:])
	}
	hash := blake3.hash(all[:])
	return fuzz_word_read(hash[:], 0, 8, false)
}

// fuzz_source_is_test reports whether a file name is a host test source
// (*_test.odin or *_test_<arch>.odin), matching sourcesOfOdin in flake.nix so
// host and Nix fuzz seeds stay identical and test edits do not churn seeds.
@(private = "file")
fuzz_source_is_test :: proc(name: string) -> bool {
	stem := strings.trim_suffix(name, ".odin")
	return strings.has_suffix(stem, "_test") || strings.contains(stem, "_test_")
}

// fuzz_sources_list adds each non-test .odin file of a folder and of its
// subfolders, to any depth.
fuzz_sources_list :: proc(folder: string, paths: ^[dynamic]string) {
	entries, error := os.read_all_directory_by_path(folder, context.temp_allocator)
	if error != nil {
		return
	}
	for entry in entries {
		if entry.type == .Directory {
			fuzz_sources_list(entry.fullpath, paths)
		} else if entry.type == .Regular && strings.has_suffix(entry.name, ".odin") && !fuzz_source_is_test(entry.name) {
			append(paths, strings.concatenate({folder, "/", entry.name}, context.temp_allocator))
		}
	}
}

// fuzz_packages_of gives the packages under test of targets, each once.
fuzz_packages_of :: proc(targets: []Fuzz_Target) -> []string {
	packages := make([dynamic]string, context.temp_allocator)
	for target in targets {
		for item in target.packages {
			if !slice.contains(packages[:], item) {
				append(&packages, item)
			}
		}
	}
	return packages[:]
}

// One target of `modustool check` and what its child left.
Fuzz_Check_Child :: struct {
	target:      ^Fuzz_Target,
	executions:  u64,
	output_path: string, // The standard output of the child, "" for the one of the tool.
	child:       Fuzz_Running_Child,
	started:     bool,
	outcome:     Fuzz_Child_Outcome, // Read when the child ended.
}

// fuzz_check_children_at_once gives the count of the children of the
// check at once: one for each processor, no more than the targets and
// FUZZ_CHECK_CHILDREN_LIMIT, and at least one.
fuzz_check_children_at_once :: proc(target_count, processors: int) -> int {
	return max(1, min(target_count, processors, FUZZ_CHECK_CHILDREN_LIMIT))
}

// fuzz_check_children_run runs the child of each target, at most at_once
// at a time, in the order of the targets, and reads the outcome of each
// one when it ends. The targets are independent: a finding or a stall of
// one child ends that child only, so each target gets its own verdict, as
// when the children ran one after the other. A child that cannot start
// keeps started false.
fuzz_check_children_run :: proc(binary: string, runs: []Fuzz_Check_Child, seed: u64, at_once: int) {
	next := 0
	running := 0
	for next < len(runs) || running > 0 {
		for running < at_once && next < len(runs) {
			run := &runs[next]
			next += 1
			child, started := fuzz_child_start(binary, .Check, run.target, seed, run.executions, 0, output_path = run.output_path)
			if !started {
				continue
			}
			run.child = child
			run.started = true
			running += 1
		}
		ended_now := 0
		for &run in runs[:next] {
			if !run.started || run.child.ended {
				continue
			}
			switch fuzz_child_poll(&run.child) {
			case .Running:
				continue
			case .Stalled:
				fuzz_child_end(&run.child)
			case .Ended:
			}
			run.outcome = fuzz_child_outcome(&run.child)
			running -= 1
			ended_now += 1
		}
		// A child that just ended frees a place: the next one starts at
		// once, not after a poll interval.
		if running > 0 && ended_now == 0 {
			time.sleep(FUZZ_POLL_INTERVAL)
		}
	}
}

@(private = "file")
fuzz_parse_positive_decimal :: proc(text: string) -> (value: int, ok: bool) {
	if len(text) == 0 || strings.contains_any(text, " \t\n\r+-_") {
		return 0, false
	}
	for b in transmute([]u8)text {
		if b < '0' || b > '9' {
			return 0, false
		}
	}
	parsed, parsed_ok := strconv.parse_int(text, 10)
	if !parsed_ok || parsed < 1 {
		return 0, false
	}
	return parsed, true
}

// fuzz_parse_shard_args validates strict ASCII positive-decimal shard bounds
// (1 <= shard <= total), refusing signs, underscores, spaces, 0, and non-digits.
fuzz_parse_shard_args :: proc(shard_text, total_text: string) -> (shard, total: int, ok: bool) {
	s, s_ok := fuzz_parse_positive_decimal(shard_text)
	t, t_ok := fuzz_parse_positive_decimal(total_text)
	if !s_ok || !t_ok || s > t {
		return 0, 0, false
	}
	return s, t, true
}

// fuzz_shard_targets selects the 1-based strided slice of targets for shard
// out of total (index % total == shard - 1), preserving order so heavy targets
// spread evenly across shards. Refuses shard < 1, total < 1, or shard > total.
fuzz_shard_targets :: proc(targets: []Fuzz_Target, shard, total: int, allocator := context.temp_allocator) -> (selected: []Fuzz_Target, ok: bool) {
	if total < 1 || shard < 1 || shard > total {
		return nil, false
	}
	chosen := make([dynamic]Fuzz_Target, allocator)
	for target, index in targets {
		if index % total == shard - 1 {
			append(&chosen, target)
		}
	}
	return chosen[:], true
}

// fuzz_check is the part of `modustool check`: the form of the corpus, then
// for each target its corpus and a fixed count of new executions in the
// instrumented child, with the seed of the sources.
fuzz_check :: proc() -> bool {
	return fuzz_check_shard(1, 1)
}

// fuzz_check_shard runs one deterministic strided shard (1-based shard in
// 1..total) of the fuzz targets of `modustool check`. Shard 1 validates the
// corpus directory once so parallel shards do not duplicate corpus checks.
fuzz_check_shard :: proc(shard, total: int) -> bool {
	all_targets := fuzz_targets()
	targets, shard_ok := fuzz_shard_targets(all_targets, shard, total)
	if !shard_ok {
		fmt.eprintfln("modustool: fuzz shard %d of %d is out of range (shard must be in 1..total)", shard, total)
		return false
	}
	if shard == 1 && !fuzz_corpus_check() {
		return false
	}
	if len(targets) == 0 {
		fmt.printfln("modustool: measure: the fuzz targets of the check shard %d/%d (0 targets): 0.0 s on the clock", shard, total)
		return true
	}
	if !fuzz_instrumented_build(fuzz_packages_of(targets)) {
		return false
	}
	seed := fuzz_sources_seed()
	runs := make([]Fuzz_Check_Child, len(targets), context.temp_allocator)
	for &target, place in targets {
		executions := target.check_executions > 0 ? target.check_executions : FUZZ_CHECK_EXECUTIONS
		runs[place] = {
			target      = &target,
			executions  = u64(executions),
			output_path = strings.concatenate({fuzz_target_folder(target.name), "/check_output.txt"}, context.temp_allocator),
		}
	}
	processors := foundation.test_processors_of(os.get_processor_core_count(), os.get_env("NIX_BUILD_CORES", context.temp_allocator))
	at_once := fuzz_check_children_at_once(len(runs), processors)
	started := time.tick_now()
	fuzz_check_children_run(FUZZ_INSTRUMENTED_BINARY, runs, seed, at_once)
	whole := time.tick_since(started)
	all_passed := true
	for &run in runs {
		if !run.started {
			all_passed = false
			continue
		}
		if output, read_error := os.read_entire_file(run.output_path, context.temp_allocator); read_error == nil {
			os.write(os.stdout, output)
		}
		outcome := run.outcome
		if outcome.oracle != .None || outcome.state != .Done {
			fmt.eprintfln("modustool: test failed: the fuzz target %s, with the seed %d", run.target.name, seed)
			_, _ = fuzz_finding_keep(FUZZ_INSTRUMENTED_BINARY, run.target, outcome)
			all_passed = false
			continue
		}
		foundation.test_passed_print("the fuzz target %s ran its %d corpus inputs and %d new executions with no fuzz finding; %d of %d edges reached", run.target.name, outcome.corpus_inputs, run.executions, outcome.edges_reached, outcome.edges)
	}
	if total == 1 {
		fmt.printfln("modustool: measure: the fuzz targets of the check (%d targets): %.1f s on the clock, at most %d at once", len(runs), time.duration_seconds(whole), at_once)
	} else {
		fmt.printfln("modustool: measure: the fuzz targets of the check shard %d/%d (%d targets): %.1f s on the clock, at most %d at once", shard, total, len(runs), time.duration_seconds(whole), at_once)
	}
	return all_passed
}

// fuzz_print_literal prints an input as the bytes of an Odin array, for a
// named host test of the package of the reader.
fuzz_print_literal :: proc(name: string, input: []u8) {
	fmt.printfln("// The input %s: %d bytes.", name, len(input))
	fmt.println("input := [?]u8{")
	for start := 0; start < len(input); start += 16 {
		line := strings.builder_make(context.temp_allocator)
		strings.write_string(&line, "\t")
		for value, index in input[start:min(start + 16, len(input))] {
			if index > 0 {
				strings.write_string(&line, " ")
			}
			fmt.sbprintf(&line, "0x%02x,", value)
		}
		fmt.println(strings.to_string(line))
	}
	fmt.println("}")
}
