package rights

import "modus:contract/call_outcome"
import "modus:contract/value_kinds"

// The log facts of rights (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before. A status of
// the kernel is a field of the contract enum: the reader writes the name of
// its member, where the line wrote its number.

// The bytes of the Text field of the text of an attempt: the longest has
// 44 bytes.
ATTEMPT_FIELD_BYTES :: 56

// Each attempt gave the status that it must give.
@(log_fact = "rights: ok, {allowed} allowed, {refused} refused")
Attempts_Passed :: struct {
	allowed: u64,
	refused: u64,
}

// An attempt gave another status than the one it must give.
@(log_fact = "rights: wrong answer: {attempt}: status {status}")
Attempt_Wrong :: struct {
	status:  call_outcome.Call_Outcome,
	attempt: [56]u8,
}

#assert(size_of(Attempt_Wrong) == 8 + ATTEMPT_FIELD_BYTES)

// attempt_field gives the Text field of the text of an attempt.
attempt_field :: proc "contextless" (text: string) -> [56]u8 {
	return value_kinds.text_field(text, 56)
}
