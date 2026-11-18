// The decisions of the clipboard of the compositor, with no state
// (src/md/features/clipboard.md): which key of the principal is a key of
// the clipboard, and which records of a window the compositor takes. The
// compositor holds the state and calls these procedures, so a host test
// gives them each refused case.
package clipboard

// The bit Control of the modifiers of a key record (display.MODIFIER_CONTROL).
// The compositor asserts that the two are the same.
MODIFIER_CONTROL :: 2

// The largest content (display.CLIPBOARD_TEXT_LIMIT); the compositor
// asserts that the two are the same.
TEXT_LIMIT :: 4096

// A key of the principal for the clipboard.
Clipboard_Key :: enum {
	None, // Not a key of the clipboard: it goes on its usual path.
	Copy, // Control+C.
	Paste, // Control+V.
}

// clipboard_key_of reads a key record of the input service: Control with
// the character c or v, in either case, as the layout gives it. The press
// and the release are both keys of the clipboard, so no program sees the
// release of a key whose press it did not see; only the press acts.
clipboard_key_of :: proc "contextless" (character: rune, modifiers: u32) -> Clipboard_Key {
	if modifiers & MODIFIER_CONTROL == 0 {
		return .None
	}
	switch character {
	case 'c', 'C':
		return .Copy
	case 'v', 'V':
		return .Paste
	}
	return .None
}

// What the compositor knows when a window sends Copy: the facts of the
// handle, the words of the record, and the state of the window.
Copy_Facts :: struct {
	asked:        bool, // The compositor sent Copy_Asked to this window, and no answer came.
	through:      bool, // The handle is a gift of this program through the ring of its window.
	is_memory:    bool, // The handle names a memory object.
	readable:     bool, // The handle has Read.
	giveable:     bool, // The handle has Give: the compositor lends it at a paste.
	kind_word:    u64, // The word of the kind.
	kind_known:   bool, // The word names a kind that is not None (display.clipboard_kind_of_word).
	count:        u64, // The word of the count of bytes.
	memory_bytes: u64, // The size of the memory. 0 when the kernel refused to give it.
}

// The rule that a Copy breaks. None: the compositor takes it.
Copy_Refusal :: enum {
	None,
	Not_Asked, // No key of the principal asked for this copy.
	Not_Given, // The handle is not a gift of this program through its ring: the compositor neither uses it nor closes it.
	Not_Memory, // The handle names no memory object.
	No_Read, // The handle has no Read.
	No_Give, // The handle has no Give.
	Unknown_Kind, // The kind names no member, or None.
	Empty, // A count of 0.
	Too_Large, // A count past TEXT_LIMIT.
	Too_Small, // The memory does not hold the count.
}

// copy_refusal decides a Copy from its facts. The words are compared as
// words, before any cast.
copy_refusal :: proc "contextless" (facts: Copy_Facts) -> Copy_Refusal {
	switch {
	case !facts.through:
		return .Not_Given
	case !facts.asked:
		return .Not_Asked
	case !facts.is_memory:
		return .Not_Memory
	case !facts.readable:
		return .No_Read
	case !facts.giveable:
		return .No_Give
	case !facts.kind_known:
		return .Unknown_Kind
	case facts.count == 0:
		return .Empty
	case facts.count > TEXT_LIMIT:
		return .Too_Large
	case facts.memory_bytes < facts.count:
		return .Too_Small
	}
	return .None
}

// The clipboard state of one window: what waits for an answer of its
// program. Each starts at a key of the principal and ends at one answer.
Window_State :: struct {
	copy_waits: bool, // Copy_Asked went, and no Copy or Copy_Declined came.
	lend_waits: bool, // Pasted went with a lent handle, and no Paste_Taken came.
}

// An answer of a program.
Answer :: enum {
	Copy, // A Copy that copy_refusal took.
	Copy_Declined,
	Paste_Taken,
}

// copy_key_take starts a copy at the key of the principal. false: a copy
// already waits for this window, and no second Copy_Asked goes.
copy_key_take :: proc "contextless" (state: ^Window_State) -> bool {
	if state.copy_waits {
		return false
	}
	state.copy_waits = true
	return true
}

// Why a paste key gives nothing to the window in front.
Paste_Refusal :: enum {
	None,
	No_Window, // No window is in front.
	No_Content, // The clipboard is empty.
}

// paste_key_take starts a lend at the key of the principal, for the window
// in front. A lend that waits for this window ends first: the compositor
// revokes it (lend_ended).
paste_key_take :: proc "contextless" (state: ^Window_State, window_in_front, content: bool) -> (refusal: Paste_Refusal, lend_ended: bool) {
	switch {
	case !window_in_front:
		return .No_Window, false
	case !content:
		return .No_Content, false
	}
	lend_ended = state.lend_waits
	state.lend_waits = true
	return .None, lend_ended
}

// answer_take changes the state for an answer of a program, and says if
// the compositor takes it: only when the state that it ends waits. A
// Paste_Taken with no paste of the principal before it is refused, as a
// Copy or a Copy_Declined with no copy that waits. A refused answer
// changes nothing.
answer_take :: proc "contextless" (state: ^Window_State, answer: Answer) -> bool {
	switch answer {
	case .Copy, .Copy_Declined:
		if !state.copy_waits {
			return false
		}
		state.copy_waits = false
	case .Paste_Taken:
		if !state.lend_waits {
			return false
		}
		state.lend_waits = false
	}
	return true
}
