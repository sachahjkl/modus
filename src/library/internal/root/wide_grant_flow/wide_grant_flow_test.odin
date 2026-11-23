#+build !freestanding
package wide_grant_flow

import "core:testing"
import "modus:contract/wide_grants"

@(private = "file")
KEY :: [32]u8{0 = 7, 31 = 9}
@(private = "file")
OTHER_KEY :: [32]u8{0 = 8}

@(private = "file")
give_values :: proc(serial: u64, authorities: wide_grants.Wide_Authorities, duration: u64, windows: []u64) -> [7]u64 {
	answer := wide_grants.Screen_Answer{flow_serial = serial, decision = .Give, authorities = authorities, duration_ms = duration, window_count = u32(len(windows))}
	for id, index in windows {
		answer.window_ids[index] = id
	}
	return wide_grants.screen_answer_values(answer)
}

@(private = "file")
refuse_values :: proc(serial: u64) -> [7]u64 {
	return {serial, u64(wide_grants.Screen_Decision.Refuse), 0, 0, 0, 0, 0}
}

@(private = "file")
VIEW_AND_INPUT :: wide_grants.Wide_Authorities{.View_Screen, .Send_Input}

// active_flow drives a flow to Active for KEY, with one ring of acts.
@(private = "file")
active_flow :: proc(t: ^testing.T, flow: ^Flow, now: u64) {
	serial, refusal := flow_ask(flow, 1, KEY, wide_grants.wide_authorities_to_word(VIEW_AND_INPUT), 5000, now)
	testing.expect_value(t, refusal, Flow_Refusal.None)
	_, _ = flow_screen_answer(flow, give_values(serial, VIEW_AND_INPUT, 4000, {3, 9}), now)
	testing.expect_value(t, flow_proved(flow, 1, true, now), Flow_Refusal.None)
	testing.expect_value(t, flow_create_sent(flow, 11), Flow_Refusal.None)
	testing.expect_value(t, flow_created(flow, 11, 6), Flow_Refusal.None)
	active, _ := flow_wired(flow, serial, 1)
	testing.expect(t, active)
}

// Each ask that breaks a rule is refused with the flow still Idle: a zero
// key, a principal past the table, scopes that name nothing, a scope that
// the screen does not draw, Send_Input alone, a duration of 0 or one past
// the bound. Then an ask opens a flow, and a second ask is Busy.
@(test)
an_ask_that_breaks_a_rule_opens_no_flow :: proc(t: ^testing.T) {
	flow: Flow
	view := wide_grants.wide_authorities_to_word({.View_Screen})
	cases := [?]struct {
		principal: u64,
		key:       [32]u8,
		scopes:    u64,
		duration:  u64,
		refusal:   Flow_Refusal,
	} {
		{1, {}, view, 1000, .Zero_Key},
		{PRINCIPALS_MOST, KEY, view, 1000, .Other_Principal},
		{max(u64), KEY, view, 1000, .Other_Principal},
		{1, KEY, 0, 1000, .Bad_Scopes},
		{1, KEY, 1, 1000, .Bad_Scopes},
		{1, KEY, wide_grants.wide_authorities_to_word({.Send_Input}), 1000, .Bad_Scopes},
		{1, KEY, wide_grants.wide_authorities_to_word({.View_Screen, .Read_Semantic_Tree}), 1000, .Bad_Scopes},
		{1, KEY, view, 0, .Bad_Duration},
		{1, KEY, view, wide_grants.MAX_WIDE_GRANT_DURATION_MS + 1, .Bad_Duration},
	}
	for case_of in cases {
		_, refusal := flow_ask(&flow, case_of.principal, case_of.key, case_of.scopes, case_of.duration, 0)
		testing.expect_value(t, refusal, case_of.refusal)
		testing.expect_value(t, flow.stage, Stage.Idle)
	}
	serial, refusal := flow_ask(&flow, 1, KEY, view, wide_grants.MAX_WIDE_GRANT_DURATION_MS, 0)
	testing.expect_value(t, refusal, Flow_Refusal.None)
	testing.expect_value(t, serial, u64(1))
	_, busy := flow_ask(&flow, 1, OTHER_KEY, view, 1000, 0)
	testing.expect_value(t, busy, Flow_Refusal.Busy)
	testing.expect_value(t, flow.client_key, KEY)
}

// The answer of a screen: a word in another stage, an answer of another
// flow, a scope that the ask did not propose, a longer duration, a broken
// answer. Then the pauses: a refused key pauses for ten minutes and a
// second key refused during that pause pauses too, each on its own; three
// refusals bar a key for the run, and another key still asks.
@(test)
an_answer_that_breaks_a_rule_gives_no_terms :: proc(t: ^testing.T) {
	flow: Flow
	view := wide_grants.wide_authorities_to_word({.View_Screen})
	_, not_awaited := flow_screen_answer(&flow, give_values(1, {.View_Screen}, 1000, {1}), 0)
	testing.expect_value(t, not_awaited, Flow_Refusal.Not_Awaited)

	serial, _ := flow_ask(&flow, 1, KEY, view, 1000, 0)
	_, other := flow_screen_answer(&flow, give_values(serial + 1, {.View_Screen}, 1000, {1}), 0)
	testing.expect_value(t, other, Flow_Refusal.Other_Flow)
	testing.expect_value(t, flow.stage, Stage.Screen_Shown)
	_, wider := flow_screen_answer(&flow, give_values(serial, VIEW_AND_INPUT, 1000, {1}), 0)
	testing.expect_value(t, wider, Flow_Refusal.Scope_Not_Proposed)
	testing.expect_value(t, flow.stage, Stage.Idle)

	serial, _ = flow_ask(&flow, 1, KEY, view, 1000, 0)
	_, longer := flow_screen_answer(&flow, give_values(serial, {.View_Screen}, 1001, {1}), 0)
	testing.expect_value(t, longer, Flow_Refusal.Duration_Past_Ask)

	serial, _ = flow_ask(&flow, 1, KEY, view, 1000, 0)
	broken := give_values(serial, {.View_Screen}, 1000, {1})
	broken[4] = 0
	_, bad := flow_screen_answer(&flow, broken, 0)
	testing.expect_value(t, bad, Flow_Refusal.Bad_Answer)
	testing.expect_value(t, flow.stage, Stage.Idle)

	// The first key is refused at 0; the second during its pause, at 100.
	serial, _ = flow_ask(&flow, 1, KEY, view, 1000, 0)
	decision, refusal := flow_screen_answer(&flow, refuse_values(serial), 0)
	testing.expect_value(t, refusal, Flow_Refusal.None)
	testing.expect_value(t, decision, wide_grants.Screen_Decision.Refuse)
	serial, refusal = flow_ask(&flow, 1, OTHER_KEY, view, 1000, 100)
	testing.expect_value(t, refusal, Flow_Refusal.None)
	_, _ = flow_screen_answer(&flow, refuse_values(serial), 100)
	_, paused := flow_ask(&flow, 1, KEY, view, 1000, REFUSED_SCREEN_PAUSE_MILLISECONDS - 1)
	testing.expect_value(t, paused, Flow_Refusal.Paused)
	_, paused = flow_ask(&flow, 1, OTHER_KEY, view, 1000, REFUSED_SCREEN_PAUSE_MILLISECONDS + 99)
	testing.expect_value(t, paused, Flow_Refusal.Paused)
	// The pause of the first key ended; the second still waits.
	serial, refusal = flow_ask(&flow, 1, KEY, view, 1000, REFUSED_SCREEN_PAUSE_MILLISECONDS)
	testing.expect_value(t, refusal, Flow_Refusal.None)
	_, _ = flow_screen_answer(&flow, refuse_values(serial), REFUSED_SCREEN_PAUSE_MILLISECONDS)
	later := 3 * REFUSED_SCREEN_PAUSE_MILLISECONDS
	serial, _ = flow_ask(&flow, 1, KEY, view, 1000, later)
	_, _ = flow_screen_answer(&flow, refuse_values(serial), later)
	_, barred := flow_ask(&flow, 1, KEY, view, 1000, max(u64) / 2)
	testing.expect_value(t, barred, Flow_Refusal.Refused_For_Run)
	// The count is of the key, not of the machine.
	_, refusal = flow_ask(&flow, 1, OTHER_KEY, view, 1000, max(u64) / 2)
	testing.expect_value(t, refusal, Flow_Refusal.None)
}

// The keys table holds KEY_RECORDS_MOST keys. A key past them takes the
// place of the key whose pause ended first, never of a key barred for the
// run; with every place barred, the refusals of new keys count together in
// one shared record: they pause, then each new key is barred for the run.
@(test)
the_table_of_keys_keeps_its_bound :: proc(t: ^testing.T) {
	flow: Flow
	view := wide_grants.wide_authorities_to_word({.View_Screen})
	key_of :: proc(number: int) -> (key: [32]u8) {
		key[0] = u8(number + 1)
		key[1] = 0xEE
		return key
	}
	for number in 0 ..< KEY_RECORDS_MOST {
		serial, _ := flow_ask(&flow, 1, key_of(number), view, 1000, u64(number))
		_, _ = flow_screen_answer(&flow, refuse_values(serial), u64(number))
	}
	// One more key takes the place of key 0, whose pause ends first.
	serial, refusal := flow_ask(&flow, 1, key_of(KEY_RECORDS_MOST), view, 1000, 50)
	testing.expect_value(t, refusal, Flow_Refusal.None)
	_, _ = flow_screen_answer(&flow, refuse_values(serial), 50)
	_, refusal = flow_ask(&flow, 1, key_of(0), view, 1000, 60)
	testing.expect_value(t, refusal, Flow_Refusal.None)
	flow_to_idle(&flow)
	_, refusal = flow_ask(&flow, 1, key_of(1), view, 1000, 60)
	testing.expect_value(t, refusal, Flow_Refusal.Paused)

	// Each place barred for the run.
	barred: Flow
	for number in 0 ..< KEY_RECORDS_MOST {
		for _ in 0 ..< REFUSED_SCREENS_MOST {
			serial, _ = flow_ask(&barred, 1, key_of(number), view, 1000, max(u64) / 4)
			_, _ = flow_screen_answer(&barred, refuse_values(serial), 0)
		}
	}
	now := max(u64) / 2
	for refused in 0 ..< REFUSED_SCREENS_MOST {
		new_key := key_of(100 + refused)
		serial, refusal = flow_ask(&barred, 1, new_key, view, 1000, now)
		testing.expect_value(t, refusal, Flow_Refusal.None)
		_, _ = flow_screen_answer(&barred, refuse_values(serial), now)
		testing.expect_value(t, barred.unplaced.refused, u32(refused + 1))
		// Another new key shares the pause.
		_, refusal = flow_ask(&barred, 1, key_of(200 + refused), view, 1000, now + 1)
		testing.expect_value(t, refusal, refused + 1 >= REFUSED_SCREENS_MOST ? Flow_Refusal.Refused_For_Run : Flow_Refusal.Paused)
		now += REFUSED_SCREEN_PAUSE_MILLISECONDS
	}
	_, refusal = flow_ask(&barred, 1, key_of(300), view, 1000, now)
	testing.expect_value(t, refusal, Flow_Refusal.Refused_For_Run)
	testing.expect_value(t, barred.keys[0].key, key_of(0))
}

// The proof: a proof in another stage, a proof of another principal (no
// grant, the flow ends), proofs not given counted for the principal until
// it unlocks, and the one end time fixed when the proof is given.
@(test)
a_proof_of_another_principal_gives_no_grant :: proc(t: ^testing.T) {
	flow: Flow
	scopes := wide_grants.wide_authorities_to_word(VIEW_AND_INPUT)
	testing.expect_value(t, flow_proved(&flow, 1, true, 0), Flow_Refusal.Not_Awaited)

	serial, _ := flow_ask(&flow, 1, KEY, scopes, 5000, 0)
	_, _ = flow_screen_answer(&flow, give_values(serial, VIEW_AND_INPUT, 4000, {3, 9}), 0)
	testing.expect_value(t, flow.stage, Stage.Proving)
	testing.expect_value(t, flow_proved(&flow, 0, true, 0), Flow_Refusal.Other_Principal)
	testing.expect_value(t, flow.stage, Stage.Idle)

	for _ in 0 ..< PROOF_FAILURES_MOST {
		serial, _ = flow_ask(&flow, 1, KEY, scopes, 5000, 0)
		_, _ = flow_screen_answer(&flow, give_values(serial, {.View_Screen}, 4000, {3}), 0)
		testing.expect_value(t, flow_proved(&flow, 1, false, 10), Flow_Refusal.None)
		testing.expect_value(t, flow.stage, Stage.Idle)
	}
	_, refusal := flow_ask(&flow, 1, OTHER_KEY, scopes, 5000, 20)
	testing.expect_value(t, refusal, Flow_Refusal.Proofs_Refused)
	_, refusal = flow_ask(&flow, 2, OTHER_KEY, scopes, 5000, 20)
	testing.expect_value(t, refusal, Flow_Refusal.None)
	flow_to_idle(&flow)
	flow_principal_unlocked(&flow, 1)
	flow_principal_unlocked(&flow, max(u64))

	serial, refusal = flow_ask(&flow, 1, OTHER_KEY, scopes, 5000, 20)
	testing.expect_value(t, refusal, Flow_Refusal.None)
	_, _ = flow_screen_answer(&flow, give_values(serial, VIEW_AND_INPUT, 4000, {3, 9}), 20)
	testing.expect_value(t, wide_grants.wide_grant_terms_validate(&flow.terms), wide_grants.Wide_Grant_Refusal.None)
	testing.expect(t, wide_grants.wide_grant_terms_contains_window(&flow.terms, 9))
	testing.expect(t, !wide_grants.wide_grant_terms_contains_window(&flow.terms, 4))
	testing.expect_value(t, flow_proved(&flow, 1, true, 30), Flow_Refusal.None)
	testing.expect_value(t, flow.ends_at_ms, u64(4030))
	testing.expect_value(t, flow_created(&flow, 5, 6), Flow_Refusal.Not_Awaited)
	testing.expect_value(t, flow_create_sent(&flow, 0), Flow_Refusal.Not_Awaited)
	testing.expect_value(t, flow_create_sent(&flow, 5), Flow_Refusal.None)
	testing.expect_value(t, flow_create_sent(&flow, 6), Flow_Refusal.Not_Awaited)
	testing.expect_value(t, flow_created(&flow, 6, 6), Flow_Refusal.Other_Tag)
	testing.expect_value(t, flow_created(&flow, 0, 6), Flow_Refusal.Other_Tag)
	testing.expect_value(t, flow_created(&flow, 5, 0), Flow_Refusal.No_Grant)
	testing.expect_value(t, flow.stage, Stage.Idle)
}

// The wiring and the end time: an answer of the wiring of another flow does
// not count; the end time stays the one of the proof, whatever the time of
// the last wiring.
@(test)
a_stale_wiring_answer_counts_for_no_flow :: proc(t: ^testing.T) {
	flow: Flow
	serial, _ := flow_ask(&flow, 1, KEY, wide_grants.wide_authorities_to_word(VIEW_AND_INPUT), 5000, 0)
	_, _ = flow_screen_answer(&flow, give_values(serial, VIEW_AND_INPUT, 4000, {3}), 0)
	_ = flow_proved(&flow, 1, true, 100)
	_ = flow_create_sent(&flow, 1)
	_ = flow_created(&flow, 1, 6)
	_, refusal := flow_wired(&flow, serial - 1, 2)
	testing.expect_value(t, refusal, Flow_Refusal.Other_Flow)
	_, refusal = flow_wired(&flow, serial, 0)
	testing.expect_value(t, refusal, Flow_Refusal.Not_Awaited)
	active, _ := flow_wired(&flow, serial, 2)
	testing.expect(t, !active)
	testing.expect(t, !flow_due(&flow, 4099))
	testing.expect(t, flow_due(&flow, 4100))
	active, _ = flow_wired(&flow, serial, 2)
	testing.expect(t, active)
	testing.expect_value(t, flow.ends_at_ms, u64(4100))
	testing.expect_value(t, flow_end_key(&flow, OTHER_KEY), Flow_Refusal.Other_Key)
	testing.expect_value(t, flow_end_key(&flow, KEY), Flow_Refusal.None)
}

// An end while the collector creates the grant: the answer that comes
// later names a grant, which the end revokes; a refusal of the collector
// leaves nothing to revoke. A new ask waits for the end.
@(test)
an_end_while_the_grant_is_created_revokes_it_when_it_comes :: proc(t: ^testing.T) {
	flow: Flow
	scopes := wide_grants.wide_authorities_to_word(VIEW_AND_INPUT)
	serial, _ := flow_ask(&flow, 1, KEY, scopes, 5000, 0)
	_, _ = flow_screen_answer(&flow, give_values(serial, VIEW_AND_INPUT, 4000, {3}), 0)
	_ = flow_proved(&flow, 1, true, 0)
	_ = flow_create_sent(&flow, 21)
	testing.expect_value(t, flow_end(&flow, .Session_Locked, false, 10), Flow_Refusal.None)
	testing.expect_value(t, flow.stage, Stage.Ending)
	_, _, due := flow_revoke_due(&flow)
	testing.expect(t, !due)
	_, refusal := flow_ask(&flow, 1, OTHER_KEY, scopes, 5000, 20)
	testing.expect_value(t, refusal, Flow_Refusal.Busy)
	settled, _ := flow_end_settle(&flow, 20)
	testing.expect(t, !settled)
	testing.expect_value(t, flow_created(&flow, 22, 9), Flow_Refusal.Not_Awaited)
	testing.expect_value(t, flow_created(&flow, 21, 9), Flow_Refusal.None)
	grant, reason, revoke_due := flow_revoke_due(&flow)
	testing.expect(t, revoke_due)
	testing.expect_value(t, grant, u64(9))
	testing.expect_value(t, reason, wide_grants.Revocation_Reason.Session_Locked)
	testing.expect_value(t, flow_revoke_sent(&flow, 31), Flow_Refusal.None)
	testing.expect_value(t, flow_revoke_answered(&flow, 30), Flow_Refusal.Other_Tag)
	testing.expect_value(t, flow_revoke_answered(&flow, 31), Flow_Refusal.None)
	late: bool
	settled, late = flow_end_settle(&flow, 30)
	testing.expect(t, settled && !late)
	testing.expect_value(t, flow.stage, Stage.Idle)

	// The collector refuses the grant after the end: nothing to revoke.
	serial, _ = flow_ask(&flow, 1, KEY, scopes, 5000, 40)
	_, _ = flow_screen_answer(&flow, give_values(serial, VIEW_AND_INPUT, 4000, {3}), 40)
	_ = flow_proved(&flow, 1, true, 40)
	_ = flow_create_sent(&flow, 41)
	_ = flow_end(&flow, .Principal_Revoked, false, 50)
	testing.expect_value(t, flow_created(&flow, 41, 0), Flow_Refusal.None)
	_, _, due = flow_revoke_due(&flow)
	testing.expect(t, !due)
	settled, late = flow_end_settle(&flow, 50)
	testing.expect(t, settled && !late)
}

// The end of a grant that holds: a Revoke_Grant that a full ring did not
// take is due again; the end of the wirings that the wiring service
// refused is asked again; nothing settles before both are done, unless the
// bound passes. An end that the collector made itself needs no revoke.
@(test)
the_end_of_a_grant_retries_until_done :: proc(t: ^testing.T) {
	flow: Flow
	active_flow(t, &flow, 0)
	testing.expect_value(t, flow_end(&flow, .Principal_Revoked, false, 100), Flow_Refusal.None)
	testing.expect_value(t, flow_end(&flow, .Principal_Revoked, false, 100), Flow_Refusal.Not_Awaited)
	testing.expect(t, flow.end.row_held_grant)
	grant, _, due := flow_revoke_due(&flow)
	testing.expect(t, due && grant == 6)
	// The ring was full: nothing sent, still due at the next pass.
	_, _, due = flow_revoke_due(&flow)
	testing.expect(t, due)
	testing.expect_value(t, flow_revoke_sent(&flow, 0), Flow_Refusal.Not_Awaited)
	testing.expect_value(t, flow_revoke_sent(&flow, 5), Flow_Refusal.None)
	_, _, due = flow_revoke_due(&flow)
	testing.expect(t, !due)
	// The wirings end only after the collector answered the revocation.
	testing.expect(t, !flow_unwire_due(&flow))
	_ = flow_revoke_answered(&flow, 5)
	testing.expect(t, flow_unwire_due(&flow))
	// An answer before the request is sent is not awaited and changes
	// nothing: the root service marks the request sent first, even when the
	// answer comes at once with no wiring service.
	testing.expect_value(t, flow_unwired(&flow, true), Flow_Refusal.Not_Awaited)
	testing.expect(t, flow_unwire_due(&flow))
	flow_unwire_sent(&flow)
	testing.expect(t, !flow_unwire_due(&flow))
	testing.expect_value(t, flow_unwired(&flow, false), Flow_Refusal.None)
	testing.expect(t, flow_unwire_due(&flow))
	flow_unwire_sent(&flow)
	testing.expect_value(t, flow_unwired(&flow, true), Flow_Refusal.None)
	settled, _ := flow_end_settle(&flow, 200)
	testing.expect(t, settled)

	// The bound: a collector that never answers frees the flow, late.
	active_flow(t, &flow, 300)
	_ = flow_end(&flow, .Time_Bound, false, 400)
	settled, _ = flow_end_settle(&flow, 400 + END_BOUND_MILLISECONDS - 1)
	testing.expect(t, !settled)
	late: bool
	settled, late = flow_end_settle(&flow, 400 + END_BOUND_MILLISECONDS)
	testing.expect(t, settled && late)

	// The collector ended the grant itself: no Revoke_Grant, the wirings end.
	active_flow(t, &flow, 500)
	_ = flow_end(&flow, .Audit_Ring_Closed, true, 600)
	_, _, due = flow_revoke_due(&flow)
	testing.expect(t, !due)
	flow_unwire_sent(&flow)
	_ = flow_unwired(&flow, true)
	settled, late = flow_end_settle(&flow, 600)
	testing.expect(t, settled && !late)

	// The collector stopped during the end: nothing more to wait for.
	active_flow(t, &flow, 650)
	_ = flow_end(&flow, .Session_Locked, false, 660)
	flow_collector_gone(&flow)
	_, _, due = flow_revoke_due(&flow)
	testing.expect(t, !due && !flow_unwire_due(&flow))
	settled, late = flow_end_settle(&flow, 660)
	testing.expect(t, settled && !late)

	// A refused screen ends with nothing to wait for.
	serial, _ := flow_ask(&flow, 1, OTHER_KEY, wide_grants.wide_authorities_to_word({.View_Screen}), 1000, 700)
	_ = serial
	testing.expect_value(t, flow_end(&flow, .Principal_Revoked, false, 700), Flow_Refusal.None)
	testing.expect_value(t, flow.stage, Stage.Idle)
}
