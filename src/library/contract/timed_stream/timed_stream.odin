// The timed stream: what a program and the sound service agree on
// (src/md/features/timed_stream.md). A timed stream is a class protocol
// whose records say when their content must reach the device. Its first
// user is sound: the sound service is the device service of a virtio sound
// device (src/modules/system/sound); a device service of another sound
// device serves the same contract.
//
// The client and the sound service share two memory objects:
//
//   the stream ring    a ring (package ring). One command record is one
//                      request: Attach, Start, or Play of one record of
//                      frames.
//   the sample region  memory of the client, which it makes from its own
//                      budget and lends with Attach, with the right Read.
//                      A Play names a place in it, never an address.
//
// The time of a record is the system clock: the nanoseconds since boot
// that `system.nanoseconds()` gives. The service maps it to the frames of
// the device (`frame_of_time`, `time_of_frame`).
//
// The service answers the commands in order. It takes a command only when
// the completion queue has room for its completion and its table has room
// for one more pending record, so a full ring stops the client and drops
// no record. The completion of a Play comes when the device took the
// period that holds its last frame; the device plays it after a delay of
// its own.
//
// This package allocates no memory and calls no kernel operation.
//
// See [timed stream](term:timed-stream) and [sound service](term:sound-service).
package timed_stream

import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/ring"

// The role of the stream ring in the context of the sound service.
SERVICE_RING :: 0
// The role of the stream ring in the context of its client: the device
// ring of a client of a device service.
GRANT_RING :: 6
// The capacity of the stream ring: the smallest ring. The pending records
// of the service have one place for each place of the ring.
RING_CAPACITY :: ring.CAPACITY

// The format of the frames of a record. The one format today: 48000 frames
// in one second, two channels, signed 16-bit samples in little endian, the
// left one first. The word crosses the stream ring, so each value is
// explicit; None is no format, and the border refuses it.
Format :: enum u64 {
	None                   = 0,
	Signed_16_Stereo_48000 = 1,
}

FRAME_RATE :: 48000 // The frames of one second, in the one format.
CHANNELS :: 2
FRAME_BYTES :: 4 // One frame: two samples of 2 bytes.
NANOSECONDS_IN_A_SECOND :: 1_000_000_000
// The most frames of one record: 10 seconds. A record holds one place of
// the table of the service until its last frame plays.
FRAME_COUNT_LIMIT :: 10 * FRAME_RATE
// The farthest time after the earliest time that a record can take. It
// keeps each time and each frame of an accepted record far from the end of
// 64 bits.
AHEAD_LIMIT_NANOSECONDS :: 10 * NANOSECONDS_IN_A_SECOND

// The periods of the device: the service gives it PERIODS_GIVEN periods of
// PERIOD_FRAMES frames, 10 ms each, and fills each new one from the pending
// records, with zeros where no record has a frame.
PERIOD_FRAMES :: 480
PERIODS_GIVEN :: 4
PERIOD_BYTES :: PERIOD_FRAMES * FRAME_BYTES

// The frames of one second, reduced: 48000 / 10^9 is 6 / 125000. The map
// between the two clocks divides by the larger number first, so no product
// passes 64 bits.
FRAMES_IN_A_STEP :: 6
NANOSECONDS_IN_A_STEP :: 125_000
#assert(FRAME_RATE * NANOSECONDS_IN_A_STEP == FRAMES_IN_A_STEP * NANOSECONDS_IN_A_SECOND)

// A command of the client, as the kind of a command record.
Command :: enum u32 {
	None   = 0, // Not a command: Bad_Command.
	// values[0]: the handle of the sample region, as the service names it,
	// with the right Read; it came through the stream ring. Send it once,
	// before Start. values[1] to values[6] are 0. The service closes a
	// handle that came through the ring and that it refuses.
	Attach = 1,
	// The stream starts: the device plays silence until the first record.
	// Each value is 0.
	// The completion: values[0] the time of the frame 0 of the stream,
	// values[1] the latency that the service holds in nanoseconds,
	// values[2] the word of the Format of the stream.
	Start  = 2,
	// One record: values[0] the time of its first frame, values[1] the
	// word of its Format, values[2] its count of frames, values[3] the place
	// of its first frame in the sample region in bytes, a multiple of
	// FRAME_BYTES. values[4] to values[6] are 0. The completion, when the
	// device took the period of its last frame: values[0] the time of its
	// first frame by the stream clock, values[1] that frame of the stream,
	// values[2] the underruns since Start.
	Play   = 3,
}

// The status of a command: the kind of its completion record. When it is
// not Ok, the values of the completion are an error record
// (errors.completion_record), and no frame of the record plays.
Status :: enum u32 {
	Ok           = 0, // The command is done: the values are its results.
	Bad_Command  = 1, // The command is not known, or a value is wrong (play_of_record), or Start came twice.
	Out_Of_Range = 2, // A frame of the record is not in the sample region.
	No_Region    = 3, // No sample region, or the handle did not come through the stream ring.
	Late         = 4, // The first frame is before the earliest time that a record can take.
	Too_Far      = 5, // The time is more than AHEAD_LIMIT_NANOSECONDS after the earliest time.
	Overlap      = 6, // The first frame is before the end of the record accepted before it.
	Not_Started  = 7, // A Play before Start.
	Device_Error = 8, // The device needs a reset: it plays no more.
}

// command_of_ring_word is the border of the kind of a command record of
// the stream ring: the command, or false for a word that names no command,
// None included.
command_of_ring_word :: proc "contextless" (word: u32) -> (command: Command, ok: bool) {
	member, known := enum_word.member_of_word(Command, u64(word))
	if !known || member == .None {
		return .None, false
	}
	return member, true
}

// status_of_completion_word is the border of the kind of a completion
// record of the stream ring: the status, or false for a word that names no
// status. The client takes such a word as a refusal, never as a status.
status_of_completion_word :: proc "contextless" (word: u32) -> (status: Status, ok: bool) {
	return enum_word.member_of_word(Status, u64(word))
}

// One record of frames, as the border read it.
Play :: struct {
	time:        u64, // The time of its first frame, by the system clock.
	format:      Format,
	frame_count: u64,
	place:       u64, // The place of its first frame in the sample region, in bytes.
}

// Why the border refused a record.
Play_Refusal :: enum {
	None, // The record is a Play.
	Unknown_Format, // Its format word names no member of Format, or names None.
	No_Frame, // Its count is 0.
	Too_Many_Frames, // Its count is past FRAME_COUNT_LIMIT.
	Place_Not_Aligned, // Its place is not a multiple of FRAME_BYTES.
	Damaged, // A value past the four that Play names is not 0.
}

// The values that Play names: the time, the format, the count, the place.
PLAY_VALUES :: 4

// The values that each command names. Each value after them is 0: a value
// there is a damaged record.
@(rodata)
COMMAND_VALUE_COUNTS := [Command]int {
	.None   = 0,
	.Attach = 1,
	.Start  = 0,
	.Play   = PLAY_VALUES,
}

// damaged_value gives the first value past those that a command names
// that is not 0, from 0. false: the record is not damaged.
damaged_value :: proc "contextless" (command: Command, values: [7]u64) -> (index: int, damaged: bool) {
	for place in COMMAND_VALUE_COUNTS[command] ..< len(values) {
		if values[place] != 0 {
			return place, true
		}
	}
	return 0, false
}

// damaged_values gives the values of the completion of a damaged record:
// its error record names the first value that is not 0, from 1.
damaged_values :: proc "contextless" (command: Command, index: int, values: [7]u64) -> [7]u64 {
	return errors.ring_fail(u32(command), .Bad_Value, .None, i64(index + 1), record_integer(values[index]), 0)
}

// play_of_record is the one border of the values of a Play: it reads each
// value once, from the copy that the caller took, and gives the record
// with its format as the enum, or the first refusal. It reads and changes
// no state.
play_of_record :: proc "contextless" (values: [7]u64) -> (play: Play, refusal: Play_Refusal) {
	if _, damaged := damaged_value(.Play, values); damaged {
		return {}, .Damaged
	}
	format, known := enum_word.member_of_word(Format, values[1])
	if !known || format == .None {
		return {}, .Unknown_Format
	}
	switch {
	case values[2] == 0:
		return {}, .No_Frame
	case values[2] > FRAME_COUNT_LIMIT:
		return {}, .Too_Many_Frames
	case values[3] % FRAME_BYTES != 0:
		return {}, .Place_Not_Aligned
	}
	return {time = values[0], format = format, frame_count = values[2], place = values[3]}, .None
}

// A value of a record as the integer of an error record: the largest
// values stay positive.
@(private = "file")
record_integer :: proc "contextless" (value: u64) -> i64 {
	return i64(min(value, 1 << 62))
}

// play_refusal_values gives the values of the completion of a record that
// the border refused: its error record, which names the value that is
// wrong (1 the time, 2 the format, 3 the count, 4 the place, 5 to 7 the
// values that must be 0).
play_refusal_values :: proc "contextless" (refusal: Play_Refusal, values: [7]u64) -> [7]u64 {
	PLAY :: u32(Command.Play)
	switch refusal {
	case .None:
		return {}
	case .Unknown_Format:
		return errors.ring_fail(PLAY, .Bad_Value, .None, 2, record_integer(values[1]), i64(max(Format)))
	case .No_Frame:
		return errors.ring_fail(PLAY, .Too_Small, .Frames, 3, 0, 1)
	case .Too_Many_Frames:
		return errors.ring_fail(PLAY, .Too_Long, .Frames, 3, record_integer(values[2]), FRAME_COUNT_LIMIT)
	case .Place_Not_Aligned:
		return errors.ring_fail(PLAY, .Not_Multiple, .Bytes, 4, record_integer(values[3]), FRAME_BYTES, i64(values[3] % FRAME_BYTES))
	case .Damaged:
		if index, damaged := damaged_value(.Play, values); damaged {
			return damaged_values(.Play, index, values)
		}
	}
	return {}
}

// play_in_region says if each frame of a record is in a sample region of
// `region_size` bytes. The count is at most FRAME_COUNT_LIMIT, so its bytes
// do not pass 64 bits.
play_in_region :: proc "contextless" (play: Play, region_size: u64) -> bool {
	return play.place <= region_size && play.frame_count * FRAME_BYTES <= region_size - play.place
}

// The map between the system clock and the frames of the stream: the frame
// `frame` plays at the time `time`. The service sets it at Start, and moves
// it at an underrun.
Anchor :: struct {
	frame: u64,
	time:  u64,
}

// frame_of_time gives the frame that plays at a time, rounded to the
// nearest frame. false: the time is before the anchor.
frame_of_time :: proc "contextless" (anchor: Anchor, time: u64) -> (frame: u64, ok: bool) {
	if time < anchor.time {
		return 0, false
	}
	passed := time - anchor.time
	steps, rest := passed / NANOSECONDS_IN_A_STEP, passed % NANOSECONDS_IN_A_STEP
	frames := steps * FRAMES_IN_A_STEP + (rest * FRAMES_IN_A_STEP + NANOSECONDS_IN_A_STEP / 2) / NANOSECONDS_IN_A_STEP
	if frames > max(u64) - anchor.frame {
		return 0, false
	}
	return anchor.frame + frames, true
}

// time_of_frame gives the time at which a frame plays, rounded down to the
// nanosecond. false: the frame is before the anchor, or its time passes 64
// bits.
time_of_frame :: proc "contextless" (anchor: Anchor, frame: u64) -> (time: u64, ok: bool) {
	if frame < anchor.frame {
		return 0, false
	}
	passed := frame - anchor.frame
	steps, rest := passed / FRAMES_IN_A_STEP, passed % FRAMES_IN_A_STEP
	if steps > (max(u64) - NANOSECONDS_IN_A_STEP) / NANOSECONDS_IN_A_STEP {
		return 0, false
	}
	nanoseconds := steps * NANOSECONDS_IN_A_STEP + rest * NANOSECONDS_IN_A_STEP / FRAMES_IN_A_STEP
	if nanoseconds > max(u64) - anchor.time {
		return 0, false
	}
	return anchor.time + nanoseconds, true
}

// What the service does with a record that the border took.
Placement_Decision :: enum {
	Accepted, // The record has its frames: it plays.
	Late, // Its first frame is before the first frame that the service has not given to the device.
	Too_Far, // Its time is more than AHEAD_LIMIT_NANOSECONDS after the earliest time.
	Overlap, // Its first frame is before the end of the record accepted before it.
}

// The frames of an accepted record, and the times of the decision.
Placement :: struct {
	first_frame: u64,
	end_frame:   u64, // The frame after its last frame.
	earliest:    u64, // The time of the first frame not given: the earliest time that a record can take.
	latest:      u64, // The latest time that a record can take.
}

// play_place decides where a record plays. next_frame is the first frame
// that the service has not given to the device; pending_end is the frame
// after the last frame of the record accepted before, or next_frame when
// no record waits. The order of the checks is the order of the statuses:
// late, too far, then overlap. It reads and changes no state.
play_place :: proc "contextless" (play: Play, anchor: Anchor, next_frame: u64, pending_end: u64) -> (placement: Placement, decision: Placement_Decision) {
	earliest, earliest_known := time_of_frame(anchor, next_frame)
	if !earliest_known {
		return {}, .Late
	}
	placement.earliest = earliest
	placement.latest = earliest + min(AHEAD_LIMIT_NANOSECONDS, max(u64) - earliest)
	first, mapped := frame_of_time(anchor, play.time)
	switch {
	case !mapped || first < next_frame:
		return placement, .Late
	case play.time > placement.latest:
		return placement, .Too_Far
	case first < pending_end:
		placement.first_frame = first
		return placement, .Overlap
	}
	placement.first_frame = first
	placement.end_frame = first + play.frame_count
	return placement, .Accepted
}

// placement_refusal_values gives the values of the completion of a record
// that play_place did not accept: its error record. Overlap names the
// first frame of the record and the end of the record before it.
placement_refusal_values :: proc "contextless" (decision: Placement_Decision, play: Play, placement: Placement, pending_end: u64) -> (status: Status, values: [7]u64) {
	PLAY :: u32(Command.Play)
	switch decision {
	case .Accepted:
		return .Ok, {}
	case .Late:
		return .Late, errors.ring_fail(PLAY, .Too_Small, .Nanoseconds, 1, record_integer(play.time), record_integer(placement.earliest))
	case .Too_Far:
		return .Too_Far, errors.ring_fail(PLAY, .Over_Limit, .Nanoseconds, 1, record_integer(play.time), record_integer(placement.latest))
	case .Overlap:
		return .Overlap, errors.ring_fail(PLAY, .Overlap, .Frames, 1, record_integer(placement.first_frame), record_integer(pending_end))
	}
	return .Bad_Command, {}
}

// The frames that one period and one record share.
Period_Share :: struct {
	period_offset: u64, // The first shared frame, from the first frame of the period.
	record_offset: u64, // The same frame, from the first frame of the record.
	count:         u64, // 0: they share no frame.
}

// period_share gives the frames that the period that starts at
// `period_first` shares with the record of the frames [record_first,
// record_end).
period_share :: proc "contextless" (period_first: u64, record_first: u64, record_end: u64) -> Period_Share {
	period_end := period_first + PERIOD_FRAMES
	first := max(period_first, record_first)
	end := min(period_end, record_end)
	if first >= end {
		return {}
	}
	return {period_offset = first - period_first, record_offset = first - record_first, count = end - first}
}

// The names of the commands and of their values, for the sentence of the
// error record of a completion (errors.completion_record).
@(rodata)
COMMAND_NAMES := [Command]string {
	.None   = "None",
	.Attach = "Attach",
	.Start  = "Start",
	.Play   = "Play",
}

@(rodata)
ARGUMENT_NAMES := [Command][]string {
	.None   = {},
	.Attach = {"region"},
	.Start  = {},
	.Play   = {"time", "format", "count", "place"},
}

// command_of_word is the border of the command word of an error record:
// the member, or false for a word that names none.
command_of_word :: proc "contextless" (word: i64) -> (command: Command, ok: bool) {
	if word < 0 {
		return {}, false
	}
	return enum_word.member_of_word(Command, u64(word))
}

// command_name gives the name of a command from an error record, or "an
// unknown command" for a number out of `Command`.
command_name :: proc "contextless" (command: i64) -> string {
	member, ok := command_of_word(command)
	return ok ? COMMAND_NAMES[member] : "an unknown command"
}

// argument_name gives the name of a value of a command, from 1, or "" for
// a command or a value that has no name.
argument_name :: proc "contextless" (command: i64, argument: i64) -> string {
	member, ok := command_of_word(command)
	if !ok {
		return ""
	}
	names := ARGUMENT_NAMES[member]
	return argument >= 1 && argument <= i64(len(names)) ? names[argument - 1] : ""
}
