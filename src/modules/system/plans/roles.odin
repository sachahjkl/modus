// The port of the roles of the machine: the command Plan_Roles of the
// root ring (modus:contract/root_ring; src/md/features/declarations.md,
// "Apply, the difference and the rollback"). The core lends the roles page
// once; the service writes there the whole set of the role overrides of a
// generation, and the core takes it whole or refuses it whole.
package plans_service

import "base:intrinsics"
import "internal:plans/plans_core"
import "modus:contract/enum_word"
import rd "modus:contract/root_delegation"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:system"

// The bound of the wait for the completion of a Plan_Roles: the core
// answers at once, so only a core that hangs meets it.
ROLES_ANSWER_BOUND_MILLISECONDS :: system.TEST_HANG_BOUND_MILLISECONDS

// The roles page that the core lent, mapped.
roles_page: ^rd.Plan_Roles_Set

// roles_command sends one Plan_Roles and waits for its completion, within
// its bound. answered is false when the ring took no record or no
// completion came. argument is values[1]: the outcome of the step Loaded,
// else 0.
@(private = "file")
roles_command :: proc "contextless" (step: rd.Plan_Roles_Step, argument: u64 = 0) -> (completion: ring.Record, answered: bool) {
	if !root_requests_open() {
		return {}, false
	}
	tag := root_requests_tag_next()
	if !system.send(&root_requests.ring.commands, ring.Record{kind = u32(root_ring.Root_Command.Plan_Roles), tag = tag, values = {0 = u64(step), 1 = argument}}) {
		return {}, false
	}
	limit := system.time() + ROLES_ANSWER_BOUND_MILLISECONDS
	for {
		for record in system.receive(&root_requests.ring.completions) {
			if record.tag == tag {
				return record, true
			}
			roles_late_completion_close(record)
		}
		wait := system.wait_begin()
		system.wait_records(&wait, &root_requests.ring.completions)
		if system.wait_end(&wait, limit) >= limit {
			if step == .Page {
				plans_core.late_page_remember(&service_state.roles_late_pages, tag)
			}
			return {}, false
		}
	}
}

// roles_late_completion_close closes the handle of the roles page that a
// late completion of a command Page holds: the root service gave a new
// handle with each answer, and no later wait reads it.
@(private = "file")
roles_late_completion_close :: proc "contextless" (record: ring.Record) {
	if !plans_core.late_page_take(&service_state.roles_late_pages, record.tag) {
		return
	}
	if record.kind == u32(system.Status.Ok) && record.values[0] != 0 {
		system.close(system.Handle(record.values[0]))
	}
}

// roles_page_read asks the core for the roles page, and gives the serial
// and the generation of the set in force. The page is mapped once: each
// later answer gives a new handle of the same page, which is closed here.
@(private = "file")
roles_page_read :: proc "contextless" () -> (serial, generation: u64, ok: bool) {
	completion, answered := roles_command(.Page)
	if !answered || completion.kind != u32(system.Status.Ok) {
		return 0, 0, false
	}
	memory := system.Handle(completion.values[0])
	if roles_page != nil {
		system.close(memory)
		return completion.values[1], completion.values[2], true
	}
	address, status := system.memory_map(memory, {.Write})
	if status != .Ok {
		system.close(memory)
		return 0, 0, false
	}
	roles_page = (^rd.Plan_Roles_Set)(address)
	return completion.values[1], completion.values[2], true
}

// roles_read is the read of the port: the step Page.
@(private = "file")
roles_read :: proc "contextless" (user: rawptr) -> (serial, generation: u64, ok: bool) {
	return roles_page_read()
}

// roles_port_bind asks the core for the roles page, maps it, and gives the
// state the port with the serial and the generation of the set in force,
// then reconciles the core with the current generation of the store: a
// service that stopped after the core took a set and before the store
// committed it left them apart. At the start of the machine, this gives
// the core the roles of the current plan of principal 0. With no page, the
// port has no procedure: a plan of principal 0 that names a role is
// refused, and a plan with no role commits.
//
// Then it tells the core what it found, with the step Loaded: the core
// waits for it before the start policy (src/md/features/declarations.md,
// "The plan of principal 0 at the start").
roles_port_bind :: proc "contextless" (state: ^plans_core.Plans_State) -> bool {
	serial, generation, read := roles_page_read()
	if !read {
		roles_loaded_tell(.Core_Unread, 0)
		return false
	}
	plans_core.roles_port_bind(state, {replace = roles_replace, read = roles_read, serial = serial, generation = generation})
	outcome := plans_core.roles_start(state)
	switch outcome {
	case .None, .No_Plan, .Applied:
	case .Plan_Refused:
		_, record, _ := plans_core.current_plan(state, plans_core.MACHINE_PRINCIPAL)
		system.log_fact(.Warning, Plan_Roles_Image_Defaults{generation = record.generation, refusal_code = u64(state.roles_stored_refusal)})
	case .Store_Unread, .Core_Unread:
		system.log_fact(.Warning, Plan_Roles_Unreconciled{generation = generation, refusal_code = u64(state.roles_refusal)})
	}
	roles_loaded_tell(outcome, state.roles.generation)
	return true
}

// roles_loaded_tell sends the step Loaded with outcome, once at the start.
// A core that does not answer meets its own bound and starts the start
// policy with the roles in force.
@(private = "file")
roles_loaded_tell :: proc "contextless" (outcome: rd.Plan_Roles_Load_Outcome, generation: u64) {
	_, answered := roles_command(.Loaded, u64(outcome))
	system.log_fact(.Info, Plan_Roles_Loaded{outcome_code = u64(outcome), generation = generation, answered = answered ? 1 : 0})
}

// roles_compensation_tell writes the line of a compensation of the core that
// failed, once: the next set reconciles first.
roles_compensation_tell :: proc "contextless" (state: ^plans_core.Plans_State) {
	if !state.roles_compensation_failed {
		return
	}
	state.roles_compensation_failed = false
	system.log_fact(.Warning, Plan_Roles_Unreconciled{generation = state.roles.generation, refusal_code = u64(state.roles_refusal)})
}

// roles_replace writes a set in the roles page and asks the core to take it.
@(private = "file")
roles_replace :: proc "contextless" (user: rawptr, set: ^rd.Plan_Roles_Set, step: rd.Plan_Roles_Step) -> (refusal: rd.Plan_Roles_Refusal) {
	if roles_page == nil {
		return .Not_In_Image
	}
	intrinsics.mem_copy_non_overlapping(roles_page, set, size_of(rd.Plan_Roles_Set))
	completion, answered := roles_command(step)
	if !answered {
		system.log_fact(.Warning, Plan_Roles_Refused{generation = set.generation, refusal_code = u64(rd.Plan_Roles_Refusal.Stale_Serial)})
		return .Stale_Serial
	}
	if completion.kind == u32(system.Status.Ok) {
		return .None
	}
	// The error record names the refusal as the value found, values[6]. A
	// word that names no refusal, or None, is a refusal still: the core did
	// not take the set.
	refusal = .Stale_Serial
	if read, known := enum_word.member_of_word(rd.Plan_Roles_Refusal, completion.values[6]); known && read != .None {
		refusal = read
	}
	system.log_fact(.Warning, Plan_Roles_Refused{generation = set.generation, refusal_code = u64(refusal)})
	return refusal
}
