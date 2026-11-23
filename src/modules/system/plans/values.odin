// The port of the values of the machine: the command Plan_Values of the
// root ring (modus:contract/root_ring; src/md/features/module_settings.md,
// "Plan records"). The core lends the values pages once; the service
// writes there the whole set of the values of a generation, and the core
// takes it whole or refuses it whole.
package plans_service

import "base:intrinsics"
import "internal:plans/plans_core"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/plan_values"
import rd "modus:contract/root_delegation"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:system"

// The values pages that the core lent, mapped.
values_pages: [^]u8

// values_command sends one Plan_Values and waits for its completion within
// the answer bound. answered is false when the ring took no record or no
// completion came.
@(private = "file")
values_command :: proc "contextless" (step: rd.Plan_Roles_Step, generation: u64 = 0) -> (completion: ring.Record, answered: bool) {
	if !root_requests_open() {
		return {}, false
	}
	tag := root_requests_tag_next()
	if !system.send(&root_requests.ring.commands, ring.Record{kind = u32(root_ring.Root_Command.Plan_Values), tag = tag, values = {0 = u64(step), 1 = generation}}) {
		return {}, false
	}
	limit := system.time() + ROLES_ANSWER_BOUND_MILLISECONDS
	for {
		for record in system.receive(&root_requests.ring.completions) {
			if record.tag == tag {
				return record, true
			}
		}
		wait := system.wait_begin()
		system.wait_records(&wait, &root_requests.ring.completions)
		if system.wait_end(&wait, limit) >= limit {
			return {}, false
		}
	}
}

// values_pages_map asks the core for the values pages once and maps them.
@(private = "file")
values_pages_map :: proc "contextless" () -> bool {
	if values_pages != nil {
		return true
	}
	completion, answered := values_command(.Page)
	if !answered || completion.kind != u32(system.Status.Ok) {
		return false
	}
	memory := system.Handle(completion.values[0])
	address, status := system.memory_map(memory, {.Write})
	if status != .Ok {
		system.close(memory)
		return false
	}
	values_pages = ([^]u8)(address)
	return true
}

// values_replace is the replace of the port: the set on the pages, then
// Apply or Rollback. The refusal of the core is the value found of its
// error record; a refusal that names no problem of the set (no pages, a
// state) is no answer, and the send is tried again.
@(private = "file")
values_replace :: proc "contextless" (user: rawptr, set: []u8, step: rd.Plan_Roles_Step) -> (problem: plan_values.Set_Problem, answered: bool) {
	if !values_pages_map() || len(set) > plan_values.SET_SIZE {
		return .None, false
	}
	intrinsics.mem_zero(values_pages, plan_values.SET_SIZE)
	intrinsics.mem_copy_non_overlapping(values_pages, raw_data(set), len(set))
	completion, completion_answered := values_command(step)
	if !completion_answered {
		return .None, false
	}
	if completion.kind == u32(system.Status.Ok) {
		return .None, true
	}
	// The core names its refusal as the value found; another refusal (no
	// pages, a state) is no refusal of the content.
	found, known := enum_word.member_of_word(plan_values.Set_Problem, u64(errors.completion_record(completion.values).found))
	if !known || found == .None {
		return .None, false
	}
	return found, true
}

// values_commit_send is the commit of the port: the step Committed of a
// generation that the store committed.
@(private = "file")
values_commit_send :: proc "contextless" (user: rawptr, generation: u64) -> (taken: bool, answered: bool) {
	completion, completion_answered := values_command(.Committed, generation)
	if !completion_answered {
		return false, false
	}
	return completion.kind == u32(system.Status.Ok), true
}

// values_port_bind gives the state the port. With no pages, the port has
// no procedure: a plan of principal 0 with a Value entry is refused, and a
// plan with none commits.
values_port_bind :: proc "contextless" (state: ^plans_core.Plans_State) {
	if !values_pages_map() {
		return
	}
	state.values = {replace = values_replace, commit = values_commit_send}
}
