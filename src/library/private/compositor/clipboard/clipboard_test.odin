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
	cases: [11]Case
	for &each in cases {
		each.facts = copy_of_test()
	}
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
// nothing: a Paste_Taken with no paste, a Copy and a Copy_Declined with no
// copy, and a second answer to one key. A paste with no content and with no
// window in front starts nothing. Then the answers to each key, last.
@(test)
answer_take_refuses_an_answer_that_no_key_started :: proc(t: ^testing.T) {
	state: Window_State
	for answer in Answer {
		testing.expectf(t, !answer_take(&state, answer), "the answer %v with no key is taken", answer)
		testing.expect_value(t, state, Window_State{})
	}
	refusal, ended := paste_key_take(&state, true, false)
	testing.expect_value(t, refusal, Paste_Refusal.No_Content)
	testing.expect(t, !ended && state == Window_State{})
	refusal, ended = paste_key_take(&state, false, true)
	testing.expect_value(t, refusal, Paste_Refusal.No_Window)
	testing.expect(t, !ended && state == Window_State{})

	// A copy: one Copy_Asked, no second one while it waits, one answer.
	testing.expect(t, copy_key_take(&state))
	testing.expect(t, !copy_key_take(&state))
	testing.expect(t, !answer_take(&state, .Paste_Taken))
	testing.expect(t, answer_take(&state, .Copy))
	testing.expect(t, !answer_take(&state, .Copy))
	testing.expect(t, !answer_take(&state, .Copy_Declined))
	testing.expect(t, copy_key_take(&state))
	testing.expect(t, answer_take(&state, .Copy_Declined))
	testing.expect_value(t, state, Window_State{})

	// A paste: a second key ends the first lend; one Paste_Taken ends it.
	refusal, ended = paste_key_take(&state, true, true)
	testing.expect(t, refusal == .None && !ended)
	refusal, ended = paste_key_take(&state, true, true)
	testing.expect(t, refusal == .None && ended)
	testing.expect(t, !answer_take(&state, .Copy))
	testing.expect(t, answer_take(&state, .Paste_Taken))
	testing.expect(t, !answer_take(&state, .Paste_Taken))
	testing.expect_value(t, state, Window_State{})
}
