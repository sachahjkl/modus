// The decisions of the root service on the commands of a start policy: the
// refusals that the grant Start_Policy gets past the table of the senders.
// A pure part, which the host tests (src/md/features/start_policy.md).
package start_policy_rules

import "modus:contract/call_outcome"
import "modus:contract/errors"
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

// start_refusal decides a Start of a start policy by its facts, in the
// order of the checks, and gives the outcome and the error record of a
// refusal, or Succeeded: a start policy is never started by a start policy
// (Grant_Or_Right_Missing, Reserved), a start policy that no longer runs
// starts nothing (Nothing_Has_That_Name, Absent of the processes), a name
// that runs does not start twice (Name_Already_Taken, Exists of the
// processes), and a process of a test machine starts only from the image
// that holds it (Nothing_Has_That_Name, Absent of the modules), as its
// procedure takes the budget of the machine and can stop it.
start_refusal :: proc "contextless" (facts: Start_Facts) -> (outcome: call_outcome.Call_Outcome, refusal: [7]u64) {
	kind := u32(root_ring.Root_Command.Start)
	switch {
	case facts.name_is_a_start_policy:
		return .Grant_Or_Right_Missing, errors.ring_fail(kind, .Reserved, .None, 1)
	case !facts.sender_runs:
		return .Nothing_Has_That_Name, errors.ring_fail(kind, .Absent, .Processes)
	case facts.name_runs:
		return .Name_Already_Taken, errors.ring_fail(kind, .Exists, .Processes, 1)
	case facts.name_is_of_a_test_machine && !facts.name_in_image:
		return .Nothing_Has_That_Name, errors.ring_fail(kind, .Absent, .Modules, 1)
	}
	return .Succeeded, {}
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
restart_refusal :: proc "contextless" (from_disk: bool, earlier_starts: u64, table_full: bool) -> call_outcome.Call_Outcome {
	if !from_disk {
		return .Succeeded
	}
	if table_full || earlier_starts > start_list.RESTART_LIMIT {
		return .Budget_Or_Capacity_Exhausted
	}
	return .Succeeded
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
restart_check :: proc "contextless" (counts: ^Name_Counts, from_disk: bool, name: string) -> (outcome: call_outcome.Call_Outcome, refusal: [7]u64, place: ^Name_Count) {
	if !from_disk {
		return .Succeeded, {}, nil
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
	outcome = restart_refusal(true, earlier, place == nil)
	if outcome != .Succeeded {
		return outcome, restart_record(earlier, place == nil), nil
	}
	if place.starts == 0 {
		place^ = {}
		place.name_length = copy(place.name[:len(place.name) - 1], name)
	}
	return .Succeeded, {}, place
}

// What the root service does with a Start of a start policy before any
// start: its refusal, and whether it closes the numbers that its list lent.
Start_Step :: struct {
	outcome:    call_outcome.Call_Outcome, // Succeeded: the start goes on.
	refusal:    [7]u64, // The error record of a refusal.
	lent_close: bool, // A refused Start with a list: each number that the list lent is closed, as on each refusal of a list.
	counted:    ^Name_Count, // Succeeded: the count of the name, which the caller adds one start to after a start that ran; nil for a start policy of the image.
}

// start_step decides a Start of a start policy before any start, in this
// order: a list for a name that the root service starts by a procedure of
// its own (Unsupported of the unit Wiring_Rows, argument 2: the word of the
// list), start_refusal, then restart_check. A refusal changes no count.
start_step :: proc "contextless" (listed: bool, facts: Start_Facts, counts: ^Name_Counts, from_disk: bool, name: string) -> Start_Step {
	kind := u32(root_ring.Root_Command.Start)
	if listed && start_list.root_procedure_of(name) != .None {
		return {outcome = .Operation_Unsupported, refusal = errors.ring_fail(kind, .Unsupported, .Wiring_Rows, 2), lent_close = true}
	}
	if outcome, refusal := start_refusal(facts); outcome != .Succeeded {
		return {outcome = outcome, refusal = refusal, lent_close = listed}
	}
	outcome, refusal, place := restart_check(counts, from_disk, name)
	if outcome != .Succeeded {
		return {outcome = outcome, refusal = refusal, lent_close = listed}
	}
	return {outcome = .Succeeded, counted = place}
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
choice_form_refusal :: proc "contextless" (nickname_is_empty: bool, hash_is_zero: bool) -> (outcome: call_outcome.Call_Outcome, refusal: [7]u64) {
	if nickname_is_empty && !hash_is_zero {
		return .Argument_Refused, errors.ring_fail(u32(root_ring.Root_Command.Start_Policy_Choice), .Bad_Value, .None, 2)
	}
	return .Succeeded, {}
}

// choice_record is the outcome and the error record of a refused choice:
// Grant_Or_Right_Missing with No_Grant of the principals for a named
// principal, which cannot choose for the machine; Wrong_State with Refused
// of the principals for a machine key that does not open with no
// passphrase, or that has no record.
choice_record :: proc "contextless" (refusal: Choice_Refusal) -> (outcome: call_outcome.Call_Outcome, record: [7]u64) {
	kind := u32(root_ring.Root_Command.Start_Policy_Choice)
	switch refusal {
	case .None:
		return .Succeeded, {}
	case .Named_Principal:
		return .Grant_Or_Right_Missing, errors.ring_fail(kind, .No_Grant, .Principals)
	case .No_Machine_Key, .Passphrase:
		return .Wrong_State, errors.ring_fail(kind, .Refused, .Principals)
	}
	return .Succeeded, {}
}

// usable_decision decides a Machine_Usable: only from the start policy that
// runs, and only while that start policy has not said it yet. Each other
// one is refused with Wrong_State and State (unit Processes), and changes
// nothing. A
// rescue that starts after the machine was usable runs in the stage
// Running again, so its own Machine_Usable is taken: the machine was
// usable by the policy that stopped, not by the rescue.
usable_decision :: proc "contextless" (sender_runs: bool, stage: Stage) -> (outcome: call_outcome.Call_Outcome, refusal: [7]u64) {
	if !sender_runs || stage != .Running {
		return .Wrong_State, errors.ring_fail(u32(root_ring.Root_Command.Machine_Usable), .State, .Processes)
	}
	return .Succeeded, {}
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

// One floor candidate for kept_pages_of_start_list.
Kept_Floor :: struct {
	name:  string,
	pages: u64,
}

// kept_pages_of_start_list sums the floors that the division of a start
// list keeps beside its rows: the start policy once (when no row names
// it), each part of system_parts that is neither "root", policy_name, nor
// a row (with at most the largest renderer of console_renderers), and
// disk_budget_pages when the budget of the disk processes is not made yet.
// The result is never below largest_pages and saturates at max(u64).
kept_pages_of_start_list :: proc "contextless" (
	policy_name: string,
	policy_pages: u64,
	system_parts: []Kept_Floor,
	console_renderers: []string,
	rows: []string,
	disk_budget_pages: u64,
	largest_pages: u64,
) -> u64 {
	add :: proc "contextless" (kept: ^u64, pages: u64) {
		kept^ = kept^ > max(u64) - pages ? max(u64) : kept^ + pages
	}
	in_names :: proc "contextless" (target: string, names: []string) -> bool {
		for item in names {
			if item == target {
				return true
			}
		}
		return false
	}
	kept: u64 = 0
	if !in_names(policy_name, rows) {
		add(&kept, policy_pages)
	}
	renderer: u64 = 0
	for part in system_parts {
		if part.name == "root" || part.name == policy_name || in_names(part.name, rows) {
			continue
		}
		if in_names(part.name, console_renderers) {
			renderer = max(renderer, part.pages)
			continue
		}
		add(&kept, part.pages)
	}
	add(&kept, renderer)
	add(&kept, disk_budget_pages)
	return max(kept, largest_pages)
}
