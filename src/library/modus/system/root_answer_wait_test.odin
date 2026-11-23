#+build !freestanding
package system

import "core:testing"
import "modus:contract/isolated"
import "modus:contract/ring"

@(private = "file")
Test_Requests :: struct {
	memory: []u8,
	root:   ring.Ring,
	caller: ring.Ring,
}

@(private = "file")
test_requests_make :: proc(t: ^testing.T) -> (made: Test_Requests) {
	made.memory = make([]u8, ring.pages(ring.CAPACITY) * ring.PAGE_SIZE)
	root_ok, caller_ok: bool
	made.root, root_ok = ring.open(raw_data(made.memory), ring.PAGE_COUNT)
	made.caller, caller_ok = ring.open(raw_data(made.memory), ring.PAGE_COUNT)
	testing.expect(t, root_ok && caller_ok)
	return made
}

// The root service answers a Connect after many polls and after more time
// than any bound of a start (the 5 s that service_connection had), while
// the answers of requests that the caller gave up come first. The wait
// skips those answers and takes its own: only the hang bound ends it.
@(test)
root_answer_step_takes_a_late_answer :: proc(t: ^testing.T) {
	made := test_requests_make(t)
	defer delete(made.memory)
	TAG :: 7
	POLLS :: 10_000
	start := u64(1000)
	deadline := answer_deadline(start)
	late := deadline - 1
	for poll in 0 ..< POLLS {
		// An answer of another request, with each tag but the one waited for.
		if poll % 1000 == 0 {
			testing.expect(t, ring.push(&made.root.completions, ring.Record{kind = 0, tag = u32(poll / 1000) % TAG}))
		}
		now := start + u64(poll) * (late - start) / POLLS
		_, came, done := root_answer_step(&made.caller, TAG, now, deadline)
		testing.expect(t, !done && !came, "the wait ended before the answer and before the deadline")
		if done {
			return
		}
	}
	testing.expect(t, ring.push(&made.root.completions, ring.Record{kind = 0, tag = TAG, values = {0 = 41}}))
	record, came, done := root_answer_step(&made.caller, TAG, late, deadline)
	testing.expect(t, done && came)
	testing.expect_value(t, record.values[0], u64(41))
	testing.expect(t, late - start > 5000, "the answer came after more than 5 s")
}

// The root service never answers: the wait ends at the deadline, and at no
// time before it; an answer of another tag does not end it.
@(test)
root_answer_step_ends_a_hang_at_the_deadline :: proc(t: ^testing.T) {
	made := test_requests_make(t)
	defer delete(made.memory)
	deadline := answer_deadline(0)
	testing.expect(t, ring.push(&made.root.completions, ring.Record{kind = 0, tag = 2}))
	_, came, done := root_answer_step(&made.caller, 1, deadline - 1, deadline)
	testing.expect(t, !done && !came)
	_, came, done = root_answer_step(&made.caller, 1, deadline, deadline)
	testing.expect(t, done && !came)
}

// The tag 0 and the largest tag are tags like the others: a record with
// the tag 0 does not answer a request with the largest tag.
@(test)
root_answer_step_matches_the_tag_only :: proc(t: ^testing.T) {
	made := test_requests_make(t)
	defer delete(made.memory)
	testing.expect(t, ring.push(&made.root.completions, ring.Record{kind = 0, tag = 0}))
	_, came, done := root_answer_step(&made.caller, max(u32), 0, answer_deadline(0))
	testing.expect(t, !came && !done)
	testing.expect(t, ring.push(&made.root.completions, ring.Record{kind = 3, tag = max(u32)}))
	record, answered, ended := root_answer_step(&made.caller, max(u32), 0, answer_deadline(0))
	testing.expect(t, answered && ended)
	testing.expect_value(t, record.kind, u32(3))
}

// The call host that answers late: call_host_start waits for its first
// completion with connection_ready_wait. A Load_Failed after many polls
// and after more than 5 s is read, not called a hang.
@(test)
call_host_ready_step_takes_a_late_load_failure :: proc(t: ^testing.T) {
	made := test_requests_make(t)
	defer delete(made.memory)
	start := u64(1000)
	deadline := answer_deadline(start)
	late := deadline - 1
	for poll in 0 ..< 1000 {
		_, done := connection_ready_step(&made.caller, start + u64(poll) * (late - start) / 1000, deadline, .Ready)
		testing.expect(t, !done)
		if done {
			return
		}
	}
	testing.expect(t, ring.push(&made.root.completions, ring.Record{kind = u32(isolated.Status.Load_Failed), tag = isolated.READY_TAG}))
	reading, done := connection_ready_step(&made.caller, late, deadline, .Ready)
	testing.expect(t, done)
	testing.expect_value(t, reading, isolated.Ready_Reading.Load_Failed)
}
