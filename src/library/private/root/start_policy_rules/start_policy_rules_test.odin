#+build !freestanding
package start_policy_rules

import "core:testing"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/root_ring"

// The facts of a Start that runs: the sender runs, the name does not run,
// it is in the image, and it is no start policy.
@(private = "file")
RUNS :: Start_Facts{sender_runs = true, name_in_image = true}

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
