// The decisions of the root service on the commands of a start policy: the
// refusals that the grant Start_Policy gets past the table of the senders.
// A pure part, which the host tests (src/md/features/start_policy.md).
package start_policy_rules

import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/root_ring"
import "modus:contract/start_list"

// What the root service waits for of the start policy.
Stage :: enum u8 {
	None,      // No start policy started yet.
	Running,   // A start policy runs, and the machine is not usable yet: its stop or the hang bound starts the rescue.
	Stopping,  // The processes of a failed start policy stop: the rescue starts when each one is gone, or at the hang bound.
	Usable,    // The start policy that runs sent Machine_Usable.
	No_Policy, // The rescue start policy failed too: no start policy runs, and the root service starts nothing more by itself.
}

// The facts of a Start from a holder of the grant Start_Policy, as the
// root service reads them before it starts anything.
Start_Facts :: struct {
	sender_runs:               bool, // The sender is the start policy that the root service waits for.
	name_runs:                 bool, // A process of the name runs.
	name_is_a_start_policy:    bool, // The role of the name holds Start_Policy: only the root service starts it.
	name_is_of_a_test_machine: bool, // shortage or operation_fuzzing, which take the machine.
	name_in_image:             bool, // The boot image holds a module of the name.
}

// start_refusal gives the status of a Start of a start policy that the
// facts refuse, in the order of the checks, or Ok: a start policy is never
// started by a start policy, a start policy that no longer runs starts
// nothing, a name that runs does not start twice, and a process of a test
// machine starts only from the image that holds it, as its procedure
// takes the budget of the machine and can stop it.
start_refusal :: proc "contextless" (facts: Start_Facts) -> op.Status {
	if facts.name_is_a_start_policy {
		return .Bad_Operation
	}
	if !facts.sender_runs || facts.name_runs {
		return .Bad_State
	}
	if facts.name_is_of_a_test_machine && !facts.name_in_image {
		return .Bad_Operation
	}
	return .Ok
}

// start_record gives the error record of a Start of a start policy that
// failed with a status: Reserved for a start policy, Absent (unit Modules)
// for a name that the image does not hold, Exists (unit Processes) for a
// name that runs, Absent (unit Processes) for a sender that no longer
// runs, and else Refused with the status.
start_record :: proc "contextless" (status: op.Status, facts: Start_Facts) -> [7]u64 {
	kind := u32(root_ring.Root_Command.Start)
	switch {
	case status == .Bad_Operation && facts.name_is_a_start_policy:
		return errors.ring_fail(kind, .Reserved, .None, 1)
	case status == .Bad_Operation && !facts.name_in_image:
		return errors.ring_fail(kind, .Absent, .Modules, 1)
	case status == .Bad_State && !facts.sender_runs:
		return errors.ring_fail(kind, .Absent, .Processes)
	case status == .Bad_State && facts.name_runs:
		return errors.ring_fail(kind, .Exists, .Processes, 1)
	}
	return errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(status))
}

// stop_record is the error record of each Stop of a start policy that is
// refused: Absent, whether a process of the name runs or not, as a start
// policy learns nothing of a process that it did not ask for.
stop_record :: proc "contextless" () -> [7]u64 {
	return errors.ring_fail(u32(root_ring.Root_Command.Stop), .Absent, .Processes, 1)
}

// The names whose starts the root service counts for a start policy from
// the disk: as many as a start list has rows.
RESTARTED_NAME_CAPACITY :: start_list.ROW_CAPACITY

// restart_refusal decides a Start of a start policy by the count of the
// earlier starts of the name that it asked for: each one after the first
// is a restart. A start policy from the disk gets the bound of a start row,
// start_list.RESTART_LIMIT restarts for the whole run of the machine, so
// no clock decides it; a name past the table of the counts is refused too.
// The start policies of the boot image are never refused here: their rows
// carry their own bound.
restart_refusal :: proc "contextless" (from_disk: bool, earlier_starts: u64, table_full: bool) -> op.Status {
	if !from_disk {
		return .Ok
	}
	if table_full || earlier_starts > start_list.RESTART_LIMIT {
		return .No_Budget
	}
	return .Ok
}

// restart_record is the error record of a Start that restart_refusal
// refused: Over_Limit with the restarts asked and the bound, or Full of the
// table of the counts.
restart_record :: proc "contextless" (earlier_starts: u64, table_full: bool) -> [7]u64 {
	kind := u32(root_ring.Root_Command.Start)
	if table_full {
		return errors.ring_fail(kind, .Full, .Records, 1, 0, RESTARTED_NAME_CAPACITY)
	}
	return errors.ring_fail(kind, .Over_Limit, .None, 1, i64(min(earlier_starts, 1 << 62)), start_list.RESTART_LIMIT)
}

// Why the root service refuses a choice of a start policy before any change
// of the disk grant table of principal 0.
Choice_Refusal :: enum u8 {
	None,
	// The caller acts for a named principal: only principal 0 chooses the
	// start policy of the machine.
	Named_Principal,
	// The machine has no record of its machine key: the table lasts until
	// the machine stops, so the choice would never be read.
	No_Machine_Key,
	// The machine key opens with a passphrase: the root service reads the
	// choice before a passphrase can be typed.
	Passphrase,
}

// The facts of a choice, as the root service reads them.
Choice_Facts :: struct {
	caller_is_principal_0:          bool,
	machine_key_record:             bool, // The table of principal 0 has a key, or waits for one.
	machine_key_without_passphrase: bool, // That record opens with no passphrase: sealed by the TPM alone.
}

// choice_refusal decides a choice of a start policy, in the order of the
// checks. A refusal changes nothing.
choice_refusal :: proc "contextless" (facts: Choice_Facts) -> Choice_Refusal {
	if !facts.caller_is_principal_0 {
		return .Named_Principal
	}
	if !facts.machine_key_record {
		return .No_Machine_Key
	}
	if !facts.machine_key_without_passphrase {
		return .Passphrase
	}
	return .None
}

// choice_record is the error record of a refused choice: Absent of the
// principals for a named principal, Refused of the principals for a machine
// key that does not open with no passphrase.
choice_record :: proc "contextless" (refusal: Choice_Refusal) -> [7]u64 {
	kind := u32(root_ring.Root_Command.Start_Policy_Choice)
	switch refusal {
	case .None:
		return {}
	case .Named_Principal:
		return errors.ring_fail(kind, .Absent, .Principals)
	case .No_Machine_Key, .Passphrase:
		return errors.ring_fail(kind, .Refused, .Principals)
	}
	return {}
}

// usable_decision decides a Machine_Usable: only from the start policy that
// runs, and only while the machine is not usable yet. Each other one is
// refused with Exists (unit Processes) and changes nothing.
usable_decision :: proc "contextless" (sender_runs: bool, stage: Stage) -> (status: op.Status, refusal: [7]u64) {
	if !sender_runs || stage != .Running {
		return .Bad_State, errors.ring_fail(u32(root_ring.Root_Command.Machine_Usable), .Exists, .Processes)
	}
	return .Ok, {}
}
