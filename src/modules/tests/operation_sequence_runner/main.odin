// The runner of one operation sequence (src/md/infrastructure/kernel_fuzzing.md,
// "The processes in the machine"). The process `operation_fuzzing` starts
// one new runner for each sequence, with the budget of that sequence.
//
// **What it is for.** It runs each sequence step as one command record of
// its kernel ring, and writes what the kernel answered, so that the tool
// checks the answers against the forms of the kernel operations.
//
// **Start**: only `operation_fuzzing` starts it, from the boot image of the
// operation sequences. Its row of `process_roles` has no grant. It writes
// nothing on the log, unless a step writes there.
package operation_sequence_runner

import "base:intrinsics"
import "modus:contract/enum_word"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/operation_sequence"
import "modus:contract/ring"
import "modus:support/system"

// The sequence, read again from the copy that the service mapped: the
// copy is read-only here, and this process checks what it runs.
sequence: operation_sequence.Sequence

// The table of error details of each step: a step of a batch keeps its own
// table until the batch ends.
details_places: [operation_sequence.STEPS_MOST]op.Error_Details_Place
details_records: [operation_sequence.STEPS_MOST][op.ERROR_DETAILS_MOST]errors.Error_Record

// The word that the thread entry Wait_On_Word waits on: nothing wakes it.
waited_word: u32

// The three thread entries that a step names as code.
entry_wait_on_word :: proc "c" (_: rawptr) -> ! {
	for {
		wait := system.wait_begin()
		system.wait_word(&wait, &waited_word, intrinsics.volatile_load(&waited_word))
		system.wait_end(&wait)
	}
}

entry_return :: proc "c" (_: rawptr) -> ! {
	// A thread entry has no caller to return to: the thread ends itself.
	system.call(.Thread_Stop, 0)
	for {}
}

entry_read_address_zero :: proc "c" (_: rawptr) -> ! {
	_ = intrinsics.volatile_load((^u8)(nil))
	for {}
}

// The entry of the runner: it checks its sequence, runs each kernel entry
// of it, writes the results after each one, then writes its end `Ran` and
// stops itself with `Done`. A refusal of its sequence writes its end and
// stops with `Refused`; a refusal of a batch, with `Failed`.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	// The service maps the results before the start, so the end of a
	// refusal has its place too.
	results := (^operation_sequence.Runner_Results)(uintptr(operation_sequence.RUNNER_RESULTS_ADDRESS))
	byte_count := ctx.values[operation_sequence.RUNNER_VALUE_SEQUENCE_BYTES]
	if byte_count > operation_sequence.SEQUENCE_BYTES_MOST {
		end_and_stop(results, .Sequence_Refused)
	}
	sequence_bytes := ([^]u8)(uintptr(operation_sequence.RUNNER_SEQUENCE_ADDRESS))
	bytes := sequence_bytes[:byte_count]
	if refusal := operation_sequence.check(bytes, &sequence); refusal.problem != .None {
		end_and_stop(results, .Sequence_Refused)
	}
	start := operation_sequence.Start_Words {
		budget  = u64(ctx.handles[op.CONTEXT_BUDGET]),
		log     = u64(ctx.handles[op.CONTEXT_LOG]),
		machine = u64(ctx.handles[operation_sequence.RUNNER_CONTEXT_MACHINE]),
	}
	for area in 0 ..< sequence.area_count {
		start.areas[area] = u64(ctx.handles[operation_sequence.RUNNER_CONTEXT_AREA_FIRST + area])
	}
	start.entries[.Wait_On_Word] = u64(uintptr(rawptr(entry_wait_on_word)))
	start.entries[.Return] = u64(uintptr(rawptr(entry_return)))
	start.entries[.Read_Address_Zero] = u64(uintptr(rawptr(entry_read_address_zero)))

	first := 0
	for first < sequence.step_count {
		// A batch: the step `first`, then each step after it with Same_Entry.
		end := first + 1
		for end < sequence.step_count && (.Same_Entry in sequence.steps[end].flags) {
			end += 1
		}
		commands: [ring.CAPACITY]ring.Record
		completions: [ring.CAPACITY]ring.Record
		for step in first ..< end {
			commands[step - first] = command_of_step(step, &start, results)
		}
		// The number of the first step of the batch, from 1: a stop during
		// the entry names it.
		intrinsics.volatile_store(&results.step_started, u64(first + 1))
		if _, status := system.commands_call(commands[:end - first], completions[:end - first], 0); status != .Ok {
			end_and_stop(results, .Batch_Refused)
		}
		for step in first ..< end {
			result_write(step, commands[step - first], completions[step - first], results)
		}
		intrinsics.volatile_store(&results.steps_run, u64(end))
		first = end
	}
	end_and_stop(results, .Ran)
}

// end_and_stop writes the end of the runner in its results, then stops it:
// the stop outcome says what kind of end, the end says which.
end_and_stop :: proc "contextless" (results: ^operation_sequence.Runner_Results, end: operation_sequence.Runner_End) -> ! {
	intrinsics.volatile_store(&results.end, u64(end))
	switch end {
	case .Ran:
		system.stop(.Done)
	case .Sequence_Refused:
		// The sequence is the input of the runner: its check refused it.
		system.stop(.Refused)
	case .Batch_Refused, .None:
		system.stop(.Failed)
	}
	system.stop(.Failed)
}

// command_of_step gives the command record of one step: its operation word
// as the sequence gives it, its arguments as words, and its table of error
// details when the operation takes one and the step does not refuse it.
command_of_step :: proc "contextless" (step: int, start: ^operation_sequence.Start_Words, results: ^operation_sequence.Runner_Results) -> ring.Record {
	item := &sequence.steps[step]
	command := ring.Record{kind = item.operation}
	for argument, index in item.arguments {
		command.values[index] = operation_sequence.argument_word(argument, start, results)
	}
	if .No_Error_Details in item.flags || !names_a_table(item.operation) {
		return command
	}
	for &record in details_records[step] {
		record = operation_sequence.details_pattern()
	}
	details_places[step] = {address = u64(uintptr(&details_records[step][0])), count = 0, capacity = op.ERROR_DETAILS_MOST}
	command.kind |= op.COMMAND_NAMES_ERROR_DETAILS
	command.values[op.ERROR_DETAILS_VALUE] = u64(uintptr(&details_places[step]))
	return command
}

// names_a_table says if the runner gives a step a table of error details:
// each operation whose last value is free, and each word that names no
// operation, which the kernel must refuse whatever the bit.
names_a_table :: proc "contextless" (word: u32) -> bool {
	operation, known := enum_word.member_of_word(op.Operation, u64(word))
	if !known || operation == .None {
		return true
	}
	return op.command_takes_error_details(operation)
}

// result_write writes what the kernel answered to one step.
result_write :: proc "contextless" (step: int, command: ring.Record, completion: ring.Record, results: ^operation_sequence.Runner_Results) {
	result := &results.results[step]
	result.words = command.values
	result.kind = u64(command.kind)
	result.status = u64(completion.kind)
	result.values = completion.values
	if command.kind & op.COMMAND_NAMES_ERROR_DETAILS != 0 {
		result.details_count = details_places[step].count
		result.details = details_records[step]
	} else {
		result.details_count = 0
		result.details = {}
	}
}
