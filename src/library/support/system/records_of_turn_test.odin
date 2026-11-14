#+build !freestanding
package system

import "core:testing"
import "modus:contract/ring"

// A writer that writes one record after each record that the reader takes:
// the reader ends its turn after the records that the queue held at the
// start of the turn, and the records of the flood wait for the next turn.
@(test)
records_of_turn_ends_against_a_writer_that_floods :: proc(t: ^testing.T) {
	counters: ring.Counters
	records: [8]ring.Record
	queue := ring.Queue{counters = &counters, records = raw_data(records[:]), mask = 7}
	for index in 0 ..< 5 {
		testing.expect(t, ring.push(&queue, ring.Record{tag = u32(index)}))
	}
	taken := 0
	for _ in 0 ..< records_of_turn(&queue) {
		record, has := ring.pop(&queue)
		if !has {
			break
		}
		testing.expect_value(t, record.tag, u32(taken))
		taken += 1
		testing.expect(t, ring.push(&queue, ring.Record{tag = 100}))
	}
	testing.expect_value(t, taken, 5)
	testing.expect_value(t, ring.count(&queue), 5)
	// The next turn takes the records of the flood, and no more.
	taken = 0
	for _ in 0 ..< records_of_turn(&queue) {
		record, has := ring.pop(&queue)
		if !has {
			break
		}
		testing.expect_value(t, record.tag, 100)
		taken += 1
		ring.push(&queue, ring.Record{tag = 200})
	}
	testing.expect_value(t, taken, 5)
}

// A writer that writes a false count: a turn is at most the capacity of
// the queue. An empty queue gives a turn of no record.
@(test)
records_of_turn_is_at_most_the_capacity :: proc(t: ^testing.T) {
	counters: ring.Counters
	records: [8]ring.Record
	queue := ring.Queue{counters = &counters, records = raw_data(records[:]), mask = 7}
	testing.expect_value(t, records_of_turn(&queue), 0)
	counters.read = 40
	counters.write = 40 + 1_000_000
	testing.expect_value(t, records_of_turn(&queue), 8)
	// The count of the writer is behind the count of the reader: the
	// difference wraps to a large number.
	counters.write = 39
	testing.expect_value(t, records_of_turn(&queue), 8)
}
