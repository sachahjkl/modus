package system

// The wait for the answer of the root service to a request of its ring: a
// Connect, which can start the service first, and the Disconnect of a
// connection that the caller gives up. A caller holds no handle of the root
// service, and a stop of the root service is the end of the machine: the
// one bound is the hang bound of an answer (ANSWER_BOUND_MILLISECONDS),
// never a time of a start, which a loaded host makes many times longer
// (src/md/api/call_ring_ready.md, "The bound is the hang bound").

import "modus:contract/ring"

// root_answer_step reads the completions of the ring once. It gives the
// completion with the tag; it skips each other completion, the answer of a
// request that this caller gave up. done is true when the answer came, or
// at the deadline.
root_answer_step :: proc "contextless" (requests: ^ring.Ring, tag: u32, now, deadline: u64) -> (record: ring.Record, answered: bool, done: bool) {
	for completion in receive(&requests.completions) {
		if completion.tag == tag {
			return completion, true, true
		}
	}
	return {}, false, now >= deadline
}

// root_answer_wait waits for the completion with the tag on the ring to
// the root service, until the hang bound of an answer.
root_answer_wait :: proc "contextless" (requests: ^ring.Ring, tag: u32) -> (record: ring.Record, answered: bool) {
	deadline := answer_deadline(time())
	for {
		wait := wait_begin()
		if completion, came, done := root_answer_step(requests, tag, time(), deadline); done {
			return completion, came
		}
		wait_records(&wait, &requests.completions)
		wait_end(&wait, deadline)
	}
}
