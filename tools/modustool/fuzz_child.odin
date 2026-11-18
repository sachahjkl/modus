package modustool

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "modustool:foundation"

// The child of the fuzzing (src/md/infrastructure/fuzzing.md, "The harness
// is the tool"): a second copy of the tool, started as `fuzz-child`, that
// runs the engine on one fuzz target. A fault of the code under test ends
// the child, not the tool. The child and its parent share the mailbox, a
// file that both map: before each execution the child copies the input
// there and adds one to its count of executions.

FUZZ_PAGE_SIZE :: 4096
FUZZ_MAILBOX_MAGIC :: u64(0x584F_424C_4941_4D5A) // The bytes "ZMAILBOX".
FUZZ_MAILBOX_HEADER_SIZE :: 8192 // The record of the mailbox; the input follows it.
// The most bytes of one input of any target: the room of the input in the
// mailbox and in the arena.
FUZZ_INPUT_CAPACITY :: 1 << 20
FUZZ_MAILBOX_SIZE :: FUZZ_MAILBOX_HEADER_SIZE + FUZZ_INPUT_CAPACITY

// The exit codes of the child.
FUZZ_EXIT_FINDING :: 3 // An execution broke an oracle: the mailbox holds the input and the verdict.
FUZZ_EXIT_FAULT :: 4 // The handler caught a fault: the mailbox holds the input, the signal and the place.

// The child reads the folder of the run again after this count of
// executions, for the inputs that the other processes kept: a count, so
// that one seed gives one run.
FUZZ_SYNC_EXECUTIONS :: 4096

Fuzz_Child_State :: enum u32 {
	Starting = 0, // The child did not run its first execution yet.
	Running  = 1, // The child runs executions.
	Done     = 2, // The child ran each execution that it was asked for, with no fuzz finding.
	Finding  = 3, // An execution broke an oracle.
	Fault    = 4, // The handler caught a fault.
}

// The mode of the child: what the parent asks of it.
Fuzz_Child_Mode :: enum {
	Run, // Fuzz: the corpus, the folder of the run, then new executions.
	Check, // The corpus, then a fixed count of new executions, for `modustool check`.
	Replay, // One input, in each of its two places.
	Corpus, // The smallest set of the kept inputs that gives each edge class: the reach inputs.
}

@(rodata)
fuzz_child_mode_names := [Fuzz_Child_Mode]string {
	.Run    = "run",
	.Check  = "check",
	.Replay = "replay",
	.Corpus = "corpus",
}

// The record at the start of the mailbox. The parent writes the magic; the
// child writes the rest. The count of executions and the state are atomic:
// the parent reads them while the child runs.
Fuzz_Mailbox :: struct {
	magic:              u64,
	executions:         u64, // The executions so far.
	input_length:       u64, // The bytes of the input of the last execution.
	state:              u32, // A Fuzz_Child_State.
	oracle:             u32, // A Fuzz_Oracle, with the state Finding.
	signal:             i32, // The signal of a fault.
	reserved:           u32,
	fault_address:      u64, // The address that the fault named.
	instruction_offset: u64, // The faulting instruction, from the start of the handler: a place in this binary.
	kept:               u64, // The inputs that this run kept.
	entries:            u64, // The inputs in memory.
	edges_reached:      u64, // The edges that the inputs in memory ran.
	edges:              u64, // The edges of the instrumented packages.
	corpus_inputs:      u64, // The inputs of the corpus that the child ran.
	text_length:        u64,
	text:               [FUZZ_VERDICT_TEXT_CAPACITY]u8, // The verdict of a finding.
}
#assert(size_of(Fuzz_Mailbox) <= FUZZ_MAILBOX_HEADER_SIZE)

// The room of one input between two pages with no access.
Fuzz_Input_Arena :: struct {
	data: []u8,
}

// The state of the child for its executor.
Fuzz_Child :: struct {
	mailbox: ^Fuzz_Mailbox,
	arena:   Fuzz_Input_Arena,
	kept_folder: string,
	kept_names: map[string]bool, // The inputs of the folder of the run that this child read or wrote.
}

fuzz_child_state: Fuzz_Child

fuzz_mailbox_input :: proc(mailbox: ^Fuzz_Mailbox) -> []u8 {
	return ([^]u8)(mailbox)[FUZZ_MAILBOX_HEADER_SIZE:][:FUZZ_INPUT_CAPACITY]
}

// fuzz_execute_in_child copies the input into the mailbox, places it
// against one of the two pages with no access (the end of the arena on an
// even count of executions, the start on an odd one), and runs it.
fuzz_execute_in_child :: proc(engine: ^Fuzz_Engine, input: []u8) -> Fuzz_Verdict {
	child := &fuzz_child_state
	length := min(len(input), len(child.arena.data))
	copy(fuzz_mailbox_input(child.mailbox), input[:length])
	child.mailbox.input_length = u64(length)
	intrinsics.atomic_add_explicit(&child.mailbox.executions, 1, .Release)
	placed: []u8
	if engine.executions % 2 == 0 {
		placed = child.arena.data[len(child.arena.data) - length:]
	} else {
		placed = child.arena.data[:length]
	}
	copy(placed, input[:length])
	return fuzz_execute_direct(engine, placed)
}

// fuzz_child_keep writes an input that the engine kept to the folder of
// the run.
fuzz_child_keep :: proc(engine: ^Fuzz_Engine, input: []u8) {
	child := &fuzz_child_state
	if path, ok := fuzz_input_write(child.kept_folder, input); ok {
		name := path[strings.last_index_byte(path, '/') + 1:]
		child.kept_names[strings.clone(name)] = true
	}
	child.mailbox.kept += 1
}

// fuzz_child_sync reads the inputs of the folder of the run that another
// process kept.
fuzz_child_sync :: proc(engine: ^Fuzz_Engine) -> Fuzz_Verdict {
	child := &fuzz_child_state
	// Not in the temporary memory: each execution frees it.
	inputs := fuzz_inputs_read(child.kept_folder, context.allocator)
	defer {
		for input in inputs {
			delete(input.name)
			delete(input.bytes)
		}
		delete(inputs)
	}
	for input in inputs {
		if input.name in child.kept_names {
			continue
		}
		child.kept_names[strings.clone(input.name)] = true
		if verdict := fuzz_engine_add(engine, input.bytes); verdict.oracle != .None {
			return verdict
		}
	}
	return FUZZ_PASSED
}

// fuzz_child_report writes the counts of the engine into the mailbox.
fuzz_child_report :: proc(engine: ^Fuzz_Engine) {
	mailbox := fuzz_child_state.mailbox
	mailbox.entries = u64(len(engine.entries))
	mailbox.edges_reached = u64(fuzz_edges_reached(engine))
	mailbox.edges = u64(fuzz_counter_count())
}

// fuzz_child_finding writes a verdict that broke an oracle into the
// mailbox: the input of the execution is there already.
fuzz_child_finding :: proc(verdict: Fuzz_Verdict) -> int {
	mailbox := fuzz_child_state.mailbox
	mailbox.oracle = u32(verdict.oracle)
	count := copy(mailbox.text[:], verdict.text)
	mailbox.text_length = u64(count)
	intrinsics.atomic_store_explicit(&mailbox.state, u32(Fuzz_Child_State.Finding), .Release)
	return FUZZ_EXIT_FINDING
}

// The corpus inputs of a target: the regression inputs first, so that a
// fixed fault runs first, then the reach inputs.
fuzz_child_corpus :: proc(target_name: string) -> (inputs: [dynamic]Fuzz_Stored_Input, regression_count: int) {
	inputs = make([dynamic]Fuzz_Stored_Input)
	append(&inputs, ..fuzz_inputs_read(fuzz_corpus_folder(target_name, FUZZ_REGRESSION_PART)))
	regression_count = len(inputs)
	append(&inputs, ..fuzz_inputs_read(fuzz_corpus_folder(target_name, FUZZ_REACH_PART)))
	return inputs, regression_count
}

// run_fuzz_child is the command `fuzz-child <mode> <target> <mailbox>
// <seed> <executions> [<file>]` (src/md/infrastructure/fuzzing.md, "The
// harness is the tool"). The parent starts it; it is not a command to run
// by hand.
run_fuzz_child :: proc(args: []string) -> int {
	if len(args) < 5 {
		fmt.eprintln("modustool: fuzz-child <run|check|replay|corpus> <target> <mailbox> <seed> <executions> [<file>]")
		return foundation.EXIT_USAGE
	}
	mode: Fuzz_Child_Mode
	mode_found := false
	for name, item in fuzz_child_mode_names {
		if name == args[0] {
			mode, mode_found = item, true
		}
	}
	target, target_found := fuzz_target_find(fuzz_targets(), args[1])
	seed, seed_ok := strconv.parse_u64(args[3])
	executions, executions_ok := strconv.parse_u64(args[4])
	if !mode_found || !target_found || !seed_ok || !executions_ok || (mode == .Replay && len(args) < 6) {
		fmt.eprintln("modustool: fuzz-child: a wrong argument")
		return foundation.EXIT_USAGE
	}
	child := &fuzz_child_state
	mailbox, mapped := fuzz_mailbox_map(args[2], create = false)
	if !mapped || mailbox.magic != FUZZ_MAILBOX_MAGIC {
		fmt.eprintfln("modustool: fuzz-child: cannot map the mailbox %s", args[2])
		return foundation.EXIT_FAILURE
	}
	child.mailbox = mailbox
	arena, arena_ok := fuzz_input_arena_make(target.input_limit)
	if !arena_ok || !fuzz_fault_handlers_install(mailbox) {
		fmt.eprintln("modustool: fuzz-child: cannot prepare the input arena and the handler of the faults")
		return foundation.EXIT_FAILURE
	}
	child.arena = arena
	child.kept_folder = strings.clone(fuzz_run_folder(target.name, FUZZ_KEPT_PART))
	child.kept_names = make(map[string]bool)
	if target.start != nil && !target.start() {
		fmt.eprintfln("modustool: fuzz-child: the target %s cannot start", target.name)
		return foundation.EXIT_FAILURE
	}
	engine: Fuzz_Engine
	fuzz_engine_init(&engine, target, seed, fuzz_execute_in_child)
	defer fuzz_engine_destroy(&engine)
	intrinsics.atomic_store_explicit(&mailbox.state, u32(Fuzz_Child_State.Running), .Release)
	switch mode {
	case .Replay:
		input, error := os.read_entire_file(args[5], context.allocator)
		if error != nil {
			fmt.eprintfln("modustool: fuzz-child: cannot read %s: %v", args[5], error)
			return foundation.EXIT_FAILURE
		}
		// Two executions: the input against the page after it, then
		// against the page before it.
		for _ in 0 ..< 2 {
			if verdict := engine.executor(&engine, input[:min(len(input), target.input_limit)]); verdict.oracle != .None {
				return fuzz_child_finding(verdict)
			}
		}
	case .Run, .Check:
		return fuzz_child_fuzz(&engine, mode, executions)
	case .Corpus:
		return fuzz_child_reach(&engine)
	}
	intrinsics.atomic_store_explicit(&mailbox.state, u32(Fuzz_Child_State.Done), .Release)
	return 0
}

// fuzz_child_fuzz runs the corpus, each input in its two places, then the
// inputs of the folder of the run (Run only), then `executions` new
// inputs; 0 is no bound in the mode Run.
fuzz_child_fuzz :: proc(engine: ^Fuzz_Engine, mode: Fuzz_Child_Mode, executions: u64) -> int {
	mailbox := fuzz_child_state.mailbox
	fuzz_dictionary_fill(engine)
	inputs, regression_count := fuzz_child_corpus(engine.target.name)
	for input, index in inputs {
		if verdict := fuzz_engine_add(engine, input.bytes, always = index < regression_count); verdict.oracle != .None {
			return fuzz_child_finding(verdict)
		}
		if verdict := engine.executor(engine, input.bytes[:min(len(input.bytes), engine.target.input_limit)]); verdict.oracle != .None {
			return fuzz_child_finding(verdict)
		}
		mailbox.corpus_inputs += 1
	}
	if mode == .Run {
		engine.kept = fuzz_child_keep
		if verdict := fuzz_child_sync(engine); verdict.oracle != .None {
			return fuzz_child_finding(verdict)
		}
	}
	if verdict := fuzz_engine_start(engine); verdict.oracle != .None {
		return fuzz_child_finding(verdict)
	}
	fuzz_child_report(engine)
	started := time.tick_now()
	done: u64
	for executions == 0 || done < executions {
		if verdict := fuzz_engine_step(engine); verdict.oracle != .None {
			return fuzz_child_finding(verdict)
		}
		done += 1
		if done % FUZZ_SYNC_EXECUTIONS == 0 {
			fuzz_child_report(engine)
			if mode == .Run {
				if verdict := fuzz_child_sync(engine); verdict.oracle != .None {
					return fuzz_child_finding(verdict)
				}
			}
		}
	}
	fuzz_child_report(engine)
	seconds := time.duration_seconds(time.tick_since(started))
	// The rate is a measure, printed for a reader; nothing checks it.
	fmt.printfln("modustool: fuzz %s: %d corpus inputs, %d new executions, %d inputs kept, %d of %d edges reached, %.0f executions in one second (a measure)", engine.target.name, mailbox.corpus_inputs, done, mailbox.kept, mailbox.edges_reached, mailbox.edges, seconds > 0 ? f64(done) / seconds : 0)
	intrinsics.atomic_store_explicit(&mailbox.state, u32(Fuzz_Child_State.Done), .Release)
	return 0
}

// fuzz_child_reach writes the reach inputs of a target: it runs the
// regression inputs, then the reach inputs and the inputs that the long
// runs kept from the smallest to the largest, and keeps each one that
// gives an edge class that no input before it gave. The new set replaces
// the reach inputs of the repository, within the bounds of the corpus.
fuzz_child_reach :: proc(engine: ^Fuzz_Engine) -> int {
	mailbox := fuzz_child_state.mailbox
	inputs, regression_count := fuzz_child_corpus(engine.target.name)
	regression_bytes := 0
	for input in inputs[:regression_count] {
		if verdict := fuzz_engine_add(engine, input.bytes, always = true); verdict.oracle != .None {
			return fuzz_child_finding(verdict)
		}
		regression_bytes += len(input.bytes)
	}
	candidates := make([dynamic]Fuzz_Stored_Input)
	append(&candidates, ..inputs[regression_count:])
	append(&candidates, ..fuzz_inputs_read(fuzz_run_folder(engine.target.name, FUZZ_KEPT_PART)))
	sort_inputs_by_size(candidates[:])
	reach := make([dynamic][]u8)
	reach_bytes := 0
	for candidate in candidates {
		before := len(engine.entries)
		if verdict := fuzz_engine_add(engine, candidate.bytes); verdict.oracle != .None {
			return fuzz_child_finding(verdict)
		}
		if len(engine.entries) == before {
			continue
		}
		if regression_count + len(reach) + 1 > FUZZ_CORPUS_TARGET_INPUT_LIMIT || regression_bytes + reach_bytes + len(candidate.bytes) > FUZZ_CORPUS_TARGET_BYTE_LIMIT {
			break
		}
		append(&reach, candidate.bytes)
		reach_bytes += len(candidate.bytes)
	}
	folder := fuzz_corpus_folder(engine.target.name, FUZZ_REACH_PART)
	if !foundation.reset_folder(folder) {
		return foundation.EXIT_FAILURE
	}
	for input in reach {
		if _, ok := fuzz_input_write(folder, input); !ok {
			return foundation.EXIT_FAILURE
		}
	}
	fuzz_child_report(engine)
	mailbox.kept = u64(len(reach))
	fmt.printfln("modustool: fuzz corpus %s: %d reach inputs of %d bytes from %d candidates, beside %d regression inputs; %d of %d edges reached", engine.target.name, len(reach), reach_bytes, len(candidates), regression_count, mailbox.edges_reached, mailbox.edges)
	intrinsics.atomic_store_explicit(&mailbox.state, u32(Fuzz_Child_State.Done), .Release)
	return 0
}

// sort_inputs_by_size orders inputs from the shortest to the longest, then
// by name: a shorter input reaches the same edge with less to read.
sort_inputs_by_size :: proc(inputs: []Fuzz_Stored_Input) {
	for index in 1 ..< len(inputs) {
		item := inputs[index]
		place := index
		for place > 0 && (len(inputs[place - 1].bytes) > len(item.bytes) || (len(inputs[place - 1].bytes) == len(item.bytes) && inputs[place - 1].name > item.name)) {
			inputs[place] = inputs[place - 1]
			place -= 1
		}
		inputs[place] = item
	}
}
