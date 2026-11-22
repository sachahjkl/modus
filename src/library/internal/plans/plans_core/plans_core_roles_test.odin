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
	serial:        u64,
	in_force:      rd.Plan_Roles_Set,
	calls:         int,
	steps:         [16]rd.Plan_Roles_Step,
	refuse:        rd.Plan_Roles_Refusal,
	// Refuse only the sets of this step, with refuse.
	refuse_step:   rd.Plan_Roles_Step,
	// Take the next set, and lose its answer: the port sees Stale_Serial,
	// as the plans service does with no completion.
	lose_answer:   bool,
	reads:         int,
	read_fails:    bool,
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
	if core.refuse != .None && (core.refuse_step == .None || core.refuse_step == step) {
		return core.refuse
	}
	core.in_force = set^
	core.serial += 1
	if core.lose_answer {
		core.lose_answer = false
		return .Stale_Serial
	}
	return .None
}

@(private = "file")
test_core_read :: proc "contextless" (user: rawptr) -> (serial, generation: u64, ok: bool) {
	core := (^Test_Core)(user)
	core.reads += 1
	if core.read_fails {
		return 0, 0, false
	}
	return core.serial, core.in_force.generation, true
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
	roles_port_bind(state, {user = core, replace = test_core_replace, read = test_core_read})
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
// The answer of a set is lost after the core took it: the port reads the
// core, gives it the generation of the store, then the set again. The core
// and the store end on the same generation.
@(test)
test_plans_roles_lost_answer_reconciles :: proc(t: ^testing.T) {
	core: Test_Core
	state, store := roles_state(&core)
	defer free(state)
	defer free(store)
	first := role_plan(0, .Storage, 1)
	first_record, refusal := apply_now(state, &first, {})
	testing.expect_value(t, refusal, pr.Plan_Refusal.None)
	testing.expect(t, state.roles.synchronized)

	core.lose_answer = true
	reads := core.reads
	second := role_plan(0, .Storage, 2)
	record, second_refusal := apply_now(state, &second, first_record.plan_hash)
	testing.expect_value(t, second_refusal, pr.Plan_Refusal.None)
	testing.expect_value(t, record.generation, u64(2))
	testing.expect_value(t, core.reads, reads + 1)
	testing.expect_value(t, core.in_force.generation, u64(2))
	testing.expect_value(t, core.in_force.overrides[0].module_hash, roles_test_hash(2))
	testing.expect_value(t, state.roles.serial, core.serial)
	testing.expect(t, state.roles.synchronized)
	// The core went back to generation 1, then took generation 2 again.
	testing.expect_value(t, core.steps[core.calls - 2], rd.Plan_Roles_Step.Rollback)
	testing.expect_value(t, core.steps[core.calls - 1], rd.Plan_Roles_Step.Apply)
}

// Another set came first, so the serial of the port is stale: the port
// reads the core, gives it the generation of the store, and the apply
// commits with the core in step.
@(test)
test_plans_roles_stale_serial_reconciles :: proc(t: ^testing.T) {
	core: Test_Core
	state, store := roles_state(&core)
	defer free(state)
	defer free(store)
	first := role_plan(0, .Storage, 1)
	first_record, _ := apply_now(state, &first, {})
	// A set that the store never named.
	core.in_force = {generation = 9}
	core.serial += 1
	second := role_plan(0, .Storage, 2)
	_, refusal := apply_now(state, &second, first_record.plan_hash)
	testing.expect_value(t, refusal, pr.Plan_Refusal.None)
	testing.expect_value(t, core.in_force.generation, u64(2))
	testing.expect_value(t, state.roles.serial, core.serial)

	// A core that does not answer the read: nothing commits.
	core.in_force = {generation = 9}
	core.serial += 1
	core.read_fails = true
	third := role_plan(0, .Storage, 3)
	_, current, _ := current_plan(state, 0)
	_, third_refusal := apply_now(state, &third, current.plan_hash)
	testing.expect_value(t, third_refusal, pr.Plan_Refusal.Roles_Refused)
	testing.expect_value(t, highest_generation(state, 0), u64(2))
	testing.expect(t, !state.roles.synchronized)
}

// The store refuses a commit that the core took, and the core refuses the
// compensation: the port is unsynchronized and says so. The next apply
// reconciles first, and the core and the store end on one generation.
@(test)
test_plans_roles_failed_compensation_recovers :: proc(t: ^testing.T) {
	core: Test_Core
	state, store := roles_state(&core)
	defer free(state)
	defer free(store)
	first := role_plan(0, .Storage, 1)
	first_record, _ := apply_now(state, &first, {})

	store.writes_allowed = store.writes + 1
	core.refuse, core.refuse_step = .Not_In_Image, .Rollback
	second := role_plan(0, .Storage, 2)
	_, refusal := apply_now(state, &second, first_record.plan_hash)
	testing.expect_value(t, refusal, pr.Plan_Refusal.Store_Failed)
	testing.expect(t, state.roles_compensation_failed)
	testing.expect(t, !state.roles.synchronized)
	testing.expect_value(t, core.in_force.generation, u64(2))
	testing.expect_value(t, highest_generation(state, 0), u64(1))

	store.writes_allowed = -1
	core.refuse, core.refuse_step = .None, .None
	third := role_plan(0, .Storage, 3)
	record, third_refusal := apply_now(state, &third, first_record.plan_hash)
	testing.expect_value(t, third_refusal, pr.Plan_Refusal.None)
	testing.expect_value(t, record.generation, u64(2))
	testing.expect_value(t, core.in_force.generation, u64(2))
	testing.expect_value(t, core.in_force.overrides[0].module_hash, roles_test_hash(3))
	testing.expect(t, state.roles.synchronized)
	testing.expect_value(t, core.steps[core.calls - 2], rd.Plan_Roles_Step.Rollback)
	testing.expect_value(t, core.in_force.generation, record.generation)
}

// A service that starts again finds the core on a generation that the store
// did not commit: the bind reconciles them before any set.
@(test)
test_plans_roles_bind_reconciles_a_restart :: proc(t: ^testing.T) {
	core: Test_Core
	state, store := roles_state(&core)
	defer free(state)
	defer free(store)
	first := role_plan(0, .Storage, 1)
	_, refusal := apply_now(state, &first, {})
	testing.expect_value(t, refusal, pr.Plan_Refusal.None)
	// The core took generation 2, and the service stopped before the store.
	core.in_force = {generation = 2, override_count = 1}
	core.serial += 1
	forget(state)
	roles_port_bind(state, {user = &core, replace = test_core_replace, read = test_core_read, serial = core.serial, generation = 2})
	testing.expect(t, !state.roles.synchronized)
	testing.expect_value(t, roles_reconcile(state), pr.Plan_Refusal.None)
	testing.expect(t, state.roles.synchronized)
	testing.expect_value(t, core.in_force.generation, u64(1))
	testing.expect_value(t, core.in_force.overrides[0].module_hash, roles_test_hash(1))
	testing.expect_value(t, core.steps[core.calls - 1], rd.Plan_Roles_Step.Rollback)
}
