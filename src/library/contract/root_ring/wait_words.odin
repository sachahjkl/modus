package root_ring

import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/start_grant"

// The words of the one wait of the loop of the root service
// (src/md/features/module_outputs.md, "The words of the wait of the root
// service"). A wait holds op.WORD_WAIT_CAPACITY words. A list that does
// not fit ends each wait at once: the loop then turns with no wait, and
// the queues past the capacity are never waited on. The root service
// counts its queues and refuses a new one past the bound where it is
// made; the count of what runs is its state, and the decision is here.

// The persisted tables whose calls the loop waits on: one for each
// principal. The root service checks it against principals.
// PRINCIPAL_CAPACITY.
ROOT_WAIT_PERSISTED_TABLES :: 2

// The words that the loop adds whatever runs: the event word, the change
// count of the date page, the control ring of the compositor, the ring of
// the entropy service, the call of a load from the disk, and the call of
// each persisted table.
ROOT_WAIT_FIXED_WORDS :: 1 + 1 + 2 + 2 + 2 + 2 * ROOT_WAIT_PERSISTED_TABLES

// Each queue takes two words: its counter, and the word that says that
// the root service waits.
ROOT_WAIT_WORDS_OF_A_QUEUE :: 2

// The root rings, the control rings of the network and the wiring rings
// that the loop waits on, together.
ROOT_WAITED_QUEUES_MOST :: (op.WORD_WAIT_CAPACITY - ROOT_WAIT_FIXED_WORDS) / ROOT_WAIT_WORDS_OF_A_QUEUE
#assert(ROOT_WAIT_FIXED_WORDS + ROOT_WAITED_QUEUES_MOST * ROOT_WAIT_WORDS_OF_A_QUEUE <= op.WORD_WAIT_CAPACITY)

// start_waited_queues gives the queues that the start of a module brings
// to the loop: its root ring, the control ring of a network device, and
// its wiring ring when its module declares a record stream.
start_waited_queues :: proc "contextless" (grants: bit_set[start_grant.Grant], declares_record_streams: bool) -> (count: int) {
	if root_ring_given(grants) {
		count += 1
	}
	if .Network_Device in grants {
		count += 1
	}
	if declares_record_streams {
		count += 1
	}
	return count
}

// waited_queues_refusal gives the error record of a command whose added
// queues do not fit the wait beside the queues that run, or false when
// they fit or add none: Full of the unit Words, the words with the new
// queues as the value, and the capacity as the limit.
waited_queues_refusal :: proc "contextless" (command: Root_Command, running, added: int) -> (values: [7]u64, refused: bool) {
	if added <= 0 || running + added <= ROOT_WAITED_QUEUES_MOST {
		return {}, false
	}
	words := ROOT_WAIT_FIXED_WORDS + (running + added) * ROOT_WAIT_WORDS_OF_A_QUEUE
	return errors.ring_fail(u32(command), .Full, .Words, 0, i64(words), op.WORD_WAIT_CAPACITY), true
}
