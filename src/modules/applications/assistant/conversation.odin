package assistant_window

import assistant_contract "modus:contract/assistant"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/value_kinds"
import "modus:system"

// The conversation of one run of the window, and the exports that the
// agent runner calls through remote (src/md/features/assistant.md, "The
// exports of the window"). Each export runs in the one thread of this
// process, between two events: no lock.

Entry_Kind :: enum u8 {
	Request, // A request of the principal.
	Reply, // The text of the model for a request.
	Reply_Refused, // A reply that the runner refused at its border.
	Act, // An act of a reply, with its state.
}

Entry :: struct {
	kind:          Entry_Kind,
	serial:        u64, // The request of the entry.
	act:           u64, // An Act: its number.
	act_kind:      assistant_contract.Act_Kind,
	state:         assistant_contract.Act_State,
	taken:         bool, // A Request: a runner took it.
	dialog:        u64, // An Act that waits: the serial of its act dialog, 0 before it shows.
	error:         errors.Error_Record, // A Reply_Refused: the record of the runner.
	text:          [assistant_contract.REPLY_TEXT_BYTES]u8, // A request, a reply, the result of an act.
	text_count:    int,
	line:          [assistant_contract.ACT_LINE_BYTES]u8, // An Act: its line.
	line_count:    int,
}

// The entries, oldest first, in a ring of CONVERSATION_ENTRY_CAPACITY:
// past it the oldest entry leaves.
entries: [assistant_contract.CONVERSATION_ENTRY_CAPACITY]Entry
entry_first: int
entry_count: int
next_serial: u64 = 1
next_act: u64 = 1
// The conversation changed: the window draws again.
conversation_changed: bool

@(rodata)
STATE_WORDS := [assistant_contract.Act_State]string {
	.Proposed             = "proposed",
	.Done                 = "done",
	.Refused              = "refused by the bridge",
	.Awaiting_Principal   = "waiting for the principal",
	.Allowed_By_Principal = "allowed by the principal",
	.Refused_By_Principal = "refused by the principal",
}

entry_at :: proc "contextless" (index: int) -> ^Entry {
	return &entries[(entry_first + index) % len(entries)]
}

// entry_add gives a new entry at the end; the oldest leaves when the ring
// is full.
entry_add :: proc "contextless" (kind: Entry_Kind, serial: u64) -> ^Entry {
	if entry_count == len(entries) {
		entry_first = (entry_first + 1) % len(entries)
		entry_count -= 1
	}
	entry := entry_at(entry_count)
	entry^ = {kind = kind, serial = serial}
	entry_count += 1
	conversation_changed = true
	return entry
}

request_of :: proc "contextless" (serial: u64) -> ^Entry {
	for index in 0 ..< entry_count {
		entry := entry_at(index)
		if entry.kind == .Request && entry.serial == serial {
			return entry
		}
	}
	return nil
}

act_of :: proc "contextless" (act: u64) -> ^Entry {
	for index in 0 ..< entry_count {
		entry := entry_at(index)
		if entry.kind == .Act && entry.act == act {
			return entry
		}
	}
	return nil
}

// request_keep keeps a request that the principal typed. A text that is not
// a text of the contract is kept as nothing: the field gives only text.
request_keep :: proc "contextless" (text: string) -> bool {
	if assistant_contract.text_check(text, assistant_contract.REQUEST_TEXT_BYTES) != .None {
		return false
	}
	entry := entry_add(.Request, next_serial)
	next_serial += 1
	entry.text_count = copy(entry.text[:], text)
	system.log_fact(.Info, Request_Kept{serial = entry.serial, text = value_kinds.text_field(text, FACT_TEXT_BYTES)})
	return true
}

// The record of a caller that does not act for the principal.
ERROR_RESULT :: -1

acts_for_principal :: proc "contextless" () -> bool {
	caller := system.service_caller()
	return caller != nil && caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0
}

// text_refusal fails a call for a text that the contract refuses.
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

// request_serial gives the serial of the oldest request of the principal that no runner took, or 0 when none waits.
//
// **What it is for.** The agent runner on the host asks for the next request through remote, then reads its text
// with [request_text](assistant.request_text).
//
// **Grant**: the caller must **act for the principal**; else `No_Grant` (-1).
@(export, link_name = "request_serial")
request_serial_export :: proc "c" (error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_RESULT, .No_Grant, .Acts_For_Principal)
	}
	for index in 0 ..< entry_count {
		entry := entry_at(index)
		if entry.kind == .Request && !entry.taken {
			return i64(entry.serial)
		}
	}
	return 0
}

// request_text gives the text of a request, and marks it taken: request_serial does not give it again.
//
// The result is the count of bytes of the text, or a negative number with an error record: `No_Grant` (-1, the
// caller does not act for the principal); `Absent` (-1, no request of the window has this serial).
@(export, link_name = "request_text")
request_text_export :: proc "c" (serial: i64, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_RESULT, .No_Grant, .Acts_For_Principal)
	}
	entry := serial > 0 ? request_of(u64(serial)) : nil
	if entry == nil {
		return errors.fail(error, ERROR_RESULT, .Absent, .Requests, 1, serial)
	}
	if !entry.taken {
		entry.taken = true
		system.log_fact(.Info, Request_Taken{serial = entry.serial})
	}
	text := string(entry.text[:entry.text_count])
	copy(result^, text)
	return i64(len(text))
}

// reply shows the text of the reply of the model to a request that a runner took.
//
// The result is the count of bytes kept, or a negative number with an error record: `No_Grant` (-1);
// `Absent` (-1, no request has the serial, or it was not taken); `Empty`, `Too_Long` or `Bad_Value` (-1,
// the text has no byte, more than 1024 bytes, or a control byte or a damaged character).
@(export, link_name = "reply")
reply_export :: proc "c" (serial: i64, text: ^string, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_RESULT, .No_Grant, .Acts_For_Principal)
	}
	request := serial > 0 ? request_of(u64(serial)) : nil
	if request == nil || !request.taken {
		return errors.fail(error, ERROR_RESULT, .Absent, .Requests, 1, serial)
	}
	if refused, result := text_refusal(error, 2, text^, assistant_contract.REPLY_TEXT_BYTES); refused {
		return result
	}
	entry := entry_add(.Reply, u64(serial))
	entry.text_count = copy(entry.text[:], text^)
	system.log_fact(.Info, Reply_Shown{serial = u64(serial), bytes = u64(entry.text_count), text = value_kinds.text_field(text^, FACT_TEXT_BYTES)})
	return i64(entry.text_count)
}

// reply_refused shows that the runner refused the reply of the model to a request at its border: the words of the error record of that refusal. No act of that reply runs.
//
// The result is 1, or a negative number with an error record: `No_Grant` (-1); `Absent` (-1, no request taken has
// the serial); `Bad_Value` (-1, a kind or a unit that names no member of the contract, or the kind None).
@(export, link_name = "reply_refused")
reply_refused_export :: proc "c" (serial, kind, unit, argument, value, limit: i64, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_RESULT, .No_Grant, .Acts_For_Principal)
	}
	request := serial > 0 ? request_of(u64(serial)) : nil
	if request == nil || !request.taken {
		return errors.fail(error, ERROR_RESULT, .Absent, .Requests, 1, serial)
	}
	kind_member, kind_ok := errors.kind_of_word(kind)
	if !kind_ok || kind_member == .None {
		return errors.fail(error, ERROR_RESULT, .Bad_Value, .None, 2, kind)
	}
	unit_member, unit_ok := errors.unit_of_word(unit)
	if !unit_ok {
		return errors.fail(error, ERROR_RESULT, .Bad_Value, .None, 3, unit)
	}
	entry := entry_add(.Reply_Refused, u64(serial))
	entry.error = errors.error_make(kind_member, unit_member, argument, value, limit)
	system.log_fact(.Info, Reply_Refused_Shown{serial = u64(serial), argument = argument, value = value, limit = limit, kind = value_kinds.text_field(errors.KIND_NAMES[kind_member], FACT_NAME_BYTES), unit = value_kinds.text_field(errors.UNIT_NAMES[unit_member], FACT_NAME_BYTES)})
	return 1
}

// act shows an act that the reply of the model to a request proposes, before the bridge answers it, and gives its number.
//
// - **serial**: the request.
// - **kind**: the kind of the act, a word of assistant.Act_Kind: 1 a line of Lex.
// - **line**: the line of the act, at most 200 bytes.
//
// The result is the number of the act, from 1, or a negative number with an error record: `No_Grant` (-1);
// `Absent` (-1, no request taken has the serial); `Bad_Value` (-1, a kind that names no member); `Empty`,
// `Too_Long` or `Bad_Value` (-1, the line).
@(export, link_name = "act")
act_export :: proc "c" (serial, kind: i64, line: ^string, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_RESULT, .No_Grant, .Acts_For_Principal)
	}
	request := serial > 0 ? request_of(u64(serial)) : nil
	if request == nil || !request.taken {
		return errors.fail(error, ERROR_RESULT, .Absent, .Requests, 1, serial)
	}
	act_kind, kind_ok := assistant_contract.act_kind_of_word(kind)
	if !kind_ok {
		return errors.fail(error, ERROR_RESULT, .Bad_Value, .None, 2, kind, i64(max(assistant_contract.Act_Kind)))
	}
	if refused, result := text_refusal(error, 3, line^, assistant_contract.ACT_LINE_BYTES); refused {
		return result
	}
	entry := entry_add(.Act, u64(serial))
	entry.act = next_act
	next_act += 1
	entry.act_kind = act_kind
	entry.state = .Proposed
	entry.line_count = copy(entry.line[:], line^)
	system.log_fact(.Info, Act_Proposed{act = entry.act, serial = u64(serial), line = value_kinds.text_field(line^, FACT_TEXT_BYTES)})
	return i64(entry.act)
}

// act_result shows the answer of the bridge to an act: done with its result, refused with why, or waiting for the principal, which shows the act dialog of the trusted display.
//
// - **act**: the number that [act](assistant.act) gave.
// - **state**: a word of assistant.Act_State that the runner may write: 2 done, 3 refused, 4 waiting for the principal.
// - **text**: the result or the refusal, as words for the principal.
//
// The result is 1, or a negative number with an error record: `No_Grant` (-1); `Absent` (-1, no act has the number);
// `Bad_Value` (-1, a state that names no member, or one that the runner may not write); `State` (-1, the act has an
// outcome already); `Empty`, `Too_Long` or `Bad_Value` (-1, the text).
@(export, link_name = "act_result")
act_result_export :: proc "c" (act, state: i64, text: ^string, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_RESULT, .No_Grant, .Acts_For_Principal)
	}
	entry := act > 0 ? act_of(u64(act)) : nil
	if entry == nil {
		return errors.fail(error, ERROR_RESULT, .Absent, .Records, 1, act)
	}
	new_state, state_ok := assistant_contract.act_state_of_word(state)
	if !state_ok || !assistant_contract.act_state_from_runner(new_state) {
		return errors.fail(error, ERROR_RESULT, .Bad_Value, .None, 2, state)
	}
	if !assistant_contract.act_state_changes(entry.state, new_state) {
		return errors.fail(error, ERROR_RESULT, .State, .None, 1, act, i64(entry.state))
	}
	if refused, result := text_refusal(error, 3, text^, assistant_contract.REPLY_TEXT_BYTES); refused {
		return result
	}
	entry.state = new_state
	entry.text_count = copy(entry.text[:], text^)
	conversation_changed = true
	system.log_fact(.Info, Act_Outcome{act = entry.act, state = value_kinds.text_field(STATE_WORDS[new_state], FACT_NAME_BYTES), text = value_kinds.text_field(text^, FACT_TEXT_BYTES)})
	return 1
}

// act_state gives the state of an act, a word of assistant.Act_State: the runner reads the decision of the principal on an act that waited.
//
// The result is the state, or a negative number with an error record: `No_Grant` (-1); `Absent` (-1, no act has
// the number).
@(export, link_name = "act_state")
act_state_export :: proc "c" (act: i64, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_RESULT, .No_Grant, .Acts_For_Principal)
	}
	entry := act > 0 ? act_of(u64(act)) : nil
	if entry == nil {
		return errors.fail(error, ERROR_RESULT, .Absent, .Records, 1, act)
	}
	return i64(entry.state)
}

// acts_waiting_step shows the act dialog of the oldest act that waits for
// the principal, and reads the decision of the one that shows. It runs at
// each turn of the loop while an act waits: one dialog at a time.
acts_waiting_step :: proc "contextless" () -> (waiting: bool) {
	for index in 0 ..< entry_count {
		entry := entry_at(index)
		if entry.kind != .Act || entry.state != .Awaiting_Principal {
			continue
		}
		waiting = true
		if entry.dialog == 0 {
			serial, cause := display_act_ask(act_name_of(string(entry.line[:entry.line_count])))
			if serial == 0 {
				// The dialog of another party shows, or none can: ask again
				// at the next turn.
				if cause != "" {
					system.log_fact(.Info, Act_Dialog_Refused{act = entry.act, cause = value_kinds.text_field(cause, FACT_TEXT_BYTES)})
				}
				return
			}
			entry.dialog = serial
			conversation_changed = true
			system.log_fact(.Info, Act_Dialog_Shown{act = entry.act, dialog = serial})
			return
		}
		decision, known := display_act_poll(entry.dialog)
		if !known {
			// A dialog that the trusted display no longer knows shows
			// again: the act never takes a decision that it did not see.
			entry.dialog = 0
			return
		}
		switch decision {
		case .Pending:
			return
		case .Allowed:
			entry.state = .Allowed_By_Principal
		case .Refused:
			entry.state = .Refused_By_Principal
		}
		conversation_changed = true
		system.log_fact(.Info, Act_Decided{act = entry.act, state = value_kinds.text_field(STATE_WORDS[entry.state], FACT_NAME_BYTES)})
		return
	}
	return
}

// act_name_of gives the name that the act dialog shows: `service.export`
// of a line, the bytes before its first "(". The compositor checks that it
// is two identifiers: the arguments never reach the trusted display.
act_name_of :: proc "contextless" (line: string) -> string {
	for character, index in transmute([]u8)line {
		if character == '(' {
			return line[:index]
		}
	}
	return line
}
