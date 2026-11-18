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
// and the release are both keys of the clipboard, so no process sees the
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
	asked:        bool, // The record names the serial of the Copy_Asked that waits for this window (copy_names_the_request).
	through:      bool, // The handle is a gift of this process through the ring of its window.
	names_held:   bool, // The number names a handle that the compositor holds already: the content of now, or a lent copy of it.
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
	Not_Given, // The handle is not a gift of this process through its ring: the compositor neither uses it nor closes it.
	Names_Held, // The number names the content that the compositor holds: it neither takes it again nor closes it.
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
	case facts.names_held:
		return .Names_Held
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
// process. Each starts at a key of the principal, has the serial of that
// key, and ends at one answer that names the serial. A serial is never 0,
// and the compositor never gives one twice (Serials), so an answer to a
// request that ended never matches the request of now.
Window_State :: struct {
	copy_serial: u64, // The serial of the Copy_Asked that waits; 0: none.
	lend_serial: u64, // The serial of the lend of a paste that waits; 0: none.
}

// The serials of the keys of the clipboard: 1, 2, 3 ... for the life of the
// compositor. A u64 counted by one for each key does not come back to 0.
Serials :: struct {
	last: u64,
}

// serial_next gives the serial of a new key.
serial_next :: proc "contextless" (serials: ^Serials) -> u64 {
	serials.last += 1
	return serials.last
}

// An answer of a process.
Answer :: enum {
	Copy, // A Copy that copy_refusal took.
	Copy_Declined,
	Paste_Taken,
}

// copy_key_take starts a copy at the key of the principal, with the serial
// of that key. A copy that waited is replaced: its process can have lost
// it, and a later answer to it is refused (answer_take). The process
// answers the newest request.
copy_key_take :: proc "contextless" (state: ^Window_State, serial: u64) {
	state.copy_serial = serial
}

// Why a paste key gives nothing to the window in front.
Paste_Refusal :: enum {
	None,
	No_Window, // No window is in front.
	No_Content, // The clipboard is empty.
}

// paste_key_take starts a lend at the key of the principal, for the window
// in front, with the serial of that key. A lend that waits for this window
// ends first: the compositor revokes it (lend_ended).
paste_key_take :: proc "contextless" (state: ^Window_State, window_in_front, content: bool, serial: u64) -> (refusal: Paste_Refusal, lend_ended: bool) {
	switch {
	case !window_in_front:
		return .No_Window, false
	case !content:
		return .No_Content, false
	}
	lend_ended = state.lend_serial != 0
	state.lend_serial = serial
	return .None, lend_ended
}

// answer_take changes the state for an answer of a process that names a
// serial, and says if the compositor takes it: only when it names the
// serial of the state that waits. A Paste_Taken with no paste of the
// principal before it, or for a lend that ended, is refused, as a Copy or
// a Copy_Declined with no copy that waits, or for a copy that a newer key
// replaced. A refused answer changes nothing.
answer_take :: proc "contextless" (state: ^Window_State, answer: Answer, serial: u64) -> bool {
	switch answer {
	case .Copy, .Copy_Declined:
		if serial == 0 || serial != state.copy_serial {
			return false
		}
		state.copy_serial = 0
	case .Paste_Taken:
		if serial == 0 || serial != state.lend_serial {
			return false
		}
		state.lend_serial = 0
	}
	return true
}

// What the end of a client ends of the clipboard.
End_Effects :: struct {
	lend_ends:    bool, // The lend of a paste ends: the compositor revokes it.
	content_ends: bool, // The content ends: the slot is empty.
}

// client_end_effects decides what the end of the client `client` ends.
// The content ends with the client that copied it. A lend ends with the
// client that copied what it lends (lend_owner: a newer copy can have
// replaced that content since), because that memory belongs to a process
// that has no budget any more, and no handle of it stays; and with the
// client that it was lent to. lend_client is -1 with no lend; content is
// false with an empty slot.
client_end_effects :: proc "contextless" (client, content_owner, lend_client, lend_owner: int, content: bool) -> End_Effects {
	return {lend_ends = lend_client >= 0 && (lend_client == client || lend_owner == client), content_ends = content && content_owner == client}
}

// copy_names_the_request says if a Copy names the copy that waits: the
// fact asked of Copy_Facts.
copy_names_the_request :: proc "contextless" (state: Window_State, serial: u64) -> bool {
	return serial != 0 && serial == state.copy_serial
}
