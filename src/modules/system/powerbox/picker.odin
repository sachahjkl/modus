// The picker of the trusted display (src/md/features/powerbox.md, "The
// picker ring"): the display writes its commands on the picker ring,
// this service answers each one. The list of an Open comes from the
// storage service: this service asks the root service, which gives it,
// for one call of `stores`, a connection that acts for the principal and
// reads only, and ends it after the call.
package powerbox_service

import "base:intrinsics"
import "internal:powerbox/powerbox_core"
import "modus:contract/blake3"
import "modus:contract/errors"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/powerbox"
import "modus:contract/ring"
import "modus:storage"
import "modus:system"

// The bound of a wait for the list: the root service gives the
// connection, then the storage service answers the call. Past it the
// Open gets No_List, and the principal asks again.
STORES_CALL_BOUND_MILLISECONDS :: 10_000

picker_region: []u8
image: []u8

// The Open that waits for its list: one at a time.
Picker_Open_Wait :: struct {
	active:    bool,
	tag:       u32,
	principal: u64,
	deadline:  u64,
}

picker_open_wait: Picker_Open_Wait
stores_wanted_sent: bool

// The call of `stores` that runs, on the connection that the root
// service gave.
Stores_Call :: struct {
	active:   bool,
	tag:      u32, // Of the command Stores_Connection, which this service completes at the end of the call.
	client:   storage.Client,
	service:  system.Handle,
	sent:     storage.Sent_Call,
	deadline: u64,
}

stores_call: Stores_Call

// The text of `stores`, copied once out of the call region, which the
// storage service can write at any time.
stores_text: [isolated.REGION_PAGES * system.PAGE_SIZE]u8
copied_picker_request: powerbox.Picker_Page_Request
picker_page: powerbox.Picker_Page

// picker_region_open maps the picker region and the boot image.
picker_region_open :: proc "contextless" (ctx: ^system.Context) {
	if handle := ctx.handles[powerbox.PICKER_REGION_SLOT]; handle != 0 {
		pages, size_status := system.memory_size(handle)
		address, map_status := system.memory_map(handle, {.Write})
		if size_status == .Ok && map_status == .Ok && pages >= powerbox.PICKER_REGION_PAGES {
			picker_region = ([^]u8)(address)[:pages * system.PAGE_SIZE]
		}
	}
	if handle := ctx.handles[powerbox.IMAGE_SLOT]; handle != 0 {
		address, map_status := system.memory_map(handle, {})
		if map_status == .Ok {
			image = ([^]u8)(address)[:ctx.values[powerbox.CONTEXT_VALUE_IMAGE_SIZE]]
		}
	}
}

@(private = "file")
picker_answer :: proc "contextless" (tag: u32, status: powerbox.Picker_Ring_Status, values: [7]u64) {
	ring.push(&display_ring.completions, ring.Record{kind = u32(status), tag = tag, values = values})
}

// picker_page_answer writes a page of a picker dialog into the region and
// answers the command of tag with its counts.
@(private = "file")
picker_page_answer :: proc "contextless" (tag: u32, request: ^powerbox.Picker_Page_Request) {
	refusal := powerbox_core.picker_page_take(&service_state, service_state.trusted_display_slot, request, &picker_page)
	if refusal != .None {
		picker_answer(tag, .Refused, {0 = u64(refusal), 1 = request.dialog_serial})
		return
	}
	intrinsics.mem_copy_non_overlapping(&picker_region[powerbox.PICKER_REGION_PAGE_OFFSET], &picker_page, size_of(powerbox.Picker_Page))
	picker_answer(tag, .Ok, {0, picker_page.dialog_serial, u64(picker_page.total), u64(picker_page.first), u64(picker_page.next), picker_page.more ? 1 : 0, u64(picker_page.candidate_count)})
}

// picker_ring_serve answers the commands of the display. It gives true
// when it wrote a completion.
picker_ring_serve :: proc "contextless" (now_ms: u64) -> (answered: bool) {
	if display_ring.commands.records == nil {
		return false
	}
	// An Open whose list did not come within its bound.
	if picker_open_wait.active && now_ms >= picker_open_wait.deadline && !stores_call.active {
		picker_answer(picker_open_wait.tag, .No_List, {})
		picker_open_wait = {}
		answered = true
	}
	for drained := 0; drained < powerbox.REQUESTS_PER_PASS && ring.count(&display_ring.completions) < ring.capacity(&display_ring.completions); drained += 1 {
		command := system.receive(&display_ring.commands) or_break
		answered = true
		parsed, known := powerbox.picker_ring_command_of_word(command.kind)
		if !known || len(picker_region) == 0 {
			picker_answer(command.tag, .Bad_Command, errors.ring_fail(command.kind, .Unsupported, .None, 0, i64(command.kind)))
			continue
		}
		switch parsed {
		case .None:
			picker_answer(command.tag, .Bad_Command, {})
		case .Open:
			if picker_open_wait.active {
				picker_answer(command.tag, .Busy, {})
				continue
			}
			// The root service gives the list; this service asks with a
			// record that answers no command.
			if ring.count(&service_ring.completions) >= ring.capacity(&service_ring.completions) {
				picker_answer(command.tag, .No_List, {})
				continue
			}
			ring.push(&service_ring.completions, ring.Record{kind = u32(powerbox.Service_Ring_Status.Stores_Wanted), values = {0 = command.values[0]}})
			stores_wanted_sent = true
			picker_open_wait = {active = true, tag = command.tag, principal = command.values[0], deadline = now_ms + STORES_CALL_BOUND_MILLISECONDS}
			answered = false
		case .Page:
			// Copied once out of the region before the check.
			intrinsics.mem_copy_non_overlapping(&copied_picker_request, &picker_region[powerbox.PICKER_REGION_REQUEST_OFFSET], size_of(powerbox.Picker_Page_Request))
			picker_page_answer(command.tag, &copied_picker_request)
		case .Pick:
			name_hash := transmute(blake3.Hash)[4]u64{command.values[3], command.values[4], command.values[5], command.values[6]}
			if command.values[1] > u64(max(u32)) {
				picker_answer(command.tag, .Refused, {0 = u64(powerbox.Powerbox_Refusal.Picker_Selection_Invalid), 1 = command.values[0]})
				continue
			}
			_, refusal := powerbox_core.picker_dialog_pick(&service_state, service_state.trusted_display_slot, command.values[0], u32(command.values[1]), command.values[2], name_hash)
			picker_answer(command.tag, refusal == .None ? .Ok : .Refused, {0 = u64(refusal), 1 = command.values[0]})
		case .Close:
			refusal := powerbox_core.picker_dialog_close(&service_state, service_state.trusted_display_slot, command.values[0])
			picker_answer(command.tag, refusal == .None ? .Ok : .Refused, {0 = u64(refusal), 1 = command.values[0]})
		}
	}
	return answered
}

// handle_proof says if a word names a handle that came through the ring of
// the root service, of a kind and with rights.
@(private = "file")
handle_proof :: proc "contextless" (word: u64, kind: op.Object_Kind, needed: system.Rights) -> bool {
	found_kind, rights, through := system.handle_state(system.Handle(word), service_ring_memory)
	return through && found_kind == kind && needed <= rights
}

@(private = "file")
stores_connection_answer :: proc "contextless" (tag: u32, status: powerbox.Service_Ring_Status) {
	ring.push(&service_ring.completions, ring.Record{kind = u32(status), tag = tag})
}

// stores_refused_take ends the Open that waits for the list of a principal
// that the root service refused.
stores_refused_take :: proc "contextless" (command: ring.Record) -> (answered: bool) {
	if picker_open_wait.active && !stores_call.active && picker_open_wait.principal == command.values[0] {
		picker_answer(picker_open_wait.tag, .No_List, {})
		picker_open_wait = {}
		answered = true
	}
	stores_connection_answer(command.tag, .Ok)
	return answered
}

// picker_wait_deadline gives the time at which an Open that waits ends,
// or no time.
picker_wait_deadline :: proc "contextless" () -> u64 {
	deadline := system.WAIT_FOREVER
	if picker_open_wait.active {
		deadline = picker_open_wait.deadline
	}
	if stores_call.active {
		deadline = min(deadline, stores_call.deadline)
	}
	return deadline
}

// stores_connection_take starts the call of `stores` on the connection that
// the root service gave for the Open that waits. A connection for no Open
// that waits, or with a handle that did not come through the ring, is
// refused, and its handles closed.
stores_connection_take :: proc "contextless" (command: ring.Record) {
	valid := handle_proof(command.values[0], .Process, {.Read}) && handle_proof(command.values[1], .Memory, {.Read, .Write}) && handle_proof(command.values[2], .Memory, {.Read, .Write})
	entries := system.image_entries(image)
	place := command.values[4]
	file: []u8
	if valid && place >= 1 && place <= u64(len(entries)) {
		entry := &entries[place - 1]
		if entry.offset <= u64(len(image)) && entry.size <= u64(len(image)) - entry.offset {
			file = image[entry.offset:][:entry.size]
		}
	}
	waits := picker_open_wait.active && picker_open_wait.principal == command.values[3]
	if !valid || !waits || stores_call.active || module.validate(file) != .None {
		for index in 0 ..< 3 {
			kind := index == 0 ? op.Object_Kind.Process : op.Object_Kind.Memory
			if handle_proof(command.values[index], kind, {}) {
				system.close(system.Handle(command.values[index]))
			}
		}
		stores_connection_answer(command.tag, .Refused)
		return
	}
	service := system.Handle(command.values[0])
	client, opened := storage.open_handles(system.Handle(command.values[1]), system.Handle(command.values[2]), service, file)
	if !opened {
		for index in 0 ..< 3 {
			system.close(system.Handle(command.values[index]))
		}
		stores_connection_answer(command.tag, .Refused)
		return
	}
	stores_call = {active = true, tag = command.tag, client = client, service = service, deadline = system.time() + STORES_CALL_BOUND_MILLISECONDS}
	sent, send_status := storage.call_send(&stores_call.client, "stores", nil)
	if send_status != .Ok {
		stores_call_end(.Refused)
		return
	}
	stores_call.sent = sent
}

// stores_call_end gives back the connection and completes its command:
// the root service then ends the connection.
@(private = "file")
stores_call_end :: proc "contextless" (status: powerbox.Service_Ring_Status) {
	client := &stores_call.client
	if client.calls.head != nil {
		system.ring_close(&client.calls)
	}
	if client.region != nil {
		system.memory_unmap(raw_data(client.region))
	}
	for handle in ([3]system.Handle{client.ring_memory, client.region_memory, stores_call.service}) {
		if handle != 0 {
			system.close(handle)
		}
	}
	stores_connection_answer(stores_call.tag, status)
	stores_call = {}
}

// stores_call_step reads the answer of `stores`: the names replace the
// stores of the principal, and the Open that waits gets its first page.
// It gives true when it answered the display.
stores_call_step :: proc "contextless" (now_ms: u64) -> (answered: bool) {
	if !stores_call.active {
		return false
	}
	error: errors.Error_Record
	full_count, text, status, done := storage.call_answer(&stores_call.client, &stores_call.sent, nil, &error)
	if !done {
		if !storage.connected(&stores_call.client) || now_ms >= stores_call.deadline {
			stores_call_end(.Refused)
			picker_answer(picker_open_wait.tag, .No_List, {})
			picker_open_wait = {}
			return true
		}
		return false
	}
	if status != .Ok {
		stores_call_end(.Refused)
		picker_answer(picker_open_wait.tag, .No_List, {})
		picker_open_wait = {}
		return true
	}
	principal := picker_open_wait.principal
	tag := picker_open_wait.tag
	// The text of the whole list did not fit the call region: a list that
	// misses stores is refused with its cause, never shown cut.
	if full_count < 0 || int(full_count) > len(text) || len(text) > len(stores_text) {
		stores_call_end(.Refused)
		picker_answer(tag, .List_Not_Whole, {0 = u64(powerbox.Picker_List_Cause.Text_Past_Region)})
		picker_open_wait = {}
		return true
	}
	count := copy(stores_text[:], text)
	powerbox_core.stores_replace_begin(&service_state, principal)
	place := 0
	store_id: u64 = 0
	whole := true
	for {
		name, more := powerbox.stores_text_next_name(stores_text[:count], &place)
		if !more {
			break
		}
		// A line that names no store is no candidate. A store that the
		// table does not take makes the list not whole.
		store_id += 1
		if len(name) > 0 && !powerbox_core.register_session_store(&service_state, principal, string(name), store_id) {
			whole = false
		}
	}
	stores_call_end(.Ok)
	picker_open_wait = {}
	if !whole {
		powerbox_core.stores_replace_begin(&service_state, principal)
		picker_answer(tag, .List_Not_Whole, {0 = u64(powerbox.Picker_List_Cause.Table_Full)})
		return true
	}
	serial, refusal := powerbox_core.picker_dialog_open(&service_state, principal, now_ms)
	if refusal != .None {
		picker_answer(tag, .Refused, {0 = u64(refusal)})
		return true
	}
	first := powerbox.Picker_Page_Request{dialog_serial = serial}
	picker_page_answer(tag, &first)
	return true
}
