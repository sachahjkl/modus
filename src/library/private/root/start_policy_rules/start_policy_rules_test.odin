#+build !freestanding
package start_policy_rules

import "core:testing"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/root_ring"
import "modus:contract/start_list"

// The facts of a Start that runs: the sender runs, the name does not run,
// it is in the image, and it is no start policy.
@(private = "file")
RUNS :: Start_Facts{sender_runs = true, name_in_image = true}

// The step before a Start of a start policy with a list. Refused first,
// each with its status and its record, the lent numbers closed, and no
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
			testing.expect_value(t, step, Start_Step{status = .Bad_Operation, refusal = errors.ring_fail(start, .Unsupported, .Wiring_Rows, 2), lent_close = true})
			testing.expect_value(t, counts, Name_Counts{})
		}
		// With no list, the procedure of the name runs.
		testing.expect_value(t, start_step(false, RUNS, &counts, false, name).status, op.Status.Ok)
	}
	runs := RUNS
	runs.name_runs = true
	step := start_step(true, runs, &counts, true, "wired_writer")
	testing.expect_value(t, step, Start_Step{status = .Bad_State, refusal = errors.ring_fail(start, .Exists, .Processes, 1), lent_close = true})
	testing.expect_value(t, counts, Name_Counts{})
	testing.expect_value(t, start_step(false, runs, &counts, true, "wired_writer").lent_close, false)

	// The bound of the restarts from the disk: the name has had each of
	// its starts, and one more is refused, with its list closed.
	full: Name_Counts
	full[0].name_length = copy(full[0].name[:], "wired_writer")
	full[0].starts = start_list.RESTART_LIMIT + 1
	before := full
	step = start_step(true, RUNS, &full, true, "wired_writer")
	testing.expect_value(t, step.status, op.Status.No_Budget)
	testing.expect_value(t, step.refusal, restart_record(start_list.RESTART_LIMIT + 1, false))
	testing.expect(t, step.lent_close && step.counted == nil, "a refused restart keeps its lent numbers or a count")
	testing.expect_value(t, full, before)
	testing.expect_value(t, start_step(false, RUNS, &full, true, "wired_writer").lent_close, false)

	step = start_step(true, RUNS, &counts, true, "wired_writer")
	testing.expect_value(t, step.status, op.Status.Ok)
	testing.expect(t, !step.lent_close && step.counted == &counts[0], "an allowed start closes its list or has no count")
	testing.expect_value(t, start_step(true, RUNS, &counts, false, "wired_writer"), Start_Step{status = .Ok})
}

// Each refusal of a Start of a start policy, first: a start of a start
// policy by itself gives Reserved, also from a sender that runs and for a
// name that runs; a sender that no longer runs gives Absent; a name that
// runs gives Exists; shortage on an image that does not hold it gives
// Absent of the modules, so its procedure, which stops the machine, never
// runs. A Start that the facts allow comes last.
@(test)
a_start_of_a_start_policy_is_refused_by_its_facts :: proc(t: ^testing.T) {
	expect :: proc(t: ^testing.T, facts: Start_Facts, status: op.Status, kind: errors.Kind, unit: errors.Unit, loc := #caller_location) {
		got := start_refusal(facts)
		testing.expect_value(t, got, status, loc = loc)
		record := errors.completion_record(start_record(got, facts))
		testing.expect_value(t, errors.Kind(record.kind), kind, loc = loc)
		testing.expect_value(t, errors.Unit(record.unit), unit, loc = loc)
		testing.expect_value(t, record.operation, i64(root_ring.Root_Command.Start), loc = loc)
	}
	itself := RUNS
	itself.name_is_a_start_policy = true
	expect(t, itself, .Bad_Operation, .Reserved, .None)
	itself.name_runs = true
	expect(t, itself, .Bad_Operation, .Reserved, .None)
	gone := RUNS
	gone.sender_runs = false
	expect(t, gone, .Bad_State, .Absent, .Processes)
	twice := RUNS
	twice.name_runs = true
	expect(t, twice, .Bad_State, .Exists, .Processes)
	absent_test := RUNS
	absent_test.name_is_of_a_test_machine = true
	absent_test.name_in_image = false
	expect(t, absent_test, .Bad_Operation, .Absent, .Modules)
	// The test machine that holds it starts it.
	held_test := RUNS
	held_test.name_is_of_a_test_machine = true
	testing.expect_value(t, start_refusal(held_test), op.Status.Ok)
	testing.expect_value(t, start_refusal(RUNS), op.Status.Ok)
	// A status that the facts do not explain gives Refused with it.
	other := errors.completion_record(start_record(.No_Slot, RUNS))
	testing.expect_value(t, errors.Kind(other.kind), errors.Kind.Refused)
	testing.expect_value(t, other.found, i64(op.Status.No_Slot))
}

// Machine_Usable: from a sender that no longer runs, in each stage, and a
// second one from the sender that runs (the stage Usable), each gives
// Exists; from the sender that runs, in each stage but Running, too. The
// one that the root service takes comes last.
@(test)
a_machine_usable_that_is_not_the_first_of_the_policy_is_refused :: proc(t: ^testing.T) {
	for stage in Stage {
		status, refusal := usable_decision(false, stage)
		testing.expect_value(t, status, op.Status.Bad_State)
		record := errors.completion_record(refusal)
		testing.expect_value(t, errors.Kind(record.kind), errors.Kind.Exists)
		testing.expect_value(t, errors.Unit(record.unit), errors.Unit.Processes)
		testing.expect_value(t, record.operation, i64(root_ring.Root_Command.Machine_Usable))
		if stage != .Running {
			second, second_refusal := usable_decision(true, stage)
			testing.expect_value(t, second, op.Status.Bad_State)
			testing.expect_value(t, second_refusal, refusal)
		}
	}
	status, refusal := usable_decision(true, .Running)
	testing.expect_value(t, status, op.Status.Ok)
	testing.expect_value(t, refusal, [7]u64{})
}

// The bound of the restarts of a start policy from the disk, edges first:
// one past the bound, the largest count, and a full table of the counts
// are refused with No_Budget and their records; then the bound itself, 1
// and 0 pass. A start policy of the boot image is never refused here,
// whatever its count.
@(test)
a_restart_past_the_bound_of_a_start_policy_from_the_disk_is_refused :: proc(t: ^testing.T) {
	refused := [?]u64{start_list.RESTART_LIMIT + 1, start_list.RESTART_LIMIT + 2, max(u64)}
	for earlier in refused {
		testing.expectf(t, restart_refusal(true, earlier, false) == .No_Budget, "the start after %d starts is taken", earlier)
		record := errors.completion_record(restart_record(earlier, false))
		testing.expect_value(t, errors.Kind(record.kind), errors.Kind.Over_Limit)
		testing.expect_value(t, record.limit, i64(start_list.RESTART_LIMIT))
		testing.expect_value(t, record.value, i64(min(earlier, 1 << 62)))
		testing.expect_value(t, record.operation, i64(root_ring.Root_Command.Start))
		testing.expect_value(t, restart_refusal(false, earlier, false), op.Status.Ok)
	}
	full := [?]u64{0, 1, start_list.RESTART_LIMIT}
	for earlier in full {
		testing.expect_value(t, restart_refusal(true, earlier, true), op.Status.No_Budget)
		record := errors.completion_record(restart_record(earlier, true))
		testing.expect_value(t, errors.Kind(record.kind), errors.Kind.Full)
		testing.expect_value(t, errors.Unit(record.unit), errors.Unit.Records)
		testing.expect_value(t, record.limit, i64(RESTARTED_NAME_CAPACITY))
		testing.expect_value(t, restart_refusal(false, earlier, true), op.Status.Ok)
	}
	testing.expect_value(t, restart_refusal(true, start_list.RESTART_LIMIT, false), op.Status.Ok)
	testing.expect_value(t, restart_refusal(true, 1, false), op.Status.Ok)
	testing.expect_value(t, restart_refusal(true, 0, false), op.Status.Ok)
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
		testing.expect_value(t, status, op.Status.Ok)
		testing.expect(t, place != nil)
		place.starts += 1
	}
	before := counts
	status, refusal, place := restart_check(&counts, true, "console")
	testing.expect_value(t, status, op.Status.No_Budget)
	testing.expect(t, place == nil)
	testing.expect_value(t, errors.Kind(errors.completion_record(refusal).kind), errors.Kind.Over_Limit)
	testing.expect(t, counts == before)
	// Another name has a count of its own.
	status, _, place = restart_check(&counts, true, "input")
	testing.expect_value(t, status, op.Status.Ok)
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
	testing.expect_value(t, status, op.Status.No_Budget)
	testing.expect(t, place == nil)
	testing.expect_value(t, errors.Kind(errors.completion_record(refusal).kind), errors.Kind.Full)
	// A start policy of the boot image: no count, whatever the table.
	status, _, place = restart_check(&full, false, "console")
	testing.expect_value(t, status, op.Status.Ok)
	testing.expect(t, place == nil)
}

// The form of a choice: a nickname of no byte with a hash is refused with
// Bad_Value of the hash; a nickname of no byte with no hash ends the
// choice, and a nickname with or without a hash passes the form.
@(test)
an_empty_nickname_with_a_hash_is_refused :: proc(t: ^testing.T) {
	status, refusal := choice_form_refusal(true, false)
	testing.expect_value(t, status, op.Status.Bad_Operation)
	record := errors.completion_record(refusal)
	testing.expect_value(t, errors.Kind(record.kind), errors.Kind.Bad_Value)
	testing.expect_value(t, record.argument, 2)
	testing.expect_value(t, record.operation, i64(root_ring.Root_Command.Start_Policy_Choice))
	for form in ([3][2]bool{{true, true}, {false, true}, {false, false}}) {
		status, refusal = choice_form_refusal(form[0], form[1])
		testing.expect_value(t, status, op.Status.Ok)
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
		{{caller_is_principal_0 = false, machine_key_record = true, machine_key_without_passphrase = true}, .Named_Principal, .Absent},
		{{caller_is_principal_0 = false}, .Named_Principal, .Absent},
		{{caller_is_principal_0 = true}, .No_Machine_Key, .Refused},
		{{caller_is_principal_0 = true, machine_key_without_passphrase = true}, .No_Machine_Key, .Refused},
		{{caller_is_principal_0 = true, machine_key_record = true}, .Passphrase, .Refused},
	}
	for item in cases {
		refusal := choice_refusal(item.facts)
		testing.expectf(t, refusal == item.refusal, "%v: %v, expected %v", item.facts, refusal, item.refusal)
		record := errors.completion_record(choice_record(refusal))
		testing.expect_value(t, errors.Kind(record.kind), item.kind)
		testing.expect_value(t, errors.Unit(record.unit), errors.Unit.Principals)
		testing.expect_value(t, record.operation, i64(root_ring.Root_Command.Start_Policy_Choice))
	}
	allowed := Choice_Facts{caller_is_principal_0 = true, machine_key_record = true, machine_key_without_passphrase = true}
	testing.expect_value(t, choice_refusal(allowed), Choice_Refusal.None)
	testing.expect_value(t, choice_record(.None), [7]u64{})
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
