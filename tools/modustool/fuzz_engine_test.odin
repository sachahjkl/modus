package modustool

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

// The tests of the engine of the fuzzing on the host: a target with a
// planted fault that the engine must find in a fixed count of executions
// with a fixed seed, the minimizer, and the parts of the commands that
// read text. No test measures a time.

// The magic of the planted fault, and the executions in which the engine
// must find it: far more than it needs, so that the test checks a
// behaviour and not a speed.
FUZZ_PLANTED_MAGIC :: u64(0x4D4F_4455)
FUZZ_PLANTED_EXECUTIONS :: 200_000
FUZZ_PLANTED_SEED :: 0x5EED

// The edge counters of the planted target: the target writes them itself,
// as the pass of the instrumented build writes the counters of a package.
// The test runner has no instrumented package, so these are the only ones.
fuzz_planted_counters: [4]u8

// fuzz_planted_execute breaks an oracle for an input that starts with the
// magic, then 7, then a byte over 0xF0. Each stage gives an edge, and each
// comparison is traced, as the instrumented code would trace it.
fuzz_planted_execute :: proc(input: []u8) -> Fuzz_Verdict {
	if len(input) < 4 {
		return FUZZ_PASSED
	}
	value := fuzz_word_read(input, 0, 4, false)
	fuzz_compare_record(value, FUZZ_PLANTED_MAGIC, 4)
	if value != FUZZ_PLANTED_MAGIC {
		return FUZZ_PASSED
	}
	fuzz_planted_counters[0] += 1
	if len(input) < 6 {
		return FUZZ_PASSED
	}
	fuzz_compare_record(u64(input[4]), 7, 1)
	if input[4] != 7 {
		return FUZZ_PASSED
	}
	fuzz_planted_counters[1] += 1
	if input[5] <= 0xF0 {
		return FUZZ_PASSED
	}
	return fuzz_broken(.Contract, "the planted fault: %x", input[5])
}

fuzz_planted_still_found :: proc(data: rawptr, candidate: []u8) -> bool {
	return fuzz_planted_execute(candidate).oracle == .Contract
}

// One test: the counters and the comparisons are globals of the process,
// and the runner runs tests on several threads.
@(test)
the_engine_finds_and_minimizes_a_planted_fault :: proc(t: ^testing.T) {
	start := ([^]u8)(&fuzz_planted_counters[0])
	fuzz_counters_init(start, start[len(fuzz_planted_counters):])
	target := Fuzz_Target {
		name        = "planted",
		kind        = .Raw,
		input_limit = 64,
		execute     = fuzz_planted_execute,
	}
	engine: Fuzz_Engine
	fuzz_engine_init(&engine, &target, FUZZ_PLANTED_SEED)
	defer fuzz_engine_destroy(&engine)
	verdict := fuzz_engine_run(&engine, FUZZ_PLANTED_EXECUTIONS)
	if !testing.expectf(t, verdict.oracle == .Contract, "the engine found no planted fault in %d executions: %v, %d inputs kept", FUZZ_PLANTED_EXECUTIONS, verdict.oracle, len(engine.entries)) {
		return
	}
	testing.expect(t, strings.has_prefix(verdict.text, "the planted fault"))
	// The engine kept at least one input: the replacement by a compared
	// value can pass several stages in one mutation, so the count of the
	// kept inputs is not one for each stage.
	testing.expect(t, len(engine.entries) >= 1)
	finding := slice.clone(engine.mutated[:])
	defer delete(finding)
	smallest, tried := fuzz_minimize(finding, fuzz_planted_still_found, nil, FUZZ_MINIMIZE_CANDIDATE_LIMIT)
	defer delete(smallest)
	expected := [6]u8{0x55, 0x44, 0x4F, 0x4D, 7, 0xF1}
	testing.expectf(t, slice.equal(smallest, expected[:]), "the minimizer gave %v in %d candidates, not %v", smallest, tried, expected)
}

@(test)
choices_read_zeros_after_the_end :: proc(t: ^testing.T) {
	input := [3]u8{0xFF, 5, 0x10}
	choices := fuzz_choices_of(input[:])
	testing.expect_value(t, fuzz_choice_byte(&choices), 0xFF)
	testing.expect_value(t, fuzz_choice_below(&choices, 3), 5 % 3)
	testing.expect_value(t, fuzz_choice_word(&choices, 2), 0x10)
	testing.expect(t, fuzz_choices_ran_out(&choices))
	testing.expect_value(t, fuzz_choice_below(&choices, 1000), 0)
	testing.expect(t, !fuzz_choice_rare(&choices, 4))
	// The simplest decision of a count of one reads no byte.
	empty := fuzz_choices_of(nil)
	testing.expect_value(t, fuzz_choice_below(&empty, 1), 0)
	testing.expect_value(t, empty.place, 0)
}

@(test)
the_generator_of_the_engine_is_fixed_by_its_seed :: proc(t: ^testing.T) {
	first := Fuzz_Random{state = FUZZ_PLANTED_SEED}
	second := Fuzz_Random{state = FUZZ_PLANTED_SEED}
	for _ in 0 ..< 100 {
		testing.expect_value(t, fuzz_random_next(&first), fuzz_random_next(&second))
	}
}

@(test)
the_minimizer_removes_what_the_finding_does_not_need :: proc(t: ^testing.T) {
	still_found :: proc(data: rawptr, candidate: []u8) -> bool {
		return slice.contains(candidate, 0x42)
	}
	input := [?]u8{9, 9, 9, 0x42, 9, 9, 9, 9}
	smallest, _ := fuzz_minimize(input[:], still_found, nil, FUZZ_MINIMIZE_CANDIDATE_LIMIT)
	defer delete(smallest)
	testing.expectf(t, slice.equal(smallest, []u8{0x42}), "the minimizer gave %v", smallest)
}

@(test)
the_words_of_a_number_hold_its_forms :: proc(t: ^testing.T) {
	target := Fuzz_Target{name = "words", input_limit = 16, execute = fuzz_planted_execute}
	engine: Fuzz_Engine
	fuzz_engine_init(&engine, &target, 1)
	defer fuzz_engine_destroy(&engine)
	fuzz_dictionary_add_integer(&engine, 0x0102)
	little := [2]u8{0x02, 0x01}
	big := [2]u8{0x01, 0x02}
	wide := [4]u8{0x02, 0x01, 0, 0}
	found_little, found_big, found_wide := false, false, false
	for word in engine.dictionary {
		found_little ||= slice.equal(word, little[:])
		found_big ||= slice.equal(word, big[:])
		found_wide ||= slice.equal(word, wide[:])
	}
	testing.expect(t, found_little && found_big && found_wide)
}

@(test)
the_printed_commands_of_the_compiler_are_split :: proc(t: ^testing.T) {
	output := "nasm \"/a b/fill.asm\" -f \"elf64\" -o \"/tmp/x/fill.asm-1.o\"\nclang -Wno-unused-command-line-argument \"/tmp/x/modustool_instrumented-module-2.o\" \"/tmp/x/fill.asm-1.o\"  -o \"build/x\"  -Wl,-z,now -L/ -lc -pie\n"
	commands, has_link := fuzz_printed_commands(output)
	testing.expect(t, has_link)
	testing.expect_value(t, len(commands.assembly), 1)
	testing.expect_value(t, commands.assembly[0][1], "/a b/fill.asm")
	testing.expect_value(t, commands.link[0], "clang")
	testing.expect_value(t, commands.link[len(commands.link) - 1], "-pie")
	testing.expect(t, fuzz_package_is_instrumented(FUZZ_INSTRUMENTED_NAME + "-module.ll", {"contract/module"}))
	testing.expect(t, fuzz_package_is_instrumented(FUZZ_INSTRUMENTED_NAME + "-quic-tls_handshake.ll", {"support/quic"}))
	testing.expect(t, fuzz_package_is_instrumented(FUZZ_INSTRUMENTED_NAME + "-quic$1.ll", {"support/quic"}))
	testing.expect(t, !fuzz_package_is_instrumented(FUZZ_INSTRUMENTED_NAME + "-modustool.ll", {"contract/module"}))
	testing.expect(t, !fuzz_package_is_instrumented(FUZZ_INSTRUMENTED_NAME + "-quick.ll", {"support/quic"}))
}

@(test)
the_place_of_a_bounds_check_has_no_folder_and_no_value :: proc(t: ^testing.T) {
	text := "/build/src/library/contract/module/load.odin(201:17) Index 9 is out of range 0..<3\n"
	testing.expect_value(t, fuzz_fault_place(text), "load.odin(201:17)")
	testing.expect_value(t, fuzz_fault_place("no place here"), "")
}

@(test)
each_fuzz_target_has_a_name_a_limit_and_its_packages :: proc(t: ^testing.T) {
	targets := fuzz_targets()
	for target, index in targets {
		testing.expectf(t, target.input_limit > 0 && target.input_limit <= FUZZ_INPUT_CAPACITY, "%s: the limit %d", target.name, target.input_limit)
		testing.expectf(t, target.execute != nil && len(target.packages) > 0, "%s has no procedure or no package", target.name)
		for package_folder in target.packages {
			testing.expectf(t, os.is_dir(strings.concatenate({SOURCE_FOLDER_LIBRARY, "/", package_folder}, context.temp_allocator)), "%s: no package %s", target.name, package_folder)
		}
		for other in targets[index + 1:] {
			testing.expectf(t, other.name != target.name, "two fuzz targets have the name %s", target.name)
		}
	}
}

@(test)
a_corpus_out_of_its_form_is_refused :: proc(t: ^testing.T) {
	root := BUILD_FOLDER + "/fuzz_corpus_form_test"
	defer {
		_ = os.remove_all(root)
	}
	testing.expect(t, reset_folder(root))
	good := []u8{1, 2, 3}
	_, written := fuzz_input_write(strings.concatenate({root, "/module_file/", FUZZ_REGRESSION_PART}, context.temp_allocator), good)
	testing.expect(t, written)
	testing.expect_value(t, len(fuzz_corpus_problems(root, fuzz_targets())), 0)
	// A file whose name is not its hash, a part that is not one of the
	// two, and a folder that names no target.
	reach := strings.concatenate({root, "/module_file/", FUZZ_REACH_PART}, context.temp_allocator)
	testing.expect(t, make_folder(reach))
	testing.expect(t, os.write_entire_file(strings.concatenate({reach, "/0000"}, context.temp_allocator), good) == nil)
	testing.expect(t, make_folder(strings.concatenate({root, "/module_file/other"}, context.temp_allocator)))
	testing.expect(t, make_folder(strings.concatenate({root, "/no_such_target"}, context.temp_allocator)))
	testing.expect_value(t, len(fuzz_corpus_problems(root, fuzz_targets())), 3)
}
