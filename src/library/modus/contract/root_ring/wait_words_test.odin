#+build !freestanding
package root_ring

import "core:testing"
import "modus:contract/errors"
import op "modus:contract/operation"

// One queue past the bound is refused with its whole record: the queues
// that run at the bound, and none that run with all of them added at once.
// The record is Full of the unit Words, the words of the wait with the new
// queues, the capacity, and the operation of the command.
@(test)
a_queue_past_the_wait_of_the_root_service_is_refused :: proc(t: ^testing.T) {
	testing.expect_value(t, ROOT_WAIT_FIXED_WORDS, 12)
	testing.expect_value(t, ROOT_WAITED_QUEUES_MOST, 122)
	Case :: struct {
		running, added: int,
	}
	for item in ([?]Case{{ROOT_WAITED_QUEUES_MOST, 1}, {ROOT_WAITED_QUEUES_MOST - 1, 2}, {0, ROOT_WAITED_QUEUES_MOST + 1}, {ROOT_WAITED_QUEUES_MOST, 3}}) {
		values, refused := waited_queues_refusal(.Start, item.running, item.added)
		testing.expectf(t, refused, "%d queues beside %d are taken", item.added, item.running)
		words := ROOT_WAIT_FIXED_WORDS + (item.running + item.added) * ROOT_WAIT_WORDS_OF_A_QUEUE
		testing.expect_value(t, errors.completion_record(values), errors.Error_Record{kind = i64(errors.Kind.Full), unit = i64(errors.Unit.Words), operation = i64(Root_Command.Start), value = i64(words), limit = op.WORD_WAIT_CAPACITY})
	}
	// 123 queues: the first count past the bound, with each command.
	values, refused := waited_queues_refusal(.Wire, ROOT_WAITED_QUEUES_MOST, 1)
	testing.expect(t, refused)
	testing.expect_value(t, errors.completion_record(values), errors.Error_Record{kind = i64(errors.Kind.Full), unit = i64(errors.Unit.Words), operation = i64(Root_Command.Wire), value = 258, limit = 256})
}

// No queue added is never refused, even past the bound; a start that
// brings no queue passes; the bound itself, 122, passes last.
@(test)
the_queues_up_to_the_wait_of_the_root_service_pass :: proc(t: ^testing.T) {
	for running in ([?]int{0, ROOT_WAITED_QUEUES_MOST, ROOT_WAITED_QUEUES_MOST + 5}) {
		values, refused := waited_queues_refusal(.Start, running, 0)
		testing.expectf(t, !refused && values == [7]u64{}, "no queue beside %d is refused", running)
	}
	values, refused := waited_queues_refusal(.Start, ROOT_WAITED_QUEUES_MOST - 1, 1)
	testing.expect(t, !refused && values == [7]u64{})
	_, refused = waited_queues_refusal(.Start, 0, ROOT_WAITED_QUEUES_MOST)
	testing.expect(t, !refused)
}

// The queues of a start: none for a start grant set with no ring and no stream, one
// for each of the root ring, the control ring of the network device and
// the wiring ring, and three together.
@(test)
a_start_brings_one_queue_for_each_ring_that_the_loop_waits_on :: proc(t: ^testing.T) {
	testing.expect_value(t, start_waited_queues({}, false), 0)
	testing.expect_value(t, start_waited_queues({.Root_Ring}, false), 1)
	testing.expect_value(t, start_waited_queues({.Network_Device}, false), 1)
	testing.expect_value(t, start_waited_queues({}, true), 1)
	testing.expect_value(t, start_waited_queues({.Root_Ring, .Network_Device}, true), 3)
}
