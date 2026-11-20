package origin

import "modus:contract/value_kinds"

// The log facts of origin (src/md/features/log_facts.md): each fact
// template is the line that the process wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before. The Text
// fields are the last fields: the serial line of a fact stops at its last
// byte that is not zero.

// The bytes of the Text field of the text of a case: the longest, "revoke
// a handle that the process does not have", has 46 bytes.
CASE_FIELD_BYTES :: 48

// A case gave another answer than the one it must give.
@(log_fact = "origin: wrong answer: {case_text}")
Answer_Wrong :: struct {
	case_text: [48]u8,
}

// Each case gave its answer.
@(log_fact = "origin: ok, {cases} cases")
Cases_Passed :: struct {
	cases: u64,
}

// The time of one cycle of a lend and of a copy of a handle.
@(log_fact = "origin: lend a handle and take it back: {lend} with 4 kernel entries; copy and close: {copy_and_close} with 2")
Handle_Cycles_Measured :: struct {
	lend:           value_kinds.Time_In_Nanoseconds,
	copy_and_close: value_kinds.Time_In_Nanoseconds,
}

#assert(size_of(Answer_Wrong) == CASE_FIELD_BYTES)
