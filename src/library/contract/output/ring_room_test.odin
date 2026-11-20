#+build !freestanding
package output

import "core:testing"
import "modus:contract/errors"

// The counts that a hostile reader writes: a read one past the write, at
// the first counts and at the last ones, and a read that leaves one
// compartment past the capacity. Each one
// is Broken for each pace, and never a wait on a word that is never equal.
@(test)
a_read_past_the_write_breaks_the_ring :: proc(t: ^testing.T) {
	CAPACITY :: 32
	Case :: struct {
		write, read: u32,
	}
	cases := [?]Case{{10, 11}, {0, 1}, {CAPACITY + 1, 0}, {max(u32), max(u32) - CAPACITY - 1}}
	for item in cases {
		for pace in Wiring_Pace {
			room := ring_room_of(item.write, item.read, CAPACITY, 1, pace)
			testing.expectf(t, room == .Broken, "the write %d and the read %d of the pace %v give %v", item.write, item.read, pace, room)
		}
	}
}

// A full ring holds the writer for the paces Writer_Chooses and
// Always_Holds_Writer, and refuses for Never_Holds_Writer; one compartment
// short of the need is full too; room comes last, at the edges: an empty
// ring, the need equal to the room, counts that wrap.
@(test)
a_ring_has_room_holds_or_refuses_by_its_pace :: proc(t: ^testing.T) {
	CAPACITY :: 32
	testing.expect_value(t, ring_room_of(CAPACITY, 0, CAPACITY, 1, .Writer_Chooses), Ring_Room.Holds)
	testing.expect_value(t, ring_room_of(CAPACITY, 0, CAPACITY, 1, .Always_Holds_Writer), Ring_Room.Holds)
	testing.expect_value(t, ring_room_of(CAPACITY, 0, CAPACITY, 1, .Never_Holds_Writer), Ring_Room.Refuses)
	testing.expect_value(t, ring_room_of(CAPACITY - 1, 0, CAPACITY, 2, .Writer_Chooses), Ring_Room.Holds)
	testing.expect_value(t, ring_room_of(CAPACITY - 1, 0, CAPACITY, 1, .Writer_Chooses), Ring_Room.Room)
	testing.expect_value(t, ring_room_of(0, 0, CAPACITY, CAPACITY, .Writer_Chooses), Ring_Room.Room)
	testing.expect_value(t, ring_room_of(3, max(u32) - 2, CAPACITY, 3, .Never_Holds_Writer), Ring_Room.Room)
}

// The step of a write: with no wait, a full ring of the pace
// Writer_Chooses gives Full, also beside a ring that always holds; a ring
// that always holds makes the writer wait, with or without wait; no full
// ring gives the write.
@(test)
the_step_of_a_write_follows_the_rings_that_hold_it :: proc(t: ^testing.T) {
	testing.expect_value(t, write_step_of(true, false, false), Write_Step.Full)
	testing.expect_value(t, write_step_of(true, true, false), Write_Step.Full)
	testing.expect_value(t, write_step_of(false, true, false), Write_Step.Wait)
	testing.expect_value(t, write_step_of(true, false, true), Write_Step.Wait)
	testing.expect_value(t, write_step_of(false, true, true), Write_Step.Wait)
	testing.expect_value(t, write_step_of(false, false, false), Write_Step.Write)
	testing.expect_value(t, write_step_of(false, false, true), Write_Step.Write)
}

// A hostile writer: a count of compartments one past the capacity, the
// largest count, and full completions at their capacity and past it. Each
// is refused with its error record; a ring that can be read comes last.
@(test)
a_hostile_writer_is_refused_before_a_read :: proc(t: ^testing.T) {
	CAPACITY :: 32
	for write in ([?]u32{CAPACITY + 1, max(u32)}) {
		fault, refusal := reader_ring_fault_of(write, 0, CAPACITY, 0, 0, CAPACITY)
		testing.expect_value(t, fault, Reader_Ring_Fault.Count_Past_Capacity)
		testing.expect_value(t, refusal, errors.error_make(.Bad_Value, .Records, 0, i64(write), CAPACITY))
	}
	for completions in ([?]u32{CAPACITY, CAPACITY + 1, max(u32)}) {
		fault, refusal := reader_ring_fault_of(1, 0, CAPACITY, completions, 0, CAPACITY)
		testing.expect_value(t, fault, Reader_Ring_Fault.Completions_Full)
		testing.expect_value(t, refusal, errors.error_make(.Full, .Records, 0, i64(completions), CAPACITY))
	}
	fault, refusal := reader_ring_fault_of(CAPACITY, 0, CAPACITY, CAPACITY - 1, 0, CAPACITY)
	testing.expect_value(t, fault, Reader_Ring_Fault.None)
	testing.expect_value(t, refusal, errors.Error_Record{})
}

// The count of a gap at its edges, on a ring with no condition and on a
// ring with one: at the largest count, the gap stays as it was and the
// writer closes the end; below it, each refusal counts one, the first one
// starts the gap at its serial, and a whole ring of refusals counts the
// capacity.
@(test)
a_gap_count_stops_at_its_largest_count :: proc(t: ^testing.T) {
	CAPACITY :: 32
	for filtered in ([?]bool{false, true}) {
		most := gap_count_most(filtered)
		at_most := Gap_State{count = most, first = 7}
		after, step := gap_after_refused_record(at_most, 9, filtered)
		testing.expectf(t, step == .Past_The_Count && after == at_most, "filtered %v: the largest count gave %v and %v", filtered, step, after)
		for count in ([?]u32{1, CAPACITY - 1, CAPACITY, most - 1}) {
			after, step = gap_after_refused_record({count = count, first = 7}, 9, filtered)
			testing.expectf(t, step == .Counted && after.count == count + 1 && after.first == 7, "filtered %v: the count %d gave %v and %v", filtered, count, step, after)
		}
		// The first refusal starts the gap at its serial.
		after, step = gap_after_refused_record({}, 31, filtered)
		testing.expect(t, step == .Counted && after == Gap_State{count = 1, first = 31})
		gap: Gap_State
		for serial in u32(31) ..< 31 + CAPACITY {
			gap, step = gap_after_refused_record(gap, serial, filtered)
			testing.expect_value(t, step, Gap_Step.Counted)
		}
		testing.expect(t, gap == Gap_State{count = CAPACITY, first = 31})
	}
	// The largest count of each kind of ring.
	testing.expect_value(t, gap_count_most(false), max(u32))
	testing.expect_value(t, gap_count_most(true), SERIAL_FORWARD_MOST - 1)
}

// Three rings refuse one write: the one at its largest count closes, and
// counts once in the rings past their gap; the two others count the
// record, each in its own gap.
@(test)
a_ring_past_its_gap_closes_alone :: proc(t: ^testing.T) {
	rings := [3]Gap_State{{count = max(u32), first = 1}, {}, {count = 5, first = 40}}
	past := 0
	for &gap in rings {
		after, step := gap_after_refused_record(gap, 45, false)
		switch step {
		case .Counted:
			gap = after
		case .Past_The_Count:
			past += 1
		}
	}
	testing.expect_value(t, past, 1)
	testing.expect(t, rings[0] == Gap_State{count = max(u32), first = 1})
	testing.expect(t, rings[1] == Gap_State{count = 1, first = 45})
	testing.expect(t, rings[2] == Gap_State{count = 6, first = 40})
}

// The count held at its edges, look by look, as the writer counts them:
// a wait that ends at its deadline counts in held and in refused; a wake
// before the room counts no second hold; a ring that closes during the
// wait leaves the next look free to write, with one hold; a full ring of
// the pace Writer_Chooses holds a writer that waits; a write that never
// waits counts nothing; Full with no wait counts in refused only.
@(test)
the_writes_that_waited_count_once :: proc(t: ^testing.T) {
	before := Writer_Counts{written = 3, refused = 2, held = 4}
	timed_out := write_counts_after(before, .Wait, false, true)
	testing.expect(t, timed_out.held == 5 && timed_out.refused == 3 && timed_out.written == 3)
	// A second look of the same write that reaches its deadline: no hold more.
	again := write_counts_after(write_counts_after(before, .Wait, false, false), .Wait, true, true)
	testing.expect(t, again.held == 5 && again.refused == 3)
	woken := write_counts_after(write_counts_after(before, .Wait, false, false), .Wait, true, false)
	testing.expect(t, woken.held == 5 && woken.refused == 2)
	// The ring that held the writer closed: the next look holds nothing.
	closed := write_counts_after(write_counts_after(before, .Wait, false, false), write_step_of(false, false, true), true, false)
	testing.expect(t, closed.held == 5 && closed.refused == 2)
	chooses := write_counts_after(before, write_step_of(true, false, true), false, false)
	testing.expect(t, chooses.held == 5 && chooses.refused == 2)
	testing.expect_value(t, write_counts_after(before, .Write, false, false), before)
	full := write_counts_after(before, write_step_of(true, false, false), false, false)
	testing.expect(t, full.held == 4 && full.refused == 3)
	// A write with no wait that a full ring of the pace Always_Holds_Writer
	// held, beside a full ring of the pace Writer_Chooses: the first ring
	// closes during the wait, and the next look finds the second, which
	// gives Full. One hold and one refusal, each counted once.
	first_look := write_step_of(true, true, false)
	testing.expect_value(t, first_look, Write_Step.Wait)
	waited := write_counts_after(before, first_look, false, false)
	second_look := write_step_of(true, false, false)
	testing.expect_value(t, second_look, Write_Step.Full)
	then_full := write_counts_after(waited, second_look, true, false)
	testing.expect(t, then_full.held == 5 && then_full.refused == 3 && then_full.written == 3)
}

// The rings that take the record of a write: only a ring with room; a ring
// that skips it, refuses it, holds or broke takes nothing. A record that
// each ring refused for its reader is taken by none, and counts as
// discarded, not as written; one ring with room is enough to count it
// written.
@(test)
a_record_that_each_ring_refused_is_discarded :: proc(t: ^testing.T) {
	for room in Ring_Room {
		testing.expectf(t, !ring_takes_record(true, room), "a ring that skips the record took it with the room %v", room)
	}
	testing.expect(t, !ring_takes_record(false, .Refuses))
	testing.expect(t, !ring_takes_record(false, .Holds))
	testing.expect(t, !ring_takes_record(false, .Broken))
	before := Writer_Counts{written = 10, discarded = 2}
	Case :: struct {
		rings:     [3]Ring_Room,
		skips:     [3]bool,
		written:   u64,
		discarded: u64,
	}
	cases := [?]Case {
		{rings = {.Refuses, .Refuses, .Refuses}, written = 10, discarded = 3},
		{rings = {.Refuses, .Broken, .Refuses}, written = 10, discarded = 3},
		{rings = {.Room, .Room, .Room}, skips = {true, true, true}, written = 10, discarded = 3},
		{rings = {.Refuses, .Room, .Refuses}, skips = {false, true, false}, written = 10, discarded = 3},
		{rings = {.Refuses, .Room, .Refuses}, written = 11, discarded = 2},
		{rings = {.Room, .Room, .Room}, written = 11, discarded = 2},
	}
	for item in cases {
		taken := false
		for room, index in item.rings {
			if ring_takes_record(item.skips[index], room) {
				taken = true
			}
		}
		after := counts_after_write(before, taken)
		testing.expectf(t, after.written == item.written && after.discarded == item.discarded, "%v gave written %d and discarded %d", item, after.written, after.discarded)
	}
}

// The wait of a reader for a full ring that holds its writer, look by
// look: no end and an end word come before any counter; hostile counters
// are refused before any other decision, also when the deadline passed; a full ring whose writer does not wait is a wait on
// the words, never a look again, until the deadline; a deadline in the
// past ends the wait; the full ring with its writer that waits ends it.
@(test)
a_reader_waits_for_its_full_ring_on_the_words :: proc(t: ^testing.T) {
	CAPACITY :: 32
	COMPLETIONS :: 32
	Case :: struct {
		write, read:   u32,
		writer_waits:  bool,
		now, deadline: u64,
		step:          Full_Wait_Step,
	}
	cases := [?]Case {
		// A read past the write, and a count one past the capacity.
		{write = 5, read = 6, now = 0, deadline = 10, step = .Broken},
		{write = CAPACITY + 1, read = 0, writer_waits = true, now = 0, deadline = 10, step = .Broken},
		// A read one past the write, at the wrap of the counters, after the deadline.
		{write = 0, read = 1, now = 20, deadline = 10, step = .Broken},
		// Full, the writer does not wait: a wait on the words.
		{write = CAPACITY, read = 0, now = 0, deadline = 10, step = .Wait},
		{write = CAPACITY, read = 0, now = 9, deadline = 10, step = .Wait},
		// The deadline at the time and past it.
		{write = CAPACITY, read = 0, now = 10, deadline = 10, step = .Past_Deadline},
		{write = 3, read = 0, now = 0, deadline = 0, step = .Past_Deadline},
		// The writer waits on a ring that is not full: no hold.
		{write = CAPACITY - 1, read = 0, writer_waits = true, now = 0, deadline = 10, step = .Wait},
		// Full with the writer that waits, at the top of the counters too.
		{write = CAPACITY, read = 0, writer_waits = true, now = 0, deadline = 10, step = .Held},
		{write = CAPACITY - 1, read = max(u32), writer_waits = true, now = 20, deadline = 10, step = .Held},
		{write = 0, read = 0, now = 0, deadline = max(u64), step = .Wait},
	}
	// No end, and an end that ended, whatever the counters say: hostile,
	// full with the writer that waits, past the deadline.
	for item in cases {
		no_end, _ := full_wait_step_of(false, .None, item.write, item.read, CAPACITY, 0, 0, COMPLETIONS, item.writer_waits, item.now, item.deadline)
		testing.expectf(t, no_end == .No_End, "%v with no end gave %v", item, no_end)
		for word in End_Word {
			if word == .None {
				continue
			}
			ended, _ := full_wait_step_of(true, word, item.write, item.read, CAPACITY, 0, 0, COMPLETIONS, item.writer_waits, item.now, item.deadline)
			testing.expectf(t, ended == .Ended, "%v with the end word %v gave %v", item, word, ended)
		}
	}
	for item in cases {
		step, refusal := full_wait_step_of(true, .None, item.write, item.read, CAPACITY, 0, 0, COMPLETIONS, item.writer_waits, item.now, item.deadline)
		testing.expectf(t, step == item.step, "%v gave %v", item, step)
		if step == .Broken {
			testing.expectf(t, refusal.kind != 0, "%v: a broken ring with no error record", item)
		} else {
			testing.expect_value(t, refusal, errors.Error_Record{})
		}
	}
	// A completion queue that the writer never empties is broken too.
	step, _ := full_wait_step_of(true, .None, CAPACITY, 0, CAPACITY, COMPLETIONS, 0, COMPLETIONS, true, 0, 10)
	testing.expect_value(t, step, Full_Wait_Step.Broken)
}
