package root

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:support/disk_program"
import "modus:support/system"

// The budget of each program that this service starts. The module asks for
// it: the table Budget of its file, which the build writes from the
// constant MODULE_BUDGET of its source and the pages that the tool counts
// (docs/MODULE_CONTRACT.md, "The budget that a module asks for"). This
// service decides: it accepts the request up to the largest
// budget of a program, limits a request above it, and keeps one table of
// exceptions, each with its reason. The budget of a program of the boot
// image comes from the budget of this service; the budget of a disk
// program comes from the one budget of the disk programs. It returns when
// the program stops.

// The budget of a module that asks for nothing, and of each part of a
// request that is 0.
LEAST_BUDGET :: system.Budget_Request{pages = 2048, programs = 1, threads = 1}

// The most that a program of the boot image with no exception gets. A
// request above it starts with this. A disk program has a smaller largest
// budget of its own (disk_program.LARGEST_BUDGET).
LARGEST_BUDGET :: system.Budget_Request{pages = 16384, programs = 8, threads = 32}

// The processor time of a program is one processor for each of its threads.
PROCESSOR_OF_A_THREAD :: 1_000_000

// The log records of each second. The kernel gives this service
// op.LOG_RECORDS_OF_THE_MACHINE, the records that the drain of the serial
// port always keeps, and each budget holds its part: a program that starts
// takes its records from this service, and gives them back at its stop
// (src/md/features/log_side_channels.md). The sum of every part fits:
//   - this service keeps LOG_RECORDS_OF_THIS_SERVICE for its own lines;
//   - the programs of the table of exceptions take their rows;
//   - each other program of the boot image, and each disk program, takes
//     LOG_RECORDS_OF_A_PROGRAM: what is left, for each slot that is left.
LOG_RECORDS_OF_THIS_SERVICE :: 120 // Its lines of the starts, the stops and the calls, many in the first seconds.
// The program slots of the budget of this service: the 64 of the kernel
// less its own.
PROGRAM_SLOTS :: 63
// The log records of the rows of log_records_exceptions. A row is a
// constant, so that the compiler checks the sum.
LOG_RECORDS_OF_LIMITS :: 40 // Its burst of 100 reaches the limit.
LOG_RECORDS_OF_LOG_READER :: 112 // Its storm child takes 100 (log_reader.STORM_LOG_RECORDS), and it keeps 12.
LOG_RECORDS_OF_CONSOLE :: 72 // Its 12 call hosts take 4 each, and it keeps 24 for its echo and its results.
LOG_RECORDS_OF_COMPOSITOR :: 48 // The line of each element of each window that moves.
LOG_RECORDS_OF_INSPECT :: 36 // The rows of its tables.
LOG_RECORDS_OF_RINGS :: 36 // Its 6 nodes take 4 each, and it keeps 12.
LOG_RECORDS_OF_LOCKS :: 32 // Its 4 lockers and its churn child take 4 each, and it keeps 12.
LOG_RECORDS_OF_FRAMES :: 28 // Its 4 twins take 4 each, and it keeps 12.
LOG_RECORDS_OF_IMPORTS :: 16 // Its 2 children take 4 each, and it keeps 8.
LOG_RECORDS_OF_THE_EXCEPTIONS :: LOG_RECORDS_OF_LIMITS + LOG_RECORDS_OF_LOG_READER + LOG_RECORDS_OF_CONSOLE + LOG_RECORDS_OF_COMPOSITOR + LOG_RECORDS_OF_INSPECT + LOG_RECORDS_OF_RINGS + LOG_RECORDS_OF_LOCKS + LOG_RECORDS_OF_FRAMES + LOG_RECORDS_OF_IMPORTS
LOG_RECORD_EXCEPTIONS :: 9
LOG_RECORDS_OF_A_PROGRAM :: (op.LOG_RECORDS_OF_THE_MACHINE - LOG_RECORDS_OF_THIS_SERVICE - LOG_RECORDS_OF_THE_EXCEPTIONS) / (PROGRAM_SLOTS - LOG_RECORD_EXCEPTIONS)
// A program that writes needs the records of the longest line of system.log.
#assert(LOG_RECORDS_OF_A_PROGRAM >= system.LOG_RECORDS_OF_A_LINE)
#assert(LOG_RECORDS_OF_THIS_SERVICE + LOG_RECORDS_OF_THE_EXCEPTIONS + (PROGRAM_SLOTS - LOG_RECORD_EXCEPTIONS) * LOG_RECORDS_OF_A_PROGRAM <= op.LOG_RECORDS_OF_THE_MACHINE)

// An exception of this table: one program of the boot image that gets
// another largest budget, or another limit of processor time. A part that
// is 0 keeps the rule of each program.
Budget_Exception :: struct {
	name:      string,
	largest:   system.Budget_Request, // In place of LARGEST_BUDGET, for each part that is not 0.
	processor: u64, // In place of one processor for each thread.
}

@(rodata)
budget_exceptions := [?]Budget_Exception {
	// It maps 64 MiB of large pages and two ranges of 1 GiB with their page
	// tables: the test of the address space needs them, and no other
	// program asks for that much.
	{name = "address_space", largest = {pages = 41984}},
	// Its cases reach the limit of processor time: a small limit makes
	// them short.
	{name = "limits", processor = 1_500_000},
}

// One program of the boot image that gets other log records of each second
// than LOG_RECORDS_OF_A_PROGRAM: its children, and the lines that it writes
// fast.
Log_Records_Exception :: struct {
	name:        string,
	log_records: u64,
}

// Each row is in LOG_RECORDS_OF_THE_EXCEPTIONS, and the compiler checks
// their count: the sum of every part fits op.LOG_RECORDS_OF_THE_MACHINE.
@(rodata)
log_records_exceptions := [?]Log_Records_Exception {
	{"limits", LOG_RECORDS_OF_LIMITS},
	{"log_reader", LOG_RECORDS_OF_LOG_READER},
	{"console", LOG_RECORDS_OF_CONSOLE},
	{"compositor", LOG_RECORDS_OF_COMPOSITOR},
	{"inspect", LOG_RECORDS_OF_INSPECT},
	{"rings", LOG_RECORDS_OF_RINGS},
	{"locks", LOG_RECORDS_OF_LOCKS},
	{"frames", LOG_RECORDS_OF_FRAMES},
	{"imports", LOG_RECORDS_OF_IMPORTS},
}
#assert(len(log_records_exceptions) == LOG_RECORD_EXCEPTIONS)

// budget_exception_of gives the exception of a program of the boot image,
// by its name. A disk program never asks: its name gives nothing.
budget_exception_of :: proc "contextless" (name: string) -> (exception: Budget_Exception, found: bool) {
	for item in budget_exceptions {
		if item.name == name {
			return item, true
		}
	}
	return {}, false
}

// log_records_of gives the log records of each second of a program of the
// boot image, by its name.
log_records_of :: proc "contextless" (name: string) -> u64 {
	for item in log_records_exceptions {
		if item.name == name {
			return item.log_records
		}
	}
	return LOG_RECORDS_OF_A_PROGRAM
}

// budget_decided reads the request of a module file and decides it by the
// rule of the starter, with a line on the log for each part that the
// program gets less of than it asks. who names the largest budget in that
// line. A file that is not valid asks for nothing: the loader refuses it
// after.
budget_decided :: proc "contextless" (file: []u8, name: string, largest: system.Budget_Request, who: string) -> system.Budget_Request {
	request: system.Budget_Request
	if module.validate(file) == .None {
		request, _ = module.budget_request(file)
	}
	granted, limited := system.budget_decide(request, LEAST_BUDGET, largest)
	for part in limited {
		system.log_in("programs", .Warning, "root: ", system.Module_Name{name}, " asks for ", system.budget_part(request, part), " ", system.budget_part_names[part], ", and ", who, " gets at most ", system.budget_part(largest, part), ": it starts with ", system.budget_part(granted, part))
	}
	return granted
}

// budget_of gives the budget of a program of the boot image from the
// request of its module file, with the exception of its name.
budget_of :: proc "contextless" (file: []u8, name: string) -> system.Budget_Amounts {
	largest := LARGEST_BUDGET
	exception, has_exception := budget_exception_of(name)
	if has_exception {
		largest.pages = exception.largest.pages != 0 ? exception.largest.pages : largest.pages
		largest.programs = exception.largest.programs != 0 ? exception.largest.programs : largest.programs
		largest.threads = exception.largest.threads != 0 ? exception.largest.threads : largest.threads
	}
	granted := budget_decided(file, name, largest, "a program")
	own, _ := system.budget_read()
	amounts := system.Budget_Amounts {
		pages    = granted.pages,
		programs = granted.programs,
		threads  = granted.threads,
	}
	processor := has_exception && exception.processor != 0 ? exception.processor : granted.threads * PROCESSOR_OF_A_THREAD
	amounts.processor = min(processor, own.processor)
	amounts.log_records = log_records_of(name)
	return amounts
}

// The one budget that pays each disk program (disk_program.PROGRAMS_BUDGET).
// 0 until the first disk program: a machine that starts none keeps its
// pages. It stays after its programs stop: what they held returns to it.
disk_programs_budget: system.Handle

// disk_programs_budget_get gives the budget of the disk programs, and makes
// it from the budget of this service the first time.
disk_programs_budget_get :: proc "contextless" () -> (budget: system.Handle, status: system.Status) {
	if disk_programs_budget != 0 {
		return disk_programs_budget, .Ok
	}
	own, _ := system.budget_read()
	shared := disk_program.PROGRAMS_BUDGET
	budget, status = system.budget_create({pages = shared.pages, programs = shared.programs, threads = shared.threads, processor = min(disk_program.PROGRAMS_PROCESSOR, own.processor), log_records = shared.programs * LOG_RECORDS_OF_A_PROGRAM})
	if status != .Ok {
		system.log_in("programs", .Warning, "root: cannot make the budget of the disk programs: status ", status)
		return 0, status
	}
	disk_programs_budget = budget
	system.log_in("programs", .Info, "root: the disk programs share one budget of ", system.Size{shared.pages, .Pages}, ", ", shared.programs, " programs and ", shared.threads, " threads")
	return budget, .Ok
}

// disk_budget_of gives the budget of a disk program from the request of
// its module file: at most disk_program.LARGEST_BUDGET, with no exception,
// and limits in time that the budget of the disk programs bounds.
disk_budget_of :: proc "contextless" (file: []u8, name: string, disk_programs: system.Handle) -> system.Budget_Amounts {
	granted := budget_decided(file, name, disk_program.LARGEST_BUDGET, "a disk program")
	holds, _ := system.budget_read(disk_programs)
	return {
		pages = granted.pages,
		programs = granted.programs,
		threads = granted.threads,
		processor = min(granted.threads * PROCESSOR_OF_A_THREAD, holds.processor),
		log_records = min(LOG_RECORDS_OF_A_PROGRAM, holds.log_records),
	}
}

// budget_refusal_log writes the line of a start that failed for the budget:
// what the program was to get, what the budget that pays holds (0: the
// budget of this service), and the first part that is short. holder names
// that budget in the line. When it holds each part, the budget of the
// program was too small for its own load: its request is too small.
budget_refusal_log :: proc "contextless" (name: string, amounts: system.Budget_Amounts, holder_budget: system.Handle, holder: string) {
	needed := system.Budget_Request{pages = amounts.pages, programs = amounts.programs, threads = amounts.threads}
	holder_amounts, _ := system.budget_read(holder_budget)
	holds := system.Budget_Request{pages = holder_amounts.pages, programs = holder_amounts.programs, threads = holder_amounts.threads}
	if part, short := system.budget_first_short_part(needed, holds); short {
		system.log_in("programs", .Warning, "root: cannot start ", system.Module_Name{name}, ": it gets ", system.budget_part(needed, part), " ", system.budget_part_names[part], ", and the budget of ", holder, " holds ", system.budget_part(holds, part))
		return
	}
	// The log records of each second move as the pages; the processor time
	// of the program is at most the limit of the holder.
	if holder_amounts.log_records < amounts.log_records {
		system.log_in("programs", .Warning, "root: cannot start ", system.Module_Name{name}, ": it gets ", amounts.log_records, " log records of each second, and the budget of ", holder, " holds ", holder_amounts.log_records)
		return
	}
	if holder_amounts.processor < amounts.processor {
		system.log_in("programs", .Warning, "root: cannot start ", system.Module_Name{name}, ": it gets ", amounts.processor, " microseconds of processor time in each second, and the limit of the budget of ", holder, " is ", holder_amounts.processor)
		return
	}
	system.log_in("programs", .Warning, "root: cannot start ", system.Module_Name{name}, ": its budget of ", system.Size{amounts.pages, .Pages}, ", ", amounts.programs, " programs and ", amounts.threads, " threads is too small for its load: the module asks for too little")
}
