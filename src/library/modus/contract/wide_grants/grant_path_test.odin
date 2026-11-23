#+build !freestanding
package wide_grants

import "core:testing"

// The border of an answer refuses each wrong word first: no flow, a
// decision that names nothing, a refusal with words, scopes that name no
// scope or Send_Input alone, a duration of 0 or one past the bound, a count
// of 0 or one past the most, an id of 0, an id twice, an id past the count.
// A good answer round-trips last.
@(test)
a_screen_answer_that_breaks_a_rule_is_refused :: proc(t: ^testing.T) {
	good := Screen_Answer {
		flow_serial  = 7,
		decision     = .Give,
		authorities  = {.View_Screen, .Send_Input},
		duration_ms  = SCREEN_DURATION_ONE_HOUR,
		window_count = 3,
		window_ids   = {0 = 1, 1 = 5, 2 = 0xFFFF},
	}
	base := screen_answer_values(good)
	change :: proc(values: [7]u64, place: int, word: u64) -> [7]u64 {
		changed := values
		changed[place] = word
		return changed
	}
	cases := [?]struct {
		values:  [7]u64,
		refusal: Screen_Answer_Refusal,
	} {
		{change(base, 0, 0), .No_Flow},
		{change(base, 1, 0), .Bad_Decision},
		{change(base, 1, 3), .Bad_Decision},
		{change(base, 1, max(u64)), .Bad_Decision},
		{{7, u64(Screen_Decision.Refuse), 1, 0, 0, 0, 0}, .Words_After_Refuse},
		{change(base, 2, 0), .Bad_Authorities},
		{change(base, 2, 1), .Bad_Authorities},
		{change(base, 2, wide_authorities_to_word({.Send_Input})), .Bad_Authorities},
		{change(base, 3, 0), .Bad_Duration},
		{change(base, 3, MAX_WIDE_GRANT_DURATION_MS + 1), .Bad_Duration},
		{change(base, 4, 0), .Bad_Window_Count},
		{change(base, 4, SCREEN_WINDOWS_MOST + 1), .Bad_Window_Count},
		{change(base, 5, base[5] & ~u64(0xFFFF)), .Bad_Window},
		{change(base, 5, (base[5] & ~u64(0xFFFF0000)) | (1 << 16)), .Bad_Window},
		{change(base, 6, 9), .Bad_Window},
		{change(base, 4, 2), .Bad_Window},
	}
	for case_of, index in cases {
		_, refusal := screen_answer_of_values(case_of.values)
		testing.expectf(t, refusal == case_of.refusal, "case %d: %v, not %v", index, refusal, case_of.refusal)
	}
	refused, refusal := screen_answer_of_values({7, u64(Screen_Decision.Refuse), 0, 0, 0, 0, 0})
	testing.expect_value(t, refusal, Screen_Answer_Refusal.None)
	testing.expect_value(t, refused.decision, Screen_Decision.Refuse)
	read, read_refusal := screen_answer_of_values(base)
	testing.expect_value(t, read_refusal, Screen_Answer_Refusal.None)
	testing.expect_value(t, read, good)
	testing.expect(t, window_in_bound(&read, 5))
	testing.expect(t, !window_in_bound(&read, 0))
	testing.expect(t, !window_in_bound(&read, 2))
	testing.expect(t, !window_in_bound(&refused, 1))
}

// The border of a screen and of a mark: a flow of 0, a word past the
// record, scopes that name no scope, a duration out of bound, a clear with
// words; then the good records round-trip.
@(test)
a_screen_or_a_mark_that_breaks_a_rule_is_refused :: proc(t: ^testing.T) {
	show := Screen_Show{flow_serial = 3, principal_id = 1, authorities = {.View_Screen}, duration_ms = 1000, client_key_head = 0xAB}
	values := screen_show_values(show)
	bad_shows := [?][7]u64{{0, 1, 2, 1000, 0, 0, 0}, {3, 1, 2, 1000, 0, 1, 0}, {3, 1, 0, 1000, 0, 0, 0}, {3, 1, 4, 1000, 0, 0, 0}, {3, 1, 2, 0, 0, 0, 0}, {3, 1, 2, MAX_WIDE_GRANT_DURATION_MS + 1, 0, 0, 0}}
	for bad in bad_shows {
		_, ok := screen_show_of_values(bad)
		testing.expect(t, !ok, "a wrong screen is taken")
	}
	read, ok := screen_show_of_values(values)
	testing.expect(t, ok && read == show)

	bad_marks := [?][7]u64{{0, 1, 0, 0, 0, 0, 0}, {1, 0, 0, 5, 1, 0, 0}, {1, 0, 2, 0, 1, 0, 0}, {1, 0, 2, 5, 0, 0, 0}, {1, 0, 2, 5, 1, 0, 9}}
	for bad in bad_marks {
		_, mark_ok := mark_of_values(bad)
		testing.expect(t, !mark_ok, "a wrong mark is taken")
	}
	cleared, cleared_ok := mark_of_values({})
	testing.expect(t, cleared_ok && cleared.grant_serial == 0)
	mark := Mark{grant_serial = 4, principal_id = 1, authorities = {.View_Screen, .Send_Input}, ends_at_ms = 99, flow_serial = 3}
	mark_read, mark_ok := mark_of_values(mark_values(mark))
	testing.expect(t, mark_ok && mark_read == mark)
}
