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
	name_is_a_start_policy:    bool, // The start grant set of the name holds Start_Policy: only the root service starts it.
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

// The starts of one name that a start policy from the disk asked for. A
// place with no start is free.
Name_Count :: struct {
	name:        [32]u8,
	name_length: int,
	starts:      u64,
}

Name_Counts :: [RESTARTED_NAME_CAPACITY]Name_Count

// restart_check is the decision that the root service calls for each Start
// of a start policy: the place of the count of the name (a free place for a
// new name; nil when each place holds another name), then restart_refusal
// and its record. The caller adds one start to the place after a start that
// ran, and only then. A refusal changes no count.
restart_check :: proc "contextless" (counts: ^Name_Counts, from_disk: bool, name: string) -> (status: op.Status, refusal: [7]u64, place: ^Name_Count) {
	if !from_disk {
		return .Ok, {}, nil
	}
	for &item in counts {
		if item.starts > 0 && string(item.name[:item.name_length]) == name {
			place = &item
			break
		}
	}
	if place == nil {
		for &item in counts {
			if item.starts == 0 {
				place = &item
				break
			}
		}
	}
	earlier: u64 = place != nil ? place.starts : 0
	status = restart_refusal(true, earlier, place == nil)
	if status != .Ok {
		return status, restart_record(earlier, place == nil), nil
	}
	if place.starts == 0 {
		place^ = {}
		place.name_length = copy(place.name[:len(place.name) - 1], name)
	}
	return .Ok, {}, place
}

// What the root service does with a Start of a start policy before any
// start: its refusal, and whether it closes the numbers that its list lent.
Start_Step :: struct {
	status:     op.Status, // Ok: the start goes on.
	refusal:    [7]u64, // The error record of a refusal.
	lent_close: bool, // A refused Start with a list: each number that the list lent is closed, as on each refusal of a list.
	counted:    ^Name_Count, // Ok: the count of the name, which the caller adds one start to after a start that ran; nil for a start policy of the image.
}

// start_step decides a Start of a start policy before any start, in this
// order: a list for a name that the root service starts by a procedure of
// its own (Unsupported of the unit Wiring_Rows, argument 2: the word of the
// list), start_refusal, then restart_check. A refusal changes no count.
start_step :: proc "contextless" (listed: bool, facts: Start_Facts, counts: ^Name_Counts, from_disk: bool, name: string) -> Start_Step {
	kind := u32(root_ring.Root_Command.Start)
	if listed && start_list.root_procedure_of(name) != .None {
		return {status = .Bad_Operation, refusal = errors.ring_fail(kind, .Unsupported, .Wiring_Rows, 2), lent_close = true}
	}
	if status := start_refusal(facts); status != .Ok {
		return {status = status, refusal = start_record(status, facts), lent_close = listed}
	}
	status, refusal, place := restart_check(counts, from_disk, name)
	if status != .Ok {
		return {status = status, refusal = refusal, lent_close = listed}
	}
	return {status = .Ok, counted = place}
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

// choice_form_refusal checks the form of a Start_Policy_Choice: a nickname
// of no byte ends the choice and names no file, so a hash with it is
// refused with Bad_Value of the argument 2 (the hash), and the end of the
// choice does not run. hash_is_zero: values[0..3] are all zero.
choice_form_refusal :: proc "contextless" (nickname_is_empty: bool, hash_is_zero: bool) -> (status: op.Status, refusal: [7]u64) {
	if nickname_is_empty && !hash_is_zero {
		return .Bad_Operation, errors.ring_fail(u32(root_ring.Root_Command.Start_Policy_Choice), .Bad_Value, .None, 2)
	}
	return .Ok, {}
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
// runs, and only while that start policy has not said it yet. Each other
// one is refused with Exists (unit Processes) and changes nothing. A
// rescue that starts after the machine was usable runs in the stage
// Running again, so its own Machine_Usable is taken: the machine was
// usable by the policy that stopped, not by the rescue.
usable_decision :: proc "contextless" (sender_runs: bool, stage: Stage) -> (status: op.Status, refusal: [7]u64) {
	if !sender_runs || stage != .Running {
		return .Bad_State, errors.ring_fail(u32(root_ring.Root_Command.Machine_Usable), .Exists, .Processes)
	}
	return .Ok, {}
}

// What the root service does at the stop of the start policy that it
// waits for.
Stop_Action :: enum u8 {
	Nothing,   // The root service asked for the stop, or no policy is waited for.
	Rescue,    // Stop each process that the policy asked for, then start the rescue start policy.
	No_Policy, // The rescue itself stopped: the machine runs with no start policy.
}

// stop_action decides the stop of the start policy that the root service
// waits for. A stop before Machine_Usable and a stop after it give the
// same escalation: the default or chosen policy gives way to the rescue,
// and a stop of the rescue leaves the machine with no start policy, so
// rows that a stopped policy asked for never run on with no starter.
stop_action :: proc "contextless" (stage: Stage, rescue_runs: bool) -> Stop_Action {
	switch stage {
	case .None, .Stopping, .No_Policy:
		return .Nothing
	case .Running, .Usable:
		return rescue_runs ? .No_Policy : .Rescue
	}
	return .Nothing
}

// screen_of_memory_of_start decides values[6] of a Start: the size of a
// screen of memory (src/md/features/screen_of_memory.md). 0 is no screen
// of memory. Any other word passes only from a start policy, for the row
// display, on a machine with no screen, and inside the bounds of the
// contract memory_screen: else ok is false, and the Start is refused.
screen_of_memory_of_start :: proc "contextless" (word: u64, from_start_policy: bool, name: string, machine_has_screen: bool) -> (width, height: u32, ok: bool) {
	width, height, ok = root_ring.screen_of_memory_of_word(word)
	if !ok || word == 0 {
		return
	}
	if !from_start_policy || start_list.root_procedure_of(name) != .Display || machine_has_screen {
		return 0, 0, false
	}
	return
}
