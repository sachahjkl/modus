package machine

import "core:testing"
import "modus:contract/errors"
import "modus:contract/operation"
import "modus:contract/operation_sequence"
import "modustool:foundation"
import "modustool:build"
import "modustool:fuzz"

// The list "**Statuses**" of a comment: a comment with no list, a list with
// no line, a name that is no status, the status Ok, a code mark with no end
// and a line that names no status are refused; then a list of two lines
// gives each status that it names.
@(test)
the_statuses_of_a_comment_are_read_or_refused :: proc(t: ^testing.T) {
	_, no_list := operation_statuses_of_comment("(budget) -> memory handle.\n**Arguments**\n")
	testing.expect(t, no_list != "", "a comment with no list is taken")
	_, no_line := operation_statuses_of_comment("**Statuses**\n\nsome text\n")
	testing.expect(t, no_line != "", "a list with no line is taken")
	_, unknown := operation_statuses_of_comment("**Statuses**\n- `Bad_Thing`: a status that does not exist.\n")
	testing.expect(t, unknown != "", "a name that is no status is taken")
	_, success := operation_statuses_of_comment("**Statuses**\n- `Ok`: no refusal.\n")
	testing.expect(t, success != "", "Ok is taken as a refusal")
	_, unended := operation_statuses_of_comment("**Statuses**\n- `Bad_Handle: the mark has no end.\n")
	testing.expect(t, unended != "", "a code mark with no end is taken")
	statuses, problem := operation_statuses_of_comment("**Statuses**\n\n- `Bad_Handle`, `No_Right`: `memory` is not a memory handle.\n  It goes on with `Bad_State` after the colon.\n- `No_Budget`: the budget cannot pay.\n**Example**\n- `No_Slot`: after the list.\n")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, statuses, bit_set[operation.Status]{.Bad_Handle, .No_Right, .No_Budget})
	// A line of an item that goes on with a bold word at its start is no
	// heading: the items after it are in the list. Thread_Control has such
	// a line ("**Counters** gives"), and its Bad_State was lost.
	statuses, problem = operation_statuses_of_comment("**Statuses**\n\n- `Bad_Handle`, `No_Right`: the handle with no\n  **Counters** gives `No_Right`.\n- `Bad_State`: no live thread.\n**Example**\n- `No_Slot`: after the list.\n")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, statuses, bit_set[operation.Status]{.Bad_Handle, .No_Right, .Bad_State})
}

// The reference of the contract lists statuses for each operation, and
// the list of Memory_Create is the one of its comment.
@(test)
the_reference_lists_the_statuses_of_each_operation :: proc(t: ^testing.T) {
	_, no_enumeration := operation_statuses_read("package operation\n")
	testing.expect(t, no_enumeration != "", "a reference with no enumeration Operation is taken")
	statuses, problem := operation_statuses_read(fuzz.fuzz_operation_reference)
	testing.expect_value(t, problem, "")
	for chosen in operation.Operation {
		if chosen != .None {
			testing.expectf(t, statuses[chosen] != {}, "%s lists no status", operation.OPERATIONS[chosen].name)
		}
	}
	testing.expect_value(t, statuses[.Memory_Create], bit_set[operation.Status]{.Bad_Handle, .No_Right, .Bad_Operation, .No_Budget, .No_Slot, .No_Memory})
	// The statuses after the line "**Counters** gives" of its comment.
	testing.expect_value(t, statuses[.Thread_Control], bit_set[operation.Status]{.Bad_Operation, .Bad_Handle, .No_Right, .Bad_State, .Bad_Address})
}

// Each seed is a sequence that check accepts: one for each operation, and
// the five cases of the seeds. Each expectation names a seed and one of its
// steps, and its step is a refusal.
@(test)
each_seed_is_a_sequence :: proc(t: ^testing.T) {
	expectations := make([dynamic]Operation_Seed_Expectation, context.temp_allocator)
	seeds := operation_seed_sequences(context.temp_allocator, &expectations)
	testing.expect_value(t, len(seeds), len(operation.Operation) - 1 + 5)
	sequences := make([]operation_sequence.Sequence, len(seeds), context.temp_allocator)
	for seed, index in seeds {
		refusal := operation_sequence.check(seed, &sequences[index])
		testing.expectf(t, refusal.problem == .None, "the seed %d is refused: %v", index, refusal)
	}
	// The variants of the findings that the corpus does not hold: the word
	// 0 and the word past the operations, with and without a table (four
	// steps), the commit with its two details, and the decommit.
	testing.expect_value(t, len(expectations), 7)
	for expected in expectations {
		testing.expectf(t, expected.sequence >= 0 && expected.sequence < len(seeds), "an expectation names the seed %d", expected.sequence)
		if expected.sequence < 0 || expected.sequence >= len(seeds) {
			continue
		}
		testing.expectf(t, expected.step >= 0 && expected.step < sequences[expected.sequence].step_count, "an expectation names the step %d of the seed %d", expected.step, expected.sequence)
		testing.expectf(t, expected.status != .Ok && expected.record_kind != .None, "the expectation of the step %d of the seed %d is no refusal", expected.step, expected.sequence)
	}
}

// The check of an expectation refuses a step that did not run, another
// status, another kind or argument of the record, a table with no detail of
// the expected kind and argument, and a detail of an argument that must
// have none; then it takes the answer.
@(test)
the_expectation_of_a_seed_step_is_checked :: proc(t: ^testing.T) {
	expected := Operation_Seed_Expectation{step = 1, status = .Bad_Handle, record_kind = .Handle_Absent, record_argument = 1, detail_kind = .Too_Long, detail_argument = 4, absent_detail_argument = 2}
	results: operation_sequence.Runner_Results
	results.steps_run = 1
	testing.expect(t, operation_seed_expectation_problem(expected, &results) != "", "a step that did not run is taken")
	negative := expected
	negative.step = -1
	testing.expect(t, operation_seed_expectation_problem(negative, &results) != "", "a negative step is taken")
	results.steps_run = 2
	record := errors.Error_Record{kind = i64(errors.Kind.Handle_Absent), operation = i64(operation.Operation.Memory_Commit), argument = 1}
	result := &results.results[1]
	result.status = u64(operation.Status.Bad_Operation)
	result.values = transmute([operation_sequence.ARGUMENTS]u64)record
	testing.expect(t, operation_seed_expectation_problem(expected, &results) != "", "another status is taken")
	result.status = u64(operation.Status.Bad_Handle)
	wrong := record
	wrong.argument = 2
	result.values = transmute([operation_sequence.ARGUMENTS]u64)wrong
	testing.expect(t, operation_seed_expectation_problem(expected, &results) != "", "a record of another argument is taken")
	wrong = record
	wrong.kind = i64(errors.Kind.Refused)
	result.values = transmute([operation_sequence.ARGUMENTS]u64)wrong
	testing.expect(t, operation_seed_expectation_problem(expected, &results) != "", "a record of another kind is taken")
	result.values = transmute([operation_sequence.ARGUMENTS]u64)record
	result.details[0] = record
	result.details_count = 1
	testing.expect(t, operation_seed_expectation_problem(expected, &results) != "", "a table with no detail of the count is taken")
	// A detail past the count is no detail.
	result.details[1] = {kind = i64(errors.Kind.Too_Long), argument = 4}
	testing.expect(t, operation_seed_expectation_problem(expected, &results) != "", "a detail past the count is taken")
	// A detail of the budget, which the step must not have.
	result.details[2] = {kind = i64(errors.Kind.Handle_Absent), argument = 2}
	result.details_count = 3
	testing.expect(t, operation_seed_expectation_problem(expected, &results) != "", "a detail of an argument that must have none is taken")
	// A count past the most reads only the records of the table.
	result.details[2] = {}
	result.details_count = max(u64)
	testing.expect_value(t, operation_seed_expectation_problem(expected, &results), "")
	// The last case: the record, then the detail of the count.
	result.details_count = 2
	testing.expect_value(t, operation_seed_expectation_problem(expected, &results), "")
}

// A sequence of one step of an operation, for the oracles.
@(private = "file")
oracle_sequence :: proc(steps: ..operation_sequence.Sequence_Step) -> operation_sequence.Sequence {
	sequence: operation_sequence.Sequence
	sequence.area_count = 1
	sequence.areas[0] = {pages = 1}
	for item, index in steps {
		sequence.steps[index] = item
	}
	sequence.step_count = len(steps)
	return sequence
}

@(private = "file")
oracle_header :: proc() -> operation_sequence.Mailbox_Header {
	header: operation_sequence.Mailbox_Header
	// A runner that a step stopped: a stop of itself with no end written,
	// which agrees with results whose end word is 0. A test of the outcome
	// Ran writes the end Ran too.
	header.outcome = u64(operation_sequence.Execution_Outcome.Stopped)
	header.stop_cause = u64(operation.Stop_Cause.Itself)
	header.stop_outcome = u64(operation.Stop_Outcome.Done)
	header.budget_before = {pages = 100, processes = 2, threads = 3}
	header.budget_after = header.budget_before
	return header
}

@(private = "file")
oracle_has :: proc(findings: []Operation_Finding, oracle: Operation_Oracle) -> bool {
	for finding in findings {
		if finding.oracle == oracle {
			return true
		}
	}
	return false
}

// A step of Memory_Create with a table: the budget, one page and no flag.
@(private = "file")
memory_create_step :: proc(pages: u64, flags: u64) -> operation_sequence.Sequence_Step {
	item := operation_sequence.Sequence_Step{operation = u32(operation.Operation.Memory_Create)}
	item.arguments[0] = {source = .Budget}
	item.arguments[1] = {source = .Value, value = pages}
	item.arguments[2] = {source = .Value, value = flags}
	return item
}

@(private = "file")
memory_create_result :: proc(results: ^operation_sequence.Runner_Results, step: int, pages: u64, flags: u64, status: operation.Status) -> ^operation_sequence.Step_Result {
	result := &results.results[step]
	result.words = {0 = 11, 1 = pages, 2 = flags}
	result.kind = u64(operation.Operation.Memory_Create) | u64(operation.COMMAND_NAMES_ERROR_DETAILS)
	result.status = u64(status)
	for &detail in result.details {
		detail = operation_sequence.details_pattern()
	}
	return result
}

// The oracles of the outcome and of the budget: an outcome word that names
// no outcome, each outcome that is a fault, a count of steps past the
// sequence, and a budget that does not come back.
@(test)
the_oracles_of_the_outcome_and_of_the_budget :: proc(t: ^testing.T) {
	grammar, ok := operation_grammar_read()
	testing.expect(t, ok, "the grammar is not read")
	sequence := oracle_sequence()
	results: operation_sequence.Runner_Results
	header := oracle_header()
	header.outcome = u64(max(operation_sequence.Execution_Outcome)) + 1
	testing.expect(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Outcome), "an outcome word that names no outcome is taken")
	for outcome in ([]operation_sequence.Execution_Outcome{.None, .Refused, .Not_Started, .Hung}) {
		header.outcome = u64(outcome)
		testing.expectf(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Outcome), "the outcome %v is taken", outcome)
	}
	header = oracle_header()
	header.outcome = u64(operation_sequence.Execution_Outcome.Stopped)
	for end in ([]operation_sequence.Runner_End{.Sequence_Refused, .Batch_Refused}) {
		results.end = u64(end)
		testing.expectf(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Outcome), "a runner that ended with %v is taken", end)
	}
	// A word of the memory of the machine that names no end, no cause or no
	// outcome is a finding, never an end, a cause or an outcome.
	for word in ([]u64{u64(max(operation_sequence.Runner_End)) + 1, max(u64)}) {
		results.end = word
		testing.expectf(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Outcome), "the end word %d is taken", word)
	}
	results.end = u64(operation_sequence.Runner_End.Ran)
	for word in ([]u64{u64(max(operation.Stop_Cause)) + 1, max(u64)}) {
		header.stop_cause = word
		testing.expectf(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Outcome), "the stop cause word %d is taken", word)
	}
	header = oracle_header()
	for word in ([]u64{u64(operation.Stop_Outcome.None), u64(max(operation.Stop_Outcome)) + 1, max(u64)}) {
		header.stop_outcome = word
		testing.expectf(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Outcome), "the stop outcome word %d with the cause Itself is taken", word)
	}
	// An outcome with a cause other than Itself: a holder cannot say what
	// the work of the runner gave.
	header = oracle_header()
	header.stop_cause = u64(operation.Stop_Cause.Holder)
	testing.expect(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Outcome), "a stop outcome with the cause Holder is taken")
	results.end = 0
	header = oracle_header()
	results.steps_run = 1
	testing.expect(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Outcome), "more steps than the sequence are taken")
	results.steps_run = 0
	header.budget_after.pages -= 1
	testing.expect(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Budget_Not_Back), "a page that did not come back is taken")
	header.budget_after = header.budget_before
	header.budget_after.processes += 1
	testing.expect(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Budget_Not_Back), "a process slot more after the runner is taken")
	header = oracle_header()
	header.outcome = u64(operation_sequence.Execution_Outcome.Stopped)
	testing.expect_value(t, len(operation_findings(&sequence, &header, &results, &grammar)), 0)
	header.outcome = u64(operation_sequence.Execution_Outcome.Ran)
	results.end = u64(operation_sequence.Runner_End.Ran)
	testing.expect_value(t, len(operation_findings(&sequence, &header, &results, &grammar)), 0)
	results.end = 0
}

// The outcome, the stop cause, the stop outcome and the end tell one
// story, or the tool takes the execution: each group that cannot come from
// the runner and the service is a finding, and the groups that can are the
// last cases.
@(test)
the_words_of_a_stop_tell_one_story :: proc(t: ^testing.T) {
	grammar, ok := operation_grammar_read()
	testing.expect(t, ok, "the grammar is not read")
	sequence := oracle_sequence()
	results: operation_sequence.Runner_Results
	Group :: struct {
		outcome:      operation_sequence.Execution_Outcome,
		cause:        operation.Stop_Cause,
		stop_outcome: operation.Stop_Outcome,
		end:          operation_sequence.Runner_End,
	}
	refused := [?]Group {
		{.Ran, .Holder, .None, .Ran}, // Ran with a cause other than Itself.
		{.Ran, .Fault, .None, .Ran},
		{.Ran, .Itself, .Failed, .Ran}, // Ran with a stop that says the work failed.
		{.Ran, .Itself, .Done, .None}, // Ran with no end written.
		{.Stopped, .None, .None, .None}, // Stopped with no cause.
		{.Ran, .None, .None, .Ran},
		{.Stopped, .Holder, .None, .Ran}, // The end Ran with a stop by a holder.
		{.Stopped, .Fault, .None, .Ran},
		{.Stopped, .Itself, .Refused, .Ran}, // The end Ran with an outcome other than Done.
		{.Stopped, .Holder, .Done, .None}, // An outcome from a holder.
		{.Stopped, .Itself, .None, .None}, // A stop of itself with no outcome.
	}
	for group in refused {
		header := oracle_header()
		header.outcome = u64(group.outcome)
		header.stop_cause = u64(group.cause)
		header.stop_outcome = u64(group.stop_outcome)
		results.end = u64(group.end)
		testing.expectf(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Outcome), "the group %v is taken", group)
	}
	accepted := [?]Group {
		{.Ran, .Itself, .Done, .Ran},
		{.Stopped, .Itself, .Done, .None}, // A step stopped the runner, with any outcome that it named.
		{.Stopped, .Itself, .Stopped_On_Request, .None},
		{.Stopped, .Holder, .None, .None},
		{.Stopped, .Fault, .None, .None},
	}
	for group in accepted {
		header := oracle_header()
		header.outcome = u64(group.outcome)
		header.stop_cause = u64(group.cause)
		header.stop_outcome = u64(group.stop_outcome)
		results.end = u64(group.end)
		testing.expectf(t, !oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Outcome), "the group %v is refused", group)
		testing.expectf(t, operation_stop_pair_problem(group.outcome, group.stop_outcome, group.end) == "", "the group %v has a problem", group)
	}
	results.end = 0
}

// A mailbox of another format, or with another magic, is refused: its
// fields are at other places or mean other things. The format of this tool
// is the last case.
@(test)
a_mailbox_of_another_format_is_refused :: proc(t: ^testing.T) {
	header := operation_sequence.Mailbox_Header{magic = operation_sequence.MAILBOX_MAGIC}
	for format in ([]u64{0, 1, operation_sequence.MAILBOX_FORMAT - 1, operation_sequence.MAILBOX_FORMAT + 1, max(u64)}) {
		header.format = format
		testing.expectf(t, !operation_mailbox_header_known(&header), "the format %d is refused", format)
	}
	header.format = operation_sequence.MAILBOX_FORMAT
	header.magic = operation_sequence.MAILBOX_MAGIC + 1
	testing.expect(t, !operation_mailbox_header_known(&header), "another magic is refused")
	header.magic = 0
	testing.expect(t, !operation_mailbox_header_known(&header), "the magic 0 is refused")
	header.magic = operation_sequence.MAILBOX_MAGIC
	testing.expect(t, operation_mailbox_header_known(&header), "the magic and the format of this tool are known")
}

// The oracles of a status: a word that names no status, an unknown
// operation that is not refused with Bad_Operation, a status that the
// reference does not list, and a value that the form refuses with Ok.
@(test)
the_oracles_of_a_status :: proc(t: ^testing.T) {
	grammar, _ := operation_grammar_read()
	header := oracle_header()
	results: operation_sequence.Runner_Results
	results.steps_run = 1

	sequence := oracle_sequence(memory_create_step(1, 0))
	result := memory_create_result(&results, 0, 1, 0, .Ok)
	result.kind = u64(operation.Operation.Memory_Create)
	result.status = u64(max(operation.Status)) + 1
	testing.expect(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Status_Word), "a status word that names no status is taken")

	unknown := oracle_sequence(operation_sequence.Sequence_Step{operation = u32(max(operation.Operation)) + 1})
	results.results[0] = {status = u64(operation.Status.Ok)}
	testing.expect(t, oracle_has(operation_findings(&unknown, &header, &results, &grammar), .Unknown_Operation), "an unknown operation that gives Ok is taken")
	none := oracle_sequence(operation_sequence.Sequence_Step{operation = u32(operation.Operation.None)})
	results.results[0] = {status = u64(operation.Status.Bad_Handle)}
	testing.expect(t, oracle_has(operation_findings(&none, &header, &results, &grammar), .Unknown_Operation), "the operation None refused with Bad_Handle is taken")
	// The word 0 with a table: Bad_Operation with another record, with a
	// record of another value or limit, and with a table that the kernel
	// wrote, are each taken.
	none_kind := u64(operation.COMMAND_NAMES_ERROR_DETAILS)
	unknown_record := errors.Error_Record{kind = i64(errors.Kind.Unknown_Operation), operation = i64(none_kind), value = i64(none_kind), limit = i64(max(operation.Operation))}
	unknown_result :: proc(results: ^operation_sequence.Runner_Results, kind: u64, record: errors.Error_Record) -> ^operation_sequence.Step_Result {
		result := &results.results[0]
		result^ = {kind = kind, status = u64(operation.Status.Bad_Operation), values = transmute([operation_sequence.ARGUMENTS]u64)record}
		for &detail in result.details {
			detail = operation_sequence.details_pattern()
		}
		return result
	}
	wrong_record := unknown_record
	wrong_record.kind = i64(errors.Kind.Refused)
	unknown_result(&results, none_kind, wrong_record)
	testing.expect(t, oracle_has(operation_findings(&none, &header, &results, &grammar), .Unknown_Operation), "the word 0 with the record Refused is taken")
	wrong_record = unknown_record
	wrong_record.value = 0 // The word without the bit of the table that the runner sent.
	unknown_result(&results, none_kind, wrong_record)
	testing.expect(t, oracle_has(operation_findings(&none, &header, &results, &grammar), .Unknown_Operation), "a record of another kind than the one sent is taken")
	wrong_record = unknown_record
	wrong_record.limit += 1
	unknown_result(&results, none_kind, wrong_record)
	testing.expect(t, oracle_has(operation_findings(&none, &header, &results, &grammar), .Unknown_Operation), "a record with another limit is taken")
	written := unknown_result(&results, none_kind, unknown_record)
	written.details_count = 1
	testing.expect(t, oracle_has(operation_findings(&none, &header, &results, &grammar), .Unknown_Operation), "a table that the kernel counted is taken")
	written = unknown_result(&results, none_kind, unknown_record)
	written.details[0] = unknown_record
	testing.expect(t, oracle_has(operation_findings(&none, &header, &results, &grammar), .Unknown_Operation), "a table that the kernel wrote is taken")
	// The right answers, with a table and with none.
	unknown_result(&results, none_kind, unknown_record)
	testing.expect_value(t, len(operation_findings(&none, &header, &results, &grammar)), 0)
	plain_record := unknown_record
	plain_record.operation, plain_record.value = 0, 0
	unknown_result(&results, 0, plain_record)
	testing.expect_value(t, len(operation_findings(&none, &header, &results, &grammar)), 0)

	result = memory_create_result(&results, 0, 1, 0, .Bad_State)
	result.kind = u64(operation.Operation.Memory_Create)
	testing.expect(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Status_Not_Listed), "a status that Memory_Create does not list is taken")

	too_many := u64(operation.MEMORY_PAGE_LIMIT + 1)
	large := oracle_sequence(memory_create_step(too_many, 0))
	result = memory_create_result(&results, 0, too_many, 0, .Ok)
	result.kind = u64(operation.Operation.Memory_Create)
	testing.expect(t, oracle_has(operation_findings(&large, &header, &results, &grammar), .Form_Refusal_Accepted), "a count past its limit with Ok is taken")

	// The last case: a refusal that the reference lists, for a value that
	// the form refuses, and no table.
	result = memory_create_result(&results, 0, too_many, 0, .Bad_Operation)
	result.kind = u64(operation.Operation.Memory_Create)
	testing.expect_value(t, len(operation_findings(&large, &header, &results, &grammar)), 0)
}

// The oracles of a table of error details: a table that a success
// changed, a refusal with no detail or past the most, a first detail that
// is not the record of the completion, a detail of an argument that the
// operation does not read, and a refused value with no detail.
@(test)
the_oracles_of_a_table_of_error_details :: proc(t: ^testing.T) {
	grammar, _ := operation_grammar_read()
	header := oracle_header()
	results: operation_sequence.Runner_Results
	results.steps_run = 1
	unknown_flag := u64(1) << 40
	sequence := oracle_sequence(memory_create_step(1, unknown_flag))

	result := memory_create_result(&results, 0, 1, 0, .Ok)
	result.details_count = 1
	testing.expect(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Details_Changed), "a success that counts a detail is taken")
	result = memory_create_result(&results, 0, 1, 0, .Ok)
	result.details[operation.ERROR_DETAILS_MOST - 1] = {}
	testing.expect(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Details_Changed), "a success that wrote a record is taken")

	record := errors.Error_Record{kind = i64(errors.Kind.Bad_Flags), operation = i64(operation.Operation.Memory_Create), argument = 3, value = i64(unknown_flag), limit = i64(operation.MEMORY_FLAGS_KNOWN)}
	refused :: proc(results: ^operation_sequence.Runner_Results, record: errors.Error_Record, flags: u64) -> ^operation_sequence.Step_Result {
		result := memory_create_result(results, 0, 1, flags, .Bad_Operation)
		result.values = transmute([operation_sequence.ARGUMENTS]u64)record
		result.details[0] = record
		result.details_count = 1
		return result
	}
	result = refused(&results, record, unknown_flag)
	result.details_count = 0
	testing.expect(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Details_Count), "a refusal with no detail is taken")
	result.details_count = operation.ERROR_DETAILS_MOST + 1
	testing.expect(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Details_Count), "a refusal past the most details is taken")
	result.details_count = max(u64)
	testing.expect(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Details_Count), "the largest count is taken")

	result = refused(&results, record, unknown_flag)
	result.details[0].limit += 1
	testing.expect(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Details_First), "a first detail that is not the record is taken")

	result = refused(&results, record, unknown_flag)
	result.details_count = 2
	result.details[1] = {kind = i64(errors.Kind.Bad_Value), argument = operation_sequence.ARGUMENTS}
	testing.expect(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Details_Argument), "a detail of an argument that the operation does not read is taken")
	result.details[1].argument = 0
	testing.expect(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Details_Argument), "a detail of the call as a whole after the first is taken")

	// A handle that names nothing is the record; the unknown flag must
	// have its own detail.
	absent := errors.Error_Record{kind = i64(errors.Kind.Handle_Absent), operation = i64(operation.Operation.Memory_Create), argument = 1, value = 11}
	result = refused(&results, absent, unknown_flag)
	result.status = u64(operation.Status.Bad_Handle)
	testing.expect(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Details_Missing), "a refused flag with no detail is taken")

	// The last case: the record of the handle, then the detail of the flag.
	result.details_count = 2
	result.details[1] = record
	testing.expect_value(t, len(operation_findings(&sequence, &header, &results, &grammar)), 0)
}

// The planted steps: a handle of another kind than its reference, and a
// budget that a refusal changed. A success between two reads of the
// budget ends the comparison.
@(test)
the_oracles_of_the_planted_steps :: proc(t: ^testing.T) {
	grammar, _ := operation_grammar_read()
	header := oracle_header()
	results: operation_sequence.Runner_Results

	state := operation_sequence.Sequence_Step{operation = u32(operation.Operation.Handle_State)}
	state.arguments[0] = {source = .Result, step = 0}
	sequence := oracle_sequence(memory_create_step(1, 0), state)
	results.steps_run = 2
	created := memory_create_result(&results, 0, 1, 0, .Ok)
	created.values[0] = 0x10003
	results.results[1] = {status = u64(operation.Status.Ok), values = {0 = u64(operation.Object_Kind.Thread)}, words = {0 = 0x10003}}
	testing.expect(t, oracle_has(operation_findings(&sequence, &header, &results, &grammar), .Handle_Kind), "a memory handle of the kind Thread is taken")
	results.results[1].values[0] = u64(operation.Object_Kind.Memory)
	testing.expect_value(t, len(operation_findings(&sequence, &header, &results, &grammar)), 0)

	read := operation_sequence.Sequence_Step{operation = u32(operation.Operation.Budget_Read)}
	read.arguments[0] = {source = .Budget}
	refused_step := memory_create_step(operation.MEMORY_PAGE_LIMIT + 1, 0)
	budget_sequence := oracle_sequence(read, refused_step, read)
	results = {}
	results.steps_run = 3
	results.results[0] = {status = u64(operation.Status.Ok), values = {0 = 50, 1 = 2, 2 = 3}, words = {0 = 11}}
	refusal := memory_create_result(&results, 1, operation.MEMORY_PAGE_LIMIT + 1, 0, .Bad_Operation)
	refusal.kind = u64(operation.Operation.Memory_Create)
	results.results[2] = {status = u64(operation.Status.Ok), values = {0 = 49, 1 = 2, 2 = 3}, words = {0 = 11}}
	testing.expect(t, oracle_has(operation_findings(&budget_sequence, &header, &results, &grammar), .Refusal_Changed_Budget), "a page gone across a refusal is taken")

	// A success between the reads may spend the budget: no finding.
	success_sequence := oracle_sequence(read, memory_create_step(1, 0), read)
	success := memory_create_result(&results, 1, 1, 0, .Ok)
	success.kind = u64(operation.Operation.Memory_Create)
	testing.expect_value(t, len(operation_findings(&success_sequence, &header, &results, &grammar)), 0)
}

// The release refuses a boot image that holds a module that only the
// image of a test holds, and bytes that are not a boot image.
@(test)
a_release_refuses_the_modules_of_a_test_image :: proc(t: ^testing.T) {
	module_bytes := []u8{1, 2, 3}
	testing.expect(t, build.release_test_module_problem(module_bytes, "bytes") != "", "bytes that are no boot image are taken")
	for name in ([]string{foundation.OPERATION_FUZZING_MODULE, foundation.OPERATION_SEQUENCE_RUNNER_MODULE}) {
		files := []build.Image_File{{name = "root", file = module_bytes}, {name = name, file = module_bytes}}
		image := build.boot_image_encode(files, len(files))
		testing.expectf(t, build.release_test_module_problem(image, "an image") != "", "an image with %s is taken", name)
	}
	files := []build.Image_File{{name = "root", file = module_bytes}, {name = "input", file = module_bytes}}
	testing.expect_value(t, build.release_test_module_problem(build.boot_image_encode(files, len(files)), "an image"), "")
}

// The two modules of the operation sequences, shortage, and the two
// modules of the restarts of the rescue list are in no image but their
// own: the boot image of the build, and so a release, does not hold them.
@(test)
the_modules_of_the_operation_sequences_are_in_their_image_only :: proc(t: ^testing.T) {
	Only_In_Image :: struct {
		name:  string,
		image: string,
	}
	expected := [?]Only_In_Image {
		{foundation.OPERATION_FUZZING_MODULE, foundation.BOOT_IMAGE_OPERATION_SEQUENCES},
		{foundation.OPERATION_SEQUENCE_RUNNER_MODULE, foundation.BOOT_IMAGE_OPERATION_SEQUENCES},
		{"shortage", foundation.BOOT_IMAGE_SHORTAGE},
		{"stops_refused", foundation.BOOT_IMAGE_MISSING_CONSOLE},
		{"stops_failed", foundation.BOOT_IMAGE_MISSING_CONSOLE},
		{"audit_asker", foundation.BOOT_IMAGE_PLAN_AND_AUDIT},
		{"plan_applier", foundation.BOOT_IMAGE_PLAN_AND_AUDIT},
		{"settings_stand_in", foundation.BOOT_IMAGE_PLAN_AND_AUDIT},
	}
	found := 0
	for build in foundation.module_builds {
		if build.only_in_image == "" {
			continue
		}
		found += 1
		image, named := "", false
		for row in expected {
			if row.name == build.name {
				image, named = row.image, true
			}
		}
		testing.expectf(t, named, "%s is in one image only", build.name)
		testing.expect_value(t, build.only_in_image, image)
		testing.expect(t, !foundation.module_in_boot_image(build), "a module of one image is in the boot image")
		testing.expect(t, foundation.module_in_a_boot_image(build), "a module of one image is in no image")
	}
	testing.expect_value(t, found, len(expected))
}
