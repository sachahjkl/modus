// The path of one wide grant through the root service
// (src/md/features/wide_grants.md, "The path of a grant, end to end"): the
// ask, the screen, the proof, the grant in the collector, the wiring of the
// act records, the time that it holds, and its end. A pure part: no call of
// the kernel. Each step takes a word only in the stage that waits for it;
// any other word is refused with its Flow_Refusal and changes nothing but
// what the refusal says.
package wide_grant_flow

import "modus:contract/blake3"
import "modus:contract/wide_grants"

// After a refused screen, the key gets no screen for this long, on the
// clock of the system.
REFUSED_SCREEN_PAUSE_MILLISECONDS :: u64(10 * 60 * 1000)
// After this many refused screens in one run, no screen until the machine
// starts again.
REFUSED_SCREENS_MOST :: 3

// The stage of the one flow of the machine.
Stage :: enum u8 {
	Idle         = 0,
	Screen_Shown = 1, // The trusted display shows the screen; its answer is awaited.
	Proving      = 2, // `unlock` asks for the passphrase of the principal.
	Creating     = 3, // The collector checks the proof and opens the act spaces.
	Wiring       = 4, // The rings of `acts` are wired to the collector, one at a time.
	Active       = 5, // The grant holds.
}

// Why a step was refused.
Flow_Refusal :: enum u8 {
	None               = 0,
	Busy               = 1, // An ask while another flow runs.
	Not_Awaited        = 2, // A word that the stage does not wait for.
	Bad_Scopes         = 3, // A word of scopes that names no scope, or Send_Input without View_Screen.
	Bad_Duration       = 4, // 0, or past wide_grants.MAX_WIDE_GRANT_DURATION_MS.
	Paused             = 5, // The key is within its pause after a refused screen.
	Refused_For_Run    = 6, // REFUSED_SCREENS_MOST screens were refused in this run.
	Other_Flow         = 7, // An answer of another screen.
	Scope_Not_Proposed = 8, // The answer gives a scope that the ask did not propose.
	Duration_Past_Ask  = 9, // The answer gives a longer duration than the ask.
	Bad_Answer         = 10, // The border of the answer refused it.
	Other_Principal    = 11, // A proof of another principal than the flow.
	Terms_Refused      = 12, // The terms do not seal.
	No_Grant           = 13, // A grant serial of 0 from the collector.
	Other_Key          = 14, // An end of another key than the grant.
	Zero_Key           = 15, // A client key of 32 zero bytes.
}

Flow :: struct {
	stage:            Stage,
	serial:           u64, // The serial of the screen of this flow; it grows at each ask.
	principal:        u64,
	client_key:       [32]u8,
	proposed:         wide_grants.Wide_Authorities,
	proposed_ms:      u64,
	answer:           wide_grants.Screen_Answer,
	terms:            wide_grants.Wide_Grant_Terms,
	grant_serial:     u64,
	ends_at_ms:       u64,
	wired:            u32, // The rings of `acts` wired so far.
	refused_screens:  u32,
	paused_key:       [32]u8,
	paused_until_ms:  u64,
}

// flow_ask opens a flow for the client key of a principal, with the scopes
// and the duration that it proposes.
flow_ask :: proc "contextless" (flow: ^Flow, principal: u64, client_key: [32]u8, authorities_word: u64, duration_ms: u64, now_ms: u64) -> (serial: u64, refusal: Flow_Refusal) {
	if flow.stage != .Idle {
		return 0, .Busy
	}
	if flow.refused_screens >= REFUSED_SCREENS_MOST {
		return 0, .Refused_For_Run
	}
	if client_key == ([32]u8{}) {
		return 0, .Zero_Key
	}
	if client_key == flow.paused_key && now_ms < flow.paused_until_ms {
		return 0, .Paused
	}
	authorities, authorities_ok := wide_grants.wide_authorities_from_word(authorities_word)
	if !authorities_ok || (.Send_Input in authorities && .View_Screen not_in authorities) {
		return 0, .Bad_Scopes
	}
	if duration_ms == 0 || duration_ms > wide_grants.MAX_WIDE_GRANT_DURATION_MS {
		return 0, .Bad_Duration
	}
	counts := flow.refused_screens
	paused_key, paused_until := flow.paused_key, flow.paused_until_ms
	next := flow.serial + 1
	flow^ = {stage = .Screen_Shown, serial = next, principal = principal, client_key = client_key, proposed = authorities, proposed_ms = duration_ms, refused_screens = counts, paused_key = paused_key, paused_until_ms = paused_until}
	return next, .None
}

// flow_screen gives the screen of the flow, for the trusted display.
flow_screen :: proc "contextless" (flow: ^Flow) -> wide_grants.Screen_Show {
	head: u64
	for index in 0 ..< 8 {
		head |= u64(flow.client_key[index]) << (8 * u64(index))
	}
	return {flow_serial = flow.serial, principal_id = flow.principal, authorities = flow.proposed, duration_ms = flow.proposed_ms, client_key_head = head}
}

// flow_refuse_screen ends a flow whose screen the principal refused or
// whose proof it did not give: the key pauses, and the count grows.
@(private = "file")
flow_refuse_screen :: proc "contextless" (flow: ^Flow, now_ms: u64) {
	flow.refused_screens += 1
	flow.paused_key = flow.client_key
	flow.paused_until_ms = now_ms + REFUSED_SCREEN_PAUSE_MILLISECONDS
	flow_to_idle(flow)
}

// flow_to_idle ends the flow and keeps the counts of the refusals.
flow_to_idle :: proc "contextless" (flow: ^Flow) {
	counts := flow.refused_screens
	paused_key, paused_until := flow.paused_key, flow.paused_until_ms
	serial := flow.serial
	flow^ = {serial = serial, refused_screens = counts, paused_key = paused_key, paused_until_ms = paused_until}
}

// flow_screen_answer takes the answer of the screen. A refusal of the
// principal ends the flow with its pause; a broken answer ends the flow
// too: the trusted display gives no second answer to one screen.
flow_screen_answer :: proc "contextless" (flow: ^Flow, values: [7]u64, now_ms: u64) -> (decision: wide_grants.Screen_Decision, refusal: Flow_Refusal) {
	if flow.stage != .Screen_Shown {
		return .None, .Not_Awaited
	}
	answer, answer_refusal := wide_grants.screen_answer_of_values(values)
	if answer_refusal != .None {
		flow_to_idle(flow)
		return .None, .Bad_Answer
	}
	if answer.flow_serial != flow.serial {
		return .None, .Other_Flow
	}
	if answer.decision == .Refuse {
		flow_refuse_screen(flow, now_ms)
		return .Refuse, .None
	}
	if answer.authorities - flow.proposed != {} {
		flow_to_idle(flow)
		return .None, .Scope_Not_Proposed
	}
	if answer.duration_ms > flow.proposed_ms {
		flow_to_idle(flow)
		return .None, .Duration_Past_Ask
	}
	terms := wide_grants.Wide_Grant_Terms {
		principal_id          = flow.principal,
		grantee_identity_hash = blake3.hash(flow.client_key[:]),
		authorities_word      = wide_grants.wide_authorities_to_word(answer.authorities),
		target_window_count   = answer.window_count,
		duration_ms           = answer.duration_ms,
	}
	for index in 0 ..< int(answer.window_count) {
		terms.target_window_ids[index] = answer.window_ids[index]
	}
	if wide_grants.wide_grant_terms_seal(&terms) != .None {
		flow_to_idle(flow)
		return .None, .Terms_Refused
	}
	flow.answer = answer
	flow.terms = terms
	flow.stage = .Proving
	return .Give, .None
}

// flow_proved takes the end of the proof of `unlock`. A proof of another
// principal ends the flow with no grant; a cancelled or refused proof ends
// it as a refused screen does.
flow_proved :: proc "contextless" (flow: ^Flow, principal: u64, proved: bool, now_ms: u64) -> Flow_Refusal {
	if flow.stage != .Proving {
		return .Not_Awaited
	}
	if principal != flow.principal {
		flow_to_idle(flow)
		return .Other_Principal
	}
	if !proved {
		flow_refuse_screen(flow, now_ms)
		return .None
	}
	flow.stage = .Creating
	return .None
}

// flow_created takes the grant serial that the collector gave.
flow_created :: proc "contextless" (flow: ^Flow, grant_serial: u64) -> Flow_Refusal {
	if flow.stage != .Creating {
		return .Not_Awaited
	}
	if grant_serial == 0 {
		flow_to_idle(flow)
		return .No_Grant
	}
	flow.grant_serial = grant_serial
	flow.stage = .Wiring
	return .None
}

// flow_wired counts one ring of `acts` wired; after rings rings, the grant
// holds until now_ms plus its duration.
flow_wired :: proc "contextless" (flow: ^Flow, rings: u32, now_ms: u64) -> (active: bool, refusal: Flow_Refusal) {
	if flow.stage != .Wiring || rings == 0 {
		return false, .Not_Awaited
	}
	flow.wired += 1
	if flow.wired < rings {
		return false, .None
	}
	flow.stage = .Active
	flow.ends_at_ms = now_ms + flow.terms.duration_ms
	return true, .None
}

// flow_end_key says if an end names the key of the grant that the flow
// holds or creates.
flow_end_key :: proc "contextless" (flow: ^Flow, client_key: [32]u8) -> Flow_Refusal {
	switch flow.stage {
	case .Idle:
		return .Not_Awaited
	case .Screen_Shown, .Proving, .Creating, .Wiring, .Active:
	}
	if client_key != flow.client_key {
		return .Other_Key
	}
	return .None
}

// flow_due says if the grant reached its end time.
flow_due :: proc "contextless" (flow: ^Flow, now_ms: u64) -> bool {
	return flow.stage == .Active && now_ms >= flow.ends_at_ms
}
