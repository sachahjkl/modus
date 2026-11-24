package root

import "internal:root/session_budgets"
import "internal:root/start_policy_rules"
import "modus:contract/call_outcome"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/reference_screen"
import "modus:contract/ring"
import "modus:contract/root_plan_values"
import "modus:contract/root_ring"
import "modus:contract/start_list"
import "modus:contract/value_kinds"
import "modus:contract/wide_grants"
import "modus:disk_process"
import "modus:principals"
import "modus:system"

// The budget of each process that this service starts
// (src/md/features/module_budget_request.md). The module gives its floor:
// the table Floor of its file, which the build writes. This service adds
// the parts of the machine and of the plan to it, the floor of the start,
// and decides the size: twice that floor by default, at most a share of
// the machine, never below the floor. The floors of the start list are
// reserved first, and the pages left are divided by one rule before the
// first row starts, so the start order decides nothing. A floor that this
// service cannot pay refuses the start with one line that names both
// amounts. The budget of a process of the boot image comes from the budget
// of this service; the budget of a disk process comes from the one budget
// of the disk processes. It returns when the process stops.

// The most that a process of the boot image gets on this machine: one share
// of the pages and the threads that this service held at its start
// (module.largest_budget_of_machine). No size passes it; a floor above it
// is the size. Until budgets_start reads the budget, the least largest
// budget.
largest_budget: system.Budget_Amounts = module.LARGEST_BUDGET_LEAST
// The share in force: the value of the plan of principal 0, or the default
// (src/md/features/module_budget_request.md, "The size, part by part").
budget_share: u64 = module.LARGEST_BUDGET_SHARE_DEFAULT
// The growth factor in force: the value default_growth_factor of the plan
// of principal 0, or the default of the contract. No plan gives the value
// yet (growth_factor_take).
growth_factor: u64 = module.DEFAULT_GROWTH_FACTOR
// What this service held at its start: the share is of the machine, not of
// what the processes left.
machine_at_start: system.Budget_Amounts
// Reserved child kernel budgets and storage block ledgers for unlocked named
// principal sessions (src/md/features/several_principals.md, "The rest").
// Index 0 (machine) is never a child budget.
session_budget_handles: [principals.PRINCIPAL_CAPACITY]system.Handle
session_block_ledgers: [principals.PRINCIPAL_CAPACITY]session_budgets.Session_Block_Ledger

// session_budget_open reserves a child kernel budget and storage block ledger
// for a named principal when its session unlocks, always holding back a
// machine reserve so the session reaches its own limit before machine limits.
session_budget_open :: proc "contextless" (principal: u64) {
	if principal == principals.MACHINE || principal >= principals.PRINCIPAL_CAPACITY {
		return
	}
	if session_budget_handles[principal] != 0 {
		return
	}
	own, status := system.budget_read()
	if status != .Succeeded {
		system.log_fact(.Warning, Session_Budget_Open_Failed{principal = principal, status = status})
		return
	}
	named_slots := u64(max(principals.PRINCIPAL_CAPACITY - 1, 1))
	avail := session_budgets.Session_Budget_Amounts {
		pages          = own.pages,
		processes      = own.processes,
		threads        = own.threads,
		processor      = own.processor,
		log_records    = own.log_records,
		storage_blocks = session_budgets.DEFAULT_MACHINE_STORAGE_BLOCKS,
	}
	reserve := session_budgets.machine_reserve_for(avail)
	per_session, ok := session_budgets.compute_session_budget(avail, reserve, named_slots)
	if !ok {
		system.log_fact(.Warning, Session_Budget_Open_Failed{principal = principal, status = .Budget_Or_Capacity_Exhausted})
		return
	}
	child, create_status := system.budget_create({
		pages       = per_session.pages,
		processes   = per_session.processes,
		threads     = per_session.threads,
		processor   = per_session.processor,
		log_records = per_session.log_records,
	})
	if create_status != .Succeeded {
		system.log_fact(.Warning, Session_Budget_Open_Failed{principal = principal, status = create_status})
		return
	}
	session_budget_handles[principal] = child
	_ = session_budgets.ledger_init(&session_block_ledgers[principal], per_session.storage_blocks)
}

// session_storage_blocks_charge accounts a storage connection's block quota
// against the named principal's session storage ledger. Unbounded store limits
// (disk_process.STORE_BLOCKS_LIMIT) are capped to half of the remaining ledger
// so one store cannot starve other stores in the same session.
session_storage_blocks_charge :: proc "contextless" (principal: u64, requested: u64) -> (granted: u64, ok: bool) {
	if principal == principals.MACHINE || principal >= principals.PRINCIPAL_CAPACITY || requested == 0 {
		return requested, true
	}
	ledger := &session_block_ledgers[principal]
	if ledger.limit == 0 {
		return requested, true
	}
	charge := requested
	if requested == disk_process.STORE_BLOCKS_LIMIT {
		remaining := session_budgets.ledger_remaining(ledger)
		if remaining == 0 {
			return 0, false
		}
		charge = max(u64(1), remaining / 2)
	}
	if !session_budgets.ledger_reserve(ledger, charge) {
		return 0, false
	}
	return charge, true
}

// session_storage_blocks_release returns a disconnected storage connection's
// charged blocks to the named principal's session storage ledger.
session_storage_blocks_release :: proc "contextless" (principal: u64, charged: u64) {
	if principal == principals.MACHINE || principal >= principals.PRINCIPAL_CAPACITY || charged == 0 {
		return
	}
	_ = session_budgets.ledger_release(&session_block_ledgers[principal], charged)
}

// session_budget_close releases the reserved child budget of a named principal
// on lock or removal, returning all unused resources to the machine budget.
session_budget_close :: proc "contextless" (principal: u64) {
	if principal == principals.MACHINE || principal >= principals.PRINCIPAL_CAPACITY {
		return
	}
	if session_budget_handles[principal] != 0 {
		system.close(session_budget_handles[principal])
		session_budget_handles[principal] = 0
	}
	session_block_ledgers[principal] = {}
}

// session_budget_of returns the paying budget handle for a process of
// `principal`: its reserved session budget for a named principal when open,
// or 0 (the root service's own budget) for principal 0.
session_budget_of :: proc "contextless" (principal: u64) -> system.Handle {
	if principal == principals.MACHINE || principal >= principals.PRINCIPAL_CAPACITY {
		return 0
	}
	return session_budget_handles[principal]
}
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

// growth_factor_take is the one place where the growth factor that the
// plan of principal 0 gives enters this service: the word passes its
// border (module.growth_factor_of_word), and the size of each next start
// follows it. A refused word changes nothing.
growth_factor_take :: proc "contextless" (word: u64) -> bool {
	factor := module.growth_factor_of_word(word) or_return
	growth_factor = factor
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
// (module.floor_of_screen). The plan carries no row of machine
// policy yet (src/md/features/declarations.md), so the table stays empty
// and each module pays its whole screen.
PLAN_SCREEN_ROW_CAPACITY :: 8
Plan_Screen_Row :: struct {
	name:  system.Name,
	pages: u64,
}
plan_screen_rows: [PLAN_SCREEN_ROW_CAPACITY]Plan_Screen_Row
plan_screen_row_count: int

// plan_screen_pages_of gives the pages that a row of the plan gives the
// screen pictures of a module, or 0: no row.
plan_screen_pages_of :: proc "contextless" (name: string) -> u64 {
	if policy, _, _ := module_budget_policy_for(name); policy.has_screen_pages {
		return policy.screen_pages
	}
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

// processor_of gives the limit of processor time of a process of the boot
// image from its plan row when present, else false (one processor for each
// thread). A disk process never asks: its name gives nothing.
processor_of :: proc "contextless" (name: string) -> (processor: u64, found: bool) {
	if policy, _, _ := module_budget_policy_for(name); policy.has_processor {
		return policy.processor, true
	}
	return 0, false
}

// log_records_of gives the log records of each second of a process of the
// boot image from its plan row when present, else LOG_RECORDS_OF_A_PROCESS.
log_records_of :: proc "contextless" (name: string) -> u64 {
	if policy, _, _ := module_budget_policy_for(name); policy.has_log_records {
		return policy.log_records
	}
	return LOG_RECORDS_OF_A_PROCESS
}

// planned_size_of gives the target page size for a module of the boot image:
// its plan row (pages or share parts of machine_at_start.pages) when set,
// else system.budget_size(floor_pages, largest_budget.pages, growth_factor).
// A plan row below floor_pages raises to floor_pages and sets row_below_floor.
planned_size_of :: proc "contextless" (name: string, floor_pages: u64) -> (size: u64, row_below_floor: bool, row_pages: u64) {
	policy, _, _ := module_budget_policy_for(name)
	if planned, has_size := root_plan_values.planned_pages_of(policy, machine_at_start.pages); has_size {
		if planned < floor_pages {
			return floor_pages, true, planned
		}
		step := u64(op.MEMORY_LIST_ENTRIES)
		rounded := planned > max(u64) - (step - 1) ? planned : ((planned + step - 1) / step) * step
		return rounded, false, planned
	}
	return system.budget_size(floor_pages, largest_budget.pages, growth_factor), false, 0
}

// disk_processes_class_budget gives the shared budget amounts and processor
// time of the disk processes class, applying any plan overrides from the
// root plan over the defaults in modus:disk_process.
disk_processes_class_budget :: proc "contextless" () -> (amounts: system.Budget_Amounts, processor: u64) {
	amounts = disk_process.PROCESSES_BUDGET
	processor = disk_process.SHARED_PROCESSOR_TIME
	if root_plan_in_force.disk_processes_pages != 0 {
		amounts.pages = root_plan_in_force.disk_processes_pages
	}
	if root_plan_in_force.disk_processes_processes != 0 {
		amounts.processes = root_plan_in_force.disk_processes_processes
	}
	if root_plan_in_force.disk_processes_threads != 0 {
		amounts.threads = root_plan_in_force.disk_processes_threads
	}
	if root_plan_in_force.disk_processes_processor != 0 {
		processor = root_plan_in_force.disk_processes_processor
	}
	return amounts, processor
}

// start_floor_of gives the floor of the start of a module: the floor of its
// file, the pages of its screen pictures at the screen of this machine,
// and, for a module of the boot image, the pages that this service adds
// from the plan: the audits of the collector of principal 0 and the
// wirings of the start list for the start policy. A disk process gets no
// such part: its name is a nickname that a file chooses. ok is false for a file that is not valid, a file with no table
// Floor, a floor of no process or no thread, a floor of screen pictures
// past the limit, and a sum past 64 bits: the start does not happen, and
// one line names the module.
start_floor_of :: proc "contextless" (file: []u8, name: string, principal: u64, of_the_image: bool) -> (floor: system.Floor, ok: bool) {
	if module.validate(file) != .None {
		return {}, false
	}
	floor = module.floor_read(file) or_return
	if !system.floor_usable(floor) {
		return {}, false
	}
	// The screen pictures of the module have the size of the screen of this
	// machine: a budget is a reservation of the pages of this service, paid
	// at the size of the screen at its start, never at a size that a
	// viewer may ask one day (src/md/features/screen_of_memory.md, "The
	// budget of a screen of memory").
	width, height := screen_in_force()
	floor = module.floor_of_screen(floor, width, height, plan_screen_pages_of(name)) or_return
	added: u64 = 0
	if !of_the_image {
		return floor, true
	}
	// The collector of principal 0 keeps the audits of the start list:
	// this service pays their memory (start_policy.odin, start_list_audits).
	if name == wide_grants.COLLECTOR_MODULE_NAME && principal == principals.MACHINE {
		added = start_list_audits * wide_grants.SPACE_AUDIT_PAGES
	}
	// The start policy pays the wirings of its list: the header gives their
	// pages (start_policy.odin).
	if is_role_holder(name, .Start_Policy) {
		added += start_list_wiring_pages
	}
	if floor.pages > max(u64) - added {
		return {}, false
	}
	floor.pages += added
	return floor, true
}

// The budget of one start: its amounts and the floor of the start, which
// the check of its first state of work reads (ready_ring_serve), and the
// row of the start list whose reserve it ends when the start succeeds.
Start_Budget :: struct {
	amounts:     system.Budget_Amounts,
	floor_pages: u64,
	list_row:    bool,
	row_name:    system.Name,
}

// The reserves of the rows of the start list that have not started
// (system.Start_List_Reserves).
start_list_reserves: system.Start_List_Reserves

// The list of start_list_reserve, in the memory of this service: a list is
// read whole.
@(private = "file")
reserve_list: start_list.List

// start_list_reserve reads the rows of a start list before the start
// policy starts, and reserves, for each row whose module the image holds
// and does not run, the size that the rule of the starter gives it
// (system.start_list_sizes): the floors first, then the pages left, of
// which one share of the machine stays with this service, for itself and
// for the starts outside the list: the most that one such start gets. The
// sum of the floors of the default list fits in the least machine (the
// tool proves it at the build); a list whose floors do not fit here keeps
// the floors alone, and each row past what this service holds is refused
// at its start, with its line. A list that is not valid reserves nothing:
// the start policy refuses it.
start_list_reserve :: proc "contextless" (bytes: []u8) {
	start_list_reserves = {}
	if problem, _ := start_list.list_rows_read(bytes, &reserve_list); problem != .None {
		return
	}
	names: [start_list.ROW_CAPACITY]string
	sizes: [start_list.ROW_CAPACITY]system.Start_Size
	count := 0
	for &row in reserve_list.rows[:reserve_list.row_count] {
		row_name := start_list.row_name(&row)
		module_name := start_list.root_procedure_of(row_name) == .Display ? role_holder_name(.Display) : row_name
		// A row whose module runs already, after a list that this one
		// replaces, holds its budget: no page is kept for it twice.
		if find_running(module_name) != nil {
			continue
		}
		floor, ok := start_floor_of(image_file_checked(module_name), module_name, principals.MACHINE, true)
		if !ok {
			continue
		}
		names[count] = module_name
		target_size, _, _ := planned_size_of(module_name, floor.pages)
		sizes[count] = {floor = floor.pages, size = target_size}
		count += 1
	}
	own, _ := system.budget_read()
	if !system.start_list_sizes(sizes[:count], own.pages, start_list_kept_pages(names[:count])) {
		for &size in sizes[:count] {
			size.size = size.floor
		}
	}
	for index in 0 ..< count {
		_ = system.start_list_reserve_add(&start_list_reserves, names[index], sizes[index].size)
	}
}

// The renderers of the console: this service runs one of them at a time.
@(private = "file")
CONSOLE_RENDERERS :: [3]string{"serial_terminal", "grid_terminal", "dom_terminal"}

// start_list_kept_pages gives the pages that the division of a start list
// keeps for the starts that are no row and that can come before the list
// is done: the floor of the start policy once, of each part of the system
// that this service starts in its own way and that the image holds (the
// largest renderer of the console alone), and the budget of the disk
// processes when it is not made yet. It is never below one share of the
// machine, which this service keeps for its own work and for a start that
// a process asks. The tool proves that these floors and the floors of the
// rows fit in the least machine (start_lists.odin).
start_list_kept_pages :: proc "contextless" (rows: []string) -> u64 {
	floor_pages :: proc "contextless" (name: string) -> u64 {
		if find_running(name) != nil {
			return 0
		}
		floor, ok := start_floor_of(image_file_checked(name), name, principals.MACHINE, true)
		return ok ? floor.pages : 0
	}
	policy_name := role_holder_name(.Start_Policy)
	parts: [len(system_part_names)]start_policy_rules.Kept_Floor
	for part, index in system_part_names {
		parts[index] = {name = part, pages = part == "root" || part == policy_name ? 0 : floor_pages(part)}
	}
	disk_class, _ := disk_processes_class_budget()
	disk_pages := disk_processes_budget == 0 ? disk_class.pages : 0
	renderers := CONSOLE_RENDERERS
	return start_policy_rules.kept_pages_of_start_list(policy_name, floor_pages(policy_name), parts[:], renderers[:], rows, disk_pages, largest_budget.pages)
}

// start_list_reserved_all gives the pages that the rows of the start list
// that did not start keep from each start that is no row: a budget of the
// disk processes, a growth of the budgets of a screen of memory.
start_list_reserved_all :: proc "contextless" () -> u64 {
	return system.start_list_reserved_pages(&start_list_reserves, "")
}

// start_list_reserves_end ends every reserve: the start policy has walked
// its whole list (Machine_Usable), or no list starts. A row that was
// absent from the machine, skipped, or whose start failed, then keeps no
// page from the other starts.
start_list_reserves_end :: proc "contextless" () {
	start_list_reserves = {}
}

// start_own_reserve_pages computes the pages that this service itself needs in
// its own budget during process_start: the prepared Code and Fixed segments of
// `file` plus temporary page-table mappings for loading, ready ring, context
// page, and service ring. Keeping this computed reserve prevents budget_of from
// draining this service to zero free pages before process_start loads `file`.
start_own_reserve_pages :: proc "contextless" (file: []u8) -> u64 {
	shared_pages: u64 = 0
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		if .Write not_in segment.flags || .Read_Only_After_Load in segment.flags {
			shared_pages += segment.memory_size / system.PAGE_SIZE
		}
	}
	reserve: u64 = 0
	if shared_pages != 0 {
		reserve += op.memory_cost(shared_pages) + op.mapping_table_pages_most(shared_pages)
	}
	// Ready ring, context page, writable segment copy, and service ring
	// temporary mappings in this service's address space.
	reserve += 4 * op.mapping_table_pages_most(1)
	return reserve
}

// budget_of gives the budget of a process of the boot image: the floor of
// its start, its size (system.budget_size, or the size of the division of
// the start list), at most what this service holds past the sizes that it
// keeps for the rows of the start list that did not start. The reserve of
// a row ends at start_budget_note, after its start succeeded. ok is false
// when the start must not happen: the file gives no floor, or its floor is
// more than this service can give; one line says why, and no page moves.
budget_of :: proc "contextless" (file: []u8, name: string, principal: u64 = principals.MACHINE) -> (budget: Start_Budget, ok: bool) {
	floor, floor_ok := start_floor_of(file, name, principal, true)
	if !floor_ok {
		system.log_fact(.Warning, Start_Refused_No_Floor{refused_process = module_name_field(name)})
		return {}, false
	}
	paying := session_budget_of(principal)
	holds, _ := system.budget_read(paying)
	reserved := paying == 0 ? system.start_list_reserved_pages(&start_list_reserves, name) : 0
	payable := holds.pages - min(holds.pages, reserved)
	if floor.pages > payable {
		holder := paying != 0 ? "the session" : "this service"
		system.log_fact(.Warning, Start_Refused_Floor{floor = value_kinds.Size_In_Pages(min(floor.pages, u64(max(i64)))), held = value_kinds.Size_In_Pages(min(payable, u64(max(i64)))), refused_process = module_name_field(name), paying_budget = text_field(holder, 24)})
		return {}, false
	}
	size, row_below_floor, row_pages := planned_size_of(name, floor.pages)
	if row_below_floor {
		system.log_fact(.Info, Budget_Plan_Row_Below_Floor{row_pages = value_kinds.Size_In_Pages(min(row_pages, u64(max(i64)))), floor_pages = value_kinds.Size_In_Pages(min(floor.pages, u64(max(i64)))), started_process = module_name_field(name)})
	}
	if paying == 0 {
		if divided, found := system.start_list_reserve_size(&start_list_reserves, name); found {
			size = max(divided, floor.pages)
			budget.list_row = true
			copy(budget.row_name[:len(budget.row_name) - 1], name)
		}
	}
	exception_processor, has_exception := processor_of(name)
	processor := has_exception ? exception_processor : floor.threads * PROCESSOR_OF_A_THREAD
	pages_limit := payable
	if paying == 0 {
		own_reserve := start_own_reserve_pages(file)
		pages_limit = payable > own_reserve ? max(floor.pages, payable - own_reserve) : floor.pages
	}
	budget.amounts = {
		pages       = min(size, pages_limit),
		processes   = floor.processes,
		threads     = floor.threads,
		processor   = min(processor, holds.processor),
		log_records = min(log_records_of(name), holds.log_records),
	}
	budget.floor_pages = floor.pages
	return budget, true
}

// The one budget that pays each disk process (disk_process.PROCESSES_BUDGET).
// 0 until the first disk process: a machine that starts none keeps its
// pages. It stays after its processes stop: what they held returns to it.
disk_processes_budget: system.Handle

// disk_processes_budget_get gives the budget of the disk processes, and makes
// it from the budget of this service the first time. name names the disk
// process whose start asks for it, so a refusal before Machine_Usable
// names the process and the start-list reserves as the cause.
disk_processes_budget_get :: proc "contextless" (name: string) -> (budget: system.Handle, status: call_outcome.Call_Outcome) {
	if disk_processes_budget != 0 {
		return disk_processes_budget, .Succeeded
	}
	own, _ := system.budget_read()
	shared, shared_processor := disk_processes_class_budget()
	// The rows of the start list that did not start keep their sizes: the
	// budget of the disk processes takes no page of them.
	reserved := start_list_reserved_all()
	payable := own.pages - min(own.pages, reserved)
	if reserved != 0 && shared.pages > payable {
		system.log_fact(.Warning, Disk_Processes_Budget_Refused_Reserved{needed = value_kinds.Size_In_Pages(min(shared.pages, u64(max(i64)))), held = value_kinds.Size_In_Pages(min(payable, u64(max(i64)))), reserved = value_kinds.Size_In_Pages(min(reserved, u64(max(i64)))), refused_process = module_name_field(name)})
		return 0, .Budget_Or_Capacity_Exhausted
	}
	budget, status = system.budget_create({pages = shared.pages, processes = shared.processes, threads = shared.threads, processor = min(shared_processor, own.processor), log_records = shared.processes * LOG_RECORDS_OF_A_PROCESS})
	if status != .Succeeded {
		system.log_fact(.Warning, Disk_Processes_Budget_Refused{status = status})
		return 0, status
	}
	disk_processes_budget = budget
	system.log_fact(.Info, Disk_Processes_Budget_Made{pages = value_kinds.Size_In_Pages(shared.pages), processes = shared.processes, threads = shared.threads})
	return budget, .Succeeded
}

// disk_budget_of gives the budget of a disk process: its floor, its size at
// most disk_process.LARGEST_BUDGET and what the budget of the disk
// processes holds, with no exception, and limits in time that this budget
// bounds. A disk process gets no row by its name: a file chooses its name.
// ok is false when the start must not happen: the file gives no floor, a
// floor of processes or threads above those of a disk process, or a floor
// of pages above the most of a disk process or above what the budget of
// the disk processes holds; one line says why.
disk_budget_of :: proc "contextless" (file: []u8, name: string, disk_processes: system.Handle) -> (budget: Start_Budget, ok: bool) {
	floor, floor_ok := start_floor_of(file, name, principals.MACHINE, false)
	if !floor_ok {
		system.log_fact(.Warning, Start_Refused_No_Floor{refused_process = module_name_field(name)})
		return {}, false
	}
	largest := disk_process.LARGEST_BUDGET
	needed := system.Budget_Amounts{pages = floor.pages, processes = floor.processes, threads = floor.threads}
	if part, short := system.budget_first_short_part(needed, largest); short && part != .Pages {
		system.log_fact(.Warning, Start_Refused_Budget_Part{needed = system.budget_part(needed, part), held = system.budget_part(largest, part), refused_process = module_name_field(name), budget_part = text_field(system.budget_part_names[part], 16), paying_budget = text_field("a disk process", 24)})
		return {}, false
	}
	holds, _ := system.budget_read(disk_processes)
	payable := min(holds.pages, largest.pages)
	if floor.pages > payable {
		system.log_fact(.Warning, Start_Refused_Floor{floor = value_kinds.Size_In_Pages(min(floor.pages, u64(max(i64)))), held = value_kinds.Size_In_Pages(min(payable, u64(max(i64)))), refused_process = module_name_field(name), paying_budget = text_field("the disk processes", 24)})
		return {}, false
	}
	budget.amounts = {
		pages       = min(system.budget_size(floor.pages, largest.pages, growth_factor), payable),
		processes   = floor.processes,
		threads     = floor.threads,
		processor   = min(floor.threads * PROCESSOR_OF_A_THREAD, holds.processor),
		log_records = min(LOG_RECORDS_OF_A_PROCESS, holds.log_records),
	}
	budget.floor_pages = floor.pages
	return budget, true
}

// budget_refusal_log writes the line of a start that the kernel refused
// for the budget: what the process was to get, what the budget that pays
// holds (0: the budget of this service), and the first part that is short.
// holder names that budget in the line. When it holds each part, the
// budget of the process was too small for its own load: its floor is too
// small.
budget_refusal_log :: proc "contextless" (name: string, amounts: system.Budget_Amounts, holder_budget: system.Handle, holder: string) {
	holds, _ := system.budget_read(holder_budget)
	if part, short := system.budget_first_short_part(amounts, holds); short {
		system.log_fact(.Warning, Start_Refused_Budget_Part{needed = system.budget_part(amounts, part), held = system.budget_part(holds, part), refused_process = module_name_field(name), budget_part = text_field(system.budget_part_names[part], 16), paying_budget = text_field(holder, 24)})
		return
	}
	// The log records of each second move as the pages; the processor time
	// of the process is at most the limit of the holder.
	if holds.log_records < amounts.log_records {
		system.log_fact(.Warning, Start_Refused_Log_Records{log_records = amounts.log_records, held_log_records = holds.log_records, refused_process = module_name_field(name), paying_budget = text_field(holder, 24)})
		return
	}
	if holds.processor < amounts.processor {
		system.log_fact(.Warning, Start_Refused_Processor_Time{processor = amounts.processor, processor_limit = holds.processor, refused_process = module_name_field(name), paying_budget = text_field(holder, 24)})
		return
	}
	system.log_fact(.Warning, Start_Refused_Budget_Too_Small{pages = value_kinds.Size_In_Pages(amounts.pages), processes = amounts.processes, threads = amounts.threads, refused_process = module_name_field(name)})
}

// start_budget_note keeps, in the place of a process whose start
// succeeded, the pages of its budget at its creation and the floor of its
// start, which the check of its first state of work reads
// (ready_ring_serve), and ends the reserve of its row of the start list.
start_budget_note :: proc "contextless" (slot: ^Started, budget: Start_Budget) {
	slot.budget_pages = budget.amounts.pages
	slot.floor_pages = budget.floor_pages
	if budget.list_row {
		row_name := budget.row_name
		system.start_list_reserve_end(&start_list_reserves, system.name_of(row_name[:]))
	}
}

// ready_ring_serve reads the ready ring of a process: its one record, the
// first state of work of the process. This service then reads the least
// count of free pages of the budget of the process since its creation, and
// writes its peak, its pages at the creation less that count, with the
// floor of its start: one fact, Budget_Peak_At_Ready, a measure of each
// build, and a second one, Budget_Floor_Passed, when the peak passed the
// floor, which the machine test refuses
// (src/md/features/module_budget_request.md, "The first state of work").
// Then it sends the one completion of the ring, which a process that stops
// waits for (system.ready_at_end), and closes the ring: no handle or
// mapping of this service stays for it. Another record ends the ring with
// one line and no peak, and so do counters that say more records than the
// ring holds and a count that moved with no record to read
// (root_ring.ready_ring_step). A process whose start noted no floor, or that
// stopped already, so that its budget ended, gives no line.
ready_ring_serve :: proc "contextless" (item: ^Started) {
	record, step := root_ring.ready_ring_step(&item.ready.mapped.commands)
	name := module_name_field(system.name_of(item.name[:]))
	switch step {
	case .Wait:
		return
	case .Ready:
		ready_peak_log(item)
		system.send(&item.ready.mapped.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = record.tag})
	case .Refused_Record:
		system.log_fact(.Warning, Ready_Record_Refused{kind = u64(record.kind), ready_process = name})
		system.send(&item.ready.mapped.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Argument_Refused), tag = record.tag})
	case .Counters_Refused:
		system.log_fact(.Warning, Ready_Ring_Counters_Refused{ready_process = name})
	case .Write_With_No_Record:
		system.log_fact(.Warning, Ready_Ring_Write_With_No_Record{ready_process = name})
	}
	system.ready_ring_close(&item.ready)
}

// ready_peak_log writes the peak of the budget of a process that said its
// first state of work, with the floor of its start.
@(private = "file")
ready_peak_log :: proc "contextless" (item: ^Started) {
	if item.floor_pages == 0 {
		return
	}
	slot, serial, place_status := system.process_place(item.process)
	if place_status != .Succeeded {
		return
	}
	report: op.Process_Report
	if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Process), slot, u64(uintptr(&report)), size_of(report)); status != .Succeeded || report.process_serial != serial || report.state == .Stopped {
		return
	}
	peak := item.budget_pages - min(item.budget_pages, report.budget_least_pages)
	name := system.name_of(item.name[:])
	system.log_fact(.Info, Budget_Peak_At_Ready{peak_pages = peak, floor_pages = item.floor_pages, ready_process = module_name_field(name)})
	if peak > item.floor_pages {
		system.log_fact(.Warning, Budget_Floor_Passed{peak_pages = peak, floor_pages = item.floor_pages, ready_process = module_name_field(name)})
	}
}

