// The slow reader of the test of fan-out and the pace
// (src/md/features/module_outputs.md, "Fan-out and flow control"). The test
// module `requests_pace` starts it, then starts `server` with a wiring list
// whose rows wire `server.requests` to each record input of this process,
// each with a ring of PACE_RING_CAPACITY compartments:
//
// - `held`, of the pace Always_Holds_Writer: a full ring holds the server;
// - `gapped`, of the pace Never_Holds_Writer: a full ring refuses the
//   record for this reader alone, which then reads a gap record.
//
// It reads in three phases, each opened by a state of its rings and never
// by a time. The tool sends the requests in three parts: C, then C after
// the line "phase 1 read", then the rest after "phase 2 read". So no
// request is in flight while this reader drains a ring, and the counts are
// exact by construction:
//
// 1. It reads nothing until `held` is full and the server waits for room in
//    it. Both rings then hold the joined record of 0 and the records 0 to
//    capacity - 2. It reads `held` whole: the server goes on, and `gapped`,
//    still full, refuses each next record.
// 2. It reads nothing until `held` is full again and the server waits: the
//    records capacity - 1 to 2 capacity - 2 are in `held`, and `gapped`
//    refused each of them. It reads `gapped` whole, then `held` whole.
// 3. The server writes the next record: `gapped` takes first a gap record
//    of exactly capacity records from the serial capacity - 1, then the
//    record. Both rings hold the rest of the stream, which ends when the
//    asker stops the server. It reads each ring to its end word.
//
// **Start**: by `requests_pace` only. **What a reader sees**: no window;
// one line for each record input "requests_reader: ...: as it must", or a
// line "requests_reader: WRONG: ...". It stops itself with the outcome
// Done, or Failed after a WRONG line.
package requests_reader

import "modus:contract/output"
import "modus:contract/value_kinds"
import "modus:support/system"

// The access record of `server`, as its writer describes it: the type check
// of the root service compares the two descriptions at the wiring, so a
// change of one of them refuses the wiring.
Access_Record :: struct {
	status:      u64,
	answer_size: value_kinds.Size_In_Bytes,
	answer_time: value_kinds.Time_In_Microseconds,
	method:      [8]u8,
	target:      [56]u8,
	peer:        [32]u8,
}

// The requests of `server`, in a ring that holds the server when it is full.
held: system.Record_Input(Access_Record)

// The requests of `server`, in a ring that refuses the records that do not
// fit, for this reader alone.
gapped: system.Record_Input(Access_Record)

// The requests that the tool sends to the server in this test: the server
// answers each one, and writes one record of each. With rings of capacity
// C, the test needs at least 2 C requests for its two phases, and the rest
// of the stream must fit in each ring after them: at most 3 C - 2.
PACE_REQUESTS :: 80
PACE_RING_CAPACITY :: output.WIRING_CAPACITY_LEAST
#assert(PACE_REQUESTS >= 2 * PACE_RING_CAPACITY && PACE_REQUESTS <= 3 * PACE_RING_CAPACITY - 2)

// The waits of the server for room in held: one for each phase.
HOLDS_OF_THE_TEST :: 2

@(private = "file")
hang_deadline :: proc "contextless" () -> u64 {
	return system.time() + system.TEST_HANG_BOUND_MILLISECONDS
}

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log(.Error, "requests_reader: WRONG: ", text, " ", value)
	system.stop(.Failed)
}

// next reads the next compartment of a record input, and stops this
// process on a status that is not Ok, or a kind or a serial other than the
// one wanted.
@(private = "file")
next :: proc "contextless" (stream: ^system.Record_Input(Access_Record), name: string, kind: output.Compartment_Kind, serial: u32) -> (item: system.Input_Item) {
	record: Access_Record
	status: output.Stream_Status
	item, status = system.input_read(stream, &record, hang_deadline())
	if status != .Ok {
		system.log(.Error, "requests_reader: WRONG: ", name, ": the read of the serial ", u64(serial), " gave the status word ", u64(status))
		system.stop(.Failed)
	}
	if item.kind != kind || item.serial != serial {
		system.log(.Error, "requests_reader: WRONG: ", name, ": wanted the kind word ", u64(kind), " and the serial ", u64(serial), ", read the kind word ", u64(item.kind), " and the serial ", u64(item.serial))
		system.stop(.Failed)
	}
	if kind == .Record && record.status != 200 {
		wrong("a request did not end with the status 200; its status", record.status)
	}
	return item
}

// records_read reads the records first ..< end of a record input.
@(private = "file")
records_read :: proc "contextless" (stream: ^system.Record_Input(Access_Record), name: string, first, end: u32) {
	for serial in first ..< end {
		next(stream, name, .Record, serial)
	}
}

// writer_waits_on waits until the ring of held is full and the server waits
// for room in it: the ring holds capacity compartments.
@(private = "file")
writer_waits_on :: proc "contextless" (phase: u64) -> (capacity: u32) {
	ended, held_now, ring_capacity := system.input_full_and_writer_waits(&held, hang_deadline())
	if ended != .Held {
		system.log(.Error, "requests_reader: WRONG: the ring of held was not full with the server waiting on it, in the phase ", phase, "; the end word ", u64(ended))
		system.stop(.Failed)
	}
	if ring_capacity != PACE_RING_CAPACITY || held_now != ring_capacity {
		wrong("the ring of held does not have the capacity of its row; its capacity", u64(ring_capacity))
	}
	return ring_capacity
}

// end_read reads the end word of a record input whose writer stopped.
@(private = "file")
end_read :: proc "contextless" (stream: ^system.Record_Input(Access_Record), name: string) {
	record: Access_Record
	item, status := system.input_read(stream, &record, hang_deadline())
	if status != .Ended || item.end_word != .Writer_Stopped {
		system.log(.Error, "requests_reader: WRONG: ", name, ": after the last request, the status word ", u64(status), " and the end word ", output.end_word_names[item.end_word])
		system.stop(.Failed)
	}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	deadline := hang_deadline()
	for !system.input_has_writer(&held) || !system.input_has_writer(&gapped) {
		if system.time() >= deadline {
			wrong("held and gapped had no writer within the hang bound", 0)
		}
		system.wiring_wait(deadline)
	}
	// 1. The first fill: the joined record of 0 and the records 0 to C - 2.
	// The tool sends C requests, then waits for the line of this phase: no
	// request comes while this reader drains, so the server waits only for
	// the record C - 1, which the drain lets in.
	capacity := writer_waits_on(1)
	next(&held, "held", .Joined, 0)
	records_read(&held, "held", 0, capacity - 1)
	system.log(.Info, "requests_reader: phase 1 read")
	// 2. The second fill of held, which gapped refused whole: the records
	// C - 1 to 2 C - 2, and the server waits for the record 2 C - 1.
	writer_waits_on(2)
	next(&gapped, "gapped", .Joined, 0)
	records_read(&gapped, "gapped", 0, capacity - 1)
	records_read(&held, "held", capacity - 1, 2 * capacity - 1)
	system.log(.Info, "requests_reader: phase 2 read")
	// 3. The rest of the stream, and in gapped the gap record first.
	records_read(&held, "held", 2 * capacity - 1, PACE_REQUESTS)
	// The counts that the server published at the write of the last
	// record, before it: the records before it were taken by a ring each,
	// none refused, and held waited twice, once for each phase.
	counts, counted := system.input_writer_counts(&held)
	if !counted || counts.written != PACE_REQUESTS - 1 || counts.discarded != 0 || counts.refused != 0 || counts.held != HOLDS_OF_THE_TEST || counts.rings_past_gap != 0 {
		system.log(.Error, "requests_reader: WRONG: the counts of the server in the ring of held: written ", counts.written, ", discarded ", counts.discarded, ", refused ", counts.refused, ", held ", counts.held, ", past their gap ", counts.rings_past_gap, "; wanted ", u64(PACE_REQUESTS - 1), ", 0, 0, ", u64(HOLDS_OF_THE_TEST), " and 0")
		system.stop(.Failed)
	}
	end_read(&held, "held")
	gap := next(&gapped, "gapped", .Gap, capacity - 1)
	if gap.gap_count != capacity {
		wrong("the gap record of gapped does not count the whole ring; its count", u64(gap.gap_count))
	}
	records_read(&gapped, "gapped", 2 * capacity - 1, PACE_REQUESTS)
	end_read(&gapped, "gapped")
	system.log(.Info, "requests_reader: held, of the pace Always_Holds_Writer: the joined record of 0 and the ", u64(PACE_REQUESTS), " records in order, no gap, with a ring of ", u64(capacity), " that held the server twice: as it must")
	system.log(.Info, "requests_reader: gapped, of the pace Never_Holds_Writer: the joined record of 0, ", u64(PACE_REQUESTS - capacity), " records, and one gap record of exactly ", u64(capacity), " records from the serial ", u64(capacity - 1), ", which the records around it meet: as it must")
	system.stop(.Done)
}
