// The program that runs operation sequences (src/md/infrastructure/kernel_fuzzing.md,
// "The programs in the machine").
//
// **What it is for.** It takes each operation sequence that the tool writes
// in its mailbox, runs it in a new runner with a new budget, and writes the
// answers of the kernel and the amounts of that budget back, so that the
// tool checks them against the forms of the kernel operations.
//
// **Start**: the root service starts it on the machine of the operation
// sequences only, whose boot image holds it, with the machine with the
// right Physical only, the boot image and the log. A release refuses an
// image that holds it.
package operation_fuzzing

import "base:intrinsics"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/operation_sequence"
import "modus:support/random"
import "modus:support/system"

// The budget of each sequence, from the budget of this program: the
// runner, its areas, its results and what its steps create.
SEQUENCE_AMOUNTS :: system.Budget_Amounts {
	pages       = 2048,
	programs    = 8,
	threads     = 16,
	log_records = 100,
}
// The budget of the runner, from the budget of the sequence. The areas, the
// results and the copy of the sequence are paid by the budget of the
// sequence beside it.
RUNNER_AMOUNTS :: system.Budget_Amounts {
	pages       = 1024,
	programs    = 4,
	threads     = 8,
	log_records = 50,
}

machine: system.Handle
image: []u8
runner_file: []u8
generator: random.Generator
prepared: system.Prepared_Modules // The shared code of the runners.
header: ^operation_sequence.Mailbox_Header
mailbox: []u8
// The copy of the sequence that the tool wrote: the tool can change the
// mailbox at any time, so this program checks the copy.
sequence_copy: [operation_sequence.SEQUENCE_BYTES_MOST]u8
sequence: operation_sequence.Sequence

failed :: proc "contextless" (text: string, status: system.Status) -> ! {
	system.log("operation_fuzzing: failed: ", text, ": status ", status)
	system.stop(1)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	machine = ctx.handles[system.GRANT_MACHINE]
	if !random.generator_from_context(&generator, ctx) {
		failed("no random seed in the context", .Bad_Operation)
	}
	address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {})
	if status != .Ok {
		failed("no boot image", status)
	}
	image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	runner_file = system.image_find(image, operation_sequence.RUNNER_NAME)
	if len(runner_file) == 0 {
		failed("the boot image has no runner", .Bad_Operation)
	}
	memory: system.Handle
	memory, status = system.memory_create(operation_sequence.MAILBOX_PAGES, 0, {.Contiguous})
	if status != .Ok {
		failed("no mailbox", status)
	}
	mapped: rawptr
	mapped, status = system.memory_map(memory, {.Write})
	if status != .Ok {
		failed("the mailbox does not map", status)
	}
	mailbox = ([^]u8)(mapped)[:operation_sequence.MAILBOX_PAGES * system.PAGE_SIZE]
	header = (^operation_sequence.Mailbox_Header)(mapped)
	results: [7]u64
	results, status = system.call(.Memory_Physical, u64(machine), u64(memory))
	if status != .Ok {
		failed("Memory_Physical refused the mailbox", status)
	}
	header.format = operation_sequence.MAILBOX_FORMAT
	intrinsics.atomic_store(&header.magic, operation_sequence.MAILBOX_MAGIC)
	system.log("operation_fuzzing: mailbox at ", results[0], ", ", u64(operation_sequence.MAILBOX_PAGES), " pages")
	for {
		executions := intrinsics.atomic_load(&header.executions)
		if intrinsics.atomic_load(&header.sequences_written) == executions {
			// The tool writes the memory with no wake: an entry with no
			// wait lets the other threads run between two reads.
			system.time_entered()
			continue
		}
		execute()
		// Before the count: the tool reads the results at the count, then
		// waits for this line, which comes after each line of the kernel
		// that the sequence caused.
		system.log(operation_sequence.SEQUENCE_END_LINE_START, executions + 1, operation_sequence.SEQUENCE_END_LINE_END)
		intrinsics.atomic_store(&header.executions, executions + 1)
	}
}

// execute runs the sequence of the mailbox, and writes its outcome.
execute :: proc "contextless" () {
	header.outcome = u64(operation_sequence.Execution_Outcome.None)
	header.stop_code, header.start_status = 0, 0
	header.budget_before, header.budget_after = {}, {}
	results := (^operation_sequence.Runner_Results)(&mailbox[operation_sequence.MAILBOX_RESULTS_OFFSET])
	results^ = {}
	byte_count := intrinsics.volatile_load(&header.sequence_bytes)
	if byte_count > operation_sequence.SEQUENCE_BYTES_MOST {
		header.outcome = u64(operation_sequence.Execution_Outcome.Refused)
		header.refusal_problem = u64(operation_sequence.Problem.Size)
		header.refusal_index, header.refusal_argument = -1, -1
		return
	}
	count := int(byte_count)
	copy(sequence_copy[:count], mailbox[operation_sequence.MAILBOX_SEQUENCE_OFFSET:][:count])
	bytes := sequence_copy[:count]
	if refusal := operation_sequence.check(bytes, &sequence); refusal.problem != .None {
		header.outcome = u64(operation_sequence.Execution_Outcome.Refused)
		header.refusal_problem = u64(refusal.problem)
		header.refusal_index, header.refusal_argument = i64(refusal.index), i64(refusal.argument)
		return
	}
	budget, status := system.budget_create(amounts_with_processor(SEQUENCE_AMOUNTS))
	if status != .Ok {
		failed("no budget for a sequence", status)
	}
	defer system.close(budget)
	header.budget_before = amounts_of(budget)
	outcome, stop_code, start_status := runner_run(budget, bytes, results)
	header.outcome = u64(outcome)
	header.stop_code = u64(stop_code)
	header.start_status = u64(start_status)
	header.budget_after = amounts_of(budget)
}

amounts_of :: proc "contextless" (budget: system.Handle) -> operation_sequence.Mailbox_Amounts {
	amounts, _ := system.budget_read(budget)
	return {pages = amounts.pages, programs = amounts.programs, threads = amounts.threads}
}

// runner_run makes the objects of the runner from the budget of the
// sequence, starts it, waits for its stop, and copies its results. Each
// handle of this program to an object of the runner is closed before it
// returns, so the budget then holds again what it held before.
runner_run :: proc "contextless" (budget: system.Handle, bytes: []u8, results: ^operation_sequence.Runner_Results) -> (outcome: operation_sequence.Execution_Outcome, stop_code: u32, start_status: system.Status) {
	grants: [op.CONTEXT_HANDLES]system.Grant
	mappings: [2 + operation_sequence.AREAS_MOST]system.Mapping
	held: [2 + operation_sequence.AREAS_MOST]system.Handle
	defer for handle in held {
		if handle != 0 {
			system.close(handle)
		}
	}
	// The copy of the sequence, read-only for the runner.
	sequence_memory, made := object_with(budget, operation_sequence.SEQUENCE_OBJECT_PAGES, bytes)
	if made != .Ok {
		return .Not_Started, 0, made
	}
	held[0] = sequence_memory
	mappings[0] = {memory = sequence_memory, address = operation_sequence.RUNNER_SEQUENCE_ADDRESS, flags = {}}
	results_memory, created := system.memory_create(operation_sequence.RESULTS_OBJECT_PAGES, budget)
	if created != .Ok {
		return .Not_Started, 0, created
	}
	held[1] = results_memory
	mappings[1] = {memory = results_memory, address = operation_sequence.RUNNER_RESULTS_ADDRESS, flags = {.Write}}
	for area in 0 ..< sequence.area_count {
		memory, area_made := object_with(budget, u64(sequence.areas[area].pages), operation_sequence.area_content(&sequence, area))
		if area_made != .Ok {
			return .Not_Started, 0, area_made
		}
		held[2 + area] = memory
		mappings[2 + area] = {memory = memory, address = operation_sequence.area_address(area), flags = {.Write}}
		grants[operation_sequence.RUNNER_CONTEXT_AREA_FIRST + area] = {memory, {.Give, .Read, .Write, .Execute}}
	}
	grants[op.CONTEXT_LOG] = {system.context_record().handles[op.CONTEXT_LOG], {.Write}}
	values: [op.CONTEXT_VALUES]u64
	values[operation_sequence.RUNNER_VALUE_SEQUENCE_BYTES] = u64(len(bytes))
	// This program reads the results through its own mapping, read-only,
	// which it removes before it reads the budget again.
	view, viewed := system.memory_map(results_memory, {})
	if viewed != .Ok {
		return .Not_Started, 0, viewed
	}
	defer system.memory_unmap(view)
	load_error: module.Load_Error
	runner, started := system.program_start(runner_file, operation_sequence.RUNNER_NAME, grants, random.values_with_seed(&generator, values), amounts_with_processor(RUNNER_AMOUNTS), mappings[:2 + sequence.area_count], &prepared, {image = image}, &load_error, budget)
	if started != .Ok {
		return .Not_Started, 0, started
	}
	// The runner holds its objects now: these handles end with it.
	for &handle in held {
		if handle != 0 {
			system.close(handle)
			handle = 0
		}
	}
	outcome = .Hung
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for system.time() < deadline {
		// The stop of a program that this program holds adds one to its
		// event word: the wait ends then.
		wait := system.wait_begin()
		if state, _ := system.program_state(runner); state == .Stopped {
			outcome = .Stopped
			break
		}
		system.wait_end(&wait, deadline)
	}
	if outcome == .Hung {
		system.call(.Program_Stop, u64(runner), 0)
	}
	_, stop_code = system.program_state(runner)
	system.close(runner)
	results^ = (^operation_sequence.Runner_Results)(view)^
	if outcome == .Stopped && stop_code == operation_sequence.RUNNER_END_CODE && results.steps_run == u64(sequence.step_count) {
		outcome = .Ran
	}
	return outcome, stop_code, .Ok
}

// object_with makes a memory object of pages from a budget, and writes
// bytes at its start through a mapping that it removes again.
object_with :: proc "contextless" (budget: system.Handle, pages: u64, bytes: []u8) -> (memory: system.Handle, status: system.Status) {
	memory = system.memory_create(pages, budget) or_return
	address, mapped := system.memory_map(memory, {.Write})
	if mapped != .Ok {
		system.close(memory)
		return 0, mapped
	}
	copy(([^]u8)(address)[:len(bytes)], bytes)
	system.memory_unmap(address)
	return memory, .Ok
}

// amounts_with_processor gives amounts with the processor limit of the
// budget of this program: a budget with no processor time would never run
// its runner.
amounts_with_processor :: proc "contextless" (amounts: system.Budget_Amounts) -> system.Budget_Amounts {
	own, _ := system.budget_read()
	with := amounts
	with.processor = own.processor
	return with
}
