package root

// The words of the one wait of the loop of this service (root_loop_pass)
// (src/md/features/module_outputs.md, "The words of the wait of the root
// service"). The wait set has the words of each queue of each place
// (root_ring.root_wait_words), so no start is refused for the wait: the
// set is made with the places, at the start of this service
// (root_tables_start).

import "modus:contract/root_ring"
import "modus:principals"
import "modus:system"

#assert(root_ring.ROOT_WAIT_PERSISTED_TABLES == principals.PRINCIPAL_CAPACITY)

// The wait of a pass did not fit once: the line is written once.
root_wait_full_told: bool

// root_wait_full_tell writes one line, once, when a wait of the loop did
// not fit: the kernel refused the wait room of the set, which holds each
// queue of each place.
root_wait_full_tell :: proc "contextless" (wait: ^system.Wait) {
	if wait.refused && !root_wait_full_told {
		root_wait_full_told = true
		system.log_fact(.Error, Root_Wait_Full{word_capacity = u64(root_wait_set.room)})
	}
}
