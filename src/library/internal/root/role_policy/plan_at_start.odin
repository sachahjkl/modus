package role_policy

// The read of the plan of principal 0 at the start of the machine
// (src/md/features/declarations.md, "The plan of principal 0 at the
// start"). The core never reads the store: it starts the holder of Plans,
// which reads its own store and gives the roles of the current plan with
// Plan_Roles, then says Loaded. The core starts the start policy after
// Loaded, after the stop of that holder, or at the hang bound, whichever
// comes first. A machine that cannot hold a plan does not wait at all.

import rd "modus:contract/root_delegation"

// Why the core reads no plan before the start policy, or None when it
// reads one.
Plan_At_Start_Skip :: enum u8 {
	None,
	// The boot record asks for the rescue start policy: it runs with the
	// roles of the image, as a plan can be what broke the start.
	Rescue,
	No_Data_Disk, // No store can hold a plan.
	No_Plans_Module, // The boot image has no holder of Plans.
	No_Storage_Module, // The boot image has no holder of Storage.
}

// What the core knows of the machine before the start policy.
Plan_At_Start_Facts :: struct {
	rescue:         bool,
	data_disk:      bool,
	plans_module:   bool,
	storage_module: bool,
}

// The stages of the read.
Plan_At_Start_Stage :: enum u8 {
	Before, // No read began.
	Waiting, // The holder of Plans runs, and the core waits for Loaded.
	Ended, // The start policy can start.
}

// Why a check ended the wait, or None when it did not: no wait runs, or
// it goes on. Loaded ends a wait as an event (plan_at_start_loaded).
Plan_At_Start_End :: enum u8 {
	None,
	Holder_Stopped, // The holder stopped before Loaded.
	Late, // The hang bound passed.
}

Plan_At_Start :: struct {
	stage:    Plan_At_Start_Stage,
	deadline: u64,
	outcome:  rd.Plan_Roles_Load_Outcome,
}

// plan_at_start_skip gives why no plan is read before the start policy,
// in the order of the checks: a rescue first, then the parts that a read
// needs.
plan_at_start_skip :: proc "contextless" (facts: Plan_At_Start_Facts) -> Plan_At_Start_Skip {
	if facts.rescue {
		return .Rescue
	}
	if !facts.data_disk {
		return .No_Data_Disk
	}
	if !facts.plans_module {
		return .No_Plans_Module
	}
	if !facts.storage_module {
		return .No_Storage_Module
	}
	return .None
}

// plan_at_start_begin begins the read once: a read that began is refused
// (false). With a reason to skip, the read ends at once and sets no
// deadline; the caller then starts the start policy. Else the caller
// starts the holder of Plans, and the core waits until now + bound.
plan_at_start_begin :: proc "contextless" (read: ^Plan_At_Start, facts: Plan_At_Start_Facts, now, bound: u64) -> (skip: Plan_At_Start_Skip, begun: bool) {
	if read.stage != .Before {
		return .None, false
	}
	skip = plan_at_start_skip(facts)
	if skip != .None {
		read.stage = .Ended
		return skip, true
	}
	read.stage = .Waiting
	read.deadline = bound > max(u64) - now ? max(u64) : now + bound
	return .None, true
}

// plan_at_start_abandon ends a wait whose holder did not start.
plan_at_start_abandon :: proc "contextless" (read: ^Plan_At_Start) {
	if read.stage == .Waiting {
		read.stage = .Ended
	}
}

// plan_at_start_loaded takes the Loaded of the holder of Plans. taken is
// false when no wait runs: a holder that starts later, at the first
// connection or again after a stop, says Loaded too, and it changes no
// start.
plan_at_start_loaded :: proc "contextless" (read: ^Plan_At_Start, outcome: rd.Plan_Roles_Load_Outcome) -> (taken: bool) {
	if read.stage != .Waiting || outcome == .None {
		return false
	}
	read.stage = .Ended
	read.outcome = outcome
	return true
}

// plan_at_start_check runs after each pass of the loop: a holder that
// stopped, or a deadline that passed, ends the wait.
plan_at_start_check :: proc "contextless" (read: ^Plan_At_Start, now: u64, holder_running: bool) -> Plan_At_Start_End {
	if read.stage != .Waiting {
		return .None
	}
	if !holder_running {
		read.stage = .Ended
		return .Holder_Stopped
	}
	if now >= read.deadline {
		read.stage = .Ended
		return .Late
	}
	return .None
}

// plan_at_start_wake gives the time at which the loop must run the check
// with no event.
plan_at_start_wake :: proc "contextless" (read: ^Plan_At_Start, forever: u64) -> u64 {
	return read.stage == .Waiting ? read.deadline : forever
}
