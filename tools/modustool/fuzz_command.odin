package modustool

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "modus:contract/blake3"
import "modus:contract/enum_word"

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
	process:       os.Process,
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
// memory of a long run.
fuzz_child_start :: proc(binary: string, mode: Fuzz_Child_Mode, target: ^Fuzz_Target, seed: u64, executions: u64, number: int, file := "") -> (child: Fuzz_Running_Child, ok: bool) {
	folder := fuzz_target_folder(target.name)
	if !make_folder(folder) {
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
	command := make([dynamic]string, context.temp_allocator)
	append(&command, binary, "fuzz-child", fuzz_child_mode_names[mode], target.name, mailbox_path, fmt.tprintf("%d", seed), fmt.tprintf("%d", executions))
	if file != "" {
		append(&command, file)
	}
	process, start_error := os.process_start({command = command[:], stdout = os.stdout, stderr = error_file})
	if start_error != nil {
		fmt.eprintfln("modustool: cannot start the child %s: %v", binary, start_error)
		return {}, false
	}
	child.process = process
	child.started = time.tick_now()
	child.last_change = child.started
	return child, true
}

// fuzz_children_watch waits until each child ended, or until one stalled
// or broke an oracle: then it ends the others. A child stalls when its
// count of executions does not grow for the hang bound: one execution
// that never returns.
fuzz_children_watch :: proc(children: []Fuzz_Running_Child) {
	for {
		running := 0
		stop_all := false
		for &child in children {
			if child.ended {
				continue
			}
			// A wait of 0 does not block: Timeout says that the child runs.
			_, wait_error := os.process_wait(child.process, 0)
			if wait_error != os.General_Error.Timeout {
				child.ended = true
				if intrinsics.atomic_load_explicit(&child.mailbox.state, .Acquire) != u32(Fuzz_Child_State.Done) {
					stop_all = true
				}
				continue
			}
			running += 1
			count := intrinsics.atomic_load_explicit(&child.mailbox.executions, .Acquire)
			if count != child.last_count {
				child.last_count = count
				child.last_change = time.tick_now()
			} else if time.tick_since(child.last_change) > HANG_BOUND {
				child.stalled = true
				stop_all = true
			}
		}
		if stop_all {
			for &child in children {
				if !child.ended {
					_ = os.process_kill(child.process)
					_, _ = os.process_wait(child.process)
					child.ended = true
				}
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
		outcome.text = fmt.tprintf("an execution did not end in %v", HANG_BOUND)
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

// fuzz_sources_seed gives the seed of `modustool check`: the BLAKE3 hash of
// the paths and the bytes of each source of the tool and of the source
// library, the inputs of the child. The same sources run the same inputs;
// a change of the code under test explores other ones.
fuzz_sources_seed :: proc() -> u64 {
	paths := make([dynamic]string, context.temp_allocator)
	fuzz_sources_list(TOOL_SOURCE_FOLDER, &paths, recursive = false)
	fuzz_sources_list(SOURCE_FOLDER_LIBRARY, &paths, recursive = true)
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

fuzz_sources_list :: proc(folder: string, paths: ^[dynamic]string, recursive: bool) {
	entries, error := os.read_all_directory_by_path(folder, context.temp_allocator)
	if error != nil {
		return
	}
	for entry in entries {
		if entry.type == .Directory && recursive {
			fuzz_sources_list(entry.fullpath, paths, recursive)
		} else if entry.type == .Regular && strings.has_suffix(entry.name, ".odin") {
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

// fuzz_check is the part of `modustool check`: the form of the corpus, then
// for each target its corpus and a fixed count of new executions in the
// instrumented child, with the seed of the sources.
fuzz_check :: proc() -> bool {
	if !fuzz_corpus_check() {
		return false
	}
	targets := fuzz_targets()
	if !fuzz_instrumented_build(fuzz_packages_of(targets)) {
		return false
	}
	seed := fuzz_sources_seed()
	all_passed := true
	for &target in targets {
		executions := target.check_executions > 0 ? target.check_executions : FUZZ_CHECK_EXECUTIONS
		outcome, started := fuzz_child_run(FUZZ_INSTRUMENTED_BINARY, .Check, &target, seed, u64(executions))
		if !started {
			all_passed = false
			continue
		}
		if outcome.oracle != .None || outcome.state != .Done {
			fmt.eprintfln("modustool: test failed: the fuzz target %s, with the seed %d", target.name, seed)
			_, _ = fuzz_finding_keep(FUZZ_INSTRUMENTED_BINARY, &target, outcome)
			all_passed = false
			continue
		}
		test_passed_print("the fuzz target %s ran its %d corpus inputs and %d new executions with no fuzz finding; %d of %d edges reached", target.name, outcome.corpus_inputs, executions, outcome.edges_reached, outcome.edges)
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

// run_fuzz is the command `fuzz` (docs/TOOLS.md, "The fuzzing").
run_fuzz :: proc(args: []string) -> int {
	usage_text :: "modustool: fuzz list | <target> [<executions> [<processes> [<seed>]]] | all [<executions>] | show <target> <file> | minimize <target> <file> | regression <target> <file> | corpus <target>"
	if len(args) == 0 {
		fmt.eprintln(usage_text)
		return EXIT_USAGE
	}
	targets := fuzz_targets()
	switch args[0] {
	case "list":
		for target in targets {
			regression := fuzz_inputs_read(fuzz_corpus_folder(target.name, FUZZ_REGRESSION_PART), context.temp_allocator)
			reach := fuzz_inputs_read(fuzz_corpus_folder(target.name, FUZZ_REACH_PART), context.temp_allocator)
			fmt.printfln("  %-26s %-9v %3d regression, %3d reach  %s", target.name, target.kind, len(regression), len(reach), target.about)
		}
		return 0
	case "show", "minimize", "regression":
		if len(args) != 3 {
			fmt.eprintln(usage_text)
			return EXIT_USAGE
		}
		target, found := fuzz_target_find(targets, args[1])
		if !found {
			fmt.eprintfln("modustool: no fuzz target %s; `modustool fuzz list` names them", args[1])
			return EXIT_USAGE
		}
		input, error := os.read_entire_file(args[2], context.allocator)
		if error != nil {
			fmt.eprintfln("modustool: cannot read %s: %v", args[2], error)
			return EXIT_FAILURE
		}
		// This binary: no instrumentation is needed to replay one input.
		binary := os.args[0]
		outcome, started := fuzz_child_run(binary, .Replay, target, 0, 0, args[2])
		if !started {
			return EXIT_FAILURE
		}
		switch args[0] {
		case "show":
			if outcome.oracle == .None {
				fmt.printfln("modustool: fuzz %s: %s breaks no oracle", target.name, args[2])
			} else {
				fmt.printfln("modustool: fuzz %s: %s: %s", target.name, outcome.signature, outcome.text)
			}
			fuzz_print_literal(fuzz_input_name(input), input)
		case "minimize":
			if outcome.oracle == .None {
				fmt.printfln("modustool: fuzz %s: %s breaks no oracle: nothing to minimize", target.name, args[2])
				return 0
			}
			if _, kept := fuzz_finding_keep(binary, target, outcome); !kept {
				return EXIT_FAILURE
			}
		case "regression":
			// A regression input enters the corpus after the fix of its
			// fault: it must break no oracle now.
			if outcome.oracle != .None {
				fmt.eprintfln("modustool: fuzz %s: %s still breaks an oracle (%s): fix the fault first", target.name, args[2], outcome.signature)
				return EXIT_FAILURE
			}
			path, written := fuzz_input_write(fuzz_corpus_folder(target.name, FUZZ_REGRESSION_PART), input)
			if !written {
				return EXIT_FAILURE
			}
			fmt.printfln("modustool: fuzz %s: the regression input %s", target.name, path)
		}
		return 0
	case "corpus":
		if len(args) != 2 {
			fmt.eprintln(usage_text)
			return EXIT_USAGE
		}
		target, found := fuzz_target_find(targets, args[1])
		if !found {
			fmt.eprintfln("modustool: no fuzz target %s; `modustool fuzz list` names them", args[1])
			return EXIT_USAGE
		}
		if !fuzz_instrumented_build(target.packages) {
			return EXIT_FAILURE
		}
		outcome, started := fuzz_child_run(FUZZ_INSTRUMENTED_BINARY, .Corpus, target, 0, 0)
		if !started || outcome.state != .Done {
			if started && outcome.oracle != .None {
				_, _ = fuzz_finding_keep(FUZZ_INSTRUMENTED_BINARY, target, outcome)
			}
			return EXIT_FAILURE
		}
		return 0
	}
	// A run: one target, or all of them in turn.
	// A run always has a count: a forgotten argument must not start a run
	// with no end, so the default is the count of the check, and 0 is
	// refused. A long run names its count.
	executions := u64(FUZZ_CHECK_EXECUTIONS)
	processes := 1
	seed := fuzz_sources_seed() ~ u64(time.time_to_unix_nano(time.now()))
	if len(args) >= 2 {
		value, ok := strconv.parse_u64(args[1])
		if !ok || value == 0 {
			fmt.eprintln("modustool: the count of executions is a number of 1 or more; a long run names its count, as 100000000")
			fmt.eprintln(usage_text)
			return EXIT_USAGE
		}
		executions = value
	}
	if len(args) >= 3 {
		value, ok := strconv.parse_int(args[2])
		if !ok || value < 1 {
			fmt.eprintln(usage_text)
			return EXIT_USAGE
		}
		processes = value
	}
	if len(args) >= 4 {
		value, ok := strconv.parse_u64(args[3])
		if !ok {
			fmt.eprintln(usage_text)
			return EXIT_USAGE
		}
		seed = value
	}
	chosen := make([dynamic]^Fuzz_Target, context.temp_allocator)
	if args[0] == "all" {
		for &target in targets {
			append(&chosen, &target)
		}
	} else {
		target, found := fuzz_target_find(targets, args[0])
		if !found {
			fmt.eprintfln("modustool: no fuzz target %s; `modustool fuzz list` names them", args[0])
			return EXIT_USAGE
		}
		append(&chosen, target)
	}
	packages := make([dynamic]string, context.temp_allocator)
	for target in chosen {
		for item in target.packages {
			if !slice.contains(packages[:], item) {
				append(&packages, item)
			}
		}
	}
	if !fuzz_instrumented_build(packages[:]) {
		return EXIT_FAILURE
	}
	for target in chosen {
		fmt.printfln("modustool: fuzz %s: the seed %d, %d processes", target.name, seed, processes)
		children := make([]Fuzz_Running_Child, processes)
		defer delete(children)
		for &child, number in children {
			started: bool
			child, started = fuzz_child_start(FUZZ_INSTRUMENTED_BINARY, .Run, target, seed + u64(number), executions, number)
			if !started {
				return EXIT_FAILURE
			}
		}
		fuzz_children_watch(children)
		for &child in children {
			outcome := fuzz_child_outcome(&child)
			if outcome.oracle != .None {
				_, _ = fuzz_finding_keep(FUZZ_INSTRUMENTED_BINARY, target, outcome)
				return EXIT_FAILURE
			}
		}
	}
	return 0
}
