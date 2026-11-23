// The contract between the window of the assistant and the agent runner
// on the host (src/md/features/assistant.md): the bounds of the texts, the
// kinds and the states of an act, and the borders of their words. Both
// sides compile it in: the module assistant and the tool.
package assistant

import "modus:contract/text_encoding"

// The bytes of the text of one request of the principal.
REQUEST_TEXT_BYTES :: 240

// The bytes of the text of a reply of the model, and of the result of an
// act, as the window shows them.
REPLY_TEXT_BYTES :: 1024

// The bytes of the line of one act. A line of Lex that the bridge reads is
// one call: a line of the console holds 256 bytes, and an act line is one
// call with literal arguments.
ACT_LINE_BYTES :: 200

// The entries of the conversation that one run of the window keeps: a
// request, a reply, a refused reply and an act take one each.
CONVERSATION_ENTRY_CAPACITY :: 64

// The acts of one model reply at most. The window refuses an act past the
// count that the reply gave.
MODEL_ACT_CAPACITY :: 4

// The bytes of the name of the service or of the export of an act: a name
// of the system, as the root service names a process.
ACT_NAME_BYTES :: 31

// What an act asks the bridge for. The values cross the border of an export
// and of the model reply: 0 names no member.
Act_Kind :: enum u8 {
	Eval_Lex = 1, // One line of Lex, which the bridge runs through remote when it is on the read-only list.
}

// The name of each kind in a model reply.
@(rodata)
ACT_KIND_NAMES := [Act_Kind]string {
	.Eval_Lex = "eval_lex",
}

// Where an act stands. The runner writes the outcome of the bridge; the
// window writes the decision of the principal.
Act_State :: enum u8 {
	Proposed             = 1, // The window shows it; the bridge has not answered yet.
	Done                 = 2, // The bridge ran it: the text is its result.
	Refused              = 3, // The bridge refused it at its border: the text says why.
	Awaiting_Principal   = 4, // The bridge stopped it with Awaiting_Principal_Approval: the act dialog decides.
	Allowed_By_Principal = 5, // The principal allowed it on the trusted display. It does not run yet.
	Refused_By_Principal = 6, // The principal refused it on the trusted display. Nothing runs.
	Not_Shown            = 7, // The trusted display refused its act dialog for a cause other than Busy, or the window has no connection to it. Nothing runs.
}

// act_kind_of_word is the border of the word of a kind: false for a word
// that names no member.
act_kind_of_word :: proc "contextless" (word: i64) -> (kind: Act_Kind, ok: bool) {
	switch word {
	case i64(Act_Kind.Eval_Lex):
		return .Eval_Lex, true
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
// runner gives one outcome to a proposed act, and the trusted display one
// decision to an act that waits for it, or the window the final state
// Not_Shown when the trusted display cannot show it. Each other change is
// refused.
act_state_changes :: proc "contextless" (from, to: Act_State) -> bool {
	switch from {
	case .Proposed:
		return act_state_from_runner(to)
	case .Awaiting_Principal:
		return to == .Allowed_By_Principal || to == .Refused_By_Principal || to == .Not_Shown
	case .Done, .Refused, .Allowed_By_Principal, .Refused_By_Principal, .Not_Shown:
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
