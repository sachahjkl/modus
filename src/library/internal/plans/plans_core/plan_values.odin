package plans_core

// The plan values of principal 0 (src/md/features/module_settings.md,
// "Plan records"): the Value entries of a plan, which the holder of Plans
// gives the core with the command Plan_Values beside the roles. The core
// checks the set whole and takes it; the set holds from the step
// Committed, which this service sends once its store committed the
// generation (values_commit), so no owner holds a value of a generation
// that the store refused.
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
// root ring. answered is false with no answer, or with a refusal that
// names no content (no pages, a full ring); problem is the refusal of the
// content. A port with no procedure gives no value: an apply of a plan of
// principal 0 with a Value entry is then refused with Values_Refused.
// commit sends the step Committed of a generation; taken is false when the
// core did not put it in force (a full service ring, no set of that
// generation). nil: nothing to commit, as in a host test of the roles.
Values_Port :: struct {
	user:    rawptr,
	replace: proc "contextless" (user: rawptr, set: []u8, step: rd.Plan_Roles_Step) -> (problem: plan_values.Set_Problem, answered: bool),
	commit:  proc "contextless" (user: rawptr, generation: u64) -> (taken: bool, answered: bool),
}

// Why the core holds other values than the store: the cause of the last
// send of values that it did not take.
Values_Cause :: enum u8 {
	None           = 0,
	Set_Too_Large  = 1, // The set of the plan does not fit the pages: a fault of this code, which the border of the plan checks.
	No_Answer      = 2, // The core gave no answer, or refused with no cause of content.
	Refused        = 3, // The core refused the content of the set: values_problem names it.
	Not_Committed  = 4, // The core did not put the set of a committed generation in force.
}

// The names of the causes, for the line of the log.
@(rodata)
VALUES_CAUSE_NAMES := [Values_Cause]string {
	.None          = "none",
	.Set_Too_Large = "set too large",
	.No_Answer     = "no answer",
	.Refused       = "set refused",
	.Not_Committed = "commit not taken",
}

// The sends of one set of values, or of one step Committed, at most: the
// core refuses for a full service ring, and the pause of the roles port
// lets the services read their rings between two sends.
VALUES_SEND_TRIES :: 3

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
	// The records of every owner, one after the other: the texts of a plan
	// fit a set, so they fit this.
	@(static) bytes: [plan_values.SET_SIZE]u8
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
		if entry.value_kind_word == u64(chosen_values.Entry_Kind.Text) {
			change = {name = field, kind = .Choose_Text, text = pr.plan_value_text(entry)}
		}
		if layer == .Locked {
			records.locks[records.locks_count] = change
			records.locks_count += 1
		} else {
			records.defaults[records.defaults_count] = change
			records.defaults_count += 1
		}
	}
	blocks: [plan_values.OWNER_CAPACITY]plan_values.Owner_Block
	at := 0
	for index in 0 ..< owner_count {
		records := &owners[index]
		defaults_written, defaults_problem := chosen_values.write_record({}, records.defaults[:records.defaults_count], bytes[at:])
		if defaults_problem != .None {
			return 0, false
		}
		defaults := bytes[at:][:defaults_written]
		at += defaults_written
		locks_written, locks_problem := chosen_values.write_record({}, records.locks[:records.locks_count], bytes[at:])
		if locks_problem != .None {
			return 0, false
		}
		blocks[index] = {owner = records.owner, defaults = defaults, locks = bytes[at:][:locks_written]}
		at += locks_written
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
		state.values_cause, state.values_problem = .Set_Too_Large, .None
		return .Values_Refused
	}
	problem, answered := state.values.replace(state.values.user, state.values_set[:written], step)
	state.values_problem = problem
	switch {
	case !answered:
		state.values_cause = .No_Answer
		return .Values_Refused
	case problem != .None:
		state.values_cause = .Refused
		return .Values_Refused
	}
	state.values_cause = .None
	return .None
}

// values_commit sends the step Committed of a generation that the store
// committed, at most VALUES_SEND_TRIES times with a pause between. A
// commit that the core never takes leaves it with the values before: the
// state records it, and the service logs it once (values_unreconciled).
values_commit :: proc "contextless" (state: ^Plans_State, principal: u64, generation: u64) {
	if principal != MACHINE_PRINCIPAL || state.values.commit == nil {
		return
	}
	for try in 0 ..< VALUES_SEND_TRIES {
		if try > 0 && state.roles.pause != nil {
			state.roles.pause(state.roles.user)
		}
		if taken, _ := state.values.commit(state.values.user, generation); taken {
			return
		}
	}
	state.values_cause = .Not_Committed
	state.values_unreconciled = true
	state.values_unreconciled_generation = generation
}

// values_resend gives the core the values of the generation in force again:
// after a refusal of the roles, at a compensation, and at the start of the
// service. A send that the core does not take is sent again, at most
// VALUES_SEND_TRIES times with a pause between; a set that it refuses for
// its content is refused again, so it is not sent twice. A send that never
// takes leaves the core with other values than the store: the state
// records it, and the service logs it once (values_unreconciled). taken is
// true when the core took the set.
values_resend :: proc "contextless" (state: ^Plans_State, principal: u64, plan: ^pr.Plan_Spec, generation: u64) -> (taken: bool) {
	for try in 0 ..< VALUES_SEND_TRIES {
		if try > 0 && state.roles.pause != nil {
			state.roles.pause(state.roles.user)
		}
		if values_give(state, principal, plan, generation, .Rollback) == .None {
			return true
		}
		if state.values_cause != .No_Answer {
			break
		}
	}
	state.values_unreconciled = true
	state.values_unreconciled_generation = generation
	return false
}

// plan_give sends the core the values, then the roles, of a generation. A
// refusal of the roles gives the core the values of the generation in
// force again (previous), so the two always name one generation.
plan_give :: proc "contextless" (state: ^Plans_State, principal: u64, plan: ^pr.Plan_Spec, generation: u64, step: rd.Plan_Roles_Step, previous: ^pr.Plan_Spec, previous_generation: u64) -> pr.Plan_Refusal {
	if refusal := values_give(state, principal, plan, generation, step); refusal != .None {
		return refusal
	}
	if refusal := roles_give(state, principal, plan, generation, step); refusal != .None {
		_ = values_resend(state, principal, previous, previous_generation)
		return refusal
	}
	return .None
}
