// A process drives its own virtual memory. The design:
// docs/ARCHITECTURE.md, "The virtual memory of a process".
//
// At its start the process runs its cases, with their numbers:
//   an arena: a range of 1 GiB of addresses with no memory behind it, whose
//     pages are committed as the arena grows, with tables of 1, 16 and 256
//     ranges for each kernel entry;
//   a sparse table: a fixed base of 1 GiB, 1024 pages committed at random;
//   decommit: the frames and the pages return to the budget at once, and a
//     page committed again is zero;
//   protection: a part of a mapping becomes read only, with the time of the
//     shoot-down when 1, 2 or 4 processors run threads of the process;
//   a guard page: a child process writes down its stack into a page with no
//     access, and the kernel stops it there;
//   large pages: random reads over 64 MiB of one object, through a mapping
//     of large pages and through a mapping of pages of 4 KiB;
//   page tables: each table that a mapping made returns to the budget with
//     its unmap, also while another thread uses a page of the same table;
//   the refusals, each with its error record.
// The window shows the numbers. The log has one line for each case and a
// line "address_space: ok, ..." when each check holds. The checks do not
// depend on the load of the host.
//
// The process needs the machine with the right Inspect (its own mappings)
// and the boot image (its child).
//
// **What it is for.** A process that manages its own memory (an arena, a
// sparse table, a stack with a guard) needs to reserve addresses with no
// memory behind them, [commit](term:committed-page) and
// [decommit](term:decommit) pages, change their
// [protection](term:page-protection), and use
// [large pages](term:large-page). This process does each of these with the
// kernel operations of the virtual memory, and checks that the budget pays
// only for what the process uses, and gets each page back.
//
// **How to start it.** From the start menu, or with
// `start("address_space")` in the console.
//
// **Its budget** from the root service holds 40960 pages and 2 processes:
// 64 MiB of large pages, two ranges of 1 GiB with their page tables, and
// the child of the guard page.
//
// **What it does not prove.** The times (a commit, a shoot-down, a read
// through large pages) are measures of the host of the run.
package address_space

import "modus:contract/call_outcome"
import "modus:contract/fixed_addresses"
import "base:intrinsics"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:random"
import "modus:system"

// 64 MiB of large pages, two ranges of 1 GiB with their page tables, and
// a child: 40530 pages. And the glyph memory of the copy of the text
// rendering of the drawing module, which draws its text: 354 pages
// (display.TEXT_MEMORY_PAGES). 40530 + 354 = 40884. With the counted
// parts, the pages are above the least largest budget of a process, so it
// runs on a machine whose share for one process holds them: a machine of
// 1 GiB does (module.largest_budget_of_machine).
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 40884, processes = 2, threads = 6, window_width = WIDTH, window_height = HEIGHT}

WIDTH :: 960
HEIGHT :: 640
GIGABYTE_PAGES :: 262144 // 1 GiB of pages of 4 KiB.
ARENA_PAGES :: 4096 // The pages that the arena commits for each size of batch.
SPARSE_PAGES :: 1024
PROTECT_PAGES :: 256
PROTECT_CALLS :: 40 // One batch.
PROTECT_BATCHES :: 5
LARGE_OBJECT_PAGES :: 16384 // 64 MiB.
LARGE_ADDRESS :: fixed_addresses.OWN_CHOICE_START + 0x0000_0100_0000_0000 // Aligned on 2 MiB: the mapping of large pages.
SMALL_ADDRESS :: fixed_addresses.OWN_CHOICE_START + 0x0000_0200_0000_1000 // Not aligned: the same object with pages of 4 KiB.
GUARD_ADDRESS :: fixed_addresses.OWN_CHOICE_START + 0x0000_0300_0000_0000 // The stack of the child: the guard page, then 63 pages.
// Places of this process's own choice: outside the band of the fixed
// ranges of the system, which grows by its end.
#assert(LARGE_ADDRESS >= fixed_addresses.OWN_CHOICE_START && SMALL_ADDRESS >= fixed_addresses.OWN_CHOICE_START && GUARD_ADDRESS >= fixed_addresses.OWN_CHOICE_START)
GUARD_STACK_PAGES :: 64
RANDOM_READS :: 4_000_000
VALUE_ROLE :: 0 // The context of the child: 1.

machine: system.Handle
process_generator: random.Generator // The seeds of the children (docs/RANDOMNESS.md).
self_index: u64 // The slot of this process, for its report of mappings.

// The results of the cases, for the log and the window.
batch_sizes := [3]u64{1, 16, 256}
arena_pages_per_second: [3]u64
arena_entries_per_thousand_pages: [3]u64 // Kernel entries for 1000 pages committed and used.
arena_map_microseconds: u64
arena_list_pages: u64
sparse_committed, sparse_present: u64
decommit_returned, decommit_expected: u64
decommit_microseconds: u64
recommit_zero: bool
// The middle of one batch of PROTECT_CALLS, with 1, 2 and 4 processors
// running the process: the least and the most of PROTECT_BATCHES batches.
// The process cannot know the load of the host: it shows the spread.
shootdown_least, shootdown_most: [3]u64
guard_address, guard_vector: u64
guard_right: bool
large_nanoseconds, small_nanoseconds: u64 // One random read.
large_flags_right: bool
refusals: [4]Refusal
right := true
problem: string
done: bool

Refusal :: struct {
	name:     string,
	status:   call_outcome.Call_Outcome,
	expected: call_outcome.Call_Outcome,
	record:   errors.Error_Record,
	sentence: [160]u8,
	count:    int,
}

fail :: proc "contextless" (what: string) {
	if right {
		problem = what
	}
	right = false
}

// The last report of the mappings of this process: 64 KiB, which a stack
// does not hold.
own_mappings_report: op.Process_Mapping_Report

// own_mappings reads the mappings of this process into the one report, and
// gives it. A second call writes over the first.
own_mappings :: proc "contextless" () -> ^op.Process_Mapping_Report {
	report := &own_mappings_report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process_Mappings), self_index, u64(uintptr(report)), size_of(report^))
	return report
}

mapping_at :: proc "contextless" (report: ^op.Process_Mapping_Report, address: u64) -> ^op.Process_Mapping {
	for &mapping in report.mappings[:report.count] {
		if mapping.address == address {
			return &mapping
		}
	}
	return nil
}

// find_self finds the slot of this process by its name in the reports.
find_self :: proc "contextless" () {
	machine_report: op.System_Report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&machine_report)), size_of(machine_report))
	for index in u64(1) ..< machine_report.process_slots {
		report: op.Process_Report
		if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), index, u64(uintptr(&report)), size_of(report)); status != .Succeeded {
			continue
		}
		if system.name_of(report.name[:]) == "address_space" && report.state != .Stopped && report.state != .None {
			self_index = index
			return
		}
	}
}

// The arena: one range of 1 GiB, pages committed as it grows.
arena :: proc "contextless" () {
	before, _ := system.budget_read()
	memory, status := system.memory_create(GIGABYTE_PAGES, flags = {.Uncommitted})
	if status != .Succeeded {
		fail("the arena: no object")
		return
	}
	defer system.close(memory)
	after_create, _ := system.budget_read()
	arena_list_pages = before.pages - after_create.pages
	start := system.nanoseconds()
	address, map_status := system.memory_map(memory)
	arena_map_microseconds = (system.nanoseconds() - start) / 1000
	if map_status != .Succeeded {
		fail("the arena: no mapping")
		return
	}
	defer system.memory_unmap(address)
	bytes := ([^]u8)(address)
	ranges: [256]op.Page_Range
	for batch, row in batch_sizes {
		first := u64(row) * ARENA_PAGES
		entries := system.kernel_entries()
		start = system.nanoseconds()
		for page := first; page < first + ARENA_PAGES; page += batch {
			for index in 0 ..< batch {
				ranges[index] = {first = page + index, page_count = 1}
			}
			if _, commit := system.memory_commit(memory, ranges[:batch]); commit != .Succeeded {
				fail("the arena: a commit was refused")
				return
			}
			for index in 0 ..< batch {
				intrinsics.volatile_store(&bytes[(page + index) * system.PAGE_SIZE], 1)
			}
		}
		elapsed := max(system.nanoseconds() - start, 1)
		arena_pages_per_second[row] = ARENA_PAGES * 1_000_000_000 / elapsed
		arena_entries_per_thousand_pages[row] = (system.kernel_entries() - entries) * 1000 / ARENA_PAGES
	}
	// The pages return.
	everything := [1]op.Page_Range{{first = 0, page_count = 3 * ARENA_PAGES}}
	if returned, decommit := system.memory_decommit(memory, everything[:]); decommit != .Succeeded || returned != 3 * ARENA_PAGES {
		fail("the arena: the decommit")
	}
}

// The sparse table: a fixed base, pages committed at random, then the
// decommit and a page committed again.
sparse :: proc "contextless" () {
	memory, status := system.memory_create(GIGABYTE_PAGES, flags = {.Uncommitted})
	if status != .Succeeded {
		fail("the sparse table: no object")
		return
	}
	defer system.close(memory)
	address, map_status := system.memory_map(memory)
	if map_status != .Succeeded {
		fail("the sparse table: no mapping")
		return
	}
	defer system.memory_unmap(address)
	words := ([^]u64)(address)
	pages: [SPARSE_PAGES]u64
	random := u64(0x9E37_79B9_7F4A_7C15)
	page: u64
	for &chosen in pages {
		random ~= random << 13
		random ~= random >> 7
		random ~= random << 17
		page += 1 + random % 255
		chosen = page
	}
	ranges: [256]op.Page_Range
	for part in 0 ..< SPARSE_PAGES / 256 {
		for index in 0 ..< 256 {
			ranges[index] = {first = pages[part * 256 + index], page_count = 1}
		}
		if _, commit := system.memory_commit(memory, ranges[:]); commit != .Succeeded {
			fail("the sparse table: a commit was refused")
			return
		}
	}
	for chosen in pages {
		words[chosen * 512] = chosen
	}
	report := own_mappings()
	if mapping := mapping_at(report, u64(uintptr(address))); mapping != nil {
		sparse_committed, sparse_present = mapping.committed, mapping.present
		if .Uncommitted not_in mapping.flags {
			fail("the sparse table: the report does not say Uncommitted")
		}
	}
	if sparse_committed != SPARSE_PAGES || sparse_present != SPARSE_PAGES {
		fail("the sparse table: the committed pages")
	}
	// Decommit: the budget gets each page back at once.
	before, _ := system.budget_read()
	// At most RANGE_TABLE_PAGE_LIMIT pages in one call: four calls for 1 GiB;
	// the longest is the longest section of the kernel with interrupts off
	// that a call of this kind makes.
	returned: u64
	decommit := call_outcome.Call_Outcome.Succeeded
	for part in u64(0) ..< GIGABYTE_PAGES / op.RANGE_TABLE_PAGE_LIMIT {
		quarter := [1]op.Page_Range{{first = part * op.RANGE_TABLE_PAGE_LIMIT, page_count = op.RANGE_TABLE_PAGE_LIMIT}}
		start := system.nanoseconds()
		changed, part_status := system.memory_decommit(memory, quarter[:])
		decommit_microseconds = max(decommit_microseconds, (system.nanoseconds() - start) / 1000)
		returned += changed
		if part_status != .Succeeded {
			decommit = part_status
		}
	}
	record: errors.Error_Record
	everything := [1]op.Page_Range{{first = 0, page_count = GIGABYTE_PAGES}}
	_, too_many := system.memory_decommit(memory, everything[:], &record)
	if too_many != .Argument_Refused || record.kind != i64(errors.Kind.Too_Long) {
		fail("a decommit of more than the page limit of one call was not refused with its record")
	}
	after, _ := system.budget_read()
	decommit_returned, decommit_expected = after.pages - before.pages, SPARSE_PAGES
	if decommit != .Succeeded || returned != SPARSE_PAGES || decommit_returned != SPARSE_PAGES {
		fail("the decommit: the budget did not get each page back")
	}
	// A page committed again is zero.
	again := [1]op.Page_Range{{first = pages[7], page_count = 1}}
	system.memory_commit(memory, again[:])
	recommit_zero = words[pages[7] * 512] == 0
	if !recommit_zero {
		fail("a page committed again is not zero")
	}
}

// Threads that run the process on other processors: they hold its page
// table, so each protection change waits for them (the shoot-down).
Runner :: struct #align (64) {
	stop: u32,
	count: u64,
}
runners: [3]Runner

run :: proc "c" (parameter: rawptr) -> ! {
	runner := (^Runner)(parameter)
	for intrinsics.atomic_load(&runner.stop) == 0 {
		intrinsics.volatile_store(&runner.count, runner.count + 1)
	}
	system.thread_stop()
}

protection :: proc "contextless" () {
	memory, status := system.memory_create(PROTECT_PAGES)
	if status != .Succeeded {
		fail("the protection: no object")
		return
	}
	defer system.close(memory)
	address, map_status := system.memory_map(memory)
	if map_status != .Succeeded {
		fail("the protection: no mapping")
		return
	}
	defer system.memory_unmap(address)
	bytes := ([^]u8)(address)
	for page in 0 ..< PROTECT_PAGES {
		bytes[page * system.PAGE_SIZE] = 1
	}
	part := [1]op.Address_Range{{address = u64(uintptr(address)) + 64 * system.PAGE_SIZE, page_count = 64}}
	threads: [3]system.Thread
	started := 0
	for running, row in ([3]int{0, 1, 3}) {
		for started < running {
			runners[started] = {}
			threads[started], _ = system.thread_start(run, &runners[started])
			started += 1
		}
		system.sleep(system.time() + 20)
		shootdown_least[row] = max(u64)
		for _ in 0 ..< PROTECT_BATCHES {
			times: [PROTECT_CALLS]u64
			for &time, call in times {
				start := system.nanoseconds()
				_, protect := system.memory_protect(part[:], call % 2 == 0 ? {} : {.Write})
				time = system.nanoseconds() - start
				if protect != .Succeeded {
					fail("the protection: a change was refused")
					return
				}
			}
			for at in 1 ..< len(times) {
				for back := at; back > 0 && times[back - 1] > times[back]; back -= 1 {
					times[back - 1], times[back] = times[back], times[back - 1]
				}
			}
			middle := times[PROTECT_CALLS / 2]
			shootdown_least[row] = min(shootdown_least[row], middle)
			shootdown_most[row] = max(shootdown_most[row], middle)
		}
	}
	for index in 0 ..< started {
		intrinsics.atomic_store(&runners[index].stop, 1)
		system.thread_wait(threads[index])
	}
	report := own_mappings()
	if mapping := mapping_at(report, u64(uintptr(address))); mapping == nil || .Protected not_in mapping.flags {
		fail("the protection: the report does not say Protected")
	}
}

// The child: its stack is under a page with no access; it writes down
// until it reaches it.
child :: proc "contextless" () -> ! {
	memory, _ := system.memory_create(GUARD_STACK_PAGES)
	address, _ := system.memory_map(memory, {.Write}, 0, GUARD_ADDRESS)
	guard := [1]op.Address_Range{{address = GUARD_ADDRESS, page_count = 1}}
	system.memory_protect(guard[:], {.No_Access})
	bytes := ([^]u8)(address)
	for offset := u64(GUARD_STACK_PAGES * system.PAGE_SIZE) - 8; ; offset -= 8 {
		intrinsics.volatile_store(&bytes[offset], 1)
	}
}

guard_page :: proc "contextless" (ctx: ^system.Context) {
	image_size := ctx.values[system.GRANT_VALUE_IMAGE_SIZE]
	address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {})
	if status != .Succeeded {
		fail("the guard page: no boot image")
		return
	}
	image := ([^]u8)(address)[:image_size]
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_ROLE] = 1
	process, start := system.process_start(system.image_find(image, "address_space"), "address_space child", grants, random.values_with_seed(&process_generator, values), {pages = 2048, processes = 1, threads = 1, processor = 100_000, log_records = 10})
	if start != .Succeeded {
		fail("the guard page: the child did not start")
		return
	}
	defer system.close(process)
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; system.time() < deadline; {
		state, _, _ := system.process_state(process)
		if state == .Stopped {
			break
		}
		system.sleep(system.time() + 10)
	}
	report := system.process_stop_report(process)
	guard_address, guard_vector = report.address, u64(report.vector)
	guard_right = guard_vector == 14 && guard_address >= GUARD_ADDRESS && guard_address < GUARD_ADDRESS + system.PAGE_SIZE
	if !guard_right {
		fail("the guard page: the child did not stop in its guard page")
	}
}

// Random reads over one object of 64 MiB: through large pages, then
// through pages of 4 KiB.
reads :: proc "contextless" (base: [^]u64) -> u64 {
	random := u64(0x2545_F491_4F6C_DD1D)
	sum: u64
	start := system.nanoseconds()
	for _ in 0 ..< RANDOM_READS {
		random ~= random << 13
		random ~= random >> 7
		random ~= random << 17
		sum += intrinsics.volatile_load(&base[random % (LARGE_OBJECT_PAGES * 512)])
	}
	elapsed := system.nanoseconds() - start
	intrinsics.volatile_store(&base[0], sum)
	return elapsed * 10 / RANDOM_READS // Tenths of a nanosecond.
}

large_pages :: proc "contextless" () {
	memory, status := system.memory_create(LARGE_OBJECT_PAGES, flags = {.Large_Pages})
	if status != .Succeeded {
		fail("the large pages: no object")
		return
	}
	defer system.close(memory)
	large, large_status := system.memory_map(memory, {.Write}, 0, LARGE_ADDRESS)
	small, small_status := system.memory_map(memory, {.Write}, 0, SMALL_ADDRESS)
	if large_status != .Succeeded || small_status != .Succeeded {
		fail("the large pages: no mapping")
		return
	}
	defer system.memory_unmap(large)
	defer system.memory_unmap(small)
	report := own_mappings()
	large_mapping, small_mapping := mapping_at(report, LARGE_ADDRESS), mapping_at(report, SMALL_ADDRESS)
	large_flags_right = large_mapping != nil && small_mapping != nil && .Large in large_mapping.flags && .Large not_in small_mapping.flags && large_mapping.present == LARGE_OBJECT_PAGES
	if !large_flags_right {
		fail("the large pages: the report")
	}
	reads(([^]u64)(large)) // Each line in the cache of the host once.
	large_nanoseconds = reads(([^]u64)(large))
	small_nanoseconds = reads(([^]u64)(small))
}

refusal :: proc "contextless" (item: ^Refusal, name: string, expected: call_outcome.Call_Outcome, status: call_outcome.Call_Outcome, record: errors.Error_Record) {
	item.name, item.expected, item.status, item.record = name, expected, status, record
	writer := system.Writer{buffer = item.sentence[:]}
	system.kernel_error_text(&writer, &item.record)
	item.count = len(system.written(&writer))
	if status != expected || record.kind == i64(errors.Kind.Refused) {
		fail("a refusal has another status or no error record")
	}
}

refuse :: proc "contextless" () {
	record: errors.Error_Record
	memory, _ := system.memory_create(64, flags = {.Uncommitted})
	defer system.close(memory)
	outside := [1]op.Page_Range{{first = 60, page_count = 10}}
	_, status := system.memory_commit(memory, outside[:], error = &record)
	refusal(&refusals[0], "a range outside the object", .Argument_Refused, status, record)
	big, _ := system.memory_create(GIGABYTE_PAGES, flags = {.Uncommitted})
	defer system.close(big)
	record = {}
	over := [1]op.Page_Range{{first = 0, page_count = 60_000}} // Under the page limit of one call, over the budget.
	_, status = system.memory_commit(big, over[:], error = &record)
	refusal(&refusals[1], "a commit over the budget", .Budget_Or_Capacity_Exhausted, status, record)
	plain, _ := system.memory_create(4)
	defer system.close(plain)
	address, _ := system.memory_map(plain)
	defer system.memory_unmap(address)
	record = {}
	both := [1]op.Address_Range{{address = u64(uintptr(address)), page_count = 4}}
	_, status = system.memory_protect(both[:], {.Write, .Execute}, &record)
	refusal(&refusals[2], "write and execute", .Argument_Refused, status, record)
	record = {}
	_, status = system.memory_create(100, flags = {.Large_Pages}, error = &record)
	refusal(&refusals[3], "large pages of 100 pages", .Argument_Refused, status, record)
}

// The edge cases of the virtual memory: each one is a case where the
// kernel did something wrong once, and that must stay right. Each one logs
// a line and sets its result.
EDGE_CASES :: 17
edge_case_names := [EDGE_CASES]string{"a small object with no frame keeps the sums of the frames", "an unmap ends the protection of parts: the object is mapped again", "large pages at an address that the kernel chooses", "a table that names one mapping whole and in part is refused", "a decommit wakes a thread that waits on a word of the page", "a word in the second 4 KiB of a large page is its own word", "an object with parts of their own protection is not mapped again", "a small uncommitted object costs a page", "a part cannot get more than its mapping", "a page that is not committed stops with its own stop cause", "a revocation of a large uncommitted mapping wakes its waiter", "an uncommitted object of 1 GiB ends with few pages walked", "a thread whose first instruction is not an address of a process is refused", "a map with a flag that the kernel does not know is refused", "the end of the last thread stops the process with its own stop cause and no stop outcome", "a process gets no Control over itself, and its stop through its own handle is refused", "a holder's stop with an outcome and a stop of itself with no outcome are refused, and nothing stops"}
edge_case_results: [EDGE_CASES]bool

Waiter :: struct #align (64) {
	word:     ^u32,
	value:    u32,
	ended:    u32,
	woke_at:  u64,
	deadline: u64, // The end of the wait: the bound of a hang. A wake before it came from a wake, not from the deadline.
}
waiter: Waiter

wait_run :: proc "c" (parameter: rawptr) -> ! {
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	waiter.deadline = deadline
	system.word_wait(waiter.word, waiter.value, deadline)
	waiter.woke_at = system.time()
	intrinsics.atomic_store(&waiter.ended, 1)
	system.thread_stop()
}

// waiter_start starts a thread that waits on a word, and waits until it
// waits (its state is Waiting). The bound only ends a hang.
waiter_start :: proc "contextless" (word: ^u32) -> system.Thread {
	waiter = {word = word, value = intrinsics.atomic_load(word)}
	thread, _ := system.thread_start(wait_run, nil)
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; system.time() < deadline; {
		results, _ := system.call(.Thread_State, u64(thread.handle))
		if op.Process_State(results[0]) == .Waiting {
			break
		}
		system.sleep(system.time() + 1)
	}
	return thread
}

edge_cases :: proc "contextless" (ctx: ^system.Context) {
	// A thread waits on a word of a committed page; the page is
	// decommitted: the waiter must wake by the decommit, before its
	// deadline.
	{
		memory, _ := system.memory_create(16, flags = {.Uncommitted})
		address, _ := system.memory_map(memory)
		ranges := [1]op.Page_Range{{first = 3, page_count = 1}}
		system.memory_commit(memory, ranges[:])
		word := (^u32)(uintptr(address) + 3 * system.PAGE_SIZE + 64)
		word^ = 7
		thread := waiter_start(word)
		system.memory_decommit(memory, ranges[:])
		for intrinsics.atomic_load(&waiter.ended) == 0 {
			system.sleep(system.time() + 1)
		}
		system.thread_wait(thread)
		edge_case_results[4] = waiter.woke_at < waiter.deadline
		system.memory_unmap(address)
		system.close(memory)
	}
	// One thread waits on a word in the second 4 KiB of a large page; a
	// wake of the word at the same offset of the first 4 KiB wakes nobody,
	// a wake of its own word wakes it.
	{
		memory, _ := system.memory_create(op.LARGE_PAGE_PAGES, flags = {.Large_Pages})
		address, _ := system.memory_map(memory, {.Write}, 0, LARGE_ADDRESS)
		first := (^u32)(uintptr(address) + 128)
		second := (^u32)(uintptr(address) + system.PAGE_SIZE + 128)
		thread := waiter_start(second)
		wrong := system.word_wake(first)
		intrinsics.atomic_add(second, 1)
		woken := system.word_wake(second)
		system.thread_wait(thread)
		edge_case_results[5] = wrong == 0 && woken == 1
		system.memory_unmap(address)
		system.close(memory)
	}
	// A part of a mapping is made No_Access; the object cannot be
	// mapped a second time while it has marks; after the part has the
	// protection of its mapping again, it can.
	{
		memory, _ := system.memory_create(8)
		address, _ := system.memory_map(memory)
		part := [1]op.Address_Range{{address = u64(uintptr(address)) + system.PAGE_SIZE, page_count = 2}}
		system.memory_protect(part[:], {.No_Access})
		record: errors.Error_Record
		second, refused := system.memory_map(memory, error = &record)
		if refused == .Succeeded {
			system.memory_unmap(second)
		}
		system.memory_protect(part[:], {.Write})
		third, allowed := system.memory_map(memory)
		if allowed == .Succeeded {
			system.memory_unmap(third)
		}
		edge_case_results[6] = refused == .Wrong_State && record.kind != i64(errors.Kind.Refused) && allowed == .Succeeded
		system.memory_unmap(address)
		system.close(memory)
	}
	// A budget with no page cannot hold a slot of the table of memory
	// objects with an uncommitted object of 4 pages.
	{
		empty, _ := system.budget_create({pages = 0})
		memory, status := system.memory_create(4, empty, {.Uncommitted})
		if status == .Succeeded {
			system.close(memory)
		}
		system.close(empty)
		edge_case_results[7] = status == .Budget_Or_Capacity_Exhausted
	}
	// The whole mapping becomes read only; a part of it cannot become
	// writable alone: refused, not a success that changes nothing.
	{
		memory, _ := system.memory_create(8)
		address, _ := system.memory_map(memory)
		whole := [1]op.Address_Range{{address = u64(uintptr(address)), page_count = 8}}
		part := [1]op.Address_Range{{address = u64(uintptr(address)), page_count = 2}}
		system.memory_protect(whole[:], {})
		record: errors.Error_Record
		_, status := system.memory_protect(part[:], {.Write}, &record)
		edge_case_results[8] = status == .Argument_Refused && record.kind != i64(errors.Kind.Refused)
		system.memory_unmap(address)
		system.close(memory)
	}
	// A child touches a page of an uncommitted object that is not committed:
	// it stops with the stop cause of a page that is not committed.
	not_committed_cause, _ := child_stop_cause(ctx, 3)
	edge_case_results[9] = not_committed_cause == .Not_Committed
	// A child whose one thread ends: the kernel stops it with the cause of
	// the end of its last thread, never as a stop of itself.
	last_thread_cause, last_thread_outcome := child_stop_cause(ctx, 5)
	edge_case_results[14] = last_thread_cause == .Last_Thread_Ended && last_thread_outcome == .None
	edge_case_results[15], edge_case_results[16] = own_handle_stop(ctx)
	// An Uncommitted object of 1 page, then a report: the test build
	// checks the sums of the frames at each report (a page that such an
	// object pays and that no count names stops the machine), and the free
	// pages less the reserved pages
	// are the pages of the budgets.
	{
		memory, _ := system.memory_create(1, flags = {.Uncommitted})
		report: op.System_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
		system.close(memory)
		after: op.System_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&after)), size_of(after))
		edge_case_results[0] = report.free_pages - report.reserved_pages == report.budget_pages && after.free_pages - after.reserved_pages == after.budget_pages
	}
	// A part of the only mapping gets No_Access, the mapping ends, and
	// the object is mapped again.
	{
		memory, _ := system.memory_create(8)
		address, _ := system.memory_map(memory)
		part := [1]op.Address_Range{{address = u64(uintptr(address)), page_count = 2}}
		system.memory_protect(part[:], {.No_Access})
		system.memory_unmap(address)
		again, status := system.memory_map(memory)
		if status == .Succeeded {
			bytes := ([^]u8)(again)
			bytes[0] = 1 // The page has no mark: no fault.
			system.memory_unmap(again)
		}
		edge_case_results[1] = status == .Succeeded
		system.close(memory)
	}
	// An object of large pages at an address that the kernel chooses.
	{
		memory, _ := system.memory_create(op.LARGE_PAGE_PAGES, flags = {.Large_Pages})
		address, status := system.memory_map(memory)
		report := own_mappings()
		mapping := mapping_at(report, u64(uintptr(address)))
		edge_case_results[2] = status == .Succeeded && mapping != nil && .Large in mapping.flags
		system.memory_unmap(address)
		system.close(memory)
	}
	// One table: the whole mapping read only, and a part of it writable.
	{
		memory, _ := system.memory_create(8)
		address, _ := system.memory_map(memory)
		ranges := [2]op.Address_Range{{address = u64(uintptr(address)), page_count = 8}, {address = u64(uintptr(address)), page_count = 2}}
		_, status := system.memory_protect(ranges[:], {.Write})
		edge_case_results[3] = status == .Argument_Refused
		system.memory_unmap(address)
		system.close(memory)
	}
	edge_case_results[10] = revocation_wakes_waiter(ctx)
	edge_case_results[11] = large_object_ends_quickly()
	{
		// An address that is not canonical, then one in the half of the
		// kernel: the kernel refuses each, and the machine goes on.
		_, not_canonical := system.call_with_error(nil, .Thread_Create, u64(system.own_budget()), 0x0000_8000_0000_0000, op.USER_END, 0)
		_, of_the_kernel := system.call_with_error(nil, .Thread_Create, u64(system.own_budget()), 0xFFFF_FFFF_8000_0000, op.USER_END, 0)
		_, stack_past_the_end := system.call_with_error(nil, .Thread_Create, u64(system.own_budget()), op.USER_END - 4096, 0x0000_9000_0000_0000, 0)
		edge_case_results[12] = not_canonical == .Argument_Refused && of_the_kernel == .Argument_Refused && stack_past_the_end == .Argument_Refused
	}
	{
		// A bit of the flags with no meaning, alone and beside a flag that
		// has one: each is refused with a record that names the flags, and
		// the object is still mapped with the flags that the kernel knows.
		// The first bit past the last member: a fixed bit becomes a known
		// flag when the enum grows, and the case would then test that flag.
		first_unknown_bit := u64(1) << (u64(max(op.Map_Flag)) + 1)
		memory, _ := system.memory_create(1)
		alone_record, beside_record: errors.Error_Record
		_, alone := system.call_with_error(&alone_record, .Memory_Map, u64(memory), 0, 0, first_unknown_bit, 0, 0)
		_, beside := system.call_with_error(&beside_record, .Memory_Map, u64(memory), 0, 0, 1 << 63 | transmute(u64)op.Map_Flags{.Write}, 0, 0)
		address, known := system.memory_map(memory, {.Write})
		edge_case_results[13] = alone == .Argument_Refused && beside == .Argument_Refused && alone_record.kind == i64(errors.Kind.Bad_Flags) && alone_record.argument == 4 && beside_record.kind == i64(errors.Kind.Bad_Flags) && known == .Succeeded
		system.memory_unmap(address)
		system.close(memory)
	}
	for name, index in edge_case_names {
		system.log_fact(.Info, Edge_Case{verdict = value_kinds.text_field(edge_case_results[index] ? "right" : "WRONG", 16), case_name = value_kinds.text_field(name, 104)})
		if !edge_case_results[index] {
			fail("an edge case")
		}
	}
}

// A child waits on a word of a mapping of 1 GiB of an Uncommitted object of
// this process; this process revokes the object in the child. The kernel
// wakes the waiter before the frames of the object leave the child: the
// revocation looks for the frames of the words with one sorted search over
// the frames of the object, not with one walk of the object for each word,
// so it ends quickly with an object of 1 GiB. The time of the revocation is
// logged; the check is only that the waiter woke: it waits with no deadline,
// so only the revocation can wake it.
REVOCATION_WORD_PAGE :: 100
GRANT_REVOCATION_OBJECT :: 0
GRANT_REVOCATION_BOARD :: 1

Revocation_Board :: struct {
	ready: u32, // The child maps the object and is about to wait.
	woken: u32, // The child woke.
}

// child_waits_on_object is the child of the role 4.
child_waits_on_object :: proc "contextless" (ctx: ^system.Context) -> ! {
	board_address, _ := system.memory_map(ctx.handles[GRANT_REVOCATION_BOARD])
	board := (^Revocation_Board)(board_address)
	object, _ := system.memory_map(ctx.handles[GRANT_REVOCATION_OBJECT])
	word := (^u32)(uintptr(object) + REVOCATION_WORD_PAGE * system.PAGE_SIZE)
	value := intrinsics.atomic_load(word)
	intrinsics.atomic_store(&board.ready, 1)
	system.word_wake(&board.ready)
	system.word_wait(word, value)
	intrinsics.atomic_store(&board.woken, 1)
	system.word_wake(&board.woken)
	for {
		system.sleep(system.time() + 1000)
	}
}

revocation_wakes_waiter :: proc "contextless" (ctx: ^system.Context) -> bool {
	object, created := system.memory_create(GIGABYTE_PAGES, flags = {.Uncommitted})
	if created != .Succeeded {
		return false
	}
	defer system.close(object)
	one := [1]op.Page_Range{{first = REVOCATION_WORD_PAGE, page_count = 1}}
	system.memory_commit(object, one[:])
	board_memory, _ := system.memory_create(1)
	defer system.close(board_memory)
	board_address, _ := system.memory_map(board_memory)
	defer system.memory_unmap(board_address)
	board := (^Revocation_Board)(board_address)
	image_address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {})
	if status != .Succeeded {
		return false
	}
	image := ([^]u8)(image_address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	grants: [op.CONTEXT_HANDLES]system.Grant
	grants[GRANT_REVOCATION_OBJECT] = {object, {.Read, .Write}}
	grants[GRANT_REVOCATION_BOARD] = {board_memory, {.Read, .Write}}
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_ROLE] = 4
	process, start := system.process_start(system.image_find(image, "address_space"), "address_space waiter", grants, random.values_with_seed(&process_generator, values), {pages = 2048, processes = 1, threads = 1, processor = 100_000, log_records = 10})
	if start != .Succeeded {
		return false
	}
	defer system.close(process)
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; intrinsics.atomic_load(&board.ready) == 0 && system.time() < deadline; {
		system.word_wait(&board.ready, 0, system.time() + 100)
	}
	// The revocation must find the child in its wait: its one thread is
	// not Ready.
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; system.time() < deadline; {
		if state, _, _ := system.process_state(process); state == .Waiting {
			break
		}
		system.sleep(system.time() + 1)
	}
	revoke_start := system.nanoseconds()
	system.handle_revoke(object, process)
	revoke_time := system.nanoseconds() - revoke_start
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; intrinsics.atomic_load(&board.woken) == 0 && system.time() < deadline; {
		system.word_wait(&board.woken, 0, system.time() + 100)
	}
	woke := intrinsics.atomic_load(&board.woken) != 0
	system.log_fact(.Info, Revocation_Of_Large_Mapping{revocation = value_kinds.Time_In_Microseconds(revoke_time / 1000), waiter = value_kinds.text_field(woke ? "woke" : "did not wake", 16)})
	system.process_stop(process)
	return woke
}

// An Uncommitted object of 1 GiB with 4 pages that have a frame ends: the
// unmap clears the present entries and stops after the last of them; the
// release gives the frames back and stops after the last frame. The time
// is logged; the check is that each page returned to the budget.
large_object_ends_quickly :: proc "contextless" () -> bool {
	before, _ := system.budget_read()
	object, created := system.memory_create(GIGABYTE_PAGES, flags = {.Uncommitted})
	if created != .Succeeded {
		return false
	}
	first := [1]op.Page_Range{{first = 0, page_count = 4}}
	system.memory_commit(object, first[:])
	address, status := system.memory_map(object)
	if status != .Succeeded {
		system.close(object)
		return false
	}
	bytes := ([^]u8)(address)
	for page in 0 ..< 4 {
		bytes[page * system.PAGE_SIZE] = 1
	}
	start := system.nanoseconds()
	system.memory_unmap(address)
	system.close(object)
	ended := system.nanoseconds() - start
	after, _ := system.budget_read()
	// The 513 page tables of the mapping return with the unmap.
	kept := before.pages - after.pages
	system.log_fact(.Info, Large_Object_Ended{unmap_and_close = value_kinds.Time_In_Microseconds(ended / 1000), pages_kept = u64(kept)})
	return kept == 0
}

// child_stop_cause starts the child with a role and gives its stop cause
// and its stop outcome: None when it did not start or did not stop within
// the hang bound.
child_stop_cause :: proc "contextless" (ctx: ^system.Context, role: u64) -> (cause: op.Stop_Cause, outcome: op.Stop_Outcome) {
	address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {})
	if status != .Succeeded {
		return .None, .None
	}
	image := ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_ROLE] = role
	process, start := system.process_start(system.image_find(image, "address_space"), "address_space child", grants, random.values_with_seed(&process_generator, values), {pages = 2048, processes = 1, threads = 1, processor = 100_000, log_records = 10})
	if start != .Succeeded {
		return .None, .None
	}
	defer system.close(process)
	cause, outcome, _ = system.process_stop_wait(process, system.time() + system.TEST_HANG_BOUND_MILLISECONDS)
	return cause, outcome
}

// The child of the role 5: its one thread ends with Thread_Stop, and the
// process stops with no stop of its own.
child_last_thread :: proc "contextless" () -> ! {
	system.thread_stop()
}

// The page that the parent shares with the child of the role 6.
Own_Handle_Board :: struct {
	handle: u64, // The number in the child of its own process handle, which the parent gave.
	given:  u32, // 1: handle is written.
	status: u32, // The status of the Process_Stop of the child through that handle, plus 1 (0: none).
}

// The child of the role 6 tries to stop itself through a handle of its own
// process, as a holder does. A process never holds Control over itself: the
// give takes Control away, so the kernel refuses the stop with No_Right,
// before it reads the outcome word. The child then writes the status and
// stops itself with `Done`. Any other status, or a stop that went through,
// is a fault that the parent sees.
child_stop_by_own_handle :: proc "contextless" (ctx: ^system.Context) -> ! {
	address, mapped := system.memory_map(ctx.handles[GRANT_REVOCATION_BOARD])
	if mapped != .Succeeded {
		system.log_fact(.Info, Own_Handle_Child_Board_Not_Mapped{map_status = mapped})
		system.stop(.Failed)
	}
	board := (^Own_Handle_Board)(address)
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; intrinsics.atomic_load(&board.given) == 0 && system.time() < deadline; {
		system.word_wait(&board.given, 0, system.time() + 100)
	}
	if intrinsics.atomic_load(&board.given) == 0 {
		system.log_fact(.Info, Own_Handle_Child_Without_Handle{})
		system.stop(.Failed)
	}
	status := system.process_stop(system.Handle(intrinsics.volatile_load(&board.handle)))
	intrinsics.atomic_store(&board.status, u32(status) + 1)
	system.stop(.Done)
}

// own_handle_stop starts the child of the role 6, gives it its own process
// handle with Read and Control, and checks that the give took Control away:
// the stop of the child through that handle is refused with No_Right, and
// the child then stops itself with the stop cause Itself and the outcome
// Done. Before the give, while the child waits for its handle, it gives the
// kernel the words of Process_Stop that it must refuse (stop_word_refusals).
own_handle_stop :: proc "contextless" (ctx: ^system.Context) -> (own_handle_right: bool, stop_words_right: bool) {
	board_memory, created := system.memory_create(1)
	if created != .Succeeded {
		return false, false
	}
	defer system.close(board_memory)
	board_address, _ := system.memory_map(board_memory)
	defer system.memory_unmap(board_address)
	board := (^Own_Handle_Board)(board_address)
	image_address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {})
	if status != .Succeeded {
		return false, false
	}
	image := ([^]u8)(image_address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	grants: [op.CONTEXT_HANDLES]system.Grant
	grants[GRANT_REVOCATION_BOARD] = {board_memory, {.Read, .Write}}
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_ROLE] = 6
	process, start := system.process_start(system.image_find(image, "address_space"), "address_space own handle", grants, random.values_with_seed(&process_generator, values), {pages = 2048, processes = 1, threads = 1, processor = 100_000, log_records = 10})
	if start != .Succeeded {
		return false, false
	}
	defer system.close(process)
	stop_words_right = stop_word_refusals(process)
	own_handle, given := system.give(process, process, {.Read, .Control})
	intrinsics.volatile_store(&board.handle, u64(own_handle))
	intrinsics.atomic_store(&board.given, 1)
	system.word_wake(&board.given)
	cause, outcome, _ := system.process_stop_wait(process, system.time() + system.TEST_HANG_BOUND_MILLISECONDS)
	refused := intrinsics.atomic_load(&board.status) == u32(call_outcome.Call_Outcome.Grant_Or_Right_Missing) + 1
	// The stop of itself is the one cause with an outcome: the sentence of
	// another cause has no outcome, as the stop line of the root service.
	stop_verdict: string = refused ? "was refused with Grant_Or_Right_Missing" : "was not refused with Grant_Or_Right_Missing"
	if cause == .Itself {
		system.log_fact(.Info, Own_Handle_Child_Stopped{give_status = given, cause = cause, outcome = outcome, stop_verdict = value_kinds.text_field(stop_verdict, 48)})
	} else {
		system.log_fact(.Info, Own_Handle_Child_Stopped_Without_Outcome{give_status = given, cause = cause, stop_verdict = value_kinds.text_field(stop_verdict, 44)})
	}
	return given == .Succeeded && refused && outcome == .Done, stop_words_right
}

// stop_word_refusals gives the kernel the words of Process_Stop that it must
// refuse, in command records, as a writer of the kernel ring that skips the
// library does: a stop of a child that runs with an outcome, which only the
// child can say, and a stop of this process with no outcome or with a word
// past the last outcome. Each one must give Bad_Operation with the record
// Bad_Value of the argument 2, its word and the limit of its target (0 for
// a holder, the last outcome for the caller), and change nothing: the
// child still runs, and this process goes on to its next line. The edges
// come first; the last case is the largest word.
stop_word_refusals :: proc "contextless" (child: system.Handle) -> bool {
	Refused_Stop :: struct {
		target: u64, // 0: this process.
		word:   u64,
		limit:  i64,
	}
	refused := [?]Refused_Stop {
		{u64(child), u64(op.Stop_Outcome.Done), 0},
		{u64(child), u64(op.Stop_Outcome.Stopped_On_Request), 0},
		{u64(child), u64(max(op.Stop_Outcome)) + 1, 0},
		// No low bit: a kernel that read 32 bits of the word would take it
		// for 0 and stop the child.
		{u64(child), u64(1) << 32, 0},
		{u64(child), max(u64), 0},
		{0, u64(op.Stop_Outcome.None), i64(max(op.Stop_Outcome))},
		{0, u64(max(op.Stop_Outcome)) + 1, i64(max(op.Stop_Outcome))},
		{0, u64(max(u32)) + 1 + u64(op.Stop_Outcome.Done), i64(max(op.Stop_Outcome))},
		{0, max(u64), i64(max(op.Stop_Outcome))},
	}
	wrong := 0
	for item in refused {
		commands := [1]ring.Record{{kind = u32(op.Operation.Process_Stop), values = {0 = item.target, 1 = item.word}}}
		completions: [1]ring.Record
		if _, status := system.commands_call(commands[:], completions[:]); status != .Succeeded {
			system.log_fact(.Info, Stop_Command_Refused_By_Library{stop_word = item.word, call_status = call_outcome.Call_Outcome_Word(status)})
			wrong += 1
			continue
		}
		record := transmute(errors.Error_Record)completions[0].values
		if completions[0].kind != u32(call_outcome.Call_Outcome.Argument_Refused) || record.kind != i64(errors.Kind.Bad_Value) || record.argument != 2 || record.value != i64(item.word) || record.limit != item.limit {
			system.log_fact(.Info, Stop_Word_Not_Refused{stop_word = item.word, status_word = call_outcome.Call_Outcome_Word(completions[0].kind), error_kind = errors.Kind_Word(record.kind), argument = record.argument, limit = record.limit, target = value_kinds.text_field(item.target == 0 ? "this process" : "a child", 16)})
			wrong += 1
		}
	}
	state, _, _ := system.process_state(child)
	if state == .Stopped {
		system.log_fact(.Info, Refused_Stop_Stopped_Child{})
		wrong += 1
	}
	return wrong == 0
}

// The child of the role 3: it touches a page that is not committed.
child_not_committed :: proc "contextless" () -> ! {
	memory, _ := system.memory_create(16, flags = {.Uncommitted})
	address, _ := system.memory_map(memory)
	intrinsics.volatile_store(&([^]u8)(address)[5 * system.PAGE_SIZE], 1)
	// The write must stop the child: past it, the case failed.
	system.stop(.Failed)
}

// The delegation of a commit (docs/ARCHITECTURE.md, "Who pays a commit"): this
// process A makes a child budget and an uncommitted object on it, and gives
// a second process B the object (Read, Write) and the child budget with the
// right Commit only. B runs the cases of the amendment of the read, one at
// a time on a board that the two map; A acts between them (revocations, a
// decommit, the end of the child budget). Each case logs its line with the
// sentence of its error record.
DELEGATION_OBJECT_PAGES :: 64
DELEGATION_BUDGET_PAGES :: 33 // 1 page of the frame list, then 32 pages that B can commit.
DELEGATION_CASES :: 10
GRANT_DELEGATION_BOARD :: 0
GRANT_DELEGATION_OBJECT :: 1
GRANT_DELEGATION_BUDGET :: 2 // The child budget, with Commit only.
GRANT_DELEGATION_SPEND :: 3 // A second child budget with Spend: does a revocation end what B made with it?

Delegation_Result :: struct {
	status:   call_outcome.Call_Outcome,
	record:   errors.Error_Record,
	value:    u64,
}

Delegation_Board :: struct {
	step:    u32, // A writes the case that B runs now.
	done:    u32, // B writes the case that it ran.
	results: [DELEGATION_CASES + 1]Delegation_Result,
}

delegation_names := [DELEGATION_CASES + 1]string {
	"",
	"1 B commits 32 pages, then one more",
	"2 B commits with no budget handle; it reads and writes the committed pages",
	"3 B makes an object with the handle that has Commit only",
	"4 B commits with a budget that does not pay for the object",
	"5 A revokes the budget handle of B: B commits no more",
	"6 A takes the pages back: it revokes the object of B, then decommits",
	"7 B decommits pages of an object that A holds too",
	"8 the child budget ends: the object moves to the budget of A",
	"9 B gives its Commit handle on: it has no right Give",
	"10 an object that B made with a Spend handle, after the revocation",
}
delegation_right: [DELEGATION_CASES + 1]bool
delegation_lines: [DELEGATION_CASES + 1][200]u8
delegation_line_counts: [DELEGATION_CASES + 1]int

// child_delegate is B: it runs case n when A writes n, and writes its result.
child_delegate :: proc "contextless" (ctx: ^system.Context) -> ! {
	address, _ := system.memory_map(ctx.handles[GRANT_DELEGATION_BOARD])
	board := (^Delegation_Board)(address)
	memory := ctx.handles[GRANT_DELEGATION_OBJECT]
	budget := ctx.handles[GRANT_DELEGATION_BUDGET]
	spend := ctx.handles[GRANT_DELEGATION_SPEND]
	object, _ := system.memory_map(memory)
	bytes := ([^]u8)(object)
	made: system.Handle
	seen: u32
	for {
		step := intrinsics.atomic_load(&board.step)
		if step == seen {
			system.word_wait(&board.step, step, system.time() + 1000)
			continue
		}
		seen = step
		result := &board.results[step]
		switch step {
		case 1:
			first := [1]op.Page_Range{{first = 0, page_count = 32}}
			if _, status := system.memory_commit(memory, first[:], budget); status == .Succeeded {
				one := [1]op.Page_Range{{first = 32, page_count = 1}}
				_, result.status = system.memory_commit(memory, one[:], budget, &result.record)
			}
		case 2:
			ranges := [1]op.Page_Range{{first = 40, page_count = 1}}
			_, result.status = system.call_with_error(&result.record, .Memory_Commit, u64(memory), 0, u64(uintptr(&ranges[0])), 1, 0)
			bytes[5 * system.PAGE_SIZE] = 55
			result.value = u64(bytes[5 * system.PAGE_SIZE])
		case 3:
			_, result.status = system.memory_create(1, budget, error = &result.record)
		case 4:
			ranges := [1]op.Page_Range{{first = 33, page_count = 1}}
			_, result.status = system.memory_commit(memory, ranges[:], system.own_budget(), &result.record)
		case 5:
			ranges := [1]op.Page_Range{{first = 34, page_count = 1}}
			_, result.status = system.memory_commit(memory, ranges[:], budget, &result.record)
			// The object that B made with the Spend handle before the revocation.
			result.value, _ = system.memory_size(made)
		case 7:
			ranges := [1]op.Page_Range{{first = 0, page_count = 32}}
			_, result.status = system.memory_decommit(memory, ranges[:], &result.record)
		case 9:
			_, result.status = system.give(ctx.handles[GRANT_DELEGATION_BOARD], budget, {.Commit}, &result.record)
		case 10:
			made, result.status = system.memory_create(1, spend, error = &result.record)
		}
		intrinsics.atomic_store(&board.done, step)
		system.word_wake(&board.done)
	}
}

delegation_run :: proc "contextless" (board: ^Delegation_Board, step: u32) -> ^Delegation_Result {
	intrinsics.atomic_store(&board.step, step)
	system.word_wake(&board.step)
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; intrinsics.atomic_load(&board.done) != step && system.time() < deadline; {
		system.word_wait(&board.done, intrinsics.atomic_load(&board.done), system.time() + 100)
	}
	return &board.results[step]
}

delegation_note :: proc "contextless" (step: int, right: bool, result: ^Delegation_Result, parts: ..system.Part) {
	delegation_right[step] = right
	writer := system.Writer{buffer = delegation_lines[step][:]}
	for part in parts {
		system.write_part(&writer, part)
	}
	if result != nil && result.status != .Succeeded {
		system.kernel_error_text(&writer, &result.record)
	}
	delegation_line_counts[step] = len(system.written(&writer))
	// The caller writes the fact of the step: each step is a fact type of
	// its own, with the record of the call of B.
	if !right {
		fail("a case of the delegation")
	}
}

// delegation_verdict gives the verdict field of the fact of a step.
delegation_verdict :: proc "contextless" (right: bool) -> [16]u8 {
	return value_kinds.text_field(right ? "as expected" : "WRONG", 16)
}

delegation :: proc "contextless" (ctx: ^system.Context) {
	address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {})
	if status != .Succeeded {
		fail("the delegation: no boot image")
		return
	}
	image := ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	child_budget, _ := system.budget_create({pages = DELEGATION_BUDGET_PAGES})
	spend_budget, _ := system.budget_create({pages = 8})
	object, _ := system.memory_create(DELEGATION_OBJECT_PAGES, child_budget, {.Uncommitted})
	board_memory, _ := system.memory_create(1)
	board_address, _ := system.memory_map(board_memory)
	board := (^Delegation_Board)(board_address)
	grants: [op.CONTEXT_HANDLES]system.Grant
	grants[GRANT_DELEGATION_BOARD] = {board_memory, {.Read, .Write}}
	grants[GRANT_DELEGATION_OBJECT] = {object, {.Read, .Write}}
	grants[GRANT_DELEGATION_BUDGET] = {child_budget, {.Commit}}
	grants[GRANT_DELEGATION_SPEND] = {spend_budget, {.Spend}}
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_ROLE] = 2
	process, start := system.process_start(system.image_find(image, "address_space"), "address_space delegate", grants, random.values_with_seed(&process_generator, values), {pages = 512, processes = 1, threads = 1, processor = 100_000, log_records = 50})
	if start != .Succeeded {
		fail("the delegation: B did not start")
		return
	}
	defer system.close(process)

	// A record of 0 when the call of B succeeded: its kind is None.
	record_of :: proc "contextless" (result: ^Delegation_Result) -> errors.Error_Record_Fact_Fields {
		return errors.error_record_fact_fields(result.status != .Succeeded ? result.record : errors.Error_Record{})
	}
	result := delegation_run(board, 1)
	step_right := result.status == .Budget_Or_Capacity_Exhausted && result.record.kind == i64(errors.Kind.Budget_Hidden)
	delegation_note(1, step_right, result, "32 pages committed; the 33rd: ")
	fields := record_of(result)
	system.log_fact(.Info, Delegation_Commit_Past_Budget{kind = fields.kind, unit = fields.unit, operation = fields.operation, argument = fields.argument, value = fields.value, limit = fields.limit, found = fields.found, verdict = delegation_verdict(step_right)})
	result = delegation_run(board, 2)
	step_right = result.status == .Argument_Refused && result.value == 55
	delegation_note(2, step_right, result, "B wrote and read 55 in a committed page; a commit: ")
	fields = record_of(result)
	system.log_fact(.Info, Delegation_Commit_Without_Budget{kind = fields.kind, unit = fields.unit, operation = fields.operation, argument = fields.argument, value = fields.value, limit = fields.limit, found = fields.found, verdict = delegation_verdict(step_right)})
	result = delegation_run(board, 3)
	step_right = result.status == .Grant_Or_Right_Missing
	delegation_note(3, step_right, result, "")
	fields = record_of(result)
	system.log_fact(.Info, Delegation_Object_With_Commit_Only{kind = fields.kind, unit = fields.unit, operation = fields.operation, argument = fields.argument, value = fields.value, limit = fields.limit, found = fields.found, verdict = delegation_verdict(step_right)})
	result = delegation_run(board, 4)
	step_right = result.status == .Argument_Refused && result.record.kind == i64(errors.Kind.Not_Payer)
	delegation_note(4, step_right, result, "")
	fields = record_of(result)
	system.log_fact(.Info, Delegation_Commit_With_Other_Payer{kind = fields.kind, unit = fields.unit, operation = fields.operation, argument = fields.argument, value = fields.value, limit = fields.limit, found = fields.found, verdict = delegation_verdict(step_right)})
	result = delegation_run(board, 7)
	step_right = result.status == .Wrong_State && result.record.kind == i64(errors.Kind.Object_Shared)
	delegation_note(7, step_right, result, "")
	fields = record_of(result)
	system.log_fact(.Info, Delegation_Decommit_Of_Shared_Object{kind = fields.kind, unit = fields.unit, operation = fields.operation, argument = fields.argument, value = fields.value, limit = fields.limit, found = fields.found, verdict = delegation_verdict(step_right)})
	result = delegation_run(board, 9)
	step_right = result.status == .Grant_Or_Right_Missing
	delegation_note(9, step_right, result, "")
	fields = record_of(result)
	system.log_fact(.Info, Delegation_Give_Without_Right{kind = fields.kind, unit = fields.unit, operation = fields.operation, argument = fields.argument, value = fields.value, limit = fields.limit, found = fields.found, verdict = delegation_verdict(step_right)})
	result = delegation_run(board, 10)
	made := result.status == .Succeeded
	// 5: A revokes the two budget handles of B.
	system.handle_revoke(child_budget, process)
	system.handle_revoke(spend_budget, process)
	held, _ := system.budget_read(child_budget)
	result = delegation_run(board, 5)
	step_right = result.status == .Argument_Refused && result.record.kind == i64(errors.Kind.Handle_Ended) && held.pages == 0
	delegation_note(5, step_right, result, "the 32 pages stay committed and paid (the child budget holds 0); a commit: ")
	fields = record_of(result)
	system.log_fact(.Info, Delegation_Commit_After_Revocation{kind = fields.kind, unit = fields.unit, operation = fields.operation, argument = fields.argument, value = fields.value, limit = fields.limit, found = fields.found, verdict = delegation_verdict(step_right)})
	// 10: the object that B made with the Spend handle stays: a revocation
	// ends the holdings that came from the handle (handles and mappings),
	// not the objects that were made with it.
	lives_on := made && result.value == 1
	delegation_note(10, lives_on, nil, lives_on ? "the object of 1 page that B made with it lives on after the revocation, paid by the child budget, and A cannot end it: the narrow right Commit makes no object" : "the object did not stay")
	if lives_on {
		system.log_fact(.Info, Delegation_Object_Lives_On{verdict = delegation_verdict(lives_on)})
	} else {
		system.log_fact(.Info, Delegation_Object_Gone{verdict = delegation_verdict(lives_on)})
	}
	// 6: A revokes the object of B (B is unmapped), then decommits.
	system.handle_revoke(object, process)
	before, _ := system.budget_read(child_budget)
	everything := [1]op.Page_Range{{first = 0, page_count = DELEGATION_OBJECT_PAGES}}
	returned, decommit := system.memory_decommit(object, everything[:])
	after, _ := system.budget_read(child_budget)
	step_right = decommit == .Succeeded && returned == 32 && after.pages - before.pages == 32
	delegation_note(6, step_right, nil, decommit == .Succeeded ? "32 pages back in the child budget; A held the object with no mapping" : "the decommit was refused")
	if decommit == .Succeeded {
		system.log_fact(.Info, Delegation_Pages_Taken_Back{verdict = delegation_verdict(step_right)})
	} else {
		system.log_fact(.Info, Delegation_Pages_Not_Taken_Back{verdict = delegation_verdict(step_right)})
	}
	// 8: A closes the child budget: the object moves to the budget of A,
	// and a commit needs the budget of A now; the old handle names nothing.
	system.close(child_budget)
	record: errors.Error_Record
	one := [1]op.Page_Range{{first = 0, page_count = 1}}
	_, old := system.memory_commit(object, one[:], child_budget, &record)
	committed, now := system.memory_commit(object, one[:])
	step_right = old == .Argument_Refused && now == .Succeeded && committed == 1
	delegation_note(8, step_right, nil, now == .Succeeded ? "a commit with the budget of A: 1 page; with the old handle: refused" : "the commit with the budget of A was refused")
	if now == .Succeeded {
		system.log_fact(.Info, Delegation_Object_Moved{verdict = delegation_verdict(step_right)})
	} else {
		system.log_fact(.Info, Delegation_Object_Not_Moved{verdict = delegation_verdict(step_right)})
	}
	system.close(object)
	system.close(spend_budget)
	system.process_stop(process)
	system.memory_unmap(board_address)
	system.close(board_memory)
}

// The addresses that the kernel chooses are used again (a kernel that
// never reuses a range of addresses runs out of them): one object mapped
// and unmapped 100 000 times
// costs the budget the same as one time.
reuse_right: bool
reuse_pages_first, reuse_pages_last: u64

addresses_reused :: proc "contextless" () {
	memory, _ := system.memory_create(4)
	defer system.close(memory)
	for round in 0 ..< 100_000 {
		address, status := system.memory_map(memory)
		if status != .Succeeded {
			fail("the reuse of addresses: a map was refused")
			return
		}
		system.memory_unmap(address)
		if round == 0 {
			first, _ := system.budget_read()
			reuse_pages_first = first.pages
		}
	}
	last, _ := system.budget_read()
	reuse_pages_last = last.pages
	reuse_right = reuse_pages_first == reuse_pages_last
	if !reuse_right {
		fail("the reuse of addresses: the budget paid for more page tables")
	}
}

// The page tables that a mapping made return to the budget with its unmap
// (docs/ARCHITECTURE.md, "The page tables of a process"). The addresses are
// SPREAD_STRIDE apart: 512 GiB, 1 GiB and 2 MiB, so each one has its own
// entry of the top table, of the third level and of the second level, and a
// mapping there needs three new tables. No other mapping of this process is
// in that band.
SPREAD_ADDRESS :: fixed_addresses.OWN_CHOICE_START + 0x0000_0400_0000_0000
SPREAD_STRIDE :: 0x0000_0080_4020_0000
SPREAD_COUNT :: 64
#assert(SPREAD_ADDRESS >= fixed_addresses.OWN_CHOICE_START && SPREAD_ADDRESS > GUARD_ADDRESS)
#assert(SPREAD_ADDRESS + (SPREAD_COUNT + 4) * SPREAD_STRIDE < op.THREAD_AREA_BASE &~ (512 << 30 - 1))
#assert(SPREAD_STRIDE % (2 << 20) == 0) // Each address can hold a large page.
NEIGHBOUR_ROUNDS :: 1000
RESERVATION_PAGES :: 1024 // 4 MiB from an address on 2 MiB: two tables of the last level.

Neighbour :: struct #align (64) {
	word:    ^u64,
	stop:    u32,
	wrong:   u32,
	touches: u64,
}
neighbour: Neighbour

// neighbour_touch writes and reads a word of a page in the same table of the
// last level as the pages that the other thread maps and unmaps. A fault
// here stops this process: the line "ok" never comes.
neighbour_touch :: proc "c" (parameter: rawptr) -> ! {
	for intrinsics.atomic_load(&neighbour.stop) == 0 {
		value := intrinsics.atomic_load(&neighbour.touches) + 1
		intrinsics.volatile_store(neighbour.word, value)
		if intrinsics.volatile_load(neighbour.word) != value {
			intrinsics.atomic_store(&neighbour.wrong, 1)
		}
		intrinsics.atomic_store(&neighbour.touches, value)
	}
	system.thread_stop()
}

// page_tables_verdict gives the verdict of a case of the page tables for
// its fact, and notes the fault of a case that did not hold. The caller
// writes the fact first, so the line comes before the fault.
page_tables_verdict :: proc "contextless" (right_case: bool) -> [16]u8 {
	return value_kinds.text_field(right_case ? "as it must" : "WRONG", 16)
}

page_tables_case_end :: proc "contextless" (right_case: bool) {
	if !right_case {
		fail("a page table did not return to the budget")
	}
}

page_tables_return :: proc "contextless" () {
	// 1. One page at 64 addresses: three tables while it is mapped, none
	// after.
	{
		memory, _ := system.memory_create(1)
		before, _ := system.budget_read()
		least_paid, most_paid, kept: u64 = max(u64), 0, 0
		mapped_all := true
		for index in u64(0) ..< SPREAD_COUNT {
			address, status := system.memory_map(memory, {.Write}, 0, SPREAD_ADDRESS + index * SPREAD_STRIDE)
			if status != .Succeeded {
				mapped_all = false
				break
			}
			intrinsics.volatile_store((^u64)(address), index)
			during, _ := system.budget_read()
			least_paid = min(least_paid, before.pages - during.pages)
			most_paid = max(most_paid, before.pages - during.pages)
			system.memory_unmap(address)
			after, _ := system.budget_read()
			kept = max(kept, before.pages - after.pages)
		}
		system.close(memory)
		right_case := mapped_all && least_paid == 3 && most_paid == 3 && kept == 0
		system.log_fact(.Info, Page_Tables_Of_Spread_Mappings{mappings = u64(SPREAD_COUNT), least_paid = least_paid, most_paid = most_paid, pages_kept = kept, verdict = page_tables_verdict(right_case)})
		page_tables_case_end(right_case)
	}
	// 2. A reservation of 4 MiB: its four tables stay through a commit and a
	// decommit (the mapping still holds its range, so a fault never needs a
	// table), and return with the unmap.
	{
		memory, _ := system.memory_create(RESERVATION_PAGES, flags = {.Uncommitted})
		before, _ := system.budget_read()
		address, status := system.memory_map(memory, {.Write}, 0, SPREAD_ADDRESS)
		mapped, _ := system.budget_read()
		returned: u64
		decommitted := mapped
		if status == .Succeeded {
			some := [1]op.Page_Range{{first = 500, page_count = 16}}
			system.memory_commit(memory, some[:])
			bytes := ([^]u8)(address)
			for page in u64(500) ..< 516 {
				intrinsics.volatile_store(&bytes[page * system.PAGE_SIZE], 1)
			}
			returned, _ = system.memory_decommit(memory, some[:])
			decommitted, _ = system.budget_read()
			system.memory_unmap(address)
		}
		after, _ := system.budget_read()
		system.close(memory)
		tables := before.pages - mapped.pages
		right_case := status == .Succeeded && returned == 16 && tables == 4 && decommitted.pages == mapped.pages && after.pages == before.pages
		system.log_fact(.Info, Page_Tables_Of_Reservation{reservation_pages = u64(RESERVATION_PAGES), table_pages = u64(tables), pages_kept = u64(before.pages - after.pages), budget_after_decommit = value_kinds.text_field(decommitted.pages == mapped.pages ? "the same" : "not the same", 16), verdict = page_tables_verdict(right_case)})
		page_tables_case_end(right_case)
	}
	// 3. A large page: two tables above it, both return.
	{
		memory, created := system.memory_create(op.LARGE_PAGE_PAGES, flags = {.Large_Pages})
		before, _ := system.budget_read()
		address, status := system.memory_map(memory, {.Write}, 0, SPREAD_ADDRESS + 2 * SPREAD_STRIDE)
		mapped, _ := system.budget_read()
		report := own_mappings()
		mapping := mapping_at(report, SPREAD_ADDRESS + 2 * SPREAD_STRIDE)
		large := mapping != nil && .Large in mapping.flags
		if status == .Succeeded {
			intrinsics.volatile_store((^u64)(address), 1)
			system.memory_unmap(address)
		}
		after, _ := system.budget_read()
		system.close(memory)
		tables := before.pages - mapped.pages
		right_case := created == .Succeeded && status == .Succeeded && large && tables == 2 && after.pages == before.pages
		system.log_fact(.Info, Page_Tables_Of_Large_Page{table_pages = u64(tables), pages_kept = u64(before.pages - after.pages), verdict = page_tables_verdict(right_case)})
		page_tables_case_end(right_case)
	}
	// 4. Two threads: this one maps and unmaps a page in the table of the
	// page of the other thread (the table stays: the other page holds it),
	// and a page at its own entry of three levels (three tables leave at each
	// unmap, while the other thread runs on the same page table).
	{
		near, _ := system.memory_create(1)
		far, _ := system.memory_create(1)
		watched, _ := system.memory_create(1)
		word_address, watched_status := system.memory_map(watched, {.Write}, 0, SPREAD_ADDRESS + 3 * SPREAD_STRIDE)
		if watched_status != .Succeeded {
			system.close(near)
			system.close(far)
			system.close(watched)
			system.log_fact(.Info, Neighbour_Page_Not_Mapped{})
			page_tables_case_end(false)
			return
		}
		neighbour = {word = (^u64)(word_address)}
		thread, thread_status := system.thread_start(neighbour_touch, nil)
		// The other thread runs before the rounds start. The bound only ends
		// a hang.
		for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; intrinsics.atomic_load(&neighbour.touches) == 0 && system.time() < deadline; {
			system.sleep(system.time() + 1)
		}
		touches_before := intrinsics.atomic_load(&neighbour.touches)
		before, _ := system.budget_read()
		rounds_right: u64
		rounds_wrong: u64
		// The rounds go on after the count until the other thread ran
		// beside one of them: the case is the two threads at the same
		// time, and a processor can give the other thread no stint during
		// a thousand rounds. The bound only ends a hang.
		rounds_deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
		for round := u64(0); round < NEIGHBOUR_ROUNDS || (intrinsics.atomic_load(&neighbour.touches) == touches_before && system.time() < rounds_deadline); round += 1 {
			near_address, near_status := system.memory_map(near, {.Write}, 0, SPREAD_ADDRESS + 3 * SPREAD_STRIDE + system.PAGE_SIZE)
			far_address, far_status := system.memory_map(far, {.Write}, 0, SPREAD_ADDRESS + 4 * SPREAD_STRIDE)
			if near_status != .Succeeded || far_status != .Succeeded {
				break
			}
			intrinsics.volatile_store((^u64)(near_address), round)
			intrinsics.volatile_store((^u64)(far_address), round + 1)
			if intrinsics.volatile_load((^u64)(near_address)) == round && intrinsics.volatile_load((^u64)(far_address)) == round + 1 {
				rounds_right += round < NEIGHBOUR_ROUNDS ? 1 : 0
			} else {
				rounds_wrong += 1
			}
			system.memory_unmap(near_address)
			system.memory_unmap(far_address)
		}
		after, _ := system.budget_read()
		touches_after := intrinsics.atomic_load(&neighbour.touches)
		intrinsics.atomic_store(&neighbour.stop, 1)
		if thread_status == .Succeeded {
			system.thread_wait(thread)
		}
		value_right := intrinsics.atomic_load(&neighbour.wrong) == 0 && intrinsics.volatile_load(neighbour.word) == intrinsics.atomic_load(&neighbour.touches)
		system.memory_unmap(word_address)
		system.close(near)
		system.close(far)
		system.close(watched)
		system.log_fact(.Info, Neighbour_Touches{touches = touches_after - touches_before})
		right_case := thread_status == .Succeeded && rounds_right == NEIGHBOUR_ROUNDS && rounds_wrong == 0 && touches_before != 0 && touches_after > touches_before && value_right && after.pages == before.pages
		system.log_fact(.Info, Page_Tables_Beside_Neighbour{rounds = u64(NEIGHBOUR_ROUNDS), rounds_right = rounds_right, pages_kept = u64(before.pages - after.pages), neighbour_page = value_kinds.text_field(value_right ? "stayed right" : "changed", 16), verdict = page_tables_verdict(right_case)})
		page_tables_case_end(right_case)
	}
}

// The window: one card for each case, with the numbers.
window_memory: interface.Window_Memory(1024, 16384)

line :: proc "contextless" (frame: ^interface.Frame, column: ^interface.Column, label: string, parts: ..system.Part) {
	buffer: [96]u8
	interface.label_value_line(frame, interface.column_take(column, 16), label, system.format(buffer[:], ..parts), graphics.colors.text, 208)
}

build :: proc "contextless" (frame: ^interface.Frame) {
	interface.background(frame, {0, 0, WIDTH, HEIGHT})
	left := interface.card(frame, {8, 8, WIDTH / 2 - 12, HEIGHT - 16}, "RESERVE AND COMMIT", "Memory_Commit", graphics.colors.memory)
	column := interface.column_of(left, 4)
	line(frame, &column, "arena: addresses", "1 GiB, one mapping")
	line(frame, &column, "  frame list paid", arena_list_pages, " pages")
	line(frame, &column, "  mapped in", arena_map_microseconds, " us")
	interface.cell_text(frame, interface.column_take(&column, 16), "  pages committed and used in one second,", graphics.colors.dim)
	interface.cell_text(frame, interface.column_take(&column, 16), "  and kernel entries for 1000 pages:", graphics.colors.dim)
	for batch, row in batch_sizes {
		buffer: [48]u8
		label := system.format(buffer[:], "  ", batch, batch == 1 ? " range" : " ranges", " / entry")
		line(frame, &column, label, arena_pages_per_second[row], " pages/s, ", arena_entries_per_thousand_pages[row], " entries")
	}
	interface.column_take(&column, 8)
	line(frame, &column, "sparse: committed", sparse_committed, " of ", u64(GIGABYTE_PAGES), " pages")
	line(frame, &column, "  with a frame", sparse_present, " pages")
	line(frame, &column, "decommit: returned", decommit_returned, " of ", decommit_expected, " pages")
	line(frame, &column, "  longest call", decommit_microseconds, " us")
	line(frame, &column, "  committed again", recommit_zero ? "zero" : "not zero")
	line(frame, &column, "map and unmap 100000", reuse_right ? "no page table more" : "page tables grew")
	interface.column_take(&column, 8)
	interface.cell_text(frame, interface.column_take(&column, 16), "refusals, each with its error record", graphics.colors.dim)
	for &item in refusals {
		color: graphics.Color = item.status == item.expected ? graphics.colors.process : graphics.colors.failed
		interface.cell_text(frame, interface.column_take(&column, 16), item.name, graphics.colors.text)
		// Two lines, cut at a space.
		first := min(item.count, 52)
		for first < item.count && first > 0 && item.sentence[first] != ' ' {
			first -= 1
		}
		interface.cell_text(frame, interface.column_take(&column, 16), string(item.sentence[:first]), color)
		interface.cell_text(frame, interface.column_take(&column, 16), string(item.sentence[min(first + 1, item.count):min(item.count, first + 53)]), color)
	}
	right_card := interface.card(frame, {WIDTH / 2 + 4, 8, WIDTH / 2 - 12, HEIGHT - 16}, "PROTECT, GUARD, LARGE PAGES", "Memory_Protect", graphics.colors.kernel)
	column = interface.column_of(right_card, 4)
	interface.cell_text(frame, interface.column_take(&column, 16), "64 pages read only, then writable: the middle", graphics.colors.dim)
	interface.cell_text(frame, interface.column_take(&column, 16), "of 40 calls, least and most of 5 batches:", graphics.colors.dim)
	most := max(shootdown_most[0], shootdown_most[1], shootdown_most[2], 1)
	for processors, row in ([3]u64{1, 2, 4}) {
		buffer: [48]u8
		line(frame, &column, system.format(buffer[:], processors, processors == 1 ? " processor" : " processors"), shootdown_least[row] == max(u64) ? u64(0) : shootdown_least[row], " to ", shootdown_most[row], " ns")
		// The track, the spread from the least to the most, and the least.
		area := interface.column_take(&column, 8)
		interface.bar(frame, area, shootdown_most[row], most, graphics.shade(graphics.colors.kernel, 50))
		least := shootdown_least[row] == max(u64) ? 0 : shootdown_least[row]
		interface.bar(frame, {area.x, area.y, int(least * u64(area.width) / most), area.height}, 1, 1, graphics.colors.kernel)
	}
	interface.column_take(&column, 8)
	interface.cell_text(frame, interface.column_take(&column, 16), "a child writes down its stack into a guard page:", graphics.colors.dim)
	if guard_right {
		buffer: [48]u8
		interface.cell_text(frame, interface.column_take(&column, 16), system.format(buffer[:], "stopped: page fault at ", system.Hex(guard_address)), graphics.colors.process)
	} else {
		interface.cell_text(frame, interface.column_take(&column, 16), done ? "not stopped in its guard page" : "not measured yet", done ? graphics.colors.failed : graphics.colors.dim)
	}
	interface.column_take(&column, 8)
	interface.cell_text(frame, interface.column_take(&column, 16), "one random read over 64 MiB:", graphics.colors.dim)
	slowest := max(large_nanoseconds, small_nanoseconds, 1)
	line(frame, &column, "large pages of 2 MiB", large_nanoseconds / 10, ".", large_nanoseconds % 10, " ns")
	interface.bar(frame, interface.column_take(&column, 8), large_nanoseconds, slowest, graphics.colors.memory)
	line(frame, &column, "pages of 4 KiB", small_nanoseconds / 10, ".", small_nanoseconds % 10, " ns")
	interface.bar(frame, interface.column_take(&column, 8), small_nanoseconds, slowest, graphics.colors.memory)
	interface.cell_text(frame, interface.column_take(&column, 16), "(the processor of the host, under KVM)", graphics.colors.dim)
	interface.column_take(&column, 8)
	interface.cell_text(frame, interface.column_take(&column, 16), "delegation: B commits for A with the right Commit", graphics.colors.dim)
	cases_line: [64]u8
	cases_right: u64
	for step in 1 ..= DELEGATION_CASES {
		cases_right += delegation_right[step] ? 1 : 0
	}
	marks := interface.column_take(&column, 16)
	for step in 1 ..= DELEGATION_CASES {
		color: graphics.Color = delegation_line_counts[step] == 0 ? graphics.colors.track : delegation_right[step] ? graphics.colors.process : graphics.colors.failed
		interface.mark(frame, marks.x + (step - 1) * 16, marks.y + 4, 8, color)
	}
	interface.cell_text(frame, {marks.x + 168, marks.y, marks.width - 168, 16}, system.format(cases_line[:], cases_right, " of 10 as expected"), graphics.colors.text)
	edge_count: u64
	for result in edge_case_results {
		edge_count += result ? 1 : 0
	}
	line(frame, &column, "edge cases", edge_count, " of ", u64(EDGE_CASES), " right")
	interface.column_take(&column, 8)
	status_text := done ? (right ? "ok: each check holds" : problem) : "the cases run"
	interface.cell_text(frame, interface.column_take(&column, 16), status_text, done ? (right ? graphics.colors.process : graphics.colors.failed) : graphics.colors.boot_program)
}

frame_draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_start(&window_memory, window)
	build(&frame)
	interface.window_frame_end(&window_memory.drawing, &frame, window)
}

// entry runs each case once, checks its counts against the budget and the
// mappings that the kernel reports, writes one log line for each case and
// the summary (`address_space: ok, ...` or `address_space: wrong: <the
// first problem>`), then keeps the window open until the process is
// stopped. When the context names the role of the child, it only writes
// down its stack into the guard page, and the kernel stops it there.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	if ctx.values[VALUE_ROLE] == 1 {
		child()
	}
	if ctx.values[VALUE_ROLE] == 4 {
		child_waits_on_object(ctx)
	}
	if ctx.values[VALUE_ROLE] == 3 {
		child_not_committed()
	}
	if ctx.values[VALUE_ROLE] == 2 {
		child_delegate(ctx)
	}
	if ctx.values[VALUE_ROLE] == 5 {
		child_last_thread()
	}
	if ctx.values[VALUE_ROLE] == 6 {
		child_stop_by_own_handle(ctx)
	}
	random.generator_from_context(&process_generator, ctx)
	window, ok := display.open(ctx, WIDTH, HEIGHT, "address_space")
	if !ok {
		system.stop(.Failed)
	}
	frame_draw(&window)
	machine = ctx.handles[system.GRANT_MACHINE]
	find_self()
	start_budget, _ := system.budget_read()

	arena()
	system.log_fact(.Info, Arena_Measured{frame_list_pages = arena_list_pages, map_time = arena_map_microseconds, pages_one_range = arena_pages_per_second[0], pages_16_ranges = arena_pages_per_second[1], pages_256_ranges = arena_pages_per_second[2], entries_one_range = arena_entries_per_thousand_pages[0], entries_16_ranges = arena_entries_per_thousand_pages[1], entries_256_ranges = arena_entries_per_thousand_pages[2]})
	sparse()
	system.log_fact(.Info, Sparse_Table_Measured{pages_committed = sparse_committed, object_pages = u64(GIGABYTE_PAGES), pages_present = sparse_present, pages_returned = u64(decommit_returned), decommit_time = value_kinds.Time_In_Microseconds(decommit_microseconds), committed_again_zero = u64(recommit_zero)})
	protection()
	system.log_fact(.Info, Protection_Measured{least_one_processor = shootdown_least[0], most_one_processor = shootdown_most[0], least_two_processors = shootdown_least[1], most_two_processors = shootdown_most[1], least_four_processors = shootdown_least[2], most_four_processors = shootdown_most[2]})
	guard_page(ctx)
	system.log_fact(.Info, Guard_Page_Stop{vector = guard_vector, fault_address = value_kinds.Hexadecimal_Sixteen_Digits(guard_address), in_guard_page = u64(guard_right)})
	large_pages()
	// The measure keeps tenths of a nanosecond; the fact writes hundredths.
	system.log_fact(.Info, Large_Pages_Measured{large_page_read = value_kinds.Hundredths(large_nanoseconds * 10), small_page_read = value_kinds.Hundredths(small_nanoseconds * 10), large_in_report = u64(large_flags_right)})
	refuse()
	edge_cases(ctx)
	delegation(ctx)
	addresses_reused()
	system.log_fact(.Info, Addresses_Reused{pages_after_last = reuse_pages_last, pages_after_first = reuse_pages_first})
	page_tables_return()
	for &item in refusals {
		fields := errors.error_record_fact_fields(item.record)
		system.log_fact(.Info, Refusal_Recorded{kind = fields.kind, unit = fields.unit, operation = fields.operation, argument = fields.argument, value = fields.value, limit = fields.limit, found = fields.found, refusal_name = value_kinds.text_field(item.name, 32)})
	}
	// Each page returned, except what this process still maps: the boot
	// image, which each case that starts a child maps, and its page tables.
	end_budget, _ := system.budget_read()
	tables := start_budget.pages - end_budget.pages
	if tables > 2048 {
		fail("the budget did not get its pages back")
	}
	done = true
	if right {
		system.log_fact(.Info, Address_Space_Held{})
	} else {
		system.log_fact(.Info, Demonstration_Wrong{problem = value_kinds.text_field(problem, 96)})
	}
	frame_draw(&window)
	deadline := system.time()
	for {
		deadline += 500
		display.wait(&window, deadline)
		interface.window_events(&window_memory.drawing, &window)
		frame_draw(&window)
	}
}
