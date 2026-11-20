package machine

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "modus:contract/operation_sequence"
import "modustool:build"
import "modustool:foundation"
import "modustool:fuzz"

// The engine guided by the counters, on a fake machine of a counted kernel
// (src/md/infrastructure/kernel_fuzzing.md, "The engine guided by the
// counters"). The fake counts one edge for each operation word of a step,
// so a sequence with a new word, or more of one word, reaches new features.

@(private = "file")
COUNTED_FAKE_EDGES :: 64

@(private = "file")
Counted_Fake :: struct {
	counts:          [COUNTED_FAKE_EDGES]u8,
	// Each execution gives each edge that ran the count 1 or 2 by the
	// parity of the execution: two runs of one sequence never agree.
	unstable:        bool,
	// From this execution, from 1, the counters have one counter less: the
	// counters of another kernel. 0: never.
	short_from:      int,
	// The count of the areas is the count of the last edge: a sequence
	// with no step, as the empty choices give, reaches an edge too.
	counts_areas:    bool,
	first_sequence:  []u8, // The bytes of the first execution.
	executions:      int,
	boots:           int,
	running:         bool,
}

@(private = "file")
counted_fake_start :: proc(data: rawptr) -> bool {
	fake := (^Counted_Fake)(data)
	fake.running = true
	fake.boots += 1
	return true
}

@(private = "file")
counted_fake_execute :: proc(data: rawptr, sequence: ^operation_sequence.Sequence, bytes: []u8) -> Operation_Fault {
	fake := (^Counted_Fake)(data)
	fake.executions += 1
	if fake.executions == 1 {
		fake.first_sequence = slice.clone(bytes, context.allocator)
	}
	fake.counts = {}
	for item in sequence.steps[:sequence.step_count] {
		edge := int(item.operation % COUNTED_FAKE_EDGES)
		if fake.counts[edge] < 255 {
			fake.counts[edge] += 1
		}
	}
	if fake.counts_areas {
		fake.counts[COUNTED_FAKE_EDGES - 1] = u8(min(sequence.area_count, 255))
	}
	if fake.unstable {
		for &count in fake.counts {
			if count != 0 {
				count = fake.executions % 2 == 0 ? 2 : 1
			}
		}
	}
	return {}
}

@(private = "file")
counted_fake_drain :: proc(data: rawptr) -> Operation_Fault {
	_ = data
	return {}
}

@(private = "file")
counted_fake_end :: proc(data: rawptr) {
	(^Counted_Fake)(data).running = false
}

@(private = "file")
counted_fake_counters :: proc(data: rawptr) -> (counts: []u8, problem: string) {
	fake := (^Counted_Fake)(data)
	if fake.short_from != 0 && fake.executions >= fake.short_from {
		return fake.counts[:COUNTED_FAKE_EDGES - 1], ""
	}
	return fake.counts[:], ""
}

@(private = "file")
counted_fake_machine :: proc(fake: ^Counted_Fake) -> Operation_Machine {
	return {data = fake, start = counted_fake_start, execute = counted_fake_execute, drain = counted_fake_drain, end = counted_fake_end, counters = counted_fake_counters}
}

// A generator that the guided loop must not call.
@(private = "file")
generator_not_called :: proc(random: ^fuzz.Fuzz_Random, sequence: ^operation_sequence.Sequence) {
	_, _ = random, sequence
	panic("the guided loop drew a sequence with the generator of the loop with no counters")
}

@(private = "file")
GUIDE_SEED :: 4242

// The guided loop keeps an input only when the part of its two runs that
// agrees gives a feature that the map did not hold: each kept input has its
// features, the map holds each of them, and each input that reached a new
// feature in its first run ran twice.
@(test)
the_guided_loop_keeps_an_input_for_a_stable_new_feature :: proc(t: ^testing.T) {
	if !testing.expect(t, fuzz.fuzz_operation_sequence_start(), "the grammar of the generator does not start") {
		return
	}
	fake := Counted_Fake{}
	defer delete(fake.first_sequence)
	machine := counted_fake_machine(&fake)
	guide := operation_guide_make("")
	defer operation_guide_free(&guide)
	run, ok := operation_fuzzing_loop(&machine, generator_not_called, GUIDE_SEED, {executions = 400, life_sequences = 16, findings_most = OPERATION_FINDINGS_MOST}, nil, &guide)
	defer operation_run_free(&run)
	testing.expect(t, ok)
	testing.expect_value(t, run.executions, 400)
	testing.expect(t, len(guide.entries) > 0, "the guided loop kept no input")
	testing.expect(t, guide.repeats >= len(guide.entries), "an input was kept with no second run")
	features := 0
	for entry in guide.entries {
		testing.expect(t, len(entry.features) > 0, "an input was kept with no feature")
		testing.expect(t, len(entry.choices) <= fuzz.OPERATION_CHOICE_BYTES)
		features += len(entry.features)
	}
	testing.expect(t, guide.edges.edge_count == COUNTED_FAKE_EDGES, "the map has the count of the counters")
	testing.expect(t, guide.edges.feature_count > 0 && guide.edges.feature_count <= features, "the map holds a feature that no kept input gave")
	testing.expect(t, !fake.running, "the last machine was not ended")
}

// Two runs that never agree keep nothing, and mark nothing.
@(test)
the_guided_loop_keeps_no_unstable_input :: proc(t: ^testing.T) {
	if !testing.expect(t, fuzz.fuzz_operation_sequence_start(), "the grammar of the generator does not start") {
		return
	}
	fake := Counted_Fake{unstable = true}
	defer delete(fake.first_sequence)
	machine := counted_fake_machine(&fake)
	guide := operation_guide_make("")
	defer operation_guide_free(&guide)
	run, ok := operation_fuzzing_loop(&machine, generator_not_called, GUIDE_SEED, {executions = 200, life_sequences = 16, findings_most = OPERATION_FINDINGS_MOST}, nil, &guide)
	defer operation_run_free(&run)
	testing.expect(t, ok)
	testing.expect(t, guide.repeats > 0, "no input ran twice")
	testing.expect_value(t, len(guide.entries), 0)
	testing.expect_value(t, guide.edges.feature_count, 0)
}

// One seed gives one guided run: the same kept inputs, byte for byte.
@(test)
a_guided_run_is_the_same_for_one_seed :: proc(t: ^testing.T) {
	if !testing.expect(t, fuzz.fuzz_operation_sequence_start(), "the grammar of the generator does not start") {
		return
	}
	bounds := Operation_Run_Bounds{executions = 300, life_sequences = 8, findings_most = OPERATION_FINDINGS_MOST}
	first_fake, second_fake := Counted_Fake{}, Counted_Fake{}
	defer delete(first_fake.first_sequence)
	defer delete(second_fake.first_sequence)
	first_machine, second_machine := counted_fake_machine(&first_fake), counted_fake_machine(&second_fake)
	first_guide, second_guide := operation_guide_make(""), operation_guide_make("")
	defer operation_guide_free(&first_guide)
	defer operation_guide_free(&second_guide)
	first_run, first_ok := operation_fuzzing_loop(&first_machine, generator_not_called, GUIDE_SEED, bounds, nil, &first_guide)
	defer operation_run_free(&first_run)
	second_run, second_ok := operation_fuzzing_loop(&second_machine, generator_not_called, GUIDE_SEED, bounds, nil, &second_guide)
	defer operation_run_free(&second_run)
	testing.expect(t, first_ok && second_ok)
	testing.expect_value(t, len(first_guide.entries), len(second_guide.entries))
	for entry, place in first_guide.entries {
		if place < len(second_guide.entries) {
			testing.expect(t, slice.equal(entry.choices, second_guide.entries[place].choices), "one seed kept two inputs")
		}
	}
}

// The reach inputs of the corpus run first, before any draw.
@(test)
the_reach_inputs_run_first :: proc(t: ^testing.T) {
	if !testing.expect(t, fuzz.fuzz_operation_sequence_start(), "the grammar of the generator does not start") {
		return
	}
	seed_choices := []u8{3, 1, 4, 1, 5, 9, 2, 6}
	guide := operation_guide_make("")
	defer operation_guide_free(&guide)
	delete(guide.seeds)
	guide.seeds = make([][]u8, 1)
	guide.seeds[0] = slice.clone(seed_choices)
	fake := Counted_Fake{}
	defer delete(fake.first_sequence)
	machine := counted_fake_machine(&fake)
	run, ok := operation_fuzzing_loop(&machine, generator_not_called, GUIDE_SEED, {executions = 1, life_sequences = 16, findings_most = OPERATION_FINDINGS_MOST}, nil, &guide)
	defer operation_run_free(&run)
	testing.expect(t, ok)
	testing.expect_value(t, guide.seeds_run, 1)
	expected := new(operation_sequence.Sequence)
	defer free(expected)
	_ = fuzz.operation_sequence_of_choices(seed_choices, expected)
	bytes, accepted := fuzz.operation_sequence_encode(expected)
	defer delete(bytes)
	testing.expect(t, accepted && slice.equal(bytes, fake.first_sequence), "the first execution is not the reach input")
}

// An empty choice sequence that reaches a new feature runs twice and is
// kept: its empty bytes do not read as no second run.
@(test)
an_empty_input_that_reaches_a_feature_is_kept :: proc(t: ^testing.T) {
	if !testing.expect(t, fuzz.fuzz_operation_sequence_start(), "the grammar of the generator does not start") {
		return
	}
	guide := operation_guide_make("")
	defer operation_guide_free(&guide)
	delete(guide.seeds)
	guide.seeds = make([][]u8, 1)
	guide.seeds[0] = nil
	fake := Counted_Fake{counts_areas = true}
	defer delete(fake.first_sequence)
	machine := counted_fake_machine(&fake)
	run, ok := operation_fuzzing_loop(&machine, generator_not_called, GUIDE_SEED, {executions = 2, life_sequences = 16, findings_most = OPERATION_FINDINGS_MOST}, nil, &guide)
	defer operation_run_free(&run)
	testing.expect(t, ok)
	testing.expect_value(t, guide.repeats, 1)
	testing.expect_value(t, len(guide.entries), 1)
	if len(guide.entries) == 1 {
		testing.expect_value(t, len(guide.entries[0].choices), 0)
		testing.expect(t, len(guide.entries[0].features) > 0, "the empty input was kept with no feature")
	}
	testing.expect(t, !guide.repeat_waiting, "a second run still waits")
}

// With one sequence in each machine life, each second run is in a new
// life: the guide keeps it across the end of the machine.
@(test)
the_second_run_crosses_a_new_machine_life :: proc(t: ^testing.T) {
	if !testing.expect(t, fuzz.fuzz_operation_sequence_start(), "the grammar of the generator does not start") {
		return
	}
	fake := Counted_Fake{}
	defer delete(fake.first_sequence)
	machine := counted_fake_machine(&fake)
	guide := operation_guide_make("")
	defer operation_guide_free(&guide)
	run, ok := operation_fuzzing_loop(&machine, generator_not_called, GUIDE_SEED, {executions = 100, life_sequences = 1, findings_most = OPERATION_FINDINGS_MOST}, nil, &guide)
	defer operation_run_free(&run)
	testing.expect(t, ok)
	testing.expect_value(t, fake.boots, 100)
	testing.expect(t, guide.repeats > 0, "no input ran twice")
	testing.expect(t, len(guide.entries) > 0, "no second run in a new life kept its input")
	testing.expect(t, !fake.running, "the last machine was not ended")
}

// The counters that must be 0: each one from a place on, a counter before
// it does not count, a place past the end reads none, and a place below 0
// reads from the first counter.
@(test)
the_counters_that_must_be_zero_are_checked :: proc(t: ^testing.T) {
	testing.expect_value(t, operation_counters_problem(nil, 0, "here"), "")
	testing.expect_value(t, operation_counters_problem([]u8{0, 0, 0}, 0, "here"), "")
	testing.expect(t, operation_counters_problem([]u8{0, 0, 1}, 0, "here") != "", "the last counter at 1 is taken")
	testing.expect(t, operation_counters_problem([]u8{255, 0, 0}, 0, "here") != "", "the first counter at 255 is taken")
	testing.expect(t, operation_counters_problem([]u8{9, 9, 0}, 2, "here") == "", "a counter before the place counts")
	testing.expect(t, operation_counters_problem([]u8{9, 9, 1}, 2, "here") != "", "the counter at the place is taken")
	testing.expect_value(t, operation_counters_problem([]u8{1}, 1, "here"), "")
	testing.expect_value(t, operation_counters_problem([]u8{1}, max(int), "here"), "")
	testing.expect(t, operation_counters_problem([]u8{1}, -1, "here") != "", "a place below 0 skips the first counter")
}

// The boot line that the tool reads is the line that the counted kernel
// writes, and the line of each test kernel starts with the text that the
// release refuses in the bytes of a kernel module.
@(test)
the_boot_line_of_the_counters_is_the_line_of_the_kernel :: proc(t: ^testing.T) {
	source, error := os.read_entire_file(foundation.SOURCE_FOLDER_KERNEL + "/edge_counters.odin", context.temp_allocator)
	testing.expect(t, error == nil, "the test runs from the root of the repository")
	declaration := strings.concatenate({"TEST_BUILD_LINE_EDGE_COUNTERS :: \"", fuzz.KERNEL_EDGE_COUNTERS_LINE_START, "\""}, context.temp_allocator)
	testing.expectf(t, strings.contains(string(source), declaration), "the kernel does not declare %s", declaration)
	for line in ([]string{fuzz.KERNEL_EDGE_COUNTERS_LINE_START, TEST_KERNEL_WITHOUT_RETURN_CHECK_LINE}) {
		testing.expectf(t, strings.has_prefix(line, build.TEST_KERNEL_TEXT), "the line %q of a test kernel does not start with the text that the release refuses", line)
	}
}

// Counters of another count than the first ones are an error of the tool,
// never a finding, and the run ends.
@(test)
counters_of_another_count_end_the_guided_run :: proc(t: ^testing.T) {
	if !testing.expect(t, fuzz.fuzz_operation_sequence_start(), "the grammar of the generator does not start") {
		return
	}
	fake := Counted_Fake{short_from = 5}
	defer delete(fake.first_sequence)
	machine := counted_fake_machine(&fake)
	guide := operation_guide_make("")
	defer operation_guide_free(&guide)
	run, ok := operation_fuzzing_loop(&machine, generator_not_called, GUIDE_SEED, {executions = 50, life_sequences = 16, findings_most = OPERATION_FINDINGS_MOST}, nil, &guide)
	defer operation_run_free(&run)
	testing.expect(t, !ok, "counters of another count are taken")
	testing.expect_value(t, run.executions, 5)
	testing.expect_value(t, run.faults, 0)
	testing.expect_value(t, len(run.kept), 0)
	testing.expect(t, !fake.running, "the machine was not ended")
}
