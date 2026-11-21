package operation_sequence

// The mailbox of the machine and the results of the runner
// (src/md/infrastructure/kernel_fuzzing.md, "The processes in the machine").
//
// The process `operation_fuzzing` makes the mailbox: one contiguous memory
// object, whose physical address it writes on the log. The tool reads and
// writes it through the memory file of the machine. The tool writes a
// sequence, then adds one to `sequences_written`; the service runs it, writes
// the results, then adds one to `executions`. Each side copies what the
// other side wrote, then checks it.
//
// The runner writes `Runner_Results` in a memory object that the service
// gave it; the service copies them into the mailbox after the runner
// stopped.

import "modus:contract/errors"
import "modus:contract/fixed_addresses"
import "modus:contract/operation"

MAILBOX_MAGIC :: u64(0x4C49_414D_5245_504F) // The bytes "OPERMAIL".
MAILBOX_FORMAT :: 3

// The process that runs each sequence, and the module of the boot image
// that holds it.
RUNNER_NAME :: "operation_sequence_runner"

// How the runner ended, which it writes in `Runner_Results.end` before it
// stops itself. A stop carries no result (src/md/api/process_stop.md): the
// runner stops with the outcome `Done` after `Ran`, `Refused` after
// `Sequence_Refused` and `Failed` after `Batch_Refused`, and the word here
// says which end. `None` with the stop cause Itself is not an end of the
// runner: a step stopped it, with any outcome that the step named.
Runner_End :: enum u64 {
	None             = 0, // The runner did not write its end: a step stopped it, or a fault.
	Ran              = 1, // It ran each step of its sequence.
	Sequence_Refused = 2, // Its copy of the sequence was refused: a fault of the service or of the runner, never the answer of a step.
	Batch_Refused    = 3, // The system library refused a batch: a fault of the runner, never the answer of a step.
}

// The line that the service writes on the log after each sequence, before
// it adds one to `executions`: "operation_fuzzing: sequence <number>
// ended", with the number of executions after this one. The line passes
// through the same queue of the log as each line of the kernel during the
// sequence, so it reaches the serial port after them: the tool names the
// sequence of a line of the kernel by the end line that comes after it.
SEQUENCE_END_LINE_START :: "operation_fuzzing: sequence "
SEQUENCE_END_LINE_END :: " ended"

// What happened to the last sequence that the service took.
Execution_Outcome :: enum u64 {
	None        = 0, // No sequence ran yet.
	Ran         = 1, // The runner ran each step, wrote the end `Ran`, then stopped itself.
	Refused     = 2, // `check` refused the sequence: the refusal fields say why. Nothing ran.
	Stopped     = 3, // The runner stopped before its end: a step stopped it, or a fault. `step_started` names the step.
	Not_Started = 4, // The runner did not start: `start_status` holds the status.
	Hung        = 5, // The runner did not stop within the hang bound: the service stopped it.
}

// The amounts of the budget of a sequence that the budget oracle compares.
// The log records are not compared: their amount returns each second.
Mailbox_Amounts :: struct {
	pages:    u64,
	processes: u64,
	threads:  u64,
}

// The first page of the mailbox.
Mailbox_Header :: struct {
	magic:             u64, // `MAILBOX_MAGIC`, written by the service when the mailbox is ready.
	format:            u64, // `MAILBOX_FORMAT`.
	sequences_written: u64, // The tool: one more for each sequence that it wrote at `MAILBOX_SEQUENCE_OFFSET`.
	sequence_bytes:    u64, // The tool: the bytes of that sequence.
	executions:        u64, // The service: one more for each sequence that it took, after it wrote each field below.
	outcome:           u64, // The service: the word of an `Execution_Outcome`.
	refusal_problem:   u64, // Refused: the word of the `Problem`.
	refusal_index:     i64, // Refused: the `index` of the `Refusal`.
	refusal_argument:  i64, // Refused: the `argument` of the `Refusal`.
	start_status:      u64, // Not_Started: the word of the status of the start.
	stop_cause:        u64, // The word of the `operation.Stop_Cause` of the runner.
	stop_outcome:      u64, // The word of the `operation.Stop_Outcome` of the runner; a reader takes the state Stopped, the cause and the outcome through `operation.stop_of_words`.
	budget_before:     Mailbox_Amounts, // What the budget of the sequence held before the runner started.
	budget_after:      Mailbox_Amounts, // What it held after the runner stopped and each of its handles ended.
}

// The result of one sequence step, as the runner wrote it.
Step_Result :: struct {
	words:         [ARGUMENTS]u64, // The values of the command record that the runner wrote.
	kind:          u64, // The kind of the command record, with `COMMAND_NAMES_ERROR_DETAILS` when it named a table.
	status:        u64, // The kind of the completion: a status word.
	values:        [ARGUMENTS]u64, // The values of the completion: the results, or an error record.
	details_count: u64, // The count of the table of error details after the command; 0 with no table.
	details:       [operation.ERROR_DETAILS_MOST]errors.Error_Record, // The table, as the command left it.
}

// What the runner writes in the result object.
Runner_Results :: struct {
	step_started: u64, // The runner writes the number of a step, from 1, before it runs its kernel entry.
	steps_run:    u64, // The steps whose results are written.
	end:          u64, // The word of its `Runner_End`, written before its stop; a reader takes it through `enum_word.member_of_word`.
	results:      [STEPS_MOST]Step_Result,
}

// The pattern of each record of a table of error details before its
// command. A command that succeeds leaves the table as it was, so each
// record still holds it.
DETAILS_PATTERN_WORD :: max(i64)

details_pattern :: proc "contextless" () -> errors.Error_Record {
	word := i64(DETAILS_PATTERN_WORD)
	return {kind = word, unit = word, operation = word, argument = word, value = word, limit = word, found = word}
}

MAILBOX_SEQUENCE_OFFSET :: operation.PAGE_SIZE
MAILBOX_RESULTS_OFFSET :: (MAILBOX_SEQUENCE_OFFSET + SEQUENCE_BYTES_MOST + operation.PAGE_SIZE - 1) / operation.PAGE_SIZE * operation.PAGE_SIZE
MAILBOX_PAGES :: (MAILBOX_RESULTS_OFFSET + size_of(Runner_Results) + operation.PAGE_SIZE - 1) / operation.PAGE_SIZE
#assert(size_of(Mailbox_Header) <= MAILBOX_SEQUENCE_OFFSET)

// The pages of the objects that the runner maps.
SEQUENCE_OBJECT_PAGES :: (SEQUENCE_BYTES_MOST + operation.PAGE_SIZE - 1) / operation.PAGE_SIZE
RESULTS_OBJECT_PAGES :: (size_of(Runner_Results) + operation.PAGE_SIZE - 1) / operation.PAGE_SIZE

// Where the runner finds its objects: addresses of its own choice, outside
// the band of the fixed ranges. The service maps them there before the
// start, with no handle, so no sequence step names them by a handle.
RUNNER_SEQUENCE_ADDRESS :: fixed_addresses.OWN_CHOICE_START + 0x0000_0700_0000_0000
RUNNER_RESULTS_ADDRESS :: RUNNER_SEQUENCE_ADDRESS + 0x0000_0001_0000_0000
RUNNER_AREAS_ADDRESS :: RUNNER_SEQUENCE_ADDRESS + 0x0000_0002_0000_0000
// Each area has the room of the largest area and its page with no access.
AREA_ROOM :: (AREA_PAGES_MOST + 1) * operation.PAGE_SIZE

area_address :: proc "contextless" (area: int) -> u64 {
	return RUNNER_AREAS_ADDRESS + u64(area) * AREA_ROOM
}

// The handles of the context of the runner. The budget and the log are at
// their usual slots; the machine at the slot of the machine of a process.
RUNNER_CONTEXT_MACHINE :: 2
RUNNER_CONTEXT_AREA_FIRST :: 3
#assert(RUNNER_CONTEXT_AREA_FIRST + AREAS_MOST <= operation.CONTEXT_LOG)
// The value of the context of the runner that holds the bytes of its
// sequence.
RUNNER_VALUE_SEQUENCE_BYTES :: 0

// The words that the runner gives to the sources of the arguments.
Start_Words :: struct {
	budget:  u64,
	log:     u64,
	machine: u64,
	areas:   [AREAS_MOST]u64, // The handle of each area.
	entries: [Thread_Entry]u64, // The address of each thread entry.
}

// argument_word gives the word of one argument of a sequence that `check`
// accepted: the runner writes it in the command record. `results` holds
// the completions of the steps before this one; `check` refused each
// argument that names a later step, so the step it names has run.
argument_word :: proc "contextless" (argument: Argument, start: ^Start_Words, results: ^Runner_Results) -> u64 {
	switch argument.source {
	case .Value:
		return argument.value
	case .Budget:
		return start.budget
	case .Log:
		return start.log
	case .Machine:
		return start.machine
	case .Area_Handle:
		return start.areas[argument.area]
	case .Area_Address:
		return area_address(argument.area) + argument.offset
	case .Thread_Entry:
		return start.entries[argument.entry]
	case .Result:
		return results.results[argument.step].values[argument.place] + argument.offset
	}
	return 0
}
