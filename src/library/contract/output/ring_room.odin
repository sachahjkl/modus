package output

import "modus:contract/errors"

// The decisions of a side of an output ring from the counters that it
// loaded once (src/md/features/module_outputs.md, "Fan-out and flow
// control"). The other side writes its counter at any time: a side loads
// it once, decides from that value, and waits on that same value, so a
// change between the decision and the wait ends the wait at once. Each
// decision is pure, so a host test gives it each count that a hostile side
// can write.

// What one ring does with the next write.
Ring_Room :: enum u8 {
	Room    = 0, // The ring takes the compartments of the write.
	Holds   = 1, // The ring is full and holds the writer: the pace Writer_Chooses or Always_Holds_Writer.
	Refuses = 2, // The ring is full and refuses this record for its reader alone: the pace Never_Holds_Writer.
	Broken  = 3, // The reader wrote a count past the write of the writer: no honest reader does. The writer closes the end.
}

// ring_room_of gives what a ring does with a write of needed compartments,
// from the counter write of the writer and the counter read that it loaded
// once, for a ring of capacity compartments.
ring_room_of :: proc "contextless" (write, read, capacity, needed: u32, pace: Wiring_Pace) -> Ring_Room {
	// The subtraction wraps as the counters do: a read past the write gives
	// a count past the capacity.
	held := write - read
	if held > capacity {
		return .Broken
	}
	if capacity - held >= needed {
		return .Room
	}
	switch pace {
	case .Never_Holds_Writer:
		return .Refuses
	case .Writer_Chooses, .Always_Holds_Writer:
		return .Holds
	}
	return .Holds
}

// What one ring of a record output does in the decision of a write.
Ring_Part :: enum u8 {
	Skipped         = 0, // The record fails the condition of the ring: the ring takes nothing of it, and holds nothing.
	Takes           = 1, // The ring has room for the write.
	Holds_By_Choice = 2, // The ring is full, of the pace Writer_Chooses: it holds a writer that waits.
	Holds_Always    = 3, // The ring is full, of the pace Always_Holds_Writer: it holds the writer whatever its call says.
	Refuses         = 4, // The ring is full, of the pace Never_Holds_Writer: it refuses the record for its reader alone.
	Broken          = 5, // The reader wrote a count past the write of the writer: the writer closes the end.
}

// ring_part_of gives what one ring does with a write: skips says that the
// record fails the condition of the ring, room what ring_room_of decided
// from its counters (not read for a ring that skips), and pace its pace. A
// ring that skips the record never holds the writer, full as it may be.
ring_part_of :: proc "contextless" (skips: bool, room: Ring_Room, pace: Wiring_Pace) -> Ring_Part {
	if skips {
		return .Skipped
	}
	switch room {
	case .Room:
		return .Takes
	case .Refuses:
		return .Refuses
	case .Broken:
		return .Broken
	case .Holds:
		return pace == .Always_Holds_Writer ? .Holds_Always : .Holds_By_Choice
	}
	return .Broken
}

// counts_after_write gives the counts of a record output after a write
// that passed its decision: written when a ring took the record, else
// discarded, as each ring left it out by its condition.
counts_after_write :: proc "contextless" (counts: Writer_Counts, taken: bool) -> Writer_Counts {
	after := counts
	if taken {
		after.written += 1
	} else {
		after.discarded += 1
	}
	return after
}

// What a write does after it looked at each ring.
Write_Step :: enum u8 {
	Write = 0, // No ring holds the writer: it writes now.
	Wait  = 1, // A ring holds the writer: it waits for room, until its deadline.
	Full  = 2, // The writer does not wait, and a ring of the pace Writer_Chooses is full: Full, nothing written.
}

// write_step_of gives the step of a write: held_by_choice says that a full
// ring of the pace Writer_Chooses holds the writer, held_always that a
// full ring of the pace Always_Holds_Writer does. With no wait, only the
// rings of the pace Always_Holds_Writer hold the writer.
write_step_of :: proc "contextless" (held_by_choice, held_always, wait: bool) -> Write_Step {
	if !held_by_choice && !held_always {
		return .Write
	}
	if !wait && held_by_choice {
		return .Full
	}
	return .Wait
}

// Why a reader refuses a ring before it reads it.
Reader_Ring_Fault :: enum u8 {
	None                = 0, // The ring can be read.
	Count_Past_Capacity = 1, // The writer wrote a count of compartments past the capacity: the reader would read stale compartments, and wait on a word that is never equal.
	Completions_Full    = 2, // The completion queue is full: the writer reads none of its completions, and the reader could never answer.
}

// reader_ring_fault_of decides from the counters that the reader loaded
// once: the write of the writer and its own read of the compartments, and
// its own write and the read of the writer of the completions. A writer
// that never reads its completions fills them only with refusals and the
// end, each of which closes the end: an honest pair never fills them.
reader_ring_fault_of :: proc "contextless" (write, read, capacity, completions_write, completions_read, completions_capacity: u32) -> (fault: Reader_Ring_Fault, refusal: errors.Error_Record) {
	if write - read > capacity {
		return .Count_Past_Capacity, errors.error_make(.Bad_Value, .Records, 0, i64(write - read), i64(capacity))
	}
	if completions_write - completions_read >= completions_capacity {
		return .Completions_Full, errors.error_make(.Full, .Records, 0, i64(completions_write - completions_read), i64(completions_capacity))
	}
	return .None, {}
}
