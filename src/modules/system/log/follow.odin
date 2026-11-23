package log

import "base:intrinsics"
import "modus:contract/isolated"
import op "modus:contract/operation"
import "modus:system"

// log.follow: the records of the whole log from the next one on, as a
// record output of this service, which the console reads as a Stream
// (src/md/features/log_facts.md, "The frequent tasks").
//
// **Who reads it.** A reader wires `log.follow` through its connection to
// this service, with the end Connected, which the root service gives only
// to a caller that acts for the principal (src/md/features/module_outputs.md,
// "The wiring and its rights"). So each reader of follow has the scope of
// the whole log, and one record output serves them all: the writer never
// knows which ring is which connection, and needs not.
//
// **The loss.** The log of the kernel stays lossy below it. When the
// kernel wrote over records before this service wrote them into follow,
// the service writes a gap record of their count in their place
// (system.output_gap), so the follower sees each loss where it is, and the
// number of the next row says the same.
//
// **The pace.** This service serves every caller, and never waits for a
// follower: each write goes with no wait and a deadline of now. A full ring
// of the pace Writer_Chooses refuses the write, and the service keeps its
// place and writes the same record at its next pass: a slow follower holds
// the rows of each follower, never the service. Past the capacity of the
// whole log, the kernel writes over what waits, and each follower reads a
// gap. A ring of the pace Never_Holds_Writer refuses the record for its
// reader alone, who reads a gap record of its own. The service passes at
// each record of the log, at each call, at each new end, and at each read
// of a follower whose full ring refused a row (system.wait_output_room in
// main.odin): a follower that drains its ring gets the row that waited, or
// its gap, with no new record of the log.

// The words of the main wait of this service, besides the rings of follow:
// the event word; the window, its completions with their flag and the two
// words of the event of its surface; the log; the wiring ring and its flag;
// the service ring and each of its connections, each with its flag.
MAIN_WAIT_WORDS_BESIDE_FOLLOW :: 1 + 4 + 1 + 2 + 2 * (1 + isolated.SERVICE_CONNECTION_CAPACITY)
// The full rings of follow that the main wait waits on: the rest of the
// list. A full ring past them gets its row at the next wake of this
// service for another cause, at the latest the next record of the log.
FOLLOW_RINGS_WAITED_MOST :: (op.WORD_WAIT_CAPACITY - MAIN_WAIT_WORDS_BESIDE_FOLLOW) / system.OUTPUT_ROOM_WAIT_WORDS
#assert(FOLLOW_RINGS_WAITED_MOST >= 1)
#assert(MAIN_WAIT_WORDS_BESIDE_FOLLOW + FOLLOW_RINGS_WAITED_MOST * system.OUTPUT_ROOM_WAIT_WORDS <= op.WORD_WAIT_CAPACITY)
// The places of the main wait, which waits on these rings: more than a
// wait on the stack holds.
log_wait_set: system.Wait_Set

// One row of log.follow: one record of the whole log, as records() gives
// it, with no byte that no field names. A fact has no text, as in
// records(): fact_records() gives its values.
Follow_Row :: struct {
	number:     i64, // The number of the log record, from 0.
	time:       i64, // Microseconds since the start of the machine.
	slot:       i64, // The slot of the process. 0: the kernel.
	process:    [32]u8, // The name of the process, or "kernel".
	level:      op.Log_Level,
	form:       op.Log_Record_Form,
	continues:  u8, // 1: the text, or the fact of several records, goes on in the next row.
	runs:       u8, // The count of the value runs of the text: value_runs() gives them.
	text_count: u32, // The bytes of the text.
	text:       [168]u8, // op.LOG_TEXT_CAPACITY.
}
#assert(size_of(Follow_Row) == 232)
#assert(op.LOG_TEXT_CAPACITY == 168)

// The records of the whole log, from the next one on, for a caller that
// acts for the principal: `log.follow |> where(level = Warning)`.
follow: system.Record_Output(Follow_Row)

// The number of the next record of the whole log that follow writes.
follow_next: u64

// follow_row_of gives the row of one record, through the borders of its
// form and its level (record_borders): a record of a byte that names no
// member gives no row, and counts as lost, as in records().
follow_row_of :: proc "contextless" (number: u64, record: ^op.Log_Record) -> (row: Follow_Row, ok: bool) {
	form, level := record_borders(record) or_return
	row = {
		number    = i64(number),
		time      = i64(record.time),
		slot      = i64(record.process),
		level     = level,
		form      = form,
		continues = record.more != 0 ? 1 : 0,
	}
	copy(row.process[:len(row.process) - 1], system.name_of(record.name[:]))
	switch form {
	case .Text:
		count := min(int(record.text_count), len(row.text))
		copy(row.text[:], record.text[:count])
		row.text_count = u32(count)
		row.runs = record.run_count
	case .Fact:
	}
	return row, true
}

// follow_lost writes a gap of count records of the log in each ring of
// follow, in parts that a gap record holds.
@(private = "file")
follow_lost :: proc "contextless" (count: u64) {
	rest := count
	for rest > 0 {
		part := min(rest, u64(max(u32)))
		system.output_gap(&follow, u32(part))
		rest -= part
	}
}

// follow_pump writes the records of the log that follow did not write yet,
// until the first one that a ring of a follower refuses. With no follower,
// the next one joins from the next record.
follow_pump :: proc "contextless" () {
	written := intrinsics.atomic_load(&reader_head.written)
	if !system.output_read_by(&follow) {
		follow_next = written
		return
	}
	// The records lost since the last row, said as one gap right before
	// the next row: a torn copy right after a loss adds to the same gap.
	next, lost := op.log_first_kept(follow_next, written)
	follow_next = next
	for follow_next < written {
		record, whole := record_copy(follow_next)
		if !whole {
			// The kernel wrote over this record during the copy, and maybe
			// over the records after it: the head again gives each one.
			written = intrinsics.atomic_load(&reader_head.written)
			kept, more := op.log_first_kept(follow_next, written)
			if more == 0 {
				kept, more = follow_next + 1, 1
			}
			lost += more
			follow_next = kept
			continue
		}
		row, row_ok := follow_row_of(follow_next, &record)
		if !row_ok {
			// A byte that names no member: a record that no follower
			// reads, in the same gap.
			lost += 1
			follow_next += 1
			continue
		}
		if lost > 0 {
			follow_lost(lost)
			lost = 0
		}
		switch system.output_write(&follow, row, wait = false, deadline = system.time()) {
		case .Ok, .No_Reader:
			follow_next += 1
		case .Full:
			// The same record at the next pass: its place is kept.
			return
		case .Ended:
			// follow never ends: a call that gives Ended names no ring.
			return
		case .No_Writer, .Bad_Record, .No_Record:
			// No write gives them; the record is passed, never written
			// twice.
			follow_next += 1
		}
	}
	if lost > 0 {
		follow_lost(lost)
	}
}
