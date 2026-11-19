package root

// The words of the one wait of the loop of this service (root_loop_pass)
// (src/md/features/module_outputs.md, "The budget"). A wait holds
// op.WORD_WAIT_CAPACITY words. A list that does not fit ends each wait at
// once: the loop then turns with no wait, and the queues past the
// capacity are never waited on. So this service counts the queues that
// its loop waits on, and refuses a new one past the bound where the queue
// is made: a start whose process would bring a root ring, a control ring
// of the network or a wiring ring, and a wiring ring for an asker.

import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/root_ring"
import "modus:support/principals"
import "modus:support/system"

// The words that the loop adds whatever runs: the event word, the change
// count of the date page, the control ring of the compositor, the ring of
// the entropy service, the call of a load from the disk, and the call of
// the persisted table of each principal.
ROOT_WAIT_FIXED_WORDS :: 1 + 1 + 2 + 2 + 2 + 2 * principals.PRINCIPAL_CAPACITY

// Each queue takes two words: its counter, and the word that says that
// this service waits.
ROOT_WAIT_WORDS_OF_A_QUEUE :: 2

// The root rings, the control rings of the network and the wiring rings
// that the loop waits on, together. STARTED_CAPACITY processes could hold
// two of them each, more than the wait holds, so honest use reaches it.
ROOT_WAITED_QUEUES_MOST :: (op.WORD_WAIT_CAPACITY - ROOT_WAIT_FIXED_WORDS) / ROOT_WAIT_WORDS_OF_A_QUEUE
#assert(ROOT_WAIT_FIXED_WORDS + ROOT_WAITED_QUEUES_MOST * ROOT_WAIT_WORDS_OF_A_QUEUE <= op.WORD_WAIT_CAPACITY)
#assert(ROOT_WAITED_QUEUES_MOST < 2 * STARTED_CAPACITY)

// The wait of a pass did not fit once: the line is written once.
root_wait_full_told: bool

// root_waited_queues gives the queues that the loop waits on now, with
// those of a place whose start is not done.
root_waited_queues :: proc "contextless" () -> (count: int) {
	for &item in started {
		if item.requests.head != nil {
			count += 1
		}
		if item.network.head != nil {
			count += 1
		}
		if item.wiring.head != nil || item.wiring_memory != 0 {
			count += 1
		}
	}
	return count
}

// start_waited_queues gives the queues that the start of a module brings
// to the loop: its root ring, the control ring of a network device, and
// its wiring ring when its module declares a record stream.
start_waited_queues :: proc "contextless" (grants: bit_set[Grant], file: []u8) -> (count: int) {
	if root_ring.root_ring_given(grants) {
		count += 1
	}
	if .Network_Device in grants {
		count += 1
	}
	if system.module_declares_record_streams(file) {
		count += 1
	}
	return count
}

// waited_queues_refusal gives the error record of a command whose queues
// do not fit the wait, or false when they fit: Full of the unit Words, the
// words with the new queues as the value, and the capacity as the limit.
waited_queues_refusal :: proc "contextless" (command: root_ring.Root_Command, added: int) -> (values: [7]u64, refused: bool) {
	queues := root_waited_queues() + added
	if added == 0 || queues <= ROOT_WAITED_QUEUES_MOST {
		return {}, false
	}
	words := ROOT_WAIT_FIXED_WORDS + queues * ROOT_WAIT_WORDS_OF_A_QUEUE
	return errors.ring_fail(u32(command), .Full, .Words, 0, i64(words), op.WORD_WAIT_CAPACITY), true
}

// root_wait_full_tell writes one line, once, when a wait of the loop did
// not fit. The bound above keeps each list in the wait: the line tells of
// a fault of this count.
root_wait_full_tell :: proc "contextless" (wait: ^system.Wait) {
	if wait.full && !root_wait_full_told {
		root_wait_full_told = true
		system.log(.Error, "root: the wait of the loop holds more words than ", u64(op.WORD_WAIT_CAPACITY), ": each wait ends at once, and the queues past it are not waited on")
	}
}
