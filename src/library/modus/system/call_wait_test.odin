#+build !freestanding
#+build !modus
package system

import "core:testing"
import op "modus:contract/operation"
import "modus:contract/ring"

@(private = "file")
Call_Test_Ring :: struct {
	memory: []u8,
	host:   ring.Ring,
	caller: ring.Ring,
}

@(private = "file")
call_test_ring_make :: proc(t: ^testing.T) -> (made: Call_Test_Ring) {
	made.memory = make([]u8, ring.pages(ring.CAPACITY) * ring.PAGE_SIZE)
	host_ok, caller_ok: bool
	made.host, host_ok = ring.open(raw_data(made.memory), ring.PAGE_COUNT)
	made.caller, caller_ok = ring.open(raw_data(made.memory), ring.PAGE_COUNT)
	testing.expect(t, host_ok && caller_ok)
	return made
}

// A call host that runs and never answers, as a compiler that loops on a
// source: the wait goes on at each poll while the process runs, even one
// millisecond before the deadline, and ends with Deadline_Passed at the
// deadline.
@(test)
call_answer_step_ends_a_call_that_never_answers :: proc(t: ^testing.T) {
	made := call_test_ring_make(t)
	defer delete(made.memory)
	start := u64(1000)
	deadline := answer_deadline(start)
	for poll in 0 ..< 10_000 {
		now := start + u64(poll) * (deadline - 1 - start) / 10_000
		state := poll % 2 == 0 ? op.Process_State.Ready : op.Process_State.Waiting
		_, waited := call_answer_step(&made.caller, 1, now, deadline, state)
		testing.expect_value(t, waited, Call_Wait.Waits)
		if waited != .Waits {
			return
		}
	}
	_, last := call_answer_step(&made.caller, 1, deadline - 1, deadline, .Ready)
	testing.expect_value(t, last, Call_Wait.Waits)
	_, ended := call_answer_step(&made.caller, 1, deadline, deadline, .Ready)
	testing.expect_value(t, ended, Call_Wait.Deadline_Passed)
}

// A call with no deadline never ends for the time alone, at the largest
// time either.
@(test)
call_answer_step_with_no_deadline_waits :: proc(t: ^testing.T) {
	made := call_test_ring_make(t)
	defer delete(made.memory)
	_, waited := call_answer_step(&made.caller, 1, WAIT_FOREVER - 1, WAIT_FOREVER, .Ready)
	testing.expect_value(t, waited, Call_Wait.Waits)
}

// The process stops with no answer, or the handle names none: Stopped at
// once, long before the deadline.
@(test)
call_answer_step_reads_a_stop :: proc(t: ^testing.T) {
	made := call_test_ring_make(t)
	defer delete(made.memory)
	for state in ([]op.Process_State{.Stopped, .None}) {
		_, waited := call_answer_step(&made.caller, 1, 0, answer_deadline(0), state)
		testing.expect_value(t, waited, Call_Wait.Stopped)
	}
}

// An answer with another tag, of a call that the caller gave up, does not
// answer this call; and a stop does not hide an answer that came before it.
@(test)
call_answer_step_takes_its_own_answer :: proc(t: ^testing.T) {
	made := call_test_ring_make(t)
	defer delete(made.memory)
	testing.expect(t, ring.push(&made.host.completions, ring.Record{kind = 0, tag = 6}))
	_, skipped := call_answer_step(&made.caller, 7, 0, answer_deadline(0), .Ready)
	testing.expect_value(t, skipped, Call_Wait.Waits)
	testing.expect(t, ring.push(&made.host.completions, ring.Record{kind = 0, tag = 7, values = {0 = 42}}))
	answer, waited := call_answer_step(&made.caller, 7, 0, answer_deadline(0), .Stopped)
	testing.expect_value(t, waited, Call_Wait.Answered)
	testing.expect_value(t, answer.values[0], u64(42))
}
