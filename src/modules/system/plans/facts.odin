package plans_service

// Log facts emitted by the delegated plans service.

FAILURE_FIELD_BYTES :: 96

// store, display and roles are 1 when the root service gave the private
// store, the way to the trusted display and the roles page, else 0: with no
// store no plan commits, with no display an apply is refused with
// Consent_Required, and with no roles page a plan of principal 0 that names
// a role is refused with Roles_Refused.
@(log_fact = "plans: ready, store {store}, display {display}, roles {roles}")
Service_Ready :: struct {
	store:   u64,
	display: u64,
	roles:   u64,
}

// The root service and the store of this service may name two generations:
// a reconciliation or a compensation failed. The next set of roles reads
// the root service first.
@(log_fact = "plans: the root service may hold the roles of generation {generation} and not those of the store: refusal {refusal_code}; the next set reconciles first")
Plan_Roles_Unreconciled :: struct {
	generation:   u64,
	refusal_code: u64,
}

// The root service refused the roles of a plan of principal 0: nothing was
// committed.
@(log_fact = "plans: the root service refused the roles of generation {generation} with refusal {refusal_code}")
Plan_Roles_Refused :: struct {
	generation:   u64,
	refusal_code: u64,
}

@(log_fact = "plans: {failure}")
Service_Failed :: struct {
	failure: [96]u8,
}

#assert(size_of(Service_Failed) == FAILURE_FIELD_BYTES)

@(log_fact = "plans: applied generation {generation} for principal {principal}")
Plan_Applied :: struct {
	generation: u64,
	principal:  u64,
}

@(log_fact = "plans: asked the trusted display with ticket {ticket} for principal {principal}")
Plan_Difference_Asked :: struct {
	ticket:    u64,
	principal: u64,
}

@(log_fact = "plans: rolled back to generation {generation} for principal {principal}")
Plan_Rolled_Back :: struct {
	generation: u64,
	principal:  u64,
}

@(log_fact = "plans: refused command for principal {principal} with refusal {refusal_code}")
Plan_Command_Refused :: struct {
	principal:    u64,
	refusal_code: u64,
}
