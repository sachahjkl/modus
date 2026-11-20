package root

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:support/disk_process"
import "modus:support/system"

// The budget of each process that this service starts. The module asks for
// it: the table Budget of its file, which the build writes from the
// constant MODULE_BUDGET of its source and the pages that the tool counts
// (docs/MODULE_CONTRACT.md, "The budget that a module asks for"). This
// service decides: it accepts the request up to the largest
// budget of a process, limits a request above it, and keeps one table of
// exceptions, each with its reason. The budget of a process of the boot
// image comes from the budget of this service; the budget of a disk
// process comes from the one budget of the disk processes. It returns when
// the process stops.

// The budget of a module that asks for nothing, and of each part of a
// request that is 0. A module with a window states its size, and the tool
// counts its pictures at the largest scale that the setting takes
// (docs/MODULE_CONTRACT.md, "The budget that a module asks for"), so the
// least budget does not grow with the scale.
LEAST_BUDGET :: system.Budget_Request{pages = 2048, processes = 1, threads = 1}

// The most that a process of the boot image with no exception gets. A
// request above it starts with this. A disk process has a smaller largest
// budget of its own (disk_process.LARGEST_BUDGET).
LARGEST_BUDGET :: system.Budget_Request{pages = 16384, processes = 8, threads = 32}

// The processor time of a process is one processor for each of its threads.
PROCESSOR_OF_A_THREAD :: 1_000_000

// The log records of each second. The kernel gives this service
// op.LOG_RECORDS_OF_THE_MACHINE, and each budget holds its part: a process
// that starts takes its records from this service, and gives them back at
// its stop (src/md/features/log_side_channels.md). The sum of every part
// fits: each process of the boot image and each disk process takes at most
// LOG_RECORDS_OF_A_PROCESS, in at most PROCESS_SLOTS slots, and this
// service keeps LOG_RECORDS_OF_THIS_SERVICE for its own lines.
LOG_RECORDS_OF_A_PROCESS :: op.LOG_RECORDS_OF_A_PROCESS
LOG_RECORDS_OF_THIS_SERVICE :: op.LOG_RECORDS_OF_A_PROCESS
// The process slots of the budget of this service: the slots of the kernel
// less its own.
PROCESS_SLOTS :: op.PROCESS_SLOTS_OF_THE_MACHINE - 1
#assert(PROCESS_SLOTS * LOG_RECORDS_OF_A_PROCESS + LOG_RECORDS_OF_THIS_SERVICE <= op.LOG_RECORDS_OF_THE_MACHINE)
// The log records of the rows of log_records_exceptions: none above
// LOG_RECORDS_OF_A_PROCESS, so the sum above holds.
LOG_RECORDS_OF_LIMITS :: 40 // Its burst of 100 reaches the limit.
#assert(LOG_RECORDS_OF_LIMITS <= LOG_RECORDS_OF_A_PROCESS)

// An exception of this table: one process of the boot image that gets
// another largest budget, or another limit of processor time. A part that
// is 0 keeps the rule of each process.
Budget_Exception :: struct {
	name:      string,
	largest:   system.Budget_Request, // In place of LARGEST_BUDGET, for each part that is not 0.
	processor: u64, // In place of one processor for each thread.
}

@(rodata)
budget_exceptions := [?]Budget_Exception {
	// It maps 64 MiB of large pages and two ranges of 1 GiB with their page
	// tables: the test of the address space needs them, and no other
	// process asks for that much. And its window draws its text, whose
	// glyph memory is 354 pages more.
	{name = "address_space", largest = {pages = 42338}},
	// Its cases reach the limit of processor time: a small limit makes
	// them short.
	{name = "limits", processor = 1_500_000},
}

// One process of the boot image that gets fewer log records of each second
// than LOG_RECORDS_OF_A_PROCESS.
Log_Records_Exception :: struct {
	name:        string,
	log_records: u64,
}

// Each row is a named constant at most LOG_RECORDS_OF_A_PROCESS, checked by
// the compiler above.
@(rodata)
log_records_exceptions := [?]Log_Records_Exception {
	{"limits", LOG_RECORDS_OF_LIMITS},
}

// budget_exception_of gives the exception of a process of the boot image,
// by its name. A disk process never asks: its name gives nothing.
budget_exception_of :: proc "contextless" (name: string) -> (exception: Budget_Exception, found: bool) {
	for item in budget_exceptions {
		if item.name == name {
			return item, true
		}
	}
	return {}, false
}

// log_records_of gives the log records of each second of a process of the
// boot image, by its name.
log_records_of :: proc "contextless" (name: string) -> u64 {
	for item in log_records_exceptions {
		if item.name == name {
			return item.log_records
		}
	}
	return LOG_RECORDS_OF_A_PROCESS
}

// budget_decided reads the request of a module file and decides it by the
// rule of the starter, with a line on the log for each part that the
// process gets less of than it asks. who names the largest budget in that
// line. A file that is not valid asks for nothing: the loader refuses it
// after.
budget_decided :: proc "contextless" (file: []u8, name: string, largest: system.Budget_Request, who: string) -> system.Budget_Request {
	request: system.Budget_Request
	if module.validate(file) == .None {
		request, _ = module.budget_request(file)
	}
	granted, limited := system.budget_decide(request, LEAST_BUDGET, largest)
	for part in limited {
		system.log_fact(.Warning, Budget_Part_Limited{asked = system.budget_part(request, part), largest = system.budget_part(largest, part), granted = system.budget_part(granted, part), started_process = module_name_field(name), budget_part = text_field(system.budget_part_names[part], 16), largest_of = text_field(who, 16)})
	}
	return granted
}

// budget_of gives the budget of a process of the boot image from the
// request of its module file, with the exception of its name.
budget_of :: proc "contextless" (file: []u8, name: string) -> system.Budget_Amounts {
	largest := LARGEST_BUDGET
	exception, has_exception := budget_exception_of(name)
	if has_exception {
		largest.pages = exception.largest.pages != 0 ? exception.largest.pages : largest.pages
		largest.processes = exception.largest.processes != 0 ? exception.largest.processes : largest.processes
		largest.threads = exception.largest.threads != 0 ? exception.largest.threads : largest.threads
	}
	granted := budget_decided(file, name, largest, "a process")
	own, _ := system.budget_read()
	amounts := system.Budget_Amounts {
		pages    = granted.pages,
		processes = granted.processes,
		threads  = granted.threads,
	}
	processor := has_exception && exception.processor != 0 ? exception.processor : granted.threads * PROCESSOR_OF_A_THREAD
	amounts.processor = min(processor, own.processor)
	amounts.log_records = log_records_of(name)
	return amounts
}

// The one budget that pays each disk process (disk_process.PROCESSES_BUDGET).
// 0 until the first disk process: a machine that starts none keeps its
// pages. It stays after its processes stop: what they held returns to it.
disk_processes_budget: system.Handle

// disk_processes_budget_get gives the budget of the disk processes, and makes
// it from the budget of this service the first time.
disk_processes_budget_get :: proc "contextless" () -> (budget: system.Handle, status: system.Status) {
	if disk_processes_budget != 0 {
		return disk_processes_budget, .Ok
	}
	own, _ := system.budget_read()
	shared := disk_process.PROCESSES_BUDGET
	budget, status = system.budget_create({pages = shared.pages, processes = shared.processes, threads = shared.threads, processor = min(disk_process.SHARED_PROCESSOR_TIME, own.processor), log_records = shared.processes * LOG_RECORDS_OF_A_PROCESS})
	if status != .Ok {
		system.log_fact(.Warning, Disk_Processes_Budget_Refused{status = status})
		return 0, status
	}
	disk_processes_budget = budget
	system.log_fact(.Info, Disk_Processes_Budget_Made{pages = value_kinds.Size_In_Pages(shared.pages), processes = shared.processes, threads = shared.threads})
	return budget, .Ok
}

// disk_budget_of gives the budget of a disk process from the request of
// its module file: at most disk_process.LARGEST_BUDGET, with no exception,
// and limits in time that the budget of the disk processes bounds.
disk_budget_of :: proc "contextless" (file: []u8, name: string, disk_processes: system.Handle) -> system.Budget_Amounts {
	granted := budget_decided(file, name, disk_process.LARGEST_BUDGET, "a disk process")
	holds, _ := system.budget_read(disk_processes)
	return {
		pages = granted.pages,
		processes = granted.processes,
		threads = granted.threads,
		processor = min(granted.threads * PROCESSOR_OF_A_THREAD, holds.processor),
		log_records = min(LOG_RECORDS_OF_A_PROCESS, holds.log_records),
	}
}

// budget_refusal_log writes the line of a start that failed for the budget:
// what the process was to get, what the budget that pays holds (0: the
// budget of this service), and the first part that is short. holder names
// that budget in the line. When it holds each part, the budget of the
// process was too small for its own load: its request is too small.
budget_refusal_log :: proc "contextless" (name: string, amounts: system.Budget_Amounts, holder_budget: system.Handle, holder: string) {
	needed := system.Budget_Request{pages = amounts.pages, processes = amounts.processes, threads = amounts.threads}
	holder_amounts, _ := system.budget_read(holder_budget)
	holds := system.Budget_Request{pages = holder_amounts.pages, processes = holder_amounts.processes, threads = holder_amounts.threads}
	if part, short := system.budget_first_short_part(needed, holds); short {
		system.log_fact(.Warning, Start_Refused_Budget_Part{needed = system.budget_part(needed, part), held = system.budget_part(holds, part), refused_process = module_name_field(name), budget_part = text_field(system.budget_part_names[part], 16), paying_budget = text_field(holder, 24)})
		return
	}
	// The log records of each second move as the pages; the processor time
	// of the process is at most the limit of the holder.
	if holder_amounts.log_records < amounts.log_records {
		system.log_fact(.Warning, Start_Refused_Log_Records{log_records = amounts.log_records, held_log_records = holder_amounts.log_records, refused_process = module_name_field(name), paying_budget = text_field(holder, 24)})
		return
	}
	if holder_amounts.processor < amounts.processor {
		system.log_fact(.Warning, Start_Refused_Processor_Time{processor = amounts.processor, processor_limit = holder_amounts.processor, refused_process = module_name_field(name), paying_budget = text_field(holder, 24)})
		return
	}
	system.log_fact(.Warning, Start_Refused_Budget_Too_Small{pages = value_kinds.Size_In_Pages(amounts.pages), processes = amounts.processes, threads = amounts.threads, refused_process = module_name_field(name)})
}
