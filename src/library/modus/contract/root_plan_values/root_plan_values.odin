// The plan-only values that the root service applies
// (src/md/features/module_settings.md, "Plan records";
// src/md/features/module_budget_request.md, "The size, part by part"):
//
// - Owner `root`: the share of the machine that one process may get, the
//   default growth factor, the rate-limit period of Budget_Grow, the class
//   budget of the disk processes, and the sizes of the screen of memory.
// - Any other owner (a module of the image or a role): the quota of its
//   store (`store_blocks`) and its budget policy row (`budget_pages` or
//   `budget_share_parts`, `budget_ceiling_pages`,
//   `budget_growth_reserve_pages`, `budget_processor`, `budget_log_records`,
//   `budget_screen_pages`).
//
// Each spends a resource of the machine, so only the plan of principal 0
// gives it; no setter takes it. This package allocates no memory and calls
// no kernel operation.
package root_plan_values

import "modus:contract/chosen_values"
import "modus:contract/memory_screen"
import module "modus:contract/module"
import "modus:contract/plan_values"

// The owner of the values of the root service in a set of plan values.
OWNER :: "root"

// The fields of the owner `root`.
BUDGET_SHARE_FIELD :: "budget_share"
DEFAULT_GROWTH_FACTOR_FIELD :: "default_growth_factor"
BUDGET_GROWTH_PERIOD_MS_FIELD :: "budget_growth_period_ms"
DISK_PROCESSES_PAGES_FIELD :: "disk_processes_pages"
DISK_PROCESSES_PROCESSES_FIELD :: "disk_processes_processes"
DISK_PROCESSES_THREADS_FIELD :: "disk_processes_threads"
DISK_PROCESSES_PROCESSOR_FIELD :: "disk_processes_processor"
MEMORY_SCREEN_START_WIDTH_FIELD :: "memory_screen_start_width"
MEMORY_SCREEN_START_HEIGHT_FIELD :: "memory_screen_start_height"
MEMORY_SCREEN_MOST_WIDTH_FIELD :: "memory_screen_most_width"
MEMORY_SCREEN_MOST_HEIGHT_FIELD :: "memory_screen_most_height"

// The plan-only fields that any module or role owner (other than `root`)
// accepts: its store quota and its budget policy row.
STORE_BLOCKS_FIELD :: "store_blocks"
BUDGET_PAGES_FIELD :: "budget_pages"
BUDGET_SHARE_PARTS_FIELD :: "budget_share_parts"
BUDGET_CEILING_PAGES_FIELD :: "budget_ceiling_pages"
BUDGET_GROWTH_RESERVE_PAGES_FIELD :: "budget_growth_reserve_pages"
BUDGET_PROCESSOR_FIELD :: "budget_processor"
BUDGET_LOG_RECORDS_FIELD :: "budget_log_records"
BUDGET_SCREEN_PAGES_FIELD :: "budget_screen_pages"

// The share: the largest budget of one process is the budget of the machine
// over this count. Stated once in module/format.odin; 1 gives one process
// the whole machine, 64 a sixty-fourth, default 4 (a quarter).
BUDGET_SHARE_LEAST :: module.LARGEST_BUDGET_SHARE_LEAST
BUDGET_SHARE_MOST :: module.LARGEST_BUDGET_SHARE_MOST
BUDGET_SHARE_DEFAULT :: module.LARGEST_BUDGET_SHARE_DEFAULT

// The default growth factor of a process size: 2 times floor by default.
// Bounded in the plan to [1, 16]: 1 gives floor alone, 16 already caps
// every process at the machine share.
DEFAULT_GROWTH_FACTOR_LEAST :: u64(1)
DEFAULT_GROWTH_FACTOR_MOST :: u64(16)
DEFAULT_GROWTH_FACTOR_DEFAULT :: u64(module.DEFAULT_GROWTH_FACTOR)

// The rate-limit period of Budget_Grow, in milliseconds: at most one
// decision per process in each period (default 1 second, bounding the
// covert channel to about one bit per second).
BUDGET_GROWTH_PERIOD_MS_LEAST :: u64(1)
BUDGET_GROWTH_PERIOD_MS_MOST :: u64(60_000)
BUDGET_GROWTH_PERIOD_MS_DEFAULT :: u64(1_000)

// The bounds of per-owner and disk-class budget policy fields.
// Pages: at least 1, at most 4 TiB in 4 KiB pages (format property of u32/u64 sizing).
BUDGET_PAGES_LEAST :: u64(1)
BUDGET_PAGES_MOST :: u64(1 << 30)
// Share parts: parts of 1024 of the machine pages at start.
BUDGET_SHARE_PARTS_LEAST :: u64(1)
BUDGET_SHARE_PARTS_WHOLE :: u64(1024)
BUDGET_SHARE_PARTS_MOST :: BUDGET_SHARE_PARTS_WHOLE
// Processor time: microseconds per second, from 1 ms up to 64 processors.
BUDGET_PROCESSOR_LEAST :: u64(1_000)
BUDGET_PROCESSOR_MOST :: u64(64_000_000)
// Log records per second: 0 disables kernel log output (used by log_flood);
// upper bound covers any single process budget.
BUDGET_LOG_RECORDS_LEAST :: u64(0)
BUDGET_LOG_RECORDS_MOST :: u64(65_536)
// Screen pictures override in pages: at least 1, at most 4 GiB.
BUDGET_SCREEN_PAGES_LEAST :: u64(1)
BUDGET_SCREEN_PAGES_MOST :: u64(1 << 20)
// Disk processes class slot bounds.
DISK_PROCESSES_PROCESSES_LEAST :: u64(1)
DISK_PROCESSES_PROCESSES_MOST :: u64(1024)
DISK_PROCESSES_THREADS_LEAST :: u64(1)
DISK_PROCESSES_THREADS_MOST :: u64(4096)

// The quota of a store, in blocks: at least one, and at most the blocks of
// a data disk of 4 GiB in blocks of 4 KiB. The storage service refuses a
// write past the room of its disk whatever the quota.
STORE_BLOCKS_LEAST :: u64(1)
STORE_BLOCKS_MOST :: u64(1 << 20)

// One field of the core and its range: the description of a value of the
// core, which has no exports. The console types a plan by it
// (src/md/features/declarations.md, "A plan written in the console").
Field_Range :: struct {
	name:        string,
	least, most: u64,
}

// The fields of the owner `root`.
@(rodata)
ROOT_FIELDS := [?]Field_Range {
	{BUDGET_SHARE_FIELD, BUDGET_SHARE_LEAST, BUDGET_SHARE_MOST},
	{DEFAULT_GROWTH_FACTOR_FIELD, DEFAULT_GROWTH_FACTOR_LEAST, DEFAULT_GROWTH_FACTOR_MOST},
	{BUDGET_GROWTH_PERIOD_MS_FIELD, BUDGET_GROWTH_PERIOD_MS_LEAST, BUDGET_GROWTH_PERIOD_MS_MOST},
	{DISK_PROCESSES_PAGES_FIELD, BUDGET_PAGES_LEAST, BUDGET_PAGES_MOST},
	{DISK_PROCESSES_PROCESSES_FIELD, DISK_PROCESSES_PROCESSES_LEAST, DISK_PROCESSES_PROCESSES_MOST},
	{DISK_PROCESSES_THREADS_FIELD, DISK_PROCESSES_THREADS_LEAST, DISK_PROCESSES_THREADS_MOST},
	{DISK_PROCESSES_PROCESSOR_FIELD, BUDGET_PROCESSOR_LEAST, BUDGET_PROCESSOR_MOST},
	{MEMORY_SCREEN_START_WIDTH_FIELD, u64(memory_screen.MIN_WIDTH), u64(memory_screen.MAX_WIDTH)},
	{MEMORY_SCREEN_START_HEIGHT_FIELD, u64(memory_screen.MIN_HEIGHT), u64(memory_screen.MAX_HEIGHT)},
	{MEMORY_SCREEN_MOST_WIDTH_FIELD, u64(memory_screen.MIN_WIDTH), u64(memory_screen.MAX_WIDTH)},
	{MEMORY_SCREEN_MOST_HEIGHT_FIELD, u64(memory_screen.MIN_HEIGHT), u64(memory_screen.MAX_HEIGHT)},
}

// The plan-only fields that each module or role owner (other than `root`)
// accepts.
@(rodata)
OWNER_FIELDS := [?]Field_Range {
	{STORE_BLOCKS_FIELD, STORE_BLOCKS_LEAST, STORE_BLOCKS_MOST},
	{BUDGET_PAGES_FIELD, BUDGET_PAGES_LEAST, BUDGET_PAGES_MOST},
	{BUDGET_SHARE_PARTS_FIELD, BUDGET_SHARE_PARTS_LEAST, BUDGET_SHARE_PARTS_MOST},
	{BUDGET_CEILING_PAGES_FIELD, BUDGET_PAGES_LEAST, BUDGET_PAGES_MOST},
	{BUDGET_GROWTH_RESERVE_PAGES_FIELD, BUDGET_PAGES_LEAST, BUDGET_PAGES_MOST},
	{BUDGET_PROCESSOR_FIELD, BUDGET_PROCESSOR_LEAST, BUDGET_PROCESSOR_MOST},
	{BUDGET_LOG_RECORDS_FIELD, BUDGET_LOG_RECORDS_LEAST, BUDGET_LOG_RECORDS_MOST},
	{BUDGET_SCREEN_PAGES_FIELD, BUDGET_SCREEN_PAGES_LEAST, BUDGET_SCREEN_PAGES_MOST},
}

// The field of the quota of a store, which each owner of a store has.
STORE_BLOCKS_RANGE :: Field_Range{STORE_BLOCKS_FIELD, STORE_BLOCKS_LEAST, STORE_BLOCKS_MOST}

// field_range_of gives the range of a field that the core reads: a field of
// the owner `root`, or one of OWNER_FIELDS of any other owner. found is
// false for another field, which the module of its owner describes.
field_range_of :: proc "contextless" (owner, field: string) -> (range: Field_Range, found: bool) {
	if owner == OWNER {
		for item in ROOT_FIELDS {
			if item.name == field {
				return item, true
			}
		}
		return {}, false
	}
	for item in OWNER_FIELDS {
		if item.name == field {
			return item, true
		}
	}
	return {}, false
}

// The values in force of the owner `root`, each with the layer that gives
// it. A zero disk_processes_* field means the contract default holds.
Root_Plan :: struct {
	budget_share:               u64,
	default_growth_factor:      u64,
	budget_growth_period_ms:    u64,
	disk_processes_pages:       u64,
	disk_processes_processes:   u64,
	disk_processes_threads:     u64,
	disk_processes_processor:   u64,
	memory_screen_start_width:  u32,
	memory_screen_start_height: u32,
	memory_screen_most_width:   u32,
	memory_screen_most_height:  u32,
	budget_share_layer:         chosen_values.Layer,
	growth_factor_layer:        chosen_values.Layer,
	growth_period_layer:        chosen_values.Layer,
	memory_screen_layer:        chosen_values.Layer, // The layer of the four sizes: they hold together.
}

// The defaults of the contract: what holds when the plan gives nothing.
ROOT_PLAN_DEFAULTS :: Root_Plan {
	budget_share               = BUDGET_SHARE_DEFAULT,
	default_growth_factor      = DEFAULT_GROWTH_FACTOR_DEFAULT,
	budget_growth_period_ms    = BUDGET_GROWTH_PERIOD_MS_DEFAULT,
	memory_screen_start_width  = memory_screen.DEFAULT_WIDTH,
	memory_screen_start_height = memory_screen.DEFAULT_HEIGHT,
	memory_screen_most_width   = memory_screen.MAX_WIDTH,
	memory_screen_most_height  = memory_screen.MAX_HEIGHT,
}

// The budget policy row of one module or role owner, read from its plan
// values. Each field has an explicit presence flag so 0 (for example
// budget_log_records = 0) stays distinct from absent.
Module_Budget_Policy :: struct {
	pages:                u64,
	has_pages:            bool,
	share_parts:          u64,
	has_share_parts:      bool,
	ceiling_pages:        u64,
	has_ceiling:          bool,
	growth_reserve_pages: u64,
	has_growth_reserve:   bool,
	processor:            u64,
	has_processor:        bool,
	log_records:          u64,
	has_log_records:      bool,
	screen_pages:         u64,
	has_screen_pages:     bool,
}

@(private = "file")
share_valid :: proc "contextless" (word: u64) -> bool {
	_, ok := module.budget_share_of_word(word)
	return ok
}

@(private = "file")
growth_factor_valid :: proc "contextless" (word: u64) -> bool {
	factor, ok := module.growth_factor_of_word(word)
	return ok && factor >= DEFAULT_GROWTH_FACTOR_LEAST && factor <= DEFAULT_GROWTH_FACTOR_MOST
}

@(private = "file")
growth_period_valid :: proc "contextless" (word: u64) -> bool {
	return word >= BUDGET_GROWTH_PERIOD_MS_LEAST && word <= BUDGET_GROWTH_PERIOD_MS_MOST
}

@(private = "file")
pages_valid :: proc "contextless" (word: u64) -> bool {
	return word >= BUDGET_PAGES_LEAST && word <= BUDGET_PAGES_MOST
}

@(private = "file")
share_parts_valid :: proc "contextless" (word: u64) -> bool {
	return word >= BUDGET_SHARE_PARTS_LEAST && word <= BUDGET_SHARE_PARTS_MOST
}

@(private = "file")
processor_valid :: proc "contextless" (word: u64) -> bool {
	return word >= BUDGET_PROCESSOR_LEAST && word <= BUDGET_PROCESSOR_MOST
}

@(private = "file")
log_records_valid :: proc "contextless" (word: u64) -> bool {
	return word >= BUDGET_LOG_RECORDS_LEAST && word <= BUDGET_LOG_RECORDS_MOST
}

@(private = "file")
screen_pages_valid :: proc "contextless" (word: u64) -> bool {
	return word >= BUDGET_SCREEN_PAGES_LEAST && word <= BUDGET_SCREEN_PAGES_MOST
}

@(private = "file")
disk_processes_count_valid :: proc "contextless" (word: u64) -> bool {
	return word >= DISK_PROCESSES_PROCESSES_LEAST && word <= DISK_PROCESSES_PROCESSES_MOST
}

@(private = "file")
disk_threads_count_valid :: proc "contextless" (word: u64) -> bool {
	return word >= DISK_PROCESSES_THREADS_LEAST && word <= DISK_PROCESSES_THREADS_MOST
}

@(private = "file")
width_valid :: proc "contextless" (word: u64) -> bool {
	return word >= u64(memory_screen.MIN_WIDTH) && word <= u64(memory_screen.MAX_WIDTH)
}

@(private = "file")
height_valid :: proc "contextless" (word: u64) -> bool {
	return word >= u64(memory_screen.MIN_HEIGHT) && word <= u64(memory_screen.MAX_HEIGHT)
}

// root_plan_of reads the values of the owner `root`: each word at the
// border of its field, then the rule across the sizes of the screen: the
// start size inside the largest size, on each axis. A rule that the four
// sizes break gives the four defaults together, so the screen never starts
// past the size that it may grow to. The plan has no choice of the
// principal: chosen is the empty record.
root_plan_of :: proc "contextless" (values: plan_values.Owner_Values) -> (plan: Root_Plan, sizes_refused: bool) {
	plan = ROOT_PLAN_DEFAULTS
	empty: chosen_values.Record
	if word, layer, found := plan_values.value_in_force(BUDGET_SHARE_FIELD, empty, values, share_valid); found {
		plan.budget_share, plan.budget_share_layer = word, layer
	}
	if word, layer, found := plan_values.value_in_force(DEFAULT_GROWTH_FACTOR_FIELD, empty, values, growth_factor_valid); found {
		plan.default_growth_factor, plan.growth_factor_layer = word, layer
	}
	if word, layer, found := plan_values.value_in_force(BUDGET_GROWTH_PERIOD_MS_FIELD, empty, values, growth_period_valid); found {
		plan.budget_growth_period_ms, plan.growth_period_layer = word, layer
	}
	if word, _, found := plan_values.value_in_force(DISK_PROCESSES_PAGES_FIELD, empty, values, pages_valid); found {
		plan.disk_processes_pages = word
	}
	if word, _, found := plan_values.value_in_force(DISK_PROCESSES_PROCESSES_FIELD, empty, values, disk_processes_count_valid); found {
		plan.disk_processes_processes = word
	}
	if word, _, found := plan_values.value_in_force(DISK_PROCESSES_THREADS_FIELD, empty, values, disk_threads_count_valid); found {
		plan.disk_processes_threads = word
	}
	if word, _, found := plan_values.value_in_force(DISK_PROCESSES_PROCESSOR_FIELD, empty, values, processor_valid); found {
		plan.disk_processes_processor = word
	}
	Size :: struct {
		field:  string,
		border: proc "contextless" (word: u64) -> bool,
		place:  ^u32,
	}
	sizes := [4]Size {
		{MEMORY_SCREEN_START_WIDTH_FIELD, width_valid, &plan.memory_screen_start_width},
		{MEMORY_SCREEN_START_HEIGHT_FIELD, height_valid, &plan.memory_screen_start_height},
		{MEMORY_SCREEN_MOST_WIDTH_FIELD, width_valid, &plan.memory_screen_most_width},
		{MEMORY_SCREEN_MOST_HEIGHT_FIELD, height_valid, &plan.memory_screen_most_height},
	}
	for size in sizes {
		if word, layer, found := plan_values.value_in_force(size.field, empty, values, size.border); found {
			size.place^ = u32(word)
			plan.memory_screen_layer = max(plan.memory_screen_layer, layer)
		}
	}
	if plan.memory_screen_start_width > plan.memory_screen_most_width || plan.memory_screen_start_height > plan.memory_screen_most_height {
		defaults := ROOT_PLAN_DEFAULTS
		plan.memory_screen_start_width, plan.memory_screen_start_height = defaults.memory_screen_start_width, defaults.memory_screen_start_height
		plan.memory_screen_most_width, plan.memory_screen_most_height = defaults.memory_screen_most_width, defaults.memory_screen_most_height
		plan.memory_screen_layer = .Contract_Default
		return plan, true
	}
	return plan, false
}

// module_budget_policy_of reads the budget policy row of one module or role
// owner from its plan values. A row may give budget_pages or
// budget_share_parts, never both: when both pass their borders, size_conflict
// is true and neither holds. A growth reserve requires a ceiling at least as
// large: otherwise reserve_over_ceiling is true and the reserve is cleared.
module_budget_policy_of :: proc "contextless" (values: plan_values.Owner_Values) -> (policy: Module_Budget_Policy, size_conflict: bool, reserve_over_ceiling: bool) {
	empty: chosen_values.Record
	if word, _, found := plan_values.value_in_force(BUDGET_PAGES_FIELD, empty, values, pages_valid); found {
		policy.pages, policy.has_pages = word, true
	}
	if word, _, found := plan_values.value_in_force(BUDGET_SHARE_PARTS_FIELD, empty, values, share_parts_valid); found {
		policy.share_parts, policy.has_share_parts = word, true
	}
	if policy.has_pages && policy.has_share_parts {
		policy.pages, policy.has_pages = 0, false
		policy.share_parts, policy.has_share_parts = 0, false
		size_conflict = true
	}
	if word, _, found := plan_values.value_in_force(BUDGET_CEILING_PAGES_FIELD, empty, values, pages_valid); found {
		policy.ceiling_pages, policy.has_ceiling = word, true
	}
	if word, _, found := plan_values.value_in_force(BUDGET_GROWTH_RESERVE_PAGES_FIELD, empty, values, pages_valid); found {
		policy.growth_reserve_pages, policy.has_growth_reserve = word, true
	}
	if policy.has_growth_reserve && (!policy.has_ceiling || policy.growth_reserve_pages > policy.ceiling_pages) {
		policy.growth_reserve_pages, policy.has_growth_reserve = 0, false
		reserve_over_ceiling = true
	}
	if word, _, found := plan_values.value_in_force(BUDGET_PROCESSOR_FIELD, empty, values, processor_valid); found {
		policy.processor, policy.has_processor = word, true
	}
	if word, _, found := plan_values.value_in_force(BUDGET_LOG_RECORDS_FIELD, empty, values, log_records_valid); found {
		policy.log_records, policy.has_log_records = word, true
	}
	if word, _, found := plan_values.value_in_force(BUDGET_SCREEN_PAGES_FIELD, empty, values, screen_pages_valid); found {
		policy.screen_pages, policy.has_screen_pages = word, true
	}
	return policy, size_conflict, reserve_over_ceiling
}

// planned_pages_of computes the planned page count of a budget policy row
// against the pages of the machine at start. has_size is false when the row
// gives neither pages nor share parts.
planned_pages_of :: proc "contextless" (policy: Module_Budget_Policy, machine_pages: u64) -> (pages: u64, has_size: bool) {
	if policy.has_pages {
		return policy.pages, true
	}
	if policy.has_share_parts {
		scaled := (u128(machine_pages) * u128(policy.share_parts)) / u128(BUDGET_SHARE_PARTS_WHOLE)
		return u64(min(scaled, u128(max(u64)))), true
	}
	return 0, false
}

// store_blocks_of gives the quota of a store from the values of its owner,
// or found false when the plan gives none that passes its border: the row
// of the start grant set holds.
store_blocks_of :: proc "contextless" (values: plan_values.Owner_Values) -> (blocks: u64, found: bool) {
	border :: proc "contextless" (word: u64) -> bool {
		return word >= STORE_BLOCKS_LEAST && word <= STORE_BLOCKS_MOST
	}
	empty: chosen_values.Record
	blocks, _, found = plan_values.value_in_force(STORE_BLOCKS_FIELD, empty, values, border)
	return blocks, found
}
