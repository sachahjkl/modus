package modustool

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/operation"
import "modus:contract/operation_sequence"
import "modustool:foundation"

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

// The folder of the corpus of the kernel operations, beside the folders of
// the fuzz targets, which it is not: it runs in a machine.
OPERATION_CORPUS_NAME :: "operations"
OPERATION_CORPUS_FOLDER :: FUZZ_CORPUS_FOLDER + "/" + OPERATION_CORPUS_NAME
OPERATION_REGRESSION_FOLDER :: OPERATION_CORPUS_FOLDER + "/" + FUZZ_REGRESSION_PART
OPERATION_REACH_FOLDER :: OPERATION_CORPUS_FOLDER + "/" + FUZZ_REACH_PART

OPERATION_REGRESSION_MAGIC :: u64(0x5247_4552_5245_504F) // The bytes "OPERREGR".
OPERATION_REGRESSION_FORMAT :: 1 // The format of the bytes. The reader refuses another.
// The sequences of one regression input: a minimized life, and most hold
// one sequence. The bound keeps an input under the byte limit of a target.
OPERATION_REGRESSION_SEQUENCES_MOST :: 16
// The bytes of the signature that a regression input keeps for its reader.
OPERATION_REGRESSION_SIGNATURE_BYTES_MOST :: 512

// The first bytes of a regression input. Then: the signature, the
// sequences, each with its count of bytes, each part padded to 8 bytes, and
// one Operation_Expectation_Record for each step of the last sequence that
// ran, in the order of the steps.
Operation_Regression_Header :: struct {
	magic:             u64,
	format:            u64,
	sequence_count:    u64, // 1 to OPERATION_REGRESSION_SEQUENCES_MOST.
	signature_bytes:   u64, // At most OPERATION_REGRESSION_SIGNATURE_BYTES_MOST.
	expectation_count: u64, // The steps of the last sequence that ran: at most its steps.
}

Operation_Detail_Record :: struct {
	kind:     i64, // An errors.Kind.
	argument: i64,
}

Operation_Expectation_Record :: struct {
	status:          u64, // An operation.Status.
	record_kind:     i64, // An errors.Kind; 0 for Ok.
	record_argument: i64, // From 1; 0: the call as a whole, and for Ok.
	detail_count:    u64, // At most ERROR_DETAILS_MOST; 0 for Ok.
	details:         [operation.ERROR_DETAILS_MOST]Operation_Detail_Record, // Zero past the count.
}

// The size of the largest regression input: the byte limit of the corpus
// of the operations.
OPERATION_REGRESSION_BYTES_MOST :: size_of(Operation_Regression_Header) + OPERATION_REGRESSION_SIGNATURE_BYTES_MOST + OPERATION_REGRESSION_SEQUENCES_MOST * (8 + (operation_sequence.SEQUENCE_BYTES_MOST + 7) / 8 * 8) + operation_sequence.STEPS_MOST * size_of(Operation_Expectation_Record)
#assert(OPERATION_REGRESSION_BYTES_MOST <= FUZZ_CORPUS_TARGET_BYTE_LIMIT)

Operation_Detail_Expectation :: struct {
	kind:     errors.Kind,
	argument: i64,
}

// The answer that one step of the last sequence of a regression input
// must get: its status; for a refusal, the kind and the argument of its
// error record and each record of its table of error details, in order.
Operation_Step_Expectation :: struct {
	status:          operation.Status,
	record_kind:     errors.Kind,
	record_argument: i64,
	detail_count:    int,
	details:         [operation.ERROR_DETAILS_MOST]Operation_Detail_Expectation,
}

// A regression input that the reader accepted. The life and the signature
// are slices of the bytes of the caller.
Operation_Regression :: struct {
	signature:    string,
	life:         [][]u8,
	expectations: []Operation_Step_Expectation,
}

// Why the reader refuses a regression input. The comment says what the
// index of the refusal names.
Operation_Regression_Problem :: enum u8 {
	None,
	Too_Small,         // Fewer bytes than the header.
	Magic,             // It does not start with OPERATION_REGRESSION_MAGIC.
	Format,            // Another format.
	Sequence_Count,    // No sequence, or more than OPERATION_REGRESSION_SEQUENCES_MOST.
	Signature_Bytes,   // A signature longer than OPERATION_REGRESSION_SIGNATURE_BYTES_MOST.
	Expectation_Count, // More expectations than the steps of the last sequence.
	Size,              // The bytes are not the parts exactly; index: the sequence whose count passes the end, or -1.
	Sequence,          // The sequence `index` is refused by check: see sequence_refusal.
	Status,            // The expectation `index` has a status word that names no status.
	Record_Kind,       // The expectation `index` has a record kind that names no kind.
	Detail_Count,      // The expectation `index` counts more details than ERROR_DETAILS_MOST.
	Detail_Kind,       // A detail of the expectation `index` names no kind.
	Unused_Detail,     // The expectation `index` has a detail past its count that is not zero.
	Answer_Of_Ok,      // The expectation `index` is Ok, with a record or a detail.
}

Operation_Regression_Refusal :: struct {
	problem:          Operation_Regression_Problem,
	index:            int,
	sequence_refusal: operation_sequence.Refusal,
}

@(private = "file")
operation_padded :: proc(count: int) -> int {
	return (count + 7) / 8 * 8
}

// operation_regression_read reads a regression input, and checks each
// rule of its format; it is the one border of its words, and gives each
// word as its member. A refused input gives a zero regression, so no
// caller runs a part of it.
operation_regression_read :: proc(bytes: []u8, allocator := context.allocator) -> (regression: Operation_Regression, refusal: Operation_Regression_Refusal) {
	refusal.index = -1
	life: [][]u8
	expectations: []Operation_Step_Expectation
	defer {
		if refusal.problem != .None {
			delete(life, allocator)
			delete(expectations, allocator)
			regression = {}
		}
	}
	header: Operation_Regression_Header
	if len(bytes) < size_of(header) {
		refusal.problem = .Too_Small
		return
	}
	copy(([^]u8)(&header)[:size_of(header)], bytes)
	switch {
	case header.magic != OPERATION_REGRESSION_MAGIC:
		refusal.problem = .Magic
	case header.format != OPERATION_REGRESSION_FORMAT:
		refusal.problem = .Format
	case header.sequence_count < 1 || header.sequence_count > OPERATION_REGRESSION_SEQUENCES_MOST:
		refusal.problem = .Sequence_Count
	case header.signature_bytes > OPERATION_REGRESSION_SIGNATURE_BYTES_MOST:
		refusal.problem = .Signature_Bytes
	case header.expectation_count > operation_sequence.STEPS_MOST:
		refusal.problem = .Expectation_Count
	}
	if refusal.problem != .None {
		return
	}
	offset := size_of(header)
	signature_bytes := int(header.signature_bytes)
	if offset + operation_padded(signature_bytes) > len(bytes) {
		refusal.problem = .Size
		return
	}
	signature := string(bytes[offset:][:signature_bytes])
	offset += operation_padded(signature_bytes)
	life = make([][]u8, int(header.sequence_count), allocator)
	last := new(operation_sequence.Sequence)
	defer free(last)
	for place in 0 ..< len(life) {
		if offset + 8 > len(bytes) {
			refusal.problem, refusal.index = .Size, place
			return
		}
		count: u64
		copy(([^]u8)(&count)[:size_of(count)], bytes[offset:])
		offset += 8
		if count > operation_sequence.SEQUENCE_BYTES_MOST || offset + operation_padded(int(count)) > len(bytes) {
			refusal.problem, refusal.index = .Size, place
			return
		}
		life[place] = bytes[offset:][:count]
		if sequence_refusal := operation_sequence.check(life[place], last); sequence_refusal.problem != .None {
			refusal.problem, refusal.index, refusal.sequence_refusal = .Sequence, place, sequence_refusal
			return
		}
		offset += operation_padded(int(count))
	}
	// `last` holds the last sequence now.
	if header.expectation_count > u64(last.step_count) {
		refusal.problem = .Expectation_Count
		return
	}
	expectation_count := int(header.expectation_count)
	if len(bytes) - offset != expectation_count * size_of(Operation_Expectation_Record) {
		refusal.problem = .Size
		return
	}
	expectations = make([]Operation_Step_Expectation, expectation_count, allocator)
	for &expected, place in expectations {
		record: Operation_Expectation_Record
		copy(([^]u8)(&record)[:size_of(record)], bytes[offset + place * size_of(record):])
		status, status_known := enum_word.member_of_word(operation.Status, record.status)
		if !status_known {
			refusal.problem, refusal.index = .Status, place
			return
		}
		kind, kind_known := enum_word.member_of_word(errors.Kind, u64(record.record_kind))
		if !kind_known {
			refusal.problem, refusal.index = .Record_Kind, place
			return
		}
		if record.detail_count > operation.ERROR_DETAILS_MOST {
			refusal.problem, refusal.index = .Detail_Count, place
			return
		}
		expected = {status = status, record_kind = kind, record_argument = record.record_argument, detail_count = int(record.detail_count)}
		for detail, detail_place in record.details {
			if detail_place >= expected.detail_count {
				if detail != (Operation_Detail_Record{}) {
					refusal.problem, refusal.index = .Unused_Detail, place
					return
				}
				continue
			}
			detail_kind, detail_known := enum_word.member_of_word(errors.Kind, u64(detail.kind))
			if !detail_known {
				refusal.problem, refusal.index = .Detail_Kind, place
				return
			}
			expected.details[detail_place] = {kind = detail_kind, argument = detail.argument}
		}
		if status == .Ok && (kind != .None || record.record_argument != 0 || expected.detail_count != 0) {
			refusal.problem, refusal.index = .Answer_Of_Ok, place
			return
		}
	}
	regression = {signature = signature, life = life, expectations = expectations}
	return
}

// operation_regression_write writes a regression input. It refuses only a
// count past its bound, so a test writes an input that the reader must
// refuse by changing its bytes.
operation_regression_write :: proc(regression: Operation_Regression, allocator := context.allocator) -> (bytes: []u8, ok: bool) {
	if len(regression.life) < 1 || len(regression.life) > OPERATION_REGRESSION_SEQUENCES_MOST || len(regression.signature) > OPERATION_REGRESSION_SIGNATURE_BYTES_MOST || len(regression.expectations) > operation_sequence.STEPS_MOST {
		return nil, false
	}
	size := size_of(Operation_Regression_Header) + operation_padded(len(regression.signature))
	for sequence in regression.life {
		if len(sequence) > operation_sequence.SEQUENCE_BYTES_MOST {
			return nil, false
		}
		size += 8 + operation_padded(len(sequence))
	}
	size += len(regression.expectations) * size_of(Operation_Expectation_Record)
	bytes = make([]u8, size, allocator)
	header := Operation_Regression_Header {
		magic             = OPERATION_REGRESSION_MAGIC,
		format            = OPERATION_REGRESSION_FORMAT,
		sequence_count    = u64(len(regression.life)),
		signature_bytes   = u64(len(regression.signature)),
		expectation_count = u64(len(regression.expectations)),
	}
	copy(bytes, ([^]u8)(&header)[:size_of(header)])
	offset := size_of(header)
	copy(bytes[offset:], regression.signature)
	offset += operation_padded(len(regression.signature))
	for sequence in regression.life {
		count := u64(len(sequence))
		copy(bytes[offset:], ([^]u8)(&count)[:size_of(count)])
		offset += 8
		copy(bytes[offset:], sequence)
		offset += operation_padded(len(sequence))
	}
	for &expected in regression.expectations {
		record := Operation_Expectation_Record {
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
operation_step_expectations_of :: proc(sequence: ^operation_sequence.Sequence, results: ^operation_sequence.Runner_Results, allocator := context.allocator) -> (expectations: []Operation_Step_Expectation, problem: string) {
	if results.steps_run > u64(sequence.step_count) {
		return nil, fmt.tprintf("the runner says that %d steps ran, of %d", results.steps_run, sequence.step_count)
	}
	expectations = make([]Operation_Step_Expectation, int(results.steps_run), allocator)
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
operation_step_expectations_problem :: proc(expectations: []Operation_Step_Expectation, results: ^operation_sequence.Runner_Results) -> string {
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

// One regression input of a folder, with its name and its bytes.
Operation_Regression_Input :: struct {
	name:       string,
	bytes:      []u8,
	regression: Operation_Regression,
}

// operation_regression_inputs_read reads each file of a folder of
// regression inputs, in the order of their names. A file that the reader
// refuses, a file that cannot be read and an entry that is no file are
// problems, never skipped: the test part runs each input of the folder or
// fails. A folder that does not exist holds no input.
operation_regression_inputs_read :: proc(folder: string, allocator := context.allocator) -> (inputs: []Operation_Regression_Input, problems: []string) {
	list := make([dynamic]Operation_Regression_Input, allocator)
	found := make([dynamic]string, context.temp_allocator)
	entries, error := os.read_all_directory_by_path(folder, context.temp_allocator)
	if error != nil {
		return list[:], found[:]
	}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	for entry in entries {
		if entry.type != .Regular {
			append(&found, fmt.tprintf("%s/%s is no file of a regression input", folder, entry.name))
			continue
		}
		bytes, read_error := os.read_entire_file(entry.fullpath, allocator)
		if read_error != nil {
			append(&found, fmt.tprintf("cannot read the regression input %s: %v", entry.fullpath, read_error))
			continue
		}
		regression, refusal := operation_regression_read(bytes, allocator)
		if refusal.problem != .None {
			append(&found, fmt.tprintf("the regression input %s is refused: %v of the part %d %v", entry.fullpath, refusal.problem, refusal.index, refusal.sequence_refusal))
			delete(bytes, allocator)
			continue
		}
		append(&list, Operation_Regression_Input{name = strings.clone(entry.name, allocator), bytes = bytes, regression = regression})
	}
	return list[:], found[:]
}

// operation_corpus_problems gives each fault of the content of the corpus
// of the operations, past the form and the bounds that
// fuzz_corpus_problems checks: each regression input that its reader
// refuses, and each reach input from which the generator builds a sequence
// that check refuses.
operation_corpus_problems :: proc(folder: string, problems: ^[dynamic]string) {
	_, regression_problems := operation_regression_inputs_read(strings.concatenate({folder, "/", FUZZ_REGRESSION_PART}, context.temp_allocator), context.temp_allocator)
	append(problems, ..regression_problems)
	reach := fuzz_inputs_read(strings.concatenate({folder, "/", FUZZ_REACH_PART}, context.temp_allocator), context.temp_allocator)
	if len(reach) == 0 {
		return
	}
	if !fuzz_operation_sequence_start() {
		append(problems, "the generator of the operation sequences cannot read its grammar")
		return
	}
	sequence := new(operation_sequence.Sequence)
	defer free(sequence)
	for input in reach {
		choices := fuzz_choices_of(input.bytes)
		fuzz_operation_sequence_generate(&choices, sequence)
		if bytes, accepted := operation_sequence_encode(sequence, context.temp_allocator); !accepted {
			append(problems, fmt.tprintf("%s/%s/%s builds a sequence that check refuses", folder, FUZZ_REACH_PART, input.name))
		} else {
			delete(bytes, context.temp_allocator)
		}
	}
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
	if len(list) < 1 || len(list) > OPERATION_REGRESSION_SEQUENCES_MOST {
		operation_life_free(list[:])
		return nil, "", fmt.tprintf("%s holds %d sequences, and a regression input holds 1 to %d", minimized, len(list), OPERATION_REGRESSION_SEQUENCES_MOST)
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
	if len(signature) > OPERATION_REGRESSION_SIGNATURE_BYTES_MOST {
		fmt.eprintfln("modustool: fuzz regression operations: the signature has %d bytes, past %d", len(signature), OPERATION_REGRESSION_SIGNATURE_BYTES_MOST)
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
	path, stored := fuzz_input_write(OPERATION_REGRESSION_FOLDER, bytes)
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
