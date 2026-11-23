#+build !freestanding
package plans_core

import "core:testing"
import "modus:contract/chosen_values"
import "modus:contract/plan_values"
import pr "modus:contract/plans_recipes"
import rd "modus:contract/root_delegation"

// The set of the values of a plan: the entries of each owner in its
// records, a lock apart from a default, the other kinds left out; the set
// passes the check of the core. A plan with no value is a set of no owner.
@(test)
the_values_of_a_plan_become_one_set :: proc(t: ^testing.T) {
	plan: pr.Plan_Spec
	add :: proc(plan: ^pr.Plan_Spec, owner, field: string, word: u64, layer: chosen_values.Layer) {
		entry, _ := pr.plan_entry_make_value(owner, field, word, layer)
		plan.entries[plan.entry_count] = entry
		plan.entry_count += 1
	}
	add(&plan, "display", "bar_edge", 2, .Plan_Default)
	add(&plan, "storage", "keep_all_minutes", 30, .Locked)
	add(&plan, "display", "consent_arm_milliseconds", 1000, .Locked)
	store, _ := pr.plan_entry_make_store("notes", .Read_Only)
	plan.entries[plan.entry_count] = store
	plan.entry_count += 1
	out: [plan_values.SET_SIZE]u8
	written, ok := plan_values_set_of(&plan, 4, out[:])
	testing.expect(t, ok && written > 0)
	head, problem := plan_values.set_check(out[:])
	testing.expect(t, problem == .None && head.owner_count == 2 && head.generation == 4)
	display, found := plan_values.owner_values_of(out[:], "display")
	testing.expect(t, found && display.defaults.count == 1 && display.locks.count == 1 && plan_values.locked(display, "consent_arm_milliseconds"))
	storage, storage_found := plan_values.owner_values_of(out[:], "storage")
	testing.expect(t, storage_found && plan_values.locked(storage, "keep_all_minutes"))
	_, notes := plan_values.owner_values_of(out[:], "notes")
	testing.expect(t, !notes)
	none: [plan_values.SET_SIZE]u8
	none_written, none_ok := plan_values_set_of(nil, 0, none[:])
	testing.expect(t, none_ok && none_written == plan_values.SET_HEADER_SIZE)
	// A damaged entry that passed no border is refused, not sent.
	damaged := plan
	damaged.entries[0].value_layer_word = 2
	_, damaged_ok := plan_values_set_of(&damaged, 4, out[:])
	testing.expect(t, !damaged_ok)
}

// With no port, a plan of principal 0 with a value is refused and one with
// none passes; a plan of another principal sends nothing. A refusal of the
// core is a refusal of the apply.
@(test)
values_with_no_port_or_a_refusal_are_refused :: proc(t: ^testing.T) {
	state: Plans_State
	plan: pr.Plan_Spec
	entry, _ := pr.plan_entry_make_value("display", "bar_edge", 2, .Plan_Default)
	plan.entries[0], plan.entry_count = entry, 1
	testing.expect_value(t, values_give(&state, MACHINE_PRINCIPAL, &plan, 1, .Apply), pr.Plan_Refusal.Values_Refused)
	testing.expect_value(t, values_give(&state, MACHINE_PRINCIPAL, nil, 1, .Apply), pr.Plan_Refusal.None)
	testing.expect_value(t, values_give(&state, 7, &plan, 1, .Apply), pr.Plan_Refusal.None)
	refuse :: proc "contextless" (user: rawptr, set: []u8, step: rd.Plan_Roles_Step) -> (problem: plan_values.Set_Problem, answered: bool) {
		return .Bad_Record, true
	}
	silent :: proc "contextless" (user: rawptr, set: []u8, step: rd.Plan_Roles_Step) -> (problem: plan_values.Set_Problem, answered: bool) {
		return .None, false
	}
	state.values = {replace = refuse}
	testing.expect_value(t, values_give(&state, MACHINE_PRINCIPAL, &plan, 1, .Apply), pr.Plan_Refusal.Values_Refused)
	testing.expect_value(t, state.values_problem, plan_values.Set_Problem.Bad_Record)
	state.values = {replace = silent}
	testing.expect_value(t, values_give(&state, MACHINE_PRINCIPAL, &plan, 1, .Apply), pr.Plan_Refusal.Values_Refused)
}
