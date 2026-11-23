package assistant_window

import "internal:assistant/conversation"
import assistant_contract "modus:contract/assistant"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/value_kinds"
import "modus:system"

// The exports that the agent runner calls through remote
// (src/md/features/assistant.md, "The exports of the window"). The state
// and each border are in internal:assistant/conversation; this file reads
// the caller of the call and writes the facts. Each export runs in the one
// thread of this process, between two events: no lock.

// The conversation of this run of the window.
talk: conversation.Conversation

@(rodata)
STATE_WORDS := [assistant_contract.Act_State]string {
	.Proposed             = "proposed",
	.Done                 = "done",
	.Refused              = "refused by the bridge",
	.Awaiting_Principal   = "waiting for the principal",
	.Allowed_By_Principal = "allowed by the principal",
	.Refused_By_Principal = "refused by the principal",
	.Not_Shown            = "not shown by the trusted display",
}

@(rodata)
LOOP_END_WORDS := [assistant_contract.Agent_Loop_End]string {
	.Final_Reply          = "final reply",
	.Step_Limit           = "step limit",
	.Repeated_Step        = "repeated step",
	.Stopped_By_Principal = "stopped by the principal",
	.Model_Failed         = "model did not answer",
	.Window_Failed        = "window call stopped",
	.Grant_Ended          = "grant ended",
}

// caller_acts_for_principal says if the caller of the export that runs
// acts for the principal: the runner, through remote.
@(private = "file")
caller_acts_for_principal :: proc "contextless" () -> bool {
	caller := system.service_caller()
	return caller != nil && caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0
}

// request_keep keeps a request that the principal typed. A text that is not
// a text of the contract is kept as nothing: the field gives only text.
request_keep :: proc "contextless" (text: string) -> bool {
	entry := conversation.request_keep(&talk, text)
	if entry == nil {
		return false
	}
	system.log_fact(.Info, Request_Kept{serial = entry.serial, text = value_kinds.text_field(text, FACT_TEXT_BYTES)})
	return true
}

// request_stop records that the principal pressed Stop or Escape on the
// running loop.
request_stop :: proc "contextless" () {
	if entry := conversation.principal_stop(&talk); entry != nil {
		system.log_fact(.Info, Loop_Stop_Requested{serial = entry.serial})
	}
}

// request_serial gives the serial of the oldest request of the principal that no runner took, or 0 when none waits.
//
// **What it is for.** The agent runner on the host asks for the next request through remote, then reads its text
// with [request_text](assistant.request_text).
//
// **Grant**: the caller must **act for the principal**; else `No_Grant` (Grant_Or_Right_Missing).
@(export, link_name = "request_serial")
request_serial_export :: proc "c" (error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	return conversation.request_serial(&talk, caller_acts_for_principal(), error)
}

// request_text gives the text of a request, and marks it taken: request_serial does not give it again.
//
// The result is the count of bytes of the text, or a failure with its call outcome and an error record: `No_Grant`
// (Grant_Or_Right_Missing: the caller does not act for the principal); `Absent` (Nothing_Has_That_Name: no request of
// the window has this serial); `Too_Long` (Argument_Refused: the result has less room than the text: the request is not
// taken).
@(export, link_name = "request_text")
request_text_export :: proc "c" (serial: i64, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	read, count, taken := conversation.request_text(&talk, caller_acts_for_principal(), serial, result^, error)
	if taken != nil {
		system.log_fact(.Info, Request_Taken{serial = taken.serial})
	}
	return read, count
}

// reply shows one step reply (or the final reply when acts is 0) of the model to a request that a runner took.
//
// - **serial**: the request.
// - **text**: the reply, at most 16 KiB.
// - **acts**: the count of the acts of the step, 0 to 16: 0 ends the loop as a final reply; 1 to 16 expects that many acts before the next step.
//
// The result is the count of bytes kept, or a failure with its call outcome and an error record: `No_Grant`
// (Grant_Or_Right_Missing); `Absent` (Nothing_Has_That_Name: no request has the serial, or it was not taken); `State`
// (Wrong_State: the loop ended or still waits for acts of the step before); `Over_Limit` (Budget_Or_Capacity_Exhausted:
// the request reached 16 steps); `Empty`, `Too_Long` or `Bad_Value` (Argument_Refused: the text has no byte, more than
// 16 KiB, or a control byte or a damaged character; a count of acts under 0 or over 16).
@(export, link_name = "reply")
reply_export :: proc "c" (serial: i64, text: ^string, acts: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	ended, result, kept := conversation.reply(&talk, caller_acts_for_principal(), serial, text^, acts, error)
	if kept != nil {
		system.log_fact(.Info, Reply_Shown{serial = kept.serial, bytes = u64(kept.text_count), text = value_kinds.text_field(text^, FACT_TEXT_BYTES)})
	}
	return ended, result
}

// reply_refused shows that the runner refused the reply of the model to a request at its border: the words of the error record of that refusal. No act of that reply runs, and the turn of the request ends.
//
// The result is 1, or a failure with its call outcome and an error record: `No_Grant` (Grant_Or_Right_Missing);
// `Absent` (Nothing_Has_That_Name: no request taken has the serial); `State` (Wrong_State: the request has its reply
// already); `Bad_Value` (Argument_Refused: a kind or a unit that names no member of the contract, or the kind None).
@(export, link_name = "reply_refused")
reply_refused_export :: proc "c" (serial, kind, unit, argument, value, limit: i64, error: ^errors.Error_Record) -> (call_outcome.Call_Outcome, i64) {
	ended, result, kept := conversation.reply_refused(&talk, caller_acts_for_principal(), serial, kind, unit, argument, value, limit, error)
	if kept != nil {
		kind_member, _ := errors.kind_of_word(kept.error.kind)
		unit_member, _ := errors.unit_of_word(kept.error.unit)
		system.log_fact(.Info, Reply_Refused_Shown{serial = kept.serial, argument = argument, value = value, limit = limit, kind = value_kinds.text_field(errors.KIND_NAMES[kind_member], FACT_NAME_BYTES), unit = value_kinds.text_field(errors.UNIT_NAMES[unit_member], FACT_NAME_BYTES)})
	}
	return ended, result
}

// act shows an act that the reply of the model to a request proposes, before the bridge answers it, and gives its number.
//
// - **serial**: the request.
// - **kind**: the kind of the act, a word of assistant.Act_Kind: 1 a line of Lex.
// - **line**: the line of the act, at most 200 bytes.
// - **service**, **export**: the names of the one call of the line, which the runner parsed: two identifiers of 31
//   bytes at most, or two empty texts for a line that is no single call. The act dialog shows them.
//
// The result is the number of the act, from 1, or a failure with its call outcome and an error record: `No_Grant`
// (Grant_Or_Right_Missing); `Absent` (Nothing_Has_That_Name: no request taken has the serial); `State` (Wrong_State: no
// reply counted this act: the reply did not come, was refused, or its acts came); `Bad_Value` (Argument_Refused: a kind
// that names no member, or a name that is no identifier); `Empty`, `Too_Long` or `Bad_Value` (Argument_Refused: the
// line).
@(export, link_name = "act")
act_export :: proc "c" (serial, kind: i64, line: ^string, service: ^string, export: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	ended, result, kept := conversation.act(&talk, caller_acts_for_principal(), serial, kind, line^, service^, export^, error)
	if kept != nil {
		system.log_fact(.Info, Act_Proposed{act = kept.act, serial = kept.serial, line = value_kinds.text_field(line^, FACT_TEXT_BYTES)})
	}
	return ended, result
}

// act_result shows the answer of the bridge to an act: done with its result, refused with why, or waiting for the principal, which shows the act dialog of the trusted display.
//
// - **act**: the number that [act](assistant.act) gave.
// - **state**: a word of assistant.Act_State that the runner may write: 2 done, 3 refused, 4 waiting for the principal.
// - **text**: the result or the refusal, as words for the principal.
//
// The result is 1, or a failure with its call outcome and an error record: `No_Grant` (Grant_Or_Right_Missing);
// `Absent` (Nothing_Has_That_Name: no act has the number); `Bad_Value` (Argument_Refused: a state that names no member,
// one that the runner may not write, or waiting for an act with no names); `State` (Wrong_State: the act has an outcome
// already); `Empty`, `Too_Long` or `Bad_Value` (Argument_Refused: the text).
@(export, link_name = "act_result")
act_result_export :: proc "c" (act, state: i64, text: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	ended, result, kept := conversation.act_result(&talk, caller_acts_for_principal(), act, state, text^, error)
	if kept != nil {
		system.log_fact(.Info, Act_Outcome{act = kept.act, state = value_kinds.text_field(STATE_WORDS[kept.state], FACT_NAME_BYTES), text = value_kinds.text_field(text^, FACT_TEXT_BYTES)})
	}
	return ended, result
}

// One column of act_table: its name. The description of an export states
// its sizes as numbers; they are the ones of the contract.
Act_Table_Column :: struct {
	name: [32]u8,
	kind: i64,
	unit: i64,
}

// One cell of act_table, row after row: the text of a field.
Act_Table_Cell :: struct {
	text:    [64]u8,
	integer: i64,
}

#assert(size_of(Act_Table_Column) == size_of(assistant_contract.Act_Table_Column) && len(Act_Table_Column{}.name) == assistant_contract.ACT_TABLE_NAME_BYTES)
#assert(size_of(Act_Table_Cell) == size_of(assistant_contract.Act_Table_Cell) && len(Act_Table_Cell{}.text) == assistant_contract.ACT_TABLE_CELL_BYTES)

// act_table gives the typed result of an act that is done, a table or a record, so the window draws it as the console does: a line of heads, aligned columns, the first rows and the count of the others.
//
// - **act**: the number that [act](assistant.act) gave; the act is done.
// - **shape**: a word of assistant.Act_Table_Shape: 1 a table, 2 a record of one row.
// - **name**: the name of the record, at most 32 bytes.
// - **total_rows**: the rows of the whole result; the cells hold the first ones.
// - **columns**: a table of `Act_Table_Column` rows, 1 to 24: the name of a column, its kind (a word of agent_bridge.Lex_Column_Kind: 1 text, 2 integer, 3 size, 4 time, 5 hexadecimal) and its unit word.
// - **cells**: a table of `Act_Table_Cell` rows, row after row, a cell for each column: the text of a text column, the value of a number column; up to 64 rows of the result (wider tables send further batches through [act_table_rows](assistant.act_table_rows)).
//
// The result is 1, or a failure with its call outcome and an error record: `No_Grant` (Grant_Or_Right_Missing);
// `Absent` (Nothing_Has_That_Name: no act has the number); `State` (Wrong_State: the act is not done, or has its
// table); `Bad_Value` (Argument_Refused: a shape or a column kind that names no member, a unit that does not fit its
// kind, a text in a number cell or a value in a text cell, a record of another count of rows than 1, a total under the
// rows, a count of cells that is no whole count of rows, an empty column name, or a name or a cell that is not UTF-8
// with no control byte or that has a byte after its zero); `Empty` or `Too_Long` (Argument_Refused: the name, no column
// or more than 24, more than 64 rows).
@(export, link_name = "act_table")
act_table_export :: proc "c" (act, shape: i64, name: ^string, total_rows: i64, columns: ^system.Table_To_Read(Act_Table_Column), cells: ^system.Table_To_Read(Act_Table_Cell), error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	// A count past the bound is refused before the table is sliced: the
	// count is a word of the caller, up to the largest u64.
	if !caller_acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	if columns.count > assistant_contract.ACT_TABLE_COLUMN_CAPACITY {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Records, 5, i64(min(columns.count, u64(max(i64)))), assistant_contract.ACT_TABLE_COLUMN_CAPACITY)
	}
	if cells.count > assistant_contract.ACT_TABLE_ROW_CAPACITY * assistant_contract.ACT_TABLE_COLUMN_CAPACITY {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Records, 6, i64(min(cells.count, u64(max(i64)))), assistant_contract.ACT_TABLE_ROW_CAPACITY * assistant_contract.ACT_TABLE_COLUMN_CAPACITY)
	}
	column_records := transmute([]assistant_contract.Act_Table_Column)columns.records[:columns.count]
	cell_records := transmute([]assistant_contract.Act_Table_Cell)cells.records[:cells.count]
	ended, result, kept := conversation.act_table(&talk, caller_acts_for_principal(), act, shape, name^, total_rows, column_records, cell_records, error)
	if kept != nil {
		if kept_table := conversation.act_table_of(&talk, kept); kept_table != nil {
			system.log_fact(.Info, Act_Table_Shown{act = kept.act, rows = u64(kept_table.row_count), total_rows = u64(kept_table.total_rows), columns = u64(kept_table.column_count), name = value_kinds.text_field(conversation.act_table_name(kept_table), FACT_NAME_BYTES)})
		}
	}
	return ended, result
}

// act_table_rows appends more rows to a table started by [act_table](assistant.act_table), up to 64 rows and total_rows.
//
// - **act**: the number that [act](assistant.act) gave; the act is done and has a table.
// - **cells**: a table of `Act_Table_Cell` rows, row after row, a whole count of rows.
//
// The result is the new count of carried rows, or a failure with its call outcome and an error record: `No_Grant`
// (Grant_Or_Right_Missing); `Absent` (Nothing_Has_That_Name: no act has the number); `State` (Wrong_State: the act has
// no table or is a record); `Empty`, `Too_Long` or `Bad_Value` (Argument_Refused: the cells).
@(export, link_name = "act_table_rows")
act_table_rows_export :: proc "c" (act: i64, cells: ^system.Table_To_Read(Act_Table_Cell), error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !caller_acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	if cells.count > assistant_contract.ACT_TABLE_ROW_CAPACITY * assistant_contract.ACT_TABLE_COLUMN_CAPACITY {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Records, 2, i64(min(cells.count, u64(max(i64)))), assistant_contract.ACT_TABLE_ROW_CAPACITY * assistant_contract.ACT_TABLE_COLUMN_CAPACITY)
	}
	cell_records := transmute([]assistant_contract.Act_Table_Cell)cells.records[:cells.count]
	ended, result, _ := conversation.act_table_rows(&talk, caller_acts_for_principal(), act, cell_records, error)
	return ended, result
}

// act_state gives the state of an act, a word of assistant.Act_State: the runner reads the decision of the principal on an act that waited.
//
// The result is the state, or a failure with its call outcome and an error record: `No_Grant` (Grant_Or_Right_Missing);
// `Absent` (Nothing_Has_That_Name: no act has the number).
@(export, link_name = "act_state")
act_state_export :: proc "c" (act: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	return conversation.act_state(&talk, caller_acts_for_principal(), act, error)
}

// stop_requested gives 1 if you pressed Stop or Escape on the running loop of a taken request, and 0 otherwise.
//
// The runner polls this export before each step and stops the loop when it reads 1.
// The result is 0 or 1, or a failure with its call outcome and an error record: `No_Grant` (Grant_Or_Right_Missing);
// `Absent` (Nothing_Has_That_Name: no taken request has the serial).
@(export, link_name = "stop_requested")
stop_requested_export :: proc "c" (serial: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	return conversation.stop_requested(&talk, caller_acts_for_principal(), serial, error)
}

// loop_end ends the loop of a taken request and shows the cause once in the window.
//
// - **serial**: the request.
// - **cause**: a word of assistant.Agent_Loop_End (1 to 7).
//
// The result is 1, or a failure with its call outcome and an error record: `No_Grant` (Grant_Or_Right_Missing);
// `Absent` (Nothing_Has_That_Name: no taken request has the serial); `State` (Wrong_State: the loop already ended);
// `Bad_Value` (Argument_Refused: a cause that names no member of Agent_Loop_End).
@(export, link_name = "loop_end")
loop_end_export :: proc "c" (serial, cause: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	ended, result, kept := conversation.loop_end(&talk, caller_acts_for_principal(), serial, cause, error)
	if kept != nil {
		system.log_fact(.Info, Loop_Ended{serial = kept.serial, steps = u64(kept.step), cause = value_kinds.text_field(LOOP_END_WORDS[kept.end_cause], FACT_NAME_BYTES)})
	}
	return ended, result
}

// acts_waiting_step runs one step of the acts that wait for the principal
// (conversation.acts_waiting_step), and writes its fact.
acts_waiting_step :: proc "contextless" () -> (waiting: bool) {
	event: conversation.Waiting_Event
	entry: ^conversation.Entry
	cause: string
	waiting, event, entry, cause = conversation.acts_waiting_step(&talk, display_act_dialog_port())
	switch event {
	case .None:
	case .Shown:
		system.log_fact(.Info, Act_Dialog_Shown{act = entry.act, dialog = entry.dialog})
	case .Not_Shown:
		system.log_fact(.Info, Act_Dialog_Refused{act = entry.act, cause = value_kinds.text_field(cause, FACT_TEXT_BYTES)})
	case .Decided:
		system.log_fact(.Info, Act_Decided{act = entry.act, state = value_kinds.text_field(STATE_WORDS[entry.state], FACT_NAME_BYTES)})
	}
	return waiting
}
