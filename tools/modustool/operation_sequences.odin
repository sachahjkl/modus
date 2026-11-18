package modustool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/operation"
import "modus:contract/operation_sequence"

// The machine of the operation sequences (src/md/infrastructure/kernel_fuzzing.md,
// "The machine", "The oracles"): the tool writes each sequence in the
// mailbox of the program operation_fuzzing through the memory file of the
// machine, reads what the kernel answered to each step, and checks the
// answers against the forms of the kernel operations, the statuses of their
// reference comments and the budget of the sequence. The machine runs the
// kernel that ships.

// The line of the program operation_fuzzing that gives the physical address
// of its mailbox.
OPERATION_MAILBOX_LINE :: "operation_fuzzing: mailbox at "
// The memory files of the machine of the test part and of a replay: the
// tool reads them in a step after other steps, so their paths are fixed.
OPERATION_SEQUENCES_MEMORY_FILE :: BUILD_FOLDER + "/test_output_operation_sequences_memory.raw"
OPERATION_REPLAY_MEMORY_FILE :: BUILD_FOLDER + "/test_output_operation_replay_memory.raw"
TEST_OUTPUT_OPERATION_REPLAY :: BUILD_FOLDER + "/test_output_operation_replay.txt"
// The command `fuzz replay operations`, as the table of the volumes of the
// commands names it.
OPERATION_REPLAY_COMMAND :: "operation_replay"

// ---------------------------------------------------------------------
// The statuses of the reference comments.

// The statuses that the reference comment of each operation lists in its
// part "**Statuses**". `Ok` is no refusal and is in no list.
Operation_Statuses :: [operation.Operation]bit_set[operation.Status]

// operation_statuses_of_comment reads the list "**Statuses**" of the
// comment of one operation: each line "- `A`, `B`: text" names the statuses
// in code marks before its first colon. The list ends at the next heading:
// a line that starts with "**" at its first column. A line of an item that
// goes on is indented, so a bold word at its start ("  **Counters** gives")
// is no heading. A name that is no status, a list with no line, and a
// comment with no list are refused.
operation_statuses_of_comment :: proc(comment: string) -> (statuses: bit_set[operation.Status], problem: string) {
	heading := strings.index(comment, "**Statuses**")
	if heading < 0 {
		return {}, "the comment has no part **Statuses**"
	}
	rest := comment[heading + len("**Statuses**"):]
	lines := 0
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, "**") {
			break
		}
		text := strings.trim_space(line)
		if !strings.has_prefix(text, "- `") {
			continue
		}
		head := text[2:]
		if colon := strings.index_byte(head, ':'); colon >= 0 {
			head = head[:colon]
		}
		names := 0
		for {
			open := strings.index_byte(head, '`')
			if open < 0 {
				break
			}
			close := strings.index_byte(head[open + 1:], '`')
			if close < 0 {
				return {}, fmt.tprintf("the line \"%s\" has a code mark with no end", text)
			}
			name := head[open + 1:][:close]
			known := false
			for status in operation.Status {
				if operation.STATUS_NAMES[status] == name && status != .Ok {
					statuses += {status}
					known = true
				}
			}
			if !known {
				return {}, fmt.tprintf("the line \"%s\" names %s, which is no status of a refusal", text, name)
			}
			names += 1
			head = head[open + 1 + close + 1:]
		}
		if names == 0 {
			return {}, fmt.tprintf("the line \"%s\" names no status", text)
		}
		lines += 1
	}
	if lines == 0 {
		return {}, "the part **Statuses** has no line"
	}
	return statuses, ""
}

// operation_statuses_read reads the statuses of each operation from the
// reference comments. The member None is no operation and has none.
operation_statuses_read :: proc(reference: string) -> (statuses: Operation_Statuses, problem: string) {
	members, read_problem := site_enumeration_read(reference, OPERATION_SOURCE, "Operation")
	if read_problem != "" {
		return {}, read_problem
	}
	found: [operation.Operation]bool
	for member in members {
		for candidate in operation.Operation {
			if operation.OPERATIONS[candidate].name != member.name {
				continue
			}
			found[candidate] = true
			if candidate == .None {
				continue
			}
			listed, listed_problem := operation_statuses_of_comment(member.comment)
			if listed_problem != "" {
				return {}, fmt.tprintf("%s, the operation %s: %s", OPERATION_SOURCE, member.name, listed_problem)
			}
			statuses[candidate] = listed
		}
	}
	for candidate in operation.Operation {
		if !found[candidate] {
			return {}, fmt.tprintf("%s: no member %s in the enumeration Operation", OPERATION_SOURCE, operation.OPERATIONS[candidate].name)
		}
	}
	return statuses, ""
}

// ---------------------------------------------------------------------
// The oracles.

Operation_Oracle :: enum u8 {
	None,
	Outcome,                // The service refused the sequence, did not start the runner, or the runner did not stop.
	Status_Word,            // A completion has a status word that names no status.
	Unknown_Operation,      // A word that names no operation gave another status than Bad_Operation.
	Status_Not_Listed,      // A refusal with a status that the reference of the operation does not list.
	Form_Refusal_Accepted,  // The form of a parameter refuses its value, and the operation gave Ok.
	Details_Changed,        // An operation that gave Ok changed its table of error details.
	Details_Count,          // A refusal with no error detail, or more than ERROR_DETAILS_MOST.
	Details_First,          // The first error detail is not the error record of the completion.
	Details_Argument,       // An error detail names an argument that the operation does not read.
	Details_Missing,        // An argument whose value the form refuses has no error detail with that problem and its limit.
	Handle_Kind,            // A handle that a step gave has another kind than its reference says.
	Refusal_Changed_Budget, // Two reads of the budget with only refusals between them differ.
	Budget_Not_Back,        // The budget of the sequence holds less or more after the runner stopped than before it started.
}

Operation_Finding :: struct {
	oracle: Operation_Oracle,
	step:   int, // The step, from 0; -1 for the whole sequence.
	text:   string,
}

// The grammar that the oracles read: the result of each operation and its
// statuses, from the reference comments.
Operation_Grammar :: struct {
	results:  [operation.Operation]Fuzz_Operation_Result,
	statuses: Operation_Statuses,
}

operation_grammar_read :: proc() -> (grammar: Operation_Grammar, ok: bool) {
	grammar.results = fuzz_operation_results_read(fuzz_operation_reference) or_return
	problem: string
	grammar.statuses, problem = operation_statuses_read(fuzz_operation_reference)
	if problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		return {}, false
	}
	return grammar, true
}

// operation_findings checks one execution: the outcome, the budget, then
// each step whose results the runner wrote. The header and the results come
// from the memory of the machine: each count is checked before its use.
operation_findings :: proc(sequence: ^operation_sequence.Sequence, header: ^operation_sequence.Mailbox_Header, results: ^operation_sequence.Runner_Results, grammar: ^Operation_Grammar) -> []Operation_Finding {
	findings := make([dynamic]Operation_Finding, context.temp_allocator)
	outcome, outcome_known := enum_word.member_of_word(operation_sequence.Execution_Outcome, header.outcome)
	if !outcome_known {
		append(&findings, Operation_Finding{.Outcome, -1, fmt.tprintf("the outcome word %d names no outcome", header.outcome)})
		return findings[:]
	}
	switch outcome {
	case .Ran, .Stopped:
	case .None, .Refused, .Not_Started, .Hung:
		append(&findings, Operation_Finding{.Outcome, -1, fmt.tprintf("the outcome is %v (problem %d, start status %d, step started %d)", outcome, header.refusal_problem, header.start_status, results.step_started)})
		return findings[:]
	}
	if outcome == .Stopped && (header.stop_code == operation_sequence.RUNNER_SEQUENCE_REFUSED_CODE || header.stop_code == operation_sequence.RUNNER_BATCH_REFUSED_CODE) {
		append(&findings, Operation_Finding{.Outcome, -1, fmt.tprintf("the runner could not run its sequence: stop code %x", header.stop_code)})
		return findings[:]
	}
	if header.budget_after != header.budget_before {
		append(&findings, Operation_Finding{.Budget_Not_Back, -1, fmt.tprintf("the budget held %v before the runner and %v after it", header.budget_before, header.budget_after)})
	}
	if results.steps_run > u64(sequence.step_count) {
		append(&findings, Operation_Finding{.Outcome, -1, fmt.tprintf("the runner says %d steps ran, of %d", results.steps_run, sequence.step_count)})
		return findings[:]
	}
	steps_run := int(results.steps_run)
	for step in 0 ..< steps_run {
		operation_step_findings(sequence, results, grammar, step, &findings)
	}
	operation_budget_read_findings(sequence, results, steps_run, &findings)
	return findings[:]
}

// operation_step_findings checks the status and the table of error details
// of one step, and the kind of the handle that a planted Handle_State reads.
@(private = "file")
operation_step_findings :: proc(sequence: ^operation_sequence.Sequence, results: ^operation_sequence.Runner_Results, grammar: ^Operation_Grammar, step: int, findings: ^[dynamic]Operation_Finding) {
	result := &results.results[step]
	status, status_known := enum_word.member_of_word(operation.Status, result.status)
	if !status_known {
		append(findings, Operation_Finding{.Status_Word, step, fmt.tprintf("the status word %d names no status", result.status)})
		return
	}
	word := sequence.steps[step].operation
	chosen, known := enum_word.member_of_word(operation.Operation, u64(word))
	if !known || chosen == .None {
		operation_unknown_findings(word, status, result, step, findings)
		return
	}
	name := operation.OPERATIONS[chosen].name
	if status != .Ok && status not_in grammar.statuses[chosen] {
		append(findings, Operation_Finding{.Status_Not_Listed, step, fmt.tprintf("%s gave %v, which its reference does not list", name, status)})
	}
	values := result.words
	for index in 0 ..< operation_sequence.ARGUMENTS {
		if !operation.argument_is_read(chosen, index, values) {
			continue
		}
		if problem, limit := operation.argument_value_problem(chosen, index, values); problem != .None && status == .Ok {
			append(findings, Operation_Finding{.Form_Refusal_Accepted, step, fmt.tprintf("%s took the value %d of %s, which its form refuses with %v (limit %d)", name, values[index], operation.OPERATIONS[chosen].parameters[index].name, problem, limit)})
		}
	}
	if result.kind & u64(operation.COMMAND_NAMES_ERROR_DETAILS) != 0 {
		operation_details_findings(chosen, status, result, step, findings)
	}
	// A planted Handle_State of the first value of an earlier step.
	if chosen == .Handle_State && status == .Ok {
		argument := sequence.steps[step].arguments[0]
		if argument.source == .Result && argument.place == 0 && argument.offset == 0 {
			earlier := &results.results[argument.step]
			earlier_operation, earlier_known := enum_word.member_of_word(operation.Operation, u64(sequence.steps[argument.step].operation))
			expected := grammar.results[earlier_operation]
			if earlier_known && earlier.status == u64(operation.Status.Ok) && expected.handle && expected.kind != .None && result.values[0] != u64(expected.kind) {
				append(findings, Operation_Finding{.Handle_Kind, step, fmt.tprintf("the handle of step %d (%s) has the kind %d, and its reference says %v", argument.step, operation.OPERATIONS[earlier_operation].name, result.values[0], expected.kind)})
			}
		}
	}
}

// operation_unknown_findings checks the answer to a word that names no
// operation: the status Bad_Operation, the error record Unknown_Operation
// with the kind that the runner sent (the bit of a table included) and the
// last operation as its limit, and a table of error details that the kernel
// did not write: it reads no table for a kind of no operation
// (src/md/features/kernel_error_details.md).
@(private = "file")
operation_unknown_findings :: proc(word: u32, status: operation.Status, result: ^operation_sequence.Step_Result, step: int, findings: ^[dynamic]Operation_Finding) {
	if status != .Bad_Operation {
		append(findings, Operation_Finding{.Unknown_Operation, step, fmt.tprintf("the word %d names no operation and gave %v", word, status)})
		return
	}
	record := transmute(errors.Error_Record)result.values
	if record.kind != i64(errors.Kind.Unknown_Operation) || record.value != i64(result.kind) || record.limit != i64(max(operation.Operation)) || record.argument != 0 {
		append(findings, Operation_Finding{.Unknown_Operation, step, fmt.tprintf("the word %d names no operation, and its error record is %v", word, record)})
	}
	if result.kind & u64(operation.COMMAND_NAMES_ERROR_DETAILS) == 0 {
		return
	}
	pattern := operation_sequence.details_pattern()
	changed := result.details_count != 0
	for detail in result.details {
		changed ||= detail != pattern
	}
	if changed {
		append(findings, Operation_Finding{.Unknown_Operation, step, fmt.tprintf("the word %d names no operation, and the kernel wrote its table of error details (count %d)", word, result.details_count)})
	}
}

// operation_details_findings checks a table of error details against the
// forms: the kernel writes the error record first, then one detail for each
// other argument that the checks of its form find wrong
// (src/md/features/kernel_error_details.md).
@(private = "file")
operation_details_findings :: proc(chosen: operation.Operation, status: operation.Status, result: ^operation_sequence.Step_Result, step: int, findings: ^[dynamic]Operation_Finding) {
	name := operation.OPERATIONS[chosen].name
	if status == .Ok {
		pattern := operation_sequence.details_pattern()
		changed := result.details_count != 0
		for detail in result.details {
			changed ||= detail != pattern
		}
		if changed {
			append(findings, Operation_Finding{.Details_Changed, step, fmt.tprintf("%s gave Ok and changed its table of error details (count %d)", name, result.details_count)})
		}
		return
	}
	if result.details_count < 1 || result.details_count > operation.ERROR_DETAILS_MOST {
		append(findings, Operation_Finding{.Details_Count, step, fmt.tprintf("%s gave %v with %d error details", name, status, result.details_count)})
		return
	}
	count := int(result.details_count)
	first := transmute(errors.Error_Record)result.values
	if result.details[0] != first {
		append(findings, Operation_Finding{.Details_First, step, fmt.tprintf("%s: the first error detail %v is not the error record %v", name, result.details[0], first)})
	}
	values := result.words
	for detail in result.details[1:count] {
		if detail.argument < 1 || detail.argument > operation_sequence.ARGUMENTS || !operation.argument_is_read(chosen, int(detail.argument) - 1, values) {
			append(findings, Operation_Finding{.Details_Argument, step, fmt.tprintf("%s: an error detail names the argument %d, which the operation does not read", name, detail.argument)})
		}
	}
	for index in 0 ..< operation_sequence.ARGUMENTS {
		if i64(index + 1) == first.argument || !operation.argument_is_read(chosen, index, values) {
			continue
		}
		problem, limit := operation.argument_value_problem(chosen, index, values)
		if problem == .None {
			continue
		}
		found := false
		for detail in result.details[1:count] {
			found ||= detail.argument == i64(index + 1) && detail.kind == i64(problem) && detail.limit == i64(limit)
		}
		if !found {
			append(findings, Operation_Finding{.Details_Missing, step, fmt.tprintf("%s: the argument %s has the value %d, which its form refuses with %v (limit %d), and no error detail says it", name, operation.OPERATIONS[chosen].parameters[index].name, values[index], problem, limit)})
		}
	}
}

// operation_budget_read_findings compares two planted reads of the budget
// of the runner with only refusals between them: a refusal changes nothing.
@(private = "file")
operation_budget_read_findings :: proc(sequence: ^operation_sequence.Sequence, results: ^operation_sequence.Runner_Results, steps_run: int, findings: ^[dynamic]Operation_Finding) {
	planted :: proc(sequence: ^operation_sequence.Sequence, results: ^operation_sequence.Runner_Results, step: int) -> bool {
		item := &sequence.steps[step]
		return item.operation == u32(operation.Operation.Budget_Read) && item.arguments[0].source == .Budget && results.results[step].status == u64(operation.Status.Ok)
	}
	before := -1
	for step in 0 ..< steps_run {
		if planted(sequence, results, step) {
			if before >= 0 {
				a, b := &results.results[before], &results.results[step]
				if a.values[0] != b.values[0] || a.values[1] != b.values[1] || a.values[2] != b.values[2] {
					append(findings, Operation_Finding{.Refusal_Changed_Budget, step, fmt.tprintf("the budget held pages %d, programs %d, threads %d at step %d, and %d, %d, %d here, with only refusals between", a.values[0], a.values[1], a.values[2], before, b.values[0], b.values[1], b.values[2])})
				}
			}
			before = step
			continue
		}
		if results.results[step].status == u64(operation.Status.Ok) {
			before = -1
		}
	}
}

// ---------------------------------------------------------------------
// The seed sequences.

// operation_seed_step gives a step of an operation whose arguments fit
// their forms where a start handle or an area can: a handle of the budget,
// of the log or of the first area, an address at the start of the first
// area, a count of 1, no flag, the first member of a set. A handle that no start handle
// can be, and a handle that can be 0, names no handle: 0 names the caller,
// and a step must not hold the thread of the runner.
operation_seed_step :: proc(chosen: operation.Operation) -> operation_sequence.Sequence_Step {
	item := operation_sequence.Sequence_Step{operation = u32(chosen)}
	for parameter, index in operation.OPERATIONS[chosen].parameters {
		argument := operation_sequence.Argument{source = .Value}
		switch parameter.form {
		case .None, .Value, .Bounded:
		case .Handle, .Handle_Or_Zero:
			switch parameter.kind {
			case .Budget:
				argument = {source = .Budget}
			case .Log:
				argument = {source = .Log}
			case .Memory:
				argument = {source = .Area_Handle, area = 0}
			case .None, .Program, .Interrupt, .Ports, .Machine, .Thread:
				argument.value = OPERATION_SEED_ABSENT_HANDLE
			}
		case .Address:
			argument = {source = .Area_Address, area = 0}
			// The code of a new thread is a thread entry of the runner, and
			// its stack ends at the end of the first area.
			if chosen == .Thread_Create && parameter.name == "entry" {
				argument = {source = .Thread_Entry, entry = .Wait_On_Word}
			}
			if chosen == .Thread_Create && parameter.name == "stack" {
				argument.offset = operation.PAGE_SIZE
			}
		case .Count:
			argument.value = 1
		case .Flags:
		case .Choice:
			argument.value = min(parameter.limit, 1)
		}
		item.arguments[index] = argument
	}
	return item
}

// A handle number that names no handle of a new program: the slot is past
// each handle that the runner holds, with a generation that no slot has.
OPERATION_SEED_ABSENT_HANDLE :: u64(0xFFFF_0FFF)

// The text of the first area of each seed: the name of a program and a
// line of the log.
OPERATION_SEED_TEXT :: "seed"

operation_seed_sequence :: proc(steps: []operation_sequence.Sequence_Step) -> operation_sequence.Sequence {
	sequence: operation_sequence.Sequence
	sequence.area_count = 1
	sequence.areas[0] = {pages = 1, content_bytes = len(OPERATION_SEED_TEXT)}
	copy(sequence.content[:], OPERATION_SEED_TEXT)
	for item, index in steps {
		sequence.steps[index] = item
	}
	sequence.step_count = len(steps)
	return sequence
}

// operation_seed_sequences gives the seeds of the test part, each as its
// bytes: one step of each operation with the arguments of
// operation_seed_step, then the cases that must succeed or be refused with
// their details. Each is a sequence that `check` accepts: a host test
// checks it. The regression of a fuzz finding is no seed: it is a
// regression input of the corpus, with the answer of each step
// (operation_corpus.odin).
operation_seed_sequences :: proc(allocator := context.allocator) -> [][]u8 {
	list := make([dynamic][]u8, allocator)
	add :: proc(list: ^[dynamic][]u8, sequence: operation_sequence.Sequence, allocator := context.allocator) {
		sequence := sequence
		size, _ := operation_sequence.size(&sequence)
		bytes := make([]u8, size, allocator)
		_, _ = operation_sequence.write(bytes, &sequence)
		append(list, bytes)
	}
	for chosen in operation.Operation {
		if chosen == .None {
			continue
		}
		steps := [?]operation_sequence.Sequence_Step{operation_seed_step(chosen)}
		add(&list, operation_seed_sequence(steps[:]), allocator)
	}
	budget_read := operation_sequence.Sequence_Step{operation = u32(operation.Operation.Budget_Read)}
	budget_read.arguments[0] = {source = .Budget}
	// A memory object, its kind, a mapping of it, its unmap and its close.
	{
		create := operation_sequence.Sequence_Step{operation = u32(operation.Operation.Memory_Create)}
		create.arguments[0] = {source = .Budget}
		create.arguments[1] = {source = .Value, value = 1}
		state := operation_sequence.Sequence_Step{operation = u32(operation.Operation.Handle_State)}
		state.arguments[0] = {source = .Result, step = 0}
		mapping := operation_sequence.Sequence_Step{operation = u32(operation.Operation.Memory_Map)}
		mapping.arguments[0] = {source = .Result, step = 0}
		mapping.arguments[3] = {source = .Value, value = transmute(u64)operation.Map_Flags{.Write}}
		unmap := operation_sequence.Sequence_Step{operation = u32(operation.Operation.Memory_Unmap)}
		unmap.arguments[1] = {source = .Result, step = 2}
		close := operation_sequence.Sequence_Step{operation = u32(operation.Operation.Handle_Close)}
		close.arguments[0] = {source = .Result, step = 0}
		steps := [?]operation_sequence.Sequence_Step{create, state, mapping, unmap, close, budget_read}
		add(&list, operation_seed_sequence(steps[:]), allocator)
	}
	// A count past its limit and a flag that the kernel does not know, then
	// a handle that names nothing with the same flag: each refused with a
	// detail for each argument, and no change of the budget.
	{
		too_large := operation_sequence.Sequence_Step{operation = u32(operation.Operation.Memory_Create)}
		too_large.arguments[0] = {source = .Budget}
		too_large.arguments[1] = {source = .Value, value = operation.MEMORY_PAGE_LIMIT + 1}
		too_large.arguments[2] = {source = .Value, value = operation.MEMORY_FLAGS_KNOWN + 1 << 32}
		absent := too_large
		absent.arguments[0] = {source = .Value, value = OPERATION_SEED_ABSENT_HANDLE}
		absent.arguments[1] = {source = .Value, value = 1}
		steps := [?]operation_sequence.Sequence_Step{budget_read, too_large, absent, budget_read}
		add(&list, operation_seed_sequence(steps[:]), allocator)
	}
	// A word past the operations, with and without a table of details.
	{
		unknown := operation_sequence.Sequence_Step{operation = u32(max(operation.Operation)) + 1}
		no_table := unknown
		no_table.flags = {.No_Error_Details}
		steps := [?]operation_sequence.Sequence_Step{unknown, no_table}
		add(&list, operation_seed_sequence(steps[:]), allocator)
	}
	// A budget and a program from the budget of the runner, with their
	// kinds: the stop of the runner ends both, and the budget of the
	// sequence comes back whole.
	{
		budget := operation_sequence.Sequence_Step{operation = u32(operation.Operation.Budget_Create)}
		budget.arguments[0] = {source = .Budget}
		budget.arguments[1] = {source = .Value, value = 1}
		budget_state := operation_sequence.Sequence_Step{operation = u32(operation.Operation.Handle_State)}
		budget_state.arguments[0] = {source = .Result, step = 0}
		program := operation_sequence.Sequence_Step{operation = u32(operation.Operation.Program_Create)}
		program.arguments[0] = {source = .Budget}
		program.arguments[1] = {source = .Area_Address, area = 0}
		program.arguments[2] = {source = .Value, value = len(OPERATION_SEED_TEXT)}
		program_state := operation_sequence.Sequence_Step{operation = u32(operation.Operation.Handle_State)}
		program_state.arguments[0] = {source = .Result, step = 2}
		log := operation_sequence.Sequence_Step{operation = u32(operation.Operation.Log)}
		log.arguments[0] = {source = .Log}
		log.arguments[1] = {source = .Area_Address, area = 0}
		log.arguments[2] = {source = .Value, value = len(OPERATION_SEED_TEXT)}
		steps := [?]operation_sequence.Sequence_Step{budget, budget_state, program, program_state, log}
		add(&list, operation_seed_sequence(steps[:]), allocator)
	}
	return list[:]
}

// ---------------------------------------------------------------------
// The mailbox through the memory file of the machine.

Operation_Mailbox :: struct {
	file:       ^os.File,
	address:    i64, // The physical address of the mailbox: its offset in the file.
	executions: u64, // The executions that the service counted when the tool last read it.
	written:    u64, // The sequences that the tool wrote.
}

// operation_mailbox_open opens the memory file and checks the mailbox that
// the line of the log names: inside the memory, with its magic and its
// format.
operation_mailbox_open :: proc(path: string, address: i64) -> (mailbox: Operation_Mailbox, problem: string) {
	memory_bytes := i64(MACHINE_MEMORY_MIB) * 1024 * 1024
	if address <= 0 || address % i64(operation.PAGE_SIZE) != 0 || address > memory_bytes - i64(operation_sequence.MAILBOX_PAGES * operation.PAGE_SIZE) {
		return {}, fmt.tprintf("the mailbox at %d is not a page of the memory of the machine", address)
	}
	file, error := os.open(path, {.Read, .Write})
	if error != nil {
		return {}, fmt.tprintf("cannot open %s: %v", path, error)
	}
	mailbox = {file = file, address = address}
	header: operation_sequence.Mailbox_Header
	if !operation_mailbox_read(&mailbox, 0, ([^]u8)(&header)[:size_of(header)]) {
		os.close(file)
		return {}, "cannot read the mailbox"
	}
	if header.magic != operation_sequence.MAILBOX_MAGIC || header.format != operation_sequence.MAILBOX_FORMAT {
		os.close(file)
		return {}, fmt.tprintf("the mailbox at %d has the magic %x and the format %d", address, header.magic, header.format)
	}
	mailbox.executions = header.executions
	mailbox.written = header.sequences_written
	if mailbox.executions != mailbox.written {
		os.close(file)
		return {}, fmt.tprintf("the mailbox counts %d sequences written and %d executions", mailbox.written, mailbox.executions)
	}
	return mailbox, ""
}

operation_mailbox_read :: proc(mailbox: ^Operation_Mailbox, offset: int, into: []u8) -> bool {
	count, error := os.read_at(mailbox.file, into, mailbox.address + i64(offset))
	return error == nil && count == len(into)
}

operation_mailbox_write :: proc(mailbox: ^Operation_Mailbox, offset: int, from: []u8) -> bool {
	count, error := os.write_at(mailbox.file, from, mailbox.address + i64(offset))
	return error == nil && count == len(from)
}

operation_mailbox_write_word :: proc(mailbox: ^Operation_Mailbox, offset: uintptr, value: u64) -> bool {
	value := value
	return operation_mailbox_write(mailbox, int(offset), ([^]u8)(&value)[:size_of(value)])
}

// operation_execute writes one sequence, waits until the service counts it,
// and reads the header and the results. The wait ends a hang only: a
// count that stays still for HANG_BOUND is a stall of the machine.
operation_execute :: proc(mailbox: ^Operation_Mailbox, bytes: []u8, header: ^operation_sequence.Mailbox_Header, results: ^operation_sequence.Runner_Results) -> (problem: string) {
	_, _, problem = operation_execute_watched(mailbox, bytes, header, results, nil)
	return problem
}

// How the wait for one execution ended.
Operation_Wait_End :: enum u8 {
	Counted,        // The service counted the sequence: the header and the results are read.
	Machine_Ended,  // QEMU ended before the service counted the sequence.
	Stalled,        // The count of executions stayed still for HANG_BOUND.
	Mailbox_Broken, // The mailbox counts what the tool did not write: the machine wrote it.
	Tool_Error,     // The tool cannot read or write the memory file, or its sequence is larger than its place: never a fault of the machine.
}

// operation_execute_watched is operation_execute that also watches QEMU,
// when process is not nil: a machine that stopped ends the wait at once,
// not at the hang bound, with the state of its end.
operation_execute_watched :: proc(mailbox: ^Operation_Mailbox, bytes: []u8, header: ^operation_sequence.Mailbox_Header, results: ^operation_sequence.Runner_Results, process: ^os.Process) -> (end: Operation_Wait_End, ended: os.Process_State, problem: string) {
	if len(bytes) > operation_sequence.SEQUENCE_BYTES_MOST {
		return .Tool_Error, {}, "the sequence is larger than its place in the mailbox"
	}
	if !operation_mailbox_write(mailbox, operation_sequence.MAILBOX_SEQUENCE_OFFSET, bytes) || !operation_mailbox_write_word(mailbox, offset_of(operation_sequence.Mailbox_Header, sequence_bytes), u64(len(bytes))) {
		return .Tool_Error, {}, "cannot write the sequence in the mailbox"
	}
	// The count last: the service reads the sequence only after it.
	mailbox.written += 1
	if !operation_mailbox_write_word(mailbox, offset_of(operation_sequence.Mailbox_Header, sequences_written), mailbox.written) {
		return .Tool_Error, {}, "cannot write the count of the sequences"
	}
	started := time.now()
	for {
		if !operation_mailbox_read(mailbox, 0, ([^]u8)(header)[:size_of(header^)]) {
			return .Tool_Error, {}, "cannot read the mailbox"
		}
		if header.executions == mailbox.written {
			break
		}
		if header.executions != mailbox.executions {
			return .Mailbox_Broken, {}, fmt.tprintf("the mailbox counts %d executions after %d, and the tool wrote %d sequences", header.executions, mailbox.executions, mailbox.written)
		}
		if process != nil {
			// A wait of 0 does not block: Timeout says that QEMU runs.
			if state, wait_error := os.process_wait(process^, 0); wait_error == nil && state.exited {
				return .Machine_Ended, state, fmt.tprintf("QEMU ended with the status %d before the service counted the sequence", state.exit_code)
			}
		}
		if time.since(started) > HANG_BOUND {
			return .Stalled, {}, fmt.tprintf("a stall: the service took no sequence within %v; the runner had started its step %d", HANG_BOUND, operation_runner_step_started(mailbox))
		}
		time.sleep(CONDITION_POLL_PERIOD)
	}
	mailbox.executions = header.executions
	if !operation_mailbox_read(mailbox, operation_sequence.MAILBOX_RESULTS_OFFSET, ([^]u8)(results)[:size_of(results^)]) {
		return .Tool_Error, {}, "cannot read the results"
	}
	return .Counted, {}, ""
}

operation_runner_step_started :: proc(mailbox: ^Operation_Mailbox) -> u64 {
	results: operation_sequence.Runner_Results
	_ = operation_mailbox_read(mailbox, operation_sequence.MAILBOX_RESULTS_OFFSET, ([^]u8)(&results)[:size_of(results)])
	return results.step_started
}

// ---------------------------------------------------------------------
// The step of a scenario, the test part and the replay.

// operation_sequences_step runs the seed sequences, or the one sequence of
// the file `replay`, through the mailbox, and checks each oracle.
operation_sequences_step :: proc(machine: ^Machine, index: int, replay: string) -> bool {
	if machine.memory_file == "" {
		fmt.eprintfln("modustool: test failed: step %d: the machine has no memory file", index + 1)
		return false
	}
	address, found := number_after(log_read(machine), OPERATION_MAILBOX_LINE)
	if !found {
		fmt.eprintfln("modustool: test failed: step %d: the log has no line \"%s\"", index + 1, OPERATION_MAILBOX_LINE)
		return false
	}
	grammar, grammar_ok := operation_grammar_read()
	if !grammar_ok {
		return false
	}
	mailbox, problem := operation_mailbox_open(machine.memory_file, address)
	if problem != "" {
		fmt.eprintfln("modustool: test failed: step %d: %s", index + 1, problem)
		return false
	}
	defer os.close(mailbox.file)
	inputs: [][]u8
	regressions: []Operation_Regression_Input
	if replay == "" {
		inputs = operation_seed_sequences(context.temp_allocator)
		// Each regression input of the corpus, after the seeds. A file
		// that the reader refuses fails the step: no input stays unrun.
		problems: []string
		regressions, problems = operation_regression_inputs_read(OPERATION_REGRESSION_FOLDER, context.temp_allocator)
		for problem in problems {
			fmt.eprintfln("modustool: test failed: step %d: %s", index + 1, problem)
		}
		if len(problems) > 0 {
			return false
		}
	} else {
		bytes, read := read_file(replay)
		if !read {
			return false
		}
		single := make([][]u8, 1, context.temp_allocator)
		single[0] = bytes
		inputs = single
	}
	sequence := new(operation_sequence.Sequence, context.temp_allocator)
	header := new(operation_sequence.Mailbox_Header, context.temp_allocator)
	results := new(operation_sequence.Runner_Results, context.temp_allocator)
	steps, findings_total := 0, 0
	run :: proc(mailbox: ^Operation_Mailbox, grammar: ^Operation_Grammar, input: []u8, name: string, index: int, sequence: ^operation_sequence.Sequence, header: ^operation_sequence.Mailbox_Header, results: ^operation_sequence.Runner_Results, findings_total: ^int) -> bool {
		if refusal := operation_sequence.check(input, sequence); refusal.problem != .None {
			fmt.eprintfln("modustool: test failed: step %d: the sequence %s is refused by check: %v", index + 1, name, refusal)
			return false
		}
		if failure := operation_execute(mailbox, input, header, results); failure != "" {
			fmt.eprintfln("modustool: test failed: step %d: the sequence %s: %s", index + 1, name, failure)
			return false
		}
		for finding in operation_findings(sequence, header, results, grammar) {
			fmt.eprintfln("modustool: test failed: step %d: the sequence %s, step %d: %v: %s", index + 1, name, finding.step, finding.oracle, finding.text)
			findings_total^ += 1
		}
		return true
	}
	for input, number in inputs {
		run(&mailbox, &grammar, input, fmt.tprintf("%d", number), index, sequence, header, results, &findings_total) or_return
		steps += int(results.steps_run)
	}
	expected_steps := 0
	for regression in regressions {
		for input, place in regression.regression.life {
			run(&mailbox, &grammar, input, fmt.tprintf("%d of the regression input %s", place, regression.name), index, sequence, header, results, &findings_total) or_return
			steps += int(results.steps_run)
		}
		if problem := operation_step_expectations_problem(regression.regression.expectations, results); problem != "" {
			fmt.eprintfln("modustool: test failed: step %d: the regression input %s (%s): %s", index + 1, regression.name, regression.regression.signature, problem)
			findings_total += 1
		}
		expected_steps += len(regression.regression.expectations)
	}
	if findings_total > 0 {
		return false
	}
	test_passed_print("the machine ran %d operation sequences and %d regression inputs, %d steps, through the mailbox: each status is in the reference of its operation, each table of error details agrees with the forms, each budget came back whole, and the %d steps of the last sequences of the regression inputs got their answers", len(inputs), len(regressions), steps, expected_steps)
	return true
}

scenario_operation_sequences := [?]Step {
	{kind = .Wait, text = "boot program: ok"},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "root: started operation_fuzzing with "},
	{kind = .Wait, text = OPERATION_MAILBOX_LINE},
	{kind = .Operation_Sequences},
	{kind = .Quit},
}

// The tool ends QEMU: status 0. The memory file goes after the machine.
operation_sequences_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	defer {
		_ = os.remove(OPERATION_SEQUENCES_MEMORY_FILE)
	}
	return machine_test(part, scenario_operation_sequences[:], {volume = BOOT_VOLUME_OPERATION_SEQUENCES, output = TEST_OUTPUT_OPERATION_SEQUENCES, exit_status = 0, memory_file = OPERATION_SEQUENCES_MEMORY_FILE})
}

// operation_sequences_replay is `fuzz replay operations <file>`: one
// sequence on a new machine of the kernel that ships, with every oracle.
operation_sequences_replay :: proc(path: string) -> int {
	bytes, read := read_file(path)
	if !read {
		return EXIT_FAILURE
	}
	sequence: operation_sequence.Sequence
	if refusal := operation_sequence.check(bytes, &sequence); refusal.problem != .None {
		fmt.eprintfln("modustool: %s is not an operation sequence: %v", path, refusal)
		return EXIT_USAGE
	}
	if code := build_system(boot_volumes_of_command(OPERATION_REPLAY_COMMAND)); code != 0 {
		return code
	}
	steps := scenario_operation_sequences
	for &step in steps {
		if step.kind == .Operation_Sequences {
			step.text = path
		}
	}
	part := test_part_run_make(OPERATION_REPLAY_COMMAND)
	defer test_part_run_free(&part)
	defer {
		_ = os.remove(OPERATION_REPLAY_MEMORY_FILE)
	}
	if !test_part_run_start(&part) || !machine_test(&part, steps[:], {volume = BOOT_VOLUME_OPERATION_SEQUENCES, output = TEST_OUTPUT_OPERATION_REPLAY, exit_status = 0, memory_file = OPERATION_REPLAY_MEMORY_FILE}) {
		fmt.eprintfln("modustool: fuzz replay operations: %s breaks an oracle on the kernel that ships, or the machine failed", path)
		return EXIT_FAILURE
	}
	fmt.printfln("modustool: fuzz replay operations: %s breaks no oracle on the kernel that ships", path)
	return 0
}
