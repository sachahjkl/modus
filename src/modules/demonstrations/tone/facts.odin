package tone

import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/timed_stream"
import "modus:contract/value_kinds"

// The log facts of tone (src/md/features/log_facts.md): each fact template
// is the line that the process wrote before it was a fact, so a wait of a
// machine test on that sentence, and the frame that the test reads in it,
// read it as before. The Text fields are the last fields: the serial line
// of a fact stops at its last byte that is not zero.
//
// Each stop of the process has its fact type, written before the stop: the
// one line of a stop took parts that differ at each call. A status of the
// sound service is a word of timed_stream.Status, which is no contract
// enum of the fields: it stays its number. A status of the kernel, the kind
// and the unit of an error record write the names of their members, where
// the line wrote their numbers.

// The bytes of the Text field of the name of a command of the stream: the
// longest, "Attach", has 6 bytes.
COMMAND_FIELD_BYTES :: 8

// A completion came with a tag that no command has.
@(log_fact = "tone: a completion with the tag {tag} came, and no command has it")
Tag_Unknown :: struct {
	tag: u64,
}

// The stream ring has no room for a command.
@(log_fact = "tone: the stream ring is full")
Stream_Ring_Full :: struct {}

// No completion of a command came before the bound of a hang.
@(log_fact = "tone: no completion of {command} before the hang bound")
Completion_Missing :: struct {
	command: [8]u8,
}

// The sound service answered with a word that names no status.
@(log_fact = "tone: the sound service answered the tag {tag} with the word {word}, which names no status")
Status_Word_Unknown :: struct {
	tag:  u64,
	word: u64,
}

// A case of a refused record got another status or error record than the
// one it must get.
@(log_fact = "tone: {case_name} got the status {status_word}, the kind {kind}, the unit {unit}, the argument {argument}")
Case_Answered_Wrong :: struct {
	status_word: u64,
	kind:        errors.Kind_Word,
	unit:        errors.Unit_Word,
	argument:    i64,
	case_name:   [40]u8,
}

// The context gives no stream ring.
@(log_fact = "tone: no stream ring")
No_Stream_Ring :: struct {}

// The process cannot make its sample region.
@(log_fact = "tone: no sample region")
No_Sample_Region :: struct {}

// The sound service does not map the stream ring: no give reaches it.
@(log_fact = "tone: the sound service does not map the stream ring")
Stream_Ring_Not_Mapped :: struct {}

// The sound service refused the sample region.
@(log_fact = "tone: the sound service refused the sample region with the status {status_word}")
Sample_Region_Refused :: struct {
	status_word: u64,
}

// The kernel refused the second give of the region.
@(log_fact = "tone: the second give of the region gave the status {status}")
Second_Give_Refused :: struct {
	status: call_outcome.Call_Outcome,
}

// The sound service refused Start.
@(log_fact = "tone: the sound service refused Start with the status {status_word}")
Start_Refused :: struct {
	status_word: u64,
}

// The stream has another format than the one of the tone.
@(log_fact = "tone: the stream has the format {format}")
Format_Unknown :: struct {
	format: u64,
}

// The tone did not end before the bound of a hang.
@(log_fact = "tone: the tone did not end before the hang bound")
Tone_Not_Ended :: struct {}

// The sound service refused the tone.
@(log_fact = "tone: the sound service refused the tone with the status {status_word}")
Tone_Refused :: struct {
	status_word: u64,
}

// The tone played from another frame than the frame of its time.
@(log_fact = "tone: the tone played from the frame {frame} at {played_time}; its time names the frame {expected_frame} at {expected_time}")
Tone_At_Another_Frame :: struct {
	frame:          u64,
	played_time:    value_kinds.Time_In_Nanoseconds,
	expected_frame: u64,
	expected_time:  value_kinds.Time_In_Nanoseconds,
}

// The tone played at the frame of its time.
@(log_fact = "tone: the tone played at the frame of its time: as it must")
Tone_At_Its_Frame :: struct {}

// The bytes of the Text field of the name of a case: the longest, "a
// record past the end of the region", has 35 bytes.
CASE_FIELD_BYTES :: 40
// The bytes of the Text field of the name of a status of a timed stream:
// the longest, "Out_Of_Range" and "Device_Error", have 12 bytes.
STATUS_FIELD_BYTES :: 16

// A case of a refused record got the status and the error record that it
// must get.
@(log_fact = "tone: {case_name} is refused with {status}: as it must")
Case_Refused :: struct {
	case_name: [40]u8,
	status:    [16]u8,
}

// The sound service started the stream, with the time of the frames that it
// holds.
@(log_fact = "tone: the stream started; the service holds {held} of frames")
Stream_Started :: struct {
	held: value_kinds.Time_In_Nanoseconds,
}

// The tone played: its first frame in the stream, its frames, and the
// underruns before its end.
@(log_fact = "tone: the tone of 440 Hz played from the frame {frame} of the stream for {frames} frames; underruns before its end: {underruns}")
Tone_Played :: struct {
	frame:     u64,
	frames:    u64,
	underruns: u64,
}

#assert(size_of(Case_Refused) == CASE_FIELD_BYTES + STATUS_FIELD_BYTES)

// status_field gives the Text field of the name of a status of a timed
// stream.
status_field :: proc "contextless" (status: timed_stream.Status) -> [STATUS_FIELD_BYTES]u8 {
	return value_kinds.text_field(timed_stream_status_name(status), STATUS_FIELD_BYTES)
}
