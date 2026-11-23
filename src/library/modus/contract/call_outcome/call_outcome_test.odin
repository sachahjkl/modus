#+build !freestanding
package call_outcome

import "modus:contract/errors"
import "core:testing"

// The border refuses each word that names no member first: one past the
// last member, a word far past it, the largest word, and the words whose
// low 32 bits name a member (a reader that cut the word to 32 bits would
// take them). Each gives Answer_Unreadable and the record Bad_Value with
// the word whole and the last member as the limit. Then each member, from
// 0 to the last, comes back from its own word with no record.
@(test)
a_word_that_names_no_outcome_is_answer_unreadable :: proc(t: ^testing.T) {
	refused := [?]u64{u64(max(Call_Outcome)) + 1, 17, 18, 1 << 32, 1 << 32 | 2, max(u64) - 1, max(u64), u64(max(u32))}
	for word in refused {
		outcome, record := outcome_of_word(word)
		testing.expectf(t, outcome == .Answer_Unreadable, "the word %d names no outcome, and it gives %v", word, outcome)
		testing.expect_value(t, record.kind, i64(errors.Kind.Bad_Value))
		testing.expect_value(t, record.unit, i64(errors.Unit.None))
		testing.expect_value(t, cast(u64)record.value, word)
		testing.expect_value(t, record.limit, i64(max(Call_Outcome)))
		testing.expect_value(t, record.found, 0)
	}
	count := 0
	for word in u64(0) ..= u64(max(Call_Outcome)) {
		outcome, record := outcome_of_word(word)
		testing.expect_value(t, u64(outcome), word)
		testing.expect_value(t, record, errors.Error_Record{})
		count += 1
	}
	testing.expect_value(t, count, 17)
}

// The values are the contract: a member that moves breaks each reader of
// another build. Succeeded is 0, so a completion of zero bytes reads as a
// success.
@(test)
the_values_of_the_members_never_move :: proc(t: ^testing.T) {
	values := [Call_Outcome]u64 {
		.Succeeded                        = 0,
		.Argument_Refused                 = 1,
		.Nothing_Has_That_Name            = 2,
		.Name_Already_Taken               = 3,
		.Grant_Or_Right_Missing           = 4,
		.Callee_Busy                      = 5,
		.Budget_Or_Capacity_Exhausted     = 6,
		.Wrong_State                      = 7,
		.Another_Change_Came_First        = 8,
		.Operation_Unsupported            = 9,
		.Data_Damaged                     = 10,
		.Callee_Unavailable               = 11,
		.Stopped_After_A_Partial_Change   = 12,
		.Callee_Stopped_During_The_Call   = 13,
		.Connection_Ended_During_The_Call = 14,
		.Deadline_Passed_During_The_Call  = 15,
		.Answer_Unreadable                = 16,
	}
	for member in Call_Outcome {
		testing.expectf(t, u64(member) == values[member], "%v has the value %d, and the contract gives %d", member, u64(member), values[member])
		// A completion has a kind of 32 bits: each member fits it.
		testing.expect(t, u64(member) < 1 << 32)
	}
	testing.expect_value(t, u8(Effect_Group.Whole_Work_Done), 0)
	testing.expect_value(t, u8(Effect_Group.Change_In_Doubt), 3)
}

// Each member has an effect group and a parent. Only Succeeded is in
// Whole_Work_Done, only Stopped_After_A_Partial_Change in
// Partial_Change_Stated, and the four members of the path in
// Change_In_Doubt: these groups keep their members for ever. A member past
// the first version is in Nothing_Changed, and its parent is a member of
// the first version in the same group.
@(test)
each_member_has_a_group_and_a_parent :: proc(t: ^testing.T) {
	for member in Call_Outcome {
		group := effect_group_of(member)
		switch group {
		case .Whole_Work_Done:
			testing.expect_value(t, member, Call_Outcome.Succeeded)
		case .Partial_Change_Stated:
			testing.expect_value(t, member, Call_Outcome.Stopped_After_A_Partial_Change)
		case .Change_In_Doubt:
			testing.expectf(t, member in bit_set[Call_Outcome; u64]{.Callee_Stopped_During_The_Call, .Connection_Ended_During_The_Call, .Deadline_Passed_During_The_Call, .Answer_Unreadable}, "%v is in Change_In_Doubt, and that group keeps its members for ever", member)
		case .Nothing_Changed:
		}
		parent := PARENT_OF[member]
		testing.expectf(t, parent in FIRST_VERSION_MEMBERS, "the parent of %v is %v, which is no member of the first version", member, parent)
		testing.expectf(t, effect_group_of(parent) == group, "%v and its parent %v are in two groups", member, parent)
		if member in FIRST_VERSION_MEMBERS {
			testing.expectf(t, parent == member, "%v is a member of the first version, and its parent is %v", member, parent)
		} else {
			testing.expectf(t, group == .Nothing_Changed, "the new member %v is in %v: a new member joins Nothing_Changed only", member, group)
			testing.expectf(t, parent != member, "the new member %v names itself as its parent", member)
		}
		testing.expect(t, CALL_OUTCOME_NAMES[member] != "")
	}
	for group in Effect_Group {
		testing.expect(t, EFFECT_GROUP_NAMES[group] != "")
	}
}

// Each kind of the error record explains at least one outcome, and Refused,
// the last resort, explains each outcome but Succeeded. Only the kind None
// explains Succeeded.
@(test)
each_kind_explains_an_outcome :: proc(t: ^testing.T) {
	for kind in errors.Kind {
		explained := 0
		for member in Call_Outcome {
			explained += int(kind in KINDS_OF[member])
		}
		testing.expectf(t, explained > 0, "the kind %v explains no outcome", kind)
	}
	for member in Call_Outcome {
		if member == .Succeeded {
			testing.expect_value(t, KINDS_OF[member], bit_set[errors.Kind; u64]{.None})
			continue
		}
		testing.expectf(t, .Refused in KINDS_OF[member], "Refused does not explain %v", member)
		testing.expectf(t, .None not_in KINDS_OF[member], "the kind None explains the failure %v", member)
	}
}

// The tests of a callee run in their order. A change that happened comes
// first, before every refusal; the grant comes before the names, so a
// caller with no grant learns nothing of a name. With no test that holds,
// the call succeeded. Each pair of tests gives the earlier one.
@(test)
the_tests_of_a_callee_run_in_their_order :: proc(t: ^testing.T) {
	testing.expect_value(t, first_outcome({}), Call_Outcome.Succeeded)
	everything := bit_set[Callee_Test; u16]{}
	for test in Callee_Test {
		everything += {test}
	}
	testing.expect_value(t, first_outcome(everything), Call_Outcome.Stopped_After_A_Partial_Change)
	testing.expect_value(t, first_outcome({.Name_Names_Nothing, .Grant_Or_Right_Absent}), Call_Outcome.Grant_Or_Right_Missing)
	testing.expect_value(t, first_outcome({.Argument_Breaks_A_Rule, .Grant_Or_Right_Absent}), Call_Outcome.Argument_Refused)
	testing.expect_value(t, first_outcome({.Own_Capacity_Exhausted, .Changed_State_Then_Stopped}), Call_Outcome.Stopped_After_A_Partial_Change)
	for earlier in Callee_Test {
		testing.expect_value(t, first_outcome({earlier}), OUTCOME_OF_CALLEE_TEST[earlier])
		testing.expect(t, effect_group_of(OUTCOME_OF_CALLEE_TEST[earlier]) != .Whole_Work_Done)
		for later in Callee_Test {
			if u8(later) <= u8(earlier) {
				continue
			}
			testing.expectf(t, first_outcome({earlier, later}) == OUTCOME_OF_CALLEE_TEST[earlier], "the tests %v and %v hold, and the outcome is not the one of the first", earlier, later)
		}
	}
	// No callee test gives a member of the path.
	for test in Callee_Test {
		group := effect_group_of(OUTCOME_OF_CALLEE_TEST[test])
		testing.expect(t, group == .Nothing_Changed || group == .Partial_Change_Stated)
	}
}

// The tests of a border run in their order, and each gives a member of the
// group Change_In_Doubt but a stop or an end before the command left or
// was read, which gives Callee_Unavailable: nothing ran. No test that holds
// gives no outcome.
@(test)
the_tests_of_a_border_run_in_their_order :: proc(t: ^testing.T) {
	_, any := first_path_outcome({})
	testing.expect(t, !any)
	outcome, ok := first_path_outcome({.Answer_Not_Readable, .Callee_Stopped_After_It_Read})
	testing.expect(t, ok)
	testing.expect_value(t, outcome, Call_Outcome.Callee_Stopped_During_The_Call)
	outcome, _ = first_path_outcome({.Deadline_Passed_After_It_Left, .Connection_Ended_After_It_Left})
	testing.expect_value(t, outcome, Call_Outcome.Connection_Ended_During_The_Call)
	outcome, _ = first_path_outcome({.Connection_Ended_Before_It_Left, .Deadline_Passed_After_It_Left})
	testing.expect_value(t, outcome, Call_Outcome.Callee_Unavailable)
	for test in Path_Test {
		group := effect_group_of(OUTCOME_OF_PATH_TEST[test])
		before := test == .Callee_Stopped_Before_It_Read || test == .Connection_Ended_Before_It_Left
		testing.expectf(t, before ? group == .Nothing_Changed : group == .Change_In_Doubt, "the test %v gives the group %v", test, group)
	}
}

// The rule of weakening: an export that changed something, then got a
// refusal from its callee, gives Stopped_After_A_Partial_Change, never the
// refusal. It passes a refusal on as it came only when it changed nothing.
// A call in doubt stays in doubt, and no outcome is ever made stronger.
@(test)
a_change_then_a_refusal_is_a_partial_change :: proc(t: ^testing.T) {
	strength :: proc(group: Effect_Group) -> int {
		switch group {
		case .Whole_Work_Done, .Nothing_Changed:
			return 2
		case .Partial_Change_Stated:
			return 1
		case .Change_In_Doubt:
			return 0
		}
		return 0
	}
	for received in Call_Outcome {
		for changed_before in ([2]bool{false, true}) {
			given := outcome_passed_on(received, changed_before)
			testing.expectf(t, strength(effect_group_of(given)) <= strength(effect_group_of(received)), "%v passed on as %v promises more", received, given)
			switch effect_group_of(received) {
			case .Nothing_Changed:
				expected := changed_before ? Call_Outcome.Stopped_After_A_Partial_Change : received
				testing.expectf(t, given == expected, "%v after a change %v gives %v", received, changed_before, given)
			case .Whole_Work_Done, .Partial_Change_Stated, .Change_In_Doubt:
				testing.expect_value(t, given, received)
			}
		}
	}
	testing.expect_value(t, outcome_passed_on(.Budget_Or_Capacity_Exhausted, true), Call_Outcome.Stopped_After_A_Partial_Change)
	testing.expect_value(t, outcome_passed_on(.Deadline_Passed_During_The_Call, true), Call_Outcome.Deadline_Passed_During_The_Call)
}

// fail writes the record and gives the outcome with the value 0, and writes
// nothing when the caller gave no record. The pair of a success is the
// last case: the value is the one of the export.
@(test)
fail_gives_the_outcome_and_the_value_0 :: proc(t: ^testing.T) {
	record: errors.Error_Record
	outcome, value := fail(&record, .Argument_Refused, .Too_Long, .Bytes, 2, 300, 255)
	testing.expect_value(t, outcome, Call_Outcome.Argument_Refused)
	testing.expect_value(t, value, 0)
	testing.expect_value(t, record, errors.error_make(.Too_Long, .Bytes, 2, 300, 255))
	outcome, value = fail(nil, .Callee_Busy, .Busy)
	testing.expect_value(t, outcome, Call_Outcome.Callee_Busy)
	testing.expect_value(t, value, 0)
	answer :: proc "c" (fails: bool, error: ^errors.Error_Record) -> (outcome: Call_Outcome, value: i64) {
		if fails {
			return fail(error, .Nothing_Has_That_Name, .Absent, .Objects, 1)
		}
		return .Succeeded, -5
	}
	outcome, value = answer(false, &record)
	testing.expect_value(t, outcome, Call_Outcome.Succeeded)
	testing.expect_value(t, value, -5)
	// Inside a package the value comes first, and or_return passes the
	// outcome on with the value 0.
	inner :: proc "contextless" (fails: bool, error: ^errors.Error_Record) -> (value: i64, outcome: Call_Outcome) {
		if fails {
			return fail_with_value_first(error, .Data_Damaged, .Damaged, .Blocks, 1)
		}
		return 7, .Succeeded
	}
	outer :: proc "contextless" (fails: bool, error: ^errors.Error_Record) -> (value: i64, outcome: Call_Outcome) {
		inner_value := inner(fails, error) or_return
		return inner_value * 3, .Succeeded
	}
	record = {}
	tripled, passed := outer(true, &record)
	testing.expect_value(t, passed, Call_Outcome.Data_Damaged)
	testing.expect_value(t, tripled, 0)
	testing.expect_value(t, record.kind, i64(errors.Kind.Damaged))
	tripled, passed = outer(false, &record)
	testing.expect_value(t, passed, Call_Outcome.Succeeded)
	testing.expect_value(t, tripled, 21)
}

// The border of a completion of a ring refuses each kind word that names no
// outcome and each failure whose values are no record, as Answer_Unreadable
// with its own record: the first word past the last member, the largest
// word; the kind None, a kind past the last member, a unit past the last
// member. A failure gives its record, and the success comes last, with no
// record whatever its values hold.
@(test)
the_border_of_a_completion_reads_its_outcome :: proc(t: ^testing.T) {
	for word in ([]u32{u32(max(Call_Outcome)) + 1, max(u32)}) {
		outcome, record := completion_outcome(word, {0 = 5})
		testing.expectf(t, outcome == .Answer_Unreadable && record.kind == i64(errors.Kind.Bad_Value), "the word %d gives %v", word, outcome)
	}
	bad_records := [?]errors.Error_Record{{}, {kind = i64(max(errors.Kind)) + 1}, {kind = -1}, {kind = i64(errors.Kind.Device), unit = i64(max(errors.Unit)) + 1}}
	for bad in bad_records {
		outcome, record := completion_outcome(u32(Call_Outcome.Callee_Unavailable), errors.completion_values(bad))
		testing.expectf(t, outcome == .Answer_Unreadable && record.kind == i64(errors.Kind.Malformed), "the record %v gives %v", bad, outcome)
	}
	device := errors.error_make(.Device, .None, 0, 4)
	outcome, record := completion_outcome(u32(Call_Outcome.Callee_Unavailable), errors.completion_values(device))
	testing.expect_value(t, outcome, Call_Outcome.Callee_Unavailable)
	testing.expect_value(t, record, device)
	outcome, record = completion_outcome(0, {1, 2, 3, 4, 5, 6, 7})
	testing.expect_value(t, outcome, Call_Outcome.Succeeded)
	testing.expect_value(t, record, errors.Error_Record{})
}

// A record whose kind its outcome does not explain goes out with the kind
// Refused and the rest of its fields; a kind that names no member too; a
// record that the outcome explains goes out as it is.
@(test)
a_record_is_explained_by_its_outcome :: proc(t: ^testing.T) {
	device := errors.error_make(.Device, .Bytes, 1, 2, 3, 4)
	explained := record_explained(.Argument_Refused, device)
	testing.expect_value(t, explained.kind, i64(errors.Kind.Refused))
	testing.expect(t, explained.unit == device.unit && explained.argument == 1 && explained.value == 2 && explained.limit == 3 && explained.found == 4)
	unknown := device
	unknown.kind = i64(max(errors.Kind)) + 1
	testing.expect_value(t, record_explained(.Callee_Unavailable, unknown).kind, i64(errors.Kind.Refused))
	testing.expect_value(t, record_explained(.Callee_Unavailable, device), device)
}
