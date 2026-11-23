package root

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/reference_screen"
import "modus:contract/value_kinds"
import "modus:disk_process"
import "modus:system"

// The budget of each process that this service starts. The module asks for
// it: the table Budget of its file, which the build writes from the
// constant MODULE_BUDGET of its source and the pages that the tool counts
// (docs/MODULE_CONTRACT.md, "The budget that a module asks for"). This
// service decides: it accepts the request up to the largest budget of a
// process, which is a share of the memory of the machine, and limits a
// request above it. A short table holds the limits in time of a few
// modules, each with its reason. The budget of a process of the boot image
// comes from the budget of this service; the budget of a disk process
// comes from the one budget of the disk processes. It returns when the
// process stops.

// The budget of a module that asks for nothing, and of each part of a
// request that is 0. A module with a window states its size, and the tool
// counts its pictures at the largest scale that the setting takes
// (docs/MODULE_CONTRACT.md, "The budget that a module asks for"), so the
// least budget does not grow with the scale.
LEAST_BUDGET :: system.Budget_Request{pages = 2048, processes = 1, threads = 1}

// The most that a process of the boot image gets on this machine: one share
// of the pages and the threads that this service held at its start
// (module.largest_budget_of_machine). A request above it starts with this.
// Until budgets_start reads the budget, the least largest budget.
largest_budget: system.Budget_Request = module.LARGEST_BUDGET_LEAST
// The share in force: the value of the plan of principal 0, or the default
// (src/md/features/module_budget_request.md, "The largest budget is a
// share of the machine").
budget_share: u64 = module.LARGEST_BUDGET_SHARE_DEFAULT
// What this service held at its start: the share is of the machine, not of
// what the processes left.
machine_at_start: system.Budget_Request
// budgets_start reads the budget of this service once, before the first
// start, and decides the largest budget of this machine. The pages of a
// later read are lower by what the processes hold, so the share is of the
// machine, not of what is left.
budgets_start :: proc "contextless" () {
	own, _ := system.budget_read()
	machine_at_start = {pages = own.pages, processes = own.processes, threads = own.threads}
	largest_budget = module.largest_budget_of_machine(machine_at_start, budget_share)
}

// budget_share_take is the one place where the share that the plan of
// principal 0 gives enters this service: the word passes its border
// (module.budget_share_of_word), and the largest budget of each next start
// follows it. A refused word changes nothing. No plan gives the value yet:
// the settings of the plan that spend a resource of the machine are a
// later step, and until then the share is the default.
budget_share_take :: proc "contextless" (word: u64) -> bool {
	share := module.budget_share_of_word(word) or_return
	budget_share = share
	largest_budget = module.largest_budget_of_machine(machine_at_start, budget_share)
	return true
}

// screen_in_force gives the size of the screen of this machine: the screen
// of the firmware, or with none, the size of the screen of memory at the
// start of the compositor, else the reference screen. A size that a viewer
// asks later is paid from the pages that each budget has left
// (src/md/features/screen_of_memory.md).
screen_in_force :: proc "contextless" () -> (width, height: u64) {
	if root_screen_values[0] != 0 && root_screen_values[1] != 0 {
		return root_screen_values[0], root_screen_values[1]
	}
	if screen_of_memory_size[0] != 0 && screen_of_memory_size[1] != 0 {
		return u64(screen_of_memory_size[0]), u64(screen_of_memory_size[1])
	}
	return reference_screen.WIDTH, reference_screen.HEIGHT
}

// The rows of the plan that lower the pages of the screen pictures of a
// module. The cost of the screen is a machine policy, which only a plan of
// principal 0 gives, and which may lower that cost and never raise it
// (module.budget_request_of_screen). The plan carries no row of machine
// policy yet (src/md/features/declarations.md), so the table stays empty
// and each module pays its whole screen.
PLAN_SCREEN_ROW_CAPACITY :: 8
Plan_Screen_Row :: struct {
	name:  system.Name,
	pages: u64,
}
plan_screen_rows: [PLAN_SCREEN_ROW_CAPACITY]Plan_Screen_Row
plan_screen_row_count: int
// The line of a refused request names the limit of screen pictures.
#assert(module.SCREEN_PICTURES_LIMIT == 4)

// plan_screen_pages_of gives the pages that a row of the plan gives the
// screen pictures of a module, or 0: no row.
plan_screen_pages_of :: proc "contextless" (name: string) -> u64 {
	for &row in plan_screen_rows[:plan_screen_row_count] {
		if system.name_of(row.name[:]) == name {
			return row.pages
		}
	}
	return 0
}

// The processor time of a process is one processor for each of its threads.
PROCESSOR_OF_A_THREAD :: 1_000_000

// The log records of each second. The kernel gives this service
// op.LOG_RECORDS_OF_THE_MACHINE_MOST, and each budget holds its part: a process
// that starts takes its records from this service, and gives them back at
// its stop (src/md/features/log_side_channels.md). The sum of every part
// fits: each process of the boot image and each disk process takes at most
// LOG_RECORDS_OF_A_PROCESS, in at most PROCESS_SLOTS slots, and this
// service keeps LOG_RECORDS_OF_THIS_SERVICE for its own lines.
LOG_RECORDS_OF_A_PROCESS :: op.LOG_RECORDS_OF_A_PROCESS
LOG_RECORDS_OF_THIS_SERVICE :: op.LOG_RECORDS_OF_A_PROCESS
// The process slots of the budget of this service: the slots of the kernel
// less its own.
PROCESS_SLOTS :: op.PROCESS_SLOTS_MOST - 1
#assert(PROCESS_SLOTS * LOG_RECORDS_OF_A_PROCESS + LOG_RECORDS_OF_THIS_SERVICE <= op.LOG_RECORDS_OF_THE_MACHINE_MOST)
// The log records of the rows of log_records_exceptions: none above
// LOG_RECORDS_OF_A_PROCESS, so the sum above holds.
LOG_RECORDS_OF_LIMITS :: 40 // Its burst of 100 reaches the limit.
#assert(LOG_RECORDS_OF_LIMITS <= LOG_RECORDS_OF_A_PROCESS)
// The test of the record output log: the log of the kernel refuses each line
// of log_flood, whatever the speed of the machine, and its wired log holds
// each one (src/md/features/log_facts.md, "The record output `log`").
LOG_RECORDS_OF_LOG_FLOOD :: 0
#assert(LOG_RECORDS_OF_LOG_FLOOD <= LOG_RECORDS_OF_A_PROCESS)

// One process of the boot image that gets another limit of processor time
// than one processor for each thread. A request holds no limit in time, so
// these rows are the one place of such a limit. No row gives pages: the
// largest budget of a process is the share of the machine for each one.
Processor_Exception :: struct {
	name:      string,
	processor: u64, // In place of one processor for each thread.
}

@(rodata)
processor_exceptions := [?]Processor_Exception {
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
	{"log_flood", LOG_RECORDS_OF_LOG_FLOOD},
}

// processor_of gives the limit of processor time of a process of the boot
// image, by its name, or false: one processor for each thread. A disk
// process never asks: its name gives nothing.
processor_of :: proc "contextless" (name: string) -> (processor: u64, found: bool) {
	for item in processor_exceptions {
		if item.name == name {
			return item.processor, true
		}
	}
	return 0, false
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
	// The screen pictures of the module have the size of the screen of this
	// machine. A request past the limit of pictures gets no screen: the
	// module gets the rest of its request, and one line names the part.
	// A budget is a reservation of the pages of this service: the pictures
	// of a screen of memory are paid at the size of its start, never at a
	// size that a viewer may ask one day (src/md/features/screen_of_memory.md,
	// "The budget of a screen of memory").
	width, height := screen_in_force()
	with_screen, screen_ok := module.budget_request_of_screen(request, width, height, plan_screen_pages_of(name))
	if !screen_ok {
		system.log_fact(.Warning, Budget_Screen_Pictures_Refused{screen_pictures = request.screen_pictures, started_process = module_name_field(name)})
		with_screen = request
		with_screen.screen_pictures = 0
	}
	request = with_screen
	granted, limited := system.budget_decide(request, LEAST_BUDGET, largest)
	for part in limited {
		system.log_fact(.Warning, Budget_Part_Limited{asked = system.budget_part(request, part), largest = system.budget_part(largest, part), granted = system.budget_part(granted, part), started_process = module_name_field(name), budget_part = text_field(system.budget_part_names[part], 16), largest_of = text_field(who, 16)})
	}
	return granted
}

// budget_of gives the budget of a process of the boot image from the
// request of its module file, up to the largest budget of this machine.
budget_of :: proc "contextless" (file: []u8, name: string) -> system.Budget_Amounts {
	exception_processor, has_exception := processor_of(name)
	granted := budget_decided(file, name, largest_budget, "a process")
	own, _ := system.budget_read()
	amounts := system.Budget_Amounts {
		pages    = granted.pages,
		processes = granted.processes,
		threads  = granted.threads,
	}
	processor := has_exception ? exception_processor : granted.threads * PROCESSOR_OF_A_THREAD
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
