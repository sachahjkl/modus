// The plan-only values that the root service applies
// (src/md/features/module_settings.md, "Plan records"): the share of the
// machine that one process may get, the sizes of the screen of memory, and
// the quota of a store. Each spends a resource of the machine, so only the
// plan of principal 0 gives it; no setter takes it.
//
// The share and the screen are values of the owner `root`; the quota is the
// value `store_blocks` of the owner of the store (the module, or its role),
// which the root service reads when it opens that store.
//
// This package allocates no memory and calls no kernel operation.
package root_plan_values

import "modus:contract/chosen_values"
import "modus:contract/memory_screen"
import module "modus:contract/module"
import "modus:contract/plan_values"

// The owner of the values of the root service in a set of plan values.
OWNER :: "root"

// The fields of the owner `root`, and the field of the quota of a store.
BUDGET_SHARE_FIELD :: "budget_share"
MEMORY_SCREEN_START_WIDTH_FIELD :: "memory_screen_start_width"
MEMORY_SCREEN_START_HEIGHT_FIELD :: "memory_screen_start_height"
MEMORY_SCREEN_MOST_WIDTH_FIELD :: "memory_screen_most_width"
MEMORY_SCREEN_MOST_HEIGHT_FIELD :: "memory_screen_most_height"
STORE_BLOCKS_FIELD :: "store_blocks"

// The share: the largest budget of one process is the budget of the machine
// over this count. Stated once in module/format.odin; 1 gives one process
// the whole machine, 64 a sixty-fourth, default 4 (a quarter).
BUDGET_SHARE_LEAST :: module.LARGEST_BUDGET_SHARE_LEAST
BUDGET_SHARE_MOST :: module.LARGEST_BUDGET_SHARE_MOST
BUDGET_SHARE_DEFAULT :: module.LARGEST_BUDGET_SHARE_DEFAULT

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
	{MEMORY_SCREEN_START_WIDTH_FIELD, u64(memory_screen.MIN_WIDTH), u64(memory_screen.MAX_WIDTH)},
	{MEMORY_SCREEN_START_HEIGHT_FIELD, u64(memory_screen.MIN_HEIGHT), u64(memory_screen.MAX_HEIGHT)},
	{MEMORY_SCREEN_MOST_WIDTH_FIELD, u64(memory_screen.MIN_WIDTH), u64(memory_screen.MAX_WIDTH)},
	{MEMORY_SCREEN_MOST_HEIGHT_FIELD, u64(memory_screen.MIN_HEIGHT), u64(memory_screen.MAX_HEIGHT)},
}

// The field of the quota of a store, which each owner of a store has.
STORE_BLOCKS_RANGE :: Field_Range{STORE_BLOCKS_FIELD, STORE_BLOCKS_LEAST, STORE_BLOCKS_MOST}

// field_range_of gives the range of a field that the core reads: a field of
// the owner `root`, or `store_blocks` of any owner. found is false for
// another field, which the module of its owner describes.
field_range_of :: proc "contextless" (owner, field: string) -> (range: Field_Range, found: bool) {
	if field == STORE_BLOCKS_FIELD {
		return STORE_BLOCKS_RANGE, true
	}
	if owner != OWNER {
		return {}, false
	}
	for item in ROOT_FIELDS {
		if item.name == field {
			return item, true
		}
	}
	return {}, false
}

// The values in force of the owner `root`, each with the layer that gives
// it.
Root_Plan :: struct {
	budget_share:               u64,
	memory_screen_start_width:  u32,
	memory_screen_start_height: u32,
	memory_screen_most_width:   u32,
	memory_screen_most_height:  u32,
	budget_share_layer:         chosen_values.Layer,
	memory_screen_layer:        chosen_values.Layer, // The layer of the four sizes: they hold together.
}

// The defaults of the contract: what holds when the plan gives nothing.
ROOT_PLAN_DEFAULTS :: Root_Plan {
	budget_share               = BUDGET_SHARE_DEFAULT,
	memory_screen_start_width  = memory_screen.DEFAULT_WIDTH,
	memory_screen_start_height = memory_screen.DEFAULT_HEIGHT,
	memory_screen_most_width   = memory_screen.MAX_WIDTH,
	memory_screen_most_height  = memory_screen.MAX_HEIGHT,
}

@(private = "file")
share_valid :: proc "contextless" (word: u64) -> bool {
	_, ok := module.budget_share_of_word(word)
	return ok
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
