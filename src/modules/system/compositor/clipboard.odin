package compositor

import "base:intrinsics"
import clipboard_rules "internal:compositor/clipboard"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:system"

// The clipboard (src/md/features/clipboard.md): one slot of the
// compositor, which a process reaches only at a key of the principal.
//
// Control+C sends Copy_Asked to the window in front; its process answers
// with Copy (a memory object of its own, with Read and Give) or
// Copy_Declined. Control+V lends the window in front a handle with Read to
// the content, from a copy of the handle of the slot that the compositor
// revokes at Paste_Taken, at the next key of the clipboard, or at the end
// of the process that pastes or of the process that copied. Each key has a
// serial that the event carries and the answer names: an answer to a key
// that a newer key replaced, or to a lend that ended, is refused. The
// compositor reads no byte of the content: the reader copies it, then
// checks its copy.

#assert(clipboard_rules.MODIFIER_CONTROL == display.MODIFIER_CONTROL)
#assert(clipboard_rules.TEXT_LIMIT == display.CLIPBOARD_TEXT_LIMIT)

// The content of the clipboard. memory 0: the slot is empty.
Clipboard_Content :: struct {
	memory: system.Handle, // The gift of the process that copied, with Read and Give.
	kind:   display.Clipboard_Kind,
	count:  int, // Its bytes, 1 to CLIPBOARD_TEXT_LIMIT.
	owner:  int, // The client that copied: its end empties the slot.
	owner_title: system.Name, // Its title, for the line of a paste.
}

clipboard_content: Clipboard_Content
clipboard_serials: clipboard_rules.Serials

// The one lend of a paste: the client, the copy of the handle of the slot
// in this process that its handle came from, and the client that copied
// what it lends. client -1: no lend.
clipboard_lend_client := -1
clipboard_lend_handle: system.Handle
clipboard_lend_owner := -1

// clipboard_key takes a key record of the input service that is a key of
// the clipboard, and gives false for any other key. The press of C or V
// with Control acts. Its release is taken too, so no process sees the
// release of a key whose press it did not see. The Control key itself is a
// record of its own, which goes on its usual path.
clipboard_key :: proc "contextless" (character: rune, modifiers: u32, pressed: bool) -> bool {
	key := clipboard_rules.clipboard_key_of(character, modifiers)
	switch key {
	case .None:
		return false
	case .Copy:
		if pressed {
			clipboard_copy_key(.Copy)
		}
	case .Cut:
		if pressed {
			clipboard_copy_key(.Cut)
		}
	case .Paste:
		if pressed {
			clipboard_paste_key()
		}
	}
	return true
}

// clipboard_store_local stores text copied by a compositor-owned surface (the
// palette) into the clipboard slot using compositor memory, with owner = -1 so
// no client closing removes it. Returns false when text is refused or memory
// creation/mapping fails, leaving any existing clipboard slot unchanged.
clipboard_store_local :: proc "contextless" (text: []u8, source: string) -> bool {
	clipboard_lend_end()
	if display.clipboard_text_problem(text, display.CLIPBOARD_TEXT_LIMIT, .Single_Line) != .None {
		return false
	}
	pages := (u64(len(text)) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	memory, status := system.memory_create(pages)
	if status != .Ok {
		return false
	}
	address, map_status := system.memory_map(memory, {.Write})
	if map_status != .Ok {
		system.close(memory)
		return false
	}
	intrinsics.mem_copy_non_overlapping(address, raw_data(text), len(text))
	system.memory_unmap(address)
	if clipboard_content.memory != 0 {
		system.close(clipboard_content.memory)
	}
	owner_title: system.Name
	copy(owner_title[:len(owner_title) - 1], source)
	clipboard_content = {memory = memory, kind = .Text, count = len(text), owner = -1, owner_title = owner_title}
	system.log_fact(.Info, Text_Copied{length = value_kinds.Size_In_Bytes(len(text)), window = window_field(owner_title[:])})
	return true
}

// clipboard_read_local copies the current clipboard text into out for a
// compositor-owned paste target (the palette). Returns (0, false) when the
// clipboard is empty, not text, larger than out, or its object gives no
// bytes. The object is memory of the window that copied, which can revoke
// it or leave a page with no frame: the copy by the kernel
// (system.memory_read) gives a status there, where a read through a
// mapping would fault and stop the trusted display. One call of at most
// CLIPBOARD_TEXT_LIMIT bytes.
clipboard_read_local :: proc "contextless" (out: []u8) -> (count: int, ok: bool) {
	clipboard_lend_end()
	if clipboard_content.memory == 0 || clipboard_content.kind != .Text || clipboard_content.count <= 0 || clipboard_content.count > len(out) || clipboard_content.count > display.CLIPBOARD_TEXT_LIMIT {
		return 0, false
	}
	if _, status := system.memory_read(clipboard_content.memory, 0, out[:clipboard_content.count]); status != .Ok {
		return 0, false
	}
	return clipboard_content.count, true
}

// clipboard_lend_end revokes the lend of a paste, if one waits: each
// handle and each mapping that came from the lent handle ends.
clipboard_lend_end :: proc "contextless" () {
	if clipboard_lend_client < 0 {
		return
	}
	system.handle_revoke(clipboard_lend_handle)
	system.close(clipboard_lend_handle)
	clients[clipboard_lend_client].clipboard.lend_serial = 0
	clipboard_lend_client, clipboard_lend_handle, clipboard_lend_owner = -1, 0, -1
}

// clipboard_copy_key sends Copy_Asked with a new serial and action (Copy
// or Cut) to the window in front. A copy that waited for it is replaced: a
// process that lost the event answers the newest one.
clipboard_copy_key :: proc "contextless" (action: display.Copy_Action = .Copy) {
	clipboard_lend_end()
	if order_count == 0 {
		system.log_fact(.Info, Copy_Key_Without_Window{})
		return
	}
	client := &clients[order[order_count - 1]]
	serial := clipboard_rules.serial_next(&clipboard_serials)
	clipboard_rules.copy_key_take(&client.clipboard, serial)
	send(client, .Copy_Asked, {0 = serial, 1 = u64(action)})
	switch action {
	case .Copy:
		system.log_fact(.Info, Copy_Key_Sent{window = window_field(client.title[:])})
	case .Cut:
		system.log_fact(.Info, Cut_Key_Sent{window = window_field(client.title[:])})
	}
}

// clipboard_paste_key lends the content to the window in front: a copy of
// the handle of the slot in this process, then a handle with Read from it
// to the process, and the event Pasted with a new serial.
clipboard_paste_key :: proc "contextless" () {
	clipboard_lend_end()
	empty_state: clipboard_rules.Window_State
	client: ^Client
	index := -1
	if order_count > 0 {
		index = order[order_count - 1]
		client = &clients[index]
	}
	state := client != nil ? &client.clipboard : &empty_state
	serial := clipboard_rules.serial_next(&clipboard_serials)
	refusal, _ := clipboard_rules.paste_key_take(state, client != nil, clipboard_content.memory != 0, serial)
	switch refusal {
	case .None:
	case .No_Window:
		system.log_fact(.Info, Paste_Key_Without_Window{})
		return
	case .No_Content:
		system.log_fact(.Info, Paste_Of_Empty_Clipboard{window = window_field(client.title[:])})
		return
	}
	lent, status := system.give(0, clipboard_content.memory, {.Read, .Give})
	given: system.Handle
	if status == .Ok {
		given, status = system.give(client.ring_memory, lent, {.Read})
		if status != .Ok {
			system.close(lent)
		}
	}
	if status != .Ok {
		client.clipboard.lend_serial = 0
		system.log_fact(.Warning, Paste_Refused{window = window_field(client.title[:])})
		return
	}
	clipboard_lend_client, clipboard_lend_handle, clipboard_lend_owner = index, lent, clipboard_content.owner
	send(client, .Pasted, {0 = u64(given), 1 = u64(clipboard_content.kind), 2 = u64(clipboard_content.count), 3 = serial})
	system.log_fact(.Info, Paste_Sent{length = value_kinds.Size_In_Bytes(clipboard_content.count), owner_window = window_field(clipboard_content.owner_title[:]), window = window_field(client.title[:])})
}

// clipboard_copy_take takes the record Copy of a window: the content of
// the copy that the newest key of the principal asked for. The checks are
// clipboard_rules.copy_refusal; a refused record changes nothing and is
// counted. A taken one replaces the slot.
clipboard_copy_take :: proc "contextless" (index: int, record: ring.Record) {
	client := &clients[index]
	// The process wrote the number of the handle: a number with no proof
	// of this process is neither used nor closed (surface_create), and a
	// number of a handle that this service holds already is not closed.
	memory := system.Handle(record.values[0])
	kind, rights, through := system.handle_state(memory, client.ring_memory)
	content_kind, kind_known := display.clipboard_kind_of_word(record.values[1])
	serial := record.values[3]
	facts := clipboard_rules.Copy_Facts {
		asked      = clipboard_rules.copy_names_the_request(client.clipboard, serial),
		through    = through,
		names_held = memory != 0 && (memory == clipboard_content.memory || memory == clipboard_lend_handle),
		is_memory  = kind == .Memory,
		readable   = .Read in rights,
		giveable   = .Give in rights,
		kind_word  = record.values[1],
		kind_known = kind_known,
		count      = record.values[2],
	}
	if facts.through && !facts.names_held && facts.is_memory {
		if pages, size_status := system.memory_size(memory); size_status == .Ok {
			facts.memory_bytes = pages * system.PAGE_SIZE
		}
	}
	if refusal := clipboard_rules.copy_refusal(facts); refusal != .None {
		if facts.through && !facts.names_held {
			system.close(memory)
		}
		client.clipboard_refused += 1
		return
	}
	clipboard_rules.answer_take(&client.clipboard, .Copy, serial)
	if clipboard_content.memory != 0 {
		system.close(clipboard_content.memory)
	}
	clipboard_content = {memory = memory, kind = content_kind, count = int(facts.count), owner = index, owner_title = client.title}
	system.log_fact(.Info, Text_Copied{length = value_kinds.Size_In_Bytes(facts.count), window = window_field(client.title[:])})
}

// clipboard_answer_take takes Copy_Declined or Paste_Taken, whose first
// value is the serial that it answers: only when that serial is the one of
// the state that waits for this window, else it is refused and counted. A
// late Paste_Taken of a lend that ended so never ends the next lend.
clipboard_answer_take :: proc "contextless" (index: int, answer: clipboard_rules.Answer, record: ring.Record) {
	client := &clients[index]
	if !clipboard_rules.answer_take(&client.clipboard, answer, record.values[0]) {
		client.clipboard_refused += 1
		return
	}
	switch answer {
	case .Copy:
		// A Copy goes through clipboard_copy_take.
	case .Copy_Declined:
		system.log_fact(.Info, Nothing_To_Copy{window = window_field(client.title[:])})
	case .Paste_Taken:
		if clipboard_lend_client == index {
			clipboard_lend_end()
		}
	}
}

// clipboard_client_remove ends what the clipboard holds of a client that
// leaves (clipboard_rules.client_end_effects): a lend to it or of what it
// copied, and the content that it copied, whose memory belongs to a process
// that ends.
clipboard_client_remove :: proc "contextless" (index: int) {
	effects := clipboard_rules.client_end_effects(index, clipboard_content.owner, clipboard_lend_client, clipboard_lend_owner, clipboard_content.memory != 0)
	if effects.lend_ends {
		clipboard_lend_end()
	}
	if effects.content_ends {
		system.close(clipboard_content.memory)
		clipboard_content = {}
		system.log_fact(.Info, Clipboard_Emptied{window = window_field(clients[index].title[:])})
	}
	if clients[index].clipboard_refused != 0 {
		system.log_fact(.Info, Window_Closed_After_Refused_Clipboard_Records{window = window_field(clients[index].title[:]), refused = clients[index].clipboard_refused})
	}
}
