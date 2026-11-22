package root

// The plan of principal 0 at the start of the machine
// (src/md/features/declarations.md, "The plan of principal 0 at the
// start").
//
// After the read of the choice of principal 0 and before the start policy,
// this service starts the holder of Plans. That holder reads the current
// plan of principal 0 from its own private store, gives its roles with
// Plan_Roles (plan_roles.odin), and says Loaded. The start policy then
// starts with those roles, so the holders that principal 0 applied hold
// from the first start. This service never reads the store itself.
//
// The wait ends at Loaded, at the stop of the holder, or at the hang
// bound. A rescue, a machine with no data disk, and a boot image with no
// holder of Plans or of Storage do not wait: the roles of the image hold.

import "internal:root/role_policy"
import rd "modus:contract/root_delegation"
import "modus:disk_process"
import "modus:system"

plan_at_start: role_policy.Plan_At_Start

// The choice of principal 0 that the start policy waits with: a copy, as
// the table can change during the wait.
plan_at_start_chosen_row: disk_process.Grant_Row
plan_at_start_chosen: bool

// The holder said Loaded: the next step starts the start policy, out of
// the answer of the root ring.
plan_at_start_policy_due: bool

// plan_at_start_begin keeps the choice of principal 0, then starts the
// holder of Plans and waits, or starts the start policy at once when the
// machine cannot hold a plan.
plan_at_start_begin :: proc "contextless" (chosen: ^disk_process.Grant_Row) {
	plan_at_start_chosen = chosen != nil
	if chosen != nil {
		plan_at_start_chosen_row = chosen^
	}
	plans_name := role_holder_name(.Plans)
	storage_name := role_holder_name(.Storage)
	facts := role_policy.Plan_At_Start_Facts {
		rescue         = start_policy_request != .Chosen,
		data_disk      = .Data_Disk in machine_parts,
		plans_module   = plans_name != "" && len(system.image_find(image, plans_name)) != 0,
		storage_module = storage_name != "" && len(system.image_find(image, storage_name)) != 0,
	}
	skip, begun := role_policy.plan_at_start_begin(&plan_at_start, facts, system.time(), START_POLICY_HANG_BOUND_MILLISECONDS)
	if !begun {
		return
	}
	switch skip {
	case .None:
	case .Rescue:
		system.log_fact(.Info, Plan_At_Start_Unread_Rescue{})
	case .No_Data_Disk:
		system.log_fact(.Info, Plan_At_Start_Unread_No_Disk{})
	case .No_Plans_Module:
		system.log_fact(.Info, Plan_At_Start_Unread_No_Plans_Module{})
	case .No_Storage_Module:
		system.log_fact(.Info, Plan_At_Start_Unread_No_Storage_Module{})
	}
	if skip != .None {
		plan_at_start_end()
		return
	}
	show("the root service reads the plan of principal 0", .Running, .Root)
	if find(plans_name) == nil {
		if status := start(plans_name); status != .Ok {
			system.log_fact(.Warning, Plan_At_Start_Start_Failed{status = status})
			role_policy.plan_at_start_abandon(&plan_at_start)
			plan_at_start_end()
			return
		}
	}
	system.log_fact(.Info, Plan_At_Start_Waiting{bound = START_POLICY_HANG_BOUND_MILLISECONDS})
}

// plan_at_start_without_window says if a start is the holder of Plans that
// the wait starts: no compositor runs yet, and a service shows no window.
plan_at_start_without_window :: proc "contextless" (name: string) -> bool {
	return plan_at_start.stage == .Waiting && name == role_holder_name(.Plans)
}

// plan_at_start_step runs after each reap: Loaded, the stop of the holder,
// or the hang bound starts the start policy.
plan_at_start_step :: proc "contextless" () {
	if plan_at_start_policy_due {
		plan_at_start_policy_due = false
		plan_at_start_end()
		return
	}
	switch role_policy.plan_at_start_check(&plan_at_start, system.time(), find(role_holder_name(.Plans)) != nil) {
	case .None:
	case .Holder_Stopped:
		system.log_fact(.Warning, Plan_At_Start_Holder_Stopped{})
		plan_at_start_end()
	case .Late:
		system.log_fact(.Warning, Plan_At_Start_Late{bound = START_POLICY_HANG_BOUND_MILLISECONDS})
		plan_at_start_end()
	}
}

// plan_at_start_wake gives the time at which the loop must run the step
// with no event.
plan_at_start_wake :: proc "contextless" () -> u64 {
	if plan_at_start_policy_due {
		return 0
	}
	return role_policy.plan_at_start_wake(&plan_at_start, system.WAIT_FOREVER)
}

// plan_at_start_loaded takes the step Loaded of the holder of Plans. Out of
// the wait at the start it changes nothing: a holder that starts later says
// Loaded too.
plan_at_start_loaded :: proc "contextless" (outcome: rd.Plan_Roles_Load_Outcome) {
	if !role_policy.plan_at_start_loaded(&plan_at_start, outcome) {
		return
	}
	switch outcome {
	case .None:
	case .Applied:
		overrides: u64
		for length in role_override_names.lengths {
			overrides += length != 0 ? 1 : 0
		}
		system.log_fact(.Info, Plan_At_Start_Applied{generation = role_override_names.generation, serial = role_override_names.serial, overrides = overrides})
	case .No_Plan:
		system.log_fact(.Info, Plan_At_Start_No_Plan{})
	case .Plan_Refused:
		system.log_fact(.Warning, Plan_At_Start_Plan_Refused{})
	case .Store_Unread:
		system.log_fact(.Warning, Plan_At_Start_Store_Unread{})
	case .Core_Unread:
		system.log_fact(.Warning, Plan_At_Start_Core_Unread{})
	}
	plan_at_start_policy_due = true
}

// plan_at_start_end starts the start policy with the choice of principal 0
// that the read kept.
@(private = "file")
plan_at_start_end :: proc "contextless" () {
	chosen: ^disk_process.Grant_Row
	if plan_at_start_chosen {
		chosen = &plan_at_start_chosen_row
	}
	start_policy_after_the_choice(chosen)
}
