#+build !freestanding
package conversation

import "core:strings"
import "core:testing"
import bridge_contract "modus:contract/agent_bridge"
import assistant_contract "modus:contract/assistant"
import "modus:contract/errors"
import "modus:contract/value_kinds"

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
	expect_refusal(t, stop_requested(talk, false, 1, &error), error, .No_Grant)
	result, kept = loop_end(talk, false, 1, i64(assistant_contract.Agent_Loop_End.Step_Limit), &error)
	expect_refusal(t, result, error, .No_Grant)
	testing.expect(t, kept == nil)
	result, kept = act_table_rows(talk, false, 1, nil, &error)
	expect_refusal(t, result, error, .No_Grant)
	testing.expect(t, kept == nil)
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
	testing.expect_value(t, talk.entries[0].turn, Turn_State.Waiting)
	result, _ = act(talk, true, 1, 1, "monitor.processes()", "monitor", "processes", &error)
	expect_refusal(t, result, error, .State, 1)
	// A final reply with 0 acts ends the loop.
	result, _ = reply(talk, true, 1, "done", 0, &error)
	testing.expect_value(t, result, 4)
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

@(private = "file")
column_of :: proc(name: string, kind := bridge_contract.Lex_Column_Kind.Text, unit: i64 = 0) -> (column: assistant_contract.Act_Table_Column) {
	copy(column.name[:], name)
	column.kind, column.unit = i64(kind), unit
	return
}

@(private = "file")
cell_of :: proc(text: string, integer: i64 = 0) -> (cell: assistant_contract.Act_Table_Cell) {
	copy(cell.text[:], text)
	cell.integer = integer
	return
}

// A conversation whose act 1 is Done, and act 2 waits for the principal.
@(private = "file")
done_conversation :: proc(t: ^testing.T) -> ^Conversation {
	talk := taken_conversation(t)
	error: errors.Error_Record
	reply(talk, true, 1, "two acts", 2, &error)
	act(talk, true, 1, 1, "monitor.processes()", "monitor", "processes", &error)
	act(talk, true, 1, 1, "plans.apply(\"home\")", "plans", "apply", &error)
	act_result(talk, true, 1, i64(assistant_contract.Act_State.Done), "2 rows of Process", &error)
	act_result(talk, true, 2, i64(assistant_contract.Act_State.Awaiting_Principal), "stopped", &error)
	return talk
}

// act_table refuses each form that is not a whole table, with its record,
// and keeps nothing: no grant, an act of no number, an act that is not
// Done, a shape that names no member, an empty or long name, no column or
// one past the bound, cells that are no whole count of rows, one row past
// the bound, a total under the rows, a record of two rows, an empty column
// name, a cell with a control byte or a byte after its zero.
@(test)
act_table_refuses_each_form_that_is_not_a_whole_table :: proc(t: ^testing.T) {
	talk := done_conversation(t)
	error: errors.Error_Record
	columns := [2]assistant_contract.Act_Table_Column{column_of("slot"), column_of("name")}
	cells := [4]assistant_contract.Act_Table_Cell{cell_of("1"), cell_of("root"), cell_of("2"), cell_of("devices")}
	table := i64(assistant_contract.Act_Table_Shape.Table)
	record := i64(assistant_contract.Act_Table_Shape.Record)
	result, _ := act_table(talk, false, 1, table, "Process", 2, columns[:], cells[:], &error)
	expect_refusal(t, result, error, .No_Grant)
	for number in ([?]i64{0, -1, 3, max(i64)}) {
		result, _ = act_table(talk, true, number, table, "Process", 2, columns[:], cells[:], &error)
		expect_refusal(t, result, error, .Absent, 1)
	}
	result, _ = act_table(talk, true, 2, table, "Process", 2, columns[:], cells[:], &error)
	expect_refusal(t, result, error, .State, 1)
	for word in ([?]i64{0, -1, 3, max(i64)}) {
		result, _ = act_table(talk, true, 1, word, "Process", 2, columns[:], cells[:], &error)
		expect_refusal(t, result, error, .Bad_Value, 2)
	}
	result, _ = act_table(talk, true, 1, table, "", 2, columns[:], cells[:], &error)
	expect_refusal(t, result, error, .Empty, 3)
	result, _ = act_table(talk, true, 1, table, strings.repeat("n", assistant_contract.ACT_TABLE_NAME_BYTES + 1, context.temp_allocator), 2, columns[:], cells[:], &error)
	expect_refusal(t, result, error, .Too_Long, 3)
	result, _ = act_table(talk, true, 1, table, "Process", 0, nil, nil, &error)
	expect_refusal(t, result, error, .Empty, 5)
	many_columns := make([]assistant_contract.Act_Table_Column, assistant_contract.ACT_TABLE_COLUMN_CAPACITY + 1, context.temp_allocator)
	for &column in many_columns {
		column = column_of("c")
	}
	result, _ = act_table(talk, true, 1, table, "Process", 0, many_columns, nil, &error)
	expect_refusal(t, result, error, .Too_Long, 5)
	result, _ = act_table(talk, true, 1, table, "Process", 2, columns[:], cells[:3], &error)
	expect_refusal(t, result, error, .Bad_Value, 6)
	many_cells := make([]assistant_contract.Act_Table_Cell, 2 * (assistant_contract.ACT_TABLE_ROW_CAPACITY + 1), context.temp_allocator)
	result, _ = act_table(talk, true, 1, table, "Process", 100, columns[:], many_cells, &error)
	expect_refusal(t, result, error, .Too_Long, 6)
	for total in ([?]i64{1, 0, -1, min(i64)}) {
		result, _ = act_table(talk, true, 1, table, "Process", total, columns[:], cells[:], &error)
		expect_refusal(t, result, error, .Bad_Value, 4)
	}
	result, _ = act_table(talk, true, 1, record, "Process", 2, columns[:], cells[:], &error)
	expect_refusal(t, result, error, .Bad_Value, 6)
	result, _ = act_table(talk, true, 1, record, "Process", 2, columns[:], cells[:2], &error)
	expect_refusal(t, result, error, .Bad_Value, 6)
	empty_name := [2]assistant_contract.Act_Table_Column{column_of("slot"), {}}
	result, _ = act_table(talk, true, 1, table, "Process", 2, empty_name[:], cells[:], &error)
	expect_refusal(t, result, error, .Bad_Value, 5)
	testing.expect_value(t, error.found, 2)
	bad_cells := [?]assistant_contract.Act_Table_Cell{cell_of("a\nb"), cell_of("\xc3"), cell_of("\x1b[31m")}
	for bad in bad_cells {
		damaged := cells
		damaged[3] = bad
		result, _ = act_table(talk, true, 1, table, "Process", 2, columns[:], damaged[:], &error)
		expect_refusal(t, result, error, .Bad_Value, 6)
		testing.expect_value(t, error.found, 2)
	}
	hidden := cells
	hidden[0].text[5] = 'x'
	result, _ = act_table(talk, true, 1, table, "Process", 2, columns[:], hidden[:], &error)
	expect_refusal(t, result, error, .Bad_Value, 6)
	testing.expect(t, act_table_of(talk, act_of(talk, 1)) == nil)
	// A whole table, last: it is kept once.
	kept: ^Entry
	result, kept = act_table(talk, true, 1, table, "Process", 18, columns[:], cells[:], &error)
	kept_table := act_table_of(talk, kept)
	testing.expect(t, result == 1 && kept != nil && kept_table != nil && kept_table.present)
	testing.expect(t, kept_table.row_count == 2 && kept_table.column_count == 2 && kept_table.total_rows == 18)
	testing.expect_value(t, act_table_cell_text(kept_table, 1, 1), "devices")
	testing.expect_value(t, act_table_column_name(kept_table, 0), "slot")
	testing.expect_value(t, act_table_name(kept_table), "Process")
	result, _ = act_table(talk, true, 1, table, "Process", 18, columns[:], cells[:], &error)
	expect_refusal(t, result, error, .State, 1)
	// A record of one row, and an empty cell, pass on a new act.
	talk = done_conversation(t)
	one := [2]assistant_contract.Act_Table_Cell{cell_of("3"), {}}
	result, kept = act_table(talk, true, 1, record, "Process", 1, columns[:], one[:], &error)
	record_table := act_table_of(talk, kept)
	testing.expect(t, result == 1 && record_table != nil && record_table.shape == .Record && act_table_cell_text(record_table, 0, 1) == "")
}

// A column kind that names no member, a unit that does not fit its kind, a
// text in a number cell and a value in a text cell are refused; a number
// column of sizes with its values passes, and gives back its kind.
@(test)
act_table_refuses_a_column_kind_or_a_cell_of_the_other_form :: proc(t: ^testing.T) {
	talk := done_conversation(t)
	error: errors.Error_Record
	table := i64(assistant_contract.Act_Table_Shape.Table)
	pages := i64(value_kinds.Size_Unit.Pages)
	cells := [2]assistant_contract.Act_Table_Cell{cell_of("root"), cell_of("", 9052)}
	bad_columns := [?][2]assistant_contract.Act_Table_Column {
		{column_of("name"), column_of("resident", .None)},
		{column_of("name"), {kind = 6}},
		{column_of("name"), {kind = -1}},
		{column_of("name"), column_of("resident", .Size, 99)},
		{column_of("name"), column_of("resident", .Hexadecimal, 0)},
		{column_of("name", .Text, 1), column_of("resident", .Size, pages)},
	}
	for columns in bad_columns {
		columns := columns
		columns[1].name = column_of("resident").name
		result, _ := act_table(talk, true, 1, table, "Process", 1, columns[:], cells[:], &error)
		expect_refusal(t, result, error, .Bad_Value, 5)
	}
	columns := [2]assistant_contract.Act_Table_Column{column_of("name"), column_of("resident", .Size, pages)}
	bad_cells := [?][2]assistant_contract.Act_Table_Cell{{cell_of("root"), cell_of("9052", 9052)}, {cell_of("root", 1), cell_of("", 9052)}}
	for wrong in bad_cells {
		wrong := wrong
		result, _ := act_table(talk, true, 1, table, "Process", 1, columns[:], wrong[:], &error)
		expect_refusal(t, result, error, .Bad_Value, 6)
	}
	testing.expect(t, act_table_of(talk, act_of(talk, 1)) == nil)
	result, kept := act_table(talk, true, 1, table, "Process", 1, columns[:], cells[:], &error)
	kept_table := act_table_of(talk, kept)
	testing.expect(t, result == 1 && kept != nil && kept_table != nil)
	unit, is_size := act_table_column_form(kept_table, 1).(value_kinds.Size_Unit)
	testing.expect(t, is_size && unit == .Pages)
	_, is_text := act_table_column_form(kept_table, 0).(Text_Form)
	testing.expect(t, is_text)
	testing.expect_value(t, act_table_cell_integer(kept_table, 0, 1), 9052)
}

// The two words of a column become its form at one border: each kind with
// a unit of its own kind gives its form; a kind of no member, None, a
// negative word, and a unit of no member of its kind give none.
@(test)
the_words_of_a_column_become_its_form_once :: proc(t: ^testing.T) {
	refused := [?][2]i64{{0, 0}, {6, 0}, {-1, 0}, {max(i64), 0}, {1, 1}, {2, -1}, {3, 5}, {3, -1}, {4, 4}, {5, 0}, {5, 9}, {min(i64), min(i64)}}
	for words in refused {
		_, ok := column_form_of_words(words[0], words[1])
		testing.expectf(t, !ok, "the words %v", words)
	}
	form, ok := column_form_of_words(1, 0)
	_, is_text := form.(Text_Form)
	testing.expect(t, ok && is_text)
	form, ok = column_form_of_words(2, 0)
	_, is_integer := form.(Integer_Form)
	testing.expect(t, ok && is_integer)
	form, ok = column_form_of_words(3, i64(value_kinds.Size_Unit.Blocks))
	size, is_size := form.(value_kinds.Size_Unit)
	testing.expect(t, ok && is_size && size == .Blocks)
	form, ok = column_form_of_words(4, i64(value_kinds.Duration_Unit.Seconds))
	time, is_time := form.(value_kinds.Duration_Unit)
	testing.expect(t, ok && is_time && time == .Seconds)
	form, ok = column_form_of_words(5, 8)
	hexadecimal, is_hexadecimal := form.(Hexadecimal_Form)
	testing.expect(t, ok && is_hexadecimal && hexadecimal.bytes == 8)
	testing.expect(t, form_is_text(Text_Form{}) && !form_is_text(value_kinds.Size_Unit.Pages))
}

// Multi-step loop: 16 steps of 4 acts each fit in the conversation without
// evicting the request; step 17 is refused with Too_Long; loop_end closes
// the request once.
@(test)
multi_step_loop_bounds_steps_and_refuses_step_17 :: proc(t: ^testing.T) {
	talk := taken_conversation(t)
	error: errors.Error_Record
	for step in 1 ..= assistant_contract.AGENT_LOOP_STEP_CAPACITY {
		r, kept := reply(talk, true, 1, "step", assistant_contract.MODEL_ACT_CAPACITY, &error)
		testing.expectf(t, r == 4 && kept != nil && int(kept.step) == step, "step %d reply", step)
		for _ in 0 ..< assistant_contract.MODEL_ACT_CAPACITY {
			num, act_entry := act(talk, true, 1, 1, "manual.modules()", "manual", "modules", &error)
			testing.expect(t, num > 0 && act_entry != nil && int(act_entry.step) == step)
		}
	}
	// The request is still in the ring and refuses step 17.
	testing.expect(t, request_of(talk, 1) != nil)
	result, _ := reply(talk, true, 1, "step 17", 0, &error)
	expect_refusal(t, result, error, .Too_Long, 1)
	testing.expect_value(t, error.limit, i64(assistant_contract.AGENT_LOOP_STEP_CAPACITY))
	result, _ = reply_refused(talk, true, 1, i64(errors.Kind.Bad_Value), i64(errors.Unit.Bytes), 1, 0, 0, &error)
	expect_refusal(t, result, error, .Too_Long, 1)
	// loop_end closes the request with Step_Limit once; a second call fails with State.
	ended, end_entry := loop_end(talk, true, 1, i64(assistant_contract.Agent_Loop_End.Step_Limit), &error)
	testing.expect(t, ended == 1 && end_entry != nil && end_entry.kind == .Loop_End)
	testing.expect_value(t, end_entry.end_cause, assistant_contract.Agent_Loop_End.Step_Limit)
	testing.expect_value(t, int(end_entry.step), assistant_contract.AGENT_LOOP_STEP_CAPACITY)
	result, _ = loop_end(talk, true, 1, i64(assistant_contract.Agent_Loop_End.Step_Limit), &error)
	expect_refusal(t, result, error, .State, 1)
}

// stop_requested and loop_end refuse bad serials, untaken requests, unknown
// end cause words, and already-ended requests; principal_stop sets the flag
// once on the running request; loop_end is accepted both in Waiting and
// mid-step in Acts_Coming.
@(test)
stop_requested_and_loop_end_enforce_borders :: proc(t: ^testing.T) {
	talk := taken_conversation(t)
	request_keep(talk, "untaken second")
	error: errors.Error_Record
	for serial in BAD_SERIALS {
		expect_refusal(t, stop_requested(talk, true, serial, &error), error, .Absent, 1)
		result, _ := loop_end(talk, true, serial, i64(assistant_contract.Agent_Loop_End.Stopped_By_Principal), &error)
		expect_refusal(t, result, error, .Absent, 1)
	}
	for cause in ([?]i64{0, -1, 8, 255, max(i64), min(i64)}) {
		result, _ := loop_end(talk, true, 1, cause, &error)
		expect_refusal(t, result, error, .Bad_Value, 2)
	}
	testing.expect_value(t, stop_requested(talk, true, 1, &error), 0)
	stopped := principal_stop(talk)
	testing.expect(t, stopped != nil && stopped.serial == 1)
	testing.expect_value(t, stop_requested(talk, true, 1, &error), 1)
	// Calling principal_stop again does not trigger a second event.
	testing.expect(t, principal_stop(talk) == nil)
	// Mid-step loop_end in Acts_Coming ends the request cleanly.
	reply(talk, true, 1, "step 1", 2, &error)
	act(talk, true, 1, 1, "manual.modules()", "manual", "modules", &error)
	testing.expect_value(t, request_of(talk, 1).turn, Turn_State.Acts_Coming)
	ended, end_entry := loop_end(talk, true, 1, i64(assistant_contract.Agent_Loop_End.Stopped_By_Principal), &error)
	testing.expect(t, ended == 1 && end_entry != nil && end_entry.end_cause == .Stopped_By_Principal)
	testing.expect(t, request_running(talk) == nil)
	// No act or reply after loop_end.
	result, _ := act(talk, true, 1, 1, "manual.modules()", "manual", "modules", &error)
	expect_refusal(t, result, error, .State, 1)
	result, _ = reply(talk, true, 1, "late", 0, &error)
	expect_refusal(t, result, error, .State, 1)
}

// Older steps fold their completed results by default, open and close on
// toggle, and never fold proposed or waiting acts; the latest action step
// stays open even after the final answer arrives.
@(test)
older_steps_fold_their_results_and_toggle :: proc(t: ^testing.T) {
	talk := taken_conversation(t)
	error: errors.Error_Record
	// Step 1: one act, Done.
	reply(talk, true, 1, "discover", 1, &error)
	_, act1 := act(talk, true, 1, 1, "manual.modules()", "manual", "modules", &error)
	// Proposed act never folds.
	testing.expect(t, !act_folded(talk, act1))
	act_result(talk, true, 1, i64(assistant_contract.Act_State.Done), "42 rows of Module", &error)
	// Latest step stays open.
	testing.expect(t, !act_folded(talk, act1))
	// Step 2 proposes another act: step 1 folds by default, step 2 stays open.
	reply(talk, true, 1, "query", 1, &error)
	_, act2 := act(talk, true, 1, 1, "monitor.processes()", "monitor", "processes", &error)
	act_result(talk, true, 2, i64(assistant_contract.Act_State.Done), "12 rows of Process", &error)
	testing.expect(t, act_folded(talk, act1))
	testing.expect(t, !act_folded(talk, act2))
	// Final answer (step 3, 0 acts): step 1 stays folded, step 2 (latest action step) stays open.
	reply(talk, true, 1, "12 processes run.", 0, &error)
	testing.expect(t, act_folded(talk, act1))
	testing.expect(t, !act_folded(talk, act2))
	// Toggling step 1 opens it, then folds it again.
	act_fold_toggle(talk, act1)
	testing.expect(t, !act_folded(talk, act1))
	act_fold_toggle(talk, act1)
	testing.expect(t, act_folded(talk, act1))
	// A new request folds step 2 as well.
	request_keep(talk, "second request")
	testing.expect(t, act_folded(talk, act2))
}

// act_table_rows appends batches up to ACT_TABLE_ROW_CAPACITY (64) rows,
// refuses rows past the capacity or past total_rows, refuses on a record
// or an act without a table, and leaves the table unchanged on any cell
// border failure.
@(test)
act_table_rows_appends_and_enforces_bounds :: proc(t: ^testing.T) {
	talk := done_conversation(t)
	error: errors.Error_Record
	columns := [2]assistant_contract.Act_Table_Column{column_of("slot", .Integer), column_of("name")}
	first := [2]assistant_contract.Act_Table_Cell{cell_of("", 1), cell_of("root")}
	// Refused before act_table.
	result, _ := act_table_rows(talk, true, 1, first[:], &error)
	expect_refusal(t, result, error, .State, 1)
	// Refused for bad act numbers.
	for number in ([?]i64{0, -1, 99, max(i64)}) {
		result, _ = act_table_rows(talk, true, number, first[:], &error)
		expect_refusal(t, result, error, .Absent, 1)
	}
	// Start a 64-row table with 1 row.
	result, _ = act_table(talk, true, 1, i64(assistant_contract.Act_Table_Shape.Table), "Process", 64, columns[:], first[:], &error)
	testing.expect_value(t, result, 1)
	// Empty cells and partial rows refused.
	result, _ = act_table_rows(talk, true, 1, nil, &error)
	expect_refusal(t, result, error, .Empty, 2)
	result, _ = act_table_rows(talk, true, 1, first[:1], &error)
	expect_refusal(t, result, error, .Bad_Value, 2)
	// Bad cell (text in integer column) refused without changing row_count.
	bad_batch := [2]assistant_contract.Act_Table_Cell{cell_of("oops", 2), cell_of("x")}
	result, _ = act_table_rows(talk, true, 1, bad_batch[:], &error)
	expect_refusal(t, result, error, .Bad_Value, 2)
	testing.expect_value(t, act_table_of(talk, act_of(talk, 1)).row_count, 1)
	// Append remaining 63 rows.
	batch := make([]assistant_contract.Act_Table_Cell, 63 * 2, context.temp_allocator)
	for row in 0 ..< 63 {
		batch[row * 2] = cell_of("", i64(row + 2))
		batch[row * 2 + 1] = cell_of("proc")
	}
	result, _ = act_table_rows(talk, true, 1, batch, &error)
	testing.expect_value(t, result, i64(assistant_contract.ACT_TABLE_ROW_CAPACITY))
	// Row 65 is refused with Too_Long.
	result, _ = act_table_rows(talk, true, 1, first[:], &error)
	expect_refusal(t, result, error, .Too_Long, 2)
	// Record refuses act_table_rows with State.
	talk2 := done_conversation(t)
	result, _ = act_table(talk2, true, 1, i64(assistant_contract.Act_Table_Shape.Record), "One", 1, columns[:], first[:], &error)
	testing.expect_value(t, result, 1)
	result, _ = act_table_rows(talk2, true, 1, first[:], &error)
	expect_refusal(t, result, error, .State, 1)
}

// Each entry has a number that grows and stays while older entries leave
// the ring; each change of what the window shows of an entry grows its
// revision and the layout serial; a refused call changes neither.
@(test)
the_numbers_and_revisions_follow_each_change_and_no_refusal :: proc(t: ^testing.T) {
	talk := taken_conversation(t)
	error: errors.Error_Record
	request := request_of(talk, 1)
	testing.expect_value(t, request.number, 1)
	serial := talk.layout_serial
	reply(talk, true, 1, "one act", 1, &error)
	_, entry := act(talk, true, 1, 1, "manual.modules()", "manual", "modules", &error)
	testing.expect_value(t, entry.number, 3)
	testing.expect(t, talk.layout_serial > serial)
	revision, serial_before := entry.revision, talk.layout_serial
	// A refused outcome changes nothing.
	result, _ := act_result(talk, true, 1, 99, "x", &error)
	expect_refusal(t, result, error, .Bad_Value, 2)
	testing.expect(t, entry.revision == revision && talk.layout_serial == serial_before)
	act_result(talk, true, 1, i64(assistant_contract.Act_State.Done), "42 rows of Module", &error)
	testing.expect(t, entry.revision > revision && talk.layout_serial > serial_before)
	revision = entry.revision
	entry_expand_toggle(talk, entry)
	testing.expect(t, entry.expanded && entry.revision > revision)
	entry_expand_toggle(talk, entry)
	testing.expect(t, !entry.expanded)
	// The ring turns: the numbers stay with their entries and keep growing.
	for _ in 0 ..< assistant_contract.CONVERSATION_ENTRY_CAPACITY {
		request_keep(talk, "more")
	}
	testing.expect(t, act_of(talk, 1) == nil)
	first := entry_at(talk, 0)
	last := entry_at(talk, talk.entry_count - 1)
	testing.expect_value(t, last.number, u64(3 + assistant_contract.CONVERSATION_ENTRY_CAPACITY))
	testing.expect_value(t, last.number - first.number, u64(talk.entry_count - 1))
}

// The fold of an act needs no search: the acts of the newest request fold
// when a later step of it has acts, and every act of an older request folds.
@(test)
the_fold_of_an_act_follows_the_newest_request :: proc(t: ^testing.T) {
	talk := taken_conversation(t)
	error: errors.Error_Record
	reply(talk, true, 1, "one", 1, &error)
	_, first := act(talk, true, 1, 1, "manual.modules()", "manual", "modules", &error)
	act_result(talk, true, 1, i64(assistant_contract.Act_State.Done), "done", &error)
	testing.expect_value(t, talk.newest_last_act_step, 1)
	testing.expect(t, !act_folded(talk, first))
	// A final reply with no act keeps the step of the last acts.
	reply(talk, true, 1, "answer", 0, &error)
	testing.expect_value(t, talk.newest_last_act_step, 1)
	testing.expect(t, !act_folded(talk, first))
	// A new request: every act of the request before folds.
	request_keep(talk, "next")
	testing.expect_value(t, talk.newest_last_act_step, 0)
	testing.expect(t, act_folded(talk, first))
}
