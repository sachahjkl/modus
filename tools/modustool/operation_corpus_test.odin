package modustool

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "modus:contract/errors"
import "modus:contract/operation"
import "modus:contract/operation_sequence"

@(private = "file")
TEST_SIGNATURE :: "oracle Unknown_Operation: a word that names no operation"

// A sequence of two steps: a Budget_Read of the budget, then the word 0.
@(private = "file")
test_sequence_bytes :: proc() -> []u8 {
	steps: [2]operation_sequence.Sequence_Step
	steps[0] = {operation = u32(operation.Operation.Budget_Read)}
	steps[0].arguments[0] = {source = .Budget}
	steps[1] = {operation = u32(operation.Operation.None)}
	sequence := new(operation_sequence.Sequence)
	defer free(sequence)
	sequence^ = operation_seed_sequence(steps[:])
	bytes, accepted := operation_sequence_encode(sequence)
	assert(accepted)
	return bytes
}

// The answers of the two steps: Ok, then Bad_Operation with its record and
// one detail.
@(private = "file")
test_expectations :: proc() -> [2]Operation_Step_Expectation {
	expectations: [2]Operation_Step_Expectation
	expectations[0] = {status = .Ok}
	expectations[1] = {status = .Bad_Operation, record_kind = .Unknown_Operation, detail_count = 1}
	expectations[1].details[0] = {kind = .Unknown_Operation}
	return expectations
}

// The bytes of a regression input of one sequence, in the allocator.
@(private = "file")
test_regression_bytes :: proc(sequence: []u8) -> []u8 {
	expectations := test_expectations()
	life := [1][]u8{sequence}
	bytes, written := operation_regression_write({signature = TEST_SIGNATURE, life = life[:], expectations = expectations[:]})
	assert(written)
	return bytes
}

@(private = "file")
with_word :: proc(bytes: []u8, offset: int, value: u64) -> []u8 {
	changed := slice.clone(bytes, context.temp_allocator)
	value := value
	copy(changed[offset:], ([^]u8)(&value)[:size_of(value)])
	return changed
}

@(private = "file")
padded :: proc(count: int) -> int {
	return (count + 7) / 8 * 8
}

@(private = "file")
expect_refused :: proc(t: ^testing.T, bytes: []u8, problem: Operation_Regression_Problem, index: int, loc := #caller_location) -> Operation_Regression_Refusal {
	regression, refusal := operation_regression_read(bytes)
	testing.expectf(t, refusal.problem == problem && refusal.index == index, "the input is refused with %v at %d, and must be refused with %v at %d", refusal.problem, refusal.index, problem, index, loc = loc)
	testing.expectf(t, regression.life == nil && regression.expectations == nil && regression.signature == "", "a refused input gives a part of its regression", loc = loc)
	return refusal
}

// Each damaged regression input is refused with its problem, and gives
// nothing: a short file, the magic, the format, each count at 0, at its
// bound and one past it, the size, a sequence that check refuses, and each
// word of an expectation that names no member. The input whole is read
// back last.
@(test)
a_damaged_regression_input_is_refused :: proc(t: ^testing.T) {
	sequence := test_sequence_bytes()
	defer delete(sequence)
	bytes := test_regression_bytes(sequence)
	defer delete(bytes)
	header :: Operation_Regression_Header
	record :: Operation_Expectation_Record
	_ = expect_refused(t, nil, .Too_Small, -1)
	_ = expect_refused(t, bytes[:size_of(header) - 1], .Too_Small, -1)
	_ = expect_refused(t, with_word(bytes, int(offset_of(header, magic)), OPERATION_REGRESSION_MAGIC + 1), .Magic, -1)
	_ = expect_refused(t, with_word(bytes, int(offset_of(header, format)), OPERATION_REGRESSION_FORMAT + 1), .Format, -1)
	_ = expect_refused(t, with_word(bytes, int(offset_of(header, sequence_count)), 0), .Sequence_Count, -1)
	_ = expect_refused(t, with_word(bytes, int(offset_of(header, sequence_count)), OPERATION_REGRESSION_SEQUENCES_MOST + 1), .Sequence_Count, -1)
	_ = expect_refused(t, with_word(bytes, int(offset_of(header, sequence_count)), max(u64)), .Sequence_Count, -1)
	// Two sequences counted, and the bytes end after the first: the count
	// of the second passes the end.
	expectations_start := len(bytes) - 2 * size_of(record)
	_ = expect_refused(t, with_word(bytes[:expectations_start], int(offset_of(header, sequence_count)), 2), .Size, 1)
	_ = expect_refused(t, with_word(bytes, int(offset_of(header, signature_bytes)), OPERATION_REGRESSION_SIGNATURE_BYTES_MOST + 1), .Signature_Bytes, -1)
	_ = expect_refused(t, with_word(bytes, int(offset_of(header, signature_bytes)), max(u64)), .Signature_Bytes, -1)
	_ = expect_refused(t, with_word(bytes, int(offset_of(header, expectation_count)), operation_sequence.STEPS_MOST + 1), .Expectation_Count, -1)
	// One expectation more than the steps of the last sequence.
	_ = expect_refused(t, with_word(bytes, int(offset_of(header, expectation_count)), 3), .Expectation_Count, -1)
	// One expectation fewer than the bytes hold.
	_ = expect_refused(t, with_word(bytes, int(offset_of(header, expectation_count)), 1), .Size, -1)
	longer := make([]u8, len(bytes) + 1, context.temp_allocator)
	copy(longer, bytes)
	_ = expect_refused(t, longer, .Size, -1)
	_ = expect_refused(t, bytes[:len(bytes) - 1], .Size, -1)
	count_offset := size_of(header) + padded(len(TEST_SIGNATURE))
	_ = expect_refused(t, with_word(bytes, count_offset, operation_sequence.SEQUENCE_BYTES_MOST + 1), .Size, 0)
	_ = expect_refused(t, with_word(bytes, count_offset, max(u64)), .Size, 0)
	damaged_sequence := expect_refused(t, with_word(bytes, count_offset + 8, operation_sequence.MAGIC + 1), .Sequence, 0)
	testing.expect_value(t, damaged_sequence.sequence_refusal.problem, operation_sequence.Problem.Magic)
	second := len(bytes) - size_of(record)
	first := second - size_of(record)
	_ = expect_refused(t, with_word(bytes, second + int(offset_of(record, status)), u64(max(operation.Status)) + 1), .Status, 1)
	_ = expect_refused(t, with_word(bytes, second + int(offset_of(record, status)), max(u64)), .Status, 1)
	_ = expect_refused(t, with_word(bytes, second + int(offset_of(record, record_kind)), u64(max(errors.Kind)) + 1), .Record_Kind, 1)
	_ = expect_refused(t, with_word(bytes, second + int(offset_of(record, record_kind)), transmute(u64)i64(-1)), .Record_Kind, 1)
	_ = expect_refused(t, with_word(bytes, second + int(offset_of(record, detail_count)), operation.ERROR_DETAILS_MOST + 1), .Detail_Count, 1)
	details := second + int(offset_of(record, details))
	_ = expect_refused(t, with_word(bytes, details + int(offset_of(Operation_Detail_Record, kind)), u64(max(errors.Kind)) + 1), .Detail_Kind, 1)
	_ = expect_refused(t, with_word(bytes, details + size_of(Operation_Detail_Record) + int(offset_of(Operation_Detail_Record, argument)), 1), .Unused_Detail, 1)
	_ = expect_refused(t, with_word(bytes, first + int(offset_of(record, record_kind)), u64(errors.Kind.Unknown_Operation)), .Answer_Of_Ok, 0)
	_ = expect_refused(t, with_word(bytes, first + int(offset_of(record, detail_count)), 1), .Answer_Of_Ok, 0)
	// The last case: the input whole.
	regression, refusal := operation_regression_read(bytes)
	defer delete(regression.life)
	defer delete(regression.expectations)
	testing.expect_value(t, refusal.problem, Operation_Regression_Problem.None)
	testing.expect_value(t, regression.signature, TEST_SIGNATURE)
	testing.expect_value(t, len(regression.life), 1)
	if len(regression.life) == 1 {
		testing.expect(t, slice.equal(regression.life[0], sequence), "the sequence reads back to other bytes")
	}
	expected := test_expectations()
	testing.expect(t, slice.equal(regression.expectations, expected[:]), "the expectations read back to others")
}

// The writer refuses a life of no sequence or past its bound, a signature
// past its bound, more expectations than a sequence has steps, and a
// sequence larger than its place.
@(test)
the_writer_of_a_regression_input_refuses_its_bounds :: proc(t: ^testing.T) {
	sequence := test_sequence_bytes()
	defer delete(sequence)
	one := [1][]u8{sequence}
	many: [OPERATION_REGRESSION_SEQUENCES_MOST + 1][]u8
	for &item in many {
		item = sequence
	}
	long_signature := strings.repeat("s", OPERATION_REGRESSION_SIGNATURE_BYTES_MOST + 1, context.temp_allocator)
	too_many := make([]Operation_Step_Expectation, operation_sequence.STEPS_MOST + 1, context.temp_allocator)
	large := [1][]u8{make([]u8, operation_sequence.SEQUENCE_BYTES_MOST + 1, context.temp_allocator)}
	_, empty_written := operation_regression_write({signature = TEST_SIGNATURE})
	testing.expect(t, !empty_written, "a life of no sequence is written")
	_, many_written := operation_regression_write({signature = TEST_SIGNATURE, life = many[:]})
	testing.expect(t, !many_written, "a life past its bound is written")
	_, signature_written := operation_regression_write({signature = long_signature, life = one[:]})
	testing.expect(t, !signature_written, "a signature past its bound is written")
	_, expectations_written := operation_regression_write({signature = TEST_SIGNATURE, life = one[:], expectations = too_many})
	testing.expect(t, !expectations_written, "expectations past their bound are written")
	_, large_written := operation_regression_write({signature = TEST_SIGNATURE, life = large[:]})
	testing.expect(t, !large_written, "a sequence larger than its place is written")
	bytes, written := operation_regression_write({signature = TEST_SIGNATURE, life = many[:OPERATION_REGRESSION_SEQUENCES_MOST]})
	defer delete(bytes)
	testing.expect(t, written, "a life at its bound is refused")
	testing.expect(t, len(bytes) <= OPERATION_REGRESSION_BYTES_MOST)
}

// Results of the two steps of the test sequence, as the runner writes the
// answers that test_expectations names.
@(private = "file")
test_results :: proc() -> operation_sequence.Runner_Results {
	results: operation_sequence.Runner_Results
	results.steps_run = 2
	results.results[0].status = u64(operation.Status.Ok)
	results.results[0].values[0] = 12345 // A value of Ok, which no expectation reads.
	record := errors.Error_Record{kind = i64(errors.Kind.Unknown_Operation), operation = 0}
	results.results[1].status = u64(operation.Status.Bad_Operation)
	results.results[1].values = transmute([operation_sequence.ARGUMENTS]u64)record
	results.results[1].kind = u64(operation.COMMAND_NAMES_ERROR_DETAILS)
	results.results[1].details_count = 1
	results.results[1].details[0] = record
	return results
}

// The check of the answers refuses another count of steps, another status,
// another record, another count of details and another detail; it takes
// the answers last, whatever the values of an Ok.
@(test)
the_answers_of_a_regression_input_are_checked :: proc(t: ^testing.T) {
	expected := test_expectations()
	results := test_results()
	results.steps_run = 1
	testing.expect(t, operation_step_expectations_problem(expected[:], &results) != "", "another count of steps is taken")
	results.steps_run = max(u64)
	testing.expect(t, operation_step_expectations_problem(expected[:], &results) != "", "the largest count of steps is taken")
	results = test_results()
	results.results[1].status = u64(operation.Status.Bad_Handle)
	testing.expect(t, operation_step_expectations_problem(expected[:], &results) != "", "another status is taken")
	results = test_results()
	results.results[0].status = u64(operation.Status.Bad_Operation)
	testing.expect(t, operation_step_expectations_problem(expected[:], &results) != "", "a refusal of an Ok step is taken")
	results = test_results()
	results.results[1].values[0] = u64(errors.Kind.Refused)
	testing.expect(t, operation_step_expectations_problem(expected[:], &results) != "", "a record of another kind is taken")
	results = test_results()
	wrong_argument := transmute(errors.Error_Record)results.results[1].values
	wrong_argument.argument = 1
	results.results[1].values = transmute([operation_sequence.ARGUMENTS]u64)wrong_argument
	testing.expect(t, operation_step_expectations_problem(expected[:], &results) != "", "a record of another argument is taken")
	results = test_results()
	results.results[1].details_count = 2
	testing.expect(t, operation_step_expectations_problem(expected[:], &results) != "", "another count of details is taken")
	results.results[1].details_count = max(u64)
	testing.expect(t, operation_step_expectations_problem(expected[:], &results) != "", "the largest count of details is taken")
	results = test_results()
	results.results[1].details[0].argument = 3
	testing.expect(t, operation_step_expectations_problem(expected[:], &results) != "", "a detail of another argument is taken")
	results = test_results()
	testing.expect_value(t, operation_step_expectations_problem(expected[:], &results), "")
}

// The answers that the command keeps come through the borders of their
// words: a count of steps past the sequence, a status, a record kind, a
// count of details and a detail kind that names nothing are refused. The
// answers of good results are the expectations, and they pass their check.
@(test)
the_answers_kept_from_a_machine_are_read_through_their_borders :: proc(t: ^testing.T) {
	sequence := new(operation_sequence.Sequence)
	defer free(sequence)
	bytes := test_sequence_bytes()
	defer delete(bytes)
	_ = operation_sequence.check(bytes, sequence)
	results := test_results()
	results.steps_run = 3
	_, past := operation_step_expectations_of(sequence, &results)
	testing.expect(t, past != "", "more steps than the sequence are taken")
	results = test_results()
	results.results[1].status = u64(max(operation.Status)) + 1
	_, status := operation_step_expectations_of(sequence, &results)
	testing.expect(t, status != "", "a status that names nothing is taken")
	results = test_results()
	results.results[1].values[0] = u64(max(errors.Kind)) + 1
	_, kind := operation_step_expectations_of(sequence, &results)
	testing.expect(t, kind != "", "a record kind that names nothing is taken")
	results = test_results()
	results.results[1].details_count = operation.ERROR_DETAILS_MOST + 1
	_, count := operation_step_expectations_of(sequence, &results)
	testing.expect(t, count != "", "a count of details past its most is taken")
	results = test_results()
	results.results[1].details[0].kind = -1
	_, detail := operation_step_expectations_of(sequence, &results)
	testing.expect(t, detail != "", "a detail kind that names nothing is taken")
	results = test_results()
	kept, problem := operation_step_expectations_of(sequence, &results)
	defer delete(kept)
	testing.expect_value(t, problem, "")
	expected := test_expectations()
	testing.expect(t, slice.equal(kept, expected[:]), "the kept answers are not the answers of the results")
	testing.expect_value(t, operation_step_expectations_problem(kept, &results), "")
}

// A folder of regression inputs: a damaged file and an entry that is no
// file are problems, never skipped; a good file is read; a folder that does
// not exist holds no input.
@(test)
each_file_of_a_folder_of_regression_inputs_is_read_or_refused :: proc(t: ^testing.T) {
	root :: BUILD_FOLDER + "/operation_regression_inputs_test"
	defer {
		_ = os.remove_all(root)
	}
	testing.expect(t, reset_folder(root))
	missing, missing_problems := operation_regression_inputs_read(root + "/none", context.temp_allocator)
	testing.expect(t, len(missing) == 0 && len(missing_problems) == 0)
	sequence := test_sequence_bytes()
	defer delete(sequence)
	bytes := test_regression_bytes(sequence)
	defer delete(bytes)
	_, good := fuzz_input_write(root, bytes)
	_, bad := fuzz_input_write(root, bytes[:len(bytes) - 1])
	testing.expect(t, good && bad)
	testing.expect(t, make_folder(root + "/inner"))
	inputs, problems := operation_regression_inputs_read(root, context.temp_allocator)
	testing.expect_value(t, len(inputs), 1)
	testing.expect_value(t, len(problems), 2)
	if len(inputs) == 1 {
		testing.expect_value(t, inputs[0].name, fuzz_input_name(bytes))
		testing.expect_value(t, inputs[0].regression.signature, TEST_SIGNATURE)
	}
}

// No regression input of the repository stays unrun: the test part reads
// the folder with the reader of this test, which refuses no file of it,
// and each entry of the folder is one input that it runs.
@(test)
each_regression_input_of_the_corpus_is_run :: proc(t: ^testing.T) {
	entries, error := os.read_all_directory_by_path(OPERATION_REGRESSION_FOLDER, context.temp_allocator)
	inputs, problems := operation_regression_inputs_read(OPERATION_REGRESSION_FOLDER, context.temp_allocator)
	for problem in problems {
		testing.expectf(t, false, "the test part does not run an input: %s", problem)
	}
	if error != nil {
		testing.expect_value(t, len(inputs), 0)
		return
	}
	testing.expect_value(t, len(inputs), len(entries))
	for input in inputs {
		testing.expectf(t, input.name == fuzz_input_name(input.bytes), "%s is not named by the hash of its bytes", input.name)
		testing.expectf(t, len(input.regression.expectations) > 0, "%s names no answer of its last sequence", input.name)
	}
	testing.expect_value(t, len(fuzz_corpus_problems(FUZZ_CORPUS_FOLDER, fuzz_targets())), 0)
}

// The corpus of the operations in a corpus root: its regression inputs are
// read by their reader, a damaged one is a problem, and a part that is not
// regression or reach is one too.
@(test)
the_corpus_of_the_operations_has_its_form :: proc(t: ^testing.T) {
	root :: BUILD_FOLDER + "/operation_corpus_form_test"
	defer {
		_ = os.remove_all(root)
	}
	testing.expect(t, reset_folder(root))
	sequence := test_sequence_bytes()
	defer delete(sequence)
	bytes := test_regression_bytes(sequence)
	defer delete(bytes)
	regression_folder := strings.concatenate({root, "/", OPERATION_CORPUS_NAME, "/", FUZZ_REGRESSION_PART}, context.temp_allocator)
	_, written := fuzz_input_write(regression_folder, bytes)
	testing.expect(t, written)
	testing.expect_value(t, len(fuzz_corpus_problems(root, fuzz_targets())), 0)
	_, damaged := fuzz_input_write(regression_folder, with_word(bytes, int(offset_of(Operation_Regression_Header, magic)), 0))
	testing.expect(t, damaged)
	testing.expect_value(t, len(fuzz_corpus_problems(root, fuzz_targets())), 1)
	testing.expect(t, make_folder(strings.concatenate({root, "/", OPERATION_CORPUS_NAME, "/other"}, context.temp_allocator)))
	testing.expect_value(t, len(fuzz_corpus_problems(root, fuzz_targets())), 2)
}

// The minimized life of a finding folder: no finding.txt, an empty
// signature, no minimized life, a file that is no sequence and no sequence
// are refused; the sequences in the order of their names and the first line
// of finding.txt are read last.
@(test)
the_life_of_a_finding_is_read_or_refused :: proc(t: ^testing.T) {
	root :: BUILD_FOLDER + "/operation_finding_life_test"
	defer {
		_ = os.remove_all(root)
	}
	testing.expect(t, reset_folder(root))
	_, _, no_text := operation_finding_life_read(root)
	testing.expect(t, no_text != "", "a folder with no finding.txt is taken")
	testing.expect(t, os.write_entire_file(root + "/finding.txt", transmute([]u8)string("\nthe text\n")) == nil)
	_, _, empty := operation_finding_life_read(root)
	testing.expect(t, empty != "", "an empty signature is taken")
	testing.expect(t, os.write_entire_file(root + "/finding.txt", transmute([]u8)fmt.tprintf("%s\nthe text\n", TEST_SIGNATURE)) == nil)
	_, _, no_life := operation_finding_life_read(root)
	testing.expect(t, no_life != "", "a folder with no minimized life is taken")
	testing.expect(t, make_folder(root + "/minimized"))
	_, _, no_sequence := operation_finding_life_read(root)
	testing.expect(t, no_sequence != "", "a minimized life of no sequence is taken")
	sequence := test_sequence_bytes()
	defer delete(sequence)
	testing.expect(t, os.write_entire_file(root + "/minimized/sequence_0001", sequence[:len(sequence) - 1]) == nil)
	_, _, refused := operation_finding_life_read(root)
	testing.expect(t, refused != "", "a file that is no sequence is taken")
	testing.expect(t, os.write_entire_file(root + "/minimized/sequence_0001", sequence) == nil)
	testing.expect(t, os.write_entire_file(root + "/minimized/sequence_0000", sequence) == nil)
	life, signature, problem := operation_finding_life_read(root)
	defer operation_life_free(life)
	defer delete(signature)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, signature, TEST_SIGNATURE)
	testing.expect_value(t, len(life), 2)
}
