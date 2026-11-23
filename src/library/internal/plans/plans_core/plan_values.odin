package plans_core

// The plan values of principal 0 (src/md/features/module_settings.md,
// "Plan records"): the Value entries of a plan, which the holder of Plans
// gives the core with the command Plan_Values beside the roles. The core
// checks the set whole and keeps it; each owner reads its values at its
// next start.
//
// The values go first, then the roles: a set of values that the core
// refuses changes nothing, and a refusal of the roles gives the core the
// values of the generation in force again, so the core never holds the
// values of one generation with the roles of another.

import "modus:contract/chosen_values"
import "modus:contract/plan_values"
import pr "modus:contract/plans_recipes"
import rd "modus:contract/root_delegation"

// The port of the values of the machine: the command Plan_Values of the
// root ring. answered is false with no answer; problem is the refusal of
// the core. A port with no procedure gives no value: an apply of a plan of
// principal 0 with a Value entry is then refused with Values_Refused.
Values_Port :: struct {
	user:    rawptr,
	replace: proc "contextless" (user: rawptr, set: []u8, step: rd.Plan_Roles_Step) -> (problem: plan_values.Set_Problem, answered: bool),
}

// The bytes of the records of one owner while a set is written.
@(private = "file")
OWNER_RECORD_BYTES :: chosen_values.HEADER_SIZE + pr.MAX_PLAN_ENTRIES * chosen_values.ENTRY_SIZE

// plan_values_set_of writes the set of the Value entries of a plan, owner
// by owner, in the order of their first entry: the defaults and the locks
// of each, as records of chosen values. A plan with no plan (nil) is the
// set of no value. ok is false when the set does not fit, or the core would
// refuse it (plan_values.set_check): the plan border took each entry, so
// that is a fault of this code.
plan_values_set_of :: proc "contextless" (plan: ^pr.Plan_Spec, generation: u64, out: []u8) -> (written: int, ok: bool) {
	Owner_Records :: struct {
		owner:    string,
		defaults: [pr.MAX_PLAN_ENTRIES]chosen_values.Change,
		locks:    [pr.MAX_PLAN_ENTRIES]chosen_values.Change,
		defaults_count, locks_count: int,
	}
	@(static) owners: [plan_values.OWNER_CAPACITY]Owner_Records
	@(static) bytes: [plan_values.OWNER_CAPACITY][2][OWNER_RECORD_BYTES]u8
	owner_count := 0
	count := plan == nil ? 0 : min(int(plan.entry_count), pr.MAX_PLAN_ENTRIES)
	for index in 0 ..< count {
		entry := &plan.entries[index]
		if entry.kind_word != u64(pr.Plan_Entry_Kind.Value) {
			continue
		}
		owner, field, parts_ok := pr.plan_value_parts(entry)
		layer, layer_ok := pr.plan_value_layer_of_word(entry.value_layer_word)
		if !parts_ok || !layer_ok {
			return 0, false
		}
		place := -1
		for other in 0 ..< owner_count {
			if owners[other].owner == owner {
				place = other
			}
		}
		if place < 0 {
			if owner_count == plan_values.OWNER_CAPACITY {
				return 0, false
			}
			place = owner_count
			owners[place] = {owner = owner}
			owner_count += 1
		}
		records := &owners[place]
		change := chosen_values.Change{name = field, kind = .Choose, value = entry.value_word}
		if layer == .Locked {
			records.locks[records.locks_count] = change
			records.locks_count += 1
		} else {
			records.defaults[records.defaults_count] = change
			records.defaults_count += 1
		}
	}
	blocks: [plan_values.OWNER_CAPACITY]plan_values.Owner_Block
	for index in 0 ..< owner_count {
		records := &owners[index]
		defaults_written, defaults_problem := chosen_values.write_record({}, records.defaults[:records.defaults_count], bytes[index][0][:])
		locks_written, locks_problem := chosen_values.write_record({}, records.locks[:records.locks_count], bytes[index][1][:])
		if defaults_problem != .None || locks_problem != .None {
			return 0, false
		}
		blocks[index] = {owner = records.owner, defaults = bytes[index][0][:defaults_written], locks = bytes[index][1][:locks_written]}
	}
	written = plan_values.set_write(out, MACHINE_PRINCIPAL, max(generation, 1), blocks[:owner_count])
	if written == 0 {
		return 0, false
	}
	_, problem := plan_values.set_check(out)
	return written, problem == .None
}

// plan_has_values says if a plan has a Value entry.
@(private = "file")
plan_has_values :: proc "contextless" (plan: ^pr.Plan_Spec) -> bool {
	if plan == nil {
		return false
	}
	for entry in plan.entries[:min(int(plan.entry_count), pr.MAX_PLAN_ENTRIES)] {
		if entry.kind_word == u64(pr.Plan_Entry_Kind.Value) {
			return true
		}
	}
	return false
}

// values_give sends the core the values of plan as the set of a
// generation. Only the plan of principal 0 gives the values of the
// machine: the plan of another principal sends nothing.
values_give :: proc "contextless" (state: ^Plans_State, principal: u64, plan: ^pr.Plan_Spec, generation: u64, step: rd.Plan_Roles_Step) -> pr.Plan_Refusal {
	if principal != MACHINE_PRINCIPAL {
		return .None
	}
	if state.values.replace == nil {
		return plan_has_values(plan) ? .Values_Refused : .None
	}
	written, ok := plan_values_set_of(plan, generation, state.values_set[:])
	if !ok {
		state.values_problem = .Too_Short
		return .Values_Refused
	}
	problem, answered := state.values.replace(state.values.user, state.values_set[:written], step)
	state.values_problem = problem
	if !answered || problem != .None {
		return .Values_Refused
	}
	return .None
}

// plan_give sends the core the values, then the roles, of a generation. A
// refusal of the roles gives the core the values of the generation in
// force again (previous), so the two always name one generation.
plan_give :: proc "contextless" (state: ^Plans_State, principal: u64, plan: ^pr.Plan_Spec, generation: u64, step: rd.Plan_Roles_Step, previous: ^pr.Plan_Spec, previous_generation: u64) -> pr.Plan_Refusal {
	if refusal := values_give(state, principal, plan, generation, step); refusal != .None {
		return refusal
	}
	if refusal := roles_give(state, principal, plan, generation, step); refusal != .None {
		_ = values_give(state, principal, previous, previous_generation, .Rollback)
		return refusal
	}
	return .None
}
