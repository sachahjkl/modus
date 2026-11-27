#+build !freestanding
package service_state

import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import op "modus:contract/operation"

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

// Fonts-only connections have empty store name, zero block limit, and
// acts_for_principal = false: they are refused from naming any store, querying
// usage, and listing durable pins.
@(test)
fonts_only_connection_refused_store_access :: proc(t: ^testing.T) {
	// Fonts-only connection (empty name, 0 limit, no acts_for_principal).
	testing.expect(t, !caller_has_own_store("", 0))
	testing.expect(t, !caller_has_own_store("notes", 0))
	testing.expect(t, !caller_has_own_store("", 64))
	testing.expect(t, caller_has_own_store("notes", 64))

	testing.expect(t, !caller_may_name_store(true, false, false, 0, "", 0, ""))
	testing.expect(t, !caller_may_name_store(true, false, false, 0, "", 0, "notes"))
	testing.expect(t, !caller_may_name_store(true, false, false, 0, "notes", 0, "notes"))
	testing.expect(t, !caller_may_read_usage(true, "", 0))
	testing.expect(t, !caller_may_read_usage(true, "notes", 0))
	testing.expect(t, !caller_may_list_pins(true, false, false, "", 0))
	testing.expect(t, !caller_may_list_pins(true, false, false, "notes", 0))

	// A fonts-only grant word produced by caller_grant_make(0, 0, false) | CALLER_READS_ONLY
	// carries zero amount, principal 0, read-only, and no elevated flags.
	fonts_grant := isolated.caller_grant_make(0, 0, false) | isolated.CALLER_READS_ONLY
	testing.expect_value(t, fonts_grant & isolated.CALLER_AMOUNT_MASK, u64(0))
	testing.expect_value(t, isolated.caller_principal(fonts_grant), u64(0))
	testing.expect(t, fonts_grant & isolated.CALLER_READS_ONLY != 0)
	testing.expect(t, fonts_grant & isolated.CALLER_ACTS_FOR_PRINCIPAL == 0)
	testing.expect(t, fonts_grant & isolated.CALLER_RECOUNTS == 0)
	testing.expect(t, fonts_grant & isolated.CALLER_ERASES_VERSIONS == 0)

	// Legitimate store owners and principal actors still pass.
	testing.expect(t, caller_may_name_store(true, false, false, 0, "notes", 64, "notes"))
	testing.expect(t, !caller_may_name_store(true, false, false, 0, "notes", 64, "edit"))
	testing.expect(t, caller_may_name_store(true, false, true, 0, "", 0, "notes"))
	testing.expect(t, !caller_may_name_store(true, false, true, 0, "", 0, ""))
	testing.expect(t, caller_may_read_usage(true, "notes", 64))
	testing.expect(t, caller_may_list_pins(true, false, false, "notes", 64))
	testing.expect(t, caller_may_list_pins(true, false, true, "", 0))
	testing.expect(t, !caller_may_list_pins(true, true, true, "notes", 64))
}

// Publish_Public_Object handle safety: unverified handles (!through) are never
// closed; self-aliasing handles are never closed on refusal or install; wrong
// rights, invalid kinds, zero sizes, and overflowing sizes close only verified
// distinct handles.
@(test)
public_object_publish_handle_checks :: proc(t: ^testing.T) {
	VALID_KIND :: u64(isolated.Public_Object_Kind.Script_Fonts)
	VALID_RIGHTS :: op.Rights{.Read, .Give}
	PAGE :: u64(4096)

	// Zero handle or unverified handle (!through): Ignore (never close).
	testing.expect_value(t, public_object_publish_decide(0, 7, true, .Memory, VALID_RIGHTS, VALID_KIND, 100, true, 1, PAGE), Public_Object_Publish_Decision{action = .Ignore})
	testing.expect_value(t, public_object_publish_decide(99, 7, false, .Memory, VALID_RIGHTS, VALID_KIND, 100, true, 1, PAGE), Public_Object_Publish_Decision{action = .Ignore})
	testing.expect_value(t, public_object_publish_decide(7, 7, false, .Memory, {.Write}, 999, 0, false, 0, PAGE), Public_Object_Publish_Decision{action = .Ignore})

	// Refused verified handle that aliases existing_handle: Ignore (no self-close UAF).
	testing.expect_value(t, public_object_publish_decide(7, 7, true, .Memory, VALID_RIGHTS, u64(isolated.Public_Object_Kind.None), 100, true, 1, PAGE), Public_Object_Publish_Decision{action = .Ignore})
	testing.expect_value(t, public_object_publish_decide(7, 7, true, .Memory, {.Read, .Write, .Give}, VALID_KIND, 100, true, 1, PAGE), Public_Object_Publish_Decision{action = .Ignore})

	// Refused verified distinct handles: Close_Incoming.
	bad_cases := [?]Public_Object_Publish_Decision{
		public_object_publish_decide(10, 7, true, .Memory, VALID_RIGHTS, 0, 100, true, 1, PAGE),                  // .None kind
		public_object_publish_decide(10, 7, true, .Memory, VALID_RIGHTS, 99, 100, true, 1, PAGE),                 // unknown kind
		public_object_publish_decide(10, 7, true, .Memory, VALID_RIGHTS, VALID_KIND, 0, true, 1, PAGE),           // zero size
		public_object_publish_decide(10, 7, true, .Process, VALID_RIGHTS, VALID_KIND, 100, true, 1, PAGE),        // non-memory
		public_object_publish_decide(10, 7, true, .Memory, {.Read}, VALID_KIND, 100, true, 1, PAGE),              // missing Give
		public_object_publish_decide(10, 7, true, .Memory, {.Give}, VALID_KIND, 100, true, 1, PAGE),              // missing Read
		public_object_publish_decide(10, 7, true, .Memory, {.Read, .Give, .Write}, VALID_KIND, 100, true, 1, PAGE),
		public_object_publish_decide(10, 7, true, .Memory, {.Read, .Give, .Execute}, VALID_KIND, 100, true, 1, PAGE),
		public_object_publish_decide(10, 7, true, .Memory, VALID_RIGHTS, VALID_KIND, 100, false, 1, PAGE),        // memory_size failed
		public_object_publish_decide(10, 7, true, .Memory, VALID_RIGHTS, VALID_KIND, PAGE + 1, true, 1, PAGE),    // size > pages * PAGE
		public_object_publish_decide(10, 7, true, .Memory, VALID_RIGHTS, VALID_KIND, 100, true, max(u64), PAGE),  // pages * PAGE overflow
	}
	for decision, idx in bad_cases {
		testing.expectf(t, decision == Public_Object_Publish_Decision{action = .Close_Incoming}, "bad case %d: got %v", idx, decision)
	}

	// Valid first install (existing == 0): Install, close_existing = false.
	testing.expect_value(t, public_object_publish_decide(10, 0, true, .Memory, VALID_RIGHTS, VALID_KIND, PAGE, true, 1, PAGE), Public_Object_Publish_Decision{action = .Install, close_existing = false, kind = .Script_Fonts})

	// Valid replacement with distinct handle: Install, close_existing = true.
	testing.expect_value(t, public_object_publish_decide(11, 10, true, .Memory, VALID_RIGHTS, VALID_KIND, 100, true, 1, PAGE), Public_Object_Publish_Decision{action = .Install, close_existing = true, kind = .Script_Fonts})

	// Valid re-publish of same handle: Install, close_existing = false (never self-close).
	testing.expect_value(t, public_object_publish_decide(10, 10, true, .Memory, VALID_RIGHTS, VALID_KIND, 100, true, 1, PAGE), Public_Object_Publish_Decision{action = .Install, close_existing = false, kind = .Script_Fonts})
}
