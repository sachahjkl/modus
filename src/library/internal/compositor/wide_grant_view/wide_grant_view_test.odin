#+build !freestanding
package wide_grant_view

import "core:testing"
import "modus:contract/wide_grants"

@(private = "file")
SHOW :: wide_grants.Screen_Show{flow_serial = 4, principal_id = 1, authorities = {.View_Screen, .Send_Input}, duration_ms = wide_grants.SCREEN_DURATION_UNTIL_LOCK, client_key_head = 0xAB}

@(private = "file")
mark_taken :: proc(display: ^Display, screen: ^Screen, values: [7]u64) -> bool {
	_, ok := display_mark_take(display, screen, values)
	return ok
}

@(private = "file")
mark_of :: proc(flow_serial: u64, authorities: wide_grants.Wide_Authorities) -> [7]u64 {
	return wide_grants.mark_values({grant_serial = 9, principal_id = 1, authorities = authorities, ends_at_ms = 5000, flow_serial = flow_serial})
}

// The lines of the screen: a scope that the ask did not propose does not
// change, Send_Input takes View_Screen with it and leaves with it, a line
// past the last changes nothing, and a give with no window or no scope is
// not sendable. The front window is chosen; "until the lock" gives the
// duration of the ask, else one hour at most.
@(test)
the_lines_of_the_screen_keep_their_rules :: proc(t: ^testing.T) {
	screen: Screen
	view_only := SHOW
	view_only.authorities = {.View_Screen}
	view_only.duration_ms = 1000
	screen_open(&screen, view_only, {7, 0, 8})
	testing.expect_value(t, screen.window_count, 2)
	testing.expect(t, screen_line_on(&screen, LINE_FIRST_WINDOW))
	testing.expect(t, !screen_line_on(&screen, LINE_FIRST_WINDOW + 1))
	screen_toggle(&screen, int(Line_Kind.Send_Input))
	testing.expect_value(t, screen.chosen, wide_grants.Wide_Authorities{.View_Screen})
	screen_toggle(&screen, int(Line_Kind.Until_Lock))
	testing.expect(t, !screen.until_lock)
	screen_toggle(&screen, -1)
	screen_toggle(&screen, screen_line_count(&screen))
	answer, sendable := screen_answer(&screen, true)
	testing.expect(t, sendable)
	testing.expect_value(t, answer.duration_ms, u64(1000))
	testing.expect_value(t, answer.window_count, u32(1))
	testing.expect_value(t, answer.window_ids[0], u64(7))
	screen_toggle(&screen, LINE_FIRST_WINDOW)
	_, sendable = screen_answer(&screen, true)
	testing.expect(t, !sendable)
	screen_toggle(&screen, LINE_FIRST_WINDOW)
	screen_toggle(&screen, int(Line_Kind.View_Screen))
	_, sendable = screen_answer(&screen, true)
	testing.expect(t, !sendable)
	refusal, refusal_sendable := screen_answer(&screen, false)
	testing.expect(t, refusal_sendable && refusal.decision == .Refuse)

	screen_open(&screen, SHOW, {3, 4, 5, 6, 7})
	testing.expect_value(t, screen.window_count, wide_grants.SCREEN_WINDOWS_MOST)
	screen_toggle(&screen, int(Line_Kind.View_Screen))
	testing.expect_value(t, screen.chosen, wide_grants.Wide_Authorities{})
	screen_toggle(&screen, int(Line_Kind.Send_Input))
	testing.expect_value(t, screen.chosen, wide_grants.Wide_Authorities{.View_Screen, .Send_Input})
	answer, _ = screen_answer(&screen, true)
	testing.expect_value(t, answer.duration_ms, wide_grants.SCREEN_DURATION_ONE_HOUR)
	screen_toggle(&screen, int(Line_Kind.Until_Lock))
	answer, _ = screen_answer(&screen, true)
	testing.expect_value(t, answer.duration_ms, wide_grants.SCREEN_DURATION_UNTIL_LOCK)
	screen_focus_move(&screen, -1)
	testing.expect_value(t, screen.focus, screen_line_count(&screen) - 1)
	screen_focus_move(&screen, 1)
	testing.expect_value(t, screen.focus, 0)
}

// A window that closes while the screen shows leaves its lines, and no
// answer names it; a window of the bound that closes leaves the bound, so
// a new window, with a new id, gets no key of the viewer, even at the same
// place of the desktop.
@(test)
a_closed_window_leaves_the_screen_and_the_bound :: proc(t: ^testing.T) {
	screen: Screen
	display: Display
	screen_open(&screen, SHOW, {11, 12})
	screen_toggle(&screen, LINE_FIRST_WINDOW + 1)
	screen.focus = screen_line_count(&screen) - 1
	display_window_closed(&display, &screen, 11)
	testing.expect_value(t, screen.window_count, 1)
	testing.expect_value(t, screen.window_ids[0], u64(12))
	testing.expect_value(t, screen.focus, screen_line_count(&screen) - 1)
	answer, sendable := screen_answer(&screen, true)
	testing.expect(t, sendable)
	testing.expect_value(t, answer.window_count, u32(1))
	testing.expect_value(t, answer.window_ids[0], u64(12))
	display_answer_given(&display, answer)
	testing.expect(t, mark_taken(&display, &screen, mark_of(SHOW.flow_serial, {.View_Screen, .Send_Input})))
	testing.expect_value(t, viewer_input_verdict(&display, .Window, 12), Verdict.Allowed)
	display_window_closed(&display, &screen, 12)
	// A console opens: the compositor gives it the next id, 13.
	testing.expect_value(t, viewer_input_verdict(&display, .Window, 13), Verdict.Dropped_Counted)
	testing.expect_value(t, viewer_input_verdict(&display, .Window, 12), Verdict.Dropped_Counted)
	testing.expect_value(t, display.dropped_input, u64(2))
}

// The rule of the input of a viewer: a trusted surface takes none, with or
// without a grant. With no grant, the input goes as it went. Under a grant:
// no input without Send_Input, none to the bar, the desktop or an overlay
// over a window of the bound, none to another window; a mark of another
// screen bounds it to no window; a clear ends the grant and the screen.
@(test)
the_input_of_a_viewer_stays_in_the_bound :: proc(t: ^testing.T) {
	screen: Screen
	display: Display
	testing.expect_value(t, viewer_input_verdict(&display, .Trusted, 0), Verdict.Dropped)
	testing.expect_value(t, viewer_input_verdict(&display, .Bar, 0), Verdict.Allowed)
	screen_open(&screen, SHOW, {21})
	answer, _ := screen_answer(&screen, true)
	display_answer_given(&display, answer)

	testing.expect(t, mark_taken(&display, &screen, mark_of(SHOW.flow_serial, {.View_Screen})))
	testing.expect_value(t, viewer_input_verdict(&display, .Window, 21), Verdict.Dropped_Counted)

	testing.expect(t, mark_taken(&display, &screen, mark_of(SHOW.flow_serial, {.View_Screen, .Send_Input})))
	for surface in ([?]Surface{.Overlay, .Bar, .Desktop}) {
		testing.expect_value(t, viewer_input_verdict(&display, surface, 21), Verdict.Dropped_Counted)
	}
	testing.expect_value(t, viewer_input_verdict(&display, .Trusted, 21), Verdict.Dropped)
	testing.expect_value(t, viewer_input_verdict(&display, .Window, 22), Verdict.Dropped_Counted)
	testing.expect_value(t, viewer_input_verdict(&display, .Window, 0), Verdict.Dropped_Counted)
	testing.expect_value(t, viewer_input_verdict(&display, .Window, 21), Verdict.Allowed)

	testing.expect(t, mark_taken(&display, &screen, mark_of(SHOW.flow_serial + 1, {.View_Screen, .Send_Input})))
	testing.expect_value(t, viewer_input_verdict(&display, .Window, 21), Verdict.Dropped_Counted)

	testing.expect(t, !mark_taken(&display, &screen, {0, 1, 0, 0, 0, 0, 0}))
	testing.expect(t, display.active)
	screen.open = true
	testing.expect(t, mark_taken(&display, &screen, {}))
	testing.expect(t, !display.active && !screen.open)
	testing.expect_value(t, viewer_input_verdict(&display, .Window, 21), Verdict.Allowed)
}

// A grant starts once: its first mark says so, and a view that is open gets
// its record then; the same mark again keeps the counts of the window and
// starts nothing; a mark of another grant starts again; a clear starts
// nothing.
@(test)
a_grant_starts_once_for_its_open_views :: proc(t: ^testing.T) {
	screen: Screen
	display: Display
	started, ok := display_mark_take(&display, &screen, mark_of(4, {.View_Screen}))
	testing.expect(t, ok && started)
	display.target = {window = 3, keys = 5}
	started, ok = display_mark_take(&display, &screen, mark_of(4, {.View_Screen}))
	testing.expect(t, ok && !started)
	testing.expect_value(t, display.target.keys, u64(5))
	other := wide_grants.mark_values({grant_serial = 10, principal_id = 1, authorities = {.View_Screen}, ends_at_ms = 5000, flow_serial = 4})
	started, ok = display_mark_take(&display, &screen, other)
	testing.expect(t, ok && started)
	testing.expect_value(t, display.target.keys, u64(0))
	started, ok = display_mark_take(&display, &screen, {})
	testing.expect(t, ok && !started)
}
