#+build !freestanding
package start_policy_rules

import "core:testing"
import "modus:contract/errors"
import "modus:contract/call_outcome"
import "modus:contract/root_ring"
import "modus:contract/start_list"

// The facts of a Start that runs: the sender runs, the name does not run,
// it is in the image, and it is no start policy.
@(private = "file")
RUNS :: Start_Facts{sender_runs = true, name_in_image = true}

// The step before a Start of a start policy with a list. Refused first,
// each with its outcome and its record, the lent numbers closed, and no
// count changed: each name that the root service starts by its own
// procedure, also when the facts allow it and from the disk; a refusal of
// the facts; the restart bound from the disk. The same refusals with no
// list close nothing. A Start with a list that the step allows comes last,
// with its count.
@(test)
a_start_with_a_list_is_refused_before_any_start :: proc(t: ^testing.T) {
	start := u32(root_ring.Root_Command.Start)
	counts: Name_Counts
	for procedure in start_list.Root_Procedure {
		if procedure == .None {
			continue
		}
		name := start_list.ROOT_PROCEDURE_NAMES[procedure]
		for from_disk in ([2]bool{false, true}) {
			step := start_step(true, RUNS, &counts, from_disk, name)
			testing.expect_value(t, step, Start_Step{outcome = .Operation_Unsupported, refusal = errors.ring_fail(start, .Unsupported, .Wiring_Rows, 2), lent_close = true})
			testing.expect_value(t, counts, Name_Counts{})
		}
		// With no list, the procedure of the name runs.
		testing.expect_value(t, start_step(false, RUNS, &counts, false, name).outcome, call_outcome.Call_Outcome.Succeeded)
	}
	runs := RUNS
	runs.name_runs = true
	step := start_step(true, runs, &counts, true, "wired_writer")
	testing.expect_value(t, step, Start_Step{outcome = .Name_Already_Taken, refusal = errors.ring_fail(start, .Exists, .Processes, 1), lent_close = true})
	testing.expect_value(t, counts, Name_Counts{})
	testing.expect_value(t, start_step(false, runs, &counts, true, "wired_writer").lent_close, false)

	// The bound of the restarts from the disk: the name has had each of
	// its starts, and one more is refused, with its list closed.
	full: Name_Counts
	full[0].name_length = copy(full[0].name[:], "wired_writer")
	full[0].starts = start_list.RESTART_LIMIT + 1
	before := full
	step = start_step(true, RUNS, &full, true, "wired_writer")
	testing.expect_value(t, step.outcome, call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted)
	testing.expect_value(t, step.refusal, restart_record(start_list.RESTART_LIMIT + 1, false))
	testing.expect(t, step.lent_close && step.counted == nil, "a refused restart keeps its lent numbers or a count")
	testing.expect_value(t, full, before)
	testing.expect_value(t, start_step(false, RUNS, &full, true, "wired_writer").lent_close, false)

	step = start_step(true, RUNS, &counts, true, "wired_writer")
	testing.expect_value(t, step.outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect(t, !step.lent_close && step.counted == &counts[0], "an allowed start closes its list or has no count")
	testing.expect_value(t, start_step(true, RUNS, &counts, false, "wired_writer"), Start_Step{outcome = .Succeeded})
}

// Each refusal of a Start of a start policy, first: a start of a start
// policy by itself gives Reserved, also from a sender that runs and for a
// name that runs; a sender that no longer runs gives Absent; a name that
// runs gives Exists; shortage on an image that does not hold it gives
// Absent of the modules, so its procedure, which stops the machine, never
// runs. A Start that the facts allow comes last.
@(test)
a_start_of_a_start_policy_is_refused_by_its_facts :: proc(t: ^testing.T) {
	expect :: proc(t: ^testing.T, facts: Start_Facts, outcome: call_outcome.Call_Outcome, kind: errors.Kind, unit: errors.Unit, loc := #caller_location) {
		got, refusal := start_refusal(facts)
		testing.expect_value(t, got, outcome, loc = loc)
		record := errors.completion_record(refusal)
		testing.expect_value(t, errors.Kind(record.kind), kind, loc = loc)
		testing.expect_value(t, errors.Unit(record.unit), unit, loc = loc)
		testing.expect_value(t, record.operation, i64(root_ring.Root_Command.Start), loc = loc)
	}
	itself := RUNS
	itself.name_is_a_start_policy = true
	expect(t, itself, .Grant_Or_Right_Missing, .Reserved, .None)
	itself.name_runs = true
	expect(t, itself, .Grant_Or_Right_Missing, .Reserved, .None)
	gone := RUNS
	gone.sender_runs = false
	expect(t, gone, .Nothing_Has_That_Name, .Absent, .Processes)
	twice := RUNS
	twice.name_runs = true
	expect(t, twice, .Name_Already_Taken, .Exists, .Processes)
	absent_test := RUNS
	absent_test.name_is_of_a_test_machine = true
	absent_test.name_in_image = false
	expect(t, absent_test, .Nothing_Has_That_Name, .Absent, .Modules)
	// The test machine that holds it starts it.
	held_test := RUNS
	held_test.name_is_of_a_test_machine = true
	for facts in ([2]Start_Facts{held_test, RUNS}) {
		outcome, refusal := start_refusal(facts)
		testing.expect_value(t, outcome, call_outcome.Call_Outcome.Succeeded)
		testing.expect_value(t, refusal, [7]u64{})
	}
}

// Machine_Usable: from a sender that no longer runs, in each stage, and a
// second one from the sender that runs (the stage Usable), each gives
// Wrong_State with State; from the sender that runs, in each stage but Running, too. The
// one that the root service takes comes last.
@(test)
a_machine_usable_that_is_not_the_first_of_the_policy_is_refused :: proc(t: ^testing.T) {
	for stage in Stage {
		status, refusal := usable_decision(false, stage)
		testing.expect_value(t, status, call_outcome.Call_Outcome.Wrong_State)
		record := errors.completion_record(refusal)
		testing.expect_value(t, errors.Kind(record.kind), errors.Kind.State)
		testing.expect_value(t, errors.Unit(record.unit), errors.Unit.Processes)
		testing.expect_value(t, record.operation, i64(root_ring.Root_Command.Machine_Usable))
		if stage != .Running {
			second, second_refusal := usable_decision(true, stage)
			testing.expect_value(t, second, call_outcome.Call_Outcome.Wrong_State)
			testing.expect_value(t, second_refusal, refusal)
		}
	}
	status, refusal := usable_decision(true, .Running)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, refusal, [7]u64{})
}

// The stop of the start policy, in each stage, for the rescue and for
// another policy. A stop that the root service asked for (Stopping), a
// stop before any policy (None) and a stop with no policy (No_Policy) do
// nothing; a stop of the rescue, before or after Machine_Usable, leaves
// the machine with no policy; a stop of another policy, before or after
// Machine_Usable, starts the rescue.
@(test)
the_stop_of_a_start_policy_escalates_before_and_after_the_machine_is_usable :: proc(t: ^testing.T) {
	for rescue_runs in ([2]bool{false, true}) {
		testing.expect_value(t, stop_action(.None, rescue_runs), Stop_Action.Nothing)
		testing.expect_value(t, stop_action(.Stopping, rescue_runs), Stop_Action.Nothing)
		testing.expect_value(t, stop_action(.No_Policy, rescue_runs), Stop_Action.Nothing)
	}
	testing.expect_value(t, stop_action(.Running, true), Stop_Action.No_Policy)
	testing.expect_value(t, stop_action(.Usable, true), Stop_Action.No_Policy)
	testing.expect_value(t, stop_action(.Running, false), Stop_Action.Rescue)
	testing.expect_value(t, stop_action(.Usable, false), Stop_Action.Rescue)
}

// The order of a stop after Machine_Usable: the first policy said it, so a
// second one from it is refused; the escalation passes through Stopping,
// where Machine_Usable is refused from any sender; the rescue then runs,
// and its own first Machine_Usable is taken, and its second refused.
@(test)
the_rescue_after_the_machine_is_usable_says_machine_usable_once :: proc(t: ^testing.T) {
	stage := Stage.Running
	first, _ := usable_decision(true, stage)
	testing.expect_value(t, first, call_outcome.Call_Outcome.Succeeded)
	stage = .Usable
	again, _ := usable_decision(true, stage)
	testing.expect_value(t, again, call_outcome.Call_Outcome.Wrong_State)
	testing.expect_value(t, stop_action(stage, false), Stop_Action.Rescue)
	stage = .Stopping
	for sender_runs in ([2]bool{false, true}) {
		during, _ := usable_decision(sender_runs, stage)
		testing.expect_value(t, during, call_outcome.Call_Outcome.Wrong_State)
	}
	stage = .Running
	stranger, _ := usable_decision(false, stage)
	testing.expect_value(t, stranger, call_outcome.Call_Outcome.Wrong_State)
	rescue_first, rescue_refusal := usable_decision(true, stage)
	testing.expect_value(t, rescue_first, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, rescue_refusal, [7]u64{})
	stage = .Usable
	rescue_again, _ := usable_decision(true, stage)
	testing.expect_value(t, rescue_again, call_outcome.Call_Outcome.Wrong_State)
	testing.expect_value(t, stop_action(stage, true), Stop_Action.No_Policy)
}

// The bound of the restarts of a start policy from the disk, edges first:
// one past the bound, the largest count, and a full table of the counts
// are refused with Budget_Or_Capacity_Exhausted and their records; then the bound itself, 1
// and 0 pass. A start policy of the boot image is never refused here,
// whatever its count.
@(test)
a_restart_past_the_bound_of_a_start_policy_from_the_disk_is_refused :: proc(t: ^testing.T) {
	refused := [?]u64{start_list.RESTART_LIMIT + 1, start_list.RESTART_LIMIT + 2, max(u64)}
	for earlier in refused {
		testing.expectf(t, restart_refusal(true, earlier, false) == .Budget_Or_Capacity_Exhausted, "the start after %d starts is taken", earlier)
		record := errors.completion_record(restart_record(earlier, false))
		testing.expect_value(t, errors.Kind(record.kind), errors.Kind.Over_Limit)
		testing.expect_value(t, record.limit, i64(start_list.RESTART_LIMIT))
		testing.expect_value(t, record.value, i64(min(earlier, 1 << 62)))
		testing.expect_value(t, record.operation, i64(root_ring.Root_Command.Start))
		testing.expect_value(t, restart_refusal(false, earlier, false), call_outcome.Call_Outcome.Succeeded)
	}
	full := [?]u64{0, 1, start_list.RESTART_LIMIT}
	for earlier in full {
		testing.expect_value(t, restart_refusal(true, earlier, true), call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted)
		record := errors.completion_record(restart_record(earlier, true))
		testing.expect_value(t, errors.Kind(record.kind), errors.Kind.Full)
		testing.expect_value(t, errors.Unit(record.unit), errors.Unit.Records)
		testing.expect_value(t, record.limit, i64(RESTARTED_NAME_CAPACITY))
		testing.expect_value(t, restart_refusal(false, earlier, true), call_outcome.Call_Outcome.Succeeded)
	}
	testing.expect_value(t, restart_refusal(true, start_list.RESTART_LIMIT, false), call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, restart_refusal(true, 1, false), call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, restart_refusal(true, 0, false), call_outcome.Call_Outcome.Succeeded)
}

// The bound through restart_check, as the root service calls it, with the
// count added after each start that ran: the start after 16 restarts of
// one name is refused and changes no count, another name still starts; a
// table whose places all hold other names refuses a new name; a start
// policy of the boot image is never counted. The starts that pass come
// first only because the bound is reached by them.
@(test)
the_restart_check_of_the_root_service_holds_the_bound :: proc(t: ^testing.T) {
	counts: Name_Counts
	for _ in 0 ..= start_list.RESTART_LIMIT {
		status, _, place := restart_check(&counts, true, "console")
		testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
		testing.expect(t, place != nil)
		place.starts += 1
	}
	before := counts
	status, refusal, place := restart_check(&counts, true, "console")
	testing.expect_value(t, status, call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted)
	testing.expect(t, place == nil)
	testing.expect_value(t, errors.Kind(errors.completion_record(refusal).kind), errors.Kind.Over_Limit)
	testing.expect(t, counts == before)
	// Another name has a count of its own.
	status, _, place = restart_check(&counts, true, "input")
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	testing.expect(t, place != nil && place.starts == 0)
	// Every place holds another name: a new name is refused.
	full: Name_Counts
	for &item, index in full {
		item.name[0] = 'a' + u8(index % 26)
		item.name[1] = 'a' + u8(index / 26)
		item.name_length = 2
		item.starts = 1
	}
	status, refusal, place = restart_check(&full, true, "console")
	testing.expect_value(t, status, call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted)
	testing.expect(t, place == nil)
	testing.expect_value(t, errors.Kind(errors.completion_record(refusal).kind), errors.Kind.Full)
	// A start policy of the boot image: no count, whatever the table.
	status, _, place = restart_check(&full, false, "console")
	testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
	testing.expect(t, place == nil)
}

// The form of a choice: a nickname of no byte with a hash is refused with
// Bad_Value of the hash; a nickname of no byte with no hash ends the
// choice, and a nickname with or without a hash passes the form.
@(test)
an_empty_nickname_with_a_hash_is_refused :: proc(t: ^testing.T) {
	status, refusal := choice_form_refusal(true, false)
	testing.expect_value(t, status, call_outcome.Call_Outcome.Argument_Refused)
	record := errors.completion_record(refusal)
	testing.expect_value(t, errors.Kind(record.kind), errors.Kind.Bad_Value)
	testing.expect_value(t, record.argument, 2)
	testing.expect_value(t, record.operation, i64(root_ring.Root_Command.Start_Policy_Choice))
	for form in ([3][2]bool{{true, true}, {false, true}, {false, false}}) {
		status, refusal = choice_form_refusal(form[0], form[1])
		testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
		testing.expect_value(t, refusal, [7]u64{})
	}
}

// A choice of a start policy, refusals first, in the order of the checks: a
// caller of a named principal, whatever the machine key; a machine with no
// record of its machine key; a machine key that needs a passphrase. The
// choice that passes comes last.
@(test)
a_choice_of_a_start_policy_is_refused_by_its_facts :: proc(t: ^testing.T) {
	Case :: struct {
		facts:   Choice_Facts,
		refusal: Choice_Refusal,
		kind:    errors.Kind,
	}
	cases := [?]Case {
		{{caller_is_principal_0 = false, machine_key_record = true, machine_key_without_passphrase = true}, .Named_Principal, .No_Grant},
		{{caller_is_principal_0 = false}, .Named_Principal, .No_Grant},
		{{caller_is_principal_0 = true}, .No_Machine_Key, .Refused},
		{{caller_is_principal_0 = true, machine_key_without_passphrase = true}, .No_Machine_Key, .Refused},
		{{caller_is_principal_0 = true, machine_key_record = true}, .Passphrase, .Refused},
	}
	for item in cases {
		refusal := choice_refusal(item.facts)
		testing.expectf(t, refusal == item.refusal, "%v: %v, expected %v", item.facts, refusal, item.refusal)
		outcome, values := choice_record(refusal)
		testing.expect_value(t, outcome, refusal == .Named_Principal ? call_outcome.Call_Outcome.Grant_Or_Right_Missing : call_outcome.Call_Outcome.Wrong_State)
		record := errors.completion_record(values)
		testing.expect_value(t, errors.Kind(record.kind), item.kind)
		testing.expect_value(t, errors.Unit(record.unit), errors.Unit.Principals)
		testing.expect_value(t, record.operation, i64(root_ring.Root_Command.Start_Policy_Choice))
	}
	allowed := Choice_Facts{caller_is_principal_0 = true, machine_key_record = true, machine_key_without_passphrase = true}
	testing.expect_value(t, choice_refusal(allowed), Choice_Refusal.None)
	none_outcome, none_record := choice_record(.None)
	testing.expect_value(t, none_outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, none_record, [7]u64{})
}

// A refused Stop of a start policy gives Absent, the one record for a name
// that runs and for a name that does not: it names the argument 1.
@(test)
a_refused_stop_of_a_start_policy_is_absent :: proc(t: ^testing.T) {
	record := errors.completion_record(stop_record())
	testing.expect_value(t, errors.Kind(record.kind), errors.Kind.Absent)
	testing.expect_value(t, errors.Unit(record.unit), errors.Unit.Processes)
	testing.expect_value(t, record.operation, i64(root_ring.Root_Command.Stop))
	testing.expect_value(t, record.argument, 1)
}
