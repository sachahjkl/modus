// Pure client call-retry state machine for surviving role connections
// (src/md/features/supervision.md, "The rule that makes a replay safe").
//
// Given a call's Call_Replay_Rule and Connection_Snapshot observations from
// Connection_Page:
// - Idempotent: resends once automatically when a new holder connects;
// - Serial_Tracked: resends once with the exact same request_serial so the new
//   holder deduplicates via Request_Serial_Log and executes at most once;
// - Not_Idempotent: never auto-resends; returns Holder_Stopped_In_Flight;
// - Single-retry bound: at most MAX_AUTOMATIC_RETRIES (1) automatic retry per
//   call, preventing infinite restart loops if the new holder also stops.
package supervision

import "modus:contract/call_outcome"

// Lifecycle state of one tracked client call across holder restarts.
Client_Call_State :: enum u32 {
	None                  = 0,
	In_Flight             = 1,
	Waiting_For_Reconnect = 2,
	Ready_To_Resend       = 3,
	Completed             = 4,
	Failed                = 5,
}

// Action the client library must take after observing a connection page state
// or receiving a completion.
Client_Retry_Decision :: enum u32 {
	None                           = 0,
	Continue_Waiting               = 1,
	Complete_With_Answer           = 2,
	Resend_To_New_Holder           = 3,
	Return_Holder_Stopped_In_Flight = 4,
	Return_Connection_Closed       = 5,
	Refuse_Invalid_Input           = 6,
}

// Pure per-call retry tracker owned by the client library.
Client_Call_Tracker :: struct {
	replay_rule:            Call_Replay_Rule,
	request_serial:         u64,
	sent_holder_generation: u64,
	retries_used:           u32,
	state:                  Client_Call_State,
	completed_result_word:  u64,
}

// client_call_ended_outcome gives the call outcome that the client library
// gives its caller for a decision that ends the call with no answer
// (src/md/api/call_outcome.md, "The calls of supervision"): the call left,
// so it is in doubt. ended is false for each decision that does not end the
// call that way: the answer of a completion carries its own outcome.
client_call_ended_outcome :: proc "contextless" (decision: Client_Retry_Decision) -> (outcome: call_outcome.Call_Outcome, ended: bool) {
	switch decision {
	case .Return_Holder_Stopped_In_Flight:
		return .Callee_Stopped_During_The_Call, true
	case .Return_Connection_Closed:
		return .Connection_Ended_During_The_Call, true
	case .None, .Continue_Waiting, .Complete_With_Answer, .Resend_To_New_Holder, .Refuse_Invalid_Input:
	}
	return .Succeeded, false
}

// client_call_begin starts tracking an outgoing call on a Connected connection.
// Refuses invalid replay rules, non-Connected snapshots, zero holder
// generation, or a zero request_serial for Serial_Tracked calls. A call that
// it refuses did not leave: the client library gives Callee_Unavailable.
client_call_begin :: proc "contextless" (
	replay_rule: Call_Replay_Rule,
	request_serial: u64,
	snapshot: Connection_Snapshot,
) -> (tracker: Client_Call_Tracker, ok: bool) {
	valid_rule, rule_ok := call_replay_rule_from_word(u64(replay_rule))
	if !rule_ok {
		return {}, false
	}
	valid_state, state_ok := connection_state_from_word(u64(snapshot.state))
	if !state_ok || valid_state != .Connected || snapshot.holder_generation == 0 {
		return {}, false
	}
	if valid_rule == .Serial_Tracked && request_serial == 0 {
		return {}, false
	}
	return Client_Call_Tracker{
		replay_rule            = valid_rule,
		request_serial         = request_serial,
		sent_holder_generation = snapshot.holder_generation,
		retries_used           = 0,
		state                  = .In_Flight,
		completed_result_word  = 0,
	}, true
}

// client_call_complete records a completion read from the call ring (whether
// written by the old holder before stopping or by the new holder after replay).
// A call that was answered is never in doubt and never replayed.
client_call_complete :: proc "contextless" (
	tracker: ^Client_Call_Tracker,
	result_word: u64,
) -> Client_Retry_Decision {
	if tracker == nil {
		return .Refuse_Invalid_Input
	}
	switch tracker.state {
	case .In_Flight, .Waiting_For_Reconnect:
		tracker.completed_result_word = result_word
		tracker.state = .Completed
		return .Complete_With_Answer
	case .None, .Ready_To_Resend, .Completed, .Failed:
		return .Refuse_Invalid_Input
	}
	return .Refuse_Invalid_Input
}

// client_call_on_connection_change evaluates a fresh Connection_Snapshot read
// from the connection page and decides whether to wait, resend once to the new
// holder, or return an error to the caller.
client_call_on_connection_change :: proc "contextless" (
	tracker: ^Client_Call_Tracker,
	snapshot: Connection_Snapshot,
) -> Client_Retry_Decision {
	if tracker == nil {
		return .Refuse_Invalid_Input
	}
	valid_rule, rule_ok := call_replay_rule_from_word(u64(tracker.replay_rule))
	if !rule_ok {
		return .Refuse_Invalid_Input
	}
	valid_state, state_ok := connection_state_from_word(u64(snapshot.state))
	if !state_ok {
		return .Refuse_Invalid_Input
	}
	if snapshot.holder_generation == 0 || snapshot.holder_generation < tracker.sent_holder_generation {
		return .Refuse_Invalid_Input
	}
	switch tracker.state {
	case .None, .Ready_To_Resend, .Completed, .Failed:
		return .Refuse_Invalid_Input
	case .In_Flight, .Waiting_For_Reconnect:
	}

	switch valid_state {
	case .None:
		return .Refuse_Invalid_Input
	case .Closed:
		tracker.state = .Failed
		return .Return_Connection_Closed
	case .Holder_Stopped, .Reconnecting:
		if valid_rule == .Not_Idempotent {
			tracker.state = .Failed
			return .Return_Holder_Stopped_In_Flight
		}
		if tracker.retries_used >= MAX_AUTOMATIC_RETRIES {
			tracker.state = .Failed
			return .Return_Holder_Stopped_In_Flight
		}
		tracker.state = .Waiting_For_Reconnect
		return .Continue_Waiting
	case .Connected:
		if snapshot.holder_generation == tracker.sent_holder_generation {
			if tracker.state == .Waiting_For_Reconnect {
				// Reconnecting must advance holder_generation strictly; seeing
				// the old generation again after Holder_Stopped is invalid.
				return .Refuse_Invalid_Input
			}
			return .Continue_Waiting
		}
		// A new holder (higher holder_generation) now serves the connection.
		switch valid_rule {
		case .None:
			return .Refuse_Invalid_Input
		case .Not_Idempotent:
			tracker.state = .Failed
			return .Return_Holder_Stopped_In_Flight
		case .Idempotent, .Serial_Tracked:
			if tracker.retries_used >= MAX_AUTOMATIC_RETRIES {
				tracker.state = .Failed
				return .Return_Holder_Stopped_In_Flight
			}
			tracker.retries_used += 1
			tracker.sent_holder_generation = snapshot.holder_generation
			tracker.state = .Ready_To_Resend
			return .Resend_To_New_Holder
		}
	}
	return .Refuse_Invalid_Input
}

// client_call_mark_resent acknowledges that the client library wrote the
// replayed call (with the same request_serial) into the call ring and moves
// the tracker back to In_Flight.
client_call_mark_resent :: proc "contextless" (tracker: ^Client_Call_Tracker) -> bool {
	if tracker == nil || tracker.state != .Ready_To_Resend {
		return false
	}
	tracker.state = .In_Flight
	return true
}
