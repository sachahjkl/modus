package operation_fuzzing

import "modus:contract/call_outcome"
import "modus:contract/value_kinds"

// The log facts of the process that runs operation sequences
// (src/md/features/log_facts.md): each line, as a record of fields. Each
// fact template is the sentence that the line wrote before it was a fact,
// and the tool reads the rendered log, so it finds the address of the
// mailbox and the end of each sequence as before; a status that the line
// wrote as its number is now the name of its member.
//
// The cause of a failure comes from a closed set of sentences, each a
// literal at a call of failed: its Text field holds the words of the
// cause. A Text field is the last field, and is [N]u8 with N written out,
// as the tool reads it.

// The bytes of the Text field of the cause of a failure: the longest,
// "Memory_Physical refused the mailbox", has 35 bytes, and a zero byte;
// with the status of 4 bytes before it, the record ends on 4 bytes.
CAUSE_FIELD_BYTES :: 40

// A step of the start failed: the process stops with Failed.
@(log_fact = "operation_fuzzing: failed: {cause}: status {status}")
Failed :: struct {
	status: call_outcome.Call_Outcome,
	cause:  [40]u8,
}

// The mailbox is ready: the physical address of its first page, which the
// tool maps, and its pages.
@(log_fact = "operation_fuzzing: mailbox at {mailbox_address}, {mailbox_pages} pages")
Mailbox_Ready :: struct {
	mailbox_address: u64,
	mailbox_pages:   u64,
}

// A sequence ended: the tool waits for this fact after the results of the
// sequence. The template writes the words of
// operation_sequence.SEQUENCE_END_LINE_START and SEQUENCE_END_LINE_END,
// which the tool reads: a template is a literal, so a change of those
// constants changes it too.
@(log_fact = "operation_fuzzing: sequence {sequence} ended")
Sequence_Ended :: struct {
	sequence: u64,
}

#assert(size_of(Failed) == size_of(call_outcome.Call_Outcome) + CAUSE_FIELD_BYTES)

// cause_field gives the Text field of the cause of a failure.
cause_field :: proc "contextless" (cause: string) -> [CAUSE_FIELD_BYTES]u8 {
	return value_kinds.text_field(cause, CAUSE_FIELD_BYTES)
}
