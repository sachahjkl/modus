#+build !freestanding
package root_ring

import "base:intrinsics"
import "core:testing"
import "core:thread"
import "core:time"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/replacement_list"
import "modus:contract/ring"
import "modus:contract/start_grant"

// values[5] of a Start: one past the last member and the largest word name
// nothing; each member comes back from its word, last.
@(test)
start_answer_of_word_refuses_a_word_that_names_no_member :: proc(t: ^testing.T) {
	for word in ([?]u64{u64(max(Start_Answer)) + 1, max(u64)}) {
		_, ok := start_answer_of_word(word)
		testing.expectf(t, !ok, "the word %d of a Start is taken", word)
	}
	for member in Start_Answer {
		read, ok := start_answer_of_word(u64(member))
		testing.expect(t, ok && read == member)
	}
}

// values[0] of a Wire and values[4] of a Start: None of a Wire, one past
// the last member and the largest word name nothing; each member comes
// back from its word, last.
@(test)
the_words_of_the_list_page_refuse_a_word_that_names_no_member :: proc(t: ^testing.T) {
	for word in ([?]u64{u64(Wire_Step.None), u64(max(Wire_Step)) + 1, max(u64)}) {
		_, ok := wire_step_of_word(word)
		testing.expectf(t, !ok, "the step %d of a Wire is taken", word)
	}
	for word in ([?]u64{u64(max(Start_Wiring_List)) + 1, max(u64)}) {
		_, ok := start_wiring_list_of_word(word)
		testing.expectf(t, !ok, "the list word %d of a Start is taken", word)
	}
	for member in ([?]Wire_Step{.List_Page, .Apply}) {
		read, ok := wire_step_of_word(u64(member))
		testing.expect(t, ok && read == member)
	}
	for member in Start_Wiring_List {
		read, ok := start_wiring_list_of_word(u64(member))
		testing.expect(t, ok && read == member)
	}
}

// values[5] of a Debug_Start: None, one past the last member, a word far
// past it and the largest word name nothing; each member comes back from
// its word, last. Only the debugger sends the command: the console, which
// starts processes, does not start one held for a debugger by itself.
@(test)
debug_start_step_of_word_refuses_a_word_that_names_no_member :: proc(t: ^testing.T) {
	for word in ([?]u64{u64(Debug_Start_Step.None), u64(max(Debug_Start_Step)) + 1, 1 << 32, max(u64)}) {
		step, ok := debug_start_step_of_word(word)
		testing.expectf(t, !ok, "the step %d of a Debug_Start is taken", word)
		testing.expect_value(t, step, Debug_Start_Step.None)
	}
	for member in ([?]Debug_Start_Step{.Start_Held, .Start_Replay, .Release, .Abandon}) {
		read, ok := debug_start_step_of_word(u64(member))
		testing.expect(t, ok && read == member)
	}
	testing.expect(t, sender_allowed(.Debug_Start, {.Debugger}))
	testing.expect(t, !sender_allowed(.Debug_Start, {.Root_Ring}))
	testing.expect(t, !sender_allowed(.Debug_Start, {.Root_Ring, .Connect, .Principals, .Start_Policy}))
	testing.expect(t, !sender_allowed(.Debug_Start, {}))
	decision := dispatch_decide(u32(Root_Command.Debug_Start), {.Root_Ring}, false)
	testing.expect_value(t, decision.step, Dispatch_Step.Sender)
	testing.expect_value(t, decision.outcome, call_outcome.Call_Outcome.Grant_Or_Right_Missing)
	refusal := errors.completion_record(decision.refusal)
	testing.expect_value(t, errors.Kind(refusal.kind), errors.Kind.No_Grant)
	testing.expect_value(t, refusal.operation, i64(Root_Command.Debug_Start))
	testing.expect_value(t, root_command_name(i64(Root_Command.Debug_Start)), "Debug_Start")
	testing.expect_value(t, root_argument_name(i64(Root_Command.Debug_Start), 1), "name")
}

// The border of a Debug_Start: a step that names nothing, then values[6]
// not 0 (1, the largest word), each refused with Argument_Refused and the
// record Bad_Value of its argument; the step is read before values[6].
// Each step with values[6] 0 passes, last.
@(test)
debug_start_border_refuses_each_word_it_does_not_take :: proc(t: ^testing.T) {
	for word in ([?]u64{u64(Debug_Start_Step.None), u64(max(Debug_Start_Step)) + 1, max(u64)}) {
		step, status, refusal := debug_start_border({5 = word})
		testing.expect_value(t, step, Debug_Start_Step.None)
		testing.expect_value(t, status, call_outcome.Call_Outcome.Argument_Refused)
		record := errors.completion_record(refusal)
		testing.expect_value(t, errors.Kind(record.kind), errors.Kind.Bad_Value)
		testing.expect_value(t, record.operation, i64(Root_Command.Debug_Start))
		testing.expect_value(t, record.argument, i64(3))
		testing.expect_value(t, record.limit, i64(max(Debug_Start_Step)))
	}
	for word in ([?]u64{1, 1 << 62, max(u64)}) {
		step, status, refusal := debug_start_border({5 = u64(Debug_Start_Step.Release), 6 = word})
		testing.expect_value(t, step, Debug_Start_Step.None)
		testing.expect_value(t, status, call_outcome.Call_Outcome.Argument_Refused)
		record := errors.completion_record(refusal)
		testing.expect_value(t, errors.Kind(record.kind), errors.Kind.Bad_Value)
		testing.expect_value(t, record.argument, i64(4))
		testing.expect_value(t, record.value, i64(min(word, 1 << 62)))
		testing.expect_value(t, record.limit, i64(0))
	}
	// A bad step with a bad values[6]: the step is the argument named.
	_, _, both := debug_start_border({5 = 0, 6 = 7})
	testing.expect_value(t, errors.completion_record(both).argument, i64(3))
	for member in ([?]Debug_Start_Step{.Start_Held, .Start_Replay, .Release, .Abandon}) {
		step, status, refusal := debug_start_border({0 = max(u64), 4 = max(u64), 5 = u64(member)})
		testing.expect_value(t, step, member)
		testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
		testing.expect_value(t, refusal, [7]u64{})
	}
}

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

// A start grant set with no start grant of ROOT_RING_GRANTS has no root ring, and
// sends no command: each start grant alone outside them is tried, then all
// of them together, then the grant Store alone, then no grant. The rule
// takes no name. That a command gives a disk process no grant of a root
// ring is the test no_command_gives_a_disk_process_a_root_ring of
// modus:disk_process.
@(test)
a_process_with_no_ring_grant_sends_no_command :: proc(t: ^testing.T) {
	without_a_ring: bit_set[start_grant.Grant]
	for grant in start_grant.Grant {
		if grant in ROOT_RING_GRANTS {
			continue
		}
		without_a_ring += {grant}
		start_grant_set := bit_set[start_grant.Grant]{grant}
		testing.expectf(t, !root_ring_given(start_grant_set), "the start grant %v gives a root ring", grant)
		for command in Root_Command {
			testing.expectf(t, !sender_allowed(command, start_grant_set), "a process with only %v sends %v", grant, command)
		}
	}
	start_grant_sets := [?]bit_set[start_grant.Grant]{{}, without_a_ring, {.Store}}
	for start_grant_set in start_grant_sets {
		testing.expect(t, !root_ring_given(start_grant_set))
		for command in Root_Command {
			testing.expectf(t, !sender_allowed(command, start_grant_set), "a process with %v and no ring sends %v", start_grant_set, command)
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
		case .Root_Ring_Or_Start_Policy:
			return grant == .Root_Ring || grant == .Start_Policy
		case .Start_Policy:
			return grant == .Start_Policy
		case .Plans:
			return grant == .Plans
		case .Screen_Capture:
			return grant == .Screen_Capture
		case .Remote_Clients:
			// A ring grant alone is never Remote_Clients, which gives no ring.
			return false
		}
		return false
	}
	for grant in ROOT_RING_GRANTS {
		start_grant_set := bit_set[start_grant.Grant]{grant}
		testing.expect(t, root_ring_given(start_grant_set))
		for command in Root_Command {
			testing.expectf(t, sender_allowed(command, start_grant_set) == expected(command, grant), "%v sends %v: %v", grant, command, sender_allowed(command, start_grant_set))
		}
	}
	// The edges of the table, by name: they are the rules of the guide.
	testing.expect(t, !sender_allowed(.None, ROOT_RING_GRANTS))
	testing.expect(t, !sender_allowed(.Principal_Unlock, {.Root_Ring}))
	testing.expect(t, !sender_allowed(.Machine_Key, {.Root_Ring, .Debugger}))
	testing.expect(t, !sender_allowed(.Debug, {.Root_Ring, .Principals}))
	// The roles of the machine come from the holder of Plans only: the
	// console and a holder of Connect never name them.
	testing.expect(t, !sender_allowed(.Plan_Roles, {.Root_Ring, .Connect, .Principals, .Debugger, .Start_Policy}))
	testing.expect(t, !sender_allowed(.Plan_Roles, {.Plans} - ROOT_RING_GRANTS))
	testing.expect(t, sender_allowed(.Plan_Roles, {.Plans}))
	// The budgets of a screen of memory grow for the service of the remote
	// display only: no console, no start policy, no holder of Connect.
	testing.expect(t, !sender_allowed(.Screen_Budget, ROOT_RING_GRANTS - {.Screen_Capture}))
	testing.expect(t, sender_allowed(.Screen_Budget, {.Screen_Capture}))
	testing.expect(t, !sender_allowed(.Start, {.Screen_Capture}))
	testing.expect(t, !sender_allowed(.Connect, {.Screen_Capture}))
	// The word of its step at its border.
	for word in ([?]u64{0, u64(max(Screen_Budget_Step)) + 1, max(u64)}) {
		_, step_ok := screen_budget_step_of_word(word)
		testing.expectf(t, !step_ok, "the step word %d was taken", word)
		_, place, words_ok := screen_budget_words_of_values({0 = word, 1 = 2560, 2 = 1440})
		testing.expect(t, !words_ok && place == 1)
	}
	// A Release names a growth: 0 is none; each word after the words of
	// a step must be 0, at its place.
	_, release_place, release_ok := screen_budget_words_of_values({0 = u64(Screen_Budget_Step.Release)})
	testing.expect(t, !release_ok && release_place == 2, "a release of growth 0 was taken")
	for place in 2 ..< 7 {
		for word in ([?]u64{1, max(u64)}) {
			values := [7]u64{0 = u64(Screen_Budget_Step.Release), 1 = 4}
			values[place] = word
			_, refused, ok := screen_budget_words_of_values(values)
			testing.expectf(t, !ok && refused == place + 1, "a release with %d at %d was taken", word, place)
		}
	}
	for place in 3 ..< 7 {
		values := [7]u64{0 = u64(Screen_Budget_Step.Grow), 1 = 2560, 2 = 1440}
		values[place] = 1
		_, refused, ok := screen_budget_words_of_values(values)
		testing.expectf(t, !ok && refused == place + 1, "a growth with a word at %d was taken", place)
	}
	grow, _, grow_ok := screen_budget_words_of_values({0 = u64(Screen_Budget_Step.Grow), 1 = 2560, 2 = 1440})
	testing.expect(t, grow_ok && grow == {step = .Grow, width = 2560, height = 1440})
	release, _, last_ok := screen_budget_words_of_values({0 = u64(Screen_Budget_Step.Release), 1 = max(u64)})
	testing.expect(t, last_ok && release == {step = .Release, growth = max(u64)})
	testing.expect(t, !sender_allowed(.Start, {.Plans}))
	testing.expect(t, !sender_allowed(.Connect, {.Plans}))
	testing.expect(t, !sender_allowed(.Start, {.Connect, .Principals, .Debugger}))
	testing.expect(t, sender_allowed(.Disconnect, {.Principals}))
	testing.expect(t, sender_allowed(.Connect, {.Connect}))
	testing.expect(t, sender_allowed(.Start, {.Root_Ring}))
	// The start policy: Machine_Usable from it alone, never from the
	// console or another ring; Start and Stop, and no other command of the
	// console.
	testing.expect(t, !sender_allowed(.Machine_Usable, {.Root_Ring, .Connect, .Principals, .Debugger}))
	testing.expect(t, !sender_allowed(.Grants, {.Start_Policy}))
	testing.expect(t, !sender_allowed(.Revoke, {.Start_Policy}))
	testing.expect(t, !sender_allowed(.Start_From_Disk, {.Start_Policy}))
	testing.expect(t, !sender_allowed(.Connect, {.Start_Policy}))
	// A start policy never chooses the start policy of the next start:
	// only the console of principal 0 does.
	testing.expect(t, !sender_allowed(.Start_Policy_Choice, {.Start_Policy}))
	testing.expect(t, !sender_allowed(.Start_Policy_Choice, {.Connect, .Principals, .Debugger, .Start_Policy}))
	testing.expect(t, sender_allowed(.Start_Policy_Choice, {.Root_Ring}))
	testing.expect(t, sender_allowed(.Start, {.Start_Policy}))
	testing.expect(t, sender_allowed(.Stop, {.Start_Policy}))
	testing.expect(t, sender_allowed(.Machine_Usable, {.Start_Policy}))
	// A wiring comes from the console or the start policy, which start the
	// processes that it names, and from no other ring.
	testing.expect(t, !sender_allowed(.Wire, {.Connect, .Principals, .Debugger}))
	testing.expect(t, !sender_allowed(.Wire, {}))
	testing.expect(t, sender_allowed(.Wire, {.Root_Ring}))
	testing.expect(t, sender_allowed(.Wire, {.Start_Policy}))
	// A refused Connect names the connection; another command the commands.
	connect := errors.completion_record(sender_refusal(.Connect))
	testing.expect_value(t, errors.Kind(connect.kind), errors.Kind.No_Grant)
	testing.expect_value(t, errors.Unit(connect.unit), errors.Unit.Connection)
	start := errors.completion_record(sender_refusal(.Start))
	testing.expect_value(t, errors.Kind(start.kind), errors.Kind.No_Grant)
	testing.expect_value(t, errors.Unit(start.unit), errors.Unit.Root_Commands)
	testing.expect_value(t, start.operation, i64(Root_Command.Start))
}

// The start policy receives its root ring and the log, and no window: it
// starts before the compositor. A start grant set with the grant beside another grant
// gets no window either, and each other start grant set with no Terminal keeps its
// window.
@(test)
the_start_policy_has_no_window :: proc(t: ^testing.T) {
	testing.expect_value(t, start_grant_set_handles({.Start_Policy}), bit_set[Start_Grant_Set_Handle]{.Log, .Root_Ring})
	testing.expect(t, .Display not_in start_grant_set_handles({.Start_Policy, .Inspect}))
	testing.expect(t, .Display in start_grant_set_handles({}))
	testing.expect(t, .Display in start_grant_set_handles({.Root_Ring}))
	testing.expect(t, .Display not_in start_grant_set_handles({.Terminal}))
}

// The decision of the dispatch, in the order of its steps. The border
// comes first: each word that names no command stops there with the
// record Unsupported, for each start grant set, the start grant set of the console too. Then the
// sender: a start grant set with no grant of a ring, each command; a Connect with the
// grant Connect to a service that its list does not name, with the unit
// Connection; a command of the principals from the console. A decision
// with the same inputs is the same decision. The commands that run come
// last.
@(test)
the_dispatch_refuses_at_its_first_step_that_refuses :: proc(t: ^testing.T) {
	console_start_grant_set := bit_set[start_grant.Grant]{.Root_Ring, .Inspect, .Stop, .Image, .Terminal, .Store}
	words := [?]u32{u32(Root_Command.None), u32(max(Root_Command)) + 1, 1 << 16, max(u32)}
	start_grant_sets := [?]bit_set[start_grant.Grant]{{}, console_start_grant_set, ROOT_RING_GRANTS}
	for word in words {
		for start_grant_set in start_grant_sets {
			for listed in ([2]bool{false, true}) {
				decision := dispatch_decide(word, start_grant_set, listed)
				testing.expect_value(t, decision.step, Dispatch_Step.Border)
				testing.expect_value(t, decision.command, Root_Command.None)
				testing.expect_value(t, decision.outcome, call_outcome.Call_Outcome.Operation_Unsupported)
				testing.expect_value(t, decision.refusal, command_refusal(word))
			}
		}
	}
	for command in Root_Command {
		if command == .None {
			continue
		}
		for start_grant_set in ([2]bit_set[start_grant.Grant]{{}, {.Store, .Image, .Serve}}) {
			decision := dispatch_decide(u32(command), start_grant_set, true)
			testing.expectf(t, decision.step == .Sender, "a start grant set with no ring sends %v", command)
			testing.expect_value(t, decision.outcome, call_outcome.Call_Outcome.Grant_Or_Right_Missing)
			testing.expect_value(t, decision.refusal, sender_refusal(command))
			testing.expect_value(t, decision, dispatch_decide(u32(command), start_grant_set, true))
		}
	}
	unlisted := dispatch_decide(u32(Root_Command.Connect), {.Connect}, false)
	testing.expect_value(t, unlisted.step, Dispatch_Step.Sender)
	record := errors.completion_record(unlisted.refusal)
	testing.expect_value(t, errors.Kind(record.kind), errors.Kind.No_Grant)
	testing.expect_value(t, errors.Unit(record.unit), errors.Unit.Connection)
	testing.expect_value(t, dispatch_decide(u32(Root_Command.Principal_Unlock), console_start_grant_set, true).step, Dispatch_Step.Sender)
	testing.expect_value(t, dispatch_decide(u32(Root_Command.Debug), console_start_grant_set, true).step, Dispatch_Step.Sender)
	// The commands that run: Connect from the console names any service,
	// and from the grant Connect a listed one; Disconnect from each ring.
	runs := [?]struct {
		command: Root_Command,
		start_grant_set:    bit_set[start_grant.Grant],
		listed:  bool,
	}{{.Connect, console_start_grant_set, false}, {.Connect, {.Connect}, true}, {.Disconnect, {.Principals}, false}, {.Start, console_start_grant_set, false}, {.Principal_Unlock, {.Principals}, false}, {.Debug, {.Debugger}, false}}
	for case_of in runs {
		decision := dispatch_decide(u32(case_of.command), case_of.start_grant_set, case_of.listed)
		testing.expectf(t, decision.step == .Command, "%v from %v does not run", case_of.command, case_of.start_grant_set)
		testing.expect_value(t, decision.command, case_of.command)
		testing.expect_value(t, decision.outcome, call_outcome.Call_Outcome.Succeeded)
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

// refuse writes the record of its kind and its values in the values of a
// completion, with the command as the operation, and gives the outcome
// that the caller named. The edges of the values come first: the largest
// and the smallest words; then a record of each field, last.
@(test)
refuse_writes_the_record_and_gives_its_outcome :: proc(t: ^testing.T) {
	values: [7]u64
	outcome := refuse(&values, .Nothing_Has_That_Name, u32(Root_Command.Stop), .Absent, .Processes, 1, max(i64), min(i64), -1)
	testing.expect_value(t, outcome, call_outcome.Call_Outcome.Nothing_Has_That_Name)
	record := errors.completion_record(values)
	testing.expect_value(t, errors.Kind(record.kind), errors.Kind.Absent)
	testing.expect_value(t, errors.Unit(record.unit), errors.Unit.Processes)
	testing.expect_value(t, record.operation, i64(Root_Command.Stop))
	testing.expect_value(t, record.argument, i64(1))
	testing.expect_value(t, record.value, max(i64))
	testing.expect_value(t, record.limit, min(i64))
	testing.expect_value(t, record.found, i64(-1))
	read, read_record := call_outcome.completion_outcome(u32(outcome), values)
	testing.expect_value(t, read, call_outcome.Call_Outcome.Nothing_Has_That_Name)
	testing.expect_value(t, read_record, record)
}

// The border of each root command that the root service reads, as it
// calls it: the enumeration, the command and the argument of its record.
// Each word that names no member gives Argument_Refused and the record
// Bad_Value of that command and argument, with the word (at most 2^62)
// and the largest member; the values of the command do not change. The
// members come last, with Succeeded and no record.
@(test)
a_root_command_refuses_a_word_that_names_no_member :: proc(t: ^testing.T) {
	refuse_each :: proc(t: ^testing.T, $Enum: typeid, command: Root_Command, argument: i64, place: int, words: []u64) {
		for word in words {
			values: [7]u64
			values[place] = word
			before := values
			member, status, refusal := member_of_word(Enum, values[place], command, argument)
			testing.expectf(t, status == .Argument_Refused, "%v: the word %d names no member, and the outcome is %v", typeid_of(Enum), word, status)
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
			testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
			testing.expect_value(t, read, member)
			testing.expect_value(t, refusal, [7]u64{})
		}
	}
	refuse_each(t, Remote_Client_Action, .Remote_Client, 2, 4, {0, u64(max(Remote_Client_Action)) + 1, 1 << 62 + 1, max(u64)})
	refuse_each(t, Disk_Grant_Action, .Disk_Grant, 0, 4, {0, u64(max(Disk_Grant_Action)) + 1, max(u64)})
	refuse_each(t, Principal_Change, .Principal_Change, 2, 4, {0, u64(max(Principal_Change)) + 1, max(u64)})
	refuse_each(t, Principal_Key_Origin, .Principal_Unlock, 0, 5, {0, u64(max(Principal_Key_Origin)) + 1, max(u64)})
	refuse_each(t, Remote_Client_State, .Remote_Client, 2, 6, {u64(max(Remote_Client_State)) + 1, max(u64)})
	refuse_each(t, Machine_Key_Form, .Machine_Key, 2, 5, {u64(max(Machine_Key_Form)) + 1, max(u64)})
	accept_each(t, Remote_Client_Action, .Remote_Client, 2)
	accept_each(t, Disk_Grant_Action, .Disk_Grant, 0)
	accept_each(t, Principal_Change, .Principal_Change, 2)
	accept_each(t, Principal_Key_Origin, .Principal_Unlock, 0)
	accept_each(t, Remote_Client_State, .Remote_Client, 2)
	accept_each(t, Machine_Key_Form, .Machine_Key, 2)
}

// The border of Machine_Key: a state that names no member, and for
// .Awaited a form that names no member, give Argument_Refused and an empty
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
		testing.expect_value(t, status, call_outcome.Call_Outcome.Argument_Refused)
		testing.expect_value(t, report, Machine_Key_Report{})
		testing.expect_value(t, values, before)
	}
	for form in Machine_Key_Form {
		report, status := machine_key_report_of_values({4 = u64(Machine_Key_State.Awaited), 5 = u64(form)})
		testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
		testing.expect_value(t, report, Machine_Key_Report{state = .Awaited, form = form})
	}
	others := [?]Machine_Key_State{.Opened, .New, .Unreadable}
	for state in others {
		// values[5] is not read: a word of no form changes nothing.
		report, status := machine_key_report_of_values({4 = u64(state), 5 = max(u64)})
		testing.expect_value(t, status, call_outcome.Call_Outcome.Succeeded)
		testing.expect_value(t, report.state, state)
	}
}

// The refusal record of a Replace is read back by its named fields, never
// by the place of a field. First the records that no reason writes: the
// record of another command, a kind or a unit word that names no member, a
// list problem past the last member or None, a pair of an outcome and a
// kind that the contract does not write. Then each reason at its edges:
// an entry past an image of 0 entries and past the largest word, each
// problem of a list, a table of capacity 0 and of the largest capacity.
@(test)
the_refusal_of_a_replace_is_read_by_its_named_fields :: proc(t: ^testing.T) {
	refused := [?]struct {
		outcome: call_outcome.Call_Outcome,
		record:  errors.Error_Record,
		about:   string,
	} {
		{.Wrong_State, errors.completion_record(errors.ring_fail(u32(Root_Command.Start), .State, .Records, 2)), "a record of Start"},
		{.Data_Damaged, {kind = 9999, unit = i64(errors.Unit.Records), operation = i64(Root_Command.Replace)}, "a kind of no member"},
		{.Data_Damaged, {kind = i64(errors.Kind.Damaged), unit = 9999, operation = i64(Root_Command.Replace)}, "a unit of no member"},
		{.Data_Damaged, errors.completion_record(errors.ring_fail(u32(Root_Command.Replace), .Damaged, .Records, 2, 3, 0, i64(max(replacement_list.List_Problem)) + 1)), "a problem past the last"},
		{.Data_Damaged, errors.completion_record(errors.ring_fail(u32(Root_Command.Replace), .Damaged, .Records, 2, 3, 0, -1)), "a negative problem"},
		{.Argument_Refused, errors.completion_record(errors.ring_fail(u32(Root_Command.Replace), .Bad_Value, .Modules, 1)), "a module of argument 1"},
		{.Callee_Busy, errors.completion_record(errors.ring_fail(u32(Root_Command.Replace), .Full, .Records)), "a full table under another outcome"},
	}
	for item in refused {
		_, _, ok := replace_refusal_of_record(item.outcome, item.record)
		testing.expectf(t, !ok, "%s is read as a refusal of a Replace", item.about)
	}
	Case :: struct {
		refusal:     Replace_Refusal,
		by:          u64,
		entry_count: u64,
		problem:     replacement_list.List_Problem,
		capacity:    i64,
	}
	cases := make([dynamic]Case, context.temp_allocator)
	append(&cases, Case{refusal = .Entry_Past_The_Image, by = 1, entry_count = 0}, Case{refusal = .Entry_Past_The_Image, by = max(u64), entry_count = 12})
	append(&cases, Case{refusal = .Table_Full, capacity = 0}, Case{refusal = .Table_Full, capacity = max(i64)})
	for problem in replacement_list.List_Problem {
		if problem != .None {
			append(&cases, Case{refusal = .List_Not_Valid, by = 3, entry_count = 12, problem = problem})
		}
	}
	for refusal in Replace_Refusal {
		append(&cases, Case{refusal = refusal, by = 3, entry_count = 12, problem = .Magic, capacity = 64})
	}
	for item in cases {
		outcome, values := replace_refusal_record(item.refusal, item.by, item.entry_count, item.problem, item.capacity)
		record := errors.completion_record(values)
		testing.expect_value(t, outcome, REPLACE_REFUSAL_OUTCOMES[item.refusal])
		testing.expectf(t, errors.Kind(record.kind) in call_outcome.KINDS_OF[outcome], "%v: the kind %v does not explain %v", item.refusal, record.kind, outcome)
		read, problem, ok := replace_refusal_of_record(outcome, record)
		testing.expectf(t, ok && read == item.refusal, "%v is read as %v (%v)", item.refusal, read, ok)
		if item.refusal == .List_Not_Valid {
			testing.expect_value(t, problem, item.problem)
		}
		if item.refusal == .Entry_Past_The_Image {
			testing.expect_value(t, record.value, i64(min(item.by, 1 << 62)))
			testing.expect_value(t, record.limit, i64(item.entry_count))
		}
		if item.refusal == .Table_Full {
			testing.expect_value(t, record.limit, item.capacity)
		}
	}
}

// The word of a screen of memory: 0 is none; a side of 0, one past each
// bound and the largest word are refused; the least and the largest size
// read back.
@(test)
a_screen_of_memory_word_at_its_edges :: proc(t: ^testing.T) {
	width, height, ok := screen_of_memory_of_word(0)
	testing.expect(t, ok && width == 0 && height == 0)
	refused := [?]u64{screen_of_memory_word(1920, 0), screen_of_memory_word(0, 1080), screen_of_memory_word(319, 240), screen_of_memory_word(320, 239), screen_of_memory_word(7681, 4320), screen_of_memory_word(7680, 4321), max(u64)}
	for word in refused {
		_, _, taken := screen_of_memory_of_word(word)
		testing.expectf(t, !taken, "the word %x was taken", word)
	}
	for size in ([?][2]u32{{320, 240}, {1920, 1080}, {7680, 4320}}) {
		width, height, ok = screen_of_memory_of_word(screen_of_memory_word(size[0], size[1]))
		testing.expect(t, ok && width == size[0] && height == size[1])
	}
}

// The commands of the path of a wide grant: the proof comes from the
// holder of Principals alone, the ask and the end from a root ring; the
// outcome of a proof refuses None, one past the last member and the
// largest word before it takes each member.
@(test)
the_wide_grant_commands_keep_their_senders :: proc(t: ^testing.T) {
	testing.expect(t, !sender_allowed(.Wide_Grant_Proof, {.Root_Ring, .Connect, .Debugger, .Start_Policy, .Plans}))
	testing.expect(t, sender_allowed(.Wide_Grant_Proof, {.Principals}))
	for command in ([2]Root_Command{.Wide_Grant_Ask, .Wide_Grant_End}) {
		testing.expect(t, !sender_allowed(command, {.Principals, .Connect, .Debugger, .Start_Policy, .Plans}))
		testing.expect(t, sender_allowed(command, {.Root_Ring}))
	}
	// The ask of an agent and its second connection come from the holder of
	// Remote_Clients with a root ring only: a console, and Remote_Clients
	// with no root ring, send neither.
	for command in ([2]Root_Command{.Wide_Grant_Agent_Ask, .Wide_Grant_Second_Connection}) {
		testing.expect(t, !sender_allowed(command, {.Root_Ring, .Principals, .Connect, .Debugger, .Start_Policy, .Plans}))
		testing.expect(t, !sender_allowed(command, {.Remote_Clients}))
		testing.expect(t, sender_allowed(command, {.Connect, .Remote_Clients}))
	}
	for word in ([?]u64{0, u64(max(Wide_Grant_Proof_Outcome)) + 1, max(u64)}) {
		_, ok := wide_grant_proof_outcome_of_word(word)
		testing.expectf(t, !ok, "the outcome word %d is taken", word)
	}
	for outcome in Wide_Grant_Proof_Outcome {
		if outcome == .None {
			continue
		}
		read, ok := wide_grant_proof_outcome_of_word(u64(outcome))
		testing.expect(t, ok && read == outcome)
	}
}
// Ready travels on the ready ring alone: the root ring refuses it at its
// sender, whatever the start grants, so the one way to say the first
// state of work is the same for each process. The word one past Ready
// names no command.
@(test)
ready_never_runs_on_the_root_ring :: proc(t: ^testing.T) {
	for grant in ROOT_RING_GRANTS {
		decision := dispatch_decide(u32(Root_Command.Ready), {grant}, true)
		testing.expectf(t, decision.step == .Sender, "Ready on the root ring with the start grant %v", grant)
	}
	testing.expect_value(t, root_command_name(i64(Root_Command.Ready)), "Ready")
	past := dispatch_decide(u32(Root_Command.Ready) + 1, {.Root_Ring}, false)
	testing.expect_value(t, past.step, Dispatch_Step.Border)
}

// The ready ring carries Ready with each value 0, and refuses each other
// record: another kind, None, a word past the last command, and a Ready
// with one value that is not 0, in the first place, the last, and the
// largest word.
@(test)
the_ready_ring_takes_ready_alone :: proc(t: ^testing.T) {
	testing.expect(t, !ready_record_refused({kind = u32(Root_Command.Ready)}))
	testing.expect(t, !ready_record_refused({kind = u32(Root_Command.Ready), tag = 7}), "the tag is no value")
	testing.expect(t, ready_record_refused({}))
	testing.expect(t, ready_record_refused({kind = u32(Root_Command.Start)}))
	testing.expect(t, ready_record_refused({kind = u32(Root_Command.Ready) + 1}))
	testing.expect(t, ready_record_refused({kind = max(u32)}))
	testing.expect(t, ready_record_refused({kind = u32(Root_Command.Ready), values = {0 = 1}}))
	testing.expect(t, ready_record_refused({kind = u32(Root_Command.Ready), values = {6 = 1}}))
	testing.expect(t, ready_record_refused({kind = u32(Root_Command.Ready), values = {3 = max(u64)}}))
}

// A model of the starter over a ready ring: each pass reads the step, and
// each step but Wait closes the ring with one line, so no later pass reads
// it. A ring never written waits; a Ready, a wrong record, a false count
// and a count that moves with no record each end it after one pass.
@(test)
the_ready_ring_ends_after_one_line :: proc(t: ^testing.T) {
	Model :: struct {
		memory: [2 * ring.PAGE_SIZE]u8,
		mapped: ring.Ring,
		open:   bool,
		lines:  int,
		passes: int,
	}
	pass :: proc(model: ^Model) -> Ready_Ring_Step {
		if !model.open {
			return .Wait
		}
		model.passes += 1
		_, step := ready_ring_step(&model.mapped.commands)
		if step != .Wait {
			if step != .Ready {
				model.lines += 1
			}
			model.open = false
		}
		return step
	}
	start :: proc(model: ^Model) {
		model^ = {}
		mapped, opened := ring.open(&model.memory[0], 2)
		assert(opened)
		model.mapped, model.open = mapped, true
	}
	model := new(Model, context.temp_allocator)
	start(model)
	testing.expect_value(t, pass(model), Ready_Ring_Step.Wait)
	testing.expect_value(t, pass(model), Ready_Ring_Step.Wait)
	testing.expect(t, model.open && model.lines == 0, "a ring never written waits")
	testing.expect(t, ring.push(&model.mapped.commands, ring.Record{kind = u32(Root_Command.Ready)}))
	testing.expect_value(t, pass(model), Ready_Ring_Step.Ready)
	testing.expect(t, !model.open && model.lines == 0)
	start(model)
	testing.expect(t, ring.push(&model.mapped.commands, ring.Record{kind = u32(Root_Command.Start)}))
	testing.expect_value(t, pass(model), Ready_Ring_Step.Refused_Record)
	start(model)
	model.mapped.head.commands.write = u32(ring.CAPACITY) + 1
	testing.expect_value(t, pass(model), Ready_Ring_Step.Counters_Refused)
	before := model.passes
	testing.expect_value(t, pass(model), Ready_Ring_Step.Wait)
	testing.expect(t, model.passes == before && model.lines == 1, "one line, and no second pass")
	start(model)
	model.mapped.head.commands.write = 1
	model.mapped.head.commands.read = 1
	testing.expect_value(t, pass(model), Ready_Ring_Step.Write_With_No_Record)
	testing.expect(t, !model.open && model.lines == 1)
}

// A push by an honest process between the reads of ready_ring_step never
// gives Write_With_No_Record:
// 1. Push between the initial write load (0) and pop: pop returns Ready.
// 2. Push between a failed pop and the refusal checks: returns Wait, and
//    the next ready_ring_step returns Ready.
// Refusal edges: write == read == max(u32), write == 1 reset to 0 before
// pop, write behind read (0, 1), and write == max(u32) with read == 0.
@(test)
a_push_between_ready_ring_reads_is_never_write_with_no_record :: proc(t: ^testing.T) {
	memory := new([2 * ring.PAGE_SIZE]u8, context.temp_allocator)
	fresh :: proc(memory: ^[2 * ring.PAGE_SIZE]u8) -> ring.Ring {
		memory^ = {}
		mapped, opened := ring.open(&memory[0], 2)
		assert(opened)
		return mapped
	}

	// Refusal edges first.
	mapped := fresh(memory)
	mapped.head.commands.write, mapped.head.commands.read = max(u32), max(u32)
	_, step := ready_ring_step(&mapped.commands)
	testing.expect_value(t, step, Ready_Ring_Step.Write_With_No_Record)

	mapped = fresh(memory)
	mapped.head.commands.write, mapped.head.commands.read = 0, 1
	_, step = ready_ring_step(&mapped.commands)
	testing.expect_value(t, step, Ready_Ring_Step.Counters_Refused)

	mapped = fresh(memory)
	mapped.head.commands.write, mapped.head.commands.read = max(u32), 0
	_, step = ready_ring_step(&mapped.commands)
	testing.expect_value(t, step, Ready_Ring_Step.Counters_Refused)

	// Hostile writer sets write = 1 before ready_ring_step, then resets
	// write = 0 before pop: write_before was non-zero and pop fails.
	mapped = fresh(memory)
	_, step = ready_ring_step_from_write(&mapped.commands, 1)
	testing.expect_value(t, step, Ready_Ring_Step.Write_With_No_Record)

	// Interleaving 1: write loaded as 0, then honest push happens before pop.
	mapped = fresh(memory)
	write_before := intrinsics.atomic_load_explicit(&mapped.commands.counters.write, .Acquire)
	testing.expect_value(t, write_before, u32(0))
	testing.expect(t, ring.push(&mapped.commands, ring.Record{kind = u32(Root_Command.Ready), tag = 9}))
	record, step_between := ready_ring_step_from_write(&mapped.commands, write_before)
	testing.expect_value(t, step_between, Ready_Ring_Step.Ready)
	testing.expect_value(t, record.tag, u32(9))

	// Interleaving 2: write loaded as 0, pop returns false, then honest push
	// lands before ready_ring_step_after_pop.
	mapped = fresh(memory)
	write_before = intrinsics.atomic_load_explicit(&mapped.commands.counters.write, .Acquire)
	_, popped := ring.pop(&mapped.commands)
	testing.expect(t, !popped)
	testing.expect(t, ring.push(&mapped.commands, ring.Record{kind = u32(Root_Command.Ready), tag = 11}))
	step_after := ready_ring_step_after_pop(&mapped.commands, write_before)
	testing.expect_value(t, step_after, Ready_Ring_Step.Wait)
	// Next pass pops the Ready record cleanly.
	record, step = ready_ring_step(&mapped.commands)
	testing.expect_value(t, step, Ready_Ring_Step.Ready)
	testing.expect_value(t, record.tag, u32(11))
}

// Two threads racing an honest Ready push against ready_ring_step across
// many fresh rings: every round sees only Wait followed by Ready, never
// Write_With_No_Record, Counters_Refused or Refused_Record.
@(test)
concurrent_honest_ready_pushes_never_refuse :: proc(t: ^testing.T) {
	ROUNDS :: u32(10_000)
	STALL_BOUND_MS :: 60_000
	Race :: struct {
		memory:     [2 * ring.PAGE_SIZE]u8,
		mapped:     ring.Ring,
		stage:      u32, // 0: reader resetting, 1: round active, 2: done.
		round:      u32,
		bad_steps:  u32,
		ready_seen: u32,
		progress:   u32,
		abandoned:  bool,
	}
	race := new(Race)
	defer free(race)
	opened: bool
	race.mapped, opened = ring.open(&race.memory[0], 2)
	testing.expect(t, opened)

	writer_proc :: proc(race: ^Race) {
		since := time.tick_now()
		last := intrinsics.atomic_load(&race.progress)
		for {
			stage := intrinsics.atomic_load_explicit(&race.stage, .Acquire)
			if stage == 2 || intrinsics.atomic_load(&race.abandoned) {
				return
			}
			if stage == 1 {
				round := intrinsics.atomic_load_explicit(&race.round, .Acquire)
				_ = ring.push(&race.mapped.commands, ring.Record{kind = u32(Root_Command.Ready), tag = round})
				intrinsics.atomic_store_explicit(&race.stage, 0, .Release)
				intrinsics.atomic_add(&race.progress, 1)
				continue
			}
			now_progress := intrinsics.atomic_load(&race.progress)
			if now_progress != last {
				last = now_progress
				since = time.tick_now()
			} else if time.duration_milliseconds(time.tick_since(since)) > STALL_BOUND_MS {
				intrinsics.atomic_store(&race.abandoned, true)
				return
			}
			intrinsics.cpu_relax()
		}
	}

	worker := thread.create_and_start_with_poly_data(race, writer_proc)
	since := time.tick_now()
	last := intrinsics.atomic_load(&race.progress)
	for round in u32(0) ..< ROUNDS {
		// Reset counters while writer waits on stage == 0.
		for intrinsics.atomic_load_explicit(&race.stage, .Acquire) != 0 {
			if intrinsics.atomic_load(&race.abandoned) {
				break
			}
			intrinsics.cpu_relax()
		}
		if intrinsics.atomic_load(&race.abandoned) {
			break
		}
		race.mapped.head.commands.write = 0
		race.mapped.head.commands.read = 0
		intrinsics.atomic_store_explicit(&race.round, round, .Release)
		intrinsics.atomic_store_explicit(&race.stage, 1, .Release)
		for {
			record, step := ready_ring_step(&race.mapped.commands)
			if step == .Ready {
				if record.tag != round {
					race.bad_steps += 1
				}
				race.ready_seen += 1
				intrinsics.atomic_add(&race.progress, 1)
				break
			}
			if step != .Wait {
				race.bad_steps += 1
				break
			}
			now_progress := intrinsics.atomic_load(&race.progress)
			if now_progress != last {
				last = now_progress
				since = time.tick_now()
			} else if time.duration_milliseconds(time.tick_since(since)) > STALL_BOUND_MS {
				intrinsics.atomic_store(&race.abandoned, true)
				break
			}
			intrinsics.cpu_relax()
		}
		if race.bad_steps != 0 || intrinsics.atomic_load(&race.abandoned) {
			break
		}
	}
	intrinsics.atomic_store_explicit(&race.stage, 2, .Release)
	thread.join(worker)
	thread.destroy(worker)
	testing.expect(t, !race.abandoned, "the concurrent ready ring race stalled")
	testing.expect_value(t, race.bad_steps, u32(0))
	testing.expect_value(t, race.ready_seen, ROUNDS)
}
