// The conversation of one run of the window of the assistant, and the
// borders of the exports that the agent runner calls through remote
// (src/md/features/assistant.md, "The exports of the window"). The module
// assistant keeps one Conversation, calls these procedures from its
// exports and its loop, and writes the facts; this package makes no call
// of the system, so a host test drives each border.
package conversation

import "base:intrinsics"
import bridge_contract "modus:contract/agent_bridge"
import "modus:contract/enum_word"
import "modus:contract/value_kinds"
import assistant_contract "modus:contract/assistant"
import "modus:contract/errors"

Entry_Kind :: enum u8 {
	Request, // A request of the principal.
	Reply, // One step reply or final answer of the model for a request.
	Reply_Refused, // A reply that the runner refused at its border.
	Act, // An act of a step, with its state.
	Loop_End, // Why the loop of a request ended without a final reply.
}

// Where the loop of a request stands: each step sends a reply with its
// count of acts, then its acts, until a final reply (0 acts), a refused
// reply, or loop_end.
Turn_State :: enum u8 {
	Waiting, // Waiting for the next step reply, a refused reply, or loop_end.
	Acts_Coming, // A step reply came; acts_given of acts_counted came.
	Ended, // The loop ended: a final reply (0 acts), a refused reply, or loop_end.
}

Entry :: struct {
	kind:           Entry_Kind,
	serial:         u64, // The request of the entry.
	act:            u64, // An Act: its number.
	act_kind:       assistant_contract.Act_Kind,
	state:          assistant_contract.Act_State,
	taken:          bool, // A Request: a runner took it.
	turn:           Turn_State, // A Request: its loop state.
	step:           u8, // A Reply, Reply_Refused, Act or Loop_End: its step number (1..16).
	step_count:     u8, // A Request: steps taken so far (0..16).
	last_act_step:  u8, // A Request: the latest step that proposed acts.
	step_acts:      u8, // A Reply: acts counted in this step (0 for final answer).
	stop_requested: bool, // A Request: the principal asked to stop the running loop.
	end_cause:      assistant_contract.Agent_Loop_End, // A Request or Loop_End: why the loop ended.
	fold_toggled:     bool, // An older Act: toggled by the principal to show or hide its result.
	table_given:      bool, // An Act: act_table already recorded a table for this act.
	table_slot:       u8, // An Act: index in Conversation.tables when table_given.
	table_row_offset: u8, // An Act: first row shown when paging a carried table.
	acts_counted:   int, // A Request: the acts that its current step reply counted.
	acts_given:     int, // A Request: the acts of the current step that came.
	dialog:         u64, // An Act that waits: the serial of its act dialog, 0 before it shows.
	error:          errors.Error_Record, // A Reply_Refused: the record of the runner.
	text:           [assistant_contract.REPLY_TEXT_BYTES]u8, // A request, a reply, the result of an act.
	text_count:     int,
	line:           [assistant_contract.ACT_LINE_BYTES]u8, // An Act: its line.
	line_count:     int,
	service:        [assistant_contract.ACT_NAME_BYTES]u8, // An Act: the service of its one call, from the runner; empty for a line that is no single call.
	service_count:  int,
	export:         [assistant_contract.ACT_NAME_BYTES]u8, // An Act: the export of its one call.
	export_count:   int,
}

// The typed result of an act: a table or a record, with its first rows
// (src/md/features/assistant.md, "The result of an act"). Kept in a pool
// on Conversation so 128 entries fit within the window budget.
Act_Table :: struct {
	present:      bool,
	act:          u64,
	shape:        assistant_contract.Act_Table_Shape,
	name:         [assistant_contract.ACT_TABLE_NAME_BYTES]u8,
	total_rows:   int, // The rows of the whole result.
	column_count: int,
	row_count:    int, // The rows here: at most ACT_TABLE_ROW_CAPACITY.
	columns:      [assistant_contract.ACT_TABLE_COLUMN_CAPACITY]Act_Column,
	cells:        [assistant_contract.ACT_TABLE_ROW_CAPACITY * assistant_contract.ACT_TABLE_COLUMN_CAPACITY]assistant_contract.Act_Table_Cell, // Row after row: column_count cells in each row.
}

// How a column is written and aligned, typed: the kind and its unit in one
// value, which act_table makes once from the two words of the contract
// record (column_form_of_words). Past that border the code reads the form
// and never a word.
Text_Form :: struct {}
Integer_Form :: struct {}
Hexadecimal_Form :: struct {
	bytes: u8, // The bytes of the number, 1 to 8: two digits for each.
}
Column_Form :: union #no_nil {
	Text_Form,
	Integer_Form,
	value_kinds.Size_Unit, // A size in its unit.
	value_kinds.Duration_Unit, // A time in its unit.
	Hexadecimal_Form,
}

// One column of a kept result: its name and its form.
Act_Column :: struct {
	name: [assistant_contract.ACT_TABLE_NAME_BYTES]u8,
	form: Column_Form,
}

// column_form_of_words is the border of the two words of a column: the
// kind (agent_bridge.Lex_Column_Kind) and its unit. ok is false for a kind
// that names no member, None too, and for a unit that names no member of
// the unit of its kind.
column_form_of_words :: proc "contextless" (kind_word, unit_word: i64) -> (form: Column_Form, ok: bool) {
	kind := bridge_contract.lex_column_kind_of_word(kind_word) or_return
	if !bridge_contract.lex_column_unit_valid(kind, unit_word) {
		return Text_Form{}, false
	}
	switch kind {
	case .Text:
		return Text_Form{}, true
	case .Integer:
		return Integer_Form{}, true
	case .Size:
		unit := enum_word.member_of_word(value_kinds.Size_Unit, u64(unit_word)) or_return
		return unit, true
	case .Time:
		unit := enum_word.member_of_word(value_kinds.Duration_Unit, u64(unit_word)) or_return
		return unit, true
	case .Hexadecimal:
		return Hexadecimal_Form{bytes = u8(unit_word)}, true
	case .None:
	}
	return Text_Form{}, false
}

// form_is_text says if a column of a form holds texts, not values.
form_is_text :: proc "contextless" (form: Column_Form) -> bool {
	_, text := form.(Text_Form)
	return text
}

// act_table_name gives the name of the record of a table.
act_table_name :: proc "contextless" (table: ^Act_Table) -> string {
	name, _ := assistant_contract.fixed_text(table.name[:])
	return name
}

// act_table_column_name gives the name of a column.
act_table_column_name :: proc "contextless" (table: ^Act_Table, column: int) -> string {
	name, _ := assistant_contract.fixed_text(table.columns[column].name[:])
	return name
}

// act_table_column_form gives the form of a column, which act_table made.
act_table_column_form :: proc "contextless" (table: ^Act_Table, column: int) -> Column_Form {
	return table.columns[column].form
}

// act_table_cell_integer gives the value of a cell of a number column.
act_table_cell_integer :: proc "contextless" (table: ^Act_Table, row, column: int) -> i64 {
	return table.cells[row * table.column_count + column].integer
}

// act_table_cell_text gives the text of a cell.
act_table_cell_text :: proc "contextless" (table: ^Act_Table, row, column: int) -> string {
	text, _ := assistant_contract.fixed_text(table.cells[row * table.column_count + column].text[:])
	return text
}

// The entries, oldest first, in a ring of CONVERSATION_ENTRY_CAPACITY:
// past it the oldest entry leaves. Typed tables live in a ring of
// ACT_TABLE_POOL_CAPACITY slots so 128 entries hold a full 16-step loop
// within the window budget; acts whose table left the pool keep their words.
Conversation :: struct {
	entries:          [assistant_contract.CONVERSATION_ENTRY_CAPACITY]Entry,
	entry_first:      int,
	entry_count:      int,
	last_serial:      u64, // The serial of the last request kept: the next one is one more.
	last_act:         u64, // The number of the last act: the next one is one more.
	changed:          bool, // The conversation changed: the window draws again.
	// The act dialog of an act whose entry left the ring while it showed:
	// the loop of the window cancels it (acts_waiting_step), outside an
	// export, so the principal never decides an act that the window no
	// longer shows. One act dialog shows at a time, so one place is enough.
	dialog_to_cancel: u64,
	tables:           [assistant_contract.ACT_TABLE_POOL_CAPACITY]Act_Table,
	table_next:       int,
	// The copy of a table that act_table checks before an entry takes it:
	// the caller can change the call region during the call, so each record
	// is read once, here.
	staging:          Act_Table,
}

// act_table_of gives the kept typed result of an act, or nil when none was
// given or an older table left the pool.
act_table_of :: proc "contextless" (conversation: ^Conversation, entry: ^Entry) -> ^Act_Table {
	if conversation == nil || entry == nil || entry.kind != .Act || !entry.table_given {
		return nil
	}
	slot := &conversation.tables[entry.table_slot]
	if !slot.present || slot.act != entry.act {
		return nil
	}
	return slot
}

// The result of a refused call.
ERROR_RESULT :: -1

entry_at :: proc "contextless" (conversation: ^Conversation, index: int) -> ^Entry {
	return &conversation.entries[(conversation.entry_first + index) % len(conversation.entries)]
}

// entry_add gives a new entry at the end; the oldest leaves when the ring
// is full. An act that leaves while its dialog shows has that dialog
// cancelled.
entry_add :: proc "contextless" (conversation: ^Conversation, kind: Entry_Kind, serial: u64) -> ^Entry {
	if conversation.entry_count == len(conversation.entries) {
		leaving := entry_at(conversation, 0)
		if leaving.kind == .Act && leaving.state == .Awaiting_Principal && leaving.dialog != 0 {
			conversation.dialog_to_cancel = leaving.dialog
		}
		conversation.entry_first = (conversation.entry_first + 1) % len(conversation.entries)
		conversation.entry_count -= 1
	}
	entry := entry_at(conversation, conversation.entry_count)
	// An entry holds about 15 KiB: it is zeroed in place, with no
	// temporary on the stack.
	intrinsics.mem_zero(entry, size_of(Entry))
	entry.kind, entry.serial = kind, serial
	conversation.entry_count += 1
	conversation.changed = true
	return entry
}

request_of :: proc "contextless" (conversation: ^Conversation, serial: i64) -> ^Entry {
	if serial < 1 {
		return nil
	}
	for index in 0 ..< conversation.entry_count {
		entry := entry_at(conversation, index)
		if entry.kind == .Request && entry.serial == u64(serial) {
			return entry
		}
	}
	return nil
}

act_of :: proc "contextless" (conversation: ^Conversation, act: i64) -> ^Entry {
	if act < 1 {
		return nil
	}
	for index in 0 ..< conversation.entry_count {
		entry := entry_at(conversation, index)
		if entry.kind == .Act && entry.act == u64(act) {
			return entry
		}
	}
	return nil
}

// request_keep keeps a request that the principal typed, and gives its
// entry. A text that is not a text of the contract is kept as nothing: nil.
request_keep :: proc "contextless" (conversation: ^Conversation, text: string) -> ^Entry {
	if assistant_contract.text_check(text, assistant_contract.REQUEST_TEXT_BYTES) != .None {
		return nil
	}
	conversation.last_serial += 1
	entry := entry_add(conversation, .Request, conversation.last_serial)
	entry.text_count = copy(entry.text[:], text)
	return entry
}

// text_refusal fails a call for a text that the contract refuses.
@(private = "file")
text_refusal :: proc "contextless" (error: ^errors.Error_Record, argument: i64, text: string, bound: int) -> (refused: bool, result: i64) {
	switch assistant_contract.text_check(text, bound) {
	case .None:
		return false, 0
	case .Empty:
		return true, errors.fail(error, ERROR_RESULT, .Empty, .Bytes, argument, 0, i64(bound))
	case .Too_Long:
		return true, errors.fail(error, ERROR_RESULT, .Too_Long, .Bytes, argument, i64(len(text)), i64(bound))
	case .Not_Text:
		return true, errors.fail(error, ERROR_RESULT, .Bad_Value, .Bytes, argument, i64(len(text)))
	}
	return true, errors.fail(error, ERROR_RESULT, .Refused)
}

@(private = "file")
no_grant :: proc "contextless" (error: ^errors.Error_Record) -> i64 {
	return errors.fail(error, ERROR_RESULT, .No_Grant, .Acts_For_Principal)
}

// taken_request_of gives the request of a serial that a runner took, or
// nil.
@(private = "file")
taken_request_of :: proc "contextless" (conversation: ^Conversation, serial: i64) -> ^Entry {
	request := request_of(conversation, serial)
	if request == nil || !request.taken {
		return nil
	}
	return request
}

// request_serial gives the serial of the oldest request that no runner
// took, or 0.
request_serial :: proc "contextless" (conversation: ^Conversation, acts_for_principal: bool, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal {
		return no_grant(error)
	}
	for index in 0 ..< conversation.entry_count {
		entry := entry_at(conversation, index)
		if entry.kind == .Request && !entry.taken {
			return i64(entry.serial)
		}
	}
	return 0
}

// request_text copies the text of a request into result and marks it
// taken; taken is the request when this call took it. A result with less
// room than the text is refused, and the request stays for a call with
// room: a cut request would read as whole.
request_text :: proc "contextless" (conversation: ^Conversation, acts_for_principal: bool, serial: i64, result: []u8, error: ^errors.Error_Record) -> (count: i64, taken: ^Entry) {
	if !acts_for_principal {
		return no_grant(error), nil
	}
	entry := request_of(conversation, serial)
	if entry == nil {
		return errors.fail(error, ERROR_RESULT, .Absent, .Requests, 1, serial), nil
	}
	text := string(entry.text[:entry.text_count])
	if len(result) < len(text) {
		return errors.fail(error, ERROR_RESULT, .Too_Long, .Bytes, 0, i64(len(text)), i64(len(result))), nil
	}
	if !entry.taken {
		entry.taken = true
		taken = entry
	}
	copy(result, text)
	return i64(len(text)), taken
}

// reply keeps one step reply (or the final reply when acts is 0) to a
// taken request and the count of its acts, and gives its entry. A request
// takes at most AGENT_LOOP_STEP_CAPACITY steps.
reply :: proc "contextless" (conversation: ^Conversation, acts_for_principal: bool, serial: i64, text: string, acts: i64, error: ^errors.Error_Record) -> (result: i64, kept: ^Entry) {
	if !acts_for_principal {
		return no_grant(error), nil
	}
	request := taken_request_of(conversation, serial)
	if request == nil {
		return errors.fail(error, ERROR_RESULT, .Absent, .Requests, 1, serial), nil
	}
	if request.turn != .Waiting {
		return errors.fail(error, ERROR_RESULT, .State, .Requests, 1, serial), nil
	}
	if int(request.step_count) >= assistant_contract.AGENT_LOOP_STEP_CAPACITY {
		return errors.fail(error, ERROR_RESULT, .Too_Long, .Records, 1, i64(request.step_count) + 1, assistant_contract.AGENT_LOOP_STEP_CAPACITY), nil
	}
	if refused, refusal := text_refusal(error, 2, text, assistant_contract.REPLY_TEXT_BYTES); refused {
		return refusal, nil
	}
	if acts < 0 {
		return errors.fail(error, ERROR_RESULT, .Bad_Value, .Records, 3, acts, assistant_contract.MODEL_ACT_CAPACITY), nil
	}
	if acts > assistant_contract.MODEL_ACT_CAPACITY {
		return errors.fail(error, ERROR_RESULT, .Too_Long, .Records, 3, acts, assistant_contract.MODEL_ACT_CAPACITY), nil
	}
	request.step_count += 1
	step := request.step_count
	request.acts_counted = int(acts)
	request.acts_given = 0
	if acts == 0 {
		request.turn = .Ended
		request.end_cause = .Final_Reply
	} else {
		request.last_act_step = step
		request.turn = .Acts_Coming
	}
	kept = entry_add(conversation, .Reply, u64(serial))
	kept.step = step
	kept.step_acts = u8(acts)
	kept.text_count = copy(kept.text[:], text)
	return i64(kept.text_count), kept
}

// reply_refused keeps the record of a reply that the runner refused at
// its border; the loop of the request ends with Model_Failed.
reply_refused :: proc "contextless" (conversation: ^Conversation, acts_for_principal: bool, serial, kind, unit, argument, value, limit: i64, error: ^errors.Error_Record) -> (result: i64, kept: ^Entry) {
	if !acts_for_principal {
		return no_grant(error), nil
	}
	request := taken_request_of(conversation, serial)
	if request == nil {
		return errors.fail(error, ERROR_RESULT, .Absent, .Requests, 1, serial), nil
	}
	if request.turn != .Waiting {
		return errors.fail(error, ERROR_RESULT, .State, .Requests, 1, serial), nil
	}
	if int(request.step_count) >= assistant_contract.AGENT_LOOP_STEP_CAPACITY {
		return errors.fail(error, ERROR_RESULT, .Too_Long, .Records, 1, i64(request.step_count) + 1, assistant_contract.AGENT_LOOP_STEP_CAPACITY), nil
	}
	kind_member, kind_ok := errors.kind_of_word(kind)
	if !kind_ok || kind_member == .None {
		return errors.fail(error, ERROR_RESULT, .Bad_Value, .None, 2, kind), nil
	}
	unit_member, unit_ok := errors.unit_of_word(unit)
	if !unit_ok {
		return errors.fail(error, ERROR_RESULT, .Bad_Value, .None, 3, unit), nil
	}
	step := request.step_count + 1
	request.turn = .Ended
	request.end_cause = .Model_Failed
	kept = entry_add(conversation, .Reply_Refused, u64(serial))
	kept.step = step
	kept.error = errors.error_make(kind_member, unit_member, argument, value, limit)
	return 1, kept
}

// act keeps an act that the current step reply counted, with the names of
// its one call as the runner parsed them, and gives its entry. The names
// are both identifiers, or both empty for a line that is no single call.
// Once the last act of the step arrives, the request returns to Waiting
// for the next step reply or loop_end.
act :: proc "contextless" (conversation: ^Conversation, acts_for_principal: bool, serial, kind: i64, line, service, export: string, error: ^errors.Error_Record) -> (result: i64, kept: ^Entry) {
	if !acts_for_principal {
		return no_grant(error), nil
	}
	request := taken_request_of(conversation, serial)
	if request == nil {
		return errors.fail(error, ERROR_RESULT, .Absent, .Requests, 1, serial), nil
	}
	// An act comes after the step reply that counted it, and no act past
	// the count of the step is accepted.
	if request.turn != .Acts_Coming || request.acts_given >= request.acts_counted {
		return errors.fail(error, ERROR_RESULT, .State, .Records, 1, serial, i64(request.acts_counted)), nil
	}
	act_kind, kind_ok := assistant_contract.act_kind_of_word(kind)
	if !kind_ok {
		return errors.fail(error, ERROR_RESULT, .Bad_Value, .None, 2, kind, i64(max(assistant_contract.Act_Kind))), nil
	}
	if refused, refusal := text_refusal(error, 3, line, assistant_contract.ACT_LINE_BYTES); refused {
		return refusal, nil
	}
	named := len(service) > 0 || len(export) > 0
	if named && !assistant_contract.act_name_valid(service) {
		return errors.fail(error, ERROR_RESULT, .Bad_Value, .Bytes, 4, i64(len(service)), assistant_contract.ACT_NAME_BYTES), nil
	}
	if named && !assistant_contract.act_name_valid(export) {
		return errors.fail(error, ERROR_RESULT, .Bad_Value, .Bytes, 5, i64(len(export)), assistant_contract.ACT_NAME_BYTES), nil
	}
	step := request.step_count
	request.acts_given += 1
	if request.acts_given == request.acts_counted {
		request.turn = .Waiting
	}
	conversation.last_act += 1
	kept = entry_add(conversation, .Act, u64(serial))
	kept.step = step
	kept.act = conversation.last_act
	kept.act_kind = act_kind
	kept.state = .Proposed
	kept.line_count = copy(kept.line[:], line)
	kept.service_count = copy(kept.service[:], service)
	kept.export_count = copy(kept.export[:], export)
	return i64(kept.act), kept
}

// stop_requested reports whether the principal asked to stop the running
// loop of a taken request: 1 if stop was requested, 0 otherwise.
stop_requested :: proc "contextless" (conversation: ^Conversation, acts_for_principal: bool, serial: i64, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal {
		return no_grant(error)
	}
	request := taken_request_of(conversation, serial)
	if request == nil {
		return errors.fail(error, ERROR_RESULT, .Absent, .Requests, 1, serial)
	}
	return request.stop_requested ? 1 : 0
}

// loop_end ends the agent loop of a taken request with a cause of
// Agent_Loop_End, and adds a Loop_End entry so the window shows the cause
// once. Allowed in Waiting or Acts_Coming; refused in Ended.
loop_end :: proc "contextless" (conversation: ^Conversation, acts_for_principal: bool, serial, cause_word: i64, error: ^errors.Error_Record) -> (result: i64, kept: ^Entry) {
	if !acts_for_principal {
		return no_grant(error), nil
	}
	request := taken_request_of(conversation, serial)
	if request == nil {
		return errors.fail(error, ERROR_RESULT, .Absent, .Requests, 1, serial), nil
	}
	if request.turn == .Ended {
		return errors.fail(error, ERROR_RESULT, .State, .Requests, 1, serial), nil
	}
	cause, cause_ok := assistant_contract.agent_loop_end_of_word(cause_word)
	if !cause_ok {
		return errors.fail(error, ERROR_RESULT, .Bad_Value, .None, 2, cause_word, i64(max(assistant_contract.Agent_Loop_End))), nil
	}
	step := request.step_count
	request.turn = .Ended
	request.end_cause = cause
	kept = entry_add(conversation, .Loop_End, u64(serial))
	kept.step = step
	kept.end_cause = cause
	return 1, kept
}

// request_running gives the taken request whose loop has not ended yet,
// or nil when no loop is running.
request_running :: proc "contextless" (conversation: ^Conversation) -> ^Entry {
	for index := conversation.entry_count - 1; index >= 0; index -= 1 {
		entry := entry_at(conversation, index)
		if entry.kind == .Request && entry.taken && entry.turn != .Ended {
			return entry
		}
	}
	return nil
}

// principal_stop records that the principal pressed Stop or Escape on the
// running loop, and gives that request when it changed from not stopped.
principal_stop :: proc "contextless" (conversation: ^Conversation) -> ^Entry {
	request := request_running(conversation)
	if request == nil || request.stop_requested {
		return nil
	}
	request.stop_requested = true
	conversation.changed = true
	return request
}

// act_folded_by_default says if an act belongs to an older step (or an
// older request) and has a finished result, so the window folds its result
// to a short line until the principal opens it.
act_folded_by_default :: proc "contextless" (conversation: ^Conversation, entry: ^Entry) -> bool {
	if conversation == nil || entry == nil || entry.kind != .Act {
		return false
	}
	if entry.state != .Done && entry.state != .Refused {
		return false
	}
	if entry.serial < conversation.last_serial {
		return true
	}
	request := request_of(conversation, i64(entry.serial))
	if request == nil {
		return true
	}
	return entry.step > 0 && entry.step < request.last_act_step
}

// act_folded says if the window currently folds the result of an act.
act_folded :: proc "contextless" (conversation: ^Conversation, entry: ^Entry) -> bool {
	if !act_folded_by_default(conversation, entry) {
		return false
	}
	return !entry.fold_toggled
}

// act_fold_toggle opens a folded older act result or folds it back.
act_fold_toggle :: proc "contextless" (conversation: ^Conversation, entry: ^Entry) {
	if !act_folded_by_default(conversation, entry) {
		return
	}
	entry.fold_toggled = !entry.fold_toggled
	conversation.changed = true
}

// act_table_page moves the first displayed row of an act's table.
act_table_page :: proc "contextless" (conversation: ^Conversation, entry: ^Entry, offset: int) {
	table := act_table_of(conversation, entry)
	if table == nil || table.row_count == 0 {
		return
	}
	clamped := clamp(offset, 0, table.row_count - 1)
	if int(entry.table_row_offset) != clamped {
		entry.table_row_offset = u8(clamped)
		conversation.changed = true
	}
}

// act_result keeps the outcome of the bridge for an act.
act_result :: proc "contextless" (conversation: ^Conversation, acts_for_principal: bool, act, state: i64, text: string, error: ^errors.Error_Record) -> (result: i64, kept: ^Entry) {
	if !acts_for_principal {
		return no_grant(error), nil
	}
	entry := act_of(conversation, act)
	if entry == nil {
		return errors.fail(error, ERROR_RESULT, .Absent, .Records, 1, act), nil
	}
	new_state, state_ok := assistant_contract.act_state_of_word(state)
	if !state_ok || !assistant_contract.act_state_from_runner(new_state) {
		return errors.fail(error, ERROR_RESULT, .Bad_Value, .None, 2, state), nil
	}
	// An act with no names has no act dialog: the bridge refuses a line
	// that is no single call, so it never waits for the principal.
	if new_state == .Awaiting_Principal && entry.service_count == 0 {
		return errors.fail(error, ERROR_RESULT, .Bad_Value, .None, 2, state), nil
	}
	if !assistant_contract.act_state_changes(entry.state, new_state) {
		return errors.fail(error, ERROR_RESULT, .State, .None, 1, act, i64(entry.state)), nil
	}
	if refused, refusal := text_refusal(error, 3, text, assistant_contract.REPLY_TEXT_BYTES); refused {
		return refusal, nil
	}
	entry.state = new_state
	entry.text_count = copy(entry.text[:], text)
	conversation.changed = true
	return 1, entry
}

// act_state gives the state of an act.
act_state :: proc "contextless" (conversation: ^Conversation, acts_for_principal: bool, act: i64, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal {
		return no_grant(error)
	}
	entry := act_of(conversation, act)
	if entry == nil {
		return errors.fail(error, ERROR_RESULT, .Absent, .Records, 1, act)
	}
	return i64(entry.state)
}

// The decision of the principal on an act, from the word of act_poll.
Act_Decision :: enum u8 {
	Pending,
	Allowed,
	Refused,
}

// What act_ask gave: the dialog shows; the dialog of another party shows
// and the act asks again later; or the trusted display refused the dialog
// for good, or the window has no connection to it.
Act_Ask_Outcome :: enum u8 {
	Shown,
	Busy,
	Refused,
}

// The port of the act dialog, as acts_waiting_step uses it: the trusted
// display, or a stand-in of a host test.
Act_Dialog_Port :: struct {
	ask:    proc "contextless" (service, export: string) -> (serial: u64, outcome: Act_Ask_Outcome, cause: string),
	poll:   proc "contextless" (serial: u64) -> (decision: Act_Decision, known: bool),
	cancel: proc "contextless" (serial: u64),
}

// What one step of the acts that wait did, for the facts of the window.
Waiting_Event :: enum u8 {
	None,
	Shown, // The act dialog of the entry shows, with its serial in entry.dialog.
	Not_Shown, // The trusted display refused the dialog of the entry for good: cause says why.
	Decided, // The principal decided the entry.
}

// acts_waiting_step cancels the dialog of an act that left the ring,
// shows the act dialog of the oldest act that waits for the principal, and
// reads the decision of the one that shows. It runs at each turn of the
// loop of the window while an act waits: one dialog at a time. A refusal
// of the trusted display other than Busy is final: the act takes the state
// Not_Shown, and the next act that waits asks in its turn.
acts_waiting_step :: proc "contextless" (conversation: ^Conversation, port: Act_Dialog_Port) -> (waiting: bool, event: Waiting_Event, entry: ^Entry, cause: string) {
	if conversation.dialog_to_cancel != 0 {
		port.cancel(conversation.dialog_to_cancel)
		conversation.dialog_to_cancel = 0
	}
	for index in 0 ..< conversation.entry_count {
		candidate := entry_at(conversation, index)
		if candidate.kind != .Act || candidate.state != .Awaiting_Principal {
			continue
		}
		if candidate.dialog == 0 {
			serial, outcome, refusal_cause := port.ask(string(candidate.service[:candidate.service_count]), string(candidate.export[:candidate.export_count]))
			switch outcome {
			case .Busy:
				// The dialog of another party shows: ask again at the next
				// turn.
				return true, .None, nil, ""
			case .Refused:
				candidate.state = .Not_Shown
				conversation.changed = true
				// The next act that waits asks at the next turn.
				return true, .Not_Shown, candidate, refusal_cause
			case .Shown:
			}
			candidate.dialog = serial
			conversation.changed = true
			return true, .Shown, candidate, ""
		}
		decision, known := port.poll(candidate.dialog)
		if !known {
			// A dialog that the trusted display no longer knows for this
			// asker shows again: the act never takes a decision that it did
			// not see.
			candidate.dialog = 0
			return true, .None, nil, ""
		}
		switch decision {
		case .Pending:
			return true, .None, nil, ""
		case .Allowed:
			candidate.state = .Allowed_By_Principal
		case .Refused:
			candidate.state = .Refused_By_Principal
		}
		conversation.changed = true
		return true, .Decided, candidate, ""
	}
	return false, .None, nil, ""
}

// act_table keeps the typed result of an act that is Done: the columns and
// the cells, row after row, read once into the staging copy, then checked
// whole. Each refusal changes nothing (src/md/features/assistant.md, "The
// result of an act"). The argument of a refusal: 1 the act, 2 the shape, 3
// the name, 4 the total of rows, 5 the columns, 6 the cells; found is the
// row of a column or a cell, from 1.
act_table :: proc "contextless" (conversation: ^Conversation, acts_for_principal: bool, act, shape_word: i64, name: string, total_rows: i64, columns: []assistant_contract.Act_Table_Column, cells: []assistant_contract.Act_Table_Cell, error: ^errors.Error_Record) -> (result: i64, kept: ^Entry) {
	if !acts_for_principal {
		return no_grant(error), nil
	}
	entry := act_of(conversation, act)
	if entry == nil {
		return errors.fail(error, ERROR_RESULT, .Absent, .Records, 1, act), nil
	}
	if entry.state != .Done || entry.table_given {
		return errors.fail(error, ERROR_RESULT, .State, .None, 1, act, i64(entry.state)), nil
	}
	shape, shape_ok := assistant_contract.act_table_shape_of_word(shape_word)
	if !shape_ok {
		return errors.fail(error, ERROR_RESULT, .Bad_Value, .None, 2, shape_word), nil
	}
	// The name is in the call region, which the caller can change during
	// the call: it is copied once into the staging copy, and the copy is
	// checked.
	if len(name) > assistant_contract.ACT_TABLE_NAME_BYTES {
		return errors.fail(error, ERROR_RESULT, .Too_Long, .Bytes, 3, i64(len(name)), assistant_contract.ACT_TABLE_NAME_BYTES), nil
	}
	staging := &conversation.staging
	intrinsics.mem_zero(staging, size_of(Act_Table))
	name_count := copy(staging.name[:], name)
	if refused, refusal := text_refusal(error, 3, string(staging.name[:name_count]), assistant_contract.ACT_TABLE_NAME_BYTES); refused {
		return refusal, nil
	}
	column_count := len(columns)
	if column_count == 0 {
		return errors.fail(error, ERROR_RESULT, .Empty, .Records, 5, 0, assistant_contract.ACT_TABLE_COLUMN_CAPACITY), nil
	}
	if column_count > assistant_contract.ACT_TABLE_COLUMN_CAPACITY {
		return errors.fail(error, ERROR_RESULT, .Too_Long, .Records, 5, i64(column_count), assistant_contract.ACT_TABLE_COLUMN_CAPACITY), nil
	}
	if len(cells) % column_count != 0 {
		return errors.fail(error, ERROR_RESULT, .Bad_Value, .Records, 6, i64(len(cells)), i64(column_count)), nil
	}
	row_count := len(cells) / column_count
	if row_count > assistant_contract.ACT_TABLE_ROW_CAPACITY {
		return errors.fail(error, ERROR_RESULT, .Too_Long, .Records, 6, i64(row_count), assistant_contract.ACT_TABLE_ROW_CAPACITY), nil
	}
	switch shape {
	case .Record:
		if row_count != 1 || total_rows != 1 {
			return errors.fail(error, ERROR_RESULT, .Bad_Value, .Records, 6, i64(row_count), 1), nil
		}
	case .Table:
	}
	if total_rows < i64(row_count) {
		return errors.fail(error, ERROR_RESULT, .Bad_Value, .Records, 4, total_rows, i64(row_count)), nil
	}
	for index in 0 ..< column_count {
		// The copy of the record is read once; its words become the form
		// of the column here, and nowhere else.
		raw := intrinsics.volatile_load(&columns[index])
		column_name, column_ok := assistant_contract.fixed_text(raw.name[:])
		if !column_ok || column_name == "" {
			return errors.fail(error, ERROR_RESULT, .Bad_Value, .Bytes, 5, 0, assistant_contract.ACT_TABLE_NAME_BYTES, i64(index + 1)), nil
		}
		form, form_ok := column_form_of_words(raw.kind, raw.unit)
		if !form_ok {
			return errors.fail(error, ERROR_RESULT, .Bad_Value, .None, 5, raw.kind, raw.unit, i64(index + 1)), nil
		}
		staging.columns[index] = {name = raw.name, form = form}
	}
	for index in 0 ..< len(cells) {
		staging.cells[index] = intrinsics.volatile_load(&cells[index])
	}
	for index in 0 ..< len(cells) {
		cell := &staging.cells[index]
		text, cell_ok := assistant_contract.fixed_text(cell.text[:])
		// A text column holds a text and no value; a number column a
		// value and no text: each fact of a cell is in one place.
		number := !form_is_text(staging.columns[index % column_count].form)
		if !cell_ok || (number && text != "") || (!number && cell.integer != 0) {
			return errors.fail(error, ERROR_RESULT, .Bad_Value, .Bytes, 6, 0, assistant_contract.ACT_TABLE_CELL_BYTES, i64(index / column_count + 1)), nil
		}
	}
	staging.present = true
	staging.act = entry.act
	staging.shape = shape
	staging.total_rows = int(total_rows)
	staging.column_count = column_count
	staging.row_count = row_count
	slot_index := conversation.table_next
	conversation.table_next = (conversation.table_next + 1) % len(conversation.tables)
	intrinsics.mem_copy_non_overlapping(&conversation.tables[slot_index], staging, size_of(Act_Table))
	entry.table_given = true
	entry.table_slot = u8(slot_index)
	conversation.changed = true
	return 1, entry
}

// act_table_rows appends additional rows to a Table result that act_table
// started, up to ACT_TABLE_ROW_CAPACITY (64) and total_rows. Lets wide
// tables cross the 64 KiB remote call region in batches while checking
// every cell once through staging; a refusal changes nothing.
act_table_rows :: proc "contextless" (conversation: ^Conversation, acts_for_principal: bool, act: i64, cells: []assistant_contract.Act_Table_Cell, error: ^errors.Error_Record) -> (result: i64, kept: ^Entry) {
	if !acts_for_principal {
		return no_grant(error), nil
	}
	entry := act_of(conversation, act)
	if entry == nil {
		return errors.fail(error, ERROR_RESULT, .Absent, .Records, 1, act), nil
	}
	table := act_table_of(conversation, entry)
	if entry.state != .Done || table == nil || table.shape != .Table {
		return errors.fail(error, ERROR_RESULT, .State, .None, 1, act, i64(entry.state)), nil
	}
	if len(cells) == 0 {
		return errors.fail(error, ERROR_RESULT, .Empty, .Records, 2, 0, assistant_contract.ACT_TABLE_ROW_CAPACITY), nil
	}
	column_count := table.column_count
	if column_count == 0 || len(cells) % column_count != 0 {
		return errors.fail(error, ERROR_RESULT, .Bad_Value, .Records, 2, i64(len(cells)), i64(column_count)), nil
	}
	extra_rows := len(cells) / column_count
	if table.row_count + extra_rows > assistant_contract.ACT_TABLE_ROW_CAPACITY {
		return errors.fail(error, ERROR_RESULT, .Too_Long, .Records, 2, i64(table.row_count + extra_rows), assistant_contract.ACT_TABLE_ROW_CAPACITY), nil
	}
	if table.row_count + extra_rows > table.total_rows {
		return errors.fail(error, ERROR_RESULT, .Too_Long, .Records, 2, i64(table.row_count + extra_rows), i64(table.total_rows)), nil
	}
	staging := &conversation.staging
	for index in 0 ..< len(cells) {
		staging.cells[index] = intrinsics.volatile_load(&cells[index])
	}
	for index in 0 ..< len(cells) {
		cell := &staging.cells[index]
		text, cell_ok := assistant_contract.fixed_text(cell.text[:])
		number := !form_is_text(table.columns[index % column_count].form)
		if !cell_ok || (number && text != "") || (!number && cell.integer != 0) {
			return errors.fail(error, ERROR_RESULT, .Bad_Value, .Bytes, 2, 0, assistant_contract.ACT_TABLE_CELL_BYTES, i64(table.row_count + index / column_count + 1)), nil
		}
	}
	start_cell := table.row_count * column_count
	for index in 0 ..< len(cells) {
		table.cells[start_cell + index] = staging.cells[index]
	}
	table.row_count += extra_rows
	conversation.changed = true
	return i64(table.row_count), entry
}
