#+build !freestanding
package conversation

import "core:strings"
import "core:testing"
import assistant_contract "modus:contract/assistant"
import "modus:contract/errors"

@(private = "file")
expect_refusal :: proc(t: ^testing.T, result: i64, error: errors.Error_Record, kind: errors.Kind, argument: i64 = -1, location := #caller_location) {
	testing.expect_value(t, result, i64(ERROR_RESULT), location)
	testing.expect_value(t, error.kind, i64(kind), location)
	if argument >= 0 {
		testing.expect_value(t, error.argument, argument, location)
	}
}

// A conversation with one request, taken, so a test starts at the reply.
@(private = "file")
taken_conversation :: proc(t: ^testing.T) -> ^Conversation {
	talk := new(Conversation, context.temp_allocator)
	testing.expect(t, request_keep(talk, "which processes run") != nil)
	buffer: [assistant_contract.REQUEST_TEXT_BYTES]u8
	error: errors.Error_Record
	count, taken := request_text(talk, true, 1, buffer[:], &error)
	testing.expect_value(t, count, 19)
	testing.expect(t, taken != nil)
	return talk
}

// The serials that name no request: 0, -1, one past the last, the largest.
@(private = "file")
BAD_SERIALS :: [?]i64{0, -1, 2, max(i64), min(i64)}

// Each export refuses a caller that does not act for the principal, the
// call of no connection too, and changes nothing.
@(test)
each_border_refuses_a_caller_that_does_not_act_for_the_principal :: proc(t: ^testing.T) {
	talk := taken_conversation(t)
	before := talk.entry_count
	error: errors.Error_Record
	buffer: [assistant_contract.REQUEST_TEXT_BYTES]u8
	expect_refusal(t, request_serial(talk, false, &error), error, .No_Grant)
	count, taken := request_text(talk, false, 1, buffer[:], &error)
	expect_refusal(t, count, error, .No_Grant)
	testing.expect(t, taken == nil)
	result, kept := reply(talk, false, 1, "hi", 0, &error)
	expect_refusal(t, result, error, .No_Grant)
	testing.expect(t, kept == nil)
	result, kept = reply_refused(talk, false, 1, i64(errors.Kind.Bad_Value), i64(errors.Unit.Bytes), 1, 0, 0, &error)
	expect_refusal(t, result, error, .No_Grant)
	result, kept = act(talk, false, 1, 1, "monitor.processes()", "monitor", "processes", &error)
	expect_refusal(t, result, error, .No_Grant)
	result, kept = act_result(talk, false, 1, 2, "done", &error)
	expect_refusal(t, result, error, .No_Grant)
	expect_refusal(t, act_state(talk, false, 1, &error), error, .No_Grant)
	testing.expect_value(t, talk.entry_count, before)
	testing.expect_value(t, talk.entries[0].turn, Turn_State.Waiting)
}

// request_text: a serial that names no request, and a result with less
// room than the text, which takes nothing; one byte of room more passes.
@(test)
request_text_refuses_a_serial_and_a_result_too_small :: proc(t: ^testing.T) {
	talk := new(Conversation, context.temp_allocator)
	request_keep(talk, "abcd")
	error: errors.Error_Record
	buffer: [8]u8
	for serial in BAD_SERIALS {
		count, _ := request_text(talk, true, serial, buffer[:], &error)
		expect_refusal(t, count, error, .Absent, 1)
	}
	count, taken := request_text(talk, true, 1, buffer[:3], &error)
	expect_refusal(t, count, error, .Too_Long, 0)
	testing.expect_value(t, error.value, 4)
	testing.expect_value(t, error.limit, 3)
	testing.expect(t, taken == nil && !talk.entries[0].taken)
	testing.expect_value(t, request_serial(talk, true, &error), 1)
	count, taken = request_text(talk, true, 1, buffer[:4], &error)
	testing.expect_value(t, count, 4)
	testing.expect(t, taken != nil)
	testing.expect_value(t, request_serial(talk, true, &error), 0)
	// A second read gives the text and takes nothing more.
	count, taken = request_text(talk, true, 1, buffer[:], &error)
	testing.expect(t, count == 4 && taken == nil)
}

// reply: a serial not taken or of no request, a text of 0 and 1025 bytes
// and with a control byte, a count of acts under 0 and over 4, a second
// reply: each is refused and changes nothing.
@(test)
reply_refuses_each_bad_input_and_comes_once :: proc(t: ^testing.T) {
	talk := taken_conversation(t)
	request_keep(talk, "not taken")
	error: errors.Error_Record
	for serial in BAD_SERIALS {
		result, _ := reply(talk, true, serial, "hi", 0, &error)
		expect_refusal(t, result, error, .Absent, 1)
	}
	long := strings.repeat("a", assistant_contract.REPLY_TEXT_BYTES + 1, context.temp_allocator)
	result, _ := reply(talk, true, 1, long, 0, &error)
	expect_refusal(t, result, error, .Too_Long, 2)
	result, _ = reply(talk, true, 1, "", 0, &error)
	expect_refusal(t, result, error, .Empty, 2)
	result, _ = reply(talk, true, 1, "a\nb", 0, &error)
	expect_refusal(t, result, error, .Bad_Value, 2)
	for acts in ([?]i64{-1, min(i64)}) {
		result, _ = reply(talk, true, 1, "hi", acts, &error)
		expect_refusal(t, result, error, .Bad_Value, 3)
	}
	for acts in ([?]i64{assistant_contract.MODEL_ACT_CAPACITY + 1, max(i64)}) {
		result, _ = reply(talk, true, 1, "hi", acts, &error)
		expect_refusal(t, result, error, .Too_Long, 3)
	}
	testing.expect_value(t, talk.entry_count, 2)
	testing.expect_value(t, talk.entries[0].turn, Turn_State.Waiting)
	most := strings.repeat("a", assistant_contract.REPLY_TEXT_BYTES, context.temp_allocator)
	kept: ^Entry
	result, kept = reply(talk, true, 1, most, assistant_contract.MODEL_ACT_CAPACITY, &error)
	testing.expect_value(t, result, i64(assistant_contract.REPLY_TEXT_BYTES))
	testing.expect(t, kept != nil && kept.kind == .Reply)
	result, _ = reply(talk, true, 1, "again", 0, &error)
	expect_refusal(t, result, error, .State, 1)
	result, _ = reply_refused(talk, true, 1, i64(errors.Kind.Bad_Value), i64(errors.Unit.Bytes), 1, 0, 0, &error)
	expect_refusal(t, result, error, .State, 1)
}

// reply_refused: a serial of no request, a kind that names no member and
// the kind None, a unit that names no member; it ends the turn.
@(test)
reply_refused_refuses_each_bad_word_and_ends_the_turn :: proc(t: ^testing.T) {
	talk := taken_conversation(t)
	error: errors.Error_Record
	bad_value, bytes := i64(errors.Kind.Bad_Value), i64(errors.Unit.Bytes)
	for serial in BAD_SERIALS {
		result, _ := reply_refused(talk, true, serial, bad_value, bytes, 1, 0, 0, &error)
		expect_refusal(t, result, error, .Absent, 1)
	}
	for kind in ([?]i64{i64(errors.Kind.None), -1, 9999, max(i64)}) {
		result, _ := reply_refused(talk, true, 1, kind, bytes, 1, 0, 0, &error)
		expect_refusal(t, result, error, .Bad_Value, 2)
	}
	for unit in ([?]i64{-1, 9999, max(i64)}) {
		result, _ := reply_refused(talk, true, 1, bad_value, unit, 1, 0, 0, &error)
		expect_refusal(t, result, error, .Bad_Value, 3)
	}
	testing.expect_value(t, talk.entry_count, 1)
	result, kept := reply_refused(talk, true, 1, bad_value, bytes, 3, 0, 0, &error)
	testing.expect(t, result == 1 && kept != nil)
	testing.expect_value(t, talk.entries[0].turn, Turn_State.Ended)
	// No act of a refused reply, and no reply after it.
	result, _ = act(talk, true, 1, 1, "monitor.processes()", "monitor", "processes", &error)
	expect_refusal(t, result, error, .State, 1)
	result, _ = reply(talk, true, 1, "hi", 0, &error)
	expect_refusal(t, result, error, .State, 1)
}

// act: before the reply, a serial of no request, a kind that names no
// member, a line of 201 bytes, a name that is no identifier, one name
// without the other, an act past the count of the reply.
@(test)
act_refuses_each_bad_input_and_each_act_past_the_turn :: proc(t: ^testing.T) {
	talk := taken_conversation(t)
	error: errors.Error_Record
	result, _ := act(talk, true, 1, 1, "monitor.processes()", "monitor", "processes", &error)
	expect_refusal(t, result, error, .State, 1)
	reply(talk, true, 1, "two acts", 2, &error)
	for serial in BAD_SERIALS {
		result, _ = act(talk, true, serial, 1, "monitor.processes()", "monitor", "processes", &error)
		expect_refusal(t, result, error, .Absent, 1)
	}
	for kind in ([?]i64{0, -1, 2, 255, max(i64)}) {
		result, _ = act(talk, true, 1, kind, "monitor.processes()", "monitor", "processes", &error)
		expect_refusal(t, result, error, .Bad_Value, 2)
	}
	long := strings.repeat("a", assistant_contract.ACT_LINE_BYTES + 1, context.temp_allocator)
	result, _ = act(talk, true, 1, 1, long, "", "", &error)
	expect_refusal(t, result, error, .Too_Long, 3)
	result, _ = act(talk, true, 1, 1, "", "", "", &error)
	expect_refusal(t, result, error, .Empty, 3)
	long_name := strings.repeat("a", assistant_contract.ACT_NAME_BYTES + 1, context.temp_allocator)
	names := [?][2]string{{"Monitor", "processes"}, {"monitor", "processes()"}, {"monitor", ""}, {"", "processes"}, {"plans.apply", "x"}, {long_name, "x"}, {"monitor", "a b"}}
	for pair in names {
		result, _ = act(talk, true, 1, 1, "monitor.processes()", pair[0], pair[1], &error)
		testing.expectf(t, result == ERROR_RESULT && error.kind == i64(errors.Kind.Bad_Value), "the names %v passed", pair)
	}
	testing.expect_value(t, talk.entry_count, 2)
	first, kept := act(talk, true, 1, 1, "monitor.processes()", "monitor", "processes", &error)
	testing.expect(t, first == 1 && kept != nil && kept.state == .Proposed)
	second, _ := act(talk, true, 1, 1, "x |> y", "", "", &error)
	testing.expect_value(t, second, 2)
	testing.expect_value(t, talk.entries[0].turn, Turn_State.Ended)
	result, _ = act(talk, true, 1, 1, "monitor.processes()", "monitor", "processes", &error)
	expect_refusal(t, result, error, .State, 1)
}

// act_result: an act of no number, a state that names no member or that
// only the window writes, waiting for an act with no names, a text of
// 1025 bytes, a second outcome.
@(test)
act_result_refuses_each_bad_input_and_takes_one_outcome :: proc(t: ^testing.T) {
	talk := taken_conversation(t)
	error: errors.Error_Record
	reply(talk, true, 1, "two acts", 2, &error)
	act(talk, true, 1, 1, "plans.apply(\"home\")", "plans", "apply", &error)
	act(talk, true, 1, 1, "x |> y", "", "", &error)
	for number in ([?]i64{0, -1, 3, max(i64), min(i64)}) {
		result, _ := act_result(talk, true, number, 2, "done", &error)
		expect_refusal(t, result, error, .Absent, 1)
		expect_refusal(t, act_state(talk, true, number, &error), error, .Absent, 1)
	}
	for state in ([?]i64{0, -1, 1, 5, 6, 7, 8, max(i64)}) {
		result, _ := act_result(talk, true, 1, state, "words", &error)
		expect_refusal(t, result, error, .Bad_Value, 2)
	}
	result, _ := act_result(talk, true, 2, i64(assistant_contract.Act_State.Awaiting_Principal), "words", &error)
	expect_refusal(t, result, error, .Bad_Value, 2)
	long := strings.repeat("a", assistant_contract.REPLY_TEXT_BYTES + 1, context.temp_allocator)
	result, _ = act_result(talk, true, 1, 2, long, &error)
	expect_refusal(t, result, error, .Too_Long, 3)
	testing.expect_value(t, act_state(talk, true, 1, &error), i64(assistant_contract.Act_State.Proposed))
	kept: ^Entry
	result, kept = act_result(talk, true, 1, i64(assistant_contract.Act_State.Awaiting_Principal), "stopped", &error)
	testing.expect(t, result == 1 && kept != nil)
	result, _ = act_result(talk, true, 1, 2, "done", &error)
	expect_refusal(t, result, error, .State, 1)
}

// A stand-in of the trusted display that counts its calls.
@(private = "file")
Display_Stand_In :: struct {
	ask_outcome: Act_Ask_Outcome,
	asks:        int,
	polls:       int,
	decision:    Act_Decision,
	cancelled:   u64,
	shown_act:   string,
}

@(private = "file")
stand_in: Display_Stand_In

@(private = "file")
stand_in_port :: proc() -> Act_Dialog_Port {
	return {
		ask = proc "contextless" (service, export: string) -> (serial: u64, outcome: Act_Ask_Outcome, cause: string) {
			stand_in.asks += 1
			stand_in.shown_act = service
			if stand_in.ask_outcome == .Shown {
				return u64(stand_in.asks), .Shown, ""
			}
			return 0, stand_in.ask_outcome, stand_in.ask_outcome == .Refused ? "Bad_Value" : ""
		},
		poll = proc "contextless" (serial: u64) -> (decision: Act_Decision, known: bool) {
			stand_in.polls += 1
			return stand_in.decision, true
		},
		cancel = proc "contextless" (serial: u64) {
			stand_in.cancelled = serial
		},
	}
}

// Two acts wait. Busy keeps the first waiting and the second unasked; a
// refusal that is not Busy is final: the first takes Not_Shown at once and
// is never asked again, and the second asks in its turn. The window never
// writes a decision that the display did not give.
@(private = "file")
a_refusal_of_the_display_other_than_busy_is_final :: proc(t: ^testing.T) {
	stand_in = {}
	talk := taken_conversation(t)
	error: errors.Error_Record
	reply(talk, true, 1, "two acts", 2, &error)
	act(talk, true, 1, 1, "plans.apply(\"home\")", "plans", "apply", &error)
	act(talk, true, 1, 1, "settings.set(1)", "settings", "set", &error)
	awaiting := i64(assistant_contract.Act_State.Awaiting_Principal)
	act_result(talk, true, 1, awaiting, "stopped", &error)
	act_result(talk, true, 2, awaiting, "stopped", &error)
	port := stand_in_port()
	stand_in.ask_outcome = .Busy
	for _ in 0 ..< 3 {
		waiting, event, _, _ := acts_waiting_step(talk, port)
		testing.expect(t, waiting && event == .None)
	}
	testing.expect_value(t, stand_in.asks, 3)
	testing.expect_value(t, stand_in.shown_act, "plans")
	stand_in.ask_outcome = .Refused
	waiting, event, entry, cause := acts_waiting_step(talk, port)
	testing.expect(t, waiting && event == .Not_Shown && entry.act == 1 && cause == "Bad_Value")
	testing.expect_value(t, act_state(talk, true, 1, &error), i64(assistant_contract.Act_State.Not_Shown))
	// The runner cannot change a final state.
	result, _ := act_result(talk, true, 1, 2, "done", &error)
	expect_refusal(t, result, error, .State, 1)
	stand_in.ask_outcome = .Shown
	waiting, event, entry, _ = acts_waiting_step(talk, port)
	testing.expect(t, waiting && event == .Shown && entry.act == 2)
	testing.expect_value(t, stand_in.shown_act, "settings")
	stand_in.decision = .Pending
	waiting, event, _, _ = acts_waiting_step(talk, port)
	testing.expect(t, waiting && event == .None)
	stand_in.decision = .Refused
	waiting, event, entry, _ = acts_waiting_step(talk, port)
	testing.expect(t, event == .Decided && entry.state == .Refused_By_Principal)
	waiting, event, _, _ = acts_waiting_step(talk, port)
	testing.expect(t, !waiting && event == .None)
}

// An act whose dialog shows leaves the ring: the next step cancels that
// dialog, once.
@(private = "file")
an_act_that_leaves_the_ring_cancels_its_dialog :: proc(t: ^testing.T) {
	stand_in = {}
	talk := taken_conversation(t)
	error: errors.Error_Record
	reply(talk, true, 1, "one act", 1, &error)
	act(talk, true, 1, 1, "plans.apply(\"home\")", "plans", "apply", &error)
	act_result(talk, true, 1, i64(assistant_contract.Act_State.Awaiting_Principal), "stopped", &error)
	stand_in.ask_outcome = .Shown
	_, event, entry, _ := acts_waiting_step(talk, stand_in_port())
	testing.expect(t, event == .Shown)
	shown := entry.dialog
	for _ in 0 ..< assistant_contract.CONVERSATION_ENTRY_CAPACITY {
		request_keep(talk, "more")
	}
	testing.expect(t, act_of(talk, 1) == nil)
	waiting, _, _, _ := acts_waiting_step(talk, stand_in_port())
	testing.expect(t, !waiting)
	testing.expect_value(t, stand_in.cancelled, shown)
	stand_in.cancelled = 0
	acts_waiting_step(talk, stand_in_port())
	testing.expect_value(t, stand_in.cancelled, 0)
}

// The two cases of the stand-in run in one test: the stand-in is one
// variable, and the tests of a package run at the same time.
@(test)
the_acts_that_wait_follow_the_trusted_display :: proc(t: ^testing.T) {
	a_refusal_of_the_display_other_than_busy_is_final(t)
	an_act_that_leaves_the_ring_cancels_its_dialog(t)
}
