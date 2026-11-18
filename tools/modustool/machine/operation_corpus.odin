package machine

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/operation"
import "modus:contract/operation_sequence"
import "modustool:foundation"
import "modustool:fuzz"

// The corpus of the kernel operations (src/md/infrastructure/kernel_fuzzing.md,
// "The corpus of the operations"): the folder `operations` of the corpus of
// the fuzz targets, with its regression inputs and its reach inputs, one
// file for each input, named by the BLAKE3 hash of its bytes as the inputs
// of the other targets are.
//
// A regression input is a minimized machine life and the answer of each
// step of its last sequence on the kernel that ships, after the fix of its
// fault. The test part `operation_sequences` runs each one and checks the
// answers, so it checks the refusal itself, not only the oracles. Only the
// tool reads the file, so its format is a part of the tool, not a contract.

// The folders of the corpus of the kernel operations and of its two parts,
// which the fuzzing on machines writes.
OPERATION_CORPUS_FOLDER :: fuzz.FUZZ_CORPUS_FOLDER + "/" + fuzz.OPERATION_CORPUS_NAME
OPERATION_REGRESSION_FOLDER :: OPERATION_CORPUS_FOLDER + "/" + fuzz.FUZZ_REGRESSION_PART
OPERATION_REACH_FOLDER :: OPERATION_CORPUS_FOLDER + "/" + fuzz.FUZZ_REACH_PART

#assert(fuzz.OPERATION_REGRESSION_BYTES_MOST <= fuzz.FUZZ_CORPUS_TARGET_BYTE_LIMIT)

// operation_regression_write writes a regression input. It refuses only a
// count past its bound, so a test writes an input that the reader must
// refuse by changing its bytes.
operation_regression_write :: proc(regression: fuzz.Operation_Regression, allocator := context.allocator) -> (bytes: []u8, ok: bool) {
	if len(regression.life) < 1 || len(regression.life) > fuzz.OPERATION_REGRESSION_SEQUENCES_MOST || len(regression.signature) > fuzz.OPERATION_REGRESSION_SIGNATURE_BYTES_MOST || len(regression.expectations) > operation_sequence.STEPS_MOST {
		return nil, false
	}
	size := size_of(fuzz.Operation_Regression_Header) + fuzz.operation_padded(len(regression.signature))
	for sequence in regression.life {
		if len(sequence) > operation_sequence.SEQUENCE_BYTES_MOST {
			return nil, false
		}
		size += 8 + fuzz.operation_padded(len(sequence))
	}
	size += len(regression.expectations) * size_of(fuzz.Operation_Expectation_Record)
	bytes = make([]u8, size, allocator)
	header := fuzz.Operation_Regression_Header {
		magic             = fuzz.OPERATION_REGRESSION_MAGIC,
		format            = fuzz.OPERATION_REGRESSION_FORMAT,
		sequence_count    = u64(len(regression.life)),
		signature_bytes   = u64(len(regression.signature)),
		expectation_count = u64(len(regression.expectations)),
	}
	copy(bytes, ([^]u8)(&header)[:size_of(header)])
	offset := size_of(header)
	copy(bytes[offset:], regression.signature)
	offset += fuzz.operation_padded(len(regression.signature))
	for sequence in regression.life {
		count := u64(len(sequence))
		copy(bytes[offset:], ([^]u8)(&count)[:size_of(count)])
		offset += 8
		copy(bytes[offset:], sequence)
		offset += fuzz.operation_padded(len(sequence))
	}
	for &expected in regression.expectations {
		record := fuzz.Operation_Expectation_Record {
			status          = u64(expected.status),
			record_kind     = i64(expected.record_kind),
			record_argument = expected.record_argument,
			detail_count    = u64(expected.detail_count),
		}
		for detail, place in expected.details[:min(max(expected.detail_count, 0), operation.ERROR_DETAILS_MOST)] {
			record.details[place] = {kind = i64(detail.kind), argument = detail.argument}
		}
		copy(bytes[offset:], ([^]u8)(&record)[:size_of(record)])
		offset += size_of(record)
	}
	return bytes, true
}

// operation_step_expectations_of gives the answer of each step of a
// sequence that ran, from the results that the machine wrote: the words
// come from the memory of the machine, so each one is read through its
// border. The oracles have held on these results before.
operation_step_expectations_of :: proc(sequence: ^operation_sequence.Sequence, results: ^operation_sequence.Runner_Results, allocator := context.allocator) -> (expectations: []fuzz.Operation_Step_Expectation, problem: string) {
	if results.steps_run > u64(sequence.step_count) {
		return nil, fmt.tprintf("the runner says that %d steps ran, of %d", results.steps_run, sequence.step_count)
	}
	expectations = make([]fuzz.Operation_Step_Expectation, int(results.steps_run), allocator)
	for &expected, step in expectations {
		result := &results.results[step]
		status, known := enum_word.member_of_word(operation.Status, result.status)
		if !known {
			delete(expectations, allocator)
			return nil, fmt.tprintf("the step %d gave the status word %d, which names no status", step, result.status)
		}
		expected.status = status
		if status == .Ok {
			continue
		}
		record := transmute(errors.Error_Record)result.values
		kind, kind_known := enum_word.member_of_word(errors.Kind, u64(record.kind))
		if !kind_known || result.details_count > operation.ERROR_DETAILS_MOST {
			delete(expectations, allocator)
			return nil, fmt.tprintf("the step %d has the record kind %d and %d details: no answer to keep", step, record.kind, result.details_count)
		}
		expected.record_kind, expected.record_argument = kind, record.argument
		expected.detail_count = int(result.details_count)
		for detail, place in result.details[:expected.detail_count] {
			detail_kind, detail_known := enum_word.member_of_word(errors.Kind, u64(detail.kind))
			if !detail_known {
				delete(expectations, allocator)
				return nil, fmt.tprintf("the detail %d of the step %d has the kind %d, which names no kind", place, step, detail.kind)
			}
			expected.details[place] = {kind = detail_kind, argument = detail.argument}
		}
	}
	return expectations, ""
}

// operation_step_expectations_problem compares the answers of the last
// sequence of a regression input with what it must get, and gives the
// first difference, or "". The words come from the memory of the machine:
// a count is checked before its use.
operation_step_expectations_problem :: proc(expectations: []fuzz.Operation_Step_Expectation, results: ^operation_sequence.Runner_Results) -> string {
	if results.steps_run != u64(len(expectations)) {
		return fmt.tprintf("%d steps ran, and %d must run", results.steps_run, len(expectations))
	}
	for &expected, step in expectations {
		result := &results.results[step]
		if result.status != u64(expected.status) {
			return fmt.tprintf("the step %d gave the status word %d, and must give %v", step, result.status, expected.status)
		}
		if expected.status == .Ok {
			continue
		}
		record := transmute(errors.Error_Record)result.values
		if record.kind != i64(expected.record_kind) || record.argument != expected.record_argument {
			return fmt.tprintf("the step %d has the error record of the kind %d and the argument %d, and must have %v of the argument %d", step, record.kind, record.argument, expected.record_kind, expected.record_argument)
		}
		if result.details_count != u64(expected.detail_count) {
			return fmt.tprintf("the step %d has %d error details, and must have %d", step, result.details_count, expected.detail_count)
		}
		for detail, place in expected.details[:expected.detail_count] {
			got := result.details[place]
			if got.kind != i64(detail.kind) || got.argument != detail.argument {
				return fmt.tprintf("the detail %d of the step %d is of the kind %d and the argument %d, and must be %v of the argument %d", place, step, got.kind, got.argument, detail.kind, detail.argument)
			}
		}
	}
	return ""
}

// operation_finding_life_read reads the minimized life of a finding
// folder, `minimized/sequence_<n>` in the order of the names, and the
// signature, the first line of `finding.txt`.
operation_finding_life_read :: proc(folder: string, allocator := context.allocator) -> (life: [][]u8, signature: string, problem: string) {
	text, text_error := os.read_entire_file(strings.concatenate({folder, "/finding.txt"}, context.temp_allocator), context.temp_allocator)
	if text_error != nil {
		return nil, "", fmt.tprintf("%s has no finding.txt: %v", folder, text_error)
	}
	signature = string(text)
	if end := strings.index_byte(signature, '\n'); end >= 0 {
		signature = signature[:end]
	}
	if signature == "" {
		return nil, "", fmt.tprintf("%s/finding.txt names no signature", folder)
	}
	minimized := strings.concatenate({folder, "/minimized"}, context.temp_allocator)
	entries, error := os.read_all_directory_by_path(minimized, context.temp_allocator)
	if error != nil {
		return nil, "", fmt.tprintf("%s has no minimized life: %v", folder, error)
	}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	list := make([dynamic][]u8, allocator)
	sequence := new(operation_sequence.Sequence)
	defer free(sequence)
	for entry in entries {
		if entry.type != .Regular || !strings.has_prefix(entry.name, "sequence_") {
			continue
		}
		bytes, read_error := os.read_entire_file(entry.fullpath, allocator)
		if read_error != nil {
			operation_life_free(list[:])
			return nil, "", fmt.tprintf("cannot read %s: %v", entry.fullpath, read_error)
		}
		if refusal := operation_sequence.check(bytes, sequence); refusal.problem != .None {
			delete(bytes, allocator)
			operation_life_free(list[:])
			return nil, "", fmt.tprintf("%s is no operation sequence: %v", entry.fullpath, refusal)
		}
		append(&list, bytes)
	}
	if len(list) < 1 || len(list) > fuzz.OPERATION_REGRESSION_SEQUENCES_MOST {
		operation_life_free(list[:])
		return nil, "", fmt.tprintf("%s holds %d sequences, and a regression input holds 1 to %d", minimized, len(list), fuzz.OPERATION_REGRESSION_SEQUENCES_MOST)
	}
	return list[:], strings.clone(signature, allocator), ""
}

// operation_regression_add is `fuzz regression operations <finding>`:
// the minimized life of a finding, run on a new machine of the kernel that
// ships, becomes a regression input with the answer of each step of its
// last sequence. It refuses a life that still breaks an oracle: the fault
// is fixed first. The developer reads the answers that it prints before
// the commit: they are the answers that the fix gives.
operation_regression_add :: proc(folder: string) -> int {
	life, signature, problem := operation_finding_life_read(folder)
	if problem != "" {
		fmt.eprintfln("modustool: fuzz regression operations: %s", problem)
		return foundation.EXIT_USAGE
	}
	defer operation_life_free(life)
	defer delete(signature)
	if len(signature) > fuzz.OPERATION_REGRESSION_SIGNATURE_BYTES_MOST {
		fmt.eprintfln("modustool: fuzz regression operations: the signature has %d bytes, past %d", len(signature), fuzz.OPERATION_REGRESSION_SIGNATURE_BYTES_MOST)
		return foundation.EXIT_USAGE
	}
	state := operation_qemu_open()
	if state == nil {
		return foundation.EXIT_FAILURE
	}
	defer operation_qemu_close(state)
	machine := operation_qemu_machine(state)
	outcome := operation_life_run(&machine, life)
	switch {
	case !outcome.booted:
		fmt.eprintfln("modustool: fuzz regression operations: %d machines in a row did not reach the line \"%s\": an error of the build", outcome.boots, OPERATION_MAILBOX_LINE)
		return foundation.EXIT_FAILURE
	case outcome.tool_error:
		fmt.eprintfln("modustool: fuzz regression operations: an error of the tool: %s", outcome.fault.text)
		return foundation.EXIT_FAILURE
	case outcome.faulting >= 0:
		fmt.eprintfln("modustool: fuzz regression operations: %s still breaks an oracle on the kernel that ships, at its sequence %d (%s): fix the fault first", folder, outcome.faulting, outcome.fault.signature)
		fmt.eprintfln("modustool:   %s", outcome.fault.text)
		return foundation.EXIT_FAILURE
	}
	last := new(operation_sequence.Sequence)
	defer free(last)
	_ = operation_sequence.check(life[len(life) - 1], last)
	expectations, answer_problem := operation_step_expectations_of(last, state.results)
	if answer_problem != "" {
		fmt.eprintfln("modustool: fuzz regression operations: %s", answer_problem)
		return foundation.EXIT_FAILURE
	}
	defer delete(expectations)
	bytes, written := operation_regression_write({signature = signature, life = life, expectations = expectations})
	if !written {
		fmt.eprintln("modustool: fuzz regression operations: the life passes the bounds of a regression input")
		return foundation.EXIT_FAILURE
	}
	defer delete(bytes)
	path, stored := fuzz.fuzz_input_write(OPERATION_REGRESSION_FOLDER, bytes)
	if !stored {
		return foundation.EXIT_FAILURE
	}
	state.part.passed = true
	fmt.printfln("modustool: fuzz regression operations: the regression input %s of %s, %d sequences; the last sequence must get:", path, signature, len(life))
	for expected, step in expectations {
		if expected.status == .Ok {
			fmt.printfln("modustool:   step %d: %s: Ok", step, operation_word_name(last.steps[step].operation))
			continue
		}
		fmt.printfln("modustool:   step %d: %s: %v, the record %v of the argument %d, %d details", step, operation_word_name(last.steps[step].operation), expected.status, expected.record_kind, expected.record_argument, expected.detail_count)
	}
	return 0
}
