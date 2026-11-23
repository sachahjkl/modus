package root

// The plan values of principal 0 (src/md/features/module_settings.md,
// "Plan records"), which the holder of Plans gives with the command
// Plan_Values (modus:contract/root_ring), as it gives the roles with
// Plan_Roles (plan_roles.odin).
//
// The core makes the values pages once and lends them to the holder of
// Plans. The holder writes there the whole set of the generation that the
// principal accepted. The core copies the set once, checks it whole
// (plan_values.set_check), and replaces its values in one step: the core
// never runs with a part of a plan. At the start of an owner of settings,
// the core writes the values of that owner on the page of its place and
// maps it read-only: an owner that started before the change keeps the
// values that it started with.

import "base:intrinsics"
import "internal:root/role_policy"
import "modus:contract/errors"
import "modus:contract/plan_values"
import rd "modus:contract/root_delegation"
import "modus:contract/root_plan_values"
import "modus:contract/root_ring"
import "modus:system"

// The values pages: the handle of the core, and its mapping.
plan_values_memory: system.Handle
plan_values_pages: [^]u8

// The copy of the set that the core checks, and the set in force. The
// holder can write the pages meanwhile.
plan_values_copy: [plan_values.SET_SIZE]u8
plan_values_in_force: [plan_values.SET_SIZE]u8
plan_values_generation: u64
plan_values_given: bool

// The page of the plan values of each place of `started`: one object, as
// the fresh bytes, mapped with Write in this service.
plan_values_owner_memory: system.Handle
plan_values_owner_address: uintptr

// plan_values_command runs Plan_Values for its one sender, the process
// with the start grant Plans.
plan_values_command :: proc "contextless" (item: ^Started, values: [7]u64, answer: ^[7]u64) -> system.Status {
	kind := u32(root_ring.Root_Command.Plan_Values)
	step, step_known := rd.plan_roles_step_of_word(values[0])
	if !step_known || step == .Loaded {
		answer^ = errors.ring_fail(kind, .Bad_Value, .None, 1, i64(min(values[0], u64(max(i64)))), i64(rd.Plan_Roles_Step.Rollback))
		return .Bad_Operation
	}
	for index in 1 ..< len(values) {
		if values[index] != 0 {
			answer^ = errors.ring_fail(kind, .Bad_Value, .None, i64(index + 1), i64(min(values[index], u64(max(i64)))), 0)
			return .Bad_Operation
		}
	}
	switch step {
	case .None, .Loaded:
		return .Bad_Operation
	case .Page:
		status := plan_values_pages_give(item, answer)
		if status != .Ok {
			answer^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(status))
		}
		return status
	case .Apply, .Rollback:
	}
	if plan_values_pages == nil {
		answer^ = errors.ring_fail(kind, .State, .Requests)
		return .Bad_State
	}
	intrinsics.mem_copy_non_overlapping(&plan_values_copy, plan_values_pages, plan_values.SET_SIZE)
	head, problem := plan_values.set_check(plan_values_copy[:])
	if problem != .None {
		system.log_fact(.Warning, Plan_Values_Refused{set_problem = text_field(plan_values.SET_PROBLEM_NAMES[problem], 24)})
		answer^ = errors.ring_fail(kind, .Refused, .Records, 0, 0, 0, i64(problem))
		return .Bad_State
	}
	plan_values_in_force = plan_values_copy
	plan_values_generation = head.generation
	plan_values_given = true
	system.log_fact(.Info, Plan_Values_Replaced{generation = head.generation, owners = u64(head.owner_count)})
	answer^ = {0 = head.generation}
	return .Ok
}

// plan_values_pages_give makes the values pages at their first use, and
// gives the sender a handle of them with Read and Write. The core keeps
// its own handle: a revocation by the sender does not reach it.
@(private = "file")
plan_values_pages_give :: proc "contextless" (item: ^Started, answer: ^[7]u64) -> system.Status {
	if plan_values_memory == 0 {
		memory, status := system.memory_create(plan_values.SET_PAGES)
		if status != .Ok {
			return status
		}
		address, map_status := system.memory_map(memory, {.Write})
		if map_status != .Ok {
			system.close(memory)
			return map_status
		}
		plan_values_memory = memory
		plan_values_pages = ([^]u8)(address)
	}
	given, status := system.give(item.requests_memory, plan_values_memory, {.Read, .Write})
	if status != .Ok {
		return status
	}
	answer^ = {0 = u64(given), 1 = plan_values_generation}
	return .Ok
}

// plan_values_of gives the values of an owner in the set in force: the
// owner is named by its store (role_policy.store_name_of_module).
plan_values_of :: proc "contextless" (owner: string) -> (values: plan_values.Owner_Values, found: bool) {
	if !plan_values_given {
		return {}, false
	}
	return plan_values.owner_values_of(plan_values_in_force[:], owner)
}

// store_blocks_planned gives the quota of the store of an owner: the value
// store_blocks of its plan values when the plan of principal 0 gives one
// that passes its border, else the row of its start grant set. The quota is
// a plan-only value: it spends the disk of the machine.
store_blocks_planned :: proc "contextless" (owner: string, start_grant_set: ^Start_Grant_Set) -> u64 {
	if values, found := plan_values_of(owner); found {
		if blocks, planned := root_plan_values.store_blocks_of(values); planned {
			return blocks
		}
	}
	return start_grant_set_store_blocks(start_grant_set)
}

// The values of the owner `root` that the core read at the last start of
// the holder of the display.
root_plan_in_force: root_plan_values.Root_Plan = root_plan_values.ROOT_PLAN_DEFAULTS

// root_plan_read reads the values of the owner `root` at the start of the
// holder of the display, and logs them once.
//
// Merge note, the share: on work/limits_kernel_and_budgets the core reads
// the share through budget_share_take (src/modules/system/root/budgets.odin)
// with the border module.budget_share_of_word, LARGEST_BUDGET_SHARE_LEAST 1
// to LARGEST_BUDGET_SHARE_MOST 64, default 4: the same range as
// root_plan_values.BUDGET_SHARE_*. At the merge, call
// budget_share_take(root_plan_in_force.budget_share) here, before the start
// of the next process, and keep one of the two borders (the constants of
// module/format.odin are the place of the fact; root_plan_values then names
// them).
//
// Merge note, the screen of memory: on work/limits_remote_and_network the
// screen of memory is paid at its start size and grows through the root
// command Screen_Budget (screen_budgets, memory_screen.screen_budget_grow_decide);
// no fixed cost row stays. At the merge, give the compositor its start size
// from memory_screen_start_width and _height in its context at this start,
// and make memory_screen_most_width and _height the largest size that
// screen_budget_grow_decide grants; the borders are memory_screen.MIN_* to
// MAX_*, which that branch raises to 7680 x 4320.
root_plan_read :: proc "contextless" () {
	values, _ := plan_values_of(root_plan_values.OWNER)
	plan, sizes_refused := root_plan_values.root_plan_of(values)
	root_plan_in_force = plan
	system.log_fact(.Info, Root_Plan_Values_Read{budget_share = plan.budget_share, start_width = u64(plan.memory_screen_start_width), start_height = u64(plan.memory_screen_start_height), most_width = u64(plan.memory_screen_most_width), most_height = u64(plan.memory_screen_most_height), sizes_refused = sizes_refused ? 1 : 0})
}

// plan_values_owner_pages_create creates the pages of the owners. A
// failure is not a failure of the start: the owners then hold the
// defaults of their contracts, and the log says it once.
plan_values_owner_pages_create :: proc "contextless" () {
	status: system.Status
	plan_values_owner_memory, status = system.memory_create(STARTED_CAPACITY)
	address: rawptr
	if status == .Ok {
		address, status = system.memory_map(plan_values_owner_memory)
	}
	if status != .Ok {
		system.log_fact(.Warning, Plan_Values_Pages_Failed{status = status})
		if plan_values_owner_memory != 0 {
			system.close(plan_values_owner_memory)
		}
		plan_values_owner_memory = 0
		return
	}
	plan_values_owner_address = uintptr(address)
}

// plan_values_page_give writes the plan values of the owner of a module on
// the page of its place and adds the page, read-only, to its mappings,
// with the bit of its range. A module that the plan gives no value gets no
// page: it holds the defaults of its contract.
plan_values_page_give :: proc "contextless" (item: ^Started, module_name: string, mappings: []system.Mapping, count: ^int, values: ^system.Context_Values) {
	if plan_values_owner_memory == 0 {
		return
	}
	owner_values, found := plan_values_of(role_policy.store_name_of_module(&role_holder_names, module_name))
	if !found {
		return
	}
	index := disk_process_page_index(item)
	if index < 0 || index >= STARTED_CAPACITY {
		return
	}
	if count^ >= len(mappings) {
		mapping_dropped_log("the plan values page", len(mappings))
		return
	}
	page := ([^]u8)(plan_values_owner_address + uintptr(index) * uintptr(system.PAGE_SIZE))[:plan_values.OWNER_PAGE_SIZE]
	if !plan_values.owner_page_write(page, owner_values) {
		return
	}
	mappings[count^] = {memory = plan_values_owner_memory, address = plan_values.OWNER_PAGE_ADDRESS, first = u64(index), page_count = 1}
	count^ += 1
	system.range_mapped_put(values, .Plan_Values_Page)
}
