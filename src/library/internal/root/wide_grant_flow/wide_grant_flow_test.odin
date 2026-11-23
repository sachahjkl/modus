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

// Each ask that breaks a rule is refused with the flow still Idle: a zero
// key, scopes that name nothing, Send_Input alone, a duration of 0 or one
// past the bound. Then an ask opens a flow, and a second ask is Busy.
@(test)
an_ask_that_breaks_a_rule_opens_no_flow :: proc(t: ^testing.T) {
	flow: Flow
	view := wide_grants.wide_authorities_to_word({.View_Screen})
	cases := [?]struct {
		key:      [32]u8,
		scopes:   u64,
		duration: u64,
		refusal:  Flow_Refusal,
	} {
		{{}, view, 1000, .Zero_Key},
		{KEY, 0, 1000, .Bad_Scopes},
		{KEY, 1, 1000, .Bad_Scopes},
		{KEY, wide_grants.wide_authorities_to_word({.Send_Input}), 1000, .Bad_Scopes},
		{KEY, view, 0, .Bad_Duration},
		{KEY, view, wide_grants.MAX_WIDE_GRANT_DURATION_MS + 1, .Bad_Duration},
	}
	for case_of in cases {
		_, refusal := flow_ask(&flow, 1, case_of.key, case_of.scopes, case_of.duration, 0)
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
// answer. Then a refusal pauses the key for ten minutes, and three refused
// screens end the asks of the run.
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
	_, wider := flow_screen_answer(&flow, give_values(serial, {.View_Screen, .Send_Input}, 1000, {1}), 0)
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

	for round in u64(0) ..< REFUSED_SCREENS_MOST {
		now := round * (REFUSED_SCREEN_PAUSE_MILLISECONDS + 1)
		serial, _ = flow_ask(&flow, 1, KEY, view, 1000, now)
		decision, refusal := flow_screen_answer(&flow, {serial, u64(wide_grants.Screen_Decision.Refuse), 0, 0, 0, 0, 0}, now)
		testing.expect_value(t, refusal, Flow_Refusal.None)
		testing.expect_value(t, decision, wide_grants.Screen_Decision.Refuse)
		if round == 0 {
			_, paused := flow_ask(&flow, 1, KEY, view, 1000, now + REFUSED_SCREEN_PAUSE_MILLISECONDS - 1)
			testing.expect_value(t, paused, Flow_Refusal.Paused)
		}
	}
	_, ended := flow_ask(&flow, 1, OTHER_KEY, view, 1000, max(u64) / 2)
	testing.expect_value(t, ended, Flow_Refusal.Refused_For_Run)
}

// The proof and the grant: a proof in another stage, a proof of another
// principal (no grant, the flow ends), a cancelled proof (a pause), a grant
// serial of 0. Then the whole path: the terms seal with the windows of the
// answer, the grant, two rings wired, the end time, an end of another key,
// and the end of the key.
@(test)
a_proof_of_another_principal_gives_no_grant :: proc(t: ^testing.T) {
	flow: Flow
	scopes := wide_grants.wide_authorities_to_word({.View_Screen, .Send_Input})
	testing.expect_value(t, flow_proved(&flow, 1, true, 0), Flow_Refusal.Not_Awaited)

	serial, _ := flow_ask(&flow, 1, KEY, scopes, 5000, 0)
	_, _ = flow_screen_answer(&flow, give_values(serial, {.View_Screen, .Send_Input}, 4000, {3, 9}), 0)
	testing.expect_value(t, flow.stage, Stage.Proving)
	testing.expect_value(t, flow_proved(&flow, 0, true, 0), Flow_Refusal.Other_Principal)
	testing.expect_value(t, flow.stage, Stage.Idle)
	testing.expect_value(t, flow_created(&flow, 1), Flow_Refusal.Not_Awaited)

	serial, _ = flow_ask(&flow, 1, KEY, scopes, 5000, 0)
	_, _ = flow_screen_answer(&flow, give_values(serial, {.View_Screen}, 4000, {3}), 0)
	testing.expect_value(t, flow_proved(&flow, 1, false, 10), Flow_Refusal.None)
	testing.expect_value(t, flow.stage, Stage.Idle)
	testing.expect_value(t, flow.refused_screens, u32(1))

	serial, _ = flow_ask(&flow, 1, OTHER_KEY, scopes, 5000, 20)
	_, _ = flow_screen_answer(&flow, give_values(serial, {.View_Screen, .Send_Input}, 4000, {3, 9}), 20)
	testing.expect_value(t, wide_grants.wide_grant_terms_validate(&flow.terms), wide_grants.Wide_Grant_Refusal.None)
	testing.expect(t, wide_grants.wide_grant_terms_contains_window(&flow.terms, 9))
	testing.expect(t, !wide_grants.wide_grant_terms_contains_window(&flow.terms, 4))
	testing.expect_value(t, flow_proved(&flow, 1, true, 30), Flow_Refusal.None)
	testing.expect_value(t, flow_created(&flow, 0), Flow_Refusal.No_Grant)
	testing.expect_value(t, flow.stage, Stage.Idle)

	serial, _ = flow_ask(&flow, 1, OTHER_KEY, scopes, 5000, 40)
	_, _ = flow_screen_answer(&flow, give_values(serial, {.View_Screen, .Send_Input}, 4000, {3, 9}), 40)
	_ = flow_proved(&flow, 1, true, 50)
	testing.expect_value(t, flow_created(&flow, 6), Flow_Refusal.None)
	active, _ := flow_wired(&flow, 2, 60)
	testing.expect(t, !active)
	active, _ = flow_wired(&flow, 2, 70)
	testing.expect(t, active)
	testing.expect_value(t, flow.ends_at_ms, u64(4070))
	testing.expect(t, !flow_due(&flow, 4069))
	testing.expect(t, flow_due(&flow, 4070))
	testing.expect_value(t, flow_end_key(&flow, KEY), Flow_Refusal.Other_Key)
	testing.expect_value(t, flow_end_key(&flow, OTHER_KEY), Flow_Refusal.None)
	flow_to_idle(&flow)
	testing.expect_value(t, flow_end_key(&flow, OTHER_KEY), Flow_Refusal.Not_Awaited)
}
