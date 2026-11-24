// The contract between the window of the assistant and the agent runner
// on the host (src/md/features/assistant.md): the bounds of the texts, the
// kinds and the states of an act, and the borders of their words. Both
// sides compile it in: the module assistant and the tool.
package assistant

import "modus:contract/text_encoding"

// The bytes of the text of one request of the principal (4 KiB so a user
// can paste an error or a code snippet).
REQUEST_TEXT_BYTES :: 4096

// The bytes of the text of a reply of the model, and of the result of an
// act, as the window shows them.
REPLY_TEXT_BYTES :: 16 * 1024

// Plan value: matches line_editor.LINE_CAPACITY (4096 bytes) so any line the
// console accepts can be proposed as an act without truncation or refusal.
ACT_LINE_BYTES :: 4096

// The entries of the conversation that one run of the window keeps: a
// request, a step reply, a refused reply, an act and a loop end take one
// each. Holds a whole 16-step loop of 16 acts per step (274 entries) with
// room for earlier entries.
CONVERSATION_ENTRY_CAPACITY :: 288

// The steps of an agent loop for one request at most. Past this count the
// loop stops with Agent_Loop_End.Step_Limit.
AGENT_LOOP_STEP_CAPACITY :: 16

// The acts of one model reply at most, matching AGENT_STEP_LINE_CAPACITY.
// The window refuses an act past the count that the reply gave.
MODEL_ACT_CAPACITY :: 16

#assert(CONVERSATION_ENTRY_CAPACITY >= 1 + AGENT_LOOP_STEP_CAPACITY * (1 + MODEL_ACT_CAPACITY) + 1)

// The typed table results kept in the conversation at once: older acts
// keep their words.
ACT_TABLE_POOL_CAPACITY :: 16

// The bytes of the name of the service or of the export of an act: a name
// of the system, as the root service names a process.
ACT_NAME_BYTES :: 31

// What an act asks the bridge for. The values cross the border of an export
// and of the model reply: 0 names no member.
Act_Kind :: enum u8 {
	Eval_Lex       = 1, // One line of Lex, which the bridge runs through remote when it is on the read-only list.
	Eval_Step      = 2, // 1 to 16 lines of Lex with persistent per-request variables, run in the read-only agent console step runner.
	Read_Screen    = 3, // Screen capture through the bridge (requires Read_Screen permission and remote Screen use).
	Read_Log_Facts = 4, // Structured log facts through the bridge (requires Read_Log_Facts permission and remote Calls use).
	Send_Key       = 5, // Scoped key input through the bridge (requires Send_Input permission and active wide grant naming the window).
	Send_Pointer   = 6, // Scoped pointer input through the bridge (requires Send_Input permission and active wide grant naming the window).
}

// The name of each kind in a model reply.
@(rodata)
ACT_KIND_NAMES := [Act_Kind]string {
	.Eval_Lex       = "eval_lex",
	.Eval_Step      = "eval_step",
	.Read_Screen    = "read_screen",
	.Read_Log_Facts = "read_log_facts",
	.Send_Key       = "send_key",
	.Send_Pointer   = "send_pointer",
}

// Where an act stands. The runner writes the outcome of the bridge; the
// window writes the decision of the principal.
Act_State :: enum u8 {
	Proposed             = 1, // The window shows it; the bridge has not answered yet.
	Done                 = 2, // The bridge ran it: the text is its result.
	Refused              = 3, // The bridge refused it at its border: the text says why.
	Awaiting_Principal   = 4, // The bridge stopped it with Awaiting_Principal_Approval: the act dialog decides.
	Allowed_By_Principal = 5, // The principal allowed it on the trusted display; eligible for verified single-use execution under an active wide grant when not gated by principal proof.
	Refused_By_Principal = 6, // The principal refused it on the trusted display. Nothing runs.
	Not_Shown            = 7, // The trusted display refused its act dialog for a cause other than Busy, or the window has no connection to it. Nothing runs.
}

// Why the agent loop of one request ended. The values cross the border of
// the export loop_end: 0 names no member.
Agent_Loop_End :: enum u8 {
	Final_Reply          = 1, // The model gave its final answer with no act.
	Step_Limit           = 2, // The loop reached AGENT_LOOP_STEP_CAPACITY steps.
	Repeated_Step        = 3, // A step repeated the exact acts of the step before.
	Stopped_By_Principal = 4, // The principal stopped the loop from the window.
	Model_Failed         = 5, // The model gave no reply or a reply that failed the border.
	Window_Failed        = 6, // A call to the window failed.
	Grant_Ended          = 7, // The grant or client access ended.
}

// agent_loop_end_of_word is the border of the word of a loop end cause:
// false for a word that names no member.
agent_loop_end_of_word :: proc "contextless" (word: i64) -> (cause: Agent_Loop_End, ok: bool) {
	switch word {
	case i64(Agent_Loop_End.Final_Reply):
		return .Final_Reply, true
	case i64(Agent_Loop_End.Step_Limit):
		return .Step_Limit, true
	case i64(Agent_Loop_End.Repeated_Step):
		return .Repeated_Step, true
	case i64(Agent_Loop_End.Stopped_By_Principal):
		return .Stopped_By_Principal, true
	case i64(Agent_Loop_End.Model_Failed):
		return .Model_Failed, true
	case i64(Agent_Loop_End.Window_Failed):
		return .Window_Failed, true
	case i64(Agent_Loop_End.Grant_Ended):
		return .Grant_Ended, true
	}
	return {}, false
}

// act_kind_of_word is the border of the word of a kind: false for a word
// that names no member.
act_kind_of_word :: proc "contextless" (word: i64) -> (kind: Act_Kind, ok: bool) {
	switch word {
	case i64(Act_Kind.Eval_Lex):
		return .Eval_Lex, true
	case i64(Act_Kind.Eval_Step):
		return .Eval_Step, true
	case i64(Act_Kind.Read_Screen):
		return .Read_Screen, true
	case i64(Act_Kind.Read_Log_Facts):
		return .Read_Log_Facts, true
	case i64(Act_Kind.Send_Key):
		return .Send_Key, true
	case i64(Act_Kind.Send_Pointer):
		return .Send_Pointer, true
	}
	return {}, false
}

// act_kind_of_name gives the kind of a name of a model reply.
act_kind_of_name :: proc "contextless" (name: string) -> (kind: Act_Kind, ok: bool) {
	for candidate in Act_Kind {
		if ACT_KIND_NAMES[candidate] == name {
			return candidate, true
		}
	}
	return {}, false
}

// act_state_of_word is the border of the word of a state: false for a word
// that names no member.
act_state_of_word :: proc "contextless" (word: i64) -> (state: Act_State, ok: bool) {
	switch word {
	case i64(Act_State.Proposed):
		return .Proposed, true
	case i64(Act_State.Done):
		return .Done, true
	case i64(Act_State.Refused):
		return .Refused, true
	case i64(Act_State.Awaiting_Principal):
		return .Awaiting_Principal, true
	case i64(Act_State.Allowed_By_Principal):
		return .Allowed_By_Principal, true
	case i64(Act_State.Refused_By_Principal):
		return .Refused_By_Principal, true
	case i64(Act_State.Not_Shown):
		return .Not_Shown, true
	}
	return {}, false
}

// act_state_from_runner says if the runner may write a state: the outcomes
// of the bridge only. The decisions of the principal come from the trusted
// display, and a runner that wrote them would answer the act dialog.
act_state_from_runner :: proc "contextless" (state: Act_State) -> bool {
	switch state {
	case .Done, .Refused, .Awaiting_Principal:
		return true
	case .Proposed, .Allowed_By_Principal, .Refused_By_Principal, .Not_Shown:
		return false
	}
	return false
}

// act_state_changes says if an act in a state may take a new state: the
// runner gives one outcome to a proposed act, the trusted display gives one
// decision to an act that waits for it (or the window Not_Shown when the
// trusted display cannot show it), and an act allowed by the principal may
// finish as Done or Refused once run through the verified approved-act border.
// Each other change is refused.
act_state_changes :: proc "contextless" (from, to: Act_State) -> bool {
	switch from {
	case .Proposed:
		return act_state_from_runner(to)
	case .Awaiting_Principal:
		return to == .Allowed_By_Principal || to == .Refused_By_Principal || to == .Not_Shown
	case .Allowed_By_Principal:
		return to == .Done || to == .Refused
	case .Done, .Refused, .Refused_By_Principal, .Not_Shown:
		return false
	}
	return false
}

// act_name_valid says if a text is a name of the service or of the export
// of an act: 1 to ACT_NAME_BYTES bytes, a lowercase letter first, then
// lowercase letters, digits and `_`. The trusted display shows such names
// only.
act_name_valid :: proc "contextless" (text: string) -> bool {
	if len(text) == 0 || len(text) > ACT_NAME_BYTES || text[0] < 'a' || text[0] > 'z' {
		return false
	}
	for character in transmute([]u8)text {
		letter := character >= 'a' && character <= 'z'
		digit := character >= '0' && character <= '9'
		if !letter && !digit && character != '_' {
			return false
		}
	}
	return true
}

// Why a text is refused at the border of an export.
Text_Refusal :: enum u8 {
	None,
	Empty, // No byte.
	Too_Long, // Past its bound.
	Not_Text, // Not UTF-8, or a control character.
}

// text_check checks a text that crosses the border: 1 to bound bytes, UTF-8
// with no control character (a line end too: the runner gives one line).
text_check :: proc "contextless" (text: string, bound: int) -> Text_Refusal {
	switch {
	case len(text) == 0:
		return .Empty
	case len(text) > bound:
		return .Too_Long
	case !text_encoding.text_valid(transmute([]u8)text):
		return .Not_Text
	}
	return .None
}

// The typed result of an act that ran: a table or a record, as the bridge
// gives it, within these bounds (src/md/features/assistant.md, "The
// result of an act"). The runner carries the first rows; total_rows of
// act_table counts all of them.
ACT_TABLE_COLUMN_CAPACITY :: 24 // The columns of one result: the table of the processes has 16.
ACT_TABLE_ROW_CAPACITY :: 64 // The rows that the window carries and pages through, matching the step bound.
ACT_TABLE_CELL_BATCH_CAPACITY :: 512 // Cells per remote call (512 * 72 B = 36 KiB, within the 64 KiB call region); wider tables stream extra rows through act_table_rows.
ACT_TABLE_CELL_BYTES :: 64 // The text of one cell: a hash of 32 bytes in hexadecimal is the longest value.
ACT_TABLE_NAME_BYTES :: 32 // The name of the record and of each column.

// What a typed result is. The values cross the border of an export: 0
// names no member.
Act_Table_Shape :: enum u8 {
	Table  = 1, // Rows of one record.
	Record = 2, // One record: one row.
}

// One column of act_table: its name, and how its cells are written and
// aligned, as the bridge gives it: a word of
// agent_bridge.Lex_Column_Kind and its unit word
// (agent_bridge.lex_column_unit_valid).
Act_Table_Column :: struct {
	name: [ACT_TABLE_NAME_BYTES]u8,
	kind: i64,
	unit: i64,
}

// One cell of act_table, row after row: the text of a cell of a text
// column, or the value of a cell of a number column; the other field is
// zero.
Act_Table_Cell :: struct {
	text:    [ACT_TABLE_CELL_BYTES]u8,
	integer: i64,
}

// act_table_shape_of_word is the border of the word of a shape: false for
// a word that names no member.
act_table_shape_of_word :: proc "contextless" (word: i64) -> (shape: Act_Table_Shape, ok: bool) {
	switch word {
	case i64(Act_Table_Shape.Table):
		return .Table, true
	case i64(Act_Table_Shape.Record):
		return .Record, true
	}
	return {}, false
}

// fixed_text reads the text of a fixed field of a row: the bytes before the
// first zero. ok is false when a byte after that zero is not zero (a field
// that hides bytes after its end), or when the text is not UTF-8 with no
// control byte. An empty text is a text: a cell can be empty.
fixed_text :: proc "contextless" (bytes: []u8) -> (text: string, ok: bool) {
	end := len(bytes)
	for value, index in bytes {
		if value == 0 {
			end = index
			break
		}
	}
	for value in bytes[end:] {
		if value != 0 {
			return "", false
		}
	}
	text = string(bytes[:end])
	if end > 0 && !text_encoding.text_valid(bytes[:end]) {
		return "", false
	}
	return text, true
}
