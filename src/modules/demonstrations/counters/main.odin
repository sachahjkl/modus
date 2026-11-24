// The counters of a thread: a process counts the events of the processor
// for its own code. The design: docs/ARCHITECTURE.md, "The counters of a
// thread".
//
// **What it is for.** It is the proof of the thread counters, and the
// smallest process that uses them. It counts a loop of known length, and it
// counts the same reads of memory in two orders, so that a reader sees what
// a data layout costs in cache misses, and not only in time.
//
// **The cases**, each with one line of the log:
//
// 1. A copy of the machine handle with no right: Start_Counters gives
//    No_Right. The right Counters is a grant.
// 2. Read_Counters before a start gives Bad_State: the thread does not
//    count. On a machine with no counters that the kernel uses, the command
//    gives Bad_Operation with the error kind Unsupported: the process says so
//    and ends there.
// 3. A loop of LOOP_TURNS turns, each with a store that the compiler keeps:
//    the instructions retired are at least LOOP_INSTRUCTIONS_LEAST. The four
//    counts are a measure on the line, never a condition.
// 4. A second read later gives no count below the first: the thread goes on
//    counting.
// 5. The same reads of 8 bytes in a region of REGION_PAGES pages, in order,
//    then with a stride of one page: the counts of each order, as a measure.
// 6. Stop_Counters with no handle gives Ok: a stop needs no right. Then
//    Read_Counters gives Bad_State.
//
// **Start**: `start("counters")` in the console. The root service gives it
// the start grant Counters: the machine handle with the right Counters only.
//
// **What a reader sees**: no window. The log has one line for each case,
// then "counters: ok". A fault gives "counters: failed: " and what came.
//
// The design: src/md/features/processor_counters.md.
package counters

import "modus:contract/call_outcome"
import "base:intrinsics"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:system"

// The process itself and the region of the reads: 180 pages, as the other
// small processes that hold no window, and the pages of the region. The
// tool reads a literal only, so the assert ties it to the region.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 692, processes = 1, threads = 1}
#assert(MODULE_BUDGET.working_memory_pages == 180 + REGION_PAGES)

// The turns of the loop of case 3, and the least count of instructions that
// the loop retires: each turn retires at least its store, whatever the
// compiler makes of the count and of the branch.
LOOP_TURNS :: 1_000_000
LOOP_INSTRUCTIONS_LEAST :: LOOP_TURNS

// The region of case 5: 2 MiB, more than the L2 cache of a core of the test
// machine (512 KiB), so the order by page misses where the order in memory
// does not.
REGION_PAGES :: 512
PAGE_BYTES :: 4096
LINE_BYTES :: 64 // A cache line of x86-64.
WORD_BYTES :: 8
WORDS_IN_A_PAGE :: PAGE_BYTES / WORD_BYTES
WORDS_IN_A_LINE :: LINE_BYTES / WORD_BYTES
LINES_IN_A_PAGE :: PAGE_BYTES / LINE_BYTES

// The word that the loop of case 3 stores to: a volatile store, which the
// compiler cannot drop.
loop_sink: u64

// step_failed writes the fact of a step that gave a status that stops the
// demonstration, and stops the process with `Failed`. Its sentence starts
// with "counters: failed: ".
step_failed :: proc "contextless" (step: string, status: call_outcome.Call_Outcome) -> ! {
	system.log_fact(.Info, Step_Failed{status_word = call_outcome.Call_Outcome_Word(status), step = value_kinds.text_field(step, 56)})
	system.stop(.Failed)
}

// step_not_refused writes the fact of a step that the kernel must refuse
// with `expected` and that gave another status, and stops the process with
// `Failed`.
step_not_refused :: proc "contextless" (step: string, status, expected: call_outcome.Call_Outcome) -> ! {
	system.log_fact(.Info, Step_Not_Refused{status_word = call_outcome.Call_Outcome_Word(status), expected = expected, refused_step = value_kinds.text_field(step, 72)})
	system.stop(.Failed)
}

// counts_log writes the four counts of one measure: `measure` names it.
counts_log :: proc "contextless" (counters: op.Thread_Counters, measure: string) {
	system.log_fact(.Info, Counts_Measured{instructions = counters.instructions_retired, cycles = counters.cycles, cache_misses = counters.cache_misses, branch_misses = counters.branch_misses, measure = value_kinds.text_field(measure, 24)})
}

// difference gives the counts of a measure between two reads of one start.
difference :: proc "contextless" (after, before: op.Thread_Counters) -> op.Thread_Counters {
	return {
		instructions_retired = after.instructions_retired - before.instructions_retired,
		cycles               = after.cycles - before.cycles,
		cache_misses         = after.cache_misses - before.cache_misses,
		branch_misses        = after.branch_misses - before.branch_misses,
	}
}

// read_or_fail reads the counts of this thread, or stops the process.
read_or_fail :: proc "contextless" (machine: system.Handle, during: string) -> op.Thread_Counters {
	counters, status := system.thread_counters_read(machine)
	if status != .Succeeded {
		// The step is "Read_Counters " and the moment of the read.
		step: [56]u8
		copy(step[:], "Read_Counters ")
		written := len("Read_Counters ")
		written += copy(step[written:len(step) - 1], during)
		step_failed(string(step[:written]), status)
	}
	return counters
}

// sum_of_words reads each word of the region once: in order, or by page.
// By page, the next read is one page further, and a pass reads one word of
// each cache line of the region, so each pass reads the whole region: no
// line stays in the L2 cache until the next pass reads its next word, and a
// prefetcher of the processor does not follow a stride of one page. The
// two orders read the same words, the same count of times.
sum_of_words :: proc "contextless" (words: [^]u64, page_order: bool) -> (sum: u64) {
	if !page_order {
		for index in 0 ..< REGION_PAGES * WORDS_IN_A_PAGE {
			sum += intrinsics.volatile_load(&words[index])
		}
		return sum
	}
	for word_in_line in 0 ..< WORDS_IN_A_LINE {
		for line in 0 ..< LINES_IN_A_PAGE {
			for page in 0 ..< REGION_PAGES {
				sum += intrinsics.volatile_load(&words[page * WORDS_IN_A_PAGE + line * WORDS_IN_A_LINE + word_in_line])
			}
		}
	}
	return sum
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	machine := ctx.handles[system.GRANT_MACHINE]

	// 1. The right Counters is a grant: a copy of the machine handle with no
	// right counts nothing.
	without_right, given := system.give(0, machine, {})
	if given != .Succeeded {
		step_failed("the copy of the machine handle", given)
	}
	refused := system.thread_counters_start(without_right)
	system.close(without_right)
	if refused != .Grant_Or_Right_Missing {
		step_not_refused("Start_Counters with a copy of the machine handle with no right", refused, .Grant_Or_Right_Missing)
	}
	system.log_fact(.Info, Start_Without_Right_Refused{})

	// 2. No count before a start, or no counters on this machine.
	error: errors.Error_Record
	_, before_start := system.thread_counters_read(machine, &error)
	if before_start == .Operation_Unsupported && error.kind == i64(errors.Kind.Unsupported) {
		start_error: errors.Error_Record
		start_status := system.thread_counters_start(machine, &start_error)
		if start_status != .Operation_Unsupported || start_error.kind != i64(errors.Kind.Unsupported) {
			step_failed("Read_Counters gave Unsupported and Start_Counters", start_status)
		}
		system.log_fact(.Info, Counters_Unsupported{})
		system.log_fact(.Info, Counters_Held{})
		system.stop(.Done)
	}
	if before_start != .Wrong_State {
		step_not_refused("Read_Counters before Start_Counters", before_start, .Wrong_State)
	}
	system.log_fact(.Info, Read_Before_Start_Refused{})

	// 3. A loop of known length.
	if status := system.thread_counters_start(machine); status != .Succeeded {
		step_failed("Start_Counters", status)
	}
	for turn in u64(0) ..< LOOP_TURNS {
		intrinsics.volatile_store(&loop_sink, turn)
	}
	loop := read_or_fail(machine, "after the loop")
	if loop.instructions_retired < LOOP_INSTRUCTIONS_LEAST {
		// A counter that the host did not give counts nothing: the four
		// counts on the line say which.
		system.log_fact(.Info, Loop_Too_Short{turns = u64(LOOP_TURNS), instructions = loop.instructions_retired, least_instructions = u64(LOOP_INSTRUCTIONS_LEAST), cycles = loop.cycles, cache_misses = loop.cache_misses, branch_misses = loop.branch_misses})
		system.stop(.Failed)
	}
	system.log_fact(.Info, Loop_Retired{turns = u64(LOOP_TURNS), least_instructions = u64(LOOP_INSTRUCTIONS_LEAST)})
	counts_log(loop, "the loop")

	// 4. The thread goes on counting.
	later := read_or_fail(machine, "a second time")
	if later.instructions_retired < loop.instructions_retired || later.cycles < loop.cycles || later.cache_misses < loop.cache_misses || later.branch_misses < loop.branch_misses {
		system.log_fact(.Info, Second_Read_Below_First{})
		system.stop(.Failed)
	}
	system.log_fact(.Info, Second_Read_Not_Below{})

	// 5. One data layout read in two orders.
	region, created := system.memory_create(REGION_PAGES)
	if created != .Succeeded {
		step_failed("Memory_Create of the region", created)
	}
	address, mapped := system.memory_map(region, {.Write})
	if mapped != .Succeeded {
		step_failed("Memory_Map of the region", mapped)
	}
	words := ([^]u64)(address)
	// Each page gets its frame before the measures, so neither order pays
	// for a page on first use.
	for index in 0 ..< REGION_PAGES * WORDS_IN_A_PAGE {
		words[index] = u64(index)
	}
	start_in_order := read_or_fail(machine, "before the reads in order")
	sum_in_order := sum_of_words(words, false)
	in_order := difference(read_or_fail(machine, "after the reads in order"), start_in_order)
	start_by_page := read_or_fail(machine, "before the reads by page")
	sum_by_page := sum_of_words(words, true)
	by_page := difference(read_or_fail(machine, "after the reads by page"), start_by_page)
	if sum_in_order != sum_by_page {
		system.log_fact(.Info, Orders_Read_Other_Words{sum_in_order = sum_in_order, sum_by_page = sum_by_page})
		system.stop(.Failed)
	}
	system.log_fact(.Info, Orders_Read_Same_Words{reads = u64(REGION_PAGES * WORDS_IN_A_PAGE), word_bytes = u64(WORD_BYTES), region_pages = u64(REGION_PAGES)})
	counts_log(in_order, "the reads in order")
	counts_log(by_page, "the reads by page")

	// 6. A stopped thread has no count. The stop takes no handle: it only
	// takes a capability away.
	if status := system.thread_counters_stop(); status != .Succeeded {
		step_failed("Stop_Counters with no handle", status)
	}
	if _, after_stop := system.thread_counters_read(machine); after_stop != .Wrong_State {
		step_not_refused("Read_Counters after Stop_Counters", after_stop, .Wrong_State)
	}
	system.log_fact(.Info, Stop_Without_Handle_Checked{})
	system.log_fact(.Info, Counters_Held{})
	system.stop(.Done)
}
