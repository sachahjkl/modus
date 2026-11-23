#+build !freestanding
package recipes_core

import "core:testing"
import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"

@(private = "file")
job_of :: proc(principal: u64, tag: u8) -> Guest_Queue_Job {
	return {principal = principal, recipe_hash = blake3.hash([]u8{tag}), mode = .Build_Only}
}

// The handoff of the builds: the first build runs at once and a call
// during its run gets an answer; a principal past its share and a full
// queue are refused with Builder_Busy and change nothing; at the end of a
// run, the next build is of another principal when one waits; a ring build
// takes no share; a cancel removes a waiting build, asks a running build
// to end, and refuses the build of another principal.
@(test)
guest_queue_handoff :: proc(t: ^testing.T) {
	queue := new(Guest_Queue)
	defer free(queue)
	testing.expect(t, guest_queue_start(queue) == nil, "an empty queue starts nothing")
	testing.expect_value(t, guest_queue_push(queue, job_of(1, 'a')), pr.Recipe_Refusal.None)
	running := guest_queue_start(queue)
	testing.expect(t, running != nil && running.recipe_hash == blake3.hash([]u8{'a'}))
	testing.expect(t, guest_queue_start(queue) == nil, "one build runs at a time")

	// A call during the run: the queue answers it.
	testing.expect_value(t, guest_queue_push(queue, job_of(1, 'b')), pr.Recipe_Refusal.None)
	testing.expect_value(t, guest_queue_push(queue, job_of(1, 'c')), pr.Recipe_Refusal.Builder_Busy)
	waiting, runs := guest_queue_count(queue)
	testing.expect(t, waiting == 1 && runs == 1, "a refused push changes nothing")
	testing.expect_value(t, guest_queue_push(queue, job_of(2, 'd')), pr.Recipe_Refusal.None)

	// The end of the run: principal 2 runs next, though principal 1 came first.
	guest_queue_end(queue)
	next := guest_queue_start(queue)
	testing.expect(t, next != nil && next.principal == 2, "the next build is of another principal")
	guest_queue_end(queue)
	next = guest_queue_start(queue)
	testing.expect(t, next != nil && next.recipe_hash == blake3.hash([]u8{'b'}), "then the waiting build of principal 1")

	// The queue fills: ring builds take no share of a principal.
	for index in 0 ..< GUEST_QUEUE_MOST - 1 {
		testing.expect_value(t, guest_queue_push(queue, job_of(GUEST_QUEUE_RING_PRINCIPAL, u8(100 + index))), pr.Recipe_Refusal.None)
	}
	testing.expect_value(t, guest_queue_push(queue, job_of(3, 'z')), pr.Recipe_Refusal.Builder_Busy)
	waiting, runs = guest_queue_count(queue)
	testing.expect(t, waiting == GUEST_QUEUE_MOST - 1 && runs == 1)

	// Cancel: the build of another principal answers as no build, an absent
	// build too, and the principal of the ring cancels nothing: its build
	// stays. Then the running build of the caller, then a waiting one.
	testing.expect_value(t, guest_queue_cancel(queue, 3, blake3.hash([]u8{'b'})), Guest_Cancel.Absent)
	testing.expect_value(t, guest_queue_cancel(queue, 1, blake3.hash([]u8{'q'})), Guest_Cancel.Absent)
	testing.expect_value(t, guest_queue_cancel(queue, GUEST_QUEUE_RING_PRINCIPAL, blake3.hash([]u8{100})), Guest_Cancel.Absent)
	waiting, _ = guest_queue_count(queue)
	testing.expect_value(t, waiting, GUEST_QUEUE_MOST - 1)
	testing.expect_value(t, guest_queue_cancel(queue, 1, blake3.hash([]u8{'b'})), Guest_Cancel.Requested)
	testing.expect(t, guest_queue_running(queue).cancel_requested, "the running build is asked to end")
	guest_queue_end(queue)
	testing.expect(t, guest_queue_running(queue) == nil)
	testing.expect_value(t, guest_queue_push(queue, job_of(1, 'w')), pr.Recipe_Refusal.None)
	testing.expect_value(t, guest_queue_cancel(queue, 1, blake3.hash([]u8{'w'})), Guest_Cancel.Removed)
	waiting, _ = guest_queue_count(queue)
	testing.expect_value(t, waiting, GUEST_QUEUE_MOST - 1)
}
