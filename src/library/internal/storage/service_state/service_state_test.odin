#+build !freestanding
package service_state

import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/errors"

// Border check: unknown words for Disk_State are refused, and every member
// round-trips cleanly.
@(test)
disk_state_border_refuses_unknown_words :: proc(t: ^testing.T) {
	for word in ([?]u64{u64(max(Disk_State)) + 1, 0x100, max(u64)}) {
		_, ok := disk_state_of_word(word)
		testing.expectf(t, !ok, "word %d must not map to a Disk_State", word)
	}
	for member in Disk_State {
		got, ok := disk_state_of_word(u64(member))
		testing.expect(t, ok)
		testing.expect_value(t, got, member)
	}
}

// Image-tree availability stays true in every Disk_State (Absent, Opening,
// Opened, Silent, Unusable), while disk-store availability is true ONLY in
// .Opened.
@(test)
image_tree_is_decoupled_from_every_disk_state :: proc(t: ^testing.T) {
	// Zero value: neither ready.
	zero := Service_Readiness{}
	testing.expect(t, !image_tree_available(zero))
	testing.expect(t, !disk_store_available(zero))

	for state in Disk_State {
		ready := Service_Readiness{image_tree_ready = true, disk_state = state}
		testing.expectf(t, image_tree_available(ready), "image tree must stay available in disk state %v", state)
		testing.expect_value(t, disk_store_available(ready), state == .Opened)

		outcome, kind, refused := disk_call_refusal(state)
		if state == .Opened {
			testing.expect(t, !refused)
			testing.expect_value(t, outcome, call_outcome.Call_Outcome.Succeeded)
			testing.expect_value(t, kind, errors.Kind.None)
		} else {
			testing.expect(t, refused)
			testing.expect_value(t, outcome, call_outcome.Call_Outcome.Callee_Unavailable)
			testing.expect_value(t, kind, errors.Kind.Device)
		}
	}
}

// State machine transition edges: invalid jumps are refused, terminal states
// (.Silent and .Unusable) never re-open, and normal lifecycle transitions pass.
@(test)
disk_state_transitions_and_terminal_states :: proc(t: ^testing.T) {
	// Invalid jumps from .Absent are refused.
	for bad in ([?]Disk_Event{.No_Block_Ring, .Open_Succeeded, .Open_Unusable}) {
		next, changed := disk_state_transition(.Absent, bad)
		testing.expect_value(t, next, Disk_State.Absent)
		testing.expect(t, !changed)
	}

	// Normal open path: Absent -> Opening -> Opened -> Silent.
	s1, c1 := disk_state_transition(.Absent, .Begin_Open)
	testing.expect_value(t, s1, Disk_State.Opening)
	testing.expect(t, c1)

	// Re-entering Begin_Open or No_Block_Ring while Opening changes nothing.
	for nop in ([?]Disk_Event{.Begin_Open, .No_Block_Ring}) {
		next, changed := disk_state_transition(.Opening, nop)
		testing.expect_value(t, next, Disk_State.Opening)
		testing.expect(t, !changed)
	}

	s2, c2 := disk_state_transition(s1, .Open_Succeeded)
	testing.expect_value(t, s2, Disk_State.Opened)
	testing.expect(t, c2)

	// Invalid transitions from .Opened do not leave .Opened.
	for nop in ([?]Disk_Event{.No_Block_Ring, .Begin_Open, .Open_Succeeded, .Open_Unusable}) {
		next, changed := disk_state_transition(.Opened, nop)
		testing.expect_value(t, next, Disk_State.Opened)
		testing.expect(t, !changed)
	}

	s3, c3 := disk_state_transition(s2, .Went_Silent)
	testing.expect_value(t, s3, Disk_State.Silent)
	testing.expect(t, c3)

	// Corrupt or older-format disk path: Absent -> Opening -> Unusable.
	u1, uc1 := disk_state_transition(.Opening, .Open_Unusable)
	testing.expect_value(t, u1, Disk_State.Unusable)
	testing.expect(t, uc1)

	// Silent before mount starts: Absent -> Silent.
	as1, asc1 := disk_state_transition(.Absent, .Went_Silent)
	testing.expect_value(t, as1, Disk_State.Silent)
	testing.expect(t, asc1)

	// Silent during mount: Opening -> Silent.
	os1, osc1 := disk_state_transition(.Opening, .Went_Silent)
	testing.expect_value(t, os1, Disk_State.Silent)
	testing.expect(t, osc1)

	// Terminal states (.Silent and .Unusable) refuse every event.
	for terminal in ([?]Disk_State{.Silent, .Unusable}) {
		for event in Disk_Event {
			next, changed := disk_state_transition(terminal, event)
			testing.expect_value(t, next, terminal)
			testing.expect(t, !changed)
		}
	}
}
