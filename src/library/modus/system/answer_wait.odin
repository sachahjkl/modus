package system

import op "modus:contract/operation"

// The wait for an answer from another part of the machine: a device that
// answers a request of its device service, or a device service that answers
// its one client (src/md/features/missing_hardware.md). The wait ends at a
// deadline, or when the process that must answer stops, never later.

// The bound of a wait for an answer of another part of the machine: a
// device, a device service, a delegated service of the root service, the
// holder of a role. Each of them answers in microseconds, so a peer that is
// silent for a minute hangs: the bound is never a measure of a device, and
// a slow device is not called silent. It is a constant of the services, not
// a setting: a principal who tunes it fixes no fault. Each contract that
// waits for an answer names its own deadline from it. The hang bound of the
// tests is not under it (test_bounds.odin), so that a machine test reads the
// line of the service that gives up before its own report.
ANSWER_BOUND_MILLISECONDS :: 60_000

// answer_deadline gives the deadline of an answer to a request given at the
// time now. A time so large that the sum passes the largest time gives the
// largest time, which no wait passes: never a deadline in the past.
answer_deadline :: proc "contextless" (now: u64) -> u64 {
	if now > WAIT_FOREVER - ANSWER_BOUND_MILLISECONDS {
		return WAIT_FOREVER
	}
	return now + ANSWER_BOUND_MILLISECONDS
}

// What a wait for an answer does next.
Answer_Wait :: enum u8 {
	Waits, // The process that answers runs, and the deadline did not pass: wait again.
	Stopped, // The process that answers stopped, or the handle names none: no answer comes.
	Silent, // The process runs and the deadline passed: it does not answer.
}

// answer_wait_of decides a wait for an answer from the state of the
// process that answers and the time. The stop comes first: a process that
// stopped after the deadline did not answer either, and its stop is the
// fact that a reader can act on. A process not started yet is not stopped.
answer_wait_of :: proc "contextless" (now: u64, deadline: u64, state: op.Process_State) -> Answer_Wait {
	switch state {
	case .None, .Stopped:
		return .Stopped
	case .Created, .Ready, .Waiting:
	}
	return now >= deadline ? .Silent : .Waits
}

// answer_deadline_earliest gives the earliest deadline of the requests in
// flight, each place holding the deadline of its request or 0 for a free
// place; WAIT_FOREVER when no request is in flight.
answer_deadline_earliest :: proc "contextless" (deadlines: []u64) -> u64 {
	earliest := WAIT_FOREVER
	for deadline in deadlines {
		if deadline != 0 && deadline < earliest {
			earliest = deadline
		}
	}
	return earliest
}
