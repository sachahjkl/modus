// Delegated plans service implementing Role.Plans
// (src/md/features/declarations.md, "The services of the declarations").
//
// Computes plan differences against each principal's current applied plan,
// shows each difference on the trusted display, commits an accepted
// generation to its private store, and rolls back without writing a new
// plan record. The roles of the plan of principal 0 go to the root service
// core with the command Plan_Roles before each commit (roles.odin).
package plans_service

import "internal:plans/plans_core"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/value_kinds"
import "modus:storage_port"
import "modus:system"

// Working memory budget for the freestanding plans service process and its
// fixed-capacity per-principal applied_plans tables.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 512, processes = 1, threads = 1}

// Status record returned by the status() export.
Plans_Status :: struct {
	total_diffs:     i64,
	total_applies:   i64,
	total_rollbacks: i64,
	total_refusals:  i64,
}

// Package-level BSS state so large plan tables never live on the stack.
service_state: plans_core.Plans_State
service_display: plans_core.Trusted_Display_Port

@(private = "file")
fail :: proc "contextless" (text: string) -> ! {
	system.log_fact(.Error, Service_Failed{failure = value_kinds.text_field(text, FAILURE_FIELD_BYTES)})
	system.stop(.Failed)
}

// status writes aggregate plans service counters into out.
@(export)
status :: proc "c" (out: ^Plans_Status, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if out == nil {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Address, .None, 1)
	}
	if !service_state.initialized {
		return call_outcome.fail(error, .Wrong_State, .State, .Requests)
	}
	out^ = {
		total_diffs     = i64(service_state.counters.total_diffs),
		total_applies   = i64(service_state.counters.total_applies),
		total_rollbacks = i64(service_state.counters.total_rollbacks),
		total_refusals  = i64(service_state.counters.total_refusals),
	}
	return .Succeeded, 0
}

// current_generation returns the active applied plan generation of the
// principal of the caller, or 0 when none. A caller names no principal:
// it reads only its own plans (exports.odin, caller_principal).
@(export)
current_generation :: proc "c" (error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	principal, failure, allowed := caller_principal(error)
	if !allowed {
		return failure, 0
	}
	_, rec, found := plans_core.current_plan(&service_state, principal)
	if !found {
		return .Succeeded, 0
	}
	return .Succeeded, i64(min(rec.generation, u64(max(i64))))
}

// diff_count returns the plan differences that the service computed.
@(export)
diff_count :: proc "c" (error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !service_state.initialized {
		return call_outcome.fail(error, .Wrong_State, .State, .Requests)
	}
	return .Succeeded, i64(service_state.counters.total_diffs)
}

// apply_generation returns the newest generation that an apply committed for
// the principal of the caller, or 0 when none: the next apply commits the
// generation after it, even after a rollback.
@(export)
apply_generation :: proc "c" (error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	principal, failure, allowed := caller_principal(error)
	if !allowed {
		return failure, 0
	}
	return .Succeeded, i64(min(plans_core.highest_generation(&service_state, principal), u64(max(i64))))
}

// rollback_generation returns the generation that a rollback of the
// principal of the caller selects, and rolls nothing back. With no earlier
// generation, it fails with the kind Absent and the unit Versions; found is
// the refusal.
@(export)
rollback_generation :: proc "c" (error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	principal, failure, allowed := caller_principal(error)
	if !allowed {
		return failure, 0
	}
	selected, refusal := plans_core.rollback_target(&service_state, principal)
	if refusal != .None {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Versions, 0, 0, 0, i64(refusal))
	}
	return .Succeeded, i64(min(selected.generation, u64(max(i64))))
}

// entry binds the private store, the way to the trusted display and the
// roles page of the core, then serves the exports until stopped.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	export_service, export_ok := system.service_open(ctx)
	if !export_ok {
		fail("no service ring")
	}
	store_port, store_open := storage_port.bind(ctx)
	// The service checks no answer of the powerbox: the trusted display of
	// the role Display shows each difference (ports.odin).
	plans_core.state_init(&service_state, 0, store_port)
	root_requests_bind(ctx)
	service_display = display_port_bind(ctx)
	roles_open := roles_port_bind(&service_state)
	system.log_fact(.Info, Service_Ready{store = store_open ? 1 : 0, display = service_display.ask != nil ? 1 : 0, roles = roles_open ? 1 : 0})

	for {
		wait := system.wait_begin()
		system.service_run(&export_service)
		system.service_wait(&wait, &export_service)
		system.wait_end(&wait)
	}
}
