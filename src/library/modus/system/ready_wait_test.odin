#+build !freestanding
package system

import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/isolated"
import op "modus:contract/operation"
import "modus:contract/ring"

// A call ring in the memory of the test: the serving side and the caller
// open the same pages, as two processes map one memory object.
@(private = "file")
Test_Ring :: struct {
	memory: []u8,
	server: ring.Ring,
	caller: ring.Ring,
}

@(private = "file")
test_ring_make :: proc(t: ^testing.T) -> (made: Test_Ring) {
	made.memory = make([]u8, ring.pages(ring.CAPACITY) * ring.PAGE_SIZE)
	server_ok, caller_ok: bool
	made.server, server_ok = ring.open(raw_data(made.memory), ring.PAGE_COUNT)
	made.caller, caller_ok = ring.open(raw_data(made.memory), ring.PAGE_COUNT)
	testing.expect(t, server_ok && caller_ok)
	return made
}

// The serving process stops before it sends the ready completion: the wait
// ends at once with Refused, long before the deadline, and with the state
// None (the handle names no process) too.
@(test)
connection_ready_step_refuses_a_stop :: proc(t: ^testing.T) {
	made := test_ring_make(t)
	defer delete(made.memory)
	deadline := answer_deadline(1000)
	for state in ([]op.Process_State{.Stopped, .None}) {
		reading, done := connection_ready_step(&made.caller, 1000, deadline, state)
		testing.expect(t, done)
		testing.expect_value(t, reading, isolated.Ready_Reading.Refused)
	}
}

// A process that runs and never answers ends at the deadline, and at no
// time before it: one millisecond before it still waits.
@(test)
connection_ready_step_ends_a_hang_at_the_deadline :: proc(t: ^testing.T) {
	made := test_ring_make(t)
	defer delete(made.memory)
	deadline := answer_deadline(0)
	_, waits := connection_ready_step(&made.caller, deadline - 1, deadline, .Waiting)
	testing.expect(t, !waits)
	reading, done := connection_ready_step(&made.caller, deadline, deadline, .Waiting)
	testing.expect(t, done)
	testing.expect_value(t, reading, isolated.Ready_Reading.Refused)
}

// A first completion that is not the ready completion is refused, even
// while the process runs: the answer of a call before any call.
@(test)
connection_ready_step_refuses_a_wrong_first_completion :: proc(t: ^testing.T) {
	made := test_ring_make(t)
	defer delete(made.memory)
	testing.expect(t, ring.push(&made.server.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = 1}))
	reading, done := connection_ready_step(&made.caller, 0, answer_deadline(0), .Ready)
	testing.expect(t, done)
	testing.expect_value(t, reading, isolated.Ready_Reading.Refused)
}

// A call host that sends Load_Failed and stops: the completion decides,
// not the stop.
@(test)
connection_ready_step_reads_the_completion_before_the_stop :: proc(t: ^testing.T) {
	made := test_ring_make(t)
	defer delete(made.memory)
	testing.expect(t, ring.push(&made.server.completions, isolated.load_failed_record(.Bind)))
	reading, done := connection_ready_step(&made.caller, 0, answer_deadline(0), .Stopped)
	testing.expect(t, done)
	testing.expect_value(t, reading, isolated.Ready_Reading.Load_Failed)
}

// A slow start: the service maps its ring after many polls, and after more
// time than any bound of a start (the 5 s of the start of a call host),
// while it runs. The wait still succeeds: only a stop or the hang bound
// ends it.
@(test)
connection_ready_step_takes_a_late_ready_completion :: proc(t: ^testing.T) {
	made := test_ring_make(t)
	defer delete(made.memory)
	POLLS :: 10_000
	start := u64(1000)
	deadline := answer_deadline(start)
	late := deadline - 1 // The last millisecond before the hang bound.
	for poll in 0 ..< POLLS {
		now := start + u64(poll) * (late - start) / POLLS
		state := poll % 2 == 0 ? op.Process_State.Ready : op.Process_State.Waiting
		_, done := connection_ready_step(&made.caller, now, deadline, state)
		testing.expect(t, !done, "the wait ended while the process ran, before the deadline")
		if done {
			return
		}
	}
	testing.expect(t, ring.push(&made.server.completions, isolated.ready_record()))
	reading, done := connection_ready_step(&made.caller, late, deadline, .Waiting)
	testing.expect(t, done)
	testing.expect_value(t, reading, isolated.Ready_Reading.Ready)
	testing.expect(t, late - start > 5000, "the ready completion came after more than 5 s")
}
