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
		system.log_fact(.Warning, Plan_Values_Refused{problem = text_field(plan_values.SET_PROBLEM_NAMES[problem], 24)})
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
