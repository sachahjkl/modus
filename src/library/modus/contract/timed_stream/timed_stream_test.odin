#+build !freestanding
package timed_stream

import "core:testing"
import "modus:contract/errors"

// A good record, which each case changes in one value.
@(private = "file")
good_record :: proc() -> [7]u64 {
	return {0 = 5 * NANOSECONDS_IN_A_SECOND, 1 = u64(Format.Signed_16_Stereo_48000), 2 = PERIOD_FRAMES, 3 = 2 * FRAME_BYTES}
}

// The kind of a command record comes from the client: None, one past the
// last command and the largest word name no command. Then each command but
// None comes back from its word.
@(test)
a_ring_word_that_names_no_command_is_refused :: proc(t: ^testing.T) {
	refused := [?]u32{u32(Command.None), u32(max(Command)) + 1, max(u32)}
	for word in refused {
		read, ok := command_of_ring_word(word)
		testing.expectf(t, !ok, "the word %d names no command, and it is taken", word)
		testing.expect_value(t, read, Command.None)
	}
	for member in Command {
		if member == .None {
			continue
		}
		read, ok := command_of_ring_word(u32(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
}

// The kind of a completion comes from the service: one past the last
// status and the largest word name no status. Then each status comes back
// from its word.
@(test)
a_completion_word_that_names_no_status_is_refused :: proc(t: ^testing.T) {
	for word in ([]u32{u32(max(Status)) + 1, max(u32)}) {
		_, ok := status_of_completion_word(word)
		testing.expectf(t, !ok, "the word %d names no status, and it is taken", word)
	}
	for member in Status {
		read, ok := status_of_completion_word(u32(member))
		testing.expect(t, ok)
		testing.expect_value(t, read, member)
	}
}

// A format word that names no member is refused, None too: 0, one past the
// last member, the largest word. The error record names the value 2 and
// the word.
@(test)
an_unknown_format_is_refused :: proc(t: ^testing.T) {
	refused := [?]u64{u64(Format.None), u64(max(Format)) + 1, max(u64)}
	for word in refused {
		values := good_record()
		values[1] = word
		play, refusal := play_of_record(values)
		testing.expect_value(t, refusal, Play_Refusal.Unknown_Format)
		testing.expect_value(t, play, Play{})
		record := errors.completion_record(play_refusal_values(refusal, values))
		testing.expect_value(t, record.kind, i64(errors.Kind.Bad_Value))
		testing.expect_value(t, record.operation, i64(Command.Play))
		testing.expect_value(t, record.argument, 2)
		testing.expect_value(t, record.value, i64(min(word, 1 << 62)))
		testing.expect_value(t, record.limit, i64(max(Format)))
	}
}

// A count of 0 and a count past the bound are refused, the largest count
// too; the bound itself is taken.
@(test)
a_count_past_its_bound_is_refused :: proc(t: ^testing.T) {
	values := good_record()
	values[2] = 0
	_, refusal := play_of_record(values)
	testing.expect_value(t, refusal, Play_Refusal.No_Frame)
	record := errors.completion_record(play_refusal_values(refusal, values))
	testing.expect_value(t, record.kind, i64(errors.Kind.Too_Small))
	testing.expect_value(t, record.unit, i64(errors.Unit.Frames))
	testing.expect_value(t, record.argument, 3)
	testing.expect_value(t, record.limit, 1)

	for count in ([]u64{FRAME_COUNT_LIMIT + 1, max(u64)}) {
		values[2] = count
		_, refusal = play_of_record(values)
		testing.expect_value(t, refusal, Play_Refusal.Too_Many_Frames)
		record = errors.completion_record(play_refusal_values(refusal, values))
		testing.expect_value(t, record.kind, i64(errors.Kind.Too_Long))
		testing.expect_value(t, record.unit, i64(errors.Unit.Frames))
		testing.expect_value(t, record.argument, 3)
		testing.expect_value(t, record.value, i64(min(count, 1 << 62)))
		testing.expect_value(t, record.limit, FRAME_COUNT_LIMIT)
	}

	for count in ([]u64{1, FRAME_COUNT_LIMIT}) {
		values[2] = count
		play, taken := play_of_record(values)
		testing.expect_value(t, taken, Play_Refusal.None)
		testing.expect_value(t, play.frame_count, count)
	}
}

// A place that is not on a frame is refused, with the rest in found.
@(test)
a_place_off_a_frame_is_refused :: proc(t: ^testing.T) {
	for place in ([]u64{1, FRAME_BYTES - 1, FRAME_BYTES + 1, max(u64)}) {
		values := good_record()
		values[3] = place
		_, refusal := play_of_record(values)
		testing.expect_value(t, refusal, Play_Refusal.Place_Not_Aligned)
		record := errors.completion_record(play_refusal_values(refusal, values))
		testing.expect_value(t, record.kind, i64(errors.Kind.Not_Multiple))
		testing.expect_value(t, record.argument, 4)
		testing.expect_value(t, record.limit, FRAME_BYTES)
		testing.expect_value(t, record.found, i64(place % FRAME_BYTES))
	}
}

// A damaged record: a value past the four of Play that is not 0. The
// record names the first such value, from 5.
@(test)
a_damaged_record_is_refused :: proc(t: ^testing.T) {
	for index in PLAY_VALUES ..< 7 {
		for value in ([]u64{1, max(u64)}) {
			values := good_record()
			values[index] = value
			play, refusal := play_of_record(values)
			testing.expect_value(t, refusal, Play_Refusal.Damaged)
			testing.expect_value(t, play, Play{})
			record := errors.completion_record(play_refusal_values(refusal, values))
			testing.expect_value(t, record.kind, i64(errors.Kind.Bad_Value))
			testing.expect_value(t, record.argument, i64(index + 1))
		}
	}
	// A damaged record with a wrong format too: the damage is named first.
	values := good_record()
	values[1] = u64(Format.None)
	values[6] = 1
	_, refusal := play_of_record(values)
	testing.expect_value(t, refusal, Play_Refusal.Damaged)
}

// Attach names one value and Start none: a value past them that is not 0
// is a damaged record, named from 1. Then the records with zeros there.
@(test)
a_damaged_attach_or_start_is_refused :: proc(t: ^testing.T) {
	for command in ([]Command{.Attach, .Start}) {
		for index in COMMAND_VALUE_COUNTS[command] ..< 7 {
			values: [7]u64
			values[0] = command == .Attach ? 5 : 0
			values[index] = max(u64)
			found, damaged := damaged_value(command, values)
			testing.expect(t, damaged)
			testing.expect_value(t, found, index)
			record := errors.completion_record(damaged_values(command, found, values))
			testing.expect_value(t, record.kind, i64(errors.Kind.Bad_Value))
			testing.expect_value(t, record.operation, i64(command))
			testing.expect_value(t, record.argument, i64(index + 1))
		}
	}
	_, damaged := damaged_value(.Attach, {0 = 5})
	testing.expect(t, !damaged)
	_, damaged = damaged_value(.Start, {})
	testing.expect(t, !damaged)
}

// A record whose frames pass the end of the region is out; a record that
// ends at the end is in.
@(test)
the_frames_of_a_record_stay_in_the_region :: proc(t: ^testing.T) {
	region_size: u64 = 16 * FRAME_BYTES
	out := [?]Play{
		{frame_count = 17},
		{place = 15 * FRAME_BYTES, frame_count = 2},
		{place = 17 * FRAME_BYTES, frame_count = 1},
		{place = max(u64) - 3, frame_count = 1},
		{place = 0, frame_count = FRAME_COUNT_LIMIT},
	}
	for play in out {
		testing.expectf(t, !play_in_region(play, region_size), "the record %v passes the region, and it is in", play)
	}
	testing.expect(t, !play_in_region({frame_count = 1}, 0))
	testing.expect(t, play_in_region({frame_count = 16}, region_size))
	testing.expect(t, play_in_region({place = 15 * FRAME_BYTES, frame_count = 1}, region_size))
}

// The map of the clocks: a time before the anchor and a frame before the
// anchor have no place; a time whose frame passes 64 bits neither. The
// largest frame whose time passes 64 bits gives false.
@(test)
the_map_refuses_what_is_before_the_anchor :: proc(t: ^testing.T) {
	anchor := Anchor{frame = 100, time = 1_000}
	_, ok := frame_of_time(anchor, 999)
	testing.expect(t, !ok)
	_, ok = frame_of_time(anchor, 0)
	testing.expect(t, !ok)
	_, ok = time_of_frame(anchor, 99)
	testing.expect(t, !ok)
	_, ok = time_of_frame(anchor, 0)
	testing.expect(t, !ok)
	_, ok = time_of_frame(anchor, max(u64))
	testing.expect(t, !ok)
	_, ok = frame_of_time({frame = max(u64), time = 0}, NANOSECONDS_IN_A_SECOND)
	testing.expect(t, !ok)
	_, ok = time_of_frame({frame = 0, time = max(u64)}, 1)
	testing.expect(t, !ok)
}

// The map against a reference in 128 bits, at the edges: the anchor, one
// nanosecond, one frame, the rounding half, one second, a day, the largest
// time.
@(test)
the_map_of_the_clocks_is_exact :: proc(t: ^testing.T) {
	anchor := Anchor{frame = 7, time = 3_000_000}
	times := [?]u64{0, 1, 10_416, 10_417, 20_833, 20_834, NANOSECONDS_IN_A_SECOND, 86_400 * NANOSECONDS_IN_A_SECOND, max(u64) - anchor.time}
	for passed in times {
		frame, ok := frame_of_time(anchor, anchor.time + passed)
		testing.expect(t, ok)
		reference := (u128(passed) * FRAME_RATE + NANOSECONDS_IN_A_SECOND / 2) / NANOSECONDS_IN_A_SECOND
		testing.expectf(t, u128(frame - anchor.frame) == reference, "%d ns after the anchor: frame %d, the reference %d", passed, frame - anchor.frame, reference)
	}
	frames := [?]u64{0, 1, 5, 6, 7, FRAME_RATE, 86_400 * FRAME_RATE}
	for passed in frames {
		time, ok := time_of_frame(anchor, anchor.frame + passed)
		testing.expect(t, ok)
		reference := u128(passed) * NANOSECONDS_IN_A_SECOND / FRAME_RATE
		testing.expectf(t, u128(time - anchor.time) == reference, "%d frames after the anchor: %d ns, the reference %d", passed, time - anchor.time, reference)
		// The time of a frame maps back to that frame: a process that asks
		// the earliest time gets the first frame not given.
		back, mapped := frame_of_time(anchor, time)
		testing.expect(t, mapped)
		testing.expect_value(t, back, anchor.frame + passed)
	}
}

// A record late by one frame, before the anchor, too far by one
// nanosecond, or over the record before it is refused, each with its
// status and its record. The earliest time and the latest time are taken.
@(test)
a_record_out_of_its_time_is_refused :: proc(t: ^testing.T) {
	anchor := Anchor{frame = 0, time = NANOSECONDS_IN_A_SECOND}
	next_frame: u64 = PERIODS_GIVEN * PERIOD_FRAMES
	earliest, _ := time_of_frame(anchor, next_frame)
	one_frame_before, _ := time_of_frame(anchor, next_frame - 1)

	for time in ([]u64{0, anchor.time - 1, anchor.time, one_frame_before}) {
		play := Play{time = time, format = .Signed_16_Stereo_48000, frame_count = 1}
		placement, decision := play_place(play, anchor, next_frame, next_frame)
		testing.expectf(t, decision == .Late, "the time %d is before the earliest time %d, and it gives %v", time, earliest, decision)
		status, values := placement_refusal_values(decision, play, placement, next_frame)
		record := errors.completion_record(values)
		testing.expect_value(t, status, Status.Late)
		testing.expect_value(t, record.kind, i64(errors.Kind.Too_Small))
		testing.expect_value(t, record.unit, i64(errors.Unit.Nanoseconds))
		testing.expect_value(t, record.argument, 1)
		testing.expect_value(t, record.limit, i64(earliest))
	}

	for time in ([]u64{earliest + AHEAD_LIMIT_NANOSECONDS + 1, max(u64)}) {
		play := Play{time = time, format = .Signed_16_Stereo_48000, frame_count = 1}
		placement, decision := play_place(play, anchor, next_frame, next_frame)
		testing.expect_value(t, decision, Placement_Decision.Too_Far)
		status, values := placement_refusal_values(decision, play, placement, next_frame)
		record := errors.completion_record(values)
		testing.expect_value(t, status, Status.Too_Far)
		testing.expect_value(t, record.kind, i64(errors.Kind.Over_Limit))
		testing.expect_value(t, record.limit, i64(earliest + AHEAD_LIMIT_NANOSECONDS))
	}

	// The record before ends one frame after the first frame of this one.
	first, _ := frame_of_time(anchor, earliest + NANOSECONDS_IN_A_SECOND)
	pending_end := first + 1
	play := Play{time = earliest + NANOSECONDS_IN_A_SECOND, format = .Signed_16_Stereo_48000, frame_count = 1}
	placement, decision := play_place(play, anchor, next_frame, pending_end)
	testing.expect_value(t, decision, Placement_Decision.Overlap)
	status, values := placement_refusal_values(decision, play, placement, pending_end)
	record := errors.completion_record(values)
	testing.expect_value(t, status, Status.Overlap)
	testing.expect_value(t, record.kind, i64(errors.Kind.Overlap))
	testing.expect_value(t, record.unit, i64(errors.Unit.Frames))
	testing.expect_value(t, record.value, i64(first))
	testing.expect_value(t, record.limit, i64(pending_end))

	// The edges that are taken: the earliest time, the latest time, and a
	// record that starts at the end of the one before.
	for time in ([]u64{earliest, earliest + AHEAD_LIMIT_NANOSECONDS}) {
		taken := Play{time = time, format = .Signed_16_Stereo_48000, frame_count = 3}
		placed, accepted := play_place(taken, anchor, next_frame, next_frame)
		testing.expect_value(t, accepted, Placement_Decision.Accepted)
		testing.expect_value(t, placed.end_frame, placed.first_frame + 3)
	}
	placed, accepted := play_place(play, anchor, next_frame, first)
	testing.expect_value(t, accepted, Placement_Decision.Accepted)
	testing.expect_value(t, placed.first_frame, first)
	testing.expect_value(t, placed.earliest, earliest)
}

// The frames that a period and a record share: none before, none after,
// none at the edge, then a record inside, over the start, over the end and
// over the whole period.
@(test)
a_period_takes_only_the_frames_of_its_span :: proc(t: ^testing.T) {
	period: u64 = 10 * PERIOD_FRAMES
	testing.expect_value(t, period_share(period, 0, period).count, 0)
	testing.expect_value(t, period_share(period, period + PERIOD_FRAMES, period + 2 * PERIOD_FRAMES).count, 0)
	testing.expect_value(t, period_share(period, period + 5, period + 5).count, 0)
	testing.expect_value(t, period_share(period, period + 5, period + 9), Period_Share{period_offset = 5, record_offset = 0, count = 4})
	testing.expect_value(t, period_share(period, period - 3, period + 2), Period_Share{period_offset = 0, record_offset = 3, count = 2})
	testing.expect_value(t, period_share(period, period + PERIOD_FRAMES - 1, period + PERIOD_FRAMES + 9), Period_Share{period_offset = PERIOD_FRAMES - 1, record_offset = 0, count = 1})
	testing.expect_value(t, period_share(period, period - 7, period + PERIOD_FRAMES + 7), Period_Share{period_offset = 0, record_offset = 7, count = PERIOD_FRAMES})
}

// The good record, last: each value as it came, the format as its member.
@(test)
a_good_record_is_read_whole :: proc(t: ^testing.T) {
	values := good_record()
	play, refusal := play_of_record(values)
	testing.expect_value(t, refusal, Play_Refusal.None)
	testing.expect_value(t, play, Play{time = values[0], format = .Signed_16_Stereo_48000, frame_count = PERIOD_FRAMES, place = 2 * FRAME_BYTES})
	testing.expect_value(t, play_refusal_values(.None, values), [7]u64{})
}

// The names of an error record: a word that names no command names no
// value either.
@(test)
a_command_that_names_no_member_has_no_name :: proc(t: ^testing.T) {
	for word in ([]i64{-1, i64(max(Command)) + 1, max(i64), min(i64)}) {
		testing.expect_value(t, command_name(word), "an unknown command")
		testing.expect_value(t, argument_name(word, 1), "")
	}
	for argument in ([]i64{0, -1, PLAY_VALUES + 1, max(i64)}) {
		testing.expect_value(t, argument_name(i64(Command.Play), argument), "")
	}
	testing.expect_value(t, argument_name(i64(Command.Play), 4), "place")
	testing.expect_value(t, command_name(i64(Command.Start)), "Start")
}
