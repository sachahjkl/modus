// The path of one wide grant through the root service
// (src/md/features/wide_grants.md, "The path of a grant, end to end"): the
// ask, the screen, the proof, the grant in the collector, the wiring of the
// act records, the time that it holds, and its end. A pure part: no call of
// the kernel. Each step takes a word only in the stage that waits for it,
// and only with the tag or the flow that it waits for; any other word is
// refused with its Flow_Refusal and changes nothing.
package wide_grant_flow

import "modus:contract/blake3"
import "modus:contract/wide_grants"

// After a refused screen, the key gets no screen for this long, on the
// clock of the system.
REFUSED_SCREEN_PAUSE_MILLISECONDS :: u64(10 * 60 * 1000)
// After this many refused screens of one key in one run, that key gets no
// screen until the machine starts again.
REFUSED_SCREENS_MOST :: 3
// After this many proofs not given by one principal, its keys get no screen
// until the principal unlocks its session again.
PROOF_FAILURES_MOST :: 3
// The keys whose refusals the flow counts at once: each row of the client
// table of `remote` fits (the root service asserts it against
// remote.CLIENT_CAPACITY). A key past them takes the place of the key whose
// pause ended first.
KEY_RECORDS_MOST :: 64
// The principals whose proofs the flow counts: principals.PRINCIPAL_CAPACITY
// at least (the root service asserts it).
PRINCIPALS_MOST :: 16
// The end of a grant waits this long for the answer of the collector and of
// the wiring service, then goes back to Idle: a collector that stopped
// never answers, and its grant ended with it.
END_BOUND_MILLISECONDS :: u64(5000)

// The stage of the one flow of the machine.
Stage :: enum u8 {
	Idle         = 0,
	Screen_Shown = 1, // The trusted display shows the screen; its answer is awaited.
	Proving      = 2, // `unlock` asks for the passphrase of the principal.
	Creating     = 3, // The collector checks the proof and opens the act spaces.
	Wiring       = 4, // The rings of `acts` are wired to the collector, one at a time.
	Active       = 5, // The grant holds.
	Ending       = 6, // The grant ended: its revocation in the collector and the end of its wirings are on their way.
}

// Why a step was refused.
Flow_Refusal :: enum u8 {
	None               = 0,
	Busy               = 1, // An ask while another flow runs or ends.
	Not_Awaited        = 2, // A word that the stage does not wait for.
	Bad_Scopes         = 3, // A word of scopes that the screen does not draw.
	Bad_Duration       = 4, // 0, or past wide_grants.MAX_WIDE_GRANT_DURATION_MS.
	Paused             = 5, // The key is within its pause after a refused screen.
	Refused_For_Run    = 6, // REFUSED_SCREENS_MOST screens of the key were refused in this run.
	Other_Flow         = 7, // A word of another screen, or of another flow.
	Scope_Not_Proposed = 8, // The answer gives a scope that the ask did not propose.
	Duration_Past_Ask  = 9, // The answer gives a longer duration than the ask.
	Bad_Answer         = 10, // The border of the answer refused it.
	Other_Principal    = 11, // A proof of another principal than the flow, or a principal past PRINCIPALS_MOST.
	Terms_Refused      = 12, // The terms do not seal.
	No_Grant           = 13, // A grant serial of 0 from the collector.
	Other_Key          = 14, // An end of another key than the grant.
	Zero_Key           = 15, // A client key of 32 zero bytes.
	Other_Tag          = 16, // An answer of the collector to another command.
	Proofs_Refused     = 17, // PROOF_FAILURES_MOST proofs of the principal were not given since its unlock.
}

// What the flow counts of one key in a run.
Key_Record :: struct {
	key:             [32]u8,
	refused:         u32,
	paused_until_ms: u64,
}

// The work of the end of a grant, kept until each part is done or the
// bound passes.
End_Work :: struct {
	reason:          wide_grants.Revocation_Reason,
	revoke_serial:   u64, // The grant that the collector must end; 0: none.
	revoke_tag:      u32, // The tag of the Revoke_Grant sent; 0: not sent yet.
	revoke_done:     bool,
	create_tag:      u32, // A Create_Grant whose answer is awaited: its grant is revoked when it comes.
	unwire_needed:   bool,
	unwire_sent:     bool,
	deadline_ms:     u64,
	row_held_grant:  bool, // The row of the key held the grant: it gets a new serial.
}

Flow :: struct {
	stage:          Stage,
	serial:         u64, // The serial of the screen of this flow; it grows at each ask.
	principal:      u64,
	client_key:     [32]u8,
	proposed:       wide_grants.Wide_Authorities,
	proposed_ms:    u64,
	answer:         wide_grants.Screen_Answer,
	terms:          wide_grants.Wide_Grant_Terms,
	create_tag:     u32,
	grant_serial:   u64,
	ends_at_ms:     u64, // Set once, when the proof is given; Create_Grant carries it.
	wired:          u32, // The rings of `acts` wired so far.
	end:            End_Work,
	keys:           [KEY_RECORDS_MOST]Key_Record,
	// The one record of the keys that find no place, each place being held
	// by a key barred for the run: their refusals count together, so a new
	// key cannot ask with no pause once the table is barred whole.
	unplaced:       Key_Record,
	proof_failures: [PRINCIPALS_MOST]u32,
}

@(private = "file")
key_record_of :: proc "contextless" (flow: ^Flow, key: [32]u8) -> ^Key_Record {
	for &record in flow.keys {
		if record.key == key {
			return &record
		}
	}
	return nil
}

// key_table_barred says if each place of the table holds a key barred for
// the run: a key with no record shares the record unplaced.
@(private = "file")
key_table_barred :: proc "contextless" (flow: ^Flow) -> bool {
	for &record in flow.keys {
		if record.key == ([32]u8{}) || record.refused < REFUSED_SCREENS_MOST {
			return false
		}
	}
	return true
}

// key_record_take gives the record of a key, or a free one, or the one
// whose pause ended first with no refusal count that bars the key, or the
// shared record unplaced when each place is barred. A key barred for the
// run keeps its place.
@(private = "file")
key_record_take :: proc "contextless" (flow: ^Flow, key: [32]u8) -> ^Key_Record {
	if found := key_record_of(flow, key); found != nil {
		return found
	}
	oldest: ^Key_Record
	for &record in flow.keys {
		if record.key == ([32]u8{}) {
			record = {key = key}
			return &record
		}
		if record.refused >= REFUSED_SCREENS_MOST {
			continue
		}
		if oldest == nil || record.paused_until_ms < oldest.paused_until_ms {
			oldest = &record
		}
	}
	if oldest == nil {
		return &flow.unplaced
	}
	oldest^ = {key = key}
	return oldest
}

// flow_ask opens a flow for the client key of a principal, with the scopes
// and the duration that it proposes.
flow_ask :: proc "contextless" (flow: ^Flow, principal: u64, client_key: [32]u8, authorities_word: u64, duration_ms: u64, now_ms: u64) -> (serial: u64, refusal: Flow_Refusal) {
	if flow.stage != .Idle {
		return 0, .Busy
	}
	if client_key == ([32]u8{}) {
		return 0, .Zero_Key
	}
	if principal >= PRINCIPALS_MOST {
		return 0, .Other_Principal
	}
	if flow.proof_failures[principal] >= PROOF_FAILURES_MOST {
		return 0, .Proofs_Refused
	}
	record := key_record_of(flow, client_key)
	if record == nil && key_table_barred(flow) {
		record = &flow.unplaced
	}
	if record != nil {
		if record.refused >= REFUSED_SCREENS_MOST {
			return 0, .Refused_For_Run
		}
		if now_ms < record.paused_until_ms {
			return 0, .Paused
		}
	}
	authorities, authorities_ok := wide_grants.screen_authorities_of_word(authorities_word)
	if !authorities_ok {
		return 0, .Bad_Scopes
	}
	if duration_ms == 0 || duration_ms > wide_grants.MAX_WIDE_GRANT_DURATION_MS {
		return 0, .Bad_Duration
	}
	flow.serial += 1
	flow_fields_clear(flow)
	flow.stage = .Screen_Shown
	flow.principal = principal
	flow.client_key = client_key
	flow.proposed = authorities
	flow.proposed_ms = duration_ms
	return flow.serial, .None
}

// flow_fields_clear empties the fields of one flow and keeps the counts of
// the run and the serial.
@(private = "file")
flow_fields_clear :: proc "contextless" (flow: ^Flow) {
	keys := flow.keys
	unplaced := flow.unplaced
	failures := flow.proof_failures
	serial := flow.serial
	flow^ = {serial = serial, keys = keys, unplaced = unplaced, proof_failures = failures}
}

// flow_screen gives the screen of the flow, for the trusted display.
flow_screen :: proc "contextless" (flow: ^Flow) -> wide_grants.Screen_Show {
	head: u64
	for index in 0 ..< 8 {
		head |= u64(flow.client_key[index]) << (8 * u64(index))
	}
	return {flow_serial = flow.serial, principal_id = flow.principal, authorities = flow.proposed, duration_ms = flow.proposed_ms, client_key_head = head}
}

// flow_screen_refused counts a refused screen of the key of the flow: the
// key pauses. A key with no place left in the table counts in the shared
// record of the keys with no place: the flow never forgets a refusal to
// let a key ask again.
@(private = "file")
flow_screen_refused :: proc "contextless" (flow: ^Flow, now_ms: u64) {
	record := key_record_take(flow, flow.client_key)
	record.refused += 1
	record.paused_until_ms = now_ms + REFUSED_SCREEN_PAUSE_MILLISECONDS
}

// flow_to_idle ends a flow that holds nothing in the collector.
flow_to_idle :: proc "contextless" (flow: ^Flow) {
	flow_fields_clear(flow)
}

// flow_screen_answer takes the answer of the screen. A refusal of the
// principal ends the flow with the pause of the key; a broken answer ends
// the flow too: the trusted display gives no second answer to one screen.
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
		flow_screen_refused(flow, now_ms)
		flow_to_idle(flow)
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
// principal ends the flow with no grant; a proof not given counts for the
// principal. A proof given fixes the one end time of the grant, which
// Create_Grant carries to the collector.
flow_proved :: proc "contextless" (flow: ^Flow, principal: u64, proved: bool, now_ms: u64) -> Flow_Refusal {
	if flow.stage != .Proving {
		return .Not_Awaited
	}
	if principal != flow.principal {
		flow_to_idle(flow)
		return .Other_Principal
	}
	if !proved {
		flow.proof_failures[principal] += 1
		flow_to_idle(flow)
		return .None
	}
	flow.stage = .Creating
	flow.ends_at_ms = now_ms + flow.terms.duration_ms
	return .None
}

// flow_principal_unlocked says that a principal unlocked its session: its
// count of proofs not given starts again.
flow_principal_unlocked :: proc "contextless" (flow: ^Flow, principal: u64) {
	if principal < PRINCIPALS_MOST {
		flow.proof_failures[principal] = 0
	}
}

// flow_create_sent keeps the tag of the Create_Grant of the flow.
flow_create_sent :: proc "contextless" (flow: ^Flow, tag: u32) -> Flow_Refusal {
	if flow.stage != .Creating || tag == 0 || flow.create_tag != 0 {
		return .Not_Awaited
	}
	flow.create_tag = tag
	return .None
}

// flow_created takes an answer of the collector to a Create_Grant: the
// grant of the flow, or the grant of a flow that ended while it waited,
// which the end then revokes. grant_serial 0 is a refusal.
flow_created :: proc "contextless" (flow: ^Flow, tag: u32, grant_serial: u64) -> Flow_Refusal {
	if tag == 0 {
		return .Other_Tag
	}
	if flow.stage == .Ending && tag == flow.end.create_tag {
		flow.end.create_tag = 0
		if grant_serial != 0 {
			flow.end.revoke_serial = grant_serial
			flow.end.revoke_done = false
		}
		return .None
	}
	if flow.stage != .Creating || flow.create_tag == 0 {
		return .Not_Awaited
	}
	if tag != flow.create_tag {
		return .Other_Tag
	}
	if grant_serial == 0 {
		flow_to_idle(flow)
		return .No_Grant
	}
	flow.grant_serial = grant_serial
	flow.stage = .Wiring
	return .None
}

// flow_wired counts one ring of `acts` wired for the flow flow_serial;
// after rings rings, the grant holds.
flow_wired :: proc "contextless" (flow: ^Flow, flow_serial: u64, rings: u32) -> (active: bool, refusal: Flow_Refusal) {
	if flow.stage != .Wiring || rings == 0 {
		return false, .Not_Awaited
	}
	if flow_serial != flow.serial {
		return false, .Other_Flow
	}
	flow.wired += 1
	if flow.wired < rings {
		return false, .None
	}
	flow.stage = .Active
	return true, .None
}

// flow_end_key says if an end names the key of the grant that the flow
// holds or creates.
flow_end_key :: proc "contextless" (flow: ^Flow, client_key: [32]u8) -> Flow_Refusal {
	switch flow.stage {
	case .Idle, .Ending:
		return .Not_Awaited
	case .Screen_Shown, .Proving, .Creating, .Wiring, .Active:
	}
	if client_key != flow.client_key {
		return .Other_Key
	}
	return .None
}

// flow_end ends the flow in any stage but Idle and Ending. A flow that
// holds nothing in the collector goes back to Idle; else it waits in
// Ending for the revocation of its grant, the answer of a Create_Grant that
// it sent, and the end of its wirings. collector_ended: the collector ended
// the grant itself, and needs no Revoke_Grant.
flow_end :: proc "contextless" (flow: ^Flow, reason: wide_grants.Revocation_Reason, collector_ended: bool, now_ms: u64) -> Flow_Refusal {
	switch flow.stage {
	case .Idle, .Ending:
		return .Not_Awaited
	case .Screen_Shown, .Proving:
		flow_to_idle(flow)
		return .None
	case .Creating, .Wiring, .Active:
	}
	work := End_Work {
		reason         = reason,
		revoke_serial  = flow.grant_serial,
		revoke_done    = collector_ended || flow.grant_serial == 0,
		create_tag     = flow.stage == .Creating ? flow.create_tag : 0,
		unwire_needed  = flow.stage == .Wiring || flow.stage == .Active,
		deadline_ms    = now_ms + END_BOUND_MILLISECONDS,
		row_held_grant = flow.stage == .Active,
	}
	key := flow.client_key
	principal := flow.principal
	grant := flow.grant_serial
	flow_fields_clear(flow)
	flow.stage = .Ending
	flow.end = work
	flow.client_key = key
	flow.principal = principal
	flow.grant_serial = grant
	return .None
}

// flow_revoke_due gives the grant that the end must revoke now: none when
// it was sent, answered, or when no grant is known yet.
flow_revoke_due :: proc "contextless" (flow: ^Flow) -> (grant_serial: u64, reason: wide_grants.Revocation_Reason, due: bool) {
	if flow.stage != .Ending || flow.end.revoke_done || flow.end.revoke_tag != 0 || flow.end.revoke_serial == 0 {
		return 0, .None, false
	}
	return flow.end.revoke_serial, flow.end.reason, true
}

// flow_revoke_sent keeps the tag of the Revoke_Grant that left. A ring that
// was full sent nothing, and the next pass asks flow_revoke_due again.
flow_revoke_sent :: proc "contextless" (flow: ^Flow, tag: u32) -> Flow_Refusal {
	if _, _, due := flow_revoke_due(flow); !due || tag == 0 {
		return .Not_Awaited
	}
	flow.end.revoke_tag = tag
	return .None
}

// flow_revoke_answered takes the answer of the collector to the
// Revoke_Grant of the end, by its tag.
flow_revoke_answered :: proc "contextless" (flow: ^Flow, tag: u32) -> Flow_Refusal {
	if flow.stage != .Ending || flow.end.revoke_tag == 0 {
		return .Not_Awaited
	}
	if tag != flow.end.revoke_tag {
		return .Other_Tag
	}
	flow.end.revoke_done = true
	return .None
}

// flow_unwire_due says if the end must ask the end of the wirings of the
// collector now: after the collector answered the revocation, so the end
// record that it writes has the reason of the end, not the close of a ring.
flow_unwire_due :: proc "contextless" (flow: ^Flow) -> bool {
	return flow.stage == .Ending && flow.end.revoke_done && flow.end.create_tag == 0 && flow.end.unwire_needed && !flow.end.unwire_sent
}

flow_unwire_sent :: proc "contextless" (flow: ^Flow) {
	if flow_unwire_due(flow) {
		flow.end.unwire_sent = true
	}
}

// flow_unwired takes the answer of the wiring service to the end of the
// wirings: a refusal asks again at the next pass.
flow_unwired :: proc "contextless" (flow: ^Flow, done: bool) -> Flow_Refusal {
	if flow.stage != .Ending || !flow.end.unwire_sent {
		return .Not_Awaited
	}
	flow.end.unwire_sent = false
	if done {
		flow.end.unwire_needed = false
	}
	return .None
}

// flow_collector_gone says that the collector of the flow stopped: its
// grants and its wirings ended with it, so the end waits for nothing more
// of it.
flow_collector_gone :: proc "contextless" (flow: ^Flow) {
	if flow.stage != .Ending {
		return
	}
	flow.end.revoke_done = true
	flow.end.create_tag = 0
	flow.end.unwire_needed = false
	flow.end.unwire_sent = false
}

// flow_end_settle ends the end: when each part is done, or when the bound
// passed. It gives true when the flow went back to Idle, and late when the
// bound ended it with a part not done.
flow_end_settle :: proc "contextless" (flow: ^Flow, now_ms: u64) -> (settled: bool, late: bool) {
	if flow.stage != .Ending {
		return false, false
	}
	done := flow.end.revoke_done && flow.end.create_tag == 0 && !flow.end.unwire_needed
	if !done && now_ms < flow.end.deadline_ms {
		return false, false
	}
	flow_to_idle(flow)
	return true, !done
}

// flow_due says if the grant reached its end time.
flow_due :: proc "contextless" (flow: ^Flow, now_ms: u64) -> bool {
	return (flow.stage == .Active || flow.stage == .Wiring) && now_ms >= flow.ends_at_ms
}
