package root_ring

import op "modus:contract/operation"

// The words of the one wait of the loop of the root service
// (src/md/features/module_outputs.md, "The words of the wait of the root
// service"). The root service sizes its wait set at its start from its
// places, one for each process slot of the machine but its own, so that
// each queue that it can hold has its words: no start is refused for the
// wait, and no queue is waited on late. The kernel holds the words in a
// wait room that the budget of the root service pays.

// The persisted tables whose calls the loop waits on: one for each
// principal. The root service checks it against principals.
// PRINCIPAL_CAPACITY.
ROOT_WAIT_PERSISTED_TABLES :: 8

// The words that the loop adds whatever runs: the event word, the change
// count of the date page, the control ring of the compositor, the ring of
// the entropy service, the call of a load from the disk, and the call of
// each persisted table.
ROOT_WAIT_FIXED_WORDS :: 1 + 1 + 2 + 2 + 2 + 2 * ROOT_WAIT_PERSISTED_TABLES

// Each queue takes two words: its counter, and the word that says that
// the root service waits.
ROOT_WAIT_WORDS_OF_A_QUEUE :: 2

// The queues of one place: the root ring of its process and the control
// ring of its network device.
ROOT_WAIT_QUEUES_OF_A_PLACE :: 2

// The queues beside the places: the rings of the delegated wiring service,
// the devices service, and the storage service reclaim completions.
ROOT_WAIT_QUEUES_BESIDE_PLACES :: 3

// root_wait_words gives the words of the wait of the loop with each queue
// of `places` places: the size of the wait set of the root service.
//
// Example: 255 places (a machine of 1 GiB) give 12 + 2 x (510 + 3) = 1038
// words; 1023 places give 4110.
root_wait_words :: proc "contextless" (places: int) -> int {
	return ROOT_WAIT_FIXED_WORDS + ROOT_WAIT_WORDS_OF_A_QUEUE * (ROOT_WAIT_QUEUES_OF_A_PLACE * max(places, 0) + ROOT_WAIT_QUEUES_BESIDE_PLACES)
}

// The largest wait, with a place for each process slot but one, fits a
// wait of the kernel.
#assert(ROOT_WAIT_FIXED_WORDS + ROOT_WAIT_WORDS_OF_A_QUEUE * (ROOT_WAIT_QUEUES_OF_A_PLACE * (op.PROCESS_SLOTS_MOST - 1) + ROOT_WAIT_QUEUES_BESIDE_PLACES) <= op.WORD_WAIT_MOST)
