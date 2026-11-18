package display

import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:support/system"
import "base:intrinsics"

// The two answers of a program to the clipboard keys of the principal
// (src/md/features/clipboard.md). The compositor holds the clipboard; a
// program sees it only at a key of the principal: Copy_Asked for a copy,
// Pasted for a paste. Each answer goes once.

// copy_send answers Copy_Asked with a text. It checks the text
// (clipboard_text_problem), makes a memory object of its pages with the
// budget of this program, writes the text, gives the compositor a handle
// with Read and Give through the ring of the window, closes its own handle,
// and sends Copy. The program then holds no handle of the content, which
// lives until the next copy or the end of this program.
//
// problem is None when the copy went. Each other problem answers with
// Copy_Declined, so the compositor waits no more, but Not_Asked (no
// request to answer) and Ring_Full (the request waits: call copy_send or
// copy_decline again). Kernel_Refused has the status of the kernel, with
// its error record: No_Budget when the budget cannot pay.
copy_send :: proc "contextless" (window: ^Window, text: []u8, error: ^errors.Error_Record = nil) -> (problem: Clipboard_Problem, status: system.Status) {
	if !window.copy_asked {
		return .Not_Asked, .Ok
	}
	// The ring has one writer, this thread: the room seen here stays for
	// the record of the answer, so no given handle waits in the table of
	// the compositor with no record that names it.
	if ring.count(&window.ring.commands) == ring.capacity(&window.ring.commands) {
		return .Ring_Full, .Ok
	}
	title := string(window.title[:window.title_count])
	problem = clipboard_text_problem(text, CLIPBOARD_TEXT_LIMIT)
	if problem != .None {
		system.log_in("programs", .Warning, "display: ", title, ": the copy is refused: ", CLIPBOARD_PROBLEM_SENTENCES[problem])
		copy_decline(window)
		return problem, .Ok
	}
	pages := (u64(len(text)) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	memory: system.Handle
	memory, status = system.memory_create(pages, error = error)
	address: rawptr
	if status == .Ok {
		address, status = system.memory_map(memory, error = error)
		if status != .Ok {
			system.close(memory)
		}
	}
	granted: system.Handle
	if status == .Ok {
		intrinsics.mem_copy_non_overlapping(address, raw_data(text), len(text))
		system.memory_unmap(address)
		granted, status = system.give(window.ring_memory, memory, {.Read, .Give}, error)
		// This program keeps no handle: no later write can reach the content.
		system.close(memory)
	}
	if status != .Ok {
		system.log_in("programs", .Warning, "display: ", title, ": the copy of ", u64(len(text)), " bytes is refused: ", op.STATUS_NAMES[status])
		copy_decline(window)
		return .Kernel_Refused, status
	}
	system.send(&window.ring.commands, ring.Record{kind = u32(Command.Copy), values = {0 = u64(granted), 1 = u64(Clipboard_Kind.Text), 2 = u64(len(text)), 3 = window.copy_serial}})
	window.copy_asked = false
	system.log_in("programs", .Info, "display: ", title, ": a copy of ", u64(len(text)), " bytes of text")
	return .None, .Ok
}

// copy_decline answers Copy_Asked with no content: the window has nothing
// to copy. It gives false when there was no request, or when the command
// ring was full: the request then waits, and the caller answers later.
copy_decline :: proc "contextless" (window: ^Window) -> bool {
	if !window.copy_asked || !system.send(&window.ring.commands, ring.Record{kind = u32(Command.Copy_Declined), values = {0 = window.copy_serial}}) {
		return false
	}
	window.copy_asked = false
	return true
}

// paste_read takes the content of a paste (an event Pasted) into the
// memory of the caller: room is where the text goes. It checks the handle
// (memory with Read that the compositor gave through the ring of the
// window, which holds the count of bytes), maps it with Read, copies the
// bytes into room, unmaps and closes the handle, and answers Paste_Taken.
// Then it checks the copy (clipboard_text_problem): the program that
// copied can write its memory after the copy, so only the copy is checked.
//
// count is the bytes of the text in room when problem is None. With a
// problem, the bytes of room past the text of the caller are not text, and
// the caller keeps its text as it was. The handle is closed and the answer
// sent in each case, with the serial of the paste, so the compositor ends
// that lend and no later one.
//
// A known risk: the read is a read of a mapping. A program that copied and
// kept its own handle can revoke it while this program reads, and this
// program then faults. No kernel operation copies bytes out of a memory
// object with a refusal in place of a fault (src/md/features/clipboard.md,
// "Subtle points"; ROADMAP.md).
paste_read :: proc "contextless" (window: ^Window, event: Event, room: []u8) -> (count: int, problem: Clipboard_Problem) {
	count, problem = paste_copy(window, event, room)
	paste_answer(window, event)
	title := string(window.title[:window.title_count])
	if problem == .None {
		system.log_in("programs", .Info, "display: ", title, ": a paste of ", u64(count), " bytes of text")
	} else {
		system.log_in("programs", .Warning, "display: ", title, ": the paste is refused: ", CLIPBOARD_PROBLEM_SENTENCES[problem])
	}
	return count, problem
}

// The facts of a paste before its copy: the event, the state of its handle,
// the size of its memory and the room of the caller.
Paste_Facts :: struct {
	event:        Event,
	is_memory:    bool, // The handle names a memory object.
	readable:     bool, // The handle has Read.
	through:      bool, // The compositor gave it through the ring of the window.
	memory_bytes: u64, // The size of the memory. 0 when the kernel refused to give it.
	room:         int, // The bytes that the caller takes.
}

// paste_problem decides a paste from its facts, before any byte is read.
// It reads and changes no state, so a host test gives it each refused
// case.
paste_problem :: proc "contextless" (facts: Paste_Facts) -> Clipboard_Problem {
	event := facts.event
	switch {
	case event.kind != .Pasted || event.clipboard_kind != .Text:
		return .Unknown_Kind
	case !facts.is_memory || !facts.readable || !facts.through:
		return .Not_Given
	case event.byte_count <= 0:
		return .Empty
	case event.byte_count > CLIPBOARD_TEXT_LIMIT || event.byte_count > facts.room:
		return .Too_Large
	case facts.memory_bytes < u64(event.byte_count):
		return .Too_Small
	}
	return .None
}

// paste_answer closes the lent handle and answers Paste_Taken with the
// serial of the paste.
@(private = "file")
paste_answer :: proc "contextless" (window: ^Window, event: Event) {
	system.close(event.paste_handle)
	system.send(&window.ring.commands, ring.Record{kind = u32(Command.Paste_Taken), values = {0 = event.clipboard_serial}})
}

// paste_copy does the checks and the copy of paste_read, with no answer.
@(private = "file")
paste_copy :: proc "contextless" (window: ^Window, event: Event, room: []u8) -> (count: int, problem: Clipboard_Problem) {
	kind, rights, through := system.handle_state(event.paste_handle, window.ring_memory)
	facts := Paste_Facts{event = event, is_memory = kind == .Memory, readable = .Read in rights, through = through, room = len(room)}
	if facts.is_memory {
		if pages, size_status := system.memory_size(event.paste_handle); size_status == .Ok {
			facts.memory_bytes = pages * system.PAGE_SIZE
		}
	}
	if refused := paste_problem(facts); refused != .None {
		return 0, refused
	}
	address, map_status := system.memory_map(event.paste_handle, {}) // Read only.
	if map_status != .Ok {
		return 0, .Kernel_Refused
	}
	intrinsics.mem_copy_non_overlapping(raw_data(room), address, event.byte_count)
	system.memory_unmap(address)
	refused := clipboard_text_problem(room[:event.byte_count], len(room))
	if refused != .None {
		return 0, refused
	}
	return event.byte_count, .None
}

// paste_refuse answers a paste that no part of the program takes: it
// closes the lent handle and answers Paste_Taken, so the compositor ends
// the lend at once.
paste_refuse :: proc "contextless" (window: ^Window, event: Event) {
	paste_answer(window, event)
	system.log_in("programs", .Info, "display: ", string(window.title[:window.title_count]), ": no part of the window takes the paste")
}
