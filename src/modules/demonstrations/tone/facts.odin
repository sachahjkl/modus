package tone

import "modus:contract/timed_stream"
import "modus:contract/value_kinds"

// The log facts of tone (src/md/features/log_facts.md): each fact template
// is the line that the process wrote before it was a fact, so a wait of a
// machine test on that sentence, and the frame that the test reads in it,
// read it as before. The Text fields are the last fields: the serial line
// of a fact stops at its last byte that is not zero.
//
// Lines stay text: the line of a stop, whose parts differ at each call, and
// the line with no value.

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
