#+build !freestanding
package system

import "modus:contract/errors"
import "modus:support/principals"
import "core:testing"

// A word of the root ring becomes its member at member_of_word only. Each
// word that names no member is refused first: 0 where 0 is no member, one
// past the largest member, a word between two members, the largest word.
// Then each member comes back from its own word.
@(test)
member_of_word_refuses_a_word_that_names_no_member :: proc(t: ^testing.T) {
	refuse :: proc(t: ^testing.T, $Enum: typeid, words: []u64) {
		for word in words {
			_, ok := member_of_word(Enum, word)
			testing.expectf(t, !ok, "%v: the word %d names no member, and it is taken", typeid_of(Enum), word)
		}
	}
	accept_each :: proc(t: ^testing.T, $Enum: typeid) {
		for member in Enum {
			read, ok := member_of_word(Enum, u64(member))
			testing.expect(t, ok)
			testing.expect_value(t, read, member)
		}
	}
	// Enumerations whose first member is not 0: 0 is refused.
	refuse(t, Remote_Client_Action, {0, u64(max(Remote_Client_Action)) + 1, 1 << 32, max(u64)})
	refuse(t, Principal_Change, {0, u64(max(Principal_Change)) + 1, max(u64)})
	refuse(t, Disk_Grant_Action, {0, u64(max(Disk_Grant_Action)) + 1, max(u64)})
	refuse(t, Machine_Key_State, {0, u64(max(Machine_Key_State)) + 1, max(u64)})
	refuse(t, Principal_Key_Origin, {0, u64(max(Principal_Key_Origin)) + 1, max(u64)})
	// Enumerations whose first member is 0.
	refuse(t, Remote_Client_State, {u64(max(Remote_Client_State)) + 1, max(u64)})
	refuse(t, Machine_Key_Form, {u64(max(Machine_Key_Form)) + 1, max(u64)})
	accept_each(t, Remote_Client_Action)
	accept_each(t, Remote_Client_State)
	accept_each(t, Principal_Change)
	accept_each(t, Disk_Grant_Action)
	accept_each(t, Machine_Key_State)
	accept_each(t, Machine_Key_Form)
	accept_each(t, Principal_Key_Origin)
}

// An enumeration whose values have a gap: a word in the gap names no
// member, though it is between the smallest and the largest.
@(test)
member_of_word_refuses_a_word_in_a_gap :: proc(t: ^testing.T) {
	With_A_Gap :: enum u64 {
		First = 1,
		Third = 3,
	}
	_, ok := member_of_word(With_A_Gap, u64(With_A_Gap.First) + 1)
	testing.expect(t, !ok)
	read, read_ok := member_of_word(With_A_Gap, u64(With_A_Gap.Third))
	testing.expect(t, read_ok)
	testing.expect_value(t, read, With_A_Gap.Third)
}

// The border of each root command that the root service reads, as it
// calls it: the enumeration, the command and the argument of its record.
// Each word that names no member gives Bad_Operation and the record
// Bad_Value of that command and argument, with the word (at most 2^62)
// and the largest member; the values of the command do not change. The
// members come last, with Ok and no record.
@(test)
a_root_command_refuses_a_word_that_names_no_member :: proc(t: ^testing.T) {
	refuse :: proc(t: ^testing.T, $Enum: typeid, command: Root_Command, argument: i64, place: int, words: []u64) {
		for word in words {
			values: [7]u64
			values[place] = word
			before := values
			member, status, refusal := ring_member_of_word(Enum, values[place], command, argument)
			testing.expectf(t, status == .Bad_Operation, "%v: the word %d names no member, and the status is %v", typeid_of(Enum), word, status)
			zero: Enum
			testing.expect_value(t, member, zero)
			testing.expect_value(t, values, before)
			record := errors.completion_record(refusal)
			testing.expect_value(t, errors.Kind(record.kind), errors.Kind.Bad_Value)
			testing.expect_value(t, errors.Unit(record.unit), errors.Unit.None)
			testing.expect_value(t, record.operation, i64(command))
			testing.expect_value(t, record.argument, argument)
			testing.expect_value(t, record.value, i64(min(word, 1 << 62)))
			testing.expect_value(t, record.limit, i64(max(Enum)))
		}
	}
	accept_each :: proc(t: ^testing.T, $Enum: typeid, command: Root_Command, argument: i64) {
		for member in Enum {
			read, status, refusal := ring_member_of_word(Enum, u64(member), command, argument)
			testing.expect_value(t, status, Status.Ok)
			testing.expect_value(t, read, member)
			testing.expect_value(t, refusal, [7]u64{})
		}
	}
	refuse(t, Remote_Client_Action, .Remote_Client, 2, 4, {0, u64(max(Remote_Client_Action)) + 1, 1 << 62 + 1, max(u64)})
	refuse(t, Disk_Grant_Action, .Disk_Grant, 0, 4, {0, u64(max(Disk_Grant_Action)) + 1, max(u64)})
	refuse(t, Principal_Change, .Principal_Change, 2, 4, {0, u64(max(Principal_Change)) + 1, max(u64)})
	refuse(t, Principal_Key_Origin, .Principal_Unlock, 0, 5, {0, u64(max(Principal_Key_Origin)) + 1, max(u64)})
	refuse(t, principals.Change_End, .Principal_Change_End, 2, 4, {u64(max(principals.Change_End)) + 1, max(u64)})
	refuse(t, principals.Change_Problem, .Principal_Change_End, 3, 5, {u64(max(principals.Change_Problem)) + 1, max(u64)})
	accept_each(t, Remote_Client_Action, .Remote_Client, 2)
	accept_each(t, Disk_Grant_Action, .Disk_Grant, 0)
	accept_each(t, Principal_Change, .Principal_Change, 2)
	accept_each(t, Principal_Key_Origin, .Principal_Unlock, 0)
	accept_each(t, principals.Change_End, .Principal_Change_End, 2)
	accept_each(t, principals.Change_Problem, .Principal_Change_End, 3)
}

// The border of Machine_Key: a state that names no member, and for
// .Awaited a form that names no member, give Bad_Operation and an empty
// report; a form is not read for another state. The reports that the
// root service takes come last.
@(test)
a_machine_key_report_refuses_a_word_that_names_no_member :: proc(t: ^testing.T) {
	refused := [?][7]u64 {
		{4 = 0},
		{4 = u64(max(Machine_Key_State)) + 1},
		{4 = max(u64)},
		{4 = u64(Machine_Key_State.Awaited), 5 = u64(max(Machine_Key_Form)) + 1},
		{4 = u64(Machine_Key_State.Awaited), 5 = max(u64)},
	}
	for values in refused {
		before := values
		report, status := machine_key_report_of_values(values)
		testing.expect_value(t, status, Status.Bad_Operation)
		testing.expect_value(t, report, Machine_Key_Report{})
		testing.expect_value(t, values, before)
	}
	for form in Machine_Key_Form {
		report, status := machine_key_report_of_values({4 = u64(Machine_Key_State.Awaited), 5 = u64(form)})
		testing.expect_value(t, status, Status.Ok)
		testing.expect_value(t, report, Machine_Key_Report{state = .Awaited, form = form})
	}
	others := [?]Machine_Key_State{.Opened, .New, .Unreadable}
	for state in others {
		// values[5] is not read: a word of no form changes nothing.
		report, status := machine_key_report_of_values({4 = u64(state), 5 = max(u64)})
		testing.expect_value(t, status, Status.Ok)
		testing.expect_value(t, report.state, state)
	}
}
