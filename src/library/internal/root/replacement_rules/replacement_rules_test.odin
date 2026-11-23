#+build !freestanding
package replacement_rules

import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/replacement_list"
import "modus:contract/root_ring"
import "internal:root/replacement_signature"

// The facts of a Replace that runs: the sender holds the grant, the entry 3
// of 12 replaces a module of the image by a signed row, with no chain.
@(private = "file")
RUNS :: Replace_Facts{granted = true, by = 3, entry_count = 12, name_in_image = true, decision = .Accepted}

@(private = "file")
expect_refused :: proc(t: ^testing.T, facts: Replace_Facts, outcome: call_outcome.Call_Outcome, kind: errors.Kind, unit: errors.Unit, about: string) -> errors.Error_Record {
	got, values, _ := replace_refusal(facts)
	record := errors.completion_record(values)
	testing.expectf(t, got == outcome, "%s: the outcome %v", about, got)
	testing.expectf(t, record.kind == i64(kind) && record.unit == i64(unit) && record.operation == i64(root_ring.Root_Command.Replace), "%s: the record %v", about, record)
	testing.expectf(t, kind in call_outcome.KINDS_OF[outcome], "%s: the kind %v does not explain %v", about, kind, outcome)
	again, values_again, _ := replace_refusal(facts)
	testing.expectf(t, again == got && values_again == values, "%s: two decisions differ", about)
	return record
}

// Each refusal at its edge, and the first test that holds wins: a sender
// with no grant learns nothing, whatever else is wrong; the entry past the
// last, the largest word; a module that replaces itself; a name of no
// module; a pair with no row or no list; a chain; a damaged list and a row
// that does not verify. A removal needs no row and no check of a chain.
// The Replace that runs comes last.
@(test)
each_refusal_of_a_replace_names_its_outcome :: proc(t: ^testing.T) {
	everything_wrong := Replace_Facts{granted = false, by = max(u64), entry_count = 0, replaces_itself = true, chained = true, decision = .Not_Authentic}
	expect_refused(t, everything_wrong, .Grant_Or_Right_Missing, .No_Grant, .Root_Commands, "no grant")
	facts := RUNS
	facts.by = facts.entry_count + 1
	record := expect_refused(t, facts, .Argument_Refused, .Bad_Value, .None, "one entry past the last")
	testing.expect_value(t, record.argument, 2)
	testing.expect_value(t, record.value, 13)
	testing.expect_value(t, record.limit, 12)
	facts.by = max(u64)
	record = expect_refused(t, facts, .Argument_Refused, .Bad_Value, .None, "the largest word")
	testing.expect_value(t, record.value, i64(1) << 62)
	facts = RUNS
	facts.by = facts.entry_count
	testing.expect(t, call_outcome.Call_Outcome.Succeeded == first_outcome(facts), "the last entry is taken")
	facts = RUNS
	facts.replaces_itself = true
	facts.name_in_image = false
	expect_refused(t, facts, .Argument_Refused, .Bad_Value, .Modules, "a module that replaces itself")
	facts = RUNS
	facts.name_in_image = false
	facts.chained = true
	expect_refused(t, facts, .Nothing_Has_That_Name, .Absent, .Modules, "a name of no module")
	for decision in ([?]replacement_signature.Decision{.No_Row, .No_List}) {
		facts = RUNS
		facts.decision = decision
		facts.chained = true
		_, _, by_signature := replace_refusal(facts)
		testing.expect(t, by_signature)
		expect_refused(t, facts, .Nothing_Has_That_Name, .Absent, .Records, "no row")
	}
	facts = RUNS
	facts.chained = true
	facts.decision = .Not_Authentic
	expect_refused(t, facts, .Wrong_State, .State, .Records, "a chain")
	facts = RUNS
	facts.decision = .Not_Authentic
	record = expect_refused(t, facts, .Data_Damaged, .Damaged, .Records, "a row that does not verify")
	testing.expect_value(t, record.found, 0)
	for problem in replacement_list.List_Problem {
		facts = RUNS
		facts.decision = .List_Not_Valid
		facts.problem = problem
		record = expect_refused(t, facts, .Data_Damaged, .Damaged, .Records, "a damaged list")
		testing.expect_value(t, record.found, i64(problem))
	}
	// A removal: no row, no list, a chain and a module of itself are not read.
	facts = RUNS
	facts.by = 0
	facts.decision = .No_List
	facts.chained = true
	facts.replaces_itself = true
	testing.expect_value(t, first_outcome(facts), call_outcome.Call_Outcome.Succeeded)
	facts.name_in_image = false
	expect_refused(t, facts, .Nothing_Has_That_Name, .Absent, .Modules, "a removal of no module")
	// The Replace that runs: Succeeded and no record.
	outcome, values, by_signature := replace_refusal(RUNS)
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Succeeded)
	testing.expect_value(t, values, [7]u64{})
	testing.expect(t, !by_signature)
}

// A full table refuses with the count of its records, and its kind explains
// its outcome.
@(test)
a_full_table_is_the_capacity_of_the_machine :: proc(t: ^testing.T) {
	for capacity in ([?]i64{0, 1, 64, max(i64)}) {
		outcome, values := table_full_refusal(capacity)
		record := errors.completion_record(values)
		testing.expect_value(t, outcome, call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted)
		testing.expect(t, record.kind == i64(errors.Kind.Full) && record.unit == i64(errors.Unit.Records) && record.limit == capacity)
		testing.expect(t, errors.Kind.Full in call_outcome.KINDS_OF[outcome])
	}
}

@(private = "file")
first_outcome :: proc(facts: Replace_Facts) -> call_outcome.Call_Outcome {
	outcome, _, _ := replace_refusal(facts)
	return outcome
}
