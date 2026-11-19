// A process that shows the errors of the system: one case for each kind of error. Each case makes the error for real, and shows the sentence of the error record that the system gave (docs/MODULE_CONTRACT.md, section 8).
//
// The cases: kernel operations that the kernel refuses (a right, a handle that was revoked or closed, a budget that cannot pay, an address, a size, a flag); loads that fail (a missing import, a replacement that fails its check); a direct call of a module export that fails; isolated calls of the storage service that fail; and a process that faults three calls deep, with its stack trace.
//
// The process runs each case at its start. A key from a to y, or a click on a case, runs it again.
//
// **What it is for.** In this system an error is a value, not a number to
// look up: each failed call gives an [error record](term:error-record) with
// an [error kind](term:error-kind), the argument that caused it, the value
// that it had and the limit that it passed, and the console writes it as a
// sentence. This process makes 25 real errors, one of each family, and
// checks that each one gives the record that the contract states
// (docs/MODULE_CONTRACT.md, "8. Errors that diagnose"). There is no global
// last error: the record comes back with the call.
//
// **What a reader sees.** Start it from the start menu, or with
// `start("errors")` in the console. The window lists the cases on pages
// (Tab shows the next page; a page holds the cases that fit in its height):
// for each one, what the process does, the kind that it expects, and the
// whole sentence of the record that it got, on as many lines as it needs,
// in the color "failed" when the answer is not the expected one. The log has
// one line for each case (`errors: a map the boot image to write: ...`),
// then `errors: ok, 25 cases, each with the expected error record`, the
// [stack trace](term:stack-trace) of the fault case, a case under
// contention, and the measures of the cost of an error.
//
// **The families of cases:**
//
// - kernel operations that the kernel refuses: a right, a handle that was
//   revoked or closed, a handle of the wrong kind, a number that names no
//   handle, a budget that cannot pay, an address in the kernel half, a name
//   too long, an unknown flag, an unknown operation, the pages of another
//   process;
// - [load errors](term:load-error): a missing import, a
//   [replacement](term:replacement) that fails its check;
// - a [direct call](term:direct-call) of a module export that fails
//   (`square_root(-4)` of the module `math`);
// - calls of the storage service that fail: an empty name, a name too
//   long, a zero byte, a write over the limit of the store, an absent name;
// - the other families of calls: a wrapper of src/library/support/system, a ring of
//   the root service, an export of a service (`tally.add`);
// - a fault three calls deep, with its stack trace from the
//   [debug image](term:debug-image).
//
// **The case under contention.** Two threads make failures on handles that
// a third thread closes and makes again, for a short time. Each record
// must explain its status; a record of the kind `Refused` (its cause was
// gone when the kernel read the state again) must stay rare.
//
// **The table of error details of a kernel command.** `Memory_Create` with
// two wrong arguments, a budget that names nothing and an unknown flag,
// gives the two in its [table of error details](term:table-of-error-details),
// one log line for each; a command with a table that succeeds leaves the
// table empty; `Log`, whose last value is an argument, refuses a table.
//
// **A full completion queue.** The process fills the completion queue of
// its kernel ring and leaves it unread: the kernel keeps the next command
// unrun in the command queue and ends the entry with no wait, also on the
// word of a `Word_Wait` of the same entry; a kernel call of the library is
// refused with `Busy` and does not run; a wait of the library ends at once
// and pushes nothing; and after the read each answer has come once, in
// order, and the kept command runs once. Its child stops on a kernel ring
// that holds records, and must stop with its own stop code.
//
// **The measures**, printed and never compared to a bound: a kernel
// operation that succeeds and one that fails with its record; a direct
// call that succeeds and one that fails; a refused `Log` over the limit of
// a budget, measured by a child (a process of this module with no log
// records in its budget); a refused `Memory_Create`, with the takes of the
// locks of the kernel; a kernel command that succeeds and one that is
// refused, each with no table of error details and with one.
//
// **Its grants**, one for each family: **Store** (the cases of the storage
// service), **Image** (load modules, and start its child and the process
// `fault`), **Inspect** (the counts of the locks, the pages of another
// process), **Connect** (ask the root service for a connection that it
// refuses: the root service lets it call no service), and **Debug_Image**
// (the names of the stack trace). Its log handle has the right Give, for
// its child.
package errors_process

import "modus:contract/errors"
import "modus:contract/fixed_addresses"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/storage"
import terminal "modus:support/terminal"
import "modus:contract/ring"
import "modus:support/random"
import "modus:contract/root_ring"
import "modus:support/system"
import "base:intrinsics"

// It starts fault and its child, and 3 threads under contention.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1476, processes = 3, threads = 4, window_width = WIDTH, window_height = HEIGHT}

// The window is built with the interface package (docs/INTERFACE.md).
window_memory: interface.Window_Memory(1024, 16384)

WIDTH :: 1000
LINE :: 16
TOP :: 8 + 2 * LINE + 8 // The first case.
CASE_HEIGHT :: 2 * LINE // A case whose sentence has one line.
CASE_CAPACITY :: 25
// The window shows one page of cases; Tab shows the next one. A sentence
// has as many lines as it needs in the width of the window (a load error
// that names an export and its difference, a stack trace with its files),
// so a case has no fixed height: a page holds the cases that fit in its
// height, in their order (pages_update).
PAGE_HEIGHT :: 19 * CASE_HEIGHT
// Under the cases: the line of the measures, on two lines when its numbers
// are long.
// A literal, because the tool counts the pictures of the window from it;
// the assertion keeps it equal to its layout.
HEIGHT :: 704
#assert(HEIGHT == TOP + PAGE_HEIGHT + 8 + 2 * LINE + 8)
SENTENCE_CAPACITY :: 480 // A stack trace of four named frames, with their files and lines.
SENTENCE_ROOM :: WIDTH - 40 // The width of the box of a sentence, in pixels: from x 32 to the end of the band of its case.

// The colors of docs/DESIGN.md: a name is dim, a value (the sentence of a
// record, the expected kind, the answer) is in the text color, a wrong
// answer is in the color "failed". The colors are the table of
// src/library/support/graphics (rules.odin).

// One case: what the process does, the error kind that it expects, and the
// sentence of the error record that the system gave.
Case :: struct {
	text:     string,
	expected: string,
	sentence: [SENTENCE_CAPACITY]u8,
	count:    int,
	lines:    int, // The lines of the sentence in the window: counted when the case runs, not at each picture.
	right:    bool,
}

cases := [CASE_CAPACITY]Case {
	{text = "map the boot image to write", expected = "Handle_Rights"},
	{text = "use a copy after its revocation", expected = "Handle_Ended"},
	{text = "use a handle after its close", expected = "Handle_Ended"},
	{text = "a budget where a memory goes", expected = "Handle_Kind"},
	{text = "a number that names no handle", expected = "Handle_Absent"},
	{text = "64 pages from a budget of 8", expected = "Budget"},
	{text = "log a text in the kernel half", expected = "Bad_Address"},
	{text = "a process name of 40 bytes", expected = "Too_Long"},
	{text = "memory with an unknown flag", expected = "Bad_Flags"},
	{text = "an operation past the last", expected = "Unknown_Operation"},
	{text = "load lonely: its import is absent", expected = "load: Find"},
	{text = "load agenda, calendar_changed", expected = "load: Check"},
	{text = "direct call: square_root(-4)", expected = "Too_Small"},
	{text = "storage.write(\"\", \"x\")", expected = "Empty"},
	{text = "storage.write: a name of 65 bytes", expected = "Too_Long"},
	{text = "storage.write: a zero byte", expected = "Bad_Byte"},
	{text = "storage.write over the limit", expected = "Over_Limit"},
	{text = "storage.size(\"nothing\")", expected = "Absent"},
	{text = "a fault three calls deep", expected = "stack trace"},
	// The second page.
	{text = "the pages of another process (Inspect, Pages)", expected = "Bad_Value"},
	{text = "the pages past the end of the user half", expected = "Bad_Value"},
	// One case for each family of calls that gave a status or a bool only
	// (MODULE_CONTRACT.md, section 8, "The other calls").
	{text = "a wrapper: display.open of 0 by 100 pixels", expected = "Bad_Value"},
	{text = "a wrapper: terminal.open with no terminal", expected = "No_Grant"},
	{text = "a ring: root.Connect(\"storage\"), not callable", expected = "No_Grant"},
	{text = "an export: tally.add, a note of 40 bytes", expected = "Too_Long"},
}

shown_page: int // The page of cases that the window shows.
// The pages: page_first[page] is the first case of a page, and
// page_first[page_count] is the count of the cases.
page_first: [CASE_CAPACITY + 1]int
page_count: int
machine: system.Handle

image: []u8
image_memory: system.Handle
debug_names: system.Debug_Names // The debug image and the verdicts of its objects: the names of the stack of fault.
client: storage.Client
connected: bool
ctx_log: system.Handle

// The measures, in nanoseconds for one call.
kernel_good, kernel_failed, direct_good, direct_failed: u64

// The kernel cases use the wrappers of src/library/support/system with their last
// parameter `error`: the record is a value of the call, in memory of this
// process. An operation with no wrapper that gives a status uses
// system.call_with_error.

// kernel_text writes the sentence of a record and says if the call failed
// with the expected kind.
kernel_text :: proc "contextless" (writer: ^system.Writer, record: ^errors.Error_Record, status: system.Status, expected: errors.Kind) -> bool {
	system.kernel_error_text(writer, record)
	return status != .Ok && record.kind == i64(expected)
}

// The pages of another process: Inspect_Kind.Pages answers for the process
// that asks only (a side channel otherwise): the slot 1, the root service,
// is refused with the argument index.
case_pages_of_another_process :: proc "contextless" (writer: ^system.Writer) -> bool {
	record: errors.Error_Record
	report: op.Page_Report
	_, status := system.call_with_error(&record, .Inspect, u64(machine), u64(op.Inspect_Kind.Pages), 1, u64(uintptr(&report)), size_of(report))
	right := kernel_text(writer, &record, status, .Bad_Value)
	return right && status == .Bad_Operation && record.argument == 3 && record.value == 1
}

// The pages past the end of the user half: the 64 pages from the first page
// of the report must be addresses of processes.
case_pages_past_the_user_half :: proc "contextless" (writer: ^system.Writer) -> bool {
	record: errors.Error_Record
	report := op.Page_Report{address = op.USER_END - system.PAGE_SIZE}
	_, status := system.call_with_error(&record, .Inspect, u64(machine), u64(op.Inspect_Kind.Pages), 0, u64(uintptr(&report)), size_of(report))
	right := kernel_text(writer, &record, status, .Bad_Value)
	return right && status == .Bad_Operation && record.argument == 4 && u64(record.value) == op.USER_END - system.PAGE_SIZE
}

case_rights :: proc "contextless" (writer: ^system.Writer) -> bool {
	record: errors.Error_Record
	address, status := system.memory_map(image_memory, {.Write}, error = &record)
	right := kernel_text(writer, &record, status, .Handle_Rights)
	return right && address == nil && .Write in transmute(op.Rights)u32(record.limit) && .Write not_in transmute(op.Rights)u32(record.found)
}

// size_case asks the size of a memory object of a handle that must fail.
size_case :: proc "contextless" (writer: ^system.Writer, handle: system.Handle, expected: errors.Kind) -> (record: errors.Error_Record, right: bool) {
	pages, status := system.memory_size(handle, &record)
	system.kernel_error_text(writer, &record)
	return record, status != .Ok && pages == 0 && record.kind == i64(expected)
}

case_revoked :: proc "contextless" (writer: ^system.Writer) -> bool {
	memory, _ := system.memory_create(1)
	defer system.close(memory)
	copy, _ := system.give(0, memory, {.Read})
	system.handle_revoke(memory)
	record, right := size_case(writer, copy, .Handle_Ended)
	return right && errors.End(record.found) == .Revoked
}

case_closed :: proc "contextless" (writer: ^system.Writer) -> bool {
	memory, _ := system.memory_create(1)
	system.close(memory)
	record, right := size_case(writer, memory, .Handle_Ended)
	return right && errors.End(record.found) == .Closed
}

case_kind :: proc "contextless" (writer: ^system.Writer) -> bool {
	record, right := size_case(writer, system.own_budget(), .Handle_Kind)
	return right && op.Object_Kind(record.found) == .Budget && op.Object_Kind(record.limit) == .Memory
}

case_absent :: proc "contextless" (writer: ^system.Writer) -> bool {
	_, right := size_case(writer, 0x7F, .Handle_Absent)
	return right
}

case_budget :: proc "contextless" (writer: ^system.Writer) -> bool {
	budget, created := system.budget_create({pages = 8})
	if created != .Ok {
		return false
	}
	defer system.close(budget)
	record: errors.Error_Record
	memory, status := system.memory_create(64, budget, {}, &record)
	right := kernel_text(writer, &record, status, .Budget)
	return right && memory == 0 && errors.Unit(record.unit) == .Pages && record.limit == 65 && record.found == 8
}

case_address :: proc "contextless" (writer: ^system.Writer) -> bool {
	record: errors.Error_Record
	_, status := system.call_with_error(&record, .Log, u64(ctx_log), 0xFFFF_8000_0000_0000, 10, 0)
	return kernel_text(writer, &record, status, .Bad_Address) && record.argument == 2
}

// log_filter_check calls the operation Log itself, past the support
// library, with control characters and a broken sequence of UTF-8: the
// kernel writes "?" for each of their bytes, and the scenario waits for
// the line with each "?" in its place. Then it asks for a process whose
// name starts with an escape byte: the name would start each line of that
// process on the serial port, and the kernel refuses it.
log_filter_check :: proc "contextless" () {
	text := "errors: a log line with control bytes: \x1b[2J\r\xc2\x85\xc3( as it must"
	system.call(.Log, u64(ctx_log), u64(uintptr(raw_data(text))), u64(len(text)), u64(op.Log_Level.Info), 0)
	name := "\x1b[2J"
	_, status := system.call(.Process_Create, u64(system.own_budget()), u64(uintptr(raw_data(name))), u64(len(name)))
	if status == .Bad_Operation {
		system.log(.Info, "errors: a name of a process with an escape byte is refused: as it must")
	} else {
		system.log(.Info, "errors: WRONG: a name of a process with an escape byte gave ", status)
	}
}

// The table of error details of a kernel command
// (src/md/features/kernel_error_details.md): Memory_Create with two wrong
// arguments, a budget handle of the index 0, which names nothing, and a flag
// that the kernel does not know. The kernel refuses it for the budget, the
// first argument that the operation reads, and the table holds the two
// arguments in their order, each as one line of the log.
DETAILS_NO_HANDLE :: u64(0)
DETAILS_UNKNOWN_FLAG :: u64(0x100) // A bit that no flag of Memory_Create has.

kernel_details_check :: proc "contextless" () {
	records: [4]errors.Error_Record
	details := system.Error_Details{records = &records[0], capacity = len(records)}
	error: errors.Error_Record
	_, status := system.call_with_error_details(&error, &details, .Memory_Create, DETAILS_NO_HANDLE, 1, DETAILS_UNKNOWN_FLAG)
	written := system.error_details_written(&details)
	for &detail, number in written {
		buffer: [SENTENCE_CAPACITY]u8
		writer := system.Writer{buffer = buffer[:]}
		system.error_detail_number_text(&writer, u64(number + 1), details.count)
		system.kernel_error_text(&writer, &detail)
		system.log(.Info, "errors: ", system.written(&writer))
	}
	two := status == .Bad_Handle && details.count == 2 && len(written) == 2 && written[0] == error
	two &&= errors.Kind(written[0].kind) == .Handle_Absent && written[0].argument == 1
	two &&= errors.Kind(written[1].kind) == .Bad_Flags && written[1].argument == 3 && u64(written[1].value) == DETAILS_UNKNOWN_FLAG
	if two {
		system.log(.Info, "errors: a kernel command with two wrong arguments gives the two in its table of error details: as it must")
	} else {
		system.log(.Info, "errors: WRONG: a kernel command with two wrong arguments gave the status ", status, " and ", details.count, " error details")
	}
	// A table of one place for two details: the Append rule. The kernel
	// writes the first detail, the error record, and counts the two.
	small := system.Error_Details{records = &records[0], capacity = 1}
	records[1] = {}
	_, status = system.call_with_error_details(&error, &small, .Memory_Create, DETAILS_NO_HANDLE, 1, DETAILS_UNKNOWN_FLAG)
	shown := system.error_details_written(&small)
	rest_buffer: [SENTENCE_CAPACITY]u8
	rest := system.Writer{buffer = rest_buffer[:]}
	system.error_details_rest_text(&rest, u64(len(shown)), small.count)
	system.log(.Info, "errors: a table of 1 place: ", system.written(&rest))
	if status == .Bad_Handle && small.count == 2 && len(shown) == 1 && shown[0] == error && records[1] == (errors.Error_Record{}) {
		system.log(.Info, "errors: a table smaller than its error details holds the first and counts each one: as it must")
	} else {
		system.log(.Info, "errors: WRONG: a table of 1 place gave the status ", status, " and the count ", small.count)
	}
	// A command with a table that succeeds leaves the table as it was.
	details.count = 0
	_, status = system.call_with_error_details(&error, &details, .Handle_State, u64(system.own_budget()))
	if status == .Ok && details.count == 0 {
		system.log(.Info, "errors: an accepted kernel command leaves its table of error details empty: as it must")
	} else {
		system.log(.Info, "errors: WRONG: an accepted kernel command with a table gave the status ", status, " and ", details.count, " error details")
	}
	// Log uses its last value: with the bit, the kernel refuses the command
	// and writes no detail.
	text := "x"
	_, status = system.call_with_error_details(&error, &details, .Log, u64(ctx_log), u64(uintptr(raw_data(text))), u64(len(text)), u64(op.Log_Level.Info), 0)
	if status == .Bad_Operation && errors.Kind(error.kind) == .Unsupported && details.count == 0 {
		system.log(.Info, "errors: Log refuses a table of error details: as it must")
	} else {
		system.log(.Info, "errors: WRONG: Log with a table of error details gave the status ", status, " and ", details.count, " error details")
	}
}

KERNEL_RING_FIRST_TAG :: u32(1)

// kernel_ring_check fills the completion queue of the kernel ring of this
// thread and checks that no answer is lost
// (src/md/api/kernel_ring_completion_room.md). The commands are None, which
// names no operation: the kernel refuses each one with Bad_Operation and
// changes nothing, so each answer differs by its tag only; they leave one
// place. The next entry holds a Word_Wait on a word that keeps its value,
// which takes the last place, then a close of a handle: the kernel must
// leave the close unrun, end the entry with no wait on the registered word,
// and run the close once after the answers are read. While records wait, a
// kernel call of the library must be refused, and its command, the close
// of another handle, must not run; a wait of the library must end at once
// and push nothing. system.log enters the kernel ring too: each line comes
// after the ring is empty again. These pushes write the kernel ring
// itself, on purpose: each one is checked.
kernel_ring_check :: proc "contextless" () {
	held_memory, held_created := system.memory_create(1)
	refused_memory, refused_created := system.memory_create(1)
	defer system.close(refused_memory)
	if held_created != .Ok || refused_created != .Ok {
		system.close(held_memory)
		system.log(.Info, "errors: WRONG: the case of a full completion queue has no memory: ", held_created, " ", refused_created)
		return
	}
	kernel := system.kernel_ring()
	capacity := ring.capacity(&kernel.completions)
	pushes_taken := ring.empty(&kernel.commands) && ring.empty(&kernel.completions)
	for number in 0 ..< capacity - 1 {
		pushes_taken &&= ring.push(&kernel.commands, ring.Record{kind = u32(op.Operation.None), tag = KERNEL_RING_FIRST_TAG + number})
	}
	system.enter(0)
	filled := ring.count(&kernel.completions) == capacity - 1 && ring.empty(&kernel.commands)
	// The last place goes to the Word_Wait, and the close is held behind it:
	// with a wait, the entry would sleep on the word, which keeps its value.
	// The hang bound only ends the wait of a kernel that would wait.
	unchanged: u32
	wait_words := [1]op.Word{{address = u64(uintptr(&unchanged)), value = 0}}
	wait_tag := KERNEL_RING_FIRST_TAG + capacity - 1
	held_tag := wait_tag + 1
	pushes_taken &&= ring.push(&kernel.commands, ring.Record{kind = u32(op.Operation.Word_Wait), tag = wait_tag, values = {0 = u64(uintptr(&wait_words)), 1 = len(wait_words)}})
	pushes_taken &&= ring.push(&kernel.commands, ring.Record{kind = u32(op.Operation.Handle_Close), tag = held_tag, values = {0 = u64(held_memory)}})
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	entered := system.enter(deadline)
	held := entered < deadline && ring.count(&kernel.commands) == 1 && ring.full(&kernel.completions)
	refusal: errors.Error_Record
	_, refused_status := system.call_with_error(&refusal, .Handle_Close, u64(refused_memory))
	refused := refused_status == .Bad_Operation && errors.Kind(refusal.kind) == .Busy && refusal.value == i64(capacity) + 1
	refused &&= ring.count(&kernel.commands) == 1 && ring.full(&kernel.completions)
	waited := system.word_wait(&unchanged, 0, deadline)
	wait_ended := waited < deadline && ring.count(&kernel.commands) == 1 && ring.full(&kernel.completions)
	// Each answer once, in the order of the commands: the refusals of the
	// None commands, then the Word_Wait.
	answers_in_order := true
	for number in 0 ..< capacity {
		answer, popped := ring.pop(&kernel.completions)
		expected := number < capacity - 1 ? system.Status.Bad_Operation : system.Status.Ok
		answers_in_order &&= popped && answer.tag == KERNEL_RING_FIRST_TAG + number && answer.kind == u32(expected)
	}
	answers_in_order &&= ring.empty(&kernel.completions)
	// The held command runs at the next entry, once.
	system.enter(0)
	held_answer, held_popped := ring.pop(&kernel.completions)
	held_ran := held_popped && held_answer.tag == held_tag && held_answer.kind == u32(system.Status.Ok)
	held_ran &&= ring.empty(&kernel.commands) && ring.empty(&kernel.completions)
	_, held_after := system.memory_size(held_memory)
	_, refused_after := system.memory_size(refused_memory)
	held_ran &&= held_after == .Bad_Handle
	refused &&= refused_after == .Ok
	if !pushes_taken {
		system.log(.Info, "errors: WRONG: the kernel ring refused a push of the case of a full completion queue")
	}
	if filled && held {
		system.log(.Info, "errors: a command past a full completion queue stays unrun in the kernel ring, and the entry does not wait: as it must")
	} else {
		system.log(.Info, "errors: WRONG: a command past a full completion queue: the queue filled: ", filled ? "yes" : "no", "; the command held with no wait: ", held ? "yes" : "no")
	}
	if refused {
		system.log(.Info, "errors: a kernel call on a kernel ring that holds records is refused with Busy, and its command does not run: as it must")
	} else {
		system.log(.Info, "errors: WRONG: a kernel call on a kernel ring that holds records gave ", refused_status, " and the kind ", refusal.kind)
	}
	if wait_ended {
		system.log(.Info, "errors: a wait of the library on a kernel ring that holds records ends at once and pushes nothing: as it must")
	} else {
		system.log(.Info, "errors: WRONG: a wait of the library on a kernel ring that holds records waited or pushed its command")
	}
	if answers_in_order && held_ran {
		system.log(.Info, "errors: each answer of a full completion queue arrives once and in order, and the held command runs once after them: as it must")
	} else {
		system.log(.Info, "errors: WRONG: the answers of a full completion queue: each once in order: ", answers_in_order ? "yes" : "no", "; the held command ran once: ", held_ran ? "yes" : "no")
	}
}

// kernel_details_measure measures a command that succeeds and one that the
// kernel refuses, each with no table and with a table of error details: the
// least of 3 runs, in nanoseconds for one command. Printed, never compared.
kernel_details_measure :: proc "contextless" () {
	DETAILS_CALLS :: 100_000
	budget := u64(system.own_budget())
	records: [4]errors.Error_Record
	error: errors.Error_Record
	// 0 and 1: accepted, with no table and with one; 2 and 3: refused.
	best := [4]u64{max(u64), max(u64), max(u64), max(u64)}
	for _ in 0 ..< 3 {
		for variant in 0 ..< len(best) {
			details := system.Error_Details{records = &records[0], capacity = len(records)}
			table: ^system.Error_Details
			if variant % 2 == 1 {
				table = &details
			}
			start := system.nanoseconds()
			for _ in 0 ..< DETAILS_CALLS {
				details.count = 0
				if variant < 2 {
					system.call_with_error_details(&error, table, .Handle_State, budget)
				} else {
					system.call_with_error_details(&error, table, .Memory_Create, DETAILS_NO_HANDLE, 1, DETAILS_UNKNOWN_FLAG)
				}
			}
			best[variant] = min(best[variant], (system.nanoseconds() - start) / DETAILS_CALLS)
		}
	}
	system.log(.Info, "errors: a kernel command and its table of error details: accepted with no table ", best[0], " ns, with a table ", best[1], " ns; refused with its error record ", best[2], " ns, with its 2 error details ", best[3], " ns")
}

case_name :: proc "contextless" (writer: ^system.Writer) -> bool {
	name := "a name of forty bytes, nine more than 31"
	record: errors.Error_Record
	_, status := system.call_with_error(&record, .Process_Create, u64(system.own_budget()), u64(uintptr(raw_data(name))), u64(len(name)))
	return kernel_text(writer, &record, status, .Too_Long) && record.value == 40 && record.limit == 31
}

case_flags :: proc "contextless" (writer: ^system.Writer) -> bool {
	record: errors.Error_Record
	memory, status := system.memory_create(1, 0, transmute(op.Memory_Flags)u64(0x100) /* A bit that no flag has: 0x4 became Uncommitted. */, &record)
	return kernel_text(writer, &record, status, .Bad_Flags) && memory == 0
}

case_operation :: proc "contextless" (writer: ^system.Writer) -> bool {
	record: errors.Error_Record
	// The case writes, on purpose, the word one past the last operation: the
	// kernel must refuse it.
	_, status := system.call_with_error(&record, op.Operation(int(max(op.Operation)) + 1))
	return kernel_text(writer, &record, status, .Unknown_Operation)
}

// load_case loads a module of the boot image, with replacements, and must
// fail at a stage. It writes the lines of the load error as one sentence.
load_case :: proc "contextless" (writer: ^system.Writer, name: string, replacements: []module.Replacement, stage: module.Load_Stage) -> bool {
	space := system.Module_Space{source = {image = image, replacements = replacements}, next = op.MODULE_BASE}
	error: module.Load_Error
	_, loaded := system.module_space_load(&space, system.image_find(image, name), &error)
	buffer: [SENTENCE_CAPACITY]u8
	lines := system.Writer{buffer = buffer[:]}
	system.load_error_text(&lines, &error)
	text := system.written(&lines)
	system.write_part(writer, "load ")
	system.write_part(writer, name)
	system.write_part(writer, ": ")
	for index in 0 ..< len(text) {
		if text[index] == '\n' {
			system.write_part(writer, index == len(text) - 1 ? "" : "; ")
		} else {
			system.write_part(writer, text[index:index + 1])
		}
	}
	return !loaded && error.stage == stage
}

hash_of :: proc "contextless" (name: string) -> [32]u8 {
	for &entry in system.image_entries(image) {
		if system.name_of(entry.name[:]) == name {
			return entry.hash
		}
	}
	return {}
}

case_missing :: proc "contextless" (writer: ^system.Writer) -> bool {
	return load_case(writer, "lonely", nil, .Find)
}

case_replacement :: proc "contextless" (writer: ^system.Writer) -> bool {
	changed := []module.Replacement{{from = hash_of("calendar"), to = hash_of("calendar_changed")}}
	return load_case(writer, "agenda", changed, .Check)
}

// The module math, loaded in this process: a direct call of its export
// square_root, with the address of an error record.
math_space: system.Module_Space
square_root: proc "c" (value: i64, error: ^errors.Error_Record) -> i64
square_root_export: u32
math_place: int

math_load :: proc "contextless" () -> bool {
	math_space = {source = {image = image}, next = op.MODULE_BASE + 0x1_0000_0000}
	error: module.Load_Error
	place, loaded := system.module_space_load(&math_space, system.image_find(image, "math"), &error)
	if !loaded {
		return false
	}
	math_place = place
	item := &math_space.modules[place]
	square_root_export = module.export_find(item.file, "square_root")
	address, found := module.export_address(item.file, uintptr(item.base), square_root_export)
	function, described := module.function(item.file, square_root_export)
	if !found || !described || function.error_record == 0 {
		return false
	}
	square_root = cast(proc "c" (value: i64, error: ^errors.Error_Record) -> i64)rawptr(address)
	return true
}

// tally, loaded as a library: its export add, called directly.
tally_space: system.Module_Space
tally_add: proc "c" (amount: i64, note: ^string, error: ^errors.Error_Record) -> i64
tally_add_export: u32
tally_place: int

tally_load :: proc "contextless" () -> bool {
	tally_space = {source = {image = image}, next = op.MODULE_BASE + 0x2_0000_0000}
	error: module.Load_Error
	place, loaded := system.module_space_load(&tally_space, system.image_find(image, "tally"), &error)
	if !loaded {
		return false
	}
	tally_place = place
	item := &tally_space.modules[place]
	tally_add_export = module.export_find(item.file, "add")
	address, found := module.export_address(item.file, uintptr(item.base), tally_add_export)
	if !found {
		return false
	}
	tally_add = cast(proc "c" (amount: i64, note: ^string, error: ^errors.Error_Record) -> i64)rawptr(address)
	return true
}

requests: ring.Ring // To the root service: Connect only (the grant Connect), and its role in the root service names no service.
has_requests: bool
request_tag: u32

// root_connect asks the root service for a connection, and waits for its
// completion.
root_connect :: proc "contextless" (name: string) -> (completion: ring.Record, ok: bool) {
	if !has_requests {
		return {}, false
	}
	request_tag += 1
	packed := system.name_pack(name)
	if !system.send(&requests.commands, ring.Record{kind = u32(root_ring.Root_Command.Connect), tag = request_tag, values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}}) {
		return {}, false
	}
	// The bound only ends a hang.
	limit := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for system.time() < limit {
		for record in system.receive(&requests.completions) {
			if record.tag == request_tag {
				return record, true
			}
		}
		wait: system.Wait
		system.wait_records(&wait, &requests.completions)
		system.wait_end(&wait, limit)
	}
	return {}, false
}

the_context: ^system.Context

// case_display_open asks for a surface of 0 by 100 pixels: display.open
// refuses it before any kernel operation.
case_display_open :: proc "contextless" (writer: ^system.Writer) -> bool {
	error: errors.Error_Record
	if _, opened := display.open(the_context, 0, 100, "zero", &error); opened {
		return false
	}
	system.wrapper_error_text(writer, &error, "display.open", display.OPEN_ARGUMENTS[:])
	return errors.Kind(error.kind) == .Bad_Value && error.argument == 2 && error.value == 0
}

// case_terminal_open opens the terminal of a process that has none.
case_terminal_open :: proc "contextless" (writer: ^system.Writer) -> bool {
	error: errors.Error_Record
	if _, opened := terminal.open(the_context, &error); opened {
		return false
	}
	system.wrapper_error_text(writer, &error, "terminal.open", {"ctx"})
	return errors.Kind(error.kind) == .No_Grant && errors.Unit(error.unit) == .Terminal
}

// case_root_connect asks the root service for a connection that the grant
// Connect of this process does not give: the completion holds the record.
case_root_connect :: proc "contextless" (writer: ^system.Writer) -> bool {
	completion, answered := root_connect("storage")
	if !answered {
		system.write_part(writer, "the root service did not answer")
		return false
	}
	error := errors.completion_record(completion.values)
	system.ring_error_text(writer, &error, "root", root_ring.root_command_name(error.operation), root_ring.root_argument_name(error.operation, error.argument))
	return system.Status(completion.kind) == .No_Right && errors.Kind(error.kind) == .No_Grant && errors.Unit(error.unit) == .Connection
}

// case_tally_add calls the export add of tally, loaded as a library, with a
// note longer than it keeps.
case_tally_add :: proc "contextless" (writer: ^system.Writer) -> bool {
	if tally_add == nil {
		system.write_part(writer, "the module tally did not load")
		return false
	}
	error: errors.Error_Record
	note := "a note of forty bytes, four more than 36"
	if tally_add(1, &note, &error) >= 0 {
		return false
	}
	error.operation = i64(tally_add_export) // The caller knows the export that it called.
	system.export_error_text(writer, tally_space.modules[tally_place].file, tally_add_export, "tally", &error)
	return errors.Kind(error.kind) == .Too_Long && error.value == 40 && error.limit == 36
}

// The measures of a failed call of each family of section 8 of
// MODULE_CONTRACT.md that is not a kernel operation: family_root in
// nanoseconds, the two others in tenths of a nanosecond.
family_wrapper, family_root, family_export: u64

families_measure :: proc "contextless" (ctx: ^system.Context) {
	WRAPPER_CALLS :: 1_000_000
	error: errors.Error_Record
	start := system.nanoseconds()
	failed := 0
	for _ in 0 ..< WRAPPER_CALLS {
		if _, opened := terminal.open(ctx, &error); !opened {
			failed += 1
		}
	}
	family_wrapper = (system.nanoseconds() - start) * 10 / WRAPPER_CALLS
	ROOT_CALLS :: 2000
	start = system.nanoseconds()
	for _ in 0 ..< ROOT_CALLS {
		if completion, answered := root_connect("storage"); answered && completion.kind != 0 {
			failed += 1
		}
	}
	family_root = (system.nanoseconds() - start) / ROOT_CALLS
	if tally_add != nil {
		EXPORT_CALLS :: 1_000_000
		note := "a note of forty bytes, four more than 36"
		start = system.nanoseconds()
		for _ in 0 ..< EXPORT_CALLS {
			tally_add(1, &note, &error)
		}
		family_export = (system.nanoseconds() - start) * 10 / EXPORT_CALLS
	}
	system.log(.Info, "errors: a failed call of each family: a wrapper of support (terminal.open with no terminal): ", family_wrapper / 10, ".", family_wrapper % 10, " ns; a command of the root ring (Connect refused): ", family_root, " ns; an export (tally.add with a note of 40 bytes, direct): ", family_export / 10, ".", family_export % 10, " ns; ", u64(failed), " failures")
}

case_direct :: proc "contextless" (writer: ^system.Writer) -> bool {
	if square_root == nil {
		system.write_part(writer, "the module math did not load")
		return false
	}
	error: errors.Error_Record
	result := square_root(-4, &error)
	if result >= 0 {
		return false
	}
	error.operation = i64(square_root_export) // The caller knows the export that it called.
	system.export_error_text(writer, math_space.modules[math_place].file, square_root_export, "math", &error)
	return errors.Kind(error.kind) == .Too_Small && error.value == -4
}

// storage_case makes one isolated call of the storage service that must
// fail with an error kind.
storage_case :: proc "contextless" (writer: ^system.Writer, export: string, expected: errors.Kind, name: string, data: string = "") -> bool {
	if !connected {
		system.write_part(writer, "no connection to the storage service")
		return false
	}
	arguments := [3]isolated.Argument{{integer = u64(storage.ROOT)}, {text = transmute([]u8)name}, {text = transmute([]u8)data}}
	error: errors.Error_Record
	result, _, status := storage.call(&client, export, arguments[:export == "write" ? 3 : 2], &error)
	storage.error_text(writer, &client, &error)
	return status == .Failed && result < 0 && error.kind == i64(expected)
}

case_empty :: proc "contextless" (writer: ^system.Writer) -> bool {
	return storage_case(writer, "write", .Empty, "", "x")
}

case_long :: proc "contextless" (writer: ^system.Writer) -> bool {
	return storage_case(writer, "write", .Too_Long, "a name of sixty-five bytes: one more than the longest name can be", "x")
}

case_byte :: proc "contextless" (writer: ^system.Writer) -> bool {
	return storage_case(writer, "write", .Bad_Byte, "a\x00b", "x")
}

case_limit :: proc "contextless" (writer: ^system.Writer) -> bool {
	return storage_case(writer, "write", .Over_Limit, "large", "one block of data, in a store of two blocks")
}

case_size :: proc "contextless" (writer: ^system.Writer) -> bool {
	return storage_case(writer, "size", .Absent, "nothing")
}

last_fault: system.Handle // The process fault of the last run of its case.

// case_fault starts the process fault, which writes to address 0 three
// calls deep, and reads its stop report: the stack trace.
case_fault :: proc "contextless" (writer: ^system.Writer) -> bool {
	error: module.Load_Error
	process, status := system.process_start(system.image_find(image, "fault"), "fault", {}, random.values_with_seed(&process_generator, {}), {pages = 256, processes = 1, threads = 1, processor = 100_000, log_records = 10}, nil, nil, {image = image}, &error)
	if status != .Ok {
		system.write_part(writer, "the process fault did not start")
		return false
	}
	// The stopped process stays until the next run of this case: a
	// developer tool shows it, with its stop report (docs/TOOLS.md).
	if last_fault != 0 {
		system.close(last_fault)
	}
	last_fault = process
	// The bound only ends a hang.
	limit := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for {
		wait := system.wait_begin()
		if state, _ := system.process_state(process); state == .Stopped || system.time() > limit {
			break
		}
		system.wait_end(&wait, limit)
	}
	report := system.process_stop_report(process)
	system.write_part(writer, report.vector == 14 ? "page fault at " : "a fault at ")
	frames := report.frames[:min(report.frame_count, op.STOP_FRAME_CAPACITY)]
	fault_hash := hash_of("fault")
	all_in_fault := len(frames) >= 4
	for &frame, number in frames {
		system.write_part(writer, number == 0 ? "" : ", ")
		system.frame_text(writer, image, &debug_names, &frame, number)
		all_in_fault &&= frame.hash == fault_hash
	}
	return report.code == op.STOP_CODE_FAULT + 14 && all_in_fault
}

// case_run runs the case of an index, writes the sentence of its error
// record, and says if the call failed with the expected kind.
case_run :: proc "contextless" (index: int, writer: ^system.Writer) -> bool {
	switch index {
	case 0:
		return case_rights(writer)
	case 1:
		return case_revoked(writer)
	case 2:
		return case_closed(writer)
	case 3:
		return case_kind(writer)
	case 4:
		return case_absent(writer)
	case 5:
		return case_budget(writer)
	case 6:
		return case_address(writer)
	case 7:
		return case_name(writer)
	case 8:
		return case_flags(writer)
	case 9:
		return case_operation(writer)
	case 10:
		return case_missing(writer)
	case 11:
		return case_replacement(writer)
	case 12:
		return case_direct(writer)
	case 13:
		return case_empty(writer)
	case 14:
		return case_long(writer)
	case 15:
		return case_byte(writer)
	case 16:
		return case_limit(writer)
	case 17:
		return case_size(writer)
	case 18:
		return case_fault(writer)
	case 19:
		return case_pages_of_another_process(writer)
	case 20:
		return case_pages_past_the_user_half(writer)
	case 21:
		return case_display_open(writer)
	case 22:
		return case_terminal_open(writer)
	case 23:
		return case_root_connect(writer)
	case 24:
		return case_tally_add(writer)
	}
	return false
}

// run runs one case and keeps its sentence.
run :: proc "contextless" (index: int) {
	item := &cases[index]
	writer := system.Writer{buffer = item.sentence[:]}
	item.right = case_run(index, &writer)
	item.count = len(system.written(&writer))
	item.lines = interface.text_wrapped_line_count(nil, {}, string(item.sentence[:item.count]), SENTENCE_ROOM)
	pages_update()
}

// pages_update puts the cases on pages again: a case goes on the page of
// the case before it while its height fits under the cases of that page. A
// case that runs again can have a sentence of another length, so the page
// that the window shows is checked too.
pages_update :: proc "contextless" () {
	page_count = 0
	used := PAGE_HEIGHT // The first case starts the first page.
	for index in 0 ..< len(cases) {
		height := case_height(index)
		if used + height > PAGE_HEIGHT {
			page_first[page_count] = index
			page_count += 1
			used = 0
		}
		used += height
	}
	page_first[page_count] = len(cases)
	shown_page = min(shown_page, page_count - 1)
}

// measure gives the nanoseconds of one kernel operation that succeeds and
// of one that fails with its error record, and the same for a direct call.
measure :: proc "contextless" () {
	CALLS :: 200_000
	budget := u64(system.own_budget())
	timed :: proc "contextless" (operation: op.Operation, value: u64) -> u64 {
		start := system.time()
		for _ in 0 ..< CALLS {
			system.call(operation, value, 0)
		}
		return (system.time() - start) * 1_000_000 / CALLS
	}
	best_good, best_failed := max(u64), max(u64)
	for _ in 0 ..< 3 {
		best_good = min(best_good, timed(.Handle_State, budget)) // Ok.
		best_failed = min(best_failed, timed(.Memory_Size, budget)) // Handle_Kind, with its record.
	}
	kernel_good, kernel_failed = best_good, best_failed
	if square_root == nil {
		return
	}
	// A failed call takes a few nanoseconds: the cycle counter gives the
	// time (system.nanoseconds), not the milliseconds of the time page.
	DIRECT :: 2_000_000
	error: errors.Error_Record
	sum: i64
	start := system.nanoseconds()
	for index in 0 ..< DIRECT {
		sum += square_root(i64(index & 0xFF), &error)
	}
	direct_good = (system.nanoseconds() - start) / DIRECT
	start = system.nanoseconds()
	for index in 0 ..< DIRECT {
		sum += square_root(-1 - i64(index & 0xFF), &error)
	}
	direct_failed = (system.nanoseconds() - start) / DIRECT
	if sum == 0 {
		system.log(.Info, "errors: the sum of the calls is 0")
	}
}

// The refusals that read a budget: a Log over the limit of the budget of the
// process, and a Memory_Create that a budget cannot pay. A refused Log needs
// a process with a log limit of 0: this process starts its own module as
// a child (VALUE_CHILD), with a budget of 0 log records, which measures and
// writes its time in a page that the two map. The locks: System_Report.locks
// before and after each loop, for all the processors.
VALUE_CHILD :: 8
// A page that this process places by its own choice: outside the band of
// the addresses that the system fixes.
MEASURE_ADDRESS :: fixed_addresses.OWN_CHOICE_START + 0x0000_0400_0000_0000
REFUSALS :: 100_000

Child_Page :: struct {
	log_ns: u64,
	done:   u64,
}

refused_log_ns, refused_log_control, refused_log_frame: u64
refused_create_ns, refused_create_control, refused_create_frame: u64

lock_takes :: proc "contextless" (machine: system.Handle) -> (control, frame: u64) {
	report: op.System_Report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
	return report.locks[op.Lock_Kind.Control].takes, report.locks[op.Lock_Kind.Frame].takes
}

// The stop code of the child: not 0 and not a code of a fault, so that the
// starter sees that the child stopped with its own stop, not by a fault.
CHILD_STOP_CODE :: 7

// child runs REFUSALS refused Log operations, writes their time, and stops
// on a kernel ring that holds records: a full completion queue, unread, and
// one command held behind it. A stop must end the process whatever its ring
// holds (src/md/api/kernel_ring_completion_room.md, "The stop of a
// process").
child :: proc "contextless" (ctx: ^system.Context) -> ! {
	page := (^Child_Page)(uintptr(MEASURE_ADDRESS))
	log := u64(ctx.handles[op.CONTEXT_LOG])
	text := "x"
	start := system.time()
	for _ in 0 ..< REFUSALS {
		system.call(.Log, log, u64(uintptr(raw_data(text))), 1, u64(op.Log_Level.Debug), 0)
	}
	page.log_ns = (system.time() - start) * 1_000_000 / REFUSALS
	intrinsics.atomic_store(&page.done, 1)
	// The pushes write the kernel ring itself, on purpose. A refused push
	// leaves a ring that holds less, which the stop must end too.
	kernel := system.kernel_ring()
	for _ in 0 ..< ring.capacity(&kernel.completions) {
		_ = ring.push(&kernel.commands, ring.Record{kind = u32(op.Operation.None)})
	}
	system.enter(0)
	_ = ring.push(&kernel.commands, ring.Record{kind = u32(op.Operation.None)})
	system.stop(CHILD_STOP_CODE)
}

// refusals measures the two refusals; the machine handle reads the counts of
// the locks.
refusals :: proc "contextless" (ctx: ^system.Context) {
	// The machine handle: the global `machine` (entry sets it).
	memory, _ := system.memory_create(1)
	defer system.close(memory)
	address, _ := system.memory_map(memory)
	page := (^Child_Page)(address)
	grants: [op.CONTEXT_HANDLES]system.Grant
	grants[op.CONTEXT_LOG] = {ctx.handles[op.CONTEXT_LOG], {.Write}}
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_CHILD] = 1
	mappings := [1]system.Mapping{{memory = memory, address = MEASURE_ADDRESS, flags = {.Write}}}
	control, frame := lock_takes(machine)
	error: module.Load_Error
	// The child is this module: its start pays for the private pages of the
	// module, which grow with its cases, so the budget keeps room past them.
	// A start that the budget cannot pay is a WRONG line below, not silence.
	process, status := system.process_start(system.image_find(image, "errors"), "errors child", grants, random.values_with_seed(&process_generator, values), {pages = 512, processes = 1, threads = 1, processor = 1_000_000, log_records = 0}, mappings[:], nil, {image = image}, &error)
	if status == .Ok {
		for intrinsics.atomic_load(&page.done) == 0 {
			if state, _ := system.process_state(process); state == .Stopped {
				break
			}
			system.sleep(system.time() + 10)
		}
		// The child then stops on a kernel ring that holds records. The
		// event word of this thread changes when a process that it holds
		// stops; the hang bound only ends a stop that never comes.
		deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
		child_state: op.Process_State
		child_code: u32
		for {
			wait := system.wait_begin()
			child_state, child_code = system.process_state(process)
			if child_state == .Stopped || system.time() >= deadline {
				break
			}
			system.wait_end(&wait, deadline)
		}
		if child_state == .Stopped && child_code == CHILD_STOP_CODE {
			system.log(.Info, "errors: a stop on a kernel ring that holds records ends the process with its own stop code: as it must")
		} else {
			system.log(.Info, "errors: WRONG: a stop on a kernel ring that holds records left the child in the state ", u64(child_state), " with the code ", u64(child_code))
		}
		system.close(process)
	} else {
		// A child that does not start measures nothing: the case says so,
		// and does not pass in silence.
		system.log(.Info, "errors: WRONG: the child of the refusals did not start: ", u64(status), ", the stage ", u64(error.stage), ", the status of the kernel ", u64(error.status), ", the error of the file ", u64(error.file_error))
	}
	control_after, frame_after := lock_takes(machine)
	refused_log_ns, refused_log_control, refused_log_frame = page.log_ns, control_after - control, frame_after - frame
	budget, _ := system.budget_create({pages = 2})
	defer system.close(budget)
	control, frame = lock_takes(machine)
	start := system.time()
	for _ in 0 ..< REFUSALS {
		system.call(.Memory_Create, u64(budget), 64, 0)
	}
	refused_create_ns = (system.time() - start) * 1_000_000 / REFUSALS
	control_after, frame_after = lock_takes(machine)
	refused_create_control, refused_create_frame = control_after - control, frame_after - frame
	system.log(.Info, "errors: ", u64(REFUSALS), " refused Log: ", refused_log_ns, " ns each, the control lock taken ", refused_log_control, " times and the frame lock ", refused_log_frame, " times; ", u64(REFUSALS), " refused Memory_Create: ", refused_create_ns, " ns each, the control lock taken ", refused_create_control, " times and the frame lock ", refused_create_frame, " times")
}

// Failures under contention: two threads make failures on the handles that
// a third thread closes and makes again, at the same time. Each record must
// explain its status: the kernel reads the state again after the failure,
// and the state can change between the two (docs/MODULE_CONTRACT.md,
// section 8).
CONTENTION_MILLISECONDS :: 500
SHARED_HANDLES :: 4

Contention :: struct {
	memories: [SHARED_HANDLES]u32, // Copies with the right Read only: a map to write fails.
	budgets:  [SHARED_HANDLES]u32, // Budgets of 2 pages: 64 pages fail.
	stop:     u32,
	failures: [2]u64,
	refused:  [2]u64, // Records of the kind Refused: the cause was gone when the kernel read the state again.
	wrong:    [2]u64, // Records that contradict their status.
	made:     u64, // Handles that the third thread closed and made again.
	source:   system.Handle, // The memory object of the copies.
}

contention: Contention

// explains says if the kind of a record can be the cause of a status, as
// the contract states it.
explains :: proc "contextless" (record: ^errors.Error_Record, status: system.Status) -> bool {
	// A kind word that names no kind explains nothing.
	kind, kind_ok := errors.kind_of_word(record.kind)
	if !kind_ok {
		return false
	}
	if kind == .Refused {
		return record.found == i64(status)
	}
	switch status {
	case .Ok, .Bad_Operation, .Bad_Address, .No_Memory, .No_Slot, .Bad_State:
		// The failures of this case give none of these.
		return false
	case .Bad_Handle:
		return kind == .Handle_Absent || kind == .Handle_Ended || kind == .Handle_Kind || kind == .No_Target
	case .No_Right:
		return kind == .Handle_Rights
	case .No_Budget:
		// A budget record names a cause that holds: the budget holds less
		// than the call asks; a count over its limit.
		return kind == .Budget && record.limit > record.found || kind == .Budget_Hidden || kind == .Over_Limit && record.value > record.limit
	}
	return false
}

// failing makes failures until the stop: thread 0 maps a copy to write,
// thread 1 asks 64 pages of a budget of 2 and the size of a copy.
failing :: proc "c" (parameter: rawptr) -> ! {
	number := int(uintptr(parameter))
	turn := 0
	for intrinsics.atomic_load(&contention.stop) == 0 {
		turn += 1
		record: errors.Error_Record
		status: system.Status
		if number == 0 {
			handle := intrinsics.atomic_load(&contention.memories[turn % SHARED_HANDLES])
			_, status = system.call_with_error(&record, .Memory_Map, u64(handle), 0, 0, transmute(u64)op.Map_Flags{.Write}, 0, 0)
		} else if turn % 2 == 0 {
			handle := intrinsics.atomic_load(&contention.budgets[turn % SHARED_HANDLES])
			_, status = system.call_with_error(&record, .Memory_Create, u64(handle), 64, 0)
		} else {
			handle := intrinsics.atomic_load(&contention.memories[turn % SHARED_HANDLES])
			_, status = system.call_with_error(&record, .Memory_Size, u64(handle) + 0x7F)
		}
		if status == .Ok {
			continue
		}
		contention.failures[number] += 1
		if errors.Kind(record.kind) == .Refused {
			contention.refused[number] += 1
		}
		if !explains(&record, status) {
			contention.wrong[number] += 1
		}
	}
	system.thread_stop()
}

// changing closes and makes again the handles that the failures name.
changing :: proc "c" (parameter: rawptr) -> ! {
	turn := 0
	for intrinsics.atomic_load(&contention.stop) == 0 {
		turn += 1
		place := turn % SHARED_HANDLES
		system.close(system.Handle(intrinsics.atomic_load(&contention.memories[place])))
		copy, _ := system.give(0, contention.source, {.Read})
		intrinsics.atomic_store(&contention.memories[place], u32(copy))
		system.close(system.Handle(intrinsics.atomic_load(&contention.budgets[place])))
		budget, _ := system.budget_create({pages = 2})
		intrinsics.atomic_store(&contention.budgets[place], u32(budget))
		contention.made += 2
	}
	system.thread_stop()
}

// contend runs the two threads of failures and the thread of changes for
// CONTENTION_MILLISECONDS. ok: each record explains its status.
contend :: proc "contextless" () -> bool {
	contention.source, _ = system.memory_create(1)
	threads: [3]system.Thread
	statuses: [3]system.Status
	threads[0], statuses[0] = system.thread_start(failing, rawptr(uintptr(0)))
	threads[1], statuses[1] = system.thread_start(failing, rawptr(uintptr(1)))
	threads[2], statuses[2] = system.thread_start(changing, nil)
	system.sleep(system.time() + CONTENTION_MILLISECONDS)
	// A loaded host can give the threads little time in that window: the
	// contention goes on until each side did its work at least once. The
	// bound only ends a hang.
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; system.time() < deadline; {
		if intrinsics.atomic_load(&contention.failures[0]) + intrinsics.atomic_load(&contention.failures[1]) > 0 && intrinsics.atomic_load(&contention.made) > 0 {
			break
		}
		system.sleep(system.time() + 10)
	}
	intrinsics.atomic_store(&contention.stop, 1)
	started := 0
	for thread, index in threads {
		if statuses[index] == .Ok {
			system.thread_wait(thread)
			started += 1
		}
	}
	for place in 0 ..< SHARED_HANDLES {
		system.close(system.Handle(contention.memories[place]))
		system.close(system.Handle(contention.budgets[place]))
	}
	system.close(contention.source)
	failures := contention.failures[0] + contention.failures[1]
	wrong := contention.wrong[0] + contention.wrong[1]
	refused := contention.refused[0] + contention.refused[1]
	system.log(.Info, "errors: under contention: ", failures, " failures from 2 threads while a third thread closed and made ", contention.made, " handles; ", wrong, " records contradict their status, ", refused, " records name no cause (Refused)")
	// A record with no cause is right only when the state changed between
	// the failure and the read: most records must name their cause.
	return started == 3 && failures > 0 && contention.made > 0 && wrong == 0 && refused * 2 < failures
}

@(rodata)
key_names := "abcdefghijklmnopqrstuvwxyz0123456789"
FAULT_CASE :: 18

// The random generator of this process (src/library/support/random).
process_generator: random.Generator

// entry runs every case once, then the measures, then shows the cases in
// a window until the process is stopped.
//
// **When it is the child** (the value `VALUE_CHILD` of its context is not
// 0), it only runs the refused `Log` operations of the measure (`child`)
// and stops with the code 0.
//
// **Else, in order:**
//
// 1. It opens its window, and maps the boot image and the debug image.
// 2. It connects to its private store, loads the modules `math` and
//    `tally`, and opens the ring of the root service.
// 3. It runs each case (`run`) and writes one log line for each, then the
//    summary: `errors: ok, 25 cases, each with the expected error record`,
//    or the count of the cases that gave another answer.
// 4. It runs the case under contention (`contend`), then the measures
//    (`measure`, `families_measure`, `refusals`), and writes the times in
//    nanoseconds.
// 5. It draws the window at each event. Tab shows the next page; a key
//    from `a` to `y`, or a press on a case, runs that case again and writes
//    its new sentence.
//
// **The stop**: with no random seed or no window, it stops with the code 1.
// Else it never returns. A wrong case does not stop it: the log says
// `WRONG:` before the sentence.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	// The random generator of this process, from the seed that its starter
	// gave: it gives the seed of each process that this one starts.
	if !random.generator_from_context(&process_generator, ctx) {
		system.log(.Info, "errors: no random seed in the context")
		system.stop(1)
	}
	if ctx.values[VALUE_CHILD] != 0 {
		child(ctx)
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "errors")
	if !ok {
		system.stop(1)
	}
	ctx_log = ctx.handles[op.CONTEXT_LOG]
	the_context = ctx
	machine = ctx.handles[system.GRANT_MACHINE]
	image_memory = ctx.handles[system.GRANT_IMAGE]
	if address, status := system.memory_map(image_memory, {}); status == .Ok {
		image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	}
	debug_names = system.debug_names_of(ctx)
	client, connected = storage.open(ctx)
	math_load()
	tally_load()
	if ctx.handles[system.GRANT_ROOT] != 0 {
		status: system.Status
		requests, status = system.ring_open(ctx.handles[system.GRANT_ROOT])
		has_requests = status == .Ok
	}

	wrong := 0
	for &item, index in cases {
		run(index)
		if !item.right {
			wrong += 1
		}
		sentence := string(item.sentence[:item.count])
		if index == FAULT_CASE {
			system.log(.Info, "errors: stack of fault: ", sentence[min(len(sentence), len("page fault at ")):])
		}
		system.log(.Info, "errors: ", key_names[index:index + 1], " ", item.text, ": ", item.right ? "" : "WRONG: ", sentence)
	}
	if wrong == 0 {
		system.log(.Info, "errors: ok, ", u64(len(cases)), " cases, each with the expected error record")
	} else {
		system.log(.Info, "errors: ", u64(wrong), " cases of ", u64(len(cases)), " gave another answer")
	}
	log_filter_check()
	kernel_details_check()
	kernel_ring_check()
	if !contend() {
		system.log(.Info, "errors: WRONG: the case under contention failed")
	}
	measure()
	families_measure(ctx)
	refusals(ctx)
	kernel_details_measure()
	system.log(.Info, "errors: a kernel operation that succeeds: ", kernel_good, " ns; one that fails, with its error record: ", kernel_failed, " ns; a direct call that succeeds: ", direct_good, " ns; one that fails: ", direct_failed, " ns")

	pressed := false
	for {
		draw(&window)
		display.wait(&window)
		for event in display.next_event(&window) {
			chosen := -1
			switch event.kind {
			case .Key:
				if event.pressed && event.code == KEY_TAB {
					shown_page = (shown_page + 1) % page_count
					system.log(.Info, "errors: the window shows the page ", u64(shown_page + 1), " of the cases")
				} else if event.pressed {
					for index in 0 ..< len(cases) {
						if rune(key_names[index]) == event.character {
							chosen = index
						}
					}
				}
			case .Pointer:
				down := event.buttons & 1 != 0
				if down && !pressed {
					chosen = case_at(event.y)
				}
				pressed = down
			case .None, .Settings_Changed, .Go_To, .Resized, .Copy_Asked, .Pasted:
				// next_event never gives None, and this window does nothing for the other events.
			}
			if chosen >= 0 {
				run(chosen)
				item := &cases[chosen]
				system.log(.Info, "errors: case ", key_names[chosen:chosen + 1], " again: ", item.right ? "" : "WRONG: ", string(item.sentence[:item.count]))
			}
		}
	}
}

// case_height gives the height of a case in the window: the line of what
// the process does, then each line of the sentence (interface.draw_text_wrapped).
case_height :: proc "contextless" (index: int) -> int {
	return (1 + max(cases[index].lines, 1)) * LINE
}

KEY_TAB :: 0x0F

// case_at gives the case that is drawn at a height of the window, or -1.
case_at :: proc "contextless" (at: int) -> int {
	y := TOP
	for index in page_first[shown_page] ..< page_first[shown_page + 1] {
		next := y + case_height(index)
		if at >= y && at < next {
			return index
		}
		y = next
	}
	return -1
}

draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_start(&window_memory, window)
	table := frame.table
	interface.draw_text(table, 16, 8, "each case makes an error for real; under it, the sentence of its record: errors.Error_Record,", graphics.colors.dim)
	interface.draw_text(table, 16, 8 + LINE, "module.Load_Error, op.Stop_Report.frames. Its key or a click runs a case again; tab: the next page", graphics.colors.dim)
	page_text: [32]u8
	interface.draw_text_right(table, WIDTH - 16, 8 + LINE, system.format(page_text[:], "page ", u64(shown_page + 1), " of ", u64(page_count)), graphics.colors.text)
	y := TOP
	first := page_first[shown_page]
	for &item, place in cases[first:page_first[shown_page + 1]] {
		index := first + place
		height := case_height(index)
		if place % 2 == 0 {
			interface.draw_rectangle(table, 8, y, WIDTH - 16, height, graphics.colors.track)
		}
		interface.draw_text(table, 16, y, key_names[index:index + 1], graphics.colors.dim)
		interface.draw_text(table, 32, y, item.text, graphics.colors.dim)
		interface.draw_text(table, 440, y, item.expected, graphics.colors.text)
		interface.draw_text(table, 640, y, item.right ? "the expected record" : "another answer", item.right ? graphics.colors.text : graphics.colors.failed)
		color: u32 = item.right ? graphics.colors.text : graphics.colors.failed
		// The whole sentence, on the lines that case_height counted.
		interface.draw_text_wrapped(table, 32, y + LINE, SENTENCE_ROOM, string(item.sentence[:item.count]), color)
		y += height
	}
	y += 8
	line: [192]u8
	interface.draw_text_wrapped(table, 16, y, WIDTH - 32, system.format(line[:], "a failure with its error record: ", kernel_failed, " ns in a kernel operation (success: ", kernel_good, " ns), ", direct_failed, " ns in a direct call (success: ", direct_good, " ns)"), graphics.colors.dim)
	interface.window_frame_end(&window_memory.drawing, &frame, window)
}
