#+build !freestanding
#+build !modus
package principals

import "core:testing"
import "modus:contract/root_ring"

// Each event that has no meaning in a state is refused, and the state
// stays: the refusals first, the paths that pass last.
@(test)
each_session_event_out_of_its_state_is_refused :: proc(t: ^testing.T) {
	Allowed :: struct {
		state: Session_State,
		event: Session_Event,
		next:  Session_State,
	}
	allowed := [?]Allowed {
		{.Absent, .Creation_Begun, .Creating},
		{.Creating, .Creation_Abandoned, .Absent},
		{.Absent, .Record_Given, .Locked},
		{.Creating, .Record_Given, .Locked},
		{.Locked, .Unlocked, .In_Front},
		{.In_Front, .Locked, .Locked},
		{.Locked, .Removal_Begun, .Removing},
		{.In_Front, .Removal_Begun, .Removing},
		{.Removing, .Removal_Finished, .Absent},
	}
	for state in Session_State {
		for event in Session_Event {
			next, ok := session_next(state, event)
			expected: Session_State
			is_allowed := false
			for row in allowed {
				if row.state == state && row.event == event {
					expected, is_allowed = row.next, true
				}
			}
			testing.expectf(t, ok == is_allowed, "%v then %v: ok %v", state, event, ok)
			if is_allowed {
				testing.expect_value(t, next, expected)
			} else {
				testing.expectf(t, next == state, "%v then %v changed the state to %v", state, event, next)
			}
		}
	}
}

@(test)
a_session_unlocks_twice_never_and_locks_only_from_the_front :: proc(t: ^testing.T) {
	_, twice := session_next(.In_Front, .Unlocked)
	testing.expect(t, !twice, "a session in front is not unlocked again")
	_, from_absent := session_next(.Absent, .Unlocked)
	testing.expect(t, !from_absent, "no record, no session")
	_, from_creating := session_next(.Creating, .Unlocked)
	testing.expect(t, !from_creating, "a creation gives its record before its session")
	_, lock_locked := session_next(.Locked, .Locked)
	testing.expect(t, !lock_locked, "a locked session is not locked again")
	_, begin_twice := session_next(.Creating, .Creation_Begun)
	testing.expect(t, !begin_twice, "one creation in a slot")
	_, begin_over_record := session_next(.Locked, .Creation_Begun)
	testing.expect(t, !begin_over_record, "a creation never takes a slot that holds a record")
}

@(test)
the_seat_refuses_a_second_session_in_front :: proc(t: ^testing.T) {
	seat := Seat{state = .Session, in_front = 1}
	next, ok := seat_next(seat, .Session_Unlocked, 1)
	testing.expect(t, !ok && next == seat, "the session in front is not put in front again")
	// A slot past the capacity names no principal.
	next, ok = seat_next({state = .Chooser}, .Session_Unlocked, PRINCIPAL_CAPACITY)
	testing.expect(t, !ok && next.state == .Chooser, "a slot past the capacity is refused")
	next, ok = seat_next({state = .Chooser}, .Session_Unlocked, max(u64))
	testing.expect(t, !ok, "the largest slot is refused")
	// Principal 0 never comes in front by an unlock: its session has none.
	next, ok = seat_next({state = .Chooser}, .Session_Unlocked, MACHINE)
	testing.expect(t, !ok, "principal 0 is not unlocked")
}

@(test)
the_seat_locks_only_the_session_in_front :: proc(t: ^testing.T) {
	_, ok := seat_next({state = .Chooser}, .Session_Locked, 1)
	testing.expect(t, !ok, "no session in front: nothing to lock")
	_, ok = seat_next({state = .Session, in_front = MACHINE}, .Session_Locked, MACHINE)
	testing.expect(t, !ok, "principal 0 never locks")
	_, ok = seat_next({state = .Session, in_front = MACHINE}, .Session_Locked, 1)
	testing.expect(t, !ok, "a lock names the session in front")
	_, ok = seat_next({state = .Unlock_Window}, .Session_Locked, 1)
	testing.expect(t, !ok, "a window of unlock is not a session")
}

@(test)
the_window_of_unlock_opens_only_on_the_chooser :: proc(t: ^testing.T) {
	_, ok := seat_next({state = .Session, in_front = 1}, .Unlock_Window_Opened)
	testing.expect(t, !ok, "a window that a session asked for does not take the seat")
	_, ok = seat_next({state = .Unlock_Window}, .Unlock_Window_Opened)
	testing.expect(t, !ok, "one window of unlock")
	_, ok = seat_next({state = .Chooser}, .Unlock_Window_Closed)
	testing.expect(t, !ok, "no window to close")
	_, ok = seat_next({state = .Chooser}, .Unlock_Window_Opened, 1)
	testing.expect(t, !ok, "the event names no principal")
}

@(test)
a_record_takes_the_seat_from_principal_zero_only :: proc(t: ^testing.T) {
	next, ok := seat_next({state = .Session, in_front = MACHINE}, .Named_Principal_Recorded)
	testing.expect(t, ok && next.state == .Chooser, "the machine leaves the front")
	testing.expect_value(t, principal_in_front(next), u64(MACHINE))
	held := Seat{state = .Session, in_front = 1}
	next, ok = seat_next(held, .Named_Principal_Recorded)
	testing.expect(t, ok && next == held, "a named session keeps the seat")
	_, ok = seat_next({state = .Chooser}, .Machine_Alone, 1)
	testing.expect(t, !ok, "the start names principal 0 only")
	_, ok = seat_next({}, .Machine_Alone, 1)
	testing.expect(t, !ok, "the start names principal 0 only")
}

// The start comes once and first: Machine_Alone in each later state is
// refused and changes nothing, and no other event has a meaning before it.
@(test)
the_start_comes_once_and_first :: proc(t: ^testing.T) {
	for later in ([?]Seat{{state = .Chooser}, {state = .Unlock_Window}, {state = .Session, in_front = 1}, {state = .Session, in_front = MACHINE}}) {
		next, ok := seat_next(later, .Machine_Alone)
		testing.expect(t, !ok && next == later, "Machine_Alone past the start was taken")
	}
	for event in Seat_Event {
		if event == .Machine_Alone {
			continue
		}
		for principal in ([?]u64{MACHINE, 1}) {
			next, ok := seat_next({}, event, principal)
			testing.expect(t, !ok && next == Seat{}, "an event before the start was taken")
		}
	}
	next, ok := seat_next({}, .Machine_Alone)
	testing.expect(t, ok && next == Seat{state = .Session, in_front = MACHINE})
}

@(test)
one_session_from_the_start_to_the_lock :: proc(t: ^testing.T) {
	seat, ok := seat_next({}, .Machine_Alone)
	testing.expect(t, ok)
	testing.expect_value(t, principal_in_front(seat), u64(MACHINE))
	seat, ok = seat_next(seat, .Named_Principal_Recorded)
	testing.expect(t, ok && seat.state == .Chooser)
	seat, ok = seat_next(seat, .Unlock_Window_Opened)
	testing.expect(t, ok && seat.state == .Unlock_Window)
	seat, ok = seat_next(seat, .Session_Unlocked, 1)
	testing.expect(t, ok && seat.state == .Session)
	testing.expect_value(t, principal_in_front(seat), u64(1))
	seat, ok = seat_next(seat, .Session_Locked, 1)
	testing.expect(t, ok && seat.state == .Chooser)
	testing.expect_value(t, principal_in_front(seat), u64(MACHINE))
}

@(test)
the_word_of_the_ring_comes_from_the_session_state :: proc(t: ^testing.T) {
	for state in Session_State {
		testing.expect_value(t, principal_state_word(MACHINE, state), root_ring.Principal_State.Machine)
	}
	testing.expect_value(t, principal_state_word(1, .Absent), root_ring.Principal_State.Absent)
	testing.expect_value(t, principal_state_word(1, .In_Front), root_ring.Principal_State.Unlocked)
	testing.expect_value(t, principal_state_word(1, .Locked), root_ring.Principal_State.Locked)
	testing.expect_value(t, principal_state_word(1, .Creating), root_ring.Principal_State.Creating)
	testing.expect_value(t, principal_state_word(1, .Removing), root_ring.Principal_State.Removing)
}

// Admission closes the seat to any open session while a new principal is
// created and receives its recovery key, and returns to the chooser if
// abandoned or moves directly to Session when the new principal unlocks.
@(test)
admission_holds_the_seat_with_no_session :: proc(t: ^testing.T) {
	// Admission begins only from Chooser or Session, with no principal argument.
	for bad in ([?]Seat{{}, {state = .Unlock_Window}, {state = .Admission}}) {
		next, ok := seat_next(bad, .Admission_Begun)
		testing.expect(t, !ok && next == bad, "Admission_Begun accepted outside Chooser or Session")
	}
	_, bad_arg := seat_next({state = .Chooser}, .Admission_Begun, 1)
	testing.expect(t, !bad_arg, "Admission_Begun accepted a principal argument")
	from_session, from_session_ok := seat_next({state = .Session, in_front = 1}, .Admission_Begun)
	testing.expect(t, from_session_ok && from_session.state == .Admission && from_session.in_front == MACHINE)

	seat, ok := seat_next({state = .Chooser}, .Admission_Begun)
	testing.expect(t, ok && seat.state == .Admission && seat.in_front == MACHINE)
	testing.expect(t, !seat_has_active_session(seat))
	testing.expect(t, !seat_allows_machine_console(seat, true))

	// Unlock window and session lock are refused during Admission.
	_, ok = seat_next(seat, .Unlock_Window_Opened)
	testing.expect(t, !ok)
	_, ok = seat_next(seat, .Session_Locked, 1)
	testing.expect(t, !ok)
	_, ok = seat_next(seat, .Session_Unlocked, MACHINE)
	testing.expect(t, !ok)
	_, ok = seat_next(seat, .Session_Unlocked, PRINCIPAL_CAPACITY)
	testing.expect(t, !ok)
	_, ok = seat_next(seat, .Admission_Ended, 1)
	testing.expect(t, !ok)

	// Abandoning admission returns to the chooser.
	chooser, end_ok := seat_next(seat, .Admission_Ended)
	testing.expect(t, end_ok && chooser.state == .Chooser)
	testing.expect(t, !seat_has_active_session(chooser))
	testing.expect(t, !seat_allows_machine_console(chooser, true))

	// Completing admission unlocks the admitted principal onto the seat.
	admitted, unlock_ok := seat_next(seat, .Session_Unlocked, 1)
	testing.expect(t, unlock_ok && admitted.state == .Session && admitted.in_front == 1)
	testing.expect(t, seat_has_active_session(admitted))
	testing.expect(t, !seat_allows_machine_console(admitted, true))

	// Only principal 0's sole Session (with no named principals) allows the machine console.
	alone := Seat{state = .Session, in_front = MACHINE}
	testing.expect(t, seat_has_active_session(alone))
	testing.expect(t, seat_allows_machine_console(alone, false))
	testing.expect(t, !seat_allows_machine_console(alone, true))
}
