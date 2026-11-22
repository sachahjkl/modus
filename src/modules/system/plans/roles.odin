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
// completion came.
@(private = "file")
roles_command :: proc "contextless" (step: rd.Plan_Roles_Step) -> (completion: ring.Record, answered: bool) {
	if !root_requests_open() {
		return {}, false
	}
	tag := root_requests_tag_next()
	if !system.send(&root_requests.ring.commands, ring.Record{kind = u32(root_ring.Root_Command.Plan_Roles), tag = tag, values = {0 = u64(step)}}) {
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

// roles_port_bind asks the core for the roles page, maps it, and gives the
// state the port with the serial of the set in force. With no page, the
// port has no procedure: a plan of principal 0 that names a role is
// refused, and a plan with no role commits.
roles_port_bind :: proc "contextless" (state: ^plans_core.Plans_State) -> bool {
	completion, answered := roles_command(.Page)
	if !answered || completion.kind != u32(system.Status.Ok) {
		return false
	}
	memory := system.Handle(completion.values[0])
	address, status := system.memory_map(memory, {.Write})
	if status != .Ok {
		system.close(memory)
		return false
	}
	roles_page = (^rd.Plan_Roles_Set)(address)
	plans_core.roles_port_bind(state, {replace = roles_replace, serial = completion.values[1]})
	return true
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
