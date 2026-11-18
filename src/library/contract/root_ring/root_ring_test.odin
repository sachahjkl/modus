#+build !freestanding
package root_ring

import "core:testing"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/start_grant"

// The kind of a record becomes a command at command_of_word only. Each word
// that names no command is refused first: 0, which is None and which no
// sender sends, one past the largest member, a word far past it, the
// largest word. Each refusal has the record Unsupported with the word.
// Then each command comes back from its own word.
@(test)
command_of_word_refuses_a_word_that_names_no_command :: proc(t: ^testing.T) {
	refused := [?]u32{u32(Root_Command.None), u32(max(Root_Command)) + 1, 1 << 16, max(u32) - 1, max(u32)}
	for word in refused {
		command, ok := command_of_word(word)
		testing.expectf(t, !ok, "the word %d names no command, and it is taken", word)
		testing.expect_value(t, command, Root_Command.None)
		record := errors.completion_record(command_refusal(word))
		testing.expect_value(t, errors.Kind(record.kind), errors.Kind.Unsupported)
		testing.expect_value(t, record.operation, i64(word))
		testing.expect_value(t, record.value, i64(word))
	}
	for member in Root_Command {
		if member == .None {
			continue
		}
		command, ok := command_of_word(u32(member))
		testing.expect(t, ok)
		testing.expect_value(t, command, member)
	}
}

// A role with no start grant of ROOT_RING_GRANTS has no root ring, and
// sends no command: each start grant alone outside them is tried, then all
// of them together, then the grant Store alone, then no grant. The rule
// takes no name. That a command gives a disk process no grant of a root
// ring is the test no_command_gives_a_disk_process_a_root_ring of
// modus:support/disk_process.
@(test)
a_process_with_no_ring_grant_sends_no_command :: proc(t: ^testing.T) {
	without_a_ring: bit_set[start_grant.Grant]
	for grant in start_grant.Grant {
		if grant in ROOT_RING_GRANTS {
			continue
		}
		without_a_ring += {grant}
		role := bit_set[start_grant.Grant]{grant}
		testing.expectf(t, !root_ring_given(role), "the start grant %v gives a root ring", grant)
		for command in Root_Command {
			testing.expectf(t, !sender_allowed(command, role), "a process with only %v sends %v", grant, command)
		}
	}
	roles := [?]bit_set[start_grant.Grant]{{}, without_a_ring, {.Store}}
	for role in roles {
		testing.expect(t, !root_ring_given(role))
		for command in Root_Command {
			testing.expectf(t, !sender_allowed(command, role), "a process with %v and no ring sends %v", role, command)
		}
	}
}

// Each start grant of a ring sends its own commands and no other: the
// commands of the principals and of the debugger never come from Root_Ring,
// Connect sends Connect and Disconnect only, and None comes from nobody.
// The commands that each grant sends come last.
@(test)
each_ring_grant_sends_its_own_commands_only :: proc(t: ^testing.T) {
	expected :: proc(command: Root_Command, grant: start_grant.Grant) -> bool {
		switch ROOT_COMMAND_SENDERS[command] {
		case .Nobody:
			return false
		case .Root_Ring:
			return grant == .Root_Ring
		case .Root_Ring_Or_Connect:
			return grant == .Root_Ring || grant == .Connect
		case .Each_Ring:
			return true
		case .Principals:
			return grant == .Principals
		case .Debugger:
			return grant == .Debugger
		}
		return false
	}
	for grant in ROOT_RING_GRANTS {
		role := bit_set[start_grant.Grant]{grant}
		testing.expect(t, root_ring_given(role))
		for command in Root_Command {
			testing.expectf(t, sender_allowed(command, role) == expected(command, grant), "%v sends %v: %v", grant, command, sender_allowed(command, role))
		}
	}
	// The edges of the table, by name: they are the rules of the guide.
	testing.expect(t, !sender_allowed(.None, ROOT_RING_GRANTS))
	testing.expect(t, !sender_allowed(.Principal_Unlock, {.Root_Ring}))
	testing.expect(t, !sender_allowed(.Machine_Key, {.Root_Ring, .Debugger}))
	testing.expect(t, !sender_allowed(.Debug, {.Root_Ring, .Principals}))
	testing.expect(t, !sender_allowed(.Start, {.Connect, .Principals, .Debugger}))
	testing.expect(t, sender_allowed(.Disconnect, {.Principals}))
	testing.expect(t, sender_allowed(.Connect, {.Connect}))
	testing.expect(t, sender_allowed(.Start, {.Root_Ring}))
	// A refused Connect names the connection; another command the commands.
	connect := errors.completion_record(sender_refusal(.Connect))
	testing.expect_value(t, errors.Kind(connect.kind), errors.Kind.No_Grant)
	testing.expect_value(t, errors.Unit(connect.unit), errors.Unit.Connection)
	start := errors.completion_record(sender_refusal(.Start))
	testing.expect_value(t, errors.Kind(start.kind), errors.Kind.No_Grant)
	testing.expect_value(t, errors.Unit(start.unit), errors.Unit.Root_Commands)
	testing.expect_value(t, start.operation, i64(Root_Command.Start))
}

// The decision of the dispatch, in the order of its steps. The border
// comes first: each word that names no command stops there with the
// record Unsupported, for each role, the role of the console too. Then the
// sender: a role with no grant of a ring, each command; a Connect with the
// grant Connect to a service that its list does not name, with the unit
// Connection; a command of the principals from the console. A decision
// with the same inputs is the same decision. The commands that run come
// last.
@(test)
the_dispatch_refuses_at_its_first_step_that_refuses :: proc(t: ^testing.T) {
	console_role := bit_set[start_grant.Grant]{.Root_Ring, .Inspect, .Stop, .Image, .Terminal, .Store}
	words := [?]u32{u32(Root_Command.None), u32(max(Root_Command)) + 1, 1 << 16, max(u32)}
	roles := [?]bit_set[start_grant.Grant]{{}, console_role, ROOT_RING_GRANTS}
	for word in words {
		for role in roles {
			for listed in ([2]bool{false, true}) {
				decision := dispatch_decide(word, role, listed)
				testing.expect_value(t, decision.step, Dispatch_Step.Border)
				testing.expect_value(t, decision.command, Root_Command.None)
				testing.expect_value(t, decision.status, op.Status.Bad_Operation)
				testing.expect_value(t, decision.refusal, command_refusal(word))
			}
		}
	}
	for command in Root_Command {
		if command == .None {
			continue
		}
		for role in ([2]bit_set[start_grant.Grant]{{}, {.Store, .Image, .Serve}}) {
			decision := dispatch_decide(u32(command), role, true)
			testing.expectf(t, decision.step == .Sender, "a role with no ring sends %v", command)
			testing.expect_value(t, decision.status, op.Status.No_Right)
			testing.expect_value(t, decision.refusal, sender_refusal(command))
			testing.expect_value(t, decision, dispatch_decide(u32(command), role, true))
		}
	}
	unlisted := dispatch_decide(u32(Root_Command.Connect), {.Connect}, false)
	testing.expect_value(t, unlisted.step, Dispatch_Step.Sender)
	record := errors.completion_record(unlisted.refusal)
	testing.expect_value(t, errors.Kind(record.kind), errors.Kind.No_Grant)
	testing.expect_value(t, errors.Unit(record.unit), errors.Unit.Connection)
	testing.expect_value(t, dispatch_decide(u32(Root_Command.Principal_Unlock), console_role, true).step, Dispatch_Step.Sender)
	testing.expect_value(t, dispatch_decide(u32(Root_Command.Debug), console_role, true).step, Dispatch_Step.Sender)
	// The commands that run: Connect from the console names any service,
	// and from the grant Connect a listed one; Disconnect from each ring.
	runs := [?]struct {
		command: Root_Command,
		role:    bit_set[start_grant.Grant],
		listed:  bool,
	}{{.Connect, console_role, false}, {.Connect, {.Connect}, true}, {.Disconnect, {.Principals}, false}, {.Start, console_role, false}, {.Principal_Unlock, {.Principals}, false}, {.Debug, {.Debugger}, false}}
	for case_of in runs {
		decision := dispatch_decide(u32(case_of.command), case_of.role, case_of.listed)
		testing.expectf(t, decision.step == .Command, "%v from %v does not run", case_of.command, case_of.role)
		testing.expect_value(t, decision.command, case_of.command)
		testing.expect_value(t, decision.status, op.Status.Ok)
		testing.expect_value(t, decision.refusal, [7]u64{})
	}
}

// The names of a command that an error record numbers: the number comes
// from another process. Each number that names no command gives "an
// unknown command" and no argument name; then each command has a name, and
// the argument 1 has a name for each command.
@(test)
a_record_of_an_unknown_command_names_no_command :: proc(t: ^testing.T) {
	unknown := [?]i64{-1, i64(Root_Command.None), i64(max(Root_Command)) + 1, i64(max(u32)), i64(max(u32)) + 1, max(i64), min(i64)}
	for number in unknown {
		testing.expect_value(t, root_command_name(number), "an unknown command")
		testing.expect_value(t, root_argument_name(number, 1), "")
		testing.expect_value(t, root_argument_name(number, 2), "")
	}
	for command in Root_Command {
		if command == .None {
			continue
		}
		testing.expect(t, root_command_name(i64(command)) == root_command_names[command])
		testing.expect(t, root_argument_name(i64(command), 1) != "")
		testing.expect_value(t, root_argument_name(i64(command), 0), "")
		testing.expect_value(t, root_argument_name(i64(command), 3), "")
	}
	testing.expect_value(t, root_argument_name(i64(Root_Command.Remote_Client), 1), "key")
	testing.expect_value(t, root_argument_name(i64(Root_Command.Remote_Client), 2), "action")
	testing.expect_value(t, root_argument_name(i64(Root_Command.Start), 2), "")
}

// The records of a refused Replace. The edges come first: `by` one past
// the entries and the largest word, a name that names no module, a module
// that replaces itself, a full table, a sender with no grant Replace. Then
// the statuses that the state does not explain give no record of their
// own, last.
@(test)
a_refused_replace_names_its_cause :: proc(t: ^testing.T) {
	ENTRIES :: 12
	CAPACITY :: 32
	expect_record :: proc(t: ^testing.T, record: [7]u64, named: bool, kind: errors.Kind, unit: errors.Unit, argument: i64, value: i64, limit: i64) {
		testing.expect(t, named)
		read := errors.completion_record(record)
		testing.expect_value(t, errors.Kind(read.kind), kind)
		testing.expect_value(t, errors.Unit(read.unit), unit)
		testing.expect_value(t, read.operation, i64(Root_Command.Replace))
		testing.expect_value(t, read.argument, argument)
		testing.expect_value(t, read.value, value)
		testing.expect_value(t, read.limit, limit)
	}
	record, named := replace_refusal(.Bad_Handle, ENTRIES + 1, ENTRIES, true, CAPACITY)
	expect_record(t, record, named, .Bad_Value, .None, 2, ENTRIES + 1, ENTRIES)
	record, named = replace_refusal(.Bad_Handle, max(u64), ENTRIES, false, CAPACITY)
	expect_record(t, record, named, .Bad_Value, .None, 2, 1 << 62, ENTRIES)
	// `by` inside the entries, and the name of no module.
	record, named = replace_refusal(.Bad_Handle, ENTRIES, ENTRIES, false, CAPACITY)
	expect_record(t, record, named, .Absent, .Modules, 1, 0, 0)
	record, named = replace_refusal(.Bad_Handle, 0, ENTRIES, false, CAPACITY)
	expect_record(t, record, named, .Absent, .Modules, 1, 0, 0)
	record, named = replace_refusal(.Bad_Operation, 3, ENTRIES, true, CAPACITY)
	expect_record(t, record, named, .Bad_Value, .None, 2, 3, 0)
	record, named = replace_refusal(.No_Slot, 3, ENTRIES, true, CAPACITY)
	expect_record(t, record, named, .Full, .Records, 0, 0, CAPACITY)
	record, named = replace_refusal(.No_Right, 3, ENTRIES, true, CAPACITY)
	testing.expect(t, named)
	testing.expect_value(t, record, sender_refusal(.Replace))
	// No cause that the state shows: a chain, a name and an entry that
	// both exist, a success.
	unexplained := [?]struct {
		status:        op.Status,
		name_in_image: bool,
	}{{.Bad_State, true}, {.Bad_Handle, true}, {.Ok, true}}
	for case_of in unexplained {
		record, named = replace_refusal(case_of.status, 3, ENTRIES, case_of.name_in_image, CAPACITY)
		testing.expectf(t, !named, "the status %v names a cause", case_of.status)
		testing.expect_value(t, record, [7]u64{})
	}
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
			member, status, refusal := member_of_word(Enum, values[place], command, argument)
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
			read, status, refusal := member_of_word(Enum, u64(member), command, argument)
			testing.expect_value(t, status, op.Status.Ok)
			testing.expect_value(t, read, member)
			testing.expect_value(t, refusal, [7]u64{})
		}
	}
	refuse(t, Remote_Client_Action, .Remote_Client, 2, 4, {0, u64(max(Remote_Client_Action)) + 1, 1 << 62 + 1, max(u64)})
	refuse(t, Disk_Grant_Action, .Disk_Grant, 0, 4, {0, u64(max(Disk_Grant_Action)) + 1, max(u64)})
	refuse(t, Principal_Change, .Principal_Change, 2, 4, {0, u64(max(Principal_Change)) + 1, max(u64)})
	refuse(t, Principal_Key_Origin, .Principal_Unlock, 0, 5, {0, u64(max(Principal_Key_Origin)) + 1, max(u64)})
	refuse(t, Remote_Client_State, .Remote_Client, 2, 6, {u64(max(Remote_Client_State)) + 1, max(u64)})
	refuse(t, Machine_Key_Form, .Machine_Key, 2, 5, {u64(max(Machine_Key_Form)) + 1, max(u64)})
	accept_each(t, Remote_Client_Action, .Remote_Client, 2)
	accept_each(t, Disk_Grant_Action, .Disk_Grant, 0)
	accept_each(t, Principal_Change, .Principal_Change, 2)
	accept_each(t, Principal_Key_Origin, .Principal_Unlock, 0)
	accept_each(t, Remote_Client_State, .Remote_Client, 2)
	accept_each(t, Machine_Key_Form, .Machine_Key, 2)
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
		testing.expect_value(t, status, op.Status.Bad_Operation)
		testing.expect_value(t, report, Machine_Key_Report{})
		testing.expect_value(t, values, before)
	}
	for form in Machine_Key_Form {
		report, status := machine_key_report_of_values({4 = u64(Machine_Key_State.Awaited), 5 = u64(form)})
		testing.expect_value(t, status, op.Status.Ok)
		testing.expect_value(t, report, Machine_Key_Report{state = .Awaited, form = form})
	}
	others := [?]Machine_Key_State{.Opened, .New, .Unreadable}
	for state in others {
		// values[5] is not read: a word of no form changes nothing.
		report, status := machine_key_report_of_values({4 = u64(state), 5 = max(u64)})
		testing.expect_value(t, status, op.Status.Ok)
		testing.expect_value(t, report.state, state)
	}
}
