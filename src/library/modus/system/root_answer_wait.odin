package system

// The wait for the answer of the root service to a request of its ring: a
// Connect, which can start the service first, and the Disconnect of a
// connection that the caller gives up. A caller holds no handle of the root
// service, and a stop of the root service is the end of the machine: the
// one bound is the hang bound of an answer (ANSWER_BOUND_MILLISECONDS),
// never a time of a start, which a loaded host makes many times longer
// (src/md/api/call_ring_ready.md, "The bound is the hang bound").

import "modus:contract/ring"
import "modus:contract/root_ring"

// The abandoned Connect tags that a caller remembers so a later drain of
// its root ring closes their late handles.
ABANDONED_CONNECT_CAPACITY :: 16

// Tags of Connects that a caller gave up without waiting (Escape in the
// console): each late answer whose tag is here has its handles closed on
// the next drain of the root ring.
Abandoned_Connects :: struct {
	tags: [ABANDONED_CONNECT_CAPACITY]u32,
	next: int,
}

// abandoned_connect_add records a Connect tag whose late answer must have
// its handles closed. Tag 0 is ignored.
abandoned_connect_add :: proc "contextless" (abandoned: ^Abandoned_Connects, tag: u32) {
	if abandoned == nil || tag == 0 {
		return
	}
	for existing in abandoned.tags {
		if existing == tag {
			return
		}
	}
	for &slot in abandoned.tags {
		if slot == 0 {
			slot = tag
			return
		}
	}
	abandoned.tags[abandoned.next] = tag
	abandoned.next = (abandoned.next + 1) % ABANDONED_CONNECT_CAPACITY
}

// abandoned_connect_take removes tag from abandoned and reports whether it
// was recorded.
abandoned_connect_take :: proc "contextless" (abandoned: ^Abandoned_Connects, tag: u32) -> bool {
	if abandoned == nil || tag == 0 {
		return false
	}
	for &slot in abandoned.tags {
		if slot == tag {
			slot = 0
			return true
		}
	}
	return false
}

// root_answer_step reads the completions of the ring once. It gives the
// completion with the tag; it skips each other completion, closing the
// handles of any completion whose tag is in abandoned (on_abandoned). done
// is true when the answer came, or at the deadline.
root_answer_step :: proc "contextless" (
	requests: ^ring.Ring,
	tag: u32,
	now, deadline: u64,
	abandoned: ^Abandoned_Connects = nil,
	on_abandoned: proc "contextless" (ring.Record) = connect_answer_close,
) -> (record: ring.Record, answered: bool, done: bool) {
	for completion in receive(&requests.completions) {
		if completion.tag == tag {
			return completion, true, true
		}
		if abandoned_connect_take(abandoned, completion.tag) && on_abandoned != nil {
			on_abandoned(completion)
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

// connect_abandon ends a Connect without waiting for the root service:
// used when the principal pressed Escape or a caller with unique tags
// gives up a Connect. It records connect_tag so the next drain of the root
// ring closes the handles of any late Connect answer, and sends Disconnect.
connect_abandon :: proc "contextless" (requests: ^ring.Ring, abandoned: ^Abandoned_Connects, connect_tag, disconnect_tag: u32, packed: [4]u64) {
	abandoned_connect_add(abandoned, connect_tag)
	send(&requests.commands, ring.Record{kind = u32(root_ring.Root_Command.Disconnect), tag = disconnect_tag, values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}})
}

// connect_give_up ends a Connect whose answer did not come before the hang
// bound. The root service can still answer it, and it then holds a
// connection for this caller, refuses the next Connect of the caller to
// the service, and gives handles that nobody closes. So the caller sends
// Disconnect, then takes the two answers in the order of the ring of the
// root service: the answer of the Connect first, whose handles it closes,
// then the answer of the Disconnect. With one tag for the two requests, a
// caller that gives the same tag to each Connect reads neither answer as
// the answer of its next request.
connect_give_up :: proc "contextless" (requests: ^ring.Ring, connect_tag, disconnect_tag: u32, packed: [4]u64) {
	if !send(&requests.commands, ring.Record{kind = u32(root_ring.Root_Command.Disconnect), tag = disconnect_tag, values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}}) {
		return
	}
	if record, came := root_answer_wait(requests, connect_tag); came {
		connect_answer_close(record)
	}
	root_answer_wait(requests, disconnect_tag)
}

// connect_answer_close closes the three handles of an answer of Connect
// that the caller does not keep: the process, the call ring and the call
// region. A refusal holds an error record, not handles.
connect_answer_close :: proc "contextless" (record: ring.Record) {
	if record.kind != u32(Status.Ok) {
		return
	}
	for index in 0 ..< 3 {
		if value := record.values[index]; value != 0 && value >> 32 == 0 {
			close(Handle(value))
		}
	}
}
