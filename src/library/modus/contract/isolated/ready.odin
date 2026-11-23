package isolated

// The ready completion of a call ring (src/md/api/call_ring_ready.md): the
// first completion that the serving side sends, once it maps the ring with
// the consent to receive handles. A caller sends its first call only after
// it; until then the kernel has no receiver for a lent handle.

import "modus:contract/ring"

// The tag of the first completion of a call ring. No call has it: a caller
// numbers its calls from 1.
READY_TAG :: 0

// What the first completion of a call ring says.
Ready_Reading :: enum u8 {
	Ready       = 0, // The serving side maps the ring with consent: the caller can call and lend.
	Load_Failed = 1, // A call host did not load its module: the call region starts with its load error.
	Refused     = 2, // Not a first completion: the caller ends the connection.
}

// ready_record gives the ready completion that the serving side sends.
ready_record :: proc "contextless" () -> ring.Record {
	return {kind = u32(Status.Ok), tag = READY_TAG}
}

// ready_of_first_completion is the border of the first completion of a
// call ring, which the other process writes. It refuses a tag other than
// READY_TAG (no call was sent, so no answer of a call comes first), a kind
// other than Ok or Load_Failed, and values that are not zero.
ready_of_first_completion :: proc "contextless" (record: ring.Record) -> Ready_Reading {
	if record.tag != READY_TAG || record.values != {} {
		return .Refused
	}
	switch record.kind {
	case u32(Status.Ok):
		return .Ready
	case u32(Status.Load_Failed):
		return .Load_Failed
	}
	return .Refused
}
