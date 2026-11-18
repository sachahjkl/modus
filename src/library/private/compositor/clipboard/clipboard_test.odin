#+build !freestanding
package clipboard

import "core:testing"

// The keys that are no key of the clipboard come first: c and v with no
// Control, Control with another character, with no character, and with
// the largest code point; then Control with c and v, in both cases, and
// with Shift too.
@(test)
clipboard_key_of_takes_control_with_c_and_v_only :: proc(t: ^testing.T) {
	SHIFT :: 1
	none := [?]struct {
		character: rune,
		modifiers: u32,
	}{
		{'c', 0},
		{'v', SHIFT},
		{'x', MODIFIER_CONTROL},
		{'r', MODIFIER_CONTROL},
		{0, MODIFIER_CONTROL},
		{rune(0x10FFFF), MODIFIER_CONTROL},
		{'c', ~u32(MODIFIER_CONTROL)},
	}
	for each in none {
		testing.expectf(t, clipboard_key_of(each.character, each.modifiers) == .None, "%v with %x is a key of the clipboard", each.character, each.modifiers)
	}
	testing.expect_value(t, clipboard_key_of('c', MODIFIER_CONTROL), Clipboard_Key.Copy)
	testing.expect_value(t, clipboard_key_of('C', MODIFIER_CONTROL | SHIFT), Clipboard_Key.Copy)
	testing.expect_value(t, clipboard_key_of('v', MODIFIER_CONTROL), Clipboard_Key.Paste)
	testing.expect_value(t, clipboard_key_of('V', ~u32(0)), Clipboard_Key.Paste)
}

// The facts of a Copy that the compositor takes: 5 bytes of text in one
// page, given with Read and Give, after Copy_Asked.
@(private = "file")
copy_of_test :: proc() -> Copy_Facts {
	return {asked = true, through = true, is_memory = true, readable = true, giveable = true, kind_word = 1, kind_known = true, count = 5, memory_bytes = 4096}
}

// Each rule that a Copy can break, from the edges: a handle that this
// program did not give, a copy that no key asked for, a handle that is no
// memory, with no Read or no Give, a kind that names no member, a count of
// 0, one past the limit and the largest word, and memory one byte too
// small. The copies that hold come last: one byte, and the limit.
@(test)
copy_refusal_refuses_each_broken_rule :: proc(t: ^testing.T) {
	Case :: struct {
		facts:   Copy_Facts,
		refusal: Copy_Refusal,
	}
	cases: [13]Case
	for &each in cases {
		each.facts = copy_of_test()
	}
	// A number that names the content of now, or its lent copy: refused
	// before any other rule, so the compositor never closes it.
	cases[11].facts.names_held, cases[11].refusal = true, .Names_Held
	cases[12].facts.names_held, cases[12].facts.asked, cases[12].refusal = true, false, .Names_Held
	cases[0].facts.through, cases[0].refusal = false, .Not_Given
	cases[1].facts.asked, cases[1].refusal = false, .Not_Asked
	cases[2].facts.is_memory, cases[2].refusal = false, .Not_Memory
	cases[3].facts.readable, cases[3].refusal = false, .No_Read
	cases[4].facts.giveable, cases[4].refusal = false, .No_Give
	cases[5].facts.kind_known, cases[5].refusal = false, .Unknown_Kind
	cases[6].facts.count, cases[6].refusal = 0, .Empty
	cases[7].facts.count, cases[7].refusal = TEXT_LIMIT + 1, .Too_Large
	cases[8].facts.count, cases[8].refusal = max(u64), .Too_Large
	cases[9].facts.memory_bytes, cases[9].refusal = 4, .Too_Small
	cases[10].facts.memory_bytes, cases[10].refusal = 0, .Too_Small
	for each, index in cases {
		refusal := copy_refusal(each.facts)
		testing.expectf(t, refusal == each.refusal, "case %d gives %v, not %v", index, refusal, each.refusal)
	}
	facts := copy_of_test()
	facts.count = 1
	testing.expect_value(t, copy_refusal(facts), Copy_Refusal.None)
	facts.count, facts.memory_bytes = TEXT_LIMIT, TEXT_LIMIT
	testing.expect_value(t, copy_refusal(facts), Copy_Refusal.None)
}

// The answers that no key of the principal started are refused, and change
// nothing: each answer with no key, with the serial 0, with the largest
// serial, and with a serial of the other state. A paste with no content and
// with no window in front starts nothing.
@(test)
answer_take_refuses_an_answer_that_no_key_started :: proc(t: ^testing.T) {
	state: Window_State
	serials: Serials
	for answer in Answer {
		for serial in ([?]u64{0, 1, max(u64)}) {
			testing.expectf(t, !answer_take(&state, answer, serial), "the answer %v of the serial %d with no key is taken", answer, serial)
			testing.expect_value(t, state, Window_State{})
		}
	}
	refusal, ended := paste_key_take(&state, true, false, serial_next(&serials))
	testing.expect_value(t, refusal, Paste_Refusal.No_Content)
	testing.expect(t, !ended && state == Window_State{})
	refusal, ended = paste_key_take(&state, false, true, serial_next(&serials))
	testing.expect_value(t, refusal, Paste_Refusal.No_Window)
	testing.expect(t, !ended && state == Window_State{})
	// A serial of a copy does not end a lend, nor the reverse.
	copy_serial := serial_next(&serials)
	copy_key_take(&state, copy_serial)
	testing.expect(t, !answer_take(&state, .Paste_Taken, copy_serial))
	testing.expect_value(t, state.copy_serial, copy_serial)
	testing.expect(t, !answer_take(&state, .Copy, 0))
	testing.expect(t, answer_take(&state, .Copy, copy_serial))
	testing.expect(t, !answer_take(&state, .Copy, copy_serial))
	testing.expect(t, !answer_take(&state, .Copy_Declined, copy_serial))
	testing.expect_value(t, state, Window_State{})
}

// A Copy_Asked that the program lost does not block the copies: the next
// key replaces it, the answer to the lost one is refused, and the answer to
// the newest is taken, once.
@(test)
copy_key_take_replaces_a_copy_that_waits :: proc(t: ^testing.T) {
	state: Window_State
	serials: Serials
	lost := serial_next(&serials)
	copy_key_take(&state, lost)
	newest := serial_next(&serials)
	copy_key_take(&state, newest)
	testing.expect(t, newest != lost && newest != 0)
	testing.expect(t, !copy_names_the_request(state, lost))
	testing.expect(t, !answer_take(&state, .Copy, lost))
	testing.expect(t, !answer_take(&state, .Copy_Declined, lost))
	testing.expect_value(t, state.copy_serial, newest)
	testing.expect(t, copy_names_the_request(state, newest))
	testing.expect(t, answer_take(&state, .Copy_Declined, newest))
	testing.expect(t, !answer_take(&state, .Copy, newest))
	testing.expect_value(t, state, Window_State{})
}

// Two pastes before one frame, and the slow answer to the first after the
// second: the answer to the first is refused and the second lend stays;
// the answer to the second ends it, once.
@(test)
paste_taken_of_an_ended_lend_does_not_end_the_next_one :: proc(t: ^testing.T) {
	state: Window_State
	serials: Serials
	first := serial_next(&serials)
	refusal, ended := paste_key_take(&state, true, true, first)
	testing.expect(t, refusal == .None && !ended)
	second := serial_next(&serials)
	refusal, ended = paste_key_take(&state, true, true, second)
	testing.expect(t, refusal == .None && ended)
	testing.expect(t, !answer_take(&state, .Paste_Taken, first))
	testing.expect_value(t, state.lend_serial, second)
	testing.expect(t, answer_take(&state, .Paste_Taken, second))
	testing.expect(t, !answer_take(&state, .Paste_Taken, second))
	testing.expect_value(t, state, Window_State{})
}

// The serials are never 0, and never twice.
@(test)
serial_next_gives_each_serial_once :: proc(t: ^testing.T) {
	serials: Serials
	before := u64(0)
	for _ in 0 ..< 1000 {
		serial := serial_next(&serials)
		testing.expect(t, serial != 0 && serial > before)
		before = serial
	}
}

// The end of a client: what it copied ends, and a lend of what it copied
// ends with it, also when the lend is to another client; a lend to the
// client ends; the end of a third client ends nothing. -1 is no lend.
@(test)
client_end_effects_end_the_lend_of_a_copier_that_ends :: proc(t: ^testing.T) {
	COPIER :: 2
	PASTER :: 5
	OTHER :: 7
	// The copier ends while the paster holds a lend of its content.
	effects := client_end_effects(COPIER, COPIER, PASTER, COPIER, true)
	testing.expect_value(t, effects, End_Effects{lend_ends = true, content_ends = true})
	// A newer copy of another client replaced the content: the lend of the
	// old content still ends with its copier, the new content stays.
	effects = client_end_effects(COPIER, OTHER, PASTER, COPIER, true)
	testing.expect_value(t, effects, End_Effects{lend_ends = true, content_ends = false})
	// The paster ends: its lend ends, the content stays.
	effects = client_end_effects(PASTER, COPIER, PASTER, COPIER, true)
	testing.expect_value(t, effects, End_Effects{lend_ends = true, content_ends = false})
	// A third client ends: nothing ends.
	effects = client_end_effects(OTHER, COPIER, PASTER, COPIER, true)
	testing.expect_value(t, effects, End_Effects{})
	// No lend and an empty slot: nothing ends, also for the client 0, which
	// the zero record of an empty slot names.
	effects = client_end_effects(0, 0, -1, -1, false)
	testing.expect_value(t, effects, End_Effects{})
	// No lend: only the content of the copier ends.
	effects = client_end_effects(COPIER, COPIER, -1, -1, true)
	testing.expect_value(t, effects, End_Effects{content_ends = true})
}
