package root

// The words of the one wait of the loop of this service (root_loop_pass)
// (src/md/features/module_outputs.md, "The words of the wait of the root
// service"). The bound and the decision are in the contract
// (root_ring.ROOT_WAITED_QUEUES_MOST, root_ring.waited_queues_refusal);
// this file counts the queues that run, and refuses a new one past the
// bound where the queue is made: a start whose process would bring a root
// ring, a control ring of the network or a wiring ring, the start of a
// start policy from a disk, and a wiring ring for an asker.

import op "modus:contract/operation"
import "modus:contract/root_ring"
import "modus:support/principals"
import "modus:support/system"

#assert(root_ring.ROOT_WAIT_PERSISTED_TABLES == principals.PRINCIPAL_CAPACITY)
// STARTED_CAPACITY processes could hold two queues each, more than the wait
// holds, so honest use reaches the bound.
#assert(root_ring.ROOT_WAITED_QUEUES_MOST < 2 * STARTED_CAPACITY)

// The wait of a pass did not fit once: the line is written once.
root_wait_full_told: bool

// root_waited_queues gives the queues that the loop waits on now, with
// those of a place whose start is not done, plus the delegated wiring
// service ring when running. Per-process wiring rings are waited on by
// the delegated wiring service, not the root core.
root_waited_queues :: proc "contextless" () -> (count: int) {
	for &item in started {
		if item.requests.head != nil {
			count += 1
		}
		if item.network.head != nil {
			count += 1
		}
	}
	if wiring_ring.head != nil {
		count += 1
	}
	return count
}

// start_waited_queues gives the queues that the start of a module of the
// image brings to the root core loop.
start_waited_queues :: proc "contextless" (grants: bit_set[Grant], file: []u8) -> int {
	_ = file
	return root_ring.start_waited_queues(grants, false)
}

// waited_queues_refusal gives the error record of a command whose added
// queues do not fit the wait beside the queues that run now.
waited_queues_refusal :: proc "contextless" (command: root_ring.Root_Command, added: int) -> (values: [7]u64, refused: bool) {
	return root_ring.waited_queues_refusal(command, root_waited_queues(), added)
}

// root_wait_full_tell writes one line, once, when a wait of the loop did
// not fit. The bound keeps each list in the wait: the line tells of a
// fault of this count.
root_wait_full_tell :: proc "contextless" (wait: ^system.Wait) {
	if wait.full && !root_wait_full_told {
		root_wait_full_told = true
		system.log(.Error, "root: the wait of the loop holds more words than ", u64(op.WORD_WAIT_CAPACITY), ": each wait ends at once, and the queues past it are not waited on")
	}
}
