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
