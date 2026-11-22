#+build !freestanding
package plans_core

import "core:testing"
import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"
import "modus:contract/role_contract"
import rd "modus:contract/root_delegation"

// A core that a test drives: it keeps the set in force, as the root service
// does with role_policy.holder_overrides_replace, and refuses a set on
// demand.
@(private = "file")
Test_Core :: struct {
	serial:       u64,
	in_force:     rd.Plan_Roles_Set,
	calls:        int,
	steps:        [8]rd.Plan_Roles_Step,
	refuse:       rd.Plan_Roles_Refusal,
}

@(private = "file")
test_core_replace :: proc "contextless" (user: rawptr, set: ^rd.Plan_Roles_Set, step: rd.Plan_Roles_Step) -> rd.Plan_Roles_Refusal {
	core := (^Test_Core)(user)
	if core.calls < len(core.steps) {
		core.steps[core.calls] = step
	}
	core.calls += 1
	if refusal, _ := rd.plan_roles_set_check(set, step, core.serial); refusal != .None {
		return refusal
	}
	if core.refuse != .None {
		return core.refuse
	}
	core.in_force = set^
	core.serial += 1
	return .None
}

@(private = "file")
roles_test_hash :: proc(tag: u8) -> blake3.Hash {
	data := [4]u8{'r', 'o', 'l', tag}
	return blake3.hash(data[:])
}

@(private = "file")
role_plan :: proc(principal: u64, role: role_contract.Role, tag: u8) -> pr.Plan_Spec {
	plan := pr.Plan_Spec{principal = principal, entry_count = 1}
	plan.entries[0], _ = pr.plan_entry_make_role("holder", role, roles_test_hash(tag))
	return plan
}

@(private = "file")
roles_state :: proc(core: ^Test_Core) -> (state: ^Plans_State, store: ^pr.Memory_Private_Store) {
	state = new(Plans_State)
	store = plans_test_state_init(state, 0)
	roles_port_bind(state, {user = core, replace = test_core_replace})
	return state, store
}

// A trusted display on which the principal accepts each difference.
@(private = "file")
accepting_ask :: proc "contextless" (user: rawptr, plan_name: string, added: string, removed: string) -> (serial: u64, ok: bool) {
	serial_count := (^u64)(user)
	serial_count^ += 1
	return serial_count^, true
}

@(private = "file")
accepting_poll :: proc "contextless" (user: rawptr, serial: u64) -> (decision: pr.Plan_Display_Decision, ok: bool) {
	return .Accepted, true
}

// apply_now shows the difference, the principal accepts it, and the poll
// commits it.
@(private = "file")
apply_now :: proc(state: ^Plans_State, plan: ^pr.Plan_Spec, expected: blake3.Hash) -> (pr.Applied_Plan_Record, pr.Plan_Refusal) {
	serials: u64
	display := Trusted_Display_Port{user = &serials, ask = accepting_ask, poll = accepting_poll}
	difference: pr.Plan_Difference
	lists: Plan_Display_Lists
	ticket, refusal := apply_request(state, &display, "home", plan, expected, &difference, &lists)
	if refusal != .None {
		return {}, refusal
	}
	record, _, poll_refusal := apply_poll(state, &display, plan.principal, ticket, 1, &difference)
	return record, poll_refusal
}

// The core refuses the roles: the plan commits nothing, the store holds no
// current object, and the core keeps its set.
@(test)
test_plans_roles_refused_by_the_core_commit_nothing :: proc(t: ^testing.T) {
	core := Test_Core{refuse = .Contract_Not_Filled}
	state, store := roles_state(&core)
	defer free(state)
	defer free(store)
	plan := role_plan(0, .Storage, 1)
	record, refusal := apply_now(state, &plan, {})
	testing.expect_value(t, refusal, pr.Plan_Refusal.Roles_Refused)
	testing.expect_value(t, state.roles_refusal, rd.Plan_Roles_Refusal.Contract_Not_Filled)
	testing.expect_value(t, record, pr.Applied_Plan_Record{})
	testing.expect_value(t, highest_generation(state, 0), u64(0))
	testing.expect_value(t, core.serial, u64(0))
	testing.expect_value(t, core.in_force, rd.Plan_Roles_Set{})
	current_name := pr.plan_object_name(0, 0, true)
	testing.expect(t, pr.memory_private_store_find(store, pr.private_object_name_text(&current_name)) == nil)
}

// A port with no procedure gives no role: a plan of principal 0 with a role
// is refused, and a plan with no role commits.
@(test)
test_plans_no_roles_port_refuses_a_role_only :: proc(t: ^testing.T) {
	state := new(Plans_State)
	defer free(state)
	store := plans_test_state_init(state, 0)
	defer free(store)
	plan := role_plan(0, .Display, 1)
	_, refusal := apply_now(state, &plan, {})
	testing.expect_value(t, refusal, pr.Plan_Refusal.Roles_Refused)
	module_only := pr.Plan_Spec{principal = 0, entry_count = 1}
	module_only.entries[0], _ = pr.plan_entry_make_module(.Disk_Module, "calc", roles_test_hash(9), 0)
	record, module_refusal := apply_now(state, &module_only, {})
	testing.expect_value(t, module_refusal, pr.Plan_Refusal.None)
	testing.expect_value(t, record.generation, u64(1))
}

// The plan of a named principal names no role of the machine: the core is
// never asked.
@(test)
test_plans_named_principal_sends_no_roles :: proc(t: ^testing.T) {
	core: Test_Core
	state, store := roles_state(&core)
	defer free(state)
	defer free(store)
	plan := role_plan(3, .Storage, 1)
	_, refusal := apply_now(state, &plan, {})
	testing.expect_value(t, refusal, pr.Plan_Refusal.None)
	testing.expect_value(t, core.calls, 0)
}

// Apply two generations, then roll back: the core holds the roles of the
// generation that the store holds as current, at each step.
@(test)
test_plans_roles_follow_apply_and_rollback :: proc(t: ^testing.T) {
	core: Test_Core
	state, store := roles_state(&core)
	defer free(state)
	defer free(store)
	first := role_plan(0, .Storage, 1)
	first_record, refusal := apply_now(state, &first, {})
	testing.expect_value(t, refusal, pr.Plan_Refusal.None)
	testing.expect_value(t, core.in_force.generation, u64(1))
	testing.expect_value(t, core.in_force.override_count, u64(1))
	testing.expect_value(t, core.in_force.overrides[0].module_hash, roles_test_hash(1))

	second := role_plan(0, .Storage, 2)
	_, refusal = apply_now(state, &second, first_record.plan_hash)
	testing.expect_value(t, refusal, pr.Plan_Refusal.None)
	testing.expect_value(t, core.in_force.generation, u64(2))
	testing.expect_value(t, core.in_force.overrides[0].module_hash, roles_test_hash(2))

	// The core refuses the rollback: the second generation stays current in
	// the store and in the core.
	core.refuse = .Not_In_Image
	_, refusal = rollback(state, 0)
	testing.expect_value(t, refusal, pr.Plan_Refusal.Roles_Refused)
	_, current, _ := current_plan(state, 0)
	testing.expect_value(t, current.generation, u64(2))
	testing.expect_value(t, core.in_force.generation, u64(2))

	core.refuse = .None
	selected, rollback_refusal := rollback(state, 0)
	testing.expect_value(t, rollback_refusal, pr.Plan_Refusal.None)
	testing.expect_value(t, selected.generation, u64(1))
	testing.expect_value(t, core.in_force.generation, u64(1))
	testing.expect_value(t, core.in_force.overrides[0].module_hash, roles_test_hash(1))
	testing.expect_value(t, core.steps[core.calls - 1], rd.Plan_Roles_Step.Rollback)
}

// The store refuses the current object after the core took the roles: the
// core gets the roles of the generation in force again, and nothing is
// committed.
@(test)
test_plans_store_failure_gives_the_core_its_roles_back :: proc(t: ^testing.T) {
	core: Test_Core
	state, store := roles_state(&core)
	defer free(state)
	defer free(store)
	first := role_plan(0, .Storage, 1)
	first_record, refusal := apply_now(state, &first, {})
	testing.expect_value(t, refusal, pr.Plan_Refusal.None)

	// The generation object is written, then the current object fails.
	store.writes_allowed = store.writes + 1
	second := role_plan(0, .Storage, 2)
	_, refusal = apply_now(state, &second, first_record.plan_hash)
	testing.expect_value(t, refusal, pr.Plan_Refusal.Store_Failed)
	testing.expect_value(t, highest_generation(state, 0), u64(1))
	testing.expect_value(t, core.in_force.generation, u64(1))
	testing.expect_value(t, core.in_force.overrides[0].module_hash, roles_test_hash(1))
	testing.expect_value(t, core.steps[core.calls - 1], rd.Plan_Roles_Step.Rollback)
}

// A plan whose role has two modules that nothing interposes on cannot be
// one override: refused before the core is asked.
@(test)
test_plans_roles_set_of_refuses_two_outermost_holders :: proc(t: ^testing.T) {
	plan := pr.Plan_Spec{principal = 0, entry_count = 2}
	plan.entries[0], _ = pr.plan_entry_make_role("first", .Assistive, roles_test_hash(1))
	plan.entries[1], _ = pr.plan_entry_make_role("second", .Assistive, roles_test_hash(2))
	set: rd.Plan_Roles_Set
	testing.expect(t, !plan_roles_set_of(&plan, 1, 0, &set))

	// An interposer over the first module is the one that callers reach.
	chained := pr.Plan_Spec{principal = 0, entry_count = 2}
	chained.entries[0], _ = pr.plan_entry_make_role("inner", .Storage, roles_test_hash(1))
	chained.entries[1], _ = pr.plan_entry_make_role("outer", .Storage, roles_test_hash(2))
	chained.entries[1].interposed_over_hash = roles_test_hash(1)
	testing.expect(t, plan_roles_set_of(&chained, 4, 7, &set))
	testing.expect_value(t, set.override_count, u64(1))
	testing.expect_value(t, set.overrides[0].module_hash, roles_test_hash(2))
	testing.expect_value(t, set.generation, u64(4))
	testing.expect_value(t, set.expected_serial, u64(7))

	// No plan: the set of the defaults of the image.
	testing.expect(t, plan_roles_set_of(nil, 0, 2, &set))
	testing.expect_value(t, set.override_count, u64(0))
}
