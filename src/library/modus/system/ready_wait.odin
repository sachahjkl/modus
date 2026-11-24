package system

// The wait for the ready completion of a call ring
// (src/md/api/call_ring_ready.md): the first completion, which the call
// host or the service sends once it maps the ring with the consent to
// receive handles. Before it, the kernel has no receiver for a handle that
// a call lends, so a caller sends its first call only after it.
//
// It is a wait for an answer from another process (answer_wait.odin): the
// stop of the serving process ends it, and the deadline only ends a hang.
// A service that starts on demand opens its store before it serves; on a
// loaded host that takes many times longer, and a bound tuned to a fast
// host would end a connection that is correct.

import "base:intrinsics"
import "modus:contract/isolated"
import op "modus:contract/operation"
import "modus:contract/ring"

// connection_ready_step reads the ring once, after the caller read the
// state of the serving process. A completion in the ring decides first: a
// call host that sends Load_Failed stops after it, and its record is the
// answer. done is false while the process runs and the deadline did not
// pass: the caller waits on the completions and steps again.
connection_ready_step :: proc "contextless" (calls: ^ring.Ring, now, deadline: u64, state: op.Process_State) -> (reading: isolated.Ready_Reading, done: bool) {
	if completion, has := receive(&calls.completions); has {
		return isolated.ready_of_first_completion(completion), true
	}
	switch answer_wait_of(now, deadline, state) {
	case .Waits:
		return .Refused, false
	case .Stopped, .Silent:
		return .Refused, true
	}
	return .Refused, true
}

// connection_ready_wait waits for the ready completion of a call ring. It
// ends with Refused when the serving process stops, or at the hang bound of
// an answer (ANSWER_BOUND_MILLISECONDS). The caller sends its first call
// only after Ready. cancel: a word that another thread of the caller sets
// to stop the wait (the Escape of the console): the wait then ends at once
// with Refused. no_clock: true for a Process_Flag.No_Clock caller, which has
// no time page and waits until ready, cancel, or process stop.
connection_ready_wait :: proc "contextless" (calls: ^ring.Ring, process: Handle, cancel: ^u32 = nil, no_clock := false) -> isolated.Ready_Reading {
	deadline := no_clock ? WAIT_FOREVER : answer_deadline(time())
	for {
		wait := wait_begin()
		if cancel != nil {
			if intrinsics.atomic_load(cancel) != 0 {
				return .Refused
			}
			wait_word(&wait, cancel, 0)
		}
		// The state before the ring: a process that sent its completion and
		// stopped is read with its completion.
		state, _, _ := process_state(process)
		now := no_clock ? u64(0) : time()
		if reading, done := connection_ready_step(calls, now, deadline, state); done {
			return reading
		}
		wait_records(&wait, &calls.completions)
		wait_end(&wait, deadline)
	}
}
