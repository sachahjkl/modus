// The states of a session and of the seat, and the one procedure that
// changes each (src/md/features/several_principals.md, "The states").
//
// A session is the tree of processes of one principal. Its state says if
// the principal has a record, if its session runs and if it is in front.
// The seat is the screen and its input: its state says what it shows, and
// which session is in front. "The session in front" is a fact of the seat,
// not "the principal that is unlocked": the two agree while one session
// runs at a time, and part when sessions run behind.
//
// A member exists only from the layer that builds it: Behind, Removing and
// Admission have none yet, so no switch handles a state that no path
// reaches.
//
// No allocator and no kernel operation: the root service and the host
// tests call the same procedures.
package principals

import "modus:contract/root_ring"

// The state of the session of one principal.
Session_State :: enum u8 {
	Absent, // No record has this slot.
	Creating, // unlock asks for the passphrase of a new principal; no record yet.
	Locked, // A record, and no session.
	In_Front, // Its session runs, and the seat shows it.
}

// What happens to a session.
Session_Event :: enum u8 {
	Creation_Begun, // unlock starts to create a principal in this slot.
	Creation_Abandoned, // That unlock stopped before it gave a record.
	Record_Given, // unlock gave the record: from a creation, or from a file at the start.
	Unlocked, // The passphrase opened its keys.
	Locked, // Its session ended.
}

// session_next gives the state of a session after an event, or ok false:
// the event has no meaning in that state, and the caller changes nothing.
// Principal 0 has no session state: its session needs no unlock and never
// locks, so the root service never calls this for it.
session_next :: proc "contextless" (state: Session_State, event: Session_Event) -> (next: Session_State, ok: bool) {
	switch event {
	case .Creation_Begun:
		if state == .Absent {
			return .Creating, true
		}
	case .Creation_Abandoned:
		if state == .Creating {
			return .Absent, true
		}
	case .Record_Given:
		// A record from the file at the start comes to an absent slot; a
		// record of a creation comes to the slot that the creation took.
		if state == .Absent || state == .Creating {
			return .Locked, true
		}
	case .Unlocked:
		if state == .Locked {
			return .In_Front, true
		}
	case .Locked:
		if state == .In_Front {
			return .Locked, true
		}
	}
	return state, false
}

// The state of the seat.
Seat_State :: enum u8 {
	Chooser, // No session is in front, and no window of unlock shows.
	Unlock_Window, // A window of unlock that no session asked for: the unlock or the creation.
	Session, // A session is in front: Seat.in_front names its principal.
}

// The seat: its state and, in the state Session, the principal in front.
// In the two other states in_front is principal 0 and means nothing.
Seat :: struct {
	state:    Seat_State,
	in_front: u64,
}

// What happens to the seat.
Seat_Event :: enum u8 {
	Machine_Alone, // The start of the machine: principal 0 is in front.
	Named_Principal_Recorded, // A named principal has a record: principal 0 leaves the front.
	Unlock_Window_Opened, // unlock opened its window for an unlock or a creation.
	Unlock_Window_Closed, // That unlock stopped.
	Session_Unlocked, // A named session comes in front: the argument names it.
	Session_Locked, // The session in front ended.
}

// seat_next gives the seat after an event, or ok false: the event has no
// meaning there, and the caller changes nothing. principal is the
// principal of Session_Unlocked and Session_Locked, and is 0 for each
// other event.
//
// Example: a seat in Session with principal 1 in front refuses
// Session_Unlocked of principal 2: one session is in front at a time.
seat_next :: proc "contextless" (seat: Seat, event: Seat_Event, principal: u64 = MACHINE) -> (next: Seat, ok: bool) {
	machine_in_front := seat.state == .Session && seat.in_front == MACHINE
	switch event {
	case .Machine_Alone:
		if principal == MACHINE {
			return {state = .Session, in_front = MACHINE}, true
		}
	case .Named_Principal_Recorded:
		if principal != MACHINE {
			break
		}
		if machine_in_front {
			return {state = .Chooser}, true
		}
		// A record that comes while a named session or the chooser holds
		// the seat changes nothing: the seat is already not principal 0.
		return seat, true
	case .Unlock_Window_Opened:
		if principal == MACHINE && seat.state == .Chooser {
			return {state = .Unlock_Window}, true
		}
	case .Unlock_Window_Closed:
		if principal == MACHINE && seat.state == .Unlock_Window {
			return {state = .Chooser}, true
		}
	case .Session_Unlocked:
		if principal == MACHINE || principal >= PRINCIPAL_CAPACITY {
			break
		}
		if seat.state == .Chooser || seat.state == .Unlock_Window || machine_in_front {
			return {state = .Session, in_front = principal}, true
		}
	case .Session_Locked:
		if principal != MACHINE && seat.state == .Session && seat.in_front == principal {
			return {state = .Chooser}, true
		}
	}
	return seat, false
}

// principal_in_front gives the principal whose session is in front, or
// principal 0 when no session is: the desktop then starts a process of
// principal 0, as before a named principal had a record.
principal_in_front :: proc "contextless" (seat: Seat) -> u64 {
	if seat.state == .Session {
		return seat.in_front
	}
	return MACHINE
}

// principal_state_word gives the state that the root ring says for a slot
// (root_ring.Principal_State): the one place where the session state
// becomes the word of the contract. Principal 0 is always Machine.
principal_state_word :: proc "contextless" (slot: u64, state: Session_State) -> root_ring.Principal_State {
	if slot == MACHINE {
		return .Machine
	}
	switch state {
	case .Absent:
		return .Absent
	case .Creating:
		return .Creating
	case .Locked:
		return .Locked
	case .In_Front:
		return .Unlocked
	}
	return .Absent
}
