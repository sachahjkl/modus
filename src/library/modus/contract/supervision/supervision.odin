// Supervision contract: closed enumerations, transport borders, connection
// page layout, request serial deduplication, and client call retry rules
// (src/md/features/supervision.md).
//
// This is a contract package: it imports base packages and contract packages
// only, calls no kernel operation, and allocates no memory.
package supervision

import "modus:contract/enum_word"

// Maximum automatic retries that a client library performs for one in-flight
// call when a holder stops and a new holder takes over the connection.
MAX_AUTOMATIC_RETRIES :: u32(1)

// Maximum serial-tracked calls kept in flight per connection. The holder keeps
// this many recent committed results per client so replayed calls return their
// stored result without running again.
REQUEST_SERIALS_IN_FLIGHT :: 8

// Maximum concurrent client connections tracked in one fixed-capacity request
// serial deduplication table.
REQUEST_LOG_CLIENT_CAPACITY :: 16

// Magic bytes "MSCONNPG" identifying a valid supervision connection page.
CONNECTION_PAGE_MAGIC :: u64(0x47504E4E4F43534D)

// Wire version of the connection page header.
CONNECTION_PAGE_VERSION :: u32(1)

// Page size bound for a connection page mapping.
CONNECTION_PAGE_SIZE :: 4096

// Maximum bounded retry attempts when reading a connection page seqlock so a
// client never spins forever on a stalled writer.
CONNECTION_PAGE_READ_ATTEMPTS :: 64

// Restart strategy that a supervisor applies when one of its supervised
// children stops. Zero means unset and is refused at the border.
Restart_Strategy :: enum u32 {
	None         = 0,
	One_For_One  = 1,
	One_For_All  = 2,
	Rest_For_One = 3,
}

// Lifecycle state of a surviving role connection on its connection page. Zero
// means unwritten memory and is refused at the border.
Connection_State :: enum u32 {
	None           = 0,
	Connected      = 1,
	Holder_Stopped = 2,
	Reconnecting   = 3,
	Closed         = 4,
}

// Replay rule declared for a call when the holder stops while the call is in
// flight. Zero means unset and is refused at the border.
Call_Replay_Rule :: enum u32 {
	None           = 0,
	Not_Idempotent = 1,
	Idempotent     = 2,
	Serial_Tracked = 3,
}

// Decision produced by the supervision tree when a child stops. Zero means
// unset and is refused at the border.
Escalation_Action :: enum u32 {
	None               = 0,
	Restart_Child      = 1,
	Restart_Group      = 2,
	Escalate_To_Parent = 3,
	Stop_Permanently   = 4,
}

// restart_strategy_from_word converts a transport word into a Restart_Strategy,
// refusing zero and every unknown word.
restart_strategy_from_word :: proc "contextless" (word: u64) -> (strategy: Restart_Strategy, ok: bool) {
	member := enum_word.member_of_word(Restart_Strategy, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// connection_state_from_word converts a transport word into a Connection_State,
// refusing zero and every unknown word.
connection_state_from_word :: proc "contextless" (word: u64) -> (state: Connection_State, ok: bool) {
	member := enum_word.member_of_word(Connection_State, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// call_replay_rule_from_word converts a transport word into a Call_Replay_Rule,
// refusing zero and every unknown word.
call_replay_rule_from_word :: proc "contextless" (word: u64) -> (rule: Call_Replay_Rule, ok: bool) {
	member := enum_word.member_of_word(Call_Replay_Rule, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}

// escalation_action_from_word converts a transport word into an
// Escalation_Action, refusing zero and every unknown word.
escalation_action_from_word :: proc "contextless" (word: u64) -> (action: Escalation_Action, ok: bool) {
	member := enum_word.member_of_word(Escalation_Action, word) or_return
	if member == .None {
		return .None, false
	}
	return member, true
}
