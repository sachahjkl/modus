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
	// Refuse this many sets with Grants_Busy before the rules above, as a
	// root service whose service rings are full.
	busy:          int,
	pauses:        int,
}

@(private = "file")
test_core_replace :: proc "contextless" (user: rawptr, set: ^rd.Plan_Roles_Set, step: rd.Plan_Roles_Step) -> rd.Plan_Roles_Refusal {
	core := (^Test_Core)(user)
	if core.calls < len(core.steps) {
		core.steps[core.calls] = step
	}
	core.calls += 1
	if core.busy > 0 {
		core.busy -= 1
		return .Grants_Busy
	}
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
	plan := test_plan(principal, 1)
	plan.entries[0], _ = pr.plan_entry_make_role("holder", role, roles_test_hash(tag))
	return plan
}

@(private = "file")
test_core_pause :: proc "contextless" (user: rawptr) {
	(^Test_Core)(user).pauses += 1
}

@(private = "file")
roles_state :: proc(core: ^Test_Core) -> (state: ^Plans_State, store: ^pr.Memory_Private_Store) {
	state = new(Plans_State)
	store = plans_test_state_init(state, 0)
	roles_port_bind(state, {user = core, replace = test_core_replace, read = test_core_read, pause = test_core_pause})
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
	module_only := test_plan(0, 1)
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
	_, refusal = rollback_commit(state, 0)
	testing.expect_value(t, refusal, pr.Plan_Refusal.Roles_Refused)
	_, current, _ := current_plan(state, 0)
	testing.expect_value(t, current.generation, u64(2))
	testing.expect_value(t, core.in_force.generation, u64(2))

	core.refuse = .None
	selected, rollback_refusal := rollback_commit(state, 0)
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
	plan := test_plan(0, 2)
	plan.entries[0], _ = pr.plan_entry_make_role("first", .Assistive, roles_test_hash(1))
	plan.entries[1], _ = pr.plan_entry_make_role("second", .Assistive, roles_test_hash(2))
	set: rd.Plan_Roles_Set
	testing.expect(t, !plan_roles_set_of(&plan, 1, 0, &set))

	// An interposer over the first module is the one that callers reach.
	chained := test_plan(0, 2)
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
	testing.expect_value(t, set.script_fonts, blake3.Hash{})
}

// The script font set of a plan travels in the set of its roles, beside
// its overrides; a plan with none, and a set of the defaults, carry zero.
@(test)
test_plans_roles_set_of_carries_the_script_font_set :: proc(t: ^testing.T) {
	plan := pr.Plan_Spec{principal = 0, entry_count = 2}
	plan.entries[0], _ = pr.plan_entry_make_role("first", .Assistive, roles_test_hash(1))
	plan.entries[1], _ = pr.plan_entry_make_script_fonts(roles_test_hash(9))
	set: rd.Plan_Roles_Set
	testing.expect(t, plan_roles_set_of(&plan, 3, 0, &set))
	testing.expect_value(t, set.override_count, u64(1))
	testing.expect_value(t, set.script_fonts, roles_test_hash(9))
	plan.entry_count = 1
	testing.expect(t, plan_roles_set_of(&plan, 3, 0, &set))
	testing.expect_value(t, set.script_fonts, blake3.Hash{})
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

// The machine stops and starts again: a new core holds the roles of the
// image (serial 0, generation 0), and the service forgets its tables.
@(private = "file")
reboot :: proc(state: ^Plans_State, core: ^Test_Core) {
	core^ = {}
	forget(state)
	roles_port_bind(state, {user = core, replace = test_core_replace, read = test_core_read})
}

// A stored plan of principal 0 that names the holder of Display: at the
// start, the core gets its roles with one Rollback before any start policy,
// and the next apply is sent as usual.
@(test)
test_plans_start_gives_the_stored_display_holder :: proc(t: ^testing.T) {
	core: Test_Core
	state, store := roles_state(&core)
	defer free(state)
	defer free(store)
	plan := role_plan(0, .Display, 7)
	record, refusal := apply_now(state, &plan, {})
	testing.expect_value(t, refusal, pr.Plan_Refusal.None)

	reboot(state, &core)
	testing.expect_value(t, roles_start(state), rd.Plan_Roles_Load_Outcome.Applied)
	testing.expect_value(t, core.calls, 1)
	testing.expect_value(t, core.steps[0], rd.Plan_Roles_Step.Rollback)
	testing.expect_value(t, core.in_force.generation, record.generation)
	testing.expect_value(t, core.in_force.override_count, u64(1))
	testing.expect_value(t, core.in_force.overrides[0].role_word, u64(role_contract.Role.Display))
	testing.expect_value(t, core.in_force.overrides[0].module_hash, roles_test_hash(7))
	testing.expect_value(t, state.roles_stored_refusal, rd.Plan_Roles_Refusal.None)
	testing.expect(t, state.roles.synchronized)

	next := role_plan(0, .Display, 8)
	next_record, next_refusal := apply_now(state, &next, record.plan_hash)
	testing.expect_value(t, next_refusal, pr.Plan_Refusal.None)
	testing.expect_value(t, core.in_force.generation, next_record.generation)
	testing.expect_value(t, core.steps[core.calls - 1], rd.Plan_Roles_Step.Apply)
}

// A fresh machine: no current object in the store. The core is read once
// and never asked to change: the roles of the image hold at once.
@(test)
test_plans_start_with_no_plan_asks_nothing :: proc(t: ^testing.T) {
	core: Test_Core
	state, store := roles_state(&core)
	defer free(state)
	defer free(store)
	testing.expect_value(t, roles_start(state), rd.Plan_Roles_Load_Outcome.No_Plan)
	testing.expect_value(t, core.calls, 0)
	testing.expect_value(t, core.reads, 1)
	testing.expect_value(t, core.in_force, rd.Plan_Roles_Set{})
	testing.expect(t, state.roles.synchronized)
	testing.expect_value(t, store.writes, 0)

	// A plan of principal 0 with no role still is a current plan: the
	// start gives its empty set, and says Applied.
	module_only := test_plan(0, 1)
	module_only.entries[0], _ = pr.plan_entry_make_module(.Disk_Module, "calc", roles_test_hash(9), 0)
	_, refusal := apply_now(state, &module_only, {})
	testing.expect_value(t, refusal, pr.Plan_Refusal.None)
	reboot(state, &core)
	testing.expect_value(t, roles_start(state), rd.Plan_Roles_Load_Outcome.Applied)
	testing.expect_value(t, core.in_force.override_count, u64(0))
	testing.expect_value(t, core.in_force.generation, u64(1))
}

// A newer boot image lacks the stored holder, or its holder no longer
// fills the contract: the start keeps the roles of the image, keeps the
// refusal, and the port is synchronized, so the next apply is sent once
// and commits.
@(test)
test_plans_start_with_a_plan_that_the_image_refuses_keeps_the_image :: proc(t: ^testing.T) {
	refusals := [2]rd.Plan_Roles_Refusal{.Not_In_Image, .Contract_Not_Filled}
	for content_refusal in refusals {
		core: Test_Core
		state, store := roles_state(&core)
		plan := role_plan(0, .Display, 3)
		record, refusal := apply_now(state, &plan, {})
		testing.expect_value(t, refusal, pr.Plan_Refusal.None)

		reboot(state, &core)
		core.refuse, core.refuse_step = content_refusal, .Rollback
		testing.expect_value(t, roles_start(state), rd.Plan_Roles_Load_Outcome.Plan_Refused)
		testing.expect_value(t, state.roles_stored_refusal, content_refusal)
		testing.expect(t, state.roles.synchronized)
		// The core held the image already: no second set.
		testing.expect_value(t, core.calls, 1)
		testing.expect_value(t, core.in_force, rd.Plan_Roles_Set{})
		testing.expect_value(t, core.serial, u64(0))
		// The store keeps its plan: nothing is written at the start.
		_, current, found := current_plan(state, 0)
		testing.expect(t, found)
		testing.expect_value(t, current.generation, record.generation)

		// The next apply names a module of the new image: it is sent at
		// once, with no reconciliation that the old plan would refuse.
		reads := core.reads
		next := role_plan(0, .Display, 4)
		next_record, next_refusal := apply_now(state, &next, record.plan_hash)
		testing.expect_value(t, next_refusal, pr.Plan_Refusal.None)
		testing.expect_value(t, next_record.generation, u64(2))
		testing.expect_value(t, core.reads, reads)
		testing.expect_value(t, core.steps[core.calls - 1], rd.Plan_Roles_Step.Apply)
		testing.expect_value(t, core.in_force.generation, u64(2))
		testing.expect_value(t, core.in_force.overrides[0].module_hash, roles_test_hash(4))
		testing.expect_value(t, state.roles_stored_refusal, rd.Plan_Roles_Refusal.None)
		free(state)
		free(store)
	}
}

// A core that refuses a set naming one hash with Not_In_Image, and takes
// any other set.
@(private = "file")
Content_Refusing_Core :: struct {
	core:         ^Test_Core,
	refused_hash: blake3.Hash,
}

@(private = "file")
content_refusing_replace :: proc "contextless" (user: rawptr, set: ^rd.Plan_Roles_Set, step: rd.Plan_Roles_Step) -> rd.Plan_Roles_Refusal {
	refusing := (^Content_Refusing_Core)(user)
	for override in set.overrides[:set.override_count] {
		if override.module_hash == refusing.refused_hash {
			refusing.core.calls += 1
			return .Not_In_Image
		}
	}
	return test_core_replace(refusing.core, set, step)
}

@(private = "file")
content_refusing_read :: proc "contextless" (user: rawptr) -> (serial, generation: u64, ok: bool) {
	return test_core_read((^Content_Refusing_Core)(user).core)
}

// The core holds the roles of another generation when the stored one is
// refused for its content: it gets the roles of the image (generation 0,
// no override), never a part of either plan. A core that refuses the set
// of the image too keeps its set, and the port stays unsynchronized.
@(test)
test_plans_reconcile_refused_content_gives_the_core_the_image :: proc(t: ^testing.T) {
	core: Test_Core
	state, store := roles_state(&core)
	defer free(state)
	defer free(store)
	plan := role_plan(0, .Storage, 1)
	_, refusal := apply_now(state, &plan, {})
	testing.expect_value(t, refusal, pr.Plan_Refusal.None)
	// The core took a generation 5 that the store never committed.
	core.in_force = {generation = 5, override_count = 1}
	core.in_force.overrides[0] = {role_word = u64(role_contract.Role.Storage), module_hash = roles_test_hash(5)}
	core.serial += 1
	forget(state)
	roles_port_bind(state, {user = &core, replace = test_core_replace, read = test_core_read})
	core.refuse, core.refuse_step = .Not_In_Image, .Rollback
	testing.expect_value(t, roles_reconcile(state), pr.Plan_Refusal.Roles_Refused)
	testing.expect(t, !state.roles.synchronized)
	testing.expect_value(t, core.in_force.generation, u64(5))

	core.refuse, core.refuse_step = .None, .None
	core.calls = 0
	refusing := Content_Refusing_Core{core = &core, refused_hash = roles_test_hash(1)}
	roles_port_bind(state, {user = &refusing, replace = content_refusing_replace, read = content_refusing_read})
	testing.expect_value(t, roles_reconcile(state), pr.Plan_Refusal.None)
	testing.expect(t, state.roles.synchronized)
	testing.expect_value(t, state.roles_stored_refusal, rd.Plan_Roles_Refusal.Not_In_Image)
	testing.expect_value(t, core.in_force.generation, u64(0))
	testing.expect_value(t, core.in_force.override_count, u64(0))
	testing.expect_value(t, core.calls, 2)
}

// A refusal of the order of the sets is no refusal of the content: the
// start says that the core was not read, and the next set tries again.
@(test)
test_plans_start_stale_serial_is_no_fallback :: proc(t: ^testing.T) {
	core: Test_Core
	state, store := roles_state(&core)
	defer free(state)
	defer free(store)
	plan := role_plan(0, .Display, 3)
	_, refusal := apply_now(state, &plan, {})
	testing.expect_value(t, refusal, pr.Plan_Refusal.None)
	reboot(state, &core)
	core.refuse, core.refuse_step = .Stale_Serial, .Rollback
	testing.expect_value(t, roles_start(state), rd.Plan_Roles_Load_Outcome.Core_Unread)
	testing.expect(t, !state.roles.synchronized)
	testing.expect_value(t, state.roles_stored_refusal, rd.Plan_Roles_Refusal.None)

	// A core that does not answer the read.
	reboot(state, &core)
	core.read_fails = true
	testing.expect_value(t, roles_start(state), rd.Plan_Roles_Load_Outcome.Core_Unread)
	testing.expect_value(t, core.calls, 0)

	// No roles page: no procedure.
	state.roles = {}
	testing.expect_value(t, roles_start(state), rd.Plan_Roles_Load_Outcome.Core_Unread)
}

// A damaged current object, an empty one, a damaged generation object, and
// a store that fails: the start refuses the plan, asks the core nothing,
// and the roles of the image hold.
@(test)
test_plans_start_with_a_damaged_store_keeps_the_image :: proc(t: ^testing.T) {
	Damage :: enum {
		Current_Bytes,
		Current_Empty,
		Generation_Bytes,
		Store_Fails,
	}
	for damage in Damage {
		core: Test_Core
		state, store := roles_state(&core)
		plan := role_plan(0, .Display, 3)
		_, refusal := apply_now(state, &plan, {})
		testing.expect_value(t, refusal, pr.Plan_Refusal.None)
		reboot(state, &core)
		current_name := pr.plan_object_name(0, 0, true)
		generation_name := pr.plan_object_name(0, 1, false)
		garbage := [5]u8{0xFF, 0, 1, 2, 3}
		switch damage {
		case .Current_Bytes:
			testing.expect_value(t, pr.private_store_write(&state.store, pr.private_object_name_text(&current_name), garbage[:]), pr.Private_Store_Status.Ok)
		case .Current_Empty:
			testing.expect_value(t, pr.private_store_write(&state.store, pr.private_object_name_text(&current_name), garbage[:0]), pr.Private_Store_Status.Ok)
		case .Generation_Bytes:
			testing.expect_value(t, pr.private_store_write(&state.store, pr.private_object_name_text(&generation_name), garbage[:]), pr.Private_Store_Status.Ok)
		case .Store_Fails:
			state.store = {}
		}
		testing.expectf(t, roles_start(state) == .Store_Unread, "damage %v", damage)
		testing.expect_value(t, core.calls, 0)
		testing.expect_value(t, core.in_force, rd.Plan_Roles_Set{})
		testing.expect(t, !state.roles.synchronized)
		// An apply on that store is refused too: nothing acts on a part of
		// a history.
		next := role_plan(0, .Display, 4)
		_, next_refusal := apply_now(state, &next, {})
		testing.expect(t, next_refusal != .None)
		testing.expect_value(t, core.in_force, rd.Plan_Roles_Set{})
		free(state)
		free(store)
	}
}

// The tags of the commands Page with no answer: a late completion with one
// of them is a page to close, once; a tag of 0, an unknown tag, and a tag
// already taken are not; the oldest tag leaves for a new one.
@(test)
test_plans_late_page_tags :: proc(t: ^testing.T) {
	late: Late_Page_Tags
	testing.expect(t, !late_page_take(&late, 0))
	testing.expect(t, !late_page_take(&late, 7))
	late_page_remember(&late, 0)
	testing.expect_value(t, late, Late_Page_Tags{})
	late_page_remember(&late, 7)
	testing.expect(t, !late_page_take(&late, 8))
	testing.expect(t, late_page_take(&late, 7))
	testing.expect(t, !late_page_take(&late, 7))
	for tag in u32(1) ..= LATE_PAGE_TAG_CAPACITY + 1 {
		late_page_remember(&late, tag)
	}
	// The first tag left for the last one.
	testing.expect(t, !late_page_take(&late, 1))
	for tag in u32(2) ..= LATE_PAGE_TAG_CAPACITY + 1 {
		testing.expect(t, late_page_take(&late, tag))
	}
	late_page_remember(&late, max(u32))
	testing.expect(t, late_page_take(&late, max(u32)))
}

// A trusted display whose principal gives one decision to each dialog.
@(private = "file")
Deciding_Display :: struct {
	serial:   u64,
	decision: pr.Plan_Display_Decision,
}

@(private = "file")
deciding_ask :: proc "contextless" (user: rawptr, plan_name: string, added: string, removed: string) -> (serial: u64, ok: bool) {
	display := (^Deciding_Display)(user)
	display.serial += 1
	return display.serial, true
}

@(private = "file")
deciding_poll :: proc "contextless" (user: rawptr, serial: u64) -> (decision: pr.Plan_Display_Decision, ok: bool) {
	return (^Deciding_Display)(user).decision, true
}

// A rollback of principal 0 changes the holder of a role: the core gets no
// set while the dialog shows, nor after a refusal of the principal, so the
// holder never changes in silence. Last: an accepted rollback gives the
// core the roles of the generation that the principal saw.
@(test)
test_plans_rollback_changes_no_role_holder_before_the_principal_accepts :: proc(t: ^testing.T) {
	core: Test_Core
	state, store := roles_state(&core)
	defer free(state)
	defer free(store)
	first := role_plan(0, .Storage, 1)
	first_record, refusal := apply_now(state, &first, {})
	testing.expect_value(t, refusal, pr.Plan_Refusal.None)
	second := role_plan(0, .Storage, 2)
	_, refusal = apply_now(state, &second, first_record.plan_hash)
	testing.expect_value(t, refusal, pr.Plan_Refusal.None)
	calls := core.calls
	in_force := core.in_force

	display := Deciding_Display{decision = .Pending}
	port := Trusted_Display_Port{user = &display, ask = deciding_ask, poll = deciding_poll}
	difference: pr.Plan_Difference
	lists: Plan_Display_Lists
	ticket, request_refusal := rollback_request(state, &port, 0, &difference, &lists)
	testing.expect_value(t, request_refusal, pr.Plan_Refusal.None)
	_, finished, _ := rollback_poll(state, &port, 0, ticket)
	testing.expect(t, !finished)
	testing.expect_value(t, core.calls, calls)
	testing.expect_value(t, core.in_force, in_force)

	display.decision = .Refused
	_, _, refused := rollback_poll(state, &port, 0, ticket)
	testing.expect_value(t, refused, pr.Plan_Refusal.Refused_By_Principal)
	testing.expect_value(t, core.calls, calls)
	testing.expect_value(t, core.in_force, in_force)
	_, current, _ := current_plan(state, 0)
	testing.expect_value(t, current.generation, u64(2))

	display.decision = .Accepted
	accepted, _ := rollback_request(state, &port, 0, &difference, &lists)
	selected, accepted_finished, accepted_refusal := rollback_poll(state, &port, 0, accepted)
	testing.expect(t, accepted_finished)
	testing.expect_value(t, accepted_refusal, pr.Plan_Refusal.None)
	testing.expect_value(t, selected.generation, u64(1))
	testing.expect_value(t, core.in_force.generation, u64(1))
	testing.expect_value(t, core.in_force.overrides[0].module_hash, roles_test_hash(1))
	testing.expect_value(t, core.steps[core.calls - 1], rd.Plan_Roles_Step.Rollback)
}

// A full service ring refuses the set with nothing changed: the set goes
// again after a pause, up to the bound. Past the bound the plan commits
// nothing, and the refusal names the full rings.
@(test)
test_plans_roles_busy_past_the_bound_commit_nothing :: proc(t: ^testing.T) {
	core := Test_Core{busy = ROLES_BUSY_RESEND_BOUND + 1}
	state, store := roles_state(&core)
	defer free(state)
	defer free(store)
	plan := role_plan(0, .Storage, 1)
	record, refusal := apply_now(state, &plan, {})
	testing.expect_value(t, refusal, pr.Plan_Refusal.Roles_Refused)
	testing.expect_value(t, state.roles_refusal, rd.Plan_Roles_Refusal.Grants_Busy)
	testing.expect_value(t, state.roles_busy_resends, u32(ROLES_BUSY_RESEND_BOUND))
	testing.expect_value(t, core.pauses, ROLES_BUSY_RESEND_BOUND)
	testing.expect_value(t, record, pr.Applied_Plan_Record{})
	testing.expect_value(t, highest_generation(state, 0), u64(0))
	testing.expect_value(t, core.serial, u64(0))
	current_name := pr.plan_object_name(0, 0, true)
	testing.expect(t, pr.memory_private_store_find(store, pr.private_object_name_text(&current_name)) == nil)
}

@(test)
test_plans_roles_busy_up_to_the_bound_commit :: proc(t: ^testing.T) {
	for busy in ([]int{0, 1, ROLES_BUSY_RESEND_BOUND}) {
		core := Test_Core{busy = busy}
		state, store := roles_state(&core)
		plan := role_plan(0, .Storage, 1)
		record, refusal := apply_now(state, &plan, {})
		testing.expectf(t, refusal == .None, "busy %d: the refusal %v", busy, refusal)
		testing.expect_value(t, record.generation, u64(1))
		testing.expect_value(t, state.roles_busy_resends, u32(busy))
		testing.expect_value(t, core.pauses, busy)
		testing.expect_value(t, core.serial, u64(1))
		free(state)
		free(store)
	}
}
