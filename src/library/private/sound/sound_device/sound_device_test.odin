#+build !freestanding
package sound_device

import "core:testing"
import op "modus:contract/operation"
import "modus:contract/timed_stream"

// An answer of PCM_INFO for `count` streams: each an output stream of the
// one format, unless the caller changes it.
@(private = "file")
pcm_info_answer :: proc(count: int) -> (bytes: [ANSWER_CODE_BYTES + STREAM_LIMIT * PCM_INFO_BYTES]u8) {
	bytes[0], bytes[1] = u8(ANSWER_OK & 0xFF), u8(ANSWER_OK >> 8)
	for index in 0 ..< count {
		place := ANSWER_CODE_BYTES + index * PCM_INFO_BYTES
		bytes[place + PCM_INFO_FORMATS] = 1 << FORMAT_SIGNED_16
		bytes[place + PCM_INFO_RATES] = 1 << RATE_48000
		bytes[place + PCM_INFO_DIRECTION] = DIRECTION_OUTPUT
		bytes[place + PCM_INFO_CHANNELS_LEAST] = 1
		bytes[place + PCM_INFO_CHANNELS_MOST] = timed_stream.CHANNELS
	}
	return
}

@(private = "file")
answer_length :: proc(count: int) -> u32 {
	return u32(ANSWER_CODE_BYTES + count * PCM_INFO_BYTES)
}

// A code with fewer bytes than its size, an answer with no byte, and a
// code that is not Ok are not an answer that succeeded.
@(test)
a_short_or_refused_answer_is_not_ok :: proc(t: ^testing.T) {
	bytes := pcm_info_answer(0)
	for length in ([]u32{0, ANSWER_CODE_BYTES - 1}) {
		answer, _ := answer_of(bytes[:], length)
		testing.expect_value(t, answer, Answer.Short)
	}
	answer, _ := answer_of(bytes[:ANSWER_CODE_BYTES - 1], ANSWER_CODE_BYTES)
	testing.expect_value(t, answer, Answer.Short)
	bytes[0] += 1
	code: u32
	answer, code = answer_of(bytes[:], ANSWER_CODE_BYTES)
	testing.expect_value(t, answer, Answer.Refused)
	testing.expect_value(t, code, u32(ANSWER_OK + 1))
}

// A short PCM_INFO: one byte less than the records asked, no record, a
// copy shorter than the length that the device says; then a refused code,
// and streams that do not hold the format: an input, no S16, no 48000,
// one channel at most, three channels at least.
@(test)
a_short_or_foreign_pcm_info_gives_no_stream :: proc(t: ^testing.T) {
	bytes := pcm_info_answer(2)
	_, choice, _ := stream_of_answer(bytes[:], answer_length(2) - 1, 2)
	testing.expect_value(t, choice, Stream_Choice.Short)
	_, choice, _ = stream_of_answer(bytes[:], answer_length(0), 1)
	testing.expect_value(t, choice, Stream_Choice.Short)
	_, choice, _ = stream_of_answer(bytes[:answer_length(2) - 1], answer_length(2), 2)
	testing.expect_value(t, choice, Stream_Choice.Short)
	_, choice, _ = stream_of_answer(bytes[:], answer_length(2), 0)
	testing.expect_value(t, choice, Stream_Choice.Short)

	refused := pcm_info_answer(1)
	refused[1] = 0
	_, choice, _ = stream_of_answer(refused[:], answer_length(1), 1)
	testing.expect_value(t, choice, Stream_Choice.Refused)

	changes := [?]struct {
		offset: int,
		value:  u8,
	} {
		{PCM_INFO_DIRECTION, DIRECTION_OUTPUT + 1},
		{PCM_INFO_FORMATS, 0},
		{PCM_INFO_RATES, 0},
		{PCM_INFO_CHANNELS_MOST, timed_stream.CHANNELS - 1},
		{PCM_INFO_CHANNELS_LEAST, timed_stream.CHANNELS + 1},
	}
	for change in changes {
		foreign := pcm_info_answer(1)
		foreign[ANSWER_CODE_BYTES + change.offset] = change.value
		_, choice, _ = stream_of_answer(foreign[:], answer_length(1), 1)
		testing.expectf(t, choice == .None_Of_The_Format, "the byte %d at %d gives %v", change.value, change.offset, choice)
	}
}

// The first stream of the format is chosen, past a stream that is not.
@(test)
the_first_stream_of_the_format_is_chosen :: proc(t: ^testing.T) {
	bytes := pcm_info_answer(3)
	bytes[ANSWER_CODE_BYTES + PCM_INFO_DIRECTION] = DIRECTION_OUTPUT + 1
	stream, choice, code := stream_of_answer(bytes[:], answer_length(3), 3)
	testing.expect_value(t, choice, Stream_Choice.Chosen)
	testing.expect_value(t, stream, 1)
	testing.expect_value(t, code, ANSWER_OK)
}

// Three periods in flight, for the cases of the used entries.
@(private = "file")
three_periods :: proc() -> (periods: Periods) {
	for _ in 0 ..< 3 {
		_, _, _ = period_take(&periods)
	}
	return
}

// A bad used id (not a head, past the slots, the largest), a period not
// in flight, a period out of order, and a status that is not Ok are
// refused, and the periods do not change.
@(test)
a_used_entry_that_the_device_must_not_give_is_refused :: proc(t: ^testing.T) {
	cases := [?]struct {
		id:      u32,
		status:  u32,
		problem: Used_Problem,
	} {
		{1, ANSWER_OK, .Not_A_Head},
		{DESCRIPTORS_OF_A_PERIOD - 1, ANSWER_OK, .Not_A_Head},
		{timed_stream.PERIODS_GIVEN * DESCRIPTORS_OF_A_PERIOD, ANSWER_OK, .Not_A_Head},
		{max(u32), ANSWER_OK, .Not_A_Head},
		{3 * DESCRIPTORS_OF_A_PERIOD, ANSWER_OK, .Not_Given},
		{1 * DESCRIPTORS_OF_A_PERIOD, ANSWER_OK, .Out_Of_Order},
		{0, 0, .Refused},
		{0, ANSWER_OK + 1, .Refused},
	}
	for case_of in cases {
		periods := three_periods()
		before := periods
		_, problem := period_used(&periods, case_of.id, case_of.status)
		testing.expectf(t, problem == case_of.problem, "the id %d with the status %x gives %v", case_of.id, case_of.status, problem)
		testing.expect(t, periods == before)
	}
	_, ok := period_status_slot(1)
	testing.expect(t, !ok)
	_, ok = period_status_slot(max(u32))
	testing.expect(t, !ok)
}

// The periods end in order, each gives the end of the frames taken, and a
// free slot takes the next frames.
@(test)
the_periods_end_in_order :: proc(t: ^testing.T) {
	periods := three_periods()
	for index in 0 ..< 3 {
		end, problem := period_used(&periods, u32(index) * DESCRIPTORS_OF_A_PERIOD, ANSWER_OK)
		testing.expect_value(t, problem, Used_Problem.None)
		testing.expect_value(t, end, u64(index + 1) * timed_stream.PERIOD_FRAMES)
	}
	testing.expect_value(t, periods.in_flight, 0)
	slot, first, ok := period_take(&periods)
	testing.expect(t, ok)
	testing.expect_value(t, slot, 0)
	testing.expect_value(t, first, 3 * timed_stream.PERIOD_FRAMES)
	for _ in 1 ..< timed_stream.PERIODS_GIVEN {
		_, _, ok = period_take(&periods)
		testing.expect(t, ok)
	}
	_, _, ok = period_take(&periods)
	testing.expect(t, !ok)
}

// An underrun needs both: no period in flight and the time past the frames
// given. A hold starts one nanosecond past the bound ahead.
@(test)
an_underrun_and_a_hold_are_decided_by_the_time :: proc(t: ^testing.T) {
	anchor := timed_stream.Anchor{frame = 0, time = timed_stream.NANOSECONDS_IN_A_SECOND}
	periods := Periods{next_frame = timed_stream.PERIODS_GIVEN * timed_stream.PERIOD_FRAMES, oldest_frame = timed_stream.PERIODS_GIVEN * timed_stream.PERIOD_FRAMES}
	end, _ := timed_stream.time_of_frame(anchor, periods.next_frame)
	testing.expect(t, !underrun(&periods, anchor, end))
	testing.expect(t, underrun(&periods, anchor, end + 1))
	periods.in_flight = 1
	testing.expect(t, !underrun(&periods, anchor, end + 1))

	held, _ := refill_hold(&periods, anchor, end - AHEAD_OF_THE_DEVICE_LIMIT_NANOSECONDS)
	testing.expect(t, !held)
	until: u64
	held, until = refill_hold(&periods, anchor, end - AHEAD_OF_THE_DEVICE_LIMIT_NANOSECONDS - 1)
	testing.expect(t, held)
	testing.expect_value(t, until, end - AHEAD_OF_THE_DEVICE_LIMIT_NANOSECONDS)
	held, _ = refill_hold(&periods, anchor, end + 1)
	testing.expect(t, !held)
}

// The handle of an Attach: one that did not come through the ring is
// refused and never closed; each other refusal closes it; a good one is
// kept.
@(test)
a_refused_attach_closes_the_handle_that_the_client_gave :: proc(t: ^testing.T) {
	refusal, close := attach_decision(.Memory, true, false, false)
	testing.expect_value(t, refusal, Attach_Refusal.Not_Through_The_Ring)
	testing.expect(t, !close)
	cases := [?]struct {
		kind:     op.Object_Kind,
		has_read: bool,
		attached: bool,
		refusal:  Attach_Refusal,
	} {
		{.Memory, true, true, .Attached_Already},
		{.Program, true, false, .Not_Memory},
		{.None, true, false, .Not_Memory},
		{.Memory, false, false, .No_Read},
	}
	for case_of in cases {
		refusal, close = attach_decision(case_of.kind, case_of.has_read, true, case_of.attached)
		testing.expect_value(t, refusal, case_of.refusal)
		testing.expect(t, close)
	}
	refusal, close = attach_decision(.Memory, true, true, false)
	testing.expect_value(t, refusal, Attach_Refusal.None)
	testing.expect(t, !close)
}
