package fuzz

import "core:fmt"
import "core:slice"

// The engine of the fuzzing (src/md/infrastructure/fuzzing.md): it keeps
// the fuzz inputs that reached new edges, makes a new input from one of
// them with the mutators, runs the fuzz target on it and checks its
// oracles. It runs in one process: the child of `modustool fuzz` and of
// `modustool check`, or a host test of the tool. Its decisions come from
// its own generator and from the edge counters only, so one seed and one
// binary give one run.

// The kind of a fuzz target (docs/glossary/project.md, "Fuzz target").
Fuzz_Target_Kind :: enum u8 {
	Raw, // The input is the bytes that the system reads.
	Generated, // The input is the choices of a generator that builds a whole value.
}

// The oracle that an execution broke (docs/glossary/project.md, "Oracle"). The
// order is the order in which a target checks them.
Fuzz_Oracle :: enum u8 {
	None        = 0, // The execution broke no oracle.
	Fault       = 1, // The code faulted: a bounds check of Odin, an access past the input, a division by zero.
	End         = 2, // The execution did not end before the hang bound.
	Contract    = 3, // A result breaks the contract that its reader documents.
	Round_Trip  = 4, // What the reader accepts and the writer writes again is not the same value.
	Model       = 5, // The code and its model give two answers.
	Two_Readers = 6, // Two readers of the system do not agree on one fact.
}

@(rodata)
fuzz_oracle_names := [Fuzz_Oracle]string {
	.None        = "no oracle",
	.Fault       = "fault",
	.End         = "end",
	.Contract    = "contract",
	.Round_Trip  = "round trip",
	.Model       = "model",
	.Two_Readers = "two readers",
}

// What one execution of a fuzz target gives: the oracle that it broke,
// and what it saw, in words. The text is in the temporary allocator.
Fuzz_Verdict :: struct {
	oracle: Fuzz_Oracle,
	text:   string,
}

FUZZ_PASSED :: Fuzz_Verdict{}

// fuzz_broken gives the verdict of an oracle that an execution broke.
fuzz_broken :: proc(oracle: Fuzz_Oracle, format: string, args: ..any) -> Fuzz_Verdict {
	return {oracle = oracle, text = fmt.tprintf(format, ..args)}
}

// A region of an input that the reader of a format takes as records of one
// type: the field mutator writes one of their fields.
Fuzz_Region :: struct {
	offset: int, // From the start of the input.
	type:   typeid, // The type of one record: a struct of a contract package.
	count:  int, // The records that follow each other.
}

// One fuzz target (docs/glossary/project.md, "Fuzz target").
Fuzz_Target :: struct {
	name:        string, // The name of the target in the commands and in the folder of its corpus.
	kind:        Fuzz_Target_Kind,
	about:       string, // What it checks, for `fuzz list`.
	// The folders of the packages under test, from the root of the
	// repository and made from the constants of the folders
	// (SOURCE_FOLDER_CONTRACT + "/module", SOURCE_FOLDER_KERNEL + "/iommu"):
	// the instrumented build counts their edges, and the dictionary reads
	// their constants.
	packages:    []string,
	input_limit: int, // The most bytes of one input, at most FUZZ_INPUT_CAPACITY.
	// The new executions of the target in `modustool check`; 0 gives
	// FUZZ_CHECK_EXECUTIONS. A target whose execution does much (a whole
	// handshake) asks for fewer.
	check_executions: int,
	execute:     proc(input: []u8) -> Fuzz_Verdict, // Runs the code of the system on one input, then checks the oracles.
	// Optional. Adds inputs to start from when the corpus has none; each
	// input is in the allocator of the context.
	seeds:       proc(seeds: ^[dynamic][]u8),
	// Optional. Gives the regions of records of an input, for the field
	// mutator.
	regions:     proc(input: []u8, regions: ^[dynamic]Fuzz_Region),
	// Optional. Runs once in a process before the first execution: the
	// state that each execution resets, made one time.
	start:       proc() -> bool,
	// Optional. Words of the dictionary that the sources do not give as a
	// constant.
	words:       proc(words: ^[dynamic][]u8),
}

// One kept input, and the count of the features that it gave first.
Fuzz_Entry :: struct {
	input:    []u8,
	features: int,
}

// The procedure that runs a target on one input: the child places the
// input before a page with no access and writes it to the mailbox first;
// a host test calls the target with no more.
Fuzz_Executor :: #type proc(engine: ^Fuzz_Engine, input: []u8) -> Fuzz_Verdict

// The most inputs that the engine keeps in memory in one run.
FUZZ_ENTRY_CAPACITY :: 1 << 16

// The verdict text that the engine keeps after its temporary memory is
// freed.
FUZZ_VERDICT_TEXT_CAPACITY :: 2048

Fuzz_Engine :: struct {
	target:        ^Fuzz_Target,
	random:        Fuzz_Random,
	executor:      Fuzz_Executor,
	entries:       [dynamic]Fuzz_Entry,
	// A bit for each feature that a kept input gave: an edge and the class
	// of its count.
	seen:          []u8,
	feature_count: int,
	dictionary:    [dynamic][]u8,
	regions:       [dynamic]Fuzz_Region,
	mutated:       [dynamic]u8, // The input of the next execution.
	executions:    u64,
	// The procedure that is called with each input that the engine keeps:
	// the child writes it to the folder of the run. Optional.
	kept:          proc(engine: ^Fuzz_Engine, input: []u8),
	keep_data:     rawptr,
	verdict_text:  [FUZZ_VERDICT_TEXT_CAPACITY]u8,
}

// fuzz_engine_init prepares an engine for a target, with a seed and the
// dictionary of the packages of the target.
fuzz_engine_init :: proc(engine: ^Fuzz_Engine, target: ^Fuzz_Target, seed: u64, executor: Fuzz_Executor = fuzz_execute_direct) {
	engine.target = target
	engine.random = {state = seed}
	engine.executor = executor
	engine.entries = make([dynamic]Fuzz_Entry)
	engine.dictionary = make([dynamic][]u8)
	engine.regions = make([dynamic]Fuzz_Region)
	engine.mutated = make([dynamic]u8)
	counters := fuzz_counter_count()
	engine.seen = make([]u8, (counters * FUZZ_COUNT_CLASSES + 7) / 8)
}

fuzz_engine_destroy :: proc(engine: ^Fuzz_Engine) {
	for entry in engine.entries {
		delete(entry.input)
	}
	delete(engine.entries)
	for word in engine.dictionary {
		delete(word)
	}
	delete(engine.dictionary)
	delete(engine.regions)
	delete(engine.mutated)
	delete(engine.seen)
}

// fuzz_execute_direct runs the target on one input in this process, with
// the edge counters at zero and the comparisons traced. The verdict text
// is copied out of the temporary memory, which it then frees.
fuzz_execute_direct :: proc(engine: ^Fuzz_Engine, input: []u8) -> Fuzz_Verdict {
	fuzz_counters_clear()
	fuzz_compare_tracing = true
	verdict := engine.target.execute(input)
	fuzz_compare_tracing = false
	engine.executions += 1
	count := copy(engine.verdict_text[:], verdict.text)
	free_all(context.temp_allocator)
	return {oracle = verdict.oracle, text = string(engine.verdict_text[:count])}
}

// fuzz_features_new counts the features of the last execution that no
// kept input gave.
fuzz_features_new :: proc(engine: ^Fuzz_Engine) -> (count: int) {
	edges := len(engine.seen) * 8 / FUZZ_COUNT_CLASSES
	number := 0
	for range_item in fuzz_counter_ranges[:fuzz_counter_range_count] {
		for index in 0 ..< range_item.count {
			edge := number
			number += 1
			if edge >= edges {
				return count
			}
			class := fuzz_count_class(range_item.start[index])
			if class == 0 {
				continue
			}
			feature := edge * FUZZ_COUNT_CLASSES + class - 1
			if engine.seen[feature / 8] & (1 << u8(feature % 8)) == 0 {
				count += 1
			}
		}
	}
	return count
}

// fuzz_features_mark marks the features of the last execution as seen.
fuzz_features_mark :: proc(engine: ^Fuzz_Engine) {
	edges := len(engine.seen) * 8 / FUZZ_COUNT_CLASSES
	number := 0
	for range_item in fuzz_counter_ranges[:fuzz_counter_range_count] {
		for index in 0 ..< range_item.count {
			edge := number
			number += 1
			if edge >= edges {
				return
			}
			class := fuzz_count_class(range_item.start[index])
			if class == 0 {
				continue
			}
			feature := edge * FUZZ_COUNT_CLASSES + class - 1
			if engine.seen[feature / 8] & (1 << u8(feature % 8)) == 0 {
				engine.seen[feature / 8] |= 1 << u8(feature % 8)
				engine.feature_count += 1
			}
		}
	}
}

// fuzz_edges_reached counts the edges that the kept inputs ran: an edge
// with any class seen.
fuzz_edges_reached :: proc(engine: ^Fuzz_Engine) -> (count: int) {
	edges := len(engine.seen) * 8 / FUZZ_COUNT_CLASSES
	for edge in 0 ..< edges {
		for class in 0 ..< FUZZ_COUNT_CLASSES {
			feature := edge * FUZZ_COUNT_CLASSES + class
			if engine.seen[feature / 8] & (1 << u8(feature % 8)) != 0 {
				count += 1
				break
			}
		}
	}
	return count
}

// fuzz_engine_add runs one input that comes from the corpus, the folder of
// the run or the seeds of the target. It keeps the input when it gave a
// new feature, or when `always`: a regression input stays in memory even
// when another input reached each of its edges, so the mutators start from
// it too.
fuzz_engine_add :: proc(engine: ^Fuzz_Engine, input: []u8, always := false) -> Fuzz_Verdict {
	bounded := input[:min(len(input), engine.target.input_limit)]
	verdict := engine.executor(engine, bounded)
	if verdict.oracle != .None {
		return verdict
	}
	new_features := fuzz_features_new(engine)
	if new_features > 0 || always {
		fuzz_engine_keep(engine, bounded, new_features, call_kept = false)
	}
	return FUZZ_PASSED
}

// fuzz_engine_keep adds an input to the kept inputs, and marks its
// features.
fuzz_engine_keep :: proc(engine: ^Fuzz_Engine, input: []u8, new_features: int, call_kept: bool) {
	fuzz_features_mark(engine)
	if len(engine.entries) >= FUZZ_ENTRY_CAPACITY {
		return
	}
	append(&engine.entries, Fuzz_Entry{input = slice.clone(input), features = new_features})
	if call_kept && engine.kept != nil {
		engine.kept(engine, input)
	}
}

// fuzz_engine_start makes sure that the engine has an input to mutate:
// the seeds of the target, or an empty input.
fuzz_engine_start :: proc(engine: ^Fuzz_Engine) -> Fuzz_Verdict {
	if len(engine.entries) > 0 {
		return FUZZ_PASSED
	}
	seeds := make([dynamic][]u8)
	defer {
		for seed in seeds {
			delete(seed)
		}
		delete(seeds)
	}
	if engine.target.seeds != nil {
		engine.target.seeds(&seeds)
	}
	for seed in seeds {
		if verdict := fuzz_engine_add(engine, seed, always = true); verdict.oracle != .None {
			return verdict
		}
	}
	if len(engine.entries) == 0 {
		return fuzz_engine_add(engine, nil, always = true)
	}
	return FUZZ_PASSED
}

// fuzz_engine_step makes one new input from a kept one, runs it, and keeps
// it when it reached a new feature. The input of a verdict that broke an
// oracle stays in engine.mutated.
fuzz_engine_step :: proc(engine: ^Fuzz_Engine) -> Fuzz_Verdict {
	if len(engine.entries) == 0 {
		return FUZZ_PASSED
	}
	// The newer inputs reached the deeper code: half of the draws take one
	// of the last eighth.
	count := len(engine.entries)
	place := fuzz_random_below(&engine.random, count)
	if fuzz_random_one_in(&engine.random, 2) {
		recent := max(count / 8, 1)
		place = count - 1 - fuzz_random_below(&engine.random, recent)
	}
	resize(&engine.mutated, len(engine.entries[place].input))
	copy(engine.mutated[:], engine.entries[place].input)
	// Stacked mutations: 1, 2, 4 or 8 of them.
	stack := 1 << uint(fuzz_random_below(&engine.random, 4))
	for _ in 0 ..< stack {
		fuzz_mutate(engine)
	}
	verdict := engine.executor(engine, engine.mutated[:])
	if verdict.oracle != .None {
		return verdict
	}
	if new_features := fuzz_features_new(engine); new_features > 0 {
		fuzz_engine_keep(engine, engine.mutated[:], new_features, call_kept = true)
	}
	return FUZZ_PASSED
}

// fuzz_engine_run runs `executions` new inputs, and stops at the first
// verdict that broke an oracle.
fuzz_engine_run :: proc(engine: ^Fuzz_Engine, executions: u64) -> Fuzz_Verdict {
	if verdict := fuzz_engine_start(engine); verdict.oracle != .None {
		return verdict
	}
	for _ in 0 ..< executions {
		if verdict := fuzz_engine_step(engine); verdict.oracle != .None {
			return verdict
		}
	}
	return FUZZ_PASSED
}
