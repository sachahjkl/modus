// The decisions of the sound service that read what the device and the
// client wrote (src/md/features/timed_stream.md): the answers of the
// control queue, the periods that the device ends, the hold of the periods
// when the device takes them faster than their time, an underrun, and the
// handle of a sample region. The sound service is the one user.
//
// The package has no state of its own and makes no kernel call, so a host
// test gives each answer that a device must not give.
package sound_device

import op "modus:contract/operation"
import "modus:contract/timed_stream"

// The code of a control answer that succeeded (virtio 1.2, 5.14.6).
ANSWER_OK :: 0x8000
// The bytes of the code at the start of each answer and of each status.
ANSWER_CODE_BYTES :: 4

// One record of PCM_INFO, and its fields.
PCM_INFO_BYTES :: 32
PCM_INFO_FORMATS :: 8
PCM_INFO_RATES :: 16
PCM_INFO_DIRECTION :: 24
PCM_INFO_CHANNELS_LEAST :: 25
PCM_INFO_CHANNELS_MOST :: 26
DIRECTION_OUTPUT :: 0
// The one format: the bit of S16 in the formats, of 48000 in the rates.
FORMAT_SIGNED_16 :: 5
RATE_48000 :: 7
// The streams that the service asks about: QEMU has at most 10.
STREAM_LIMIT :: 10

// The descriptors of the request of one period: the header, the frames,
// the status.
DESCRIPTORS_OF_A_PERIOD :: 3

// The time of one period.
PERIOD_NANOSECONDS :: timed_stream.PERIOD_FRAMES * timed_stream.NANOSECONDS_IN_A_STEP / timed_stream.FRAMES_IN_A_STEP
#assert(PERIOD_NANOSECONDS * timed_stream.FRAMES_IN_A_STEP == timed_stream.PERIOD_FRAMES * timed_stream.NANOSECONDS_IN_A_STEP)
// How far the frames given can be ahead of now. The device takes the
// periods as fast as it plays them; at its start QEMU takes some at once
// into its mixer, fewer than the periods given. Past this bound the device
// takes them faster than their time: the service holds the next period.
AHEAD_OF_THE_DEVICE_LIMIT_NANOSECONDS :: 3 * timed_stream.PERIODS_GIVEN * PERIOD_NANOSECONDS

// What a control answer says.
Answer :: enum {
	Ok, // The code is ANSWER_OK.
	Short, // The device wrote fewer bytes than the code, or than the answer needs.
	Refused, // The code is another one.
}

// answer_of reads the code of a control answer of `length` bytes, as the
// device said, in the copy `response`.
answer_of :: proc "contextless" (response: []u8, length: u32) -> (answer: Answer, code: u32) {
	if length < ANSWER_CODE_BYTES || len(response) < ANSWER_CODE_BYTES {
		return .Short, 0
	}
	code = u32_of(response, 0)
	return code == ANSWER_OK ? .Ok : .Refused, code
}

@(private = "file")
u32_of :: proc "contextless" (bytes: []u8, offset: int) -> u32 {
	return u32(bytes[offset]) | u32(bytes[offset + 1]) << 8 | u32(bytes[offset + 2]) << 16 | u32(bytes[offset + 3]) << 24
}

@(private = "file")
u64_of :: proc "contextless" (bytes: []u8, offset: int) -> u64 {
	return u64(u32_of(bytes, offset)) | u64(u32_of(bytes, offset + 4)) << 32
}

// What the answer of PCM_INFO gives.
Stream_Choice :: enum {
	Chosen, // An output stream plays the one format.
	Short, // The device wrote fewer records than it was asked for, or no code.
	Refused, // The code is not ANSWER_OK.
	None_Of_The_Format, // No stream that it described plays the one format.
}

// stream_of_answer reads the answer of PCM_INFO for `asked` streams, and
// gives the first output stream whose formats, rates and channels hold the
// one format. A device that wrote fewer bytes than `asked` records is
// refused whole: a record that it did not write is never read.
stream_of_answer :: proc "contextless" (response: []u8, length: u32, asked: u32) -> (stream: u32, choice: Stream_Choice, code: u32) {
	answer: Answer
	answer, code = answer_of(response, length)
	switch answer {
	case .Ok:
	case .Short:
		return 0, .Short, code
	case .Refused:
		return 0, .Refused, code
	}
	written := min(u64(length), u64(len(response)))
	if asked == 0 || written < ANSWER_CODE_BYTES + u64(asked) * PCM_INFO_BYTES {
		return 0, .Short, code
	}
	for index in 0 ..< asked {
		place := ANSWER_CODE_BYTES + int(index) * PCM_INFO_BYTES
		formats := u64_of(response, place + PCM_INFO_FORMATS)
		rates := u64_of(response, place + PCM_INFO_RATES)
		plays_the_format := formats & (1 << FORMAT_SIGNED_16) != 0 && rates & (1 << RATE_48000) != 0
		holds_the_channels := response[place + PCM_INFO_CHANNELS_LEAST] <= timed_stream.CHANNELS && timed_stream.CHANNELS <= response[place + PCM_INFO_CHANNELS_MOST]
		if response[place + PCM_INFO_DIRECTION] == DIRECTION_OUTPUT && plays_the_format && holds_the_channels {
			return index, .Chosen, code
		}
	}
	return 0, .None_Of_The_Format, code
}

// A period with the device.
Period_Slot :: struct {
	in_flight:   bool,
	first_frame: u64,
}

// The periods with the device. The device must end them in the order in
// which the service gave them: each ends the oldest one in flight.
Periods :: struct {
	slots:        [timed_stream.PERIODS_GIVEN]Period_Slot,
	in_flight:    u32,
	next_frame:   u64, // The first frame not given to the device.
	oldest_frame: u64, // The first frame of the oldest period in flight, or next_frame with none.
}

// period_take takes a free slot for the next period: its frames start at
// next_frame. false: each slot is in flight.
period_take :: proc "contextless" (periods: ^Periods) -> (slot: u32, first_frame: u64, ok: bool) {
	for &candidate, index in periods.slots {
		if !candidate.in_flight {
			candidate = {in_flight = true, first_frame = periods.next_frame}
			first_frame = periods.next_frame
			periods.next_frame += timed_stream.PERIOD_FRAMES
			periods.in_flight += 1
			return u32(index), first_frame, true
		}
	}
	return 0, 0, false
}

// Why a used entry of the transmit queue is refused.
Used_Problem :: enum {
	None,
	Not_A_Head, // The descriptor is not the first of the request of a period.
	Not_Given, // Its period is not in flight.
	Out_Of_Order, // Its period is not the oldest in flight.
	Refused, // The device wrote a status that is not ANSWER_OK.
}

// period_used reads one used entry of the transmit queue: the first
// descriptor `id` that the device names, and the `status` that it wrote
// for that period. It ends the period and gives the end of the frames that
// the device took, or the problem, and then changes nothing.
period_used :: proc "contextless" (periods: ^Periods, id: u32, status: u32) -> (taken_end: u64, problem: Used_Problem) {
	slot := id / DESCRIPTORS_OF_A_PERIOD
	switch {
	case id % DESCRIPTORS_OF_A_PERIOD != 0 || slot >= timed_stream.PERIODS_GIVEN:
		return 0, .Not_A_Head
	case !periods.slots[slot].in_flight:
		return 0, .Not_Given
	case periods.slots[slot].first_frame != periods.oldest_frame:
		return 0, .Out_Of_Order
	case status != ANSWER_OK:
		return 0, .Refused
	}
	periods.slots[slot].in_flight = false
	periods.in_flight -= 1
	periods.oldest_frame += timed_stream.PERIOD_FRAMES
	return periods.oldest_frame, .None
}

// period_status_slot gives the slot of a used entry whose status the
// caller reads: the slot of its first descriptor, or false for an id that
// names no slot.
period_status_slot :: proc "contextless" (id: u32) -> (slot: u32, ok: bool) {
	slot = id / DESCRIPTORS_OF_A_PERIOD
	return slot, id % DESCRIPTORS_OF_A_PERIOD == 0 && slot < timed_stream.PERIODS_GIVEN
}

// underrun says if the device ran out: no period in flight, and the time
// past the end of the frames given. A device can hold no period before
// that time: it took several at once.
underrun :: proc "contextless" (periods: ^Periods, anchor: timed_stream.Anchor, now: u64) -> bool {
	if periods.in_flight != 0 {
		return false
	}
	end, known := timed_stream.time_of_frame(anchor, periods.next_frame)
	return !known || now > end
}

// refill_hold says if the service holds the next period: the frames given
// end more than AHEAD_OF_THE_DEVICE_LIMIT_NANOSECONDS after now, so the
// device took them faster than their time. until: the time at which the
// next period can go.
refill_hold :: proc "contextless" (periods: ^Periods, anchor: timed_stream.Anchor, now: u64) -> (held: bool, until: u64) {
	end, known := timed_stream.time_of_frame(anchor, periods.next_frame)
	if !known {
		return false, 0
	}
	if end <= now || end - now <= AHEAD_OF_THE_DEVICE_LIMIT_NANOSECONDS {
		return false, 0
	}
	return true, end - AHEAD_OF_THE_DEVICE_LIMIT_NANOSECONDS
}

// Why the service refuses the handle of an Attach.
Attach_Refusal :: enum {
	None,
	Not_Through_The_Ring, // The handle did not come through the stream ring: it is not the client's to give.
	Attached_Already, // A sample region is attached.
	Not_Memory, // The handle names no memory object.
	No_Read, // The handle has no right Read.
}

// attach_decision decides on the handle of an Attach from what Handle_State
// gave. close: the service closes the handle, because the client gave it
// and the service keeps it not. A handle that did not come through the
// ring can be a handle of the service itself, so it is never closed.
attach_decision :: proc "contextless" (kind: op.Object_Kind, has_read: bool, through: bool, attached_already: bool) -> (refusal: Attach_Refusal, close: bool) {
	switch {
	case !through:
		return .Not_Through_The_Ring, false
	case attached_already:
		return .Attached_Already, true
	case kind != .Memory:
		return .Not_Memory, true
	case !has_read:
		return .No_Read, true
	}
	return .None, false
}
