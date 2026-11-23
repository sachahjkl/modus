// The screen and the mark of a wide grant on the trusted display, and the
// rule of the input of a viewer under a grant (src/md/features/wide_grants.md,
// "The screen", "The mark" and "The path of a grant, end to end"). A pure
// part of the compositor: no call of the kernel, no drawing. The compositor
// gives each window an id that it never gives again in one run, and asks
// this part what each line, each key and each press does.
package wide_grant_view

import "modus:contract/wide_grants"

// The lines of the screen, in order: the two scopes, the duration, then
// one line for each window offered.
Line_Kind :: enum u8 {
	View_Screen = 0,
	Send_Input  = 1,
	Until_Lock  = 2,
	Window      = 3,
}
LINE_FIRST_WINDOW :: int(Line_Kind.Window)

Screen :: struct {
	open:          bool,
	show:          wide_grants.Screen_Show,
	chosen:        wide_grants.Wide_Authorities,
	until_lock:    bool,
	window_count:  int,
	window_ids:    [wide_grants.SCREEN_WINDOWS_MOST]u64,
	window_chosen: [wide_grants.SCREEN_WINDOWS_MOST]bool,
	focus:         int,
}

// screen_open opens the screen of show with the windows that the display
// offers, top first: the ids of the windows that show, none marked local.
// The window in front is chosen; an id of 0 is no window.
screen_open :: proc "contextless" (screen: ^Screen, show: wide_grants.Screen_Show, windows: []u64) {
	screen^ = {open = true, show = show, chosen = show.authorities}
	for id in windows {
		if id == 0 || screen.window_count >= wide_grants.SCREEN_WINDOWS_MOST {
			continue
		}
		screen.window_ids[screen.window_count] = id
		screen.window_chosen[screen.window_count] = screen.window_count == 0
		screen.window_count += 1
	}
}

screen_line_count :: proc "contextless" (screen: ^Screen) -> int {
	return LINE_FIRST_WINDOW + screen.window_count
}

screen_line_kind :: proc "contextless" (line: int) -> Line_Kind {
	if line >= LINE_FIRST_WINDOW {
		return .Window
	}
	return Line_Kind(line)
}

// screen_line_offered says if a line can change: a scope that the ask did
// not propose, and "until the lock" for an ask of one hour or less, cannot.
screen_line_offered :: proc "contextless" (screen: ^Screen, line: int) -> bool {
	switch screen_line_kind(line) {
	case .View_Screen:
		return .View_Screen in screen.show.authorities
	case .Send_Input:
		return .Send_Input in screen.show.authorities
	case .Until_Lock:
		return screen.show.duration_ms > wide_grants.SCREEN_DURATION_ONE_HOUR
	case .Window:
		return line - LINE_FIRST_WINDOW < screen.window_count
	}
	return false
}

// screen_line_on says if a line is ticked.
screen_line_on :: proc "contextless" (screen: ^Screen, line: int) -> bool {
	switch screen_line_kind(line) {
	case .View_Screen:
		return .View_Screen in screen.chosen
	case .Send_Input:
		return .Send_Input in screen.chosen
	case .Until_Lock:
		return screen.until_lock
	case .Window:
		index := line - LINE_FIRST_WINDOW
		return index < screen.window_count && screen.window_chosen[index]
	}
	return false
}

// screen_toggle changes the tick of a line that can change. Send_Input
// needs View_Screen, so the one leaves with the other.
screen_toggle :: proc "contextless" (screen: ^Screen, line: int) {
	if !screen.open || line < 0 || line >= screen_line_count(screen) || !screen_line_offered(screen, line) {
		return
	}
	switch screen_line_kind(line) {
	case .View_Screen:
		if .View_Screen in screen.chosen {
			screen.chosen -= {.View_Screen, .Send_Input}
		} else {
			screen.chosen += {.View_Screen}
		}
	case .Send_Input:
		if .Send_Input in screen.chosen {
			screen.chosen -= {.Send_Input}
		} else {
			screen.chosen += {.View_Screen, .Send_Input}
		}
	case .Until_Lock:
		screen.until_lock = !screen.until_lock
	case .Window:
		index := line - LINE_FIRST_WINDOW
		screen.window_chosen[index] = !screen.window_chosen[index]
	}
}

// screen_focus_move moves the focus one line down (step 1) or up (-1),
// around the end.
screen_focus_move :: proc "contextless" (screen: ^Screen, step: int) {
	count := screen_line_count(screen)
	screen.focus = ((screen.focus + step) % count + count) % count
}

// screen_answer gives the answer of the principal. A give with no scope or
// no window is not sendable: the screen stays.
screen_answer :: proc "contextless" (screen: ^Screen, give: bool) -> (answer: wide_grants.Screen_Answer, sendable: bool) {
	answer = {flow_serial = screen.show.flow_serial, decision = .Refuse}
	if !screen.open {
		return answer, false
	}
	if !give {
		return answer, true
	}
	answer.decision = .Give
	answer.authorities = screen.chosen
	answer.duration_ms = screen.until_lock ? screen.show.duration_ms : min(screen.show.duration_ms, wide_grants.SCREEN_DURATION_ONE_HOUR)
	for index in 0 ..< screen.window_count {
		if screen.window_chosen[index] {
			answer.window_ids[answer.window_count] = screen.window_ids[index]
			answer.window_count += 1
		}
	}
	return answer, answer.authorities != {} && answer.window_count > 0
}

// screen_window_closed removes a window that closed from the lines of the
// screen: no answer names a window that is gone.
screen_window_closed :: proc "contextless" (screen: ^Screen, id: u64) {
	kept := 0
	for index in 0 ..< screen.window_count {
		if screen.window_ids[index] == id {
			continue
		}
		screen.window_ids[kept] = screen.window_ids[index]
		screen.window_chosen[kept] = screen.window_chosen[index]
		kept += 1
	}
	for index in kept ..< wide_grants.SCREEN_WINDOWS_MOST {
		screen.window_ids[index] = 0
		screen.window_chosen[index] = false
	}
	screen.window_count = kept
	screen.focus = min(screen.focus, screen_line_count(screen) - 1)
}

// The mark of the grant that holds, and the windows that bound the input
// of a viewer.
Display :: struct {
	active:        bool,
	mark:          wide_grants.Mark,
	given:         wide_grants.Screen_Answer, // The last answer of Give that left.
	bound:         wide_grants.Screen_Answer,
	card_open:     bool,
	acts_recorded: u64,
	dropped_acts:  u64,
	dropped_input: u64,
	target:        wide_grants.Input_Target,
}

// display_answer_given keeps the last Give that left: a mark of the same
// screen takes its windows as its bound.
display_answer_given :: proc "contextless" (display: ^Display, answer: wide_grants.Screen_Answer) {
	if answer.decision == .Give {
		display.given = answer
	}
}

// display_mark_take takes a mark of the root service, its one writer. A
// clear ends the mark, its card and a screen that still shows. A mark of
// another screen than the last answer bounds the input to no window.
display_mark_take :: proc "contextless" (display: ^Display, screen: ^Screen, values: [7]u64) -> bool {
	mark, ok := wide_grants.mark_of_values(values)
	if !ok {
		return false
	}
	if mark.grant_serial == 0 {
		display^ = {}
		screen^ = {}
		return true
	}
	bound := display.given
	if bound.flow_serial != mark.flow_serial {
		bound = {}
	}
	given := display.given
	display^ = {active = true, mark = mark, bound = bound, given = given}
	return true
}

// display_window_closed takes a window that closed: it leaves the bound
// and the screen.
display_window_closed :: proc "contextless" (display: ^Display, screen: ^Screen, id: u64) {
	if id == 0 {
		return
	}
	wide_grants.window_leaves_bound(&display.bound, id)
	wide_grants.window_leaves_bound(&display.given, id)
	screen_window_closed(screen, id)
	if display.target.window == id {
		display.target = {}
	}
}

// What lies under the pointer of a viewer, or takes its key: the real hit
// test of the desktop, in the order that the compositor gives the input.
Surface :: enum u8 {
	Window  = 0, // A window, and nothing over it.
	Overlay = 1, // The palette, a menu, a card, a list or a move of a window: it takes the input first.
	Bar     = 2,
	Desktop = 3,
	Trusted = 4, // A dialog or a screen of the trusted display, or a window marked local.
}

// What the input of a viewer does.
Verdict :: enum u8 {
	Allowed         = 0, // It goes where the desktop sends it.
	Dropped         = 1, // A trusted surface: no input of a viewer reaches it.
	Dropped_Counted = 2, // A grant holds and the input leaves its bound: counted on the mark.
}

// viewer_input_verdict is the one rule of the input of a viewer. A trusted
// surface takes none. With no grant, the input goes as it went. Under a
// grant, only with Send_Input, only to a window, and only to a window of
// the bound: never to the bar, the desktop, the palette, a menu, a card or
// another window.
viewer_input_verdict :: proc "contextless" (display: ^Display, surface: Surface, window_id: u64) -> Verdict {
	if surface == .Trusted {
		return .Dropped
	}
	if !display.active {
		return .Allowed
	}
	switch {
	case .Send_Input not_in display.mark.authorities, surface != .Window, !wide_grants.window_in_bound(&display.bound, window_id):
		display.dropped_input += 1
		return .Dropped_Counted
	}
	return .Allowed
}
