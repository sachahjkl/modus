// The decisions of the root service on the commands of a start policy: the
// refusals that the grant Start_Policy gets past the table of the senders.
// A pure part, which the host tests (src/md/features/start_policy.md).
package start_policy_rules

import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/root_ring"

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

// usable_decision decides a Machine_Usable: only from the start policy that
// runs, and only while the machine is not usable yet. Each other one is
// refused with Exists (unit Processes) and changes nothing.
usable_decision :: proc "contextless" (sender_runs: bool, stage: Stage) -> (status: op.Status, refusal: [7]u64) {
	if !sender_runs || stage != .Running {
		return .Bad_State, errors.ring_fail(u32(root_ring.Root_Command.Machine_Usable), .Exists, .Processes)
	}
	return .Ok, {}
}
